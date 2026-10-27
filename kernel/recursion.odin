package kernel

import syn "../syntax"
import "core:fmt"
import "core:slice"

// RECURSION (specs/types.md §5.6)
//
// A scope names itself only in its productions. Asked again from its own
// production, it stays a carve and a collapse — a recursive call — and is never
// unfolded. Its first production is then an equation that mentions it. It is
// solved — an iteration, in a closed form when it has one — or it stays. A call of
// a solved equation substitutes its arguments into the solution.
//
// A recursive call has the family of its equation: that of its base cases. An
// operator on it is checked once the equation is given.

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
		return names_scope(v.then, s, seen)
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
			if substitutable do return renewed(k, rewrite(k, solution, values), &run)
		}
	}
	out := new(Collapse)
	out.target, out.recursive, out.span = s, true, span
	if root.effectful do return call_effect(k, out)
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

// solved: t holds no recursive call of the scope.
solved :: proc(t: Type, root: ^Scope) -> bool {
	#partial switch v in t {
	case ^Collapse:
		if s, ok := v.target.(^Scope); ok && v.recursive && origin(s) == root do return false
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
	}
	return true
}

// call_family: the family of a recursive call: that of the base cases of the
// equation it calls, once given — false while it is being given.
call_family :: proc(k: ^Kernel, c: ^Collapse) -> (Family, bool) {
	s, ok := c.target.(^Scope)
	if !ok do return {}, false
	root := origin(s)
	p, found := first_production(k, root)
	if !found || p.state != .Done do return {}, false
	return base_family(k, root, p.typed_value)
}

// is_pending_call: a recursive call whose equation is being given.
is_pending_call :: proc(t: Type) -> bool {
	c, ok := as_call(t)
	if !ok do return false
	s, is_scope := c.target.(^Scope)
	if !is_scope do return false
	for b in origin(s).bindings do if b.kind == .Product do return b.state == .In_Progress
	return false
}

// equation_family: the family of the equation of root: that of its base cases,
// the products that do not call it. When the values the scope holds reach none of
// them, its calls carve those values: the family is read on the equation where
// what they carve is an unknown of its color, root{n -> ?::C}.
equation_family :: proc(k: ^Kernel, root: ^Scope, e: Type) -> (family: Family, ok: bool) {
	if f, based := base_family(k, root, e); based do return f, true
	carved := carved_by_calls(e, root)
	if len(carved) == 0 do return
	generic := generic_equation(k, root, &carved) or_return
	p := first_production(k, generic) or_return
	return base_family(k, root, binding_type(k, p))
}

// carved_by_calls: the bindings the recursive calls of e carve, in operations.
carved_by_calls :: proc(e: Type, root: ^Scope) -> map[^Binding]Type {
	carved := make(map[^Binding]Type)
	for o in operations_on_calls(e, root) {
		for a in o.args {
			c, is_call := as_call(a)
			if !is_call do continue
			if s, is_scope := c.target.(^Scope); is_scope do for b in s.changes do carved[b] = nil
		}
	}
	return carved
}

// generic_equation: root where each binding of carved is an unknown of its color,
// root{n -> ?::C}; carved maps each one to its unknown.
generic_equation :: proc(k: ^Kernel, root: ^Scope, carved: ^map[^Binding]Type) -> (^Scope, bool) {
	for b in carved {
		u := new_unknown(k, nil)
		u.layout = binding_color(k, b)
		if u.layout == nil do u.layout = everything()
		carved[b] = u
	}
	return derive(k, root, carved^, root.span).(^Scope)
}

// generic_solution: the solution of the equation of root where each binding of
// values is an unknown of its color, with those values (§5.6):
// sum{n -> m}! = m ? {0 -> 0  -> m + sum{n -> m - 1}!} gives m * (m + 1) / 2 whatever
// m, and whatever n holds in sum.
generic_solution :: proc(k: ^Kernel, root: ^Scope, values: map[^Binding]Type) -> (solution: Type, ok: bool) {
	params := make(map[^Binding]Type)
	for b in values do params[b] = nil
	generic := generic_equation(k, root, &params) or_return
	p := first_production(k, generic) or_return
	solved := iteration(k, generic, binding_type(k, p)) or_return
	rewrites: Rewrite
	for b, u in params do rewrites = rewriting(rewrites, u.(^Unknown), values[b])
	return rewrite(k, solved, rewrites), true
}

// holding: the binding of s that holds b, a binding of the scope s copies: b
// itself, or its copy.
holding :: proc(s: ^Scope, b: ^Binding) -> ^Binding {
	for x in s.bindings do if x == b || x.source == b do return x
	return b
}

// base_family: the family of the base cases of e; false when there are none, or
// not of one family.
base_family :: proc(k: ^Kernel, root: ^Scope, e: Type) -> (family: Family, ok: bool) {
	f: Maybe(Family)
	for b in base_cases(e, root) {
		g := family_of(k, b) or_return
		if current, set := f.?; set && current != g do return {}, false
		f = g
	}
	return f.?
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

// gives_scopes: a recursive call whose equation has scopes for base cases: by
// induction, it gives a scope, and `...` places it (§5.6).
gives_scopes :: proc(k: ^Kernel, c: ^Collapse) -> bool {
	s, ok := c.target.(^Scope)
	if !ok || !c.recursive do return false
	root := origin(s)
	p, found := first_production(k, root)
	if !found do return false
	bases := base_cases(binding_type(k, p), root)
	for b in bases do if _, is_scope := b.(^Scope); !is_scope do return false
	return len(bases) > 0
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

// operations_on_calls: the operations of t that take a recursive call of root.
operations_on_calls :: proc(t: Type, root: ^Scope) -> []^Operation {
	out := make([dynamic]^Operation)
	visit :: proc(t: Type, root: ^Scope, out: ^[dynamic]^Operation) {
		#partial switch v in t {
		case ^Operation:
			for a in v.args {
				c, is_call := as_call(a)
				if !is_call do continue
				if s, is_scope := c.target.(^Scope); is_scope && origin(s) == root {
					append(out, v)
					break
				}
			}
			for a in v.args do visit(a, root, out)
		case ^Pattern:
			for b in v.branches do visit(b.product, root, out)
		case ^Or:
			for a in v.terms do visit(a, root, out)
		case ^And:
			for a in v.terms do visit(a, root, out)
		case ^Not:
			visit(v.term, root, out)
		case ^Effect:
			visit(v.then, root, out)
		}
	}
	visit(t, root, &out)
	return out[:]
}

// legal_on_call: a signature of the operator holds its operands, the recursive
// calls being of the family f.
legal_on_call :: proc(k: ^Kernel, o: ^Operation, f: Family) -> bool {
	next: for sig in signatures(o.op) {
		for a, i in o.args {
			if _, is_call := as_call(a); is_call {
				if !family_holds(sig.args[min(i, 1)], f) do continue next
				continue
			}
			if !proven_in(k, a, family_term(sig.args[min(i, 1)])) do continue next
		}
		return true
	}
	return false
}

// solve: the solution of the equation (§5.6): its iteration, when it is a
// recursion on a counter. When what the calls carve holds known values in the
// scope, the equation is read where they are unknowns, and solved at those values.
solve :: proc(k: ^Kernel, root: ^Scope, value: Type) -> Type {
	if solution, solved := iteration(k, root, value); solved do return solution
	if root.effectful do return value
	values := carved_by_calls(value, root)
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
	p := value.(^Pattern) or_return
	if len(p.branches) != 2 || p.branches[0].cover == nil || p.branches[1].cover != nil do return
	u := p.target.(^Unknown) or_return
	root := origin(s)
	stop, c, r := p.branches[0].cover, p.branches[0].product, p.branches[1].product
	if !solved(c, root) do return
	family := family_of(k, given(k, c)) or_return
	pre, calls, answer, after := at_calls(k, s, r) or_return
	if answer == nil && skips(r, root) do return
	step, ahead := orbit_step(k, s, calls, u) or_return
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
	i.layout = new_range(Int(0), nil, .Int)
	ki, closed := orbit(k, rewrite(k, step, rewriting(nil, u, x)), x, u, i)
	n: Type
	if closed {
		j := new_unknown(k, nil)
		j.layout = i.layout
		n = least_law(k, j, in_law(k, rewrite(k, ki, rewriting(nil, i, j)), stop), p.span)
	}
	at := proc(k: ^Kernel, ki: Type, i: ^Unknown, t: Type) -> Type {return rewrite(k, ki, rewriting(nil, i, t))}
	feeds := false
	for e in pre do feeds ||= e.answer != nil && reads(k, after, e.answer)
	if closed && !feeds {
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
	alpha, beta, affine := affine_in(v, ys[0])
	if len(calls) != 1 || len(post) > 0 || !affine || family != .Int do return
	// going down, the composed map (A, B)
	f := new(Fold)
	f.span = p.span
	along, at_end: Rewrite
	if closed {
		f.index, f.start, f.next, f.stop = i, Int(0), op(k, .Add, i, Int(1)), new_range(n, nil, .Int)
		along, at_end = rewriting(nil, u, ki), rewriting(nil, u, at(k, ki, i, n))
	} else {
		f.index, f.start, f.next, f.stop = x, u, rewrite(k, step, rewriting(nil, u, x)), stop
		along, at_end = rewriting(nil, u, x), rewriting(nil, u, narrowing(x, and_law(k, {layout_of(k, u), stop})))
	}
	a, b := new_unknown(k, nil), new_unknown(k, nil)
	a.layout, b.layout = family_term(.Int), family_term(.Int)
	f.states, f.inits = slice.clone([]^Unknown{a, b}), slice.clone([]Type{Int(1), Int(0)})
	f.effects = rewrite(k, wrap_effects(pre, None{}), along)
	f.updates = slice.clone([]Type{op(k, .Mul, a, rewrite(k, alpha, along)), op(k, .Add, b, op(k, .Mul, a, rewrite(k, beta, along)))})
	f.value = op(k, .Add, op(k, .Mul, a, rewrite(k, c, at_end)), b)
	return folded(k, f), true
}

// orbit_step: the step s of the orbit the calls follow, and how far along it each
// call is: one call, s itself, 1; calls f{n -> m - j}!, the points j / g along
// s(m) = m - g, g the greatest divisor of the j.
orbit_step :: proc(k: ^Kernel, s: ^Scope, calls: []^Collapse, u: ^Unknown) -> (step: Type, ahead: []int, ok: bool) {
	if len(calls) == 1 {
		step = counter_next(k, s, calls[0], u) or_return
		return step, slice.clone([]int{1}), true
	}
	shifts := make([]i128, len(calls))
	g: i128 = 0
	for call, j in calls {
		next := counter_next(k, s, call, u) or_return
		alpha, beta := affine_in(next, u) or_return
		one, is_int := alpha.(Int)
		minus, constant := beta.(Int)
		if !is_int || one != 1 || !constant || minus >= 0 do return
		shifts[j] = -i128(minus)
		g = gcd(g, shifts[j])
	}
	ahead = make([]int, len(calls))
	for x, j in shifts do ahead[j] = int(x / g)
	return op(k, .Sub, u, Int(g)), ahead, true
}

// continues: the orbit, once in B, stays in it — kᵢ decreasing, B = ..b, or
// increasing, B = b.. —: the points after the end of the orbit are base cases.
continues :: proc(k: ^Kernel, stop: Type, ki: Type, i: ^Unknown) -> bool {
	r, is_range := stop.(^Range)
	if !is_range do return false
	alpha, _, affine := affine_in(ki, i)
	slope, is_int := alpha.(Int)
	if !affine || !is_int do return false
	return slope < 0 && r.lo == nil || slope > 0 && r.hi == nil
}

// orbit: kᵢ = sⁱ(m), the i-th point of the orbit of m by s(x), when it has a closed
// form: s(x) = α·x + β gives m + β·i when α = 1, αⁱ·m + β·(αⁱ - 1)/(α - 1)
// otherwise; s(x) = x / c, for x ≥ 0, gives m / cⁱ; s(x) = x >> c gives m >> c·i.
orbit :: proc(k: ^Kernel, s: Type, x: ^Unknown, m: Type, i: ^Unknown) -> (Type, bool) {
	if alpha, beta, affine := affine_in(s, x); affine {
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
	case .Shr:
		shift = i128(c)
	case .Div:
		// ⌊⌊m / c⌋ / c⌋ = ⌊m / c²⌋ for m ≥ 0
		if !included(k, layout_of(k, x), new_range(Int(0), nil, .Int)) do return nil, false
		return op(k, .Div, m, op(k, .Pow, c, i)), true
	case:
		return nil, false
	}
	return op(k, .Shr, m, op(k, .Mul, Int(shift), i)), true
}

// least_law: μ(i: t). When t is kᵢ in B, kᵢ moving by one — down into B = ..b, or
// onto its point b from above; up into b.. —, μ is where it crosses in: the
// distance m - b, or 0 when m is in B already.
least_law :: proc(k: ^Kernel, i: ^Unknown, holds: Type, span: syn.Span) -> Type {
	if is_bool(holds, true) do return Int(0)
	out := new(Least)
	out.index, out.holds, out.span = i, holds, span
	o, is_in := holds.(^Operation)
	if !is_in || o.op != .In do return out
	alpha, beta, affine := affine_in(o.args[0], i)
	slope, is_int := alpha.(Int)
	if !affine || !is_int || slope != 1 && slope != -1 do return out
	cells, negated := as_cells(o.args[1])
	if negated || len(cells) != 1 do return out
	lo, hi := discrete_bounds(cells[0])
	l, has_lo := lo.?
	h, has_hi := hi.?
	gap: Type
	switch {
	case slope < 0 && has_hi && (!has_lo || l == h):
		gap = op(k, .Sub, beta, Int(h))
		if has_lo && !proven_in(k, gap, new_range(Int(0), nil, .Int)) do return out // onto the point
	case slope > 0 && has_lo && (!has_hi || l == h):
		gap = op(k, .Sub, Int(l), beta)
		if has_hi && !proven_in(k, gap, new_range(Int(0), nil, .Int)) do return out
	case:
		return out
	}
	// max(gap, 0)
	if proven_in(k, gap, new_range(Int(0), nil, .Int)) do return gap
	if proven_in(k, gap, new_range(nil, Int(0), .Int)) do return Int(0)
	m := new(Pattern)
	m.target, m.span = gap, span
	m.branches = slice.clone([]Branch{{cover = new_range(nil, Int(0), .Int), product = Int(0)}, {product = gap}})
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
affine_in :: proc(t: Type, y: ^Unknown) -> (alpha, beta: Type, ok: bool) {
	ms, divisor := monomials(t) or_return
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
	alpha = ring_term(as[:], 1) or_return
	beta = ring_term(bs[:], 1) or_return
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
	found := make([dynamic]^Collapse)
	note := proc(k: ^Kernel, found: ^[dynamic]^Collapse, c: ^Collapse) {
		for x in found do if same(k, x, c) do return
		append(found, c)
	}
	if c, is_call := r.(^Collapse); is_call && c.recursive do note(k, &found, c)
	for o in operations_on_calls(r, origin(s)) {
		for a in o.args {
			c, is_call := a.(^Collapse)
			if is_call && c.recursive do note(k, &found, c)
		}
	}
	return nil, found[:], nil, r, len(found) > 0
}

// counter_next: the value the call c gives the field that holds u, when it changes
// that field only.
counter_next :: proc(k: ^Kernel, s: ^Scope, c: ^Collapse, u: ^Unknown) -> (Type, bool) {
	target, is_scope := c.target.(^Scope)
	if !is_scope || origin(target) != origin(s) || len(target.changes) != 1 do return nil, false
	for b, v in target.changes {
		x, is_unknown := binding_type(k, holding(s, b)).(^Unknown)
		if !is_unknown || !same_unknown(x, u) do return nil, false
		return v, true
	}
	return nil, false
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
simplified :: proc(k: ^Kernel, f: ^Fold) -> ^Fold {
	out := f
	for changed := true; changed; {
		changed = false
		for x, i in out.states {
			if same(k, out.updates[i], x) {
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
	return out
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
	alpha, beta := affine_in(update, x) or_return
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
	t.layout = new_range(Int(0), nil, .Int)
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
// it.
atomized :: proc(k: ^Kernel, t: Type, back: ^Rewrite) -> Type {
	#partial switch v in t {
	case Int, ^Unknown:
		return t
	case ^Operation:
		#partial switch v.op {
		case .Add, .Sub, .Mul:
			out := atomized(k, v.args[0], back)
			for a in v.args[1:] {
				next, ok := ring_law(v.op, {out, atomized(k, a, back)})
				if !ok do break
				out = next
			}
			if _, _, ring := monomials(out); ring do return out
		case .Neg:
			if out, ok := ring_law(.Neg, {atomized(k, v.args[0], back)}); ok do return out
		}
	}
	for x in back do if x.unknown != nil && same(k, x.term, t) do return x.unknown
	u := new_unknown(k, nil)
	u.layout = family_term(.Int)
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
	s.index = new_unknown(k, nil)
	s.index.layout = family_term(.Int)
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
	if proven_in(k, n, new_range(nil, Int(0), .Int)) do return identity
	if s.op == .Add {
		if sum, closed := faulhaber(k, s); closed do return sum
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
	if alpha, beta, affine := affine_in(s.term, s.index); affine {
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
	if same(k, s.term, s.index) && proven_in(k, s.lo, new_range(nil, Int(0), .Int)) && proven_in(k, s.hi, new_range(Int(0), nil, .Int)) do return Int(0)
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
		return f.start, ring_law(.Sub, {r.lo, Int(1)}) or_return, true
	}
	if same(k, f.next, op(k, .Sub, f.index, Int(1))) && r.hi != nil && r.lo == nil {
		return ring_law(.Add, {r.hi, Int(1)}) or_return, f.start, true
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
