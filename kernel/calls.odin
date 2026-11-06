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

// origin: the scope a copy carves, uncarved; a scope is its own.
origin :: proc(s: ^Scope) -> ^Scope {
	return s.carved != nil ? s.carved : s
}

// recursive_call: s! where s is a recursive scope, or a carve of one: the solution of
// its equation at the values s gives (§5.6); without one, the call, which the program
// computes — never its definition read at the values: that is unfolding. A carve of
// it was checked where it is written (scope.odin).
recursive_call :: proc(k: ^Kernel, s: ^Scope, span: syn.Span) -> Type {
	root := origin(s)
	// a definition solved is an equality for every value of its fields: substituted,
	// whatever gives them; otherwise read through what gives them (§5.6)
	if through := through_of(k, s); len(through) > 0 {
		if eq, read := equation_of(k, root, call_key(s)); read && eq.solution != nil {
			run: Rewrite
			return renewed(k, solution_at(k, eq, s), &run)
		}
	}
	if eq, read := equation_of(k, root, call_key(s), through_of(k, s)); read {
		run: Rewrite
		if eq.solution != nil do return renewed(k, solution_at(k, eq, s), &run)
		if v, based := reached_base(k, eq, s); based do return renewed(k, v, &run)
	}
	out := new(Collapse)
	out.target, out.recursive, out.span = s, true, span
	if root.effectful do return call_effect(k, out)
	return out
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
	carved := make(map[^Binding]bool)
	for c in calls_in(k, value, root) do for x in c.target.(^Scope).changes do carved[x] = true
	if len(carved) == 0 do return value
	key := make([dynamic]^Binding)
	for x in in_order(carved) do append(&key, x)
	eq: ^Recursion
	if x, found := equation_covering(k, root, key[:], nil); found do eq = x
	if eq == nil do eq = equation_built(k, root, key[:])
	if eq.solution != nil do return solution_at(k, eq, b.scope)
	return value
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
	key, through := call_key(s), through_of(k, s)
	// its bases are known once its term is, while it is read too
	eq, read := equation_found(k, root, key, through)
	if !read do eq, read = equation_of(k, root, key, through)
	if !read || eq.term == nil do return {}, false
	bases := make([dynamic]Type)
	base_cases(eq.term, root, &bases)
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
	for x in k.equations do if x.root == root && x.reading do return true
	return false
}

// reached_base: the values the carve s gives the fields reach one branch of the
// equation (§6), a base that calls nothing: its product there is the call (§7). Only
// the covers are read; no other branch, and no call, is.
reached_base :: proc(k: ^Kernel, eq: ^Recursion, s: ^Scope) -> (v: Type, ok: bool) {
	p := eq.term.(^Pattern) or_return
	at := values_of_call(k, eq, s)
	target := rewrite(k, p.target, at)
	reached, _, invalid := reaches(k, target, p.branches)
	if invalid != nil || len(reached) != 1 || !reached[0].all do return
	b := p.branches[reached[0].branch]
	if !solved(b.product, eq.root) do return
	v = rewrite(k, branch_product(k, b, reached[0].rewrite, target), at)
	return v, solved(v, eq.root) && !holds_invalid(v)
}
