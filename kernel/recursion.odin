package kernel

import syn "../syntax"
import "core:slice"
import "core:strings"

// RECURSION (specs/types.md §5.6)
//
// A scope names itself only in its productions. Asked again from its own
// production, it stays a carve and a collapse — a recursive call — and is never
// unfolded. Its first production is then an equation that mentions it. It is
// solved — an iteration, in a closed form when it has one — or it stays. A call of
// a solved equation substitutes its arguments into the solution.
//
// A recursive call is read on its equation, where what it carves is unknown: what it
// proves, by induction; the values it gives, as the scope of that equation, a color.
// While the equation is read, its calls are the hypothesis: an operator on them is
// checked once it is given.

// recursive: the productions of a scope name it — the binding whose value it is —
// directly or in a carve (§5.6); a carve of it is recursive with it.
recursive :: proc(s: ^Scope) -> bool {
	root := origin(s)
	seen := make(map[^Scope]bool)
	for b in root.bindings do if b.kind == .Product && (names_scope(b.color, root, &seen) || names_scope(b.value, root, &seen)) do return true
	return false
}

// names_scope: the term, as written, names the binding whose value is s. A scope
// is read once: `.x` names the scope it is written in.
names_scope :: proc(t: Type, s: ^Scope, seen: ^map[^Scope]bool) -> bool {
	if t == nil do return false
	switch v in t {
	case ^Name:
		value, ok := v.binding.value.(^Scope)
		return ok && value == s
	case ^Scope:
		if v in seen do return false
		seen[v] = true
		for b in v.bindings do if names_scope(b.color, s, seen) || names_scope(b.value, s, seen) do return true
	case ^Operation:
		for a in v.args do if names_scope(a, s, seen) do return true
	case ^Or:
		for a in v.terms do if names_scope(a, s, seen) do return true
	case ^And:
		for a in v.terms do if names_scope(a, s, seen) do return true
	case ^Effect:
		return v.choice != nil && names_scope(v.choice, s, seen) || names_scope(v.then, s, seen)
	case ^Not:
		return names_scope(v.term, s, seen)
	case ^Is:
		return names_scope(v.term, s, seen)
	case ^Range:
		return names_scope(v.lo, s, seen) || names_scope(v.hi, s, seen)
	case ^Access:
		return names_scope(v.target, s, seen)
	case ^Collapse:
		return names_scope(v.target, s, seen)
	case ^Carve:
		if target, is_scope := v.target.(^Scope); is_scope && target == s do return true // a carve of s itself
		if names_scope(v.target, s, seen) do return true
		for a in v.args do if names_scope(a.value, s, seen) || names_scope(a.otherwise, s, seen) do return true
	case ^Default:
		return names_scope(v.color, s, seen)
	case ^Pattern:
		if names_scope(v.target, s, seen) do return true
		for b in v.branches do if names_scope(b.cover, s, seen) || names_scope(b.product, s, seen) do return true
	case ^Fold:
		for t in fold_parts(v) do if names_scope(t, s, seen) do return true
	case ^Least:
		return names_scope(v.holds, s, seen)
	case ^Series:
		return names_scope(v.lo, s, seen) || names_scope(v.hi, s, seen) || names_scope(v.term, s, seen)
	case ^Recurrent:
		for t in v.initial do if names_scope(t, s, seen) do return true
		return names_scope(v.at, s, seen)
	case Char, Int, Real, Bool, None, Invalid, ^Unknown:
	}
	return false
}

// origin: the scope a copy carves, uncarved; a scope is its own.
origin :: proc(s: ^Scope) -> ^Scope {
	return s.carved != nil ? s.carved : s
}

// recursive_call: s! where s is a recursive scope, or a carve of one. A carve of it
// was checked where it is written (scope.odin).
recursive_call :: proc(k: ^Kernel, s: ^Scope, span: syn.Span) -> Type {
	root := origin(s)
	if p, found := first_production(k, root); found && p.state != .In_Progress {
		solution := binding_type(k, p)
		if solved(solution, root) {
			values: Rewrite
			substitutable := true
			for b, v in s.changes {
				u, is_unknown := binding_type(k, b).(^Unknown)
				if !is_unknown {
					substitutable = false
					break
				}
				values = rewriting(values, u, v)
			}
			// each call runs the effects of the solution: what they give back is new
			run: Rewrite
			if substitutable do return renewed(k, substituted(k, solution, values), &run)
		}
	}
	out := new(Collapse)
	out.target, out.recursive, out.span = s, true, span
	if root.effectful do return call_effect(k, out)
	// a production that, at the values the carve gives, calls nothing is the value
	// (§7); asked when the carve gives a known value, which may decide it
	decides := false
	for _, v in s.changes do decides ||= is_constant(v)
	if decides && s != root {
		if v, rest, eq, read := production_known(k, out); read {
			defer eq.read = false
			if solved(v, root) do return rewrite(k, v, rest)
		}
	}
	// a recursion over what a fold builds is the fold of the recursion
	if s != root do for b, v in s.changes {
		f, is_fold := v.(^Fold)
		if !is_fold do continue
		if x, folded := over_fold(k, s, b, f, span); folded do return x
	}
	return out
}

// as_call: t is a recursive call, or what one with effects gives back.
as_call :: proc(t: Type) -> (^Collapse, bool) {
	#partial switch v in t {
	case ^Collapse:
		if v.recursive do return v, true
	case ^Unknown:
		if v.call != nil do return v.call, true
	}
	return nil, false
}

// solved: t holds no recursive call of the scope, nor does a scope in it.
solved :: proc(t: Type, root: ^Scope) -> bool {
	#partial switch v in t {
	case ^Collapse:
		if s, ok := v.target.(^Scope); ok && v.recursive && origin(s) == root do return false
	case ^Scope:
		seen := make(map[^Scope]bool)
		return !names_scope(v, root, &seen)
	case ^Operation:
		for a in v.args do if !solved(a, root) do return false
	case ^Or:
		for a in v.terms do if !solved(a, root) do return false
	case ^And:
		for a in v.terms do if !solved(a, root) do return false
	case ^Not:
		return solved(v.term, root)
	case ^Effect:
		if v.call != nil && !solved(v.call, root) do return false
		if v.fold != nil && !solved(v.fold, root) do return false
		if v.choice != nil && !solved(v.choice, root) do return false
		return solved(v.then, root)
	case ^Pattern:
		if !solved(v.target, root) do return false
		for b in v.branches do if !solved(b.product, root) do return false
	case ^Fold:
		for t in fold_parts(v) do if !solved(t, root) do return false
	case ^Least:
		return solved(v.holds, root)
	case ^Series:
		return solved(v.lo, root) && solved(v.hi, root) && solved(v.term, root)
	case ^Recurrent:
		for t in v.initial do if !solved(t, root) do return false
		return solved(v.at, root)
	}
	return true
}

// call_family: the family a recursive call is proven in: `c in F` (§4.5, call_in);
// with a read, the family what it reads of what the call gives is proven in. None
// while its equation is read: its calls are the hypothesis.
call_family :: proc(k: ^Kernel, c: ^Collapse, fields := Read{}) -> (Family, bool) {
	s, ok := c.target.(^Scope)
	if !ok || !c.recursive || reading(k, origin(s)) do return {}, false
	for f in ([]Family{.Int, .Real, .Bool, .Char, .String, .Scope}) do if call_in(k, c, family_term(f), fields) do return f, true
	return {}, false
}

// is_pending_call: a recursive call whose equation is being read, or what is read
// of it: the hypothesis of the induction, checked once the equation is given.
is_pending_call :: proc(k: ^Kernel, t: Type) -> bool {
	#partial switch v in t {
	case ^Access:
		return is_pending_call(k, v.target)
	case ^Operation:
		if v.op == .Item || v.op == .From do return is_pending_call(k, v.args[0])
	case ^And:
		// t & S: t where it is in S (§4.2)
		for a in v.terms do if is_pending_call(k, a) do return true
	}
	c, ok := as_call(t)
	if !ok do return false
	s, is_scope := c.target.(^Scope)
	return is_scope && reading(k, origin(s))
}

// reading: the equation of root is being read — its production typed, read where
// what its calls carve is unknown (call_equation), or read at the values of a call
// (production_at) —, as a binding is while it is given. Its calls are then the
// hypothesis (§5.6).
reading :: proc(k: ^Kernel, root: ^Scope) -> bool {
	if p, found := first_production(k, root); found && p.state == .In_Progress do return true
	for x in k.equations do if x.root == root && (!x.derived || x.read) do return true
	return false
}

// carved_by_calls: the bindings the recursive calls of e carve.
carved_by_calls :: proc(k: ^Kernel, e: Type, root: ^Scope) -> map[^Binding]Type {
	carved := make(map[^Binding]Type)
	for c in calls_in(k, e, root) do for b in c.target.(^Scope).changes do carved[b] = nil
	return carved
}

// generic_equation: root where each binding of carved is an unknown of its color,
// root{n -> ?::C}; carved maps each one to its unknown. Without a color, a binding
// is in the family of its value (§5.4). A binding given a call of another equation
// keeps it, over that equation's own fields (through): the recursion follows what
// the other builds (§5.6).
generic_equation :: proc(k: ^Kernel, root: ^Scope, carved: ^map[^Binding]Type, through: []Through = nil) -> (^Scope, bool) {
	for b in carved {
		if t, kept := through_of(through, b); kept {
			carved[b] = recursive_call(k, t.equation.generic, root.span)
			continue
		}
		u := new_unknown(k, nil)
		u.layout = binding_color(k, b)
		if u.layout == nil {
			f, known := family_of(k, binding_type(k, b))
			u.layout = known ? family_term(f) : everything()
		}
		carved[b] = u
	}
	return derive(k, root, carved^, root.span).(^Scope)
}

// Through: a binding a call gives a call of another equation, and the equation that
// call reads.
Through :: struct {
	field:    ^Binding,
	equation: ^Call_Equation,
}

through_of :: proc(through: []Through, b: ^Binding) -> (Through, bool) {
	for t in through do if t.field == b do return t, true
	return {}, false
}

// call_key: the bindings a call of root carving given carves, sorted by address,
// and those given a call of another equation, with the equation it reads.
call_key :: proc(k: ^Kernel, root: ^Scope, given: map[^Binding]Type) -> (key: []^Binding, through: []Through) {
	bindings := make([dynamic]^Binding)
	kept := make([dynamic]Through)
	for b, v in given {
		append(&bindings, b)
		c, is_call := v.(^Collapse)
		if !is_call || !c.recursive do continue
		s, is_scope := c.target.(^Scope)
		// a call of an equation being read is the hypothesis: nothing is read through it
		if !is_scope || origin(s) == root || reading(k, origin(s)) do continue
		// the equation of every call of it: where all it and its calls carve is unknown
		eq := equation_of(k, c) or_continue
		all := make([dynamic]^Binding)
		for x in eq.params do append(&all, x)
		slice.sort_by(all[:], proc(a, b: ^Binding) -> bool {return uintptr(a) < uintptr(b)})
		if whole, read := call_equation(k, eq.root, all[:], eq.through); read do append(&kept, Through{b, whole})
	}
	slice.sort_by(bindings[:], proc(a, b: ^Binding) -> bool {return uintptr(a) < uintptr(b)})
	slice.sort_by(kept[:], proc(a, b: Through) -> bool {return uintptr(a.field) < uintptr(b.field)})
	return bindings[:], kept[:]
}

// generic_solution: the solution of the equation of root where each binding of
// values is an unknown of its color, with those values (§5.6):
// sum{n -> m}! = m ? {0 -> 0  -> m + sum{n -> m - 1}!} gives m * (m + 1) / 2 whatever
// m, and whatever n holds in sum.
generic_solution :: proc(k: ^Kernel, root: ^Scope, given: map[^Binding]Type) -> (solution: Type, ok: bool) {
	// solved once for the bindings given: then at their values, its bound unknowns
	// its own
	// the bindings given, and those the calls carve, at the values root holds
	// a carve of the solved equation substitutes its arguments into the solution
	// (§5.6); unsolved, the equation read through the calls of others it is given
	key, through := call_key(k, root, given)
	if eq, read := call_equation(k, root, key); read {
		if solved, ok := solved_once(k, eq); ok do return substituted(k, solved, at_values(k, eq, given)), true
	}
	if len(through) == 0 do return
	eq := call_equation(k, root, key, through) or_return
	solved := solved_once(k, eq) or_return
	return substituted(k, solved, at_values(k, eq, given)), true
}

// solved_once: the solution of an equation, by iteration (§5.6), once.
solved_once :: proc(k: ^Kernel, eq: ^Call_Equation) -> (solution: Type, ok: bool) {
	for g in k.generics do if g.equation == eq do return g.solved, true
	solution = iteration(k, eq.generic, eq.equation) or_return
	append(&k.generics, Generic{eq, solution})
	return solution, true
}

// substituted: a solution at the values r gives (§5.6), its bound unknowns its own —
// renamed once their layouts have followed the values.
substituted :: proc(k: ^Kernel, solution: Type, r: Rewrite) -> Type {
	return renamed(k, rewrite(k, solution, r))
}

// at_values: each unknown of the equation at the value given to its binding, or at
// the value the scope holds; a binding given a call of another equation, the
// unknowns of that equation at the values its carve gives.
at_values :: proc(k: ^Kernel, eq: ^Call_Equation, given: map[^Binding]Type, r: Rewrite = nil) -> Rewrite {
	r := r
	for b, u in eq.params {
		if t, kept := through_of(eq.through, b); kept {
			if c, is_call := given[b].(^Collapse); is_call do if s, is_scope := c.target.(^Scope); is_scope {
				r = at_values(k, t.equation, s.changes, r)
				continue
			}
		}
		if x, is_unknown := u.(^Unknown); is_unknown do r = rewriting(r, x, b in given ? given[b] : binding_type(k, b))
	}
	return r
}

// production_at: the production of the equation the call c reads, at the values its
// carve gives (§5.6, §6). The equation is read until the caller closes it (eq.read):
// meanwhile its calls are the hypothesis. Not read while it is already.
production_at :: proc(k: ^Kernel, c: ^Collapse) -> (v: Type, eq: ^Call_Equation, ok: bool) {
	rest: Rewrite
	v, rest, eq = production_known(k, c) or_return
	v = rewrite(k, v, rest)
	if holds_invalid(v) || has_effect(v) {
		eq.read = false
		return nil, nil, false
	}
	return v, eq, true
}

// production_known: the production of the equation the call c reads at the known
// values its carve gives — the constants, which decide its patterns —, and rest, the
// other values: a term is read into the production after, so that a pattern on it is
// not taken one binding at a time (§5.6: the equation is read where what is carved is
// unknown, then solved).
production_known :: proc(k: ^Kernel, c: ^Collapse) -> (v: Type, rest: Rewrite, eq: ^Call_Equation, ok: bool) {
	s, is_scope := c.target.(^Scope)
	if !is_scope || !c.recursive || reading(k, origin(s)) do return
	eq = equation_of(k, c) or_return
	eq.read = true
	known := make([dynamic]Rewriting)
	others := make([dynamic]Rewriting)
	for x in at_values(k, eq, s.changes) do append(is_constant(x.term) ? &known : &others, x)
	v = rewrite(k, eq.equation, known[:])
	if holds_invalid(v) || has_effect(v) {
		eq.read = false
		return nil, nil, nil, false
	}
	return v, others[:], eq, true
}

// Call_Equation: the equation a call of root reads: root's production where the bindings
// the call carves, and those its calls carve, are unknowns of their colors — params
// maps each to its unknown (§5.6). Read once per root and bindings carved.
Call_Equation :: struct {
	root:     ^Scope,
	given:    []^Binding,
	through:  []Through, // the bindings given a call of another equation, kept
	generic:  ^Scope,
	equation: Type,
	params:   map[^Binding]Type,
	derived:  bool, // read where what is carved is unknown; generic nil when it cannot be
	read:     bool, // read at the values of a call (production_at, call_in)
}

// call_equation: the equation of root a call carving the bindings given reads,
// given sorted by address; through, those it gives a call of another equation.
call_equation :: proc(k: ^Kernel, root: ^Scope, given: []^Binding, through: []Through = nil) -> (eq: ^Call_Equation, ok: bool) {
	for x in k.equations do if x.root == root && slice.equal(x.given, given) && slice.equal(x.through, through) do return x, x.generic != nil
	// while it is read, its calls are the hypothesis: their equation is not read yet,
	// as a binding asked while it is given
	eq = new(Call_Equation)
	eq.root, eq.given, eq.through = root, slice.clone(given), slice.clone(through)
	append(&k.equations, eq)
	defer eq.derived = true
	params := make(map[^Binding]Type)
	for b in given do params[b] = nil
	for {
		for b in params do params[b] = nil
		generic := generic_equation(k, root, &params, through) or_break
		p := first_production(k, generic) or_break
		equation := binding_type(k, p)
		more := false
		for b in carved_by_calls(k, equation, root) do if b not_in params {
			params[b] = nil
			more = true
		}
		if !more {
			// read through another equation, a term of no type: not read so
			if len(through) > 0 && holds_invalid(equation) do return
			eq.generic, eq.equation, eq.params = generic, equation, params
			return eq, true
		}
	}
	return
}

// keyed_equation: the equation a call of root carving given reads: through the
// calls of other equations it gives, unless that reading gives a term of no type;
// then where they are unknowns of their colors.
keyed_equation :: proc(k: ^Kernel, root: ^Scope, given: map[^Binding]Type) -> (eq: ^Call_Equation, ok: bool) {
	key, through := call_key(k, root, given)
	eq, ok = call_equation(k, root, key, through)
	if ok || len(through) == 0 || !eq.derived do return
	return call_equation(k, root, key)
}

// equation_of: the equation the call c reads.
equation_of :: proc(k: ^Kernel, c: ^Collapse) -> (eq: ^Call_Equation, ok: bool) {
	s := c.target.(^Scope) or_return
	return keyed_equation(k, origin(s), s.changes)
}

// Generic: the solution of an equation where the bindings given, and those its
// calls carve, are the unknowns params holds.
Generic :: struct {
	equation: ^Call_Equation,
	solved:   Type,
}

// holding: the binding of s that holds b, a binding of the scope s copies: b
// itself, or its copy.
holding :: proc(s: ^Scope, b: ^Binding) -> ^Binding {
	for x in s.bindings do if x == b || x.source == b do return x
	return b
}

// base_cases: the products of e that do not call root, through the effects that wrap
// them (§4.8).
base_cases :: proc(e: Type, root: ^Scope) -> []Type {
	out := make([dynamic]Type)
	if a, is_effect := e.(^Effect); is_effect && (a.call == nil || !a.call.recursive) do return base_cases(a.then, root)
	if p, is_pattern := e.(^Pattern); is_pattern {
		for b in p.branches do if solved(b.product, root) do append(&out, ..base_cases(b.product, root))
	} else if solved(e, root) {
		append(&out, e)
	}
	return out[:]
}

// production_law: the value of a production. In a recursive scope, the equation —
// its first production — is given first, and solved when it can be (§5.6); a carve
// of it is the same equation. When the equation has effects besides its calls
// — its production, or a binding above it, has some, for some values of its fields
// —, each call runs it, so its calls are effects too (§4.8): the production is typed
// again, on a copy, its calls in the order they are written like any effect.
production_law :: proc(k: ^Kernel, b: ^Binding) -> Type {
	root := origin(b.scope)
	if !recursive(root) do return normal(k, b.value)
	first, found := first_production(k, root)
	if found && first != b && first.state == .Not_Asked do binding_type(k, first)
	value := normal(k, b.value)
	if first != b do return value
	if !root.effectful && (has_effect(with_effects(k, root, b, value)) || effects_elsewhere(k, root)) {
		root.effectful = true
		m: Copier
		m.scopes[b.scope] = b.scope // the scopes written in the production are copied
		value = normal(k, copy_term(k, &m, b.value, b.scope))
	}
	return solve(k, root, value)
}

// effects_elsewhere: the equation of root has effects besides its calls where its
// fields are unknowns of their colors, though not at the values they hold: a
// pattern on a known value keeps one branch, the equation all of them. Its calls
// stay calls while its production is given. A field that is a scope, or an unknown
// already, stays.
effects_elsewhere :: proc(k: ^Kernel, root: ^Scope) -> bool {
	fields := make(map[^Binding]Type)
	for f in root.bindings {
		if f.kind != .Push && f.kind != .Pull do continue
		#partial switch _ in binding_value(k, f) {
		case ^Unknown, ^Scope:
			continue
		}
		fields[f] = nil
	}
	if len(fields) == 0 do return false
	generic := generic_equation(k, root, &fields) or_return
	p := first_production(k, generic) or_return
	return has_effect(with_effects(k, generic, p, binding_type(k, p)))
}

// solve: the solution of the equation (§5.6): its iteration, when it is a
// recursion on a counter. When what the calls carve holds known values in the
// scope, the equation is read where they are unknowns, and solved at those values.
solve :: proc(k: ^Kernel, root: ^Scope, value: Type) -> Type {
	if solution, solved := iteration(k, root, value); solved do return solution
	if root.effectful do return value
	values := carved_by_calls(k, value, root)
	if len(values) == 0 do return value
	for b in values do values[b] = binding_type(k, b)
	if solution, solved := generic_solution(k, root, values); solved do return solution
	return value
}

// iteration: the solution of a recursion (§5.6). A run of
//
//   f{n -> m}! = m ? {B -> c(m)  -> pre(m) · f{n -> s(m)}! · post(m)}
//
// follows the orbit of m by s until B: the effects before the call run going down,
// those after it coming back up — the order the equation runs them, by Arden on its
// effects. Its value is v(m, y) after post, y what the call gives back. When the
// orbit has a closed form, kᵢ = sⁱ(m), and its length n = μ(i: kᵢ in B), the
// recurrence itself is folded from the base case up, x = v(kᵢ, x) for i from n - 1
// down to 0, after pre going down — unless post reads what pre gives back. Calls
// further along the orbit, f{n -> s²(m)}! …, are a window of states. Otherwise,
// when post has no effect and v is affine in y, v = α·y + β, the maps compose,
// (A, B) ∘ (α, β) = (A·α, B + A·β): the fold goes down, A·c + B where it stops.
// What is left would keep the orbit, or what pre gives back: it stays.
iteration :: proc(k: ^Kernel, s: ^Scope, value: Type) -> (solution: Type, ok: bool) {
	root := origin(s)
	p := calls_joined(k, value.(^Pattern) or_return, root)
	if len(p.branches) != 2 || p.branches[0].cover == nil || p.branches[1].cover != nil do return
	u := p.target.(^Unknown) or_return
	// a step with a term of no type is not solved: the call stays, typed at its values
	for b in p.branches do if holds_invalid(b.product) do return
	stop, c, r := p.branches[0].cover, p.branches[0].product, p.branches[1].product
	// the branch with a cover calls, the other is the base: it takes what the cover
	// does not (§6) — on a run cut by its head, the runs of fewer pieces
	if !solved(c, root) && solved(r, root) {
		short, cuts := cuts_head(k, stop, u)
		stop, c, r = cuts ? Type(short) : not_law(k, stop), r, c
	}
	if !solved(c, root) do return
	family := family_of(k, given(k, c)) or_return
	pre, calls, answer, after := at_calls(k, s, r) or_return
	if answer == nil && skips(r, root) do return
	step, ahead, carried := orbit_step(k, s, calls, u) or_return
	// what each call gives back
	ys := make([]^Unknown, len(calls))
	if answer != nil do ys[0] = answer
	else {
		for call, j in calls {
			ys[j] = new_unknown(k, nil)
			ys[j].layout = family_term(family)
			after = rewrite(k, after, rewriting_call(nil, call, ys[j]))
		}
	}
	if !solved(after, root) do return
	post := make([dynamic]^Effect)
	v := after
	for e, is_effect := v.(^Effect); is_effect; e, is_effect = v.(^Effect) {
		append(&post, e)
		v = e.then
	}
	if has_effect(v) do return
	// the orbit: its point x where the fold goes on, its closed form kᵢ, its length n
	x := orbit_index(k, u, stop)
	i := new_unknown(k, nil)
	i.layout = COUNTS
	ki, closed := orbit(k, rewrite(k, step, rewriting(nil, u, x)), x, u, i)
	n: Type
	if closed {
		j := new_unknown(k, nil)
		j.layout = i.layout
		n = least_law(k, j, in_law(k, rewrite(k, ki, rewriting(nil, i, j)), stop), p.span)
		// along the orbit, before it stops: i in 0..n - 1
		along := new_unknown(k, nil)
		along.layout = range_law(k, Int(0), op(k, .Sub, n, Int(1)), .Int, p.span)
		ki, i = rewrite(k, ki, rewriting(nil, i, along)), along
	}
	at := proc(k: ^Kernel, ki: Type, i: ^Unknown, t: Type) -> Type {return rewrite(k, ki, rewriting(nil, i, t))}
	feeds := false
	for e in pre do feeds ||= e.answer != nil && reads(k, after, e.answer)
	// states carried by the call: the fold goes down
	if closed && !feeds && len(carried) == 0 {
		d := 0
		for a in ahead do d = max(d, a)
		if d > 1 && (has_effect(c) || answer != nil || !continues(k, stop, ki, i)) do return
		// coming back up, from the base case: z₁ … z_d, f at the d points after kᵢ
		f := new(Fold)
		f.index, f.span = i, p.span
		f.start, f.next, f.stop = op(k, .Sub, n, Int(1)), op(k, .Sub, i, Int(1)), new_range(nil, Int(-1), .Int)
		inside := rewriting(nil, u, ki)
		states := make([]^Unknown, d)
		inits := make([]Type, d)
		for &z, j in states {
			z = new_unknown(k, nil)
			z.layout = family_term(family)
			inits[j] = rewrite(k, c, rewriting(nil, u, at(k, ki, i, op(k, .Add, n, Int(j)))))
		}
		for y, j in ys do inside = rewriting(inside, y, states[ahead[j] - 1])
		updates := make([]Type, d)
		updates[0] = rewrite(k, v, inside)
		for j in 1 ..< d do updates[j] = states[j - 1]
		f.states, f.inits, f.updates, f.value = states, inits, updates, states[0]
		f.effects = rewrite(k, wrap_effects(post[:], None{}), inside)
		up := d == 1 ? sequence(k, f, {inits[0]}, from_base) : folded(k, f)
		if len(pre) == 0 do return up, true
		// going down first: the effects before the call
		down := new(Fold)
		down.index, down.span = new_unknown(k, nil), p.span
		down.index.layout = i.layout
		down.start, down.next, down.stop = Int(0), op(k, .Add, down.index, Int(1)), new_range(n, nil, .Int)
		down.effects, down.value = rewrite(k, wrap_effects(pre, None{}), rewriting(nil, u, at(k, ki, i, down.index))), None{}
		return wrapped(folded(k, down).(^Effect), nil, up), true
	}
	// v = (α·y + β) % m, m > 0, all ≥ 0: affine modulo m, the maps compose modulo m
	modulus: Type
	if o, is_mod := v.(^Operation); is_mod && o.op == .Mod {
		if mm, constant := o.args[1].(Int); constant && mm > 0 && proven_in(k, c, COUNTS) {
			modulus, v = o.args[1], o.args[0]
		}
	}
	alpha, beta, affine := affine_in(k, v, ys[0])
	if modulus != nil && affine && !(proven_in(k, alpha, COUNTS) && proven_in(k, beta, COUNTS)) do return
	// v = {...P  ...y  ...Q}: affine in the runs, which compose likewise:
	// (A, B) ∘ (P, Q) = ({...A ...P}, {...Q ...B})
	prefix, suffix, joins := run_affine(k, v, ys[0])
	if joins && modulus != nil do return
	// v = y: A = 1 and B = 0 at every step, so the value is c
	tail := affine && is_int(alpha, 1) && is_int(beta, 0)
	if len(calls) != 1 || len(post) > 0 || !affine && !joins || family != .Int && !tail && !joins do return
	modded :: proc(k: ^Kernel, t, m: Type) -> Type {return m == nil ? t : op(k, .Mod, t, m)}
	// going down: the states the call carries, and the composed map (A, B)
	f := new(Fold)
	f.span = p.span
	carry: Rewrite
	states, inits := make([dynamic]^Unknown), make([dynamic]Type)
	for w in carried {
		z := new_unknown(k, nil)
		z.layout = layout_of(k, w)
		carry = rewriting(carry, w, z)
		append(&states, z)
		append(&inits, w)
	}
	along, at_end: Rewrite
	if closed {
		f.index, f.start, f.next, f.stop = i, Int(0), op(k, .Add, i, Int(1)), new_range(n, nil, .Int)
		along, at_end = rewriting(carry, u, ki), rewriting(carry, u, at(k, ki, i, n))
	} else {
		f.index, f.start, f.next, f.stop = x, u, rewrite(k, step, rewriting(nil, u, x)), stop
		along, at_end = rewriting(carry, u, x), rewriting(carry, u, narrowing(x, and_law(k, {layout_of(k, u), stop})))
	}
	updates := make([dynamic]Type)
	for w in inits do append(&updates, rewrite(k, carried[w.(^Unknown)], along))
	f.effects = rewrite(k, wrap_effects(pre, None{}), along)
	f.value = rewrite(k, c, at_end)
	if joins {
		// A, and B when Q places something: without, B is {} at every step
		a := new_unknown(k, nil)
		a.layout = family_term(.Scope)
		append(&states, a)
		append(&inits, joined(k, nil))
		append(&updates, joined(k, {a}, prefix, along))
		last := []Type{}
		if len(suffix) > 0 {
			b := new_unknown(k, nil)
			b.layout = family_term(.Scope)
			append(&states, b)
			append(&inits, joined(k, nil))
			append(&updates, joined(k, nil, suffix, along, {b}))
			last = {b}
		}
		f.value = joined(k, {a, f.value}, nil, nil, last)
	} else if !tail {
		a, b := new_unknown(k, nil), new_unknown(k, nil)
		a.layout, b.layout = family_term(.Int), family_term(.Int)
		if modulus != nil do a.layout, b.layout = COUNTS, COUNTS
		append(&states, a, b)
		append(&inits, Int(1), Int(0))
		append(&updates, modded(k, op(k, .Mul, a, rewrite(k, alpha, along)), modulus), modded(k, op(k, .Add, b, op(k, .Mul, a, rewrite(k, beta, along))), modulus))
		f.value = modded(k, op(k, .Add, op(k, .Mul, a, f.value), b), modulus)
	}
	f.states, f.inits, f.updates = states[:], inits[:], updates[:]
	return folded(k, f), true
}

// run_affine: v = {...P  ...y  ...Q}, a run that places y once, as a run, and
// whose other bindings do not read y: the bindings P before it and Q after it.
run_affine :: proc(k: ^Kernel, v: Type, y: ^Unknown) -> (prefix, suffix: []^Binding, ok: bool) {
	s := v.(^Scope) or_return
	xs := run_data(k, s)
	at := -1
	for b, i in xs {
		x := binding_value(k, b)
		if b.kind == .Expand && at < 0 {
			if u, is_y := x.(^Unknown); is_y && same_unknown(u, y) {
				at = i
				continue
			}
		}
		if reads(k, x, y) do return
	}
	if at < 0 do return
	return xs[:at], xs[at + 1:], true
}

// joined: the run of the runs first, the bindings of the run between, rewritten by
// r, then the runs last: {...a₀ … ...aₙ  x₀ … xₘ  ...b₀ … ...bₗ}. A run known to
// be a scope places its bindings (§5.3).
joined :: proc(k: ^Kernel, first: []Type, between: []^Binding = nil, r: Rewrite = nil, last: []Type = nil) -> Type {
	s := new_scope(nil, {})
	s.source, s.complete, s.reached = s, true, true
	place :: proc(k: ^Kernel, s: ^Scope, kind: Kind, t: Type) {
		if kind == .Expand {
			if known, is_scope := given(k, t).(^Scope); is_scope {
				for x in run_data(k, known) do place(k, s, x.kind, binding_value(k, x))
				return
			}
		}
		b := new_binding(s, kind, {})
		b.value = t
	}
	for t in first do place(k, s, .Expand, t)
	for x in between do place(k, s, x.kind, rewrite(k, binding_value(k, x), r))
	for t in last do place(k, s, .Expand, t)
	// {...x} is the run x
	if len(s.bindings) == 1 && s.bindings[0].kind == .Expand do return s.bindings[0].value
	return normal(k, s)
}

// orbit_step: the step s of the orbit the calls follow, and how far along it each
// call is: one call, s itself, 1; calls f{n -> m - j}!, the points j / g along
// s(m) = m - g, g the greatest divisor of the j.
orbit_step :: proc(k: ^Kernel, s: ^Scope, calls: []^Collapse, u: ^Unknown) -> (step: Type, ahead: []int, carried: map[^Unknown]Type, ok: bool) {
	if len(calls) == 1 {
		step, carried = counter_next(k, s, calls[0], u) or_return
		return step, slice.clone([]int{1}), carried, true
	}
	shifts := make([]i128, len(calls))
	g: i128 = 0
	for call, j in calls {
		next, others := counter_next(k, s, call, u) or_return
		if len(others) > 0 do return
		alpha, beta := affine_in(k, next, u) or_return
		one, is_int := alpha.(Int)
		minus, constant := beta.(Int)
		if !is_int || one != 1 || !constant || minus >= 0 do return
		shifts[j] = -i128(minus)
		g = gcd(g, shifts[j])
	}
	ahead = make([]int, len(calls))
	for x, j in shifts do ahead[j] = int(x / g)
	return op(k, .Sub, u, Int(g)), ahead, nil, true
}

// continues: the orbit, once in B, stays in it — kᵢ decreasing, B = ..b, or
// increasing, B = b.. —: the points after the end of the orbit are base cases.
continues :: proc(k: ^Kernel, stop: Type, ki: Type, i: ^Unknown) -> bool {
	r, is_range := stop.(^Range)
	if !is_range do return false
	alpha, _, affine := affine_in(k, ki, i)
	slope, is_int := alpha.(Int)
	if !affine || !is_int do return false
	return slope < 0 && r.lo == nil || slope > 0 && r.hi == nil
}

// orbit: kᵢ = sⁱ(m), the i-th point of the orbit of m by s(x), when it has a closed
// form: s(x) = α·x + β gives m + β·i when α = 1, αⁱ·m + β·(αⁱ - 1)/(α - 1)
// otherwise; s(x) = x / c gives m / cⁱ; s(x) = x >> c gives m >> c·i.
orbit :: proc(k: ^Kernel, s: Type, x: ^Unknown, m: Type, i: ^Unknown) -> (Type, bool) {
	if alpha, beta, affine := affine_in(k, s, x); affine {
		a, is_int := alpha.(Int)
		b, constant := beta.(Int)
		if is_int && constant && a == 1 do return op(k, .Add, m, op(k, .Mul, b, i)), true
		if is_int && constant && a != 0 {
			power := op(k, .Pow, a, i)
			return op(k, .Add, op(k, .Mul, power, m), op(k, .Div, op(k, .Mul, b, op(k, .Sub, power, Int(1))), Int(a - 1))), true
		}
	}
	o, is_op := s.(^Operation)
	if !is_op || len(o.args) != 2 do return nil, false
	y, is_x := o.args[0].(^Unknown)
	c, constant := o.args[1].(Int)
	if !is_x || !same_unknown(y, x) || !constant || c <= 0 do return nil, false
	shift: i128
	#partial switch o.op {
	case .From:
		return op(k, .From, m, op(k, .Mul, Int(c), i)), true
	case .Shr:
		shift = i128(c)
	case .Div:
		// (m / c) / c = m / c², / rounding toward 0 (§4.5), whatever the sign of m
		return op(k, .Div, m, op(k, .Pow, c, i)), true
	case:
		return nil, false
	}
	return op(k, .Shr, m, op(k, .Mul, Int(shift), i)), true
}

// least_law: μ(i: t). When t is kᵢ in B, kᵢ moving by one — down into B = ..b, or
// onto its point b from above; up into b.. —, μ is where it crosses in: the
// distance m - b, or 0 when m is in B already. Moving by c into a half-line, it
// crosses in ⌈distance / c⌉ steps.
least_law :: proc(k: ^Kernel, i: ^Unknown, holds: Type, span: syn.Span) -> Type {
	if is_bool(holds, true) do return Int(0)
	out := new(Least)
	out.index, out.holds, out.span = i, holds, span
	o, is_in := holds.(^Operation)
	if !is_in || o.op != .In do return out
	// μ(i: m from c·i has fewer than c pieces) = |m| / c
	if rest, is_from := o.args[0].(^Operation); is_from && rest.op == .From {
		c, at, along := affine_in(k, rest.args[1], i)
		step, constant := c.(Int)
		if along && constant && step > 0 && is_int(at, 0) && fewer_than(o.args[1], i128(step)) do return op(k, .Div, op(k, .Length, rest.args[0]), Int(step))
	}
	alpha, beta, affine := affine_in(k, o.args[0], i)
	slope, is_int := alpha.(Int)
	if !affine || !is_int || slope == 0 do return out
	one: [1]Type
	cells, negated := cells_in(o.args[1], &one)
	if negated || len(cells) != 1 do return out
	lo, hi := discrete_bounds(cells[0])
	l, has_lo := lo.?
	h, has_hi := hi.?
	// onto a point: only by steps of one
	if has_lo && has_hi && (l != h || slope != 1 && slope != -1) do return out
	gap: Type
	switch {
	case slope < 0 && has_hi:
		gap = op(k, .Sub, beta, Int(h))
		if has_lo && !proven_in(k, gap, COUNTS) do return out // onto the point
	case slope > 0 && has_lo:
		gap = op(k, .Sub, Int(l), beta)
		if has_hi && !proven_in(k, gap, COUNTS) do return out
	case:
		return out
	}
	// by steps of c: the gap in steps, ⌈gap / c⌉ = (gap + c - 1) / c for gap ≥ 0
	c := abs(slope)
	if c != 1 {
		if !proven_in(k, gap, COUNTS) do return out
		return op(k, .Div, op(k, .Add, gap, Int(c - 1)), Int(c))
	}
	// max(gap, 0)
	if proven_in(k, gap, COUNTS) do return gap
	if proven_in(k, gap, NONPOSITIVE) do return Int(0)
	m := new(Pattern)
	m.target, m.span = gap, span
	m.branches = slice.clone([]Branch{{cover = NONPOSITIVE, product = Int(0)}, {product = gap}})
	return pattern_law(k, m)
}

// orbit_index: k, a point of the orbit where the fold goes on: u in its layout,
// out of stop.
orbit_index :: proc(k: ^Kernel, u: ^Unknown, stop: Type) -> ^Unknown {
	index := new_unknown(k, nil)
	index.layout = and_law(k, {layout_of(k, u), not_law(k, stop)})
	return index
}

// op: the normal form of the operation.
op :: proc(k: ^Kernel, o: Operator, args: ..Type) -> Type {
	return normal(k, new_operation(o, ..args))
}

// affine_in: t = α·y + β, α and β not reading y: t of degree 1 in y, by the ring
// law (ring.odin).
affine_in :: proc(k: ^Kernel, t: Type, y: ^Unknown) -> (alpha, beta: Type, ok: bool) {
	// what the ring does not read is an atom: a call, a fold, a pattern
	back: Rewrite
	ms, divisor := monomials(atomized(k, t, &back)) or_return
	if divisor != 1 do return
	as, bs := make([dynamic]Type), make([dynamic]Type)
	for m in ms {
		rest := make([dynamic]^Unknown)
		degree := 0
		for f in factors(m) {
			if same_unknown(f, y) do degree += 1
			else do append(&rest, f)
		}
		switch degree {
		case 0:
			append(&bs, m)
		case 1:
			append(&as, monomial(coefficient(m), rest[:]))
		case:
			return
		}
	}
	alpha = unatomized(ring_term(as[:], 1) or_return, back)
	beta = unatomized(ring_term(bs[:], 1) or_return, back)
	// an atom that holds y: t is not of degree 1 in y
	if reads(k, alpha, y) || reads(k, beta, y) do return nil, nil, false
	return alpha, beta, true
}

// at_calls: a step of the equation, cut at its calls of f: the effects before
// the call, the calls, what the call gives back when the equation has effects —
// then it makes one —, and what follows it. Without effects, what follows is the
// step itself, where each call is a term.
at_calls :: proc(k: ^Kernel, s: ^Scope, r: Type) -> (before: []^Effect, calls: []^Collapse, answer: ^Unknown, after: Type, ok: bool) {
	chain := make([dynamic]^Effect)
	t := r
	for {
		e, is_effect := t.(^Effect)
		if !is_effect do break
		if e.call != nil && e.call.recursive {
			if target, is_scope := e.call.target.(^Scope); is_scope && origin(target) == origin(s) {
				return chain[:], slice.clone([]^Collapse{e.call}), e.answer, e.then, e.answer != nil
			}
		}
		append(&chain, e)
		t = e.then
	}
	if len(chain) > 0 do return
	found := calls_in(k, r, origin(s))
	return nil, found, nil, r, len(found) > 0
}

// calls_in: the recursive calls of root in t, each once.
calls_in :: proc(k: ^Kernel, t: Type, root: ^Scope) -> []^Collapse {
	found := make([dynamic]^Collapse)
	visit :: proc(k: ^Kernel, t: Type, root: ^Scope, found: ^[dynamic]^Collapse) {
		if c, is_call := as_call(t); is_call {
			if s, is_scope := c.target.(^Scope); is_scope && origin(s) == root {
				for x in found do if same(k, x, c) do return
				append(found, c)
			}
			return
		}
		#partial switch v in t {
		case ^Operation:
			for a in v.args do visit(k, a, root, found)
		case ^Pattern:
			visit(k, v.target, root, found)
			for b in v.branches do visit(k, b.product, root, found)
		case ^Or:
			for a in v.terms do visit(k, a, root, found)
		case ^And:
			for a in v.terms do visit(k, a, root, found)
		case ^Not:
			visit(k, v.term, root, found)
		case ^Effect:
			if v.call != nil do visit(k, v.call, root, found)
			if v.choice != nil do visit(k, v.choice, root, found)
			visit(k, v.then, root, found)
		case ^Scope:
			for b in placed(k, v, .Value) do if b.kind != .Product && b.kind != .Handler do visit(k, binding_type(k, b), root, found)
		}
	}
	visit(k, t, root, &found)
	return found[:]
}

// counter_next: what the call c carves the field of u to, and the other fields it
// carves: the states it carries (§5.6).
counter_next :: proc(k: ^Kernel, s: ^Scope, c: ^Collapse, u: ^Unknown) -> (next: Type, carried: map[^Unknown]Type, ok: bool) {
	target, is_scope := c.target.(^Scope)
	if !is_scope || origin(target) != origin(s) do return
	carried = make(map[^Unknown]Type)
	values := make(map[^Unknown]Type)
	for b, v in target.changes do matched(k, binding_type(k, holding(s, b)), v, &values) or_return
	for x, v in values {
		if same_unknown(x, u) do next = v
		else do carried[x] = v
	}
	return next, carried, next != nil
}

// matched: the values of the unknowns of w that make it v: w an unknown, or a call
// of an equation whose carve gives unknowns, v a call of it.
matched :: proc(k: ^Kernel, w, v: Type, out: ^map[^Unknown]Type) -> bool {
	if x, is_unknown := w.(^Unknown); is_unknown {
		out[x] = v
		return true
	}
	g, through := w.(^Collapse)
	c, is_call := v.(^Collapse)
	if !through || !is_call || !g.recursive || !c.recursive do return false
	gs, gok := g.target.(^Scope)
	cs, cok := c.target.(^Scope)
	if !gok || !cok || origin(gs) != origin(cs) do return false
	for b, x in gs.changes {
		y, given := cs.changes[b]
		if !given do y = binding_type(k, holding(cs, b))
		if !matched(k, x, y, out) do return false
	}
	return true
}

// skips: a branch of a pattern of t does not make the call of root that t makes:
// some steps would not.
skips :: proc(t: Type, root: ^Scope) -> bool {
	#partial switch v in t {
	case ^Pattern:
		if solved(v, root) do return false
		if !solved(v.target, root) do return skips(v.target, root)
		for b in v.branches do if solved(b.product, root) || skips(b.product, root) do return true
	case ^Operation:
		for a in v.args do if skips(a, root) do return true
	case ^Or:
		for a in v.terms do if skips(a, root) do return true
	case ^And:
		for a in v.terms do if skips(a, root) do return true
	case ^Not:
		return skips(v.term, root)
	}
	return false
}

// wrap_effects: t, in the effects of the chain, in order.
wrap_effects :: proc(chain: []^Effect, t: Type) -> Type {
	out := t
	#reverse for e in chain do out = wrapped(e, e.answer, out)
	return out
}

// from_base: the fold t, its state from the value of the base case, computed (§4.8).
from_base :: proc(k: ^Kernel, t: Type, parts: []Type) -> Type {
	f := new(Fold)
	f^ = t.(^Fold)^
	f.inits = slice.clone([]Type{parts[0]})
	return folded(k, f)
}

// folded: the fold as a term: by its laws, when it has no effect; otherwise an
// effect that gives it back, bound in what follows. When neither its states nor its
// value read what the effects give back, and the effects do not read the states,
// the states cross them (§4.8): the effects fold alone, then the rest.
folded :: proc(k: ^Kernel, fold: ^Fold) -> Type {
	f := simplified(k, fold)
	if !has_effect(f.effects) do return fold_law(k, f)
	crosses := !has_effect(f.value)
	for x in chain_answers(f.effects) {
		if x == nil do continue
		crosses &&= !reads(k, f.value, x)
		for t in f.updates do crosses &&= !reads(k, t, x)
	}
	for x in f.states do crosses &&= !reads(k, f.effects, x)
	out := new(Effect)
	out.id, out.fold, out.span = -1, f, f.span
	if crosses {
		effects := new(Fold)
		effects^ = f^
		effects.states, effects.inits, effects.updates, effects.value = nil, nil, nil, None{}
		pure := new(Fold)
		pure^ = f^
		pure.effects = None{}
		out.fold, out.then = effects, fold_law(k, pure)
		return out
	}
	if is_none(f.value) {
		out.then = None{}
		return out
	}
	out.answer = new_unknown(k, nil)
	if family, known := family_of(k, f.value); known do out.answer.layout = family_term(family)
	out.then = out.answer
	return out
}

// fold_law: a fold whose steps have no effect, by the laws of folds: what does not
// change is not folded, and a state that adds a polynomial in k along a counter is
// a sum with a closed form (simplified); a fold left with nothing to fold, whose
// value does not read k, is its value, effects included.
fold_law :: proc(k: ^Kernel, f: ^Fold) -> Type {
	// it starts where it stops: no step runs, the value is that of the inits
	if is_bool(in_law(k, f.start, f.stop), true) {
		at := rewriting(nil, f.index, f.start)
		for z, i in f.states do at = rewriting(at, z, f.inits[i])
		return rewrite(k, f.value, at)
	}
	g := simplified(k, f)
	if is_none(g.effects) && len(g.states) == 0 && !reads(k, g.value, g.index) do return g.value
	return g
}

// simplified: the fold, its states reduced by the laws of folds, until none applies:
//
//   a state whose update is itself is its init           x ↦ x
//   a state nothing reads is not folded
//   along a counter, a state read by the value only, whose update is a first-order
//   linear recurrence with constant coefficient, x ↦ r·x + g(k), g a polynomial in
//   k, has a closed form where k stops (closed)
//   along a counter, states whose updates are a linear map with integer
//   coefficients are each a C-finite sequence (linear_states)
simplified :: proc(k: ^Kernel, f: ^Fold) -> ^Fold {
	out := carrying(k, f)
	for changed := true; changed; {
		changed = false
		for x, i in out.states {
			// x: e ↦ u(x), u reading x only and u(e) = e: x is e
			if fixed(k, out, i) {
				out = without_state(k, out, i, out.inits[i])
				changed = true
				break
			}
			read := reads(k, out.value, x) || reads(k, out.effects, x)
			for t, j in out.updates do read ||= j != i && reads(k, t, x)
			if !read {
				out = without_state(k, out, i, nil)
				changed = true
				break
			}
			if !is_none(out.effects) || reads_other_updates(k, out, i) do continue
			if end, closed := closed(k, out, i); closed {
				out = without_state(k, out, i, end)
				changed = true
				break
			}
		}
	}
	if linear, ok := linear_states(k, out); ok do return linear
	// what the laws above leave: calls along the counter tupled, one call for all
	return tupled(k, out)
}

// linear_states: the fold whose states, along a counter of n steps, take a linear
// map with integer coefficients, x ↦ M·x + b: each state is the C-finite sequence
// of the characteristic polynomial of M — b a state of its own, always 1 — by
// Cayley–Hamilton, from its first values (§5.6); the fold is its value, read
// where the states end.
linear_states :: proc(k: ^Kernel, f: ^Fold) -> (folded: ^Fold, ok: bool) {
	if len(f.states) == 0 || !is_none(f.effects) || reads(k, f.value, f.index) do return
	for t in f.updates do if reads(k, t, f.index) do return
	lo, hi := counter_range(k, f) or_return
	n := len(f.states)
	// M, n + 1 square: the last row and column for the constant 1
	m := make([][]i128, n + 1)
	for &row in m do row = make([]i128, n + 1)
	m[n][n] = 1
	affine := false
	for t, i in f.updates {
		ms, d := monomials(t) or_return
		if d != 1 do return
		for mono in ms {
			fs := factors(mono)
			switch len(fs) {
			case 0:
				m[i][n] += coefficient(mono)
				affine = true
			case 1:
				j := -1
				for x, l in f.states do if same_unknown(x, fs[0]) do j = l
				if j < 0 do return
				m[i][j] += coefficient(mono)
			case:
				return
			}
		}
	}
	size := affine ? n + 1 : n
	coefficients := characteristic(m[:size], size) or_return
	// the first values of each state: s₀ the inits, s_{t+1} the updates of s_t
	steps := make([][]Type, size)
	steps[0] = slice.clone(f.inits)
	for t in 1 ..< size {
		r: Rewrite
		for x, j in f.states do r = rewriting(r, x, steps[t - 1][j])
		steps[t] = make([]Type, n)
		for u, j in f.updates do steps[t][j] = rewrite(k, u, r)
	}
	count := op(k, .Add, op(k, .Sub, hi, lo), Int(1))
	ends: Rewrite
	for x, j in f.states {
		seq := new(Recurrent)
		seq.coefficients, seq.at, seq.span = coefficients, count, f.span
		seq.initial = make([]Type, size)
		for t in 0 ..< size do seq.initial[t] = steps[t][j]
		ends = rewriting(ends, x, recurrent_law(k, seq))
	}
	out := new(Fold)
	out^ = f^
	out.states, out.inits, out.updates = nil, nil, nil
	out.value = rewrite(k, f.value, ends)
	return out, true
}

// characteristic: c₁ … c_d with x^d - c₁·x^{d-1} - … - c_d the characteristic
// polynomial of the square matrix m of size d, by Faddeev–LeVerrier:
// M₀ = 0, M_k = m·M_{k-1} + p_{d-k+1}·I, p_{d-k} = -tr(m·M_k) / k.
characteristic :: proc(m: [][]i128, d: int) -> (out: []i128, ok: bool) {
	times :: proc(a, b: [][]i128, d: int) -> (c: [][]i128, ok: bool) {
		c = make([][]i128, d)
		for &row, i in c {
			row = make([]i128, d)
			for j in 0 ..< d do for l in 0 ..< d {
				p := mul_checked(a[i][l], b[l][j]) or_return
				row[j] = add_checked(row[j], p) or_return
			}
		}
		return c, true
	}
	p := make([]i128, d + 1)
	p[d] = 1
	current := make([][]i128, d)
	for &row in current do row = make([]i128, d)
	for step in 1 ..= d {
		current = times(m, current, d) or_return
		for i in 0 ..< d do current[i][i] = add_checked(current[i][i], p[d - step + 1]) or_return
		am := times(m, current, d) or_return
		trace: i128 = 0
		for i in 0 ..< d do trace = add_checked(trace, am[i][i]) or_return
		if trace % i128(step) != 0 do return nil, false
		p[d - step] = -trace / i128(step)
	}
	out = make([]i128, d)
	for j in 1 ..= d do out[j - 1] = -p[d - j]
	return out, true
}

// recurrent_law: C⟨c₁ … c_d | x₀ … x_{d-1}⟩(s), by its laws:
//
//   s known                  x_s = Σ_j x_j·[αˢ]_j, αˢ by squaring in ℤ[α]
//   d = 1                    x₀ * c₁ ** s
//   d = 2, Δ = c₁² + 4·c₂ a square, the roots r = (c₁ ± √Δ) / 2 integers:
//     r₁ ≠ r₂                x_s = A * r₁ ** s + B * r₂ ** s
//     r₁ = r₂ = r            x_s = (A + B * s) * r ** s
//   A and B from x₀ and x₁, the closed form preferred to the power
recurrent_law :: proc(k: ^Kernel, r: ^Recurrent) -> Type {
	d := len(r.coefficients)
	if s, known := r.at.(Int); known && s >= 0 {
		if int(s) < d do return r.initial[s]
		if power, ok := algebraic_power(r.coefficients, i128(s)); ok {
			out: Type = Int(0)
			for x, j in r.initial do out = op(k, .Add, out, op(k, .Mul, x, Int(power[j])))
			return out
		}
	}
	if d == 1 do return op(k, .Mul, r.initial[0], op(k, .Pow, Int(r.coefficients[0]), r.at))
	if d == 2 {
		c1, c2 := r.coefficients[0], r.coefficients[1]
		x0, x1 := r.initial[0], r.initial[1]
		disc := c1 * c1 + 4 * c2
		root, square := integer_sqrt(disc)
		if square && (c1 + root) % 2 == 0 {
			r1, r2 := (c1 + root) / 2, (c1 - root) / 2
			if r1 != r2 {
				// A + B = x₀, A·r₁ + B·r₂ = x₁
				b := op(k, .Div, op(k, .Sub, x1, op(k, .Mul, Int(r1), x0)), Int(r2 - r1))
				a := op(k, .Sub, x0, b)
				return op(k, .Add, op(k, .Mul, a, op(k, .Pow, Int(r1), r.at)), op(k, .Mul, b, op(k, .Pow, Int(r2), r.at)))
			}
			if r1 != 0 {
				// A = x₀, (A + B)·r = x₁
				b := op(k, .Sub, op(k, .Div, x1, Int(r1)), x0)
				return op(k, .Mul, op(k, .Add, x0, op(k, .Mul, b, r.at)), op(k, .Pow, Int(r1), r.at))
			}
		}
	}
	return r
}

// integer_sqrt: the root of n, when n is a square: Newton's iteration on the
// integers, r ↦ (r + n / r) / 2, from n down.
integer_sqrt :: proc(n: i128) -> (root: i128, square: bool) {
	if n < 2 do return n, n >= 0
	r := n
	for next := (r + n / r) / 2; next < r; next = (r + n / r) / 2 do r = next
	return r, r * r == n
}

// algebraic_power: the coordinates of αˢ in ℤ[α], α a root of x^d - c₁·x^{d-1}
// - … - c_d, by squaring: a product is reduced by α^d = c₁·α^{d-1} + … + c_d.
algebraic_power :: proc(c: []i128, s: i128) -> (out: []i128, ok: bool) {
	d := len(c)
	product :: proc(a, b, c: []i128) -> (out: []i128, ok: bool) {
		d := len(c)
		full := make([]i128, 2 * d - 1)
		for x, i in a do for y, j in b {
			p := mul_checked(x, y) or_return
			full[i + j] = add_checked(full[i + j], p) or_return
		}
		#reverse for _, t in full {
			if t < d do break
			for cj, j in c {
				p := mul_checked(full[t], cj) or_return
				full[t - 1 - j] = add_checked(full[t - 1 - j], p) or_return
			}
			full[t] = 0
		}
		return slice.clone(full[:d]), true
	}
	out = make([]i128, d)
	out[0] = 1
	base := make([]i128, d)
	if d == 1 do base[0] = c[0]
	else do base[1] = 1
	for e := s; e > 0; e >>= 1 {
		if e & 1 == 1 do out = product(out, base, c) or_return
		if e > 1 do base = product(base, base, c) or_return
	}
	return out, true
}

// reads_other_updates: another state's update reads the state i.
reads_other_updates :: proc(k: ^Kernel, f: ^Fold, i: int) -> bool {
	for t, j in f.updates do if j != i && reads(k, t, f.states[i]) do return true
	return false
}

// without_state: the fold without its state i, which reads `by` where it was;
// nil when nothing reads it.
without_state :: proc(k: ^Kernel, f: ^Fold, i: int, by: Type) -> ^Fold {
	parts := fold_parts(f)
	if by != nil {
		r := rewriting(nil, f.states[i], by)
		for &t in parts do t = rewrite(k, t, r)
	}
	out := with_parts(f, parts)
	states := make([dynamic]^Unknown)
	inits := make([dynamic]Type)
	updates := make([dynamic]Type)
	for j in 0 ..< len(f.states) {
		if j == i do continue
		append(&states, f.states[j])
		append(&inits, out.inits[j])
		append(&updates, out.updates[j])
	}
	out.states, out.inits, out.updates = states[:], inits[:], updates[:]
	return out
}

// closed: the state i where k stops, along a counter, when its update is
// x ↦ r·x + g(k), r an integer and g a polynomial in k over the other unknowns but
// the states. With t the number of steps taken, k = lo + t going up or hi - t
// going down, and n = hi - lo + 1 of them:
//
//   r = 1         x = x₀ + G(hi) - G(lo - 1)     G(m) = g(0) + … + g(m), by the
//                                                 sums of powers (Faulhaber)
//   r ≠ 1         x = P(n) + (x₀ - P(0))·rⁿ     P the polynomial with
//                                                 P(t + 1) = r·P(t) + g(t), by its
//                                                 coefficients (undetermined)
//
// The ring computes on lo, hi and x₀ as polynomials over atoms (atomized), put
// back at the end.
closed :: proc(k: ^Kernel, f: ^Fold, i: int) -> (end: Type, ok: bool) {
	first, last := counter_range(k, f) or_return
	x := f.states[i]
	// the update over atoms, none of which reads a state
	parts: Rewrite
	update := atomized(k, f.updates[i], &parts)
	for a in parts do for y in f.states do if reads(k, a.term, y) do return
	alpha, beta := affine_in(k, update, x) or_return
	alpha, beta = rewrite(k, alpha, parts), rewrite(k, beta, parts)
	for y in f.states do if reads(k, alpha, y) || reads(k, beta, y) do return
	r, constant := alpha.(Int)
	switch {
	case constant && r == 1:
		// x ↦ x + g(k): x₀ + Σ g
		return op(k, .Add, f.inits[i], series(k, .Add, f.index, first, last, beta)), true
	case same(k, beta, Int(0)) && reads(k, alpha, f.index):
		// x ↦ α(k)·x: x₀ · Π α
		return op(k, .Mul, f.inits[i], series(k, .Mul, f.index, first, last, alpha)), true
	case !constant || !is_ring(beta):
		return
	}
	bounds: Rewrite
	lo, hi := atomized(k, first, &bounds), atomized(k, last, &bounds)
	init := atomized(k, f.inits[i], &bounds)
	g := beta
	ms, divisor := monomials(g) or_return
	// g in t, the steps taken
	t := new_unknown(k, nil)
	t.layout = COUNTS
	place: Type
	if same(k, f.next, op(k, .Add, f.index, Int(1))) do place = ring_law(.Add, {lo, t}) or_return
	else do place = ring_law(.Sub, {hi, t}) or_return
	gt := rewrite(k, ring_over(g, divisor) or_return, rewriting(nil, f.index, place))
	// its coefficients by the powers of t
	tms, td := monomials(gt) or_return
	degree := 0
	for m in tms {
		p := 0
		for u in factors(m) do if same_unknown(u, t) do p += 1
		degree = max(degree, p)
	}
	coefficients := make([]Type, degree + 1)
	for &c in coefficients do c = Int(0)
	for m in tms {
		p := 0
		others := make([dynamic]^Unknown)
		for u in factors(m) {
			if same_unknown(u, t) do p += 1
			else do append(&others, u)
		}
		coefficients[p] = ring_law(.Add, {coefficients[p], monomial(coefficient(m), others[:])}) or_return
	}
	for &c in coefficients do c = ring_over(c, td) or_return
	// P(t + 1) - r·P(t) = g(t): from the highest power down,
	// pₑ = (Σ_{d>e} C(d, e)·p_d - gₑ) / (r - 1)
	ps := make([]Type, degree + 1)
	#reverse for _, e in ps {
		acc := ring_law(.Neg, {coefficients[e]}) or_return
		for d in e + 1 ..= degree do acc = ring_law(.Add, {acc, ring_law(.Mul, {Int(binomial(d, e)), ps[d]}) or_return}) or_return
		if r < 1 do acc = ring_law(.Neg, {acc}) or_return
		ps[e] = ring_over(acc, abs(i128(r) - 1)) or_return
	}
	poly: Type = Int(0)
	tᵉ: Type = Int(1)
	for pe in ps {
		poly = ring_law(.Add, {poly, ring_law(.Mul, {pe, tᵉ}) or_return}) or_return
		tᵉ = ring_law(.Mul, {tᵉ, t}) or_return
	}
	n := ring_law(.Add, {ring_law(.Sub, {hi, lo}) or_return, Int(1)}) or_return
	at_n := ring_at(poly, t, n) or_return
	at_0 := ring_at(poly, t, Int(0)) or_return
	// rⁿ an atom, so that the whole is one polynomial over one divisor: its parts
	// alone need not be integers
	rⁿ := atomized(k, op(k, .Pow, r, rewrite(k, n, bounds)), &bounds)
	start := ring_law(.Sub, {init, at_0}) or_return
	whole := ring_law(.Add, {at_n, ring_law(.Mul, {start, rⁿ}) or_return}) or_return
	return rewrite(k, whole, bounds), true
}

// ring_at: the polynomial t with u replaced by v, in the ring: over its divisor,
// whatever its parts are worth alone.
ring_at :: proc(t: Type, u: ^Unknown, v: Type) -> (out: Type, ok: bool) {
	ms, d := monomials(t) or_return
	out = Int(0)
	for m in ms {
		term: Type = Int(coefficient(m))
		for f in factors(m) do term = ring_law(.Mul, {term, same_unknown(f, u) ? v : f}) or_return
		out = ring_law(.Add, {out, term}) or_return
	}
	return ring_over(out, d)
}

// atomized: t as a polynomial (ring.odin) over atoms: each term the ring does not
// read — a μ, a pattern — is named by an unknown of its own, which back rewrites to
// it. In the field (ring.odin), over the reals.
atomized :: proc(k: ^Kernel, t: Type, back: ^Rewrite, field := false) -> Type {
	#partial switch v in t {
	case ^Unknown:
		return t
	case Int:
		if !field do return t
	case Real:
		if field do return t
	case ^Operation:
		#partial switch v.op {
		case .Add, .Sub, .Mul:
			out := atomized(k, v.args[0], back, field)
			for a in v.args[1:] {
				next, ok := ring_law(v.op, {out, atomized(k, a, back, field)}, field)
				if !ok do break
				out = next
			}
			if _, _, ring := monomials(out, field); ring do return out
		case .Neg:
			if out, ok := ring_law(.Neg, {atomized(k, v.args[0], back, field)}, field); ok do return out
		}
	}
	for x in back do if x.unknown != nil && same(k, x.term, t) do return x.unknown
	u := new_unknown(k, nil)
	u.layout = family_term(field ? .Real : .Int)
	back^ = rewriting(back^, u, t)
	return u
}

// is_ring: t is a polynomial (ring.odin).
is_ring :: proc(t: Type) -> bool {
	_, _, ok := monomials(t)
	return ok
}

// series: Σ(j: lo..hi, t) or Π, with j for the index i of t, by their laws.
series :: proc(k: ^Kernel, o: Operator, i: ^Unknown, lo, hi, t: Type) -> Type {
	s := new(Series)
	s.op, s.lo, s.hi = o, lo, hi
	// the index takes the values lo..hi
	s.index = new_unknown(k, nil)
	s.index.layout = range_law(k, lo, hi, .Int, {})
	s.term = rewrite(k, t, rewriting(nil, i, s.index))
	return series_law(k, s)
}

// series_law: Σ(i: lo..hi, t) and Π(i: lo..hi, t), by their laws:
//
//   over an empty range                    0, 1
//   Σ, t a polynomial in i over atoms      G(hi) - G(lo - 1), G(m) = t(0) + … + t(m),
//                                          by the sums of powers (Faulhaber)
//   Π, t not reading i                     t ** n, n = hi - lo + 1
//   Π, t = c·uᵃ·iᵖ…, a monomial            cⁿ·(u ** n)ᵃ·(Π(i: lo..hi, i))ᵖ…
//   Π, c the content of t, > 1             cⁿ·Π(i: lo..hi, t / c)
//   Π, t = ±i + b                          Π(j: lo'..hi', j), over the integers
//                                          t runs through, upward
//   Π(j: a..b, j), a ≤ 0 ≤ b               0
series_law :: proc(k: ^Kernel, s: ^Series) -> Type {
	identity: Type = s.op == .Add ? Type(Int(0)) : Type(Int(1))
	n := op(k, .Add, op(k, .Sub, s.hi, s.lo), Int(1))
	if proven_in(k, n, NONPOSITIVE) do return identity
	if s.op == .Add {
		if sum, closed := faulhaber(k, s); closed do return sum
		if x, bitwise := bitwise_sum(k, s); bitwise do return x
		if f, summed := summed_fold(k, s); summed do return f
		if f, summed := summed_call(k, s); summed do return f
		// a Σ that reads, along its index, a run a fold builds is the fold that
		// carries it: the run is never built
		if f, carried := carried_sum(k, s); carried do return f
		return s
	}
	if !reads(k, s.term, s.index) do return op(k, .Pow, s.term, n)
	if ms, d, ring := monomials(s.term); ring && len(ms) == 1 && d == 1 {
		m := ms[0]
		p := 0
		out := op(k, .Pow, Int(coefficient(m)), n)
		for u in factors(m) {
			if same_unknown(u, s.index) do p += 1
			else do out = op(k, .Mul, out, op(k, .Pow, u, n))
		}
		if p > 0 && !(p == 1 && len(factors(m)) == 1 && coefficient(m) == 1) {
			ascending := new(Series)
			ascending^ = s^
			ascending.term = s.index
			return op(k, .Mul, out, op(k, .Pow, series_law(k, ascending), Int(p)))
		}
	}
	if ms, d, ring := monomials(s.term); ring && d == 1 {
		content: i128 = 0
		for m in ms do content = gcd(content, abs(coefficient(m)))
		if content > 1 {
			reduced := make([]Type, len(ms))
			for m, j in ms do reduced[j] = monomial(coefficient(m) / content, factors(m))
			if t, ok := ring_term(reduced, 1); ok {
				primitive := new(Series)
				primitive^ = s^
				primitive.term = t
				return op(k, .Mul, op(k, .Pow, Int(content), n), series_law(k, primitive))
			}
		}
	}
	if alpha, beta, affine := affine_in(k, s.term, s.index); affine {
		if a, unit := alpha.(Int); unit && (a == 1 || a == -1) && !(a == 1 && same(k, beta, Int(0))) {
			// j = ±i + b runs through the integers between its ends
			from, to := op(k, .Add, op(k, .Mul, a, s.lo), beta), op(k, .Add, op(k, .Mul, a, s.hi), beta)
			if a < 0 do from, to = to, from
			upward := new(Series)
			upward^ = s^
			upward.lo, upward.hi, upward.term = from, to, s.index
			return series_law(k, upward)
		}
	}
	if same(k, s.term, s.index) && proven_in(k, s.lo, NONPOSITIVE) && proven_in(k, s.hi, COUNTS) do return Int(0)
	return s
}

// faulhaber: Σ(i: lo..hi, t), t a polynomial in i over atoms that do not read i:
// G(hi) - G(lo - 1), each monomial c·q·iᵖ giving c·q·Sₚ, the sums of powers.
faulhaber :: proc(k: ^Kernel, s: ^Series) -> (sum: Type, ok: bool) {
	bounds: Rewrite
	t := atomized(k, s.term, &bounds)
	for a in bounds do if reads(k, a.term, s.index) do return
	lo, hi := atomized(k, s.lo, &bounds), atomized(k, s.hi, &bounds)
	ms, divisor := monomials(t) or_return
	degree := 0
	for m in ms {
		p := 0
		for u in factors(m) do if same_unknown(u, s.index) do p += 1
		degree = max(degree, p)
	}
	sums := power_sums(s.index, degree) or_return
	total: Type = Int(0)
	for m in ms {
		p := 0
		others := make([dynamic]^Unknown)
		for u in factors(m) {
			if same_unknown(u, s.index) do p += 1
			else do append(&others, u)
		}
		term := ring_law(.Mul, {monomial(coefficient(m), others[:]), sums[p]}) or_return
		total = ring_law(.Add, {total, term}) or_return
	}
	total = ring_over(total, divisor) or_return
	upper := ring_at(total, s.index, hi) or_return
	lower := ring_at(total, s.index, ring_law(.Sub, {lo, Int(1)}) or_return) or_return
	return rewrite(k, ring_law(.Sub, {upper, lower}) or_return, bounds), true
}

// counter_range: the steps of a fold whose index moves by one between lo and hi:
// up from lo, until it reaches hi + 1.., or down from hi, until ..lo - 1.
counter_range :: proc(k: ^Kernel, f: ^Fold) -> (lo, hi: Type, ok: bool) {
	r := f.stop.(^Range) or_return
	if same(k, f.next, op(k, .Add, f.index, Int(1))) && r.lo != nil && r.hi == nil {
		return f.start, op(k, .Sub, r.lo, Int(1)), true
	}
	if same(k, f.next, op(k, .Sub, f.index, Int(1))) && r.hi != nil && r.lo == nil {
		return op(k, .Add, r.hi, Int(1)), f.start, true
	}
	return
}

// ring_over: t / d, d ≥ 1, over the divisor of the sum.
ring_over :: proc(t: Type, d: i128) -> (out: Type, ok: bool) {
	ms, e := monomials(t) or_return
	ed := mul_checked(e, d) or_return
	return ring_term(ms, ed)
}
binomial :: proc(n, r: int) -> i128 {
	out: i128 = 1
	for i in 0 ..< r do out = out * i128(n - i) / i128(i + 1)
	return out
}

// power_sums: S_0 … S_d, S_p(m) = 0^p + 1^p + … + m^p, from
// C(p+1, 0) S_0 + … + C(p+1, p) S_p = (m + 1)^(p+1).
power_sums :: proc(u: ^Unknown, d: int) -> (out: []Type, ok: bool) {
	out = make([]Type, d + 1)
	next := ring_law(.Add, {u, Int(1)}) or_return
	for p in 0 ..= d {
		acc: Type = Int(1)
		for _ in 0 ..= p do acc = ring_law(.Mul, {acc, next}) or_return
		for j in 0 ..< p {
			term := ring_law(.Mul, {Int(binomial(p + 1, j)), out[j]}) or_return
			acc = ring_law(.Sub, {acc, term}) or_return
		}
		out[p] = ring_over(acc, i128(p + 1)) or_return
	}
	return out, true
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
		if every do return runs_of(pieces, Int(0), Int(c - 1), cover), true
	}
	if c != 1 || !included(k, item, or_law(k, heads[:])) do return
	return runs_of(pieces, Int(0), Int(0), cover), true
}

// runs_of: the runs of lo..hi pieces, hi nil for no bound.
runs_of :: proc(pieces, lo, hi: Type, at: Type) -> ^Scope {
	span := syn.Span{}
	if written, is_scope := at.(^Scope); is_scope do span = written.span
	out := new_scope(nil, span)
	out.source, out.complete, out.reached = out, true, true
	run := new_binding(out, .Expand, span)
	run.color = new_operation(.Mul, pieces, new_range(lo, hi, .Int))
	run.typed_color = run.color
	return out
}

// built: f builds a run, c bindings a step along a counter from 0: its value is
// the state y, {} at first, {...y  e₀ … e_{c-1}} at each step. The binding c·i + j
// of the run is eⱼ at step i.
built :: proc(k: ^Kernel, f: ^Fold) -> (y: int, es: []Type, ok: bool) {
	lo, _ := counter_range(k, f) or_return
	if !is_int(lo, 0) || !same(k, f.next, op(k, .Add, f.index, Int(1))) || !is_none(f.effects) do return
	for z, i in f.states {
		if !same(k, f.value, z) do continue
		start, is_scope := given(k, f.inits[i]).(^Scope)
		step, is_step := f.updates[i].(^Scope)
		if !is_scope || !is_step || len(run_data(k, start)) != 0 do return
		data := run_data(k, step)
		if len(data) < 2 || data[0].kind != .Expand || !same(k, binding_value(k, data[0]), z) do return
		out := make([]Type, len(data) - 1)
		for d, j in data[1:] {
			if d.kind == .Expand do return
			out[j] = binding_value(k, d)
			if reads(k, out[j], z) do return
		}
		for t, j in f.updates do if j != i && reads(k, t, z) do return
		return i, out, true
	}
	return
}

// carried_sum: Σ(i: lo..hi, t) as the fold ⟳(i: lo ↦ i + 1 until (hi + 1)..;
// x: 0 ↦ x + t; x), when t reads a run a fold builds along i: that fold carries it.
carried_sum :: proc(k: ^Kernel, s: ^Series) -> (Type, bool) {
	f := new(Fold)
	f.index, f.span = s.index, s.span
	f.start, f.next, f.stop = s.lo, op(k, .Add, s.index, Int(1)), new_range(op(k, .Add, s.hi, Int(1)), nil, .Int)
	x := new_unknown(k, nil)
	x.layout = family_term(.Int)
	f.states, f.inits, f.updates = slice.clone([]^Unknown{x}), slice.clone([]Type{Int(0)}), slice.clone([]Type{op(k, .Add, x, s.term)})
	f.value, f.effects = x, None{}
	if b, _ := run_reads(k, f); b == nil do return nil, false
	return folded(k, f), true
}

// carrying: f reads, at its step i counted from 0, the bindings c·i + j of a run a
// fold builds c a step: it carries the states of that fold beside its own, and the
// binding c·i + j is what that fold gives at step i. The run is never built.
carrying :: proc(k: ^Kernel, f: ^Fold) -> ^Fold {
	lo, _, counts := counter_range(k, f)
	if !counts || !is_int(lo, 0) || !same(k, f.next, op(k, .Add, f.index, Int(1))) do return f
	b, reads := run_reads(k, f)
	if b == nil do return f
	y, es, _ := built(k, b)
	along := rewriting(nil, b.index, f.index)
	states, inits := make([dynamic]^Unknown), make([dynamic]Type)
	append(&states, ..f.states)
	append(&inits, ..f.inits)
	for z, j in b.states {
		if j == y do continue
		w := new_unknown(k, nil)
		w.layout = layout_of(k, z)
		along = rewriting(along, z, w)
		append(&states, w)
		append(&inits, b.inits[j])
	}
	reading: Rewrite
	for r in reads do reading = append_read(reading, r.read, rewrite(k, es[r.at], along))
	parts := fold_parts(f)
	for &t in parts do t = rewrite(k, t, reading)
	out := with_parts(f, parts)
	updates := make([dynamic]Type)
	append(&updates, ..out.updates)
	for z, j in b.states do if j != y do append(&updates, rewrite(k, b.updates[j], along))
	out.states, out.inits, out.updates = states[:], inits[:], updates[:]
	return carrying(k, out)
}

Run_Read :: struct {
	read: ^Operation,
	at:   int, // j: the read is of the binding c·i + j
}

append_read :: proc(r: Rewrite, read: Type, t: Type) -> Rewrite {
	out := make([dynamic]Rewriting)
	append(&out, ..r)
	append(&out, Rewriting{read = read, term = t})
	return out[:]
}

// run_reads: a run a fold builds c a step that f reads at its index i, x.#(c·i + j)
// with j in 0..c - 1, and all those reads; nil when there is none, or when one
// reads it elsewhere.
run_reads :: proc(k: ^Kernel, f: ^Fold) -> (b: ^Fold, reads: []Run_Read) {
	found := make([dynamic]Run_Read)
	visit :: proc(k: ^Kernel, t: Type, i: ^Unknown, b: ^^Fold, found: ^[dynamic]Run_Read) {
		if t == nil do return
		if o, is_op := t.(^Operation); is_op && o.op == .Item {
			if x, is_fold := o.args[0].(^Fold); is_fold && (b^ == nil || same(k, b^, x)) {
				if _, es, builds := built(k, x); builds {
					c, j, along := affine_in(k, o.args[1], i)
					step, by := c.(Int)
					at, constant := j.(Int)
					if along && by && constant && int(step) == len(es) && at >= 0 && int(at) < len(es) {
						b^ = x
						append(found, Run_Read{o, int(at)})
						return
					}
				}
			}
		}
		for x in parts(t) do visit(k, x, i, b, found)
		if p, is_pattern := t.(^Pattern); is_pattern do for br in p.branches do visit(k, br.product, i, b, found)
	}
	for t in fold_parts(f) do visit(k, t, f.index, &b, &found)
	return b, found[:]
}

// summed_fold: Σ(j: lo..hi, ⟳(…; x: 0 ↦ x + g; x)) = ⟳(…; x: 0 ↦ x + Σ(j: lo..hi, g); x),
// when nothing else in the fold reads j: a sum of sums is the sum of their terms.
summed_fold :: proc(k: ^Kernel, s: ^Series) -> (out: Type, ok: bool) {
	f := s.term.(^Fold) or_return
	if !is_none(f.effects) do return
	x := -1
	for z, i in f.states do if same(k, f.value, z) do x = i
	if x < 0 || !is_int(f.inits[x], 0) do return
	sum := f.updates[x].(^Operation) or_return
	if sum.op != .Add do return
	rest := make([dynamic]Type)
	held := false
	for a in sum.args {
		if z, is_state := a.(^Unknown); is_state && !held && same_unknown(z, f.states[x]) do held = true
		else do append(&rest, a)
	}
	if !held || len(rest) == 0 do return
	g := len(rest) == 1 ? rest[0] : op(k, .Add, ..rest[:])
	if reads(k, g, f.states[x]) do return
	for t, i in fold_parts(f) do if t != nil && i != 4 + len(f.states) + x && reads(k, t, s.index) do return
	inner := new(Series)
	inner^ = s^
	inner.term = g
	g2 := new(Fold)
	g2^ = f^
	g2.updates = slice.clone(f.updates)
	g2.updates[x] = op(k, .Add, f.states[x], series_law(k, inner))
	return fold_law(k, g2), true
}

// call_image: the values of a call that stays are bounded by the recursion of its
// bounds (§5.6). The bounds lo, hi of what the call gives are unknowns: its
// equation, each call in it taken in lo..hi and every other term at its own image,
// gives equations on them — hi the greatest of what its products give, lo the
// least —, solved in closed form. On a counter, the bounds are functions of it:
// y ↦ α·y + max(g) from max(c), the least likewise, folds solved by their laws.
// Otherwise the narrowest range the equations admit, proven by induction (call_in):
// the solving only proposes it. Its length likewise: an operator on a pattern is the
// pattern of the operator on its products (§6), |{...x r}| = |x| + 1 (§5.3), each
// call's length taken in lo..hi.
Measure_Kind :: enum u8 {
	Value,
	Length,
	Sum,
}

// Measure: what is bounded of what a call gives: its value; its length; or the sum
// over its bindings Σ(x: 0..|X| - 1, g(X.#x)), g a term over the unknown at.
Measure :: struct {
	kind: Measure_Kind,
	g:    Type,
	at:   ^Unknown,
}

LENGTH :: Measure{kind = .Length}

same_measure :: proc(k: ^Kernel, a, b: Measure) -> bool {
	if a.kind != b.kind do return false
	return a.kind != .Sum || same(k, rewrite(k, a.g, rewriting(nil, a.at, b.at)), b.g)
}

Image :: struct {
	equation: ^Call_Equation,
	measure:  Measure,
	kept:     []Type, // what the fields every call keeps hold at the call
	bounds:   Bounds,
	ok:       bool,
	given:    bool, // false while it is given
	at:       [dynamic]Image_At, // the bounds read at a count of steps
}

Image_At :: struct {
	key:   []Type,
	image: Type,
	ok:    bool,
}

// Bounds: lo..hi; on a counter, functions of the count of steps, which is steps — or
// any number up to it —, a term of what the call carves.
Bounds :: struct {
	lo, hi: Type,
	count:  ^Unknown,
	steps:  Type,
	upto:   bool,
}

// bounds_at: the bounds at the count of steps the call makes.
bounds_at :: proc(k: ^Kernel, b: Bounds, steps: Type) -> (image: Type, ok: bool) {
	if b.count == nil do return range_law(k, b.lo, b.hi, .Int, {}), true
	steps := steps
	if b.upto {
		most := layout_image(k, steps) or_return
		_, top := int_bounds(k, most) or_return
		any := new_unknown(k, nil)
		any.layout = range_law(k, Int(0), Int(top.? or_return), .Int, {})
		steps = any
	}
	at := rewriting(nil, b.count, steps)
	hi := layout_image(k, rewrite(k, b.hi, at)) or_return
	lo := layout_image(k, rewrite(k, b.lo, at)) or_return
	_, top := int_bounds(k, hi) or_return
	least, _ := int_bounds(k, lo) or_return
	return range_law(k, Int(least.? or_return), Int(top.? or_return), .Int, {}), true
}

call_image :: proc(k: ^Kernel, call: ^Collapse, measure := Measure{}) -> (image: Type, ok: bool) {
	s := call.target.(^Scope) or_return
	if !call.recursive do return
	root := origin(s)
	// while the equation, or one it reads through, is read, its calls are the
	// hypothesis: no bounds yet
	if reading(k, root) do return
	eq := equation_of(k, call) or_return
	for t in eq.through do if reading(k, t.equation.root) do return
	// the bounds depend on the equation the call reads, and on what the fields its
	// calls keep hold: given once; while they are given, its calls are the
	// hypothesis
	for x in k.images do if x.equation == eq && same_measure(k, x.measure, measure) && !x.given do return
	at := len(k.images)
	append(&k.images, Image{equation = eq, measure = measure})
	e, values, kept := kept_fields(k, call, eq)
	next: for &x in k.images[:at] {
		if x.equation != eq || !same_measure(k, x.measure, measure) || len(x.kept) != len(kept) do continue
		for t, i in kept do if !same(k, t, x.kept[i]) do continue next
		ordered_remove(&k.images, at)
		if !x.ok do return
		return images_at(k, &x, values)
	}
	// an equation holding a term of no type bounds nothing
	bounds: Bounds
	if !holds_invalid(e) {
		if measure.kind != .Sum {
			measured := measure.kind == .Length ? run_law(k, .Length, {e}, eq.root.span) : e
			bounds, ok = counter_bounds(k, eq, measured, measure)
			if !ok do bounds, ok = least_bounds(k, eq, measured, measure)
		}
		// as functions of what the call carves: a side left open taken from them, both
		// bounds holding
		if !ok || bounds.count == nil && (bounds.lo == nil || bounds.hi == nil) {
			if linear, read := linear_bounds(k, eq, e, measure); read {
				if !ok do bounds = linear
				if bounds.lo == nil do bounds.lo = linear.lo
				if bounds.hi == nil do bounds.hi = linear.hi
				ok = true
			}
		}
	}
	k.images[at] = Image{eq, measure, kept, bounds, ok, true, nil}
	if !ok do return
	return images_at(k, &k.images[at], values)
}

// images_at: the bounds of the entry at the values a call gives, read once for them.
images_at :: proc(k: ^Kernel, x: ^Image, values: Rewrite) -> (image: Type, ok: bool) {
	// what the bounds read of the values: the count of steps, or the fields they are
	// functions of
	key := make([dynamic]Type)
	for v in values {
		if v.unknown == nil do continue
		read := x.bounds.count != nil ? reads(k, x.bounds.steps, v.unknown) : x.bounds.lo != nil && reads(k, x.bounds.lo, v.unknown) || x.bounds.hi != nil && reads(k, x.bounds.hi, v.unknown)
		if read do append(&key, v.term)
	}
	// the very terms first; terms equal to those of an entry are read as its terms
	// from then on
	identical: for a in x.at {
		for t, i in key do if t != a.key[i] do continue identical
		return a.image, a.ok
	}
	equal: for a in x.at {
		for t, i in key do if !same(k, t, a.key[i]) do continue equal
		append(&x.at, Image_At{key[:], a.image, a.ok})
		return a.image, a.ok
	}
	if x.bounds.count == nil do image, ok = linear_at(k, x.bounds, values)
	else do image, ok = bounds_at(k, x.bounds, rewrite(k, x.bounds.steps, values))
	append(&x.at, Image_At{key[:], image, ok})
	return
}

// kept_fields: the equation the call reads, where each field that every call of it
// keeps — carves to itself, or not at all — holds what the call gives it (§5.3: a
// carve is the equation at the values it gives): an unknown of that image. values:
// each field at what the call gives it; key: the images of those kept.
kept_fields :: proc(k: ^Kernel, call: ^Collapse, eq: ^Call_Equation) -> (e: Type, values: Rewrite, key: []Type) {
	values = at_values(k, eq, call.target.(^Scope).changes)
	moved := make([dynamic]^Unknown)
	all_moved := false
	for x in calls_in(k, eq.equation, eq.root) {
		target := x.target.(^Scope)
		carved := make(map[^Unknown]Type)
		for b, v in target.changes do all_moved ||= !matched(k, binding_type(k, holding(eq.generic, b)), v, &carved)
		for u, v in carved {
			w, is_unknown := v.(^Unknown)
			if !is_unknown || !same_unknown(u, w) do append(&moved, u)
		}
	}
	r: Rewrite
	out := make([dynamic]Type)
	for x in values {
		if x.unknown == nil do continue
		kept := !all_moved
		for u in moved do kept &&= !same_unknown(u, x.unknown)
		if !kept do continue
		image, known := layout_image(k, x.term)
		if !known || !is_constant(image) do continue
		r = rewriting(r, x.unknown, narrowing(x.unknown, image))
		append(&out, image)
	}
	return rewrite(k, eq.equation, r), values, out[:]
}

// orbit_length: the length n of the orbit of u by step until stop, in closed form:
// μ(i: kᵢ in stop), kᵢ = stepⁱ(u) (§5.6).
orbit_length :: proc(k: ^Kernel, u: ^Unknown, step, stop: Type, span: syn.Span) -> (n: Type, ok: bool) {
	x := orbit_index(k, u, stop)
	i := new_unknown(k, nil)
	i.layout = COUNTS
	ki := orbit(k, rewrite(k, step, rewriting(nil, u, x)), x, u, i) or_return
	j := new_unknown(k, nil)
	j.layout = COUNTS
	return least_law(k, j, in_law(k, rewrite(k, ki, rewriting(nil, i, j)), stop), span), true
}

// Bound_Product: a product of the equation, its calls taken at one bound y: g,
// reading none (a = 0), α·y + g, α ≥ 0 — g between lo and hi —; or x % m, m > 0
// constant, which lies in -(m - 1)..m - 1 whatever x, and in 0..m - 1 when x ≥ 0.
Bound_Product :: struct {
	a:       i128,
	lo, hi:  Maybe(i128),
	modulus: i128,
}

bound_product :: proc(k: ^Kernel, t: Type, y: ^Unknown) -> (p: Bound_Product, ok: bool) {
	if o, is_op := t.(^Operation); is_op && o.op == .Mod && reads(k, o.args[0], y) {
		if m, constant := o.args[1].(Int); constant && m > 0 && !reads(k, o.args[1], y) do return {modulus = i128(m)}, true
	}
	alpha, beta := affine_in(k, t, y) or_return
	a := alpha.(Int) or_return
	if a < 0 do return
	image := layout_image(k, beta) or_return
	lo, hi := int_bounds(k, image) or_return
	return {a = i128(a), lo = lo, hi = hi}, true
}

// measured: the measure of t, each call of root taken at to: the call itself, or
// its length; false when t reads a call otherwise.
measured :: proc(k: ^Kernel, t: Type, root: ^Scope, measure: Measure, to: Type) -> (out: Type, ok: bool) {
	at: Rewrite
	for x in calls_in(k, t, root) {
		if measure.kind == .Value do at = rewriting_call(at, x, to)
		else do at = append_read(at, new_operation(.Length, x), to)
	}
	out = rewrite(k, t, at)
	return out, solved(out, root)
}

// at_bound: the products of t, each call of root in it taken at y.
at_bound :: proc(k: ^Kernel, t: Type, root: ^Scope, measure: Measure, y: ^Unknown) -> (out: []Bound_Product, ok: bool) {
	leaves := make([dynamic]Product)
	products(k, measured(k, t, root, measure, y) or_return, &leaves)
	parts := make([dynamic]Bound_Product)
	for x in leaves do append(&parts, bound_product(k, x.term, y) or_return)
	return parts[:], true
}

// least_bounds: hi = max(c, α·hi + g …), lo = min(c', α·lo + g …), c the bounds of
// the products that read no call — m - 1 for x % m —: the least solution, the
// narrowest range. A step α·y + g, α ≥ 1, keeps hi when α·hi + max(g) ≤ hi, lo
// when α·lo + min(g) ≥ lo; otherwise that side has no bound. x % m keeps lo at 0
// when x ≥ 0 there, at -(m - 1) otherwise. The range is proven by induction.
least_bounds :: proc(k: ^Kernel, eq: ^Call_Equation, e: Type, measure: Measure) -> (bounds: Bounds, ok: bool) {
	y := new_unknown(k, nil)
	y.layout = family_term(.Int)
	parts := at_bound(k, e, eq.root, measure, y) or_return
	based := false
	hi, lo: Maybe(i128)
	open_hi, open_lo := false, false
	widest: i128 // the greatest modulus
	for p in parts {
		if p.a != 0 do continue
		h, l := p.hi, p.lo
		if p.modulus > 0 {
			widest = max(widest, p.modulus)
			h, l = p.modulus - 1, 0
		}
		open_hi ||= h == nil
		open_lo ||= l == nil
		hi = !based ? h : (h == nil || hi == nil ? hi : max(hi.?, h.?))
		lo = !based ? l : (l == nil || lo == nil ? lo : min(lo.?, l.?))
		based = true
	}
	if !based do return
	// a side that grows with each step has no bound
	keeps :: proc(parts: []Bound_Product, at: i128, g: proc(p: Bound_Product) -> Maybe(i128), above: bool) -> bool {
		for p in parts {
			if p.a == 0 || p.modulus > 0 do continue
			b := g(p).? or_return
			next := p.a * at + b
			if above ? next > at : next < at do return false
		}
		return true
	}
	upper: Maybe(i128)
	if !open_hi && keeps(parts, hi.?, proc(p: Bound_Product) -> Maybe(i128) {return p.hi}, true) do upper = hi
	// the candidates for lo, from the narrowest: x % m at 0, then at -(m - 1)
	candidates := make([dynamic]Maybe(i128))
	if !open_lo {
		append(&candidates, lo)
		if widest > 0 do append(&candidates, min(lo.?, 1 - widest))
	}
	append(&candidates, nil)
	for l in candidates {
		if l != nil && !keeps(parts, l.?, proc(p: Bound_Product) -> Maybe(i128) {return p.lo}, false) do continue
		if l == nil && upper == nil do return
		lo_t, hi_t: Type
		if l != nil do lo_t = Int(l.?)
		if upper != nil do hi_t = Int(upper.?)
		set := range_law(k, lo_t, hi_t, .Int, {})
		taken := new_unknown(k, nil)
		taken.layout = set
		if holds_in(k, measured(k, e, eq.root, measure, taken) or_return, set, {}) do return {lo = lo_t, hi = hi_t}, true
	}
	return
}

// linear_at: the bounds at the values the call gives: functions of what it carves,
// each read on its image there.
linear_at :: proc(k: ^Kernel, b: Bounds, values: Rewrite) -> (image: Type, ok: bool) {
	lo, hi: Type
	if b.lo != nil {
		least, _ := int_bounds(k, layout_image(k, rewrite(k, b.lo, values)) or_return) or_return
		lo = Int(least.? or_return)
	}
	if b.hi != nil {
		_, top := int_bounds(k, layout_image(k, rewrite(k, b.hi, values)) or_return) or_return
		hi = Int(top.? or_return)
	}
	if lo == nil && hi == nil do return
	return range_law(k, lo, hi, .Int, {}), true
}

// measure_of: the measure of t, each call of root in it an unknown of its own: what
// the call gives, its length, or its sum Σ(x: 0..|X| - 1, g(X.#x)) — split over the
// bindings of a scope, an expansion by the sum of what it expands, a pattern by its
// products (§5.3, §6).
measure_of :: proc(k: ^Kernel, t: Type, root: ^Scope, m: Measure, calls: ^[dynamic]^Collapse, ys: ^[dynamic]^Unknown) -> (out: Type, ok: bool) {
	taken :: proc(k: ^Kernel, x: ^Collapse, calls: ^[dynamic]^Collapse, ys: ^[dynamic]^Unknown) -> ^Unknown {
		for c, i in calls do if c == x do return ys[i]
		y := new_unknown(k, nil)
		y.layout = family_term(.Int)
		append(calls, x)
		append(ys, y)
		return y
	}
	switch m.kind {
	case .Value, .Length:
		v := m.kind == .Length ? run_law(k, .Length, {t}, root.span) : t
		r: Rewrite
		for x in calls_in(k, t, root) {
			y := taken(k, x, calls, ys)
			if m.kind == .Value do r = rewriting_call(r, x, y)
			else do r = append_read(r, new_operation(.Length, x), y)
		}
		out = rewrite(k, v, r)
		return out, solved(out, root)
	case .Sum:
		if c, is_call := as_call(t); is_call && is_call_of(c, root) do return taken(k, c, calls, ys), true
		#partial switch v in t {
		case ^Pattern:
			if has_effect(v) do return
			branches := make([]Branch, len(v.branches))
			for b, i in v.branches do branches[i] = with_product(b, is_none(b.product) ? b.product : measure_of(k, b.product, root, m, calls, ys) or_return)
			return pattern_law(k, branching(v, branches)), true
		case ^Scope:
			out = Int(0)
			for b in run_data(k, v) {
				x := binding_value(k, b)
				part := b.kind == .Expand ? measure_of(k, x, root, m, calls, ys) or_return : rewrite(k, m.g, rewriting(nil, m.at, x))
				out = op(k, .Add, out, part)
			}
			return out, solved(out, root)
		}
	}
	return
}

// Linear: Σ coefs[j]·uⱼ + constant ≥ 0, over the coefficients u of a bound.
Linear :: struct {
	coefs:    []i128,
	constant: i128,
}

// linear_bounds: the bounds of a call that stays as functions of what it carves
// (§5.6): hi = c + Σ aⱼ·mⱼ, mⱼ the measure of a field the call carves — an integer,
// or the length of a run —, aⱼ ≥ 0; lo likewise from below. Each product of the
// equation, its calls taken at the bound of what they carve and every other term at
// its own image, lies within the bound at the product's fields, for every value its
// branch lets them take: linear constraints on c and the aⱼ — the induction, each
// product within the bound, its calls within it. Their least solution, the aⱼ first
// then c, solved in closed form by elimination.
linear_bounds :: proc(k: ^Kernel, eq: ^Call_Equation, e: Type, m: Measure) -> (bounds: Bounds, ok: bool) {
	Field :: struct {
		binding: ^Binding,
		unknown: ^Unknown,
		measure: Type,
		z:       ^Unknown,
	}
	fields := make([dynamic]Field)
	for b, u in eq.params {
		x := u.(^Unknown) or_continue
		measure: Type
		if proven_in(k, x, family_term(.Int)) do measure = x
		else if gives_scope(k, x) do measure = run_law(k, .Length, {x}, eq.root.span)
		else do continue
		z := new_unknown(k, nil)
		z.layout = family_term(.Int)
		append(&fields, Field{b, x, measure, z})
	}
	n := len(fields)
	// the measures of the fields read as the unknowns z
	as_z: Rewrite
	for f in fields {
		if f.measure == Type(f.unknown) do as_z = rewriting(as_z, f.unknown, f.z)
		else do as_z = append_read(as_z, f.measure, f.z)
	}
	// t, over the z, as Σ coefs·z + rest
	split_z :: proc(k: ^Kernel, t: Type, zs: []^Unknown) -> (coefs: []i128, rest: Type, ok: bool) {
		coefs = make([]i128, len(zs))
		rest = t
		for z, j in zs {
			alpha, beta := affine_in(k, rest, z) or_return
			a := alpha.(Int) or_return
			coefs[j], rest = i128(a), beta
		}
		for z in zs do if reads(k, rest, z) do return
		return coefs, rest, true
	}
	zs := make([]^Unknown, n)
	for f, j in fields do zs[j] = f.z
	leaves := make([dynamic]Product)
	products(k, given(k, e), &leaves)
	side :: proc(k: ^Kernel, leaves: []Product, eq: ^Call_Equation, m: Measure, fields: []Field, zs: []^Unknown, as_z: Rewrite, upper: bool) -> (solution: []i128, ok: bool) {
		n := len(fields)
		rows := make([dynamic]Linear)
		// aⱼ ≥ 0
		for j in 0 ..< n {
			row := Linear{make([]i128, n + 1), 0}
			row.coefs[j] = 1
			append(&rows, row)
		}
		for leaf in leaves {
			if is_none(leaf.term) do continue
			calls, ys := make([dynamic]^Collapse), make([dynamic]^Unknown)
			measured := measure_of(k, leaf.term, eq.root, m, &calls, &ys) or_return
			t := rewrite(k, measured, as_z)
			// K = bound(z) - measure(z) on the upper side, measure - bound below: K_j the
			// coefficient of zⱼ, K0 the constant, linear in (a, c)
			ks := make([]Linear, n + 1)
			for &x in ks do x = Linear{make([]i128, n + 1), 0}
			sign: i128 = upper ? 1 : -1
			for j in 0 ..< n do ks[j + 1].coefs[j] += sign
			ks[0].coefs[n] += sign
			for x, i in calls {
				alpha, beta := affine_in(k, t, ys[i]) or_return
				a := i128(alpha.(Int) or_return)
				if a < 0 do return
				t = beta
				// the call at the bound of what it carves
				changes := x.target.(^Scope).changes
				for f, j in fields {
					arg := changes[f.binding] or_else Type(f.unknown)
					at := f.measure == Type(f.unknown) ? arg : run_law(k, .Length, {arg}, eq.root.span)
					q, p := split_z(k, rewrite(k, at, as_z), zs) or_return
					constant := p.(Int) or_return
					for qi, i in q do ks[i + 1].coefs[j] -= sign * a * qi
					ks[0].coefs[j] -= sign * a * i128(constant)
				}
				ks[0].coefs[n] -= sign * a
			}
			es, rest := split_z(k, t, zs) or_return
			for ys_i in ys do if reads(k, rest, ys_i) do return
			for x, j in es do ks[j + 1].constant -= sign * x
			// every other term at its own image
			lo, hi := int_bounds(k, layout_image(k, read_in(k, leaf, rest)) or_return) or_return
			d := upper ? hi : lo
			ks[0].constant -= sign * (d.? or_return)
			// the region of the fields in the branch
			constants := make([dynamic]Linear)
			append(&constants, ks[0])
			for f, j in fields {
				l, h := int_bounds(k, layout_image(k, read_in(k, leaf, f.measure)) or_return) or_return
				kj := ks[j + 1]
				added := make([dynamic]Linear)
				for c in constants {
					switch {
					case l != nil && h != nil && l.? == h.?:
						append(&added, linear_add(c, kj, l.?) or_return)
					case h == nil && l != nil:
						append(&added, linear_add(c, kj, l.?) or_return)
					case l == nil && h != nil:
						append(&added, linear_add(c, kj, h.?) or_return)
					case l != nil && h != nil:
						append(&added, linear_add(c, kj, l.?) or_return)
						append(&added, linear_add(c, kj, h.?) or_return)
					}
				}
				switch {
				case h == nil && l == nil:
					append(&rows, kj, linear_scaled(kj, -1))
				case h == nil:
					append(&rows, kj)
				case l == nil:
					append(&rows, linear_scaled(kj, -1))
				}
				if len(added) > 16 do return
				constants = added
			}
			append(&rows, ..constants[:])
		}
		return least_solution(rows[:], n + 1, upper)
	}
	term :: proc(k: ^Kernel, u: []i128, fields: []Field) -> Type {
		out: Type = Int(u[len(fields)])
		for f, j in fields do if u[j] != 0 do out = op(k, .Add, out, op(k, .Mul, Int(u[j]), f.measure))
		return out
	}
	if u, solved := side(k, leaves[:], eq, m, fields[:], zs, as_z, true); solved do bounds.hi = term(k, u, fields[:])
	if u, solved := side(k, leaves[:], eq, m, fields[:], zs, as_z, false); solved do bounds.lo = term(k, u, fields[:])
	if m.kind == .Length && bounds.lo == nil do bounds.lo = Int(0)
	return bounds, bounds.hi != nil || bounds.lo != nil
}

linear_add :: proc(a, b: Linear, by: i128) -> (out: Linear, ok: bool) {
	out = Linear{make([]i128, len(a.coefs)), a.constant}
	for x, i in a.coefs {
		y := mul_checked(b.coefs[i], by) or_return
		out.coefs[i] = add_checked(x, y) or_return
	}
	c := mul_checked(b.constant, by) or_return
	out.constant = add_checked(out.constant, c) or_return
	return out, true
}

linear_scaled :: proc(a: Linear, by: i128) -> Linear {
	out := Linear{make([]i128, len(a.coefs)), a.constant * by}
	for x, i in a.coefs do out.coefs[i] = x * by
	return out
}

// least_solution: the integers u satisfying every row, each the least in turn (the
// greatest when not upper, the bound from below), the others free: the rows over
// u₀ … uᵥ, the later eliminated (Fourier–Motzkin), give uᵥ its range.
least_solution :: proc(rows: []Linear, n: int, upper: bool) -> (u: []i128, ok: bool) {
	u = make([]i128, n)
	current := slice.clone(rows)
	for v in 0 ..< n {
		system := slice.clone(current)
		for w := n - 1; w > v; w -= 1 do system = eliminate(system, w) or_return
		lo, hi: Maybe(i128)
		for r in system {
			a := r.coefs[v]
			switch {
			case a > 0:
				l := ceil_div(-r.constant, a)
				if lo == nil || l > lo.? do lo = l
			case a < 0:
				h := floor_div(r.constant, -a)
				if hi == nil || h < hi.? do hi = h
			case r.constant < 0:
				return
			}
		}
		value := (upper ? lo : hi).? or_return
		if upper && hi != nil && value > hi.? || !upper && lo != nil && value < lo.? do return
		u[v] = value
		// the rows with uᵥ given
		for &r in current {
			r.constant = add_checked(r.constant, mul_checked(r.coefs[v], value) or_return) or_return
			coefs := slice.clone(r.coefs)
			coefs[v] = 0
			r.coefs = coefs
		}
	}
	return u, true
}

// eliminate: the rows without uₓ: each pair of opposite signs on it combined.
eliminate :: proc(rows: []Linear, x: int) -> (out: []Linear, ok: bool) {
	kept := make([dynamic]Linear)
	for r in rows do if r.coefs[x] == 0 do append(&kept, r)
	for p in rows {
		if p.coefs[x] <= 0 do continue
		for q in rows {
			if q.coefs[x] >= 0 do continue
			r := linear_add(linear_scaled(p, -q.coefs[x]), q, p.coefs[x]) or_return
			g := abs(r.constant)
			for c in r.coefs do g = gcd(g, abs(c))
			if g > 1 {
				for &c in r.coefs do c /= g
				r.constant = floor_div(r.constant, g)
			}
			append(&kept, r)
		}
	}
	if len(kept) > 512 do return
	return kept[:], true
}

// counter_bounds: f = m ? {B -> c  -> g + f{s(m)}! + …}, each call moving the
// counter by the same step: the bounds after the n steps of the orbit, y ↦ α·y +
// max(g) from max(c) above, the least likewise below — folds, in closed form, over
// what the call gives the counter. A pattern gives one of its products, so the
// bounds follow the greatest α and g above, the least below, when every value is
// not negative. A run is the orbit of its positions: a call that takes the rest
// m from c of the run m its pattern cuts makes at most |m| / c steps, each branch
// making no call a base.
counter_bounds :: proc(k: ^Kernel, eq: ^Call_Equation, e: Type, measure: Measure) -> (bounds: Bounds, ok: bool) {
	root, generic := eq.root, eq.generic
	p := e.(^Pattern) or_return
	u := p.target.(^Unknown) or_return
	// the calls that move the counter by one step; a call of another value whose
	// production, at its values, calls nothing is that production (§7)
	step: Type
	asked: Rewrite
	for x in calls_in(k, e, root) {
		if next, _, moves := counter_next(k, generic, x, u); moves && (step == nil || same(k, step, next)) {
			step = next
			continue
		}
		v, read := production_at(k, x) or_return
		read.read = false
		if !solved(v, root) do return
		asked = rewriting_call(asked, x, v)
	}
	if step == nil do return
	bases, moves := make([dynamic]Type), make([dynamic]Type)
	n: Type
	if from, cuts := step.(^Operation); cuts && from.op == .From && same(k, from.args[0], u) {
		c, constant := from.args[1].(Int)
		if !constant || c <= 0 do return
		// a cover that takes every run of c pieces or more leaves the runs of fewer to
		// the branches after it: when they are the bases, the orbit stops there, after
		// |m| / c steps; otherwise after any number up to it
		short: Type
		for b in p.branches {
			product := rewrite(k, b.product, asked)
			if solved(product, root) {
				if short == nil do short = Bool(false)
				append(&bases, product)
				continue
			}
			if short == nil && b.cover != nil do if cut, cuts := cuts_head(k, b.cover, u); cuts && fewer_than(cut, i128(c)) do short = cut
			append(&moves, product)
		}
		if _, exact := short.(^Scope); exact do n = orbit_length(k, u, step, short, p.span) or_return
		else do n, bounds.upto = op(k, .Div, run_law(k, .Length, {u}, p.span), Int(c)), true
	} else {
		if len(p.branches) != 2 || p.branches[0].cover == nil || p.branches[1].cover != nil do return
		stop := p.branches[0].cover
		append(&bases, rewrite(k, p.branches[0].product, asked))
		append(&moves, rewrite(k, p.branches[1].product, asked))
		if !solved(bases[0], root) do return
		n = orbit_length(k, u, step, stop, p.span) or_return
	}
	if len(bases) == 0 || len(moves) == 0 do return
	y := new_unknown(k, nil)
	y.layout = family_term(.Int)
	steps := make([dynamic]Bound_Product)
	for t in moves do append(&steps, ..at_bound(k, t, root, measure, y) or_return)
	images := make([]Type, len(bases))
	for t, i in bases do images[i] = layout_image(k, t) or_return
	clo, chi := int_bounds(k, or_law(k, images)) or_return
	a_lo, a_hi: i128 = -1, -1
	tlo, thi: Maybe(i128)
	for x, i in steps {
		if x.modulus > 0 do return
		if i == 0 {
			a_lo, a_hi, tlo, thi = x.a, x.a, x.lo, x.hi
			continue
		}
		a_lo, a_hi = min(a_lo, x.a), max(a_hi, x.a)
		// a side without bound in one product has none
		tlo = tlo != nil && x.lo != nil ? Maybe(i128)(min(tlo.?, x.lo.?)) : nil
		thi = thi != nil && x.hi != nil ? Maybe(i128)(max(thi.?, x.hi.?)) : nil
	}
	if len(steps) > 1 {
		least, has := clo.?
		if !has || least < 0 do return
		at_least, read := tlo.?
		if !read || at_least < 0 do return
	}
	bound :: proc(k: ^Kernel, n: Type, a: i128, from, by: Maybe(i128), span: syn.Span) -> (out: Type, ok: bool) {
		c := from.? or_return
		b := by.? or_return
		f := new(Fold)
		f.index, f.span = new_unknown(k, nil), span
		f.index.layout = COUNTS
		f.start, f.next, f.stop = Int(0), op(k, .Add, f.index, Int(1)), new_range(n, nil, .Int)
		z := new_unknown(k, nil)
		z.layout = family_term(.Int)
		f.states, f.inits = slice.clone([]^Unknown{z}), slice.clone([]Type{Int(c)})
		f.effects, f.updates, f.value = None{}, slice.clone([]Type{op(k, .Add, op(k, .Mul, Int(a), z), Int(b))}), z
		return fold_law(k, f), true
	}
	// functions of the count of steps, read at the values the call gives (bounds_at)
	bounds.count, bounds.steps = new_unknown(k, nil), n
	bounds.count.layout = COUNTS
	bounds.hi = bound(k, bounds.count, a_hi, chi, thi, p.span) or_return
	bounds.lo = bound(k, bounds.count, a_lo, clo, tlo, p.span) or_return
	return bounds, true
}

// products: the products t may give: a pattern without effects, those of its
// branches, each read in its branch, where its reach holds — t & S there (§6) —;
// otherwise t. Each comes with the rewrite its reach makes: what is read inside it
// — the bindings of a scope it gives — is read under that rewrite too.
Product :: struct {
	term:    Type,
	rewrite: Rewrite,
}

products :: proc(k: ^Kernel, t: Type, out: ^[dynamic]Product, r: Rewrite = nil) {
	if p, is_pattern := t.(^Pattern); is_pattern && !has_effect(p) {
		reached, _, invalid := reaches(k, p.target, p.branches)
		if invalid != nil {
			append(out, Product{invalid, r})
			return
		}
		for x in reached {
			inner := make([dynamic]Rewriting)
			append(&inner, ..r)
			append(&inner, ..x.rewrite)
			products(k, branch_product(k, p.branches[x.branch], x.rewrite, p.target), out, inner[:])
		}
		return
	}
	append(out, Product{t, r})
}

// read_in: what a product holds, read under the rewrite of its branch.
read_in :: proc(k: ^Kernel, p: Product, t: Type) -> Type {
	if len(p.rewrite) == 0 do return t
	return rewrite(k, t, p.rewrite)
}

// Summed: the equation F of Σ(p: lo..hi, f{… p -> p}!), f linear in its calls.
Summed :: struct {
	root:   ^Scope,
	field:  ^Binding,
	lo, hi: Type,
	sum:    ^Scope,
}

// summed_call: Σ(p: lo..hi, f{x  p -> p}!) = F{x}!, f an equation whose products are
// a term and calls that keep p: F is f, its terms summed over p, its calls F's
// (§5.6). One traversal for all p.
summed_call :: proc(k: ^Kernel, s: ^Series) -> (out: Type, ok: bool) {
	call := s.term.(^Collapse) or_return
	if !call.recursive do return
	target := call.target.(^Scope) or_return
	root := origin(target)
	field: ^Binding
	for b, v in target.changes do if u, is_index := v.(^Unknown); is_index && same_unknown(u, s.index) do field = b
	if field == nil do return
	for b, v in target.changes do if b != field && reads(k, v, s.index) do return
	f := summed_equation(k, root, field, s.lo, s.hi) or_return
	changes := make(map[^Binding]Type)
	for b, v in target.changes do if b != field do changes[holding(f, b)] = v
	carve := derive(k, f, changes, call.span).(^Scope) or_return
	return recursive_call(k, carve, call.span), true
}

// summed_equation: F, made once for f, its field p and the range of the sum.
summed_equation :: proc(k: ^Kernel, root: ^Scope, field: ^Binding, lo, hi: Type) -> (^Scope, bool) {
	for x in k.summed do if x.root == root && x.field == field && same(k, x.lo, lo) && same(k, x.hi, hi) do return x.sum, x.sum != nil
	append(&k.summed, Summed{root, field, lo, hi, nil})
	f := copy_scope(k, root, nil)
	f.source, f.name = nil, strings.concatenate({"Σ", root.name})
	p: ^Binding
	for b in f.bindings do if b.source == field do p = b
	for b in f.bindings {
		if b.kind != .Product do continue
		written, linear := summed_product(k, b.value, root, f, p, lo, hi)
		if !linear do return nil, false
		b.value = written
		break
	}
	k.summed[len(k.summed) - 1].sum = f
	return f, true
}

// summed_product: the production t of f, written for F: through a pattern, a sum of
// a term and calls of f that keep p is Σ(p: lo..hi, term) and those calls, of F,
// without p.
summed_product :: proc(k: ^Kernel, t: Type, root, f: ^Scope, p: ^Binding, lo, hi: Type) -> (Type, bool) {
	if pat, is_pattern := t.(^Pattern); is_pattern {
		out := new(Pattern)
		out^ = pat^
		out.branches = make([]Branch, len(pat.branches))
		for b, i in pat.branches {
			product, linear := summed_product(k, b.product, root, f, p, lo, hi)
			if !linear do return nil, false
			out.branches[i] = with_product(b, product)
		}
		return out, true
	}
	terms := make([dynamic]Type)
	summands :: proc(t: Type, out: ^[dynamic]Type) {
		if o, is_sum := t.(^Operation); is_sum && o.op == .Add {
			for a in o.args do summands(a, out)
			return
		}
		append(out, t)
	}
	summands(t, &terms)
	rest := make([dynamic]Type)
	calls := make([dynamic]Type)
	for x in terms {
		c, is_call := x.(^Collapse)
		carve: ^Carve
		if is_call do carve, is_call = c.target.(^Carve)
		if is_call {
			name, named := carve.target.(^Name)
			if !named || name.binding.value != root do is_call = false
		}
		if !is_call {
			seen := make(map[^Scope]bool)
			if names_scope(x, root, &seen) do return nil, false
			append(&rest, x)
			continue
		}
		// a call that keeps p, given to F without it
		args := make([dynamic]Carve_Arg)
		kept := false
		for a in carve.args {
			if a.name == p.name {
				name, is_name := a.value.(^Name)
				if !is_name || name.binding != p do return nil, false
				kept = true
				continue
			}
			append(&args, a)
		}
		if !kept do return nil, false
		g := new(Carve)
		g^ = carve^
		g.target, g.args = f, args[:]
		d := new(Collapse)
		d^ = c^
		d.target = g
		append(&calls, d)
	}
	out: Type
	if len(rest) > 0 {
		index := new_unknown(k, nil)
		index.layout = range_law(k, lo, hi, .Int, {})
		m := Copier{pieces = make(map[^Binding]Type)}
		m.pieces[p] = index
		term := len(rest) == 1 ? rest[0] : Type(new_operation(.Add, ..rest[:]))
		sum := new(Series)
		sum.op, sum.index, sum.lo, sum.hi = .Add, index, lo, hi
		sum.term = copy_term(k, &m, term, f)
		out = sum
	}
	for c in calls do out = out == nil ? c : Type(new_operation(.Add, out, c))
	return out, true
}

// bitwise_sum: Σ(i: lo..hi, v ⊕ i), ⊕ one of ^ [&] [|], v ≥ 0 not reading i: summed bit
// by bit. With N the count of i and C_b the count of those whose bit b is 1, bit b
// gives 2ᵇ times: C_b + v_b·(N - 2·C_b) for ^, v_b·C_b for [&], C_b + v_b·(N - C_b)
// for [|]. The bits of v with the same factor K are one mask: K·(v [&] mask) (§5.6).
bitwise_sum :: proc(k: ^Kernel, s: ^Series) -> (out: Type, ok: bool) {
	o := s.term.(^Operation) or_return
	if o.op != .Xor && o.op != .Bit_And && o.op != .Bit_Or || len(o.args) != 2 do return
	// v ⊕ (i + c): the sum over j = i + c, from lo + c to hi + c
	v: Type
	shift: i128 = 0
	for a, j in o.args {
		slope, c, affine := affine_in(k, a, s.index)
		at, constant := c.(Int)
		if affine && is_int(slope, 1) && constant {
			v, shift = o.args[1 - j], i128(at)
		}
	}
	if v == nil || reads(k, v, s.index) do return
	lo := i128(s.lo.(Int) or_return) + shift
	hi := i128(s.hi.(Int) or_return) + shift
	if lo < 0 || hi < lo do return
	image := layout_image(k, v) or_return
	vlo, vhi := int_bounds(k, image) or_return
	least := vlo.? or_return
	top := vhi.? or_return
	if least < 0 do return
	// the bits of v and of i
	width := uint(0)
	for (i128(1) << width) <= max(top, hi) do width += 1
	if width > 62 do return
	// ones(n, b): the integers of 0..n-1 whose bit b is 1
	ones :: proc(n: i128, b: uint) -> i128 {
		block := i128(1) << (b + 1)
		return (n / block) << b + max(n % block - i128(1) << b, 0)
	}
	n := hi - lo + 1
	constant: i128 = 0
	factors := make([]i128, width)
	for b in 0 ..< width {
		c := ones(hi + 1, b) - ones(lo, b)
		#partial switch o.op {
		case .Xor:
			constant += c << b
			factors[b] = n - 2 * c
		case .Bit_And:
			factors[b] = c
		case .Bit_Or:
			constant += c << b
			factors[b] = n - c
		}
	}
	out = Int(constant)
	done := make([]bool, width)
	for b in 0 ..< width {
		if done[b] || factors[b] == 0 do continue
		mask: i128 = 0
		for x in b ..< width do if !done[x] && factors[x] == factors[b] {
			mask |= i128(1) << x
			done[x] = true
		}
		out = op(k, .Add, out, op(k, .Mul, Int(factors[b]), op(k, .Bit_And, v, Int(mask))))
	}
	return out, true
}

// fewer_than: s is the shape of the runs of fewer than c pieces, {...(A * (0..c - 1)):}.
fewer_than :: proc(s: Type, c: i128) -> bool {
	shape, is_scope := s.(^Scope)
	if !is_scope || len(shape.bindings) != 1 || !is_run(shape.bindings[0]) do return false
	o, repeats := shape.bindings[0].color.(^Operation)
	if !repeats || o.op != .Mul do return false
	r, is_range := o.args[1].(^Range)
	return is_range && is_int(r.lo, 0) && is_int(r.hi, c - 1)
}

// fixed: the state i stays at its init: its update reads it alone, and gives the
// init back from it (x ↦ x, x ↦ x % m from 1 …).
fixed :: proc(k: ^Kernel, f: ^Fold, i: int) -> bool {
	x, u := f.states[i], f.updates[i]
	if same(k, u, x) do return true
	if reads(k, u, f.index) || !is_constant(f.inits[i]) do return false
	for z, j in f.states do if j != i && reads(k, u, z) do return false
	return same(k, rewrite(k, u, rewriting(nil, x, f.inits[i])), f.inits[i])
}

// TUPLING (§5.6): calls of an equation f that differ by a field p only, over a
// range lo..hi, are the bindings of one call of T, whose value is the scope
// {f at p = lo  …  f at p = hi}: T is f, each product a scope of its products at
// each p, its calls of f T's, read at their p. One recursion for the range.

Tupled :: struct {
	root:   ^Scope,
	field:  ^Binding,
	lo, hi: i128,
	tuple:  ^Scope,
}

// Tupling: the copy of a product of f for p = lo + at, in T.
Tupling :: struct {
	root:   ^Scope,
	tuple:  ^Scope,
	field:  ^Binding,
	at:     int,
	failed: bool,
}

// tupled_call: in the copy for p = lo + at, a call of f that keeps p is T{…}!.#at.
tupled_call :: proc(k: ^Kernel, m: ^Copier, c: ^Collapse, scope: ^Scope) -> (Type, bool) {
	carve, is_carve := c.target.(^Carve)
	if !is_carve do return nil, false
	name, named := carve.target.(^Name)
	if !named || name.binding.value != m.tuple.root do return nil, false
	args := make([dynamic]Carve_Arg)
	kept := false
	for a in carve.args {
		if a.name == m.tuple.field.name {
			p, is_name := a.value.(^Name)
			kept = is_name && p.binding == m.tuple.field
			continue
		}
		b := a
		b.value = copy_term(k, m, a.value, scope)
		append(&args, b)
	}
	if !kept {
		m.tuple.failed = true
		return nil, false
	}
	g := new(Carve)
	g^ = carve^
	g.target, g.args = m.tuple.tuple, args[:]
	d := new(Collapse)
	d^ = c^
	d.target = g
	return new_operation(.Item, d, Int(m.tuple.at)), true
}

// tupled_equation: T, made once for f, its field p and the range.
tupled_equation :: proc(k: ^Kernel, root: ^Scope, field: ^Binding, lo, hi: i128) -> (^Scope, bool) {
	for x in k.tupled do if x.root == root && x.field == field && x.lo == lo && x.hi == hi do return x.tuple, x.tuple != nil
	append(&k.tupled, Tupled{root, field, lo, hi, nil})
	t := copy_scope(k, root, nil)
	t.source, t.name = nil, strings.concatenate({"⊗", root.name})
	p: ^Binding
	for b in t.bindings do if b.source == field do p = b
	for b in t.bindings {
		if b.kind != .Product do continue
		written, kept := tupled_product(k, b.value, root, t, p, lo, hi, t)
		if !kept do return nil, false
		b.value = written
		break
	}
	k.tupled[len(k.tupled) - 1].tuple = t
	return t, true
}

// tupled_product: through a pattern, each product of f as the scope of its copies
// at each p of the range.
tupled_product :: proc(k: ^Kernel, t: Type, root, tuple: ^Scope, p: ^Binding, lo, hi: i128, parent: ^Scope) -> (Type, bool) {
	if pat, is_pattern := t.(^Pattern); is_pattern {
		out := new(Pattern)
		out^ = pat^
		out.branches = make([]Branch, len(pat.branches))
		for b, i in pat.branches {
			product, kept := tupled_product(k, b.product, root, tuple, p, lo, hi, b.scope != nil ? b.scope : parent)
			if !kept do return nil, false
			out.branches[i] = with_product(b, product)
		}
		return out, true
	}
	literal := new_scope(parent, tuple.span)
	literal.complete = true
	for at in 0 ..= int(hi - lo) {
		m := Copier{pieces = make(map[^Binding]Type)}
		m.pieces[p] = Int(lo + i128(at))
		m.tuple = &Tupling{root, tuple, p, at, false}
		v := copy_term(k, &m, t, literal)
		if m.tuple.failed do return nil, false
		b := new_binding(literal, .Push, tuple.span)
		b.value = v
	}
	return literal, true
}

// tupled: the fold, its counter i over lo..hi known, reads calls f{x  p -> i}! of
// an equation that keeps p in its calls: each is T{x}!.#(i - lo).
tupled :: proc(k: ^Kernel, f: ^Fold) -> ^Fold {
	lo_t, hi_t, counts := counter_range(k, f)
	lo, known_lo := lo_t.(Int)
	hi, known_hi := hi_t.(Int)
	if !counts || !known_lo || !known_hi || hi < lo || hi - lo > 63 || !same(k, f.next, op(k, .Add, f.index, Int(1))) do return f
	reading: Rewrite
	visit :: proc(k: ^Kernel, t: Type, f: ^Fold, lo, hi: i128, reading: ^Rewrite) {
		if t == nil do return
		if c, is_call := t.(^Collapse); is_call && c.recursive {
			s, is_scope := c.target.(^Scope)
			field: ^Binding
			if is_scope do for b, v in s.changes do if u, is_index := v.(^Unknown); is_index && same_unknown(u, f.index) do field = b
			if field != nil {
				for b, v in s.changes do if b != field && reads(k, v, f.index) do return
				tuple, made := tupled_equation(k, origin(s), field, lo, hi)
				if !made do return
				changes := make(map[^Binding]Type)
				for b, v in s.changes do if b != field do changes[holding(tuple, b)] = v
				carve, carved := derive(k, tuple, changes, c.span).(^Scope)
				if !carved do return
				at := op(k, .Sub, narrowing(f.index, range_law(k, Int(lo), Int(hi), .Int, {})), Int(lo))
				reading^ = rewriting_call(reading^, c, op(k, .Item, recursive_call(k, carve, c.span), at))
				return
			}
		}
		for x in parts(t) do visit(k, x, f, lo, hi, reading)
		if p, is_pattern := t.(^Pattern); is_pattern do for br in p.branches do visit(k, br.product, f, lo, hi, reading)
	}
	for t in fold_parts(f) do visit(k, t, f, i128(lo), i128(hi), &reading)
	if len(reading) == 0 do return f
	parts := fold_parts(f)
	for &t in parts do t = rewrite(k, t, reading)
	return with_parts(f, parts)
}

// over_fold: f{t -> ⟳(…; y: c ↦ u(y); y)}! = ⟳(…; w: f{t -> c}! ↦ f{t -> u(y)}!; w),
// where the production of f{t -> u(y)}! reads y only through f{t -> y}!, which is
// w: the recursion follows the fold that builds what it reads, and nothing is
// built (§5.6). y takes the structure of u(y), as every state after the first.
over_fold :: proc(k: ^Kernel, s: ^Scope, field: ^Binding, f: ^Fold, span: syn.Span) -> (out: Type, ok: bool) {
	root := origin(s)
	if !is_none(f.effects) do return
	at := -1
	for z, i in f.states do if same(k, f.value, z) do at = i
	if at < 0 do return
	y := f.states[at]
	step := f.updates[at].(^Scope) or_return
	for t, j in f.updates do if j != at && reads(k, t, y) do return
	// y as every state after the first: the shape of u, a place holding y in the
	// color of the field, as the states are (fold_induction)
	shape := new_scope(nil, step.span)
	shape.source, shape.complete, shape.reached = shape, true, true
	for x in placed(k, step, .Value) {
		if x.kind != .Push do return
		place := new_binding(shape, .Push, x.span)
		place.name = x.name
		if u, is_y := binding_value(k, x).(^Unknown); is_y && same_unknown(u, y) do place.color = binding_color(k, field)
		else if image, known := layout_image(k, binding_value(k, x)); known do place.color = image
		place.typed_color = place.color
	}
	z := new_unknown(k, nil)
	z.layout = shape
	call :: proc(k: ^Kernel, s, root: ^Scope, field: ^Binding, v: Type, span: syn.Span) -> (c: ^Collapse, ok: bool) {
		changes := make(map[^Binding]Type)
		for b, x in s.changes do changes[b] = x
		changes[field] = v
		// v is a state of the fold, in the color of the field as the fold is (fold_induction)
		carve := carved_copy(k, root, changes)
		c = new(Collapse)
		c.target, c.recursive, c.span = carve, true, span
		return c, true
	}
	first := call(k, s, root, field, f.inits[at], span) or_return
	next := call(k, s, root, field, rewrite(k, step, rewriting(nil, y, z)), span) or_return
	init, init_read := production_at(k, first) or_return
	init_read.read = false
	value, value_read := production_at(k, next) or_return
	value_read.read = false
	// f{t -> y}!, the other fields as in s: w
	w := new_unknown(k, nil)
	family := family_of(k, init) or_return
	w.layout = family_term(family)
	back: Rewrite
	for c in calls_in(k, value, root) {
		target := c.target.(^Scope)
		matches := len(target.changes) == len(s.changes)
		for b, x in target.changes {
			if b == field {
				u, is_z := x.(^Unknown)
				matches &&= is_z && same_unknown(u, z)
			} else {
				matches &&= b in s.changes && same(k, x, s.changes[b])
			}
		}
		if !matches do return
		back = rewriting_call(back, c, w)
	}
	value = rewrite(k, value, back)
	if reads(k, value, z) || !solved(init, root) || !solved(value, root) do return
	g := new(Fold)
	g^ = f^
	g.states = slice.clone(f.states)
	g.inits = slice.clone(f.inits)
	g.updates = slice.clone(f.updates)
	g.states[at], g.inits[at], g.updates[at], g.value = w, init, value, w
	return fold_law(k, g), true
}
