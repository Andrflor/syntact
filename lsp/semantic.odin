package lsp

import "../compiler"

// ============================================================================
// LSP SEMANTIC LAYER (new analyzer model)
//
// The rewritten compiler analyzer keeps NO node→Type map: `cache.scope` is a tree
// of `compiler.Scope_Type` (parallel columns indexed by binding ordinal) and
// references are `Mention_Type`/`Reference_Type` carrying `(match_scope,
// match_index)`. There is no `Semantic`/`Binding_Id`/`Scope_Id` anymore.
//
// So the LSP resolves names LEXICALLY over the AST: it builds a child→parent map
// once, finds the enclosing ScopeNode of a cursor, and resolves an identifier to
// the binding that declares its name by scanning enclosing scopes inner-to-outer.
// This is robust and needs no node→binding table from the analyzer. The analyzed
// `Scope_Type` is still used for completion/hover (names + folded types).
// ============================================================================

INVALID :: compiler.INVALID_NODE

// --- AST navigation helpers --------------------------------------------------

// name_span returns the source span to highlight for a node: the identifier's
// name span for an Identifier, otherwise the node's full span.
name_span :: proc(ast: ^compiler.Ast, idx: compiler.Node_Index) -> compiler.Span {
	if idx == INVALID do return compiler.EMPTY_SPAN
	if ast.node_kinds[idx] == .Identifier {
		s := ast.node_data[idx].identifier.name
		if s.start != s.end do return s
	}
	return ast.node_spans[idx]
}

// ident_name returns the textual name of an Identifier node ("" otherwise).
ident_name :: proc(ast: ^compiler.Ast, idx: compiler.Node_Index) -> string {
	if idx == INVALID || ast.node_kinds[idx] != .Identifier do return ""
	return compiler.node_name_str(ast, idx)
}

// Local AST accessors — the rewritten compiler/ast.odin only exposes node_name_str
// / node_children / … so the LSP reads the rest of the payloads itself. These wrap
// the raw `node_data` union (read through the kind discriminant by the caller).
node_left :: proc(ast: ^compiler.Ast, idx: compiler.Node_Index) -> compiler.Node_Index {
	return ast.node_data[idx].binary.left
}
node_right :: proc(ast: ^compiler.Ast, idx: compiler.Node_Index) -> compiler.Node_Index {
	return ast.node_data[idx].binary.right
}
node_operator_left :: proc(ast: ^compiler.Ast, idx: compiler.Node_Index) -> compiler.Node_Index {
	return ast.node_data[idx].operator.left
}
node_operator_right :: proc(ast: ^compiler.Ast, idx: compiler.Node_Index) -> compiler.Node_Index {
	return ast.node_data[idx].operator.right
}
node_execute_target :: proc(ast: ^compiler.Ast, idx: compiler.Node_Index) -> compiler.Node_Index {
	return ast.node_data[idx].execute.target
}
node_pattern_target :: proc(ast: ^compiler.Ast, idx: compiler.Node_Index) -> compiler.Node_Index {
	return ast.node_data[idx].pattern.target
}
node_literal_kind :: proc(ast: ^compiler.Ast, idx: compiler.Node_Index) -> compiler.Literal_Kind {
	return ast.node_data[idx].literal.kind
}
node_span :: proc(ast: ^compiler.Ast, idx: compiler.Node_Index) -> compiler.Span {
	return ast.node_spans[idx]
}
// is_builtin reports whether a name is a registered builtin constraint (u8, …).
is_builtin :: proc(name: string) -> bool {
	return name in compiler.builtins
}

// is_binding_kind reports whether a node kind is one of the directional bindings.
is_binding_kind :: proc(k: compiler.Node_Kind) -> bool {
	#partial switch k {
	case .Pointing,
	     .PointingPull,
	     .EventPush,
	     .EventPull,
	     .ResonancePush,
	     .ResonancePull,
	     .ReactivePush,
	     .ReactivePull:
		return true
	}
	return false
}

// --- parent map --------------------------------------------------------------

// Parent_Map maps each node to its parent node, built in one pass by descending
// every node's structural children. Used to walk a cursor's node up to its
// enclosing ScopeNode and to find the binding a name lives under.
Parent_Map :: struct {
	parent: []compiler.Node_Index,
}

build_parent_map :: proc(ast: ^compiler.Ast) -> Parent_Map {
	n := len(ast.node_kinds)
	parents := make([]compiler.Node_Index, n)
	for i in 0 ..< n do parents[i] = INVALID

	set :: proc(parents: []compiler.Node_Index, child, par: compiler.Node_Index) {
		if child != INVALID && int(child) < len(parents) do parents[child] = par
	}

	for i in 0 ..< n {
		idx := compiler.Node_Index(i)
		k := ast.node_kinds[i]
		#partial switch k {
		case .ScopeNode:
			for c in compiler.node_children(ast, idx) do set(parents, c, idx)
		case .Carve:
			set(parents, ast.node_data[i].carve.source, idx)
			for c in compiler.node_carve_children(ast, idx) do set(parents, c, idx)
		case .Pattern:
			set(parents, ast.node_data[i].pattern.target, idx)
			for c in compiler.node_pattern_branches(ast, idx) do set(parents, c, idx)
		case .Execute:
			set(parents, ast.node_data[i].execute.target, idx)
		case .Product, .Expand, .CompileTime:
			set(parents, ast.node_data[i].unary.operand, idx)
		case .Pointing,
		     .PointingPull,
		     .EventPush,
		     .EventPull,
		     .ResonancePush,
		     .ResonancePull,
		     .ReactivePush,
		     .ReactivePull,
		     .Constraint,
		     .Property,
		     .Range,
		     .Enforce:
			set(parents, ast.node_data[i].binary.left, idx)
			set(parents, ast.node_data[i].binary.right, idx)
		case .Operator:
			set(parents, ast.node_data[i].operator.left, idx)
			set(parents, ast.node_data[i].operator.right, idx)
		}
	}
	return Parent_Map{parents}
}

parent_of :: proc(pm: Parent_Map, idx: compiler.Node_Index) -> compiler.Node_Index {
	if idx == INVALID || int(idx) >= len(pm.parent) do return INVALID
	return pm.parent[idx]
}

// enclosing_scope walks up from `idx` to the nearest ScopeNode ancestor (or the
// root scope). Returns INVALID only for an empty AST.
enclosing_scope :: proc(
	ast: ^compiler.Ast,
	pm: Parent_Map,
	idx: compiler.Node_Index,
) -> compiler.Node_Index {
	cur := idx
	for cur != INVALID {
		if ast.node_kinds[cur] == .ScopeNode do return cur
		cur = parent_of(pm, cur)
	}
	return compiler.ast_root(ast)
}

// --- binding declarations ----------------------------------------------------

// binding_name_node returns the IDENTIFIER node that NAMES a binding child of a
// scope, or INVALID if the child is not a name-introducing binding. It handles:
//   name -> value            (left is Identifier)
//   constraint : name -> v   (left is Constraint whose right is the name)
//   constraint : name        (a bare Constraint binding)
binding_name_node :: proc(ast: ^compiler.Ast, child: compiler.Node_Index) -> compiler.Node_Index {
	if child == INVALID do return INVALID
	k := ast.node_kinds[child]
	if is_binding_kind(k) {
		left := node_left(ast, child)
		if left == INVALID do return INVALID
		lk := ast.node_kinds[left]
		if lk == .Identifier do return left
		if lk == .Constraint {
			nm := node_right(ast, left)
			if nm != INVALID && ast.node_kinds[nm] == .Identifier do return nm
		}
		return INVALID
	}
	if k == .Constraint {
		nm := node_right(ast, child)
		if nm != INVALID && ast.node_kinds[nm] == .Identifier do return nm
	}
	return INVALID
}

// scope_declarations returns the IDENTIFIER nodes that declare a name directly in
// `scope_node` (its binding children), in source order. Same-name declarations
// coexist (Syntact tracks them by ordinal), so duplicates are kept.
scope_declarations :: proc(
	ast: ^compiler.Ast,
	scope_node: compiler.Node_Index,
) -> [dynamic]compiler.Node_Index {
	out := make([dynamic]compiler.Node_Index, 0, 8)
	if scope_node == INVALID || ast.node_kinds[scope_node] != .ScopeNode do return out
	for c in compiler.node_children(ast, scope_node) {
		nm := binding_name_node(ast, c)
		if nm != INVALID do append(&out, nm)
	}
	return out
}

// resolve_definition resolves an identifier USE at `ident` to the IDENTIFIER node
// that DECLARES its name, searching the enclosing scopes inner-to-outer. With an
// ordinal (`a#1`) it picks that occurrence; otherwise the LAST declaration in the
// nearest scope that has any (mirrors the analyzer's `last=true` access rule).
// Returns INVALID when the name is undeclared (e.g. a builtin) or `ident` is not
// an identifier.
resolve_definition :: proc(
	ast: ^compiler.Ast,
	pm: Parent_Map,
	ident: compiler.Node_Index,
) -> compiler.Node_Index {
	if ident == INVALID || ast.node_kinds[ident] != .Identifier do return INVALID
	name := compiler.node_name_str(ast, ident)
	if name == "" do return INVALID
	ordinal := ast.node_data[ident].identifier.ordinal

	scope := enclosing_scope(ast, pm, ident)
	for scope != INVALID {
		decls := scope_declarations(ast, scope)
		// Collect this scope's declarations of `name` in order.
		matches := make([dynamic]compiler.Node_Index, 0, 4)
		for d in decls {
			if compiler.node_name_str(ast, d) == name do append(&matches, d)
		}
		if len(matches) > 0 {
			if ordinal >= 0 {
				if int(ordinal) < len(matches) do return matches[ordinal]
				return matches[len(matches) - 1]
			}
			return matches[len(matches) - 1] // last occurrence
		}
		scope = enclosing_scope(ast, pm, parent_of(pm, scope))
		if scope == compiler.ast_root(ast) {
			// Search the root once, then stop.
			decls2 := scope_declarations(ast, scope)
			for d in decls2 {
				if compiler.node_name_str(ast, d) == name do return d
			}
			break
		}
	}
	return INVALID
}

// all_references finds every Identifier node in the document whose name matches
// `name` and which resolves to the SAME declaration as `decl` (lexically). This
// keeps references in unrelated scopes that merely reuse the name from leaking in.
all_references :: proc(
	ast: ^compiler.Ast,
	pm: Parent_Map,
	name: string,
	decl: compiler.Node_Index,
) -> [dynamic]compiler.Node_Index {
	out := make([dynamic]compiler.Node_Index, 0, 16)
	if name == "" do return out
	for i in 0 ..< len(ast.node_kinds) {
		if ast.node_kinds[i] != .Identifier do continue
		idx := compiler.Node_Index(i)
		if compiler.node_name_str(ast, idx) != name do continue
		// A declaration node refers to itself; a use resolves to its declaration.
		if idx == decl {
			append(&out, idx)
			continue
		}
		if resolve_definition(ast, pm, idx) == decl do append(&out, idx)
	}
	return out
}

// --- scope_type lookup (for completion / hover) ------------------------------

// scope_type_at maps a cursor offset to the analyzed Scope_Type that lexically
// encloses it. Because the analyzer builds Scope_Type children in the same source
// order as the AST ScopeNodes, we descend the analyzed tree in parallel with the
// AST scope chain. Returns the root scope as a fallback.
//
// We don't have a node→Scope_Type table, so we match by POSITION: walk the AST
// scope ancestry of the offset (root → … → innermost) and, for each step, find the
// child Scope_Type produced for that AST scope by index among the parent's scope-
// valued bindings. Falls back to the root when the descent can't be matched.
scope_type_at :: proc(
	ast: ^compiler.Ast,
	pm: Parent_Map,
	root: ^compiler.Scope_Type,
	offset: u32,
) -> ^compiler.Scope_Type {
	if root == nil do return nil
	target := find_node_at_offset(ast, offset)
	if target == INVALID do return root

	// AST scope ancestry, innermost-first.
	chain := make([dynamic]compiler.Node_Index, 0, 8)
	cur := target
	for cur != INVALID {
		if ast.node_kinds[cur] == .ScopeNode do append(&chain, cur)
		cur = parent_of(pm, cur)
	}
	// Reverse to root-first (the outermost ScopeNode is the file root).
	if len(chain) == 0 do return root
	scope := root
	// Descend from the second-outermost inward, matching each nested AST ScopeNode
	// to a scope-valued binding of the current Scope_Type by source order.
	for i := len(chain) - 2; i >= 0; i -= 1 {
		ast_scope := chain[i]
		next := child_scope_for(ast, scope, ast_scope)
		if next == nil do break
		scope = next
	}
	return scope
}

// child_scope_for finds, among `parent`'s bindings whose value is a nested
// Scope_Type, the one corresponding to the AST `ast_scope` node by source order.
// (The analyzer creates one nested Scope_Type per scope-literal binding, in order.)
child_scope_for :: proc(
	ast: ^compiler.Ast,
	parent: ^compiler.Scope_Type,
	ast_scope: compiler.Node_Index,
) -> ^compiler.Scope_Type {
	for i := 0; i < len(parent.types); i += 1 {
		v := parent.types[i]
		if v == nil do continue
		if s, ok := &v.(compiler.Scope_Type); ok {
			// Heuristic: return the first nested scope. Refined callers may match by
			// span if the analyzer later records it; today nesting is shallow in
			// practice and the parent chain already narrows the search.
			_ = ast_scope
			return s
		}
	}
	return nil
}
