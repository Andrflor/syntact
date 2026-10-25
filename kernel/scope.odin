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
		}
	}
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
		if is_invalid(target) do return target
		return problem(.Invalid_Property_Access, a.span, fmt.tprintf("`.%s` on %s, which is not a scope", a.name, print_type(target)))
	}
	if b, found := occurrence(placed(k, s, .Value), a.name, a.ordinal, true); found do return binding_type(k, b)
	return problem(.Invalid_Property_Access, a.span, fmt.tprintf("%s has no binding `%s`", print_type(s), a.name))
}

// collapse_law: {… -> p …}! = p, the first production; none without one. A
// recursive call is never unfolded (recursion.odin).
collapse_law :: proc(k: ^Kernel, c: ^Collapse) -> Type {
	target := normal(k, c.target)
	s, ok := target.(^Scope)
	if !ok {
		if is_invalid(target) do return target
		return problem(.Invalid_Execute, c.span, fmt.tprintf("`!` on %s, which is not a scope", print_type(target)))
	}
	// a recursive call, or a carve of a recursive scope: its arguments go into the
	// solution, or it stays
	if c.recursive || s != origin(s) && recursive(s) do return recursive_call(k, s, c.span)
	if p, found := first_production(k, s); found do return binding_type(k, p)
	return None{}
}

// --- carving (§5.3) ---

carve_law :: proc(k: ^Kernel, c: ^Carve) -> Type {
	target := normal(k, c.target)
	args := make([]Carve_Arg, len(c.args))
	for a, i in c.args {
		args[i] = a
		if a.carves != nil do continue // `z{…}`: read against the target (carve)
		args[i].value = normal(k, a.value)
		if is_invalid(args[i].value) do return args[i].value
	}
	s, ok := target.(^Scope)
	if !ok {
		if is_invalid(target) do return target
		return problem(.Invalid_Carve, c.span, fmt.tprintf("%s is not a scope: it cannot be carved", print_type(target)))
	}
	r := carve(k, s, args, c.span)
	// the value of a binding colored by C, carved, is checked against C (§5.4)
	if b := designated(k, c.target); b != nil && !is_invalid(r) {
		if color := binding_color(k, b); color != nil {
			if p := in_problem(k, r, color, c.span); p != nil do return p
		}
	}
	return r
}

// designated: the binding a term designates: a name, or a field of a scope.
designated :: proc(k: ^Kernel, t: Type) -> ^Binding {
	#partial switch v in t {
	case ^Name:
		return v.binding
	case ^Access:
		s, is_scope := normal(k, v.target).(^Scope)
		if !is_scope do return nil
		b, _ := occurrence(placed(k, s, .Value), v.name, v.ordinal, true)
		return b
	}
	return nil
}

// carve: s{x -> w} = s where the first occurrence of x is w. An unnamed argument
// targets, in order, the bindings that are neither productions nor holes.
carve :: proc(k: ^Kernel, s: ^Scope, args: []Carve_Arg, span: syn.Span) -> Type {
	bindings := placed(k, s, .Value)
	changes := make(map[^Binding]Type)
	next := 0
	for arg in args {
		a := arg
		if a.carves != nil {
			// `z{…}`: the binding z of s, carved in turn: z -> s.z{…}; without one, the
			// carve of the name z above, a value given by position
			if field, found := occurrence(bindings, a.name, a.ordinal, false); found {
				inner := new(Carve)
				inner.target, inner.args, inner.span = binding_type(k, field), a.carves, a.span
				a.value = carve_law(k, inner)
			} else if a.otherwise != nil {
				a.name, a.value = "", normal(k, a.otherwise)
			} else {
				return problem(.Invalid_Carve, a.span, fmt.tprintf("%s has no binding `%s` to carve", print_type(s), a.name))
			}
			if is_invalid(a.value) do return a.value
		}
		b: ^Binding
		if a.name != "" {
			found: bool
			b, found = occurrence(bindings, a.name, a.ordinal, false)
			if !found do return problem(.Invalid_Carve, a.span, fmt.tprintf("%s has no binding `%s` to carve", print_type(s), a.name))
		} else {
			for next < len(bindings) && (bindings[next].kind == .Product || bindings[next].kind == .Pull) do next += 1
			if next >= len(bindings) do return problem(.Invalid_Carve, a.span, fmt.tprintf("%s has no binding left to carve", print_type(s)))
			b = bindings[next]
			next += 1
		}
		if b.scope != s do return unsupported_at(k, a.span, "a carve through an expansion")
		changes[b] = a.value
	}
	return derive(k, s, changes, span)
}

// derive: the copy of the scope s carves, uncarved, with the changes of s and
// these. A carve whose changed equations are not proven in their colors has no
// type: its problem is where it is written (§7: a carve is checked where it is
// written, in what it changed; the rest was checked in its source).
derive :: proc(k: ^Kernel, s: ^Scope, changes: map[^Binding]Type, span: syn.Span) -> Type {
	root := s.carved != nil ? s.carved : s
	merged := make(map[^Binding]Type)
	for b, v in s.changes do merged[b] = v
	for b, v in changes do merged[s.carved != nil ? b.source : b] = v
	c := copy_scope(k, root, merged)
	c.carved, c.changes = root, merged
	if p := carve_problem(k, c, span); p != nil do return p
	return c
}

// carve_problem: the first binding of a carve whose equation changed — a replaced
// one, or one that names it — and is not proven in its color; nil when there is
// none.
carve_problem :: proc(k: ^Kernel, c: ^Scope, span: syn.Span) -> Type {
	for b in c.bindings {
		if b.kind == .Product || b.kind == .Expand do continue
		v := binding_type(k, b)
		color := binding_color(k, b)
		if !b.carved && same(k, v, binding_type(k, b.source)) && same(k, color, binding_color(k, b.source)) do continue
		for t in ([2]Type{v, color}) {
			if p, invalid := t.(Invalid); invalid {
				if p.problem == nil do return t
				return problem(p.problem.kind, span, p.problem.message)
			}
		}
		if color == nil do continue
		if p := in_problem(k, v, color, span); p != nil do return p
	}
	return nil
}

// --- copies ---

// Copier: the bindings and scopes of a copy, by those they copy: a name follows
// its binding into the copy. A copy for a branch also substitutes each reference
// from outside by its type, with the unknowns of `outer` rewritten, and each name
// of its cover by the piece of the target it reads.
Copier :: struct {
	instance:   ^Scope, // a carve: the copy its unknowns are read in
	carve:      bool,
	bindings:   map[^Binding]^Binding,
	scopes:     map[^Scope]^Scope,
	substitute: bool,
	outer:      Rewrite,
	pieces:     map[^Binding]Type,
}

copy_scope :: proc(k: ^Kernel, s: ^Scope, changes: map[^Binding]Type) -> ^Scope {
	m := Copier{carve = len(changes) > 0}
	c := copy_into(k, &m, s, s.parent)
	for b in c.bindings {
		if v, carved := changes[b.source]; carved {
			b.value, b.carved = v, true
		}
	}
	return c
}

copy_into :: proc(k: ^Kernel, m: ^Copier, s: ^Scope, parent: ^Scope) -> ^Scope {
	c := new_scope(parent, s.span)
	c.complete = true
	if m.carve && m.instance == nil do m.instance = c
	if !m.substitute do c.source = s // a scope of a branch is checked as written there
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
		// ?ₖ whose layout names what the copy changes: ?ₖ read in the carve
		if !mentions(m, v.written) || m.instance == nil do return v
		u := new(Unknown)
		u^ = v^
		u.written, u.layout, u.instance = copy_term(k, m, v.written, scope), nil, m.instance
		return u
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
		if b, found := m.bindings[v.binding]; found {
			n.binding = b
			return n
		}
		if p, found := m.pieces[v.binding]; found do return rewrite(k, p, m.outer)
		// a reference from outside the copy: its type, with the unknowns rewritten
		if m.substitute do return rewrite(k, binding_type(k, v.binding), m.outer)
		return n
	case ^Scope:
		if c, found := m.scopes[v]; found do return c // the scope being copied, named from inside it (`.x`)
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
			if b.view != nil {
				// the names of the cover follow it into the copy
				view := new_scope(b.view.parent, b.view.span)
				for x in b.view.bindings {
					y, found := m.bindings[x]
					append(&view.bindings, found ? y : x)
				}
				view.complete = true
				b.view = view
			}
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
		return v.binding in m.bindings
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
	for b in s.bindings do if b.kind == .Expand do return s
	colors, aligned := place_colors(k, s.bindings[:], placed(k, shape, .Shape))
	if !aligned do return s
	c := copy_scope(k, s, nil)
	for b, i in c.bindings do if b.color == nil && colors[i] != nil do b.color = colors[i]
	return c
}

// place_colors: the color of the place each binding of xs takes in a shape: a
// binding, its color; a run `...C:`, the places of C — a shape, its own; a
// recursive scope, those of its solution; A * n, those of A, piece by piece. False
// when the places are not decided.
place_colors :: proc(k: ^Kernel, xs, shape: []^Binding) -> (colors: []Type, aligned: bool) {
	colors = make([]Type, len(xs))
	lengths, decided, fits := run_lengths(k, xs, shape)
	if !decided || !fits do return
	at := 0
	for place, i in shape {
		part := xs[at:at + lengths[i]]
		if !is_run(place) {
			colors[at] = place.color
		} else if place.color != nil {
			inner := run_colors(k, part, binding_color(k, place)) or_return
			copy(colors[at:], inner)
		}
		at += lengths[i]
	}
	return colors, true
}

run_colors :: proc(k: ^Kernel, part: []^Binding, c: Type) -> (colors: []Type, aligned: bool) {
	#partial switch v in c {
	case ^Scope:
		s := v
		if recursive(s) do s = arden(k, s) or_return
		if !is_shape(k, s) do return make([]Type, len(part)), true
		return place_colors(k, part, placed(k, s, .Shape))
	case ^Operation:
		// A * n: pieces of the length of A
		a, is_scope := v.args[0].(^Scope)
		if v.op != .Mul || !is_scope do break
		n := shape_length(k, a) or_return
		if n == 0 || len(part) % n != 0 do return
		colors = make([]Type, len(part))
		for i := 0; i < len(part); i += n {
			inner := place_colors(k, part[i:i + n], placed(k, a, .Shape)) or_return
			copy(colors[i:], inner)
		}
		return colors, true
	}
	return make([]Type, len(part)), true
}

// --- a scope as a color (§5.4) ---

// admits: x in s. A scope with productions admits what they produce; a shape, the
// scopes of the same structure whose bindings its colors admit.
admits :: proc(k: ^Kernel, x: Type, s: ^Scope) -> Type {
	if is_invalid(x) do return x
	if recursive(s) {
		solution, solved := arden(k, s)
		if solved && solution != s do return admits(k, x, solution)
		// unsolved, a scope is asked of the productions when they are guarded: each
		// asks it of runs strictly shorter than it (§5.6); otherwise the equation stays
		if _, is_scope := x.(^Scope); !solved && !(is_scope && guarded(k, s)) do return new_operation(.In, x, s)
	}
	shape := placed(k, s, .Shape)
	out: Type = Bool(false)
	produces := false
	for p in shape {
		if p.kind != .Product do continue
		produces = true
		out = bool_or(k, out, produced(k, x, p))
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
// of its place; a run `...C:` takes bindings that C admits taken as a scope. It is
// the law of `in` on a concatenation, as for strings: x in (A + B) is true when x
// is y + z with y in A and z in B — over the ways the bindings of x are split
// between the places, finitely many.
match_shape :: proc(k: ^Kernel, x: Type, s: ^Scope, xs, shape: []^Binding) -> Type {
	if len(shape) == 0 do return Bool(len(xs) == 0)
	place := shape[0]
	if !is_run(place) {
		if len(xs) == 0 do return Bool(false)
		v := xs[0]
		if v.name != place.name || v.kind != place.kind do return Bool(false)
		head: Type = Bool(true)
		if c := binding_color(k, place); c != nil do head = in_law(k, binding_type(k, v), c)
		if is_bool(head, false) do return head
		return bool_and(k, head, match_shape(k, x, s, xs[1:], shape[1:]))
	}
	run_in :: proc(k: ^Kernel, part: []^Binding, place: ^Binding) -> Type {
		if place.color == nil do return Bool(true) // `...` admits any run
		return in_law(k, run_scope(k, part), binding_color(k, place))
	}
	if n, fixed := run_length(k, place); fixed {
		if len(xs) < n do return Bool(false)
		head := run_in(k, xs[:n], place)
		if is_bool(head, false) do return head
		return bool_and(k, head, match_shape(k, x, s, xs[n:], shape[1:]))
	}
	out: Type = Bool(false)
	for i in 0 ..= len(xs) {
		head := run_in(k, xs[:i], place)
		if is_bool(head, false) do continue
		out = bool_or(k, out, bool_and(k, head, match_shape(k, x, s, xs[i:], shape[1:])))
		if is_bool(out, true) do return out
	}
	return out
}

// run_lengths: how many bindings of xs each place of a shape takes: one; a run of
// fixed length, that length; the one run that is not, what the others leave. Not
// decided with two such runs; not fitting when the lengths do not add up.
run_lengths :: proc(k: ^Kernel, xs, shape: []^Binding) -> (lengths: []int, decided, fits: bool) {
	lengths = make([]int, len(shape))
	free := -1
	fixed := 0
	for b, i in shape {
		n, known := 1, true
		if is_run(b) do n, known = run_length(k, b)
		if !known {
			if free >= 0 do return lengths, false, false
			free = i
			continue
		}
		lengths[i] = n
		fixed += n
	}
	if free >= 0 {
		if len(xs) < fixed do return lengths, true, false
		lengths[free] = len(xs) - fixed
		return lengths, true, true
	}
	return lengths, true, len(xs) == fixed
}

// run_length: the number of bindings a run `...C:` takes, when C is a shape of a
// fixed length.
run_length :: proc(k: ^Kernel, b: ^Binding) -> (int, bool) {
	if b.color == nil do return 0, false
	s, ok := binding_color(k, b).(^Scope)
	if !ok do return 0, false
	return shape_length(k, s)
}

// shape_length: the number of bindings of every scope a shape admits, when it is
// fixed: each of its runs takes a fixed number.
shape_length :: proc(k: ^Kernel, s: ^Scope) -> (length: int, fixed: bool) {
	if !is_shape(k, s) do return 0, false
	n := 0
	for p in placed(k, s, .Shape) {
		if !is_run(p) {
			n += 1
			continue
		}
		m := run_length(k, p) or_return
		n += m
	}
	return n, true
}

// run_scope: a run of bindings taken as a scope.
run_scope :: proc(k: ^Kernel, part: []^Binding) -> ^Scope {
	s := new_scope(nil, {})
	append(&s.bindings, ..part)
	s.source, s.complete, s.reached = s, true, true
	return s
}

// --- recursive shapes (§5.6) ---
//
// A scope whose productions name it is an equation in it. When each production is
// a shape that names it only as its last run, X = B | A + X: the bases B, the
// prefixes A. Arden solves it, as for strings (§5.6): X = A * 0.. + B, the shape
// of a run of zero or more A, then a B. Otherwise the equation stays.

arden :: proc(k: ^Kernel, s: ^Scope) -> (^Scope, bool) {
	prefixes := make([dynamic]Type)
	bases := make([dynamic]Type)
	for p in placed(k, s, .Shape) {
		if p.kind != .Product do continue
		if p.value == nil do return nil, false // `-> C:`: not a shape
		shape, is_scope := binding_type(k, p).(^Scope)
		if !is_scope || !is_shape(k, shape) do return nil, false
		places := placed(k, shape, .Shape)
		n := len(places)
		if n > 0 && is_run(places[n - 1]) && places[n - 1].color != nil && same(k, binding_color(k, places[n - 1]), s) {
			for b in places[:n - 1] do if binding_mentions(k, b, s) do return nil, false
			append(&prefixes, run_scope(k, places[:n - 1]))
			continue
		}
		for b in places do if binding_mentions(k, b, s) do return nil, false
		append(&bases, shape)
	}
	if len(prefixes) == 0 do return s, true // it names itself elsewhere than in a shape
	solution := new_scope(nil, s.span)
	solution.source, solution.complete, solution.reached = s, true, true
	run := new_binding(solution, .Expand, s.span)
	run.color = new_operation(.Mul, or_law(k, prefixes[:]), new_range(Int(0), nil, .Int))
	run.typed_color = run.color
	last := new_binding(solution, .Expand, s.span)
	last.color = or_law(k, bases[:])
	last.typed_color = last.color
	return solution, true
}

// guarded: in each production of s, a run that names s comes with a binding: a
// scope in s is asked of runs strictly shorter than it (§5.6).
guarded :: proc(k: ^Kernel, s: ^Scope) -> bool {
	for p in placed(k, s, .Shape) {
		if p.kind != .Product || p.value == nil do continue
		shape, is_scope := binding_type(k, p).(^Scope)
		if !is_scope do continue
		names, fixed := false, false
		for b in placed(k, shape, .Shape) {
			if !is_run(b) do fixed = true
			else if binding_mentions(k, b, s) do names = true
		}
		if names && !fixed do return false
	}
	return true
}

// binding_mentions: the color or the value of a binding holds the scope s.
binding_mentions :: proc(k: ^Kernel, b: ^Binding, s: ^Scope) -> bool {
	seen := make(map[^Scope]bool)
	if b.color != nil && mentions_scope(k, binding_color(k, b), s, &seen) do return true
	return b.value != nil && b.kind != .Product && mentions_scope(k, binding_type(k, b), s, &seen)
}

mentions_scope :: proc(k: ^Kernel, t: Type, s: ^Scope, seen: ^map[^Scope]bool) -> bool {
	#partial switch v in t {
	case ^Scope:
		if same(k, v, s) do return true
		if v in seen do return false
		seen[v] = true
		for b in placed(k, v, .Shape) {
			if b.color != nil && mentions_scope(k, binding_color(k, b), s, seen) do return true
		}
	case ^Collapse:
		if x, ok := v.target.(^Scope); ok do return origin(x) == origin(s)
	case ^Operation:
		for a in v.args do if mentions_scope(k, a, s, seen) do return true
	case ^Or:
		for a in v.terms do if mentions_scope(k, a, s, seen) do return true
	case ^And:
		for a in v.terms do if mentions_scope(k, a, s, seen) do return true
	case ^Not:
		return mentions_scope(k, v.term, s, seen)
	case ^Is:
		return mentions_scope(k, v.term, s, seen)
	case ^Pattern:
		for b in v.branches do if mentions_scope(k, b.product, s, seen) do return true
	}
	return false
}

// repeated_in: x in A * n, A a set of shapes: x is y + z, y a piece in A and z
// in A * (n - 1), over the lengths A admits — the law of `in` on a concatenation
// (§4.6, §5.6). A piece takes a binding at least; when A admits {}, empty pieces
// make up any count that n allows.
repeated_in :: proc(k: ^Kernel, x: Type, a: Type, counts: Type) -> Type {
	stays := new_operation(.In, x, new_operation(.Mul, a, counts))
	v, is_scope := x.(^Scope)
	if !is_scope do return is_constant(x) ? Type(Bool(false)) : stays
	alternatives, negated := as_cells(a)
	if negated do return stays
	lengths := make([dynamic]int) // the lengths of the pieces, when each is fixed
	any_length := false
	for c in alternatives {
		shape, ok := c.(^Scope)
		if !ok do return stays
		n, fixed := shape_length(k, shape)
		if !fixed do any_length = true
		else if !slice.contains(lengths[:], n) do append(&lengths, n)
	}
	empty := in_law(k, run_scope(k, nil), a)
	if !is_bool(empty, true) && !is_bool(empty, false) do return stays
	return pieces_in(k, placed(k, v, .Value), a, counts, 0, lengths[:], any_length, is_bool(empty, true))
}

// pieces_in: the bindings xs are pieces in a, after `used` of them.
pieces_in :: proc(k: ^Kernel, xs: []^Binding, a, counts: Type, used: i128, lengths: []int, any_length, empty: bool) -> Type {
	if len(xs) == 0 {
		if empty do return Bool(!is_none(counts_from(counts, used)))
		return Bool(counts_hold(counts, used))
	}
	if is_none(counts_from(counts, used + 1)) do return Bool(false)
	out: Type = Bool(false)
	for i in 1 ..= len(xs) {
		if !any_length && !slice.contains(lengths, i) do continue
		head := in_law(k, run_scope(k, xs[:i]), a)
		if is_bool(head, false) do continue
		out = bool_or(k, out, bool_and(k, head, pieces_in(k, xs[i:], a, counts, used + 1, lengths, any_length, empty)))
		if is_bool(out, true) do return out
	}
	return out
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
		return ok && same_unknown(x, y) // the same unknown, whatever layout a branch gives it
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
		return ok && x.binding == y.binding
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
	// two carves of one scope: s{x -> v} = s{x -> w} when v = w; s{x -> s.x} = s
	if root := origin(a); root == origin(b) {
		for x in root.bindings {
			v, in_a := a.changes[x]
			w, in_b := b.changes[x]
			if !in_a && !in_b do continue
			if !in_a do v = binding_type(k, x)
			if !in_b do w = binding_type(k, x)
			if !same(k, v, w) do return false
		}
		return true
	}
	return same_bindings(k, a, b, true)
}

// same_bindings: the bindings of two scopes are, in order, the same names, kinds
// and values (§5.3) — as terms, the same colors too: `{u8:}` and `{i8:}` give the
// same value, not the same set.
same_bindings :: proc(k: ^Kernel, a, b: ^Scope, colors: bool) -> bool {
	xs := placed(k, a, .Value)
	ys := placed(k, b, .Value)
	if len(xs) != len(ys) do return false
	for x, i in xs {
		y := ys[i]
		if x.name != y.name || x.kind != y.kind do return false
		if colors && !same(k, binding_color(k, x), binding_color(k, y)) do return false
		if !same(k, binding_type(k, x), binding_type(k, y)) do return false
	}
	return true
}
