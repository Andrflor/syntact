package code_calc

import code ".."

// THE COST OF A COMPUTATION
//
// Cost is a homomorphism into the tropical semiring (ℝ ∪ ∞, min, +): a computation
// costs what its operation costs on the machine, plus what its arguments cost; a
// class costs its cheapest computation; a loop, what its parameters start from plus
// its turns times the cost of a turn; a match, its target plus its dearest arm. The
// normal form of a class is the computation it costs: the least, to a fixed point.

// Costs: what a machine takes, in cycles, for an operation on registers — on
// integers, on floats —, for a value it loads — a float, a text, an input, a
// constant where an operand cannot be one —, a call, a branch; and the turns of a
// loop.
Costs :: struct {
	ints:   [code.Op]f64,
	reals:  [code.Op]f64,
	load:   f64,
	call:   f64,
	branch: f64,
	turns:  f64,
}

X64 := Costs {
	ints = {
		.Add = 1,
		.Sub = 1,
		.Mul = 3,
		.Div = 26,
		.Mod = 26,
		.Pow = 0, // by its count
		.Neg = 1,
		.And = 1,
		.Or = 1,
		.Xor = 1,
		.Not = 1,
		.Shl = 1,
		.Shr = 1,
		.Eq = 1,
		.Ne = 1,
		.Lt = 1,
		.Le = 1,
		.Gt = 1,
		.Ge = 1,
	},
	reals = #partial {
		.Add = 4,
		.Sub = 4,
		.Mul = 4,
		.Div = 14,
		.Pow = 0, // by its count
		.Neg = 1,
		.Eq = 3,
		.Ne = 3,
		.Lt = 3,
		.Le = 3,
		.Gt = 3,
		.Ge = 3,
	},
	load   = 1,
	call   = 20,
	branch = 2,
	turns  = 16,
}

INFINITE :: f64(1e300)

// extract: the node of least cost of each class, by its index; -1 for a class
// nothing computes.
extract :: proc(g: ^Graph, costs: ^Costs) -> []int {
	scope := scopes(g)
	cost := make([]f64, len(g.parent))
	best := make([]int, len(g.parent))
	for &c in cost do c = INFINITE
	for &b in best do b = -1
	for changed := true; changed; {
		changed = false
		for n, id in g.nodes {
			c := find(g, g.home[id])
			r, defined := node_scope(g, n, scope)
			if s, has := scope[c].?; !defined || !has || r != s do continue
			total := node_cost(g, costs, n, cost)
			if total < cost[c] {
				cost[c] = total
				best[c] = id
				changed = true
			}
		}
	}
	return best
}

node_cost :: proc(g: ^Graph, costs: ^Costs, n: Node, cost: []f64) -> f64 {
	of :: proc(g: ^Graph, cost: []f64, c: Class) -> f64 {return cost[find(g, c)]}
	// what a computation reads, each class once: computed once, read twice
	sum :: proc(g: ^Graph, cost: []f64, cs: []Class) -> f64 {
		out: f64
		outer: for c, i in cs {
			for d in cs[:i] do if find(g, d) == find(g, c) do continue outer
			out += of(g, cost, c)
		}
		return min(out, INFINITE)
	}
	switch n.kind {
	case .Param:
		// a parameter a law carries: what a turn does to it
		op, carried := g.loops[n.owner].carried[n.index].?
		if !carried do return 0
		return (g.loops[n.owner].machines[n.index] == .Real ? costs.reals : costs.ints)[op]
	case .Int, .Argument, .Start, .Arm, .Get, .Narrow, .Again, .Exit:
		return sum(g, cost, n.args)
	case .Real, .Text, .Input:
		return costs.load
	case .Unary:
		a := g.facts[find(g, n.args[0])]
		return (a.machine == .Real ? costs.reals : costs.ints)[n.op] + sum(g, cost, n.args)
	case .Binary:
		a, b := g.facts[find(g, n.args[0])], g.facts[find(g, n.args[1])]
		ops := a.machine == .Real ? costs.reals : costs.ints
		w := ops[n.op]
		// a power by squaring: a square, a product and a branch for each bit of the count
		if n.op == .Pow do w = f64(bits(b.bounds.hi)) * (2 * ops[.Mul] + costs.branch)
		// a constant first takes a register
		if a.constant != nil do w += costs.load
		return w + sum(g, cost, n.args)
	case .In:
		return costs.branch * f64(len(g.covers[n.index].ints) + len(g.covers[n.index].reals)) + sum(g, cost, n.args)
	case .Foreign, .Call:
		return costs.call + sum(g, cost, n.args)
	case .Match:
		info := g.matches[n.owner]
		first := info.state ? 2 : 1
		per := (len(n.args) - first) / len(info.covers)
		dearest: f64
		for k in 0 ..< len(info.covers) do dearest = max(dearest, sum(g, cost, n.args[first + k * per:][:per]))
		return costs.branch * f64(len(info.covers) - 1) + sum(g, cost, n.args[:first]) + dearest
	case .Loop:
		last := len(n.args) - 1
		return sum(g, cost, n.args[:last]) + costs.turns * of(g, cost, n.args[last])
	}
	return INFINITE
}

// bits: the bits of a count up to hi.
bits :: proc(hi: i128) -> int {
	out := 0
	for x := min(hi, i128(max(i64))); x > 0; x >>= 1 do out += 1
	return out
}
