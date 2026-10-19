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
	copy:       Copy,
	span:       syn.Span,
}

// Copy : ce qu'un carve a fait d'un binding de la copie qu'il a dérivée. Une erreur
// n'est signalée qu'une fois, là où on peut la corriger : un binding copié sans
// changement a déjà été vérifié dans sa source, un binding que le carve a changé
// est signalé au carve.
Copy :: enum u8 {
	Written, // pas une copie : le binding tel qu'écrit
	Same, // copié d'une source, sans que le carve ne le touche
	Changed, // la valeur carvée, ou un binding qui en dépend
}

Scope :: struct {
	parent:   ^Scope,
	bindings: [dynamic]Binding,
	shape:    []Place, // la forme qu'il a reçue, place par place : la couleur implicite de ses bindings
	site:     syn.Span, // une copie : le carve qui l'a dérivée, où sont signalées ses erreurs
	carving:  ^Scope, // les arguments d'un carve : le scope qu'il dérive, que `.x` désigne
	cover:    ^Expr, // une branche de pattern : ce qu'elle admet ; nil pour la branche par défaut
	fact:     Fact, // une branche de pattern : ce qu'elle sait de l'inconnue qu'elle reçoit
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

// Inferred : dans un scope carvé, la valeur qu'un trou a reçue du carve sans être
// rempli : celle, parmi ce qui tombe à sa place, qui contient toutes les autres
// (hole.odin).
Inferred :: struct {
	args: ^Scope, // les arguments du carve qui l'a inférée
	type: ^Expr,
}

// `.x` sans source, dans les arguments d'un carve : le scope que ce carve dérive.
// `a{z -> .z{b -> 2}}` recarve le z de a.
Carving :: struct {
	span: syn.Span,
}

// `z{…}` sans flèche, parmi les arguments d'un carve : la cible de ce carve
// intérieur reste à choisir. Si le scope carvé a un champ z, c'est `.z`, et
// l'argument recarve ce champ : `a{z{b -> 2}}` vaut `a{z -> .z{b -> 2}}`. Sinon
// c'est le z visible, et l'argument est positionnel : `Pt{Box{1}}`. On ne le sait
// qu'une fois la cible typée.
Shorthand :: struct {
	field: Access, // .z
	outer: ^Expr, // z, résolu au-dessus ; nil quand rien ne s'appelle z
}

// `target ? {…}` : chaque branche est un scope, dont la production est celle de la
// branche, écrite dans sa couverture (Scope.cover). La première branche qui admet
// la valeur de target la donne (pattern.odin).
Match :: struct {
	target:   ^Expr,
	branches: []^Scope,
	span:     syn.Span,
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
	Inferred,
	Carving,
	Shorthand,
	Op,
	Match,
	Range,
	Unknown,
	Poly, // une valeur entière qui dépend d'inconnues (un type seulement) : unknown.odin
	Term, // une autre valeur qui dépend d'inconnues
	^Var, // une inconnue qui n'est pas un entier pur (un entier est un polynôme)
	Set_Form, // un ensemble qui dépend d'inconnues : set_form.odin
	Cases, // le type d'un pattern sur une inconnue : une valeur par branche atteinte
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
	Invalid_Expansion,
	Invalid_operator,
	Invalid_Range,
	Constraint_Mismatch,
	Non_Exhaustive_Pattern, // une valeur possible qu'aucune branche n'admet
	Unproven, // le kernel ne sait pas prouver qu'une couleur est respectée
	Insoluble_Constraint,
	Infinite_Recursion, // le cas de base d'un type récursif revient à lui-même
	Invalid_Cast, // un cast vers ce qui n'est pas un layout
	Unsupported, // une forme que le kernel ne traite pas encore
}

Error :: struct {
	kind:    Error_Kind,
	message: string,
	span:    syn.Span, // où la signaler
	origin:  syn.Span, // ce qu'elle concerne, écrit dans la source d'une copie ; = span hors des copies
}

Kernel :: struct {
	ast:      ^syn.Ast,
	errors:   [dynamic]Error,
	typed:    [dynamic]^Scope, // tous les scopes typés, pour la vérification finale
	variables: int, // le compte des variables créées : leur ordre (unknown.odin)
	shapes:   map[^Scope]Set, // un scope lu comme couleur, une fois pour toutes (bdd.odin)
	scene:    Scene, // le binding typé ou vérifié en ce moment : où vont ses erreurs
	matching: map[Matching]struct{}, // les appartenances à une forme en cours de décision
}

// Scene : où vont les erreurs du binding en cours. Hors des copies, à l'endroit
// qu'elles concernent ; dans une copie, au carve (site), ou nulle part (quiet).
Scene :: struct {
	site:  syn.Span,
	quiet: bool,
}

// enter : la scène d'un binding du scope s ; rend la précédente, à rétablir.
enter :: proc(k: ^Kernel, s: ^Scope, b: ^Binding) -> (previous: Scene) {
	previous = k.scene
	switch b.copy {
	case .Written:
		k.scene = {}
	case .Same:
		k.scene = {
			quiet = true,
		}
	case .Changed:
		k.scene = {
			site = s.site,
		}
		// la valeur carvée elle-même : à l'argument, quand le carve est celui qui a
		// dérivé ce scope
		if b.value != nil {
			if c, carved := b.value^.(Carved); carved && c.args.span == s.site do k.scene.site = c.args.bindings[c.index].span
		}
	}
	return
}

// report : une erreur, à la place que dit la scène, une seule fois.
report :: proc(k: ^Kernel, kind: Error_Kind, span: syn.Span, message: string) -> ^Expr {
	return report_about(k, kind, span, span, message)
}

// report_about : une erreur signalée en `span`, qui concerne ce qui est écrit en
// `origin` — un binding qu'un scope a reçu d'ailleurs.
report_about :: proc(
	k: ^Kernel,
	kind: Error_Kind,
	span, origin: syn.Span,
	message: string,
) -> ^Expr {
	if !k.scene.quiet {
		e := Error{kind, message, k.scene.site != {} ? k.scene.site : span, origin}
		if !slice.contains(k.errors[:], e) do append(&k.errors, e)
	}
	return new_expr(Invalid{})
}

is_invalid :: proc(e: ^Expr) -> bool {
	if e == nil do return false
	_, ok := e^.(Invalid)
	return ok
}
