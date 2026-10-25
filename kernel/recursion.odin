package kernel

import syn "../compiler"
import "core:fmt"
import "core:slice"

// RECURSION (specs/types.md §5.6)
//
// A scope names itself only in its productions. Asked again from its own
// production, it stays a carve and a collapse — a recursive call — and is never
// unfolded. Its first production is then an equation that mentions it. It is
// solved — a closed form — or it stays. A call of a solved equation substitutes
// its arguments into the solution.
//
// A recursive call has the family of its equation: that of its base cases. An
// operator on it is checked once the equation is given.

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
			if s == root do return solution
			values := make(Rewrite)
			substitutable := true
			for b, v in s.changes {
				u, is_unknown := binding_type(k, b).(^Unknown)
				if !is_unknown {
					substitutable = false
					break
				}
				values[u.id] = v
			}
			if substitutable do return rewrite(k, solution, values)
		}
	}
	out := new(Collapse)
	out.target, out.recursive, out.span = s, true, span
	return out
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
	case ^Pattern:
		if !solved(v.target, root) do return false
		for b in v.branches do if !solved(b.product, root) do return false
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
	c, ok := t.(^Collapse)
	if !ok || !c.recursive do return false
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
	carved := make(map[^Binding]Type)
	for o in operations_on_calls(e, root) {
		for a in o.args {
			c, is_call := a.(^Collapse)
			if !is_call || !c.recursive do continue
			if s, is_scope := c.target.(^Scope); is_scope do for b in s.changes do carved[b] = nil
		}
	}
	if len(carved) == 0 do return
	for b in carved {
		u := new_unknown(k, nil)
		u.layout = binding_color(k, b)
		if u.layout == nil do u.layout = everything()
		carved[b] = u
	}
	generic := derive(k, root, carved, root.span)
	p := first_production(k, generic) or_return
	return base_family(k, root, binding_type(k, p))
}

// base_family: the family of the products of e that do not call root; false when
// there are none, or not of one family.
base_family :: proc(k: ^Kernel, root: ^Scope, e: Type) -> (family: Family, ok: bool) {
	if p, is_pattern := e.(^Pattern); is_pattern {
		f: Maybe(Family)
		for b in p.branches {
			if !solved(b.product, root) do continue
			g := base_family(k, root, b.product) or_return
			if current, set := f.?; set && current != g do return {}, false
			f = g
		}
		return f.?
	}
	if !solved(e, root) do return {}, false
	return family_of(k, e)
}

// recursion_law: the first production of a recursive scope, once given, is solved
// when it has a closed form. A carve of it is the same equation.
recursion_law :: proc(k: ^Kernel, b: ^Binding, value: Type) -> Type {
	root := origin(b.scope)
	if !root.recursive do return value
	first, found := first_production(k, b.scope)
	if !found || first != b do return value
	if b.scope != root {
		if p, has := first_production(k, root); has && p.state == .Not_Asked do binding_type(k, p)
		return value
	}
	return solve(k, b.scope, value)
}

// operations_on_calls: the operations of t that take a recursive call of root.
operations_on_calls :: proc(t: Type, root: ^Scope) -> []^Operation {
	out := make([dynamic]^Operation)
	visit :: proc(t: Type, root: ^Scope, out: ^[dynamic]^Operation) {
		#partial switch v in t {
		case ^Operation:
			for a in v.args {
				c, is_call := a.(^Collapse)
				if !is_call || !c.recursive do continue
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
			if c, is_call := a.(^Collapse); is_call && c.recursive {
				if !family_holds(sig.args[min(i, 1)], f) do continue next
				continue
			}
			if !proven_in(k, a, family_term(sig.args[min(i, 1)])) do continue next
		}
		return true
	}
	return false
}

// solve: the closed form (§5.6). When
//
//   f{n -> m}! = m ? {b -> c  -> g(m) + f{n -> m - 1}!}
//
// with m ≥ b for every value, then f{n -> m}! = c + g(b + 1) + … + g(m), a
// polynomial in m when g is one: c + G(m) - G(b), G(m) = g(0) + … + g(m).
solve :: proc(k: ^Kernel, root: ^Scope, value: Type) -> Type {
	if closed, solved := closed_form(k, root, value); solved do return closed
	return value
}

closed_form :: proc(k: ^Kernel, root: ^Scope, value: Type) -> (closed: Type, ok: bool) {
	p := value.(^Pattern) or_return
	if len(p.branches) != 2 || p.branches[1].cover != nil do return
	u := p.target.(^Unknown) or_return
	base := p.branches[0].cover.(Int) or_return
	c := p.branches[0].product.(Int) or_return
	g, call := split_call(k, p.branches[1].product, root) or_return
	if len(call.changes) != 1 do return
	step := ring_law(.Sub, {u, Int(1)}) or_return
	for b, v in call.changes {
		x, same_unknown := binding_type(k, b).(^Unknown)
		if !same_unknown || x.id != u.id || !same(k, v, step) do return
	}
	ms, divisor := monomials(g) or_return
	degree := 0
	for m in ms {
		for f in factors(m) do if f.id != u.id do return
		degree = max(degree, len(factors(m)))
	}
	if !included(k, layout_of(k, u), new_range(Int(base), nil, .Int)) do return
	// G(m) = g(0) + … + g(m): each monomial c * m^p gives c * S_p(m)
	sums := power_sums(u, degree) or_return
	total: Type = Int(0)
	for m in ms {
		term := ring_law(.Mul, {Int(coefficient(m)), sums[len(factors(m))]}) or_return
		total = ring_law(.Add, {total, term}) or_return
	}
	total = ring_over(total, divisor) or_return
	at := make(Rewrite)
	at[u.id] = Int(base)
	at_base := rewrite(k, total, at).(Int) or_return
	first := add_checked(i128(c), -i128(at_base)) or_return
	return ring_law(.Add, {Int(first), total})
}

// split_call: a product g + f{…}!, with g a sum of products and one recursive call
// of f.
split_call :: proc(k: ^Kernel, product: Type, root: ^Scope) -> (g: Type, call: ^Scope, ok: bool) {
	terms := []Type{product}
	if o, is_add := product.(^Operation); is_add && o.op == .Add do terms = o.args
	g = Int(0)
	for t in terms {
		if c, is_call := t.(^Collapse); is_call && c.recursive {
			s, is_scope := c.target.(^Scope)
			if !is_scope || origin(s) != root || call != nil do return
			call = s
			continue
		}
		g = ring_law(.Add, {g, t}) or_return
	}
	return g, call, call != nil
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
