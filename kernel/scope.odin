package kernel

import syn "../compiler"
import "core:fmt"
import "core:strings"

// SCOPES (specs/types.md §5)
//
// A scope as written is an ordered sequence of bindings. A scope as a type is a
// Frame: an instance of a written scope, inside the instance of its enclosing
// scope. A scope is a system of equations: each binding states one, its name
// denotes the type of its value (§5.2). A frame gives each type once, when asked.
// A carve derives a frame where some bindings receive another value: it replaces
// their equations, and every binding that names them follows (§5.3).

Binding_Kind :: enum u8 {
	Push, // name -> value, C:name, an anonymous value
	Pull, // name <- value: a hole
	Product, // -> value: a production
	Expand, // ...value, ...C:, ...
}

Binding :: struct {
	name:  string, // "" for an anonymous binding or a production
	kind:  Binding_Kind,
	color: Expr, // left of `:`; nil when uncolored
	value: Expr, // nil when not written: the default of the color
	span:  syn.Span,
}

Scope :: struct {
	parent:    ^Scope,
	bindings:  [dynamic]Binding,
	complete:  bool, // all its bindings are built: all are visible
	producing: bool, // a production of it is being built: it may name itself
	span:      syn.Span,
}

Typing :: enum u8 {
	Not_Asked,
	In_Progress,
	Done,
}

Frame :: struct {
	scope:     ^Scope,
	parent:    ^Frame,
	source:    ^Frame, // a carve: the frame it derives
	overrides: map[int]Type, // a carve: the value it gives each binding it names
	site:      syn.Span, // a carve: where it is written, where its errors go
	shape:     ^Frame, // the shape of the color it is the value of (§5.4)
	facts:     Facts, // what the branches around it prove, where it is written
	colors:    []Type,
	values:    []Type,
	states:    []Typing,
	slots:     Maybe([]Slot), // its bindings as a value, the expansions placed
	placing:   bool, // its expansions are being placed
}

// Slot: binding `index` of `frame`: a binding of a scope once expansions are placed.
Slot :: struct {
	frame: ^Frame,
	index: int,
}

new_frame :: proc(s: ^Scope, parent: ^Frame) -> ^Frame {
	f := new(Frame)
	n := len(s.bindings)
	f.scope, f.parent = s, parent
	f.colors, f.values, f.states = make([]Type, n), make([]Type, n), make([]Typing, n)
	return f
}

// frame_of: the instance of s that f sees: f itself or a frame around it.
frame_of :: proc(f: ^Frame, s: ^Scope) -> ^Frame {
	for g := f; g != nil; g = g.parent do if g.scope == s do return g
	return nil
}

// literal_frame: the frame of the scope literal s written in f, the same each time
// it is asked. A frame to check is checked once (check.odin).
literal_frame :: proc(k: ^Kernel, s: ^Scope, f: ^Frame, check := true) -> ^Frame {
	key := [2]rawptr{s, f}
	if g, ok := k.literals[key]; ok do return g
	g := new_frame(s, f)
	g.facts = k.facts
	k.literals[key] = g
	if check do append(&k.pending, g)
	return g
}

binding_of :: proc(s: Slot) -> Binding {
	return s.frame.scope.bindings[s.index]
}

slot_value :: proc(k: ^Kernel, s: Slot) -> Type {
	return value_type(k, s.frame, s.index)
}

slot_color :: proc(k: ^Kernel, s: Slot) -> Type {
	return color_type(k, s.frame, s.index)
}

// color_type: the color of binding i; nil when uncolored. In the value of a
// binding colored by a shape, an uncolored binding has the color of its place in
// the shape: the coloring flows down (specs/language/11).
color_type :: proc(k: ^Kernel, f: ^Frame, i: int) -> Type {
	if f.colors[i] != nil do return f.colors[i]
	b := f.scope.bindings[i]
	if b.color != nil {
		f.colors[i] = type_of(k, f, b.color)
	} else if f.shape != nil && b.kind != .Product {
		cs := shape_slots(k, f.shape)
		if i < len(cs) && len(cs) == len(f.scope.bindings) && binding_of(cs[i]).kind != .Expand {
			f.colors[i] = slot_color(k, cs[i])
		}
	}
	return f.colors[i]
}

// colored_frame: f, the value of a binding colored by the shape c.
colored_frame :: proc(k: ^Kernel, f, c: ^Frame) -> ^Frame {
	if f.shape == c do return f
	key := [2]rawptr{f, c}
	if g, ok := k.colored[key]; ok do return g
	g := new_frame(f.scope, f.parent)
	g.source, g.overrides, g.site, g.shape, g.facts = f.source, f.overrides, f.site, c, f.facts
	k.colored[key] = g
	return g
}

// value_type: the type of the value of binding i (§5.2): what a carve gave it,
// what is written, or the default of its color. A binding asked again while its
// type is being given comes back to itself: a base case that recurses.
value_type :: proc(k: ^Kernel, f: ^Frame, i: int) -> Type {
	switch f.states[i] {
	case .Done:
		return f.values[i]
	case .In_Progress:
		return report(k, .Infinite_Recursion, f.scope.bindings[i].span, "this binding comes back to itself before it has a value")
	case .Not_Asked:
	}
	f.states[i] = .In_Progress
	b := f.scope.bindings[i]
	t: Type
	if o, carved := f.overrides[i]; carved {
		t = o
	} else if u, unknown := b.value.(^Unknown_Expr); unknown && u.layout == nil && b.color != nil {
		t = new_unknown(k, color_type(k, f, i)) // `C:x -> ??`: an unknown of C
	} else if b.value != nil {
		t = type_of(k, f, b.value)
	} else if c := color_type(k, f, i); c != nil {
		t = default_of(k, c)
	} else {
		t = NONE
	}
	if g, is_frame := t.(^Frame); is_frame {
		if c, colored := color_type(k, f, i).(^Frame); colored && !has_productions(k, c) do t = colored_frame(k, g, c)
	}
	if b.kind == .Product do t = solve(k, f, t) // a production that names its scope is an equation
	f.values[i] = t
	f.states[i] = .Done
	return t
}

// frame_slots: the bindings of f as a value, each expansion replaced by those it
// places (specs/language/04): `...e` those of e, `...C:` those of the default of
// C, `...` none. A value that places itself again is a base case that recurses.
frame_slots :: proc(k: ^Kernel, f: ^Frame) -> []Slot {
	if s, ok := f.slots.?; ok do return s
	if f.placing {
		report(k, .Infinite_Recursion, f.scope.span, "this value places itself again: its base case recurses")
		return nil
	}
	f.placing = true
	defer f.placing = false
	out := make([dynamic]Slot)
	for b, i in f.scope.bindings {
		if b.kind == .Expand {
			if b.value == nil && b.color == nil do continue
			if g, is_frame := value_type(k, f, i).(^Frame); is_frame {
				append(&out, ..frame_slots(k, g))
				continue
			}
		}
		append(&out, Slot{f, i})
	}
	f.slots = out[:]
	return out[:]
}

// shape_slots: the bindings of f as a shape: `...C:` and `...` stay, as runs.
shape_slots :: proc(k: ^Kernel, f: ^Frame) -> []Slot {
	out := make([dynamic]Slot)
	for b, i in f.scope.bindings {
		if b.kind == .Expand && b.value != nil {
			if g, is_frame := value_type(k, f, i).(^Frame); is_frame {
				append(&out, ..shape_slots(k, g))
				continue
			}
		}
		append(&out, Slot{f, i})
	}
	return out[:]
}

has_productions :: proc(k: ^Kernel, f: ^Frame) -> bool {
	for s in shape_slots(k, f) do if binding_of(s).kind == .Product do return true
	return false
}

// default_of: the default of a color (§5.5): the distinguished element of a set;
// the first production of a scope that has some; a shape, itself.
default_of :: proc(k: ^Kernel, c: Type) -> Type {
	#partial switch v in c {
	case Set:
		return set_default(v)
	case ^Frame:
		for s in shape_slots(k, v) do if binding_of(s).kind == .Product do return slot_value(k, s)
		return v
	}
	return c
}

set_default :: proc(s: Set) -> Set {
	if !ints_empty(s.ints) {
		if ints_contains(s.ints, 0) do return set_of(i128(0))
		r := s.ints.ranges[0]
		if lo, ok := r.lo.?; ok do return set_of(lo)
		hi, _ := r.hi.?
		return set_of(hi)
	}
	if !reals_empty(s.reals) {
		if reals_contains(s.reals, 0) do return set_of(f64(0))
		r := s.reals.ranges[0]
		if lo, ok := r.lo.?; ok && !r.lo_open do return set_of(lo)
		if hi, ok := r.hi.?; ok && !r.hi_open do return set_of(hi)
	}
	if w := set_words(s); !words_is_empty(w) {
		v, _ := words_witness(w)
		return set_of(v)
	}
	if .False in s.bools do return set_of(false)
	if .True in s.bools do return set_of(true)
	return NONE
}

// --- the operations of scopes (§5.3) ---

// access: {… x -> v …}.x = v, the last occurrence; x#n, the n-th.
access :: proc(k: ^Kernel, target: Type, name: string, ordinal: int, span: syn.Span) -> Type {
	if is_invalid(target) do return target
	f, is_frame := target.(^Frame)
	if !is_frame do return report(k, .Invalid_Property_Access, span, fmt.tprintf("%s is not a scope: it has no `%s`", print_type(target), name))
	found := -1
	seen := 0
	slots := frame_slots(k, f)
	for s, i in slots {
		if binding_of(s).name != name do continue
		if ordinal >= 0 && seen == ordinal do return slot_value(k, s)
		seen += 1
		found = i
	}
	if found < 0 || ordinal >= 0 do return report(k, .Invalid_Property_Access, span, fmt.tprintf("the scope has no `%s`", name))
	return slot_value(k, slots[found])
}

// collapse: {… -> p …}! = p, the first production; none without one. The collapse
// of a carve of an equation is the equation, with the values of the carve.
collapse :: proc(k: ^Kernel, target: Type, span: syn.Span) -> Type {
	if is_invalid(target) do return target
	f, is_frame := target.(^Frame)
	if !is_frame do return report(k, .Invalid_Execute, span, fmt.tprintf("%s is not a scope: nothing to collapse", print_type(target)))
	if r, posed := substitute_equation(k, f); posed do return r
	for s in shape_slots(k, f) do if binding_of(s).kind == .Product do return slot_value(k, s)
	return NONE
}

// Carve_Arg: an argument of a carve, typed where it is written.
Carve_Arg :: struct {
	name:    string, // "" for a positional argument
	ordinal: int, // x#n: the n-th occurrence; -1: the first
	type:    Type,
	span:    syn.Span,
}

// carve: the frame derived from target where each argument replaces the equation
// of the binding it names — unnamed, of the next binding that is neither a
// production nor a hole. A carve creates no binding. The same carve of the same
// frame is the same frame.
carve :: proc(k: ^Kernel, target: Type, args: []Carve_Arg, span: syn.Span) -> Type {
	if is_invalid(target) do return target
	for a in args do if is_invalid(a.type) do return Invalid{}
	f, is_frame := target.(^Frame)
	if !is_frame do return report(k, .Invalid_Carve, span, fmt.tprintf("%s is not a scope: it cannot be carved", print_type(target)))
	overrides := make(map[int]Type)
	position := 0
	for a in args {
		index := -1
		if a.name != "" {
			seen := 0
			for b, i in f.scope.bindings {
				if b.name != a.name do continue
				if a.ordinal < 0 || seen == a.ordinal {
					index = i
					break
				}
				seen += 1
			}
			if index < 0 do return report(k, .Invalid_Carve, a.span, fmt.tprintf("the scope has no `%s` to carve", a.name))
		} else {
			for position < len(f.scope.bindings) {
				b := f.scope.bindings[position]
				position += 1
				if b.kind == .Product || b.kind == .Pull || b.kind == .Expand do continue
				index = position - 1
				break
			}
			if index < 0 do return report(k, .Invalid_Carve, a.span, "more arguments than bindings to carve")
		}
		overrides[index] = a.type
	}
	key := carve_key(f, overrides)
	if g, ok := k.carves[key]; ok do return g
	g := new_frame(f.scope, f.parent)
	g.source, g.overrides, g.site, g.shape, g.facts = f, overrides, span, f.shape, k.facts
	k.carves[key] = g
	append(&k.pending, g)
	return g
}

carve_key :: proc(f: ^Frame, overrides: map[int]Type) -> string {
	b := strings.builder_make()
	fmt.sbprintf(&b, "%p", f)
	for i in 0 ..< len(f.scope.bindings) {
		if o, ok := overrides[i]; ok do fmt.sbprintf(&b, "|%d=%s", i, type_key(o))
	}
	return strings.to_string(b)
}

// type_key: a string that identifies a type in normal form.
type_key :: proc(t: Type) -> string {
	switch v in t {
	case Set:
		return print_set(v)
	case Poly:
		return print_poly(v)
	case ^Unknown:
		return fmt.tprintf("?%d", v.id)
	case ^Apply:
		parts := make([dynamic]string)
		for a in v.args do append(&parts, a == nil ? "_" : type_key(a))
		return fmt.tprintf("%v(%s)", v.op, strings.join(parts[:], ","))
	case ^Frame:
		return fmt.tprintf("%p", v)
	case Invalid:
		return "!"
	}
	return "_"
}

// --- a scope as a color (§5.4) ---

// frame_admits: x in c, c a scope. A scope with productions admits what they
// produce: a produced shape admits through its colors, another value only itself.
// A scope without production is a shape: it admits the scopes of the same
// structure — names, kinds, order — whose bindings its colors admit; `...C:` admits
// a run that C admits, `...` any run. A value finite and known is read against the
// equation of a recursive scope, without unfolding it: a cycle admits nothing.
frame_admits :: proc(k: ^Kernel, x: Type, c: ^Frame) -> Type {
	key := fmt.tprintf("%s|%p", type_key_deep(k, x), c)
	if key in k.admitting do return type_false()
	k.admitting[key] = true
	defer delete_key(&k.admitting, key)
	if has_productions(k, c) {
		r := type_false()
		for s in shape_slots(k, c) {
			if binding_of(s).kind != .Product do continue
			p := slot_value(k, s)
			produced, is_frame := p.(^Frame)
			shape := is_frame && !has_productions(k, produced)
			r = bool_or(r, shape ? type_in(k, x, p) : type_equal(k, x, p))
			if is_bool(r, true) do return r
		}
		return r
	}
	f, is_frame := x.(^Frame)
	if !is_frame {
		if is_atom(x) && closed(k, x) do return type_false()
		return new_apply(.In, x, c)
	}
	return match_shape(k, frame_slots(k, f), shape_slots(k, c))
}

// type_key_deep: a key for a type, a scope by its bindings.
type_key_deep :: proc(k: ^Kernel, x: Type) -> string {
	f, is_frame := x.(^Frame)
	if !is_frame do return type_key(x)
	b := strings.builder_make()
	strings.write_byte(&b, '{')
	for s in frame_slots(k, f) {
		bd := binding_of(s)
		fmt.sbprintf(&b, "%s:%v=%s;", bd.name, bd.kind, type_key(slot_value(k, s)))
	}
	strings.write_byte(&b, '}')
	return strings.to_string(b)
}

// match_shape: the bindings xs, in order, against the bindings of a shape.
match_shape :: proc(k: ^Kernel, xs, cs: []Slot) -> Type {
	if len(cs) == 0 do return set_bool(len(xs) == 0)
	c := binding_of(cs[0])
	if c.kind == .Expand {
		color := slot_color(k, cs[0])
		r := type_false()
		for n in 0 ..= len(xs) {
			head := type_true()
			if color != nil do head = type_in(k, run_frame(k, xs[:n]), color)
			if is_bool(head, false) do continue
			r = bool_or(r, bool_and(head, match_shape(k, xs[n:], cs[1:])))
			if is_bool(r, true) do return r
		}
		return r
	}
	if len(xs) == 0 do return type_false()
	x := binding_of(xs[0])
	if x.name != c.name || x.kind != c.kind do return type_false()
	head := type_true()
	if color := slot_color(k, cs[0]); color != nil do head = type_in(k, slot_value(k, xs[0]), color)
	if is_bool(head, false) do return head
	return bool_and(head, match_shape(k, xs[1:], cs[1:]))
}

// run_frame: a run of bindings, taken as a scope.
run_frame :: proc(k: ^Kernel, slots: []Slot) -> ^Frame {
	s := new_scope(nil, {})
	s.complete = true
	for x in slots do append(&s.bindings, Binding{name = binding_of(x).name, kind = binding_of(x).kind, span = binding_of(x).span})
	f := new_frame(s, nil)
	for x, i in slots {
		f.values[i] = slot_value(k, x)
		f.states[i] = .Done
	}
	return f
}

// frame_same: two scopes are equal when their bindings are, in order (§5.3).
frame_same :: proc(k: ^Kernel, a, b: ^Frame) -> bool {
	if a == b do return true
	xs, ys := frame_slots(k, a), frame_slots(k, b)
	if len(xs) != len(ys) do return false
	for x, i in xs {
		p, q := binding_of(x), binding_of(ys[i])
		if p.name != q.name || p.kind != q.kind do return false
		if !same(k, slot_value(k, x), slot_value(k, ys[i])) do return false
	}
	return true
}

// Scopes: the scopes of a constant set: all of them (in `~none`) or none. Particular
// scopes and their combinations are frames and Applies of | & ~.
Scopes :: struct {
	all: bool,
}

scopes_union :: proc(a, b: Scopes) -> Scopes {return {a.all || b.all}}
scopes_intersect :: proc(a, b: Scopes) -> Scopes {return {a.all && b.all}}
scopes_complement :: proc(a: Scopes) -> Scopes {return {!a.all}}
scopes_empty :: proc(a: Scopes) -> bool {return !a.all}
scopes_equal :: proc(a, b: Scopes) -> bool {return a.all == b.all}
