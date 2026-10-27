package code_calc

import code ".."

// THE CODE, READ AS COMPUTATIONS
//
// A function of the code (code/), each of its values a class: an instruction is a
// node on the classes of what it reads, and what the code says of its value holds
// of its class. The effects take the state the last left; an arm and a turn start
// in a state of their own. In the body of a loop, what ends a turn is a tail: an
// Again, an Exit, or a match whose arms end in tails.

Reader :: struct {
	g:      ^Graph,
	class:  []Class, // per value of the function
	state:  Class, // the state the effects read so far leave
	token:  Class, // what a narrowing is read in: the arm the code is in, or the start
	region: Region,
	loops:  [dynamic]int, // the loops the code is in, innermost last
}

// read: the graph of the function f of p, the class of its value — NO_CLASS when
// it gives none — and of the state it ends in.
read :: proc(p: ^code.Program, f: ^code.Func) -> (g: ^Graph, value, state: Class) {
	g = new(Graph)
	g.prog, g.func = p, f
	r := Reader{g = g, class = make([]Class, len(f.kinds))}
	for &c in r.class do c = NO_CLASS
	for _, j in f.params do set(&r, code.Value(j), Node{kind = .Argument, index = j})
	r.state = add(g, Node{kind = .Start})
	r.token = r.state
	read_body(&r, f.body)
	value = f.body.value == code.NONE ? NO_CLASS : r.class[f.body.value]
	return g, value, r.state
}

read_body :: proc(r: ^Reader, b: code.Body) {
	for inst in b.insts do read_inst(r, inst)
}

// set: the value dst is the class of n, with the facts the code gives it.
set :: proc(r: ^Reader, dst: code.Value, n: Node) -> Class {
	c := add(r.g, n)
	observe(r.g, c, r.g.func.kinds[dst])
	r.class[dst] = c
	return c
}

classes :: proc(r: ^Reader, vs: []code.Value) -> []Class {
	out := make([]Class, len(vs))
	for v, i in vs do out[i] = r.class[v]
	return out
}

// effectful: the state reaches the call: a call of a symbol, or of a function with
// effects.
effectful :: proc(r: ^Reader, n: Node) -> bool {
	return n.kind == .Foreign || n.kind == .Call && !r.g.prog.funcs[n.index].pure
}

read_inst :: proc(r: ^Reader, inst: code.Inst) {
	g := r.g
	switch i in inst {
	case code.Const:
		set(r, i.dst, Node{kind = .Int, value = i.value})
	case code.Real_Const:
		set(r, i.dst, Node{kind = .Real, value = transmute(i64)i.value})
	case code.Text_Const:
		set(r, i.dst, Node{kind = .Text, index = i.text})
	case code.Input:
		set(r, i.dst, Node{kind = .Input, index = i.slot})
	case code.Unary:
		set(r, i.dst, Node{kind = .Unary, op = i.op, args = classes(r, {i.a})})
	case code.Binary:
		set(r, i.dst, Node{kind = .Binary, op = i.op, args = classes(r, {i.a, i.b})})
	case code.In:
		append(&g.covers, i.cover)
		set(r, i.dst, Node{kind = .In, index = len(g.covers) - 1, args = classes(r, {i.x})})
	case code.Narrow:
		args := make([]Class, 2)
		args[0], args[1] = r.class[i.src], r.token
		set(r, i.dst, Node{kind = .Narrow, args = args})
	case code.Foreign:
		effect(r, i.dst, Node{kind = .Foreign, index = i.symbol}, i.args)
	case code.Call:
		n := Node{kind = .Call, index = i.func}
		if effectful(r, n) {
			effect(r, i.dst, n, i.args)
		} else {
			n.args = classes(r, i.args)
			if i.dst != code.NONE do set(r, i.dst, n)
		}
	case code.Match:
		read_match(r, i)
	case code.Loop:
		read_loop(r, i)
	case code.Again:
		panic("an Again outside the tail of a loop")
	}
}

// effect: a node that takes the state, then gives the state after it, and its
// answer.
effect :: proc(r: ^Reader, dst: code.Value, n: Node, args: []code.Value) {
	n := n
	all := make([]Class, len(args) + 1)
	all[0] = r.state
	for a, i in args do all[i + 1] = r.class[a]
	n.args = all
	t := add(r.g, n)
	r.state = add(r.g, Node{kind = .Get, index = 0, args = one(t)})
	if dst != code.NONE do set(r, dst, Node{kind = .Get, index = 1, args = one(t)})
}

one :: proc(c: Class) -> []Class {
	out := make([]Class, 1)
	out[0] = c
	return out
}

// has_effects: a body that calls a symbol, or a function with effects.
has_effects :: proc(p: ^code.Program, b: code.Body) -> bool {
	for inst in b.insts do if inst_effects(p, inst) do return true
	return false
}

inst_effects :: proc(p: ^code.Program, inst: code.Inst) -> bool {
	#partial switch i in inst {
	case code.Foreign:
		return true
	case code.Call:
		return !p.funcs[i.func].pure
	case code.Match:
		for arm in i.arms do if has_effects(p, arm.body) do return true
	case code.Loop:
		return has_effects(p, i.body)
	}
	return false
}

// continues: a body that ends in an Again of the loop it is in.
continues :: proc(b: code.Body) -> bool {
	return len(b.insts) > 0 && inst_continues(b.insts[len(b.insts) - 1])
}

inst_continues :: proc(inst: code.Inst) -> bool {
	#partial switch i in inst {
	case code.Again:
		return true
	case code.Match:
		for arm in i.arms do if continues(arm.body) do return true
	}
	return false
}

covers_of :: proc(m: code.Match) -> []code.Cover {
	out := make([]code.Cover, len(m.arms))
	for arm, k in m.arms do out[k] = arm.cover
	return out
}

// arms: the arms of the match m read, each in its state and region, by read_arm;
// the arguments of its node: the target, the state it starts in when its arms have
// effects, then what each arm gives.
arms :: proc(r: ^Reader, m: int, i: code.Match, read_arm: proc(r: ^Reader, m: int, b: code.Body, outs: ^[dynamic]Class)) -> []Class {
	info := r.g.matches[m]
	outs := make([dynamic]Class)
	append(&outs, r.class[i.target])
	if info.state do append(&outs, r.state)
	state, token, region := r.state, r.token, r.region
	for arm, k in i.arms {
		r.token = add(r.g, Node{kind = .Arm, owner = m, index = k})
		r.state, r.region = r.token, Region{.Arm, m, k}
		read_arm(r, m, arm.body, &outs)
	}
	r.state, r.token, r.region = state, token, region
	return outs[:]
}

// read_match: a match whose arms give a value, or effects, or both.
read_match :: proc(r: ^Reader, i: code.Match) {
	g := r.g
	m := len(g.matches)
	append(&g.matches, Match_Info{parent = r.region, covers = covers_of(i), value = i.dst != code.NONE, state = inst_effects(g.prog, i)})
	args := arms(r, m, i, proc(r: ^Reader, m: int, b: code.Body, outs: ^[dynamic]Class) {
		info := r.g.matches[m]
		read_body(r, b)
		if info.value do append(outs, r.class[b.value])
		if info.state do append(outs, r.state)
	})
	c := add(g, Node{kind = .Match, owner = m, args = args})
	info := g.matches[m]
	if info.value do set(r, i.dst, Node{kind = .Get, index = 0, args = one(c)})
	if info.state do r.state = add(g, Node{kind = .Get, index = info.value ? 1 : 0, args = one(c)})
}

// read_loop: a loop, its body read as the tail of a turn.
read_loop :: proc(r: ^Reader, i: code.Loop) {
	g := r.g
	l := len(g.loops)
	state := has_effects(g.prog, i.body)
	machines := make([dynamic]code.Machine)
	for x in i.params do append(&machines, g.func.kinds[x].machine)
	if state do append(&machines, code.Machine.None)
	append(&g.loops, Loop_Info{parent = r.region, machines = machines[:], value = i.dst != code.NONE, state = state})
	args := make([dynamic]Class)
	for x in i.init do append(&args, r.class[x])
	if state do append(&args, r.state)
	for x, j in i.params do set(r, x, Node{kind = .Param, owner = l, index = j})
	outer_state, outer_region := r.state, r.region
	r.region = Region{.Body, l, 0}
	if state do r.state = add(g, Node{kind = .Param, owner = l, index = len(i.params)})
	append(&r.loops, l)
	append(&args, read_tail(r, i.body))
	pop(&r.loops)
	r.state, r.region = outer_state, outer_region
	c := add(g, Node{kind = .Loop, owner = l, args = args[:]})
	if i.dst != code.NONE do set(r, i.dst, Node{kind = .Get, index = 0, args = one(c)})
	if state do r.state = add(g, Node{kind = .Get, index = i.dst != code.NONE ? 1 : 0, args = one(c)})
}

// read_tail: the body of a turn, up to what ends it.
read_tail :: proc(r: ^Reader, b: code.Body) -> Class {
	g := r.g
	info := g.loops[r.loops[len(r.loops) - 1]]
	for inst in b.insts {
		#partial switch i in inst {
		case code.Again:
			args := make([dynamic]Class)
			for a in i.args do append(&args, r.class[a])
			if info.state do append(&args, r.state)
			return add(g, Node{kind = .Again, args = args[:]})
		case code.Match:
			if inst_continues(i) do return read_tail_match(r, i)
		}
		read_inst(r, inst)
	}
	outs := make([dynamic]Class)
	if info.value do append(&outs, r.class[b.value])
	if info.state do append(&outs, r.state)
	return add(g, Node{kind = .Exit, args = outs[:]})
}

// read_tail_match: a match whose arms end the turn.
read_tail_match :: proc(r: ^Reader, i: code.Match) -> Class {
	g := r.g
	loop := g.loops[r.loops[len(r.loops) - 1]]
	m := len(g.matches)
	append(&g.matches, Match_Info{parent = r.region, covers = covers_of(i), state = loop.state, tail = true})
	args := arms(r, m, i, proc(r: ^Reader, m: int, b: code.Body, outs: ^[dynamic]Class) {
		append(outs, read_tail(r, b))
	})
	return add(g, Node{kind = .Match, owner = m, args = args})
}
