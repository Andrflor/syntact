package kernel

import syn "../syntax"
import "core:fmt"
import "core:slice"

// RECURSION (specs/types.md §5.6)
//
// A scope names itself only in its productions. Asked again from its own
// production, it stays a carve and a collapse — a recursive call — and is never
// unfolded. Its first production is then an equation that mentions it. It is
// solved — an iteration, in a closed form when it has one — or it stays. A call of
// a solved equation substitutes its arguments into the solution.
//
// A recursive call has the family of its equation: that of its base cases. An
// operator on it is checked once the equation is given.

// recursive: the productions of a scope name it — the binding whose value it is —
// directly or in a carve (§5.6); a carve of it is recursive with it.
recursive :: proc(s: ^Scope) -> bool {
	root := origin(s)
	seen := make(map[^Scope]bool)
	for b in root.bindings do if b.kind == .Product && (names_scope(b.color, root, &seen) || names_scope(b.value, root, &seen)) do return true
	return false
}

// names_scope: the term, as written, names the binding whose value is s. A scope
// is read once: `.x` names the scope it is written in.
names_scope :: proc(t: Type, s: ^Scope, seen: ^map[^Scope]bool) -> bool {
	if t == nil do return false
	switch v in t {
	case ^Name:
		value, ok := v.binding.value.(^Scope)
		return ok && value == s
	case ^Scope:
		if v in seen do return false
		seen[v] = true
		for b in v.bindings do if names_scope(b.color, s, seen) || names_scope(b.value, s, seen) do return true
	case ^Operation:
		for a in v.args do if names_scope(a, s, seen) do return true
	case ^Or:
		for a in v.terms do if names_scope(a, s, seen) do return true
	case ^And:
		for a in v.terms do if names_scope(a, s, seen) do return true
	case ^Effect:
		return names_scope(v.then, s, seen)
	case ^Not:
		return names_scope(v.term, s, seen)
	case ^Is:
		return names_scope(v.term, s, seen)
	case ^Range:
		return names_scope(v.lo, s, seen) || names_scope(v.hi, s, seen)
	case ^Access:
		return names_scope(v.target, s, seen)
	case ^Collapse:
		return names_scope(v.target, s, seen)
	case ^Carve:
		if names_scope(v.target, s, seen) do return true
		for a in v.args do if names_scope(a.value, s, seen) || names_scope(a.otherwise, s, seen) do return true
	case ^Default:
		return names_scope(v.color, s, seen)
	case ^Pattern:
		if names_scope(v.target, s, seen) do return true
		for b in v.branches do if names_scope(b.cover, s, seen) || names_scope(b.product, s, seen) do return true
	case ^Iterate:
		for t in ([]Type{v.start, v.init, v.stop, v.next, v.step, v.last}) do if names_scope(t, s, seen) do return true
	case Char, Int, Real, Bool, None, Invalid, ^Unknown:
	}
	return false
}

// origin: the scope a copy carves, uncarved; a scope is its own.
origin :: proc(s: ^Scope) -> ^Scope {
	return s.carved != nil ? s.carved : s
}

// recursive_call: s! where s is a recursive scope, or a carve of one. A carve of it
// was checked where it is written (scope.odin).
recursive_call :: proc(k: ^Kernel, s: ^Scope, span: syn.Span) -> Type {
	root := origin(s)
	if p, found := first_production(k, root); found && p.state != .In_Progress {
		solution := binding_type(k, p)
		if solved(solution, root) {
			values: Rewrite
			substitutable := true
			for b, v in s.changes {
				u, is_unknown := binding_type(k, b).(^Unknown)
				if !is_unknown {
					substitutable = false
					break
				}
				values = rewriting(values, u, v)
			}
			// each call runs the effects of the solution: what they give back is new
			run: Rewrite
			if substitutable do return renewed(k, rewrite(k, solution, values), &run)
		}
	}
	out := new(Collapse)
	out.target, out.recursive, out.span = s, true, span
	if root.effectful do return call_effect(k, out)
	return out
}

// as_call: t is a recursive call, or what one with effects gives back.
as_call :: proc(t: Type) -> (^Collapse, bool) {
	#partial switch v in t {
	case ^Collapse:
		if v.recursive do return v, true
	case ^Unknown:
		if v.call != nil do return v.call, true
	}
	return nil, false
}

// solved: t holds no recursive call of the scope.
solved :: proc(t: Type, root: ^Scope) -> bool {
	#partial switch v in t {
	case ^Collapse:
		if s, ok := v.target.(^Scope); ok && v.recursive && origin(s) == root do return false
	case ^Operation:
		for a in v.args do if !solved(a, root) do return false
	case ^Or:
		for a in v.terms do if !solved(a, root) do return false
	case ^And:
		for a in v.terms do if !solved(a, root) do return false
	case ^Not:
		return solved(v.term, root)
	case ^Effect:
		if v.call != nil && !solved(v.call, root) do return false
		if v.iterate != nil && !solved(v.iterate, root) do return false
		return solved(v.then, root)
	case ^Pattern:
		if !solved(v.target, root) do return false
		for b in v.branches do if !solved(b.product, root) do return false
	case ^Iterate:
		for t in ([]Type{v.start, v.init, v.stop, v.next, v.step, v.last}) do if !solved(t, root) do return false
	}
	return true
}

// call_family: the family of a recursive call: that of the base cases of the
// equation it calls, once given — false while it is being given.
call_family :: proc(k: ^Kernel, c: ^Collapse) -> (Family, bool) {
	s, ok := c.target.(^Scope)
	if !ok do return {}, false
	root := origin(s)
	p, found := first_production(k, root)
	if !found || p.state != .Done do return {}, false
	return base_family(k, root, p.typed_value)
}

// is_pending_call: a recursive call whose equation is being given.
is_pending_call :: proc(t: Type) -> bool {
	c, ok := as_call(t)
	if !ok do return false
	s, is_scope := c.target.(^Scope)
	if !is_scope do return false
	for b in origin(s).bindings do if b.kind == .Product do return b.state == .In_Progress
	return false
}

// equation_family: the family of the equation of root: that of its base cases,
// the products that do not call it. When the values the scope holds reach none of
// them, its calls carve those values: the family is read on the equation where
// what they carve is an unknown of its color, root{n -> ?::C}.
equation_family :: proc(k: ^Kernel, root: ^Scope, e: Type) -> (family: Family, ok: bool) {
	if f, based := base_family(k, root, e); based do return f, true
	carved := carved_by_calls(e, root)
	if len(carved) == 0 do return
	generic := generic_equation(k, root, &carved) or_return
	p := first_production(k, generic) or_return
	return base_family(k, root, binding_type(k, p))
}

// carved_by_calls: the bindings the recursive calls of e carve, in operations.
carved_by_calls :: proc(e: Type, root: ^Scope) -> map[^Binding]Type {
	carved := make(map[^Binding]Type)
	for o in operations_on_calls(e, root) {
		for a in o.args {
			c, is_call := as_call(a)
			if !is_call do continue
			if s, is_scope := c.target.(^Scope); is_scope do for b in s.changes do carved[b] = nil
		}
	}
	return carved
}

// generic_equation: root where each binding of carved is an unknown of its color,
// root{n -> ?::C}; carved maps each one to its unknown.
generic_equation :: proc(k: ^Kernel, root: ^Scope, carved: ^map[^Binding]Type) -> (^Scope, bool) {
	for b in carved {
		u := new_unknown(k, nil)
		u.layout = binding_color(k, b)
		if u.layout == nil do u.layout = everything()
		carved[b] = u
	}
	return derive(k, root, carved^, root.span).(^Scope)
}

// generic_solution: the solution of the equation of root where each binding of
// values is an unknown of its color, with those values (§5.6):
// sum{n -> m}! = m ? {0 -> 0  -> m + sum{n -> m - 1}!} gives m * (m + 1) / 2 whatever
// m, and whatever n holds in sum.
generic_solution :: proc(k: ^Kernel, root: ^Scope, values: map[^Binding]Type) -> (solution: Type, ok: bool) {
	params := make(map[^Binding]Type)
	for b in values do params[b] = nil
	generic := generic_equation(k, root, &params) or_return
	p := first_production(k, generic) or_return
	solved := iteration(k, generic, binding_type(k, p)) or_return
	rewrites: Rewrite
	for b, u in params do rewrites = rewriting(rewrites, u.(^Unknown), values[b])
	return rewrite(k, solved, rewrites), true
}

// holding: the binding of s that holds b, a binding of the scope s copies: b
// itself, or its copy.
holding :: proc(s: ^Scope, b: ^Binding) -> ^Binding {
	for x in s.bindings do if x == b || x.source == b do return x
	return b
}

// base_family: the family of the base cases of e; false when there are none, or
// not of one family.
base_family :: proc(k: ^Kernel, root: ^Scope, e: Type) -> (family: Family, ok: bool) {
	f: Maybe(Family)
	for b in base_cases(e, root) {
		g := family_of(k, b) or_return
		if current, set := f.?; set && current != g do return {}, false
		f = g
	}
	return f.?
}

// base_cases: the products of e that do not call root, through the effects that wrap
// them (§4.8).
base_cases :: proc(e: Type, root: ^Scope) -> []Type {
	out := make([dynamic]Type)
	if a, is_effect := e.(^Effect); is_effect && (a.call == nil || !a.call.recursive) do return base_cases(a.then, root)
	if p, is_pattern := e.(^Pattern); is_pattern {
		for b in p.branches do if solved(b.product, root) do append(&out, ..base_cases(b.product, root))
	} else if solved(e, root) {
		append(&out, e)
	}
	return out[:]
}

// gives_scopes: a recursive call whose equation has scopes for base cases: by
// induction, it gives a scope, and `...` places it (§5.6).
gives_scopes :: proc(k: ^Kernel, c: ^Collapse) -> bool {
	s, ok := c.target.(^Scope)
	if !ok || !c.recursive do return false
	root := origin(s)
	p, found := first_production(k, root)
	if !found do return false
	bases := base_cases(binding_type(k, p), root)
	for b in bases do if _, is_scope := b.(^Scope); !is_scope do return false
	return len(bases) > 0
}

// production_law: the value of a production. In a recursive scope, the equation —
// its first production — is given first, and solved when it can be (§5.6); a carve
// of it is the same equation. When the equation has effects besides its calls
// — its production, or a binding above it, has some, for some values of its fields
// —, each call runs it, so its calls are effects too (§4.8): the production is typed
// again, on a copy, its calls in the order they are written like any effect.
production_law :: proc(k: ^Kernel, b: ^Binding) -> Type {
	root := origin(b.scope)
	if !recursive(root) do return normal(k, b.value)
	first, found := first_production(k, root)
	if found && first != b && first.state == .Not_Asked do binding_type(k, first)
	value := normal(k, b.value)
	if first != b do return value
	if !root.effectful && (has_effect(with_effects(k, root, b, value)) || effects_elsewhere(k, root)) {
		root.effectful = true
		m: Copier
		m.scopes[b.scope] = b.scope // the scopes written in the production are copied
		value = normal(k, copy_term(k, &m, b.value, b.scope))
	}
	return solve(k, root, value)
}

// effects_elsewhere: the equation of root has effects besides its calls where its
// fields are unknowns of their colors, though not at the values they hold: a
// pattern on a known value keeps one branch, the equation all of them. Its calls
// stay calls while its production is given. A field that is a scope, or an unknown
// already, stays.
effects_elsewhere :: proc(k: ^Kernel, root: ^Scope) -> bool {
	fields := make(map[^Binding]Type)
	for f in root.bindings {
		if f.kind != .Push && f.kind != .Pull do continue
		#partial switch _ in binding_value(k, f) {
		case ^Unknown, ^Scope:
			continue
		}
		fields[f] = nil
	}
	if len(fields) == 0 do return false
	generic := generic_equation(k, root, &fields) or_return
	p := first_production(k, generic) or_return
	return has_effect(with_effects(k, generic, p, binding_type(k, p)))
}

// operations_on_calls: the operations of t that take a recursive call of root.
operations_on_calls :: proc(t: Type, root: ^Scope) -> []^Operation {
	out := make([dynamic]^Operation)
	visit :: proc(t: Type, root: ^Scope, out: ^[dynamic]^Operation) {
		#partial switch v in t {
		case ^Operation:
			for a in v.args {
				c, is_call := as_call(a)
				if !is_call do continue
				if s, is_scope := c.target.(^Scope); is_scope && origin(s) == root {
					append(out, v)
					break
				}
			}
			for a in v.args do visit(a, root, out)
		case ^Pattern:
			for b in v.branches do visit(b.product, root, out)
		case ^Or:
			for a in v.terms do visit(a, root, out)
		case ^And:
			for a in v.terms do visit(a, root, out)
		case ^Not:
			visit(v.term, root, out)
		case ^Effect:
			visit(v.then, root, out)
		}
	}
	visit(t, root, &out)
	return out[:]
}

// legal_on_call: a signature of the operator holds its operands, the recursive
// calls being of the family f.
legal_on_call :: proc(k: ^Kernel, o: ^Operation, f: Family) -> bool {
	next: for sig in signatures(o.op) {
		for a, i in o.args {
			if _, is_call := as_call(a); is_call {
				if !family_holds(sig.args[min(i, 1)], f) do continue next
				continue
			}
			if !proven_in(k, a, family_term(sig.args[min(i, 1)])) do continue next
		}
		return true
	}
	return false
}

// solve: the solution of the equation (§5.6): its iteration, when it is a
// recursion on a counter. When what the calls carve holds known values in the
// scope, the equation is read where they are unknowns, and solved at those values.
solve :: proc(k: ^Kernel, root: ^Scope, value: Type) -> Type {
	if solution, solved := iteration(k, root, value); solved do return solution
	if root.effectful do return value
	values := carved_by_calls(value, root)
	if len(values) == 0 do return value
	for b in values do values[b] = binding_type(k, b)
	if solution, solved := generic_solution(k, root, values); solved do return solution
	return value
}

// iteration: the solution of a recursion (§5.6), a loop. When
//
//   f{n -> m}! = m ? {B -> c(m)  -> h(m, f{n -> s(m)}!)}
//
// and each step makes the call, f{n -> m}! is computed by one loop, whose effects
// run in the order the equation runs them. On a counter, s(m) = m - 1 and B = b
// with m ≥ b for every value, and no effect before the call, it is computed from
// the base case up: x = c, then x = h(k, x) for k from b + 1 up to m. Otherwise it
// follows the calls down from m, through s, until B: then h(m, y) = ε…(y ⊕ a(m)),
// ⊕ an associative operator on integers and e its identity, so the parentheses move
// — x = e, then x = ε…(x ⊕ a(k)) at each k, and x ⊕ c(k) at the last — or
// h(m, y) = ε…(y), a call in tail position — its effects at each k, then c(k).
iteration :: proc(k: ^Kernel, s: ^Scope, value: Type) -> (solution: Type, ok: bool) {
	p := value.(^Pattern) or_return
	if len(p.branches) != 2 || p.branches[0].cover == nil || p.branches[1].cover != nil do return
	u := p.target.(^Unknown) or_return
	root := origin(s)
	stop, c, r := p.branches[0].cover, p.branches[0].product, p.branches[1].product
	if !solved(c, root) do return
	before, call, answer, after := at_call(k, s, r) or_return
	next := counter_next(k, s, call, u) or_return
	family := family_of(k, given(k, c)) or_return
	it := new(Iterate)
	it.index = new_unknown(k, nil)
	it.index.layout = and_law(k, {layout_of(k, u), not_law(k, stop)})
	it.state = new_unknown(k, nil)
	it.state.layout = family_term(family)
	it.span = p.span
	counter := rewriting(nil, u, it.index)
	value := answer != nil ? rewriting(counter, answer, it.state) : rewriting_call(counter, call, it.state)
	if answer == nil && skips(r, root) do return
	if base, is_int := stop.(Int); is_int && len(before) == 0 && same(k, next, ring_law(.Sub, {u, Int(1)}) or_return) && included(k, layout_of(k, u), new_range(stop, nil, .Int)) {
		// from the base case up
		it.start, it.stop = Int(base + 1), new_range(ring_law(.Add, {u, Int(1)}) or_return, nil, .Int)
		it.next = ring_law(.Add, {it.index, Int(1)}) or_return
		it.step, it.last = rewrite(k, after, value), it.state
		if !solved(it.step, root) do return
		return sequence(k, it, {c}, from_base), true
	}
	// down from m, through the calls
	it.start, it.stop, it.next = u, stop, rewrite(k, next, counter)
	last := rewrite(k, c, rewriting(nil, u, narrowing(it.index, and_law(k, {layout_of(k, u), stop}))))
	is_call := proc(k: ^Kernel, t: Type, call: ^Collapse, answer: ^Unknown) -> bool {
		if answer == nil do return same(k, t, call)
		y, is_unknown := t.(^Unknown)
		return is_unknown && same_unknown(y, answer)
	}
	if is_call(k, after, call, answer) {
		// a call in tail position: the effects of each step, then the base case
		it.init, it.step, it.last = None{}, rewrite(k, wrap_effects(before, None{}), counter), last
		return iterated(k, it), true
	}
	o := after.(^Operation) or_return
	if o.op != .Add && o.op != .Mul || family != .Int do return
	rest := make([dynamic]Type)
	found := false
	for a in o.args {
		if !found && is_call(k, a, call, answer) {
			found = true
			continue
		}
		append(&rest, a)
	}
	if !found do return
	a := len(rest) == 1 ? rest[0] : operation_law(k, o.op, rest[:], o.span)
	if !solved(a, root) || answer != nil && reads(k, a, answer) do return
	it.init = o.op == .Add ? Int(0) : Int(1)
	it.step = rewrite(k, wrap_effects(before, operation_law(k, o.op, {it.state, a}, o.span)), value)
	it.last = normal(k, new_operation(o.op, it.state, last))
	return iterated(k, it), true
}

// at_call: a step of the equation, cut at its call of f: the effects before it,
// the call, what it gives back when the equation has effects, and what follows it.
// Without effects, what follows is the step itself, where the call is a term.
at_call :: proc(k: ^Kernel, s: ^Scope, r: Type) -> (before: []^Effect, call: ^Collapse, answer: ^Unknown, after: Type, ok: bool) {
	chain := make([dynamic]^Effect)
	t := r
	for {
		e, is_effect := t.(^Effect)
		if !is_effect do break
		if e.call != nil && e.call.recursive {
			if target, is_scope := e.call.target.(^Scope); is_scope && origin(target) == origin(s) {
				return chain[:], e.call, e.answer, e.then, e.answer != nil
			}
		}
		append(&chain, e)
		t = e.then
	}
	if len(chain) > 0 do return
	if c, is_call := r.(^Collapse); is_call && c.recursive do return nil, c, nil, r, true
	for o in operations_on_calls(r, origin(s)) {
		for a in o.args {
			c, is_call := a.(^Collapse)
			if !is_call || !c.recursive do continue
			if call != nil && !same(k, c, call) do return
			call = c
		}
	}
	return nil, call, nil, r, call != nil
}

// counter_next: the value the call c gives the field that holds u, when it changes
// that field only.
counter_next :: proc(k: ^Kernel, s: ^Scope, c: ^Collapse, u: ^Unknown) -> (Type, bool) {
	target, is_scope := c.target.(^Scope)
	if !is_scope || origin(target) != origin(s) || len(target.changes) != 1 do return nil, false
	for b, v in target.changes {
		x, is_unknown := binding_type(k, holding(s, b)).(^Unknown)
		if !is_unknown || !same_unknown(x, u) do return nil, false
		return v, true
	}
	return nil, false
}

// skips: a branch of a pattern of t does not make the call of root that t makes:
// some steps would not.
skips :: proc(t: Type, root: ^Scope) -> bool {
	#partial switch v in t {
	case ^Pattern:
		if solved(v, root) do return false
		if !solved(v.target, root) do return skips(v.target, root)
		for b in v.branches do if solved(b.product, root) || skips(b.product, root) do return true
	case ^Operation:
		for a in v.args do if skips(a, root) do return true
	case ^Or:
		for a in v.terms do if skips(a, root) do return true
	case ^And:
		for a in v.terms do if skips(a, root) do return true
	case ^Not:
		return skips(v.term, root)
	}
	return false
}

// wrap_effects: t, in the effects of the chain, in order.
wrap_effects :: proc(chain: []^Effect, t: Type) -> Type {
	out := t
	#reverse for e in chain do out = wrapped(e, e.answer, out)
	return out
}

// from_base: the iteration t, from the value of the base case, computed (§4.8).
from_base :: proc(k: ^Kernel, t: Type, parts: []Type) -> Type {
	it := new(Iterate)
	it^ = t.(^Iterate)^
	it.init = parts[0]
	return iterated(k, it)
}

// iterated: the iteration as a term: itself, or its closed form, when it has no
// effect; otherwise an effect that gives it back, bound in what follows. What its
// steps compute without reading what their effects give back crosses them (§4.8):
// the effects run alone, and the value is the iteration of the rest.
iterated :: proc(k: ^Kernel, it: ^Iterate) -> Type {
	if !has_effect(it.step) && !has_effect(it.last) do return iterate_law(k, it)
	chain := make([dynamic]^Effect)
	rest := it.step
	for {
		e, is_effect := rest.(^Effect)
		if !is_effect do break
		append(&chain, e)
		rest = e.then
	}
	crosses := !has_effect(rest) && !has_effect(it.last) && !is_none(rest)
	for e in chain do crosses &&= e.answer == nil || !reads(k, rest, e.answer)
	out := new(Effect)
	out.id, out.iterate, out.span = -1, it, it.span
	if crosses {
		effects := new(Iterate)
		effects^ = it^
		effects.init, effects.step, effects.last = None{}, wrap_effects(chain[:], None{}), None{}
		value := new(Iterate)
		value^ = it^
		value.step = rest
		out.iterate, out.then = effects, iterate_law(k, value)
		return out
	}
	out.answer = new_unknown(k, nil)
	out.answer.layout = it.state.layout
	out.then = out.answer
	return out
}

// iterate_law: an iteration on a counter, k from lo up to hi or from hi down to lo,
// whose step adds to x a polynomial g in k: x = c + g(lo) + … + g(hi) at the last,
// c + G(hi) - G(lo - 1), G(m) = g(0) + … + g(m) from the sums of powers (§5.6).
iterate_law :: proc(k: ^Kernel, it: ^Iterate) -> Type {
	if closed, ok := closed_form(k, it); ok do return closed
	return it
}

closed_form :: proc(k: ^Kernel, it: ^Iterate) -> (closed: Type, ok: bool) {
	lo, hi, end := counter_range(k, it) or_return
	g := ring_law(.Sub, {it.step, it.state}) or_return
	ms, divisor := monomials(g) or_return
	degree := 0
	for m in ms {
		for f in factors(m) do if !same_unknown(f, it.index) do return
		degree = max(degree, len(factors(m)))
	}
	// G(m) = g(0) + … + g(m): each monomial c * m^p gives c * S_p(m)
	sums := power_sums(it.index, degree) or_return
	total: Type = Int(0)
	for m in ms {
		term := ring_law(.Mul, {Int(coefficient(m)), sums[len(factors(m))]}) or_return
		total = ring_law(.Add, {total, term}) or_return
	}
	total = ring_over(total, divisor) or_return
	below := ring_law(.Sub, {lo, Int(1)}) or_return
	upper := rewrite(k, total, rewriting(nil, it.index, hi))
	lower := rewrite(k, total, rewriting(nil, it.index, below))
	sum := ring_law(.Sub, {upper, lower}) or_return
	x := ring_law(.Add, {it.init, sum}) or_return
	return rewrite(k, it.last, rewriting(rewriting(nil, it.state, x), it.index, end)), true
}

// counter_range: the steps of a counter run k over lo..hi, by one — up from lo
// until it passes hi, or down from hi until b = lo - 1, which it reaches —, and k
// is end at the last.
counter_range :: proc(k: ^Kernel, it: ^Iterate) -> (lo, hi, end: Type, ok: bool) {
	if same(k, it.next, ring_law(.Add, {it.index, Int(1)}) or_return) {
		r := it.stop.(^Range) or_return
		if r.hi != nil || r.lo == nil do return
		return it.start, ring_law(.Sub, {r.lo, Int(1)}) or_return, r.lo, true
	}
	if !same(k, it.next, ring_law(.Sub, {it.index, Int(1)}) or_return) do return
	b := it.stop.(Int) or_return
	image := layout_image(k, it.start) or_return
	if !included(k, image, new_range(Int(b), nil, .Int)) do return
	return Int(b + 1), it.start, Int(b), true
}

// ring_over: t / d, d ≥ 1, over the divisor of the sum.
ring_over :: proc(t: Type, d: i128) -> (out: Type, ok: bool) {
	ms, e := monomials(t) or_return
	ed := mul_checked(e, d) or_return
	return ring_term(ms, ed)
}
binomial :: proc(n, r: int) -> i128 {
	out: i128 = 1
	for i in 0 ..< r do out = out * i128(n - i) / i128(i + 1)
	return out
}

// power_sums: S_0 … S_d, S_p(m) = 0^p + 1^p + … + m^p, from
// C(p+1, 0) S_0 + … + C(p+1, p) S_p = (m + 1)^(p+1).
power_sums :: proc(u: ^Unknown, d: int) -> (out: []Type, ok: bool) {
	out = make([]Type, d + 1)
	next := ring_law(.Add, {u, Int(1)}) or_return
	for p in 0 ..= d {
		acc: Type = Int(1)
		for _ in 0 ..= p do acc = ring_law(.Mul, {acc, next}) or_return
		for j in 0 ..< p {
			term := ring_law(.Mul, {Int(binomial(p + 1, j)), out[j]}) or_return
			acc = ring_law(.Sub, {acc, term}) or_return
		}
		out[p] = ring_over(acc, i128(p + 1)) or_return
	}
	return out, true
}
