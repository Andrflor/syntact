package compiler

import "core:fmt"

// --- generic fold (domain-agnostic dispatch) ---
//
// fold_type derives the constraint a value *produces* (its envelope): for `5`
// it is `5..5`, for `a + b` the envelope of the sum, for a reference the
// target's. fold_constraint resolves the constraint a binding *imposes*; it
// must reduce to a closed, compile-time-known object. Both return a reduced
// ^Type or nil when the form cannot be resolved statically.
//
// satisfy(fc, ft) proves ft ⊆ fc. These three functions are pure dispatch —
// every domain-specific operation lives in its domain file (fold_integer.odin).
// To add a domain (float, string), give it fold_*_<domain>/<domain>_satisfy/
// <domain>_to_string and add a case here.

// A binding `constraint : … -> value` is checked by matching the *type* of the
// value against the *value* of the constraint:
//
//   - LEFT of `:` (the constraint) folds to its VALUE — the set it denotes.
//     u8 -> Integer_Type{0..255}. That is fold_constraint.
//   - RIGHT of `->` (the value) folds to its TYPE (a typeof). A concrete
//     singleton (10, or 5..5) is its own type: Integer_Type{10,10}. A set
//     (u8, 1..2, >=20) is NOT a value, so its type is the producer scope
//     {-> set}. That is fold_value_type. The value/set split is SEMANTIC:
//     singleton (hi==lo) -> value, otherwise -> producer.
//
// satisfy then proves fold_value_type(value) fits fold_constraint(constraint).

// fold_constraint folds the imposed constraint to the set the value must fall
// into (the LEFT side). A producer scope {-> X} is NOT flattened: its value is
// the producer of fold_constraint(X), mirroring fold_value_type on the right so
// {->u8} (constraint) matches u8 (value). A plain (non-producer) scope keeps
// its shape. Returns nil when it cannot be resolved statically.
fold_constraint :: proc(t: ^Type) -> ^Type {
	if t != nil {
		#partial switch v in t^ {
		case Scope_Type:
			return t
		case Mention_Type:
			if v.match_scope != nil && v.match_index >= 0 {
				return fold_constraint_target(v.match_scope, v.match_index)
			}
		case Reference_Type:
			ref := v.reference
			if ref != nil && ref.match_scope != nil && ref.match_index >= 0 {
				return fold_constraint_target(ref.match_scope, ref.match_index)
			}
		case And_Type:
			r := new(Type)
			r^ = And_Type{fold_constraint(v.left), fold_constraint(v.right)}
			return r
		case Or_Type:
			r := new(Type)
			r^ = Or_Type{fold_constraint(v.left), fold_constraint(v.right)}
			return r
		}
	}
	if r := fold_constraint_integer(t); r != nil do return r
	return nil
}

// fold_constraint_target folds the value at scope[i] when it is used as a
// constraint. If that value is Unknown (??), the constraint is only resolvable
// when the Unknown's type is a single concrete value: a singleton constraint
// fold becomes that value, anything else stays Unknown (which never satisfies).
fold_constraint_target :: proc(scope: ^Scope_Type, i: int) -> ^Type {
	value := scope.values[i]
	if value != nil {
		if _, is_unknown := value^.(Unknown_Type); is_unknown {
			ty := scope.constraint_folds[i]
			if ty != nil && fold_is_concrete_value(ty) do return ty
			r := new(Type)
			r^ = Unknown_Type{}
			return r
		}
	}
	return fold_constraint(value)
}

// fold_value_type yields the TYPE of a value (the RIGHT side, a typeof).
// Singleton -> the value itself; any wider set -> the producer scope {-> set}.
fold_value_type :: proc(t: ^Type) -> ^Type {
	// A producer scope {-> X} on the right is itself a value of a higher meta
	// level: its type is the producer of fold_value_type(X). This mirrors
	// fold_constraint on the left so {->X} matches across sides.
	if t != nil {
		#partial switch v in t^ {
		case Scope_Type:
			prods := scope_productions(v)
			if len(prods) > 0 {
				folded := make([dynamic]^Type, 0, len(prods))
				for p in prods {
					fp := fold_value_type(p)
					if fp == nil do return nil
					append(&folded, fp)
				}
				return make_producer_scope_multi(folded[:])
			}
		}
	}
	// Envelope of the value. fold_type_integer covers concrete values and
	// arithmetic; sets built with ~ | & only resolve through the constraint
	// fold, so fall back to it for those.
	env := fold_type_integer(t)
	if env == nil do env = fold_constraint_integer(t)
	if env == nil do return nil
	if fold_is_concrete_value(env) do return env
	return make_producer_scope(env)
}

// fold_is_concrete_value reports whether a folded ^Type denotes one concrete
// value (a singleton) rather than a set/range. Domain dispatch.
fold_is_concrete_value :: proc(t: ^Type) -> bool {
	if t == nil do return false
	#partial switch v in t^ {
	case Integer_Type:
		return integer_intervals_is_concrete(v.integer_intervals)
	}
	return false
}

// make_producer_scope builds the scope {-> produces} — the type of a set, one
// meta level up. Reuses Scope_Type (a single .Product binding).
make_producer_scope :: proc(produces: ^Type) -> ^Type {
	if produces == nil do return nil
	return make_producer_scope_multi([]^Type{produces})
}

// make_producer_scope_multi builds a producer scope with one .Product binding
// per element of produces (preserving order).
make_producer_scope_multi :: proc(produces: []^Type) -> ^Type {
	scope := new(Scope_Type)
	for p in produces {
		append(&scope.names, "")
		append(&scope.types, nil)
		append(&scope.kind, Binding_Kind.Product)
		append(&scope.values, p)
		append(&scope.type_folds, nil)
		append(&scope.constraint_folds, nil)
	}
	r := new(Type)
	r^ = scope^
	return r
}

// satisfy proves the folded value ft (a typeof) fits the folded constraint fc.
// fc is on the LEFT, ft on the RIGHT — mirroring the language, where the
// constraint sits left of `:` and the value right of `->`.
//
//   - fc Integer_Type vs ft Integer_Type : a concrete value against a set →
//     membership (10 ∈ u8). u8:a -> 10 ✅.
//   - fc Integer_Type vs ft Scope (producer) : a set is not a member of a set →
//     fail. u8:a -> u8 ❌ (u8 is not of type u8).
//   - fc Scope vs ft Scope : two producers → match their productions in order.
//     {->u8}:a -> u8 ✅.
satisfy :: proc(fc, ft: ^Type) -> bool {
	if fc == nil || ft == nil do return false
	#partial switch f in fc^ {
	case Integer_Type:
		v, ok := ft^.(Integer_Type)
		return ok && integer_satisfy(f, v)
	case Scope_Type:
		v, ok := ft^.(Scope_Type)
		if !ok do return false
		return scope_satisfy(f, v)
	case And_Type:
		return satisfy(f.left, ft) && satisfy(f.right, ft)
	case Or_Type:
		return satisfy(f.left, ft) || satisfy(f.right, ft)
	}
	return false
}

satisfy_root :: proc(fc, ft: ^Type) -> bool {
	v, ok := fc^.(Scope_Type)
	if ok {
		hasProd := false
		// A constraint root with productions is a sum: the value satisfies it
		// if it matches AT LEAST ONE production. Each production IS the target
		// constraint (the content the value must be). The value fold ft carries
		// one extra producer level for sets ({->u8}) but not for singletons
		// (10) — so compare the production against ft's content: ft's own
		// production when ft is a producer, ft itself otherwise.
		ft_content := ft
		if vt, vt_ok := ft^.(Scope_Type); vt_ok {
			prods := scope_productions(vt)
			if len(prods) == 1 do ft_content = prods[0]
		}
		for i := 0; i < len(v.kind); i += 1 {

			if (v.kind[i] == .Product) {
				hasProd = true
				if (satisfy(v.values[i], ft_content)) {
					return true
				}
			}
		}
		if (hasProd) {
			return false
		}
	}
	return satisfy(fc, ft)
}


scope_satisfy :: proc(cs, vs: Scope_Type) -> bool {
	if len(vs.names) != len(cs.names) do return false
	for i in 0 ..< len(cs.names) {
		if vs.names[i] != cs.names[i] do return false
		if vs.kind[i] != cs.kind[i] do return false
		// Match the binding CONTENT, not just its shape: a producer of u8
		// ({->u8}) must not satisfy a producer of a producer ({->{->u8}}).
		if !satisfy(cs.values[i], vs.values[i]) do return false
	}
	return true
}

scope_productions :: proc(s: Scope_Type) -> [dynamic]^Type {
	out := make([dynamic]^Type, 0, len(s.kind))
	for i in 0 ..< len(s.kind) {
		if s.kind[i] == .Product do append(&out, s.values[i])
	}
	return out
}

// type_to_string renders a folded ^Type for error messages.
type_to_string :: proc(t: ^Type) -> string {
	if t == nil do return "<unresolved>"
	#partial switch v in t^ {
	case Integer_Type:
		return integer_to_string(v)
	}
	return "<value>"
}

fold_compose :: proc(a: ^Analyzer, t: ^Type, node: Node_Index) {
	if t == nil do return
	comp, ok := &t^.(Compose_Type)
	if !ok do return
	// fold_compose stores the raw numeric envelope of the arithmetic (a value),
	// not its typeof — the envelope is consumed by further interval arithmetic.
	folded := fold_type_integer(t)
	if folded != nil {
		comp.type_fold = folded
	} else {
		sem_error(
			a,
			"Cannot fold type: operands must be integers",
			.Invalid_operator,
			node_pos(a, node),
		)
	}
}

fold_range :: proc(a: ^Analyzer, t: ^Type, node: Node_Index) {
	if t == nil do return
	range, ok := t^.(Range_Type)
	if !ok do return

	left_resolved := follow(range.left)
	right_resolved := follow(range.right)

	left_kind := range_operand_kind(left_resolved)
	right_kind := range_operand_kind(right_resolved)

	if left_kind == .Invalid {
		sem_error(
			a,
			"Invalid range: left side must be an integer, float, or string",
			.Invalid_Range,
			node_pos(a, node),
		)
		return
	}
	if right_kind == .Invalid {
		sem_error(
			a,
			"Invalid range: right side must be an integer, float, or string",
			.Invalid_Range,
			node_pos(a, node),
		)
		return
	}

	if left_kind != .None && right_kind != .None && left_kind != right_kind {
		sem_error(
			a,
			fmt.tprintf(
				"Invalid range: mismatched types (%s .. %s)",
				range_kind_name(left_kind),
				range_kind_name(right_kind),
			),
			.Invalid_Range,
			node_pos(a, node),
		)
	}
}

Range_Operand_Kind :: enum {
	None,
	Integer,
	Float,
	String,
	Invalid,
}


range_operand_kind :: proc(t: ^Type) -> Range_Operand_Kind {
	if t == nil do return .None
	#partial switch v in t^ {
	case Integer_Type:
		return .Integer
	case Float_Type:
		return .Float
	case String_Type:
		return .String
	case None_Type:
		return .Invalid
	case Scope_Type:
		for i := 0; i < len(v.kind); i += 1 {
			if v.kind[i] == .Product {
				return range_operand_kind(v.values[i])
			}
		}
		return .Invalid
	case Mention_Type:
		if v.match_scope != nil && v.match_index >= 0 {
			return range_operand_kind(v.match_scope.values[v.match_index])
		}
		return .Invalid
	case Reference_Type:
		if v.reference != nil && v.reference.match_scope != nil && v.reference.match_index >= 0 {
			return range_operand_kind(v.reference.match_scope.values[v.reference.match_index])
		}
		return .Invalid
	}
	return .Invalid
}


range_kind_name :: #force_inline proc(kind: Range_Operand_Kind) -> string {
	switch kind {
	case .Integer:
		return "Integer"
	case .Float:
		return "Float"
	case .String:
		return "String"
	case .None:
		return "none"
	case .Invalid:
		return "invalid"
	}
	return "unknown"
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
		if len(v.names) == 1 && v.kind[0] == .Product && v.names[0] == "" && v.types[0] == nil {
			// Root scope (the file): collapse to its sole production.
			if depth == 0 {
				print_type(v.values[0], depth)
				break
			}
			// Nested single-production scope = a producer {->X}: print inline.
			fmt.print("{->")
			print_type(v.values[0], depth)
			fmt.print("}")
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
				print_fold_inline(v.constraint_folds[i])
				fmt.print(" ")
			}
			if has_tf {
				fmt.print("t:")
				print_fold_inline(v.type_folds[i])
				fmt.print(" ")
			}
			if has_cf {
				if has_tf {
					if satisfy_root(v.constraint_folds[i], v.type_folds[i]) {
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
		} else if len(v.integer_intervals) == 1 {
			print_integer_interval(v.integer_intervals[0])
		} else {
			for interval, i in v.integer_intervals {
				if i > 0 do fmt.print(" | ")
				print_integer_interval(interval)
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
		if v.left != nil do print_type(v.left, depth)
		fmt.print("..")
		if v.right != nil do print_type(v.right, depth)

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

	case Or_Type:
		print_type(v.left, depth)
		fmt.print(" | ")
		print_type(v.right, depth)

	case And_Type:
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

print_integer_intervals :: proc(t: ^Type) {
	#partial switch v in t^ {
	case Integer_Type:
		for interval, i in v.integer_intervals {
			if i > 0 do fmt.print(", ")
			print_range_inline(interval)
		}
		return
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

// print_fold_inline renders a folded ^Type (as stored in type_folds /
// constraint_folds) for the --ir dump. Domain dispatch.
print_fold_inline :: proc(t: ^Type) {
	if t == nil {
		fmt.print("[?]")
		return
	}
	#partial switch v in t^ {
	case Integer_Type:
		print_integer_intervals_inline(v.integer_intervals)
		return
	}
	fmt.print("[?]")
}

print_integer_intervals_inline :: proc(integer_intervals: []Integer_Interval) {
	if len(integer_intervals) == 1 {
		name, name_ok := builtin_name(integer_intervals[0]).(string)
		if name_ok {
			fmt.printf("[%s]", name)
			return
		}
	}
	fmt.print("[")
	for interval, i in integer_intervals {
		if i > 0 do fmt.print(" | ")
		print_range_inline(interval)
	}
	fmt.print("]")
}

print_range_inline :: proc(interval: Integer_Interval) {
	lo, lo_ok := interval.lo.(i128)
	hi, hi_ok := interval.hi.(i128)
	if lo_ok && hi_ok && lo == hi {
		fmt.print(lo)
		return
	}
	if lo_ok do fmt.print(lo)
	fmt.print("..")
	if hi_ok do fmt.print(hi)
}

print_integer_interval :: proc(interval: Integer_Interval) {
	lo, lo_ok := interval.lo.(i128)
	hi, hi_ok := interval.hi.(i128)
	if lo_ok && hi_ok && lo == hi {
		fmt.print(lo)
	} else {
		name, name_ok := builtin_name(interval).(string)
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
