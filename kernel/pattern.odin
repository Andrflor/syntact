package kernel

import "core:fmt"

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
	target := normal(k, p.target)
	if is_invalid(target) do return target
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

// Reach: a branch that values of the target reach: its cover, the rewrite of its
// unknowns, whether every value that comes to it takes it, and whether the rewrite
// says all of its reach.
Reach :: struct {
	branch:  int,
	cover:   Type,
	rewrite: Rewrite,
	all:     bool,
	exact:   bool,
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
		r, reached, exact := narrow(k, nil, reach)
		if !reached do continue
		all := is_bool(rest, false)
		append(&out, Reach{i, cover, r, all, exact})
		if all do return out, nil, nil
	}
	return out, rest, nil
}

// narrow: the rewrite a reach makes: through [&], `u in S` rewrites ?ₖ::L into
// ?ₖ::(L & S), `[~](u in S)` into ?ₖ::(L & ~S). Not reached when the reach is
// false, or a layout becomes none. Exact when the reach is all said so.
narrow :: proc(k: ^Kernel, base: Rewrite, reach: Type) -> (out: Rewrite, reached: bool, exact: bool) {
	if is_bool(reach, false) || is_invalid(reach) do return nil, false, false
	out = base
	exact = true
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
		if !is_op || o.op != .In {
			exact = false
			continue
		}
		u, is_unknown := o.args[0].(^Unknown)
		if !is_unknown || !is_constant(o.args[1]) {
			exact = false
			continue
		}
		current := layout_of(k, u)
		if x, found := rewritten(out, u); found {
			current = x
			if w, ok := x.(^Unknown); ok do current = layout_of(k, w)
		}
		layout := and_law(k, {current, positive ? o.args[1] : not_law(k, o.args[1])})
		if is_none(layout) do return nil, false, false
		out = rewriting(out, u, narrowing(u, layout))
	}
	return out, true, exact
}

// branch_product: the product of a branch, for the values that reach it: a copy of
// it where each reference from outside is its type — computed once — with the
// unknowns the reach narrows rewritten, ?ₖ::(L & S). The scopes written in it are
// copied likewise: they are the scopes of that branch.
branch_product :: proc(k: ^Kernel, b: Branch, r: Rewrite, target: Type) -> Type {
	pieces := cover_pieces(k, b, target)
	if b.scope == nil || len(r) == 0 && len(pieces) == 0 do return rewrite(k, normal(k, b.product), r)
	m := Copier{outer = r, substitute = true, pieces = pieces}
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
			pieces[place] = is_run(place) ? Type(run_scope(k, part)) : binding_type(k, part[0])
		}
		return pieces
	}
	for v in b.view.bindings {
		if found, ok := occurrence(xs, v.name, -1, true); ok do pieces[v] = binding_type(k, found)
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
	for b, i in p.branches do entered.branches[i] = Branch{cover = b.cover, product = apply(b.product, other), span = b.span}
	return pattern_law(k, entered)
}
