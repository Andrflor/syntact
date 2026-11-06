package kernel

import syn "../syntax"

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
	generic:  ^Scope, // root where each field its calls carve is an unknown of its color
	term:     Type, // its first production there
	params:   map[^Binding]^Unknown,
	solution: Type, // the term without calls of root, when the laws give one
	reading:  bool, // being read: its calls are the hypothesis (§5.6)
}

// equation_of: the equation of the recursive scope root, read once; false while it
// is read.
equation_of :: proc(k: ^Kernel, root: ^Scope) -> (eq: ^Recursion, ok: bool) {
	if x, found := k.equations[root]; found do return x, !x.reading
	eq = new(Recursion)
	eq.root, eq.reading = root, true
	k.equations[root] = eq
	defer eq.reading = false
	// its fields: the bindings it declares with a color (§5.5), each an unknown of it
	params := make(map[^Binding]^Unknown)
	changes := make(map[^Binding]Type)
	for b in root.bindings {
		if b.kind != .Push && b.kind != .Pull || b.color == nil do continue
		u := new_unknown(k, nil)
		u.layout = binding_color(k, b)
		params[b], changes[b] = u, u
	}
	generic := derive(k, root, changes, root.span).(^Scope) or_return
	p := first_production(k, generic) or_return
	eq.generic, eq.params = generic, params
	eq.term = binding_type(k, p)
	eq.solution = solve(k, eq)
	return eq, true
}

// solution_at: the solution of the equation at the values a carve of root gives its
// fields, its bound unknowns its own (§5.6).
solution_at :: proc(k: ^Kernel, eq: ^Recursion, s: ^Scope) -> Type {
	r: Rewrite
	for b, u in eq.params do r = rewriting(r, u, b in s.changes ? s.changes[b] : binding_type(k, holding(s, b)))
	return renamed(k, rewrite(k, eq.solution, r))
}

// solve: the normal form of the equation by the laws of the recursion; nil when they
// leave a call of it.
solve :: proc(k: ^Kernel, eq: ^Recursion) -> Type {
	root := eq.root
	if solved(eq.term, root) do return eq.term
	if has_effect(eq.term) do return nil
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
	step = rewrite(k, step, rewriting_call(nil, call, y))
	if !solved(step, root) do return nil
	// the fields the call moves, each to a term over the fields
	next := make(map[^Unknown]Type)
	for b, v in call.target.(^Scope).changes do next[eq.params[b] or_else nil] = v
	if nil in next || u not_in next do return nil
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
	f.effects, f.value = None{}, rewrite(k, base, at_end)
	switch {
	case same(k, step, y):
		// the call itself: the value is the base where the fold stops
	case:
		if alpha, beta, affine := affine_in(k, step, y); affine {
			// α·y + β: the maps compose, A·base + B where it stops
			a, b := new_unknown(k, nil), new_unknown(k, nil)
			a.layout, b.layout = y.layout, y.layout
			append(&states, a, b)
			append(&inits, Int(1), Int(0))
			append(&updates, op(k, .Mul, a, rewrite(k, alpha, along)), op(k, .Add, b, op(k, .Mul, a, rewrite(k, beta, along))))
			f.value = op(k, .Add, op(k, .Mul, a, f.value), b)
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
	return fold_law(k, f)
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
