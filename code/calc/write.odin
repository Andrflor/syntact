package code_calc

import code ".."
import "core:fmt"

// THE NORMAL FORM, WRITTEN AS CODE
//
// Each class reached, by its computation of least cost, written once in its region,
// after what it reads: a match with its arms, a loop with its body, each region
// open while what runs in it is written.

Writer :: struct {
	p:       ^Plan,
	g:       ^Graph,
	f:       ^code.Func,
	values:  []code.Value, // per class, once written
	written: []bool,
	open:    [dynamic]Open, // the regions being written, innermost last
	loops:   [dynamic]int, // the loops whose body is being written, innermost last
	error:   string,
}

Open :: struct {
	region: Region,
	insts:  ^[dynamic]code.Inst,
}

// optimize: the program, each function as the normal form of its computations on a
// machine.
optimize :: proc(p: ^code.Program, costs: ^Costs) -> (out: code.Program, err: string) {
	out = code.Program{imports = p.imports, texts = p.texts, inputs = p.inputs}
	for f in p.funcs {
		g, value, state := read(p, f)
		rebuild(g)
		plan := plan(g, extract(g, costs), {value, state})
		if plan.error != "" do return out, fmt.tprintf("%s: %s", f.name, plan.error)
		written, msg := write_function(plan, f, value, state)
		if msg != "" do return out, fmt.tprintf("%s: %s", f.name, msg)
		append(&out.funcs, written)
	}
	return out, ""
}

write_function :: proc(p: ^Plan, f: ^code.Func, value, state: Class) -> (out: ^code.Func, err: string) {
	g := p.g
	out = new_clone(code.Func{name = f.name, pure = f.pure, params = f.params, result = f.result})
	for _, j in f.params do append(&out.kinds, f.kinds[j])
	w := Writer{p = p, g = g, f = out, values = make([]code.Value, len(g.parent)), written = make([]bool, len(g.parent))}
	append(&w.open, Open{ROOT, &out.body.insts})
	ensure(&w, state)
	out.body.value = value == NO_CLASS ? code.NONE : ensure(&w, value)
	return out, w.error
}

// fresh: a new value of the function, with the facts of c.
fresh :: proc(w: ^Writer, c: Class) -> code.Value {
	facts := w.g.facts[find(w.g, c)]
	v := code.value(w.f, facts.machine)
	if facts.machine == .Int do w.f.kinds[v].bounds = facts.bounds
	return v
}

// emit: the instruction of c, in the region c is placed in.
emit :: proc(w: ^Writer, c: Class, inst: code.Inst) {
	r := w.p.place[find(w.g, c)]
	#reverse for o in w.open {
		if o.region == r {
			append(o.insts, inst)
			return
		}
	}
	if w.error == "" do w.error = fmt.tprintf("a %v is placed in a region not written", chosen(w.p, c).kind)
}

// here: the instruction, in the region being written.
here :: proc(w: ^Writer, inst: code.Inst) {
	append(w.open[len(w.open) - 1].insts, inst)
}

// done: c is the value v.
done :: proc(w: ^Writer, c: Class, v: code.Value) -> code.Value {
	c := find(w.g, c)
	w.values[c], w.written[c] = v, true
	return v
}

// gives: the class of what the tuple t gives at index, when it is read.
gives :: proc(w: ^Writer, t: Class, index: int) -> (Class, bool) {
	return w.p.gets[Get_Key{find(w.g, t), index}]
}

values_of :: proc(w: ^Writer, cs: []Class) -> []code.Value {
	out := make([dynamic]code.Value)
	for c in cs {
		v := ensure(w, c)
		if v != code.NONE do append(&out, v)
	}
	return out[:]
}

// ensure: the value of c, written where it is placed when it is not yet.
ensure :: proc(w: ^Writer, c: Class) -> code.Value {
	g := w.g
	c := find(g, c)
	if c == NO_CLASS || w.error != "" do return code.NONE
	if w.written[c] do return w.values[c]
	n := chosen(w.p, c)^
	switch n.kind {
	case .Start, .Arm:
		return done(w, c, code.NONE)
	case .Argument:
		return done(w, c, code.Value(n.index))
	case .Param:
		w.error = "a parameter read outside its loop"
		return code.NONE
	case .Get:
		ensure(w, n.args[0])
		if !w.written[c] do w.error = "what a node gives is not written"
		return w.values[c]
	case .Again, .Exit:
		w.error = "a tail read outside the body of its loop"
		return code.NONE
	case .Match:
		write_match(w, c, n)
		return w.values[c]
	case .Loop:
		write_loop(w, c, n)
		return w.values[c]
	case .Foreign, .Call:
		if pinned(w.p, n) {
			ensure(w, n.args[0]) // the effects before
			args := values_of(w, n.args[1:])
			answer, read := gives(w, c, 1)
			dst := read ? fresh(w, answer) : code.NONE
			if n.kind == .Foreign do emit(w, c, code.Foreign{dst, n.index, args})
			else do emit(w, c, code.Call{dst, n.index, args})
			if state, has := gives(w, c, 0); has do done(w, state, code.NONE)
			if read do done(w, answer, dst)
			return done(w, c, code.NONE)
		}
	case .Int, .Real, .Text, .Input, .Unary, .Binary, .In, .Narrow:
	}
	args := values_of(w, n.args)
	dst := fresh(w, c)
	inst: code.Inst
	#partial switch n.kind {
	case .Int:
		inst = code.Const{dst, n.value}
	case .Real:
		inst = code.Real_Const{dst, transmute(f64)n.value}
	case .Text:
		inst = code.Text_Const{dst, n.index}
	case .Input:
		inst = code.Input{dst, n.index}
	case .Unary:
		inst = code.Unary{dst, args[0], n.op}
	case .Binary:
		inst = code.Binary{dst, args[0], args[1], n.op}
	case .In:
		inst = code.In{dst, args[0], g.covers[n.index]}
	case .Narrow:
		inst = code.Narrow{dst, args[0]}
	case .Call:
		inst = code.Call{dst, n.index, args}
	}
	emit(w, c, inst)
	return done(w, c, dst)
}

// write_match: a match whose arms give a value, or effects, or both.
write_match :: proc(w: ^Writer, c: Class, n: Node) {
	info := w.g.matches[n.owner]
	target := ensure(w, n.args[0])
	first := 1
	if info.state {
		ensure(w, n.args[1])
		first = 2
	}
	per := (info.value ? 1 : 0) + (info.state ? 1 : 0)
	value, read := gives(w, c, 0)
	read &&= info.value
	dst := read ? fresh(w, value) : code.NONE
	arms := make([]code.Arm, len(info.covers))
	for &arm, k in arms {
		arm.cover = info.covers[k]
		arm.body.value = code.NONE
		append(&w.open, Open{Region{.Arm, n.owner, k}, &arm.body.insts})
		outs := n.args[first + k * per:][:per]
		if info.state do ensure(w, outs[per - 1])
		if read do arm.body.value = ensure(w, outs[0])
		pop(&w.open)
	}
	emit(w, c, code.Match{dst, target, arms})
	if read do done(w, value, dst)
	if state, has := gives(w, c, info.value ? 1 : 0); has && info.state do done(w, state, code.NONE)
	done(w, c, code.NONE)
}

// write_loop: a loop: its parameters, from what they start from, then its body.
write_loop :: proc(w: ^Writer, c: Class, n: Node) {
	g := w.g
	info := g.loops[n.owner]
	count := len(info.machines)
	params := make([dynamic]code.Value)
	init := make([dynamic]code.Value)
	for j in 0 ..< count {
		start := ensure(w, n.args[j])
		param, read := lookup(g, Node{kind = .Param, owner = n.owner, index = j})
		state := info.state && j == count - 1
		if state {
			if read do done(w, g.home[param], code.NONE)
			continue
		}
		v: code.Value
		if read {
			v = done(w, g.home[param], fresh(w, g.home[param]))
		} else {
			v = code.value(w.f, info.machines[j])
		}
		append(&params, v)
		append(&init, start)
	}
	loop := code.Loop{params = params[:], init = init[:]}
	append(&w.open, Open{Region{.Body, n.owner, 0}, &loop.body.insts})
	append(&w.loops, n.owner)
	loop.body.value = write_tail(w, n.args[count])
	pop(&w.loops)
	pop(&w.open)
	value, read := gives(w, c, 0)
	read &&= info.value
	loop.dst = read ? fresh(w, value) : code.NONE
	emit(w, c, loop)
	if read do done(w, value, loop.dst)
	if state, has := gives(w, c, info.value ? 1 : 0); has && info.state do done(w, state, code.NONE)
	done(w, c, code.NONE)
}

// write_tail: the end of a turn, written where it is: the value of the body, NONE
// when it ends in an Again.
write_tail :: proc(w: ^Writer, t: Class) -> code.Value {
	g := w.g
	info := g.loops[w.loops[len(w.loops) - 1]]
	n := chosen(w.p, t)^
	#partial switch n.kind {
	case .Again:
		here(w, code.Again{values_of(w, n.args)})
		return code.NONE
	case .Exit:
		if info.state do ensure(w, n.args[len(n.args) - 1])
		return info.value ? ensure(w, n.args[0]) : code.NONE
	case .Match:
		m := g.matches[n.owner]
		target := ensure(w, n.args[0])
		first := 1
		if m.state {
			ensure(w, n.args[1])
			first = 2
		}
		arms := make([]code.Arm, len(m.covers))
		dst := code.NONE
		for &arm, k in arms {
			arm.cover = m.covers[k]
			append(&w.open, Open{Region{.Arm, n.owner, k}, &arm.body.insts})
			arm.body.value = write_tail(w, n.args[first + k])
			pop(&w.open)
			if arm.body.value == code.NONE do continue
			if dst == code.NONE {
				dst = code.value(w.f, code.machine_of(w.f, arm.body.value))
				w.f.kinds[dst].bounds = code.bounds_of(w.f, arm.body.value)
			} else {
				w.f.kinds[dst].bounds = code.hull(w.f.kinds[dst].bounds, code.bounds_of(w.f, arm.body.value))
			}
		}
		here(w, code.Match{dst, target, arms})
		return dst
	}
	w.error = fmt.tprintf("a %v ends a turn", n.kind)
	return code.NONE
}
