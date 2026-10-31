package kernel

import syn "../syntax"
import "core:fmt"
import "core:slice"

// OPERATORS (specs/types.md §4.5, §4.6)
//
// An operator applies only to types proven to be in a family it accepts; otherwise
// it is illegal. The proof is the check's (prove.odin). It distributes over |: on
// constant sets it computes the image when the image is a normal form — ranges for
// + and -, booleans for the comparisons, strings for + and *, any operator on single
// primitives. On integers over unknowns, the laws of a ring give the normal form
// of a sum of products. What no law reduces stays the operation.

Family :: enum u8 {
	Int,
	Real,
	String, // characters included: a character is a string of length 1
	Char,
	Bool,
	Count, // an integer ≥ 0: the count of a repetition, of a shift
	Nonzero_Int, // a divisor: int & ~0
	Nonzero_Real, // float & ~0.0
}

// family_term: a family as a type, in normal form.
family_term :: proc(f: Family) -> Type {
	switch f {
	case .Int:
		return EVERY_INT
	case .Real:
		return EVERY_REAL
	case .String:
		return STRING
	case .Char:
		return EVERY_CHAR
	case .Bool:
		return BOOLS
	case .Count:
		return COUNTS
	case .Nonzero_Int:
		return NONZERO_INT
	case .Nonzero_Real:
		return NONZERO_REAL
	}
	return None{}
}

Signature :: struct {
	args:   [2]Family,
	result: Family,
}

signatures :: proc(op: Operator) -> []Signature {
	@(static) add := []Signature{{{.Int, .Int}, .Int}, {{.Real, .Real}, .Real}, {{.String, .String}, .String}}
	@(static) sub := []Signature{{{.Int, .Int}, .Int}, {{.Real, .Real}, .Real}}
	@(static) mul := []Signature{{{.Int, .Int}, .Int}, {{.Real, .Real}, .Real}, {{.String, .Count}, .String}}
	@(static) div := []Signature{{{.Int, .Nonzero_Int}, .Int}, {{.Real, .Nonzero_Real}, .Real}}
	@(static) modulo := []Signature{{{.Int, .Nonzero_Int}, .Int}}
	@(static) power := []Signature{{{.Int, .Count}, .Int}, {{.Real, .Count}, .Real}}
	@(static) shift := []Signature{{{.Int, .Int}, .Int}}
	@(static) bits := []Signature{{{.Int, .Int}, .Int}, {{.Bool, .Bool}, .Bool}}
	@(static) compare := []Signature{{{.Int, .Int}, .Bool}, {{.Real, .Real}, .Bool}, {{.Char, .Char}, .Bool}}
	@(static) round := []Signature{{{.Real, .Int}, .Real}}
	#partial switch op {
	case .Round:
		return round
	case .Add:
		return add
	case .Sub, .Neg:
		return sub
	case .Mul:
		return mul
	case .Div:
		return div
	case .Mod:
		return modulo
	case .Pow:
		return power
	case .Shl, .Shr:
		return shift
	case .Bit_And, .Bit_Or, .Xor, .Bit_Not:
		return bits
	case .Less, .Less_Eq, .Greater, .Greater_Eq:
		return compare
	}
	return nil
}

// family_of: the family of an atom, by its form: a primitive, an unknown whose
// layout is in one family, an operation by the family of its result.
family_of :: proc(k: ^Kernel, t: Type) -> (Family, bool) {
	#partial switch v in t {
	case Int:
		return .Int, true
	case Real:
		return .Real, true
	case Char:
		return .Char, true
	case Bool:
		return .Bool, true
	case ^Unknown:
		if v.call != nil do return call_family(k, v.call)
		return layout_family(k, layout_of(k, v))
	case ^Operation:
		if v.op == .In do return .Bool, true
		if is_string_value(t) do return .String, true
		// a recursive call whose equation is being given fits any family
		families: [2]Maybe(Family)
		for a, i in v.args {
			if i >= 2 do break
			f, ok := family_of(k, a)
			if ok {
				families[i] = f
			} else if !is_pending_call(a) {
				return {}, false
			}
		}
		// the operation was proven legal when it was built: its operands are read in
		// the families the signature restricts (a divisor, a count, in the integers)
		next: for sig in signatures(v.op) {
			for f, i in families[:min(len(v.args), 2)] do if g, known := f.?; known && !family_holds(domain(sig.args[i]), g) do continue next
			return sig.result, true
		}
	case ^Collapse:
		if v.recursive do return call_family(k, v)
	case ^Fold:
		return family_of(k, v.value)
	case ^Least:
		return .Int, true
	case ^Series:
		return family_of(k, v.term)
	case ^Recurrent:
		return .Int, true
	case ^Or, ^And, ^Not, ^Range:
		if is_constant(t) do return layout_family(k, t)
	case ^Pattern:
		f: Maybe(Family)
		for b in v.branches {
			g, ok := family_of(k, b.product)
			if !ok do return {}, false
			if current, set := f.?; set && current != g do return {}, false
			f = g
		}
		return f.?
	}
	return {}, false
}

// domain: the family a restricted one is taken in.
domain :: proc(f: Family) -> Family {
	#partial switch f {
	case .Nonzero_Int, .Count:
		return .Int
	case .Nonzero_Real:
		return .Real
	}
	return f
}

// family_holds: an atom of the family `of` is in the family `f` without more proof.
family_holds :: proc(f, of: Family) -> bool {
	return f == of || (f == .String && of == .Char)
}

// layout_family: the one family the elements of a layout are in.
layout_family :: proc(k: ^Kernel, layout: Type) -> (Family, bool) {
	for f in ([]Family{.Int, .Real, .Bool, .Char, .String}) {
		if proven_in(k, layout, family_term(f)) do return f, true
	}
	return {}, false
}

// legal_signature: the first signature whose families are proven to hold the
// operands. A recursive call has the family of its equation; while its equation
// is being given, the operator on it is checked once it is (recursion.odin).
legal_signature :: proc(k: ^Kernel, op: Operator, args: []Type) -> (Signature, bool) {
	next: for sig in signatures(op) {
		for a, i in args {
			if c, is_call := as_call(a); is_call {
				if f, known := call_family(k, c); known && !family_holds(sig.args[min(i, 1)], f) do continue next
				continue
			}
			// an operation is in the family its signature gives: 100 / (n + 1) is an
			// integer; a pattern, in that of its products, one of which it gives; a
			// divisor, a count, is still proven
			#partial switch _ in a {
			case ^Operation, ^Pattern:
				if f, known := family_of(k, a); known && family_holds(sig.args[min(i, 1)], f) do continue
			}
			if !proven_in(k, a, family_term(sig.args[min(i, 1)])) do continue next
		}
		return sig, true
	}
	return {}, false
}

operation_law :: proc(k: ^Kernel, op: Operator, args: []Type, span: syn.Span) -> Type {
	for a in args do if is_invalid(a) do return a
	if op == .Round do return round_law(k, args[0], bits_format(args[1]), span)
	if f := operands_format(k, op, args); f != .Exact {
		// on values of a format, what the machine computes: the exact result, rounded
		// to the widest; a known operand is first rounded to it (format.odin)
		rounded := make([]Type, len(args))
		for a, i in args do rounded[i] = is_constant(a) && !(op == .Pow && i == 1) ? round_law(k, a, f, span) : a
		return round_law(k, exact_law(k, op, rounded, span), f, span)
	}
	return exact_law(k, op, args, span)
}

// exact_law: the operation on its operands, exactly.
exact_law :: proc(k: ^Kernel, op: Operator, args: []Type, span: syn.Span) -> Type {
	if len(args) > 2 {
		// + and * are associative: a + b + c = (a + b) + c
		out := operation_law(k, op, args[:2], span)
		for a in args[2:] do out = operation_law(k, op, {out, a}, span)
		return out
	}
	if op == .In do return in_law(k, args[0], args[1])
	for a in args do if is_none(a) do return None{} // none op c = none
	sig, legal := legal_signature(k, op, args)
	if !legal do return problem(.Invalid_operator, span, fmt.tprintf("`%s` is not proven to apply to %s", operator_text[op], print_types(args)))
	if is_comparison(op) && (sig.args[0] == .Int || sig.args[0] == .Real) && !is_constant(args[0]) && !is_constant(args[1]) {
		// the order is that of a ring: x < y = x - y < 0
		zero: Type = sig.args[0] == .Int ? Type(Int(0)) : Type(real_int(0))
		return operation_law(k, op, {operation_law(k, .Sub, args, span), zero}, span)
	}
	if bound, x, ok := comparison_bound(op, args); ok do return in_law(k, x, normal(k, bound))
	constant := true
	for a in args do constant &&= is_constant(a)
	if constant {
		if r, exact := compute(k, op, sig, args); exact do return r
		return new_operation(op, ..args)
	}
	if op == .Pow do return single(k, power_law(k, sig, args[0], args[1], span))
	out: Type
	#partial switch sig.args[0] {
	case .Int:
		if r, ok := ring_law(op, args); ok do out = r
		else if r, ok := atom_ring(k, op, args); ok do out = r
	case .Bool:
		out = bool_law(k, op, args)
	case .String:
		if op == .Add do out = concatenation(args)
	}
	if out == nil do out = new_operation(op, ..args)
	return single(k, out)
}

// single: a term over unknowns whose layout is one primitive is that primitive:
// ?ₖ::p = p, and so is what an operator gives of it (§4.5, §7).
single :: proc(k: ^Kernel, t: Type) -> Type {
	if _, is_op := t.(^Operation); !is_op || is_constant(t) do return t
	if image, ok := layout_image(k, t); ok && is_primitive(image) do return image
	return t
}

is_comparison :: proc(op: Operator) -> bool {
	#partial switch op {
	case .Less, .Less_Eq, .Greater, .Greater_Eq:
		return true
	}
	return false
}

// comparison_bound: x < c = x in <c, and likewise for <= > >= (§4.3), when c is
// one primitive and x is not a constant: the comparison is then an atom of `in`.
comparison_bound :: proc(op: Operator, args: []Type) -> (bound: Type, x: Type, ok: bool) {
	#partial switch op {
	case .Less, .Less_Eq, .Greater, .Greater_Eq:
	case:
		return
	}
	order := op
	c := args[1]
	x = args[0]
	if !is_constant(c) {
		// c op x = x op' c
		x, c = c, x
		#partial switch op {
		case .Less:
			order = .Greater
		case .Less_Eq:
			order = .Greater_Eq
		case .Greater:
			order = .Less
		case .Greater_Eq:
			order = .Less_Eq
		}
	}
	if is_constant(x) do return
	#partial switch _ in c {
	case Int, Real, Char:
	case:
		return
	}
	#partial switch order {
	case .Less:
		bound = new_and(new_range(nil, c), new_not(c))
	case .Less_Eq:
		bound = new_range(nil, c)
	case .Greater:
		bound = new_and(new_range(c, nil), new_not(c))
	case .Greater_Eq:
		bound = new_range(c, nil)
	}
	return bound, x, true
}

// compute: an operator on constant sets is the | of its results on their elements
// (§4.5). It is computed when that is a normal form: on cells,
//
//   (a..b) + (c..d) = (a + c)..(b + d)      -(a..b) = -b..-a      [~]x = -x - 1
//   (a..b) < (c..d) = true when b < c, false when d <= a, else false | true
//   (a..b) * (c..d) = the least..the greatest of the products at the bounds (reals)
//
// and any operator on two primitives; + and * on strings by their laws.
compute :: proc(k: ^Kernel, op: Operator, sig: Signature, args: []Type) -> (result: Type, ok: bool) {
	from := mark(k)
	defer release(k, from)
	cells := make([][]Type, len(args), context.temp_allocator)
	for a, i in args {
		c, negated := cells_of(k, a)
		if negated || len(c) == 0 do return nil, false
		cells[i] = c
	}
	#partial switch sig.args[0] {
	case .Int:
		for c in cells do if !all_of_family(c, .Int) do return nil, false
		#partial switch op {
		case .Add:
			return int_sum(k, cells[0], cells[1])
		case .Sub:
			opposite := int_opposite(k, cells[1]) or_return
			return int_sum(k, cells[0], opposite)
		case .Neg:
			opposite := int_opposite(k, cells[0]) or_return
			return cells_term(k, join_discrete(k, .Int, opposite)), true
		case .Bit_Not:
			// [~]x = -x - 1
			opposite := int_opposite(k, cells[0]) or_return
			return int_sum(k, opposite, {Int(-1)})
		case .Less, .Less_Eq, .Greater, .Greater_Eq:
			lo_a, hi_a := discrete_hull(cells[0])
			lo_b, hi_b := discrete_hull(cells[1])
			return compare_bounds(op, lo_a, hi_a, lo_b, hi_b), true
		}
		x, single_x := one_primitive(cells[0]).(Int)
		y, single_y := one_primitive(cells[1]).(Int)
		if !single_x || !single_y do return nil, false
		v, computed := int_operation(op, i128(x), i128(y))
		return Int(v), computed
	case .Real:
		if op == .Pow {
			x, single_x := one_primitive(cells[0]).(Real)
			n, single_n := one_primitive(cells[1]).(Int)
			if !single_x || !single_n do return nil, false
			return real_power(x, i128(n))
		}
		for c in cells do if !all_of_family(c, .Real) do return nil, false
		#partial switch op {
		case .Add:
			return real_sum(k, cells[0], cells[1])
		case .Sub:
			opposite := real_opposite(k, cells[1]) or_return
			return real_sum(k, cells[0], opposite)
		case .Neg:
			opposite := real_opposite(k, cells[0]) or_return
			return cells_term(k, join_reals(k, opposite)), true
		case .Less, .Less_Eq, .Greater, .Greater_Eq:
			return compare_reals(op, cells[0], cells[1]), true
		case .Mul:
			if product, exact := real_product(k, cells[0], cells[1]); exact do return product, true
		}
		x, single_x := one_primitive(cells[0]).(Real)
		y, single_y := one_primitive(cells[1]).(Real)
		if !single_x || !single_y do return nil, false
		if op == .Div {
			q := real_div(x, y) or_return
			return q, true
		}
	case .String:
		#partial switch op {
		case .Add:
			return concatenation(args), true
		case .Mul:
			return repetition(args[0], args[1]), true
		}
	case .Char:
		for c in cells do if !all_of_family(c, .Char) do return nil, false
		lo_a, hi_a := discrete_hull(cells[0])
		lo_b, hi_b := discrete_hull(cells[1])
		return compare_bounds(op, lo_a, hi_a, lo_b, hi_b), true
	case .Bool:
		results := mark(k)
		for x in cells[0] {
			p := bool(x.(Bool))
			if op == .Bit_Not {
				push(k, Bool(!p))
				continue
			}
			for y in cells[1] {
				q := bool(y.(Bool))
				#partial switch op {
				case .Bit_And:
					push(k, Bool(p && q))
				case .Bit_Or:
					push(k, Bool(p || q))
				case .Xor:
					push(k, Bool(p != q))
				}
			}
		}
		return cells_term(k, union_cells(k, pushed(k, results))), true
	}
	return nil, false
}

all_of_family :: proc(cells: []Type, f: Cell_Family) -> bool {
	for c in cells do if cell_family(c) != f do return false
	return true
}

one_primitive :: proc(cells: []Type) -> Type {
	if len(cells) != 1 || !is_primitive(cells[0]) do return nil
	return cells[0]
}

// discrete_hull: the least and greatest elements of sorted integer or character
// cells.
discrete_hull :: proc(cells: []Type) -> (lo, hi: Maybe(i128)) {
	lo, _ = discrete_bounds(cells[0])
	_, hi = discrete_bounds(cells[len(cells) - 1])
	return
}

// int_sum: (a..b) + (c..d) = (a + c)..(b + d), on each pair of cells; false when a
// bound is beyond the integers written here.
int_sum :: proc(k: ^Kernel, a, b: []Type) -> (sum: Type, ok: bool) {
	from := mark(k)
	defer release(k, from)
	for x in a {
		for y in b {
			lo_x, hi_x := discrete_bounds(x)
			lo_y, hi_y := discrete_bounds(y)
			lo := add_bound(lo_x, lo_y) or_return
			hi := add_bound(hi_x, hi_y) or_return
			push(k, discrete_cell(.Int, lo, hi))
		}
	}
	return cells_term(k, join_discrete(k, .Int, pushed(k, from))), true
}

// int_opposite: -(a..b) = -b..-a, pushed.
int_opposite :: proc(k: ^Kernel, cells: []Type) -> (opposite: []Type, ok: bool) {
	from := mark(k)
	for c in cells {
		lo, hi := discrete_bounds(c)
		x := neg_bound(hi) or_return
		y := neg_bound(lo) or_return
		push(k, discrete_cell(.Int, x, y))
	}
	return pushed(k, from), true
}

// real_sum: (a..b) + (c..d) = (a + c)..(b + d), open where either bound is.
real_sum :: proc(k: ^Kernel, a, b: []Type) -> (sum: Type, ok: bool) {
	from := mark(k)
	defer release(k, from)
	for x in a {
		for y in b {
			p, q := real_bounds(x), real_bounds(y)
			r: Real_Bounds
			if u, has_u := p.lo.?; has_u {
				if v, has_v := q.lo.?; has_v do r.lo, r.lo_open = real_add(u, v) or_return, p.lo_open || q.lo_open
			}
			if u, has_u := p.hi.?; has_u {
				if v, has_v := q.hi.?; has_v do r.hi, r.hi_open = real_add(u, v) or_return, p.hi_open || q.hi_open
			}
			push(k, real_cell(r))
		}
	}
	return cells_term(k, join_reals(k, pushed(k, from))), true
}

// real_opposite: -(a..b) = -b..-a, pushed.
real_opposite :: proc(k: ^Kernel, cells: []Type) -> (opposite: []Type, ok: bool) {
	from := mark(k)
	for c in cells {
		p := real_bounds(c)
		r := Real_Bounds{lo_open = p.hi_open, hi_open = p.lo_open, format = p.format} // a format is symmetric
		if v, has := p.hi.?; has do r.lo = real_neg(v) or_return
		if v, has := p.lo.?; has do r.hi = real_neg(v) or_return
		push(k, real_cell(r))
	}
	return pushed(k, from), true
}

// real_product: (a..b) * (c..d) on closed, bounded intervals: the image of a
// connected set by a continuous operator is the interval between its least and
// greatest products at the bounds. False for an open or infinite bound.
real_product :: proc(k: ^Kernel, a, b: []Type) -> (product: Type, ok: bool) {
	from := mark(k)
	defer release(k, from)
	for x in a {
		for y in b {
			p, q := real_bounds(x), real_bounds(y)
			if p.lo_open || p.hi_open || q.lo_open || q.hi_open do return nil, false
			u1, has_u1 := p.lo.?
			u2, has_u2 := p.hi.?
			v1, has_v1 := q.lo.?
			v2, has_v2 := q.hi.?
			if !has_u1 || !has_u2 || !has_v1 || !has_v2 do return nil, false
			corners: [4]Real
			corners[0] = real_mul(u1, v1) or_return
			corners[1] = real_mul(u1, v2) or_return
			corners[2] = real_mul(u2, v1) or_return
			corners[3] = real_mul(u2, v2) or_return
			lo, hi := corners[0], corners[0]
			for c in corners[1:] {
				if real_less(c, lo) do lo = c
				if real_less(hi, c) do hi = c
			}
			push(k, real_cell({lo = lo, hi = hi}))
		}
	}
	return cells_term(k, join_reals(k, pushed(k, from))), true
}

int_operation :: proc(op: Operator, x, y: i128) -> (i128, bool) {
	#partial switch op {
	case .Mul:
		return mul_checked(x, y)
	case .Div:
		if x == min(i128) && y == -1 do return 0, false
		return x / y, true
	case .Mod:
		if x == min(i128) && y == -1 do return 0, true
		return x % y, true
	case .Pow:
		return int_power(x, y)
	case .Bit_And:
		return x & y, true
	case .Bit_Or:
		return x | y, true
	case .Xor:
		return x ~ y, true
	case .Shl:
		// x << y = x * 2^y; a negative count, or a result beyond the integers, is not computed
		if y < 0 || y >= 127 do return 0, false
		return mul_checked(x, i128(1) << uint(y))
	case .Shr:
		if y < 0 do return 0, false
		return y >= 127 ? (x < 0 ? -1 : 0) : x >> uint(y), true
	}
	return 0, false
}

// int_power: x ** y, y ≥ 0, by squaring; not computed beyond the integers written
// here.
int_power :: proc(x, y: i128) -> (out: i128, ok: bool) {
	if y < 0 do return 0, false
	out = 1
	base, e := x, y
	for e > 0 {
		if e & 1 == 1 do out = mul_checked(out, base) or_return
		e >>= 1
		if e > 0 do base = mul_checked(base, base) or_return
	}
	return out, true
}

// real_power: x ** n, n ≥ 0, exactly.
real_power :: proc(x: Real, n: i128) -> (out: Real, ok: bool) {
	if n < 0 do return {}, false
	out = real_int(1)
	base, e := x, n
	for e > 0 {
		if e & 1 == 1 do out = real_mul(out, base) or_return
		e >>= 1
		if e > 0 do base = real_mul(base, base) or_return
	}
	return out, true
}

// power_law: x ** n, n a count, by the laws of powers:
//
//   x ** 0 = 1     x ** 1 = x     1 ** n = 1     0 ** n = 0, n ≥ 1
//   (x ** a) ** b = x ** (a * b)
//   (c·x·y…) ** e = cᵉ·xᵉ·yᵉ…, e an integer: a monomial of the ring
power_law :: proc(k: ^Kernel, sig: Signature, x, n: Type, span: syn.Span) -> Type {
	one: Type = sig.args[0] == .Int ? Type(Int(1)) : Type(real_int(1))
	if e, constant := n.(Int); constant {
		switch {
		case e == 0:
			return one
		case e == 1:
			return x
		}
		if sig.args[0] == .Int {
			if ms, d, ring := monomials(x); ring && len(ms) == 1 && d == 1 {
				out: Type = Int(1)
				for _ in 0 ..< e {
					next, ok := ring_law(.Mul, {out, ms[0]})
					if !ok {
						out = nil
						break
					}
					out = next
				}
				if out != nil do return out
			}
		}
	}
	if same(k, x, one) do return one
	if z, is_int := x.(Int); is_int && z == 0 && proven_in(k, n, POSITIVE) do return Int(0)
	if inner, is_op := x.(^Operation); is_op && inner.op == .Pow {
		return operation_law(k, .Pow, {inner.args[0], operation_law(k, .Mul, {inner.args[1], n}, span)}, span)
	}
	return new_operation(.Pow, x, n)
}

// compare_bounds: the booleans x op y takes, x from lo_a to hi_a, y from lo_b to
// hi_b: `x < y` happens when lo_a < hi_b, `x >= y` when hi_a >= lo_b.
compare_bounds :: proc(op: Operator, lo_a, hi_a, lo_b, hi_b: Maybe(i128)) -> Type {
	below :: proc(x, y: Maybe(i128)) -> bool {
		u, has_u := x.?
		v, has_v := y.?
		return !has_u || !has_v || u < v
	}
	at_most :: proc(x, y: Maybe(i128)) -> bool {
		u, has_u := x.?
		v, has_v := y.?
		return !has_u || !has_v || u <= v
	}
	yes, no: bool
	#partial switch op {
	case .Less:
		yes, no = below(lo_a, hi_b), at_most(lo_b, hi_a)
	case .Less_Eq:
		yes, no = at_most(lo_a, hi_b), below(lo_b, hi_a)
	case .Greater:
		yes, no = below(lo_b, hi_a), at_most(lo_a, hi_b)
	case .Greater_Eq:
		yes, no = at_most(lo_b, hi_a), below(lo_a, hi_b)
	}
	return booleans(yes, no)
}

compare_reals :: proc(op: Operator, a, b: []Type) -> Type {
	Edge :: struct {
		v:      Maybe(Real),
		closed: bool,
	}
	inf :: proc(cells: []Type) -> Edge {r := real_bounds(cells[0]);return {r.lo, !r.lo_open}}
	sup :: proc(cells: []Type) -> Edge {r := real_bounds(cells[len(cells) - 1]);return {r.hi, !r.hi_open}}
	below :: proc(x, y: Edge) -> bool {
		u, has_u := x.v.?
		v, has_v := y.v.?
		return !has_u || !has_v || real_less(u, v)
	}
	at_most :: proc(x, y: Edge) -> bool {
		u, has_u := x.v.?
		v, has_v := y.v.?
		return !has_u || !has_v || real_less(u, v) || (u == v && x.closed && y.closed)
	}
	yes, no: bool
	#partial switch op {
	case .Less:
		yes, no = below(inf(a), sup(b)), at_most(inf(b), sup(a))
	case .Less_Eq:
		yes, no = at_most(inf(a), sup(b)), below(inf(b), sup(a))
	case .Greater:
		yes, no = below(inf(b), sup(a)), at_most(inf(a), sup(b))
	case .Greater_Eq:
		yes, no = at_most(inf(b), sup(a)), below(inf(a), sup(b))
	}
	return booleans(yes, no)
}

booleans :: proc(yes, no: bool) -> Type {
	switch {
	case yes && no:
		return new_or(Bool(false), Bool(true))
	case yes:
		return Bool(true)
	case no:
		return Bool(false)
	}
	return None{}
}

// bool_law: [&] [|] ^ [~] by the laws of a Boolean algebra: the neutral and
// absorbing elements, [~][~]a = a. Read back, the laws of `in` (§4.7) make the
// atoms on one unknown one atom:
//
//   (u in a) [|] (u in b) = u in a | b        (u in a) [&] (u in b) = u in a & b
//
// [~](u in a) being u in ~a.
bool_law :: proc(k: ^Kernel, op: Operator, args: []Type) -> Type {
	a := args[0]
	if op == .Bit_Not {
		if is_bool(a, true) do return Bool(false)
		if is_bool(a, false) do return Bool(true)
		if n, ok := a.(^Operation); ok && n.op == .Bit_Not do return n.args[0]
		return new_operation(.Bit_Not, a)
	}
	b := args[1]
	if op == .Xor {
		if is_bool(a, false) do return b
		if is_bool(b, false) do return a
		return new_operation(op, a, b)
	}
	from := mark(k)
	defer release(k, from)
	flatten_bool(k, op, a)
	flatten_bool(k, op, b)
	terms := pushed(k, from)
	// the atoms on one value, combined: (x in A) [|] (x in B) = x in (A | B), and
	// likewise [&] and &; each term's atom, x and S, read once, side by side
	atoms := mark(k)
	for t in terms {
		x, s, ok := literal(k, t)
		push(k, ok ? x : nil)
		push(k, s)
	}
	value :: proc(k: ^Kernel, atoms, i: int) -> Type {return k.scratch[atoms + 2 * i]}
	// on_one: the atom of the term i shares its value with another one
	on_one :: proc(k: ^Kernel, atoms, n, i: int) -> bool {
		x := value(k, atoms, i)
		if x == nil do return false
		for j in 0 ..< n do if j != i && value(k, atoms, j) != nil && same(k, x, value(k, atoms, j)) do return true
		return false
	}
	kept := mark(k)
	for t, i in terms do if !on_one(k, atoms, len(terms), i) do push(k, t)
	// the atoms on one value, at the place of the first, their sets combined in order
	next: for i in 0 ..< len(terms) {
		x := value(k, atoms, i)
		if x == nil || !on_one(k, atoms, len(terms), i) do continue
		for j in 0 ..< i do if value(k, atoms, j) != nil && same(k, x, value(k, atoms, j)) do continue next
		set := k.scratch[atoms + 2 * i + 1]
		for j in i + 1 ..< len(terms) {
			if y := value(k, atoms, j); y != nil && same(k, x, y) {
				s := k.scratch[atoms + 2 * j + 1]
				set = op == .Bit_Or ? or_law(k, {set, s}) : and_law(k, {set, s})
			}
		}
		push(k, in_law(k, x, set))
	}
	absorbing := op == .Bit_Or
	out: Type
	for t in pushed(k, kept) {
		if is_bool(t, absorbing) do return Bool(absorbing)
		if is_bool(t, !absorbing) do continue
		out = out == nil ? t : new_operation(op, out, t)
	}
	return out == nil ? Type(Bool(!absorbing)) : out
}

flatten_bool :: proc(k: ^Kernel, op: Operator, t: Type) {
	if o, ok := t.(^Operation); ok && o.op == op {
		for a in o.args do flatten_bool(k, op, a)
		return
	}
	push(k, t)
}

// literal: t is `x in S`, or `[~](x in S)` read as x in ~S: x one value — an
// unknown, or a term over them —, S a constant type the laws compute whole.
literal :: proc(k: ^Kernel, t: Type) -> (Type, Type, bool) {
	positive := true
	atom := t
	if n, ok := t.(^Operation); ok && n.op == .Bit_Not {
		positive = false
		atom = n.args[0]
	}
	o, is_op := atom.(^Operation)
	if !is_op || o.op != .In do return nil, nil, false
	if !is_value(k, o.args[0]) || !decided(o.args[1]) do return nil, nil, false
	return o.args[0], positive ? o.args[1] : not_law(k, o.args[1]), true
}

bool_and :: proc(k: ^Kernel, a, b: Type) -> Type {return bool_law(k, .Bit_And, {a, b})}
bool_or :: proc(k: ^Kernel, a, b: Type) -> Type {return bool_law(k, .Bit_Or, {a, b})}
bool_not :: proc(k: ^Kernel, a: Type) -> Type {return bool_law(k, .Bit_Not, {a})}
