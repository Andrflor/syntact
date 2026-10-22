package kernel

import "core:slice"

// DECIDING A TRUTH
//
// A truth — a type `x in c`, a comparison, and what & | ~ make of them — holds
// when true is one of its elements. The check asks whether it holds for every
// value of the unknowns (in.odin). Three outcomes: it is proved; it is refuted —
// there is a value of the unknowns where it does not hold; or we cannot tell,
// which is never an acceptance (Unproven).
//
// Without running through the values of the unknowns, from cheapest to most
// expensive: the truth is known; it follows from what is known at its place — the
// facts of the branches around it, and each unknown in its domain when that
// domain is an equation over others (`e in 0..n`); in a single unknown, its
// solution covers the domain of that unknown or not; `a & b` holds when a and b
// do, `a | b` when one does, or when the other does wherever the first does not;
// the envelope decides it; `a·x + b in K` is decided exactly; a value of the
// unknowns at the bounds of their domains where it does not hold refutes it.

Verdict :: enum u8 {
	Proved, // it holds for every value of the unknowns
	Refuted, // a value of the unknowns where it does not hold
	Undecided, // we cannot prove it: never an acceptance
}

verdict :: proc(holds: bool) -> Verdict {
	return holds ? .Proved : .Refuted
}

// both: two verdicts that must hold together.
both :: proc(a, b: Verdict) -> Verdict {
	if a == .Refuted || b == .Refuted do return .Refuted
	if a == .Undecided || b == .Undecided do return .Undecided
	return .Proved
}

// decide: the truth t, for every value of the unknowns, in the context ctx.
decide :: proc(k: ^Kernel, t: ^Expr, ctx: Context) -> Verdict {
	return decided(k, t, ctx, hypotheses(k, t, ctx))
}

decided :: proc(k: ^Kernel, t: ^Expr, ctx: Context, hyps: []^Expr) -> Verdict {
	if s, known := t^.(Set); known do return verdict(.True in s.bools)
	if entailed(k, hyps, t) do return .Proved
	if x, lone := lone_unknown(t); lone && !dependent(x) {
		// a truth in a single unknown: solved, it holds on its whole domain or not
		if s, solved := solution(k, t, x); solved {
			if domain, known := known_domain(k, ctx, x); known do return verdict(set_subset(domain, s))
		}
	}
	#partial switch v in t^ {
	case Cases:
		// each case, under what its branch knows
		result := Verdict.Proved
		for c in v.cases {
			if !reachable(k, ctx, c.fact) do continue
			result = both(result, decided(k, c.value, with(ctx, c.fact), hyps))
			if result == .Refuted do break
		}
		return result
	case Set_Form:
		#partial switch v.op.kind {
		case .Inter:
			return both(decided(k, v.args[0], ctx, hyps), decided(k, v.args[1], ctx, hyps))
		case .Union:
			for a in v.args do if decided(k, a, ctx, hyps) == .Proved do return .Proved
			if split(k, v, ctx, hyps) do return .Proved
		}
	}
	return leaf(k, t, ctx)
}

// leaf: a truth that & and | no longer split — by its envelope, by the exact tiers
// of `x in K`, by a value of the unknowns at the bounds.
leaf :: proc(k: ^Kernel, t: ^Expr, ctx: Context) -> Verdict {
	possible := truths(k, t, ctx)
	if possible == {.True} do return .Proved
	if possible == {.False} do return .Refuted
	if x, is_term := t^.(Term); is_term && x.op == .In {
		if set, known := x.args[1]^.(Set); known && is_value(x.args[0]) {
			if r := value_in(k, x.args[0], set, ctx); r != .Undecided do return r
		}
	}
	return refuted_at_bounds(k, t, ctx) ? .Refuted : .Undecided
}

// reachable: the fact of a case can hold in the context. Otherwise no value of the
// unknowns leads to it: the case asks for nothing.
reachable :: proc(k: ^Kernel, ctx: Context, fact: ^Expr) -> bool {
	if fact == nil do return true
	if x, lone := lone_unknown(fact); lone {
		if s, solved := solution(k, fact, x); solved {
			d, known := known_domain(k, ctx, x)
			return !known || !set_is_empty(set_intersect(d, s))
		}
	}
	return .True in truths(k, fact, ctx)
}

// --- what is known ---

// hypotheses: what is known where t is decided — the facts of the context, and
// each unknown of t in its domain when that domain is an equation over others.
hypotheses :: proc(k: ^Kernel, t: ^Expr, ctx: Context) -> []^Expr {
	out := make([dynamic]^Expr, context.temp_allocator)
	append(&out, ..ctx)
	for x in unknowns_of(t) do if dependent(x) do append(&out, in_type(k, var_value(k, x), x.type, nil))
	return out[:]
}

// var_value: the variable x as a value — a polynomial when its values are integers.
var_value :: proc(k: ^Kernel, x: ^Var) -> ^Expr {
	if d, known := known_domain(k, nil, x); known {
		if sort, pure := pure_domain(d); pure && sort == .Ints do return new_expr(poly_var(x))
	}
	return new_expr(x)
}

// unknowns_of: the unknowns t depends on, and those their domains depend on, in
// the order of their creation.
unknowns_of :: proc(t: ^Expr) -> []^Var {
	found := make([dynamic]^Var, context.temp_allocator)
	collect_symbols(t, &found)
	for i := 0; i < len(found); i += 1 do if dependent(found[i]) do collect_symbols(found[i].type, &found)
	slice.sort_by(found[:], var_less)
	return slice.unique(found[:])
}

// entailed: one of the hypotheses implies t.
entailed :: proc(k: ^Kernel, hyps: []^Expr, t: ^Expr) -> bool {
	for h in hyps do if implies(k, h, t) do return true
	return false
}

// implies: h implies t — it is t; t holds when each of its parts does (&), or one
// of them (|); h gives each of its parts (&), or one of its alternatives, each
// of which implies t (|).
implies :: proc(k: ^Kernel, h, t: ^Expr) -> bool {
	if expr_equal(k, h, t) do return true
	if x, is_form := t^.(Set_Form); is_form {
		#partial switch x.op.kind {
		case .Inter:
			if implies(k, h, x.args[0]) && implies(k, h, x.args[1]) do return true
		case .Union:
			if implies(k, h, x.args[0]) || implies(k, h, x.args[1]) do return true
		}
	}
	if y, is_form := h^.(Set_Form); is_form {
		#partial switch y.op.kind {
		case .Inter:
			return implies(k, y.args[0], t) || implies(k, y.args[1], t)
		case .Union:
			return implies(k, y.args[0], t) && implies(k, y.args[1], t)
		}
	}
	return false
}

// --- `a | b` by cases ---

// split: `a | b` holds when the other holds wherever one does not — that one
// solved for its unknown, the other decided on the rest of its domain.
split :: proc(k: ^Kernel, v: Set_Form, ctx: Context, hyps: []^Expr) -> bool {
	for d, i in v.args {
		x, lone := lone_unknown(d)
		if !lone do continue
		s, solved := solution(k, d, x)
		if !solved do continue
		domain, known := known_domain(k, ctx, x)
		if !known do continue
		rest := set_diff(domain, s)
		if set_is_empty(rest) do return true
		elsewhere := new_expr(Term{op = .In, args = pair(var_value(k, x), new_expr(rest))})
		if decided(k, v.args[1 - i], with(ctx, elsewhere), hyps) == .Proved do return true
	}
	return false
}

// lone_unknown: t depends on a single unknown.
lone_unknown :: proc(t: ^Expr) -> (^Var, bool) {
	vars := unknowns_of(t)
	if len(vars) != 1 || is_equation(vars[0]) do return nil, false
	return vars[0], true
}

// solution: the values of the unknown x for which the truth t holds, when t
// depends on x alone — a known set. False when no law solves it.
solution :: proc(k: ^Kernel, t: ^Expr, x: ^Var) -> (set: Set, ok: bool) {
	#partial switch v in t^ {
	case Set:
		return .True in v.bools ? set_everything() : Set{}, true
	case ^Var:
		if v == x do return set_of_bools({.True}), true // a boolean unknown holds when it is true
	case Set_Form:
		#partial switch v.op.kind {
		case .Inter, .Union:
			a := solution(k, v.args[0], x) or_return
			b := solution(k, v.args[1], x) or_return
			return v.op.kind == .Inter ? set_intersect(a, b) : set_union(a, b), true
		case .Comp:
			a := solution(k, v.args[0], x) or_return
			return set_diff(set_everything(), a), true
		}
	case Term:
		#partial switch v.op {
		case .In:
			c := v.args[1]^.(Set) or_return
			if lone, is_lone := lone_symbol(v.args[0]); is_lone && lone == x {
				// a set of strings admits a character as a string of one letter: the
				// solution of a character among strings is not that set
				domain := known_domain(k, nil, x) or_return
				if domain_count(domain, .Chars) > 0 && domain_count(c, .Strings) > 0 do return {}, false
				return c, true
			}
			return affine_preimage(v.args[0], c, x)
		case .Lt, .Le, .Eq, .Ne:
			if len(v.args) == 1 do return solve_linear(v.op, v.args[0], x)
			return solve_compare(v.op, v.args[0], v.args[1], x)
		}
	}
	return {}, false
}

// affine_preimage: the integers x for which a·x + b is in the set of integers c —
// the preimage of each of its intervals.
affine_preimage :: proc(t: ^Expr, c: Set, x: ^Var) -> (set: Set, ok: bool) {
	p := as_poly(t) or_return
	if den(p) != 1 || len(p.monos) != 1 || len(p.monos[0].vars) != 1 || p.monos[0].vars[0] != x || carried(c) != {.Ints} do return {}, false
	a, b := p.monos[0].coef, p.const
	runs := make([dynamic]Int_Interval, context.temp_allocator)
	for iv in c.ints.intervals {
		lo := preimage(iv.lo, a, b, a > 0) or_return
		hi := preimage(iv.hi, a, b, a < 0) or_return
		if a < 0 do lo, hi = hi, lo
		append(&runs, Int_Interval{lo, hi})
	}
	return set_of_ints(ints_of(runs[:])), true
}

// solve_linear: the integers x for which a·x + b ⋈ 0 — p, of degree 1 in x alone.
solve_linear :: proc(op: Term_Op, t: ^Expr, x: ^Var) -> (set: Set, ok: bool) {
	p := as_poly(t) or_return
	if den(p) != 1 || len(p.monos) != 1 || len(p.monos[0].vars) != 1 || p.monos[0].vars[0] != x do return {}, false
	a, b := p.monos[0].coef, p.const
	#partial switch op {
	case .Eq, .Ne:
		at := b % a == 0 ? ints_point(-b / a) : Ints{}
		return set_of_ints(op == .Eq ? at : ints_complement(at)), true
	case .Lt:
		// a·x < -b
		if a > 0 do return set_of_ints(ints_range(nil, floor_div(-b - 1, a))), true
		return set_of_ints(ints_range(floor_div(b, -a) + 1, nil)), true
	}
	return {}, false
}

// solve_compare: the values of x for which x ⋈ c, or c ⋈ x, c a known atom.
solve_compare :: proc(op: Term_Op, a, b: ^Expr, x: ^Var) -> (set: Set, ok: bool) {
	left, l_lone := lone_symbol(a)
	right, r_lone := lone_symbol(b)
	c: Set
	known: bool
	x_left := l_lone && left == x
	switch {
	case x_left:
		c, known = b^.(Set)
	case r_lone && right == x:
		c, known = a^.(Set)
	}
	if !known || !is_atom(c) do return {}, false
	#partial switch op {
	case .Eq:
		return c, true
	case .Ne:
		return set_diff(set_everything(), c), true
	case .Lt:
		r, status := half_line(x_left ? .Less : .Greater, c)
		return r, status == .Ok
	case .Le:
		r, status := half_line(x_left ? .LessEqual : .GreaterEqual, c)
		return r, status == .Ok
	}
	return {}, false
}

// --- the possible truths ---

// truths: whether the truth t can hold, and whether it can fail, in the context
// ctx — a safe envelope. `a & b` can hold only when both can, fail when one can;
// `a | b` the other way round; `~a` holds where a fails.
truths :: proc(k: ^Kernel, t: ^Expr, ctx: Context) -> Bools {
	#partial switch v in t^ {
	case Set:
		return .True in v.bools ? {.True} : {.False}
	case Cases:
		r: Bools
		for c in v.cases do if reachable(k, ctx, c.fact) do r += truths(k, c.value, with(ctx, c.fact))
		return r
	case Set_Form:
		#partial switch v.op.kind {
		case .Inter, .Union:
			a := truths(k, v.args[0], ctx)
			b := truths(k, v.args[1], ctx)
			if v.op.kind == .Inter do return (a & b & {.True}) + ((a | b) & {.False})
			return ((a | b) & {.True}) + (a & b & {.False})
		case .Comp:
			a := truths(k, v.args[0], ctx)
			r: Bools
			if .True in a do r += {.False}
			if .False in a do r += {.True}
			return r
		}
	case Term:
		#partial switch v.op {
		case .In:
			return in_truths(k, v, ctx)
		case .Lt, .Le, .Eq, .Ne:
			if len(v.args) == 1 || (is_value(v.args[0]) && is_value(v.args[1])) do return comparison_envelope(k, v, ctx)
		}
	case Poly, ^Var:
		env, _ := envelope(k, t, ctx)
		if card(env.bools) > 0 do return env.bools
	}
	return {.False, .True}
}

// in_truths: whether `x in c` can hold, and fail, by the envelope of x. A set never
// empty whose values all lie outside c is never one of its elements — unless c has
// sets for elements.
in_truths :: proc(k: ^Kernel, t: Term, ctx: Context) -> Bools {
	x := t.args[0]
	set, known := t.args[1]^.(Set)
	if !known do return {.False, .True}
	if is_value(x) {
		env, _ := envelope(k, x, ctx)
		if atoms_admitted(env, set) do return {.True}
		if none_admitted(env, set) do return {.False}
		return {.False, .True}
	}
	if values_is_empty(set.sets) && never_empty(k, x) {
		if env, ok := set_envelope(k, x); ok && none_admitted(env, set) do return {.False}
	}
	return {.False, .True}
}

// --- a value in a known set ---

// value_in: for every value of the unknowns, the value v is an element of the known
// set c — by its envelope, then as a linear form: decided exactly with a single
// unknown, refuted by its extremes otherwise.
value_in :: proc(k: ^Kernel, v: ^Expr, c: Set, ctx: Context = nil) -> Verdict {
	// the envelope, without enumerating: the normal form already did `n - n = 0`
	env, exact := envelope(k, v, ctx)
	if atoms_admitted(env, c) do return .Proved
	if exact || none_admitted(env, c) do return .Refuted
	if r, affine := affine_in(k, v, c, ctx); affine do return r
	if lo, hi, linear := linear_extremes(k, v, ctx); linear {
		if l, ok := lo.?; ok && !ints_contains(c.ints, l) do return .Refuted
		if h, ok := hi.?; ok && !ints_contains(c.ints, h) do return .Refuted
	}
	return .Undecided
}

// atom_bounds: the smallest and the largest element of a domain of integers or of
// characters — values it contains.
atom_bounds :: proc(d: Set) -> (lo, hi: Atom, finite: bool) {
	kind, pure := pure_domain(d)
	if !pure do return
	#partial switch kind {
	case .Ints:
		lm, hm := ints_bounds(d.ints)
		l, l_ok := lm.?
		h, h_ok := hm.?
		if !l_ok || !h_ok do return
		return l, h, true
	case .Chars:
		lm, hm := ints_bounds(d.chars)
		l, l_ok := lm.?
		h, h_ok := hm.?
		if !l_ok || !h_ok do return
		return Char_Atom(l), Char_Atom(h), true
	}
	return
}

// none_admitted: no value of t is admitted by c.
none_admitted :: proc(t, c: Set) -> bool {
	if !set_is_empty(set_intersect(t, c)) do return false
	return strings_count(strings_intersect(chars_as_strings(t.chars), c.strings)) == 0
}

// affine_in: v = a·x + b, a single unknown whose domain is a set. Its values
// outside c are those that fall into a gap of c; the preimage of a gap is an
// interval of x, which we intersect with the set of x.
affine_in :: proc(k: ^Kernel, v: ^Expr, c: Set, ctx: Context = nil) -> (Verdict, bool) {
	p, is_poly := v^.(Poly)
	if !is_poly || den(p) != 1 || len(p.monos) != 1 || len(p.monos[0].vars) != 1 || dependent(p.monos[0].vars[0]) do return .Undecided, false
	a, b := p.monos[0].coef, p.const
	known, solved := known_domain(k, ctx, p.monos[0].vars[0])
	if !solved do return .Undecided, false
	domain := known.ints
	for gap in ints_complement(c.ints).intervals {
		lo, lo_ok := preimage(gap.lo, a, b, a > 0)
		hi, hi_ok := preimage(gap.hi, a, b, a < 0)
		if !lo_ok || !hi_ok do return .Undecided, false
		if a < 0 do lo, hi = hi, lo
		if len(ints_intersect(domain, ints_range(lo, hi)).intervals) > 0 do return .Refuted, true
	}
	return .Proved, true
}

// preimage: the bound of x such that a·x + b reaches `bound` — rounded toward the
// inside of the interval (`up`: upward). nil stays infinite.
preimage :: proc(bound: Maybe(i128), a, b: i128, up: bool) -> (Maybe(i128), bool) {
	y, finite := bound.?
	if !finite do return nil, true
	d, ok := add_checked(y, -b)
	if !ok do return nil, false
	return up ? -floor_div(-d, a) : floor_div(d, a), true
}

// linear_extremes: the min and the max of a polynomial of degree 1, reached when
// each unknown is at a bound of its set (a finite bound belongs to it). The
// unknowns are independent: none has a domain over the others.
// nil: infinite on that side, or beyond the universe.
linear_extremes :: proc(k: ^Kernel, v: ^Expr, ctx: Context = nil) -> (lo, hi: Maybe(i128), ok: bool) {
	p, is_poly := v^.(Poly)
	if !is_poly || den(p) != 1 do return nil, nil, false
	for m in p.monos do if len(m.vars) != 1 || dependent(m.vars[0]) do return nil, nil, false
	lo, hi = p.const, p.const
	for m in p.monos {
		d, solved := known_domain(k, ctx, m.vars[0])
		if !solved do return nil, nil, false
		l, h := ints_bounds(d.ints)
		if m.coef < 0 do l, h = h, l
		lo = scaled_sum(lo, m.coef, l)
		hi = scaled_sum(hi, m.coef, h)
	}
	return lo, hi, true
}

scaled_sum :: proc(acc: Maybe(i128), coef: i128, bound: Maybe(i128)) -> Maybe(i128) {
	a, a_ok := acc.?
	b, b_ok := bound.?
	if !a_ok || !b_ok do return nil
	p, p_ok := mul_checked(coef, b)
	if !p_ok do return nil
	s, s_ok := add_checked(a, p)
	if !s_ok do return nil
	return s
}

// atoms_admitted: the possible values `t` are admitted by the color `c`.
// `none` is the element of no set of atoms: only an empty color admits it. A
// color of strings admits a character as the string of one letter.
atoms_admitted :: proc(t, c: Set) -> bool {
	if set_is_empty(t) do return set_is_empty(c)
	if set_subset(t, c) do return true
	outside := ints_intersect(t.chars, ints_complement(c.chars))
	lifted := t
	lifted.chars = {}
	lifted.strings = strings_union(t.strings, chars_as_strings(outside))
	return set_subset(lifted, c)
}

// atoms_subset: a ⊆ b, two types of atoms, strictly (without admission).
atoms_subset :: proc(a, b: Set) -> bool {
	if set_is_empty(a) do return set_is_empty(b)
	return set_subset(a, b)
}

// --- a witness ---

// MAX_WITNESS_UNKNOWNS: beyond this, the bounds are not tried.
MAX_WITNESS_UNKNOWNS :: 12

// refuted_at_bounds: a value of the unknowns of t, each at a bound of its domain in
// ctx, where the facts of ctx hold and t does not — a witness. An unknown whose
// domain depends on others takes the bounds of that domain at their values.
// Without finite bounds, or with too many unknowns, there is none.
refuted_at_bounds :: proc(k: ^Kernel, t: ^Expr, ctx: Context) -> bool {
	found := make([dynamic]^Var, context.temp_allocator)
	collect_symbols(t, &found)
	for f in ctx do collect_symbols(f, &found)
	for i := 0; i < len(found); i += 1 do if dependent(found[i]) do collect_symbols(found[i].type, &found)
	slice.sort_by(found[:], var_less)
	vars := slice.unique(found[:])
	if len(vars) > MAX_WITNESS_UNKNOWNS do return false
	env := make([]Atom, k.variables, context.temp_allocator)
	return refuting(k, t, ctx, vars, 0, env)
}

// refuting: the unknowns vars[i:] take the bounds of their domains, the others
// keep theirs in env; true at a value where the facts hold and t does not.
refuting :: proc(k: ^Kernel, t: ^Expr, ctx: Context, vars: []^Var, i: int, env: []Atom) -> bool {
	if i == len(vars) {
		for f in ctx do if holds, known := holds_at(f, env); !known || !holds do return false
		holds, known := holds_at(t, env)
		return known && !holds
	}
	x := vars[i]
	d: Set
	if dependent(x) {
		at, ok := eval_set(x.type, env)
		if !ok do return false
		d = at
	} else {
		known, solved := known_domain(k, ctx, x)
		if !solved do return false
		d = known
	}
	lo, hi, bounded := atom_bounds(d)
	if !bounded do return false
	for a in ([2]Atom{lo, hi}) {
		env[x.id] = a
		if refuting(k, t, ctx, vars, i + 1, env) do return true
	}
	return false
}

// holds_at: the truth t when each unknown `id` is env[id] — true is one of the
// elements of what it is worth. No fact holds always.
holds_at :: proc(t: ^Expr, env: []Atom) -> (holds: bool, known: bool) {
	if t == nil do return true, true
	s := eval_set(t, env) or_return
	return .True in s.bools, true
}
