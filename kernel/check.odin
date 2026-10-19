package kernel

import "core:fmt"
import "core:slice"

// La vérification finale : une fois tout typé, la valeur de chaque binding coloré
// doit être un élément de sa couleur, pour toute valeur des inconnues. C'est la
// seule question du typecheck ; elle a trois issues.
Verdict :: enum u8 {
	Proved, // toute valeur possible est admise
	Refuted, // une valeur possible ne l'est pas
	Undecided, // on ne sait pas le prouver : jamais une acceptation
}

verdict :: proc(holds: bool) -> Verdict {
	return holds ? .Proved : .Refuted
}

check :: proc(k: ^Kernel) {
	for s in k.typed {
		for &b in s.bindings {
			if b.color_type == nil || b.value_type == nil || is_invalid(b.color_type) || is_invalid(b.value_type) do continue
			enter(k, s, &b)
			color, _ := color_set(k, b.color_type) // un seul ensemble : vérifié au typage
			ctx := context_of(s) // ce que les branches qui entourent le binding savent
			switch admits(k, color, b.value_type, ctx) {
			case .Proved:
			case .Refuted:
				if field, set, found := refused_field(k, color, b.value_type, ctx); found {
					report_about(k, .Constraint_Mismatch, b.span, field.span, fmt.tprintf("%s ∉ %s sur %s, dans %s", brief(field.value_type), print_set(set), display(field), display(&b)))
				} else {
					report(k, .Constraint_Mismatch, b.span, fmt.tprintf("%s ∉ %s sur %s", brief(b.value_type), brief(b.color_type), display(&b)))
				}
			case .Undecided:
				report(k, .Unproven, b.span, fmt.tprintf("%s ∈ %s n'a pas pu être prouvé sur %s", brief(b.value_type), brief(b.color_type), display(&b)))
			}
		}
	}
	k.scene = {}
}

// refused_field : quand la couleur est une seule forme et la valeur un scope, le
// binding de la valeur que la forme refuse — au plus profond, quand c'est un scope
// refusé par une forme plus intérieure — et ce que la forme y admet.
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

// admits : pour toute valeur des inconnues, la valeur que désigne le type `t` est
// un élément de la couleur.
admits :: proc(k: ^Kernel, color: Set, t: ^Expr, ctx: Context = nil) -> Verdict {
	if is_invalid(t) do return .Proved // déjà signalé ailleurs
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
		// chaque cas, sous ce que sa branche sait
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

// member : la valeur `v`, connue, est un élément de la couleur. Un atome (ou none)
// se lit parmi ses atomes ; un ensemble d'au moins deux éléments n'est l'élément
// que d'une couleur qui l'admet comme valeur : `u8:a -> u8` est refusé,
// `{-> u8}:a -> u8` est admis.
member :: proc(v, color: Set) -> bool {
	if is_atom(v) do return atoms_admitted(v, color)
	return values_contains(color.sets, v)
}

// form_in : pour toute valeur des inconnues, l'ensemble que vaut la forme est un
// élément de la couleur.
form_in :: proc(k: ^Kernel, t: ^Expr, c: Set, ctx: Context = nil) -> Verdict {
	// Sans ensemble admis comme valeur, une forme jamais vide dont l'enveloppe évite
	// la couleur est refusée : chacune de ses valeurs est hors de la couleur.
	if values_is_empty(c.sets) && never_empty(k, t) {
		if env, ok := set_envelope(k, t); ok && none_admitted(env, c) do return .Refuted
	}
	// un témoin aux bornes des domaines : un ensemble que vaut la forme, hors de c
	if set_outside_at_bounds(k, t, c, ctx) do return .Refuted
	return .Undecided
}

// set_outside_at_bounds : en mettant chaque inconnue de la forme t à l'une des
// bornes de son domaine, t vaut un ensemble que c n'admet pas.
set_outside_at_bounds :: proc(k: ^Kernel, t: ^Expr, c: Set, ctx: Context) -> bool {
	vars, bounds, finite := corners(k, t, ctx)
	if !finite do return false
	env := make([]Atom, k.variables, context.temp_allocator)
	for corner in 0 ..< 1 << uint(len(vars)) {
		for x, i in vars do env[x.id] = bounds[i][(corner >> uint(i)) & 1]
		if s, ok := eval_set(k, t, env); ok && !member(s, c) do return true
	}
	return false
}

// corners : les inconnues de t, et les bornes de leurs domaines dans ctx — des
// valeurs qu'elles peuvent prendre. Faux sans bornes finies, ou trop d'inconnues.
corners :: proc(k: ^Kernel, t: ^Expr, ctx: Context) -> (vars: []^Var, bounds: [][2]Atom, finite: bool) {
	found := make([dynamic]^Var, context.temp_allocator)
	collect_symbols(t, &found)
	slice.sort_by(found[:], var_less)
	vars = slice.unique(found[:])
	if len(vars) > 12 do return
	bounds = make([][2]Atom, len(vars), context.temp_allocator)
	for x, i in vars {
		d, solved := known_domain(ctx, x)
		if !solved do return
		lo, hi, bounded := atom_bounds(d)
		if !bounded do return
		bounds[i] = {lo, hi}
	}
	return vars, bounds, true
}

// value_in : ∀σ, ⟦v⟧σ est admise par c — par paliers, du moins cher au plus cher.
value_in :: proc(k: ^Kernel, v: ^Expr, c: Set, ctx: Context = nil) -> Verdict {
	// 1. L'enveloppe, sans énumérer : la forme normale a déjà fait `n - n = 0`.
	env, exact := envelope(k, v, ctx)
	if atoms_admitted(env, c) do return .Proved
	if exact || none_admitted(env, c) do return .Refuted
	// 2. Une forme linéaire : a·x + b se décide exactement ; sinon son min et son max
	//    sont atteints, aux bornes des inconnues.
	if r, affine := affine_in(k, v, c, ctx); affine do return r
	if lo, hi, linear := linear_extremes(k, v, ctx); linear {
		if l, ok := lo.?; ok && !ints_contains(c.ints, l) do return .Refuted
		if h, ok := hi.?; ok && !ints_contains(c.ints, h) do return .Refuted
	}
	// 3. Un témoin : les bornes des domaines sont des valeurs possibles ; une valeur
	//    hors de c en l'une d'elles réfute. On n'énumère pas.
	if outside_at_bounds(k, v, c, ctx) do return .Refuted
	return .Undecided
}

// outside_at_bounds : en mettant chaque inconnue de v à l'une des bornes de son
// domaine dans ctx, v prend une valeur hors de c.
outside_at_bounds :: proc(k: ^Kernel, v: ^Expr, c: Set, ctx: Context) -> bool {
	vars, bounds, finite := corners(k, v, ctx)
	if !finite do return false
	env := make([]Atom, k.variables, context.temp_allocator)
	for corner in 0 ..< 1 << uint(len(vars)) {
		for x, i in vars do env[x.id] = bounds[i][(corner >> uint(i)) & 1]
		if r, ok := eval(v, env); ok && !atoms_admitted(set_of_atoms({r}), c) do return true
	}
	return false
}

// atom_bounds : le plus petit et le plus grand élément d'un domaine d'entiers ou de
// caractères — des valeurs qu'il contient.
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

// none_admitted : aucune valeur de t n'est admise par c.
none_admitted :: proc(t, c: Set) -> bool {
	if !set_is_empty(set_intersect(t, c)) do return false
	return strings_count(strings_intersect(chars_as_strings(t.chars), c.strings)) == 0
}

// affine_in : v = a·x + b, une seule inconnue. Ses valeurs hors de c sont celles
// qui tombent dans un trou de c ; l'antécédent d'un trou est un intervalle de x,
// qu'on croise avec l'ensemble de x.
affine_in :: proc(k: ^Kernel, v: ^Expr, c: Set, ctx: Context = nil) -> (Verdict, bool) {
	p, is_poly := v^.(Poly)
	if !is_poly || den(p) != 1 || len(p.monos) != 1 || len(p.monos[0].vars) != 1 do return .Undecided, false
	a, b := p.monos[0].coef, p.const
	known, solved := known_domain(ctx, p.monos[0].vars[0])
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

// preimage : la borne de x telle que a·x + b atteint `bound` — arrondie vers
// l'intérieur du trou (`up` : vers le haut). nil reste infini.
preimage :: proc(bound: Maybe(i128), a, b: i128, up: bool) -> (Maybe(i128), bool) {
	y, finite := bound.?
	if !finite do return nil, true
	d, ok := add_checked(y, -b)
	if !ok do return nil, false
	return up ? -floor_div(-d, a) : floor_div(d, a), true
}

// linear_extremes : le min et le max d'un polynôme de degré 1, atteints quand
// chaque inconnue est à une borne de son ensemble (une borne finie en fait partie).
// nil : infini de ce côté, ou au-delà de l'univers.
linear_extremes :: proc(k: ^Kernel, v: ^Expr, ctx: Context = nil) -> (lo, hi: Maybe(i128), ok: bool) {
	p, is_poly := v^.(Poly)
	if !is_poly || den(p) != 1 do return nil, nil, false
	for m in p.monos do if len(m.vars) != 1 do return nil, nil, false
	lo, hi = p.const, p.const
	for m in p.monos {
		d, solved := known_domain(ctx, m.vars[0])
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

// atoms_admitted : les valeurs possibles `t` sont admises par la couleur `c`.
// `none` n'est l'élément d'aucun ensemble d'atomes : seule une couleur vide
// l'admet. Une couleur de chaînes admet un caractère comme la chaîne d'une lettre.
atoms_admitted :: proc(t, c: Set) -> bool {
	if set_is_empty(t) do return set_is_empty(c)
	if set_subset(t, c) do return true
	outside := ints_intersect(t.chars, ints_complement(c.chars))
	lifted := t
	lifted.chars = {}
	lifted.strings = strings_union(t.strings, chars_as_strings(outside))
	return set_subset(lifted, c)
}

// atoms_subset : a ⊆ b, deux types d'atomes, strictement (sans admission).
atoms_subset :: proc(a, b: Set) -> bool {
	if set_is_empty(a) do return set_is_empty(b)
	return set_subset(a, b)
}
