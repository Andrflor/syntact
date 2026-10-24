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
// covers above: its reach, `t in c [&] [~](t in c₀) …`. What a branch types holds
// for those values: where the reach says `u in S` of an unknown u, u is, inside
// the branch, `?::(L & S)` — its layout narrowed (Facts). A branch that no value
// reaches is not typed. A value of the target that no branch takes makes the
// pattern non-exhaustive.

pattern_law :: proc(k: ^Kernel, p: ^Pattern) -> Type {
	target := normal(k, p.target)
	if is_invalid(target) do return Invalid{}
	reached, rest, complete := reaches(k, target, p.branches)
	out := make([dynamic]Branch)
	for r in reached {
		b := p.branches[r.branch]
		saved := k.facts
		k.facts = r.facts
		if b.scope != nil do b.scope.facts = r.facts
		product := normal(k, b.product)
		k.facts = saved
		if r.all && len(out) == 0 do return product
		append(&out, Branch{cover = r.all ? nil : r.cover, product = product, span = b.span})
	}
	if complete && rest != nil && decide(k, rest) != .False {
		report(k, .Non_Exhaustive_Pattern, p.span, fmt.tprintf("a value of %s is not proven taken by a branch", print_type(target)))
	}
	if len(out) == 0 do return None{}
	all_same := true
	for b in out[1:] do all_same &&= same(k, b.product, out[0].product)
	if all_same do return out[0].product
	r := new(Pattern)
	r.target, r.branches, r.span = target, out[:], p.span
	return r
}

// Reach: a branch that values of the target reach: its cover, the layouts its
// reach narrows, and whether every value that comes to it takes it.
Reach :: struct {
	branch: int,
	cover:  Type,
	facts:  Facts,
	all:    bool,
}

// reaches: the branches values of the target reach, up to one that every value
// left takes; then rest is nil. Otherwise rest is the condition of the values
// that no branch takes. Not complete when a cover is invalid: already reported.
reaches :: proc(k: ^Kernel, target: Type, branches: []Branch) -> (out: [dynamic]Reach, rest: Type, complete: bool) {
	out = make([dynamic]Reach)
	rest = Bool(true) // the values no branch above takes
	complete = true
	for b, i in branches {
		cond: Type = Bool(true)
		cover: Type
		if b.cover != nil {
			cover = normal(k, b.cover)
			cond = in_law(k, target, cover)
			if is_invalid(cover) || is_invalid(cond) {
				complete = false
				continue
			}
		}
		reach := bool_and(rest, cond)
		rest = bool_and(rest, bool_not(cond))
		facts, reached := narrow(k, k.facts, reach)
		if !reached do continue
		all := is_bool(rest, false)
		append(&out, Reach{i, cover, facts, all})
		if all do return out, nil, complete
	}
	return out, rest, complete
}

// narrow: the layouts a reach narrows: `u in S` narrows u to L & S, `[~](u in S)`
// to L & ~S, through [&]. False when the reach is false, or narrows a layout to
// none: no value reaches.
narrow :: proc(k: ^Kernel, facts: Facts, reach: Type) -> (Facts, bool) {
	if is_bool(reach, false) || is_invalid(reach) do return nil, false
	out := facts
	copied := false
	literals := make([dynamic]Type)
	conjuncts(reach, &literals)
	for l in literals {
		positive := true
		atom := l
		if n, ok := l.(^Operation); ok && n.op == .Bit_Not {
			positive = false
			atom = n.args[0]
		}
		o, is_op := atom.(^Operation)
		if !is_op || o.op != .In do continue
		u, is_unknown := o.args[0].(^Unknown)
		if !is_unknown || !is_constant(o.args[1]) do continue
		part := positive ? o.args[1] : not_law(k, o.args[1])
		layout := and_law(k, {known_layout_in(k, out, u), part})
		if is_none(layout) do return nil, false
		if !copied {
			out = make(Facts)
			for x, l in facts do out[x] = l
			copied = true
		}
		out[u] = layout
	}
	return out, true
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
