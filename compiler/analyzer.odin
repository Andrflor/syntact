package compiler

import "core:fmt"
import "core:strconv"
import "core:strings"

/* ======================================================================
 * SECTION 1: SHARED TYPES
 * ====================================================================== */

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

Analyzer_Error :: struct {
	type:     Analyzer_Error_Type,
	message:  string,
	position: Position,
}

/* ======================================================================
 * SECTION 2: SEMANTIC TYPES
 * ====================================================================== */

Scope_Id :: distinct u32
INVALID_SCOPE :: Scope_Id(0xFFFFFFFF)

Binding_Id :: distinct u32
INVALID_BINDING :: Binding_Id(0xFFFFFFFF)

Sem_Flag :: enum u16 {
	Has_Value,
	Self_Referential,
	Contains_Pull,
	Contains_Product,
	Is_Collapsible,
	Is_Pure,
	Has_Constraint,
	Has_Error,
	In_Progress,
}
Sem_Flags :: bit_set[Sem_Flag; u16]

Value_Kind :: enum u8 {
	None,
	Integer,
	Float,
	Bool,
	String_Literal,
	Scope,
	Ref,
	Builtin,
	Symbolic,
}

Builtin_Id :: enum u8 {
	None,
	B_U8,
	B_I8,
	B_U16,
	B_I16,
	B_U32,
	B_I32,
	B_U64,
	B_I64,
	B_F32,
	B_F64,
	B_Bool,
	B_Char,
	B_String,
}

Static_Value :: struct #raw_union {
	integer: Integer_SV,
	float_v: Float_SV,
	bool_v:  bool,
	str_span: Span,
	scope:   Node_Index,
	ref:     Binding_Id,
	builtin: Builtin_Id,
}

Integer_SV :: struct {
	content:  u64,
	kind:     IntegerKind,
	negative: bool,
}

Float_SV :: struct {
	content: f64,
	kind:    FloatKind,
}

Node_Sem :: struct {
	value_kind: Value_Kind,
	value:      Static_Value,
	flags:      Sem_Flags,
	scope_id:   Scope_Id,
}

Scope_Info :: struct {
	node:          Node_Index,
	parent:        Scope_Id,
	first_binding: Binding_Id,
	binding_count: u32,
	flags:         Sem_Flags,
	names:         map[string]Binding_Id,
}

Sem_Binding_Kind :: enum u8 {
	Pointing_Push,
	Pointing_Pull,
	Event_Push,
	Event_Pull,
	Resonance_Push,
	Resonance_Pull,
	Reactive_Push,
	Reactive_Pull,
	Inline_Push,
	Product,
}

Binding_Entry :: struct {
	node:            Node_Index,
	name:            Span,
	kind:            Sem_Binding_Kind,
	value_node:      Node_Index,
	constraint_node: Node_Index,
	scope_id:        Scope_Id,
	value_kind:      Value_Kind,
	value:           Static_Value,
	flags:           Sem_Flags,
}

Semantic :: struct {
	ast:            ^Ast,
	node_sems:      []Node_Sem,
	node_to_scope:  []Scope_Id,
	scopes:         [dynamic]Scope_Info,
	bindings:       [dynamic]Binding_Entry,
	scope_stack:    [dynamic]Scope_Id,
	errors:         [dynamic]Analyzer_Error,
	warnings:       [dynamic]Analyzer_Error,
	builtin_scope:  Scope_Id,
}

/* ======================================================================
 * SECTION 2: BUILTINS
 * ====================================================================== */

Builtin_Def :: struct {
	name:      string,
	id:        Builtin_Id,
	int_kind:  IntegerKind,
	flt_kind:  FloatKind,
	is_int:    bool,
	is_float:  bool,
	is_bool:   bool,
	is_string: bool,
}

BUILTIN_DEFS :: [14]Builtin_Def{
	{name = "u8",     id = .B_U8,     int_kind = .u8,   is_int = true},
	{name = "i8",     id = .B_I8,     int_kind = .i8,   is_int = true},
	{name = "u16",    id = .B_U16,    int_kind = .u16,  is_int = true},
	{name = "i16",    id = .B_I16,    int_kind = .i16,  is_int = true},
	{name = "u32",    id = .B_U32,    int_kind = .u32,  is_int = true},
	{name = "i32",    id = .B_I32,    int_kind = .i32,  is_int = true},
	{name = "u64",    id = .B_U64,    int_kind = .u64,  is_int = true},
	{name = "i64",    id = .B_I64,    int_kind = .i64,  is_int = true},
	{name = "f32",    id = .B_F32,    flt_kind = .f32,  is_float = true},
	{name = "f64",    id = .B_F64,    flt_kind = .f64,  is_float = true},
	{name = "bool",   id = .B_Bool,   is_bool = true},
	{name = "char",   id = .B_Char,   int_kind = .u8,   is_int = true},
	{name = "String", id = .B_String, is_string = true},
	{},
}

init_sem_builtins :: proc(s: ^Semantic) {
	builtin_scope := Scope_Info {
		node          = INVALID_NODE,
		parent        = INVALID_SCOPE,
		first_binding = Binding_Id(len(s.bindings)),
		binding_count = 0,
		flags         = {.Is_Pure},
	}
	s.builtin_scope = Scope_Id(len(s.scopes))
	append(&s.scopes, builtin_scope)

	count: u32 = 0
	for def in BUILTIN_DEFS {
		if def.id == .None do break
		entry := Binding_Entry {
			node            = INVALID_NODE,
			name            = EMPTY_SPAN,
			kind            = .Pointing_Push,
			value_node      = INVALID_NODE,
			constraint_node = INVALID_NODE,
			scope_id        = s.builtin_scope,
			value_kind      = .Builtin,
			flags           = {.Has_Value},
		}
		entry.value.builtin = def.id
		append(&s.bindings, entry)
		count += 1
	}
	s.scopes[s.builtin_scope].binding_count = count
}

resolve_builtin_by_name :: #force_inline proc(name: string) -> (Builtin_Id, bool) {
	for def in BUILTIN_DEFS {
		if def.id == .None do break
		if def.name == name do return def.id, true
	}
	return .None, false
}

builtin_def_by_id :: #force_inline proc(id: Builtin_Id) -> Builtin_Def {
	for def in BUILTIN_DEFS {
		if def.id == id do return def
	}
	return {}
}

builtin_default_value :: proc(id: Builtin_Id) -> (Value_Kind, Static_Value) {
	def := builtin_def_by_id(id)
	sv: Static_Value
	if def.is_int {
		sv.integer = Integer_SV{content = 0, kind = def.int_kind}
		return .Integer, sv
	}
	if def.is_float {
		sv.float_v = Float_SV{content = 0.0, kind = def.flt_kind}
		return .Float, sv
	}
	if def.is_bool {
		sv.bool_v = false
		return .Bool, sv
	}
	if def.is_string {
		sv.str_span = EMPTY_SPAN
		return .String_Literal, sv
	}
	return .None, sv
}

/* ======================================================================
 * SECTION 3: ANALYZER CORE
 * ====================================================================== */

analyze :: proc(cache: ^Cache, ast: ^Ast) -> bool {
	if ast == nil do return false

	s := new(Semantic)
	s.ast = ast
	s.node_sems = make([]Node_Sem, len(ast.node_kinds))
	s.node_to_scope = make([]Scope_Id, len(ast.node_kinds))
	for &v in s.node_to_scope { v = INVALID_SCOPE }
	s.scopes = make([dynamic]Scope_Info, 0, 32)
	s.bindings = make([dynamic]Binding_Entry, 0, 128)
	s.scope_stack = make([dynamic]Scope_Id, 0, 16)
	s.errors = make([dynamic]Analyzer_Error, 0)
	s.warnings = make([dynamic]Analyzer_Error, 0)

	init_sem_builtins(s)

	root_scope := Scope_Info {
		node          = ast_root(ast),
		parent        = s.builtin_scope,
		first_binding = Binding_Id(len(s.bindings)),
		binding_count = 0,
		flags         = {},
	}
	root_id := Scope_Id(len(s.scopes))
	append(&s.scopes, root_scope)

	append(&s.scope_stack, s.builtin_scope)
	append(&s.scope_stack, root_id)

	root_idx := ast_root(ast)
	if node_kind(ast, root_idx) == .ScopeNode {
		for child in node_children(ast, root_idx) {
			sem_walk(s, child)
		}
	} else {
		sem_error(s, "Root should be a scope", .Default, node_position(ast, root_idx))
	}

	sem_finalize_scope(s, root_id)

	pop(&s.scope_stack)
	pop(&s.scope_stack)

	cache.semantic = s
	cache.analyze_errors = s.errors
	cache.analyze_warnings = s.warnings

	if resolver.options.print_errors && len(s.errors) > 0 {
		debug_sem_errors(s)
	}

	if resolver.options.print_symbol_table {
		debug_sem_scopes(s)
	}

	return len(s.errors) == 0
}

/* ======================================================================
 * SECTION 4: SCOPE MANAGEMENT
 * ====================================================================== */

sem_current_scope :: #force_inline proc(s: ^Semantic) -> Scope_Id {
	return s.scope_stack[len(s.scope_stack) - 1]
}

sem_push_scope :: proc(s: ^Semantic, node: Node_Index) -> Scope_Id {
	parent := sem_current_scope(s)
	scope := Scope_Info {
		node          = node,
		parent        = parent,
		first_binding = Binding_Id(len(s.bindings)),
		binding_count = 0,
		flags         = {},
	}
	id := Scope_Id(len(s.scopes))
	append(&s.scopes, scope)
	append(&s.scope_stack, id)
	if node != INVALID_NODE {
		s.node_to_scope[node] = id
	}
	return id
}

sem_pop_scope :: #force_inline proc(s: ^Semantic) {
	pop(&s.scope_stack)
}

sem_add_binding :: proc(s: ^Semantic, entry: Binding_Entry) -> Binding_Id {
	id := Binding_Id(len(s.bindings))
	append(&s.bindings, entry)
	scope_id := sem_current_scope(s)
	s.scopes[scope_id].binding_count += 1
	if entry.name != EMPTY_SPAN {
		name := s.ast.source[entry.name.start:entry.name.end]
		s.scopes[scope_id].names[name] = id
	}
	return id
}

/* ======================================================================
 * SECTION 5: WALK
 * ====================================================================== */

sem_walk :: proc(s: ^Semantic, idx: Node_Index) {
	if idx == INVALID_NODE do return
	ast := s.ast
	kind := node_kind(ast, idx)

	s.node_sems[idx].scope_id = sem_current_scope(s)

	#partial switch kind {
	case .Pointing:
		sem_register_pointing(s, idx, .Pointing_Push)
	case .PointingPull:
		sem_register_pointing(s, idx, .Pointing_Pull)
	case .EventPush:
		sem_register_event_push(s, idx)
	case .EventPull:
		sem_register_event_pull(s, idx)
	case .ResonancePush:
		sem_register_pointing(s, idx, .Resonance_Push)
	case .ResonancePull:
		sem_register_pointing(s, idx, .Resonance_Pull)
	case .ReactivePush:
		sem_register_pointing(s, idx, .Reactive_Push)
	case .ReactivePull:
		sem_register_pointing(s, idx, .Reactive_Pull)
	case .Product:
		sem_register_product(s, idx)
	case .Constraint:
		sem_register_constraint(s, idx)
	case .Expand:
		sem_register_expand(s, idx)
	case .ScopeNode:
		scope_id := sem_push_scope(s, idx)
		for child in node_children(ast, idx) {
			sem_walk(s, child)
		}
		sem_finalize_scope(s, scope_id)
		sem_pop_scope(s)
		s.node_sems[idx].value_kind = .Scope
		s.node_sems[idx].value.scope = idx
		s.node_sems[idx].flags |= {.Has_Value}
	case:
		entry := Binding_Entry {
			node            = idx,
			name            = EMPTY_SPAN,
			kind            = .Inline_Push,
			value_node      = idx,
			constraint_node = INVALID_NODE,
			scope_id        = sem_current_scope(s),
		}
		sem_add_binding(s, entry)
	}
}

/* ======================================================================
 * SECTION 6: REGISTRATION
 * ====================================================================== */

sem_register_pointing :: proc(s: ^Semantic, idx: Node_Index, kind: Sem_Binding_Kind) {
	ast := s.ast

	from_idx: Node_Index
	to_idx: Node_Index

	if kind == .Pointing_Pull {
		from_idx = node_left(ast, idx)
		to_idx = node_right(ast, idx)
	} else {
		from_idx = node_left(ast, idx)
		to_idx = node_right(ast, idx)
	}

	entry := Binding_Entry {
		node            = idx,
		kind            = kind,
		value_node      = to_idx,
		constraint_node = INVALID_NODE,
		scope_id        = sem_current_scope(s),
	}

	sem_extract_name(s, from_idx, &entry)
	sem_add_binding(s, entry)
}

sem_register_event_push :: proc(s: ^Semantic, idx: Node_Index) {
	ast := s.ast
	from_idx := node_left(ast, idx)
	to_idx := node_right(ast, idx)

	entry := Binding_Entry {
		node            = idx,
		kind            = .Event_Push,
		value_node      = to_idx,
		constraint_node = INVALID_NODE,
		scope_id        = sem_current_scope(s),
	}

	if from_idx != INVALID_NODE {
		sem_extract_name(s, from_idx, &entry)
	}
	sem_add_binding(s, entry)
}

sem_register_event_pull :: proc(s: ^Semantic, idx: Node_Index) {
	ast := s.ast
	from_idx := node_event_pull_from(ast, idx)
	to_idx := node_event_pull_to(ast, idx)

	entry := Binding_Entry {
		node            = idx,
		kind            = .Event_Pull,
		value_node      = to_idx,
		constraint_node = INVALID_NODE,
		scope_id        = sem_current_scope(s),
	}

	if from_idx != INVALID_NODE {
		sem_extract_name(s, from_idx, &entry)
	}
	sem_add_binding(s, entry)
}

sem_register_product :: proc(s: ^Semantic, idx: Node_Index) {
	ast := s.ast
	operand := node_unary_operand(ast, idx)

	entry := Binding_Entry {
		node            = idx,
		name            = EMPTY_SPAN,
		kind            = .Product,
		value_node      = operand,
		constraint_node = INVALID_NODE,
		scope_id        = sem_current_scope(s),
	}
	sem_add_binding(s, entry)
}

sem_register_constraint :: proc(s: ^Semantic, idx: Node_Index) {
	ast := s.ast
	constraint_idx := node_left(ast, idx)
	name_idx := node_right(ast, idx)

	entry := Binding_Entry {
		node            = idx,
		kind            = .Pointing_Push,
		value_node      = INVALID_NODE,
		constraint_node = constraint_idx,
		scope_id        = sem_current_scope(s),
		flags           = {.Has_Constraint},
	}

	if name_idx != INVALID_NODE {
		nk := node_kind(ast, name_idx)
		#partial switch nk {
		case .Identifier:
			entry.name = node_name_span(ast, name_idx)
		case .Carve:
			source_idx := node_carve_source(ast, name_idx)
			if source_idx != INVALID_NODE && node_kind(ast, source_idx) == .Identifier {
				entry.name = node_name_span(ast, source_idx)
			}
		case .ScopeNode:
		case:
			sem_error(
				s,
				"The : constraint indicator must be followed by an identifier or nothing",
				.Invalid_Constraint_Name,
				node_position(ast, name_idx),
			)
		}
	}

	sem_add_binding(s, entry)
}

sem_register_expand :: proc(s: ^Semantic, idx: Node_Index) {
	ast := s.ast
	operand := node_unary_operand(ast, idx)

	entry := Binding_Entry {
		node            = idx,
		name            = EMPTY_SPAN,
		kind            = .Inline_Push,
		value_node      = operand,
		constraint_node = INVALID_NODE,
		scope_id        = sem_current_scope(s),
	}
	sem_add_binding(s, entry)
}

sem_extract_name :: proc(s: ^Semantic, idx: Node_Index, entry: ^Binding_Entry) {
	if idx == INVALID_NODE do return
	ast := s.ast
	kind := node_kind(ast, idx)

	#partial switch kind {
	case .Constraint:
		name_idx := node_right(ast, idx)
		constraint_idx := node_left(ast, idx)
		if name_idx != INVALID_NODE {
			nk := node_kind(ast, name_idx)
			#partial switch nk {
			case .Identifier:
				entry.name = node_name_span(ast, name_idx)
			case .Carve:
				source_idx := node_carve_source(ast, name_idx)
				if source_idx != INVALID_NODE && node_kind(ast, source_idx) == .Identifier {
					entry.name = node_name_span(ast, source_idx)
				} else {
					sem_error(
						s,
						"The : constraint indicator must be followed by an identifier or nothing",
						.Invalid_Constraint_Name,
						node_position(ast, name_idx),
					)
				}
			case .ScopeNode:
			case:
				sem_error(
					s,
					"The : constraint indicator must be followed by an identifier or nothing",
					.Invalid_Constraint_Name,
					node_position(ast, name_idx),
				)
			}
		}
		if constraint_idx != INVALID_NODE {
			entry.constraint_node = constraint_idx
			entry.flags |= {.Has_Constraint}
		}
	case .Identifier:
		entry.name = node_name_span(ast, idx)
	case:
		sem_error(
			s,
			"Cannot use anything other than constraint or identifier as binding name",
			.Invalid_Binding_Name,
			node_position(ast, idx),
		)
	}
}

/* ======================================================================
 * SECTION 7: FINALIZE SCOPE
 * ====================================================================== */

sem_finalize_scope :: proc(s: ^Semantic, scope_id: Scope_Id) {
	scope := &s.scopes[scope_id]
	first := u32(scope.first_binding)
	count := scope.binding_count
	flags: Sem_Flags

	has_product := false
	has_pull := false
	has_effect := false
	all_static := true

	for i in first ..< first + count {
		entry := &s.bindings[i]

		sem_evaluate_binding(s, entry)

		#partial switch entry.kind {
		case .Product:
			has_product = true
		case .Pointing_Pull:
			has_pull = true
		case .Event_Push, .Event_Pull:
			has_effect = true
		case .Resonance_Push, .Resonance_Pull:
			has_effect = true
		}

		if .Has_Value not_in entry.flags {
			all_static = false
		}
		if .Self_Referential in entry.flags {
			flags |= {.Self_Referential}
		}
	}

	if has_product do flags |= {.Contains_Product}
	if has_pull do flags |= {.Contains_Pull}

	if has_product && !has_pull && !has_effect &&
	   .Self_Referential not_in flags && all_static {
		flags |= {.Is_Collapsible, .Is_Pure}
	}

	scope.flags = flags

	if scope.node != INVALID_NODE {
		sem := &s.node_sems[scope.node]
		sem.flags |= flags
	}
}

sem_evaluate_binding :: proc(s: ^Semantic, entry: ^Binding_Entry) {
	if entry.value_node == INVALID_NODE && entry.constraint_node == INVALID_NODE {
		entry.value_kind = .None
		entry.flags |= {.Has_Value}
		return
	}

	if entry.constraint_node != INVALID_NODE {
		sem_evaluate_constraint(s, entry)
	}

	if entry.value_node != INVALID_NODE {
		vk, sv := sem_evaluate_value(s, entry.value_node)
		entry.value_kind = vk
		entry.value = sv
		if vk != .None {
			entry.flags |= {.Has_Value}
		}
		if vk == .Symbolic {
			entry.flags |= {.Self_Referential}
		}
	} else if .Has_Constraint in entry.flags {
		vk, sv := sem_resolve_default(s, entry.constraint_node)
		entry.value_kind = vk
		entry.value = sv
		if vk != .None {
			entry.flags |= {.Has_Value}
		}
	}
}

sem_evaluate_constraint :: proc(s: ^Semantic, entry: ^Binding_Entry) {
	vk, _ := sem_evaluate_value(s, entry.constraint_node)
	if vk == .Scope || vk == .Builtin {
		entry.flags |= {.Has_Constraint}
	}
}

sem_resolve_default :: proc(s: ^Semantic, constraint_node: Node_Index) -> (Value_Kind, Static_Value) {
	if constraint_node == INVALID_NODE do return .None, {}

	sem := s.node_sems[constraint_node]
	if sem.value_kind == .Builtin {
		return builtin_default_value(sem.value.builtin)
	}

	if sem.value_kind == .Scope {
		scope_node := sem.value.scope
		scope_id, ok := sem_find_scope(s, scope_node)
		if !ok do return .None, {}
		scope := s.scopes[scope_id]
		first := u32(scope.first_binding)
		for i in first ..< first + scope.binding_count {
			if s.bindings[i].kind == .Product {
				return s.bindings[i].value_kind, s.bindings[i].value
			}
		}
	}

	return .None, {}
}

sem_find_scope :: #force_inline proc(s: ^Semantic, node: Node_Index) -> (Scope_Id, bool) {
	if node == INVALID_NODE do return INVALID_SCOPE, false
	id := s.node_to_scope[node]
	return id, id != INVALID_SCOPE
}

/* ======================================================================
 * SECTION 8: VALUE EVALUATION
 * ====================================================================== */

sem_evaluate_value :: proc(s: ^Semantic, idx: Node_Index) -> (Value_Kind, Static_Value) {
	if idx == INVALID_NODE do return .None, {}

	sem := &s.node_sems[idx]

	if .Has_Value in sem.flags {
		return sem.value_kind, sem.value
	}

	if .In_Progress in sem.flags {
		sem.flags |= {.Self_Referential}
		return .Symbolic, {}
	}

	sem.flags |= {.In_Progress}
	defer sem.flags -= {.In_Progress}

	ast := s.ast
	kind := node_kind(ast, idx)

	vk: Value_Kind
	sv: Static_Value

	#partial switch kind {
	case .Literal:
		vk, sv = sem_evaluate_literal(s, idx)
	case .Identifier:
		vk, sv = sem_evaluate_identifier(s, idx)
	case .ScopeNode:
		if .Has_Value not_in sem.flags {
			scope_id := sem_push_scope(s, idx)
			for child in node_children(ast, idx) {
				sem_walk(s, child)
			}
			sem_finalize_scope(s, scope_id)
			sem_pop_scope(s)
		}
		sv.scope = idx
		vk = .Scope
	case .Operator:
		vk, sv = sem_evaluate_operator(s, idx)
	case .Property:
		vk, sv = sem_evaluate_property(s, idx)
	case .Range:
		vk, sv = sem_evaluate_range(s, idx)
	case .Carve:
		vk, sv = sem_evaluate_carve(s, idx)
	case .Execute:
		vk, sv = sem_evaluate_execute(s, idx)
	case .Pattern:
		vk, sv = sem_evaluate_pattern(s, idx)
	case .CompileTime:
		operand := node_unary_operand(ast, idx)
		vk, sv = sem_evaluate_value(s, operand)
	case .Constraint:
		constraint_idx := node_left(ast, idx)
		vk, sv = sem_evaluate_value(s, constraint_idx)
		if vk == .Scope || vk == .Builtin {
			dvk, dsv := sem_resolve_default(s, constraint_idx)
			if dvk != .None {
				vk = dvk
				sv = dsv
			}
		}
	case .External:
		vk = .Symbolic
	case .Expand:
		operand := node_unary_operand(ast, idx)
		vk, sv = sem_evaluate_value(s, operand)
	case .Enforce:
		vk = .Symbolic
	case .EventPull, .EventPush, .ResonancePush, .ResonancePull,
	     .ReactivePush, .ReactivePull, .Pointing, .PointingPull, .Product:
		sem_error(
			s,
			"Cannot use a binding definition as a binding value",
			.Invalid_Binding_Value,
			node_position(ast, idx),
		)
		return .None, {}
	case .Branch:
		sem_error(
			s,
			"Branch found outside a pattern node",
			.Invalid_Binding_Value,
			node_position(ast, idx),
		)
		return .None, {}
	}

	sem.value_kind = vk
	sem.value = sv
	if vk != .None {
		sem.flags |= {.Has_Value}
	}
	return vk, sv
}

/* ======================================================================
 * SECTION 9: LITERAL EVALUATION
 * ====================================================================== */

sem_evaluate_literal :: proc(s: ^Semantic, idx: Node_Index) -> (Value_Kind, Static_Value) {
	ast := s.ast
	lit_kind := node_literal_kind(ast, idx)
	text := node_text(ast, idx)
	sv: Static_Value

	switch lit_kind {
	case .Integer:
		content, ok := strconv.parse_int(text)
		if ok do sv.integer.content = u64(content)
		sv.integer.kind = .none
		return .Integer, sv
	case .Float:
		content, ok := strconv.parse_f64(text)
		if ok do sv.float_v.content = content
		sv.float_v.kind = .none
		return .Float, sv
	case .String:
		sv.str_span = node_span(ast, idx)
		return .String_Literal, sv
	case .Bool:
		sv.bool_v = text == "true"
		return .Bool, sv
	case .Hexadecimal:
		hex_text := text
		if len(hex_text) > 2 && hex_text[0] == '0' && (hex_text[1] == 'x' || hex_text[1] == 'X') {
			hex_text = hex_text[2:]
		}
		content, ok := strconv.parse_int(hex_text, 16)
		if ok do sv.integer.content = u64(content)
		sv.integer.kind = .none
		return .Integer, sv
	case .Binary:
		bin_text := text
		if len(bin_text) > 2 && bin_text[0] == '0' && (bin_text[1] == 'b' || bin_text[1] == 'B') {
			bin_text = bin_text[2:]
		}
		content, ok := strconv.parse_int(bin_text, 2)
		if ok do sv.integer.content = u64(content)
		sv.integer.kind = .none
		return .Integer, sv
	}
	return .None, {}
}

/* ======================================================================
 * SECTION 10: IDENTIFIER RESOLUTION
 * ====================================================================== */

sem_span_str :: #force_inline proc(ast: ^Ast, span: Span) -> string {
	if span == EMPTY_SPAN do return ""
	return ast.source[span.start:span.end]
}

sem_resolve_symbol :: proc(s: ^Semantic, name: string) -> (Binding_Id, bool) {
	for i := len(s.scope_stack) - 1; i >= 0; i -= 1 {
		sid := s.scope_stack[i]
		if sid == s.builtin_scope {
			bid, found := sem_resolve_builtin_binding(s, name)
			if found do return bid, true
			continue
		}
		if bid, ok := s.scopes[sid].names[name]; ok {
			return bid, true
		}
	}
	return INVALID_BINDING, false
}

sem_resolve_builtin_binding :: proc(s: ^Semantic, name: string) -> (Binding_Id, bool) {
	scope := s.scopes[s.builtin_scope]
	first := u32(scope.first_binding)
	for def, i in BUILTIN_DEFS {
		if def.id == .None do break
		if def.name == name {
			return Binding_Id(first + u32(i)), true
		}
	}
	return INVALID_BINDING, false
}

sem_resolve_in_scope :: proc(s: ^Semantic, scope_id: Scope_Id, name: string) -> (Binding_Id, bool) {
	if bid, ok := s.scopes[scope_id].names[name]; ok {
		return bid, true
	}

	scope := s.scopes[scope_id]
	first := u32(scope.first_binding)
	for i in first ..< first + scope.binding_count {
		entry := &s.bindings[i]
		if entry.kind == .Inline_Push && entry.value_kind == .Scope {
			expanded_id, ok := sem_find_scope(s, entry.value.scope)
			if ok {
				bid, found := sem_resolve_in_scope(s, expanded_id, name)
				if found do return bid, true
			}
		}
	}

	return INVALID_BINDING, false
}

sem_evaluate_identifier :: proc(s: ^Semantic, idx: Node_Index) -> (Value_Kind, Static_Value) {
	ast := s.ast
	name := node_name_str(ast, idx)

	bid, found := sem_resolve_symbol(s, name)
	if !found {
		sem_error(
			s,
			fmt.tprintf("Undefined identifier named %s found", name),
			.Undefined_Identifier,
			node_position(ast, idx),
		)
		return .None, {}
	}

	entry := &s.bindings[bid]
	sv: Static_Value
	sv.ref = bid

	if .Has_Value in entry.flags {
		return entry.value_kind, entry.value
	}

	return .Ref, sv
}

/* ======================================================================
 * SECTION 11: OPERATOR EVALUATION
 * ====================================================================== */

sem_evaluate_operator :: proc(s: ^Semantic, idx: Node_Index) -> (Value_Kind, Static_Value) {
	ast := s.ast
	op_kind := node_operator_kind(ast, idx)
	left_idx := node_operator_left(ast, idx)
	right_idx := node_operator_right(ast, idx)
	pos := node_position(ast, idx)

	if left_idx == INVALID_NODE && right_idx != INVALID_NODE {
		return sem_evaluate_unary(s, idx, right_idx, op_kind)
	}
	if right_idx == INVALID_NODE && left_idx != INVALID_NODE {
		return sem_evaluate_unary(s, idx, left_idx, op_kind)
	}
	if left_idx == INVALID_NODE && right_idx == INVALID_NODE {
		return .None, {}
	}

	lvk, lsv := sem_evaluate_value(s, left_idx)
	rvk, rsv := sem_evaluate_value(s, right_idx)

	if lvk == .Symbolic || rvk == .Symbolic {
		return .Symbolic, {}
	}

	#partial switch op_kind {
	case .Add, .Subtract, .Multiply, .Divide, .Mod:
		return sem_fold_math(lvk, lsv, rvk, rsv, op_kind, pos, s)
	case .And, .Or, .Xor:
		return sem_fold_bitwise(lvk, lsv, rvk, rsv, op_kind, pos, s)
	case .Less, .Greater, .LessEqual, .GreaterEqual:
		return sem_fold_comparison(lvk, lsv, rvk, rsv, op_kind, pos, s)
	case .Equal:
		return sem_fold_equality(lvk, lsv, rvk, rsv, false, pos, s)
	case .NotEqual:
		return sem_fold_equality(lvk, lsv, rvk, rsv, true, pos, s)
	case .LShift, .RShift:
		return sem_fold_shift(lvk, lsv, rvk, rsv, op_kind, pos, s)
	case .Not:
		sem_error(s, "Cannot use not as binary operator", .Invalid_operator, pos)
		return .None, {}
	}
	return .Symbolic, {}
}

sem_evaluate_unary :: proc(
	s: ^Semantic,
	op_idx: Node_Index,
	child_idx: Node_Index,
	op_kind: Operator_Kind,
) -> (Value_Kind, Static_Value) {
	pos := node_position(s.ast, op_idx)
	cvk, csv := sem_evaluate_value(s, child_idx)

	if cvk == .Symbolic do return .Symbolic, {}

	sv: Static_Value

	switch op_kind {
	case .Subtract:
		if cvk == .Integer {
			sv.integer = csv.integer
			sv.integer.negative = true
			return .Integer, sv
		}
		if cvk == .Float {
			sv.float_v = csv.float_v
			sv.float_v.content = -csv.float_v.content
			return .Float, sv
		}
		sem_error(s, "Cannot negate anything other than int or float", .Invalid_operator, pos)
	case .Not:
		if cvk == .Bool {
			sv.bool_v = !csv.bool_v
			return .Bool, sv
		}
		if cvk == .Integer {
			sv.integer = csv.integer
			sv.integer.content = ~csv.integer.content
			return .Integer, sv
		}
	case .Add, .Multiply, .Divide, .Mod, .Equal, .Less, .Greater, .NotEqual,
	     .LessEqual, .GreaterEqual, .And, .Or, .Xor, .RShift, .LShift:
		sem_error(s, "Operator should not be used as unary", .Invalid_operator, pos)
		return cvk, csv
	}
	return cvk, csv
}

sem_fold_math :: proc(
	lvk: Value_Kind, lsv: Static_Value,
	rvk: Value_Kind, rsv: Static_Value,
	op: Operator_Kind,
	pos: Position,
	s: ^Semantic,
) -> (Value_Kind, Static_Value) {
	sv: Static_Value

	if lvk == .Integer && rvk == .Integer {
		l := lsv.integer
		r := rsv.integer
		sv.integer.kind = l.kind if l.kind != .none else r.kind
		#partial switch op {
		case .Add:      sv.integer.content = l.content + r.content
		case .Subtract: sv.integer.content = l.content - r.content
		case .Multiply: sv.integer.content = l.content * r.content
		case .Divide:
			if r.content != 0 do sv.integer.content = l.content / r.content
		case .Mod:
			if r.content != 0 do sv.integer.content = l.content % r.content
		}
		return .Integer, sv
	}

	if lvk == .Float && rvk == .Float {
		l := lsv.float_v
		r := rsv.float_v
		sv.float_v.kind = l.kind if l.kind != .none else r.kind
		#partial switch op {
		case .Add:      sv.float_v.content = l.content + r.content
		case .Subtract: sv.float_v.content = l.content - r.content
		case .Multiply: sv.float_v.content = l.content * r.content
		case .Divide:
			if r.content != 0 do sv.float_v.content = l.content / r.content
		case .Mod:
			sem_error(s, "Mod is only allowed with integers", .Invalid_operator, pos)
			return .None, {}
		}
		return .Float, sv
	}

	sem_error(s, fmt.tprintf("Incompatible types for %s", op), .Invalid_operator, pos)
	return .None, {}
}

sem_fold_bitwise :: proc(
	lvk: Value_Kind, lsv: Static_Value,
	rvk: Value_Kind, rsv: Static_Value,
	op: Operator_Kind,
	pos: Position,
	s: ^Semantic,
) -> (Value_Kind, Static_Value) {
	sv: Static_Value

	if lvk == .Integer && rvk == .Integer {
		l := lsv.integer
		r := rsv.integer
		sv.integer.kind = l.kind if l.kind != .none else r.kind
		#partial switch op {
		case .And: sv.integer.content = l.content & r.content
		case .Or:  sv.integer.content = l.content | r.content
		case .Xor: sv.integer.content = l.content ~ r.content
		}
		return .Integer, sv
	}

	if lvk == .Bool && rvk == .Bool {
		#partial switch op {
		case .And: sv.bool_v = lsv.bool_v && rsv.bool_v
		case .Or:  sv.bool_v = lsv.bool_v || rsv.bool_v
		case .Xor: sv.bool_v = lsv.bool_v ~ rsv.bool_v
		}
		return .Bool, sv
	}

	sem_error(s, fmt.tprintf("Incompatible types for %s", op), .Invalid_operator, pos)
	return .None, {}
}

sem_fold_comparison :: proc(
	lvk: Value_Kind, lsv: Static_Value,
	rvk: Value_Kind, rsv: Static_Value,
	op: Operator_Kind,
	pos: Position,
	s: ^Semantic,
) -> (Value_Kind, Static_Value) {
	sv: Static_Value

	sem_cmp :: #force_inline proc(a, b: $T, op: Operator_Kind) -> bool {
		#partial switch op {
		case .Less:         return a < b
		case .Greater:      return a > b
		case .LessEqual:    return a <= b
		case .GreaterEqual: return a >= b
		}
		return false
	}

	if lvk == .Integer && rvk == .Integer {
		sv.bool_v = sem_cmp(lsv.integer.content, rsv.integer.content, op)
		return .Bool, sv
	}
	if lvk == .Float && rvk == .Float {
		sv.bool_v = sem_cmp(lsv.float_v.content, rsv.float_v.content, op)
		return .Bool, sv
	}
	if lvk == .Integer && rvk == .Float {
		sv.bool_v = sem_cmp(f64(lsv.integer.content), rsv.float_v.content, op)
		return .Bool, sv
	}
	if lvk == .Float && rvk == .Integer {
		sv.bool_v = sem_cmp(lsv.float_v.content, f64(rsv.integer.content), op)
		return .Bool, sv
	}

	sem_error(s, fmt.tprintf("Incompatible types for %s", op), .Invalid_operator, pos)
	return .None, {}
}

sem_fold_equality :: proc(
	lvk: Value_Kind, lsv: Static_Value,
	rvk: Value_Kind, rsv: Static_Value,
	negate: bool,
	pos: Position,
	s: ^Semantic,
) -> (Value_Kind, Static_Value) {
	sv: Static_Value
	equal := false

	if lvk != rvk {
		equal = false
	} else {
		switch lvk {
		case .Integer:
			equal = lsv.integer.content == rsv.integer.content
		case .Float:
			equal = lsv.float_v.content == rsv.float_v.content
		case .Bool:
			equal = lsv.bool_v == rsv.bool_v
		case .String_Literal:
			l := sem_span_str(s.ast, lsv.str_span)
			r := sem_span_str(s.ast, rsv.str_span)
			equal = l == r
		case .Scope:
			equal = lsv.scope == rsv.scope
		case .Builtin:
			equal = lsv.builtin == rsv.builtin
		case .None:
			equal = true
		case .Ref, .Symbolic:
			return .Symbolic, {}
		}
	}

	sv.bool_v = equal ~ negate
	return .Bool, sv
}

sem_fold_shift :: proc(
	lvk: Value_Kind, lsv: Static_Value,
	rvk: Value_Kind, rsv: Static_Value,
	op: Operator_Kind,
	pos: Position,
	s: ^Semantic,
) -> (Value_Kind, Static_Value) {
	sv: Static_Value

	if lvk == .Integer && rvk == .Integer {
		sv.integer.kind = lsv.integer.kind
		sv.integer.negative = lsv.integer.negative
		#partial switch op {
		case .LShift: sv.integer.content = lsv.integer.content << rsv.integer.content
		case .RShift: sv.integer.content = lsv.integer.content >> rsv.integer.content
		}
		return .Integer, sv
	}

	sem_error(s, fmt.tprintf("Shift requires integer operands, got %s", op), .Invalid_operator, pos)
	return .None, {}
}

/* ======================================================================
 * SECTION 12: PROPERTY EVALUATION
 * ====================================================================== */

sem_evaluate_property :: proc(s: ^Semantic, idx: Node_Index) -> (Value_Kind, Static_Value) {
	ast := s.ast
	prop_idx := node_right(ast, idx)
	source_idx := node_left(ast, idx)
	pos := node_position(ast, idx)

	if prop_idx == INVALID_NODE || node_kind(ast, prop_idx) != .Identifier {
		sem_error(s, "Invalid property access without identifier", .Invalid_Property_Access, pos)
		return .None, {}
	}

	prop_name := node_name_str(ast, prop_idx)

	if source_idx != INVALID_NODE {
		svk, ssv := sem_evaluate_value(s, source_idx)
		if svk == .Scope {
			scope_id, ok := sem_find_scope(s, ssv.scope)
			if ok {
				bid, found := sem_resolve_in_scope(s, scope_id, prop_name)
				if found {
					entry := &s.bindings[bid]
					if .Has_Value in entry.flags {
						return entry.value_kind, entry.value
					}
					sv: Static_Value
					sv.ref = bid
					return .Ref, sv
				}
			}
		}
		if svk == .Builtin {
			return .Symbolic, {}
		}
	} else {
		scope_id := sem_current_scope(s)
		bid, found := sem_resolve_in_scope(s, scope_id, prop_name)
		if found {
			entry := &s.bindings[bid]
			if .Has_Value in entry.flags {
				return entry.value_kind, entry.value
			}
		}
	}

	sem_error(s, fmt.tprintf("There is no property %s", prop_name), .Invalid_Property_Access, pos)
	return .None, {}
}

/* ======================================================================
 * SECTION 13: RANGE EVALUATION
 * ====================================================================== */

sem_evaluate_range :: proc(s: ^Semantic, idx: Node_Index) -> (Value_Kind, Static_Value) {
	ast := s.ast
	start_idx := node_left(ast, idx)
	end_idx := node_right(ast, idx)

	svk, _ := sem_evaluate_value(s, start_idx)
	evk, _ := sem_evaluate_value(s, end_idx)

	if svk != .Integer || evk != .Integer {
		sem_error(
			s,
			"Trying to create a range with a non integer value",
			.Invalid_Range,
			node_position(ast, idx),
		)
	}

	return .Symbolic, {}
}

/* ======================================================================
 * SECTION 14: CARVE EVALUATION
 * ====================================================================== */

sem_evaluate_carve_children :: proc(s: ^Semantic, idx: Node_Index, target_scope_id: Scope_Id = INVALID_SCOPE) {
	ast := s.ast
	for child in node_carve_children(ast, idx) {
		ck := node_kind(ast, child)
		#partial switch ck {
		case .Pointing, .PointingPull:
			from_idx := node_left(ast, child)
			to_idx := node_right(ast, child)
			if to_idx != INVALID_NODE {
				sem_evaluate_value(s, to_idx)
			}
			if target_scope_id != INVALID_SCOPE && from_idx != INVALID_NODE && node_kind(ast, from_idx) == .Identifier {
				name := node_name_str(ast, from_idx)
				_, found := sem_resolve_in_scope(s, target_scope_id, name)
				if !found {
					sem_error(s, fmt.tprintf("Unknown override '%s' in carve", name), .Undefined_Identifier, node_position(ast, from_idx))
				}
			}
		case:
			sem_evaluate_value(s, child)
		}
	}
}

sem_evaluate_carve :: proc(s: ^Semantic, idx: Node_Index) -> (Value_Kind, Static_Value) {
	ast := s.ast
	source_idx := node_carve_source(ast, idx)
	pos := node_position(ast, idx)

	tvk, tsv := sem_evaluate_value(s, source_idx)

	if tvk == .Symbolic {
		return .Symbolic, {}
	}

	if tvk == .Builtin {
		sem_evaluate_carve_children(s, idx)
		return .Builtin, tsv
	}

	if tvk != .Scope && tvk != .Ref {
		sem_evaluate_carve_children(s, idx)
		if tvk == .None {
			sem_error(s, "Trying to carve an element that does not resolve to a scope", .Invalid_Carve, pos)
		}
		return tvk, tsv
	}

	target_node := tsv.scope
	if tvk == .Ref {
		entry := &s.bindings[tsv.ref]
		if entry.value_kind == .Scope {
			target_node = entry.value.scope
		} else {
			sem_evaluate_carve_children(s, idx)
			return entry.value_kind, entry.value
		}
	}

	target_scope_id, ok := sem_find_scope(s, target_node)
	if !ok {
		sem_evaluate_carve_children(s, idx)
		return .Symbolic, {}
	}

	target_flags := s.scopes[target_scope_id].flags

	sem_evaluate_carve_children(s, idx, target_scope_id)

	if .Self_Referential in target_flags {
		return .Symbolic, {}
	}

	sv: Static_Value
	sv.scope = target_node
	return .Scope, sv
}

sem_apply_carve_overlay :: proc(
	s: ^Semantic,
	target_scope_id: Scope_Id,
	carve_node: Node_Index,
) -> (Value_Kind, Static_Value) {
	scope := s.scopes[target_scope_id]
	first := u32(scope.first_binding)

	for i in first ..< first + scope.binding_count {
		entry := &s.bindings[i]
		if entry.kind == .Product {
			if .Has_Value in entry.flags {
				return entry.value_kind, entry.value
			}
		}
	}

	return .None, {}
}

/* ======================================================================
 * SECTION 15: EXECUTE EVALUATION
 * ====================================================================== */

sem_evaluate_execute :: proc(s: ^Semantic, idx: Node_Index) -> (Value_Kind, Static_Value) {
	ast := s.ast
	target_idx := node_execute_target(ast, idx)

	tvk, tsv := sem_evaluate_value(s, target_idx)

	if tvk == .Symbolic {
		return .Symbolic, {}
	}

	if tvk == .Scope {
		scope_id, ok := sem_find_scope(s, tsv.scope)
		if ok {
			scope := s.scopes[scope_id]
			if .Is_Collapsible in scope.flags {
				first := u32(scope.first_binding)
				for i in first ..< first + scope.binding_count {
					entry := &s.bindings[i]
					if entry.kind == .Product {
						if .Has_Value in entry.flags {
							return entry.value_kind, entry.value
						}
					}
				}
			}
		}
	}

	return .Symbolic, {}
}

/* ======================================================================
 * SECTION 16: PATTERN EVALUATION
 * ====================================================================== */

sem_evaluate_pattern :: proc(s: ^Semantic, idx: Node_Index) -> (Value_Kind, Static_Value) {
	ast := s.ast
	target_idx := node_pattern_target(ast, idx)
	branches := node_pattern_branches(ast, idx)

	tvk, tsv := sem_evaluate_value(s, target_idx)

	i := 0
	for i < len(branches) {
		pattern_idx := Node_Index(branches[i])
		product_idx := Node_Index(branches[i + 1]) if i + 1 < len(branches) else INVALID_NODE

		if sem_pattern_matches(s, tvk, tsv, pattern_idx) {
			if product_idx != INVALID_NODE {
				return sem_evaluate_value(s, product_idx)
			}
			return tvk, tsv
		}
		i += 2
	}

	return .Symbolic, {}
}

sem_pattern_matches :: proc(
	s: ^Semantic,
	tvk: Value_Kind,
	tsv: Static_Value,
	pattern_idx: Node_Index,
) -> bool {
	if pattern_idx == INVALID_NODE do return true
	ast := s.ast
	pat_kind := node_kind(ast, pattern_idx)

	#partial switch pat_kind {
	case .Literal:
		pvk, psv := sem_evaluate_literal(s, pattern_idx)
		if pvk != tvk do return false
		switch pvk {
		case .Integer:      return tsv.integer.content == psv.integer.content
		case .Float:        return tsv.float_v.content == psv.float_v.content
		case .Bool:         return tsv.bool_v == psv.bool_v
		case .String_Literal:
			return sem_span_str(ast, tsv.str_span) == sem_span_str(ast, psv.str_span)
		case .None, .Scope, .Ref, .Builtin, .Symbolic:
			return false
		}
	case .ScopeNode:
		return tvk == .Scope
	case .Identifier:
		return true
	}

	return false
}

/* ======================================================================
 * SECTION 17: ERROR REPORTING
 * ====================================================================== */

sem_error :: proc(s: ^Semantic, message: string, error_type: Analyzer_Error_Type, position: Position) {
	error := Analyzer_Error {
		type     = error_type,
		message  = message,
		position = position,
	}
	append(&s.errors, error)
}

sem_warning :: proc(s: ^Semantic, message: string, error_type: Analyzer_Error_Type, position: Position) {
	warning := Analyzer_Error {
		type     = error_type,
		message  = message,
		position = position,
	}
	append(&s.warnings, warning)
}

/* ======================================================================
 * SECTION 18: DEBUG OUTPUT
 * ====================================================================== */

debug_sem_errors :: proc(s: ^Semantic) {
	fmt.eprintln("=== SEMANTIC ERRORS ===")
	for error, i in s.errors {
		fmt.eprintf(
			"  [%d] %v at line %d, col %d: %s\n",
			i,
			error.type,
			error.position.line,
			error.position.column,
			error.message,
		)
	}
	fmt.eprintln()
}

debug_sem_scopes :: proc(s: ^Semantic) {
	fmt.eprintln("=== SEMANTIC SCOPES ===")
	for scope, i in s.scopes {
		if i == int(s.builtin_scope) do continue
		fmt.eprintf("Scope #%d", i)
		if scope.node != INVALID_NODE {
			pos := node_position(s.ast, scope.node)
			fmt.eprintf(" at line %d, col %d", pos.line, pos.column)
		}
		fmt.eprintf(" (parent=#%d, bindings=%d", scope.parent, scope.binding_count)
		if .Self_Referential in scope.flags do fmt.eprintf(" SELF_REF")
		if .Is_Collapsible in scope.flags do fmt.eprintf(" COLLAPSIBLE")
		if .Is_Pure in scope.flags do fmt.eprintf(" PURE")
		if .Contains_Product in scope.flags do fmt.eprintf(" HAS_PRODUCT")
		if .Contains_Pull in scope.flags do fmt.eprintf(" HAS_PULL")
		fmt.eprintln(")")

		first := u32(scope.first_binding)
		for j in first ..< first + scope.binding_count {
			entry := s.bindings[j]
			name := sem_span_str(s.ast, entry.name)
			if name == "" do name = "<anon>"
			fmt.eprintf("    [%d] %s '%s'", j, sem_binding_kind_str(entry.kind), name)
			if .Has_Constraint in entry.flags do fmt.eprintf(" (constrained)")
			fmt.eprintf(" = %s", sem_value_str(s, entry.value_kind, entry.value))
			if .Self_Referential in entry.flags do fmt.eprintf(" [SELF_REF]")
			fmt.eprintln()
		}
	}
	fmt.eprintln("=== END SCOPES ===")
}

sem_binding_kind_str :: proc(kind: Sem_Binding_Kind) -> string {
	switch kind {
	case .Pointing_Push:  return "->"
	case .Pointing_Pull:  return "<-"
	case .Event_Push:     return ">-"
	case .Event_Pull:     return "-<"
	case .Resonance_Push: return ">>-"
	case .Resonance_Pull: return "-<<"
	case .Reactive_Push:  return ">>="
	case .Reactive_Pull:  return "=<<"
	case .Inline_Push:    return "inline"
	case .Product:        return "product"
	}
	return "?"
}

sem_value_str :: proc(s: ^Semantic, vk: Value_Kind, sv: Static_Value) -> string {
	switch vk {
	case .None:           return "none"
	case .Integer:
		if sv.integer.negative {
			return fmt.tprintf("-%d", sv.integer.content)
		}
		return fmt.tprintf("%d", sv.integer.content)
	case .Float:          return fmt.tprintf("%f", sv.float_v.content)
	case .Bool:           return fmt.tprintf("%t", sv.bool_v)
	case .String_Literal: return fmt.tprintf("\"%s\"", sem_span_str(s.ast, sv.str_span))
	case .Scope:          return fmt.tprintf("scope@%d", sv.scope)
	case .Ref:            return fmt.tprintf("ref@%d", sv.ref)
	case .Builtin:        return fmt.tprintf("builtin(%v)", sv.builtin)
	case .Symbolic:       return "symbolic"
	}
	return "?"
}
