package kernel

import syn "../compiler"

// L'IR du kernel. Un scope est une liste ordonnée de bindings ; un binding porte
// une couleur (à gauche du `:`) et une valeur (à droite de la flèche). La même
// forme sert au programme et à ses types : `type_of` d'un scope est le singleton
// du scope de ses types de bindings, dont chaque binding garde sa couleur
// (`color_of`, un ensemble) et porte son type à la place de sa valeur.

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
	name:    string, // "" = anonyme ou production
	capture: string, // alias invisible `(h)`
	kind:    Binding_Kind,
	color:   ^Expr, // nil = non coloré
	value:   ^Expr, // nil = pas de valeur : le défaut de la couleur
	span:    syn.Span,
}

Scope :: struct {
	parent:   ^Scope,
	bindings: [dynamic]Binding,
	span:     syn.Span,
}

// Un binding, résolu lexicalement : remonter `up` scopes, prendre le binding `index`.
Ref :: struct {
	up:    int,
	index: int,
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
	Op,
	Range,
	Unknown,
	Poly, // une forme sur des inconnues (résultat de type_of seulement) : unknown.odin
	Term,
	Family, // un ensemble qui dépend d'inconnues : family.odin
	Subsets, // son enveloppe, quand il dépend de trop d'inconnues
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
	Invalid_operator,
	Invalid_Range,
	Constraint_Mismatch,
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
}

report :: proc(k: ^Kernel, kind: Error_Kind, span: syn.Span, message: string) -> ^Expr {
	append(&k.errors, Error{kind, message, span})
	return new_expr(Invalid{})
}

is_invalid :: proc(e: ^Expr) -> bool {
	if e == nil do return false
	_, ok := e^.(Invalid)
	return ok
}
