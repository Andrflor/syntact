package kernel

import syn "../compiler"
import "core:fmt"

// THE LAWS OF THE OPERATIONS (specs/types.md §4)
//
// apply builds the type an operation gives, by the laws of the spec: on constant
// sets the normal form computes it (§4.1–4.6); on integers over unknowns, the
// laws of a ring give a polynomial; on booleans, those of a Boolean algebra. What
// no law reduces stays an Apply. An operator applies only to types proven to be in
// a family it accepts (§4.5): the proof is the check's (prove.odin).

apply :: proc(k: ^Kernel, op: Op, args: []Type, span: syn.Span) -> Type {
	for a in args do if a != nil && is_invalid(a) do return Invalid{}
	switch op {
	case .Or, .And, .Not:
		return apply_set(op, args)
	case .Is:
		return apply_is(args[0])
	case .In:
		return type_in(k, args[0], args[1])
	case .Add, .Sub, .Mul, .Div, .Mod, .Neg, .Bit_And, .Bit_Or, .Xor, .Bit_Not, .Shl, .Shr, .Less, .Less_Eq, .Greater, .Greater_Eq:
		return apply_operator(k, op, args, span)
	case .Range, .Range_From, .Range_To:
		return apply_range(k, op, args, span)
	case .Match:
		return apply_match(k, args)
	case .Recur:
	}
	return new_apply(op, ..args)
}

// apply_set: | & ~ (§4.1), computed by the normal form on constant sets.
apply_set :: proc(op: Op, args: []Type) -> Type {
	sets := make([]Set, len(args))
	for a, i in args {
		s, constant := a.(Set)
		if !constant do return new_apply(op, ..args)
		sets[i] = s
	}
	#partial switch op {
	case .Or:
		return set_union(sets[0], sets[1])
	case .And:
		return set_intersect(sets[0], sets[1])
	}
	return set_complement(sets[0])
}

// apply_is: =p = p for a primitive (§4.4).
apply_is :: proc(t: Type) -> Type {
	if s, ok := t.(Set); ok {
		if set_is_none(s) do return s
		if _, single := set_single(s); single do return s
	}
	return new_apply(.Is, t)
}

// Signature: the families an operator accepts, one per operand (§4.5).
Signature :: struct {
	args:   [2]Family,
	result: Family,
}

signatures :: proc(op: Op) -> []Signature {
	@(static) add := []Signature{{{.Int, .Int}, .Int}, {{.Real, .Real}, .Real}, {{.String, .String}, .String}}
	@(static) sub := []Signature{{{.Int, .Int}, .Int}, {{.Real, .Real}, .Real}}
	@(static) mul := []Signature{{{.Int, .Int}, .Int}, {{.Real, .Real}, .Real}, {{.String, .Count}, .String}}
	@(static) div := []Signature{{{.Int, .Nonzero_Int}, .Int}, {{.Real, .Nonzero_Real}, .Real}}
	@(static) modulo := []Signature{{{.Int, .Nonzero_Int}, .Int}}
	@(static) shift := []Signature{{{.Int, .Count}, .Int}}
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

// legal_signature: the first signature whose families are proven to hold the
// operands. An operator distributes over |: a set is in a family when each of its
// elements is.
legal_signature :: proc(k: ^Kernel, op: Op, args: []Type) -> (Signature, bool) {
	next: for sig in signatures(op) {
		for a, i in args do if prove_elements(k, a, family_set(sig.args[i])) != .Proven do continue next
		return sig, true
	}
	return {}, false
}

apply_operator :: proc(k: ^Kernel, op: Op, args: []Type, span: syn.Span) -> Type {
	constant := true
	for a in args {
		if s, ok := a.(Set); ok {
			if set_is_none(s) do return NONE // none op c = none
			continue
		}
		constant = false
		// the family of a recursive call is that of the solution of its equation:
		// proven when the equation is solved (recursion.odin)
		if has_recursion(a) do return new_apply(op, ..args)
	}
	sig, legal := legal_signature(k, op, args)
	if !legal do return report(k, .Invalid_operator, span, fmt.tprintf("%v is not proven to apply to %s", op, print_types(args)))
	if constant {
		sets := make([]Set, len(args))
		for a, i in args do sets[i] = a.(Set)
		if r, exact := compute(op, sig, sets); exact do return r
		return new_apply(op, ..args)
	}
	#partial switch sig.args[0] {
	case .Int:
		if r, ok := poly_operation(op, args); ok do return r
	case .Bool:
		return bool_operation(op, args)
	}
	return new_apply(op, ..args)
}

// poly_operation: the ring laws on integers (§4.5), in the normal form of a
// polynomial; a division only by a constant that divides every coefficient.
poly_operation :: proc(op: Op, args: []Type) -> (result: Type, ok: bool) {
	ps := make([]Poly, len(args))
	for a, i in args do ps[i] = as_poly(a) or_return
	r: Poly
	#partial switch op {
	case .Add:
		r = poly_add(ps[0], ps[1])
	case .Sub:
		r = poly_add(ps[0], poly_neg(ps[1]))
	case .Mul:
		r = poly_mul(ps[0], ps[1])
	case .Neg:
		r = poly_neg(ps[0])
	case .Bit_Not:
		r = poly_add(poly_neg(ps[0]), poly_constant(-1))
	case .Div:
		d := poly_is_constant(ps[1]) or_return
		r = poly_div(ps[0], d) or_return
	case:
		return nil, false
	}
	return poly_normal(r), true
}

// bool_operation: [&] [|] ^ [~] by the laws of a Boolean algebra (§4.5):
// computed on constants, simplified by the neutral and absorbing elements.
bool_operation :: proc(op: Op, args: []Type) -> Type {
	a := args[0]
	if op == .Bit_Not {
		if is_bool(a, true) do return type_false()
		if is_bool(a, false) do return type_true()
		if n, ok := a.(^Apply); ok && n.op == .Bit_Not do return n.args[0]
		return new_apply(.Bit_Not, a)
	}
	b := args[1]
	if op == .Xor {
		if is_bool(a, false) do return b
		if is_bool(b, false) do return a
		return new_apply(op, a, b)
	}
	absorbing := op == .Bit_Or // true absorbs [|], false absorbs [&]
	if is_bool(a, absorbing) || is_bool(b, absorbing) do return set_bool(absorbing)
	if is_bool(a, !absorbing) do return b
	if is_bool(b, !absorbing) do return a
	return new_apply(op, a, b)
}

bool_and :: proc(a, b: Type) -> Type {return bool_operation(.Bit_And, {a, b})}
bool_or :: proc(a, b: Type) -> Type {return bool_operation(.Bit_Or, {a, b})}
bool_not :: proc(a: Type) -> Type {return bool_operation(.Bit_Not, {a})}

// compute: { x op y | x ∈ a, y ∈ b } on constant sets (§4.5: distribute over |,
// compute on the primitives), when the result is a normal form: ranges for + - and
// the comparisons, words for the strings, any operator on single primitives.
// Otherwise false: the operation stays.
compute :: proc(op: Op, sig: Signature, args: []Set) -> (Set, bool) {
	a := args[0]
	#partial switch sig.args[0] {
	case .Int:
		#partial switch op {
		case .Add:
			return Set{ints = ints_add(a.ints, args[1].ints)}, true
		case .Sub:
			return Set{ints = ints_add(a.ints, ints_neg(args[1].ints))}, true
		case .Neg:
			return Set{ints = ints_neg(a.ints)}, true
		case .Bit_Not:
			return Set{ints = ints_add(ints_neg(a.ints), ints_point(-1))}, true
		case .Less, .Less_Eq, .Greater, .Greater_Eq:
			return compare_ints(op, a.ints, args[1].ints), true
		}
		x, single_x := ints_single(a.ints)
		y, single_y := ints_single(args[1].ints)
		if !single_x || !single_y do return {}, false
		r, ok := int_operation(op, x, y)
		return set_of(r), ok
	case .Real:
		#partial switch op {
		case .Add:
			return Set{reals = reals_add(a.reals, args[1].reals)}, true
		case .Sub:
			return Set{reals = reals_add(a.reals, reals_neg(args[1].reals))}, true
		case .Neg:
			return Set{reals = reals_neg(a.reals)}, true
		case .Less, .Less_Eq, .Greater, .Greater_Eq:
			return compare_reals(op, a.reals, args[1].reals), true
		case .Mul:
			r, exact := reals_mul(a.reals, args[1].reals)
			return Set{reals = r}, exact
		case .Div:
			r, exact := reals_div(a.reals, args[1].reals)
			return Set{reals = r}, exact
		}
	case .String:
		#partial switch op {
		case .Add:
			return Set{words = words_cat(set_words(a), set_words(args[1]))}, true
		case .Mul:
			return Set{words = words_repeat(set_words(a), args[1].ints)}, true
		}
	case .Char:
		x_lo, x_hi, _ := words_char_bounds(set_words(a))
		y_lo, y_hi, _ := words_char_bounds(set_words(args[1]))
		return compare_ints(op, ints_between(x_lo, x_hi), ints_between(y_lo, y_hi)), true
	case .Bool:
		out: Bools
		for x in a.bools {
			if op == .Bit_Not {
				out += {x == .True ? .False : .True}
				continue
			}
			for y in args[1].bools {
				p, q := x == .True, y == .True
				r: bool
				#partial switch op {
				case .Bit_And:
					r = p && q
				case .Bit_Or:
					r = p || q
				case .Xor:
					r = p != q
				}
				out += {r ? .True : .False}
			}
		}
		return Set{bools = out}, true
	}
	return {}, false
}

int_operation :: proc(op: Op, x, y: i128) -> (i128, bool) {
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
		if y > 126 do return 0, false
		return mul_checked(x, i128(1) << uint(y))
	case .Shr:
		return y > 126 ? (x < 0 ? -1 : 0) : x >> uint(y), true
	}
	return 0, false
}

// compare_ints: the booleans x op y takes for x in a, y in b: `x < y` happens
// when min a < max b, `x >= y` when max a >= min b.
compare_ints :: proc(op: Op, a, b: Ints) -> Set {
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
	lo_a, hi_a, lo_b, hi_b := ints_min(a), ints_max(a), ints_min(b), ints_max(b)
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
	out: Bools
	if yes do out += {.True}
	if no do out += {.False}
	return Set{bools = out}
}

// compare_reals: as compare_ints, a bound counting for <= only when reached.
compare_reals :: proc(op: Op, a, b: Reals) -> Set {
	Edge :: struct {
		v:      Maybe(f64),
		closed: bool,
	}
	inf :: proc(r: Reals) -> Edge {return {r.ranges[0].lo, !r.ranges[0].lo_open}}
	sup :: proc(r: Reals) -> Edge {last := r.ranges[len(r.ranges) - 1];return {last.hi, !last.hi_open}}
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
	out: Bools
	if yes do out += {.True}
	if no do out += {.False}
	return Set{bools = out}
}

// apply_range: a range whose bounds depend on unknowns (§4.3), computed once
// they are primitives.
apply_range :: proc(k: ^Kernel, op: Op, args: []Type, span: syn.Span) -> Type {
	bounds: [2]Maybe(Prim)
	slots := op == .Range ? []int{0, 1} : (op == .Range_From ? []int{0} : []int{1})
	for a, i in args {
		s, constant := a.(Set)
		if !constant do return new_apply(op, ..args)
		p, single := set_single(s)
		if !single do return report(k, .Invalid_Range, span, "a bound of a range is one primitive")
		bounds[slots[i]] = p
	}
	family, _ := bounds[0].?
	if family == nil do family, _ = bounds[1].?
	return range_set(k, bounds[0], bounds[1], family, span)
}
