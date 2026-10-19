package kernel

import "core:fmt"

// L'EXPANSION
//
// `...E` dépose ici les bindings de la valeur de E, tous et tels quels : un scope
// qui expanse `{2 3}` présente les mêmes bindings que s'il les écrivait. Les
// bindings déposés restent écrits dans leur scope — leurs références y sont
// relatives — et un scope se présente à travers ses expansions (places).
//
// Un carve passe dans l'expansion qui apporte le binding qu'il vise :
// `{...a}{x -> v}` vaut `{...a{x -> v}}`, et ce qui dépend de x dans a se retype
// avec lui.

// Place : un binding tel qu'un scope le présente. Il est écrit dans `scope`, à
// l'index `index` ; `top` est l'index, dans le scope présenté, du binding écrit qui
// l'apporte — lui-même, ou l'expansion qui le dépose.
Place :: struct {
	scope: ^Scope,
	index: int,
	top:   int,
}

binding_at :: proc(p: Place) -> ^Binding {
	return &p.scope.bindings[p.index]
}

// places : les bindings que présente s, ses expansions déposées, dans l'ordre.
// Une expansion pas encore typée, ou invalide, ne dépose rien : son erreur est
// signalée où elle est écrite.
places :: proc(s: ^Scope) -> []Place {
	out := make([dynamic]Place)
	for b, i in s.bindings {
		if b.kind != .Expand {
			append(&out, Place{s, i, i})
			continue
		}
		v, is_scope := expanded(b)
		if !is_scope do continue
		for p in places(v) do append(&out, Place{p.scope, p.index, i})
	}
	return out[:]
}

// expanded : le scope qu'une expansion dépose.
expanded :: proc(b: Binding) -> (^Scope, bool) {
	if b.value_type == nil do return nil, false
	v, is_scope := b.value_type^.(^Scope)
	return v, is_scope
}

// direct : le binding est écrit dans le scope qui le présente.
direct :: proc(s: ^Scope, p: Place) -> bool {
	return p.scope == s && p.index == p.top
}

// type_expansion : la valeur de `...E` doit être un scope. Un scope écrit ici
// reçoit `shape`, la suite de la forme de env à partir de sa place.
type_expansion :: proc(k: ^Kernel, b: ^Binding, env: ^Scope, shape: []Place) {
	previous := enter(k, env, b)
	defer k.scene = previous
	if v, literal := scope_literal(b.value); literal && v.parent == env && shape != nil {
		type_scope(k, v, shape)
		b.value_type = b.value
		return
	}
	if b.color != nil {
		b.color_type = type_color(k, b, env)
		b.value_type = default_of(k, b.color_type, b)
	} else {
		b.value_type = type_of(k, b.value, env)
	}
	if is_invalid(b.value_type) do return
	if _, is_scope := b.value_type^.(^Scope); !is_scope {
		if _, itself := b.value_type^.(Itself); itself {
			b.value_type = report(k, .Unsupported, b.span, "pas encore dans le kernel : expanser un type récursif")
			return
		}
		b.value_type = report(k, .Invalid_Expansion, b.span, fmt.tprintf("on n'expanse qu'un scope : %s", brief(b.value_type)))
	}
}

// Into : les arguments qu'un carve fait passer dans l'expansion `top` de sa copie.
Into :: struct {
	args:     ^Scope,
	ordinals: [dynamic]int,
}

// carve_into : l'argument `a`, l'index i des arguments de c, vise `target`, que
// l'expansion `target.top` apporte. Il devient un argument du carve de cette
// expansion : nommé par le binding qu'il vise, à son occurrence dans le scope
// déposé ; sans nom s'il est positionnel — les positions d'un scope déposé se
// suivent, et le carve les remplit dans l'ordre.
carve_into :: proc(into: ^map[int]Into, derived, s: ^Scope, target: Place, a: Binding, i: int, c: Carve) {
	group, seen := into[target.top]
	if !seen do group = Into{args = new_scope(derived, c.args.span)}
	name, ordinal := "", -1
	if a.name != "" || is_shorthand(a) {
		name = binding_at(target).name
		ordinal = local_ordinal(expanded_scope(s.bindings[target.top]), target, name)
	}
	append(&group.args.bindings, Binding{name = name, kind = a.kind, value = new_expr(Carved{c.args, i}), span = a.span})
	append(&group.ordinals, ordinal)
	into[target.top] = group
}

// carve_expansions : chaque expansion dans laquelle passent des arguments devient
// `...E{…}`.
carve_expansions :: proc(into: map[int]Into, derived: ^Scope, c: Carve) {
	for top, group in into {
		b := &derived.bindings[top]
		b.value = new_expr(Carve{target = b.value, args = group.args, ordinals = group.ordinals[:], span = c.span})
	}
}

// expanded_scope : le scope que dépose une expansion typée.
expanded_scope :: proc(b: Binding) -> ^Scope {
	v, _ := expanded(b)
	return v
}

// local_ordinal : l'occurrence de `name`, dans le scope déposé, qu'est `target`.
local_ordinal :: proc(s: ^Scope, target: Place, name: string) -> int {
	seen := 0
	for p in places(s) {
		if p.scope == target.scope && p.index == target.index do return seen
		if binding_at(p).name == name do seen += 1
	}
	return -1
}

// scope_literal : la valeur écrite est un scope.
scope_literal :: proc(value: ^Expr) -> (^Scope, bool) {
	if value == nil do return nil, false
	v, ok := value^.(^Scope)
	return v, ok
}
