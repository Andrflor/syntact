package compiler

import "core:fmt"
import "core:strings"

// IR data model — the `Type` union and its payloads, the single shape every
// Syntact form resolves to. Syntact has no type system: a `Type` is the static
// shape of a value or a constraint. `Scope_Type` is the recursive backbone (a
// scope is parallel `[dynamic]` arrays indexed by binding ordinal); the domain
// payloads (Integer/Float/String intervals, Bool) carry the constraint sets the
// folding in type.odin/integer.odin/float.odin/string.odin/bool.odin reasons over.
// The analyzer that BUILDS this IR from the AST lives in analyze.odin.

// --- shared interval types (the domain payloads carried inside a Type) ---

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

// A string interval unifies char and string. The `ordinal` flag IS the mode
// (set once at construction from the literal's quotation + length):
//   ORDINAL    (ordinal = true): a codepoint range — 'a'..'z' = any single char
//              with codepoint in [lo,hi]. A single-quote literal ≤ 1 codepoint.
//   POSITIONAL (ordinal = false): lo = required prefix, hi = required suffix —
//              "a".."z" → starts with "a", ends with "z" (positional even for 1
//              char!); any double-quote / backtick / multi-char literal.
// So the QUOTE picks the mode once, here: only a single-char single-quote bound is
// ordinal; "a".."z" is positional (prefix a, suffix z), not ordinal. nil bound =
// open (no prefix / no suffix, or ±∞ ordinal).
//
// `count` carries the repetition (`*`). Default {1..1}. For an ordinal element it
// is the number of chars ('a'..'z'*3 = 3 single chars each in [a-z]); for a
// concrete element it is the number of repetitions of that literal ("ab"*3 =
// "ababab"). It reuses all of Integer_Type's arithmetic (so the count can itself
// be a range: 'a'..'z'*2..4 = 2 to 4 letters). The impossible count {-1..-1} TAGS
// a word-negation segment inside a `+` sequence (see string.odin seg_is_negation).
//
// A []String_Interval is ALWAYS a UNION of alternatives (`|`): a value matches if
// it satisfies AT LEAST ONE segment. The ordered concatenation `+` is NOT a flat
// []String_Interval — it stays a Compose_Type, matched in order at satisfy time
// (string.odin fold_string_sequence / string_compose_satisfy). A three-bound range
// "ab".."cd".."ef" likewise stays a raw Range_Type (string_tri_range_satisfy):
// starts with ab, contains cd, ends with ef.
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

// How a binding connects a name to its value inside a scope. The four
// push/pull pairs mirror Syntact's directional operators (`->`/`<-`, `>-`/`-<`,
// `>>-`/`-<<`, `>>=`/`=<<`); only the pointing pair is fully exercised today —
// events, resonance and reactivity are recorded but not yet reduced. `Expand`
// is `+{}` extension, `Product` is the scope's `->`-less production (what
// collapse `!` reduces through).
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
//
// The variants split into three groups:
//   * connective shapes — Or/And/Negate (the `|`/`&`/~` constraint algebra),
//     Compose (arithmetic), Range — that combine other Types symbolically until
//     a fold collapses them to a domain (see type.odin / integer.odin / …);
//   * domain leaves — Integer/Float/String/Bool — carrying concrete interval
//     sets plus the default the scope produces when collapsed bare;
//   * structural shapes — Scope/Carve/Execute and the two indirections
//     (Mention/Reference) that point back at a binding rather than copying it.
// None/Unknown/Invalid are the absence, the not-yet-resolved, and the
// already-errored sentinels; they fold to nothing and never satisfy a constraint.

// `A | B` (sum) and `A & B` (product/intersection — also the explicit cast).
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

// The recursive backbone. A scope is its bindings stored column-wise, indexed by
// ordinal — same-name bindings coexist (`#0`, `#1`, …). For binding i:
//   names[i]            the bound name ("" for anonymous / positional / product)
//   types[i]            the imposed constraint, unfolded (nil if none)
//   kind[i]             the Binding_Kind connecting name to value
//   values[i]           the bound value, unfolded
//   constraint_folds[i] types[i] resolved to its set (the LEFT of `:`) — cached
//   type_folds[i]       values[i] folded to its typeof (the RIGHT of `->`) — cached
// The two *_folds arrays are filled by typecheck() and reused by reduce.odin so
// the proof is computed once. `parent` chains lexical scopes for name lookup.
Scope_Type :: struct {
	parent:           ^Scope_Type,
	names:            [dynamic]string,
	types:            [dynamic]^Type,
	kind:             [dynamic]Binding_Kind,
	values:           [dynamic]^Type,
	type_folds:       [dynamic]^Type,
	constraint_folds: [dynamic]^Type,
}

// `scope!` — collapse: reduce `target` through its Product binding.
Execute_Type :: struct {
	target: ^Type,
}

// `source{ name -> v, … }` — derive a new scope from `source` by overriding
// some of its bindings. Each `references[i]` locates the overridden field in
// the source scope; `values[i]` is the replacement. Unmentioned fields are
// inherited, so the carve stores only the diff, not a full copy of the source.
Carve_Type :: struct {
	source:     ^Type,
	references: [dynamic]Reference,
	values:     [dynamic]^Type,
}

// A resolved pointer to a specific binding: (match_scope, match_index) is the
// definition site; name/index record how it was written (name and/or ordinal)
// for diagnostics. Used both inside carves and inside Reference_Type.
Reference :: struct {
	name:        Maybe(string),
	index:       Maybe(u64),
	match_scope: ^Scope_Type,
	match_index: int,
}

// An ordinal/property reference (`a#1`, `a.b`). `target` is the expression it
// was reached through (nil for a bare ordinal); `reference` is the resolved site.
Reference_Type :: struct {
	target:    ^Type,
	reference: ^Reference,
}

// A plain by-name reference (`a`). Unlike Reference_Type it is the common,
// ordinal-less case; follow() chases it to the bound value on demand.
Mention_Type :: struct {
	name:        string,
	match_scope: ^Scope_Type,
	match_index: int,
}

// Integer domain leaf: a normalized set of intervals (e.g. u8 = 0..255) plus the
// value the scope produces bare. See integer.odin for the interval algebra.
Integer_Type :: struct {
	integer_intervals: []Integer_Interval,
	default_value:     Maybe(i128),
}

// Float domain leaf. `kind` tracks the family (f32/f64/unsized) since intervals
// alone don't distinguish precision. See float.odin.
Float_Type :: struct {
	float_intervals: []Float_Interval,
	kind:            FloatKind,
	default_value:   Maybe(f64),
}

// Pattern domain leaf. A pattern is assesed on something
// In order to typechek the pattern must be exhaustve
// So union of the match in the pattern should tpyecheck with the type_fold of target
// Or one pattern_branch need a empty arrow
// Branch are always considered in order
// When fold the pattern_type resolve to the according product of it's branch
// When fold_constraint is calledd it must resolve to one branch
// When fold_type is called it can resolve to multiple branches and the combined type is atributed
Pattern_Type :: struct {
	target:   ^Type,
	branches: []Pattern_Branch,
}

// Pattern branch, nil match mean match anything
// There is two pattern mode one prefixed with a = unary value pattern check
// And one witout the = wich is a typechek
Pattern_Branch :: struct {
	value_match: bool,
	match:       ^Type,
	product:     ^Type,
}


// Arithmetic `left <op> right` (`+`, `-`, `*`, …). Kept symbolic until folded;
// `type_fold` caches the resulting envelope once fold_compose() resolves it.
Compose_Type :: struct {
	left:      ^Type,
	right:     ^Type,
	operator:  Operator_Kind,
	type_fold: ^Type,
}

// `value :: target` — a raw binary reinterpret-cast. Unlike `&` (which narrows
// by intersection and can fail to prove), `::` forces `value`'s bits into the
// target's layout: pad/cut to the target width (zero-extend if the source domain
// is unsigned, sign-extend if signed; truncate the high bits when narrowing),
// THEN reinterpret the resulting bit pattern under the target's signedness.
// e.g. `i8 -1 :: u8` -> 255 (bits 0xFF read unsigned); `u8 200 :: i16` -> 200
// (zero-extended 0x00C8 read signed). The result always lands inside the target,
// so `::` never raises a Constraint_Mismatch — it can only fail statically with
// Invalid_Cast when the target has no canonical binary layout (a non-zero-based
// range like 10..37, an open range `>10`, a sum/product, or unbounded `int`).
// `type_fold` caches the resulting concrete value/envelope once fold_cast resolves.
Cast_Type :: struct {
	value:     ^Type,
	target:    ^Type,
	type_fold: ^Type,
}

// `lo..hi`. Either bound may be nil (prefix `..hi` / postfix `lo..`), meaning
// "unbounded on that side" — NOT the value `none`. Folded by fold_range().
Range_Type :: struct {
	left:  ^Type,
	right: ^Type,
}

// Bool domain leaf. `value` is set for a concrete true/false; nil means the open
// set {true, false} (i.e. the `Bool` constraint), with `default` the bare value.
Bool_Type :: struct {
	value:   Maybe(bool),
	default: bool,
}

// String/char domain leaf — a UNION of String_Intervals (each carrying its own
// `ordinal` mode flag; see above). `default_quotation` is the quote to render the
// materialized default with. See string.odin.
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
	Pattern_Type,
}


// ===========================================================================
// PRINTING — render the IR (Type) for diagnostics, the --ir dump, and tests.
//   type_to_string : a folded ^Type for error messages
//   value_to_string/write_value : a concrete reduced/default value (tests)
//   print_type : the full --ir tree dump
// Per-domain rendering (integer_to_string, float_to_string, print_string_type,
// bool_to_string) lives in each domain file; this section composes them.
// ===========================================================================

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

// value_to_string : compact rendering of a concrete VALUE (result of a default
// or a reduction) for the tests. Handles scopes recursively: a scope is rendered
// {p0, p1, …} with its productions, {name->val, …} with its bindings.
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
		strings.write_string(b, "??")
	case Scope_Type:
		strings.write_byte(b, '{')
		first := true
		for i := 0; i < len(v.kind); i += 1 {
			if !first do strings.write_string(b, ", ")
			first = false
			// Prefer the field's cached concrete fold over its raw value: a computed
			// field (`y -> x+10`) keeps `x + 10` in values[i] but its materialized
			// result (15) in type_folds[i]. Mirrors the default-suite runner.
			fv := v.values[i]
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
		// The default of a carve is the default of its resulting scope: fold the
		// substitution, then render the substituted scope like any other.
		sub := fold_carve(t)
		if sub == nil {
			strings.write_string(b, type_to_string(t))
			return
		}
		st := new(Type)
		st^ = sub^
		write_value(b, st)
	case Cast_Type:
		// A cast's value is its folded result (the reinterpreted bits laid into
		// the target). If the fold resolved, render that; otherwise show it raw.
		if v.type_fold != nil {
			write_value(b, v.type_fold)
		} else {
			strings.write_string(b, type_to_string(t))
		}
	case:
		strings.write_string(b, type_to_string(t))
	}
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
		fmt.print(" :: ")
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
	case Float_Type:
		print_float_intervals_inline(v.float_intervals, v.kind)
		return
	}
	fmt.print("[?]")
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
