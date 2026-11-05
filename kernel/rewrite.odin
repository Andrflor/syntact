package kernel

import "core:fmt"
import "core:slice"
import "core:strings"

// REWRITING AN UNKNOWN
//
// The layout of an unknown is in its term: `?ₖ::L` (§2). A rewrite replaces
// unknowns, by their index, with other terms — and a recursive call with what it
// gives back, in the solution of its equation (§5.6) —, and simplifies the result by
// the same laws:
//
//   - in a branch, the unknown its reach narrows is `?ₖ::(L & S)` (§6, §7);
//     `?ₖ::p`, in a single primitive, is p;
//   - a call of a solved equation puts its arguments in the solution (§5.6).
//

Rewrite :: []Rewriting

// Rewriting: ?ₖ ↦ t, a recursive call ↦ t, or a read of a run x.#k ↦ t.
Rewriting :: struct {
	unknown: ^Unknown,
	call:    ^Collapse,
	read:    ^Operation,
	term:    Type,
}

// rewritten: the term an unknown is rewritten to, when it is.
rewritten :: proc(r: Rewrite, u: ^Unknown) -> (Type, bool) {
	for x in r do if x.unknown != nil && same_unknown(x.unknown, u) do return x.term, true
	return nil, false
}

// rewriting: r, with u rewritten to t.
rewriting :: proc(r: Rewrite, u: ^Unknown, t: Type) -> Rewrite {
	out := make([dynamic]Rewriting)
	for x in r do if x.unknown == nil || !same_unknown(x.unknown, u) do append(&out, x)
	append(&out, Rewriting{unknown = u, term = t})
	return out[:]
}

// rewriting_call: r, with the recursive call c rewritten to t.
rewriting_call :: proc(r: Rewrite, c: ^Collapse, t: Type) -> Rewrite {
	out := make([dynamic]Rewriting)
	append(&out, ..r)
	append(&out, Rewriting{call = c, term = t})
	return out[:]
}

// reads: t holds the unknown u: rewriting u changes it.
reads :: proc(k: ^Kernel, t: Type, u: ^Unknown) -> bool {
	return !same(k, rewrite(k, t, rewriting(nil, u, new_unknown(k, nil))), t)
}

// rewrite: t with its unknowns rewritten, in normal form. A term none of whose parts
// a rewrite changes is the term itself: in normal form, its parts the same, its law
// gives it back — only what holds a rewritten unknown is computed again.
rewrite :: proc(k: ^Kernel, t: Type, r: Rewrite) -> Type {
	if len(r) == 0 || t == nil do return t
	switch v in t {
	case Char, Int, Real, Bool, None, Invalid:
		return t
	case ^Unknown:
		if x, found := rewritten(r, v); found do return x
		return t
	case ^Effect:
		then := rewrite(k, v.then, r)
		if v.write != nil {
			w := new(Write)
			w^ = v.write^
			w.value = rewrite(k, v.write.value, r)
			// a place renewed by a run is the place of that run
			if w.place != nil do if x, found := rewritten(r, w.place); found do if p, is_place := x.(^Unknown); is_place do w.place = p
			if then == v.then && w.value == v.write.value && w.place == v.write.place do return t
			out := new(Effect)
			out^ = v^
			out.write = w
			return writing(k, out, then)
		}
		call := v.call != nil ? rewrite_call(k, v.call, r) : nil
		fold := v.fold != nil ? rewrite_fold(k, v.fold, r) : nil
		if v.choice != nil {
			chosen := rewrite(k, v.choice, r)
			if then == v.then && chosen == v.choice do return t
			// a choice the rewrite decided is the effects of its branch, then what follows
			if !has_effect(chosen) do return then
			if _, still := chosen.(^Pattern); !still do return sequence(k, nil, {chosen, then}, last_part)
			out := new(Effect)
			out^ = v^
			out.choice, out.then = chosen, then
			return out
		}
		emission := v.emission
		if emission != nil {
			sent := rewrite(k, emission.sent, r)
			if sent != emission.sent {
				emission = new(Emission)
				emission^ = v.emission^
				emission.sent = sent
			}
		}
		if then == v.then && call == v.call && fold == v.fold && emission == v.emission do return t
		out := effect_law(k, v, then)
		if e, is_effect := out.(^Effect); is_effect {
			if v.call != nil do e.call = call
			if v.fold != nil do e.fold = fold
			e.emission = emission
		}
		return out
	case ^Collapse:
		for x in r do if x.call != nil && same(k, x.call, v) do return x.term
		return rewrite_call(k, v, r)
	case ^Fold:
		parts := fold_parts(v)
		rewritten := rewrite_all(k, parts, r)
		if identical(rewritten, parts) do return t
		return fold_law(k, with_parts(v, rewritten))
	case ^Least:
		holds := rewrite(k, v.holds, r)
		if holds == v.holds do return t
		return least_law(k, v.index, holds, v.span)
	case ^Series:
		out := new(Series)
		out^ = v^
		out.lo, out.hi, out.term = rewrite(k, v.lo, r), rewrite(k, v.hi, r), rewrite(k, v.term, r)
		if out.lo == v.lo && out.hi == v.hi && out.term == v.term do return t
		return series_law(k, out)
	case ^Recurrent:
		out := new(Recurrent)
		out^ = v^
		out.initial, out.at = rewrite_all(k, v.initial, r), rewrite(k, v.at, r)
		if identical(out.initial, v.initial) && out.at == v.at do return t
		return recurrent_law(k, out)
	case ^Operation:
		if is_string_value(t) do return t
		for x in r do if x.read != nil && same(k, x.read, v) do return x.term
		args := rewrite_all(k, v.args, r)
		if identical(args, v.args) do return t
		return as_normal(operation_law(k, v.op, args, v.span))
	case ^Or:
		terms := rewrite_all(k, v.terms, r)
		if identical(terms, v.terms) do return t
		return as_normal(or_law(k, terms))
	case ^And:
		terms := rewrite_all(k, v.terms, r)
		if identical(terms, v.terms) do return t
		return as_normal(and_law(k, terms))
	case ^Not:
		term := rewrite(k, v.term, r)
		if term == v.term do return t
		return as_normal(not_law(k, term))
	case ^Is:
		term := rewrite(k, v.term, r)
		if term == v.term do return t
		return as_normal(is_law(term))
	case ^Range:
		lo, hi := rewrite(k, v.lo, r), rewrite(k, v.hi, r)
		if lo == v.lo && hi == v.hi do return t
		return as_normal(range_law(k, lo, hi, v.family, v.span))
	case ^Pattern:
		p := new(Pattern)
		p.target, p.span = rewrite(k, v.target, r), v.span
		p.branches = make([]Branch, len(v.branches))
		moved := false
		for b, i in v.branches {
			p.branches[i] = with_product(b, rewrite(k, b.product, r))
			moved ||= p.branches[i].product != b.product
		}
		if p.target != v.target do return as_normal(pattern_law(k, p))
		if !moved do return t
		// the target the same, so are its unknowns, and the reach of each branch: only
		// its product is rewritten; t ? {c -> p  -> p} = p, where every value is taken
		all_same := p.branches[len(p.branches) - 1].cover == nil
		for b in p.branches[1:] do all_same &&= same(k, b.product, p.branches[0].product)
		if all_same do return p.branches[0].product
		return as_normal(p)
	case ^Scope:
		return rewrite_carve(k, v, r)
	case ^Access:
		// x.a, x rewritten: the field of what x becomes
		target := rewrite(k, v.target, r)
		if target == v.target do return t
		return as_normal(access_law(k, target, v))
	case ^Name, ^Carve, ^Default:
	}
	return t
}

// rewrite_call: a call that stays, whose carve gives values over the unknowns
// rewritten: the call of the carve with those values rewritten.
rewrite_call :: proc(k: ^Kernel, c: ^Collapse, r: Rewrite) -> ^Collapse {
	s, is_scope := c.target.(^Scope)
	if !is_scope do return c
	carved := rewrite_carve(k, s, r)
	if carved == s do return c
	out := new(Collapse)
	out^ = c^
	out.target = carved
	return out
}

// rewrite_carve: s{x -> v} with u rewritten is s{x -> v with u rewritten}. A
// written scope is rewritten as the carve of its bindings to their values
// rewritten. The scope itself when nothing changes.
rewrite_carve :: proc(k: ^Kernel, s: ^Scope, r: Rewrite) -> ^Scope {
	if s.carved == nil {
		changes := make(map[^Binding]Type)
		moved := false
		for b in s.bindings {
			if b.value == nil || b.kind == .Pull || b.kind == .Handler || b.resonance != nil do continue
			v := binding_type(k, b)
			changes[b] = rewrite(k, v, r)
			moved ||= !same(k, changes[b], v)
		}
		if !moved do return s
		return carved_copy(k, s, changes)
	}
	changes := make(map[^Binding]Type)
	moved := false
	for b, v in s.changes {
		w := rewrite(k, v, r)
		// the place of a resonant binding is not a read of it: it follows only a place
		if _, is_place := w.(^Unknown); b.resonance != nil && !is_place do w = v
		changes[b] = w
		moved ||= !same(k, w, v)
	}
	if !moved do return s
	return carved_copy(k, s.carved, changes)
}

// rewrite_fold: the fold with its parts rewritten; what it binds is its own.
rewrite_fold :: proc(k: ^Kernel, f: ^Fold, r: Rewrite) -> ^Fold {
	return with_parts(f, rewrite_all(k, fold_parts(f), r))
}

// identical: the same terms, each the very term.
identical :: proc(a, b: []Type) -> bool {
	if len(a) != len(b) do return false
	for x, i in a do if x != b[i] do return false
	return true
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

// layout_of: the layout of an unknown, in normal form: as narrowed by a branch, or
// as written.
layout_of :: proc(k: ^Kernel, u: ^Unknown) -> Type {
	if u.layout != nil do return u.layout
	if u.written != nil do return normal(k, u.written)
	// what a recursive call gives back: a value of the family of its equation
	if u.call != nil do if f, known := call_family(k, u.call); known do return family_term(f)
	return everything()
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
		// a layout over other unknowns: what it may hold
		layout := layout_of(k, v)
		if !is_constant(layout) do if image, known := layout_image(k, layout); known do return image, true
		return layout, true
	case ^Operation:
		if is_string_value(t) do return t, true
		if v.op == .In do return family_term(.Bool), true
		if v.op == .Length || v.op == .Item || v.op == .From do return run_image(k, v)
		args := make([]Type, len(v.args))
		for a, i in v.args do args[i] = layout_image(k, a) or_return
		// the term computes exactly: only a rounding rounds (format.odin)
		if v.op == .Round do return round_law(k, args[0], bits_format(args[1]), v.span), true
		return related_image(k, t, exact_law(k, v.op, args, v.span)), true
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
		if image, known := call_image(k, v); known do return image, true
		if f, known := family_of(k, v); known do return family_term(f), true
	case ^Fold:
		// a sum along the fold: its init, and as many terms as steps
		if image, known := sum_image(k, v); known do return image, true
		// its value, over the layouts of its states
		if image, known := layout_image(k, v.value); known do return image, true
		if f, known := family_of(k, v); known do return family_term(f), true
	case ^Least:
		return COUNTS, true
	case ^Series:
		if v.op == .Add {
			term := rewrite(k, v.term, rewriting(nil, v.index, narrowing(v.index, range_law(k, v.lo, v.hi, .Int, v.span))))
			if image, known := hull_times(k, op(k, .Add, op(k, .Sub, v.hi, v.lo), Int(1)), term); known do return image, true
		}
		if f, known := family_of(k, t); known do return family_term(f), true
	case ^Recurrent:
		if f, known := family_of(k, t); known do return family_term(f), true
	case ^Access:
		// x.a, x of a shape: the color of a in it
		set := values(k, v.target) or_return
		return field_color(k, set, v.name)
	case ^Effect, ^Pattern, ^Scope, ^Name, ^Carve, ^Default:
	}
	return nil, false
}

// related_image: the image of a term of degree 1 in an unknown narrowed between
// bounds over other unknowns, u::(L & l..h): a·u + r lies between a·l + r and
// a·h + r, each a term over the others — the image keeps what relates them.
// image is the image of the term, each unknown replaced by its layout on its own.
related_image :: proc(k: ^Kernel, t: Type, image: Type) -> Type {
	if !is_constant(image) do return image
	read := make([dynamic]^Unknown)
	read_unknowns(t, &read)
	out := image
	for u in read {
		layout := layout_of(k, u)
		if is_constant(layout) do continue
		alpha, r, affine := affine_in(k, t, u)
		a, constant := alpha.(Int)
		if !affine || !constant || a == 0 do continue
		terms := []Type{layout}
		if both, narrowed := layout.(^And); narrowed do terms = both.terms
		for x in terms {
			bounds, is_range := x.(^Range)
			if !is_range || is_constant(x) do continue
			lo, hi := bounds.lo, bounds.hi
			if a < 0 do lo, hi = hi, lo
			least, most: Type
			if lo != nil do least = term_bound(k, op(k, .Add, op(k, .Mul, alpha, lo), r), true) or_continue
			if hi != nil do most = term_bound(k, op(k, .Add, op(k, .Mul, alpha, hi), r), false) or_continue
			out = and_law(k, {out, range_law(k, least, most, .Int, {})})
		}
	}
	return out
}

// sum_image: the values of a fold whose value is a state x: c ↦ x + g, g not
// reading x: c, and n terms of g, n its steps.
sum_image :: proc(k: ^Kernel, f: ^Fold) -> (image: Type, ok: bool) {
	lo, hi := counter_range(k, f) or_return
	for z, i in f.states {
		if !same(k, f.value, z) do continue
		// x ↦ x + g: the ring reads the update as 1·x + g
		one, g := affine_in(k, f.updates[i], z) or_return
		if !is_int(one, 1) do return
		steps := op(k, .Add, op(k, .Sub, hi, lo), Int(1))
		terms := hull_times(k, steps, rewrite(k, g, rewriting(nil, f.index, narrowing(f.index, range_law(k, lo, hi, .Int, f.span))))) or_return
		start := layout_image(k, f.inits[i]) or_return
		return exact_law(k, .Add, {start, terms}, f.span), true
	}
	return
}

// hull_times: the integers from n·a to n·b, n ≥ 0 the counts of steps, a..b the
// bounds of the values of g: what n terms of g sum to.
hull_times :: proc(k: ^Kernel, n, g: Type) -> (image: Type, ok: bool) {
	steps := layout_image(k, n) or_return
	terms := layout_image(k, g) or_return
	slo, shi := int_bounds(k, steps) or_return
	glo, ghi := int_bounds(k, terms) or_return
	nl := max(slo.? or_return, 0)
	nh := shi.? or_return
	a := glo.? or_return
	b := ghi.? or_return
	la := mul_checked(nl, a) or_return
	ha := mul_checked(nh, a) or_return
	lb := mul_checked(nl, b) or_return
	hb := mul_checked(nh, b) or_return
	return range_law(k, Int(min(la, ha)), Int(max(lb, hb)), .Int, {}), true
}

// field_color: the color of the field `name` in the shape a layout holds — in a
// term of it, when it is narrowed (L & S).
field_color :: proc(k: ^Kernel, layout: Type, name: string) -> (color: Type, ok: bool) {
	if both, narrowed := layout.(^And); narrowed {
		for t in both.terms do if color, ok = field_color(k, t, name); ok do return
		return
	}
	s := layout.(^Scope) or_return
	if !is_shape(k, s) {
		// a scope with productions: the field in those that have it, of one color
		for p in placed(k, s, .Shape) {
			if p.kind != .Product || p.value == nil do continue
			c := field_color(k, binding_type(k, p), name) or_continue
			if color != nil && !same(k, color, c) do return nil, false
			color = c
		}
		return color, color != nil
	}
	for b in placed(k, s, .Shape) do if b.name == name && b.color != nil do return binding_color(k, b), true
	return
}
