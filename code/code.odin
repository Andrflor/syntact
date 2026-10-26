package code

import "core:fmt"
import "core:strings"

// THE CODE OF A PROGRAM
//
// The residual program, as instructions (specs/language/15): what the normal form of
// a program leaves to run once the laws have simplified what they can. Its values
// are virtual registers, each written once but at a join, where each path moves its
// value into the same register. An act is an instruction in the order it runs: the
// call of a symbol behind a boundary (specs/types.md §4.8).

Value :: distinct int
Label :: distinct int

NONE :: Value(-1) // what gives nothing back

// Machine: what a value is at run time.
Machine :: enum u8 {
	None,
	Int, // a signed 64-bit integer; a boolean is 0 or 1
	Real, // a 64-bit float
	Text, // the address of bytes in the image, followed by a 0
}

Op :: enum u8 {
	Add,
	Sub,
	Mul,
	Div, // truncated toward 0
	Mod, // the sign of the dividend
	Neg,
	And, // bitwise; on booleans, and
	Or,
	Xor,
	Not, // bitwise
	Shl,
	Shr,
	Eq, // comparisons give 0 or 1
	Ne,
	Lt,
	Le,
	Gt,
	Ge,
}

Inst :: union {
	Const, // dst = an integer
	Real_Const, // dst = a float
	Text_Const, // dst = the address of a text of the program
	Input, // dst = the n-th input of the program, an integer
	Unary, // dst = op a
	Binary, // dst = a op b
	Move, // dst = src: the value of a path at a join
	Mark, // label:
	Jump, // goto label
	Branch, // if cond = 0 goto otherwise
	Foreign, // dst = the call of an imported symbol
	Return, // the value of the function
}

Const :: struct {
	dst:   Value,
	value: i64,
}

Real_Const :: struct {
	dst:   Value,
	value: f64,
}

Text_Const :: struct {
	dst:  Value,
	text: int,
}

Input :: struct {
	dst:  Value,
	slot: int,
}

Unary :: struct {
	dst, a: Value,
	op:     Op,
}

Binary :: struct {
	dst, a, b: Value,
	op:        Op,
}

Move :: struct {
	dst, src: Value,
}

Mark :: struct {
	label: Label,
}

Jump :: struct {
	label: Label,
}

Branch :: struct {
	cond:      Value,
	otherwise: Label,
}

// Foreign: dst = symbol(args…), in the order it is written; NONE when it gives
// nothing back.
Foreign :: struct {
	dst:    Value,
	symbol: int,
	args:   []Value,
}

Return :: struct {
	value: Value,
}

// Import: a symbol of a library, as a boundary declares it: what goes out, and
// what comes back.
Import :: struct {
	lib, symbol: string,
	args:        []Machine,
	result:      Machine,
	// an integer that comes back: how many of its bits the symbol gives, and
	// whether they are signed
	result_bits:   int,
	result_signed: bool,
}

Func :: struct {
	name:   string,
	result: Machine,
	insts:  [dynamic]Inst,
	types:  [dynamic]Machine, // per value
	labels: int,
}

Program :: struct {
	funcs:   [dynamic]Func, // the first is the program itself
	imports: [dynamic]Import,
	texts:   [dynamic]string,
	inputs:  int,
}

// --- building ---

value :: proc(f: ^Func, m: Machine) -> Value {
	append(&f.types, m)
	return Value(len(f.types) - 1)
}

label :: proc(f: ^Func) -> Label {
	f.labels += 1
	return Label(f.labels - 1)
}

machine_of :: proc(f: ^Func, v: Value) -> Machine {
	if v == NONE do return .None
	return f.types[v]
}

// intern: the import of lib's symbol, once.
intern :: proc(p: ^Program, imp: Import) -> int {
	for x, i in p.imports do if x.lib == imp.lib && x.symbol == imp.symbol do return i
	append(&p.imports, imp)
	return len(p.imports) - 1
}

text :: proc(p: ^Program, s: string) -> int {
	for t, i in p.texts do if t == s do return i
	append(&p.texts, s)
	return len(p.texts) - 1
}

// --- printing ---

print_program :: proc(p: ^Program) -> string {
	b := strings.builder_make(context.temp_allocator)
	for imp, i in p.imports {
		args := make([dynamic]string, context.temp_allocator)
		for a in imp.args do append(&args, fmt.tprint(a))
		fmt.sbprintfln(&b, "import %d  <%s>.%s(%s) -> %v", i, imp.lib, imp.symbol, strings.join(args[:], ", ", context.temp_allocator), imp.result)
	}
	for t, i in p.texts do fmt.sbprintfln(&b, "text %d  %q", i, t)
	for f in p.funcs {
		fmt.sbprintfln(&b, "func %s -> %v", f.name, f.result)
		for inst in f.insts do fmt.sbprintfln(&b, "  %s", print_inst(f, p, inst))
	}
	return strings.to_string(b)
}

print_inst :: proc(f: Func, p: ^Program, inst: Inst) -> string {
	v :: proc(x: Value) -> string {return x == NONE ? "none" : fmt.tprintf("v%d", int(x))}
	switch i in inst {
	case Const:
		return fmt.tprintf("%s = %d", v(i.dst), i.value)
	case Real_Const:
		r := fmt.tprintf("%v", i.value)
		if !strings.contains_any(r, ".en") do r = fmt.tprintf("%s.0", r) // a real reads as one
		return fmt.tprintf("%s = %s", v(i.dst), r)
	case Text_Const:
		return fmt.tprintf("%s = text %d", v(i.dst), i.text)
	case Input:
		return fmt.tprintf("%s = input %d", v(i.dst), i.slot)
	case Unary:
		return fmt.tprintf("%s = %v %s", v(i.dst), i.op, v(i.a))
	case Binary:
		return fmt.tprintf("%s = %s %v %s", v(i.dst), v(i.a), i.op, v(i.b))
	case Move:
		return fmt.tprintf("%s <- %s", v(i.dst), v(i.src))
	case Mark:
		return fmt.tprintf("L%d:", int(i.label))
	case Jump:
		return fmt.tprintf("jump L%d", int(i.label))
	case Branch:
		return fmt.tprintf("if %s = 0 jump L%d", v(i.cond), int(i.otherwise))
	case Foreign:
		args := make([dynamic]string, context.temp_allocator)
		for a in i.args do append(&args, v(a))
		return fmt.tprintf("%s = call %s(%s)", v(i.dst), p.imports[i.symbol].symbol, strings.join(args[:], ", ", context.temp_allocator))
	case Return:
		return fmt.tprintf("return %s", v(i.value))
	}
	return ""
}
