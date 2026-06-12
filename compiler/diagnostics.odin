package compiler

import "core:fmt"
import "core:strings"

// diagnostics.odin — turns analysis failures into messages a Syntact author can
// act on. The fold_* procedures answer a yes/no question (does this resolve?);
// this file owns the WHY and phrases it in the language's own vocabulary —
// values, colors (`:`), constraints — never the compiler's internals (folds,
// intervals, envelopes). Messages are short: name the value(s), state the rule,
// suggest the fix in one line.
//
// NB: any rendered fragment may contain `{` / `}` (scopes, producers). Always
// pass such fragments through `%s`, and never build them with fmt.tprintf
// (its `{` are format verbs) — use a strings.Builder.

// --- value families -------------------------------------------------------

// Family is the broad shape of a resolved value, used to decide whether an
// operation is meaningful and to phrase mismatches.
Family :: enum {
	Unknown, // not statically resolvable (??), no claim possible
	Integer,
	Float,
	String,
	Bool,
	Scope,
	None,
	Other,
}

// family_of classifies a value by following references/mentions to the thing it
// ultimately denotes.
family_of :: proc(t: ^Type) -> Family {
	if t == nil do return .None
	#partial switch v in t^ {
	case Integer_Type:
		return .Integer
	case Float_Type:
		return .Float
	case String_Type:
		return .String
	case Bool_Type:
		return .Bool
	case Scope_Type:
		for i := 0; i < len(v.kind); i += 1 {
			if v.kind[i] == .Product {
				return family_of(v.types[i])
			}
		}
		return .Scope
	case Range_Type:
		lf := family_of(v.left)
		if lf != .None do return lf
		return family_of(v.right)
	case Compose_Type:
		if v.type_fold != nil do return family_of(v.type_fold)
		lf := family_of(v.left)
		if lf != .None && lf != .Unknown do return lf
		return family_of(v.right)
	case Cast_Type:
		// A `value :: target` lands in the target's domain — so `??::u8` is an
		// Integer family member, not an opaque "value". This lets a fixed point
		// participate in arithmetic/comparison without a spurious Invalid_operator.
		return family_of(v.target)
	case Negate_Type:
		return family_of(v.operand)
	case Mention_Type:
		if v.match_scope != nil && v.match_index >= 0 {
			return family_of(v.match_scope.types[v.match_index])
		}
		return .Unknown
	case Reference_Type:
		ref := v.reference
		if ref != nil && ref.match_scope != nil && ref.match_index >= 0 {
			return family_of(ref.match_scope.types[ref.match_index])
		}
		return .Unknown
	case Unknown_Type:
		return .Unknown
	case None_Type:
		return .None
	}
	return .Other
}

family_name :: proc(f: Family) -> string {
	switch f {
	case .Integer:
		return "integer"
	case .Float:
		return "float"
	case .String:
		return "string"
	case .Bool:
		return "bool"
	case .Scope:
		return "scope"
	case .None:
		return "nothing"
	case .Unknown:
		return "unknown value"
	case .Other:
		return "value"
	}
	return "value"
}

// describe_value renders a short phrase naming a value's family and, when
// concrete, its literal: "integer 0", "float 0.2", "color f32", "string \"hi\"".
describe_value :: proc(t: ^Type) -> string {
	resolved := follow_for_diagnostic(t)
	if resolved == nil do return "nothing"
	#partial switch v in resolved^ {
	case Integer_Type:
		if int_is_concrete(v) do return fmt.tprintf("integer %v", int_value(v))
		return strings.concatenate({"integer ", integer_to_string(v)})
	case Float_Type:
		if float_is_concrete(v) do return strings.concatenate({"float ", float_to_string(v)})
		if v.kind == .none do return "a float"
		return strings.concatenate({"color ", float_kind_name(v.kind)})
	case String_Type:
		if string_is_concrete(v) do return strings.concatenate({"string \"", string_value(v), "\""})
		return "a string"
	case Bool_Type:
		return bool_to_string(v)
	case Scope_Type:
		return "a scope"
	case Unknown_Type:
		return "an unknown value (??)"
	case None_Type:
		return "nothing"
	}
	return "a value"
}

float_kind_name :: proc(k: FloatKind) -> string {
	switch k {
	case .f32:
		return "f32"
	case .f64:
		return "f64"
	case .none:
		return "float"
	}
	return "Float"
}

// describe_type renders any ^Type compactly for constraint messages: a value
// keeps its literal, a builtin its name (u8, f32), a producer reads "{-> …}", a
// structural scope a short word. Builder-based so embedded braces survive.
describe_type :: proc(t: ^Type) -> string {
	b := strings.builder_make()
	write_type_desc(&b, t)
	return strings.to_string(b)
}

write_type_desc :: proc(b: ^strings.Builder, t: ^Type) {
	if t == nil {
		strings.write_string(b, "nothing")
		return
	}
	#partial switch v in t^ {
	case Integer_Type:
		strings.write_string(b, integer_to_string(v))
	case Float_Type:
		strings.write_string(b, float_to_string(v))
	case String_Type:
		write_string_desc(b, v)
	case Bool_Type:
		write_bool_desc(b, v)
	case Scope_Type:
		prods := scope_productions(v)
		if len(prods) == 1 && len(v.names) == 1 {
			strings.write_string(b, "{->")
			write_type_desc(b, prods[0])
			strings.write_byte(b, '}')
		} else if len(prods) > 0 {
			strings.write_string(b, "a producer")
		} else {
			strings.write_string(b, "a scope")
		}
	case Range_Type:
		if v.left != nil do write_type_desc(b, v.left)
		strings.write_string(b, "..")
		if v.right != nil do write_type_desc(b, v.right)
	case And_Type:
		write_type_desc(b, v.left)
		strings.write_string(b, " & ")
		write_type_desc(b, v.right)
	case Or_Type:
		write_type_desc(b, v.left)
		strings.write_string(b, " | ")
		write_type_desc(b, v.right)
	case Unknown_Type:
		strings.write_string(b, "??")
	case None_Type:
		strings.write_string(b, "nothing")
	case:
		strings.write_string(b, "a value")
	}
}

// follow_for_diagnostic resolves mentions/references to the underlying value so
// describe_value can name the literal, not the indirection.
follow_for_diagnostic :: proc(t: ^Type) -> ^Type {
	cur := t
	for cur != nil {
		#partial switch v in cur^ {
		case Mention_Type:
			if v.match_scope != nil && v.match_index >= 0 {
				cur = v.match_scope.types[v.match_index]
				continue
			}
		case Reference_Type:
			ref := v.reference
			if ref != nil && ref.match_scope != nil && ref.match_index >= 0 {
				cur = ref.match_scope.types[ref.match_index]
				continue
			}
		}
		break
	}
	return cur
}

float_color :: proc(t: ^Type) -> FloatKind {
	resolved := follow_for_diagnostic(t)
	if resolved == nil do return .none
	#partial switch v in resolved^ {
	case Float_Type:
		return v.kind
	}
	return .none
}

is_numeric_family :: #force_inline proc(f: Family) -> bool {
	return f == .Integer || f == .Float
}

// --- compose diagnostic -----------------------------------------------------

// diagnose_compose is called when fold_compose could not produce a numeric
// envelope for an arithmetic/bitwise operation. It inspects the operands and
// emits the most specific, author-facing error it can. The operator is
// arithmetic/bitwise (Set/`~` operators never reach here).
diagnose_compose :: proc(a: ^Analyzer, comp: Compose_Type, span: Span) {
	sym := op_symbol(comp.operator)

	// Unary form (no left operand).
	if comp.left == nil {
		rf := family_of(comp.right)
		if rf == .Integer || rf == .Float do return
		if rf == .Unknown {
			diag_unknown(a, sym, span)
			return
		}
		diag(
			a,
			span,
			fmt.tprintf("'%s' expects a number, not %s", sym, describe_value(comp.right)),
		)
		return
	}

	lf := family_of(comp.left)
	rf := family_of(comp.right)

	if lf == .Unknown || rf == .Unknown {
		diag_unknown(a, sym, span)
		return
	}

	// Type mismatch: integer and float don't mix without an explicit cast.
	if (lf == .Integer && rf == .Float) || (lf == .Float && rf == .Integer) {
		diag(
			a,
			span,
			fmt.tprintf(
				"type mismatch: cannot %s %s and %s without a cast — color the integer (e.g. 'f64:x -> ...' or write it as a float '0.0')",
				op_verb(comp.operator),
				describe_value(comp.left),
				describe_value(comp.right),
			),
		)
		return
	}

	// Two floats with incompatible colors (f32 vs f64).
	if lf == .Float && rf == .Float {
		lk := float_color(comp.left)
		rk := float_color(comp.right)
		if !float_kind_compatible(lk, rk) {
			diag(
				a,
				span,
				fmt.tprintf(
					"type mismatch: cannot %s %s and %s — float colors %s and %s differ",
					op_verb(comp.operator),
					describe_value(comp.left),
					describe_value(comp.right),
					float_kind_name(lk),
					float_kind_name(rk),
				),
			)
			return
		}
		diag_open_or_divzero(a, comp, span)
		return
	}

	// Non-numeric operand (string, bool, scope…).
	if !is_numeric_family(lf) {
		diag(
			a,
			span,
			fmt.tprintf(
				"'%s' expects numbers; left operand is %s",
				sym,
				describe_value(comp.left),
			),
		)
		return
	}
	if !is_numeric_family(rf) {
		diag(
			a,
			span,
			fmt.tprintf(
				"'%s' expects numbers; right operand is %s",
				sym,
				describe_value(comp.right),
			),
		)
		return
	}

	diag_open_or_divzero(a, comp, span)
}

diag_open_or_divzero :: proc(a: ^Analyzer, comp: Compose_Type, span: Span) {
	if comp.operator == .Divide || comp.operator == .Mod {
		diag(
			a,
			span,
			fmt.tprintf(
				"cannot %s %s by %s: the divisor may be zero",
				op_verb(comp.operator),
				describe_value(comp.left),
				describe_value(comp.right),
			),
		)
		return
	}
	diag(
		a,
		span,
		fmt.tprintf(
			"cannot %s %s and %s at compile time",
			op_verb(comp.operator),
			describe_value(comp.left),
			describe_value(comp.right),
		),
	)
}

diag_unknown :: proc(a: ^Analyzer, sym: string, span: Span) {
	diag(
		a,
		span,
		fmt.tprintf(
			"'%s' has an unknown operand (??) that cannot be computed at compile time",
			sym,
		),
	)
}

diag :: #force_inline proc(a: ^Analyzer, span: Span, msg: string) {
	sem_error(a, msg, .Invalid_operator, span)
}

op_verb :: proc(op: Operator_Kind) -> string {
	#partial switch op {
	case .Add:
		return "add"
	case .Subtract:
		return "subtract"
	case .Multiply:
		return "multiply"
	case .Divide:
		return "divide"
	case .Mod:
		return "take the modulo of"
	case .LShift, .RShift:
		return "shift"
	case .BitAnd, .BitOr, .Xor:
		return "combine"
	}
	return "combine"
}
