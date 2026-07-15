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

// The unfold stack marks canonical sources whose carve materialization is
// currently reducing its Product fields (reduce_carve) — the path a recursive
// unfolding actually takes; collapse_stack only tracks the scope-collapse path
// (`reduce(&s)` in execute). Consulted ONLY by reduce_pattern's SYMBOLIC path:
// a branch product that re-enters an open unfold cannot terminate (the pivot
// stays symbolic every round), so that product stays residual. A concrete
// pattern never consults it — a statically chosen branch unfolds through and
// terminates at its base case.

unfold_enter :: proc(s: ^Scope_Type) {
	if s == nil do return
	if r := current_reducer(); r != nil do append(&r.unfold_stack, s)
}

unfold_leave :: proc(s: ^Scope_Type) {
	if s == nil do return
	r := current_reducer()
	if r != nil && len(r.unfold_stack) > 0 do pop(&r.unfold_stack)
}

unfold_open :: proc(s: ^Scope_Type) -> bool {
	if s == nil do return false
	r := current_reducer()
	if r == nil do return false
	for open in r.unfold_stack do if open == s do return true
	return false
}

// contains_open_unfold reports whether t structurally carries a collapse or carve
// of a source already open on the unfold stack. Walks the same reduced backbone
// as contains_fixed_point, plus the Execute/Carve nodes themselves.
contains_open_unfold :: proc(t: ^Type) -> bool {
	if t == nil do return false
	#partial switch v in t^ {
	case Execute_Type:
		if unfold_open(collapse_source(v.target)) do return true
		return contains_open_unfold(v.target)
	case Carve_Type:
		if unfold_open(collapse_source(v.source)) do return true
		for ov in v.types do if contains_open_unfold(ov) do return true
		return false
	case Compose_Type:
		return contains_open_unfold(v.left) || contains_open_unfold(v.right)
	case And_Type:
		return contains_open_unfold(v.left) || contains_open_unfold(v.right)
	case Or_Type:
		return contains_open_unfold(v.left) || contains_open_unfold(v.right)
	case Negate_Type:
		return contains_open_unfold(v.operand)
	case Range_Type:
		return contains_open_unfold(v.left) || contains_open_unfold(v.right)
	case Cast_Type:
		return contains_open_unfold(v.value)
	case Pattern_Type:
		if contains_open_unfold(v.target) do return true
		for branch in v.branches {
			if contains_open_unfold(branch.product) do return true
		}
		return false
	}
	return false
}
