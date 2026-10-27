package code_calc

import code ".."

// THE LAW OF SELECTS
//
// A match whose arms have no effect, and whose values can be computed where its
// arm is not taken, is a select of them, its covers tested in order:
//
//   t ? {c₀ -> v₀  c₁ -> v₁  -> v₂} = (t in c₀) ? v₀ : ((t in c₁) ? v₁ : v₂)
//
// What an arm narrows, a value is computed from as it is outside — its facts those
// of the computation then —, and nothing in it may fail nor go on: a quotient by
// what may be 0 stays in its arm. Both values computed, one kept, no branch: which
// runs is the cost's to say, and in lanes, only a select runs. And membership in
// one cell is comparisons:
//
//   x in lo..hi = (x >= lo) [&] (x <= hi)        x in c = (x = c)

// selected: the law of selects on a match.
selected :: proc(g: ^Graph, c: Class, n: Node) {
	if n.kind != .Match do return
	info := &g.matches[n.owner]
	if info.tail || info.state || !info.value || info.selected do return
	info.selected = true
	value, read := lookup(g, Node{kind = .Get, index = 0, args = one(c)})
	if !read do return
	t := Unnarrow{g = g, match = n.owner}
	arms := len(info.covers)
	out, free := freed(&t, n.args[arms])
	if !free do return
	for k := arms - 2; k >= 0; k -= 1 {
		yes, free_yes := freed(&t, n.args[1 + k])
		if !free_yes do return
		append(&g.covers, info.covers[k])
		test := add(g, Node{kind = .In, index = len(g.covers) - 1, args = one(n.args[0])})
		out = add(g, Node{kind = .Select, args = three(test, yes, out)})
	}
	merge(g, g.home[value], out)
}

// cells: membership in one cell of integers, as comparisons.
cells :: proc(g: ^Graph, c: Class, n: Node) {
	if n.kind != .In do return
	cover := g.covers[n.index]
	x := find(g, n.args[0])
	if cover.negated || len(cover.ints) != 1 || len(cover.reals) > 0 || g.facts[x].machine != .Int do return
	cell := cover.ints[0]
	if !in_64(cell) do return
	if cell.lo == cell.hi {
		equal(g, c, binary(g, .Eq, x, add(g, int_node(i64(cell.lo)))))
		return
	}
	above := add(g, binary(g, .Ge, x, add(g, int_node(i64(cell.lo)))))
	below := add(g, binary(g, .Le, x, add(g, int_node(i64(cell.hi)))))
	equal(g, c, binary(g, .And, above, below))
}

// Unnarrow: the computations of a value of an arm of the match, as they are where
// its arm is not taken.
Unnarrow :: struct {
	g:     ^Graph,
	match: int,
	memo:  map[Class]Class,
	busy:  map[Class]bool,
}

// in_arm: the region r is in an arm of the match m.
in_arm :: proc(g: ^Graph, r: Region, m: int) -> bool {
	for x := r; x.kind != .Root; x = parent_of(g, x) do if x.kind == .Arm && x.owner == m do return true
	return false
}

// freed: c, computed outside the arms of the match.
freed :: proc(t: ^Unnarrow, c: Class) -> (Class, bool) {
	g := t.g
	c := find(g, c)
	if x, done := t.memo[c]; done do return x, true
	if c >= Class(len(g.scope)) do return NO_CLASS, false
	r, defined := g.scope[c].?
	if !defined do return NO_CLASS, false
	if !in_arm(g, r, t.match) do return c, true
	if t.busy[c] do return NO_CLASS, false
	t.busy[c] = true
	out := NO_CLASS
	for id in g.members[c] {
		n := g.nodes[id] // a copy: what adds a node moves the nodes
		x := free_node(t, n) or_continue
		out = out == NO_CLASS ? x : merge(g, out, x)
	}
	t.busy[c] = false
	if out == NO_CLASS do return NO_CLASS, false
	t.memo[c] = find(g, out)
	return t.memo[c], true
}

free_node :: proc(t: ^Unnarrow, n: Node) -> (c: Class, ok: bool) {
	g := t.g
	#partial switch n.kind {
	case .Narrow:
		// what an arm of the match narrows, as it is outside
		token := g.nodes[g.members[find(g, n.args[1])][0]]
		if token.kind == .Arm && token.owner == t.match do return freed(t, n.args[0])
		return NO_CLASS, false
	case .Unary, .Binary, .In, .Splat, .Lanes, .Reduce, .Select:
	case:
		return NO_CLASS, false
	}
	out := n
	args := make([]Class, len(n.args))
	for a, k in n.args do args[k] = freed(t, a) or_return
	out.args = args
	// a quotient, where the arm is not taken: by what may be 0, it would fail
	if n.kind == .Binary && (n.op == .Div || n.op == .Mod) {
		divisor := g.facts[find(g, args[1])]
		if divisor.machine == .Int && divisor.bounds.lo <= 0 && divisor.bounds.hi >= 0 do return NO_CLASS, false
		if divisor.machine == .Int && divisor.bounds.lo <= -1 && divisor.bounds.hi >= -1 && g.facts[find(g, args[0])].bounds.lo <= i128(min(i64)) do return NO_CLASS, false
	}
	return add(g, out), true
}
