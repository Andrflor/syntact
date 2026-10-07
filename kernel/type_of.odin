package kernel

import "core:fmt"

// type_of : la seule opération sémantique. Le type d'une expression est
// l'ensemble de ses valeurs possibles, écrit lui-même en IR :
//
//   type_of(5)                    = 5                  une valeur connue est son propre singleton
//   type_of(u8)                   = {-> 0..255}        l'ensemble comme valeur : un niveau au-dessus
//   type_of(??::u8)               = ??0                une inconnue, qui vaut dans 0..255
//   type_of(none)                 = none               none = {}, une valeur : son propre singleton
//   type_of(scope{ Σ binding })   = { scope{ Σ typeof(binding) } }
//
// Un binding typé garde son nom et son kind ; sa couleur devient color_of (un
// ensemble), sa valeur devient son type. La vérification `type ⊆ couleur` se
// fait à la fin (check), une fois tout typé.

// singleton : le type dont `x` est l'unique élément. Une valeur atomique est son
// propre singleton (`5` est `{5}`, `none` est `{}`) ; tout autre élément est
// produit par `{-> x}`.
singleton :: proc(x: ^Expr) -> ^Expr {
	if s, ok := x^.(Set); ok && is_atom(s) do return x
	p := new_scope(nil)
	append(&p.bindings, Binding{kind = .Product, value = x})
	return new_expr(p)
}

// the_element : l'unique élément d'un type, s'il en a exactement un.
the_element :: proc(t: ^Expr) -> (^Expr, bool) {
	#partial switch v in t^ {
	case Set:
		if is_atom(v) do return t, true
	case ^Scope:
		if is_producer(v) do return v.bindings[0].value, true
	}
	return nil, false
}

// is_atom : une valeur qui est son propre singleton — un seul élément, ou aucun
// (`none`, l'ensemble vide).
is_atom :: proc(s: Set) -> bool {
	return set_count(s) <= 1
}

// `{-> x}` : un scope dont le seul binding est une production non colorée.
is_producer :: proc(s: ^Scope) -> bool {
	if len(s.bindings) != 1 do return false
	b := s.bindings[0]
	return b.kind == .Product && b.name == "" && b.color == nil
}

type_of :: proc(k: ^Kernel, e: ^Expr, env: ^Scope) -> ^Expr {
	if e == nil do return new_expr(Invalid{})
	switch v in e^ {
	case Set:
		return singleton(e)
	case ^Scope:
		return singleton(new_expr(type_scope(k, v, env)))
	case Ref:
		return type_ref(k, v, env)
	case Access:
		return type_access(k, v, env)
	case Collapse:
		return type_collapse(k, v, env)
	case Op:
		return type_op(k, v, env)
	case Range:
		return type_range(k, v, env)
	case Unknown:
		return type_unknown(k, v, env, nil)
	case Poly, Term, Family, Subsets, Invalid:
		return e
	}
	return e
}

// type_scope construit le scope typé, binding par binding, dans l'ordre : chaque
// binding est typé en voyant ceux du dessus. La case existe avant d'être typée ;
// une ref qui la trouve encore vide est une récursion.
type_scope :: proc(k: ^Kernel, s: ^Scope, env: ^Scope) -> ^Scope {
	t := new_scope(env, s.span)
	append(&k.typed, t)
	for &b in s.bindings {
		append(&t.bindings, Binding{name = b.name, capture = b.capture, kind = b.kind, span = b.span})
		i := len(t.bindings) - 1
		color, value := type_binding(k, &b, t)
		t.bindings[i].color = color
		t.bindings[i].value = value
	}
	return t
}

type_binding :: proc(k: ^Kernel, b: ^Binding, env: ^Scope) -> (color: ^Expr, value: ^Expr) {
	if b.kind != .Push && b.kind != .Product do return nil, new_expr(Invalid{}) // signalé à la construction
	if b.color != nil do color = color_of(k, b.color, env, b)
	switch {
	case b.value == nil:
		value = default_of(k, color, b)
	case is_bare_unknown(b.value) && color != nil:
		value = type_unknown(k, b.value^.(Unknown), env, color) // `??` prend sa couleur
	case:
		value = type_of(k, b.value, env)
	}
	return
}

is_bare_unknown :: proc(e: ^Expr) -> bool {
	u, ok := e^.(Unknown)
	return ok && u.layout == nil
}

// color_of : l'élément unique du type de la couleur. nil quand elle ne désigne pas
// un seul ensemble (Insoluble), ou quand une erreur a déjà été signalée dedans.
color_of :: proc(k: ^Kernel, c: ^Expr, env: ^Scope, b: ^Binding) -> ^Expr {
	t := type_of(k, c, env)
	if is_invalid(t) do return nil
	x, ok := the_element(t)
	if !ok {
		report(k, .Insoluble_Constraint, b.span, fmt.tprintf("la couleur de %s ne désigne pas un seul ensemble : %s", display(b), brief(t)))
		return nil
	}
	return x
}

// default_of : le type de la valeur d'un binding qui n'en écrit pas — le défaut de
// sa couleur. Un ensemble : son élément distingué. Un scope : sa première
// production s'il en a, sinon lui-même (`Point:p` vaut Point).
default_of :: proc(k: ^Kernel, color: ^Expr, b: ^Binding) -> ^Expr {
	if color == nil do return new_expr(Invalid{})
	#partial switch c in color^ {
	case Set:
		d, ok := set_default(c)
		if !ok do return color // la couleur none : sa seule valeur est none
		return new_expr(d)
	case ^Scope:
		if p := first_production(c); p >= 0 do return c.bindings[p].value
		return singleton(color)
	}
	return report(k, .Unsupported, b.span, "pas encore dans le kernel : ce défaut")
}

first_production :: proc(s: ^Scope) -> int {
	for b, i in s.bindings do if b.kind == .Product do return i
	return -1
}

type_ref :: proc(k: ^Kernel, r: Ref, env: ^Scope) -> ^Expr {
	sc := env
	for _ in 0 ..< r.up do sc = sc.parent
	v := sc.bindings[r.index].value
	if v == nil do return report(k, .Unsupported, r.span, "pas encore dans le kernel : la récursion")
	return v
}

// scope_element : le scope qu'un type désigne, s'il en désigne exactement un.
scope_element :: proc(t: ^Expr) -> (^Scope, bool) {
	x, ok := the_element(t)
	if !ok do return nil, false
	s, is_scope := x^.(^Scope)
	return s, is_scope
}

type_access :: proc(k: ^Kernel, a: Access, env: ^Scope) -> ^Expr {
	t := type_of(k, a.target, env)
	if is_invalid(t) do return t
	s, ok := scope_element(t)
	if !ok do return report(k, .Invalid_Property_Access, a.span, fmt.tprintf("'.%s' : la cible n'est pas un scope", a.name))
	i := find_binding(s, a.name, a.ordinal)
	if i < 0 do return report(k, .Invalid_Property_Access, a.span, fmt.tprintf("'%s' n'existe pas dans ce scope", a.name))
	v := s.bindings[i].value
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
	s, ok := scope_element(t)
	if !ok do return report(k, .Invalid_Execute, c.span, "on ne collapse qu'un scope")
	p := first_production(s)
	if p < 0 do return new_expr(Set{}) // un scope sans production se réduit à none
	return s.bindings[p].value
}

// type_unknown : une nouvelle inconnue. Ses valeurs possibles viennent de sa forme
// (`??::u8`), de la couleur qui l'attend (`u8:x -> ??`), ou de rien : un `??` sans
// rien peut valoir n'importe quel atome.
type_unknown :: proc(k: ^Kernel, u: Unknown, env: ^Scope, color: ^Expr) -> ^Expr {
	shape := color
	if u.layout != nil {
		t := type_of(k, u.layout, env)
		if is_invalid(t) do return t
		x, ok := the_element(t)
		if !ok do return report(k, .Insoluble_Constraint, u.span, "la forme de ?? doit être un seul ensemble")
		shape = x
	}
	if shape == nil do return new_symbol(k, set_top())
	s, is_set := shape^.(Set)
	if !is_set do return report(k, .Unsupported, u.span, "pas encore dans le kernel : ?? d'un scope")
	return new_symbol(k, s)
}

// type_of(lo..hi) = { x..y | x ∈ type_of(lo), y ∈ type_of(hi) } : voir range_set.
type_range :: proc(k: ^Kernel, r: Range, env: ^Scope) -> ^Expr {
	open := singleton(new_expr(Set{})) // une borne absente : ignorée par range_set
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
