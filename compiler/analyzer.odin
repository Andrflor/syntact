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
	Constraint_Violation,
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
Sem_Flags :: bit_set[Sem_Flag;u16]

Integer_SV :: struct {
	content:  u64,
	kind:     IntegerKind,
	negative: bool,
}

Float_SV :: struct {
	content: f64,
	kind:    FloatKind,
}

Ref_SV :: struct {
	binding: Binding_Id,
}

Unresolved_SV :: struct {}

Static_Value :: union {
	Integer_SV,
	Float_SV,
	bool,
	Span,
	Node_Index,
	Ref_SV,
	Unresolved_SV,
}

sv_kind_name :: proc(sv: Static_Value) -> string {
	#partial switch _ in sv {
	case Integer_SV:
		return "integer"
	case Float_SV:
		return "float"
	case bool:
		return "bool"
	case Span:
		return "string"
	case Node_Index:
		return "scope"
	case Ref_SV:
		return "ref"
	case Unresolved_SV:
		return "unresolved"
	}
	return "none"
}

sv_constraint_name :: proc(sv: Static_Value) -> string {
	switch v in sv {
	case Integer_SV:
		switch v.kind {
		case .u8:  return "u8"
		case .i8:  return "i8"
		case .u16: return "u16"
		case .i16: return "i16"
		case .u32: return "u32"
		case .i32: return "i32"
		case .u64: return "u64"
		case .i64: return "i64"
		case .none: return "integer"
		}
	case Float_SV:
		switch v.kind {
		case .f32:  return "f32"
		case .f64:  return "f64"
		case .none: return "float"
		}
	case bool:
		return "bool"
	case Span:
		return "String"
	case Node_Index:
		return "scope"
	case Ref_SV, Unresolved_SV:
	}
	return ""
}

Node_Sem :: struct {
	value:       Static_Value,
	flags:       Sem_Flags,
	scope_id:    Scope_Id,
	ref_binding: Binding_Id,
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
	Expand,
	Product,
}

Binding_Entry :: struct {
	node:            Node_Index,
	name:            Span,
	kind:            Sem_Binding_Kind,
	value_node:      Node_Index,
	constraint_node: Node_Index,
	scope_id:        Scope_Id,
	value:           Static_Value,
	flags:           Sem_Flags,
}

Semantic :: struct {
	ast:           ^Ast,
	node_sems:     []Node_Sem,
	node_to_scope: []Scope_Id,
	scopes:        [dynamic]Scope_Info,
	bindings:      [dynamic]Binding_Entry,
	scope_stack:   [dynamic]Scope_Id,
	errors:        [dynamic]Analyzer_Error,
	warnings:      [dynamic]Analyzer_Error,
	builtin_scope: Scope_Id,
}

/* ======================================================================
 * SECTION 2b: BUILTINS
 * ====================================================================== */

BUILTIN_NAMES :: [13]string {
	"u8", "i8", "u16", "i16", "u32", "i32", "u64", "i64",
	"f32", "f64", "bool", "char", "String",
}

builtin_default_value :: proc(name: string) -> Static_Value {
	switch name {
	case "u8":     return Integer_SV{kind = .u8}
	case "i8":     return Integer_SV{kind = .i8}
	case "u16":    return Integer_SV{kind = .u16}
	case "i16":    return Integer_SV{kind = .i16}
	case "u32":    return Integer_SV{kind = .u32}
	case "i32":    return Integer_SV{kind = .i32}
	case "u64":    return Integer_SV{kind = .u64}
	case "i64":    return Integer_SV{kind = .i64}
	case "f32":    return Float_SV{kind = .f32}
	case "f64":    return Float_SV{kind = .f64}
	case "bool":   return bool(false)
	case "char":   return Integer_SV{kind = .u8}
	case "String": return EMPTY_SPAN
	}
	return nil
}

is_builtin_name :: #force_inline proc(name: string) -> bool {
	for n in BUILTIN_NAMES {
		if n == name do return true
	}
	return false
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

	for name in BUILTIN_NAMES {
		append(&s.bindings, Binding_Entry{
			node            = INVALID_NODE,
			name            = EMPTY_SPAN,
			kind            = .Pointing_Push,
			value_node      = INVALID_NODE,
			constraint_node = INVALID_NODE,
			scope_id        = s.builtin_scope,
			value           = builtin_default_value(name),
			flags           = {.Has_Value},
		})
	}
	s.scopes[s.builtin_scope].binding_count = u32(len(BUILTIN_NAMES))
}

/* ======================================================================
 * SECTION 3: ANALYZER CORE
 * ====================================================================== */

analyze :: proc(cache: ^Cache, ast: ^Ast) -> bool {
	if ast == nil do return false

	s := new(Semantic)
	s.ast = ast
	s.node_sems = make([]Node_Sem, len(ast.node_kinds))
	for &ns in s.node_sems {ns.ref_binding = INVALID_BINDING}
	s.node_to_scope = make([]Scope_Id, len(ast.node_kinds))
	for &v in s.node_to_scope {v = INVALID_SCOPE}
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
	case .Carve:
		source_idx := node_carve_source(ast, idx)
		if source_idx != INVALID_NODE && node_kind(ast, source_idx) == .Constraint {
			sem_register_constraint(s, source_idx)
		} else {
			entry := Binding_Entry {
				node            = idx,
				name            = EMPTY_SPAN,
				kind            = .Pointing_Push,
				value_node      = idx,
				constraint_node = INVALID_NODE,
				scope_id        = sem_current_scope(s),
			}
			sem_add_binding(s, entry)
		}
	case .Expand:
		sem_register_expand(s, idx)
	case .ScopeNode:
		entry := Binding_Entry {
			node            = idx,
			name            = EMPTY_SPAN,
			kind            = .Pointing_Push,
			value_node      = idx,
			constraint_node = INVALID_NODE,
			scope_id        = sem_current_scope(s),
		}
		sem_add_binding(s, entry)
	case:
		entry := Binding_Entry {
			node            = idx,
			name            = EMPTY_SPAN,
			kind            = .Pointing_Push,
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

	if operand != INVALID_NODE && node_kind(ast, operand) == .Constraint {
		constraint_idx := node_left(ast, operand)
		entry.value_node = INVALID_NODE
		entry.constraint_node = constraint_idx
		entry.flags |= {.Has_Constraint}
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
		kind            = .Expand,
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

	if has_product && !has_pull && !has_effect && .Self_Referential not_in flags && all_static {
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
		entry.flags |= {.Has_Value}
		return
	}

	if entry.constraint_node != INVALID_NODE {
		sem_evaluate_constraint(s, entry)
	}

	if entry.value_node != INVALID_NODE {
		sv := sem_evaluate_value(s, entry.value_node)
		entry.value = sv
		if sv != nil {
			entry.flags |= {.Has_Value}
		}
		if _, ok := sv.(Unresolved_SV); ok {
			entry.flags |= {.Self_Referential}
		}
	} else if .Has_Constraint in entry.flags {
		sv := sem_resolve_default(s, entry.constraint_node)
		entry.value = sv
		if sv != nil {
			entry.flags |= {.Has_Value}
		}
	}

	if .Has_Constraint in entry.flags && .Has_Value in entry.flags {
		sem_check_constraint(s, entry)
	}
}

sem_evaluate_constraint :: proc(s: ^Semantic, entry: ^Binding_Entry) {
	sv := sem_evaluate_value(s, entry.constraint_node)
	#partial switch _ in sv {
	case Integer_SV, Float_SV, bool, Span, Node_Index, Unresolved_SV:
		entry.flags |= {.Has_Constraint}
	case Ref_SV:
	}
}

sem_constraint_name :: proc(s: ^Semantic, constraint_node: Node_Index) -> string {
	if constraint_node == INVALID_NODE do return "unknown"
	ast := s.ast

	if node_kind(ast, constraint_node) == .Operator {
		op := node_operator_kind(ast, constraint_node)
		if op == .Or || op == .And {
			left_idx := node_operator_left(ast, constraint_node)
			right_idx := node_operator_right(ast, constraint_node)
			sep := " | " if op == .Or else " & "
			return fmt.tprintf(
				"%s%s%s",
				sem_constraint_name(s, left_idx),
				sep,
				sem_constraint_name(s, right_idx),
			)
		}
	}

	csem := s.node_sems[constraint_node]

	if _, ok := csem.value.(Unresolved_SV); ok && csem.ref_binding != INVALID_BINDING {
		ref_entry := &s.bindings[csem.ref_binding]
		if ref_entry.value_node != INVALID_NODE {
			return sem_constraint_name(s, ref_entry.value_node)
		}
	}

	cname := sv_constraint_name(csem.value)
	if cname != "" do return cname

	if scope_node, is_scope := csem.value.(Node_Index); is_scope {
		scope_id, sok := sem_find_scope(s, scope_node)
		if sok {
			scope := s.scopes[scope_id]
			first := u32(scope.first_binding)
			parts := make([dynamic]string, 0, 4)
			for i in first ..< first + scope.binding_count {
				e := &s.bindings[i]
				if e.kind != .Product do continue
				if .Has_Constraint in e.flags && e.constraint_node != INVALID_NODE {
					append(&parts, sem_constraint_name(s, e.constraint_node))
				} else if e.value_node != INVALID_NODE &&
				   node_kind(ast, e.value_node) == .Constraint {
					cleft := node_left(ast, e.value_node)
					if cleft != INVALID_NODE {
						append(&parts, sem_constraint_name(s, cleft))
					}
				}
			}
			if len(parts) > 0 {
				return strings.join(parts[:], " | ")
			}
		}
		return "scope"
	}
	return "unknown"
}

sem_check_value_against_constraint :: proc(s: ^Semantic, constraint_sv: Static_Value, entry: ^Binding_Entry) -> bool {
	#partial switch csv in constraint_sv {
	case Integer_SV:
		iv, ok := entry.value.(Integer_SV)
		if !ok do return false
		return sem_check_int(&iv, csv.kind)
	case Float_SV:
		fv, ok := entry.value.(Float_SV)
		if !ok do return false
		return sem_check_float(&fv, csv.kind)
	case bool:
		_, ok := entry.value.(bool)
		return ok
	case Span:
		_, ok := entry.value.(Span)
		return ok
	case Node_Index, Ref_SV, Unresolved_SV:
		return false
	}
	return false
}

Constraint_Override :: struct {
	binding_id: Binding_Id,
	value:      Static_Value,
	node:       Node_Index,
}

sem_check_constraint :: proc(s: ^Semantic, entry: ^Binding_Entry) {
	if entry.constraint_node == INVALID_NODE do return
	if _, ok := entry.value.(Unresolved_SV); ok do return
	if _, is_ref := entry.value.(Ref_SV); is_ref do return
	if entry.value == nil do return

	ast := s.ast
	if node_kind(ast, entry.constraint_node) == .Operator {
		op := node_operator_kind(ast, entry.constraint_node)
		if op == .Or || op == .And {
			if sem_check_compound(s, entry.constraint_node, entry) do return
			binding_name :=
				sem_span_str(ast, entry.name) if entry.name != EMPTY_SPAN else "<anonymous>"
			pos := node_position(ast, entry.node)
			cname := sem_constraint_name(s, entry.constraint_node)
			sem_error(
				s,
				fmt.tprintf(
					"'%s' expected %s, got %s",
					binding_name,
					cname,
					sv_kind_name(entry.value),
				),
				.Constraint_Violation,
				pos,
			)
			return
		}
	}

	csem := s.node_sems[entry.constraint_node]
	binding_name := sem_span_str(ast, entry.name) if entry.name != EMPTY_SPAN else "<anonymous>"

	if _, ok := csem.value.(Unresolved_SV); ok {
		compound_node := sem_find_compound_node(s, entry.constraint_node)
		if compound_node != INVALID_NODE {
			if sem_check_compound(s, compound_node, entry) do return
			pos := node_position(ast, entry.node)
			cname := sem_constraint_name(s, compound_node)
			sem_error(
				s,
				fmt.tprintf(
					"'%s' expected %s, got %s",
					binding_name,
					cname,
					sv_kind_name(entry.value),
				),
				.Constraint_Violation,
				pos,
			)
			return
		}
	}

	#partial switch _ in csem.value {
	case Integer_SV, Float_SV, bool, Span:
		if sem_check_value_against_constraint(s, csem.value, entry) do return
		pos := node_position(ast, entry.node)
		cname := sv_constraint_name(csem.value)
		sem_error(
			s,
			fmt.tprintf(
				"'%s' expected %s, got %s",
				binding_name,
				cname,
				sv_kind_name(entry.value),
			),
			.Constraint_Violation,
			pos,
		)
		entry.value = csem.value
		return
	case Node_Index, Ref_SV, Unresolved_SV:
	}

	if scope_node, is_scope := csem.value.(Node_Index); is_scope {
		overrides := sem_extract_carve_overrides(s, entry.constraint_node)
		if sem_check_by_scope(s, scope_node, entry.value, overrides[:]) do return
		errors_before := len(s.errors)
		sem_check_by_scope(s, scope_node, entry.value, overrides[:], true)
		if len(s.errors) == errors_before {
			pos := node_position(ast, entry.node)
			cname := sem_constraint_name(s, entry.constraint_node)
			sem_error(
				s,
				fmt.tprintf(
					"'%s' expected %s, got %s",
					binding_name,
					cname,
					sv_kind_name(entry.value),
				),
				.Constraint_Violation,
				pos,
			)
		}
		dsv := sem_resolve_default(s, entry.constraint_node)
		if dsv != nil {
			entry.value = dsv
		}
		return
	}
}

sem_find_compound_node :: proc(s: ^Semantic, node: Node_Index) -> Node_Index {
	ast := s.ast
	if node == INVALID_NODE do return INVALID_NODE

	if node_kind(ast, node) == .Operator {
		op := node_operator_kind(ast, node)
		if op == .Or || op == .And do return node
	}

	sem := s.node_sems[node]
	if sem.ref_binding != INVALID_BINDING {
		entry := &s.bindings[sem.ref_binding]
		if entry.value_node != INVALID_NODE {
			return sem_find_compound_node(s, entry.value_node)
		}
	}

	return INVALID_NODE
}

sem_check_compound :: proc(
	s: ^Semantic,
	constraint_node: Node_Index,
	entry: ^Binding_Entry,
) -> bool {
	ast := s.ast
	if node_kind(ast, constraint_node) != .Operator do return false

	op := node_operator_kind(ast, constraint_node)
	left_idx := node_operator_left(ast, constraint_node)
	right_idx := node_operator_right(ast, constraint_node)

	if op == .Or {
		return(
			sem_check_constraint_node(s, left_idx, entry) ||
			sem_check_constraint_node(s, right_idx, entry) \
		)
	}
	if op == .And {
		return(
			sem_check_constraint_node(s, left_idx, entry) &&
			sem_check_constraint_node(s, right_idx, entry) \
		)
	}
	return false
}

sem_check_constraint_node :: proc(
	s: ^Semantic,
	constraint_node: Node_Index,
	entry: ^Binding_Entry,
) -> bool {
	if constraint_node == INVALID_NODE do return false
	ast := s.ast

	if node_kind(ast, constraint_node) == .Operator {
		op := node_operator_kind(ast, constraint_node)
		if op == .Or || op == .And {
			return sem_check_compound(s, constraint_node, entry)
		}
	}

	csem := s.node_sems[constraint_node]

	if _, ok := csem.value.(Unresolved_SV); ok {
		compound_node := sem_find_compound_node(s, constraint_node)
		if compound_node != INVALID_NODE {
			return sem_check_compound(s, compound_node, entry)
		}
	}

	#partial switch _ in csem.value {
	case Integer_SV, Float_SV, bool, Span:
		test_entry := Binding_Entry {
			value = entry.value,
		}
		return sem_check_value_against_constraint(s, csem.value, &test_entry)
	case:
	}

	if scope_node, is_scope := csem.value.(Node_Index); is_scope {
		overrides := sem_extract_carve_overrides(s, constraint_node)
		if _, val_is_scope := entry.value.(Node_Index);
		   val_is_scope && entry.value_node != INVALID_NODE {
			if sem_check_scope_against_carve_constraint(
				s,
				entry.value_node,
				constraint_node,
				overrides[:],
			) {
				return true
			}
		}
		return sem_check_by_scope(s, scope_node, entry.value, overrides[:])
	}

	return false
}

sem_check_scope_against_carve_constraint :: proc(
	s: ^Semantic,
	value_node: Node_Index,
	constraint_node: Node_Index,
	constraint_overrides: []Constraint_Override,
) -> bool {
	ast := s.ast
	if constraint_node == INVALID_NODE do return false

	con_source_node := constraint_node
	if node_kind(ast, constraint_node) == .Carve {
		con_source_node = node_carve_source(ast, constraint_node)
	}
	con_sem := s.node_sems[con_source_node]
	con_scope_node, con_is_scope := con_sem.value.(Node_Index)
	if !con_is_scope do return false

	val_node := value_node
	val_overrides: [dynamic]Constraint_Override

	if node_kind(ast, val_node) == .Carve {
		val_overrides = sem_extract_carve_overrides(s, val_node)
		val_source := node_carve_source(ast, val_node)
		val_sem := s.node_sems[val_source]
		if val_scope_node, vs_ok := val_sem.value.(Node_Index);
		   vs_ok && val_scope_node == con_scope_node {
			return sem_check_carve_overrides_compatible(
				s,
				con_scope_node,
				val_overrides[:],
				constraint_overrides,
			)
		}
	} else if node_kind(ast, val_node) == .Identifier {
		val_sem := s.node_sems[val_node]
		if val_scope_node, vs_ok := val_sem.value.(Node_Index); vs_ok {
			return sem_check_scope_productions_compatible(
				s,
				val_scope_node,
				con_scope_node,
				constraint_overrides,
			)
		}
	}

	return false
}

sem_check_carve_overrides_compatible :: proc(
	s: ^Semantic,
	scope_node: Node_Index,
	val_overrides: []Constraint_Override,
	con_overrides: []Constraint_Override,
) -> bool {
	for co in con_overrides {
		found := false
		for vo in val_overrides {
			if vo.binding_id == co.binding_id {
				found = true
				#partial switch _ in co.value {
				case Integer_SV, Float_SV, bool, Span:
					test_entry := Binding_Entry{value = vo.value}
					if !sem_check_value_against_constraint(s, co.value, &test_entry) do return false
				case Node_Index:
					if _, vo_scope := vo.value.(Node_Index); !vo_scope do return false
				case:
					co_kind := sv_kind_name(co.value)
					vo_kind := sv_kind_name(vo.value)
					if co_kind != vo_kind do return false
				}
				break
			}
		}
		if !found do return false
	}
	return true
}

sem_check_scope_productions_compatible :: proc(
	s: ^Semantic,
	val_scope_node: Node_Index,
	con_scope_node: Node_Index,
	con_overrides: []Constraint_Override,
) -> bool {
	val_scope_id, vok := sem_find_scope(s, val_scope_node)
	if !vok do return false
	con_scope_id, cok := sem_find_scope(s, con_scope_node)
	if !cok do return false

	con_scope := s.scopes[con_scope_id]
	val_scope := s.scopes[val_scope_id]

	cfirst := u32(con_scope.first_binding)
	for ci in cfirst ..< cfirst + con_scope.binding_count {
		ce := &s.bindings[ci]
		if ce.kind == .Product || ce.kind == .Expand do continue
		if .Has_Constraint not_in ce.flags do continue
		if ce.constraint_node == INVALID_NODE do continue

		resolved_sv, resolved_node, resolved := sem_resolve_constraint_with_overrides(
			s,
			ce.constraint_node,
			con_overrides,
		)

		vfirst := u32(val_scope.first_binding)
		for vi in vfirst ..< vfirst + val_scope.binding_count {
			ve := &s.bindings[vi]
			if ve.kind == .Product || ve.kind == .Expand do continue
			if .Has_Value not_in ve.flags do continue

			csv := resolved_sv if resolved else s.node_sems[ce.constraint_node].value
			#partial switch _ in csv {
			case Integer_SV, Float_SV, bool, Span:
				test_entry := Binding_Entry{value = ve.value}
				if !sem_check_value_against_constraint(s, csv, &test_entry) do return false
			case:
			}
		}
	}

	return true
}

sem_extract_carve_overrides :: proc(
	s: ^Semantic,
	constraint_node: Node_Index,
) -> [dynamic]Constraint_Override {
	overrides := make([dynamic]Constraint_Override, 0, 4)
	if constraint_node == INVALID_NODE do return overrides
	ast := s.ast
	if node_kind(ast, constraint_node) != .Carve do return overrides

	source_idx := node_carve_source(ast, constraint_node)
	ssv := s.node_sems[source_idx].value
	scope_node, is_scope := ssv.(Node_Index)
	if !is_scope do return overrides

	target_scope_id, ok := sem_find_scope(s, scope_node)
	if !ok do return overrides

	positional_idx: i16 = 0
	for child in node_carve_children(ast, constraint_node) {
		ck := node_kind(ast, child)
		#partial switch ck {
		case .Pointing, .PointingPull:
			from_idx := node_left(ast, child)
			to_idx := node_right(ast, child)
			if from_idx != INVALID_NODE && node_kind(ast, from_idx) == .Identifier {
				name := node_name_str(ast, from_idx)
				bid, found := sem_resolve_in_scope(s, target_scope_id, name)
				if found && to_idx != INVALID_NODE {
					child_sem := s.node_sems[to_idx]
					append(
						&overrides,
						Constraint_Override {
							binding_id = bid,
							value = child_sem.value,
							node = to_idx,
						},
					)
				}
			}
		case:
			child_sem := s.node_sems[child]
			bid, found := sem_resolve_by_index(s, target_scope_id, positional_idx)
			if found {
				append(
					&overrides,
					Constraint_Override{binding_id = bid, value = child_sem.value, node = child},
				)
			}
			positional_idx += 1
		}
	}
	return overrides
}

sem_check_int :: proc(val: ^Integer_SV, constr_kind: IntegerKind) -> bool {
	if val.kind == .none {
		switch constr_kind {
		case .none:
			return true
		case .u8:
			if !val.negative && val.content < 256 {val.kind = .u8;return true};return false
		case .i8:
			if val.content < 128 {val.kind = .i8;return true};return false
		case .u16:
			if !val.negative && val.content < 65536 {val.kind = .u16;return true};return false
		case .i16:
			if val.content < 32768 {val.kind = .i16;return true};return false
		case .u32:
			if !val.negative && val.content < 4294967296 {val.kind = .u32;return true};return false
		case .i32:
			if val.content < 2147483648 {val.kind = .i32;return true};return false
		case .u64:
			if !val.negative {val.kind = .u64;return true};return false
		case .i64:
			val.kind = .i64;return true
		}
	}
	return constr_kind == .none || constr_kind == val.kind
}

sem_check_float :: proc(val: ^Float_SV, constr_kind: FloatKind) -> bool {
	switch val.kind {
	case .none:
		#partial switch constr_kind {
		case .f32:
			if val.content < (1 << 24) {
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
		return constr_kind == .none || constr_kind == .f32
	case .f64:
		return constr_kind == .none || constr_kind == .f64
	}
	return false
}

sem_check_by_scope :: proc(
	s: ^Semantic,
	scope_node: Node_Index,
	sv: Static_Value,
	overrides: []Constraint_Override = {},
	report: bool = false,
) -> bool {
	scope_id, ok := sem_find_scope(s, scope_node)
	if !ok do return false

	scope := s.scopes[scope_id]
	first := u32(scope.first_binding)
	has_product := false

	for i in first ..< first + scope.binding_count {
		entry := &s.bindings[i]
		if entry.kind != .Product do continue
		has_product = true

		if .Has_Constraint in entry.flags && entry.constraint_node != INVALID_NODE {
			resolved_sv, resolved_node, resolved := sem_resolve_constraint_with_overrides(
				s,
				entry.constraint_node,
				overrides,
			)
			if resolved {
				test_entry := Binding_Entry{value = sv}
				#partial switch rsv in resolved_sv {
				case Unresolved_SV:
					if resolved_node != INVALID_NODE {
						if sem_check_constraint_node(s, resolved_node, &test_entry) do return true
					}
				case Integer_SV, Float_SV, bool, Span:
					if sem_check_value_against_constraint(s, resolved_sv, &test_entry) do return true
				case Node_Index:
					if sem_check_by_scope(s, rsv, sv, overrides, report) do return true
				case Ref_SV:
				}
			} else {
				test_entry := Binding_Entry{value = sv}
				if sem_check_constraint_node(s, entry.constraint_node, &test_entry) do return true
			}
		} else if .Has_Value in entry.flags {
			_, entry_is_scope := entry.value.(Node_Index)
			_, sv_is_scope_v := sv.(Node_Index)
			if entry_is_scope && sv_is_scope_v {
				product_overrides := overrides
				own_overrides: [dynamic]Constraint_Override
				if entry.value_node != INVALID_NODE &&
				   node_kind(s.ast, entry.value_node) == .Carve {
					own_overrides = sem_extract_carve_overrides(s, entry.value_node)
					product_overrides = own_overrides[:]
				}
				sv_scope, _ := sv.(Node_Index)
				entry_scope, _ := entry.value.(Node_Index)
				if sem_check_scope_structural(s, sv_scope, entry_scope, product_overrides, report) do return true
			} else {
				if sem_check_by_value(entry.value, sv) do return true
			}
		}
	}

	if !has_product {
		if sv_scope, is_scope := sv.(Node_Index); is_scope {
			return sem_check_scope_structural(s, sv_scope, scope_node, overrides, report)
		}
		return false
	}
	return false
}

sem_resolve_constraint_with_overrides :: proc(
	s: ^Semantic,
	constraint_node: Node_Index,
	overrides: []Constraint_Override,
) -> (
	Static_Value,
	Node_Index,
	bool,
) {
	if constraint_node == INVALID_NODE do return nil, INVALID_NODE, false

	csem := s.node_sems[constraint_node]

	if csem.ref_binding != INVALID_BINDING {
		for ov in overrides {
			if ov.binding_id == csem.ref_binding {
				return ov.value, ov.node, true
			}
		}
	}

	return nil, INVALID_NODE, false
}

sem_check_scope_structural :: proc(
	s: ^Semantic,
	value_scope_node: Node_Index,
	constraint_scope_node: Node_Index,
	overrides: []Constraint_Override,
	report: bool = false,
) -> bool {
	val_scope_id, vok := sem_find_scope(s, value_scope_node)
	if !vok do return true

	con_scope_id, cok := sem_find_scope(s, constraint_scope_node)
	if !cok do return true

	con_scope := s.scopes[con_scope_id]
	val_scope_tmp := s.scopes[val_scope_id]

	con_element_count: u32 = 0
	has_expand := false
	cfirst := u32(con_scope.first_binding)
	for i in cfirst ..< cfirst + con_scope.binding_count {
		e := &s.bindings[i]
		if e.kind == .Expand {has_expand = true;continue}
		if e.kind == .Product do continue
		con_element_count += 1
	}

	val_element_count: u32 = 0
	vfirst_tmp := u32(val_scope_tmp.first_binding)
	for i in vfirst_tmp ..< vfirst_tmp + val_scope_tmp.binding_count {
		e := &s.bindings[i]
		if e.kind != .Product && e.kind != .Expand do val_element_count += 1
	}

	if con_element_count == 0 && !has_expand {
		return val_element_count == 0
	}

	element_constraint_sv, element_constraint_node, has_element_constraint :=
		sem_find_element_constraint(s, con_scope_id, overrides)

	if !has_element_constraint do return true

	val_scope := s.scopes[val_scope_id]
	vfirst := u32(val_scope.first_binding)
	all_ok := true

	for i in vfirst ..< vfirst + val_scope.binding_count {
		val_entry := &s.bindings[i]
		if val_entry.kind == .Product || val_entry.kind == .Expand do continue
		if .Has_Value not_in val_entry.flags do continue

		if .Has_Constraint in val_entry.flags && val_entry.constraint_node != INVALID_NODE {
			continue
		}

		ok := true
		#partial switch ecsv in element_constraint_sv {
		case Unresolved_SV:
			if element_constraint_node != INVALID_NODE {
				ok = sem_check_constraint_node(s, element_constraint_node, val_entry)
			}
		case Integer_SV, Float_SV, bool, Span:
			test_entry := Binding_Entry{value = val_entry.value}
			ok = sem_check_value_against_constraint(s, element_constraint_sv, &test_entry)
		case Node_Index:
			ok = sem_check_by_scope(s, ecsv, val_entry.value, overrides)
		case Ref_SV:
		}

		if !ok {
			all_ok = false
			if report && val_entry.node != INVALID_NODE {
				cname := sv_constraint_name(element_constraint_sv)
				if cname == "" && element_constraint_node != INVALID_NODE {
					cname = sem_constraint_name(s, element_constraint_node)
				}
				if cname == "" do cname = "scope"
				val_str := sem_value_str(s, val_entry.value)
				sem_error(
					s,
					fmt.tprintf(
						"expected %s, got %s (%s)",
						cname,
						sv_kind_name(val_entry.value),
						val_str,
					),
					.Constraint_Violation,
					node_position(s.ast, val_entry.node),
				)
			}
			if !report do return false
		}
	}
	return all_ok
}

sem_find_element_constraint :: proc(
	s: ^Semantic,
	scope_id: Scope_Id,
	overrides: []Constraint_Override,
) -> (
	Static_Value,
	Node_Index,
	bool,
) {
	scope := s.scopes[scope_id]
	first := u32(scope.first_binding)

	for i in first ..< first + scope.binding_count {
		entry := &s.bindings[i]
		if entry.kind == .Product || entry.kind == .Expand do continue
		if .Has_Constraint not_in entry.flags do continue
		if entry.constraint_node == INVALID_NODE do continue

		resolved_sv, resolved_node, resolved := sem_resolve_constraint_with_overrides(
			s,
			entry.constraint_node,
			overrides,
		)
		if resolved {
			return resolved_sv, resolved_node, true
		}

		csem := s.node_sems[entry.constraint_node]
		#partial switch _ in csem.value {
		case Integer_SV, Float_SV, bool, Span, Node_Index:
			return csem.value, entry.constraint_node, true
		case:
		}
	}

	return nil, INVALID_NODE, false
}

sem_check_by_value :: proc(constr_sv: Static_Value, val_sv: Static_Value) -> bool {
	if sv_kind_name(constr_sv) != sv_kind_name(val_sv) do return false
	switch c in constr_sv {
	case Integer_SV:
		v, ok := val_sv.(Integer_SV)
		if !ok do return false
		copy := v
		return sem_check_int(&copy, c.kind)
	case Float_SV:
		v, ok := val_sv.(Float_SV)
		if !ok do return false
		copy := v
		return sem_check_float(&copy, c.kind)
	case bool:
		return true
	case Span:
		return true
	case Node_Index:
		return true
	case Ref_SV:
		return true
	case Unresolved_SV:
		return true
	}
	return true
}

sem_resolve_default :: proc(s: ^Semantic, constraint_node: Node_Index) -> Static_Value {
	if constraint_node == INVALID_NODE do return nil

	ast := s.ast
	if node_kind(ast, constraint_node) == .Operator {
		op := node_operator_kind(ast, constraint_node)
		if op == .Or || op == .And {
			left_idx := node_operator_left(ast, constraint_node)
			return sem_resolve_default(s, left_idx)
		}
	}

	sem := s.node_sems[constraint_node]
	#partial switch _ in sem.value {
	case Integer_SV, Float_SV, bool, Span:
		return sem.value
	case:
	}

	if scope_node, is_scope := sem.value.(Node_Index); is_scope {
		scope_id, ok := sem_find_scope(s, scope_node)
		if !ok do return nil
		scope := s.scopes[scope_id]
		first := u32(scope.first_binding)
		for i in first ..< first + scope.binding_count {
			if s.bindings[i].kind == .Product {
				return s.bindings[i].value
			}
		}
		return Node_Index(scope_node)
	}

	return nil
}

sem_find_scope :: #force_inline proc(s: ^Semantic, node: Node_Index) -> (Scope_Id, bool) {
	if node == INVALID_NODE do return INVALID_SCOPE, false
	id := s.node_to_scope[node]
	return id, id != INVALID_SCOPE
}

/* ======================================================================
 * SECTION 8: VALUE EVALUATION
 * ====================================================================== */

sem_evaluate_value :: proc(s: ^Semantic, idx: Node_Index) -> Static_Value {
	if idx == INVALID_NODE do return nil

	sem := &s.node_sems[idx]

	if .Has_Value in sem.flags {
		return sem.value
	}

	if .In_Progress in sem.flags {
		sem.flags |= {.Self_Referential}
		return Unresolved_SV{}
	}

	sem.flags |= {.In_Progress}
	defer sem.flags -= {.In_Progress}

	ast := s.ast
	kind := node_kind(ast, idx)

	sv: Static_Value

	#partial switch kind {
	case .Literal:
		sv = sem_evaluate_literal(s, idx)
	case .Identifier:
		sv = sem_evaluate_identifier(s, idx)
	case .ScopeNode:
		if .Has_Value not_in sem.flags {
			scope_id := sem_push_scope(s, idx)
			for child in node_children(ast, idx) {
				sem_walk(s, child)
			}
			sem_finalize_scope(s, scope_id)
			sem_pop_scope(s)
		}
		sv = Node_Index(idx)
	case .Operator:
		sv = sem_evaluate_operator(s, idx)
	case .Property:
		sv = sem_evaluate_property(s, idx)
	case .Range:
		sv = sem_evaluate_range(s, idx)
	case .Carve:
		sv = sem_evaluate_carve(s, idx)
	case .Execute:
		sv = sem_evaluate_execute(s, idx)
	case .Pattern:
		sv = sem_evaluate_pattern(s, idx)
	case .CompileTime:
		operand := node_unary_operand(ast, idx)
		sv = sem_evaluate_value(s, operand)
	case .Constraint:
		constraint_idx := node_left(ast, idx)
		sv = sem_evaluate_value(s, constraint_idx)
		#partial switch _ in sv {
		case Node_Index, Unresolved_SV:
			dsv := sem_resolve_default(s, constraint_idx)
			if dsv != nil {
				sv = dsv
			}
		}
	case .External:
		sv = Unresolved_SV{}
	case .Expand:
		operand := node_unary_operand(ast, idx)
		sv = sem_evaluate_value(s, operand)
	case .Enforce:
		sv = Unresolved_SV{}
	case .EventPull,
	     .EventPush,
	     .ResonancePush,
	     .ResonancePull,
	     .ReactivePush,
	     .ReactivePull,
	     .Pointing,
	     .PointingPull,
	     .Product:
		sem_error(
			s,
			"Cannot use a binding definition as a binding value",
			.Invalid_Binding_Value,
			node_position(ast, idx),
		)
		return nil
	case .Branch:
		sem_error(
			s,
			"Branch found outside a pattern node",
			.Invalid_Binding_Value,
			node_position(ast, idx),
		)
		return nil
	}

	sem.value = sv
	if sv != nil {
		sem.flags |= {.Has_Value}
	}
	return sv
}

/* ======================================================================
 * SECTION 9: LITERAL EVALUATION
 * ====================================================================== */

sem_evaluate_literal :: proc(s: ^Semantic, idx: Node_Index) -> Static_Value {
	ast := s.ast
	lit_kind := node_literal_kind(ast, idx)
	text := node_text(ast, idx)

	switch lit_kind {
	case .Integer:
		content, ok := strconv.parse_int(text)
		isv := Integer_SV {
			kind = .none,
		}
		if ok do isv.content = u64(content)
		return isv
	case .Float:
		content, ok := strconv.parse_f64(text)
		fsv := Float_SV {
			kind = .none,
		}
		if ok do fsv.content = content
		return fsv
	case .String:
		return node_span(ast, idx)
	case .Bool:
		return bool(text == "true")
	case .Hexadecimal:
		hex_text := text
		if len(hex_text) > 2 && hex_text[0] == '0' && (hex_text[1] == 'x' || hex_text[1] == 'X') {
			hex_text = hex_text[2:]
		}
		content, ok := strconv.parse_int(hex_text, 16)
		isv := Integer_SV {
			kind = .none,
		}
		if ok do isv.content = u64(content)
		return isv
	case .Binary:
		bin_text := text
		if len(bin_text) > 2 && bin_text[0] == '0' && (bin_text[1] == 'b' || bin_text[1] == 'B') {
			bin_text = bin_text[2:]
		}
		content, ok := strconv.parse_int(bin_text, 2)
		isv := Integer_SV {
			kind = .none,
		}
		if ok do isv.content = u64(content)
		return isv
	}
	return nil
}

/* ======================================================================
 * SECTION 10: IDENTIFIER RESOLUTION
 * ====================================================================== */

sem_span_str :: #force_inline proc(ast: ^Ast, span: Span) -> string {
	if span == EMPTY_SPAN do return ""
	return ast.source[span.start:span.end]
}

sem_resolve_symbol :: proc(s: ^Semantic, name: string, ordinal: i16 = -1) -> (Binding_Id, bool) {
	for i := len(s.scope_stack) - 1; i >= 0; i -= 1 {
		sid := s.scope_stack[i]
		if sid == s.builtin_scope {
			bid, found := sem_resolve_builtin_binding(s, name)
			if found do return bid, true
			continue
		}
		if ordinal >= 0 {
			bid, found := sem_resolve_by_ordinal(s, sid, name, ordinal)
			if found do return bid, true
		} else {
			if bid, ok := s.scopes[sid].names[name]; ok {
				return bid, true
			}
		}
	}
	return INVALID_BINDING, false
}

sem_resolve_by_ordinal :: proc(
	s: ^Semantic,
	scope_id: Scope_Id,
	name: string,
	ordinal: i16,
) -> (
	Binding_Id,
	bool,
) {
	scope := s.scopes[scope_id]
	first := u32(scope.first_binding)
	occurrence: i16 = 0
	for i in first ..< first + scope.binding_count {
		entry := &s.bindings[i]
		if entry.name != EMPTY_SPAN {
			entry_name := s.ast.source[entry.name.start:entry.name.end]
			if entry_name == name {
				if occurrence == ordinal {
					return Binding_Id(i), true
				}
				occurrence += 1
			}
		}
	}
	return INVALID_BINDING, false
}

sem_resolve_by_index :: proc(s: ^Semantic, scope_id: Scope_Id, index: i16) -> (Binding_Id, bool) {
	scope := s.scopes[scope_id]
	first := u32(scope.first_binding)
	pos: i16 = 0
	for i in first ..< first + scope.binding_count {
		entry := &s.bindings[i]
		if entry.kind == .Expand {
			if scope_node, is_scope := entry.value.(Node_Index); is_scope {
				expanded_id, ok := sem_find_scope(s, scope_node)
				if ok {
					expanded_count := i16(s.scopes[expanded_id].binding_count)
					if index < pos + expanded_count {
						return sem_resolve_by_index(s, expanded_id, index - pos)
					}
					pos += expanded_count
				}
				continue
			}
		}
		if entry.kind == .Product do continue
		if pos == index {
			return Binding_Id(i), true
		}
		pos += 1
	}
	return INVALID_BINDING, false
}

sem_resolve_builtin_binding :: proc(s: ^Semantic, name: string) -> (Binding_Id, bool) {
	scope := s.scopes[s.builtin_scope]
	first := u32(scope.first_binding)
	for bname, i in BUILTIN_NAMES {
		if bname == name {
			return Binding_Id(first + u32(i)), true
		}
	}
	return INVALID_BINDING, false
}

sem_resolve_in_scope :: proc(
	s: ^Semantic,
	scope_id: Scope_Id,
	name: string,
) -> (
	Binding_Id,
	bool,
) {
	if bid, ok := s.scopes[scope_id].names[name]; ok {
		return bid, true
	}

	scope := s.scopes[scope_id]
	first := u32(scope.first_binding)
	for i in first ..< first + scope.binding_count {
		entry := &s.bindings[i]
		if entry.kind == .Expand {
			if scope_node, is_scope := entry.value.(Node_Index); is_scope {
				expanded_id, ok := sem_find_scope(s, scope_node)
				if ok {
					bid, found := sem_resolve_in_scope(s, expanded_id, name)
					if found do return bid, true
				}
			}
		}
	}

	return INVALID_BINDING, false
}

sem_evaluate_identifier :: proc(s: ^Semantic, idx: Node_Index) -> Static_Value {
	ast := s.ast
	name := node_name_str(ast, idx)
	ordinal := node_ordinal(ast, idx)

	bid, found := sem_resolve_symbol(s, name, ordinal)
	if !found {
		sem_error(
			s,
			fmt.tprintf("Undefined identifier named %s found", name),
			.Undefined_Identifier,
			node_position(ast, idx),
		)
		return nil
	}

	s.node_sems[idx].ref_binding = bid

	entry := &s.bindings[bid]

	if .Has_Value in entry.flags {
		return entry.value
	}

	return Ref_SV{binding = bid}
}

/* ======================================================================
 * SECTION 11: OPERATOR EVALUATION
 * ====================================================================== */

sem_evaluate_operator :: proc(s: ^Semantic, idx: Node_Index) -> Static_Value {
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
		return nil
	}

	lsv := sem_evaluate_value(s, left_idx)
	rsv := sem_evaluate_value(s, right_idx)

	if _, ok := lsv.(Unresolved_SV); ok do return Unresolved_SV{}
	if _, ok := rsv.(Unresolved_SV); ok do return Unresolved_SV{}

	#partial switch op_kind {
	case .Add, .Subtract, .Multiply, .Divide, .Mod:
		return sem_fold_math(lsv, rsv, op_kind, pos, s)
	case .And, .Or, .Xor:
		return sem_fold_bitwise(lsv, rsv, op_kind, pos, s)
	case .Less, .Greater, .LessEqual, .GreaterEqual:
		return sem_fold_comparison(lsv, rsv, op_kind, pos, s)
	case .Equal:
		return sem_fold_equality(lsv, rsv, false, pos, s)
	case .NotEqual:
		return sem_fold_equality(lsv, rsv, true, pos, s)
	case .LShift, .RShift:
		return sem_fold_shift(lsv, rsv, op_kind, pos, s)
	case .Not:
		sem_error(s, "Cannot use not as binary operator", .Invalid_operator, pos)
		return nil
	}
	return Unresolved_SV{}
}

sem_evaluate_unary :: proc(
	s: ^Semantic,
	op_idx: Node_Index,
	child_idx: Node_Index,
	op_kind: Operator_Kind,
) -> Static_Value {
	pos := node_position(s.ast, op_idx)
	csv := sem_evaluate_value(s, child_idx)

	switch op_kind {
	case .Subtract:
		switch v in csv {
		case Integer_SV:
			return Integer_SV{content = v.content, kind = v.kind, negative = true}
		case Float_SV:
			return Float_SV{content = -v.content, kind = v.kind}
		case Unresolved_SV:
			return csv
		case bool, Span, Node_Index, Ref_SV:
			sem_error(s, "Cannot negate anything other than int or float", .Invalid_operator, pos)
		}
	case .Not:
		switch v in csv {
		case bool:
			return bool(!v)
		case Integer_SV:
			return Integer_SV{content = ~v.content, kind = v.kind, negative = v.negative}
		case Unresolved_SV:
			return csv
		case Float_SV, Span, Node_Index, Ref_SV:
		}
	case .Add, .Multiply, .Divide, .Mod, .Equal, .Less, .Greater,
	     .NotEqual, .LessEqual, .GreaterEqual, .And, .Or, .Xor, .RShift, .LShift:
		sem_error(s, "Operator should not be used as unary", .Invalid_operator, pos)
	}
	return csv
}

sem_fold_math :: proc(
	lsv: Static_Value,
	rsv: Static_Value,
	op: Operator_Kind,
	pos: Position,
	s: ^Semantic,
) -> Static_Value {
	switch l in lsv {
	case Integer_SV:
		switch r in rsv {
		case Integer_SV:
			result := Integer_SV{kind = l.kind if l.kind != .none else r.kind}
			#partial switch op {
			case .Add:      result.content = l.content + r.content
			case .Subtract: result.content = l.content - r.content
			case .Multiply: result.content = l.content * r.content
			case .Divide:   if r.content != 0 do result.content = l.content / r.content
			case .Mod:      if r.content != 0 do result.content = l.content % r.content
			}
			return result
		case Float_SV, bool, Span, Node_Index, Ref_SV, Unresolved_SV:
		}
	case Float_SV:
		switch r in rsv {
		case Float_SV:
			result := Float_SV{kind = l.kind if l.kind != .none else r.kind}
			#partial switch op {
			case .Add:      result.content = l.content + r.content
			case .Subtract: result.content = l.content - r.content
			case .Multiply: result.content = l.content * r.content
			case .Divide:   if r.content != 0 do result.content = l.content / r.content
			case .Mod:
				sem_error(s, "Mod is only allowed with integers", .Invalid_operator, pos)
				return nil
			}
			return result
		case Integer_SV, bool, Span, Node_Index, Ref_SV, Unresolved_SV:
		}
	case Node_Index:
		if op == .Add do return lsv
	case bool, Span, Ref_SV, Unresolved_SV:
	}

	if _, ok := rsv.(Node_Index); ok && op == .Add {
		return rsv
	}

	sem_error(s, fmt.tprintf("Incompatible types for %s", op), .Invalid_operator, pos)
	return nil
}

sem_fold_bitwise :: proc(
	lsv: Static_Value,
	rsv: Static_Value,
	op: Operator_Kind,
	pos: Position,
	s: ^Semantic,
) -> Static_Value {
	switch l in lsv {
	case Integer_SV:
		if r, ok := rsv.(Integer_SV); ok {
			result := Integer_SV{kind = l.kind if l.kind != .none else r.kind}
			#partial switch op {
			case .And: result.content = l.content & r.content
			case .Or:  result.content = l.content | r.content
			case .Xor: result.content = l.content ~ r.content
			}
			return result
		}
	case bool:
		if r, ok := rsv.(bool); ok {
			#partial switch op {
			case .And: return bool(l && r)
			case .Or:  return bool(l || r)
			case .Xor: return bool(l ~ r)
			}
		}
	case Float_SV, Span, Node_Index, Ref_SV, Unresolved_SV:
	}

	if op == .Or || op == .And {
		return Unresolved_SV{}
	}

	sem_error(s, fmt.tprintf("Incompatible types for %s", op), .Invalid_operator, pos)
	return nil
}

sem_fold_comparison :: proc(
	lsv: Static_Value,
	rsv: Static_Value,
	op: Operator_Kind,
	pos: Position,
	s: ^Semantic,
) -> Static_Value {
	sem_cmp :: #force_inline proc(a, b: $T, op: Operator_Kind) -> bool {
		#partial switch op {
		case .Less:         return a < b
		case .Greater:      return a > b
		case .LessEqual:    return a <= b
		case .GreaterEqual: return a >= b
		}
		return false
	}

	switch l in lsv {
	case Integer_SV:
		switch r in rsv {
		case Integer_SV: return bool(sem_cmp(l.content, r.content, op))
		case Float_SV:   return bool(sem_cmp(f64(l.content), r.content, op))
		case bool, Span, Node_Index, Ref_SV, Unresolved_SV:
		}
	case Float_SV:
		switch r in rsv {
		case Float_SV:   return bool(sem_cmp(l.content, r.content, op))
		case Integer_SV: return bool(sem_cmp(l.content, f64(r.content), op))
		case bool, Span, Node_Index, Ref_SV, Unresolved_SV:
		}
	case bool, Span, Node_Index, Ref_SV, Unresolved_SV:
	}

	sem_error(s, fmt.tprintf("Incompatible types for %s", op), .Invalid_operator, pos)
	return nil
}

sem_fold_equality :: proc(
	lsv: Static_Value,
	rsv: Static_Value,
	negate: bool,
	pos: Position,
	s: ^Semantic,
) -> Static_Value {
	equal := false

	lk := sv_kind_name(lsv)
	rk := sv_kind_name(rsv)
	if lk != rk {
		equal = false
	} else {
		switch l in lsv {
		case Integer_SV:
			r, _ := rsv.(Integer_SV)
			equal = l.content == r.content
		case Float_SV:
			r, _ := rsv.(Float_SV)
			equal = l.content == r.content
		case bool:
			r, _ := rsv.(bool)
			equal = l == r
		case Span:
			r, _ := rsv.(Span)
			equal = sem_span_str(s.ast, l) == sem_span_str(s.ast, r)
		case Node_Index:
			r, _ := rsv.(Node_Index)
			equal = l == r
		case Ref_SV:
			return Unresolved_SV{}
		case Unresolved_SV:
			return Unresolved_SV{}
		}
	}

	return bool(equal ~ negate)
}

sem_fold_shift :: proc(
	lsv: Static_Value,
	rsv: Static_Value,
	op: Operator_Kind,
	pos: Position,
	s: ^Semantic,
) -> Static_Value {
	switch l in lsv {
	case Integer_SV:
		if r, ok := rsv.(Integer_SV); ok {
			result := Integer_SV{kind = l.kind, negative = l.negative}
			#partial switch op {
			case .LShift: result.content = l.content << r.content
			case .RShift: result.content = l.content >> r.content
			}
			return result
		}
	case Float_SV, bool, Span, Node_Index, Ref_SV, Unresolved_SV:
	}

	sem_error(s, "Shift requires integer operands", .Invalid_operator, pos)
	return nil
}

/* ======================================================================
 * SECTION 12: PROPERTY EVALUATION
 * ====================================================================== */

sem_evaluate_property :: proc(s: ^Semantic, idx: Node_Index) -> Static_Value {
	ast := s.ast
	prop_idx := node_right(ast, idx)
	source_idx := node_left(ast, idx)
	pos := node_position(ast, idx)

	if prop_idx == INVALID_NODE || node_kind(ast, prop_idx) != .Identifier {
		if source_idx != INVALID_NODE {
			sem_evaluate_value(s, source_idx)
		}
		sem_error(s, "Invalid property access without identifier", .Invalid_Property_Access, pos)
		return nil
	}

	prop_name := node_name_str(ast, prop_idx)
	prop_ordinal := node_ordinal(ast, prop_idx)

	if source_idx != INVALID_NODE {
		ssv := sem_evaluate_value(s, source_idx)
		if scope_node, is_scope := ssv.(Node_Index); is_scope {
			scope_id, ok := sem_find_scope(s, scope_node)
			if ok {
				bid: Binding_Id
				found: bool
				if prop_name == "" && prop_ordinal >= 0 {
					bid, found = sem_resolve_by_index(s, scope_id, prop_ordinal)
				} else {
					bid, found = sem_resolve_in_scope(s, scope_id, prop_name)
				}
				if found {
					s.node_sems[prop_idx].ref_binding = bid
					entry := &s.bindings[bid]
					if .Has_Value in entry.flags {
						return entry.value
					}
					return Ref_SV{binding = bid}
				}
			}
		}
		if ssv == nil do return Unresolved_SV{}
		if _, ok := ssv.(Unresolved_SV); ok do return Unresolved_SV{}
		if _, is_ref := ssv.(Ref_SV); is_ref {
			return Unresolved_SV{}
		}
		if node_kind(ast, source_idx) == .Identifier {
			ref_bid := s.node_sems[source_idx].ref_binding
			if ref_bid != INVALID_BINDING {
				ref_scope_id := s.bindings[ref_bid].scope_id
				ref_name := sem_span_str(ast, s.bindings[ref_bid].name)
				scope := s.scopes[ref_scope_id]
				first := u32(scope.first_binding)
				for ri := first + scope.binding_count; ri > first; ri -= 1 {
					i := ri - 1
					e := &s.bindings[i]
					if e.name == EMPTY_SPAN do continue
					if sem_span_str(ast, e.name) != ref_name do continue
					scopes_to_check: [2]struct {
						node: Node_Index,
						ok:   bool,
					}
					count := 0
					if e_scope, e_is_scope := e.value.(Node_Index); e_is_scope {
						scopes_to_check[count] = {e_scope, true}
						count += 1
					}
					if .Has_Constraint in e.flags && e.constraint_node != INVALID_NODE {
						csv := sem_evaluate_value(s, e.constraint_node)
						if c_scope, c_is_scope := csv.(Node_Index); c_is_scope {
							scopes_to_check[count] = {c_scope, true}
							count += 1
						}
					}
					for ci in 0 ..< count {
						sc := scopes_to_check[ci]
						if !sc.ok do continue
						sid, sok := sem_find_scope(s, sc.node)
						if !sok do continue
						bid: Binding_Id
						found: bool
						if prop_name == "" && prop_ordinal >= 0 {
							bid, found = sem_resolve_by_index(s, sid, prop_ordinal)
						} else {
							bid, found = sem_resolve_in_scope(s, sid, prop_name)
						}
						if found {
							s.node_sems[prop_idx].ref_binding = bid
							entry := &s.bindings[bid]
							if .Has_Value in entry.flags {
								return entry.value
							}
							return Ref_SV{binding = bid}
						}
					}
				}
			}
		}
	} else {
		scope_id := sem_current_scope(s)
		bid: Binding_Id
		found: bool
		if prop_name == "" && prop_ordinal >= 0 {
			bid, found = sem_resolve_by_index(s, scope_id, prop_ordinal)
		} else {
			bid, found = sem_resolve_in_scope(s, scope_id, prop_name)
		}
		if found {
			s.node_sems[prop_idx].ref_binding = bid
			entry := &s.bindings[bid]
			if .Has_Value in entry.flags {
				return entry.value
			}
		}
	}

	sem_error(s, fmt.tprintf("There is no property %s", prop_name), .Invalid_Property_Access, pos)
	return nil
}

/* ======================================================================
 * SECTION 13: RANGE EVALUATION
 * ====================================================================== */

sem_evaluate_range :: proc(s: ^Semantic, idx: Node_Index) -> Static_Value {
	ast := s.ast
	start_idx := node_left(ast, idx)
	end_idx := node_right(ast, idx)

	ssv := sem_evaluate_value(s, start_idx)
	esv := sem_evaluate_value(s, end_idx)

	_, s_int := ssv.(Integer_SV)
	_, e_int := esv.(Integer_SV)
	if !s_int || !e_int {
		sem_error(
			s,
			"Trying to create a range with a non integer value",
			.Invalid_Range,
			node_position(ast, idx),
		)
	}

	return Unresolved_SV{}
}

/* ======================================================================
 * SECTION 14: CARVE EVALUATION
 * ====================================================================== */

sem_check_carve_override :: proc(
	s: ^Semantic,
	target_entry: ^Binding_Entry,
	sv: Static_Value,
	name: string,
	pos: Position,
) {
	if _, ok := sv.(Unresolved_SV); ok do return
	if _, is_ref := sv.(Ref_SV); is_ref do return
	if sv == nil do return
	if .Has_Constraint not_in target_entry.flags do return
	if target_entry.constraint_node == INVALID_NODE do return

	csem := s.node_sems[target_entry.constraint_node]
	#partial switch _ in csem.value {
	case Integer_SV, Float_SV, bool, Span:
		test_entry := Binding_Entry{value = sv}
		if !sem_check_value_against_constraint(s, csem.value, &test_entry) {
			cname := sv_constraint_name(csem.value)
			sem_error(
				s,
				fmt.tprintf(
					"carve override '%s' expected %s, got %s",
					name,
					cname,
					sv_kind_name(sv),
				),
				.Constraint_Violation,
				pos,
			)
		}
	case:
	}
	if scope_node, is_scope := csem.value.(Node_Index); is_scope {
		if !sem_check_by_scope(s, scope_node, sv) {
			sem_error(
				s,
				fmt.tprintf(
					"carve override '%s' expected scope constraint, got %s",
					name,
					sv_kind_name(sv),
				),
				.Constraint_Violation,
				pos,
			)
		}
	}
}

Carve_Override_Entry :: struct {
	binding_id: Binding_Id,
	value:      Static_Value,
}

sem_evaluate_carve_children :: proc(
	s: ^Semantic,
	idx: Node_Index,
	target_scope_id: Scope_Id = INVALID_SCOPE,
) -> [dynamic]Carve_Override_Entry {
	ast := s.ast
	positional_idx: i16 = 0
	collected := make([dynamic]Carve_Override_Entry, 0, 4)

	for child in node_carve_children(ast, idx) {
		ck := node_kind(ast, child)
		#partial switch ck {
		case .Pointing, .PointingPull:
			from_idx := node_left(ast, child)
			to_idx := node_right(ast, child)
			sv: Static_Value
			if to_idx != INVALID_NODE {
				sv = sem_evaluate_value(s, to_idx)
			}
			if target_scope_id != INVALID_SCOPE &&
			   from_idx != INVALID_NODE &&
			   node_kind(ast, from_idx) == .Identifier {
				name := node_name_str(ast, from_idx)
				ordinal := node_ordinal(ast, from_idx)
				bid: Binding_Id
				found: bool
				if name == "" && ordinal >= 0 {
					bid, found = sem_resolve_by_index(s, target_scope_id, ordinal)
				} else {
					bid, found = sem_resolve_in_scope(s, target_scope_id, name)
				}
				if !found {
					label := name if name != "" else fmt.tprintf("#%d", ordinal)
					sem_error(
						s,
						fmt.tprintf("Unknown override '%s' in carve", label),
						.Undefined_Identifier,
						node_position(ast, from_idx),
					)
				} else {
					s.node_sems[from_idx].ref_binding = bid
				}
				if found && to_idx != INVALID_NODE {
					sem_check_carve_override(
						s,
						&s.bindings[bid],
						sv,
						name,
						node_position(ast, child),
					)
					if sv != nil {
						if _, uok := sv.(Unresolved_SV); !uok {
							append(&collected, Carve_Override_Entry{binding_id = bid, value = sv})
						}
					}
				}
			}
		case:
			sv := sem_evaluate_value(s, child)
			if target_scope_id != INVALID_SCOPE {
				bid, found := sem_resolve_by_index(s, target_scope_id, positional_idx)
				if found {
					target_entry := &s.bindings[bid]
					name :=
						sem_span_str(ast, target_entry.name) if target_entry.name != EMPTY_SPAN else fmt.tprintf("#%d", positional_idx)
					sem_check_carve_override(s, target_entry, sv, name, node_position(ast, child))
					if sv != nil {
						if _, uok := sv.(Unresolved_SV); !uok {
							append(&collected, Carve_Override_Entry{binding_id = bid, value = sv})
						}
					}
				}
				positional_idx += 1
			}
		}
	}
	return collected
}

sem_evaluate_carve :: proc(s: ^Semantic, idx: Node_Index) -> Static_Value {
	ast := s.ast
	source_idx := node_carve_source(ast, idx)
	pos := node_position(ast, idx)

	tsv := sem_evaluate_value(s, source_idx)

	if _, ok := tsv.(Unresolved_SV); ok {
		return Unresolved_SV{}
	}

	_, is_scope := tsv.(Node_Index)
	_, is_ref := tsv.(Ref_SV)

	if !is_scope && !is_ref {
		overrides := sem_evaluate_carve_children(s, idx)
		delete(overrides)
		if tsv == nil {
			sem_error(
				s,
				"Trying to carve an element that does not resolve to a scope",
				.Invalid_Carve,
				pos,
			)
		}
		return tsv
	}

	target_node: Node_Index
	if scope_node, s_ok := tsv.(Node_Index); s_ok {
		target_node = scope_node
	} else if ref, r_ok := tsv.(Ref_SV); r_ok {
		entry := &s.bindings[ref.binding]
		if e_scope, e_ok := entry.value.(Node_Index); e_ok {
			target_node = e_scope
		} else {
			overrides := sem_evaluate_carve_children(s, idx)
			delete(overrides)
			return entry.value
		}
	}

	target_scope_id, ok := sem_find_scope(s, target_node)
	if !ok {
		overrides := sem_evaluate_carve_children(s, idx)
		delete(overrides)
		return Unresolved_SV{}
	}

	target_flags := s.scopes[target_scope_id].flags

	overrides := sem_evaluate_carve_children(s, idx, target_scope_id)

	if .Self_Referential in target_flags {
		delete(overrides)
		return Unresolved_SV{}
	}

	if len(overrides) > 0 {
		sem_verify_carve_scope(s, target_scope_id, overrides[:], pos)
	}
	delete(overrides)

	return Node_Index(target_node)
}

sem_apply_carve_overlay :: proc(
	s: ^Semantic,
	target_scope_id: Scope_Id,
	carve_node: Node_Index,
) -> Static_Value {
	scope := s.scopes[target_scope_id]
	first := u32(scope.first_binding)

	for i in first ..< first + scope.binding_count {
		entry := &s.bindings[i]
		if entry.kind == .Product {
			if .Has_Value in entry.flags {
				return entry.value
			}
		}
	}

	return nil
}

/* ======================================================================
 * SECTION 15: EXECUTE EVALUATION
 * ====================================================================== */

sem_evaluate_execute :: proc(s: ^Semantic, idx: Node_Index) -> Static_Value {
	ast := s.ast
	target_idx := node_execute_target(ast, idx)

	tsv := sem_evaluate_value(s, target_idx)

	if _, ok := tsv.(Unresolved_SV); ok {
		return Unresolved_SV{}
	}

	if scope_node, is_scope := tsv.(Node_Index); is_scope {
		scope_id, ok := sem_find_scope(s, scope_node)
		if ok {
			scope := s.scopes[scope_id]
			if .Is_Collapsible in scope.flags {
				first := u32(scope.first_binding)
				for i in first ..< first + scope.binding_count {
					entry := &s.bindings[i]
					if entry.kind == .Product {
						if .Has_Value in entry.flags {
							return entry.value
						}
					}
				}
			}
		}
	}

	return Unresolved_SV{}
}

/* ======================================================================
 * SECTION 16: PATTERN EVALUATION
 * ====================================================================== */

sem_evaluate_pattern :: proc(s: ^Semantic, idx: Node_Index) -> Static_Value {
	ast := s.ast
	target_idx := node_pattern_target(ast, idx)
	branches := node_pattern_branches(ast, idx)

	tsv := sem_evaluate_value(s, target_idx)

	i := 0
	for i < len(branches) {
		pattern_idx := Node_Index(branches[i])
		product_idx := Node_Index(branches[i + 1]) if i + 1 < len(branches) else INVALID_NODE

		if sem_pattern_matches(s, tsv, pattern_idx) {
			if product_idx != INVALID_NODE {
				return sem_evaluate_value(s, product_idx)
			}
			return tsv
		}
		i += 2
	}

	return Unresolved_SV{}
}

sem_pattern_matches :: proc(s: ^Semantic, tsv: Static_Value, pattern_idx: Node_Index) -> bool {
	if pattern_idx == INVALID_NODE do return true
	ast := s.ast
	pat_kind := node_kind(ast, pattern_idx)

	#partial switch pat_kind {
	case .Literal:
		psv := sem_evaluate_literal(s, pattern_idx)
		if sv_kind_name(tsv) != sv_kind_name(psv) do return false
		switch p in psv {
		case Integer_SV:
			t, ok := tsv.(Integer_SV)
			return ok && t.content == p.content
		case Float_SV:
			t, ok := tsv.(Float_SV)
			return ok && t.content == p.content
		case bool:
			t, ok := tsv.(bool)
			return ok && t == p
		case Span:
			t, ok := tsv.(Span)
			return ok && sem_span_str(ast, t) == sem_span_str(ast, p)
		case Node_Index, Ref_SV, Unresolved_SV:
			return false
		}
	case .ScopeNode:
		_, ok := tsv.(Node_Index)
		return ok
	case .Identifier:
		return true
	}

	return false
}

/* ======================================================================
 * SECTION 16b: CARVE SCOPE VERIFICATION
 * ====================================================================== */

sem_verify_carve_scope :: proc(
	s: ^Semantic,
	target_scope_id: Scope_Id,
	overrides: []Carve_Override_Entry,
	carve_pos: Position,
) {
	scope := s.scopes[target_scope_id]
	first := u32(scope.first_binding)

	errors_before := len(s.errors)

	for i in first ..< first + scope.binding_count {
		entry := &s.bindings[i]
		if entry.kind != .Product do continue
		if entry.value_node == INVALID_NODE do continue

		sv := sem_vcarve_eval(s, entry.value_node, target_scope_id, overrides)
		if sv == nil do continue
		if _, uok := sv.(Unresolved_SV); uok do continue

		if .Has_Constraint in entry.flags && entry.constraint_node != INVALID_NODE {
			test_entry := Binding_Entry {
				value           = sv,
				constraint_node = entry.constraint_node,
				node            = entry.node,
				name            = entry.name,
				flags           = entry.flags,
			}
			sem_check_constraint(s, &test_entry)
		}
	}

	for i in errors_before ..< len(s.errors) {
		s.errors[i].position = carve_pos
	}
}

sem_vcarve_eval :: proc(
	s: ^Semantic,
	idx: Node_Index,
	scope_id: Scope_Id,
	overrides: []Carve_Override_Entry,
	depth: int = 0,
) -> Static_Value {
	if idx == INVALID_NODE do return nil
	if depth > 64 do return Unresolved_SV{}

	ast := s.ast
	kind := node_kind(ast, idx)

	#partial switch kind {
	case .Literal:
		return sem_evaluate_literal(s, idx)
	case .Identifier:
		return sem_vcarve_eval_identifier(s, idx, scope_id, overrides)
	case .Operator:
		return sem_vcarve_eval_operator(s, idx, scope_id, overrides, depth)
	case .Property:
		return sem_vcarve_eval_property(s, idx, scope_id, overrides, depth)
	case .ScopeNode:
		return Node_Index(idx)
	case .Carve:
		nsem := s.node_sems[idx]
		if .Has_Value in nsem.flags {
			return nsem.value
		}
		return Unresolved_SV{}
	case .Execute:
		nsem := s.node_sems[idx]
		if .Has_Value in nsem.flags {
			return nsem.value
		}
		return Unresolved_SV{}
	case .Pattern:
		return Unresolved_SV{}
	case .CompileTime:
		operand := node_unary_operand(ast, idx)
		return sem_vcarve_eval(s, operand, scope_id, overrides, depth + 1)
	case .Constraint:
		constraint_idx := node_left(ast, idx)
		return sem_vcarve_eval(s, constraint_idx, scope_id, overrides, depth + 1)
	}

	nsem := s.node_sems[idx]
	if .Has_Value in nsem.flags {
		return nsem.value
	}
	return Unresolved_SV{}
}

sem_vcarve_eval_identifier :: proc(
	s: ^Semantic,
	idx: Node_Index,
	scope_id: Scope_Id,
	overrides: []Carve_Override_Entry,
) -> Static_Value {
	ref_bid := s.node_sems[idx].ref_binding
	if ref_bid == INVALID_BINDING {
		return Unresolved_SV{}
	}

	for ov in overrides {
		if ov.binding_id == ref_bid {
			return ov.value
		}
	}

	entry := &s.bindings[ref_bid]
	if .Has_Value in entry.flags {
		return entry.value
	}
	return Unresolved_SV{}
}

sem_vcarve_eval_operator :: proc(
	s: ^Semantic,
	idx: Node_Index,
	scope_id: Scope_Id,
	overrides: []Carve_Override_Entry,
	depth: int,
) -> Static_Value {
	ast := s.ast
	op_kind := node_operator_kind(ast, idx)
	left_idx := node_operator_left(ast, idx)
	right_idx := node_operator_right(ast, idx)
	pos := node_position(ast, idx)

	if left_idx == INVALID_NODE && right_idx != INVALID_NODE {
		csv := sem_vcarve_eval(s, right_idx, scope_id, overrides, depth + 1)
		if _, ok := csv.(Unresolved_SV); ok do return Unresolved_SV{}
		return sem_vcarve_check_unary(s, csv, op_kind, pos)
	}
	if right_idx == INVALID_NODE && left_idx != INVALID_NODE {
		csv := sem_vcarve_eval(s, left_idx, scope_id, overrides, depth + 1)
		if _, ok := csv.(Unresolved_SV); ok do return Unresolved_SV{}
		return sem_vcarve_check_unary(s, csv, op_kind, pos)
	}
	if left_idx == INVALID_NODE && right_idx == INVALID_NODE {
		return nil
	}

	lsv := sem_vcarve_eval(s, left_idx, scope_id, overrides, depth + 1)
	rsv := sem_vcarve_eval(s, right_idx, scope_id, overrides, depth + 1)

	if _, ok := lsv.(Unresolved_SV); ok do return Unresolved_SV{}
	if _, ok := rsv.(Unresolved_SV); ok do return Unresolved_SV{}

	#partial switch op_kind {
	case .Add, .Subtract, .Multiply, .Divide, .Mod:
		return sem_fold_math(lsv, rsv, op_kind, pos, s)
	case .And, .Or, .Xor:
		return sem_fold_bitwise(lsv, rsv, op_kind, pos, s)
	case .Less, .Greater, .LessEqual, .GreaterEqual:
		return sem_fold_comparison(lsv, rsv, op_kind, pos, s)
	case .Equal:
		return sem_fold_equality(lsv, rsv, false, pos, s)
	case .NotEqual:
		return sem_fold_equality(lsv, rsv, true, pos, s)
	case .LShift, .RShift:
		return sem_fold_shift(lsv, rsv, op_kind, pos, s)
	}
	return Unresolved_SV{}
}

sem_vcarve_check_unary :: proc(
	s: ^Semantic,
	csv: Static_Value,
	op_kind: Operator_Kind,
	pos: Position,
) -> Static_Value {
	switch op_kind {
	case .Subtract:
		if iv, ok := csv.(Integer_SV); ok {
			iv.negative = true
			return iv
		}
		if fv, ok := csv.(Float_SV); ok {
			fv.content = -fv.content
			return fv
		}
		sem_error(
			s,
			fmt.tprintf("carve result: cannot negate %s", sv_kind_name(csv)),
			.Constraint_Violation,
			pos,
		)
	case .Not:
		if bv, ok := csv.(bool); ok {
			return bool(!bv)
		}
		if iv, ok := csv.(Integer_SV); ok {
			iv.content = ~iv.content
			return iv
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
		return csv
	}
	return csv
}

sem_vcarve_eval_property :: proc(
	s: ^Semantic,
	idx: Node_Index,
	scope_id: Scope_Id,
	overrides: []Carve_Override_Entry,
	depth: int,
) -> Static_Value {
	ast := s.ast
	prop_idx := node_right(ast, idx)
	source_idx := node_left(ast, idx)
	pos := node_position(ast, idx)

	if prop_idx == INVALID_NODE || node_kind(ast, prop_idx) != .Identifier {
		return nil
	}

	prop_name := node_name_str(ast, prop_idx)
	prop_ordinal := node_ordinal(ast, prop_idx)

	if source_idx == INVALID_NODE do return nil

	ssv := sem_vcarve_eval(s, source_idx, scope_id, overrides, depth + 1)

	source_name := ""
	if node_kind(ast, source_idx) == .Identifier {
		source_name = node_name_str(ast, source_idx)
	}
	prop_label := prop_name if prop_name != "" else fmt.tprintf("#%d", prop_ordinal)

	if _, ok := ssv.(Unresolved_SV); ok do return Unresolved_SV{}

	scope_node, is_scope := ssv.(Node_Index)
	if !is_scope {
		_, is_ref := ssv.(Ref_SV)
		if ssv != nil && !is_ref {
			if source_name != "" {
				sem_error(
					s,
					fmt.tprintf(
						"'%s' should have property '%s' but got %s",
						source_name,
						prop_label,
						sv_kind_name(ssv),
					),
					.Constraint_Violation,
					pos,
				)
			} else {
				sem_error(
					s,
					fmt.tprintf(
						"cannot access property '%s' on %s",
						prop_label,
						sv_kind_name(ssv),
					),
					.Constraint_Violation,
					pos,
				)
			}
		}
		return nil
	}

	sid, ok := sem_find_scope(s, scope_node)
	if !ok do return Unresolved_SV{}

	bid: Binding_Id
	found: bool
	if prop_name == "" && prop_ordinal >= 0 {
		bid, found = sem_resolve_by_index(s, sid, prop_ordinal)
	} else {
		bid, found = sem_resolve_in_scope(s, sid, prop_name)
	}

	if !found {
		if source_name != "" {
			sem_error(
				s,
				fmt.tprintf("'%s' should have property '%s'", source_name, prop_label),
				.Constraint_Violation,
				pos,
			)
		} else {
			sem_error(s, fmt.tprintf("no property '%s'", prop_label), .Constraint_Violation, pos)
		}
		return nil
	}

	for ov in overrides {
		if ov.binding_id == bid {
			return ov.value
		}
	}

	entry := &s.bindings[bid]
	if .Has_Value in entry.flags {
		return entry.value
	}

	return Ref_SV{binding = bid}
}

/* ======================================================================
 * SECTION 17: ERROR REPORTING
 * ====================================================================== */

sem_error :: proc(
	s: ^Semantic,
	message: string,
	error_type: Analyzer_Error_Type,
	position: Position,
) {
	error := Analyzer_Error {
		type     = error_type,
		message  = message,
		position = position,
	}
	append(&s.errors, error)
}

sem_warning :: proc(
	s: ^Semantic,
	message: string,
	error_type: Analyzer_Error_Type,
	position: Position,
) {
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
			fmt.eprintf(" = %s", sem_value_str(s, entry.value))
			if .Self_Referential in entry.flags do fmt.eprintf(" [SELF_REF]")
			fmt.eprintln()
		}
	}
	fmt.eprintln("=== END SCOPES ===")
}

sem_binding_kind_str :: proc(kind: Sem_Binding_Kind) -> string {
	switch kind {
	case .Pointing_Push:
		return "->"
	case .Pointing_Pull:
		return "<-"
	case .Event_Push:
		return ">-"
	case .Event_Pull:
		return "-<"
	case .Resonance_Push:
		return ">>-"
	case .Resonance_Pull:
		return "-<<"
	case .Reactive_Push:
		return ">>="
	case .Reactive_Pull:
		return "=<<"
	case .Expand:
		return "expand"
	case .Product:
		return "product"
	}
	return "?"
}

sem_value_str :: proc(s: ^Semantic, sv: Static_Value) -> string {
	switch v in sv {
	case Integer_SV:
		if v.negative {
			return fmt.tprintf("-%d", v.content)
		}
		return fmt.tprintf("%d", v.content)
	case Float_SV:
		return fmt.tprintf("%g", v.content)
	case bool:
		return fmt.tprintf("%t", v)
	case Span:
		return fmt.tprintf("\"%s\"", sem_span_str(s.ast, v))
	case Node_Index:
		return fmt.tprintf("scope@%d", v)
	case Ref_SV:
		return fmt.tprintf("ref@%d", v.binding)
	case Unresolved_SV:
		return "symbolic"
	}
	return "none"
}
