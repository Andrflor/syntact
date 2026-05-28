package compiler

import "core:fmt"
import "core:slice"
import "core:strconv"
import "core:strings"

reduce :: proc(scope: ^Scope_Type) -> ^Type {
	for i := 0; i < len(scope.kind); i += 1 {
		if scope.kind[i] == .Product {
			tf := scope.type_folds[i]
			if tf != nil && len(tf) == 1 && segs_is_concrete(tf) {
				result := new(Type)
				result^ = Integer_Type{tf}
				return result
			}
			return reduce_value(scope.values[i])
		}
	}
	return nil
}

reduce_value :: proc(value: ^Type) -> ^Type {
	switch v in value {
	case Execute_Type:
		return reduce_value(execute(v))
	case Compose_Type:
		if v.type_fold != nil {
			tf, tf_ok := v.type_fold^.(Integer_Type)
			if tf_ok && int_is_concrete(tf) {
				return v.type_fold
			}
		}
		return reduce_value(compose(v))
	case Carve_Type:
		return reduce_value(carve(v))
	case Mention_Type:
		if v.match_scope != nil && v.match_index >= 0 {
			tf := v.match_scope.type_folds[v.match_index]
			if tf != nil && len(tf) == 1 && segs_is_concrete(tf) {
				result := new(Type)
				result^ = Integer_Type{tf}
				return result
			}
			return reduce_value(v.match_scope.values[v.match_index])
		}
	case Reference_Type:
		ref := v.reference
		if ref != nil && ref.match_scope != nil && ref.match_index >= 0 {
			tf := ref.match_scope.type_folds[ref.match_index]
			if tf != nil && len(tf) == 1 && segs_is_concrete(tf) {
				result := new(Type)
				result^ = Integer_Type{tf}
				return result
			}
			return reduce_value(ref.match_scope.values[ref.match_index])
		}
		if v.target != nil {
			return reduce_value(v.target)
		}
	case Sum_Type:
	case Product_Type:
	case Negate_Type:
	case Scope_Type:
	case String_Type:
	case Integer_Type:
	case Float_Type:
	case Range_Type:
	case Bool_Type:
	case None_Type:
	case Invalid_Type:
	case Unknown_Type:
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
	scope.type_folds = make([dynamic][]Segment, len(src.type_folds))
	scope.constraint_folds = make([dynamic][]Segment, len(src.constraint_folds))

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
	case Sum_Type:
		v.left = patch_type(v.left, old, replacement)
		v.right = patch_type(v.right, old, replacement)
	case Product_Type:
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

// --- integer helpers ---

int_is_concrete :: proc(t: Integer_Type) -> bool {
	return segs_is_concrete(t.segments)
}

segs_is_concrete :: proc(segs: []Segment) -> bool {
	if len(segs) != 1 do return false
	lo, lo_ok := segs[0].lo.(i64)
	hi, hi_ok := segs[0].hi.(i64)
	return lo_ok && hi_ok && lo == hi
}

int_value :: proc(t: Integer_Type) -> i64 {
	return t.segments[0].lo.(i64)
}

make_int_result :: proc(val: i64) -> Type {
	segs := make([]Segment, 1)
	segs[0] = Segment{val, val}
	return Integer_Type{segs}
}

int_to_f64 :: proc(i: Integer_Type) -> f64 {
	return f64(int_value(i))
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

// --- arithmetic (int+int, float+float, int+float, string+string) ---

compose_arith :: proc(lv, rv: Type, op: Operator_Kind) -> Type {
	li, li_ok := lv.(Integer_Type)
	ri, ri_ok := rv.(Integer_Type)
	lf, lf_ok := lv.(Float_Type)
	rf, rf_ok := rv.(Float_Type)

	// unary minus: -x = 0 - x
	if lv == nil && op == .Subtract {
		if ri_ok && int_is_concrete(ri) {
			return make_int_result(-int_value(ri))
		}
		if rf_ok {
			f := rf.value.(f64)
			return Float_Type{rf.kind, -f}
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

	if lf_ok && rf_ok {
		fl = lf.value.(f64)
		fr = rf.value.(f64)
		fk = promote_float_kind(lf.kind, rf.kind)
	} else if lf_ok && ri_ok && int_is_concrete(ri) {
		fl = lf.value.(f64)
		fr = int_to_f64(ri)
		fk = lf.kind == .none ? .f64 : lf.kind
	} else if li_ok && rf_ok && int_is_concrete(li) {
		fl = int_to_f64(li)
		fr = rf.value.(f64)
		fk = rf.kind == .none ? .f64 : rf.kind
	} else {
		if op == .Add {
			ls, ls_ok := lv.(String_Type)
			rs, rs_ok := rv.(String_Type)
			if ls_ok && rs_ok {
				return String_Type{strings.concatenate({ls.value.(string), rs.value.(string)})}
			}
		}
		return nil
	}

	#partial switch op {
	case .Add:
		return Float_Type{fk, fl + fr}
	case .Subtract:
		return Float_Type{fk, fl - fr}
	case .Multiply:
		return Float_Type{fk, fl * fr}
	case .Divide:
		return Float_Type{fk, fl / fr}
	}
	return nil
}

promote_float_kind :: proc(a, b: FloatKind) -> FloatKind {
	if a == .none do return b
	if b == .none do return a
	if a == .f64 || b == .f64 do return .f64
	return .f32
}

// --- equality ---

compose_eq :: proc(lv, rv: Type, eq: bool) -> Bool_Type {
	#partial switch l in lv {
	case Integer_Type:
		if !int_is_concrete(l) do return Bool_Type{false}
		r_i, r_i_ok := rv.(Integer_Type)
		r_f, r_f_ok := rv.(Float_Type)
		if r_i_ok && int_is_concrete(r_i) {
			return Bool_Type{eq == (int_value(l) == int_value(r_i))}
		}
		if r_f_ok {
			return Bool_Type{eq == (int_to_f64(l) == r_f.value.(f64))}
		}
	case Float_Type:
		r_f, r_f_ok := rv.(Float_Type)
		r_i, r_i_ok := rv.(Integer_Type)
		lf := l.value.(f64)
		if r_f_ok do return Bool_Type{eq == (lf == r_f.value.(f64))}
		if r_i_ok && int_is_concrete(r_i) do return Bool_Type{eq == (lf == int_to_f64(r_i))}
	case Bool_Type:
		r := rv.(Bool_Type)
		return Bool_Type{eq == (l.value == r.value)}
	case String_Type:
		r := rv.(String_Type)
		return Bool_Type{eq == (l.value.(string) == r.value.(string))}
	}
	return Bool_Type{false}
}

// --- ordering ---

compose_ord :: proc(lv, rv: Type, op: Operator_Kind) -> Bool_Type {
	#partial switch l in lv {
	case Integer_Type:
		if !int_is_concrete(l) do return Bool_Type{false}
		r_i, r_i_ok := rv.(Integer_Type)
		r_f, r_f_ok := rv.(Float_Type)
		if r_i_ok && int_is_concrete(r_i) do return Bool_Type{i64_cmp(int_value(l), int_value(r_i), op)}
		if r_f_ok do return Bool_Type{float_cmp(int_to_f64(l), r_f.value.(f64), op)}
	case Float_Type:
		r_f, r_f_ok := rv.(Float_Type)
		r_i, r_i_ok := rv.(Integer_Type)
		lf := l.value.(f64)
		if r_f_ok do return Bool_Type{float_cmp(lf, r_f.value.(f64), op)}
		if r_i_ok && int_is_concrete(r_i) do return Bool_Type{float_cmp(lf, int_to_f64(r_i), op)}
	}
	return Bool_Type{false}
}

i64_cmp :: proc(a, b: i64, op: Operator_Kind) -> bool {
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

float_cmp :: proc(a, b: f64, op: Operator_Kind) -> bool {
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

// --- bitwise / logic ---

compose_bitlogic :: proc(lv, rv: Type, op: Operator_Kind) -> Type {
	#partial switch l in lv {
	case Integer_Type:
		if !int_is_concrete(l) do return nil
		r, r_ok := rv.(Integer_Type)
		if !r_ok || !int_is_concrete(r) do return nil
		a := int_value(l)
		b := int_value(r)
		val: i64
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

// --- shift ---

compose_shift :: proc(lv, rv: Type, is_left: bool) -> Type {
	l, l_ok := lv.(Integer_Type)
	r, r_ok := rv.(Integer_Type)
	if !l_ok || !r_ok do return nil
	if !int_is_concrete(l) || !int_is_concrete(r) do return nil
	a := int_value(l)
	b := int_value(r)
	if b < 0 || b >= 64 do return nil

	val: i64
	ub := u64(b)
	if is_left {
		val = i64(u64(a) << ub)
	} else {
		val = i64(u64(a) >> ub)
	}
	return make_int_result(val)
}

// --- print ---

print_type :: proc(t: ^Type, depth: int = 0) {
	if t == nil {
		fmt.print("none")
		return
	}
	print_type_value(t^, depth)
}

print_type_value :: proc(t: Type, depth: int = 0) {
	indent :: proc(d: int) {
		for _ in 0 ..< d {
			fmt.print("  ")
		}
	}

	switch v in t {
	case Scope_Type:
		if len(v.names) == 0 {
			fmt.print("{}")
			break
		}
		fmt.println("{")
		for i := 0; i < len(v.names); i += 1 {
			indent(depth + 1)
			has_constraint := v.types[i] != nil
			has_name := v.names[i] != ""
			if v.kind[i] == .Expand {
				fmt.print("...")
				if has_constraint {
					print_type(v.types[i], depth + 1)
					fmt.print(": -> ")
					print_type(v.values[i], depth + 1)
				} else {
					print_type(v.values[i], depth + 1)
				}
			} else {
				if has_constraint {
					print_type(v.types[i], depth + 1)
					fmt.print(":")
				}
				if has_name {
					fmt.print(v.names[i])
				}
				switch v.kind[i] {
				case .Pointing_Push:
					if has_name || has_constraint {
						fmt.print(" -> ")
					}
					print_type(v.values[i], depth + 1)
				case .Pointing_Pull:
					fmt.print(" <- ")
					print_type(v.values[i], depth + 1)
				case .Event_Push:
					fmt.print(" >- ")
					print_type(v.values[i], depth + 1)
				case .Event_Pull:
					fmt.print(" -< ")
					print_type(v.values[i], depth + 1)
				case .Resonance_Push:
					fmt.print(" >>- ")
					print_type(v.values[i], depth + 1)
				case .Resonance_Pull:
					fmt.print(" -<< ")
					print_type(v.values[i], depth + 1)
				case .Reactive_Push:
					fmt.print(" >>= ")
					print_type(v.values[i], depth + 1)
				case .Reactive_Pull:
					fmt.print(" =<< ")
					print_type(v.values[i], depth + 1)
				case .Expand:
				case .Product:
					fmt.print("-> ")
					print_type(v.values[i], depth + 1)
				}
			}
			has_tf := i < len(v.type_folds) && v.type_folds[i] != nil
			has_cf := i < len(v.constraint_folds) && v.constraint_folds[i] != nil
			fmt.print("  ")
			if has_cf {
				fmt.print("c:")
				print_segments_inline(v.constraint_folds[i])
				fmt.print(" ")
			}
			if has_tf {
				fmt.print("t:")
				print_segments_inline(v.type_folds[i])
				fmt.print(" ")
			}
			if has_cf {
				if has_tf {
					if segments_satisfies(v.type_folds[i], v.constraint_folds[i]) {
						fmt.print("v")
					} else {
						fmt.print("x")
					}
				} else {
					fmt.print("x")
				}
			} else if has_tf {
				fmt.print("v")
			}
			fmt.println()
		}
		indent(depth)
		fmt.print("}")

	case Integer_Type:
		if int_is_concrete(v) {
			fmt.print(int_value(v))
		} else if len(v.segments) == 1 {
			print_segment(v.segments[0])
		} else {
			for seg, i in v.segments {
				if i > 0 do fmt.print(" | ")
				print_segment(seg)
			}
		}

	case Float_Type:
		f, ok := v.value.(f64)
		if ok {
			fmt.printf("%v", f)
		} else {
			print_float_kind(v.kind)
		}

	case String_Type:
		s, ok := v.value.(string)
		if ok {
			fmt.printf("\"%s\"", s)
		} else {
			fmt.print("String")
		}

	case Bool_Type:
		fmt.print(v.value ? "true" : "false")

	case None_Type:
		fmt.print("none")

	case Range_Type:
		print_type(v.left, depth)
		fmt.print("..")
		print_type(v.right, depth)

	case Compose_Type:
		if v.left != nil {
			print_type(v.left, depth)
			fmt.printf(" %s ", op_symbol(v.operator))
		} else {
			fmt.printf("%s", op_symbol(v.operator))
		}
		print_type(v.right, depth)

	case Execute_Type:
		print_type(v.target, depth)
		fmt.print("!")

	case Carve_Type:
		if v.source != nil {
			print_type(v.source, depth)
		}
		fmt.print("{")
		for i := 0; i < len(v.references); i += 1 {
			if i > 0 do fmt.print(", ")
			ref := v.references[i]
			n, n_ok := ref.name.(string)
			if n_ok && n != "" do fmt.printf("%s -> ", n)
			print_type(v.values[i], depth)
		}
		fmt.print("}")

	case Sum_Type:
		print_type(v.left, depth)
		fmt.print(" | ")
		print_type(v.right, depth)

	case Product_Type:
		print_type(v.left, depth)
		fmt.print(" & ")
		print_type(v.right, depth)

	case Negate_Type:
		fmt.print("~")
		print_type(v.operand, depth)

	case Mention_Type:
		if v.name != "" {
			fmt.print(v.name)
		} else if v.match_scope != nil && v.match_index >= 0 {
			print_type(v.match_scope.values[v.match_index], depth)
		}

	case Reference_Type:
		ref := v.reference
		n, n_ok := ref.name.(string)
		idx, idx_ok := ref.index.(u64)
		has_target := v.target != nil
		is_self_ref := n_ok && n == "" && !idx_ok

		if is_self_ref {
			print_type(v.target, depth)
		} else if has_target {
			print_type(v.target, depth)
			fmt.print(".")
			if n_ok && n != "" {
				fmt.print(n)
			}
			if idx_ok {
				fmt.printf("#%d", idx)
			}
		} else {
			if n_ok && n != "" {
				fmt.print(n)
			}
			if idx_ok {
				fmt.printf("#%d", idx)
			}
		}

	case Invalid_Type:
		fmt.print("<invalid>")

	case Unknown_Type:
		fmt.print("??")
	}
}

builtin_name :: proc(seg: Segment) -> Maybe(string) {
	lo, lo_ok := seg.lo.(i64)
	hi, hi_ok := seg.hi.(i64)
	if !lo_ok && !hi_ok do return "Int"
	if !lo_ok || !hi_ok do return nil
	switch {
	case lo == 0 && hi == 255:
		return "u8"
	case lo == -128 && hi == 127:
		return "i8"
	case lo == 0 && hi == 65535:
		return "u16"
	case lo == -32768 && hi == 32767:
		return "i16"
	case lo == 0 && hi == 4294967295:
		return "u32"
	case lo == -2147483648 && hi == 2147483647:
		return "i32"
	case lo == 0 && hi == 9223372036854775807:
		return "u64"
	case lo == -9223372036854775808 && hi == 9223372036854775807:
		return "i64"
	}
	return nil
}

// --- constraint folding (set logic: union, intersection, negation) ---

fold_constraint :: proc(t: ^Type) -> Maybe([]Segment) {
	if t == nil do return nil
	#partial switch v in t^ {
	case Integer_Type:
		return v.segments
	case Range_Type:
		left_segs, left_ok := fold_constraint(v.left).([]Segment)
		right_segs, right_ok := fold_constraint(v.right).([]Segment)
		lo: Maybe(i64) = nil
		hi: Maybe(i64) = nil
		if left_ok && len(left_segs) > 0 {
			lo = left_segs[0].lo
		}
		if right_ok && len(right_segs) > 0 {
			hi = right_segs[len(right_segs) - 1].hi
		}
		segs := make([]Segment, 1)
		segs[0] = Segment{lo, hi}
		return segs
	case Compose_Type:
		if v.type_fold != nil {
			return fold_constraint(v.type_fold)
		}
		return fold_to_segments(t)
	case Sum_Type:
		left, left_ok := fold_constraint(v.left).([]Segment)
		right, right_ok := fold_constraint(v.right).([]Segment)
		if !left_ok do return right_ok ? right : nil
		if !right_ok do return left
		return segments_union(left, right)
	case Product_Type:
		left, left_ok := fold_constraint(v.left).([]Segment)
		right, right_ok := fold_constraint(v.right).([]Segment)
		if !left_ok || !right_ok do return nil
		return segments_intersect(left, right)
	case Negate_Type:
		inner, inner_ok := fold_constraint(v.operand).([]Segment)
		if !inner_ok do return nil
		return segments_negate(inner)
	case Mention_Type:
		if v.match_scope != nil && v.match_index >= 0 {
			if v.match_scope.constraint_folds[v.match_index] != nil {
				return v.match_scope.constraint_folds[v.match_index]
			}
			if v.match_scope.type_folds[v.match_index] != nil {
				return v.match_scope.type_folds[v.match_index]
			}
			return fold_constraint(v.match_scope.values[v.match_index])
		}
	case Reference_Type:
		ref := v.reference
		if ref != nil && ref.match_scope != nil && ref.match_index >= 0 {
			if ref.match_scope.constraint_folds[ref.match_index] != nil {
				return ref.match_scope.constraint_folds[ref.match_index]
			}
			if ref.match_scope.type_folds[ref.match_index] != nil {
				return ref.match_scope.type_folds[ref.match_index]
			}
			return fold_constraint(ref.match_scope.values[ref.match_index])
		}
	}
	return nil
}

// merge two sorted segment lists into their union
segments_union :: proc(a, b: []Segment) -> []Segment {
	merged := make([dynamic]Segment)
	i, j := 0, 0
	for i < len(a) || j < len(b) {
		seg: Segment
		if i < len(a) && (j >= len(b) || seg_lo(a[i]) <= seg_lo(b[j])) {
			seg = a[i];i += 1
		} else {
			seg = b[j];j += 1
		}
		if len(merged) > 0 && segments_overlap_or_adjacent(merged[len(merged) - 1], seg) {
			merged[len(merged) - 1] = segment_merge(merged[len(merged) - 1], seg)
		} else {
			append(&merged, seg)
		}
	}
	return merged[:]
}

// intersect two sorted segment lists
segments_intersect :: proc(a, b: []Segment) -> []Segment {
	result := make([dynamic]Segment)
	i, j := 0, 0
	for i < len(a) && j < len(b) {
		lo := max_lo(a[i].lo, b[j].lo)
		hi := min_hi(a[i].hi, b[j].hi)
		if maybe_le(lo, hi) {
			append(&result, Segment{lo, hi})
		}
		if maybe_le_hi(a[i].hi, b[j].hi) {
			i += 1
		} else {
			j += 1
		}
	}
	return result[:]
}

// negate segments (complement within -inf..+inf)
segments_negate :: proc(segs: []Segment) -> []Segment {
	result := make([dynamic]Segment)
	prev_hi: Maybe(i64) = nil // starts at -inf
	for seg in segs {
		lo := seg.lo
		if lo != nil {
			lo_val := lo.(i64)
			new_hi: Maybe(i64) = lo_val - 1
			if maybe_le(prev_hi, new_hi) {
				append(&result, Segment{prev_hi, new_hi})
			}
		} else {
			// seg starts at -inf, skip gap
		}
		hi := seg.hi
		if hi != nil {
			prev_hi = hi.(i64) + 1
		} else {
			prev_hi = nil // +inf, nothing after
			return result[:]
		}
	}
	// gap from prev_hi to +inf
	append(&result, Segment{prev_hi, nil})
	return result[:]
}

segments_normalize :: proc(segs: []Segment) -> []Segment {
	if len(segs) <= 1 do return segs
	sorted := make([]Segment, len(segs))
	copy(sorted, segs)
	slice.sort_by(sorted, proc(a, b: Segment) -> bool {
		return seg_lo(a) < seg_lo(b)
	})
	result := make([dynamic]Segment)
	append(&result, sorted[0])
	for i := 1; i < len(sorted); i += 1 {
		if segments_overlap_or_adjacent(result[len(result) - 1], sorted[i]) {
			result[len(result) - 1] = segment_merge(result[len(result) - 1], sorted[i])
		} else {
			append(&result, sorted[i])
		}
	}
	return result[:]
}

// helpers for Maybe(i64) comparison
seg_lo :: proc(s: Segment) -> i64 {
	lo, ok := s.lo.(i64)
	return ok ? lo : min(i64)
}

segments_overlap_or_adjacent :: proc(a, b: Segment) -> bool {
	a_hi, a_ok := a.hi.(i64)
	b_lo, b_ok := b.lo.(i64)
	if !a_ok do return true // a goes to +inf
	if !b_ok do return true // b starts at -inf
	return a_hi >= b_lo - 1
}

segment_merge :: proc(a, b: Segment) -> Segment {
	return Segment{min_lo(a.lo, b.lo), max_hi(a.hi, b.hi)}
}

// for lo bounds: nil = -inf
max_lo :: proc(a, b: Maybe(i64)) -> Maybe(i64) {
	a_val, a_ok := a.(i64)
	b_val, b_ok := b.(i64)
	if !a_ok do return b // -inf < anything, take b
	if !b_ok do return a // -inf < anything, take a
	return max(a_val, b_val)
}

min_lo :: proc(a, b: Maybe(i64)) -> Maybe(i64) {
	a_val, a_ok := a.(i64)
	b_val, b_ok := b.(i64)
	if !a_ok do return a // -inf is smallest
	if !b_ok do return b // -inf is smallest
	return min(a_val, b_val)
}

// for hi bounds: nil = +inf
max_hi :: proc(a, b: Maybe(i64)) -> Maybe(i64) {
	a_val, a_ok := a.(i64)
	b_val, b_ok := b.(i64)
	if !a_ok do return a // +inf is largest
	if !b_ok do return b // +inf is largest
	return max(a_val, b_val)
}

min_hi :: proc(a, b: Maybe(i64)) -> Maybe(i64) {
	a_val, a_ok := a.(i64)
	b_val, b_ok := b.(i64)
	if !a_ok do return b // +inf > anything, take b
	if !b_ok do return a // +inf > anything, take a
	return min(a_val, b_val)
}

// lo <= hi comparison (nil lo = -inf, nil hi = +inf)
maybe_le :: proc(lo: Maybe(i64), hi: Maybe(i64)) -> bool {
	lo_val, lo_ok := lo.(i64)
	hi_val, hi_ok := hi.(i64)
	if !lo_ok do return true // -inf <= anything
	if !hi_ok do return true // anything <= +inf
	return lo_val <= hi_val
}

// hi <= hi comparison (nil = +inf)
maybe_le_hi :: proc(a, b: Maybe(i64)) -> bool {
	a_val, a_ok := a.(i64)
	b_val, b_ok := b.(i64)
	if !a_ok do return !b_ok // +inf <= +inf is true, +inf <= finite is false
	if !b_ok do return true // anything <= +inf
	return a_val <= b_val
}

// A ⊆ B : every segment of A is contained in some segment of B
segments_satisfies :: proc(value_segs, constraint_segs: []Segment) -> bool {
	if value_segs == nil || constraint_segs == nil do return false
	for vs in value_segs {
		found := false
		for cs in constraint_segs {
			// vs.lo >= cs.lo && vs.hi <= cs.hi
			if maybe_le(cs.lo, vs.lo) && maybe_le_hi(vs.hi, cs.hi) {
				found = true
				break
			}
		}
		if !found do return false
	}
	return true
}

// --- value folding (arithmetic propagation) ---

fold_to_segments :: proc(t: ^Type) -> Maybe([]Segment) {
	if t == nil do return nil
	#partial switch v in t^ {
	case Integer_Type:
		return v.segments
	case Range_Type:
		left_segs, left_ok := fold_to_segments(v.left).([]Segment)
		right_segs, right_ok := fold_to_segments(v.right).([]Segment)
		lo: Maybe(i64) = nil
		hi: Maybe(i64) = nil
		if left_ok && len(left_segs) > 0 {
			lo = left_segs[0].lo
		}
		if right_ok && len(right_segs) > 0 {
			hi = right_segs[len(right_segs) - 1].hi
		}
		segs := make([]Segment, 1)
		segs[0] = Segment{lo, hi}
		return segs
	case Compose_Type:
		if v.type_fold != nil {
			return fold_to_segments(v.type_fold)
		}
		if v.left == nil {
			// unary
			right_segs, right_ok := fold_to_segments(v.right).([]Segment)
			if !right_ok do return nil
			#partial switch v.operator {
			case .Greater:
				// >X = X+1..inf
				hi, hi_ok := right_segs[0].hi.(i64)
				if !hi_ok do return nil
				segs := make([]Segment, 1)
				segs[0] = Segment{hi + 1, nil}
				return segs
			case .GreaterEqual:
				// >=X = X..inf
				segs := make([]Segment, 1)
				segs[0] = Segment{right_segs[0].lo, nil}
				return segs
			case .Less:
				// <X = -inf..X-1
				lo, lo_ok := right_segs[0].lo.(i64)
				if !lo_ok do return nil
				segs := make([]Segment, 1)
				segs[0] = Segment{nil, lo - 1}
				return segs
			case .LessEqual:
				// <=X = -inf..X
				segs := make([]Segment, 1)
				segs[0] = Segment{nil, right_segs[0].hi}
				return segs
			case .Subtract:
				// -X = negate
				lo, lo_ok := right_segs[0].lo.(i64)
				hi, hi_ok := right_segs[0].hi.(i64)
				if !lo_ok || !hi_ok do return nil
				segs := make([]Segment, 1)
				segs[0] = Segment{-hi, -lo}
				return segs
			}
			return nil
		}
		// binary compose
		left_segs, left_ok := fold_to_segments(v.left).([]Segment)
		right_segs, right_ok := fold_to_segments(v.right).([]Segment)
		if !left_ok || !right_ok do return nil
		if len(left_segs) == 0 || len(right_segs) == 0 do return nil
		result := make([dynamic]Segment)
		for ls in left_segs {
			for rs in right_segs {
				pair, pair_ok := fold_arith_segments(ls, rs, v.operator).([]Segment)
				if !pair_ok do return nil
				for s in pair {
					append(&result, s)
				}
			}
		}
		return segments_normalize(result[:])
	case Mention_Type:
		if v.match_scope != nil && v.match_index >= 0 {
			if v.match_scope.type_folds[v.match_index] != nil {
				return v.match_scope.type_folds[v.match_index]
			}
			if v.match_scope.constraint_folds[v.match_index] != nil {
				return v.match_scope.constraint_folds[v.match_index]
			}
		}
		return nil
	case Reference_Type:
		ref := v.reference
		if ref != nil && ref.match_scope != nil && ref.match_index >= 0 {
			if ref.match_scope.type_folds[ref.match_index] != nil {
				return ref.match_scope.type_folds[ref.match_index]
			}
			if ref.match_scope.constraint_folds[ref.match_index] != nil {
				return ref.match_scope.constraint_folds[ref.match_index]
			}
		}
		return nil
	}
	return nil
}

fold_arith_segments :: proc(a, b: Segment, op: Operator_Kind) -> Maybe([]Segment) {
	a_lo, a_lo_ok := a.lo.(i64)
	a_hi, a_hi_ok := a.hi.(i64)
	b_lo, b_lo_ok := b.lo.(i64)
	b_hi, b_hi_ok := b.hi.(i64)

	segs := make([]Segment, 1)

	#partial switch op {
	case .Add:
		lo: Maybe(i64) = a_lo_ok && b_lo_ok ? a_lo + b_lo : nil
		hi: Maybe(i64) = a_hi_ok && b_hi_ok ? a_hi + b_hi : nil
		segs[0] = Segment{lo, hi}
		return segs
	case .Subtract:
		lo: Maybe(i64) = a_lo_ok && b_hi_ok ? a_lo - b_hi : nil
		hi: Maybe(i64) = a_hi_ok && b_lo_ok ? a_hi - b_lo : nil
		segs[0] = Segment{lo, hi}
		return segs
	case .Multiply:
		if !a_lo_ok || !a_hi_ok || !b_lo_ok || !b_hi_ok do return nil
		p1 := a_lo * b_lo
		p2 := a_lo * b_hi
		p3 := a_hi * b_lo
		p4 := a_hi * b_hi
		segs[0] = Segment{min(p1, p2, p3, p4), max(p1, p2, p3, p4)}
		return segs
	case .Divide:
		if !a_lo_ok || !a_hi_ok || !b_lo_ok || !b_hi_ok do return nil
		if b_lo == 0 && b_hi == 0 do return nil
		// avoid division by zero in range
		bl := b_lo == 0 ? i64(1) : b_lo
		bh := b_hi == 0 ? i64(-1) : b_hi
		if bl > bh do return nil
		p1 := a_lo / bl
		p2 := a_lo / bh
		p3 := a_hi / bl
		p4 := a_hi / bh
		segs[0] = Segment{min(p1, p2, p3, p4), max(p1, p2, p3, p4)}
		return segs
	case .Mod:
		if !a_lo_ok || !a_hi_ok || !b_lo_ok || !b_hi_ok do return nil
		if b_lo == 0 && b_hi == 0 do return nil
		bl := b_lo == 0 ? i64(1) : b_lo
		bh := b_hi == 0 ? i64(-1) : b_hi
		if bl > bh do return nil
		p1 := a_lo %% bl
		p2 := a_lo %% bh
		p3 := a_hi %% bl
		p4 := a_hi %% bh
		segs[0] = Segment{min(p1, p2, p3, p4), max(p1, p2, p3, p4)}
		return segs
	case .LShift:
		if !a_lo_ok || !a_hi_ok || !b_lo_ok || !b_hi_ok do return nil
		if b_lo < 0 || b_hi >= 64 do return nil
		p1 := a_lo << u64(b_lo)
		p2 := a_lo << u64(b_hi)
		p3 := a_hi << u64(b_lo)
		p4 := a_hi << u64(b_hi)
		segs[0] = Segment{min(p1, p2, p3, p4), max(p1, p2, p3, p4)}
		return segs
	case .RShift:
		if !a_lo_ok || !a_hi_ok || !b_lo_ok || !b_hi_ok do return nil
		if b_lo < 0 || b_hi >= 64 do return nil
		p1 := a_lo >> u64(b_lo)
		p2 := a_lo >> u64(b_hi)
		p3 := a_hi >> u64(b_lo)
		p4 := a_hi >> u64(b_hi)
		segs[0] = Segment{min(p1, p2, p3, p4), max(p1, p2, p3, p4)}
		return segs
	case .BitAnd:
		if !a_lo_ok || !a_hi_ok || !b_lo_ok || !b_hi_ok do return nil
		if a_lo == a_hi && b_lo == b_hi {
			val := a_lo & b_lo
			segs[0] = Segment{val, val}
			return segs
		}
		// conservative: result is between 0 and min of the two maxes
		segs[0] = Segment{i64(0), min(a_hi, b_hi)}
		return segs
	case .BitOr:
		if !a_lo_ok || !a_hi_ok || !b_lo_ok || !b_hi_ok do return nil
		if a_lo == a_hi && b_lo == b_hi {
			val := a_lo | b_lo
			segs[0] = Segment{val, val}
			return segs
		}
		segs[0] = Segment{max(a_lo, b_lo), max(a_hi, b_hi)}
		return segs
	case .Xor:
		if !a_lo_ok || !a_hi_ok || !b_lo_ok || !b_hi_ok do return nil
		if a_lo == a_hi && b_lo == b_hi {
			val := a_lo ~ b_lo
			segs[0] = Segment{val, val}
			return segs
		}
		// conservative
		segs[0] = Segment{i64(0), max(a_hi, b_hi)}
		return segs
	}
	return nil
}

print_segments :: proc(t: ^Type) {
	if t == nil {
		fmt.print("none")
		return
	}
	segs, ok := fold_to_segments(t).([]Segment)
	if ok {
		for seg, i in segs {
			if i > 0 do fmt.print(", ")
			print_segment_raw(seg)
		}
		return
	}
	#partial switch v in t^ {
	case Float_Type:
		f, f_ok := v.value.(f64)
		if f_ok {
			fmt.printf("{%v, %v}", f, f)
		} else {
			print_float_kind(v.kind)
		}
	case String_Type:
		s, s_ok := v.value.(string)
		if s_ok {
			fmt.printf("{\"%s\", \"%s\"}", s, s)
		} else {
			fmt.print("String")
		}
	case Bool_Type:
		fmt.printf("{%s, %s}", v.value ? "true" : "false", v.value ? "true" : "false")
	case Unknown_Type:
		fmt.print("??")
	case None_Type:
		fmt.print("none")
	case Scope_Type:
		fmt.print("scope")
	case:
		fmt.print("?")
	}
}

pretty_segments :: proc(segs: []Segment) -> string {
	if len(segs) == 1 {
		alias := builtin_alias(segs[0])
		if alias != "" do return alias
	}
	b := strings.builder_make()
	for seg, i in segs {
		if i > 0 do strings.write_string(&b, " | ")
		lo, lo_ok := seg.lo.(i64)
		hi, hi_ok := seg.hi.(i64)
		if lo_ok && hi_ok && lo == hi {
			strings.write_string(&b, fmt.tprintf("%d", lo))
		} else {
			if lo_ok {
				strings.write_string(&b, fmt.tprintf("%d", lo))
			} else {
				strings.write_string(&b, "-inf")
			}
			strings.write_string(&b, "..")
			if hi_ok {
				strings.write_string(&b, fmt.tprintf("%d", hi))
			} else {
				strings.write_string(&b, "inf")
			}
		}
	}
	return strings.to_string(b)
}

builtin_alias :: proc(seg: Segment) -> string {
	lo, lo_ok := seg.lo.(i64)
	hi, hi_ok := seg.hi.(i64)
	if !lo_ok || !hi_ok do return ""
	if lo == 0 && hi == 255 do return "u8"
	if lo == -128 && hi == 127 do return "i8"
	if lo == 0 && hi == 65535 do return "u16"
	if lo == -32768 && hi == 32767 do return "i16"
	if lo == 0 && hi == 4294967295 do return "u32"
	if lo == -2147483648 && hi == 2147483647 do return "i32"
	if lo == 0 && hi == 9223372036854775807 do return "u64"
	if lo == -9223372036854775808 && hi == 9223372036854775807 do return "i64"
	return ""
}

print_segments_inline :: proc(segs: []Segment) {
	fmt.print("[")
	for seg, i in segs {
		if i > 0 do fmt.print(", ")
		print_segment_raw(seg)
	}
	fmt.print("]")
}

print_segment_raw :: proc(seg: Segment) {
	lo, lo_ok := seg.lo.(i64)
	hi, hi_ok := seg.hi.(i64)
	fmt.print("{")
	if lo_ok {
		fmt.print(lo)
	} else {
		fmt.print("-inf")
	}
	fmt.print(", ")
	if hi_ok {
		fmt.print(hi)
	} else {
		fmt.print("inf")
	}
	fmt.print("}")
}

print_segment :: proc(seg: Segment) {
	lo, lo_ok := seg.lo.(i64)
	hi, hi_ok := seg.hi.(i64)
	if lo_ok && hi_ok && lo == hi {
		fmt.print(lo)
	} else {
		name, name_ok := builtin_name(seg).(string)
		if name_ok {
			fmt.print(name)
			return
		}
		if lo_ok {
			fmt.print(lo)
		}
		fmt.print("..")
		if hi_ok {
			fmt.print(hi)
		}
	}
}

op_symbol :: proc(op: Operator_Kind) -> string {
	switch op {
	case .Add:
		return "+"
	case .Subtract:
		return "-"
	case .Multiply:
		return "*"
	case .Divide:
		return "/"
	case .Mod:
		return "%"
	case .Equal:
		return "=="
	case .NotEqual:
		return "!="
	case .Less:
		return "<"
	case .Greater:
		return ">"
	case .LessEqual:
		return "<="
	case .GreaterEqual:
		return ">="
	case .And:
		return "&"
	case .Or:
		return "|"
	case .Xor:
		return "^"
	case .Not:
		return "~"
	case .BitAnd:
		return "[&]"
	case .BitOr:
		return "[|]"
	case .BitNot:
		return "[~]"
	case .LShift:
		return "<<"
	case .RShift:
		return ">>"
	}
	return "?"
}

print_float_kind :: proc(k: FloatKind) {
	switch k {
	case .none:
		fmt.print("Float")
	case .f32:
		fmt.print("f32")
	case .f64:
		fmt.print("f64")
	}
}
