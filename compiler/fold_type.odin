package compiler

import "core:fmt"

fold_compose :: proc(a: ^Analyzer, t: ^Type, node: Node_Index) {
	if t == nil do return
	comp, ok := &t^.(Compose_Type)
	if !ok do return
	integer_intervals, segs_ok := fold_to_integer_intervals(t).([]Integer_Interval)
	if segs_ok {
		tf := new(Type)
		tf^ = Integer_Type{integer_intervals, default_for_integer_intervals(integer_intervals)}
		comp.type_fold = tf
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
		return .None
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
			print_type(v.values[0], depth)
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
				print_integer_intervals_inline(v.constraint_folds[i])
				fmt.print(" ")
			}
			if has_tf {
				fmt.print("t:")
				print_integer_intervals_inline(v.type_folds[i])
				fmt.print(" ")
			}
			if has_cf {
				if has_tf {
					if integer_intervals_satisfy(v.type_folds[i], v.constraint_folds[i]) {
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

print_integer_intervals :: proc(t: ^Type) {
	if t == nil {
		fmt.print("none")
		return
	}
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
	lo, lo_ok := interval.lo.(i64)
	hi, hi_ok := interval.hi.(i64)
	if lo_ok && hi_ok && lo == hi {
		fmt.print(lo)
		return
	}
	if lo_ok do fmt.print(lo)
	fmt.print("..")
	if hi_ok do fmt.print(hi)
}

print_integer_interval :: proc(interval: Integer_Interval) {
	lo, lo_ok := interval.lo.(i64)
	hi, hi_ok := interval.hi.(i64)
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
