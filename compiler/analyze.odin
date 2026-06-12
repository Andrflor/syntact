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
// REDUCE NEVER CALLS THE FOLD LAYER (it has its own substitution/materialization
// in reduce.odin and reads the folds the analyzer cached), so a fold helper can
// always trust that context.user_ptr is this struct.
Analyzer :: struct {
	ast:              ^Ast,
	scope:            ^Scope_Type,
	errors:           [dynamic]Analyzer_Error,
	warnings:         [dynamic]Analyzer_Error,
	// While walking a carve's override values, this points at the scope being
	// carved so a source-none property (`.x`, a self-mention) resolves against
	// the carved scope's *original* fields. nil outside a carve override. Saved
	// and restored around each override walk so nested carves nest correctly.
	carved_scope:     ^Scope_Type,
	// Span of the carve being rechecked, so reresolve_property (in the fold layer,
	// reached via the context) anchors its error at the carve site. Set around
	// recheck_carve only.
	recheck_span:     Span,
	// Transient push/pop stacks guarding self-referential folds. They live ON the
	// analyzer (not in a global) so their backing is allocated in this pass's
	// allocator and dies with it: a global [dynamic] would keep a stale cap into a
	// destroyed arena and corrupt the next pass — the test runner analyzes cases on
	// many threads, each in its own arena. Reached via current_analyzer() from the
	// fold layer. Strictly balanced, so empty between top-level folds.
	// scope_scan_stack guards the Scope/Carve constraint field scan against a
	// self-referential constraint (`A -> {x -> A}`): the outermost scan decides.
	scope_scan_stack: [dynamic]^Type,
	// carve_fold_stack guards fold_carve against re-entering the SAME carve node
	// while folding it (a self-referential carve — its own placeholder value, a
	// recursive tail): the inner re-entry bails to nil instead of cloning
	// forever. Distinct nodes (each level of an inductive proof repoints a fresh
	// copy) pass through.
	carve_fold_stack: [dynamic]^Type,
	// execute_stack guards folding a recursive collapse (`fib{…}!` whose
	// production collapses fib again): each Execute fold pushes the UNDERLYING
	// scope its target resolves through (stable across carve clones — the
	// recursive reference always names the original); re-entry bails to nil.
	execute_stack:    [dynamic]^Scope_Type,
	// Deferred-recursion state. `fold_pending` is set by the fold layer (via
	// current_analyzer) when a fold touches a scope still being walked or an
	// unresolved forward Reference: the fold result cannot be trusted yet, so
	// the dependent obligation is queued on `pending` and re-run when that scope
	// closes (scope_close).
	fold_pending:     ^Scope_Type,
	pending:          [dynamic]Pending,
}

// One deferred obligation, re-run when `awaiting` finishes walking:
//   .Ref       — resolve `rr` (an unresolved forward Reference_Type) against
//                `target` (the property's target expression), patching the
//                Reference's match_scope/match_index once the scope closes.
//   .Carve     — re-resolve the references of `carve` (its source awaited
//                `awaiting`), then re-run its per-field proofs + recheck_carve.
//   .Typecheck — re-fold and re-prove binding `bind` of `scope`, patching the
//                cached constraint_folds/type_folds in place (reduce reads them).
//   .Default   — a bare-constraint binding (`...Array{T}:`, `c:name`) whose
//                constraint awaited `awaiting`: re-fold it and materialize its
//                default into values/folds at `bind`.
Pending_Kind :: enum u8 {
	Ref,
	Typecheck,
	Carve,
	Default,
}

Pending :: struct {
	kind:     Pending_Kind,
	awaiting: ^Scope_Type,
	rr:       ^Type, // .Ref: the unresolved Reference_Type node to patch
	target:   ^Type, // .Ref: the property's target expression (nil = self-mention)
	carve:    ^Type, // .Carve: the Carve_Type node
	scope:    ^Scope_Type, // .Typecheck: the owning scope
	bind:     int, // .Typecheck: binding index in `scope`
	node:     Node_Index, // diagnostics anchor
}

create_analyzer :: proc(ast: ^Ast) -> Analyzer {
	return Analyzer {
		ast = ast,
		scope = new(Scope_Type),
		errors = make([dynamic]Analyzer_Error, 0),
		warnings = make([dynamic]Analyzer_Error, 0),
	}
}

// --- analyzer core ---

// analyze is the entry point: it walks the root scope's children into the root
// Scope_Type, leaving the result and any diagnostics in `cache`. A bare child
// (not a binding/constraint) is treated as an anonymous Pointing_Push so it still
// gets recorded and constraint-checked. Returns true iff no errors were emitted.
analyze :: proc(cache: ^Cache) -> bool {
	a := current_analyzer()
	ast := a.ast

	root := ast_root(ast)
	root_data := ast.node_data[root]
	r := root_data.scope
	children := ast.extra[r.start:][:r.len]
	a.scope.walking = true
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
			walk(a, a.scope, child)
		case:
			value := walk(a, a.scope, child)
			scope_append(a, a.scope, "", nil, .Pointing_Push, value)
			typecheck(a, a.scope, "", nil, .Pointing_Push, value, child)
		}
	}

	a.scope.walking = false
	scope_close(a, a.scope)
	// Every deferred obligation awaits some enclosing scope, and the root is the
	// outermost — nothing may survive its close. A leftover means a reference
	// that never became resolvable; report it rather than silently dropping it.
	for p in a.pending {
		sem_error(
			a,
			"unresolved recursive reference",
			.Invalid_Property_Access,
			node_span(a, p.node),
		)
	}
	clear(&a.pending)

	cache.scope = a.scope
	cache.analyze_errors = a.errors
	cache.analyze_warnings = a.warnings

	if resolver.options.print_errors && len(a.errors) > 0 {
		debug_sem_errors(a)
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
	capture: string = "",
) {
	append(&scope.names, name)
	append(&scope.constraints, constraint)
	append(&scope.kind, bk)
	append(&scope.types, value)
	append(&scope.captures, capture)

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
	a.fold_pending = nil
	fc := fold_constraint(constraint)
	ft := fold_value_type(value)

	append(&scope.constraint_folds, fc)
	append(&scope.type_folds, ft)

	// The folds touched a scope still being walked (a recursive/forward
	// reference): neither can be trusted yet. Queue the proof for that scope's
	// close — retypecheck re-folds and PATCHES the two cached folds in place.
	if pend := a.fold_pending; pend != nil {
		a.fold_pending = nil
		append(
			&a.pending,
			Pending {
				kind = .Typecheck,
				awaiting = pend,
				scope = scope,
				bind = len(scope.constraint_folds) - 1,
				node = node,
			},
		)
		return
	}

	prove_binding(a, fc, ft, name, node)
}

// prove_binding is the diagnostic tail shared by typecheck and retypecheck:
// given the two folds, report Insoluble_Constraint / Constraint_Mismatch.
prove_binding :: proc(a: ^Analyzer, fc, ft: ^Type, name: string, node: Node_Index) {
	display := name != "" ? fmt.tprintf("'%s'", name) : "the production"

	// A constraint must denote a statically-known SET. fold_constraint lands on
	// Unknown when the constraint depends on a `??` anywhere — directly, through
	// a reference, or inside any composition — because such a constraint cannot
	// be solved at compile time. `u8` is fine (the set 0..255); `??::u8` is one
	// indeterminate u8 element, so `??::u8:a -> 10` is insoluble.
	if fold_is_unknown(fc) {
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

// scope_close runs when `s` finishes walking: every deferred obligation that
// awaited s is drained IN INSERTION ORDER (inner ones first, so references
// resolve before the typechecks that read them). An obligation that re-blocks —
// its fold hits an OUTER scope still being walked — re-queues itself on that
// scope; the root's close is the final drain.
scope_close :: proc(a: ^Analyzer, s: ^Scope_Type) {
	if len(a.pending) == 0 do return
	i := 0
	for i < len(a.pending) {
		if a.pending[i].awaiting != s {
			i += 1
			continue
		}
		p := a.pending[i]
		ordered_remove(&a.pending, i)
		switch p.kind {
		case .Ref:
			close_ref(a, p)
		case .Typecheck:
			retypecheck(a, p.scope, p.bind, p.node)
		case .Carve:
			close_carve(a, p)
		case .Default:
			close_default(a, p)
		}
	}
}

// close_default re-folds a deferred bare constraint and materializes its
// default in place — mirroring what walk_constraint/walk_expand/walk_product do
// inline for a non-recursive constraint.
close_default :: proc(a: ^Analyzer, p: Pending) {
	a.fold_pending = nil
	fc := fold_constraint(p.scope.constraints[p.bind])
	if pend := a.fold_pending; pend != nil {
		a.fold_pending = nil
		np := p
		np.awaiting = pend
		append(&a.pending, np)
		return
	}
	value := default_value(fc)
	p.scope.types[p.bind] = value
	if p.bind < len(p.scope.constraint_folds) do p.scope.constraint_folds[p.bind] = fc
	if p.bind < len(p.scope.type_folds) do p.scope.type_folds[p.bind] = value
	if fold_is_unknown(fc) {
		prove_binding(a, fc, value, p.scope.names[p.bind], p.node)
	}
}

// pending_scope_of reports the still-walking scope that blocks resolving
// through `t` (nil when nothing blocks): an unresolved named recursive
// reference blocks on its scope; a chain landing on a scope still being walked
// blocks on that scope; a carve blocks on whatever blocks its source.
pending_scope_of :: proc(t: ^Type) -> ^Scope_Type {
	cur := t
	for cur != nil {
		cur = follow(cur)
		if cur == nil do return nil
		#partial switch &v in cur^ {
		case Reference_Type:
			// follow chases a RESOLVED reference; landing here means unresolved
			// (a deferred forward property). Only a scope still being walked
			// blocks — unresolved against a CLOSED scope means the close already
			// reported the miss: permanently broken, nothing left to wait for
			// (re-queuing would loop the drain).
			r := v.reference
			if r != nil && r.match_index < 0 && r.match_scope != nil && r.match_scope.walking {
				return r.match_scope
			}
			return nil
		case Recursive_Mention_Type:
			// A self mention is always resolvable (its binding pre-exists); it
			// never blocks the drain.
			return nil
		case Scope_Type:
			if v.walking do return &v
			return nil
		case Carve_Type:
			cur = v.source
			continue
		}
		return nil
	}
	return nil
}

// close_ref resolves a deferred recursive reference now that the scope it
// awaited is complete: re-resolve through the property's target expression
// (resolve_property_site — the one place property lookup is defined). A target
// that is ITSELF still blocked (a chain into an outer open scope) re-queues on
// that scope; a miss against the now-complete scope is the real error.
close_ref :: proc(a: ^Analyzer, p: Pending) {
	rt, rt_ok := &p.rr^.(Reference_Type)
	if !rt_ok || rt.reference == nil do return
	ref := rt.reference
	if open := pending_scope_of(p.target); open != nil {
		np := p
		np.awaiting = open
		append(&a.pending, np)
		return
	}
	prop_name, _ := ref.name.(string)
	prop_ordinal := i16(-1)
	if idx, ok := ref.index.(u64); ok do prop_ordinal = i16(idx)
	rs, ri := resolve_property_site(p.target, prop_name, prop_ordinal)
	if rs == nil {
		sem_error(
			a,
			fmt.tprintf("property '%s' does not exist", prop_name),
			.Invalid_Property_Access,
			node_span(a, p.node),
		)
		return
	}
	ref.match_scope = rs
	ref.match_index = ri
}

// retypecheck re-runs a deferred binding proof: re-fold both sides (the
// recursive references are resolved now), PATCH the cached folds in place
// (reduce reads these columns), and report exactly what typecheck would have.
retypecheck :: proc(a: ^Analyzer, scope: ^Scope_Type, bind: int, node: Node_Index) {
	constraint := scope.constraints[bind]
	value := scope.types[bind]
	a.fold_pending = nil
	fc := fold_constraint(constraint)
	ft := fold_value_type(value)
	if pend := a.fold_pending; pend != nil {
		// Still blocked, on an outer scope still being walked: re-queue there.
		a.fold_pending = nil
		append(
			&a.pending,
			Pending{kind = .Typecheck, awaiting = pend, scope = scope, bind = bind, node = node},
		)
		return
	}
	if bind < len(scope.constraint_folds) do scope.constraint_folds[bind] = fc
	if bind < len(scope.type_folds) do scope.type_folds[bind] = ft
	prove_binding(a, fc, ft, scope.names[bind], node)
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
	allow_capture := false,
) -> (
	^Scope_Type,
	int,
) {
	if ordinal >= 0 {
		if name == "" {
			if int(ordinal) < len(scope.types) {
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

	// Capture fallback: a `(e)` capture is an INVISIBLE alias of its binding —
	// not in `names` (so `.`/carve never see it), but referenceable by mention.
	// Only the mention path (walk_identifier) sets allow_capture; property access
	// and carve resolution leave it false, so a capture stays invisible to them.
	// Searched after visible names in THIS scope, before walking to parent, so a
	// visible name always wins and a capture stays scope-local.
	if allow_capture {
		for i := 0; i < len(scope.captures); i += 1 {
			if scope.captures[i] == name {
				return scope, i
			}
		}
	}

	if scope.parent != nil {
		return scope_resolve(scope.parent, name, ordinal, last, allow_capture)
	}
	return nil, -1
}

// self_resolve locates a field for a self-mention (`.x` / `.#0` / `.x#0`) in the
// scope being carved. Unlike scope_resolve it never walks up to the parent: `.`
// names *this* scope, so a missing field is an error, not a parent lookup. With
// no ordinal it takes the first occurrence (the carve default-target rule).
// nth_pointing_push returns the index of the k-th Pointing_Push binding in `scope`
// (0-based), or -1 if there are fewer than k+1. Used by positional carves, which
// only target the pushable (`->`) fields.
nth_pointing_push :: proc(scope: ^Scope_Type, k: int) -> int {
	count := 0
	for i := 0; i < len(scope.kind); i += 1 {
		if scope.kind[i] == .Pointing_Push {
			if count == k do return i
			count += 1
		}
	}
	return -1
}

self_resolve :: proc(scope: ^Scope_Type, name: string, ordinal: i16) -> (^Scope_Type, int) {
	if ordinal >= 0 {
		if name == "" {
			if int(ordinal) < len(scope.types) {
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
	// A self-referential scope (`a -> b; b -> a`, or a constraint that mentions
	// itself) forms a cycle in the Mention/Reference chain — chasing it unguarded
	// would loop forever. The cycle is EXACT: it is re-visiting the same binding
	// site (match_scope, match_index). We detect that precisely instead of clipping
	// at a magic depth — a cycle is a valid construction, not an error, so we just
	// stop at the node we'd revisit and return it as-is. The visited set is built
	// lazily: a non-indirection (the common case) costs nothing.
	cur := t
	visited: map[Follow_Key]bool
	defer if visited != nil do delete(visited)
	for cur != nil {
		key: Follow_Key
		next: ^Type
		#partial switch v in cur^ {
		case Mention_Type:
			if v.match_scope == nil || v.match_index < 0 do return cur
			key = Follow_Key{v.match_scope, v.match_index}
			next = v.match_scope.types[v.match_index]
		case Reference_Type:
			r := v.reference
			if r == nil || r.match_scope == nil || r.match_index < 0 do return cur
			key = Follow_Key{r.match_scope, r.match_index}
			next = r.match_scope.types[r.match_index]
		case Recursive_Mention_Type:
			// A self mention designates its own binding (the scope pointer is
			// valid even while the scope is incomplete — CONSUMERS check
			// `walking`). Follow it like a Mention to that binding's value.
			if v.match_scope == nil || v.match_index < 0 do return cur
			key = Follow_Key{v.match_scope, v.match_index}
			next = v.match_scope.types[v.match_index]
		case:
			return cur
		}
		if visited == nil do visited = make(map[Follow_Key]bool)
		if key in visited do return cur // cycle: we'd revisit this exact binding
		visited[key] = true
		cur = next
	}
	return cur
}

// Follow_Key identifies a binding site: (definition scope, ordinal within it).
// Re-visiting the same key while following indirections IS the cycle.
Follow_Key :: struct {
	scope: ^Scope_Type,
	index: int,
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
		// A missing node (incomplete source while typing) is INVALID, not the
		// legitimate value `none`.
		return make_invalid()
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

// make_invalid : the "an error is already reported / this folds to nothing"
// sentinel. Distinct from None_Type, which is the LEGITIMATE value `none`.
make_invalid :: #force_inline proc() -> ^Type {
	result := new(Type)
	result^ = Invalid_Type{}
	return result
}

walk_scope_node :: #force_inline proc(
	a: ^Analyzer,
	current_scope: ^Scope_Type,
	idx: Node_Index,
) -> ^Type {
	ast := a.ast
	data := ast.node_data[idx]
	scope := new(Scope_Type)
	scope.parent = current_scope
	scope.walking = true
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
	// Close BEFORE the value copy so the copy never carries walking=true.
	scope.walking = false
	scope_close(a, scope)
	result := new(Type)
	result^ = scope^
	return result
}

// A directional binding `lhs <op> rhs`. The left side is either a bare name,
// or a `constraint : name` form (so we extract both the imposed constraint and
// the bound name). The right side is the value; when it is a scope literal we
// build the child Scope_Type in place and register the binding *before*
// walking the body, so the body can refer back to the binding being defined.
walk_binding :: #force_inline proc(
	a: ^Analyzer,
	current_scope: ^Scope_Type,
	idx: Node_Index,
) -> ^Type {
	ast := a.ast
	data := ast.node_data[idx]
	kind := ast.node_kinds[idx]
	left_idx := data.binary.left
	right_idx := data.binary.right
	bk := binding_kind_from_node(kind)

	name := ""
	capture := ""
	constraint: ^Type = nil
	if left_idx == INVALID_NODE do return make_invalid() // malformed binding (parse error)
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
				capture = span_str(ast, ast.node_data[name_idx].identifier.capture)
			} else if nk == .Carve {
				// constraint:name{carves} — the carve source is the name
				csrc := ast.node_data[name_idx].carve.source
				if ast.node_kinds[csrc] == .Identifier {
					name = span_str(ast, ast.node_data[csrc].identifier.name)
					capture = span_str(ast, ast.node_data[csrc].identifier.capture)
				}
			}
			// `u16:3 -> v`, `u16:(a+b) -> v` — the colored name must resolve to
			// an identifier; a literal/expression cannot name a binding.
			if name == "" {
				sem_error(
					a,
					"invalid constraint name: the colored name must be an identifier",
					.Invalid_Constraint_Name,
					node_span(a, name_idx),
				)
				return make_invalid()
			}
		}
	} else if left_kind == .Identifier {
		name = span_str(ast, ast.node_data[left_idx].identifier.name)
		capture = span_str(ast, ast.node_data[left_idx].identifier.capture)
	} else {
		// `{plop} -> v`, `3 -> v`, `(a+b) -> v` — the left of a binding must
		// name a binding (a bare identifier or a `constraint:name` form). A
		// scope/literal/expression on the left is illegal, not an anonymous one.
		sem_error(
			a,
			"invalid binding name: the left of a binding must be a name",
			.Invalid_Binding_Name,
			node_span(a, left_idx),
		)
		return make_invalid()
	}

	if right_idx == INVALID_NODE do return make_invalid() // malformed binding (parse error)
	right_kind := ast.node_kinds[right_idx]
	if right_kind == .ScopeNode {
		result := new(Type)
		result^ = Scope_Type {
			parent  = current_scope,
			walking = true,
		}
		scope := &result.(Scope_Type)
		scope_append(a, current_scope, name, constraint, bk, result, capture)

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
		// The body is fully walked: close the scope (resolving everything that
		// awaited it) BEFORE the binding's own proof, so that proof sees the
		// resolved recursive references.
		scope.walking = false
		scope_close(a, scope)
		typecheck(a, current_scope, name, constraint, bk, result, idx)
		return result
	}
	value := walk(a, current_scope, right_idx)
	scope_append(a, current_scope, name, constraint, bk, value, capture)
	typecheck(a, current_scope, name, constraint, bk, value, idx)
	return value
}

// `-> X` produces ONE entry, the scope's production. If X is itself a
// constraint (`-> f32:`, `-> u8:3`), the production CARRIES that constraint —
// it is a single colored production, not a binding plus a production. Walking
// the constraint operand directly would route through walk_constraint, which
// appends its own (Pointing_Push) binding, doubling the entry. So we peel the
// constraint here and emit exactly one .Product, like walk_expand does.
walk_product :: #force_inline proc(
	a: ^Analyzer,
	current_scope: ^Scope_Type,
	idx: Node_Index,
) -> ^Type {
	ast := a.ast
	data := ast.node_data[idx]
	operand_idx := data.unary.operand
	if ast.node_kinds[operand_idx] == .Constraint {
		cdata := ast.node_data[operand_idx]
		constraint := walk(a, current_scope, cdata.binary.left)
		value: ^Type = ---
		if cdata.binary.right != INVALID_NODE {
			value = walk(a, current_scope, cdata.binary.right)
			scope_append(a, current_scope, "", constraint, .Product, value)
			typecheck(a, current_scope, "", constraint, .Product, value, idx)
		} else {
			value = append_bare_constraint(a, current_scope, "", constraint, .Product, idx)
		}
		return value
	}
	value := walk(a, current_scope, operand_idx)
	scope_append(a, current_scope, "", nil, .Product, value)
	typecheck(a, current_scope, "", nil, .Product, value, idx)
	return value
}

// `+{…}` extension. A constrained-but-valueless expand (`+{u8:}`) materializes
// the constraint's default as the value and caches the folds directly, since
// there is no value expression to run typecheck() against.
walk_expand :: #force_inline proc(
	a: ^Analyzer,
	current_scope: ^Scope_Type,
	idx: Node_Index,
) -> ^Type {
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
			append_bare_constraint(a, current_scope, "", constraint, .Expand, idx)
		}
		return value
	}
	value := walk(a, current_scope, operand_idx)
	scope_append(a, current_scope, "", nil, .Expand, value)
	typecheck(a, current_scope, "", nil, .Expand, value, idx)
	return value
}

walk_compile_time :: #force_inline proc(
	a: ^Analyzer,
	current_scope: ^Scope_Type,
	idx: Node_Index,
) -> ^Type {
	data := a.ast.node_data[idx]
	return walk(a, current_scope, data.unary.operand)
}

// A bare constraint `c : name` with no `-> value`. It still introduces a
// binding: the value is the constraint's default element, and the folds are
// cached inline (there is nothing to prove — the value is by construction the
// constraint's own default, hence trivially inside it).
walk_constraint :: #force_inline proc(
	a: ^Analyzer,
	current_scope: ^Scope_Type,
	idx: Node_Index,
) -> ^Type {
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
		// `u16:3`, `u16:(a+b)`, … — a colored binding's name must be an
		// identifier; a literal/expression cannot name a binding. Anything that
		// left `name` empty here is illegal, not a silent anonymous binding.
		if name == "" {
			sem_error(
				a,
				"invalid constraint name: the colored name must be an identifier",
				.Invalid_Constraint_Name,
				node_span(a, data.binary.right),
			)
			return make_invalid()
		}
	}
	return append_bare_constraint(a, current_scope, name, constraint, .Pointing_Push, idx)
}

// append_bare_constraint registers a valueless colored binding (`c:name`,
// `...c:`, `-> c:`): the value is the constraint's materialized default and the
// folds are cached inline (there is nothing to prove — the default is by
// construction inside its own constraint). When the constraint touches a scope
// still being walked (a recursive constraint like `...Array{T}:` inside Array),
// the fold + materialization are deferred to that scope's close (.Default) and
// an Unknown placeholder holds the slot meanwhile.
append_bare_constraint :: proc(
	a: ^Analyzer,
	scope: ^Scope_Type,
	name: string,
	constraint: ^Type,
	bk: Binding_Kind,
	node: Node_Index,
) -> ^Type {
	a.fold_pending = nil
	fc := fold_constraint(constraint)
	value := default_value(fc)
	if pend := a.fold_pending; pend != nil {
		a.fold_pending = nil
		// The CONSTRAINT NODE itself holds the slot until close_default patches
		// in the materialized default — NOT an Unknown_Type, which means `??`
		// and would wrongly diagnose every fold over this scope as insoluble.
		// A fold reaching the placeholder folds the constraint (guarded against
		// re-entry by scope_scan_stack), which is exactly what the slot denotes.
		value = constraint
		scope_append(a, scope, name, constraint, bk, value)
		append(&scope.constraint_folds, nil)
		append(&scope.type_folds, nil)
		append(
			&a.pending,
			Pending {
				kind = .Default,
				awaiting = pend,
				scope = scope,
				bind = len(scope.types) - 1,
				node = node,
			},
		)
		return value
	}
	scope_append(a, scope, name, constraint, bk, value)
	append(&scope.constraint_folds, fc)
	append(&scope.type_folds, value)
	return value
}

// resolve_property_site locates the field a `target.name` access lands on,
// returning its (scope, index) or (nil, -1) when the property does not exist. It
// follows `target` to its scope, peeling Carve_Types to their source, and takes
// the LAST occurrence of the name (last=true), per the same-name rule. Shared by
// walk_property (initial analysis) and reresolve_property (carve substitution) so
// both resolve identically — the one place property lookup is defined.
resolve_property_site :: proc(target: ^Type, name: string, ordinal: i16) -> (^Scope_Type, int) {
	prop_target := follow(target)
	for prop_target != nil {
		#partial switch &t in prop_target^ {
		case Scope_Type:
			return scope_resolve(&t, name, ordinal, true)
		case Carve_Type:
			if t.source != nil {
				prop_target = follow(t.source)
				continue
			}
		}
		break
	}
	return nil, -1
}

// `target.prop` — resolve `prop` against the scope `target` denotes. The loop
// peels through Carve_Types to their source, so a property of a carved scope
// resolves against the underlying scope's fields. Property access takes the
// *last* occurrence of the name (last=true), per the same-name rule.
walk_property :: #force_inline proc(
	a: ^Analyzer,
	current_scope: ^Scope_Type,
	idx: Node_Index,
) -> ^Type {
	ast := a.ast
	data := ast.node_data[idx]
	right_idx := data.binary.right
	// `a.` while typing: the property name node is missing. An incomplete edit
	// is not an error here — the LSP must tolerate it.
	if right_idx == INVALID_NODE {
		return make_invalid()
	}
	// `a.3`, `a.(b+c)` — the property side parsed but is not a name. A property
	// must name a field; a literal/expression cannot. (Ordinals are `#n`, not
	// `.n`.) An Invalid_Type with no diagnostic is always a bug.
	if ast.node_kinds[right_idx] != .Identifier {
		sem_error(
			a,
			"invalid property name: a property must name a field (ordinals are '#n')",
			.Invalid_Property_Access,
			node_span(a, right_idx),
		)
		return make_invalid()
	}
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

	prop_scope, prop_index := resolve_property_site(target, prop_name, prop_ordinal)

	if prop_scope == nil {
		// The target chain lands in a scope STILL BEING WALKED (`module.odd`
		// before odd is bound): the miss is not an error yet — defer it as a
		// recursive reference, re-resolved when that scope closes. Only a miss on
		// a COMPLETE scope is a real Invalid_Property_Access.
		if open := pending_scope_of(target); open != nil {
			// Not a self mention — a forward property into a scope still walking.
			// Record an UNRESOLVED Reference (match_index -1) and defer it; the
			// close patches the resolved (match_scope, match_index) in place.
			ref := new(Reference)
			ref^ = Reference {
				prop_name,
				prop_ordinal >= 0 ? Maybe(u64)(u64(prop_ordinal)) : nil,
				open,
				-1,
			}
			result := new(Type)
			result^ = Reference_Type{target, ref}
			append(
				&a.pending,
				Pending {
					kind = .Ref,
					awaiting = open,
					rr = result,
					target = target,
					node = right_idx,
				},
			)
			return result
		}
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

walk_enforce :: #force_inline proc(
	a: ^Analyzer,
	current_scope: ^Scope_Type,
	idx: Node_Index,
) -> ^Type {
	data := a.ast.node_data[idx]
	left := walk(a, current_scope, data.binary.left)
	right := walk(a, current_scope, data.binary.right)
	result := new(Type)
	result^ = Or_Type{left, right}
	return result
}

walk_range :: #force_inline proc(
	a: ^Analyzer,
	current_scope: ^Scope_Type,
	idx: Node_Index,
) -> ^Type {
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
walk_operator :: #force_inline proc(
	a: ^Analyzer,
	current_scope: ^Scope_Type,
	idx: Node_Index,
) -> ^Type {
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
// carve_shorthand_field tells the shorthand carve-of-a-carved-field (`a{z{…}}`)
// apart from a plain positional carve of a foreign scope (`a{data{6}}`). It fires
// ONLY when the child is a `Carve` whose source is a bare identifier that names a
// field of the scope being carved (src_scope) — then that field is the override
// target. Otherwise (source not an identifier, or the name is not a carved field)
// it returns ok=false and the child stays a positional value.
carve_shorthand_field :: proc(
	a: ^Analyzer,
	src_scope: ^Scope_Type,
	child: Node_Index,
) -> (
	scope: ^Scope_Type,
	index: int,
	ok: bool,
) {
	if src_scope == nil do return nil, -1, false
	ast := a.ast
	if ast.node_kinds[child] != .Carve do return nil, -1, false
	src_node := ast.node_data[child].carve.source
	if ast.node_kinds[src_node] != .Identifier do return nil, -1, false
	cname := span_str(ast, ast.node_data[src_node].identifier.name)
	cordinal := ast.node_data[src_node].identifier.ordinal
	// self_resolve, NOT scope_resolve: the shorthand targets a DIRECT field of the
	// carved scope only. scope_resolve walks up to the parent, which would wrongly
	// claim a foreign top-level scope (`a{data{6}}`, `data` defined at the root) as a
	// carved field and steal it from the positional-carve path.
	fscope, fidx := self_resolve(src_scope, cname, cordinal)
	if fscope == nil do return nil, -1, false
	return fscope, fidx, true
}

// source_override, when non-nil, replaces the walk of `idx`'s source node. It is
// used for the shorthand carve-of-a-carved-field (`a{z{a->2}}`): the inner
// `z{a->2}`'s source `z` denotes the field of the scope being carved, so the
// caller resolves it as a self-mention (a Reference_Type into the carved scope,
// identical to `.z`) and threads it in here instead of letting `z` resolve as a
// plain mention in the enclosing scope.
walk_carve :: proc(
	a: ^Analyzer,
	current_scope: ^Scope_Type,
	idx: Node_Index,
	source_override: ^Type = nil,
) -> ^Type {
	ast := a.ast
	data := ast.node_data[idx]
	source := source_override != nil ? source_override : walk(a, current_scope, data.carve.source)

	result := new(Type)
	result^ = Carve_Type {
		source     = source,
		references = make([dynamic]Reference),
		types      = make([dynamic]^Type),
	}

	// A source that chains into a scope STILL BEING WALKED (`module.odd{…}`
	// while module is open, or a self-carve `Array{T}` inside Array) has no
	// resolvable fields yet: defer the WHOLE carve — reference resolution,
	// override walks, per-field proofs, recheck — to that scope's close
	// (close_carve). The override expressions are pure (they never register
	// bindings into the enclosing scope), so walking them at close, with
	// current_scope captured here, is equivalent.
	if pending_src := pending_scope_of(source); pending_src != nil {
		append(
			&a.pending,
			Pending {
				kind = .Carve,
				awaiting = pending_src,
				carve = result,
				scope = current_scope,
				node = idx,
			},
		)
		return result
	}

	carve_resolve_children(a, current_scope, idx, carve_source_scope(source), result)
	carve_check(a, result, idx)
	return result
}

// carve_source_scope follows a carve source down to the underlying Scope_Type
// its override names resolve against, peeling nested carves.
carve_source_scope :: proc(source: ^Type) -> ^Scope_Type {
	src_target := follow(source)
	for src_target != nil {
		#partial switch &s in src_target^ {
		case Scope_Type:
			return &s
		case Carve_Type:
			if s.source != nil {
				src_target = follow(s.source)
				continue
			}
		}
		break
	}
	return nil
}

// carve_resolve_children walks a carve's override children, resolving each
// against src_scope and appending (reference, value) pairs onto the carve IN
// PLACE. Shared by walk_carve (immediate) and close_carve (deferred), so both
// resolve identically.
carve_resolve_children :: proc(
	a: ^Analyzer,
	current_scope: ^Scope_Type,
	idx: Node_Index,
	src_scope: ^Scope_Type,
	carve: ^Type,
) {
	ast := a.ast
	data := ast.node_data[idx]
	r := data.carve.children
	carve_children := ast.extra[r.start:][:r.len]

	cv, cv_ok := &carve^.(Carve_Type)
	if !cv_ok do return
	refs := &cv.references
	vals := &cv.types

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
				refs,
				Reference {
					cname,
					cordinal >= 0 ? Maybe(u64)(u64(cordinal)) : nil,
					carve_scope,
					carve_index,
				},
			)
			append(vals, val)
		} else if shorthand_field, shorthand_idx, ok := carve_shorthand_field(a, src_scope, child);
		   ok {
			// Shorthand `a{z{a->2}}` == `a{z->.z{a->2}}`: a carve child `z{…}` whose
			// source `z` NAMES A FIELD of the scope being carved targets that field and
			// re-carves it. (A `data{6}` whose source is NOT a carved field is a plain
			// positional carve — the value `data{6}` matched to the next push slot — and
			// falls through to the positional branch below; that distinction is why the
			// resolve happens in the guard, not here.) Walk the child carve with the
			// field's Reference threaded in as its source (a self-mention into the carved
			// scope, exactly what `.z` produces).
			src_node := child_data.carve.source
			cname := span_str(ast, ast.node_data[src_node].identifier.name)
			cordinal := ast.node_data[src_node].identifier.ordinal
			carve_scope := shorthand_field
			carve_index := shorthand_idx

			// The self-source for the inner carve: a Reference into the carved field,
			// identical to what a `.z` property yields (see walk_property).
			ref_self := new(Reference)
			ref_self^ = Reference {
				cname,
				cordinal >= 0 ? Maybe(u64)(u64(cordinal)) : nil,
				carve_scope,
				carve_index,
			}
			self_src := new(Type)
			self_src^ = Reference_Type{nil, ref_self}

			val := walk_carve(a, current_scope, child, self_src)
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
							node_span(a, child),
						)
					}
				}
			}
			append(
				refs,
				Reference {
					cname,
					cordinal >= 0 ? Maybe(u64)(u64(cordinal)) : nil,
					carve_scope,
					carve_index,
				},
			)
			append(vals, val)
		} else {
			carve_scope: ^Scope_Type = nil
			carve_index := -1
			cname := ""
			// A positional carve targets ONLY the Pointing_Push fields, in order —
			// pulls/events/resonance/reactive/products/expands are not positional
			// parameters (a pull is extracted, and the others are carved by name with
			// their own operator). So the k-th positional value goes to the k-th
			// Pointing_Push field, skipping everything else.
			if src_scope != nil {
				idx := nth_pointing_push(src_scope, positional_idx)
				if idx >= 0 {
					cname = src_scope.names[idx]
					carve_scope = src_scope
					carve_index = idx
				}
			}
			if carve_scope == nil {
				sem_error(
					a,
					"positional carve out of range: the scope has fewer pushable (->)  fields",
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
			append(refs, Reference{nil, nil, carve_scope, carve_index})
			append(vals, val)
			positional_idx += 1
		}
	}
}

// carve_check runs the whole-carve proofs, shared by the immediate path
// (walk_carve) and the deferred one (close_carve).
carve_check :: proc(a: ^Analyzer, carve: ^Type, idx: Node_Index) {
	// Pull unification conflict: a pull mentioned in two fields' constraints
	// (`data{e}:somedata` + `data{e}:someother`) carved with values that disagree
	// (`a{data{6} data{3}}` → e = 6 then 3) is an error — all bindings of a pull
	// must agree on one value.
	if conflict, has := carve_pull_conflict(carve); has {
		display := conflict.pull_name != "" ? fmt.tprintf("'%s'", conflict.pull_name) : "a pull"
		sem_error(
			a,
			fmt.tprintf(
				"pull conflict: %s is unified to both %s and %s in this carve",
				display,
				describe_type(fold_value_type(conflict.first)),
				describe_type(fold_value_type(conflict.second)),
			),
			.Constraint_Mismatch,
			node_span(a, idx),
		)
	}

	// Implicit constraints: substituting an override can break a constraint on
	// another field that (transitively) references it — `u8:z -> x+y` no longer
	// fits u8 once x is carved out of range. fold_carve materializes the
	// substituted scope; we re-prove every colored binding against its now-
	// substituted value and report the mismatch at the carve site.
	recheck_carve(a, carve, idx)
}

// close_carve finishes a carve whose source awaited a scope's close: the source
// is resolvable now, so resolve the references, walk the overrides, and run the
// proofs — everything walk_carve would have done inline. A source that is
// STILL blocked (chained into an outer open scope) re-queues.
close_carve :: proc(a: ^Analyzer, p: Pending) {
	cv, cv_ok := &p.carve^.(Carve_Type)
	if !cv_ok do return
	if open := pending_scope_of(cv.source); open != nil {
		np := p
		np.awaiting = open
		append(&a.pending, np)
		return
	}
	src_scope := carve_source_scope(cv.source)
	if src_scope == nil {
		// The source did not resolve to a scope after all (e.g. the deferred
		// property turned out missing — already reported there). Nothing to
		// resolve the overrides against.
		return
	}
	carve_resolve_children(a, p.scope, p.node, src_scope, p.carve)
	carve_check(a, p.carve, p.node)
}

// recheck_carve folds a carve to its substituted scope and re-proves each
// colored binding (constraint vs the substituted value's fold). The per-field
// inline check above only covers the directly-overridden fields; this covers the
// implicit constraints — fields whose value depends on what was carved.
recheck_carve :: proc(a: ^Analyzer, carve: ^Type, node: Node_Index) {
	saved_span := a.recheck_span
	a.recheck_span = node_span(a, node)
	defer a.recheck_span = saved_span
	sub := fold_carve(carve)
	if sub == nil do return
	// Fields DIRECTLY overridden by the carve are already proven inline by
	// walk_carve (the explicit "constraint mismatch in carve 'x'") — skip them here
	// so a direct violation isn't reported twice as a (mislabeled) "implicit" one.
	// recheck_carve only covers the DEPENDENT fields (value references a carved one).
	overridden := make(map[int]bool)
	if cv, ok := carve^.(Carve_Type); ok {
		for ref in cv.references do overridden[ref.match_index] = true
	}
	for i in 0 ..< len(sub.names) {
		if overridden[i] do continue
		fc := i < len(sub.constraint_folds) ? sub.constraint_folds[i] : nil
		if fc == nil do continue
		ft := fold_value_type(sub.types[i])
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
walk_pattern :: #force_inline proc(
	a: ^Analyzer,
	current_scope: ^Scope_Type,
	idx: Node_Index,
) -> ^Type {
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
walk_execute :: #force_inline proc(
	a: ^Analyzer,
	current_scope: ^Scope_Type,
	idx: Node_Index,
) -> ^Type {
	data := a.ast.node_data[idx]
	target := walk(a, current_scope, data.execute.target)
	result := new(Type)
	result^ = Execute_Type{target}
	return result
}

// `@name` — an external. Opaque to static analysis, so Unknown_Type.
walk_external :: #force_inline proc(
	a: ^Analyzer,
	current_scope: ^Scope_Type,
	idx: Node_Index,
) -> ^Type {
	return make_unknown()
}

walk_branch :: #force_inline proc(
	a: ^Analyzer,
	current_scope: ^Scope_Type,
	idx: Node_Index,
) -> ^Type {
	return make_unknown()
}

walk_unknown :: #force_inline proc(
	a: ^Analyzer,
	current_scope: ^Scope_Type,
	idx: Node_Index,
) -> ^Type {
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
	// Unsigned families already get 0 from the structural fallback (lo = 0). The
	// SIGNED families and `int` carry an EXPLICIT 0 default so a bare `i8` (or any
	// `&`/`|` that keeps it as the left term) defaults to 0 instead of its low
	// bound; this default then propagates through the fold like any other.
	builtins["u8"] = make_int_range(0, 255)
	builtins["i8"] = make_int_range_default(-128, 127, 0)
	builtins["u16"] = make_int_range(0, 65535)
	builtins["i16"] = make_int_range_default(-32768, 32767, 0)
	builtins["u32"] = make_int_range(0, 4294967295)
	builtins["i32"] = make_int_range_default(-2147483648, 2147483647, 0)
	builtins["u64"] = make_int_range(0, 18446744073709551615)
	builtins["i64"] = make_int_range_default(-9223372036854775808, 9223372036854775807, 0)
	builtins["f32"] = make_float_range(nil, nil, .f32)
	builtins["f64"] = make_float_range(nil, nil, .f64)
	builtins["int"] = make_int_range_default(nil, nil, 0)
	builtins["float"] = make_float_range(nil, nil, .none)
	builtins["string"] = make_string_any()
	builtins["char"] = make_char_any()
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

	res_scope, res_index := scope_resolve(scope, name, ordinal, true, allow_capture = true)
	if res_scope != nil {
		// A mention of a binding whose value is a scope STILL BEING WALKED is a
		// self mention (`Array` inside Array's body, `fib` inside fib, or `a`
		// naming itself from an inner scope): record it as an explicit
		// Recursive_Mention instead of a plain Mention, so folds defer through it,
		// the satisfy layer detects the inductive step structurally, and it
		// survives carve cloning (repoint never rewrites it). match_scope/index
		// point at the self binding directly — its value IS the open scope.
		if val := res_scope.types[res_index]; val != nil {
			if vs, is_scope := &val^.(Scope_Type); is_scope && vs.walking {
				result := new(Type)
				result^ = Recursive_Mention_Type {
					name        = name,
					match_scope = res_scope,
					match_index = res_index,
				}
				return result
			}
		}
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

	sem_error(
		a,
		fmt.tprintf("'%s' is not defined", name),
		.Undefined_Identifier,
		node_span(a, idx),
	)
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
sem_error :: proc(s: ^Analyzer, message: string, error_type: Analyzer_Error_Type, span: Span) {
	error := Analyzer_Error {
		type     = error_type,
		message  = message,
		span     = span,
		position = span_to_position(s.ast, span.start),
	}
	append(&s.errors, error)
}

sem_warning :: proc(s: ^Analyzer, message: string, error_type: Analyzer_Error_Type, span: Span) {
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
