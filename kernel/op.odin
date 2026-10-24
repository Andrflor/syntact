package kernel

import syn "../compiler"
import "core:fmt"

// THE LAWS OF THE OPERATIONS (specs/types.md §4)
//
// apply builds the type that an operation gives. On constant sets the laws
// compute it: | & ~ component by component (§4.1), an operator by distributing
// over | and computing on the primitives (§4.5). What no law reduces stays an
// Apply. An operator applies only to types proven to be in a family it accepts;
// otherwise it is illegal.

apply :: proc(k: ^Kernel, op: Op, args: []Type, span: syn.Span) -> Type {
	for a in args do if a != nil && is_invalid(a) do return Invalid{}
	#partial switch op {
	case .Or, .And, .Not:
		return apply_boolean(op, args)
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
	}
	return new_apply(op, ..args)
}

// apply_boolean: | & ~ (§4.1). On constant sets, the normal form computes them.
apply_boolean :: proc(op: Op, args: []Type) -> Type {
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
	case .Not:
		return set_complement(sets[0])
	}
	return new_apply(op, ..args)
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
	@(static) arith := []Signature{{{.Int, .Int}, .Int}, {{.Real, .Real}, .Real}}
	@(static) mul := []Signature{{{.Int, .Int}, .Int}, {{.Real, .Real}, .Real}, {{.String, .Count}, .String}}
	@(static) int_only := []Signature{{{.Int, .Int}, .Int}}
	@(static) bits := []Signature{{{.Int, .Int}, .Int}, {{.Bool, .Bool}, .Bool}}
	@(static) neg := []Signature{{{.Int, .Int}, .Int}, {{.Real, .Real}, .Real}}
	@(static) bit_not := []Signature{{{.Int, .Int}, .Int}, {{.Bool, .Bool}, .Bool}}
	@(static) compare := []Signature{{{.Int, .Int}, .Bool}, {{.Real, .Real}, .Bool}, {{.Char, .Char}, .Bool}}
	#partial switch op {
	case .Add:
		return add
	case .Sub, .Div:
		return arith
	case .Mul:
		return mul
	case .Mod, .Shl, .Shr:
		return int_only
	case .Bit_And, .Bit_Or, .Xor:
		return bits
	case .Neg:
		return neg
	case .Bit_Not:
		return bit_not
	case .Less, .Less_Eq, .Greater, .Greater_Eq:
		return compare
	}
	return nil
}

// signature_of: the signature whose families contain the operands.
signature_of :: proc(op: Op, args: []Set) -> (Signature, bool) {
	for sig in signatures(op) {
		fits := true
		for a, i in args do fits &&= set_subset(a, family_set(sig.args[i]))
		if fits do return sig, true
	}
	return {}, false
}

apply_operator :: proc(k: ^Kernel, op: Op, args: []Type, span: syn.Span) -> Type {
	// what each operand may be: a constant set, or the envelope of an atom
	possible := make([]Set, len(args))
	constant := true
	for a, i in args {
		if s, ok := a.(Set); ok {
			possible[i] = s
			continue
		}
		constant = false
		if has_recursion(a) do return new_apply(op, ..args) // proven once the equation is solved or unfolded
		e, ok := envelope(a, k.narrow)
		if !ok do return report(k, .Invalid_operator, span, fmt.tprintf("%v: cannot prove the family of %s", op, print_type(a)))
		possible[i] = e
	}
	for s in possible do if set_is_none(s) do return NONE // none op c = none
	sig, legal := signature_of(op, possible)
	if !legal do return report(k, .Invalid_operator, span, fmt.tprintf("%v does not apply to %s", op, print_types(args)))
	if op == .Div || op == .Mod {
		if set_has(possible[1], i128(0)) || set_has(possible[1], f64(0)) {
			return report(k, .Invalid_operator, span, fmt.tprintf("the divisor %s may be 0", print_type(args[1])))
		}
	}
	if constant {
		if r, exact := compute(op, sig, possible); exact do return r
	} else if sig.args[0] == .Int {
		if r, ok := poly_operation(op, args); ok do return r
	}
	return new_apply(op, ..args)
}

// poly_operation: the ring laws on integers (§4.5), in the normal form of a
// polynomial; the division only by a constant that divides every coefficient.
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

as_poly :: proc(t: Type) -> (Poly, bool) {
	#partial switch v in t {
	case Poly:
		return v, true
	case Set:
		n, single := ints_single(v.ints)
		if single && set_equal(v, set_of(n)) do return poly_constant(n), true
	}
	return {}, false
}

// apply_range: a range whose bounds depend on unknowns (§4.3); computed once they
// are primitives.
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

// compute: { x op y | x ∈ a, y ∈ b } (§4.5: distribute over |, compute on the
// primitives). False when the result is not exact in a normal form: the
// operation then stays an Apply.
compute :: proc(op: Op, sig: Signature, args: []Set) -> (Set, bool) {
	a := args[0]
	switch sig.args[0] {
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
		return enumerate_ints(op, a.ints, args[1].ints)
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
		}
		#partial switch op {
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
	case .Count:
	}
	return {}, false
}

// ENUMERATION_LIMIT: past this many pairs, an operator whose image is not a range
// stays an Apply instead of being enumerated.
ENUMERATION_LIMIT :: 4096

enumerate_ints :: proc(op: Op, a, b: Ints) -> (Set, bool) {
	n, finite_a := ints_size(a, ENUMERATION_LIMIT)
	m, finite_b := ints_size(b, ENUMERATION_LIMIT)
	if !finite_a || !finite_b || n * m > ENUMERATION_LIMIT do return {}, false
	out := make([dynamic]Int_Range)
	for x in ints_values(a) {
		for y in ints_values(b) {
			r, ok := int_operation(op, x, y)
			if !ok do return {}, false
			append(&out, Int_Range{r, r})
		}
	}
	return Set{ints = ints_of(out[:])}, true
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
		if y < 0 || y > 126 do return 0, false
		return mul_checked(x, i128(1) << uint(y))
	case .Shr:
		if y < 0 do return 0, false
		return y > 126 ? (x < 0 ? -1 : 0) : x >> uint(y), true
	}
	return 0, false
}

// compare_ints: the booleans that x op y takes for x in a, y in b. `x < y` is
// possible when min a < max b, and `x >= y` when max a >= min b.
compare_ints :: proc(op: Op, a, b: Ints) -> Set {
	below := proc(x, y: Maybe(i128)) -> bool {
		u, has_u := x.?
		v, has_v := y.?
		return !has_u || !has_v || u < v
	}
	at_most := proc(x, y: Maybe(i128)) -> bool {
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

// compare_reals: as compare_ints, with the infimum and supremum of each set; a
// bound counts for <= only when it is reached.
compare_reals :: proc(op: Op, a, b: Reals) -> Set {
	Edge :: struct {
		v:      Maybe(f64), // nil: infinite
		closed: bool,
	}
	inf := proc(r: Reals) -> Edge {return {r.ranges[0].lo, !r.ranges[0].lo_open}}
	sup := proc(r: Reals) -> Edge {last := r.ranges[len(r.ranges) - 1];return {last.hi, !last.hi_open}}
	below := proc(x, y: Edge) -> bool {
		u, has_u := x.v.?
		v, has_v := y.v.?
		return !has_u || !has_v || u < v
	}
	at_most := proc(x, y: Edge) -> bool {
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
