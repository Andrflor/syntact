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
//   x * 2ᵏ = x << k
//   x / 2ᵏ = x >> k             x ≥ 0
//   x % 2ᵏ = x & (2ᵏ - 1)       x ≥ 0
//   x ** i * x ** j = x ** (i + j)                  x = x ** 1
//   x ** 2m = (x ** m)²         x ** (2m + 1) = x · (x ** m)²
//   a ⊕ b = b ⊕ a               ⊕ commutes: + * & | ^ = ≠, on integers and floats
//   a ◁ b = b ▷ a               ▷ the converse of ◁: < >, <= >=

Law :: proc(g: ^Graph, c: Class, n: Node)

LAWS := [?]Law{known, neutral, absorbing, strength, commuted, conversed, gathered, chained}

// saturate: the laws on every node, until none adds a node nor merges two classes,
// or the graph holds budget nodes.
saturate :: proc(g: ^Graph, budget: int) {
	for len(g.nodes) < budget {
		nodes, merges := len(g.nodes), g.merges
		index_members(g)
		for id in 0 ..< nodes {
			n := g.nodes[id]
			for law in LAWS do law(g, find(g, g.home[id]), n)
		}
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

binary :: proc(op: code.Op, a, b: Class) -> Node {
	args := make([]Class, 2)
	args[0], args[1] = a, b
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
	equal(g, c, int_node(v))
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
			equal(g, c, int_node(0))
		case -1:
			equal(g, c, Node{kind = .Unary, op = .Neg, args = one(x)})
		}
	case .And:
		if a == 0 do equal(g, c, int_node(0))
	case .Mod:
		if a == 1 || a == -1 do equal(g, c, int_node(0))
	case .Pow:
		if a != 0 do return
		if g.facts[x].machine == .Real do equal(g, c, Node{kind = .Real, value = transmute(i64)f64(1)})
		else do equal(g, c, int_node(1))
	}
}

// strength: an operation by a power of two, a shift or a mask.
strength :: proc(g: ^Graph, c: Class, n: Node) {
	x, d, ok := operands(g, n)
	if !ok || g.facts[x].machine != .Int do return
	k, power := log2(d)
	if !power do return
	nonnegative := g.facts[x].bounds.lo >= 0
	#partial switch n.op {
	case .Mul:
		equal(g, c, binary(.Shl, x, add(g, int_node(k))))
	case .Div:
		if nonnegative do equal(g, c, binary(.Shr, x, add(g, int_node(k))))
	case .Mod:
		if nonnegative do equal(g, c, binary(.And, x, add(g, int_node(d - 1))))
	}
}

// commuted: a ⊕ b = b ⊕ a.
commuted :: proc(g: ^Graph, c: Class, n: Node) {
	if n.kind != .Binary do return
	#partial switch n.op {
	case .Add, .Mul, .And, .Or, .Xor, .Eq, .Ne:
		equal(g, c, binary(n.op, n.args[1], n.args[0]))
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
	if n.kind != .Binary do return
	#partial switch n.op {
	case .Lt, .Le, .Gt, .Ge:
		equal(g, c, binary(CONVERSE[n.op], n.args[1], n.args[0]))
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
		if p.base == q.base do equal(g, c, binary(.Pow, p.base, add(g, int_node(p.count + q.count))))
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
		r = add(g, binary(.Mul, r, r))
		if e >> uint(bit) & 1 == 1 do r = add(g, binary(.Mul, r, x))
	}
	merge(g, c, r)
}

// log2: k when c = 2ᵏ, k ≥ 1.
log2 :: proc(c: i64) -> (k: i64, ok: bool) {
	if c < 2 || c & (c - 1) != 0 do return
	for x := c; x > 1; x >>= 1 do k += 1
	return k, true
}
