package kernel

import syn "../syntax"
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
			if recursive(s) && places_itself(k, s, b) {
				report(k, .Infinite_Recursion, b.span, "the base case places its scope again")
				continue
			}
		case .Expand:
			// `...e` places the value of e, `...C:` the default of C, `...` nothing:
			// only a scope can be expanded (specs/language/03)
			if b.value == nil && b.color == nil do continue
			if c := binding_color(k, b); c != nil && obligations(k, c) do continue
			v := binding_type(k, b)
			if obligations(k, v) do continue
			if gives_scope(k, v) do continue
			report(k, .Constraint_Mismatch, b.span, fmt.tprintf("only a scope can be expanded, not %s", print_type(v)))
			continue
		case .Handler:
			// a handler answers an event: a binding its handle names (§4.9)
			if handled(k, b) == nil {
				if h := normal(k, b.handle); !obligations(k, h) do report(k, .Invalid_Emission, b.span, fmt.tprintf("`-<` answers an event, a binding its name gives, not %s", print_type(h)))
				continue
			}
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
	check_in(k, value, color, b.span)
}

// obligations: the proofs a normal form asks besides `V in C`; true when one is
// not proven, and reported — at the site given, a carve, or where it is: `V in C`
// is then not asked.
obligations :: proc(k: ^Kernel, t: Type, site := syn.Span{}) -> bool {
	switch v in t {
	case Invalid:
		if v.problem != nil do report(k, v.problem.kind, site != {} ? site : v.problem.span, v.problem.message)
		return true
	case ^Operation:
		failed := false
		for a in v.args do failed = obligations(k, a, site) || failed
		if !failed && takes_recursive_call(v) do failed = !call_applies(k, v)
		return failed
	case ^Pattern:
		failed := obligations(k, v.target, site)
		for b in v.branches {
			if b.cover != nil do failed = obligations(k, b.cover, site) || failed
			failed = obligations(k, b.product, site) || failed
		}
		if !failed do exhaustive(k, v)
		return failed
	case ^Or:
		failed := false
		for a in v.terms do failed = obligations(k, a, site) || failed
		return failed
	case ^And:
		failed := false
		for a in v.terms do failed = obligations(k, a, site) || failed
		return failed
	case ^Effect:
		failed := v.choice != nil && obligations(k, v.choice, site)
		return obligations(k, v.then, site) || failed
	case ^Least, ^Series, ^Recurrent:
		return false // the equation's, checked there
	case ^Fold:
		// its steps are the equation's, checked there
		failed := obligations(k, v.start, site)
		for t in v.inits do failed = obligations(k, t, site) || failed
		return failed
	case ^Not:
		return obligations(k, v.term, site)
	case ^Is:
		return obligations(k, v.term, site)
	case ^Range:
		return v.lo != nil && obligations(k, v.lo, site) || v.hi != nil && obligations(k, v.hi, site)
	case ^Scope:
		// a carve holding a recursive call, taken while its equation was read (the
		// hypothesis): what it changed, proven now that the equation is given (§5.6, §7)
		if v.carved != nil && holds_call(k, v, false) {
			if p, invalid := carve_problem(k, v, site != {} ? site : v.span).(Invalid); invalid {
				report(k, p.problem.kind, p.problem.span, p.problem.message)
				return true
			}
		}
	case Char, Int, Real, Bool, None, ^Unknown, ^Name, ^Access, ^Collapse, ^Carve, ^Default:
	}
	return false
}

// exhaustive: every value of the target of a pattern is taken by a branch: the
// values no cover takes, rest, are none — [~]rest is proven (§6).
exhaustive :: proc(k: ^Kernel, p: ^Pattern) {
	_, rest, _ := branch_reaches(k, p)
	if rest == nil do return
	// the target in the union of the covers, read whole: a call by induction (§5.6)
	covers := make([]Type, len(p.branches))
	for b, i in p.branches do covers[i] = branch_term(k, b, b.cover)
	if verdict, _ := prove(k, in_law(k, p.target, or_law(k, covers))); verdict == .Proven do return
	if verdict, _ := prove(k, bool_not(k, rest)); verdict != .Proven {
		report(k, .Non_Exhaustive_Pattern, p.span, fmt.tprintf("a value of %s is not proven taken by a branch", print_type(p.target)))
	}
}

takes_recursive_call :: proc(o: ^Operation) -> bool {
	for a in o.args do if _, ok := as_call(a); ok do return true
	return false
}

// call_applies: an operator on a recursive call, taken while its equation was read
// (the hypothesis), applies once it is given: its operands are proven in the sets a
// signature asks (§4.5), the call by induction (§5.6); a read of a run, on what gives
// scopes.
call_applies :: proc(k: ^Kernel, o: ^Operation) -> bool {
	switch {
	case o.op == .In:
		return true
	case reads_run(o.op):
		if gives_scope(k, o.args[0]) do return true
	case:
		if _, legal := legal_signature(k, o.op, o.args); legal do return true
	}
	report(k, .Invalid_operator, o.span, fmt.tprintf("`%s` is not proven to apply to %s", operator_text[o.op], print_types(o.args)))
	return false
}
