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
//   x in p        = x in =p                        p one value
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
	if u, ok := x.(^Unknown); ok && (same(k, known_layout(k, u), c) || same(k, u.layout, c)) do return Bool(true) // (t::L) in L
	if s, ok := c.(^Scope); ok do return admits(k, x, s)
	if i, ok := c.(^Is); ok do return equal_law(k, x, i.term)
	if is_none(x) {
		if is_constant(c) {
			switch empty(k, c) {
			case .True:
				return Bool(true)
			case .False:
				return Bool(false)
			case .Unknown:
			}
		}
		return new_operation(.In, x, c)
	}
	if is_constant(c) {
		if r := read(k, c); r.exact && len(r.scopes) == 0 do return in_reading(k, x, c, r)
	} else if is_value(k, c) {
		return equal_law(k, x, c) // x in p = x in =p
	}
	#partial switch v in c {
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

// in_reading: x in a constant type without scope, taken whole. Its elements are
// primitives; a complement also holds every scope and every set taken as a value.
in_reading :: proc(k: ^Kernel, x, c: Type, r: Reading) -> Type {
	if is_primitive(x) do return Bool(disjoint(k, x, c) == .False)
	if !is_value(k, x) do return Bool(r.all_scopes) // a set, taken as a value
	#partial switch v in x {
	case ^Scope:
		return Bool(r.all_scopes)
	case ^Unknown:
		return layout_in(k, x, known_layout(k, v), c)
	}
	if u, a, b, linear := linear_in(x); linear && !(a == 1 && b == 0) {
		return in_law(k, u, rebuild(k, Reading{ints = preimage(r.ints, a, b), words = words_empty(), exact = true}))
	}
	if image, ok := layout_image(k, x); ok do return layout_in(k, x, image, c)
	return new_operation(.In, x, c)
}

// layout_in: x, one value of the layout L, is in c when L is, and is not when L
// and c are disjoint.
layout_in :: proc(k: ^Kernel, x, layout, c: Type) -> Type {
	if subset(k, layout, c) == .True do return Bool(true)
	if disjoint(k, layout, c) == .True do return Bool(false)
	return new_operation(.In, x, c)
}

// equal_law: x in =t.
equal_law :: proc(k: ^Kernel, x, t: Type) -> Type {
	if is_invalid(x) || is_invalid(t) do return Invalid{}
	if same(k, x, t) do return Bool(true)
	if is_constant(x) && is_constant(t) {
		switch values_equal(k, x, t) {
		case .True:
			return Bool(true)
		case .False:
			return Bool(false)
		case .Unknown:
		}
	}
	if is_primitive(x) && is_value(k, t) do return in_law(k, t, x) // t in =x: a primitive is its own singleton
	return new_operation(.In, x, new_is(t))
}

// values_equal: two known values are equal: two sets when each is in the other,
// two scopes when their bindings are (§5.3).
values_equal :: proc(k: ^Kernel, a, b: Type) -> Truth {
	_, a_scope := a.(^Scope)
	_, b_scope := b.(^Scope)
	if a_scope || b_scope do return truth(a_scope && b_scope && same(k, a, b))
	x := subset(k, a, b)
	y := subset(k, b, a)
	if x == .True && y == .True do return .True
	if x == .False || y == .False do return .False
	return .Unknown
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

// linear_in: t = a * u + b, one unknown u of degree 1.
linear_in :: proc(t: Type) -> (u: ^Unknown, a, b: i128, ok: bool) {
	s, is_sum := as_sum(t)
	if !is_sum || s.denom != 1 || len(s.products) != 1 || len(s.products[0].factors) != 1 do return
	return s.products[0].factors[0], s.products[0].coef, s.constant, true
}

// preimage: the integers v such that a * v + b is in s, a ≠ 0.
preimage :: proc(s: Ints, a, b: i128) -> Ints {
	out := make([dynamic]Int_Range)
	for r in s {
		lo, hi: Maybe(i128)
		if l, ok := r.lo.?; ok do lo = l - b
		if h, ok := r.hi.?; ok do hi = h - b
		if a < 0 do lo, hi = neg_bound(hi), neg_bound(lo)
		m := abs(a)
		from, to: Maybe(i128)
		if l, ok := lo.?; ok do from = ceil_div(l, m)
		if h, ok := hi.?; ok do to = floor_div(h, m)
		append(&out, Int_Range{from, to})
	}
	return ints_of(out[:])
}

floor_div :: proc(x, y: i128) -> i128 {
	q := x / y
	if x % y != 0 && (x < 0) != (y < 0) do q -= 1
	return q
}

ceil_div :: proc(x, y: i128) -> i128 {
	return -floor_div(-x, y)
}
