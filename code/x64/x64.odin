package code_x64

import code ".."
import enc "asm"
import "core:os"

// THE MACHINE CODE OF A PROGRAM
//
// The code of a program (code/) for x86-64, on the encoder, the image writer and the
// System V ABI of code/x64/asm. Each value has its slot in the frame of its
// function: an instruction loads its operands into scratch registers, computes, and
// stores its result. A call of a symbol goes through its slot of the GOT, which the
// loader fills.
//
// The image starts at a stub: it reads the inputs of the program from the command
// line — integers —, calls the program, and ends with its value: an integer is the
// exit code; a float, written with six decimals, and a text, written, end with a
// newline and the exit code 0. The output of the libraries is flushed first.

Emitter :: struct {
	prog:         ^code.Program,
	buf:          enc.ByteBuffer,
	imports:      [dynamic]enc.Import, // the program's, then fflush when it has any
	flush:        int, // the import of fflush; -1 without imports
	rodata:       [dynamic]u8,
	text_offsets: []int,
	rodata_vaddr: int,
	funcs:        []int, // the offset of each function
	calls:        [dynamic]Fixup, // calls of a function, patched once all are placed
}

// Fixup: a rel32 at `at` that reaches `target`, a label or a function.
Fixup :: struct {
	at, target: int,
}

// executable: the program, as an executable file at path; "" when written.
executable :: proc(p: ^code.Program, path: string) -> string {
	image, err := image_of(p)
	if err != "" do return err
	if os.write_entire_file(path, image) != nil do return "the executable cannot be written"
	os.chmod(path, os.Permissions{.Read_User, .Write_User, .Execute_User, .Read_Group, .Execute_Group, .Read_Other, .Execute_Other})
	return ""
}

image_of :: proc(p: ^code.Program) -> (image: []u8, err: string) {
	e := Emitter{prog = p, flush = -1}
	for imp in p.imports do append(&e.imports, enc.Import{lib = imp.lib, symbol = imp.symbol})
	if len(p.imports) > 0 {
		append(&e.imports, enc.Import{lib = "libc.so.6", symbol = "fflush"})
		e.flush = len(e.imports) - 1
	}
	if len(e.imports) > enc.GOT_MAX do return nil, "too many symbols imported"
	if len(p.inputs) > enc.ARGS_TABLE_MAX do return nil, "too many inputs"
	e.text_offsets = make([]int, len(p.texts))
	for t, i in p.texts {
		e.text_offsets[i] = len(e.rodata)
		append(&e.rodata, ..transmute([]u8)t)
		append(&e.rodata, 0)
	}
	e.rodata_vaddr = enc.ELF_BASE + enc.elf_headers_size(len(e.imports))
	context.user_ptr = &e.buf
	stub(&e)
	e.funcs = make([]int, len(p.funcs))
	for f, i in p.funcs {
		e.funcs[i] = e.buf.len
		if msg := function(&e, f); msg != "" do return nil, msg
	}
	for c in e.calls do patch(&e, c.at, e.funcs[c.target])
	machine := make([]u8, e.buf.len)
	copy(machine, e.buf.data[:e.buf.len])
	return enc.build_elf(machine, e.rodata[:], e.imports[:], 0), ""
}

// --- placing code ---

here :: proc(e: ^Emitter) -> int {
	return e.buf.len
}

// patch: the rel32 that ends at `at` + 4 reaches target.
patch :: proc(e: ^Emitter, at, target: int) {
	rel := transmute(u32)i32(target - (at + 4))
	for i in 0 ..< 4 do e.buf.data[at + i] = u8(rel >> (8 * uint(i)))
}

// forward: a jump whose target is not placed yet: the offset of its rel32.
forward :: proc(e: ^Emitter, jump: proc(offset: i32)) -> int {
	jump(0)
	return here(e) - 4
}

// land: the forward jump at `at` reaches here.
land :: proc(e: ^Emitter, at: int) {
	patch(e, at, here(e))
}

// back: a jump to a target already placed.
back :: proc(e: ^Emitter, jump: proc(offset: i32), target: int) {
	jump(0)
	patch(e, here(e) - 4, target)
}

absolute :: proc(reg: enc.Register64) -> enc.MemoryAddress {
	return enc.AddressComponents{base = reg}
}

// --- the stub ---

stub :: proc(e: ^Emitter) {
	p := e.prog
	if len(p.inputs) > 0 {
		// argc < inputs + 1: exit 2
		enc.mov_r64_m64(.RAX, absolute(.RSP))
		enc.cmp_r64_imm32(.RAX, u32(len(p.inputs) + 1))
		enough := forward(e, enc.jge_rel32)
		write_text(e, "missing inputs\n", 2)
		exit_with(e, 2)
		land(e, enough)
		// each input, in the layout it is written with: otherwise exit 2
		outside := make([dynamic]int)
		for cover, slot in p.inputs {
			enc.mov_r64_m64(.RSI, enc.AddressComponents{base = .RSP, displacement = i32(16 + 8 * slot)})
			integer_of(e)
			enc.movabs_r64_imm64(.R10, i64(enc.ARGS_TABLE_VADDR + 8 * slot))
			enc.mov_m64_r64(absolute(.R10), .RAX)
			append(&outside, ..test_loaded(e, .Int, cover))
		}
		admitted := forward(e, enc.jmp_rel32)
		for at in outside do land(e, at)
		write_text(e, "input out of range\n", 2)
		exit_with(e, 2)
		land(e, admitted)
	}
	enc.call_rel32(0)
	append(&e.calls, Fixup{here(e) - 4, 0})
	enc.mov_r64_r64(.RBX, .RAX) // the value, kept across the calls below
	if e.flush >= 0 {
		enc.xor_r64_r64(.RDI, .RDI)
		call_import(e, e.flush, 0)
	}
	switch p.funcs[0].result {
	case .Int:
		enc.mov_r64_r64(.RDI, .RBX)
		enc.movabs_r64_imm64(.RAX, 60)
		enc.syscall()
	case .None:
		exit_with(e, 0)
	case .Real:
		write_real(e)
		exit_with(e, 0)
	case .Text:
		write_string_at(e)
		exit_with(e, 0)
	}
}

exit_with :: proc(e: ^Emitter, status: i64) {
	enc.movabs_r64_imm64(.RDI, status)
	enc.movabs_r64_imm64(.RAX, 60)
	enc.syscall()
}

// integer_of: rax = the signed decimal integer the bytes at rsi write.
integer_of :: proc(e: ^Emitter) {
	enc.xor_r64_r64(.RAX, .RAX)
	enc.xor_r64_r64(.RCX, .RCX) // 1 when negative
	enc.movzx_r64_m8(.RDX, absolute(.RSI))
	enc.cmp_r64_imm32(.RDX, u32('-'))
	positive := forward(e, enc.jne_rel32)
	enc.movabs_r64_imm64(.RCX, 1)
	enc.inc_r64(.RSI)
	land(e, positive)
	digits := here(e)
	enc.movzx_r64_m8(.RDX, absolute(.RSI))
	enc.sub_r64_imm32(.RDX, u32('0'))
	enc.cmp_r64_imm32(.RDX, 9)
	done := forward(e, enc.ja_rel32)
	enc.imul_r64_r64_imm32(.RAX, .RAX, 10)
	enc.add_r64_r64(.RAX, .RDX)
	enc.inc_r64(.RSI)
	back(e, enc.jmp_rel32, digits)
	land(e, done)
	enc.test_r64_r64(.RCX, .RCX)
	unsigned := forward(e, enc.je_rel32)
	enc.neg_r64(.RAX)
	land(e, unsigned)
}

// write_bytes: write(fd, rsi, rdx).
write_bytes :: proc(fd: i64) {
	enc.movabs_r64_imm64(.RDI, fd)
	enc.movabs_r64_imm64(.RAX, 1)
	enc.syscall()
}

// write_char: one byte, through the stack.
write_char :: proc(c: u8) {
	enc.movabs_r64_imm64(.RAX, i64(c))
	enc.push_r64(.RAX)
	enc.mov_r64_r64(.RSI, .RSP)
	enc.movabs_r64_imm64(.RDX, 1)
	write_bytes(1)
	enc.pop_r64(.RAX)
}

// write_text: a text known when compiling, written byte by byte.
write_text :: proc(e: ^Emitter, s: string, fd: i64) {
	for c in transmute([]u8)s {
		enc.movabs_r64_imm64(.RAX, i64(c))
		enc.push_r64(.RAX)
		enc.mov_r64_r64(.RSI, .RSP)
		enc.movabs_r64_imm64(.RDX, 1)
		write_bytes(fd)
		enc.pop_r64(.RAX)
	}
}

// write_string_at: the text that rbx addresses, up to its 0, then a newline.
write_string_at :: proc(e: ^Emitter) {
	enc.xor_r64_r64(.RDX, .RDX)
	count := here(e)
	enc.movzx_r64_m8(.RCX, enc.AddressComponents{base = .RBX, index = .RDX, scale = 1})
	enc.test_r64_r64(.RCX, .RCX)
	end := forward(e, enc.je_rel32)
	enc.inc_r64(.RDX)
	back(e, enc.jmp_rel32, count)
	land(e, end)
	enc.mov_r64_r64(.RSI, .RBX)
	write_bytes(1)
	write_char('\n')
}

// write_unsigned: the decimal digits of rax, at least `least` of them, through a
// buffer on the stack.
write_unsigned :: proc(e: ^Emitter, least: int) {
	enc.sub_r64_imm32(.RSP, 32)
	enc.movabs_r64_imm64(.R8, 32) // where the next digit goes, from the end
	enc.movabs_r64_imm64(.R9, i64(least))
	enc.movabs_r64_imm64(.RCX, 10)
	digit := here(e)
	enc.cqo()
	enc.idiv_r64(.RCX)
	enc.add_r64_imm32(.RDX, u32('0'))
	enc.dec_r64(.R8)
	enc.mov_m8_r8(enc.AddressComponents{base = .RSP, index = .R8, scale = 1}, .DL)
	enc.dec_r64(.R9)
	enc.test_r64_r64(.RAX, .RAX)
	back(e, enc.jne_rel32, digit)
	enc.cmp_r64_imm32(.R9, 0)
	back(e, enc.jg_rel32, digit)
	enc.lea_r64_m64(.RSI, enc.AddressComponents{base = .RSP, index = .R8, scale = 1})
	enc.movabs_r64_imm64(.RDX, 32)
	enc.sub_r64_r64(.RDX, .R8)
	write_bytes(1)
	enc.add_r64_imm32(.RSP, 32)
}

// write_real: the float whose bits rbx holds, with six decimals, then a newline:
// round(|x| * 10⁶) cut at 10⁶.
write_real :: proc(e: ^Emitter) {
	enc.test_r64_r64(.RBX, .RBX)
	positive := forward(e, enc.jns_rel32)
	write_char('-')
	enc.movabs_r64_imm64(.RAX, 63)
	enc.btr_r64_r64(.RBX, .RAX)
	land(e, positive)
	enc.movq_xmm_r64(.XMM0, .RBX)
	enc.movabs_r64_imm64(.RAX, transmute(i64)f64(1e6))
	enc.movq_xmm_r64(.XMM1, .RAX)
	enc.mulsd_xmm_xmm(.XMM0, .XMM1)
	enc.movabs_r64_imm64(.RAX, transmute(i64)f64(0.5))
	enc.movq_xmm_r64(.XMM1, .RAX)
	enc.addsd_xmm_xmm(.XMM0, .XMM1)
	enc.cvttsd2si_r64_xmm(.RAX, .XMM0)
	enc.movabs_r64_imm64(.RCX, 1000000)
	enc.cqo()
	enc.idiv_r64(.RCX)
	enc.mov_r64_r64(.R12, .RDX) // the decimals
	write_unsigned(e, 1)
	write_char('.')
	enc.mov_r64_r64(.RAX, .R12)
	write_unsigned(e, 6)
	write_char('\n')
}

// call_import: call the symbol of a slot of the GOT, `sse` of its arguments in
// SSE registers.
call_import :: proc(e: ^Emitter, slot, sse: int) {
	enc.movabs_r64_imm64(.RAX, i64(sse))
	enc.movabs_r64_imm64(.R10, i64(enc.GOT_VADDR + 8 * slot))
	enc.call_m64(absolute(.R10))
}

// --- a function ---

// slot: where a value lives in its function's frame.
slot :: proc(v: code.Value) -> enc.MemoryAddress {
	return enc.AddressComponents{base = .RBP, displacement = i32(-8 * (int(v) + 1))}
}

load :: proc(reg: enc.Register64, v: code.Value) {
	enc.mov_r64_m64(reg, slot(v))
}

store :: proc(v: code.Value, reg: enc.Register64) {
	enc.mov_m64_r64(slot(v), reg)
}

function :: proc(e: ^Emitter, f: ^code.Func) -> string {
	frame := (8 * len(f.kinds) + 15) & ~int(15)
	enc.push_r64(.RBP)
	enc.mov_r64_r64(.RBP, .RSP)
	if frame > 0 do enc.sub_r64_imm32(.RSP, u32(frame))
	// the parameters, v0…, from the registers the System V ABI gives them
	assignment, msg := assign(f.params)
	if msg != "" do return msg
	for loc, i in assignment.locations {
		switch loc.class {
		case .Integer:
			store(code.Value(i), enc.SYSV_INT_ARGS[loc.register])
		case .SSE:
			enc.movq_r64_xmm(.RAX, enc.SYSV_SSE_ARGS[loc.register])
			store(code.Value(i), .RAX)
		case .Stack:
		}
	}
	loops := make([dynamic]Loop_Head)
	if msg := body(e, f, f.body, &loops); msg != "" do return msg
	if f.body.value == code.NONE do enc.xor_r64_r64(.RAX, .RAX)
	else do load(.RAX, f.body.value)
	enc.mov_r64_r64(.RSP, .RBP)
	enc.pop_r64(.RBP)
	enc.ret()
	return ""
}

// Loop_Head: a loop the code is in: where its body starts, and its parameters.
Loop_Head :: struct {
	at:     int,
	params: []code.Value,
}

// body: the instructions of a body, in order; a match and a loop laid out with
// jumps.
body :: proc(e: ^Emitter, f: ^code.Func, b: code.Body, loops: ^[dynamic]Loop_Head) -> string {
	for inst in b.insts {
		switch i in inst {
		case code.Const:
			enc.movabs_r64_imm64(.RAX, i.value)
			store(i.dst, .RAX)
		case code.Real_Const:
			enc.movabs_r64_imm64(.RAX, transmute(i64)i.value)
			store(i.dst, .RAX)
		case code.Text_Const:
			enc.movabs_r64_imm64(.RAX, i64(e.rodata_vaddr + e.text_offsets[i.text]))
			store(i.dst, .RAX)
		case code.Input:
			enc.movabs_r64_imm64(.R10, i64(enc.ARGS_TABLE_VADDR + 8 * i.slot))
			enc.mov_r64_m64(.RAX, absolute(.R10))
			store(i.dst, .RAX)
		case code.Unary:
			load(.RAX, i.a)
			switch {
			case i.op == .Neg && f.kinds[i.a].machine == .Real:
				enc.movabs_r64_imm64(.RCX, 63)
				enc.btc_r64_r64(.RAX, .RCX)
			case i.op == .Neg:
				enc.neg_r64(.RAX)
			case i.op == .Not:
				enc.not_r64(.RAX)
			case:
				return "a unary operation the machine does not compute"
			}
			store(i.dst, .RAX)
		case code.Binary:
			load(.RAX, i.a)
			load(.RCX, i.b)
			msg := f.kinds[i.a].machine == .Real ? real_binary(i.op) : int_binary(i.op)
			if msg != "" do return msg
			store(i.dst, .RAX)
		case code.In:
			outside := test_cover(e, f, i.x, i.cover)
			enc.movabs_r64_imm64(.RAX, 1)
			done := forward(e, enc.jmp_rel32)
			for at in outside do land(e, at)
			enc.xor_r64_r64(.RAX, .RAX)
			land(e, done)
			store(i.dst, .RAX)
		case code.Narrow:
			load(.RAX, i.src)
			store(i.dst, .RAX)
		case code.Foreign:
			if msg := call_symbol(e, f, i); msg != "" do return msg
		case code.Call:
			callee := e.prog.funcs[i.func]
			assignment, msg := assign(callee.params)
			if msg != "" do return msg
			pass(i.args, assignment)
			enc.call_rel32(0)
			append(&e.calls, Fixup{here(e) - 4, i.func})
			if i.dst != code.NONE do store(i.dst, .RAX)
		case code.Match:
			ends := make([dynamic]int)
			for arm, n in i.arms {
				last := n == len(i.arms) - 1
				next: []int
				if !last do next = test_cover(e, f, i.target, arm.cover)
				if msg := body(e, f, arm.body, loops); msg != "" do return msg
				if i.dst != code.NONE && arm.body.value != code.NONE {
					load(.RAX, arm.body.value)
					store(i.dst, .RAX)
				}
				if last do break
				append(&ends, forward(e, enc.jmp_rel32))
				for at in next do land(e, at)
			}
			for at in ends do land(e, at)
		case code.Loop:
			move_all(i.params, i.init)
			append(loops, Loop_Head{here(e), i.params})
			if msg := body(e, f, i.body, loops); msg != "" do return msg
			pop(loops)
			if i.dst != code.NONE {
				load(.RAX, i.body.value)
				store(i.dst, .RAX)
			}
		case code.Again:
			if len(loops) == 0 do return "an Again outside a loop"
			head := loops[len(loops) - 1]
			move_all(head.params, i.args)
			back(e, enc.jmp_rel32, head.at)
		}
	}
	return ""
}

// move_all: dst take the values of src, all read before any is written: through
// the stack.
move_all :: proc(dst, src: []code.Value) {
	for x in src {
		load(.RAX, x)
		enc.push_r64(.RAX)
	}
	#reverse for x in dst {
		enc.pop_r64(.RAX)
		store(x, .RAX)
	}
}

// test_cover: jumps to where the cover does not take the value x; what follows
// runs when it does.
test_cover :: proc(e: ^Emitter, f: ^code.Func, x: code.Value, c: code.Cover) -> []int {
	m := f.kinds[x].machine
	load(.RAX, x)
	if m == .Real do enc.movq_xmm_r64(.XMM0, .RAX)
	return test_loaded(e, m, c)
}

// test_loaded: test_cover, on an integer in rax or a float in xmm0. Each cell is
// tested in turn: a value in one is in the cells.
test_loaded :: proc(e: ^Emitter, m: code.Machine, c: code.Cover) -> []int {
	inside := make([dynamic]int)
	if m == .Real {
		for r in c.reals {
			skip := make([dynamic]int)
			if r.lo > -max(f64) {
				// x < lo, or x <= lo when open, or unordered: not in the cell
				enc.movabs_r64_imm64(.RAX, transmute(i64)r.lo)
				enc.movq_xmm_r64(.XMM1, .RAX)
				enc.ucomisd_xmm_xmm(.XMM0, .XMM1)
				append(&skip, forward(e, enc.jp_rel32))
				append(&skip, forward(e, r.lo_open ? enc.jbe_rel32 : enc.jb_rel32))
			}
			if r.hi < max(f64) {
				enc.movabs_r64_imm64(.RAX, transmute(i64)r.hi)
				enc.movq_xmm_r64(.XMM1, .RAX)
				enc.ucomisd_xmm_xmm(.XMM0, .XMM1)
				append(&skip, forward(e, enc.jp_rel32))
				append(&skip, forward(e, r.hi_open ? enc.jae_rel32 : enc.ja_rel32))
			}
			append(&inside, forward(e, enc.jmp_rel32))
			for at in skip do land(e, at)
		}
	} else {
		for b in c.ints {
			skip := make([dynamic]int)
			if b.lo > i128(min(i64)) {
				enc.movabs_r64_imm64(.RCX, i64(clamp(b.lo, i128(min(i64)), i128(max(i64)))))
				enc.cmp_r64_r64(.RAX, .RCX)
				append(&skip, forward(e, enc.jl_rel32))
			}
			if b.hi < i128(max(i64)) {
				enc.movabs_r64_imm64(.RCX, i64(clamp(b.hi, i128(min(i64)), i128(max(i64)))))
				enc.cmp_r64_r64(.RAX, .RCX)
				append(&skip, forward(e, enc.jg_rel32))
			}
			append(&inside, forward(e, enc.jmp_rel32))
			for at in skip do land(e, at)
		}
	}
	// here, the value is in no cell
	if c.negated do return inside[:]
	outside := make([]int, 1)
	outside[0] = forward(e, enc.jmp_rel32)
	for at in inside do land(e, at)
	return outside
}

// int_binary: rax = rax op rcx.
int_binary :: proc(op: code.Op) -> string {
	switch op {
	case .Add:
		enc.add_r64_r64(.RAX, .RCX)
	case .Sub:
		enc.sub_r64_r64(.RAX, .RCX)
	case .Mul:
		enc.imul_r64_r64(.RAX, .RCX)
	case .Div:
		enc.cqo()
		enc.idiv_r64(.RCX)
	case .Mod:
		enc.cqo()
		enc.idiv_r64(.RCX)
		enc.mov_r64_r64(.RAX, .RDX)
	case .And:
		enc.and_r64_r64(.RAX, .RCX)
	case .Or:
		enc.or_r64_r64(.RAX, .RCX)
	case .Xor:
		enc.xor_r64_r64(.RAX, .RCX)
	case .Shl:
		enc.shl_r64_cl(.RAX)
	case .Shr:
		enc.sar_r64_cl(.RAX)
	case .Eq, .Ne, .Lt, .Le, .Gt, .Ge:
		enc.cmp_r64_r64(.RAX, .RCX)
		#partial switch op {
		case .Eq:
			enc.sete_r8(.AL)
		case .Ne:
			enc.setne_r8(.AL)
		case .Lt:
			enc.setl_r8(.AL)
		case .Le:
			enc.setle_r8(.AL)
		case .Gt:
			enc.setg_r8(.AL)
		case .Ge:
			enc.setge_r8(.AL)
		}
		enc.movzx_r64_r8(.RAX, .AL)
	case .Neg, .Not:
		return "a binary operation the machine does not compute"
	}
	return ""
}

// real_binary: rax = rax op rcx, on the bits of two doubles.
real_binary :: proc(op: code.Op) -> string {
	enc.movq_xmm_r64(.XMM0, .RAX)
	enc.movq_xmm_r64(.XMM1, .RCX)
	#partial switch op {
	case .Add:
		enc.addsd_xmm_xmm(.XMM0, .XMM1)
	case .Sub:
		enc.subsd_xmm_xmm(.XMM0, .XMM1)
	case .Mul:
		enc.mulsd_xmm_xmm(.XMM0, .XMM1)
	case .Div:
		enc.divsd_xmm_xmm(.XMM0, .XMM1)
	case .Eq, .Ne, .Lt, .Le, .Gt, .Ge:
		enc.ucomisd_xmm_xmm(.XMM0, .XMM1)
		#partial switch op {
		case .Eq:
			enc.sete_r8(.AL)
		case .Ne:
			enc.setne_r8(.AL)
		case .Lt:
			enc.setb_r8(.AL)
		case .Le:
			enc.setbe_r8(.AL)
		case .Gt:
			enc.seta_r8(.AL)
		case .Ge:
			enc.setae_r8(.AL)
		}
		enc.movzx_r64_r8(.RAX, .AL)
		return ""
	case:
		return "a float operation the machine does not compute"
	}
	enc.movq_r64_xmm(.RAX, .XMM0)
	return ""
}

// assign: the registers of the System V ABI for values of these machines; a call
// that would pass some on the stack is not code yet.
assign :: proc(machines: []code.Machine) -> (enc.X64_ABI_Assignment, string) {
	classes := make([]enc.X64_ABI_Class, len(machines))
	for m, i in machines {
		if m == .None do return {}, "an argument without a machine is not code"
		classes[i] = CLASSES[m]
	}
	assignment := enc.x64_sysv_assign(classes)
	if assignment.stack_count > 0 do return {}, "a call that passes arguments on the stack is not code yet"
	return assignment, ""
}

// pass: the arguments in the registers an assignment gives them.
pass :: proc(args: []code.Value, assignment: enc.X64_ABI_Assignment) {
	for a, i in args {
		loc := assignment.locations[i]
		switch loc.class {
		case .Integer:
			load(enc.SYSV_INT_ARGS[loc.register], a)
		case .SSE:
			load(.RAX, a)
			enc.movq_xmm_r64(enc.SYSV_SSE_ARGS[loc.register], .RAX)
		case .Stack:
		}
	}
}

// CLASSES: the class of the System V ABI that passes a value of each machine.
CLASSES := #partial [code.Machine]enc.X64_ABI_Class {
	.Int  = .Integer,
	.Real = .SSE,
	.Text = .Integer,
}

// call_symbol: the call of a symbol, its arguments in the registers the System V ABI
// gives them; an integer that comes back is extended from the bits it gives.
call_symbol :: proc(e: ^Emitter, f: ^code.Func, call: code.Foreign) -> string {
	imp := e.prog.imports[call.symbol]
	assignment, msg := assign(imp.args)
	if msg != "" do return msg
	pass(call.args, assignment)
	call_import(e, call.symbol, assignment.sse_count)
	if call.dst == code.NONE do return ""
	switch imp.result {
	case .Real:
		enc.movq_r64_xmm(.RAX, .XMM0)
	case .Int:
		switch {
		case imp.result_bits == 32 && imp.result_signed:
			enc.movsxd_r64_r32(.RAX, .EAX)
		case imp.result_bits == 32:
			enc.mov_r32_r32(.EAX, .EAX)
		case imp.result_bits == 16 && imp.result_signed:
			enc.movsx_r64_r16(.RAX, .AX)
		case imp.result_bits == 16:
			enc.movzx_r64_r16(.RAX, .AX)
		case imp.result_bits == 8 && imp.result_signed:
			enc.movsx_r64_r8(.RAX, .AL)
		case imp.result_bits == 8:
			enc.movzx_r64_r8(.RAX, .AL)
		}
	case .Text, .None:
	}
	store(call.dst, .RAX)
	return ""
}
