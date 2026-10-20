package kernel

import syn "../compiler"
import "core:fmt"

// THE CARVE
//
// `target{x -> v}` derives a new scope (specs/language/08). Since each binding
// keeps its symbolic color and value, the carve is a copy: we copy the symbolic
// tree of the scope, put the arguments in place of the values they target, and
// type the copy. Everything that depends on a carved value — a value, a color, a
// deeper carve — is re-typed with it; the final check applies to the copy as to
// any scope.
//
// The errors of the copy are reported at the carve, and only those the carve
// caused: a binding it does not change has already been checked in its source.

type_carve :: proc(k: ^Kernel, c: Carve, env: ^Scope) -> ^Expr {
	t := type_of(k, c.target, env)
	if is_invalid(t) do return t
	if _, d, recursive := equation_var(t); recursive do return carve_itself(k, d, d, c)
	s, is_scope := t^.(^Scope)
	if !is_scope do return report(k, .Invalid_Carve, c.span, fmt.tprintf("only a scope can be carved: %s", brief(t)))
	c.args.carving = s // what `.x` designates in the arguments
	if d, found := redefined(env, s); found do return carve_itself(k, s, d, c)
	// in a copy, this carve is derived with it: its errors go to the original carve
	derived := copy_scope(s, s.parent, k.scene.site != {} ? k.scene.site : c.span)
	targets := fill(k, s, derived, c)
	infer_holes(k, s, c, derived, targets)
	// a copy made silently is that of a binding nothing has changed: it gives back
	// what its source already gave
	if !k.scene.quiet do mark_changes(derived, c.args, {})
	type_scope(k, derived, s.shape)
	return new_expr(derived)
}

// redefined: the scope being defined that the carve of s gives back — same
// written source (a copy keeps the span of what it copies). Whatever its
// arguments, it is a self-reference: X, or X applied to other arguments.
redefined :: proc(env, s: ^Scope) -> (^Scope, bool) {
	for d := env; d != nil; d = d.parent do if d.span == s.span do return d, true
	return nil, false
}

// carve_itself: the carve of s is a self-reference, which gives back d. Nothing of
// s is copied or typed; its arguments are checked against the bindings they fill,
// as for any carve. If they give d types other than its own, it is the equation
// applied to other arguments (polymorphic recursion, or the recursive call of a
// function).
carve_itself :: proc(k: ^Kernel, s, d: ^Scope, c: Carve) -> ^Expr {
	c.args.carving = s
	targets := fill(k, s, copy_scope(s, s.parent, c.span), c)
	for j, i in targets do if j >= 0 do type_argument(k, Carved{c.args, i}, s.bindings[j].color_type)
	append(&k.typed, c.args) // checked at the end, with everything else
	given := make([]^Expr, len(d.bindings))
	for b, j in d.bindings do given[j] = b.value_type
	same := true
	for j, i in targets {
		if j < 0 do continue
		given[j] = c.args.bindings[i].value_type
		if is_invalid(given[j]) do return given[j]
		same &&= expr_equal(k, given[j], d.bindings[j].value_type)
	}
	if same do return new_equation_var(k, new_expr(d))
	// the equation applied to other types: the written source, carved by these
	// arguments
	return new_equation_var(k, new_expr(Carve{target = new_expr(s), args = c.args, ordinals = c.ordinals, span = c.span}))
}

// fill: puts each argument in place of the binding it targets. `->` fills a field,
// `<-` a hole; an argument without a name targets a field, never a hole. The
// target is read in the source s, typed, through its expansions; the copy has the
// same written bindings. Returns, for each argument, the written binding of the
// copy that it fills (-1: none, or a binding that an expansion brings).
fill :: proc(k: ^Kernel, s, derived: ^Scope, c: Carve) -> []int {
	targets := make([]int, len(c.args.bindings))
	chosen := make([dynamic]Place, context.temp_allocator)
	into := make(map[int]Into, context.temp_allocator)
	position := 0
	for a, i in c.args.bindings {
		targets[i] = -1
		if a.kind != .Push && a.kind != .Pull do continue // another arrow: reported at construction
		if a.color != nil {
			report(k, .Unsupported, a.span, "not in the kernel yet: a colored carve argument")
			continue
		}
		p, found := carve_target(s, a, c.ordinals[i], &position)
		if !found {
			report(k, .Invalid_Carve, a.span, carve_miss(a, c.ordinals[i], position))
			continue
		}
		b := binding_at(p)
		if (a.kind == .Pull) != (b.kind == .Pull) {
			message := a.kind == .Pull ? "%s is not a hole: it is filled with ->" : "%s is a hole: it is filled with <-"
			report(k, .Invalid_Carve, a.span, fmt.tprintf(message, display(b)))
			continue
		}
		if slice_contains(chosen[:], p) {
			report(k, .Invalid_Carve, a.span, fmt.tprintf("%s is carved twice", display(b)))
			continue
		}
		append(&chosen, p)
		if !direct(s, p) {
			carve_into(&into, derived, s, p, a, i, c)
			continue
		}
		targets[i] = p.index
		derived.bindings[p.index].value = new_expr(Carved{c.args, i})
	}
	carve_expansions(into, derived, c)
	return targets
}

slice_contains :: proc(places: []Place, p: Place) -> bool {
	for q in places do if q.scope == p.scope && q.index == p.index do return true
	return false
}

// What has changed around what we mark: the implicit color that the shape gives
// its bindings (shape), the scope that `.x` designates (carving).
Around :: struct {
	shape, carving: bool,
}

// mark_changes: in the copy s, the bindings that the carve changes — the value it
// put (an argument of args), and what depends on it: a color, a value, a scope
// written inside, an implicit color. Returns true if a binding of s changed.
mark_changes :: proc(s, args: ^Scope, around: Around) -> (changed: bool) {
	// a branch whose cover changes: its production can change with it
	cover := s.cover != nil && changes(s.cover, s, args, {carving = around.carving})
	for &b in s.bindings {
		color := b.color != nil ? changes(b.color, s, args, {carving = around.carving}) : around.shape
		value := changes(b.value, s, args, {shape = color, carving = around.carving})
		if cover || color || value {
			b.copy = .Changed
			changed = true
		}
	}
	return
}

// changes: `e`, written in env, depends on a changed binding. Each scope written
// inside is marked along the way: both operands are always traversed.
changes :: proc(e: ^Expr, env, args: ^Scope, around: Around) -> bool {
	if e == nil do return false
	inner := Around{carving = around.carving} // the shape colors only the scope it expects
	#partial switch v in e^ {
	case Carved:
		return v.args == args
	case Inferred:
		return v.args == args
	case Carving:
		return around.carving
	case Shorthand:
		outer := changes(v.outer, env, args, inner)
		return outer || around.carving
	case Ref:
		sc := env
		for _ in 0 ..< v.up do sc = sc.parent
		return sc.bindings[v.index].copy == .Changed
	case ^Scope:
		return v.parent == env && mark_changes(v, args, around)
	case Access:
		return changes(v.target, env, args, inner)
	case Collapse:
		return changes(v.target, env, args, inner)
	case Carve:
		target := changes(v.target, env, args, inner)
		written := v.args.parent == env && mark_changes(v.args, args, {carving = target})
		return target || written
	case Op:
		left := changes(v.left, env, args, inner)
		right := changes(v.right, env, args, inner)
		return left || right
	case Match:
		changed := changes(v.target, env, args, inner)
		for b in v.branches do changed |= b.parent == env && mark_changes(b, args, inner)
		return changed
	case Range:
		lo := changes(v.lo, env, args, inner)
		hi := changes(v.hi, env, args, inner)
		return lo || hi
	case Unknown:
		return changes(v.layout, env, args, inner)
	}
	return false
}

// carving_of: the scope derived by the carve of which env is one of the arguments,
// or is written in them.
carving_of :: proc(env: ^Scope) -> ^Scope {
	for sc := env; sc != nil; sc = sc.parent do if sc.carving != nil do return sc.carving
	return nil
}

type_carving :: proc(k: ^Kernel, c: Carving, env: ^Scope) -> ^Expr {
	s := carving_of(env)
	if s == nil do return report(k, .Invalid_Property_Access, c.span, "'.x' without a source is only written in the arguments of a carve")
	return new_expr(s)
}

// recarves: `z{…}` recarves the field z of the carved scope s, if it has one.
recarves :: proc(s: ^Scope, sh: Shorthand) -> bool {
	if s == nil do return false
	_, found := find_binding(s, sh.field.name, sh.field.ordinal)
	return found
}

type_shorthand :: proc(k: ^Kernel, sh: Shorthand, env: ^Scope) -> ^Expr {
	if recarves(carving_of(env), sh) do return type_access(k, sh.field, env)
	if sh.outer == nil do return report(k, .Undefined_Identifier, sh.field.span, fmt.tprintf("'%s' is neither a field of the carved scope nor a visible name", sh.field.name))
	return type_of(k, sh.outer, env)
}

// carve_target: the binding that an argument targets, among those s presents.
// Named, the first occurrence of its name, or that of `x#n`; `z{…}` that recarves
// a field, that field; without a name, the field of the same rank — neither a
// production nor a hole. False: it does not exist — a scope is closed.
carve_target :: proc(s: ^Scope, a: Binding, ordinal: int, position: ^int) -> (Place, bool) {
	if a.name != "" do return find_binding(s, a.name, max(ordinal, 0))
	if sh, ok := shorthand_of(a); ok && recarves(s, sh) do return find_binding(s, sh.field.name, max(sh.field.ordinal, 0))
	rank := position^
	position^ += 1
	for p in places(s) {
		kind := binding_at(p).kind
		if kind == .Product || kind == .Pull do continue
		if rank == 0 do return p, true
		rank -= 1
	}
	return {}, false
}

is_shorthand :: proc(a: Binding) -> bool {
	_, ok := shorthand_of(a)
	return ok
}

// shorthand_of: the argument is `z{…}`, without an arrow.
shorthand_of :: proc(a: Binding) -> (Shorthand, bool) {
	if a.value == nil do return {}, false
	c, is_carve := a.value^.(Carve)
	if !is_carve do return {}, false
	sh, ok := c.target^.(Shorthand)
	return sh, ok
}

carve_miss :: proc(a: Binding, ordinal: int, position: int) -> string {
	if a.name == "" do return fmt.tprintf("the scope has no binding number %d to carve", position)
	if ordinal >= 0 do return fmt.tprintf("'%s#%d' is not a binding of the carved scope", a.name, ordinal)
	return fmt.tprintf("'%s' is not a binding of the carved scope", a.name)
}

// type_argument: the type of a carve argument, typed once, where it was written,
// with the color of the binding it replaces. A copy of the copy keeps the same
// value: the argument was fixed by the carve that wrote it.
type_argument :: proc(k: ^Kernel, c: Carved, color: ^Expr) -> ^Expr {
	a := &c.args.bindings[c.index]
	if a.value_type == nil do type_binding(k, a, c.args, color)
	return a.value_type
}

// copy_scope: the symbolic copy of a scope, under `parent`, derived by the carve
// `site`. The scopes written inside are copied with it; those it only designates
// (a carve argument written elsewhere, the shape that colors it) are shared. The
// types are not copied: the copy is typed again.
copy_scope :: proc(s: ^Scope, parent: ^Scope, site: syn.Span) -> ^Scope {
	c := new_scope(parent, s.span)
	c.shape = s.shape
	c.site = site
	c.cover = copy_expr(s.cover, s, c)
	for b in s.bindings {
		append(&c.bindings, Binding{name = b.name, capture = b.capture, kind = b.kind, color = copy_expr(b.color, s, c), value = copy_expr(b.value, s, c), copy = .Same, span = b.span})
	}
	return c
}

// copy_expr: `e`, written in the scope `from`, rewritten in its copy `to`.
copy_expr :: proc(e: ^Expr, from, to: ^Scope) -> ^Expr {
	if e == nil do return nil
	#partial switch v in e^ {
	case ^Scope:
		if v.parent != from do return e
		return new_expr(copy_scope(v, to, to.site))
	case Access:
		return new_expr(Access{copy_expr(v.target, from, to), v.name, v.ordinal, v.span})
	case Collapse:
		return new_expr(Collapse{copy_expr(v.target, from, to), v.span})
	case Carve:
		args := v.args.parent == from ? copy_scope(v.args, to, to.site) : v.args
		return new_expr(Carve{copy_expr(v.target, from, to), args, v.ordinals, v.span})
	case Op:
		return new_expr(Op{v.kind, copy_expr(v.left, from, to), copy_expr(v.right, from, to), v.span})
	case Match:
		branches := make([]^Scope, len(v.branches))
		for b, i in v.branches do branches[i] = copy_scope(b, to, to.site)
		return new_expr(Match{copy_expr(v.target, from, to), branches, v.span})
	case Range:
		return new_expr(Range{copy_expr(v.lo, from, to), copy_expr(v.hi, from, to), v.span})
	case Unknown:
		return new_expr(Unknown{copy_expr(v.layout, from, to), v.span})
	}
	return e // Set, Ref, Carved, Invalid: nothing to rewrite
}
