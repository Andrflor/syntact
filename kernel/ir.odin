package kernel

import syn "../compiler"
import "core:slice"

// L'IR du kernel. Un scope est une liste ordonnée de bindings. Un binding porte
// quatre choses : sa couleur et sa valeur, symboliques, telles qu'écrites — et
// leurs types. Le type simplifie (un carve qui donne 5 a le type 5), la valeur
// garde toute la structure qui l'a produit.
//
// Les types sont eux aussi des expressions : le type de 5 est 5, celui de u8 est
// 0..255, celui de `??::u8` est l'inconnue ??0. Un scope est son propre type : ses
// bindings portent déjà les leurs.

Binding_Kind :: enum u8 {
	Push, // name -> value
	Pull, // name <- value
	Product, // -> value
	Expand, // ...value
	Event_Push, // >-
	Event_Pull, // -<
	Resonance_Push, // >>-
	Resonance_Pull, // -<<
	Reactive_Push, // >>=
	Reactive_Pull, // =<<
}

Binding :: struct {
	name:       string, // "" = anonyme ou production
	capture:    string, // alias invisible `(h)`
	kind:       Binding_Kind,
	color:      ^Expr, // à gauche du `:` ; nil = non coloré
	value:      ^Expr, // à droite de la flèche ; nil = pas écrite : le défaut de la couleur
	color_type: ^Expr, // type_of(color) : un seul ensemble, qui ne dépend d'aucune inconnue
	value_type: ^Expr, // type_of(value), ou le défaut de color_type ; nil = pas encore typé
	span:       syn.Span,
}

Scope :: struct {
	parent:   ^Scope,
	bindings: [dynamic]Binding,
	shape:    ^Scope, // la forme contre laquelle il a été typé : la couleur implicite de ses bindings
	span:     syn.Span,
}

// Un binding, résolu lexicalement : remonter `up` scopes, prendre le binding `index`.
Ref :: struct {
	up:    int,
	index: int,
	name:  string, // tel qu'écrit, pour l'impression
	span:  syn.Span,
}

// `target.name` (dernière occurrence) ou `target.name#n`.
Access :: struct {
	target:  ^Expr,
	name:    string,
	ordinal: int, // -1 = dernière occurrence
	span:    syn.Span,
}

// `target!` : le scope réduit par sa première production.
Collapse :: struct {
	target: ^Expr,
	span:   syn.Span,
}

// Un opérateur. `left` est nil pour un opérateur unaire (`~x`, `>0`, `-x`).
Op :: struct {
	kind:  syn.Operator_Kind,
	left:  ^Expr,
	right: ^Expr,
	span:  syn.Span,
}

// `target{…}` : un scope dérivé de target, dont des bindings reçoivent une autre
// valeur. Les arguments sont un scope écrit à cet endroit : `x -> v` vise la
// première occurrence de x (`x#n -> v`, la n-ième), un argument sans nom vise le
// binding de même rang parmi ceux qui ne sont pas des productions.
Carve :: struct {
	target:   ^Expr,
	args:     ^Scope,
	ordinals: []int, // pour chaque argument, l'occurrence visée ; -1 : la première
	span:     syn.Span,
}

// Carved : dans un scope carvé, la valeur qu'un argument a mise à la place. Elle
// reste l'argument `index` de `args`, écrit et typé là où il a été écrit.
Carved :: struct {
	args:  ^Scope,
	index: int,
}

// `lo..hi`. Une borne nil est ouverte. Entre des caractères, l'intervalle porte sur
// les caractères (`'a'..'z'`) ; entre des chaînes, sur les positions (`"jwt"..`
// commence par, `.."_"` finit par).
Range :: struct {
	lo:   ^Expr,
	hi:   ^Expr,
	span: syn.Span,
}

// `??` (layout nil) ou `??::T` : une valeur inconnue, dont seul le type est connu.
Unknown :: struct {
	layout: ^Expr,
	span:   syn.Span,
}

// Une erreur déjà signalée à cet endroit : tout ce qui en dépend reste silencieux.
Invalid :: struct {}

Expr :: union {
	^Scope,
	Set,
	Ref,
	Access,
	Collapse,
	Carve,
	Carved,
	Op,
	Range,
	Unknown,
	Poly, // une valeur entière qui dépend d'inconnues (un type seulement) : unknown.odin
	Term, // une autre valeur qui dépend d'inconnues
	Set_Form, // un ensemble qui dépend d'inconnues : set_form.odin
	Invalid,
}

new_expr :: proc(e: Expr) -> ^Expr {
	r := new(Expr)
	r^ = e
	return r
}

new_scope :: proc(parent: ^Scope, span: syn.Span = {}) -> ^Scope {
	s := new(Scope)
	s.parent = parent
	s.span = span
	return s
}

// --- erreurs ---

Error_Kind :: enum u8 {
	Undefined_Identifier,
	Invalid_Binding_Name,
	Invalid_Property_Access,
	Invalid_Execute,
	Invalid_Carve,
	Invalid_operator,
	Invalid_Range,
	Constraint_Mismatch,
	Unproven, // le kernel ne sait pas prouver qu'une couleur est respectée
	Insoluble_Constraint,
	Unsupported, // une forme que le kernel ne traite pas encore
}

Error :: struct {
	kind:    Error_Kind,
	message: string,
	span:    syn.Span,
}

Kernel :: struct {
	ast:     ^syn.Ast,
	errors:  [dynamic]Error,
	typed:   [dynamic]^Scope, // tous les scopes typés, pour la vérification finale
	symbols: [dynamic]Set, // l'ensemble des valeurs possibles de chaque inconnue
	shapes:  map[^Scope]Set, // un scope lu comme couleur, une fois pour toutes (bdd.odin)
}

// report : une erreur, une seule fois — une copie re-typée par un carve retrouve
// les erreurs de l'original qui ne dépendent pas du carve.
report :: proc(k: ^Kernel, kind: Error_Kind, span: syn.Span, message: string) -> ^Expr {
	e := Error{kind, message, span}
	if !slice.contains(k.errors[:], e) do append(&k.errors, e)
	return new_expr(Invalid{})
}

is_invalid :: proc(e: ^Expr) -> bool {
	if e == nil do return false
	_, ok := e^.(Invalid)
	return ok
}
