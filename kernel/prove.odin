package kernel

// THE PROOF (specs/types.md §7)
//
// The check proves `V in C` from what is known: the domain of each unknown, as
// the branches around restrict it (Facts), and the laws. What is not proven is
// refused. There is no search over values: an unknown is known by its domain,
// and a term by what its unknowns are known to be.
//
//   u in S                  proven when what is known of u is in S
//   f(u) in S               u ∈ D ⟹ f(u) ∈ f(D): proven when f(D) is in S
//   (t::L) in L             proven: an unknown is in its domain
//   p [&] q, p [|] q, [~]p  the proofs of p and q
//   t ? {c -> p …}          each branch proven, with what it knows of t

// Facts: what a branch proves of an unknown: a domain narrower than its own.
Facts :: map[^Unknown]Type

Proof :: enum u8 {
	Proven,
	Refuted, // false for every value known
	Unproven,
}

// known_domain: what is known of u where the proof is made.
known_domain :: proc(k: ^Kernel, u: ^Unknown) -> Type {
	if d, ok := k.facts[u]; ok do return d
	return u.domain
}

// with_fact: the facts, with u known in d.
with_fact :: proc(facts: Facts, u: ^Unknown, d: Type) -> Facts {
	out := make(Facts)
	for key, v in facts do out[key] = v
	out[u] = d
	return out
}

prove :: proc(k: ^Kernel, r: Type) -> Proof {
	if is_bool(r, true) do return .Proven
	if is_bool(r, false) do return .Refuted
	a, is_apply := r.(^Apply)
	if !is_apply do return .Unproven
	#partial switch a.op {
	case .In:
		return prove_in(k, a.args[0], a.args[1])
	case .Bit_And:
		p, q := prove(k, a.args[0]), prove(k, a.args[1])
		if p == .Refuted || q == .Refuted do return .Refuted
		return p == .Proven && q == .Proven ? .Proven : .Unproven
	case .Bit_Or:
		p, q := prove(k, a.args[0]), prove(k, a.args[1])
		if p == .Proven || q == .Proven do return .Proven
		return p == .Refuted && q == .Refuted ? .Refuted : .Unproven
	case .Bit_Not:
		switch prove(k, a.args[0]) {
		case .Proven:
			return .Refuted
		case .Refuted:
			return .Proven
		case .Unproven:
		}
	case .Match:
		return prove_match(k, a)
	}
	return .Unproven
}

// prove_in: x in c, x whole.
prove_in :: proc(k: ^Kernel, x, c: Type) -> Proof {
	if u := target_unknown(x); u != nil && same(k, known_domain(k, u), c) do return .Proven // (t::L) in L
	#partial switch v in c {
	case Set:
		if !is_atom(x) do return v.scopes.all ? .Proven : .Unproven
		image, ok := known_image(k, x)
		if !ok do return .Unproven
		if set_subset(image, v) do return .Proven
		if set_is_none(set_intersect(image, v)) do return .Refuted
		return .Unproven
	case ^Frame:
		r := frame_admits(k, x, v)
		if a, still := r.(^Apply); still && a.op == .In do return .Unproven // nothing is known that the scope admits
		return prove(k, r)
	case ^Apply:
		if v.op == .Is do return prove_equal(k, x, v.args[0])
		// a set that depends on unknowns: what it surely holds, what it may hold
		if !is_atom(x) do return .Unproven
		image, ok := known_image(k, x)
		if !ok do return .Unproven
		if inner, has := surely(k, c); has && set_subset(image, inner) do return .Proven
		if outer, has := maybe(k, c); has && set_is_none(set_intersect(image, outer)) do return .Refuted
		return .Unproven
	}
	return prove_equal(k, x, c)
}

// prove_equal: x in =t.
prove_equal :: proc(k: ^Kernel, x, t: Type) -> Proof {
	if same(k, x, t) do return .Proven
	a, a_ok := known_image(k, x)
	b, b_ok := known_image(k, t)
	if !a_ok || !b_ok do return .Unproven
	if set_is_none(set_intersect(a, b)) do return .Refuted
	_, single_a := set_single(a)
	if single_a && set_equal(a, b) do return .Proven
	return .Unproven
}

// prove_elements: every element of t is in the family f; t is a set, or one value.
prove_elements :: proc(k: ^Kernel, t: Type, f: Set) -> Proof {
	if s, constant := t.(Set); constant do return set_subset(s, f) ? .Proven : .Refuted
	if is_atom(t) do return prove_in(k, t, f)
	outer, ok := maybe(k, t)
	if ok && set_subset(outer, f) do return .Proven
	return .Unproven
}

// prove_match: each branch that a known value of the target reaches, proven with
// what the branch knows of it.
prove_match :: proc(k: ^Kernel, a: ^Apply) -> Proof {
	u := target_unknown(a.args[0])
	taken := NONE
	result := Proof.Proven
	for i := 1; i + 1 < len(a.args); i += 2 {
		c, p := a.args[i], a.args[i + 1]
		cover, constant := c.(Set)
		previous := k.facts
		if u != nil && (c == nil || constant) {
			domain, known := known_set(k, u)
			if known {
				part := set_intersect(domain, set_complement(taken))
				if c != nil do part = set_intersect(part, cover)
				if c != nil do taken = set_union(taken, cover)
				if set_is_none(part) do continue // no known value reaches it
				k.facts = with_fact(previous, u, part)
			}
		}
		v := prove(k, p)
		k.facts = previous
		if v == .Unproven do result = .Unproven
		if v == .Refuted do return .Refuted
		if c == nil do break
	}
	return result
}

// known_set: what is known of u, when it is a constant set.
known_set :: proc(k: ^Kernel, u: ^Unknown) -> (Set, bool) {
	return maybe(k, known_domain(k, u))
}

// known_image: a set that holds the value of the atom t, from what is known of its
// unknowns: u ∈ D ⟹ f(u) ∈ f(D). The laws compute f(D); an image that is not a
// range is bounded by its extreme values.
known_image :: proc(k: ^Kernel, t: Type) -> (result: Set, ok: bool) {
	switch v in t {
	case Set:
		return v, true
	case ^Unknown:
		return known_set(k, v)
	case Poly:
		sum := ints_point(v.constant)
		for m in v.monos {
			term := ints_point(m.coef)
			for u in m.vars {
				d, ok := known_set(k, u)
				if !ok do return {}, false
				term = ints_product_bounds(term, d.ints)
			}
			sum = ints_add(sum, term)
		}
		if v.denom != 1 do sum = ints_quotient_bounds(sum, ints_point(v.denom))
		return Set{ints = sum}, true
	case ^Apply:
		#partial switch v.op {
		case .In:
			x, ok := known_image(k, v.args[0])
			c, c_ok := v.args[1].(Set)
			if !ok || !c_ok do return family_set(.Bool), true
			out: Bools
			if !set_is_none(set_intersect(x, c)) do out += {.True}
			if !set_subset(x, c) do out += {.False}
			return Set{bools = out}, true
		case .Match:
			return match_image(k, v)
		case .Recur, .Or, .And, .Not, .Is, .Range, .Range_From, .Range_To:
			return {}, false
		}
		images := make([]Set, len(v.args))
		for a, i in v.args {
			images[i] = known_image(k, a) or_return
			if set_is_none(images[i]) do return NONE, true
		}
		sig, legal := signature_of(v.op, images)
		if !legal do return {}, false
		if r, exact := compute(v.op, sig, images); exact do return r, true
		return image_bounds(v.op, sig, images), true
	case ^Frame, Invalid:
	}
	return {}, false
}

// match_image: the values a pattern may give: those of the branches its target
// reaches, each read with what the branch knows of the target.
match_image :: proc(k: ^Kernel, a: ^Apply) -> (result: Set, ok: bool) {
	u := target_unknown(a.args[0])
	taken := NONE
	for i := 1; i + 1 < len(a.args); i += 2 {
		c, p := a.args[i], a.args[i + 1]
		cover, constant := c.(Set)
		previous := k.facts
		if u != nil && (c == nil || constant) {
			if domain, known := known_set(k, u); known {
				part := set_intersect(domain, set_complement(taken))
				if c != nil do part = set_intersect(part, cover)
				if c != nil do taken = set_union(taken, cover)
				if set_is_none(part) do continue
				k.facts = with_fact(previous, u, part)
			}
		}
		image, has := known_image(k, p)
		k.facts = previous
		if !has do return {}, false
		result = set_union(result, image)
		if c == nil do break
	}
	return result, true
}

// signature_of: the signature whose families hold the constant operands.
signature_of :: proc(op: Op, args: []Set) -> (Signature, bool) {
	for sig in signatures(op) {
		fits := true
		for a, i in args do fits &&= set_subset(a, family_set(sig.args[i]))
		if fits do return sig, true
	}
	return {}, false
}

// image_bounds: the extreme values of an image that is not a range: x * y, x / y,
// x % y lie between the products, quotients, remainders of the bounds; the others,
// in the family of the result.
image_bounds :: proc(op: Op, sig: Signature, args: []Set) -> Set {
	if sig.args[0] == .Int {
		#partial switch op {
		case .Mul:
			return Set{ints = ints_product_bounds(args[0].ints, args[1].ints)}
		case .Div:
			return Set{ints = ints_quotient_bounds(args[0].ints, args[1].ints)}
		}
	}
	return family_set(sig.result)
}

// ints_product_bounds: the range between the smallest and the largest x * y.
ints_product_bounds :: proc(a, b: Ints) -> Ints {
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

// ints_quotient_bounds: the range between the smallest and the largest x / y, y
// without 0.
ints_quotient_bounds :: proc(a, b: Ints) -> Ints {
	xs := [2]Maybe(i128){ints_min(a), ints_max(a)}
	ys := [2]Maybe(i128){ints_min(b), ints_max(b)}
	lo, hi: Maybe(i128)
	first := true
	for x in xs {
		for y in ys {
			u, has_u := x.?
			v, has_v := y.?
			if !has_u || !has_v || v == 0 do return ints_all()
			q := u / v
			if first {
				lo, hi, first = q, q, false
			} else {
				lo, hi = min_hi(lo, q), max_lo(hi, q)
			}
		}
	}
	return ints_between(lo, hi)
}

sign :: proc(x: i128) -> int {
	return x > 0 ? 1 : (x < 0 ? -1 : 0)
}

// surely: the values a set-type holds whatever its unknowns: 0..n holds 0..min n.
surely :: proc(k: ^Kernel, t: Type) -> (result: Set, ok: bool) {
	#partial switch v in t {
	case Set:
		return v, true
	case ^Apply:
		#partial switch v.op {
		case .Range, .Range_From, .Range_To:
			lo, hi: Maybe(i128)
			if v.op != .Range_To {
				b := known_image(k, v.args[0]) or_return
				lo = ints_max(b.ints)
				if lo == nil do return {}, false
			}
			if v.op != .Range_From {
				b := known_image(k, v.args[len(v.args) - 1]) or_return
				hi = ints_min(b.ints)
				if hi == nil do return {}, false
			}
			return Set{ints = ints_between(lo, hi)}, true
		case .Or:
			a := surely(k, v.args[0]) or_return
			b := surely(k, v.args[1]) or_return
			return set_union(a, b), true
		case .And:
			a := surely(k, v.args[0]) or_return
			b := surely(k, v.args[1]) or_return
			return set_intersect(a, b), true
		}
	}
	return {}, false
}

// maybe: the values a set-type may hold, for some value of its unknowns: 0..n may
// hold 0..max n. For one value, what is known of it.
maybe :: proc(k: ^Kernel, t: Type) -> (result: Set, ok: bool) {
	#partial switch v in t {
	case Set:
		return v, true
	case ^Apply:
		#partial switch v.op {
		case .Range, .Range_From, .Range_To:
			lo, hi: Maybe(i128)
			if v.op != .Range_To {
				b := known_image(k, v.args[0]) or_return
				lo = ints_min(b.ints)
			}
			if v.op != .Range_From {
				b := known_image(k, v.args[len(v.args) - 1]) or_return
				hi = ints_max(b.ints)
			}
			return Set{ints = ints_between(lo, hi)}, true
		case .Or:
			a := maybe(k, v.args[0]) or_return
			b := maybe(k, v.args[1]) or_return
			return set_union(a, b), true
		case .And:
			a := maybe(k, v.args[0]) or_return
			b := maybe(k, v.args[1]) or_return
			return set_intersect(a, b), true
		}
	}
	if is_atom(t) do return known_image(k, t)
	return {}, false
}
