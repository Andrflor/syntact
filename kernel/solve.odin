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
equation_of :: proc(k: ^Kernel, root: ^Scope, given: []^Binding) -> (eq: ^Recursion, ok: bool) {
	for x in k.equations do if x.root == root && x.reading do return nil, false
	for x in k.equations do if x.root == root && slice.equal(x.given, given) do return x, true
	if p, found := first_production(k, root); found && p.state == .In_Progress do return nil, false
	return equation_built(k, root, given), true
}

// equation_built: the equation of root for the fields given, built.
equation_built :: proc(k: ^Kernel, root: ^Scope, given: []^Binding) -> ^Recursion {
	eq := new(Recursion)
	eq.root, eq.given, eq.reading = root, slice.clone(given), true
	append(&k.equations, eq)
	defer eq.reading = false
	carved := make(map[^Binding]bool)
	for b in given do carved[b] = true
	for {
		params := make(map[^Binding]^Unknown)
		changes := make(map[^Binding]Type)
		for b in carved {
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
	r: Rewrite
	for b, u in eq.params do r = rewriting(r, u, b in s.changes ? s.changes[b] : binding_type(k, holding(s, b)))
	return renamed(k, rewrite(k, eq.solution, r))
}

// equation_at: the equation at the values a carve of root gives its fields.
equation_at :: proc(k: ^Kernel, eq: ^Recursion, s: ^Scope) -> Type {
	if eq.term == nil do return nil
	r: Rewrite
	for b, u in eq.params do r = rewriting(r, u, b in s.changes ? s.changes[b] : binding_type(k, holding(s, b)))
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
	calls := calls_in(k, eq.term, root)
	if len(calls) != 1 do return nil
	call := calls[0]
	p, is_pattern := eq.term.(^Pattern)
	if !is_pattern do return nil
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
	for b, v in call.target.(^Scope).changes do next[eq.params[b] or_else nil] = v
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
		stop = not_law(k, taken)
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
	up.states, up.inits, up.updates = {z}, {rewrite(k, base, rewriting(nil, u, at(k, ki, i, n)))}, {rewrite(k, v, inside)}
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
