package kernel

import syn "../compiler"
import "core:fmt"

// THE CHECK (specs/types.md §7)
//
//   C:x -> V    ⟺    V in C = true
//
// With unknowns, `V in C` is an equation; each ?ₖ::L ranges over the values of L.
// Its normal form decides it: true for every value of the unknowns, false for
// every one, or it stays. What stays is decided by the laws again, on each side
// of an atom `u in S` of the equation (Boole: f = (a [&] f[a := true]) [|]
// ([~]a [&] f[a := false])), where u is ?::(L & S), then ?::(L & ~S): the atom
// reduces on each side, and the rest with it. A pattern is decided branch by
// branch, each under its reach. What the laws leave is not proven: refused.

// known_layout: the layout of an unknown where it is asked: narrowed by the
// branches around (Facts), or its own.
known_layout :: proc(k: ^Kernel, u: ^Unknown) -> Type {
	return known_layout_in(k, k.facts, u)
}

known_layout_in :: proc(k: ^Kernel, facts: Facts, u: ^Unknown) -> Type {
	if l, found := facts[u]; found do return l
	ready_layout(k, u)
	return u.layout
}

// layout_image: a term over unknowns, each replaced by its layout: an operator
// distributes over |, so the term is one value of this image (§4.5).
layout_image :: proc(k: ^Kernel, t: Type) -> (Type, bool) {
	return substitute(k, t, &Substitution{layouts = true})
}

// elements_in: every element of t is in the type f (§4.5: a set is in a family
// when each of its elements is).
elements_in :: proc(k: ^Kernel, t: Type, f: Type) -> Truth {
	if is_invalid(t) do return .True
	if is_value(k, t) do return decide(k, in_law(k, t, f))
	if !is_constant(t) do return .Unknown
	if r := subset(k, t, f); r != .Unknown do return r
	// a set the laws leave as an operation: its elements are in the family of its result
	if family, known := family_of(k, t); known do return subset(k, family_term(family), f)
	return .Unknown
}

// decide: the truth of a boolean in normal form for every value of its unknowns.
decide :: proc(k: ^Kernel, eq: Type) -> Truth {
	#partial switch v in eq {
	case Bool:
		return truth(bool(v))
	case Invalid:
		return .True // already reported
	case None:
		return .False
	case ^Pattern:
		return decide_branches(k, v)
	case ^Operation:
		#partial switch v.op {
		case .Bit_Not:
			return negate(decide(k, v.args[0]))
		case .Bit_And:
			a, b := decide(k, v.args[0]), decide(k, v.args[1])
			if a == .True && b == .True do return .True
			if a == .False || b == .False do return .False
		case .Bit_Or:
			a, b := decide(k, v.args[0]), decide(k, v.args[1])
			if a == .True || b == .True do return .True
			if a == .False && b == .False do return .False
		}
	}
	return split(k, eq)
}

negate :: proc(t: Truth) -> Truth {
	switch t {
	case .True:
		return .False
	case .False:
		return .True
	case .Unknown:
	}
	return .Unknown
}

// decide_branches: a pattern is true when every branch some value reaches gives
// true under its reach, false when every one gives false.
decide_branches :: proc(k: ^Kernel, p: ^Pattern) -> Truth {
	reached, _, _ := reaches(k, p.target, p.branches)
	results := make([dynamic]Truth)
	for r in reached {
		saved := k.facts
		k.facts = r.facts
		append(&results, decide(k, p.branches[r.branch].product))
		k.facts = saved
	}
	return all_of(results[:])
}

all_of :: proc(results: []Truth) -> Truth {
	all_true, all_false := true, true
	for t in results {
		all_true &&= t == .True
		all_false &&= t == .False
	}
	if all_true do return .True
	if all_false do return .False
	return .Unknown
}

// split: the equation decided on each side of one of its atoms `u in S`.
split :: proc(k: ^Kernel, eq: Type) -> Truth {
	u, s, found := find_atom(k, eq)
	if !found do return .Unknown
	layout := known_layout(k, u)
	results := make([dynamic]Truth)
	for side in ([2]Type{s, not_law(k, s)}) {
		narrowed := and_law(k, {layout, side})
		if is_none(narrowed) do continue
		saved := k.facts
		facts := make(Facts)
		for x, l in saved do facts[x] = l
		facts[u] = narrowed
		k.facts = facts
		append(&results, decide(k, normal(k, eq)))
		k.facts = saved
	}
	return all_of(results[:])
}

// find_atom: an atom `u in S` that each side decides — S a constant type
// without scope, the layout of u too — among the atoms of the equation and the
// conditions of the patterns in it: on each side, the pattern reduces.
find_atom :: proc(k: ^Kernel, eq: Type) -> (^Unknown, Type, bool) {
	#partial switch v in eq {
	case ^Operation:
		if u, s, ok := atom(k, eq); ok do return u, s, true
		for a in v.args do if u, s, found := find_atom(k, a); found do return u, s, true
	case ^Pattern:
		for b in v.branches {
			if b.cover == nil do continue
			if u, s, ok := atom(k, in_law(k, v.target, b.cover)); ok do return u, s, true
		}
		if u, s, found := find_atom(k, v.target); found do return u, s, true
		for b in v.branches do if u, s, found := find_atom(k, b.product); found do return u, s, true
	}
	return nil, nil, false
}

// atom: t is `u in S`, decided on each side.
atom :: proc(k: ^Kernel, t: Type) -> (^Unknown, Type, bool) {
	o, is_op := t.(^Operation)
	if !is_op || o.op != .In do return nil, nil, false
	u, is_unknown := o.args[0].(^Unknown)
	if !is_unknown || !decidable(k, o.args[1]) || !decidable(k, known_layout(k, u)) do return nil, nil, false
	return u, o.args[1], true
}

decidable :: proc(k: ^Kernel, t: Type) -> bool {
	if !is_constant(t) do return false
	r := read(k, t)
	return r.exact && len(r.scopes) == 0
}

// check_in: V in C, for every value of the unknowns.
check_in :: proc(k: ^Kernel, value, color: Type, span: syn.Span) {
	if is_invalid(value) || is_invalid(color) do return
	switch decide(k, in_law(k, value, color)) {
	case .True:
	case .False:
		report(k, .Constraint_Mismatch, span, fmt.tprintf("%s is not in %s", print_type(value), print_type(color)))
	case .Unknown:
		report(k, .Constraint_Mismatch, span, fmt.tprintf("%s is not proven to be in %s", print_type(value), print_type(color)))
	}
}
