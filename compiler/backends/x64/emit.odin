package x64_assembler

import bc "../../bytecode"

// ============================================================================
// x64 EMITTER — bytecode → x86-64 machine code (.text bytes).
//
// Consumes the target-neutral bc.BC_Program and emits x86-64 using the tested
// assembler in backends/x64 (encodings validated against objdump). This first
// emitter uses a simple, robust "stack-everything" model: every virtual register
// vN lives at [rbp - 8*(vN+1)], loaded into a work register for each op and
// stored back. It is correct and easy to validate against the interpreter; the
// optimizing linear-scan allocator (x64_regalloc.odin) layers on top later.
//
// Work registers: RAX (primary), RCX (secondary / shift count), RDX (idiv high).
// Result is returned via the exit-status syscall (integer programs).
//
// Labels are resolved in two passes: emit with placeholder rel32 offsets while
// recording each jump's site and target label, then patch the offsets once every
// label's byte position is known (rel32 = displacement from the END of the jump).
// ============================================================================

X64_Emit :: struct {
	buf:        ByteBuffer,
	prog:       ^bc.BC_Program,
	// label id → byte offset of its definition (filled as we emit).
	label_pos:  []int,
	// pending jump fixups: patch a rel32 at `at` to reach `label`.
	fixups:     [dynamic]X64_Fixup,
	// .rodata layout: rodata_off[id] is the byte offset of string id within the
	// rodata blob, whose runtime base address is rodata_vaddr. Both are known
	// BEFORE emitting code (they depend only on string lengths), so bc.BC_Str_Const
	// loads an absolute address with no fixup.
	rodata_off:    []int,
	rodata_vaddr:  int,
	code_base_off: int,
	// str_len[vN] is the byte length of the concrete string a Str_Const value
	// holds, used by the string epilogue's write(1, ptr, len).
	str_len:       map[int]int,
	// alloc maps each vN to a register or a spill slot (linear-scan result). The
	// load/store helpers consult it so a value that lives in a register is used
	// directly — no store-then-reload through the stack.
	alloc:         Reg_Alloc,
	// def[v] = index of the instruction defining v (-1 if none); use_count[v] =
	// number of operand uses. The instruction selector consults these to fold an
	// address-mode pattern (lea) and to refuse folding a shared value.
	def:           []int,
	use_count:     []int,
	// absorbed[v] = the value was dissolved into a parent lea's address mode (an
	// intermediate +/-/index node), so the emitter must not emit it on its own.
	absorbed:      []bool,
}

X64_Fixup :: struct {
	at:    int, // byte offset of the rel32 field to patch
	label: bc.BC_Label,
}

// X64_Output is the emitter's result: the code bytes plus the .rodata blob that
// must precede the code in the image (string literals live there).
X64_Output :: struct {
	code:   []u8,
	rodata: []u8,
}

// emit_x64 lowers a bc.BC_Program to machine code + its .rodata blob. The image is
// laid out [headers][rodata][code]; rodata offsets depend only on string lengths,
// so they're known before emitting and bc.BC_Str_Const loads absolute addresses.
emit_x64 :: proc(prog: ^bc.BC_Program) -> (X64_Output, string) {
	if prog == nil do return {}, "no program"
	if prog.error != "" do return {}, prog.error

	e := X64_Emit{prog = prog}
	e.label_pos = make([]int, prog.label_count)
	defer delete(e.label_pos)
	defer delete(e.fixups)
	for i in 0 ..< prog.label_count do e.label_pos[i] = -1

	// def / use_count / absorbed — for the instruction selector (lea folding).
	e.def = make([]int, prog.value_count)
	e.use_count = make([]int, prog.value_count)
	e.absorbed = make([]bool, prog.value_count)
	defer delete(e.def)
	defer delete(e.use_count)
	defer delete(e.absorbed)
	for i in 0 ..< prog.value_count do e.def[i] = -1
	for inst, pc in prog.insts {
		if d, ok := bc_def(inst); ok do e.def[d] = pc
		for u in bc_uses(inst) do e.use_count[u] += 1
	}

	// Linear-scan register allocation: values live in registers, only spilled
	// ones touch the stack. load/store consult e.alloc.
	e.alloc = allocate_registers(prog)
	defer delete(e.alloc.locs)

	// Lay out .rodata: concatenated string bytes, each offset recorded. The blob
	// sits right after the headers, so each string's runtime address is
	// ELF_BASE + ELF_HEADERS + offset.
	rodata_blob := make([dynamic]u8)
	e.rodata_off = make([]int, len(prog.rodata))
	defer delete(e.rodata_off)
	for s, i in prog.rodata {
		e.rodata_off[i] = len(rodata_blob)
		for c in transmute([]u8)s do append(&rodata_blob, c)
	}
	e.rodata_vaddr = ELF_BASE + ELF_HEADERS

	// Code follows the rodata blob in the image.
	code_off := ELF_HEADERS + len(rodata_blob)
	e.code_base_off = code_off

	context.user_ptr = &e.buf

	// The frame only needs room for SPILLED values now (most live in registers).
	frame := e.alloc.stack_size + 16
	frame = (frame + 15) & ~int(15)

	emit_arg_stub(&e)
	emit_prologue(&e, frame)
	if msg := emit_body(&e); msg != "" do return {}, msg
	patch_fixups(&e)

	out := make([]u8, e.buf.len)
	copy(out, e.buf.data[:e.buf.len])
	return X64_Output{code = out, rodata = rodata_blob[:]}, ""
}

// arg_slot_info collects, per arg slot, whether that slot is a FLOAT ?? (its
// argv string must be parsed as a decimal, not an integer). Returns the highest
// slot index seen + 1 (the count to parse) and the float-slot flags.
arg_slot_info :: proc(e: ^X64_Emit) -> (count: int, is_float: map[int]bool) {
	is_float = make(map[int]bool)
	count = 0
	for inst in e.prog.insts {
		if la, ok := inst.(bc.BC_Load_Arg); ok {
			if la.slot + 1 > count do count = la.slot + 1
			if bc.mtype_is_float(e.prog.value_types[int(la.dst)]) {
				is_float[la.slot] = true
			}
		}
	}
	return
}

// emit_arg_stub parses argv[1..] into ARGS_TABLE[slot]. Integer slots store the
// signed integer (inline atoi); FLOAT slots store the f64 BIT PATTERN (inline
// atof). Because each slot's domain (int vs float) is known at compile time, the
// stub is UNROLLED — one parse block per slot, branchless on type — so a float
// slot gets atof and an int slot atoi, with no per-slot type test at runtime.
//
// At process entry rsp -> argc, then the argv pointers. argv[K+1] is the K-th
// ??. A slot whose argv is missing (K+1 >= argc) is left zero.
// Registers: r12=argc, r13=&argv[0]. Parse blocks clobber rax/rcx/rdx/rsi/rdi
// + xmm0/xmm1 (float). R11 holds the ARGS_TABLE base.
emit_arg_stub :: proc(e: ^X64_Emit) {
	count, is_float := arg_slot_info(e)
	defer delete(is_float)
	if count == 0 do return

	// r12 = argc = [rsp] ; r13 = &argv[0] = rsp+8 ; r11 = ARGS_TABLE base.
	write([]u8{0x4C, 0x8B, 0x24, 0x24}) // mov r12, [rsp]
	write([]u8{0x4C, 0x8D, 0x6C, 0x24, 0x08}) // lea r13, [rsp+8]
	emit_load_imm_into(e, .R11, i64(ARGS_TABLE_VADDR)) // ARGS_TABLE fits imm32

	for slot in 0 ..< count {
		// Guard: if slot+1 >= argc, skip this slot (leaves table[slot]=0).
		// cmp r12, imm(slot+1) ; jle skip
		write([]u8{0x49, 0x81, 0xFC}) // cmp r12, imm32
		put_u32(e, u32(slot + 1))
		write([]u8{0x0F, 0x8E}) // jle rel32 → skip
		jle_at := e.buf.len
		write([]u8{0, 0, 0, 0})

		// rdi = argv[slot+1] = [r13 + 8*(slot+1)]
		write([]u8{0x49, 0x8B, 0xBD}) // mov rdi, [r13 + disp32]
		put_u32(e, u32(8 * (slot + 1)))

		if is_float[slot] {
			emit_atof(e) // f64 bits → rax
		} else {
			emit_atoi(e) // signed int → rax
		}

		// ARGS_TABLE[slot] = rax → mov [r11 + disp32], rax
		write([]u8{0x49, 0x89, 0x83}) // mov [r11 + disp32], rax
		put_u32(e, u32(8 * slot))

		// skip:
		skip := e.buf.len
		patch_rel32(e, jle_at, i32(skip - (jle_at + 4)))
	}
}

put_u32 :: proc(e: ^X64_Emit, v: u32) {
	write([]u8{u8(v & 0xFF), u8((v >> 8) & 0xFF), u8((v >> 16) & 0xFF), u8((v >> 24) & 0xFF)})
}

// emit_atoi: parse the NUL-terminated string at rdi into rax (signed decimal).
// rax=acc, cl=byte, sil=sign flag. Clobbers rax,rcx,rsi,rdx.
emit_atoi :: proc(e: ^X64_Emit) {
	write([]u8{0x48, 0x31, 0xC0}) // xor rax, rax            (acc=0)
	write([]u8{0x45, 0x31, 0xC0}) // xor r8, r8              (sign=0)
	// check leading '-' : if [rdi]==0x2D, sign=1, rdi++
	write([]u8{0x8A, 0x0F}) // mov cl, [rdi]
	write([]u8{0x80, 0xF9, 0x2D}) // cmp cl, '-'
	write([]u8{0x75, 0x06}) // jne +6 (skip sign setup)
	write([]u8{0x41, 0xB0, 0x01}) // mov r8b, 1
	write([]u8{0x48, 0xFF, 0xC7}) // inc rdi
	// digit loop:
	dloop := e.buf.len
	write([]u8{0x8A, 0x0F}) // mov cl, [rdi]
	write([]u8{0x80, 0xF9, 0x30}) // cmp cl, '0'
	write([]u8{0x7C}) // jl rel8 → end (patched)
	jl_at := e.buf.len; write([]u8{0})
	write([]u8{0x80, 0xF9, 0x39}) // cmp cl, '9'
	write([]u8{0x7F}) // jg rel8 → end (patched)
	jg_at := e.buf.len; write([]u8{0})
	// acc = acc*10 + (cl - '0'), the hot path, in 3 fast ops (no imul):
	//   movzx ecx, cl              ; digit (ascii) zero-extended
	//   lea   eax, [rax+rax*4]     ; acc*5
	//   lea   eax, [rcx+rax*2-'0'] ; acc*10 + digit - '0'  (fuses *2, +digit, -'0')
	// 32-bit lea (no REX.W). imul (3 cycles) → two lea (1 cycle each).
	write([]u8{0x0F, 0xB6, 0xC9}) // movzx ecx, cl
	write([]u8{0x8D, 0x04, 0x80}) // lea eax, [rax+rax*4]
	write([]u8{0x8D, 0x44, 0x41, 0xD0}) // lea eax, [rcx+rax*2-0x30]
	write([]u8{0x48, 0xFF, 0xC7}) // inc rdi
	// jmp dloop
	write([]u8{0xEB})
	back := e.buf.len
	write([]u8{0})
	e.buf.data[back] = u8(i8(dloop - (back + 1)))
	// end: patch the two forward jumps to here, then apply sign.
	end := e.buf.len
	e.buf.data[jl_at] = u8(i8(end - (jl_at + 1)))
	e.buf.data[jg_at] = u8(i8(end - (jg_at + 1)))
	write([]u8{0x45, 0x84, 0xC0}) // test r8b, r8b
	write([]u8{0x74, 0x03}) // jz +3
	write([]u8{0x48, 0xF7, 0xD8}) // neg rax
}

// emit_atof: parse the NUL-terminated decimal string at rdi into the f64 BIT
// PATTERN in rax. Handles a leading '-', an integer part, and an optional
// '.'-fraction (`-3.14`, `42`, `.5`). Computed as
//     value = (ipart + frac/scale) * sign,  scale = 10^(#frac digits)
// in scalar SSE, then movq'd back to rax. Not the hot path (one-shot arg
// parsing), so it favors clarity over cycle count. Clobbers rax,rcx,rdx,r8,r9,
// r10,r15,xmm0,xmm1,xmm2.
emit_atof :: proc(e: ^X64_Emit) {
	// r8=sign(0/1), r9=ipart, r10=frac, r15=scale(=1, ×10 per frac digit).
	write([]u8{0x45, 0x31, 0xC0}) // xor r8, r8     (sign=0)
	write([]u8{0x4D, 0x31, 0xC9}) // xor r9, r9     (ipart=0)
	write([]u8{0x4D, 0x31, 0xD2}) // xor r10, r10   (frac=0)
	write([]u8{0x49, 0xC7, 0xC7, 0x01, 0x00, 0x00, 0x00}) // mov r15, 1  (scale=1)

	// leading '-' ?
	write([]u8{0x8A, 0x0F}) // mov cl, [rdi]
	write([]u8{0x80, 0xF9, 0x2D}) // cmp cl, '-'
	write([]u8{0x75, 0x06}) // jne +6
	write([]u8{0x41, 0xB0, 0x01}) // mov r8b, 1
	write([]u8{0x48, 0xFF, 0xC7}) // inc rdi

	// integer-part loop: r9 = r9*10 + digit.
	iloop := e.buf.len
	write([]u8{0x8A, 0x0F}) // mov cl, [rdi]
	write([]u8{0x80, 0xF9, 0x30}) // cmp cl, '0'
	write([]u8{0x7C}) // jl rel8 → after int (patched)
	i_jl := e.buf.len; write([]u8{0})
	write([]u8{0x80, 0xF9, 0x39}) // cmp cl, '9'
	write([]u8{0x7F}) // jg rel8 → after int
	i_jg := e.buf.len; write([]u8{0})
	// r9 = r9*10 + (cl-'0'). One-shot parse, not the hot path → plain imul.
	write([]u8{0x0F, 0xB6, 0xC9}) // movzx ecx, cl
	write([]u8{0x83, 0xE9, 0x30}) // sub ecx, 0x30        (digit value in rcx)
	imul_r64_imm32(.R9, 10) // r9 *= 10
	add_r64_r64(.R9, .RCX) // r9 += digit
	write([]u8{0x48, 0xFF, 0xC7}) // inc rdi
	write([]u8{0xEB}) // jmp iloop
	i_back := e.buf.len; write([]u8{0})
	e.buf.data[i_back] = u8(i8(iloop - (i_back + 1)))

	after_int := e.buf.len
	e.buf.data[i_jl] = u8(i8(after_int - (i_jl + 1)))
	e.buf.data[i_jg] = u8(i8(after_int - (i_jg + 1)))

	// '.' ?  if [rdi]=='.', inc rdi and parse fraction; else skip.
	write([]u8{0x8A, 0x0F}) // mov cl, [rdi]
	write([]u8{0x80, 0xF9, 0x2E}) // cmp cl, '.'
	write([]u8{0x75}) // jne rel8 → after frac
	dot_jne := e.buf.len; write([]u8{0})
	write([]u8{0x48, 0xFF, 0xC7}) // inc rdi

	floop := e.buf.len
	write([]u8{0x8A, 0x0F}) // mov cl, [rdi]
	write([]u8{0x80, 0xF9, 0x30}) // cmp cl, '0'
	write([]u8{0x7C}) // jl → after frac
	f_jl := e.buf.len; write([]u8{0})
	write([]u8{0x80, 0xF9, 0x39}) // cmp cl, '9'
	write([]u8{0x7F}) // jg → after frac
	f_jg := e.buf.len; write([]u8{0})
	// r10 = r10*10 + (cl-'0'); r15 *= 10.
	write([]u8{0x0F, 0xB6, 0xC9}) // movzx ecx, cl
	write([]u8{0x83, 0xE9, 0x30}) // sub ecx, 0x30        (digit value in rcx)
	imul_r64_imm32(.R10, 10) // r10 *= 10
	add_r64_r64(.R10, .RCX) // r10 += digit
	imul_r64_imm32(.R15, 10) // r15 *= 10
	write([]u8{0x48, 0xFF, 0xC7}) // inc rdi
	write([]u8{0xEB}) // jmp floop
	f_back := e.buf.len; write([]u8{0})
	e.buf.data[f_back] = u8(i8(floop - (f_back + 1)))

	after_frac := e.buf.len
	e.buf.data[dot_jne] = u8(i8(after_frac - (dot_jne + 1)))
	e.buf.data[f_jl] = u8(i8(after_frac - (f_jl + 1)))
	e.buf.data[f_jg] = u8(i8(after_frac - (f_jg + 1)))

	// value = ipart + frac/scale  (all in xmm0).
	cvtsi2sd_xmm_r64(.XMM0, .R9) // xmm0 = (double)ipart
	cvtsi2sd_xmm_r64(.XMM1, .R10) // xmm1 = (double)frac
	cvtsi2sd_xmm_r64(.XMM2, .R15) // xmm2 = (double)scale
	divsd_xmm_xmm(.XMM1, .XMM2) // xmm1 = frac/scale
	addsd_xmm_xmm(.XMM0, .XMM1) // xmm0 = ipart + frac/scale
	// sign: if r8b, xmm0 = -xmm0  (flip sign bit).
	write([]u8{0x45, 0x84, 0xC0}) // test r8b, r8b
	write([]u8{0x74}) // jz → done
	sgn_jz := e.buf.len; write([]u8{0})
	movq_r64_xmm_bits(.RAX, .XMM0)
	movabs_r64_imm64(.RCX, transmute(i64)u64(0x8000000000000000))
	write([]u8{0x48, 0x31, 0xC8}) // xor rax, rcx   (flip sign bit)
	movq_xmm_r64(.XMM0, .RAX)
	done_sgn := e.buf.len
	e.buf.data[sgn_jz] = u8(i8(done_sgn - (sgn_jz + 1)))

	movq_r64_xmm_bits(.RAX, .XMM0) // rax = f64 bits
}

put_i64_bytes :: proc(e: ^X64_Emit, v: i64) {
	u := transmute(u64)v
	bytes: [8]u8
	for i in 0 ..< 8 do bytes[i] = u8(u >> (uint(i) * 8))
	write(bytes[:])
}

patch_rel32 :: proc(e: ^X64_Emit, at: int, rel: i32) {
	u := transmute(u32)rel
	e.buf.data[at + 0] = u8(u & 0xFF)
	e.buf.data[at + 1] = u8((u >> 8) & 0xFF)
	e.buf.data[at + 2] = u8((u >> 16) & 0xFF)
	e.buf.data[at + 3] = u8((u >> 24) & 0xFF)
}

// --- frame helpers : register-aware load/store -----------------------------
//
// Every value access in the emitter goes through load/store, so making just
// these two consult the linear-scan allocation lifts the whole emitter off the
// stack: a value that lives in a register is read/written in place (a reg→reg
// mov, elided when source and destination already coincide); only spilled values
// touch memory.

// spill_addr is the stack address of a SPILLED value's slot, [rbp - offset].
spill_addr :: proc(e: ^X64_Emit, vN: int) -> MemoryAddress {
	off := e.alloc.locs[vN].offset
	return AddressComponents{base = Register64.RBP, displacement = i32(-off)}
}

// home_reg returns the register a value is allocated to, and whether it has one.
home_reg :: proc(e: ^X64_Emit, vN: bc.BC_Value) -> (Register64, bool) {
	loc := e.alloc.locs[int(vN)]
	if loc.kind == .Register do return loc.reg, true
	return .RAX, false
}

// load brings vN's value into `reg`. If vN lives in a register, it's a reg→reg
// move (skipped when reg is already its home); if spilled, a load from memory.
load :: proc(e: ^X64_Emit, reg: Register64, vN: bc.BC_Value) {
	if home, ok := home_reg(e, vN); ok {
		if home != reg do mov_r64_r64(reg, home)
		return
	}
	mov_r64_m64(reg, spill_addr(e, int(vN)))
}

// store writes `reg` into vN's home. If vN lives in a register, it's a reg→reg
// move (skipped when they coincide); if spilled, a store to memory.
store :: proc(e: ^X64_Emit, vN: bc.BC_Value, reg: Register64) {
	if home, ok := home_reg(e, vN); ok {
		if home != reg do mov_r64_r64(home, reg)
		return
	}
	mov_m64_r64(spill_addr(e, int(vN)), reg)
}

// --- prologue / epilogue ---------------------------------------------------

emit_prologue :: proc(e: ^X64_Emit, frame: int) {
	// No frame needed when nothing is spilled: we call nothing and use no stack
	// locals (spills), and the float-print scratch lives in the red zone below
	// rsp. So `push rbp ; mov rbp,rsp ; sub rsp,N` is dead — skip it entirely.
	if e.alloc.stack_size == 0 do return
	// push rbp ; mov rbp, rsp ; sub rsp, frame
	push_r64(.RBP)
	mov_r64_r64(.RBP, .RSP)
	sub_r64_imm32(.RSP, u32(frame))

	// Load each ??N from argv. The runtime entry stub (in the ELF) leaves the
	// parsed integer arguments in a small table the prologue reads; for now the
	// ELF stub parses argv[1..] into the first N stack slots BELOW our frame.
	// See write_elf_exec: it pushes parsed args, then calls us. Here we assume
	// the stub placed arg K at [rbp + 16 + 8*K] (above the saved rbp/return).
	// (Wired in the ELF step.)
}

// emit_exit emits the program's return. For a string result: write(1, ptr, len)
// then exit(0). For an integer/bool result: exit(result & 0xff) via the status.
emit_exit :: proc(e: ^X64_Emit, result: bc.BC_Value) {
	if e.prog.result_type == .Str {
		// sys_write(1, ptr, len): rax=1, rdi=1, rsi=ptr, rdx=len.
		load(e, .RSI, result) // rsi = string pointer
		if l, ok := e.str_len[int(result)]; ok {
			emit_load_imm_into(e, .RDX, i64(l)) // rdx = length (immediate, known)
		} else {
			xor_r64_r64(.RDX, .RDX)
		}
		emit_load_imm_into(e, .RDI, 1) // fd = stdout
		emit_load_imm_into(e, .RAX, 1) // sys_write
		syscall()
		// exit(0)
		xor_r64_r64(.RDI, .RDI)
		emit_load_imm_into(e, .RAX, 60)
		syscall()
		return
	}
	if bc.mtype_is_float(e.prog.result_type) {
		emit_print_float(e, result)
		xor_r64_r64(.RDI, .RDI)
		emit_load_imm_into(e, .RAX, 60)
		syscall()
		return
	}
	load(e, .RDI, result)
	emit_load_imm_into(e, .RAX, 60) // sys_exit
	syscall()
}

// emit_print_float writes a decimal rendering of the f64 in `result`'s slot to
// stdout: optional '-', integer part, '.', then 6 fractional digits. Not a full
// IEEE shortest-round-trip formatter — a simple fixed-6 form sufficient to
// observe and validate float results. Builds the string in a stack buffer.
emit_print_float :: proc(e: ^X64_Emit, result: bc.BC_Value) {
	// Strategy (all integer math after the initial truncation):
	//   xmm0 = value ; if sign bit, emit '-' and xmm0 = -xmm0
	//   ipart = (i64)xmm0   (cvttsd2si)
	//   frac  = (xmm0 - ipart) * 1e6  rounded → 6 digits
	// We render into a 32-byte buffer on the stack at [rbp-512] (within frame
	// headroom is not guaranteed; use a dedicated red-zone-safe area below rsp).
	// For simplicity we print integer part and 6 fraction digits via the helpers.

	// SAVE the value's bits to a stable stack slot FIRST. The print helpers below
	// clobber many registers (RSI/RCX/R8/R9 for the write syscall and digit
	// loops), so `result` — which may live in one of them under the linear-scan
	// allocation — cannot be reloaded from its home. We stash the bits at
	// [rsp-64]: RSP is stable here (no push between), the print digit buffers use
	// [rsp-1]/[rsp-32], so [rsp-64] is a disjoint red-zone slot.
	val_slot := AddressComponents{base = Register64.RSP, displacement = i32(-64)}
	load(e, .RAX, result)
	mov_m64_r64(val_slot, .RAX)
	movq_xmm_r64(.XMM0, .RAX)

	// --- handle sign: test the sign bit of rax (bit 63). ---
	movabs_r64_imm64(.RCX, transmute(i64)u64(0x8000000000000000))
	write([]u8{0x48, 0x85, 0xC8}) // test rax, rcx
	write([]u8{0x74}) // jz over_sign
	jz_at := e.buf.len; write([]u8{0})
	// print '-'
	emit_print_char(e, '-')
	over_sign := e.buf.len
	e.buf.data[jz_at] = u8(i8(over_sign - (jz_at + 1)))

	// abs: reload bits from the stable slot, clear the sign bit, into xmm0.
	mov_r64_m64(.RAX, val_slot)
	movabs_r64_imm64(.RCX, transmute(i64)u64(0x7FFFFFFFFFFFFFFF))
	write([]u8{0x48, 0x21, 0xC8}) // and rax, rcx
	movq_xmm_r64(.XMM0, .RAX)

	// ipart = cvttsd2si rax, xmm0
	cvttsd2si_r64_xmm(.RAX, .XMM0)
	emit_print_uint_in_rax(e)
	emit_print_char(e, '.')
	// frac: reload abs bits from the stable slot (print clobbered registers).
	mov_r64_m64(.RAX, val_slot)
	movabs_r64_imm64(.RCX, transmute(i64)u64(0x7FFFFFFFFFFFFFFF))
	write([]u8{0x48, 0x21, 0xC8}) // and rax, rcx  (abs)
	movq_xmm_r64(.XMM0, .RAX) // xmm0 = |value|
	cvttsd2si_r64_xmm(.RAX, .XMM0)
	cvtsi2sd_xmm_r64(.XMM1, .RAX)
	subsd_xmm_xmm(.XMM0, .XMM1)
	// xmm1 = 1e6
	movabs_r64_imm64(.RAX, transmute(i64)f64(1000000.0))
	movq_xmm_r64(.XMM1, .RAX)
	mulsd_xmm_xmm(.XMM0, .XMM1)
	cvttsd2si_r64_xmm(.RAX, .XMM0)
	// print rax as exactly 6 digits, zero-padded.
	emit_print_uint6(e)
}

// emit_load_arg realizes a ??N load+domain-normalization in the FEWEST
// instructions: load the value's address, then a single movzx/movsx/movsxd that
// reads only the domain's bytes and zero/sign-extends — the mask is FUSED into
// the load (no separate `and`/`shl/sar`). The address is absolute, so it goes
// through R11 first: `movabs r11, addr ; <load+extend> dst, [r11]`.
emit_load_arg :: proc(e: ^X64_Emit, v: bc.BC_Load_Arg) {
	mt := e.prog.value_types[int(v.dst)]
	rd, homed := home_reg(e, v.dst)
	dst := homed ? rd : Register64.RAX

	// RBX holds the ARGS_TABLE base (loaded once in emit_body). Each arg is a
	// displacement off it — `[rbx + 8*slot]` — instead of a 10-byte movabs of the
	// full address per arg.
	mem := MemoryAddress(AddressComponents{base = Register64.RBX, displacement = i32(8 * v.slot)})

	if bc.mtype_is_float(mt) {
		// Float ??: the arg stub already parsed the decimal (atof) and stored the
		// f64 BIT PATTERN in the table — load it straight into the value's home.
		mov_r64_m64(dst, mem)
		if !homed do store(e, v.dst, .RAX)
		return
	}

	// Integer: load + normalize to the declared width. When the value is computed
	// in 32-bit registers (width ≤ 32), use the 32-bit movzx/movsx form — one byte
	// shorter (no REX.W), and the 32-bit write zero-extends the upper half. Safe by
	// construction (the value fits its declared width).
	use32 := val_is_32bit(e, int(v.dst))
	switch v.width {
	case 8:
		if v.signed {
			if use32 {movsx_r32_m8(dst, mem)} else {movsx_r64_m8(dst, mem)}
		} else {
			if use32 {movzx_r32_m8(dst, mem)} else {movzx_r64_m8(dst, mem)}
		}
	case 16:
		if v.signed {
			if use32 {movsx_r32_m16(dst, mem)} else {movsx_r64_m16(dst, mem)}
		} else {
			if use32 {movzx_r32_m16(dst, mem)} else {movzx_r64_m16(dst, mem)}
		}
	case 32:
		if v.signed {
			movsxd_r64_m32(dst, mem) // sign-extend to 64 (i32 source may feed wider)
		} else {
			mov_r64d_m32(dst, mem) // zero-extends to 64 automatically
		}
	case:
		mov_r64_m64(dst, mem) // 64-bit / unsized
	}
	if !homed do store(e, v.dst, dst)
}

// emit_lea_root realizes a matched address mode as a single `lea dst, [mode]`.
// The dst's home register receives the result (or RAX then store, if spilled).
emit_lea_root :: proc(e: ^X64_Emit, dst: bc.BC_Value, am: X64_Address) {
	rd, homed := home_reg(e, dst)
	w := homed ? rd : Register64.RAX
	if val_is_32bit(e, int(dst)) {
		lea_r32_m(r32(w), addr_to_mem(am)) // 32-bit lea: no REX.W
	} else {
		lea_r64_m64(w, addr_to_mem(am))
	}
	if !homed do store(e, dst, w)
}

// --- body ------------------------------------------------------------------

emit_body :: proc(e: ^X64_Emit) -> string {
	// Load the ARGS_TABLE base into RBX once (it's reserved, never allocated), so
	// every BC_Load_Arg is a cheap `[rbx + 8*slot]` displacement load rather than a
	// 10-byte movabs of the full address each time.
	has_args := false
	for inst in e.prog.insts {
		if _, ok := inst.(bc.BC_Load_Arg); ok {has_args = true; break}
	}
	if has_args {
		emit_load_imm_into(e, .RBX, i64(ARGS_TABLE_VADDR))
	}

	// Instruction selection: find address-mode (lea) roots and the values they
	// absorb. An absorbed value is not emitted on its own; a root is emitted as a
	// single lea.
	roots := select_lea_roots(e)
	defer delete(roots)

	for inst in e.prog.insts {
		if d, has_d := bc_def(inst); has_d {
			// An intermediate node folded into a parent lea: don't emit it.
			if e.absorbed[d] do continue
			// A lea root: emit the whole matched address mode as one lea.
			if am, is_root := roots[d]; is_root {
				emit_lea_root(e, bc.BC_Value(d), am)
				continue
			}
		}
		switch v in inst {
		case bc.BC_Const:
			// A constant that genuinely lives in a register (e.g. `ret` of a bare
			// constant). Load the immediate straight into its home, no RAX detour.
			rd, ok := home_reg(e, v.dst)
			emit_load_imm_into(e, ok ? rd : .RAX, v.imm)
			if !ok do store(e, v.dst, .RAX)
		case bc.BC_Const_F:
			// Materialize the f64 bit pattern in RAX, store to the value's slot.
			movabs_r64_imm64(.RAX, transmute(i64)v.fimm)
			store(e, v.dst, .RAX)
		case bc.BC_Str_Const:
			// Load the absolute address of the string's bytes in .rodata.
			addr := e.rodata_vaddr + e.rodata_off[v.id]
			write([]u8{0x48, 0xB8}) // movabs rax, addr
			put_i64_bytes(e, i64(addr))
			store(e, v.dst, .RAX)
			e.str_len[int(v.dst)] = len(v.bytes)
		case bc.BC_Load_Arg:
			emit_load_arg(e, v)
		case bc.BC_Bin:
			if msg := emit_bin(e, v); msg != "" do return msg
		case bc.BC_Bin_Imm:
			if msg := emit_bin_imm(e, v); msg != "" do return msg
		case bc.BC_Cmp:
			emit_cmp(e, v)
		case bc.BC_Cmp_Imm:
			emit_cmp_imm(e, v)
		case bc.BC_Move:
			load(e, .RAX, v.src)
			store(e, v.dst, .RAX)
		case bc.BC_Label_Def:
			e.label_pos[int(v.label)] = e.buf.len
		case bc.BC_Jump:
			emit_jmp(e, v.target)
		case bc.BC_Branch_Zero:
			emit_brz(e, v.cond, v.target)
		case bc.BC_Ret:
			emit_exit(e, v.src)
		}
	}
	return ""
}

// emit_bin emits `dst = a op b`, applying immediate folding and strength
// reduction: a constant operand becomes an immediate, a multiply/divide/mod by a
// power of two becomes a shift/and, a multiply by 3/5/9 a single lea. The result
// register is RAX, then stored to dst's slot.
// emit_bin emits `dst = a op b` in register-register form. The immediate forms
// are handled by emit_bin_imm; here both operands are real values. Ring ops
// (add/sub/mul/and/or/xor) compute IN PLACE in dst's home register (x64 is
// 2-operand: `op dst, src`), the seed-mov elided when it coincides. idiv/mod and
// variable shifts use their fixed registers (RAX/RDX, CL).
emit_bin :: proc(e: ^X64_Emit, v: bc.BC_Bin) -> string {
	if bc.mtype_is_float(e.prog.value_types[int(v.dst)]) {
		return emit_bin_float(e, v)
	}

	#partial switch v.op {
	case .Divide:
		load(e, .RAX, v.a); load(e, .RCX, v.b)
		cqo(); idiv_r64(.RCX)
		store(e, v.dst, .RAX)
		return ""
	case .Mod:
		load(e, .RAX, v.a); load(e, .RCX, v.b)
		cqo(); idiv_r64(.RCX)
		store(e, v.dst, .RDX)
		return ""
	case .LShift:
		load(e, .RAX, v.a); load(e, .RCX, v.b) // count in CL
		shl_r64_cl(.RAX)
		store(e, v.dst, .RAX)
		return ""
	case .RShift:
		load(e, .RAX, v.a); load(e, .RCX, v.b)
		sar_r64_cl(.RAX)
		store(e, v.dst, .RAX)
		return ""
	}

	rd, dst_in_reg := home_reg(e, v.dst)
	work := dst_in_reg ? rd : Register64.RAX
	commutative := v.op == .Add || v.op == .Multiply || v.op == .BitAnd || v.op == .BitOr || v.op == .BitXor
	rb, b_in_reg := home_reg(e, v.b)

	// Seed `work` with one operand and pick the source register, never clobbering
	// an operand before it's read.
	src: Register64
	if commutative && b_in_reg && rb == work {
		src = .RCX
		load(e, src, v.a)
	} else if b_in_reg && rb != work {
		load(e, work, v.a)
		src = rb
	} else {
		src = .RCX
		load(e, src, v.b)
		load(e, work, v.a)
	}

	use32 := val_is_32bit(e, int(v.dst))
	#partial switch v.op {
	case .Add:
		if use32 {add_r32_r32(r32(work), r32(src))} else {add_r64_r64(work, src)}
	case .Subtract:
		if use32 {sub_r32_r32(r32(work), r32(src))} else {sub_r64_r64(work, src)}
	case .Multiply:
		if use32 {imul_r32_r32(r32(work), r32(src))} else {imul_r64_r64(work, src)}
	case .BitAnd:
		if use32 {and_r32_r32(r32(work), r32(src))} else {and_r64_r64(work, src)}
	case .BitOr:
		if use32 {or_r32_r32(r32(work), r32(src))} else {or_r64_r64(work, src)}
	case .BitXor:
		if use32 {xor_r32_r32(r32(work), r32(src))} else {xor_r64_r64(work, src)}
	case:
		return "x64: unsupported binary operator"
	}
	if work != rd || !dst_in_reg do store(e, v.dst, work)
	return ""
}

// emit_bin_imm emits `dst = a op #imm` with immediate folding and strength
// reduction: *2^k → shl, *3/5/9 → lea, *k → imul imm, unsigned /2^k → shr,
// unsigned %2^k → and, +0/-0/*1 elided, and/or/xor/add/sub take an imm32. The
// result computes in dst's home register `w` (or RAX if spilled).
emit_bin_imm :: proc(e: ^X64_Emit, v: bc.BC_Bin_Imm) -> string {
	if bc.mtype_is_float(e.prog.value_types[int(v.dst)]) {
		return emit_bin_imm_float(e, v)
	}
	unsigned := !bc.mtype_signed(e.prog.value_types[int(v.a)])
	k := v.imm
	use32 := val_is_32bit(e, int(v.dst))

	w, w_homed := home_reg(e, v.dst)
	if !w_homed do w = .RAX

	#partial switch v.op {
	case .Multiply:
		if emit_mul_const_into(e, w, v.a, k, use32) {dst_finish(e, v.dst, w, w_homed); return ""}
	case .Add:
		load(e, w, v.a)
		if k != 0 {
			if fits_imm32(k) {
				if use32 {add_r32_imm32(r32(w), u32(i32(k)))} else {add_r64_imm32(w, u32(i32(k)))}
			} else {
				movabs_r64_imm64(.RCX, k); add_r64_r64(w, .RCX)
			}
		}
		dst_finish(e, v.dst, w, w_homed)
		return ""
	case .Subtract:
		load(e, w, v.a)
		if k != 0 {
			if fits_imm32(k) {
				if use32 {sub_r32_imm32(r32(w), u32(i32(k)))} else {sub_r64_imm32(w, u32(i32(k)))}
			} else {
				movabs_r64_imm64(.RCX, k); sub_r64_r64(w, .RCX)
			}
		}
		dst_finish(e, v.dst, w, w_homed)
		return ""
	case .BitAnd:
		load(e, w, v.a)
		and_reg_imm(e, w, k)
		dst_finish(e, v.dst, w, w_homed)
		return ""
	case .BitOr:
		load(e, w, v.a)
		movabs_r64_imm64(.RCX, k); or_r64_r64(w, .RCX)
		dst_finish(e, v.dst, w, w_homed)
		return ""
	case .BitXor:
		load(e, w, v.a)
		movabs_r64_imm64(.RCX, k); xor_r64_r64(w, .RCX)
		dst_finish(e, v.dst, w, w_homed)
		return ""
	case .Divide:
		if unsigned {
			if sh, ok := log2_exact(k); ok {
				load(e, w, v.a)
				shr_r64_imm8(w, u8(sh))
				dst_finish(e, v.dst, w, w_homed)
				return ""
			}
		}
		// General signed/non-pow2 divide by an immediate: divisor in RCX.
		load(e, .RAX, v.a)
		movabs_r64_imm64(.RCX, k)
		cqo(); idiv_r64(.RCX)
		store(e, v.dst, .RAX)
		return ""
	case .Mod:
		if unsigned {
			if _, ok := log2_exact(k); ok {
				load(e, w, v.a)
				and_reg_imm(e, w, k - 1)
				dst_finish(e, v.dst, w, w_homed)
				return ""
			}
		}
		load(e, .RAX, v.a)
		movabs_r64_imm64(.RCX, k)
		cqo(); idiv_r64(.RCX)
		store(e, v.dst, .RDX)
		return ""
	case .LShift:
		load(e, w, v.a)
		shl_r64_imm8(w, u8(k & 63))
		dst_finish(e, v.dst, w, w_homed)
		return ""
	case .RShift:
		load(e, w, v.a)
		sar_r64_imm8(w, u8(k & 63))
		dst_finish(e, v.dst, w, w_homed)
		return ""
	}
	return "x64: unsupported immediate binary operator"
}

// emit_bin_imm_float: a float op against an integer immediate (rare — the
// reducer usually keeps float constants as BC_Const_F). Materialize the immediate
// as a double and use the register path.
emit_bin_imm_float :: proc(e: ^X64_Emit, v: bc.BC_Bin_Imm) -> string {
	load(e, .RAX, v.a)
	movq_xmm_r64(.XMM0, .RAX)
	movabs_r64_imm64(.RAX, transmute(i64)f64(v.imm))
	movq_xmm_r64(.XMM1, .RAX)
	#partial switch v.op {
	case .Add:
		addsd_xmm_xmm(.XMM0, .XMM1)
	case .Subtract:
		subsd_xmm_xmm(.XMM0, .XMM1)
	case .Multiply:
		mulsd_xmm_xmm(.XMM0, .XMM1)
	case .Divide:
		divsd_xmm_xmm(.XMM0, .XMM1)
	case:
		return "x64: unsupported immediate float operator"
	}
	movq_r64_xmm_bits(.RAX, .XMM0)
	store(e, v.dst, .RAX)
	return ""
}

// emit_bin_float emits a scalar-double op via XMM. Operand bits are loaded from
// their stack slots into XMM0/XMM1, the SSE op runs, and the result bits go back.
// f32 is computed in double then narrowed only at materialization (kept simple).
emit_bin_float :: proc(e: ^X64_Emit, v: bc.BC_Bin) -> string {
	load(e, .RAX, v.a)
	movq_xmm_r64(.XMM0, .RAX) // xmm0 = a
	load(e, .RAX, v.b)
	movq_xmm_r64(.XMM1, .RAX) // xmm1 = b
	#partial switch v.op {
	case .Add:
		addsd_xmm_xmm(.XMM0, .XMM1)
	case .Subtract:
		subsd_xmm_xmm(.XMM0, .XMM1)
	case .Multiply:
		mulsd_xmm_xmm(.XMM0, .XMM1)
	case .Divide:
		divsd_xmm_xmm(.XMM0, .XMM1)
	case:
		return "x64: unsupported float operator"
	}
	movq_r64_xmm_bits(.RAX, .XMM0) // rax = bits(xmm0)
	store(e, v.dst, .RAX)
	return ""
}

// emit_load_imm_rax loads an immediate into RAX with the SHORTEST encoding:
// `mov eax, imm32` (5 bytes, zero-extends to RAX) when the value fits in u32,
// `movabs rax, imm64` (10 bytes) otherwise. A common immediate-folding win.
emit_load_imm_rax :: proc(e: ^X64_Emit, v: i64) {
	emit_load_imm_into(e, .RAX, v)
}

// emit_load_imm_into loads an immediate into `reg` with the shortest encoding:
// `mov r32, imm32` (zero-extends to 64) when it fits in u32, `movabs r64, imm64`
// otherwise. Handles the REX.B prefix for the extended registers R8-R15.
emit_load_imm_into :: proc(e: ^X64_Emit, reg: Register64, v: i64) {
	if v >= 0 && v <= 0xFFFFFFFF {
		// [REX.B] B8+rd id : mov r32, imm32 (upper 32 bits zeroed).
		if (u8(reg) & 0x8) != 0 do write([]u8{0x41}) // REX.B for r8d..r15d
		u := u32(v)
		write([]u8{0xB8 | (u8(reg) & 0x7), u8(u), u8(u >> 8), u8(u >> 16), u8(u >> 24)})
		return
	}
	movabs_r64_imm64(reg, v)
}

// emit_print_char writes a single byte to stdout. Uses the red zone: push the
// char, write(1, rsp, 1), pop.
emit_print_char :: proc(e: ^X64_Emit, c: u8) {
	// mov byte ptr [rsp-1], c ; lea rsi, [rsp-1] ; write(1, rsi, 1)
	write([]u8{0xC6, 0x44, 0x24, 0xFF, c}) // mov byte [rsp-1], c
	write([]u8{0x48, 0x8D, 0x74, 0x24, 0xFF}) // lea rsi, [rsp-1]
	emit_load_imm_into(e, .RDX, 1) // len 1
	emit_load_imm_into(e, .RDI, 1) // fd 1
	emit_load_imm_into(e, .RAX, 1) // sys_write
	syscall()
}

// emit_print_uint_in_rax prints the unsigned integer in RAX as decimal (no
// leading zeros, "0" if zero). Builds digits backwards into [rsp-32..] then
// write()s them. Clobbers rax,rcx,rdx,rsi,rdi,r8,r9.
emit_print_uint_in_rax :: proc(e: ^X64_Emit) {
	// r8 = rax (value) ; r9 = &buf_end = rsp-1 ; ten in rcx.
	write([]u8{0x49, 0x89, 0xC0}) // mov r8, rax
	write([]u8{0x4C, 0x8D, 0x4C, 0x24, 0xE0}) // lea r9, [rsp-32]  (buffer start)
	// We'll fill forward from a cursor and track count. Simpler: classic reverse.
	// Use [rsp-1] downward as the digit area; r9 = cursor = rsp-1.
	write([]u8{0x4C, 0x8D, 0x4C, 0x24, 0xFF}) // lea r9, [rsp-1]
	movabs_r64_imm64(.RCX, 10)
	// loop: rdx:rax = r8 ; div rcx ; digit = rdx ; store; r8 = rax(quotient)
	loop := e.buf.len
	write([]u8{0x4C, 0x89, 0xC0}) // mov rax, r8
	write([]u8{0x48, 0x31, 0xD2}) // xor rdx, rdx
	write([]u8{0x48, 0xF7, 0xF1}) // div rcx  (unsigned)
	write([]u8{0x49, 0x89, 0xC0}) // mov r8, rax (quotient)
	// dl += '0' ; store [r9], dl ; r9--
	write([]u8{0x80, 0xC2, 0x30}) // add dl, '0'
	write([]u8{0x41, 0x88, 0x11}) // mov [r9], dl
	write([]u8{0x49, 0xFF, 0xC9}) // dec r9
	// if r8 != 0 loop
	write([]u8{0x4D, 0x85, 0xC0}) // test r8, r8
	write([]u8{0x75}) // jnz loop
	back := e.buf.len; write([]u8{0})
	e.buf.data[back] = u8(i8(loop - (back + 1)))
	// write(1, r9+1, (rsp-1)-(r9)) : rsi = r9+1 ; rdx = (rsp-1) - r9
	write([]u8{0x49, 0xFF, 0xC1}) // inc r9  (now points at first digit)
	write([]u8{0x4C, 0x89, 0xCE}) // mov rsi, r9
	// rdx = (rsp-1) - r9 + 1  = rsp - r9
	write([]u8{0x48, 0x89, 0xE2}) // mov rdx, rsp
	write([]u8{0x4C, 0x29, 0xCA}) // sub rdx, r9
	emit_load_imm_into(e, .RDI, 1)
	emit_load_imm_into(e, .RAX, 1)
	syscall()
}

// emit_print_uint6 prints RAX as exactly 6 zero-padded decimal digits.
emit_print_uint6 :: proc(e: ^X64_Emit) {
	// r8 = value ; r9 = rsp-1 ; write 6 digits backwards.
	write([]u8{0x49, 0x89, 0xC0}) // mov r8, rax
	write([]u8{0x4C, 0x8D, 0x4C, 0x24, 0xFF}) // lea r9, [rsp-1]
	movabs_r64_imm64(.RCX, 10)
	movabs_r64_imm64(.RSI, 6) // counter
	loop := e.buf.len
	write([]u8{0x4C, 0x89, 0xC0}) // mov rax, r8
	write([]u8{0x48, 0x31, 0xD2}) // xor rdx, rdx
	write([]u8{0x48, 0xF7, 0xF1}) // div rcx
	write([]u8{0x49, 0x89, 0xC0}) // mov r8, rax
	write([]u8{0x80, 0xC2, 0x30}) // add dl, '0'
	write([]u8{0x41, 0x88, 0x11}) // mov [r9], dl
	write([]u8{0x49, 0xFF, 0xC9}) // dec r9
	write([]u8{0x48, 0xFF, 0xCE}) // dec rsi
	write([]u8{0x48, 0x85, 0xF6}) // test rsi, rsi
	write([]u8{0x75}) // jnz loop
	back := e.buf.len; write([]u8{0})
	e.buf.data[back] = u8(i8(loop - (back + 1)))
	// write(1, r9+1, 6)
	write([]u8{0x49, 0xFF, 0xC1}) // inc r9
	write([]u8{0x4C, 0x89, 0xCE}) // mov rsi, r9
	emit_load_imm_into(e, .RDX, 6)
	emit_load_imm_into(e, .RDI, 1)
	emit_load_imm_into(e, .RAX, 1)
	syscall()
}

// emit_mul_const lowers x*k with strength reduction. Returns false if it falls
// through to the general imul path (handled by the caller). Result in RAX.
// emit_mul_const_into lowers x*k with strength reduction, leaving the result in
// `w`. Returns false (caller uses the general imul path) only for a constant too
// large for an imm32 that isn't a power of two.
emit_mul_const_into :: proc(e: ^X64_Emit, w: Register64, x: bc.BC_Value, k: i64, use32: bool) -> bool {
	switch {
	case k == 0:
		if use32 {xor_r32_r32(r32(w), r32(w))} else {xor_r64_r64(w, w)} // *0 → 0
		return true
	case k == 1:
		load(e, w, x) // *1 → identity
		return true
	}
	if sh, ok := log2_exact(k); ok {
		load(e, w, x)
		if use32 {shl_r32_imm8(r32(w), u8(sh))} else {shl_r64_imm8(w, u8(sh))} // *2^k → shl
		return true
	}
	// `*{3,5,9}` -> one lea [src + src*scale], scale = k-1 in {2,4,8}.
	if k == 3 || k == 5 || k == 9 {
		emit_lea_self(e, w, mul_base(e, x), u8(k - 1), use32)
		return true
	}

	// Two-instruction decompositions, a la clang/LLVM (lea/shl: 1 cycle, two ports;
	// beats imul's 3-cycle latency). Fallback to imul for constants that don't
	// factor into <=2 lea/shl steps.
	if lo, lf, ok := mul_pow2_lea(k); ok {
		// k = 2^lo * {3,5,9}: shl the value by lo, then lea *lf.
		load(e, w, x)
		if use32 {shl_r32_imm8(r32(w), u8(lo))} else {shl_r64_imm8(w, u8(lo))}
		emit_lea_self(e, w, w, u8(lf - 1), use32)
		return true
	}
	if f1, f2, ok := mul_lea_lea(k); ok {
		// k = f1 * f2 with f1,f2 in {3,5,9}: lea *f1 then lea *f2.
		emit_lea_self(e, w, mul_base(e, x), u8(f1 - 1), use32)
		emit_lea_self(e, w, w, u8(f2 - 1), use32)
		return true
	}

	// Fallback: imul w, x, k.
	load(e, w, x)
	if fits_imm32(k) {
		if use32 {
			imul_r32_imm32(r32(w), u32(i32(k)))
		} else {
			imul_r64_r64_imm32(w, w, u32(i32(k)))
		}
		return true
	}
	return false
}

// mul_base loads x into a register usable as a SIB base and returns it (x's home
// if it can be a base, else RCX).
mul_base :: proc(e: ^X64_Emit, x: bc.BC_Value) -> Register64 {
	if rx, ok := home_reg(e, x); ok && rx != .RBP && rx != .R13 {
		return rx
	}
	load(e, .RCX, x)
	return .RCX
}

// emit_lea_self emits `lea w, [base + base*scale]` (= base * (scale+1)), 32/64-bit.
emit_lea_self :: proc(e: ^X64_Emit, w, base: Register64, scale: u8, use32: bool) {
	mem := MemoryAddress(AddressComponents{base = base, index = base, scale = scale})
	if use32 {lea_r32_m(r32(w), mem)} else {lea_r64_m64(w, mem)}
}

// mul_pow2_lea: k = 2^lo * lf with lo >= 1 and lf in {3,5,9}.
mul_pow2_lea :: proc(k: i64) -> (lo: int, lf: i64, ok: bool) {
	v := k
	lo = 0
	for v % 2 == 0 {v /= 2; lo += 1}
	if lo == 0 do return 0, 0, false
	if v == 3 || v == 5 || v == 9 do return lo, v, true
	return 0, 0, false
}

// mul_lea_lea: k = f1 * f2 with both in {3,5,9} (covers 9,15,25,27,45,81).
mul_lea_lea :: proc(k: i64) -> (f1: i64, f2: i64, ok: bool) {
	for a in ([3]i64{3, 5, 9}) {
		if k % a == 0 {
			b := k / a
			if b == 3 || b == 5 || b == 9 do return a, b, true
		}
	}
	return 0, 0, false
}

// dst_finish stores `w` into dst's slot if w isn't already dst's home register.
dst_finish :: proc(e: ^X64_Emit, dst: bc.BC_Value, w: Register64, w_homed: bool) {
	if !w_homed {
		store(e, dst, w) // spilled dst: w is RAX, write to memory
		return
	}
	home, _ := home_reg(e, dst)
	if home != w do mov_r64_r64(home, w)
}

// bc_const_operand: if exactly one of a/b is a constant, return (k, x) with k the
// constant value and x the variable operand.
// log2_exact returns the shift amount if k is a positive power of two.
log2_exact :: proc(k: i64) -> (int, bool) {
	if k <= 0 do return 0, false
	if (k & (k - 1)) != 0 do return 0, false
	sh := 0
	v := k
	for v > 1 {v >>= 1; sh += 1}
	return sh, true
}

fits_imm32 :: proc(k: i64) -> bool {
	return k >= -2147483648 && k <= 2147483647
}

// and_rax_imm: and rax, imm (imm32 if it fits, else via rcx).
// and_reg_imm: and reg, imm (imm32 if it fits, REX.B for r8-r15; else via RCX).
and_reg_imm :: proc(e: ^X64_Emit, reg: Register64, k: i64) {
	if fits_imm32(k) {
		// [REX.W|REX.B] 81 /4 id : and r/m64, imm32. modrm = C0 | (4<<3?) — for
		// the /4 opcode extension the reg field is 4, rm is the target register.
		rex: u8 = 0x48 | ((u8(reg) & 0x8) >> 3) // REX.W + REX.B
		modrm: u8 = 0xE0 | (u8(reg) & 0x7) // mod=11, /4 (reg=100), rm=reg
		write([]u8{rex, 0x81, modrm})
		u := transmute(u32)i32(k)
		write([]u8{u8(u), u8(u >> 8), u8(u >> 16), u8(u >> 24)})
	} else {
		// RCX is a scratch (never an allocatable home), safe to clobber here.
		movabs_r64_imm64(.RCX, k)
		and_r64_r64(reg, .RCX)
	}
}

// emit_lea_reg_base_index: lea dst, [base + base*scale]. scale ∈ {2,4,8} via SIB,
// implementing x*3 / x*5 / x*9. Handles REX for extended dst/base registers.
emit_lea_reg_base_index :: proc(e: ^X64_Emit, dst: Register64, base: Register64, scale: u8) {
	ss: u8 = scale == 2 ? 1 : (scale == 4 ? 2 : 3) // log2(scale)
	// REX.W + REX.R (dst high bit) + REX.X & REX.B (base is both index and base).
	rex: u8 = 0x48
	if (u8(dst) & 0x8) != 0 do rex |= 0x4 // REX.R
	if (u8(base) & 0x8) != 0 do rex |= 0x2 | 0x1 // REX.X | REX.B (base used twice)
	// modrm: mod=00, reg=dst(low3), rm=100 (SIB follows).
	modrm: u8 = (u8(dst) & 0x7) << 3 | 0x04
	// SIB: scale=ss, index=base(low3), base=base(low3).
	sib: u8 = (ss << 6) | ((u8(base) & 0x7) << 3) | (u8(base) & 0x7)
	write([]u8{rex, 0x8D, modrm, sib})
}

// emit_cmp: rax = (a <op> b) ? 1 : 0 via cmp + setcc + movzx.
emit_cmp :: proc(e: ^X64_Emit, v: bc.BC_Cmp) {
	load(e, .RAX, v.a)
	load(e, .RCX, v.b)
	cmp_r64_r64(.RAX, .RCX)
	#partial switch v.op {
	case .Equal:
		sete_r8(.AL)
	case .NotEqual:
		setne_r8(.AL)
	case .Less:
		setl_r8(.AL)
	case .Greater:
		setg_r8(.AL)
	case .LessEqual:
		setle_r8(.AL)
	case .GreaterEqual:
		setge_r8(.AL)
	}
	movzx_r64_r8(.RAX, .AL)
	store(e, v.dst, .RAX)
}

emit_cmp_setcc :: proc(op: bc.BC_Op) {
	#partial switch op {
	case .Equal:        sete_r8(.AL)
	case .NotEqual:     setne_r8(.AL)
	case .Less:         setl_r8(.AL)
	case .Greater:      setg_r8(.AL)
	case .LessEqual:    setle_r8(.AL)
	case .GreaterEqual: setge_r8(.AL)
	}
}

// emit_cmp_imm: dst = (a op #imm) ? 1 : 0  via cmp r, imm32 + setcc + movzx.
emit_cmp_imm :: proc(e: ^X64_Emit, v: bc.BC_Cmp_Imm) {
	load(e, .RAX, v.a)
	if fits_imm32(v.imm) {
		cmp_r64_imm32(.RAX, u32(i32(v.imm)))
	} else {
		movabs_r64_imm64(.RCX, v.imm)
		cmp_r64_r64(.RAX, .RCX)
	}
	emit_cmp_setcc(v.op)
	movzx_r64_r8(.RAX, .AL)
	store(e, v.dst, .RAX)
}

// --- jumps (two-pass) ------------------------------------------------------

emit_jmp :: proc(e: ^X64_Emit, label: bc.BC_Label) {
	// jmp rel32 : E9 cd
	write([]u8{0xE9})
	at := e.buf.len
	write([]u8{0, 0, 0, 0})
	append(&e.fixups, X64_Fixup{at = at, label = label})
}

emit_brz :: proc(e: ^X64_Emit, cond: bc.BC_Value, label: bc.BC_Label) {
	// test the cond register, then je rel32 (jump if zero).
	load(e, .RAX, cond)
	test_r64_r64(.RAX, .RAX)
	write([]u8{0x0F, 0x84}) // je rel32
	at := e.buf.len
	write([]u8{0, 0, 0, 0})
	append(&e.fixups, X64_Fixup{at = at, label = label})
}

patch_fixups :: proc(e: ^X64_Emit) {
	for f in e.fixups {
		target := e.label_pos[int(f.label)]
		// rel32 is measured from the END of the 4-byte field.
		rel := i32(target - (f.at + 4))
		u := transmute(u32)rel
		e.buf.data[f.at + 0] = u8(u & 0xFF)
		e.buf.data[f.at + 1] = u8((u >> 8) & 0xFF)
		e.buf.data[f.at + 2] = u8((u >> 16) & 0xFF)
		e.buf.data[f.at + 3] = u8((u >> 24) & 0xFF)
	}
}
