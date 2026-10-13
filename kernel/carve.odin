package kernel

import "core:fmt"

// LE CARVE
//
// `target{x -> v}` dérive un nouveau scope (specs/language/08). Comme chaque binding
// garde sa couleur et sa valeur symboliques, le carve est une copie : on copie
// l'arbre symbolique du scope, on met les arguments à la place des valeurs qu'ils
// visent, et on type la copie. Tout ce qui dépend d'une valeur carvée — une
// valeur, une couleur, un carve plus profond — est re-typé avec elle ; la
// vérification finale porte sur la copie comme sur tout scope.

type_carve :: proc(k: ^Kernel, c: Carve, env: ^Scope) -> ^Expr {
	t := type_of(k, c.target, env)
	if is_invalid(t) do return t
	s, is_scope := t^.(^Scope)
	if !is_scope do return report(k, .Invalid_Carve, c.span, fmt.tprintf("on ne carve qu'un scope : %s", brief(t)))
	derived := copy_scope(s, s.parent)
	carved := make([]bool, len(derived.bindings))
	position := 0
	for a, i in c.args.bindings {
		if a.kind != .Push do continue // une autre flèche : signalée à la construction
		if a.color != nil {
			report(k, .Unsupported, a.span, "pas encore dans le kernel : un argument de carve coloré")
			continue
		}
		j := carve_target(derived, a, c.ordinals[i], &position)
		if j < 0 {
			report(k, .Invalid_Carve, a.span, carve_miss(a, c.ordinals[i], position))
			continue
		}
		if carved[j] {
			report(k, .Invalid_Carve, a.span, fmt.tprintf("%s est carvé deux fois", display(&derived.bindings[j])))
			continue
		}
		carved[j] = true
		derived.bindings[j].value = new_expr(Carved{c.args, i})
	}
	type_scope(k, derived, s.shape)
	return new_expr(derived)
}

// carve_target : le binding que vise un argument. Nommé, la première occurrence
// de son nom, ou celle de `x#n` ; sans nom, le binding de même rang parmi ceux qui
// ne sont pas des productions. -1 : il n'existe pas — un scope est clos.
carve_target :: proc(s: ^Scope, a: Binding, ordinal: int, position: ^int) -> int {
	if a.name != "" do return find_binding(s, a.name, max(ordinal, 0))
	rank := position^
	position^ += 1
	for b, i in s.bindings {
		if b.kind == .Product do continue
		if rank == 0 do return i
		rank -= 1
	}
	return -1
}

carve_miss :: proc(a: Binding, ordinal: int, position: int) -> string {
	if a.name == "" do return fmt.tprintf("le scope n'a pas de %de binding à carver", position)
	if ordinal >= 0 do return fmt.tprintf("'%s#%d' n'est pas un binding du scope carvé", a.name, ordinal)
	return fmt.tprintf("'%s' n'est pas un binding du scope carvé", a.name)
}

// type_argument : le type d'un argument de carve, typé une fois, là où il a été
// écrit, avec la couleur du binding qu'il remplace. Une copie de la copie garde
// la même valeur : l'argument a été fixé par le carve qui l'a écrit.
type_argument :: proc(k: ^Kernel, c: Carved, color: ^Expr) -> ^Expr {
	a := &c.args.bindings[c.index]
	if a.value_type == nil do type_binding(k, a, c.args, color)
	return a.value_type
}

// copy_scope : la copie symbolique d'un scope, sous `parent`. Les scopes écrits
// dedans sont copiés avec lui ; ceux qu'il désigne seulement (un argument de
// carve écrit ailleurs, la forme qui le colore) sont partagés. Les types ne sont
// pas copiés : la copie se type à nouveau.
copy_scope :: proc(s: ^Scope, parent: ^Scope) -> ^Scope {
	c := new_scope(parent, s.span)
	c.shape = s.shape
	for b in s.bindings {
		append(&c.bindings, Binding{name = b.name, capture = b.capture, kind = b.kind, color = copy_expr(b.color, s, c), value = copy_expr(b.value, s, c), span = b.span})
	}
	return c
}

// copy_expr : `e`, écrit dans le scope `from`, réécrit dans sa copie `to`.
copy_expr :: proc(e: ^Expr, from, to: ^Scope) -> ^Expr {
	if e == nil do return nil
	#partial switch v in e^ {
	case ^Scope:
		if v.parent != from do return e
		return new_expr(copy_scope(v, to))
	case Access:
		return new_expr(Access{copy_expr(v.target, from, to), v.name, v.ordinal, v.span})
	case Collapse:
		return new_expr(Collapse{copy_expr(v.target, from, to), v.span})
	case Carve:
		args := v.args.parent == from ? copy_scope(v.args, to) : v.args
		return new_expr(Carve{copy_expr(v.target, from, to), args, v.ordinals, v.span})
	case Op:
		return new_expr(Op{v.kind, copy_expr(v.left, from, to), copy_expr(v.right, from, to), v.span})
	case Range:
		return new_expr(Range{copy_expr(v.lo, from, to), copy_expr(v.hi, from, to), v.span})
	case Unknown:
		return new_expr(Unknown{copy_expr(v.layout, from, to), v.span})
	}
	return e // Set, Ref, Carved, Invalid : rien à réécrire
}
