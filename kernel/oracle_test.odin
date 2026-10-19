package kernel

import "core:slice"

// L'ORACLE DES TESTS : énumérer les valeurs des inconnues, pour vérifier ce que le
// kernel décide sans énumérer.

// Au-delà, l'oracle n'énumère plus.
ENUMERATION_LIMIT :: 1 << 16

// enumerate : les valeurs possibles d'une forme, exactes, si ses inconnues
// s'énumèrent.
enumerate :: proc(k: ^Kernel, t: ^Expr, ctx: Context = nil) -> (vals: Set, ok: bool) {
	a := assignments(k, t, ctx) or_return
	results := make([dynamic]Atom)
	for {
		v := eval(t, a.env) or_return
		append(&results, v)
		if !next_assignment(&a) do break
	}
	return set_of_atoms(results[:]), true
}

// Assignments : toutes les valeurs des inconnues d'un type, une à une, la première
// inconnue variant le plus vite. `env[id]` est la valeur courante de l'inconnue id.
Assignments :: struct {
	ids:     []^Var,
	domains: [][]Atom,
	digits:  []int,
	env:     []Atom,
}

// assignments : la première affectation des inconnues de `t` ; faux s'il y en a
// trop pour les énumérer.
assignments :: proc(k: ^Kernel, t: ^Expr, ctx: Context = nil) -> (Assignments, bool) {
	found := make([dynamic]^Var)
	collect_symbols(t, &found)
	slice.sort_by(found[:], var_less)
	return assignments_of(k, slice.unique(found[:]), ctx)
}

// assignments_of : de même, pour des inconnues données, sans doublon.
assignments_of :: proc(k: ^Kernel, ids: []^Var, ctx: Context = nil) -> (a: Assignments, ok: bool) {
	a.ids = ids
	a.domains = make([][]Atom, len(ids))
	total := 1
	for id, i in ids {
		d := known_domain(k, ctx, id) or_return
		a.domains[i] = atoms_of_set(d, ENUMERATION_LIMIT) or_return
		total *= len(a.domains[i])
		if total > ENUMERATION_LIMIT do return a, false
	}
	a.digits = make([]int, len(ids))
	a.env = make([]Atom, k.variables)
	load_assignment(&a)
	return a, true
}

// next_assignment : passe à l'affectation suivante ; faux après la dernière.
next_assignment :: proc(a: ^Assignments) -> bool {
	for i in 0 ..< len(a.digits) {
		a.digits[i] += 1
		if a.digits[i] < len(a.domains[i]) {
			load_assignment(a)
			return true
		}
		a.digits[i] = 0
	}
	return false
}

load_assignment :: proc(a: ^Assignments) {
	for id, i in a.ids do a.env[id.id] = a.domains[i][a.digits[i]]
}

