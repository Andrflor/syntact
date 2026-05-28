package compiler

import "core:fmt"
import "core:strconv"
import "core:strings"

reduce :: proc(scope: ^Scope_Type) -> ^Type {
	for i := 0; i < len(scope.kind); i += 1 {
		if scope.kind[i] == .Product {
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
		return reduce_value(compose(v))
	case Carve_Type:
		return reduce_value(carve(v))
	case Mention_Type:
		return reduce_value(v.target)
	case Reference_Type:
		reduced := reduce_value(v.reference.match)
		#partial switch &s in reduced^ {
		case Scope_Type:
			name, has_name := v.reference.name.(string)
			idx, has_idx := v.reference.index.(u64)
			if has_name || has_idx {
				ordinal: i16 = has_idx ? i16(idx) : -1
				resolved := scope_resolve(&s, has_name ? name : "", ordinal, true)
				if resolved != nil {
					return reduce_value(resolved)
				}
			}
		}
		return reduced
	case Sum_Type:
	case Product_Type:
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
	return reduce(&value.target.(Scope_Type))
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

	for i := 0; i < len(src.names); i += 1 {
		scope.names[i] = src.names[i]
		scope.types[i] = src.types[i]
		scope.kind[i] = src.kind[i]
		scope.values[i] = src.values[i]
	}

	for i := 0; i < len(value.references); i += 1 {
		ref := &value.references[i]
		val := value.values[i]
		if ref.match != nil {
			ref.match^ = val^
		}
		for j := 0; j < len(scope.values); j += 1 {
			if scope.values[j] == ref.match {
				scope.values[j] = val
				break
			}
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
		if v.reference != nil && v.reference.match == old {
			v.reference.match = replacement
		}
	case Mention_Type:
		v.target = patch_type(v.target, old, replacement)
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

compose :: proc(value: Compose_Type) -> ^Type {
	left := reduce_value(value.left)
	right := value.right != nil ? reduce_value(value.right) : nil
	lv := left^
	rv: Type = right != nil ? right^ : nil

	result := new(Type)

	switch value.operator {
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
	case .And:
		result^ = compose_bitlogic(lv, rv, .And)
	case .Or:
		result^ = compose_bitlogic(lv, rv, .Or)
	case .Xor:
		result^ = compose_bitlogic(lv, rv, .Xor)
	case .Not:
		#partial switch l in lv {
		case Integer_Type:
			result^ = int_unary_not(l)
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

// --- int kind promotion ---

int_kind_signed :: proc(k: IntegerKind) -> bool {
	#partial switch k {
	case .i8, .i16, .i32, .i64:
		return true
	}
	return false
}

int_kind_size :: proc(k: IntegerKind) -> u8 {
	#partial switch k {
	case .u8, .i8:
		return 1
	case .u16, .i16:
		return 2
	case .u32, .i32:
		return 4
	case .u64, .i64:
		return 8
	}
	return 0
}

signed_kind_for_size :: proc(s: u8) -> IntegerKind {
	switch s {
	case 1:
		return .i8
	case 2:
		return .i16
	case 4:
		return .i32
	}
	return .i64
}

unsigned_kind_for_size :: proc(s: u8) -> IntegerKind {
	switch s {
	case 1:
		return .u8
	case 2:
		return .u16
	case 4:
		return .u32
	}
	return .u64
}

promote_int_kind :: proc(a, b: IntegerKind) -> IntegerKind {
	if a == .none do return b
	if b == .none do return a
	sa := int_kind_size(a)
	sb := int_kind_size(b)
	signed := int_kind_signed(a) || int_kind_signed(b)
	size := max(sa, sb)
	// u32 + i32 -> i64 pour pas perdre le range
	if signed {
		ua := !int_kind_signed(a)
		ub := !int_kind_signed(b)
		if (ua && sa >= size) || (ub && sb >= size) {
			size = min(size * 2, 8)
		}
	}
	return signed ? signed_kind_for_size(size) : unsigned_kind_for_size(size)
}

promote_float_kind :: proc(a, b: FloatKind) -> FloatKind {
	if a == .none do return b
	if b == .none do return a
	if a == .f64 || b == .f64 do return .f64
	return .f32
}

int_to_f64 :: proc(i: Integer_Type) -> f64 {
	d := i.value.(Integer_Data)
	return d.negative ? -f64(d.value) : f64(d.value)
}

// --- arithmetic (int+int, float+float, int+float, string+string) ---

compose_arith :: proc(lv, rv: Type, op: Operator_Kind) -> Type {
	li, li_ok := lv.(Integer_Type)
	ri, ri_ok := rv.(Integer_Type)
	lf, lf_ok := lv.(Float_Type)
	rf, rf_ok := rv.(Float_Type)

	if li_ok && ri_ok {
		return int_arith(li, ri, op)
	}

	fl, fr: f64
	fk: FloatKind

	if lf_ok && rf_ok {
		fl = lf.value.(f64)
		fr = rf.value.(f64)
		fk = promote_float_kind(lf.kind, rf.kind)
	} else if lf_ok && ri_ok {
		fl = lf.value.(f64)
		fr = int_to_f64(ri)
		fk = lf.kind == .none ? .f64 : lf.kind
	} else if li_ok && rf_ok {
		fl = int_to_f64(li)
		fr = rf.value.(f64)
		fk = rf.kind == .none ? .f64 : rf.kind
	} else {
		if op == .Add {
			ls, ls_ok := lv.(String_Type)
			rs, rs_ok := rv.(String_Type)
			if ls_ok && rs_ok {
				return String_Type {
					strings.concatenate({ls.value.(string), rs.value.(string)}),
					nil,
				}
			}
		}
		return nil
	}

	#partial switch op {
	case .Add:
		return Float_Type{fk, fl + fr, nil}
	case .Subtract:
		return Float_Type{fk, fl - fr, nil}
	case .Multiply:
		return Float_Type{fk, fl * fr, nil}
	case .Divide:
		return Float_Type{fk, fl / fr, nil}
	}
	return nil
}

int_arith :: proc(l, r: Integer_Type, op: Operator_Kind) -> Type {
	kind := promote_int_kind(l.kind, r.kind)
	ld := l.value.(Integer_Data)
	rd := r.value.(Integer_Data)

	#partial switch op {
	case .Add:      return int_add(ld, rd, kind)
	case .Subtract: return int_sub(ld, rd, kind)
	case .Multiply: return int_mul(ld, rd, kind)
	case .Divide:   return int_div(ld, rd, kind)
	case .Mod:      return int_mod(ld, rd, kind)
	}
	return nil
}

int_add :: proc(a, b: Integer_Data, kind: IntegerKind) -> Integer_Type {
	if a.negative == b.negative {
		return Integer_Type{kind, Integer_Data{a.value + b.value, a.negative}, nil}
	}
	if a.value >= b.value {
		return Integer_Type{kind, Integer_Data{a.value - b.value, a.negative}, nil}
	}
	return Integer_Type{kind, Integer_Data{b.value - a.value, b.negative}, nil}
}

int_sub :: proc(a, b: Integer_Data, kind: IntegerKind) -> Integer_Type {
	return int_add(a, Integer_Data{b.value, !b.negative}, kind)
}

int_mul :: proc(a, b: Integer_Data, kind: IntegerKind) -> Integer_Type {
	return Integer_Type{kind, Integer_Data{a.value * b.value, a.negative != b.negative}, nil}
}

int_div :: proc(a, b: Integer_Data, kind: IntegerKind) -> Integer_Type {
	return Integer_Type{kind, Integer_Data{a.value / b.value, a.negative != b.negative}, nil}
}

int_mod :: proc(a, b: Integer_Data, kind: IntegerKind) -> Integer_Type {
	return Integer_Type{kind, Integer_Data{a.value % b.value, a.negative}, nil}
}

int_unary_not :: proc(l: Integer_Type) -> Integer_Type {
	d := l.value.(Integer_Data)
	return Integer_Type{l.kind, Integer_Data{~d.value, d.negative}, nil}
}

// --- equality ---

compose_eq :: proc(lv, rv: Type, eq: bool) -> Bool_Type {
	#partial switch l in lv {
	case Integer_Type:
		r_i, r_i_ok := rv.(Integer_Type)
		r_f, r_f_ok := rv.(Float_Type)
		if r_i_ok {
			ld := l.value.(Integer_Data)
			rd := r_i.value.(Integer_Data)
			same := ld.value == rd.value && ld.negative == rd.negative
			return Bool_Type{eq == same}
		}
		if r_f_ok {
			return Bool_Type{eq == (int_to_f64(l) == r_f.value.(f64))}
		}
	case Float_Type:
		r_f, r_f_ok := rv.(Float_Type)
		r_i, r_i_ok := rv.(Integer_Type)
		lf := l.value.(f64)
		if r_f_ok do return Bool_Type{eq == (lf == r_f.value.(f64))}
		if r_i_ok do return Bool_Type{eq == (lf == int_to_f64(r_i))}
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
		r_i, r_i_ok := rv.(Integer_Type)
		r_f, r_f_ok := rv.(Float_Type)
		if r_i_ok do return Bool_Type{int_cmp(l.value.(Integer_Data), r_i.value.(Integer_Data), op)}
		if r_f_ok do return Bool_Type{float_cmp(int_to_f64(l), r_f.value.(f64), op)}
	case Float_Type:
		r_f, r_f_ok := rv.(Float_Type)
		r_i, r_i_ok := rv.(Integer_Type)
		lf := l.value.(f64)
		if r_f_ok do return Bool_Type{float_cmp(lf, r_f.value.(f64), op)}
		if r_i_ok do return Bool_Type{float_cmp(lf, int_to_f64(r_i), op)}
	}
	return Bool_Type{false}
}

int_cmp :: proc(a, b: Integer_Data, op: Operator_Kind) -> bool {
	if a.negative != b.negative {
		a_less := a.negative
		#partial switch op {
		case .Less:         return a_less
		case .Greater:      return !a_less
		case .LessEqual:    return a_less
		case .GreaterEqual: return !a_less
		}
	}
	flip := a.negative
	#partial switch op {
	case .Less:         return flip ? a.value > b.value : a.value < b.value
	case .Greater:      return flip ? a.value < b.value : a.value > b.value
	case .LessEqual:    return flip ? a.value >= b.value : a.value <= b.value
	case .GreaterEqual: return flip ? a.value <= b.value : a.value >= b.value
	}
	return false
}

float_cmp :: proc(a, b: f64, op: Operator_Kind) -> bool {
	#partial switch op {
	case .Less:         return a < b
	case .Greater:      return a > b
	case .LessEqual:    return a <= b
	case .GreaterEqual: return a >= b
	}
	return false
}

// --- bitwise / logic ---

compose_bitlogic :: proc(lv, rv: Type, op: Operator_Kind) -> Type {
	#partial switch l in lv {
	case Integer_Type:
		r := rv.(Integer_Type)
		kind := promote_int_kind(l.kind, r.kind)
		ld := l.value.(Integer_Data)
		rd := r.value.(Integer_Data)
		val: u64
		#partial switch op {
		case .And: val = ld.value & rd.value
		case .Or:  val = ld.value | rd.value
		case .Xor: val = ld.value ~ rd.value
		}
		return Integer_Type{kind, Integer_Data{val, false}, nil}
	case Bool_Type:
		r := rv.(Bool_Type)
		#partial switch op {
		case .And: return Bool_Type{l.value && r.value}
		case .Or:  return Bool_Type{l.value || r.value}
		case .Xor: return Bool_Type{l.value ~ r.value}
		}
	}
	return nil
}

// --- shift (entier positif à droite, garanti par l'analyzer) ---

compose_shift :: proc(lv, rv: Type, is_left: bool) -> Type {
	l := lv.(Integer_Type)
	r := rv.(Integer_Type)
	ld := l.value.(Integer_Data)
	rd := r.value.(Integer_Data)

	val: u64
	if is_left {
		val = ld.value << rd.value
	} else {
		val = ld.value >> rd.value
	}
	return Integer_Type{l.kind, Integer_Data{val, ld.negative}, nil}
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
		fmt.println("{")
		for i := 0; i < len(v.names); i += 1 {
			indent(depth + 1)
			has_constraint := v.types[i] != nil
			has_name := v.names[i] != ""
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
				fmt.print("...")
				print_type(v.values[i], depth + 1)
			case .Product:
				fmt.print("-> ")
				print_type(v.values[i], depth + 1)
			}
			fmt.println()
		}
		indent(depth)
		fmt.print("}")

	case Integer_Type:
		d, ok := v.value.(Integer_Data)
		if ok {
			if d.negative do fmt.print("-")
			fmt.print(d.value)
		} else {
			print_int_kind(v.kind)
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
		print_type(v.left, depth)
		fmt.printf(" %s ", op_symbol(v.operator))
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

	case Mention_Type:
		if v.name != "" {
			fmt.print(v.name)
		} else {
			print_type(v.target, depth)
		}

	case Reference_Type:
		ref := v.reference
		n, n_ok := ref.name.(string)
		idx, idx_ok := ref.index.(u64)
		has_target := v.target != nil
		is_self_ref := n_ok && n == ""&& !idx_ok

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
		return "%%"
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
		return "!"
	case .LShift:
		return "<<"
	case .RShift:
		return ">>"
	}
	return "?"
}

print_int_kind :: proc(k: IntegerKind) {
	switch k {
	case .none:
		fmt.print("Int")
	case .u8:
		fmt.print("u8")
	case .i8:
		fmt.print("i8")
	case .u16:
		fmt.print("u16")
	case .i16:
		fmt.print("i16")
	case .u32:
		fmt.print("u32")
	case .i32:
		fmt.print("i32")
	case .u64:
		fmt.print("u64")
	case .i64:
		fmt.print("i64")
	}
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
