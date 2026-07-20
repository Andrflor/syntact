package compiler

import bc "bytecode"

// LOWERING — reduced IR (^Type DAG) → the neutral bytecode (package `bytecode`).
// The one codegen part that must know both worlds, so it lives in package compiler.
// Memoization keyed by node ADDRESS carries the reducer's CSE through: a node
// reached twice returns the same vN.

// op_to_bc maps Operator_Kind to BC_Op. Unmapped operators fall back to Add and
// are guarded upstream (non-arithmetic operators don't reach lowering).
op_to_bc :: proc(op: Operator_Kind) -> bc.BC_Op {
	#partial switch op {
	case .Add:
		return .Add
	case .Subtract:
		return .Subtract
	case .Multiply:
		return .Multiply
	case .Divide:
		return .Divide
	case .Mod:
		return .Mod
	case .And, .BitAnd:
		return .BitAnd
	case .Or, .BitOr:
		return .BitOr
	case .Xor:
		return .BitXor
	case .LShift:
		return .LShift
	case .RShift:
		return .RShift
	case .Equal:
		return .Equal
	case .NotEqual:
		return .NotEqual
	case .Less:
		return .Less
	case .Greater:
		return .Greater
	case .LessEqual:
		return .LessEqual
	case .GreaterEqual:
		return .GreaterEqual
	}
	return .Add
}

// machine_type_of derives a reduced node's Machine_Type. Single point of truth for
// the int/float width-and-signedness mapping. .None = no materializable layout yet
// (unsized int/float, symbolic string), which the caller rejects.
machine_type_of :: proc(node: ^Type) -> bc.Machine_Type {
	if node == nil do return .None
	#partial switch v in node^ {
	case Integer_Type:
		if int_is_concrete(v) {
			return bc.mtype_for_int_value(i64(int_value(v)))
		}
		if len(v.integer_intervals) == 1 {
			iv := v.integer_intervals[0]
			if lay, ok := int_layout(iv); ok {
				return bc.mtype_from_layout(lay.bits, lay.signed)
			}
			// Non-canonical range: smallest type that contains it (known by construction).
			lo, hi: Maybe(i64)
			if l, lok := iv.lo.?; lok do lo = i64(l)
			if h, hok := iv.hi.?; hok do hi = i64(h)
			return bc.mtype_for_range(lo, hi)
		}
		return .I64
	case Float_Type:
		switch v.kind {
		case .f32:
			return .F32
		case .f64:
			return .F64
		case .none:
			return .F64
		}
	case Bool_Type:
		return .U8
	case String_Type:
		if string_is_concrete(v) do return .Str
		return .None
	case Cast_Type:
		if tgt, ok := cast_target(v.target); ok {
			switch tgt.kind {
			case .Integer:
				return bc.mtype_from_layout(tgt.width, tgt.signed)
			case .Float:
				return tgt.float_kind == .f32 ? .F32 : .F64
			case .Bool:
				return .U8
			case .String, .Char:
				return .Str
			}
		}
		return .None
	case Compose_Type:
		if env := fold_type(node); env != nil && env != node {
			return machine_type_of(env)
		}
		lm := machine_type_of(v.left)
		rm := machine_type_of(v.right)
		return bc.mtype_wider(lm, rm)
	}
	return .None
}

BC_Lower :: struct {
	prog: ^bc.BC_Program,
	memo: map[^Type]bc.BC_Value, // DAG node → its already-lowered vN (CSE)
}

bc_fresh_value :: proc(l: ^BC_Lower, mt: bc.Machine_Type = .I64) -> bc.BC_Value {
	v := bc.BC_Value(l.prog.value_count)
	l.prog.value_count += 1
	append(&l.prog.value_types, mt)
	return v
}

bc_fail :: proc(l: ^BC_Lower, msg: string) -> bc.BC_Value {
	if l.prog.error == "" do l.prog.error = msg
	return bc_fresh_value(l)
}

bc_fresh_label :: proc(l: ^BC_Lower) -> bc.BC_Label {
	lab := bc.BC_Label(l.prog.label_count)
	l.prog.label_count += 1
	return lab
}

bc_emit :: proc(l: ^BC_Lower, inst: bc.BC_Inst) {
	append(&l.prog.insts, inst)
}

// lower_to_bytecode turns the reduced DAG into the neutral bytecode every backend
// shares. `root` is the value the main scope reduces to (reduce(scope)).
lower_to_bytecode :: proc(root: ^Type) -> ^bc.BC_Program {
	if root == nil do return nil
	prog := new(bc.BC_Program)
	l := BC_Lower {
		prog = prog,
		memo = make(map[^Type]bc.BC_Value),
	}
	defer delete(l.memo)
	result := bc_lower_value(&l, root)
	prog.result_type = machine_type_of(root)
	if prog.result_type == .None && int(result) < len(prog.value_types) {
		prog.result_type = prog.value_types[result]
	}
	bc_emit(&l, bc.BC_Ret{result})
	// Affine canonicalization happens upstream in the reducer; bytecode is minimal.
	return prog
}

bc_lower_value :: proc(l: ^BC_Lower, node: ^Type) -> bc.BC_Value {
	if node == nil {
		dst := bc_fresh_value(l)
		bc_emit(l, bc.BC_Const{dst, 0})
		return dst
	}
	if v, ok := l.memo[node]; ok do return v // ← CSE: shared DAG node, one vN

	dst: bc.BC_Value
	#partial switch v in node^ {
	case Integer_Type:
		if int_is_concrete(v) {
			dst = bc_fresh_value(l, .I64)
			bc_emit(l, bc.BC_Const{dst, i64(int_value(v))})
		} else {
			dst = bc_lower_fixed_point(l, node)
		}

	case Float_Type:
		if float_is_concrete(v) {
			dst = bc_fresh_value(l, machine_type_of(node))
			bc_emit(l, bc.BC_Const_F{dst, float_value(v)})
		} else {
			dst = bc_lower_fixed_point(l, node)
		}

	case Bool_Type:
		dst = bc_fresh_value(l, .U8)
		bc_emit(l, bc.BC_Const{dst, bool_is_concrete(v) && bool_value(v) ? 1 : 0})

	case None_Type:
		// Empty set / absence of a value (e.g. `true & false`) materializes as 0.
		dst = bc_fresh_value(l, .I64)
		bc_emit(l, bc.BC_Const{dst, 0})

	case String_Type:
		if string_is_concrete(v) {
			dst = bc_lower_string_const(l, string_value(v))
		} else {
			dst = bc_fail(l, "codegen: symbolic string not yet supported (needs pattern capture)")
		}

	case Cast_Type:
		dst = bc_lower_fixed_point(l, node)

	case Unknown_Type:
		dst = bc_lower_fixed_point(l, node)

	case Compose_Type:
		// A string-domain compose is an ordered sequence, not arithmetic (needs
		// pattern capture, not yet implemented). Reject before lowering operands.
		if bc_compose_is_string(node) {
			dst = bc_fail(
				l,
				"codegen: symbolic string concatenation not yet supported (needs pattern capture)",
			)
		} else {
			dst = bc_lower_compose(l, node, v)
		}

	case Pattern_Type:
		dst = bc_lower_pattern(l, v)

	case Execute_Type, Carve_Type:
		// A residual recursive collapse (a symbolic scrutinee kept the pattern
		// symbolic) has no closed form to emit: the bytecode has no loops yet.
		dst = bc_fail(
			l,
			"codegen: recursion over a symbolic ?? does not lower yet (the bytecode has no loops)",
		)

	case:
		dst = bc_fail(l, "codegen: unsupported value in lowering")
	}

	l.memo[node] = dst
	return dst
}

// bc_const_int returns a node's value as an i64 when it is a concrete integer
// (foldable into an immediate), else ok=false.
bc_const_int :: proc(node: ^Type) -> (i64, bool) {
	if node == nil do return 0, false
	#partial switch v in node^ {
	case Integer_Type:
		if int_is_concrete(v) do return i64(int_value(v)), true
	}
	return 0, false
}

// bc_lower_compose lowers an arithmetic/comparison node, choosing the immediate
// mnemonic when an operand is a concrete integer. For non-commutative ops only the
// RIGHT operand may be the immediate; commutative ops normalize the constant there.
bc_lower_compose :: proc(l: ^BC_Lower, node: ^Type, v: Compose_Type) -> bc.BC_Value {
	op := op_to_bc(v.operator)
	mt := machine_type_of(node)
	cmp := bc.bc_op_is_comparison(op)

	lk, l_const := bc_const_int(v.left)
	rk, r_const := bc_const_int(v.right)

	// Float operands never fold to an integer immediate — keep them register form.
	is_float := bc.mtype_is_float(mt)
	if is_float {l_const = false;r_const = false}

	commutative :=
		op == .Add ||
		op == .Multiply ||
		op == .BitAnd ||
		op == .BitOr ||
		op == .BitXor ||
		op == .Equal ||
		op == .NotEqual

	// a op #rk — always valid (immediate is the right side).
	if r_const && !l_const {
		a := bc_lower_value(l, v.left)
		return bc_emit_imm(l, node, op, a, rk, cmp, mt)
	}
	// #lk op b  ==  b op #lk on a commutative op.
	if l_const && !r_const && commutative {
		b := bc_lower_value(l, v.right)
		return bc_emit_imm(l, node, op, b, lk, cmp, mt)
	}

	// General register/register form.
	a := bc_lower_value(l, v.left)
	b := bc_lower_value(l, v.right)
	if mt == .None do mt = bc.mtype_wider(l.prog.value_types[a], l.prog.value_types[b])
	if cmp {
		dst := bc_fresh_value(l, .U8)
		bc_emit(l, bc.BC_Cmp{dst, op, a, b})
		return dst
	}
	dst := bc_fresh_value(l, mt)
	bc_emit(l, bc.BC_Bin{dst, op, a, b})
	return dst
}

bc_emit_imm :: proc(
	l: ^BC_Lower,
	node: ^Type,
	op: bc.BC_Op,
	a: bc.BC_Value,
	imm: i64,
	cmp: bool,
	mt_in: bc.Machine_Type,
) -> bc.BC_Value {
	mt := mt_in
	if mt == .None do mt = l.prog.value_types[a]
	if cmp {
		dst := bc_fresh_value(l, .U8)
		bc_emit(l, bc.BC_Cmp_Imm{dst, op, a, imm})
		return dst
	}
	dst := bc_fresh_value(l, mt)
	bc_emit(l, bc.BC_Bin_Imm{dst, op, a, imm})
	return dst
}

// A ??N fixed point → ONE Load_Arg{slot, width, signed}; the Load_Arg alone carries
// the domain (??::u8 normalized by the backend's movzx/movsx, no separate mask).
// fixedpoint_id gives the stable, appearance-ordered index = the argv position.
bc_lower_fixed_point :: proc(l: ^BC_Lower, node: ^Type) -> bc.BC_Value {
	slot := fixedpoint_id(node)
	mt := machine_type_of(node)

	if bc.mtype_is_float(mt) {
		dst := bc_fresh_value(l, mt)
		bc_emit(l, bc.BC_Load_Arg{dst, slot, bc.mtype_bits(mt), true})
		return dst
	}

	width, signed := bc_unknown_domain(node)
	dst := bc_fresh_value(l, mt == .None ? .I64 : mt)
	bc_emit(l, bc.BC_Load_Arg{dst, slot, width, signed})
	return dst
}

// bc_lower_string_const lays a concrete string into .rodata and emits a pointer.
bc_lower_string_const :: proc(l: ^BC_Lower, s: string) -> bc.BC_Value {
	id := len(l.prog.rodata)
	append(&l.prog.rodata, s)
	dst := bc_fresh_value(l, .Str)
	bc_emit(l, bc.BC_Str_Const{dst, s, id})
	return dst
}

// bc_unknown_domain reads a ??'s declared domain width/signedness from the
// Cast_Type that pins it (??::u8 → {8,false}). A bare Unknown is unsized.
bc_unknown_domain :: proc(node: ^Type) -> (width: uint, signed: bool) {
	if node == nil do return 0, false
	#partial switch v in node^ {
	case Cast_Type:
		if tgt, ok := cast_target(v.target); ok {
			if tgt.kind == .Integer do return tgt.width, tgt.signed
			if tgt.kind == .Bool do return 8, false
		}
	}
	return 0, false
}

// A pattern whose target survives as a fixed point becomes a branch chain: test
// each branch's match against the target, jump to the firing product.
bc_lower_pattern :: proc(l: ^BC_Lower, p: Pattern_Type) -> bc.BC_Value {
	target := bc_lower_value(l, p.target)
	end := bc_fresh_label(l)
	// Merge slot: every branch writes its product here via BC_Move (a phi).
	rt := len(p.branches) > 0 ? machine_type_of(p.branches[0].product) : bc.Machine_Type.I64
	if rt == .None do rt = .I64
	result := bc_fresh_value(l, rt)

	for branch in p.branches {
		// A bool value-match (`=true`/`=false`): fire when target equals the bool.
		if bval, is_bool := bc_branch_bool_value(branch); is_bool {
			next := bc_fresh_label(l)
			want := bc_fresh_value(l);bc_emit(l, bc.BC_Const{want, bval ? 1 : 0})
			eq := bc_fresh_value(l, .U8);bc_emit(l, bc.BC_Cmp{eq, .Equal, target, want})
			bc_emit(l, bc.BC_Branch_Zero{eq, next}) // target != bval → skip this branch
			prod := bc_lower_value(l, branch.product)
			bc_emit(l, bc.BC_Move{result, prod})
			bc_emit(l, bc.BC_Jump{end})
			bc_emit(l, bc.BC_Label_Def{next})
			continue
		}
		lo, hi, ok := bc_branch_int_range(branch)
		if !ok {
			prod := bc_lower_value(l, branch.product)
			bc_emit(l, bc.BC_Move{result, prod})
			bc_emit(l, bc.BC_Jump{end})
			continue
		}
		next := bc_fresh_label(l)
		lo_v := bc_fresh_value(l);bc_emit(l, bc.BC_Const{lo_v, lo})
		ge_lo := bc_fresh_value(l, .U8);bc_emit(l, bc.BC_Cmp{ge_lo, .GreaterEqual, target, lo_v})
		bc_emit(l, bc.BC_Branch_Zero{ge_lo, next})
		hi_v := bc_fresh_value(l);bc_emit(l, bc.BC_Const{hi_v, hi})
		le_hi := bc_fresh_value(l, .U8);bc_emit(l, bc.BC_Cmp{le_hi, .LessEqual, target, hi_v})
		bc_emit(l, bc.BC_Branch_Zero{le_hi, next})
		prod := bc_lower_value(l, branch.product)
		bc_emit(l, bc.BC_Move{result, prod})
		bc_emit(l, bc.BC_Jump{end})
		bc_emit(l, bc.BC_Label_Def{next})
	}
	bc_emit(l, bc.BC_Label_Def{end})
	return result
}

// Extract a concrete bool from a value-match branch. Only a singleton Bool_Type
// qualifies — a full `{true,false}` is not a test. A value-match branch (`=v`) is a
// producer scope `{-> v}`; read through its single production to the reified value.
bc_branch_bool_value :: proc(branch: Pattern_Branch) -> (val: bool, ok: bool) {
	if branch.match == nil do return false, false
	folded := fold_type(branch.match)
	if folded == nil do folded = branch.match
	scope, is_scope := folded^.(Scope_Type)
	if !is_scope do return false, false
	prods := scope_productions(scope)
	if len(prods) != 1 || prods[0] == nil do return false, false
	inner := fold_type(prods[0])
	if inner == nil do inner = prods[0]
	#partial switch b in inner^ {
	case Bool_Type:
		if v, has := b.value.?; has do return v, true
	}
	return false, false
}

// Extract a concrete integer [lo,hi] match from a pattern branch, if it is one.
bc_branch_int_range :: proc(branch: Pattern_Branch) -> (lo: i64, hi: i64, ok: bool) {
	if branch.match == nil do return 0, 0, false
	if it, ok := fold_type_intervals(branch.match).?; ok {
		ints := it.integer_intervals
		if len(ints) == 1 {
			if lo, has_lo := ints[0].lo.?; has_lo {
				if hi, has_hi := ints[0].hi.?; has_hi {
					return i64(lo), i64(hi), true
				}
			}
		}
	}
	return 0, 0, false
}

// bc_compose_is_string reports whether an arithmetic node operates on strings.
bc_compose_is_string :: proc(node: ^Type) -> bool {
	if node == nil do return false
	#partial switch v in node^ {
	case Compose_Type:
		return bc_operand_is_string(v.left) || bc_operand_is_string(v.right)
	}
	return false
}

bc_operand_is_string :: proc(node: ^Type) -> bool {
	if node == nil do return false
	#partial switch v in node^ {
	case String_Type:
		return true
	case Compose_Type:
		return bc_compose_is_string(node)
	case Cast_Type:
		if tgt, ok := cast_target(v.target); ok do return tgt.kind == .String
	}
	if env := fold_type(node); env != nil {
		#partial switch e in env^ {
		case String_Type:
			return true
		}
	}
	return false
}
