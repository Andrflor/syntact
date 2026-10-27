package code

import kernel "../kernel"
import "core:fmt"
import "core:strings"

// FROM THE NORMAL FORM TO CODE (specs/language/15)
//
// The type of a program is its normal form; its code is that form, read as
// instructions. A known value is a constant. An unknown that no effect gives back is
// an input of the program. An effect is run where it stands, in order: the call of a
// symbol behind a boundary is an instruction, and what it gives back is the value
// its answer stands for. A pattern is a match on its target, each cover the cells
// of a set the laws computed. An iteration, the solution of a recursion, is a loop;
// a recursion that stays is a function, and its calls in tail position the loop of
// its body. What the laws could not reduce to one of these is not code yet, and
// says so.
//
// What the kernel proved comes along: each integer has the bounds of its layout
// image (specs/types.md §7), and an unknown an arm narrows, ?ₖ::(L & S), is read
// there through a Narrow.

Lowering :: struct {
	k:      ^kernel.Kernel,
	prog:   ^Program,
	f:      ^Func,
	insts:  ^[dynamic]Inst, // the body the instructions go to
	bound:  [dynamic]Bound, // in the body: the answers of its effects, the parameters, the inputs, the narrowings
	inputs: [dynamic]^kernel.Unknown,
	funcs:  map[^kernel.Scope]int, // the function of each recursive equation lowered
	self:   ^Self, // the function being lowered; nil in the program itself
	error:  string,
}

// Bound: what an unknown stands for in the code: the value an effect gave back, a
// parameter, an input, or what an arm narrowed one of these to.
Bound :: struct {
	unknown: ^kernel.Unknown,
	value:   Value,
}

// Self: the equation of the function being lowered. A call of it in tail position
// is an Again of the loop of its body.
Self :: struct {
	root:  ^kernel.Scope,
	again: bool, // a call in tail position was lowered
}

// program_type: the type of the file: one run of it, its production — or the
// default one, none — with the effects of the bindings above it (specs/types.md §4.8).
program_type :: proc(k: ^kernel.Kernel) -> kernel.Type {
	if p, found := kernel.first_production(k, k.root); found do return kernel.binding_type(k, p)
	return kernel.with_effects(k, k.root, nil, kernel.None{})
}

// lower_program: the code of a file the kernel checked without error.
lower_program :: proc(k: ^kernel.Kernel) -> (prog: Program, err: string) {
	if len(k.errors) > 0 do return prog, "the program has errors"
	append(&prog.funcs, new_clone(Func{name = "main"}))
	l := Lowering{k = k, prog = &prog, f = prog.funcs[0]}
	l.f.body = lower_body(&l, program_type(k), false)
	if l.error != "" do return prog, l.error
	l.f.result = machine_of(l.f, l.f.body.value)
	for u in l.inputs {
		c, known := input_cover(&l, u)
		if !known do return prog, fmt.tprintf("the input ?%d has a layout the code does not test", u.id)
		append(&prog.inputs, c)
	}
	return prog, ""
}

// input_cover: the layout an input is written with, before any arm narrows it, as
// a cover: what the stub admits.
input_cover :: proc(l: ^Lowering, u: ^kernel.Unknown) -> (Cover, bool) {
	written := u^
	written.layout = nil
	layout := kernel.layout_of(l.k, &written)
	if c, constant := cover_of(layout); constant do return c, len(c.reals) == 0
	if b := term_bounds(l, &written); b == EVERY {
		every := make([]Bounds, 1)
		every[0] = EVERY
		return Cover{ints = every}, true
	}
	return {}, false
}

fail :: proc(l: ^Lowering, format: string, args: ..any) -> Value {
	if l.error == "" do l.error = fmt.tprintf(format, ..args)
	return NONE
}

emit :: proc(l: ^Lowering, inst: Inst) {
	append(l.insts, inst)
}

constant :: proc(l: ^Lowering, x: i64) -> Value {
	v := value(l.f, .Int)
	l.f.kinds[v].bounds = {i128(x), i128(x)}
	emit(l, Const{v, x})
	return v
}

// open_body: b, the body the instructions go to until it is closed. What it binds
// is bound in it only.
open_body :: proc(l: ^Lowering, b: ^Body) -> (outer: ^[dynamic]Inst, bound: int) {
	outer, bound = l.insts, len(l.bound)
	b.insts = make([dynamic]Inst)
	l.insts = &b.insts
	return
}

close_body :: proc(l: ^Lowering, outer: ^[dynamic]Inst, bound: int) {
	l.insts = outer
	resize(&l.bound, bound)
}

// lower_body: t, as a body of its own.
lower_body :: proc(l: ^Lowering, t: kernel.Type, tail: bool) -> (b: Body) {
	outer, bound := open_body(l, &b)
	b.value = lower(l, t, tail)
	close_body(l, outer, bound)
	return
}

// lower: the value of t. In tail position, nothing is computed after it: a call of
// the function being lowered is an Again. A value made for t has the bounds of t.
lower :: proc(l: ^Lowering, t: kernel.Type, tail := false) -> Value {
	if l.error != "" do return NONE
	first := Value(len(l.f.kinds))
	v := term(l, t, tail)
	if v != NONE && v >= first && machine_of(l.f, v) == .Int {
		l.f.kinds[v].bounds = meet(l.f.kinds[v].bounds, term_bounds(l, t))
	}
	return v
}

term :: proc(l: ^Lowering, t: kernel.Type, tail: bool) -> Value {
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
		emit(l, Real_Const{r, float_of(v)})
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
		target := lower(l, v.target)
		if l.error != "" do return NONE
		return match(l, v.branches, target, tail)
	case ^kernel.Effect:
		return effect(l, v, tail)
	case ^kernel.Collapse:
		if !v.recursive do break
		if tail && is_self(l, v) do return again(l, v)
		return call(l, v)
	case ^kernel.Iterate:
		return iterate(l, v)
	}
	return fail(l, "%s is not a value the code computes yet", kernel.print_type(t))
}

// unknown: the value an effect gave back, a parameter, or else an input of the
// program, numbered in the order they are first read. Where an arm narrowed it,
// ?ₖ::(L & S), it is read through a Narrow that has the narrowed bounds.
unknown :: proc(l: ^Lowering, u: ^kernel.Unknown) -> Value {
	facts := term_bounds(l, u)
	#reverse for b in l.bound {
		if !kernel.same_unknown(b.unknown, u) do continue
		if machine_of(l.f, b.value) != .Int do return b.value
		narrowed := meet(bounds_of(l.f, b.value), facts)
		if narrowed == bounds_of(l.f, b.value) do return b.value
		dst := value(l.f, .Int)
		l.f.kinds[dst].bounds = narrowed
		emit(l, Narrow{dst, b.value})
		append(&l.bound, Bound{u, dst})
		return dst
	}
	m := machine_of_layout(l.k, kernel.layout_of(l.k, u))
	if m != .Int do return fail(l, "the input ?%d is not an integer", u.id)
	slot := len(l.inputs)
	for x, i in l.inputs do if kernel.same_unknown(x, u) do slot = i
	if slot == len(l.inputs) do append(&l.inputs, u)
	v := value(l.f, .Int)
	l.f.kinds[v].bounds = facts
	emit(l, Input{v, slot})
	append(&l.bound, Bound{u, v})
	return v
}

// effect: an effect, run where it stands, then what it wraps. Only the call of a
// symbol behind a boundary is code: another effect is served by nothing.
effect :: proc(l: ^Lowering, e: ^kernel.Effect, tail: bool) -> Value {
	if e.iterate != nil {
		// an iteration whose steps have effects: the loop, then what it wraps
		dst := iterate(l, e.iterate)
		if e.answer != nil do append(&l.bound, Bound{e.answer, dst})
		return lower(l, e.then, tail)
	}
	if e.call == nil do return fail(l, "the effect ε%d is served by no boundary", e.id)
	if e.call.recursive {
		// a call of an equation with effects: the call, then what it wraps — in tail
		// position when what it wraps is what the call gives back
		if tail && is_self(l, e.call) && gives_answer(e) do return again(l, e.call)
		dst := call(l, e.call)
		if e.answer != nil do append(&l.bound, Bound{e.answer, dst})
		return lower(l, e.then, tail)
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
	if imp.result == .Int do l.f.kinds[dst].bounds = term_bounds(l, e.answer)
	emit(l, Foreign{dst, intern(l.prog, imp), args[:]})
	if e.answer != nil do append(&l.bound, Bound{e.answer, dst})
	return lower(l, e.then, tail)
}

// iterate: an iteration (specs/types.md §5.6) as a loop on its counter k and its
// value x: k from `from`, x from init; until k passes `to`, x takes the step and k
// the next integer. An iteration of effects alone has no value.
iterate :: proc(l: ^Lowering, it: ^kernel.Iterate) -> Value {
	from, to, init := lower(l, it.from), lower(l, it.to), lower(l, it.init)
	if l.error != "" do return NONE
	if machine_of(l.f, from) != .Int || machine_of(l.f, to) != .Int do return fail(l, "an iteration whose counter is not an integer is not code yet")
	counter := value(l.f, .Int)
	state := init == NONE ? NONE : value(l.f, machine_of(l.f, init))
	params := make([dynamic]Value)
	starts := make([dynamic]Value)
	append(&params, counter)
	append(&starts, from)
	if state != NONE {
		append(&params, state)
		append(&starts, init)
	}
	loop := Loop{dst = NONE, params = params[:], init = starts[:]}
	outer, bound := open_body(l, &loop.body)
	append(&l.bound, Bound{it.index, counter})
	if state != NONE do append(&l.bound, Bound{it.state, state})
	past := binary(l, it.down ? .Lt : .Gt, counter, to, .Int)
	done := make([]Bounds, 1)
	done[0] = {1, 1}
	arms := make([]Arm, 2)
	arms[0] = Arm{cover = Cover{ints = done}, body = Body{insts = make([dynamic]Inst), value = state}}
	arms[1].body.value = NONE // it ends in an Again
	step_outer, step_bound := open_body(l, &arms[1].body)
	x := lower(l, it.step)
	if l.error == "" && machine_of(l.f, x) != machine_of(l.f, state) do fail(l, "the step of an iteration gives a %v, its value is a %v", machine_of(l.f, x), machine_of(l.f, state))
	next := binary(l, it.down ? .Sub : .Add, counter, constant(l, 1), .Int)
	args := make([dynamic]Value)
	append(&args, next)
	if state != NONE do append(&args, x)
	emit(l, Again{args[:]})
	close_body(l, step_outer, step_bound)
	loop.body.value = close_match(l, past, arms)
	close_body(l, outer, bound)
	if l.error != "" do return NONE
	if loop.body.value != NONE {
		loop.dst = value(l.f, machine_of(l.f, loop.body.value))
		l.f.kinds[loop.dst].bounds = bounds_of(l.f, loop.body.value)
	}
	emit(l, loop)
	return loop.dst
}

// gives_answer: what the effect wraps is what it gives back.
gives_answer :: proc(e: ^kernel.Effect) -> bool {
	if e.answer == nil do return kernel.is_none(e.then)
	u, is_unknown := e.then.(^kernel.Unknown)
	return is_unknown && kernel.same_unknown(u, e.answer)
}

// is_self: c is a call of the function being lowered.
is_self :: proc(l: ^Lowering, c: ^kernel.Collapse) -> bool {
	s, is_scope := c.target.(^kernel.Scope)
	return l.self != nil && is_scope && kernel.origin(s) == l.self.root
}

// call: a recursive call that stays, as the call of the function of its equation.
call :: proc(l: ^Lowering, c: ^kernel.Collapse) -> Value {
	index, args := arguments(l, c)
	if l.error != "" do return NONE
	dst := value(l.f, l.prog.funcs[index].result)
	emit(l, Call{dst, index, args})
	return dst
}

// again: a call of the function being lowered, in tail position: its parameters
// take the values the carve gives, and its body runs again.
again :: proc(l: ^Lowering, c: ^kernel.Collapse) -> Value {
	_, args := arguments(l, c)
	if l.error != "" do return NONE
	emit(l, Again{args})
	l.self.again = true
	return NONE
}

// arguments: the function of the equation c carves, and the values the carve
// gives its fields.
arguments :: proc(l: ^Lowering, c: ^kernel.Collapse) -> (index: int, args: []Value) {
	s, is_scope := c.target.(^kernel.Scope)
	if !is_scope {
		fail(l, "%s is not a call the code makes yet", kernel.print_type(c))
		return
	}
	index = function_of(l, kernel.origin(s), c)
	if l.error != "" do return
	out := make([dynamic]Value)
	for b in s.bindings {
		if !is_parameter(b) do continue
		a := lower(l, kernel.binding_value(l.k, b))
		if l.error != "" do return
		if machine_of(l.f, a) != l.prog.funcs[index].params[len(out)] {
			fail(l, "the field `%s` of %s is given a %v", b.name, kernel.print_type(c), machine_of(l.f, a))
			return
		}
		append(&out, a)
	}
	return index, out[:]
}

is_parameter :: proc(b: ^kernel.Binding) -> bool {
	return b.kind == .Push || b.kind == .Pull
}

// function_of: the function of a recursive equation, lowered once (specs/language/15):
// its fields are its parameters, each an unknown of its layout — its color, or else
// the family of its value —, and its body the normal form of its production over
// them, its own calls left as calls. When some are in tail position, the body is a
// loop on the parameters.
function_of :: proc(l: ^Lowering, root: ^kernel.Scope, c: ^kernel.Collapse) -> int {
	if index, done := l.funcs[root]; done do return index
	family, known := kernel.family_of(l.k, c)
	if !known do return int(fail(l, "%s has no family the code holds", kernel.print_type(c)))
	f := new_clone(Func{name = root.name != "" ? root.name : "equation", pure = !root.effectful})
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
	outer, outer_bound, outer_self, outer_insts := l.f, l.bound, l.self, l.insts
	self := Self{root = root}
	l.f, l.bound, l.self = f, make([dynamic]Bound), &self
	values := make([]Value, len(params))
	for u, i in params {
		values[i] = value(f, machines[i])
		if machines[i] == .Int do f.kinds[values[i]].bounds = term_bounds(l, u)
		append(&l.bound, Bound{u, values[i]})
	}
	f.body = lower_body(l, body, true)
	if self.again {
		loop := Loop{dst = NONE, params = values, init = values, body = f.body}
		if f.body.value != NONE {
			loop.dst = value(f, machine_of(f, f.body.value))
			f.kinds[loop.dst].bounds = bounds_of(f, f.body.value)
		}
		f.body = Body{value = loop.dst}
		append(&f.body.insts, loop)
	}
	if l.error == "" && machine_of(f, f.body.value) != f.result do fail(l, "%s gives a %v, its calls a %v", f.name, machine_of(f, f.body.value), f.result)
	l.f, l.bound, l.self, l.insts = outer, outer_bound, outer_self, outer_insts
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
	if is_comparison(op) do l.f.kinds[dst].bounds = {0, 1}
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

// member: x in s: 1 or 0. A set of constants is a cover; a set the laws did not
// compute is tested on its parts — a value it holds is x = that value.
member :: proc(l: ^Lowering, x: Value, s: kernel.Type) -> Value {
	if l.error != "" do return NONE
	if c, constant := cover_of(s); constant {
		if !fits(l, x, c) do return fail(l, "membership in %s is not code yet", kernel.print_type(s))
		dst := value(l.f, .Int)
		l.f.kinds[dst].bounds = {0, 1}
		emit(l, In{dst, x, c})
		return dst
	}
	#partial switch v in s {
	case ^kernel.Range:
		out := NONE
		if v.lo != nil do out = both(l, .And, out, binary(l, .Ge, x, lower(l, v.lo), .Int))
		if v.hi != nil do out = both(l, .And, out, binary(l, .Le, x, lower(l, v.hi), .Int))
		return out
	case ^kernel.Or:
		out := NONE
		for term in v.terms do out = both(l, .Or, out, member(l, x, term))
		return out
	case ^kernel.And:
		out := NONE
		for term in v.terms do out = both(l, .And, out, member(l, x, term))
		return out
	case ^kernel.Not:
		return binary(l, .Xor, member(l, x, v.term), constant(l, 1), .Int)
	case ^kernel.Is:
		return member(l, x, v.term)
	case ^kernel.Unknown, ^kernel.Operation:
		if kernel.is_constant(s) do break // a set the laws left as an operation
		y := lower(l, s)
		if machine_of(l.f, y) != machine_of(l.f, x) do break
		return binary(l, .Eq, x, y, .Int)
	}
	return fail(l, "membership in %s is not code yet", kernel.print_type(s))
}

// both: a op b, a the first of the parts when NONE.
both :: proc(l: ^Lowering, op: Op, a, b: Value) -> Value {
	if a == NONE do return b
	return binary(l, op, a, b, .Int)
}

// match: the branches of a pattern on the target. A branch whose cover is not a
// set of constants is tested where it stands, after the covers above: in the arm
// that takes what they do not, as a match on its membership,
//
//   t ? {c₀ -> p₀  c₁ -> p₁ …} = t ? {c₀ -> p₀  -> t ? {c₁ -> p₁ …}}
//
// The last branch is not tested: the check proved that one takes every value.
match :: proc(l: ^Lowering, branches: []kernel.Branch, target: Value, tail: bool) -> Value {
	arms := make([dynamic]Arm)
	for b, i in branches {
		if i == len(branches) - 1 || b.cover == nil {
			// t ? {-> p} = p
			if i == 0 do return lower(l, b.product, tail)
			append(&arms, Arm{body = lower_body(l, b.product, tail)})
			break
		}
		cover, constant := cover_of(b.cover)
		if constant {
			if !fits(l, target, cover) do return fail(l, "a cover %s is not code yet", kernel.print_type(b.cover))
			append(&arms, Arm{cover, lower_body(l, b.product, tail)})
			continue
		}
		if i > 0 {
			append(&arms, Arm{body = rest_body(l, branches[i:], target, tail)})
			break
		}
		tested := member(l, target, b.cover)
		if l.error != "" do return NONE
		taken := make([]Bounds, 1)
		taken[0] = {1, 1}
		append(&arms, Arm{Cover{ints = taken}, lower_body(l, b.product, tail)})
		append(&arms, Arm{body = rest_body(l, branches[1:], target, tail)})
		return close_match(l, tested, arms[:])
	}
	return close_match(l, target, arms[:])
}

// rest_body: the branches from a cover the laws did not compute, as the body of
// the arm that takes what the covers above do not.
rest_body :: proc(l: ^Lowering, branches: []kernel.Branch, target: Value, tail: bool) -> (b: Body) {
	outer, bound := open_body(l, &b)
	b.value = match(l, branches, target, tail)
	close_body(l, outer, bound)
	return
}

// close_match: the match of these arms, its value that of the arm that runs: it
// has the bounds of all of them.
close_match :: proc(l: ^Lowering, target: Value, arms: []Arm) -> Value {
	if l.error != "" do return NONE
	dst := NONE
	for arm in arms {
		v := arm.body.value
		if v == NONE do continue
		if dst == NONE {
			dst = value(l.f, machine_of(l.f, v))
			l.f.kinds[dst].bounds = bounds_of(l.f, v)
			continue
		}
		if machine_of(l.f, v) != machine_of(l.f, dst) do return fail(l, "the arms of a match give %v and %v", machine_of(l.f, dst), machine_of(l.f, v))
		l.f.kinds[dst].bounds = hull(bounds_of(l.f, dst), bounds_of(l.f, v))
	}
	emit(l, Match{dst, target, arms})
	return dst
}

// cover_of: a set of constants as the kernel cut it, its cells — integers,
// characters and booleans as integers, or floats —; false when the set is not one.
cover_of :: proc(set: kernel.Type) -> (c: Cover, constant: bool) {
	if !kernel.is_constant(set) do return
	cells, negated := kernel.as_cells(set)
	if len(cells) == 0 do return
	c.negated = negated
	if ints, discrete := int_cells(cells); discrete {
		c.ints = ints
		return c, true
	}
	reals := make([dynamic]Interval)
	for x in cells {
		if kernel.cell_family(x) != .Real do return {}, false
		append(&reals, interval_of(kernel.real_bounds(x)))
	}
	c.reals = reals[:]
	return c, true
}

// fits: a cover tests a value of its family.
fits :: proc(l: ^Lowering, x: Value, c: Cover) -> bool {
	switch machine_of(l.f, x) {
	case .Int:
		return len(c.reals) == 0
	case .Real:
		return len(c.ints) == 0
	case .Text, .None:
	}
	return false
}

// int_cells: cells of integers, characters or booleans, as bounds; false when one
// is not.
int_cells :: proc(cells: []kernel.Type) -> (out: []Bounds, discrete: bool) {
	bounds := make([dynamic]Bounds)
	for x in cells {
		#partial switch kernel.cell_family(x) {
		case .Bool:
			v := i128(x.(kernel.Bool) ? 1 : 0)
			append(&bounds, Bounds{v, v})
		case .Int, .Char:
			lo, hi := kernel.discrete_bounds(x)
			append(&bounds, Bounds{lo.? or_else min(i128), hi.? or_else max(i128)})
		case:
			return nil, false
		}
	}
	return bounds[:], true
}

interval_of :: proc(b: kernel.Real_Bounds) -> Interval {
	out := Interval{lo = -inf_f64(), hi = inf_f64(), lo_open = b.lo_open, hi_open = b.hi_open}
	if lo, has := b.lo.?; has do out.lo = float_of(lo)
	if hi, has := b.hi.?; has do out.hi = float_of(hi)
	return out
}

inf_f64 :: proc() -> f64 {
	return transmute(f64)u64(0x7FF0_0000_0000_0000)
}

float_of :: proc(r: kernel.Real) -> f64 {
	return f64(r.num) / f64(r.den)
}

// term_bounds: the least and greatest integers t takes: those of its layout image,
// t with each unknown replaced by its layout (specs/types.md §7).
term_bounds :: proc(l: ^Lowering, t: kernel.Type) -> Bounds {
	image, ok := kernel.layout_image(l.k, t)
	if !ok do return EVERY
	if cells, negated := kernel.as_cells(image); !negated && len(cells) > 0 {
		if ints, discrete := int_cells(cells); discrete {
			out := ints[0]
			for x in ints[1:] do out = hull(out, x)
			return out
		}
	}
	// a set left as an operation on sets of integers: the results at their bounds
	lo, hi, known := kernel.int_bounds(l.k, image)
	if !known do return EVERY
	return Bounds{lo.? or_else min(i128), hi.? or_else max(i128)}
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
