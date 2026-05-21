package compiler

import "core:fmt"
import "core:slice"
import "core:strconv"
import "core:strings"

Analyzer :: struct {
	ast:             ^Ast,
	errors:          [dynamic]Analyzer_Error,
	warnings:        [dynamic]Analyzer_Error,
	stack:           [dynamic]^ScopeData,
	pending_binding: ^Binding,
}

Binding :: struct {
	name:           string,
	kind:           Binding_Kind,
	constraint:     ^ScopeData,
	owner:          ^ScopeData,
	symbolic_value: ValueData,
	static_value:   ValueData,
}

ValueData :: union {
	^ScopeData,
	^StringData,
	^IntegerData,
	^FloatData,
	^BoolData,
	^PropertyData,
	^RangeData,
	^AExecuteData,
	^CarveAData,
	^RefData,
	^BinaryOpData,
	^ReactiveData,
	^EffectData,
	^UnaryOpData,
	Empty,
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

CarveAData :: struct {
	target: ValueData,
	carves: [dynamic]^Binding,
}

AExecuteData :: struct {
	target:   ValueData,
	wrappers: [dynamic]ExecutionWrapper,
}

RefData :: struct {
	refered: ^Binding,
}

RangeData :: struct {
	start: ValueData,
	end:   ValueData,
}

Empty :: struct {}

ScopeData :: struct {
	content: [dynamic]^Binding,
}

StringData :: struct {
	content: string,
}

IntegerData :: struct {
	content:  u64,
	kind:     IntegerKind,
	negative: bool,
}

IntegerKind :: enum {
	none,
	u8,
	i8,
	u16,
	i16,
	u32,
	i32,
	u64,
	i64,
}

FloatKind :: enum {
	none,
	f32,
	f64,
}

FloatData :: struct {
	content: f64,
	kind:    FloatKind,
}

BoolData :: struct {
	content: bool,
}

Analyzer_Error_Type :: enum {
	Undefined_Identifier,
	Invalid_Binding_Name,
	Invalid_Carve,
	Invalid_Property_Access,
	Type_Mismatch,
	Invalid_Constraint,
	Invalid_Constraint_Name,
	Invalid_Constraint_Value,
	Circular_Reference,
	Invalid_Event_Pull,
	Invalid_Binding_Value,
	Invalid_Expand,
	Invalid_Execute,
	Invalid_operator,
	Invalid_Range,
	Infinite_Recursion,
	Default,
}

Binding_Kind :: enum {
	pointing_push,
	pointing_pull,
	event_push,
	event_pull,
	resonance_push,
	resonance_pull,
	inline_push,
	product,
}

Analyzer_Error :: struct {
	type:     Analyzer_Error_Type,
	message:  string,
	position: Position,
}

get_analyzer :: #force_inline proc() -> ^Analyzer {
	return (^Analyzer)(context.user_ptr)
}

get_ast :: #force_inline proc() -> ^Ast {
	return get_analyzer().ast
}

push_scope :: #force_inline proc(data: ^ScopeData) {
	add_binding(data)
	append(&get_analyzer().stack, data)
}

curr_scope :: #force_inline proc() -> ^ScopeData {
	stack := get_analyzer().stack
	return stack[len(stack) - 1]
}

pending_binding_get :: #force_inline proc() -> ^Binding {
	return get_analyzer().pending_binding
}

set_pending_binding :: #force_inline proc(binding: ^Binding) {
	get_analyzer().pending_binding = binding
}

curr_binding :: #force_inline proc() -> ^Binding {
	scope := curr_scope()
	return scope.content[len(scope.content) - 1]
}

pop_scope :: #force_inline proc() {
	pop(&get_analyzer().stack)
}

add_binding :: #force_inline proc(scope: ^ScopeData = nil) {
	binding := pending_binding_get()
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

analyze :: proc(cache: ^Cache, ast: ^Ast) -> bool {
	if ast == nil do return false

	root := new(ScopeData)
	root.content = make([dynamic]^Binding, 0)

	analyzer := Analyzer {
		ast      = ast,
		errors   = make([dynamic]Analyzer_Error, 0),
		warnings = make([dynamic]Analyzer_Error, 0),
		stack    = make([dynamic]^ScopeData, 0),
	}

	context.user_ptr = &analyzer
	push_scope(&builtin)
	push_scope(root)

	root_idx := ast_root(ast)
	if node_kind(ast, root_idx) == .ScopeNode {
		for child in node_children(ast, root_idx) {
			analyze_node(child)
		}
	} else {
		analyzer_error("Root should be a scope", .Default, node_position(ast, root_idx))
	}

	cache.analyze_errors = analyzer.errors
	cache.analyze_warnings = analyzer.warnings

	if resolver.options.print_errors {
		debug_analyzer(&analyzer, true)
	}
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
		new_int^ = data^
		return new_int
	case ^FloatData:
		new_float := new(FloatData, allocator)
		new_float^ = data^
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
	case ^AExecuteData:
		new_execute := new(AExecuteData, allocator)
		new_execute.target = copy_value_data(data.target, allocator)
		new_execute.wrappers = data.wrappers
		return new_execute
	case ^CarveAData:
		new_carve := new(CarveAData, allocator)
		new_carve.target = copy_value_data(data.target, allocator)
		new_carve.carves = make([dynamic]^Binding, len(data.carves), allocator)
		for binding, i in data.carves {
			new_carve.carves[i] = copy_binding(binding, allocator)
		}
		return new_carve
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

copy_binding :: proc(original: ^Binding, allocator := context.allocator) -> ^Binding {
	new_binding := new(Binding, allocator)
	new_binding.name = strings.clone(original.name, allocator)
	new_binding.kind = original.kind
	new_binding.owner = original.owner
	new_binding.constraint = original.constraint
	new_binding.symbolic_value = copy_value_data(original.symbolic_value, allocator)
	new_binding.static_value = copy_value_data(original.static_value, allocator)
	return new_binding
}

analyze_node :: proc(idx: Node_Index) {
	if idx == INVALID_NODE do return
	ast := get_ast()
	binding := new(Binding)
	set_pending_binding(binding)
	kind := node_kind(ast, idx)
	pos := node_position(ast, idx)

	#partial switch kind {
	case .EventPull:
		binding.kind = .event_pull
		from := node_event_pull_from(ast, idx)
		to := node_event_pull_to(ast, idx)
		if from == INVALID_NODE {
			analyzer_error(
				"Event pulling must have a Event descriptor left",
				.Invalid_Event_Pull,
				pos,
			)
		}
		binding.symbolic_value = empty
		binding.static_value = empty
		analyzer_error("Missing binding name", .Invalid_Binding_Value, pos)
		analyze_name(from, binding)
		bind_value(binding, to)
	case .EventPush:
		binding.kind = .event_push
		from := node_left(ast, idx)
		to := node_right(ast, idx)
		if from != INVALID_NODE {
			analyze_name(from, binding)
		}
		if to == INVALID_NODE {
			binding.symbolic_value = empty
			binding.static_value = empty
			analyzer_error("Missing binding value", .Invalid_Binding_Value, pos)
		} else {
			bind_value(binding, to)
		}
	case .ResonancePush:
		binding.kind = .resonance_push
		from := node_left(ast, idx)
		to := node_right(ast, idx)
		if from == INVALID_NODE {
			binding.symbolic_value = empty
			binding.static_value = empty
			analyzer_error("Missing binding name", .Invalid_Binding_Value, pos)
		} else {
			analyze_name(from, binding)
		}
		if to == INVALID_NODE {
			binding.symbolic_value = empty
			binding.static_value = empty
			analyzer_error("Missing binding value", .Invalid_Binding_Value, pos)
		} else {
			bind_value(binding, to)
		}
	case .ResonancePull:
		binding.kind = .resonance_pull
		from := node_left(ast, idx)
		to := node_right(ast, idx)
		if from == INVALID_NODE {
			binding.symbolic_value = empty
			binding.static_value = empty
			analyzer_error("Missing binding name", .Invalid_Binding_Value, pos)
		} else {
			analyze_name(from, binding)
		}
		if to == INVALID_NODE {
			binding.symbolic_value = empty
			binding.static_value = empty
			analyzer_error("Missing binding value", .Invalid_Binding_Value, pos)
		} else {
			bind_value(binding, to)
		}
	case .Pointing:
		binding.kind = .pointing_push
		from := node_left(ast, idx)
		to := node_right(ast, idx)
		if from == INVALID_NODE {
			binding.symbolic_value = empty
			binding.static_value = empty
			analyzer_error("Missing binding name", .Invalid_Binding_Value, pos)
		} else {
			analyze_name(from, binding)
		}
		if to == INVALID_NODE {
			binding.symbolic_value = empty
			binding.static_value = empty
			analyzer_error("Missing binding value", .Invalid_Binding_Value, pos)
		} else {
			bind_value(binding, to)
		}
	case .PointingPull:
		binding.kind = .pointing_pull
		from := node_left(ast, idx)
		to := node_right(ast, idx)
		if from == INVALID_NODE {
			binding.symbolic_value = empty
			binding.static_value = empty
			analyzer_error("Missing binding name", .Invalid_Binding_Value, pos)
		} else {
			analyze_name(from, binding)
		}
		if to == INVALID_NODE {
			binding.symbolic_value = empty
			binding.static_value = empty
			analyzer_error("Missing binding value", .Invalid_Binding_Value, pos)
		} else {
			bind_value(binding, to)
		}
	case .Product:
		binding.kind = .product
		operand := node_unary_operand(ast, idx)
		if operand == INVALID_NODE {
			binding.symbolic_value = empty
			binding.static_value = empty
			analyzer_error("Missing binding value", .Invalid_Binding_Value, pos)
		} else {
			bind_value(binding, operand)
		}
	case .Constraint:
		binding.kind = .pointing_push
		analyze_name(idx, binding)
	case .Expand:
		operand := node_unary_operand(ast, idx)
		process_expand_value(operand, binding)
	case:
		binding.kind = .pointing_push
		bind_value(binding, idx)
	}
	typecheck_binding(binding, idx)
	add_binding()
}

bind_value :: #force_inline proc(binding: ^Binding, idx: Node_Index) {
	binding.symbolic_value, binding.static_value = analyze_value(idx)
	if s, ok := binding.static_value.(^ScopeData); ok {
		analyze_scope_recursive_properties(s)
	}
}

typecheck_binding :: proc(binding: ^Binding, idx: Node_Index) {
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
	ast := get_ast()
	analyzer_error("Type are not matching", .Type_Mismatch, node_position(ast, idx))
	binding.static_value = resolve_default(binding.constraint)
	binding.symbolic_value = binding.static_value
}

typecheck_by_constraint :: proc(constraint: ^ScopeData, value: ValueData) -> bool {
	isEmptyConstraint := true
	for binding in constraint.content {
		if binding.kind == .product {
			isEmptyConstraint = false
			if binding.constraint != nil {
				if typecheck_by_constraint(binding.constraint, value) {
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
				if !check_constraint_compatibility(constraint, valBind.constraint) {
					return false
				}
			} else {
				if !typecheck_by_constraint(constraint, valBind.static_value) {
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
			if c.content[i].kind == .product {
				return c.content[i].static_value
			}
		}
	}
	return empty
}

typecheck_scope :: proc(constraint: []^Binding, value: []^Binding) -> bool {
	if len(value) != len(constraint) do return false
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
			if val.content < 1 << 24 {
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
		switch constr.kind {
		case .none:
			return true
		case .u8:
			if val.negative == false && val.content < 256 {val.kind = .u8;return true};return false
		case .i8:
			if val.content < 256 {val.kind = .i8;return true};return false
		case .u16:
			if val.negative == false &&
			   val.content < 65536 {val.kind = .u16;return true};return false
		case .i16:
			if val.content < 65536 {val.kind = .i16;return true};return false
		case .u32:
			if val.negative == false &&
			   val.content < 4294967296 {val.kind = .u32;return true};return false
		case .i32:
			if val.content < 4294967296 {val.kind = .i32;return true};return false
		case .u64:
			if val.negative == false {val.kind = .u64;return true};return false
		case .i64:
			val.kind = .i64;return true
		}
	}
	return constr.kind == .none || constr.kind == val.kind
}

typecheck_by_value :: proc(constraint: ValueData, value: ValueData) -> bool {
	#partial switch constr in constraint {
	case ^ScopeData:
		if val, ok := value.(^ScopeData); ok {
			return typecheck_scope(constr.content[:], val.content[:])
		}
		return false
	case ^StringData:
		_, ok := value.(^StringData)
		return ok
	case ^IntegerData:
		if val, ok := value.(^IntegerData); ok {
			return typecheck_int(val, constr)
		}
		return false
	case ^FloatData:
		if val, ok := value.(^FloatData); ok {
			return typecheck_float(val, constr)
		}
		return false
	case ^BoolData:
		_, ok := value.(^BoolData)
		return ok
	case Empty:
		_, ok := value.(Empty)
		return ok
	}
	return false
}

process_expand_value :: proc(idx: Node_Index, binding: ^Binding) {
	if idx == INVALID_NODE do return
	ast := get_ast()
	kind := node_kind(ast, idx)
	pos := node_position(ast, idx)

	#partial switch kind {
	case .EventPull:
		from := node_event_pull_from(ast, idx)
		to := node_event_pull_to(ast, idx)
		analyze_name(from, binding)
		bind_value(binding, to)
	case .EventPush:
		from := node_left(ast, idx)
		to := node_right(ast, idx)
		if from != INVALID_NODE {
			analyze_name(from, binding)
		}
		bind_value(binding, to)
	case .ResonancePush:
		from := node_left(ast, idx)
		to := node_right(ast, idx)
		analyze_name(from, binding)
		bind_value(binding, to)
	case .ResonancePull:
		from := node_left(ast, idx)
		to := node_right(ast, idx)
		analyze_name(from, binding)
		bind_value(binding, to)
	case .Pointing:
		from := node_left(ast, idx)
		to := node_right(ast, idx)
		analyze_name(from, binding)
		bind_value(binding, to)
	case .PointingPull:
		from := node_left(ast, idx)
		to := node_right(ast, idx)
		analyze_name(from, binding)
		bind_value(binding, to)
	case .Product:
		operand := node_unary_operand(ast, idx)
		bind_value(binding, operand)
	case .Constraint:
		analyze_name(idx, binding)
	case .Expand:
		analyzer_error("Nested expands are not allowed", .Invalid_Expand, pos)
		operand := node_unary_operand(ast, idx)
		process_expand_value(operand, binding)
	case:
		bind_value(binding, idx)
	}
}

analyze_name :: proc(idx: Node_Index, binding: ^Binding) {
	if idx == INVALID_NODE do return
	ast := get_ast()
	kind := node_kind(ast, idx)
	pos := node_position(ast, idx)

	#partial switch kind {
	case .Constraint:
		name_idx := node_right(ast, idx)
		constraint_idx := node_left(ast, idx)
		if name_idx != INVALID_NODE {
			name_kind := node_kind(ast, name_idx)
			#partial switch name_kind {
			case .Identifier:
				binding.name = node_name_str(ast, name_idx)
			case .Carve:
				source_idx := node_carve_source(ast, name_idx)
				if source_idx != INVALID_NODE && node_kind(ast, source_idx) == .Identifier {
					binding.name = node_name_str(ast, source_idx)
				} else {
					analyzer_error(
						"The : constraint indicator must be followed by an identifier or nothing",
						.Invalid_Constraint_Name,
						node_position(ast, name_idx),
					)
				}
			case .ScopeNode:
			case:
				analyzer_error(
					"The : constraint indicator must be followed by an identifier or nothing",
					.Invalid_Constraint_Name,
					node_position(ast, name_idx),
				)
			}
		}
		if constraint_idx == INVALID_NODE {
			analyzer_error(
				"Constraint node without a specific constraint is not allowed",
				.Invalid_Constraint,
				pos,
			)
			return
		}
		analyze_constraint(constraint_idx, binding)
	case .Identifier:
		binding.name = node_name_str(ast, idx)
	case:
		analyzer_error(
			"Cannot use anything other than constraint or identifier as binding name",
			.Invalid_Binding_Name,
			pos,
		)
	}
}

analyze_scope_recursive_properties :: proc(scope: ^ScopeData) {
	for binding in scope.content {
		if binding.kind == .product {
			if binding.constraint == scope {
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
					if bind.constraint == scope {
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

analyze_constraint :: proc(idx: Node_Index, binding: ^Binding) {
	constraint, static_constraint := analyze_value(idx)
	#partial switch c in static_constraint {
	case ^ScopeData:
		binding.constraint = c
	}
}

analyze_carve :: proc(idx: Node_Index) -> ^Binding {
	if idx == INVALID_NODE do return nil
	ast := get_ast()
	binding := new(Binding)
	kind := node_kind(ast, idx)

	#partial switch kind {
	case .EventPull:
		binding.kind = .event_pull
		from := node_event_pull_from(ast, idx)
		to := node_event_pull_to(ast, idx)
		analyze_name(from, binding)
		bind_value(binding, to)
	case .EventPush:
		binding.kind = .event_push
		from := node_left(ast, idx)
		to := node_right(ast, idx)
		analyze_name(from, binding)
		bind_value(binding, to)
	case .ResonancePush:
		binding.kind = .resonance_push
		from := node_left(ast, idx)
		to := node_right(ast, idx)
		analyze_name(from, binding)
		bind_value(binding, to)
	case .ResonancePull:
		binding.kind = .resonance_pull
		to := node_right(ast, idx)
		bind_value(binding, to)
	case .Pointing:
		binding.kind = .pointing_push
		from := node_left(ast, idx)
		to := node_right(ast, idx)
		analyze_name(from, binding)
		bind_value(binding, to)
	case .PointingPull:
		binding.kind = .pointing_pull
		from := node_left(ast, idx)
		to := node_right(ast, idx)
		analyze_name(from, binding)
		bind_value(binding, to)
	case .Product:
		binding.kind = .product
		operand := node_unary_operand(ast, idx)
		bind_value(binding, operand)
	case .Constraint:
		return nil
	case .Expand:
		return nil
	case:
		binding.kind = .pointing_push
		bind_value(binding, idx)
	}
	return binding
}

BindSwap :: struct {
	old: ^Binding,
	new: ^Binding,
}

index_carve :: #force_inline proc(target: ^ScopeData, index: int, carve: ^Binding) -> BindSwap {
	skip := 0
	for i in 0 ..< len(target.content) {
		if target.content[i].kind != .pointing_push {
			skip += 1
		} else if i == index + skip {
			carven := target.content[i]
			target.content[i] = copy_binding(carven)
			target.content[i].symbolic_value = carve.symbolic_value
			target.content[i].static_value = carve.static_value
			return BindSwap{old = carven, new = target.content[i]}
		}
	}
	return BindSwap{}
}

name_carve :: #force_inline proc(target: ^ScopeData, carve: ^Binding) -> BindSwap {
	for binding, i in target.content {
		if binding.name == carve.name {
			if binding.kind == carve.kind {
				carven := target.content[i]
				target.content[i] = copy_binding(carven)
				target.content[i].symbolic_value = carve.symbolic_value
				target.content[i].static_value = carve.static_value
				return BindSwap{old = carven, new = target.content[i]}
			} else {
				analyzer_error(
					fmt.tprintf("Binding kind mismatch for %s", carve.name),
					.Invalid_Carve,
					Position{},
				)
			}
			return BindSwap{}
		}
	}
	analyzer_error(fmt.tprintf("Property %s not found", carve.name), .Invalid_Carve, Position{})
	return BindSwap{}
}

reeval_carven_scope :: #force_inline proc(target: ^ScopeData, swapped: ^[dynamic]BindSwap) {
	for binding, i in target.content {
		symbolic_value, static_value := replace_references_and_collapse(
			binding.symbolic_value,
			swapped,
		)
		if static_value != binding.static_value {
			target.content[i] = copy_binding(binding)
			target.content[i].symbolic_value = symbolic_value
			target.content[i].static_value = static_value
			append(swapped, BindSwap{old = binding, new = target.content[i]})
		}
	}
}

apply_carve :: proc(target: ValueData, carves: [dynamic]^Binding) -> ValueData {
	switch t in target {
	case ^ScopeData:
		swapped := make([dynamic]BindSwap, 0)
		for i in 0 ..< len(carves) {
			if carves[i].name == "" {
				swap := index_carve(t, i, carves[i])
				if swap.old != nil do append(&swapped, swap)
			} else {
				swap := name_carve(t, carves[i])
				if swap.old != nil do append(&swapped, swap)
			}
		}
		if len(swapped) > 0 {
			reeval_carven_scope(t, &swapped)
		}
	case ^StringData:
		if len(carves) == 1 && carves[0].name == "" && carves[0].kind == .pointing_push {
			if s, ok := carves[0].static_value.(^StringData); ok {
				t.content = s.content
				return t
			}
		}
		analyzer_error("Carve for string should just be string", .Invalid_Carve, Position{})
	case ^IntegerData:
		if len(carves) == 1 && carves[0].name == "" && carves[0].kind == .pointing_push {
			if i, ok := carves[0].static_value.(^IntegerData); ok {
				if typecheck_int(t, i) {
					t.content = i.content
					t.kind = i.kind
					t.negative = i.negative
					return t
				}
			}
		}
		analyzer_error("Carve for int should just be string", .Invalid_Carve, Position{})
	case ^FloatData:
		if len(carves) == 1 && carves[0].name == "" && carves[0].kind == .pointing_push {
			if f, ok := carves[0].static_value.(^FloatData); ok {
				if typecheck_float(t, f) {
					t.content = f.content
					t.kind = f.kind
					return t
				}
			}
		}
		analyzer_error("Carve for float should just be string", .Invalid_Carve, Position{})
	case ^BoolData:
		if len(carves) == 1 && carves[0].name == "" && carves[0].kind == .pointing_push {
			if b, ok := carves[0].static_value.(^BoolData); ok {
				t.content = b.content
				return t
			}
		}
		analyzer_error("Carve for boolean should just be string", .Invalid_Carve, Position{})
	case ^PropertyData,
	     ^RangeData,
	     ^AExecuteData,
	     ^CarveAData,
	     ^RefData,
	     ^BinaryOpData,
	     ^ReactiveData,
	     ^EffectData,
	     ^UnaryOpData:
		analyzer_error("Those dynamic elements should ne be used here", .Invalid_Carve, Position{})
	case Empty:
		analyzer_error("Cannot carve someting that resolve to empty", .Invalid_Carve, Position{})
	}
	return target
}

analyze_value :: proc(idx: Node_Index) -> (ValueData, ValueData) {
	if idx == INVALID_NODE do return empty, empty
	ast := get_ast()
	kind := node_kind(ast, idx)
	pos := node_position(ast, idx)

	#partial switch kind {
	case .EventPull,
	     .EventPush,
	     .ResonancePush,
	     .ResonancePull,
	     .Pointing,
	     .PointingPull,
	     .Product,
	     .Expand:
		analyzer_error(
			"Cannot use a binding definition has a binding value",
			.Invalid_Binding_Value,
			pos,
		)
		return empty, empty
	case .Unknown:
	case .Enforce:
	case .Branch:
		analyzer_error(
			"We should not find a branch outside a pattern node",
			.Invalid_Binding_Value,
			pos,
		)
		return empty, empty
	case .Constraint:
		constraint_idx := node_left(ast, idx)
		name_idx := node_right(ast, idx)
		constraint, static_constraint := analyze_value(constraint_idx)
		if c, ok := static_constraint.(^ScopeData); ok {
			add_binding()
			binding := curr_binding()
			if binding.constraint == nil {
				binding.constraint = c
			}
		}
		value := resolve_default(static_constraint)
		if name_idx == INVALID_NODE {
			return value, value
		} else {
			if node_kind(ast, name_idx) == .ScopeNode {
				// TODO(andrflor): apply carve here?
			} else {
				analyzer_error(
					"Value for constraint data should be carve",
					.Invalid_Constraint,
					pos,
				)
			}
			return value, value
		}
	case .ScopeNode:
		scope := new(ScopeData)
		scope.content = make([dynamic]^Binding, 0)
		push_scope(scope)
		for child in node_children(ast, idx) {
			analyze_node(child)
		}
		pop_scope()
		return scope, scope
	case .Carve:
		source_idx := node_carve_source(ast, idx)
		target, static_target := analyze_value(source_idx)
		if scope, ok := static_target.(^ScopeData); ok {
			carve := new(CarveAData)
			carve.target = target
			carve.carves = make([dynamic]^Binding, 0)
			for child in node_carve_children(ast, idx) {
				binding := analyze_carve(child)
				if binding != nil {
					append(&carve.carves, binding)
				}
			}
			return carve, apply_carve(copy_scope(scope), carve.carves)
		} else {
			analyzer_error(
				"Trying to carve an element that does no resolve to a scope",
				.Invalid_Carve,
				pos,
			)
			return target, static_target
		}
	case .Identifier:
		name := node_name_str(ast, idx)
		symbol := resolve_symbol(name)
		if symbol == nil {
			analyzer_error(
				fmt.tprintf("Undefined identifier named %s found", name),
				.Undefined_Identifier,
				pos,
			)
			return empty, empty
		}
		ref := new(RefData)
		ref.refered = symbol
		return ref, ref.refered.static_value
	case .Property:
		prop_idx := node_right(ast, idx)
		source_idx := node_left(ast, idx)
		if prop_idx != INVALID_NODE && node_kind(ast, prop_idx) == .Identifier {
			prop_name := node_name_str(ast, prop_idx)
			prop := new(PropertyData)
			prop.prop = prop_name
			if source_idx != INVALID_NODE {
				source, static_source := analyze_value(source_idx)
				if scope, ok := static_source.(^ScopeData); ok {
					for binding in scope.content {
						if binding.name == prop_name {
							return prop, binding.static_value
						}
					}
				}
			} else {
				for binding in curr_scope().content {
					if binding.name == prop_name {
						return prop, binding.static_value
					}
				}
			}
			analyzer_error(
				fmt.tprintf("There is no property %s", prop_name),
				.Invalid_Property_Access,
				pos,
			)
			return prop, empty
		}
		analyzer_error("Invalid property access without identifier", .Invalid_Property_Access, pos)
		return empty, empty
	case .Pattern:
		target_idx := node_pattern_target(ast, idx)
		source, static_source := analyze_value(target_idx)
	case .Operator:
		op_kind := node_operator_kind(ast, idx)
		left_idx := node_operator_left(ast, idx)
		right_idx := node_operator_right(ast, idx)
		if left_idx == INVALID_NODE {
			return analyze_unary_operator(idx, right_idx)
		}
		if right_idx == INVALID_NODE {
			return analyze_unary_operator(idx, left_idx)
		}
		switch op_kind {
		case .Not:
			analyzer_error("Cannot use not as binary operator", .Invalid_operator, pos)
			return empty, empty
		case .Add, .Subtract, .Multiply, .Divide, .Mod:
			return analyze_math_operator(idx)
		case .And, .Or, .Xor:
			return analyze_bitwise_operator(idx)
		case .Less, .Greater, .LessEqual, .GreaterEqual:
			return analyze_ordering_operator(idx)
		case .Equal:
			return analyze_equal_operator(idx)
		case .NotEqual:
			op, bool_val := analyze_equal_operator(idx)
			#partial switch b in bool_val {
			case ^BoolData:
				b.content = !b.content
				return op, b
			}
			return op, bool_val
		case .RShift, .LShift:
			return analyze_int_operator(idx)
		}
	case .Execute:
		exec := new(AExecuteData)
		target_idx := node_execute_target(ast, idx)
		target, static_target := analyze_value(target_idx)
		exec.target = target
		wrappers_raw := node_execute_wrappers(ast, idx)
		exec.wrappers = make([dynamic]ExecutionWrapper, len(wrappers_raw))
		for w, i in wrappers_raw {
			exec.wrappers[i] = ExecutionWrapper(w)
		}
		if scope, ok := static_target.(^ScopeData); ok {
			for binding in scope.content {
				if binding.kind == .product {
					return exec, binding.static_value
				}
			}
		}
		return exec, empty
	case .CompileTime:
		operand := node_unary_operand(ast, idx)
		return analyze_value(operand)
	case .Literal:
		lit_kind := node_literal_kind(ast, idx)
		text := node_text(ast, idx)
		switch lit_kind {
		case .Integer:
			value := new(IntegerData)
			content, ok := strconv.parse_int(text)
			if ok do value.content = u64(content)
			value.kind = .none
			return value, value
		case .Float:
			value := new(FloatData)
			content, ok := strconv.parse_f64(text)
			if ok do value.content = content
			value.kind = .none
			return value, value
		case .String:
			value := new(StringData)
			value.content = text
			return value, value
		case .Bool:
			value := new(BoolData)
			value.content = text == "true"
			return value, value
		case .Hexadecimal:
			value := new(IntegerData)
			hex_text := text
			if len(hex_text) > 2 &&
			   hex_text[0] == '0' &&
			   (hex_text[1] == 'x' || hex_text[1] == 'X') {
				hex_text = hex_text[2:]
			}
			content, ok := strconv.parse_int(hex_text, 16)
			if ok do value.content = u64(content)
			value.kind = .none
			return value, value
		case .Binary:
			value := new(IntegerData)
			bin_text := text
			if len(bin_text) > 2 &&
			   bin_text[0] == '0' &&
			   (bin_text[1] == 'b' || bin_text[1] == 'B') {
				bin_text = bin_text[2:]
			}
			content, ok := strconv.parse_int(bin_text, 2)
			if ok do value.content = u64(content)
			value.kind = .none
			return value, value
		}
	case .External:
		name := node_external_name(ast, idx)
		content := resolver.files[name]
		return empty, empty
	case .Range:
		range_data := new(RangeData)
		start_idx := node_left(ast, idx)
		end_idx := node_right(ast, idx)
		start_val, static_start := analyze_value(start_idx)
		end_val, static_end := analyze_value(end_idx)
		start_data, start_ok := static_start.(^IntegerData)
		end_data, end_ok := static_end.(^IntegerData)
		range_data.start = start_val
		range_data.end = end_val
		static_range := new(RangeData)
		static_range.start = static_start
		static_range.end = static_end
		if !start_ok || !end_ok {
			analyzer_error(
				"Trying to create a range with a non integer value",
				.Invalid_Range,
				pos,
			)
		}
		return range_data, static_range
	}
	return empty, empty
}

empty := Empty{}

string_to_u64 :: proc(s: string) -> u64 {
	bytes := transmute([]u8)s
	if len(bytes) > 8 do return max(u64)
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
	op_idx: Node_Index,
	child_idx: Node_Index,
) -> (
	ValueData,
	ValueData,
) {
	ast := get_ast()
	op_kind := node_operator_kind(ast, op_idx)
	pos := node_position(ast, op_idx)

	op := new(UnaryOpData)
	value, static_value := analyze_value(child_idx)
	op.value = value
	op.oprator = op_kind
	switch op_kind {
	case .Subtract:
		#partial switch v in static_value {
		case ^IntegerData:
			#partial switch v.kind {
			case .u8, .u16, .u32, .u64:
				analyzer_error("Cannot sub on an unsigned int", .Invalid_operator, pos)
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
			analyzer_error("Cannot sub anything else than float or int", .Invalid_operator, pos)
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
		analyzer_error("Operator should not be used as unary", .Invalid_operator, pos)
		return value, static_value
	}
	return value, static_value
}

analyze_math_operator :: #force_inline proc(idx: Node_Index) -> (ValueData, ValueData) {
	ast := get_ast()
	op_kind := node_operator_kind(ast, idx)
	left_idx := node_operator_left(ast, idx)
	right_idx := node_operator_right(ast, idx)
	pos := node_position(ast, idx)

	op := new(BinaryOpData)
	left, static_left := analyze_value(left_idx)
	right, static_right := analyze_value(right_idx)
	op.oprator = op_kind
	op.left = left
	op.right = right

	#partial switch r in static_right {
	case ^IntegerData:
		#partial switch l in static_left {
		case ^IntegerData:
			if l.kind == r.kind || l.kind == .none || r.kind == .none {
				static_int := new(IntegerData)
				#partial switch op_kind {
				case .Add:
					static_int.content = l.content + r.content;return op, static_int
				case .Divide:
					static_int.content = l.content / r.content;return op, static_int
				case .Subtract:
					static_int.content = l.content - r.content;return op, static_int
				case .Mod:
					static_int.content = l.content % r.content;return op, static_int
				case .Multiply:
					static_int.content = l.content * r.content;return op, static_int
				}
			} else {
				analyzer_error(
					fmt.tprintf("Icompatible integer types for %s", op_kind),
					.Invalid_operator,
					pos,
				)
				return empty, empty
			}
		}
	case ^FloatData:
		#partial switch l in static_left {
		case ^FloatData:
			if l.kind == r.kind || l.kind == .none || r.kind == .none {
				static_float := new(FloatData)
				#partial switch op_kind {
				case .Add:
					static_float.content = l.content + r.content;return op, static_float
				case .Divide:
					static_float.content = l.content / r.content;return op, static_float
				case .Subtract:
					static_float.content = l.content - r.content;return op, static_float
				case .Mod:
					analyzer_error(
						fmt.tprintf("Mod is only allowed with integers", op_kind),
						.Invalid_operator,
						pos,
					)
					return empty, empty
				case .Multiply:
					static_float.content = l.content * r.content;return op, static_float
				}
			} else {
				analyzer_error(
					fmt.tprintf("Icompatible float types for %s", op_kind),
					.Invalid_operator,
					pos,
				)
				return empty, empty
			}
		}
	}
	analyzer_error(fmt.tprintf("Icompatible types for %s", op_kind), .Invalid_operator, pos)
	return empty, empty
}

analyze_bitwise_operator :: #force_inline proc(idx: Node_Index) -> (ValueData, ValueData) {
	ast := get_ast()
	op_kind := node_operator_kind(ast, idx)
	left_idx := node_operator_left(ast, idx)
	right_idx := node_operator_right(ast, idx)
	pos := node_position(ast, idx)

	op := new(BinaryOpData)
	left, static_left := analyze_value(left_idx)
	right, static_right := analyze_value(right_idx)
	op.oprator = op_kind
	op.left = left
	op.right = right

	#partial switch r in static_right {
	case ^IntegerData:
		#partial switch l in static_left {
		case ^IntegerData:
			if l.kind == r.kind || l.kind == .none || r.kind == .none {
				static_int := new(IntegerData)
				#partial switch op_kind {
				case .Or:
					static_int.content = l.content | r.content;return op, static_int
				case .Xor:
					static_int.content = l.content ~ r.content;return op, static_int
				case .And:
					static_int.content = l.content & r.content;return op, static_int
				}
			} else {
				analyzer_error(
					fmt.tprintf("Icompatible integer types for %s", op_kind),
					.Invalid_operator,
					pos,
				)
				return empty, empty
			}
		}
	case ^BoolData:
		#partial switch l in static_left {
		case ^BoolData:
			static_bool := new(BoolData)
			#partial switch op_kind {
			case .Or:
				static_bool.content = r.content | l.content;return op, static_bool
			case .Xor:
				static_bool.content = r.content ~ l.content;return op, static_bool
			case .And:
				static_bool.content = r.content & l.content;return op, static_bool
			}
		}
	}
	analyzer_error(fmt.tprintf("Icompatible types for %s", op_kind), .Invalid_operator, pos)
	return empty, empty
}

analyze_equal_operator :: #force_inline proc(idx: Node_Index) -> (ValueData, ValueData) {
	ast := get_ast()
	op_kind := node_operator_kind(ast, idx)
	left_idx := node_operator_left(ast, idx)
	right_idx := node_operator_right(ast, idx)
	pos := node_position(ast, idx)

	op := new(BinaryOpData)
	left, static_left := analyze_value(left_idx)
	right, static_right := analyze_value(right_idx)
	op.oprator = op_kind
	op.left = left
	op.right = right

	#partial switch r in static_right {
	case ^IntegerData:
		#partial switch l in static_left {
		case ^IntegerData:
			boolean := new(BoolData)
			if r.kind == .none || l.kind == .none {
				boolean.content = r.content == l.content
			} else {
				boolean.content = r.kind == l.kind && r.content == l.content
			}
			return op, boolean
		case ^FloatData, ^ScopeData, ^BoolData, ^StringData:
			boolean := new(BoolData)
			boolean.content = false
			return op, boolean
		}
	case ^FloatData:
		#partial switch l in static_left {
		case ^IntegerData, ^ScopeData, ^BoolData, ^StringData:
			boolean := new(BoolData)
			boolean.content = false
			return op, boolean
		case ^FloatData:
			boolean := new(BoolData)
			if r.kind == .none || l.kind == .none {
				boolean.content = r.content == l.content
			} else {
				boolean.content = r.kind == l.kind && r.content == l.content
			}
			return op, boolean
		}
	case ^ScopeData:
		#partial switch l in static_left {
		case ^IntegerData, ^FloatData, ^BoolData, ^StringData:
			boolean := new(BoolData)
			boolean.content = false
			return op, boolean
		case ^ScopeData:
			boolean := new(BoolData)
			rlen := len(r.content)
			llen := len(l.content)
			if rlen != llen {
				boolean.content = false
			} else {
				boolean.content = true
				for i in 0 ..< llen {
					rr := r.content[i]
					ll := l.content[i]
					if rr.kind != ll.kind ||
					   rr.name != ll.name ||
					   rr.static_value != ll.static_value {
						boolean.content = false
						break
					}
				}
			}
			return op, boolean
		}
	case ^BoolData:
		#partial switch l in static_left {
		case ^IntegerData, ^FloatData, ^ScopeData, ^StringData:
			boolean := new(BoolData)
			boolean.content = false
			return op, boolean
		case ^BoolData:
			boolean := new(BoolData)
			boolean.content = l.content == r.content
			return op, boolean
		}
	case ^StringData:
		#partial switch l in static_left {
		case ^IntegerData, ^FloatData, ^ScopeData, ^BoolData:
			boolean := new(BoolData)
			boolean.content = false
			return op, boolean
		case ^StringData:
			boolean := new(BoolData)
			boolean.content = r.content == l.content
			return op, boolean
		}
	}
	analyzer_error(fmt.tprintf("Invalid static value for %s", op_kind), .Invalid_operator, pos)
	return empty, empty
}

analyze_int_operator :: #force_inline proc(idx: Node_Index) -> (ValueData, ValueData) {
	ast := get_ast()
	op_kind := node_operator_kind(ast, idx)
	left_idx := node_operator_left(ast, idx)
	right_idx := node_operator_right(ast, idx)
	pos := node_position(ast, idx)

	op := new(BinaryOpData)
	left, static_left := analyze_value(left_idx)
	right, static_right := analyze_value(right_idx)
	op.oprator = op_kind
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
					fmt.tprintf("Use of invalid %s as a shifting operator", op_kind),
					.Invalid_operator,
					pos,
				)
				return empty, empty
			}
		case:
			analyzer_error(
				fmt.tprintf("Cannot %s with a %s value", op_kind, debug_value_type(static_left)),
				.Invalid_operator,
				pos,
			)
			return empty, empty
		}
	case:
		analyzer_error(
			fmt.tprintf("Cannot %s with a %s increment", op_kind, debug_value_type(static_right)),
			.Invalid_operator,
			pos,
		)
		return empty, empty
	}
	return empty, empty
}

analyze_ordering_operator :: #force_inline proc(idx: Node_Index) -> (ValueData, ValueData) {
	ast := get_ast()
	op_kind := node_operator_kind(ast, idx)
	left_idx := node_operator_left(ast, idx)
	right_idx := node_operator_right(ast, idx)
	pos := node_position(ast, idx)

	op := new(BinaryOpData)
	left, static_left := analyze_value(left_idx)
	right, static_right := analyze_value(right_idx)
	op.oprator = op_kind
	op.left = left
	op.right = right

	#partial switch l in static_left {
	case ^IntegerData:
		#partial switch r in static_right {
		case ^IntegerData:
			boolData := new(BoolData)
			boolData.content = compare_func(l.content, r.content, op_kind)
			return op, boolData
		case ^FloatData:
			boolData := new(BoolData)
			boolData.content = compare_func(cast(f64)l.content, r.content, op_kind)
			return op, boolData
		case ^StringData:
			boolData := new(BoolData)
			boolData.content = compare_func(l.content, string_to_u64(r.content), op_kind)
			return op, boolData
		}
	case ^FloatData:
		#partial switch r in static_right {
		case ^IntegerData:
			boolData := new(BoolData)
			boolData.content = compare_func(l.content, cast(f64)r.content, op_kind)
			return op, boolData
		case ^FloatData:
			boolData := new(BoolData)
			boolData.content = compare_func(l.content, r.content, op_kind)
			return op, boolData
		case ^StringData:
			boolData := new(BoolData)
			boolData.content = compare_func(l.content, cast(f64)string_to_u64(r.content), op_kind)
			return op, boolData
		}
	case ^StringData:
		#partial switch r in static_right {
		case ^IntegerData:
			boolData := new(BoolData)
			boolData.content = compare_func(string_to_u64(l.content), r.content, op_kind)
			return op, boolData
		case ^FloatData:
			boolData := new(BoolData)
			boolData.content = compare_func(cast(f64)string_to_u64(l.content), r.content, op_kind)
			return op, boolData
		case ^StringData:
			boolData := new(BoolData)
			boolData.content = compare_func(
				string_to_u64(l.content),
				string_to_u64(r.content),
				op_kind,
			)
			return op, boolData
		}
	}
	analyzer_error(
		fmt.tprintf(
			"Cannot use %s operator on anything else than string integer or float",
			op_kind,
		),
		.Invalid_operator,
		pos,
	)
	return empty, empty
}

_resolve_symbol :: proc(name: string, index: int = 0) -> ^Binding {
	if index < 0 do return nil
	scope := get_analyzer().stack[index]
	for i := len(scope.content) - 1; i >= 0; i -= 1 {
		if scope.content[i].name == name do return scope.content[i]
	}
	return _resolve_symbol(name, index - 1)
}

resolve_symbol :: #force_inline proc(name: string) -> ^Binding {
	return _resolve_symbol(name, len(get_analyzer().stack) - 1)
}

resolve_named_property_symbol :: #force_inline proc(name: string, binding: ^Binding) -> ^Binding {
	if binding.symbolic_value == nil do return nil
	#partial switch scope in binding.symbolic_value {
	case ^ScopeData:
		for i := len(scope.content) - 1; i >= 0; i -= 1 {
			if scope.content[i].name == name do return scope.content[i]
		}
	}
	return nil
}

analyzer_error :: proc(message: string, error_type: Analyzer_Error_Type, position: Position) {
	analyzer := get_analyzer()
	error := Analyzer_Error {
		type     = error_type,
		message  = message,
		position = position,
	}
	append(&analyzer.errors, error)
}

debug_analyzer :: proc(analyzer: ^Analyzer, verbose: bool = false) {
	fmt.eprintln("=== ANALYZER DEBUG REPORT ===")
	fmt.eprintf("Errors: %d, Warnings: %d\n", len(analyzer.errors), len(analyzer.warnings))
	fmt.eprintf("Stack depth: %d\n\n", len(analyzer.stack))

	if len(analyzer.errors) > 0 {
		fmt.eprintln("ERRORS:")
		for error, i in analyzer.errors {
			debug_error(error, i)
		}
		fmt.eprintln()
	}

	if len(analyzer.warnings) > 0 {
		fmt.eprintln("WARNINGS:")
		for warning, i in analyzer.warnings {
			debug_error(warning, i)
		}
		fmt.eprintln()
	}

	fmt.eprintln("SCOPE STACK:")
	for scope, level in analyzer.stack {
		if level != 0 {
			debug_scope(scope, level - 1, verbose)
		}
	}
	fmt.eprintln("=== END DEBUG REPORT ===\n")
}

debug_error :: proc(error: Analyzer_Error, index: int) {
	fmt.eprintf(
		"  [%d] %v at line %d, col %d: %s\n",
		index,
		error.type,
		error.position.line,
		error.position.column,
		error.message,
	)
}

debug_scope :: proc(scope: ^ScopeData, level: int, verbose: bool = false) {
	indent := strings.repeat("  ", level)
	fmt.printf("%sScope [%d] - %d bindings:\n", indent, level, len(scope.content))
	for binding, i in scope.content {
		if binding != nil {
			debug_binding(binding, level + 1, i)
		}
	}
}

debug_raw_bindings :: proc(bindings: ^[dynamic]^Binding, level: int, verbose: bool = false) {
	indent := strings.repeat("  ", level)
	fmt.printf("%RawBindings [%d] - %d bindings:\n", indent, level, len(bindings))
	for binding, i in bindings {
		if binding != nil {
			debug_binding(binding, level + 1, i)
		}
	}
}

debug_binding :: proc(binding: ^Binding, indent_level: int, index: int) {
	indent := strings.repeat("  ", indent_level)
	kind_str := binding_kind_to_string(binding.kind)
	fmt.printf("%s[%d] %s '%s'", indent, index, kind_str, binding.name)
	if binding.constraint != nil {
		fmt.printf(" (constrained)")
	}
	if binding.symbolic_value != nil {
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
	if binding.symbolic_value != nil {
		if scope_data, is_scope := binding.symbolic_value.(^ScopeData); is_scope {
			debug_scope(scope_data, indent_level + 1, false)
		}
	}
}

debug_value_inline :: proc(value: ValueData) -> string {
	switch v in value {
	case ^ScopeData:
		return ""
	case ^CarveAData:
		return ""
	case ^StringData:
		return fmt.tprintf("String(\"%s\")", v.content)
	case ^IntegerData:
		if v.negative {
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
		if start_inline == "" || end_inline == "" do return "Range(<complex>)"
		return fmt.tprintf("Range(%s..%s)", start_inline, end_inline)
	case ^AExecuteData:
		target_inline := debug_value_inline(v.target)
		if target_inline == "" do return "Execute(<scope>)"
		return fmt.tprintf("Execute(%s)", target_inline)
	case ^RefData:
		if v.refered != nil do return fmt.tprintf("Ref(%s)", v.refered.name)
		return "Ref(<nil>)"
	case ^BinaryOpData:
		left_inline := debug_value_inline(v.left)
		right_inline := debug_value_inline(v.right)
		if left_inline == "" || right_inline == "" do return fmt.tprintf("BinaryOp(%v)", v.oprator)
		return fmt.tprintf("BinaryOp(%s %v %s)", left_inline, v.oprator, right_inline)
	case ^UnaryOpData:
		value_inline := debug_value_inline(v.value)
		if value_inline == "" do return fmt.tprintf("UnaryOp(%v)", v.oprator)
		return fmt.tprintf("UnaryOp(%v %s)", v.oprator, value_inline)
	case Empty:
		return "Empty"
	}
	return "Unknown"
}

debug_value_type :: proc(value: ValueData) -> string {
	switch v in value {
	case ^ScopeData:
		return fmt.tprintf("Scope(%d bindings)", len(v.content))
	case ^CarveAData:
		return "Carve"
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
	case ^AExecuteData:
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

replace_references_and_collapse :: proc(
	symbolic: ValueData,
	swapped: ^[dynamic]BindSwap,
) -> (
	ValueData,
	ValueData,
) {
	switch s in symbolic {
	case ^ScopeData:
		needs_update := false
		for binding in s.content {
			if binding != nil && contains_references(binding.symbolic_value, swapped) {
				needs_update = true
				break
			}
		}
		if !needs_update do return s, s
		new_scope := copy_scope(s)
		for binding in new_scope.content {
			if binding != nil {
				binding.symbolic_value, binding.static_value = replace_references_and_collapse(
					binding.symbolic_value,
					swapped,
				)
			}
		}
		return new_scope, new_scope

	case ^StringData, ^IntegerData, ^FloatData, ^BoolData, Empty:
		return symbolic, symbolic

	case ^RefData:
		for swap in swapped {
			if swap.old == s.refered {
				new_ref := new(RefData)
				new_ref.refered = swap.new
				return new_ref, swap.new.static_value
			}
		}
		if s.refered != nil do return s, s.refered.static_value
		return s, empty

	case ^PropertyData:
		new_source, static_source := replace_references_and_collapse(s.source, swapped)
		if new_source == s.source {
			if scope, ok := static_source.(^ScopeData); ok {
				for binding in scope.content {
					if binding.name == s.prop do return s, binding.static_value
				}
			}
			return s, empty
		}
		new_prop := new(PropertyData)
		new_prop.source = new_source
		new_prop.prop = s.prop
		if scope, ok := static_source.(^ScopeData); ok {
			for binding in scope.content {
				if binding.name == s.prop do return new_prop, binding.static_value
			}
		}
		return new_prop, empty

	case ^BinaryOpData:
		new_left, static_left := replace_references_and_collapse(s.left, swapped)
		new_right, static_right := replace_references_and_collapse(s.right, swapped)
		if new_left == s.left && new_right == s.right {
			static_result := evaluate_binary_op(static_left, static_right, s.oprator)
			return s, static_result
		}
		new_binop := new(BinaryOpData)
		new_binop.left = new_left
		new_binop.right = new_right
		new_binop.oprator = s.oprator
		static_result := evaluate_binary_op(static_left, static_right, s.oprator)
		return new_binop, static_result

	case ^UnaryOpData:
		new_value, static_value := replace_references_and_collapse(s.value, swapped)
		if new_value == s.value {
			static_result := evaluate_unary_op(static_value, s.oprator)
			return s, static_result
		}
		new_unary := new(UnaryOpData)
		new_unary.value = new_value
		new_unary.oprator = s.oprator
		static_result := evaluate_unary_op(static_value, s.oprator)
		return new_unary, static_result

	case ^CarveAData:
		new_target, static_target := replace_references_and_collapse(s.target, swapped)
		carves_changed := false
		new_carves := make([dynamic]^Binding, len(s.carves))
		for carve, i in s.carves {
			if contains_references(carve.symbolic_value, swapped) {
				carves_changed = true
				new_carve := copy_binding(carve)
				new_carve.symbolic_value, new_carve.static_value = replace_references_and_collapse(
					carve.symbolic_value,
					swapped,
				)
				new_carves[i] = new_carve
			} else {
				new_carves[i] = carve
			}
		}
		if new_target == s.target && !carves_changed {
			static_result := apply_carve(static_target, s.carves)
			return s, static_result
		}
		new_carve_data := new(CarveAData)
		new_carve_data.target = new_target
		new_carve_data.carves = new_carves
		static_result := apply_carve(static_target, new_carves)
		return new_carve_data, static_result

	case ^AExecuteData:
		new_target, static_target := replace_references_and_collapse(s.target, swapped)
		if new_target == s.target {
			if scope, ok := static_target.(^ScopeData); ok {
				for binding in scope.content {
					if binding.kind == .product do return s, binding.static_value
				}
			}
			return s, empty
		}
		new_exec := new(AExecuteData)
		new_exec.target = new_target
		new_exec.wrappers = s.wrappers
		if scope, ok := static_target.(^ScopeData); ok {
			for binding in scope.content {
				if binding.kind == .product do return new_exec, binding.static_value
			}
		}
		return new_exec, empty

	case ^RangeData:
		new_start, static_start := replace_references_and_collapse(s.start, swapped)
		new_end, static_end := replace_references_and_collapse(s.end, swapped)
		if new_start == s.start && new_end == s.end {
			static_range := new(RangeData)
			static_range.start = static_start
			static_range.end = static_end
			return s, static_range
		}
		new_range := new(RangeData)
		new_range.start = new_start
		new_range.end = new_end
		static_range := new(RangeData)
		static_range.start = static_start
		static_range.end = static_end
		return new_range, static_range

	case ^ReactiveData:
		new_initial, static_initial := replace_references_and_collapse(s.initial, swapped)
		if new_initial == s.initial do return s, static_initial
		new_reactive := new(ReactiveData)
		new_reactive.initial = new_initial
		return new_reactive, static_initial

	case ^EffectData:
		new_placeholder, static_placeholder := replace_references_and_collapse(
			s.placeholder,
			swapped,
		)
		if new_placeholder == s.placeholder do return s, static_placeholder
		new_effect := new(EffectData)
		new_effect.placeholder = new_placeholder
		return new_effect, static_placeholder
	}
	return symbolic, symbolic
}

contains_references :: proc(value: ValueData, swapped: ^[dynamic]BindSwap) -> bool {
	#partial switch v in value {
	case ^RefData:
		for swap in swapped {
			if swap.old == v.refered do return true
		}
		return false
	case ^PropertyData:
		return contains_references(v.source, swapped)
	case ^BinaryOpData:
		return contains_references(v.left, swapped) || contains_references(v.right, swapped)
	case ^UnaryOpData:
		return contains_references(v.value, swapped)
	case ^CarveAData:
		if contains_references(v.target, swapped) do return true
		for carve in v.carves {
			if contains_references(carve.symbolic_value, swapped) do return true
		}
		return false
	case ^AExecuteData:
		return contains_references(v.target, swapped)
	case ^RangeData:
		return contains_references(v.start, swapped) || contains_references(v.end, swapped)
	case ^ReactiveData:
		return contains_references(v.initial, swapped)
	case ^EffectData:
		return contains_references(v.placeholder, swapped)
	case ^ScopeData:
		for binding in v.content {
			if binding != nil && contains_references(binding.symbolic_value, swapped) do return true
		}
		return false
	}
	return false
}

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
				if r.content != 0 do result.content = l.content / r.content
			case .Mod:
				if r.content != 0 do result.content = l.content % r.content
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
				if r.content != 0 do result.content = l.content / r.content
			case .Mod:
				return empty
			}
			return result
		}
	}
	return empty
}

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
		if len(bytes) > 8 do return max(u64)
		result: u64 = 0
		for b in bytes {result = (result << 8) + cast(u64)b}
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
			if len(l.content) != len(r.content) do return false
			for i in 0 ..< len(l.content) {
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
