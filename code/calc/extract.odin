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
// constant where an operand cannot be one —, a call, a branch; the turns of a
// loop; and its vectors: their lanes — none when it has no vector —, an operation
// on each lane — INFINITE where it has none —, a value in each lane, a reduction.
Costs :: struct {
	ints:   [code.Op]f64,
	reals:  [code.Op]f64,
	load:   f64,
	call:   f64,
	branch: f64,
	turns:  f64,
	lanes:  int,
	vints:  [code.Op]f64,
	vreals: [code.Op]f64,
	splat:  f64,
	reduce: f64,
}

INFINITE :: f64(1e300)

X64_INTS :: [code.Op]f64 {
	.Add = 1,
	.Sub = 1,
	.Mul = 3,
	.Div = 26,
	.Mod = 26,
	.Pow = 0, // by its count
	.Mul_High = 4,
	.Neg = 1,
	.And = 1,
	.Or  = 1,
	.Xor = 1,
	.Not = 1,
	.Shl = 1,
	.Shr = 1,
	.Eq  = 1,
	.Ne  = 1,
	.Lt  = 1,
	.Le  = 1,
	.Gt  = 1,
	.Ge  = 1,
}

X64_REALS :: [code.Op]f64 {
	.Add = 4,
	.Sub = 4,
	.Mul = 4,
	.Div = 14,
	.Mod = INFINITE,
	.Pow = 0, // by its count
	.Mul_High = INFINITE,
	.Neg = 1,
	.And = INFINITE,
	.Or  = INFINITE,
	.Xor = INFINITE,
	.Not = INFINITE,
	.Shl = INFINITE,
	.Shr = INFINITE,
	.Eq  = 3,
	.Ne  = 3,
	.Lt  = 3,
	.Le  = 3,
	.Gt  = 3,
	.Ge  = 3,
}

// SSE2: two lanes of 64 bits; a product of integers in 32 bits is one pmuludq.
SSE2_INTS :: [code.Op]f64 {
	.Add = 1,
	.Sub = 1,
	.Mul = 6, // 1 on lanes in 32 bits
	.Div = INFINITE,
	.Mod = INFINITE,
	.Pow = INFINITE,
	.Mul_High = INFINITE,
	.Neg = 1,
	.And = 1,
	.Or  = 1,
	.Xor = 1,
	.Not = 1,
	.Shl = 1,
	.Shr = 3, // 1 on lanes not negative
	.Eq  = 2,
	.Ne  = 3,
	.Lt  = 3,
	.Le  = 4,
	.Gt  = 3,
	.Ge  = 4,
}

SSE2_REALS :: [code.Op]f64 {
	.Add = 4,
	.Sub = 4,
	.Mul = 4,
	.Div = 14,
	.Mod = INFINITE,
	.Pow = INFINITE,
	.Mul_High = INFINITE,
	.Neg = 1,
	.And = INFINITE,
	.Or  = INFINITE,
	.Xor = INFINITE,
	.Not = INFINITE,
	.Shl = INFINITE,
	.Shr = INFINITE,
	.Eq  = 3,
	.Ne  = 3,
	.Lt  = 3,
	.Le  = 3,
	.Gt  = 3,
	.Ge  = 3,
}

// X64_LANES: the operations on lanes the x86-64 backend writes: equality, but no
// order, no division, a shift of each lane by the same count.
X64_LANES :: [code.Op]f64 {
	.Eq = 4,
	.Ne = 5,
	.Add = 1,
	.Sub = 1,
	.Mul = 8, // 1 on lanes in 32 bits
	.Div = INFINITE,
	.Mod = INFINITE,
	.Pow = INFINITE,
	.Mul_High = INFINITE,
	.Neg = 2,
	.And = 1,
	.Or  = 1,
	.Xor = 1,
	.Not = 2,
	.Shl = 1,
	.Shr = 5, // 1 on lanes not negative
	.Lt  = INFINITE,
	.Le  = INFINITE,
	.Gt  = INFINITE,
	.Ge  = INFINITE,
}

X64_REAL_LANES :: [code.Op]f64 {
	.Add = 4,
	.Sub = 4,
	.Mul = 4,
	.Div = 14,
	.Mod = INFINITE,
	.Pow = INFINITE,
	.Mul_High = INFINITE,
	.Neg = 3,
	.And = INFINITE,
	.Or  = INFINITE,
	.Xor = INFINITE,
	.Not = INFINITE,
	.Shl = INFINITE,
	.Shr = INFINITE,
	.Eq  = INFINITE,
	.Ne  = INFINITE,
	.Lt  = INFINITE,
	.Le  = INFINITE,
	.Gt  = INFINITE,
	.Ge  = INFINITE,
}

// X64: the machine the x86-64 backend writes for: two lanes of SSE2, each in the
// frame — loaded, computed, stored.
X64 := Costs {
	ints   = X64_INTS,
	reals  = X64_REALS,
	load   = 1,
	call   = 20,
	branch = 3,
	turns  = 16,
	lanes  = 2,
	vints  = X64_LANES,
	vreals = X64_REAL_LANES,
	splat  = 3,
	reduce = 3,
}

// GCC: x86-64 as the C compiler writes for it, its own vectors.
GCC := Costs {
	ints   = X64_INTS,
	reals  = X64_REALS,
	load   = 1,
	call   = 20,
	branch = 3,
	turns  = 16,
	lanes  = 0,
	vints  = SSE2_INTS,
	vreals = SSE2_REALS,
	splat  = 2,
	reduce = 2,
}

// C: x86-64 as the C compiler writes for it, with the vectors of SSE2.
C := Costs {
	ints   = X64_INTS,
	reals  = X64_REALS,
	load   = 1,
	call   = 20,
	branch = 3,
	turns  = 16,
	lanes  = 2,
	vints  = SSE2_INTS,
	vreals = SSE2_REALS,
	splat  = 2,
	reduce = 2,
}


// extract: the node of least cost of each class, by its index — -1 for a class
// nothing computes —, and that cost. A computation costs what each class it reaches costs once —
// computed once, read as often as it is —: its weight times how often it runs, the
// turns of each loop it is in (a class is where its scope is). From the best each
// class has, to a fixed point; a node that reaches its own class is no computation
// of it.
extract :: proc(g: ^Graph, costs: ^Costs) -> (best: []int, cost: []f64) {
	scope := scopes(g)
	index_members(g)
	turns := make([]f64, len(g.loops))
	for _, l in g.loops do turns[l] = turns_of(g, costs, l)
	n := len(g.parent)
	runs := make([]f64, n)
	for &r, c in runs {
		r = 1
		if s, has := scope[c].?; has do r = runs_in(g, turns, s)
	}
	best = make([]int, n)
	cost = make([]f64, n)
	reach := make([][]Class, n)
	for &b in best do b = -1
	for &c in cost do c = INFINITE
	local :: proc(g: ^Graph, costs: ^Costs, runs: []f64, best: []int, x: Class) -> f64 {
		return weight(g, costs, g.nodes[best[x]]) * runs[x]
	}
	for round := 0; round < 64; round += 1 {
		changed := false
		for node, id in g.nodes {
			c := find(g, g.home[id])
			r, defined := node_scope(g, node, scope)
			if s, has := scope[c].?; !defined || !has || r != s do continue
			// what it reaches: its arguments' classes, and theirs
			reached := make([dynamic]Class, context.temp_allocator)
			computes := true
			for a in node.args {
				a := find(g, a)
				if best[a] < 0 || contains(reach[a], c) {
					computes = false
					break
				}
				for x in reach[a] do insert_sorted(&reached, x)
			}
			if !computes do continue
			total := weight(g, costs, node) * runs[c]
			for x in reached do if x != c do total += local(g, costs, runs, best, x)
			if total < cost[c] - 1e-9 {
				cost[c], best[c] = total, id
				insert_sorted(&reached, c)
				delete(reach[c])
				reach[c] = make([]Class, len(reached))
				copy(reach[c], reached[:])
				changed = true
			}
		}
		if !changed do break
	}
	return
}

// runs_in: how often a computation in the region r runs: the turns of each loop it
// is in.
runs_in :: proc(g: ^Graph, turns: []f64, r: Region) -> f64 {
	out: f64 = 1
	for x := r; x.kind != .Root; x = parent_of(g, x) do if x.kind == .Body do out *= turns[x.owner]
	return out
}

// turns_of: how many turns the loop l runs, at most: those it was given; or, for a
// counter by d at each turn, the integers it takes while it goes on — the fewest
// a reading of it is proven in — over |d|; or as many as a loop does.
turns_of :: proc(g: ^Graph, costs: ^Costs, l: int) -> f64 {
	info := g.loops[l]
	if info.turns > 0 do return info.turns
	out := costs.turns
	for j, d in counters(g, l) {
		param, read := lookup(g, Node{kind = .Param, owner = l, index = j})
		if !read do continue
		c := find(g, g.home[param])
		width := g.facts[c].bounds.hi - g.facts[c].bounds.lo
		for x, id in g.nodes do if x.kind == .Narrow && find(g, x.args[0]) == c {
			b := g.facts[find(g, g.home[id])].bounds
			width = min(width, b.hi - b.lo)
		}
		if width >= 0 && width < 1 << 62 do out = max(out, f64(width) / f64(abs(d)) + 1)
	}
	return out
}

contains :: proc(set: []Class, c: Class) -> bool {
	lo, hi := 0, len(set)
	for lo < hi {
		mid := (lo + hi) / 2
		if set[mid] == c do return true
		if set[mid] < c do lo = mid + 1
		else do hi = mid
	}
	return false
}

insert_sorted :: proc(set: ^[dynamic]Class, c: Class) {
	lo, hi := 0, len(set)
	for lo < hi {
		mid := (lo + hi) / 2
		if set[mid] == c do return
		if set[mid] < c do lo = mid + 1
		else do hi = mid
	}
	inject_at(set, lo, c)
}

// weight: what the operation of n costs, once, on the machine.
weight :: proc(g: ^Graph, costs: ^Costs, n: Node) -> f64 {
	switch n.kind {
	case .Param:
		// a parameter a law carries: what a turn does to it
		op, carried := g.loops[n.owner].carried[n.index].?
		if !carried do return 0
		return table(costs, kind_facts(g.loops[n.owner].params[n.index]))[op]
	case .Int, .Argument, .Start, .Arm, .Get, .Narrow, .Again, .Exit, .Loop:
		return 0
	case .Real, .Text, .Input, .Lanes:
		return costs.load
	case .Splat:
		return costs.splat
	case .Reduce:
		a := g.facts[find(g, n.args[0])]
		return costs.reduce * f64(a.lanes - 1)
	case .Unary:
		a := g.facts[find(g, n.args[0])]
		return table(costs, a)[n.op]
	case .Binary:
		a, b := g.facts[find(g, n.args[0])], g.facts[find(g, n.args[1])]
		ops := table(costs, a)
		w := ops[n.op]
		if a.lanes > 0 && a.machine == .Int {
			// in 32 bits, a product is one instruction; not negative, a shift
			if n.op == .Mul && in_32(a.bounds) && in_32(b.bounds) do w = ops[.Mul] / 2
			if n.op == .Shr && a.bounds.lo >= 0 do w = ops[.Shl]
		}
		// a power by squaring: a square, a product and a branch for each bit of the count
		if n.op == .Pow && a.lanes == 0 do w = f64(bits(b.bounds.hi)) * (2 * ops[.Mul] + costs.branch)
		// a constant first takes a register
		if a.constant != nil && a.lanes == 0 do w += costs.load
		return w
	case .In:
		// a comparison for each side of each cell
		return 2 * costs.ints[.Le] * f64(len(g.covers[n.index].ints) + len(g.covers[n.index].reals))
	case .Select:
		// a mask and three operations on lanes; a test and a move
		t := g.facts[find(g, n.args[1])]
		if t.lanes > 0 do return 4 * table(costs, t)[.Xor]
		return 2 * costs.ints[.And]
	case .Foreign, .Call:
		return costs.call
	case .Match:
		return costs.branch * f64(len(g.matches[n.owner].covers) - 1)
	}
	return INFINITE
}

// table: what an operation costs on the machine of a.
table :: proc(costs: ^Costs, a: Facts) -> [code.Op]f64 {
	if a.lanes > 0 do return a.machine == .Real ? costs.vreals : costs.vints
	return a.machine == .Real ? costs.reals : costs.ints
}

kind_facts :: proc(k: code.Kind) -> Facts {
	return Facts{machine = k.machine, bounds = k.bounds, lanes = k.lanes}
}

// in_32: integers not negative that 32 bits hold.
in_32 :: proc(b: code.Bounds) -> bool {
	return b.lo >= 0 && b.hi < 1 << 32
}

// bits: the bits of a count up to hi.
bits :: proc(hi: i128) -> int {
	out := 0
	for x := min(hi, i128(max(i64))); x > 0; x >>= 1 do out += 1
	return out
}
