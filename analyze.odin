package compiler

import "core:fmt"
import "core:slice"
import "core:strconv"
import "core:strings"

// Main analyzer structure that maintains the analysis state
// Contains error tracking and a scope stack for symbol resolution
Analyzer :: struct {
	errors:          [dynamic]Analyzer_Error, // Collection of semantic errors found during analysis
	warnings:        [dynamic]Analyzer_Error, // Collection of warnings found during analysis
	stack:           [dynamic]^ScopeData, // Stack of nested scopes for symbol resolution
	pending_binding: ^Binding,
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
	content:  u64, // The actual integer value
	kind:     IntegerKind, // Specific integer type (u8, i32, etc.)
	negative: bool,
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
	Invalid_Event_Pull,
	Invalid_Binding_Value, // Invalid value for binding
	Invalid_Expand,
	Invalid_Execute,
	Invalid_operator,
	Invalid_Range,
	Infinite_Recursion,
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
	add_binding(data)
	append(&(^Analyzer)(context.user_ptr).stack, data)
}

curr_scope :: #force_inline proc() -> ^ScopeData {
	stack := (^Analyzer)(context.user_ptr).stack
	return stack[len(stack) - 1]
}

pending_binding :: #force_inline proc() -> ^Binding {
	return (^Analyzer)(context.user_ptr).pending_binding
}

set_pending_binding :: #force_inline proc(binding: ^Binding) {
	(^Analyzer)(context.user_ptr).pending_binding = binding
}

curr_binding :: #force_inline proc() -> ^Binding {
	scope := curr_scope()
	return scope.content[len(scope.content) - 1]
}

// Pops the current scope from the scope stack
// Used when exiting nested scopes
pop_scope :: #force_inline proc() {
	pop(&(^Analyzer)(context.user_ptr).stack)
}

// Adds a binding to the current (top) scope
// New bindings are always added to the most recent scope
add_binding :: #force_inline proc(scope: ^ScopeData = nil) {
	binding := pending_binding()
	if binding != nil {
		set_pending_binding(nil)
		binding.owner = curr_scope()
		if (scope != nil) {
			binding.static_value = scope
			binding.symbolic_value = scope
		}
		append(&binding.owner.content, binding)
	}
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


copy_scope :: proc(original: ^ScopeData, allocator := context.allocator) -> ^ScopeData {
	new_scope := new(ScopeData, allocator)
	new_scope.content = make([dynamic]^Binding, len(original.content), allocator)
	for binding, i in original.content {
		new_scope.content[i] = binding
	}
	return new_scope
}

// Deep copy function for ValueData
copy_value_data :: proc(original: ValueData, allocator := context.allocator) -> ValueData {
	switch data in original {
	case ^ScopeData:
		new_scope := new(ScopeData, allocator)
		new_scope.content = make([dynamic]^Binding, len(data.content), allocator)
		for binding, i in data.content {
			new_scope.content[i] = copy_binding(binding, allocator)
		}
		return new_scope

	case ^StringData:
		new_string := new(StringData, allocator)
		new_string.content = strings.clone(data.content, allocator)
		return new_string

	case ^IntegerData:
		new_int := new(IntegerData, allocator)
		new_int^ = data^ // Copy all fields (content, kind, negative)
		return new_int

	case ^FloatData:
		new_float := new(FloatData, allocator)
		new_float^ = data^ // Copy all fields (content, kind)
		return new_float

	case ^BoolData:
		new_bool := new(BoolData, allocator)
		new_bool.content = data.content
		return new_bool

	case ^PropertyData:
		new_prop := new(PropertyData, allocator)
		new_prop.source = copy_value_data(data.source, allocator)
		new_prop.prop = strings.clone(data.prop, allocator)
		return new_prop

	case ^RangeData:
		new_range := new(RangeData, allocator)
		new_range.start = copy_value_data(data.start, allocator)
		new_range.end = copy_value_data(data.end, allocator)
		return new_range

	case ^ExecuteData:
		new_execute := new(ExecuteData, allocator)
		new_execute.target = copy_value_data(data.target, allocator)
		new_execute.wrappers = data.wrappers
		return new_execute

	case ^OverrideData:
		new_override := new(OverrideData, allocator)
		new_override.target = copy_value_data(data.target, allocator)
		new_override.overrides = make([dynamic]^Binding, len(data.overrides), allocator)
		for binding, i in data.overrides {
			new_override.overrides[i] = copy_binding(binding, allocator)
		}
		return new_override

	case ^RefData:
		new_ref := new(RefData, allocator)
		new_ref.refered = data.refered
		return new_ref

	case ^BinaryOpData:
		new_binop := new(BinaryOpData, allocator)
		new_binop.left = copy_value_data(data.left, allocator)
		new_binop.right = copy_value_data(data.right, allocator)
		new_binop.oprator = data.oprator
		return new_binop

	case ^ReactiveData:
		new_reactive := new(ReactiveData, allocator)
		new_reactive.initial = copy_value_data(data.initial, allocator)
		return new_reactive

	case ^EffectData:
		new_effect := new(EffectData, allocator)
		new_effect.placeholder = copy_value_data(data.placeholder, allocator)
		return new_effect

	case ^UnaryOpData:
		new_unary := new(UnaryOpData, allocator)
		new_unary.value = copy_value_data(data.value, allocator)
		new_unary.oprator = data.oprator
		return new_unary

	case Empty:
		return Empty{}
	}

	return Empty{}
}


// Deep copy function for Binding
copy_binding :: proc(original: ^Binding, allocator := context.allocator) -> ^Binding {
	new_binding := new(Binding, allocator)
	new_binding.name = strings.clone(original.name, allocator)
	new_binding.kind = original.kind
	new_binding.owner = original.owner
	new_binding.constraint = original.constraint

	// Copy the symbolic and static values
	new_binding.symbolic_value = copy_value_data(original.symbolic_value, allocator)
	new_binding.static_value = copy_value_data(original.static_value, allocator)

	return new_binding
}


// Recursive procedure to analyze individual AST nodes
// Dispatches to specific processing procedures based on node type
analyze_node :: proc(node: ^Node) {
	binding := new(Binding)
	set_pending_binding(binding)
	#partial switch n in node {
	case EventPull:
		binding.kind = .event_pull
		if (n.name == nil) {
			analyzer_error(
				"Event pulling must have a Event descriptor left",
				.Invalid_Event_Pull,
				get_position(node),
			)
		} else {

		}
		binding.symbolic_value = empty
		binding.static_value = empty
		analyzer_error("Missing binding name", .Invalid_Binding_Value, get_position(node))
		analyze_name(n.name, binding)
		bind_value(binding, n.value)
	case EventPush:
		binding.kind = .event_push
		if (n.name != nil) {
			analyze_name(n.name, binding)
		}
		if (n.value == nil) {
			binding.symbolic_value = empty
			binding.static_value = empty
			analyzer_error("Missing binding value", .Invalid_Binding_Value, get_position(node))
		} else {
			bind_value(binding, n.value)
		}
	case ResonancePush:
		binding.kind = .resonance_push
		if (n.name == nil) {
			binding.symbolic_value = empty
			binding.static_value = empty
			analyzer_error("Missing binding name", .Invalid_Binding_Value, get_position(node))
		} else {
			analyze_name(n.name, binding)
		}
		if (n.value == nil) {
			binding.symbolic_value = empty
			binding.static_value = empty
			analyzer_error("Missing binding value", .Invalid_Binding_Value, get_position(node))
		} else {
			bind_value(binding, n.value)
		}
	case ResonancePull:
		binding.kind = .resonance_pull
		if (n.name == nil) {
			binding.symbolic_value = empty
			binding.static_value = empty
			analyzer_error("Missing binding name", .Invalid_Binding_Value, get_position(node))
		} else {
			analyze_name(n.name, binding)
		}
		if (n.value == nil) {
			binding.symbolic_value = empty
			binding.static_value = empty
			analyzer_error("Missing binding value", .Invalid_Binding_Value, get_position(node))
		} else {
			bind_value(binding, n.value)
		}
	case Pointing:
		binding.kind = .pointing_push
		if (n.name == nil) {
			binding.symbolic_value = empty
			binding.static_value = empty
			analyzer_error("Missing binding name", .Invalid_Binding_Value, get_position(node))
		} else {
			analyze_name(n.name, binding)
		}
		if (n.value == nil) {
			binding.symbolic_value = empty
			binding.static_value = empty
			analyzer_error("Missing binding value", .Invalid_Binding_Value, get_position(node))
		} else {
			bind_value(binding, n.value)
		}
	case PointingPull:
		binding.kind = .pointing_pull
		if (n.name == nil) {
			binding.symbolic_value = empty
			binding.static_value = empty
			analyzer_error("Missing binding name", .Invalid_Binding_Value, get_position(node))
		} else {
			analyze_name(n.name, binding)
		}
		if (n.value == nil) {
			binding.symbolic_value = empty
			binding.static_value = empty
			analyzer_error("Missing binding value", .Invalid_Binding_Value, get_position(node))
		} else {
			bind_value(binding, n.value)
		}
	case Product:
		binding.kind = .product
		if (n.value == nil) {
			binding.symbolic_value = empty
			binding.static_value = empty
			analyzer_error("Missing binding value", .Invalid_Binding_Value, get_position(node))
		} else {
			bind_value(binding, n.value)
		}
	case Constraint:
		binding.kind = .pointing_push
		analyze_name(node, binding)
	case Expand:
		process_expand_value(n.target, binding)
	case:
		binding.kind = .pointing_push
		bind_value(binding, node)
	}
	typecheck_binding(binding, node)
	add_binding()
}

bind_value :: #force_inline proc(binding: ^Binding, node: ^Node) {
	binding.symbolic_value, binding.static_value = analyze_value(node)
	if s, ok := binding.static_value.(^ScopeData); ok {
		analyze_scope_recursive_properties(s)
	}
}

typecheck_binding :: proc(binding: ^Binding, node: ^Node) {
	if binding.constraint == nil {
		if binding.static_value == nil {
			binding.static_value = empty
			binding.symbolic_value = empty
		}
		return
	}

	if binding.static_value == nil {
		binding.static_value = resolve_default(binding.constraint)
		binding.symbolic_value = binding.static_value
		return
	}

	if typecheck_by_constraint(binding.constraint, binding.static_value) {
		return
	}

	analyzer_error("Type are not matching", .Type_Mismatch, get_position(node))
	binding.static_value = resolve_default(binding.constraint)
	binding.symbolic_value = binding.static_value
}

typecheck_by_constraint :: proc(constraint: ^ScopeData, value: ValueData) -> bool {
	isEmptyConstraint := true
	for binding in constraint.content {
		if binding.kind == .product {
			isEmptyConstraint = false
			if binding.constraint != nil {
				if (typecheck_by_constraint(binding.constraint, value)) {
					return true
				}
			} else if typecheck_by_value(binding.static_value, value) {
				return true
			}
		}
	}
	if value == empty {
		return isEmptyConstraint
	}
	return false
}

check_constraint_compatibility :: proc(constraint: ^ScopeData, value: ^ScopeData) -> bool {
	for valBind in value.content {
		if valBind.kind == .product {
			if valBind.constraint != nil {
				if (!check_constraint_compatibility(constraint, valBind.constraint)) {
					return false
				}
			} else {
				if (!typecheck_by_constraint(constraint, valBind.static_value)) {
					return false
				}
			}
		}
	}
	return true
}

resolve_default :: #force_inline proc(constraint: ValueData) -> ValueData {
	#partial switch c in constraint {
	case ^ScopeData:
		for i in 0 ..< len(c.content) {
			if (c.content[i].kind == .product) {
				return c.content[i].static_value
			}
		}
	}
	return empty
}

typecheck_scope :: proc(constraint: []^Binding, value: []^Binding) -> bool {
	if len(value) != len(constraint) {
		return false
	}
	for i in 0 ..< len(value) {
		if value[i].kind != constraint[i].kind || value[i].name != constraint[i].name {
			return false
		}
		if constraint[i].constraint != nil {
			if value[i].constraint != nil {
				if !check_constraint_compatibility(constraint[i].constraint, value[i].constraint) {
					return false
				}
			}
			if !typecheck_by_constraint(constraint[i].constraint, value[i].static_value) {
				return false
			}
		}
	}
	return true
}

typecheck_float :: #force_inline proc(val: ^FloatData, constr: ^FloatData) -> bool {
	switch val.kind {
	case .none:
		#partial switch constr.kind {
		case .f32:
			if val.content < 1 << 24 { 	// Rough f32 precision limit
				val.kind = .f32
				return true
			}
			return false
		case .f64:
			val.kind = .f64
			return true
		case:
			return true
		}
	case .f32:
		return true
	case .f64:
		#partial switch constr.kind {
		case .f32:
			return false
		case:
			return true
		}
	case:
		return false
	}
}

typecheck_int :: #force_inline proc(val: ^IntegerData, constr: ^IntegerData) -> bool {
	#partial switch val.kind {
	case .none:
		// Untyped integer - check if it fits in the constraint type
		switch constr.kind {
		case .none:
			return true
		case .u8:
			if val.negative == false && val.content < 256 {
				val.kind = .u8
				return true
			}
			return false
		case .i8:
			if val.content < 256 {
				val.kind = .i8
				return true
			}
			return false
		case .u16:
			if val.negative == false && val.content < 65536 {
				val.kind = .u16
				return true
			}
			return false
		case .i16:
			if val.content < 65536 {
				val.kind = .i16
				return true
			}
			return false
		case .u32:
			if val.negative == false && val.content < 4294967296 {
				val.kind = .u32
				return true
			}
			return false
		case .i32:
			if val.content < 4294967296 {
				val.kind = .i32
				return true
			}
			return false
		case .u64:
			if val.negative == false {
				val.kind = .u64
				return true
			}
			return false
		case .i64:
			val.kind = .i64
			return true
		}
	}
	// Typed integer - must match exactly or constraint must be untyped
	return constr.kind == .none || constr.kind == val.kind
}


typecheck_by_value :: proc(constraint: ValueData, value: ValueData) -> bool {
	#partial switch constr in constraint {
	case ^ScopeData:
		#partial switch val in value {
		case ^ScopeData:
			return typecheck_scope(constr.content[:], val.content[:])
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
		#partial switch val in value {
		case ^IntegerData:
			return typecheck_int(val, constr)
		case:
			return false
		}
	case ^FloatData:
		#partial switch val in value {
		case ^FloatData:
			return typecheck_float(val, constr)
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

process_expand_value :: proc(node: ^Node, binding: ^Binding) {
	#partial switch n in node {
	case EventPull:
		analyze_name(n.name, binding)
		bind_value(binding, n.value)
	case EventPush:
		if (n.name != nil) {
			analyze_name(n.name, binding)
		}
		bind_value(binding, n.value)
	case ResonancePush:
		analyze_name(n.name, binding)
		bind_value(binding, n.value)
	case ResonancePull:
		analyze_name(n.name, binding)
		bind_value(binding, n.value)
	case Pointing:
		analyze_name(n.name, binding)
		bind_value(binding, n.value)
	case PointingPull:
		analyze_name(n.name, binding)
		bind_value(binding, n.value)
	case Product:
		bind_value(binding, n.value)
	case Constraint:
		analyze_name(node, binding)
	case Expand:
		analyzer_error("Nested expands are not allowed", .Invalid_Expand, n.position)
		process_expand_value(n.target, binding)
	case:
		bind_value(binding, node)
	}
}

analyze_name :: proc(node: ^Node, binding: ^Binding) {
	#partial switch n in node {
	case Constraint:
		if (n.value != nil) {
			#partial switch v in n.value {
			case Identifier:
				binding.name = v.name
			case Override:
				if i, ok := v.source.(Identifier); ok {
					binding.name = i.name
				} else {
					analyzer_error(
						"The : constraint indicator must be followed by an identifier or nothing",
						.Invalid_Constaint_Name,
						get_position(n.value),
					)
				}
			case ScopeNode:
			// We have a anonymous value
			case:
				analyzer_error(
					"The : constraint indicator must be followed by an identifier or nothing",
					.Invalid_Constaint_Name,
					get_position(n.value),
				)
			}
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


analyze_scope_recursive_properties :: proc(scope: ^ScopeData) {
	// TODO: check for deep nested and indirect recursion
	for binding in scope.content {
		if binding.kind == .product {
			if (binding.constraint == scope) {
				analyzer_error(
					"Infinite recursion you need a base case",
					.Infinite_Recursion,
					Position{},
				)
				scope.content = make([dynamic]^Binding, 0)
				return
			}
			if s, ok := binding.static_value.(^ScopeData); ok {
				for bind in s.content {
					if (bind.constraint == scope) {
						analyzer_error(
							"Infinite recursion you need a base case",
							.Infinite_Recursion,
							Position{},
						)
						scope.content = make([dynamic]^Binding, 0)
						return
					}
				}
			}
			return
		}
	}
}

analyze_constraint :: proc(node: ^Node, binding: ^Binding) {
	constraint, static_constraint := analyze_value(node)
	#partial switch c in static_constraint {
	case ^ScopeData:
		binding.constraint = c
	}
}

analyze_override :: proc(node: ^Node) -> ^Binding {
	// TODO(andrflor): return nil binding when needed and add analyzer errors when doing so
	// TODO(andrlofr): make analyze name and analyze value for overrides
	binding := new(Binding)
	#partial switch n in node {
	case EventPull:
		binding.kind = .event_pull
		analyze_name(n.name, binding)
		bind_value(binding, n.value)
	case EventPush:
		binding.kind = .event_push
		analyze_name(n.name, binding)
		bind_value(binding, n.value)
	case ResonancePush:
		binding.kind = .resonance_push
		analyze_name(n.name, binding)
		bind_value(binding, n.value)
	case ResonancePull:
		binding.kind = .resonance_pull
		bind_value(binding, n.value)
	case Pointing:
		binding.kind = .pointing_push
		analyze_name(n.name, binding)
		bind_value(binding, n.value)
	case PointingPull:
		binding.kind = .pointing_pull
		analyze_name(n.name, binding)
		bind_value(binding, n.value)
	case Product:
		binding.kind = .product
		bind_value(binding, n.value)
	case Constraint:
		return nil
	case Expand:
		return nil
	case:
		binding.kind = .pointing_push
		bind_value(binding, node)
	}
	return binding
}

BindSwap::struct {
  old: ^Binding,
  new: ^Binding,
}

index_override :: #force_inline proc(
	target: ^ScopeData,
	index: int,
	override: ^Binding,
) -> BindSwap {
	skip := 0
	for i in 0 ..< len(target.content) {
		if target.content[i].kind != .pointing_push {
			skip += 1
		} else if i == index + skip {
			overriden := target.content[i]
			target.content[i] = copy_binding(overriden)
			target.content[i].symbolic_value = override.symbolic_value
			target.content[i].static_value = override.static_value
      return BindSwap{old=overriden, new=target.content[i]}
		}
	}
	return BindSwap{}
}



name_override :: #force_inline proc(target: ^ScopeData, override: ^Binding) -> BindSwap {
	for binding, i in target.content {
		if binding.name == override.name {
			if binding.kind == override.kind {
				overriden := target.content[i]
				target.content[i] = copy_binding(overriden)
				target.content[i].symbolic_value = override.symbolic_value
				target.content[i].static_value = override.static_value
				return BindSwap{old=overriden, new=target.content[i]}
			} else {
				analyzer_error(
					fmt.tprintf("Binding kind mismatch for %s", override.name),
					.Invalid_Override,
					Position{},
				)
			}
			return BindSwap{}
		}
	}
	analyzer_error(
		fmt.tprintf("Property %s not found", override.name),
		.Invalid_Override,
		Position{},
	)
	return BindSwap{}
}

reeval_overriden_scope :: #force_inline proc(target: ^ScopeData, swapped: ^[dynamic]BindSwap) {
	for binding, i in target.content {
    symbolic_value, static_value := replace_references_and_collapse(binding.symbolic_value, swapped)
    if static_value != binding.static_value {
      target.content[i] = copy_binding(binding)
      target.content[i].symbolic_value = symbolic_value
      target.content[i].static_value = static_value
      append(swapped, BindSwap{old=binding, new=target.content[i]})
    }
	}
}

apply_override :: proc(target: ValueData, overrides: [dynamic]^Binding) -> ValueData {
	switch t in target {
	case ^ScopeData:
		swapped := make([dynamic]BindSwap, 0)
		for i in 0 ..< len(overrides) {
			if overrides[i].name == "" {
				swap := index_override(t, i, overrides[i])
				if (swap.old != nil) {
					append(&swapped, swap)
				}
			} else {
				// TODO: sucessive name override over the same value override the second one
				swap := name_override(t, overrides[i])
				if (swap.old != nil) {
					append(&swapped, swap)
				}
			}
		}
		if len(swapped) > 0 {
			reeval_overriden_scope(t, &swapped)
		}

	case ^StringData:
		if (len(overrides) == 1 &&
			   overrides[0].name == "" &&
			   overrides[0].kind == .pointing_push) {
			if s, ok := overrides[0].static_value.(^StringData); ok {
				t.content = s.content
				return t
			}
		}
		analyzer_error("Override for string should just be string", .Invalid_Override, Position{})
	case ^IntegerData:
		if (len(overrides) == 1 &&
			   overrides[0].name == "" &&
			   overrides[0].kind == .pointing_push) {
			if i, ok := overrides[0].static_value.(^IntegerData); ok {
				if typecheck_int(t, i) {
					t.content = i.content
					t.kind = i.kind
					t.negative = i.negative
					return t
				}
			}
		}
		analyzer_error("Override for int should just be string", .Invalid_Override, Position{})
	case ^FloatData:
		if (len(overrides) == 1 &&
			   overrides[0].name == "" &&
			   overrides[0].kind == .pointing_push) {
			if f, ok := overrides[0].static_value.(^FloatData); ok {
				if typecheck_float(t, f) {
					t.content = f.content
					t.kind = f.kind
					return t
				}
			}
		}
		analyzer_error("Override for float should just be string", .Invalid_Override, Position{})
	case ^BoolData:
		if (len(overrides) == 1 &&
			   overrides[0].name == "" &&
			   overrides[0].kind == .pointing_push) {
			if b, ok := overrides[0].static_value.(^BoolData); ok {
				t.content = b.content
				return t
			}
		}
		analyzer_error("Override for boolean should just be string", .Invalid_Override, Position{})
	case ^PropertyData,
	     ^RangeData,
	     ^ExecuteData,
	     ^OverrideData,
	     ^RefData,
	     ^BinaryOpData,
	     ^ReactiveData,
	     ^EffectData,
	     ^UnaryOpData:
		analyzer_error(
			"Those dynamic elements should ne be used here",
			.Invalid_Override,
			Position{},
		)
	case Empty:
		analyzer_error(
			"Cannot override someting that resolve to empty",
			.Invalid_Override,
			Position{},
		)
	}
	return target
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
	     Expand:
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
	case Constraint:
		constraint, static_constraint := analyze_value(n.constraint)
		if c, ok := static_constraint.(^ScopeData); ok {
			add_binding()
			binding := curr_binding()
			if binding.constraint == nil {
				binding.constraint = c
			}
		}
		value := resolve_default(static_constraint)
		if n.value == nil {
			return value, value
		} else {
			if s, ok := n.value.(ScopeNode); ok {
				// TODO(andrflor): apply override here?
			} else {
				analyzer_error(
					"Value for constraint data should be override",
					.Invalid_Constaint,
					n.position,
				)
			}
			return value, value
		}
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
		target, static_target := analyze_value(n.source)
		if scope, ok := static_target.(^ScopeData); ok {
			override := new(OverrideData)
			override.target = target
			override.overrides = make([dynamic]^Binding, 0)
			for i in 0 ..< len(n.overrides) {
				binding := analyze_override(&n.overrides[i])
				if (binding != nil) {
					append(&override.overrides, binding)
				}
			}
			return override, apply_override(copy_scope(scope), override.overrides)
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
		source, static_source := analyze_value(n.target)
	case Operator:
		if (n.left == nil) {
			return analyze_unary_operator(n, n.right)
		}
		if (n.right == nil) {
			return analyze_unary_operator(n, n.left)
		}
		switch n.kind {
		case .Not:
			analyzer_error("Cannot use not as binary operator", .Invalid_operator, n.position)
			return empty, empty
		case .Add:
			return analyze_math_operator(n)
		case .Subtract:
			return analyze_math_operator(n)
		case .Multiply:
			return analyze_math_operator(n)
		case .Divide:
			return analyze_math_operator(n)
		case .Mod:
			return analyze_math_operator(n)
		case .And:
			return analyze_bitwise_operator(n)
		case .Or:
			return analyze_bitwise_operator(n)
		case .Xor:
			return analyze_bitwise_operator(n)
		case .Less:
			return analyze_ordering_operator(n)
		case .Greater:
			return analyze_ordering_operator(n)
		case .LessEqual:
			return analyze_ordering_operator(n)
		case .GreaterEqual:
			return analyze_ordering_operator(n)
		case .Equal:
			return analyze_equal_operator(n)
		case .NotEqual:
			op, bool := analyze_equal_operator(n)
			#partial switch b in bool {
			case ^BoolData:
				b.content = !b.content
				return op, b
			}
			return op, bool
		case .RShift:
			return analyze_int_operator(n)
		case .LShift:
			return analyze_int_operator(n)
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
		content := resolver.files[n.name]
		return empty, empty
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


compare_func :: #force_inline proc(a, b: $T, kind: Operator_Kind) -> bool {
	#partial switch kind {
	case .Less:
		return a < b
	case .Greater:
		return a > b
	case .LessEqual:
		return a <= b
	case .GreaterEqual:
		return a >= b
	}
	return false
}

analyze_unary_operator :: #force_inline proc(
	node: Operator,
	child: ^Node,
) -> (
	ValueData,
	ValueData,
) {

	op := new(UnaryOpData)
	value, static_value := analyze_value(child)
	op.value = value
	op.oprator = node.kind
	switch node.kind {
	case .Subtract:
		#partial switch v in static_value {
		case ^IntegerData:
			#partial switch v.kind {
			case .u8, .u16, .u32, .u64:
				analyzer_error("Cannot sub on an unsigned int", .Invalid_operator, node.position)
				return value, static_value
			}
			static_int := new(IntegerData)
			static_int.kind = v.kind
			static_int.content = v.content
			static_int.negative = true
			return op, static_int
		case ^FloatData:
			static_float := new(FloatData)
			static_float.kind = v.kind
			static_float.content = -v.content
			return op, static_float
		case:
			analyzer_error(
				"Cannot sub anything else than float or int",
				.Invalid_operator,
				node.position,
			)
		}
	case .Not:
		#partial switch v in static_value {
		case ^IntegerData:
			static_int := new(IntegerData)
			static_int.content = ~v.content
			return op, static_int
		case ^BoolData:
			static_bool := new(BoolData)
			static_bool.content = !v.content
			return op, static_bool
		}
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
		analyzer_error("Operator should not be used as unary", .Invalid_operator, node.position)
		return value, static_value
	}
	return value, static_value
}

analyze_math_operator :: #force_inline proc(node: Operator) -> (ValueData, ValueData) {
	op := new(BinaryOpData)
	left, static_left := analyze_value(node.left)
	right, static_right := analyze_value(node.right)
	op.oprator = node.kind
	op.left = left
	op.right = right

	#partial switch r in static_right {
	case ^IntegerData:
		#partial switch l in static_left {
		case ^IntegerData:
			if (l.kind == r.kind || l.kind == .none || r.kind == .none) {
				static_int := new(IntegerData)
				#partial switch node.kind {
				case .Add:
					static_int.content = l.content + r.content
					return op, static_int
				case .Divide:
					static_int.content = l.content / r.content
					return op, static_int
				case .Subtract:
					static_int.content = l.content - r.content
					return op, static_int
				case .Mod:
					static_int.content = l.content % r.content
					return op, static_int
				case .Multiply:
					static_int.content = l.content * r.content
					return op, static_int
				}
			} else {
				analyzer_error(
					fmt.tprintf("Icompatible integer types for %s", node.kind),
					.Invalid_operator,
					node.position,
				)
				return empty, empty
			}
		}
	case ^FloatData:
		#partial switch l in static_left {
		case ^FloatData:
			if (l.kind == r.kind || l.kind == .none || r.kind == .none) {
				static_float := new(FloatData)
				#partial switch node.kind {
				case .Add:
					static_float.content = l.content + r.content
					return op, static_float
				case .Divide:
					static_float.content = l.content / r.content
					return op, static_float
				case .Subtract:
					static_float.content = l.content - r.content
					return op, static_float
				case .Mod:
					analyzer_error(
						fmt.tprintf("Mod is only allowed with integers", node.kind),
						.Invalid_operator,
						node.position,
					)
					return empty, empty
				case .Multiply:
					static_float.content = l.content * r.content
					return op, static_float
				}
			} else {
				analyzer_error(
					fmt.tprintf("Icompatible float types for %s", node.kind),
					.Invalid_operator,
					node.position,
				)
				return empty, empty
			}
		}
	}
	analyzer_error(
		fmt.tprintf("Icompatible types for %s", node.kind),
		.Invalid_operator,
		node.position,
	)
	return empty, empty
}


analyze_bitwise_operator :: #force_inline proc(node: Operator) -> (ValueData, ValueData) {
	op := new(BinaryOpData)
	left, static_left := analyze_value(node.left)
	right, static_right := analyze_value(node.right)
	op.oprator = node.kind
	op.left = left
	op.right = right

	#partial switch r in static_right {
	case ^IntegerData:
		#partial switch l in static_left {
		case ^IntegerData:
			if (l.kind == r.kind || l.kind == .none || r.kind == .none) {
				static_int := new(IntegerData)
				#partial switch node.kind {
				case .Or:
					static_int.content = l.content | r.content
					return op, static_int
				case .Xor:
					static_int.content = l.content ~ r.content
					return op, static_int
				case .And:
					static_int.content = l.content & r.content
					return op, static_int
				}
			} else {
				analyzer_error(
					fmt.tprintf("Icompatible integer types for %s", node.kind),
					.Invalid_operator,
					node.position,
				)
				return empty, empty
			}
		}
	case ^BoolData:
		#partial switch l in static_left {
		case ^BoolData:
			static_bool := new(BoolData)
			#partial switch node.kind {
			case .Or:
				static_bool.content = r.content | l.content
				return op, static_bool
			case .Xor:
				static_bool.content = r.content ~ l.content
				return op, static_bool
			case .And:
				static_bool.content = r.content & l.content
				return op, static_bool
			}
		}
	}
	analyzer_error(
		fmt.tprintf("Icompatible types for %s", node.kind),
		.Invalid_operator,
		node.position,
	)
	return empty, empty
}

analyze_equal_operator :: #force_inline proc(node: Operator) -> (ValueData, ValueData) {
	op := new(BinaryOpData)
	left, static_left := analyze_value(node.left)
	right, static_right := analyze_value(node.right)
	op.oprator = node.kind
	op.left = left
	op.right = right

	#partial switch r in static_right {
	case ^IntegerData:
		#partial switch l in static_left {
		case ^IntegerData:
			boolean := new(BoolData)
			if (r.kind == .none || l.kind == .none) {
				boolean.content = r.content == l.content
			} else {
				boolean.content = r.kind == l.kind && r.content == l.content
			}
			return op, boolean
		case ^FloatData:
			boolean := new(BoolData)
			boolean.content = false
			return op, boolean
		case ^ScopeData:
			boolean := new(BoolData)
			boolean.content = false
			return op, boolean
		case ^BoolData:
			boolean := new(BoolData)
			boolean.content = false
			return op, boolean
		case ^StringData:
			boolean := new(BoolData)
			boolean.content = false
			return op, boolean
		}
	case ^FloatData:
		#partial switch l in static_left {
		case ^IntegerData:
			boolean := new(BoolData)
			boolean.content = false
			return op, boolean
		case ^FloatData:
			boolean := new(BoolData)
			if (r.kind == .none || l.kind == .none) {
				boolean.content = r.content == l.content
			} else {
				boolean.content = r.kind == l.kind && r.content == l.content
			}
			return op, boolean
		case ^ScopeData:
			boolean := new(BoolData)
			boolean.content = false
			return op, boolean
		case ^BoolData:
			boolean := new(BoolData)
			boolean.content = false
			return op, boolean
		case ^StringData:
			boolean := new(BoolData)
			boolean.content = false
			return op, boolean
		}
	case ^ScopeData:
		#partial switch l in static_left {
		case ^IntegerData:
			boolean := new(BoolData)
			boolean.content = false
			return op, boolean
		case ^FloatData:
			boolean := new(BoolData)
			boolean.content = false
			return op, boolean
		case ^ScopeData:
			boolean := new(BoolData)
			rlen := len(r.content)
			llen := len(l.content)
			if (rlen != llen) {
				boolean.content = false
			} else {
				for i in 0 ..< llen {
					right := r.content[i]
					left := l.content[i]
					if (right.kind != left.kind ||
						   right.name != left.name ||
						   right.static_value != left.static_value) {
						boolean.content = false
						break
					}
				}
				boolean.content = true
			}
			return op, boolean
		case ^BoolData:
			boolean := new(BoolData)
			boolean.content = false
			return op, boolean
		case ^StringData:
			boolean := new(BoolData)
			boolean.content = false
			return op, boolean
		}
	case ^BoolData:
		#partial switch l in static_left {
		case ^IntegerData:
			boolean := new(BoolData)
			boolean.content = false
			return op, boolean
		case ^FloatData:
			boolean := new(BoolData)
			boolean.content = false
			return op, boolean
		case ^ScopeData:
			boolean := new(BoolData)
			boolean.content = false
			return op, boolean
		case ^BoolData:
			boolean := new(BoolData)
			boolean.content = l.content == r.content
			return op, boolean
		case ^StringData:
			boolean := new(BoolData)
			boolean.content = false
			return op, boolean
		}
	case ^StringData:
		#partial switch l in static_left {
		case ^IntegerData:
			boolean := new(BoolData)
			boolean.content = false
			return op, boolean
		case ^FloatData:
			boolean := new(BoolData)
			boolean.content = false
			return op, boolean
		case ^ScopeData:
			boolean := new(BoolData)
			boolean.content = false
			return op, boolean
		case ^BoolData:
			boolean := new(BoolData)
			boolean.content = false
			return op, boolean
		case ^StringData:
			boolean := new(BoolData)
			boolean.content = r.content == l.content
			return op, boolean
		}
	}
	analyzer_error(
		fmt.tprintf("Invalid static value for %s", node.kind),
		.Invalid_operator,
		node.position,
	)
	return empty, empty
}


analyze_int_operator :: #force_inline proc(node: Operator) -> (ValueData, ValueData) {
	op := new(BinaryOpData)
	left, static_left := analyze_value(node.left)
	right, static_right := analyze_value(node.right)
	op.oprator = node.kind
	op.left = left
	op.right = right

	#partial switch r in static_right {
	case ^IntegerData:
		#partial switch l in static_left {
		case ^IntegerData:
			#partial switch op.oprator {
			case .LShift:
				integer := new(IntegerData)
				integer.kind = l.kind
				integer.content = l.content << r.content
				return op, integer
			case .RShift:
				integer := new(IntegerData)
				integer.kind = l.kind
				integer.content = l.content >> r.content
				return op, integer
			case:
				analyzer_error(
					fmt.tprintf("Use of invalid %s as a shifting operator", node.kind),
					.Invalid_operator,
					node.position,
				)
				return empty, empty
			}
		case:
			analyzer_error(
				fmt.tprintf("Cannot %s with a %s value", node.kind, debug_value_type(static_left)),
				.Invalid_operator,
				node.position,
			)
			return empty, empty
		}
	case:
		analyzer_error(
			fmt.tprintf(
				"Cannot %s with a %s increment",
				node.kind,
				debug_value_type(static_right),
			),
			.Invalid_operator,
			node.position,
		)
		return empty, empty
	}
	return empty, empty
}


analyze_ordering_operator :: #force_inline proc(node: Operator) -> (ValueData, ValueData) {
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
			boolData.content = compare_func(l.content, r.content, node.kind)
			return op, boolData
		case ^FloatData:
			boolData := new(BoolData)
			boolData.content = compare_func(cast(f64)l.content, r.content, node.kind)
			return op, boolData
		case ^StringData:
			boolData := new(BoolData)
			boolData.content = compare_func(l.content, string_to_u64(r.content), node.kind)
			return op, boolData
		}
	case ^FloatData:
		#partial switch r in static_right {
		case ^IntegerData:
			boolData := new(BoolData)
			boolData.content = compare_func(l.content, cast(f64)r.content, node.kind)
			return op, boolData
		case ^FloatData:
			boolData := new(BoolData)
			boolData.content = compare_func(l.content, r.content, node.kind)
			return op, boolData
		case ^StringData:
			boolData := new(BoolData)
			boolData.content = compare_func(
				l.content,
				cast(f64)string_to_u64(r.content),
				node.kind,
			)
			return op, boolData
		}
	case ^StringData:
		#partial switch r in static_right {
		case ^IntegerData:
			boolData := new(BoolData)
			boolData.content = compare_func(string_to_u64(l.content), r.content, node.kind)
			return op, boolData
		case ^FloatData:
			boolData := new(BoolData)
			boolData.content = compare_func(
				cast(f64)string_to_u64(l.content),
				r.content,
				node.kind,
			)
			return op, boolData
		case ^StringData:
			boolData := new(BoolData)
			boolData.content = compare_func(
				string_to_u64(l.content),
				string_to_u64(r.content),
				node.kind,
			)
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

	// Debug symbolic_value
	if binding.symbolic_value != nil {
		// Check if it's a scope
		if scope_data, is_scope := binding.symbolic_value.(^ScopeData); is_scope {
			fmt.printf(" -> Scope(%d bindings)", len(scope_data.content))
		} else {
			inline_repr := debug_value_inline(binding.symbolic_value)
			if inline_repr != "" {
				fmt.printf(" = %s", inline_repr)
			} else {
				fmt.printf(" -> %s", debug_value_type(binding.symbolic_value))
			}
		}
	}

	// Debug static_value
	if binding.static_value != nil {
		fmt.printf(" | ")

		static_inline := debug_value_inline(binding.static_value)
		if static_inline != "" {
			fmt.printf("%s", static_inline)
		} else {
			fmt.printf("%s", debug_value_type(binding.static_value))
		}
	}

	fmt.println()

	// Expand scope if present in symbolic_value
	if binding.symbolic_value != nil {
		if scope_data, is_scope := binding.symbolic_value.(^ScopeData); is_scope {
			debug_scope(scope_data, indent_level + 1, false)
		}
	}
}

// Enhanced debug function that shows both type and data inline (except for scopes)
debug_value_inline :: proc(value: ValueData) -> string {
	switch v in value {
	case ^ScopeData:
		// Scopes should not be inlined - they need to show their contents
		return "" // This signals that scope should be handled separately
	case ^OverrideData:
		return ""
	case ^StringData:
		return fmt.tprintf("String(\"%s\")", v.content)
	case ^IntegerData:
		if (v.negative) {
			return fmt.tprintf("%s(-%d)", debug_value_type(value), v.content)
		} else {
			return fmt.tprintf("%s(%d)", debug_value_type(value), v.content)
		}
	case ^FloatData:
		return fmt.tprintf("%s(%f, %s)", debug_value_type(value), v.content, v.kind)
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
	case ^OverrideData:
		return "Override"
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

// Only modifies values if references are found and need replacement
replace_references_and_collapse :: proc(symbolic: ValueData, swapped: ^[dynamic]BindSwap) -> (ValueData, ValueData) {
	switch s in symbolic {
	case ^ScopeData:
		// Check if any binding in scope needs reference replacement
		needs_update := false
		for binding in s.content {
			if binding != nil && contains_references(binding.symbolic_value, swapped) {
				needs_update = true
				break
			}
		}

		if !needs_update {
			return s, s
		}

		// Create new scope with updated bindings
		new_scope := copy_scope(s)
		for binding in new_scope.content {
			if binding != nil {
				binding.symbolic_value, binding.static_value = replace_references_and_collapse(binding.symbolic_value, swapped)
			}
		}
		return new_scope, new_scope

	case ^StringData, ^IntegerData, ^FloatData, ^BoolData, Empty:
		// Primitive values have no references - return unchanged
		return symbolic, symbolic

	case ^RefData:
		// Check if this reference needs to be swapped
    for swap in swapped {
      if swap.old == s.refered {

        new_ref := new(RefData)
        new_ref.refered = swap.new
        return new_ref, swap.new.static_value
      }
    }

		// Reference unchanged
		if s.refered != nil {
			return s, s.refered.static_value
		}
		return s, empty

	case ^PropertyData:
		// Check if source contains references
		new_source, static_source := replace_references_and_collapse(s.source, swapped)

		// If source unchanged, return original
		if new_source == s.source {
			// Try to resolve property from original static value
			if scope, ok := static_source.(^ScopeData); ok {
				for binding in scope.content {
					if binding.name == s.prop {
						return s, binding.static_value
					}
				}
			}
			return s, empty
		}

		// Source changed, create new property
		new_prop := new(PropertyData)
		new_prop.source = new_source
		new_prop.prop = s.prop

		// Resolve property from new static source
		if scope, ok := static_source.(^ScopeData); ok {
			for binding in scope.content {
				if binding.name == s.prop {
					return new_prop, binding.static_value
				}
			}
		}
		return new_prop, empty

	case ^BinaryOpData:
		// Check both operands
		new_left, static_left := replace_references_and_collapse(s.left, swapped)
		new_right, static_right := replace_references_and_collapse(s.right, swapped)

		// If nothing changed, return original
		if new_left == s.left && new_right == s.right {
			// Evaluate with original static values
			static_result := evaluate_binary_op(static_left, static_right, s.oprator)
			return s, static_result
		}

		// Create new binary op
		new_binop := new(BinaryOpData)
		new_binop.left = new_left
		new_binop.right = new_right
		new_binop.oprator = s.oprator

		// Evaluate with new static values
		static_result := evaluate_binary_op(static_left, static_right, s.oprator)
		return new_binop, static_result

	case ^UnaryOpData:
		// Check operand
		new_value, static_value := replace_references_and_collapse(s.value, swapped)

		// If nothing changed, return original
		if new_value == s.value {
			static_result := evaluate_unary_op(static_value, s.oprator)
			return s, static_result
		}

		// Create new unary op
		new_unary := new(UnaryOpData)
		new_unary.value = new_value
		new_unary.oprator = s.oprator

		// Evaluate with new static value
		static_result := evaluate_unary_op(static_value, s.oprator)
		return new_unary, static_result

	case ^OverrideData:
		// Check target
		new_target, static_target := replace_references_and_collapse(s.target, swapped)

		// Check overrides
		overrides_changed := false
		new_overrides := make([dynamic]^Binding, len(s.overrides))
		for override, i in s.overrides {
			if contains_references(override.symbolic_value, swapped) {
				overrides_changed = true
				new_override := copy_binding(override)
				new_override.symbolic_value, new_override.static_value = replace_references_and_collapse(override.symbolic_value, swapped)
				new_overrides[i] = new_override
			} else {
				new_overrides[i] = override
			}
		}

		// If nothing changed, return original with applied overrides
		if new_target == s.target && !overrides_changed {
			static_result := apply_override(static_target, s.overrides)
			return s, static_result
		}

		// Create new override
		new_override_data := new(OverrideData)
		new_override_data.target = new_target
		new_override_data.overrides = new_overrides

		// Apply overrides to get static result
		static_result := apply_override(static_target, new_overrides)
		return new_override_data, static_result

	case ^ExecuteData:
		// Check target
		new_target, static_target := replace_references_and_collapse(s.target, swapped)

		// If nothing changed, return original
		if new_target == s.target {
			// Execute original
			if scope, ok := static_target.(^ScopeData); ok {
				for binding in scope.content {
					if binding.kind == .product {
						return s, binding.static_value
					}
				}
			}
			return s, empty
		}

		// Create new execute
		new_exec := new(ExecuteData)
		new_exec.target = new_target
		new_exec.wrappers = s.wrappers

		// Execute new target
		if scope, ok := static_target.(^ScopeData); ok {
			for binding in scope.content {
				if binding.kind == .product {
					return new_exec, binding.static_value
				}
			}
		}
		return new_exec, empty

	case ^RangeData:
		// Check both bounds
		new_start, static_start := replace_references_and_collapse(s.start, swapped)
		new_end, static_end := replace_references_and_collapse(s.end, swapped)

		// If nothing changed, return original
		if new_start == s.start && new_end == s.end {
			static_range := new(RangeData)
			static_range.start = static_start
			static_range.end = static_end
			return s, static_range
		}

		// Create new range
		new_range := new(RangeData)
		new_range.start = new_start
		new_range.end = new_end

		static_range := new(RangeData)
		static_range.start = static_start
		static_range.end = static_end

		return new_range, static_range

	case ^ReactiveData:
		// Check initial value
		new_initial, static_initial := replace_references_and_collapse(s.initial, swapped)

		// If nothing changed, return original
		if new_initial == s.initial {
			return s, static_initial
		}

		// Create new reactive
		new_reactive := new(ReactiveData)
		new_reactive.initial = new_initial
		return new_reactive, static_initial

	case ^EffectData:
		// Check placeholder
		new_placeholder, static_placeholder := replace_references_and_collapse(s.placeholder, swapped)

		// If nothing changed, return original
		if new_placeholder == s.placeholder {
			return s, static_placeholder
		}

		// Create new effect
		new_effect := new(EffectData)
		new_effect.placeholder = new_placeholder
		return new_effect, static_placeholder
	}

	return symbolic, symbolic
}

// Helper function to check if a value contains references that need swapping
contains_references :: proc(value: ValueData, swapped: ^[dynamic]BindSwap) -> bool {
  #partial switch v in value {
	case ^RefData:
    for swap in swapped {
      if swap.old == v.refered {
        return true
      }
    }
		return false
	case ^PropertyData:
		return contains_references(v.source, swapped)
	case ^BinaryOpData:
		return contains_references(v.left, swapped) || contains_references(v.right, swapped)
	case ^UnaryOpData:
		return contains_references(v.value, swapped)
	case ^OverrideData:
		if contains_references(v.target, swapped) {
			return true
		}
		for override in v.overrides {
			if contains_references(override.symbolic_value, swapped) {
				return true
			}
		}
		return false
	case ^ExecuteData:
		return contains_references(v.target, swapped)
	case ^RangeData:
		return contains_references(v.start, swapped) || contains_references(v.end, swapped)
	case ^ReactiveData:
		return contains_references(v.initial, swapped)
	case ^EffectData:
		return contains_references(v.placeholder, swapped)
	case ^ScopeData:
		for binding in v.content {
			if binding != nil && contains_references(binding.symbolic_value, swapped) {
				return true
			}
		}
		return false
	}
	return false
}

// Helper function to evaluate binary operations on static values
evaluate_binary_op :: proc(left: ValueData, right: ValueData, op: Operator_Kind) -> ValueData {
  #partial switch op {
	case .Add, .Subtract, .Multiply, .Divide, .Mod:
		return evaluate_math_op(left, right, op)
	case .And, .Or, .Xor:
		return evaluate_bitwise_op(left, right, op)
	case .Less, .Greater, .LessEqual, .GreaterEqual:
		return evaluate_comparison_op(left, right, op)
	case .Equal, .NotEqual:
		return evaluate_equality_op(left, right, op)
	case .LShift, .RShift:
		return evaluate_shift_op(left, right, op)
	}
	return empty
}

// Helper function to evaluate unary operations on static values
evaluate_unary_op :: proc(value: ValueData, op: Operator_Kind) -> ValueData {
  #partial switch op {
	case .Subtract:
    #partial switch v in value {
		case ^IntegerData:
			result := new(IntegerData)
			result.content = v.content
			result.kind = v.kind
			result.negative = !v.negative
			return result
		case ^FloatData:
			result := new(FloatData)
			result.content = -v.content
			result.kind = v.kind
			return result
		}
	case .Not:
    #partial switch v in value {
		case ^BoolData:
			result := new(BoolData)
			result.content = !v.content
			return result
		case ^IntegerData:
			result := new(IntegerData)
			result.content = ~v.content
			result.kind = v.kind
			result.negative = v.negative
			return result
		}
	}
	return empty
}

// Helper function for math operations
evaluate_math_op :: proc(left: ValueData, right: ValueData, op: Operator_Kind) -> ValueData {
  #partial switch l in left {
	case ^IntegerData:
		if r, ok := right.(^IntegerData); ok {
			result := new(IntegerData)
			result.kind = l.kind if l.kind != .none else r.kind
			result.negative = l.negative || r.negative

      #partial switch op {
			case .Add:
				result.content = l.content + r.content
			case .Subtract:
				result.content = l.content - r.content
			case .Multiply:
				result.content = l.content * r.content
			case .Divide:
				if r.content != 0 {
					result.content = l.content / r.content
				}
			case .Mod:
				if r.content != 0 {
					result.content = l.content % r.content
				}
			}
			return result
		}
	case ^FloatData:
		if r, ok := right.(^FloatData); ok {
			result := new(FloatData)
			result.kind = l.kind if l.kind != .none else r.kind

      #partial switch op {
			case .Add:
				result.content = l.content + r.content
			case .Subtract:
				result.content = l.content - r.content
			case .Multiply:
				result.content = l.content * r.content
			case .Divide:
				if r.content != 0 {
					result.content = l.content / r.content
				}
			case .Mod:
				return empty
			}
			return result
		}
	}
	return empty
}

// Helper function for bitwise operations
evaluate_bitwise_op :: proc(left: ValueData, right: ValueData, op: Operator_Kind) -> ValueData {
  #partial switch l in left {
	case ^BoolData:
		if r, ok := right.(^BoolData); ok {
			result := new(BoolData)
      #partial switch op {
			case .And:
				result.content = l.content && r.content
			case .Or:
				result.content = l.content || r.content
			case .Xor:
				result.content = l.content ~ r.content
			}
			return result
		}
	case ^IntegerData:
		if r, ok := right.(^IntegerData); ok {
			result := new(IntegerData)
			result.kind = l.kind if l.kind != .none else r.kind
			result.negative = l.negative

      #partial switch op {
			case .And:
				result.content = l.content & r.content
			case .Or:
				result.content = l.content | r.content
			case .Xor:
				result.content = l.content ~ r.content
			}
			return result
		}
	}
	return empty
}

// Helper function for comparison operations
evaluate_comparison_op :: proc(left: ValueData, right: ValueData, op: Operator_Kind) -> ValueData {
	result := new(BoolData)

	compare_func :: #force_inline proc(a, b: $T, kind: Operator_Kind) -> bool {
		#partial switch kind {
		case .Less:
			return a < b
		case .Greater:
			return a > b
		case .LessEqual:
			return a <= b
		case .GreaterEqual:
			return a >= b
		}
		return false
	}

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

  #partial switch l in left {
	case ^IntegerData:
    #partial switch r in right {
		case ^IntegerData:
			result.content = compare_func(l.content, r.content, op)
		case ^FloatData:
			result.content = compare_func(cast(f64)l.content, r.content, op)
		case ^StringData:
			result.content = compare_func(l.content, string_to_u64(r.content), op)
		case:
			return empty
		}
	case ^FloatData:
    #partial switch r in right {
		case ^IntegerData:
			result.content = compare_func(l.content, cast(f64)r.content, op)
		case ^FloatData:
			result.content = compare_func(l.content, r.content, op)
		case ^StringData:
			result.content = compare_func(l.content, cast(f64)string_to_u64(r.content), op)
		case:
			return empty
		}
	case ^StringData:
    #partial switch r in right {
		case ^IntegerData:
			result.content = compare_func(string_to_u64(l.content), r.content, op)
		case ^FloatData:
			result.content = compare_func(cast(f64)string_to_u64(l.content), r.content, op)
		case ^StringData:
			result.content = compare_func(string_to_u64(l.content), string_to_u64(r.content), op)
		case:
			return empty
		}
	case:
		return empty
	}

	return result
}

// Helper function for equality operations
evaluate_equality_op :: proc(left: ValueData, right: ValueData, op: Operator_Kind) -> ValueData {
	result := new(BoolData)
	equal := values_equal(left, right)

  #partial switch op {
	case .Equal:
		result.content = equal
	case .NotEqual:
		result.content = !equal
	}

	return result
}

// Helper function for shift operations
evaluate_shift_op :: proc(left: ValueData, right: ValueData, op: Operator_Kind) -> ValueData {
	if l, l_ok := left.(^IntegerData); l_ok {
		if r, r_ok := right.(^IntegerData); r_ok {
			result := new(IntegerData)
			result.kind = l.kind
			result.negative = l.negative

      #partial switch op {
			case .LShift:
				result.content = l.content << r.content
			case .RShift:
				result.content = l.content >> r.content
			}
			return result
		}
	}
	return empty
}

// Helper function to check if two values are equal
values_equal :: proc(left: ValueData, right: ValueData) -> bool {
  #partial switch l in left {
	case ^IntegerData:
		if r, ok := right.(^IntegerData); ok {
			return l.content == r.content && l.kind == r.kind && l.negative == r.negative
		}
	case ^FloatData:
		if r, ok := right.(^FloatData); ok {
			return l.content == r.content && l.kind == r.kind
		}
	case ^BoolData:
		if r, ok := right.(^BoolData); ok {
			return l.content == r.content
		}
	case ^StringData:
		if r, ok := right.(^StringData); ok {
			return l.content == r.content
		}
	case ^ScopeData:
		if r, ok := right.(^ScopeData); ok {
			if len(l.content) != len(r.content) {
				return false
			}
			for i in 0..<len(l.content) {
				if l.content[i].name != r.content[i].name ||
				   l.content[i].kind != r.content[i].kind ||
				   !values_equal(l.content[i].static_value, r.content[i].static_value) {
					return false
				}
			}
			return true
		}
	case Empty:
		_, ok := right.(Empty)
		return ok
	}
	return false
}

