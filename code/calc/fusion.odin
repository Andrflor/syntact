package code_calc

import "core:slice"

// THE FOLD OF A PAIR
//
// Folds over one orbit are the fold of their pair (banana split): two loops of one
// region whose counters start from one class, step by one δ and stop at one bound
// run the same turns; where neither reads what the other gives, they are one loop
// of the parameters of both, whose turn is the turn of each, and which gives what
// each gives. Its effects are those of the one that has some, in their order: two
// loops with effects are not one.
//
//   ⟳(x ↦ f(x)) × ⟳(y ↦ h(y)) = ⟳((x, y) ↦ (f(x), h(y)))
//
// Two parameters p, q of one loop that start from one class, and whose nexts are
// one computation where p and q are identified, are one: by induction on the
// turns, equal at the first, and at the next where equal at this one.

// fusable: a loop of the code — or one a law of the code made — whose turns the
// law of the pair may run with another's.
fusable :: proc(info: Loop_Info) -> bool {
	return (info.origin == .Code || info.origin == .Laned) && len(info.parts) > 0 && len(info.finals) == 0
}

// paired: the law of the pair on each two loops of a region, once; a loop with
// effects only with a pure one.
paired :: proc(g: ^Graph) {
	count := len(g.loops)
	steps := make([]map[int]i64, count, context.temp_allocator)
	for l in 0 ..< count do if fusable(g.loops[l]) do steps[l] = counters(g, l)
	for l1 in 0 ..< count do for l2 in 0 ..< count {
		a, b := g.loops[l1], g.loops[l2]
		if l1 == l2 || !fusable(a) || !fusable(b) || a.parent != b.parent || a.state >= 0 do continue
		if b.state < 0 && l1 > l2 do continue
		if len(steps[l1]) == 0 || len(steps[l2]) == 0 || overlap(a.parts, b.parts) do continue
		fuse(g, l1, l2, steps[l1], steps[l2])
	}
}

// overlap: two sets of loops of the code, sorted, share one.
overlap :: proc(a, b: []int) -> bool {
	for x in a do if _, found := slice.binary_search(b, x); found do return true
	return false
}

// fuse: the loop of the pair l1, l2, when their counters run one orbit to one
// bound and neither reads what the other gives.
fuse :: proc(g: ^Graph, l1, l2: int, steps1, steps2: map[int]i64) -> bool {
	a, b := g.loops[l1], g.loops[l2]
	node1, node2 := g.nodes[a.node], g.nodes[b.node]
	t1 := turn_of(g, node1.args[len(node1.args) - 1], l1) or_return
	t2 := turn_of(g, node2.args[len(node2.args) - 1], l2) or_return
	if !same_orbit(g, t1, t2, l1, l2, steps1, steps2) do return false
	// neither reads what the other gives: each has a computation without it
	c1, c2 := find(g, g.home[a.node]), find(g, g.home[b.node])
	free1, free2 := without(g, c1), without(g, c2)
	for x in node2.args do if !free1[find(g, x)] do return false
	for x in node1.args do if !free2[find(g, x)] do return false
	own1, own2 := own_params(a), own_params(b)
	inits := make([dynamic]Class)
	append(&inits, ..node1.args[:own1])
	append(&inits, ..node2.args[:own2])
	parts := make([dynamic]int)
	append(&parts, ..a.parts)
	append(&parts, ..b.parts)
	slice.sort(parts[:])
	// once
	for other in g.loops do if same_parts(other.parts, parts[:]) && starts_from(g, other, inits[:]) do return false
	// the loop of the pair: its parameters, its match, its tail
	f := len(g.loops)
	info := Loop_Info{parent = a.parent, state = b.state >= 0 ? own1 + b.state : -1, values = a.values + b.values, origin = .Code, parts = parts[:], turns = turns_of(g, g.costs, l1)}
	for k in a.params[:own1] do append(&info.params, k)
	for k in b.params[:own2] do append(&info.params, k)
	for _ in info.params do append(&info.carried, nil)
	append(&g.loops, info)
	m1, m2 := t1.match.owner, t2.match.owner
	m := len(g.matches)
	append(&g.matches, Match_Info{parent = Region{.Body, f, 0}, covers = g.matches[m1].covers, state = b.state >= 0, tail = true})
	t := Copy{g = g, from = []int{l1, l2}, base = []int{0, own1}, to = f}
	t.matches[m1], t.matches[m2] = m, m
	t.arms[{m2, t2.exit}], t.arms[{m2, t2.step}] = t1.exit, t1.step
	built := build_pair(&t, t1, t2, own1, own2)
	if built == NO_CLASS {
		abandon(g, f)
		return false
	}
	args := make([dynamic]Class)
	append(&args, ..inits[:])
	append(&args, built)
	pair := add(g, Node{kind = .Loop, owner = f, args = args[:]})
	g.loops[f].node = len(g.nodes) - 1
	// what each gives
	for k in 0 ..< a.values do merge(g, given(g, c1, k), given(g, pair, k))
	for k in 0 ..< outputs(b) do merge(g, given(g, c2, k), given(g, pair, a.values + k))
	return true
}

// same_orbit: a counter of l1 and one of l2 start from one class, by one δ, and
// their tests stop them at one bound.
same_orbit :: proc(g: ^Graph, t1, t2: Turn, l1, l2: int, steps1, steps2: map[int]i64) -> bool {
	start1, start2 := g.nodes[g.loops[l1].node].args, g.nodes[g.loops[l2].node].args
	for i1, d1 in steps1 do for i2, d2 in steps2 {
		if d1 != d2 || find(g, start1[i1]) != find(g, start2[i2]) do continue
		s1, ok1 := stop_of(g, t1, l1, i1, d1)
		s2, ok2 := stop_of(g, t2, l2, i2, d2)
		if ok1 && ok2 && s1.op == s2.op && find(g, s1.bound) == find(g, s2.bound) do return true
	}
	return false
}

// starts_from: the loop's node starts its own parameters from inits.
starts_from :: proc(g: ^Graph, info: Loop_Info, inits: []Class) -> bool {
	args := g.nodes[info.node].args
	if own_params(info) != len(inits) do return false
	for x, k in inits do if find(g, x) != find(g, args[k]) do return false
	return true
}

// build_pair: the tail of the loop of the pair: the test of t1; at its end what
// each gives, then the state of t2; at each turn what each takes next.
build_pair :: proc(t: ^Copy, t1, t2: Turn, own1, own2: int) -> Class {
	g := t.g
	m := t.matches[t1.match.owner]
	arms := make([]Class, 2)
	ending := make([dynamic]Class)
	for x in t1.ending.args do append(&ending, copied(t, x) or_else NO_CLASS)
	for x in t2.ending.args do append(&ending, copied(t, x) or_else NO_CLASS)
	again := make([dynamic]Class)
	for x in t1.again.args[:own1] do append(&again, copied(t, x) or_else NO_CLASS)
	for x in t2.again.args[:own2] do append(&again, copied(t, x) or_else NO_CLASS)
	target := copied(t, t1.match.args[0]) or_else NO_CLASS
	outs := make([dynamic]Class)
	append(&outs, target)
	if g.matches[m].state do append(&outs, copied(t, t2.match.args[1]) or_else NO_CLASS)
	for x in outs do if x == NO_CLASS do return NO_CLASS
	for x in ending do if x == NO_CLASS do return NO_CLASS
	for x in again do if x == NO_CLASS do return NO_CLASS
	arms[t1.exit] = add(g, Node{kind = .Exit, owner = t.to, args = ending[:]})
	arms[t1.step] = add(g, Node{kind = .Again, owner = t.to, args = again[:]})
	append(&outs, ..arms)
	return add(g, Node{kind = .Match, owner = m, args = outs[:]})
}

// identified: in each loop, two parameters that start from one class and whose
// nexts are one computation where they are identified, one.
identified :: proc(g: ^Graph) {
	for info, l in g.loops {
		if info.node >= len(g.nodes) || g.nodes[info.node].kind != .Loop || g.nodes[info.node].owner != l do continue
		starts := g.nodes[info.node].args
		agains := make([dynamic]Node, context.temp_allocator)
		for n in g.nodes do if n.kind == .Again && n.owner == l do append(&agains, n)
		if len(agains) == 0 do continue
		count := len(starts) - 1
		for p in 0 ..< count do for q in p + 1 ..< count {
			if p == info.state || q == info.state || info.params[p] != info.params[q] do continue
			if find(g, starts[p]) != find(g, starts[q]) do continue
			pp, has_p := lookup(g, Node{kind = .Param, owner = l, index = p})
			qq, has_q := lookup(g, Node{kind = .Param, owner = l, index = q})
			if !has_p || !has_q do continue
			x, y := find(g, g.home[pp]), find(g, g.home[qq])
			if x == y do continue
			memo := make(map[[2]Class]bool, context.temp_allocator)
			same := true
			for n in agains do same &&= p < len(n.args) && q < len(n.args) && identical(g, n.args[p], n.args[q], {x, y}, &memo, 0)
			if same do merge(g, x, y)
		}
	}
}

// identical: a and b are one value where the classes of pair are: one class, the
// pair itself, a narrowing of one the other, or one operation on identical
// arguments.
identical :: proc(g: ^Graph, a, b: Class, pair: [2]Class, memo: ^map[[2]Class]bool, depth: int) -> bool {
	a, b := find(g, a), find(g, b)
	if a == b do return true
	if a == find(g, pair[0]) && b == find(g, pair[1]) || a == find(g, pair[1]) && b == find(g, pair[0]) do return true
	if depth > 32 || a >= Class(len(g.members)) || b >= Class(len(g.members)) do return false
	if x, done := memo[{a, b}]; done do return x
	memo[{a, b}] = false
	out := false
	search: for i in g.members[a] {
		n := g.nodes[i]
		// a narrowing is the value it narrows
		if n.kind == .Narrow && identical(g, n.args[0], b, pair, memo, depth + 1) {
			out = true
			break
		}
		for j in g.members[b] {
			o := g.nodes[j]
			if o.kind == .Narrow && identical(g, a, o.args[0], pair, memo, depth + 1) {
				out = true
				break search
			}
			if n.kind != o.kind || n.op != o.op || n.value != o.value || n.index != o.index || n.owner != o.owner || len(n.args) != len(o.args) do continue
			same := true
			for x, k in n.args do same &&= identical(g, x, o.args[k], pair, memo, depth + 1)
			if same {
				out = true
				break search
			}
		}
	}
	memo[{a, b}] = out
	return out
}

// without: the classes one of whose computations does not read the class target,
// to a fixed point from what reads nothing.
without :: proc(g: ^Graph, target: Class) -> []bool {
	out := make([]bool, len(g.parent), context.temp_allocator)
	target := find(g, target)
	for changed := true; changed; {
		changed = false
		for n, id in g.nodes {
			c := find(g, g.home[id])
			if out[c] || c == target do continue
			free := true
			for a in n.args do free &&= out[find(g, a)]
			if free {
				out[c] = true
				changed = true
			}
		}
	}
	return out
}
