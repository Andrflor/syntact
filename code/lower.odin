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
	bound:  [dynamic]Bound, // in f: the answers of the acts lowered, its parameters, the inputs
	inputs: [dynamic]^kernel.Unknown,
	funcs:  map[^kernel.Scope]int, // the function of each recursive equation lowered
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
	append(&prog.funcs, new_clone(Func{name = "main"}))
	l := Lowering{k = k, prog = &prog, f = prog.funcs[0]}
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
	case ^kernel.Collapse:
		if v.recursive do return call(l, v)
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
	if e.call.recursive {
		// a call of an equation that acts: the call, then what it wraps
		dst := call(l, e.call)
		if e.answer != nil do append(&l.bound, Bound{e.answer, dst})
		return lower(l, e.then)
	}
	s, is_scope := e.call.target.(^kernel.Scope)
	if !is_scope do return fail(l, "%s is not a call the code makes yet", kernel.print_type(e.call))
	lib, behind := kernel.symbol_of(s)
	if !behind do return fail(l, "%s is not a call the code makes yet", kernel.print_type(e.call))
	imp := Import{lib = lib, symbol = kernel.origin(s).name}
	machines := make([dynamic]Machine)
	args := make([dynamic]Value)
	// what goes out: the fields of the symbol, in the order they are declared,
	// with the values the run gave them
	for b in kernel.placed(l.k, s, .Value) {
		if b.kind != .Push && b.kind != .Pull do continue
		for a in crossing(l, b, imp.symbol) {
			append(&machines, machine_of(l.f, a))
			append(&args, a)
		}
		if l.error != "" do return NONE
	}
	imp.args = machines[:]
	if e.answer != nil {
		if named(e.answer.written, "f32") do return fail(l, "%s gives back an f32: only f64 crosses a boundary yet", imp.symbol)
		layout := kernel.layout_of(l.k, e.answer)
		imp.result = machine_of_layout(l.k, layout)
		if imp.result == .None do return fail(l, "what %s gives back has no layout the code holds", imp.symbol)
		if imp.result == .Int do imp.result_bits, imp.result_signed = int_width(l.k, layout)
	}
	dst := imp.result == .None ? NONE : value(l.f, imp.result)
	emit(l, Foreign{dst, intern(l.prog, imp), args[:]})
	if e.answer != nil do append(&l.bound, Bound{e.answer, dst})
	return lower(l, e.then)
}

// call: a recursive call that stays, as the call of the function of its equation;
// the values the carve gives the fields are its arguments.
call :: proc(l: ^Lowering, c: ^kernel.Collapse) -> Value {
	s, is_scope := c.target.(^kernel.Scope)
	if !is_scope do return fail(l, "%s is not a call the code makes yet", kernel.print_type(c))
	index := function_of(l, kernel.origin(s), c)
	if l.error != "" do return NONE
	args := make([dynamic]Value)
	for b, i in s.bindings {
		if !is_parameter(b) do continue
		a := lower(l, kernel.binding_value(l.k, b))
		if l.error != "" do return NONE
		if machine_of(l.f, a) != l.prog.funcs[index].params[len(args)] do return fail(l, "the field `%s` of %s is given a %v", b.name, kernel.print_type(c), machine_of(l.f, a))
		append(&args, a)
		_ = i
	}
	dst := value(l.f, l.prog.funcs[index].result)
	emit(l, Call{dst, index, args[:]})
	return dst
}

is_parameter :: proc(b: ^kernel.Binding) -> bool {
	return b.kind == .Push || b.kind == .Pull
}

// function_of: the function of a recursive equation, lowered once (specs/language/15):
// its fields are its parameters, each an unknown of its layout — its color, or else
// the family of its value —, and its body the normal form of its production over
// them, its own calls left as calls.
function_of :: proc(l: ^Lowering, root: ^kernel.Scope, c: ^kernel.Collapse) -> int {
	if index, done := l.funcs[root]; done do return index
	family, known := kernel.family_of(l.k, c)
	if !known do return int(fail(l, "%s has no family the code holds", kernel.print_type(c)))
	f := new_clone(Func{name = root.name != "" ? root.name : "equation"})
	f.result = machine_of_layout(l.k, kernel.family_term(family))
	index := len(l.prog.funcs)
	append(&l.prog.funcs, f)
	l.funcs[root] = index
	changes := make(map[^kernel.Binding]kernel.Type)
	params := make([dynamic]^kernel.Unknown)
	machines := make([dynamic]Machine)
	for b in root.bindings {
		if !is_parameter(b) do continue
		layout := kernel.binding_color(l.k, b)
		if layout == nil {
			family, has := kernel.family_of(l.k, kernel.binding_value(l.k, b))
			if !has do return int(fail(l, "the field `%s` of %s is not a value the code passes", b.name, f.name))
			layout = kernel.family_term(family)
		}
		m := machine_of_layout(l.k, layout)
		if m == .None do return int(fail(l, "the field `%s` of %s is not a value the code passes", b.name, f.name))
		u := kernel.new_unknown(l.k, layout)
		changes[b] = u
		append(&params, u)
		append(&machines, m)
	}
	f.params = machines[:]
	generic, is_scope := kernel.derive(l.k, root, changes, root.span).(^kernel.Scope)
	if !is_scope do return int(fail(l, "the equation of %s does not take its fields as parameters", f.name))
	p, has := kernel.first_production(l.k, generic)
	if !has do return int(fail(l, "%s has no production", f.name))
	body := kernel.binding_type(l.k, p)
	// the body, in the function
	outer, outer_bound := l.f, l.bound
	l.f, l.bound = f, make([dynamic]Bound)
	for u, i in params {
		append(&l.bound, Bound{u, value(f, machines[i])})
	}
	v := lower(l, body)
	if l.error == "" && machine_of(f, v) != f.result do fail(l, "%s gives a %v, its calls a %v", f.name, machine_of(f, v), f.result)
	emit(l, Return{v})
	l.f, l.bound = outer, outer_bound
	return index
}

// crossing: the values that pass a field of a symbol, one in each register the
// call fills. A value of a primitive layout is one. A scope crosses as it is
// (specs/language/11): laid out as C lays out a struct of its fields, in words of
// 8 bytes — a word that holds a float alone is that float, any other the bytes of
// its fields packed in an integer.
crossing :: proc(l: ^Lowering, b: ^kernel.Binding, symbol: string) -> []Value {
	out := make([dynamic]Value)
	if s, is_scope := kernel.binding_value(l.k, b).(^kernel.Scope); is_scope {
		slots, size, _ := lay_out(l, s, b.name, symbol)
		if l.error != "" do return nil
		if size == 0 || size > 16 {
			fail(l, "the field `%s` of %s is a scope of %d bytes: only 1 to 16 cross in registers yet", b.name, symbol, size)
			return nil
		}
		for start := 0; start < size; start += 8 do append(&out, word(l, slots, start))
		return out[:]
	}
	m, _ := primitive(l, b, b.name, symbol)
	if l.error != "" do return nil
	a := argument(l, kernel.binding_value(l.k, b), m)
	if l.error != "" do return nil
	if machine_of(l.f, a) != m {
		fail(l, "the field `%s` of %s is a %v, given a %v", b.name, symbol, m, machine_of(l.f, a))
		return nil
	}
	append(&out, a)
	return out[:]
}

// Slot: a field of primitive layout in the C layout of a scope.
Slot :: struct {
	field:   ^kernel.Binding,
	machine: Machine,
	offset:  int,
	size:    int,
}

// lay_out: the slots of the fields of s, in order, each aligned on its alignment
// — its size, for a primitive; its largest, for a scope —, and the size of s, a
// multiple of its alignment.
lay_out :: proc(l: ^Lowering, s: ^kernel.Scope, name, symbol: string) -> (slots: []Slot, size, align: int) {
	out := make([dynamic]Slot)
	align = 1
	for f in kernel.placed(l.k, s, .Value) {
		if f.kind != .Push && f.kind != .Pull {
			fail(l, "the field `%s` of %s is a scope that is not only fields", name, symbol)
			return
		}
		inner: []Slot
		n, a: int
		if nested, is_scope := kernel.binding_value(l.k, f).(^kernel.Scope); is_scope {
			inner, n, a = lay_out(l, nested, name, symbol)
		} else {
			m, bytes := primitive(l, f, name, symbol)
			inner, n, a = []Slot{{f, m, 0, bytes}}, bytes, bytes
		}
		if l.error != "" do return
		size = (size + a - 1) / a * a
		for x in inner do append(&out, Slot{x.field, x.machine, x.offset + size, x.size})
		size += n
		align = max(align, a)
	}
	return out[:], (size + align - 1) / align * align, align
}

// primitive: the machine of a binding's value at a boundary, and its bytes — the
// C type that holds it: a boolean is a byte, an integer the least width that holds
// its range, a float or a text 8 bytes.
primitive :: proc(l: ^Lowering, b: ^kernel.Binding, name, symbol: string) -> (Machine, int) {
	if named(b.color, "f32") {
		fail(l, "the field `%s` of %s is an f32: only f64 crosses a boundary yet", name, symbol)
		return .None, 0
	}
	color := kernel.binding_color(l.k, b)
	m := color != nil ? machine_of_layout(l.k, color) : .None
	if m == .None {
		fail(l, "the field `%s` of %s has no layout the call can pass", name, symbol)
		return .None, 0
	}
	if m != .Int do return m, 8
	bits, _ := int_width(l.k, color)
	return m, bits / 8
}

// word: the 8 bytes of a scope laid out in slots from start, as one value.
word :: proc(l: ^Lowering, slots: []Slot, start: int) -> Value {
	out := NONE
	for x in slots {
		if x.offset < start || x.offset >= start + 8 do continue
		v := argument(l, kernel.binding_value(l.k, x.field), x.machine)
		if l.error != "" do return NONE
		if machine_of(l.f, v) != x.machine do return fail(l, "the field `%s` is a %v, given a %v", x.field.name, x.machine, machine_of(l.f, v))
		if x.machine != .Int do return v // a float or a text: the whole word
		if x.size < 8 do v = binary(l, .And, v, constant(l, i64(1) << uint(8 * x.size) - 1), .Int)
		if x.offset > start do v = binary(l, .Shl, v, constant(l, i64(8 * (x.offset - start))), .Int)
		out = out == NONE ? v : binary(l, .Or, out, v, .Int)
	}
	return out == NONE ? constant(l, 0) : out
}

// argument: a value where a machine is expected. A character is a string of length
// 1 (specs/types.md §4.6): where a text goes, it is the text of that character.
argument :: proc(l: ^Lowering, t: kernel.Type, m: Machine) -> Value {
	c, is_char := t.(kernel.Char)
	if m != .Text || !is_char do return lower(l, t)
	b := strings.builder_make()
	strings.write_rune(&b, rune(c))
	r := value(l.f, .Text)
	emit(l, Text_Const{r, text(l.prog, strings.to_string(b))})
	return r
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
	case ^kernel.Unknown, ^kernel.Operation:
		// one value the laws did not compute: x in v is x = v
		return binary(l, .Eq, x, lower(l, v), .Int)
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

// int_width: the bits that hold the integers of a layout, and whether signed: the
// width an integer crosses a boundary in. A boolean is a byte.
int_width :: proc(k: ^kernel.Kernel, layout: kernel.Type) -> (bits: int, signed: bool) {
	if f, known := kernel.layout_family(k, layout); known && f == .Bool do return 8, false
	r, is_range := layout.(^kernel.Range)
	if !is_range do return 64, true
	lo, has_lo := r.lo.(kernel.Int)
	hi, has_hi := r.hi.(kernel.Int)
	if !has_lo || !has_hi do return 64, true
	for b in ([]uint{8, 16, 32}) {
		if lo >= 0 && i128(hi) < i128(1) << b do return int(b), false
		if i128(lo) >= -(i128(1) << (b - 1)) && i128(hi) < i128(1) << (b - 1) do return int(b), true
	}
	return 64, lo < 0
}

// named: t is written as the alias name.
named :: proc(t: kernel.Type, name: string) -> bool {
	n, is_name := t.(^kernel.Name)
	return is_name && n.binding.name == name
}

string_of :: proc(o: ^kernel.Operation) -> string {
	b := strings.builder_make()
	for a in o.args do strings.write_rune(&b, rune(a.(kernel.Char)))
	return strings.to_string(b)
}
