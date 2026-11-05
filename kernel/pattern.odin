package kernel

import "core:fmt"
import "core:slice"

// PATTERNS (specs/types.md §6)
//
// A pattern is a type of the algebra. Like `in`, it takes its target whole:
//
//   t ? {c -> p  …} = p              when t in c = true
//   t ? {c -> p  …} = t ? {…}        when t in c = false
//   t ? {-> p  …}   = p              the branch without a cover admits everything
//   t ? {c -> p  -> p} = p           all its branches give the same product
//
// A branch is reached by the values of the target in its cover and in none of the
// covers above: its reach, `t in c [&] [~](t in c₀) …`. Its product holds for
// those values: where the reach says `u in S`, the unknown `?ₖ::L` is rewritten
// `?ₖ::(L & S)` in the product (rewrite.odin). A branch that no value reaches is
// not typed. A value of the target that no branch takes makes the pattern
// non-exhaustive: `[~]rest` must be proven, rest being the values no cover takes.

pattern_law :: proc(k: ^Kernel, p: ^Pattern) -> Type {
	return pattern_on(k, normal(k, p.target), p)
}

// pattern_on: the pattern p on its target, in normal form. A cover is computed when
// its branch is tested, after the target, on the paths that come to it (§4.8): the
// pattern is the first branch, then the others,
//
//   t ? {c₀ -> p₀  …  cᵢ -> pᵢ  …} = t ? {c₀ -> p₀  …  -> t ? {cᵢ -> pᵢ  …}}
//
// so the effects of a cover are those of the first branch of a pattern: computed with
// the target, before any test.
pattern_on :: proc(k: ^Kernel, target: Type, p: ^Pattern) -> Type {
	if is_invalid(target) do return target
	// a call of another equation: the pattern is read on its production
	if c, is_call := target.(^Collapse); is_call {
		if v, asked := call_production(k, c); asked do return pattern_on(k, v, p)
	}
	// a pattern gives one of its products: (t ? {c -> q  …}) ? B = t ? {c -> q ? B  …}
	if q, is_pattern := target.(^Pattern); is_pattern && !has_effect(q) {
		branches := make([]Branch, len(q.branches))
		for b, i in q.branches do branches[i] = with_product(b, pattern_on(k, b.product, p))
		return pattern_law(k, branching(q, branches))
	}
	for b, i in p.branches {
		if b.cover == nil || !has_effect(normal(k, b.cover)) do continue
		if i == 0 do return sequence(k, p, {target, normal(k, b.cover)}, covered)
		branches := make([dynamic]Branch)
		append(&branches, ..p.branches[:i])
		append(&branches, Branch{product = branching(p, p.branches[i:]), span = b.span})
		return pattern_on(k, target, branching(p, branches[:]))
	}
	reached, rest, invalid := reaches(k, target, p.branches)
	if invalid != nil do return invalid
	out := make([dynamic]Branch)
	for r in reached {
		b := p.branches[r.branch]
		product := branch_product(k, b, r.rewrite, target)
		if r.all && len(out) == 0 do return product
		append(&out, Branch{cover = r.all ? nil : r.cover, product = product, span = b.span})
	}
	// taken by every value: t ? {c -> p  -> p} = p; otherwise the check proves that
	// every value is taken (check.odin)
	if rest == nil {
		all_same := true
		for b in out[1:] do all_same &&= same(k, b.product, out[0].product)
		if all_same do return out[0].product
	}
	r := new(Pattern)
	r.target, r.branches, r.span = target, out[:], p.span
	return r
}

// covered: the pattern t, on its target and its first cover, both computed.
covered :: proc(k: ^Kernel, t: Type, parts: []Type) -> Type {
	p := t.(^Pattern)
	branches := slice.clone(p.branches)
	branches[0].cover = parts[1]
	return pattern_on(k, parts[0], branching(p, branches))
}

// Reach: a branch that values of the target reach: its cover, the rewrite of its
// unknowns, whether every value that comes to it takes it, and what of its reach
// the rewrite does not say — true when it says all of it.
Reach :: struct {
	branch:  int,
	cover:   Type,
	rewrite: Rewrite,
	all:     bool,
	unsaid:  Type,
}

// reaches: the branches values of the target reach, up to one that every value
// left takes; then rest is nil. Otherwise rest is the condition of the values
// that no branch takes. A cover no law types makes the pattern Invalid.
reaches :: proc(k: ^Kernel, target: Type, branches: []Branch) -> (out: [dynamic]Reach, rest: Type, invalid: Type) {
	out = make([dynamic]Reach)
	rest = Bool(true) // the values no branch above takes
	for b, i in branches {
		cond: Type = Bool(true)
		cover: Type
		if b.cover != nil {
			cover = normal(k, b.cover)
			cond = in_law(k, target, cover)
			if is_invalid(cover) do return out, rest, cover
			if is_invalid(cond) do return out, rest, cond
		}
		reach := bool_and(k, rest, cond)
		rest = bool_and(k, rest, bool_not(k, cond))
		r, reached, unsaid := narrow(k, nil, reach)
		if !reached do continue
		all := is_bool(rest, false)
		append(&out, Reach{i, cover, r, all, unsaid})
		if all do return out, nil, nil
	}
	return out, rest, nil
}

// narrow: the rewrite a reach makes: through [&], `u in S` rewrites ?ₖ::L into
// ?ₖ::(L & S), `[~](u in S)` into ?ₖ::(L & ~S). Not reached when the reach is
// false, or a layout becomes none. Unsaid: the literals of the reach the rewrite
// does not say — an atom on a term, a set not constant.
narrow :: proc(k: ^Kernel, base: Rewrite, reach: Type) -> (out: Rewrite, reached: bool, unsaid: Type) {
	if is_bool(reach, false) || is_invalid(reach) do return nil, false, nil
	out = base
	unsaid = Bool(true)
	literals := make([dynamic]Type)
	conjuncts(reach, &literals)
	for l in literals {
		if is_bool(l, true) do continue
		positive := true
		atom := l
		if n, ok := l.(^Operation); ok && n.op == .Bit_Not {
			positive = false
			atom = n.args[0]
		}
		o, is_op := atom.(^Operation)
		// a disjunction — or the negation of a conjunction, [~](a [&] b) = [~]a [|] [~]b —:
		// each unknown in the union of what each side narrows it to
		if is_op && (o.op == .Bit_Or && positive || o.op == .Bit_And && !positive) {
			unsaid = bool_and(k, unsaid, l)
			sides := make([]Type, len(o.args))
			for a, i in o.args do sides[i] = positive ? a : bool_not(k, a)
			either, any := narrow_either(k, out, sides)
			if !any do return nil, false, nil
			out = either
			continue
		}
		if !is_op || o.op != .In {
			unsaid = bool_and(k, unsaid, l)
			continue
		}
		targets: []Narrowed
		if u, is_unknown := o.args[0].(^Unknown); is_unknown {
			targets = []Narrowed{{u, o.args[1], true}}
		} else {
			targets = bounded_preimage(k, o.args[0], o.args[1], positive)
		}
		said := false
		for target in targets {
			u, set, exact := target.unknown, rewrite(k, target.set, out), target.exact
			if !is_constant(set) && depends(k, set, u) {
				// a set over unknowns whose layouts read u: by its bounds — u is in
				// what it may hold, out of what it always holds
				exact = false
				bound: Type
				known: bool
				if positive do bound, known = outer_set(k, set)
				else do bound, known = inner_set(k, set)
				if !known do continue
				set = bound
			}
			current := layout_of(k, u)
			if x, found := rewritten(out, u); found {
				current = x
				if w, ok := x.(^Unknown); ok do current = layout_of(k, w)
			}
			layout := and_law(k, {current, positive ? set : not_law(k, set)})
			if is_none(layout) do return nil, false, nil
			out = rewriting(out, u, narrowing(u, layout))
			said ||= exact
		}
		if !said do unsaid = bool_and(k, unsaid, l)
	}
	return out, true, unsaid
}

// branch_product: the product of a branch, for the values that reach it: a copy of
// it where each reference from outside is its type — computed once — with the
// unknowns the reach narrows rewritten, ?ₖ::(L & S). The scopes written in it are
// copied likewise: they are the scopes of that branch.
branch_product :: proc(k: ^Kernel, b: Branch, r: Rewrite, target: Type) -> Type {
	pieces := cover_pieces(k, b, target)
	if b.scope == nil || len(r) == 0 && len(pieces) == 0 do return rewrite(k, normal(k, b.product), r)
	m := Copier{outer = r, substitute = true, pieces = pieces}
	m.scopes[b.scope] = b.scope // the scopes written in the branch are copied
	return rewrite(k, normal(k, copy_term(k, &m, b.product, b.scope)), r)
}

// cover_pieces: destructuring (specs/language/07): what the names of a cover read
// when its branch takes the target — the pieces of the target, by place for a
// scope written as the cover (its captures included), by name otherwise.
cover_pieces :: proc(k: ^Kernel, b: Branch, target: Type) -> map[^Binding]Type {
	pieces := make(map[^Binding]Type)
	if b.view == nil do return pieces
	s, known := target.(^Scope)
	if !known {
		// a scope not known yet: its pieces are terms, x.name for a named place, x.#k for
		// another, and x from k for a last run
		if written, structural := b.cover.(^Scope); structural && gives_scope(k, target) {
			shape := placed(k, written, .Shape)
			at: Type = Int(0)
			for place, i in shape {
				if is_run(place) && i < len(shape) - 1 do break
				if !is_run(place) {
					if place.name != "" {
						a := new(Access)
						a.name, a.ordinal, a.span = place.name, -1, place.span
						pieces[place] = access_law(k, target, a)
					} else {
						pieces[place] = op(k, .Item, target, at)
					}
					at = op(k, .Add, at, Int(1))
					continue
				}
				pieces[place] = op(k, .From, target, at)
				return pieces
			}
			if len(pieces) == len(shape) do return pieces
			clear(&pieces)
		}
		for v in b.view.bindings do pieces[v] = problem(.Invalid_Property_Access, b.span, fmt.tprintf("the pieces of %s are read, and it is not a known scope", print_type(target)))
		return pieces
	}
	xs := placed(k, s, .Value)
	if written, structural := b.cover.(^Scope); structural {
		shape := placed(k, written, .Shape)
		lengths, decided, fits := run_lengths(k, xs, shape)
		if !decided || !fits do return pieces
		at := 0
		for place, i in shape {
			part := xs[at:at + lengths[i]]
			at += lengths[i]
			pieces[place] = is_run(place) ? Type(run_scope(k, part)) : binding_value(k, part[0])
		}
		return pieces
	}
	for v in b.view.bindings {
		if found, ok := occurrence(xs, v.name, -1, true); ok do pieces[v] = binding_value(k, found)
	}
	return pieces
}

// conjuncts: the terms of a [&].
conjuncts :: proc(t: Type, out: ^[dynamic]Type) {
	if o, ok := t.(^Operation); ok && o.op == .Bit_And {
		for a in o.args do conjuncts(a, out)
		return
	}
	append(out, t)
}

// enter_branches: a pattern gives one of its products, so an operation on it
// enters each branch: x in (t ? {c -> p …}) = t ? {c -> x in p …}, and likewise
// (t ? {c -> p …}) in C = t ? {c -> p in C …}.
enter_branches :: proc(k: ^Kernel, p: ^Pattern, apply: proc(product, other: Type) -> Type, other: Type) -> Type {
	entered := new(Pattern)
	entered.target, entered.span = p.target, p.span
	entered.branches = make([]Branch, len(p.branches))
	for b, i in p.branches do entered.branches[i] = with_product(b, apply(b.product, other))
	return pattern_law(k, entered)
}

// call_production: the production of the scope c calls, at the values its carve
// gives, when its equation is not being given: a call read from outside it.
call_production :: proc(k: ^Kernel, c: ^Collapse) -> (Type, bool) {
	s, is_scope := c.target.(^Scope)
	if !is_scope || !c.recursive do return nil, false
	root, found := first_production(k, origin(s))
	if !found || root.state == .In_Progress do return nil, false
	p, has := first_production(k, s)
	if !has || p.state == .In_Progress do return nil, false
	v := binding_type(k, p)
	if holds_invalid(v) || has_effect(v) do return nil, false
	return v, true
}

// holds_invalid: t, or a term in it, has no type.
holds_invalid :: proc(t: Type) -> bool {
	if t == nil do return false
	if is_invalid(t) do return true
	if p, is_pattern := t.(^Pattern); is_pattern {
		for b in p.branches do if holds_invalid(b.product) do return true
	}
	if f, is_fold := t.(^Fold); is_fold {
		for x in fold_parts(f) do if holds_invalid(x) do return true
	}
	if e, is_effect := t.(^Effect); is_effect {
		if e.call != nil && holds_invalid(e.call) do return true
		if e.choice != nil && holds_invalid(e.choice) do return true
		return holds_invalid(e.then)
	}
	if c, is_call := t.(^Collapse); is_call {
		if s, is_scope := c.target.(^Scope); is_scope do for _, v in s.changes do if holds_invalid(v) do return true
	}
	for x in parts(t) do if holds_invalid(x) do return true
	return false
}

// outer_set: a constant set that holds every value s may hold, whatever its
// unknowns: a range from the least of its lower bound to the greatest of its upper.
outer_set :: proc(k: ^Kernel, s: Type) -> (out: Type, ok: bool) {
	if is_constant(s) do return s, true
	#partial switch v in s {
	case ^Range:
		lo, hi: Type
		if v.lo != nil do lo = term_bound(k, v.lo, true) or_return
		if v.hi != nil do hi = term_bound(k, v.hi, false) or_return
		return range_law(k, lo, hi, .Int, v.span), true
	case ^And:
		terms := make([]Type, len(v.terms))
		for t, i in v.terms do terms[i] = outer_set(k, t) or_return
		return and_law(k, terms), true
	case ^Or:
		terms := make([]Type, len(v.terms))
		for t, i in v.terms do terms[i] = outer_set(k, t) or_return
		return or_law(k, terms), true
	case ^Not:
		inner := inner_set(k, v.term) or_return
		return not_law(k, inner), true
	case ^Is:
		// =t: one of the values t may be
		return layout_image(k, v.term)
	}
	// a value over unknowns: what it may be
	return layout_image(k, s)
}

// inner_set: a constant set of values s holds whatever its unknowns: a range from
// the greatest of its lower bound to the least of its upper.
inner_set :: proc(k: ^Kernel, s: Type) -> (out: Type, ok: bool) {
	if is_constant(s) do return s, true
	#partial switch v in s {
	case ^Range:
		lo, hi: Type
		if v.lo != nil do lo = term_bound(k, v.lo, false) or_return
		if v.hi != nil do hi = term_bound(k, v.hi, true) or_return
		return range_law(k, lo, hi, .Int, v.span), true
	case ^And:
		terms := make([]Type, len(v.terms))
		for t, i in v.terms do terms[i] = inner_set(k, t) or_return
		return and_law(k, terms), true
	case ^Or:
		terms := make([]Type, len(v.terms))
		for t, i in v.terms do terms[i] = inner_set(k, t) or_return
		return or_law(k, terms), true
	case ^Not:
		outer := outer_set(k, v.term) or_return
		return not_law(k, outer), true
	}
	// =t, or a value over unknowns: none of its values is it whatever the unknowns
	return None{}, true
}

// term_bound: the least (or greatest) integer the term t may be.
term_bound :: proc(k: ^Kernel, t: Type, least: bool) -> (out: Type, ok: bool) {
	image := layout_image(k, t) or_return
	lo, hi := int_bounds(k, image) or_return
	b := (least ? lo : hi).? or_return
	return Int(b), true
}

// Narrowed: an unknown, the set a literal puts it in, and whether that set says
// the literal exactly.
Narrowed :: struct {
	unknown: ^Unknown,
	set:     Type,
	exact:   bool,
}

// depends: the set reads u, or reads an unknown whose layout does.
depends :: proc(k: ^Kernel, set: Type, u: ^Unknown) -> bool {
	read := make([dynamic]^Unknown)
	read_unknowns(set, &read)
	for w in read {
		if w.id == u.id do return true
		if l := layout_of(k, w); !is_constant(l) && depends(k, l, u) do return true
	}
	return false
}

// bounded_preimage: e = a·u + t, t a term not reading u, in the constant set s,
// for each unknown u of degree 1 in e: u is in the preimage of s by a·u + t. With
// a = ±1 it is the set s - t, or t - s, exactly; otherwise it is bounded at the
// bounds of t: u is in the preimage for some b t may be (positive: the hull of the
// preimages at the bounds of t), or for every one (negated: their meet).
bounded_preimage :: proc(k: ^Kernel, e, s: Type, positive: bool) -> []Narrowed {
	out := make([dynamic]Narrowed)
	if !is_constant(s) do return nil
	ms, d, ring := monomials(e)
	if !ring || d != 1 do return nil
	one: [1]Type
	cells, negated := cells_in(s, &one)
	if negated do return nil
	for m in ms {
		fs := factors(m)
		if len(fs) != 1 do continue
		x := fs[0]
		alpha, t, affine := affine_in(k, e, x)
		a, constant := alpha.(Int)
		if !affine || !constant || a == 0 do continue
		if a == 1 || a == -1 {
			if set, exact := shifted(k, cells, i128(a), t); exact {
				append(&out, Narrowed{x, set, true})
				continue
			}
		}
		image := layout_image(k, t) or_continue
		tl, th := int_bounds(k, image) or_continue
		low := tl.? or_continue
		high := th.? or_continue
		at_low := preimage(k, cells, i128(a), low) or_continue
		at_high := preimage(k, cells, i128(a), high) or_continue
		if !positive {
			append(&out, Narrowed{x, and_law(k, {at_low, at_high}), false})
			continue
		}
		lo1, hi1 := int_bounds(k, at_low) or_continue
		lo2, hi2 := int_bounds(k, at_high) or_continue
		// the hull: a missing bound is unbounded
		lo, hi: Maybe(i128)
		if l1, has1 := lo1.?; has1 do if l2, has2 := lo2.?; has2 do lo = min(l1, l2)
		if h1, has1 := hi1.?; has1 do if h2, has2 := hi2.?; has2 do hi = max(h1, h2)
		append(&out, Narrowed{x, discrete_cell(.Int, lo, hi), false})
	}
	return out[:]
}

// shifted: the integers v such that a·v + t is in the cells, a = ±1: each cell
// lo..hi gives (lo - t)..(hi - t), or (t - hi)..(t - lo).
shifted :: proc(k: ^Kernel, cells: []Type, a: i128, t: Type) -> (set: Type, ok: bool) {
	if !integer_term(k, t) do return
	parts := make([]Type, len(cells))
	for c, i in cells {
		if cell_family(c) != .Int do return
		lo, hi := discrete_bounds(c)
		from, to: Type
		if l, has := lo.?; has do from = op(k, .Sub, Int(l), t)
		if h, has := hi.?; has do to = op(k, .Sub, Int(h), t)
		if a < 0 {
			from, to = to == nil ? nil : op(k, .Neg, to), from == nil ? nil : op(k, .Neg, from)
		}
		parts[i] = range_law(k, from, to, .Int, {})
	}
	return or_law(k, parts), true
}

// narrow_either: the rewrite a disjunction makes: each side narrows on its own; an
// unknown is in the union of what the sides it reaches narrow it to; a side that
// no value reaches adds nothing. Not reached when no side is.
narrow_either :: proc(k: ^Kernel, base: Rewrite, sides: []Type) -> (out: Rewrite, reached: bool) {
	rewrites := make([dynamic]Rewrite)
	for side in sides {
		r, side_reached, _ := narrow(k, base, side)
		if side_reached do append(&rewrites, r)
	}
	if len(rewrites) == 0 do return nil, false
	out = base
	first: for x in rewrites[0] {
		if x.unknown == nil do continue
		layouts := make([dynamic]Type)
		for r in rewrites {
			t, found := rewritten(r, x.unknown)
			if !found do continue first
			w, narrowed := t.(^Unknown)
			append(&layouts, narrowed ? layout_of(k, w) : t)
		}
		out = rewriting(out, x.unknown, narrowing(x.unknown, or_law(k, layouts[:])))
	}
	return out, true
}
