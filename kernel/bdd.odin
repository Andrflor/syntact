package kernel

import "core:fmt"
import "core:slice"
import "core:strings"

// LES ENSEMBLES DE SCOPES : des combinaisons de formes.
//
// Une forme est une couleur de scope sans production — `{u8:x  u8:y}` — lue comme
// l'ensemble des scopes de même structure dont chaque binding est admis par le
// sien. `|`, `&` et `~` de formes se gardent dans un BDD paresseux (Frisch,
// thèse, ch. 7 ; Elixir 1.19) : `{a, oui, peut, non}` vaut
// `(a & oui) | peut | (~a & non)`. Les unions restent dans `peut` au lieu d'être
// distribuées : la taille reste celle de l'écriture. On ne distribue qu'en
// décidant, chemin par chemin, puis champ par champ.

// Record : une forme. `shape` est le scope typé qu'elle lit (son défaut).
Record :: struct {
	fields: []Field,
	shape:  ^Scope,
	id:     int, // l'ordre des nœuds du BDD
}

Field :: struct {
	name: string,
	kind: Binding_Kind,
	set:  Set, // ce que le binding admet
	free: bool, // un binding nommé sans couleur n'impose rien
}

Bdd_Leaf :: enum u8 {
	Bottom,
	Top,
}

Bdd :: union #no_nil {
	Bdd_Leaf, // la valeur zéro : Bottom, aucun scope
	^Bdd_Node,
}

Bdd_Node :: struct {
	atom:           ^Record,
	yes, maybe, no: Bdd,
}

@(thread_local)
record_count: int

new_record :: proc(fields: []Field, shape: ^Scope) -> ^Record {
	r := new(Record)
	r^ = Record{fields, shape, record_count}
	record_count += 1
	return r
}

is_leaf :: proc(b: Bdd, leaf: Bdd_Leaf) -> bool {
	l, ok := b.(Bdd_Leaf)
	return ok && l == leaf
}

bdd_atom :: proc(r: ^Record) -> Bdd {
	return node(r, .Top, .Bottom, .Bottom)
}

// node : un nœud, simplifié quand une branche rend les autres inutiles.
node :: proc(atom: ^Record, yes, maybe, no: Bdd) -> Bdd {
	if is_leaf(maybe, .Top) do return .Top
	if is_leaf(yes, .Bottom) && is_leaf(no, .Bottom) do return maybe
	n := new(Bdd_Node)
	n^ = Bdd_Node{atom, yes, maybe, no}
	return n
}

bdd_or :: proc(a, b: Bdd) -> Bdd {
	if is_leaf(a, .Top) || is_leaf(b, .Top) do return .Top
	if is_leaf(a, .Bottom) do return b
	if is_leaf(b, .Bottom) do return a
	x, y := a.(^Bdd_Node), b.(^Bdd_Node)
	switch {
	case x.atom == y.atom:
		return node(x.atom, bdd_or(x.yes, y.yes), bdd_or(x.maybe, y.maybe), bdd_or(x.no, y.no))
	case x.atom.id < y.atom.id:
		return node(x.atom, x.yes, bdd_or(x.maybe, b), x.no) // l'union reste paresseuse
	}
	return node(y.atom, y.yes, bdd_or(a, y.maybe), y.no)
}

bdd_and :: proc(a, b: Bdd) -> Bdd {
	if is_leaf(a, .Bottom) || is_leaf(b, .Bottom) do return .Bottom
	if is_leaf(a, .Top) do return b
	if is_leaf(b, .Top) do return a
	x, y := a.(^Bdd_Node), b.(^Bdd_Node)
	switch {
	case x.atom == y.atom:
		return node(x.atom, bdd_and(bdd_or(x.yes, x.maybe), bdd_or(y.yes, y.maybe)), .Bottom, bdd_and(bdd_or(x.no, x.maybe), bdd_or(y.no, y.maybe)))
	case x.atom.id < y.atom.id:
		return node(x.atom, bdd_and(x.yes, b), bdd_and(x.maybe, b), bdd_and(x.no, b))
	}
	return node(y.atom, bdd_and(a, y.yes), bdd_and(a, y.maybe), bdd_and(a, y.no))
}

// a ∖ b : on ne distribue que le long de l'atome courant.
bdd_diff :: proc(a, b: Bdd) -> Bdd {
	if is_leaf(b, .Top) || is_leaf(a, .Bottom) do return .Bottom
	if is_leaf(b, .Bottom) do return a
	y := b.(^Bdd_Node)
	x, a_node := a.(^Bdd_Node)
	switch {
	case !a_node || y.atom.id < x.atom.id:
		return node(y.atom, bdd_diff(a, bdd_or(y.yes, y.maybe)), .Bottom, bdd_diff(a, bdd_or(y.no, y.maybe)))
	case x.atom == y.atom:
		return node(x.atom, bdd_diff(bdd_or(x.yes, x.maybe), bdd_or(y.yes, y.maybe)), .Bottom, bdd_diff(bdd_or(x.no, x.maybe), bdd_or(y.no, y.maybe)))
	}
	return node(x.atom, bdd_diff(x.yes, b), bdd_diff(x.maybe, b), bdd_diff(x.no, b))
}

// bdd_is_empty : chaque chemin est une intersection de formes moins des formes ;
// le BDD est vide si chaque chemin l'est.
bdd_is_empty :: proc(b: Bdd) -> bool {
	walk :: proc(b: Bdd, pos, neg: ^[dynamic]^Record) -> bool {
		switch v in b {
		case Bdd_Leaf:
			return v == .Bottom || records_empty(pos[:], neg[:])
		case ^Bdd_Node:
			append(pos, v.atom)
			yes := walk(v.yes, pos, neg)
			pop(pos)
			if !yes || !walk(v.maybe, pos, neg) do return false
			append(neg, v.atom)
			no := walk(v.no, pos, neg)
			pop(neg)
			return no
		}
		return true
	}
	pos := make([dynamic]^Record, context.temp_allocator)
	neg := make([dynamic]^Record, context.temp_allocator)
	return walk(b, &pos, &neg)
}

bdd_subset :: proc(a, b: Bdd) -> bool {
	return bdd_is_empty(bdd_diff(a, b))
}

// records_empty : ∩pos ∖ ∪neg = ∅ ? Deux structures différentes ne se
// rencontrent pas ; sans forme positive, ce sont tous les scopes moins quelques
// formes, et il en reste toujours (une autre structure).
records_empty :: proc(pos, neg: []^Record) -> bool {
	if len(pos) == 0 do return false
	first := pos[0]
	fields := make([]Set, len(first.fields), context.temp_allocator)
	for f, i in first.fields do fields[i] = field_set(f)
	for r in pos[1:] {
		if !same_structure(r, first) do return true
		for &f, i in fields do f = set_intersect(f, field_set(r.fields[i]))
	}
	cover := make([dynamic][]Set, context.temp_allocator)
	for r in neg {
		if !same_structure(r, first) do continue
		sets := make([]Set, len(r.fields), context.temp_allocator)
		for f, i in r.fields do sets[i] = field_set(f)
		append(&cover, sets)
	}
	return product_covered(fields, cover[:])
}

// product_covered : F₁ × … × Fₙ ⊆ ∪ cover ? On retire une forme N à la fois : ce
// qui reste de F hors de N est l'union, pour chaque champ i, de F avec Fᵢ ∖ Nᵢ.
product_covered :: proc(fields: []Set, cover: [][]Set) -> bool {
	for f in fields do if set_is_empty(f) do return true
	if len(cover) == 0 do return false
	n := cover[0]
	for f, i in fields {
		rest := slice.clone(fields, context.temp_allocator)
		rest[i] = set_diff(f, n[i])
		if !product_covered(rest, cover[1:]) do return false
	}
	return true
}

same_structure :: proc(a, b: ^Record) -> bool {
	if len(a.fields) != len(b.fields) do return false
	for f, i in a.fields do if f.name != b.fields[i].name || f.kind != b.fields[i].kind do return false
	return true
}

// field_set : ce qu'un binding admet ; tout, s'il n'impose rien.
field_set :: proc(f: Field) -> Set {
	return set_everything() if f.free else f.set
}

// set_everything : toutes les valeurs, scopes compris.
set_everything :: proc() -> Set {
	s := set_top()
	s.sorts += {.Scopes}
	s.scopes = .Top
	return s
}

// bdd_atoms : les formes qui apparaissent dans le BDD.
bdd_atoms :: proc(b: Bdd) -> []^Record {
	out := make([dynamic]^Record, context.temp_allocator)
	walk :: proc(b: Bdd, out: ^[dynamic]^Record) {
		n, is_node := b.(^Bdd_Node)
		if !is_node do return
		if !slice.contains(out[:], n.atom) do append(out, n.atom)
		walk(n.yes, out)
		walk(n.maybe, out)
		walk(n.no, out)
	}
	walk(b, &out)
	return out[:]
}

// --- les formes, depuis les scopes typés ---

// shape_set : l'ensemble qu'un scope typé désigne comme couleur. Avec des
// productions, ce qu'admet l'une d'elles ; sans, sa forme. Faux quand un binding
// n'a pas d'ensemble clos (une valeur qui dépend d'une inconnue, un ensemble
// comme valeur) : la couleur se lit alors binding par binding (scope_admits).
shape_set :: proc(s: ^Scope) -> (Set, bool) {
	if first_production(s) >= 0 {
		u := Set{}
		for b in s.bindings {
			if b.kind != .Product do continue
			x, ok := admitted_set(b)
			if !ok do return {}, false
			u = set_union(u, x)
		}
		return u, true
	}
	fields := make([]Field, len(s.bindings))
	for b, i in s.bindings {
		fields[i] = Field{name = b.name, kind = b.kind}
		if b.color == nil && b.name != "" {
			fields[i].free = true
			continue
		}
		x, ok := admitted_set(b)
		if !ok do return {}, false
		fields[i].set = x
	}
	return Set{sorts = {.Scopes}, scopes = bdd_atom(new_record(fields, s))}, true
}

// admitted_set : ce qu'admet un binding d'une couleur — sa couleur, sinon sa
// valeur, quand c'est un atome ou un scope clos.
admitted_set :: proc(b: Binding) -> (Set, bool) {
	if b.color != nil do return colour_set(b.color)
	if b.value == nil do return {}, false
	if s, is_set := b.value^.(Set); is_set do return s, true
	if v, is_scope := scope_element(b.value); is_scope do return shape_of_value(v)
	return {}, false
}

colour_set :: proc(c: ^Expr) -> (Set, bool) {
	#partial switch v in c^ {
	case Set:
		return v, true
	case ^Scope:
		return shape_set(v)
	}
	return {}, false
}

// shape_of_value : un scope valeur, comme le singleton de sa forme — chaque
// binding admet exactement sa valeur.
shape_of_value :: proc(v: ^Scope) -> (Set, bool) {
	if first_production(v) >= 0 do return {}, false // un ensemble comme valeur
	fields := make([]Field, len(v.bindings))
	for b, i in v.bindings {
		fields[i] = Field{name = b.name, kind = b.kind}
		if s, is_set := b.value^.(Set); is_set && is_atom(s) {
			fields[i].set = s
			continue
		}
		inner, is_scope := scope_element(b.value)
		if !is_scope do return {}, false
		x, ok := shape_of_value(inner)
		if !ok do return {}, false
		fields[i].set = x
	}
	return Set{sorts = {.Scopes}, scopes = bdd_atom(new_record(fields, v))}, true
}

// --- l'admission d'un scope valeur ---

// Member : l'appartenance d'une valeur qui peut dépendre d'inconnues. « Pas
// toujours » (une valeur des inconnues sort) ne se nie pas, et deux « pas
// toujours » ne se combinent pas par « ou » : ce ne sont pas forcément les mêmes
// valeurs. « Jamais » se combine librement.
Member :: enum u8 {
	Always,
	Not_Always,
	Never,
	Unknown,
}

member_of :: proc(v: Verdict, closed: bool) -> Member {
	switch v {
	case .Proved:
		return .Always
	case .Refuted:
		return closed ? .Never : .Not_Always
	case .Undecided:
	}
	return .Unknown
}

and3 :: proc(a, b: Member) -> Member {
	switch {
	case a == .Never || b == .Never:
		return .Never
	case a == .Always:
		return b
	case b == .Always:
		return a
	case a == .Not_Always || b == .Not_Always:
		return .Not_Always
	}
	return .Unknown
}

or3 :: proc(a, b: Member) -> Member {
	switch {
	case a == .Always || b == .Always:
		return .Always
	case a == .Never:
		return b
	case b == .Never:
		return a
	}
	return .Unknown
}

not3 :: proc(a: Member) -> Member {
	#partial switch a {
	case .Always:
		return .Never
	case .Never:
		return .Always
	}
	return .Unknown
}

// bdd_admits : le scope valeur `s` est-il dans l'ensemble `b` ?
bdd_admits :: proc(k: ^Kernel, b: Bdd, s: ^Scope) -> Verdict {
	switch bdd_member(k, b, s) {
	case .Always:
		return .Proved
	case .Not_Always, .Never:
		return .Refuted
	case .Unknown:
	}
	return .Undecided
}

bdd_member :: proc(k: ^Kernel, b: Bdd, s: ^Scope) -> Member {
	switch v in b {
	case Bdd_Leaf:
		return v == .Top ? .Always : .Never
	case ^Bdd_Node:
		in_atom := record_member(k, v.atom, s)
		via_yes := and3(in_atom, bdd_member(k, v.yes, s))
		via_no := and3(not3(in_atom), bdd_member(k, v.no, s))
		return or3(or3(via_yes, bdd_member(k, v.maybe, s)), via_no)
	}
	return .Never
}

record_member :: proc(k: ^Kernel, r: ^Record, s: ^Scope) -> Member {
	if len(s.bindings) != len(r.fields) do return .Never
	result := Member.Always
	for f, i in r.fields {
		b := s.bindings[i]
		if f.name != b.name || f.kind != b.kind do return .Never
		if f.free do continue
		result = and3(result, member_of(admits(k, new_expr(f.set), b.value), is_closed_value(b.value)))
	}
	return result
}

// is_closed_value : une valeur sans inconnue — son verdict vaut pour toutes.
is_closed_value :: proc(v: ^Expr) -> bool {
	#partial switch x in v^ {
	case Set:
		return true
	case Poly, Term, Family, Subsets:
		return false
	}
	inner, is_scope := scope_element(v)
	if !is_scope do return true
	for b in inner.bindings do if !is_closed_value(b.value) do return false
	return true
}

// --- impression : `(a & oui) | peut | (~a & non)`, en Syntact ---

printed_bdd :: proc(b: Bdd) -> (string, Level) {
	Part :: struct {
		text:  string,
		level: Level,
	}
	switch v in b {
	case Bdd_Leaf:
		return v == .Top ? "scope" : "none", .PRIMARY
	case ^Bdd_Node:
		atom := print_expr(new_expr(v.atom.shape))
		parts := make([dynamic]Part, context.temp_allocator)
		branch :: proc(parts: ^[dynamic]Part, head: string, head_level: Level, rest: Bdd) {
			if is_leaf(rest, .Bottom) do return
			if is_leaf(rest, .Top) {
				append(parts, Part{head, head_level})
				return
			}
			text, level := printed_bdd(rest)
			append(parts, Part{fmt.tprintf("%s & %s", head, wrap(text, level, above(.AND))), .AND})
		}
		branch(&parts, atom, .PRIMARY, v.yes)
		if !is_leaf(v.maybe, .Bottom) {
			text, level := printed_bdd(v.maybe)
			append(&parts, Part{text, level})
		}
		branch(&parts, fmt.tprintf("~%s", atom), .UNARY, v.no)
		if len(parts) == 1 do return parts[0].text, parts[0].level
		texts := make([]string, len(parts), context.temp_allocator)
		for p, i in parts do texts[i] = wrap(p.text, p.level, above(.OR))
		return strings.join(texts, " | "), .OR
	}
	return "none", .PRIMARY
}
