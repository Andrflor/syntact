package compiler

import "core:fmt"
import "core:hash"
import "core:slice"
import "core:strings"
import "core:time"

Analyzer :: struct {
	errors:       [dynamic]Analyzer_Error,
	warnings:     [dynamic]Analyzer_Error,
	root:         ^Scope,
	current:      ^Scope,
	current_node: ^Node,
}

Analyzer_Error_Type :: enum {
	Undefined,
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


analyze :: proc(cache: ^Cache, ast: ^Node) -> bool {
	if (ast == nil) {
		return false
	}

	root := new(Scope)
	root.name = cache.path
	root.parent = &builtin
	root.binding_kind = .pointing_push
	root.content = make([dynamic]Scope, 8)

	analyzer := Analyzer {
		errors   = make([dynamic]Analyzer_Error, 1),
		warnings = make([dynamic]Analyzer_Error, 1),
		root     = root,
		current  = root,
	}
	context.user_ptr = &analyzer

	analyze_node(ast)
	return true
}

enter_scope :: proc(symbol: ^Scope) {
}

leave_scope :: proc() {

}

analyze_node :: proc(node: ^Node) {
	analyzer := (^Analyzer)(context.user_ptr)
	switch n in node {
	case Pointing:
	case PointingPull:
	case EventPush:
	case EventPull:
	case ResonancePush:
	case ResonancePull:
	case ScopeNode:
	case Override:
	case Product:
	case Branch:
	case Identifier:
	case Pattern:
	case Constraint:
	case Operator:
	case Execute:
	case Literal:
	case Property:
	case Expand:
	case External:
	case Range:
	}
}

resolve_symbol :: proc(scope: ^Scope, name: string) -> ^Scope {
	if scope == nil {
		analyzer_error_at(fmt.tprintf("Cannot find name %s in current scope", name), .Undefined)
		return nil
	}

	for i := 0; i < len(scope.content); i += 1 {
		content_scope := &scope.content[i]
		if content_scope.name == name {
			return content_scope
		}
	}

	return resolve_symbol(scope.parent, name)
}

/*
 * error_at creates a detailed error record at a specific token
 */
analyzer_error_at :: proc(message: string, error_type: Analyzer_Error_Type) {
	analyzer := (^Analyzer)(context.user_ptr)
	// Create detailed error record
	error := Analyzer_Error {
		type     = error_type,
		message  = message,
		position = NODE_POS(analyzer.current_node),
	}

	// Add to errors list
	append(&analyzer.errors, error)
}

/*
 * error_at creates a detailed error record at a specific token
 */
analyzer_warning_at :: proc(message: string, error_type: Analyzer_Error_Type) {
	analyzer := (^Analyzer)(context.user_ptr)
	// Create detailed error record
	error := Analyzer_Error {
		type     = error_type,
		message  = message,
		position = NODE_POS(analyzer.current_node),
	}

	// Add to errors list
	append(&analyzer.errors, error)
}

Scope :: struct {
	name:         string,
	parent:       ^Scope,
	content:      [dynamic]Scope,
	binding_kind: Binding_Kind,
}

NODE_POS :: #force_inline proc(node: ^Node) -> Position {
	#partial switch n in node^ {
	case Pointing:
		return n.position
	case PointingPull:
		return n.position
	case EventPush:
		return n.position
	case EventPull:
		return n.position
	case ResonancePush:
		return n.position
	case ResonancePull:
		return n.position
	case ScopeNode:
		return n.position
	case Override:
		return n.position
	case Product:
		return n.position
	case Branch:
		return n.position
	case Identifier:
		return n.position
	case Pattern:
		return n.position
	case Constraint:
		return n.position
	case Operator:
		return n.position
	case Execute:
		return n.position
	case Literal:
		return n.position
	case Property:
		return n.position
	case Expand:
		return n.position
	case External:
		return n.position
	case Range:
		return n.position
	}
	return Position{}
}
