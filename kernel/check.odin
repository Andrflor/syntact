package kernel

import syn "../compiler"
import "core:fmt"
import "core:slice"

// The final check: once everything is typed, the value of each colored binding
// must be an element of its color, for every value of the unknowns — those of the
// value, and those of the color when it depends on some. It is the only question
// of the typecheck; it has three outcomes.
Verdict :: enum u8 {
	Proved, // every possible value is admitted
	Refuted, // a possible value is not
	Undecided, // we cannot prove it: never an acceptance
}

verdict :: proc(holds: bool) -> Verdict {
	return holds ? .Proved : .Refuted
}

check :: proc(k: ^Kernel) {
	for s in k.typed {
		for &b in s.bindings {
			if b.color_type == nil || b.value_type == nil || is_invalid(b.color_type) || is_invalid(b.value_type) do continue
			enter(k, s, &b)
			ctx := context_of(s) // what the branches around the binding know
			switch admitted(k, b.color_type, b.value_type, ctx) {
			case .Proved:
			case .Refuted:
				if color, closed := color_set(k, b.color_type); closed {
					if field, set, found := refused_field(k, color, b.value_type, ctx); found {
						report_about(k, .Constraint_Mismatch, b.span, field.span, fmt.tprintf("%s ∉ %s on %s, in %s", brief(field.value_type), print_set(set), display(field), display(&b)))
						continue
					}
				}
				report(k, .Constraint_Mismatch, b.span, fmt.tprintf("%s ∉ %s on %s", brief(b.value_type), brief(b.color_type), display(&b)))
			case .Undecided:
				report(k, .Unproven, b.span, fmt.tprintf("%s ∈ %s could not be proved on %s", brief(b.value_type), brief(b.color_type), display(&b)))
			}
		}
	}
	k.scene = {}
}

// refused_field: when the color is a single shape and the value a scope, the
// binding of the value that the shape refuses — at the deepest, when it is a scope
// refused by a shape further inside — and what the shape admits there.
refused_field :: proc(k: ^Kernel, color: Set, t: ^Expr, ctx: Context = nil) -> (field: ^Binding, set: Set, found: bool) {
	s, is_scope := t^.(^Scope)
	if !is_scope do return
	n, is_node := color.scopes.(^Bdd_Node)
	if !is_node || !is_leaf(n.yes, .Top) || !is_leaf(n.maybe, .Bottom) || !is_leaf(n.no, .Bottom) || has_run(n.atom) do return
	shown := places(s)
	if len(shown) != len(n.atom.fields) do return
	for f, i in n.atom.fields {
		b := binding_at(shown[i])
		if f.free || b.value_type == nil || admits(k, f.set, b.value_type, ctx) != .Refuted do continue
		if inner, inner_set, deeper := refused_field(k, f.set, b.value_type, ctx); deeper do return inner, inner_set, true
		return b, f.set, true
	}
	return
}

// admitted: for every value of the unknowns, the value v is an element of the
// color c. The rules are those of a known color (admits): when c depends on
// unknowns, they move to the value's side, as in algebra — each condition puts a
// value against a known set (conditions). A color whose unknowns cannot be moved
// can still be refuted by a witness.
admitted :: proc(k: ^Kernel, c, v: ^Expr, ctx: Context) -> Verdict {
	conds := make([dynamic]Condition, context.temp_allocator)
	if !conditions(k, c, v, ctx, &conds) do return outside_at_bounds(k, c, v, ctx) ? .Refuted : .Undecided
	r := Verdict.Proved
	for x in conds {
		r = both(r, admits(k, x.set, x.value, x.ctx))
		if r == .Refuted do break
	}
	return r
}

// Condition: a value against a known set, in a context.
Condition :: struct {
	set:   Set,
	value: ^Expr,
	ctx:   Context,
}

// conditions: `v ∈ c` as conditions that must all hold, whose left side is known.
// Each constructor of c says, by its definition, how its unknowns move to the
// value's side:
//
//   v ∈ S          S known               v ∈ S
//   v ∈ x          a value               (v = x) ∈ {true}
//   v ∈ >x         >=x, <x, <=x, !=x     (v > x) ∈ {true}
//   v ∈ lo..hi     lo <= hi              (lo <= v) ∈ {true}  and  (v <= hi) ∈ {true}
//   v ∈ A & B                            those of A, and those of B
//   by cases       v or c                those of each case, under what its branch knows
//
// False for what these conditions cannot write: a union or a complement that
// depends on unknowns, bounds that cannot be ordered.
conditions :: proc(k: ^Kernel, c, v: ^Expr, ctx: Context, out: ^[dynamic]Condition) -> bool {
	if set, closed := color_set(k, c); closed {
		append(out, Condition{set, v, ctx})
		return true
	}
	if x, is_cases := v^.(Cases); is_cases {
		for e in x.cases do if reachable(k, ctx, e.fact) do conditions(k, c, e.value, with(ctx, e.fact), out) or_return
		return true
	}
	#partial switch x in c^ {
	case Cases:
		for e in x.cases do if reachable(k, ctx, e.fact) do conditions(k, e.value, v, with(ctx, e.fact), out) or_return
		return true
	case Poly, Term, ^Var:
		return compared(k, .Equal, v, c, ctx, out)
	case Set_Form:
		#partial switch x.op.kind {
		case .Half:
			return compared(k, x.op.half, v, x.args[0], ctx, out)
		case .Inter:
			return conditions(k, x.args[0], v, ctx, out) && conditions(k, x.args[1], v, ctx, out)
		case .Range:
			// between numbers or characters, v lies between the bounds, in either
			// order (`2..1` is `1..2`); between strings, `..` means "starts with" and
			// "ends with", which comparisons cannot write
			lo, hi := x.args[0], x.args[1]
			if !ordered_sort(k, x.op.lo_open ? hi : lo) do return false
			if !x.op.lo_open && !x.op.hi_open && !holds(k, .LessEqual, lo, hi, ctx) {
				if !holds(k, .LessEqual, hi, lo, ctx) do return false
				lo, hi = hi, lo
			}
			if !x.op.lo_open do compared(k, .LessEqual, lo, v, ctx, out) or_return
			if !x.op.hi_open do compared(k, .LessEqual, v, hi, ctx, out) or_return
			return true
		}
	}
	return false
}

// compared: the condition `(a ⋈ b) ∈ {true}`, by the algebra's comparison. False
// when ⋈ does not compare a and b.
compared :: proc(k: ^Kernel, kind: syn.Operator_Kind, a, b: ^Expr, ctx: Context, out: ^[dynamic]Condition) -> bool {
	t := comparison_of(k, kind, a, b, ctx) or_return
	append(out, Condition{set_of_bools({.True}), t, ctx})
	return true
}

// holds: `a ⋈ b` is true for every value of the unknowns.
holds :: proc(k: ^Kernel, kind: syn.Operator_Kind, a, b: ^Expr, ctx: Context) -> bool {
	t, comparable := comparison_of(k, kind, a, b, ctx)
	return comparable && admits(k, set_of_bools({.True}), t, ctx) == .Proved
}

// ordered_sort: t is a value of an ordered sort — a number or a character.
ordered_sort :: proc(k: ^Kernel, t: ^Expr) -> bool {
	d, ok := value_domain(k, t)
	return ok && is_value(t) && (d == .Ints || d == .Floats || d == .Chars)
}

// comparison_of: the type of `a ⋈ b`. `=` and `!=` compare two values of any
// sorts; an order compares two values of the same sort.
comparison_of :: proc(k: ^Kernel, kind: syn.Operator_Kind, a, b: ^Expr, ctx: Context) -> (^Expr, bool) {
	if !is_value(a) || !is_value(b) do return nil, false
	if kind != .Equal && kind != .NotEqual {
		da, a_ok := value_domain(k, a)
		db, b_ok := value_domain(k, b)
		if !a_ok || !b_ok || da != db do return nil, false
	}
	t := binary(k, Op{kind = kind}, a, b, ctx)
	return t, !is_invalid(t)
}

// reachable: the fact of a case is compatible with the context. Otherwise no value
// of the unknowns leads to it: the case asks for nothing.
reachable :: proc(k: ^Kernel, ctx: Context, f: Fact) -> bool {
	if f.var == nil do return true
	d, solved := known_domain(k, ctx, f.var)
	return !solved || !set_is_empty(set_intersect(d, f.domain))
}

// both: two verdicts that must hold together.
both :: proc(a, b: Verdict) -> Verdict {
	if a == .Refuted || b == .Refuted do return .Refuted
	if a == .Undecided || b == .Undecided do return .Undecided
	return .Proved
}

// admits: for every value of the unknowns, the value that the type `t` designates
// is an element of the color.
admits :: proc(k: ^Kernel, color: Set, t: ^Expr, ctx: Context = nil) -> Verdict {
	if is_invalid(t) do return .Proved // already reported elsewhere
	#partial switch v in t^ {
	case Set:
		return verdict(member(v, color))
	case Poly, Term, ^Var:
		return value_in(k, t, color, ctx)
	case Set_Form:
		return form_in(k, t, color, ctx)
	case ^Scope:
		return bdd_admits(k, color.scopes, v, ctx)
	case Cases:
		// each case, under what its branch knows
		result := Verdict.Proved
		for c in v.cases {
			switch admits(k, color, c.value, with(ctx, c.fact)) {
			case .Proved:
			case .Refuted:
				return .Refuted
			case .Undecided:
				result = .Undecided
			}
		}
		return result
	}
	return .Refuted
}

// member: the value `v`, known, is an element of the color. An atom (or none) is
// read among its atoms; a set of at least two elements is the element only of a
// color that admits it as a value: `u8:a -> u8` is refused,
// `{-> u8}:a -> u8` is admitted.
member :: proc(v, color: Set) -> bool {
	if is_atom(v) do return atoms_admitted(v, color)
	return values_contains(color.sets, v)
}

// form_in: for every value of the unknowns, the set the form is worth is an
// element of the color.
form_in :: proc(k: ^Kernel, t: ^Expr, c: Set, ctx: Context = nil) -> Verdict {
	// Without a set admitted as a value, a never-empty form whose envelope avoids
	// the color is refused: each of its values is outside the color.
	if values_is_empty(c.sets) && never_empty(k, t) {
		if env, ok := set_envelope(k, t); ok && none_admitted(env, c) do return .Refuted
	}
	// a witness at the bounds of the domains: a set the form is worth, outside c
	if outside_at_bounds(k, new_expr(c), t, ctx) do return .Refuted
	return .Undecided
}

// outside_at_bounds: setting each unknown of the value v and of the color c to one
// of the bounds of its domain in ctx, v is not an element of what c is worth — a
// possible value outside the color. A scope is not evaluated at a point.
outside_at_bounds :: proc(k: ^Kernel, c, v: ^Expr, ctx: Context) -> bool {
	if _, is_scope := v^.(^Scope); is_scope do return false
	vars, bounds, finite := corners(k, ctx, c, v)
	if !finite do return false
	env := make([]Atom, k.variables, context.temp_allocator)
	for corner in 0 ..< 1 << uint(len(vars)) {
		for x, i in vars do env[x.id] = bounds[i][(corner >> uint(i)) & 1]
		color, colored := eval_set(k, c, env)
		value, valued := eval_set(k, v, env)
		if colored && valued && !member(value, color) do return true
	}
	return false
}

// corners: the unknowns of the types ts, and the bounds of their domains in ctx —
// values they can take. False without finite bounds, or with too many unknowns.
corners :: proc(k: ^Kernel, ctx: Context, ts: ..^Expr) -> (vars: []^Var, bounds: [][2]Atom, finite: bool) {
	found := make([dynamic]^Var, context.temp_allocator)
	for t in ts do collect_symbols(t, &found)
	slice.sort_by(found[:], var_less)
	vars = slice.unique(found[:])
	if len(vars) > 12 do return
	bounds = make([][2]Atom, len(vars), context.temp_allocator)
	for x, i in vars {
		d, solved := known_domain(k, ctx, x)
		if !solved do return
		lo, hi, bounded := atom_bounds(d)
		if !bounded do return
		bounds[i] = {lo, hi}
	}
	return vars, bounds, true
}

// value_in: ∀σ, ⟦v⟧σ is admitted by c — in tiers, from cheapest to most expensive.
value_in :: proc(k: ^Kernel, v: ^Expr, c: Set, ctx: Context = nil) -> Verdict {
	// 1. The envelope, without enumerating: the normal form already did `n - n = 0`.
	env, exact := envelope(k, v, ctx)
	if atoms_admitted(env, c) do return .Proved
	if exact || none_admitted(env, c) do return .Refuted
	// 2. A linear form: a·x + b is decided exactly; otherwise its min and its max
	//    are reached, at the bounds of the unknowns.
	if r, affine := affine_in(k, v, c, ctx); affine do return r
	if lo, hi, linear := linear_extremes(k, v, ctx); linear {
		if l, ok := lo.?; ok && !ints_contains(c.ints, l) do return .Refuted
		if h, ok := hi.?; ok && !ints_contains(c.ints, h) do return .Refuted
	}
	// 3. A witness: the bounds of the domains are possible values; a value outside
	//    c at one of them refutes. We do not enumerate.
	if outside_at_bounds(k, new_expr(c), v, ctx) do return .Refuted
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

// affine_in: v = a·x + b, a single unknown. Its values outside c are those that
// fall into a gap of c; the preimage of a gap is an interval of x, which we
// intersect with the set of x.
affine_in :: proc(k: ^Kernel, v: ^Expr, c: Set, ctx: Context = nil) -> (Verdict, bool) {
	p, is_poly := v^.(Poly)
	if !is_poly || den(p) != 1 || len(p.monos) != 1 || len(p.monos[0].vars) != 1 do return .Undecided, false
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
// inside of the gap (`up`: upward). nil stays infinite.
preimage :: proc(bound: Maybe(i128), a, b: i128, up: bool) -> (Maybe(i128), bool) {
	y, finite := bound.?
	if !finite do return nil, true
	d, ok := add_checked(y, -b)
	if !ok do return nil, false
	return up ? -floor_div(-d, a) : floor_div(d, a), true
}

// linear_extremes: the min and the max of a polynomial of degree 1, reached when
// each unknown is at a bound of its set (a finite bound belongs to it).
// nil: infinite on that side, or beyond the universe.
linear_extremes :: proc(k: ^Kernel, v: ^Expr, ctx: Context = nil) -> (lo, hi: Maybe(i128), ok: bool) {
	p, is_poly := v^.(Poly)
	if !is_poly || den(p) != 1 do return nil, nil, false
	for m in p.monos do if len(m.vars) != 1 do return nil, nil, false
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
