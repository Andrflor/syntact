package kernel

// RECURSION (specs/types.md §5.6)
//
// A scope names itself only in its productions. Its collapse there is a recursive
// call: it stays an operation, Apply(.Recur, [the frame]) — carving and collapse
// applied to types — and the production is an equation that mentions it. The
// equation is never unfolded: it is solved, or it stays.
//
// The closed form, when the name is called on an integer:
//
//   f{n -> m}! = m ? {b -> c  -> g(m) + f{n -> m - 1}!}
//   ⟹  f{n -> m}! = c + g(b + 1) + … + g(m)
//
// for every m of the domain of n, which all come down to b; a polynomial in m when
// g is one. A carve of a scope whose production is an equation in its unknowns is
// that equation, the unknowns given the values of the carve: sum{n -> 5}! is sum!
// with n = 5.

has_recursion :: proc(t: Type) -> bool {
	a, is_apply := t.(^Apply)
	if !is_apply do return false
	if a.op == .Recur do return true
	for arg in a.args do if arg != nil && has_recursion(arg) do return true
	return false
}

// solve: the production t of f, an equation that mentions f, in closed form when
// it has the form above; t otherwise.
solve :: proc(k: ^Kernel, f: ^Frame, t: Type) -> Type {
	m, is_match := t.(^Apply)
	if !is_match || m.op != .Match || len(m.args) != 5 || m.args[3] != nil do return t
	u := target_unknown(m.args[0])
	if u == nil do return t
	// the base case: one integer b, a product c that does not recurse
	cover, base_ok := m.args[1].(Set)
	if !base_ok do return t
	b, single := ints_single(cover.ints)
	if !single || !set_equal(cover, set_of(b)) do return t
	c, c_ok := as_poly(m.args[2])
	if !c_ok do return t
	// every value of the domain of u comes down to b
	domain, known := maybe(k, u.domain)
	low, bounded := ints_min(domain.ints).?
	if !known || !bounded || low < b || !set_subset(domain, family_set(.Int)) do return t
	g, ok := step_of(k, f, u, m.args[4])
	if !ok do return t
	// c + Σ_{j=b+1}^{u} g(j) = c + Σ_p a_p (S_p(u) - S_p(b))
	result := c
	for mono in g.monos {
		s := power_sum(u, len(mono.vars))
		at_b := substitute_number(s, u, b)
		result = poly_add(result, poly_mul(poly_over(poly_constant(mono.coef), g.denom), poly_add(s, poly_neg(at_b))))
	}
	if g.constant != 0 do result = poly_add(result, poly_mul(poly_over(poly_constant(g.constant), g.denom), poly_add(poly_var(u), poly_constant(-b))))
	return poly_normal(result)
}

// step_of: g, when p is g(u) + f{n -> u - 1}!, g a polynomial in u alone.
step_of :: proc(k: ^Kernel, f: ^Frame, u: ^Unknown, p: Type) -> (Poly, bool) {
	recursion: ^Apply
	g := poly_constant(0)
	parts := make([dynamic]Type)
	sum_parts(p, &parts)
	for part in parts {
		if a, is_apply := part.(^Apply); is_apply && a.op == .Recur {
			if recursion != nil do return {}, false
			recursion = a
			continue
		}
		q, is_poly := as_poly(part)
		if !is_poly do return {}, false
		for mono in q.monos do for v in mono.vars do if v != u do return {}, false
		g = poly_add(g, q)
	}
	if recursion == nil do return {}, false
	h := recursion.args[0].(^Frame)
	if h.scope != f.scope || h.parent != f.parent || len(h.overrides) != 1 do return {}, false
	for i, o in h.overrides {
		parameter := target_unknown(value_type(k, f, i))
		arg, arg_poly := as_poly(o)
		if parameter != u || !arg_poly || !poly_equal(arg, poly_add(poly_var(u), poly_constant(-1))) do return {}, false
	}
	return g, true
}

sum_parts :: proc(t: Type, out: ^[dynamic]Type) {
	if a, is_apply := t.(^Apply); is_apply && a.op == .Add {
		sum_parts(a.args[0], out)
		sum_parts(a.args[1], out)
		return
	}
	append(out, t)
}

// power_sum: S_p(u) = 1^p + … + u^p, a polynomial in u, from
// (u + 1)^(p+1) - 1 = Σ_{q ≤ p} C(p + 1, q) S_q(u).
power_sum :: proc(u: ^Unknown, p: int) -> Poly {
	sums := make([dynamic]Poly)
	next := poly_add(poly_var(u), poly_constant(1))
	for q in 0 ..= p {
		power := poly_constant(1)
		for _ in 0 ..= q do power = poly_mul(power, next)
		s := poly_add(power, poly_constant(-1))
		for r, j in sums do s = poly_add(s, poly_neg(poly_mul(poly_constant(binomial(q + 1, j)), r)))
		append(&sums, poly_over(s, i128(q + 1)))
	}
	return sums[p]
}

binomial :: proc(n, r: int) -> i128 {
	out: i128 = 1
	for i in 0 ..< r do out = out * i128(n - i) / i128(i + 1)
	return out
}

// substitute_number: p with u = b, a constant polynomial.
substitute_number :: proc(p: Poly, u: ^Unknown, b: i128) -> Poly {
	result := poly_constant(p.constant)
	for m in p.monos {
		term := poly_constant(m.coef)
		for v in m.vars do term = poly_mul(term, v == u ? poly_constant(b) : poly_var(v))
		result = poly_add(result, term)
	}
	return poly_over(result, p.denom)
}

// substitute_equation: the collapse of a carve g whose source produces an
// equation in the unknowns g carves: that equation, with their values.
substitute_equation :: proc(k: ^Kernel, g: ^Frame) -> (Type, bool) {
	source := g.source
	if source == nil do return nil, false
	values := make(map[^Unknown]Type)
	for i, o in g.overrides {
		u := target_unknown(value_type(k, source, i))
		if u == nil do return nil, false
		values[u] = o
	}
	for s in shape_slots(k, source) {
		if binding_of(s).kind != .Product do continue
		if s.frame.states[s.index] == .In_Progress do return nil, false
		return substitute(k, slot_value(k, s), values), true
	}
	return nil, false
}

// substitute: t, each unknown in values replaced by its value, in normal form. A
// recursive call is carved again with the values: it stays a call.
substitute :: proc(k: ^Kernel, t: Type, values: map[^Unknown]Type) -> Type {
	switch v in t {
	case ^Unknown:
		if x, ok := values[v]; ok do return x
		return v
	case Poly:
		result := poly_constant(v.constant)
		for m in v.monos {
			term := poly_constant(m.coef)
			for u in m.vars {
				factor := poly_var(u)
				if x, ok := values[u]; ok {
					p, is_poly := as_poly(x)
					if !is_poly do return t
					factor = p
				}
				term = poly_mul(term, factor)
			}
			result = poly_add(result, term)
		}
		if v.denom != 1 {
			q, exact := poly_div(result, v.denom)
			if !exact do return Poly{result.monos, result.constant, result.denom * v.denom}
			result = q
		}
		return poly_normal(result)
	case ^Apply:
		if v.op == .Recur {
			g := v.args[0].(^Frame)
			args := make([dynamic]Carve_Arg)
			for i, o in g.overrides do append(&args, Carve_Arg{g.scope.bindings[i].name, -1, substitute(k, o, values), {}})
			c := carve(k, g.source, args[:], {})
			if h, is_frame := c.(^Frame); is_frame do return new_apply(.Recur, h)
			return c
		}
		args := make([]Type, len(v.args))
		for a, i in v.args do if a != nil do args[i] = substitute(k, a, values)
		return apply(k, v.op, args, {})
	case Set, ^Frame, Invalid:
	}
	return t
}
