package code_x64

import code ".."
import mir "../mir"
import enc "asm"

// A FUNCTION ON THE MACHINE
//
// A function laid out in blocks (code/mir) whose registers have their places: an
// integer in a register of the machine — one a call keeps, rbx and r12…r15, when it
// lives across a call; rsi, rdi, r8…r10 otherwise — or in a slot of the frame; a
// float in a slot. rax, rcx, rdx and r11 are never given: an instruction computes
// in them. The frame keeps rbp, then the registers the function uses that a call
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
	return mir.Target{kept = kept, spent = spent, arguments = arguments}
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
			enc.movq_m64_xmm(slot_address(&fr, mir.Reg(i)), enc.SYSV_SSE_ARGS[loc.register])
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

// Place: where a value is for an instruction: a register, a slot, or an integer.
Place :: union {
	enc.Register64,
	Frame_Slot,
	i64,
}

Frame_Slot :: distinct int

place_of :: proc(fr: ^Frame, r: mir.Reg) -> Place {
	switch p in fr.alloc.places[r] {
	case mir.Machine_Reg:
		return enc.Register64(p)
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

// get: the value at p, into the register x.
get :: proc(fr: ^Frame, x: enc.Register64, p: Place) {
	switch v in p {
	case enc.Register64:
		if v != x do enc.mov_r64_r64(x, v)
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
	case Frame_Slot:
		enc.mov_m64_r64(slot_memory(fr, v), x)
	}
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
		if loc.class == .SSE do enc.movq_xmm_m64(enc.SYSV_SSE_ARGS[loc.register], slot_address(fr, a.(mir.Reg)))
	}
}

// power_of_two: k when v = 2ᵏ, k ≥ 1.
power_of_two :: proc(v: i64) -> (k: u8, ok: bool) {
	if v < 2 || v & (v - 1) != 0 do return
	for x := v; x > 1; x >>= 1 do k += 1
	return k, true
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
	nonnegative := f.kinds[i.a].bounds.lo >= 0
	constant, is_constant := b.(i64)
	#partial switch i.op {
	case .Add, .Sub, .And, .Or, .Xor:
		get(fr, x, a)
		if is_constant && fits_32(constant) && (i.op == .Add || i.op == .Sub) {
			if i.op == .Add do enc.add_r64_imm32(x, u32(i32(constant)))
			else do enc.sub_r64_imm32(x, u32(i32(constant)))
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
		if k, shift := power_of_two(constant); is_constant && shift {
			enc.shl_r64_imm8(x, k)
		} else if is_constant && fits_32(constant) {
			enc.imul_r64_r64_imm32(x, x, u32(i32(constant)))
		} else if slot, in_slot := b.(Frame_Slot); in_slot {
			enc.imul_r64_m64(x, slot_memory(fr, slot))
		} else {
			enc.imul_r64_r64(x, in_register_place(fr, b, .RCX))
		}
	case .Div, .Mod:
		if k, shift := power_of_two(constant); is_constant && shift && nonnegative {
			// a dividend ≥ 0: a shift, a mask
			get(fr, x, a)
			if i.op == .Div do enc.shr_r64_imm8(x, k)
			else {
				get(fr, .RCX, constant - 1)
				enc.and_r64_r64(x, .RCX)
			}
		} else {
			y := in_register_place(fr, b, .RCX)
			get(fr, .RAX, place_of(fr, i.a))
			enc.cqo()
			enc.idiv_r64(y)
			x = i.op == .Div ? .RAX : .RDX
		}
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
	case:
		return "a binary operation the machine does not compute"
	}
	put(fr, dst, x)
	return ""
}

// real_binary: the floats are in slots: xmm0 op xmm1.
real_binary :: proc(fr: ^Frame, i: mir.Binary) -> string {
	enc.movq_xmm_m64(.XMM0, slot_address(fr, i.a))
	if i.op == .Pow {
		get(fr, .RCX, operand(fr, i.b))
		enc.movq_r64_xmm(.RAX, .XMM0)
		power(fr.e, true)
		put(fr, place_of(fr, i.dst), .RAX)
		return ""
	}
	enc.movq_xmm_m64(.XMM1, slot_address(fr, i.b.(mir.Reg)))
	#partial switch i.op {
	case .Add:
		enc.addsd_xmm_xmm(.XMM0, .XMM1)
	case .Sub:
		enc.subsd_xmm_xmm(.XMM0, .XMM1)
	case .Mul:
		enc.mulsd_xmm_xmm(.XMM0, .XMM1)
	case .Div:
		enc.divsd_xmm_xmm(.XMM0, .XMM1)
	case:
		return "a float operation the machine does not compute"
	}
	enc.movq_m64_xmm(slot_address(fr, i.dst), .XMM0)
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
// by ucomisd, from their slots.
compare :: proc(fr: ^Frame, cond: mir.Cond, a: mir.Reg, b: mir.Operand) {
	if fr.f.kinds[a].machine == .Real {
		enc.movq_xmm_m64(.XMM0, slot_address(fr, a))
		enc.movq_xmm_m64(.XMM1, slot_address(fr, b.(mir.Reg)))
		enc.ucomisd_xmm_xmm(.XMM0, .XMM1)
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
	c := cond
	if contrary {
		switch cond {
		case .Eq:
			c = .Ne
		case .Ne:
			c = .Eq
		case .Lt:
			c = .Ge
		case .Le:
			c = .Gt
		case .Gt:
			c = .Le
		case .Ge:
			c = .Lt
		case .Below_Eq:
			c = .Above
		case .Above:
			c = .Below_Eq
		}
	}
	switch c {
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
