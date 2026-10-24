package kernel

import syn "../compiler"
import "core:fmt"
import "core:slice"
import "core:strings"

// SCOPES (specs/types.md §5)
//
// A scope is a new type: an ordered sequence of bindings, each an equation. Its
// operations are laws: an access is the last occurrence's value, a collapse the
// first production's, an expansion places bindings as they are, a carve is the
// same scope with one equation replaced — a copy where the names follow. A scope
// as a color admits what its productions give, or what its shape admits.

// scope_law: a scope literal is itself; reached, it is checked (check.odin).
scope_law :: proc(k: ^Kernel, s: ^Scope) -> Type {
	if !s.reached {
		s.reached = true
		if s.source == nil do append(&k.pending, s)
	}
	return s
}

// placed: the bindings of s with its expansions placed (§5.3): `...e` places the
// bindings of e as they are; `...C:` places the default of C in a value, and stays
// a run in a shape; `...` places nothing in a value.
placed :: proc(k: ^Kernel, s: ^Scope, view: View) -> []^Binding {
	if view in s.placed_by do return s.placed[view]
	if s.placing[view] {
		report(k, .Infinite_Recursion, s.span, "this scope places itself again")
		return nil
	}
	s.placing[view] = true
	out := make([dynamic]^Binding)
	for b in s.bindings {
		if b.kind != .Expand || (view == .Shape && b.value == nil) {
			append(&out, b)
			continue
		}
		if b.value == nil && b.color == nil do continue
		v := binding_type(k, b)
		#partial switch x in v {
		case ^Scope:
			append(&out, ..placed(k, x, view))
		case Invalid:
		case:
			report(k, .Constraint_Mismatch, b.span, fmt.tprintf("only a scope can be expanded, not %s", print_type(v)))
		}
	}
	s.placing[view] = false
	s.placed[view] = out[:]
	s.placed_by += {view}
	return out[:]
}

is_run :: proc(b: ^Binding) -> bool {
	return b.kind == .Expand && b.value == nil
}

first_production :: proc(k: ^Kernel, s: ^Scope) -> (^Binding, bool) {
	for b in placed(k, s, .Value) do if b.kind == .Product do return b, true
	return nil, false
}

// is_shape: a scope without production (§5.4).
is_shape :: proc(k: ^Kernel, s: ^Scope) -> bool {
	for b in placed(k, s, .Shape) do if b.kind == .Product do return false
	return true
}

// occurrence: the binding named `name`: its n-th occurrence, or by default its
// last (or first) one.
occurrence :: proc(bindings: []^Binding, name: string, ordinal: int, last: bool) -> (^Binding, bool) {
	if ordinal >= 0 {
		seen := 0
		for b in bindings {
			if b.name != name do continue
			if seen == ordinal do return b, true
			seen += 1
		}
		return nil, false
	}
	if last {
		#reverse for b in bindings do if b.name == name do return b, true
	} else {
		for b in bindings do if b.name == name do return b, true
	}
	return nil, false
}

// access_law: {… x -> v …}.x = v, the last occurrence; x#n, the n-th.
access_law :: proc(k: ^Kernel, target: Type, a: ^Access) -> Type {
	s, ok := target.(^Scope)
	if !ok {
		if is_invalid(target) do return Invalid{}
		return report(k, .Invalid_Property_Access, a.span, fmt.tprintf("`.%s` on %s, which is not a scope", a.name, print_type(target)))
	}
	if b, found := occurrence(placed(k, s, .Value), a.name, a.ordinal, true); found do return binding_type(k, b)
	return report(k, .Invalid_Property_Access, a.span, fmt.tprintf("%s has no binding `%s`", print_type(s), a.name))
}

// collapse_law: {… -> p …}! = p, the first production; none without one. Asked
// while a production of the same scope is given, it is a recursive call, never
// unfolded (recursion.odin).
collapse_law :: proc(k: ^Kernel, c: ^Collapse) -> Type {
	target := normal(k, c.target)
	s, ok := target.(^Scope)
	if !ok {
		if is_invalid(target) do return Invalid{}
		return report(k, .Invalid_Execute, c.span, fmt.tprintf("`!` on %s, which is not a scope", print_type(target)))
	}
	root := origin(s)
	if c.recursive || k.giving[root] > 0 do return recursive_call(k, s, c.span)
	if s != root {
		// a carve of a recursive scope: its arguments go into the solution, or it stays
		if p, found := first_production(k, root); found do binding_type(k, p)
		if root.recursive do return recursive_call(k, s, c.span)
	}
	if p, found := first_production(k, s); found do return binding_type(k, p)
	return None{}
}

// --- carving (§5.3) ---

carve_law :: proc(k: ^Kernel, c: ^Carve) -> Type {
	target := normal(k, c.target)
	args := make([]Carve_Arg, len(c.args))
	for a, i in c.args {
		args[i] = a
		args[i].value = normal(k, a.value)
		if is_invalid(args[i].value) do return Invalid{}
	}
	s, ok := target.(^Scope)
	if !ok {
		if is_invalid(target) do return Invalid{}
		return report(k, .Invalid_Carve, c.span, fmt.tprintf("%s is not a scope: it cannot be carved", print_type(target)))
	}
	return carve(k, s, args, c.span)
}

// carve: s{x -> w} = s where the first occurrence of x is w. An unnamed argument
// targets, in order, the bindings that are neither productions nor holes.
carve :: proc(k: ^Kernel, s: ^Scope, args: []Carve_Arg, span: syn.Span) -> Type {
	bindings := placed(k, s, .Value)
	changes := make(map[^Binding]Type)
	next := 0
	for a in args {
		b: ^Binding
		if a.name != "" {
			found: bool
			b, found = occurrence(bindings, a.name, a.ordinal, false)
			if !found do return report(k, .Invalid_Carve, a.span, fmt.tprintf("%s has no binding `%s` to carve", print_type(s), a.name))
		} else {
			for next < len(bindings) && (bindings[next].kind == .Product || bindings[next].kind == .Pull) do next += 1
			if next >= len(bindings) do return report(k, .Invalid_Carve, a.span, fmt.tprintf("%s has no binding left to carve", print_type(s)))
			b = bindings[next]
			next += 1
		}
		if b.scope != s do return unsupported_at(k, a.span, "a carve through an expansion")
		changes[b] = a.value
	}
	return derive(k, s, changes, span)
}

// derive: the copy of the scope s carves, uncarved, with the changes of s and
// these. The same carve under the same layouts is the same copy. It is checked
// where it is written, in what it changed: the rest was checked in its source.
derive :: proc(k: ^Kernel, s: ^Scope, changes: map[^Binding]Type, span: syn.Span) -> ^Scope {
	root := s.carved != nil ? s.carved : s
	merged := make(map[^Binding]Type)
	for b, v in s.changes do merged[b] = v
	for b, v in changes do merged[s.carved != nil ? b.source : b] = v
	facts := merge_facts(k, scope_facts(root.parent), k.facts)
	key := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&key, "%p", root)
	for b in root.bindings do if v, carved := merged[b]; carved do fmt.sbprintf(&key, "|%p:%s", b, key_of(v))
	fmt.sbprintf(&key, "|%s", facts_key(facts))
	if c, found := k.copies[strings.to_string(key)]; found do return c
	c := copy_scope(k, root, merged, facts)
	c.carved, c.changes = root, merged
	k.copies[strings.clone(strings.to_string(key))] = c
	check_carve(k, c, span)
	return c
}

// check_carve: the bindings of a carve whose equation changed — the replaced ones,
// and those that name them — are typed and checked, with their errors at the carve.
check_carve :: proc(k: ^Kernel, c: ^Scope, span: syn.Span) {
	saved_site, saved_facts := k.site, k.facts
	if k.site == {} do k.site = span
	k.facts = scope_facts(c)
	for b in c.bindings {
		if b.kind == .Product || b.kind == .Expand do continue
		v := binding_type(k, b)
		color := binding_color(k, b)
		if color == nil do continue
		if !b.carved && same(k, v, binding_type(k, b.source)) && same(k, color, binding_color(k, b.source)) do continue
		check_in(k, v, color, b.span)
	}
	k.site, k.facts = saved_site, saved_facts
}

merge_facts :: proc(k: ^Kernel, a, b: Facts) -> Facts {
	if a == nil do return b
	if b == nil do return a
	out := make(Facts)
	for u, l in a do out[u] = l
	for u, l in b do out[u] = u in out ? and_law(k, {out[u], l}) : l
	return out
}

facts_key :: proc(facts: Facts) -> string {
	parts := make([dynamic]string)
	for u, l in facts do append(&parts, fmt.tprintf("%d:%s", u.id, key_of(l)))
	slice.sort(parts[:])
	return strings.join(parts[:], ",")
}

// --- copies ---

// Copier: the bindings and scopes of a copy, by those they copy: a name follows
// its binding into the copy.
Copier :: struct {
	bindings: map[^Binding]^Binding,
	scopes:   map[^Scope]^Scope,
}

copy_scope :: proc(k: ^Kernel, s: ^Scope, changes: map[^Binding]Type, facts: Facts) -> ^Scope {
	m := Copier{}
	c := copy_into(k, &m, s, s.parent)
	c.facts = facts
	for b in c.bindings {
		if v, carved := changes[b.source]; carved {
			b.value, b.carved = v, true
		}
	}
	return c
}

copy_into :: proc(k: ^Kernel, m: ^Copier, s: ^Scope, parent: ^Scope) -> ^Scope {
	c := new_scope(parent, s.span)
	c.source, c.complete = s, true
	m.scopes[s] = c
	for b in s.bindings {
		n := new(Binding)
		n^ = Binding {
			name   = b.name,
			kind   = b.kind,
			span   = b.span,
			scope  = c,
			source = b,
		}
		m.bindings[b] = n
		append(&c.bindings, n)
	}
	for b, i in s.bindings {
		n := c.bindings[i]
		n.color = copy_term(k, m, b.color, c)
		if u, is_unknown := b.value.(^Unknown); is_unknown && u.written == nil {
			// `??` takes the layout of its color: a color that follows the copy makes another unknown
			n.value = mentions(m, b.color) ? Type(new_unknown(k, nil)) : Type(u)
			continue
		}
		n.value = copy_term(k, m, b.value, c)
	}
	return c
}

copy_term :: proc(k: ^Kernel, m: ^Copier, t: Type, scope: ^Scope) -> Type {
	if t == nil do return nil
	switch v in t {
	case Char, Int, Real, Bool, None, Invalid:
		return t
	case ^Unknown:
		if !mentions(m, v.written) do return v
		return new_unknown(k, copy_term(k, m, v.written, scope))
	case ^Or:
		return new_or(..copy_terms(k, m, v.terms, scope))
	case ^And:
		return new_and(..copy_terms(k, m, v.terms, scope))
	case ^Not:
		return new_not(copy_term(k, m, v.term, scope))
	case ^Is:
		return new_is(copy_term(k, m, v.term, scope))
	case ^Range:
		return new_range(copy_term(k, m, v.lo, scope), copy_term(k, m, v.hi, scope), v.family, v.span)
	case ^Operation:
		return written(new_operation(v.op, ..copy_terms(k, m, v.args, scope)), v.span)
	case ^Name:
		n := new(Name)
		n^ = v^
		if b, found := m.bindings[v.binding]; found do n.binding = b
		if s, found := m.scopes[v.self]; found && v.self != nil do n.self = s
		return n
	case ^Scope:
		parent := scope
		if p, found := m.scopes[v.parent]; found do parent = p
		return copy_into(k, m, v, parent)
	case ^Access:
		a := new(Access)
		a^ = v^
		a.target = copy_term(k, m, v.target, scope)
		return a
	case ^Collapse:
		c := new(Collapse)
		c^ = v^
		c.target = copy_term(k, m, v.target, scope)
		return c
	case ^Carve:
		c := new(Carve)
		c^ = v^
		c.target = copy_term(k, m, v.target, scope)
		c.args = slice.clone(v.args)
		for &a in c.args do a.value = copy_term(k, m, a.value, scope)
		return c
	case ^Default:
		d := new(Default)
		d^ = v^
		d.color = copy_term(k, m, v.color, scope)
		return d
	case ^Pattern:
		p := new(Pattern)
		p^ = v^
		p.target = copy_term(k, m, v.target, scope)
		p.branches = slice.clone(v.branches)
		for &b in p.branches {
			b.cover = copy_term(k, m, b.cover, scope)
			if b.scope != nil {
				parent := scope
				if x, found := m.scopes[b.scope.parent]; found do parent = x
				b.scope = copy_into(k, m, b.scope, parent)
			}
			b.product = copy_term(k, m, b.product, b.scope != nil ? b.scope : scope)
		}
		return p
	}
	return t
}

copy_terms :: proc(k: ^Kernel, m: ^Copier, ts: []Type, scope: ^Scope) -> []Type {
	out := make([]Type, len(ts))
	for t, i in ts do out[i] = copy_term(k, m, t, scope)
	return out
}

// mentions: t names a binding or a scope the copy follows.
mentions :: proc(m: ^Copier, t: Type) -> bool {
	if t == nil do return false
	switch v in t {
	case Char, Int, Real, Bool, None, Invalid:
	case ^Unknown:
		return mentions(m, v.written)
	case ^Or:
		for x in v.terms do if mentions(m, x) do return true
	case ^And:
		for x in v.terms do if mentions(m, x) do return true
	case ^Not:
		return mentions(m, v.term)
	case ^Is:
		return mentions(m, v.term)
	case ^Range:
		return mentions(m, v.lo) || mentions(m, v.hi)
	case ^Operation:
		for x in v.args do if mentions(m, x) do return true
	case ^Name:
		return v.binding in m.bindings || v.self != nil && v.self in m.scopes
	case ^Scope:
		for b in v.bindings do if mentions(m, b.color) || mentions(m, b.value) do return true
	case ^Access:
		return mentions(m, v.target)
	case ^Collapse:
		return mentions(m, v.target)
	case ^Carve:
		if mentions(m, v.target) do return true
		for a in v.args do if mentions(m, a.value) do return true
	case ^Default:
		return mentions(m, v.color)
	case ^Pattern:
		if mentions(m, v.target) do return true
		for b in v.branches do if mentions(m, b.cover) || mentions(m, b.product) do return true
	}
	return false
}

// colored: the color of a binding flows down into its value (§5.4): in the value
// of a binding colored by a shape, a binding without a color has the color of its
// place in the shape.
colored :: proc(k: ^Kernel, s: ^Scope, shape: ^Scope) -> Type {
	key := fmt.tprintf("color %p %p", s, shape)
	if c, found := k.copies[key]; found do return c
	places := placed(k, shape, .Shape)
	if len(places) != len(s.bindings) do return s
	for b, i in s.bindings do if b.kind == .Expand || is_run(places[i]) do return s
	c := copy_scope(k, s, nil, nil)
	for b, i in c.bindings do if b.color == nil && places[i].color != nil do b.color = places[i].color
	k.copies[strings.clone(key)] = c
	return c
}

// --- a scope as a color (§5.4) ---

// admits: x in s. A scope with productions admits what they produce; a shape, the
// scopes of the same structure whose bindings its colors admit.
admits :: proc(k: ^Kernel, x: Type, s: ^Scope) -> Type {
	if is_invalid(x) do return Invalid{}
	key := fmt.tprintf("%s in %p", key_of(x), s)
	if key in k.admitting do return new_operation(.In, x, s) // asked again inside itself: not decided here
	k.admitting[strings.clone(key)] = true
	defer delete_key(&k.admitting, key)
	shape := placed(k, s, .Shape)
	out: Type = Bool(false)
	produces := false
	for p in shape {
		if p.kind != .Product do continue
		produces = true
		out = bool_or(out, produced(k, x, p))
	}
	if produces do return out
	v, is_scope := x.(^Scope)
	if !is_scope do return is_constant(x) ? Type(Bool(false)) : new_operation(.In, x, s)
	return match_shape(k, x, s, placed(k, v, .Value), shape)
}

// produced: x in what a production gives: `-> C:` produces what C admits; a
// produced shape admits through its colors; another produced value, only itself.
produced :: proc(k: ^Kernel, x: Type, p: ^Binding) -> Type {
	if p.value == nil && p.color != nil do return in_law(k, x, binding_color(k, p))
	v := binding_type(k, p)
	if s, ok := v.(^Scope); ok && is_shape(k, s) do return admits(k, x, s)
	return equal_law(k, x, v)
}

// match_shape: the same names, kinds and order, each binding admitted by the color
// of its place; a run `...C:` takes the bindings that C admits taken as a scope.
// A run has the length of its shape, or takes what the others leave: one such run
// at most is decided.
match_shape :: proc(k: ^Kernel, x: Type, s: ^Scope, xs, shape: []^Binding) -> Type {
	lengths := make([]int, len(shape))
	free := -1
	fixed := 0
	for b, i in shape {
		n, known := 1, true
		if is_run(b) do n, known = run_length(k, b)
		if !known {
			if free >= 0 do return new_operation(.In, x, s)
			free = i
			continue
		}
		lengths[i] = n
		fixed += n
	}
	if free >= 0 {
		if len(xs) < fixed do return Bool(false)
		lengths[free] = len(xs) - fixed
	} else if len(xs) != fixed {
		return Bool(false)
	}
	out: Type = Bool(true)
	at := 0
	for b, i in shape {
		part := xs[at:at + lengths[i]]
		at += lengths[i]
		if !is_run(b) {
			v := part[0]
			if v.name != b.name || v.kind != b.kind do return Bool(false)
			if c := binding_color(k, b); c != nil do out = bool_and(out, in_law(k, binding_type(k, v), c))
			continue
		}
		if b.color == nil do continue // `...` admits any run
		out = bool_and(out, in_law(k, run_scope(k, part), binding_color(k, b)))
	}
	return out
}

// run_length: the number of bindings a run `...C:` takes when C is a shape without
// run; false otherwise.
run_length :: proc(k: ^Kernel, b: ^Binding) -> (int, bool) {
	if b.color == nil do return 0, false
	s, ok := binding_color(k, b).(^Scope)
	if !ok || !is_shape(k, s) do return 0, false
	places := placed(k, s, .Shape)
	for p in places do if is_run(p) do return 0, false
	return len(places), true
}

// run_scope: a run of bindings taken as a scope; the same run is the same scope.
run_scope :: proc(k: ^Kernel, part: []^Binding) -> ^Scope {
	key := strings.builder_make(context.temp_allocator)
	strings.write_string(&key, "run")
	for b in part do fmt.sbprintf(&key, " %p", b)
	if s, found := k.copies[strings.to_string(key)]; found do return s
	s := new_scope(nil, {})
	append(&s.bindings, ..part)
	s.source, s.complete, s.reached = s, true, true
	k.copies[strings.clone(strings.to_string(key))] = s
	return s
}

// different_structures: two shapes without run whose names, kinds or order
// differ: they admit nothing in common (§5.4).
different_structures :: proc(k: ^Kernel, a, b: Type) -> bool {
	x, is_x := a.(^Scope)
	y, is_y := b.(^Scope)
	if !is_x || !is_y || !is_shape(k, x) || !is_shape(k, y) do return false
	xs := placed(k, x, .Shape)
	ys := placed(k, y, .Shape)
	for p in xs do if is_run(p) do return false
	for p in ys do if is_run(p) do return false
	if len(xs) != len(ys) do return true
	for p, i in xs do if p.name != ys[i].name || p.kind != ys[i].kind do return true
	return false
}

// --- equality ---

// same: two normal forms are the same term. Two scopes are equal when their
// bindings are, in order: the same names, the same kinds, equal values (§5.3).
same :: proc(k: ^Kernel, a, b: Type) -> bool {
	if a == nil || b == nil do return a == nil && b == nil
	switch x in a {
	case Char:
		y, ok := b.(Char)
		return ok && x == y
	case Int:
		y, ok := b.(Int)
		return ok && x == y
	case Real:
		y, ok := b.(Real)
		return ok && x == y
	case Bool:
		y, ok := b.(Bool)
		return ok && x == y
	case None:
		_, ok := b.(None)
		return ok
	case Invalid:
		_, ok := b.(Invalid)
		return ok
	case ^Unknown:
		y, ok := b.(^Unknown)
		return ok && x == y
	case ^Or:
		y, ok := b.(^Or)
		return ok && same_all(k, x.terms, y.terms)
	case ^And:
		y, ok := b.(^And)
		return ok && same_all(k, x.terms, y.terms)
	case ^Not:
		y, ok := b.(^Not)
		return ok && same(k, x.term, y.term)
	case ^Is:
		y, ok := b.(^Is)
		return ok && same(k, x.term, y.term)
	case ^Range:
		y, ok := b.(^Range)
		return ok && x.family == y.family && same(k, x.lo, y.lo) && same(k, x.hi, y.hi)
	case ^Operation:
		y, ok := b.(^Operation)
		return ok && x.op == y.op && same_all(k, x.args, y.args)
	case ^Name:
		y, ok := b.(^Name)
		return ok && x.binding == y.binding && x.self == y.self
	case ^Scope:
		y, ok := b.(^Scope)
		return ok && same_scope(k, x, y)
	case ^Access:
		y, ok := b.(^Access)
		return ok && x.name == y.name && x.ordinal == y.ordinal && same(k, x.target, y.target)
	case ^Collapse:
		y, ok := b.(^Collapse)
		return ok && x.recursive == y.recursive && same(k, x.target, y.target)
	case ^Carve:
		y, ok := b.(^Carve)
		if !ok || len(x.args) != len(y.args) || !same(k, x.target, y.target) do return false
		for a, i in x.args do if a.name != y.args[i].name || a.ordinal != y.args[i].ordinal || !same(k, a.value, y.args[i].value) do return false
		return true
	case ^Default:
		y, ok := b.(^Default)
		return ok && same(k, x.color, y.color)
	case ^Pattern:
		y, ok := b.(^Pattern)
		if !ok || len(x.branches) != len(y.branches) || !same(k, x.target, y.target) do return false
		for br, i in x.branches do if !same(k, br.cover, y.branches[i].cover) || !same(k, br.product, y.branches[i].product) do return false
		return true
	}
	return false
}

same_all :: proc(k: ^Kernel, a, b: []Type) -> bool {
	if len(a) != len(b) do return false
	for x, i in a do if !same(k, x, b[i]) do return false
	return true
}

same_scope :: proc(k: ^Kernel, a, b: ^Scope) -> bool {
	if a == b do return true
	pair := [2]^Scope{a, b}
	if pair in k.comparing do return true // compared inside itself: equal as far as the rest says
	k.comparing[pair] = true
	defer delete_key(&k.comparing, pair)
	xs := placed(k, a, .Value)
	ys := placed(k, b, .Value)
	if len(xs) != len(ys) do return false
	for x, i in xs {
		y := ys[i]
		if x.name != y.name || x.kind != y.kind do return false
		if !same(k, binding_type(k, x), binding_type(k, y)) do return false
	}
	return true
}
