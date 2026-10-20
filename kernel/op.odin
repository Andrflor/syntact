package kernel

import syn "../compiler"
import "core:fmt"

// type_of of an operator. If both operands are values (an atom, or a form over
// unknowns), the computation is on the values, and the result is in normal form
// (`n * 2 - n` is ??0). If they are sets (`u8`, `>0`, `'a'..'z'`), the computation
// is on their elements: `u8 + 1` is 1..256; and if one depends on unknowns, the
// type keeps the form of the operation (set_form.odin).

type_op :: proc(k: ^Kernel, o: Op, env: ^Scope) -> ^Expr {
	if o.left == nil do return type_unary(k, o, env)
	a := type_of(k, o.left, env)
	b := type_of(k, o.right, env)
	if is_invalid(a) do return a
	if is_invalid(b) do return b
	return binary(k, o, a, b, context_of(env))
}

// binary: the operation on two types, in the context where it is written. On a
// type by cases, it is done case by case, each case with what its branch knows.
binary :: proc(k: ^Kernel, o: Op, a, b: ^Expr, ctx: Context) -> ^Expr {
	if x, is_cases := a^.(Cases); is_cases do return each_case(x, proc(k: ^Kernel, o: Op, v, other: ^Expr, ctx: Context) -> ^Expr {return binary(k, o, v, other, ctx)}, k, o, b, ctx)
	if y, is_cases := b^.(Cases); is_cases do return each_case(y, proc(k: ^Kernel, o: Op, v, other: ^Expr, ctx: Context) -> ^Expr {return binary(k, o, other, v, ctx)}, k, o, a, ctx)
	#partial switch o.kind {
	case .Or, .And:
		return set_algebra(k, o, a, b)
	case .Add, .Subtract, .Multiply:
		return arithmetic(k, o, a, b)
	case .Equal, .NotEqual, .Less, .Greater, .LessEqual, .GreaterEqual:
		return comparison(k, o, a, b)
	case .Cast:
		return cast_into(k, o, a, b)
	case .Divide, .Mod:
		return division(k, o, a, b, ctx)
	}
	return report(k, .Unsupported, o.span, fmt.tprintf("not in the kernel yet: the operator %v", o.kind))
}

// each_case: f applied to the value of each case; an error in a case is that of
// the operation.
each_case :: proc(c: Cases, f: proc(k: ^Kernel, o: Op, v, other: ^Expr, ctx: Context) -> ^Expr, k: ^Kernel, o: Op, other: ^Expr, ctx: Context) -> ^Expr {
	out := make([]Case, len(c.cases))
	for x, i in c.cases {
		r := f(k, o, x.value, other, with(ctx, x.fact))
		if is_invalid(r) do return r
		out[i] = Case{x.fact, r}
	}
	return new_expr(Cases{out})
}

// `|` and `&` operate on sets.
set_algebra :: proc(k: ^Kernel, o: Op, a, b: ^Expr) -> ^Expr {
	return set_operation(k, Set_Op{kind = o.kind == .Or ? .Union : .Inter}, o.span, a, b)
}

arith_of :: proc(kind: syn.Operator_Kind) -> Arith {
	#partial switch kind {
	case .Subtract:
		return .Sub
	case .Multiply:
		return .Mul
	}
	return .Add
}

arithmetic :: proc(k: ^Kernel, o: Op, a, b: ^Expr) -> ^Expr {
	op := arith_of(o.kind)
	if is_value(a) && is_value(b) {
		r, status := value_arith(k, op, a, b)
		if status != .Ok do return arith_failure(k, o, status, a, b)
		return r
	}
	// On sets, known or depending on unknowns.
	return set_operation(k, Set_Op{kind = .Arith, arith = op}, o.span, a, b)
}

// value_arith: on two values, known or not, in normal form.
value_arith :: proc(k: ^Kernel, op: Arith, a_in, b_in: ^Expr) -> (^Expr, Arith_Status) {
	a, b := a_in, b_in
	sa, a_atom := a^.(Set)
	sb, b_atom := b^.(Set)
	if a_atom && b_atom {
		r, status := arith_sets(op, sa, sb)
		return new_expr(r), status
	}
	da, a_ok := value_domain(k, a)
	db, b_ok := value_domain(k, b)
	a, da, a_ok = adopt(a, da, a_ok, db, b_ok)
	b, db, b_ok = adopt(b, db, b_ok, da, a_ok)
	if !a_ok || !b_ok do return nil, .Unsupported // an unknown of several sorts
	switch {
	case da == .Ints && db == .Ints:
		pa, a_poly := as_int_poly(k, a)
		pb, b_poly := as_int_poly(k, b)
		if !a_poly || !b_poly do return nil, .Unsupported
		r: Poly
		ok: bool
		switch op {
		case .Add:
			r, ok = poly_add(pa, pb)
		case .Sub:
			r, ok = poly_sub(pa, pb)
		case .Mul:
			r, ok = poly_mul(pa, pb)
		}
		if !ok do return nil, .Unsupported // a coefficient beyond i128
		return poly_type(r), .Ok
	case da == .Floats && db == .Floats:
		switch op {
		case .Add:
			return float_add(a, b), .Ok
		case .Sub:
			return float_add(a, float_neg(b)), .Ok // a - b = a + (-b), exactly
		case .Mul:
			return float_mul(a, b), .Ok
		}
	case is_textual(da) && is_textual(db) && op == .Add:
		return concat(k, a, b), .Ok
	case op == .Mul && is_textual(da) && db == .Ints:
		return repeat_term(k, a, b)
	case op == .Mul && da == .Ints && is_textual(db):
		return repeat_term(k, b, a)
	case (da == .Ints && db == .Floats) || (da == .Floats && db == .Ints):
		return nil, .Unsupported
	}
	return nil, .Invalid
}

// adopt: a variable whose equation is not solved yet takes the sort of the other
// operand; when integer, it enters the polynomials.
adopt :: proc(t: ^Expr, d: Domain, ok: bool, other: Domain, other_ok: bool) -> (^Expr, Domain, bool) {
	if ok || !other_ok do return t, d, ok
	v, waiting := pending(t)
	if !waiting do return t, d, ok
	if other == .Ints do return new_expr(poly_var(v)), other, true
	return t, other, true
}

Arith_Status :: enum u8 {
	Ok,
	Invalid, // the operator does not apply to these sorts
	Unsupported, // not in the kernel yet (integer/float mix, too large to be exact)
}

arith_failure :: proc(k: ^Kernel, o: Op, status: Arith_Status, a, b: ^Expr) -> ^Expr {
	if status == .Unsupported {
		return report(k, .Unsupported, o.span, fmt.tprintf("not in the kernel yet: '%v' on %s and %s", o.kind, print_type(a), print_type(b)))
	}
	return report(k, .Invalid_operator, o.span, fmt.tprintf("'%v' does not apply to %s and %s", o.kind, print_type(a), print_type(b)))
}

// arith_sets: { x op y } on two sets, sort by sort: each sort of `a` combines
// with the sort of `b` for which the operation exists. On numbers, arithmetic; on
// strings, `+` concatenates and `*` repeats by a set of counts (`'a'..'z' * 2..4`,
// `..10 * "ab"`), in both directions. No compatible pair: the operator does not
// apply.
arith_sets :: proc(op: Arith, a, b: Set) -> (Set, Arith_Status) {
	has :: proc(s: Set, d: Domain) -> bool {
		return domain_count(s, d) > 0
	}
	textual :: proc(s: Set) -> bool {
		return domain_count(s, .Strings) > 0 || domain_count(s, .Chars) > 0
	}
	r := Set{}
	found := false
	if has(a, .Ints) && has(b, .Ints) {
		exact: bool
		r.ints, exact = ints_arith(op, a.ints, b.ints)
		if !exact do return {}, .Unsupported // a bound beyond i128
		found = true
	}
	if has(a, .Floats) && has(b, .Floats) {
		r.floats = floats_arith(op, a.floats, b.floats)
		found = true
	}
	// Concatenating or repeating characters gives strings.
	if textual(a) && textual(b) && op == .Add {
		r.strings = strings_union(r.strings, strings_concat(as_strings(a), as_strings(b)))
		found = true
	}
	if op == .Mul {
		for pair in ([2][2]Set{{a, b}, {b, a}}) {
			if !textual(pair[0]) || !has(pair[1], .Ints) do continue
			rep, ok := strings_repeat(as_strings(pair[0]), pair[1].ints)
			if !ok do return {}, .Unsupported // too large for an exact automaton
			r.strings = strings_union(r.strings, rep)
			found = true
		}
	}
	if found do return r, .Ok
	if (has(a, .Ints) && has(b, .Floats)) || (has(a, .Floats) && has(b, .Ints)) do return {}, .Unsupported
	return {}, .Invalid
}

// pure_domain: the single sort of a non-empty set that carries only one.
pure_domain :: proc(s: Set) -> (Domain, bool) {
	found := false
	d: Domain
	for x in Domain {
		if domain_count(s, x) == 0 do continue
		if found do return d, false
		d, found = x, true
	}
	return d, found
}

compare_op_of :: proc(kind: syn.Operator_Kind) -> Compare_Op {
	#partial switch kind {
	case .Less:
		return .Lt
	case .LessEqual:
		return .Le
	case .Greater:
		return .Gt
	case .GreaterEqual:
		return .Ge
	case .NotEqual:
		return .Ne
	}
	return .Eq
}

// A comparison gives a boolean: exact when the values decide it, a normal form
// otherwise. Two different sorts are never equal.
comparison :: proc(k: ^Kernel, o: Op, a, b: ^Expr) -> ^Expr {
	op := compare_op_of(o.kind)
	if is_value(a) && is_value(b) {
		da, a_ok := value_domain(k, a)
		db, b_ok := value_domain(k, b)
		if a_ok && b_ok && da != db {
			if op == .Eq || op == .Ne do return bool_atom(op == .Ne)
			return report(k, .Invalid_operator, o.span, fmt.tprintf("'%v' compares two different sorts: %s and %s", o.kind, print_type(a), print_type(b)))
		}
		r: ^Expr
		status: Arith_Status
		pa, a_poly := as_poly(a)
		pb, b_poly := as_poly(b)
		if a_poly && b_poly {
			p, ok := poly_sub(pa, pb)
			if !ok do return report(k, .Unsupported, o.span, "not in the kernel yet: a coefficient beyond i128")
			r, status = int_compare(k, op, p)
		} else {
			r, status = general_compare(k, op, a, b)
		}
		if status != .Ok do return arith_failure(k, o, status, a, b)
		return r
	}
	// Two sets compared as values: only equality makes sense.
	sa, a_known := color_set(k, a)
	sb, b_known := color_set(k, b)
	if !a_known || !b_known || (op != .Eq && op != .Ne) {
		return report(k, .Unsupported, o.span, "not in the kernel yet: this comparison")
	}
	return bool_atom(set_equal(sa, sb) == (op == .Eq))
}

equal_verdict :: proc(a, b: Set) -> Bools {
	if is_atom(a) && is_atom(b) do return set_equal(a, b) ? {.True} : {.False}
	if set_is_empty(set_intersect(a, b)) do return {.False}
	return {.False, .True}
}

// order_verdict decides `a < b` (etc.) on the envelopes of two sets of numbers
// or of characters.
order_verdict :: proc(op: Compare_Op, a, b: Set) -> (Bools, bool) {
	da, a_pure := pure_domain(a)
	db, b_pure := pure_domain(b)
	if !a_pure || !b_pure || da != db do return {}, false
	alo, ahi, blo, bhi: Maybe(f64)
	switch da {
	case .Ints:
		alo, ahi = to_f64(ints_bounds(a.ints))
		blo, bhi = to_f64(ints_bounds(b.ints))
	case .Chars:
		alo, ahi = to_f64(ints_bounds(a.chars))
		blo, bhi = to_f64(ints_bounds(b.chars))
	case .Floats:
		alo, ahi = floats_bounds(a.floats)
		blo, bhi = floats_bounds(b.floats)
	case .Strings, .Bools, .Scopes, .Sets:
		return {}, false
	}
	// lt: a < b is certain; ge: a >= b is certain (and symmetrically).
	lt := below(ahi, blo, strict = true)
	le := below(ahi, blo, strict = false)
	gt := below(bhi, alo, strict = true)
	ge := below(bhi, alo, strict = false)
	#partial switch op {
	case .Lt:
		if lt do return {.True}, true
		if ge do return {.False}, true
	case .Le:
		if le do return {.True}, true
		if gt do return {.False}, true
	case .Gt:
		if gt do return {.True}, true
		if le do return {.False}, true
	case .Ge:
		if ge do return {.True}, true
		if lt do return {.False}, true
	}
	return {.False, .True}, true
}

// below: hi < lo (or hi <= lo), for an upper bound and a lower bound.
below :: proc(hi, lo: Maybe(f64), strict: bool) -> bool {
	h, h_ok := hi.?
	l, l_ok := lo.?
	if !h_ok || !l_ok do return false
	return strict ? h < l : h <= l
}

to_f64 :: proc(lo, hi: Maybe(i128)) -> (Maybe(f64), Maybe(f64)) {
	l: Maybe(f64) = nil
	h: Maybe(f64) = nil
	if v, ok := lo.?; ok do l = f64(v)
	if v, ok := hi.?; ok do h = f64(v)
	return l, h
}

// The unary operators: `-x` on a value; `~X`, `>x`, `<x`, `>=x`, `<=x`, `!=x`
// build a set.
type_unary :: proc(k: ^Kernel, o: Op, env: ^Scope) -> ^Expr {
	t := type_of(k, o.right, env)
	if is_invalid(t) do return t
	return unary(k, o, t)
}

unary :: proc(k: ^Kernel, o: Op, t: ^Expr) -> ^Expr {
	if x, is_cases := t^.(Cases); is_cases do return each_case(x, proc(k: ^Kernel, o: Op, v, _: ^Expr, _: Context) -> ^Expr {return unary(k, o, v)}, k, o, nil, nil)
	#partial switch o.kind {
	case .Subtract:
		return negate(k, o, t)
	case .Not:
		return set_operation(k, Set_Op{kind = .Comp}, o.span, t)
	case .Greater, .Less, .GreaterEqual, .LessEqual, .NotEqual:
		return set_operation(k, Set_Op{kind = .Half, half = o.kind}, o.span, t)
	}
	return report(k, .Unsupported, o.span, fmt.tprintf("not in the kernel yet: the prefix operator %v", o.kind))
}

// negate: `-x`, on a value (known or not) or on a known set.
negate :: proc(k: ^Kernel, o: Op, t: ^Expr) -> ^Expr {
	if is_value(t) {
		d, ok := value_domain(k, t)
		if ok && d == .Ints {
			p, _ := as_poly(t)
			r, r_ok := poly_scale(p, -1)
			if r_ok do return poly_type(r)
		}
		if ok && d == .Floats do return float_neg(t)
		if !ok do return report(k, .Unsupported, o.span, fmt.tprintf("not in the kernel yet: '-' on an unknown of several sorts: %s", print_type(t)))
		return report(k, .Invalid_operator, o.span, fmt.tprintf("'-' expects a number: %s", print_type(t)))
	}
	s, known := color_set(k, t)
	if !known do return report(k, .Unsupported, o.span, "not in the kernel yet: '-' on a set that depends on an unknown")
	d, pure := pure_domain(s)
	switch {
	case pure && d == .Ints:
		return new_expr(set_of_ints(ints_neg(s.ints)))
	case pure && d == .Floats:
		return new_expr(set_of_floats(floats_neg(s.floats)))
	}
	return report(k, .Invalid_operator, o.span, fmt.tprintf("'-' expects numbers: %s", print_set(s)))
}

// --- the cast ---

// `x \ T` forces x into the layout T. Between integers, the low bits are kept:
// (200 + 100) \ u8 is 44, -1 \ u8 is 255, 200 \ i8 is -56. Across sorts, a
// character gives its code, a boolean 0 or 1, a float its integer part; an integer
// gives the float, or the boolean (true if it is not zero). An unknown value that
// already fits in the layout does not change; otherwise the cast stays an
// operation of the equation, whose values are those of the layout.

Layout :: struct {
	kind:   Domain, // .Ints, .Floats, .Bools or .Chars
	bits:   uint,
	signed: bool,
}

cast_into :: proc(k: ^Kernel, o: Op, a, t: ^Expr) -> ^Expr {
	target, closed := color_set(k, t)
	layout, is_layout := layout_of(target)
	if !closed || !is_layout do return report(k, .Invalid_Cast, o.span, fmt.tprintf("one can only cast to a layout — an integer of 8 to 64 bits, a float, a boolean, a character: %s", brief(t)))
	if v, known := a^.(Set); known {
		x, atom := atom_of(v)
		r, ok := cast_atom(x, layout)
		if !atom || !ok do return report(k, .Invalid_Cast, o.span, fmt.tprintf("%s does not cast to %s", brief(a), brief(t)))
		return new_expr(set_of_atoms({r}))
	}
	if !is_value(a) do return report(k, .Invalid_Cast, o.span, fmt.tprintf("one can only cast a value: %s", brief(a)))
	if d, ok := value_domain(k, a); ok && d == layout.kind {
		if env, _ := envelope(k, a); atoms_subset(env, target) do return a // it already fits in it
	}
	args := make([]^Expr, 2)
	args[0], args[1] = a, new_expr(target)
	return new_expr(Term{op = .Cast, args = args})
}

// layout_of: the set is that of a layout.
layout_of :: proc(s: Set) -> (Layout, bool) {
	kind, pure := pure_domain(s)
	if !pure do return {}, false
	#partial switch kind {
	case .Ints:
		lo, hi := ints_bounds(s.ints)
		l, l_ok := lo.?
		h, h_ok := hi.?
		if !l_ok || !h_ok || len(s.ints.intervals) != 1 do return {}, false
		for bits in ([?]uint{8, 16, 32, 64}) {
			span := i128(1) << bits
			if l == 0 && h == span - 1 do return Layout{.Ints, bits, false}, true
			if l == -span / 2 && h == span / 2 - 1 do return Layout{.Ints, bits, true}, true
		}
	case .Floats:
		if set_equal(s, set_of_floats(floats_all())) do return Layout{kind = .Floats}, true
	case .Bools:
		if set_equal(s, set_of_bools({.False, .True})) do return Layout{kind = .Bools}, true
	case .Chars:
		if set_equal(s, set_of_chars(chars_all())) do return Layout{kind = .Chars}, true
	}
	return {}, false
}

// cast_atom: a known value, forced into the layout.
cast_atom :: proc(x: Atom, l: Layout) -> (Atom, bool) {
	as_int: i128
	switch v in x {
	case i128:
		as_int = v
	case Char_Atom:
		as_int = i128(v)
	case bool:
		as_int = v ? 1 : 0
	case f64:
		if l.kind == .Floats do return v, true
		if v != v || v > 1e38 || v < -1e38 do return nil, false // NaN, or beyond i128
		as_int = i128(v) // the integer part
	case string:
		return nil, false
	}
	switch l.kind {
	case .Ints:
		span := i128(1) << l.bits
		r := as_int %% span
		if l.signed && r >= span / 2 do r -= span
		return r, true
	case .Floats:
		return f64(as_int), true
	case .Bools:
		return as_int != 0, true
	case .Chars:
		if as_int < 0 || as_int > i128(max(rune)) do return nil, false
		return Char_Atom(as_int), true
	case .Strings, .Scopes, .Sets:
	}
	return nil, false
}

// --- the division ---

// Between integers, `/` truncates toward zero and `%` gives the remainder, with
// the sign of the dividend — the machine's division. The divisor is never 0: if it
// can be, in the context where the division is written, it is an error. Between
// floats, it is the IEEE 754 division, without error (x / 0 is ±∞). On unknowns,
// the division stays an operation of the equation; x / 1 is x, x % 1 is 0, and
// x % d is x when x is already in 0..d - 1.
division :: proc(k: ^Kernel, o: Op, a, b: ^Expr, ctx: Context) -> ^Expr {
	if !is_value(a) || !is_value(b) do return report(k, .Unsupported, o.span, "not in the kernel yet: the division of sets")
	da, a_ok := value_domain(k, a)
	db, b_ok := value_domain(k, b)
	op_name := o.kind == .Divide ? "/" : "%"
	if !a_ok || !b_ok || da != db || (da != .Ints && da != .Floats) || (da == .Floats && o.kind == .Mod) {
		return report(k, .Invalid_operator, o.span, fmt.tprintf("'%s' does not apply to %s and %s", op_name, brief(a), brief(b)))
	}
	if da == .Floats {
		x, x_known := float_atom(a)
		y, y_known := float_atom(b)
		if x_known && y_known do return new_expr(set_of_floats(floats_point(x / y)))
		return new_expr(Term{op = .F_Div, args = pair(a, b)})
	}
	divisor, _ := envelope(k, b, ctx)
	if ints_contains(divisor.ints, 0) do return report(k, .Invalid_operator, o.span, fmt.tprintf("the divisor %s can be 0", brief(b)))
	x, x_known := int_atom(a)
	y, y_known := int_atom(b)
	if x_known && y_known do return new_expr(set_of_ints(ints_point(o.kind == .Divide ? x / y : x % y)))
	if y_known && y == 1 do return o.kind == .Divide ? a : new_expr(set_of_ints(ints_point(0)))
	if y_known && y > 0 && o.kind == .Mod {
		if values, _ := envelope(k, a, ctx); ints_subset(values.ints, ints_range(0, y - 1)) do return a
	}
	return new_expr(Term{op = o.kind == .Divide ? .Div : .Mod, args = pair(a, b)})
}

pair :: proc(a, b: ^Expr) -> []^Expr {
	args := make([]^Expr, 2)
	args[0], args[1] = a, b
	return args
}

int_atom :: proc(t: ^Expr) -> (i128, bool) {
	s, is_set := t^.(Set)
	if !is_set do return 0, false
	x, ok := atom_of(s)
	v, is_int := x.(i128)
	return v, ok && is_int
}

float_atom :: proc(t: ^Expr) -> (f64, bool) {
	s, is_set := t^.(Set)
	if !is_set do return 0, false
	x, ok := atom_of(s)
	v, is_float := x.(f64)
	return v, ok && is_float
}

// div_envelope: the possible quotients, a and b two sets of integers, b without 0
// and of a single sign — the truncated division is monotone in each operand there:
// its extremes are at the corners.
div_envelope :: proc(a, b: Ints) -> Ints {
	alo, ahi := ints_bounds(a)
	blo, bhi := ints_bounds(b)
	al, al_ok := alo.?
	ah, ah_ok := ahi.?
	bl, bl_ok := blo.?
	bh, bh_ok := bhi.?
	if !al_ok || !ah_ok || !bl_ok || !bh_ok || (bl <= 0 && bh >= 0) do return ints_all()
	q := [4]i128{al / bl, al / bh, ah / bl, ah / bh}
	return ints_range(min(q[0], q[1], q[2], q[3]), max(q[0], q[1], q[2], q[3]))
}

// mod_envelope: the possible remainders — of absolute value below the largest
// |b|, with the sign of the dividend (the remainder is not monotone: no corners).
mod_envelope :: proc(a, b: Ints) -> Ints {
	blo, bhi := ints_bounds(b)
	bl, bl_ok := blo.?
	bh, bh_ok := bhi.?
	if !bl_ok || !bh_ok do return ints_all()
	m := max(abs(bl), abs(bh)) - 1
	alo, ahi := ints_bounds(a)
	lo, hi := -m, m
	if l, ok := alo.?; ok do lo = l >= 0 ? 0 : max(l, -m)
	if h, ok := ahi.?; ok do hi = h <= 0 ? 0 : min(h, m)
	return ints_range(lo, hi)
}
