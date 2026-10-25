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
// An operator applies to a recursive call when its family is the one the
// operator needs: the hypothesis of an induction, checked once the equation is
// given — the family of the first production must be that one.

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

// assume: the hypothesis that a recursive call is in the family f, recorded when
// none is; false when another one is.
assume :: proc(k: ^Kernel, c: ^Collapse, f: Family) -> bool {
	s, ok := c.target.(^Scope)
	if !ok do return false
	root := origin(s)
	if have, found := k.hypotheses[root]; found do return family_holds(f, have)
	k.hypotheses[root] = f
	return true
}

hypothesis :: proc(k: ^Kernel, c: ^Collapse) -> (Family, bool) {
	s, ok := c.target.(^Scope)
	if !ok do return {}, false
	f, found := k.hypotheses[origin(s)]
	return f, found
}

// recursion_law: the first production of a recursive scope, once given: the
// hypothesis is checked, and the equation solved when it has a closed form.
recursion_law :: proc(k: ^Kernel, b: ^Binding, value: Type) -> Type {
	root := origin(b.scope)
	if !root.recursive do return value
	first, found := first_production(k, b.scope)
	if !found || first != b do return value
	if f, assumed := k.hypotheses[root]; assumed {
		g, known := family_of(k, value)
		if !known || !family_holds(f, g) {
			report(k, .Invalid_operator, b.span, fmt.tprintf("the recursive call is used as %v, and is not proven to be one", f))
		}
	}
	if b.scope.carved != nil do return value
	return solve(k, b.scope, value)
}

// solve: the closed form (§5.6). When
//
//   f{n -> m}! = m ? {b -> c  -> g(m) + f{n -> m - 1}!}
//
// with m ≥ b for every value, then f{n -> m}! = c + g(b + 1) + … + g(m), a
// polynomial in m when g is one: c + G(m) - G(b), G(m) = g(0) + … + g(m).
solve :: proc(k: ^Kernel, root: ^Scope, value: Type) -> Type {
	p, is_pattern := value.(^Pattern)
	if !is_pattern || len(p.branches) != 2 || p.branches[1].cover != nil do return value
	u, is_unknown := p.target.(^Unknown)
	base, has_base := p.branches[0].cover.(Int)
	c, constant := p.branches[0].product.(Int)
	if !is_unknown || !has_base || !constant do return value
	g, call, split := split_call(k, p.branches[1].product, root)
	if !split || len(call.changes) != 1 do return value
	for b, v in call.changes {
		x, same_unknown := binding_type(k, b).(^Unknown)
		step, is_sum := as_sum(v)
		if !same_unknown || x.id != u.id || !is_sum || !same_sum(step, sum_add(unknown_sum(u), sum_constant(-1))) do return value
	}
	degree := 0
	for q in g.products {
		for f in q.factors do if f.id != u.id do return value
		degree = max(degree, len(q.factors))
	}
	if !included(k, layout_of(k, u), new_range(Int(base), nil, .Int)) do return value
	sums := power_sums(u, degree)
	total := sum_scale(sums[0], g.constant)
	for q in g.products do total = sum_add(total, sum_scale(sums[len(q.factors)], q.coef))
	total = sum_div(total, g.denom)
	at_base, exact := sum_eval(total, u, i128(base))
	if !exact do return value
	return sum_term(sum_add(sum_constant(i128(c) - at_base), total))
}

// split_call: a product g + f{…}!, with g a sum and one recursive call of f.
split_call :: proc(k: ^Kernel, product: Type, root: ^Scope) -> (g: Sum, call: ^Scope, ok: bool) {
	terms := []Type{product}
	if o, is_add := product.(^Operation); is_add && o.op == .Add do terms = o.args
	g = sum_constant(0)
	for t in terms {
		if c, is_call := t.(^Collapse); is_call && c.recursive {
			s, is_scope := c.target.(^Scope)
			if !is_scope || origin(s) != root || call != nil do return
			call = s
			continue
		}
		part := as_sum(t) or_return
		g = sum_add(g, part)
	}
	return g, call, call != nil
}

// --- polynomials, by the laws of the ring (arith.odin) ---

unknown_sum :: proc(u: ^Unknown) -> Sum {
	s := sum_constant(0)
	append(&s.products, Product{1, slice.clone([]^Unknown{u})})
	return s
}

same_sum :: proc(a, b: Sum) -> bool {
	d := sum_add(a, sum_neg(b))
	return len(d.products) == 0 && d.constant == 0
}

sum_scale :: proc(s: Sum, c: i128) -> Sum {
	return sum_mul(s, sum_constant(c))
}

sum_div :: proc(s: Sum, d: i128) -> Sum {
	out := s
	out.denom *= d
	return sum_reduce(out)
}

sum_pow :: proc(s: Sum, n: int) -> Sum {
	out := sum_constant(1)
	for _ in 0 ..< n do out = sum_mul(out, s)
	return out
}

binomial :: proc(n, r: int) -> i128 {
	out: i128 = 1
	for i in 0 ..< r do out = out * i128(n - i) / i128(i + 1)
	return out
}

// power_sums: S_0 … S_d, S_p(m) = 0^p + 1^p + … + m^p, from
// C(p+1, 0) S_0 + … + C(p+1, p) S_p = (m + 1)^(p+1).
power_sums :: proc(u: ^Unknown, d: int) -> []Sum {
	out := make([]Sum, d + 1)
	next := sum_add(unknown_sum(u), sum_constant(1))
	for p in 0 ..= d {
		acc := sum_pow(next, p + 1)
		for j in 0 ..< p do acc = sum_add(acc, sum_neg(sum_scale(out[j], binomial(p + 1, j))))
		out[p] = sum_div(acc, i128(p + 1))
	}
	return out
}

// sum_eval: the value of a polynomial in u at u = v; false when it is not an
// integer.
sum_eval :: proc(s: Sum, u: ^Unknown, v: i128) -> (i128, bool) {
	total := s.constant
	for q in s.products {
		term := q.coef
		for f in q.factors {
			if f.id != u.id do return 0, false
			term *= v
		}
		total += term
	}
	if total % s.denom != 0 do return 0, false
	return total / s.denom, true
}
