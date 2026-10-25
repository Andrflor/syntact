package kernel

// `in` (specs/types.md §4.7)
//
// `x in c` is true when x is an element of c. It takes both arguments whole. Its
// laws, which put it in normal form:
//
//   x in (a | b)  = (x in a) [|] (x in b)          x ≠ none
//   x in (a & b)  = (x in a) [&] (x in b)          x ≠ none
//   x in ~a       = [~](x in a)                    x ≠ none
//   x in =t       = true when x and t are the same; false when both are known
//                   and differ
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
// reading (set.odin). What no law reduces stays `x in c`: the check proves it
// (prove.odin).

in_law :: proc(k: ^Kernel, x, c: Type) -> Type {
	if is_invalid(x) || is_invalid(c) do return Invalid{}
	if p, ok := x.(^Pattern); ok do return enter_branches(k, p, proc(product, other: Type) -> Type {return new_operation(.In, product, other)}, c)
	if p, ok := c.(^Pattern); ok do return enter_branches(k, p, proc(product, other: Type) -> Type {return new_operation(.In, other, product)}, x)
	if u, ok := x.(^Unknown); ok && same(k, layout_of(k, u), c) do return Bool(true) // (t::L) in L
	if s, ok := c.(^Scope); ok do return admits(k, x, s)
	if i, ok := c.(^Is); ok do return equal_law(k, x, i.term)
	if is_none(x) {
		if is_none(c) do return Bool(true)
		if inhabited(k, c) do return Bool(false)
		return new_operation(.In, x, c)
	}
	if is_constant(c) {
		cells, negated := as_cells(c)
		if negated do return bool_not(in_law(k, x, cells_term(cells))) // x in ~a = [~](x in a)
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
			if v.lo != nil do out = bool_and(out, operation_law(k, .Greater_Eq, {x, v.lo}, v.span))
			if v.hi != nil do out = bool_and(out, operation_law(k, .Less_Eq, {x, v.hi}, v.span))
			return out
		}
	case ^Or:
		out: Type = Bool(false)
		for term in v.terms do out = bool_or(out, in_law(k, x, term))
		return out
	case ^And:
		out: Type = Bool(true)
		for term in v.terms do out = bool_and(out, in_law(k, x, term))
		return out
	case ^Not:
		return bool_not(in_law(k, x, v.term))
	}
	return new_operation(.In, x, c)
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
			if f, known := family_of(k, x); known && f == .Bool do return bool(v) ? x : bool_not(x)
		}
	}
	if !is_value(k, x) do return Bool(false) // a set, taken as a value, is not a primitive
	#partial switch v in x {
	case ^Scope:
		return Bool(false)
	case ^Unknown:
		return layout_in(k, x, layout_of(k, v), c)
	}
	if u, a, b, linear := linear_in(x); linear && !(a == 1 && b == 0) {
		return in_law(k, u, preimage(cells, a, b))
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
	if is_invalid(x) || is_invalid(t) do return Invalid{}
	if same(k, x, t) do return Bool(true)
	if is_constant(x) && is_constant(t) {
		if equal, known := values_equal(k, x, t); known do return Bool(equal)
	}
	if is_primitive(x) && is_value(k, t) do return in_law(k, t, x) // t in =x: a primitive is its own singleton
	return new_operation(.In, x, new_is(t))
}

// values_equal: two constant values are equal: two sets when a & ~b and b & ~a
// are none, and not when one shows an element; two scopes when their bindings
// are (§5.3). Not known otherwise.
values_equal :: proc(k: ^Kernel, a, b: Type) -> (equal: bool, known: bool) {
	_, a_scope := a.(^Scope)
	_, b_scope := b.(^Scope)
	if a_scope || b_scope do return a_scope && b_scope && same(k, a, b), true
	x := and_law(k, {a, not_law(k, b)})
	y := and_law(k, {b, not_law(k, a)})
	if is_none(x) && is_none(y) do return true, true
	if inhabited(k, x) || inhabited(k, y) do return false, true
	return false, false
}

// is_value: t is one value for each value of its unknowns, not a set of them: an
// unknown, an operation on values, a pattern whose products are values.
is_value :: proc(k: ^Kernel, t: Type) -> bool {
	switch v in t {
	case Char, Int, Real, Bool, None, ^Unknown, ^Scope, ^Collapse, Invalid:
		return true
	case ^Operation:
		if v.op == .In do return true
		for a in v.args do if !is_value(k, a) do return false
		return true
	case ^Pattern:
		for b in v.branches do if !is_value(k, b.product) do return false
		return true
	case ^Or, ^And, ^Not, ^Is, ^Range, ^Name, ^Access, ^Carve, ^Default:
	}
	return false
}

// preimage: the integers v such that a * v + b is in s, a ≠ 0.
// preimage: the integers v such that a * v + b is in the cells, a ≠ 0.
preimage :: proc(cells: []Type, a, b: i128) -> Type {
	out := make([dynamic]Type)
	for c in cells {
		if cell_family(c) != .Int do continue
		lo, hi := discrete_bounds(c)
		lo, hi = add_bound(lo, -b), add_bound(hi, -b)
		if a < 0 do lo, hi = neg_bound(hi), neg_bound(lo)
		m := abs(a)
		from, to: Maybe(i128)
		if l, ok := lo.?; ok do from = ceil_div(l, m)
		if h, ok := hi.?; ok do to = floor_div(h, m)
		append(&out, discrete_cell(.Int, from, to))
	}
	return cells_term(join_discrete(.Int, out[:]))
}

floor_div :: proc(x, y: i128) -> i128 {
	q := x / y
	if x % y != 0 && (x < 0) != (y < 0) do q -= 1
	return q
}

ceil_div :: proc(x, y: i128) -> i128 {
	return -floor_div(-x, y)
}
