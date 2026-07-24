package compiler

import "base:runtime"
import "core:fmt"
import "core:strconv"

// The analyzer turns the AST into a tree of `Type`, proving for every binding
// `c : … -> v` that `fold_type(v) ⊆ fold_constraint(c)` (the proof lives in the
// domain files, dispatched from type.odin). References never copy a value; they
// carry (scope, index) back to the definition and are chased lazily by `follow()`.

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
	// The constraint itself depends on a `??`, so it denotes no static set
	// (distinct from Constraint_Mismatch, where a known constraint fails).
	Insoluble_Constraint,
	// A pattern whose branches do not cover the whole target and has no `->` default.
	Non_Exhaustive_Pattern,
	Default,
}

Analyzer_Error :: struct {
	type:     Analyzer_Error_Type,
	message:  string,
	// `span` is the byte range to underline; `position` its start as (line, col).
	span:     Span,
	position: Position,
}


// Per-file analysis state. Reachable from deep fold helpers via current_analyzer(),
// which reads the Phase_Context on context.user_ptr. TRAP: reduce also re-enters the
// fold layer (refold on demand), so context.user_ptr is NEVER a bare ^Analyzer — it is
// a Phase_Context holding both phase handles; always go through current_analyzer()/
// current_reducer(), never cast the pointer directly (see Phase_Context below).
Analyzer :: struct {
	ast:              ^Ast,
	scope:            ^Scope_Type,
	errors:           [dynamic]Analyzer_Error,
	warnings:         [dynamic]Analyzer_Error,
	// During a carve override walk, points at the scope being carved so a
	// source-none property (`.x`) resolves against its original fields; nil
	// otherwise. Saved/restored around each override walk so nested carves nest.
	carved_scope:     ^Scope_Type,
	// Span of the carve being rechecked, so the fold layer anchors its error at the
	// carve site. Set around recheck_carve only.
	recheck_span:     Span,
	// TRAP: these guard stacks live ON the analyzer (not a global) so their backing
	// dies with this pass's arena — a global [dynamic] would keep a stale cap into a
	// destroyed arena (the test runner analyzes on many threads). Strictly balanced.
	// scope_scan_stack guards the Scope/Carve constraint field scan against a
	// self-referential constraint (`A -> {x -> A}`): the outermost scan decides.
	scope_scan_stack: [dynamic]^Type,
	// carve_fold_stack guards fold_carve against re-entering the SAME carve node
	// (a self-referential carve): inner re-entry bails to nil. Distinct nodes pass.
	carve_fold_stack: [dynamic]^Type,
	// execute_stack guards folding a recursive collapse: each Execute fold pushes the
	// underlying scope its target resolves through (stable across carve clones);
	// re-entry bails to nil.
	execute_stack:    [dynamic]^Scope_Type,
	// `fold_pending` is set by the fold layer when a fold touches a scope still being
	// walked or an unresolved forward Reference: the obligation is queued on
	// `pending` and re-run at that scope's close (scope_close).
	fold_pending:     ^Scope_Type,
	pending:          [dynamic]Pending,
	// Sites whose scope currently carries a refinement override (the values live on
	// each Scope_Type.refine_overrides, keyed by binding index — NOT here, so the
	// fold layer never needs this Analyzer to read one). This set only exists to
	// enumerate the active overrides when a deferred obligation snapshots them.
	active_override_sites: map[Binding_Site]bool,
	// The obligation ledger: one conclusion per (recorded site, error type). A
	// proof re-fires on every materialization; whatever environment concludes
	// FIRST owns the diagnostic — a later re-proof of the same obligation (same
	// site, possibly a different message) never stacks a second one.
	concluded:             map[Obligation_Site]bool,
}

// Obligation_Site identifies one proof obligation for the ledger: the source
// span recorded on the IR at walk time plus the error class.
Obligation_Site :: struct {
	span: Span,
	type: Analyzer_Error_Type,
}

// Identifies a single binding for the refinement-override map.
Binding_Site :: struct {
	scope: ^Scope_Type,
	index: int,
}

// resolve_binding_type returns the domain a binding resolves to during folding: its
// pattern-refined override when one is installed for this branch, else its declared
// type. This is the single hook that makes a refined scrutinee binding visible to
// every domain/constraint fold inside a pattern branch product.
resolve_binding_type :: proc(scope: ^Scope_Type, index: int) -> ^Type {
	if scope == nil || index < 0 do return nil
	if ov := refine_override_for(scope, index); ov != nil do return ov
	if index < len(scope.types) do return scope.types[index]
	return nil
}

// refine_override_for returns the installed refinement override for a binding, or
// nil if none. It reads the SCOPE's own override map — no analyzer, no context —
// so it is safe (and trivially nil) when called from the reducer's fold reuse.
refine_override_for :: proc(scope: ^Scope_Type, index: int) -> ^Type {
	if scope == nil || index < 0 do return nil
	if len(scope.refine_overrides) == 0 do return nil
	if ov, ok := scope.refine_overrides[index]; ok do return ov
	return nil
}

// snapshot_overrides copies the currently-active refinement overrides, to be replayed
// later around a deferred obligation. Returns nil when none are active.
snapshot_overrides :: proc(a: ^Analyzer) -> map[Binding_Site]^Type {
	if a == nil || len(a.active_override_sites) == 0 do return nil
	snap := make(map[Binding_Site]^Type)
	for site in a.active_override_sites {
		if ov, ok := site.scope.refine_overrides[site.index]; ok do snap[site] = ov
	}
	return snap
}

// install_override_snapshot replays a snapshot of branch overrides (taken by
// snapshot_overrides when an obligation was deferred) as an ordinary override
// frame, registering fresh sites on the active set. Undo with
// uninstall_branch_refinement — the same frame law as every other installer.
install_override_snapshot :: proc(a: ^Analyzer, snap: map[Binding_Site]^Type) -> Override_Frame {
	frame: Override_Frame
	if a == nil || len(snap) == 0 do return frame
	for site, v in snap {
		if _, present := site.scope.refine_overrides[site.index]; !present {
			a.active_override_sites[site] = true
		}
		frame_override(&frame, site, v)
	}
	return frame
}

// One deferred obligation, re-run when `awaiting` finishes walking:
//   .Ref       — resolve `rr` against `target`, patching the Reference's match site.
//   .Carve     — re-resolve `carve`'s references, re-run its proofs + recheck_carve.
//   .Typecheck — re-fold/re-prove binding `bind` of `scope`, patching cached folds.
//   .Default   — re-fold a bare-constraint binding and materialize its default.
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
	// Snapshot of the pattern-branch refinement overrides active when this obligation
	// was deferred. A carve inside a pattern branch (`n ? {0->…, -> f{n->n-1}}`)
	// re-proves at scope_close, long after walk_pattern restored the live overrides —
	// so we replay this snapshot around the deferred proof. nil/empty when none.
	overrides: map[Binding_Site]^Type,
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

// analyze walks the root scope's children into the root Scope_Type, leaving the
// result and diagnostics in `cache`. A bare child is an anonymous Pointing_Push.
analyze :: proc(cache: ^Cache) -> bool {
	a := current_analyzer()
	ast := a.ast

	root := ast_root(ast)
	root_data := ast.node_data[root]
	r := root_data.scope
	children := ast.extra[r.start:][:r.len]
	a.scope.walking = true
	walk_scope_children(a, a.scope, children)

	a.scope.walking = false
	scope_close(a, a.scope)
	// Nothing may survive the root's close: a leftover is a reference that never
	// became resolvable — report it rather than silently dropping it.
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

node_span :: proc(a: ^Analyzer, idx: Node_Index) -> Span {
	// A missing node (INVALID_NODE, e.g. an empty carve target `n->`) has no span;
	// fall back to an empty span so a diagnostic never indexes out of range.
	if idx == INVALID_NODE || int(idx) >= len(a.ast.node_spans) do return Span{}
	return a.ast.node_spans[idx]
}

node_pos :: proc(a: ^Analyzer, idx: Node_Index) -> Position {
	if idx == INVALID_NODE || int(idx) >= len(a.ast.node_spans) do return Position{}
	return span_to_position(a.ast, a.ast.node_spans[idx].start)
}

// walk_scope_children walks a scope's child nodes IN ORDER, deciding for each what
// the form IS in binding position — the ONE place that law lives (the root, scope
// literals, and bound scope bodies all walk through here):
//   * a directional binding / production / expand registers itself (walk);
//   * a bare colored form `C:name` registers a binding holding C's default;
//   * a colored carve `C:name{…}` (a Carve whose source is a Constraint — the
//     parser wraps the whole colored form in the Carve) registers `name` colored
//     by C with the CARVED complete value;
//   * anything else is an anonymous pushed value.
// Everywhere else (pattern covers, carve overrides, operands) the same forms are
// VALUES: walk routes them to their pure walkers and nothing registers.
walk_scope_children :: proc(a: ^Analyzer, scope: ^Scope_Type, children: []Node_Index) {
	for child in children {
		child_kind := a.ast.node_kinds[child]
		if child_kind == .Carve && carve_colored_source(a, child) != INVALID_NODE {
			walk_colored_carve_binding(a, scope, child)
			continue
		}
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
		     .Expand:
			walk(a, scope, child)
		case .Constraint:
			walk_constraint_binding(a, scope, child)
		case:
			value := walk(a, scope, child)
			scope_append(a, scope, "", nil, .Pointing_Push, value)
			typecheck(a, scope, "", nil, .Pointing_Push, value, child)
		}
	}
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

// scope_append pushes one binding onto the parallel columns in lockstep. The two
// *_folds columns are filled separately by typecheck() (or inline), never here.
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
// onto the scope (carves do their own inline). fc denotes a SET, ft a value's
// TYPE; we prove ft ⊆ fc.
typecheck :: proc(
	a: ^Analyzer,
	scope: ^Scope_Type,
	name: string,
	constraint: ^Type,
	bk: Binding_Kind,
	value: ^Type,
	node: Node_Index,
) {
	a.fold_pending = nil
	fc := fold_constraint(constraint)
	ft := fold_type(value)

	append(&scope.constraint_folds, fc)
	append(&scope.type_folds, ft)

	// A fold touched a scope still being walked (recursive/forward ref): queue the
	// proof for that scope's close, where retypecheck re-folds and patches in place.
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

	if carve_of_own_color(constraint, value) do return
	prove_binding(a, fc, ft, name, node)
}

// carve_of_own_color reports whether a binding's value is a carve DERIVED FROM
// its own constraint (`Point:p{x -> 10}` — walk_colored_carve_binding threads the
// constraint in as the carve source). Such a value inhabits its color by
// construction; every possible violation (an override out of color, a dependent
// field broken by an override) is proven at materialization
// (prove_materialized_carve), so the whole-binding proof would only re-report the
// same obligation with a vaguer message.
carve_of_own_color :: proc(constraint, value: ^Type) -> bool {
	if constraint == nil || value == nil do return false
	cv, ok := value^.(Carve_Type)
	return ok && cv.source == constraint
}

// prove_binding is the diagnostic tail shared by typecheck and retypecheck:
// given the two folds, report Insoluble_Constraint / Constraint_Mismatch.
prove_binding :: proc(a: ^Analyzer, fc, ft: ^Type, name: string, node: Node_Index) {
	display := name != "" ? fmt.tprintf("'%s'", name) : "the production"

	// A constraint depending on a `??` folds to Unknown — it denotes no static set.
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

// scope_close drains every obligation that awaited `s` IN INSERTION ORDER (refs
// resolve before the typechecks that read them). An obligation that re-blocks on
// an outer open scope re-queues there; the root's close is the final drain.
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
			// Replay the refinement overrides that were active when this carve was
			// deferred, so a carve inside a pattern branch re-proves with the refined
			// scrutinee domain it was written under.
			saved := install_override_snapshot(a, p.overrides)
			close_carve(a, p)
			uninstall_branch_refinement(a, saved)
		case .Default:
			close_default(a, p)
		}
	}
}

// close_default re-folds a deferred bare constraint and materializes its default
// in place (the deferred counterpart of the inline path in walk_constraint etc.).
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
	if default_is_infinite(fc) {
		sem_error(
			a,
			"infinite default: the constraint's first production recurses into its own grammar — put a terminal production (e.g. `-> {}`) first",
			.Infinite_Recursion,
			node_span(a, p.node),
		)
	}
	value := default_value(fc)
	p.scope.types[p.bind] = value
	if p.bind < len(p.scope.constraint_folds) do p.scope.constraint_folds[p.bind] = fc
	if p.bind < len(p.scope.type_folds) do p.scope.type_folds[p.bind] = value
	if fold_is_unknown(fc) {
		prove_binding(a, fc, value, p.scope.names[p.bind], p.node)
	}
}

// pending_scope_of reports the still-walking scope that blocks resolving through
// `t` (nil when nothing blocks); a carve blocks on whatever blocks its source.
pending_scope_of :: proc(t: ^Type) -> ^Scope_Type {
	cur := t
	for cur != nil {
		cur = follow(cur)
		if cur == nil do return nil
		#partial switch &v in cur^ {
		case Reference_Type:
			// Landing on a Reference here means unresolved. Only a still-walking
			// scope blocks; unresolved against a CLOSED scope is permanently broken
			// (the close already reported it — re-queuing would loop the drain).
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

// close_ref resolves a deferred recursive reference now its scope is complete,
// re-resolving through resolve_property_site. A target still blocked on an outer
// open scope re-queues; a miss against the now-complete scope is the real error.
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

// retypecheck re-runs a deferred binding proof: re-fold both sides and PATCH the
// cached folds in place (reduce reads these columns).
retypecheck :: proc(a: ^Analyzer, scope: ^Scope_Type, bind: int, node: Node_Index) {
	constraint := scope.constraints[bind]
	value := scope.types[bind]
	a.fold_pending = nil
	fc := fold_constraint(constraint)
	ft := fold_type(value)
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
	if carve_of_own_color(constraint, value) do return
	prove_binding(a, fc, ft, scope.names[bind], node)
}

// nth_named returns the index of the rank-th binding named `name` in `scope` (or
// -1), plus whether the scope defines the name AT ALL — the ONE occurrence law
// behind ordinal resolution (`a#1`), the carve default target (rank 0), and carve
// re-resolution against a substituted scope (carve_ref_index).
nth_named :: proc(scope: ^Scope_Type, name: string, rank: int) -> (idx: int, found_any: bool) {
	count := 0
	for i := 0; i < len(scope.names); i += 1 {
		if scope.names[i] != name do continue
		found_any = true
		if count == rank do return i, true
		count += 1
	}
	return -1, found_any
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
		idx, found_any := nth_named(scope, name, int(ordinal))
		if idx >= 0 do return scope, idx
		// Like the unordered case, walk up to an ancestor — but only when THIS scope
		// does not define the name at all. A scope that defines `d` shadows ancestors;
		// an out-of-range ordinal there is unresolved, not a jump to the parent's `d`.
		if !found_any && scope.parent != nil {
			return scope_resolve(scope.parent, name, ordinal, last, allow_capture)
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
		if idx, _ := nth_named(scope, name, 0); idx >= 0 {
			return scope, idx
		}
	}

	// Capture fallback: a `(e)` capture is an INVISIBLE alias — not in `names`, only
	// referenceable by mention (allow_capture, set by walk_identifier only). Searched
	// after visible names in THIS scope so a visible name wins and it stays scope-local.
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

// nth_pointing_push returns the index of the k-th Pointing_Push binding (or -1).
// Used by positional carves, which only target the pushable (`->`) fields.
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

// self_resolve locates a field for a self-mention (`.x`) in the carved scope.
// Unlike scope_resolve it never walks up to the parent — `.` names *this* scope.
self_resolve :: proc(scope: ^Scope_Type, name: string, ordinal: i16) -> (^Scope_Type, int) {
	if ordinal >= 0 && name == "" {
		if int(ordinal) < len(scope.types) {
			return scope, int(ordinal)
		}
		return nil, -1
	}
	rank := ordinal >= 0 ? int(ordinal) : 0
	if idx, _ := nth_named(scope, name, rank); idx >= 0 {
		return scope, idx
	}
	return nil, -1
}

// follow chases indirections (Mention/Reference) to the value they ultimately
// bind, transitively. A non-indirection or dangling indirection returns unchanged.
follow :: proc(t: ^Type) -> ^Type {
	// TRAP: a self-referential chain (`a -> b; b -> a`) cycles forever unguarded.
	// We detect re-visiting the EXACT same binding site (a cycle is a valid
	// construction, not an error) and stop there. The visited set is built lazily.
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
			// Follow like a Mention; the scope pointer is valid even while incomplete
			// (consumers check `walking`).
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

// Follow_Key identifies a binding site; re-visiting one while following IS the cycle.
Follow_Key :: struct {
	scope: ^Scope_Type,
	index: int,
}

// walk is the AST→IR dispatcher: it routes each Node_Kind to its walk_<kind>
// handler. Binding/constraint nodes register into `current_scope` and return the
// bound value; expression nodes are pure. walk owns only the INVALID_NODE guard.
walk :: proc(a: ^Analyzer, current_scope: ^Scope_Type, idx: Node_Index) -> ^Type {
	if idx == INVALID_NODE {
		// A missing node (incomplete source) is INVALID, not the value `none`.
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

// make_invalid: the error sentinel. Distinct from None_Type, the value `none`.
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
	// Build the scope IN PLACE inside its ^Type node: the address the children's
	// mentions resolve to (match_scope) IS the address every later consumer keys
	// on (follow/fold/carve repoint) — one identity. Building in a working struct
	// and copying it into the node afterwards left two addresses for one scope,
	// and clone-based substitutions missed the internal mentions.
	result := new(Type)
	result^ = Scope_Type{}
	scope := &result^.(Scope_Type)
	scope.parent = current_scope
	scope.walking = true
	r := data.scope
	children := ast.extra[r.start:][:r.len]
	walk_scope_children(a, scope, children)
	scope.walking = false
	scope_close(a, scope)
	return result
}

// A directional binding `lhs <op> rhs`. The left is a bare name or a
// `constraint : name` form. When the right is a scope literal we register the
// binding *before* walking the body, so the body can refer back to it.
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
		constraint = walk(a, current_scope, cdata.binary.left)
		n_ok: bool
		name, capture, n_ok = colored_name(a, cdata.binary.right)
		if !n_ok do return make_invalid()
	} else if left_kind == .Identifier {
		name = span_str(ast, ast.node_data[left_idx].identifier.name)
		capture = span_str(ast, ast.node_data[left_idx].identifier.capture)
	} else {
		// The left of a binding must name a binding, not a scope/literal/expression.
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
		walk_scope_children(a, scope, scope_children)
		// Close the scope BEFORE the binding's own proof, so that proof sees the
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

// `-> X` produces ONE entry, the scope's production. A colored production
// (`-> u8:3`) carries the constraint; we peel it here rather than route through
// walk_constraint (which would append its own binding and double the entry).
walk_product :: #force_inline proc(
	a: ^Analyzer,
	current_scope: ^Scope_Type,
	idx: Node_Index,
) -> ^Type {
	ast := a.ast
	data := ast.node_data[idx]
	operand_idx := data.unary.operand
	if operand_idx == INVALID_NODE {
		// `->` with no operand (incomplete source, e.g. `{->}` mid-edit): walk the
		// missing node (returns INVALID) rather than indexing node_kinds[INVALID_NODE],
		// then append it exactly as the normal path would.
		value := walk(a, current_scope, operand_idx)
		scope_append(a, current_scope, "", nil, .Product, value)
		typecheck(a, current_scope, "", nil, .Product, value, idx)
		return value
	}
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

// `...expr` expansion. A valueless expand (`...u8:`) materializes the constraint's
// default (there is no value expression to typecheck against).
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
		// `...C:name` / `...C:(r)`: the Constraint's right is the binding NAME
		// (possibly a bare capture), exactly as in walk_constraint — never a value.
		if cdata.binary.right != INVALID_NODE &&
		   ast.node_kinds[cdata.binary.right] == .Identifier {
			name := span_str(ast, ast.node_data[cdata.binary.right].identifier.name)
			capture := span_str(ast, ast.node_data[cdata.binary.right].identifier.capture)
			return append_bare_constraint(a, current_scope, name, constraint, .Expand, idx, capture)
		}
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
	// A bare captured tail `...(r)`: an anonymous UNCONSTRAINED Expand binding
	// whose capture swallows the rest of the run (its domain is inferred from the
	// scrutinee's grammar by stamp_cover_tail_domain). Walking the identifier as a
	// value would wrongly resolve `r` as a mention.
	if ast.node_kinds[operand_idx] == .Identifier {
		iname := span_str(ast, ast.node_data[operand_idx].identifier.name)
		icap := span_str(ast, ast.node_data[operand_idx].identifier.capture)
		if icap != "" && iname == "" {
			return append_bare_constraint(a, current_scope, "", nil, .Expand, idx, icap)
		}
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

// colored_name extracts the binding name (and optional `(e)` capture) from the
// right of a `constraint : name` form. INVALID_NODE (an anonymous `C:`) is valid.
// Anything else must be an identifier — or a bare `(e)` capture: an ANONYMOUS
// captured binding (no name; invisible to `.` and carving, reachable only by
// mention, like any capture). ok=false reports Invalid_Constraint_Name.
colored_name :: proc(a: ^Analyzer, name_idx: Node_Index) -> (name, capture: string, ok: bool) {
	if name_idx == INVALID_NODE do return "", "", true
	ast := a.ast
	if ast.node_kinds[name_idx] == .Identifier {
		name = span_str(ast, ast.node_data[name_idx].identifier.name)
		capture = span_str(ast, ast.node_data[name_idx].identifier.capture)
	}
	if name == "" && capture == "" {
		sem_error(
			a,
			"invalid constraint name: the colored name must be an identifier",
			.Invalid_Constraint_Name,
			node_span(a, name_idx),
		)
		return "", "", false
	}
	return name, capture, true
}

// A bare colored form `c : name` in VALUE position (a pattern cover, an operand):
// PURE — the form denotes the constraint's materialized default, and nothing is
// registered anywhere. A `.Constraint` CHILD of a scope is a binding and goes
// through walk_scope_children → walk_constraint_binding instead: registration is
// the caller's decision, not a side effect of evaluating the form.
walk_constraint :: #force_inline proc(
	a: ^Analyzer,
	current_scope: ^Scope_Type,
	idx: Node_Index,
) -> ^Type {
	data := a.ast.node_data[idx]
	constraint := walk(a, current_scope, data.binary.left)
	if _, _, ok := colored_name(a, data.binary.right); !ok {
		return make_invalid()
	}
	value, _, _ := materialize_bare_constraint(a, constraint, idx)
	return value
}

// walk_constraint_binding registers the binding a bare colored form denotes when
// it stands as a scope child: `C:name` — create `name`, color it by C, value =
// C's materialized default.
walk_constraint_binding :: proc(
	a: ^Analyzer,
	scope: ^Scope_Type,
	idx: Node_Index,
) -> ^Type {
	data := a.ast.node_data[idx]
	constraint := walk(a, scope, data.binary.left)
	name, capture, ok := colored_name(a, data.binary.right)
	if !ok do return make_invalid()
	return append_bare_constraint(a, scope, name, constraint, .Pointing_Push, idx, capture)
}

// materialize_bare_constraint folds a constraint and materializes its default —
// the PURE half of a bare colored form, shared by the registering path
// (append_bare_constraint) and value positions (walk_constraint, pattern covers).
// When the fold touches a still-walking scope, `pend` names the scope to await and
// the value is the constraint node itself as a placeholder.
materialize_bare_constraint :: proc(
	a: ^Analyzer,
	constraint: ^Type,
	node: Node_Index,
) -> (
	value: ^Type,
	fc: ^Type,
	pend: ^Scope_Type,
) {
	a.fold_pending = nil
	fc = fold_constraint(constraint)
	if default_is_infinite(fc) {
		sem_error(
			a,
			"infinite default: the constraint's first production recurses into its own grammar — put a terminal production (e.g. `-> {}`) first",
			.Infinite_Recursion,
			node_span(a, node),
		)
	}
	value = default_value(fc)
	if pend = a.fold_pending; pend != nil {
		a.fold_pending = nil
		// TRAP: the CONSTRAINT NODE holds the slot until close_default patches in
		// the default — NOT an Unknown_Type, which means `??` and would diagnose
		// every fold over this scope as insoluble.
		value = constraint
	}
	return
}

// append_bare_constraint registers a valueless colored binding: the value is the
// constraint's materialized default, folds cached inline (nothing to prove). When
// the constraint touches a still-walking scope, the fold is deferred to its close.
append_bare_constraint :: proc(
	a: ^Analyzer,
	scope: ^Scope_Type,
	name: string,
	constraint: ^Type,
	bk: Binding_Kind,
	node: Node_Index,
	capture: string = "",
) -> ^Type {
	value, fc, pend := materialize_bare_constraint(a, constraint, node)
	if pend != nil {
		scope_append(a, scope, name, constraint, bk, value, capture)
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
	scope_append(a, scope, name, constraint, bk, value, capture)
	append(&scope.constraint_folds, fc)
	append(&scope.type_folds, value)
	return value
}

// resolve_property_site locates the field a `target.name` access lands on (or
// (nil,-1)). Takes the LAST occurrence of the name (same-name rule). The one place
// property lookup is defined — shared by walk_property and the carve path.
resolve_property_site :: proc(target: ^Type, name: string, ordinal: i16) -> (^Scope_Type, int) {
	prop_target := follow(target)
	for prop_target != nil {
		#partial switch &t in prop_target^ {
		case Scope_Type:
			return scope_resolve(&t, name, ordinal, true)
		case Carve_Type:
			// Resolve against the SUBSTITUTED scope, not the raw source: `b.z` where
			// b = a{x->10} and z -> x must see z = 10, not the pre-carve a.z = 0.
			if sub := fold_carve_type(prop_target); sub != nil {
				return scope_resolve(sub, name, ordinal, true)
			}
		}
		break
	}
	return nil, -1
}

// `target.prop` — resolve `prop` against the scope `target` denotes.
walk_property :: #force_inline proc(
	a: ^Analyzer,
	current_scope: ^Scope_Type,
	idx: Node_Index,
) -> ^Type {
	ast := a.ast
	data := ast.node_data[idx]
	right_idx := data.binary.right
	// `a.` while typing: missing property name. An incomplete edit is not an error
	// here — the LSP must tolerate it.
	if right_idx == INVALID_NODE {
		return make_invalid()
	}
	// The property side must name a field (ordinals are `#n`, not `.n`).
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

	// Source-none property (`.x`) is a self-mention into the carved scope, reading
	// its *original* value (before this carve's overrides), with no parent walk-up.
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
			node_span(a, right_idx),
		}
		result := new(Type)
		result^ = Reference_Type{nil, ref}
		return result
	}

	target := walk(a, current_scope, data.binary.left)

	prop_scope, prop_index := resolve_property_site(target, prop_name, prop_ordinal)

	if prop_scope == nil {
		// The target chain lands in a still-walking scope (`module.odd` before odd
		// is bound): defer the miss as a recursive reference; only a miss on a
		// COMPLETE scope is a real Invalid_Property_Access.
		if open := pending_scope_of(target); open != nil {
			// Record an UNRESOLVED Reference (match_index -1); the close patches in
			// the resolved (match_scope, match_index).
			ref := new(Reference)
			ref^ = Reference {
				prop_name,
				prop_ordinal >= 0 ? Maybe(u64)(u64(prop_ordinal)) : nil,
				open,
				-1,
				node_span(a, right_idx),
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
		node_span(a, right_idx),
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
	// TRAP: an absent bound stays nil ("no bound"), not None_Type — walk(INVALID_NODE)
	// would yield None_Type, which fold_range and the printer mistake for a real bound.
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

// An operator node. Set-algebra operators (`&`, `|`, ~) become symbolic
// And/Or/Negate nodes; every other operator is arithmetic, folded eagerly into a
// Compose_Type here so a constraint mismatch surfaces at the operation.
walk_operator :: #force_inline proc(
	a: ^Analyzer,
	current_scope: ^Scope_Type,
	idx: Node_Index,
) -> ^Type {
	data := a.ast.node_data[idx]

	// A unary `=x` is pure sugar for the producer scope `{-> x}`, EVERYWHERE: in a
	// pattern branch it is a value-match, in a constraint it means "statically x", and
	// as a bare value it is the producer `{-> x}`. So `=x` == `{-> x}`, no exceptions —
	// built exactly as a source `{-> x}` would (folds via the normal machinery, so the
	// inner value re-reifies just like the hand-written form).
	if data.operator.kind == .Equal && data.operator.left == INVALID_NODE {
		value := walk(a, current_scope, data.operator.right)
		r := new(Type)
		r^ = Scope_Type {
			parent = current_scope,
		}
		scope := &r.(Scope_Type)
		scope_append(a, scope, "", nil, .Product, value)
		typecheck(a, scope, "", nil, .Product, value, idx)
		return r
	}

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

// carve_shorthand_field tells the shorthand carve-of-a-carved-field (`a{z{…}}`)
// apart from a plain positional carve of a foreign scope (`a{data{6}}`). It fires
// ONLY when the child is a `Carve` whose source names a field of src_scope — then
// that field is the override target; otherwise ok=false and it stays positional.
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
	if src_node == INVALID_NODE do return nil, -1, false
	if ast.node_kinds[src_node] != .Identifier do return nil, -1, false
	cname := span_str(ast, ast.node_data[src_node].identifier.name)
	cordinal := ast.node_data[src_node].identifier.ordinal
	// TRAP: self_resolve, NOT scope_resolve — the shorthand targets a DIRECT field
	// only; scope_resolve's parent walk-up would steal a foreign top-level scope.
	fscope, fidx := self_resolve(src_scope, cname, cordinal)
	if fscope == nil do return nil, -1, false
	return fscope, fidx, true
}

// carve_colored_source returns the `.Constraint` node a carve's source holds for
// the colored-carve form `C:name{…}` (the parser wraps the whole colored form in
// the Carve node), or INVALID_NODE for a plain carve.
carve_colored_source :: proc(a: ^Analyzer, carve_idx: Node_Index) -> Node_Index {
	src := a.ast.node_data[carve_idx].carve.source
	if src != INVALID_NODE && a.ast.node_kinds[src] == .Constraint do return src
	return INVALID_NODE
}

// walk_colored_carve_binding registers the binding a colored carve denotes when it
// stands as a scope child: `C:name{…}` — create `name`, color it by C, and derive
// its value by carving C's complete structure with the overrides ("create p,
// constrain p by Point, carve p with x -> 10").
walk_colored_carve_binding :: proc(
	a: ^Analyzer,
	scope: ^Scope_Type,
	idx: Node_Index,
) -> ^Type {
	ast := a.ast
	cnode := carve_colored_source(a, idx)
	cdata := ast.node_data[cnode]
	constraint := walk(a, scope, cdata.binary.left)
	name, capture, ok := colored_name(a, cdata.binary.right)
	if !ok do return make_invalid()
	// An empty carve is the identity derivation, so `C:name{}` IS `C:name`.
	if ast.node_data[idx].carve.children.len == 0 {
		return append_bare_constraint(a, scope, name, constraint, .Pointing_Push, idx, capture)
	}
	value := walk_carve(a, scope, idx, constraint)
	scope_append(a, scope, name, constraint, .Pointing_Push, value, capture)
	typecheck(a, scope, name, constraint, .Pointing_Push, value, idx)
	return value
}

// `source{ … }` — derive a new scope from `source`. source_override, when non-nil,
// replaces the walk of the source node: used for the shorthand carve-of-a-carved-
// field (`a{z{a->2}}`), where `z` is threaded in as a self-mention into the carved
// scope (identical to `.z`) rather than resolving as a plain enclosing mention.
// A COLORED source (`C:name{…}` in value position — a pattern cover, an operand)
// derives from the shape C itself, PURELY: the name registers nothing here; a
// scope child registers through walk_colored_carve_binding instead.
walk_carve :: proc(
	a: ^Analyzer,
	current_scope: ^Scope_Type,
	idx: Node_Index,
	source_override: ^Type = nil,
) -> ^Type {
	ast := a.ast
	data := ast.node_data[idx]
	source: ^Type
	if source_override != nil {
		source = source_override
	} else if cnode := carve_colored_source(a, idx); cnode != INVALID_NODE {
		cdata := ast.node_data[cnode]
		source = walk(a, current_scope, cdata.binary.left)
		if _, _, ok := colored_name(a, cdata.binary.right); !ok {
			return make_invalid()
		}
		// An empty carve is the identity derivation: `C:{}` IS the bare `C:`.
		if data.carve.children.len == 0 {
			value, _, _ := materialize_bare_constraint(a, source, idx)
			return value
		}
	} else {
		source = walk(a, current_scope, data.carve.source)
	}

	result := new(Type)
	result^ = Carve_Type {
		source     = source,
		references = make([dynamic]Reference),
		types      = make([dynamic]^Type),
		span       = node_span(a, idx),
	}

	// A source chaining into a still-walking scope (`module.odd{…}`, or a self-carve
	// `Array{T}` inside Array) has no resolvable fields yet: defer the WHOLE carve to
	// that scope's close. The override expressions are pure, so deferring is equivalent.
	if pending_src := pending_scope_of(source); pending_src != nil {
		append(
			&a.pending,
			Pending {
				kind = .Carve,
				awaiting = pending_src,
				carve = result,
				scope = current_scope,
				node = idx,
				overrides = snapshot_overrides(a),
			},
		)
		return result
	}

	carve_resolve_children(a, current_scope, idx, carve_source_scope(source), result)
	carve_check(a, &result^.(Carve_Type), idx)
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

// carve_resolve_children walks a carve's override children, resolving each against
// src_scope and appending (reference, value) pairs onto the carve IN PLACE. Shared
// by walk_carve and close_carve.
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

	// Point carved_scope at src_scope so a source-none property (`.x`) resolves
	// against it; restore afterwards so nested carves resolve `.` against the nearest.
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

			if name_idx != INVALID_NODE && ast.node_kinds[name_idx] == .Identifier {
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

			// The override proof runs at MATERIALIZATION (prove_materialized_carve)
			// against the SUBSTITUTED constraint (a sibling override may rewrite this
			// field's constraint: `a{T -> u8, source -> …}` proves source against
			// Array{u8}).
			val := walk(a, current_scope, val_idx)
			append(
				refs,
				Reference {
					cname,
					cordinal >= 0 ? Maybe(u64)(u64(cordinal)) : nil,
					carve_scope,
					carve_index,
					node_span(a, child),
				},
			)
			append(vals, val)
		} else if shorthand_field, shorthand_idx, ok := carve_shorthand_field(a, src_scope, child);
		   ok {
			// Shorthand `a{z{a->2}}` == `a{z->.z{a->2}}`: re-carve the carved field `z`.
			// Walk the child carve with the field's Reference threaded in as its source
			// (a self-mention into the carved scope, what `.z` produces).
			src_node := child_data.carve.source
			cname := span_str(ast, ast.node_data[src_node].identifier.name)
			cordinal := ast.node_data[src_node].identifier.ordinal
			carve_scope := shorthand_field
			carve_index := shorthand_idx

			ref_self := new(Reference)
			ref_self^ = Reference {
				cname,
				cordinal >= 0 ? Maybe(u64)(u64(cordinal)) : nil,
				carve_scope,
				carve_index,
				node_span(a, src_node),
			}
			self_src := new(Type)
			self_src^ = Reference_Type{nil, ref_self}

			val := walk_carve(a, current_scope, child, self_src)
			append(
				refs,
				Reference {
					cname,
					cordinal >= 0 ? Maybe(u64)(u64(cordinal)) : nil,
					carve_scope,
					carve_index,
					node_span(a, child),
				},
			)
			append(vals, val)
		} else {
			carve_scope: ^Scope_Type = nil
			carve_index := -1
			cname := ""
			// A positional carve targets ONLY the Pointing_Push fields, in order:
			// the k-th positional value goes to the k-th Pointing_Push field.
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
			append(refs, Reference{nil, nil, carve_scope, carve_index, node_span(a, child)})
			append(vals, val)
			positional_idx += 1
		}
	}

}

// carve_check runs the whole-carve proofs, shared by the immediate path
// (walk_carve) and the deferred one (close_carve).
carve_check :: proc(a: ^Analyzer, carve: ^Carve_Type, idx: Node_Index) {
	// Pull unification conflict: all bindings of a pull must agree on one value.
	if conflict, has := carve_pull_conflict(carve); has {
		display := conflict.pull_name != "" ? fmt.tprintf("'%s'", conflict.pull_name) : "a pull"
		sem_error(
			a,
			fmt.tprintf(
				"pull conflict: %s is unified to both %s and %s in this carve",
				display,
				describe_type(fold_type(conflict.first)),
				describe_type(fold_type(conflict.second)),
			),
			.Constraint_Mismatch,
			node_span(a, idx),
		)
	}

	// Implicit constraints: an override can break a constraint on another field that
	// references it (`u8:z -> x+y` overflows once x is carved out of range).
	recheck_carve(a, carve, idx)
}

// close_carve finishes a deferred carve now its source is resolvable, running
// everything walk_carve would have done inline. A source still blocked re-queues.
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
		// Source did not resolve to a scope (the deferred property was missing —
		// already reported there). Nothing to resolve overrides against.
		return
	}
	carve_resolve_children(a, p.scope, p.node, src_scope, p.carve)
	carve_check(a, cv, p.node)
}

// recheck_carve materializes the carve under this node's armed span so the
// materialization proof (prove_materialized_carve, run by carve_substitute) fires:
// direct overrides AND the implicit constraints — dependent fields whose value
// references a carved one. A source that does NOT materialize (still symbolic)
// can't have changed any color, so each override proves against its FROZEN
// definition color instead — exact, because only a materialization changes colors.
recheck_carve :: proc(a: ^Analyzer, carve: ^Carve_Type, node: Node_Index) {
	saved_span := a.recheck_span
	a.recheck_span = node_span(a, node)
	defer a.recheck_span = saved_span
	if fold_carve_constraint(cast(^Type)carve) != nil do return
	for i in 0 ..< len(carve.references) {
		ref := carve.references[i]
		if ref.match_scope == nil || ref.match_index < 0 do continue
		if ref.match_index >= len(ref.match_scope.constraint_folds) do continue
		prove_carve_override(
			ref.match_scope.constraint_folds[ref.match_index],
			carve.types[i],
			ref,
			carve.span,
		)
	}
}

// prove_materialized_carve is THE carve proof law, run by carve_substitute on
// every materialization: each field of the substituted scope must still inhabit
// its color.
//   * A directly-overridden field proves its override VALUE — the walked original,
//     NOT the clone's repointed refold: an active branch refinement keeps applying
//     to the original's mentions, and a self-referential override (`n -> n-1`)
//     refolds to nothing on the clone. The color is the SUBSTITUTED one (a sibling
//     override may rewrite it: `a{T -> u8, source -> …}` proves source against
//     Array{u8}, not Array{T -> {}}), falling back to the frozen definition color
//     when the substituted one didn't fold.
//   * Every other colored field re-proves its refold — the implicit constraints
//     (`u8:z -> x+y` overflows once x is carved out of range). A nil refold is
//     ambiguous — legally symbolic (`x + 1`) OR incoherent (`"" + 10` after the
//     carve) — detect_invalid emits only for a real error.
// Proving at materialization is what makes the proof compositional: an inner carve
// at ANY depth, under ANY wrapper, re-proves the moment any fold materializes it,
// in the environment that fold established (walk-time branch refinement or
// fold_type_pattern's install_fold_refinement). Recomputed folds re-prove for
// free — emit_at dedups onto the spans recorded at walk. No-op without a live
// analyzer: reduce and rendering materialize without proving.
prove_materialized_carve :: proc(carve: ^Carve_Type, sub: ^Scope_Type) {
	if current_analyzer() == nil do return
	overridden := make(map[int]bool)
	defer delete(overridden)
	for k in 0 ..< len(carve.references) {
		ref := carve.references[k]
		idx := carve_ref_index(ref, sub)
		if idx >= 0 do overridden[idx] = true
		fc: ^Type = nil
		if idx >= 0 && idx < len(sub.constraint_folds) do fc = sub.constraint_folds[idx]
		if fc == nil &&
		   ref.match_scope != nil &&
		   ref.match_index >= 0 &&
		   ref.match_index < len(ref.match_scope.constraint_folds) {
			fc = ref.match_scope.constraint_folds[ref.match_index]
		}
		prove_carve_override(fc, carve.types[k], ref, carve.span)
	}
	for i in 0 ..< len(sub.names) {
		if overridden[i] do continue // proven above as a direct override
		ft := fold_type(sub.types[i])
		if ft == nil {
			detect_invalid(sub.types[i])
			continue
		}
		// The proof applies only to a COLORED field.
		fc := i < len(sub.constraint_folds) ? sub.constraint_folds[i] : nil
		if fc == nil do continue
		if !satisfy_root(fc, ft) {
			display := sub.names[i] != "" ? fmt.tprintf("'%s'", sub.names[i]) : "the production"
			emit_at(
				fmt.tprintf(
					"implicit constraint mismatch: %s does not satisfy %s on %s after carve",
					describe_type(ft),
					describe_type(fc),
					display,
				),
				.Constraint_Mismatch,
				carve.span,
			)
		}
	}
}

// prove_carve_override proves ONE override value against a color. It only
// concludes on conclusive evidence: an unfolded/unknown color, or a still-
// symbolic/placeholder value (fold nil, unknown, or incomparable) is skipped
// rather than false-positived — the obligation is not forgiven, it re-fires at
// the next materialization that resolves the value. A recursive-tail color proves
// inductively via satisfy at its own collapse, not here. Anchors at the override's
// recorded span (fallback: the carve's), so every re-proof dedups onto one site.
prove_carve_override :: proc(fc: ^Type, value: ^Type, ref: Reference, fallback: Span) {
	if fc == nil || is_recursive_tail(fc) || fold_is_unknown(fc) do return
	if value == nil do return
	vf := fold_type(value)
	if vf == nil || fold_is_unknown(vf) do return
	if !value_is_comparable_for_proof(vf) do return
	if satisfy_root(fc, vf) do return
	span := ref.span
	if span.start == 0 && span.end == 0 do span = fallback
	if name, has := ref.name.(string); has {
		emit_at(
			fmt.tprintf(
				"constraint mismatch in carve '%s': %s does not satisfy %s",
				name,
				describe_type(vf),
				describe_type(fc),
			),
			.Constraint_Mismatch,
			span,
		)
	} else {
		emit_at(
			fmt.tprintf(
				"constraint mismatch in positional carve: %s does not satisfy %s",
				describe_type(vf),
				describe_type(fc),
			),
			.Constraint_Mismatch,
			span,
		)
	}
}

// value_is_comparable_for_proof reports whether a folded value can be proven against a
// color: a leaf domain, a set operator, a producer scope, or any NON-EMPTY scope value
// (it proves via scope_satisfy). Only the EMPTY scope is incomparable — it is the
// unresolved capture placeholder, and proving a color against it would false-positive.
value_is_comparable_for_proof :: proc(vf: ^Type) -> bool {
	if vf == nil do return false
	#partial switch v in vf^ {
	case Integer_Type, Float_Type, String_Type, Bool_Type, Range_Type, Or_Type, And_Type, Negate_Type:
		return true
	case Scope_Type:
		return len(v.kind) > 0 || color_is_leaf_domain(vf)
	}
	return false
}

// `target ? { match -> product, … }` — pattern match. Builds a Pattern_Type from
// the (match, product) pairs and proves exhaustiveness. A branch's mode lives in its
// match: `=v -> …` is sugar for the producer `{-> v}` (value-match, fires on equality);
// `c -> …` is a typecheck match; `-> p` is the default branch.
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
	// Covers of earlier branches, accumulated so branch k's product is proven knowing
	// the scrutinee fell through every prior branch (`target & ~M0 & … & M(k-1)`).
	prior_covers := make([dynamic]^Type, 0, len(branch_nodes) / 2)
	defer delete(prior_covers)
	for i := 0; i < len(branch_nodes); i += 2 {
		match_idx := branch_nodes[i]
		product_idx := i + 1 < len(branch_nodes) ? branch_nodes[i + 1] : INVALID_NODE

		match: ^Type = nil
		if match_idx != INVALID_NODE {
			// `=v` in the match walks to the producer `{-> v}` (walk_operator turns the
			// unary `=` into make_producer_scope), so a value-match is just a producer.
			match = walk(a, current_scope, match_idx)
			// A bare trailing `...(r)` in the cover inherits the scrutinee grammar's
			// tail domain (the rest of an Array{T} run IS an Array{T}).
			stamp_cover_tail_domain(match, target)
		}

		// Install the scrutinee refinement for THIS branch before walking its product,
		// so any constraint proof inside the product (e.g. a carve `f{n -> n-1}`) sees
		// the narrowed scrutinee domain. Restored right after.
		this_cover := match != nil ? cover_leaf(fold_constraint(match)) : nil
		installed := install_branch_refinement(a, target, this_cover, prior_covers[:])

		// A branch product is lexically a production OF its cover: walked with a
		// literal scope cover as its scope, the ordinary resolution chain (cover →
		// enclosing scope) makes the cover's bindings and `(e)` captures mentionable
		// from the product — destructuring, with nested patterns nesting for free.
		product_scope := current_scope
		if match != nil {
			if ms, is_scope := &match^.(Scope_Type); is_scope {
				product_scope = ms
			}
		}

		product: ^Type = nil
		if product_idx != INVALID_NODE {
			product = walk(a, product_scope, product_idx)
		} else {
			product = make_none()
		}

		uninstall_branch_refinement(a, installed)
		append(&prior_covers, this_cover)

		append(&branches, build_pattern_branch(match, product))
	}

	result := new(Type)
	result^ = Pattern_Type{target, branches[:]}

	// Exhaustiveness: the branches must cover the whole target (a covering union or
	// an empty-arrow default), else a target value could fall through unmatched.
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

// walk_literal turns a literal token into its single-element domain set (`5` →
// 5..5). An unparseable literal yields Invalid_Type (the parse error is upstream).
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


// The built-in constraints (pre-built domain sets), resolved by name when no
// binding shadows them — a user binding of the same name wins (walk_identifier).
builtins: map[string]Type

@(init)
init_builtins :: proc "contextless" () {
	context = runtime.default_context()
	// Unsigned families get 0 from the structural fallback (lo = 0). The SIGNED
	// families and `int` carry an EXPLICIT 0 default so a bare `i8` defaults to 0,
	// not its low bound; this propagates through the fold like any other.
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
// an ordinal'd reference (`a#1`) produces a Reference_Type, a plain name a
// Mention_Type. Neither bound nor builtin → Undefined_Identifier / Invalid_Type.
walk_identifier :: #force_inline proc(a: ^Analyzer, scope: ^Scope_Type, idx: Node_Index) -> ^Type {
	ast := a.ast
	data := ast.node_data[idx]
	name := span_str(ast, data.identifier.name)
	ordinal := data.identifier.ordinal

	res_scope, res_index := scope_resolve(scope, name, ordinal, true, allow_capture = true)
	if res_scope != nil {
		// A mention of a still-walking scope is a self mention (`fib` inside fib):
		// record an explicit Recursive_Mention so folds defer through it, satisfy
		// detects the inductive step, and it survives carve cloning (repoint never
		// rewrites it).
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
				node_span(a, idx),
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

// Phase_Context is what context.user_ptr points at while a file is processed. It holds
// BOTH phase handles at once, so the two never fight over the single user_ptr slot:
// analyze fills `.analyzer`, reduce fills `.reducer` WITHOUT clearing `.analyzer`. reduce
// legitimately re-enters the analyzer's fold layer (fold_type/fold_constraint through
// repoint/scope_repoint), so `.analyzer` must stay reachable there — this is what lets
// current_analyzer() return the real analyzer during reduce instead of a mis-cast pointer.
// A field's handle is nil when its phase is not live (e.g. `.reducer` during analyze).
Phase_Context :: struct {
	analyzer: ^Analyzer,
	reducer:  ^Reducer,
}

// current_analyzer fetches the in-flight analyzer from the phase context (nil outside a
// pass, or if no analyzer is live).
current_analyzer :: #force_inline proc() -> ^Analyzer {
	pc := cast(^Phase_Context)context.user_ptr
	if pc == nil do return nil
	return pc.analyzer
}

// emit reports an error from the FOLD layer, which has no `^Analyzer`/node threaded
// in, anchored at `a.recheck_span` (the node being re-folded, armed by
// recheck_carve). Outside a pass, or with no armed span, it does nothing —
// detection without a place to report is silent.
emit :: proc(message: string, error_type: Analyzer_Error_Type) {
	emit_at(message, error_type, Span{})
}

// emit_at reports a fold-layer error at an explicit span — the carve / override
// site recorded on the IR at walk time — falling back to the armed recheck_span
// when the span is zero, and staying silent when neither is set (rather than
// anchoring at offset 0).
//
// A fold is a recomputable cache, so the same proof re-fires once per refold —
// possibly under a DIFFERENT environment, wording the failure differently. The
// obligation ledger keys the conclusion on (site, error type): one obligation,
// one diagnostic, whatever each re-proof would have said. Distinct obligations
// at different sites (e.g. a carve override AND its dependent production both
// overflowing) survive untouched. Only a FALLBACK-anchored error (no recorded
// site — the caller passed a zero span) still dedups by exact message: its
// anchor varies with whichever recheck is armed, so the span alone cannot
// identify the obligation.
emit_at :: proc(message: string, error_type: Analyzer_Error_Type, span: Span) {
	a := current_analyzer()
	if a == nil do return
	site_anchored := span.start != 0 || span.end != 0
	s := span
	if !site_anchored {
		s = a.recheck_span
		if s.start == 0 && s.end == 0 do return
	}
	if site_anchored {
		key := Obligation_Site{s, error_type}
		if key in a.concluded do return
		a.concluded[key] = true
	} else {
		for e in a.errors {
			if e.type == error_type && e.span == s && e.message == message do return
		}
	}
	sem_error(a, message, error_type, s)
}

// sem_error / sem_warning take the node's SPAN and resolve its start to a Position
// once, so an Analyzer_Error carries both the byte range and (line, column).
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
