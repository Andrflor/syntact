package code

import "core:fmt"

// THE REFERENCE INTERPRETER
//
// Runs the code of a program as the machine will: the instructions in order, a
// branch to its label, each call of a symbol in the order it is written. The
// symbols are given by the caller: what a library would answer.

Datum :: struct {
	int:  i64,
	real: f64,
	text: string,
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

// execute: the function `index` of the program, on its arguments.
execute :: proc(m: ^Machine_State, index: int, args: []Datum) -> (result: Datum, err: string) {
	p := m.p
	f := p.funcs[index]
	if m.depth > 100_000 do return {}, "the calls go too deep"
	m.depth += 1
	defer m.depth -= 1
	regs := make([]Datum, len(f.types))
	defer delete(regs)
	copy(regs, args)
	marks := make(map[Label]int)
	defer delete(marks)
	for inst, i in f.insts do if mark, ok := inst.(Mark); ok do marks[mark.label] = i
	pc := 0
	for pc < len(f.insts) {
		inst := f.insts[pc]
		pc += 1
		switch i in inst {
		case Const:
			regs[i.dst].int = i.value
		case Real_Const:
			regs[i.dst].real = i.value
		case Text_Const:
			regs[i.dst].text = p.texts[i.text]
		case Input:
			if i.slot >= len(m.inputs) do return {}, fmt.tprintf("the input %d is not given", i.slot)
			regs[i.dst].int = m.inputs[i.slot]
		case Unary:
			regs[i.dst] = unary(i.op, f.types[i.a], regs[i.a])
		case Binary:
			d, ok := binary_of(i.op, f.types[i.a], regs[i.a], regs[i.b])
			if !ok do return {}, "a division by 0"
			regs[i.dst] = d
		case Move:
			regs[i.dst] = regs[i.src]
		case Mark:
		case Jump:
			pc = marks[i.label]
		case Branch:
			if regs[i.cond].int == 0 do pc = marks[i.otherwise]
		case Foreign:
			imp := p.imports[i.symbol]
			s, known := m.symbols[imp.symbol]
			if !known do return {}, fmt.tprintf("the symbol %s is not given", imp.symbol)
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
			if failed != "" do return {}, failed
			if i.dst != NONE do regs[i.dst] = d
		case Return:
			if i.value != NONE do result = regs[i.value]
			return result, ""
		}
	}
	return {}, "the code ends without a return"
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
