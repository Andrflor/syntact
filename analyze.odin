package compiler

import "core:fmt"
import "core:slice"
import "core:strings"

Analyzer :: struct {
	errors:   [dynamic]Analyzer_Error,
	warnings: [dynamic]Analyzer_Error,
	root:     ^Scope,
	current:  ^Scope,
}

Analyzer_Error_Type :: enum {
	Undefined,
	Invalid_Binding_Name,
	Type_Mismatch,
	Circular_Reference,
}

Binding_Kind :: enum {
	pointing_push,
	pointing_pull,
	event_push,
	event_pull,
	resonance_push,
	resonance_pull,
	product,
}

Analyzer_Error :: struct {
	type:     Analyzer_Error_Type,
	message:  string,
	position: Position,
}

// Simplified scope structure focused on tracking references
Scope :: struct {
	name:         string,
	parent:       ^Scope,
	content:      [dynamic]^Scope, // Child scopes
	binding_kind: Binding_Kind,
	expression:   ^Node, // Original AST node
	type_info:    ^Scope, // Type constraint if present
	referenced:   bool, // Track if the binding is used
}

analyze :: proc(cache: ^Cache, ast: ^Node) -> bool {
	if ast == nil {
		return false
	}

	root := new(Scope)
	root.name = cache.path
	root.parent = &builtin
	root.binding_kind = .pointing_push
	root.content = make([dynamic]^Scope, 8)

	analyzer := Analyzer {
		errors   = make([dynamic]Analyzer_Error, 0),
		warnings = make([dynamic]Analyzer_Error, 0),
		root     = root,
		current  = root,
	}
	context.user_ptr = &analyzer

	// Build the scope hierarchy
	analyze_node(ast)

	// Print analysis results
	print_analyzer_results(&analyzer)

	return len(analyzer.errors) == 0
}

analyze_node :: proc(node: ^Node) {
	if node == nil {
		return
	}

	switch n in node {
	case Pointing:
		process_pointing_push(n)
	case PointingPull:
		process_pointing_pull(n)
	case EventPush:
		process_event_push(n)
	case EventPull:
		process_event_pull(n)
	case ResonancePush:
		process_resonance_push(n)
	case ResonancePull:
		process_resonance_pull(n)
	case ScopeNode:
		process_scope_node(n)
	case Override:
		process_override(n)
	case Product:
		process_product(n)
	case Branch:
		process_branch(n)
	case Identifier:
		process_identifier(n)
	case Pattern:
		process_pattern(n)
	case Constraint:
		process_constraint(n)
	case Operator:
		process_operator(n)
	case Execute:
		process_execute(n)
	case Literal:
		process_literal(n)
	case Property:
		process_property(n)
	case Expand:
		process_expand(n)
	case External:
		process_external(n)
	case Range:
		process_range(n)
	}
}

// Core implementations
process_pointing_push :: proc(node: Pointing) {
	analyzer := (^Analyzer)(context.user_ptr)

	// Create scope for binding
	scope := create_binding_scope(node.name, .pointing_push)

	// Store the value expression directly
	scope.expression = node.value

	// Process scope value if it's a scope node
	if scope_node, is_scope := node.value.(ScopeNode); is_scope {
		old_current := analyzer.current
		analyzer.current = scope // Enter the binding's scope
		process_scope_node(scope_node)
		analyzer.current = old_current // Return to parent
	}
}

process_pointing_pull :: proc(node: PointingPull) {
	analyzer := (^Analyzer)(context.user_ptr)
	// Create scope for binding
	scope := create_binding_scope(node.name, .pointing_pull)
	// Store the value expression
	scope.expression = node.value
}

process_event_push :: proc(node: EventPush) {
	analyzer := (^Analyzer)(context.user_ptr)
	// Create scope for binding
	scope := create_binding_scope(node.name, .event_push)
	// Store the value expression
	scope.expression = node.value
}

process_event_pull :: proc(node: EventPull) {
	analyzer := (^Analyzer)(context.user_ptr)
	// Create scope for binding
	scope := create_binding_scope(node.name, .event_pull)
	// Store the value expression
	scope.expression = node.value
}

process_resonance_push :: proc(node: ResonancePush) {
	analyzer := (^Analyzer)(context.user_ptr)
	// Create scope for binding
	scope := create_binding_scope(node.name, .resonance_push)
}

process_resonance_pull :: proc(node: ResonancePull) {
	analyzer := (^Analyzer)(context.user_ptr)

	// Create scope for binding
	scope := create_binding_scope(node.name, .resonance_pull)

	// Store the value expression
	scope.expression = node.value
}

process_scope_node :: proc(scope_node: ScopeNode) {
	analyzer := (^Analyzer)(context.user_ptr)

	// Process all nodes in the scope
	for i := 0; i < len(scope_node.value); i += 1 {
		analyze_node(&scope_node.value[i])
	}
}

process_override :: proc(node: Override) {
	analyzer := (^Analyzer)(context.user_ptr)

	// Process all overrides
	for i := 0; i < len(node.overrides); i += 1 {
		analyze_node(&node.overrides[i])
	}
}

process_product :: proc(node: Product) {
	analyzer := (^Analyzer)(context.user_ptr)

	// Create a product scope
	scope := new(Scope)
	scope.binding_kind = .product
	scope.parent = analyzer.current
	scope.content = make([dynamic]^Scope, 0)
	scope.expression = node.value

	append(&analyzer.current.content, scope)
}

process_branch :: proc(node: Branch) {
	analyzer := (^Analyzer)(context.user_ptr)
}

process_identifier :: proc(identifier: Identifier) {
	analyzer := (^Analyzer)(context.user_ptr)

	// Resolve symbol
	symbol := resolve_symbol(analyzer.current, identifier.name)

	if symbol == nil {
		analyzer_error(
			fmt.tprintf("Undefined symbol: %s", identifier.name),
			.Undefined,
			identifier.position,
		)
	} else {
		// Mark as referenced
		symbol.referenced = true
	}
}

process_pattern :: proc(node: Pattern) {
	analyzer := (^Analyzer)(context.user_ptr)

}

process_constraint :: proc(node: Constraint) {
	analyzer := (^Analyzer)(context.user_ptr)


	// Process value if present
	if node.value != nil {
	}
}

process_operator :: proc(node: Operator) {
}

process_execute :: proc(node: Execute) {
	analyzer := (^Analyzer)(context.user_ptr)

	// Process the value to be executed
	if node.value != nil {

		// If executing an identifier, mark it as referenced
		if id, is_id := node.value.(Identifier); is_id {
			symbol := resolve_symbol(analyzer.current, id.name)
			if symbol != nil {
				symbol.referenced = true
			} else {
				analyzer_error(
					fmt.tprintf("Cannot execute undefined symbol: %s", id.name),
					.Undefined,
					id.position,
				)
			}
		}
	}
}

process_literal :: proc(node: Literal) {

}

process_property :: proc(node: Property) {
}

process_expand :: proc(node: Expand) {
}

process_external :: proc(node: External) {
}

process_range :: proc(node: Range) {

}

// Create a scope for a binding from a name node
create_binding_scope :: proc(name_node: ^Node, kind: Binding_Kind) -> ^Scope {
	analyzer := (^Analyzer)(context.user_ptr)

	scope := new(Scope)
	scope.binding_kind = kind
	scope.parent = analyzer.current
	scope.content = make([dynamic]^Scope, 0)
	scope.referenced = false

	// Extract name
	if id, is_id := name_node.(Identifier); is_id {
		scope.name = id.name
	} else if constraint, is_constraint := name_node.(Constraint); is_constraint {
		// Handle type constraint
		if type_id, is_type_id := constraint.constraint.(Identifier); is_type_id {
			scope.type_info = resolve_symbol(analyzer.current, type_id.name)
		}

		// Extract name from constraint
		if id, is_id := constraint.value.(Identifier); is_id {
			scope.name = id.name
		}
	}

	append(&analyzer.current.content, scope)
	return scope
}

resolve_symbol :: proc(scope: ^Scope, name: string) -> ^Scope {
	if scope == nil {
		return nil
	}

	// Check in current scope
	for i := 0; i < len(scope.content); i += 1 {
		if scope.content[i].name == name {
			return scope.content[i]
		}
	}

	// Check parent scope
	return resolve_symbol(scope.parent, name)
}

analyzer_error :: proc(message: string, error_type: Analyzer_Error_Type, position: Position) {
	analyzer := (^Analyzer)(context.user_ptr)

	error := Analyzer_Error {
		type     = error_type,
		message  = message,
		position = position,
	}

	append(&analyzer.errors, error)
}

print_analyzer_results :: proc(analyzer: ^Analyzer) {
	fmt.println("\n=== ANALYZER RESULTS ===")

	// Print errors
	if len(analyzer.errors) > 0 {
		fmt.println("\nERRORS:")
		for error, i in analyzer.errors {
			pos := error.position
			fmt.printf(
				"[%d] %v at line %d, column %d: %s\n",
				i + 1,
				error.type,
				pos.line,
				pos.column,
				error.message,
			)
		}
	} else {
		fmt.println("\nNo errors detected.")
	}

	// Print warnings
	if len(analyzer.warnings) > 0 {
		fmt.println("\nWARNINGS:")
		for warning, i in analyzer.warnings {
			pos := warning.position
			fmt.printf(
				"[%d] %v at line %d, column %d: %s\n",
				i + 1,
				warning.type,
				pos.line,
				pos.column,
				warning.message,
			)
		}
	} else {
		fmt.println("\nNo warnings detected.")
	}

	// Print scope tree
	fmt.println("\n=== SCOPE TREE ===")
	print_scope_tree(analyzer.root)
	fmt.println("\n======================")
}

print_scope_tree :: proc(scope: ^Scope, indent: int = 0) {
	if scope == nil {
		return
	}

	indentation := strings.repeat(" ", indent * 2)

	// Print type if present
	type_str := ""
	if scope.type_info != nil {
		type_str = fmt.tprintf(" : %s", scope.type_info.name)
	}

	// Print expression summary if present
	expr_str := ""
	if scope.expression != nil {
		#partial switch e in scope.expression {
		case Literal:
			expr_str = fmt.tprintf(" = %s (%v)", e.value, e.kind)
		case Operator:
			expr_str = fmt.tprintf(" = <operator: %v>", e.kind)
		case:
			expr_str = fmt.tprintf(" = <%T>", scope.expression^)
		}
	}

	// Add reference status
	ref_str := scope.referenced ? " (used)" : " (unused)"

	fmt.printf(
		"%s%s%s%s (%v)%s\n",
		indentation,
		scope.name,
		type_str,
		expr_str,
		scope.binding_kind,
		ref_str,
	)

	// Print children
	for i := 0; i < len(scope.content); i += 1 {
		print_scope_tree(scope.content[i], indent + 1)
	}
}
