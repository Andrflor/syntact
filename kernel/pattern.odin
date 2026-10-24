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
//
// On an unknown target, `t in c` does not reduce, and the pattern stays an
// equation: Apply(.Match, [t, c₁, p₁, c₂, p₂, …]), the default branch with a nil
// cover. A branch is typed only when some value of t reaches it.

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
	args := make([dynamic]Type)
	append(&args, t)
	taken := type_false() // t in one of the covers above
	taken_sets := NONE // the same, while the covers are constant
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
		reach := bool_operation(.Bit_And, admits, bool_operation(.Bit_Not, taken, nil))
		if never, _ := decide(bool_operation(.Bit_Not, reach, nil), k.narrow); never == .True do continue // no value reaches it
		product := branch_product(k, b.scope, f, t, cover, &taken_sets, &constant_covers)
		if len(args) == 1 && is_bool(admits, true) do return product // the first branch that admits t
		append(&args, cover, product)
		taken = bool_operation(.Bit_Or, taken, admits)
		if is_bool(admits, true) do break
	}
	switch verdict, counterexample := decide(taken, k.narrow); verdict {
	case .True:
	case .False:
		when_ := counterexample == "" ? "" : fmt.tprintf(" (%s)", counterexample)
		return report(k, .Non_Exhaustive_Pattern, m.span, fmt.tprintf("no branch takes every value of %s%s", print_type(t), when_))
	case .Undecided:
		if len(args) > 1 && args[len(args) - 2] == nil do break // a default branch takes the rest
		return report(k, .Unproven, m.span, fmt.tprintf("cannot decide whether a branch takes every value of %s", print_type(t)))
	}
	if len(args) == 1 do return report(k, .Non_Exhaustive_Pattern, m.span, fmt.tprintf("no branch takes %s", print_type(t)))
	return apply_match(k, args[:])
}

// branch_frame: the frame of a branch in f — typed only when it fires.
branch_frame :: proc(k: ^Kernel, s: ^Scope, f: ^Frame) -> ^Frame {
	return literal_frame(k, s, f, false)
}

// branch_product: the product of a branch. What it checks holds for the values of
// the target that reach the branch: when the target is an unknown and the covers
// are constant, the unknown is narrowed to them while the product is typed (§6:
// for each value of the target, the laws apply).
branch_product :: proc(k: ^Kernel, s: ^Scope, f: ^Frame, t, cover: Type, taken: ^Set, constant_covers: ^bool) -> Type {
	u := target_unknown(t)
	cs, constant := cover.(Set)
	if cover != nil && !constant do constant_covers^ = false
	if u == nil || !constant_covers^ do return value_type(k, branch_frame(k, s, f), 0)
	values, known_values := k.narrow[u]
	if !known_values {
		values, known_values = layout_envelope(u.layout)
		if !known_values do return value_type(k, branch_frame(k, s, f), 0)
	}
	part := set_intersect(values, set_complement(taken^))
	if cover != nil do part = set_intersect(part, cs)
	if cover != nil do taken^ = set_union(taken^, cs)
	previous := k.narrow
	k.narrow = copy_narrow(previous)
	if k.narrow == nil do k.narrow = make(map[^Unknown]Set)
	k.narrow[u] = part
	defer k.narrow = previous
	return value_type(k, branch_frame(k, s, f), 0)
}

// apply_match: the laws of the pattern, on an equation whose target is now
// known further (decide substitutes unknowns).
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
	if len(rest) == 1 do return NONE // no branch: already reported where the pattern is written
	// every branch gives the same product: the pattern is that product
	same := true
	for i := 4; i < len(rest); i += 2 do same &&= type_same(k, rest[i], rest[2])
	if same do return rest[2]
	return new_apply(.Match, ..rest[:])
}

// map_products: the pattern a, each product p replaced by f(p, other): for every
// value of the target, the pattern is one of its products.
map_products :: proc(k: ^Kernel, a: ^Apply, f: proc(k: ^Kernel, p, other: Type) -> Type, other: Type) -> Type {
	args := make([]Type, len(a.args))
	copy(args, a.args)
	for i := 2; i < len(args); i += 2 do args[i] = f(k, args[i], other)
	return apply_match(k, args)
}

match_products :: proc(a: ^Apply) -> []Type {
	out := make([dynamic]Type)
	for i := 2; i < len(a.args); i += 2 do append(&out, a.args[i])
	return out[:]
}

// match_envelope: the values a pattern may take: those of the branches its target
// reaches. When the target is an unknown, each branch is read with the unknown
// narrowed to the values that reach it.
match_envelope :: proc(a: ^Apply, narrow: map[^Unknown]Set) -> (result: Set, ok: bool) {
	t := a.args[0]
	values := envelope(t, narrow) or_return
	u := target_unknown(t)
	taken := NONE
	for i := 1; i + 1 < len(a.args); i += 2 {
		c, p := a.args[i], a.args[i + 1]
		part := set_intersect(values, set_complement(taken))
		cs, constant := c.(Set)
		if c != nil && constant do part = set_intersect(part, cs)
		if set_is_none(part) do continue
		n := make(map[^Unknown]Set)
		for key, v in narrow do n[key] = v
		if u != nil do n[u] = part
		e := envelope(p, n) or_return
		result = set_union(result, e)
		if c == nil do break
		if constant do taken = set_union(taken, cs)
	}
	return result, true
}

// target_unknown: the unknown t is, when it is one.
target_unknown :: proc(t: Type) -> ^Unknown {
	#partial switch v in t {
	case ^Unknown:
		return v
	case Poly:
		if len(v.monos) == 1 && v.constant == 0 && v.denom == 1 && v.monos[0].coef == 1 && len(v.monos[0].vars) == 1 do return v.monos[0].vars[0]
	}
	return nil
}
