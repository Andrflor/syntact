package kernel

import "core:slice"

// `in` (specs/types.md §4.7)
//
// `x in c` is true when x is an element of c. It takes both arguments whole. Its
// laws, which put it in normal form:
//
//   x in (a | b)  = (x in a) [|] (x in b)          x ≠ none
//   x in (a & b)  = (x in a) [&] (x in b)          x ≠ none
//   x in ~a       = [~](x in a)                    x ≠ none
//   x in =t       = true when x and t are the same; false when both are known
//                   and differ, or their layouts have nothing in common
//   x in l..u     = l <= x [&] x <= u              x one value
//   x in p        = x in =p                        p one value
//   b in true     = b,  b in false = [~]b          b a boolean
//   none in t     = t is none
//   (t::L) in L   = true: an unknown, or a term over unknowns, is in what holds
//                   its layout, and in nothing disjoint from it
//   (a * u + b) in S = u in {v | a * v + b in S}   the preimage
//   x in (t ? {c -> p …}) = t ? {c -> x in p …}    a pattern gives one product
//   x in S        S a scope: what its productions give, or its shape (§5.4)
//
// On a constant type without scope, the laws of | & ~ are computed whole, by its
// reading (lattice.odin). What no law reduces stays `x in c`: the check proves it
// (prove.odin).

in_law :: proc(k: ^Kernel, x, c: Type) -> Type {
	if is_invalid(x) do return x
	if is_invalid(c) do return c
	if is_value(k, x) && same(k, x, c) do return Bool(true) // x in x = x in =x, x one value
	if p, ok := x.(^Pattern); ok do return enter_branches(k, p, proc(product, other: Type) -> Type {return new_operation(.In, product, other)}, c)
	if p, ok := c.(^Pattern); ok do return enter_branches(k, p, proc(product, other: Type) -> Type {return new_operation(.In, other, product)}, x)
	if u, ok := x.(^Unknown); ok && same(k, layout_of(k, u), c) do return Bool(true) // (t::L) in L
	if call, ok := x.(^Collapse); ok && call.recursive && induction(k, call, c) do return Bool(true)
	if f, ok := x.(^Fold); ok && fold_induction(k, f, c) do return Bool(true)
	if s, ok := c.(^Scope); ok {
		// (t::L) in S: true when S holds L, false when they are apart
		if !is_constant(x) {
			if image, known := values(k, x); known {
				if included(k, image, s) || shape_in(k, image, s) do return Bool(true)
				if apart(k, image, s) do return Bool(false)
			}
		}
		if verdict, read := built_in(k, x, s); read do return verdict
		return admits(k, x, s)
	}
	if o, ok := c.(^Operation); ok && o.op == .Mul && of_values(o.args[0]) do return repeated_in(k, x, o.args[0], o.args[1])
	if i, ok := c.(^Is); ok do return equal_law(k, x, i.term)
	if is_none(x) {
		if is_none(c) do return Bool(true)
		if inhabited(k, c) do return Bool(false)
		return new_operation(.In, x, c)
	}
	if is_constant(c) {
		one: [1]Type
		cells, negated := cells_in(c, &one)
		if negated do return bool_not(k, in_law(k, x, cells_term(k, cells))) // x in ~a = [~](x in a)
		values := false
		for cell in cells do values ||= cell_family(cell) == .Value
		if !values do return in_cells(k, x, c, cells)
	} else if is_value(k, c) {
		return equal_law(k, x, c) // x in p = x in =p
	}
	#partial switch v in c {
	case ^Range:
		// one value from l to u: l <= x [&] x <= u (§4.3)
		if is_value(k, x) {
			out: Type = Bool(true)
			if v.lo != nil do out = bool_and(k, out, operation_law(k, .Greater_Eq, {x, v.lo}, v.span))
			if v.hi != nil do out = bool_and(k, out, operation_law(k, .Less_Eq, {x, v.hi}, v.span))
			return out
		}
	case ^Or:
		out: Type = Bool(false)
		for term in v.terms do out = bool_or(k, out, in_law(k, x, term))
		return out
	case ^And:
		out: Type = Bool(true)
		for term in v.terms do out = bool_and(k, out, in_law(k, x, term))
		return out
	case ^Not:
		return bool_not(k, in_law(k, x, v.term))
	}
	return new_operation(.In, x, c)
}

// of_values: a | of cells that are values — scopes, =t — and nothing else.
of_values :: proc(t: Type) -> bool {
	one: [1]Type
	cells, negated := cells_in(t, &one)
	if negated || len(cells) == 0 do return false
	for c in cells do if cell_family(c) != .Value do return false
	return true
}

// in_cells: x in a | of cells without a value (a scope, =t): its elements are
// primitives, and strings of them. A boolean b is in =true when it is true:
// b in true = b, b in false = [~]b.
in_cells :: proc(k: ^Kernel, x, c: Type, cells: []Type) -> Type {
	if is_primitive(x) {
		r := and_law(k, {x, c})
		if is_none(r) do return Bool(false)
		if same(k, r, x) do return Bool(true)
		return new_operation(.In, x, c)
	}
	if v, is_bool := c.(Bool); is_bool {
		if _, is_op := x.(^Operation); is_op {
			if f, known := family_of(k, x); known && f == .Bool do return bool(v) ? x : bool_not(k, x)
		}
	}
	if !is_value(k, x) do return Bool(false) // a set, taken as a value, is not a primitive
	#partial switch v in x {
	case ^Scope:
		return Bool(false)
	case ^Unknown:
		// its layout, or what that layout may hold when it reads other unknowns
		image, _ := layout_image(k, x)
		return layout_in(k, x, image, c)
	}
	if u, a, b, linear := linear_in(x); linear && !(a == 1 && b == 0) {
		if set, exact := preimage(k, cells, a, b); exact do return in_law(k, u, set)
	}
	if image, ok := layout_image(k, x); ok do return layout_in(k, x, image, c)
	return new_operation(.In, x, c)
}

// layout_in: x, one value of the layout L: x in c = true when L & ~c = none,
// false when L & c = none (§7).
layout_in :: proc(k: ^Kernel, x, layout, c: Type) -> Type {
	if included(k, layout, c) do return Bool(true)
	if apart(k, layout, c) do return Bool(false)
	return new_operation(.In, x, c)
}

// equal_law: x in =t.
equal_law :: proc(k: ^Kernel, x, t: Type) -> Type {
	if is_invalid(x) do return x
	if is_invalid(t) do return t
	if same(k, x, t) do return Bool(true)
	if is_constant(x) && is_constant(t) {
		if equal, known := values_equal(k, x, t); known do return Bool(equal)
	}
	if is_primitive(x) && is_value(k, t) do return in_law(k, t, x) // t in =x: a primitive is its own singleton
	// two values whose layouts have nothing in common are never equal
	if is_value(k, x) && is_value(k, t) {
		lx, known_x := layout_image(k, x)
		lt, known_t := layout_image(k, t)
		if known_x && known_t && apart(k, lx, lt) do return Bool(false)
	}
	return new_operation(.In, x, new_is(t))
}

// values_equal: two constant values are equal: two sets when a & ~b and b & ~a
// are none, and not when one shows an element; two scopes when their bindings
// are (§5.3). Not known otherwise.
values_equal :: proc(k: ^Kernel, a, b: Type) -> (equal: bool, known: bool) {
	x, a_scope := a.(^Scope)
	y, b_scope := b.(^Scope)
	if a_scope || b_scope do return a_scope && b_scope && (same(k, a, b) || same_bindings(k, x, y, false)), true
	l := and_law(k, {a, not_law(k, b)})
	r := and_law(k, {b, not_law(k, a)})
	if is_none(l) && is_none(r) do return true, true
	if inhabited(k, l) || inhabited(k, r) do return false, true
	return false, false
}

// is_value: t is one value for each value of its unknowns, not a set of them: an
// unknown, an operation on values, a pattern whose products are values.
is_value :: proc(k: ^Kernel, t: Type) -> bool {
	switch v in t {
	case Char, Int, Real, Bool, None, ^Unknown, ^Scope, ^Collapse, ^Fold, ^Least, ^Series, ^Recurrent, Invalid:
		return true
	case ^Operation:
		if v.op == .In do return true
		for a in v.args do if !is_value(k, a) do return false
		return true
	case ^Pattern:
		for b in v.branches do if !is_value(k, b.product) do return false
		return true
	case ^Access:
		return is_value(k, v.target) // a field of a value
	case ^And:
		// t & S, t one value: t where it is in S
		for a in v.terms do if is_value(k, a) do return true
		return false
	case ^Effect, ^Or, ^Not, ^Is, ^Range, ^Name, ^Carve, ^Default:
	}
	return false
}

// preimage: the integers v such that a * v + b is in the cells, a ≠ 0; false when a
// bound is beyond the integers written here, or when a cell is not of integers.
preimage :: proc(k: ^Kernel, cells: []Type, a, b: i128) -> (set: Type, ok: bool) {
	if b == min(i128) || a == min(i128) do return
	start := mark(k)
	defer release(k, start)
	for c in cells {
		if cell_family(c) != .Int do return
		lo, hi := discrete_bounds(c)
		lo = add_bound(lo, -b) or_return
		hi = add_bound(hi, -b) or_return
		if a < 0 {
			x := neg_bound(hi) or_return
			y := neg_bound(lo) or_return
			lo, hi = x, y
		}
		m := abs(a)
		from, to: Maybe(i128)
		if l, has := lo.?; has do from = ceil_div(l, m)
		if h, has := hi.?; has do to = floor_div(h, m)
		push(k, discrete_cell(.Int, from, to))
	}
	return cells_term(k, join_discrete(k, .Int, pushed(k, start))), true
}

floor_div :: proc(x, y: i128) -> i128 {
	q := x / y
	if x % y != 0 && (x < 0) != (y < 0) do q -= 1
	return q
}

ceil_div :: proc(x, y: i128) -> i128 {
	return -floor_div(-x, y)
}

// induction: a recursive call is in c when its equation is, each call it makes
// taken in c (§5.6).
Induced :: struct {
	root:   ^Scope,
	set:    Type,
	proven: bool,
}

induction :: proc(k: ^Kernel, call: ^Collapse, c: Type) -> bool {
	s := call.target.(^Scope) or_return
	root := origin(s)
	for x in k.induced do if x.root == root && same(k, x.set, c) do return x.proven
	if being_given(k, root) do return false
	giving(k, root)
	proven := induced(k, root, c)
	pop(&k.asking)
	append(&k.induced, Induced{root, c, proven})
	return proven
}

induced :: proc(k: ^Kernel, root: ^Scope, c: Type) -> bool {
	p := first_production(k, root) or_return
	carved := carved_by_calls(k, binding_type(k, p), root)
	generic := generic_equation(k, root, &carved) or_return
	q := first_production(k, generic) or_return
	e := binding_type(k, q)
	assumed: Rewrite
	for inner in calls_in(k, e, root) {
		u := new_unknown(k, nil)
		u.layout = c
		assumed = rewriting_call(assumed, inner, u)
	}
	verdict, _ := prove(k, in_law(k, rewrite(k, e, assumed), c))
	return verdict == .Proven
}

// built_in: a run a fold builds, {e₀ … eₙ₋₁}, or what of it follows k, in a shape
// of places then runs of pieces: the law of `in` on a concatenation (match_shape),
// on its length and on the values its steps place — each in the color of every
// place it may take. Not read when those values are not shown in those colors.
built_in :: proc(k: ^Kernel, x: Type, s: ^Scope) -> (verdict: Type, read: bool) {
	f, is_fold := x.(^Fold)
	if o, is_from := x.(^Operation); is_from && o.op == .From do f, is_fold = o.args[0].(^Fold)
	if !is_fold do return
	shape := s
	if recursive(s) do shape = arden(k, s) or_return
	if !is_shape(k, shape) do return
	_, es, builds := built(k, f)
	if !builds do return
	images := make([]Type, len(es))
	for e, i in es do images[i] = values(k, given(k, e)) or_return
	placed_values := or_law(k, images)
	places := placed(k, shape, .Shape)
	fixed, runs := 0, false
	colors := make([dynamic]Type)
	for p in places {
		if !is_run(p) {
			if runs || p.name != "" do return // the bindings a fold places are unnamed
			fixed += 1
			if c := binding_color(k, p); c != nil do append(&colors, c)
			continue
		}
		if p.color == nil {
			runs = true
			continue
		}
		color := binding_color(k, p)
		// a run of the empty shape places nothing
		if empty, is_scope := color.(^Scope); is_scope && is_shape(k, empty) && len(placed(k, empty, .Shape)) == 0 do continue
		// a repetition A * n places pieces of A; a scope, the pieces of its runs
		pieces: Type
		if o, repeats := color.(^Operation); repeats && o.op == .Mul do pieces = o.args[0]
		else do pieces, _ = layout_pieces(k, color) or_return
		piece := pieces.(^Scope) or_return
		inner := placed(k, piece, .Shape)
		if len(inner) != 1 || is_run(inner[0]) do return
		runs = true
		if c := binding_color(k, inner[0]); c != nil do append(&colors, c)
	}
	for c in colors do if !included(k, placed_values, c) do return
	length := run_law(k, .Length, {x}, f.span)
	if !runs do return in_law(k, length, Int(i128(fixed))), true
	return in_law(k, length, range_law(k, Int(i128(fixed)), nil, .Int, f.span)), true
}

// fold_induction: a fold is in c when the states its value reads start in c, stay
// in c at each step, and its value is in c, each of those states taken in c; the
// other states are what their layouts say.
fold_induction :: proc(k: ^Kernel, f: ^Fold, c: Type) -> bool {
	assumed: Rewrite
	taken := make([]bool, len(f.states))
	for z, i in f.states {
		if !reads(k, f.value, z) do continue
		u := new_unknown(k, nil)
		u.layout = c
		assumed = rewriting(assumed, z, u)
		taken[i] = true
	}
	holds :: proc(k: ^Kernel, t, c: Type) -> bool {
		verdict, _ := prove(k, in_law(k, t, c))
		return verdict == .Proven
	}
	for t, i in f.inits do if taken[i] && !holds(k, t, c) do return false
	for t, i in f.updates do if taken[i] && !holds(k, rewrite(k, t, assumed), c) do return false
	return holds(k, rewrite(k, f.value, assumed), c)
}

// shape_in: every scope the shape l admits is in s: shapes of one structure are
// products (§5.4), included place by place — in s itself, or in a production of s.
shape_in :: proc(k: ^Kernel, l: Type, s: ^Scope) -> bool {
	shape, is_scope := l.(^Scope)
	if !is_scope || !is_shape(k, shape) do return false
	places := placed(k, shape, .Shape)
	for p in placed(k, s, .Shape) {
		if p.kind != .Product || p.value == nil do continue
		target, is_shape_value := binding_type(k, p).(^Scope)
		if !is_shape_value || !is_shape(k, target) do continue
		others := placed(k, target, .Shape)
		if len(others) != len(places) do continue
		holds := true
		for x, i in places {
			y := others[i]
			if x.name != y.name || x.kind != y.kind || is_run(x) || is_run(y) {
				holds = false
				break
			}
			cy := binding_color(k, y)
			if cy == nil do continue
			cx := binding_color(k, x)
			holds &&= cx != nil && (same(k, cx, cy) || included(k, cx, cy))
		}
		if holds do return true
	}
	return false
}
