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
// A computation runs on the paths that use it, not on the others: where its uses
// lie in some arms of a match only, it is written in each of those arms — once on
// each path that needs it —, unless running it where it is not needed costs no
// more than a branch, or it leaves a loop: then it runs once, above. A call costs
// its function, which its weight does not say: it does not go above an arm that
// does not need it.
//
// A match, a loop, an effect stay in their region, and a state, an argument, a
// parameter, an arm are in theirs; an Again and an Exit are written where each use
// is.

Plan :: struct {
	g:     ^Graph,
	best:  []int, // per class: the node of least cost
	order: [dynamic]Class, // the classes reached, each after the classes it reads
	place: [][]Region, // per class: the regions it is written in — one, or arms of a match
	dear:  []i8, // per class: 1 when running it where it is not needed costs more than a branch, -1 when not
	gets:  map[Get_Key]Class, // what a node gives, read
	live:  [][]bool, // per loop, per parameter: read by what is reached
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
	p := new_clone(Plan{g = g, best = best, place = make([][]Region, len(g.parent)), dear = make([]i8, len(g.parent))})
	// the parameters alive: those a computation reached reads, and the state; then
	// what each Again gives them
	p.live = make([][]bool, len(g.loops))
	for info, l in g.loops {
		p.live[l] = make([]bool, len(info.params))
		if info.state >= 0 do p.live[l][info.state] = true
	}
	reached := make([]bool, len(g.parent))
	for {
		alive := count_live(p)
		clear(&p.order)
		for &r in reached do r = false
		for c in roots do if c != NO_CLASS do reach(p, c, reached)
		if p.error != "" || count_live(p) == alive do break
	}
	if p.error != "" do return p
	early := make([]Region, len(g.parent))
	for c in p.order do early[c] = earliest(p, c, early)
	uses := make([][dynamic]Region, len(g.parent))
	use :: proc(g: ^Graph, uses: [][dynamic]Region, c: Class, r: Region) {
		c := find(g, c)
		for u in uses[c] do if u == r do return
		append(&uses[c], r)
	}
	for c in roots do if c != NO_CLASS do use(g, uses, c, ROOT)
	#reverse for c in p.order {
		n := chosen(p, c)
		late, used := ancestor(g, uses[c][:])
		switch {
		case pinned(p, n^):
			p.place[c] = one_region(early[c])
		case n.kind == .Again || n.kind == .Exit:
			p.place[c] = one_region(used ? late : early[c])
		case:
			if !used {
				p.error = fmt.tprintf("a computation reached is used nowhere: %v", n.kind)
				return p
			}
			r, ok := choose(g, n^, early[c], late)
			if !ok {
				p.error = fmt.tprintf("a %v is used where what it reads is not computed", n.kind)
				return p
			}
			if r == late && is_dear(p, c) {
				places := make([dynamic]Region)
				spread(g, uses[c][:], late, &places)
				p.place[c] = places[:]
			} else do p.place[c] = one_region(r)
		}
		// its uses: in the arms of a match, in the body of a loop, where it is
		for at in p.place[c] {
			#partial switch n.kind {
			case .Match:
				info := g.matches[n.owner]
				first := info.state ? 2 : 1
				per := (len(n.args) - first) / len(info.covers)
				for a in n.args[:first] do use(g, uses, a, at)
				for k in 0 ..< len(info.covers) do for a in n.args[first + k * per:][:per] do use(g, uses, a, Region{.Arm, n.owner, k})
			case .Loop:
				last := len(n.args) - 1
				for a, j in n.args[:last] do if p.live[n.owner][j] do use(g, uses, a, at)
				use(g, uses, n.args[last], Region{.Body, n.owner, 0})
			case .Again:
				for a, j in n.args do if p.live[n.owner][j] do use(g, uses, a, at)
			case:
				for a in n.args do use(g, uses, a, at)
			}
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
	#partial switch n.kind {
	case .Param:
		p.live[n.owner][n.index] = true
	case .Again:
		for a, j in n.args do if p.live[n.owner][j] do reach(p, a, reached)
	case .Loop:
		last := len(n.args) - 1
		for a, j in n.args[:last] do if p.live[n.owner][j] do reach(p, a, reached)
		reach(p, n.args[last], reached)
	case:
		for a in n.args do reach(p, a, reached)
	}
	if n.kind == .Get {
		p.gets[Get_Key{find(p.g, n.args[0]), n.index}] = c
		// a parameter a loop gives at its end is alive
		if t := chosen(p, n.args[0]); t.kind == .Loop {
			info := p.g.loops[t.owner]
			if k := n.index - outputs(info); k >= 0 do p.live[t.owner][info.finals[k]] = true
		}
	}
	append(&p.order, c)
}

count_live :: proc(p: ^Plan) -> int {
	out := 0
	for l in p.live do for x in l do if x do out += 1
	return out
}

// pinned: a computation that stays in its region.
pinned :: proc(p: ^Plan, n: Node) -> bool {
	#partial switch n.kind {
	case .Start, .Param, .Arm, .Match, .Loop, .Foreign, .Memory:
		return true
	case .Call:
		return !p.g.prog.funcs[n.index].pure
	case .Get:
		// what a tuple gives, where it is
		return pinned(p, chosen(p, n.args[0])^)
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

// ancestor: the innermost region all of the regions are in.
ancestor :: proc(g: ^Graph, rs: []Region) -> (Region, bool) {
	if len(rs) == 0 do return ROOT, false
	out := rs[0]
	for r in rs[1:] do out = lca(g, out, r)
	return out, true
}

one_region :: proc(r: Region) -> []Region {
	out := make([]Region, 1)
	out[0] = r
	return out
}

// is_dear: running c where it is not needed costs more than a branch: its own
// operation, or one it reads that would run there with it. A computation that
// stays in its region runs there anyway; a call costs its function.
is_dear :: proc(p: ^Plan, c: Class) -> bool {
	c := find(p.g, c)
	if p.dear[c] != 0 do return p.dear[c] > 0
	n := chosen(p, c)^
	out := false
	if !pinned(p, n) {
		p.dear[c] = -1 // a computation does not read itself
		out = n.kind == .Call || weight(p.g, p.g.costs, n) > p.g.costs.branch
		for a in n.args do if !out do out = is_dear(p, a)
	}
	p.dear[c] = out ? 1 : -1
	return out
}

// spread: the regions in r a computation used in the regions uses is written in:
// r, where a use is r itself or the uses are not all in the arms of one match of
// r, or every arm of it uses it; else, of each arm that uses it, its own.
spread :: proc(g: ^Graph, uses: []Region, r: Region, out: ^[dynamic]Region) {
	m := -1
	for u in uses {
		k := child_of(g, u, r)
		if u == r || k.kind != .Arm || (m >= 0 && k.owner != m) {
			append(out, r)
			return
		}
		m = k.owner
	}
	arms := make([][dynamic]Region, len(g.matches[m].covers), context.temp_allocator)
	for u in uses {
		k := child_of(g, u, r)
		append(&arms[k.arm], u)
	}
	all := true
	for a in arms do all = all && len(a) > 0
	if all {
		append(out, r)
		return
	}
	for a, k in arms do if len(a) > 0 do spread(g, a[:], Region{.Arm, m, k}, out)
}

// child_of: the region in r that u is in — u is in r and not r.
child_of :: proc(g: ^Graph, u, r: Region) -> Region {
	x := u
	for x != r && parent_of(g, x) != r do x = parent_of(g, x)
	return x
}

// speculable: a computation that cannot fail nor go on, whatever its arguments.
speculable :: proc(g: ^Graph, n: Node) -> bool {
	#partial switch n.kind {
	case .Int, .Real, .Text, .Input, .Argument, .Unary, .In, .Narrow, .Splat, .Lanes, .Reduce, .Select:
		return true
	case .Call:
		// a pure function of the program: an equation, which ends
		return g.prog.funcs[n.index].pure
	case .Get:
		// a value of a tuple, read after it
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
