package x64_assembler

import bc "../../bytecode"

// ============================================================================
// INSTRUCTION SELECTION — choosing WHAT to emit (LLVM X86ISelDAGToDAG-style).
//
// The naive emitter picks one x64 instruction per bytecode op in isolation. A
// real selector looks at a PATTERN of operations and emits the single best
// instruction that covers it. The centerpiece is the x86 address mode
//
//     base + index*scale + disp        (scale ∈ {1,2,4,8})
//
// which a single `lea dst, [base + index*scale + disp]` computes in ONE
// instruction. So `(11a) + (3b) - 4` — an add, a sub, fed by two values — folds
// into one lea instead of add+sub. This file transposes LLVM's
// matchAddressRecursively / selectLEAAddr into our bytecode (no SelectionDAG; we
// match directly on the linear SSA bytecode).
//
// X64_Address mirrors LLVM's X86ISelAddressMode. AddressComponents (in
// x64_instructions.odin) is the encodable form the assembler already supports.
// ============================================================================

X64_Address :: struct {
	has_base:  bool,
	base:      Register64,
	has_index: bool,
	index:     Register64,
	scale:     u8, // 1, 2, 4, 8
	disp:      i64, // folded constant (must fit i32 to be encodable)
}


// match_address tries to fold the expression that DEFINES value `v` into an x86
// address mode {base, index*scale, disp}. Returns ok=false if `v` isn't an
// integer arithmetic value the mode can absorb. The emitter then decides (via
// lea_is_profitable) whether to realize it as a single LEA.
//
// Operands that are themselves values already produced (loaded into registers)
// become the base / index registers; only the SHAPE (which value is scaled, the
// constant displacement) is matched here — not the sub-computations, which are
// emitted normally and live in registers by the time the root is selected.
// SINGLE-LEVEL matching (correct and conservative): the value's defining op is
// matched into ONE address mode whose operands are already-materialized register
// leaves. We do NOT recurse into operands (that caused overlapping lea roots
// stepping on each other); a future version can chain safely with a proper
// single-match worklist. The win is still real: each lea folds a *scale, a
// base+index, or a +disp into one instruction.
// match_address returns the folded address mode AND the list of intermediate
// values it dissolves. The CALLER commits `absorbed` into e.absorbed only after
// deciding the lea is profitable — so a failed/unprofitable match leaves no
// spurious absorptions.
match_address :: proc(e: ^X64_Emit, v: bc.BC_Value) -> (am: X64_Address, absorbed: [dynamic]int, ok: bool) {
	am = X64_Address{scale = 1}
	if !match_addr_rec(e, v, &am, &absorbed, 0, true) {
		delete(absorbed)
		return {}, nil, false
	}
	return am, absorbed, true
}

// match_addr_rec recursively folds the expression defining `v` into the address
// mode `am`, à la LLVM matchAddressRecursively. `is_root` is true only for the
// top value (which becomes the lea); intermediate additive nodes it dissolves are
// appended to `absorbed`. A value used MORE THAN ONCE, or a `*scale`/leaf already
// in a register, stays a leaf operand (base/index) — never dissolved.
match_addr_rec :: proc(e: ^X64_Emit, v: bc.BC_Value, am: ^X64_Address, absorbed: ^[dynamic]int, depth: int, is_root: bool) -> bool {
	if depth > 6 do return false
	pc := e.def[int(v)]
	if pc < 0 do return place_leaf(e, v, am)

	// A non-root value used elsewhere must keep its own register: it's a leaf.
	if !is_root && e.use_count[int(v)] != 1 do return place_leaf(e, v, am)

	#partial switch inst in e.prog.insts[pc] {
	case bc.BC_Bin:
		if inst.op == .Add {
			// Dissolve the add: fold both sides into the mode. Keep `inst` as an
			// absorbed intermediate (it won't be emitted; the lea covers it).
			if !match_addr_rec(e, inst.a, am, absorbed, depth + 1, false) do return false
			if !match_addr_rec(e, inst.b, am, absorbed, depth + 1, false) do return false
			if !is_root do append(absorbed, int(v))
			return true
		}
		return is_root ? false : place_leaf(e, v, am)
	case bc.BC_Bin_Imm:
		#partial switch inst.op {
		case .Add:
			if !fits_i32(am.disp + inst.imm) do return is_root ? false : place_leaf(e, v, am)
			if !match_addr_rec(e, inst.a, am, absorbed, depth + 1, false) do return false
			am.disp += inst.imm
			if !is_root do append(absorbed, int(v))
			return true
		case .Subtract:
			if !fits_i32(am.disp - inst.imm) do return is_root ? false : place_leaf(e, v, am)
			if !match_addr_rec(e, inst.a, am, absorbed, depth + 1, false) do return false
			am.disp -= inst.imm
			if !is_root do append(absorbed, int(v))
			return true
		case .Multiply:
			// `a * {2,4,8}` → index = a's REGISTER (a stays materialized), scale.
			// `a * {3,5,9}` → a is both base and index (only if both slots free).
			if (inst.imm == 2 || inst.imm == 4 || inst.imm == 8) && !am.has_index {
				rg, ok := leaf_reg(e, inst.a)
				if ok {
					am.has_index = true; am.index = rg; am.scale = u8(inst.imm)
					if !is_root do append(absorbed, int(v))
					return true
				}
			}
			if (inst.imm == 3 || inst.imm == 5 || inst.imm == 9) && !am.has_base && !am.has_index {
				rg, ok := leaf_reg(e, inst.a)
				if ok {
					am.has_base = true; am.base = rg
					am.has_index = true; am.index = rg; am.scale = u8(inst.imm - 1)
					if !is_root do append(absorbed, int(v))
					return true
				}
			}
			return is_root ? false : place_leaf(e, v, am)
		case .LShift:
			if inst.imm >= 0 && inst.imm <= 3 && !am.has_index {
				rg, ok := leaf_reg(e, inst.a)
				if ok {
					am.has_index = true; am.index = rg; am.scale = u8(1 << uint(inst.imm))
					if !is_root do append(absorbed, int(v))
					return true
				}
			}
			return is_root ? false : place_leaf(e, v, am)
		}
	}
	// Not foldable: a root that can't fold isn't a lea; a non-root is a leaf.
	return is_root ? false : place_leaf(e, v, am)
}

// place_leaf puts a value's register into the first free slot (base, then index).
place_leaf :: proc(e: ^X64_Emit, v: bc.BC_Value, am: ^X64_Address) -> bool {
	rg, ok := leaf_reg(e, v)
	if !ok do return false
	if !am.has_base {
		am.has_base = true; am.base = rg
		return true
	}
	if !am.has_index {
		am.has_index = true; am.index = rg; am.scale = 1
		return true
	}
	return false // both slots full
}

// leaf_reg returns the register a value lives in (its allocated home). Only a
// register-homed value can be an address operand; a spilled one can't.
leaf_reg :: proc(e: ^X64_Emit, v: bc.BC_Value) -> (Register64, bool) {
	loc := e.alloc.locs[int(v)]
	if loc.kind == .Register do return loc.reg, true
	return .RAX, false
}

// lea_is_profitable decides whether realizing the matched address as a single LEA
// beats emitting the operations separately (LLVM selectLEAAddr's cost rule).
// Profitable when LEA collapses ≥2 operations: an index*scale plus something, or
// base+index, or base/index plus a displacement.
lea_is_profitable :: proc(am: X64_Address) -> bool {
	ops := 0
	if am.has_base do ops += 1
	if am.has_index do ops += 1
	if am.scale > 1 do ops += 1
	if am.disp != 0 do ops += 1
	// One operand alone (just a base, or just an index*1) is a plain mov/identity;
	// LEA pays off from two folded components up.
	return ops >= 2 && (am.has_base || am.has_index)
}

fits_i32 :: proc(x: i64) -> bool {
	return x >= -2147483648 && x <= 2147483647
}

// select_lea_roots scans the program and, for each value whose defining op is an
// integer add/sub that match_address can fold profitably into a single LEA, marks
// it a lea root and records its address mode. Values absorbed into a root (used
// only by it, and only as the scale/disp shape) are marked `absorbed` so the
// emitter skips them. Returns lea_root: value → matched address (has_base set when
// valid). Conservative: a value used more than once is never absorbed.
//
// We process roots OUTERMOST first (reverse order) so an outer add absorbs its
// inner index*scale / +disp pieces; an inner piece already absorbed isn't itself
// made a root.
select_lea_roots :: proc(e: ^X64_Emit) -> map[int]X64_Address {
	roots := make(map[int]X64_Address)
	// Process OUTERMOST values first (reverse order): a root dissolves its inner
	// additive nodes (marking them absorbed), so they aren't re-tried as roots.
	for pc := len(e.prog.insts) - 1; pc >= 0; pc -= 1 {
		d, has_d := bc_inst_def_local(e.prog.insts[pc])
		if !has_d do continue
		if e.absorbed[d] do continue // already folded into a bigger lea
		if !is_int_dst(e, d) do continue
		if _, ok := leaf_reg(e, bc.BC_Value(d)); !ok do continue // dst must be in a register
		am, absorbed, ok := match_address(e, bc.BC_Value(d))
		if !ok {delete(absorbed); continue}
		if !lea_is_profitable(am) {delete(absorbed); continue}
		// Commit the absorptions now that we know the lea is profitable.
		for x in absorbed do e.absorbed[x] = true
		delete(absorbed)
		roots[d] = am
	}
	return roots
}

is_int_dst :: proc(e: ^X64_Emit, d: int) -> bool {
	mt := e.prog.value_types[d]
	return bc.mtype_is_int(mt) || mt == .None
}

// bc_inst_def_local mirrors bc_def (regalloc.odin) — re-exposed for isel clarity.
bc_inst_def_local :: proc(inst: bc.BC_Inst) -> (int, bool) {
	return bc_def(inst)
}

// addr_to_mem converts the matched address mode to the assembler's encodable
// AddressComponents.
addr_to_mem :: proc(am: X64_Address) -> MemoryAddress {
	ac := AddressComponents{}
	if am.has_base do ac.base = am.base
	if am.has_index {
		ac.index = am.index
		ac.scale = am.scale
	}
	if am.disp != 0 do ac.displacement = i32(am.disp)
	return ac
}
