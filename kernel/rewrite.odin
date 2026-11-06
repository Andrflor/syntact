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

// reads: t holds the unknown u: rewriting u changes it.
reads :: proc(k: ^Kernel, t: Type, u: ^Unknown) -> bool {
	#partial switch _ in t {
	case nil, Char, Int, Real, Bool, None, Invalid:
		return false
	}
	// a node is never changed once built: what it reads, asked once
	node := t
	key := Read_Key{node = (^rawptr)(&node)^, unknown = u.id}
	if known, found := k.read[key]; found do return known
	read := !same(k, rewrite(k, t, rewriting(nil, u, new_unknown(k, nil))), t)
	k.read[key] = read
	return read
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
		return rewrite_call(k, v, r)
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
		out := with_parts(v, rewritten)
		out.index, out.states = index, states
		return fold_law(k, out)
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
		// a new target: the pattern on it, each product rewritten in its branch (§6)
		if target := rewrite(k, v.target, r); target != v.target do return as_normal(pattern_on(k, target, v, r))
		p := new(Pattern)
		p.target, p.span = v.target, v.span
		p.branches = make([]Branch, len(v.branches))
		moved := false
		for b, i in v.branches {
			p.branches[i] = with_product(b, rewrite(k, b.product, r))
			moved ||= p.branches[i].product != b.product
		}
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

// bound_as: an unknown bound in a term — an index, a state — as r rewrites it: as
// its occurrences are, renamed or its layout rewritten.
bound_as :: proc(k: ^Kernel, r: Rewrite, u: ^Unknown) -> (^Unknown, bool) {
	if w, is_unknown := rewrite(k, u, r).(^Unknown); is_unknown && w != u do return w, true
	return u, false
}

// renamed: t, each unknown bound in it — the index and the states of a fold, the
// index of a Σ or a μ — another of the same layout: the same term, its bound
// unknowns its own.
renamed :: proc(k: ^Kernel, t: Type) -> Type {
	bound := make([dynamic]^Unknown)
	visit :: proc(t: Type, out: ^[dynamic]^Unknown) {
		#partial switch v in t {
		case ^Fold:
			append(out, v.index)
			append(out, ..v.states)
			for p in fold_parts(v) do visit(p, out)
		case ^Series:
			append(out, v.index)
			visit(v.lo, out)
			visit(v.hi, out)
			visit(v.term, out)
		case ^Least:
			append(out, v.index)
			visit(v.holds, out)
		case ^Pattern:
			visit(v.target, out)
			for b in v.branches do visit(b.product, out)
		case ^Effect:
			visit(v.then, out)
			if v.choice != nil do visit(v.choice, out)
		case ^Scope, ^Collapse:
		case:
			for p in parts(t) do visit(p, out)
		}
	}
	visit(t, &bound)
	if len(bound) == 0 do return t
	r: Rewrite
	for u in bound {
		fresh := new(Unknown)
		fresh^ = u^
		fresh.id = k.unknowns
		k.unknowns += 1
		r = rewriting(r, u, fresh)
	}
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
	// what a recursive call gives back: a value of the family it is proven in
	if u.call != nil do if f, known := call_family(k, u.call); known do return family_term(f)
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
		// computed once; holding calls, once for what is being given
		known, plain := plain_of(k, v)
		if plain && known.imaged do return known.image, known.image != nil
		key := Image_Key{v, k.state}
		if !plain do if x, found := k.images_in[key]; found do return x.image, x.ok
		args := make([]Type, len(v.args))
		image: Type
		computed := true
		// the images of its operands: sets of constants, or not given
		for a, i in v.args {
			args[i], computed = layout_image(k, a)
			computed &&= is_constant(args[i])
			if !computed do break
		}
		if computed {
			// the term computes exactly: only a rounding rounds (format.odin)
			if v.op == .Round do image = round_law(k, args[0], bits_format(args[1]), v.span)
			else do image = euclid_image(k, t, related_image(k, t, exact_law(k, v.op, args, v.span)))
		}
		if plain {
			known, _ = plain_of(k, v)
			known.imaged, known.image = true, image
			remember_plain(k, v, known)
		} else if key.state == k.state {
			k.images_in[key] = {image, image != nil}
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
			// a set the laws keep written, u8 % 3: the range that bounds it
			if _, written := set.(^Operation); written do set = int_hull(k, set)
			append(&terms, set)
		}
		if len(terms) == 0 do return nil, false
		return and_law(k, terms[:]), true
	case ^Not:
		return not_law(k, layout_image(k, v.term) or_return), true
	case ^Is:
		return is_law(layout_image(k, v.term) or_return), true
	case ^Range:
		if is_constant(t) do return t, true
		// what it may hold: from the least of its lower bound to the greatest of its upper
		return outer_set(k, t)
	case ^Collapse:
		// a call that stays: bounded by the recursion of its bounds (§5.6); giving
		// scopes, the scope of its equation, read as a color (§5.4); otherwise the
		// family it is proven in
		if image, known := call_image(k, v); known do return image, true
		f := family_of(k, v) or_return
		if f == .Scope do if eq, read := equation_of(k, v); read do return eq.generic, true
		return family_term(f), true
	case ^Fold, ^Least, ^Series:
		// computed once when the term alone gives it; holding calls, once for what is
		// being given (given_changed): their images read it
		known, plain := plain_of(k, t)
		if plain && known.imaged do return known.image, known.image != nil
		node, _ := plain_node(t)
		key := Image_Key{node, k.state}
		if !plain do if x, found := k.images_in[key]; found do return x.image, x.ok
		image, imaged := ordered_image(k, t)
		if plain {
			known.imaged = true
			if imaged do known.image = image
			remember_plain(k, t, known)
		} else if key.state == k.state {
			k.images_in[key] = {image, imaged}
		}
		return image, imaged
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

// ordered_image: the image of a fold, a μ or a series, by the order of the integers
// along it.
ordered_image :: proc(k: ^Kernel, t: Type) -> (out: Type, ok: bool) {
	#partial switch v in t {
	case ^Fold:
		// a sum along the fold: its init, and as many terms as steps
		if image, known := sum_image(k, v); known do return image, true
		// a run it builds: a run of what its steps place
		if image, known := built_image(k, v); known do return image, true
		// its value, over the layouts of its states
		if image, known := layout_image(k, v.value); known do return image, true
		if f, known := family_of(k, v); known do return family_term(f), true
	case ^Least:
		if image, known := least_image(k, v); known do return image, true
		return COUNTS, true
	case ^Series:
		if v.op == .Add {
			// Σ(a + b) = Σa + Σb
			if o, sums := v.term.(^Operation); sums && o.op == .Add {
				total: Type = Int(0)
				split := true
				for part in o.args {
					image, known := layout_image(k, series(k, .Add, v.index, v.lo, v.hi, part))
					if !known {
						split = false
						break
					}
					total = exact_law(k, .Add, {total, image}, v.span)
				}
				if split do return total, true
			}
			// Σ(x: 0..|X| - 1, g(X.#x)), X a call: what bounds that sum of the call (§5.6)
			if image, known := summed_image(k, v); known do return image, true
			term := rewrite(k, v.term, rewriting(nil, v.index, narrowing(v.index, range_law(k, v.lo, v.hi, .Int, v.span))))
			if image, known := hull_times(k, op(k, .Add, op(k, .Sub, v.hi, v.lo), Int(1)), term); known do return image, true
		}
		if f, known := family_of(k, t); known do return family_term(f), true
	}
	return nil, false
}

// Image_Key: a term holding calls, in a state of what is being given.
Image_Key :: struct {
	node:  rawptr,
	state: int,
}

Image_Known :: struct {
	image: Type,
	ok:    bool,
}

// Plain: what is known of a term over plain terms — constants, unknowns that no call
// gives, operations, folds, μ and series over them —, which depends on nothing but
// the term: its image and its family, each computed once.
Plain :: struct {
	plain, imaged, typed: bool,
	image:                Type,
	family:               Maybe(Family),
}

// plain_node: the node of a term whose image is known by the term alone.
plain_node :: proc(t: Type) -> (node: rawptr, ok: bool) {
	#partial switch v in t {
	case ^Operation:
		return v, true
	case ^Fold:
		return v, true
	case ^Least:
		return v, true
	case ^Series:
		return v, true
	}
	return nil, false
}

// plain_of: what is known of t, and whether t is plain — found once.
plain_of :: proc(k: ^Kernel, t: Type) -> (Plain, bool) {
	node, has := plain_node(t)
	if !has do return {}, false
	if entry, found := k.plain[node]; found do return entry, entry.plain
	is_plain :: proc(k: ^Kernel, t: Type) -> bool {
		#partial switch v in t {
		case Int, Real, Char, Bool, None:
			return true
		case ^Unknown:
			return v.call == nil
		case ^Operation, ^Fold, ^Least, ^Series:
			_, plain := plain_of(k, t)
			return plain
		}
		return t == nil
	}
	entry := Plain{plain = true}
	#partial switch v in t {
	case ^Operation:
		for a in v.args do entry.plain &&= is_plain(k, a)
	case ^Fold:
		for a in fold_parts(v) do entry.plain &&= is_plain(k, a)
	case ^Least:
		entry.plain = is_plain(k, v.holds)
	case ^Series:
		entry.plain = is_plain(k, v.lo) && is_plain(k, v.hi) && is_plain(k, v.term)
	}
	k.plain[node] = entry
	return entry, entry.plain
}

// remember_plain: what is known of a plain term, from now on.
remember_plain :: proc(k: ^Kernel, t: Type, entry: Plain) {
	node, _ := plain_node(t)
	k.plain[node] = entry
}

// int_hull: the integers from the least to the greatest of a constant set of
// integers, one range: what bounds it, as a set the laws compute on.
int_hull :: proc(k: ^Kernel, t: Type) -> Type {
	lo, hi, ok := int_bounds(k, t)
	if !ok do return t
	return discrete_cell(.Int, lo, hi)
}

// one_affine: t = a·u + b, u its one unknown, a = ±1.
one_affine :: proc(k: ^Kernel, t: Type) -> (u: ^Unknown, a: i128, b: Type, ok: bool) {
	read := make([dynamic]^Unknown)
	read_unknowns(t, &read)
	if len(read) != 1 do return
	alpha, beta := affine_in(k, t, read[0]) or_return
	one := alpha.(Int) or_return
	if one != 1 && one != -1 do return
	return read[0], i128(one), beta, true
}

// euclid_image: n = c·(n / c) + n % c, for n ≥ 0 and c > 0 constant: a term that reads
// n / c is read on q = n / c and r = n % c, unknowns of their own, n being c·q + r —
// the image keeps what relates n and n / c. image is the image of the term as it is.
euclid_image :: proc(k: ^Kernel, t: Type, image: Type) -> Type {
	if !is_constant(image) do return image
	quotients := make([dynamic]^Operation)
	visit :: proc(t: Type, out: ^[dynamic]^Operation) {
		o, is_op := t.(^Operation)
		if !is_op do return
		if o.op == .Div && len(o.args) == 2 {
			if c, constant := o.args[1].(Int); constant && c > 0 do append(out, o)
		}
		for a in o.args do visit(a, out)
	}
	visit(t, &quotients)
	out := image
	for d in quotients {
		if Type(d) == t do continue // n / c itself: nothing beside it to relate
		n := d.args[0]
		c := d.args[1].(Int)
		at_least, _ := term_bound(k, n, true)
		if low, known := at_least.(Int); !known || low < 0 do continue
		q, r := new_unknown(k, nil), new_unknown(k, nil)
		q.layout = layout_image(k, d) or_continue
		r.layout = range_law(k, Int(0), Int(c - 1), .Int, {})
		whole := op(k, .Add, op(k, .Mul, c, q), r)
		reading := append_read(nil, d, q)
		if u, is_unknown := n.(^Unknown); is_unknown {
			reading = rewriting(reading, u, whole)
		} else if u, a, b, affine := one_affine(k, n); affine {
			// n = a·u + b, a = ±1: u = a·(c·q + r - b), wherever t reads it
			reading = rewriting(reading, u, op(k, .Mul, Int(a), op(k, .Sub, whole, b)))
		} else if o, is_op := n.(^Operation); is_op {
			reading = append_read(reading, o, whole)
		} else do continue
		read := layout_image(k, rewrite(k, t, reading)) or_continue
		if is_constant(read) do out = and_law(k, {int_hull(k, out), int_hull(k, read)})
	}
	return out
}

// related_image: the image of a term of degree 1 in an unknown narrowed between
// bounds over other unknowns, u::(L & l..h): a·u + r lies between a·l + r and
// a·h + r, each a term over the others — the image keeps what relates them.
// image is the image of the term, each unknown replaced by its layout on its own.
related_image :: proc(k: ^Kernel, term: Type, image: Type) -> Type {
	if !is_constant(image) do return image
	t, _ := runs_read(k, term)
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
			// each side on its own: a side without extremity leaves it open
			least, most: Type
			if lo != nil do least, _ = term_bound(k, op(k, .Add, op(k, .Mul, alpha, lo), r), true)
			if hi != nil do most, _ = term_bound(k, op(k, .Add, op(k, .Mul, alpha, hi), r), false)
			if least == nil && most == nil do continue
			out = and_law(k, {int_hull(k, out), range_law(k, least, most, .Int, {})})
		}
	}
	return out
}

// runs_read: t, each binding of a run it reads, x.#k, an unknown of what the run's
// layout says it holds, when that is over unknowns: the bindings relate as unknowns do.
runs_read :: proc(k: ^Kernel, t: Type) -> (out: Type, changed: bool) {
	o, is_operation := t.(^Operation)
	if !is_operation do return t, false
	if reads_run(o.op) {
		image, known := run_image(k, o)
		if !known || is_constant(image) do return t, false
		u := new_unknown(k, nil)
		u.layout = image
		return u, true
	}
	args := make([]Type, len(o.args))
	for a, i in o.args {
		read: bool
		args[i], read = runs_read(k, a)
		changed ||= read
	}
	if !changed do return t, false
	return operation_law(k, o.op, args, o.span), true
}

// built_image: the run a fold builds, {e₀ … eₙ₋₁}: the shape {...{E:} * 0..},
// E the values its steps place.
built_image :: proc(k: ^Kernel, f: ^Fold) -> (image: Type, ok: bool) {
	_, es, builds := built(k, f)
	if !builds do return
	values_of := make([]Type, len(es))
	for e, i in es do values_of[i] = values(k, given(k, e)) or_return
	piece := new_scope(nil, f.span)
	piece.source, piece.complete, piece.reached = piece, true, true
	place := new_binding(piece, .Push, f.span)
	// what a binding may hold: a set the laws keep written, by the range that bounds it
	place.color = or_law(k, values_of)
	if _, written := place.color.(^Operation); written do place.color = int_hull(k, place.color)
	place.typed_color = place.color
	return repeated(k, piece, COUNTS, f.span), true
}

// sum_image: the values of a fold whose value is a state x: c ↦ x + g, g not
// reading x: c, and n terms of g, n its steps.
sum_image :: proc(k: ^Kernel, f: ^Fold) -> (image: Type, ok: bool) {
	// the steps: along a counter, from lo to hi; otherwise the length of the orbit of
	// the index from its start (§5.6), the index where its layout says
	steps: Type
	along: Rewrite
	if lo, hi, counter := counter_range(k, f); counter {
		steps = op(k, .Add, op(k, .Sub, hi, lo), Int(1))
		along = rewriting(nil, f.index, narrowing(f.index, range_law(k, lo, hi, .Int, f.span)))
	} else {
		// the orbit of the start: its points from what the start may be
		start := new_unknown(k, nil)
		start.layout = layout_image(k, f.start) or_return
		n := orbit_length(k, start, rewrite(k, f.next, rewriting(nil, f.index, start)), f.stop, f.span) or_return
		steps = rewrite(k, n, rewriting(nil, start, f.start))
	}
	for z, i in f.states {
		if !same(k, f.value, z) do continue
		// x ↦ x + g: the ring reads the update as 1·x + g
		one, g := affine_in(k, f.updates[i], z) or_return
		if !is_int(one, 1) do return
		terms := hull_times(k, steps, rewrite(k, g, along)) or_return
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
		// the scope of an equation, read as a color (§5.4): reading it is reading the
		// equation — its calls the hypothesis meanwhile (§5.6) —, once
		for x in k.equations {
			if x.generic != s do continue
			for f in k.fields do if f.scope == s && f.name == name do return f.color, f.color != nil
			if reading(k, x.root) do return nil, false
			x.read = true
			given_changed(k)
			color, ok = produced_field(k, s, name)
			x.read = false
			given_changed(k)
			append(&k.fields, Field{s, name, ok ? color : nil})
			given_changed(k)
			return
		}
		return produced_field(k, s, name)
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

// summed_image: Σ(x: 0..|X| - 1, g(X.#x)), X a recursive call, its terms reading X
// only at x: the bounds of that sum of what the call gives (§5.6).
summed_image :: proc(k: ^Kernel, v: ^Series) -> (image: Type, ok: bool) {
	if !is_int(v.lo, 0) do return
	reads_at :: proc(t: Type, i: ^Unknown, out: ^[dynamic]^Collapse) {
		if o, is_op := t.(^Operation); is_op && o.op == .Item {
			if c, is_call := as_call(o.args[0]); is_call do if u, at := o.args[1].(^Unknown); at && same_unknown(u, i) do append(out, c)
		}
		for p in parts(t) do reads_at(p, i, out)
	}
	calls := make([dynamic]^Collapse)
	reads_at(v.term, v.index, &calls)
	for c in calls {
		if !same(k, v.hi, op(k, .Sub, run_law(k, .Length, {c}, v.span), Int(1))) do continue
		// at: a binding of X, what X holds at a place
		item := new_operation(.Item, c, v.index)
		at := new_unknown(k, nil)
		at.layout = layout_image(k, item) or_continue
		g := rewrite(k, v.term, append_read(nil, item, at))
		if holds_invalid(g) do continue
		if reads(k, g, v.index) do continue
		return call_image(k, c, Measure{.Sum, g, at})
	}
	return
}

// least_image: μ(i: m / c ** i in B), B holding 0: the orbit reaches 0, the later the
// greater |m| — at most the count of the digits of |m| in base c, at its bound.
least_image :: proc(k: ^Kernel, l: ^Least) -> (image: Type, ok: bool) {
	holds := l.holds.(^Operation) or_return
	if holds.op != .In || !is_bool(in_law(k, Int(0), holds.args[1]), true) do return
	div := holds.args[0].(^Operation) or_return
	if div.op != .Div do return
	power := div.args[1].(^Operation) or_return
	if power.op != .Pow do return
	c := power.args[0].(Int) or_return
	at, by_index := power.args[1].(^Unknown)
	if !by_index || !same_unknown(at, l.index) || c < 2 || reads(k, div.args[0], l.index) do return
	lo, hi := int_bounds(k, layout_image(k, div.args[0]) or_return) or_return
	// / rounds toward 0 (§4.5): |m / c ** i| = |m| / c ** i
	least, top := lo.? or_return, hi.? or_return
	if least == min(i128) do return
	top = max(top, -least)
	digits: i128 = 0
	for x := top; x > 0; x /= i128(c) do digits += 1
	return range_law(k, Int(0), Int(digits), .Int, l.span), true
}
