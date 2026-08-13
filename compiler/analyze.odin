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
	ast:                   ^Ast,
	scope:                 ^Scope_Type,
	errors:                [dynamic]Analyzer_Error,
	warnings:              [dynamic]Analyzer_Error,
	// During a carve override walk, points at the scope being carved so a
	// source-none property (`.x`) resolves against its original fields; nil
	// otherwise. Saved/restored around each override walk so nested carves nest.
	carved_scope:          ^Scope_Type,
	// During a UNION cover's product walk (`Square: | Diamond: -> …`), the cover
	// itself; nil otherwise. A name resolved in the cover scope must belong to the
	// common projection — present in EVERY operand. Saved/restored like carved_scope.
	union_cover:           ^Type,
	// Span of the carve being rechecked, so the fold layer anchors its error at the
	// carve site. Set around recheck_carve only.
	recheck_span:          Span,
	// TRAP: these guard stacks live ON the analyzer (not a global) so their backing
	// dies with this pass's arena — a global [dynamic] would keep a stale cap into a
	// destroyed arena (the test runner analyzes on many threads). Strictly balanced.
	// scope_scan_stack guards the Scope/Carve constraint field scan against a
	// self-referential constraint (`A -> {x -> A}`): the outermost scan decides.
	scope_scan_stack:      [dynamic]^Type,
	// carve_fold_stack guards fold_carve against re-entering the SAME carve node
	// (a self-referential carve): inner re-entry bails to nil. Distinct nodes pass.
	carve_fold_stack:      [dynamic]^Type,
	// execute_stack guards folding a recursive collapse: each Execute fold pushes the
	// underlying scope its target resolves through (stable across carve clones);
	// re-entry bails to nil.
	execute_stack:         [dynamic]^Scope_Type,
	// `fold_pending` is set by the fold layer when a fold touches a scope still being
	// walked or an unresolved forward Reference: the obligation is queued on
	// `pending` and re-run at that scope's close (scope_close).
	fold_pending:          ^Scope_Type,
	pending:               [dynamic]Pending,
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
	kind:      Pending_Kind,
	awaiting:  ^Scope_Type,
	rr:        ^Type, // .Ref: the unresolved Reference_Type node to patch
	target:    ^Type, // .Ref: the property's target expression (nil = self-mention)
	carve:     ^Type, // .Carve: the Carve_Type node
	scope:     ^Scope_Type, // .Typecheck: the owning scope
	bind:      int, // .Typecheck: binding index in `scope`
	node:      Node_Index, // diagnostics anchor
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
		case .EventPush:
			// An emit in binding position registers an entry (anonymous, or named when
			// written `name >- E{…}`); in value position walk gives the value alone.
			walk_event_push(a, scope, child)
		case .EventPull:
			// A handler in binding position belongs to THIS scope.
			walk_event_pull(a, scope, child)
		case .Pointing,
		     .PointingPull,
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

// binding_kind_from_node maps a directional node to its Binding_Kind. The event
// pair is absent by design: `>-`/`-<` do not route through walk_binding (the left
// of `-<` names the event it handles, not the binding it defines), so they stamp
// .Event_Push / .Event_Pull themselves — see walk_event_push / walk_event_pull.
binding_kind_from_node :: proc(kind: Node_Kind) -> Binding_Kind {
	#partial switch kind {
	case .Pointing:
		return .Pointing_Push
	case .PointingPull:
		return .Pointing_Pull
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

binding_is_resonance :: #force_inline proc(kind: Binding_Kind) -> bool {
	return kind == .Resonance_Push || kind == .Resonance_Pull
}

// cover_scope: the scope a cover exposes to its branch product. A cover IS a scope,
// so the product is walked inside it and the ordinary resolution chain does the rest.
// A UNION of covers exposes the projection COMMON to its operands — the spec's
// "two shapes unify through a common projection because resolution is structural,
// not nominal" (specs/language/12-patterns.md). Either operand serves that shared
// surface; cover_projects keeps it shared.
cover_scope :: proc(match: ^Type) -> ^Scope_Type {
	if match == nil do return nil
	#partial switch &m in match^ {
	case Scope_Type:
		return &m
	case Or_Type:
		s := cover_scope(m.left)
		if s == nil do s = cover_scope(m.right)
		return s
	}
	return nil
}

// cover_projects reports whether `name` belongs to a cover's common projection: it
// must resolve in EVERY operand of a union, and in the scope itself otherwise. A
// name only one operand defines is not readable — the scrutinee might be the other
// shape, and resolving positionally would read a different field under that name.
cover_projects :: proc(match: ^Type, name: string) -> bool {
	if match == nil do return false
	#partial switch &m in match^ {
	case Scope_Type:
		idx, _ := nth_named(&m, name, 0)
		return idx >= 0
	case Or_Type:
		return cover_projects(m.left, name) && cover_projects(m.right, name)
	}
	return false
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
	// The slot stays valueless (it stated no value): only the color and the cached read
	// of it are filled in. A cover CAPTURE keeps a materialized placeholder, by the same
	// rule append_bare_constraint applies.
	if p.bind < len(p.scope.captures) && p.scope.captures[p.bind] != "" {
		p.scope.types[p.bind] = value
	}
	if p.bind < len(p.scope.constraint_folds) do p.scope.constraint_folds[p.bind] = fc
	if p.bind < len(p.scope.type_folds) do p.scope.type_folds[p.bind] = value
	if p.bind < len(p.scope.captures) {
		mark_unresolved_capture(p.scope, p.bind, p.scope.captures[p.bind], value)
	}
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
		case Execute_Type:
			// A collapse blocks on whatever blocks its target — `mod.f{...}!.x`
			// before `f` is bound must defer, not miss.
			cur = v.target
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
		// A broken target's own diagnostic already fired; re-reporting the field miss
		// would cascade one root cause into two.
		if !is_broken(p.target) {
			sem_error(
				a,
				fmt.tprintf("property '%s' does not exist", prop_name),
				.Invalid_Property_Access,
				node_span(a, p.node),
			)
		}
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

// slot_is_handler reports whether a binding slot is a HANDLER (`E -< e {…}`). Its
// `constraints` entry is the EVENT IT HANDLES — a nominal KEY, not a color — so
// every constraint proof must skip such a slot: proving a handler's body against
// the shape of the event it interprets is a category error, not a mismatch.
slot_is_handler :: #force_inline proc(scope: ^Scope_Type, i: int) -> bool {
	return scope != nil && i >= 0 && i < len(scope.kind) && scope.kind[i] == .Event_Pull
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

// refined_slot_value reads the value follow should chase through a binding: a live
// pattern-branch refinement when one is installed, else the stored value. Inside
// `shape ? {Circle -> …}` the scrutinee IS a Circle for that branch, so every
// consumer that follows the mention — property resolution, carve target resolution
// — must see the narrowed shape, not the declared union. Outside a branch no
// override exists and this is exactly slot_value.
refined_slot_value :: #force_inline proc(scope: ^Scope_Type, index: int) -> ^Type {
	if ov := refine_override_for(scope, index); ov != nil do return ov
	return slot_value(scope, index)
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
			next = refined_slot_value(v.match_scope, v.match_index)
		case Reference_Type:
			r := v.reference
			if r == nil || r.match_scope == nil || r.match_index < 0 do return cur
			key = Follow_Key{r.match_scope, r.match_index}
			next = refined_slot_value(r.match_scope, r.match_index)
		case Recursive_Mention_Type:
			// Follow like a Mention; the scope pointer is valid even while incomplete
			// (consumers check `walking`).
			if v.match_scope == nil || v.match_index < 0 do return cur
			key = Follow_Key{v.match_scope, v.match_index}
			next = slot_value(v.match_scope, v.match_index)
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
	     .ResonancePush,
	     .ResonancePull,
	     .ReactivePush,
	     .ReactivePull:
		return walk_binding(a, current_scope, idx)
	case .EventPush:
		// In VALUE position an emit is just the value it denotes; only in binding
		// position (walk_scope_children) does it register an entry.
		return walk_emit_value(a, current_scope, idx)
	case .EventPull:
		// In VALUE position a handler registers nowhere — it is the interpretation
		// itself, which a carve override then installs on the scope it derives.
		return walk_event_pull(a, current_scope, idx, register = false)
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
	case .Foreign:
		return walk_foreign(a, current_scope, idx)
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

// is_broken reports whether a value resolves to the ERROR SENTINEL — the marker
// that a diagnostic already fired at its own site. Consumers check it to stay
// silent rather than cascade one root cause into several. A carve of a broken
// source is itself broken: deriving from nothing yields nothing.
is_broken :: proc(t: ^Type) -> bool {
	cur := t
	for cur != nil {
		r := follow(cur)
		if r == nil do return false
		#partial switch v in r^ {
		case Invalid_Type:
			return true
		case Carve_Type:
			cur = v.source
			continue
		}
		return false
	}
	return false
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

// `<libm.so.6>{ sqrt -> { f64:x  -> ??::f64 } }` — a foreign scope. The body is
// walked by the ORDINARY scope machinery: a declared symbol is just a binding whose
// value is a scope, its inputs are colored bindings and its production an unknown
// cast into the result layout. Nothing here is special-cased — the only addition is
// stamping the provenance on the scope, which is what marks every collapse through
// it as crossing the external frontier.
walk_foreign :: #force_inline proc(
	a: ^Analyzer,
	current_scope: ^Scope_Type,
	idx: Node_Index,
) -> ^Type {
	ast := a.ast
	data := ast.node_data[idx]
	body := data.foreign_lib.scope
	// A provenance with no block declares nothing (the parser already reported it).
	if body == INVALID_NODE do return make_invalid()

	result := walk(a, current_scope, body)
	// The body is a scope literal, so this holds; on a malformed body walk returned
	// Invalid and there is nothing to stamp.
	if scope, ok := &result^.(Scope_Type); ok {
		scope.foreign_lib = span_str(ast, data.foreign_lib.lib)
	}
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
		if binding_is_resonance(bk) {
			// The RHS of resonance names the nominal event/update channel. It is
			// deliberately not proved against the writable formal's value color.
			append(&current_scope.constraint_folds, fold_constraint(constraint))
			append(&current_scope.type_folds, fold_type(result))
		} else {
			typecheck(a, current_scope, name, constraint, bk, result, idx)
		}
		return result
	}
	value := walk(a, current_scope, right_idx)
	scope_append(a, current_scope, name, constraint, bk, value, capture)
	if binding_is_resonance(bk) {
		// Resonance's RHS is an event identity, not the value inhabiting the
		// writable formal. The actual value is supplied by a later carve/call.
		append(&current_scope.constraint_folds, fold_constraint(constraint))
		append(&current_scope.type_folds, fold_type(value))
	} else {
		typecheck(a, current_scope, name, constraint, bk, value, idx)
	}
	return value
}

// ============================================================================
// NOMINAL EVENTS — `>-` emit / `-<` handle
//
// An event is an ORDINARY data scope (`Log -> {string:message}`) used as the
// nominal key of a handler. Nominality needs no marker on the type: it IS the
// identity of the resolved scope (scope_canon), so two structurally identical
// events declared separately never match. Everything else in Syntact stays
// structural; this is the one place identity, not shape, decides.
//
//   Log -< e { -> io.write{e.message}! }   registers a handler for scope Log,
//                                          `e` captures the incoming payload
//   >- Log{message -> "hello"}             emits; resolves to the handler above
//
// Resolution is lexical and static: an emit walks the `parent` chain for the
// nearest `.Event_Pull` whose event scope is the same scope (up to
// materialization) as the emit payload's carve source. Found → the emit IS the
// handler's production, substituted at reduce. Not found → Invalid_Event_Pull.
// Nothing dynamic survives, so the whole flow inlines at compile time.
// ============================================================================

// event_scope_of resolves an event reference (the left of `-<`, or the source of
// an emit's payload carve) to the canonical data scope that identifies it. A bare
// mention of the event and a carve of it both land on the same canonical scope,
// which is exactly the match rule. nil when it does not resolve to a scope.
//
// A producer scope obeys the SAME producer law as constraints (satisfy_root): an
// event named through `Logger:debug`, where `Logger -> { -> {…} }`, denotes what
// Logger PRODUCES, not Logger itself — so both the handler and the emit peel to
// the produced scope and meet on one identity.
event_scope_of :: proc(t: ^Type) -> ^Scope_Type {
	s := carve_source_scope(t)
	if s == nil do return nil
	if prod := produced_scope(s); prod != nil do return scope_canon(prod)
	return scope_canon(s)
}

// produced_scope peels a producer scope to the single scope it produces, or nil
// when it produces nothing, produces a non-scope, or offers a CHOICE of
// productions (several productions denote a set, so there is no single scope to
// read through). This is the structural half of the producer law that
// default_value applies to values and satisfy_root to constraints: `Logger -> {
// -> {u8:n} }` denotes what it PRODUCES, so its fields are the production's.
produced_scope :: proc(s: ^Scope_Type) -> ^Scope_Type {
	found: ^Scope_Type = nil
	for i := 0; i < len(s.kind); i += 1 {
		if s.kind[i] != .Product do continue
		if found != nil do return nil // a choice of productions is not one identity
		prod := follow(s.types[i])
		if prod == nil do return nil
		ps, ok := &prod^.(Scope_Type)
		if !ok do return nil
		found = ps
	}
	return found
}

// walk_event_pull registers a handler: `Event -< e { … }`.
//
// The event is resolved by STANDARD resolution (it is just a name bound to a data
// scope). The capture `e` sits to the RIGHT of `-<` because its scope is the
// handler body alone, so it is installed as the body's own first binding, holding
// the event scope as its value — `e` then resolves through the existing invisible
// capture path and `e.message` is an ordinary projection. At reduce the emit
// overwrites that binding with the real payload.
// Two POSITIONS share this walk, exactly as `>-` shares walk_event_push /
// walk_emit_value:
//   * a scope child (`register`) — the handler belongs to that scope;
//   * a carve override (`register` false) — it SPECIALIZES an inherited handler
//     (`FastLib -> SomeLib{Alloc -< e {…}}`), so it registers nothing and
//     carve_resolve_children installs it on the carve instead.
// `event_value`, when given, is the already-walked event: the carve path must
// resolve it first (to find the slot the override targets) and passing it in keeps
// the event name from being walked — and mis-reported — twice.
walk_event_pull :: proc(
	a: ^Analyzer,
	current_scope: ^Scope_Type,
	idx: Node_Index,
	register := true,
	event_value: ^Type = nil,
) -> ^Type {
	ast := a.ast
	data := ast.node_data[idx]
	event_idx := data.event_pull.from
	body_idx := data.event_pull.to
	capture := span_str(ast, data.event_pull.catch_span)

	if event_idx == INVALID_NODE {
		sem_error(
			a,
			"a handler must name the event it handles: `Event -< e { … }`",
			.Invalid_Event_Pull,
			node_span(a, idx),
		)
		return make_invalid()
	}
	event := event_value != nil ? event_value : walk(a, current_scope, event_idx)
	if body_idx == INVALID_NODE || ast.node_kinds[body_idx] != .ScopeNode {
		sem_error(
			a,
			"a handler's body must be a scope: `Event -< e { -> value }`",
			.Invalid_Event_Pull,
			node_span(a, idx),
		)
		return make_invalid()
	}

	// The event must name a data scope — that scope's identity IS the nominal key.
	// A name that did not resolve at all already reported; only a resolved value of
	// the wrong shape is news here.
	if event_scope_of(event) == nil {
		if is_broken(event) do return make_invalid()
		sem_error(
			a,
			"the left of `-<` must name an event scope (a scope declared like `Log -> { string:message }`)",
			.Invalid_Event_Pull,
			node_span(a, event_idx),
		)
		return make_invalid()
	}

	result := new(Type)
	result^ = Scope_Type {
		parent  = current_scope,
		walking = true,
	}
	body := &result.(Scope_Type)
	// Register the handler binding BEFORE walking the body, exactly as walk_binding
	// does, so the body may refer back to it. The event scope is the binding's
	// CONSTRAINT: it records which event this handles without standing in for the
	// handler's own value.
	if register {
		scope_append(a, current_scope, "", event, .Event_Pull, result)
		append(&current_scope.constraint_folds, nil)
		append(&current_scope.type_folds, nil)
	}

	// The payload slot: invisible (no name), reachable only as the capture `e`
	// within this body. Its value is the event scope, so `e.message` typechecks
	// against the event's declared shape before any emit exists.
	if capture != "" {
		scope_append(a, body, "", nil, .Pointing_Push, event, capture)
		append(&body.constraint_folds, nil)
		append(&body.type_folds, nil)
	}

	rdata := ast.node_data[body_idx]
	r := rdata.scope
	walk_scope_children(a, body, ast.extra[r.start:][:r.len])
	body.walking = false
	scope_close(a, body)

	// A handler normally produces explicitly. A resonance update is also a valid
	// terminal continuation: its RHS is the value delivered to the named state
	// channel, so no synthetic Scope_Type mutation is needed.
	if !scope_has_product(body) && !scope_has_resonance_update(body) {
		sem_error(
			a,
			"a handler must produce a value or contain a resonance update (`-<<`)",
			.Invalid_Event_Pull,
			node_span(a, idx),
		)
	}
	return result
}

// scope_has_product reports whether a scope collapses to a value — a `->`
// production, or an `...A` expansion that carries one (the same order law reduce
// applies, so the check agrees with what a collapse would actually find).
scope_has_product :: proc(scope: ^Scope_Type) -> bool {
	for i := 0; i < len(scope.kind); i += 1 {
		if scope.kind[i] == .Product do return true
		if scope.kind[i] == .Expand {
			if s := carve_source_scope(scope.types[i]); s != nil && scope_has_product(s) {
				return true
			}
		}
	}
	return false
}

scope_has_resonance_update :: proc(scope: ^Scope_Type) -> bool {
	if scope == nil do return false
	for kind in scope.kind {
		if kind == .Resonance_Pull do return true
	}
	return false
}

// walk_event_push walks an emit: `>- Event{ … }`, or `name >- Event{ … }` when the
// emitted value is bound (the emit IS a value, so binding it is ordinary).
//
// The payload is an ordinary carve of the event scope, so it walks as one (and
// carve_check already proved its overrides against the event's shape — there is
// no separate structural check to make). Only the handler LOOKUP is new: the
// nearest enclosing `.Event_Pull` keyed on the same canonical scope.
walk_event_push :: proc(a: ^Analyzer, current_scope: ^Scope_Type, idx: Node_Index) -> ^Type {
	ast := a.ast
	data := ast.node_data[idx]
	left_idx := data.binary.left

	value := walk_emit_value(a, current_scope, idx)
	// A bare emit registers itself as an anonymous Event_Push binding; `name >- E{…}`
	// (or `C:name >- E{…}`) binds the emitted value under that name.
	name := ""
	capture := ""
	constraint: ^Type = nil
	if left_idx != INVALID_NODE {
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
			sem_error(
				a,
				"invalid binding name: the left of an emit must be a name",
				.Invalid_Binding_Name,
				node_span(a, left_idx),
			)
			return make_invalid()
		}
	}
	scope_append(a, current_scope, name, constraint, .Event_Push, value, capture)
	typecheck(a, current_scope, name, constraint, .Event_Push, value, idx)
	return value
}

// walk_emit_value resolves an emit to the value it denotes: its handler's
// production with the payload substituted in. This is where the whole nominal
// event mechanism lands — everything else about `>-` is ordinary binding.
walk_emit_value :: proc(a: ^Analyzer, current_scope: ^Scope_Type, idx: Node_Index) -> ^Type {
	ast := a.ast
	data := ast.node_data[idx]
	payload_idx := data.binary.right

	if payload_idx == INVALID_NODE {
		sem_error(
			a,
			"an emit must name the event it emits: `>- Event{ field -> value }`",
			.Invalid_Event_Pull,
			node_span(a, idx),
		)
		return make_invalid()
	}
	payload := walk(a, current_scope, payload_idx)
	event := event_scope_of(payload)
	if event == nil {
		if is_broken(payload) do return make_invalid()
		sem_error(
			a,
			"the right of `>-` must name an event scope, optionally carved: `>- Log{message -> \"hi\"}`",
			.Invalid_Event_Pull,
			node_span(a, payload_idx),
		)
		return make_invalid()
	}

	handler, capture_index := resolve_handler(current_scope, event)
	if handler == nil {
		sem_error(
			a,
			fmt.tprintf(
				"no handler in scope for this event: add a `%s -<` handler in an enclosing scope",
				event_display_name(current_scope, event),
			),
			.Invalid_Event_Pull,
			node_span(a, idx),
		)
		return make_invalid()
	}

	// The emit IS the handler's production, with the payload substituted into the
	// capture slot: a carve of the handler body, collapsed. Reduce then folds it
	// like any other collapse — no residual, no continuation, fully static.
	result := new(Type)
	if capture_index < 0 {
		// A handler that ignores its payload (no capture) needs no substitution.
		result^ = Execute_Type{target = handler, caller_scope = current_scope}
		return result
	}
	carve := new(Type)
	cv := Carve_Type {
		source     = handler,
		references = make([dynamic]Reference),
		types      = make([dynamic]^Type),
		span       = node_span(a, idx),
	}
	append(
		&cv.references,
		Reference {
			name = nil,
			index = Maybe(u64)(u64(capture_index)),
			match_scope = event_handler_scope(handler),
			match_index = capture_index,
			span = node_span(a, idx),
		},
	)
	append(&cv.types, payload)
	carve^ = cv
	result^ = Execute_Type{target = carve, caller_scope = current_scope}
	return result
}

// resolve_handler finds the handler for `event`: the nearest `.Event_Pull`
// binding, walking up the lexical chain, whose event scope is `event` up to
// materialization. Returns the handler body and the index of its payload capture
// slot (-1 when the handler declared no capture).
//
// Within one scope the LAST matching handler wins, mirroring the same-name rule
// that makes a later binding shadow an earlier one; the parent chain is only
// consulted when this scope handles the event nowhere.
resolve_handler :: proc(scope: ^Scope_Type, event: ^Scope_Type) -> (^Type, int) {
	for s := scope; s != nil; s = s.parent {
		if i := scope_handler_index(s, event); i >= 0 {
			return s.types[i], handler_capture_index(s.types[i])
		}
	}
	return nil, -1
}

// scope_handler_index finds the handler THIS scope installs for `event` — the last
// matching `.Event_Pull` slot, by the same rule resolve_handler applies within a
// scope. -1 when this scope handles the event nowhere. Split out because a carve
// override targets the CARVED scope's own handler and must not walk up: an
// enclosing handler is not a field of the scope being derived.
scope_handler_index :: proc(s: ^Scope_Type, event: ^Scope_Type) -> int {
	if s == nil || event == nil do return -1
	for i := len(s.kind) - 1; i >= 0; i -= 1 {
		if s.kind[i] != .Event_Pull do continue
		if i >= len(s.constraints) do continue
		if event_scope_of(s.constraints[i]) != event do continue
		return i
	}
	return -1
}

// handler_capture_index locates a handler body's payload slot — the binding
// carrying the `-<` capture. -1 when the handler declared none.
handler_capture_index :: proc(handler: ^Type) -> int {
	h := event_handler_scope(handler)
	if h == nil do return -1
	for i := 0; i < len(h.captures); i += 1 {
		if h.captures[i] != "" do return i
	}
	return -1
}

// event_handler_scope reads a handler binding's value as the scope it is.
event_handler_scope :: proc(handler: ^Type) -> ^Scope_Type {
	if handler == nil do return nil
	if s, ok := &handler^.(Scope_Type); ok do return s
	return nil
}

// event_display_name recovers the source name an event scope was bound to, for
// diagnostics; falls back to a generic word when the event was written inline.
event_display_name :: proc(scope: ^Scope_Type, event: ^Scope_Type) -> string {
	for s := scope; s != nil; s = s.parent {
		for i := 0; i < len(s.names); i += 1 {
			if s.names[i] == "" do continue
			if bound := follow(s.types[i]); bound != nil {
				if bs, ok := &bound^.(Scope_Type); ok && scope_canon(bs) == event {
					return s.names[i]
				}
			}
		}
	}
	return "Event"
}

// `-> X` produces ONE entry, the scope's production. A colored production
// (`-> u8:3`) carries the constraint; we peel it here rather than route through
// walk_constraint (which would double the entry).
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
			return append_bare_constraint(
				a,
				current_scope,
				name,
				constraint,
				.Expand,
				idx,
				capture,
			)
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
walk_constraint_binding :: proc(a: ^Analyzer, scope: ^Scope_Type, idx: Node_Index) -> ^Type {
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
	// An unresolvable color denotes no set at all, so the bare form materializes the
	// error sentinel rather than nothing: the diagnostic already fired at the color
	// itself, and the sentinel keeps every later use of the binding silent.
	if is_broken(constraint) do return make_invalid(), nil, nil
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
		scope_append(a, scope, name, constraint, bk, capture != "" ? value : nil, capture)
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
	// NO VALUE IS STORED: this binding stated none, so its COLOR is the only source
	// of truth and its value is what reading it materializes (slot_value). Baking the
	// default into the slot would freeze it: `maybe{u8}` substitutes T, and a baked
	// `{}` would survive under the new color u8 — a value nobody ever wrote.
	// EXCEPT a cover CAPTURE (`{T:(e) …}`): its slot is a destructuring target, and
	// the placeholder laid down here is what a fired branch replaces with the matched
	// piece — a represented placeholder, never re-derived from a live color (that is
	// the unresolved_captures / capture_color_domain law, which owns the domain a
	// capture reads before it is filled).
	scope_append(a, scope, name, constraint, bk, capture != "" ? value : nil, capture)
	append(&scope.constraint_folds, fc)
	append(&scope.type_folds, value)
	mark_unresolved_capture(scope, len(scope.types) - 1, capture, value)
	return value
}

// mark_unresolved_capture records that a capture slot still holds the cover
// build's own materialization, not a destructured piece. This is the ONE moment
// the distinction is knowable: right here `value` is what WE just laid down —
// nothing (an unbound color) or the shared `{}` default of an unbound pull. Once
// a real value lands in the slot the marker is gone (destructure_cover clears
// it), so a genuine `{}` value is never mistaken for a placeholder again.
mark_unresolved_capture :: proc(scope: ^Scope_Type, index: int, capture: string, value: ^Type) {
	if capture == "" || index < 0 do return
	if value == nil {
		scope.unresolved_captures[index] = true
		return
	}
	if vs, ok := value^.(Scope_Type); ok && len(vs.kind) == 0 {
		scope.unresolved_captures[index] = true
	}
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
		case Execute_Type:
			// `target!.name` — a collapse denotes its production's value: resolve the
			// property against the production it reduces through (a carve production
			// materializes, so the site reads the carved values). Guarded like every
			// collapse fold — a RECURSIVE collapse can't be peeled statically.
			key, blocked := execute_fold_enter(t.target)
			if blocked do return nil, -1
			defer execute_fold_leave(key)
			if prod, resolved := execute_production(t.target); resolved && prod != nil {
				return resolve_property_site(prod, name, ordinal)
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
		// A broken target's own diagnostic already fired (an undefined name, an
		// unresolvable color); re-reporting the field miss would cascade one root
		// cause into two.
		if is_broken(target) do return make_invalid()
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
walk_colored_carve_binding :: proc(a: ^Analyzer, scope: ^Scope_Type, idx: Node_Index) -> ^Type {
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
	// The overrides name fields of what the color DENOTES. Under the producer law a
	// producer denotes its production (`Logger -> { -> {u8:n} }` — `n` lives in the
	// production, not in Logger), so a producer color is carved through to it. The
	// binding's COLOR stays the constraint itself: the empty-carve path above already
	// materializes through the production, so both agree on what the value inhabits.
	source := constraint
	if cs := carve_source_scope(constraint); cs != nil {
		if prod := produced_scope(cs); prod != nil {
			source = new_type(prod^)
		}
	}
	value := walk_carve(a, scope, idx, source)
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

	// A broken source has no fields to target, and its own diagnostic already fired:
	// every override would miss, turning one root cause into one error per override.
	// The overrides are still WALKED (their own contents get proven) — only the miss
	// is silent.
	broken_src := is_broken(cv.source)

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
			if carve_scope == nil && !broken_src {
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
		} else if child_kind == .EventPull {
			// Specializing an INHERITED handler (`FastLib -> SomeLib{Alloc -< e {…}}`,
			// README §Handlers as compile-time DI): the override targets the source's
			// own handler slot for that event. A scope is closed, so carving derives and
			// never extends — the source must already handle the event.
			// TRAP: scope_handler_index, NOT resolve_handler — an override names a field
			// of the CARVED scope; the lexical walk-up would steal an unrelated
			// enclosing handler and silently rewrite the wrong slot.
			event_idx := child_data.event_pull.from
			event_value := event_idx != INVALID_NODE ? walk(a, current_scope, event_idx) : nil
			event := event_scope_of(event_value)
			carve_scope: ^Scope_Type = nil
			carve_index := -1
			if i := scope_handler_index(src_scope, event); i >= 0 {
				carve_scope = src_scope
				carve_index = i
			}
			if carve_scope == nil && !broken_src && !is_broken(event_value) {
				sem_error(
					a,
					fmt.tprintf(
						"the carved scope has no handler for '%s': a carve derives a scope, it cannot add a handler the source does not declare",
						event_display_name(current_scope, event),
					),
					.Invalid_Carve,
					node_span(a, event_idx != INVALID_NODE ? event_idx : child),
				)
			}
			// The override is the interpretation ALONE: it registers in no scope, and
			// the event it handles is already recorded by the slot it replaces.
			val := walk_event_pull(a, current_scope, child, register = false, event_value = event_value)
			append(refs, Reference{nil, nil, carve_scope, carve_index, node_span(a, child)})
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
			if carve_scope == nil && !broken_src {
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
		if slot_is_handler(ref.match_scope, ref.match_index) do continue
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
		if slot_is_handler(sub, idx) || slot_is_handler(ref.match_scope, ref.match_index) {
			continue // a handler slot's constraint is the event key, not a color
		}
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
		if slot_is_handler(sub, i) do continue // the event key is not a color
		// slot_value, not the raw slot: a field that stated no value holds its color's
		// default, and after substitution that is the SUBSTITUTED color's default —
		// exactly the value this proof must judge.
		value := slot_value(sub, i)
		ft := fold_type(value)
		if ft == nil {
			detect_invalid(value)
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

// value_is_comparable_for_proof reports whether a folded value can be proven
// against a color: a leaf domain, a set operator, or any scope value — a real
// `{}` included. An UNRESOLVED capture never reaches this question: its fold
// reads through capture_color_domain to the applied color, or to Unknown while
// that color is not inferred (and Unknown was skipped by the caller already).
value_is_comparable_for_proof :: proc(vf: ^Type) -> bool {
	if vf == nil do return false
	#partial switch v in vf^ {
	case Integer_Type,
	     Float_Type,
	     String_Type,
	     Bool_Type,
	     Range_Type,
	     Or_Type,
	     And_Type,
	     Negate_Type,
	     Scope_Type:
		return true
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
		if ms := cover_scope(match); ms != nil do product_scope = ms

		product: ^Type = nil
		if product_idx != INVALID_NODE {
			// A union cover only lends its COMMON projection to the product.
			saved_union := a.union_cover
			if match != nil {
				if _, is_or := match^.(Or_Type); is_or do a.union_cover = match
			}
			product = walk(a, product_scope, product_idx)
			a.union_cover = saved_union
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
	result^ = Execute_Type{target = target, caller_scope = current_scope}
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
	// The current target is x86-64, so the pointer-width aliases have the same
	// layout as their 64-bit fixed-width families.
	builtins["usize"] = make_int_range(0, 18446744073709551615)
	builtins["isize"] = make_int_range_default(-9223372036854775808, 9223372036854775807, 0)
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
	// Inside a union cover's product, a name that landed IN the cover scope must be
	// part of the common projection — defined by every operand.
	if res_scope != nil && a.union_cover != nil && res_scope == scope {
		if !cover_projects(a.union_cover, name) do res_scope = nil
	}
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
