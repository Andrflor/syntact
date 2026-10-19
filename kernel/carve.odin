package kernel

import syn "../compiler"
import "core:fmt"

// LE CARVE
//
// `target{x -> v}` dérive un nouveau scope (specs/language/08). Comme chaque binding
// garde sa couleur et sa valeur symboliques, le carve est une copie : on copie
// l'arbre symbolique du scope, on met les arguments à la place des valeurs qu'ils
// visent, et on type la copie. Tout ce qui dépend d'une valeur carvée — une
// valeur, une couleur, un carve plus profond — est re-typé avec elle ; la
// vérification finale porte sur la copie comme sur tout scope.
//
// Les erreurs de la copie sont signalées au carve, et seulement celles que le carve
// a causées : un binding qu'il ne change pas a déjà été vérifié dans sa source.

type_carve :: proc(k: ^Kernel, c: Carve, env: ^Scope) -> ^Expr {
	t := type_of(k, c.target, env)
	if is_invalid(t) do return t
	if x, itself := t^.(Itself); itself do return carve_itself(k, x.scope, x.scope, c)
	s, is_scope := t^.(^Scope)
	if !is_scope do return report(k, .Invalid_Carve, c.span, fmt.tprintf("on ne carve qu'un scope : %s", brief(t)))
	c.args.carving = s // ce que `.x` désigne dans les arguments
	if d, found := redefined(k, s); found do return carve_itself(k, s, d, c)
	// dans une copie, ce carve est dérivé avec elle : ses erreurs vont au carve d'origine
	derived := copy_scope(s, s.parent, k.scene.site != {} ? k.scene.site : c.span)
	targets := fill(k, s, derived, c)
	infer_holes(k, s, c, derived, targets)
	// une copie faite en silence est celle d'un binding que rien n'a changé : elle
	// redonne ce que sa source a déjà donné
	if !k.scene.quiet do mark_changes(derived, c.args, {})
	type_scope(k, derived, s.shape)
	return new_expr(derived)
}

// redefined : le scope en cours de définition que le carve de s redonne — même
// source écrite (une copie garde le span de ce qu'elle copie). Quels que soient
// ses arguments, c'est une self-référence : X, ou X appliqué à d'autres arguments.
redefined :: proc(k: ^Kernel, s: ^Scope) -> (^Scope, bool) {
	#reverse for d in k.defining do if d.span == s.span do return d, true
	return nil, false
}

// carve_itself : le carve de s est une self-référence, qui redonne d. Rien n'est
// copié ni typé de s ; ses arguments sont vérifiés contre les bindings qu'ils
// remplissent, comme pour tout carve.
carve_itself :: proc(k: ^Kernel, s, d: ^Scope, c: Carve) -> ^Expr {
	c.args.carving = s
	targets := fill(k, s, copy_scope(s, s.parent, c.span), c)
	for j, i in targets do if j >= 0 do type_argument(k, Carved{c.args, i}, s.bindings[j].color_type)
	append(&k.typed, c.args) // vérifiés à la fin, avec tout le reste
	return new_expr(Itself{d, new_expr(c)})
}

// fill : met chaque argument à la place du binding qu'il vise. `->` remplit un
// champ, `<-` un trou ; un argument sans nom vise un champ, jamais un trou. La
// cible se lit dans la source s, typée, à travers ses expansions ; la copie a les
// mêmes bindings écrits. Rend, pour chaque argument, le binding écrit de la copie
// qu'il remplit (-1 : aucun, ou un binding qu'une expansion apporte).
fill :: proc(k: ^Kernel, s, derived: ^Scope, c: Carve) -> []int {
	targets := make([]int, len(c.args.bindings))
	chosen := make([dynamic]Place, context.temp_allocator)
	into := make(map[int]Into, context.temp_allocator)
	position := 0
	for a, i in c.args.bindings {
		targets[i] = -1
		if a.kind != .Push && a.kind != .Pull do continue // une autre flèche : signalée à la construction
		if a.color != nil {
			report(k, .Unsupported, a.span, "pas encore dans le kernel : un argument de carve coloré")
			continue
		}
		p, found := carve_target(s, a, c.ordinals[i], &position)
		if !found {
			report(k, .Invalid_Carve, a.span, carve_miss(a, c.ordinals[i], position))
			continue
		}
		b := binding_at(p)
		if (a.kind == .Pull) != (b.kind == .Pull) {
			message := a.kind == .Pull ? "%s n'est pas un trou : il se remplit par ->" : "%s est un trou : il se remplit par <-"
			report(k, .Invalid_Carve, a.span, fmt.tprintf(message, display(b)))
			continue
		}
		if slice_contains(chosen[:], p) {
			report(k, .Invalid_Carve, a.span, fmt.tprintf("%s est carvé deux fois", display(b)))
			continue
		}
		append(&chosen, p)
		if !direct(s, p) {
			carve_into(&into, derived, s, p, a, i, c)
			continue
		}
		targets[i] = p.index
		derived.bindings[p.index].value = new_expr(Carved{c.args, i})
	}
	carve_expansions(into, derived, c)
	return targets
}

slice_contains :: proc(places: []Place, p: Place) -> bool {
	for q in places do if q.scope == p.scope && q.index == p.index do return true
	return false
}

// Ce qui a changé autour de ce qu'on marque : la couleur implicite que la forme
// donne à ses bindings (shape), le scope que désigne `.x` (carving).
Around :: struct {
	shape, carving: bool,
}

// mark_changes : dans la copie s, les bindings que le carve change — la valeur
// qu'il a mise (un argument de args), et ce qui en dépend : une couleur, une valeur,
// un scope écrit dedans, une couleur implicite. Rend vrai si un binding de s a changé.
mark_changes :: proc(s, args: ^Scope, around: Around) -> (changed: bool) {
	// une branche dont la couverture change : sa production peut changer avec elle
	cover := s.cover != nil && changes(s.cover, s, args, {carving = around.carving})
	for &b in s.bindings {
		color := b.color != nil ? changes(b.color, s, args, {carving = around.carving}) : around.shape
		value := changes(b.value, s, args, {shape = color, carving = around.carving})
		if cover || color || value {
			b.copy = .Changed
			changed = true
		}
	}
	return
}

// changes : `e`, écrit dans env, dépend d'un binding changé. Chaque scope écrit
// dedans est marqué en passant : les deux opérandes sont toujours parcourus.
changes :: proc(e: ^Expr, env, args: ^Scope, around: Around) -> bool {
	if e == nil do return false
	inner := Around{carving = around.carving} // la forme ne colore que le scope qu'elle attend
	#partial switch v in e^ {
	case Carved:
		return v.args == args
	case Inferred:
		return v.args == args
	case Carving:
		return around.carving
	case Shorthand:
		outer := changes(v.outer, env, args, inner)
		return outer || around.carving
	case Ref:
		sc := env
		for _ in 0 ..< v.up do sc = sc.parent
		return sc.bindings[v.index].copy == .Changed
	case ^Scope:
		return v.parent == env && mark_changes(v, args, around)
	case Access:
		return changes(v.target, env, args, inner)
	case Collapse:
		return changes(v.target, env, args, inner)
	case Carve:
		target := changes(v.target, env, args, inner)
		written := v.args.parent == env && mark_changes(v.args, args, {carving = target})
		return target || written
	case Op:
		left := changes(v.left, env, args, inner)
		right := changes(v.right, env, args, inner)
		return left || right
	case Match:
		changed := changes(v.target, env, args, inner)
		for b in v.branches do changed |= b.parent == env && mark_changes(b, args, inner)
		return changed
	case Range:
		lo := changes(v.lo, env, args, inner)
		hi := changes(v.hi, env, args, inner)
		return lo || hi
	case Unknown:
		return changes(v.layout, env, args, inner)
	}
	return false
}

// carving_of : le scope que dérive le carve dont env est l'un des arguments, ou y
// est écrit.
carving_of :: proc(env: ^Scope) -> ^Scope {
	for sc := env; sc != nil; sc = sc.parent do if sc.carving != nil do return sc.carving
	return nil
}

type_carving :: proc(k: ^Kernel, c: Carving, env: ^Scope) -> ^Expr {
	s := carving_of(env)
	if s == nil do return report(k, .Invalid_Property_Access, c.span, "'.x' sans source ne s'écrit que dans les arguments d'un carve")
	return new_expr(s)
}

// recarves : `z{…}` recarve le champ z du scope carvé s, s'il en a un.
recarves :: proc(s: ^Scope, sh: Shorthand) -> bool {
	if s == nil do return false
	_, found := find_binding(s, sh.field.name, sh.field.ordinal)
	return found
}

type_shorthand :: proc(k: ^Kernel, sh: Shorthand, env: ^Scope) -> ^Expr {
	if recarves(carving_of(env), sh) do return type_access(k, sh.field, env)
	if sh.outer == nil do return report(k, .Undefined_Identifier, sh.field.span, fmt.tprintf("'%s' n'est ni un champ du scope carvé ni un nom visible", sh.field.name))
	return type_of(k, sh.outer, env)
}

// carve_target : le binding que vise un argument, parmi ceux que présente s.
// Nommé, la première occurrence de son nom, ou celle de `x#n` ; `z{…}` qui
// recarve un champ, ce champ ; sans nom, le champ de même rang — ni production ni
// trou. Faux : il n'existe pas — un scope est clos.
carve_target :: proc(s: ^Scope, a: Binding, ordinal: int, position: ^int) -> (Place, bool) {
	if a.name != "" do return find_binding(s, a.name, max(ordinal, 0))
	if sh, ok := shorthand_of(a); ok && recarves(s, sh) do return find_binding(s, sh.field.name, max(sh.field.ordinal, 0))
	rank := position^
	position^ += 1
	for p in places(s) {
		kind := binding_at(p).kind
		if kind == .Product || kind == .Pull do continue
		if rank == 0 do return p, true
		rank -= 1
	}
	return {}, false
}

is_shorthand :: proc(a: Binding) -> bool {
	_, ok := shorthand_of(a)
	return ok
}

// shorthand_of : l'argument est `z{…}`, sans flèche.
shorthand_of :: proc(a: Binding) -> (Shorthand, bool) {
	if a.value == nil do return {}, false
	c, is_carve := a.value^.(Carve)
	if !is_carve do return {}, false
	sh, ok := c.target^.(Shorthand)
	return sh, ok
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

// copy_scope : la copie symbolique d'un scope, sous `parent`, dérivée par le carve
// `site`. Les scopes écrits dedans sont copiés avec lui ; ceux qu'il désigne
// seulement (un argument de carve écrit ailleurs, la forme qui le colore) sont
// partagés. Les types ne sont pas copiés : la copie se type à nouveau.
copy_scope :: proc(s: ^Scope, parent: ^Scope, site: syn.Span) -> ^Scope {
	c := new_scope(parent, s.span)
	c.shape = s.shape
	c.site = site
	c.cover = copy_expr(s.cover, s, c)
	for b in s.bindings {
		append(&c.bindings, Binding{name = b.name, capture = b.capture, kind = b.kind, color = copy_expr(b.color, s, c), value = copy_expr(b.value, s, c), copy = .Same, span = b.span})
	}
	return c
}

// copy_expr : `e`, écrit dans le scope `from`, réécrit dans sa copie `to`.
copy_expr :: proc(e: ^Expr, from, to: ^Scope) -> ^Expr {
	if e == nil do return nil
	#partial switch v in e^ {
	case ^Scope:
		if v.parent != from do return e
		return new_expr(copy_scope(v, to, to.site))
	case Access:
		return new_expr(Access{copy_expr(v.target, from, to), v.name, v.ordinal, v.span})
	case Collapse:
		return new_expr(Collapse{copy_expr(v.target, from, to), v.span})
	case Carve:
		args := v.args.parent == from ? copy_scope(v.args, to, to.site) : v.args
		return new_expr(Carve{copy_expr(v.target, from, to), args, v.ordinals, v.span})
	case Op:
		return new_expr(Op{v.kind, copy_expr(v.left, from, to), copy_expr(v.right, from, to), v.span})
	case Match:
		branches := make([]^Scope, len(v.branches))
		for b, i in v.branches do branches[i] = copy_scope(b, to, to.site)
		return new_expr(Match{copy_expr(v.target, from, to), branches, v.span})
	case Range:
		return new_expr(Range{copy_expr(v.lo, from, to), copy_expr(v.hi, from, to), v.span})
	case Unknown:
		return new_expr(Unknown{copy_expr(v.layout, from, to), v.span})
	}
	return e // Set, Ref, Carved, Invalid : rien à réécrire
}
