package kernel

import "core:fmt"

// THE CHECK
//
// Once everything is typed, the value of each colored binding must be an element
// of its color for every value of the unknowns: the type `value in color` holds
// (in.odin, decide.odin). It is the only question of the typecheck. The color and
// the value are two types like any other: both can depend on unknowns, a `??`
// written in the color as well.
check :: proc(k: ^Kernel) {
	for s in k.typed {
		for &b in s.bindings {
			if b.color_type == nil || b.value_type == nil || is_invalid(b.color_type) || is_invalid(b.value_type) do continue
			enter(k, s, &b)
			ctx := context_of(s) // what the branches around the binding know
			switch decide(k, in_type(k, b.value_type, b.color_type, ctx), ctx) {
			case .Proved:
			case .Refuted:
				if color, known := normal_set(k, b.color_type); known {
					if field, set, found := refused_field(k, color, b.value_type, ctx); found {
						report_about(k, .Constraint_Mismatch, b.span, field.span, fmt.tprintf("%s ∉ %s on %s, in %s", brief(field.value_type), print_set(set), display(field), display(&b)))
						continue
					}
				}
				report(k, .Constraint_Mismatch, b.span, fmt.tprintf("%s ∉ %s on %s", brief(b.value_type), brief(b.color_type), display(&b)))
			case .Undecided:
				report(k, .Unproven, b.span, fmt.tprintf("%s ∈ %s could not be proved on %s", brief(b.value_type), brief(b.color_type), display(&b)))
			}
		}
	}
	k.scene = {}
}

// refused_field: when the color is a single shape and the value a scope, the
// binding of the value that the shape refuses — at the deepest, when it is a scope
// refused by a shape further inside — and what the shape admits there.
refused_field :: proc(k: ^Kernel, color: Set, t: ^Expr, ctx: Context = nil) -> (field: ^Binding, set: Set, found: bool) {
	s, is_scope := t^.(^Scope)
	if !is_scope do return
	n, is_node := color.scopes.(^Bdd_Node)
	if !is_node || !is_leaf(n.yes, .Top) || !is_leaf(n.maybe, .Bottom) || !is_leaf(n.no, .Bottom) || has_run(n.atom) do return
	shown := places(s)
	if len(shown) != len(n.atom.fields) do return
	for f, i in n.atom.fields {
		b := binding_at(shown[i])
		if f.free || b.value_type == nil || decide(k, in_type(k, b.value_type, new_expr(f.set), ctx), ctx) != .Refuted do continue
		if inner, inner_set, deeper := refused_field(k, f.set, b.value_type, ctx); deeper do return inner, inner_set, true
		return b, f.set, true
	}
	return
}
