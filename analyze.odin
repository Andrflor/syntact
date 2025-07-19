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
	name:           string, // The identifier name of the binding
	kind:           Binding_Kind, // What type of binding this is (push/pull/event/etc.)
	constraint:     ^ScopeData, // Optional type constraint for the binding
	owner:          ^ScopeData,
	symbolic_value: ValueData, // The actual value/data associated with this binding
	static_value:   ValueData,
}


// Union type representing all possible value types in the language
// This is the core data representation for runtime values
ValueData :: union {
	^ScopeData, // Reference to a scope (nested bindings)
	^StringData, // String literal value
	^IntegerData, // Integer literal value
	^FloatData, // Float literal value
	^BoolData, // Boolean literal value
	^PropertyData,
	^RangeData,
	^ExecuteData,
	^OverrideData,
	^RefData,
	^BinaryOpData,
	^ReactiveData,
	^EffectData,
	^UnaryOpData,
	Empty, // Empty/null value
}

ReactiveData :: struct {
	initial: ValueData,
}

EffectData :: struct {
	placeholder: ValueData,
}

PropertyData :: struct {
	source: ValueData,
	prop:   string,
}

BinaryOpData :: struct {
	left:    ValueData,
	right:   ValueData,
	oprator: Operator_Kind,
}

UnaryOpData :: struct {
	value:   ValueData,
	oprator: Operator_Kind,
}

OverrideData :: struct {
	target:    ValueData,
	overrides: [dynamic]^Binding,
}

ExecuteData :: struct {
	target:   ValueData,
	wrappers: [dynamic]ExecutionWrapper, // Ordered list of execution wrappers (from outside to inside)
}

RefData :: struct {
	refered: ^Binding,
}

RangeData :: struct {
	start: ValueData, // must be evaluable to integer
	end:   ValueData, // must be evaluable to integer
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
	Invalid_Execute,
	Invalid_operator,
	Invalid_Range,
	Default,
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
	binding.owner =
		(^Analyzer)(context.user_ptr).stack[len((^Analyzer)(context.user_ptr).stack) - 1]
	append(&binding.owner.content, binding)
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
	if ast != nil {
		if scope, ok := ast.(ScopeNode); ok {
			for i in 0 ..< len(scope.value) {
				analyze_node(&scope.value[i])
			}
		} else {
			analyzer_error("Root should be a scope", .Default, get_position(ast))
		}
	}

	// Print debug information about the analysis results
	debug_analyzer(&analyzer, true)

	// Return true if no errors were found
	return len(analyzer.errors) == 0
}

// Recursive procedure to analyze individual AST nodes
// Dispatches to specific processing procedures based on node type
analyze_node :: proc(node: ^Node) {
	binding := new(Binding)
	add_binding(binding)
	#partial switch n in node {
	case EventPull:
		binding.kind = .event_pull
		analyze_name(n.name, binding)
		binding.symbolic_value, binding.static_value = analyze_value(n.value)
	case EventPush:
		binding.kind = .event_push
		analyze_name(n.name, binding)
		binding.symbolic_value, binding.static_value = analyze_value(n.value)
	case ResonancePush:
		binding.kind = .resonance_push
		analyze_name(n.name, binding)
		binding.symbolic_value, binding.static_value = analyze_value(n.value)
	case ResonancePull:
		binding.kind = .resonance_pull
		binding.symbolic_value, binding.static_value = analyze_value(n.value)
	case Pointing:
		binding.kind = .pointing_push
		analyze_name(n.name, binding)
		binding.symbolic_value, binding.static_value = analyze_value(n.value)
	case PointingPull:
		binding.kind = .pointing_pull
		analyze_name(n.name, binding)
		binding.symbolic_value, binding.static_value = analyze_value(n.value)
	case Product:
		binding.kind = .product
		binding.symbolic_value, binding.static_value = analyze_value(n.value)
	case Constraint:
		binding.kind = .pointing_push
		analyze_name(node, binding)
	case Expand:
		process_expand_value(n.target, binding)
	case:
		binding.kind = .pointing_push
		binding.symbolic_value, binding.static_value = analyze_value(node)
	}
}

process_expand_value :: proc(node: ^Node, binding: ^Binding) {
	#partial switch n in node {
	case EventPull:
		analyze_name(n.name, binding)
		binding.symbolic_value, binding.static_value = analyze_value(n.value)
	case EventPush:
		analyze_name(n.name, binding)
		binding.symbolic_value, binding.static_value = analyze_value(n.value)
	case ResonancePush:
		analyze_name(n.name, binding)
		binding.symbolic_value, binding.static_value = analyze_value(n.value)
	case ResonancePull:
		analyze_name(n.name, binding)
		binding.symbolic_value, binding.static_value = analyze_value(n.value)
	case Pointing:
		analyze_name(n.name, binding)
		binding.symbolic_value, binding.static_value = analyze_value(n.value)
	case PointingPull:
		analyze_name(n.name, binding)
		binding.symbolic_value, binding.static_value = analyze_value(n.value)
	case Product:
		binding.symbolic_value, binding.static_value = analyze_value(n.value)
	case Constraint:
		analyze_name(node, binding)
	case Expand:
		analyzer_error("Nested expands are not allowed", .Invalid_Expand, n.position)
		process_expand_value(n.target, binding)
	case:
		binding.symbolic_value, binding.static_value = analyze_value(node)
	}
}

analyze_name :: proc(node: ^Node, binding: ^Binding) {
	#partial switch n in node {
	case Constraint:
		if (n.value != nil) {
			#partial switch v in n.value {
			case Identifier:
				binding.name = v.name
			}
			analyzer_error(
				"The : constraint indicator must be followed by an identifier or nothing",
				.Invalid_Constaint_Name,
				get_position(n.value),
			)
		}
		if (n.constraint == nil) {
			analyzer_error(
				"Constraint node without a specific constraint is not allowed",
				.Invalid_Constaint,
				get_position(node),
			)
			return
		}
		analyze_constraint(n.constraint, binding)
	case Identifier:
		binding.name = n.name
	case:
		analyzer_error(
			"Cannot use anything other than constraint or identifier as binding name",
			.Invalid_Binding_Name,
			get_position(node),
		)

	}
}

analyze_constraint :: proc(node: ^Node, binding: ^Binding) {
}

analyze_value :: proc(node: ^Node) -> (ValueData, ValueData) {
	switch n in node {
	case EventPull,
	     EventPush,
	     ResonancePush,
	     ResonancePull,
	     Pointing,
	     PointingPull,
	     Product,
	     Expand,
	     Constraint:
		analyzer_error(
			"Cannot use a binding definition has a binding value",
			.Invalid_Binding_Value,
			get_position(node),
		)
		return empty, empty
	case Branch:
		analyzer_error(
			"We should not find a branch outside a pattern node",
			.Invalid_Binding_Value,
			get_position(node),
		)
		return empty, empty
	case ScopeNode:
		scope := new(ScopeData)
		scope.content = make([dynamic]^Binding, 0)
		push_scope(scope)
		for i in 0 ..< len(n.value) {
			analyze_node(&n.value[i])
		}
		pop_scope()
		return scope, scope
	case Override:
		override := new(OverrideData)
		target, static_target := analyze_value(n.source)
		override.target = target
		if scope, ok := static_target.(^ScopeData); ok {
			// TODO(andrflor): process override check and static override
			static_override := scope
			return override, static_override
		} else {
			analyzer_error(
				"Trying to override an element that does no resolve to a scope",
				.Invalid_Override,
				n.position,
			)
			return target, static_target
		}
	case Identifier:
		symbol := resolve_symbol(n.name)
		if (symbol == nil) {
			analyzer_error(
				fmt.tprintf("Undefined identifier named %s found", n.name),
				.Undefined_Identifier,
				n.position,
			)
			return empty, empty
		}
		ref := new(RefData)
		ref.refered = symbol
		return ref, ref.refered.static_value
	case Property:
		if identifier, ok := n.property.(Identifier); ok {
			prop := new(PropertyData)
			prop.prop = identifier.name
			source, static_source := analyze_value(n.source)
			if scope, ok := static_source.(^ScopeData); ok {
				for binding in scope.content {
					if binding.name == identifier.name {
						return prop, binding.static_value
					}
				}
			} else {
				analyzer_error(
					fmt.tprintf("There is no property %s", identifier.name),
					.Invalid_Property_Access,
					n.position,
				)
				return empty, empty
			}
			return prop, empty
		}
		analyzer_error(
			"Invalid property access without identifier",
			.Invalid_Property_Access,
			n.position,
		)
		return empty, empty
	case Pattern:
		source := analyze_value(n.target)
	case Operator:
		if (n.left == nil) {
			op := new(UnaryOpData)
			value, static_value := analyze_value(n.right)
			switch n.kind {
			case .Subtract:
			case .Not:

			case .Add,
			     .Multiply,
			     .Divide,
			     .Mod,
			     .Equal,
			     .Less,
			     .Greater,
			     .NotEqual,
			     .LessEqual,
			     .GreaterEqual,
			     .And,
			     .Or,
			     .Xor,
			     .RShift,
			     .LShift:
				analyzer_error(
					"Operator should not be used as unary",
					.Invalid_operator,
					n.position,
				)
				return value, static_value
			}
			op.value = value
			op.oprator = n.kind
			return op
		}
		if (n.right == nil) {
			op := new(UnaryOpData)
			op.value = analyze_value(n.left)
			op.oprator = n.kind
			return op
		}
		switch n.kind {
		case .Not:
			analyzer_error("Cannot use not as binary operator", .Invalid_operator, n.position)
			return empty, empty
		case .Add:
		case .Subtract:
		case .Multiply:
		case .Divide:
		case .Mod:
		case .Less:
			return analyze_ordering_operator(n, less_than)
		case .Greater:
			return analyze_ordering_operator(n, greater_than)
		case .LessEqual:
			return analyze_ordering_operator(n, less_equal)
		case .GreaterEqual:
			return analyze_ordering_operator(n, greater_equal)
		case .Equal:
		case .NotEqual:
		case .And:
		case .Or:
		case .Xor:
		case .RShift:
		case .LShift:
		}

	case Execute:
		exec := new(ExecuteData)
		target, static_target := analyze_value(n.value)
		exec.target = target
		exec.wrappers = n.wrappers
		if scope, ok := static_target.(^ScopeData); ok {
			for binding in scope.content {
				if binding.kind == .product {
					return exec, binding.static_value
				}
			}
		}
		return exec, empty
	case Literal:
		switch n.kind {
		case .Integer:
			value := new(IntegerData)
			content, ok := strconv.parse_int(n.value)
			if (ok) {
				value.content = u64(content)
			}
			value.kind = .none
			return value, value
		case .Float:
			value := new(FloatData)
			content, ok := strconv.parse_f64(n.value)
			if (ok) {
				value.content = content
			}
			value.kind = .none
			return value, value
		case .String:
			value := new(StringData)
			value.content = n.value
			return value, value
		case .Bool:
			value := new(BoolData)
			value.content = n.value == "true"
			return value, value
		case .Hexadecimal:
			value := new(IntegerData)
			content, ok := strconv.parse_int(n.value, 16)
			if (ok) {
				value.content = u64(content)
			}
			value.kind = .none
			return value, value
		case .Binary:
			value := new(IntegerData)
			content, ok := strconv.parse_int(n.value, 2)
			if (ok) {
				value.content = u64(content)
			}
			value.kind = .none
			return value, value
		}
	case External:
		ref := new(RefData)
		//TODO(andrflor): resolve the ref
		return ref, empty
	case Range:
		range := new(RangeData)
		start, static_start := analyze_value(n.start)
		end, static_end := analyze_value(n.end)
		start_data, start_ok := static_start.(^IntegerData)
		end_data, end_ok := static_end.(^IntegerData)
		range.start = start
		range.end = end
		static_range := new(RangeData)
		static_range.start = static_start
		static_range.end = static_end

		if !start_ok || !end_ok {
			analyzer_error(
				"Trying to create a range with a non integer value",
				.Invalid_Range,
				n.position,
			)
		}

		return range, static_range

	}
	return empty, empty
}

empty := Empty{}

string_to_u64 :: proc(s: string) -> u64 {
	bytes := transmute([]u8)s
	if len(bytes) > 8 {
		return max(u64)
	}

	result: u64 = 0
	for b in bytes {
		result = (result << 8) + cast(u64)b
	}

	return result
}

less_than :: #force_inline proc(a, b: $T) -> bool {return a < b}
greater_than :: #force_inline proc(a, b: $T) -> bool {return a > b}
less_equal :: #force_inline proc(a, b: $T) -> bool {return a <= b}
greater_equal :: #force_inline proc(a, b: $T) -> bool {return a >= b}
equal :: #force_inline proc(a, b: $T) -> bool {return a == b}
not_equal :: #force_inline proc(a, b: $T) -> bool {return a != b}

analyze_ordering_operator :: #force_inline proc(
	node: Operator,
	compare_func: proc(left, right: $T) -> bool,
) -> (
	ValueData,
	ValueData,
) {
	op := new(BinaryOpData)
	left, static_left := analyze_value(node.left)
	right, static_right := analyze_value(node.right)
	op.oprator = node.kind
	op.left = left
	op.right = right

	#partial switch l in static_left {
	case ^IntegerData:
		#partial switch r in static_right {
		case ^IntegerData:
			boolData := new(BoolData)
			boolData.content = compare_func(l.content, r.content)
			return op, boolData
		case ^FloatData:
			boolData := new(BoolData)
			boolData.content = compare_func(cast(f64)l.content, r.content)
			return op, boolData
		case ^StringData:
			boolData := new(BoolData)
			boolData.content = compare_func(l.content, string_to_u64(r.content))
			return op, boolData
		}
	case ^FloatData:
		#partial switch r in static_right {
		case ^IntegerData:
			boolData := new(BoolData)
			boolData.content = compare_func(l.content, cast(f64)r.content)
			return op, boolData
		case ^FloatData:
			boolData := new(BoolData)
			boolData.content = compare_func(l.content, r.content)
			return op, boolData
		case ^StringData:
			boolData := new(BoolData)
			boolData.content = compare_func(l.content, cast(f64)string_to_u64(r.content))
			return op, boolData
		}
	case ^StringData:
		#partial switch r in static_right {
		case ^IntegerData:
			boolData := new(BoolData)
			boolData.content = compare_func(string_to_u64(l.content), r.content)
			return op, boolData
		case ^FloatData:
			boolData := new(BoolData)
			boolData.content = compare_func(cast(f64)string_to_u64(l.content), r.content)
			return op, boolData
		case ^StringData:
			boolData := new(BoolData)
			boolData.content = compare_func(string_to_u64(l.content), string_to_u64(r.content))
			return op, boolData
		}
	}
	analyzer_error(
		fmt.tprintf(
			"Cannot use %s operator on anything else than string integer or float",
			node.kind,
		),
		.Invalid_operator,
		node.position,
	)
	return empty, empty
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

// Resolves a named symbol within a specific binding's scope
// Used for property access (searches from end to beginning for shadowing)
resolve_named_property_symbol :: #force_inline proc(name: string, binding: ^Binding) -> ^Binding {
	if (binding.symbolic_value == nil) {
		return nil
	}
	#partial switch scope in binding.symbolic_value {
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
			debug_binding(binding, level + 1, i)
		}
	}
}

debug_raw_bindings :: proc(bindings: ^[dynamic]^Binding, level: int, verbose: bool = false) {
	indent := strings.repeat("  ", level)
	fmt.printf("%RawBindings [%d] - %d bindings:\n", indent, level, len(bindings))

	for binding, i in bindings {
		if (binding != nil) {
			debug_binding(binding, level + 1, i)
		}
	}
}

// Compact debug function using inline representation (but expands scopes)
debug_binding :: proc(binding: ^Binding, indent_level: int, index: int) {
	indent := strings.repeat("  ", indent_level)
	kind_str := binding_kind_to_string(binding.kind)
	fmt.printf("%s[%d] %s '%s'", indent, index, kind_str, binding.name)
	if binding.constraint != nil {
		fmt.printf(" (constrained)")
	}
	if binding.symbolic_value != nil {
		// Check if it's a scope
		if scope_data, is_scope := binding.symbolic_value.(^ScopeData); is_scope {
			fmt.printf(" -> Scope(%d bindings)\n", len(scope_data.content))
			debug_scope(scope_data, indent_level + 1, false)
		} else {
			inline_repr := debug_value_inline(binding.symbolic_value)
			if inline_repr != "" {
				fmt.printf(" = %s\n", inline_repr)
			} else {
				fmt.printf(" -> %s\n", debug_value_type(binding.symbolic_value))
			}
		}
	} else {
		fmt.println()
	}
}

// Enhanced debug function that shows both type and data inline (except for scopes)
debug_value_inline :: proc(value: ValueData) -> string {
	switch v in value {
	case ^ScopeData:
		// Scopes should not be inlined - they need to show their contents
		return "" // This signals that scope should be handled separately
	case ^StringData:
		return fmt.tprintf("String(\"%s\")", v.content)
	case ^IntegerData:
		return fmt.tprintf("%s(%d)", debug_value_type(value), v.content)
	case ^FloatData:
		return fmt.tprintf("%s(%f)", debug_value_type(value), v.content)
	case ^BoolData:
		return fmt.tprintf("bool(%t)", v.content)
	case ^PropertyData:
		source_inline := debug_value_inline(v.source)
		if source_inline == "" {
			return fmt.tprintf("Property(<scope>.%s)", v.prop)
		}
		return fmt.tprintf("Property(%s.%s)", source_inline, v.prop)
	case ^ReactiveData:
		return fmt.tprintf("Reactive(%s)", debug_value_inline(v.initial))
	case ^EffectData:
		return fmt.tprintf("Reactive(%s)", debug_value_inline(v.placeholder))
	case ^RangeData:
		start_inline := debug_value_inline(v.start)
		end_inline := debug_value_inline(v.end)
		if start_inline == "" || end_inline == "" {
			return "Range(<complex>)"
		}
		return fmt.tprintf("Range(%s..%s)", start_inline, end_inline)
	case ^ExecuteData:
		target_inline := debug_value_inline(v.target)
		if target_inline == "" {
			return "Execute(<scope>)"
		}
		return fmt.tprintf("Execute(%s)", target_inline)
	case ^RefData:
		if v.refered != nil {
			return fmt.tprintf("Ref(%s)", v.refered.name)
		}
		return "Ref(<nil>)"
	case ^BinaryOpData:
		left_inline := debug_value_inline(v.left)
		right_inline := debug_value_inline(v.right)
		if left_inline == "" || right_inline == "" {
			return fmt.tprintf("BinaryOp(%v)", v.oprator)
		}
		return fmt.tprintf("BinaryOp(%s %v %s)", left_inline, v.oprator, right_inline)
	case ^UnaryOpData:
		value_inline := debug_value_inline(v.value)
		if value_inline == "" {
			return fmt.tprintf("UnaryOp(%v)", v.oprator)
		}
		return fmt.tprintf("UnaryOp(%v %s)", v.oprator, value_inline)
	case Empty:
		return "Empty"
	}
	return "Unknown"
}

// Get the type name of a ValueData
debug_value_type :: proc(value: ValueData) -> string {
	switch v in value {
	case ^ScopeData:
		return fmt.tprintf("Scope(%d bindings)", len(v.content))
	case ^ReactiveData:
		return "Rx"
	case ^EffectData:
		return "Eff"
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
	case ^PropertyData:
		return "Property"
	case ^RangeData:
		return "Range"
	case ^ExecuteData:
		return "Execute"
	case ^RefData:
		return "Ref"
	case ^BinaryOpData:
		return "BinaryOp"
	case ^UnaryOpData:
		return "UnaryOp"
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
	case .inline_push:
		return "Inline"
	case .product:
		return "Product"
	case:
		return "Unknown"
	}
}
