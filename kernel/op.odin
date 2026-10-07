package kernel

import syn "../compiler"
import "core:fmt"

// type_of d'un opérateur. Une seule loi pour tous :
//
//   type_of(a op b) = { x op y | x ∈ type_of(a), y ∈ type_of(b) }
//
// Si les opérandes sont des valeurs (leurs types sont des ensembles d'atomes),
// on calcule sur les valeurs. Si ce sont des ensembles (leurs types sont des
// singletons d'ensembles : `u8`, `>0`), on calcule sur ces ensembles, et le
// résultat est encore un ensemble unique. Un mélange qui produirait plusieurs
// ensembles possibles donne Many.

type_op :: proc(k: ^Kernel, o: Op, env: ^Scope) -> ^Expr {
	if o.left == nil do return type_unary(k, o, env)
	a := type_of(k, o.left, env)
	b := type_of(k, o.right, env)
	if is_invalid(a) do return a
	if is_invalid(b) do return b
	#partial switch o.kind {
	case .Or, .And:
		return set_algebra(k, o, a, b)
	case .Add, .Subtract, .Multiply:
		return arithmetic(k, o, a, b)
	case .Equal, .NotEqual, .Less, .Greater, .LessEqual, .GreaterEqual:
		return comparison(k, o, a, b)
	}
	return report(k, .Unsupported, o.span, fmt.tprintf("pas encore dans le kernel : l'opérateur %v", o.kind))
}

// `|` et `&` opèrent sur des ensembles : sur l'élément de chaque opérande.
set_algebra :: proc(k: ^Kernel, o: Op, a, b: ^Expr) -> ^Expr {
	xa, oka := the_element(a)
	xb, okb := the_element(b)
	if !oka || !okb do return new_expr(Many{}) // plusieurs ensembles possibles
	sa, sa_ok := xa^.(Set)
	sb, sb_ok := xb^.(Set)
	if !sa_ok || !sb_ok do return report(k, .Unsupported, o.span, "pas encore dans le kernel : | et & sur des scopes")
	r := o.kind == .Or ? set_union(sa, sb) : set_intersect(sa, sb)
	return singleton(new_expr(r))
}

arith_of :: proc(kind: syn.Operator_Kind) -> Arith {
	#partial switch kind {
	case .Subtract:
		return .Sub
	case .Multiply:
		return .Mul
	}
	return .Add
}

arithmetic :: proc(k: ^Kernel, o: Op, a, b: ^Expr) -> ^Expr {
	// Sur des valeurs : les deux types sont des ensembles d'atomes.
	if sa, ok := a^.(Set); ok {
		if sb, ok2 := b^.(Set); ok2 {
			r, status := arith_sets(arith_of(o.kind), sa, sb)
			if status != .Ok do return arith_failure(k, o, status, sa, sb)
			return new_expr(r)
		}
	}
	// Sur des ensembles : les deux types sont des singletons d'ensembles.
	xa, oka := the_element(a)
	xb, okb := the_element(b)
	if !oka || !okb do return new_expr(Many{})
	sa, sa_ok := xa^.(Set)
	sb, sb_ok := xb^.(Set)
	if !sa_ok || !sb_ok do return report(k, .Invalid_operator, o.span, fmt.tprintf("'%v' attend des nombres", o.kind))
	r, status := arith_sets(arith_of(o.kind), sa, sb)
	if status != .Ok do return arith_failure(k, o, status, sa, sb)
	return singleton(new_expr(r))
}

Arith_Status :: enum u8 {
	Ok,
	Invalid, // l'opérateur ne s'applique pas à ces sortes
	Unsupported, // pas encore dans le kernel (grammaires de chaînes, mélange entier/flottant)
}

arith_failure :: proc(k: ^Kernel, o: Op, status: Arith_Status, a, b: Set) -> ^Expr {
	if status == .Unsupported {
		return report(k, .Unsupported, o.span, fmt.tprintf("pas encore dans le kernel : '%v' sur %s et %s", o.kind, print_set(a), print_set(b)))
	}
	return invalid_operator(k, o, a, b)
}

invalid_operator :: proc(k: ^Kernel, o: Op, a, b: Set) -> ^Expr {
	return report(
		k,
		.Invalid_operator,
		o.span,
		fmt.tprintf("'%v' ne s'applique pas à %s et %s", o.kind, print_set(a), print_set(b)),
	)
}

// arith_sets : { x op y } sur deux ensembles, sorte par sorte : chaque sorte de
// `a` se combine avec la sorte de `b` pour laquelle l'opération existe. Sur les
// nombres, l'arithmétique ; sur les chaînes, `+` concatène et `*` répète par un
// ensemble de comptes (`'a'..'z' * 2..4`, `..10 * "ab"`), dans les deux sens.
// Aucune paire compatible : l'opérateur ne s'applique pas.
arith_sets :: proc(op: Arith, a, b: Set) -> (Set, Arith_Status) {
	has :: proc(s: Set, d: Domain) -> bool {
		return domain_count(s, d) > 0
	}
	r := Set{}
	found := false
	if has(a, .Ints) && has(b, .Ints) {
		r.ints = ints_arith(op, a.ints, b.ints)
		found = true
	}
	if has(a, .Floats) && has(b, .Floats) {
		r.floats = floats_arith(op, a.floats, b.floats)
		found = true
	}
	// Concaténer ou répéter des caractères donne des chaînes.
	textual :: proc(s: Set) -> bool {
		return domain_count(s, .Strings) > 0 || domain_count(s, .Chars) > 0
	}
	if textual(a) && textual(b) && op == .Add {
		r.strings = strings_union(r.strings, strings_concat(as_strings(a), as_strings(b)))
		found = true
	}
	if op == .Mul {
		for pair in ([2][2]Set{{a, b}, {b, a}}) {
			if !textual(pair[0]) || !has(pair[1], .Ints) do continue
			rep, ok := strings_repeat(as_strings(pair[0]), pair[1].ints)
			if !ok do return {}, .Unsupported // trop grand pour un automate exact
			r.strings = strings_union(r.strings, rep)
			found = true
		}
	}
	if found do return r, .Ok
	if (has(a, .Ints) && has(b, .Floats)) || (has(a, .Floats) && has(b, .Ints)) do return {}, .Unsupported
	return {}, .Invalid
}

// pure_domain : la sorte unique d'un ensemble non vide qui n'en porte qu'une.
pure_domain :: proc(s: Set) -> (Domain, bool) {
	found := false
	d: Domain
	for x in Domain {
		if domain_count(s, x) == 0 do continue
		if found do return d, false
		d, found = x, true
	}
	return d, found
}

// Une comparaison donne un booléen : exact quand les ensembles le décident,
// `bool` sinon.
comparison :: proc(k: ^Kernel, o: Op, a, b: ^Expr) -> ^Expr {
	sa, a_ok := a^.(Set)
	sb, b_ok := b^.(Set)
	if !a_ok || !b_ok {
		// Deux ensembles comparés comme valeurs : seule l'égalité a un sens.
		xa, oka := the_element(a)
		xb, okb := the_element(b)
		if !oka || !okb || (o.kind != .Equal && o.kind != .NotEqual) {
			return report(k, .Unsupported, o.span, "pas encore dans le kernel : cette comparaison")
		}
		ea, ea_ok := xa^.(Set)
		eb, eb_ok := xb^.(Set)
		if !ea_ok || !eb_ok do return report(k, .Unsupported, o.span, "pas encore dans le kernel : l'égalité de scopes")
		return new_expr(set_of_bools(bools_point(set_equal(ea, eb) == (o.kind == .Equal))))
	}
	#partial switch o.kind {
	case .Equal, .NotEqual:
		verdict := equal_verdict(sa, sb)
		if o.kind == .NotEqual && card(verdict) == 1 do verdict = ~verdict
		return new_expr(set_of_bools(verdict))
	}
	verdict, ok := order_verdict(o.kind, sa, sb)
	if !ok do return invalid_operator(k, o, sa, sb)
	return new_expr(set_of_bools(verdict))
}

equal_verdict :: proc(a, b: Set) -> Bools {
	if set_count(a) == 1 && set_count(b) == 1 do return set_equal(a, b) ? {.True} : {.False}
	if set_is_empty(set_intersect(a, b)) do return {.False}
	return {.False, .True}
}

// order_verdict décide `a < b` (etc.) sur les enveloppes de deux ensembles de nombres.
order_verdict :: proc(kind: syn.Operator_Kind, a, b: Set) -> (Bools, bool) {
	da, a_pure := pure_domain(a)
	db, b_pure := pure_domain(b)
	if !a_pure || !b_pure || da != db do return {}, false
	alo, ahi, blo, bhi: Maybe(f64)
	switch da {
	case .Ints:
		alo, ahi = to_f64(ints_bounds(a.ints))
		blo, bhi = to_f64(ints_bounds(b.ints))
	case .Chars:
		alo, ahi = to_f64(ints_bounds(a.chars))
		blo, bhi = to_f64(ints_bounds(b.chars))
	case .Floats:
		alo, ahi = floats_bounds(a.floats)
		blo, bhi = floats_bounds(b.floats)
	case .Strings, .Bools:
		return {}, false
	}
	// lt : a < b est sûr ; ge : a >= b est sûr (et symétriquement).
	lt := below(ahi, blo, strict = true)
	le := below(ahi, blo, strict = false)
	gt := below(bhi, alo, strict = true)
	ge := below(bhi, alo, strict = false)
	#partial switch kind {
	case .Less:
		if lt do return {.True}, true
		if ge do return {.False}, true
	case .LessEqual:
		if le do return {.True}, true
		if gt do return {.False}, true
	case .Greater:
		if gt do return {.True}, true
		if le do return {.False}, true
	case .GreaterEqual:
		if ge do return {.True}, true
		if lt do return {.False}, true
	}
	return {.False, .True}, true
}

// below : hi < lo (ou hi <= lo), pour une borne haute et une borne basse.
below :: proc(hi, lo: Maybe(f64), strict: bool) -> bool {
	h, h_ok := hi.?
	l, l_ok := lo.?
	if !h_ok || !l_ok do return false
	return strict ? h < l : h <= l
}

to_f64 :: proc(lo, hi: Maybe(i128)) -> (Maybe(f64), Maybe(f64)) {
	l: Maybe(f64) = nil
	h: Maybe(f64) = nil
	if v, ok := lo.?; ok do l = f64(v)
	if v, ok := hi.?; ok do h = f64(v)
	return l, h
}

// Les opérateurs unaires : `-x` sur une valeur ; `~X`, `>x`, `<x`, `>=x`, `<=x`,
// `!=x` construisent un ensemble.
type_unary :: proc(k: ^Kernel, o: Op, env: ^Scope) -> ^Expr {
	t := type_of(k, o.right, env)
	if is_invalid(t) do return t
	#partial switch o.kind {
	case .Subtract:
		if s, ok := t^.(Set); ok {
			r, done := negate_values(s)
			if !done do return report(k, .Invalid_operator, o.span, "'-' attend des nombres")
			return new_expr(r)
		}
		return report(k, .Unsupported, o.span, "pas encore dans le kernel : '-' sur un ensemble")
	case .Not:
		x, ok := the_element(t)
		if !ok do return new_expr(Many{})
		s, is_set := x^.(Set)
		if !is_set do return report(k, .Unsupported, o.span, "pas encore dans le kernel : ~ sur un scope")
		return singleton(new_expr(set_complement(s)))
	case .Greater, .Less, .GreaterEqual, .LessEqual, .NotEqual:
		s, status := bound_of(k, o.right, env)
		#partial switch status {
		case .Invalid:
			return new_expr(Invalid{})
		case .Unknown:
			return report(k, .Unsupported, o.span, "pas encore dans le kernel : une comparaison préfixe à borne inconnue")
		}
		d, _ := pure_domain(s)
		if status != .Ok || set_count(s) != 1 || d == .Strings {
			return report(k, .Invalid_Range, o.span, "une comparaison préfixe attend un nombre connu")
		}
		return singleton(new_expr(half_line(o.kind, s)))
	}
	return report(k, .Unsupported, o.span, fmt.tprintf("pas encore dans le kernel : l'opérateur préfixe %v", o.kind))
}

negate_values :: proc(s: Set) -> (Set, bool) {
	d, pure := pure_domain(s)
	if !pure do return {}, false
	#partial switch d {
	case .Ints:
		return set_of_ints(ints_neg(s.ints)), true
	case .Floats:
		return set_of_floats(floats_neg(s.floats)), true
	}
	return {}, false
}

// half_line : `>x` est l'ensemble des nombres de la sorte de x plus grands que x.
half_line :: proc(kind: syn.Operator_Kind, x: Set) -> Set {
	if ints_count(x.ints) == 1 {
		v, _ := ints_default(x.ints)
		#partial switch kind {
		case .Greater:
			return set_of_ints(ints_range(v + 1, nil))
		case .GreaterEqual:
			return set_of_ints(ints_range(v, nil))
		case .Less:
			return set_of_ints(ints_range(nil, v - 1))
		case .LessEqual:
			return set_of_ints(ints_range(nil, v))
		}
		return set_of_ints(ints_complement(ints_point(v))) // !=
	}
	v, _ := floats_default(x.floats)
	#partial switch kind {
	case .Greater:
		return set_of_floats(floats_of({Float_Interval{lo = v, lo_open = true}}))
	case .GreaterEqual:
		return set_of_floats(floats_of({Float_Interval{lo = v}}))
	case .Less:
		return set_of_floats(floats_of({Float_Interval{hi = v, hi_open = true}}))
	case .LessEqual:
		return set_of_floats(floats_of({Float_Interval{hi = v}}))
	}
	return set_of_floats(floats_complement(floats_point(v)))
}
