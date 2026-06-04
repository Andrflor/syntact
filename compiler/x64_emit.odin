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
}

X64_Fixup :: struct {
	at:    int, // byte offset of the rel32 field to patch
	label: BC_Label,
}

// emit_x64 lowers a BC_Program to a flat .text byte slice. Returns nil + error if
// the program carries a lowering error or uses an unsupported construct.
emit_x64 :: proc(prog: ^BC_Program) -> ([]u8, string) {
	if prog == nil do return nil, "no program"
	if prog.error != "" do return nil, prog.error
	if prog.result_type == .Str do return nil, "x64: string output not yet supported"
	if mtype_is_float(prog.result_type) do return nil, "x64: float output not yet supported (exit-status is integer)"

	e := X64_Emit{prog = prog}
	e.label_pos = make([]int, prog.label_count)
	defer delete(e.label_pos)
	defer delete(e.fixups)
	for i in 0 ..< prog.label_count do e.label_pos[i] = -1

	// Run the assembler's procs against OUR buffer via context.user_ptr.
	context.user_ptr = &e.buf

	frame := 8 * prog.value_count + 16 // one slot per vN, 16-aligned headroom
	frame = (frame + 15) & ~int(15)

	emit_arg_stub(&e) // parse argv[1..] → ARGS_TABLE
	emit_prologue(&e, frame)
	if msg := emit_body(&e); msg != "" do return nil, msg
	patch_fixups(&e)

	out := make([]u8, e.buf.len)
	copy(out, e.buf.data[:e.buf.len])
	return out, ""
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

// emit_exit emits: mov rdi, <result reg> ; mov rax, 60 ; syscall
emit_exit :: proc(e: ^X64_Emit, result: BC_Value) {
	load(e, .RDI, result)
	x64.movabs_r64_imm64(.RAX, 60) // sys_exit
	x64.syscall()
}

// --- body ------------------------------------------------------------------

emit_body :: proc(e: ^X64_Emit) -> string {
	for inst in e.prog.insts {
		switch v in inst {
		case BC_Const:
			x64.movabs_r64_imm64(.RAX, v.imm)
			store(e, v.dst, .RAX)
		case BC_Const_F:
			return "x64: float not yet supported"
		case BC_Str_Const:
			return "x64: string not yet supported"
		case BC_Load_Arg:
			// The arg stub parsed arg K into ARGS_TABLE[K] (absolute address).
			x64.write([]u8{0x48, 0xB8}) // movabs rax, addr
			put_i64_bytes(e, i64(ARGS_TABLE_VADDR + 8 * v.slot))
			x64.write([]u8{0x48, 0x8B, 0x00}) // mov rax, [rax]
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

// emit_bin: rax = a ; <op> rax, b(rcx) ; store dst.
emit_bin :: proc(e: ^X64_Emit, v: BC_Bin) -> string {
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
		// cqo ; idiv rcx  → quotient in rax
		emit_cqo(e)
		x64.idiv_r64(.RCX)
	case .Mod:
		emit_cqo(e)
		x64.idiv_r64(.RCX)
		x64.mov_r64_r64(.RAX, .RDX) // remainder in rdx
	case .LShift:
		emit_shift_cl(e, 0xE0) // shl rax, cl  (/4)
	case .RShift:
		emit_shift_cl(e, 0xF8) // sar rax, cl  (/7, arithmetic)
	case:
		return "x64: unsupported binary operator"
	}
	store(e, v.dst, .RAX)
	return ""
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
