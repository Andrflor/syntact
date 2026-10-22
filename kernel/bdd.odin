package kernel

import "core:fmt"
import "core:slice"
import "core:strings"

// SETS OF SCOPES: combinations of shapes.
//
// A shape — a scope without production, `{u8:x  u8:y}` — taken as a set is the set
// of scopes of the same structure whose every binding is admitted by its own.
// `|`, `&` and `~` of shapes are kept in a lazy BDD (Frisch, thesis, ch. 7;
// Elixir 1.19): `{a, yes, maybe, no}` is `(a & yes) | maybe | (~a & no)`. Unions
// stay in `maybe` instead of being distributed: the size stays that of what was
// written. We distribute only when deciding, path by path, then field by field.

// Record: a shape. `shape` is the scope it reads (its default). `exact`: it admits
// only that value scope itself, each binding admitting only its contract.
// `equation`: a self-reference — the shape has no fields, it refers to the
// equation of `shape`, read only at decision time (§3 of
// specs/kernel-recursion.md: we never unfold).
Record :: struct {
	fields:   []Field,
	shape:    ^Scope,
	exact:    bool,
	equation: ^Expr, // the self-reference as written; nil for a shape
	id:       int, // the order of the BDD nodes
}

Field :: struct {
	name:   string,
	kind:   Binding_Kind,
	set:    Set, // what the binding admits; for a run, the scopes it forms
	free:   bool, // a named binding without color imposes nothing
	run:    bool, // `...C:`: a run of bindings, which forms a scope admitted by C
	counts: Ints, // a counted run: n pieces, n among counts, each admitted by set; empty: a single one
}

Bdd_Leaf :: enum u8 {
	Bottom,
	Top,
}

Bdd :: union #no_nil {
	Bdd_Leaf, // the zero value: Bottom, no scope
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

// node: a node, simplified when a branch makes the others useless.
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
		return node(x.atom, x.yes, bdd_or(x.maybe, b), x.no) // the union stays lazy
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

// a ∖ b: we distribute only along the current atom.
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

// bdd_is_empty: each path is an intersection of shapes minus shapes; the BDD is
// empty if each path is.
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

// records_empty: ∩pos ∖ ∪neg = ∅? Two different structures do not meet; without
// a positive shape, it is all scopes minus a few shapes, and some always remain
// (another structure).
records_empty :: proc(pos, neg: []^Record) -> bool {
	if len(pos) == 0 do return false
	// a shape of any length, or an equation: its emptiness is not decided here
	// yet; we do not assert it — and ignoring a removed shape only enlarges the
	// rest
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

// product_covered: F₁ × … × Fₙ ⊆ ∪ cover? We remove one shape N at a time: what
// remains of F outside N is the union, for each field i, of F with Fᵢ ∖ Nᵢ.
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

// field_set: what a binding admits; everything, if it imposes nothing.
field_set :: proc(f: Field) -> Set {
	return set_everything() if f.free else f.set
}

// set_everything: all values, scopes and sets included.
set_everything :: proc() -> Set {
	s := set_top()
	s.sorts += {.Scopes, .Sets}
	s.scopes = .Top
	s.sets = Set_Values{cofinite = true}
	return s
}

// bdd_atoms: the shapes that appear in the BDD.
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

// --- the normal form of a set ---

// normal_set: a type without unknown, taken as a set — the elements it
// designates, in normal form. A set is its own normal form. A scope with
// productions designates what each one admits: a colored production, its color;
// another, its value itself; Arden's lemma solves the equation of a scope that
// mentions itself. Without production, the scopes of its shape. A self-reference
// designates its equation, read only on a value. False when the type depends on
// an unknown. A scope is read only once.
normal_set :: proc(k: ^Kernel, t: ^Expr) -> (Set, bool) {
	if x, d, recursive := equation_var(t); recursive {
		return Set{sorts = {.Scopes}, scopes = bdd_atom(new_record(nil, d, equation = x.type))}, true
	}
	#partial switch v in t^ {
	case Set:
		return v, true
	case ^Scope:
		if s, seen := k.shapes[v]; seen do return s, true
		s, closed := scope_set(k, v)
		if closed do k.shapes[v] = s
		return s, closed
	}
	return {}, false
}

scope_set :: proc(k: ^Kernel, s: ^Scope) -> (set: Set, ok: bool) {
	shown := places(s)
	if first_production(s) != nil {
		alternatives := make([dynamic]Set, context.temp_allocator)
		for p in shown {
			b := binding_at(p)^
			if b.kind != .Product do continue
			alternative: Set
			if b.color_type != nil do alternative = normal_set(k, b.color_type) or_return
			else do alternative = single_set(k, b.value_type) or_return
			append(&alternatives, alternative)
		}
		if solved, solvable := arden(s, alternatives[:]); solvable do return solved, true
		for x in alternatives do set = set_union(set, x)
		return set, true
	}
	fields := make([dynamic]Field)
	record_fields(k, s, &fields, exact = false) or_return
	return Set{sorts = {.Scopes}, scopes = bdd_atom(new_record(fields[:], s))}, true
}

// arden: the equation of s, X = A·X | B, where each recursive production ends with
// the run X (or X = X·A | B, where each one starts with it), has as solution
// X = A*·B (or B·A*): Arden's lemma (specs/kernel-recursion.md §5). A* is a
// counted run, `0..*A`. False if the equation does not have this form: it stays
// an equation.
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
		at := -1 // the place of the run X in the production
		if single do for f, i in r.fields do if f.run && set_equation(f.set) == s {
			if at >= 0 do return {}, false // X twice: not linear
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
	// A*·B: the counted run, then each base; a base that is not a single shape is
	// read as a run it admits
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

// lone_record: the set is a single shape.
lone_record :: proc(x: Set) -> (^Record, bool) {
	n, is_node := x.scopes.(^Bdd_Node)
	if !is_node || !is_leaf(n.yes, .Top) || !is_leaf(n.maybe, .Bottom) || !is_leaf(n.no, .Bottom) do return nil, false
	if x.sorts != {.Scopes} do return nil, false
	return n.atom, true
}

// records_union: the union of these shapes.
records_union :: proc(records: []^Record) -> (u: Set) {
	for r in records do u = set_union(u, Set{sorts = {.Scopes}, scopes = bdd_atom(r)})
	return
}

// set_equation: the set is a self-reference; the scope whose equation it is.
set_equation :: proc(x: Set) -> ^Scope {
	r, single := lone_record(x)
	if !single || r.equation == nil do return nil
	return r.shape
}

// record_fields: the places of a shape, each by the normal form of its contract —
// its color, written or received from the shape that surrounds it (implicit
// coloring). An expansion `...xs` deposits the places of xs there; a colored
// expansion `...C:`, a run — what it deposits is not a value but any scope C
// admits. A binding without contract admits its value; named, in a shape (`exact`
// false), it imposes nothing: a carve can give it any value.
record_fields :: proc(k: ^Kernel, s: ^Scope, out: ^[dynamic]Field, exact: bool) -> bool {
	for b in s.bindings {
		if b.kind == .Expand {
			if b.color == nil {
				v, ok := expanded(b)
				if !ok do return false // an expansion without a typed scope: we do not know what it deposits
				record_fields(k, v, out, exact) or_return
				continue
			}
			set := normal_set(k, b.color_type) or_return
			append(out, Field{kind = .Expand, set = set, run = true})
			continue
		}
		f := Field{name = b.name, kind = b.kind}
		switch {
		case b.color_type != nil:
			f.set = normal_set(k, b.color_type) or_return
		case b.name != "" && !exact:
			f.free = true
		case:
			f.set = single_set(k, b.value_type) or_return
		}
		append(out, f)
	}
	return true
}

// single_set: the set whose only element is the type t, =t. An atom is its own
// singleton; a set of at least two elements is a value of the sort of sets; a
// scope, the shape whose every binding admits only its contract — its color,
// written or implicit, otherwise its value. False when the type depends on an
// unknown.
single_set :: proc(k: ^Kernel, t: ^Expr) -> (set: Set, ok: bool) {
	if t == nil || is_invalid(t) do return {}, false
	#partial switch v in t^ {
	case Set:
		if is_atom(v) do return v, true
		return Set{sorts = {.Sets}, sets = values_point(v)}, true
	case ^Scope:
		fields := make([dynamic]Field)
		record_fields(k, v, &fields, exact = true) or_return
		return Set{sorts = {.Scopes}, scopes = bdd_atom(new_record(fields[:], v, exact = true))}, true
	}
	return {}, false
}

// is_closed_type: a type without unknown — its verdict holds for all their values.
is_closed_type :: proc(t: ^Expr) -> bool {
	#partial switch v in t^ {
	case Poly, Term, ^Var, Set_Form, Cases:
		return false
	case ^Scope:
		for p in places(v) do if field := binding_at(p).value_type; field != nil && !is_closed_type(field) do return false
	}
	return true
}

// print_fields: a shape by its fields — `{0..*0..255:}`, `{u8:  ...C:}`.
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

// print_group: what a counted run repeats — a lone field as is, otherwise in
// parentheses.
print_group :: proc(s: Set) -> string {
	if r, single := lone_record(s); single {
		inner := print_fields(r.fields)
		inner = inner[1:len(inner) - 1]
		return len(r.fields) == 1 ? inner : fmt.tprintf("(%s)", inner)
	}
	return fmt.tprintf("(%s)", print_set(s))
}

// --- printing: `(a & yes) | maybe | (~a & no)`, in Syntact ---

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
		if v.atom.exact do atom = fmt.tprintf("{{-> %s}}", atom) // the scope itself, not its shape
		if has_count(v.atom) do atom = print_fields(v.atom.fields) // an Arden solution: its fields
		if v.atom.equation != nil do atom = print_equation(v.atom.equation) // the self-reference, never unfolded
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
