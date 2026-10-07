package kernel

import syn "../compiler"
import "core:fmt"

// type_of d'un opérateur. Une seule loi pour tous :
//
//   type_of(a op b) = { x op y | x ∈ type_of(a), y ∈ type_of(b) }
//
// Si les deux opérandes sont des valeurs (un atome, ou une forme sur des
// inconnues), on calcule sur les valeurs et le résultat est sous forme
// normale. Si ce sont des ensembles (`u8`, `>0`, `'a'..'z'`), on calcule sur
// les ensembles, et le résultat est encore un ensemble.

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

// known_set : l'ensemble qu'un type désigne quand il est connu (un atome est
// l'ensemble de lui-même).
known_set :: proc(t: ^Expr) -> (Set, bool) {
	x, ok := the_element(t)
	if !ok do return {}, false
	s, is_set := x^.(Set)
	return s, is_set
}

// `|` et `&` opèrent sur des ensembles : sur l'élément de chaque opérande.
set_algebra :: proc(k: ^Kernel, o: Op, a, b: ^Expr) -> ^Expr {
	return set_operation(k, Set_Op{kind = o.kind == .Or ? .Union : .Inter}, o.span, a, b)
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
	op := arith_of(o.kind)
	if is_value(a) && is_value(b) {
		r, status := value_arith(k, op, a, b)
		if status != .Ok do return arith_failure(k, o, status, a, b)
		return r
	}
	// Sur des ensembles, connus ou qui dépendent d'inconnues.
	return set_operation(k, Set_Op{kind = .Arith, arith = op}, o.span, a, b)
}

// value_arith : sur deux valeurs, connues ou non, en forme normale.
value_arith :: proc(k: ^Kernel, op: Arith, a, b: ^Expr) -> (^Expr, Arith_Status) {
	sa, a_atom := a^.(Set)
	sb, b_atom := b^.(Set)
	if a_atom && b_atom {
		r, status := arith_sets(op, sa, sb)
		return new_expr(r), status
	}
	da, a_ok := value_domain(k, a)
	db, b_ok := value_domain(k, b)
	if !a_ok || !b_ok do return nil, .Unsupported // une inconnue de plusieurs sortes
	switch {
	case da == .Ints && db == .Ints:
		pa, _ := as_poly(a)
		pb, _ := as_poly(b)
		r: Poly
		ok: bool
		switch op {
		case .Add:
			r, ok = poly_add(pa, pb)
		case .Sub:
			r, ok = poly_sub(pa, pb)
		case .Mul:
			r, ok = poly_mul(pa, pb)
		}
		if !ok do return nil, .Unsupported // un coefficient au-delà de i128
		return poly_type(r), .Ok
	case da == .Floats && db == .Floats:
		switch op {
		case .Add:
			return float_add(a, b), .Ok
		case .Sub:
			return float_add(a, float_neg(b)), .Ok // a - b = a + (-b), exactement
		case .Mul:
			return float_mul(a, b), .Ok
		}
	case is_textual(da) && is_textual(db) && op == .Add:
		return concat(k, a, b), .Ok
	case op == .Mul && is_textual(da) && db == .Ints:
		return repeat_term(k, a, b)
	case op == .Mul && da == .Ints && is_textual(db):
		return repeat_term(k, b, a)
	case (da == .Ints && db == .Floats) || (da == .Floats && db == .Ints):
		return nil, .Unsupported
	}
	return nil, .Invalid
}

Arith_Status :: enum u8 {
	Ok,
	Invalid, // l'opérateur ne s'applique pas à ces sortes
	Unsupported, // pas encore dans le kernel (mélange entier/flottant, trop grand pour être exact)
}

arith_failure :: proc(k: ^Kernel, o: Op, status: Arith_Status, a, b: ^Expr) -> ^Expr {
	if status == .Unsupported {
		return report(k, .Unsupported, o.span, fmt.tprintf("pas encore dans le kernel : '%v' sur %s et %s", o.kind, print_expr(a), print_expr(b)))
	}
	return report(k, .Invalid_operator, o.span, fmt.tprintf("'%v' ne s'applique pas à %s et %s", o.kind, print_expr(a), print_expr(b)))
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
	textual :: proc(s: Set) -> bool {
		return domain_count(s, .Strings) > 0 || domain_count(s, .Chars) > 0
	}
	r := Set{}
	found := false
	if has(a, .Ints) && has(b, .Ints) {
		exact: bool
		r.ints, exact = ints_arith(op, a.ints, b.ints)
		if !exact do return {}, .Unsupported // une borne au-delà de i128
		found = true
	}
	if has(a, .Floats) && has(b, .Floats) {
		r.floats = floats_arith(op, a.floats, b.floats)
		found = true
	}
	// Concaténer ou répéter des caractères donne des chaînes.
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

compare_op_of :: proc(kind: syn.Operator_Kind) -> Compare_Op {
	#partial switch kind {
	case .Less:
		return .Lt
	case .LessEqual:
		return .Le
	case .Greater:
		return .Gt
	case .GreaterEqual:
		return .Ge
	case .NotEqual:
		return .Ne
	}
	return .Eq
}

// Une comparaison donne un booléen : exact quand les valeurs le décident, une
// forme normale sinon. Deux sortes différentes ne sont jamais égales.
comparison :: proc(k: ^Kernel, o: Op, a, b: ^Expr) -> ^Expr {
	op := compare_op_of(o.kind)
	if is_value(a) && is_value(b) {
		da, a_ok := value_domain(k, a)
		db, b_ok := value_domain(k, b)
		if a_ok && b_ok && da != db {
			if op == .Eq || op == .Ne do return bool_atom(op == .Ne)
			return report(k, .Invalid_operator, o.span, fmt.tprintf("'%v' compare deux sortes différentes : %s et %s", o.kind, print_expr(a), print_expr(b)))
		}
		r: ^Expr
		status: Arith_Status
		pa, a_poly := as_poly(a)
		pb, b_poly := as_poly(b)
		if a_poly && b_poly {
			p, ok := poly_sub(pa, pb)
			if !ok do return report(k, .Unsupported, o.span, "pas encore dans le kernel : un coefficient au-delà de i128")
			r, status = int_compare(k, op, p)
		} else {
			r, status = general_compare(k, op, a, b)
		}
		if status != .Ok do return arith_failure(k, o, status, a, b)
		return r
	}
	// Deux ensembles comparés comme valeurs : seule l'égalité a un sens.
	sa, a_known := known_set(a)
	sb, b_known := known_set(b)
	if !a_known || !b_known || (op != .Eq && op != .Ne) {
		return report(k, .Unsupported, o.span, "pas encore dans le kernel : cette comparaison")
	}
	return bool_atom(set_equal(sa, sb) == (op == .Eq))
}

equal_verdict :: proc(a, b: Set) -> Bools {
	if is_atom(a) && is_atom(b) do return set_equal(a, b) ? {.True} : {.False}
	if set_is_empty(set_intersect(a, b)) do return {.False}
	return {.False, .True}
}

// order_verdict décide `a < b` (etc.) sur les enveloppes de deux ensembles de
// nombres ou de caractères.
order_verdict :: proc(op: Compare_Op, a, b: Set) -> (Bools, bool) {
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
	#partial switch op {
	case .Lt:
		if lt do return {.True}, true
		if ge do return {.False}, true
	case .Le:
		if le do return {.True}, true
		if gt do return {.False}, true
	case .Gt:
		if gt do return {.True}, true
		if le do return {.False}, true
	case .Ge:
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
		return negate(k, o, t)
	case .Not:
		return set_operation(k, Set_Op{kind = .Comp}, o.span, t)
	case .Greater, .Less, .GreaterEqual, .LessEqual, .NotEqual:
		return set_operation(k, Set_Op{kind = .Half, half = o.kind}, o.span, t)
	}
	return report(k, .Unsupported, o.span, fmt.tprintf("pas encore dans le kernel : l'opérateur préfixe %v", o.kind))
}

// negate : `-x`, sur une valeur (connue ou non) ou sur un ensemble connu.
negate :: proc(k: ^Kernel, o: Op, t: ^Expr) -> ^Expr {
	if is_value(t) {
		d, ok := value_domain(k, t)
		if ok && d == .Ints {
			p, _ := as_poly(t)
			r, r_ok := poly_scale(p, -1)
			if r_ok do return poly_type(r)
		}
		if ok && d == .Floats do return float_neg(t)
		if !ok do return report(k, .Unsupported, o.span, fmt.tprintf("pas encore dans le kernel : '-' sur une inconnue de plusieurs sortes : %s", print_expr(t)))
		return report(k, .Invalid_operator, o.span, fmt.tprintf("'-' attend un nombre : %s", print_expr(t)))
	}
	s, known := known_set(t)
	if !known do return report(k, .Unsupported, o.span, "pas encore dans le kernel : '-' sur un ensemble qui dépend d'une inconnue")
	d, pure := pure_domain(s)
	switch {
	case pure && d == .Ints:
		return singleton(new_expr(set_of_ints(ints_neg(s.ints))))
	case pure && d == .Floats:
		return singleton(new_expr(set_of_floats(floats_neg(s.floats))))
	}
	return report(k, .Invalid_operator, o.span, fmt.tprintf("'-' attend des nombres : %s", print_set(s)))
}
