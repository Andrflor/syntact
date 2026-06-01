package compiler

import "core:fmt"
import "core:strconv"
import "core:strings"

reduce :: proc(scope: ^Scope_Type) -> ^Type {
	for i := 0; i < len(scope.kind); i += 1 {
		if scope.kind[i] == .Product {
			tf := scope.type_folds[i]
			if tf != nil {
				#partial switch v in tf^ {
				case Integer_Type:
					if integer_intervals_is_concrete(v.integer_intervals) {
						return tf
					}
				}
			}
			return reduce_value(scope.values[i])
		}
	}
	return nil
}

reduce_value :: proc(value: ^Type) -> ^Type {
	switch &v in value {
	case Execute_Type:
		return reduce_value(execute(v))
	case Compose_Type:
		if v.type_fold != nil {
			tf, tf_ok := v.type_fold^.(Integer_Type)
			if tf_ok && int_is_concrete(tf) {
				result := new(Type)
				result^ = make_int_result(int_value(tf))
				return result
			}
		}
		return compose(v)
	case Carve_Type:
		return carve(v)
	case Mention_Type:
		if v.match_scope != nil && v.match_index >= 0 {
			return reduce_value(v.match_scope.values[v.match_index])
		}
	case Reference_Type:
		ref := v.reference
		if ref == nil || ref.match_scope == nil || ref.match_index < 0 do return value
		target := ref.match_scope.values[ref.match_index]
		if v.target != nil {
			#partial switch &cv in v.target^ {
			case Carve_Type:
				for i := 0; i < len(cv.references); i += 1 {
					if cv.references[i].match_index == ref.match_index {
						return reduce_value(cv.values[i])
					}
				}
			}
		}
		return reduce_value(target)
	case Scope_Type:
		return reduce(&v)
	case Integer_Type:
		return value
	case Float_Type:
		return value
	case String_Type:
		return value
	case Bool_Type:
		return value
	case Range_Type:
		return value
	case None_Type:
		return value
	case Invalid_Type:
		return value
	case Unknown_Type:
		return value
	case Or_Type:
		return value
	case And_Type:
		return value
	case Negate_Type:
		return value
	}
	return value
}

execute :: proc(value: Execute_Type) -> ^Type {
	reduced := reduce_value(value.target)
	#partial switch &s in reduced^ {
	case Scope_Type:
		return reduce(&s)
	}
	return reduced
}

carve :: proc(value: Carve_Type) -> ^Type {
	reduced_source := reduce_value(value.source)
	src: ^Scope_Type = nil
	#partial switch &s in reduced_source^ {
	case Scope_Type:
		src = &s
	}
	if src == nil do return reduced_source

	scope := new(Scope_Type)
	scope.parent = src.parent
	scope.names = make([dynamic]string, len(src.names))
	scope.types = make([dynamic]^Type, len(src.types))
	scope.kind = make([dynamic]Binding_Kind, len(src.kind))
	scope.values = make([dynamic]^Type, len(src.values))
	scope.type_folds = make([dynamic]^Type, len(src.type_folds))
	scope.constraint_folds = make([dynamic]^Type, len(src.constraint_folds))

	for i := 0; i < len(src.names); i += 1 {
		scope.names[i] = src.names[i]
		scope.types[i] = src.types[i]
		scope.kind[i] = src.kind[i]
		scope.values[i] = src.values[i]
		if i < len(src.type_folds) do scope.type_folds[i] = src.type_folds[i]
		if i < len(src.constraint_folds) do scope.constraint_folds[i] = src.constraint_folds[i]
	}

	for i := 0; i < len(value.references); i += 1 {
		ref := &value.references[i]
		val := value.values[i]
		if ref.match_scope != nil && ref.match_index >= 0 && ref.match_index < len(scope.values) {
			scope.values[ref.match_index] = val
			scope.type_folds[ref.match_index] = fold_value_type(val)
		}
	}

	result := new(Type)
	result^ = scope^
	return result
}

patch_refs :: proc(scope: ^Scope_Type, old: ^Type, replacement: ^Type) {
	for i := 0; i < len(scope.values); i += 1 {
		scope.values[i] = patch_type(scope.values[i], old, replacement)
	}
}

patch_type :: proc(t: ^Type, old: ^Type, replacement: ^Type) -> ^Type {
	if t == nil do return nil
	if t == old do return replacement
	#partial switch &v in t^ {
	case Compose_Type:
		v.left = patch_type(v.left, old, replacement)
		v.right = patch_type(v.right, old, replacement)
	case Reference_Type:
		v.target = patch_type(v.target, old, replacement)
	case Mention_Type:
	case Execute_Type:
		v.target = patch_type(v.target, old, replacement)
	case Range_Type:
		v.left = patch_type(v.left, old, replacement)
		v.right = patch_type(v.right, old, replacement)
	case Or_Type:
		v.left = patch_type(v.left, old, replacement)
		v.right = patch_type(v.right, old, replacement)
	case And_Type:
		v.left = patch_type(v.left, old, replacement)
		v.right = patch_type(v.right, old, replacement)
	case Carve_Type:
		v.source = patch_type(v.source, old, replacement)
		for i := 0; i < len(v.values); i += 1 {
			v.values[i] = patch_type(v.values[i], old, replacement)
		}
	}
	return t
}

// --- compose dispatch ---

compose :: proc(value: Compose_Type) -> ^Type {
	left := value.left != nil ? reduce_value(value.left) : nil
	right := value.right != nil ? reduce_value(value.right) : nil
	lv: Type = left != nil ? left^ : nil
	rv: Type = right != nil ? right^ : nil

	result := new(Type)

	#partial switch value.operator {
	case .Add:
		result^ = compose_arith(lv, rv, .Add)
	case .Subtract:
		result^ = compose_arith(lv, rv, .Subtract)
	case .Multiply:
		result^ = compose_arith(lv, rv, .Multiply)
	case .Divide:
		result^ = compose_arith(lv, rv, .Divide)
	case .Mod:
		result^ = compose_arith(lv, rv, .Mod)
	case .Equal:
		result^ = compose_eq(lv, rv, true)
	case .NotEqual:
		result^ = compose_eq(lv, rv, false)
	case .Less:
		result^ = compose_ord(lv, rv, .Less)
	case .Greater:
		result^ = compose_ord(lv, rv, .Greater)
	case .LessEqual:
		result^ = compose_ord(lv, rv, .LessEqual)
	case .GreaterEqual:
		result^ = compose_ord(lv, rv, .GreaterEqual)
	case .BitAnd:
		result^ = compose_bitlogic(lv, rv, .BitAnd)
	case .BitOr:
		result^ = compose_bitlogic(lv, rv, .BitOr)
	case .Xor:
		result^ = compose_bitlogic(lv, rv, .Xor)
	case .BitNot, .Not:
		#partial switch l in lv {
		case Integer_Type:
			if int_is_concrete(l) {
				result^ = make_int_result(~int_value(l))
			}
		case Bool_Type:
			result^ = Bool_Type{!l.value}
		}
	case .LShift:
		result^ = compose_shift(lv, rv, true)
	case .RShift:
		result^ = compose_shift(lv, rv, false)
	}

	return result
}

compose_arith :: proc(lv, rv: Type, op: Operator_Kind) -> Type {
	li, li_ok := lv.(Integer_Type)
	ri, ri_ok := rv.(Integer_Type)
	lf, lf_ok := lv.(Float_Type)
	rf, rf_ok := rv.(Float_Type)

	if lv == nil && op == .Subtract {
		if ri_ok && int_is_concrete(ri) {
			return make_int_result(-int_value(ri))
		}
		if rf_ok && float_is_concrete(rf) {
			return make_float_result(-float_value(rf), rf.kind)
		}
		return nil
	}

	if li_ok && ri_ok && int_is_concrete(li) && int_is_concrete(ri) {
		a := int_value(li)
		b := int_value(ri)
		#partial switch op {
		case .Add:
			return make_int_result(a + b)
		case .Subtract:
			return make_int_result(a - b)
		case .Multiply:
			return make_int_result(a * b)
		case .Divide:
			if b != 0 do return make_int_result(a / b)
		case .Mod:
			if b != 0 do return make_int_result(a % b)
		}
		return nil
	}

	fl, fr: f64
	fk: FloatKind

	if lf_ok && rf_ok && float_is_concrete(lf) && float_is_concrete(rf) {
		fl = float_value(lf)
		fr = float_value(rf)
		fk = promote_float_kind(lf.kind, rf.kind)
	} else if lf_ok && float_is_concrete(lf) && ri_ok && int_is_concrete(ri) {
		fl = float_value(lf)
		fr = int_to_f64(ri)
		fk = lf.kind
	} else if li_ok && int_is_concrete(li) && rf_ok && float_is_concrete(rf) {
		fl = int_to_f64(li)
		fr = float_value(rf)
		fk = rf.kind
	} else {
		if op == .Add {
			ls, ls_ok := lv.(String_Type)
			rs, rs_ok := rv.(String_Type)
			if ls_ok && rs_ok && string_is_concrete(ls) && string_is_concrete(rs) {
				joined := strings.concatenate({string_value(ls), string_value(rs)})
				return make_string_const(joined, .double)
			}
		}
		return nil
	}

	#partial switch op {
	case .Add:
		return make_float_result(fl + fr, fk)
	case .Subtract:
		return make_float_result(fl - fr, fk)
	case .Multiply:
		return make_float_result(fl * fr, fk)
	case .Divide:
		return make_float_result(fl / fr, fk)
	}
	return nil
}


promote_float_kind :: #force_inline proc(a, b: FloatKind) -> FloatKind {
	if a == .none do return b
	if b == .none do return a
	if a == .f64 || b == .f64 do return .f64
	return .f32
}

compose_eq :: proc(lv, rv: Type, eq: bool) -> Bool_Type {
	#partial switch l in lv {
	case Integer_Type:
		if !int_is_concrete(l) do return Bool_Type{false}
		r_i, r_i_ok := rv.(Integer_Type)
		r_f, r_f_ok := rv.(Float_Type)
		if r_i_ok && int_is_concrete(r_i) {
			return Bool_Type{eq == (int_value(l) == int_value(r_i))}
		}
		if r_f_ok && float_is_concrete(r_f) {
			return Bool_Type{eq == (int_to_f64(l) == float_value(r_f))}
		}
	case Float_Type:
		if !float_is_concrete(l) do return Bool_Type{false}
		r_f, r_f_ok := rv.(Float_Type)
		r_i, r_i_ok := rv.(Integer_Type)
		lf := float_value(l)
		if r_f_ok && float_is_concrete(r_f) do return Bool_Type{eq == (lf == float_value(r_f))}
		if r_i_ok && int_is_concrete(r_i) do return Bool_Type{eq == (lf == int_to_f64(r_i))}
	case Bool_Type:
		r := rv.(Bool_Type)
		return Bool_Type{eq == (l.value == r.value)}
	case String_Type:
		r := rv.(String_Type)
		if string_is_concrete(l) && string_is_concrete(r) {
			return Bool_Type{eq == (string_value(l) == string_value(r))}
		}
		return Bool_Type{!eq}
	}
	return Bool_Type{false}
}

compose_ord :: proc(lv, rv: Type, op: Operator_Kind) -> Bool_Type {
	#partial switch l in lv {
	case Integer_Type:
		if !int_is_concrete(l) do return Bool_Type{false}
		r_i, r_i_ok := rv.(Integer_Type)
		r_f, r_f_ok := rv.(Float_Type)
		if r_i_ok && int_is_concrete(r_i) do return Bool_Type{i128_cmp(int_value(l), int_value(r_i), op)}
		if r_f_ok && float_is_concrete(r_f) do return Bool_Type{float_cmp(int_to_f64(l), float_value(r_f), op)}
	case Float_Type:
		if !float_is_concrete(l) do return Bool_Type{false}
		r_f, r_f_ok := rv.(Float_Type)
		r_i, r_i_ok := rv.(Integer_Type)
		lf := float_value(l)
		if r_f_ok && float_is_concrete(r_f) do return Bool_Type{float_cmp(lf, float_value(r_f), op)}
		if r_i_ok && int_is_concrete(r_i) do return Bool_Type{float_cmp(lf, int_to_f64(r_i), op)}
	}
	return Bool_Type{false}
}


i128_cmp :: #force_inline proc(a, b: i128, op: Operator_Kind) -> bool {
	#partial switch op {
	case .Less:
		return a < b
	case .Greater:
		return a > b
	case .LessEqual:
		return a <= b
	case .GreaterEqual:
		return a >= b
	}
	return false
}


float_cmp :: #force_inline proc(a, b: f64, op: Operator_Kind) -> bool {
	#partial switch op {
	case .Less:
		return a < b
	case .Greater:
		return a > b
	case .LessEqual:
		return a <= b
	case .GreaterEqual:
		return a >= b
	}
	return false
}

compose_bitlogic :: proc(lv, rv: Type, op: Operator_Kind) -> Type {
	#partial switch l in lv {
	case Integer_Type:
		if !int_is_concrete(l) do return nil
		r, r_ok := rv.(Integer_Type)
		if !r_ok || !int_is_concrete(r) do return nil
		a := int_value(l)
		b := int_value(r)
		val: i128
		#partial switch op {
		case .BitAnd:
			val = a & b
		case .BitOr:
			val = a | b
		case .Xor:
			val = a ~ b
		}
		return make_int_result(val)
	case Bool_Type:
		r := rv.(Bool_Type)
		#partial switch op {
		case .BitAnd:
			return Bool_Type{l.value && r.value}
		case .BitOr:
			return Bool_Type{l.value || r.value}
		case .Xor:
			return Bool_Type{l.value ~ r.value}
		}
	}
	return nil
}

compose_shift :: proc(lv, rv: Type, is_left: bool) -> Type {
	l, l_ok := lv.(Integer_Type)
	r, r_ok := rv.(Integer_Type)
	if !l_ok || !r_ok do return nil
	if !int_is_concrete(l) || !int_is_concrete(r) do return nil
	a := int_value(l)
	b := int_value(r)
	if b < 0 || b >= 128 do return nil

	val: i128
	ub := u64(b)
	if is_left {
		val = i128(u128(a) << ub)
	} else {
		val = i128(u128(a) >> ub)
	}
	return make_int_result(val)
}
