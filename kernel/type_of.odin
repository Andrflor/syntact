package kernel

import "core:fmt"

// type_of: the only semantic operation. The type of an expression is the set it
// designates, itself written in IR, and simplified:
//
//   type_of(5)             = 5           a value is a set: its own type
//   type_of(u8)            = 0..255
//   type_of(none)          = none
//   type_of(??::u8)        = ??0         an unknown, whose value lies in 0..255
//   type_of(n * 2 + n)     = 3*??0       the normal form, exact
//   type_of(??0..10)       = ??0..10     a set that depends on an unknown
//   type_of(scope)         = scope       its bindings carry their types
//
// Scopes are typed in place: each binding keeps its symbolic color and value, and
// receives their types. The check `value ⊆ color` happens at the end (check), once
// everything is typed.

type_of :: proc(k: ^Kernel, e: ^Expr, env: ^Scope) -> ^Expr {
	if e == nil do return new_expr(Invalid{})
	switch v in e^ {
	case Set:
		return e
	case ^Scope:
		type_scope(k, v)
		return e
	case Ref:
		return type_ref(k, v, env)
	case Access:
		return type_access(k, v, env)
	case Collapse:
		return type_collapse(k, v, env)
	case Carve:
		return type_carve(k, v, env)
	case Carved:
		return type_argument(k, v, nil)
	case Inferred:
		return v.type
	case Carving:
		return type_carving(k, v, env)
	case Shorthand:
		return type_shorthand(k, v, env)
	case Op:
		return type_op(k, v, env)
	case Match:
		return type_match(k, v, env)
	case Range:
		return type_range(k, v, env)
	case Unknown:
		return type_unknown(k, v, env, nil)
	case Poly, Term, ^Var, Set_Form, Cases, Invalid:
		return e // already a type
	}
	return e
}

// type_scope types each binding in place, in order: each one sees the types of
// those above it. A ref to a binding not yet typed is a recursion.
// `shape`: the places of the shape the color expects, when this scope is the
// value of a binding colored by it. The scope retains it: its copies keep it. A
// scope written here and expanded receives the rest of the shape, starting from
// the place where it lays down its bindings.
type_scope :: proc(k: ^Kernel, s: ^Scope, shape: []Place = nil) {
	s.shape = shape
	append(&k.typed, s)
	position := 0 // the place of the binding among those s presents
	for &b in s.bindings {
		if b.kind == .Expand {
			type_expansion(k, &b, s, position < len(shape) ? shape[position:] : nil)
			if v, ok := expanded(b); ok do position += len(places(v))
			continue
		}
		type_binding(k, &b, s, expected_color(shape, position, b))
		// a production that calls itself: its equation, solved if we know how
		if b.kind == .Product && b.value_type != nil do b.value_type = solved(k, s, b.value_type)
		position += 1
	}
}

// expected_color: the color type the shape expects at place i, if this binding
// corresponds to it (same name, same kind).
expected_color :: proc(shape: []Place, i: int, b: Binding) -> ^Expr {
	if i >= len(shape) do return nil
	sb := binding_at(shape[i])
	if sb.name != b.name || sb.kind != b.kind do return nil
	return sb.color_type
}

// type_binding: the color, then the value. A binding without a written color takes
// the one the shape around it expects at its place (`expected`): implicit
// coloring (specs/language/11). Typing is bidirectional: the color goes down into
// the value — a `??` takes it, a literal scope passes it to its bindings, a carve
// argument receives it from the binding it replaces.
type_binding :: proc(k: ^Kernel, b: ^Binding, env: ^Scope, expected: ^Expr) {
	previous := enter(k, env, b)
	defer k.scene = previous
	if b.kind != .Push && b.kind != .Pull && b.kind != .Product {
		b.value_type = new_expr(Invalid{}) // reported at construction
		return
	}
	b.color_type = b.color != nil ? type_color(k, b, env) : expected
	if b.value == nil {
		b.value_type = default_of(k, b.color_type, b)
		return
	}
	#partial switch v in b.value^ {
	case Unknown:
		if v.layout == nil && b.color_type != nil {
			b.value_type = type_unknown(k, v, env, b.color_type) // `??` takes its color
			return
		}
	case ^Scope:
		if shape, found := expected_shape(k, b.color_type, v); found {
			type_scope(k, v, places(shape))
			b.value_type = b.value
			return
		}
	case Carved:
		b.value_type = type_argument(k, v, b.color_type)
		return
	}
	b.value_type = type_of(k, b.value, env)
}

// type_color: the type of the color, an equation like any other type. It can
// depend on the unknowns of the bindings it mentions, which the value can share
// (check.odin). It cannot introduce one: a `??` written in the color is shared by
// no value.
type_color :: proc(k: ^Kernel, b: ^Binding, env: ^Scope) -> ^Expr {
	if writes_unknown(b.color) do return report(k, .Insoluble_Constraint, b.span, fmt.tprintf("the color of %s introduces an unknown `??` that no value shares", display(b)))
	t := type_of(k, b.color, env)
	if _, is_scope := t^.(^Scope); is_scope {
		if _, closed := color_set(k, t); !closed {
			if holds_invalid(t) do return new_expr(Invalid{}) // an error already reported inside
			return report(k, .Unsupported, b.span, fmt.tprintf("not in the kernel yet: a scope shape that depends on an unknown: %s", brief(t)))
		}
	}
	return t
}

// writes_unknown: a `??` is written in the expression — outside the scopes it
// writes, whose bindings have their own colors.
writes_unknown :: proc(e: ^Expr) -> bool {
	if e == nil do return false
	#partial switch v in e^ {
	case Unknown:
		return true
	case Op:
		return writes_unknown(v.left) || writes_unknown(v.right)
	case Range:
		return writes_unknown(v.lo) || writes_unknown(v.hi)
	case Access:
		return writes_unknown(v.target)
	case Collapse:
		return writes_unknown(v.target)
	case Carve:
		return writes_unknown(v.target)
	case Match:
		return writes_unknown(v.target)
	}
	return false
}

// holds_invalid: a binding of the scope, at whatever depth, carries an error
// already reported.
holds_invalid :: proc(t: ^Expr) -> bool {
	s, is_scope := t^.(^Scope)
	if !is_scope do return false
	for b in s.bindings {
		if is_invalid(b.color_type) || is_invalid(b.value_type) do return true
		if b.color_type != nil && holds_invalid(b.color_type) do return true
		if b.value_type != nil && holds_invalid(b.value_type) do return true
	}
	return false
}

// expected_shape: the shape a color type expects for this literal scope — the
// color itself if it is a shape, or the only shape of the same structure in a
// combination of shapes. Implicit coloring goes down place by place: a shape of
// any length (`...C:`) has no fixed places.
expected_shape :: proc(k: ^Kernel, color: ^Expr, literal: ^Scope) -> (^Scope, bool) {
	if color == nil do return nil, false
	#partial switch c in color^ {
	case ^Scope:
		return c, first_production(c) == nil && fixed_length(c)
	case Set:
		found: ^Scope = nil
		for r in bdd_atoms(c.scopes) {
			if r.equation != nil || !fits(r, literal) || r.shape == found do continue
			if found != nil do return nil, false // ambiguous
			found = r.shape
		}
		return found, found != nil
	}
	return nil, false
}

// fixed_length: the shape has no run — neither itself, nor what it expands.
fixed_length :: proc(s: ^Scope) -> bool {
	for b in s.bindings {
		if b.kind != .Expand do continue
		if b.color != nil do return false
		if v, ok := expanded(b); ok && !fixed_length(v) do return false
	}
	return true
}

// fits: the literal scope has the structure of the shape (names and kinds, in
// order).
fits :: proc(r: ^Record, literal: ^Scope) -> bool {
	if len(r.fields) != len(literal.bindings) do return false
	for f, i in r.fields do if f.name != literal.bindings[i].name || f.kind != literal.bindings[i].kind do return false
	return true
}

// default_of: the type of the value of a binding that writes none — the default of
// its color. A set: its distinguished element. A scope: its first production if it
// has one, otherwise itself (`Point:p` is Point).
default_of :: proc(k: ^Kernel, color: ^Expr, b: ^Binding) -> ^Expr {
	if color == nil || is_invalid(color) do return new_expr(Invalid{})
	if x, d, recursive := equation_var(color); recursive do return recursive_default(k, x, d, b)
	#partial switch c in color^ {
	case Set:
		first, _ := set_first_domain(c)
		#partial switch first {
		case .Scopes:
			return scopes_default(k, c.scopes, b)
		case .Sets:
			if c.sets.cofinite do return report(k, .Unsupported, b.span, "not in the kernel yet: the default of all sets but a few")
			return new_expr(c.sets.values[0])
		}
		d, ok := set_default(c)
		if !ok do return color // the color none: its only value is none
		return new_expr(d)
	case ^Scope:
		if p := first_production(c); p != nil do return p.value_type
		return color
	case Poly, Term, ^Var:
		return color // a value designates its singleton, whose default is the value itself
	}
	return report(k, .Unsupported, b.span, "not in the kernel yet: this default")
}

// recursive_default: the default of X, that of its scope: its first production,
// the base case (specs/kernel-recursion.md §1). If it is the one being typed, the
// base case comes back to X: its default would be infinite, the definition is
// illegal. Without a production, the scope contains itself: no base case.
recursive_default :: proc(k: ^Kernel, x: ^Var, d: ^Scope, b: ^Binding) -> ^Expr {
	p := first_production(d)
	if p != nil && p.value_type != nil do return p.value_type
	return report(k, .Infinite_Recursion, b.span, fmt.tprintf("the base case of %s comes back to itself: its default would be infinite", print_equation(x.type)))
}

// scopes_default: the default of a set of scopes reduced to one shape is the shape
// itself (`Point:p` is Point).
scopes_default :: proc(k: ^Kernel, b: Bdd, binding: ^Binding) -> ^Expr {
	// all scopes: the empty scope, like "" for all strings
	if is_leaf(b, .Top) do return new_expr(new_scope(nil))
	if n, is_node := b.(^Bdd_Node); is_node && is_leaf(n.yes, .Top) && is_leaf(n.maybe, .Bottom) && is_leaf(n.no, .Bottom) {
		if n.atom.equation != nil do return default_of(k, new_expr(n.atom.shape), binding) // the default of the equation
		return new_expr(n.atom.shape)
	}
	return report(k, .Unsupported, binding.span, "not in the kernel yet: the default of a combination of shapes")
}

// first_production: the first production s presents, or nil.
first_production :: proc(s: ^Scope) -> ^Binding {
	for p in places(s) do if b := binding_at(p); b.kind == .Product do return b
	return nil
}

// type_ref: the type of the designated binding.
type_ref :: proc(k: ^Kernel, r: Ref, env: ^Scope) -> ^Expr {
	sc := env
	for _ in 0 ..< r.up do sc = sc.parent
	b := sc.bindings[r.index]
	t := b.value_type
	// the scope being defined: a self-reference
	if v, literal := scope_literal(b.value); t == nil && literal && encloses(v, env) do return new_equation_var(k, new_expr(v))
	if t == nil do return report(k, .Unsupported, r.span, "not in the kernel yet: recursion")
	return t
}

type_access :: proc(k: ^Kernel, a: Access, env: ^Scope) -> ^Expr {
	t := type_of(k, a.target, env)
	if is_invalid(t) do return t
	if _, _, recursive := equation_var(t); recursive do return report(k, .Unsupported, a.span, "not in the kernel yet: a field of a recursive type")
	s, ok := t^.(^Scope)
	if !ok do return report(k, .Invalid_Property_Access, a.span, fmt.tprintf("'.%s': the target is not a scope", a.name))
	p, found := find_binding(s, a.name, a.ordinal)
	if !found do return report(k, .Invalid_Property_Access, a.span, fmt.tprintf("'%s' does not exist in this scope", a.name))
	v := binding_at(p).value_type
	if v == nil do return report(k, .Unsupported, a.span, "not in the kernel yet: recursion")
	return v
}

// find_binding: among the bindings s presents, the last occurrence of a name, or
// the n-th with `#n`.
find_binding :: proc(s: ^Scope, name: string, ordinal: int) -> (Place, bool) {
	all := places(s)
	if ordinal >= 0 {
		seen := 0
		for p in all {
			if binding_at(p).name != name do continue
			if seen == ordinal do return p, true
			seen += 1
		}
		return {}, false
	}
	#reverse for p in all do if binding_at(p).name == name do return p, true
	return {}, false
}

type_collapse :: proc(k: ^Kernel, c: Collapse, env: ^Scope) -> ^Expr {
	t := type_of(k, c.target, env)
	if is_invalid(t) do return t
	if x, d, recursive := equation_var(t); recursive {
		// a recursive call: the value of the production of the equation, applied
		// to the same types as x — an unknown (specs/equational.md §2). On the
		// same types, known, it comes back to itself: the recursion does not end.
		_, carved, _, _ := equation_of(x)
		if carved == nil && known_types(binding_types(d)) do return report(k, .Infinite_Recursion, c.span, fmt.tprintf("%s! comes back with the same arguments: the recursion does not end", print_equation(x.type)))
		// the equation of d already solved: its closed form, applied to the arguments
		if applied, ok := carved.?; ok {
			if closed, solved := apply_closed(k, d, applied); solved do return closed
		}
		return new_equation_var(k, new_expr(Collapse{target = x.type, span = c.span}))
	}
	s, ok := t^.(^Scope)
	if !ok do return report(k, .Invalid_Execute, c.span, "only a scope can be collapsed")
	p := first_production(s)
	if p == nil do return new_expr(Set{}) // a scope without a production reduces to none
	return p.value_type
}

// binding_types: the types of the bindings of s that are neither productions nor
// expansions.
binding_types :: proc(s: ^Scope) -> []^Expr {
	types := make([]^Expr, len(s.bindings), context.temp_allocator)
	for b, j in s.bindings do if b.kind != .Product && b.kind != .Expand do types[j] = b.value_type
	return types
}

// known_types: none of these types depends on an unknown.
known_types :: proc(types: []^Expr) -> bool {
	for t in types do if t != nil && !is_closed_type(t) do return false
	return true
}

// type_unknown: a new unknown. Its possible values come from its shape (`??::u8`),
// from the color that expects it (`u8:x -> ??`), or from nothing: a bare `??` can
// be any atom. As in new_symbol, an unknown with a single possible value is that
// value: `n:x -> ??` is n.
type_unknown :: proc(k: ^Kernel, u: Unknown, env: ^Scope, color: ^Expr) -> ^Expr {
	shape := color
	if u.layout != nil {
		if writes_unknown(u.layout) do return report(k, .Insoluble_Constraint, u.span, "the shape of ?? introduces an unknown `??` that no value shares")
		shape = type_of(k, u.layout, env)
	}
	if shape == nil do return new_symbol(k, set_top())
	if is_invalid(shape) do return shape
	s, closed := color_set(k, shape)
	if !closed {
		if is_value(shape) do return shape
		return report(k, .Unsupported, u.span, fmt.tprintf("not in the kernel yet: an unknown whose domain depends on another: %s", brief(shape)))
	}
	if domain_count(s, .Scopes) > 0 || domain_count(s, .Sets) > 0 do return report(k, .Unsupported, u.span, "not in the kernel yet: ?? of a scope or of a set")
	return new_symbol(k, s)
}

// type_of(lo..hi) = the union of the ranges x..y, x ∈ type_of(lo), y ∈ type_of(hi):
// see range_set.
type_range :: proc(k: ^Kernel, r: Range, env: ^Scope) -> ^Expr {
	open := new_expr(Set{}) // an absent bound: ignored by range_set
	lo, hi := open, open
	if r.lo != nil do lo = type_of(k, r.lo, env)
	if r.hi != nil do hi = type_of(k, r.hi, env)
	if is_invalid(lo) do return lo
	if is_invalid(hi) do return hi
	return set_operation(k, Set_Op{kind = .Range, lo_open = r.lo == nil, hi_open = r.hi == nil}, r.span, lo, hi)
}

first_rune :: proc(s: string) -> rune {
	for r in s do return r
	return 0
}

display :: proc(b: ^Binding) -> string {
	if b.name != "" do return fmt.tprintf("'%s'", b.name)
	if b.kind == .Product do return "the production"
	return "this binding"
}

// encloses: s is written in outer, or is outer — a scope being typed when s is
// typed.
encloses :: proc(outer, s: ^Scope) -> bool {
	for sc := s; sc != nil; sc = sc.parent do if sc == outer do return true
	return false
}
