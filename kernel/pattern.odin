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

// pattern_law: p, a pattern a law built of normal terms, on its target.
pattern_law :: proc(k: ^Kernel, p: ^Pattern) -> Type {
	return pattern_on(k, p.target, p)
}

// branch_term: a term of the branch b, normal: written in its scope, its normal
// form; built by a law, normal already — not normalized again.
branch_term :: proc(k: ^Kernel, b: Branch, t: Type) -> Type {
	return b.scope != nil ? normal(k, t) : t
}

// pattern_on: the pattern p on its target, in normal form. A cover is computed when
// its branch is tested, after the target, on the paths that come to it (§4.8): the
// pattern is the first branch, then the others,
//
//   t ? {c₀ -> p₀  …  cᵢ -> pᵢ  …} = t ? {c₀ -> p₀  …  -> t ? {cᵢ -> pᵢ  …}}
//
// so the effects of a cover are those of the first branch of a pattern: computed with
// the target, before any test.
pattern_on :: proc(k: ^Kernel, target: Type, p: ^Pattern, outer: Rewrite = nil) -> Type {
	if is_invalid(target) do return target
	// a call whose carve gives each field an unknown — the definition over its fields,
	// universally quantified: the pattern is read on its production (§6), the
	// definitions compose, its calls the hypothesis meanwhile. A call that gives a field
	// a term is never read there: that would unfold it
	if c, is_call := target.(^Collapse); is_call && c.recursive {
		if s, is_scope := c.target.(^Scope); is_scope && at_unknowns(s) {
			if eq, read := equation_of(k, origin(s), call_key(s), through_of(k, s)); read && eq.term != nil {
				eq.reading = true
				defer eq.reading = false
				if v := rewrite(k, eq.term, values_of_call(k, eq, s)); !holds_invalid(v) do return pattern_through(k, v, p, outer)
			}
		}
	}
	return pattern_over(k, target, p, outer)
}

// at_unknowns: the carve s gives each field it changes an unknown of its own, a field
// given a call of another equation such a call.
at_unknowns :: proc(s: ^Scope) -> bool {
	seen := make(map[int]bool)
	defer delete(seen)
	for b in s.changes {
		v := s.changes[b]
		if c, is_call := called(v); is_call {
			t, is_scope := c.target.(^Scope)
			if !is_scope || !at_unknowns(t) do return false
			continue
		}
		u, is_unknown := v.(^Unknown)
		if !is_unknown || u.id in seen do return false
		seen[u.id] = true
	}
	return true
}

// pattern_through: v ? p, a pattern giving one of its products (§6):
// (t ? {c -> q  …}) ? B = t ? {c -> q ? B  …}.
pattern_through :: proc(k: ^Kernel, v: Type, p: ^Pattern, outer: Rewrite) -> Type {
	if q, is_pattern := v.(^Pattern); is_pattern && !has_effect(q) {
		branches := make([]Branch, len(q.branches))
		for b, i in q.branches do branches[i] = with_product(b, pattern_on(k, b.product, p, outer))
		return entered(k, q, branches)
	}
	return pattern_on(k, v, p, outer)
}

// entered: the pattern p, an operation entered in its branches: a pattern gives one of
// its products, op(t ? {c -> q …}) = t ? {c -> op(q) …} (§6). Its target and its covers
// stay, so does the reach of each branch, which its normal form keeps: each product is
// read where that reach holds, rewritten as it narrows. A pattern not read on its
// target yet is read there.
entered :: proc(k: ^Kernel, p: ^Pattern, branches: []Branch) -> Type {
	if !p.reached do return pattern_law(k, branching(p, branches))
	for &b in branches do b.product = rewrite(k, b.product, b.reach)
	out := new(Pattern)
	out^ = p^
	out.branches = branches
	return one_product(k, out)
}

// one_product: p, each branch read where its reach holds — its product as its reach
// rewrites it. Where every value is taken, t ? {c -> q  -> q} = q, and so is the same
// product read in each branch (§6); otherwise p, whose values a check proves taken
// (check.odin).
one_product :: proc(k: ^Kernel, p: ^Pattern) -> Type {
	n := len(p.branches)
	if n == 0 || p.branches[n - 1].cover != nil do return p
	all_same := true
	for b in p.branches[1:] do all_same &&= same(k, b.product, p.branches[0].product)
	if all_same do return p.branches[0].product
	if whole, agrees := agreeing(k, p.branches); agrees do return whole
	return p
}

// branch_reaches: the reach of each branch of p, which its normal form keeps; read on
// its target and its covers when p is not read on them yet (§6).
branch_reaches :: proc(k: ^Kernel, p: ^Pattern) -> (out: [dynamic]Reach, rest: Type, invalid: Type) {
	if !p.reached do return reaches(k, p.target, p.branches)
	out = make([dynamic]Reach, 0, len(p.branches))
	for b, i in p.branches do append(&out, Reach{i, b.cover, b.reach, b.cover == nil, b.unsaid})
	return out, p.rest, nil
}

// pattern_over: the pattern p on its target, not read through a call.
pattern_over :: proc(k: ^Kernel, target: Type, p: ^Pattern, outer: Rewrite) -> Type {
	if q, is_pattern := target.(^Pattern); is_pattern && !has_effect(q) do return pattern_through(k, q, p, outer)
	for b, i in p.branches {
		if b.cover == nil || !has_effect(branch_term(k, b, b.cover)) do continue
		if i == 0 do return sequence(k, p, {target, branch_term(k, b, b.cover)}, covered)
		branches := make([dynamic]Branch)
		append(&branches, ..p.branches[:i])
		// the others, a pattern on the same target: built in its normal form
		append(&branches, Branch{product = pattern_on(k, target, branching(p, p.branches[i:])), span = b.span})
		return pattern_over(k, target, branching(p, branches[:]), outer)
	}
	reached, rest, invalid := reaches(k, target, p.branches)
	if invalid != nil do return invalid
	out := make([dynamic]Branch)
	for r in reached {
		b := p.branches[r.branch]
		product := branch_product(k, b, r.rewrite, target, outer)
		if r.all && len(out) == 0 do return product
		append(&out, Branch{cover = r.all ? nil : r.cover, product = product, span = b.span, reach = r.rewrite, unsaid = r.unsaid})
	}
	q := new(Pattern)
	q.target, q.branches, q.span, q.reached, q.rest = target, out[:], p.span, true, rest
	return one_product(k, q)
}

// agreeing: the product of the last branch, its unknowns as they are outside it,
// when every branch gives it rewritten as its reach narrows them: then the pattern
// is that product (t ? {c -> p -> p} = p, read in each branch).
agreeing :: proc(k: ^Kernel, out: []Branch) -> (Type, bool) {
	if len(out) < 2 do return nil, false
	last := len(out) - 1
	back: Rewrite
	for x in out[last].reach do if x.unknown != nil do back = rewriting(back, x.unknown, x.unknown)
	whole := rewrite(k, out[last].product, back)
	if has_effect(whole) || is_invalid(whole) do return nil, false
	for b in out[:last] do if !same(k, b.product, rewrite(k, whole, b.reach)) do return nil, false
	return whole, true
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
			cover = branch_term(k, b, b.cover)
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
			targets = preimages(k, o.args[0], o.args[1])
		}
		said := false
		for target in targets {
			u, set, exact := target.unknown, rewrite(k, target.set, out), target.exact
			// a layout never reads, through other layouts, its own unknown (§6)
			if !is_constant(set) && depends(k, set, u) do continue
			current := layout_of(k, u)
			if x, found := rewritten(out, u); found {
				current = x
				if w, ok := x.(^Unknown); ok do current = layout_of(k, w)
			}
			layout := and_law(k, {current, positive ? set : not_law(k, set)})
			if is_none(layout) do return nil, false, nil
			out = rewriting(out, u, narrowing(u, layout))
			said ||= exact
			// u is: its layout is not none, each lower end at most each upper one — what
			// that says of the other unknowns narrows them in turn (inhabited)
			if !is_constant(set) {
				reached: bool
				out, reached = inhabited_by(k, out, layout)
				if !reached do return nil, false, nil
			}
			// one unknown narrowed exactly says the literal
			if said do break
		}
		if !said {
			unsaid = bool_and(k, unsaid, l)
			// a term the reach speaks of: t & S in the branch, as ?ₖ::(L & S)
			if _, is_unknown := o.args[0].(^Unknown); !is_unknown do out = restricting(k, out, o.args[0], positive ? o.args[1] : not_law(k, o.args[1]), l)
		}
	}
	return out, true, unsaid
}

// inhabited_by: r, narrowed by what a layout over other unknowns needs to hold a value
// (§6): its ranges meet (§4.1) — the lower end l of each at most the upper end h of
// each other, h - l in 0.., a literal over those unknowns, narrowed the same way; not
// reached when one is false.
inhabited_by :: proc(k: ^Kernel, r: Rewrite, layout: Type) -> (out: Rewrite, reached: bool) {
	out = r
	lows, highs := make([dynamic]Type), make([dynamic]Type)
	range_pieces(k, layout, &lows, &highs)
	for l in lows do for h in highs {
		if is_constant(l) && is_constant(h) do continue
		literal := in_law(k, rewrite(k, op(k, .Sub, h, l), out), COUNTS)
		if is_bool(literal, true) do continue
		if is_bool(literal, false) do return nil, false
		narrowed, inside, _ := narrow(k, out, literal)
		if !inside do return nil, false
		out = narrowed
	}
	return out, true
}

// restricting: r, with the term t restricted to S, t & S — further, when r
// restricts it.
restricting :: proc(k: ^Kernel, r: Rewrite, t, s: Type, literal: Type) -> Rewrite {
	out := make([dynamic]Rewriting)
	current := t
	for x in r {
		if x.read != nil && same(k, x.read, t) {
			current = x.term
			continue
		}
		append(&out, x)
	}
	// t in S is the literal of the reach, already read: not read again
	append(&out, Rewriting{read = t, term = meet_law(k, {current, s}, literal)})
	return out[:]
}

// branch_product: the product of a branch, for the values that reach it: a copy of
// it where each reference from outside is its type — computed once — with the
// unknowns the reach narrows rewritten, ?ₖ::(L & S). The scopes written in it are
// copied likewise: they are the scopes of that branch.
branch_product :: proc(k: ^Kernel, b: Branch, r: Rewrite, target: Type, outer: Rewrite = nil) -> Type {
	b := b
	// a product rewritten with its target: in its branch, where its reach holds
	if outer != nil do b.product = rewrite(k, branch_term(k, b, b.product), outer)
	// the pieces of the value that reaches the branch: the target, narrowed
	pieces := cover_pieces(k, b, rewrite(k, target, r))
	if b.scope == nil || len(r) == 0 && len(pieces) == 0 do return rewrite(k, branch_term(k, b, b.product), r)
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
	// a scope expanding a run: its places are not its bindings, but read by place (§5.3)
	if known do for b in run_data(k, s) do known &&= b.kind != .Expand
	if !known {
		// a scope not known yet: its pieces are terms, x.name for a named place, x.#k for
		// another, and x from k for a last run (§5.6)
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
	branches := make([]Branch, len(p.branches))
	for b, i in p.branches do branches[i] = with_product(b, composed(k, apply(b.product, other)))
	return entered(k, p, branches)
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

// preimages: e = a·u + t, t a term not reading u, in the constant set s, for each
// unknown u of degree 1 in e with a = ±1: u is in the set s - t, or t - s, exactly.
preimages :: proc(k: ^Kernel, e, s: Type) -> []Narrowed {
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
		if !affine || !constant || a != 1 && a != -1 do continue
		if set, exact := shifted(k, cells, i128(a), t); exact do append(&out, Narrowed{x, set, true})
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
