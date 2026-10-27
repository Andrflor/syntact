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
	run.result, err = execute(&machine, 0, nil)
	return run, err
}

Machine_State :: struct {
	p:       ^Program,
	inputs:  []i64,
	symbols: map[string]Symbol,
	run:     ^Run,
	depth:   int,
}

// Frame: a function running: its values, and the parameters of the loops it is in,
// innermost last.
Frame :: struct {
	f:     ^Func,
	regs:  []Datum,
	loops: [dynamic][]Value,
}

// execute: the function `index` of the program, on its arguments.
execute :: proc(m: ^Machine_State, index: int, args: []Datum) -> (result: Datum, err: string) {
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
	if f.body.value != NONE do result = fr.regs[f.body.value]
	return result, ""
}

// run_body: the instructions of a body, up to its end or an Again, which is then
// true: the parameters of the innermost loop hold their new values.
run_body :: proc(m: ^Machine_State, fr: ^Frame, b: Body) -> (again: bool, err: string) {
	p := m.p
	regs := fr.regs
	for inst in b.insts {
		switch i in inst {
		case Const:
			regs[i.dst].int = i.value
		case Real_Const:
			regs[i.dst].real = i.value
		case Text_Const:
			regs[i.dst].text = p.texts[i.text]
		case Input:
			if i.slot >= len(m.inputs) do return false, fmt.tprintf("the input %d is not given", i.slot)
			if !takes(p.inputs[i.slot], .Int, Datum{int = m.inputs[i.slot]}) do return false, fmt.tprintf("the input %d is out of its layout", i.slot)
			regs[i.dst].int = m.inputs[i.slot]
		case Unary:
			kind := fr.f.kinds[i.a]
			for k in 0 ..< max(kind.lanes, 1) do set_lane(&regs[i.dst], kind, k, unary(i.op, kind.machine, lane(regs[i.a], kind, k)))
		case Binary:
			kind := fr.f.kinds[i.a]
			for k in 0 ..< max(kind.lanes, 1) {
				d, ok := binary_of(i.op, kind.machine, lane(regs[i.a], kind, k), lane(regs[i.b], fr.f.kinds[i.b], k))
				if !ok do return false, "a division by 0"
				set_lane(&regs[i.dst], fr.f.kinds[i.dst], k, d)
			}
		case Splat:
			kind := fr.f.kinds[i.dst]
			for k in 0 ..< kind.lanes do set_lane(&regs[i.dst], kind, k, regs[i.a])
		case Lanes:
			for x, k in i.values do regs[i.dst].ints[k] = x
		case Reduce:
			kind := fr.f.kinds[i.a]
			out := lane(regs[i.a], kind, 0)
			for k in 1 ..< kind.lanes do out, _ = binary_of(i.op, kind.machine, out, lane(regs[i.a], kind, k))
			regs[i.dst] = out
		case In:
			regs[i.dst].int = takes(i.cover, fr.f.kinds[i.x].machine, regs[i.x]) ? 1 : 0
		case Narrow:
			regs[i.dst] = regs[i.src]
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
			d, failed := execute(m, i.func, given)
			if failed != "" do return false, failed
			if i.dst != NONE do regs[i.dst] = d
		case Match:
			machine := fr.f.kinds[i.target].machine
			for arm, n in i.arms {
				if n < len(i.arms) - 1 && !takes(arm.cover, machine, regs[i.target]) do continue
				again, err = run_body(m, fr, arm.body)
				if again || err != "" do return
				if i.dst != NONE && arm.body.value != NONE do regs[i.dst] = regs[arm.body.value]
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
			if i.dst != NONE do regs[i.dst] = regs[i.body.value]
		case Again:
			if len(fr.loops) == 0 do return false, "an Again outside a loop"
			assign(regs, fr.loops[len(fr.loops) - 1], i.args)
			return true, ""
		}
		if msg := proven(fr, written(inst)); msg != "" do return false, msg
	}
	return false, ""
}

// written: the value an instruction writes; NONE for none.
written :: proc(inst: Inst) -> Value {
	switch i in inst {
	case Const:
		return i.dst
	case Real_Const:
		return i.dst
	case Text_Const:
		return i.dst
	case Input:
		return i.dst
	case Unary:
		return i.dst
	case Binary:
		return i.dst
	case In:
		return i.dst
	case Narrow:
		return i.dst
	case Splat:
		return i.dst
	case Lanes:
		return i.dst
	case Reduce:
		return i.dst
	case Foreign:
		return i.dst
	case Call:
		return i.dst
	case Match:
		return i.dst
	case Loop:
		return i.dst
	case Again:
	}
	return NONE
}

// proven: the integer x holds — each lane of a vector — is within the bounds the
// kernel proved of it.
proven :: proc(fr: ^Frame, x: Value) -> string {
	if x == NONE || fr.f.kinds[x].machine != .Int do return ""
	kind := fr.f.kinds[x]
	for k in 0 ..< max(kind.lanes, 1) {
		v := i128(lane(fr.regs[x], kind, k).int)
		if v < kind.bounds.lo || v > kind.bounds.hi do return fmt.tprintf("%s: v%d = %d, out of the bounds proven, %s", fr.f.name, int(x), v, print_cell(kind.bounds))
	}
	return ""
}

// lane: the k-th lane of a vector, as a value; a value itself.
lane :: proc(d: Datum, kind: Kind, k: int) -> Datum {
	if kind.lanes == 0 do return d
	return Datum{int = d.ints[k], real = d.reals[k]}
}

set_lane :: proc(d: ^Datum, kind: Kind, k: int, x: Datum) {
	if kind.lanes == 0 {
		d^ = x
		return
	}
	d.ints[k], d.reals[k] = x.int, x.real
}

// assign: dst take the values of src, all read before any is written.
assign :: proc(regs: []Datum, dst, src: []Value) {
	given := make([]Datum, len(src))
	defer delete(given)
	for x, i in src do given[i] = regs[x]
	for x, i in dst do regs[x] = given[i]
}

// takes: the cover takes the value.
takes :: proc(c: Cover, m: Machine, x: Datum) -> bool {
	inside := false
	if m == .Real {
		for r in c.reals {
			above := r.lo_open ? x.real > r.lo : x.real >= r.lo
			below := r.hi_open ? x.real < r.hi : x.real <= r.hi
			inside ||= above && below
		}
	} else {
		for b in c.ints do inside ||= b.lo <= i128(x.int) && i128(x.int) <= b.hi
	}
	return inside != c.negated
}

unary :: proc(op: Op, m: Machine, a: Datum) -> Datum {
	#partial switch op {
	case .Neg:
		return m == .Real ? Datum{real = -a.real} : Datum{int = -a.int}
	case .Not:
		return Datum{int = ~a.int}
	}
	return a
}

binary_of :: proc(op: Op, m: Machine, a, b: Datum) -> (Datum, bool) {
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
	case .Neg, .Not:
	}
	return {}, false
}
