package kernel

// THE BOUNDS OF A CALL THAT STAYS, ON THE MEASURES OF ITS FIELDS (specs/types.md §5.6)
//
// What is bounded is a measure of what the call gives: its length, or a sum over its
// bindings Σ(x: 0..|X| - 1, g(X.#x)). The bound is a function of the measures mⱼ of
// the fields of its equation — the length of a run, the value of a count —:
//
//   hi = c + Σ aⱼ·mⱼ
//
// Its equation gives, over each of its products, hi ≥ the measure of the product,
// each call in it taken at hi of what it carves and every other term at its own
// image, for every value the branch lets the fields take: linear in c and the aⱼ by
// their coefficients, the least solution, the aⱼ first. lo likewise. The induction
// on the equation proves it: the solving only proposes it.

Measure :: enum u8 {
	Length, // |v|
	Items, // Σ over the bindings b of v of g(b)
}

// Measured_Field: a field of the equation and its measure: the length of a run, the
// value of a count.
Measured_Field :: struct {
	field: ^Unknown,
	run:   bool,
}

// measure_bound: lo and hi of the measure of what the call gives, over the measures
// of the fields its carve gives (nil where none is found). For Items, g is a term over
// the unknown item, the binding it is read at.
measure_bound :: proc(k: ^Kernel, call: ^Collapse, m: Measure, g: Type = nil, item: ^Unknown = nil) -> (lo, hi: Type, ok: bool) {
	s := call.target.(^Scope) or_return
	key, through := call_key(s), through_of(k, s)
	eq, found := equation_found(k, origin(s), key, through)
	if !found do eq = equation_of(k, origin(s), key, through) or_return
	if eq.term == nil do return
	// the fields, each with its measure
	fields := make([dynamic]Measured_Field)
	add_fields :: proc(k: ^Kernel, eq: ^Recursion, fields: ^[dynamic]Measured_Field) {
		for b in in_order(eq.params) {
			u := eq.params[b]
			if gives_scope(k, u) do append(fields, Measured_Field{u, true})
			else if proven_in(k, u, COUNTS) do append(fields, Measured_Field{u, false})
		}
		for b in in_order(eq.through) do add_fields(k, eq.through[b], fields)
	}
	add_fields(k, eq, &fields)
	at := values_of_call(k, eq, s)
	template :: proc(k: ^Kernel, fields: []Measured_Field, cs: []i128, at: Rewrite) -> Type {
		out: Type = Int(cs[0])
		for f, j in fields do if cs[j + 1] != 0 do out = op(k, .Add, out, op(k, .Mul, Int(cs[j + 1]), measure_of(k, f, f.field)))
		return rewrite(k, out, at)
	}
	if cs, solved := least_template(k, eq, fields[:], m, g, item, true); solved do hi = template(k, fields[:], cs, at)
	if cs, solved := least_template(k, eq, fields[:], m, g, item, false); solved do lo = template(k, fields[:], cs, at)
	return lo, hi, lo != nil || hi != nil
}

// measure_of: the measure of the field f at the value v: its length, or v.
measure_of :: proc(k: ^Kernel, f: Measured_Field, v: Type) -> Type {
	return f.run ? op(k, .Length, v) : v
}

// least_template: the coefficients c, a₀ … of the least hi (upper), or the greatest
// lo, the equation admits, by its products.
least_template :: proc(k: ^Kernel, eq: ^Recursion, fields: []Measured_Field, m: Measure, g: Type, item: ^Unknown, upper: bool) -> (cs: []i128, ok: bool) {
	// the unknowns: 0 is c, 1 + j is aⱼ; each row Σ coefs·unknowns + constant ≤ 0
	n := 1 + len(fields)
	sys: Lia
	for _ in 0 ..< n do append(&sys.atoms, None{})
	if upper do for j in 1 ..< n {
		// aⱼ ≥ 0
		r: Linear
		r.coefs = make(map[int]i128)
		r.coefs[j] = -1
		append(&sys.rows, r)
	}
	leaves := make([dynamic]Product)
	products(k, eq.term, &leaves)
	for leaf in leaves {
		if is_none(leaf.term) do continue
		bound_rows(k, eq, fields, m, g, item, leaf, upper, &sys) or_return
	}
	// the least of each aⱼ, then of c (the greatest for lo)
	cs = make([]i128, n)
	order := make([]int, n)
	for j in 0 ..< n do order[j] = (j + 1) % n
	for v in order {
		x, found := extreme_of(sys.rows[:], n, v, upper)
		if !found do return nil, false
		cs[v] = x
		// v = x
		eq_lo, eq_hi: Linear
		eq_lo.coefs, eq_hi.coefs = make(map[int]i128), make(map[int]i128)
		eq_lo.coefs[v], eq_lo.constant = 1, -x
		eq_hi.coefs[v], eq_hi.constant = -1, x
		append(&sys.rows, eq_lo, eq_hi)
	}
	if unsatisfiable(&sys) do return nil, false
	return cs, true
}

// extreme_of: the least value of the unknown v the rows admit (upper), or the
// greatest: every other unknown eliminated.
extreme_of :: proc(rows: []Linear, n, v: int, least: bool) -> (x: i128, found: bool) {
	rs := rows
	for a in 0 ..< n do if a != v do rs = eliminate_atom(rs, a)
	best: Maybe(i128)
	for r in rs {
		c := r.coefs[v] or_else 0
		if c == 0 {
			continue
		}
		// c·v + constant ≤ 0
		if least && c < 0 {
			bound := -floor_div(-r.constant, -c)
			if b, has := best.?; !has || bound > b do best = bound
		} else if !least && c > 0 {
			bound := floor_div(-r.constant, c)
			if b, has := best.?; !has || bound < b do best = bound
		}
	}
	return best.?
}

// bound_rows: the rows one product of the equation gives: T(m) ≥ its measure
// (upper) — each call at T of what it carves, every other term at its image —, for
// every measure the branch lets the fields take: by the coefficient of each measure,
// and where each is least.
bound_rows :: proc(k: ^Kernel, eq: ^Recursion, fields: []Measured_Field, m: Measure, g: Type, item: ^Unknown, leaf: Product, upper: bool, sys: ^Lia) -> bool {
	root := eq.root
	product := read_in(k, leaf, leaf.term)
	// each measure least where the branch narrows its field
	lows := make([]Maybe(i128), len(fields))
	for f, j in fields {
		narrowed := len(leaf.rewrite) > 0 ? rewrite(k, f.field, leaf.rewrite) : Type(f.field)
		lows[j], _ = extremes(k, measure_of(k, f, narrowed))
	}
	// the measure of the product, each call one unknown yᵢ
	calls := calls_in(k, product, root)
	ys := make([]^Unknown, len(calls))
	r: Rewrite
	for c, i in calls {
		ys[i] = new_unknown(k, nil)
		ys[i].layout = family_term(.Int)
	}
	measured: Type
	switch m {
	case .Length:
		measured = op(k, .Length, product)
		for c, i in calls do r = append_read(r, op(k, .Length, c), ys[i])
		measured = rewrite(k, measured, r)
	case .Items:
		// a call: its measure, y
		if c, is_call := called(product); is_call {
			for d, i in calls do if d == c do measured = ys[i]
			if measured == nil do return false
			break
		}
		v, is_scope := given(k, product).(^Scope)
		if !is_scope do return false
		measured = Int(0)
		for b in run_data(k, v) {
			x := binding_value(k, b)
			if b.kind == .Expand {
				c, is_call := called(x)
				if !is_call do return false
				at := -1
				for d, i in calls do if d == c do at = i
				if at < 0 do return false
				measured = op(k, .Add, measured, ys[at])
				continue
			}
			measured = op(k, .Add, measured, rewrite(k, g, rewriting(nil, item, x)))
		}
	}
	// coefficient of each unknown of the template, a term over the fields: c the count
	// of calls taken, aⱼ the measure of field j less those the calls carve; free, the
	// rest of the measure, negated
	coef := make([]Type, 1 + len(fields))
	coef[0] = Int(1)
	for f, j in fields do coef[j + 1] = measure_of(k, f, f.field)
	free := measured
	for c, i in calls {
		alpha, _, affine := affine_in(k, measured, ys[i])
		a, constant := alpha.(Int)
		if !affine || !constant || a < 0 do return false
		free = rewrite(k, free, rewriting(nil, ys[i], Int(0)))
		_, next, moving := moves(k, eq, c)
		if !moving do return false
		coef[0] = op(k, .Sub, coef[0], Int(a))
		for f, j in fields {
			v, carved := next[f.field]
			if !carved do return false
			coef[j + 1] = op(k, .Sub, coef[j + 1], op(k, .Mul, Int(a), measure_of(k, f, v)))
		}
	}
	if !solved(free, root) do return false
	// D = Σ coefᵤ·u − free ≥ 0 (upper), ≤ 0 (lower): each coefficient linear over the
	// measures of the fields — a field as narrowed by the branch or not —; every other
	// atom of free at its image
	s: Lia
	measure_index :: proc(fields: []Measured_Field, t: Type) -> int {
		for f, j in fields {
			x := t
			if f.run {
				o, is_op := t.(^Operation)
				if !is_op || o.op != .Length do continue
				x = o.args[0]
			}
			if u, is_unknown := x.(^Unknown); is_unknown && same_unknown(u, f.field) do return j
		}
		return -1
	}
	// rows over the template unknowns: for each measure μ, its coefficient in D;
	// and D where every measure is least
	per := make([]Linear, len(fields))
	for &p in per do p.coefs = make(map[int]i128)
	at_least: Linear
	at_least.coefs = make(map[int]i128)
	for t, u in coef {
		x := linear_of(k, &s, t) or_return
		at_least.coefs[u] += x.constant
		for atom, c in x.coefs {
			if c == 0 do continue
			j := measure_index(fields, s.atoms[atom])
			if j < 0 do return false
			per[j].coefs[u] += c
			at_least.coefs[u] += c * (lows[j].? or_return)
		}
	}
	fx := linear_of(k, &s, free) or_return
	at_least.constant -= fx.constant
	for atom, c in fx.coefs {
		if c == 0 do continue
		if j := measure_index(fields, s.atoms[atom]); j >= 0 {
			per[j].constant -= c
			at_least.constant -= c * (lows[j].? or_return)
			continue
		}
		// another atom at its image: its greatest where it adds (upper)
		lo, hi := extremes(k, s.atoms[atom])
		bound := (c > 0) == upper ? hi : lo
		at_least.constant -= c * (bound.? or_return)
	}
	// upper: each per ≥ 0 and at_least ≥ 0, as rows ≤ 0 their negation; lower: ≤ 0
	sign: i128 = upper ? -1 : 1
	for p in per do append(&sys.rows, scaled(p, sign))
	append(&sys.rows, scaled(at_least, sign))
	return true
}
