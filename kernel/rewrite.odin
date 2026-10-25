package kernel

import "core:fmt"
import "core:slice"
import "core:strings"

// REWRITING AN UNKNOWN
//
// The layout of an unknown is in its term: `?ₖ::L` (§2). A rewrite replaces
// unknowns, by their index, with other terms, and simplifies the result by the
// same laws:
//
//   - in a branch, the unknown its reach narrows is `?ₖ::(L & S)` (§6, §7);
//     `?ₖ::p`, in a single primitive, is p;
//   - a call of a solved equation puts its arguments in the solution (§5.6).
//
// A scope is a value: a rewrite does not enter it. What is taken out of it in a
// branch — a name, an access, a collapse — is rewritten there.

Rewrite :: map[int]Type

// rewrite: t with its unknowns rewritten, in normal form.
rewrite :: proc(k: ^Kernel, t: Type, r: Rewrite) -> Type {
	if len(r) == 0 || t == nil do return t
	switch v in t {
	case Char, Int, Real, Bool, None, Invalid:
		return t
	case ^Unknown:
		if x, found := r[v.id]; found do return x
		return t
	case ^Operation:
		if is_string_value(t) do return t
		return operation_law(k, v.op, rewrite_all(k, v.args, r), v.span)
	case ^Or:
		return or_law(k, rewrite_all(k, v.terms, r))
	case ^And:
		return and_law(k, rewrite_all(k, v.terms, r))
	case ^Not:
		return not_law(k, rewrite(k, v.term, r))
	case ^Is:
		return is_law(rewrite(k, v.term, r))
	case ^Range:
		return range_law(k, rewrite(k, v.lo, r), rewrite(k, v.hi, r), v.family, v.span)
	case ^Pattern:
		p := new(Pattern)
		p.target, p.span = rewrite(k, v.target, r), v.span
		p.branches = make([]Branch, len(v.branches))
		for b, i in v.branches do p.branches[i] = Branch{cover = b.cover, product = rewrite(k, b.product, r), span = b.span}
		return pattern_law(k, p)
	case ^Scope, ^Name, ^Access, ^Collapse, ^Carve, ^Default:
	}
	return t
}

rewrite_all :: proc(k: ^Kernel, ts: []Type, r: Rewrite) -> []Type {
	out := make([]Type, len(ts))
	for t, i in ts do out[i] = rewrite(k, t, r)
	return out
}

// narrowing: the unknown u in the layout l: `?ₖ::l`, or the primitive l itself.
narrowing :: proc(u: ^Unknown, l: Type) -> Type {
	if is_primitive(l) do return l
	n := new(Unknown)
	n^ = u^
	n.layout = l
	return n
}

// layout_of: the layout of an unknown, in normal form.
layout_of :: proc(k: ^Kernel, u: ^Unknown) -> Type {
	if u.layout == nil {
		u.layout = everything()
		if u.written != nil do u.layout = normal(k, u.written)
	}
	return u.layout
}

// scope_rewrite: the rewrite where a scope is typed: that of the nearest branch or
// carve around it.
scope_rewrite :: proc(s: ^Scope) -> Rewrite {
	for sc := s; sc != nil; sc = sc.parent do if sc.rewrite != nil do return sc.rewrite
	return nil
}

// merge_rewrites: both narrowings at once: an unknown both narrow is in both.
merge_rewrites :: proc(k: ^Kernel, a, b: Rewrite) -> Rewrite {
	if a == nil do return b
	if b == nil do return a
	out := make(Rewrite)
	for id, t in a do out[id] = t
	for id, t in b {
		x, found := out[id]
		if !found {
			out[id] = t
			continue
		}
		u, is_unknown := x.(^Unknown)
		w, other := t.(^Unknown)
		switch {
		case is_unknown && other:
			out[id] = narrowing(u, and_law(k, {layout_of(k, u), layout_of(k, w)}))
		case is_unknown:
			out[id] = t // a primitive: the narrower
		}
	}
	return out
}

rewrite_key :: proc(r: Rewrite) -> string {
	parts := make([dynamic]string)
	for id, t in r {
		layout := t
		if u, ok := t.(^Unknown); ok do layout = u.layout
		append(&parts, fmt.tprintf("%d:%s", id, key_of(layout)))
	}
	slice.sort(parts[:])
	return strings.join(parts[:], ",")
}

// layout_image: a term over unknowns, each replaced by its layout: an operator
// distributes over |, so the term is one value of this image (§4.5, §7). A
// boolean whose value the layouts do not give is false | true. False when the term
// holds what has no layout here: a pattern, a scope.
layout_image :: proc(k: ^Kernel, t: Type) -> (out: Type, ok: bool) {
	switch v in t {
	case Char, Int, Real, Bool, None, Invalid:
		return t, true
	case ^Unknown:
		return layout_of(k, v), true
	case ^Operation:
		if is_string_value(t) do return t, true
		if v.op == .In do return family_term(.Bool), true
		args := make([]Type, len(v.args))
		for a, i in v.args do args[i] = layout_image(k, a) or_return
		return operation_law(k, v.op, args, v.span), true
	case ^Or:
		terms := make([]Type, len(v.terms))
		for a, i in v.terms do terms[i] = layout_image(k, a) or_return
		return or_law(k, terms), true
	case ^And:
		terms := make([]Type, len(v.terms))
		for a, i in v.terms do terms[i] = layout_image(k, a) or_return
		return and_law(k, terms), true
	case ^Not:
		return not_law(k, layout_image(k, v.term) or_return), true
	case ^Is:
		return is_law(layout_image(k, v.term) or_return), true
	case ^Range:
		lo, hi: Type
		if v.lo != nil do lo = layout_image(k, v.lo) or_return
		if v.hi != nil do hi = layout_image(k, v.hi) or_return
		return range_law(k, lo, hi, v.family, v.span), true
	case ^Collapse:
		if f, known := family_of(k, v); known do return family_term(f), true
	case ^Pattern, ^Scope, ^Name, ^Access, ^Carve, ^Default:
	}
	return nil, false
}
