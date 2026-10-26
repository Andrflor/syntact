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
	f := &p.funcs[0]
	regs := make([]Datum, len(f.types))
	marks := make(map[Label]int)
	for inst, i in f.insts do if m, ok := inst.(Mark); ok do marks[m.label] = i
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
			if i.slot >= len(inputs) do return run, fmt.tprintf("the input %d is not given", i.slot)
			regs[i.dst].int = inputs[i.slot]
		case Unary:
			regs[i.dst] = unary(i.op, f.types[i.a], regs[i.a])
		case Binary:
			d, ok := binary_of(i.op, f.types[i.a], regs[i.a], regs[i.b])
			if !ok do return run, "a division by 0"
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
			s, known := symbols[imp.symbol]
			if !known do return run, fmt.tprintf("the symbol %s is not given", imp.symbol)
			args := make([]Datum, len(i.args))
			for a, j in i.args do args[j] = regs[a]
			append(&run.calls, imp.symbol)
			d := s(args)
			if i.dst != NONE do regs[i.dst] = d
		case Return:
			if i.value != NONE do run.result = regs[i.value]
			return run, ""
		}
	}
	return run, "the code ends without a return"
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
