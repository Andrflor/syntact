package kernel

import "core:fmt"

// type_of : la seule opération sémantique. Le type d'une expression est
// l'ensemble qu'elle désigne, écrit lui-même en IR, et simplifié :
//
//   type_of(5)             = 5           une valeur est un ensemble : son propre type
//   type_of(u8)            = 0..255
//   type_of(none)          = none
//   type_of(??::u8)        = ??0         une inconnue, qui vaut dans 0..255
//   type_of(n * 2 + n)     = 3*??0       la forme normale, exacte
//   type_of(??0..10)       = ??0..10     un ensemble qui dépend d'une inconnue
//   type_of(scope)         = scope       ses bindings portent leurs types
//
// Les scopes sont typés sur place : chaque binding garde sa couleur et sa valeur
// symboliques, et reçoit leurs types. La vérification `valeur ⊆ couleur` se fait
// à la fin (check), une fois tout typé.

type_of :: proc(k: ^Kernel, e: ^Expr, env: ^Scope) -> ^Expr {
	if e == nil do return new_expr(Invalid{})
	switch v in e^ {
	case Set:
		return e
	case ^Scope:
		type_scope(k, v)
		return e
	case Ref:
		return type_ref(k, v, env)
	case Access:
		return type_access(k, v, env)
	case Collapse:
		return type_collapse(k, v, env)
	case Carve:
		return type_carve(k, v, env)
	case Carved:
		return type_argument(k, v, nil)
	case Op:
		return type_op(k, v, env)
	case Range:
		return type_range(k, v, env)
	case Unknown:
		return type_unknown(k, v, env, nil)
	case Poly, Term, Set_Form, Invalid:
		return e // déjà un type
	}
	return e
}

// type_scope type chaque binding sur place, dans l'ordre : chacun voit les types
// de ceux du dessus. Une ref vers un binding pas encore typé est une récursion.
// `shape` : la forme que la couleur attend, quand ce scope est la valeur d'un
// binding coloré par elle. Le scope la retient : ses copies la gardent.
type_scope :: proc(k: ^Kernel, s: ^Scope, shape: ^Scope = nil) {
	s.shape = shape
	append(&k.typed, s)
	for &b, i in s.bindings do type_binding(k, &b, s, expected_color(shape, i, b))
}

// expected_color : le type de couleur que la forme attend à la place i, si ce
// binding y correspond (même nom, même kind).
expected_color :: proc(shape: ^Scope, i: int, b: Binding) -> ^Expr {
	if shape == nil || i >= len(shape.bindings) do return nil
	sb := shape.bindings[i]
	if sb.name != b.name || sb.kind != b.kind do return nil
	return sb.color_type
}

// type_binding : la couleur, puis la valeur. Un binding sans couleur écrite prend
// celle que la forme qui l'entoure attend à sa place (`expected`) : la coloration
// implicite (specs/language/11). Le typage est bidirectionnel : la couleur descend
// dans la valeur — un `??` la prend, un scope littéral la passe à ses bindings, un
// argument de carve la reçoit du binding qu'il remplace.
type_binding :: proc(k: ^Kernel, b: ^Binding, env: ^Scope, expected: ^Expr) {
	if b.kind != .Push && b.kind != .Product {
		b.value_type = new_expr(Invalid{}) // signalé à la construction
		return
	}
	b.color_type = b.color != nil ? type_color(k, b, env) : expected
	if b.value == nil {
		b.value_type = default_of(k, b.color_type, b)
		return
	}
	#partial switch v in b.value^ {
	case Unknown:
		if v.layout == nil && b.color_type != nil {
			b.value_type = type_unknown(k, v, env, b.color_type) // `??` prend sa couleur
			return
		}
	case ^Scope:
		if shape, found := expected_shape(k, b.color_type, v); found {
			type_scope(k, v, shape)
			b.value_type = b.value
			return
		}
	case Carved:
		b.value_type = type_argument(k, v, b.color_type)
		return
	}
	b.value_type = type_of(k, b.value, env)
}

// type_color : le type de la couleur. Il doit désigner un seul ensemble, qui ne
// dépend d'aucune inconnue ; sinon la couleur est insoluble.
type_color :: proc(k: ^Kernel, b: ^Binding, env: ^Scope) -> ^Expr {
	t := type_of(k, b.color, env)
	if is_invalid(t) do return t
	if _, closed := color_set(k, t); !closed {
		return report(k, .Insoluble_Constraint, b.span, fmt.tprintf("la couleur de %s ne désigne pas un seul ensemble : %s", display(b), brief(t)))
	}
	return t
}

// expected_shape : la forme qu'un type de couleur attend pour ce scope littéral —
// la couleur elle-même si c'est une forme, ou la seule forme de même structure
// dans une combinaison de formes.
expected_shape :: proc(k: ^Kernel, color: ^Expr, literal: ^Scope) -> (^Scope, bool) {
	if color == nil do return nil, false
	#partial switch c in color^ {
	case ^Scope:
		return c, first_production(c) < 0
	case Set:
		found: ^Scope = nil
		for r in bdd_atoms(c.scopes) {
			if !fits(r, literal) || r.shape == found do continue
			if found != nil do return nil, false // ambigu
			found = r.shape
		}
		return found, found != nil
	}
	return nil, false
}

// fits : le scope littéral a la structure de la forme (noms et kinds, dans l'ordre).
fits :: proc(r: ^Record, literal: ^Scope) -> bool {
	if len(r.fields) != len(literal.bindings) do return false
	for f, i in r.fields do if f.name != literal.bindings[i].name || f.kind != literal.bindings[i].kind do return false
	return true
}

// default_of : le type de la valeur d'un binding qui n'en écrit pas — le défaut de
// sa couleur. Un ensemble : son élément distingué. Un scope : sa première
// production s'il en a, sinon lui-même (`Point:p` vaut Point).
default_of :: proc(k: ^Kernel, color: ^Expr, b: ^Binding) -> ^Expr {
	if color == nil || is_invalid(color) do return new_expr(Invalid{})
	#partial switch c in color^ {
	case Set:
		first, _ := set_first_domain(c)
		#partial switch first {
		case .Scopes:
			return scopes_default(k, c.scopes, b)
		case .Sets:
			if c.sets.cofinite do return report(k, .Unsupported, b.span, "pas encore dans le kernel : le défaut de tous les ensembles sauf quelques-uns")
			return new_expr(c.sets.values[0])
		}
		d, ok := set_default(c)
		if !ok do return color // la couleur none : sa seule valeur est none
		return new_expr(d)
	case ^Scope:
		if p := first_production(c); p >= 0 do return c.bindings[p].value_type
		return color
	}
	return report(k, .Unsupported, b.span, "pas encore dans le kernel : ce défaut")
}

// scopes_default : le défaut d'un ensemble de scopes réduit à une forme, c'est la
// forme elle-même (`Point:p` vaut Point).
scopes_default :: proc(k: ^Kernel, b: Bdd, binding: ^Binding) -> ^Expr {
	if n, is_node := b.(^Bdd_Node); is_node && is_leaf(n.yes, .Top) && is_leaf(n.maybe, .Bottom) && is_leaf(n.no, .Bottom) {
		return new_expr(n.atom.shape)
	}
	return report(k, .Unsupported, binding.span, "pas encore dans le kernel : le défaut d'une combinaison de formes")
}

first_production :: proc(s: ^Scope) -> int {
	for b, i in s.bindings do if b.kind == .Product do return i
	return -1
}

// type_ref : le type du binding désigné.
type_ref :: proc(k: ^Kernel, r: Ref, env: ^Scope) -> ^Expr {
	sc := env
	for _ in 0 ..< r.up do sc = sc.parent
	t := sc.bindings[r.index].value_type
	if t == nil do return report(k, .Unsupported, r.span, "pas encore dans le kernel : la récursion")
	return t
}

type_access :: proc(k: ^Kernel, a: Access, env: ^Scope) -> ^Expr {
	t := type_of(k, a.target, env)
	if is_invalid(t) do return t
	s, ok := t^.(^Scope)
	if !ok do return report(k, .Invalid_Property_Access, a.span, fmt.tprintf("'.%s' : la cible n'est pas un scope", a.name))
	i := find_binding(s, a.name, a.ordinal)
	if i < 0 do return report(k, .Invalid_Property_Access, a.span, fmt.tprintf("'%s' n'existe pas dans ce scope", a.name))
	v := s.bindings[i].value_type
	if v == nil do return report(k, .Unsupported, a.span, "pas encore dans le kernel : la récursion")
	return v
}

// find_binding : l'accès lit la dernière occurrence d'un nom, ou la n-ième avec `#n`.
find_binding :: proc(s: ^Scope, name: string, ordinal: int) -> int {
	if ordinal >= 0 {
		seen := 0
		for b, i in s.bindings {
			if b.name != name do continue
			if seen == ordinal do return i
			seen += 1
		}
		return -1
	}
	#reverse for b, i in s.bindings do if b.name == name do return i
	return -1
}

type_collapse :: proc(k: ^Kernel, c: Collapse, env: ^Scope) -> ^Expr {
	t := type_of(k, c.target, env)
	if is_invalid(t) do return t
	s, ok := t^.(^Scope)
	if !ok do return report(k, .Invalid_Execute, c.span, "on ne collapse qu'un scope")
	p := first_production(s)
	if p < 0 do return new_expr(Set{}) // un scope sans production se réduit à none
	return s.bindings[p].value_type
}

// type_unknown : une nouvelle inconnue. Ses valeurs possibles viennent de sa forme
// (`??::u8`), de la couleur qui l'attend (`u8:x -> ??`), ou de rien : un `??` sans
// rien peut valoir n'importe quel atome.
type_unknown :: proc(k: ^Kernel, u: Unknown, env: ^Scope, color: ^Expr) -> ^Expr {
	shape := color
	if u.layout != nil {
		shape = type_of(k, u.layout, env)
		if is_invalid(shape) do return shape
	}
	if shape == nil do return new_symbol(k, set_top())
	s, closed := color_set(k, shape)
	if !closed do return report(k, .Insoluble_Constraint, u.span, "la forme de ?? doit être un seul ensemble")
	if domain_count(s, .Scopes) > 0 || domain_count(s, .Sets) > 0 do return report(k, .Unsupported, u.span, "pas encore dans le kernel : ?? d'un scope ou d'un ensemble")
	return new_symbol(k, s)
}

// type_of(lo..hi) = l'union des plages x..y, x ∈ type_of(lo), y ∈ type_of(hi) : voir range_set.
type_range :: proc(k: ^Kernel, r: Range, env: ^Scope) -> ^Expr {
	open := new_expr(Set{}) // une borne absente : ignorée par range_set
	lo, hi := open, open
	if r.lo != nil do lo = type_of(k, r.lo, env)
	if r.hi != nil do hi = type_of(k, r.hi, env)
	if is_invalid(lo) do return lo
	if is_invalid(hi) do return hi
	return set_operation(k, Set_Op{kind = .Range, lo_open = r.lo == nil, hi_open = r.hi == nil}, r.span, lo, hi)
}

first_rune :: proc(s: string) -> rune {
	for r in s do return r
	return 0
}

display :: proc(b: ^Binding) -> string {
	if b.name != "" do return fmt.tprintf("'%s'", b.name)
	if b.kind == .Product do return "la production"
	return "ce binding"
}
