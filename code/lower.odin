package code

import kernel "../kernel"
import "core:fmt"
import "core:slice"
import "core:strings"

// FROM THE NORMAL FORM TO CODE (specs/language/15)
//
// The type of a program is its normal form; its code is that form, read as
// instructions. A known value is a constant. An unknown that no effect gives back is
// an input of the program. An effect is run where it stands, in order: the call of a
// symbol behind a boundary is an instruction, and what it gives back is the value
// its answer stands for. A pattern is a match on its target, each cover the cells
// of a set the laws computed. A fold, the solution of a recursion, is a loop;
// a recursion that stays is a function, and its calls in tail position the loop of
// its body. A scope of fields is the values of its fields, in order — a field
// that is a scope, its own in turn —: a match, a loop, a call give them all, and
// a field read picks its own. What the laws could not reduce to one of these is
// not code yet, and says so.
//
// What the kernel proved comes along: each integer has the bounds of its layout
// image (specs/types.md §7), and an unknown an arm narrows, ?ₖ::(L & S), is read
// there through a Narrow.
//
// The code is the normal form, read: what is cheaper to compute — a power of a
// counter carried from turn to turn rather than computed again — is the algebra of
// computations' to say (code/calc).

Lowering :: struct {
	k:       ^kernel.Kernel,
	prog:    ^Program,
	f:       ^Func,
	insts:   ^[dynamic]Inst, // the body the instructions go to
	bound:   [dynamic]Bound, // in the body: the answers of its effects, the parameters, the narrowings, the terms computed
	inputs:  [dynamic]^kernel.Unknown,
	entry:   [dynamic]Inst, // the program's: the inputs, read once where it starts
	read:    [dynamic]Value, // the value of each input, read in the entry
	funcs:   [dynamic]Lowered, // the function of each recursive equation lowered, in each context
	self:    ^Self, // the function being lowered; nil in the program itself
	error:   string,
}

// Bound: what an unknown stands for in the code: the values an effect gave back, a
// parameter, or what an arm narrowed one of these to; or the values of a term
// computed.
Bound :: struct {
	unknown: ^kernel.Unknown,
	term:    kernel.Type,
	values:  []Value,
}

// Self: the equation of the function being lowered. A call of it in tail position
// is an Again of the loop of its body.
Self :: struct {
	using lowered: Lowered,
	again:         bool, // a call in tail position was lowered
}

// Lowered: the function of an equation, where what it emits is answered by these
// scopes, and by its handlers, those a carve replaced in place of its own
// (specs/types.md §4.9): an equation has a function in each context.
Lowered :: struct {
	root:     ^kernel.Scope,
	answered: []^kernel.Scope,
	handlers: map[^kernel.Binding]kernel.Type,
	through:  map[^kernel.Binding]^kernel.Scope, // a field the call gives a call of this equation: passed as its fields
	index:    int,
}

// lowered_for: the function of the equation the call c calls, in its context: the
// scopes that answer it, and the handlers its carve replaces.
lowered_for :: proc(l: ^Lowering, c: ^kernel.Collapse) -> (out: Lowered, ok: bool) {
	s := c.target.(^kernel.Scope) or_return
	out.root, out.answered = kernel.origin(s), c.answered
	out.handlers = make(map[^kernel.Binding]kernel.Type)
	out.through = make(map[^kernel.Binding]^kernel.Scope)
	for b, v in s.changes {
		if b.kind == .Handler do out.handlers[b] = v
		if g, is_call := called(v); is_call do out.through[b] = kernel.origin(g)
	}
	return out, true
}

// same_context: two functions of one equation, in one context.
same_context :: proc(l: ^Lowering, a, b: Lowered) -> bool {
	if a.root != b.root || !slice.equal(a.answered, b.answered) || len(a.handlers) != len(b.handlers) || len(a.through) != len(b.through) do return false
	for f, g in a.through do if b.through[f] != g do return false
	for h, v in a.handlers {
		w, found := b.handlers[h]
		if !found || !kernel.same(l.k, v, w) do return false
	}
	return true
}

// program_type: the program is the type of the file's production, its entry point:
// what it gives, with the effects it holds. The file is not collapsed: a binding of
// it runs only where the production holds it. A file without production is a
// program without main: none.
program_type :: proc(k: ^kernel.Kernel) -> kernel.Type {
	if p, found := kernel.first_production(k, k.root); found do return kernel.product(k, p)
	return kernel.None{}
}

// lower_program: the code of a file the kernel checked without error.
lower_program :: proc(k: ^kernel.Kernel) -> (prog: Program, err: string) {
	if len(k.errors) > 0 do return prog, "the program has errors"
	append(&prog.funcs, new_clone(Func{name = "main"}))
	l := Lowering{k = k, prog = &prog, f = prog.funcs[0]}
	l.f.body = lower_body(&l, program_type(k), false)
	if l.error != "" do return prog, l.error
	inject_at(&l.f.body.insts, 0, ..l.entry[:])
	l.f.results = machines_of(l.f, l.f.body.values)
	if len(l.f.results) > 1 do return prog, fmt.tprintf("the program gives %d values: a program that gives a scope is not code yet", len(l.f.results))
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

fail_values :: proc(l: ^Lowering, format: string, args: ..any) -> []Value {
	fail(l, format, ..args)
	return nil
}

// single: the values of x: x, or none for NONE.
single :: proc(x: Value) -> []Value {
	if x == NONE do return nil
	out := make([]Value, 1)
	out[0] = x
	return out
}

// machines_of: the machine of each value.
machines_of :: proc(f: ^Func, xs: []Value) -> []Machine {
	out := make([]Machine, len(xs))
	for x, i in xs do out[i] = machine_of(f, x)
	return out
}

// fresh: a value of the machine and the bounds of each of xs.
fresh :: proc(l: ^Lowering, xs: []Value) -> []Value {
	out := make([]Value, len(xs))
	for x, i in xs {
		out[i] = value(l.f, machine_of(l.f, x))
		l.f.kinds[out[i]].bounds = bounds_of(l.f, x)
	}
	return out
}

emit :: proc(l: ^Lowering, inst: Inst) {
	append(l.insts, inst)
}

constant :: proc(l: ^Lowering, x: i128) -> Value {
	if !in_word({x, x}) do return fail(l, "%v takes more than a word of 64 bits: not code yet", x)
	v := value(l.f, .Int)
	l.f.kinds[v].bounds = {x, x}
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
	b.values = lower_values(l, t, tail)
	close_body(l, outer, bound)
	return
}

// lower_values: the values of t: one for a number, none for none, those of its
// fields for a scope of fields. In tail position, nothing is computed after it: a
// call of the function being lowered is an Again. A value made for t, one, has the
// bounds of t.
lower_values :: proc(l: ^Lowering, t: kernel.Type, tail := false) -> []Value {
	if l.error != "" do return nil
	#reverse for b in l.bound do if b.term != nil && kernel.same(l.k, b.term, t) do return b.values
	first := Value(len(l.f.kinds))
	vs := term(l, t, tail)
	made := len(vs) > 0
	for v in vs do made &&= v >= first
	if made && len(vs) == 1 && machine_of(l.f, vs[0]) == .Int {
		l.f.kinds[vs[0]].bounds = meet(l.f.kinds[vs[0]].bounds, term_bounds(l, t))
	}
	// one term, its values: where it is computed, a pure term reads them again
	if made && computed(t) do append(&l.bound, Bound{term = t, values = vs})
	return vs
}

// lower: the value of t, where one is read — NONE for none.
lower :: proc(l: ^Lowering, t: kernel.Type, tail := false) -> Value {
	vs := lower_values(l, t, tail)
	switch len(vs) {
	case 0:
		return NONE
	case 1:
		return vs[0]
	}
	return fail(l, "%s gives %d values where one is read", kernel.print_type(t), len(vs))
}

// computed: a term that takes instructions to compute, without effect: the same
// term, read again, is the same value.
computed :: proc(t: kernel.Type) -> bool {
	#partial switch v in t {
	case ^kernel.Operation:
		return !kernel.is_string_value(t)
	case ^kernel.Pattern, ^kernel.Fold, ^kernel.Least, ^kernel.Series, ^kernel.Recurrent:
		return !kernel.has_effect(t)
	}
	return false
}

term :: proc(l: ^Lowering, t: kernel.Type, tail: bool) -> []Value {
	#partial switch v in t {
	case ^kernel.And:
		// t & S, t one value where it is in S: the value t
		for a in v.terms do if kernel.is_value(l.k, a) do return lower_values(l, a, tail)
	case kernel.Int:
		return single(constant(l, i128(v)))
	case kernel.Bool:
		return single(constant(l, v ? 1 : 0))
	case kernel.Char:
		return single(constant(l, i128(v)))
	case kernel.Real:
		r := value(l.f, .Real)
		emit(l, Real_Const{r, float_of(v)})
		return single(r)
	case kernel.None:
		return nil
	case ^kernel.Unknown:
		return unknown(l, v)
	case ^kernel.Operation:
		if kernel.is_string_value(t) {
			r := value(l.f, .Text)
			emit(l, Text_Const{r, text(l.prog, string_of(v))})
			return single(r)
		}
		if v.op == .Item do return item(l, v)
		return single(operation(l, v))
	case ^kernel.Scope:
		// a scope of fields: the values of its fields, in order
		out := make([dynamic]Value)
		given(l, v, &out)
		return out[:]
	case ^kernel.Access:
		return field(l, v)
	case ^kernel.Pattern:
		for b in v.branches[1:] do if !same_fields(l, v.branches[0].product, b.product) do return fail_values(l, "the branches of %s give scopes of other fields", kernel.print_type(t))
		target := lower(l, v.target)
		if l.error != "" do return nil
		return match(l, v.branches, target, tail)
	case ^kernel.Effect:
		return effect(l, v, tail)
	case ^kernel.Collapse:
		if !v.recursive do break
		if tail && is_self(l, v) do return again(l, v)
		return call(l, v)
	case ^kernel.Fold:
		return fold(l, v)
	case ^kernel.Least:
		return least(l, v)
	case ^kernel.Series:
		return series(l, v)
	case ^kernel.Recurrent:
		return recurrent(l, v)
	case kernel.Invalid:
		// a term the kernel gives no type to: why
		if v.problem != nil do return fail_values(l, "%s", v.problem.message)
	}
	return fail_values(l, "%s is not a value the code computes yet", kernel.print_type(t))
}

// unknown: the values an effect gave back, a parameter, or else an input of the
// program, numbered in the order they are first read. Where an arm narrowed it,
// ?ₖ::(L & S), it is read through a Narrow.
unknown :: proc(l: ^Lowering, u: ^kernel.Unknown) -> []Value {
	#reverse for b in l.bound do if b.unknown != nil && kernel.same_unknown(b.unknown, u) {
		if len(b.values) != 1 do return b.values
		return single(narrowed(l, u, b.unknown, b.values[0]))
	}
	m := machine_of_layout(l.k, kernel.layout_of(l.k, u))
	if m != .Int do return fail_values(l, "the input ?%d is not an integer", u.id)
	slot := len(l.inputs)
	for x, i in l.inputs do if kernel.same_unknown(x, u) do slot = i
	// an input, as it is written
	written := new_clone(u^)
	written.layout = nil
	if slot == len(l.inputs) {
		// read once, where the program starts
		append(&l.inputs, u)
		v := value(l.prog.funcs[0], .Int)
		l.prog.funcs[0].kinds[v].bounds = term_bounds(l, written)
		append(&l.entry, Input{v, slot})
		append(&l.read, v)
	}
	if l.f != l.prog.funcs[0] {
		// in a function: read where it is asked
		v := value(l.f, .Int)
		l.f.kinds[v].bounds = term_bounds(l, written)
		emit(l, Input{v, slot})
		append(&l.bound, Bound{unknown = written, values = single(v)})
		return single(narrowed(l, u, written, v))
	}
	return single(narrowed(l, u, written, l.read[slot]))
}

// narrowed: v, the value u stands for as it stood when it was bound, read where an
// arm narrowed its layout: through a Narrow, its bounds those of u there. What an
// arm proves is read through it, so that what is computed from it is computed in
// the arm, and nothing else holds facts of the arm alone.
narrowed :: proc(l: ^Lowering, u, bound: ^kernel.Unknown, v: Value) -> Value {
	if machine_of(l.f, v) != .Int || kernel.same(l.k, kernel.layout_of(l.k, u), kernel.layout_of(l.k, bound)) do return v
	dst := value(l.f, .Int)
	l.f.kinds[dst].bounds = meet(bounds_of(l.f, v), term_bounds(l, u))
	emit(l, Narrow{dst, v})
	append(&l.bound, Bound{unknown = u, values = single(dst)})
	return dst
}

// effect: an effect, run where it stands, then what it wraps. Only the call of a
// symbol behind a boundary is code: another effect is served by nothing.
effect :: proc(l: ^Lowering, e: ^kernel.Effect, tail: bool) -> []Value {
	if e.fold != nil {
		// a fold whose steps have effects: the loop, then what it wraps
		dst := fold(l, e.fold)
		if e.answer != nil do append(&l.bound, Bound{unknown = e.answer, values = dst})
		return lower_values(l, e.then, tail)
	}
	if e.choice != nil {
		// a choice whose branches have effects: the match, then what it wraps
		lower_values(l, e.choice)
		return lower_values(l, e.then, tail)
	}
	// a write: what follows already reads what it wrote (specs/types.md §4.14)
	if e.write != nil do return lower_values(l, e.then, tail)
	if e.emission != nil do return fail_values(l, "the emission of %s is answered by no handler", kernel.print_type(e.emission.sent))
	if e.call == nil do return fail_values(l, "the effect ε%d is served by no boundary", e.id)
	if e.call.recursive {
		// a call of an equation with effects: the call, then what it wraps — in tail
		// position when what it wraps is what the call gives back
		if tail && is_self(l, e.call) && gives_answer(e) do return again(l, e.call)
		dst := call(l, e.call)
		if e.answer != nil do append(&l.bound, Bound{unknown = e.answer, values = dst})
		return lower_values(l, e.then, tail)
	}
	s, is_scope := e.call.target.(^kernel.Scope)
	if !is_scope do return fail_values(l, "%s is not a call the code makes yet", kernel.print_type(e.call))
	lib, behind := kernel.symbol_of(s)
	if !behind do return fail_values(l, "%s is not a call the code makes yet", kernel.print_type(e.call))
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
		if l.error != "" do return nil
	}
	imp.args = machines[:]
	if e.answer != nil {
		if named(e.answer.written, "f32") do return fail_values(l, "%s gives back an f32: only f64 crosses a boundary yet", imp.symbol)
		layout := kernel.layout_of(l.k, e.answer)
		imp.result = machine_of_layout(l.k, layout)
		if imp.result == .None do return fail_values(l, "what %s gives back has no layout the code holds", imp.symbol)
		if imp.result == .Int do imp.result_bits, imp.result_signed = int_width(l.k, layout)
	}
	dst := imp.result == .None ? NONE : value(l.f, imp.result)
	if imp.result == .Int do l.f.kinds[dst].bounds = term_bounds(l, e.answer)
	emit(l, Foreign{dst, intern(l.prog, imp), args[:]})
	if e.answer != nil do append(&l.bound, Bound{unknown = e.answer, values = single(dst)})
	return lower_values(l, e.then, tail)
}

// fold: a fold (specs/types.md §5.6) as a loop on k and its states: k from start,
// each state from its init; while k is not in stop, the effects of a step, then
// the updates and the next k, which the loop takes again; where k stops, the value.
fold :: proc(l: ^Lowering, f: ^kernel.Fold) -> []Value {
	start := lower(l, f.start)
	if l.error != "" do return nil
	if machine_of(l.f, start) != .Int do return fail_values(l, "a fold whose orbit is not of integers is not code yet")
	params := make([dynamic]Value)
	starts := make([dynamic]Value)
	append(&params, value(l.f, .Int))
	append(&starts, start)
	for init in f.inits {
		v := lower(l, init)
		if l.error != "" do return nil
		append(&params, value(l.f, machine_of(l.f, v)))
		append(&starts, v)
	}
	loop := Loop{params = params[:], init = starts[:]}
	outer, bound := open_body(l, &loop.body)
	// k at the head of a turn: any point of the orbit, the last too; its layout,
	// out of stop, is the step's, read through a Narrow
	head := new_clone(f.index^)
	head.layout, head.written, head.call = nil, nil, nil
	append(&l.bound, Bound{unknown = head, values = single(params[0])})
	for x, i in f.states do append(&l.bound, Bound{unknown = x, values = single(params[i + 1])})
	arms := make([]Arm, 2)
	arms[0].body = lower_body(l, f.value, false)
	// arms[1] ends in an Again
	step_outer, step_bound := open_body(l, &arms[1].body)
	lower(l, f.effects)
	args := make([dynamic]Value)
	append(&args, NONE) // the next k, once the states are given
	for t, i in f.updates {
		x := lower(l, t)
		if l.error == "" && machine_of(l.f, x) != machine_of(l.f, params[i + 1]) do fail(l, "the update of a fold gives a %v, its state is a %v", machine_of(l.f, x), machine_of(l.f, params[i + 1]))
		append(&args, x)
	}
	args[0] = lower(l, f.next)
	emit(l, Again{args[:]})
	close_body(l, step_outer, step_bound)
	// where k stops: the cells of stop, or its membership
	target := params[0]
	if cover, constant := cover_of(f.stop); constant && fits(l, target, cover) {
		arms[0].cover = cover
	} else {
		target = member(l, target, f.stop)
		taken := make([]Bounds, 1)
		taken[0] = {1, 1}
		arms[0].cover = Cover{ints = taken}
	}
	loop.body.values = close_match(l, target, arms)
	return close_loop(l, loop, outer, bound)
}

// close_loop: the loop, its body closed: its values those of its body.
close_loop :: proc(l: ^Lowering, loop: Loop, outer: ^[dynamic]Inst, bound: int) -> []Value {
	loop := loop
	close_body(l, outer, bound)
	if l.error != "" do return nil
	loop.dst = fresh(l, loop.body.values)
	emit(l, loop)
	return loop.dst
}

// least: μ(i: t) (specs/types.md §5.6) as a loop: i from 0, until t holds.
least :: proc(l: ^Lowering, m: ^kernel.Least) -> []Value {
	params, starts := make([]Value, 1), make([]Value, 1)
	starts[0] = constant(l, 0)
	params[0] = value(l.f, .Int)
	l.f.kinds[params[0]].bounds = {0, max(i128)}
	loop := Loop{params = params, init = starts}
	outer, bound := open_body(l, &loop.body)
	append(&l.bound, Bound{unknown = m.index, values = single(params[0])})
	holds := lower(l, m.holds)
	arms := make([]Arm, 2)
	taken := make([]Bounds, 1)
	taken[0] = {1, 1}
	arms[0] = Arm{cover = Cover{ints = taken}, body = Body{insts = make([dynamic]Inst), values = single(params[0])}}
	// arms[1] ends in an Again
	step_outer, step_bound := open_body(l, &arms[1].body)
	next := make([]Value, 1)
	next[0] = binary(l, .Add, params[0], constant(l, 1), .Int)
	emit(l, Again{next})
	close_body(l, step_outer, step_bound)
	loop.body.values = close_match(l, holds, arms)
	return close_loop(l, loop, outer, bound)
}

// series: Σ(i: lo..hi, t) or Π (specs/types.md §5.6) as a loop: i from lo, the
// accumulator from 0 or 1; while i ≤ hi, it takes t, and i the next integer.
series :: proc(l: ^Lowering, s: ^kernel.Series) -> []Value {
	lo, hi := lower(l, s.lo), lower(l, s.hi)
	if l.error != "" do return nil
	machine := machine_of_layout(l.k, kernel.layout_image(l.k, s.term) or_else nil)
	if machine != .Int && machine != .Real do machine = .Int
	identity := s.op == .Add ? 0 : 1
	start: Value
	if machine == .Real {
		start = value(l.f, .Real)
		emit(l, Real_Const{start, f64(identity)})
	} else {
		start = constant(l, i128(identity))
	}
	params, starts := make([]Value, 2), make([]Value, 2)
	params[0], params[1] = value(l.f, .Int), value(l.f, machine)
	starts[0], starts[1] = lo, start
	loop := Loop{params = params, init = starts}
	outer, bound := open_body(l, &loop.body)
	append(&l.bound, Bound{unknown = s.index, values = single(params[0])})
	past := binary(l, .Gt, params[0], hi, .Int)
	arms := make([]Arm, 2)
	taken := make([]Bounds, 1)
	taken[0] = {1, 1}
	arms[0] = Arm{cover = Cover{ints = taken}, body = Body{insts = make([dynamic]Inst), values = single(params[1])}}
	// arms[1] ends in an Again
	step_outer, step_bound := open_body(l, &arms[1].body)
	// in a step, lo ≤ i ≤ hi: i from lo, by 1, not past hi
	index := value(l.f, .Int)
	l.f.kinds[index].bounds = {bounds_of(l.f, lo).lo, bounds_of(l.f, hi).hi}
	emit(l, Narrow{index, params[0]})
	append(&l.bound, Bound{unknown = s.index, values = single(index)})
	t := lower(l, s.term)
	if l.error == "" && machine_of(l.f, t) != machine do fail(l, "the term of a series is a %v, its value a %v", machine_of(l.f, t), machine)
	next := make([]Value, 2)
	next[0] = binary(l, .Add, params[0], constant(l, 1), .Int)
	next[1] = binary(l, s.op == .Add ? .Add : .Mul, params[1], t, machine)
	emit(l, Again{next})
	close_body(l, step_outer, step_bound)
	loop.body.values = close_match(l, past, arms)
	return close_loop(l, loop, outer, bound)
}

// recurrent: C⟨c₁ … c_d | x₀ … x_{d-1}⟩(s) (specs/types.md §5.6): αˢ in ℤ[α] by
// squaring — a loop on the bits of s, whose turn multiplies the result by the
// base when the bit is 1, then squares the base —, and Σ_j x_j·[αˢ]_j.
recurrent :: proc(l: ^Lowering, r: ^kernel.Recurrent) -> []Value {
	d := len(r.coefficients)
	s := lower(l, r.at)
	initial := make([]Value, d)
	for t, j in r.initial do initial[j] = lower(l, t)
	if l.error != "" do return nil
	params, starts := make([dynamic]Value), make([dynamic]Value)
	append(&params, value(l.f, .Int))
	append(&starts, s)
	result, base := make([]Value, d), make([]Value, d)
	for j in 0 ..< d {
		result[j] = value(l.f, .Int)
		append(&params, result[j])
		append(&starts, constant(l, j == 0 ? 1 : 0))
	}
	for j in 0 ..< d {
		base[j] = value(l.f, .Int)
		append(&params, base[j])
		alpha: i128 = d == 1 ? i128(r.coefficients[0]) : (j == 1 ? 1 : 0)
		append(&starts, constant(l, alpha))
	}
	loop := Loop{params = params[:], init = starts[:]}
	outer, bound := open_body(l, &loop.body)
	arms := make([]Arm, 2)
	done := make([]Bounds, 1)
	done[0] = {0, 0}
	arms[0].cover = Cover{ints = done}
	exit_outer, exit_bound := open_body(l, &arms[0].body)
	sum := binary(l, .Mul, initial[0], result[0], .Int)
	for j in 1 ..< d do sum = binary(l, .Add, sum, binary(l, .Mul, initial[j], result[j], .Int), .Int)
	arms[0].body.values = single(sum)
	close_body(l, exit_outer, exit_bound)
	// arms[1] ends in an Again
	step_outer, step_bound := open_body(l, &arms[1].body)
	odd := binary(l, .And, params[0], constant(l, 1), .Int)
	product := algebraic_product(l, result, base, r.coefficients)
	next := make([dynamic]Value)
	append(&next, binary(l, .Shr, params[0], constant(l, 1), .Int))
	// the result times the base when the bit is 1: x + odd·(x·b - x)
	for j in 0 ..< d do append(&next, binary(l, .Add, result[j], binary(l, .Mul, odd, binary(l, .Sub, product[j], result[j], .Int), .Int), .Int))
	append(&next, ..algebraic_product(l, base, base, r.coefficients))
	emit(l, Again{next[:]})
	close_body(l, step_outer, step_bound)
	loop.body.values = close_match(l, params[0], arms)
	return close_loop(l, loop, outer, bound)
}

// algebraic_product: a·b in ℤ[α]: the product of the polynomials, reduced by
// α^d = c₁·α^{d-1} + … + c_d from the highest power down.
algebraic_product :: proc(l: ^Lowering, a, b: []Value, c: []i128) -> []Value {
	d := len(c)
	full := make([]Value, 2 * d - 1)
	for &x in full do x = NONE
	for x, i in a do for y, j in b {
		p := binary(l, .Mul, x, y, .Int)
		full[i + j] = full[i + j] == NONE ? p : binary(l, .Add, full[i + j], p, .Int)
	}
	#reverse for _, t in full {
		if t < d do break
		for cj, j in c {
			if cj == 0 do continue
			p := binary(l, .Mul, full[t], constant(l, i128(cj)), .Int)
			full[t - 1 - j] = full[t - 1 - j] == NONE ? p : binary(l, .Add, full[t - 1 - j], p, .Int)
		}
	}
	out := make([]Value, d)
	for j in 0 ..< d do out[j] = full[j] == NONE ? constant(l, 0) : full[j]
	return out
}

// gives_answer: what the effect wraps is what it gives back.
gives_answer :: proc(e: ^kernel.Effect) -> bool {
	if e.answer == nil do return kernel.is_none(e.then)
	u, is_unknown := e.then.(^kernel.Unknown)
	return is_unknown && kernel.same_unknown(u, e.answer)
}

// is_self: c is a call of the function being lowered, in its context.
is_self :: proc(l: ^Lowering, c: ^kernel.Collapse) -> bool {
	if l.self == nil do return false
	called, ok := lowered_for(l, c)
	return ok && same_context(l, called, l.self)
}

// call: a recursive call that stays, as the call of the function of its equation:
// the values it gives.
call :: proc(l: ^Lowering, c: ^kernel.Collapse) -> []Value {
	index, args := arguments(l, c)
	if l.error != "" do return nil
	results := l.prog.funcs[index].results
	dst := make([]Value, len(results))
	for m, i in results do dst[i] = value(l.f, m)
	// what the call gives: the bounds of its image, the recursion of its bounds
	// (specs/types.md §5.6)
	if len(results) == 1 && results[0] == .Int do l.f.kinds[dst[0]].bounds = term_bounds(l, c)
	emit(l, Call{dst, index, args})
	return dst
}

// again: a call of the function being lowered, in tail position: its parameters
// take the values the carve gives, and its body runs again.
again :: proc(l: ^Lowering, c: ^kernel.Collapse) -> []Value {
	_, args := arguments(l, c)
	if l.error != "" do return nil
	emit(l, Again{args})
	l.self.again = true
	return nil
}

// arguments: the function of the equation c carves, and the values the carve
// gives its fields.
arguments :: proc(l: ^Lowering, c: ^kernel.Collapse) -> (index: int, args: []Value) {
	s, is_scope := c.target.(^kernel.Scope)
	if !is_scope {
		fail(l, "%s is not a call the code makes yet", kernel.print_type(c))
		return
	}
	index = function_of(l, c)
	if l.error != "" do return
	out := make([dynamic]Value)
	params := l.prog.funcs[index].params
	this, _ := lowered_for(l, c)
	for b in s.bindings {
		if !is_parameter(l, b) do continue
		start := len(out)
		v := kernel.binding_value(l.k, b)
		if g, through := called(v); through && this.through[b.source] != nil {
			for x in g.bindings do if is_parameter(l, x) do given(l, kernel.binding_value(l.k, x), &out)
		} else {
			given(l, v, &out)
		}
		if l.error != "" do return
		for a, i in out[start:] {
			if start + i >= len(params) || machine_of(l.f, a) != params[start + i] {
				fail(l, "the field `%s` of %s is given a %v", b.name, kernel.print_type(c), machine_of(l.f, a))
				return
			}
		}
	}
	if len(out) != len(params) do fail(l, "%s gives %d values to %d parameters", kernel.print_type(c), len(out), len(params))
	return index, out[:]
}

// is_parameter: a field of an equation: a binding that is not run — it has no effect
// and emits nothing, in the equation as written —, so a call gives it a value.
is_parameter :: proc(l: ^Lowering, b: ^kernel.Binding) -> bool {
	return (b.kind == .Push || b.kind == .Pull) && !kernel.has_effect(kernel.binding_type(l.k, kernel.as_written(b)))
}

// function_of: the function of a recursive equation, lowered once (specs/language/15):
// its fields are its parameters, each an unknown of its layout — its color, or else
// the family of its value —, its results what its calls give, and its body the
// normal form of its production over them, its own calls left as calls. When some
// are in tail position, the body is a loop on the parameters.
function_of :: proc(l: ^Lowering, c: ^kernel.Collapse) -> int {
	this, _ := lowered_for(l, c)
	for x in l.funcs do if same_context(l, x, this) do return x.index
	root := this.root
	results := make([dynamic]Machine)
	results_of(l, c, &results)
	if l.error != "" do return -1
	f := new_clone(Func{name = root.name != "" ? root.name : "equation", pure = !root.effectful, results = results[:]})
	index := len(l.prog.funcs)
	append(&l.prog.funcs, f)
	this.index = index
	append(&l.funcs, this)
	// the handlers the carve replaced answer its emissions in place of its own
	changes := make(map[^kernel.Binding]kernel.Type)
	for h, v in this.handlers do changes[h] = v
	params := make([dynamic]^kernel.Unknown)
	machines := make([dynamic]Machine)
	for b in root.bindings {
		if !is_parameter(l, b) do continue
		changes[b] = parameter(l, b, f.name, &params, &machines, this.through[b])
		if l.error != "" do return index
	}
	f.params = machines[:]
	generic, is_scope := kernel.derive(l.k, root, changes, root.span).(^kernel.Scope)
	if !is_scope do return int(fail(l, "the equation of %s does not take its fields as parameters", f.name))
	p, has := kernel.first_production(l.k, generic)
	if !has do return int(fail(l, "%s has no production", f.name))
	// the effects above the production are run by the call, where it is collapsed
	body := kernel.product(l.k, p)
	// what the equation emits is answered where the call is collapsed, then by the
	// program (specs/types.md §4.9)
	for s in c.answered do body = kernel.answered(l.k, body, s)
	body = kernel.answered_by_program(l.k, body)
	// the body, in the function
	outer, outer_bound, outer_self, outer_insts := l.f, l.bound, l.self, l.insts
	self := Self{lowered = this}
	l.f, l.bound, l.self = f, make([dynamic]Bound), &self
	values := make([]Value, len(params))
	for u, i in params {
		values[i] = value(f, machines[i])
		if machines[i] == .Int do f.kinds[values[i]].bounds = term_bounds(l, u)
		append(&l.bound, Bound{unknown = u, values = single(values[i])})
	}
	f.body = lower_body(l, body, true)
	if self.again {
		loop := Loop{dst = fresh(l, f.body.values), params = values, init = values, body = f.body}
		f.body = Body{values = loop.dst}
		append(&f.body.insts, loop)
	}
	if gives := machines_of(f, f.body.values); l.error == "" && !slice.equal(gives, f.results) do fail(l, "%s gives %v, its calls %v", f.name, gives, f.results)
	l.f, l.bound, l.self, l.insts = outer, outer_bound, outer_self, outer_insts
	return index
}

// results_of: the machine of each value t gives, as the kernel types it: those of
// the fields of the scope it gives, in turn, or the one of its family.
results_of :: proc(l: ^Lowering, t: kernel.Type, out: ^[dynamic]Machine) {
	if s, has := shape_of(l, t); has {
		fields, _ := fields_of(l, s)
		for x in fields do results_of(l, kernel.binding_value(l.k, x), out)
		return
	}
	family, known := kernel.family_of(l.k, t)
	if !known {
		fail(l, "%s has no family the code holds", kernel.print_type(t))
		return
	}
	if m := machine_of_layout(l.k, kernel.family_term(family)); m != .None do append(out, m)
}

// shape_of: the scope of fields whose values t gives: t itself; the field of it a
// read picks; what the branches of a pattern give, what an effect wraps, what the
// call an answer stands for gives; for a recursive call, a base case of its
// equation: by induction, every call gives a scope of its fields (specs/types.md
// §5.6).
shape_of :: proc(l: ^Lowering, t: kernel.Type) -> (shape: ^kernel.Scope, ok: bool) {
	#partial switch v in t {
	case ^kernel.Scope:
		_, fields := fields_of(l, v)
		return v, fields
	case ^kernel.Access:
		fields, _ := fields_of(l, shape_of(l, v.target) or_return)
		b := kernel.occurrence(fields, v.name, v.ordinal, true) or_return
		return shape_of(l, kernel.binding_value(l.k, b))
	case ^kernel.Operation:
		at, known := v.args[1].(kernel.Int)
		if v.op != .Item || !known do break
		fields, _ := fields_of(l, shape_of(l, v.args[0]) or_return)
		if int(at) >= len(fields) do break
		return shape_of(l, kernel.binding_value(l.k, fields[at]))
	case ^kernel.Pattern:
		for b in v.branches do if s, has := shape_of(l, b.product); has do return s, true
	case ^kernel.Effect:
		return shape_of(l, v.then)
	case ^kernel.Unknown:
		if v.call != nil do return shape_of(l, v.call)
	case ^kernel.Collapse:
		if !kernel.gives_scopes(l.k, v) do break
		root := kernel.origin(v.target.(^kernel.Scope))
		p, _ := kernel.first_production(l.k, root)
		return shape_of(l, kernel.base_cases(kernel.binding_type(l.k, p), root)[0])
	}
	return nil, false
}

// same_fields: a and b give scopes of the same fields, by name and in order — or
// neither gives one.
same_fields :: proc(l: ^Lowering, a, b: kernel.Type) -> bool {
	s, has_s := shape_of(l, a)
	r, has_r := shape_of(l, b)
	if !has_s || !has_r do return has_s == has_r
	xs, _ := fields_of(l, s)
	ys, _ := fields_of(l, r)
	if len(xs) != len(ys) do return false
	for x, i in xs do if x.name != ys[i].name || !same_fields(l, kernel.binding_value(l.k, x), kernel.binding_value(l.k, ys[i])) do return false
	return true
}

// fields_of: the fields of a scope of fields, in order — not its holes —; false
// for a scope that is not only fields.
fields_of :: proc(l: ^Lowering, s: ^kernel.Scope) -> ([]^kernel.Binding, bool) {
	out := make([dynamic]^kernel.Binding)
	for x in kernel.placed(l.k, s, .Value) {
		#partial switch x.kind {
		case .Push:
			append(&out, x)
		case .Pull:
		case:
			return nil, false
		}
	}
	return out[:], true
}

// field: x.a (access_law): the values of the field a, its last occurrence or the
// one numbered, among those x gives.
field :: proc(l: ^Lowering, a: ^kernel.Access) -> []Value {
	s, has := shape_of(l, a.target)
	if !has do return fail_values(l, "%s is not a value the code computes yet", kernel.print_type(a))
	fields, _ := fields_of(l, s)
	b, found := kernel.occurrence(fields, a.name, a.ordinal, true)
	if !found do return fail_values(l, "%s has no field `%s`", kernel.print_type(a.target), a.name)
	return part(l, lower_values(l, a.target), fields, b)
}

// item: x.#k (run_law): the values of the binding k of the run x — at a k the
// program reads, a match on k, each arm a binding.
item :: proc(l: ^Lowering, o: ^kernel.Operation) -> []Value {
	s, has := shape_of(l, o.args[0])
	if !has do return fail_values(l, "%s is not lowered yet", kernel.print_type(o))
	run, _ := fields_of(l, s)
	all := lower_values(l, o.args[0])
	if at, known := o.args[1].(kernel.Int); known {
		if int(at) >= len(run) do return fail_values(l, "%s has no binding %d", kernel.print_type(o.args[0]), at)
		return part(l, all, run, run[at])
	}
	index := lower(l, o.args[1])
	if l.error != "" do return nil
	arms := make([]Arm, len(run))
	for b, k in run {
		cell := make([]Bounds, 1)
		cell[0] = {i128(k), i128(k)}
		arms[k] = Arm{Cover{ints = cell}, Body{insts = make([dynamic]Inst), values = part(l, all, run, b)}}
	}
	return close_match(l, index, arms)
}

// part: the values of the field b among all, the values of the fields in turn.
part :: proc(l: ^Lowering, all: []Value, fields: []^kernel.Binding, b: ^kernel.Binding) -> []Value {
	at := 0
	for x in fields {
		counted := make([dynamic]Machine)
		results_of(l, kernel.binding_value(l.k, x), &counted)
		if x == b && at + len(counted) <= len(all) do return all[at:][:len(counted)]
		at += len(counted)
	}
	return fail_values(l, "the field `%s` is not among the values given", b.name)
}

// parameter: the value of the field b of a function, over its parameters: an
// unknown of its layout — its color, or else the family of its value. A scope of
// fields is passed as its fields: its value is that scope, each field a parameter
// in turn; its holes are its type, as they are (specs/language/09).
parameter :: proc(l: ^Lowering, b: ^kernel.Binding, name: string, params: ^[dynamic]^kernel.Unknown, machines: ^[dynamic]Machine, through: ^kernel.Scope = nil) -> kernel.Type {
	// a call of the equation g: g's fields are the parameters
	if through != nil {
		changes := make(map[^kernel.Binding]kernel.Type)
		for x in through.bindings {
			if !is_parameter(l, x) do continue
			changes[x] = parameter(l, x, name, params, machines)
			if l.error != "" do return nil
		}
		g, is_scope := kernel.derive(l.k, through, changes, through.span).(^kernel.Scope)
		if !is_scope do return fail_type(l, "the field `%s` of %s does not take the fields of %s", b.name, name, through.name)
		return kernel.recursive_call(l.k, g, through.span)
	}
	if s, fields := scope_of_fields(l, b); fields {
		changes := make(map[^kernel.Binding]kernel.Type)
		for x in kernel.placed(l.k, s, .Value) {
			if x.kind == .Pull do continue
			changes[x] = parameter(l, x, name, params, machines)
			if l.error != "" do return nil
		}
		return kernel.derive(l.k, s, changes, s.span)
	}
	layout := kernel.binding_color(l.k, b)
	if layout == nil {
		family, has := kernel.family_of(l.k, kernel.binding_value(l.k, b))
		if !has {
			fail(l, "the field `%s` of %s is not a value the code passes", b.name, name)
			return nil
		}
		layout = kernel.family_term(family)
	}
	m := machine_of_layout(l.k, layout)
	if m == .None {
		fail(l, "the field `%s` of %s is not a value the code passes", b.name, name)
		return nil
	}
	u := kernel.new_unknown(l.k, layout)
	append(params, u)
	append(machines, m)
	return u
}

// scope_of_fields: the scope a binding holds — its color when that is a scope,
// otherwise its value —, when it is only fields.
scope_of_fields :: proc(l: ^Lowering, b: ^kernel.Binding) -> (^kernel.Scope, bool) {
	s, is_scope := kernel.binding_color(l.k, b).(^kernel.Scope)
	if !is_scope do s, is_scope = kernel.binding_value(l.k, b).(^kernel.Scope)
	if !is_scope do return nil, false
	for x in kernel.placed(l.k, s, .Value) do if !is_parameter(l, x) do return nil, false
	return s, true
}

// given: the values of a field, a scope of fields, the values of its fields in
// turn — not its holes.
given :: proc(l: ^Lowering, t: kernel.Type, out: ^[dynamic]Value) {
	if s, is_scope := t.(^kernel.Scope); is_scope {
		fields, ok := fields_of(l, s)
		if !ok {
			fail(l, "%s is not a value the code computes yet", kernel.print_type(t))
			return
		}
		for x in fields do given(l, kernel.binding_value(l.k, x), out)
		return
	}
	append(out, ..lower_values(l, t))
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
		if x.size < 8 do v = binary(l, .And, v, constant(l, i128(1) << uint(8 * x.size) - 1), .Int)
		if x.offset > start do v = binary(l, .Shl, v, constant(l, i128(8 * (x.offset - start))), .Int)
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
	.Pow        = .Pow,
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
	.Round      = .Add, // not used: a rounding is lowered by its width
	.Length     = .Add, // not used: not lowered yet
	.Item       = .Add,
	.From       = .Add,
}

operation :: proc(l: ^Lowering, o: ^kernel.Operation) -> Value {
	if o.op == .In do return member(l, lower(l, o.args[0]), o.args[1])
	// a real is computed in 64 bits: rounding to them is what each operation does
	if o.op == .Round {
		if bits, is_int := o.args[1].(kernel.Int); is_int && bits == 64 do return lower(l, o.args[0])
		return fail(l, "%s: the reals of 16 and 32 bits are not lowered yet", kernel.print_type(o))
	}
	if o.op == .Length || o.op == .Item || o.op == .From do return fail(l, "%s is not lowered yet", kernel.print_type(o))
	args := make([dynamic]Value)
	for a in o.args {
		append(&args, lower(l, a))
		if l.error != "" do return NONE
	}
	m := machine_of(l.f, args[0])
	// a power takes an integer count, whatever its base
	for a, i in args do if machine_of(l.f, a) != (o.op == .Pow && i == 1 ? .Int : m) do return fail(l, "%s mixes %v and %v", kernel.print_type(o), m, machine_of(l.f, a))
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
match :: proc(l: ^Lowering, branches: []kernel.Branch, target: Value, tail: bool) -> []Value {
	arms := make([dynamic]Arm)
	for b, i in branches {
		if i == len(branches) - 1 || b.cover == nil {
			// t ? {-> p} = p
			if i == 0 do return lower_values(l, b.product, tail)
			append(&arms, Arm{body = lower_body(l, b.product, tail)})
			break
		}
		cover, constant := cover_of(b.cover)
		if constant {
			if !fits(l, target, cover) do return fail_values(l, "a cover %s is not code yet", kernel.print_type(b.cover))
			append(&arms, Arm{cover, lower_body(l, b.product, tail)})
			continue
		}
		if i > 0 {
			append(&arms, Arm{body = rest_body(l, branches[i:], target, tail)})
			break
		}
		tested := member(l, target, b.cover)
		if l.error != "" do return nil
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
	b.values = match(l, branches, target, tail)
	close_body(l, outer, bound)
	return
}

// close_match: the match of these arms, its values those of the arm that runs:
// each has the bounds of all of them. An arm that ends in an Again gives none.
close_match :: proc(l: ^Lowering, target: Value, arms: []Arm) -> []Value {
	if l.error != "" do return nil
	dst: []Value
	for arm in arms {
		vs := arm.body.values
		if len(vs) == 0 do continue
		if dst == nil {
			dst = fresh(l, vs)
			continue
		}
		if len(vs) != len(dst) do return fail_values(l, "the arms of a match give %d and %d values", len(dst), len(vs))
		for v, i in vs {
			if machine_of(l.f, v) != machine_of(l.f, dst[i]) do return fail_values(l, "the arms of a match give %v and %v", machine_of(l.f, dst[i]), machine_of(l.f, v))
			l.f.kinds[dst[i]].bounds = hull(bounds_of(l.f, dst[i]), bounds_of(l.f, v))
		}
	}
	emit(l, Match{dst, target, arms})
	return dst
}

// cover_of: a set of constants as the kernel cut it, its cells — integers,
// characters and booleans as integers, or floats —; false when the set is not one.
cover_of :: proc(set: kernel.Type) -> (c: Cover, constant: bool) {
	if !kernel.is_constant(set) do return
	one: [1]kernel.Type
	cells, negated := kernel.cells_in(set, &one)
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
	one: [1]kernel.Type
	if cells, negated := kernel.cells_in(image, &one); !negated && len(cells) > 0 {
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

// called: t is a call of a recursive equation, the carve it calls.
called :: proc(t: kernel.Type) -> (^kernel.Scope, bool) {
	c, is_call := t.(^kernel.Collapse)
	if !is_call || !c.recursive do return nil, false
	return c.target.(^kernel.Scope)
}

fail_type :: proc(l: ^Lowering, format: string, args: ..any) -> kernel.Type {
	fail(l, format, ..args)
	return nil
}
