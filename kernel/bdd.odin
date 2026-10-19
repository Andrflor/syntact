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
// n'admet que ce scope valeur lui-même, chaque binding n'admettant que son contrat.
// `equation` : une self-référence — la forme n'a pas de champs, elle renvoie à
// l'équation de `shape`, lue seulement au moment de décider (§3 de
// specs/kernel-recursion.md : on ne déplie jamais).
Record :: struct {
	fields:   []Field,
	shape:    ^Scope,
	exact:    bool,
	equation: ^Expr, // la self-référence telle qu'écrite ; nil pour une forme
	id:       int, // l'ordre des nœuds du BDD
}

Field :: struct {
	name:   string,
	kind:   Binding_Kind,
	set:    Set, // ce que le binding admet ; pour une suite, les scopes qu'elle forme
	free:   bool, // un binding nommé sans couleur n'impose rien
	run:    bool, // `...C:` : une suite de bindings, qui forme un scope admis par C
	counts: Ints, // une suite comptée : n morceaux, n parmi counts, chacun admis par set ; vide : un seul
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

new_record :: proc(fields: []Field, shape: ^Scope, exact := false, equation: ^Expr = nil) -> ^Record {
	r := new(Record)
	r^ = Record{fields, shape, exact, equation, record_count}
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
	// une forme de longueur quelconque, ou une équation : son vide ne se décide pas
	// encore ici ; on ne l'affirme pas — et ignorer une forme retirée ne fait
	// qu'agrandir le reste
	for r in pos do if has_run(r) || r.equation != nil do return false
	first := pos[0]
	fields := make([]Set, len(first.fields), context.temp_allocator)
	for f, i in first.fields do fields[i] = field_set(f)
	for r in pos[1:] {
		if !same_structure(r, first) do return true
		for &f, i in fields do f = set_intersect(f, field_set(r.fields[i]))
	}
	cover := make([dynamic][]Set, context.temp_allocator)
	for r in neg {
		if has_run(r) || r.equation != nil || !same_structure(r, first) do continue
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
	for f, i in a.fields do if f.name != b.fields[i].name || f.kind != b.fields[i].kind || f.run != b.fields[i].run do return false
	return true
}

has_count :: proc(r: ^Record) -> bool {
	for f in r.fields do if len(f.counts.intervals) > 0 do return true
	return false
}

has_run :: proc(r: ^Record) -> bool {
	for f in r.fields do if f.run do return true
	return false
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
// colorée, ce qu'admet sa couleur ; sinon, sa valeur exactement, lue par ses
// contrats (`{-> u8}` n'admet que la valeur u8). Sans production, c'est une forme.
// Une self-référence admet ce qu'admet son équation : une forme qui y renvoie.
// Faux quand le type dépend d'une inconnue : ce n'est pas un seul ensemble. Un
// scope n'est lu qu'une fois.
color_set :: proc(k: ^Kernel, t: ^Expr) -> (Set, bool) {
	if x, d, recursive := equation_var(t); recursive {
		return Set{sorts = {.Scopes}, scopes = bdd_atom(new_record(nil, d, equation = x.type))}, true
	}
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
		alternatives := make([dynamic]Set, context.temp_allocator)
		for p in shown {
			b := binding_at(p)^
			if b.kind != .Product do continue
			append(&alternatives, admitted_by(k, b) or_return)
		}
		if solved, solvable := arden(s, alternatives[:]); solvable do return solved, true
		for x in alternatives do set = set_union(set, x)
		return set, true
	}
	fields := make([dynamic]Field)
	shape_fields(k, s, &fields, exact = false) or_return
	return Set{sorts = {.Scopes}, scopes = bdd_atom(new_record(fields[:], s))}, true
}

// arden : l'équation de s, X = A·X | B, où chaque production récursive finit par la
// suite X (ou X = X·A | B, où chacune commence par elle), a pour solution
// X = A*·B (ou B·A*) : le lemme d'Arden (specs/kernel-recursion.md §5). A* est une
// suite comptée, `0..*A`. Faux si l'équation n'a pas cette forme : elle reste une
// équation.
arden :: proc(s: ^Scope, alternatives: []Set) -> (Set, bool) {
	Side :: enum u8 {
		None,
		Tail,
		Head,
	}
	side := Side.None
	group, bases: Set
	base_records := make([dynamic]^Record, context.temp_allocator)
	for x in alternatives {
		r, single := lone_record(x)
		at := -1 // la place de la suite X dans la production
		if single do for f, i in r.fields do if f.run && set_equation(f.set) == s {
			if at >= 0 do return {}, false // deux fois X : pas linéaire
			at = i
		}
		if at < 0 {
			bases = set_union(bases, x)
			if single do append(&base_records, r)
			continue
		}
		here := at == len(r.fields) - 1 ? Side.Tail : at == 0 ? Side.Head : Side.None
		if here == .None || (side != .None && side != here) || len(r.fields) < 2 do return {}, false
		side = here
		rest := here == .Tail ? r.fields[:at] : r.fields[1:]
		group = set_union(group, Set{sorts = {.Scopes}, scopes = bdd_atom(new_record(rest, s, exact = true))})
	}
	if side == .None do return {}, false
	repeat := Field{kind = .Expand, set = group, run = true, counts = ints_range(0, nil)}
	solved: Set
	// A*·B : la suite comptée, puis chaque base ; une base qui n'est pas une seule
	// forme se lit comme une suite qu'elle admet
	if len(base_records) == 0 || !set_equal(bases, records_union(base_records[:])) {
		fields := side == .Tail ? []Field{repeat, Field{kind = .Expand, set = bases, run = true}} : []Field{Field{kind = .Expand, set = bases, run = true}, repeat}
		return Set{sorts = {.Scopes}, scopes = bdd_atom(new_record(fields, s, exact = true))}, true
	}
	for r in base_records {
		fields := make([dynamic]Field)
		if side == .Tail do append(&fields, repeat)
		append(&fields, ..r.fields)
		if side == .Head do append(&fields, repeat)
		solved = set_union(solved, Set{sorts = {.Scopes}, scopes = bdd_atom(new_record(fields[:], s, exact = true))})
	}
	return solved, true
}

// lone_record : l'ensemble est une seule forme.
lone_record :: proc(x: Set) -> (^Record, bool) {
	n, is_node := x.scopes.(^Bdd_Node)
	if !is_node || !is_leaf(n.yes, .Top) || !is_leaf(n.maybe, .Bottom) || !is_leaf(n.no, .Bottom) do return nil, false
	if x.sorts != {.Scopes} do return nil, false
	return n.atom, true
}

// records_union : l'union de ces formes.
records_union :: proc(records: []^Record) -> (u: Set) {
	for r in records do u = set_union(u, Set{sorts = {.Scopes}, scopes = bdd_atom(r)})
	return
}

// set_equation : l'ensemble est une self-référence ; le scope dont c'est l'équation.
set_equation :: proc(x: Set) -> ^Scope {
	r, single := lone_record(x)
	if !single || r.equation == nil do return nil
	return r.shape
}

// shape_fields : les places d'une forme, chacune par son contrat — sa couleur,
// écrite ou reçue de la forme qui l'entoure (la coloration implicite). Une
// expansion `...xs` y dépose les places de xs ; une expansion colorée `...C:`, une
// suite — ce qu'elle dépose n'est pas une valeur mais tout scope que C admet. Un
// binding sans contrat admet sa valeur ; nommé, dans une forme (`exact` faux), il
// n'impose rien : un carve peut lui donner toute valeur.
shape_fields :: proc(k: ^Kernel, s: ^Scope, out: ^[dynamic]Field, exact: bool) -> bool {
	for b in s.bindings {
		if b.kind == .Expand {
			if b.color == nil {
				v, ok := expanded(b)
				if !ok do return false // une expansion sans scope typé : on ne sait pas ce qu'elle dépose
				shape_fields(k, v, out, exact) or_return
				continue
			}
			set := color_set(k, b.color_type) or_return
			append(out, Field{kind = .Expand, set = set, run = true})
			continue
		}
		f := Field{name = b.name, kind = b.kind}
		switch {
		case b.color_type != nil:
			f.set = color_set(k, b.color_type) or_return
		case b.name != "" && !exact:
			f.free = true
		case:
			f.set = exact_set(k, b.value_type) or_return
		}
		append(out, f)
	}
	return true
}

// admitted_by : ce qu'un binding admet — ce qu'admet sa couleur, écrite ou
// implicite, sinon sa valeur.
admitted_by :: proc(k: ^Kernel, b: Binding) -> (Set, bool) {
	if b.color_type != nil do return color_set(k, b.color_type)
	return exact_set(k, b.value_type)
}

// exact_set : l'ensemble dont ce type est le seul élément. Un atome est son propre
// singleton ; un ensemble d'au moins deux éléments est une valeur de la sorte des
// ensembles ; un scope, la forme dont chaque binding n'admet que son contrat — sa
// couleur, écrite ou implicite, sinon sa valeur. Faux quand le type dépend d'une
// inconnue.
exact_set :: proc(k: ^Kernel, t: ^Expr) -> (set: Set, ok: bool) {
	if t == nil || is_invalid(t) do return {}, false
	#partial switch v in t^ {
	case Set:
		if is_atom(v) do return v, true
		return Set{sorts = {.Sets}, sets = values_point(v)}, true
	case ^Scope:
		fields := make([dynamic]Field)
		shape_fields(k, v, &fields, exact = true) or_return
		return Set{sorts = {.Scopes}, scopes = bdd_atom(new_record(fields[:], v, exact = true))}, true
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
bdd_admits :: proc(k: ^Kernel, b: Bdd, s: ^Scope, ctx: Context = nil) -> Verdict {
	switch bdd_member(k, b, places(s), ctx) {
	case .Always:
		return .Proved
	case .Not_Always, .Never:
		return .Refuted
	case .Unknown:
	}
	return .Undecided
}

// bdd_member : la suite de bindings `view` — un scope, ou la part d'un scope
// qu'une suite reçoit — est-elle dans l'ensemble `b` ?
bdd_member :: proc(k: ^Kernel, b: Bdd, view: []Place, ctx: Context = nil) -> Member {
	switch v in b {
	case Bdd_Leaf:
		return v == .Top ? .Always : .Never
	case ^Bdd_Node:
		in_atom := record_member(k, v.atom, view, ctx)
		via_yes := and3(in_atom, bdd_member(k, v.yes, view, ctx))
		via_no := and3(not3(in_atom), bdd_member(k, v.no, view, ctx))
		return or3(or3(via_yes, bdd_member(k, v.maybe, view, ctx)), via_no)
	}
	return .Never
}

// record_member : la suite `view` a-t-elle la forme r ? Chaque place de la forme
// prend un binding ; une suite prend une part, de longueur quelconque, que sa
// couleur doit admettre comme scope. On essaie chaque découpage.
//
// Une forme qui se mentionne elle-même peut redemander la même suite (`X -> {...X:}`)
// : une appartenance qui dépend d'elle-même n'est pas établie — c'est la plus
// petite solution, celle des valeurs finies.
record_member :: proc(k: ^Kernel, r: ^Record, view: []Place, ctx: Context = nil) -> Member {
	key := Matching{r, raw_data(view), len(view)}
	if key in k.matching do return .Never
	k.matching[key] = {}
	defer delete_key(&k.matching, key)
	if r.equation != nil {
		// une self-référence : on lit l'équation sur cette suite, rien de plus
		set, closed := color_set(k, new_expr(r.shape))
		return closed ? bdd_member(k, set.scopes, view, ctx) : .Unknown
	}
	memo := make(map[[2]int]Member, context.temp_allocator)
	return match_fields(k, r.fields, view, 0, 0, &memo, ctx)
}

// Matching : une appartenance en cours de décision.
Matching :: struct {
	record: ^Record,
	view:   rawptr,
	len:    int,
}

// match_fields : view[i:] a-t-elle la forme fields[j:] ?
match_fields :: proc(k: ^Kernel, fields: []Field, view: []Place, i, j: int, memo: ^map[[2]int]Member, ctx: Context) -> Member {
	if j == len(fields) do return i == len(view) ? .Always : .Never
	if m, seen := memo[{i, j}]; seen do return m
	f := fields[j]
	result := Member.Never
	if f.run {
		for e in i ..= len(view) {
			result = or3(result, and3(run_member(k, f, view[i:e], ctx), match_fields(k, fields, view, e, j + 1, memo, ctx)))
			if result == .Always do break
		}
	} else if i < len(view) {
		result = and3(field_member(k, f, binding_at(view[i])^, ctx), match_fields(k, fields, view, i + 1, j + 1, memo, ctx))
	}
	memo[{i, j}] = result
	return result
}

// run_member : la suite view est-elle admise par la suite f — un seul morceau, ou
// n morceaux non vides, n parmi ses comptes, chacun admis ?
run_member :: proc(k: ^Kernel, f: Field, view: []Place, ctx: Context) -> Member {
	if len(f.counts.intervals) == 0 do return bdd_member(k, f.set.scopes, view, ctx)
	repeated :: proc(k: ^Kernel, f: Field, view: []Place, n: i128, ctx: Context) -> Member {
		if len(view) == 0 do return ints_contains(f.counts, n) ? .Always : .Never
		result := Member.Never
		for e in 1 ..= len(view) {
			result = or3(result, and3(bdd_member(k, f.set.scopes, view[:e], ctx), repeated(k, f, view[e:], n + 1, ctx)))
			if result == .Always do break
		}
		return result
	}
	return repeated(k, f, view, 0, ctx)
}

// field_member : le binding b a-t-il la place f ?
field_member :: proc(k: ^Kernel, f: Field, b: Binding, ctx: Context) -> Member {
	if f.name != b.name || f.kind != b.kind do return .Never
	if f.free || colored_within(k, b, f.set) do return .Always
	return member_of(admits(k, f.set, b.value_type, ctx), is_closed_type(b.value_type))
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
	case Poly, Term, ^Var, Set_Form, Cases:
		return false
	case ^Scope:
		for p in places(v) do if field := binding_at(p).value_type; field != nil && !is_closed_type(field) do return false
	}
	return true
}

// print_fields : une forme par ses champs — `{0..*0..255:}`, `{u8:  ...C:}`.
print_fields :: proc(fields: []Field) -> string {
	parts := make([dynamic]string, context.temp_allocator)
	for f in fields {
		switch {
		case len(f.counts.intervals) > 0:
			append(&parts, fmt.tprintf("%s*%s", print_ints(f.counts), print_group(f.set)))
		case f.run:
			append(&parts, fmt.tprintf("...%s:", print_set(f.set)))
		case f.free:
			append(&parts, f.name)
		case:
			append(&parts, fmt.tprintf("%s:%s", print_set(f.set), f.name))
		}
	}
	return fmt.tprintf("{{%s}}", strings.join(parts[:], "  "))
}

// print_group : ce qu'une suite comptée répète — un champ seul tel quel, sinon
// entre parenthèses.
print_group :: proc(s: Set) -> string {
	if r, single := lone_record(s); single {
		inner := print_fields(r.fields)
		inner = inner[1:len(inner) - 1]
		return len(r.fields) == 1 ? inner : fmt.tprintf("(%s)", inner)
	}
	return fmt.tprintf("(%s)", print_set(s))
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
		if has_count(v.atom) do atom = print_fields(v.atom.fields) // une solution d'Arden : ses champs
		if v.atom.equation != nil do atom = print_equation(v.atom.equation) // la self-référence, jamais dépliée
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
