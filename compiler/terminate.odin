package compiler

// ============================================================================
// TERMINATION OF STRUCTURAL REDUCTION
//
// A program reduces by collapsing scopes (`s!`). The only engine of recursion is
// a collapse of a SELF-REFERENTIAL scope: `even{n -> arg}!` whose production is a
// pattern that, on the recursive branch, collapses `even{…}!` again. Whether that
// unfolding TERMINATES is not a guard against hanging — it is the semantic fact
// that decides the RESULT:
//
//   - terminates (a base case is statically chosen)  -> unfold and FOLD to concrete
//   - does not terminate (the pivot is a `??`, no base case chosen at compile time)
//                                                    -> stop unfolding, stay SYMBOLIC
//
// A cycle is NEVER an error: recursion is a valid construction of the language
// (this is what makes recursive type matching and runtime recursive functions
// possible). Detecting a cycle serves ONLY to stop unfolding and hold the symbolic
// form — never to reject, never to raise a diagnostic.
//
// The cycle key is the CANONICAL source scope of the collapse, read on the fly —
// nothing is stored on the IR. A recursive collapse clones its carved scope each
// turn (`fold_carve` -> `scope_clone`), so the scope `reduce` receives is fresh
// every round and useless as a key. But the scope the carve derives FROM
// (`follow(carve.source)`) is the one shared `even` node every `Reference` points
// at — stable across the whole unfolding. We keep a thread-local stack of the
// source scopes currently being unfolded; re-entering one means the collapse will
// not terminate statically, so we keep it symbolic. This replaces the magic depth
// counters that used to clip legitimate recursion at 64/512/4096.
// ============================================================================

// The source scopes of collapses currently being unfolded live on the Reducer
// (reached via current_reducer()), not a global: the test runner reduces on many
// threads each in its own arena, so a global [dynamic] would both race and keep a
// stale backing into a freed arena. Unlike the DAG tables it is NOT reset per
// reduce() — it must survive the collapse recursion as the termination guard.
// Balanced by collapse_enter/collapse_leave, so it is empty whenever the top-level
// reduce() returns.

// collapse_source resolves a collapse target (`Execute_Type.target`) to the
// canonical source scope it ultimately collapses, peeling nested carves the same
// way fold_carve does. Returns nil when the target does not bottom out in a scope
// (nothing to track — not a scope collapse).
collapse_source :: proc(target: ^Type) -> ^Scope_Type {
	cur := follow(target)
	for cur != nil {
		#partial switch &v in cur^ {
		case Scope_Type:
			return &v
		case Carve_Type:
			cur = follow(v.source)
			continue
		}
		break
	}
	return nil
}

// collapse_would_recurse reports whether unfolding `s` would re-enter a collapse
// already open on the stack — i.e. the recursion does not terminate statically.
collapse_would_recurse :: proc(s: ^Scope_Type) -> bool {
	if s == nil do return false
	r := current_reducer()
	if r == nil do return false
	for open in r.collapse_stack {
		if open == s do return true
	}
	return false
}

collapse_enter :: proc(s: ^Scope_Type) {
	if r := current_reducer(); r != nil {
		append(&r.collapse_stack, s)
	}
}

collapse_leave :: proc() {
	r := current_reducer()
	if r != nil && len(r.collapse_stack) > 0 {
		pop(&r.collapse_stack)
	}
}
