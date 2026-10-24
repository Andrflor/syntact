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

DECIDE_LIMIT :: 1 << 16

// decide: whether the boolean r is true for every value of its unknowns. By its
// envelope first; then by giving each unknown each of its values, when they are
// few enough. An unknown with too many values is given the values where r may
// change — the bounds and the constants of r: a counterexample found that way
// is real, but finding none proves nothing.
decide :: proc(r: Type) -> (verdict: Verdict, counterexample: string) {
	if is_bool(r, true) do return .True, ""
	if is_bool(r, false) do return .False, ""
	if e, ok := envelope(r); ok {
		if set_equal(e, set_bool(true)) do return .True, ""
		if set_equal(e, set_bool(false)) do return .False, ""
	}
	unknowns := make([dynamic]^Unknown)
	collect_unknowns(r, &unknowns)
	slice.sort_by(unknowns[:], proc(a, b: ^Unknown) -> bool {return a.id < b.id})
	constants := make([dynamic]Set)
	collect_constants(r, &constants)
	values := make(map[^Unknown]Set)
	budget := DECIDE_LIMIT
	found, complete := search(r, unknowns[:], constants[:], &values, &budget)
	if found != nil do return .False, print_assignment(unknowns[:], found)
	if complete do return .True, ""
	return .Undecided, ""
}

// search: an assignment of the unknowns for which r is not true. `complete` is
// true when every assignment was given and found true.
@(private = "file")
search :: proc(r: Type, unknowns: []^Unknown, constants: []Set, values: ^map[^Unknown]Set, budget: ^int) -> (found: map[^Unknown]Set, complete: bool) {
	if len(unknowns) == 0 {
		budget^ -= 1
		v := substitute(r, values^)
		if is_bool(v, false) do return clone_map(values^), true
		return nil, is_bool(v, true)
	}
	u := unknowns[0]
	layout, constant := substitute(u.layout, values^).(Set)
	if !constant do return nil, false
	elements, all := set_elements(layout, budget^)
	if !all do elements = sample_values(layout, constants)
	complete = all
	for e in elements {
		if budget^ <= 0 do return nil, false
		values[u] = e
		f, c := search(r, unknowns[1:], constants, values, budget)
		if f != nil do return f, true
		complete &&= c
	}
	delete_key(values, u)
	return nil, complete
}

// sample_values: the values of a layout where a boolean may change: its bounds,
// and the constants of the term with their neighbours.
@(private = "file")
sample_values :: proc(layout: Set, constants: []Set) -> []Set {
	out := make([dynamic]Set)
	add := proc(out: ^[dynamic]Set, layout: Set, p: Prim) {
		v := set_of(p)
		if !set_has(layout, p) do return
		for o in out do if set_equal(o, v) do return
		append(out, v)
	}
	ints := make([dynamic]i128)
	append(&ints, 0, 1, -1)
	for r in layout.ints.ranges {
		if v, ok := r.lo.?; ok do append(&ints, v)
		if v, ok := r.hi.?; ok do append(&ints, v)
	}
	for c in constants {
		for r in c.ints.ranges {
			if v, ok := r.lo.?; ok do append(&ints, v - 1, v, v + 1)
			if v, ok := r.hi.?; ok do append(&ints, v - 1, v, v + 1)
		}
	}
	for v in ints do add(&out, layout, v)
	reals := make([dynamic]f64)
	append(&reals, 0, 1, -1)
	for c in ([2]Set{layout, {}}) do for r in c.reals.ranges {
		if v, ok := r.lo.?; ok do append(&reals, v, v - 1, v + 1)
		if v, ok := r.hi.?; ok do append(&reals, v, v - 1, v + 1)
	}
	for c in constants do for r in c.reals.ranges {
		if v, ok := r.lo.?; ok do append(&reals, v, v - 0.5, v + 0.5)
		if v, ok := r.hi.?; ok do append(&reals, v, v - 0.5, v + 0.5)
	}
	for v in reals do add(&out, layout, v)
	words := set_words(layout)
	if w, ok := words_witness(words); ok do add(&out, layout, w)
	for c in constants {
		cw := set_words(c)
		if w, ok := words_witness(words_and(words, cw)); ok do add(&out, layout, w)
		if w, ok := words_witness(words_and(words, words_not(cw))); ok do add(&out, layout, w)
	}
	for b in layout.bools do add(&out, layout, b == .True)
	return out[:]
}

// collect_constants: the constant sets in t.
collect_constants :: proc(t: Type, out: ^[dynamic]Set) {
	#partial switch v in t {
	case Set:
		append(out, v)
	case Poly:
		append(out, set_of(v.constant))
		for m in v.monos do append(out, set_of(m.coef))
	case ^Unknown:
		collect_constants(v.layout, out)
	case ^Apply:
		for a in v.args do if a != nil do collect_constants(a, out)
	}
}

clone_map :: proc(m: map[^Unknown]Set) -> map[^Unknown]Set {
	out := make(map[^Unknown]Set)
	for k, v in m do out[k] = v
	return out
}

// set_elements: the elements of a finite set, at most `limit` of them.
set_elements :: proc(s: Set, limit: int) -> ([]Set, bool) {
	out := make([dynamic]Set)
	if !ints_empty(s.ints) {
		n, finite := ints_size(s.ints, i128(limit))
		if !finite do return nil, false
		_ = n
		for v in ints_values(s.ints) do append(&out, set_of(v))
	}
	if !reals_empty(s.reals) {
		v, single := reals_single(s.reals)
		if !single do return nil, false
		append(&out, set_of(v))
	}
	if w := set_words(s); !words_is_empty(w) {
		v, single := words_single(w)
		if !single do return nil, false
		append(&out, set_of(v))
	}
	for b in s.bools do append(&out, set_of(b == .True))
	if !scopes_empty(s.scopes) do return nil, false
	return out[:], len(out) <= limit
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
		args := make([]Type, len(v.args))
		for a, i in v.args do if a != nil do args[i] = substitute(a, values)
		scratch: Kernel // an assignment cannot make an operation illegal: its envelope was checked
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
