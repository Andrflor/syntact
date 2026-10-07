package kernel

import "core:fmt"

// La vérification finale : une fois tout typé, chaque binding coloré doit avoir un
// type inclus dans sa couleur, `type_of ⊆ color_of`.
check :: proc(k: ^Kernel) {
	for t in k.typed {
		for &b in t.bindings {
			if b.color == nil || b.value == nil || is_invalid(b.value) do continue
			if contains(k, b.color, b.value) do continue
			report(
				k,
				.Constraint_Mismatch,
				b.span,
				fmt.tprintf("%s ⊄ %s sur %s", brief(b.value), brief(b.color), display(&b)),
			)
		}
	}
}

// contains : toutes les valeurs possibles de `type` sont admises par la couleur
// `color`. Une couleur est un ensemble : un ensemble d'atomes, ou un scope lu
// comme ensemble. Les valeurs d'une forme sur des inconnues peuvent être
// sur-approchées : la vérification reste sûre, elle peut seulement refuser plus.
contains :: proc(k: ^Kernel, color, type: ^Expr) -> bool {
	if is_invalid(color) || is_invalid(type) do return true // déjà signalé ailleurs
	#partial switch c in color^ {
	case Set:
		if !is_value(type) do return false
		vals, _ := values_of(k, type)
		return atoms_admitted(vals, c)
	case ^Scope:
		return scope_admits(k, c, type)
	}
	return false
}

// atoms_admitted : les valeurs possibles `t` sont admises par la couleur `c`.
// `none` n'est l'élément d'aucun ensemble d'atomes : seule la couleur none
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
scope_admits :: proc(k: ^Kernel, c: ^Scope, type: ^Expr) -> bool {
	if first_production(c) >= 0 {
		for b in c.bindings {
			if b.kind == .Product && binding_admits(k, b, type) do return true
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
		if !binding_admits(k, cb, vb.value) do return false
	}
	return true
}

// binding_admits : ce qu'un binding d'une couleur admet — ce qu'admet sa couleur
// s'il en a une, sinon les valeurs de son propre type.
binding_admits :: proc(k: ^Kernel, b: Binding, type: ^Expr) -> bool {
	if b.color != nil do return contains(k, b.color, type)
	return type_subset(k, type, b.value)
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
