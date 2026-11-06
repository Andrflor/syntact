package kernel

// LINEAR ARITHMETIC OVER THE TYPES (specs/types.md §4.5, §7)
//
// The theory of the integers of the solver. A query `t in a..b` is proven when
// `t < a` and `t > b` are each unsatisfiable with the axioms of the terms in t:
//
//   a term is linear over atoms, by the ring: an atom is an unknown, or a term the
//   ring does not read — a product of unknowns, x % m, x / c, a fold, a Σ —, named;
//   an unknown lies in its layout; x % m, m > 0, in 0..m − 1 when x ≥ 0 (Euclid);
//   x / c, c > 0, x ≥ 0: c·q ≤ x ≤ c·q + c − 1; x [&] m, m ≥ 0: in 0..m;
//   a call that stays, in its type: the least solution of its definition (call_range);
//   a pattern, one of its products: between the least and the greatest of them;
//   b ** e, b ≥ 1, e ≥ 0: b ** p ≤ b ** e ≤ b ** q, p ≤ e ≤ q;
//   a Σ of n terms g, or a fold adding g at each of its n steps, from s:
//   s + n·p ≤ S ≤ s + n·q, p ≤ g ≤ q what the theory gives of g (induction on the
//   steps);
//
// and a conjunction of linear constraints is decided by Fourier–Motzkin elimination:
// unsatisfiable over the reals, it is over the integers.

Linear :: struct {
	coefs:    map[int]i128, // atom → coefficient
	constant: i128,
}

Lia :: struct {
	atoms: [dynamic]Type,
	rows:  [dynamic]Linear, // each: Σ coefs·atoms + constant ≤ 0
}

// lia_in: every value of t is in the range lo..hi, an end nil for none: proven by the
// theory.
lia_in :: proc(k: ^Kernel, t: Type, lo, hi: Maybe(i128)) -> bool {
	if l, has := lo.?; has {
		// t < l: t − l + 1 ≤ 0
		s: Lia
		x, ok := linear_of(k, &s, t)
		if !ok do return false
		x.constant -= l - 1
		append(&s.rows, x)
		if !unsatisfiable(&s) do return false
	}
	if h, has := hi.?; has {
		// t > h: −t + h + 1 ≤ 0
		s: Lia
		x, ok := linear_of(k, &s, t)
		if !ok do return false
		x = scaled(x, -1)
		x.constant += h + 1
		append(&s.rows, x)
		if !unsatisfiable(&s) do return false
	}
	return true
}

// linear_of: t as a linear form over the atoms of s, their axioms added.
linear_of :: proc(k: ^Kernel, s: ^Lia, t: Type) -> (out: Linear, ok: bool) {
	out.coefs = make(map[int]i128)
	if c, constant := t.(Int); constant {
		out.constant = i128(c)
		return out, true
	}
	back: Rewrite
	ms, divisor := monomials(atomized(k, t, &back)) or_return
	if divisor != 1 do return
	for m in ms {
		fs := factors(m)
		c := coefficient(m)
		if len(fs) == 0 {
			out.constant += c
			continue
		}
		term: Type = len(fs) == 1 ? unatomized(fs[0], back) : unatomized(monomial(1, fs), back)
		a := atom_of(k, s, term) or_return
		out.coefs[a] += c
	}
	return out, true
}

// atom_of: the atom t names in s, its axioms added once.
atom_of :: proc(k: ^Kernel, s: ^Lia, t: Type) -> (a: int, ok: bool) {
	for x, i in s.atoms do if same(k, x, t) do return i, true
	a = len(s.atoms)
	append(&s.atoms, t)
	axioms(k, s, a, t) or_return
	return a, true
}

// axioms: what the theory knows of the atom a, the term t.
axioms :: proc(k: ^Kernel, s: ^Lia, a: int, t: Type) -> bool {
	at :: proc(a: int, c: i128) -> Linear {
		l: Linear
		l.coefs = make(map[int]i128)
		l.coefs[a] = c
		return l
	}
	// a in lo..hi
	within :: proc(s: ^Lia, a: int, lo, hi: Maybe(i128)) {
		if l, has := lo.?; has {
			r := at(a, -1)
			r.constant = l
			append(&s.rows, r)
		}
		if h, has := hi.?; has {
			r := at(a, 1)
			r.constant = -h
			append(&s.rows, r)
		}
	}
	#partial switch v in t {
	case ^Unknown:
		// its layout: a set of constants, the range from its least to its greatest; a
		// range over other unknowns, each end a linear constraint
		layout := layout_of(k, v)
		if r, is_range := layout.(^Range); is_range && !is_constant(layout) {
			if r.lo != nil {
				x := linear_of(k, s, r.lo) or_return
				x.coefs[a] -= 1
				append(&s.rows, x)
			}
			if r.hi != nil {
				x := linear_of(k, s, r.hi) or_return
				x = scaled(x, -1)
				x.coefs[a] += 1
				append(&s.rows, x)
			}
			return true
		}
		if lo, hi, bounded := int_bounds(k, layout); bounded do within(s, a, lo, hi)
	case ^Operation:
		#partial switch v.op {
		case .Mod:
			m, constant := v.args[1].(Int)
			if !constant || m <= 0 do return true
			if lia_in(k, v.args[0], 0, nil) do within(s, a, 0, i128(m) - 1)
			else do within(s, a, -(i128(m) - 1), i128(m) - 1)
		case .Div:
			c, constant := v.args[1].(Int)
			if !constant || c <= 0 || !lia_in(k, v.args[0], 0, nil) do return true
			// c·q ≤ x ≤ c·q + c − 1
			x := linear_of(k, s, v.args[0]) or_return
			lower := scaled(x, -1)
			lower.coefs[a] += i128(c)
			append(&s.rows, lower)
			upper := x
			upper.coefs = clone_coefs(x.coefs)
			upper.coefs[a] -= i128(c)
			upper.constant -= i128(c) - 1
			append(&s.rows, upper)
		case .Pow:
			// b ** e, b ≥ 1 a constant, e ≥ 0: from b ** least to b ** greatest of e
			b, constant := v.args[0].(Int)
			if !constant || b < 1 do return true
			p, q := extremes(k, v.args[1])
			least, has_least := p.?
			if !has_least || least < 0 do return true
			power :: proc(b, e: i128) -> (i128, bool) {
				out: i128 = 1
				for _ in 0 ..< e {
					if out > (i128(1) << 100) / b do return 0, false
					out *= b
				}
				return out, true
			}
			low, _ := power(i128(b), least)
			high: Maybe(i128)
			if greatest, has := q.?; has do if x, fits := power(i128(b), greatest); fits do high = x
			within(s, a, low, high)
		case .Bit_And:
			for arg in v.args do if m, constant := arg.(Int); constant && m >= 0 do within(s, a, 0, i128(m))
		case:
			if image, known := layout_image(k, t); known && is_constant(image) {
				if lo, hi, bounded := int_bounds(k, image); bounded do within(s, a, lo, hi)
			}
		}
	case ^Collapse:
		// a call that stays: its type, the least solution of its definition
		if !v.recursive do return true
		l, h, ranged := call_range(k, v)
		if !ranged do return true
		if l != nil {
			// l − a ≤ 0
			x := linear_of(k, s, l) or_return
			x.coefs[a] -= 1
			append(&s.rows, x)
		}
		if h != nil {
			// a − h ≤ 0
			x := linear_of(k, s, h) or_return
			x = scaled(x, -1)
			x.coefs[a] += 1
			append(&s.rows, x)
		}
	case ^Pattern:
		// a pattern gives one of its products, each read in its branch (§6): a
		// disjunction, split; the atom lies between the least and the greatest any
		// of them takes — none gives no value
		lo, hi: Maybe(i128)
		leaves := make([dynamic]Product)
		products(k, v, &leaves)
		for leaf in leaves {
			if is_none(leaf.term) do continue
			p, q := extremes(k, read_in(k, leaf, leaf.term))
			l, has_l := p.?
			h, has_h := q.?
			if !has_l || !has_h do return true
			if x, has := lo.?; !has || l < x do lo = l
			if x, has := hi.?; !has || h > x do hi = h
		}
		within(s, a, lo, hi)
	case ^Series:
		if v.op != .Add do return true
		// n terms g: n·p ≤ S ≤ n·q, p ≤ g ≤ q
		n := op(k, .Add, op(k, .Sub, v.hi, v.lo), Int(1))
		return summed(k, s, a, v.term, v.index, range_law(k, v.lo, v.hi, .Int, v.span), n, Int(0))
	case ^Fold:
		// a fold whose value is a state x: c ↦ x + g, along a counter of n steps; g
	// may read the other states, each any value of its layout
		lo, hi, counter := counter_range(k, v)
		if !counter do return true
		for z, i in v.states {
			if !same(k, v.value, z) do continue
			one, g, affine := affine_in(k, v.updates[i], z)
			if !affine || !is_int(one, 1) do return true
			n := op(k, .Add, op(k, .Sub, hi, lo), Int(1))
			return summed(k, s, a, g, v.index, range_law(k, lo, hi, .Int, v.span), n, v.inits[i])
		}
	}
	return true
}

// summed: the atom a is start plus n terms g, each with its index in along: s + n·p ≤ a
// ≤ s + n·q, p and q the least and greatest the theory gives of g — by induction on
// the terms, each in p..q.
summed :: proc(k: ^Kernel, s: ^Lia, a: int, g: Type, index: ^Unknown, along: Type, n: Type, start: Type) -> bool {
	i := new_unknown(k, nil)
	i.layout = along
	term := rewrite(k, g, rewriting(nil, index, i))
	p, q := extremes(k, term)
	count := linear_of(k, s, n) or_return
	init := linear_of(k, s, start) or_return
	if lo, has := p.?; has {
		// start + n·p − a ≤ 0
		r := add_linear(init, scaled(count, lo))
		r.coefs[a] -= 1
		append(&s.rows, r)
	}
	if hi, has := q.?; has {
		// a − start − n·q ≤ 0
		r := scaled(add_linear(init, scaled(count, hi)), -1)
		r.coefs[a] += 1
		append(&s.rows, r)
	}
	return true
}

// extremes: the least and greatest values of t the theory proves, by elimination of
// every atom but t.
extremes :: proc(k: ^Kernel, t: Type) -> (lo, hi: Maybe(i128)) {
	s: Lia
	x, ok := linear_of(k, &s, t)
	if !ok do return
	// v = t: v − t ≤ 0, t − v ≤ 0
	v := len(s.atoms)
	append(&s.atoms, None{})
	r1 := scaled(x, -1)
	r1.coefs[v] += 1
	r2 := x
	r2.coefs = clone_coefs(x.coefs)
	r2.coefs[v] -= 1
	append(&s.rows, r1, r2)
	rows := s.rows[:]
	for a in 0 ..< v do rows = eliminate_atom(rows, a)
	for r in rows {
		c := r.coefs[v] or_else 0
		if c == 0 do continue
		// c·v + constant ≤ 0
		if c > 0 {
			bound := floor_div(-r.constant, c)
			if h, has := hi.?; !has || bound < h do hi = bound
		} else {
			// v ≥ ⌈constant / −c⌉
			bound := -floor_div(-r.constant, -c)
			if l, has := lo.?; !has || bound > l do lo = bound
		}
	}
	return
}

// unsatisfiable: the rows of s have no solution: Fourier–Motzkin, each atom
// eliminated in turn; a row with no atom left and a positive constant is 0 < 0.
unsatisfiable :: proc(s: ^Lia) -> bool {
	rows := s.rows[:]
	for a in 0 ..< len(s.atoms) do rows = eliminate_atom(rows, a)
	for r in rows {
		empty := true
		for _, c in r.coefs do if c != 0 do empty = false
		if empty && r.constant > 0 do return true
	}
	return false
}

// eliminate_atom: the rows without the atom a: those not reading it, and each pair of a
// row bounding it above and one bounding it below, combined.
eliminate_atom :: proc(rows: []Linear, a: int) -> []Linear {
	out := make([dynamic]Linear)
	upper, lower := make([dynamic]Linear), make([dynamic]Linear)
	for r in rows {
		c := r.coefs[a] or_else 0
		switch {
		case c > 0:
			append(&upper, r)
		case c < 0:
			append(&lower, r)
		case:
			append(&out, r)
		}
	}
	for u in upper do for l in lower {
		cu, cl := u.coefs[a], -l.coefs[a]
		r := add_linear(scaled(u, cl), scaled(l, cu))
		delete_key(&r.coefs, a)
		append(&out, tightened(r))
	}
	return out[:]
}

// tightened: the row divided by the gcd of its coefficients, its constant rounded up:
// over the integers, Σ c·x ≤ −k with g | c is Σ (c / g)·x ≤ ⌊−k / g⌋.
tightened :: proc(r: Linear) -> Linear {
	g: i128 = 0
	for _, c in r.coefs do g = gcd(g, abs(c))
	if g <= 1 do return r
	out: Linear
	out.coefs = make(map[int]i128)
	for x, c in r.coefs do out.coefs[x] = c / g
	out.constant = -floor_div(-r.constant, g)
	return out
}

scaled :: proc(r: Linear, by: i128) -> Linear {
	out: Linear
	out.coefs = make(map[int]i128)
	for x, c in r.coefs do out.coefs[x] = c * by
	out.constant = r.constant * by
	return out
}

add_linear :: proc(a, b: Linear) -> Linear {
	out: Linear
	out.coefs = clone_coefs(a.coefs)
	for x, c in b.coefs do out.coefs[x] += c
	out.constant = a.constant + b.constant
	return out
}

clone_coefs :: proc(m: map[int]i128) -> map[int]i128 {
	out := make(map[int]i128)
	for x, c in m do out[x] = c
	return out
}
