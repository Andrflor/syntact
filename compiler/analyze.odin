package compiler

import "base:runtime"
import "core:fmt"
import "core:strconv"

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
//
// The IR data model this file builds — `Type` and all its variants, the domain
// interval payloads, `Binding_Kind` — lives in ir.odin. This file holds the
// analyzer state, the diagnostics (`Analyzer_Error*`), and the AST→IR logic.

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
	Invalid_Cast,
	Infinite_Recursion,
	// A constraint that cannot be resolved at compile time because it depends on
	// an unknown value (`??`), directly or through any composition. A constraint
	// must denote a statically-known SET; `u8` is fine (the set 0..255), but a
	// typed unknown `??::u8` is one indeterminate element, so `??::u8:a -> 10`
	// cannot be proven. Distinct from Constraint_Mismatch (the value fails a
	// known constraint) — here the constraint itself is not solvable.
	Insoluble_Constraint,
	// A pattern (`target ? { … }`) whose branches do not cover the whole target:
	// the union of the branch matches misses some target values and there is no
	// empty-arrow (`->`) default branch. Without a covering branch a target value
	// could fall through unmatched, so the pattern is rejected at compile time.
	Non_Exhaustive_Pattern,
	Default,
}

Analyzer_Error :: struct {
	type:     Analyzer_Error_Type,
	message:  string,
	// `span` is the source byte range to underline; `position` is its start
	// resolved to (line, column, offset). Both are filled at creation by sem_error
	// from the offending node's span — mirroring Parse_Error — so every consumer
	// (LSP, debug printing) reads them directly without recomputing.
	span:     Span,
	position: Position,
}


// Per-file analysis state. `scope` is the root scope being built; errors and
// warnings accumulate as `walk()` recurses. Reachable from deep fold helpers via
// context.user_ptr (see current_analyzer) so they can report without threading it.
Analyzer :: struct {
	ast:      ^Ast,
	scope:    ^Scope_Type,
	errors:   [dynamic]Analyzer_Error,
	warnings: [dynamic]Analyzer_Error,
	// While walking a carve's override values, this points at the scope being
	// carved so a source-none property (`.x`, a self-mention) resolves against
	// the carved scope's *original* fields. nil outside a carve override. Saved
	// and restored around each override walk so nested carves nest correctly.
	carved_scope: ^Scope_Type,
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

// node_span returns the source byte range of node `idx` — what sem_error now
// takes, so the error carries the range to underline (not just a point).
node_span :: proc(a: ^Analyzer, idx: Node_Index) -> Span {
	return a.ast.node_spans[idx]
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

	display := name != "" ? fmt.tprintf("'%s'", name) : "the production"

	// A constraint must denote a statically-known SET. If it depends on an unknown
	// value (`??`) anywhere — directly, through a reference, or inside any
	// composition — it cannot be solved at compile time. `u8` is fine (the set
	// 0..255); `??::u8` is one indeterminate u8 element, so `??::u8:a -> 10` is
	// insoluble. This is checked on the raw constraint tree (following references)
	// so a `??` buried under &/|/~/+/range/carve/execute/pattern is caught too.
	// Checked BEFORE the `fc == nil` bail: an insoluble constraint (e.g. a pattern
	// whose target is a bare `??`) folds to nil, but the right diagnosis is
	// Insoluble_Constraint, not a silent skip.
	if constraint != nil && constraint_depends_on_unknown(constraint) {
		sem_error(
			a,
			fmt.tprintf(
				"insoluble constraint on %s: it depends on an unknown value (??) and cannot be resolved at compile time",
				display,
			),
			.Insoluble_Constraint,
			node_span(a, node),
		)
		return
	}

	// No imposed constraint → nothing to prove.
	if fc == nil do return

	if ft == nil {
		sem_error(
			a,
			fmt.tprintf(
				"%s is colored by %s but its value cannot be resolved",
				display,
				describe_type(fc),
			),
			.Constraint_Mismatch,
			node_span(a, node),
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
			node_span(a, node),
		)
	}
}

// constraint_depends_on_unknown reports whether the constraint tree `t` relies on
// an unknown value (`??`) that is not pinned to a single concrete value, making
// the constraint insoluble at compile time. It descends through every composition
// (&/|/~, arithmetic/range, carve, execute) and follows references/mentions to
// their bound value. A bare `??` is insoluble; a `??::T` (cast of an unknown) is
// insoluble UNLESS the cast folds to a concrete singleton; everything built on top
// of an insoluble part is itself insoluble.
constraint_depends_on_unknown :: proc(t: ^Type, depth := 0) -> bool {
	if t == nil do return false
	if depth > 64 do return false // cycle guard
	switch v in t^ {
	case Unknown_Type:
		return true
	case Cast_Type:
		// `??::u8` stays one indeterminate element unless it pinned to a concrete
		// singleton (then type_fold is that value and the constraint is solvable).
		if v.type_fold != nil && fold_is_concrete_value(v.type_fold) do return false
		return constraint_depends_on_unknown(v.value, depth + 1)
	case Mention_Type:
		if v.match_scope != nil && v.match_index >= 0 {
			return constraint_depends_on_unknown(v.match_scope.values[v.match_index], depth + 1)
		}
		return false
	case Reference_Type:
		ref := v.reference
		if ref != nil && ref.match_scope != nil && ref.match_index >= 0 {
			return constraint_depends_on_unknown(ref.match_scope.values[ref.match_index], depth + 1)
		}
		return false
	case And_Type:
		return constraint_depends_on_unknown(v.left, depth + 1) ||
			constraint_depends_on_unknown(v.right, depth + 1)
	case Or_Type:
		return constraint_depends_on_unknown(v.left, depth + 1) ||
			constraint_depends_on_unknown(v.right, depth + 1)
	case Negate_Type:
		return constraint_depends_on_unknown(v.operand, depth + 1)
	case Compose_Type:
		return constraint_depends_on_unknown(v.left, depth + 1) ||
			constraint_depends_on_unknown(v.right, depth + 1)
	case Range_Type:
		return constraint_depends_on_unknown(v.left, depth + 1) ||
			constraint_depends_on_unknown(v.right, depth + 1)
	case Execute_Type:
		return constraint_depends_on_unknown(v.target, depth + 1)
	case Carve_Type:
		if constraint_depends_on_unknown(v.source, depth + 1) do return true
		for ov in v.values {
			if constraint_depends_on_unknown(ov, depth + 1) do return true
		}
		return false
	case Scope_Type:
		// A scope-shaped constraint is solvable only if every field's value is.
		for val in v.values {
			if constraint_depends_on_unknown(val, depth + 1) do return true
		}
		return false
	case Pattern_Type:
		// A pattern-shaped constraint is insoluble if its target or any branch
		// match/product depends on an unknown — the selected branch would not be
		// statically determinable.
		if constraint_depends_on_unknown(v.target, depth + 1) do return true
		for branch in v.branches {
			if constraint_depends_on_unknown(branch.match, depth + 1) do return true
			if constraint_depends_on_unknown(branch.product, depth + 1) do return true
		}
		return false
	case Integer_Type, Float_Type, String_Type, Bool_Type, None_Type, Invalid_Type:
		return false
	}
	return false
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

// self_resolve locates a field for a self-mention (`.x` / `.#0` / `.x#0`) in the
// scope being carved. Unlike scope_resolve it never walks up to the parent: `.`
// names *this* scope, so a missing field is an error, not a parent lookup. With
// no ordinal it takes the first occurrence (the carve default-target rule).
self_resolve :: proc(scope: ^Scope_Type, name: string, ordinal: i16) -> (^Scope_Type, int) {
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
	for i := 0; i < len(scope.names); i += 1 {
		if scope.names[i] == name {
			return scope, i
		}
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
// walk is the AST→IR dispatcher: it routes each Node_Kind to its walk_<kind>
// handler (mirroring how the Pratt parser dispatches on token kind). The handlers
// hold the per-kind logic; walk only owns the INVALID_NODE guard and the fallback.
walk :: proc(a: ^Analyzer, current_scope: ^Scope_Type, idx: Node_Index) -> ^Type {
	if idx == INVALID_NODE {
		result := new(Type)
		result^ = None_Type{}
		return result
	}
	kind := a.ast.node_kinds[idx]

	#partial switch kind {
	case .ScopeNode:
		return walk_scope_node(a, current_scope, idx)
	case .Pointing,
	     .PointingPull,
	     .EventPush,
	     .EventPull,
	     .ResonancePush,
	     .ResonancePull,
	     .ReactivePush,
	     .ReactivePull:
		return walk_binding(a, current_scope, idx)
	case .Product:
		return walk_product(a, current_scope, idx)
	case .Expand:
		return walk_expand(a, current_scope, idx)
	case .CompileTime:
		return walk_compile_time(a, current_scope, idx)
	case .Constraint:
		return walk_constraint(a, current_scope, idx)
	case .Property:
		return walk_property(a, current_scope, idx)
	case .Enforce:
		return walk_enforce(a, current_scope, idx)
	case .Range:
		return walk_range(a, current_scope, idx)
	case .Operator:
		return walk_operator(a, current_scope, idx)
	case .Carve:
		return walk_carve(a, current_scope, idx)
	case .Pattern:
		return walk_pattern(a, current_scope, idx)
	case .Execute:
		return walk_execute(a, current_scope, idx)
	case .External:
		return walk_external(a, current_scope, idx)
	case .Literal:
		return walk_literal(a, idx)
	case .Identifier:
		return walk_identifier(a, current_scope, idx)
	case .Branch:
		return walk_branch(a, current_scope, idx)
	case .Unknown:
		return walk_unknown(a, current_scope, idx)
	}

	result := new(Type)
	result^ = Unknown_Type{}
	return result
}

// make_unknown / make_none : the two trivial IR leaves several handlers return.
make_unknown :: #force_inline proc() -> ^Type {
	result := new(Type)
	result^ = Unknown_Type{}
	return result
}

make_none :: #force_inline proc() -> ^Type {
	result := new(Type)
	result^ = None_Type{}
	return result
}

walk_scope_node :: #force_inline proc(a: ^Analyzer, current_scope: ^Scope_Type, idx: Node_Index) -> ^Type {
	ast := a.ast
	data := ast.node_data[idx]
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
}

// A directional binding `lhs <op> rhs`. The left side is either a bare name,
// or a `constraint : name` form (so we extract both the imposed constraint and
// the bound name). The right side is the value; when it is a scope literal we
// build the child Scope_Type in place and register the binding *before*
// walking the body, so the body can refer back to the binding being defined.
walk_binding :: #force_inline proc(a: ^Analyzer, current_scope: ^Scope_Type, idx: Node_Index) -> ^Type {
	ast := a.ast
	data := ast.node_data[idx]
	kind := ast.node_kinds[idx]
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
		sem_error(a, "invalid binding name", .Invalid_Binding_Name, node_span(a, left_idx))
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
}

walk_product :: #force_inline proc(a: ^Analyzer, current_scope: ^Scope_Type, idx: Node_Index) -> ^Type {
	data := a.ast.node_data[idx]
	value := walk(a, current_scope, data.unary.operand)
	scope_append(a, current_scope, "", nil, .Product, value)
	typecheck(a, current_scope, "", nil, .Product, value, idx)
	return value
}

// `+{…}` extension. A constrained-but-valueless expand (`+{u8:}`) materializes
// the constraint's default as the value and caches the folds directly, since
// there is no value expression to run typecheck() against.
walk_expand :: #force_inline proc(a: ^Analyzer, current_scope: ^Scope_Type, idx: Node_Index) -> ^Type {
	ast := a.ast
	data := ast.node_data[idx]
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
}

walk_compile_time :: #force_inline proc(a: ^Analyzer, current_scope: ^Scope_Type, idx: Node_Index) -> ^Type {
	data := a.ast.node_data[idx]
	return walk(a, current_scope, data.unary.operand)
}

// A bare constraint `c : name` with no `-> value`. It still introduces a
// binding: the value is the constraint's default element, and the folds are
// cached inline (there is nothing to prove — the value is by construction the
// constraint's own default, hence trivially inside it).
walk_constraint :: #force_inline proc(a: ^Analyzer, current_scope: ^Scope_Type, idx: Node_Index) -> ^Type {
	ast := a.ast
	data := ast.node_data[idx]
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
}

// `target.prop` — resolve `prop` against the scope `target` denotes. The loop
// peels through Carve_Types to their source, so a property of a carved scope
// resolves against the underlying scope's fields. Property access takes the
// *last* occurrence of the name (last=true), per the same-name rule.
walk_property :: #force_inline proc(a: ^Analyzer, current_scope: ^Scope_Type, idx: Node_Index) -> ^Type {
	ast := a.ast
	data := ast.node_data[idx]
	right_idx := data.binary.right
	prop_name := span_str(ast, ast.node_data[right_idx].identifier.name)
	prop_ordinal := ast.node_data[right_idx].identifier.ordinal

	// Source-none property (`.x`, written with no left side) is a self-mention:
	// inside a carve override it refers to a field of the carved scope, reading
	// its *original* value (before any of this carve's overrides). Resolve it
	// directly against self_scope, with no parent walk-up — `.` names this scope.
	if data.binary.left == INVALID_NODE {
		if a.carved_scope == nil {
			sem_error(
				a,
				fmt.tprintf("'.%s' is only valid inside a carve override", prop_name),
				.Invalid_Property_Access,
				node_span(a, right_idx),
			)
			result := new(Type)
			result^ = Invalid_Type{}
			return result
		}
		s_scope, s_index := self_resolve(a.carved_scope, prop_name, prop_ordinal)
		if s_scope == nil {
			sem_error(
				a,
				fmt.tprintf("'.%s' does not exist in the carved scope", prop_name),
				.Invalid_Property_Access,
				node_span(a, right_idx),
			)
			result := new(Type)
			result^ = Invalid_Type{}
			return result
		}
		ref := new(Reference)
		ref^ = Reference {
			prop_name,
			prop_ordinal >= 0 ? Maybe(u64)(u64(prop_ordinal)) : nil,
			s_scope,
			s_index,
		}
		result := new(Type)
		result^ = Reference_Type{nil, ref}
		return result
	}

	target := walk(a, current_scope, data.binary.left)

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
			node_span(a, right_idx),
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
}

walk_enforce :: #force_inline proc(a: ^Analyzer, current_scope: ^Scope_Type, idx: Node_Index) -> ^Type {
	data := a.ast.node_data[idx]
	left := walk(a, current_scope, data.binary.left)
	right := walk(a, current_scope, data.binary.right)
	result := new(Type)
	result^ = Or_Type{left, right}
	return result
}

walk_range :: #force_inline proc(a: ^Analyzer, current_scope: ^Scope_Type, idx: Node_Index) -> ^Type {
	data := a.ast.node_data[idx]
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
}

// An operator node. The set-algebra operators (`&`, `|`, ~) become symbolic
// And/Or/Negate nodes that the constraint folder reduces later; every other
// operator is arithmetic and is folded eagerly into a Compose_Type's envelope
// here so a constraint mismatch surfaces at the operation, not downstream.
walk_operator :: #force_inline proc(a: ^Analyzer, current_scope: ^Scope_Type, idx: Node_Index) -> ^Type {
	data := a.ast.node_data[idx]
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
	case .Cast:
		// `left :: right` — raw reinterpret-cast of `left` into `right`'s layout.
		result^ = Cast_Type{left, right, nil}
		fold_cast(a, result, idx)
	case:
		result^ = Compose_Type{left, right, data.operator.kind, nil}
		fold_compose(a, result, idx)
	}
	return result
}

// `source{ … }` — derive a new scope from `source`. We first resolve `source`
// down to the underlying Scope_Type (peeling carves-of-carves) so each
// override can be located in it. Overrides come in two forms, handled in the
// loop: named (`name -> v`, resolved by name, FIRST occurrence) and positional
// (a bare value, matched to the next field by index). Each override is
// constraint-checked against the field it replaces.
walk_carve :: #force_inline proc(a: ^Analyzer, current_scope: ^Scope_Type, idx: Node_Index) -> ^Type {
	ast := a.ast
	data := ast.node_data[idx]
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

	// While walking override values, a source-none property (`.x`) is a
	// self-mention into the carved scope. Point carved_scope at it and restore
	// the outer one afterwards so nested carves resolve `.` against the nearest.
	saved_carved := a.carved_scope
	a.carved_scope = src_scope
	defer a.carved_scope = saved_carved

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
					node_span(a, name_idx),
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
							node_span(a, val_idx),
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
					node_span(a, child),
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
							node_span(a, child),
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

	// Implicit constraints: substituting an override can break a constraint on
	// another field that (transitively) references it — `u8:z -> x+y` no longer
	// fits u8 once x is carved out of range. fold_carve materializes the
	// substituted scope; we re-prove every colored binding against its now-
	// substituted value and report the mismatch at the carve site.
	recheck_carve(a, result, idx)

	return result
}

// recheck_carve folds a carve to its substituted scope and re-proves each
// colored binding (constraint vs the substituted value's fold). The per-field
// inline check above only covers the directly-overridden fields; this covers the
// implicit constraints — fields whose value depends on what was carved.
recheck_carve :: proc(a: ^Analyzer, carve: ^Type, node: Node_Index) {
	sub := fold_carve(carve)
	if sub == nil do return
	for i in 0 ..< len(sub.names) {
		fc := i < len(sub.constraint_folds) ? sub.constraint_folds[i] : nil
		if fc == nil do continue
		ft := fold_value_type(sub.values[i])
		if ft == nil do continue // unresolved value: not a definite violation here
		if !satisfy_root(fc, ft) {
			display := sub.names[i] != "" ? fmt.tprintf("'%s'", sub.names[i]) : "the production"
			sem_error(
				a,
				fmt.tprintf(
					"implicit constraint mismatch: %s does not satisfy %s on %s after carve",
					describe_type(ft),
					describe_type(fc),
					display,
				),
				.Constraint_Mismatch,
				node_span(a, node),
			)
		}
	}
}

// `target ? { match -> product, … }` — pattern match. We walk the target and
// every branch (so their bindings and constraints are checked), build a
// Pattern_Type from the (match, product) pairs, and prove the branches cover the
// target (raising Non_Exhaustive_Pattern otherwise). The Pattern_Type then folds
// to one branch as a constraint, or the union of reachable branches as a value
// (see pattern.odin / fold_constraint_pattern / fold_type_pattern).
//
// A branch source carries its MODE in its syntax: `=v -> …` (value match) parses
// as a unary `=` operator (Equal with no left side), which we peel here so the
// branch holds the bare value plus value_match=true. `c -> …` (typecheck match)
// keeps the constraint as-is. A leading `-> p` is the default branch (match nil).
walk_pattern :: #force_inline proc(a: ^Analyzer, current_scope: ^Scope_Type, idx: Node_Index) -> ^Type {
	ast := a.ast
	data := ast.node_data[idx]
	target := walk(a, current_scope, data.pattern.target)
	r := data.pattern.branches
	branch_nodes := ast.extra[r.start:][:r.len]

	branches := make([dynamic]Pattern_Branch, 0, len(branch_nodes) / 2)
	for i := 0; i < len(branch_nodes); i += 2 {
		match_idx := branch_nodes[i]
		product_idx := i + 1 < len(branch_nodes) ? branch_nodes[i + 1] : INVALID_NODE

		match: ^Type = nil
		value_match := false
		if match_idx != INVALID_NODE {
			// Peel a unary `=v` (value-match mode): the parser builds it as an Equal
			// operator with no left operand. Walk the inner operand as the bare match
			// value and flag the branch as a value match.
			mk := ast.node_kinds[match_idx]
			if mk == .Operator {
				op := ast.node_data[match_idx].operator
				if op.kind == .Equal && op.left == INVALID_NODE {
					value_match = true
					match = walk(a, current_scope, op.right)
				}
			}
			if match == nil {
				match = walk(a, current_scope, match_idx)
			}
		}

		product: ^Type = nil
		if product_idx != INVALID_NODE {
			product = walk(a, current_scope, product_idx)
		} else {
			product = make_none()
		}

		append(&branches, build_pattern_branch(match, product, value_match))
	}

	result := new(Type)
	result^ = Pattern_Type{target, branches[:]}

	// Exhaustiveness: the branches must cover the whole target (a covering union of
	// matches, or an empty-arrow default). A non-exhaustive pattern could let a
	// target value fall through unmatched.
	if !pattern_is_exhaustive(result.(Pattern_Type)) {
		sem_error(
			a,
			"non-exhaustive pattern: the branches do not cover every value of the target (add a covering branch or an empty `->` default)",
			.Non_Exhaustive_Pattern,
			node_span(a, idx),
		)
	}

	return result
}

// `target!` — collapse. Recorded as an Execute_Type; the actual reduction
// through the target's Product happens later in reduce.odin.
walk_execute :: #force_inline proc(a: ^Analyzer, current_scope: ^Scope_Type, idx: Node_Index) -> ^Type {
	data := a.ast.node_data[idx]
	target := walk(a, current_scope, data.execute.target)
	result := new(Type)
	result^ = Execute_Type{target}
	return result
}

// `@name` — an external. Opaque to static analysis, so Unknown_Type.
walk_external :: #force_inline proc(a: ^Analyzer, current_scope: ^Scope_Type, idx: Node_Index) -> ^Type {
	return make_unknown()
}

walk_branch :: #force_inline proc(a: ^Analyzer, current_scope: ^Scope_Type, idx: Node_Index) -> ^Type {
	return make_unknown()
}

walk_unknown :: #force_inline proc(a: ^Analyzer, current_scope: ^Scope_Type, idx: Node_Index) -> ^Type {
	return make_unknown()
}

// walk_literal turns a literal token into its degenerate single-element domain
// set: `5` becomes the integer interval 5..5, `"hi"` the string singleton, etc.
// A concrete literal is its own type — the value/set split (see type.odin) treats
// a singleton as a value. An unparseable literal yields Invalid_Type rather than
// crashing; the parse error is already reported upstream.
walk_literal :: #force_inline proc(a: ^Analyzer, idx: Node_Index) -> ^Type {
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
walk_identifier :: #force_inline proc(a: ^Analyzer, scope: ^Scope_Type, idx: Node_Index) -> ^Type {
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

	sem_error(a, fmt.tprintf("'%s' is not defined", name), .Undefined_Identifier, node_span(a, idx))
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

// sem_error / sem_warning take the offending node's SPAN and resolve its start to
// a Position once, here — so an Analyzer_Error always carries both the byte range
// (to underline) and its (line, column) (to print), like Parse_Error.
sem_error :: proc(
	s: ^Analyzer,
	message: string,
	error_type: Analyzer_Error_Type,
	span: Span,
) {
	error := Analyzer_Error {
		type     = error_type,
		message  = message,
		span     = span,
		position = span_to_position(s.ast, span.start),
	}
	append(&s.errors, error)
}

sem_warning :: proc(
	s: ^Analyzer,
	message: string,
	error_type: Analyzer_Error_Type,
	span: Span,
) {
	warning := Analyzer_Error {
		type     = error_type,
		message  = message,
		span     = span,
		position = span_to_position(s.ast, span.start),
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
