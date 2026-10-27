package kernel

import syn "../syntax"
import "core:fmt"
import "core:strings"

// THE CHECK (specs/types.md §7)
//
//   C:x -> V    ⟺    V in C = true
//
// The check simplifies `V in C` by the laws, and reads what is left. It solves
// nothing. Its result is a verdict, not a type:
//
//   Proven     the equation is true for every value of its unknowns
//   Refuted    a value of the unknowns makes it false: a counterexample
//   Unproven   it stays an equation
//
// An atom `u in S` that stays is simplified on each side (Boole), by the law of
// the pattern: eq = (u in S) ? {true -> eq  -> eq}, where each side rewrites u
// into ?ₖ::(L & S), then ?ₖ::(L & ~S): the atom reduces there, and eq with it.
// A pattern is proven when each branch some value reaches is; it is refuted when
// one is refuted for values that its rewrite says exactly.

Verdict :: enum u8 {
	Proven,
	Unproven,
	Refuted,
}

// prove: the verdict on a boolean in normal form; when refuted, the rewrite of the
// unknowns for which it is false.
prove :: proc(k: ^Kernel, eq: Type) -> (Verdict, Rewrite) {
	#partial switch v in eq {
	case Bool:
		return bool(v) ? .Proven : .Refuted, nil
	case Invalid:
		return .Proven, nil // already reported
	case ^Pattern:
		return prove_branches(k, v)
	}
	if u, s, found := find_atom(k, eq); found do return prove(k, boole(k, u, s, eq))
	return .Unproven, nil
}

// boole: eq = (u in S) ? {true -> eq  -> eq}.
boole :: proc(k: ^Kernel, u: ^Unknown, s: Type, eq: Type) -> Type {
	p := new(Pattern)
	p.target = new_operation(.In, u, s)
	p.branches = make([]Branch, 2)
	p.branches[0] = Branch{cover = Bool(true), product = eq}
	p.branches[1] = Branch{product = eq}
	return pattern_law(k, p)
}

prove_branches :: proc(k: ^Kernel, p: ^Pattern) -> (Verdict, Rewrite) {
	reached, _, _ := reaches(k, p.target, p.branches)
	verdict := Verdict.Proven
	for r in reached {
		v, witness := prove(k, p.branches[r.branch].product)
		switch v {
		case .Proven:
		case .Refuted:
			if witness == nil do witness = r.rewrite
			if r.exact do return .Refuted, witness
			verdict = .Unproven
		case .Unproven:
			verdict = .Unproven
		}
	}
	return verdict, nil
}

// find_atom: an atom `u in S` that each side reduces — S a constant type without
// scope, the layout of u too — among the atoms of the equation and the conditions
// of the patterns in it.
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

// atom: t is `u in S`, reduced on each side.
atom :: proc(k: ^Kernel, t: Type) -> (^Unknown, Type, bool) {
	o, is_op := t.(^Operation)
	if !is_op || o.op != .In do return nil, nil, false
	u, is_unknown := o.args[0].(^Unknown)
	if !is_unknown || !decided(o.args[1]) || !decided(layout_of(k, u)) do return nil, nil, false
	return u, o.args[1], true
}

// proven_in: every element of t is in f — for a value, `t in f` is proven; for a
// set, t & ~f = none (§4.5: a set is in a family when each of its elements is).
proven_in :: proc(k: ^Kernel, t: Type, f: Type) -> bool {
	if is_invalid(t) do return true
	if is_value(k, t) {
		verdict, _ := prove(k, in_law(k, t, f))
		return verdict == .Proven
	}
	return included(k, t, f)
}

// check_in: V in C, for every value of the unknowns, reported when it is not.
check_in :: proc(k: ^Kernel, value, color: Type, span: syn.Span) {
	if is_invalid(value) || is_invalid(color) do return
	if p, ok := in_problem(k, value, color, span).(Invalid); ok do report(k, p.problem.kind, p.problem.span, p.problem.message)
}

// in_problem: V in C, for every value of the unknowns: nil when proven, otherwise
// the problem. An effect is not a value: the verdict is read on what the effects
// wrap (§4.8).
in_problem :: proc(k: ^Kernel, value, color: Type, span: syn.Span) -> Type {
	switch verdict, witness := prove(k, in_law(k, given(k, value), color)); verdict {
	case .Proven:
	case .Refuted:
		return problem(.Constraint_Mismatch, span, fmt.tprintf("%s is not in %s%s", print_type(value), print_type(color), print_witness(witness)))
	case .Unproven:
		return problem(.Constraint_Mismatch, span, fmt.tprintf("%s is not proven to be in %s", print_type(value), print_type(color)))
	}
	return nil
}

// print_witness: the values of the unknowns for which the equation is false.
print_witness :: proc(r: Rewrite) -> string {
	if len(r) == 0 do return ""
	parts := make([dynamic]string)
	for x in r {
		layout := x.term
		if u, ok := x.term.(^Unknown); ok do layout = u.layout
		append(&parts, fmt.tprintf("?%d in %s", x.unknown.id, print_type(layout)))
	}
	return fmt.tprintf(" when %s", strings.join(parts[:], ", "))
}
