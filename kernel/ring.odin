package kernel

import "core:slice"

// THE RING OF INTEGERS (specs/types.md §4.5)
//
// On integers over unknowns, + and * are associative and commutative, * distributes
// over +, 0 and 1 are neutral, -a is the opposite of a, (k * a) / k = a. Oriented,
// they give the normal form of an integer term: a sum of monomials — an integer,
// an unknown, c * u * v … — the unknowns in the order of their index, the
// monomials by degree, the constant last, each added or subtracted, over a divisor:
//
//   ?1 - ?1 = 0      ?1 + ?1 = 2 * ?1      ?0 * (?0 + 1) / 2 = (?0 + ?0 * ?0) / 2

// monomials: an integer term as the monomials of its sum, over a divisor ≥ 1;
// false when it is not a sum of products of integers and unknowns.
monomials :: proc(t: Type) -> (terms: []Type, divisor: i128, ok: bool) {
	#partial switch v in t {
	case Int, ^Unknown:
		return slice.clone([]Type{t}), 1, true
	case ^Operation:
		#partial switch v.op {
		case .Add, .Sub:
			if is_string_value(t) do return
			out := make([dynamic]Type)
			d: i128 = 1
			for a, i in v.args {
				ms, e := monomials(a) or_return
				if v.op == .Sub && i > 0 do ms = scale(ms, -1)
				l := d / gcd(d, e) * e
				scaled := scale(out[:], l / d)
				clear(&out)
				append(&out, ..scaled)
				append(&out, ..scale(ms, l / e))
				d = l
			}
			return collect(out[:]), d, true
		case .Neg:
			ms, d := monomials(v.args[0]) or_return
			return scale(ms, -1), d, true
		case .Mul:
			out := slice.clone([]Type{Int(1)})
			d: i128 = 1
			for a in v.args {
				ms, e := monomials(a) or_return
				out = times(out, ms)
				d *= e
			}
			return out, d, true
		case .Div:
			ms, d := monomials(v.args[0]) or_return
			c, constant := v.args[1].(Int)
			if !constant || c <= 0 do return
			return ms, d * i128(c), true
		}
	}
	return
}

// coefficient, factors: the integer and the unknowns of a monomial.
coefficient :: proc(m: Type) -> i128 {
	#partial switch v in m {
	case Int:
		return i128(v)
	case ^Operation:
		c: i128 = 1
		for a in v.args do if x, ok := a.(Int); ok do c *= i128(x)
		return c
	}
	return 1
}

factors :: proc(m: Type) -> []^Unknown {
	out := make([dynamic]^Unknown)
	#partial switch v in m {
	case ^Unknown:
		append(&out, v)
	case ^Operation:
		for a in v.args do if u, ok := a.(^Unknown); ok do append(&out, u)
	}
	slice.sort_by(out[:], proc(a, b: ^Unknown) -> bool {return a.id < b.id})
	return out[:]
}

// monomial: c * u * v …; 1 * u is u; with no unknown, c.
monomial :: proc(c: i128, us: []^Unknown) -> Type {
	parts := make([dynamic]Type)
	if c != 1 || len(us) == 0 do append(&parts, Int(c))
	for u in us do append(&parts, u)
	return len(parts) == 1 ? parts[0] : new_operation(.Mul, ..parts[:])
}

scale :: proc(ms: []Type, c: i128) -> []Type {
	out := make([]Type, len(ms))
	for m, i in ms do out[i] = monomial(coefficient(m) * c, factors(m))
	return out
}

// times: * distributes over +: each monomial of a by each of b.
times :: proc(a, b: []Type) -> []Type {
	out := make([dynamic]Type)
	for x in a {
		for y in b {
			us := make([dynamic]^Unknown)
			append(&us, ..factors(x))
			append(&us, ..factors(y))
			slice.sort_by(us[:], proc(p, q: ^Unknown) -> bool {return p.id < q.id})
			append(&out, monomial(coefficient(x) * coefficient(y), us[:]))
		}
	}
	return collect(out[:])
}

same_factors :: proc(a, b: []^Unknown) -> bool {
	if len(a) != len(b) do return false
	for x, i in a do if x.id != b[i].id do return false
	return true
}

// collect: c * m + d * m = (c + d) * m, 0 * m dropped, in the order of the normal
// form: by degree, then by unknown, the constant last.
collect :: proc(ms: []Type) -> []Type {
	coefs := make([dynamic]i128)
	us := make([dynamic][]^Unknown)
	outer: for m in ms {
		f := factors(m)
		for x, i in us {
			if same_factors(x, f) {
				coefs[i] += coefficient(m)
				continue outer
			}
		}
		append(&us, f)
		append(&coefs, coefficient(m))
	}
	out := make([dynamic]Type)
	for f, i in us do if coefs[i] != 0 do append(&out, monomial(coefs[i], f))
	slice.sort_by(out[:], monomial_less)
	return out[:]
}

monomial_less :: proc(a, b: Type) -> bool {
	x, y := factors(a), factors(b)
	if len(x) == 0 || len(y) == 0 do return len(x) > 0 && len(y) == 0 // the constant last
	if len(x) != len(y) do return len(x) < len(y)
	for u, i in x do if u.id != y[i].id do return u.id < y[i].id
	return false
}

gcd :: proc(a, b: i128) -> i128 {
	x, y := abs(a), abs(b)
	for y != 0 do x, y = y, x % y
	return x == 0 ? 1 : x
}

// ring_term: the normal form of monomials over a divisor: the divisor and the
// coefficients divided by their gcd; each monomial added, or subtracted.
ring_term :: proc(ms: []Type, divisor: i128) -> Type {
	g := divisor
	for m in ms do g = gcd(g, coefficient(m))
	terms := collect(scale_down(ms, g))
	d := divisor / g
	if len(terms) == 0 do return Int(0)
	t: Type
	for m, i in terms {
		c := coefficient(m)
		magnitude := monomial(abs(c), factors(m))
		switch {
		case i == 0:
			t = c < 0 && len(factors(m)) > 0 ? new_operation(.Neg, magnitude) : m
		case c < 0:
			t = new_operation(.Sub, t, magnitude)
		case:
			t = new_operation(.Add, t, magnitude)
		}
	}
	if d != 1 do t = new_operation(.Div, t, Int(d))
	return t
}

scale_down :: proc(ms: []Type, g: i128) -> []Type {
	out := make([]Type, len(ms))
	for m, i in ms do out[i] = monomial(coefficient(m) / g, factors(m))
	return out
}

// ring_law: + - * neg [~], and a division by a constant that divides exactly;
// false when an operand is not a sum of products.
ring_law :: proc(op: Operator, args: []Type) -> (Type, bool) {
	a, d, ok := monomials(args[0])
	if !ok do return nil, false
	#partial switch op {
	case .Neg:
		return ring_term(scale(a, -1), d), true
	case .Bit_Not:
		// [~]a = -a - 1
		return ring_term(collect(append_all(scale(a, -1), monomial(-d, nil))), d), true
	}
	b, e, ok2 := monomials(args[1])
	if !ok2 do return nil, false
	#partial switch op {
	case .Add, .Sub:
		if op == .Sub do b = scale(b, -1)
		l := d / gcd(d, e) * e
		return ring_term(collect(append_all(scale(a, l / d), ..scale(b, l / e))), l), true
	case .Mul:
		return ring_term(times(a, b), d * e), true
	case .Div:
		// (k * a) / k = a: every coefficient divisible by the constant
		c, constant := args[1].(Int)
		if !constant || c == 0 || d != 1 || e != 1 do return nil, false
		for m in a do if coefficient(m) % i128(c) != 0 do return nil, false
		out := make([]Type, len(a))
		for m, i in a do out[i] = monomial(coefficient(m) / i128(c), factors(m))
		return ring_term(out, 1), true
	}
	return nil, false
}

append_all :: proc(a: []Type, b: ..Type) -> []Type {
	out := make([dynamic]Type)
	append(&out, ..a)
	append(&out, ..b)
	return out[:]
}

// --- sums of terms, for the closed forms (recursion.odin) ---

ring :: proc(op: Operator, args: ..Type) -> Type {
	t, _ := ring_law(op, args)
	return t
}

// linear_in: t = a * u + b, one unknown u of degree 1.
linear_in :: proc(t: Type) -> (u: ^Unknown, a, b: i128, ok: bool) {
	ms, d, is_sum := monomials(t)
	if !is_sum || d != 1 do return
	for m in ms {
		f := factors(m)
		switch len(f) {
		case 0:
			b = coefficient(m)
		case 1:
			if u != nil do return
			u, a = f[0], coefficient(m)
		case:
			return
		}
	}
	return u, a, b, u != nil
}
