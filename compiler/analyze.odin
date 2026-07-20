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

// install_override_snapshot installs `snap` onto the live override map, returning the
// prior values of exactly the keys it touched (with a `present` flag) so the install
// can be undone precisely. A nil/empty snapshot installs nothing.
Override_Save :: struct {
	site:    Binding_Site,
	value:   ^Type,
	present: bool,
}
install_override_snapshot :: proc(a: ^Analyzer, snap: map[Binding_Site]^Type) -> []Override_Save {
	if a == nil || len(snap) == 0 do return {}
	saved := make([dynamic]Override_Save, 0, len(snap))
	for site, v in snap {
		prev, present := site.scope.refine_overrides[site.index]
		append(&saved, Override_Save{site, prev, present})
		site.scope.refine_overrides[site.index] = v
		if !present do a.active_override_sites[site] = true
	}
	return saved[:]
}

// restore_override_snapshot undoes install_override_snapshot exactly.
restore_override_snapshot :: proc(a: ^Analyzer, saved: []Override_Save) {
	if a == nil do return
	for s in saved {
		if s.present {
			s.site.scope.refine_overrides[s.site.index] = s.value
		} else {
			delete_key(&s.site.scope.refine_overrides, s.site.index)
			delete_key(&a.active_override_sites, s.site)
		}
	}
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

	prove_binding(a, fc, ft, name, node)
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
			restore_override_snapshot(a, saved)
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
		found_any := false
		for i := 0; i < len(scope.names); i += 1 {
			if scope.names[i] == name {
				found_any = true
				if count == int(ordinal) {
					return scope, i
				}
				count += 1
			}
		}
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
		for i := 0; i < len(scope.names); i += 1 {
			if scope.names[i] == name {
				return scope, i
			}
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
				if csrc != INVALID_NODE && ast.node_kinds[csrc] == .Identifier {
					name = span_str(ast, ast.node_data[csrc].identifier.name)
					capture = span_str(ast, ast.node_data[csrc].identifier.capture)
				}
			}
			// The colored name must resolve to an identifier — or a bare `(e)`
			// capture: an ANONYMOUS captured binding (no name; invisible to `.`
			// and carving, reachable only by mention, like any capture).
			if name == "" && capture == "" {
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

// A bare constraint `c : name` with no `-> value`: the value is the constraint's
// default, with folds cached inline (nothing to prove — the default is inside it).
walk_constraint :: #force_inline proc(
	a: ^Analyzer,
	current_scope: ^Scope_Type,
	idx: Node_Index,
) -> ^Type {
	ast := a.ast
	data := ast.node_data[idx]
	constraint := walk(a, current_scope, data.binary.left)
	name := ""
	capture := ""
	if data.binary.right != INVALID_NODE {
		right_kind := ast.node_kinds[data.binary.right]
		if right_kind == .Identifier {
			name = span_str(ast, ast.node_data[data.binary.right].identifier.name)
			capture = span_str(ast, ast.node_data[data.binary.right].identifier.capture)
		} else if right_kind == .Carve {
			csrc := ast.node_data[data.binary.right].carve.source
			if csrc != INVALID_NODE && ast.node_kinds[csrc] == .Identifier {
				name = span_str(ast, ast.node_data[csrc].identifier.name)
				capture = span_str(ast, ast.node_data[csrc].identifier.capture)
			}
		}
		// A colored binding's name must be an identifier — or a bare `(e)` capture
		// (an ANONYMOUS captured binding, mention-only).
		if name == "" && capture == "" {
			sem_error(
				a,
				"invalid constraint name: the colored name must be an identifier",
				.Invalid_Constraint_Name,
				node_span(a, data.binary.right),
			)
			return make_invalid()
		}
	}
	return append_bare_constraint(a, current_scope, name, constraint, .Pointing_Push, idx, capture)
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
	a.fold_pending = nil
	fc := fold_constraint(constraint)
	if default_is_infinite(fc) {
		sem_error(
			a,
			"infinite default: the constraint's first production recurses into its own grammar — put a terminal production (e.g. `-> {}`) first",
			.Infinite_Recursion,
			node_span(a, node),
		)
	}
	value := default_value(fc)
	if pend := a.fold_pending; pend != nil {
		a.fold_pending = nil
		// TRAP: the CONSTRAINT NODE holds the slot until close_default patches in
		// the default — NOT an Unknown_Type, which means `??` and would diagnose
		// every fold over this scope as insoluble.
		value = constraint
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

// `source{ … }` — derive a new scope from `source`. source_override, when non-nil,
// replaces the walk of the source node: used for the shorthand carve-of-a-carved-
// field (`a{z{a->2}}`), where `z` is threaded in as a self-mention into the carved
// scope (identical to `.z`) rather than resolving as a plain enclosing mention.
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

			// The override proof runs in recheck_carve against the SUBSTITUTED
			// constraint (a sibling override may rewrite this field's constraint:
			// `a{T -> u8, source -> …}` proves source against Array{u8}).
			val := walk(a, current_scope, val_idx)
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
			append(refs, Reference{nil, nil, carve_scope, carve_index})
			append(vals, val)
			positional_idx += 1
		}
	}

	// Prove each override against the SUBSTITUTED constraint: a sibling override
	// may rewrite this field's constraint (`a{T -> u8, source -> …}`: source must
	// prove against Array{u8}, not the source scope's Array{T -> {}}). The VALUE
	// fold is the walked original — an active branch refinement keeps applying to
	// its mentions — only the CONSTRAINT side reads through the substitution,
	// falling back to the pre-carve constraint when the carve doesn't fold.
	saved_pending := a.fold_pending
	sub := fold_carve_constraint(carve)
	a.fold_pending = saved_pending
	for k in 0 ..< len(cv.references) {
		ref := cv.references[k]
		if ref.match_scope == nil || ref.match_index < 0 do continue
		cf: ^Type = nil
		if sub != nil {
			if idx := carve_ref_index(ref, sub); idx >= 0 && idx < len(sub.constraint_folds) {
				cf = sub.constraint_folds[idx]
			}
		}
		if cf == nil && ref.match_index < len(ref.match_scope.constraint_folds) {
			cf = ref.match_scope.constraint_folds[ref.match_index]
		}
		if cf == nil do continue
		vf := fold_type(cv.types[k])
		if vf == nil do continue
		if !satisfy_root(cf, vf) {
			child := carve_children[k]
			if name, has := ref.name.(string); has {
				sem_error(
					a,
					fmt.tprintf(
						"constraint mismatch in carve '%s': %s does not satisfy %s",
						name,
						describe_type(vf),
						describe_type(cf),
					),
					.Constraint_Mismatch,
					node_span(a, child),
				)
			} else {
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

// recheck_carve folds a carve to its substituted scope and re-proves each colored
// binding. Covers the implicit constraints — DEPENDENT fields (value references a
// carved one); the override proof runs in carve_resolve_children against the
// substituted constraint.
recheck_carve :: proc(a: ^Analyzer, carve: ^Carve_Type, node: Node_Index) {
	saved_span := a.recheck_span
	a.recheck_span = node_span(a, node)
	defer a.recheck_span = saved_span
	sub := fold_carve_constraint(cast(^Type)carve)
	if sub == nil do return
	// Skip directly-overridden fields (already proven at resolution) so a direct
	// violation isn't reported twice as a (mislabeled) "implicit" one.
	overridden := make(map[int]bool)
	for ref in carve.references do overridden[carve_ref_index(ref, sub)] = true
	for i in 0 ..< len(sub.names) {
		if overridden[i] do continue
		// A dependent field may CARVE a binding this carve just SUBSTITUTED (`func{e->5}!`
		// after `m{func->{string:e}}`): that inner carve was proven at definition against
		// func's ORIGINAL color and must be re-proven against the substituted one. Only
		// carves whose source IS a substituted field are re-checked — a recursive carve on
		// an un-substituted binding (`f{n->n-1}` inside f) keeps its branch-refined proof.
		recheck_inner_carves(a, sub, sub.types[i], overridden)
		ft := fold_type(sub.types[i])
		if ft == nil {
			// A nil fold is ambiguous: legally symbolic (`x + 1`) OR incoherent
			// (`"" + 10`). detect_invalid emits only for a real error. Checked for
			// every dependent field, colored or not.
			detect_invalid(sub.types[i])
			continue
		}
		// The proof applies only to a COLORED field.
		fc := i < len(sub.constraint_folds) ? sub.constraint_folds[i] : nil
		if fc == nil do continue
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

// recheck_inner_carves descends a dependent field's value looking for a CARVE whose
// source is a binding this parent carve just SUBSTITUTED, re-proving its overrides
// against the substituted color. `parent` is the materialized parent scope; `substituted`
// marks its overridden field indices. A carve on a global or un-substituted binding
// (`f{n->n-1}` inside recursive f) is left to its eager / branch-refined proof — only a
// carve of a substituted field (`func{e->5}!` after `m{func->{string:e}}`) is re-checked.
// Descends only the structural wrappers a carve hides behind (collapse `!`, pattern
// branch products, scopes of collapses, composites) — never arithmetic operands.
recheck_inner_carves :: proc(a: ^Analyzer, parent: ^Scope_Type, t: ^Type, substituted: map[int]bool) {
	if t == nil do return
	#partial switch &v in t^ {
	case Execute_Type:
		recheck_inner_carves(a, parent, v.target, substituted)
	case Carve_Type:
		// Re-prove ONLY when the carve's source is a substituted field of `parent`.
		if src_idx, ok := carve_source_parent_index(&v, parent); ok && substituted[src_idx] {
			prove_carve_overrides(a, &v)
		}
		recheck_inner_carves(a, parent, v.source, substituted)
		for cv in v.types do recheck_inner_carves(a, parent, cv, substituted)
	case Pattern_Type:
		recheck_inner_carves(a, parent, v.target, substituted)
		for branch in v.branches {
			recheck_inner_carves(a, parent, branch.product, substituted)
		}
	case Compose_Type:
		recheck_inner_carves(a, parent, v.left, substituted)
		recheck_inner_carves(a, parent, v.right, substituted)
	case Scope_Type:
		// A branch product is often a literal scope of collapses (`{ func{e->e}! … }`).
		for ft in v.types do recheck_inner_carves(a, parent, ft, substituted)
	}
}

// carve_source_parent_index resolves a carve's source to a binding of `parent`, returning
// its index. Handles the direct Mention/Reference to a parent field. nil for anything else
// (a global scope, a nested carve, a literal) — those aren't substituted fields.
carve_source_parent_index :: proc(carve: ^Carve_Type, parent: ^Scope_Type) -> (int, bool) {
	s := carve.source
	if s == nil do return 0, false
	#partial switch v in s^ {
	case Mention_Type:
		if v.match_scope == parent && v.match_index >= 0 do return v.match_index, true
	case Reference_Type:
		if v.reference != nil && v.reference.match_scope == parent && v.reference.match_index >= 0 {
			return v.reference.match_index, true
		}
	}
	return 0, false
}

// prove_carve_overrides proves each override of `carve` against the SUBSTITUTED color of
// the field it targets — the fold-side mirror of carve_resolve_children's eager proof.
// Only concludes on a COMPARABLE value (a leaf domain or a producer of one): a still-
// symbolic/placeholder value is skipped rather than false-positived. emit dedups and
// gates on the armed span. A recursive-tail color proves inductively via satisfy.
prove_carve_overrides :: proc(a: ^Analyzer, carve: ^Carve_Type) {
	sub := fold_carve_constraint(cast(^Type)carve)
	if sub == nil do return
	for i in 0 ..< len(carve.references) {
		ref := carve.references[i]
		idx := carve_ref_index(ref, sub)
		if idx < 0 || idx >= len(sub.constraint_folds) do continue
		fc := sub.constraint_folds[idx]
		if fc == nil || is_recursive_tail(fc) || fold_is_unknown(fc) do continue
		if carve.types[i] == nil do continue
		vf := fold_type(carve.types[i])
		if vf == nil || fold_is_unknown(vf) do continue
		if !value_is_comparable_for_proof(vf) do continue
		if !satisfy_root(fc, vf) {
			nm := ref.name.(string) or_else ""
			disp := nm != "" ? fmt.tprintf("'%s'", nm) : "a positional field"
			emit(
				fmt.tprintf(
					"constraint mismatch in carve %s: %s does not satisfy %s",
					disp,
					describe_type(vf),
					describe_type(fc),
				),
				.Constraint_Mismatch,
			)
		}
	}
}

// value_is_comparable_for_proof reports whether a folded value can be proven against a
// color: a leaf domain, a set operator, or a producer scope `{-> leaf}`. A bare structural
// scope (an unresolved capture placeholder, or a genuine scope value) is NOT — proving a
// color against it would false-positive; concrete scopes prove via their own fields.
value_is_comparable_for_proof :: proc(vf: ^Type) -> bool {
	if vf == nil do return false
	#partial switch v in vf^ {
	case Integer_Type, Float_Type, String_Type, Bool_Type, Range_Type, Or_Type, And_Type, Negate_Type:
		return true
	case Scope_Type:
		return color_is_leaf_domain(vf)
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
// in. It anchors the error at `a.recheck_span` (the node being re-folded, armed by
// recheck_carve). Outside a pass it does nothing — detection without a place to
// report is silent. This is the entry point for errors a fold DETECTS on the
// re-fold path; the eager walk path reports through its local node's span directly.
emit :: proc(message: string, error_type: Analyzer_Error_Type) {
	a := current_analyzer()
	if a == nil do return
	// No armed span: this fold is not under a re-fold that wants the diagnostic —
	// stay silent rather than anchor at offset 0.
	if a.recheck_span.start == 0 && a.recheck_span.end == 0 do return
	// A fold is a recomputable cache: recheck_carve re-folds the same carve through both
	// carve_resolve_children and recheck_carve, so a fold-detected error would be emitted
	// once per refold. Drop a STRICT duplicate (same type, span, and message) — distinct
	// diagnostics at different spans (the legitimate double, e.g. a carve override AND its
	// dependent production both overflowing) survive untouched.
	for e in a.errors {
		if e.type == error_type && e.span == a.recheck_span && e.message == message do return
	}
	sem_error(a, message, error_type, a.recheck_span)
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
