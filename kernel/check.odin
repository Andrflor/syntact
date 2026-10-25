package kernel

import "core:fmt"

// WHAT IS CHECKED, AND WHERE (specs/types.md §7)
//
// - every binding of a scope that has a color: `V in C`;
// - a definition along its base case: its first production. The other productions
//   are typed when they are asked;
// - a carve where it is written, in what it changed (scope.odin);
// - inside a branch, under the reach of the branch (pattern.odin).
//
// The laws only give terms. The check proves what a normal form asks besides
// `V in C`, and reports what is not proven (obligations): a term no law typed, a
// pattern that does not take every value of its target, an operator on a
// recursive call that the family of its equation does not admit.
//
// The file is checked, and each scope reached from it.

check_program :: proc(k: ^Kernel) {
	scope_law(k, k.root)
	for i := 0; i < len(k.pending); i += 1 do check_scope(k, k.pending[i])
}

check_scope :: proc(k: ^Kernel, s: ^Scope) {
	first := true
	for b in s.bindings {
		switch b.kind {
		case .Product:
			if !first do continue
			first = false
			// the base case is not recursive: placing its scope again, it is an
			// infinite recursion (§5.6)
			if s.recursive && places_itself(k, s, b) {
				report(k, .Infinite_Recursion, b.span, "the base case places its scope again")
				continue
			}
		case .Expand:
			if b.value == nil {
				if c := binding_color(k, b); c != nil do obligations(k, c) // a run: its color is a type
				continue
			}
			v := binding_type(k, b)
			if obligations(k, v) do continue
			if _, is_scope := v.(^Scope); !is_scope {
				report(k, .Constraint_Mismatch, b.span, fmt.tprintf("only a scope can be expanded, not %s", print_type(v)))
			}
			continue
		case .Push, .Pull:
		}
		check_binding(k, b)
	}
}

check_binding :: proc(k: ^Kernel, b: ^Binding) {
	value := binding_type(k, b)
	color := binding_color(k, b)
	failed := value != nil && obligations(k, value)
	failed = color != nil && obligations(k, color) || failed
	if failed || color == nil || value == nil do return
	saved := k.rewrite
	k.rewrite = scope_rewrite(b.scope)
	check_in(k, value, color, b.span)
	k.rewrite = saved
}

// obligations: the proofs a normal form asks besides `V in C`; true when one is
// not proven, and reported: `V in C` is then not asked.
obligations :: proc(k: ^Kernel, t: Type) -> bool {
	switch v in t {
	case Invalid:
		if v.problem != nil do report(k, v.problem.kind, v.problem.span, v.problem.message)
		return true
	case ^Operation:
		failed := false
		for a in v.args do failed = obligations(k, a) || failed
		if !failed && takes_recursive_call(v) do failed = !call_applies(k, v)
		return failed
	case ^Pattern:
		failed := obligations(k, v.target)
		for b in v.branches {
			if b.cover != nil do failed = obligations(k, b.cover) || failed
			failed = obligations(k, b.product) || failed
		}
		if !failed do exhaustive(k, v)
		return failed
	case ^Or:
		failed := false
		for a in v.terms do failed = obligations(k, a) || failed
		return failed
	case ^And:
		failed := false
		for a in v.terms do failed = obligations(k, a) || failed
		return failed
	case ^Not:
		return obligations(k, v.term)
	case ^Is:
		return obligations(k, v.term)
	case ^Range:
		return v.lo != nil && obligations(k, v.lo) || v.hi != nil && obligations(k, v.hi)
	case Char, Int, Real, Bool, None, ^Unknown, ^Name, ^Scope, ^Access, ^Collapse, ^Carve, ^Default:
	}
	return false
}

// exhaustive: every value of the target of a pattern is taken by a branch: the
// values no cover takes, rest, are none — [~]rest is proven (§6).
exhaustive :: proc(k: ^Kernel, p: ^Pattern) {
	_, rest, _ := reaches(k, p.target, p.branches)
	if rest == nil do return
	if verdict, _ := prove(k, bool_not(k, rest)); verdict != .Proven {
		report(k, .Non_Exhaustive_Pattern, p.span, fmt.tprintf("a value of %s is not proven taken by a branch", print_type(p.target)))
	}
}

takes_recursive_call :: proc(o: ^Operation) -> bool {
	for a in o.args do if c, ok := a.(^Collapse); ok && c.recursive do return true
	return false
}

// call_applies: an operator on a recursive call applies to the family of the
// equation the call is a value of: that of its base cases, by induction (§5.6).
call_applies :: proc(k: ^Kernel, o: ^Operation) -> bool {
	root: ^Scope
	for a in o.args {
		if c, ok := a.(^Collapse); ok && c.recursive {
			if s, is_scope := c.target.(^Scope); is_scope do root = origin(s)
		}
	}
	p, found := first_production(k, root)
	if !found do return true
	f, based := equation_family(k, root, binding_type(k, p))
	if !based {
		report(k, .Invalid_operator, o.span, fmt.tprintf("`%s` applies to a recursive call, and the equation has no base case to give its family", operator_text[o.op]))
		return false
	}
	if !legal_on_call(k, o, f) {
		report(k, .Invalid_operator, o.span, fmt.tprintf("`%s` is not proven to apply to %s, a recursive call in %v", operator_text[o.op], print_types(o.args), f))
		return false
	}
	return true
}
