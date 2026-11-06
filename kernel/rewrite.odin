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

// Rewriting: ?ₖ ↦ t, a recursive call ↦ t, or a term ↦ t: a read of a run x.#k,
// a term a branch narrows (t ↦ t & S, §6).
Rewriting :: struct {
	unknown: ^Unknown,
	call:    ^Collapse,
	read:    Type,
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

// node_of: the node a term is, nil for a value held in place (a constant).
node_of :: proc(t: Type) -> rawptr {
	#partial switch _ in t {
	case nil, Char, Int, Real, Bool, None, Invalid:
		return nil
	}
	node := t
	return (^rawptr)(&node)^
}

// reads: t holds the unknown u, in one of the parts a rewrite rewrites: a structural
// reading, nothing rewritten.
reads :: proc(k: ^Kernel, t: Type, u: ^Unknown) -> bool {
	#partial switch _ in t {
	case nil, Char, Int, Real, Bool, None, Invalid:
		return false
	}
	// a node is never changed once built: what it reads, asked once; a scope that
	// names itself is not read again
	key := Read_Key{node = node_of(t), unknown = u.id}
	if known, found := k.read[key]; found do return known
	k.read[key] = false
	read := reads_part(k, t, u)
	k.read[key] = read
	return read
}

// reads_part: the parts of t rewrite_node rewrites, read for u.
reads_part :: proc(k: ^Kernel, t: Type, u: ^Unknown) -> bool {
	any :: proc(k: ^Kernel, ts: []Type, u: ^Unknown) -> bool {
		for t in ts do if reads(k, t, u) do return true
		return false
	}
	switch v in t {
	case Char, Int, Real, Bool, None, Invalid, ^Name, ^Default:
		return false
	case ^Carve:
		if reads(k, v.target, u) do return true
		for a in v.args do if a.carves == nil && !a.handler && reads(k, a.value, u) do return true
		return false
	case ^Unknown:
		// itself, or a layout over other unknowns that reads it
		return same_unknown(v, u) || v.layout != nil && !is_constant(v.layout) && reads(k, v.layout, u)
	case ^Effect:
		if reads(k, v.then, u) do return true
		if v.write != nil && (reads(k, v.write.value, u) || v.write.place != nil && same_unknown(v.write.place, u)) do return true
		if v.call != nil && reads(k, v.call, u) do return true
		if v.fold != nil && reads(k, v.fold, u) do return true
		if v.choice != nil && reads(k, v.choice, u) do return true
		return v.emission != nil && reads(k, v.emission.sent, u)
	case ^Collapse:
		return reads(k, v.target, u)
	case ^Fold:
		if reads(k, v.index, u) || any(k, fold_parts(v), u) do return true
		for z in v.states do if reads(k, z, u) do return true
		return false
	case ^Least:
		return reads(k, v.index, u) || reads(k, v.holds, u)
	case ^Series:
		return reads(k, v.index, u) || reads(k, v.lo, u) || reads(k, v.hi, u) || reads(k, v.term, u)
	case ^Recurrent:
		return any(k, v.initial, u) || reads(k, v.at, u)
	case ^Operation:
		return !is_string_value(t) && any(k, v.args, u)
	case ^Or:
		return any(k, v.terms, u)
	case ^And:
		return any(k, v.terms, u)
	case ^Not:
		return reads(k, v.term, u)
	case ^Is:
		return reads(k, v.term, u)
	case ^Range:
		return reads(k, v.lo, u) || reads(k, v.hi, u)
	case ^Pattern:
		if reads(k, v.target, u) do return true
		for b in v.branches do if reads(k, b.cover, u) || reads(k, b.product, u) do return true
		return false
	case ^Scope:
		// what rewrite_carve rewrites: the changes of a carve, the values of a scope
		// as written
		if v.carved != nil {
			for b in in_order(v.changes) do if reads(k, v.changes[b], u) do return true
			return false
		}
		for b in v.bindings {
			if b.value == nil || b.kind == .Pull || b.kind == .Handler || b.resonance != nil do continue
			if reads(k, binding_type(k, b), u) do return true
		}
		return false
	case ^Access:
		return reads(k, v.target, u)
	}
	return false
}

// Read_Key: a node, and an unknown it may read.
Read_Key :: struct {
	node:    rawptr,
	unknown: int,
}
// rewrite: t with its unknowns rewritten, in normal form. A term none of whose parts
// a rewrite changes is the term itself: in normal form, its parts the same, its law
// gives it back — only what holds a rewritten unknown is computed again.
rewrite :: proc(k: ^Kernel, t: Type, r: Rewrite) -> Type {
	if len(r) == 0 || t == nil do return t
	// a shared node rewritten once in a rewrite: a term is a graph of shared nodes,
	// rewritten as a graph, not as the tree it unfolds into
	node := node_of(t)
	if node == nil do return rewrite_node(k, t, r)
	key := Rewrite_Key{node, raw_data(r), len(r)}
	if x, found := k.rewritten[key]; found do return x
	k.rewrites += 1
	out := rewrite_node(k, t, r)
	k.rewrites -= 1
	k.rewritten[key] = out
	if k.rewrites == 0 do clear(&k.rewritten)
	return out
}

// Rewrite_Key: a node and the rewrite it is under.
Rewrite_Key :: struct {
	node:    rawptr,
	rewrite: rawptr,
	len:     int,
}

rewrite_node :: proc(k: ^Kernel, t: Type, r: Rewrite) -> Type {
	for x in r do if x.read != nil && same(k, x.read, t) do return x.term
	switch v in t {
	case Char, Int, Real, Bool, None, Invalid:
		return t
	case ^Unknown:
		if x, found := rewritten(r, v); found {
			// a narrowing of an unknown a branch inside already narrowed: both hold,
			// ?ₖ::(L & S) where L is its layout there (§6)
			if n, narrows := x.(^Unknown); narrows && n.id == v.id && v.layout != nil && n.layout != nil && !same(k, v.layout, n.layout) {
				// runs and scopes stay a written meet, read term by term
				if holds_scope(v.layout) || holds_scope(n.layout) do return narrowing(v, new_and(v.layout, n.layout))
				return narrowing(v, and_law(k, {v.layout, n.layout}))
			}
			return x
		}
		// a layout over other unknowns follows them
		if v.layout != nil && !is_constant(v.layout) {
			if layout := rewrite(k, v.layout, r); layout != v.layout do return narrowing(v, layout)
		}
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
		if _, is_scope := v.target.(^Scope); !is_scope {
			// a scope not known yet, collapsed: its law once the rewrite gives it
			target := rewrite(k, v.target, r)
			if target == v.target do return t
			return collapse_law(k, target, v)
		}
		return rewrite_call(k, v, r)
	case ^Carve:
		// a carve of a scope not known yet: its law once the rewrite gives it
		target := rewrite(k, v.target, r)
		args := slice.clone(v.args)
		moved := target != v.target
		for &a, i in args {
			if a.carves != nil || a.handler || a.value == nil do continue
			a.value = rewrite(k, a.value, r)
			moved ||= a.value != v.args[i].value
		}
		if !moved do return t
		out := new(Carve)
		out^ = v^
		out.target, out.args = target, args
		return carve_law(k, target, out)
	case ^Fold:
		parts := fold_parts(v)
		rewritten := rewrite_all(k, parts, r)
		index, renamed := bound_as(k, r, v.index)
		states := make([]^Unknown, len(v.states))
		for z, i in v.states {
			x, moved := bound_as(k, r, z)
			states[i] = x
			renamed ||= moved
		}
		if identical(rewritten, parts) && !renamed do return t
		// a part with no type: the fold has none
		for p in rewritten do if is_invalid(p) do return p
		// a substitution, part by part: the fold is already in normal form
		out := with_parts(v, rewritten)
		out.index, out.states = index, states
		return out
	case ^Least:
		holds := rewrite(k, v.holds, r)
		index, renamed := bound_as(k, r, v.index)
		if holds == v.holds && !renamed do return t
		return least_law(k, index, holds, v.span)
	case ^Series:
		out := new(Series)
		out^ = v^
		out.lo, out.hi, out.term = rewrite(k, v.lo, r), rewrite(k, v.hi, r), rewrite(k, v.term, r)
		renamed: bool
		out.index, renamed = bound_as(k, r, v.index)
		if out.lo == v.lo && out.hi == v.hi && out.term == v.term && !renamed do return t
		return series_law(k, out)
	case ^Recurrent:
		out := new(Recurrent)
		out^ = v^
		out.initial, out.at = rewrite_all(k, v.initial, r), rewrite(k, v.at, r)
		if identical(out.initial, v.initial) && out.at == v.at do return t
		return recurrent_law(k, out)
	case ^Operation:
		if is_string_value(t) do return t
		args := rewrite_all(k, v.args, r)
		if identical(args, v.args) do return t
		return operation_law(k, v.op, args, v.span)
	case ^Or:
		terms := rewrite_all(k, v.terms, r)
		if identical(terms, v.terms) do return t
		return or_law(k, terms)
	case ^And:
		terms := rewrite_all(k, v.terms, r)
		if identical(terms, v.terms) do return t
		return and_law(k, terms)
	case ^Not:
		term := rewrite(k, v.term, r)
		if term == v.term do return t
		return not_law(k, term)
	case ^Is:
		term := rewrite(k, v.term, r)
		if term == v.term do return t
		return is_law(term)
	case ^Range:
		lo, hi := rewrite(k, v.lo, r), rewrite(k, v.hi, r)
		if lo == v.lo && hi == v.hi do return t
		return range_law(k, lo, hi, v.family, v.span)
	case ^Pattern:
		// a new target: the pattern on it, each product rewritten in its branch (§6)
		if target := rewrite(k, v.target, r); target != v.target do return pattern_on(k, target, v, r)
		// a cover over the unknowns rewritten: the pattern on its new covers
		covers: ^Pattern
		for b, i in v.branches {
			if b.cover == nil do continue
			cover := rewrite(k, b.cover, r)
			if cover == b.cover do continue
			if covers == nil {
				covers = new(Pattern)
				covers^ = v^
				covers.branches = slice.clone(v.branches)
			}
			covers.branches[i].cover = cover
		}
		if covers != nil do return pattern_on(k, v.target, covers, r)
		p := new(Pattern)
		p^ = v^
		p.branches = make([]Branch, len(v.branches))
		moved := false
		for b, i in v.branches {
			p.branches[i] = with_product(b, rewrite(k, b.product, r))
			moved ||= p.branches[i].product != b.product
		}
		if !moved do return t
		// the target the same, so are its unknowns, and the reach of each branch: only
		// its product is rewritten
		return one_product(k, p)
	case ^Scope:
		return rewrite_carve(k, v, r)
	case ^Access:
		// x.a, x rewritten: the field of what x becomes
		target := rewrite(k, v.target, r)
		if target == v.target do return t
		return access_law(k, target, v)
	case ^Name, ^Default:
	}
	return t
}

// rewrite_call: a call that stays, whose carve gives values over the unknowns
// rewritten: the call of the carve with those values rewritten.
rewrite_call :: proc(k: ^Kernel, c: ^Collapse, r: Rewrite) -> ^Collapse {
	s, is_scope := c.target.(^Scope)
	if !is_scope do return c
	carved, still := rewrite_carve(k, s, r).(^Scope)
	if !still || carved == s do return c
	out := new(Collapse)
	out^ = c^
	out.target = carved
	return out
}

// rewrite_carve: s{x -> v} with u rewritten is s{x -> v with u rewritten}. A
// written scope is rewritten as the carve of its bindings to their values
// rewritten. The scope itself when nothing changes.
rewrite_carve :: proc(k: ^Kernel, s: ^Scope, r: Rewrite) -> Type {
	if s.carved == nil {
		// a run — anonymous values and expansions —: the free monoid, its parts
		// rewritten; a part that becomes a known run places its bindings (§5.3)
		run := len(s.bindings) > 0
		for b in s.bindings do run &&= (b.kind == .Push || b.kind == .Expand) && b.name == "" && b.color == nil && b.value != nil
		if run {
			moved := false
			for b in s.bindings do moved ||= !same(k, rewrite(k, binding_value(k, b), r), binding_value(k, b))
			if !moved do return s
			return joined(k, nil, s.bindings[:], r)
		}
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
	for b in in_order(s.changes) {
		v := s.changes[b]
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

// bound_as: an unknown bound in a term — an index, a state — as r rewrites it: as
// its occurrences are, renamed or its layout rewritten.
bound_as :: proc(k: ^Kernel, r: Rewrite, u: ^Unknown) -> (^Unknown, bool) {
	if w, is_unknown := rewrite(k, u, r).(^Unknown); is_unknown && w != u do return w, true
	return u, false
}

// renamed: t before the rewrite at puts its values in it: an unknown bound in t — the
// index and the states of a fold, the index of a Σ or a μ — that those values hold
// would capture them, and is another of the same layout. Otherwise t is the same term:
// the same solution at the same values is one term, shared (§5.6).
renamed :: proc(k: ^Kernel, t: Type, at: Rewrite) -> Type {
	held := make([dynamic]^Unknown)
	for x in at do if x.term != nil do read_unknowns(x.term, &held)
	if len(held) == 0 do return t
	bound := make([dynamic]^Unknown)
	seen := make(map[rawptr]bool)
	defer delete(seen)
	// each node once: a term shares its parts
	visit :: proc(t: Type, out: ^[dynamic]^Unknown, seen: ^map[rawptr]bool) {
		if node := node_of(t); node != nil {
			if node in seen do return
			seen[node] = true
		}
		#partial switch v in t {
		case ^Fold:
			append(out, v.index)
			append(out, ..v.states)
			for p in fold_parts(v) do visit(p, out, seen)
		case ^Series:
			append(out, v.index)
			visit(v.lo, out, seen)
			visit(v.hi, out, seen)
			visit(v.term, out, seen)
		case ^Least:
			append(out, v.index)
			visit(v.holds, out, seen)
		case ^Pattern:
			visit(v.target, out, seen)
			for b in v.branches do visit(b.product, out, seen)
		case ^Effect:
			visit(v.then, out, seen)
			if v.choice != nil do visit(v.choice, out, seen)
		case ^Scope, ^Collapse:
		case:
			for p in parts(t) do visit(p, out, seen)
		}
	}
	visit(t, &bound, &seen)
	r: Rewrite
	next: for u in bound {
		captures := false
		for h in held do captures ||= same_unknown(h, u)
		if !captures do continue next
		fresh := new(Unknown)
		fresh^ = u^
		fresh.id = k.unknowns
		k.unknowns += 1
		r = rewriting(r, u, fresh)
	}
	if len(r) == 0 do return t
	return rewrite(k, t, r)
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
// holds_scope: t is, or is built of, scopes.
holds_scope :: proc(t: Type) -> bool {
	if _, is_scope := t.(^Scope); is_scope do return true
	for p in parts(t) do if holds_scope(p) do return true
	return false
}

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
	// what a recursive call gives back: a value of the family of its base cases
	if u.call != nil do if f, known := base_family(k, u.call); known do return family_term(f)
	return everything()
}

// held: what a layout may hold: itself, or, over unknowns, a set of constants — or
// not given.
held :: proc(k: ^Kernel, layout: Type) -> (image: Type, ok: bool) {
	over := make([dynamic]^Unknown)
	read_unknowns(layout, &over)
	if len(over) == 0 && is_constant(layout) do return layout, true
	image = layout_image(k, layout) or_return
	return image, is_constant(image)
}

// layout_image: a term over unknowns, each replaced by its layout: an operator
// distributes over |, so the term is one value of this image (§4.5, §7). A
// boolean whose value the layouts do not give is false | true. A pattern, the
// images of its products. False when the term holds what has no layout here: a scope.
layout_image :: proc(k: ^Kernel, t: Type) -> (out: Type, ok: bool) {
	switch v in t {
	case Char, Int, Real, Bool, None, Invalid:
		return t, true
	case ^Unknown:
		// a layout over other unknowns: what it may hold
		return held(k, layout_of(k, v))
	case ^Operation:
		if is_string_value(t) do return t, true
		if v.op == .In do return family_term(.Bool), true
		// a binding of a run: what its layout says it holds
		if reads_run(v.op) do return held(k, run_image(k, v) or_return)
		// computed once
		known, plain := plain_of(k, v)
		if plain && known.imaged do return known.image, known.image != nil
		image := translated_image(k, t)
		// the images of its operands: sets of constants, or not given
		args := make([]Type, len(v.args))
		computed := image == nil
		for a, i in v.args {
			if !computed do break
			args[i], computed = layout_image(k, a)
			computed &&= is_constant(args[i])
		}
		// the term computes exactly: only a rounding rounds (format.odin)
		if computed && v.op == .Round do image = round_law(k, args[0], bits_format(args[1]), v.span)
		else if computed do image = exact_law(k, v.op, args, v.span)
		if plain {
			known, _ = plain_of(k, v)
			known.imaged, known.image = true, image
			k.plain[v] = known
		}
		return image, image != nil
	case ^Or:
		terms := make([]Type, len(v.terms))
		for a, i in v.terms do terms[i] = layout_image(k, a) or_return
		return or_law(k, terms), true
	case ^And:
		// what each says: a value its image, a set itself; a term whose values are not
		// read, the family it is proven in, or nothing, ~none: a & ~none = a (§4.1),
		// x & C lies in C
		terms := make([dynamic]Type, 0, len(v.terms))
		for a in v.terms {
			set, read := values(k, a)
			if !read {
				f := family_of(k, a) or_continue
				set = family_term(f)
			}
			append(&terms, set)
		}
		if len(terms) == 0 do return nil, false
		return and_law(k, terms[:]), true
	case ^Not:
		// the complement of what a set over unknowns may hold is not what its complement
		// may hold: only a constant set is complemented
		if !is_constant(v.term) do return nil, false
		return not_law(k, layout_image(k, v.term) or_return), true
	case ^Is:
		// =t holds the values t takes
		return layout_image(k, v.term)
	case ^Range:
		if is_constant(t) do return t, true
		// a range over unknowns: each end replaced by what it may be, the union of the
		// ranges between them (range_law)
		lo, hi: Type
		ends: if true {
			if v.lo != nil {
				lo = layout_image(k, v.lo) or_break ends
				if !is_constant(lo) do break ends
			}
			if v.hi != nil {
				hi = layout_image(k, v.hi) or_break ends
				if !is_constant(hi) do break ends
			}
			if image := range_law(k, lo, hi, v.family, v.span); is_constant(image) do return image, true
		}
		// otherwise its family
		#partial switch v.family {
		case .Int:
			return family_term(.Int), true
		case .Real, .F16, .F32, .F64:
			return family_term(.Real), true
		}
		return nil, false
	case ^Collapse:
		// a call that stays: giving scopes, the scope of its equation, read as a color
		// (§5.4); otherwise the family it is proven in
		f := family_of(k, v) or_return
		// an equation not built, without a term, says nothing of them
		if f == .Value do if s, is_scope := v.target.(^Scope); is_scope {
			g := generalized(k, s, false)
			if _, read := equation(k, g); read do return g, true
		}
		return family_term(f), true
	case ^Fold, ^Series:
		// a node is never changed once built: what it may hold, read once (values), but
		// over a call, the hypothesis while its equation is read
		key := node_of(t)
		if known, found := k.valued[key]; found do return known, known != nil
		image, read := fold_image(k, t)
		if !holds_call(k, t, false) do k.valued[key] = read ? image : nil
		return image, read
	case ^Least:
		return COUNTS, true
	case ^Recurrent:
		if f, known := family_of(k, t); known do return family_term(f), true
	case ^Access:
		// x.a, x of a shape: the color of a in it
		set := values(k, v.target) or_return
		return field_color(k, set, v.name)
	case ^Pattern:
		// a pattern gives one of its products (§6)
		images := make([]Type, len(v.branches))
		for b, i in v.branches do images[i] = layout_image(k, b.product) or_return
		return or_law(k, images), true
	case ^Effect, ^Scope, ^Name, ^Carve, ^Default:
	}
	return nil, false
}

// translated_image: ±u + b, u in a layout over other unknowns: that layout moved by
// b — {a·u + b | u in L} is the v with a·v - a·b in L —, a set over the others, read
// in turn: the unknowns replaced one at a time, the relation kept (§7).
translated_image :: proc(k: ^Kernel, t: Type) -> Type {
	// over unknowns whose layouts are constants, nothing relates them
	us := make([dynamic]^Unknown)
	read_unknowns(t, &us)
	related := false
	for u in us do related ||= !is_constant(layout_of(k, u))
	if !related do return nil
	for d in degree_one(k, t) {
		layout := layout_of(k, d.u)
		if d.a != 1 && d.a != -1 || is_constant(layout) do continue
		set := moved(k, layout, d.a, op(k, .Mul, Int(-d.a), d.b)) or_continue
		if image, read := layout_image(k, set); read && is_constant(image) do return image
	}
	return nil
}

// THE TYPE OF A TERM THE RING DOES NOT READ
//
// What it takes, by the law of its operator, a set over what it reads:
//
//   n % b, n ≥ 0 and b ≥ 1           0..b - 1                   (§4.5)
//   Σ(i: lo..hi, t), t in p..q       n·p..n·q, n = hi - lo + 1   + distributes over |
//                                                                and keeps the order
//   ⟳(…; x: s ↦ x + g; x), g in p..q s + n·p..s + n·q, n steps  its init and the Σ of
//                                                                its steps (§5.6)
//
// p and q, the least and greatest of a constant type (§7).

// term_type: the type of t by the law of its operator.
term_type :: proc(k: ^Kernel, t: Type) -> (type: Type, ok: bool) {
	#partial switch v in t {
	case ^Operation:
		if v.op != .Mod do return
		n, b := v.args[0], v.args[1]
		if !is_bool(in_law(k, n, COUNTS), true) || !is_bool(in_law(k, b, POSITIVE), true) do return
		return and_law(k, {COUNTS, range_law(k, nil, op(k, .Sub, b, Int(1)), .Int, {})}), true
	case ^Series:
		if v.op != .Add do return
		n := op(k, .Add, op(k, .Sub, v.hi, v.lo), Int(1))
		sum := summed_type(k, Int(0), n, v.term) or_return
		return or_law(k, {sum, Int(0)}), true
	case ^Fold:
		if !is_none(v.effects) do return
		lo, hi := counter_range(k, v) or_return
		for z, i in v.states {
			if !same(k, v.value, z) do continue
			one, g := affine_in(k, v.updates[i], z) or_return
			if !is_int(one, 1) do return
			n := op(k, .Add, op(k, .Sub, hi, lo), Int(1))
			sum := summed_type(k, v.inits[i], n, g) or_return
			// no step: its init
			return or_law(k, {sum, range_law(k, v.inits[i], v.inits[i], .Int, {})}), true
		}
	}
	return
}

// summed_type: s plus n terms, each one of the values g takes, from p to q: from
// s + n·p to s + n·q.
summed_type :: proc(k: ^Kernel, s, n, g: Type) -> (type: Type, ok: bool) {
	each := layout_image(k, g) or_return
	if !is_constant(each) do return
	p, q := int_bounds(k, each) or_return
	from, to: Type
	if x, has := p.?; has do from = op(k, .Add, s, op(k, .Mul, n, Int(x)))
	if x, has := q.?; has do to = op(k, .Add, s, op(k, .Mul, n, Int(x)))
	if from == nil && to == nil do return
	return range_law(k, from, to, .Int, {}), true
}

// fold_image: what a fold or a Σ may hold: a run a fold builds, the runs of what its
// steps place; its type by its law (term_type); a fold's value over the layouts of its
// states; otherwise its family.
fold_image :: proc(k: ^Kernel, t: Type) -> (image: Type, ok: bool) {
	if f, is_fold := t.(^Fold); is_fold {
		if image, known := built_image(k, f); known do return image, true
	}
	if type, typed := term_type(k, t); typed {
		if image, read := layout_image(k, type); read && is_constant(image) do return image, true
	}
	if f, is_fold := t.(^Fold); is_fold {
		if image, known := layout_image(k, f.value); known do return image, true
	}
	if f, known := family_of(k, t); known do return family_term(f), true
	return
}

// Plain: what is known of an operation over plain terms — constants, unknowns that
// no call gives, operations over them —, which depends on nothing but the term:
// its image and its family, each computed once.
Plain :: struct {
	plain, imaged, typed: bool,
	image:                Type,
	family:               Maybe(Family),
}

// plain_of: what is known of o, and whether o is plain — found once.
plain_of :: proc(k: ^Kernel, o: ^Operation) -> (Plain, bool) {
	if entry, found := k.plain[o]; found do return entry, entry.plain
	is_plain :: proc(k: ^Kernel, t: Type) -> bool {
		#partial switch v in t {
		case Int, Real, Char, Bool, None:
			return true
		case ^Unknown:
			return v.call == nil
		case ^Operation:
			_, plain := plain_of(k, v)
			return plain
		case ^Fold, ^Series, ^Least, ^Recurrent:
			// a node that holds no call: what it may hold depends on it alone
			return !holds_call(k, t, false)
		}
		return false
	}
	entry := Plain{plain = true}
	for a in o.args do entry.plain &&= is_plain(k, a)
	k.plain[o] = entry
	return entry, entry.plain
}

// built_image: the run a fold builds, {e₀ … eₙ₋₁}: the shape {...{E:} * 0..},
// E the values its steps place.
built_image :: proc(k: ^Kernel, f: ^Fold) -> (image: Type, ok: bool) {
	_, es, builds := built(k, f)
	if !builds do return
	// what a step places: over the index alone, exactly the values it takes, =e, the
	// index in its layout; over the states, what its values may be
	values_of := make([]Type, len(es))
	for e, i in es {
		over_states := false
		for z in f.states do over_states ||= reads(k, e, z)
		values_of[i] = over_states ? values(k, given(k, e)) or_return : is_law(e)
	}
	piece := new_scope(nil, f.span)
	piece.source, piece.complete, piece.reached = piece, true, true
	place := new_binding(piece, .Push, f.span)
	place.color = or_law(k, values_of)
	place.typed_color = place.color
	return repeated(k, piece, COUNTS, f.span), true
}

// field_color: the color of the field `name` in the shape a layout holds — in a
// term of it, when it is narrowed (L & S).
field_color :: proc(k: ^Kernel, layout: Type, name: string) -> (color: Type, ok: bool) {
	if both, narrowed := layout.(^And); narrowed {
		for t in both.terms do if color, ok = field_color(k, t, name); ok do return
		return
	}
	if any, either := layout.(^Or); either {
		// one of these scopes: the field in those that have it, its values in any
		for t in any.terms {
			c := field_color(k, t, name) or_continue
			color = color == nil ? c : or_law(k, {color, c})
		}
		return color, color != nil
	}
	s := layout.(^Scope) or_return
	if !is_shape(k, s) {
		// what the productions of s give, read once: while it is read, the field of s
		// itself adds nothing, X = X | P (§5.6)
		for f in k.fields do if f.scope == s && f.name == name do return f.color, f.color != nil
		at := len(k.fields)
		append(&k.fields, Field{s, name, nil})
		color, ok = produced_field(k, s, name)
		k.fields[at].color = ok ? color : nil
		return
	}
	c, has := shape_field(k, s, name, nil) or_return
	return c, has
}

// Field: the color of a field of the scope of an equation, read once.
Field :: struct {
	scope: ^Scope,
	name:  string,
	color: Type,
}

// produced_field: the field name of what the productions of s give, through their
// patterns (§6) — in those that have it, its values the union of theirs (§5.3); a
// call of s itself, or a read of one, adds nothing: X = X | P.
produced_field :: proc(k: ^Kernel, s: ^Scope, name: string) -> (color: Type, ok: bool) {
	for p in placed(k, s, .Shape) {
		if p.kind != .Product || p.value == nil do continue
		leaves := make([dynamic]Product)
		products(k, binding_type(k, p), &leaves)
		for leaf in leaves {
			if is_none(leaf.term) || is_call_of(leaf.term, s) do continue
			c: Type
			if shape, is_scope := leaf.term.(^Scope); is_scope && is_shape(k, shape) {
				has: bool
				c, has = shape_field(k, shape, name, s) or_return
				if !has do continue
			} else {
				c = field_color(k, leaf.term, name) or_return
			}
			color = color == nil ? c : or_law(k, {color, c})
		}
	}
	return color, color != nil
}

// shape_field: the color of the field name of the shape s, when it has one; written
// without color, its values — nothing when it reads the field of a call of itself.
shape_field :: proc(k: ^Kernel, s: ^Scope, name: string, itself: ^Scope) -> (color: Type, has: bool, ok: bool) {
	for b in placed(k, s, .Shape) {
		if b.name != name do continue
		if b.color != nil do return binding_color(k, b), true, true
		if b.value == nil do return nil, false, false
		v := binding_value(k, b)
		if c, read := call_read(v); read && itself != nil && is_call_of(c, itself) do return nil, false, true
		set := values(k, v) or_return
		return set, true, true
	}
	return nil, false, true
}

// is_call_of: t is a recursive call of the scope s, or of the equation s reads.
is_call_of :: proc(t: Type, s: ^Scope) -> bool {
	c := as_call(t) or_return
	target := c.target.(^Scope) or_return
	return origin(target) == origin(s)
}

