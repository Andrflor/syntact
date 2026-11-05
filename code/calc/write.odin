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
	needs:   map[Class]int, // the registers writing each class takes (need)
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
		g, values, state := read(p, f)
		g.costs = costs
		rebuild(g)
		saturate(g, 100 * len(g.nodes))
		best, _ := extract(g, costs)
		roots := make([dynamic]Class)
		append(&roots, ..values)
		append(&roots, state)
		plan := plan(g, best, roots[:])
		if plan.error != "" do return out, fmt.tprintf("%s: %s", f.name, plan.error)
		written, msg := write_function(plan, f, values, state)
		if msg != "" do return out, fmt.tprintf("%s: %s", f.name, msg)
		append(&out.funcs, written)
	}
	return out, ""
}

write_function :: proc(p: ^Plan, f: ^code.Func, values: []Class, state: Class) -> (out: ^code.Func, err: string) {
	g := p.g
	out = new_clone(code.Func{name = f.name, pure = f.pure, params = f.params, results = f.results})
	for _, j in f.params do append(&out.kinds, f.kinds[j])
	w := Writer{p = p, g = g, f = out, values = make([]code.Value, len(g.parent)), written = make([]bool, len(g.parent))}
	append(&w.open, Open{ROOT, &out.body.insts})
	ensure(&w, state)
	out.body.values = make([]code.Value, len(values))
	for c, k in values do out.body.values[k] = ensure(&w, c)
	return out, w.error
}

// fresh: a new value of the function, with the facts of c.
fresh :: proc(w: ^Writer, c: Class) -> code.Value {
	facts := w.g.facts[find(w.g, c)]
	v := code.value(w.f, facts.machine, facts.lanes, facts.bits)
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

// ordered: the values of what a pure computation reads, each written in turn —
// the one that needs the most registers first, so that the values written before
// it do not wait in registers while it is (Sethi, Ullman): they commute, being
// pure.
ordered :: proc(w: ^Writer, cs: []Class) -> []code.Value {
	order := make([]int, len(cs))
	needs := make([]int, len(cs))
	defer delete(order)
	defer delete(needs)
	for c, k in cs {
		order[k] = k
		needs[k] = need(w, c)
	}
	// stable, the most first
	for k in 1 ..< len(order) {
		for j := k; j > 0 && needs[order[j]] > needs[order[j - 1]]; j -= 1 do order[j], order[j - 1] = order[j - 1], order[j]
	}
	out := make([]code.Value, len(cs))
	for k in order do out[k] = ensure(w, cs[k])
	return out
}

// need: the registers writing c takes, its own among them: none once it is
// written, or when it is written in another region; for a computation of
// arguments, the most of each argument's need plus the values written before
// it, the arguments in the order they are written.
need :: proc(w: ^Writer, c: Class) -> int {
	c := find(w.g, c)
	if c == NO_CLASS || w.written[c] do return 0
	if len(w.open) > 0 && w.p.place[c] != w.open[len(w.open) - 1].region do return 0
	if v, known := w.needs[c]; known do return v
	n := chosen(w.p, c)^
	out := 1
	#partial switch n.kind {
	case .Unary, .Binary, .In, .Narrow, .Splat, .Reduce, .Select:
		args := make([]int, len(n.args))
		defer delete(args)
		for a, k in n.args do args[k] = need(w, a)
		for k in 1 ..< len(args) do for j := k; j > 0 && args[j] > args[j - 1]; j -= 1 do args[j], args[j - 1] = args[j - 1], args[j]
		for x, k in args do out = max(out, x + k)
	}
	w.needs[c] = out
	return out
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
		write_call(w, c, n)
		return done(w, c, code.NONE)
	case .Int, .Real, .Text, .Input, .Unary, .Binary, .In, .Narrow, .Splat, .Lanes, .Reduce, .Select:
	}
	args := ordered(w, n.args)
	dst := fresh(w, c)
	inst: code.Inst
	#partial switch n.kind {
	case .Int:
		inst = code.Const{dst, n.value}
	case .Real:
		inst = code.Real_Const{dst, transmute(f64)i64(n.value)}
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
	case .Splat:
		inst = code.Splat{dst, args[0]}
	case .Lanes:
		inst = code.Lanes{dst, g.vectors[n.index]}
	case .Reduce:
		inst = code.Reduce{dst, args[0], n.op}
	case .Select:
		inst = code.Select{dst, args[0], args[1], args[2]}
	}
	emit(w, c, inst)
	return done(w, c, dst)
}

// write_call: the call of a symbol or of a function: after the state it takes,
// when it takes one, and its arguments; each value it gives, one of its own.
write_call :: proc(w: ^Writer, c: Class, n: Node) {
	first := effectful(w.g, n) ? 1 : 0
	if first == 1 do ensure(w, n.args[0]) // the effects before
	args := values_of(w, n.args[first:])
	if n.kind == .Foreign {
		answer, read := gives(w, c, 1)
		dst := read ? fresh(w, answer) : code.NONE
		emit(w, c, code.Foreign{dst, n.index, args})
		if read do done(w, answer, dst)
	} else {
		results := w.g.prog.funcs[n.index].results
		dst := make([]code.Value, len(results))
		for m, k in results {
			answer, read := gives(w, c, first + k)
			dst[k] = read ? done(w, answer, fresh(w, answer)) : code.value(w.f, m)
		}
		emit(w, c, code.Call{dst, n.index, args})
	}
	if state, has := gives(w, c, 0); has && first == 1 do done(w, state, code.NONE)
}

// read_values: of the count values a tuple gives, those read.
read_values :: proc(w: ^Writer, t: Class, count: int) -> []int {
	out := make([dynamic]int)
	for j in 0 ..< count do if _, read := gives(w, t, j); read do append(&out, j)
	return out[:]
}

// fresh_values: a value for each of the values of t read.
fresh_values :: proc(w: ^Writer, t: Class, read: []int) -> []code.Value {
	out := make([]code.Value, len(read))
	for j, k in read {
		value, _ := gives(w, t, j)
		out[k] = fresh(w, value)
	}
	return out
}

// done_values: the values of t read are dst.
done_values :: proc(w: ^Writer, t: Class, read: []int, dst: []code.Value) {
	for j, k in read {
		value, _ := gives(w, t, j)
		done(w, value, dst[k])
	}
}

// write_match: a match whose arms give values, or effects, or both.
write_match :: proc(w: ^Writer, c: Class, n: Node) {
	info := w.g.matches[n.owner]
	target := ensure(w, n.args[0])
	first := 1
	if info.state {
		ensure(w, n.args[1])
		first = 2
	}
	per := info.values + (info.state ? 1 : 0)
	read := read_values(w, c, info.values)
	dst := fresh_values(w, c, read)
	arms := make([]code.Arm, len(info.covers))
	for &arm, k in arms {
		arm.cover = info.covers[k]
		append(&w.open, Open{Region{.Arm, n.owner, k}, &arm.body.insts})
		outs := n.args[first + k * per:][:per]
		if info.state do ensure(w, outs[per - 1])
		arm.body.values = make([]code.Value, len(read))
		for j, x in read do arm.body.values[x] = ensure(w, outs[j])
		pop(&w.open)
	}
	emit(w, c, code.Match{dst, target, arms})
	done_values(w, c, read, dst)
	if state, has := gives(w, c, info.values); has && info.state do done(w, state, code.NONE)
	done(w, c, code.NONE)
}

// write_loop: a loop: its parameters alive, from what they start from, then its
// body.
write_loop :: proc(w: ^Writer, c: Class, n: Node) {
	g := w.g
	info := g.loops[n.owner]
	count := len(info.params)
	params := make([dynamic]code.Value)
	init := make([dynamic]code.Value)
	values := make([]code.Value, count)
	for j in 0 ..< count {
		if !w.p.live[n.owner][j] do continue
		start := ensure(w, n.args[j])
		param, read := lookup(g, Node{kind = .Param, owner = n.owner, index = j})
		if j == info.state {
			if read do done(w, g.home[param], code.NONE)
			continue
		}
		if read {
			values[j] = done(w, g.home[param], fresh(w, g.home[param]))
		} else {
			values[j] = code.value(w.f, info.params[j].machine, info.params[j].lanes)
		}
		append(&params, values[j])
		append(&init, start)
	}
	loop := code.Loop{params = params[:], init = init[:]}
	append(&w.open, Open{Region{.Body, n.owner, 0}, &loop.body.insts})
	append(&w.loops, n.owner)
	loop.body.values = write_tail(w, n.args[count])
	pop(&w.loops)
	pop(&w.open)
	read := read_values(w, c, info.values)
	loop.dst = fresh_values(w, c, read)
	emit(w, c, loop)
	done_values(w, c, read, loop.dst)
	if state, has := gives(w, c, info.values); has && info.state >= 0 do done(w, state, code.NONE)
	// what its parameters hold at its end
	for j, k in info.finals do if final, has := gives(w, c, outputs(info) + k); has do done(w, final, values[j])
	done(w, c, code.NONE)
}

// write_tail: the end of a turn, written where it is: the values of the body read,
// none when it ends in an Again.
write_tail :: proc(w: ^Writer, t: Class) -> []code.Value {
	g := w.g
	l := w.loops[len(w.loops) - 1]
	info := g.loops[l]
	n := chosen(w.p, t)^
	#partial switch n.kind {
	case .Again:
		args := make([dynamic]code.Value)
		for a, j in n.args {
			if !w.p.live[l][j] do continue
			v := ensure(w, a)
			if j != info.state do append(&args, v)
		}
		here(w, code.Again{args[:]})
		return nil
	case .Exit:
		if info.state >= 0 do ensure(w, n.args[len(n.args) - 1])
		read := read_values(w, find(g, g.home[info.node]), info.values)
		out := make([]code.Value, len(read))
		for j, k in read do out[k] = ensure(w, n.args[j])
		return out
	case .Match:
		m := g.matches[n.owner]
		target := ensure(w, n.args[0])
		first := 1
		if m.state {
			ensure(w, n.args[1])
			first = 2
		}
		arms := make([]code.Arm, len(m.covers))
		dst: []code.Value
		for &arm, k in arms {
			arm.cover = m.covers[k]
			append(&w.open, Open{Region{.Arm, n.owner, k}, &arm.body.insts})
			arm.body.values = write_tail(w, n.args[first + k])
			pop(&w.open)
			vs := arm.body.values
			if len(vs) == 0 do continue
			if dst == nil {
				dst = make([]code.Value, len(vs))
				for v, j in vs {
					dst[j] = code.value(w.f, code.machine_of(w.f, v))
					w.f.kinds[dst[j]].bounds = code.bounds_of(w.f, v)
				}
				continue
			}
			for v, j in vs do w.f.kinds[dst[j]].bounds = code.hull(w.f.kinds[dst[j]].bounds, code.bounds_of(w.f, v))
		}
		here(w, code.Match{dst, target, arms})
		return dst
	}
	w.error = fmt.tprintf("a %v ends a turn", n.kind)
	return nil
}
