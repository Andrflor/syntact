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
//
// A coefficient beyond the integers written here is not computed: the law does not
// apply, and the term stays.

// atom_ring: the ring law over atoms: a term the ring does not read — a fold, a
// μ, a series, a power, a pattern — is a variable of the polynomial, named while
// the law applies, then put back as it is.
atom_ring :: proc(k: ^Kernel, op: Operator, args: []Type) -> (out: Type, ok: bool) {
	back: Rewrite
	named := make([]Type, len(args))
	for a, i in args do named[i] = atomized(k, a, &back)
	if len(back) == 0 do return
	r := ring_law(op, named) or_return
	return unatomized(r, back), true
}

// unatomized: the ring term t with its atoms put back as they are, its form kept.
unatomized :: proc(t: Type, back: Rewrite) -> Type {
	#partial switch v in t {
	case ^Unknown:
		if x, found := rewritten(back, v); found do return x
	case ^Operation:
		args := make([]Type, len(v.args))
		for a, i in v.args do args[i] = unatomized(a, back)
		out := new(Operation)
		out^ = v^
		out.args = args
		return out
	}
	return t
}

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
				if v.op == .Sub && i > 0 do ms = scale(ms, -1) or_return
				l := mul_checked(d / gcd(d, e), e) or_return
				left := scale(out[:], l / d) or_return
				right := scale(ms, l / e) or_return
				clear(&out)
				append(&out, ..left)
				append(&out, ..right)
				d = l
			}
			collected := collect(out[:]) or_return
			return collected, d, true
		case .Neg:
			ms, d := monomials(v.args[0]) or_return
			neg := scale(ms, -1) or_return
			return neg, d, true
		case .Mul:
			out := slice.clone([]Type{Int(1)})
			d: i128 = 1
			for a in v.args {
				ms, e := monomials(a) or_return
				out = times(out, ms) or_return
				d = mul_checked(d, e) or_return
			}
			return out, d, true
		case .Div:
			ms, d := monomials(v.args[0]) or_return
			c, constant := v.args[1].(Int)
			if !constant || c <= 0 do return
			e := mul_checked(d, i128(c)) or_return
			return ms, e, true
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
		for a in v.args do if x, ok := a.(Int); ok do return i128(x)
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
	slice.sort_by(out[:], proc(a, b: ^Unknown) -> bool {return unknown_order(a, b) < 0})
	return out[:]
}

// monomial: c * u * v …; 1 * u is u; with no unknown, c.
monomial :: proc(c: i128, us: []^Unknown) -> Type {
	parts := make([dynamic]Type)
	if c != 1 || len(us) == 0 do append(&parts, Int(c))
	for u in us do append(&parts, u)
	return len(parts) == 1 ? parts[0] : new_operation(.Mul, ..parts[:])
}

scale :: proc(ms: []Type, c: i128) -> (out: []Type, ok: bool) {
	out = make([]Type, len(ms))
	for m, i in ms {
		x := mul_checked(coefficient(m), c) or_return
		out[i] = monomial(x, factors(m))
	}
	return out, true
}

// times: * distributes over +: each monomial of a by each of b.
times :: proc(a, b: []Type) -> (out: []Type, ok: bool) {
	products := make([dynamic]Type)
	for x in a {
		for y in b {
			us := make([dynamic]^Unknown)
			append(&us, ..factors(x))
			append(&us, ..factors(y))
			slice.sort_by(us[:], proc(p, q: ^Unknown) -> bool {return unknown_order(p, q) < 0})
			c := mul_checked(coefficient(x), coefficient(y)) or_return
			append(&products, monomial(c, us[:]))
		}
	}
	return collect(products[:])
}

same_factors :: proc(a, b: []^Unknown) -> bool {
	if len(a) != len(b) do return false
	for x, i in a do if !same_unknown(x, b[i]) do return false
	return true
}

// collect: c * m + d * m = (c + d) * m, 0 * m dropped, in the order of the normal
// form: by degree, then by unknown, the constant last.
collect :: proc(ms: []Type) -> (out: []Type, ok: bool) {
	coefs := make([dynamic]i128)
	us := make([dynamic][]^Unknown)
	outer: for m in ms {
		f := factors(m)
		for x, i in us {
			if same_factors(x, f) {
				coefs[i] = add_checked(coefs[i], coefficient(m)) or_return
				continue outer
			}
		}
		append(&us, f)
		append(&coefs, coefficient(m))
	}
	kept := make([dynamic]Type)
	for f, i in us do if coefs[i] != 0 do append(&kept, monomial(coefs[i], f))
	slice.sort_by(kept[:], monomial_less)
	return kept[:], true
}

monomial_less :: proc(a, b: Type) -> bool {
	x, y := factors(a), factors(b)
	if len(x) == 0 || len(y) == 0 do return len(x) > 0 && len(y) == 0 // the constant last
	if len(x) != len(y) do return len(x) < len(y)
	for u, i in x do if c := unknown_order(u, y[i]); c != 0 do return c < 0
	return false
}

gcd :: proc(a, b: i128) -> i128 {
	x, y := a, b
	for y != 0 do x, y = y, x % y
	return x == 0 ? 1 : (x < 0 ? -x : x)
}

// ring_term: the normal form of monomials over a divisor: the divisor and the
// coefficients divided by their gcd; each monomial added, or subtracted.
ring_term :: proc(ms: []Type, divisor: i128) -> (t: Type, ok: bool) {
	g := divisor
	for m in ms do g = gcd(g, coefficient(m))
	reduced := make([]Type, len(ms))
	for m, i in ms do reduced[i] = monomial(coefficient(m) / g, factors(m))
	terms := collect(reduced) or_return
	d := divisor / g
	if len(terms) == 0 do return Int(0), true
	for m, i in terms {
		c := coefficient(m)
		if c == min(i128) do return nil, false
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
	return t, true
}

// ring_law: + - * neg [~], and a division by a constant that divides exactly;
// false when an operand is not a sum of products, or a coefficient is beyond the
// integers written here.
ring_law :: proc(op: Operator, args: []Type) -> (t: Type, ok: bool) {
	a, d := monomials(args[0]) or_return
	#partial switch op {
	case .Neg:
		neg := scale(a, -1) or_return
		return ring_term(neg, d)
	case .Bit_Not:
		// [~]a = -a - 1
		neg := scale(a, -1) or_return
		minus_one := monomial(-d, nil)
		all := collect(append_all(neg, minus_one)) or_return
		return ring_term(all, d)
	}
	b, e := monomials(args[1]) or_return
	#partial switch op {
	case .Add, .Sub:
		if op == .Sub do b = scale(b, -1) or_return
		l := mul_checked(d / gcd(d, e), e) or_return
		left := scale(a, l / d) or_return
		right := scale(b, l / e) or_return
		all := collect(append_all(left, ..right)) or_return
		return ring_term(all, l)
	case .Mul:
		product := times(a, b) or_return
		de := mul_checked(d, e) or_return
		return ring_term(product, de)
	case .Div:
		// (k * a) / k = a: every coefficient divisible by the constant
		c, constant := args[1].(Int)
		if !constant || c == 0 || d != 1 || e != 1 do return
		out := make([]Type, len(a))
		for m, i in a {
			if coefficient(m) % i128(c) != 0 do return
			out[i] = monomial(coefficient(m) / i128(c), factors(m))
		}
		return ring_term(out, 1)
	}
	return
}

append_all :: proc(a: []Type, b: ..Type) -> []Type {
	out := make([dynamic]Type)
	append(&out, ..a)
	append(&out, ..b)
	return out[:]
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
