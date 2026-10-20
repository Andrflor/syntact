package kernel

// SOLVING AN EQUATION
//
// The production of a scope that calls itself is an equation: the recursive
// call is an unknown in it (specs/equational.md §4). When it has the form
//
//   Y(p) = c                  for p = b, the base case
//   Y(p) = g(p) + Y(p - 1)    for p from b + 1 to the bound of its domain
//
// where p is a parameter of the scope and g a polynomial in p, its solution is the
// sum Y(p) = c + Σ g(i), i from b + 1 to p: a polynomial, the closed form. It is
// computed without unrolling: the sum of a polynomial of degree n is a polynomial
// of degree n + 1, given by its finite differences at b. Otherwise, the equation
// stays as it is.

solved :: proc(k: ^Kernel, d: ^Scope, t: ^Expr) -> ^Expr {
	cases, is_cases := t^.(Cases)
	if !is_cases || len(cases.cases) != 2 do return t
	base, step := cases.cases[0], cases.cases[1]
	p := base.fact.var
	if p == nil || step.fact.var != p || !parameter_of(d, p) do return t
	// the base case: a single value of p, and the value it gives
	lo, hi := ints_bounds(base.fact.domain.ints)
	b, b_ok := lo.?
	if !b_ok || hi != lo || ints_count(base.fact.domain.ints) != 1 do return t
	env := make([]Atom, k.variables, context.temp_allocator)
	env[p.id] = b
	c_atom, c_ok := eval(base.value, env)
	c, c_int := c_atom.(i128)
	if !c_ok || !c_int do return t
	// the step: p ranges over b + 1 and beyond, without a hole
	step_lo, _ := ints_bounds(step.fact.domain.ints)
	if s, ok := step_lo.?; !ok || s != b + 1 || len(step.fact.domain.ints.intervals) != 1 do return t
	q, is_poly := as_poly(step.value)
	if !is_poly do return t
	g, found := step_rest(k, d, p, q)
	if !found do return t
	if closed, ok := closed_sum(k, p, g, b, c); ok do return poly_type(closed)
	return t
}

// parameter_of: p is the type of a binding of d — a parameter.
parameter_of :: proc(d: ^Scope, p: ^Var) -> bool {
	for b in d.bindings {
		if b.kind == .Product || b.value_type == nil do continue
		if x, lone := lone_symbol(b.value_type); lone && x == p do return true
	}
	return false
}

// step_rest: q = g + Y, where Y is the call of d that gives p the type p - 1 — and
// g, a polynomial in p alone.
step_rest :: proc(k: ^Kernel, d: ^Scope, p: ^Var, q: Poly) -> (g: Poly, found: bool) {
	if den(q) != 1 do return
	call: ^Var = nil
	for m in q.monos {
		for x in m.vars {
			if x == p do continue
			if call != nil || len(m.vars) != 1 || m.coef != 1 || !steps_down(k, d, p, x) do return
			call = x
		}
	}
	if call == nil do return
	g, found = poly_sub(q, poly_var(call))
	return
}

// steps_down: x is the recursive call of d that gives its parameter p the type
// p - 1, and leaves the other bindings as they are.
steps_down :: proc(k: ^Kernel, d: ^Scope, p: ^Var, x: ^Var) -> bool {
	target, carve, call, ok := equation_of(x)
	c, carved := carve.?
	if !ok || !call || !carved || target != d do return false
	position := 0
	moved := false
	for a, i in c.args.bindings {
		place, found := carve_target(d, a, c.ordinals[i], &position)
		if !found || a.value_type == nil do return false
		was := binding_at(place).value_type
		if expr_equal(k, a.value_type, was) do continue
		x, lone := lone_symbol(was)
		want, _ := poly_sub(poly_var(p), Poly{const = 1})
		if !lone || x != p || !expr_equal(k, a.value_type, poly_type(want)) do return false
		moved = true
	}
	return moved
}

// closed_sum: c + Σ g(i), i from b + 1 to p, as a polynomial in p — by the
// finite differences of the sum at b: S(p) = Σ Δʲ S(b) · C(p - b, j).
closed_sum :: proc(k: ^Kernel, p: ^Var, g: Poly, b, c: i128) -> (result: Poly, ok: bool) {
	degree := 0
	for m in g.monos do degree = max(degree, len(m.vars))
	n := degree + 1
	// the sum at b, b + 1, …, b + n
	sums := make([]i128, n + 1, context.temp_allocator)
	env := make([]Atom, k.variables, context.temp_allocator)
	for i in 1 ..= n {
		env[p.id] = b + i128(i)
		v, evaluated := eval(new_expr(g), env)
		x, is_int := v.(i128)
		if !evaluated || !is_int do return
		sums[i] = add_checked(sums[i - 1], x) or_return
	}
	// its finite differences at b
	diffs := make([]i128, n + 1, context.temp_allocator)
	row := sums
	for j in 0 ..= n {
		diffs[j] = row[0]
		next := make([]i128, len(row) - 1, context.temp_allocator)
		for i in 0 ..< len(next) do next[i] = add_checked(row[i + 1], -row[i]) or_return
		row = next
	}
	// Σ Δʲ · (p - b)(p - b - 1)…(p - b - j + 1) / j!
	result = Poly{const = c}
	binomial := Poly{const = 1}
	factorial: i128 = 1
	for j in 0 ..= n {
		if j > 0 {
			shift, _ := poly_sub(poly_var(p), Poly{const = b + i128(j - 1)})
			binomial = poly_mul(binomial, shift) or_return
			factorial = mul_checked(factorial, i128(j)) or_return
		}
		term := poly_scale(binomial, diffs[j]) or_return
		term = poly_mul(term, Poly{const = 1, denom = factorial}) or_return
		result = poly_add(result, term) or_return
	}
	return result, true
}

// apply_closed: the production of d, solved in closed form, applied to the carve
// c — each parameter that c changes replaced by the type it receives. False as
// long as the production is not solved (it is being typed, or it stays an
// equation).
apply_closed :: proc(k: ^Kernel, d: ^Scope, c: Carve) -> (^Expr, bool) {
	p := first_production(d)
	if p == nil || p.value_type == nil || mentions_call(p.value_type, d) do return nil, false
	r := p.value_type
	position := 0
	for a, i in c.args.bindings {
		place, found := carve_target(d, a, c.ordinals[i], &position)
		if !found || a.value_type == nil do return nil, false
		x, lone := lone_symbol(binding_at(place).value_type)
		if !lone do return nil, false
		ok: bool
		r, ok = substitute_var(r, x, a.value_type)
		if !ok do return nil, false
	}
	return r, true
}

// mentions_call: t depends on a recursive call of d not solved yet.
mentions_call :: proc(t: ^Expr, d: ^Scope) -> bool {
	found := make([dynamic]^Var, context.temp_allocator)
	collect_symbols(t, &found)
	for x in found {
		target, _, call, ok := equation_of(x)
		if ok && call && target.span == d.span do return true
	}
	return false
}

// substitute_var: t, where the variable x is `by`, in normal form. False for a
// form that the substitution cannot rewrite yet.
substitute_var :: proc(t: ^Expr, x: ^Var, by: ^Expr) -> (^Expr, bool) {
	#partial switch v in t^ {
	case Set:
		return t, true
	case Poly:
		y, is_poly := as_poly(by)
		if !is_poly do return nil, false
		r := Poly{const = v.const}
		for m in v.monos {
			term := Poly{const = m.coef}
			for z in m.vars {
				ok: bool
				term, ok = poly_mul(term, z == x ? y : poly_var(z))
				if !ok do return nil, false
			}
			ok: bool
			r, ok = poly_add(r, term)
			if !ok do return nil, false
		}
		r, _ = poly_mul(r, Poly{const = 1, denom = den(v)})
		return poly_type(r), true
	}
	return nil, false
}
