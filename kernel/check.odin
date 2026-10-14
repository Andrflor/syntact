package kernel

import "core:fmt"

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
			switch admits(k, color, b.value_type) {
			case .Proved:
			case .Refuted:
				if field, set, found := refused_field(k, color, b.value_type); found {
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
refused_field :: proc(k: ^Kernel, color: Set, t: ^Expr) -> (field: ^Binding, set: Set, found: bool) {
	s, is_scope := t^.(^Scope)
	if !is_scope do return
	n, is_node := color.scopes.(^Bdd_Node)
	if !is_node || !is_leaf(n.yes, .Top) || !is_leaf(n.maybe, .Bottom) || !is_leaf(n.no, .Bottom) || has_run(n.atom) do return
	shown := places(s)
	if len(shown) != len(n.atom.fields) do return
	for f, i in n.atom.fields {
		b := binding_at(shown[i])
		if f.free || b.value_type == nil || admits(k, f.set, b.value_type) != .Refuted do continue
		if inner, inner_set, deeper := refused_field(k, f.set, b.value_type); deeper do return inner, inner_set, true
		return b, f.set, true
	}
	return
}

// admits : pour toute valeur des inconnues, la valeur que désigne le type `t` est
// un élément de la couleur.
admits :: proc(k: ^Kernel, color: Set, t: ^Expr) -> Verdict {
	if is_invalid(t) do return .Proved // déjà signalé ailleurs
	#partial switch v in t^ {
	case Set:
		return verdict(member(v, color))
	case Poly, Term:
		return value_in(k, t, color)
	case Set_Form:
		return form_in(k, t, color)
	case ^Scope:
		return bdd_admits(k, color.scopes, v)
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
form_in :: proc(k: ^Kernel, t: ^Expr, c: Set) -> Verdict {
	// Sans ensemble admis comme valeur, une forme jamais vide dont l'enveloppe évite
	// la couleur est refusée : chacune de ses valeurs est hors de la couleur.
	if values_is_empty(c.sets) && never_empty(k, t) {
		if env, ok := set_envelope(k, t); ok && none_admitted(env, c) do return .Refuted
	}
	a, enumerable := assignments(k, t)
	if !enumerable do return .Undecided
	for {
		s, ok := eval_set(k, t, a.env)
		if !ok do return .Undecided
		if !member(s, c) do return .Refuted
		if !next_assignment(&a) do break
	}
	return .Proved
}

// value_in : ∀σ, ⟦v⟧σ est admise par c — par paliers, du moins cher au plus cher.
value_in :: proc(k: ^Kernel, v: ^Expr, c: Set) -> Verdict {
	// 1. L'enveloppe, sans énumérer : la forme normale a déjà fait `n - n = 0`.
	env, exact := envelope(k, v)
	if atoms_admitted(env, c) do return .Proved
	if exact || none_admitted(env, c) do return .Refuted
	// 2. Une forme linéaire : a·x + b se décide exactement ; sinon son min et son max
	//    sont atteints, aux bornes des inconnues.
	if r, affine := affine_in(k, v, c); affine do return r
	if lo, hi, linear := linear_extremes(k, v); linear {
		if l, ok := lo.?; ok && !ints_contains(c.ints, l) do return .Refuted
		if h, ok := hi.?; ok && !ints_contains(c.ints, h) do return .Refuted
	}
	// 3. Exact, si les inconnues s'énumèrent.
	if vals, ok := enumerate(k, v); ok do return verdict(atoms_admitted(vals, c))
	return .Undecided
}

// none_admitted : aucune valeur de t n'est admise par c.
none_admitted :: proc(t, c: Set) -> bool {
	if !set_is_empty(set_intersect(t, c)) do return false
	return strings_count(strings_intersect(chars_as_strings(t.chars), c.strings)) == 0
}

// affine_in : v = a·x + b, une seule inconnue. Ses valeurs hors de c sont celles
// qui tombent dans un trou de c ; l'antécédent d'un trou est un intervalle de x,
// qu'on croise avec l'ensemble de x.
affine_in :: proc(k: ^Kernel, v: ^Expr, c: Set) -> (Verdict, bool) {
	p, is_poly := v^.(Poly)
	if !is_poly || len(p.monos) != 1 || len(p.monos[0].vars) != 1 do return .Undecided, false
	a, b := p.monos[0].coef, p.const
	domain := k.symbols[p.monos[0].vars[0]].ints
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
linear_extremes :: proc(k: ^Kernel, v: ^Expr) -> (lo, hi: Maybe(i128), ok: bool) {
	p, is_poly := v^.(Poly)
	if !is_poly do return nil, nil, false
	for m in p.monos do if len(m.vars) != 1 do return nil, nil, false
	lo, hi = p.const, p.const
	for m in p.monos {
		l, h := ints_bounds(k.symbols[m.vars[0]].ints)
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
