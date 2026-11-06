package kernel

import syn "../syntax"
import "core:slice"

// FOLDS (specs/types.md §5.6): the laws of a fold ⟳ along an orbit, of μ, of Σ and of
// C-finite sequences, each a local law the normal form applies.

// op: the normal form of the operation.
op :: proc(k: ^Kernel, o: Operator, args: ..Type) -> Type {
	return normal(k, new_operation(o, ..args))
}

// affine_in: t = α·y + β, α and β not reading y: t of degree 1 in y, by the ring
// law (ring.odin).
affine_in :: proc(k: ^Kernel, t: Type, y: ^Unknown) -> (alpha, beta: Type, ok: bool) {
	// what the ring does not read is an atom: a call, a fold, a pattern
	back: Rewrite
	ms, divisor := monomials(atomized(k, t, &back)) or_return
	if divisor != 1 do return
	as, bs := make([dynamic]Type), make([dynamic]Type)
	for m in ms {
		rest := make([dynamic]^Unknown)
		degree := 0
		for f in factors(m) {
			if same_unknown(f, y) do degree += 1
			else do append(&rest, f)
		}
		switch degree {
		case 0:
			append(&bs, m)
		case 1:
			append(&as, monomial(coefficient(m), rest[:]))
		case:
			return
		}
	}
	alpha = unatomized(ring_term(as[:], 1) or_return, back)
	beta = unatomized(ring_term(bs[:], 1) or_return, back)
	// an atom that holds y: t is not of degree 1 in y
	if reads(k, alpha, y) || reads(k, beta, y) do return nil, nil, false
	return alpha, beta, true
}

// orbit: kᵢ = sⁱ(m), the i-th point of the orbit of m by s(x), when it has a closed
// form: s(x) = α·x + β gives m + β·i when α = 1, αⁱ·m + β·(αⁱ - 1)/(α - 1)
// otherwise; s(x) = x / c gives m / cⁱ; s(x) = x >> c gives m >> c·i.
orbit :: proc(k: ^Kernel, s: Type, x: ^Unknown, m: Type, i: ^Unknown) -> (Type, bool) {
	if alpha, beta, affine := affine_in(k, s, x); affine {
		a, is_int := alpha.(Int)
		b, constant := beta.(Int)
		if is_int && constant && a == 1 do return op(k, .Add, m, op(k, .Mul, b, i)), true
		if is_int && constant && a != 0 {
			power := op(k, .Pow, a, i)
			return op(k, .Add, op(k, .Mul, power, m), op(k, .Div, op(k, .Mul, b, op(k, .Sub, power, Int(1))), Int(a - 1))), true
		}
	}
	o, is_op := s.(^Operation)
	if !is_op || len(o.args) != 2 do return nil, false
	y, is_x := o.args[0].(^Unknown)
	c, constant := o.args[1].(Int)
	if !is_x || !same_unknown(y, x) || !constant || c <= 0 do return nil, false
	shift: i128
	#partial switch o.op {
	case .From:
		return op(k, .From, m, op(k, .Mul, Int(c), i)), true
	case .Shr:
		shift = i128(c)
	case .Div:
		// (m / c) / c = m / c², / rounding toward 0 (§4.5), whatever the sign of m
		return op(k, .Div, m, op(k, .Pow, c, i)), true
	case:
		return nil, false
	}
	return op(k, .Shr, m, op(k, .Mul, Int(shift), i)), true
}

// orbit_index: k, a point of the orbit where the fold goes on: u in its layout,
// out of stop.
orbit_index :: proc(k: ^Kernel, u: ^Unknown, stop: Type) -> ^Unknown {
	index := new_unknown(k, nil)
	index.layout = and_law(k, {layout_of(k, u), not_law(k, stop)})
	return index
}

// least_law: μ(i: t). When t is kᵢ in B, kᵢ moving by one — down into B = ..b, or
// onto its point b from above; up into b.. —, μ is where it crosses in: the
// distance m - b, or 0 when m is in B already. Moving by c into a half-line, it
// crosses in ⌈distance / c⌉ steps.
least_law :: proc(k: ^Kernel, i: ^Unknown, holds: Type, span: syn.Span) -> Type {
	if is_bool(holds, true) do return Int(0)
	out := new(Least)
	out.index, out.holds, out.span = i, holds, span
	o, is_in := holds.(^Operation)
	if !is_in || o.op != .In do return out
	// μ(i: m from c·i has fewer than c pieces) = |m| / c
	if rest, is_from := o.args[0].(^Operation); is_from && rest.op == .From {
		c, at, along := affine_in(k, rest.args[1], i)
		step, constant := c.(Int)
		if along && constant && step > 0 && is_int(at, 0) && fewer_than(o.args[1], i128(step)) do return op(k, .Div, op(k, .Length, rest.args[0]), Int(step))
	}
	alpha, beta, affine := affine_in(k, o.args[0], i)
	slope, is_int := alpha.(Int)
	if !affine || !is_int || slope == 0 do return out
	one: [1]Type
	cells, negated := cells_in(o.args[1], &one)
	if negated || len(cells) != 1 do return out
	lo, hi := discrete_bounds(cells[0])
	l, has_lo := lo.?
	h, has_hi := hi.?
	// onto a point: only by steps of one
	if has_lo && has_hi && (l != h || slope != 1 && slope != -1) do return out
	gap: Type
	switch {
	case slope < 0 && has_hi:
		gap = op(k, .Sub, beta, Int(h))
		if has_lo && !proven_in(k, gap, COUNTS) do return out // onto the point
	case slope > 0 && has_lo:
		gap = op(k, .Sub, Int(l), beta)
		if has_hi && !proven_in(k, gap, COUNTS) do return out
	case:
		return out
	}
	// by steps of c: the gap in steps, ⌈gap / c⌉ = (gap + c - 1) / c for gap ≥ 0
	c := abs(slope)
	if c != 1 {
		if !proven_in(k, gap, COUNTS) do return out
		return op(k, .Div, op(k, .Add, gap, Int(c - 1)), Int(c))
	}
	// max(gap, 0)
	if proven_in(k, gap, COUNTS) do return gap
	if proven_in(k, gap, NONPOSITIVE) do return Int(0)
	m := new(Pattern)
	m.target, m.span = gap, span
	m.branches = slice.clone([]Branch{{cover = NONPOSITIVE, product = Int(0)}, {product = gap}})
	return pattern_law(k, m)
}

// continues: the orbit, once in B, stays in it — kᵢ decreasing, B = ..b, or
// increasing, B = b.. —: the points after the end of the orbit are base cases.
continues :: proc(k: ^Kernel, stop: Type, ki: Type, i: ^Unknown) -> bool {
	r, is_range := stop.(^Range)
	if !is_range do return false
	alpha, _, affine := affine_in(k, ki, i)
	slope, is_int := alpha.(Int)
	if !affine || !is_int do return false
	return slope < 0 && r.lo == nil || slope > 0 && r.hi == nil
}

// folded: the fold as a term: by its laws, when it has no effect; otherwise an
// effect that gives it back, bound in what follows. When neither its states nor its
// value read what the effects give back, and the effects do not read the states,
// the states cross them (§4.8): the effects fold alone, then the rest.
folded :: proc(k: ^Kernel, fold: ^Fold) -> Type {
	fold := fold
	if g, along := along_orbit(k, fold); along do fold = g
	f := simplified(k, fold)
	if !has_effect(f.effects) do return fold_law(k, f)
	crosses := !has_effect(f.value)
	for x in chain_answers(f.effects) {
		if x == nil do continue
		crosses &&= !reads(k, f.value, x)
		for t in f.updates do crosses &&= !reads(k, t, x)
	}
	for x in f.states do crosses &&= !reads(k, f.effects, x)
	out := new(Effect)
	out.id, out.fold, out.span = -1, f, f.span
	if crosses {
		effects := new(Fold)
		effects^ = f^
		effects.states, effects.inits, effects.updates, effects.value = nil, nil, nil, None{}
		pure := new(Fold)
		pure^ = f^
		pure.effects = None{}
		out.fold, out.then = effects, fold_law(k, pure)
		return out
	}
	if is_none(f.value) {
		out.then = None{}
		return out
	}
	out.answer = new_unknown(k, nil)
	if family, known := family_of(k, f.value); known do out.answer.layout = family_term(family)
	out.then = out.answer
	return out
}

// fold_law: a fold whose steps have no effect, by the laws of folds: what does not
// change is not folded, and a state that adds a polynomial in k along a counter is
// a sum with a closed form (simplified); a fold left with nothing to fold, whose
// value does not read k, is its value, effects included.
fold_law :: proc(k: ^Kernel, f: ^Fold) -> Type {
	// it starts where it stops: no step runs, the value is that of the inits
	if is_bool(in_law(k, f.start, f.stop), true) {
		at := rewriting(nil, f.index, f.start)
		for z, i in f.states do at = rewriting(at, z, f.inits[i])
		return rewrite(k, f.value, at)
	}
	if g, along := along_orbit(k, f); along do return fold_law(k, g)
	g := simplified(k, f)
	if is_none(g.effects) && len(g.states) == 0 && !reads(k, g.value, g.index) do return g.value
	return g
}

// along_orbit: a fold whose index moves from m by a step whose orbit has a closed
// form, kᵢ = sⁱ(m), is the fold along i from 0 until n = μ(i: kᵢ in the stop), each
// read of its index kᵢ (§5.6): its steps counted.
along_orbit :: proc(k: ^Kernel, f: ^Fold) -> (g: ^Fold, ok: bool) {
	if _, _, counter := counter_range(k, f); counter do return
	i := new_unknown(k, nil)
	i.layout = COUNTS
	ki := orbit(k, f.next, f.index, f.start, i) or_return
	j := new_unknown(k, nil)
	j.layout = COUNTS
	n := least_law(k, j, in_law(k, rewrite(k, ki, rewriting(nil, i, j)), f.stop), f.span)
	// along the orbit, before it stops: i in 0.. and below n — 0.. & ..(n - 1), none
	// when n is 0 (a range holds what is between its ends, either way)
	along := new_unknown(k, nil)
	along.layout = and_law(k, {COUNTS, range_law(k, nil, op(k, .Sub, n, Int(1)), .Int, f.span)})
	ki = rewrite(k, ki, rewriting(nil, i, along))
	i = along
	at := rewriting(nil, f.index, ki)
	g = new(Fold)
	g^ = f^
	g.index, g.start, g.next, g.stop = i, Int(0), op(k, .Add, i, Int(1)), new_range(n, nil, .Int)
	g.updates = make([]Type, len(f.updates))
	for t, x in f.updates do g.updates[x] = rewrite(k, t, at)
	g.effects, g.value = rewrite(k, f.effects, at), rewrite(k, f.value, at)
	return g, true
}

// simplified: the fold, its states reduced by the laws of folds, until none applies:
//
//   a state whose update is itself is its init           x ↦ x
//   a state nothing reads is not folded
//   along a counter, a state read by the value only, whose update is a first-order
//   linear recurrence with constant coefficient, x ↦ r·x + g(k), g a polynomial in
//   k, has a closed form where k stops (closed)
//   along a counter, states whose updates are a linear map with integer
//   coefficients are each a C-finite sequence (linear_states)
simplified :: proc(k: ^Kernel, f: ^Fold) -> ^Fold {
	out := carrying(k, f)
	for changed := true; changed; {
		changed = false
		for x, i in out.states {
			// x: e ↦ u(x), u reading x only and u(e) = e: x is e
			if fixed(k, out, i) {
				out = without_state(k, out, i, out.inits[i])
				changed = true
				break
			}
			read := reads(k, out.value, x) || reads(k, out.effects, x)
			for t, j in out.updates do read ||= j != i && reads(k, t, x)
			if !read {
				out = without_state(k, out, i, nil)
				changed = true
				break
			}
			if !is_none(out.effects) || reads_other_updates(k, out, i) do continue
			if end, closed := closed(k, out, i); closed {
				out = without_state(k, out, i, end)
				changed = true
				break
			}
		}
	}
	if linear, ok := linear_states(k, out); ok do return linear
	return out
}

// linear_states: the fold whose states, along a counter of n steps, take a linear
// map with integer coefficients, x ↦ M·x + b: each state is the C-finite sequence
// of the characteristic polynomial of M — b a state of its own, always 1 — by
// Cayley–Hamilton, from its first values (§5.6); the fold is its value, read
// where the states end.
linear_states :: proc(k: ^Kernel, f: ^Fold) -> (folded: ^Fold, ok: bool) {
	if len(f.states) == 0 || !is_none(f.effects) || reads(k, f.value, f.index) do return
	for t in f.updates do if reads(k, t, f.index) do return
	lo, hi := counter_range(k, f) or_return
	n := len(f.states)
	// M, n + 1 square: the last row and column for the constant 1
	m := make([][]i128, n + 1)
	for &row in m do row = make([]i128, n + 1)
	m[n][n] = 1
	affine := false
	for t, i in f.updates {
		ms, d := monomials(t) or_return
		if d != 1 do return
		for mono in ms {
			fs := factors(mono)
			switch len(fs) {
			case 0:
				m[i][n] += coefficient(mono)
				affine = true
			case 1:
				j := -1
				for x, l in f.states do if same_unknown(x, fs[0]) do j = l
				if j < 0 do return
				m[i][j] += coefficient(mono)
			case:
				return
			}
		}
	}
	size := affine ? n + 1 : n
	coefficients := characteristic(m[:size], size) or_return
	// the first values of each state: s₀ the inits, s_{t+1} the updates of s_t
	steps := make([][]Type, size)
	steps[0] = slice.clone(f.inits)
	for t in 1 ..< size {
		r: Rewrite
		for x, j in f.states do r = rewriting(r, x, steps[t - 1][j])
		steps[t] = make([]Type, n)
		for u, j in f.updates do steps[t][j] = rewrite(k, u, r)
	}
	count := op(k, .Add, op(k, .Sub, hi, lo), Int(1))
	ends: Rewrite
	for x, j in f.states {
		seq := new(Recurrent)
		seq.coefficients, seq.at, seq.span = coefficients, count, f.span
		seq.initial = make([]Type, size)
		for t in 0 ..< size do seq.initial[t] = steps[t][j]
		ends = rewriting(ends, x, recurrent_law(k, seq))
	}
	out := new(Fold)
	out^ = f^
	out.states, out.inits, out.updates = nil, nil, nil
	out.value = rewrite(k, f.value, ends)
	return out, true
}

// characteristic: c₁ … c_d with x^d - c₁·x^{d-1} - … - c_d the characteristic
// polynomial of the square matrix m of size d, by Faddeev–LeVerrier:
// M₀ = 0, M_k = m·M_{k-1} + p_{d-k+1}·I, p_{d-k} = -tr(m·M_k) / k.
characteristic :: proc(m: [][]i128, d: int) -> (out: []i128, ok: bool) {
	times :: proc(a, b: [][]i128, d: int) -> (c: [][]i128, ok: bool) {
		c = make([][]i128, d)
		for &row, i in c {
			row = make([]i128, d)
			for j in 0 ..< d do for l in 0 ..< d {
				p := mul_checked(a[i][l], b[l][j]) or_return
				row[j] = add_checked(row[j], p) or_return
			}
		}
		return c, true
	}
	p := make([]i128, d + 1)
	p[d] = 1
	current := make([][]i128, d)
	for &row in current do row = make([]i128, d)
	for step in 1 ..= d {
		current = times(m, current, d) or_return
		for i in 0 ..< d do current[i][i] = add_checked(current[i][i], p[d - step + 1]) or_return
		am := times(m, current, d) or_return
		trace: i128 = 0
		for i in 0 ..< d do trace = add_checked(trace, am[i][i]) or_return
		if trace % i128(step) != 0 do return nil, false
		p[d - step] = -trace / i128(step)
	}
	out = make([]i128, d)
	for j in 1 ..= d do out[j - 1] = -p[d - j]
	return out, true
}

// recurrent_law: C⟨c₁ … c_d | x₀ … x_{d-1}⟩(s), by its laws:
//
//   s known                  x_s = Σ_j x_j·[αˢ]_j, αˢ by squaring in ℤ[α]
//   d = 1                    x₀ * c₁ ** s
//   d = 2, Δ = c₁² + 4·c₂ a square, the roots r = (c₁ ± √Δ) / 2 integers:
//     r₁ ≠ r₂                x_s = A * r₁ ** s + B * r₂ ** s
//     r₁ = r₂ = r            x_s = (A + B * s) * r ** s
//   A and B from x₀ and x₁, the closed form preferred to the power
recurrent_law :: proc(k: ^Kernel, r: ^Recurrent) -> Type {
	d := len(r.coefficients)
	if s, known := r.at.(Int); known && s >= 0 {
		if int(s) < d do return r.initial[s]
		if power, ok := algebraic_power(r.coefficients, i128(s)); ok {
			out: Type = Int(0)
			for x, j in r.initial do out = op(k, .Add, out, op(k, .Mul, x, Int(power[j])))
			return out
		}
	}
	if d == 1 do return op(k, .Mul, r.initial[0], op(k, .Pow, Int(r.coefficients[0]), r.at))
	if d == 2 {
		c1, c2 := r.coefficients[0], r.coefficients[1]
		x0, x1 := r.initial[0], r.initial[1]
		disc := c1 * c1 + 4 * c2
		root, square := integer_sqrt(disc)
		if square && (c1 + root) % 2 == 0 {
			r1, r2 := (c1 + root) / 2, (c1 - root) / 2
			if r1 != r2 {
				// A + B = x₀, A·r₁ + B·r₂ = x₁
				b := op(k, .Div, op(k, .Sub, x1, op(k, .Mul, Int(r1), x0)), Int(r2 - r1))
				a := op(k, .Sub, x0, b)
				return op(k, .Add, op(k, .Mul, a, op(k, .Pow, Int(r1), r.at)), op(k, .Mul, b, op(k, .Pow, Int(r2), r.at)))
			}
			if r1 != 0 {
				// A = x₀, (A + B)·r = x₁
				b := op(k, .Sub, op(k, .Div, x1, Int(r1)), x0)
				return op(k, .Mul, op(k, .Add, x0, op(k, .Mul, b, r.at)), op(k, .Pow, Int(r1), r.at))
			}
		}
	}
	return r
}

// integer_sqrt: the root of n, when n is a square: Newton's iteration on the
// integers, r ↦ (r + n / r) / 2, from n down.
integer_sqrt :: proc(n: i128) -> (root: i128, square: bool) {
	if n < 2 do return n, n >= 0
	r := n
	for next := (r + n / r) / 2; next < r; next = (r + n / r) / 2 do r = next
	return r, r * r == n
}

// algebraic_power: the coordinates of αˢ in ℤ[α], α a root of x^d - c₁·x^{d-1}
// - … - c_d, by squaring: a product is reduced by α^d = c₁·α^{d-1} + … + c_d.
algebraic_power :: proc(c: []i128, s: i128) -> (out: []i128, ok: bool) {
	d := len(c)
	product :: proc(a, b, c: []i128) -> (out: []i128, ok: bool) {
		d := len(c)
		full := make([]i128, 2 * d - 1)
		for x, i in a do for y, j in b {
			p := mul_checked(x, y) or_return
			full[i + j] = add_checked(full[i + j], p) or_return
		}
		#reverse for _, t in full {
			if t < d do break
			for cj, j in c {
				p := mul_checked(full[t], cj) or_return
				full[t - 1 - j] = add_checked(full[t - 1 - j], p) or_return
			}
			full[t] = 0
		}
		return slice.clone(full[:d]), true
	}
	out = make([]i128, d)
	out[0] = 1
	base := make([]i128, d)
	if d == 1 do base[0] = c[0]
	else do base[1] = 1
	for e := s; e > 0; e >>= 1 {
		if e & 1 == 1 do out = product(out, base, c) or_return
		if e > 1 do base = product(base, base, c) or_return
	}
	return out, true
}

// reads_other_updates: another state's update reads the state i.
reads_other_updates :: proc(k: ^Kernel, f: ^Fold, i: int) -> bool {
	for t, j in f.updates do if j != i && reads(k, t, f.states[i]) do return true
	return false
}

// without_state: the fold without its state i, which reads `by` where it was;
// nil when nothing reads it.
without_state :: proc(k: ^Kernel, f: ^Fold, i: int, by: Type) -> ^Fold {
	parts := fold_parts(f)
	if by != nil {
		r := rewriting(nil, f.states[i], by)
		for &t in parts do t = rewrite(k, t, r)
	}
	out := with_parts(f, parts)
	states := make([dynamic]^Unknown)
	inits := make([dynamic]Type)
	updates := make([dynamic]Type)
	for j in 0 ..< len(f.states) {
		if j == i do continue
		append(&states, f.states[j])
		append(&inits, out.inits[j])
		append(&updates, out.updates[j])
	}
	out.states, out.inits, out.updates = states[:], inits[:], updates[:]
	return out
}

// closed: the state i where k stops, along a counter, when its update is
// x ↦ r·x + g(k), r an integer and g a polynomial in k over the other unknowns but
// the states. With t the number of steps taken, k = lo + t going up or hi - t
// going down, and n = hi - lo + 1 of them:
//
//   r = 1         x = x₀ + G(hi) - G(lo - 1)     G(m) = g(0) + … + g(m), by the
//                                                 sums of powers (Faulhaber)
//   r ≠ 1         x = P(n) + (x₀ - P(0))·rⁿ     P the polynomial with
//                                                 P(t + 1) = r·P(t) + g(t), by its
//                                                 coefficients (undetermined)
//
// The ring computes on lo, hi and x₀ as polynomials over atoms (atomized), put
// back at the end.
closed :: proc(k: ^Kernel, f: ^Fold, i: int) -> (end: Type, ok: bool) {
	first, last := counter_range(k, f) or_return
	x := f.states[i]
	// the update over atoms, none of which reads a state
	parts: Rewrite
	update := atomized(k, f.updates[i], &parts)
	for a in parts do for y in f.states do if reads(k, a.term, y) do return
	alpha, beta := affine_in(k, update, x) or_return
	alpha, beta = rewrite(k, alpha, parts), rewrite(k, beta, parts)
	for y in f.states do if reads(k, alpha, y) || reads(k, beta, y) do return
	r, constant := alpha.(Int)
	switch {
	case constant && r == 1:
		// x ↦ x + g(k): x₀ + Σ g
		return op(k, .Add, f.inits[i], series(k, .Add, f.index, first, last, beta)), true
	case same(k, beta, Int(0)) && reads(k, alpha, f.index):
		// x ↦ α(k)·x: x₀ · Π α
		return op(k, .Mul, f.inits[i], series(k, .Mul, f.index, first, last, alpha)), true
	case !constant || !is_ring(beta):
		return
	}
	bounds: Rewrite
	lo, hi := atomized(k, first, &bounds), atomized(k, last, &bounds)
	init := atomized(k, f.inits[i], &bounds)
	g := beta
	ms, divisor := monomials(g) or_return
	// g in t, the steps taken
	t := new_unknown(k, nil)
	t.layout = COUNTS
	place: Type
	if same(k, f.next, op(k, .Add, f.index, Int(1))) do place = ring_law(.Add, {lo, t}) or_return
	else do place = ring_law(.Sub, {hi, t}) or_return
	gt := rewrite(k, ring_over(g, divisor) or_return, rewriting(nil, f.index, place))
	// its coefficients by the powers of t
	tms, td := monomials(gt) or_return
	degree := 0
	for m in tms {
		p := 0
		for u in factors(m) do if same_unknown(u, t) do p += 1
		degree = max(degree, p)
	}
	coefficients := make([]Type, degree + 1)
	for &c in coefficients do c = Int(0)
	for m in tms {
		p := 0
		others := make([dynamic]^Unknown)
		for u in factors(m) {
			if same_unknown(u, t) do p += 1
			else do append(&others, u)
		}
		coefficients[p] = ring_law(.Add, {coefficients[p], monomial(coefficient(m), others[:])}) or_return
	}
	for &c in coefficients do c = ring_over(c, td) or_return
	// P(t + 1) - r·P(t) = g(t): from the highest power down,
	// pₑ = (Σ_{d>e} C(d, e)·p_d - gₑ) / (r - 1)
	ps := make([]Type, degree + 1)
	#reverse for _, e in ps {
		acc := ring_law(.Neg, {coefficients[e]}) or_return
		for d in e + 1 ..= degree do acc = ring_law(.Add, {acc, ring_law(.Mul, {Int(binomial(d, e)), ps[d]}) or_return}) or_return
		if r < 1 do acc = ring_law(.Neg, {acc}) or_return
		ps[e] = ring_over(acc, abs(i128(r) - 1)) or_return
	}
	poly: Type = Int(0)
	tᵉ: Type = Int(1)
	for pe in ps {
		poly = ring_law(.Add, {poly, ring_law(.Mul, {pe, tᵉ}) or_return}) or_return
		tᵉ = ring_law(.Mul, {tᵉ, t}) or_return
	}
	n := ring_law(.Add, {ring_law(.Sub, {hi, lo}) or_return, Int(1)}) or_return
	at_n := ring_at(poly, t, n) or_return
	at_0 := ring_at(poly, t, Int(0)) or_return
	// rⁿ an atom, so that the whole is one polynomial over one divisor: its parts
	// alone need not be integers
	rⁿ := atomized(k, op(k, .Pow, r, rewrite(k, n, bounds)), &bounds)
	start := ring_law(.Sub, {init, at_0}) or_return
	whole := ring_law(.Add, {at_n, ring_law(.Mul, {start, rⁿ}) or_return}) or_return
	return rewrite(k, whole, bounds), true
}

// ring_at: the polynomial t with u replaced by v, in the ring: over its divisor,
// whatever its parts are worth alone.
ring_at :: proc(t: Type, u: ^Unknown, v: Type) -> (out: Type, ok: bool) {
	ms, d := monomials(t) or_return
	out = Int(0)
	for m in ms {
		term: Type = Int(coefficient(m))
		for f in factors(m) do term = ring_law(.Mul, {term, same_unknown(f, u) ? v : f}) or_return
		out = ring_law(.Add, {out, term}) or_return
	}
	return ring_over(out, d)
}

// atomized: t as a polynomial (ring.odin) over atoms: each term the ring does not
// read — a μ, a pattern — is named by an unknown of its own, which back rewrites to
// it. In the field (ring.odin), over the reals. A sum, a product keep their form,
// their operands atomized: the ring reads it whole, once (monomials, ring_law).
atomized :: proc(k: ^Kernel, t: Type, back: ^Rewrite, field := false) -> Type {
	#partial switch v in t {
	case ^Unknown:
		return t
	case Int:
		if !field do return t
	case Real:
		if field do return t
	case ^Operation:
		#partial switch v.op {
		case .Add, .Sub, .Mul, .Neg:
			if is_string_value(t) do break
			args := make([]Type, len(v.args))
			for a, i in v.args do args[i] = atomized(k, a, back, field)
			return new_operation(v.op, ..args)
		}
	}
	for x in back do if x.unknown != nil && same(k, x.term, t) do return x.unknown
	u := new_unknown(k, nil)
	u.layout = family_term(field ? .Real : .Int)
	back^ = rewriting(back^, u, t)
	return u
}

// is_ring: t is a polynomial (ring.odin).
is_ring :: proc(t: Type) -> bool {
	_, _, ok := monomials(t)
	return ok
}

// series: Σ(j: lo..hi, t) or Π, with j for the index i of t, by their laws.
series :: proc(k: ^Kernel, o: Operator, i: ^Unknown, lo, hi, t: Type) -> Type {
	s := new(Series)
	s.op, s.lo, s.hi = o, lo, hi
	// the index takes the values from lo up to hi: lo.. & ..hi, none over an empty
	// range (a range holds what is between its ends, either way)
	s.index = new_unknown(k, nil)
	s.index.layout = and_law(k, {range_law(k, lo, nil, .Int, {}), range_law(k, nil, hi, .Int, {})})
	s.term = rewrite(k, t, rewriting(nil, i, s.index))
	return series_law(k, s)
}

// series_law: Σ(i: lo..hi, t) and Π(i: lo..hi, t), by their laws:
//
//   over an empty range                    0, 1
//   Σ, t a polynomial in i over atoms      G(hi) - G(lo - 1), G(m) = t(0) + … + t(m),
//                                          by the sums of powers (Faulhaber)
//   Π, t not reading i                     t ** n, n = hi - lo + 1
//   Π, t = c·uᵃ·iᵖ…, a monomial            cⁿ·(u ** n)ᵃ·(Π(i: lo..hi, i))ᵖ…
//   Π, c the content of t, > 1             cⁿ·Π(i: lo..hi, t / c)
//   Π, t = ±i + b                          Π(j: lo'..hi', j), over the integers
//                                          t runs through, upward
//   Π(j: a..b, j), a ≤ 0 ≤ b               0
series_law :: proc(k: ^Kernel, s: ^Series) -> Type {
	identity: Type = s.op == .Add ? Type(Int(0)) : Type(Int(1))
	n := op(k, .Add, op(k, .Sub, s.hi, s.lo), Int(1))
	if proven_in(k, n, NONPOSITIVE) do return identity
	if s.op == .Add {
		if sum, closed := faulhaber(k, s); closed do return sum
		if x, bitwise := bitwise_sum(k, s); bitwise do return x
		if f, summed := summed_fold(k, s); summed do return f
		// a Σ is the fold that adds its terms (x ↦ x + g(i)): reading, along its
		// index, a run a fold builds, it is that fold, the run never built
		if f, carried := carried_sum(k, s); carried do return f
		return s
	}
	if !reads(k, s.term, s.index) do return op(k, .Pow, s.term, n)
	if ms, d, ring := monomials(s.term); ring && len(ms) == 1 && d == 1 {
		m := ms[0]
		p := 0
		out := op(k, .Pow, Int(coefficient(m)), n)
		for u in factors(m) {
			if same_unknown(u, s.index) do p += 1
			else do out = op(k, .Mul, out, op(k, .Pow, u, n))
		}
		if p > 0 && !(p == 1 && len(factors(m)) == 1 && coefficient(m) == 1) {
			ascending := new(Series)
			ascending^ = s^
			ascending.term = s.index
			return op(k, .Mul, out, op(k, .Pow, series_law(k, ascending), Int(p)))
		}
	}
	if ms, d, ring := monomials(s.term); ring && d == 1 {
		content: i128 = 0
		for m in ms do content = gcd(content, abs(coefficient(m)))
		if content > 1 {
			reduced := make([]Type, len(ms))
			for m, j in ms do reduced[j] = monomial(coefficient(m) / content, factors(m))
			if t, ok := ring_term(reduced, 1); ok {
				primitive := new(Series)
				primitive^ = s^
				primitive.term = t
				return op(k, .Mul, op(k, .Pow, Int(content), n), series_law(k, primitive))
			}
		}
	}
	if alpha, beta, affine := affine_in(k, s.term, s.index); affine {
		if a, unit := alpha.(Int); unit && (a == 1 || a == -1) && !(a == 1 && same(k, beta, Int(0))) {
			// j = ±i + b runs through the integers between its ends
			from, to := op(k, .Add, op(k, .Mul, a, s.lo), beta), op(k, .Add, op(k, .Mul, a, s.hi), beta)
			if a < 0 do from, to = to, from
			upward := new(Series)
			upward^ = s^
			upward.lo, upward.hi, upward.term = from, to, s.index
			return series_law(k, upward)
		}
	}
	if same(k, s.term, s.index) && proven_in(k, s.lo, NONPOSITIVE) && proven_in(k, s.hi, COUNTS) do return Int(0)
	return s
}

// summed_fold: Σ(j: lo..hi, ⟳(…; x: 0 ↦ x + g; x)) = ⟳(…; x: 0 ↦ x + Σ(j: lo..hi, g); x),
// when nothing else in the fold reads j: a sum of sums is the sum of their terms.
summed_fold :: proc(k: ^Kernel, s: ^Series) -> (out: Type, ok: bool) {
	f := s.term.(^Fold) or_return
	if !is_none(f.effects) do return
	x := -1
	for z, i in f.states do if same(k, f.value, z) do x = i
	if x < 0 || !is_int(f.inits[x], 0) do return
	_, g, affine := affine_in(k, f.updates[x], f.states[x])
	if !affine || !same(k, f.updates[x], op(k, .Add, f.states[x], g)) do return
	for t, i in fold_parts(f) do if t != nil && i != 4 + len(f.states) + x && reads(k, t, s.index) do return
	inner := new(Series)
	inner^ = s^
	inner.term = g
	summed := new(Fold)
	summed^ = f^
	summed.updates = slice.clone(f.updates)
	summed.updates[x] = op(k, .Add, f.states[x], series_law(k, inner))
	return fold_law(k, summed), true
}

// bitwise_sum: Σ(i: lo..hi, v ⊕ i), ⊕ one of ^ [&] [|], v not reading i, 0 ≤ lo ≤ hi
// known: summed bit by bit. With w the bits of hi, m = 2ʷ - 1, v ⊕ i is
// (v - v [&] m) + (v [&] m ⊕ i) for ^ and [|], v [&] m [&] i for [&]. With N the
// count of i and C_b the count of those whose bit b is 1, bit b < w gives 2ᵇ times:
// C_b + v_b·(N - 2·C_b) for ^, v_b·C_b for [&], C_b + v_b·(N - C_b) for [|]; the
// bits of v with the same factor K are one mask: K·(v [&] mask) (§5.6).
bitwise_sum :: proc(k: ^Kernel, s: ^Series) -> (out: Type, ok: bool) {
	o := s.term.(^Operation) or_return
	if o.op != .Xor && o.op != .Bit_And && o.op != .Bit_Or || len(o.args) != 2 do return
	// v ⊕ (i + c): the sum over j = i + c, from lo + c to hi + c
	v: Type
	shift: i128 = 0
	for a, j in o.args {
		slope, c, affine := affine_in(k, a, s.index)
		at, constant := c.(Int)
		if affine && is_int(slope, 1) && constant do v, shift = o.args[1 - j], i128(at)
	}
	if v == nil || reads(k, v, s.index) do return
	lo := i128(s.lo.(Int) or_return) + shift
	hi := i128(s.hi.(Int) or_return) + shift
	if lo < 0 || hi < lo do return
	width := uint(0)
	for (i128(1) << width) <= hi do width += 1
	// ones(n, b): the integers of 0..n-1 whose bit b is 1
	ones :: proc(n: i128, b: uint) -> i128 {
		block := i128(1) << (b + 1)
		return (n / block) << b + max(n % block - i128(1) << b, 0)
	}
	n := hi - lo + 1
	constant: i128 = 0
	factors := make([]i128, width)
	for b in 0 ..< width {
		c := ones(hi + 1, b) - ones(lo, b)
		#partial switch o.op {
		case .Xor:
			constant += c << b
			factors[b] = n - 2 * c
		case .Bit_And:
			factors[b] = c
		case .Bit_Or:
			constant += c << b
			factors[b] = n - c
		}
	}
	out = Int(constant)
	// the bits above w: v's own, N times, for ^ and [|]
	if o.op != .Bit_And do out = op(k, .Add, out, op(k, .Mul, Int(n), op(k, .Sub, v, op(k, .Bit_And, v, Int((i128(1) << width) - 1)))))
	done := make([]bool, width)
	for b in 0 ..< width {
		if done[b] || factors[b] == 0 do continue
		mask: i128 = 0
		for x in b ..< width do if !done[x] && factors[x] == factors[b] {
			mask |= i128(1) << x
			done[x] = true
		}
		out = op(k, .Add, out, op(k, .Mul, Int(factors[b]), op(k, .Bit_And, v, Int(mask))))
	}
	return out, true
}

// carried_sum: Σ(i: lo..hi, t) as the fold ⟳(i: lo ↦ i + 1 until (hi + 1)..;
// x: 0 ↦ x + t; x), when t reads a run a fold builds along i: that fold carries it.
carried_sum :: proc(k: ^Kernel, s: ^Series) -> (Type, bool) {
	f := new(Fold)
	f.index, f.span = s.index, s.span
	f.start, f.next, f.stop = s.lo, op(k, .Add, s.index, Int(1)), new_range(op(k, .Add, s.hi, Int(1)), nil, .Int)
	x := new_unknown(k, nil)
	x.layout = family_term(.Int)
	f.states, f.inits, f.updates = slice.clone([]^Unknown{x}), slice.clone([]Type{Int(0)}), slice.clone([]Type{op(k, .Add, x, s.term)})
	f.value, f.effects = x, None{}
	if b, _ := run_reads(k, f); b == nil do return nil, false
	return folded(k, f), true
}

// faulhaber: Σ(i: lo..hi, t), t a polynomial in i over atoms that do not read i:
// G(hi) - G(lo - 1), each monomial c·q·iᵖ giving c·q·Sₚ, the sums of powers.
faulhaber :: proc(k: ^Kernel, s: ^Series) -> (sum: Type, ok: bool) {
	bounds: Rewrite
	t := atomized(k, s.term, &bounds)
	for a in bounds do if reads(k, a.term, s.index) do return
	lo, hi := atomized(k, s.lo, &bounds), atomized(k, s.hi, &bounds)
	ms, divisor := monomials(t) or_return
	degree := 0
	for m in ms {
		p := 0
		for u in factors(m) do if same_unknown(u, s.index) do p += 1
		degree = max(degree, p)
	}
	sums := power_sums(s.index, degree) or_return
	total: Type = Int(0)
	for m in ms {
		p := 0
		others := make([dynamic]^Unknown)
		for u in factors(m) {
			if same_unknown(u, s.index) do p += 1
			else do append(&others, u)
		}
		term := ring_law(.Mul, {monomial(coefficient(m), others[:]), sums[p]}) or_return
		total = ring_law(.Add, {total, term}) or_return
	}
	total = ring_over(total, divisor) or_return
	upper := ring_at(total, s.index, hi) or_return
	lower := ring_at(total, s.index, ring_law(.Sub, {lo, Int(1)}) or_return) or_return
	return rewrite(k, ring_law(.Sub, {upper, lower}) or_return, bounds), true
}

// counter_range: the steps of a fold whose index moves by one between lo and hi:
// up from lo, until it reaches hi + 1.., or down from hi, until ..lo - 1.
counter_range :: proc(k: ^Kernel, f: ^Fold) -> (lo, hi: Type, ok: bool) {
	r := f.stop.(^Range) or_return
	if same(k, f.next, op(k, .Add, f.index, Int(1))) && r.lo != nil && r.hi == nil {
		return f.start, op(k, .Sub, r.lo, Int(1)), true
	}
	if same(k, f.next, op(k, .Sub, f.index, Int(1))) && r.hi != nil && r.lo == nil {
		return op(k, .Add, r.hi, Int(1)), f.start, true
	}
	return
}

// ring_over: t / d, d ≥ 1, over the divisor of the sum.
ring_over :: proc(t: Type, d: i128) -> (out: Type, ok: bool) {
	ms, e := monomials(t) or_return
	ed := mul_checked(e, d) or_return
	return ring_term(ms, ed)
}

binomial :: proc(n, r: int) -> i128 {
	out: i128 = 1
	for i in 0 ..< r do out = out * i128(n - i) / i128(i + 1)
	return out
}

// power_sums: S_0 … S_d, S_p(m) = 0^p + 1^p + … + m^p, from
// C(p+1, 0) S_0 + … + C(p+1, p) S_p = (m + 1)^(p+1).
power_sums :: proc(u: ^Unknown, d: int) -> (out: []Type, ok: bool) {
	out = make([]Type, d + 1)
	next := ring_law(.Add, {u, Int(1)}) or_return
	for p in 0 ..= d {
		acc: Type = Int(1)
		for _ in 0 ..= p do acc = ring_law(.Mul, {acc, next}) or_return
		for j in 0 ..< p {
			term := ring_law(.Mul, {Int(binomial(p + 1, j)), out[j]}) or_return
			acc = ring_law(.Sub, {acc, term}) or_return
		}
		out[p] = ring_over(acc, i128(p + 1)) or_return
	}
	return out, true
}

// fixed: the state i stays at its init: its update reads it alone, and gives the
// init back from it (x ↦ x, x ↦ x % m from 1 …).
fixed :: proc(k: ^Kernel, f: ^Fold, i: int) -> bool {
	x, u := f.states[i], f.updates[i]
	if same(k, u, x) do return true
	if reads(k, u, f.index) || !is_constant(f.inits[i]) do return false
	for z, j in f.states do if j != i && reads(k, u, z) do return false
	return same(k, rewrite(k, u, rewriting(nil, x, f.inits[i])), f.inits[i])
}

// TUPLING (§5.6): calls of an equation f that differ by a field p only, over a
// range lo..hi, are the bindings of one call of T, whose value is the scope
// {f at p = lo  …  f at p = hi}: T is f, each product a scope of its products at
// each p, its calls of f T's, read at their p. One recursion for the range.

// fewer_than: s is the shape of the runs of fewer than c pieces, {...(A * (0..c - 1)):}.
fewer_than :: proc(s: Type, c: i128) -> bool {
	shape, is_scope := s.(^Scope)
	// fewer than one piece: {}
	if is_scope && len(shape.bindings) == 0 do return c == 1
	if !is_scope || len(shape.bindings) != 1 || !is_run(shape.bindings[0]) do return false
	o, repeats := shape.bindings[0].color.(^Operation)
	if !repeats || o.op != .Mul do return false
	r, is_range := o.args[1].(^Range)
	return is_range && is_int(r.lo, 0) && is_int(r.hi, c - 1)
}

// joined: the run of the runs first, the bindings of the run between, rewritten by
// r, then the runs last: {...a₀ … ...aₙ  x₀ … xₘ  ...b₀ … ...bₗ}. A run known to
// be a scope places its bindings (§5.3).
joined :: proc(k: ^Kernel, first: []Type, between: []^Binding = nil, r: Rewrite = nil, last: []Type = nil) -> Type {
	s := new_scope(nil, {})
	s.source, s.complete, s.reached = s, true, true
	place :: proc(k: ^Kernel, s: ^Scope, kind: Kind, t: Type) {
		if kind == .Expand {
			if known, is_scope := given(k, t).(^Scope); is_scope {
				for x in run_data(k, known) do place(k, s, x.kind, binding_value(k, x))
				return
			}
		}
		b := new_binding(s, kind, {})
		b.value = t
	}
	// a part with no type: the run has none (none of a law is computed on it)
	for t in first do if is_invalid(t) do return t
	for t in last do if is_invalid(t) do return t
	for t in first do place(k, s, .Expand, t)
	for x in between {
		t := rewrite(k, binding_value(k, x), r)
		if is_invalid(t) do return t
		place(k, s, x.kind, t)
	}
	for t in last do place(k, s, .Expand, t)
	// {...x} is the run x
	if len(s.bindings) == 1 && s.bindings[0].kind == .Expand do return s.bindings[0].value
	return normal(k, s)
}

// products: the products t may give: a pattern without effects, those of its
// branches, each read in its branch, where its reach holds — t & S there (§6) —;
// otherwise t. Each comes with the rewrite its reach makes: what is read inside it
// — the bindings of a scope it gives — is read under that rewrite too.
// orbit_length: the length n of the orbit of u by step until stop, in closed form:
// μ(i: kᵢ in stop), kᵢ = stepⁱ(u) (§5.6).
orbit_length :: proc(k: ^Kernel, u: ^Unknown, step, stop: Type, span: syn.Span) -> (n: Type, ok: bool) {
	x := orbit_index(k, u, stop)
	i := new_unknown(k, nil)
	i.layout = COUNTS
	ki := orbit(k, rewrite(k, step, rewriting(nil, u, x)), x, u, i) or_return
	j := new_unknown(k, nil)
	j.layout = COUNTS
	return least_law(k, j, in_law(k, rewrite(k, ki, rewriting(nil, i, j)), stop), span), true
}

// built: f builds a run, c bindings a step along a counter from 0: its value is
// the state y, {} at first, {...y  e₀ … e_{c-1}} at each step. The binding c·i + j
// of the run is eⱼ at step i.
built :: proc(k: ^Kernel, f: ^Fold) -> (y: int, es: []Type, ok: bool) {
	// a fold is never changed once built: what it builds, read once
	if known, found := k.built[f]; found do return known.y, known.es, known.ok
	y, es, ok = builds(k, f)
	k.built[f] = Built{y, es, ok}
	return
}

// Built: what a fold builds, once read (built).
Built :: struct {
	y:  int,
	es: []Type,
	ok: bool,
}

builds :: proc(k: ^Kernel, f: ^Fold) -> (y: int, es: []Type, ok: bool) {
	lo, _ := counter_range(k, f) or_return
	if !is_int(lo, 0) || !same(k, f.next, op(k, .Add, f.index, Int(1))) || !is_none(f.effects) do return
	for z, i in f.states {
		if !same(k, f.value, z) do continue
		start, is_scope := given(k, f.inits[i]).(^Scope)
		step, is_step := f.updates[i].(^Scope)
		if !is_scope || !is_step || len(run_data(k, start)) != 0 do return
		data := run_data(k, step)
		if len(data) < 2 || data[0].kind != .Expand || !same(k, binding_value(k, data[0]), z) do return
		out := make([]Type, len(data) - 1)
		for d, j in data[1:] {
			if d.kind == .Expand do return
			out[j] = binding_value(k, d)
			if reads(k, out[j], z) do return
		}
		for t, j in f.updates do if j != i && reads(k, t, z) do return
		return i, out, true
	}
	return
}

// carrying: f reads, at its step i counted from 0, the bindings c·i + j of a run a
// fold builds c a step: it carries the states of that fold beside its own, and the
// binding c·i + j is what that fold gives at step i. The run is never built.
carrying :: proc(k: ^Kernel, f: ^Fold) -> ^Fold {
	lo, _, counts := counter_range(k, f)
	if !counts || !is_int(lo, 0) || !same(k, f.next, op(k, .Add, f.index, Int(1))) do return f
	b, reads := run_reads(k, f)
	if b == nil do return f
	y, es, _ := built(k, b)
	along := rewriting(nil, b.index, f.index)
	states, inits := make([dynamic]^Unknown), make([dynamic]Type)
	append(&states, ..f.states)
	append(&inits, ..f.inits)
	for z, j in b.states {
		if j == y do continue
		w := new_unknown(k, nil)
		w.layout = layout_of(k, z)
		along = rewriting(along, z, w)
		append(&states, w)
		append(&inits, b.inits[j])
	}
	reading: Rewrite
	for r in reads do reading = append_read(reading, r.read, rewrite(k, es[r.at], along))
	parts := fold_parts(f)
	for &t in parts do t = rewrite(k, t, reading)
	out := with_parts(f, parts)
	updates := make([dynamic]Type)
	append(&updates, ..out.updates)
	for z, j in b.states do if j != y do append(&updates, rewrite(k, b.updates[j], along))
	out.states, out.inits, out.updates = states[:], inits[:], updates[:]
	return carrying(k, out)
}

Run_Read :: struct {
	read: ^Operation,
	at:   int, // j: the read is of the binding c·i + j
}

append_read :: proc(r: Rewrite, read: Type, t: Type) -> Rewrite {
	out := make([dynamic]Rewriting)
	append(&out, ..r)
	append(&out, Rewriting{read = read, term = t})
	return out[:]
}

// run_reads: a run a fold builds c a step that f reads at its index i, x.#(c·i + j)
// with j in 0..c - 1, and all those reads; nil when there is none, or when one
// reads it elsewhere.
run_reads :: proc(k: ^Kernel, f: ^Fold) -> (b: ^Fold, reads: []Run_Read) {
	found := make([dynamic]Run_Read)
	visit :: proc(k: ^Kernel, t: Type, i: ^Unknown, b: ^^Fold, found: ^[dynamic]Run_Read) {
		if t == nil do return
		if o, is_op := t.(^Operation); is_op && o.op == .Item {
			if x, is_fold := o.args[0].(^Fold); is_fold && (b^ == nil || same(k, b^, x)) {
				if _, es, builds := built(k, x); builds {
					c, j, along := affine_in(k, o.args[1], i)
					step, by := c.(Int)
					at, constant := j.(Int)
					if along && by && constant && int(step) == len(es) && at >= 0 && int(at) < len(es) {
						b^ = x
						append(found, Run_Read{o, int(at)})
						return
					}
				}
			}
		}
		for x in parts(t) do visit(k, x, i, b, found)
		if p, is_pattern := t.(^Pattern); is_pattern do for br in p.branches do visit(k, br.product, i, b, found)
	}
	for t in fold_parts(f) do visit(k, t, f.index, &b, &found)
	return b, found[:]
}

Product :: struct {
	term:    Type,
	rewrite: Rewrite,
}

products :: proc(k: ^Kernel, t: Type, out: ^[dynamic]Product, r: Rewrite = nil) {
	if p, is_pattern := t.(^Pattern); is_pattern && !has_effect(p) {
		reached, _, invalid := branch_reaches(k, p)
		if invalid != nil {
			append(out, Product{invalid, r})
			return
		}
		for x in reached {
			inner := make([dynamic]Rewriting)
			append(&inner, ..r)
			append(&inner, ..x.rewrite)
			products(k, branch_product(k, p.branches[x.branch], x.rewrite, p.target), out, inner[:])
		}
		return
	}
	append(out, Product{t, r})
}

// read_in: what a product holds, read under the rewrite of its branch.
read_in :: proc(k: ^Kernel, p: Product, t: Type) -> Type {
	if len(p.rewrite) == 0 do return t
	return rewrite(k, t, p.rewrite)
}
