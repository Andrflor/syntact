package code

import "core:fmt"

// THE REFERENCE INTERPRETER
//
// Runs the code of a program as the machine will: the instructions in order, the
// arm of a match whose cover takes the target, a loop until its body ends without
// an Again, each call of a symbol in the order it is written. The symbols are
// given by the caller: what a library would answer. Each integer written is within
// the bounds the kernel proved of it, or the run fails: a backend relies on them.

Datum :: struct {
	int:   i64,
	real:  f64,
	text:  string,
	ints:  [MAX_LANES]i64, // a vector of integers
	reals: [MAX_LANES]f64, // a vector of floats
}

Symbol :: proc(args: []Datum) -> Datum

// Run: what a run did — its value, and the symbols called, in order.
Run :: struct {
	result: Datum,
	calls:  [dynamic]string,
}

interpret :: proc(p: ^Program, inputs: []i64, symbols: map[string]Symbol) -> (run: Run, err: string) {
	machine := Machine_State{p = p, inputs = inputs, symbols = symbols, run = &run}
	results: []Datum
	results, err = execute(&machine, 0, nil)
	if len(results) > 0 do run.result = results[0]
	return run, err
}

Machine_State :: struct {
	p:       ^Program,
	inputs:  []i64,
	symbols: map[string]Symbol,
	run:     ^Run,
	depth:   int,
	written: [dynamic]Value, // what the instruction run last writes
	memory:  [dynamic]u8, // the arena: an address is 1 + an index of it
}

// Frame: a function running: its values, and the parameters of the loops it is in,
// innermost last.
Frame :: struct {
	f:     ^Func,
	regs:  []Datum,
	loops: [dynamic][]Value,
}

// execute: the function `index` of the program, on its arguments: the values it
// gives.
execute :: proc(m: ^Machine_State, index: int, args: []Datum) -> (results: []Datum, err: string) {
	f := m.p.funcs[index]
	if m.depth > 100_000 do return {}, "the calls go too deep"
	m.depth += 1
	defer m.depth -= 1
	fr := Frame{f = f, regs = make([]Datum, len(f.kinds))}
	defer delete(fr.regs)
	defer delete(fr.loops)
	copy(fr.regs, args)
	again: bool
	again, err = run_body(m, &fr, f.body)
	if err != "" do return {}, err
	if again do return {}, "an Again outside a loop"
	results = make([]Datum, len(f.body.values))
	for x, i in f.body.values do results[i] = fr.regs[x]
	return results, ""
}

// run_body: the instructions of a body, up to its end or an Again, which is then
// true: the parameters of the innermost loop hold their new values.
run_body :: proc(m: ^Machine_State, fr: ^Frame, b: Body) -> (again: bool, err: string) {
	p := m.p
	regs := fr.regs
	for inst in b.insts {
		switch i in inst {
		case Const:
			regs[i.dst].int = word_of(i.value)
		case Real_Const:
			regs[i.dst].real = i.value
		case Text_Const:
			regs[i.dst].text = p.texts[i.text]
		case Input:
			if i.slot >= len(m.inputs) do return false, fmt.tprintf("the input %d is not given", i.slot)
			if !takes(p.inputs[i.slot], Kind{machine = .Int, bounds = I64}, Datum{int = m.inputs[i.slot]}) do return false, fmt.tprintf("the input %d is out of its layout", i.slot)
			regs[i.dst].int = m.inputs[i.slot]
		case Unary:
			kind := fr.f.kinds[i.a]
			for k in 0 ..< max(kind.lanes, 1) do set_lane(&regs[i.dst], kind, k, unary(i.op, kind.machine, lane(regs[i.a], kind, k)))
		case Binary:
			kind := fr.f.kinds[i.a]
			for k in 0 ..< max(kind.lanes, 1) {
				// read as unsigned when one operand is (the word)
				d, ok := binary_of(i.op, kind.machine, lane(regs[i.a], kind, k), lane(regs[i.b], fr.f.kinds[i.b], k), unsigned(kind) || unsigned(fr.f.kinds[i.b]))
				if !ok do return false, "a division by 0"
				set_lane(&regs[i.dst], fr.f.kinds[i.dst], k, d)
			}
		case Splat:
			kind := fr.f.kinds[i.dst]
			for k in 0 ..< kind.lanes do set_lane(&regs[i.dst], kind, k, regs[i.a])
		case Lanes:
			for x, k in i.values do set_lane(&regs[i.dst], fr.f.kinds[i.dst], k, Datum{int = x})
		case Select:
			kind := fr.f.kinds[i.dst]
			for k in 0 ..< max(kind.lanes, 1) {
				taken := lane(regs[i.test], fr.f.kinds[i.test], k).int == 1
				set_lane(&regs[i.dst], kind, k, lane(regs[taken ? i.yes : i.no], kind, k))
			}
		case Reduce:
			kind := fr.f.kinds[i.a]
			out := lane(regs[i.a], kind, 0)
			for k in 1 ..< kind.lanes do out, _ = binary_of(i.op, kind.machine, out, lane(regs[i.a], kind, k))
			regs[i.dst] = out
		case In:
			regs[i.dst].int = takes(i.cover, fr.f.kinds[i.x], regs[i.x]) ? 1 : 0
		case Narrow:
			regs[i.dst] = regs[i.src]
		case Memory:
			if msg := memory(m, i, regs); msg != "" do return false, msg
		case Foreign:
			imp := p.imports[i.symbol]
			s, known := m.symbols[imp.symbol]
			if !known do return false, fmt.tprintf("the symbol %s is not given", imp.symbol)
			given := make([]Datum, len(i.args))
			for a, j in i.args do given[j] = regs[a]
			append(&m.run.calls, imp.symbol)
			d := s(given)
			if i.dst != NONE do regs[i.dst] = d
		case Call:
			given := make([]Datum, len(i.args))
			defer delete(given)
			for a, j in i.args do given[j] = regs[a]
			results, failed := execute(m, i.func, given)
			defer delete(results)
			if failed != "" do return false, failed
			for x, j in i.dst do regs[x] = results[j]
		case Match:
			kind := fr.f.kinds[i.target]
			for arm, n in i.arms {
				if n < len(i.arms) - 1 && !takes(arm.cover, kind, regs[i.target]) do continue
				again, err = run_body(m, fr, arm.body)
				if again || err != "" do return
				assign(regs, i.dst, arm.body.values)
				break
			}
		case Loop:
			assign(regs, i.params, i.init)
			append(&fr.loops, i.params)
			for {
				for x in i.params do if msg := proven(fr, x); msg != "" do return false, msg
				again, err = run_body(m, fr, i.body)
				if err != "" do return
				if !again do break
			}
			pop(&fr.loops)
			assign(regs, i.dst, i.body.values)
		case Again:
			if len(fr.loops) == 0 do return false, "an Again outside a loop"
			assign(regs, fr.loops[len(fr.loops) - 1], i.args)
			return true, ""
		}
		clear(&m.written)
		written(inst, &m.written)
		for x in m.written do if msg := proven(fr, x); msg != "" do return false, msg
	}
	return false, ""
}

// written: the values an instruction writes.
written :: proc(inst: Inst, out: ^[dynamic]Value) {
	switch i in inst {
	case Const:
		append(out, i.dst)
	case Real_Const:
		append(out, i.dst)
	case Text_Const:
		append(out, i.dst)
	case Input:
		append(out, i.dst)
	case Unary:
		append(out, i.dst)
	case Binary:
		append(out, i.dst)
	case In:
		append(out, i.dst)
	case Narrow:
		append(out, i.dst)
	case Splat:
		append(out, i.dst)
	case Lanes:
		append(out, i.dst)
	case Reduce:
		append(out, i.dst)
	case Select:
		append(out, i.dst)
	case Foreign:
		append(out, i.dst)
	case Memory:
		if i.dst != NONE do append(out, i.dst)
	case Call:
		append(out, ..i.dst)
	case Match:
		append(out, ..i.dst)
	case Loop:
		append(out, ..i.dst)
	case Again:
	}
}

// proven: the integer x holds — each lane of a vector — is within the bounds the
// kernel proved of it.
proven :: proc(fr: ^Frame, x: Value) -> string {
	if x == NONE || fr.f.kinds[x].machine != .Int do return ""
	kind := fr.f.kinds[x]
	for k in 0 ..< max(kind.lanes, 1) {
		v := kind.lanes > 0 ? i128(lane(fr.regs[x], kind, k).int) : of_word(fr.regs[x].int, kind)
		if v < kind.bounds.lo || v > kind.bounds.hi do return fmt.tprintf("%s: v%d = %d, out of the bounds proven, %s", fr.f.name, int(x), v, print_cell(kind.bounds))
	}
	return ""
}

// lane: the k-th lane of a vector, as a value; a value itself.
lane :: proc(d: Datum, kind: Kind, k: int) -> Datum {
	if kind.lanes == 0 do return d
	return Datum{int = d.ints[k], real = d.reals[k]}
}

// set_lane: the k-th lane of a vector takes x — an integer, in the bits of the
// lane, where it wraps; a value takes it.
set_lane :: proc(d: ^Datum, kind: Kind, k: int, x: Datum) {
	if kind.lanes == 0 {
		d^ = x
		return
	}
	shift := uint(64 - lane_bits(kind))
	d.ints[k], d.reals[k] = (x.int << shift) >> shift, x.real
}

// assign: dst take the values of src, all read before any is written.
assign :: proc(regs: []Datum, dst, src: []Value) {
	given := make([]Datum, len(src))
	defer delete(given)
	for x, i in src do given[i] = regs[x]
	for x, i in dst do regs[x] = given[i]
}

// takes: the cover takes the value.
takes :: proc(c: Cover, kind: Kind, x: Datum) -> bool {
	inside := false
	if kind.machine == .Real {
		for r in c.reals {
			above := r.lo_open ? x.real > r.lo : x.real >= r.lo
			below := r.hi_open ? x.real < r.hi : x.real <= r.hi
			inside ||= above && below
		}
	} else {
		v := of_word(x.int, kind)
		for b in c.ints do inside ||= b.lo <= v && v <= b.hi
	}
	return inside != c.negated
}

unary :: proc(op: Op, m: Machine, a: Datum) -> Datum {
	#partial switch op {
	case .Neg:
		return m == .Real ? Datum{real = -a.real} : Datum{int = -a.int}
	case .Not:
		return Datum{int = ~a.int}
	case .Round32:
		return Datum{real = f64(f32(a.real))}
	}
	return a
}

binary_of :: proc(op: Op, m: Machine, a, b: Datum, unsigned := false) -> (Datum, bool) {
	flag :: proc(x: bool) -> Datum {return Datum{int = x ? 1 : 0}}
	if m == .Real {
		x, y := a.real, b.real
		#partial switch op {
		case .Add:
			return Datum{real = x + y}, true
		case .Sub:
			return Datum{real = x - y}, true
		case .Mul:
			return Datum{real = x * y}, true
		case .Div:
			return Datum{real = x / y}, true
		case .Pow:
			out := 1.0
			for e := b.int; e > 0; e >>= 1 {
				if e & 1 == 1 do out *= x
				x *= x
			}
			return Datum{real = out}, true
		case .Eq:
			return flag(x == y), true
		case .Ne:
			return flag(x != y), true
		case .Lt:
			return flag(x < y), true
		case .Le:
			return flag(x <= y), true
		case .Gt:
			return flag(x > y), true
		case .Ge:
			return flag(x >= y), true
		}
		return {}, false
	}
	x, y := a.int, b.int
	if unsigned {
		// the words read as unsigned: what their bits read that way gives
		u, v := transmute(u64)x, transmute(u64)y
		#partial switch op {
		case .Div:
			if v == 0 do return {}, false
			return Datum{int = transmute(i64)(u / v)}, true
		case .Mod:
			if v == 0 do return {}, false
			return Datum{int = transmute(i64)(u % v)}, true
		case .Shr:
			return Datum{int = transmute(i64)(u >> v)}, true
		case .Lt:
			return flag(u < v), true
		case .Le:
			return flag(u <= v), true
		case .Gt:
			return flag(u > v), true
		case .Ge:
			return flag(u >= v), true
		}
	}
	switch op {
	case .Add:
		return Datum{int = x + y}, true
	case .Sub:
		return Datum{int = x - y}, true
	case .Mul:
		return Datum{int = x * y}, true
	case .Div:
		if y == 0 do return {}, false
		return Datum{int = x / y}, true
	case .Mod:
		if y == 0 do return {}, false
		return Datum{int = x % y}, true
	case .Mul_High:
		return Datum{int = i64((u128(u64(x)) * u128(u64(y))) >> 64)}, true
	case .Pow:
		out: i64 = 1
		for e := y; e > 0; e >>= 1 {
			if e & 1 == 1 do out *= x
			x *= x
		}
		return Datum{int = out}, true
	case .And:
		return Datum{int = x & y}, true
	case .Or:
		return Datum{int = x | y}, true
	case .Xor:
		return Datum{int = x ~ y}, true
	case .Shl:
		return Datum{int = x << u64(y)}, true
	case .Shr:
		return Datum{int = x >> u64(y)}, true
	case .Eq:
		return flag(x == y), true
	case .Ne:
		return flag(x != y), true
	case .Lt:
		return flag(x < y), true
	case .Le:
		return flag(x <= y), true
	case .Gt:
		return flag(x > y), true
	case .Ge:
		return flag(x >= y), true
	case .Neg, .Round32, .Not:
	}
	return {}, false
}

// memory: an operation on the arena: a reservation at its end, 8-aligned; a load
// or a store within what was reserved, little-endian.
memory :: proc(m: ^Machine_State, i: Memory, regs: []Datum) -> string {
	switch i.op {
	case .Reserve:
		for len(m.memory) % 8 != 0 do append(&m.memory, 0)
		regs[i.dst].int = i64(len(m.memory) + 1)
		resize(&m.memory, len(m.memory) + int(regs[i.a].int))
	case .Free:
		at := int(regs[i.a].int) - 1
		if at < 0 || at > len(m.memory) do return "a free beyond the memory reserved"
		resize(&m.memory, at)
	case .Load, .Store:
		at := int(regs[i.a].int) - 1 + int(i.offset)
		bytes := i.bits / 8
		if at < 0 || at + bytes > len(m.memory) do return fmt.tprintf("a %v outside the memory reserved", i.op)
		if i.op == .Store {
			w := u64(regs[i.b].int)
			for k in 0 ..< bytes do m.memory[at + k] = u8(w >> uint(8 * k))
			return ""
		}
		w: u64
		for k in 0 ..< bytes do w |= u64(m.memory[at + k]) << uint(8 * k)
		if i.signed && i.bits < 64 && w >> uint(i.bits - 1) & 1 == 1 do w |= max(u64) << uint(i.bits)
		regs[i.dst].int = i64(w)
	}
	return ""
}
