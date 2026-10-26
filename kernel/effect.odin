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

// call_act: a recursive call of an equation that acts, as an act: x, what it gives
// back, is bound in what follows it.
call_act :: proc(k: ^Kernel, c: ^Collapse) -> Type {
	x := new_unknown(k, nil)
	x.call = c
	e := new(Effect)
	e^ = Effect{id = -1, answer = x, then = x, call = c, span = c.span}
	return e
}

// wrapped: the effect e, with x what it gives back, wrapping t.
wrapped :: proc(e: ^Effect, x: ^Unknown, t: Type) -> Type {
	out := new(Effect)
	out^ = e^
	out.answer, out.then = x, t
	return out
}

// crossed: what the run s of a symbol behind a boundary gives: the act of its
// production is the call of the symbol, with what the run carved (§4.8).
crossed :: proc(k: ^Kernel, s: ^Scope, c: ^Collapse, product: Type) -> Type {
	e, is_effect := product.(^Effect)
	if !is_effect || e.call != nil do return product
	call := new(Collapse)
	call.target, call.span = s, c.span
	out := new(Effect)
	out^ = e^
	out.call = call
	return out
}

// symbol_of: s is a symbol behind a boundary: the boundary's lib.
symbol_of :: proc(s: ^Scope) -> (lib: string, ok: bool) {
	if s.parent == nil || s.parent.boundary == "" do return "", false
	return s.parent.boundary, true
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

// ran: the acts of the bindings of s above its production p — nil: the default one,
// below every binding —, in the order they are written, joined to parts (§4.8). An
// expansion is computed where it is written, then the bindings it places are.
// Another production is not run; what is below p is not reached, like code after a
// return. True when p is reached, placed by an expansion.
//
// For a run, answers is not nil: each act gives back a new answer, and changes
// carves each binding of s that acts to what it gives back — an expansion to a copy
// of what it places, carved likewise —, so that what reads it reads that answer.
ran :: proc(k: ^Kernel, s: ^Scope, p: ^Binding, parts: ^[dynamic]Type, answers: ^[dynamic]^Unknown, changes: ^map[^Binding]Type) -> bool {
	for b in s.bindings {
		if b == p do return true
		switch b.kind {
		case .Product:
		case .Expand:
			if b.value == nil && b.color == nil do continue
			t := binding_type(k, b)
			acting := acts(t)
			if acting {
				if answers != nil do t = renewed(k, t, answers)
				append(parts, t)
			}
			value := given(k, t)
			placing := make(map[^Binding]Type)
			reached := false
			if inner, is_scope := value.(^Scope); is_scope {
				reached = ran(k, inner, p, parts, answers, &placing)
				if len(placing) > 0 do value = carved_copy(k, inner, placing)
			}
			if answers != nil && (acting || len(placing) > 0) do changes[b] = value
			if reached do return true
		case .Push, .Pull:
			t := binding_type(k, b)
			if !acts(t) do continue
			if answers != nil {
				t = renewed(k, t, answers)
				changes[b] = given(k, t)
			}
			append(parts, t)
		}
	}
	return false
}

// with_acts: v, what the production p of s gives — nil: the default production,
// none —, with the acts of the bindings above it, in the order they are written.
with_acts :: proc(k: ^Kernel, s: ^Scope, p: ^Binding, v: Type) -> Type {
	parts := make([dynamic]Type)
	ran(k, s, p, &parts, nil, nil)
	if len(parts) == 0 do return v
	append(&parts, v)
	return sequence(k, nil, parts[:], last_part)
}

// collapsed: s!, one run of s (§4.8): the acts of the bindings above its production,
// in the order they are written, then the production — or the default one, none.
// Each act of the run gives back a new answer, which what reads its binding reads,
// and which a call takes as a value.
collapsed :: proc(k: ^Kernel, s: ^Scope, c: ^Collapse) -> Type {
	answers := make([dynamic]^Unknown)
	parts := make([dynamic]Type)
	changes := make(map[^Binding]Type)
	p, _ := first_production(k, s)
	ran(k, s, p, &parts, &answers, &changes)
	inner := len(changes) > 0 ? carved_copy(k, s, changes) : s
	product := product_of(k, inner, c)
	if _, behind := symbol_of(inner); behind do product = crossed(k, inner, c, product)
	append(&parts, renewed(k, product, &answers))
	return sequence(k, nil, parts[:], last_part)
}

last_part :: proc(k: ^Kernel, t: Type, parts: []Type) -> Type {
	return parts[len(parts) - 1]
}
