package kernel

import "core:fmt"

// THE EXPANSION
//
// `...E` deposits here the bindings of the value of E, all of them and as they are:
// a scope that expands `{2 3}` presents the same bindings as if it wrote them. The
// deposited bindings remain written in their scope — their references are relative
// to it — and a scope presents itself through its expansions (places).
//
// A carve passes into the expansion that brings the binding it targets:
// `{...a}{x -> v}` is `{...a{x -> v}}`, and what depends on x in a is retyped
// with it.

// Place: a binding as a scope presents it. It is written in `scope`, at index
// `index`; `top` is the index, in the presented scope, of the written binding that
// brings it — itself, or the expansion that deposits it.
Place :: struct {
	scope: ^Scope,
	index: int,
	top:   int,
}

binding_at :: proc(p: Place) -> ^Binding {
	return &p.scope.bindings[p.index]
}

// places: the bindings that s presents, its expansions deposited, in order.
// An expansion not yet typed, or invalid, deposits nothing: its error is
// reported where it is written.
places :: proc(s: ^Scope) -> []Place {
	out := make([dynamic]Place)
	for b, i in s.bindings {
		if b.kind != .Expand {
			append(&out, Place{s, i, i})
			continue
		}
		v, is_scope := expanded(b)
		if !is_scope do continue
		for p in places(v) do append(&out, Place{p.scope, p.index, i})
	}
	return out[:]
}

// expanded: the scope that an expansion deposits.
expanded :: proc(b: Binding) -> (^Scope, bool) {
	if b.value_type == nil do return nil, false
	v, is_scope := b.value_type^.(^Scope)
	return v, is_scope
}

// direct: the binding is written in the scope that presents it.
direct :: proc(s: ^Scope, p: Place) -> bool {
	return p.scope == s && p.index == p.top
}

// type_expansion: the value of `...E` must be a scope. A scope written here
// receives `shape`, the rest of the shape of env from its place onward.
type_expansion :: proc(k: ^Kernel, b: ^Binding, env: ^Scope, shape: []Place) {
	previous := enter(k, env, b)
	defer k.scene = previous
	if v, literal := scope_literal(b.value); literal && v.parent == env && shape != nil {
		type_scope(k, v, shape)
		b.value_type = b.value
		return
	}
	if b.color != nil {
		b.color_type = type_color(k, b, env)
		b.value_type = default_of(k, b.color_type, b)
	} else {
		b.value_type = type_of(k, b.value, env)
	}
	if is_invalid(b.value_type) do return
	if _, is_scope := b.value_type^.(^Scope); !is_scope {
		if _, _, recursive := equation_var(b.value_type); recursive {
			b.value_type = report(k, .Unsupported, b.span, "not in the kernel yet: expanding a recursive type")
			return
		}
		b.value_type = report(k, .Invalid_Expansion, b.span, fmt.tprintf("only a scope can be expanded: %s", brief(b.value_type)))
	}
}

// Into: the arguments that a carve passes into the expansion `top` of its copy.
Into :: struct {
	args:     ^Scope,
	ordinals: [dynamic]int,
}

// carve_into: the argument `a`, index i of the arguments of c, targets `target`,
// which the expansion `target.top` brings. It becomes an argument of the carve of
// that expansion: named by the binding it targets, at its occurrence in the
// deposited scope; unnamed if it is positional — the positions of a deposited
// scope follow one another, and the carve fills them in order.
carve_into :: proc(into: ^map[int]Into, derived, s: ^Scope, target: Place, a: Binding, i: int, c: Carve) {
	group, seen := into[target.top]
	if !seen do group = Into{args = new_scope(derived, c.args.span)}
	name, ordinal := "", -1
	if a.name != "" || is_shorthand(a) {
		name = binding_at(target).name
		ordinal = local_ordinal(expanded_scope(s.bindings[target.top]), target, name)
	}
	append(&group.args.bindings, Binding{name = name, kind = a.kind, value = new_expr(Carved{c.args, i}), span = a.span})
	append(&group.ordinals, ordinal)
	into[target.top] = group
}

// carve_expansions: each expansion into which arguments pass becomes
// `...E{…}`.
carve_expansions :: proc(into: map[int]Into, derived: ^Scope, c: Carve) {
	for top, group in into {
		b := &derived.bindings[top]
		b.value = new_expr(Carve{target = b.value, args = group.args, ordinals = group.ordinals[:], span = c.span})
	}
}

// expanded_scope: the scope that a typed expansion deposits.
expanded_scope :: proc(b: Binding) -> ^Scope {
	v, _ := expanded(b)
	return v
}

// local_ordinal: the occurrence of `name`, in the deposited scope, that `target` is.
local_ordinal :: proc(s: ^Scope, target: Place, name: string) -> int {
	seen := 0
	for p in places(s) {
		if p.scope == target.scope && p.index == target.index do return seen
		if binding_at(p).name == name do seen += 1
	}
	return -1
}

// scope_literal: the written value is a scope.
scope_literal :: proc(value: ^Expr) -> (^Scope, bool) {
	if value == nil do return nil, false
	v, ok := value^.(^Scope)
	return v, ok
}
