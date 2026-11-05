package code_calc

import code ".."

// THE CELLS OF MEMORY
//
// A reservation is cells no other shares: what reads them reads them through an
// address computed from its own, base + offset. Of each value, from one base, the
// algebra knows whether it is an integer, an address from the base, or either, and
// its residue r modulo m, m dividing 64: ℤ → ℤ/m is a homomorphism of rings — a
// word wraps modulo 2⁶⁴, which m divides —, so + - and a product by a constant keep
// it; where two computations meet — a parameter of a loop, the arms of a match —
// the residue is their join, m the gcd of both moduli and of the difference of the
// residues. The base is a reservation, a parameter of the function, or each value
// that may be an address: what a reservation, a load, a symbol, a function with
// effects gives, an argument.
//
// What reads the cells of a base: each load through it whose value is used, at its
// residue plus its offset, modulo m; each function it is given to, by its
// footprint — what that function reads through its parameter, to a fixed point
// over the functions —; and every cell where the address escapes: to a symbol,
// into memory, out of the function, or at a residue not known.
//
//   store(s, a + k, v) = s        a reserved here, no reader of its cells reads
//                                 a cell a + k is
//
//   M(F(s, x)) = F(M(s), x)       M an effect on memory only, F a call of a symbol
//                                 given no address, M reading nothing F gives: what
//                                 the symbol does it does to the world, what the
//                                 memory holds it holds; they commute

// Holds: what a value is: none known yet, an integer, an address from the base,
// or either.
Holds :: enum u8 {
	None,
	Value,
	Address,
	Any,
}

// Residue: what a class holds, and its residue r modulo m, m dividing 64.
Residue :: struct {
	holds: Holds,
	m, r:  u64,
}

// Footprint: the cells read through a base: the residues modulo m of each byte
// read, as the bits of mask; whether a function gives the base back.
Footprint :: struct {
	m, mask:  u64,
	returned: bool,
}

NOTHING :: Footprint{m = 64}
EVERYTHING :: Footprint{m = 1, mask = 1}

INTEGER :: Residue{.Value, 1, 0}
EITHER :: Residue{.Any, 1, 0}
BASE :: Residue{.Address, 64, 0}

// Cells: of one base, the residue of each class and what reads its cells.
Cells :: struct {
	residues: []Residue,
	reads:    Footprint,
}

gcd :: proc(a, b: u64) -> u64 {
	a, b := a, b
	for b != 0 do a, b = b, a % b
	return a
}

// joined: what holds of a value one of a or b computes.
joined :: proc(a, b: Residue) -> Residue {
	if a.holds == .None do return b
	if b.holds == .None do return a
	m := gcd(a.m, b.m)
	m = gcd(m, (a.r % m + m - b.r % m) % m)
	return Residue{a.holds == b.holds ? a.holds : .Any, m, a.r % m}
}

// summed_residue: a + b, or a - b: an address and an integer, an address; two
// addresses apart, an integer.
summed_residue :: proc(a, b: Residue, minus: bool) -> Residue {
	if a.holds == .None || b.holds == .None do return {}
	m := gcd(a.m, b.m)
	r := minus ? (a.r % m + m - b.r % m) % m : (a.r + b.r) % m
	switch {
	case a.holds == .Value && b.holds == .Value:
		return Residue{.Value, m, r}
	case a.holds == .Address && b.holds == .Value:
		return Residue{.Address, m, r}
	case !minus && a.holds == .Value && b.holds == .Address:
		return Residue{.Address, m, r}
	case minus && a.holds == .Address && b.holds == .Address:
		return Residue{.Value, m, r}
	}
	return Residue{.Any, m, r}
}

// scaled_residue: a · c, c a constant: of an integer, an integer.
scaled_residue :: proc(a: Residue, c: i128) -> Residue {
	if a.holds == .None do return {}
	if a.holds != .Value do return EITHER
	k := u64(c & 63)
	m := gcd(k * a.m % 64, 64)
	return Residue{.Value, m, k * a.r % m}
}

// Analysis: the residues of a graph from the classes of a base, to a fixed point;
// the ends of each loop.
Analysis :: struct {
	g:        ^Graph,
	base:     []bool,
	residues: []Residue,
	ends:     [][dynamic]int, // per loop: its Again and Exit nodes
}

// cells_of: the residue of each class of g from the base — the classes base holds,
// one base —, and what reads its cells; where results, what the function gives
// back is read too.
cells_of :: proc(g: ^Graph, base: []bool, results := true) -> Cells {
	a := Analysis{g = g, base = base, residues = make([]Residue, len(g.parent)), ends = make([][dynamic]int, len(g.loops))}
	for n, id in g.nodes do if n.kind == .Again || n.kind == .Exit do append(&a.ends[n.owner], id)
	for changed := true; changed; {
		changed = false
		for n, id in g.nodes {
			c := find(g, g.home[id])
			x := base[c] ? BASE : residue_of(&a, n)
			if x.holds == .None do continue
			j := joined(a.residues[c], x)
			if j != a.residues[c] {
				a.residues[c] = j
				changed = true
			}
		}
	}
	return Cells{a.residues, read_by(&a, results)}
}

// residue: of the class c, once the analysis reached it.
residue :: proc(a: ^Analysis, c: Class) -> Residue {
	return a.residues[find(a.g, c)]
}

// residue_of: what the node n holds.
residue_of :: proc(a: ^Analysis, n: Node) -> Residue {
	g := a.g
	#partial switch n.kind {
	case .Int:
		return Residue{.Value, 64, u64(n.value & 63)}
	case .Narrow:
		return residue(a, n.args[0])
	case .Select:
		return joined(residue(a, n.args[1]), residue(a, n.args[2]))
	case .Param:
		info := g.loops[n.owner]
		if n.index >= len(g.nodes[info.node].args) - 1 do return {}
		out := residue(a, g.nodes[info.node].args[n.index])
		for id in a.ends[n.owner] do if e := g.nodes[id]; e.kind == .Again && n.index < len(e.args) do out = joined(out, residue(a, e.args[n.index]))
		return out
	case .Get:
		return residue_of_get(a, n)
	case .Unary:
		x := residue(a, n.args[0])
		if n.op == .Neg && x.holds == .Value do return Residue{.Value, x.m, (x.m - x.r) % x.m}
	case .Binary:
		x, y := residue(a, n.args[0]), residue(a, n.args[1])
		if comparison(n.op) do return INTEGER
		#partial switch n.op {
		case .Add, .Sub:
			return summed_residue(x, y, n.op == .Sub)
		case .Mul:
			if k, known := g.facts[find(g, n.args[1])].constant.?; known do return scaled_residue(x, k)
			if k, known := g.facts[find(g, n.args[0])].constant.?; known do return scaled_residue(y, k)
		case .Shl:
			if k, known := g.facts[find(g, n.args[1])].constant.?; known && k >= 0 && k < 64 do return scaled_residue(x, i128(1) << uint(k))
		}
	case .Splat, .Reduce:
	case:
		return INTEGER
	}
	// an operation on integers: an integer; on an address, either
	for x in n.args {
		h := residue(a, x).holds
		if h == .None do return {}
		if h != .Value do return EITHER
	}
	return INTEGER
}

// residue_of_get: what one of the values a tuple gives holds: what a loop or a
// match gives at its end; what a function gives back of what it is given; an
// integer, else.
residue_of_get :: proc(a: ^Analysis, n: Node) -> Residue {
	g := a.g
	out: Residue
	for id in g.members[find(g, n.args[0])] {
		t := g.nodes[id]
		#partial switch t.kind {
		case .Loop:
			info := g.loops[t.owner]
			if k := n.index - outputs(info); k >= 0 {
				if k >= len(info.finals) do continue
				if p, has := lookup(g, Node{kind = .Param, owner = t.owner, index = info.finals[k]}); has do out = joined(out, residue(a, g.home[p]))
				continue
			}
			for e in a.ends[t.owner] do if x := g.nodes[e]; x.kind == .Exit && n.index < len(x.args) do out = joined(out, residue(a, x.args[n.index]))
		case .Match:
			info := g.matches[t.owner]
			first := info.state ? 2 : 1
			per := info.values + (info.state ? 1 : 0)
			if n.index >= per do continue
			for k in 0 ..< len(info.covers) do out = joined(out, residue(a, t.args[first + k * per + n.index]))
		case .Call:
			first := effectful(g, t) ? 1 : 0
			out = joined(out, INTEGER)
			if n.index < first do continue
			for arg, k in t.args[first:] {
				if residue(a, arg).holds != .Value && footprint(g, t.index, k).returned do out = joined(out, EITHER)
			}
		case:
			out = joined(out, INTEGER)
		}
	}
	return out
}

// footprint: what the function f reads through its parameter k.
footprint :: proc(g: ^Graph, f, k: int) -> Footprint {
	if f >= len(g.footprints) || k >= len(g.footprints[f]) do return EVERYTHING
	return g.footprints[f][k]
}

// read_cells: the bytes from x + offset read.
read_cells :: proc(f: ^Footprint, x: Residue, offset: i64, bytes: int) {
	#partial switch x.holds {
	case .Any:
		f^ = EVERYTHING
	case .Address:
		add_bytes(f, x.m, x.r + u64(offset & 63), bytes)
	}
}

// add_bytes: the bytes r … r + bytes - 1 modulo m, read too.
add_bytes :: proc(f: ^Footprint, m, r: u64, bytes: int) {
	modulus := gcd(f.m, m)
	folded := modulo(f^, modulus)
	for k in 0 ..< u64(bytes) do folded |= 1 << ((r + k) % modulus)
	f.m, f.mask = modulus, folded
}

// modulo: the bytes of f, modulo m, m dividing its modulus.
modulo :: proc(f: Footprint, m: u64) -> (out: u64) {
	for b in 0 ..< f.m do if f.mask >> b & 1 == 1 do out |= 1 << (b % m)
	return
}

// escapes: where x is, or may be, an address, every cell is read.
escapes :: proc(f: ^Footprint, x: Residue) {
	if x.holds == .Address || x.holds == .Any do f^ = EVERYTHING
}

// read_by: what reads the cells of the base: the loads whose value is used, the
// functions an address is given to, and where it escapes; where results, out of
// the function.
read_by :: proc(a: ^Analysis, results: bool) -> (f: Footprint) {
	g := a.g
	f = NOTHING
	used := make([]bool, len(g.parent), context.temp_allocator)
	for n in g.nodes do for x in n.args do used[find(g, x)] = true
	for n, id in g.nodes {
		#partial switch n.kind {
		case .Memory:
			#partial switch code.Memory_Op(n.owner & 15) {
			case .Load:
				// what is loaded and never used is not read
				answer, has := lookup(g, Node{kind = .Get, index = 1, args = one(find(g, g.home[id]))})
				if has && used[find(g, g.home[answer])] do read_cells(&f, residue(a, n.args[1]), i64(n.value), n.index / 8)
			case .Store:
				escapes(&f, residue(a, n.args[2]))
			}
		case .Foreign:
			for x in n.args[1:] do escapes(&f, residue(a, x))
		case .Call:
			first := effectful(g, n) ? 1 : 0
			for arg, k in n.args[first:] {
				x := residue(a, arg)
				if x.holds == .Value || x.holds == .None do continue
				callee := footprint(g, n.index, k)
				m := gcd(x.m, callee.m)
				for b in 0 ..< callee.m do if callee.mask >> b & 1 == 1 do read_cells(&f, Residue{x.holds, m, (x.r + b) % m}, 0, 1)
			}
		}
	}
	for c in g.results {
		x := residue(a, c)
		if results do escapes(&f, x)
		else do f.returned ||= x.holds == .Address || x.holds == .Any
	}
	return
}

// footprints: what each function of p reads through each of its parameters, and
// whether it gives it back: from none, to a fixed point over the functions.
footprints :: proc(p: ^code.Program) -> [][]Footprint {
	out := make([][]Footprint, len(p.funcs))
	for f, i in p.funcs {
		out[i] = make([]Footprint, len(f.params))
		for &x in out[i] do x = NOTHING
	}
	graphs := make([]^Graph, len(p.funcs))
	for f, i in p.funcs {
		graphs[i], _, _ = read(p, f)
		rebuild(graphs[i])
		index_members(graphs[i])
	}
	for changed := true; changed; {
		changed = false
		for g, i in graphs {
			g.footprints = out
			for _, k in p.funcs[i].params {
				arg, has := lookup(g, Node{kind = .Argument, index = k})
				if !has do continue
				base := make([]bool, len(g.parent))
				base[find(g, g.home[arg])] = true
				f := cells_of(g, base, false).reads
				if f != out[i][k] {
					out[i][k] = f
					changed = true
				}
			}
		}
	}
	return out
}

// memory_laws: the laws of the cells, on the graph as the laws last left it.
memory_laws :: proc(g: ^Graph) {
	rebuild(g)
	index_members(g)
	g.scope = scopes(g)
	unread(g)
	commute(g)
}

// unread: a store into a reservation of the function, at cells no reader of it
// reads, is the state it takes.
unread :: proc(g: ^Graph) {
	count := len(g.nodes)
	done := make(map[Class]bool, context.temp_allocator)
	for id in 0 ..< count {
		r := g.nodes[id]
		if r.kind != .Memory || code.Memory_Op(r.owner & 15) != .Reserve do continue
		reservation, has := lookup(g, Node{kind = .Get, index = 1, args = one(g.home[id])})
		if !has do continue
		base := find(g, g.home[reservation])
		if done[base] do continue
		done[base] = true
		in_base := make([]bool, len(g.parent))
		in_base[base] = true
		c := cells_of(g, in_base)
		for sid in 0 ..< count {
			n := g.nodes[sid]
			if n.kind != .Memory || code.Memory_Op(n.owner & 15) != .Store do continue
			x := c.residues[find(g, n.args[1])]
			if x.holds != .Address do continue
			written := NOTHING
			add_bytes(&written, x.m, x.r + u64(n.value & 63), n.index / 8)
			m := gcd(c.reads.m, written.m)
			if modulo(c.reads, m) & modulo(written, m) != 0 do continue
			merge(g, add(g, Node{kind = .Get, index = 0, args = one(g.home[sid])}), n.args[0])
		}
	}
}

// addresses: the classes that may hold an address: what a reservation, a load, a
// symbol, a function with effects gives, an argument.
addresses :: proc(g: ^Graph) -> []bool {
	out := make([]bool, len(g.parent))
	for n, id in g.nodes {
		c := find(g, g.home[id])
		#partial switch n.kind {
		case .Argument:
			out[c] ||= g.func.params[n.index] == .Int
		case .Get:
			for t in g.members[find(g, n.args[0])] {
				x := g.nodes[t]
				out[c] ||= n.index > 0 && (x.kind == .Memory || x.kind == .Foreign || x.kind == .Call && effectful(g, x))
			}
		}
	}
	return out
}

// commute: each effect on memory only after a call of a symbol given no address,
// before it too.
commute :: proc(g: ^Graph) {
	c := cells_of(g, addresses(g))
	count := len(g.nodes)
	for id in 0 ..< count {
		n := g.nodes[id]
		state := -1
		#partial switch n.kind {
		case .Memory:
			state = 0
		case .Loop:
			info := g.loops[n.owner]
			if info.node != id || info.state < 0 || !on_memory(g, n.owner) do continue
			state = info.state
		case:
			continue
		}
		for gid in g.members[find(g, n.args[state])] {
			get := g.nodes[gid]
			if get.kind != .Get || get.index != 0 do continue
			for fid in g.members[find(g, get.args[0])] {
				f := g.nodes[fid]
				if f.kind != .Foreign || !given_no_address(&c, g, f) do continue
				if answer, has := lookup(g, Node{kind = .Get, index = 1, args = one(g.home[fid])}); has {
					if reads_any(g, n, state, find(g, g.home[answer])) do continue
				}
				swap(g, id, state, fid)
			}
		}
	}
}

// given_no_address: each argument of the call of a symbol f is an integer.
given_no_address :: proc(c: ^Cells, g: ^Graph, f: Node) -> bool {
	for x in f.args[1:] do if c.residues[find(g, x)].holds != .Value do return false
	return true
}

// on_memory: each effect of the body of the loop l is on memory.
on_memory :: proc(g: ^Graph, l: int) -> bool {
	for n, id in g.nodes {
		if !effectful(g, n) && n.kind != .Loop do continue
		if !within(g, g.home[id], l) do continue
		if n.kind != .Memory do return false
	}
	return true
}

// reads_any: an argument of n, but its state, reads the class target.
reads_any :: proc(g: ^Graph, n: Node, state: int, target: Class) -> bool {
	seen := make(map[Class]bool, context.temp_allocator)
	for x, k in n.args do if k != state && reaches(g, x, target, &seen) do return true
	return false
}

// reaches: some computation of c reads target.
reaches :: proc(g: ^Graph, c, target: Class, seen: ^map[Class]bool) -> bool {
	c := find(g, c)
	if c == find(g, target) do return true
	if c in seen || c >= Class(len(g.members)) do return false
	seen[c] = true
	for id in g.members[c] do for a in g.nodes[id].args do if reaches(g, a, target, seen) do return true
	return false
}

// swap: the effect m, then the call of a symbol f it took the state of, as f after
// m: m from the state f took, f from the state m gives.
swap :: proc(g: ^Graph, m, state, f: int) {
	n, call := g.nodes[m], g.nodes[f]
	moved: Class
	at, gives: int // the state among what m gives; how many it gives
	if n.kind == .Memory {
		out := n
		out.args = make([]Class, len(n.args))
		copy(out.args, n.args)
		out.args[0] = call.args[0]
		moved = add(g, out)
		at, gives = 0, code.Memory_Op(n.owner & 15) == .Store || code.Memory_Op(n.owner & 15) == .Free ? 1 : 2
	} else {
		info := g.loops[n.owner]
		inits := make([]Class, own_params(info))
		copy(inits, n.args[:len(inits)])
		inits[state] = call.args[0]
		ok: bool
		if moved, ok = loop_from(g, n.owner, inits); !ok do return
		at, gives = info.values, outputs(info) + len(info.finals)
	}
	args := make([]Class, len(call.args))
	copy(args, call.args)
	args[0] = given(g, moved, at)
	later := add(g, Node{kind = .Foreign, index = call.index, args = args})
	merge(g, given(g, g.home[m], at), given(g, later, 0))
	merge(g, given(g, g.home[f], 1), given(g, later, 1))
	for k in 0 ..< gives do if k != at do merge(g, given(g, g.home[m], k), given(g, moved, k))
}

// loop_from: the loop that runs the turns of the loop l from inits: one already
// there, that runs the turns of the same loops of the code from the same starts,
// or a copy of l.
loop_from :: proc(g: ^Graph, l: int, inits: []Class) -> (c: Class, ok: bool) {
	info := g.loops[l]
	for other in g.loops {
		if !same_parts(other.parts, info.parts) || own_params(other) != len(inits) do continue
		args := g.nodes[other.node].args
		same := true
		for x, k in inits do same &&= find(g, x) == find(g, args[k]) && other.params[k] == info.params[k]
		if same do return find(g, g.home[other.node]), true
	}
	r := copy_loop(g, l, .Code) or_return
	g.loops[r].turns = info.turns
	node := &g.nodes[g.loops[r].node]
	args := make([]Class, len(inits) + 1)
	copy(args, inits)
	args[len(inits)] = node.args[0]
	node.args = args
	return find(g, g.home[g.loops[r].node]), true
}

same_parts :: proc(a, b: []int) -> bool {
	if len(a) != len(b) || len(a) == 0 do return false
	for x, k in a do if x != b[k] do return false
	return true
}
