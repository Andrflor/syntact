package kernel

import "core:slice"

// INTEGER POLYNOMIALS (specs/types.md §4.5)
//
// On terms without | & ~, the integers bring the laws of a ring: + and *
// associative and commutative, * distributes over +, 0 and 1 neutral, -a the
// opposite of a. Their normal form is a polynomial in the unknowns: a sum of
// monomials, sorted, with nonzero coefficients, over a positive denominator.
// `?₁ - ?₁` is 0, `?₁ + ?₁` is `2 * ?₁`. The denominator only comes from an exact
// division: `?₁ * (?₁ + 1) / 2` stays an integer for every ?₁.

Mono :: struct {
	coef: i128,
	vars: []^Unknown, // sorted by id, repeated for a power: ?₁² is [?₁, ?₁]
}

Poly :: struct {
	monos:    []Mono,
	constant: i128,
	denom:    i128, // ≥ 1
}

poly_constant :: proc(c: i128) -> Poly {
	return Poly{constant = c, denom = 1}
}

poly_var :: proc(u: ^Unknown) -> Poly {
	vars := make([]^Unknown, 1)
	vars[0] = u
	monos := make([]Mono, 1)
	monos[0] = Mono{1, vars}
	return Poly{monos = monos, denom = 1}
}

// poly_of: the normal form of a sum of monomials over d.
poly_of :: proc(monos: []Mono, constant: i128, d: i128) -> Poly {
	sorted := slice.clone(monos)
	slice.sort_by(sorted, mono_less)
	out := make([dynamic]Mono, 0, len(sorted))
	for m in sorted {
		if len(out) > 0 && same_vars(out[len(out) - 1].vars, m.vars) {
			out[len(out) - 1].coef += m.coef
		} else {
			append(&out, m)
		}
	}
	kept := make([dynamic]Mono, 0, len(out))
	for m in out do if m.coef != 0 do append(&kept, m)
	return reduce(Poly{kept[:], constant, d})
}

// reduce: the denominator and the coefficients divided by their gcd; the sign on
// the numerator.
@(private = "file")
reduce :: proc(p: Poly) -> Poly {
	d := p.denom
	if d == 1 do return p
	g := d
	for m in p.monos do g = gcd(g, abs(m.coef))
	g = gcd(g, abs(p.constant))
	if g == 1 do return p
	monos := make([]Mono, len(p.monos))
	for m, i in p.monos do monos[i] = Mono{m.coef / g, m.vars}
	return Poly{monos, p.constant / g, d / g}
}

gcd :: proc(a, b: i128) -> i128 {
	x, y := abs(a), abs(b)
	for y != 0 do x, y = y, x % y
	return x
}

mono_less :: proc(a, b: Mono) -> bool {
	if len(a.vars) != len(b.vars) do return len(a.vars) < len(b.vars)
	for v, i in a.vars do if v.id != b.vars[i].id do return v.id < b.vars[i].id
	return false
}

same_vars :: proc(a, b: []^Unknown) -> bool {
	return slice.equal(a, b)
}

poly_is_constant :: proc(p: Poly) -> (i128, bool) {
	if len(p.monos) != 0 || p.denom != 1 do return 0, false
	return p.constant, true
}

poly_add :: proc(a, b: Poly) -> Poly {
	// over the common denominator
	d := a.denom / gcd(a.denom, b.denom) * b.denom
	fa, fb := d / a.denom, d / b.denom
	monos := make([dynamic]Mono)
	for m in a.monos do append(&monos, Mono{m.coef * fa, m.vars})
	for m in b.monos do append(&monos, Mono{m.coef * fb, m.vars})
	return poly_of(monos[:], a.constant * fa + b.constant * fb, d)
}

poly_neg :: proc(a: Poly) -> Poly {
	monos := make([]Mono, len(a.monos))
	for m, i in a.monos do monos[i] = Mono{-m.coef, m.vars}
	return Poly{monos, -a.constant, a.denom}
}

poly_mul :: proc(a, b: Poly) -> Poly {
	terms_a := poly_terms(a)
	terms_b := poly_terms(b)
	monos := make([dynamic]Mono)
	constant: i128
	for x in terms_a {
		for y in terms_b {
			c := x.coef * y.coef
			if len(x.vars) + len(y.vars) == 0 {
				constant += c
				continue
			}
			vars := make([]^Unknown, len(x.vars) + len(y.vars))
			copy(vars, x.vars)
			copy(vars[len(x.vars):], y.vars)
			slice.sort_by(vars, proc(u, v: ^Unknown) -> bool {return u.id < v.id})
			append(&monos, Mono{c, vars})
		}
	}
	return poly_of(monos[:], constant, a.denom * b.denom)
}

// poly_terms: the monomials and the constant, as one list.
@(private = "file")
poly_terms :: proc(p: Poly) -> []Mono {
	out := make([dynamic]Mono, 0, len(p.monos) + 1)
	append(&out, ..p.monos)
	if p.constant != 0 do append(&out, Mono{p.constant, nil})
	return out[:]
}

// poly_div: p / k for a constant k ≠ 0, exact when every coefficient is a
// multiple of k: (k * a) / k = a.
poly_div :: proc(p: Poly, k: i128) -> (Poly, bool) {
	if k == 0 || p.denom != 1 do return {}, false
	for m in p.monos do if m.coef % k != 0 do return {}, false
	if p.constant % k != 0 do return {}, false
	monos := make([]Mono, len(p.monos))
	for m, i in p.monos do monos[i] = Mono{m.coef / k, m.vars}
	return Poly{monos, p.constant / k, 1}, true
}

poly_equal :: proc(a, b: Poly) -> bool {
	if a.constant != b.constant || a.denom != b.denom || len(a.monos) != len(b.monos) do return false
	for m, i in a.monos do if m.coef != b.monos[i].coef || !same_vars(m.vars, b.monos[i].vars) do return false
	return true
}

// poly_unknowns: the unknowns of p, each once.
poly_unknowns :: proc(p: Poly, out: ^[dynamic]^Unknown) {
	for m in p.monos do for v in m.vars do if !slice.contains(out[:], v) do append(out, v)
}
