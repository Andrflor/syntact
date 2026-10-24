package kernel

import syn "../compiler"

// SCOPES (specs/types.md §5)
//
// A scope as written is an ordered sequence of bindings. A scope as a type is a
// Frame: an instance of a written scope, inside the instance of its enclosing
// scope. Each binding states an equation: its name denotes the type of its value
// (§5.2). A frame computes each type once, when it is asked.

Binding_Kind :: enum u8 {
	Push, // name -> value, C:name, an anonymous value
	Pull, // name <- value: a hole
	Product, // -> value: a production
	Expand, // ...value
}

Binding :: struct {
	name:  string, // "" for an anonymous binding or a production
	kind:  Binding_Kind,
	color: Expr, // left of `:`; nil when uncolored
	value: Expr, // nil when not written: the default of the color
	span:  syn.Span,
}

Scope :: struct {
	parent:   ^Scope,
	bindings: [dynamic]Binding,
	complete: bool, // all its bindings are built: all are visible
	span:     syn.Span,
}

Typing :: enum u8 {
	Not_Asked,
	In_Progress,
	Done,
}

Frame :: struct {
	scope:  ^Scope,
	parent: ^Frame,
	colors: []Type,
	values: []Type,
	states: []Typing,
}

new_frame :: proc(s: ^Scope, parent: ^Frame) -> ^Frame {
	f := new(Frame)
	n := len(s.bindings)
	f^ = Frame{s, parent, make([]Type, n), make([]Type, n), make([]Typing, n)}
	return f
}

// frame_of: the instance of `s` that f sees: f itself or an enclosing frame.
frame_of :: proc(f: ^Frame, s: ^Scope) -> ^Frame {
	for g := f; g != nil; g = g.parent do if g.scope == s do return g
	return nil
}

// color_type: the type of the color of binding i; nil when uncolored.
color_type :: proc(k: ^Kernel, f: ^Frame, i: int) -> Type {
	b := f.scope.bindings[i]
	if b.color == nil do return nil
	if f.colors[i] == nil do f.colors[i] = type_of(k, f, b.color)
	return f.colors[i]
}

// value_type: the type of the value of binding i (§5.2): the type of what is
// written, or the default of the color.
value_type :: proc(k: ^Kernel, f: ^Frame, i: int) -> Type {
	switch f.states[i] {
	case .Done:
		return f.values[i]
	case .In_Progress:
		return report(k, .Unsupported, f.scope.bindings[i].span, "not in the kernel yet: a binding that depends on itself")
	case .Not_Asked:
	}
	f.states[i] = .In_Progress
	b := f.scope.bindings[i]
	t: Type
	if b.value != nil {
		t = type_of(k, f, b.value)
	} else if c := color_type(k, f, i); c != nil {
		t = default_of(c)
	} else {
		t = NONE
	}
	f.values[i] = t
	f.states[i] = .Done
	return t
}

// default_of: the default of a color (specs/language/10): its distinguished
// element.
default_of :: proc(c: Type) -> Type {
	s, constant := c.(Set)
	if !constant do return c
	return set_default(s)
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
		lo, has_lo := r.lo.?
		hi, has_hi := r.hi.?
		switch {
		case has_lo && !r.lo_open:
			return set_of(lo)
		case has_hi && !r.hi_open:
			return set_of(hi)
		case has_lo && has_hi:
			return set_of((lo + hi) / 2)
		case has_lo:
			return set_of(lo + 1)
		case:
			return set_of(hi - 1)
		}
	}
	if w := set_words(s); !words_is_empty(w) {
		v, _ := words_witness(w)
		return set_of(v)
	}
	if .False in s.bools do return set_of(false)
	if .True in s.bools do return set_of(true)
	return NONE
}

// Scopes: the scopes of a constant type. Only "every scope" or "none" for now:
// shapes come with §5.4.
Scopes :: struct {
	all: bool,
}

scopes_union :: proc(a, b: Scopes) -> Scopes {return {a.all || b.all}}
scopes_intersect :: proc(a, b: Scopes) -> Scopes {return {a.all && b.all}}
scopes_complement :: proc(a: Scopes) -> Scopes {return {!a.all}}
scopes_empty :: proc(a: Scopes) -> bool {return !a.all}
scopes_equal :: proc(a, b: Scopes) -> bool {return a.all == b.all}

// scopes_have_value: the set x, taken as a value, is an element of a.
scopes_have_value :: proc(a: Scopes, x: Set) -> bool {
	return a.all
}
