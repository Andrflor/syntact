package code

import kernel "../kernel"
import "core:fmt"
import "core:strings"

// FROM THE NORMAL FORM TO CODE (specs/language/15)
//
// The type of a program is its normal form; its code is that form, read as
// instructions. A known value is a constant. An unknown that no act gives back is an
// input of the program. An act is run where it stands, in order: the call of a
// symbol behind a boundary is an instruction, and what it gives back is the value
// its answer stands for. A pattern is a branch on its target, each cover a test of
// membership in a set the laws computed; the value of the branch taken is moved
// into the pattern's. What the laws could not reduce to one of these is not code
// yet, and says so.

Lowering :: struct {
	k:      ^kernel.Kernel,
	prog:   ^Program,
	f:      ^Func,
	bound:  [dynamic]Bound, // the answers of the acts lowered, and the inputs
	inputs: [dynamic]^kernel.Unknown,
	error:  string,
}

// Bound: what an unknown stands for in the code: the value an act gave back, or an
// input.
Bound :: struct {
	unknown: ^kernel.Unknown,
	value:   Value,
}

// program_type: the type of the file: one run of it, its production — or the
// default one, none — with the acts of the bindings above it (specs/types.md §4.8).
program_type :: proc(k: ^kernel.Kernel) -> kernel.Type {
	if p, found := kernel.first_production(k, k.root); found do return kernel.binding_type(k, p)
	return kernel.with_acts(k, k.root, nil, kernel.None{})
}

// lower_program: the code of a file the kernel checked without error.
lower_program :: proc(k: ^kernel.Kernel) -> (prog: Program, err: string) {
	if len(k.errors) > 0 do return prog, "the program has errors"
	append(&prog.funcs, Func{name = "main"})
	l := Lowering{k = k, prog = &prog, f = &prog.funcs[0]}
	v := lower(&l, program_type(k))
	if l.error != "" do return prog, l.error
	l.f.result = machine_of(l.f, v)
	append(&l.f.insts, Return{v})
	prog.inputs = len(l.inputs)
	return prog, ""
}

fail :: proc(l: ^Lowering, format: string, args: ..any) -> Value {
	if l.error == "" do l.error = fmt.tprintf(format, ..args)
	return NONE
}

emit :: proc(l: ^Lowering, inst: Inst) {
	append(&l.f.insts, inst)
}

constant :: proc(l: ^Lowering, x: i64) -> Value {
	v := value(l.f, .Int)
	emit(l, Const{v, x})
	return v
}

lower :: proc(l: ^Lowering, t: kernel.Type) -> Value {
	if l.error != "" do return NONE
	#partial switch v in t {
	case kernel.Int:
		if i128(v) < i128(min(i64)) || i128(v) > i128(max(i64)) do return fail(l, "%v does not fit in 64 bits", i128(v))
		return constant(l, i64(v))
	case kernel.Bool:
		return constant(l, v ? 1 : 0)
	case kernel.Char:
		return constant(l, i64(v))
	case kernel.Real:
		r := value(l.f, .Real)
		emit(l, Real_Const{r, f64(v.num) / f64(v.den)})
		return r
	case kernel.None:
		return NONE
	case ^kernel.Unknown:
		return unknown(l, v)
	case ^kernel.Operation:
		if kernel.is_string_value(t) {
			r := value(l.f, .Text)
			emit(l, Text_Const{r, text(l.prog, string_of(v))})
			return r
		}
		return operation(l, v)
	case ^kernel.Pattern:
		return pattern(l, v)
	case ^kernel.Effect:
		return act(l, v)
	}
	return fail(l, "%s is not a value the code computes yet", kernel.print_type(t))
}

// unknown: the value an act gave back, or else an input of the program, in the
// order they are first read.
unknown :: proc(l: ^Lowering, u: ^kernel.Unknown) -> Value {
	for b in l.bound do if kernel.same_unknown(b.unknown, u) do return b.value
	m := machine_of_layout(l.k, kernel.layout_of(l.k, u))
	if m != .Int do return fail(l, "the input ?%d is not an integer", u.id)
	v := value(l.f, .Int)
	emit(l, Input{v, len(l.inputs)})
	append(&l.inputs, u)
	append(&l.bound, Bound{u, v})
	return v
}

// act: an act, run where it stands, then what it wraps. Only the call of a symbol
// behind a boundary is code: another effect is served by nothing.
act :: proc(l: ^Lowering, e: ^kernel.Effect) -> Value {
	if e.call == nil do return fail(l, "the effect ε%d is served by no boundary", e.id)
	s, is_scope := e.call.target.(^kernel.Scope)
	if !is_scope do return fail(l, "%s is not a call the code makes yet", kernel.print_type(e.call))
	lib, behind := kernel.symbol_of(s)
	if !behind do return fail(l, "%s: a recursive call is not code yet", kernel.print_type(e.call))
	imp := Import{lib = lib, symbol = kernel.origin(s).name}
	machines := make([dynamic]Machine)
	args := make([dynamic]Value)
	// what goes out: the fields of the symbol, in the order they are declared,
	// with the values the run gave them
	for b in kernel.placed(l.k, s, .Value) {
		if b.kind != .Push && b.kind != .Pull do continue
		color := kernel.binding_color(l.k, b)
		m := color != nil ? machine_of_layout(l.k, color) : .None
		if m == .None do return fail(l, "the field `%s` of %s has no layout the call can pass", b.name, imp.symbol)
		a := lower(l, kernel.binding_value(l.k, b))
		if l.error != "" do return NONE
		if machine_of(l.f, a) != m do return fail(l, "the field `%s` of %s is a %v, given a %v", b.name, imp.symbol, m, machine_of(l.f, a))
		append(&machines, m)
		append(&args, a)
	}
	imp.args = machines[:]
	if e.answer != nil do imp.result = machine_of_layout(l.k, kernel.layout_of(l.k, e.answer))
	if e.answer != nil && imp.result == .None do return fail(l, "what %s gives back has no layout the code holds", imp.symbol)
	dst := imp.result == .None ? NONE : value(l.f, imp.result)
	emit(l, Foreign{dst, intern(l.prog, imp), args[:]})
	if e.answer != nil do append(&l.bound, Bound{e.answer, dst})
	return lower(l, e.then)
}

OPS := [kernel.Operator]Op {
	.Add        = .Add,
	.Sub        = .Sub,
	.Mul        = .Mul,
	.Div        = .Div,
	.Mod        = .Mod,
	.Neg        = .Neg,
	.Bit_And    = .And,
	.Bit_Or     = .Or,
	.Xor        = .Xor,
	.Bit_Not    = .Not,
	.Shl        = .Shl,
	.Shr        = .Shr,
	.Less       = .Lt,
	.Less_Eq    = .Le,
	.Greater    = .Gt,
	.Greater_Eq = .Ge,
	.In         = .Eq, // not used: `in` is a test of membership
}

operation :: proc(l: ^Lowering, o: ^kernel.Operation) -> Value {
	if o.op == .In do return member(l, lower(l, o.args[0]), o.args[1])
	args := make([dynamic]Value)
	for a in o.args {
		append(&args, lower(l, a))
		if l.error != "" do return NONE
	}
	m := machine_of(l.f, args[0])
	for a in args do if machine_of(l.f, a) != m do return fail(l, "%s mixes %v and %v", kernel.print_type(o), m, machine_of(l.f, a))
	if m == .Text || m == .None do return fail(l, "%s is not computed on %v yet", kernel.print_type(o), m)
	op := OPS[o.op]
	if len(args) == 1 {
		// [~] on a boolean is its negation, 1 - b; on an integer, its bits
		if o.op == .Bit_Not && boolean(l, o.args[0]) do return binary(l, .Xor, args[0], constant(l, 1), .Int)
		dst := value(l.f, m)
		emit(l, Unary{dst, args[0], op})
		return dst
	}
	result := m
	if is_comparison(op) do result = .Int
	out := args[0]
	for b in args[1:] do out = binary(l, op, out, b, result)
	return out
}

binary :: proc(l: ^Lowering, op: Op, a, b: Value, m: Machine) -> Value {
	dst := value(l.f, m)
	emit(l, Binary{dst, a, b, op})
	return dst
}

is_comparison :: proc(op: Op) -> bool {
	#partial switch op {
	case .Eq, .Ne, .Lt, .Le, .Gt, .Ge:
		return true
	}
	return false
}

boolean :: proc(l: ^Lowering, t: kernel.Type) -> bool {
	f, known := kernel.family_of(l.k, t)
	return known && f == .Bool
}

// member: x in s, s a set the laws computed: 1 or 0.
member :: proc(l: ^Lowering, x: Value, s: kernel.Type) -> Value {
	if l.error != "" do return NONE
	#partial switch v in s {
	case kernel.Int, kernel.Bool, kernel.Char, kernel.Real:
		return binary(l, .Eq, x, lower(l, v), .Int)
	case ^kernel.Range:
		out := constant(l, 1)
		if v.lo != nil do out = binary(l, .And, out, binary(l, .Ge, x, lower(l, v.lo), .Int), .Int)
		if v.hi != nil do out = binary(l, .And, out, binary(l, .Le, x, lower(l, v.hi), .Int), .Int)
		return out
	case ^kernel.Or:
		out := constant(l, 0)
		for term in v.terms do out = binary(l, .Or, out, member(l, x, term), .Int)
		return out
	case ^kernel.And:
		out := constant(l, 1)
		for term in v.terms do out = binary(l, .And, out, member(l, x, term), .Int)
		return out
	case ^kernel.Not:
		return binary(l, .Xor, member(l, x, v.term), constant(l, 1), .Int)
	case ^kernel.Is:
		return member(l, x, v.term)
	}
	return fail(l, "membership in %s is not code yet", kernel.print_type(s))
}

// pattern: the branches in order; each cover tested on the target, the first that
// holds taken. The check proved that one does: the last is taken without its test.
pattern :: proc(l: ^Lowering, p: ^kernel.Pattern) -> Value {
	target := lower(l, p.target)
	if l.error != "" do return NONE
	end := label(l.f)
	result := NONE
	for b, i in p.branches {
		last := i == len(p.branches) - 1
		next: Label
		if b.cover != nil && !last {
			next = label(l.f)
			emit(l, Branch{member(l, target, b.cover), next})
		}
		v := lower(l, b.product)
		if l.error != "" do return NONE
		if v != NONE {
			if result == NONE do result = value(l.f, machine_of(l.f, v))
			if machine_of(l.f, v) != machine_of(l.f, result) do return fail(l, "the branches of %s give %v and %v", kernel.print_type(p.target), machine_of(l.f, result), machine_of(l.f, v))
			emit(l, Move{result, v})
		}
		if !last {
			emit(l, Jump{end})
			if b.cover != nil do emit(l, Mark{next})
		}
	}
	emit(l, Mark{end})
	return result
}

// machine_of_layout: what holds a value of a layout at run time.
machine_of_layout :: proc(k: ^kernel.Kernel, layout: kernel.Type) -> Machine {
	if layout == nil || kernel.is_none(layout) do return .None
	f, known := kernel.layout_family(k, layout)
	if !known do return .None
	#partial switch f {
	case .Int, .Bool, .Char:
		return .Int
	case .Real:
		return .Real
	case .String:
		return .Text
	}
	return .None
}

string_of :: proc(o: ^kernel.Operation) -> string {
	b := strings.builder_make()
	for a in o.args do strings.write_rune(&b, rune(a.(kernel.Char)))
	return strings.to_string(b)
}
