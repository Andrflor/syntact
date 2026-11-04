package kernel

import syn "../syntax"
import "core:fmt"
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
// in a branch is in that branch. A scope holds the effects of its bindings until
// it is collapsed: its run gives the production, with the effects of the bindings
// above it, in the order they are written. A name reads what its binding gives back.

// effect_law: εₖ(x, t); x in a single primitive p is p (§7: ?ₖ::p = p): the effect
// gives nothing back, εₖ(t).
effect_law :: proc(k: ^Kernel, e: ^Effect, then: Type) -> Type {
	if e.write != nil do return writing(k, e, then)
	if e.answer == nil do return wrapped(e, nil, then)
	if layout := layout_of(k, e.answer); is_primitive(layout) do return wrapped(e, nil, rewrite(k, then, rewriting(nil, e.answer, layout)))
	return wrapped(e, e.answer, then)
}

// call_effect: a recursive call of an equation with effects, as an effect: x, what
// it gives back, is bound in what follows it.
call_effect :: proc(k: ^Kernel, c: ^Collapse) -> Type {
	x := new_unknown(k, nil)
	x.call = c
	e := new(Effect)
	e^ = Effect{id = -1, answer = x, then = x, call = c, span = c.span}
	return e
}

// chain_answers: what each effect of the chain heading t gives back, in order;
// nil for one that gives nothing.
chain_answers :: proc(t: Type) -> []^Unknown {
	out := make([dynamic]^Unknown)
	for e, is_effect := t.(^Effect); is_effect; e, is_effect = e.then.(^Effect) do append(&out, e.answer)
	return out[:]
}

// wrapped: the effect e, with x what it gives back, wrapping t.
wrapped :: proc(e: ^Effect, x: ^Unknown, t: Type) -> Type {
	out := new(Effect)
	out^ = e^
	out.answer, out.then = x, t
	return out
}

// crossed: what the run s of a symbol behind a boundary gives: the effect of its
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

// has_effect: t, in normal form, holds an effect where it is computed: it is an
// effect, or a pattern one of whose branches has one.
has_effect :: proc(t: Type) -> bool {
	#partial switch v in t {
	case ^Effect:
		return true
	case ^Pattern:
		for b in v.branches do if has_effect(b.product) do return true
	}
	return false
}

// Law: the law of a term on its parts, in normal form and pure.
Law :: proc(k: ^Kernel, t: Type, parts: []Type) -> Type

// sequence: t computed on its parts, in normal form. The parts are computed in the
// order they are written: the first that has an effect is computed first, and t is
// in the effect it gives, or in each branch of the pattern its effect is in. A pure
// part crosses the effect. On pure parts, the law of t applies.
sequence :: proc(k: ^Kernel, t: Type, parts: []Type, law: Law) -> Type {
	for part in parts do if is_invalid(part) do return part
	for part, i in parts {
		#partial switch v in part {
		case ^Effect:
			rest := slice.clone(parts)
			rest[i] = v.then
			if v.write != nil do return writing(k, v, sequence(k, t, rest, law))
			return wrapped(v, v.answer, sequence(k, t, rest, law))
		case ^Pattern:
			if !has_effect(v) do continue
			// a choice whose branches have effects is an effect: what follows crosses
			// it, computed once, when it reads nothing they give back
			if chosen, crossed := choice(k, v, parts[i + 1:]); crossed {
				rest := slice.clone(parts)
				rest[i] = given(k, v)
				out := new(Effect)
				out.id, out.choice, out.span = -1, chosen, v.span
				out.then = sequence(k, t, rest, law)
				return out
			}
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

// choice: p, a pattern whose branches have effects, as an effect, when effects come
// after it — what follows would be computed in each branch — and what it gives back
// holds none of the answers its branches bind: the effects of a branch stay in it,
// what follows comes once.
choice :: proc(k: ^Kernel, p: ^Pattern, after: []Type) -> (Type, bool) {
	// what follows a write reads what it wrote, and an emission not answered yet may
	// write once it is: what follows is computed in each branch
	if has_write(p) do return nil, false
	later := false
	for x in after do later ||= has_effect(x)
	if !later do return nil, false
	answers := make([dynamic]^Unknown)
	bound(p, &answers)
	pure := given(k, p)
	for u in answers do if reads(k, pure, u) do return nil, false
	return p, true
}

// bound: the answers the effects of t bind, in its branches too.
bound :: proc(t: Type, out: ^[dynamic]^Unknown) {
	#partial switch v in t {
	case ^Effect:
		if v.answer != nil do append(out, v.answer)
		if v.choice != nil do bound(v.choice, out)
		bound(v.then, out)
	case ^Pattern:
		for b in v.branches do bound(b.product, out)
	}
}

// given: what t gives back, its effects left where they are run: what a name reads.
given :: proc(k: ^Kernel, t: Type) -> Type {
	#partial switch v in t {
	case ^Effect:
		return given(k, v.then)
	case ^Pattern:
		if !has_effect(v) do return t
		branches := make([]Branch, len(v.branches))
		for b, j in v.branches do branches[j] = Branch{cover = b.cover, product = given(k, b.product), span = b.span}
		return pattern_law(k, branching(v, branches))
	}
	return t
}

// renewed: t, each of its effects with a new answer, but those new already; run maps
// each answer as written to the new one. What one run gives back is not what
// another gives back.
renewed :: proc(k: ^Kernel, t: Type, run: ^Rewrite) -> Type {
	#partial switch v in t {
	case ^Effect:
		if v.write != nil && len(v.write.versions) > 0 && !is_new(run^, v.write.versions[0].at) {
			// each run reads the places where its own writes are
			w := new(Write)
			w^ = v.write^
			versions := make([]Version, len(v.write.versions))
			fresh: Rewrite
			for ver, i in v.write.versions {
				x := new(Unknown)
				x^ = ver.at^
				x.id = k.unknowns
				k.unknowns += 1
				run^ = rewriting(run^, ver.at, x)
				fresh = rewriting(fresh, ver.at, x)
				versions[i] = Version{place = ver.place, at = x}
			}
			w.versions, w.value = versions, rewrite(k, v.write.value, fresh)
			out := new(Effect)
			out^ = v^
			out.write = w
			out.then = renewed(k, rewrite(k, v.then, fresh), run)
			return out
		}
		if v.choice != nil {
			out := new(Effect)
			out^ = v^
			out.choice = renewed(k, v.choice, run)
			out.then = renewed(k, rewrite(k, v.then, run^), run)
			return out
		}
		if v.answer == nil || is_new(run^, v.answer) do return wrapped(v, v.answer, renewed(k, v.then, run))
		x := new(Unknown)
		x^ = v.answer^
		x.id = k.unknowns
		k.unknowns += 1
		run^ = rewriting(run^, v.answer, x)
		return wrapped(v, x, renewed(k, rewrite(k, v.then, rewriting(nil, v.answer, x)), run))
	case ^Pattern:
		if !has_effect(v) do return t
		branches := make([]Branch, len(v.branches))
		for b, j in v.branches do branches[j] = Branch{cover = b.cover, product = renewed(k, b.product, run), span = b.span}
		return pattern_law(k, branching(v, branches))
	}
	return t
}

// is_new: u is an answer the run gave.
is_new :: proc(run: Rewrite, u: ^Unknown) -> bool {
	for x in run do if same_unknown(x.term.(^Unknown), u) do return true
	return false
}

// in_run: t, a part of a run, after the effects before it: what it reads of their
// answers is what they gave in this run, then its own effects give new ones.
in_run :: proc(k: ^Kernel, t: Type, run: ^Rewrite) -> Type {
	return renewed(k, rewrite(k, t, run^), run)
}

// branching: the pattern p, with these branches.
branching :: proc(p: ^Pattern, branches: []Branch) -> ^Pattern {
	out := new(Pattern)
	out.target, out.branches, out.span = p.target, branches, p.span
	return out
}

// ran: the effects of the bindings of s above its production p — nil: the default one,
// below every binding —, in the order they are written, joined to parts (§4.8); a
// handler is not run, it answers (§4.9). An
// expansion is computed where it is written, then the bindings it places are.
// Another production is not run; what is below p is not reached, like code after a
// return. True when p is reached, placed by an expansion.
//
// For a run, run is not nil: each effect gives back a new answer, which the effects
// after it read, and changes carves each binding of s that has one to what it gives
// back — an expansion to a copy of what it places, carved likewise —, so that what
// reads it reads that answer.
ran :: proc(k: ^Kernel, s: ^Scope, p: ^Binding, parts: ^[dynamic]Type, run: ^Rewrite, changes: ^map[^Binding]Type) -> bool {
	for b in s.bindings {
		if b == p do return true
		switch b.kind {
		case .Product, .Handler:
		case .Expand:
			if b.value == nil && b.color == nil do continue
			t := binding_type(k, b)
			effectful := has_effect(t)
			if effectful {
				if run != nil do t = in_run(k, t, run)
				append(parts, t)
			}
			value := given(k, t)
			placing := make(map[^Binding]Type)
			reached := false
			if inner, is_scope := value.(^Scope); is_scope {
				reached = ran(k, inner, p, parts, run, &placing)
				if len(placing) > 0 do value = carved_copy(k, inner, placing)
			}
			if run != nil && (effectful || len(placing) > 0) do changes[b] = value
			if reached do return true
		case .Push, .Pull:
			if b.resonance != nil {
				// each run has a place of its own
				if run != nil do changes[b] = renewed_place(k, b, run)
				continue
			}
			t := binding_type(k, b)
			if !has_effect(t) do continue
			if run != nil {
				t = in_run(k, t, run)
				changes[b] = given(k, t)
			}
			append(parts, t)
		}
	}
	return false
}

// with_effects: v, what the production p of s gives — nil: the default production,
// none —, with the effects of the bindings above it, in the order they are written.
with_effects :: proc(k: ^Kernel, s: ^Scope, p: ^Binding, v: Type) -> Type {
	parts := make([dynamic]Type)
	ran(k, s, p, &parts, nil, nil)
	if len(parts) == 0 do return v
	append(&parts, v)
	return sequence(k, nil, parts[:], last_part)
}

// collapsed: s!, one run of s (§4.8): the effects of the bindings above its
// production, in the order they are written, then the production — or the default
// one, none. Each effect of the run gives back a new answer, which what reads its binding reads,
// and which a call takes as a value.
collapsed :: proc(k: ^Kernel, s: ^Scope, c: ^Collapse) -> Type {
	run: Rewrite
	parts := make([dynamic]Type)
	changes := make(map[^Binding]Type)
	p, _ := first_production(k, s)
	ran(k, s, p, &parts, &run, &changes)
	inner := len(changes) > 0 ? carved_copy(k, s, changes) : s
	product := product_of(k, inner, c)
	if _, behind := symbol_of(inner); behind do product = crossed(k, inner, c, product)
	product = in_run(k, product, &run)
	// a scope the run gives, with resonant bindings: their places are this run's
	if s, is_scope := product.(^Scope); is_scope do product = instance(k, s, &parts, &run)
	append(&parts, product)
	return freed(k, sequence(k, nil, parts[:], last_part), s.parent)
}

// freed: t, what a run gives, without the writes of the places that die with it:
// those not declared in the scope that outlives the run — keep, or a scope it is
// written in —, nor held by what the run gives (§4.12). What is left of them reads
// them no more. An emission not answered yet may read them once it is: they are
// kept.
freed :: proc(k: ^Kernel, t: Type, keep: ^Scope) -> Type {
	if awaits(t) do return t
	places := make([dynamic]^Unknown)
	written_places(t, &places)
	out := t
	for place in places {
		declared := place.place.scope
		if keep != nil && declared != nil && written_in(keep, declared) do continue
		if !reads(k, given(k, out), place) do out = unwritten(out, place)
	}
	return out
}

// written_places: the places t writes, each once.
written_places :: proc(t: Type, out: ^[dynamic]^Unknown) {
	#partial switch v in t {
	case ^Effect:
		if v.write != nil && v.write.place != nil {
			known := false
			for p in out do known ||= same_unknown(p, v.write.place)
			if !known do append(out, v.write.place)
		}
		if v.choice != nil do written_places(v.choice, out)
		written_places(v.then, out)
	case ^Pattern:
		for b in v.branches do written_places(b.product, out)
	}
}

// unwritten: t without the writes of the place.
unwritten :: proc(t: Type, place: ^Unknown) -> Type {
	#partial switch v in t {
	case ^Effect:
		if v.write != nil && v.write.place != nil && same_unknown(v.write.place, place) do return unwritten(v.then, place)
		then := unwritten(v.then, place)
		choice := v.choice != nil ? unwritten(v.choice, place) : nil
		if then == v.then && choice == v.choice do return t
		out := new(Effect)
		out^ = v^
		out.then, out.choice = then, choice
		return out
	case ^Pattern:
		branches := make([]Branch, len(v.branches))
		moved := false
		for b, j in v.branches {
			branches[j] = Branch{cover = b.cover, product = unwritten(b.product, place), span = b.span}
			moved ||= branches[j].product != b.product
		}
		if !moved do return t
		return branching(v, branches)
	}
	return t
}

// awaits: t holds an emission not answered yet.
awaits :: proc(t: Type) -> bool {
	#partial switch v in t {
	case ^Effect:
		return v.emission != nil || v.choice != nil && awaits(v.choice) || awaits(v.then)
	case ^Pattern:
		for b in v.branches do if awaits(b.product) do return true
	}
	return false
}

last_part :: proc(k: ^Kernel, t: Type, parts: []Type) -> Type {
	return parts[len(parts) - 1]
}

// --- writes (specs/types.md §4.14) ---
//
// `x -<< v`: the resonant binding x takes v. What reads x after it reads v:
//
//   ω(x := v, t)   =   ω(x := v, t[x ↦ v])
//
// up to the first emission not answered yet: its handler may write x, so what
// follows it is read once it is answered (answer_in). What v reads of a place p is
// p where the write is, an unknown of its own, its version p@: the write of p
// before it gives p@ its value. So each read is replaced once, by the write it
// follows, and a read never crosses a write of its place. A binding that reads
// places is a pin: a write without place, which only reads them where it is.
// A write is held where it is written, ordered like the effects; nothing reads
// what it gives back.

// write_law: `x -<< v` as written: x a resonant binding, v in its color, computed
// first — its effects before the write.
write_law :: proc(k: ^Kernel, e: ^Effect) -> Type {
	return sequence(k, e, {normal(k, e.write.target), normal(k, e.write.value)}, write_parts)
}

write_parts :: proc(k: ^Kernel, t: Type, parts: []Type) -> Type {
	e := t.(^Effect)
	place, is_place := parts[0].(^Unknown)
	if !is_place || place.place == nil || place.before {
		return problem(.Invalid_Write, e.span, fmt.tprintf("`-<<` writes a resonant binding, not %s", print_type(parts[0])))
	}
	if place.written != nil {
		if p := in_problem(k, parts[1], layout_of(k, place), e.span); p != nil do return p
	}
	w := new(Write)
	w^ = Write{target = e.write.target, place = place, value = parts[1]}
	out := new(Effect)
	out^ = e^
	out.write = w
	return writing(k, out, normal(k, e.then))
}

// pinned: t, the value of the binding b, which reads places: a pin, where b is
// written, what reads b reading them there.
pinned :: proc(k: ^Kernel, t: Type, span: syn.Span) -> Type {
	w := new(Write)
	w.value = t
	e := new(Effect)
	e^ = Effect{id = -1, write = w, span = span}
	return writing(k, e, t)
}

// reads_places: t reads a place, the values a scope it gives was built with
// included.
reads_places :: proc(t: Type) -> bool {
	seen := make([dynamic]^Unknown)
	read_places(t, &seen)
	return len(seen) > 0
}

// read_places: the places t reads, each once: in the changes of a scope too, the
// values it was built with.
read_places :: proc(t: Type, out: ^[dynamic]^Unknown) {
	if s, is_scope := t.(^Scope); is_scope {
		for _, v in s.changes do read_places(v, out)
		return
	}
	seen := make([dynamic]^Unknown)
	read_unknowns(t, &seen)
	for u in seen {
		if u.place == nil || u.before do continue
		known := false
		for p in out do known ||= same_unknown(p, u)
		if !known do append(out, u)
	}
}

// built: t, a value built where it is: a scope reads the places its bindings read
// there — each is changed to what it reads, as a carve would.
built :: proc(k: ^Kernel, t: Type) -> Type {
	s, is_scope := t.(^Scope)
	if !is_scope do return t
	changes := make(map[^Binding]Type)
	for b in s.bindings {
		if b.kind != .Push && b.kind != .Expand || b.resonance != nil || b.value == nil do continue
		v := binding_type(k, b)
		if !has_effect(v) && reads_places(v) do changes[b] = v
	}
	if len(changes) == 0 do return t
	return carved_copy(k, s, changes)
}

// writing: the write e, wrapping t: what its value reads of places, read where it
// is; what follows reading what it wrote. A pin all of whose reads are given is
// what it wraps.
writing :: proc(k: ^Kernel, e: ^Effect, t: Type) -> Type {
	w := new(Write)
	w^ = e.write^
	w.value = built(k, w.value)
	then := t
	// each place the value reads, a version of its own
	seen := make([dynamic]^Unknown)
	read_places(w.value, &seen)
	versions := make([dynamic]Version)
	append(&versions, ..w.versions)
	for u in seen {
		at := new(Unknown)
		at^ = u^
		at.id, at.before = k.unknowns, true
		k.unknowns += 1
		append(&versions, Version{place = u, at = at})
		r := rewriting(nil, u, at)
		w.value = rewrite(k, w.value, r)
		if w.place == nil do then = rewrite(k, then, r) // a pin: what it wraps reads them there too
	}
	w.versions = versions[:]
	if w.place != nil do then = after_write(k, then, w.place, w.value)
	else if !pin_reads(k, w, then) do return then
	out := new(Effect)
	out^ = e^
	out.answer, out.write, out.then = nil, w, then
	return out
}

// pin_reads: the pin w still reads a place where it is: one of its versions is not
// given yet.
pin_reads :: proc(k: ^Kernel, w: ^Write, then: Type) -> bool {
	for v in w.versions do if reads(k, then, v.at) do return true
	return false
}

// after_write: t, what follows a write of the place to v: its reads are v, up to an
// emission not answered yet — what it sends is computed before it. A later write:
// its version of the place is v; what follows a later write of the place reads it.
after_write :: proc(k: ^Kernel, t: Type, place: ^Unknown, v: Type) -> Type {
	reads := rewriting(nil, place, v)
	#partial switch x in t {
	case ^Effect:
		if x.write != nil {
			w := new(Write)
			w^ = x.write^
			out := new(Effect)
			out^ = x^
			out.write = w
			// its version of the place, where it is, is v
			given_versions := reads
			kept := make([dynamic]Version)
			for ver in x.write.versions {
				if same_unknown(ver.place, place) do given_versions = rewriting(given_versions, ver.at, v)
				else do append(&kept, ver)
			}
			w.versions = kept[:]

			w.value = rewrite(k, x.write.value, given_versions)
			if w.place != nil && same_unknown(w.place, place) {
				out.then = rewrite(k, x.then, given_versions[1:])
				return out
			}
			out.then = after_write(k, rewrite(k, x.then, given_versions[1:]), place, v)
			if w.place == nil && !pin_reads(k, w, out.then) do return out.then
			return out
		}
		if x.emission != nil {
			sent := rewrite(k, x.emission.sent, reads)
			if sent == x.emission.sent do return t
			m := new(Emission)
			m^ = x.emission^
			m.sent = sent
			out := new(Effect)
			out^ = x^
			out.emission = m
			return out
		}
		// another effect: what it computes on, then what follows it
		out := new(Effect)
		out^ = x^
		if x.call != nil do out.call = rewrite_call(k, x.call, reads)
		if x.fold != nil do out.fold = rewrite_fold(k, x.fold, reads)
		if x.choice != nil do out.choice = after_write(k, x.choice, place, v)
		out.then = after_write(k, x.then, place, v)
		return out
	case ^Pattern:
		branches := make([]Branch, len(x.branches))
		for b, j in x.branches do branches[j] = Branch{cover = b.cover, product = after_write(k, b.product, place, v), span = b.span}
		p := new(Pattern)
		p^ = Pattern{target = rewrite(k, x.target, reads), branches = branches, span = x.span}
		return pattern_law(k, p)
	}
	return rewrite(k, t, reads)
}

// has_write: t holds a write where it is computed, or an emission not answered
// yet, whose handler may write.
has_write :: proc(t: Type) -> bool {
	#partial switch v in t {
	case ^Effect:
		return v.write != nil || v.emission != nil || v.choice != nil && has_write(v.choice) || has_write(v.then)
	case ^Pattern:
		for b in v.branches do if has_write(b.product) do return true
	}
	return false
}

// renewed_place: the place of the resonant binding b in a run: a new one, which
// what the run reads of b reads.
renewed_place :: proc(k: ^Kernel, b: ^Binding, run: ^Rewrite) -> ^Unknown {
	place := binding_type(k, b).(^Unknown)
	x := new(Unknown)
	x^ = place^
	x.id = k.unknowns
	k.unknowns += 1
	run^ = rewriting(run^, place, x)
	return x
}

// instance: s, a scope a run gives: each of its resonant bindings with a place of
// this run, which starts with its first write, joined to parts (§4.14).
instance :: proc(k: ^Kernel, s: ^Scope, parts: ^[dynamic]Type, run: ^Rewrite) -> Type {
	changes := make(map[^Binding]Type)
	for b in s.bindings do if b.resonance != nil do changes[b] = renewed_place(k, b, run)
	if len(changes) == 0 do return s
	// what the run gives holds them: they live on
	for b in s.bindings {
		if b.kind != .Push || b.resonance != nil do continue
		t := binding_type(k, b)
		if has_write(t) do append(parts, in_run(k, t, run))
	}
	return carved_copy(k, s, changes)
}
