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

// Record : une forme. `shape` est le scope qu'elle lit (son défaut). `exact` : elle
// n'admet que ce scope valeur lui-même, chaque binding n'admettant que sa valeur.
Record :: struct {
	fields: []Field,
	shape:  ^Scope,
	exact:  bool,
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

new_record :: proc(fields: []Field, shape: ^Scope, exact := false) -> ^Record {
	r := new(Record)
	r^ = Record{fields, shape, exact, record_count}
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

// set_everything : toutes les valeurs, scopes et ensembles compris.
set_everything :: proc() -> Set {
	s := set_top()
	s.sorts += {.Scopes, .Sets}
	s.scopes = .Top
	s.sets = Set_Values{cofinite = true}
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

// --- les types lus comme couleurs ---

// color_set : l'ensemble des valeurs qu'un type admet comme couleur. Un ensemble
// admet ses éléments. Un scope avec des productions admet chacune : une production
// colorée, ce qu'admet sa couleur ; sinon, sa valeur exactement (`{-> u8}` n'admet
// que la valeur u8). Sans production, c'est une forme. Faux quand le type dépend
// d'une inconnue : ce n'est pas un seul ensemble. Un scope n'est lu qu'une fois.
color_set :: proc(k: ^Kernel, t: ^Expr) -> (Set, bool) {
	#partial switch v in t^ {
	case Set:
		return v, true
	case ^Scope:
		if s, seen := k.shapes[v]; seen do return s, true
		s, closed := scope_color_set(k, v)
		if closed do k.shapes[v] = s
		return s, closed
	}
	return {}, false
}

scope_color_set :: proc(k: ^Kernel, s: ^Scope) -> (set: Set, ok: bool) {
	shown := places(s)
	if first_production(s) != nil {
		for p in shown {
			b := binding_at(p)^
			if b.kind != .Product do continue
			x := admitted_by(k, b) or_return
			set = set_union(set, x)
		}
		return set, true
	}
	fields := make([]Field, len(shown))
	for p, i in shown {
		b := binding_at(p)^
		fields[i] = Field{name = b.name, kind = b.kind}
		if b.color == nil && b.name != "" {
			fields[i].free = true // un binding nommé sans couleur n'impose rien : un carve peut lui donner toute valeur
			continue
		}
		fields[i].set = admitted_by(k, b) or_return
	}
	return Set{sorts = {.Scopes}, scopes = bdd_atom(new_record(fields, s))}, true
}

// admitted_by : ce qu'un binding admet — ce qu'admet sa couleur, sinon sa valeur.
admitted_by :: proc(k: ^Kernel, b: Binding) -> (Set, bool) {
	if b.color != nil do return color_set(k, b.color_type)
	return exact_set(k, b.value_type)
}

// exact_set : l'ensemble dont ce type est le seul élément. Un atome est son propre
// singleton ; un ensemble d'au moins deux éléments est une valeur de la sorte des
// ensembles ; un scope, la forme dont chaque binding n'admet que sa valeur. Faux
// quand le type dépend d'une inconnue.
exact_set :: proc(k: ^Kernel, t: ^Expr) -> (set: Set, ok: bool) {
	if t == nil || is_invalid(t) do return {}, false
	#partial switch v in t^ {
	case Set:
		if is_atom(v) do return v, true
		return Set{sorts = {.Sets}, sets = values_point(v)}, true
	case ^Scope:
		shown := places(v)
		fields := make([]Field, len(shown))
		for p, i in shown {
			b := binding_at(p)^
			fields[i] = Field{name = b.name, kind = b.kind}
			fields[i].set = exact_set(k, b.value_type) or_return
		}
		return Set{sorts = {.Scopes}, scopes = bdd_atom(new_record(fields, v, exact = true))}, true
	}
	return {}, false
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
	shown := places(s)
	if len(shown) != len(r.fields) do return .Never
	result := Member.Always
	for f, i in r.fields {
		b := binding_at(shown[i])^
		if f.name != b.name || f.kind != b.kind do return .Never
		if f.free || colored_within(k, b, f.set) do continue
		result = and3(result, member_of(admits(k, f.set, b.value_type), is_closed_type(b.value_type)))
	}
	return result
}

// colored_within : la couleur du binding n'admet que des éléments de `s`. Sa valeur
// y est alors, ou sa propre vérification le signale : rien à décider deux fois.
colored_within :: proc(k: ^Kernel, b: Binding, s: Set) -> bool {
	if b.color_type == nil do return false
	c, closed := color_set(k, b.color_type)
	return closed && atoms_subset(c, s)
}

// is_closed_type : un type sans inconnue — son verdict vaut pour toutes leurs valeurs.
is_closed_type :: proc(t: ^Expr) -> bool {
	#partial switch v in t^ {
	case Poly, Term, Set_Form:
		return false
	case ^Scope:
		for p in places(v) do if field := binding_at(p).value_type; field != nil && !is_closed_type(field) do return false
	}
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
		atom := print_type(new_expr(v.atom.shape))
		if v.atom.exact do atom = fmt.tprintf("{{-> %s}}", atom) // le scope lui-même, pas sa forme
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
