package compiler

// Termination of structural reduction. A recursive collapse that terminates
// (base case statically chosen) unfolds and folds concrete; one that does not
// (pivot is a `??`) stops unfolding and stays SYMBOLIC. A cycle is NEVER an error:
// detecting it only stops unfolding, never rejects.
//
// The cycle key is the canonical SOURCE scope `follow(carve.source)` — stable
// across the unfolding, whereas the cloned carved scope reduce receives is fresh
// each round. The open-collapse stack lives on the Reducer (current_reducer()),
// NOT a global: the test runner reduces on many threads each in its own arena.
// Unlike the DAG tables it is NOT reset per reduce() — it must survive the collapse
// recursion. Balanced by collapse_enter/collapse_leave.

// collapse_source resolves a collapse target to the canonical source scope it
// ultimately collapses, peeling nested carves. nil = not a scope collapse.
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

// collapse_would_recurse reports whether unfolding `s` would re-enter an already
// open collapse (the recursion does not terminate statically).
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
