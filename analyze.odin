package compiler

import "core:fmt"
import "core:slice"
import "core:strings"

Analyzer :: struct {
	errors:   [dynamic]Analyzer_Error,
	warnings: [dynamic]Analyzer_Error,
	stack:    [dynamic]^ScopeData,
}

Analyzer_Mode :: enum {}

Binding :: struct {
	name:       string,
	kind:       Binding_Kind,
	constraint: ^Shape,
	value:      ValueData,
}

Shape :: struct {
	content: [dynamic]^ValueData,
}

ValueData :: union {
	^ScopeData,
	^StringData,
	^IntegerData,
	^FloatData,
	^BoolData,
}

ScopeData :: struct {
	content: [dynamic]^Binding,
}

StringData :: struct {
	content: string,
}

IntegerData :: struct {
	content: u64,
}

FloatData :: struct {
	content: f64,
}

BoolData :: struct {
	content: bool,
}

Analyzer_Error_Type :: enum {
	Undefined,
	Invalid_Binding_Name,
	Invalid_Property_Access,
	Type_Mismatch,
	Invalid_Constaint_Name,
	Invalid_Constaint_Value,
	Circular_Reference,
	Invalid_Binding_Value,
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

push_scope :: #force_inline proc(data: ^ScopeData) {
	append(&(^Analyzer)(context.user_ptr).stack, data)
}

pop_scope :: #force_inline proc() {
	pop(&(^Analyzer)(context.user_ptr).stack)
}

add_binding :: #force_inline proc(binding: ^Binding) {
	append(
		&(^Analyzer)(context.user_ptr).stack[len((^Analyzer)(context.user_ptr).stack) - 1].content,
		binding,
	)
}

analyze :: proc(cache: ^Cache, ast: ^Node) -> bool {
	if ast == nil {
		return false
	}

	root := new(ScopeData)
	root.content = make([dynamic]^Binding, 0)

	analyzer := Analyzer {
		errors   = make([dynamic]Analyzer_Error, 0),
		warnings = make([dynamic]Analyzer_Error, 0),
		stack    = make([dynamic]^ScopeData, 0),
	}

	context.user_ptr = &analyzer
	push_scope(&builtin)
	push_scope(root)

	// Build the scope hierarchy
	analyze_node(ast)
	fmt.println(root)
	debug_analyzer(&analyzer)

	return len(analyzer.errors) == 0
}

analyze_node :: proc(node: ^Node) {
	if node == nil {
		return
	}
	#partial switch n in node {
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
	case Product:
		process_product(n)
	case Expand:
		process_expand(n)
	case:
    binding := new(Binding)
    binding.name = ""
    binding.kind = .pointing_push
		analyze_binding_value(node, binding)
		add_binding(binding)
	}
}

analyze_binding_name :: #force_inline proc(node: ^Node, binding: ^Binding) {
	#partial switch n in node {
	case Identifier:
		binding.name = n.name
	case Constraint:
		#partial switch v in n.value {
		case Identifier:
			binding.name = v.name
		case:
			analyzer_error(
				"The : constraint indicator must be followed by an identifier or nothing",
				.Invalid_Constaint_Name,
				get_position(n.value^),
			)
		}
		#partial switch v in n.constraint {
		case External:
		case Execute:
		case ScopeNode:
		case Override:
		case Identifier:
		case:
			analyzer_error(
				"The : constraint value must be a valid form",
				.Invalid_Constaint_Value,
				get_position(n.value^),
			)
		}
	case:
		analyzer_error(
			"The binding name can either be a constraint or an identifier",
			.Invalid_Binding_Name,
			get_position(n),
		)
	}
}


analyze_binding_value :: #force_inline proc(node: ^Node, binding: ^Binding) {
	switch n in node {
	case Pointing:
		analyzer_error(
			"Cannot use a Pointing rule as a binding value",
			.Invalid_Binding_Value,
			n.position,
		)
	case PointingPull:
		analyzer_error(
			"Cannot use a Pointing Pull rule as a binding value",
			.Invalid_Binding_Value,
			n.position,
		)
	case EventPush:
		analyzer_error(
			"Cannot use a Event Push rule as a binding value",
			.Invalid_Binding_Value,
			n.position,
		)
	case EventPull:
		analyzer_error(
			"Cannot use a Event Pull rule as a binding value",
			.Invalid_Binding_Value,
			n.position,
		)
	case ResonancePush:
		analyzer_error(
			"Cannot use a Resonance Push rule as a binding value",
			.Invalid_Binding_Value,
			n.position,
		)
	case ResonancePull:
		analyzer_error(
			"Cannot use a Resonance Pull rule as a binding value",
			.Invalid_Binding_Value,
			n.position,
		)
	case Product:
		analyzer_error(
			"Cannot use a Product rule as a binding value",
			.Invalid_Binding_Value,
			n.position,
		)
	case Branch:
		analyzer_error(
			"Cannot use a Branch rule as a binding value",
			.Invalid_Binding_Value,
			n.position,
		)
	case Pattern:
		analyzer_error(
			"Cannot use a Pattern rule as a binding value",
			.Invalid_Binding_Value,
			n.position,
		)
	case Expand:
		analyzer_error(
			"Cannot use an Expand rule as a binding value",
			.Invalid_Binding_Value,
			n.position,
		)
	case Range:
		analyzer_error(
			"Cannot use a Range rule as a binding value",
			.Invalid_Binding_Value,
			n.position,
		)
	case ScopeNode:
		process_scope_node(n, binding)
	case Override:
		process_override(n)
	case Identifier:
		process_identifier(n)
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
	case External:
		process_external(n)
	}
}


process_pointing_push :: proc(node: Pointing) {
  binding := new(Binding)
  binding.name = ""
  binding.kind = .pointing_push
	analyze_binding_name(node.name, binding)
	analyze_binding_value(node.value, binding)
	add_binding(binding)
}

process_pointing_pull :: proc(node: PointingPull) {
  binding := new(Binding)
  binding.name = ""
  binding.kind = .pointing_pull
	analyze_binding_name(node.name, binding)
	analyze_binding_value(node.value, binding)
	add_binding(binding)
}

process_event_push :: proc(node: EventPush) {
  binding := new(Binding)
  binding.name = ""
  binding.kind = .event_push
	analyze_binding_name(node.name, binding)
	analyze_binding_value(node.value, binding)
	add_binding(binding)
}

process_event_pull :: proc(node: EventPull) {
  binding := new(Binding)
  binding.name = ""
  binding.kind = .event_pull
  analyze_binding_name(node.name, binding)
	analyze_binding_value(node.value, binding)
	add_binding(binding)
}

process_resonance_push :: proc(node: ResonancePush) {
  binding := new(Binding)
  binding.name = ""
  binding.kind = .resonance_push
	analyze_binding_name(node.name, binding)
	analyze_binding_value(node.value, binding)
	add_binding(binding)
}

process_resonance_pull :: proc(node: ResonancePull) {
  binding := new(Binding)
  binding.name = ""
  binding.kind = .resonance_pull
	analyze_binding_name(node.name, binding)
	analyze_binding_value(node.value, binding)
	add_binding(binding)
}

process_scope_node :: proc(scope_node: ScopeNode, binding: ^Binding) {
	analyzer := (^Analyzer)(context.user_ptr)

  scope := new(ScopeData)
  scope.content = make([dynamic]^Binding, 0)

  binding.value = scope
  push_scope(scope)

	for i := 0; i < len(scope_node.value); i += 1 {
		analyze_node(&scope_node.value[i])
	}
  pop_scope()
}

process_override :: proc(node: Override) {
	analyzer := (^Analyzer)(context.user_ptr)

	// Process all overrides
	for i := 0; i < len(node.overrides); i += 1 {
		analyze_node(&node.overrides[i])
	}
}

process_product :: proc(node: Product) {

}

process_branch :: proc(node: Branch) {
	analyzer := (^Analyzer)(context.user_ptr)
}

process_identifier :: proc(identifier: Identifier) {
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


resolve_first_symbol :: #force_inline proc(name: string) -> ^Binding {
	return _resolve_first_symbol(name, len((^Analyzer)(context.user_ptr).stack) - 1)
}

_resolve_symbol :: proc(name: string, index: int = 0) -> ^Binding {
	if index < 0 { 	// Changed from index == 0 to index < 0
		return nil
	}

	scope := (^Analyzer)(context.user_ptr).stack[index]
	for i := len(scope.content) - 1; i >= 0; i -= 1 {
		if scope.content[i].name == name {
			return scope.content[i]
		}
	}

	return _resolve_symbol(name, index - 1)
}

_resolve_first_symbol :: proc(name: string, index: int = 0) -> ^Binding {
	if index < 0 { 	// Changed from index == 0 to index < 0
		return nil
	}

	scope := (^Analyzer)(context.user_ptr).stack[index]
	for i := 0; i < len(scope.content); i += 1 {
		if scope.content[i].name == name {
			return scope.content[i]
		}
	}

	return _resolve_first_symbol(name, index - 1)
}

resolve_symbol :: #force_inline proc(name: string) -> ^Binding {
	return _resolve_symbol(name, len((^Analyzer)(context.user_ptr).stack) - 1)
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

get_position :: proc(node: Node) -> Position {
	switch n in node {
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

debug_analyzer :: proc(analyzer: ^Analyzer, verbose: bool = false) {
	fmt.println("=== ANALYZER DEBUG REPORT ===")
	fmt.printf("Errors: %d, Warnings: %d\n", len(analyzer.errors), len(analyzer.warnings))
	fmt.printf("Stack depth: %d\n\n", len(analyzer.stack))

	// Print errors
	if len(analyzer.errors) > 0 {
		fmt.println("ERRORS:")
		for error, i in analyzer.errors {
			debug_error(error, i)
		}
		fmt.println()
	}

	// Print warnings
	if len(analyzer.warnings) > 0 {
		fmt.println("WARNINGS:")
		for warning, i in analyzer.warnings {
			debug_error(warning, i)
		}
		fmt.println()
	}

	// Print scope stack
	fmt.println("SCOPE STACK:")
	for scope, level in analyzer.stack {
		debug_scope(scope, level, verbose)
	}

	fmt.println("=== END DEBUG REPORT ===\n")
}

// Debug a single error/warning
debug_error :: proc(error: Analyzer_Error, index: int) {
	fmt.printf(
		"  [%d] %v at line %d, col %d: %s\n",
		index,
		error.type,
		error.position.line,
		error.position.column,
		error.message,
	)
}

// Debug a scope with all its bindings
debug_scope :: proc(scope: ^ScopeData, level: int, verbose: bool = false) {
	indent := strings.repeat("  ", level)
	fmt.printf("%sScope [%d] - %d bindings:\n", indent, level, len(scope.content))

	if len(scope.content) == 0 {
		fmt.printf("%s  (empty)\n", indent)
		return
	}

	for binding, i in scope.content {
    if(binding != nil) {
      debug_binding(binding, level + 1, i, verbose)
    }
	}
}

// Debug a single binding
debug_binding :: proc(binding: ^Binding, indent_level: int, index: int, verbose: bool = false) {
	indent := strings.repeat("  ", indent_level)

    kind_str := binding_kind_to_string(binding.kind)
    fmt.printf("%s[%d] %s '%s'", indent, index, kind_str, binding.name)
	if binding.constraint != nil {
		fmt.printf(" (constrained)")
	}

	if binding.value != nil {
		value_type := debug_value_type(binding.value)
		fmt.printf(" -> %s", value_type)

		if verbose {
			fmt.printf("\n%s    Value: ", indent)
			debug_value_data(binding.value, indent_level + 2)
		}
	}

	fmt.println()
}

// Get the type name of a ValueData
debug_value_type :: proc(value: ValueData) -> string {
	switch v in value {
	case ^ScopeData:
		return fmt.tprintf("Scope(%d bindings)", len(v.content))
	case ^StringData:
		return "String"
	case ^IntegerData:
		return "Integer"
	case ^FloatData:
		return "Float"
	case ^BoolData:
		return "Bool"
	case:
		return "Unknown"
	}
}

// Debug ValueData contents
debug_value_data :: proc(value: ValueData, indent_level: int) {
	indent := strings.repeat("  ", indent_level)

	switch v in value {
	case ^ScopeData:
		fmt.printf("Scope with %d bindings:\n", len(v.content))
		for binding, i in v.content {
			debug_binding(binding, indent_level + 1, i, false)
		}
	case ^StringData:
		fmt.printf("'%s'\n", v.content)
	case ^IntegerData:
		fmt.printf("%d\n", v.content)
	case ^FloatData:
		fmt.printf("%f\n", v.content)
	case ^BoolData:
		fmt.printf("%t\n", v.content)
	case:
		fmt.printf("Unknown value type\n")
	}
}

// Convert binding kind to readable string
binding_kind_to_string :: proc(kind: Binding_Kind) -> string {
	switch kind {
	case .pointing_push:
		return "PointingPush"
	case .pointing_pull:
		return "PointingPull"
	case .event_push:
		return "EventPush"
	case .event_pull:
		return "EventPull"
	case .resonance_push:
		return "ResonancePush"
	case .resonance_pull:
		return "ResonancePull"
	case .product:
		return "Product"
	case:
		return "Unknown"
	}
}
