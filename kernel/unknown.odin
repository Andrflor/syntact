package kernel

import "core:fmt"
import "core:slice"
import "core:strings"

// UNKNOWNS (specs/types.md §5.2, §7)
//
// `??::L` is an unknown: one value, read in the layout L, written ?k::L. Each `??`
// written is a distinct unknown; the same unknown comes back through a name. A type
// with unknowns is an equation in them. The check asks whether `V in C` is true for
// every value of the unknowns (decide).

Unknown :: struct {
	id:     int,
	layout: Type, // the values it may take; it may depend on earlier unknowns
}

// new_unknown: ?k::layout. An unknown with one possible value is that value; one
// whose values are integers is a polynomial (poly.odin).
new_unknown :: proc(k: ^Kernel, layout: Type) -> Type {
	if is_invalid(layout) do return Invalid{}
	if s, constant := layout.(Set); constant {
		if _, single := set_single(s); single do return s
	}
	u := new(Unknown)
	u^ = Unknown{k.unknowns, layout}
	k.unknowns += 1
	if e, ok := layout_envelope(layout); ok && !set_is_none(e) && set_subset(e, family_set(.Int)) do return poly_var(u)
	return u
}

// is_atom: t is one value for each value of the unknowns — not a set of them.
is_atom :: proc(t: Type) -> bool {
	switch v in t {
	case Set:
		if set_is_none(v) do return true
		_, single := set_single(v)
		return single
	case Poly, ^Unknown:
		return true
	case ^Apply:
		#partial switch v.op {
		case .Or, .And, .Not, .Is, .Range, .Range_From, .Range_To:
			return false
		case .In:
			return true
		case .Match:
			for p in match_products(v) do if !is_atom(p) do return false
			return true
		}
		for a in v.args do if !is_atom(a) do return false
		return true
	case ^Frame:
		return true
	case Invalid:
		return true
	}
	return false
}

// envelope: the values an atomic t may take, for every value of its unknowns;
// a set that contains them all. False when it cannot be computed.
envelope :: proc(t: Type, narrow: map[^Unknown]Set = nil) -> (result: Set, ok: bool) {
	switch v in t {
	case Set:
		return v, is_atom(v)
	case ^Unknown:
		if n, ok := narrow[v]; ok do return n, true
		return layout_envelope(v.layout, narrow)
	case Poly:
		return poly_envelope(v, narrow)
	case ^Apply:
		if !is_atom(v) do return {}, false
		if v.op == .In do return in_envelope(v.args[0], v.args[1], narrow)
		if v.op == .Match do return match_envelope(v, narrow)
		sets := make([]Set, len(v.args))
		for a, i in v.args do sets[i] = envelope(a, narrow) or_return
		for s in sets do if set_is_none(s) do return NONE, true
		sig, legal := signature_of(v.op, sets)
		if !legal do return {}, false
		if r, exact := compute(v.op, sig, sets); exact do return r, true
		if sig.args[0] == .Int && v.op == .Mul do return Set{ints = ints_hull_mul(sets[0].ints, sets[1].ints)}, true
		return family_set(sig.result), true
	case ^Frame, Invalid:
	}
	return {}, false
}

// layout_envelope: every value the layout L may admit, whatever the earlier
// unknowns it depends on.
layout_envelope :: proc(t: Type, narrow: map[^Unknown]Set = nil) -> (result: Set, ok: bool) {
	#partial switch v in t {
	case Set:
		return v, true
	case ^Apply:
		#partial switch v.op {
		case .Or:
			a := layout_envelope(v.args[0], narrow) or_return
			b := layout_envelope(v.args[1], narrow) or_return
			return set_union(a, b), true
		case .And:
			a, a_ok := layout_envelope(v.args[0], narrow)
			b, b_ok := layout_envelope(v.args[1], narrow)
			_ = a_ok || b_ok
			if a_ok && b_ok do return set_intersect(a, b), true
			if a_ok do return a, true
			if b_ok do return b, true
		case .Range, .Range_From, .Range_To:
			lo, hi: Set
			has_lo, has_hi := v.op != .Range_To, v.op != .Range_From
			if has_lo do lo = envelope(v.args[0], narrow) or_return
			if has_hi do hi = envelope(v.args[len(v.args) - 1], narrow) or_return
			return range_hull(lo, hi, has_lo, has_hi)
		}
	}
	return envelope(t, narrow)
}

// range_hull: every value between the smallest possible low bound and the
// largest possible high bound.
range_hull :: proc(lo, hi: Set, has_lo, has_hi: bool) -> (Set, bool) {
	if (has_lo && !ints_empty(lo.ints)) || (has_hi && !ints_empty(hi.ints)) {
		a: Maybe(i128) = has_lo ? ints_min(lo.ints) : nil
		b: Maybe(i128) = has_hi ? ints_max(hi.ints) : nil
		return Set{ints = ints_between(a, b)}, true
	}
	return {}, false
}

// poly_envelope: the integers p may take, by interval arithmetic on the
// envelopes of its unknowns — a safe envelope, exact for one unknown of degree 1.
poly_envelope :: proc(p: Poly, narrow: map[^Unknown]Set = nil) -> (result: Set, ok: bool) {
	sum := ints_point(p.constant)
	for m in p.monos {
		term := ints_point(m.coef)
		for v in m.vars {
			e, narrowed := narrow[v]
			if !narrowed do e = layout_envelope(v.layout, narrow) or_return
			term = ints_hull_mul(term, e.ints)
		}
		sum = ints_add(sum, term)
	}
	if p.denom != 1 do sum = ints_hull_div(sum, p.denom)
	return Set{ints = sum}, true
}

// ints_hull_mul: the interval that contains every x * y.
ints_hull_mul :: proc(a, b: Ints) -> Ints {
	if ints_empty(a) || ints_empty(b) do return {}
	corners := [2]Maybe(i128){ints_min(a), ints_max(a)}
	others := [2]Maybe(i128){ints_min(b), ints_max(b)}
	lo, hi: Maybe(i128)
	first := true
	unbounded_lo, unbounded_hi := false, false
	for x, i in corners {
		for y, j in others {
			u, has_u := x.?
			v, has_v := y.?
			if !has_u || !has_v {
				// an infinite corner: its sign decides the side
				su := has_u ? sign(u) : (i == 0 ? -1 : 1)
				sv := has_v ? sign(v) : (j == 0 ? -1 : 1)
				if su * sv < 0 do unbounded_lo = true
				if su * sv > 0 do unbounded_hi = true
				continue
			}
			p, ok := mul_checked(u, v)
			if !ok {
				if sign(u) * sign(v) < 0 {
					unbounded_lo = true
				} else {
					unbounded_hi = true
				}
				continue
			}
			if first {
				lo, hi, first = p, p, false
			} else {
				lo, hi = min_hi(lo, p), max_lo(hi, p)
			}
		}
	}
	if unbounded_lo do lo = nil
	if unbounded_hi do hi = nil
	if first && !unbounded_lo && !unbounded_hi do return ints_point(0)
	return ints_between(lo, hi)
}

sign :: proc(x: i128) -> int {
	return x > 0 ? 1 : (x < 0 ? -1 : 0)
}

// ints_hull_div: the interval that contains every x / d, d > 0.
ints_hull_div :: proc(a: Ints, d: i128) -> Ints {
	lo, hi := ints_min(a), ints_max(a)
	if v, ok := lo.?; ok do lo = v / d - 1
	if v, ok := hi.?; ok do hi = v / d + 1
	return ints_between(lo, hi)
}

// in_envelope: the booleans `x in c` may take, x atomic.
in_envelope :: proc(x, c: Type, narrow: map[^Unknown]Set = nil) -> (result: Set, ok: bool) {
	e := envelope(x, narrow) or_return
	yes, no := true, true
	if cs, constant := c.(Set); constant {
		yes = !set_is_none(set_intersect(e, cs))
		no = !set_subset(e, cs)
	} else if a, is_apply := c.(^Apply); is_apply && a.op == .Is && is_atom(a.args[0]) {
		t := envelope(a.args[0], narrow) or_return
		yes = !set_is_none(set_intersect(e, t))
		_, single_e := set_single(e)
		no = !(single_e && set_equal(e, t))
	}
	out: Bools
	if yes do out += {.True}
	if no do out += {.False}
	return Set{bools = out}, true
}

// --- deciding ---

Verdict :: enum u8 {
	True, // for every value of the unknowns
	False, // for some value: the counterexample
	Undecided,
}

// decide: whether the boolean r is true for every value of its unknowns — the
// unknowns ranging over their layouts, or over `narrow` where it says.
//
//   1. its envelope: true only, or false only;
//   2. a case split on an atom `u in S` (Shannon): the values of u in S make it
//      true, the others false; each split removes an atom;
//   3. a split of the values of an unknown in two halves; the values end as points,
//      where the laws compute r.
//
// A counterexample is a point where r is false. On infinitely many values, when
// neither the envelope nor an atom concludes, r stays an equation: undecided.
decide :: proc(r: Type, narrow: map[^Unknown]Set = nil) -> (verdict: Verdict, counterexample: string) {
	if is_bool(r, true) do return .True, ""
	if is_bool(r, false) do return .False, ""
	if e, ok := envelope(r, narrow); ok {
		if set_equal(e, set_bool(true)) do return .True, ""
		if set_equal(e, set_bool(false)) do return .False, witness(r, narrow)
	}
	if atom, u, s, found := split_atom(r); found {
		values, ok := domain(u, narrow)
		if !ok do return .Undecided, ""
		return decide_parts(r, narrow, u, {set_intersect(values, s), set_intersect(values, set_complement(s))}, atom)
	}
	unknowns := make([dynamic]^Unknown)
	collect_unknowns(r, &unknowns)
	slice.sort_by(unknowns[:], proc(a, b: ^Unknown) -> bool {return a.id < b.id})
	all_points := true
	for u in unknowns {
		values, ok := domain(u, narrow)
		if !ok do return .Undecided, ""
		if _, point := set_single(values); point do continue
		all_points = false
		if halves, finite := halve(values); finite do return decide_parts(r, narrow, u, halves, nil)
	}
	if all_points {
		// every unknown has one value: the laws compute r
		values := make(map[^Unknown]Set)
		for u in unknowns do values[u], _ = domain(u, narrow)
		v := substitute(r, values)
		if is_bool(v, true) do return .True, ""
		if is_bool(v, false) do return .False, print_assignment(unknowns[:], values)
	}
	return .Undecided, ""
}

// decide_parts: r on each part of the values of u; with an atom, the atom is true
// on the first part and false on the second.
decide_parts :: proc(r: Type, narrow: map[^Unknown]Set, u: ^Unknown, parts: [2]Set, atom: ^Apply) -> (Verdict, string) {
	undecided := false
	for part, i in parts {
		if set_is_none(part) do continue
		n := make(map[^Unknown]Set)
		for key, v in narrow do n[key] = v
		n[u] = part
		side := r
		if atom != nil do side = assume(r, atom, i == 0)
		v, c := decide(side, n)
		if v == .False do return .False, c
		undecided ||= v == .Undecided
	}
	return undecided ? .Undecided : .True, ""
}

// domain: the values u ranges over.
domain :: proc(u: ^Unknown, narrow: map[^Unknown]Set) -> (Set, bool) {
	if values, narrowed := narrow[u]; narrowed do return values, true
	return layout_envelope(u.layout, narrow)
}

// halve: a finite set of values in two; false for infinitely many.
halve :: proc(s: Set) -> ([2]Set, bool) {
	lo, has_lo := ints_min(s.ints).?
	hi, has_hi := ints_max(s.ints).?
	other := s
	other.ints = {}
	if !ints_empty(s.ints) {
		if !has_lo || !has_hi do return {}, false
		if lo < hi {
			mid := lo + (hi - lo) / 2
			first := set_intersect(s, Set{ints = ints_between(nil, mid)})
			return {first, set_intersect(s, set_complement(first))}, true
		}
		if !set_is_none(other) do return {Set{ints = s.ints}, other}, true
	}
	if s.bools == {.False, .True} do return {Set{bools = {.False}}, set_intersect(s, set_complement(Set{bools = {.False}}))}, true
	if w := set_words(s); !words_is_empty(w) {
		first, found := words_witness(w)
		if !found do return {}, false
		one := set_of(first)
		rest := set_intersect(s, set_complement(one))
		if set_is_none(rest) do return {}, false
		if !words_finite(w) do return {}, false
		return {one, rest}, true
	}
	return {}, false
}

// witness: a point where r is false, its envelope being false everywhere: any
// value of each unknown.
witness :: proc(r: Type, narrow: map[^Unknown]Set) -> string {
	unknowns := make([dynamic]^Unknown)
	collect_unknowns(r, &unknowns)
	slice.sort_by(unknowns[:], proc(a, b: ^Unknown) -> bool {return a.id < b.id})
	values := make(map[^Unknown]Set)
	for u in unknowns {
		d, ok := domain(u, narrow)
		if ok do values[u] = set_default(d)
	}
	return print_assignment(unknowns[:], values)
}

// split_atom: an `u in S` in the boolean r, u an unknown and S a constant set.
split_atom :: proc(r: Type) -> (atom: ^Apply, u: ^Unknown, s: Set, found: bool) {
	a, is_apply := r.(^Apply)
	if !is_apply do return
	if a.op == .In {
		target := target_unknown(a.args[0])
		set, constant := a.args[1].(Set)
		if target != nil && constant do return a, target, set, true
		return
	}
	if a.op == .Bit_And || a.op == .Bit_Or || a.op == .Bit_Not {
		for arg in a.args do if arg != nil {
			atom, u, s, found = split_atom(arg)
			if found do return
		}
	}
	return
}

// assume: r where the boolean atom is b.
assume :: proc(r: Type, atom: ^Apply, b: bool) -> Type {
	a, is_apply := r.(^Apply)
	if !is_apply do return r
	if a == atom do return set_bool(b)
	if a.op != .Bit_And && a.op != .Bit_Or && a.op != .Bit_Not do return r
	x := assume(a.args[0], atom, b)
	y: Type
	if len(a.args) > 1 do y = assume(a.args[1], atom, b)
	return bool_operation(a.op, x, y)
}

print_assignment :: proc(unknowns: []^Unknown, values: map[^Unknown]Set) -> string {
	parts := make([dynamic]string)
	for u in unknowns {
		if v, ok := values[u]; ok do append(&parts, fmt.tprintf("?%d = %s", u.id, print_set(v)))
	}
	return strings.join(parts[:], ", ")
}

// collect_unknowns: the unknowns t depends on, those of their layouts included.
collect_unknowns :: proc(t: Type, out: ^[dynamic]^Unknown) {
	switch v in t {
	case ^Unknown:
		if slice.contains(out[:], v) do return
		append(out, v)
		collect_unknowns(v.layout, out)
	case Poly:
		vars := make([dynamic]^Unknown)
		poly_unknowns(v, &vars)
		for u in vars do collect_unknowns(u, out)
	case ^Apply:
		if v.op == .Recur {
			for _, o in v.args[0].(^Frame).overrides do collect_unknowns(o.type, out)
			return
		}
		for a in v.args do if a != nil do collect_unknowns(a, out)
	case Set, ^Frame, Invalid:
	}
}

// substitute: t where each unknown has the given value, in normal form.
substitute :: proc(t: Type, values: map[^Unknown]Set) -> Type {
	switch v in t {
	case ^Unknown:
		if x, ok := values[v]; ok do return x
		return v
	case Poly:
		result := poly_constant(v.constant)
		for m in v.monos {
			term := poly_constant(m.coef)
			for u in m.vars {
				factor := poly_var(u)
				if x, ok := values[u]; ok {
					n, single := ints_single(x.ints)
					if !single do return t
					factor = poly_constant(n)
				}
				term = poly_mul(term, factor)
			}
			result = poly_add(result, term)
		}
		if v.denom != 1 {
			q, exact := poly_div(result, v.denom)
			if !exact do return t
			result = q
		}
		return poly_normal(result)
	case ^Apply:
		scratch: Kernel // an assignment cannot make an operation illegal: its envelope was checked
		if v.op == .Recur {
			// the recursion, carved with the values: unfolded once they are known
			g := v.args[0].(^Frame)
			args := make([dynamic]Carve_Arg)
			for i, o in g.overrides do append(&args, Carve_Arg{g.scope.bindings[i].name, -1, substitute(o.type, values), {}})
			return collapse(&scratch, carve(&scratch, g.source, args[:], {}), {})
		}
		args := make([]Type, len(v.args))
		for a, i in v.args do if a != nil do args[i] = substitute(a, values)
		return apply(&scratch, v.op, args, {})
	case Set, ^Frame, Invalid:
	}
	return t
}

// same_alternatives: two | are the same when each alternative of one is an
// alternative of the other, in any order (§4.1).
same_alternatives :: proc(k: ^Kernel, a, b: ^Apply) -> bool {
	xs, ys := make([dynamic]Type), make([dynamic]Type)
	alternatives(a, &xs)
	alternatives(b, &ys)
	contains := proc(k: ^Kernel, list: []Type, t: Type) -> bool {
		for u in list do if type_same(k, u, t) do return true
		return false
	}
	for x in xs do if !contains(k, ys[:], x) do return false
	for y in ys do if !contains(k, xs[:], y) do return false
	return true
}

alternatives :: proc(t: Type, out: ^[dynamic]Type) {
	if a, ok := t.(^Apply); ok && a.op == .Or {
		for arg in a.args do alternatives(arg, out)
		return
	}
	append(out, t)
}

// poly_normal: a polynomial without unknowns is its constant.
poly_normal :: proc(p: Poly) -> Type {
	if c, constant := poly_is_constant(p); constant do return set_of(c)
	return p
}

// type_same: a and b are the same type by the laws: equal normal forms.
type_same :: proc(k: ^Kernel, a, b: Type) -> bool {
	if a == nil || b == nil do return a == nil && b == nil
	switch x in a {
	case Set:
		y, ok := b.(Set)
		return ok && set_equal(x, y)
	case Poly:
		y, ok := b.(Poly)
		return ok && poly_equal(x, y)
	case ^Unknown:
		y, ok := b.(^Unknown)
		return ok && x == y
	case ^Apply:
		y, ok := b.(^Apply)
		if !ok || x.op != y.op || len(x.args) != len(y.args) do return false
		if x.op == .Or do return same_alternatives(k, x, y)
		for arg, i in x.args do if !type_same(k, arg, y.args[i]) do return false
		return true
	case ^Frame:
		y, ok := b.(^Frame)
		return ok && frame_same(k, x, y)
	case Invalid:
	}
	return false
}
