package kernel

import "core:fmt"

// La vérification finale : une fois tout typé, chaque binding coloré doit avoir un
// type inclus dans sa couleur, `type_of ⊆ color_of`.
check :: proc(k: ^Kernel) {
	for t in k.typed {
		for &b in t.bindings {
			if b.color == nil || b.value == nil || is_invalid(b.value) do continue
			if contains(b.color, b.value) do continue
			report(
				k,
				.Constraint_Mismatch,
				b.span,
				fmt.tprintf("%s ⊄ %s sur %s", print_expr(b.value), print_expr(b.color), display(&b)),
			)
		}
	}
}

// contains : toutes les valeurs possibles de `type` sont admises par la couleur
// `color`. Une couleur est un ensemble : un ensemble d'atomes, ou un scope lu
// comme ensemble.
contains :: proc(color, type: ^Expr) -> bool {
	if is_invalid(color) || is_invalid(type) do return true // déjà signalé ailleurs
	#partial switch c in color^ {
	case Set:
		if t, ok := type^.(Set); ok do return atoms_admitted(t, c)
		return false
	case ^Scope:
		return scope_admits(c, type)
	}
	return false
}

// atoms_admitted : les valeurs possibles `t` sont des éléments de `c`. `none` n'est
// l'élément d'aucun ensemble d'atomes : seule la couleur none l'admet.
atoms_admitted :: proc(t, c: Set) -> bool {
	if set_is_empty(t) do return set_is_empty(c)
	return set_subset(t, c)
}

// scope_admits : un scope avec productions admet ce qu'admet l'une de ses
// productions ; sans production, il admet les scopes de même structure dont
// chaque binding est admis par le sien.
scope_admits :: proc(c: ^Scope, type: ^Expr) -> bool {
	if first_production(c) >= 0 {
		for b in c.bindings {
			if b.kind == .Product && binding_admits(b, type) do return true
		}
		return false
	}
	v, ok := scope_element(type)
	if !ok || len(v.bindings) != len(c.bindings) do return false
	for cb, i in c.bindings {
		vb := v.bindings[i]
		if cb.name != vb.name || cb.kind != vb.kind do return false
		// un binding nommé sans couleur n'impose rien : un carve peut lui donner toute valeur
		if cb.color == nil && cb.name != "" do continue
		if !binding_admits(cb, vb.value) do return false
	}
	return true
}

// binding_admits : ce qu'un binding d'une couleur admet — ce qu'admet sa couleur
// s'il en a une, sinon les valeurs de son propre type.
binding_admits :: proc(b: Binding, type: ^Expr) -> bool {
	if b.color != nil do return contains(b.color, type)
	return type_subset(type, b.value)
}

// type_subset : a ⊆ b, deux types (deux ensembles de valeurs possibles).
type_subset :: proc(a, b: ^Expr) -> bool {
	if is_invalid(a) || is_invalid(b) do return true
	if sa, ok := a^.(Set); ok {
		if sb, ok2 := b^.(Set); ok2 do return atoms_admitted(sa, sb)
	}
	xa, a_one := the_element(a)
	xb, b_one := the_element(b)
	return a_one && b_one && value_equal(xa, xb)
}

// value_equal : deux valeurs (éléments de types) identiques.
value_equal :: proc(x, y: ^Expr) -> bool {
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
			if ab.color != nil && !value_equal(ab.color, bb.color) do return false
			if !type_subset(ab.value, bb.value) || !type_subset(bb.value, ab.value) do return false
		}
		return true
	}
	return false
}
