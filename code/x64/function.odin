package code_x64

import code ".."
import mir "../mir"
import enc "asm"

// A FUNCTION ON THE MACHINE
//
// A function laid out in blocks (code/mir) whose registers have their places: an
// integer in a register of the machine — one a call keeps, rbx and r12…r15, when it
// lives across a call; rsi, rdi, r8…r10 otherwise — or in a slot of the frame; a
// float, or a vector of two lanes of SSE2, in xmm8…xmm15 — no call keeps them: when
// it lives across a call, in a slot of the frame for each lane, lane 0 the lowest.
// rax, rcx, rdx and r11, xmm0…xmm3 are never given: an instruction computes in
// them, a call takes its floats in xmm0…xmm7. The frame keeps rbp, then the registers the function uses that a call
// keeps, then the slots, 16-aligned.

KEPT := []enc.Register64{.RBX, .R12, .R13, .R14, .R15}
SPENT := []enc.Register64{.RSI, .RDI, .R8, .R9, .R10}

target :: proc() -> mir.Target {
	kept := make([]int, len(KEPT))
	spent := make([]int, len(SPENT))
	for r, i in KEPT do kept[i] = int(r)
	for r, i in SPENT do spent[i] = int(r)
	arguments := make([]int, len(enc.SYSV_INT_ARGS))
	for r, i in enc.SYSV_INT_ARGS do arguments[i] = int(r)
	wide := make([]int, 8)
	for &x, i in wide do x = 8 + i
	return mir.Target{kept = kept, spent = spent, arguments = arguments, wide = wide}
}

// Frame: the function being emitted, and where its registers are.
Frame :: struct {
	e:      ^Emitter,
	f:      ^mir.Func,
	alloc:  mir.Allocation,
	jumps:  [dynamic]Fixup, // to blocks
	blocks: []int, // the offset of each block
}

function :: proc(e: ^Emitter, f: ^mir.Func) -> string {
	fr := Frame{e = e, f = f, alloc = mir.allocate(f, target()), blocks = make([]int, len(f.blocks))}
	enc.push_r64(.RBP)
	enc.mov_r64_r64(.RBP, .RSP)
	for r in fr.alloc.used do enc.push_r64(enc.Register64(r))
	size := 8 * fr.alloc.slots
	if (8 * len(fr.alloc.used) + size) % 16 != 0 do size += 8
	if size > 0 do enc.sub_r64_imm32(.RSP, u32(size))
	// the parameters, from the registers the System V ABI gives them
	assignment, msg := assign(f.source.params)
	if msg != "" do return msg
	moves := make([dynamic]Move)
	for loc, i in assignment.locations {
		if fr.alloc.places[i] == nil do continue // never read
		#partial switch loc.class {
		case .Integer:
			append(&moves, Move{place_of(&fr, mir.Reg(i)), Place(enc.SYSV_INT_ARGS[loc.register])})
		case .SSE:
			store_real(&fr, mir.Reg(i), enc.SYSV_SSE_ARGS[loc.register])
		}
	}
	parallel(&fr, moves[:])
	for id, k in f.order {
		fr.blocks[id] = here(e)
		for inst in f.blocks[id].insts do if msg := instruction(&fr, inst); msg != "" do return msg
		terminator(&fr, f.blocks[id].end, k + 1 < len(f.order) ? int(f.order[k + 1]) : -1)
	}
	for j in fr.jumps do patch(e, j.at, fr.blocks[j.target])
	return ""
}

// --- places ---

// Place: where a value is for an instruction: a register — of integers, or of
// floats and vectors —, a slot, or an integer.
Place :: union {
	enc.Register64,
	enc.XMMRegister,
	Frame_Slot,
	i64,
}

Frame_Slot :: distinct int

place_of :: proc(fr: ^Frame, r: mir.Reg) -> Place {
	switch p in fr.alloc.places[r] {
	case mir.Machine_Reg:
		return enc.Register64(p)
	case mir.Wide_Reg:
		return enc.XMMRegister(p)
	case mir.Slot:
		return Frame_Slot(p)
	}
	return Frame_Slot(0)
}

operand :: proc(fr: ^Frame, o: mir.Operand) -> Place {
	switch v in o {
	case mir.Reg:
		return place_of(fr, v)
	case i64:
		return v
	}
	return i64(0)
}

slot_memory :: proc(fr: ^Frame, s: Frame_Slot) -> enc.MemoryAddress {
	return enc.AddressComponents{base = .RBP, displacement = i32(-8 * (len(fr.alloc.used) + int(s) + 1))}
}

slot_address :: proc(fr: ^Frame, r: mir.Reg) -> enc.MemoryAddress {
	return slot_memory(fr, place_of(fr, r).(Frame_Slot))
}

fits_32 :: proc(v: i64) -> bool {
	return v >= i64(min(i32)) && v <= i64(max(i32))
}

// get: the value at p, into the register x: of a float, its bits.
get :: proc(fr: ^Frame, x: enc.Register64, p: Place) {
	switch v in p {
	case enc.Register64:
		if v != x do enc.mov_r64_r64(x, v)
	case enc.XMMRegister:
		enc.movq_r64_xmm(x, v)
	case Frame_Slot:
		enc.mov_r64_m64(x, slot_memory(fr, v))
	case i64:
		switch {
		case v == 0:
			enc.xor_r32_r32(enc.Register32(x), enc.Register32(x))
		case fits_32(v):
			enc.mov_r64_imm64(x, transmute(u64)v)
		case:
			enc.movabs_r64_imm64(x, v)
		}
	}
}

// put: the register x, into the place p.
put :: proc(fr: ^Frame, p: Place, x: enc.Register64) {
	#partial switch v in p {
	case enc.Register64:
		if v != x do enc.mov_r64_r64(v, x)
	case enc.XMMRegister:
		enc.movq_xmm_r64(v, x)
	case Frame_Slot:
		enc.mov_m64_r64(slot_memory(fr, v), x)
	}
}

// load_real: the float of r, into x.
load_real :: proc(fr: ^Frame, x: enc.XMMRegister, r: mir.Reg) {
	#partial switch p in place_of(fr, r) {
	case enc.XMMRegister:
		if p != x do enc.movapd_xmm_xmm(x, p)
	case Frame_Slot:
		enc.movq_xmm_m64(x, slot_memory(fr, p))
	}
}

// store_real: the float in x, into the place of r.
store_real :: proc(fr: ^Frame, r: mir.Reg, x: enc.XMMRegister) {
	#partial switch p in place_of(fr, r) {
	case enc.XMMRegister:
		if p != x do enc.movapd_xmm_xmm(p, x)
	case Frame_Slot:
		enc.movq_m64_xmm(slot_memory(fr, p), x)
	}
}

// real_in: the float of r in a register: its own, or loaded into x.
real_in :: proc(fr: ^Frame, r: mir.Reg, x: enc.XMMRegister) -> enc.XMMRegister {
	if p, is_reg := place_of(fr, r).(enc.XMMRegister); is_reg do return p
	load_real(fr, x, r)
	return x
}

// work: the register an instruction computes r in: its own, or rax.
work :: proc(fr: ^Frame, r: mir.Reg) -> enc.Register64 {
	if x, is_reg := place_of(fr, r).(enc.Register64); is_reg do return x
	return .RAX
}

// in_register: the value of o in a register: its own, or loaded into x.
in_register :: proc(fr: ^Frame, o: mir.Operand, x: enc.Register64) -> enc.Register64 {
	p := operand(fr, o)
	if r, is_reg := p.(enc.Register64); is_reg do return r
	get(fr, x, p)
	return x
}

in_register_place :: proc(fr: ^Frame, p: Place, x: enc.Register64) -> enc.Register64 {
	if r, is_reg := p.(enc.Register64); is_reg do return r
	get(fr, x, p)
	return x
}

// Move: one move of a parallel move.
Move :: struct {
	dst, src: Place,
}

// parallel: each dst takes its src, all read before any is written; a register
// moves once no move pending reads it, and r11 breaks a cycle.
parallel :: proc(fr: ^Frame, moves: []Move) {
	pending := make([dynamic]Move)
	for m in moves do if m.dst != m.src do append(&pending, m)
	for len(pending) > 0 {
		moved := false
		for m, n in pending {
			read := false
			for q in pending do read ||= q.src == m.dst
			if read do continue
			copy_place(fr, m.dst, m.src)
			ordered_remove(&pending, n)
			moved = true
			break
		}
		if moved do continue
		d := pending[0].dst
		copy_place(fr, Place(enc.Register64.R11), d)
		for &q in pending do if q.src == d do q.src = Place(enc.Register64.R11)
	}
}

copy_place :: proc(fr: ^Frame, dst, src: Place) {
	if x, is_wide := dst.(enc.XMMRegister); is_wide {
		if y, from_wide := src.(enc.XMMRegister); from_wide {
			if x != y do enc.movapd_xmm_xmm(x, y)
			return
		}
	}
	if x, is_reg := dst.(enc.Register64); is_reg {
		get(fr, x, src)
		return
	}
	if x, is_reg := src.(enc.Register64); is_reg {
		put(fr, dst, x)
		return
	}
	get(fr, .RAX, src)
	put(fr, dst, .RAX)
}

// --- instructions ---

instruction :: proc(fr: ^Frame, inst: mir.Inst) -> string {
	e := fr.e
	f := fr.f
	switch i in inst {
	case mir.Copy:
		if f.kinds[i.dst].lanes > 0 {
			x := wide_work(fr, i.dst, nil)
			load_lanes(fr, x, i.src)
			store_lanes(fr, i.dst, x)
			return ""
		}
		copy_place(fr, place_of(fr, i.dst), operand(fr, i.src))
	case mir.Real:
		get(fr, .RAX, i.bits)
		put(fr, place_of(fr, i.dst), .RAX)
	case mir.Text:
		x := work(fr, i.dst)
		enc.movabs_r64_imm64(x, i64(e.rodata_vaddr + e.text_offsets[i.text]))
		put(fr, place_of(fr, i.dst), x)
	case mir.Input:
		x := work(fr, i.dst)
		enc.movabs_r64_imm64(.R11, i64(enc.ARGS_TABLE_VADDR + 8 * i.slot))
		enc.mov_r64_m64(x, absolute(.R11))
		put(fr, place_of(fr, i.dst), x)
	case mir.Unary:
		if f.kinds[i.a].lanes > 0 do return vector_unary(fr, i)
		x := work(fr, i.dst)
		get(fr, x, place_of(fr, i.a))
		switch {
		case i.op == .Neg && f.kinds[i.a].machine == .Real:
			enc.movabs_r64_imm64(.RCX, 63)
			enc.btc_r64_r64(x, .RCX)
		case i.op == .Neg:
			enc.neg_r64(x)
		case i.op == .Not:
			enc.not_r64(x)
		case:
			return "a unary operation the machine does not compute"
		}
		put(fr, place_of(fr, i.dst), x)
	case mir.Binary:
		if f.kinds[i.a].lanes > 0 do return vector_binary(fr, i)
		if f.kinds[i.a].machine == .Real do return real_binary(fr, i)
		return int_binary(fr, i)
	case mir.Compare:
		compare(fr, i.cond, i.a, i.b)
		x := work(fr, i.dst)
		set(i.cond, f.kinds[i.a].machine == .Real)
		enc.movzx_r64_r8(x, .AL)
		put(fr, place_of(fr, i.dst), x)
	case mir.Foreign:
		imp := e.prog.imports[i.symbol]
		assignment, msg := assign(imp.args)
		if msg != "" do return msg
		pass(fr, i.args, assignment)
		call_import(e, i.symbol, assignment.sse_count)
		if i.dst == mir.NO_REG do return ""
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
		put(fr, place_of(fr, i.dst), .RAX)
	case mir.Splat:
		x := wide_work(fr, i.dst, nil)
		load_lanes(fr, x, i.a)
		store_lanes(fr, i.dst, x)
	case mir.Lanes:
		if len(i.values) != 2 do return "a vector of other than two lanes x86-64 does not write"
		get(fr, .RAX, i.values[0])
		enc.movq_xmm_r64(.XMM0, .RAX)
		get(fr, .RAX, i.values[1])
		enc.movq_xmm_r64(.XMM1, .RAX)
		enc.punpcklqdq_xmm_xmm(.XMM0, .XMM1)
		store_lanes(fr, i.dst, .XMM0)
	case mir.Reduce:
		return reduce(fr, i)
	case mir.Call:
		callee := e.prog.funcs[i.func]
		assignment, msg := assign(callee.params)
		if msg != "" do return msg
		pass(fr, i.args, assignment)
		enc.call_rel32(0)
		append(&e.calls, Fixup{here(e) - 4, i.func})
		if i.dst != mir.NO_REG do put(fr, place_of(fr, i.dst), .RAX)
	}
	return ""
}

// pass: the arguments in the registers the System V ABI gives them, by one
// parallel move; a float from its slot.
pass :: proc(fr: ^Frame, args: []mir.Operand, assignment: enc.X64_ABI_Assignment) {
	moves := make([dynamic]Move)
	for a, i in args {
		loc := assignment.locations[i]
		#partial switch loc.class {
		case .Integer:
			append(&moves, Move{Place(enc.SYSV_INT_ARGS[loc.register]), operand(fr, a)})
		}
	}
	parallel(fr, moves[:])
	for a, i in args {
		loc := assignment.locations[i]
		if loc.class == .SSE do load_real(fr, enc.SYSV_SSE_ARGS[loc.register], a.(mir.Reg))
	}
}

int_binary :: proc(fr: ^Frame, i: mir.Binary) -> string {
	f := fr.f
	b := operand(fr, i.b)
	dst := place_of(fr, i.dst)
	// compute in the destination's register, unless b is there: then, when the
	// operation commutes, the operands swap
	x := work(fr, i.dst)
	a := place_of(fr, i.a)
	if r, is_reg := b.(enc.Register64); is_reg && r == x && i.a != i.dst {
		#partial switch i.op {
		case .Add, .Mul, .And, .Or, .Xor:
			a, b = b, a
		case:
			x = .RAX
		}
	}
	constant, is_constant := b.(i64)
	#partial switch i.op {
	case .Add, .Sub, .And, .Or, .Xor:
		get(fr, x, a)
		if is_constant && fits_32(constant) {
			imm := u32(i32(constant))
			#partial switch i.op {
			case .Add:
				enc.add_r64_imm32(x, imm)
			case .Sub:
				enc.sub_r64_imm32(x, imm)
			case .And:
				enc.and_r64_imm32(x, imm)
			case .Or:
				enc.or_r64_imm32(x, imm)
			case .Xor:
				enc.xor_r64_imm32(x, imm)
			}
		} else if slot, in_slot := b.(Frame_Slot); in_slot {
			m := slot_memory(fr, slot)
			#partial switch i.op {
			case .Add:
				enc.add_r64_m64(x, m)
			case .Sub:
				enc.sub_r64_m64(x, m)
			case .And:
				enc.and_r64_m64(x, m)
			case .Or:
				enc.or_r64_m64(x, m)
			case .Xor:
				enc.xor_r64_m64(x, m)
			}
		} else {
			y := in_register_place(fr, b, .RCX)
			#partial switch i.op {
			case .Add:
				enc.add_r64_r64(x, y)
			case .Sub:
				enc.sub_r64_r64(x, y)
			case .And:
				enc.and_r64_r64(x, y)
			case .Or:
				enc.or_r64_r64(x, y)
			case .Xor:
				enc.xor_r64_r64(x, y)
			}
		}
	case .Mul:
		get(fr, x, a)
		if is_constant && fits_32(constant) {
			enc.imul_r64_r64_imm32(x, x, u32(i32(constant)))
		} else if slot, in_slot := b.(Frame_Slot); in_slot {
			enc.imul_r64_m64(x, slot_memory(fr, slot))
		} else {
			enc.imul_r64_r64(x, in_register_place(fr, b, .RCX))
		}
	case .Div, .Mod:
		y := in_register_place(fr, b, .RCX)
		get(fr, .RAX, place_of(fr, i.a))
		enc.cqo()
		enc.idiv_r64(y)
		x = i.op == .Div ? .RAX : .RDX
	case .Shl, .Shr:
		get(fr, x, a)
		if is_constant {
			k := u8(constant & 63)
			if i.op == .Shl do enc.shl_r64_imm8(x, k)
			else do enc.sar_r64_imm8(x, k)
		} else {
			get(fr, .RCX, b)
			if i.op == .Shl do enc.shl_r64_cl(x)
			else do enc.sar_r64_cl(x)
		}
	case .Pow:
		get(fr, .RAX, place_of(fr, i.a))
		get(fr, .RCX, b)
		power(fr.e, false)
		x = .RAX
	case .Mul_High:
		// rdx:rax = rax · y, unsigned
		y := in_register_place(fr, b, .RCX)
		get(fr, .RAX, place_of(fr, i.a))
		enc.mul_r64(y)
		x = .RDX
	case:
		return "a binary operation the machine does not compute"
	}
	put(fr, dst, x)
	return ""
}

// real_binary: x = a op b, in dst's register or xmm0; b in its register or in
// xmm1.
real_binary :: proc(fr: ^Frame, i: mir.Binary) -> string {
	if i.op == .Pow {
		load_real(fr, .XMM0, i.a)
		get(fr, .RCX, operand(fr, i.b))
		enc.movq_r64_xmm(.RAX, .XMM0)
		power(fr.e, true)
		put(fr, place_of(fr, i.dst), .RAX)
		return ""
	}
	x := wide_work(fr, i.dst, i.b)
	load_real(fr, x, i.a)
	y := real_in(fr, i.b.(mir.Reg), .XMM1)
	#partial switch i.op {
	case .Add:
		enc.addsd_xmm_xmm(x, y)
	case .Sub:
		enc.subsd_xmm_xmm(x, y)
	case .Mul:
		enc.mulsd_xmm_xmm(x, y)
	case .Div:
		enc.divsd_xmm_xmm(x, y)
	case:
		return "a float operation the machine does not compute"
	}
	store_real(fr, i.dst, x)
	return ""
}

// power: rax = rax ** rcx, rcx ≥ 0, by squaring: the bits of the count, from the
// lowest, the result in rdx; on a float, the bits of rax are a double.
power :: proc(e: ^Emitter, real: bool) {
	if real {
		enc.movq_xmm_r64(.XMM0, .RAX)
		enc.movabs_r64_imm64(.RDX, transmute(i64)f64(1))
		enc.movq_xmm_r64(.XMM1, .RDX)
	} else {
		enc.mov_r64_imm64(.RDX, 1)
	}
	top := here(e)
	enc.test_r64_r64(.RCX, .RCX)
	done := forward(e, enc.je_rel32)
	enc.test_r64_imm32(.RCX, 1)
	even := forward(e, enc.je_rel32)
	if real do enc.mulsd_xmm_xmm(.XMM1, .XMM0)
	else do enc.imul_r64_r64(.RDX, .RAX)
	land(e, even)
	if real do enc.mulsd_xmm_xmm(.XMM0, .XMM0)
	else do enc.imul_r64_r64(.RAX, .RAX)
	enc.shr_r64_imm8(.RCX, 1)
	back(e, enc.jmp_rel32, top)
	land(e, done)
	if real do enc.movq_r64_xmm(.RAX, .XMM1)
	else do enc.mov_r64_r64(.RAX, .RDX)
}

// compare: the flags of a cond b: integers by cmp, the first in a register; floats
// by ucomisd, from their registers.
compare :: proc(fr: ^Frame, cond: mir.Cond, a: mir.Reg, b: mir.Operand) {
	if fr.f.kinds[a].machine == .Real {
		enc.ucomisd_xmm_xmm(real_in(fr, a, .XMM0), real_in(fr, b.(mir.Reg), .XMM1))
		return
	}
	x := in_register(fr, a, .RAX)
	switch v in operand(fr, b) {
	case i64:
		if fits_32(v) {
			enc.cmp_r64_imm32(x, u32(i32(v)))
		} else {
			get(fr, .RCX, v)
			enc.cmp_r64_r64(x, .RCX)
		}
	case Frame_Slot:
		enc.cmp_r64_m64(x, slot_memory(fr, v))
	case enc.Register64:
		enc.cmp_r64_r64(x, v)
	case enc.XMMRegister:
	// an integer is never there
	}
}

// set: al = the cond of the flags; on floats, the unsigned conditions.
set :: proc(cond: mir.Cond, real: bool) {
	switch cond {
	case .Eq:
		enc.sete_r8(.AL)
	case .Ne:
		enc.setne_r8(.AL)
	case .Lt:
		if real do enc.setb_r8(.AL)
		else do enc.setl_r8(.AL)
	case .Le:
		if real do enc.setbe_r8(.AL)
		else do enc.setle_r8(.AL)
	case .Gt:
		if real do enc.seta_r8(.AL)
		else do enc.setg_r8(.AL)
	case .Ge:
		if real do enc.setae_r8(.AL)
		else do enc.setge_r8(.AL)
	case .Below_Eq:
		enc.setbe_r8(.AL)
	case .Above:
		enc.seta_r8(.AL)
	}
}

// jump_if: the jump of a cond, or of its contrary; on floats, the unsigned ones.
jump_if :: proc(cond: mir.Cond, real, contrary: bool) -> proc(offset: i32) {
	switch contrary ? mir.CONTRARY[cond] : cond {
	case .Eq:
		return enc.je_rel32
	case .Ne:
		return enc.jne_rel32
	case .Lt:
		return real ? enc.jb_rel32 : enc.jl_rel32
	case .Le:
		return real ? enc.jbe_rel32 : enc.jle_rel32
	case .Gt:
		return real ? enc.ja_rel32 : enc.jg_rel32
	case .Ge:
		return real ? enc.jae_rel32 : enc.jge_rel32
	case .Below_Eq:
		return enc.jbe_rel32
	case .Above:
		return enc.ja_rel32
	}
	return enc.jmp_rel32
}

// to_block: a jump to a block, patched once it is placed.
to_block :: proc(fr: ^Frame, jump: proc(offset: i32), b: mir.Block_Id) {
	jump(0)
	append(&fr.jumps, Fixup{here(fr.e) - 4, int(b)})
}

// terminator: the end of a block; the block laid out next is reached by falling
// through.
terminator :: proc(fr: ^Frame, t: mir.Terminator, next: int) {
	switch v in t {
	case mir.Jump:
		if int(v.to) != next do to_block(fr, enc.jmp_rel32, v.to)
	case mir.Branch:
		real := fr.f.kinds[v.a].machine == .Real
		compare(fr, v.cond, v.a, v.b)
		if real {
			// unordered: only Ne holds
			to_block(fr, enc.jp_rel32, v.cond == .Ne ? v.yes : v.no)
			to_block(fr, jump_if(v.cond, true, false), v.yes)
			if int(v.no) != next do to_block(fr, enc.jmp_rel32, v.no)
			return
		}
		if int(v.yes) == next {
			to_block(fr, jump_if(v.cond, false, true), v.no)
			return
		}
		to_block(fr, jump_if(v.cond, false, false), v.yes)
		if int(v.no) != next do to_block(fr, enc.jmp_rel32, v.no)
	case mir.Return:
		if v.value == mir.NO_REG do enc.xor_r32_r32(.EAX, .EAX)
		else do get(fr, .RAX, place_of(fr, v.value))
		if len(fr.alloc.used) > 0 do enc.lea_r64_m64(.RSP, enc.AddressComponents{base = .RBP, displacement = i32(-8 * len(fr.alloc.used))})
		else do enc.mov_r64_r64(.RSP, .RBP)
		#reverse for r in fr.alloc.used do enc.pop_r64(enc.Register64(r))
		enc.pop_r64(.RBP)
		enc.ret()
	}
}

// --- vectors ---

// vector_memory: where the lanes of the vector r are, in the frame, lane 0 first.
vector_memory :: proc(fr: ^Frame, r: mir.Reg) -> enc.MemoryAddress {
	return slot_memory(fr, place_of(fr, r).(Frame_Slot) + Frame_Slot(fr.f.kinds[r].lanes - 1))
}

// load_lanes: o into x: a vector, its lanes; a value, in each lane.
load_lanes :: proc(fr: ^Frame, x: enc.XMMRegister, o: mir.Operand) {
	r, is_reg := o.(mir.Reg)
	switch {
	case is_reg && fr.f.kinds[r].lanes > 0:
		#partial switch p in place_of(fr, r) {
		case enc.XMMRegister:
			if p != x do enc.movapd_xmm_xmm(x, p)
		case Frame_Slot:
			enc.movdqu_xmm_m128(x, vector_memory(fr, r))
		}
		return
	case is_reg && fr.f.kinds[r].machine == .Real:
		load_real(fr, x, r)
	case:
		enc.movq_xmm_r64(x, in_register(fr, o, .RAX))
	}
	enc.punpcklqdq_xmm_xmm(x, x)
}

// store_lanes: the vector in x, into the place of r.
store_lanes :: proc(fr: ^Frame, r: mir.Reg, x: enc.XMMRegister) {
	#partial switch p in place_of(fr, r) {
	case enc.XMMRegister:
		if p != x do enc.movapd_xmm_xmm(p, x)
	case Frame_Slot:
		enc.movdqu_m128_xmm(vector_memory(fr, r), x)
	}
}

// bounds_of: the bounds of an operand: of a register, or the integer it is.
bounds_of :: proc(fr: ^Frame, o: mir.Operand) -> code.Bounds {
	switch v in o {
	case mir.Reg:
		return fr.f.kinds[v].bounds
	case i64:
		return {i128(v), i128(v)}
	}
	return code.EVERY
}

in_32 :: proc(b: code.Bounds) -> bool {
	return b.lo >= 0 && b.hi < 1 << 32
}

// wide_work: the register an operation on floats or vectors computes dst in: its
// own, unless b is there; or xmm0.
wide_work :: proc(fr: ^Frame, dst: mir.Reg, b: mir.Operand) -> enc.XMMRegister {
	d, is_reg := place_of(fr, dst).(enc.XMMRegister)
	if !is_reg do return .XMM0
	if r, reads := b.(mir.Reg); reads {
		if p, in_reg := place_of(fr, r).(enc.XMMRegister); in_reg && p == d do return .XMM0
	}
	return d
}

// lanes_in: the vector o in a register: its own, or loaded into x — a value, in
// each lane.
lanes_in :: proc(fr: ^Frame, o: mir.Operand, x: enc.XMMRegister) -> enc.XMMRegister {
	if r, is_reg := o.(mir.Reg); is_reg && fr.f.kinds[r].lanes > 0 {
		if p, in_reg := place_of(fr, r).(enc.XMMRegister); in_reg do return p
	}
	load_lanes(fr, x, o)
	return x
}

// vector_binary: x = a op b, in each lane, in dst's register or xmm0; b a vector,
// or in each lane.
vector_binary :: proc(fr: ^Frame, i: mir.Binary) -> string {
	i := i
	a := fr.f.kinds[i.a]
	// b in the register of dst: when the operation commutes, the operands swap
	if b, is_reg := i.b.(mir.Reg); is_reg && wide_work(fr, i.dst, i.b) == .XMM0 && fr.f.kinds[b].lanes > 0 {
		#partial switch i.op {
		case .Add, .Mul, .And, .Or, .Xor:
			if i.op != .Mul || a.machine == .Real || in_32(a.bounds) == in_32(fr.f.kinds[b].bounds) do i.a, i.b = b, i.a
		}
	}
	x := wide_work(fr, i.dst, i.b)
	load_lanes(fr, x, i.a)
	if a.machine == .Real {
		y := lanes_in(fr, i.b, .XMM1)
		#partial switch i.op {
		case .Add:
			enc.addpd_xmm_xmm(x, y)
		case .Sub:
			enc.subpd_xmm_xmm(x, y)
		case .Mul:
			enc.mulpd_xmm_xmm(x, y)
		case .Div:
			enc.divpd_xmm_xmm(x, y)
		case:
			return "an operation on lanes of floats x86-64 does not write"
		}
	} else {
		#partial switch i.op {
		case .Shl, .Shr:
			count, constant := i.b.(i64)
			if !constant do return "a shift of lanes by lanes x86-64 does not write"
			k := u8(count & 63)
			switch {
			case i.op == .Shl:
				enc.psllq_xmm_imm8(x, k)
			case a.bounds.lo >= 0:
				enc.psrlq_xmm_imm8(x, k)
			case:
				// arithmetic, from logical: m the sign of each lane, ((x ^ m) >> k) ^ m
				enc.pshufd_xmm_xmm_imm8(.XMM1, x, 0xF5)
				enc.psrad_xmm_imm8(.XMM1, 31)
				enc.pxor_xmm_xmm(x, .XMM1)
				enc.psrlq_xmm_imm8(x, k)
				enc.pxor_xmm_xmm(x, .XMM1)
			}
		case:
			y := lanes_in(fr, i.b, .XMM1)
			#partial switch i.op {
			case .Add:
				enc.paddq_xmm_xmm(x, y)
			case .Sub:
				enc.psubq_xmm_xmm(x, y)
			case .And:
				enc.pand_xmm_xmm(x, y)
			case .Or:
				enc.por_xmm_xmm(x, y)
			case .Xor:
				enc.pxor_xmm_xmm(x, y)
			case .Mul:
				if in_32(a.bounds) && in_32(bounds_of(fr, i.b)) {
					enc.pmuludq_xmm_xmm(x, y)
					break
				}
				// a·b in 64 bits: lo(a)·lo(b) + (hi(a)·lo(b) + lo(a)·hi(b)) << 32
				enc.pshufd_xmm_xmm_imm8(.XMM2, x, 0xE4)
				enc.psrlq_xmm_imm8(.XMM2, 32)
				enc.pmuludq_xmm_xmm(.XMM2, y)
				enc.pshufd_xmm_xmm_imm8(.XMM3, y, 0xE4)
				enc.psrlq_xmm_imm8(.XMM3, 32)
				enc.pmuludq_xmm_xmm(.XMM3, x)
				enc.paddq_xmm_xmm(.XMM2, .XMM3)
				enc.psllq_xmm_imm8(.XMM2, 32)
				enc.pmuludq_xmm_xmm(x, y)
				enc.paddq_xmm_xmm(x, .XMM2)
			case:
				return "an operation on lanes of integers x86-64 does not write"
			}
		}
	}
	store_lanes(fr, i.dst, x)
	return ""
}

// vector_unary: op a, in each lane.
vector_unary :: proc(fr: ^Frame, i: mir.Unary) -> string {
	a := fr.f.kinds[i.a]
	load_lanes(fr, .XMM0, i.a)
	switch {
	case i.op == .Neg && a.machine == .Real:
		// the sign bit of each lane
		enc.movabs_r64_imm64(.RAX, min(i64))
		enc.movq_xmm_r64(.XMM1, .RAX)
		enc.punpcklqdq_xmm_xmm(.XMM1, .XMM1)
		enc.pxor_xmm_xmm(.XMM0, .XMM1)
	case i.op == .Neg:
		enc.pxor_xmm_xmm(.XMM1, .XMM1)
		enc.psubq_xmm_xmm(.XMM1, .XMM0)
		enc.pshufd_xmm_xmm_imm8(.XMM0, .XMM1, 0xE4)
	case i.op == .Not:
		enc.pcmpeqd_xmm_xmm(.XMM1, .XMM1)
		enc.pxor_xmm_xmm(.XMM0, .XMM1)
	case:
		return "an operation on lanes x86-64 does not write"
	}
	store_lanes(fr, i.dst, .XMM0)
	return ""
}

// reduce: the two lanes of a, by op.
reduce :: proc(fr: ^Frame, i: mir.Reduce) -> string {
	a := fr.f.kinds[i.a]
	if a.lanes != 2 do return "a reduction of other than two lanes x86-64 does not write"
	load_lanes(fr, .XMM0, i.a)
	enc.pshufd_xmm_xmm_imm8(.XMM1, .XMM0, 0x4E)
	if a.machine == .Real {
		#partial switch i.op {
		case .Add:
			enc.addsd_xmm_xmm(.XMM0, .XMM1)
		case .Mul:
			enc.mulsd_xmm_xmm(.XMM0, .XMM1)
		case:
			return "a reduction of floats x86-64 does not write"
		}
		store_real(fr, i.dst, .XMM0)
		return ""
	}
	enc.movq_r64_xmm(.RAX, .XMM0)
	enc.movq_r64_xmm(.RCX, .XMM1)
	#partial switch i.op {
	case .Add:
		enc.add_r64_r64(.RAX, .RCX)
	case .Mul:
		enc.imul_r64_r64(.RAX, .RCX)
	case .And:
		enc.and_r64_r64(.RAX, .RCX)
	case .Or:
		enc.or_r64_r64(.RAX, .RCX)
	case .Xor:
		enc.xor_r64_r64(.RAX, .RCX)
	case:
		return "a reduction x86-64 does not write"
	}
	put(fr, place_of(fr, i.dst), .RAX)
	return ""
}
