package code_calc

import code ".."

// THE LAW OF LANES
//
// ℤᴸ, the L lanes of a vector of the machine, is a ring lane by lane. δ: ℤ → ℤᴸ,
// a in each lane, is a homomorphism of rings; ρ⊕: Mᴸ → M, the lanes one after
// another by ⊕, one of monoids when ⊕ is associative and commutative — + * & | ^,
// on floats too. A loop folds monoids along its turns when each of its parameters
// is a step that composes, x ↦ M·x + b (steps.odin) — a counter i, by d, is one —,
// a reduction x ↦ x ⊕ g, g reading no reduction, or what no turn changes. Its
// turns, L at a time, are a loop over lanes, each lane one of L interleaved
// orbits (specs/types.md §4.10):
//
//   i ↦ i + L·d      X ↦ (M, b)ᴸ·X      R ↦ R ⊕ g⃗(I, X)
//
// from X = ((M, b)ᵏ·x)ₖ, R = δ(e), e the neutral of ⊕, I = ((M, b)ᵏ·i)ₖ the lanes of
// the counter, g⃗ g computed in each lane — its laws are those of any computation —,
// while the last lane goes on: then they all do, the test of the loop being one
// the counter crosses once. The turns the lanes leave are the loop itself, from
// where they stopped: each x from lane 0 of X, π₀ = ρ| ∘ (· & e₀), and each
// reduction from x ⊕ ρ⊕(R):
//
//   ⟳ = ⟳(i ↦ i_L, x ↦ π₀(X_L), r ↦ r ⊕ ρ⊕(R_L))      where the lanes stop
//
// Which runs, the loop or its lanes and the turns they leave, is the cost's to say.

// laned: the law of lanes on each loop of the code, once: interleaved and blocked
// orbits in lanes of words; interleaved in lanes of fewer bits.
laned :: proc(g: ^Graph) {
	if g.costs.lanes < 2 do return
	for l in 0 ..< len(g.loops) {
		if g.loops[l].origin != .Code do continue
		g.loops[l].origin = .Laned
		if f, is := fold_of(g, l, 0); is {
			interleaved(g, &f, g.costs.lanes, 0)
			blocked(g, &f, g.costs.lanes)
		}
		// ℤ → ℤ/2ʷ is a homomorphism of rings: where each lane and what it reads
		// stays within w bits, the lanes are of w bits, and more of them
		if g.costs.lanes32 > 0 {
			if f, is := fold_of(g, l, 32); is do interleaved(g, &f, g.costs.lanes32, 32)
		}
	}
}

// Stepped: a parameter whose turns compose, and its step.
Stepped :: struct {
	param: int,
	step:  Affine,
}

// Reduction: a parameter x ↦ x ⊕ g₁ ⊕ g₂ ⊕ …
Reduction :: struct {
	param: int,
	op:    code.Op,
	terms: []Class,
}

// Fold: a loop whose turns fold monoids: the counter its test reads, by delta,
// where it stops; its steps that compose, the counter first; its reductions; what
// no turn changes.
Fold :: struct {
	l:          int,
	info:       Loop_Info,
	loop:       Node,
	own:        int,
	turn:       Turn,
	counter:    int,
	delta:      i64,
	stop:       Stop,
	steps:      [dynamic]Stepped,
	reductions: [dynamic]Reduction,
	invariants: map[int]Class,
}

// fold_of: the loop l as a fold of monoids, in lanes of bits bits — 0: 64.
fold_of :: proc(g: ^Graph, l: int, bits: int) -> (f: Fold, ok: bool) {
	f.l, f.info = l, g.loops[l]
	if f.info.state >= 0 do return
	f.loop = g.nodes[f.info.node]
	f.own = own_params(f.info)
	f.turn = turn_of(g, f.loop.args[len(f.loop.args) - 1], l) or_return
	// the counter the test reads: where the lanes stop
	f.counter = -1
	for i, d in counters(g, l) {
		if x, crossed := stop_of(g, f.turn, l, i, d); crossed {
			f.counter, f.delta, f.stop = i, d, x
		}
	}
	if f.counter < 0 do return
	// the others: steps that compose, reductions, or what no turn changes
	append(&f.steps, Stepped{f.counter, Affine{a = 1, b = transmute(u64)f.delta}})
	for j in 0 ..< f.own {
		if j == f.counter do continue
		next := f.turn.again.args[j]
		if param, is := lookup(g, Node{kind = .Param, owner = l, index = j}); is && find(g, next) == find(g, g.home[param]) {
			f.invariants[j] = f.loop.args[j]
			continue
		}
		if r, is := reduction(g, next, l, j); is {
			append(&f.reductions, r)
			continue
		}
		step := affine_step(g, next, l, j) or_return
		// a lane of fewer bits than a word holds no orbit of a word
		if bits > 0 do return
		append(&f.steps, Stepped{j, step})
	}
	for r in f.reductions do for t in r.terms do for other in f.reductions do if reads_param(g, t, l, other.param) do return
	if bits > 0 {
		// what each lane gathers stays within its bits: its turns, times its terms
		turns := turns_of(g, g.costs, l) / f64(g.costs.lanes32)
		for r in f.reductions {
			if r.op == .Mul do return
			b := g.facts[find(g, r.terms[0])].bounds
			for t in r.terms[1:] do b = binary_bounds(r.op, b, g.facts[find(g, t)].bounds)
			if !fits(b, bits) || r.op == .Add && turns * f64(max(abs(b.lo), abs(b.hi))) >= f64(i128(1) << uint(bits - 1)) do return
		}
	}
	return f, true
}

// Built: a loop a law builds, in the region parent: its parameters, the arm its
// turns go on in, and its match.
Built :: struct {
	v, m:   int,
	params: []Class,
	step:   Class,
}

// new_loop: a loop of parameters of these kinds, in parent, each of which it gives
// at its end; it ends where its test is in the cover exit.
new_loop :: proc(g: ^Graph, parent: Region, kinds: []code.Kind, exit: code.Cover, origin: Origin, turns: f64 = 0) -> Built {
	b := Built{v = len(g.loops), m = len(g.matches)}
	info := Loop_Info{parent = parent, state = -1, origin = origin, turns = turns}
	for k, j in kinds {
		append(&info.params, k)
		append(&info.carried, nil)
		append(&info.finals, j)
	}
	append(&g.loops, info)
	covers := make([]code.Cover, 2)
	covers[0] = exit
	append(&g.matches, Match_Info{parent = Region{.Body, b.v, 0}, covers = covers, tail = true})
	b.params = make([]Class, len(kinds))
	for &p, j in b.params do p = add(g, Node{kind = .Param, owner = b.v, index = j})
	b.step = add(g, Node{kind = .Arm, owner = b.m, index = 1})
	return b
}

// close_loop: the loop b, from inits, its parameters taking nexts at each turn
// its test leaves the exit; its node.
close_loop :: proc(g: ^Graph, b: Built, test: Class, inits, nexts: []Class) -> Class {
	tail := add(g, Node{kind = .Match, owner = b.m, args = three(test, add(g, Node{kind = .Exit, owner = b.v}), add(g, Node{kind = .Again, owner = b.v, args = nexts}))})
	args := make([dynamic]Class)
	append(&args, ..inits)
	append(&args, tail)
	out := add(g, Node{kind = .Loop, owner = b.v, args = args[:]})
	g.loops[b.v].node = len(g.nodes) - 1
	return out
}

// given: what the loop of the node at gives at its end, the parameter k.
given :: proc(g: ^Graph, at: Class, k: int) -> Class {
	return add(g, Node{kind = .Get, index = k, args = one(at)})
}

// lane_of: lane k of a vector of lanes words: π_k = ρ| ∘ (· & e_k).
lane_of :: proc(g: ^Graph, x: Class, k, lanes, bits: int) -> Class {
	e := make([]i64, lanes)
	e[k] = -1
	only := add(g, binary(g, .And, x, add(g, Node{kind = .Lanes, index = vector(g, e), value = i128(bits)})))
	return add(g, Node{kind = .Reduce, op = .Or, args = one(only)})
}

// interleaved: the turns of the fold f, L at a time, each lane one of L
// interleaved orbits: the counter, scalar, by L·d; each other step that composes,
// a vector whose lane k is its k-th point, by its L-th power; each reduction, a
// vector; until the last lane would stop.
interleaved :: proc(g: ^Graph, f: ^Fold, lanes, bits: int) -> bool {
	kinds := make([dynamic]code.Kind)
	append(&kinds, code.Kind{.Int, code.EVERY, 0, 0})
	for _ in f.steps[1:] do append(&kinds, code.Kind{.Int, code.EVERY, lanes, bits})
	for r in f.reductions do append(&kinds, code.Kind{f.info.params[r.param].machine, code.EVERY, lanes, bits})
	stops := make([]code.Bounds, 1)
	stops[0] = {1, 1}
	b := new_loop(g, f.info.parent, kinds[:], code.Cover{ints = stops}, .Lanes)
	i := b.params[0]
	// the counter of the lanes takes points of the orbit of the loop's
	if param, is := lookup(g, Node{kind = .Param, owner = f.l, index = f.counter}); is {
		g.facts[find(g, i)].bounds = code.meet(g.facts[find(g, i)].bounds, g.facts[find(g, g.home[param])].bounds)
	}
	vectors := make(map[int]Class)
	vectors[f.counter] = orbit(g, f.steps[0].step, i, lanes, bits)
	for x, k in f.steps[1:] do vectors[x.param] = b.params[k + 1]
	// each step, L turns at once: its power
	nexts := make([dynamic]Class)
	append(&nexts, advanced(g, f.steps[0].step, i, 0, 0, lanes))
	for x, k in f.steps[1:] do append(&nexts, advanced(g, x.step, b.params[k + 1], lanes, bits, lanes))
	reduced_in_lanes(g, f, b, vectors, lanes, bits, &nexts) or_return
	// the lanes stop where the last would
	last := plus(g, i, add(g, int_node(i128(lanes - 1) * i128(f.delta))))
	test := add(g, binary(g, f.stop.op, last, f.stop.bound))
	inits := make([dynamic]Class)
	append(&inits, f.loop.args[f.counter])
	for x in f.steps[1:] do append(&inits, orbit(g, x.step, f.loop.args[x.param], lanes, bits))
	for r in f.reductions do append(&inits, splat(g, neutral_of(g, r.op, f.info.params[r.param].machine), lanes, bits))
	laned := close_loop(g, b, test, inits[:], nexts[:])
	// the turns the lanes leave: each step from lane 0
	starts := make(map[int]Class)
	starts[f.counter] = given(g, laned, 0)
	for x, k in f.steps[1:] do starts[x.param] = lane_of(g, given(g, laned, k + 1), 0, lanes, bits)
	return rest(g, f, laned, starts, len(f.steps), lanes)
}

// reduced_in_lanes: what each reduction gathers at a turn of the lanes b, its term in each
// lane, the parameters of the fold in their lanes.
reduced_in_lanes :: proc(g: ^Graph, f: ^Fold, b: Built, vectors: map[int]Class, lanes, bits: int, nexts: ^[dynamic]Class) -> bool {
	t := Lift{g = g, from = f.l, to = b.v, counter = f.counter, delta = f.delta, lanes = lanes, bits = bits, invariants = f.invariants, vectors = vectors}
	t.step_match, t.step_arm, t.step_to = f.turn.match.owner, f.turn.step, b.step
	first := len(b.params) - len(f.reductions)
	for r, k in f.reductions {
		x := b.params[first + k]
		for term in r.terms do x = add(g, binary(g, r.op, x, lift(&t, term) or_return))
		append(nexts, x)
	}
	return true
}

// rest: the turns the lanes leave: the loop again, from starts — each step where
// the lanes stopped, each reduction from what it held and the lanes gathered,
// from the first after the steps on —; the same value as the loop.
rest :: proc(g: ^Graph, f: ^Fold, laned: Class, starts: map[int]Class, first, lanes: int) -> bool {
	copy := copy_loop(g, f.l) or_return
	g.loops[copy].turns = f64(lanes) / 2
	inits := make([dynamic]Class)
	for j in 0 ..< f.own {
		if x, is := f.invariants[j]; is do append(&inits, x)
		if x, is := starts[j]; is do append(&inits, x)
		for r, k in f.reductions do if r.param == j {
			reduced := add(g, Node{kind = .Reduce, op = r.op, args = one(given(g, laned, first + k))})
			append(&inits, add(g, binary(g, r.op, f.loop.args[j], reduced)))
		}
	}
	node := &g.nodes[g.loops[copy].node]
	append(&inits, node.args[0])
	node.args = inits[:]
	merge(g, g.home[f.info.node], g.home[g.loops[copy].node])
	return true
}

three :: proc(a, b, c: Class) -> []Class {
	out := make([]Class, 3)
	out[0], out[1], out[2] = a, b, c
	return out
}

// own_params: how many parameters are the loop's own, before those laws carry.
own_params :: proc(info: Loop_Info) -> int {
	for c, j in info.carried do if c != nil do return j
	return len(info.carried)
}

// Turn: how a turn of a loop ends: a match whose arm exit gives what the loop
// gives, and whose arm step goes on, by an Again; the token of that arm.
Turn :: struct {
	match:      Node,
	exit, step: int,
	again:      Node,
	step_token: Class,
}

turn_of :: proc(g: ^Graph, tail: Class, l: int) -> (t: Turn, ok: bool) {
	for id in g.members[find(g, tail)] {
		n := g.nodes[id]
		if n.kind != .Match || !g.matches[n.owner].tail || len(n.args) != 3 do continue
		t.match = n
		t.exit, t.step = -1, -1
		for k in 0 ..< 2 {
			for aid in g.members[find(g, n.args[1 + k])] {
				a := g.nodes[aid]
				if a.owner != l do continue
				if a.kind == .Exit do t.exit = k
				if a.kind == .Again {
					t.step = k
					t.again = a
				}
			}
		}
		if t.exit < 0 || t.step < 0 || t.exit == t.step do continue
		token, has := lookup(g, Node{kind = .Arm, owner = n.owner, index = t.step})
		t.step_token = has ? find(g, g.home[token]) : NO_CLASS
		return t, true
	}
	return
}

// Stop: the lanes stop where the last of them is op bound.
Stop :: struct {
	op:    code.Op,
	bound: Class,
}

// stop_of: where the lanes from the counter i, by d, stop: when the test of the
// turn is one the counter crosses once, and does not cross back — a comparison of
// the counter with what no turn changes, or its membership in one cell where it
// stops —, where the last lane crosses it, all the lanes before it go on.
stop_of :: proc(g: ^Graph, turn: Turn, l, i: int, d: i64) -> (Stop, bool) {
	cover := g.matches[turn.match.owner].covers[0]
	target := turn.match.args[0]
	// x stops the turn
	stops :: proc(cover: code.Cover, exit: int, x: i64) -> bool {
		return in_cover(cover, x) == (exit == 0)
	}
	if _, is := counter_of(g, target, l, i); is {
		if turn.exit != 0 || cover.negated || len(cover.ints) != 1 || !in_64(cover.ints[0]) do return {}, false
		cell := cover.ints[0]
		if d < 0 do return Stop{.Le, add(g, int_node(cell.hi))}, true
		return Stop{.Ge, add(g, int_node(cell.lo))}, true
	}
	for id in g.members[find(g, target)] {
		n := g.nodes[id]
		if n.kind != .Binary || n.op not_in CONTRARY_OP_SET do continue
		op := n.op
		a, b := n.args[0], n.args[1]
		if _, is := counter_of(g, b, l, i); is {
			op = CONVERSE[op]
			a, b = b, a
		}
		if _, is := counter_of(g, a, l, i); !is || !invariant(g, b, l) do continue
		one, zero := stops(cover, turn.exit, 1), stops(cover, turn.exit, 0)
		if one == zero do continue
		if zero do op = CONTRARY_OP[op]
		#partial switch op {
		case .Gt, .Ge:
			if d > 0 do return Stop{op, b}, true
		case .Lt, .Le:
			if d < 0 do return Stop{op, b}, true
		}
	}
	return {}, false
}

in_cover :: proc(c: code.Cover, x: i64) -> bool {
	taken := false
	for b in c.ints do taken ||= b.lo <= i128(x) && i128(x) <= b.hi
	return taken != c.negated
}

CONTRARY_OP_SET :: bit_set[code.Op]{.Lt, .Le, .Gt, .Ge}

CONTRARY_OP := #partial [code.Op]code.Op {
	.Lt = .Ge,
	.Le = .Gt,
	.Gt = .Le,
	.Ge = .Lt,
}

// reduction: next, x ⊕ g with x the parameter j of l, ⊕ associative and
// commutative: (x ⊕ g) ⊕ h is x ⊕ (g ⊕ h) — on integers; floats round at each ⊕.
reduction :: proc(g: ^Graph, next: Class, l, j: int) -> (Reduction, bool) {
	busy := make(map[Class]bool)
	defer delete(busy)
	return reduced(g, next, l, j, &busy)
}

reduced :: proc(g: ^Graph, next: Class, l, j: int, busy: ^map[Class]bool) -> (Reduction, bool) {
	next := find(g, next)
	if busy[next] do return {}, false
	busy[next] = true
	defer busy[next] = false
	real := g.facts[next].machine == .Real
	for id in g.members[next] {
		n := g.nodes[id]
		if n.kind != .Binary do continue
		#partial switch n.op {
		case .Add, .Mul, .And, .Or, .Xor:
			if real && n.op != .Add && n.op != .Mul do continue
			for k in 0 ..< 2 {
				if param, is := lookup(g, Node{kind = .Param, owner = l, index = j}); is && find(g, n.args[k]) == find(g, g.home[param]) {
					terms := make([]Class, 1)
					terms[0] = find(g, n.args[1 - k])
					return Reduction{j, n.op, terms}, true
				}
				if real do continue
				if inner, is := reduced(g, n.args[k], l, j, busy); is && inner.op == n.op {
					terms := make([]Class, len(inner.terms) + 1)
					copy(terms, inner.terms)
					terms[len(inner.terms)] = find(g, n.args[1 - k])
					return Reduction{j, n.op, terms}, true
				}
			}
		}
	}
	return {}, false
}

// neutral_of: e, e ⊕ x = x.
neutral_of :: proc(g: ^Graph, op: code.Op, m: code.Machine) -> Class {
	if m == .Real do return add(g, Node{kind = .Real, value = i128(transmute(i64)(op == .Mul ? f64(1) : f64(0)))})
	#partial switch op {
	case .Mul:
		return add(g, int_node(1))
	case .And:
		return add(g, int_node(-1))
	}
	return add(g, int_node(0))
}

// reads_param: some computation of c reads the parameter j of l.
reads_param :: proc(g: ^Graph, c: Class, l, j: int) -> bool {
	seen := make(map[Class]bool)
	visit :: proc(g: ^Graph, c: Class, l, j: int, seen: ^map[Class]bool) -> bool {
		c := find(g, c)
		if c in seen do return false
		seen[c] = true
		if c >= Class(len(g.members)) do return false
		for id in g.members[c] {
			n := g.nodes[id]
			if n.kind == .Param && n.owner == l && n.index == j do return true
			for a in n.args do if visit(g, a, l, j, seen) do return true
		}
		return false
	}
	return visit(g, c, l, j, &seen)
}

// Lift: the computations of a turn of the loop from, in the lanes of the loop to:
// its counter in each lane, what no turn changes in each lane.
Lift :: struct {
	g:                 ^Graph,
	from, to:          int,
	counter:           int,
	delta:             i64,
	lanes:             int,
	bits:              int, // of each lane; 0: 64
	invariants:        map[int]Class,
	vectors:           map[int]Class, // the lanes of each parameter that is not invariant
	step_match:        int,
	step_arm:          int,
	step_to:           Class,
	memo:              map[Class]Class,
	busy:              map[Class]bool,
}

// lift: c in each lane: each of its computations that has one. In lanes of w bits,
// a lane holds c modulo 2ʷ — ℤ → ℤ/2ʷ is a homomorphism of rings, and of the
// bits —: c itself where it is exact, what w bits hold; where an operation of
// the ring or of the bits reads it, its residue is enough.
lift :: proc(t: ^Lift, c: Class, exact := true) -> (Class, bool) {
	g := t.g
	c := find(g, c)
	// where a turn goes on, each lane is a point of the orbit, and what holds there
	// holds in each lane; at the head of the last turn, the lanes are past it
	r, defined := g.scope[c].?
	stepping := defined && inside(g, r, Region{.Arm, t.step_match, t.step_arm})
	b := g.facts[c].bounds
	if !stepping && !invariant(g, c, t.from) {
		spread := i128(t.lanes - 1) * i128(t.delta)
		b = {b.lo + min(spread, 0), b.hi + max(spread, 0)}
	}
	held := t.bits == 0 || fits(b, t.bits)
	if exact && !held do return NO_CLASS, false
	if x, done := t.memo[c]; done do return x, true
	if invariant(g, c, t.from) {
		t.memo[c] = splat(g, c, t.lanes, t.bits)
		return t.memo[c], true
	}
	if t.busy[c] || c >= Class(len(g.members)) do return NO_CLASS, false
	t.busy[c] = true
	out := NO_CLASS
	for id in g.members[c] {
		n := g.nodes[id] // a copy: what adds a node moves the nodes
		x := lift_node(t, n, exact) or_continue
		out = out == NO_CLASS ? x : merge(g, out, x)
	}
	t.busy[c] = false
	if out == NO_CLASS do return NO_CLASS, false
	if stepping && held do g.facts[find(g, out)].bounds = code.meet(g.facts[find(g, out)].bounds, g.facts[c].bounds)
	t.memo[c] = find(g, out)
	return t.memo[c], true
}

lift_node :: proc(t: ^Lift, n: Node, exact: bool) -> (out: Class, ok: bool) {
	g := t.g
	#partial switch n.kind {
	case .Param:
		if n.owner != t.from do return NO_CLASS, false
		if x, is := t.vectors[n.index]; is do return x, true
		if init, is := t.invariants[n.index]; is do return splat(g, init, t.lanes, t.bits), true
	case .Arm:
		if n.owner == t.step_match && n.index == t.step_arm do return t.step_to, true
	case .Narrow:
		x := lift(t, n.args[0], exact) or_return
		arm := g.nodes[g.members[find(g, n.args[1])][0]]
		token := lift_node(t, arm, true) or_return
		args := make([]Class, 2)
		args[0], args[1] = x, token
		return add(g, Node{kind = .Narrow, args = args}), true
	case .Unary:
		// a negation, a complement: of the residue, the residue
		a := lift(t, n.args[0], false) or_return
		return add(g, Node{kind = .Unary, op = n.op, args = one(a)}), true
	case .Select:
		test := lift(t, n.args[0]) or_return
		yes := lift(t, n.args[1], false) or_return
		no := lift(t, n.args[2], false) or_return
		return add(g, Node{kind = .Select, args = three(test, yes, no)}), true
	case .Binary:
		// an operation of the ring or of the bits reads residues; a count, an order,
		// a quotient read what is
		residue := false
		#partial switch n.op {
		case .Add, .Sub, .Mul, .And, .Or, .Xor, .Shl:
			residue = true
		}
		a := lift(t, n.args[0], !residue) or_return
		shift := n.op == .Shl || n.op == .Shr
		// a shift by what no turn changes: by the same count in each lane
		if shift && invariant(g, n.args[1], t.from) {
			out := add(g, binary(g, n.op, a, n.args[1]))
			// shifted in as zeros, read as unsigned: x >> k & (2⁶⁴⁻ᵏ - 1), whatever
			// the reading of the lanes
			k, constant := g.facts[find(g, n.args[1])].constant.?
			reads := g.facts[find(g, n.args[0])].bounds
			if n.op == .Shr && reads.lo >= 0 && constant && k > 0 && k < 64 && t.bits == 0 {
				out = add(g, binary(g, .And, out, splat(g, add(g, int_node(i128(max(u64) >> uint(k)))), t.lanes, t.bits)))
			}
			return out, true
		}
		b := lift(t, n.args[1], !residue || n.op == .Shl) or_return
		return add(g, binary(g, n.op, a, b)), true
	}
	return NO_CLASS, false
}

// fits: integers within bits bits.
fits :: proc(b: code.Bounds, bits: int) -> bool {
	return b.lo >= -(i128(1) << uint(bits - 1)) && b.hi < i128(1) << uint(bits - 1)
}

// splat: c in each of lanes lanes, of bits bits — 0: 64.
splat :: proc(g: ^Graph, c: Class, lanes: int, bits := 0) -> Class {
	return add(g, Node{kind = .Splat, value = i128(lanes), index = bits, args = one(c)})
}

// Copy: the computations of a turn of the loop from, as those of the loop to: its
// own parameters, its matches, its tail.
Copy :: struct {
	g:        ^Graph,
	from, to: int,
	own:      int,
	matches:  map[int]int,
	memo:     map[Class]Class,
	busy:     map[Class]bool,
}

// copy_loop: a loop that computes what l does, by the same turns, from what its
// node is given — its own parameters only, the tail of its body its one argument.
copy_loop :: proc(g: ^Graph, l: int) -> (r: int, ok: bool) {
	info := g.loops[l]
	r = len(g.loops)
	own := own_params(info)
	copy_info := Loop_Info{parent = info.parent, state = info.state, values = info.values, origin = .Rest}
	for j in 0 ..< own {
		append(&copy_info.params, info.params[j])
		append(&copy_info.carried, nil)
	}
	append(&g.loops, copy_info)
	t := Copy{g = g, from = l, to = r, own = own}
	tail := copied(&t, g.nodes[info.node].args[len(g.nodes[info.node].args) - 1]) or_return
	add(g, Node{kind = .Loop, owner = r, args = one(tail)})
	g.loops[r].node = len(g.nodes) - 1
	return r, true
}

copied :: proc(t: ^Copy, c: Class) -> (Class, bool) {
	g := t.g
	c := find(g, c)
	if x, done := t.memo[c]; done do return x, true
	if invariant(g, c, t.from) do return c, true
	if t.busy[c] || c >= Class(len(g.members)) do return NO_CLASS, false
	t.busy[c] = true
	out := NO_CLASS
	for id in g.members[c] {
		n := g.nodes[id] // a copy: what adds a node moves the nodes
		x := copy_node(t, n) or_continue
		out = out == NO_CLASS ? x : merge(g, out, x)
	}
	t.busy[c] = false
	if out == NO_CLASS do return NO_CLASS, false
	// the same values, at the same points
	g.facts[find(g, out)] = meet(g.facts[find(g, out)], g.facts[c])
	t.memo[c] = find(g, out)
	return t.memo[c], true
}

copy_node :: proc(t: ^Copy, n: Node) -> (c: Class, ok: bool) {
	g := t.g
	out := n
	#partial switch n.kind {
	case .Param:
		if n.owner != t.from || n.index >= t.own do return NO_CLASS, false
		out.owner = t.to
		return add(g, out), true
	case .Arm:
		out.owner = copy_match(t, n.owner)
		return add(g, out), true
	case .Match:
		out.owner = copy_match(t, n.owner)
	case .Again:
		if n.owner != t.from do return NO_CLASS, false
		out.owner = t.to
		out.args = n.args[:t.own]
	case .Exit:
		if n.owner != t.from do return NO_CLASS, false
		out.owner = t.to
	case .Call:
		if !g.prog.funcs[n.index].pure do return NO_CLASS, false
	case .Narrow, .Unary, .Binary, .In, .Get, .Splat, .Lanes, .Reduce, .Select:
	case:
		return NO_CLASS, false
	}
	args := make([]Class, len(out.args))
	for a, k in out.args do args[k] = copied(t, a) or_return
	out.args = args
	return add(g, out), true
}

// copy_match: the match of the copy for a match of the body of from.
copy_match :: proc(t: ^Copy, m: int) -> int {
	if x, done := t.matches[m]; done do return x
	info := t.g.matches[m]
	info.parent = copy_region(t, info.parent)
	append(&t.g.matches, info)
	t.matches[m] = len(t.g.matches) - 1
	return t.matches[m]
}

copy_region :: proc(t: ^Copy, r: Region) -> Region {
	switch r.kind {
	case .Body:
		if r.owner == t.from do return Region{.Body, t.to, 0}
	case .Arm:
		if inside(t.g, r, Region{.Body, t.from, 0}) do return Region{.Arm, copy_match(t, r.owner), r.arm}
	case .Root:
	}
	return r
}
