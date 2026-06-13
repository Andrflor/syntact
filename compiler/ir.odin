package compiler

import "core:fmt"
import "core:strings"

// IR data model — the `Type` union and its payloads. A `Type` is the static shape
// of a value or constraint; `Scope_Type` is the recursive backbone. The analyzer
// that builds this IR from the AST lives in analyze.odin.

Integer_Interval :: struct {
	lo: Maybe(i128), // nil = -∞
	hi: Maybe(i128), // nil = +∞
}

Float_Interval :: struct {
	lo:      Maybe(f64), // nil = -∞
	hi:      Maybe(f64), // nil = +∞
	lo_open: bool, // true = exclusive lower bound, e.g. `>x` is (x, +∞)
	hi_open: bool, // true = exclusive upper bound, e.g. `<x` is (-∞, x)
}

// A string interval unifies char and string. `ordinal` is the mode: true = a
// codepoint range ('a'..'z'); false = positional (lo prefix, hi suffix). nil bound
// = open. `count` is the repetition (`*`), default {1..1}, reusing Integer_Type's
// arithmetic; the impossible {-1..-1} tags a word-negation segment in a `+`
// sequence (string.odin seg_is_negation). A []String_Interval is always a UNION.
String_Interval :: struct {
	lo:      Maybe(string),
	hi:      Maybe(string),
	ordinal: bool,
	count:   Integer_Type,
}

FloatKind :: enum {
	none,
	f32,
	f64,
}

// How a binding connects a name to its value. The push/pull pairs mirror Syntact's
// directional operators; only the pointing pair is reduced today (events/resonance/
// reactivity are recorded, not yet reduced). Expand = `+{}`, Product = the
// `->`-less production collapse `!` reduces through.
Binding_Kind :: enum u8 {
	Pointing_Push,
	Pointing_Pull,
	Event_Push,
	Event_Pull,
	Resonance_Push,
	Resonance_Pull,
	Reactive_Push,
	Reactive_Pull,
	Expand,
	Product,
}

// --- the Type union and its variants ---

// `A | B` (sum) and `A & B` (intersection — also the explicit cast).
Or_Type :: struct {
	left:  ^Type,
	right: ^Type,
}

And_Type :: struct {
	left:  ^Type,
	right: ^Type,
}

// `~X` — set complement. Pushed toward the leaves by De Morgan during folding.
Negate_Type :: struct {
	operand: ^Type,
}

// The recursive backbone: a scope's bindings stored column-wise, indexed by ordinal
// (same-name bindings coexist `#0`, `#1`, …). The *_folds arrays cache types[i] and
// values[i] resolved to their sets, filled by typecheck() and reused by reduce.odin.
// `parent` chains lexical scopes for name lookup.
Scope_Type :: struct {
	parent:           ^Scope_Type,
	names:            [dynamic]string, // "" for anonymous / product
	kind:             [dynamic]Binding_Kind,
	types:            [dynamic]^Type,
	type_folds:       [dynamic]^Type, // values[i] folded to its typeof (cached)
	constraints:      [dynamic]^Type,
	constraint_folds: [dynamic]^Type, // types[i] folded to its set (cached)
	// A second, INVISIBLE name per binding (the `(e)` capture). NOT consulted by
	// `.` or carving (those scan `names` only) — reachable only by mention within
	// its own scope (and a pattern branch's production).
	captures:         [dynamic]string,
	// True while the analyzer is still walking this scope's body: folds that touch
	// it are untrustworthy (bindings missing) and defer. Always false on clones.
	walking:          bool,
}

// `scope!` — collapse: reduce `target` through its Product binding.
Execute_Type :: struct {
	target: ^Type,
}

// `source{ name -> v, … }` — derive a new scope by overriding bindings. Each
// `references[i]` locates the overridden field, `types[i]` the replacement; the
// carve stores only the diff, not a copy.
Carve_Type :: struct {
	source:     ^Type,
	references: [dynamic]Reference,
	types:      [dynamic]^Type,
}

// A resolved pointer to a binding: (match_scope, match_index) is the definition
// site; name/index record how it was written, for diagnostics.
Reference :: struct {
	name:        Maybe(string),
	index:       Maybe(u64),
	match_scope: ^Scope_Type,
	match_index: int,
}

// An ordinal/property reference (`a#1`, `a.b`). `target` is the expression reached
// through (nil for a bare ordinal); `reference` the resolved site.
Reference_Type :: struct {
	target:    ^Type,
	reference: ^Reference,
}

// A plain by-name reference (`a`), the common ordinal-less case; follow() chases
// it to the bound value on demand.
Mention_Type :: struct {
	name:        string,
	match_scope: ^Scope_Type,
	match_index: int,
}

// A by-name mention of a binding that mentions ITSELF (`fib` inside fib). Kept
// distinct from Mention_Type so folds defer through it, satisfy detects the
// inductive step, and repoint never rewrites it on carve clones. The scope pointer
// is valid while walking; consumers must check `walking`.
Recursive_Mention_Type :: struct {
	name:        string,
	match_scope: ^Scope_Type,
	match_index: int, // -1 until resolved
}

// Integer domain leaf: a normalized interval set + the bare default. See integer.odin.
Integer_Type :: struct {
	integer_intervals: []Integer_Interval,
	default_value:     Maybe(i128),
}

// Float domain leaf. `kind` tracks the family since intervals don't carry precision.
Float_Type :: struct {
	float_intervals: []Float_Interval,
	kind:            FloatKind,
	default_value:   Maybe(f64),
}

// Pattern domain leaf `target ? {…}`. Branches are tried in order; exhaustiveness =
// the union of branch matches typechecks the target (or one branch is bare `->`).
// fold_constraint resolves to one branch; fold_type combines the matching branches.
Pattern_Type :: struct {
	target:   ^Type,
	branches: []Pattern_Branch,
}

// One branch (nil match = match anything). `value_match` is the `=v` mode vs the
// bare typecheck mode. `cover_fold` is the branch's firing set, folded once at
// analysis and reused by reduce_pattern; nil when the match did not fold statically.
Pattern_Branch :: struct {
	value_match: bool,
	match:       ^Type,
	product:     ^Type,
	cover_fold:  ^Type,
}


// Arithmetic `left <op> right`. Symbolic until folded; `type_fold` caches the result.
Compose_Type :: struct {
	left:      ^Type,
	right:     ^Type,
	operator:  Operator_Kind,
	type_fold: ^Type,
}

// `value :: target` — a raw reinterpret-cast: pad/truncate `value`'s bits to the
// target width (sign- or zero-extend by source signedness), then read under the
// target's signedness. Never a Constraint_Mismatch; fails with Invalid_Cast only
// when the target has no canonical layout (non-zero-based range, open range, sum,
// unbounded `int`). `type_fold` caches the result.
Cast_Type :: struct {
	value:     ^Type,
	target:    ^Type,
	type_fold: ^Type,
}

// `lo..hi`. Either bound may be nil = unbounded on that side (NOT `none`).
Range_Type :: struct {
	left:  ^Type,
	right: ^Type,
}

// Bool domain leaf. `value` set = concrete; nil = the open set {true, false}.
Bool_Type :: struct {
	value:   Maybe(bool),
	default: bool,
}

// String/char domain leaf — a UNION of String_Intervals. See string.odin.
String_Type :: struct {
	string_intervals:  []String_Interval,
	default_value:     Maybe(string),
	default_quotation: String_Quotation,
}

None_Type :: struct {} // the explicit absence of a value (`none`)

Unknown_Type :: struct {} // not yet resolvable (externals, patterns, branches)

Invalid_Type :: struct {} // an error was already reported here; folds to nothing

Type :: union {
	Or_Type,
	And_Type,
	Negate_Type,
	Compose_Type,
	Cast_Type,
	String_Type,
	Scope_Type,
	Integer_Type,
	Float_Type,
	Execute_Type,
	Range_Type,
	Bool_Type,
	None_Type,
	Invalid_Type,
	Unknown_Type,
	Carve_Type,
	Mention_Type,
	Reference_Type,
	Recursive_Mention_Type,
	Pattern_Type,
}


// PRINTING — render the IR (Type) for diagnostics, the --ir dump, and tests.
// Per-domain rendering lives in each domain file; this section composes them.

// type_to_string renders a folded ^Type for error messages.
type_to_string :: proc(t: ^Type) -> string {
	if t == nil do return "<unresolved>"
	#partial switch v in t^ {
	case Integer_Type:
		return integer_to_string(v)
	case Float_Type:
		return float_to_string(v)
	case String_Type:
		b := strings.builder_make()
		write_string_desc(&b, v)
		return strings.to_string(b)
	}
	return "<value>"
}

// Compact rendering of a concrete value (default or reduction) for the tests.
value_to_string :: proc(t: ^Type) -> string {
	if t == nil do return "<nil>"
	b := strings.builder_make()
	write_value(&b, t)
	return strings.to_string(b)
}

write_value :: proc(b: ^strings.Builder, t: ^Type) {
	if t == nil {
		strings.write_string(b, "<nil>")
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
	case None_Type:
		strings.write_string(b, "none")
	case Unknown_Type:
		fmt.sbprintf(b, "??%d", fixedpoint_id(t))
	case Scope_Type:
		strings.write_byte(b, '{')
		first := true
		for i := 0; i < len(v.kind); i += 1 {
			if !first do strings.write_string(b, ", ")
			first = false
			// Prefer the cached fold over the raw value (a computed field shows 15, not x+10).
			fv := v.types[i]
			if i < len(v.type_folds) && v.type_folds[i] != nil do fv = v.type_folds[i]
			if v.kind[i] == .Product {
				strings.write_string(b, "-> ")
				write_value(b, fv)
			} else {
				if v.names[i] != "" {
					strings.write_string(b, v.names[i])
					strings.write_string(b, " -> ")
				}
				write_value(b, fv)
			}
		}
		strings.write_byte(b, '}')
	case Carve_Type:
		// fold the substitution, then render the resulting scope.
		sub := fold_carve_type(t)
		if sub == nil {
			strings.write_string(b, type_to_string(t))
			return
		}
		st := new(Type)
		st^ = sub^
		write_value(b, st)
	case Cast_Type:
		// concrete source → folded result; bare `??::T` atom → `??N`; a width wrapper
		// over a composite (`(a+b)::u8`) → the inner expression in parens, then `::target`.
		if v.type_fold != nil && fold_is_concrete_value(v.type_fold) {
			write_value(b, v.type_fold)
		} else if cast_is_atom(t) {
			fmt.sbprintf(b, "??%d", fixedpoint_id(t))
		} else {
			strings.write_byte(b, '(')
			write_value(b, v.value)
			strings.write_string(b, ")::")
			strings.write_string(b, type_to_string(v.target))
		}
	case Compose_Type:
		// surviving symbolic expression: render infix with parens per precedence.
		write_compose_value(b, v)
	case Mention_Type, Reference_Type:
		fmt.sbprintf(b, "??%d", fixedpoint_id(t))
	case Pattern_Type:
		// pattern over a surviving fixed-point target: render `target ? {match -> product, …}`.
		write_value(b, v.target)
		strings.write_string(b, " ? {")
		for branch, i in v.branches {
			if i > 0 do strings.write_string(b, ", ")
			if branch.match == nil {
				strings.write_string(b, "-> ")
			} else {
				if branch.value_match do strings.write_byte(b, '=')
				write_value(b, branch.match)
				strings.write_string(b, " -> ")
			}
			write_value(b, branch.product)
		}
		strings.write_byte(b, '}')
	case Range_Type:
		if v.left != nil do write_value(b, v.left)
		strings.write_string(b, "..")
		if v.right != nil do write_value(b, v.right)
	case:
		strings.write_string(b, type_to_string(t))
	}
}

// Operator rank for parenthesization: higher binds tighter.
op_prec :: proc(op: Operator_Kind) -> int {
	#partial switch op {
	case .Multiply, .Divide, .Mod:
		return 3
	case .Add, .Subtract:
		return 2
	}
	return 1
}

// Renders a reduced arithmetic node infix, parenthesizing a looser-binding operand.
write_compose_value :: proc(b: ^strings.Builder, v: Compose_Type) {
	if v.left == nil {
		strings.write_string(b, op_symbol(v.operator))
		write_operand_value(b, v.right, op_prec(v.operator))
		return
	}
	write_operand_value(b, v.left, op_prec(v.operator))
	fmt.sbprintf(b, " %s ", op_symbol(v.operator))
	write_operand_value(b, v.right, op_prec(v.operator))
}

write_operand_value :: proc(b: ^strings.Builder, operand: ^Type, parent_prec: int) {
	if operand != nil {
		#partial switch ov in operand^ {
		case Compose_Type:
			if op_prec(ov.operator) < parent_prec {
				strings.write_byte(b, '(')
				write_value(b, operand)
				strings.write_byte(b, ')')
				return
			}
		case Cast_Type:
			// `??::u8` fixed point renders as ??N, not value::target.
			if ov.type_fold == nil || !fold_is_concrete_value(ov.type_fold) {
				fmt.sbprintf(b, "??%d", fixedpoint_id(operand))
				return
			}
		}
	}
	write_value(b, operand)
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
		if len(v.names) == 1 &&
		   v.kind[0] == .Product &&
		   v.names[0] == "" &&
		   v.constraints[0] == nil {
			// root scope: collapse to its sole production; nested: print inline.
			if depth == 0 {
				print_type(v.types[0], depth)
				break
			}
			fmt.print("{->")
			print_type(v.types[0], depth)
			fmt.print("}")
			break
		}
		fmt.println("{")
		for i := 0; i < len(v.names); i += 1 {
			indent(depth + 1)
			has_constraint := v.constraints[i] != nil
			has_name := v.names[i] != ""
			if v.kind[i] == .Expand {
				fmt.print("...")
				if has_constraint {
					print_type(v.constraints[i], depth + 1)
					fmt.print(": -> ")
					print_type(v.types[i], depth + 1)
				} else {
					print_type(v.types[i], depth + 1)
				}
			} else {
				if has_constraint {
					print_type(v.constraints[i], depth + 1)
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
					print_type(v.types[i], depth + 1)
				case .Pointing_Pull:
					fmt.print(" <- ")
					print_type(v.types[i], depth + 1)
				case .Event_Push:
					fmt.print(" >- ")
					print_type(v.types[i], depth + 1)
				case .Event_Pull:
					fmt.print(" -< ")
					print_type(v.types[i], depth + 1)
				case .Resonance_Push:
					fmt.print(" >>- ")
					print_type(v.types[i], depth + 1)
				case .Resonance_Pull:
					fmt.print(" -<< ")
					print_type(v.types[i], depth + 1)
				case .Reactive_Push:
					fmt.print(" >>= ")
					print_type(v.types[i], depth + 1)
				case .Reactive_Pull:
					fmt.print(" =<< ")
					print_type(v.types[i], depth + 1)
				case .Expand:
				case .Product:
					fmt.print("-> ")
					print_type(v.types[i], depth + 1)
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
				// type_folds[i] keeps only the production for a scope-with-production;
				// the dump wants the whole structure, so render members directly.
				print_fold_inline(member_type_fold_display(v.types[i], v.type_folds[i]))
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
		if float_is_concrete(v) {
			fmt.print(float_display(float_value(v)))
		} else if len(v.float_intervals) == 1 {
			print_float_interval(v.float_intervals[0], v.kind)
		} else {
			for interval, i in v.float_intervals {
				if i > 0 do fmt.print(" | ")
				print_float_interval(interval, v.kind)
			}
		}

	case String_Type:
		print_string_type(v)

	case Bool_Type:
		fmt.print(bool_to_string(v))

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

	case Cast_Type:
		print_type(v.value, depth)
		fmt.print("::")
		print_type(v.target, depth)

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
			print_type(v.types[i], depth)
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
			print_type(v.match_scope.types[v.match_index], depth)
		}

	case Recursive_Mention_Type:
		// never expand through it.
		fmt.print(v.name != "" ? v.name : "<recursive>")

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

	case Pattern_Type:
		if v.target != nil do print_type(v.target, depth)
		fmt.print(" ? {")
		for branch, i in v.branches {
			if i > 0 do fmt.print(", ")
			if branch.match == nil {
				fmt.print("-> ")
			} else {
				if branch.value_match do fmt.print("=")
				print_type(branch.match, depth)
				fmt.print(" -> ")
			}
			print_type(branch.product, depth)
		}
		fmt.print("}")

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
		if float_is_concrete(v) {
			f := float_value(v)
			fmt.printf("{%v, %v}", f, f)
		} else {
			print_float_kind(v.kind)
		}
	case String_Type:
		print_string_type(v)
	case Bool_Type:
		fmt.print(bool_to_string(v))
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

// What the `--ir` t: column shows for a member. The cached type_fold collapses a
// scope-with-production to that production; for the dump we want the full structure,
// so when the value is a scope return it (a carve is materialized). Display-only.
member_type_fold_display :: proc(value: ^Type, cached: ^Type) -> ^Type {
	if value != nil {
		#partial switch v in value^ {
		case Scope_Type:
			if !v.walking do return value
		case Carve_Type:
			if sub := fold_carve_type(value); sub != nil {
				st := new(Type)
				st^ = sub^
				return st
			}
		}
	}
	return cached
}

print_fold_inline :: proc(t: ^Type) {
	fmt.print(fold_to_string(t))
}

// Renders any ^Type compactly on one line for the `--ir` t:/c: columns. Favors
// readability over exact source syntax.
fold_to_string :: proc(t: ^Type) -> string {
	b := strings.builder_make()
	write_fold(&b, t)
	return strings.to_string(b)
}

write_fold :: proc(b: ^strings.Builder, t: ^Type) {
	if t == nil {
		strings.write_string(b, "[?]")
		return
	}
	switch v in t^ {
	case Integer_Type:
		strings.write_string(b, integer_to_string(v))
	case Float_Type:
		strings.write_string(b, float_to_string(v))
	case String_Type:
		write_string_desc(b, v)
	case Bool_Type:
		strings.write_string(b, bool_to_string(v))
	case None_Type:
		strings.write_string(b, "none")
	case Unknown_Type:
		strings.write_string(b, "??")
	case Invalid_Type:
		strings.write_string(b, "<invalid>")
	case Scope_Type:
		strings.write_byte(b, '{')
		for i := 0; i < len(v.kind); i += 1 {
			if i > 0 do strings.write_string(b, ", ")
			// Render by binding kind: a production keeps its arrow (`{n -> 0, -> 0}` must
			// not collapse to `{n -> 0, 0}`); named renders `name op value`. Prefer the
			// cached type_fold over the raw value.
			fv := v.types[i]
			if i < len(v.type_folds) && v.type_folds[i] != nil do fv = v.type_folds[i]
			if v.names[i] != "" {
				strings.write_string(b, v.names[i])
				strings.write_string(b, write_binding_op(v.kind[i]))
				write_fold(b, fv)
			} else if v.kind[i] == .Product {
				strings.write_string(b, "-> ")
				write_fold(b, fv)
			} else {
				write_fold(b, fv)
			}
		}
		strings.write_byte(b, '}')
	case Carve_Type:
		write_fold(b, v.source)
		strings.write_byte(b, '{')
		for i := 0; i < len(v.references); i += 1 {
			if i > 0 do strings.write_string(b, ", ")
			if n, ok := v.references[i].name.(string); ok && n != "" {
				strings.write_string(b, n)
				strings.write_string(b, "->")
			}
			write_fold(b, v.types[i])
		}
		strings.write_byte(b, '}')
	case Execute_Type:
		write_fold(b, v.target)
		strings.write_byte(b, '!')
	case Mention_Type:
		strings.write_string(b, v.name != "" ? v.name : "<mention>")
	case Recursive_Mention_Type:
		strings.write_string(b, v.name != "" ? v.name : "<recursive>")
	case Reference_Type:
		if v.target != nil {
			write_fold(b, v.target)
			strings.write_byte(b, '.')
		}
		if v.reference != nil {
			if n, ok := v.reference.name.(string); ok && n != "" do strings.write_string(b, n)
			if idx, ok := v.reference.index.(u64); ok do fmt.sbprintf(b, "#%d", idx)
		}
	case Cast_Type:
		write_fold(b, v.value)
		strings.write_string(b, "::")
		write_fold(b, v.target)
	case Compose_Type:
		if v.left != nil do write_fold(b, v.left)
		fmt.sbprintf(b, " %s ", op_symbol(v.operator))
		write_fold(b, v.right)
	case Range_Type:
		if v.left != nil do write_fold(b, v.left)
		strings.write_string(b, "..")
		if v.right != nil do write_fold(b, v.right)
	case Or_Type:
		write_fold(b, v.left)
		strings.write_string(b, " | ")
		write_fold(b, v.right)
	case And_Type:
		write_fold(b, v.left)
		strings.write_string(b, " & ")
		write_fold(b, v.right)
	case Negate_Type:
		strings.write_byte(b, '~')
		write_fold(b, v.operand)
	case Pattern_Type:
		write_fold(b, v.target)
		strings.write_string(b, " ? {")
		for branch, i in v.branches {
			if i > 0 do strings.write_string(b, ", ")
			if branch.match != nil {
				if branch.value_match do strings.write_byte(b, '=')
				write_fold(b, branch.match)
			}
			strings.write_string(b, "->")
			write_fold(b, branch.product)
		}
		strings.write_byte(b, '}')
	}
}

write_binding_op :: proc(k: Binding_Kind) -> string {
	switch k {
	case .Pointing_Push:
		return "->"
	case .Pointing_Pull:
		return "<-"
	case .Event_Push:
		return ">-"
	case .Event_Pull:
		return "-<"
	case .Resonance_Push:
		return ">>-"
	case .Resonance_Pull:
		return "-<<"
	case .Reactive_Push:
		return ">>="
	case .Reactive_Pull:
		return "=<<"
	case .Expand:
		return "..."
	case .Product:
		return "->"
	}
	return "->"
}

print_float_intervals_inline :: proc(float_intervals: []Float_Interval, kind: FloatKind) {
	fmt.printf("[%s]", pretty_float_intervals(float_intervals, kind))
}

print_float_interval :: proc(interval: Float_Interval, kind: FloatKind) {
	lo, lo_ok := interval.lo.(f64)
	hi, hi_ok := interval.hi.(f64)
	if lo_ok && hi_ok && lo == hi && !interval.lo_open && !interval.hi_open {
		fmt.print(float_display(lo))
		return
	}
	if !lo_ok && !hi_ok {
		print_float_kind(kind)
		return
	}
	if lo_ok {
		if interval.lo_open do fmt.print(">")
		fmt.print(float_display(lo))
	}
	fmt.print("..")
	if hi_ok {
		if interval.hi_open do fmt.print("<")
		fmt.print(float_display(hi))
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
	case .Cast:
		return "::"
	}
	return "?"
}

print_float_kind :: proc(k: FloatKind) {
	switch k {
	case .none:
		fmt.print("float")
	case .f32:
		fmt.print("f32")
	case .f64:
		fmt.print("f64")
	}
}
