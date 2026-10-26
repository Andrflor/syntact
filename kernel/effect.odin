package kernel

import "core:slice"

// EFFECTS (specs/types.md §4.8)
//
// `!?` is an effect. What it does and where it comes from are not written: no law
// copies, replaces, erases or reorders it. It wraps the computation that follows
// it: εₖ(x, t), x what it gives back, bound in t. A pure computation crosses it:
//
//   εₖ(x, a) op c         = εₖ(x, a op c)
//   εₖ(x, a) op εⱼ(y, b)  = εₖ(x, εⱼ(y, a op b))     the effects in the order written
//
// so the laws of §4 apply to what the effects wrap, never to an effect. An effect
// in a branch is in that branch. A scope holds the acts of its bindings until it
// is collapsed: its run gives the production, with the acts of the bindings above
// it, in the order they are written. A name reads what its binding gives back.

// effect_law: εₖ(x, t); x in a single primitive p is p (§7: ?ₖ::p = p): the effect
// gives nothing back, εₖ(t).
effect_law :: proc(k: ^Kernel, e: ^Effect, then: Type) -> Type {
	if e.answer == nil do return wrapped(e, nil, then)
	if layout := layout_of(k, e.answer); is_primitive(layout) do return wrapped(e, nil, rewrite(k, then, rewriting(nil, e.answer, layout)))
	return wrapped(e, e.answer, then)
}

// wrapped: the effect e, with x what it gives back, wrapping t.
wrapped :: proc(e: ^Effect, x: ^Unknown, t: Type) -> Type {
	out := new(Effect)
	out^ = Effect{e.id, x, t, e.span}
	return out
}

// acts: t, in normal form, holds an act where it is computed: it is an effect, or
// a pattern one of whose branches acts.
acts :: proc(t: Type) -> bool {
	#partial switch v in t {
	case ^Effect:
		return true
	case ^Pattern:
		for b in v.branches do if acts(b.product) do return true
	}
	return false
}

// Law: the law of a term on its parts, in normal form and pure.
Law :: proc(k: ^Kernel, t: Type, parts: []Type) -> Type

// sequence: t computed on its parts, in normal form. The parts are computed in the
// order they are written: the first that acts is computed first, and t is in the
// effect it gives, or in each branch of the pattern its act is in. A pure part
// crosses the act. On pure parts, the law of t applies.
sequence :: proc(k: ^Kernel, t: Type, parts: []Type, law: Law) -> Type {
	for part in parts do if is_invalid(part) do return part
	for part, i in parts {
		#partial switch v in part {
		case ^Effect:
			rest := slice.clone(parts)
			rest[i] = v.then
			return wrapped(v, v.answer, sequence(k, t, rest, law))
		case ^Pattern:
			if !acts(v) do continue
			branches := make([]Branch, len(v.branches))
			for b, j in v.branches {
				rest := slice.clone(parts)
				rest[i] = b.product
				branches[j] = Branch{cover = b.cover, product = sequence(k, t, rest, law), span = b.span}
			}
			return pattern_law(k, branching(v, branches))
		}
	}
	return law(k, t, parts)
}

// given: what t gives back, its acts left where they are run: what a name reads.
given :: proc(k: ^Kernel, t: Type) -> Type {
	#partial switch v in t {
	case ^Effect:
		return given(k, v.then)
	case ^Pattern:
		if !acts(v) do return t
		branches := make([]Branch, len(v.branches))
		for b, j in v.branches do branches[j] = Branch{cover = b.cover, product = given(k, b.product), span = b.span}
		return pattern_law(k, branching(v, branches))
	}
	return t
}

// renewed: t, each of its acts with a new answer, but those of kept, new already;
// the new ones join kept. What one run gives back is not what another gives back.
renewed :: proc(k: ^Kernel, t: Type, kept: ^[dynamic]^Unknown) -> Type {
	#partial switch v in t {
	case ^Effect:
		if v.answer == nil || is_kept(kept[:], v.answer) do return wrapped(v, v.answer, renewed(k, v.then, kept))
		x := new(Unknown)
		x^ = v.answer^
		x.id = k.unknowns
		k.unknowns += 1
		append(kept, x)
		return wrapped(v, x, renewed(k, rewrite(k, v.then, rewriting(nil, v.answer, x)), kept))
	case ^Pattern:
		if !acts(v) do return t
		branches := make([]Branch, len(v.branches))
		for b, j in v.branches do branches[j] = Branch{cover = b.cover, product = renewed(k, b.product, kept), span = b.span}
		return pattern_law(k, branching(v, branches))
	}
	return t
}

is_kept :: proc(kept: []^Unknown, u: ^Unknown) -> bool {
	for x in kept do if same_unknown(x, u) do return true
	return false
}

// branching: the pattern p, with these branches.
branching :: proc(p: ^Pattern, branches: []Branch) -> ^Pattern {
	out := new(Pattern)
	out.target, out.branches, out.span = p.target, branches, p.span
	return out
}

// with_acts: v, what the production p of s gives — nil: the default production,
// none, below every binding —, with the acts of the bindings above it, in the order
// they are written (§4.8). Another production is not run; what is below p is not
// reached, like code after a return.
with_acts :: proc(k: ^Kernel, s: ^Scope, p: ^Binding, v: Type) -> Type {
	acting := make([dynamic]Type)
	for b in placed(k, s, .Value) {
		if b == p do break
		if b.kind == .Product do continue
		if t := binding_type(k, b); acts(t) do append(&acting, t)
	}
	if len(acting) == 0 do return v
	append(&acting, v)
	return sequence(k, nil, acting[:], last_part)
}

// collapsed: s!, one run of s (§4.8): its production, or the default one, with the
// acts above it. Each act of the run gives back a new answer: a binding of s that
// acts is carved to its act renewed, so that what names it reads the new answer;
// then the other acts of the production are renewed.
collapsed :: proc(k: ^Kernel, s: ^Scope, c: ^Collapse) -> Type {
	answers := make([dynamic]^Unknown)
	changes := make(map[^Binding]Type)
	for b in placed(k, s, .Value) {
		if b.kind == .Product do break
		if b.scope != s do continue // placed by an expansion: renewed with the production
		if t := binding_type(k, b); acts(t) do changes[b] = renewed(k, t, &answers)
	}
	inner := len(changes) > 0 ? carved_copy(k, s, changes) : s
	return renewed(k, product_of(k, inner, c), &answers)
}

last_part :: proc(k: ^Kernel, t: Type, parts: []Type) -> Type {
	return parts[len(parts) - 1]
}
