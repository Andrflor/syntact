package code_calc

import "core:fmt"

// THE PLACE OF EACH COMPUTATION
//
// The regions nest: a match runs in a region and each of its arms is one, a loop
// runs in a region and its body is one. A computation that takes no state is not
// written anywhere: it goes where its uses need it (Click, Global Code Motion). It
// cannot run before what it reads — its earliest region, the innermost of theirs —,
// it must run before each use — its latest, the region all its uses are in —; from
// the latest up to the earliest, it goes to the region in the fewest loops, the
// latest of them. Out of the body of a loop, it runs once instead of at each turn:
// the body runs at least once. Out of an arm, it runs where the arm would not: only
// a computation that cannot fail nor go on goes.
//
// A match, a loop, an effect stay in their region, and a state, an argument, a
// parameter, an arm are in theirs; an Again and an Exit are written where each use
// is.

Plan :: struct {
	g:     ^Graph,
	best:  []int, // per class: the node of least cost
	order: [dynamic]Class, // the classes reached, each after the classes it reads
	place: []Region,
	gets:  map[Get_Key]Class, // what a node gives, read
	error: string,
}

Get_Key :: struct {
	tuple: Class,
	index: int,
}

chosen :: proc(p: ^Plan, c: Class) -> ^Node {
	return &p.g.nodes[p.best[find(p.g, c)]]
}

// plan: the classes the value and the state of a function reach, by their node of
// least cost, and the place of each.
plan :: proc(g: ^Graph, best: []int, roots: []Class) -> ^Plan {
	p := new_clone(Plan{g = g, best = best, place = make([]Region, len(g.parent))})
	reached := make([]bool, len(g.parent))
	for c in roots do if c != NO_CLASS do reach(p, c, reached)
	if p.error != "" do return p
	early := make([]Region, len(g.parent))
	for c in p.order do early[c] = earliest(p, c, early)
	late := make([]Maybe(Region), len(g.parent))
	use :: proc(g: ^Graph, late: []Maybe(Region), c: Class, r: Region) {
		c := find(g, c)
		if l, has := late[c].?; has do late[c] = lca(g, l, r)
		else do late[c] = r
	}
	for c in roots do if c != NO_CLASS do use(g, late, c, ROOT)
	#reverse for c in p.order {
		n := chosen(p, c)
		switch {
		case pinned(p, n^):
			p.place[c] = early[c]
		case n.kind == .Again || n.kind == .Exit:
			p.place[c] = late[c].? or_else early[c]
		case:
			l, used := late[c].?
			if !used {
				p.error = fmt.tprintf("a computation reached is used nowhere: %v", n.kind)
				return p
			}
			r, ok := choose(g, n^, early[c], l)
			if !ok {
				p.error = fmt.tprintf("a %v is used where what it reads is not computed", n.kind)
				return p
			}
			p.place[c] = r
		}
		// its uses: in the arms of a match, in the body of a loop, where it is
		#partial switch n.kind {
		case .Match:
			info := g.matches[n.owner]
			first := info.state ? 2 : 1
			per := (len(n.args) - first) / len(info.covers)
			for a in n.args[:first] do use(g, late, a, p.place[c])
			for k in 0 ..< len(info.covers) do for a in n.args[first + k * per:][:per] do use(g, late, a, Region{.Arm, n.owner, k})
		case .Loop:
			last := len(n.args) - 1
			for a in n.args[:last] do use(g, late, a, p.place[c])
			use(g, late, n.args[last], Region{.Body, n.owner, 0})
		case:
			for a in n.args do use(g, late, a, p.place[c])
		}
	}
	return p
}

// reach: the classes c reads, then c.
reach :: proc(p: ^Plan, c: Class, reached: []bool) {
	c := find(p.g, c)
	if reached[c] do return
	reached[c] = true
	if p.best[c] < 0 {
		p.error = "a class has no computation"
		return
	}
	n := chosen(p, c)
	for a in n.args do reach(p, a, reached)
	if n.kind == .Get do p.gets[Get_Key{find(p.g, n.args[0]), n.index}] = c
	append(&p.order, c)
}

// pinned: a computation that stays in its region.
pinned :: proc(p: ^Plan, n: Node) -> bool {
	#partial switch n.kind {
	case .Start, .Param, .Arm, .Match, .Loop, .Foreign, .Get:
		return true
	case .Call:
		return !p.g.prog.funcs[n.index].pure
	}
	return false
}

// earliest: the first region c can run in.
earliest :: proc(p: ^Plan, c: Class, early: []Region) -> Region {
	g := p.g
	n := chosen(p, c)
	#partial switch n.kind {
	case .Param:
		return Region{.Body, n.owner, 0}
	case .Arm:
		return Region{.Arm, n.owner, n.index}
	case .Match:
		return g.matches[n.owner].parent
	case .Loop:
		return g.loops[n.owner].parent
	}
	out := ROOT
	for a in n.args do out = inner(g, out, early[find(g, a)])
	return out
}

// choose: from the latest region up to the earliest, the one in the fewest loops,
// the latest of them; out of an arm, only what can run where the arm would not.
choose :: proc(g: ^Graph, n: Node, early, late: Region) -> (Region, bool) {
	best, r := late, late
	for r != early {
		if r.kind == .Root do return early, false
		if r.kind == .Arm && !speculable(g, n) do break
		r = parent_of(g, r)
		if loop_depth(g, r) < loop_depth(g, best) do best = r
	}
	if !inside(g, best, early) do return early, false
	return best, true
}

// speculable: a computation that cannot fail nor go on, whatever its arguments.
speculable :: proc(g: ^Graph, n: Node) -> bool {
	#partial switch n.kind {
	case .Int, .Real, .Text, .Input, .Argument, .Unary, .In, .Narrow:
		return true
	case .Binary:
		#partial switch n.op {
		case .Div, .Mod:
			a, b := g.facts[find(g, n.args[0])], g.facts[find(g, n.args[1])]
			if b.machine != .Int do return true
			zero := b.bounds.lo <= 0 && b.bounds.hi >= 0
			overflow := b.bounds.lo <= -1 && b.bounds.hi >= -1 && a.bounds.lo <= i128(min(i64))
			return !zero && !overflow
		}
		return true
	}
	return false
}

parent_of :: proc(g: ^Graph, r: Region) -> Region {
	switch r.kind {
	case .Arm:
		return g.matches[r.owner].parent
	case .Body:
		return g.loops[r.owner].parent
	case .Root:
	}
	return ROOT
}

depth :: proc(g: ^Graph, r: Region) -> int {
	out := 0
	for x := r; x.kind != .Root; x = parent_of(g, x) do out += 1
	return out
}

loop_depth :: proc(g: ^Graph, r: Region) -> int {
	out := 0
	for x := r; x.kind != .Root; x = parent_of(g, x) do if x.kind == .Body do out += 1
	return out
}

// inside: a is b or a region in it.
inside :: proc(g: ^Graph, a, b: Region) -> bool {
	for x := a; ; x = parent_of(g, x) {
		if x == b do return true
		if x.kind == .Root do return false
	}
}

// inner: the region in the other, of two on one chain.
inner :: proc(g: ^Graph, a, b: Region) -> Region {
	return depth(g, a) >= depth(g, b) ? a : b
}

// lca: the innermost region both are in.
lca :: proc(g: ^Graph, a, b: Region) -> Region {
	a, b := a, b
	da, db := depth(g, a), depth(g, b)
	for da > db {
		a = parent_of(g, a)
		da -= 1
	}
	for db > da {
		b = parent_of(g, b)
		db -= 1
	}
	for a != b {
		a, b = parent_of(g, a), parent_of(g, b)
	}
	return a
}
