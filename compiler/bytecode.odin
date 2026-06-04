package compiler

import bc "bytecode"

// ============================================================================
// LOWERING — reduced IR (^Type DAG) → the neutral bytecode (package `bytecode`).
//
// This is the one part of the codegen path that must know BOTH worlds: the
// reducer's `^Type` IR (this package) and the target-neutral bytecode (the `bc`
// package). It therefore lives in `package compiler` and translates between them
// — including mapping the AST's Operator_Kind to the bytecode's own BC_Op.
//
// Post-order DFS with memoization keyed by node ADDRESS carries the reducer's CSE
// through to the bytecode: a DAG node reached twice returns the same vN, so it is
// computed once.
// ============================================================================

// op_to_bc maps the compiler's Operator_Kind to the bytecode's neutral BC_Op.
// Only the operators the bytecode models are mapped; others fall back to Add and
// are guarded against upstream (non-arithmetic operators don't reach lowering).
op_to_bc :: proc(op: Operator_Kind) -> bc.BC_Op {
	#partial switch op {
	case .Add:          return .Add
	case .Subtract:     return .Subtract
	case .Multiply:     return .Multiply
	case .Divide:       return .Divide
	case .Mod:          return .Mod
	case .And, .BitAnd: return .BitAnd
	case .Or, .BitOr:   return .BitOr
	case .Xor:          return .BitXor
	case .LShift:       return .LShift
	case .RShift:       return .RShift
	case .Equal:        return .Equal
	case .NotEqual:     return .NotEqual
	case .Less:         return .Less
	case .Greater:      return .Greater
	case .LessEqual:    return .LessEqual
	case .GreaterEqual: return .GreaterEqual
	}
	return .Add
}

// machine_type_of derives the bytecode Machine_Type of a reduced node from its
// fold. Single point of truth for the int/float-width-and-signedness mapping.
// Returns .None when the node has no materializable machine layout yet (unsized
// int/float, symbolic string) — the caller rejects.
machine_type_of :: proc(node: ^Type) -> bc.Machine_Type {
	if node == nil do return .None
	#partial switch v in node^ {
	case Integer_Type:
		if int_is_concrete(v) {
			return bc.mtype_for_int_value(i64(int_value(v)))
		}
		if len(v.integer_intervals) == 1 {
			if lay, ok := int_layout(v.integer_intervals[0]); ok {
				return bc.mtype_from_layout(lay.bits, lay.signed)
			}
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
			case .String:
				return .Str
			}
		}
		return .None
	case Compose_Type:
		if env := fold_value_type(node); env != nil && env != node {
			return machine_type_of(env)
		}
		lm := machine_type_of(v.left)
		rm := machine_type_of(v.right)
		return bc.mtype_wider(lm, rm)
	}
	return .None
}

// ----------------------------------------------------------------------------
// Lowering state and helpers.
// ----------------------------------------------------------------------------

BC_Lower :: struct {
	prog: ^bc.BC_Program,
	memo: map[^Type]bc.BC_Value, // DAG node → its already-lowered vN (CSE)
}

// bc_fresh_value mints a new SSA value and records its Machine_Type.
bc_fresh_value :: proc(l: ^BC_Lower, mt: bc.Machine_Type = .I64) -> bc.BC_Value {
	v := bc.BC_Value(l.prog.value_count)
	l.prog.value_count += 1
	append(&l.prog.value_types, mt)
	return v
}

// bc_fail records the first lowering error and returns a placeholder value.
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
		// The empty set / absence of a value (e.g. `true & false`). Materializes
		// as 0 (exit 0 / empty), the natural "nothing" result.
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
		// A string-domain compose ("hi " + ??::string) is an ordered sequence,
		// not arithmetic — needs runtime concat + length (pattern capture), not
		// implemented yet. Reject before lowering its operands.
		if bc_compose_is_string(node) {
			dst = bc_fail(l, "codegen: symbolic string concatenation not yet supported (needs pattern capture)")
		} else {
			a := bc_lower_value(l, v.left)
			b := bc_lower_value(l, v.right)
			mt := machine_type_of(node)
			if mt == .None do mt = bc.mtype_wider(l.prog.value_types[a], l.prog.value_types[b])
			op := op_to_bc(v.operator)
			if bc.bc_op_is_comparison(op) {
				dst = bc_fresh_value(l, .U8)
				bc_emit(l, bc.BC_Cmp{dst, op, a, b})
			} else {
				dst = bc_fresh_value(l, mt)
				bc_emit(l, bc.BC_Bin{dst, op, a, b})
			}
		}

	case Pattern_Type:
		dst = bc_lower_pattern(l, v)

	case:
		dst = bc_fail(l, "codegen: unsupported value in lowering")
	}

	l.memo[node] = dst
	return dst
}

// A ??N fixed point → Load_Arg{slot: N}. fixedpoint_id gives the stable,
// appearance-ordered index, which is exactly the argv position.
//
// The ??'s declared domain (its ::u8 / ::i32 envelope) is read here and the
// value is NORMALIZED to that domain ONCE at entry: an unsigned u8 is masked
// (`and 0xff`), a signed i8 sign-extended (`shl 56; sar 56`). After this single
// normalization the analyzer has proven the downstream in range — no further
// masking.
bc_lower_fixed_point :: proc(l: ^BC_Lower, node: ^Type) -> bc.BC_Value {
	slot := fixedpoint_id(node)
	mt := machine_type_of(node)

	// A float ?? (??::f64 / ??::f32): load the argument as a double, no masking.
	if bc.mtype_is_float(mt) {
		raw := bc_fresh_value(l, mt)
		bc_emit(l, bc.BC_Load_Arg{raw, slot, bc.mtype_bits(mt), true})
		return raw
	}

	width, signed := bc_unknown_domain(node)

	raw := bc_fresh_value(l, mt == .None ? .I64 : mt)
	bc_emit(l, bc.BC_Load_Arg{raw, slot, width, signed})

	// A 64-bit (or unsized) domain needs no normalization — argv is already i64.
	if width == 0 || width >= 64 do return raw

	if !signed {
		mask := i64((u64(1) << width) - 1)
		m := bc_fresh_value(l); bc_emit(l, bc.BC_Const{m, mask})
		dst := bc_fresh_value(l, mt)
		bc_emit(l, bc.BC_Bin{dst, .BitAnd, raw, m})
		return dst
	}

	shift := i64(64 - width)
	s1 := bc_fresh_value(l); bc_emit(l, bc.BC_Const{s1, shift})
	hi := bc_fresh_value(l); bc_emit(l, bc.BC_Bin{hi, .LShift, raw, s1})
	s2 := bc_fresh_value(l); bc_emit(l, bc.BC_Const{s2, shift})
	dst := bc_fresh_value(l, mt)
	bc_emit(l, bc.BC_Bin{dst, .RShift, hi, s2})
	return dst
}

// bc_lower_string_const lays a concrete string into the program's .rodata pool
// and emits a pointer to it.
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
	// The merge slot: every branch writes its product here via BC_Move, so the
	// allocator pins all writers to one location (a proper phi).
	rt := len(p.branches) > 0 ? machine_type_of(p.branches[0].product) : bc.Machine_Type.I64
	if rt == .None do rt = .I64
	result := bc_fresh_value(l, rt)

	for branch in p.branches {
		lo, hi, ok := bc_branch_int_range(branch)
		if !ok {
			prod := bc_lower_value(l, branch.product)
			bc_emit(l, bc.BC_Move{result, prod})
			bc_emit(l, bc.BC_Jump{end})
			continue
		}
		next := bc_fresh_label(l)
		lo_v := bc_fresh_value(l); bc_emit(l, bc.BC_Const{lo_v, lo})
		ge_lo := bc_fresh_value(l, .U8); bc_emit(l, bc.BC_Cmp{ge_lo, .GreaterEqual, target, lo_v})
		bc_emit(l, bc.BC_Branch_Zero{ge_lo, next})
		hi_v := bc_fresh_value(l); bc_emit(l, bc.BC_Const{hi_v, hi})
		le_hi := bc_fresh_value(l, .U8); bc_emit(l, bc.BC_Cmp{le_hi, .LessEqual, target, hi_v})
		bc_emit(l, bc.BC_Branch_Zero{le_hi, next})
		prod := bc_lower_value(l, branch.product)
		bc_emit(l, bc.BC_Move{result, prod})
		bc_emit(l, bc.BC_Jump{end})
		bc_emit(l, bc.BC_Label_Def{next})
	}
	bc_emit(l, bc.BC_Label_Def{end})
	return result
}

// Extract a concrete integer [lo,hi] match from a pattern branch, if it is one.
bc_branch_int_range :: proc(branch: Pattern_Branch) -> (lo: i64, hi: i64, ok: bool) {
	if branch.match == nil do return 0, 0, false
	if ints, ok := fold_type_intervals(branch.match).?; ok {
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
	if env := fold_value_type(node); env != nil {
		#partial switch e in env^ {
		case String_Type:
			return true
		}
	}
	return false
}
