package compiler

import "core:fmt"
import "core:slice"
import "core:strconv"
import "core:strings"

// Main analyzer structure that maintains the analysis state
// Contains error tracking and a scope stack for symbol resolution
Analyzer :: struct {
	errors:   [dynamic]Analyzer_Error, // Collection of semantic errors found during analysis
	warnings: [dynamic]Analyzer_Error, // Collection of warnings found during analysis
	stack:    [dynamic]^ScopeData, // Stack of nested scopes for symbol resolution
}

// Represents a binding (variable/symbol) in the language
// Contains the name, type of binding, optional type constraint, and value
Binding :: struct {
	name:       string, // The identifier name of the binding
	kind:       Binding_Kind, // What type of binding this is (push/pull/event/etc.)
	constraint: ^ScopeData, // Optional type constraint for the binding
	value:      ValueData, // The actual value/data associated with this binding
}

// Union type representing all possible value types in the language
// This is the core data representation for runtime values
ValueData :: union {
	^ScopeData, // Reference to a scope (nested bindings)
	^StringData, // String literal value
	^IntegerData, // Integer literal value
	^FloatData, // Float literal value
	^BoolData, // Boolean literal value
	Empty, // Empty/null value
}

// Represents an empty/null value
Empty :: struct {}

// Represents a scope containing multiple bindings
// Scopes are used for namespacing and variable resolution
ScopeData :: struct {
	content: [dynamic]^Binding, // Array of bindings within this scope
}

// String literal data with content
StringData :: struct {
	content: string,
}

// Integer literal data with content and specific integer type
IntegerData :: struct {
	content: u64, // The actual integer value
	kind:    IntegerKind, // Specific integer type (u8, i32, etc.)
}

// Enumeration of supported integer types
IntegerKind :: enum {
	none, // Unspecified integer type
	u8, // 8-bit unsigned integer
	i8, // 8-bit signed integer
	u16, // 16-bit unsigned integer
	i16, // 16-bit signed integer
	u32, // 32-bit unsigned integer
	i32, // 32-bit signed integer
	u64, // 64-bit unsigned integer
	i64, // 64-bit signed integer
}

// Enumeration of supported floating-point types
FloatKind :: enum {
	none, // Unspecified float type
	f32, // 32-bit float
	f64, // 64-bit float
}

// Float literal data with content and specific float type
FloatData :: struct {
	content: f64, // The actual float value
	kind:    FloatKind, // Specific float type
}

// Boolean literal data
BoolData :: struct {
	content: bool,
}

// Enumeration of all possible analyzer error types
Analyzer_Error_Type :: enum {
	Undefined_Identifier, // Reference to undeclared identifier
	Invalid_Binding_Name, // Invalid syntax for binding names
	Invalid_Override, // Invalid property access syntax
	Invalid_Property_Access, // Invalid property access syntax
	Type_Mismatch, // Type constraint violation
	Invalid_Constaint, // Invalid constraint syntax
	Invalid_Constaint_Name, // Invalid constraint name
	Invalid_Constaint_Value, // Invalid constraint value
	Circular_Reference, // Circular dependency detected
	Invalid_Binding_Value, // Invalid value for binding
	Invalid_Expand,
}

// Enumeration of different binding types in the language
// These represent different semantic categories of bindings
Binding_Kind :: enum {
	pointing_push, // Push-style pointing binding
	pointing_pull, // Pull-style pointing binding
	event_push, // Push-style event binding
	event_pull, // Pull-style event binding
	resonance_push, // Push-style resonance binding
	resonance_pull, // Pull-style resonance binding
	inline_push, // Paste value of a scope in another
	product, // Product/output binding
	event_source, // Event source binding
}

// Structure representing an analyzer error with context
Analyzer_Error :: struct {
	type:     Analyzer_Error_Type, // The type of error
	message:  string, // Human-readable error message
	position: Position, // Source code position where error occurred
}

// Pushes a new scope onto the scope stack
// Used when entering nested scopes (functions, blocks, etc.)
push_scope :: #force_inline proc(data: ^ScopeData) {
	append(&(^Analyzer)(context.user_ptr).stack, data)
}

// Pops the current scope from the scope stack
// Used when exiting nested scopes
pop_scope :: #force_inline proc() {
	pop(&(^Analyzer)(context.user_ptr).stack)
}

// Adds a binding to the current (top) scope
// New bindings are always added to the most recent scope
add_binding :: #force_inline proc(binding: ^Binding) {
	append(
		&(^Analyzer)(context.user_ptr).stack[len((^Analyzer)(context.user_ptr).stack) - 1].content,
		binding,
	)
}

// Main entry point for semantic analysis
// Takes a cache and AST root node, returns true if analysis succeeded (no errors)
analyze :: proc(cache: ^Cache, ast: ^Node) -> bool {
	if ast == nil {
		return false
	}

	// Create the root scope for global bindings
	root := new(ScopeData)
	root.content = make([dynamic]^Binding, 0)

	// Initialize the analyzer with empty error collections and scope stack
	analyzer := Analyzer {
		errors   = make([dynamic]Analyzer_Error, 0),
		warnings = make([dynamic]Analyzer_Error, 0),
		stack    = make([dynamic]^ScopeData, 0),
	}

	// Set up the context for analyzer procedures to access the analyzer state
	context.user_ptr = &analyzer

	// Push builtin scope first (contains built-in functions/types)
	push_scope(&builtin)
	// Push the root scope for user-defined bindings
	push_scope(root)

	// Process the entire AST starting from the root
	analyze_node(ast)

	// Print debug information about the analysis results
	debug_analyzer(&analyzer, true)

	// Return true if no errors were found
	return len(analyzer.errors) == 0
}

// Recursive procedure to analyze individual AST nodes
// Dispatches to specific processing procedures based on node type
analyze_node :: proc(node: ^Node) {
	if node == nil {
		return
	}

	// Pattern match on the node type and dispatch to appropriate handler
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
	case Expand:
		process_expand(n)
	case Product:
		process_product(n)
	case:
		// Default case: create an anonymous binding for unhandled node types
		binding := new(Binding)
		binding.name = ""
		binding.kind = .pointing_push
		analyze_binding_value(node, binding)
		add_binding(binding)
		typecheck_binding(binding, get_position(node))
	}
}

// Analyzes and validates the name part of a binding
// Handles identifiers and constraints on binding names
analyze_binding_name :: #force_inline proc(node: ^Node, binding: ^Binding) {
	if (node == nil) {
		analyzer_error(
			"A name was expected for the binding got nothing",
			.Invalid_Binding_Value,
			Position{},
		)
		return
	}

	#partial switch n in node {
	case Identifier:
		// Simple identifier as binding name
		binding.name = n.name
	case Constraint:
		// Constraint with optional identifier
		#partial switch v in n.value {
		case Identifier:
			binding.name = v.name
		case:
			analyzer_error(
				"The : constraint indicator must be followed by an identifier or nothing",
				.Invalid_Constaint_Name,
				get_position(n.value),
			)
		}
		// Process the constraint part
		process_constraint(n, binding)
	case:
		analyzer_error(
			"The binding name can either be a constraint or an identifier",
			.Invalid_Binding_Name,
			get_position(node),
		)
	}
}

// Analyzes and validates the value part of a binding
// Ensures the value is appropriate for the binding context
analyze_binding_value :: #force_inline proc(node: ^Node, binding: ^Binding) {
	if (node == nil) {
		analyzer_error(
			"A value was expexted for the binding got nothing",
			.Invalid_Binding_Value,
			Position{},
		)
		return
	}

	// Check each node type and either process it or report an error
	switch n in node {
	// These node types cannot be used as binding values
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
	case Expand:
		analyzer_error(
			"Cannot use a expand rule as a binding value",
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
	case Range:
		analyzer_error(
			"Cannot use a Range rule as a binding value",
			.Invalid_Binding_Value,
			n.position,
		)
	// These node types can be used as binding values
	case Pattern:
		process_pattern(n, binding)
	case ScopeNode:
		process_scope_node(n, binding)
	case Override:
		process_override(n, binding)
	case Identifier:
		process_identifier(n, binding)
	case Constraint:
		process_constraint(n, binding)
	case Operator:
		process_operator(n, binding)
	case Execute:
		process_execute(n)
	case Literal:
		process_literal(n, binding)
	case Property:
		process_property(n, binding)
	case External:
		process_external(n)
	}

}

// Processes a pointing push binding (name -> value)
process_pointing_push :: proc(node: Pointing) {
	binding := new(Binding)
	binding.name = ""
	binding.kind = .pointing_push
	analyze_binding_name(node.name, binding)
	add_binding(binding)
	analyze_binding_value(node.value, binding)
	typecheck_binding(binding, node.position)
}

// Processes a pointing pull binding (name <- value)
process_pointing_pull :: proc(node: PointingPull) {
	binding := new(Binding)
	binding.name = ""
	binding.kind = .pointing_pull
	analyze_binding_name(node.name, binding)
	add_binding(binding)
	analyze_binding_value(node.value, binding)
	typecheck_binding(binding, node.position)
}

// Processes an event push binding (optional name >> value)
process_event_push :: proc(node: EventPush) {
	binding := new(Binding)
	binding.name = ""
	binding.kind = .event_push
	// Event push bindings can have optional names
	if (node.name != nil) {
		analyze_binding_name(node.name, binding)
	}
	add_binding(binding)
	analyze_binding_value(node.value, binding)
	typecheck_binding(binding, node.position)
}

// Processes expand nodes (unpacking/spreading)
process_expand :: proc(node: Expand) {
	binding := new(Binding)
	binding.name = ""
	binding.kind = .inline_push
	// Event push bindings can have optional names
	if (node.target == nil) {
		analyzer_error(
			"Cannot use a Expand without a target value",
			.Invalid_Expand,
			node.position,
		)
		return
	}
	analyze_binding_value(node.target, binding)
	add_binding(binding)
	typecheck_binding(binding, get_position(node.target))
}


// Processes an event pull binding (name << value)
process_event_pull :: proc(node: EventPull) {
	binding := new(Binding)
	binding.name = ""
	binding.kind = .event_pull
	analyze_binding_name(node.name, binding)
	add_binding(binding)
	analyze_binding_value(node.value, binding)
	typecheck_binding(binding, node.position)
}

// Processes a resonance push binding (optional name ~> value)
process_resonance_push :: proc(node: ResonancePush) {
	binding := new(Binding)
	binding.name = ""
	binding.kind = .resonance_push
	// Resonance push bindings can have optional names
	if (node.name != nil) {
		analyze_binding_name(node.name, binding)
	}
	add_binding(binding)
	analyze_binding_value(node.value, binding)
	typecheck_binding(binding, node.position)
}

// Processes a resonance pull binding (name <~ value)
process_resonance_pull :: proc(node: ResonancePull) {
	binding := new(Binding)
	binding.name = ""
	binding.kind = .resonance_pull
	analyze_binding_name(node.name, binding)
	add_binding(binding)
	analyze_binding_value(node.value, binding)
	typecheck_binding(binding, node.position)
}

// Processes a product binding (produces output)
process_product :: proc(node: Product) {
	binding := new(Binding)
	binding.name = ""
	binding.kind = .product
	add_binding(binding)
	analyze_binding_value(node.value, binding)
	typecheck_binding(binding, node.position)
}

// Processes a scope node (block of statements)
// Creates a new scope, processes all contained statements, then pops the scope
process_scope_node :: proc(scope_node: ScopeNode, binding: ^Binding) {
	// Create a new scope for the block
	scope := new(ScopeData)
	scope.content = make([dynamic]^Binding, 0)

	// Associate the scope with the binding
	binding.value = scope

	// Enter the new scope
	push_scope(scope)

	// Process all statements in the scope
	for i := 0; i < len(scope_node.value); i += 1 {
		analyze_node(&scope_node.value[i])
	}

	// Exit the scope
	pop_scope()
}

// Processes an override binding (name = source { overrides... })
// Used for event pull bindings with source and override specifications
process_override :: proc(node: Override, binding: ^Binding) {
	if (binding.kind == .event_pull) {
		// Create a scope for the override
		scope := new(ScopeData)
		scope.content = make([dynamic]^Binding, 0)
		binding.value = scope
		push_scope(scope)

		// Process the source identifier
		#partial switch name in node.source {
		case Identifier:
			identifier := new(Binding)
			binding.name = name.name // Note: This looks like a bug - should be identifier.name
			binding.kind = .event_source
			add_binding(identifier)
		case:
			analyzer_error(
				"Only identifiers can be used in even push name binding",
				.Invalid_Binding_Name,
				get_position(node.source),
			)
		}

		// Process all override statements
		for i := 0; i < len(node.overrides); i += 1 {
			analyze_node(&node.overrides[i])
		}
		pop_scope()
	} else {
		analyze_binding_value(node.source, binding)
		#partial switch v in binding.value {
		case ^ScopeData:
		}
	}
}

// Processes an identifier reference
// Resolves the identifier to a symbol and assigns its value to the binding
process_identifier :: proc(identifier: Identifier, binding: ^Binding) {
	// Look up the identifier in the symbol table
	symbol := resolve_symbol(identifier.name)
	if (symbol == nil) {
		analyzer_error(
			fmt.tprintf("Undefined identifier named %s found", identifier.name),
			.Undefined_Identifier,
			identifier.position,
		)
		return
	}
	// Copy the symbol's value to this binding
	binding.value = symbol.value
}

// Processes a pattern node (pattern matching)
process_pattern :: proc(node: Pattern, binding: ^Binding) {
	// TODO(andrflor): Implement pattern processing
}

// Processes a branch node (conditional logic)
process_branch :: proc(node: Branch) {
	// TODO(andrflor): Implement branch processing
}

// Validates that a binding's value satisfies its type constraint
// If no value is provided, uses the constraint's default value
typecheck_binding :: #force_inline proc(binding: ^Binding, position: Position) {
	if (binding.constraint == nil) {
		return
	}

	if (binding.value == nil) {
		// No value provided, use the constraint's default
		binding.value = resolve_default(binding.constraint)
	} else {
		if (typecheck_by_constraint(binding.constraint, binding.value)) {
			return
		}
		// Replace the value with the default so that we can continue compiling
		binding.value = resolve_default(binding.constraint)
		analyzer_error("The constraint do not match the given value", .Type_Mismatch, position)
	}
}

typecheck_scope_content :: proc(
	constraints: []^Binding,
	value: []^Binding,
	inline_constr_index: int = 0,
) -> bool {
	for val in value {
		if !typecheck_scope_binding(val, constraints, inline_constr_index) {
			return false
		}
	}
	return true
}

typecheck_scope_binding :: proc(
	binding: ^Binding,
	constraint: []^Binding,
	inline_constr_index: int = 0,
) -> bool {
	if (binding.kind == .inline_push) {
		for innerBinding in binding.value.(^ScopeData).content {
			if (!typecheck_scope_binding(innerBinding, constraint)) {
				return false
			}
		}
	} else {
		if (len(constraint) == 0) {
			return false
		}
		constr := constraint[0]
		if (constr.kind == .inline_push) {

		} else {
			return typecheck(binding, constr)
		}
	}
	return true
}

typecheck :: proc(value: ^Binding, constraint: ^Binding) -> bool {
	if (value.name != constraint.name || value.kind != constraint.kind) {
		return false
	}
	if (constraint.constraint == nil) {
		return typecheck_by_value(constraint.value, value.value)
	} else {
		return typecheck_by_constraint(constraint.constraint, value.value)
	}
}


typecheck_by_constraint :: proc(constraint: ^ScopeData, value: ValueData) -> bool {
	for i in 0 ..< len(constraint.content) {
		if (constraint.content[i].kind == .product) {
			if typecheck_by_value(constraint.content[i].value, value) {
				return true
			}
		}
	}
	return false
}

// Recursively checks if a value matches a type constraint
// Returns true if the value is compatible with the constraint
typecheck_by_value :: proc(constraint: ValueData, value: ValueData) -> bool {
	switch constr in constraint {
	case ^ScopeData:
		#partial switch val in value {
		case ^ScopeData:
			return typecheck_scope_content(constr.content[:], val.content[:])
		case:
			return false
		}
	case ^StringData:
		// String constraints must match string values
		#partial switch val in value {
		case ^StringData:
			return true
		case:
			return false
		}
	case ^IntegerData:
		// Integer constraints must match integer values with size checking
		#partial switch val in value {
		case ^IntegerData:
			#partial switch val.kind {
			case .none:
				// Untyped integer - check if it fits in the constraint type
				switch constr.kind {
				case .none:
					return true
				case .u8:
					val.kind = .u8
					return val.content < 256
				case .i8:
					val.kind = .i8
					return val.content < 256
				case .u16:
					val.kind = .u16
					return val.content < 65536
				case .i16:
					val.kind = .i16
					return val.content < 65536
				case .u32:
					val.kind = .u32
					return val.content < 4294967296
				case .i32:
					val.kind = .i32
					return val.content < 4294967296
				case .u64:
					val.kind = .u64
					return true
				case .i64:
					val.kind = .i64
					return true
				}
			}
			// Typed integer - must match exactly or constraint must be untyped
			return constr.kind == .none || constr.kind == val.kind
		case:
			return false
		}
	case ^FloatData:
		// Float constraints must match float values
		#partial switch val in value {
		case ^FloatData:
			switch val.kind {
			case .none:
				// Untyped float - check precision requirements
				#partial switch constr.kind {
				case .f32:
					val.kind = .f32
					return val.content < 1 << 24 // Rough f32 precision limit
				case .f64:
					val.kind = .f64
				case:
					return true
				}
			case .f32:
				return true
			case .f64:
				// f64 cannot be constrained to f32
				#partial switch constr.kind {
				case .f32:
					return false
				case:
					return true
				}
			case:
				return false
			}
		case:
			return false
		}
	case ^BoolData:
		// Boolean constraints must match boolean values
		#partial switch val in value {
		case ^BoolData:
			return true
		case:
			return false
		}
	case Empty:
		// Empty constraints must match empty values
		#partial switch val in value {
		case Empty:
			return true
		case:
			return false
		}
	}
	return false
}


// Finds the default value for a constraint by looking for product bindings
resolve_default :: #force_inline proc(constraint: ^ScopeData) -> ValueData {
	for i in 0 ..< len(constraint.content) {
		if (constraint.content[i].kind == .product) {
			return constraint.content[i].value
		}
	}
	return empty
}

// Resolves a constraint node to a ScopeData structure
// Used for type constraint processing
resolve_constraint :: #force_inline proc(node: ^Node) -> ^ScopeData {
	#partial switch c in compile_time_resolve(node) {
	case ^ScopeData:
		return c
	}
	return &emptyScope
}

empty := Empty{}

// Empty scope used as a default when constraint resolution fails
emptyScope := ScopeData {
	content = make([dynamic]^Binding, 0),
}

shallow_copy_scope :: #force_inline proc(original: ^ScopeData) -> ^ScopeData {
	if original == nil do return nil

	scope := new(ScopeData)
	scope.content = make([dynamic]^Binding, len(original.content))
	copy(scope.content[:], original.content[:])
	return scope
}


// Executes a node at compile-time and returns the computed value
compile_time_execute :: proc(node: ^Node) -> ValueData {
	target := compile_time_resolve(node)
	#partial switch t in target {
	case ^ScopeData:
		for binding in t.content {
			if binding.kind == .product {
				return binding.value
			}
		}
	}
	return empty
}

compile_time_solve_binding_override :: #force_inline proc(
	target: ^ScopeData,
	override: PointingBase,
	kind: Binding_Kind,
) {
	#partial switch n in override.name {
	case Identifier:
		for binding, index in target.content {
			if binding.kind == kind && binding.name == n.name {
				target.content[index] = override_binding(binding, override.value)
				return
			}
		}
	case Literal:
		#partial switch n.kind {
		case .Integer:
			access_index, ok := strconv.parse_int(n.value)
			if (ok) {
				if access_index >= 0 && access_index < len(target.content) {
					if target.content[access_index].kind == kind {
						target.content[access_index] = override_binding(
							target.content[access_index],
							override.value,
						)
						return
					}
				}
			}
		}
	}
}

override_binding :: #force_inline proc(binding: ^Binding, value: ^Node) -> ^Binding {
	value := compile_time_resolve(value)
	if typecheck_by_value(binding.value, value) {
		overriden := new(Binding)
		overriden.value = value
		overriden.kind = binding.kind
		overriden.name = binding.name
		overriden.constraint = binding.constraint
		return overriden
	}
	return binding
}


// Applies overrides to a target value at compile-time
compile_time_override :: proc(target: ValueData, overrides: [dynamic]Node) -> ValueData {
	#partial switch t in target {
	case ^ScopeData:
		scope := shallow_copy_scope(t)
		for override, index in overrides {
			#partial switch o in override {
			case Pointing:
				compile_time_solve_binding_override(scope, o, .pointing_push)
			case PointingPull:
				compile_time_solve_binding_override(scope, o, .pointing_pull)
			case EventPush:
				compile_time_solve_binding_override(scope, o, .event_push)
			case EventPull:
				compile_time_solve_binding_override(scope, o, .event_pull)
			case ResonancePush:
				compile_time_solve_binding_override(scope, o, .resonance_push)
			case ResonancePull:
				compile_time_solve_binding_override(scope, o, .resonance_pull)
			case:
				if index < len(t.content) {
					scope.content[index] = override_binding(
						scope.content[index],
						&overrides[index],
					)
				}
			}
		}
	}

	analyzer_error(
		"Impossible to override with provided values",
		.Invalid_Property_Access,
		Position{},
	)
	return target
}

// Accesses a property of a target value at compile-time
compile_time_access :: proc(target: ValueData, property: ^Node) -> ValueData {
	#partial switch t in target {
	case ^ScopeData:
		#partial switch n in property {
		case Identifier:
			for binding in t.content {
				if binding.name == n.name {
					return binding.value
				}
			}
		case Literal:
			#partial switch n.kind {
			case .Integer:
				access_index, ok := strconv.parse_int(n.value)
				if (ok) {
					if access_index >= 0 && access_index < len(t.content) {
						return t.content[access_index].value
					}
				}
			}
		}
	}
	analyzer_error(
		"Impossible to find the property",
		.Invalid_Property_Access,
		get_position(property),
	)
	return nil
}

// Performs compile-time resolution of nodes to values
// Used for constraint evaluation and constant folding
compile_time_resolve :: proc(node: ^Node) -> ValueData {
	#partial switch n in node {
	case External:
		return compile_time_resolve(n.scope)
	case Execute:
		return compile_time_execute(n.value)
	case ScopeNode:
		scope := new(ScopeData)
		// TODO(andrflor): make the parsing maybe??
		for node in n.value {

		}
		return scope
	case Override:
		target := compile_time_resolve(n.source)
		if target != nil {
			return compile_time_override(target, n.overrides)
		}
	case Property:
		target := compile_time_resolve(n.source)
		if target != nil {
			return compile_time_access(target, n.property)
		}
	case Identifier:
		symbol := resolve_symbol(n.name)
		if symbol == nil {
			analyzer_error(
				fmt.tprintf("Undefined identifier named %s found", n.name),
				.Undefined_Identifier,
				n.position,
			)
		}
		return symbol.value
	case:
		analyzer_error(
			"The : constraint value must be a valid form",
			.Invalid_Constaint_Value,
			get_position(node),
		)
	}
	return nil
}

// Processes a constraint node (name : constraint)
// Sets up type constraints for bindings
process_constraint :: #force_inline proc(node: Constraint, binding: ^Binding) {
	if (node.constraint == nil) {
		analyzer_error(
			"Constraint node without a specific constraint is not allowed",
			.Invalid_Constaint,
			get_position(node.value),
		)
	}

	// Resolve the constraint to a scope
	binding.constraint = resolve_constraint(node.constraint)

	if (node.value == nil) {
		return
	}

	// Process the constrained value
	#partial switch n in node.value {
	case Identifier:
		binding.name = n.name
	case Override:
		#partial switch o in n.source {
		case Identifier:
			binding.name = o.name
		case:
			analyzer_error(
				"Override for constraint named should be using identifier",
				.Invalid_Binding_Name,
				get_position(node.value),
			)
		}
	//TODO(andrflor)(andrflor): need to handle overrides
	case:
		analyzer_error(
			"Constraint should be only applied to identifier with or without overrides or be empty",
			.Invalid_Binding_Name,
			get_position(node.value),
		)
	}
}

// Processes operator nodes (arithmetic, logical, etc.)
process_operator :: proc(node: Operator, binding: ^Binding) {
	// TODO(andrflor): Implement operator processing
}

// Processes execution blocks
process_execute :: proc(node: Execute) {
	// TODO(andrflor): Implement execution block processing
}

// Processes literal values (numbers, strings, booleans)
// Converts string representations to typed data structures
process_literal :: proc(node: Literal, binding: ^Binding) {
	switch node.kind {
	case .Integer:
		value := new(IntegerData)
		content, ok := strconv.parse_int(node.value)
		if (ok) {
			value.content = u64(content)
		}
		value.kind = .none
		binding.value = value
	case .Float:
		value := new(FloatData)
		content, ok := strconv.parse_f64(node.value)
		if (ok) {
			value.content = content
		}
		value.kind = .none
		binding.value = value
	case .String:
		value := new(StringData)
		value.content = node.value
		binding.value = value
	case .Bool:
		value := new(BoolData)
		value.content = node.value == "true"
		binding.value = value
	case .Hexadecimal:
		value := new(IntegerData)
		content, ok := strconv.parse_int(node.value, 16)
		if (ok) {
			value.content = u64(content)
		}
		value.kind = .none
		binding.value = value
	case .Binary:
		value := new(IntegerData)
		content, ok := strconv.parse_int(node.value, 2)
		if (ok) {
			value.content = u64(content)
		}
		value.kind = .none
		binding.value = value
	}
}

// Processes property access nodes (object.property)
process_property :: proc(node: Property, binding: ^Binding) {
	analyze_binding_value(node.source, binding)
	#partial switch v in binding.value {
	case ^ScopeData:
		#partial switch n in node.property {
		case Identifier:
			for bind in v.content {
				if bind.name == n.name {
					binding.value = bind.value
					return
				}
			}
		case Literal:
			#partial switch n.kind {
			case .Integer:
				access_index, ok := strconv.parse_int(n.value)
				if (ok) {
					if access_index >= 0 && access_index < len(v.content) {
						binding.value = v.content[access_index].value
						return
					}
				}
			}

		}
	}
	analyzer_error(
		"Impossible to find the property",
		.Invalid_Property_Access,
		get_position(node.property),
	)
}


// Processes external reference nodes
process_external :: proc(node: External) {
	// TODO(andrflor): Implement external reference processing
}

// Processes range nodes (1..10, etc.)
process_range :: proc(node: Range) {
	// TODO(andrflor): Implement range processing
}

// Resolves a named symbol within a specific binding's scope
// Used for override resolution
resolve_named_override_symbol :: #force_inline proc(name: string, binding: ^Binding) -> ^Binding {
	if (binding.value == nil) {
		return nil
	}
	#partial switch scope in binding.value {
	case ^ScopeData:
		for i := 0; i < len(scope.content); i += 1 {
			if scope.content[i].name == name {
				return scope.content[i]
			}
		}
	}
	return nil
}

// Resolves a named symbol within a specific binding's scope
// Used for property access (searches from end to beginning for shadowing)
resolve_named_property_symbol :: #force_inline proc(name: string, binding: ^Binding) -> ^Binding {
	if (binding.value == nil) {
		return nil
	}
	#partial switch scope in binding.value {
	case ^ScopeData:
		// Search from end to beginning to handle variable shadowing
		for i := len(scope.content) - 1; i >= 0; i -= 1 {
			if scope.content[i].name == name {
				return scope.content[i]
			}
		}
	}
	return nil
}

// Internal recursive symbol resolution function
// Searches through the scope stack from a specific index downward
_resolve_symbol :: proc(name: string, index: int = 0) -> ^Binding {
	if index < 0 {
		return nil
	}

	scope := (^Analyzer)(context.user_ptr).stack[index]
	// Search the current scope from end to beginning (for shadowing)
	for i := len(scope.content) - 1; i >= 0; i -= 1 {
		if scope.content[i].name == name {
			return scope.content[i]
		}
	}

	// If not found in current scope, search parent scope
	return _resolve_symbol(name, index - 1)
}

// Public interface for symbol resolution
// Searches through all scopes starting from the current scope
resolve_symbol :: #force_inline proc(name: string) -> ^Binding {
	return _resolve_symbol(name, len((^Analyzer)(context.user_ptr).stack) - 1)
}

// Reports an analyzer error with message, type, and position
analyzer_error :: proc(message: string, error_type: Analyzer_Error_Type, position: Position) {
	analyzer := (^Analyzer)(context.user_ptr)

	error := Analyzer_Error {
		type     = error_type,
		message  = message,
		position = position,
	}

	append(&analyzer.errors, error)
}

get_position :: #force_inline proc(node: ^Node) -> Position {
	return (^NodeBase)(node).position
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
		if (level != 0) {
			debug_scope(scope, level - 1, verbose)
		}
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

	for binding, i in scope.content {
		if (binding != nil) {
			debug_binding(binding, level + 1, i, verbose)
		}
	}
}

debug_raw_bindings :: proc(bindings: ^[dynamic]^Binding, level: int, verbose: bool = false) {
	indent := strings.repeat("  ", level)
	fmt.printf("%RawBindings [%d] - %d bindings:\n", indent, level, len(bindings))

	for binding, i in bindings {
		if (binding != nil) {
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
		#partial switch v.kind {
		case .u8:
			return "u8"
		case .i8:
			return "i8"
		case .u16:
			return "u16"
		case .i16:
			return "i16"
		case .u32:
			return "u32"
		case .i32:
			return "i32"
		case .u64:
			return "u64"
		case .i64:
			return "i64"
		}
		return "Integer"
	case ^FloatData:
		#partial switch v.kind {
		case .f32:
			return "f32"
		case .f64:
			return "f64"
		}
		return "Float"
	case ^BoolData:
		return "bool"
	case Empty:
		return "none"
	}
	return "Unknown"
}

// Debug ValueData contents
debug_value_data :: proc(value: ValueData, indent_level: int) {
	indent := strings.repeat("  ", indent_level)

	switch v in value {
	case ^ScopeData:
		fmt.println()
		debug_scope(v, indent_level, true)
	case ^StringData:
		fmt.printf("('%s')\n", v.content)
	case ^IntegerData:
		fmt.printf("(%d)\n", v.content)
	case ^FloatData:
		fmt.printf("(%f)\n", v.content)
	case ^BoolData:
		fmt.printf("(%t)\n", v.content)
	case Empty:
		fmt.printf("(none)\n")
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
	case .event_source:
		return "EventSource"
	case .resonance_push:
		return "ResonancePush"
	case .resonance_pull:
		return "ResonancePull"
	case .inline_push:
		return "Inline"
	case .product:
		return "Product"
	case:
		return "Unknown"
	}
}
