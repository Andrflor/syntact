package kernel

import syn "../compiler"
import "core:fmt"

// PATTERNS (specs/types.md §6)
//
// A pattern is a type of the algebra, like | and ~. In `t ? B`, B is a scope of
// branches; each branch is a scope whose production is written in its cover. Like
// `in`, a pattern takes its target whole:
//
//   t ? {c -> p  …} = p              when t in c = true
//   t ? {c -> p  …} = t ? {…}        when t in c = false
//   t ? {-> p  …}   = p              the branch without a cover admits everything
//   t ? {c -> p  -> p} = p           every branch gives the same product
//
// On an unknown target, `t in c` does not reduce: the pattern stays an equation,
// Apply(.Match, [t, c₁, p₁, …]), a nil cover for the default branch. A branch knows
// what its cover proves of the target — the target in its cover and in none of the
// covers above — and its product is typed with that knowledge. A branch that no
// known value of the target reaches is not typed.

Match_Expr :: struct {
	target:   Expr,
	branches: []Branch_Expr,
	span:     syn.Span,
}

Branch_Expr :: struct {
	cover: Expr, // nil: the default branch
	scope: ^Scope, // the branch: its production is the product
	span:  syn.Span,
}

type_match :: proc(k: ^Kernel, f: ^Frame, m: ^Match_Expr) -> Type {
	t := type_of(k, f, m.target)
	if is_invalid(t) do return t
	u := target_unknown(t)
	args := make([dynamic]Type)
	append(&args, t)
	covers := NONE // the covers above, while they are constant
	constant_covers := true
	for b in m.branches {
		cover: Type
		admits := type_true()
		if b.cover != nil {
			cover = type_of(k, f, b.cover)
			if is_invalid(cover) do return Invalid{}
			admits = type_in(k, t, cover)
		}
		if is_bool(admits, false) do continue
		// what the branch knows of the target
		facts := k.facts
		cs, constant := cover.(Set)
		constant_covers &&= cover == nil || constant
		if u != nil && constant_covers {
			if domain, known := known_set(k, u); known {
				part := set_intersect(domain, set_complement(covers))
				if cover != nil do part = set_intersect(part, cs)
				if set_is_none(part) do continue // no known value reaches it
				facts = with_fact(k.facts, u, part)
			}
		}
		if cover != nil && constant do covers = set_union(covers, cs)
		product := branch_product(k, b.scope, f, facts)
		if len(args) == 1 && is_bool(admits, true) do return product // the first branch that admits t
		append(&args, cover, product)
		if is_bool(admits, true) do break
	}
	if len(args) == 1 do return report(k, .Non_Exhaustive_Pattern, m.span, fmt.tprintf("no branch takes %s", print_type(t)))
	if args[len(args) - 2] != nil {
		// no default branch: every value of the target must be taken
		taken := args[1]
		for i := 3; i < len(args); i += 2 do taken = apply_set(.Or, {taken, args[i]})
		if prove_in(k, t, taken) != .Proven do return report(k, .Non_Exhaustive_Pattern, m.span, fmt.tprintf("not proven that a branch takes every value of %s", print_type(t)))
	}
	return apply_match(k, args[:])
}

// branch_product: the product of a branch, typed with what the branch knows.
branch_product :: proc(k: ^Kernel, s: ^Scope, f: ^Frame, facts: Facts) -> Type {
	previous := k.facts
	k.facts = facts
	defer k.facts = previous
	return value_type(k, literal_frame(k, s, f, false), 0)
}

// apply_match: the laws of the pattern, on types.
apply_match :: proc(k: ^Kernel, args: []Type) -> Type {
	t := args[0]
	rest := make([dynamic]Type)
	append(&rest, t)
	for i := 1; i + 1 < len(args); i += 2 {
		c, p := args[i], args[i + 1]
		admits := c == nil ? type_true() : type_in(k, t, c)
		if is_bool(admits, false) do continue
		if len(rest) == 1 && is_bool(admits, true) do return p
		append(&rest, c, p)
		if is_bool(admits, true) do break
	}
	if len(rest) == 1 do return NONE // no branch: reported where the pattern is written
	same_products := true
	for i := 4; i < len(rest); i += 2 do same_products &&= same(k, rest[i], rest[2])
	if same_products do return rest[2]
	return new_apply(.Match, ..rest[:])
}

// map_products: the pattern, each product p replaced by f(p, other).
map_products :: proc(k: ^Kernel, a: ^Apply, f: proc(k: ^Kernel, p, other: Type) -> Type, other: Type) -> Type {
	args := make([]Type, len(a.args))
	copy(args, a.args)
	for i := 2; i < len(args); i += 2 do args[i] = f(k, args[i], other)
	return apply_match(k, args)
}
