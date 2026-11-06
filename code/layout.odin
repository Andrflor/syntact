package code

import kernel "../kernel"

// THE LAYOUT OF A VALUE (specs/types.md §4.11, §4.13)
//
// A value is held at run time by values of its machine: a word holds a number, a
// boolean, a character or a text; a scope of fields is the values of its fields, in
// order; a run is two words, the address of its bindings in memory and their
// number; a tree is two words, which of its shapes it takes and the address of its
// fields — none for a shape without field. In memory, a word takes the bits that
// hold its set — the encoding the code widens it to (§4.11) —, a scope of fields
// its fields at their natural alignment, a run and a tree their two words; the
// bindings of a run follow one another at the stride of its item.
//
// The layout is read on the set a value may take, as the kernel gives it: a set of
// one family is a word; a shape of named fields is a scope of fields; a recursive
// scope whose productions are shapes of named fields is a tree of those shapes
// (§5.6); a shape whose places are not named, its runs included — a recursive one
// solved by Arden —, is a run, its item what its places may hold (kernel.item_image).

Layout_Kind :: enum u8 {
	Word,
	Fields,
	Run,
	Tree,
}

Layout :: struct {
	kind:    Layout_Kind,
	machine: Machine, // a word
	bits:    int, // a word: its bits in memory
	signed:  bool, // a word of integers: read back as signed
	fields:  []Field_Layout, // a scope of fields
	item:    ^Layout, // a run: the layout of each of its bindings
	scope:   ^kernel.Scope, // a tree: the recursive scope it lays out
	shapes:  []kernel.Type, // a tree: its shapes, the index of each its tag
	nodes:   []^Layout, // a tree: the fields of each shape
	size:    int, // the bytes it takes in memory
	align:   int,
}

Field_Layout :: struct {
	name:   string,
	layout: ^Layout,
	offset: int,
}

// PAIR_BYTES: a run or a tree held in memory: two words.
PAIR_BYTES :: 16

// layout_of_set: the layout of the values of a set — of the term of, when one
// is given —; false when the code holds none of it.
layout_of_set :: proc(l: ^Lowering, written: kernel.Type, of: kernel.Type = nil) -> (lay: ^Layout, ok: bool) {
	set := written
	if set == nil do return nil, false
	// a set over unknowns: laid out as what it may hold, a set of constants
	if !kernel.is_constant(set) {
		if image, read := kernel.layout_image(l.k, set); read && kernel.is_constant(image) do set = image
	}
	if m := machine_of_layout(l.k, set); m != .None {
		bits, signed := 64, m == .Int
		if m == .Int do bits, signed = int_width(l.k, kernel.int_hull(l.k, set))
		return new_clone(Layout{kind = .Word, machine = m, bits = bits, signed = signed, size = bits / 8, align = bits / 8}), true
	}
	if s, is_scope := set.(^kernel.Scope); is_scope && !kernel.recursive(s) && kernel.is_shape(l.k, s) {
		if fields, named := fields_layout(l, s); named do return fields, true
	}
	// a recursive scope whose productions are shapes of named fields: a tree
	if s, is_scope := set.(^kernel.Scope); is_scope && kernel.recursive(s) {
		if tree, laid := tree_layout(l, s); laid do return tree, true
	}
	// the run of no binding is a value of every run, held as any: a union with it
	// is held as the run its other terms are
	if any, either := set.(^kernel.Or); either {
		rest := make([dynamic]kernel.Type)
		for t in any.terms do if !empty_run(l, t) do append(&rest, t)
		if len(rest) > 0 && len(rest) < len(any.terms) {
			if run, laid := layout_of_set(l, kernel.or_law(l.k, rest[:]), of); laid && run.kind == .Run do return run, true
		}
	}
	if item, has := kernel.item_image(l.k, set); has {
		// a run of a length known is held as its bindings, in values: the length
		// its set admits, or that of the term — a call's, by the recursion of its
		// bounds (§5.6)
		n, read := kernel.length_image(l.k, set)
		if !read && of != nil do n, read = kernel.layout_image(l.k, kernel.op(l.k, .Length, of))
		if !read do return
		if _, known := n.(kernel.Int); known do return
		inner := layout_of_set(l, item) or_return
		return new_clone(Layout{kind = .Run, item = inner, size = PAIR_BYTES, align = 8}), true
	}
	return
}

// empty_run: t is {}, the run of no binding.
empty_run :: proc(l: ^Lowering, t: kernel.Type) -> bool {
	s, is_scope := t.(^kernel.Scope)
	return is_scope && kernel.is_shape(l.k, s) && len(kernel.placed(l.k, s, .Shape)) == 0
}

// tree_layout: a recursive scope whose productions are shapes of fields, as a
// tree: the layout of a scope is made once, so that a field that holds the tree
// again is laid out as it.
tree_layout :: proc(l: ^Lowering, s: ^kernel.Scope) -> (lay: ^Layout, ok: bool) {
	for t in l.trees do if kernel.same(l.k, t.scope, s) do return t, true
	lay = new_clone(Layout{kind = .Tree, scope = s, size = PAIR_BYTES, align = 8})
	shapes := make([dynamic]kernel.Type)
	nodes := make([dynamic]^Layout)
	for p in kernel.placed(l.k, s, .Shape) {
		if p.kind != .Product do continue
		shape, is_scope := kernel.binding_type(l.k, p).(^kernel.Scope)
		if !is_scope || !named_shape(l, shape) do return nil, false
		append(&shapes, shape)
	}
	lay.shapes = shapes[:]
	append(&l.trees, lay)
	defer if !ok do pop(&l.trees)
	for shape in shapes do append(&nodes, fields_layout(l, shape.(^kernel.Scope)) or_return)
	lay.nodes = nodes[:]
	return lay, true
}

// named_shape: a shape whose places are all named bindings.
named_shape :: proc(l: ^Lowering, s: ^kernel.Scope) -> bool {
	if !kernel.is_shape(l.k, s) do return false
	for p in kernel.placed(l.k, s, .Shape) do if p.name == "" || kernel.is_run(p) || p.kind != .Push && p.kind != .Pull do return false
	return true
}

// fields_layout: a shape of named fields, each at its natural alignment; false when
// a place is not named, or holds what the code does not lay out.
fields_layout :: proc(l: ^Lowering, s: ^kernel.Scope) -> (lay: ^Layout, ok: bool) {
	if !named_shape(l, s) do return nil, false
	places := kernel.placed(l.k, s, .Shape)
	fields := make([]Field_Layout, len(places))
	size, align := 0, 1
	for p, i in places {
		set := kernel.binding_color(l.k, p)
		if set == nil do set = kernel.values(l.k, kernel.binding_value(l.k, p)) or_return
		inner := layout_of_set(l, set) or_return
		size = (size + inner.align - 1) / inner.align * inner.align
		fields[i] = Field_Layout{p.name, inner, size}
		size += inner.size
		align = max(align, inner.align)
	}
	return new_clone(Layout{kind = .Fields, fields = fields, size = (size + align - 1) / align * align, align = align}), true
}

// layout_of_term: the layout of the values t may take.
layout_of_term :: proc(l: ^Lowering, t: kernel.Type) -> (lay: ^Layout, ok: bool) {
	x := kernel.given(l.k, t)
	return layout_of_set(l, kernel.values(l.k, x) or_return, x)
}

// layout_machines: the machine of each value that holds a value of the layout.
layout_machines :: proc(lay: ^Layout, out: ^[dynamic]Machine) {
	switch lay.kind {
	case .Word:
		append(out, lay.machine)
	case .Fields:
		for f in lay.fields do layout_machines(f.layout, out)
	case .Run, .Tree:
		append(out, Machine.Int, Machine.Int)
	}
}

// layout_width: the number of values that hold a value of the layout.
layout_width :: proc(lay: ^Layout) -> int {
	switch lay.kind {
	case .Word:
		return 1
	case .Fields:
		n := 0
		for f in lay.fields do n += layout_width(f.layout)
		return n
	case .Run, .Tree:
		return 2
	}
	return 0
}

// same_layout: a and b hold values alike, in values and in memory.
same_layout :: proc(a, b: ^Layout) -> bool {
	if a.kind != b.kind || a.size != b.size do return false
	switch a.kind {
	case .Word:
		return a.machine == b.machine && a.bits == b.bits && a.signed == b.signed
	case .Run:
		return same_layout(a.item, b.item)
	case .Tree:
		return a == b
	case .Fields:
		if len(a.fields) != len(b.fields) do return false
		for f, i in a.fields do if f.name != b.fields[i].name || f.offset != b.fields[i].offset || !same_layout(f.layout, b.fields[i].layout) do return false
	}
	return true
}

// hold: vs hold a value of the layout: the first word of each run or tree holds
// its layout.
hold :: proc(l: ^Lowering, lay: ^Layout, vs: []Value) {
	switch lay.kind {
	case .Word:
	case .Run:
		l.held[{l.f, vs[0]}] = lay
		l.f.kinds[vs[1]].bounds = meet(l.f.kinds[vs[1]].bounds, {0, I64.hi})
	case .Tree:
		l.held[{l.f, vs[0]}] = lay
		l.f.kinds[vs[0]].bounds = meet(l.f.kinds[vs[0]].bounds, {0, i128(len(lay.shapes) - 1)})
	case .Fields:
		at := 0
		for f in lay.fields {
			w := layout_width(f.layout)
			hold(l, f.layout, vs[at:][:w])
			at += w
		}
	}
}

// held_run: vs hold a run: its layout.
held_run :: proc(l: ^Lowering, vs: []Value) -> (^Layout, bool) {
	lay, held := held_pair(l, vs)
	return lay, held && lay.kind == .Run
}

// held_pair: vs hold a run or a tree: its layout.
held_pair :: proc(l: ^Lowering, vs: []Value) -> (^Layout, bool) {
	if len(vs) != 2 do return nil, false
	lay, held := l.held[{l.f, vs[0]}]
	return lay, held
}

// --- in memory (specs/types.md §4.13) ---

// load: the values of a value of the layout, laid out at base + offset.
load :: proc(l: ^Lowering, base: Value, offset: int, lay: ^Layout) -> []Value {
	out := make([dynamic]Value)
	switch lay.kind {
	case .Word:
		if lay.machine != .Int do return fail_values(l, "a %v in memory is not code yet", lay.machine)
		dst := value(l.f, .Int)
		l.f.kinds[dst].bounds = width_bounds(lay)
		emit(l, Memory{op = .Load, dst = dst, a = base, b = NONE, offset = i64(offset), bits = lay.bits, signed = lay.signed})
		append(&out, dst)
	case .Run, .Tree:
		word := Layout{kind = .Word, machine = .Int, bits = 64, signed = true}
		append(&out, ..load(l, base, offset, &word))
		append(&out, ..load(l, base, offset + 8, &word))
		hold(l, lay, out[:])
	case .Fields:
		for f in lay.fields do append(&out, ..load(l, base, offset + f.offset, f.layout))
	}
	return out[:]
}

// store: vs, the values of a value of the layout, laid out at base + offset.
store :: proc(l: ^Lowering, base: Value, offset: int, lay: ^Layout, vs: []Value) {
	if l.error != "" do return
	switch lay.kind {
	case .Word:
		if lay.machine != .Int {
			fail(l, "a %v in memory is not code yet", lay.machine)
			return
		}
		emit(l, Memory{op = .Store, dst = NONE, a = base, b = vs[0], offset = i64(offset), bits = lay.bits})
	case .Run, .Tree:
		emit(l, Memory{op = .Store, dst = NONE, a = base, b = vs[0], offset = i64(offset), bits = 64})
		emit(l, Memory{op = .Store, dst = NONE, a = base, b = vs[1], offset = i64(offset + 8), bits = 64})
	case .Fields:
		at := 0
		for f in lay.fields {
			w := layout_width(f.layout)
			store(l, base, offset + f.offset, f.layout, vs[at:][:w])
			at += w
		}
	}
}

// width_bounds: the integers a word of the layout reads back.
width_bounds :: proc(lay: ^Layout) -> Bounds {
	if lay.bits >= 64 do return lay.signed ? I64 : U64
	if lay.signed do return {-(i128(1) << uint(lay.bits - 1)), i128(1) << uint(lay.bits - 1) - 1}
	return {0, i128(1) << uint(lay.bits) - 1}
}

// element: the address of the binding at of a run laid out from a.
element :: proc(l: ^Lowering, a, at: Value, run: ^Layout) -> Value {
	if run.item.size == 0 do return a
	return binary(l, .Add, a, binary(l, .Mul, at, constant(l, i128(run.item.size)), .Int), .Int)
}

// reserve: the address of n bindings of the run, reserved whole.
reserve :: proc(l: ^Lowering, n: Value, run: ^Layout) -> Value {
	return reserve_bytes(l, binary(l, .Mul, n, constant(l, i128(run.item.size)), .Int))
}

reserve_bytes :: proc(l: ^Lowering, bytes: Value) -> Value {
	dst := value(l.f, .Int)
	emit(l, Memory{op = .Reserve, dst = dst, a = bytes, b = NONE})
	return dst
}

// copy_items: the count bindings of a run laid out from src, laid out again from
// dst — as the run there holds them —: a loop on their places.
copy_items :: proc(l: ^Lowering, dst, src, count: Value, run: ^Layout, from: ^Layout) {
	params, starts := make([]Value, 1), make([]Value, 1)
	params[0], starts[0] = value(l.f, .Int), constant(l, 0)
	l.f.kinds[params[0]].bounds = {0, I64.hi}
	loop := Loop{params = params, init = starts}
	outer, bound := open_body(l, &loop.body)
	done := binary(l, .Ge, params[0], count, .Int)
	arms := make([]Arm, 2)
	taken := make([]Bounds, 1)
	taken[0] = {1, 1}
	arms[0] = Arm{cover = Cover{ints = taken}, body = Body{insts = make([dynamic]Inst), values = single(params[0])}}
	step_outer, step_bound := open_body(l, &arms[1].body)
	store(l, element(l, dst, params[0], run), 0, run.item, load(l, element(l, src, params[0], from), 0, from.item))
	next := make([]Value, 1)
	next[0] = binary(l, .Add, params[0], constant(l, 1), .Int)
	emit(l, Again{next})
	close_body(l, step_outer, step_bound)
	loop.body.values = close_match(l, done, arms)
	close_loop(l, loop, outer, bound)
}

// --- runs (specs/types.md §5.3) ---

// run_read: |x|, x.#k, x from k and x{#k -> v} on a run held in memory: its
// length; the binding at a + k·stride; the run from there, n - k long; a copy of
// x with the binding k stored again, laid out as it is held (into). A run held in
// values is read by its fields.
run_read :: proc(l: ^Lowering, o: ^kernel.Operation, into: ^Layout = nil) -> []Value {
	all := lower_values(l, o.args[0])
	if l.error != "" do return nil
	run, is_run := held_run(l, all)
	if !is_run {
		if o.op == .Item do return item(l, o, all)
		return fail_values(l, "%s is not lowered yet", kernel.print_type(o))
	}
	if o.op == .Length do return all[1:]
	at := lower(l, o.args[1])
	if l.error != "" do return nil
	out := make([]Value, 2)
	#partial switch o.op {
	case .Item:
		return load(l, element(l, all[0], at, run), 0, run.item)
	case .From:
		out[0], out[1] = element(l, all[0], at, run), binary(l, .Sub, all[1], at, .Int)
	case .Put:
		laid := into != nil ? into : run
		v := build(l, o.args[2], laid.item)
		out[0], out[1] = reserve(l, all[1], laid), all[1]
		copy_items(l, out[0], all[0], all[1], laid, run)
		store(l, element(l, out[0], at, laid), 0, laid.item, v)
		hold(l, laid, out)
		return out
	}
	hold(l, run, out)
	return out
}

// build: the values of t, held as the layout says: a run built by a fold, or
// written as its bindings, is laid out in memory; a pattern gives a run in each
// branch.
build :: proc(l: ^Lowering, t: kernel.Type, lay: ^Layout, tail := false) -> []Value {
	if l.error != "" do return nil
	if lay.kind != .Run && lay.kind != .Tree do return lower_values(l, t, tail)
	#partial switch v in t {
	case ^kernel.Fold:
		if lay.kind == .Run do return fold(l, v, lay)
	case ^kernel.Scope:
		if lay.kind == .Tree do return node_of(l, v, lay)
		return run_of(l, v, lay)
	case ^kernel.Pattern:
		return pattern(l, v, tail, lay)
	case ^kernel.Operation:
		if v.op == .Put do return run_read(l, v, lay)
	}
	vs := lower_values(l, t, tail)
	if l.error != "" || len(vs) == 0 do return vs
	have, held := held_pair(l, vs)
	if held && same_layout(have, lay) do return vs
	// a run laid out otherwise: its bindings laid out again, as it is held here
	if !held || have.kind != .Run || lay.kind != .Run do return fail_values(l, "%s is laid out otherwise than where it is held", kernel.print_type(t))
	out := make([]Value, 2)
	out[0], out[1] = reserve(l, vs[1], lay), vs[1]
	copy_items(l, out[0], vs[0], vs[1], lay, have)
	hold(l, lay, out)
	return out
}

// run_of: a run written as its bindings, {e₁ …}: its length the sum of theirs, one
// for a value, |r| for an expansion ...r; reserved whole, then each stored, an
// expansion copied. The run of no binding takes no memory.
run_of :: proc(l: ^Lowering, s: ^kernel.Scope, run: ^Layout) -> []Value {
	data := kernel.run_data(l.k, s)
	out := make([]Value, 2)
	if len(data) == 0 {
		out[0], out[1] = constant(l, 0), constant(l, 0)
		hold(l, run, out)
		return out
	}
	parts := make([][]Value, len(data))
	n := NONE
	for b, i in data {
		x := kernel.binding_value(l.k, b)
		parts[i] = build(l, x, b.kind == .Expand ? run : run.item)
		if l.error != "" do return nil
		n = both(l, .Add, n, b.kind == .Expand ? parts[i][1] : constant(l, 1))
	}
	out[0], out[1] = reserve(l, n, run), n
	placed(l, out[0], constant(l, 0), data, parts, run)
	hold(l, run, out)
	return out
}

// placed: the parts of a run stored from the place at of the run at a, in turn;
// the place after the last.
placed :: proc(l: ^Lowering, a, at: Value, data: []^kernel.Binding, parts: [][]Value, run: ^Layout) -> Value {
	at := at
	for b, i in data {
		if b.kind == .Expand {
			copy_items(l, element(l, a, at, run), parts[i][0], parts[i][1], run, run)
			at = binary(l, .Add, at, parts[i][1], .Int)
			continue
		}
		store(l, element(l, a, at, run), 0, run.item, parts[i])
		at = binary(l, .Add, at, constant(l, 1), .Int)
	}
	return at
}

// grows: the update of the state i of a fold is {...x e…}, x the state, read
// nowhere else: x is read for the last time, and what follows it is built in its
// place (§4.13).
grows :: proc(l: ^Lowering, f: ^kernel.Fold, i: int) -> bool {
	s, is_scope := f.updates[i].(^kernel.Scope)
	if !is_scope do return false
	data := kernel.run_data(l.k, s)
	if len(data) == 0 || data[0].kind != .Expand do return false
	x, is_state := kernel.binding_value(l.k, data[0]).(^kernel.Unknown)
	if !is_state || !kernel.same_unknown(x, f.states[i]) do return false
	for b in data[1:] do if kernel.reads(l.k, kernel.binding_value(l.k, b), f.states[i]) do return false
	for t, j in f.updates do if j != i && kernel.reads(l.k, t, f.states[i]) do return false
	return true
}

// grown: a state that grows along the fold, reserved whole before the first step
// at its final length, the closed form of |fold| (§4.13, §5.6); its init stored
// first.
grown :: proc(l: ^Lowering, f: ^kernel.Fold, i: int, run: ^Layout) -> []Value {
	ending := new_clone(f^)
	ending.value = f.states[i]
	length := kernel.op(l.k, .Length, ending)
	if o, stays := length.(^kernel.Operation); stays && o.op == .Length do return fail_values(l, "the length of %s has no closed form", kernel.print_type(ending))
	init := build(l, f.inits[i], run)
	n := lower(l, length)
	if l.error != "" do return nil
	out := make([]Value, 2)
	out[0], out[1] = reserve(l, n, run), init[1]
	if bounds_of(l.f, init[1]) != {0, 0} do copy_items(l, out[0], init[0], init[1], run, run)
	hold(l, run, out)
	return out
}

// appended: the update {...x e…} of a state that grows: e… stored after the
// bindings of x, in its place.
appended :: proc(l: ^Lowering, x: []Value, update: kernel.Type, run: ^Layout) -> []Value {
	data := kernel.run_data(l.k, update.(^kernel.Scope))[1:]
	parts := make([][]Value, len(data))
	for b, i in data {
		parts[i] = build(l, kernel.binding_value(l.k, b), b.kind == .Expand ? run : run.item)
		if l.error != "" do return nil
	}
	out := make([]Value, 2)
	out[0], out[1] = x[0], placed(l, x[0], x[1], data, parts, run)
	hold(l, run, out)
	return out
}

// --- trees (specs/types.md §5.6) ---

// node_of: a scope of fields as a value of a tree: the shape whose fields it gives,
// by name and in order; its fields stored in what is reserved for them.
node_of :: proc(l: ^Lowering, s: ^kernel.Scope, tree: ^Layout) -> []Value {
	fields, only := fields_of(l, s)
	if !only do return fail_values(l, "%s is not a value of a tree yet", kernel.print_type(s))
	for node, tag in tree.nodes {
		if len(node.fields) != len(fields) do continue
		named := true
		for f, i in node.fields do named &&= f.name == fields[i].name
		if !named do continue
		vs := make([dynamic]Value)
		for f, i in node.fields do append(&vs, ..build(l, kernel.binding_value(l.k, fields[i]), f.layout))
		if l.error != "" do return nil
		out := make([]Value, 2)
		out[0] = constant(l, i128(tag))
		if node.size == 0 {
			out[1] = constant(l, 0)
		} else {
			out[1] = reserve_bytes(l, constant(l, i128(node.size)))
			store(l, out[1], 0, node, vs[:])
		}
		hold(l, tree, out)
		return out
	}
	return fail_values(l, "%s is none of the shapes of its tree", kernel.print_type(s))
}

// tree_match: the branches of a pattern on a tree, as a match on its tag: a cover
// takes the shapes it holds whole, and none it is apart from (the lattice: S & ~c
// and S & c); a cover that takes part of a shape is not code yet.
tree_match :: proc(l: ^Lowering, branches: []kernel.Branch, tag: Value, tree: ^Layout, tail: bool, into: ^Layout) -> []Value {
	arms := make([dynamic]Arm)
	for b, i in branches {
		if i == len(branches) - 1 || b.cover == nil {
			if i == 0 do return held_as(l, b.product, into, tail)
			append(&arms, Arm{body = lower_body(l, b.product, tail, into)})
			break
		}
		tags := make([dynamic]Bounds)
		for shape, j in tree.shapes {
			if kernel.is_none(kernel.and_law(l.k, {shape, kernel.not_law(l.k, b.cover)})) {
				append(&tags, Bounds{i128(j), i128(j)})
			} else if !kernel.is_none(kernel.and_law(l.k, {shape, b.cover})) {
				return fail_values(l, "a cover %s that takes part of a shape of a tree is not code yet", kernel.print_type(b.cover))
			}
		}
		if len(tags) == 0 do continue
		append(&arms, Arm{Cover{ints = tags[:]}, lower_body(l, b.product, tail, into)})
	}
	return close_match(l, tag, arms[:])
}

// tree_field: x.a, x a tree: the field a, at its offset in the shapes that have it
// — the same in each, or it is not code yet.
tree_field :: proc(l: ^Lowering, x: []Value, tree: ^Layout, name: string) -> []Value {
	found: ^Field_Layout
	for node in tree.nodes do for &f in node.fields {
		if f.name != name do continue
		if found != nil && (found.offset != f.offset || !same_layout(found.layout, f.layout)) do return fail_values(l, "the field `%s` is laid out apart in the shapes of its tree: not code yet", name)
		found = &f
	}
	if found == nil do return fail_values(l, "no shape of the tree has a field `%s`", name)
	return load(l, x[1], found.offset, found.layout)
}

// fields_field: x.a, x a scope of fields held as its layout: the values of a.
fields_field :: proc(l: ^Lowering, x: []Value, lay: ^Layout, name: string) -> []Value {
	at := 0
	for f in lay.fields {
		w := layout_width(f.layout)
		if f.name == name do return x[at:][:w]
		at += w
	}
	return fail_values(l, "no field `%s`", name)
}

// --- the memory of a scope (specs/types.md §4.12, §4.13) ---

// holds_memory: a value of the layout holds memory: a run or a tree, in it.
holds_memory :: proc(lay: ^Layout) -> bool {
	switch lay.kind {
	case .Word:
		return false
	case .Run, .Tree:
		return true
	case .Fields:
		for f in lay.fields do if holds_memory(f.layout) do return true
	}
	return false
}

// scoped: the body of a scope that passes on no memory it reserves — what it gives
// holds none, or what it holds was reserved before it —: what it reserves is freed
// at its end, all at once (§4.13). The free end where it begins is a reservation of
// no byte; it goes back there after its last instruction, an Again staying last.
scoped :: proc(l: ^Lowering, b: ^Body) {
	if !reserves(b^) do return
	zero, mark := value(l.f, .Int), value(l.f, .Int)
	l.f.kinds[zero].bounds = {0, 0}
	inject_at(&b.insts, 0, Inst(Const{zero, 0}), Inst(Memory{op = .Reserve, dst = mark, a = zero, b = NONE}))
	free := Memory{op = .Free, dst = NONE, a = mark, b = NONE}
	last := len(b.insts) - 1
	if _, again := b.insts[last].(Again); again {
		inject_at(&b.insts, last, Inst(free))
	} else {
		append(&b.insts, free)
	}
}
