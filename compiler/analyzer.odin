package compiler

import "base:runtime"
import "core:fmt"
import "core:strconv"
import "core:strings"

// The analyzer turns the parser's flat AST into a tree of `Type` — the single
// union every form in Syntact resolves to. Syntact has no type system: a `Type`
// is the static *shape* of a value or a constraint, and the analyzer's job is to
// prove, for every binding `c : … -> v`, that the value v falls inside the set
// the constraint c denotes (`fold_value_type(v) ⊆ fold_constraint(c)`). The
// proof itself lives in the domain files (integer/float/string/bool) and is
// dispatched from type.odin; this file only builds the tree and asks.
//
// Layout: an arena of `^Type` nodes (each its own `new(Type)`), with `Scope_Type`
// as the recursive backbone — a scope is parallel `[dynamic]` arrays indexed by
// binding ordinal. References never copy a value; they carry (scope, index) back
// to the definition and are chased lazily by `follow()`.

// --- shared interval types (the domain payloads carried inside a Type) ---

Integer_Interval :: struct {
	lo: Maybe(i128), // nil = -∞
	hi: Maybe(i128), // nil = +∞
}

Float_Interval :: struct {
	lo: Maybe(f64), // nil = -∞
	hi: Maybe(f64), // nil = +∞
}

// A string interval unifies char and string. The semantics of the range
// depend on the quotation carried by the bound:
//   .simple   ('…') + content 0/1 char → ordinal (codepoints lo..hi)
//   .simple   ('abc')                  → string mode
//   .double   ("…")                    → positional: lo = prefix, hi = suffix
//   .backtick (`…`)                    → raw positional (no escaping)
// nil bound = open (empty prefix/suffix, or ±∞ ordinal).
//
// `count` carries the repetition (`*`). Default {1..1}. In ordinal mode it counts
// the number of independent chars in [lo,hi] ('a'..'z'*3 ≡ [a-z]{3}); in
// concrete mode it counts the repetitions of the string ("ab"*3 ≡ "ababab"). It reuses
// all of Integer_Type's arithmetic (multiplication, union, intersection).
String_Interval :: struct {
	lo:        Maybe(string),
	hi:        Maybe(string),
	quotation: String_Quotation,
	count:     Integer_Type,
}

FloatKind :: enum {
	none,
	f32,
	f64,
}

Analyzer_Error_Type :: enum {
	Undefined_Identifier,
	Invalid_Binding_Name,
	Invalid_Carve,
	Invalid_Property_Access,
	Constraint_Mismatch,
	Invalid_Constraint,
	Invalid_Constraint_Name,
	Invalid_Constraint_Value,
	Circular_Reference,
	Invalid_Event_Pull,
	Invalid_Binding_Value,
	Invalid_Expand,
	Invalid_Execute,
	Invalid_operator,
	Invalid_Range,
	Infinite_Recursion,
	Default,
}

Analyzer_Error :: struct {
	type:     Analyzer_Error_Type,
	message:  string,
	position: Position,
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

// Arithmetic `left <op> right` (`+`, `-`, `*`, …). Kept symbolic until folded;
// `type_fold` caches the resulting envelope once fold_compose() resolves it.
Compose_Type :: struct {
	left:      ^Type,
	right:     ^Type,
	operator:  Operator_Kind,
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

// String/char domain leaf — a set of String_Intervals (see above for how the
// quotation drives ordinal vs positional semantics). See string.odin.
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
}

// Per-file analysis state. `scope` is the root scope being built; errors and
// warnings accumulate as `walk()` recurses. Reachable from deep fold helpers via
// context.user_ptr (see current_analyzer) so they can report without threading it.
Analyzer :: struct {
	ast:      ^Ast,
	scope:    ^Scope_Type,
	errors:   [dynamic]Analyzer_Error,
	warnings: [dynamic]Analyzer_Error,
}

// --- analyzer core ---

// analyze is the entry point: it walks the root scope's children into the root
// Scope_Type, leaving the result and any diagnostics in `cache`. A bare child
// (not a binding/constraint) is treated as an anonymous Pointing_Push so it still
// gets recorded and constraint-checked. Returns true iff no errors were emitted.
analyze :: proc(cache: ^Cache, ast: ^Ast) -> bool {
	a := Analyzer {
		ast      = ast,
		scope    = new(Scope_Type),
		errors   = make([dynamic]Analyzer_Error, 0),
		warnings = make([dynamic]Analyzer_Error, 0),
	}

	// Expose the analyzer through the context so deep fold helpers can emit
	// precise, source-anchored diagnostics without threading ^Analyzer through
	// every signature. Restored on exit (analyze can be called per-file).
	prev_user_ptr := context.user_ptr
	context.user_ptr = &a
	defer context.user_ptr = prev_user_ptr

	root := ast_root(ast)
	root_data := ast.node_data[root]
	r := root_data.scope
	children := ast.extra[r.start:][:r.len]
	for child in children {
		child_kind := ast.node_kinds[child]
		#partial switch child_kind {
		case .Pointing,
		     .PointingPull,
		     .EventPush,
		     .EventPull,
		     .ResonancePush,
		     .ResonancePull,
		     .ReactivePush,
		     .ReactivePull,
		     .Product,
		     .Expand,
		     .Constraint:
			walk(&a, a.scope, child)
		case:
			value := walk(&a, a.scope, child)
			scope_append(&a, a.scope, "", nil, .Pointing_Push, value)
			typecheck(&a, a.scope, "", nil, .Pointing_Push, value, child)
		}
	}

	cache.scope = a.scope
	cache.analyze_errors = a.errors
	cache.analyze_warnings = a.warnings

	if resolver.options.print_errors && len(a.errors) > 0 {
		debug_sem_errors(&a)
	}

	return len(a.errors) == 0
}

span_str :: proc(ast: ^Ast, s: Span) -> string {
	return ast.source[s.start:s.end]
}

node_pos :: proc(a: ^Analyzer, idx: Node_Index) -> Position {
	return span_to_position(a.ast, a.ast.node_spans[idx].start)
}

binding_kind_from_node :: proc(kind: Node_Kind) -> Binding_Kind {
	#partial switch kind {
	case .Pointing:
		return .Pointing_Push
	case .PointingPull:
		return .Pointing_Pull
	case .EventPush:
		return .Event_Push
	case .EventPull:
		return .Event_Pull
	case .ResonancePush:
		return .Resonance_Push
	case .ResonancePull:
		return .Resonance_Pull
	case .ReactivePush:
		return .Reactive_Push
	case .ReactivePull:
		return .Reactive_Pull
	case:
		return .Pointing_Push
	}
}

// scope_append records one binding by pushing onto the four parallel columns in
// lockstep, so every column stays indexed by the same ordinal. The two *_folds
// columns are filled separately by typecheck() (or, for the bare-constraint
// forms, inline) — never here.
scope_append :: proc(
	a: ^Analyzer,
	scope: ^Scope_Type,
	name: string,
	constraint: ^Type,
	bk: Binding_Kind,
	value: ^Type,
) {
	append(&scope.names, name)
	append(&scope.types, constraint)
	append(&scope.kind, bk)
	append(&scope.values, value)

}

// typecheck performs the constraint proof for one binding and caches both folds
// onto the scope. It is the only place a Constraint_Mismatch is raised in the
// normal binding path (carves do their own inline). The fc/ft split below is the
// whole game: the constraint denotes a SET, the value denotes its own TYPE, and
// we must show the latter is a subset of the former.
typecheck :: proc(
	a: ^Analyzer,
	scope: ^Scope_Type,
	name: string,
	constraint: ^Type,
	bk: Binding_Kind,
	value: ^Type,
	node: Node_Index,
) {
	// fc: the VALUE of the imposed constraint (left side) — the set the value
	//     must fall into. Must resolve statically.
	// ft: the TYPE of the value (right side, a typeof) — a concrete singleton
	//     stays itself, a set becomes its producer scope {-> set}.
	fc := fold_constraint(constraint)
	ft := fold_value_type(value)

	append(&scope.constraint_folds, fc)
	append(&scope.type_folds, ft)

	// No imposed constraint → nothing to prove.
	if fc == nil do return

	display := name != "" ? fmt.tprintf("'%s'", name) : "the production"
	if ft == nil {
		sem_error(
			a,
			fmt.tprintf(
				"%s is colored by %s but its value cannot be resolved",
				display,
				describe_type(fc),
			),
			.Constraint_Mismatch,
			node_pos(a, node),
		)
	} else if !satisfy_root(fc, ft) {
		sem_error(
			a,
			fmt.tprintf(
				"constraint mismatch: %s does not satisfy %s on %s",
				describe_type(ft),
				describe_type(fc),
				display,
			),
			.Constraint_Mismatch,
			node_pos(a, node),
		)
	}
}

// scope_resolve maps a name (and optional ordinal) to its defining (scope, index),
// walking up the `parent` chain on miss. Same-name bindings are a feature, so the
// disambiguation rule matters:
//   * ordinal >= 0  — pick the ordinal-th binding of that name (`a#0`, `a#1`, …);
//     an empty name with an ordinal indexes positionally into the scope.
//   * ordinal < 0   — pick by position: `last` chooses the most recent occurrence
//     (property access `.`), otherwise the first (carve `{}` default target).
// Returns (nil, -1) when the name is not in scope nor any ancestor.
scope_resolve :: proc(
	scope: ^Scope_Type,
	name: string,
	ordinal: i16,
	last: bool,
) -> (
	^Scope_Type,
	int,
) {
	if ordinal >= 0 {
		if name == "" {
			if int(ordinal) < len(scope.values) {
				return scope, int(ordinal)
			}
			return nil, -1
		}
		count := 0
		for i := 0; i < len(scope.names); i += 1 {
			if scope.names[i] == name {
				if count == int(ordinal) {
					return scope, i
				}
				count += 1
			}
		}
		return nil, -1
	}

	if last {
		for i := len(scope.names) - 1; i >= 0; i -= 1 {
			if scope.names[i] == name {
				return scope, i
			}
		}
	} else {
		for i := 0; i < len(scope.names); i += 1 {
			if scope.names[i] == name {
				return scope, i
			}
		}
	}

	if scope.parent != nil {
		return scope_resolve(scope.parent, name, ordinal, last)
	}
	return nil, -1
}

// follow chases indirections (Mention/Reference) to the value they ultimately
// bind, transitively (a reference to a reference resolves through). A non-pointer
// Type, or a dangling/unresolved indirection, is returned unchanged — callers can
// switch on the result without special-casing references.
follow :: proc(t: ^Type) -> ^Type {
	if t == nil do return nil
	#partial switch v in t^ {
	case Mention_Type:
		if v.match_scope != nil && v.match_index >= 0 {
			return follow(v.match_scope.values[v.match_index])
		}
	case Reference_Type:
		if v.reference != nil && v.reference.match_scope != nil && v.reference.match_index >= 0 {
			return follow(v.reference.match_scope.values[v.reference.match_index])
		}
	}
	return t
}

// walk is the AST → Type recursion: given a node, build and return its `^Type`,
// appending bindings to `current_scope` along the way. Binding/constraint nodes
// have side effects (they register into the scope) and return the bound value;
// expression nodes are pure and just return their shape. INVALID_NODE → None_Type.
// Anything not yet modeled (externals, patterns, branches) folds to Unknown_Type.
walk :: proc(a: ^Analyzer, current_scope: ^Scope_Type, idx: Node_Index) -> ^Type {
	if idx == INVALID_NODE {
		result := new(Type)
		result^ = None_Type{}
		return result
	}
	ast := a.ast
	kind := ast.node_kinds[idx]
	data := ast.node_data[idx]

	#partial switch kind {

	case .ScopeNode:
		scope := new(Scope_Type)
		scope.parent = current_scope
		r := data.scope
		children := ast.extra[r.start:][:r.len]
		for child in children {
			child_kind := ast.node_kinds[child]
			#partial switch child_kind {
			case .Pointing,
			     .PointingPull,
			     .EventPush,
			     .EventPull,
			     .ResonancePush,
			     .ResonancePull,
			     .ReactivePush,
			     .ReactivePull,
			     .Product,
			     .Expand,
			     .Constraint:
				walk(a, scope, child)
			case:
				value := walk(a, scope, child)
				scope_append(a, scope, "", nil, .Pointing_Push, value)
				typecheck(a, scope, "", nil, .Pointing_Push, value, child)
			}
		}
		result := new(Type)
		result^ = scope^
		return result

	// A directional binding `lhs <op> rhs`. The left side is either a bare name,
	// or a `constraint : name` form (so we extract both the imposed constraint and
	// the bound name). The right side is the value; when it is a scope literal we
	// build the child Scope_Type in place and register the binding *before*
	// walking the body, so the body can refer back to the binding being defined.
	case .Pointing,
	     .PointingPull,
	     .EventPush,
	     .EventPull,
	     .ResonancePush,
	     .ResonancePull,
	     .ReactivePush,
	     .ReactivePull:
		left_idx := data.binary.left
		right_idx := data.binary.right
		bk := binding_kind_from_node(kind)

		name := ""
		constraint: ^Type = nil
		left_kind := ast.node_kinds[left_idx]

		if left_kind == .Constraint {
			cdata := ast.node_data[left_idx]
			constraint_idx := cdata.binary.left
			name_idx := cdata.binary.right
			constraint = walk(a, current_scope, constraint_idx)
			if name_idx != INVALID_NODE {
				nk := ast.node_kinds[name_idx]
				if nk == .Identifier {
					name = span_str(ast, ast.node_data[name_idx].identifier.name)
				} else if nk == .Carve {
					// constraint:name{carves} — the carve source is the name
					csrc := ast.node_data[name_idx].carve.source
					if ast.node_kinds[csrc] == .Identifier {
						name = span_str(ast, ast.node_data[csrc].identifier.name)
					}
				}
			}
		} else if left_kind == .Identifier {
			name = span_str(ast, ast.node_data[left_idx].identifier.name)
		} else {
			sem_error(a, "invalid binding name", .Invalid_Binding_Name, node_pos(a, left_idx))
		}

		right_kind := ast.node_kinds[right_idx]
		if right_kind == .ScopeNode {
			result := new(Type)
			result^ = Scope_Type {
				parent = current_scope,
			}
			scope := &result.(Scope_Type)
			scope_append(a, current_scope, name, constraint, bk, result)

			rdata := ast.node_data[right_idx]
			r := rdata.scope
			scope_children := ast.extra[r.start:][:r.len]
			for child in scope_children {
				child_kind := ast.node_kinds[child]
				#partial switch child_kind {
				case .Pointing,
				     .PointingPull,
				     .EventPush,
				     .EventPull,
				     .ResonancePush,
				     .ResonancePull,
				     .ReactivePush,
				     .ReactivePull,
				     .Product,
				     .Expand,
				     .Constraint:
					walk(a, scope, child)
				case:
					val := walk(a, scope, child)
					scope_append(a, scope, "", nil, .Pointing_Push, val)
					typecheck(a, scope, "", nil, .Pointing_Push, val, child)
				}
			}
			typecheck(a, current_scope, name, constraint, bk, result, idx)
			return result
		}
		value := walk(a, current_scope, right_idx)
		scope_append(a, current_scope, name, constraint, bk, value)
		typecheck(a, current_scope, name, constraint, bk, value, idx)
		return value

	case .Product:
		value := walk(a, current_scope, data.unary.operand)
		scope_append(a, current_scope, "", nil, .Product, value)
		typecheck(a, current_scope, "", nil, .Product, value, idx)
		return value

	// `+{…}` extension. A constrained-but-valueless expand (`+{u8:}`) materializes
	// the constraint's default as the value and caches the folds directly, since
	// there is no value expression to run typecheck() against.
	case .Expand:
		operand_idx := data.unary.operand
		constraint: ^Type = nil
		if ast.node_kinds[operand_idx] == .Constraint {
			cdata := ast.node_data[operand_idx]
			constraint = walk(a, current_scope, cdata.binary.left)
			value: ^Type = nil
			if cdata.binary.right != INVALID_NODE {
				value = walk(a, current_scope, cdata.binary.right)
				scope_append(a, current_scope, "", constraint, .Expand, value)
				typecheck(a, current_scope, "", constraint, .Expand, value, idx)
			} else {
				fc := fold_constraint(constraint)
				value := default_value(fc)
				scope_append(a, current_scope, "", constraint, .Expand, value)
				append(&current_scope.constraint_folds, fc)
				append(&current_scope.type_folds, value)
			}
			return value
		}
		value := walk(a, current_scope, operand_idx)
		scope_append(a, current_scope, "", nil, .Expand, value)
		typecheck(a, current_scope, "", nil, .Expand, value, idx)
		return value

	case .CompileTime:
		return walk(a, current_scope, data.unary.operand)

	// A bare constraint `c : name` with no `-> value`. It still introduces a
	// binding: the value is the constraint's default element, and the folds are
	// cached inline (there is nothing to prove — the value is by construction the
	// constraint's own default, hence trivially inside it).
	case .Constraint:
		constraint := walk(a, current_scope, data.binary.left)
		name := ""
		if data.binary.right != INVALID_NODE {
			right_kind := ast.node_kinds[data.binary.right]
			if right_kind == .Identifier {
				name = span_str(ast, ast.node_data[data.binary.right].identifier.name)
			} else if right_kind == .Carve {
				csrc := ast.node_data[data.binary.right].carve.source
				if ast.node_kinds[csrc] == .Identifier {
					name = span_str(ast, ast.node_data[csrc].identifier.name)
				}
			}
		}
		fc := fold_constraint(constraint)
		value := default_value(fc)
		scope_append(a, current_scope, name, constraint, .Pointing_Push, value)
		append(&current_scope.constraint_folds, fc)
		append(&current_scope.type_folds, value)

		return value

	// `target.prop` — resolve `prop` against the scope `target` denotes. The loop
	// peels through Carve_Types to their source, so a property of a carved scope
	// resolves against the underlying scope's fields. Property access takes the
	// *last* occurrence of the name (last=true), per the same-name rule.
	case .Property:
		target := walk(a, current_scope, data.binary.left)
		right_idx := data.binary.right
		prop_name := span_str(ast, ast.node_data[right_idx].identifier.name)
		prop_ordinal := ast.node_data[right_idx].identifier.ordinal

		prop_scope: ^Scope_Type = nil
		prop_index := -1
		resolved_target := follow(target)
		prop_target := resolved_target
		for {
			#partial switch &t in prop_target^ {
			case Scope_Type:
				prop_scope, prop_index = scope_resolve(&t, prop_name, prop_ordinal, true)
			case Carve_Type:
				if t.source != nil {
					prop_target = follow(t.source)
					continue
				}
			}
			break
		}

		if prop_scope == nil {
			sem_error(
				a,
				fmt.tprintf("property '%s' does not exist", prop_name),
				.Invalid_Property_Access,
				node_pos(a, right_idx),
			)
			result := new(Type)
			result^ = Invalid_Type{}
			return result
		}

		ref := new(Reference)
		ref^ = Reference {
			prop_name,
			prop_ordinal >= 0 ? Maybe(u64)(u64(prop_ordinal)) : nil,
			prop_scope,
			prop_index,
		}
		result := new(Type)
		result^ = Reference_Type{target, ref}
		return result

	case .Enforce:
		left := walk(a, current_scope, data.binary.left)
		right := walk(a, current_scope, data.binary.right)
		result := new(Type)
		result^ = Or_Type{left, right}
		return result

	case .Range:
		// An absent bound (prefix `..hi` / postfix `lo..`) stays nil — it means
		// "no bound", not the value `none`. walk(INVALID_NODE) would yield a
		// None_Type, which fold_range and the printer would mistake for a real bound.
		left: ^Type = nil
		if data.binary.left != INVALID_NODE {
			left = walk(a, current_scope, data.binary.left)
		}
		right: ^Type = nil
		if data.binary.right != INVALID_NODE {
			right = walk(a, current_scope, data.binary.right)
		}
		result := new(Type)
		result^ = Range_Type{left, right}
		fold_range(a, result, idx)
		return result

	// An operator node. The set-algebra operators (`&`, `|`, ~) become symbolic
	// And/Or/Negate nodes that the constraint folder reduces later; every other
	// operator is arithmetic and is folded eagerly into a Compose_Type's envelope
	// here so a constraint mismatch surfaces at the operation, not downstream.
	case .Operator:
		left: ^Type = nil
		if data.operator.left != INVALID_NODE {
			left = walk(a, current_scope, data.operator.left)
		}
		right := walk(a, current_scope, data.operator.right)
		result := new(Type)
		#partial switch data.operator.kind {
		case .And:
			result^ = And_Type{left, right}
		case .Or:
			result^ = Or_Type{left, right}
		case .Not:
			result^ = Negate_Type{right}
		case:
			result^ = Compose_Type{left, right, data.operator.kind, nil}
			fold_compose(a, result, idx)
		}
		return result

	// `source{ … }` — derive a new scope from `source`. We first resolve `source`
	// down to the underlying Scope_Type (peeling carves-of-carves) so each
	// override can be located in it. Overrides come in two forms, handled in the
	// loop: named (`name -> v`, resolved by name, FIRST occurrence) and positional
	// (a bare value, matched to the next field by index). Each override is
	// constraint-checked against the field it replaces.
	case .Carve:
		source := walk(a, current_scope, data.carve.source)
		r := data.carve.children
		carve_children := ast.extra[r.start:][:r.len]

		src_scope: ^Scope_Type = nil
		resolved_source := follow(source)
		src_target := resolved_source
		for {
			#partial switch &s in src_target^ {
			case Scope_Type:
				src_scope = &s
			case Carve_Type:
				if s.source != nil {
					src_target = follow(s.source)
					continue
				}
			}
			break
		}

		refs := make([dynamic]Reference)
		vals := make([dynamic]^Type)

		positional_idx := 0
		for child in carve_children {
			child_kind := ast.node_kinds[child]
			child_data := ast.node_data[child]

			if child_kind == .Pointing || child_kind == .PointingPull {
				name_idx := child_data.binary.left
				val_idx := child_data.binary.right
				cname := ""
				cordinal: i16 = -1

				if ast.node_kinds[name_idx] == .Identifier {
					cname = span_str(ast, ast.node_data[name_idx].identifier.name)
					cordinal = ast.node_data[name_idx].identifier.ordinal
				}

				carve_scope: ^Scope_Type = nil
				carve_index := -1
				if src_scope != nil {
					carve_scope, carve_index = scope_resolve(src_scope, cname, cordinal, false)
				}
				if carve_scope == nil {
					sem_error(
						a,
						fmt.tprintf("'%s' does not exist in the carved scope", cname),
						.Invalid_Carve,
						node_pos(a, name_idx),
					)
				}

				val := walk(a, current_scope, val_idx)
				if carve_scope != nil && carve_index >= 0 {
					cf := carve_scope.constraint_folds[carve_index]
					if cf != nil {
						vf := fold_value_type(val)
						if vf != nil && !satisfy_root(cf, vf) {
							sem_error(
								a,
								fmt.tprintf(
									"constraint mismatch in carve '%s': %s does not satisfy %s",
									cname,
									describe_type(vf),
									describe_type(cf),
								),
								.Constraint_Mismatch,
								node_pos(a, val_idx),
							)
						}
					}
				}
				append(
					&refs,
					Reference {
						cname,
						cordinal >= 0 ? Maybe(u64)(u64(cordinal)) : nil,
						carve_scope,
						carve_index,
					},
				)
				append(&vals, val)
			} else {
				carve_scope: ^Scope_Type = nil
				carve_index := -1
				cname := ""
				if src_scope != nil && positional_idx < len(src_scope.names) {
					cname = src_scope.names[positional_idx]
					carve_scope = src_scope
					carve_index = positional_idx
				}
				if carve_scope == nil {
					sem_error(
						a,
						"positional carve out of range: the scope has fewer fields",
						.Invalid_Carve,
						node_pos(a, child),
					)
				}

				val := walk(a, current_scope, child)
				if carve_scope != nil && carve_index >= 0 {
					cf := carve_scope.constraint_folds[carve_index]
					if cf != nil {
						vf := fold_value_type(val)
						if vf != nil && !satisfy_root(cf, vf) {
							sem_error(
								a,
								fmt.tprintf(
									"constraint mismatch in positional carve: %s does not satisfy %s",
									describe_type(vf),
									describe_type(cf),
								),
								.Constraint_Mismatch,
								node_pos(a, child),
							)
						}
					}
				}
				append(&refs, Reference{nil, nil, carve_scope, carve_index})
				append(&vals, val)
				positional_idx += 1
			}
		}

		result := new(Type)
		result^ = Carve_Type{source, refs, vals}
		return result

	// `target ? { cond -> branch, … }` — pattern match. We still walk the target
	// and every branch so their bindings and constraints are checked, but the
	// match result itself is not statically resolved yet, so it folds to Unknown.
	case .Pattern:
		target := walk(a, current_scope, data.pattern.target)
		_ = target
		r := data.pattern.branches
		branches := ast.extra[r.start:][:r.len]
		for i := 0; i < len(branches); i += 2 {
			walk(a, current_scope, branches[i])
			if i + 1 < len(branches) {
				walk(a, current_scope, branches[i + 1])
			}
		}
		result := new(Type)
		result^ = Unknown_Type{}
		return result

	// `target!` — collapse. Recorded as an Execute_Type; the actual reduction
	// through the target's Product happens later in reduce.odin.
	case .Execute:
		target := walk(a, current_scope, data.execute.target)
		result := new(Type)
		result^ = Execute_Type{target}
		return result

	// `@name` — an external. Opaque to static analysis, so Unknown_Type.
	case .External:
		result := new(Type)
		result^ = Unknown_Type{}
		return result

	case .Literal:
		return walk_literal(a, idx)

	case .Identifier:
		return walk_identifier(a, current_scope, idx)

	case .Branch:
		result := new(Type)
		result^ = Unknown_Type{}
		return result

	case .Unknown:
		result := new(Type)
		result^ = Unknown_Type{}
		return result
	}

	result := new(Type)
	result^ = Unknown_Type{}
	return result
}

// walk_literal turns a literal token into its degenerate single-element domain
// set: `5` becomes the integer interval 5..5, `"hi"` the string singleton, etc.
// A concrete literal is its own type — the value/set split (see type.odin) treats
// a singleton as a value. An unparseable literal yields Invalid_Type rather than
// crashing; the parse error is already reported upstream.
walk_literal :: proc(a: ^Analyzer, idx: Node_Index) -> ^Type {
	ast := a.ast
	data := ast.node_data[idx]
	span := ast.node_spans[idx]
	text := ast.source[span.start:span.end]

	result := new(Type)

	switch data.literal.kind {
	case .Integer:
		val, ok := strconv.parse_u64_of_base(text, 10)
		if ok {
			result^ = make_int_const(i128(val))
		} else {
			result^ = Invalid_Type{}
		}
	case .Hexadecimal:
		raw := len(text) > 2 ? text[2:] : text
		val, ok := strconv.parse_u64_of_base(raw, 16)
		if ok {
			result^ = make_int_const(i128(val))
		} else {
			result^ = Invalid_Type{}
		}
	case .Binary:
		raw := len(text) > 2 ? text[2:] : text
		val, ok := strconv.parse_u64_of_base(raw, 2)
		if ok {
			result^ = make_int_const(i128(val))
		} else {
			result^ = Invalid_Type{}
		}
	case .Float:
		val, ok := strconv.parse_f64(text)
		if ok {
			result^ = make_float_const(val)
		} else {
			result^ = Invalid_Type{}
		}
	case .String:
		quotation := data.literal.quotation
		decoded := decode_string_literal(text, quotation)
		result^ = make_string_const(decoded, quotation)
	case .Bool:
		result^ = make_bool_const(text == "true")
	}

	return result
}


// The built-in constraints, resolved by name when no binding shadows them. They
// are nothing special — just pre-built domain sets: `u8` is the interval 0..255,
// `Int` the unbounded integer line, `Bool` the open {true,false}, and so on. A
// user binding of the same name wins (checked first in walk_identifier), so these
// are not keywords — only defaults.
builtins: map[string]Type

@(init)
init_builtins :: proc "contextless" () {
	context = runtime.default_context()
	builtins["u8"] = make_int_range(0, 255)
	builtins["i8"] = make_int_range(-128, 127)
	builtins["u16"] = make_int_range(0, 65535)
	builtins["i16"] = make_int_range(-32768, 32767)
	builtins["u32"] = make_int_range(0, 4294967295)
	builtins["i32"] = make_int_range(-2147483648, 2147483647)
	builtins["u64"] = make_int_range(0, 18446744073709551615)
	builtins["i64"] = make_int_range(-9223372036854775808, 9223372036854775807)
	builtins["f32"] = make_float_range(nil, nil, .f32)
	builtins["f64"] = make_float_range(nil, nil, .f64)
	builtins["int"] = make_int_range(nil, nil)
	builtins["float"] = make_float_range(nil, nil, .none)
	builtins["string"] = make_string_any()
	builtins["bool"] = make_bool_any()
	builtins["none"] = None_Type{}
}

// walk_identifier resolves a name reference. A scope binding wins over a builtin;
// an ordinal'd reference (`a#1`) produces a Reference_Type (it must carry the
// ordinal), a plain name produces the lighter Mention_Type. A name that is
// neither bound nor builtin is an Undefined_Identifier and folds to Invalid_Type.
walk_identifier :: proc(a: ^Analyzer, scope: ^Scope_Type, idx: Node_Index) -> ^Type {
	ast := a.ast
	data := ast.node_data[idx]
	name := span_str(ast, data.identifier.name)
	ordinal := data.identifier.ordinal

	res_scope, res_index := scope_resolve(scope, name, ordinal, true)
	if res_scope != nil {
		if ordinal >= 0 {
			ref := new(Reference)
			ref^ = Reference {
				name != "" ? Maybe(string)(name) : nil,
				Maybe(u64)(u64(ordinal)),
				res_scope,
				res_index,
			}
			result := new(Type)
			result^ = Reference_Type{nil, ref}
			return result
		}
		result := new(Type)
		result^ = Mention_Type{name, res_scope, res_index}
		return result
	}

	if ordinal < 0 {
		if builtin, ok := builtins[name]; ok {
			result := new(Type)
			result^ = builtin
			return result
		}
	}

	sem_error(a, fmt.tprintf("'%s' is not defined", name), .Undefined_Identifier, node_pos(a, idx))
	result := new(Type)
	result^ = Invalid_Type{}
	return result
}


// --- error reporting ---

// current_analyzer fetches the in-flight analyzer from the context (set at the
// top of analyze()). Returns nil outside an analysis pass.
current_analyzer :: #force_inline proc() -> ^Analyzer {
	return cast(^Analyzer)context.user_ptr
}

sem_error :: proc(
	s: ^Analyzer,
	message: string,
	error_type: Analyzer_Error_Type,
	position: Position,
) {
	error := Analyzer_Error {
		type     = error_type,
		message  = message,
		position = position,
	}
	append(&s.errors, error)
}

sem_warning :: proc(
	s: ^Analyzer,
	message: string,
	error_type: Analyzer_Error_Type,
	position: Position,
) {
	warning := Analyzer_Error {
		type     = error_type,
		message  = message,
		position = position,
	}
	append(&s.warnings, warning)
}

// --- debug output ---

debug_sem_errors :: proc(s: ^Analyzer) {
	fmt.eprintln("=== SEMANTIC ERRORS ===")
	for error, i in s.errors {
		fmt.eprintf(
			"  [%d] %v at line %d, col %d: %s\n",
			i,
			error.type,
			error.position.line,
			error.position.column,
			error.message,
		)
	}
	fmt.eprintln()
}
