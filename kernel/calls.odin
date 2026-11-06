package kernel

import syn "../syntax"
import "core:slice"

// RECURSIVE CALLS (specs/types.md §5.6)
//
// A scope names itself only in its productions. Asked again from its own production,
// it stays a carve and a collapse — a recursive call — and is never unfolded. A call
// of a production that is solved, one that calls nothing, substitutes its values into
// it; otherwise the call stays, and the program computes it.

// recursive: the productions of a scope name it — the binding whose value it is —
// directly or in a carve (§5.6); a carve of it is recursive with it.
recursive :: proc(s: ^Scope) -> bool {
	root := origin(s)
	seen := make(map[^Scope]bool)
	for b in root.bindings do if b.kind == .Product && (names_scope(b.color, root, &seen) || names_scope(b.value, root, &seen)) do return true
	return false
}

// names_scope: the term, as written, names the binding whose value is s. A scope
// is read once: `.x` names the scope it is written in.
names_scope :: proc(t: Type, s: ^Scope, seen: ^map[^Scope]bool) -> bool {
	if t == nil do return false
	switch v in t {
	case ^Name:
		value, ok := v.binding.value.(^Scope)
		return ok && value == s
	case ^Scope:
		if v in seen do return false
		seen[v] = true
		for b in v.bindings do if names_scope(b.color, s, seen) || names_scope(b.value, s, seen) do return true
	case ^Operation:
		for a in v.args do if names_scope(a, s, seen) do return true
	case ^Or:
		for a in v.terms do if names_scope(a, s, seen) do return true
	case ^And:
		for a in v.terms do if names_scope(a, s, seen) do return true
	case ^Effect:
		return v.choice != nil && names_scope(v.choice, s, seen) || names_scope(v.then, s, seen)
	case ^Not:
		return names_scope(v.term, s, seen)
	case ^Is:
		return names_scope(v.term, s, seen)
	case ^Range:
		return names_scope(v.lo, s, seen) || names_scope(v.hi, s, seen)
	case ^Access:
		return names_scope(v.target, s, seen)
	case ^Collapse:
		return names_scope(v.target, s, seen)
	case ^Carve:
		if target, is_scope := v.target.(^Scope); is_scope && target == s do return true // a carve of s itself
		if names_scope(v.target, s, seen) do return true
		for a in v.args do if names_scope(a.value, s, seen) || names_scope(a.otherwise, s, seen) do return true
	case ^Default:
		return names_scope(v.color, s, seen)
	case ^Pattern:
		if names_scope(v.target, s, seen) do return true
		for b in v.branches do if names_scope(b.cover, s, seen) || names_scope(b.product, s, seen) do return true
	case ^Fold:
		for t in fold_parts(v) do if names_scope(t, s, seen) do return true
	case ^Least:
		return names_scope(v.holds, s, seen)
	case ^Series:
		return names_scope(v.lo, s, seen) || names_scope(v.hi, s, seen) || names_scope(v.term, s, seen)
	case ^Recurrent:
		for t in v.initial do if names_scope(t, s, seen) do return true
		return names_scope(v.at, s, seen)
	case Char, Int, Real, Bool, None, Invalid, ^Unknown:
	}
	return false
}

// generalized: the carve whose first production is the equation a call s reads
// (§5.6): its production where what s carves is ?? — unknowns of their colors —, and
// what its calls carve too (widened). With through, a field s gives a call of another
// equation keeps it, over the fields of that equation, each ??: the recursion follows
// what the other builds. A shared node: its production is typed once.
generalized :: proc(k: ^Kernel, s: ^Scope, through := true) -> ^Scope {
	root := origin(s)
	changes := make(map[^Binding]Type)
	for b in s.changes {
		changes[b] = SOME
		if !through do continue
		c := called(carved_value(k, s, b)) or_continue
		t := c.target.(^Scope) or_continue
		if origin(t) == root do continue
		other := generalized(k, t, false)
		if _, read := equation(k, other); read do changes[b] = call_of(other)
	}
	return generalization(k, root, changes)
}

// widened: the generalized carve g where what the calls of root in t carve is ?? too.
widened :: proc(k: ^Kernel, g: ^Scope, t: Type) -> ^Scope {
	root := g.carved
	changes := make(map[^Binding]Type)
	for b in params_of(k, g) do changes[b] = SOME
	for b, other in through_of(g) do changes[b] = call_of(other)
	wider := false
	for c in calls_in(k, t, root) do for b in c.target.(^Scope).changes do if b not_in changes {
		changes[b] = SOME
		wider = true
	}
	return wider ? generalization(k, root, changes) : g
}

// generalization: the generalized carve of root these changes give, a shared node;
// nil when it is not proven in its colors: it has no equation (§7).
generalization :: proc(k: ^Kernel, root: ^Scope, changes: map[^Binding]Type) -> ^Scope {
	key := carve_key(root, changes)
	if node := built_before(key); node != nil {
		g, _ := node.(^Scope)
		return g
	}
	g := carved_copy(k, root, changes)
	if carve_problem(k, g, root.span) == nil do return g
	replace(key, Invalid{})
	return nil
}

// call_of: the call of the generalized carve g, over its own fields: a shared node.
call_of :: proc(g: ^Scope) -> Type {
	one := [1]Type{g}
	return intern({shape = .Call, children = one[:]})
}

// generalizes: s is a generalized carve: the node of the carve that gives ?? where s
// gives its unknowns.
generalizes :: proc(k: ^Kernel, s: ^Scope) -> bool {
	if s.carved == nil do return false
	changes := make(map[^Binding]Type)
	for b, v in s.changes {
		_, is_unknown := v.(^Unknown)
		changes[b] = is_unknown ? SOME : v
	}
	return built_before(carve_key(s.carved, changes)) == Type(s)
}

// carved_value: the value the carve s gives b, or the one s holds.
carved_value :: proc(k: ^Kernel, s: ^Scope, b: ^Binding) -> Type {
	if v, carved := s.changes[b]; carved do return v
	return binding_type(k, holding(s, b))
}

// equation: what the generalized carve g holds: the type of its first production,
// solved when the laws solve it. Not read while it is typed — its calls are then the
// hypothesis (§5.6) —, nor while the base case of its scope is; without g, a carve not
// proven in its colors, there is none.
equation :: proc(k: ^Kernel, g: ^Scope) -> (Type, bool) {
	if g == nil do return nil, false
	if base, found := first_production(k, g.carved); found && typing(base) do return nil, false
	return equation_term(k, g)
}

// equation_known: the equation of g once its production is typed — also while the
// base case of its scope is —, otherwise when it may be read (equation).
equation_known :: proc(k: ^Kernel, g: ^Scope) -> (Type, bool) {
	if g == nil do return nil, false
	if p, found := first_production(k, g); found && p.type != nil do return equation_term(k, g)
	return equation(k, g)
}

// equation_term: the type of the first production of g, but while it is typed. The
// base case of its scope is typed first (§5.6): it reads the equation.
equation_term :: proc(k: ^Kernel, g: ^Scope) -> (t: Type, ok: bool) {
	if g == nil do return nil, false
	if base, found := first_production(k, g.carved); found && base.type == nil do binding_type(k, base)
	p := first_production(k, g) or_return
	if typing(p) do return nil, false
	return binding_type(k, p), true
}

// params_of: the unknown each field of the generalized carve g is in its equation.
params_of :: proc(k: ^Kernel, g: ^Scope) -> map[^Binding]^Unknown {
	out := make(map[^Binding]^Unknown)
	for b, v in g.changes do if u, is_unknown := v.(^Unknown); is_unknown do out[b] = u
	return out
}

// through_of: the fields g gives a call of another equation, with its generalized
// carve.
through_of :: proc(g: ^Scope) -> map[^Binding]^Scope {
	out := make(map[^Binding]^Scope)
	for b, v in g.changes do if c, is_call := v.(^Collapse); is_call do out[b] = c.target.(^Scope)
	return out
}

// origin: the scope a copy carves, uncarved; a scope is its own.
origin :: proc(s: ^Scope) -> ^Scope {
	return s.carved != nil ? s.carved : s
}

// recursive_call: s! where s is a recursive scope, or a carve of one: the solution of
// its equation at the values s gives (§5.6); without one, the call, which the program
// computes — never its definition read at the values: that is unfolding. A carve of
// it was checked where it is written (scope.odin).
recursive_call :: proc(k: ^Kernel, s: ^Scope, span: syn.Span, site: ^Scope = nil) -> Type {
	root := origin(s)
	run: Rewrite
	if asked_again(k, site, root) do return stays(k, s, span, site)
	// a definition solved is an equality for every value of its fields: substituted,
	// whatever gives them; otherwise read through what gives them (§5.6)
	plain, g := generalized(k, s, false), generalized(k, s)
	if g != plain {
		if t, read := equation(k, plain); read && solved(t, root) do return renewed(k, solution_at(k, plain, t, s), &run)
	}
	if t, read := equation(k, g); read {
		if solved(t, root) do return renewed(k, solution_at(k, g, t, s), &run)
		if v, based := reached_base(k, g, t, s); based do return renewed(k, v, &run)
	}
	return stays(k, s, span, site)
}

// stays: the call s! as a term, which the program computes; with effects, an effect
// (§4.8).
stays :: proc(k: ^Kernel, s: ^Scope, span: syn.Span, site: ^Scope) -> Type {
	out := new(Collapse)
	out.target, out.recursive, out.span, out.site = s, true, span, site
	if origin(s).effectful do return call_effect(k, out)
	return out
}

// asked_again: a call of root written at site is asked again from a production of
// its scope being typed — that of root, or of a carve of it —: it stays a carve and a
// collapse, the hypothesis, never unfolded (§5.6).
asked_again :: proc(k: ^Kernel, site, root: ^Scope) -> bool {
	for x := site; x != nil; x = x.parent {
		if origin(x) != root do continue
		if p, found := first_production(k, x); found && typing(p) do return true
	}
	return false
}

// as_call: t is a recursive call, or what one with effects gives back.
as_call :: proc(t: Type) -> (^Collapse, bool) {
	#partial switch v in t {
	case ^Collapse:
		if v.recursive do return v, true
	case ^Unknown:
		if v.call != nil do return v.call, true
	}
	return nil, false
}

// solved: t holds no recursive call of the scope, nor does a scope in it.
solved :: proc(t: Type, root: ^Scope) -> bool {
	#partial switch v in t {
	case ^Collapse:
		if s, ok := v.target.(^Scope); ok && v.recursive && origin(s) == root do return false
	case ^Scope:
		seen := make(map[^Scope]bool)
		return !names_scope(v, root, &seen)
	case ^Operation:
		for a in v.args do if !solved(a, root) do return false
	case ^Or:
		for a in v.terms do if !solved(a, root) do return false
	case ^And:
		for a in v.terms do if !solved(a, root) do return false
	case ^Not:
		return solved(v.term, root)
	case ^Effect:
		if v.call != nil && !solved(v.call, root) do return false
		if v.fold != nil && !solved(v.fold, root) do return false
		if v.choice != nil && !solved(v.choice, root) do return false
		return solved(v.then, root)
	case ^Pattern:
		if !solved(v.target, root) do return false
		for b in v.branches do if !solved(b.product, root) do return false
	case ^Fold:
		for t in fold_parts(v) do if !solved(t, root) do return false
	case ^Least:
		return solved(v.holds, root)
	case ^Series:
		return solved(v.lo, root) && solved(v.hi, root) && solved(v.term, root)
	case ^Recurrent:
		for t in v.initial do if !solved(t, root) do return false
		return solved(v.at, root)
	}
	return true
}

// calls_in: the recursive calls of root in t, each once.
calls_in :: proc(k: ^Kernel, t: Type, root: ^Scope) -> []^Collapse {
	found := make([dynamic]^Collapse)
	visit :: proc(k: ^Kernel, t: Type, root: ^Scope, found: ^[dynamic]^Collapse) {
		if c, is_call := as_call(t); is_call {
			if s, is_scope := c.target.(^Scope); is_scope && origin(s) == root {
				for x in found do if same(k, x, c) do return
				append(found, c)
			}
			return
		}
		#partial switch v in t {
		case ^Operation:
			for a in v.args do visit(k, a, root, found)
		case ^Pattern:
			visit(k, v.target, root, found)
			for b in v.branches do visit(k, b.product, root, found)
		case ^Or:
			for a in v.terms do visit(k, a, root, found)
		case ^And:
			for a in v.terms do visit(k, a, root, found)
		case ^Not:
			visit(k, v.term, root, found)
		case ^Effect:
			if v.call != nil do visit(k, v.call, root, found)
			if v.choice != nil do visit(k, v.choice, root, found)
			visit(k, v.then, root, found)
		case ^Scope:
			for b in placed(k, v, .Value) do if b.kind != .Product && b.kind != .Handler do visit(k, binding_type(k, b), root, found)
		}
	}
	visit(k, t, root, &found)
	return found[:]
}

// holding: the binding of s that holds b, a binding of the scope s copies: b
// itself, or its copy.
holding :: proc(s: ^Scope, b: ^Binding) -> ^Binding {
	for x in s.bindings do if x == b || x.source == b do return x
	return b
}

// production_law: the value of a production, in normal form. When it has effects
// besides its calls, each call runs them, so its calls are effects too (§4.8): the
// production is typed again on a copy, its calls in the order they are written.
production_law :: proc(k: ^Kernel, b: ^Binding) -> Type {
	root := origin(b.scope)
	if !recursive(root) do return normal(k, b.value)
	first, found := first_production(k, root)
	if found && first != b && first.type == nil do binding_type(k, first)
	if first != b do return normal(k, b.value)
	value := normal(k, b.value)
	if !root.effectful && has_effect(with_effects(k, root, b, value)) {
		root.effectful = true
		m: Copier
		m.scopes[b.scope] = b.scope // the scopes written in the production are copied
		value = normal(k, copy_term(k, &m, b.value, b.scope))
	}
	// the equation of the fields its calls carve, solved: at the values the scope holds
	carves := false
	for c in calls_in(k, value, root) do carves ||= len(c.target.(^Scope).changes) > 0
	if !carves do return value
	g := generalized(k, root)
	if t, read := equation_term(k, g); read && solved(t, root) do return solution_at(k, g, t, b.scope)
	return value
}

// equation_law: t, what the first production of the generalized carve g gives: the
// equation of its scope, in normal form (§5.6) — each call of root that is not at
// values of its fields read by its own equation, and the laws of the recursion
// solving it when they do.
equation_law :: proc(k: ^Kernel, g: ^Scope, t: Type) -> Type {
	if is_invalid(t) do return t
	// what its calls carve is unknown too: solved, the equation of the widened carve,
	// at the values g holds
	if w := widened(k, g, t); w != g {
		if e, read := equation_term(k, w); read && solved(e, g.carved) do return solution_at(k, w, e, g)
	}
	term := instances(k, g, t)
	// what the laws turn invalid is not a solution of a term that holds
	if solution := solve(k, g, term); solution != nil && (holds_invalid(term) || !holds_invalid(solution)) do return solution
	return term
}

// base_cases: the products of e that do not call root, through the effects that wrap
// them (§4.8) and every branch of its patterns: the bases of the equation.
base_cases :: proc(e: Type, root: ^Scope, out: ^[dynamic]Type) {
	if a, is_effect := e.(^Effect); is_effect && (a.call == nil || !a.call.recursive) {
		base_cases(a.then, root, out)
		return
	}
	if p, is_pattern := e.(^Pattern); is_pattern {
		for b in p.branches do base_cases(b.product, root, out)
		return
	}
	if solved(e, root) do append(out, e)
}

// base_family: the family of a recursive call, that of its base cases (§5.6): a product
// that calls it is the hypothesis, X = X | P. Of what it reads of the scope it gives,
// that of what each base gives there. Read in the equation; not known while the
// equation is read.
base_family :: proc(k: ^Kernel, c: ^Collapse, fields := Read{}) -> (Family, bool) {
	s, is_scope := c.target.(^Scope)
	if !is_scope do return {}, false
	root := origin(s)
	t, read := equation_known(k, generalized(k, s))
	if !read do return {}, false
	bases := make([dynamic]Type)
	base_cases(t, root, &bases)
	family: Family
	found := false
	for base in bases {
		// none adds no value, an invalid base is reported where it is
		if is_none(base) || is_invalid(base) do continue
		f, known := read_family(k, given(k, base), fields)
		if !known || found && f != family do return {}, false
		family, found = f, true
	}
	return family, found
}

// read_family: the family of v; with a read, of what is read of the scope v: of the
// field named, or of each of its bindings — a run, by its items.
read_family :: proc(k: ^Kernel, v: Type, fields: Read) -> (Family, bool) {
	if !fields.fields do return family_of(k, v)
	s, is_scope := v.(^Scope)
	if !is_scope do return {}, false
	family: Family
	found := false
	for b in placed(k, s, .Value) {
		if b.kind != .Push && b.kind != .Expand do continue
		if fields.name != "" && b.name != fields.name do continue
		f: Family
		known: bool
		if b.kind == .Push {
			f, known = family_of(k, binding_value(k, b))
		} else if fields.name == "" {
			if set, has := values(k, binding_value(k, b)); has {
				if item, items := item_image(k, set); items do f, known = layout_family(k, item)
			}
		}
		if !known || found && f != family do return {}, false
		family, found = f, true
	}
	return family, found
}

// as_call_any: t is a recursive call, or reads one: x.a, x.#k (§5.6).
as_call_any :: proc(t: Type) -> bool {
	if _, is_call := as_call(t); is_call do return true
	_, read := call_read(t)
	return read
}

// is_pending_call: a recursive call whose equation is being read, or what is read of
// it: the hypothesis of the induction (§5.6), checked once the equation is given.
is_pending_call :: proc(k: ^Kernel, t: Type) -> bool {
	#partial switch v in t {
	case ^Access:
		return is_pending_call(k, v.target)
	case ^Operation:
		if v.op == .Item || v.op == .From do return is_pending_call(k, v.args[0])
	case ^And:
		for a in v.terms do if is_pending_call(k, a) do return true
	}
	c, ok := as_call(t)
	if !ok do return false
	s, is_scope := c.target.(^Scope)
	if !is_scope do return false
	root := origin(s)
	if p, found := first_production(k, root); found && typing(p) do return true
	return asked_again(k, c.site, root)
}

// reached_base: the values the carve s gives the fields reach one branch of the
// equation t of g (§6), a base that calls nothing: its product there is the call
// (§7). Only the covers are read; no other branch, and no call, is.
reached_base :: proc(k: ^Kernel, g: ^Scope, t: Type, s: ^Scope) -> (v: Type, ok: bool) {
	p := t.(^Pattern) or_return
	at := values_of_call(k, g, s)
	target := rewrite(k, p.target, at)
	// the covers at those values too: they may read the fields
	covers := slice.clone(p.branches)
	for &b in covers do if b.cover != nil do b.cover = rewrite(k, b.cover, at)
	reached, _, invalid := reaches(k, target, covers)
	if invalid != nil || len(reached) != 1 || !reached[0].all do return
	b := covers[reached[0].branch]
	if !solved(b.product, g.carved) do return
	v = rewrite(k, branch_product(k, b, reached[0].rewrite, target), at)
	return v, solved(v, g.carved) && !holds_invalid(v)
}
