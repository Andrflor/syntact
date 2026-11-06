package kernel

// THE THEORY OF THE INTEGERS (specs/types.md §4.5, §6, §7)
//
// A branch is a conjunction of layouts ?ₖ::(L & S). Its constraints are terms d of the
// ring, each meaning d in 0..: a range l..h in the layout of u gives u - l and h - u;
// a term the ring does not read — an atom: x % m, x / c, |x|, x.#k, a call, a fold —
// is an unknown of the ring, and enters by its type. The conjunction is empty when
// eliminating its unknowns one by one gives a negative constant: each unknown u,
// a·u + r ≥ 0 and -b·u + s ≥ 0 give b·r + a·s ≥ 0, a term of the ring over the
// others, divided by the gcd of its coefficients and rounded, its constant floored —
// over the integers. Every step is a term of the ring; the order changes no verdict
// over the rationals.
//
//   x in lo..hi      the branch with x < lo is empty, and so with x > hi
//   the image of t   what is left of t when every other unknown is eliminated

Conjunction :: struct {
	back:        Rewrite, // the atoms, each an unknown of the ring
	constraints: [dynamic]Type, // each d: d in 0..
	seen:        map[int]bool, // the unknowns whose layouts, the atoms whose types, are in
}

// in_range: x in lo..hi, an end nil for none, its ends terms or constants, for every
// value of the unknowns: each side's negation empty.
in_range :: proc(k: ^Kernel, x, lo, hi: Type) -> bool {
	// a shared node is never changed: its verdict, found once — but over a call, which
	// is the hypothesis while its equation is read
	key := Range_Key{node_of(x), node_of(lo), node_of(hi), int_value(lo), int_value(hi), lo != nil, hi != nil}
	if key.x != nil && !holds_call(k, x, false) {
		if known, found := k.ranges[key]; found do return known
		holds := decided_in_range(k, x, lo, hi)
		k.ranges[key] = holds
		return holds
	}
	return decided_in_range(k, x, lo, hi)
}

// Range_Key: a term and the ends of a range asked of it.
Range_Key :: struct {
	x, lo, hi:      rawptr,
	low, high:      i128, // ends that are constants
	has_lo, has_hi: bool,
}

int_value :: proc(t: Type) -> i128 {
	if c, constant := t.(Int); constant do return i128(c)
	return 0
}

decided_in_range :: proc(k: ^Kernel, x, lo, hi: Type) -> bool {
	if lo != nil {
		// lo - x - 1 ≥ 0, x < lo: empty?
		p: Conjunction
		d := difference(k, &p, lo, x, -1) or_return
		append(&p.constraints, d)
		if !empty(k, &p) do return false
	}
	if hi != nil {
		// x - hi - 1 ≥ 0, x > hi: empty?
		p: Conjunction
		d := difference(k, &p, x, hi, -1) or_return
		append(&p.constraints, d)
		if !empty(k, &p) do return false
	}
	return true
}

// projected: the least and greatest t may be, every other unknown eliminated.
projected :: proc(k: ^Kernel, t: Type) -> (lo, hi: Maybe(i128)) {
	if c, constant := t.(Int); constant do return i128(c), i128(c)
	// a shared node: projected once — but over a call, the hypothesis while its
	// equation is read
	node := node_of(t)
	if node != nil && !holds_call(k, t, false) {
		if known, found := k.projections[node]; found do return known[0], known[1]
		lo, hi = projection(k, t)
		k.projections[node] = {lo, hi}
		return
	}
	return projection(k, t)
}

projection :: proc(k: ^Kernel, t: Type) -> (lo, hi: Maybe(i128)) {
	p: Conjunction
	d, ok := term_of(k, &p, t)
	if !ok do return
	v := new_unknown(k, nil)
	// v - t ≥ 0 and t - v ≥ 0
	a, ok_a := ring_law(.Sub, {v, d})
	b, ok_b := ring_law(.Sub, {d, v})
	if !ok_a || !ok_b do return
	append(&p.constraints, a, b)
	for r in eliminate_all(rows_of(p.constraints[:]), v) {
		c: i128 = 0
		for us, i in r.unknowns do if len(us) == 1 && us[0] == v do c += r.coefs[i]
		if c == 0 || len(r.coefs) != 1 do continue
		rest := r.constant
		if c > 0 {
			// c·v + rest ≥ 0: v ≥ ⌈-rest / c⌉
			bound := -floor_div(rest, c)
			if l, has := lo.?; !has || bound > l do lo = bound
		} else {
			// v ≤ ⌊rest / -c⌋
			bound := floor_div(rest, -c)
			if h, has := hi.?; !has || bound < h do hi = bound
		}
	}
	return
}

// difference: a - b + c as a term of the ring, the constraints of its unknowns in p.
difference :: proc(k: ^Kernel, p: ^Conjunction, a, b: Type, c: i128) -> (d: Type, ok: bool) {
	x := term_of(k, p, a) or_return
	y := term_of(k, p, b) or_return
	d = ring_law(.Sub, {x, y}) or_return
	return ring_law(.Add, {d, Int(c)})
}

// term_of: t as a term of the ring over unknowns, its atoms named in p, and the
// constraints of each of its unknowns, of each of its atoms, added once.
term_of :: proc(k: ^Kernel, p: ^Conjunction, t: Type) -> (out: Type, ok: bool) {
	out = atomized(k, t, &p.back)
	ms, divisor := monomials(out) or_return
	if divisor != 1 do return
	for m in ms do for u in factors(m) do constrain(k, p, u)
	return out, true
}

// constrain: what the unknown u, or the atom it names, is known to be in: its layout;
// an atom, its type.
constrain :: proc(k: ^Kernel, p: ^Conjunction, u: ^Unknown) {
	if p.seen[u.id] do return
	p.seen[u.id] = true
	x, atom := rewritten(p.back, u)
	if !atom {
		within(k, p, u, layout_of(k, u))
		return
	}
	if o, is_op := x.(^Operation); is_op {
		#partial switch o.op {
		case .Mod:
			// x % m, m > 0: in 0..m - 1 when x ≥ 0, in -(m - 1)..m - 1 otherwise (§4.5)
			if m, constant := o.args[1].(Int); constant && m > 0 {
				least := in_range(k, o.args[0], Int(0), nil) ? Int(0) : Int(-(i128(m) - 1))
				within(k, p, u, new_range(least, Int(i128(m) - 1), .Int))
				return
			}
		case .Div:
			// a / c, c > 0, a ≥ 0: c·q ≤ a ≤ c·q + c - 1 (Euclid, §4.5)
			if c, constant := o.args[1].(Int); constant && c > 0 && in_range(k, o.args[0], Int(0), nil) {
				a, read := term_of(k, p, o.args[0])
				if !read do return
				cq, scaled := ring_law(.Mul, {Int(c), u})
				if !scaled do return
				if lower, ok := ring_law(.Sub, {a, cq}); ok do append(&p.constraints, lower)
				if upper, ok := ring_law(.Sub, {cq, a}); ok do if upper_c, ok_c := ring_law(.Add, {upper, Int(i128(c) - 1)}); ok_c do append(&p.constraints, upper_c)
				return
			}
		}
	}
	// a fold that adds, a Σ, a call that stays: their types; any other term, its values
	type: Type
	#partial switch v in x {
	case ^Fold:
		type, _ = fold_type(k, v)
	case ^Series:
		type, _ = series_type(k, v)
	case ^Collapse:
		if v.recursive do type, _ = call_type(k, v)
	}
	if type == nil do type, _ = values(k, x)
	if type != nil do within(k, p, u, type)
}

// within: u in the set s: a range l..h, u - l ≥ 0 and h - u ≥ 0, its ends terms; out
// of a half-line, in the other; =t, u = t; a meet, each of its terms; a set of
// constants, from its least to its greatest — what is left of it says less, never
// more.
within :: proc(k: ^Kernel, p: ^Conjunction, u: ^Unknown, s: Type) {
	terms := []Type{s}
	if both, meet := s.(^And); meet do terms = both.terms
	for t in terms {
		lo, hi: Type
		#partial switch v in t {
		case ^Range:
			if v.family == .Int || v.family == .Any do lo, hi = v.lo, v.hi
		case ^Not:
			if r, is_range := v.term.(^Range); is_range && (r.lo == nil) != (r.hi == nil) {
				if r.lo != nil do hi = op(k, .Sub, r.lo, Int(1))
				else do lo = op(k, .Add, r.hi, Int(1))
			}
		case ^Is:
			lo, hi = v.term, v.term
		}
		if lo == nil && hi == nil && is_constant(t) {
			if l, h, bounded := int_bounds(k, t); bounded {
				if x, has := l.?; has do lo = Int(x)
				if x, has := h.?; has do hi = Int(x)
			}
		}
		if lo != nil do if d, ok := difference(k, p, u, lo, 0); ok do append(&p.constraints, d)
		if hi != nil do if d, ok := difference(k, p, hi, u, 0); ok do append(&p.constraints, d)
	}
}

// Row: a constraint d ≥ 0 as the sum of its monomials, each a coefficient and its
// unknowns: the normal form of the ring, its factors read once.
Row :: struct {
	coefs:    []i128,
	unknowns: [][]^Unknown,
	constant: i128,
}

// row_of: the row of a term of the ring; false when it is not a polynomial.
row_of :: proc(t: Type) -> (r: Row, ok: bool) {
	ms, divisor := monomials(t) or_return
	if divisor != 1 do return
	coefs := make([dynamic]i128)
	us := make([dynamic][]^Unknown)
	for m in ms {
		fs := factors(m)
		if len(fs) == 0 {
			r.constant += coefficient(m)
			continue
		}
		append(&coefs, coefficient(m))
		append(&us, fs)
	}
	r.coefs, r.unknowns = coefs[:], us[:]
	return r, true
}

// empty: the constraints of p have no solution.
empty :: proc(k: ^Kernel, p: ^Conjunction) -> bool {
	rows := rows_of(p.constraints[:])
	for r in eliminate_all(rows, nil) do if len(r.coefs) == 0 && r.constant < 0 do return true
	return false
}

rows_of :: proc(ts: []Type) -> []Row {
	out := make([dynamic]Row)
	for t in ts do if r, ok := row_of(t); ok do append(&out, r)
	return out[:]
}

// eliminate_all: the rows with every unknown but keep eliminated; a row not linear
// in the unknown eliminated is left out — what is left says less, never more. A
// negative constant ends it: nothing is left to solve.
eliminate_all :: proc(rows: []Row, keep: ^Unknown) -> []Row {
	rows := rows
	for {
		for r in rows do if len(r.coefs) == 0 && r.constant < 0 do return rows
		u := next_unknown(rows, keep) or_break
		rows = eliminate(rows, u)
	}
	return rows
}

// next_unknown: an unknown the rows read, keep aside: the one that gives the fewest
// combinations.
next_unknown :: proc(rows: []Row, keep: ^Unknown) -> (best: ^Unknown, ok: bool) {
	counts := make(map[int][2]int)
	defer delete(counts)
	units := make(map[int]^Unknown)
	defer delete(units)
	for r in rows do for us, i in r.unknowns do for u in us {
		if keep != nil && u.id == keep.id do continue
		units[u.id] = u
		c := counts[u.id]
		if r.coefs[i] > 0 do c[0] += 1
		else do c[1] += 1
		counts[u.id] = c
	}
	least := max(int)
	for id, c in counts {
		if c[0] * c[1] < least || c[0] * c[1] == least && best != nil && id < best.id {
			least, best = c[0] * c[1], units[id]
		}
	}
	return best, best != nil
}

// eliminate: the rows without u: those that do not read it, and each pair of a row
// where u is above and one where it is below, combined so that u cancels.
eliminate :: proc(rows: []Row, u: ^Unknown) -> []Row {
	out := make([dynamic]Row)
	above, below := make([dynamic]Row), make([dynamic]Row)
	a_coef, b_coef := make([dynamic]i128), make([dynamic]i128)
	for r in rows {
		a, linear, reads := coefficient_of(r, u)
		switch {
		case !reads:
			append(&out, r)
		case !linear:
		case a > 0:
			append(&above, r)
			append(&a_coef, a)
		case:
			append(&below, r)
			append(&b_coef, -a)
		}
	}
	for r, i in above do for s, j in below {
		t, ok := combined(r, b_coef[j], s, a_coef[i])
		if !ok do continue
		t = tightened_row(t)
		// what holds always adds nothing
		if len(t.coefs) == 0 && t.constant >= 0 do continue
		known := false
		for o in out do known ||= same_row(o, t)
		if !known do append(&out, t)
	}
	return out[:]
}

// combined: x·r + y·s, the monomials of the same unknowns added.
combined :: proc(r: Row, x: i128, s: Row, y: i128) -> (out: Row, ok: bool) {
	coefs := make([dynamic]i128)
	us := make([dynamic][]^Unknown)
	add :: proc(coefs: ^[dynamic]i128, us: ^[dynamic][]^Unknown, f: []^Unknown, c: i128) -> bool {
		for x, i in us do if same_factors(x, f) {
			coefs[i] = add_checked(coefs[i], c) or_return
			return true
		}
		append(us, f)
		append(coefs, c)
		return true
	}
	for f, i in r.unknowns do add(&coefs, &us, f, mul_checked(r.coefs[i], x) or_return) or_return
	for f, i in s.unknowns do add(&coefs, &us, f, mul_checked(s.coefs[i], y) or_return) or_return
	kept_c := make([dynamic]i128)
	kept_u := make([dynamic][]^Unknown)
	for c, i in coefs do if c != 0 {
		append(&kept_c, c)
		append(&kept_u, us[i])
	}
	cr := mul_checked(r.constant, x) or_return
	cs := mul_checked(s.constant, y) or_return
	out.constant = add_checked(cr, cs) or_return
	out.coefs, out.unknowns = kept_c[:], kept_u[:]
	return out, true
}

// coefficient_of: the coefficient of u in the row, when u appears there alone in its
// monomials.
coefficient_of :: proc(r: Row, u: ^Unknown) -> (a: i128, linear, reads: bool) {
	linear = true
	for us, i in r.unknowns do for f in us do if f.id == u.id {
		reads = true
		if len(us) == 1 do a += r.coefs[i]
		else do linear = false
	}
	return
}

// tightened_row: d ≥ 0 over the integers: d = g·e + c, g the gcd of its coefficients,
// is e + ⌊c / g⌋ ≥ 0.
tightened_row :: proc(r: Row) -> Row {
	g: i128 = 0
	for c in r.coefs do g = gcd(g, abs(c))
	if g <= 1 do return r
	out := r
	out.coefs = make([]i128, len(r.coefs))
	for c, i in r.coefs do out.coefs[i] = c / g
	out.constant = floor_div(r.constant, g)
	return out
}

// same_row: the same constraint, monomial for monomial.
same_row :: proc(a, b: Row) -> bool {
	if a.constant != b.constant || len(a.coefs) != len(b.coefs) do return false
	outer: for f, i in a.unknowns {
		for g, j in b.unknowns do if a.coefs[i] == b.coefs[j] && same_factors(f, g) do continue outer
		return false
	}
	return true
}
