package code_calc

import code ".."

// THE LAWS OF A LOOP
//
// A parameter whose every Again adds the same δ to it is a counter: i, i + δ, … What
// a turn computes from a counter, the loop can carry from turn to turn instead — a
// parameter more, that changes none of the values the loop gives: its value at
// each turn is what it stands for, and the cost says which the code keeps.
//
//   p(i), a polynomial of degree d:  Newton's differences, Δp(i) = p(i + δ) - p(i)
//     T₀ = p(i), T₁ = Δp(i), … T_{d-1} = Δ^{d-1}p(i):  T_k ↦ T_k + T_{k+1}, T_{d-1} ↦ T_{d-1} + Δ^d p
//   b ** e(i), e affine, α its slope:  T ↦ T · b ** αδ    (T / b ** -αδ when αδ < 0)
//   m / b ** e(i), m read by no turn:  T ↦ T / b ** αδ,  αδ > 0
//
// each from its value where i starts. Where an arm narrowed the counter, the
// carried parameter is read through the same narrowing: what the arm proved holds
// there only. Only what leaves the ring is carried — a polynomial an operation of
// another kind reads, a power, a quotient —: what it is made of comes along.

// loop_laws: the laws of each loop, on the classes as the laws last saw them.
loop_laws :: proc(g: ^Graph) {
	consumed := make([]bool, len(g.parent))
	for n in g.nodes {
		if ring(n) do continue
		for a in n.args do consumed[find(g, a)] = true
	}
	for _, l in g.loops {
		steps := counters(g, l)
		if len(steps) == 0 do continue
		count := len(g.members)
		for c in 0 ..< count {
			c := Class(c)
			if find(g, c) != c || !within(g, c, l) || carried(g, c, l) do continue
			for i, delta in steps {
				if consumed[c] && carry_polynomial(g, c, l, i, delta) do break
				if carry_power(g, c, l, i, delta) do break
			}
		}
	}
}

// ring: an operation of the ring of integers, a polynomial of polynomials.
ring :: proc(n: Node) -> bool {
	if n.kind == .Unary do return n.op == .Neg
	if n.kind != .Binary do return false
	#partial switch n.op {
	case .Add, .Sub, .Mul, .Shl:
		return true
	}
	return false
}

// counters: the parameters of the loop l each Again adds the same constant to.
counters :: proc(g: ^Graph, l: int) -> map[int]i64 {
	out := make(map[int]i64)
	info := g.loops[l]
	agains := make([dynamic]Node)
	for n in g.nodes do if n.kind == .Again && n.owner == l do append(&agains, n)
	if len(agains) == 0 do return out
	params: for j in 0 ..< len(info.params) {
		if info.params[j].machine != .Int || info.params[j].lanes > 0 || info.carried[j] != nil do continue
		delta: Maybe(i64)
		for a in agains {
			d, ok := step(g, a.args[j], l, j)
			if !ok do continue params
			if x, has := delta.?; has && x != d do continue params
			delta = d
		}
		if d, has := delta.?; has && d != 0 do out[j] = d
	}
	return out
}

// step: δ when the class c is the parameter j of l plus δ.
step :: proc(g: ^Graph, c: Class, l, j: int) -> (i64, bool) {
	for id in g.members[find(g, c)] {
		n := g.nodes[id]
		if n.kind != .Binary || n.op != .Add && n.op != .Sub do continue
		d, known := g.facts[find(g, n.args[1])].constant.?
		if !known do continue
		if _, is := counter_of(g, n.args[0], l, j); is do return n.op == .Add ? d : -d, true
	}
	return 0, false
}

// counter_of: the class c is the parameter j of l — read through the narrowing of an
// arm, its token —.
counter_of :: proc(g: ^Graph, c: Class, l, j: int) -> (token: Class, ok: bool) {
	for id in g.members[find(g, c)] {
		n := g.nodes[id]
		if n.kind == .Param && n.owner == l && n.index == j do return NO_CLASS, true
		if n.kind == .Narrow {
			if _, is := counter_of(g, n.args[0], l, j); is do return find(g, n.args[1]), true
		}
	}
	return NO_CLASS, false
}

// within: the class c reads a parameter of the loop l: it is computed in its body.
within :: proc(g: ^Graph, c: Class, l: int) -> bool {
	if find(g, c) >= Class(len(g.scope)) do return false
	r, defined := g.scope[find(g, c)].?
	return defined && inside(g, r, Region{.Body, l, 0})
}

// invariant: no turn of l changes c.
invariant :: proc(g: ^Graph, c: Class, l: int) -> bool {
	if find(g, c) >= Class(len(g.scope)) do return false
	_, defined := g.scope[find(g, c)].?
	return defined && !within(g, c, l)
}

// carried: c is a parameter l carries, or one read through a narrowing.
carried :: proc(g: ^Graph, c: Class, l: int) -> bool {
	for id in g.members[find(g, c)] {
		n := g.nodes[id]
		if n.kind == .Param && n.owner == l && g.loops[l].carried[n.index] != nil do return true
		if n.kind == .Narrow && carried(g, n.args[0], l) do return true
	}
	return false
}

// Polynomial: the coefficients of a polynomial in a counter, each read by no turn,
// from the constant term up; and the narrowing it reads the counter through.
Polynomial :: struct {
	coefficients: []Class,
	token:        Class,
}

// polynomial: c as a polynomial in the counter i of l.
polynomial :: proc(g: ^Graph, c: Class, l, i: int, depth := 0) -> (p: Polynomial, ok: bool) {
	c := find(g, c)
	if g.facts[c].machine != .Int || depth > 12 do return
	if invariant(g, c, l) do return Polynomial{one(c), NO_CLASS}, true
	if token, is := counter_of(g, c, l, i); is {
		coefficients := make([]Class, 2)
		coefficients[0], coefficients[1] = add(g, int_node(0)), add(g, int_node(1))
		return Polynomial{coefficients, token}, true
	}
	for id in g.members[c] {
		n := g.nodes[id]
		if n.kind == .Splat {
			// in each lane: δ is a homomorphism of rings
			a := polynomial(g, n.args[0], l, i, depth + 1) or_continue
			lanes := make([]Class, len(a.coefficients))
			for x, k in a.coefficients do lanes[k] = splat(g, x, int(n.value))
			return Polynomial{lanes, a.token}, true
		}
		if !ring(n) do continue
		a := polynomial(g, n.args[0], l, i, depth + 1) or_continue
		if n.kind == .Unary {
			return scaled(g, a, -1), true
		}
		if n.op == .Shl {
			k, known := g.facts[find(g, n.args[1])].constant.?
			if !known || k < 0 || k > 62 do continue
			return scaled(g, a, i64(1) << uint(k)), true
		}
		b := polynomial(g, n.args[1], l, i, depth + 1) or_continue
		token := a.token
		if b.token != NO_CLASS {
			if token != NO_CLASS && token != b.token do continue
			token = b.token
		}
		#partial switch n.op {
		case .Add:
			return Polynomial{summed(g, a.coefficients, b.coefficients, 1), token}, true
		case .Sub:
			return Polynomial{summed(g, a.coefficients, b.coefficients, -1), token}, true
		case .Mul:
			return Polynomial{multiplied(g, a.coefficients, b.coefficients), token}, true
		}
	}
	return
}

// plus, times: a + b and a · b, a constant folded.
plus :: proc(g: ^Graph, a, b: Class) -> Class {
	x, known_a := g.facts[find(g, a)].constant.?
	y, known_b := g.facts[find(g, b)].constant.?
	switch {
	case known_a && x == 0:
		return find(g, b)
	case known_b && y == 0:
		return find(g, a)
	case known_a && known_b && g.facts[find(g, a)].lanes == g.facts[find(g, b)].lanes:
		return add(g, int_node(x + y)) if g.facts[find(g, a)].lanes == 0 else add(g, constant_like(g, a, x + y))
	}
	v := vector_first(g, a, b)
	return add(g, binary(.Add, v[0], v[1]))
}

times :: proc(g: ^Graph, a, b: Class) -> Class {
	x, known_a := g.facts[find(g, a)].constant.?
	y, known_b := g.facts[find(g, b)].constant.?
	switch {
	case known_a && x == 0 || known_b && y == 0:
		return add(g, int_node(0))
	case known_a && x == 1:
		return find(g, b)
	case known_b && y == 1:
		return find(g, a)
	case known_a && known_b && g.facts[find(g, a)].lanes == g.facts[find(g, b)].lanes:
		return add(g, int_node(x * y)) if g.facts[find(g, a)].lanes == 0 else add(g, constant_like(g, a, x * y))
	case known_a && g.facts[find(g, a)].lanes <= g.facts[find(g, b)].lanes:
		return add(g, binary(.Mul, b, a))
	}
	v := vector_first(g, a, b)
	return add(g, binary(.Mul, v[0], v[1]))
}

// vector_first: a and b, a vector first.
vector_first :: proc(g: ^Graph, a, b: Class) -> [2]Class {
	if g.facts[find(g, a)].lanes < g.facts[find(g, b)].lanes do return {b, a}
	return {a, b}
}

scaled :: proc(g: ^Graph, p: Polynomial, s: i64) -> Polynomial {
	out := make([]Class, len(p.coefficients))
	for c, k in p.coefficients do out[k] = times(g, c, add(g, int_node(s)))
	return Polynomial{out, p.token}
}

summed :: proc(g: ^Graph, a, b: []Class, sign: i64) -> []Class {
	out := make([]Class, max(len(a), len(b)))
	for &c, k in out {
		x := k < len(a) ? a[k] : add(g, int_node(0))
		y := k < len(b) ? times(g, b[k], add(g, int_node(sign))) : add(g, int_node(0))
		c = plus(g, x, y)
	}
	return trimmed(g, out)
}

multiplied :: proc(g: ^Graph, a, b: []Class) -> []Class {
	out := make([]Class, len(a) + len(b) - 1)
	for &c in out do c = add(g, int_node(0))
	for x, j in a do for y, k in b do out[j + k] = plus(g, out[j + k], times(g, x, y))
	return trimmed(g, out)
}

// trimmed: the coefficients, without the zeros above the degree.
trimmed :: proc(g: ^Graph, cs: []Class) -> []Class {
	n := len(cs)
	for n > 1 {
		v, known := g.facts[find(g, cs[n - 1])].constant.?
		if !known || v != 0 do break
		n -= 1
	}
	return cs[:n]
}

// difference: the coefficients of Δp, p(i + δ) - p(i): the k-th, Σ over m > k of
// the m-th times C(m, k) δ^(m-k).
difference :: proc(g: ^Graph, p: []Class, delta: i64) -> []Class {
	if len(p) <= 1 do return one(add(g, int_node(0)))
	out := make([]Class, len(p) - 1)
	for &c, k in out {
		c = add(g, int_node(0))
		for m in k + 1 ..< len(p) {
			factor := binomial(m, k)
			for _ in 0 ..< m - k do factor *= delta
			c = plus(g, c, times(g, p[m], add(g, int_node(factor))))
		}
	}
	return out
}

binomial :: proc(n, k: int) -> i64 {
	out: i64 = 1
	for j in 0 ..< k do out = out * i64(n - j) / i64(j + 1)
	return out
}

// at: the polynomial at x, by Horner.
at :: proc(g: ^Graph, p: []Class, x: Class) -> Class {
	out := p[len(p) - 1]
	#reverse for c in p[:len(p) - 1] do out = plus(g, times(g, out, x), c)
	return out
}

// carry_polynomial: c, a polynomial of degree d in the counter i, carried with its
// differences.
carry_polynomial :: proc(g: ^Graph, c: Class, l, i: int, delta: i64) -> bool {
	p := polynomial(g, c, l, i) or_return
	d := len(p.coefficients) - 1
	if d < 1 do return false
	// a polynomial of degree 1 whose slope is ±1 costs an addition: as much as it would
	if d == 1 {
		if slope, known := g.facts[find(g, p.coefficients[1])].constant.?; known && (slope == 1 || slope == -1) do return false
	}
	start := g.nodes[g.loops[l].node].args[i]
	differences := make([][]Class, d + 1)
	differences[0] = p.coefficients
	for k in 1 ..= d do differences[k] = difference(g, differences[k - 1], delta)
	params := make([]Class, d)
	for k in 0 ..< d do params[k] = extend(g, l, at(g, differences[k], start), .Add)
	nexts := make([]Class, d)
	for k in 0 ..< d {
		next := k + 1 < d ? params[k + 1] : differences[d][0]
		nexts[k] = add(g, binary(.Add, params[k], next))
	}
	advance(g, l, nexts)
	merge(g, c, read_as(g, params[0], p.token))
	return true
}

// carry_power: c, b ** e(i) with e affine in the counter i — or m / b ** e(i) —,
// carried by its factor at each turn.
carry_power :: proc(g: ^Graph, c: Class, l, i: int, delta: i64) -> bool {
	for id in g.members[find(g, c)] {
		n := g.nodes[id]
		if n.kind != .Binary do continue
		#partial switch n.op {
		case .Pow:
			factor, slope, token := power_step(g, n, l, i, delta) or_continue
			start := g.nodes[g.loops[l].node].args[i]
			e := polynomial(g, n.args[1], l, i) or_continue
			first := add(g, binary(.Pow, n.args[0], at(g, e.coefficients, start)))
			// going down, a quotient: exact while the count is not below the step
			b := g.facts[find(g, n.args[0])]
			if slope < 0 && (b.machine != .Int || b.bounds.lo <= 0 && b.bounds.hi >= 0) do continue
			op: code.Op = slope > 0 ? .Mul : .Div
			t := extend(g, l, first, op)
			advance(g, l, one(add(g, binary(op, t, factor))))
			merge(g, c, read_as(g, t, token))
			return true
		case .Div:
			if g.facts[find(g, c)].machine != .Int || !invariant(g, n.args[0], l) do continue
			for pid in g.members[find(g, n.args[1])] {
				q := g.nodes[pid]
				if q.kind != .Binary || q.op != .Pow do continue
				factor, slope, token := power_step(g, q, l, i, delta) or_continue
				if slope <= 0 || g.facts[find(g, q.args[0])].bounds.lo < 1 do continue
				start := g.nodes[g.loops[l].node].args[i]
				e := polynomial(g, q.args[1], l, i) or_continue
				first := add(g, binary(.Div, n.args[0], add(g, binary(.Pow, q.args[0], at(g, e.coefficients, start)))))
				t := extend(g, l, first, .Div)
				advance(g, l, one(add(g, binary(.Div, t, factor))))
				merge(g, c, read_as(g, t, token))
				return true
			}
		}
	}
	return false
}

// power_step: for b ** e(i), e affine in i of a constant slope α, b read by no
// turn: b ** |αδ|, the factor of a turn, and the sign of αδ.
power_step :: proc(g: ^Graph, n: Node, l, i: int, delta: i64) -> (factor: Class, slope: i64, token: Class, ok: bool) {
	if !invariant(g, n.args[0], l) do return
	e := polynomial(g, n.args[1], l, i) or_return
	if len(e.coefficients) != 2 do return
	alpha := g.facts[find(g, e.coefficients[1])].constant.? or_return
	slope = alpha * delta
	if slope == 0 do return
	factor = slope == 1 || slope == -1 ? find(g, n.args[0]) : add(g, binary(.Pow, n.args[0], add(g, int_node(abs(slope)))))
	return factor, slope, e.token, true
}

// read_as: the parameter t, read through the narrowing token, when there is one.
read_as :: proc(g: ^Graph, t: Class, token: Class) -> Class {
	if token == NO_CLASS do return t
	args := make([]Class, 2)
	args[0], args[1] = t, token
	return add(g, Node{kind = .Narrow, args = args})
}

// extend: a parameter more for the loop l, from start, carried by op; it takes
// what advance gives it next.
extend :: proc(g: ^Graph, l: int, start: Class, op: code.Op) -> Class {
	info := &g.loops[l]
	j := len(info.params)
	f := g.facts[find(g, start)]
	append(&info.params, code.Kind{f.machine, code.EVERY, f.lanes})
	append(&info.carried, op)
	loop := &g.nodes[info.node]
	args := make([]Class, len(loop.args) + 1)
	copy(args, loop.args[:j])
	args[j] = find(g, start)
	args[j + 1] = loop.args[j]
	loop.args = args
	return add(g, Node{kind = .Param, owner = l, index = j})
}

// advance: what each Again of l gives the parameters extend last added, in order.
advance :: proc(g: ^Graph, l: int, nexts: []Class) {
	for &n in g.nodes {
		if n.kind != .Again || n.owner != l do continue
		args := make([]Class, len(n.args) + len(nexts))
		copy(args, n.args)
		copy(args[len(n.args):], nexts)
		n.args = args
	}
}
