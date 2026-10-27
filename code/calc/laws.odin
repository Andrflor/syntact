package code_calc

import code ".."

// THE LAWS
//
// Each law is an equation between computations, under the facts of their classes.
// It adds the computation on its other side to the class of the one it sees, and
// takes none away: which one the code keeps is the cost's to say (extract.odin).
//
//   x = c                       the facts of x give the one integer c
//   x + 0 = x - 0 = x | 0 = x ^ 0 = x << 0 = x >> 0 = x * 1 = x / 1 = x ** 1 = x
//   x * 0 = x & 0 = x % 1 = 0        x ** 0 = 1        x * -1 = -x
//   x * 2ᵏ = x << k             x * (2ᵏ ± 1) = (x << k) ± x
//   x / 2ᵏ = x >> k             x ≥ 0
//   x % 2ᵏ = x & (2ᵏ - 1)       x ≥ 0
//   x / c = (x · m) >> s, …     0 ≤ x ≤ X: Granlund, Montgomery (divided)
//   x % c = x - c · (x / c)
//   x ** i * x ** j = x ** (i + j)                  x = x ** 1
//   x ** 2m = (x ** m)²         x ** (2m + 1) = x · (x ** m)²
//   a ⊕ b = b ⊕ a               ⊕ commutes: + * & | ^ = ≠, on integers and floats
//   a ◁ b = b ▷ a               ▷ the converse of ◁: < >, <= >=
//   x + c ◁ k = x ◁ k - c       ◁ a comparison, x + c not wrapping
//   t ? {c -> a  -> b} = (t in c) ? a : b       selects (selects.odin)

Law :: proc(g: ^Graph, c: Class, n: Node)

LAWS := [?]Law{known, neutral, absorbing, strength, divided, commuted, conversed, shifted, gathered, chained, selected, cells}

// saturate: the laws on every node and those of the loops (loops.odin), until none
// adds a node nor merges two classes, or the graph holds budget nodes; then the law
// of lanes (lanes.odin), on the loops as the laws left them, and the laws again,
// on what it made.
saturate :: proc(g: ^Graph, budget: int) {
	saturated(g, budget)
	index_members(g)
	g.scope = scopes(g)
	laned(g)
	rebuild(g)
	saturated(g, budget)
}

saturated :: proc(g: ^Graph, budget: int) {
	for len(g.nodes) < budget {
		nodes, merges := len(g.nodes), g.merges
		index_members(g)
		g.scope = scopes(g)
		for id in 0 ..< nodes {
			n := g.nodes[id]
			for law in LAWS do law(g, find(g, g.home[id]), n)
		}
		loop_laws(g)
		rebuild(g)
		if len(g.nodes) == nodes && g.merges == merges do return
	}
}

// equal: the class c holds n too.
equal :: proc(g: ^Graph, c: Class, n: Node) {
	merge(g, c, add(g, n))
}

// operands: x and the constant c of x op c, on integers — or, for a power, on any
// base.
operands :: proc(g: ^Graph, n: Node) -> (x: Class, c: i64, ok: bool) {
	if n.kind != .Binary do return
	x = find(g, n.args[0])
	c = g.facts[find(g, n.args[1])].constant.? or_return
	return x, c, n.op == .Pow || g.facts[x].machine == .Int
}

int_node :: proc(v: i64) -> Node {
	return Node{kind = .Int, value = v}
}

// binary: a op b; on a vector, what is in each lane of it a vector too — but the
// count of a shift.
binary :: proc(g: ^Graph, op: code.Op, a, b: Class) -> Node {
	args := make([]Class, 2)
	args[0], args[1] = a, b
	lanes := g.facts[find(g, a)].lanes
	if lanes > 0 && g.facts[find(g, b)].lanes == 0 && op != .Shl && op != .Shr do args[1] = splat(g, b, lanes)
	return Node{kind = .Binary, op = op, args = args}
}

// known: a class whose facts give one integer is that integer.
known :: proc(g: ^Graph, c: Class, n: Node) {
	f := g.facts[find(g, c)]
	if f.machine != .Int || n.kind == .Int do return
	v, constant := f.constant.?
	if !constant {
		if f.bounds.lo != f.bounds.hi || !in_64(f.bounds) do return
		v = i64(f.bounds.lo)
	}
	equal(g, c, constant_like(g, c, v))
}

// constant_like: the integer v, in each lane when c is a vector.
constant_like :: proc(g: ^Graph, c: Class, v: i64) -> Node {
	lanes := g.facts[find(g, c)].lanes
	if lanes == 0 do return int_node(v)
	return Node{kind = .Splat, value = i64(lanes), args = one(add(g, int_node(v)))}
}

// neutral: x op e = x, e the neutral of op on its right.
neutral :: proc(g: ^Graph, c: Class, n: Node) {
	x, e, ok := operands(g, n)
	if !ok do return
	#partial switch n.op {
	case .Add, .Sub, .Or, .Xor, .Shl, .Shr:
		if e == 0 do merge(g, c, x)
	case .Mul, .Div, .Pow:
		if e == 1 do merge(g, c, x)
	}
}

// absorbing: x op a is a constant, or the negation of x.
absorbing :: proc(g: ^Graph, c: Class, n: Node) {
	x, a, ok := operands(g, n)
	if !ok do return
	#partial switch n.op {
	case .Mul:
		switch a {
		case 0:
			equal(g, c, constant_like(g, c, 0))
		case -1:
			equal(g, c, Node{kind = .Unary, op = .Neg, args = one(x)})
		}
	case .And:
		if a == 0 do equal(g, c, constant_like(g, c, 0))
	case .Mod:
		if a == 1 || a == -1 do equal(g, c, constant_like(g, c, 0))
	case .Pow:
		if a != 0 do return
		if g.facts[x].machine != .Real do equal(g, c, constant_like(g, c, 1))
		else if g.facts[x].lanes == 0 do equal(g, c, Node{kind = .Real, value = transmute(i64)f64(1)})
	}
}

// strength: an operation by a power of two, a shift or a mask; a product by one
// next to it, a shift and a sum.
strength :: proc(g: ^Graph, c: Class, n: Node) {
	x, d, ok := operands(g, n)
	if !ok || g.facts[x].machine != .Int do return
	if n.op == .Mul && d > 2 {
		for sign in ([]i64{1, -1}) {
			if k, near := log2(d - sign); near do equal(g, c, binary(g, sign > 0 ? .Add : .Sub, add(g, binary(g, .Shl, x, add(g, int_node(k)))), x))
		}
	}
	k, power := log2(d)
	if !power do return
	nonnegative := g.facts[x].bounds.lo >= 0
	#partial switch n.op {
	case .Mul:
		equal(g, c, binary(g, .Shl, x, add(g, int_node(k))))
	case .Div:
		if nonnegative do equal(g, c, binary(g, .Shr, x, add(g, int_node(k))))
	case .Mod:
		if nonnegative do equal(g, c, binary(g, .And, x, add(g, int_node(d - 1))))
	}
}

// divided: a quotient by a constant c, 2 < c not a power of 2, x in 0..X, as
// products and shifts, exact over those bounds (Granlund, Montgomery 1994): each
// that holds, the cost choosing —
//
//   (x · m) >> s                    m = ⌈2ˢ / c⌉, X · (m·c - 2ˢ) < 2ˢ, X · m < 2⁶³
//   (t + ((x - t) >> 1)) >> (l - 1)  t = (x · m') >> N, X < 2ᴺ, l = ⌈log₂ c⌉,
//                                    m' = ⌊2ᴺ (2ˡ - c) / c⌋ + 1, X · m' < 2⁶³
//   mulhi(x, m) >> (s - 64)          m = ⌈2ˢ / c⌉ < 2⁶⁴, X · (m·c - 2ˢ) < 2ˢ
//
// — and a remainder, x - c · (x / c).
divided :: proc(g: ^Graph, c: Class, n: Node) {
	x, d, ok := operands(g, n)
	if !ok || n.op != .Div && n.op != .Mod || d < 3 || g.facts[x].machine != .Int do return
	if _, power := log2(d); power do return
	b := g.facts[x].bounds
	if b.lo < 0 || !in_64(b) do return
	top, divisor := b.hi, i128(d)
	constant :: proc(g: ^Graph, v: i128) -> Class {return add(g, int_node(i64(v)))}
	quotients := make([dynamic]Class)
	// a product and a shift
	for s in uint(1) ..< 63 {
		m := (i128(1) << s + divisor - 1) / divisor
		if top * (m * divisor - i128(1) << s) >= i128(1) << s do continue
		if top * m < i128(1) << 63 do append(&quotients, add(g, binary(g, .Shr, add(g, binary(g, .Mul, x, constant(g, m))), constant(g, i128(s)))))
		break
	}
	// a product, its high half in N bits, and an addition
	l := uint(0)
	for i128(1) << l < divisor do l += 1
	for bits in uint(1) ..= 32 {
		if top >= i128(1) << bits do continue
		m := (i128(1) << bits) * (i128(1) << l - divisor) / divisor + 1
		if top * m >= i128(1) << 63 do break
		t := add(g, binary(g, .Shr, add(g, binary(g, .Mul, x, constant(g, m))), constant(g, i128(bits))))
		// t ≤ x: what the theorem proves, the laws hold
		rest := add(g, binary(g, .Sub, x, t))
		sum := add(g, binary(g, .Add, t, add(g, binary(g, .Shr, rest, constant(g, 1)))))
		for c in ([]Class{t, rest, sum}) do g.facts[find(g, c)].bounds = code.meet(g.facts[find(g, c)].bounds, {0, top})
		append(&quotients, add(g, binary(g, .Shr, sum, constant(g, i128(l - 1)))))
		break
	}
	// the high half of a product of 128 bits
	if g.facts[x].lanes == 0 {
		for s in uint(64) ..< 128 {
			m := (i128(1) << s + divisor - 1) / divisor
			if m >= i128(1) << 64 do break
			if top * (m * divisor - i128(1) << s) >= i128(1) << s do continue
			high := add(g, binary(g, .Mul_High, x, add(g, int_node(transmute(i64)u64(m)))))
			append(&quotients, s == 64 ? high : add(g, binary(g, .Shr, high, constant(g, i128(s - 64)))))
			break
		}
	}
	for q in quotients {
		if n.op == .Div do merge(g, c, q)
		else do equal(g, c, binary(g, .Sub, x, add(g, binary(g, .Mul, q, add(g, int_node(d))))))
	}
}

// commuted: a ⊕ b = b ⊕ a — a vector first, before what is in each of its lanes.
commuted :: proc(g: ^Graph, c: Class, n: Node) {
	if n.kind != .Binary || !same_lanes(g, n) do return
	#partial switch n.op {
	case .Add, .Mul, .And, .Or, .Xor, .Eq, .Ne:
		equal(g, c, binary(g, n.op, n.args[1], n.args[0]))
	}
}

CONVERSE := #partial [code.Op]code.Op {
	.Lt = .Gt,
	.Le = .Ge,
	.Gt = .Lt,
	.Ge = .Le,
}

// conversed: a ◁ b = b ▷ a.
conversed :: proc(g: ^Graph, c: Class, n: Node) {
	if n.kind != .Binary || !same_lanes(g, n) do return
	#partial switch n.op {
	case .Lt, .Le, .Gt, .Ge:
		equal(g, c, binary(g, CONVERSE[n.op], n.args[1], n.args[0]))
	}
}

// shifted: x + c ◁ k = x ◁ k - c, where x + c and k - c do not wrap.
shifted :: proc(g: ^Graph, c: Class, n: Node) {
	if n.kind != .Binary || !comparison(n.op) || !same_lanes(g, n) do return
	k, known := g.facts[find(g, n.args[1])].constant.?
	if !known do return
	sum := find(g, n.args[0])
	if !in_64(g.facts[sum].bounds) || g.facts[sum].machine != .Int do return
	for id in g.members[sum] {
		s := g.nodes[id]
		if s.kind != .Binary || s.op != .Add && s.op != .Sub do continue
		d, constant := g.facts[find(g, s.args[1])].constant.?
		if !constant do continue
		moved := s.op == .Add ? i128(k) - i128(d) : i128(k) + i128(d)
		if moved < i128(min(i64)) || moved > i128(max(i64)) do continue
		lanes := g.facts[find(g, n.args[1])].lanes
		bound := lanes > 0 ? splat(g, add(g, int_node(i64(moved))), lanes) : add(g, int_node(i64(moved)))
		equal(g, c, binary(g, n.op, s.args[0], bound))
		return
	}
}

// Power: base ** count, a count known.
Power :: struct {
	base:  Class,
	count: i64,
}

// powers: the powers the class c holds: c ** 1, and each power of a count known.
powers :: proc(g: ^Graph, c: Class) -> []Power {
	c := find(g, c)
	out := make([dynamic]Power)
	append(&out, Power{c, 1})
	for id in g.members[c] {
		n := g.nodes[id]
		if n.kind != .Binary || n.op != .Pow do continue
		if k, known := g.facts[find(g, n.args[1])].constant.?; known && k >= 1 do append(&out, Power{find(g, n.args[0]), k})
	}
	return out[:]
}

// gathered: x ** i * x ** j = x ** (i + j).
gathered :: proc(g: ^Graph, c: Class, n: Node) {
	if n.kind != .Binary || n.op != .Mul do return
	for p in powers(g, n.args[0]) do for q in powers(g, n.args[1]) {
		if p.base == q.base do equal(g, c, binary(g, .Pow, p.base, add(g, int_node(p.count + q.count))))
	}
}

// chained: x ** n, n ≥ 2 known, as the squares of x by the bits of n from the
// highest, times x at each bit set.
chained :: proc(g: ^Graph, c: Class, n: Node) {
	x, e, ok := operands(g, n)
	if !ok || n.op != .Pow || e < 2 do return
	top := 0
	for b := e; b > 1; b >>= 1 do top += 1
	r := x
	for bit := top - 1; bit >= 0; bit -= 1 {
		r = add(g, binary(g, .Mul, r, r))
		if e >> uint(bit) & 1 == 1 do r = add(g, binary(g, .Mul, r, x))
	}
	merge(g, c, r)
}

// same_lanes: the arguments of a binary node are both vectors, or both not.
same_lanes :: proc(g: ^Graph, n: Node) -> bool {
	return g.facts[find(g, n.args[0])].lanes == g.facts[find(g, n.args[1])].lanes
}

// log2: k when c = 2ᵏ, k ≥ 1.
log2 :: proc(c: i64) -> (k: i64, ok: bool) {
	if c < 2 || c & (c - 1) != 0 do return
	for x := c; x > 1; x >>= 1 do k += 1
	return k, true
}
