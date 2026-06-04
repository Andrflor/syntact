package compiler

import x64 "./backends/x64"

// ============================================================================
// x64 EMITTER — bytecode → x86-64 machine code (.text bytes).
//
// Consumes the target-neutral BC_Program and emits x86-64 using the tested
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
	buf:        x64.ByteBuffer,
	prog:       ^BC_Program,
	// label id → byte offset of its definition (filled as we emit).
	label_pos:  []int,
	// pending jump fixups: patch a rel32 at `at` to reach `label`.
	fixups:     [dynamic]X64_Fixup,
	// const_val[vN] holds the immediate when vN is an integer BC_Const, plus a
	// parallel `is_const` flag — the basis for immediate folding and strength
	// reduction (a constant operand becomes an imm / shift / lea, never a reg op).
	const_val:  []i64,
	is_const:   []bool,
	// .rodata layout: rodata_off[id] is the byte offset of string id within the
	// rodata blob, whose runtime base address is rodata_vaddr. Both are known
	// BEFORE emitting code (they depend only on string lengths), so BC_Str_Const
	// loads an absolute address with no fixup.
	rodata_off:    []int,
	rodata_vaddr:  int,
	code_base_off: int,
	// str_len[vN] is the byte length of the concrete string a Str_Const value
	// holds, used by the string epilogue's write(1, ptr, len).
	str_len:       map[int]int,
}

X64_Fixup :: struct {
	at:    int, // byte offset of the rel32 field to patch
	label: BC_Label,
}

// X64_Output is the emitter's result: the code bytes plus the .rodata blob that
// must precede the code in the image (string literals live there).
X64_Output :: struct {
	code:   []u8,
	rodata: []u8,
}

// emit_x64 lowers a BC_Program to machine code + its .rodata blob. The image is
// laid out [headers][rodata][code]; rodata offsets depend only on string lengths,
// so they're known before emitting and BC_Str_Const loads absolute addresses.
emit_x64 :: proc(prog: ^BC_Program) -> (X64_Output, string) {
	if prog == nil do return {}, "no program"
	if prog.error != "" do return {}, prog.error

	e := X64_Emit{prog = prog}
	e.label_pos = make([]int, prog.label_count)
	e.const_val = make([]i64, prog.value_count)
	e.is_const = make([]bool, prog.value_count)
	defer delete(e.label_pos)
	defer delete(e.fixups)
	defer delete(e.const_val)
	defer delete(e.is_const)
	for i in 0 ..< prog.label_count do e.label_pos[i] = -1
	for inst in prog.insts {
		if c, ok := inst.(BC_Const); ok {
			e.const_val[int(c.dst)] = c.imm
			e.is_const[int(c.dst)] = true
		}
	}

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

	frame := 8 * prog.value_count + 16
	frame = (frame + 15) & ~int(15)

	emit_arg_stub(&e)
	emit_prologue(&e, frame)
	if msg := emit_body(&e); msg != "" do return {}, msg
	patch_fixups(&e)

	out := make([]u8, e.buf.len)
	copy(out, e.buf.data[:e.buf.len])
	return X64_Output{code = out, rodata = rodata_blob[:]}, ""
}

// emit_arg_stub parses each argv[1..] as a signed integer into ARGS_TABLE[slot].
// At process entry rsp -> argc, then the argv pointers. We loop K=0.. while
// K+1 < argc, atoi(argv[K+1]) → ARGS_TABLE[K].
//
// Registers: r12=argc, r13=&argv[0], r14=K (slot). Inner atoi uses rax/rcx/rsi/rdx.
emit_arg_stub :: proc(e: ^X64_Emit) {
	// r12 = argc = [rsp]
	x64.write([]u8{0x4C, 0x8B, 0x24, 0x24}) // mov r12, [rsp]
	// r13 = rsp + 8  (&argv[0])
	x64.write([]u8{0x4C, 0x8D, 0x6C, 0x24, 0x08}) // lea r13, [rsp+8]
	// r14 = 0
	x64.write([]u8{0x4D, 0x31, 0xF6}) // xor r14, r14

	loop_start := e.buf.len
	// rax = r14 + 1 ; cmp rax, r12 ; jge done
	x64.write([]u8{0x4C, 0x89, 0xF0}) // mov rax, r14
	x64.write([]u8{0x48, 0xFF, 0xC0}) // inc rax
	x64.write([]u8{0x4C, 0x39, 0xE0}) // cmp rax, r12
	x64.write([]u8{0x0F, 0x8D}) // jge rel32
	jge_at := e.buf.len
	x64.write([]u8{0, 0, 0, 0})

	// rdi = argv[r14+1] = [r13 + 8*rax]   (rax = r14+1 still)
	x64.write([]u8{0x49, 0x8B, 0x7C, 0xC5, 0x00}) // mov rdi, [r13 + rax*8 + 0]
	// atoi(rdi) → rax  (inline)
	emit_atoi(e)
	// ARGS_TABLE[r14] = rax  → mov [base + r14*8], rax. base is absolute; load it.
	x64.write([]u8{0x49, 0xBB}) // movabs r11, ARGS_TABLE_VADDR
	put_i64_bytes(e, i64(ARGS_TABLE_VADDR))
	x64.write([]u8{0x4B, 0x89, 0x04, 0xF3}) // mov [r11 + r14*8], rax
	// r14++
	x64.write([]u8{0x49, 0xFF, 0xC6}) // inc r14
	// jmp loop_start
	x64.write([]u8{0xE9})
	jat := e.buf.len
	x64.write([]u8{0, 0, 0, 0})
	rel := i32(loop_start - (jat + 4))
	patch_rel32(e, jat, rel)

	// done:
	done := e.buf.len
	rel2 := i32(done - (jge_at + 4))
	patch_rel32(e, jge_at, rel2)
}

// emit_atoi: parse the NUL-terminated string at rdi into rax (signed decimal).
// rax=acc, cl=byte, sil=sign flag. Clobbers rax,rcx,rsi,rdx.
emit_atoi :: proc(e: ^X64_Emit) {
	x64.write([]u8{0x48, 0x31, 0xC0}) // xor rax, rax            (acc=0)
	x64.write([]u8{0x45, 0x31, 0xC0}) // xor r8, r8              (sign=0)
	// check leading '-' : if [rdi]==0x2D, sign=1, rdi++
	x64.write([]u8{0x8A, 0x0F}) // mov cl, [rdi]
	x64.write([]u8{0x80, 0xF9, 0x2D}) // cmp cl, '-'
	x64.write([]u8{0x75, 0x06}) // jne +6 (skip sign setup)
	x64.write([]u8{0x41, 0xB0, 0x01}) // mov r8b, 1
	x64.write([]u8{0x48, 0xFF, 0xC7}) // inc rdi
	// digit loop:
	dloop := e.buf.len
	x64.write([]u8{0x8A, 0x0F}) // mov cl, [rdi]
	x64.write([]u8{0x80, 0xF9, 0x30}) // cmp cl, '0'
	x64.write([]u8{0x7C}) // jl rel8 → end (patched)
	jl_at := e.buf.len; x64.write([]u8{0})
	x64.write([]u8{0x80, 0xF9, 0x39}) // cmp cl, '9'
	x64.write([]u8{0x7F}) // jg rel8 → end (patched)
	jg_at := e.buf.len; x64.write([]u8{0})
	// acc = acc*10 + (cl-'0')
	x64.write([]u8{0x48, 0x6B, 0xC0, 0x0A}) // imul rax, rax, 10
	x64.write([]u8{0x48, 0x0F, 0xB6, 0xD1}) // movzx rdx, cl
	x64.write([]u8{0x48, 0x83, 0xEA, 0x30}) // sub rdx, '0'
	x64.write([]u8{0x48, 0x01, 0xD0}) // add rax, rdx
	x64.write([]u8{0x48, 0xFF, 0xC7}) // inc rdi
	// jmp dloop
	x64.write([]u8{0xEB})
	back := e.buf.len
	x64.write([]u8{0})
	e.buf.data[back] = u8(i8(dloop - (back + 1)))
	// end: patch the two forward jumps to here, then apply sign.
	end := e.buf.len
	e.buf.data[jl_at] = u8(i8(end - (jl_at + 1)))
	e.buf.data[jg_at] = u8(i8(end - (jg_at + 1)))
	x64.write([]u8{0x45, 0x84, 0xC0}) // test r8b, r8b
	x64.write([]u8{0x74, 0x03}) // jz +3
	x64.write([]u8{0x48, 0xF7, 0xD8}) // neg rax
}

put_i64_bytes :: proc(e: ^X64_Emit, v: i64) {
	u := transmute(u64)v
	bytes: [8]u8
	for i in 0 ..< 8 do bytes[i] = u8(u >> (uint(i) * 8))
	x64.write(bytes[:])
}

patch_rel32 :: proc(e: ^X64_Emit, at: int, rel: i32) {
	u := transmute(u32)rel
	e.buf.data[at + 0] = u8(u & 0xFF)
	e.buf.data[at + 1] = u8((u >> 8) & 0xFF)
	e.buf.data[at + 2] = u8((u >> 16) & 0xFF)
	e.buf.data[at + 3] = u8((u >> 24) & 0xFF)
}

// --- frame helpers ---------------------------------------------------------

slot_addr :: proc(vN: int) -> x64.MemoryAddress {
	// [rbp - 8*(vN+1)]
	return x64.AddressComponents{base = x64.Register64.RBP, displacement = i32(-8 * (vN + 1))}
}

load :: proc(e: ^X64_Emit, reg: x64.Register64, vN: BC_Value) {
	x64.mov_r64_m64(reg, slot_addr(int(vN)))
}

store :: proc(e: ^X64_Emit, vN: BC_Value, reg: x64.Register64) {
	x64.mov_m64_r64(slot_addr(int(vN)), reg)
}

// --- prologue / epilogue ---------------------------------------------------

emit_prologue :: proc(e: ^X64_Emit, frame: int) {
	// push rbp ; mov rbp, rsp ; sub rsp, frame
	x64.push_r64(.RBP)
	x64.mov_r64_r64(.RBP, .RSP)
	x64.sub_r64_imm32(.RSP, u32(frame))

	// Load each ??N from argv. The runtime entry stub (in the ELF) leaves the
	// parsed integer arguments in a small table the prologue reads; for now the
	// ELF stub parses argv[1..] into the first N stack slots BELOW our frame.
	// See write_elf_exec: it pushes parsed args, then calls us. Here we assume
	// the stub placed arg K at [rbp + 16 + 8*K] (above the saved rbp/return).
	// (Wired in the ELF step.)
}

// emit_exit emits the program's return. For a string result: write(1, ptr, len)
// then exit(0). For an integer/bool result: exit(result & 0xff) via the status.
emit_exit :: proc(e: ^X64_Emit, result: BC_Value) {
	if e.prog.result_type == .Str {
		// sys_write(1, ptr, len): rax=1, rdi=1, rsi=ptr, rdx=len.
		load(e, .RSI, result) // rsi = string pointer
		if l, ok := e.str_len[int(result)]; ok {
			x64.movabs_r64_imm64(.RDX, i64(l)) // rdx = length (immediate, known)
		} else {
			x64.xor_r64_r64(.RDX, .RDX)
		}
		x64.movabs_r64_imm64(.RDI, 1) // fd = stdout
		x64.movabs_r64_imm64(.RAX, 1) // sys_write
		x64.syscall()
		// exit(0)
		x64.xor_r64_r64(.RDI, .RDI)
		x64.movabs_r64_imm64(.RAX, 60)
		x64.syscall()
		return
	}
	if mtype_is_float(e.prog.result_type) {
		emit_print_float(e, result)
		x64.xor_r64_r64(.RDI, .RDI)
		x64.movabs_r64_imm64(.RAX, 60)
		x64.syscall()
		return
	}
	load(e, .RDI, result)
	x64.movabs_r64_imm64(.RAX, 60) // sys_exit
	x64.syscall()
}

// emit_print_float writes a decimal rendering of the f64 in `result`'s slot to
// stdout: optional '-', integer part, '.', then 6 fractional digits. Not a full
// IEEE shortest-round-trip formatter — a simple fixed-6 form sufficient to
// observe and validate float results. Builds the string in a stack buffer.
emit_print_float :: proc(e: ^X64_Emit, result: BC_Value) {
	// Strategy (all integer math after the initial truncation):
	//   xmm0 = value ; if sign bit, emit '-' and xmm0 = -xmm0
	//   ipart = (i64)xmm0   (cvttsd2si)
	//   frac  = (xmm0 - ipart) * 1e6  rounded → 6 digits
	// We render into a 32-byte buffer on the stack at [rbp-512] (within frame
	// headroom is not guaranteed; use a dedicated red-zone-safe area below rsp).
	// For simplicity we print integer part and 6 fraction digits via the helpers.

	// Load value bits into xmm0.
	load(e, .RAX, result)
	x64.movq_xmm_r64(.XMM0, .RAX)

	// --- handle sign: test the sign bit of rax (bit 63). ---
	// if rax < 0 (as signed bits): print '-', and clear sign bit (abs).
	// movabs rcx, 0x8000000000000000 ; test rax, rcx ; jz +; print '-'; andn
	x64.movabs_r64_imm64(.RCX, transmute(i64)u64(0x8000000000000000))
	// test rax, rcx
	x64.write([]u8{0x48, 0x85, 0xC8}) // test rax, rcx
	x64.write([]u8{0x74}) // jz over_sign
	jz_at := e.buf.len; x64.write([]u8{0})
	// print '-' : write(1, &minus, 1). Put '-' on stack via push.
	emit_print_char(e, '-')
	// abs: clear sign bit in rax, reload xmm0.
	load(e, .RAX, result)
	x64.movabs_r64_imm64(.RCX, transmute(i64)u64(0x7FFFFFFFFFFFFFFF))
	x64.write([]u8{0x48, 0x21, 0xC8}) // and rax, rcx
	x64.movq_xmm_r64(.XMM0, .RAX)
	over_sign := e.buf.len
	e.buf.data[jz_at] = u8(i8(over_sign - (jz_at + 1)))

	// ipart = cvttsd2si rax, xmm0  → F2 48 0F 2C C0
	x64.write([]u8{0xF2, 0x48, 0x0F, 0x2C, 0xC0})
	// print ipart (signed-but-now-positive integer) via emit_print_uint.
	emit_print_uint_in_rax(e)
	// print '.'
	emit_print_char(e, '.')
	// frac digits: xmm1 = (double)ipart ; xmm0 = xmm0 - xmm1 ; xmm0 *= 1e6 ;
	// rax = cvttsd2si xmm0 ; print 6 digits zero-padded.
	// cvtsi2sd xmm1, rax(ipart)  → F2 48 0F 2A C8 (rax still holds ipart? no — it
	// was consumed). Recompute ipart into rcx first.
	// Simpler: reload value, recompute. Reload original (already abs'd is lost);
	// to keep it correct we recompute from result and re-abs.
	load(e, .RAX, result)
	x64.movabs_r64_imm64(.RCX, transmute(i64)u64(0x7FFFFFFFFFFFFFFF))
	x64.write([]u8{0x48, 0x21, 0xC8}) // and rax, rcx  (abs)
	x64.movq_xmm_r64(.XMM0, .RAX) // xmm0 = |value|
	x64.write([]u8{0xF2, 0x48, 0x0F, 0x2C, 0xC0}) // cvttsd2si rax, xmm0 (ipart)
	x64.write([]u8{0xF2, 0x48, 0x0F, 0x2A, 0xC8}) // cvtsi2sd xmm1, rax (ipart→dbl)
	x64.write([]u8{0xF2, 0x0F, 0x5C, 0xC1}) // subsd xmm0, xmm1  (fraction)
	// xmm1 = 1e6
	x64.movabs_r64_imm64(.RAX, transmute(i64)f64(1000000.0))
	x64.movq_xmm_r64(.XMM1, .RAX)
	x64.write([]u8{0xF2, 0x0F, 0x59, 0xC1}) // mulsd xmm0, xmm1
	x64.write([]u8{0xF2, 0x48, 0x0F, 0x2C, 0xC0}) // cvttsd2si rax, xmm0 (frac int)
	// print rax as exactly 6 digits, zero-padded.
	emit_print_uint6(e)
}

// --- body ------------------------------------------------------------------

emit_body :: proc(e: ^X64_Emit) -> string {
	for inst in e.prog.insts {
		switch v in inst {
		case BC_Const:
			emit_load_imm_rax(e, v.imm)
			store(e, v.dst, .RAX)
		case BC_Const_F:
			// Materialize the f64 bit pattern in RAX, store to the value's slot.
			x64.movabs_r64_imm64(.RAX, transmute(i64)v.fimm)
			store(e, v.dst, .RAX)
		case BC_Str_Const:
			// Load the absolute address of the string's bytes in .rodata.
			addr := e.rodata_vaddr + e.rodata_off[v.id]
			x64.write([]u8{0x48, 0xB8}) // movabs rax, addr
			put_i64_bytes(e, i64(addr))
			store(e, v.dst, .RAX)
			e.str_len[int(v.dst)] = len(v.bytes)
		case BC_Load_Arg:
			// The arg stub parsed arg K into ARGS_TABLE[K] (absolute address).
			x64.write([]u8{0x48, 0xB8}) // movabs rax, addr
			put_i64_bytes(e, i64(ARGS_TABLE_VADDR + 8 * v.slot))
			x64.write([]u8{0x48, 0x8B, 0x00}) // mov rax, [rax]
			if mtype_is_float(e.prog.value_types[int(v.dst)]) {
				// A float ?? arrives as the integer atoi parsed; convert to f64
				// bits (cvtsi2sd xmm0, rax ; movq rax, xmm0). NB: a decimal argv
				// like "3.5" was truncated to 3 by the integer stub — native float
				// args are whole numbers; the interpreter handles full decimals.
				x64.write([]u8{0xF2, 0x48, 0x0F, 0x2A, 0xC0}) // cvtsi2sd xmm0, rax
				emit_movq_rax_xmm0(e)
			}
			store(e, v.dst, .RAX)
		case BC_Bin:
			if msg := emit_bin(e, v); msg != "" do return msg
		case BC_Cmp:
			emit_cmp(e, v)
		case BC_Move:
			load(e, .RAX, v.src)
			store(e, v.dst, .RAX)
		case BC_Label_Def:
			e.label_pos[int(v.label)] = e.buf.len
		case BC_Jump:
			emit_jmp(e, v.target)
		case BC_Branch_Zero:
			emit_brz(e, v.cond, v.target)
		case BC_Ret:
			emit_exit(e, v.src)
		}
	}
	return ""
}

// emit_bin emits `dst = a op b`, applying immediate folding and strength
// reduction: a constant operand becomes an immediate, a multiply/divide/mod by a
// power of two becomes a shift/and, a multiply by 3/5/9 a single lea. The result
// register is RAX, then stored to dst's slot.
emit_bin :: proc(e: ^X64_Emit, v: BC_Bin) -> string {
	// Float arithmetic goes through XMM (addsd/subsd/mulsd/divsd, scalar double).
	if mtype_is_float(e.prog.value_types[int(v.dst)]) {
		return emit_bin_float(e, v)
	}

	// For divide/mod strength reduction the dividend's signedness is what matters
	// (an unsigned dividend makes /2^k → shr, %2^k → and valid). The result's
	// Machine_Type may widen to i64 (an envelope without a canonical width), so we
	// read the operand, not the dst.
	unsigned := !mtype_signed(e.prog.value_types[int(v.a)])

	// Try strength reduction when one operand is a constant.
	a_const := e.is_const[int(v.a)]
	b_const := e.is_const[int(v.b)]

	#partial switch v.op {
	case .Multiply:
		// Commutative: put the constant on `k`, the variable on `x`.
		if k, x, ok := bc_const_operand(e, v.a, v.b); ok {
			if emit_mul_const(e, x, k) {store(e, v.dst, .RAX); return ""}
		}
	case .Add:
		if k, x, ok := bc_const_operand(e, v.a, v.b); ok {
			load(e, .RAX, x)
			if k == 0 {store(e, v.dst, .RAX); return ""} // +0 elided
			if fits_imm32(k) {
				x64.add_r64_imm32(.RAX, u32(i32(k)))
				store(e, v.dst, .RAX)
				return ""
			}
		}
	case .Subtract:
		if b_const && !a_const {
			load(e, .RAX, v.a)
			k := e.const_val[int(v.b)]
			if k == 0 {store(e, v.dst, .RAX); return ""} // -0 elided
			if fits_imm32(k) {
				x64.sub_r64_imm32(.RAX, u32(i32(k)))
				store(e, v.dst, .RAX)
				return ""
			}
		}
	case .Divide:
		if unsigned && b_const && !a_const {
			if sh, ok := log2_exact(e.const_val[int(v.b)]); ok {
				load(e, .RAX, v.a)
				x64.shr_r64_imm8(.RAX, u8(sh)) // unsigned /2^k → shr
				store(e, v.dst, .RAX)
				return ""
			}
		}
	case .Mod:
		if unsigned && b_const && !a_const {
			k := e.const_val[int(v.b)]
			if _, ok := log2_exact(k); ok {
				load(e, .RAX, v.a)
				and_rax_imm(e, k - 1) // unsigned %2^k → and (k-1)
				store(e, v.dst, .RAX)
				return ""
			}
		}
	case .And, .BitAnd:
		if k, x, ok := bc_const_operand(e, v.a, v.b); ok {
			load(e, .RAX, x)
			and_rax_imm(e, k)
			store(e, v.dst, .RAX)
			return ""
		}
	}

	// General path: rax = a ; op rax, rcx.
	load(e, .RAX, v.a)
	load(e, .RCX, v.b)
	#partial switch v.op {
	case .Add:
		x64.add_r64_r64(.RAX, .RCX)
	case .Subtract:
		x64.sub_r64_r64(.RAX, .RCX)
	case .Multiply:
		x64.imul_r64_r64(.RAX, .RCX)
	case .And, .BitAnd:
		x64.and_r64_r64(.RAX, .RCX)
	case .Or, .BitOr:
		x64.or_r64_r64(.RAX, .RCX)
	case .Xor:
		x64.xor_r64_r64(.RAX, .RCX)
	case .Divide:
		emit_cqo(e)
		x64.idiv_r64(.RCX)
	case .Mod:
		emit_cqo(e)
		x64.idiv_r64(.RCX)
		x64.mov_r64_r64(.RAX, .RDX) // remainder in rdx
	case .LShift:
		x64.mov_r64_r64(.RCX, .RCX) // (count already in rcx; CL is its low byte)
		emit_shift_cl(e, 0xE0) // shl rax, cl
	case .RShift:
		emit_shift_cl(e, 0xF8) // sar rax, cl  (arithmetic)
	case:
		return "x64: unsupported binary operator"
	}
	store(e, v.dst, .RAX)
	return ""
}

// emit_bin_float emits a scalar-double op via XMM. Operand bits are loaded from
// their stack slots into XMM0/XMM1, the SSE op runs, and the result bits go back.
// f32 is computed in double then narrowed only at materialization (kept simple).
emit_bin_float :: proc(e: ^X64_Emit, v: BC_Bin) -> string {
	load(e, .RAX, v.a)
	x64.movq_xmm_r64(.XMM0, .RAX) // xmm0 = a
	load(e, .RAX, v.b)
	x64.movq_xmm_r64(.XMM1, .RAX) // xmm1 = b
	#partial switch v.op {
	case .Add:
		x64.write([]u8{0xF2, 0x0F, 0x58, 0xC1}) // addsd xmm0, xmm1
	case .Subtract:
		x64.write([]u8{0xF2, 0x0F, 0x5C, 0xC1}) // subsd xmm0, xmm1
	case .Multiply:
		x64.write([]u8{0xF2, 0x0F, 0x59, 0xC1}) // mulsd xmm0, xmm1
	case .Divide:
		x64.write([]u8{0xF2, 0x0F, 0x5E, 0xC1}) // divsd xmm0, xmm1
	case:
		return "x64: unsupported float operator"
	}
	// rax = bits(xmm0) ; store.
	emit_movq_rax_xmm0(e)
	store(e, v.dst, .RAX)
	return ""
}

// movq rax, xmm0 : 66 48 0F 7E C0 (REX.W form moves all 64 bits).
emit_movq_rax_xmm0 :: proc(e: ^X64_Emit) {
	x64.write([]u8{0x66, 0x48, 0x0F, 0x7E, 0xC0})
}

// emit_load_imm_rax loads an immediate into RAX with the SHORTEST encoding:
// `mov eax, imm32` (5 bytes, zero-extends to RAX) when the value fits in u32,
// `movabs rax, imm64` (10 bytes) otherwise. A common immediate-folding win.
emit_load_imm_rax :: proc(e: ^X64_Emit, v: i64) {
	if v >= 0 && v <= 0xFFFFFFFF {
		// B8 id : mov eax, imm32  (the upper 32 bits of RAX are zeroed)
		u := u32(v)
		x64.write([]u8{0xB8, u8(u), u8(u >> 8), u8(u >> 16), u8(u >> 24)})
		return
	}
	x64.movabs_r64_imm64(.RAX, v)
}

// emit_print_char writes a single byte to stdout. Uses the red zone: push the
// char, write(1, rsp, 1), pop.
emit_print_char :: proc(e: ^X64_Emit, c: u8) {
	// mov byte ptr [rsp-1], c ; lea rsi, [rsp-1] ; write(1, rsi, 1)
	x64.write([]u8{0xC6, 0x44, 0x24, 0xFF, c}) // mov byte [rsp-1], c
	x64.write([]u8{0x48, 0x8D, 0x74, 0x24, 0xFF}) // lea rsi, [rsp-1]
	x64.movabs_r64_imm64(.RDX, 1) // len 1
	x64.movabs_r64_imm64(.RDI, 1) // fd 1
	x64.movabs_r64_imm64(.RAX, 1) // sys_write
	x64.syscall()
}

// emit_print_uint_in_rax prints the unsigned integer in RAX as decimal (no
// leading zeros, "0" if zero). Builds digits backwards into [rsp-32..] then
// write()s them. Clobbers rax,rcx,rdx,rsi,rdi,r8,r9.
emit_print_uint_in_rax :: proc(e: ^X64_Emit) {
	// r8 = rax (value) ; r9 = &buf_end = rsp-1 ; ten in rcx.
	x64.write([]u8{0x49, 0x89, 0xC0}) // mov r8, rax
	x64.write([]u8{0x4C, 0x8D, 0x4C, 0x24, 0xE0}) // lea r9, [rsp-32]  (buffer start)
	// We'll fill forward from a cursor and track count. Simpler: classic reverse.
	// Use [rsp-1] downward as the digit area; r9 = cursor = rsp-1.
	x64.write([]u8{0x4C, 0x8D, 0x4C, 0x24, 0xFF}) // lea r9, [rsp-1]
	x64.movabs_r64_imm64(.RCX, 10)
	// loop: rdx:rax = r8 ; div rcx ; digit = rdx ; store; r8 = rax(quotient)
	loop := e.buf.len
	x64.write([]u8{0x4C, 0x89, 0xC0}) // mov rax, r8
	x64.write([]u8{0x48, 0x31, 0xD2}) // xor rdx, rdx
	x64.write([]u8{0x48, 0xF7, 0xF1}) // div rcx  (unsigned)
	x64.write([]u8{0x49, 0x89, 0xC0}) // mov r8, rax (quotient)
	// dl += '0' ; store [r9], dl ; r9--
	x64.write([]u8{0x80, 0xC2, 0x30}) // add dl, '0'
	x64.write([]u8{0x41, 0x88, 0x11}) // mov [r9], dl
	x64.write([]u8{0x49, 0xFF, 0xC9}) // dec r9
	// if r8 != 0 loop
	x64.write([]u8{0x4D, 0x85, 0xC0}) // test r8, r8
	x64.write([]u8{0x75}) // jnz loop
	back := e.buf.len; x64.write([]u8{0})
	e.buf.data[back] = u8(i8(loop - (back + 1)))
	// write(1, r9+1, (rsp-1)-(r9)) : rsi = r9+1 ; rdx = (rsp-1) - r9
	x64.write([]u8{0x49, 0xFF, 0xC1}) // inc r9  (now points at first digit)
	x64.write([]u8{0x4C, 0x89, 0xCE}) // mov rsi, r9
	// rdx = (rsp-1) - r9 + 1  = rsp - r9
	x64.write([]u8{0x48, 0x89, 0xE2}) // mov rdx, rsp
	x64.write([]u8{0x4C, 0x29, 0xCA}) // sub rdx, r9
	x64.movabs_r64_imm64(.RDI, 1)
	x64.movabs_r64_imm64(.RAX, 1)
	x64.syscall()
}

// emit_print_uint6 prints RAX as exactly 6 zero-padded decimal digits.
emit_print_uint6 :: proc(e: ^X64_Emit) {
	// r8 = value ; r9 = rsp-1 ; write 6 digits backwards.
	x64.write([]u8{0x49, 0x89, 0xC0}) // mov r8, rax
	x64.write([]u8{0x4C, 0x8D, 0x4C, 0x24, 0xFF}) // lea r9, [rsp-1]
	x64.movabs_r64_imm64(.RCX, 10)
	x64.movabs_r64_imm64(.RSI, 6) // counter
	loop := e.buf.len
	x64.write([]u8{0x4C, 0x89, 0xC0}) // mov rax, r8
	x64.write([]u8{0x48, 0x31, 0xD2}) // xor rdx, rdx
	x64.write([]u8{0x48, 0xF7, 0xF1}) // div rcx
	x64.write([]u8{0x49, 0x89, 0xC0}) // mov r8, rax
	x64.write([]u8{0x80, 0xC2, 0x30}) // add dl, '0'
	x64.write([]u8{0x41, 0x88, 0x11}) // mov [r9], dl
	x64.write([]u8{0x49, 0xFF, 0xC9}) // dec r9
	x64.write([]u8{0x48, 0xFF, 0xCE}) // dec rsi
	x64.write([]u8{0x48, 0x85, 0xF6}) // test rsi, rsi
	x64.write([]u8{0x75}) // jnz loop
	back := e.buf.len; x64.write([]u8{0})
	e.buf.data[back] = u8(i8(loop - (back + 1)))
	// write(1, r9+1, 6)
	x64.write([]u8{0x49, 0xFF, 0xC1}) // inc r9
	x64.write([]u8{0x4C, 0x89, 0xCE}) // mov rsi, r9
	x64.movabs_r64_imm64(.RDX, 6)
	x64.movabs_r64_imm64(.RDI, 1)
	x64.movabs_r64_imm64(.RAX, 1)
	x64.syscall()
}

// emit_mul_const lowers x*k with strength reduction. Returns false if it falls
// through to the general imul path (handled by the caller). Result in RAX.
emit_mul_const :: proc(e: ^X64_Emit, x: BC_Value, k: i64) -> bool {
	switch {
	case k == 0:
		x64.xor_r64_r64(.RAX, .RAX) // *0 → 0
		return true
	case k == 1:
		load(e, .RAX, x) // *1 → identity
		return true
	case k == 2:
		load(e, .RAX, x)
		x64.shl_r64_imm8(.RAX, 1)
		return true
	}
	if sh, ok := log2_exact(k); ok {
		load(e, .RAX, x)
		x64.shl_r64_imm8(.RAX, u8(sh)) // *2^k → shl
		return true
	}
	// x*3 = lea rax,[rcx+rcx*2]; x*5 = [rcx+rcx*4]; x*9 = [rcx+rcx*8].
	scale: u8 = 0
	switch k {
	case 3: scale = 2
	case 5: scale = 4
	case 9: scale = 8
	}
	if scale != 0 {
		load(e, .RCX, x)
		// lea rax, [rcx + rcx*scale]  (scale=2→*3, 4→*5, 8→*9)
		emit_lea_rax_rcx_rcx(e, scale)
		return true
	}
	// Not reducible: fall back to imul with the constant materialized.
	load(e, .RAX, x)
	if fits_imm32(k) {
		x64.imul_r64_r64_imm32(.RAX, .RAX, u32(i32(k)))
		return true
	}
	return false
}

// bc_const_operand: if exactly one of a/b is a constant, return (k, x) with k the
// constant value and x the variable operand.
bc_const_operand :: proc(e: ^X64_Emit, a, b: BC_Value) -> (k: i64, x: BC_Value, ok: bool) {
	if e.is_const[int(a)] && !e.is_const[int(b)] do return e.const_val[int(a)], b, true
	if e.is_const[int(b)] && !e.is_const[int(a)] do return e.const_val[int(b)], a, true
	return 0, 0, false
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
and_rax_imm :: proc(e: ^X64_Emit, k: i64) {
	if fits_imm32(k) {
		// REX.W 81 /4 id : and r/m64, imm32  → 48 81 E0 id
		x64.write([]u8{0x48, 0x81, 0xE0})
		u := transmute(u32)i32(k)
		x64.write([]u8{u8(u), u8(u >> 8), u8(u >> 16), u8(u >> 24)})
	} else {
		x64.movabs_r64_imm64(.RCX, k)
		x64.and_r64_r64(.RAX, .RCX)
	}
}

// emit_lea_rax_rcx_rcx: lea rax, [rcx + rcx*scale]. scale ∈ {2,4,8} via SIB.
emit_lea_rax_rcx_rcx :: proc(e: ^X64_Emit, scale: u8) {
	ss: u8 = scale == 2 ? 1 : (scale == 4 ? 2 : 3) // log2(scale)
	// REX.W=48, opcode 8D, modrm: mod=00 reg=rax(000) rm=100(SIB) → 0x04
	// SIB: scale=ss base=rcx(001) index=rcx(001) → (ss<<6)|(001<<3)|001
	sib := (ss << 6) | (0b001 << 3) | 0b001
	x64.write([]u8{0x48, 0x8D, 0x04, sib})
}

// emit_cmp: rax = (a <op> b) ? 1 : 0 via cmp + setcc + movzx.
emit_cmp :: proc(e: ^X64_Emit, v: BC_Cmp) {
	load(e, .RAX, v.a)
	load(e, .RCX, v.b)
	x64.cmp_r64_r64(.RAX, .RCX)
	#partial switch v.op {
	case .Equal:
		x64.sete_r8(.AL)
	case .NotEqual:
		x64.setne_r8(.AL)
	case .Less:
		x64.setl_r8(.AL)
	case .Greater:
		x64.setg_r8(.AL)
	case .LessEqual:
		x64.setle_r8(.AL)
	case .GreaterEqual:
		x64.setge_r8(.AL)
	}
	x64.movzx_r64_r8(.RAX, .AL)
	store(e, v.dst, .RAX)
}

// --- raw-byte helpers for instructions the assembler lacks -----------------

// cqo: REX.W + 0x99 — sign-extend RAX into RDX:RAX before idiv.
emit_cqo :: proc(e: ^X64_Emit) {
	x64.write([]u8{0x48, 0x99})
}

// shift rax by cl: REX.W + 0xD3 /modrm. modrm_ext is the /digit << 3 | rm pattern
// for rax (rm=0): 0xE0 = shl (/4), 0xF8 = sar (/7), 0xE8 = shr (/5).
emit_shift_cl :: proc(e: ^X64_Emit, modrm: u8) {
	x64.write([]u8{0x48, 0xD3, modrm})
}

// --- jumps (two-pass) ------------------------------------------------------

emit_jmp :: proc(e: ^X64_Emit, label: BC_Label) {
	// jmp rel32 : E9 cd
	x64.write([]u8{0xE9})
	at := e.buf.len
	x64.write([]u8{0, 0, 0, 0})
	append(&e.fixups, X64_Fixup{at = at, label = label})
}

emit_brz :: proc(e: ^X64_Emit, cond: BC_Value, label: BC_Label) {
	// test the cond register, then je rel32 (jump if zero).
	load(e, .RAX, cond)
	x64.test_r64_r64(.RAX, .RAX)
	x64.write([]u8{0x0F, 0x84}) // je rel32
	at := e.buf.len
	x64.write([]u8{0, 0, 0, 0})
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
