package kernel

import syn "../compiler"
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
		return new_range(nil, nil, .Int)
	case .Real:
		return new_range(nil, nil, .Real)
	case .String:
		return string_term()
	case .Char:
		return new_range(Char(0), nil)
	case .Bool:
		return new_or(Bool(false), Bool(true))
	case .Count:
		return new_range(Int(0), nil, .Int)
	case .Nonzero_Int:
		return cells_term({discrete_cell(.Int, nil, -1), discrete_cell(.Int, 1, nil)})
	case .Nonzero_Real:
		return cells_term({real_cell({hi = 0.0, hi_open = true}), real_cell({lo = 0.0, lo_open = true})})
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
	@(static) shift := []Signature{{{.Int, .Int}, .Int}}
	@(static) bits := []Signature{{{.Int, .Int}, .Int}, {{.Bool, .Bool}, .Bool}}
	@(static) compare := []Signature{{{.Int, .Int}, .Bool}, {{.Real, .Real}, .Bool}, {{.Char, .Char}, .Bool}}
	#partial switch op {
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
		return layout_family(k, layout_of(k, v))
	case ^Operation:
		if v.op == .In do return .Bool, true
		if is_string_value(t) do return .String, true
		families: [2]Family
		for a, i in v.args {
			if i >= 2 do break
			f, ok := family_of(k, a)
			if !ok do return {}, false
			families[i] = f
		}
		for sig in signatures(v.op) {
			if family_holds(sig.args[0], families[0]) && (len(v.args) < 2 || family_holds(sig.args[1], families[1])) do return sig.result, true
		}
	case ^Collapse:
		if v.recursive do return hypothesis(k, v)
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
// operands. A recursive call has the family the operator needs of it: the
// hypothesis of an induction, checked once its equation is given (recursion.odin).
legal_signature :: proc(k: ^Kernel, op: Operator, args: []Type) -> (Signature, bool) {
	next: for sig in signatures(op) {
		for a, i in args {
			if c, is_call := a.(^Collapse); is_call && c.recursive {
				if f, assumed := hypothesis(k, c); assumed && !family_holds(sig.args[min(i, 1)], f) do continue next
				continue
			}
			if !proven_in(k, a, family_term(sig.args[min(i, 1)])) do continue next
		}
		for a, i in args do if c, is_call := a.(^Collapse); is_call && c.recursive do assume(k, c, sig.args[min(i, 1)])
		return sig, true
	}
	return {}, false
}

operation_law :: proc(k: ^Kernel, op: Operator, args: []Type, span: syn.Span) -> Type {
	for a in args do if is_invalid(a) do return Invalid{}
	if len(args) > 2 {
		// + and * are associative: a + b + c = (a + b) + c
		out := operation_law(k, op, args[:2], span)
		for a in args[2:] do out = operation_law(k, op, {out, a}, span)
		return out
	}
	if op == .In do return in_law(k, args[0], args[1])
	for a in args do if is_none(a) do return None{} // none op c = none
	sig, legal := legal_signature(k, op, args)
	if !legal do return report(k, .Invalid_operator, span, fmt.tprintf("`%s` is not proven to apply to %s", operator_text[op], print_types(args)))
	if bound, x, ok := comparison_bound(op, args); ok do return in_law(k, x, normal(k, bound))
	constant := true
	for a in args do constant &&= is_constant(a)
	if constant {
		if r, exact := compute(k, op, sig, args); exact do return r
		return new_operation(op, ..args)
	}
	out: Type
	#partial switch sig.args[0] {
	case .Int:
		if r, ok := ring_law(op, args); ok do out = r
	case .Bool:
		out = bool_law(op, args)
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
compute :: proc(k: ^Kernel, op: Operator, sig: Signature, args: []Type) -> (Type, bool) {
	cells := make([][]Type, len(args))
	for a, i in args {
		c, negated := as_cells(a)
		if negated || len(c) == 0 do return nil, false
		cells[i] = c
	}
	#partial switch sig.args[0] {
	case .Int:
		for c in cells do if !all_of_family(c, .Int) do return nil, false
		#partial switch op {
		case .Add:
			return int_sum(cells[0], cells[1]), true
		case .Sub:
			return int_sum(cells[0], int_opposite(cells[1])), true
		case .Neg:
			return cells_term(join_discrete(.Int, int_opposite(cells[0]))), true
		case .Bit_Not:
			return int_sum(int_opposite(cells[0]), {Int(-1)}), true
		case .Less, .Less_Eq, .Greater, .Greater_Eq:
			lo_a, hi_a := discrete_hull(cells[0])
			lo_b, hi_b := discrete_hull(cells[1])
			return compare_bounds(op, lo_a, hi_a, lo_b, hi_b), true
		}
		x, single_x := one_primitive(cells[0]).(Int)
		y, single_y := one_primitive(cells[1]).(Int)
		if !single_x || !single_y do return nil, false
		v, ok := int_operation(op, i128(x), i128(y))
		return Int(v), ok
	case .Real:
		for c in cells do if !all_of_family(c, .Real) do return nil, false
		#partial switch op {
		case .Add:
			return real_sum(cells[0], cells[1]), true
		case .Sub:
			return real_sum(cells[0], real_opposite(cells[1])), true
		case .Neg:
			return cells_term(join_reals(real_opposite(cells[0]))), true
		case .Less, .Less_Eq, .Greater, .Greater_Eq:
			return compare_reals(op, cells[0], cells[1]), true
		case .Mul:
			if product, exact := real_product(cells[0], cells[1]); exact do return product, true
		}
		x, single_x := one_primitive(cells[0]).(Real)
		y, single_y := one_primitive(cells[1]).(Real)
		if !single_x || !single_y do return nil, false
		if op == .Div do return Real(x / y), true
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
		results := make([dynamic]Type)
		for x in cells[0] {
			p := bool(x.(Bool))
			if op == .Bit_Not {
				append(&results, Bool(!p))
				continue
			}
			for y in cells[1] {
				q := bool(y.(Bool))
				#partial switch op {
				case .Bit_And:
					append(&results, Bool(p && q))
				case .Bit_Or:
					append(&results, Bool(p || q))
				case .Xor:
					append(&results, Bool(p != q))
				}
			}
		}
		return cells_term(union_cells(k, results[:])), true
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

// int_sum: (a..b) + (c..d) = (a + c)..(b + d), on each pair of cells.
int_sum :: proc(a, b: []Type) -> Type {
	out := make([dynamic]Type)
	for x in a {
		for y in b {
			lo_x, hi_x := discrete_bounds(x)
			lo_y, hi_y := discrete_bounds(y)
			append(&out, discrete_cell(.Int, add_bound(lo_x, lo_y), add_bound(hi_x, hi_y)))
		}
	}
	return cells_term(join_discrete(.Int, out[:]))
}

// int_opposite: -(a..b) = -b..-a.
int_opposite :: proc(cells: []Type) -> []Type {
	out := make([]Type, len(cells))
	for c, i in cells {
		lo, hi := discrete_bounds(c)
		out[i] = discrete_cell(.Int, neg_bound(hi), neg_bound(lo))
	}
	return out
}

// real_sum: (a..b) + (c..d) = (a + c)..(b + d), open where either bound is.
real_sum :: proc(a, b: []Type) -> Type {
	out := make([dynamic]Type)
	for x in a {
		for y in b {
			p, q := real_bounds(x), real_bounds(y)
			r: Real_Bounds
			if u, ok := p.lo.?; ok do if v, ok2 := q.lo.?; ok2 do r.lo, r.lo_open = u + v, p.lo_open || q.lo_open
			if u, ok := p.hi.?; ok do if v, ok2 := q.hi.?; ok2 do r.hi, r.hi_open = u + v, p.hi_open || q.hi_open
			append(&out, real_cell(r))
		}
	}
	return cells_term(join_reals(out[:]))
}

real_opposite :: proc(cells: []Type) -> []Type {
	out := make([]Type, len(cells))
	for c, i in cells {
		p := real_bounds(c)
		r := Real_Bounds{lo_open = p.hi_open, hi_open = p.lo_open}
		if v, ok := p.hi.?; ok do r.lo = -v
		if v, ok := p.lo.?; ok do r.hi = -v
		out[i] = real_cell(r)
	}
	return out
}

// real_product: (a..b) * (c..d) on closed, bounded intervals: the image of a
// connected set by a continuous operator is the interval between its least and
// greatest products at the bounds. False for an open or infinite bound.
real_product :: proc(a, b: []Type) -> (Type, bool) {
	out := make([dynamic]Type)
	for x in a {
		for y in b {
			p, q := real_bounds(x), real_bounds(y)
			if p.lo_open || p.hi_open || q.lo_open || q.hi_open do return nil, false
			u1, has_u1 := p.lo.?
			u2, has_u2 := p.hi.?
			v1, has_v1 := q.lo.?
			v2, has_v2 := q.hi.?
			if !has_u1 || !has_u2 || !has_v1 || !has_v2 do return nil, false
			corners := [4]f64{u1 * v1, u1 * v2, u2 * v1, u2 * v2}
			lo, hi := corners[0], corners[0]
			for c in corners[1:] {
				lo = min(lo, c)
				hi = max(hi, c)
			}
			append(&out, real_cell({lo = lo, hi = hi}))
		}
	}
	return cells_term(join_reals(out[:])), true
}

int_operation :: proc(op: Operator, x, y: i128) -> (i128, bool) {
	#partial switch op {
	case .Mul:
		return mul_checked(x, y)
	case .Div:
		return x / y, true
	case .Mod:
		return x % y, true
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
		v:      Maybe(f64),
		closed: bool,
	}
	inf :: proc(cells: []Type) -> Edge {r := real_bounds(cells[0]);return {r.lo, !r.lo_open}}
	sup :: proc(cells: []Type) -> Edge {r := real_bounds(cells[len(cells) - 1]);return {r.hi, !r.hi_open}}
	below :: proc(x, y: Edge) -> bool {
		u, has_u := x.v.?
		v, has_v := y.v.?
		return !has_u || !has_v || u < v
	}
	at_most :: proc(x, y: Edge) -> bool {
		u, has_u := x.v.?
		v, has_v := y.v.?
		return !has_u || !has_v || u < v || (u == v && x.closed && y.closed)
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
// absorbing elements, [~][~]a = a.
bool_law :: proc(op: Operator, args: []Type) -> Type {
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
	absorbing := op == .Bit_Or
	if is_bool(a, absorbing) || is_bool(b, absorbing) do return Bool(absorbing)
	if is_bool(a, !absorbing) do return b
	if is_bool(b, !absorbing) do return a
	return new_operation(op, a, b)
}

bool_and :: proc(a, b: Type) -> Type {return bool_law(.Bit_And, {a, b})}
bool_or :: proc(a, b: Type) -> Type {return bool_law(.Bit_Or, {a, b})}
bool_not :: proc(a: Type) -> Type {return bool_law(.Bit_Not, {a})}

// --- the ring of integers (§4.5) ---
//
// On integers over unknowns, + and * are associative and commutative, * distributes
// over +, 0 and 1 are neutral, -a is the opposite of a, (k * a) / k = a. The normal
// form is a sum of products of unknowns, in a fixed order, and a constant: `a - a`
// is 0, `a + a` is `2 * a`. Sum is the computation of these laws, not a type.

Product :: struct {
	coef:    i128,
	factors: []^Unknown, // sorted by id, repeated for a power
}

Sum :: struct {
	products: [dynamic]Product,
	constant: i128,
	denom:    i128, // ≥ 1: an exact division by a constant
}

// as_sum: the sum an integer term is; false when it is not one.
as_sum :: proc(t: Type) -> (s: Sum, ok: bool) {
	s.denom = 1
	#partial switch v in t {
	case Int:
		s.constant = i128(v)
		return s, true
	case ^Unknown:
		append(&s.products, Product{1, slice.clone([]^Unknown{v})})
		return s, true
	case ^Operation:
		#partial switch v.op {
		case .Add:
			if is_string_value(t) do return s, false
			out := sum_constant(0)
			for a in v.args do out = sum_add(out, as_sum(a) or_return)
			return out, true
		case .Sub:
			return sum_add(as_sum(v.args[0]) or_return, sum_neg(as_sum(v.args[1]) or_return)), true
		case .Neg:
			return sum_neg(as_sum(v.args[0]) or_return), true
		case .Mul:
			out := sum_constant(1)
			for a in v.args do out = sum_mul(out, as_sum(a) or_return)
			return out, true
		case .Div:
			out := as_sum(v.args[0]) or_return
			d, constant := v.args[1].(Int)
			if !constant || d <= 0 do return s, false
			out.denom *= i128(d)
			return sum_reduce(out), true
		}
	}
	return s, false
}

sum_constant :: proc(c: i128) -> Sum {
	return Sum{constant = c, denom = 1}
}

sum_add :: proc(a, b: Sum) -> Sum {
	d := a.denom / gcd(a.denom, b.denom) * b.denom
	fa, fb := d / a.denom, d / b.denom
	out := Sum{constant = a.constant * fa + b.constant * fb, denom = d}
	for p in a.products do add_product(&out, Product{p.coef * fa, p.factors})
	for p in b.products do add_product(&out, Product{p.coef * fb, p.factors})
	return sum_reduce(out)
}

sum_neg :: proc(a: Sum) -> Sum {
	out := Sum{constant = -a.constant, denom = a.denom}
	for p in a.products do append(&out.products, Product{-p.coef, p.factors})
	return out
}

sum_mul :: proc(a, b: Sum) -> Sum {
	out := Sum{denom = a.denom * b.denom}
	terms_a := sum_terms(a)
	terms_b := sum_terms(b)
	for x in terms_a {
		for y in terms_b {
			factors := make([dynamic]^Unknown)
			append(&factors, ..x.factors)
			append(&factors, ..y.factors)
			sort_unknowns(factors[:])
			if len(factors) == 0 {
				out.constant += x.coef * y.coef
			} else {
				add_product(&out, Product{x.coef * y.coef, factors[:]})
			}
		}
	}
	return sum_reduce(out)
}

sum_terms :: proc(s: Sum) -> []Product {
	out := make([dynamic]Product)
	append(&out, ..s.products[:])
	if s.constant != 0 do append(&out, Product{s.constant, nil})
	return out[:]
}

add_product :: proc(s: ^Sum, p: Product) {
	for &q in s.products {
		if same_factors(q.factors, p.factors) {
			q.coef += p.coef
			return
		}
	}
	append(&s.products, p)
}

same_factors :: proc(a, b: []^Unknown) -> bool {
	if len(a) != len(b) do return false
	for x, i in a do if x.id != b[i].id do return false
	return true
}

sort_unknowns :: proc(us: []^Unknown) {
	for i in 1 ..< len(us) {
		for j := i; j > 0 && us[j].id < us[j - 1].id; j -= 1 do us[j], us[j - 1] = us[j - 1], us[j]
	}
}

// sum_reduce: no zero product; the denominator and the coefficients divided by
// their gcd.
sum_reduce :: proc(s: Sum) -> Sum {
	out := Sum{constant = s.constant, denom = s.denom}
	for p in s.products do if p.coef != 0 do append(&out.products, p)
	g := out.denom
	for p in out.products do g = gcd(g, p.coef)
	g = gcd(g, out.constant)
	if g > 1 {
		for &p in out.products do p.coef /= g
		out.constant /= g
		out.denom /= g
	}
	return out
}

gcd :: proc(a, b: i128) -> i128 {
	x, y := abs(a), abs(b)
	for y != 0 do x, y = y, x % y
	return x == 0 ? 1 : x
}

// sum_term: the normal form of a sum, as a term: its products by degree then by
// unknown, the constant last, each added or subtracted, over its denominator.
sum_term :: proc(s: Sum) -> Type {
	products := make([dynamic]Product)
	append(&products, ..s.products[:])
	for i in 1 ..< len(products) {
		for j := i; j > 0 && product_less(products[j], products[j - 1]); j -= 1 do products[j], products[j - 1] = products[j - 1], products[j]
	}
	if s.constant != 0 || len(products) == 0 do append(&products, Product{s.constant, nil})
	t: Type
	for p, i in products {
		magnitude := product_term(abs(p.coef), p.factors)
		switch {
		case i == 0:
			t = p.coef < 0 && len(p.factors) > 0 ? new_operation(.Neg, magnitude) : product_term(p.coef, p.factors)
		case p.coef < 0:
			t = new_operation(.Sub, t, magnitude)
		case:
			t = new_operation(.Add, t, magnitude)
		}
	}
	if s.denom != 1 do t = new_operation(.Div, t, Int(s.denom))
	return t
}

// product_term: c * u * v …; 1 * u is u.
product_term :: proc(c: i128, factors: []^Unknown) -> Type {
	parts := make([dynamic]Type)
	if c != 1 || len(factors) == 0 do append(&parts, Int(c))
	for u in factors do append(&parts, u)
	return len(parts) == 1 ? parts[0] : new_operation(.Mul, ..parts[:])
}

product_less :: proc(a, b: Product) -> bool {
	if len(a.factors) != len(b.factors) do return len(a.factors) < len(b.factors)
	for u, i in a.factors do if u.id != b.factors[i].id do return u.id < b.factors[i].id
	return false
}

// ring_law: + - * neg [~] and the division by a constant that divides exactly, on
// sums; false when an operand is not a sum.
ring_law :: proc(op: Operator, args: []Type) -> (Type, bool) {
	sums := make([]Sum, len(args))
	for a, i in args {
		s, ok := as_sum(a)
		if !ok do return nil, false
		sums[i] = s
	}
	r: Sum
	#partial switch op {
	case .Add:
		r = sum_add(sums[0], sums[1])
	case .Sub:
		r = sum_add(sums[0], sum_neg(sums[1]))
	case .Mul:
		r = sum_mul(sums[0], sums[1])
	case .Neg:
		r = sum_neg(sums[0])
	case .Bit_Not:
		r = sum_add(sum_neg(sums[0]), sum_constant(-1))
	case .Div:
		if len(sums[1].products) != 0 || sums[1].denom != 1 || sums[1].constant == 0 do return nil, false
		d := sums[1].constant
		n := sums[0]
		if n.denom != 1 do return nil, false
		for p in n.products do if p.coef % d != 0 do return nil, false
		if n.constant % d != 0 do return nil, false
		r = Sum{constant = n.constant / d, denom = 1}
		for p in n.products do append(&r.products, Product{p.coef / d, p.factors})
	case:
		return nil, false
	}
	return sum_term(r), true
}
