package x64_assembler

import bc "../../bytecode"

// ============================================================================
// x64 EMITTER — bytecode → x86-64 machine code (.text bytes).
//
// Consumes the target-neutral bc.BC_Program and emits x86-64 using the tested
// assembler in backends/x64 (encodings validated against objdump). The linear-scan
// allocator (regalloc.odin) runs FIRST: load/store/home_reg consult e.alloc, so a
// value that lives in a register is read/written in place and only spilled values
// touch the frame. The instruction selector (isel.odin) folds add/sub/scale trees
// into single LEAs, and emit_bin applies strength reduction (shl/lea/magic-div).
//
// Work registers kept free of the allocatable pool: RAX/RDX (the imul/idiv pair),
// RCX (the shift count). Result is returned via the exit-status syscall (integer
// programs), stdout for strings/floats.
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

// emit_arg_stub parses argv[1..] into ARGS_TABLE[slot]. The common case (all
// integer ??) is ONE compact generic loop running inline atoi over argv[1..] —
// no per-slot unrolling, so the stub stays tiny. Only when the program has FLOAT
// ?? slots do we add a small SECOND pass that re-parses just those slots with the
// inline atof (overwriting their integer value with the f64 bit pattern). So a
// float program pays only for its float slots; an integer program is unchanged.
//
// At process entry rsp -> argc, then the argv pointers; argv[K+1] is the K-th ??.
// Registers: r12=argc, r13=&argv[0], r14=K. atoi/atof clobber rax/rcx/rdx/rsi/rdi
// (+xmm for atof). R11 holds the ARGS_TABLE base.
emit_arg_stub :: proc(e: ^X64_Emit) {
	_, is_float := arg_slot_info(e)
	defer delete(is_float)

	// --- generic atoi loop over all of argv[1..] ---
	rsp0 := MemoryAddress(AddressComponents{base = Register64.RSP}) // [rsp] = argc
	argv0 := MemoryAddress(AddressComponents{base = Register64.RSP, displacement = 8}) // &argv[0]
	mov_r64_m64(.R12, rsp0) // r12 = argc
	lea_r64_m64(.R13, argv0) // r13 = &argv[0]
	xor_r64_r64(.R14, .R14) // K = 0
	// Hoist the ARGS_TABLE base OUT of the loop — it's constant, and atoi clobbers
	// only rax/rcx/rdx/r8, never r11. Loading it once instead of per-arg.
	emit_load_imm_into(e, .R11, i64(ARGS_TABLE_VADDR))

	loop_start := here(e)
	mov_r64_r64(.RAX, .R14)
	inc_r64(.RAX)
	cmp_r64_r64(.RAX, .R12)
	to_done := forward32(e, jge_rel32)

	// rdi = argv[K+1] = [r13 + rax*8]
	mov_r64_m64(.RDI, MemoryAddress(AddressComponents{base = Register64.R13, index = Register64.RAX, scale = 8}))
	emit_atoi(e) // atoi(rdi) → rax
	// ARGS_TABLE[K] = rax → [r11 + r14*8]
	mov_m64_r64(MemoryAddress(AddressComponents{base = Register64.R11, index = Register64.R14, scale = 8}), .RAX)
	inc_r64(.R14)
	back32(e, jmp_rel32, loop_start, 5) // jmp loop_start (5-byte rel32 jmp)

	bind32(e, to_done)

	// --- float fixup: re-parse only the float slots with atof ---
	if len(is_float) == 0 do return
	// R11 still holds the ARGS_TABLE base from the loop. r13 = &argv[0], r12 = argc.
	for slot, _ in is_float {
		// Guard: skip if argv[slot+1] is missing (cmp r12, slot+1 ; jle skip).
		cmp_r64_imm32(.R12, u32(slot + 1))
		to_skip := forward32(e, jle_rel32)

		mov_r64_m64(.RDI, MemoryAddress(AddressComponents{base = Register64.R13, displacement = i32(8 * (slot + 1))}))
		emit_atof(e) // f64 bits → rax
		emit_load_imm_into(e, .R11, i64(ARGS_TABLE_VADDR)) // atof may clobber; reload base
		mov_m64_r64(MemoryAddress(AddressComponents{base = Register64.R11, displacement = i32(8 * slot)}), .RAX)

		bind32(e, to_skip)
	}
}

put_u32 :: proc(e: ^X64_Emit, v: u32) {
	write([]u8{u8(v & 0xFF), u8((v >> 8) & 0xFF), u8((v >> 16) & 0xFF), u8((v >> 24) & 0xFF)})
}

// --- local rel8 labels -----------------------------------------------------
//
// Minimal forward/backward jump bookkeeping for self-contained code (atoi/atof):
// short-range jumps inside one proc that don't go through the program's BC_Label
// fixup table. The assembler's jcc procs write opcode+rel8 together, so a FORWARD
// jump emits with rel8=0 then back-patches the displacement byte once the target
// is bound; a BACKWARD jump computes the displacement up front (target known).
//
// `here()` is the current byte position (a backward target / a fixup's base).
// `forward(jcc)` emits the jcc and returns the displacement byte's index to patch.
// `bind(at)` patches a forward jump to land at the current position.
// `back(jcc, target)` emits a jcc reaching an already-bound `target`.

here :: #force_inline proc(e: ^X64_Emit) -> int {return e.buf.len}

// forward emits a 1-byte-displacement jcc (via the assembler proc) with a 0
// placeholder, and returns the index of that displacement byte to bind() later.
forward :: proc(e: ^X64_Emit, jcc: proc(_: i8)) -> int {
	jcc(0)
	return e.buf.len - 1 // the rel8 byte the proc just wrote
}

// bind patches a forward jump's displacement so it lands at the current position.
bind :: proc(e: ^X64_Emit, disp_at: int) {
	e.buf.data[disp_at] = u8(i8(e.buf.len - (disp_at + 1)))
}

// back emits a jcc reaching an already-known target; the proc writes the correct
// rel8 directly (no patching needed).
back :: proc(e: ^X64_Emit, jcc: proc(_: i8), target: int) {
	// after the 2-byte jcc, rip = (here+2); rel8 = target - (here+2).
	jcc(i8(target - (e.buf.len + 2)))
}

// rel32 variants — for forward jumps whose distance may exceed a signed byte.
forward32 :: proc(e: ^X64_Emit, jcc: proc(_: i32)) -> int {
	jcc(0)
	return e.buf.len - 4 // the 4-byte rel32 the proc just wrote
}

bind32 :: proc(e: ^X64_Emit, disp_at: int) {
	patch_rel32(e, disp_at, i32(e.buf.len - (disp_at + 4)))
}

// back32 emits a rel32 jcc/jmp reaching an already-known target. The proc writes
// opcode + rel32; rel32 = target - (rip after the instruction). jmp is 5 bytes
// (1 opcode + 4), jcc is 6 (2 + 4) — pass the instruction's total length.
back32 :: proc(e: ^X64_Emit, jcc: proc(_: i32), target: int, instr_len: int) {
	jcc(i32(target - (e.buf.len + instr_len)))
}

// emit_atoi: parse the NUL-terminated string at rdi into rax (signed decimal).
// Matches clang/gcc -O3's hot loop: a single UNSIGNED range check per digit
// (`d = c-'0' ; cmp $9 ; ja` — one compare, one branch, vs the naïve two), and
// software pipelining (the NEXT char is loaded at the bottom of the body so its
// load overlaps the current digit's arithmetic). acc=rax, sign=r8b.
// Clobbers rax,rcx,rdx,r8,rdi.
emit_atoi :: proc(e: ^X64_Emit) {
	at_rdi := MemoryAddress(AddressComponents{base = Register64.RDI}) // [rdi]
	dec_rcx := MemoryAddress(AddressComponents{base = Register64.RCX, displacement = -0x30}) // [rcx-'0']
	xor_r64_r64(.RAX, .RAX) // acc = 0
	xor_r64_r64(.R8, .R8) // sign = 0
	// leading '-' : if [rdi]=='-', sign=1, rdi++.
	mov_r8_m8(.CL, at_rdi) // cl = [rdi]
	cmp_r8_imm8(.CL, '-')
	no_sign := forward(e, jne_rel8)
	mov_r8_imm8(.R8B, 1) // sign = 1
	inc_r64(.RDI)
	bind(e, no_sign)

	// First char + range check (peeled prologue so the loop tests before it loads).
	movzx_r32_m8(.RCX, at_rdi) // ecx = (c)
	lea_r32_m(.EDX, dec_rcx) // edx = c-'0'
	cmp_r8_imm8(.DL, 9)
	to_end := forward32(e, ja_rel32) // c not a digit → end (unsigned wraps c<'0' high)

	// digit loop body: acc = acc*10 + (c-'0'), then load + range-check the NEXT
	// char at the bottom (pipelined). ecx holds the current ascii byte.
	dloop := here(e)
	lea_r32_m(.EAX, MemoryAddress(AddressComponents{base = Register64.RAX, index = Register64.RAX, scale = 4})) // acc*5
	lea_r32_m(.EAX, MemoryAddress(AddressComponents{base = Register64.RCX, index = Register64.RAX, scale = 2, displacement = -0x30})) // acc*10 + c - '0'
	inc_r64(.RDI)
	movzx_r32_m8(.RCX, at_rdi) // next c
	lea_r32_m(.EDX, dec_rcx) // next d
	cmp_r8_imm8(.DL, 10)
	back(e, jb_rel8, dloop) // d < 10 → still a digit

	// end: bind the prologue's range-check jump, then apply sign.
	bind32(e, to_end)
	test_r8_r8(.R8B, .R8B)
	keep := forward(e, je_rel8) // sign==0 → skip neg
	neg_r64(.RAX)
	bind(e, keep)
}

// emit_atof: parse the NUL-terminated decimal string at rdi into the f64 BIT
// PATTERN in rax. Handles a leading '-', an integer part, and an optional
// '.'-fraction (`-3.14`, `42`, `.5`). Computed as
//     value = (ipart + frac/scale) * sign,  scale = 10^(#frac digits)
// in scalar SSE, then movq'd back to rax. Not the hot path (one-shot arg
// parsing), so it favors clarity over cycle count. Clobbers rax,rcx,rdx,r8,r9,
// r10,r15,xmm0,xmm1,xmm2.
emit_atof :: proc(e: ^X64_Emit) {
	at_rdi := MemoryAddress(AddressComponents{base = Register64.RDI}) // [rdi]
	NEG30 :: u8(0xD0) // -0x30 as imm8 (add by it = sub 0x30)

	// r8=sign(0/1), r9=ipart, r10=frac, r15=scale(=1, ×10 per frac digit).
	xor_r64_r64(.R8, .R8) // sign = 0
	xor_r64_r64(.R9, .R9) // ipart = 0
	xor_r64_r64(.R10, .R10) // frac = 0
	emit_load_imm_into(e, .R15, 1) // scale = 1

	// leading '-' ?
	mov_r8_m8(.CL, at_rdi)
	cmp_r8_imm8(.CL, '-')
	no_sign := forward(e, jne_rel8)
	mov_r8_imm8(.R8B, 1) // sign = 1
	inc_r64(.RDI)
	bind(e, no_sign)

	// integer-part loop: r9 = r9*10 + digit.
	iloop := here(e)
	mov_r8_m8(.CL, at_rdi)
	cmp_r8_imm8(.CL, '0')
	i_jl := forward(e, jl_rel8) // < '0' → after int
	cmp_r8_imm8(.CL, '9')
	i_jg := forward(e, jg_rel8) // > '9' → after int
	movzx_r32_r8(.ECX, .CL)
	add_r32_imm8(.ECX, NEG30) // ecx = digit (c - '0')
	imul_r64_imm32(.R9, 10) // r9 *= 10
	add_r64_r64(.R9, .RCX) // r9 += digit
	inc_r64(.RDI)
	back(e, jmp_rel8, iloop)
	bind(e, i_jl)
	bind(e, i_jg)

	// '.' ?  if [rdi]=='.', inc rdi and parse fraction; else skip.
	mov_r8_m8(.CL, at_rdi)
	cmp_r8_imm8(.CL, '.')
	no_dot := forward(e, jne_rel8) // not '.' → after frac
	inc_r64(.RDI)

	floop := here(e)
	mov_r8_m8(.CL, at_rdi)
	cmp_r8_imm8(.CL, '0')
	f_jl := forward(e, jl_rel8)
	cmp_r8_imm8(.CL, '9')
	f_jg := forward(e, jg_rel8)
	movzx_r32_r8(.ECX, .CL)
	add_r32_imm8(.ECX, NEG30) // ecx = digit
	imul_r64_imm32(.R10, 10) // r10 *= 10
	add_r64_r64(.R10, .RCX) // r10 += digit
	imul_r64_imm32(.R15, 10) // r15 *= 10
	inc_r64(.RDI)
	back(e, jmp_rel8, floop)
	bind(e, no_dot)
	bind(e, f_jl)
	bind(e, f_jg)

	// value = ipart + frac/scale  (all in xmm0).
	cvtsi2sd_xmm_r64(.XMM0, .R9) // xmm0 = (double)ipart
	cvtsi2sd_xmm_r64(.XMM1, .R10) // xmm1 = (double)frac
	cvtsi2sd_xmm_r64(.XMM2, .R15) // xmm2 = (double)scale
	divsd_xmm_xmm(.XMM1, .XMM2) // xmm1 = frac/scale
	addsd_xmm_xmm(.XMM0, .XMM1) // xmm0 = ipart + frac/scale
	// sign: if r8b, xmm0 = -xmm0  (flip sign bit).
	test_r8_r8(.R8B, .R8B)
	no_neg := forward(e, je_rel8) // sign==0 → done
	movq_r64_xmm_bits(.RAX, .XMM0)
	movabs_r64_imm64(.RCX, transmute(i64)u64(0x8000000000000000))
	xor_r64_r64(.RAX, .RCX) // flip the sign bit
	movq_xmm_r64(.XMM0, .RAX)
	bind(e, no_neg)

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
	// push rbp ; mov rbp, rsp ; sub rsp, frame. This only reserves the spill area;
	// the ??N arguments are NOT in the frame — emit_arg_stub parses argv[1..] into
	// the ARGS_TABLE before the prologue, and emit_load_arg reads each slot from
	// there. The frame is purely for register spills under pressure.
	push_r64(.RBP)
	mov_r64_r64(.RBP, .RSP)
	sub_r64_imm32(.RSP, u32(frame))
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
	test_r64_r64(.RAX, .RCX)
	over_sign := forward(e, je_rel8) // sign bit clear → skip '-'
	emit_print_char(e, '-')
	bind(e, over_sign)

	// abs: reload bits from the stable slot, clear the sign bit, into xmm0.
	mov_r64_m64(.RAX, val_slot)
	movabs_r64_imm64(.RCX, transmute(i64)u64(0x7FFFFFFFFFFFFFFF))
	and_r64_r64(.RAX, .RCX) // abs
	movq_xmm_r64(.XMM0, .RAX)

	// ipart = cvttsd2si rax, xmm0
	cvttsd2si_r64_xmm(.RAX, .XMM0)
	emit_print_uint_in_rax(e)
	emit_print_char(e, '.')
	// frac: reload abs bits from the stable slot (print clobbered registers).
	mov_r64_m64(.RAX, val_slot)
	movabs_r64_imm64(.RCX, transmute(i64)u64(0x7FFFFFFFFFFFFFFF))
	and_r64_r64(.RAX, .RCX) // abs
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

	// Peephole: `0 - b` is a single `neg`. The reducer can't fold a literal-zero
	// left operand into the BC_Bin, so it arrives as a BC_Const here; turn the
	// whole subtract into one `neg b` instead of `mov $0 ; sub`.
	if v.op == .Subtract {
		if k, ok := bc_const_of(e, v.a); ok && k == 0 {
			use32 := val_is_32bit(e, int(v.dst))
			rd, dst_in_reg := home_reg(e, v.dst)
			w := dst_in_reg ? rd : Register64.RAX
			load(e, w, v.b)
			if use32 {neg_r32(r32(w))} else {neg_r64(w)}
			if !dst_in_reg do store(e, v.dst, w)
			return ""
		}
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
		if k == -1 {
			// `a * -1` is a single `neg` (vs `imul a,-1`).
			load(e, w, v.a)
			if use32 {neg_r32(r32(w))} else {neg_r64(w)}
			dst_finish(e, v.dst, w, w_homed)
			return ""
		}
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
		if unsigned && k > 0 {
			if sh, ok := log2_exact(k); ok {
				load(e, w, v.a)
				shr_r64_imm8(w, u8(sh))
				dst_finish(e, v.dst, w, w_homed)
				return ""
			}
			// Unsigned divide by a non-pow2 constant → multiply-high + shift
			// (Granlund-Montgomery magic), replacing a ~20-40cy idiv. The dividend
			// is zero-extended into a 64-bit register (BC_Load_Arg/32-bit writes
			// already clear the upper half for an unsigned value), so the 64-bit
			// magic is exact over the value's whole range.
			emit_udiv_magic(e, w, v.a, k)
			dst_finish(e, v.dst, w, w_homed)
			return ""
		}
		// General signed/non-pow2 divide by an immediate: divisor in RCX.
		load(e, .RAX, v.a)
		movabs_r64_imm64(.RCX, k)
		cqo(); idiv_r64(.RCX)
		store(e, v.dst, .RAX)
		return ""
	case .Mod:
		if unsigned && k > 0 {
			if _, ok := log2_exact(k); ok {
				load(e, w, v.a)
				and_reg_imm(e, w, k - 1)
				dst_finish(e, v.dst, w, w_homed)
				return ""
			}
			// a % k = a - (a / k) * k, with a / k via the magic sequence. Compute
			// the quotient into RAX, q*k into RAX, then a - that. RCX/RDX are the
			// magic scratch (idiv pair / shift count — never allocatable homes).
			emit_udiv_magic(e, .RAX, v.a, k) // RAX = a / k
			if fits_imm32(k) {imul_r64_r64_imm32(.RAX, .RAX, u32(i32(k)))} else {movabs_r64_imm64(.RCX, k); imul_r64_r64(.RAX, .RCX)} // RAX = q*k
			load(e, w == .RAX ? .RCX : w, v.a) // bring a into a reg distinct from RAX
			areg := w == .RAX ? Register64.RCX : w
			sub_r64_r64(areg, .RAX) // areg = a - q*k
			if areg != w do mov_r64_r64(w, areg)
			dst_finish(e, v.dst, w, w_homed)
			return ""
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
		// mov r32, imm32 zero-extends to 64 — shorter than movabs. The assembler's
		// proc handles the REX.B prefix for r8d..r15d (r32 shares the r64 index).
		mov_r32_imm32(r32(reg), u32(v))
		return
	}
	movabs_r64_imm64(reg, v)
}

// emit_print_char writes a single byte to stdout. Uses the red zone: push the
// char, write(1, rsp, 1), pop.
emit_print_char :: proc(e: ^X64_Emit, c: u8) {
	rsp_m1 := MemoryAddress(AddressComponents{base = Register64.RSP, displacement = -1})
	// stage the char in a scratch byte, store it to [rsp-1], then write(1, rsp-1, 1).
	mov_r8_imm8(.AL, c)
	mov_m8_r8(rsp_m1, .AL)
	lea_r64_m64(.RSI, rsp_m1)
	emit_load_imm_into(e, .RDX, 1) // len 1
	emit_load_imm_into(e, .RDI, 1) // fd 1
	emit_load_imm_into(e, .RAX, 1) // sys_write
	syscall()
}

// emit_print_uint_in_rax prints the unsigned integer in RAX as decimal (no
// leading zeros, "0" if zero). Builds digits backwards into [rsp-32..] then
// write()s them. Clobbers rax,rcx,rdx,rsi,rdi,r8,r9.
emit_print_uint_in_rax :: proc(e: ^X64_Emit) {
	at_r9 := MemoryAddress(AddressComponents{base = Register64.R9}) // [r9]
	// r8 = value ; r9 = digit cursor = [rsp-1], filled backwards ; rcx = 10.
	mov_r64_r64(.R8, .RAX)
	lea_r64_m64(.R9, MemoryAddress(AddressComponents{base = Register64.RSP, displacement = -1}))
	movabs_r64_imm64(.RCX, 10)
	// loop: rdx:rax = r8 ; div rcx ; digit = rdx ; store ; r8 = quotient.
	loop := here(e)
	mov_r64_r64(.RAX, .R8)
	xor_r64_r64(.RDX, .RDX)
	div_r64(.RCX) // unsigned: rax = q, rdx = rem
	mov_r64_r64(.R8, .RAX) // r8 = quotient
	add_r8_imm8(.DL, '0') // digit ascii
	mov_m8_r8(at_r9, .DL) // [r9] = digit
	dec_r64(.R9)
	test_r64_r64(.R8, .R8)
	back(e, jne_rel8, loop) // quotient != 0 → keep dividing
	// write(1, r9+1, rsp - (r9+1) ... = rsp-1-r9): rsi = r9+1 ; rdx = rsp - r9.
	inc_r64(.R9) // now points at the first digit
	mov_r64_r64(.RSI, .R9)
	mov_r64_r64(.RDX, .RSP)
	sub_r64_r64(.RDX, .R9)
	emit_load_imm_into(e, .RDI, 1)
	emit_load_imm_into(e, .RAX, 1)
	syscall()
}

// emit_print_uint6 prints RAX as exactly 6 zero-padded decimal digits.
emit_print_uint6 :: proc(e: ^X64_Emit) {
	at_r9 := MemoryAddress(AddressComponents{base = Register64.R9}) // [r9]
	// r8 = value ; r9 = rsp-1 cursor ; rsi = 6 (counter) ; write 6 digits backwards.
	mov_r64_r64(.R8, .RAX)
	lea_r64_m64(.R9, MemoryAddress(AddressComponents{base = Register64.RSP, displacement = -1}))
	movabs_r64_imm64(.RCX, 10)
	movabs_r64_imm64(.RSI, 6)
	loop := here(e)
	mov_r64_r64(.RAX, .R8)
	xor_r64_r64(.RDX, .RDX)
	div_r64(.RCX)
	mov_r64_r64(.R8, .RAX)
	add_r8_imm8(.DL, '0')
	mov_m8_r8(at_r9, .DL)
	dec_r64(.R9)
	dec_r64(.RSI)
	test_r64_r64(.RSI, .RSI)
	back(e, jne_rel8, loop) // 6 digits not done → loop
	// write(1, r9+1, 6)
	inc_r64(.R9)
	mov_r64_r64(.RSI, .R9)
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
	// `*{3,5,9}` -> ONE lea [src + src*scale], scale = k-1 in {2,4,8}.
	if k == 3 || k == 5 || k == 9 {
		emit_lea_self(e, w, mul_base(e, x), u8(k - 1), use32)
		return true
	}

	// Anything else → a single `imul dst, src, imm` (3 bytes for an imm8, one
	// instruction). We deliberately do NOT decompose into shl+lea / lea+lea: a
	// 2-instruction expansion is BIGGER (≥6 bytes) and no faster in practice than a
	// single imul-imm — and it loses the coalesced destination. The one-instruction
	// lea cases above (`*{3,5,9}`, `*2^k`) are the only wins worth taking.

	// Fallback: imul w, x, k. imul-by-immediate is 3-operand (`imul dst, src, imm`
	// reads src, writes dst), so when x already lives in a register we read it
	// straight as the source — no `mov w, x` seed. Only spilled x needs a load.
	if !fits_imm32(k) {
		return false
	}
	if rx, ok := home_reg(e, x); ok {
		if use32 {
			imul_r32_r32_imm32(r32(w), r32(rx), u32(i32(k)))
		} else {
			imul_r64_r64_imm32(w, rx, u32(i32(k)))
		}
		return true
	}
	load(e, w, x)
	if use32 {
		imul_r32_r32_imm32(r32(w), r32(w), u32(i32(k)))
	} else {
		imul_r64_r64_imm32(w, w, u32(i32(k)))
	}
	return true
}

// --- unsigned division by a constant via multiply-high (magic) --------------
//
// Granlund-Montgomery: replace `n / d` (a slow idiv) by `(n * M) >> s`, reading
// the high word of the 2^64-wide product. magicu64 derives M, the post-shift,
// and whether the "add" correction step is needed, for a 64-bit unsigned
// dividend. Syntact zero-extends the dividend to 64 bits (its range is known and
// fits its width ≤ 32), so the 64-bit magic is exact over the value's range.
//
// magicu64 (Hacker's Delight §10-9, unsigned): returns (M, add, sh) such that
//   q = n / d  ==  add ? ((MULHI(M,n) + ((n-MULHI(M,n))>>1)) >> (sh-1))
//                      :  (MULHI(M,n) >> sh)
// for every n in [0, 2^64). d must be > 0 and not a power of two (handled by the
// shr fast-path before this is reached).
magicu64 :: proc(d: i64) -> (M: u64, add: bool, sh: uint) {
	ud := u64(d)
	// nc = largest n (< 2^64) with n % d == d-1, i.e. ((2^64) / d)*d - 1.
	nc := (~u64(0) / ud) * ud - 1
	p: uint = 63
	// Find the smallest p such that 2^p > nc*(d - 1 - (2^p-1)%d). Done with
	// 128-bit-free arithmetic via the two running remainders q1/r1, q2/r2 (the
	// standard Hacker's Delight loop, all in 64-bit with explicit carry checks).
	q1 := u64(0x8000000000000000) / (nc + 1)
	r1 := u64(0x8000000000000000) - q1 * (nc + 1)
	q2 := (u64(0x7FFFFFFFFFFFFFFF)) / ud
	r2 := (u64(0x7FFFFFFFFFFFFFFF)) - q2 * ud
	delta: u64
	for {
		p += 1
		if r1 >= (nc + 1) - r1 {
			q1 = 2 * q1 + 1
			r1 = 2 * r1 - (nc + 1)
		} else {
			q1 = 2 * q1
			r1 = 2 * r1
		}
		if r2 + 1 >= ud - r2 {
			if q2 >= 0x7FFFFFFFFFFFFFFF do add = true
			q2 = 2 * q2 + 1
			r2 = 2 * r2 + 1 - ud
		} else {
			if q2 >= 0x8000000000000000 do add = true
			q2 = 2 * q2
			r2 = 2 * r2 + 1
		}
		delta = ud - 1 - r2
		if !(p < 128 && (q1 < delta || (q1 == delta && r1 == 0))) do break
	}
	M = q2 + 1
	sh = p - 64
	return
}

// emit_udiv_magic computes `w = a / k` for an unsigned dividend via the magic
// sequence. Uses RAX/RDX (the mul output pair) and RCX (scratch) — none of which
// is an allocatable home — so it never clobbers a live value other than its own
// inputs. The dividend is zero-extended into RAX; `mul rcx` puts the product high
// word in RDX.
emit_udiv_magic :: proc(e: ^X64_Emit, w: Register64, a: bc.BC_Value, k: i64) {
	M, add, sh := magicu64(k)
	load(e, .RAX, a) // rax = n (zero-extended)
	if add {
		// t = MULHI(M, n) ; q = ((n - t) >> 1 + t) >> (sh-1). n is saved in the red
		// zone [rsp-8] across the mul (which clobbers RAX/RDX); only RAX/RDX/RCX —
		// none allocatable — are touched, so no live value is lost.
		n_slot := AddressComponents{base = Register64.RSP, displacement = -8}
		mov_m64_r64(n_slot, .RAX)             // save n
		movabs_r64_imm64(.RCX, transmute(i64)M)
		mul_r64(.RCX)                          // rdx:rax = n * M ; rdx = t (high)
		mov_r64_m64(.RAX, n_slot)              // rax = n
		sub_r64_r64(.RAX, .RDX)                // rax = n - t
		shr_r64_imm8(.RAX, 1)                  // (n - t) >> 1
		add_r64_r64(.RAX, .RDX)                // + t
		if sh > 1 do shr_r64_imm8(.RAX, u8(sh - 1))
		if w != .RAX do mov_r64_r64(w, .RAX)
	} else {
		movabs_r64_imm64(.RCX, transmute(i64)M)
		mul_r64(.RCX)           // rdx:rax = n * M ; rdx = high word = MULHI
		if sh > 0 do shr_r64_imm8(.RDX, u8(sh))
		if w != .RDX do mov_r64_r64(w, .RDX)
	}
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
// bc_const_of returns the integer immediate a value was defined by, if it is a
// BC_Const (used by peepholes like `0 - b` → neg). e.def[v] is the defining
// instruction index (-1 if none).
bc_const_of :: proc(e: ^X64_Emit, v: bc.BC_Value) -> (i64, bool) {
	d := e.def[int(v)]
	if d < 0 do return 0, false
	if c, ok := e.prog.insts[d].(bc.BC_Const); ok do return c.imm, true
	return 0, false
}

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
	// movzbl eax,al (not movzbq): a 32-bit write zero-extends to all 64 bits, so
	// the bool (0/1) is correct and the encoding is one byte shorter (no REX.W).
	movzx_r32_r8(.EAX, .AL)
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
	movzx_r32_r8(.EAX, .AL) // movzbl: zero-extends to 64, no REX.W
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
