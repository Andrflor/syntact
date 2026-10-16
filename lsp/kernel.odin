package lsp

import "../compiler"
import kernel "../kernel"

// ============================================================================
// LE KERNEL DANS L'ÉDITEUR
//
// Le kernel type le fichier sur place : chaque binding écrit porte ses types. Le
// LSP retrouve un binding par la position de ce qui est écrit — le scope écrit le
// plus profond qui contient le curseur, puis, dedans, le binding qui le contient.
// Les copies d'un carve ne sont pas écrites dans le fichier : on ne les parcourt
// pas.
// ============================================================================

contains :: proc(span: compiler.Span, offset: u32) -> bool {
	return span.start <= offset && offset <= span.end
}

// written_scope_at : le scope écrit le plus profond qui contient offset, sous s.
written_scope_at :: proc(s: ^kernel.Scope, offset: u32) -> ^kernel.Scope {
	if s == nil do return nil
	for b in s.bindings {
		if !contains(b.span, offset) do continue
		if inner := scope_in_expr(b.color, s, offset); inner != nil do return inner
		if inner := scope_in_expr(b.value, s, offset); inner != nil do return inner
	}
	return s
}

// scope_in_expr : le scope écrit dans e (qui est écrit dans s) contenant offset.
scope_in_expr :: proc(e: ^kernel.Expr, s: ^kernel.Scope, offset: u32) -> ^kernel.Scope {
	if e == nil do return nil
	#partial switch v in e^ {
	case ^kernel.Scope:
		if v.parent == s && contains(v.span, offset) do return written_scope_at(v, offset)
	case kernel.Carve:
		if inner := scope_in_expr(v.target, s, offset); inner != nil do return inner
		if v.args.parent == s && contains(v.args.span, offset) do return written_scope_at(v.args, offset)
	case kernel.Match:
		if inner := scope_in_expr(v.target, s, offset); inner != nil do return inner
		for b in v.branches {
			if b.parent != s || !contains(b.span, offset) && !contains(b.bindings[0].span, offset) do continue
			if inner := scope_in_expr(b.cover, b, offset); inner != nil do return inner
			return written_scope_at(b, offset)
		}
	case kernel.Access:
		return scope_in_expr(v.target, s, offset)
	case kernel.Collapse:
		return scope_in_expr(v.target, s, offset)
	case kernel.Op:
		if inner := scope_in_expr(v.left, s, offset); inner != nil do return inner
		return scope_in_expr(v.right, s, offset)
	case kernel.Range:
		if inner := scope_in_expr(v.lo, s, offset); inner != nil do return inner
		return scope_in_expr(v.hi, s, offset)
	case kernel.Unknown:
		return scope_in_expr(v.layout, s, offset)
	}
	return nil
}

// written_binding : le binding écrit qui déclare `name` à offset ; sinon celui que
// le prélude nomme ainsi (un builtin).
written_binding :: proc(program: ^kernel.Scope, name: string, offset: u32) -> ^kernel.Binding {
	if program == nil do return nil
	s := written_scope_at(program, offset)
	for &b in s.bindings do if b.name == name && contains(b.span, offset) do return &b
	if prelude := program.parent; prelude != nil {
		for &b in prelude.bindings do if b.name == name do return &b
	}
	return nil
}

// visible_bindings : les bindings nommés visibles à offset, du plus proche au
// prélude ; un nom masqué n'apparaît qu'une fois.
visible_bindings :: proc(program: ^kernel.Scope, offset: u32) -> []^kernel.Binding {
	out := make([dynamic]^kernel.Binding)
	if program == nil do return out[:]
	seen := make(map[string]bool, allocator = context.temp_allocator)
	for sc := written_scope_at(program, offset); sc != nil; sc = sc.parent {
		#reverse for &b in sc.bindings {
			if b.name == "" || b.name in seen do continue
			seen[b.name] = true
			append(&out, &b)
		}
	}
	return out[:]
}

// shown_type : le binding tel que le kernel l'a typé.
shown_type :: proc(b: ^kernel.Binding) -> string {
	return kernel.print_binding(b^, .Type)
}
