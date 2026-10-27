package code_mir

import code ".."
import "core:slice"

// THE PLACE OF EACH REGISTER
//
// The instructions are numbered in the order the blocks are laid out: an
// instruction reads at its position and writes just after, so that what it writes
// may take the register of what it last reads. A register lives from where it is
// first written to where it is last read, across the blocks it is live into or
// out of — by the dataflow of liveness, to a fixed point. Over these ranges, a
// linear scan gives each register a register of the machine: one the calls keep
// when the range spans a call, any free one otherwise — the register of what it
// is copied from first, so that the copy goes —, or a slot of the frame when none
// is left: the range that ends last is the one that goes to the frame. Floats and
// vectors have registers of their own, none of which a call keeps: across a call,
// they are in the frame, a slot for each lane.

// Target: the registers of a machine the scan gives, by their number: those a call
// keeps, and those it does not; those a call takes its integers in, in order; and
// the registers of floats and vectors, which no call keeps.
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

Range :: struct {
	reg:        Reg,
	start, end: int,
	spans_call: bool,
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
	case Call:
		for a in i.args do operand(a, out)
	case Splat:
		append(out, i.a)
	case Reduce:
		append(out, i.a)
	case Lanes:
	}
}

// writes: the register an instruction writes; NO_REG for none.
writes :: proc(inst: Inst) -> Reg {
	switch i in inst {
	case Copy:
		return i.dst
	case Real:
		return i.dst
	case Text:
		return i.dst
	case Input:
		return i.dst
	case Unary:
		return i.dst
	case Binary:
		return i.dst
	case Compare:
		return i.dst
	case Foreign:
		return i.dst
	case Call:
		return i.dst
	case Splat:
		return i.dst
	case Lanes:
		return i.dst
	case Reduce:
		return i.dst
	}
	return NO_REG
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
		if e.value != NO_REG do append(out, e.value)
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
	blocks := len(f.blocks)
	// the positions, in the order the blocks are placed: two per instruction, the
	// terminator last
	first := make([]int, blocks)
	last := make([]int, blocks)
	position := 0
	calls := make([dynamic]int)
	for i in f.order {
		first[i] = position
		for inst in f.blocks[i].insts {
			if is_call(inst) do append(&calls, position)
			position += 2
		}
		last[i] = position
		position += 2
	}
	// liveness, backward to a fixed point
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
			clear(&read)
			end_uses(b.end, &read)
			for r in read do live[r] = true
			#reverse for inst in b.insts {
				if w := writes(inst); w != NO_REG do live[w] = false
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
	// the range of each register: the hull of where it is written, read or live
	ranges := make([]Range, n)
	for &r, i in ranges do r = Range{Reg(i), max(int), -1, false}
	cover :: proc(r: ^Range, p: int) {
		r.start = min(r.start, p)
		r.end = max(r.end, p)
	}
	for i in 0 ..< len(f.source.params) do cover(&ranges[i], -1)
	for i in f.order {
		b := f.blocks[i]
		p := first[i]
		for r in 0 ..< n {
			if live_in[i][r] do cover(&ranges[r], first[i])
			if live_out[i][r] do cover(&ranges[r], last[i])
		}
		for inst in b.insts {
			clear(&read)
			uses(inst, &read)
			for r in read do cover(&ranges[r], p)
			if w := writes(inst); w != NO_REG do cover(&ranges[w], p + 1)
			p += 2
		}
		clear(&read)
		end_uses(b.end, &read)
		for r in read do cover(&ranges[r], last[i])
	}
	for &r in ranges do for c in calls do r.spans_call ||= r.start <= c && c < r.end
	// a copy's destination is hinted to its source's register; an integer a call
	// takes, to the register it takes it in
	hint := make([]Reg, n)
	for &h in hint do h = NO_REG
	argument := make([]int, n)
	for &a in argument do a = -1
	for b in f.blocks do for inst in b.insts {
		args: []Operand
		#partial switch i in inst {
		case Copy:
			if src, is_reg := i.src.(Reg); is_reg do hint[i.dst] = src
		case Foreign:
			args = i.args
		case Call:
			args = i.args
		}
		k := 0
		for a in args {
			r, is_reg := a.(Reg)
			if !is_reg {
				k += 1
				continue
			}
			if f.kinds[r].machine == .Real do continue
			if k < len(target.arguments) && argument[r] < 0 do argument[r] = target.arguments[k]
			k += 1
		}
	}
	// the scan, in the order the ranges start, each bank on its own: the integers;
	// the floats and the vectors, in registers no call keeps
	order := make([dynamic]Range)
	for r in ranges do if r.end >= 0 do append(&order, r)
	slice.sort_by(order[:], proc(a, b: Range) -> bool {return a.start < b.start})
	out := Allocation{places = make([]Place, n)}
	banks: [2]Bank
	for &b in banks do b.free = make(map[int]bool)
	for x in target.kept do banks[0].free[x] = true
	for x in target.spent do banks[0].free[x] = true
	for x in target.wide do banks[1].free[x] = true
	number := make([]int, n) // the register of the machine each register is in
	used := make(map[int]bool)
	to_frame :: proc(out: ^Allocation, f: ^Func, r: Reg) {
		out.places[r] = Slot(out.slots)
		out.slots += max(f.kinds[r].lanes, 1)
	}
	for r in order {
		// the ranges that ended free their registers
		for &b in banks {
			for j := 0; j < len(b.active); {
				if b.active[j].end < r.start {
					b.free[number[b.active[j].reg]] = true
					ordered_remove(&b.active, j)
				} else do j += 1
			}
		}
		is_wide := wide(f.kinds[r.reg])
		bank := &banks[is_wide ? 1 : 0]
		// what a register of the bank may hold this range
		fits :: proc(target: Target, r: Range, is_wide: bool, x: int) -> bool {
			return is_wide || !r.spans_call || slice.contains(target.kept, x)
		}
		if is_wide && r.spans_call {
			to_frame(&out, f, r.reg)
			continue
		}
		chosen := -1
		if h := hint[r.reg]; h != NO_REG && wide(f.kinds[h]) == is_wide && in_register(out.places[h]) {
			if x := number[h]; bank.free[x] && fits(target, r, is_wide, x) do chosen = x
		}
		if is_wide {
			if chosen < 0 do chosen = first_free(target.wide, bank.free)
		} else {
			if a := argument[r.reg]; chosen < 0 && a >= 0 && bank.free[a] && !r.spans_call do chosen = a
			if chosen < 0 && !r.spans_call do chosen = first_free(target.spent, bank.free)
			if chosen < 0 do chosen = first_free(target.kept, bank.free)
		}
		if chosen < 0 {
			// the range that ends last, among those whose register fits, goes to the frame
			victim := -1
			for a, j in bank.active {
				if fits(target, r, is_wide, number[a.reg]) && a.end > r.end && (victim < 0 || a.end > bank.active[victim].end) do victim = j
			}
			if victim < 0 {
				to_frame(&out, f, r.reg)
				continue
			}
			chosen = number[bank.active[victim].reg]
			to_frame(&out, f, bank.active[victim].reg)
			ordered_remove(&bank.active, victim)
		}
		bank.free[chosen] = false
		number[r.reg] = chosen
		out.places[r.reg] = is_wide ? Place(Wide_Reg(chosen)) : Place(Machine_Reg(chosen))
		if !is_wide && slice.contains(target.kept, chosen) do used[chosen] = true
		append(&bank.active, r)
	}
	kept := make([dynamic]int)
	for x in target.kept do if used[x] do append(&kept, x)
	out.used = kept[:]
	return out
}

// Bank: the registers of one kind the scan gives: those free, and the ranges in
// them.
Bank :: struct {
	free:   map[int]bool,
	active: [dynamic]Range,
}

// wide: a float, or a vector: in the registers of floats and vectors.
wide :: proc(k: code.Kind) -> bool {
	return k.machine == .Real || k.lanes > 0
}

in_register :: proc(p: Place) -> bool {
	#partial switch _ in p {
	case Machine_Reg, Wide_Reg:
		return true
	}
	return false
}

first_free :: proc(regs: []int, free: map[int]bool) -> int {
	for x in regs do if free[x] do return x
	return -1
}
