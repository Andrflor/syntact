package code_mir

import code ".."
import "core:slice"

// THE PLACE OF EACH REGISTER
//
// Two registers interfere when one is written where the other lives on: they need
// two places. Where each lives is the dataflow of liveness, backward to a fixed
// point; an instruction reads before it writes, so that what it writes may take
// the register of what it last reads, and a copy's destination does not interfere
// with its source, which holds the same value. Over this graph, the registers are
// coloured by the registers of the machine (Chaitin, Briggs): a copy whose two
// sides do not interfere is one register, when that leaves the graph colourable
// (Briggs', George's tests); then, one by one, a register with fewer neighbours
// than the colours it may take goes, or else the one whose frame slot would cost
// least — its reads and writes, ten times more for each loop around them, by its
// neighbours —, and they are coloured back in the reverse order, each by a colour
// no neighbour took: that of a register it is copied from or to, or computed from
// or in, or of the argument a call takes it as, when free; else one such a
// register not coloured yet may take after it; a slot of the frame when none is.
// A register living across a call takes only a register the call keeps. Floats
// and vectors have registers of their own, none of which a call keeps: across a
// call, they are in the frame, a slot for each lane.

// Target: the registers of a machine the colouring gives, by their number: those
// a call keeps, and those it does not; those a call takes its integers in, in
// order; and the registers of floats and vectors, which no call keeps.
Target :: struct {
	kept:      []int,
	spent:     []int,
	arguments: []int,
	wide:      []int,
}

// Place: where a register is: a register of the machine — of integers, or of
// floats and vectors —, or slots of the frame, one for each lane.
Place :: union {
	Machine_Reg,
	Wide_Reg,
	Slot,
}

Machine_Reg :: distinct int
Wide_Reg :: distinct int
Slot :: distinct int

Allocation :: struct {
	places: []Place, // per register; nil for one never written nor read
	used:   []int, // the registers the calls keep that the function uses
	slots:  int,
}

// uses: the registers an instruction reads.
uses :: proc(inst: Inst, out: ^[dynamic]Reg) {
	operand :: proc(o: Operand, out: ^[dynamic]Reg) {if r, is_reg := o.(Reg); is_reg do append(out, r)}
	switch i in inst {
	case Copy:
		operand(i.src, out)
	case Real, Text, Input:
	case Unary:
		append(out, i.a)
	case Binary:
		append(out, i.a)
		operand(i.b, out)
	case Compare:
		append(out, i.a)
		operand(i.b, out)
	case Foreign:
		for a in i.args do operand(a, out)
	case Memory:
		append(out, i.a)
		operand(i.b, out)
	case Call:
		for a in i.args do operand(a, out)
	case Splat:
		append(out, i.a)
	case Reduce:
		append(out, i.a)
	case Select:
		append(out, i.a)
		operand(i.b, out)
		operand(i.yes, out)
		operand(i.no, out)
	case Lanes:
	}
}

// writes: the registers an instruction writes.
writes :: proc(inst: Inst, out: ^[dynamic]Reg) {
	switch i in inst {
	case Copy:
		append(out, i.dst)
	case Real:
		append(out, i.dst)
	case Text:
		append(out, i.dst)
	case Input:
		append(out, i.dst)
	case Unary:
		append(out, i.dst)
	case Binary:
		append(out, i.dst)
	case Compare:
		append(out, i.dst)
	case Foreign:
		if i.dst != NO_REG do append(out, i.dst)
	case Memory:
		if i.dst != NO_REG do append(out, i.dst)
	case Call:
		for x in i.dst do if x != NO_REG do append(out, x)
	case Splat:
		append(out, i.dst)
	case Lanes:
		append(out, i.dst)
	case Reduce:
		append(out, i.dst)
	case Select:
		append(out, i.dst)
	}
}

is_call :: proc(inst: Inst) -> bool {
	#partial switch _ in inst {
	case Foreign, Call:
		return true
	}
	return false
}

end_uses :: proc(t: Terminator, out: ^[dynamic]Reg) {
	switch e in t {
	case Jump:
	case Branch:
		append(out, e.a)
		if r, is_reg := e.b.(Reg); is_reg do append(out, r)
	case Return:
		append(out, ..e.values)
	}
}

successors :: proc(t: Terminator) -> []Block_Id {
	switch e in t {
	case Jump:
		return slice.clone([]Block_Id{e.to})
	case Branch:
		return slice.clone([]Block_Id{e.yes, e.no})
	case Return:
	}
	return nil
}

// allocate: the place of each register of f, on the target.
allocate :: proc(f: ^Func, target: Target) -> Allocation {
	n := len(f.kinds)
	live_out := liveness(f)
	depth := loop_depths(f)
	g := Interference {
		edges = make([]u64, (n * n + 63) / 64),
		adjacent = make([][dynamic]Reg, n),
		seen = make([]int, n),
		n = n,
	}
	cost := make([]f64, n)
	present := make([]bool, n)
	crosses := make([]bool, n)
	copies := make([][dynamic]Reg, n) // the registers each is copied from or to
	hints := make([][dynamic]Reg, n) // and those an operation computes it from or in
	argument := make([]int, n)
	for &a in argument do a = -1
	same_bank :: proc(f: ^Func, a, b: Reg) -> bool {return wide(f.kinds[a]) == wide(f.kinds[b])}
	regs := make([dynamic]Reg)
	defs := make([dynamic]Reg)
	for b, id in f.blocks {
		weight := 1.0
		for _ in 0 ..< min(depth[id], 6) do weight *= 10
		live := slice.clone(live_out[id])
		clear(&regs)
		end_uses(b.end, &regs)
		for r in regs {
			live[r] = true
			present[r] = true
			cost[r] += weight
		}
		#reverse for inst in b.insts {
			clear(&defs)
			writes(inst, &defs)
			source := NO_REG
			#partial switch i in inst {
			case Copy:
				if src, from_reg := i.src.(Reg); from_reg {
					source = src
					if same_bank(f, i.dst, src) {
						append(&copies[i.dst], src)
						append(&copies[src], i.dst)
					}
				}
			case Unary:
				hinted(f, hints, i.dst, i.a)
			case Binary:
				// the machine computes in the register of the first operand; of either,
				// when the operation commutes
				hinted(f, hints, i.dst, i.a)
				if b, is_reg := i.b.(Reg); is_reg && commutes(i.op) do hinted(f, hints, i.dst, b)
			case Select:
				if no, is_reg := i.no.(Reg); is_reg do hinted(f, hints, i.dst, no)
			}
			if is_call(inst) do for r in 0 ..< n do if live[r] && !slice.contains(defs[:], Reg(r)) do crosses[r] = true
			for d, k in defs {
				for r in 0 ..< n do if live[r] && Reg(r) != d && Reg(r) != source && same_bank(f, d, Reg(r)) do interfere(&g, d, Reg(r))
				for e in defs[k + 1:] do if same_bank(f, d, e) do interfere(&g, d, e)
			}
			for d in defs {
				live[d] = false
				present[d] = true
				cost[d] += weight
			}
			clear(&regs)
			uses(inst, &regs)
			for r in regs {
				live[r] = true
				present[r] = true
				cost[r] += weight
			}
			// an integer a call takes, hinted to the register it takes it in
			args: []Operand
			#partial switch i in inst {
			case Foreign:
				args = i.args
			case Call:
				args = i.args
			}
			k := 0
			for a in args {
				r, is_reg := a.(Reg)
				if is_reg && f.kinds[r].machine == .Real do continue
				if is_reg && k < len(target.arguments) && argument[r] < 0 do argument[r] = target.arguments[k]
				k += 1
			}
		}
		if id == 0 {
			// the parameters, and what lives into the entry, are all there at once
			for i in 0 ..< len(f.source.params) do if present[i] do live[i] = true
			for r in 0 ..< n do if live[r] do for q in r + 1 ..< n do if live[q] && same_bank(f, Reg(r), Reg(q)) do interfere(&g, Reg(r), Reg(q))
		}
	}
	// the colours each register may take
	colours :: proc(f: ^Func, target: Target, r: Reg, crosses: bool) -> int {
		if wide(f.kinds[r]) do return crosses ? 0 : len(target.wide)
		return crosses ? len(target.kept) : len(target.kept) + len(target.spent)
	}
	// coalescing: a copy's two sides, one register, when they do not interfere and
	// the neighbours of the two with as many neighbours as colours are fewer than
	// the colours (Briggs), or each neighbour of one is a neighbour of the other or
	// has fewer neighbours than colours (George)
	group := make([]Reg, n)
	for &x, i in group do x = Reg(i)
	for changed := true; changed; {
		changed = false
		for a in 0 ..< n do for p in copies[a] {
			x, y := find_group(group, Reg(a)), find_group(group, p)
			if x == y || connected(&g, x, y) do continue
			k := colours(f, target, x, crosses[x] || crosses[y])
			if k == 0 do continue
			significant := 0
			counted := make(map[Reg]bool)
			defer delete(counted)
			for side in ([]Reg{x, y}) do for q in g.adjacent[side] {
				z := find_group(group, q)
				if z == x || z == y || counted[z] do continue
				counted[z] = true
				if neighbours(&g, group, nil, z) >= colours(f, target, z, crosses[z]) do significant += 1
			}
			if significant >= k {
				george :: proc(g: ^Interference, f: ^Func, target: Target, group: []Reg, crosses: []bool, x, y: Reg) -> bool {
					if crosses[y] && !crosses[x] do return false
					for q in g.adjacent[y] {
						z := find_group(group, q)
						if z == x || z == y || connected(g, z, x) do continue
						if neighbours(g, group, nil, z) >= colours(f, target, z, crosses[z]) do return false
					}
					return true
				}
				if george(&g, f, target, group, crosses, y, x) do x, y = y, x
				else if !george(&g, f, target, group, crosses, x, y) do continue
			}
			// y into x
			group[y] = x
			crosses[x] ||= crosses[y]
			cost[x] += cost[y]
			present[x] ||= present[y]
			for q in g.adjacent[y] do interfere(&g, x, find_group(group, q))
			changed = true
		}
	}
	// simplify: a register with fewer neighbours left than its colours goes; when
	// none has, the one whose slot costs least for its neighbours
	removed := make([]bool, n)
	stack := make([dynamic]Reg)
	left := make([dynamic]Reg)
	for r in 0 ..< n do if present[r] && find_group(group, Reg(r)) == Reg(r) do append(&left, Reg(r))
	for len(left) > 0 {
		chosen := -1
		for r, j in left do if neighbours(&g, group, removed, r) < colours(f, target, r, crosses[r]) {
			chosen = j
			break
		}
		if chosen < 0 {
			best := max(f64)
			for r, j in left {
				c := cost[r] / f64(neighbours(&g, group, removed, r) + 1)
				if c < best {
					best = c
					chosen = j
				}
			}
		}
		r := left[chosen]
		unordered_remove(&left, chosen)
		removed[r] = true
		append(&stack, r)
	}
	// select: back in the reverse order, each a colour no neighbour has
	out := Allocation{places = make([]Place, n)}
	colour := make([]int, n)
	for &c in colour do c = -1
	used := make(map[int]bool)
	members := make([][dynamic]Reg, n)
	for r in 0 ..< n do append(&members[find_group(group, Reg(r))], Reg(r))
	#reverse for r in stack {
		is_wide := wide(f.kinds[r])
		taken: [64]bool
		for q in g.adjacent[r] {
			z := find_group(group, q)
			if z != r && colour[z] >= 0 do taken[colour[z]] = true
		}
		allowed := make([dynamic]int)
		defer delete(allowed)
		if is_wide {
			if !crosses[r] do append(&allowed, ..target.wide)
		} else {
			if !crosses[r] do append(&allowed, ..target.spent)
			append(&allowed, ..target.kept)
		}
		// the colours a copy or a call would have it in, first
		preferred := make([dynamic]int)
		defer delete(preferred)
		for m in members[r] {
			for p in copies[m] do if c := colour[find_group(group, p)]; c >= 0 do append(&preferred, c)
			for p in hints[m] do if c := colour[find_group(group, p)]; c >= 0 do append(&preferred, c)
			if argument[m] >= 0 do append(&preferred, argument[m])
		}
		chosen := -1
		for c in preferred do if !taken[c] && slice.contains(allowed[:], c) {
			chosen = c
			break
		}
		// else one the registers it is copied to or computed in, not coloured yet,
		// may take after it
		if chosen < 0 {
			theirs: [64]bool
			for m in members[r] do for list in ([][dynamic]Reg{copies[m], hints[m]}) do for p in list {
				z := find_group(group, p)
				if z == r || colour[z] >= 0 do continue
				for q in g.adjacent[z] do if c := colour[find_group(group, q)]; c >= 0 do theirs[c] = true
			}
			for c in allowed do if !taken[c] && !theirs[c] {
				chosen = c
				break
			}
		}
		if chosen < 0 do for c in allowed do if !taken[c] {
			chosen = c
			break
		}
		if chosen < 0 {
			out.places[r] = Slot(out.slots)
			out.slots += max(f.kinds[r].lanes, 1)
		} else {
			colour[r] = chosen
			out.places[r] = is_wide ? Place(Wide_Reg(chosen)) : Place(Machine_Reg(chosen))
			if !is_wide && slice.contains(target.kept, chosen) do used[chosen] = true
		}
	}
	for r in 0 ..< n do if present[r] do out.places[r] = out.places[find_group(group, Reg(r))]
	kept := make([dynamic]int)
	for x in target.kept do if used[x] do append(&kept, x)
	out.used = kept[:]
	return out
}

// hinted: a and b are better in one register, when it is free.
hinted :: proc(f: ^Func, hints: [][dynamic]Reg, a, b: Reg) {
	if wide(f.kinds[a]) != wide(f.kinds[b]) do return
	append(&hints[a], b)
	append(&hints[b], a)
}

// commutes: a op b = b op a.
commutes :: proc(op: code.Op) -> bool {
	#partial switch op {
	case .Add, .Mul, .And, .Or, .Xor:
		return true
	}
	return false
}

// Interference: which registers interfere, as a matrix of bits, and the
// neighbours of each.
Interference :: struct {
	edges:    []u64,
	adjacent: [][dynamic]Reg,
	seen:     []int, // a stamp per register, to count each group once
	stamp:    int,
	n:        int,
}

interfere :: proc(g: ^Interference, a, b: Reg) {
	if a == b || connected(g, a, b) do return
	for e in ([][2]Reg{{a, b}, {b, a}}) {
		k := int(e[0]) * g.n + int(e[1])
		g.edges[k / 64] |= 1 << uint(k % 64)
	}
	append(&g.adjacent[a], b)
	append(&g.adjacent[b], a)
}

connected :: proc(g: ^Interference, a, b: Reg) -> bool {
	k := int(a) * g.n + int(b)
	return g.edges[k / 64] & (1 << uint(k % 64)) != 0
}

// neighbours: the groups next to r, each once, but those removed.
neighbours :: proc(g: ^Interference, group: []Reg, removed: []bool, r: Reg) -> int {
	g.stamp += 1
	count := 0
	for q in g.adjacent[r] {
		z := find_group(group, q)
		if z == r || g.seen[z] == g.stamp || removed != nil && removed[z] do continue
		g.seen[z] = g.stamp
		count += 1
	}
	return count
}

// find_group: the register a register is one with, by coalescing.
find_group :: proc(group: []Reg, r: Reg) -> Reg {
	r := r
	for group[r] != r do r = group[r]
	return r
}

// liveness: the registers live out of each block, backward to a fixed point.
liveness :: proc(f: ^Func) -> [][]bool {
	n := len(f.kinds)
	blocks := len(f.blocks)
	live_in := make([][]bool, blocks)
	live_out := make([][]bool, blocks)
	for i in 0 ..< blocks {
		live_in[i] = make([]bool, n)
		live_out[i] = make([]bool, n)
	}
	read := make([dynamic]Reg)
	for changed := true; changed; {
		changed = false
		#reverse for b, i in f.blocks {
			for s in successors(b.end) do for r in 0 ..< n do if live_in[s][r] && !live_out[i][r] {
				live_out[i][r] = true
				changed = true
			}
			live := slice.clone(live_out[i])
			defer delete(live)
			clear(&read)
			end_uses(b.end, &read)
			for r in read do live[r] = true
			#reverse for inst in b.insts {
				clear(&read)
				writes(inst, &read)
				for w in read do live[w] = false
				clear(&read)
				uses(inst, &read)
				for r in read do live[r] = true
			}
			for r in 0 ..< n do if live[r] && !live_in[i][r] {
				live_in[i][r] = true
				changed = true
			}
		}
	}
	return live_out
}

// loop_depths: how many loops each block is in: a jump back to a block placed
// before, or to itself, closes a loop of the blocks that reach its source without
// passing through its target.
loop_depths :: proc(f: ^Func) -> []int {
	depth := make([]int, len(f.blocks))
	position := make([]int, len(f.blocks))
	for &p in position do p = -1
	for b, k in f.order do position[b] = k
	preds := make([][dynamic]Block_Id, len(f.blocks))
	for b, id in f.blocks do for s in successors(b.end) do append(&preds[s], Block_Id(id))
	for b, id in f.blocks {
		if position[id] < 0 do continue
		for h in successors(b.end) {
			if position[h] < 0 || position[h] > position[id] do continue
			inside := make([]bool, len(f.blocks))
			defer delete(inside)
			inside[h] = true
			work := make([dynamic]Block_Id)
			defer delete(work)
			append(&work, Block_Id(id))
			for len(work) > 0 {
				x := pop(&work)
				if inside[x] do continue
				inside[x] = true
				for p in preds[x] do append(&work, p)
			}
			for in_loop, x in inside do if in_loop do depth[x] += 1
		}
	}
	return depth
}

// wide: a float, or a vector: in the registers of floats and vectors.
wide :: proc(k: code.Kind) -> bool {
	return k.machine == .Real || k.lanes > 0
}

