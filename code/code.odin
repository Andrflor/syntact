package code

import "core:fmt"
import "core:strings"

// THE CODE OF A PROGRAM
//
// The residual program, as instructions (specs/language/15): what the normal form of
// a program leaves to run once the laws have simplified what they can. It keeps the
// structure of that form — a pattern is a match, a recursion whose calls are in
// tail position a loop — and what the kernel proved of each value: the bounds of an
// integer, the narrowing an arm makes, the cells of a cover, whether a function has
// effects. A backend reads these facts; it never computes them again.
//
// Its values are virtual registers, each written once, but for the value of a match,
// written by the arm that runs, and the parameters of a loop, written on entry and
// at each Again. An effect is an instruction in the order it runs: the call of a
// symbol behind a boundary (specs/types.md §4.8).

Value :: distinct int

NONE :: Value(-1) // what gives nothing back

// Machine: what a value is at run time.
Machine :: enum u8 {
	None,
	Int, // a signed 64-bit integer; a boolean is 0 or 1, a character its code point
	Real, // a 64-bit float
	Text, // the address of bytes in the image, followed by a 0
}

// Bounds: the least and greatest integers of a set.
Bounds :: struct {
	lo, hi: i128,
}

// EVERY: the bounds of an integer the kernel proved nothing of.
EVERY :: Bounds{min(i128), max(i128)}

// Kind: what a value is at run time, and, for an integer, the bounds the kernel
// proved of it.
Kind :: struct {
	machine: Machine,
	bounds:  Bounds,
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
	In, // dst = x in a cover: 1 or 0
	Narrow, // dst = src, where an arm narrowed it
	Foreign, // dst = the call of an imported symbol
	Call, // dst = the call of a function of the program
	Match, // dst = the value of the first arm whose cover takes the target
	Loop, // dst = the value of a body run again at each Again
	Again, // the parameters of the innermost loop take new values; its body runs again
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

In :: struct {
	dst, x: Value,
	cover:  Cover,
}

// Narrow: dst is src, in an arm whose cover narrowed it (specs/types.md §6): the
// bounds of dst are the narrowed ones.
Narrow :: struct {
	dst, src: Value,
}

// Foreign: dst = symbol(args…), in the order it is written; NONE when it gives
// nothing back.
Foreign :: struct {
	dst:    Value,
	symbol: int,
	args:   []Value,
}

// Call: dst = func(args…), a function of the program.
Call :: struct {
	dst:  Value,
	func: int,
	args: []Value,
}

// Body: instructions, then the value they give: NONE when they give nothing, or
// end in an Again.
Body :: struct {
	insts: [dynamic]Inst,
	value: Value,
}

// Match: the arms in order; the first whose cover takes the target runs, and its
// value is dst. The last is not tested: the check proved that an arm takes every
// value.
Match :: struct {
	dst:    Value,
	target: Value,
	arms:   []Arm,
}

Arm :: struct {
	cover: Cover,
	body:  Body,
}

// Cover: the values an arm takes, as the kernel cut its set into cells: integers
// (characters and booleans are integers) or floats, sorted. Negated, it takes the
// values outside them.
Cover :: struct {
	ints:    []Bounds,
	reals:   []Interval,
	negated: bool,
}

// Interval: the floats from lo to hi, a bound excluded when open; ±∞ where the set
// has none.
Interval :: struct {
	lo, hi:           f64,
	lo_open, hi_open: bool,
}

// Loop: a recursion whose calls are in tail position. The parameters take init,
// then the body runs; an Again in it runs it again, and the value of the body that
// ends without one is dst.
Loop :: struct {
	dst:    Value,
	params: []Value,
	init:   []Value,
	body:   Body,
}

// Again: the parameters of the innermost loop take args — all read before any is
// written —, and its body runs again.
Again :: struct {
	args: []Value,
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

// Func: a function of the program; its parameters are its first values, v0…
// Pure when its equation has no effect (specs/types.md §4.8): what it gives depends
// on its arguments only.
Func :: struct {
	name:   string,
	pure:   bool,
	params: []Machine,
	result: Machine,
	body:   Body,
	kinds:  [dynamic]Kind, // per value
}

Program :: struct {
	funcs:   [dynamic]^Func, // the first is the program itself
	imports: [dynamic]Import,
	texts:   [dynamic]string,
	inputs:  [dynamic]Cover, // the layout of each input, as written: the stub takes no value outside it
}

// --- building ---

value :: proc(f: ^Func, m: Machine) -> Value {
	append(&f.kinds, Kind{m, EVERY})
	return Value(len(f.kinds) - 1)
}

machine_of :: proc(f: ^Func, v: Value) -> Machine {
	if v == NONE do return .None
	return f.kinds[v].machine
}

bounds_of :: proc(f: ^Func, v: Value) -> Bounds {
	if v == NONE do return EVERY
	return f.kinds[v].bounds
}

// meet: the integers in both a and b.
meet :: proc(a, b: Bounds) -> Bounds {
	return Bounds{max(a.lo, b.lo), min(a.hi, b.hi)}
}

// hull: the least bounds that hold a and b.
hull :: proc(a, b: Bounds) -> Bounds {
	return Bounds{min(a.lo, b.lo), max(a.hi, b.hi)}
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
		params := make([dynamic]string, context.temp_allocator)
		for m, i in f.params {
			b := bounds_of(f, Value(i))
			facts := m == .Int && b != EVERY ? fmt.tprintf(" %s", print_cell(b)) : ""
			append(&params, fmt.tprintf("v%d %v%s", i, m, facts))
		}
		fmt.sbprintfln(&b, "%sfunc %s(%s) -> %v", f.pure ? "pure " : "", f.name, strings.join(params[:], ", ", context.temp_allocator), f.result)
		print_body(&b, f, p, f.body, 1)
	}
	return strings.to_string(b)
}

print_body :: proc(b: ^strings.Builder, f: ^Func, p: ^Program, body: Body, depth: int) {
	indent :: proc(b: ^strings.Builder, depth: int) {for _ in 0 ..< depth do strings.write_string(b, "  ")}
	for inst in body.insts {
		indent(b, depth)
		#partial switch i in inst {
		case Match:
			fmt.sbprintfln(b, "%smatch %s%s", print_dst(i.dst), print_value(i.target), print_bounds(f, i.dst))
			for arm, n in i.arms {
				indent(b, depth + 1)
				fmt.sbprintfln(b, "%s:", n == len(i.arms) - 1 ? "_" : print_cover(arm.cover))
				print_body(b, f, p, arm.body, depth + 2)
			}
		case Loop:
			pairs := make([dynamic]string, context.temp_allocator)
			for x, n in i.params do append(&pairs, fmt.tprintf("%s <- %s", print_value(x), print_value(i.init[n])))
			fmt.sbprintfln(b, "%sloop (%s)%s", print_dst(i.dst), strings.join(pairs[:], ", ", context.temp_allocator), print_bounds(f, i.dst))
			print_body(b, f, p, i.body, depth + 1)
		case:
			fmt.sbprintfln(b, "%s", print_inst(f, p, inst))
		}
	}
	if body.value != NONE {
		indent(b, depth)
		fmt.sbprintfln(b, "-> %s", print_value(body.value))
	}
}

print_dst :: proc(x: Value) -> string {
	return x == NONE ? "" : fmt.tprintf("v%d = ", int(x))
}

print_value :: proc(x: Value) -> string {
	return x == NONE ? "none" : fmt.tprintf("v%d", int(x))
}

// print_bounds: the bounds of an integer, when the kernel proved some.
print_bounds :: proc(f: ^Func, x: Value) -> string {
	if machine_of(f, x) != .Int || bounds_of(f, x) == EVERY do return ""
	return fmt.tprintf("    ; %s", print_cell(bounds_of(f, x)))
}

print_cell :: proc(c: Bounds) -> string {
	lo := c.lo == min(i128) ? "" : fmt.tprint(c.lo)
	hi := c.hi == max(i128) ? "" : fmt.tprint(c.hi)
	if c.lo == c.hi do return lo
	return fmt.tprintf("%s..%s", lo, hi)
}

print_cover :: proc(c: Cover) -> string {
	cells := make([dynamic]string, context.temp_allocator)
	for x in c.ints do append(&cells, print_cell(x))
	for x in c.reals {
		lo := x.lo_open ? "(" : "["
		hi := x.hi_open ? ")" : "]"
		append(&cells, fmt.tprintf("%s%v, %v%s", lo, x.lo, x.hi, hi))
	}
	s := strings.join(cells[:], " | ", context.temp_allocator)
	return c.negated ? fmt.tprintf("~(%s)", s) : s
}

print_inst :: proc(f: ^Func, p: ^Program, inst: Inst) -> string {
	v := print_value
	list :: proc(xs: []Value) -> string {
		out := make([dynamic]string, context.temp_allocator)
		for x in xs do append(&out, print_value(x))
		return strings.join(out[:], ", ", context.temp_allocator)
	}
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
		return fmt.tprintf("%s = input %d%s", v(i.dst), i.slot, print_bounds(f, i.dst))
	case Unary:
		return fmt.tprintf("%s = %v %s%s", v(i.dst), i.op, v(i.a), print_bounds(f, i.dst))
	case Binary:
		return fmt.tprintf("%s = %s %v %s%s", v(i.dst), v(i.a), i.op, v(i.b), print_bounds(f, i.dst))
	case In:
		return fmt.tprintf("%s = %s in %s", v(i.dst), v(i.x), print_cover(i.cover))
	case Narrow:
		return fmt.tprintf("%s = narrow %s%s", v(i.dst), v(i.src), print_bounds(f, i.dst))
	case Foreign:
		return fmt.tprintf("%s = call %s(%s)%s", v(i.dst), p.imports[i.symbol].symbol, list(i.args), print_bounds(f, i.dst))
	case Call:
		return fmt.tprintf("%s = call %s(%s)%s", v(i.dst), p.funcs[i.func].name, list(i.args), print_bounds(f, i.dst))
	case Again:
		return fmt.tprintf("again (%s)", list(i.args))
	case Match, Loop:
	}
	return ""
}
