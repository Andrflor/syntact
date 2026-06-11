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
	// captures: a second, INVISIBLE name per binding (the `(e)` capture span).
	// Parallel to the columns above: "" when a field has no capture. Unlike
	// `names`, captures are NOT consulted by property access `.` or carving `{}`
	// (those scan `names` only) — a capture is referenceable by mention within its
	// own scope (and, for a pattern match, its branch production), nothing else.
	captures:         [dynamic]string,
	// True while the analyzer is still walking this scope's body. A fold that
	// touches a walking scope cannot be trusted (bindings are missing) — it
	// signals fold_pending and the dependent typecheck is deferred until the
	// scope closes. Cleared at the end of the walk; always false on clones.
	walking:          bool,
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

// A by-name mention of something that mentions ITSELF: the open scope referring
// to its own binding (`fib` inside fib, `Array` inside Array), or a field that
// names itself from within an inner scope (`a -> { -> {0 a} }` — the inner `a`).
// It is structurally a Mention_Type — `match_scope.values[match_index]` is the
// self binding — but kept a distinct node so folds defer through it, the satisfy
// layer detects the inductive step, and it survives carve cloning unchanged
// (repoint never rewrites it). The scope pointer is valid even while the scope is
// still walking; CONSUMERS check `walking`. To take a genuine (non-self) handle
// on a binding, use Reference_Type instead.
Recursive_Mention_Type :: struct {
	name:        string,
	match_scope: ^Scope_Type, // the scope holding the self binding (valid while walking)
	match_index: int, // field index in match_scope; -1 until resolved
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
// `cover_fold` is the branch's FIRING SET, folded once at analysis (constraint
// fold of a typecheck match, value fold of a `=v` match) and reused by
// reduce_pattern — reduce never calls the fold layer. nil when the match did
// not fold statically (the pattern then stays symbolic at reduce).
Pattern_Branch :: struct {
	value_match: bool,
	match:       ^Type,
	product:     ^Type,
	cover_fold:  ^Type,
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
	Recursive_Mention_Type,
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
		// A surviving bare fixed point: `??N` (stable index).
		fmt.sbprintf(b, "??%d", fixedpoint_id(t))
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
		// A cast's value is its folded result (the reinterpreted bits laid into the
		// target) when the source was concrete. A bare `??::T` atom is a SURVIVING
		// fixed point: render as `??N`. A width WRAPPER over a composite source
		// (`(a+b)::u8`) renders the inner expression in parens, then `::target`.
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
		// A SYMBOLIC reduced expression (a fixed point survived): the reducer emits a
		// factored Compose tree over the surviving `??`. Render it infix WITH
		// PARENTHESES per operator precedence, so `(x+1)*y` is not mis-read as
		// `x + 1 * y`.
		write_compose_value(b, v)
	case Mention_Type, Reference_Type:
		// A surviving fixed point renders as `??N` — a stable index distinguishing
		// the distinct unknowns the linker will resolve (`??0`, `??1`, …).
		fmt.sbprintf(b, "??%d", fixedpoint_id(t))
	case Pattern_Type:
		// A pattern whose target is a fixed point survives reduction (the runtime
		// selects the branch): render `target ? {match -> product, …}` with the
		// target's `??N` and each branch's reduced product.
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
		// A branch match like `0..127` reduced inside a surviving pattern.
		if v.left != nil do write_value(b, v.left)
		strings.write_string(b, "..")
		if v.right != nil do write_value(b, v.right)
	case:
		strings.write_string(b, type_to_string(t))
	}
}

// op_prec ranks an operator for parenthesization: higher binds tighter.
op_prec :: proc(op: Operator_Kind) -> int {
	#partial switch op {
	case .Multiply, .Divide, .Mod:
		return 3
	case .Add, .Subtract:
		return 2
	}
	return 1
}

// write_compose_value renders a reduced arithmetic node infix, parenthesizing an
// operand whose own operator binds LOOSER than this one (so a sum inside a product
// gets parens). A Cast operand (`??::u8`) prints as `??N` via write_value.
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
			// A `??::u8` fixed point: render as ??N, not value::target.
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
				// type_folds[i] is fold_value_type — for a scope-with-production it keeps
				// ONLY the production (the type the scope produces, `{0}`), dropping the
				// named members and the binding kinds. The debug dump wants the WHOLE
				// scope structure (`{n -> 0, -> 0}`: n points at 0, then a production
				// evaluating to 0 — distinct from `{n -> 0, 0}`). So when the member's
				// value resolves to a scope, render that scope's members directly (each
				// with its own type_fold); the typecheck fold layer stays unchanged.
				print_fold_inline(member_type_fold_display(v.values[i], v.type_folds[i]))
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

	case Recursive_Mention_Type:
		// Never expand through it — that is the whole point of the node.
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

// member_type_fold_display picks what the `--ir` t: column shows for a member.
// The cached type_fold (fold_value_type) is the typeof a value PRODUCES — for a
// scope with a production it collapses to just that production (`{0}`), hiding the
// named members and the binding kinds. For the dump we want the member's full
// STRUCTURE instead: when its value resolves to a scope, return that scope so
// write_fold walks its members (each rendered through its OWN type_fold, by kind:
// `n -> 0`, `-> 0`, …). A carve is materialized first. Everything else (a domain
// leaf, a reference, …) shows its cached fold unchanged. This is display-only; the
// typecheck fold layer is untouched.
member_type_fold_display :: proc(value: ^Type, cached: ^Type) -> ^Type {
	if value != nil {
		#partial switch v in value^ {
		case Scope_Type:
			if !v.walking do return value
		case Carve_Type:
			if sub := fold_carve(value); sub != nil {
				st := new(Type)
				st^ = sub^
				return st
			}
		}
	}
	return cached
}

// print_fold_inline renders a folded ^Type (as stored in type_folds /
// constraint_folds) for the --ir dump. Domain dispatch.
print_fold_inline :: proc(t: ^Type) {
	fmt.print(fold_to_string(t))
}

// fold_to_string renders ANY ^Type compactly, on one line, for the `--ir` t:/c:
// columns. Unlike the old print_fold_inline (which printed `[?]` for everything
// but integers/floats), this covers every variant so the dump shows the real
// structure — scopes, carves, pulls, patterns, casts, references, … Used only for
// debugging output, so it favors readability over the exact source syntax.
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
		// integer_to_string already renders a singleton as `6` and a set as `u8` /
		// `0..255` — no brackets, so a default value shows as its concrete value.
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
			// Each member is rendered by its BINDING KIND, so the structure is faithful:
			//   * a PRODUCTION (`-> X`) shows its arrow even though it has no name —
			//     `{n -> 0, -> 0}` (n points at 0, THEN a production evaluating to 0)
			//     must not collapse to `{n -> 0, 0}` (a nameless field 0). The arrow is
			//     the whole point.
			//   * a NAMED binding renders `name op value`.
			//   * a bare anonymous child (no name, not a production) renders as its value.
			// Prefer the member's cached type_fold over its raw value: a computed field
			// shows its folded result, not the expression.
			fv := v.values[i]
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
			write_fold(b, v.values[i])
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

// write_binding_op renders the directional operator for a binding kind, used by
// the compact fold dump.
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
