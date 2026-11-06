package kernel

import syn "../syntax"
import "core:slice"

// THE EQUATION OF A RECURSION, AND ITS SOLUTION (specs/types.md §5.6)
//
// A recursive scope is an equation: its first production, where each field its calls
// carve is an unknown of its color. It is one per scope, read once. Its solution is
// its normal form under the laws below, each a local equality that composes with the
// others and with every law of the algebra:
//
//   a pattern takes its first branch (§6): the branches that call nothing are the
//   bases, those that call the step, each a pattern of its branches;
//   a step that is the call itself, f(x) = f(s(x)), is a fold that moves the fields
//   until the bases take them: its value is the base where it stops;
//   a step that is the call composed with a map affine in what the call gives —
//   α·y + β in the ring, {...P ...y ...Q} in the runs — is the fold of the composed
//   maps (A, B) ∘ (α, β) = (A·α, B + A·β), ({...A ...P}, {...Q ...B});
//
// and the laws of folds then simplify the fold (fold.odin). What none of them
// reduces stays the equation: its calls are calls, which the program computes.

Recursion :: struct {
	root:     ^Scope,
	given:    []^Binding, // the fields the call that reads it carves, sorted by address
	generic:  ^Scope, // root where each field its calls carve is an unknown of its color
	term:     Type, // its first production there
	params:   map[^Binding]^Unknown,
	through:  map[^Binding]^Recursion, // a field given a call of another equation: that equation (§5.6)
	solution: Type, // the term without calls of root, when the laws give one
	reading:  bool, // being read: its calls are the hypothesis (§5.6)
}

// call_key: the fields a carve of root changes, sorted by address.
call_key :: proc(s: ^Scope) -> []^Binding {
	key := make([dynamic]^Binding)
	for b in s.changes do append(&key, b)
	slice.sort_by(key[:], proc(a, b: ^Binding) -> bool {return uintptr(a) < uintptr(b)})
	return key[:]
}

// equation_of: the equation a call of root carving the fields given reads (§5.6): its
// production where those fields, and those its calls carve, are unknowns of their
// colors; one for each root and fields given, read once; false while it is read, its
// calls then the hypothesis, and while the production of root is typed.
equation_of :: proc(k: ^Kernel, root: ^Scope, given: []^Binding, through: map[^Binding]^Recursion = nil) -> (eq: ^Recursion, ok: bool) {
	for x in k.equations do if x.root == root && x.reading do return nil, false
	same_through :: proc(a, b: map[^Binding]^Recursion) -> bool {
		if len(a) != len(b) do return false
		for f, e in a do if b[f] != e do return false
		return true
	}
	for x in k.equations do if x.root == root && slice.equal(x.given, given) && same_through(x.through, through) do return x, true
	if p, found := first_production(k, root); found && p.state == .In_Progress do return nil, false
	return equation_built(k, root, given, through), true
}

// equation_found: the equation of root for those fields when it is built, read or
// not: what an induction proves on (§5.6).
equation_found :: proc(k: ^Kernel, root: ^Scope, given: []^Binding, through: map[^Binding]^Recursion) -> (^Recursion, bool) {
	for x in k.equations {
		if x.root != root || !slice.equal(x.given, given) || len(x.through) != len(through) do continue
		same := true
		for f, e in through do same &&= x.through[f] == e
		if same && x.term != nil do return x, true
	}
	return nil, false
}

// called: the call a carve gives, also where a branch narrows it: t & S is t where it
// is in S (§4.2).
called :: proc(v: Type) -> (^Collapse, bool) {
	if c, is_call := v.(^Collapse); is_call && c.recursive do return c, true
	if meet, narrowed := v.(^And); narrowed do for t in meet.terms do if c, is_call := t.(^Collapse); is_call && c.recursive do return c, true
	return nil, false
}

// through_of: the fields a carve gives a call of another equation, with that
// equation: the recursion follows what the other builds (§5.6).
through_of :: proc(k: ^Kernel, s: ^Scope) -> map[^Binding]^Recursion {
	out := make(map[^Binding]^Recursion)
	for b, v in s.changes {
		c := called(v) or_continue
		t, is_scope := c.target.(^Scope)
		if !is_scope || origin(t) == origin(s) do continue
		if eq, read := equation_of(k, origin(t), call_key(t)); read && eq.term != nil do out[b] = eq
	}
	return out
}

// equation_built: the equation of root for the fields given, built.
equation_built :: proc(k: ^Kernel, root: ^Scope, given: []^Binding, through: map[^Binding]^Recursion = nil) -> ^Recursion {
	eq := new(Recursion)
	eq.root, eq.given, eq.through, eq.reading = root, slice.clone(given), through, true
	append(&k.equations, eq)
	defer eq.reading = false
	carved := make(map[^Binding]bool)
	for b in given do carved[b] = true
	for {
		params := make(map[^Binding]^Unknown)
		changes := make(map[^Binding]Type)
		for b in carved {
			if other, kept := through[b]; kept {
				// a call of the other equation, over its own fields
				c := new(Collapse)
				c.target, c.recursive, c.span = other.generic, true, root.span
				changes[b] = c
				continue
			}
			u := new_unknown(k, nil)
			u.layout = binding_color(k, b)
			if u.layout == nil {
				f, known := family_of(k, binding_type(k, b))
				u.layout = known ? family_term(f) : everything()
			}
			params[b], changes[b] = u, u
		}
		generic, derived := derive(k, root, changes, root.span).(^Scope)
		if !derived do return eq
		p, found := first_production(k, generic)
		if !found do return eq
		term := binding_type(k, p)
		more := false
		for c in calls_in(k, term, root) do for b in c.target.(^Scope).changes do if b not_in carved {
			carved[b] = true
			more = true
		}
		if more do continue
		eq.generic, eq.term, eq.params = generic, term, params
		eq.solution = solve(k, eq)
		return eq
	}
}

// solution_at: the solution of the equation at the values a carve of root gives its
// fields, its bound unknowns its own (§5.6).
solution_at :: proc(k: ^Kernel, eq: ^Recursion, s: ^Scope) -> Type {
	return renamed(k, rewrite(k, eq.solution, values_of_call(k, eq, s)))
}

// values_of_call: each unknown of the equation at the value the carve s gives its
// field, or the value the scope holds; a field given a call of another equation, the
// unknowns of that equation at the values its carve gives.
values_of_call :: proc(k: ^Kernel, eq: ^Recursion, s: ^Scope, r: Rewrite = nil) -> Rewrite {
	r := r
	for b, u in eq.params do r = rewriting(r, u, b in s.changes ? s.changes[b] : binding_type(k, holding(s, b)))
	for b, other in eq.through {
		c := called(s.changes[b]) or_continue
		t := c.target.(^Scope) or_continue
		r = values_of_call(k, other, t, r)
	}
	return r
}

// equation_at: the equation at the values a carve of root gives its fields.
equation_at :: proc(k: ^Kernel, eq: ^Recursion, s: ^Scope) -> Type {
	if eq.term == nil do return nil
	r := values_of_call(k, eq, s)
	// its calls are the hypothesis meanwhile: read as calls, never at their values
	eq.reading = true
	defer eq.reading = false
	return rewrite(k, eq.term, r)
}

// solve: the normal form of the equation by the laws of the recursion; nil when they
// leave a call of it.
solve :: proc(k: ^Kernel, eq: ^Recursion) -> Type {
	root := eq.root
	if eq.term == nil do return nil
	if solved(eq.term, root) do return eq.term
	p, is_pattern := eq.term.(^Pattern)
	if !is_pattern do return nil
	// covered branches each calling the equation with the same fields are one (§6)
	p = calls_joined(k, p, root)
	calls := calls_in(k, p, root)
	if len(calls) != 1 do return nil
	call := calls[0]
	u, on_field := p.target.(^Unknown)
	if !on_field do return nil
	stop, base, step, split := bases_and_steps(k, p, root, u)
	if !split do return nil
	// what the call gives back: y, in the family of the bases
	family, known := family_of(k, base)
	if !known do return nil
	y := new_unknown(k, nil)
	y.layout = family_term(family)
	// the effects of a step before its call run at each step of the fold, in the order
	// the equation runs them (§4.8); what follows them is the step, over what the call
	// gives back
	pre, post := make([dynamic]^Effect), make([dynamic]^Effect)
	answered := false
	for e, is_effect := step.(^Effect); is_effect; e, is_effect = step.(^Effect) {
		step = e.then
		if e.call != nil && e.call.recursive {
			// the call, an effect: what it gives back is y
			if answered do return nil
			answered = true
			if e.answer != nil do step = rewrite(k, step, rewriting(nil, e.answer, y))
			continue
		}
		append(answered ? &post : &pre, e)
	}
	step = rewrite(k, step, rewriting_call(nil, call, y))
	if !solved(step, root) || has_effect(step) do return nil
	// the fields the call moves, each to a term over the fields
	next := make(map[^Unknown]Type)
	for b, v in call.target.(^Scope).changes {
		if other, kept := eq.through[b]; kept {
			// a call of the other equation: its fields, each to what the call gives it
			c, is_call := called(v)
			if !is_call do return nil
			t, is_scope := c.target.(^Scope)
			if !is_scope || origin(t) != other.root do return nil
			for ob, ou in other.params do next[ou] = ob in t.changes ? t.changes[ob] : binding_type(k, holding(t, ob))
			continue
		}
		next[eq.params[b] or_else nil] = v
	}
	if nil in next || u not_in next do return nil
	// effects after the call run coming back up, from the base: the fold of the
	// definition along its orbit, from its end
	if len(post) > 0 do return from_base(k, p, u, stop, base, pre[:], post[:], step, y, next)
	// the fold: its index the target, its states the other fields the call moves
	f := new(Fold)
	f.span = p.span
	x := new_unknown(k, nil)
	x.layout = and_law(k, {layout_of(k, u), not_law(k, stop)})
	along: Rewrite = rewriting(nil, u, x)
	states, inits := make([dynamic]^Unknown), make([dynamic]Type)
	for w in next do if w != u {
		z := new_unknown(k, nil)
		z.layout = layout_of(k, w)
		along = rewriting(along, w, z)
		append(&states, z)
		append(&inits, w)
	}
	updates := make([dynamic]Type)
	for w in inits do append(&updates, rewrite(k, next[w.(^Unknown)], along))
	at_end := rewriting(along, u, narrowing(x, and_law(k, {layout_of(k, u), stop})))
	f.index, f.start, f.next, f.stop = x, u, rewrite(k, next[u], along), stop
	effects: Type = None{}
	#reverse for e in pre do effects = wrapped(e, e.answer, effects)
	f.effects, f.value = rewrite(k, effects, along), rewrite(k, base, at_end)
	switch {
	case same(k, step, y):
		// the call itself: the value is the base where the fold stops
	case:
		modulus: Type
		if o, is_mod := step.(^Operation); is_mod && o.op == .Mod {
			if m, constant := o.args[1].(Int); constant && m > 0 do modulus, step = o.args[1], o.args[0]
		}
		modded :: proc(k: ^Kernel, t, m: Type) -> Type {return m == nil ? t : op(k, .Mod, t, m)}
		if alpha, beta, affine := affine_in(k, step, y); affine && (modulus == nil || proven_in(k, alpha, COUNTS) && proven_in(k, beta, COUNTS) && proven_in(k, base, COUNTS)) {
			// α·y + β, modulo m when it is: the maps compose, (A·base + B) % m where it stops
			a, b := new_unknown(k, nil), new_unknown(k, nil)
			a.layout, b.layout = y.layout, y.layout
			if modulus != nil do a.layout, b.layout = COUNTS, COUNTS
			append(&states, a, b)
			append(&inits, Int(1), Int(0))
			append(&updates, modded(k, op(k, .Mul, a, rewrite(k, alpha, along)), modulus), modded(k, op(k, .Add, b, op(k, .Mul, a, rewrite(k, beta, along))), modulus))
			f.value = modded(k, op(k, .Add, op(k, .Mul, a, f.value), b), modulus)
		} else if modulus != nil {
			return nil
		} else if prefix, suffix, runs := run_affine(k, step, y); runs {
			// {...P ...y ...Q}: the runs compose, {...A ...base ...B} where it stops
			a, b := new_unknown(k, nil), new_unknown(k, nil)
			a.layout, b.layout = family_term(.Scope), family_term(.Scope)
			append(&states, a, b)
			append(&inits, joined(k, nil), joined(k, nil))
			append(&updates, joined(k, {a}, prefix, along), joined(k, nil, suffix, along, {b}))
			f.value = joined(k, {a, f.value}, nil, nil, {b})
		} else {
			return nil
		}
	}
	f.states, f.inits, f.updates = states[:], inits[:], updates[:]
	return folded(k, f)
}

// bases_and_steps: a pattern takes its first branch (§6), so its branches are two
// patterns: base, those that do not call root, and step, those that do, each the
// pattern of its branches, the last one taking what is left. stop: where the bases
// take the target — the covers of the bases; when the last branch is a base, what the
// covers of the steps do not take.
bases_and_steps :: proc(k: ^Kernel, p: ^Pattern, root: ^Scope, u: ^Unknown) -> (stop, base, step: Type, ok: bool) {
	bases, steps := make([dynamic]Branch), make([dynamic]Branch)
	for b in p.branches do append(solved(b.product, root) ? &bases : &steps, b)
	if len(bases) == 0 || len(steps) == 0 do return
	group :: proc(k: ^Kernel, p: ^Pattern, branches: []Branch) -> Type {
		if len(branches) == 1 do return branches[0].product
		out := new(Pattern)
		out.target, out.span = p.target, p.span
		out.branches = make([]Branch, len(branches))
		copy(out.branches, branches)
		out.branches[len(branches) - 1].cover = nil
		return pattern_law(k, out)
	}
	covers :: proc(branches: []Branch) -> (Type, bool) {
		cs := make([dynamic]Type)
		for b in branches {
			if b.cover == nil do return nil, false
			append(&cs, b.cover)
		}
		return len(cs) == 1 ? cs[0] : new_or(..cs[:]), true
	}
	last := p.branches[len(p.branches) - 1]
	if last.cover == nil && solved(last.product, root) {
		taken := covers(steps[:]) or_return
		// on a run cut by its head: the runs of fewer pieces (§5.6)
		if short, cuts := cuts_head(k, taken, u); cuts do stop = short
		else do stop = not_law(k, taken)
	} else {
		stop = covers(bases[:]) or_return
	}
	return stop, group(k, p, bases[:]), group(k, p, steps[:]), true
}

// run_affine: v = {...P  ...y  ...Q}, a run that places y once, as a run, and whose
// other bindings do not read y: the bindings P before it and Q after it.
run_affine :: proc(k: ^Kernel, v: Type, y: ^Unknown) -> (prefix, suffix: []^Binding, ok: bool) {
	s := v.(^Scope) or_return
	xs := run_data(k, s)
	at := -1
	for b, i in xs {
		x := binding_value(k, b)
		if b.kind == .Expand && at < 0 {
			if w, is_y := x.(^Unknown); is_y && same_unknown(w, y) {
				at = i
				continue
			}
		}
		if reads(k, x, y) do return
	}
	if at < 0 do return
	return xs[:at], xs[at + 1:], true
}

_ :: syn

// from_base: f(m) = pre(m) · f(s(m)) · post(m, y) with v(m, y) its value, the orbit
// of m by s in closed form, kᵢ = sⁱ(m), n = μ(i: kᵢ in stop): the effects pre run going
// down, i from 0 to n − 1; then the fold comes back up from the base b(kₙ), i from
// n − 1 to 0, each step post(kᵢ, y) and y ↦ v(kᵢ, y) (§5.6). Only u moves.
from_base :: proc(k: ^Kernel, p: ^Pattern, u: ^Unknown, stop, base: Type, pre, post: []^Effect, v: Type, y: ^Unknown, next: map[^Unknown]Type) -> Type {
	if len(next) != 1 do return nil
	i := new_unknown(k, nil)
	i.layout = COUNTS
	ki, closed := orbit(k, next[u], u, u, i)
	if !closed do return nil
	j := new_unknown(k, nil)
	j.layout = COUNTS
	n := least_law(k, j, in_law(k, rewrite(k, ki, rewriting(nil, i, j)), stop), p.span)
	at :: proc(k: ^Kernel, ki: Type, i: ^Unknown, t: Type) -> Type {return rewrite(k, ki, rewriting(nil, i, t))}
	up := new(Fold)
	up.span = p.span
	up.index = new_unknown(k, nil)
	up.index.layout = COUNTS
	up.start, up.next, up.stop = op(k, .Sub, n, Int(1)), op(k, .Sub, up.index, Int(1)), new_range(nil, Int(-1), .Int)
	z := new_unknown(k, nil)
	z.layout = y.layout
	inside := rewriting(rewriting(nil, u, at(k, ki, i, up.index)), y, z)
	effects: Type = None{}
	#reverse for e in post do effects = wrapped(e, e.answer, effects)
	up.states = slice.clone([]^Unknown{z})
	up.inits = slice.clone([]Type{rewrite(k, base, rewriting(nil, u, at(k, ki, i, n)))})
	up.updates = slice.clone([]Type{rewrite(k, v, inside)})
	up.effects, up.value = rewrite(k, effects, inside), z
	value := folded(k, up)
	if len(pre) == 0 do return value
	down := new(Fold)
	down.span = p.span
	down.index = new_unknown(k, nil)
	down.index.layout = COUNTS
	down.start, down.next, down.stop = Int(0), op(k, .Add, down.index, Int(1)), new_range(n, nil, .Int)
	before: Type = None{}
	#reverse for e in pre do before = wrapped(e, e.answer, before)
	down.effects, down.value = rewrite(k, before, rewriting(nil, u, at(k, ki, i, down.index))), None{}
	return wrapped(folded(k, down).(^Effect), nil, value)
}

// calls_joined: t ? {c₀ -> f{x -> a₀}!  …  cₙ -> f{x -> aₙ}!  -> b}, each covered
// branch a call of root carving the same bindings, is one branch (§6): a pattern takes
// its first branch, so t ? {c₀ -> p₀  c₁ -> p₁  -> b} = t ? {c₀ | c₁ -> t ? {c₀ -> p₀
// -> p₁}  -> b}; and a pattern gives one of its products, so t ? {c -> f{x -> a}!
// -> f{x -> b}!} = f{x -> t ? {c -> a  -> b}}!. Otherwise p itself.
calls_joined :: proc(k: ^Kernel, p: ^Pattern, root: ^Scope) -> ^Pattern {
	n := len(p.branches)
	if n < 3 || p.branches[n - 1].cover != nil do return p
	carves := make([]^Scope, n - 1)
	for b, i in p.branches[:n - 1] {
		c, is_call := b.product.(^Collapse)
		if !is_call || !c.recursive do return p
		carve, is_scope := c.target.(^Scope)
		if !is_scope || origin(carve) != root || i > 0 && len(carve.changes) != len(carves[0].changes) do return p
		for x in carve.changes do if i > 0 && x not_in carves[0].changes do return p
		carves[i] = carve
	}
	changes := make(map[^Binding]Type)
	for x in carves[0].changes {
		branches := make([]Branch, n - 1)
		for carve, i in carves {
			branches[i] = p.branches[i]
			branches[i].product = carve.changes[x]
		}
		branches[n - 2].cover = nil
		q := new(Pattern)
		q.target, q.branches, q.span = p.target, branches, p.span
		changes[x] = normal(k, q)
	}
	call := new(Collapse)
	call.target, call.recursive, call.span = carved_copy(k, root, changes), true, p.span
	covers := make([]Type, n - 1)
	for b, i in p.branches[:n - 1] do covers[i] = b.cover
	out := new(Pattern)
	out.target, out.span = p.target, p.span
	out.branches = make([]Branch, 2)
	out.branches[0] = p.branches[0]
	out.branches[0].cover, out.branches[0].product = new_or(..covers), call
	out.branches[1] = p.branches[n - 1]
	return out
}


// cuts_head: the covers {T₁(h₁) … T_c(h_c) ...R:(t)}, one or a union of them, each
// cutting c pieces from the head of u, a run of pieces of one binding, in R. They take
// every run of c pieces or more when one cover takes every piece at each place — or,
// cutting one piece, when its heads together take every piece: a union of covers of
// one piece is the cover of the union of their heads. What they do not take, the
// base, is then the runs of fewer than c pieces.
cuts_head :: proc(k: ^Kernel, cover: Type, u: ^Unknown) -> (short: ^Scope, ok: bool) {
	covers := []Type{cover}
	if any, is_or := cover.(^Or); is_or do covers = any.terms
	pieces, _ := run_pieces(k, u) or_return
	shape := pieces.(^Scope) or_return
	inner := placed(k, shape, .Shape)
	if len(inner) != 1 || is_run(inner[0]) || inner[0].color == nil do return
	item := binding_color(k, inner[0])
	c := -1
	heads := make([dynamic]Type)
	for x in covers {
		written := x.(^Scope) or_return
		places := placed(k, written, .Shape)
		n := len(places) - 1
		if n < 1 || c >= 0 && n != c || !is_run(places[n]) || places[n].color == nil do return
		if !is_bool(in_law(k, u, binding_color(k, places[n])), true) do return
		c = n
		every := true
		for place in places[:n] {
			if is_run(place) do return
			// what the place admits: its color, or the value written there
			head := binding_color(k, place)
			if head == nil && place.value != nil do head = values(k, binding_value(k, place)) or_return
			if head == nil do head = item
			if n == 1 do append(&heads, head)
			every &&= included(k, item, head)
		}
		if every do return runs_of(k, pieces, Int(0), Int(c - 1), cover), true
	}
	if c != 1 || !included(k, item, or_law(k, heads[:])) do return
	return runs_of(k, pieces, Int(0), Int(0), cover), true
}

// runs_of: the runs of lo..hi pieces, hi nil for no bound.
runs_of :: proc(k: ^Kernel, pieces, lo, hi: Type, at: Type) -> ^Scope {
	// no piece: the run of no binding, {} (§4.6)
	if is_int(lo, 0) && is_int(hi, 0) do return run_scope(k, {})
	span := syn.Span{}
	if written, is_scope := at.(^Scope); is_scope do span = written.span
	out := new_scope(nil, span)
	out.source, out.complete, out.reached = out, true, true
	run := new_binding(out, .Expand, span)
	run.color = new_operation(.Mul, pieces, new_range(lo, hi, .Int))
	run.typed_color = run.color
	return out
}

