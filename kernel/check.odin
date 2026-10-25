package kernel

// WHAT IS CHECKED, AND WHERE (specs/types.md §7)
//
// - every binding of a scope that has a color: `V in C`;
// - a definition along its base case: its first production. The other productions
//   are typed when they are asked;
// - a carve where it is written, in what it changed (scope.odin);
// - inside a branch, under the reach of the branch (pattern.odin).
//
// The file is checked, and each scope reached from it.

check_program :: proc(k: ^Kernel) {
	scope_law(k, k.root)
	for i := 0; i < len(k.pending); i += 1 do check_scope(k, k.pending[i])
}

check_scope :: proc(k: ^Kernel, s: ^Scope) {
	first := true
	expands := false
	for b in s.bindings {
		switch b.kind {
		case .Product:
			if !first do continue
			first = false
		case .Expand:
			expands = true
			if b.value == nil {
				binding_color(k, b) // a run: its color is a type
				continue
			}
		case .Push, .Pull:
		}
		check_binding(k, b)
	}
	if expands {
		placed(k, s, .Value)
		placed(k, s, .Shape)
	}
}

check_binding :: proc(k: ^Kernel, b: ^Binding) {
	value := binding_type(k, b)
	color := binding_color(k, b)
	if color == nil || value == nil do return
	saved := k.rewrite
	k.rewrite = scope_rewrite(b.scope)
	check_in(k, value, color, b.span)
	k.rewrite = saved
}
