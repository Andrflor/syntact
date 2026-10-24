package kernel

// `in` (specs/types.md §4.7)
//
// `x in c` is true when x is an element of c. It takes both arguments whole. Its
// laws, which put it in normal form:
//
//   x in (a | b)  = (x in a) [|] (x in b)        x ≠ none
//   x in (a & b)  = (x in a) [&] (x in b)        x ≠ none
//   x in ~a       = [~](x in a)                  x ≠ none
//   x in =t       = true when x and t are the same, false when both are closed
//   x in p        = x in =p                      p a primitive, or an unknown
//   none in t     = false                        t ≠ none
//   (a * u + b) / d in S = u in {v | (a * v + b) / d in S}     the preimage
//   x in (t ? {c -> p …}) = t ? {c -> x in p …}  a pattern gives one product
//   x in S        S a scope: what its productions produce, or its shape (§5.4)
//
// What no law reduces stays `x in c`: the check proves it (prove.odin).

type_in :: proc(k: ^Kernel, x, c: Type) -> Type {
	if is_invalid(x) || is_invalid(c) do return Invalid{}
	xs, x_constant := x.(Set)
	cs, c_constant := c.(Set)
	if x_constant && c_constant do return set_bool(set_in(xs, cs))
	if x_constant && set_is_none(xs) && c_constant do return set_bool(set_is_none(cs))
	if a, ok := x.(^Apply); ok && a.op == .Match {
		return map_products(k, a, proc(k: ^Kernel, p, other: Type) -> Type {return type_in(k, p, other)}, c)
	}
	if a, ok := c.(^Apply); ok && a.op == .Match {
		return map_products(k, a, proc(k: ^Kernel, p, other: Type) -> Type {return type_in(k, other, p)}, x)
	}
	if f, is_frame := c.(^Frame); is_frame do return frame_admits(k, x, f)
	if _, is_frame := x.(^Frame); is_frame && c_constant do return set_bool(cs.scopes.all)
	if a, ok := c.(^Apply); ok && a.op == .Is do return type_equal(k, x, a.args[0])
	if !c_constant && is_atom(c) do return type_equal(k, x, c)
	if p, is_poly := x.(Poly); is_poly && c_constant {
		if u, a, b, linear := linear_in(p); linear && !(a == 1 && b == 0 && p.denom == 1) {
			return type_in(k, poly_var(u), Set{ints = preimage(cs.ints, a, b, p.denom)})
		}
	}
	if a, ok := c.(^Apply); ok && !(x_constant && set_is_none(xs)) {
		#partial switch a.op {
		case .Or:
			return bool_or(type_in(k, x, a.args[0]), type_in(k, x, a.args[1]))
		case .And:
			return bool_and(type_in(k, x, a.args[0]), type_in(k, x, a.args[1]))
		case .Not:
			return bool_not(type_in(k, x, a.args[0]))
		}
	}
	return new_apply(.In, x, c)
}

// type_equal: x in =t. True when x and t are the same by the laws; false when both
// are closed and differ; for a primitive x, `t in x`.
type_equal :: proc(k: ^Kernel, x, t: Type) -> Type {
	if same(k, x, t) do return type_true()
	if closed(k, x) && closed(k, t) do return type_false()
	if xs, constant := x.(Set); constant && !is_constant(t) && is_atom(t) {
		if _, primitive := set_single(xs); primitive do return type_in(k, t, xs)
	}
	return new_apply(.In, x, new_apply(.Is, t))
}

// set_in: x in c, both constant. none is only in none; a set taken as a value is
// only among the scopes of `~none`.
set_in :: proc(x, c: Set) -> bool {
	if set_is_none(x) do return set_is_none(c)
	if p, single := set_single(x); single do return set_has(c, p)
	return c.scopes.all
}

// linear_in: p = (a * u + b) / d, one unknown u of degree 1.
linear_in :: proc(p: Poly) -> (u: ^Unknown, a, b: i128, ok: bool) {
	if len(p.monos) != 1 || len(p.monos[0].vars) != 1 do return
	return p.monos[0].vars[0], p.monos[0].coef, p.constant, true
}

// preimage: the integers v such that (a * v + b) / d is in s, a ≠ 0, d > 0.
preimage :: proc(s: Ints, a, b, d: i128) -> Ints {
	out := make([dynamic]Int_Range)
	for r in s.ranges {
		lo, hi: Maybe(i128)
		if l, ok := r.lo.?; ok do lo = l * d - b
		if h, ok := r.hi.?; ok do hi = h * d - b
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
