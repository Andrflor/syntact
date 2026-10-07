package kernel

import "core:fmt"

// La vérification finale : une fois tout typé, chaque binding coloré doit avoir
// toutes ses valeurs possibles admises par sa couleur. C'est la seule question
// du typecheck ; elle a trois issues.
Verdict :: enum u8 {
	Proved, // toute valeur possible est admise
	Refuted, // une valeur possible ne l'est pas
	Undecided, // on ne sait pas le prouver : jamais une acceptation
}

verdict :: proc(holds: bool) -> Verdict {
	return holds ? .Proved : .Refuted
}

check :: proc(k: ^Kernel) {
	for t in k.typed {
		for &b in t.bindings {
			if b.color == nil || b.value == nil || is_invalid(b.value) do continue
			switch admits(k, b.color, b.value) {
			case .Proved:
			case .Refuted:
				report(k, .Constraint_Mismatch, b.span, fmt.tprintf("%s ⊄ %s sur %s", brief(b.value), brief(b.color), display(&b)))
			case .Undecided:
				report(k, .Unproven, b.span, fmt.tprintf("%s ⊆ %s n'a pas pu être prouvé sur %s", brief(b.value), brief(b.color), display(&b)))
			}
		}
	}
}

// admits : toutes les valeurs possibles de `type` sont admises par la couleur
// `color`. Une couleur est un ensemble d'atomes, ou un scope lu comme ensemble.
admits :: proc(k: ^Kernel, color, type: ^Expr) -> Verdict {
	if is_invalid(color) || is_invalid(type) do return .Proved // déjà signalé ailleurs
	#partial switch c in color^ {
	case Set:
		#partial switch v in type^ {
		case Set:
			return verdict(atoms_admitted(v, c))
		case Poly, Term:
			return value_in(k, type, c)
		}
		if s, is_scope := scope_element(type); is_scope && first_production(s) < 0 do return bdd_admits(k, c.scopes, s)
		return .Refuted // un ensemble comme valeur n'est pas un élément d'un ensemble d'atomes
	case ^Scope:
		// une forme close se lit comme ensemble ; sinon binding par binding
		if s, ok := shape_set(c); ok do return admits(k, new_expr(s), type)
		return scope_admits(k, c, type)
	}
	return .Refuted
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

// scope_admits : un scope avec productions admet ce qu'admet l'une de ses
// productions ; sans production, il admet les scopes de même structure dont
// chaque binding est admis par le sien.
scope_admits :: proc(k: ^Kernel, c: ^Scope, type: ^Expr) -> Verdict {
	if first_production(c) >= 0 {
		result := Verdict.Refuted
		for b in c.bindings {
			if b.kind != .Product do continue
			switch binding_admits(k, b, type) {
			case .Proved:
				return .Proved
			case .Undecided:
				result = .Undecided
			case .Refuted:
			}
		}
		return result
	}
	v, ok := scope_element(type)
	if !ok || len(v.bindings) != len(c.bindings) do return .Refuted
	result := Verdict.Proved
	for cb, i in c.bindings {
		vb := v.bindings[i]
		if cb.name != vb.name || cb.kind != vb.kind do return .Refuted
		// un binding nommé sans couleur n'impose rien : un carve peut lui donner toute valeur
		if cb.color == nil && cb.name != "" do continue
		switch binding_admits(k, cb, vb.value) {
		case .Refuted:
			return .Refuted
		case .Undecided:
			result = .Undecided
		case .Proved:
		}
	}
	return result
}

// binding_admits : ce qu'un binding d'une couleur admet — ce qu'admet sa couleur
// s'il en a une, sinon les valeurs de son propre type.
binding_admits :: proc(k: ^Kernel, b: Binding, type: ^Expr) -> Verdict {
	if b.color != nil do return admits(k, b.color, type)
	return verdict(type_subset(k, type, b.value))
}

// type_subset : a ⊆ b, deux types (deux ensembles de valeurs possibles). Une
// inclusion affirmée ne repose jamais sur une sur-approximation.
type_subset :: proc(k: ^Kernel, a, b: ^Expr) -> bool {
	if is_invalid(a) || is_invalid(b) do return true
	if expr_equal(k, a, b) do return true
	if is_value(a) {
		if sb, ok := b^.(Set); ok {
			va, exact := values_of(k, a)
			return exact && atoms_subset(va, sb)
		}
		return false
	}
	xa, a_one := the_element(a)
	xb, b_one := the_element(b)
	return a_one && b_one && value_equal(k, xa, xb)
}

// value_equal : deux valeurs (éléments de types) identiques.
value_equal :: proc(k: ^Kernel, x, y: ^Expr) -> bool {
	#partial switch a in x^ {
	case Set:
		b, ok := y^.(Set)
		return ok && set_equal(a, b)
	case ^Scope:
		b, ok := y^.(^Scope)
		if !ok || len(a.bindings) != len(b.bindings) do return false
		for ab, i in a.bindings {
			bb := b.bindings[i]
			if ab.name != bb.name || ab.kind != bb.kind do return false
			if (ab.color == nil) != (bb.color == nil) do return false
			if ab.color != nil && !value_equal(k, ab.color, bb.color) do return false
			if !type_subset(k, ab.value, bb.value) || !type_subset(k, bb.value, ab.value) do return false
		}
		return true
	}
	return false
}
