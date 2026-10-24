package kernel

// RECURSION (specs/types.md §5.5)
//
// A scope names itself only in its productions. Asked again with arguments that
// depend on unknowns, from inside its own production, it is not unfolded: the
// carve and the collapse stay, as an operation of the algebra —
// `sum{n -> m - 1}!` is Apply(.Recur, [the frame sum{n -> m - 1}]). The type of the
// production is then an equation that mentions it. It is solved, or it stays.
//
// The closed form, when the name is called on an integer:
//
//   f{n -> m}! = m ? {b -> c  -> g(m) + f{n -> m - 1}!}
//   ⟹  f{n -> m}! = c + g(b + 1) + … + g(m)
//
// a polynomial in m when g is one (Faulhaber), for every m from b up.

// recursion_of: the collapse of g, when it would unfold the production being
// typed again on unknowns: the equation, not unfolded.
recursion_of :: proc(k: ^Kernel, g: ^Frame) -> (Type, bool) {
	if g.source == nil do return nil, false
	recursive := false
	for h in k.producing do if h.scope == g.scope && h.parent == g.parent do recursive = true
	if !recursive do return nil, false
	for _, o in g.overrides do if !known(k, o.type) do return new_apply(.Recur, g), true
	return nil, false
}

has_recursion :: proc(t: Type) -> bool {
	a, is_apply := t.(^Apply)
	if !is_apply do return false
	if a.op == .Recur do return true
	for arg in a.args do if arg != nil && has_recursion(arg) do return true
	return false
}

// solve: the production t of f, an equation in f itself, in closed form when it
// has the form above; t otherwise.
solve :: proc(k: ^Kernel, f: ^Frame, t: Type) -> Type {
	m, is_match := t.(^Apply)
	if !is_match || m.op != .Match || len(m.args) != 5 do return t
	u := target_unknown(m.args[0])
	if u == nil do return t
	// the base case: a single integer b, a product c without recursion
	cover, base_ok := m.args[1].(Set)
	if !base_ok do return t
	b, single := ints_single(cover.ints)
	if !single || !set_equal(cover, set_of(b)) do return t
	c, c_ok := as_poly(m.args[2])
	if !c_ok do return t
	// every value of u comes down to b: none is below it
	layout, known_layout := layout_envelope(u.layout)
	low, bounded := ints_min(layout.ints).?
	if !known_layout || !bounded || low < b || !set_subset(layout, family_set(.Int)) do return t
	// the other branch: g(u) + f{n -> u - 1}!
	g, ok := step_of(k, f, u, m.args[4])
	if !ok do return t
	// c + Σ_{j=b+1}^{u} g(j) = c + Σ_p a_p (S_p(u) - S_p(b))
	result := c
	for mono in g.monos {
		p := len(mono.vars)
		s, known_power := power_sum(u, p)
		if !known_power do return t
		at_b, _ := power_sum_at(b, p)
		term := poly_add(s, poly_constant(-at_b))
		result = poly_add(result, poly_mul(poly_over(poly_constant(mono.coef), g.denom), term))
	}
	if g.constant != 0 {
		// Σ_{j=b+1}^{u} k = k (u - b)
		result = poly_add(result, poly_mul(poly_over(poly_constant(g.constant), g.denom), poly_add(poly_var(u), poly_constant(-b))))
	}
	return poly_normal(result)
}

// step_of: g when p is g(u) + f{n -> u - 1}!, g a polynomial in u alone.
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
	// the recursion carves the parameter u into u - 1, and nothing else
	h := recursion.args[0].(^Frame)
	if h.scope != f.scope || h.parent != f.parent || len(h.overrides) != 1 do return {}, false
	for i, o in h.overrides {
		parameter, is_poly := as_poly(value_type(k, f, i))
		if !is_poly || target_unknown(Type(parameter)) != u do return {}, false
		arg, arg_poly := as_poly(o.type)
		if !arg_poly || !poly_equal(arg, poly_add(poly_var(u), poly_constant(-1))) do return {}, false
	}
	return g, true
}

// sum_parts: the terms of a sum, an Apply of + or a polynomial.
sum_parts :: proc(t: Type, out: ^[dynamic]Type) {
	if a, is_apply := t.(^Apply); is_apply && a.op == .Add {
		sum_parts(a.args[0], out)
		sum_parts(a.args[1], out)
		return
	}
	append(out, t)
}

// power_sum: S_p(u) = 1^p + 2^p + … + u^p, as a polynomial in u (Faulhaber).
power_sum :: proc(u: ^Unknown, p: int) -> (Poly, bool) {
	m := poly_var(u)
	pow := proc(m: Poly, n: int) -> Poly {
		r := poly_constant(1)
		for _ in 0 ..< n do r = poly_mul(r, m)
		return r
	}
	terms: []i128 // coefficients of m^0 … m^(p+1), over the denominator
	d: i128
	switch p {
	case 0:
		terms, d = {0, 1}, 1
	case 1:
		terms, d = {0, 1, 1}, 2
	case 2:
		terms, d = {0, 1, 3, 2}, 6
	case 3:
		terms, d = {0, 0, 1, 2, 1}, 4
	case 4:
		terms, d = {0, -1, 0, 10, 15, 6}, 30
	case:
		return {}, false
	}
	r := poly_constant(0)
	for coef, i in terms do if coef != 0 do r = poly_add(r, poly_mul(poly_constant(coef), pow(m, i)))
	return poly_over(r, d), true
}

// power_sum_at: S_p(b) for a known b.
power_sum_at :: proc(b: i128, p: int) -> (i128, bool) {
	s: i128
	for j in i128(1) ..= b {
		term: i128 = 1
		for _ in 0 ..< p do term *= j
		s += term
	}
	return s, true
}
