package compiler

import "core:fmt"
import "core:strconv"
import "core:strings"

/* ======================================================================
 * SECTION 1: TYPES
 * ====================================================================== */

Reduced_Kind :: enum u8 {
	None,
	Integer,
	Float,
	Bool,
	String,
	Scope,
}

Reduced_Value :: struct {
	kind:         Reduced_Kind,
	data:         Reduced_Data,
	extra_scopes: []Node_Index,
}

Reduced_Data :: struct #raw_union {
	integer: Integer_SV,
	float_v: Float_SV,
	bool_v:  bool,
	str:     string,
	scope:   Node_Index,
}

Override :: struct {
	name:  string,
	value: Reduced_Value,
}

Env_Frame :: struct {
	scope_id:  Scope_Id,
	overrides: []Override,
}

Reducer :: struct {
	sem:             ^Semantic,
	ast:             ^Ast,
	env:             [dynamic]Env_Frame,
	errors:          [dynamic]Analyzer_Error,
	max_depth:       int,
	depth:           int,
	current_binding: Binding_Id,
}

REDUCE_MAX_DEPTH :: 1024

/* ======================================================================
 * SECTION 2: ENTRY POINT
 * ====================================================================== */

reduce :: proc(sem: ^Semantic, ast: ^Ast) -> Reduced_Value {
	r := Reducer {
		sem             = sem,
		ast             = ast,
		env             = make([dynamic]Env_Frame, 0, 16),
		errors          = make([dynamic]Analyzer_Error, 0),
		max_depth       = REDUCE_MAX_DEPTH,
		depth           = 0,
		current_binding = INVALID_BINDING,
	}

	root_scope_id := Scope_Id(1)
	if int(root_scope_id) >= len(sem.scopes) {
		return Reduced_Value{kind = .None}
	}

	append(&r.env, Env_Frame{scope_id = root_scope_id})
	result := find_scope_product(&r, root_scope_id)
	pop(&r.env)

	if len(r.errors) > 0 {
		fmt.eprintln("=== REDUCTION ERRORS ===")
		for err in r.errors {
			fmt.eprintf("  %v: %s\n", err.type, err.message)
		}
	}

	return result
}

/* ======================================================================
 * SECTION 3: CORE REDUCTION
 * ====================================================================== */

reduce_node :: proc(r: ^Reducer, idx: Node_Index) -> Reduced_Value {
	if idx == INVALID_NODE do return Reduced_Value{kind = .None}

	r.depth += 1
	defer {r.depth -= 1}

	if r.depth > r.max_depth {
		reduce_error(
			r,
			"Reduction depth exceeded, possible infinite loop",
			.Infinite_Recursion,
			idx,
		)
		return Reduced_Value{kind = .None}
	}

	ast := r.ast
	kind := node_kind(ast, idx)

	#partial switch kind {
	case .Literal:
		return reduce_literal(r, idx)
	case .Identifier:
		return reduce_identifier(r, idx)
	case .Operator:
		return reduce_operator(r, idx)
	case .ScopeNode:
		sv: Reduced_Value
		sv.kind = .Scope
		sv.data.scope = idx
		return sv
	case .Carve:
		return reduce_carve(r, idx)
	case .Execute:
		return reduce_execute(r, idx)
	case .Pattern:
		return reduce_pattern(r, idx)
	case .Property:
		return reduce_property(r, idx)
	case .CompileTime:
		operand := node_unary_operand(ast, idx)
		return reduce_node(r, operand)
	case .Product:
		operand := node_unary_operand(ast, idx)
		return reduce_node(r, operand)
	case .Constraint:
		sem := r.sem.node_sems[idx]
		if .Has_Value in sem.flags {
			return static_to_reduced(sem.value, ast)
		}
		constraint_idx := node_left(ast, idx)
		constraint_val := reduce_node(r, constraint_idx)
		if constraint_val.kind == .Scope {
			scope_id, ok := sem_find_scope(r.sem, constraint_val.data.scope)
			if ok {
				return find_scope_product(r, scope_id)
			}
		}
		return constraint_val
	case .Range:
		return Reduced_Value{kind = .None}
	case .Expand:
		operand := node_unary_operand(ast, idx)
		return reduce_node(r, operand)
	case .External:
		return Reduced_Value{kind = .None}
	}

	return Reduced_Value{kind = .None}
}

/* ======================================================================
 * SECTION 4: LITERALS
 * ====================================================================== */

reduce_literal :: proc(r: ^Reducer, idx: Node_Index) -> Reduced_Value {
	ast := r.ast
	lit_kind := node_literal_kind(ast, idx)
	text := node_text(ast, idx)
	rv: Reduced_Value

	switch lit_kind {
	case .Integer:
		content, ok := strconv.parse_int(text)
		rv.kind = .Integer
		if ok do rv.data.integer.content = u64(content)
	case .Float:
		content, ok := strconv.parse_f64(text)
		rv.kind = .Float
		if ok do rv.data.float_v.content = content
	case .String:
		rv.kind = .String
		rv.data.str = text
	case .Bool:
		rv.kind = .Bool
		rv.data.bool_v = text == "true"
	case .Hexadecimal:
		hex_text := text
		if len(hex_text) > 2 && hex_text[0] == '0' && (hex_text[1] == 'x' || hex_text[1] == 'X') {
			hex_text = hex_text[2:]
		}
		content, ok := strconv.parse_int(hex_text, 16)
		rv.kind = .Integer
		if ok do rv.data.integer.content = u64(content)
	case .Binary:
		bin_text := text
		if len(bin_text) > 2 && bin_text[0] == '0' && (bin_text[1] == 'b' || bin_text[1] == 'B') {
			bin_text = bin_text[2:]
		}
		content, ok := strconv.parse_int(bin_text, 2)
		rv.kind = .Integer
		if ok do rv.data.integer.content = u64(content)
	}
	return rv
}

/* ======================================================================
 * SECTION 5: IDENTIFIER RESOLUTION
 * ====================================================================== */

reduce_binding :: proc(r: ^Reducer, bid: Binding_Id) -> Reduced_Value {
	entry := &r.sem.bindings[bid]
	if entry.value_node != INVALID_NODE {
		prev := r.current_binding
		r.current_binding = bid
		result := reduce_node(r, entry.value_node)
		r.current_binding = prev
		return result
	}
	if .Has_Value in entry.flags {
		return static_to_reduced(entry.value, r.ast)
	}
	return Reduced_Value{kind = .None}
}

reduce_identifier :: proc(r: ^Reducer, idx: Node_Index) -> Reduced_Value {
	name := node_name_str(r.ast, idx)
	ordinal := node_ordinal(r.ast, idx)

	for i := len(r.env) - 1; i >= 0; i -= 1 {
		frame := r.env[i]
		if ordinal < 0 {
			for ov in frame.overrides {
				if ov.name == name {
					return ov.value
				}
			}
		}

		if frame.scope_id != INVALID_SCOPE {
			if ordinal >= 0 {
				bid, found := sem_resolve_by_ordinal(r.sem, frame.scope_id, name, ordinal)
				if found {
					return reduce_binding(r, bid)
				}
			} else {
				bid, found := sem_resolve_in_scope(r.sem, frame.scope_id, name)
				if found {
					if bid == r.current_binding && frame.scope_id == r.sem.bindings[bid].scope_id {
						prev, prev_found := resolve_previous_binding(r, frame.scope_id, name, bid)
						if prev_found {
							return reduce_binding(r, prev)
						}
						continue
					}
					return reduce_binding(r, bid)
				}
			}
		}
	}

	bid, found := sem_resolve_builtin_binding(r.sem, name)
	if found {
		entry := &r.sem.bindings[bid]
		if .Has_Value in entry.flags {
			return static_to_reduced(entry.value, r.ast)
		}
	}

	reduce_error(
		r,
		fmt.tprintf("Undefined identifier '%s' during reduction", name),
		.Undefined_Identifier,
		idx,
	)
	return Reduced_Value{kind = .None}
}

/* ======================================================================
 * SECTION 6: OPERATOR REDUCTION
 * ====================================================================== */

reduce_operator :: proc(r: ^Reducer, idx: Node_Index) -> Reduced_Value {
	ast := r.ast
	op_kind := node_operator_kind(ast, idx)
	left_idx := node_operator_left(ast, idx)
	right_idx := node_operator_right(ast, idx)

	if left_idx == INVALID_NODE && right_idx != INVALID_NODE {
		return reduce_unary(r, right_idx, op_kind)
	}
	if right_idx == INVALID_NODE && left_idx != INVALID_NODE {
		return reduce_unary(r, left_idx, op_kind)
	}

	left := reduce_node(r, left_idx)
	right := reduce_node(r, right_idx)

	rv: Reduced_Value

	#partial switch op_kind {
	case .Add, .Subtract, .Multiply, .Divide, .Mod:
		return reduce_math(left, right, op_kind)
	case .And, .Or, .Xor:
		return reduce_bitwise(left, right, op_kind)
	case .Less, .Greater, .LessEqual, .GreaterEqual:
		return reduce_comparison(left, right, op_kind)
	case .Equal:
		rv.kind = .Bool
		rv.data.bool_v = reduced_equal(left, right)
		return rv
	case .NotEqual:
		rv.kind = .Bool
		rv.data.bool_v = !reduced_equal(left, right)
		return rv
	case .LShift, .RShift:
		if left.kind == .Integer && right.kind == .Integer {
			rv.kind = .Integer
			rv.data.integer.kind = left.data.integer.kind
			if op_kind == .LShift {
				rv.data.integer.content = left.data.integer.content << right.data.integer.content
			} else {
				rv.data.integer.content = left.data.integer.content >> right.data.integer.content
			}
			return rv
		}
	}

	return Reduced_Value{kind = .None}
}

reduce_unary :: proc(r: ^Reducer, child_idx: Node_Index, op: Operator_Kind) -> Reduced_Value {
	child := reduce_node(r, child_idx)
	rv: Reduced_Value

	switch op {
	case .Subtract:
		if child.kind == .Integer {
			rv = child
			rv.data.integer.negative = !child.data.integer.negative
			return rv
		}
		if child.kind == .Float {
			rv = child
			rv.data.float_v.content = -child.data.float_v.content
			return rv
		}
	case .Not:
		if child.kind == .Bool {
			rv.kind = .Bool
			rv.data.bool_v = !child.data.bool_v
			return rv
		}
		if child.kind == .Integer {
			rv = child
			rv.data.integer.content = ~child.data.integer.content
			return rv
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
	}
	return child
}

reduce_math :: proc(l, r: Reduced_Value, op: Operator_Kind) -> Reduced_Value {
	rv: Reduced_Value
	if l.kind == .Integer && r.kind == .Integer {
		rv.kind = .Integer
		rv.data.integer.kind =
			l.data.integer.kind if l.data.integer.kind != .none else r.data.integer.kind
		#partial switch op {
		case .Add:
			rv.data.integer.content = l.data.integer.content + r.data.integer.content
		case .Subtract:
			rv.data.integer.content = l.data.integer.content - r.data.integer.content
		case .Multiply:
			rv.data.integer.content = l.data.integer.content * r.data.integer.content
		case .Divide:
			if r.data.integer.content != 0 do rv.data.integer.content = l.data.integer.content / r.data.integer.content
		case .Mod:
			if r.data.integer.content != 0 do rv.data.integer.content = l.data.integer.content % r.data.integer.content
		}
		return rv
	}
	if l.kind == .Float && r.kind == .Float {
		rv.kind = .Float
		rv.data.float_v.kind =
			l.data.float_v.kind if l.data.float_v.kind != .none else r.data.float_v.kind
		#partial switch op {
		case .Add:
			rv.data.float_v.content = l.data.float_v.content + r.data.float_v.content
		case .Subtract:
			rv.data.float_v.content = l.data.float_v.content - r.data.float_v.content
		case .Multiply:
			rv.data.float_v.content = l.data.float_v.content * r.data.float_v.content
		case .Divide:
			if r.data.float_v.content != 0 do rv.data.float_v.content = l.data.float_v.content / r.data.float_v.content
		}
		return rv
	}
	if l.kind == .Scope && r.kind == .Scope && op == .Add {
		extras := make([dynamic]Node_Index, 0, 4)
		if l.extra_scopes != nil {
			for s in l.extra_scopes do append(&extras, s)
		}
		append(&extras, r.data.scope)
		if r.extra_scopes != nil {
			for s in r.extra_scopes do append(&extras, s)
		}

		rv.kind = .Scope
		rv.data.scope = l.data.scope
		rv.extra_scopes = extras[:]
		return rv
	}
	return Reduced_Value{kind = .None}
}

reduce_bitwise :: proc(l, r: Reduced_Value, op: Operator_Kind) -> Reduced_Value {
	rv: Reduced_Value
	if l.kind == .Integer && r.kind == .Integer {
		rv.kind = .Integer
		rv.data.integer.kind =
			l.data.integer.kind if l.data.integer.kind != .none else r.data.integer.kind
		#partial switch op {
		case .And:
			rv.data.integer.content = l.data.integer.content & r.data.integer.content
		case .Or:
			rv.data.integer.content = l.data.integer.content | r.data.integer.content
		case .Xor:
			rv.data.integer.content = l.data.integer.content ~ r.data.integer.content
		}
		return rv
	}
	if l.kind == .Bool && r.kind == .Bool {
		rv.kind = .Bool
		#partial switch op {
		case .And:
			rv.data.bool_v = l.data.bool_v && r.data.bool_v
		case .Or:
			rv.data.bool_v = l.data.bool_v || r.data.bool_v
		case .Xor:
			rv.data.bool_v = l.data.bool_v ~ r.data.bool_v
		}
		return rv
	}
	return Reduced_Value{kind = .None}
}

reduce_comparison :: proc(l, r: Reduced_Value, op: Operator_Kind) -> Reduced_Value {
	rv: Reduced_Value
	rv.kind = .Bool

	rcmp :: #force_inline proc(a, b: $T, op: Operator_Kind) -> bool {
		#partial switch op {
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

	if l.kind == .Integer && r.kind == .Integer {
		rv.data.bool_v = rcmp(l.data.integer.content, r.data.integer.content, op)
		return rv
	}
	if l.kind == .Float && r.kind == .Float {
		rv.data.bool_v = rcmp(l.data.float_v.content, r.data.float_v.content, op)
		return rv
	}
	return Reduced_Value{kind = .None}
}

reduced_equal :: proc(l, r: Reduced_Value) -> bool {
	if l.kind != r.kind do return false
	switch l.kind {
	case .Integer:
		return l.data.integer.content == r.data.integer.content
	case .Float:
		return l.data.float_v.content == r.data.float_v.content
	case .Bool:
		return l.data.bool_v == r.data.bool_v
	case .String:
		return l.data.str == r.data.str
	case .Scope:
		return l.data.scope == r.data.scope
	case .None:
		return true
	}
	return false
}

/* ======================================================================
 * SECTION 7: CARVE REDUCTION
 * ====================================================================== */

build_carve_overrides :: proc(
	r: ^Reducer,
	carve_idx: Node_Index,
	scope_id: Scope_Id,
) -> [dynamic]Override {
	ast := r.ast
	scope := r.sem.scopes[scope_id]
	first := u32(scope.first_binding)

	overrides := make([dynamic]Override, 0, 8)

	carve_children := node_carve_children(ast, carve_idx)
	named_idx := 0
	for child in carve_children {
		child_kind := node_kind(ast, child)

		#partial switch child_kind {
		case .Pointing, .PointingPull:
			from_idx := node_left(ast, child)
			to_idx := node_right(ast, child)
			if from_idx != INVALID_NODE && node_kind(ast, from_idx) == .Identifier {
				name := node_name_str(ast, from_idx)
				value := reduce_node(r, to_idx)
				append(&overrides, Override{name = name, value = value})
			} else if from_idx != INVALID_NODE && node_kind(ast, from_idx) == .Constraint {
				name_idx := node_right(ast, from_idx)
				if name_idx != INVALID_NODE && node_kind(ast, name_idx) == .Identifier {
					name := node_name_str(ast, name_idx)
					value := reduce_node(r, to_idx)
					append(&overrides, Override{name = name, value = value})
				}
			}
		case:
			value := reduce_node(r, child)
			pos_idx := 0
			for i in first ..< first + scope.binding_count {
				entry := &r.sem.bindings[i]
				if entry.kind != .Product && entry.name != EMPTY_SPAN {
					if pos_idx == named_idx {
						target_name := sem_span_str(ast, entry.name)
						append(&overrides, Override{name = target_name, value = value})
						break
					}
					pos_idx += 1
				}
			}
			named_idx += 1
		}
	}

	return overrides
}

reduce_carve :: proc(r: ^Reducer, idx: Node_Index) -> Reduced_Value {
	ast := r.ast
	source_idx := node_carve_source(ast, idx)

	source := reduce_node(r, source_idx)
	if source.kind != .Scope {
		return source
	}

	scope_node := source.data.scope
	scope_id, ok := sem_find_scope(r.sem, scope_node)
	if !ok do return Reduced_Value{kind = .None}

	overrides := build_carve_overrides(r, idx, scope_id)
	defer delete(overrides)

	frame := Env_Frame {
		scope_id  = scope_id,
		overrides = overrides[:],
	}
	append(&r.env, frame)

	scope := r.sem.scopes[scope_id]
	first := u32(scope.first_binding)
	for i in first ..< first + scope.binding_count {
		entry := &r.sem.bindings[i]
		name := sem_span_str(ast, entry.name)
		rv: Reduced_Value
		found_override := false
		if name != "" {
			for ov in overrides {
				if ov.name == name {
					rv = ov.value
					found_override = true
					break
				}
			}
		}
		if !found_override {
			rv = reduce_binding(r, Binding_Id(i))
		}
		sv := reduced_to_static(rv)
		if sv != nil {
			entry.value = sv
			entry.flags |= {.Has_Value}
		}
	}

	pop(&r.env)
	return Reduced_Value{kind = .Scope, data = {scope = scope_node}}
}

/* ======================================================================
 * SECTION 8: EXECUTE REDUCTION
 * ====================================================================== */

reduce_execute :: proc(r: ^Reducer, idx: Node_Index) -> Reduced_Value {
	ast := r.ast
	target_idx := node_execute_target(ast, idx)
	target_kind := node_kind(ast, target_idx)

	if target_kind == .Carve {
		return reduce_carve_and_execute(r, target_idx)
	}

	target := reduce_node(r, target_idx)
	if target.kind != .Scope do return target

	scope_id, ok := sem_find_scope(r.sem, target.data.scope)
	if !ok do return Reduced_Value{kind = .None}

	return reduce_scope_product(r, scope_id, nil)
}

reduce_carve_and_execute :: proc(r: ^Reducer, carve_idx: Node_Index) -> Reduced_Value {
	source_idx := node_carve_source(r.ast, carve_idx)

	source := reduce_node(r, source_idx)
	if source.kind != .Scope {
		return source
	}

	scope_id, ok := sem_find_scope(r.sem, source.data.scope)
	if !ok do return Reduced_Value{kind = .None}

	overrides := build_carve_overrides(r, carve_idx, scope_id)
	defer delete(overrides)

	return reduce_scope_product(r, scope_id, overrides[:])
}

reduce_scope_product :: proc(
	r: ^Reducer,
	scope_id: Scope_Id,
	overrides: []Override,
) -> Reduced_Value {
	frame := Env_Frame {
		scope_id  = scope_id,
		overrides = overrides,
	}
	append(&r.env, frame)
	result := find_scope_product(r, scope_id)
	pop(&r.env)
	return result
}

find_scope_product :: proc(r: ^Reducer, scope_id: Scope_Id) -> Reduced_Value {
	scope := r.sem.scopes[scope_id]
	first := u32(scope.first_binding)
	for i in first ..< first + scope.binding_count {
		entry := &r.sem.bindings[i]
		if entry.kind == .Product {
			return reduce_node(r, entry.value_node)
		}
		if entry.kind == .Expand {
			if entry.value_node != INVALID_NODE && node_kind(r.ast, entry.value_node) == .Carve {
				carve_idx := entry.value_node
				source_idx := node_carve_source(r.ast, carve_idx)
				source := reduce_node(r, source_idx)
				if source.kind == .Scope {
					expanded_id, ok := sem_find_scope(r.sem, source.data.scope)
					if ok {
						overrides := build_carve_overrides(r, carve_idx, expanded_id)
						apply_parent_overrides(r, &overrides)
						inner := reduce_scope_product(r, expanded_id, overrides[:])
						delete(overrides)
						if inner.kind != .None do return inner
					}
				}
			} else {
				inline_val := reduce_node(r, entry.value_node)
				if inline_val.kind == .Scope {
					expanded_id, ok := sem_find_scope(r.sem, inline_val.data.scope)
					if ok {
						inner := reduce_scope_product(r, expanded_id, nil)
						if inner.kind != .None do return inner
					}
				}
			}
		}
	}
	return Reduced_Value{kind = .None}
}

apply_parent_overrides :: proc(r: ^Reducer, overrides: ^[dynamic]Override) {
	for i := len(r.env) - 1; i >= 0; i -= 1 {
		for parent_ov in r.env[i].overrides {
			for &ov in overrides {
				if ov.name == parent_ov.name {
					ov.value = parent_ov.value
				}
			}
		}
	}
}

/* ======================================================================
 * SECTION 9: PATTERN REDUCTION
 * ====================================================================== */

reduce_pattern :: proc(r: ^Reducer, idx: Node_Index) -> Reduced_Value {
	ast := r.ast
	target_idx := node_pattern_target(ast, idx)
	branches := node_pattern_branches(ast, idx)

	target := reduce_node(r, target_idx)

	i := 0
	for i < len(branches) {
		pattern_idx := Node_Index(branches[i])
		product_idx := Node_Index(branches[i + 1]) if i + 1 < len(branches) else INVALID_NODE

		if reduce_matches(r, target, pattern_idx) {
			if product_idx != INVALID_NODE {
				return reduce_node(r, product_idx)
			}
			return target
		}
		i += 2
	}

	return Reduced_Value{kind = .None}
}

reduce_matches :: proc(r: ^Reducer, target: Reduced_Value, pattern_idx: Node_Index) -> bool {
	if pattern_idx == INVALID_NODE do return true

	ast := r.ast
	pat_kind := node_kind(ast, pattern_idx)

	#partial switch pat_kind {
	case .Literal:
		pat := reduce_literal(r, pattern_idx)
		return reduced_equal(target, pat)
	case .ScopeNode:
		return target.kind == .Scope
	case .Identifier:
		return true
	case .Operator:
		op := node_operator_kind(ast, pattern_idx)
		left_idx := node_operator_left(ast, pattern_idx)
		right_idx := node_operator_right(ast, pattern_idx)
		if left_idx == INVALID_NODE && right_idx != INVALID_NODE {
			right := reduce_node(r, right_idx)
			rv := reduce_comparison(target, right, op)
			return rv.kind == .Bool && rv.data.bool_v
		}
	}

	return false
}

/* ======================================================================
 * SECTION 10: PROPERTY REDUCTION
 * ====================================================================== */

reduce_property :: proc(r: ^Reducer, idx: Node_Index) -> Reduced_Value {
	ast := r.ast
	prop_idx := node_right(ast, idx)
	source_idx := node_left(ast, idx)

	if prop_idx == INVALID_NODE || node_kind(ast, prop_idx) != .Identifier {
		return Reduced_Value{kind = .None}
	}

	prop_name := node_name_str(ast, prop_idx)
	prop_ordinal := node_ordinal(ast, prop_idx)

	if source_idx != INVALID_NODE {
		source := reduce_node(r, source_idx)
		if source.kind == .Scope {
			if source.extra_scopes != nil {
				for i := len(source.extra_scopes) - 1; i >= 0; i -= 1 {
					eid, eok := sem_find_scope(r.sem, source.extra_scopes[i])
					if !eok do continue
					bid: Binding_Id
					found: bool
					if prop_name == "" && prop_ordinal >= 0 {
						bid, found = sem_resolve_by_index(r.sem, eid, prop_ordinal)
					} else {
						bid, found = sem_resolve_in_scope(r.sem, eid, prop_name)
					}
					if found {
						return reduce_binding(r, bid)
					}
				}
			}
			scope_id, ok := sem_find_scope(r.sem, source.data.scope)
			if ok {
				bid: Binding_Id
				found: bool
				if prop_name == "" && prop_ordinal >= 0 {
					bid, found = sem_resolve_by_index(r.sem, scope_id, prop_ordinal)
				} else {
					bid, found = sem_resolve_in_scope(r.sem, scope_id, prop_name)
				}
				if found {
					return reduce_binding(r, bid)
				}
			}
		}
	}

	return Reduced_Value{kind = .None}
}

/* ======================================================================
 * SECTION 11: UTILITIES
 * ====================================================================== */

reduced_to_static :: proc(rv: Reduced_Value) -> Static_Value {
	switch rv.kind {
	case .Integer:
		return rv.data.integer
	case .Float:
		return rv.data.float_v
	case .Bool:
		return rv.data.bool_v
	case .String:
		return Span{}
	case .Scope:
		return rv.data.scope
	case .None:
		return nil
	}
	return nil
}

static_to_reduced :: proc(sv: Static_Value, ast: ^Ast) -> Reduced_Value {
	rv: Reduced_Value
	switch v in sv {
	case Integer_SV:
		rv.kind = .Integer
		rv.data.integer = v
	case Float_SV:
		rv.kind = .Float
		rv.data.float_v = v
	case bool:
		rv.kind = .Bool
		rv.data.bool_v = v
	case Span:
		rv.kind = .String
		rv.data.str = sem_span_str(ast, v)
	case Node_Index:
		rv.kind = .Scope
		rv.data.scope = v
	case Ref_SV, Symbolic_SV:
		rv.kind = .None
	}
	return rv
}

resolve_previous_binding :: proc(
	r: ^Reducer,
	scope_id: Scope_Id,
	name: string,
	current: Binding_Id,
) -> (
	Binding_Id,
	bool,
) {
	scope := r.sem.scopes[scope_id]
	first := u32(scope.first_binding)
	last_found := INVALID_BINDING
	for i in first ..< first + scope.binding_count {
		bid := Binding_Id(i)
		if bid == current do break
		entry := &r.sem.bindings[i]
		if entry.name != EMPTY_SPAN && sem_span_str(r.ast, entry.name) == name {
			last_found = bid
		}
	}
	return last_found, last_found != INVALID_BINDING
}

reduce_error :: proc(
	r: ^Reducer,
	message: string,
	error_type: Analyzer_Error_Type,
	idx: Node_Index,
) {
	pos := node_position(r.ast, idx) if idx != INVALID_NODE else Position{}
	append(&r.errors, Analyzer_Error{type = error_type, message = message, position = pos})
}

reduced_to_string :: proc(rv: Reduced_Value, sem: ^Semantic = nil, ast: ^Ast = nil) -> string {
	switch rv.kind {
	case .None:
		return fmt.tprintf("none")
	case .Integer:
		if rv.data.integer.negative {
			return fmt.tprintf("-%d", rv.data.integer.content)
		} else {
			return fmt.tprintf("%d", rv.data.integer.content)
		}
	case .Float:
		return fmt.tprintf("%f", rv.data.float_v.content)
	case .Bool:
		return fmt.tprintf("%v", rv.data.bool_v)
	case .String:
		return fmt.tprintf("\"%s\"", rv.data.str)
	case .Scope:
		if sem != nil && ast != nil {
			if rv.extra_scopes != nil {
				return composite_scope_to_string(rv.data.scope, rv.extra_scopes, sem, ast)
			}
			return scope_to_string(rv.data.scope, sem, ast)
		}
		return fmt.tprintf("scope@%d", rv.data.scope)
	}
	return "none"
}

scope_to_string :: proc(
	scope_node: Node_Index,
	sem: ^Semantic,
	ast: ^Ast,
	depth: int = 0,
) -> string {
	if depth > 8 do return "{...}"

	b := strings.builder_make(0, 128)
	strings.write_string(&b, "{ ")
	write_scope_bindings(&b, scope_node, sem, ast, depth, 0)
	strings.write_string(&b, " }")
	return strings.to_string(b)
}

composite_scope_to_string :: proc(
	first_scope: Node_Index,
	extra: []Node_Index,
	sem: ^Semantic,
	ast: ^Ast,
) -> string {
	b := strings.builder_make(0, 128)
	strings.write_string(&b, "{ ")
	count := write_scope_bindings(&b, first_scope, sem, ast, 0, 0)
	for s in extra {
		count = write_scope_bindings(&b, s, sem, ast, 0, count)
	}
	strings.write_string(&b, " }")
	return strings.to_string(b)
}

@(private = "file")
write_scope_bindings :: proc(
	b: ^strings.Builder,
	scope_node: Node_Index,
	sem: ^Semantic,
	ast: ^Ast,
	depth: int,
	start_count: int,
) -> int {
	scope_id, ok := sem_find_scope(sem, scope_node)
	if !ok do return start_count

	scope := sem.scopes[scope_id]
	first := u32(scope.first_binding)

	count := start_count
	for i in first ..< first + scope.binding_count {
		entry := &sem.bindings[i]
		name := sem_span_str(ast, entry.name)

		if count > 0 do strings.write_string(b, ", ")

		if entry.kind == .Product {
			strings.write_string(b, "-> ")
			write_binding_value(b, entry, sem, ast, depth)
		} else {
			constraint_str := ""
			if .Has_Constraint in entry.flags && entry.constraint_node != INVALID_NODE {
				constraint_str = sem_constraint_name(sem, entry.constraint_node)
			}
			if constraint_str != "" && constraint_str != "unknown" {
				strings.write_string(b, constraint_str)
				strings.write_string(b, ":")
			}
			if name != "" {
				strings.write_string(b, name)
				strings.write_string(b, " -> ")
			}
			write_binding_value(b, entry, sem, ast, depth)
		}
		count += 1
	}
	return count
}

@(private = "file")
write_binding_value :: proc(
	b: ^strings.Builder,
	entry: ^Binding_Entry,
	sem: ^Semantic,
	ast: ^Ast,
	depth: int,
) {
	if .Has_Value in entry.flags {
		switch v in entry.value {
		case Integer_SV:
			if v.negative {
				fmt.sbprintf(b, "-%d", v.content)
			} else {
				fmt.sbprintf(b, "%d", v.content)
			}
		case Float_SV:
			fmt.sbprintf(b, "%f", v.content)
		case bool:
			fmt.sbprintf(b, "%v", v)
		case Span:
			fmt.sbprintf(b, "\"%s\"", sem_span_str(ast, v))
		case Node_Index:
			strings.write_string(b, scope_to_string(v, sem, ast, depth + 1))
		case Ref_SV, Symbolic_SV:
			if entry.value_node != INVALID_NODE {
				text := node_text(ast, entry.value_node)
				if text != "" {
					strings.write_string(b, text)
				} else {
					strings.write_string(b, "?")
				}
			} else {
				strings.write_string(b, "?")
			}
		case:
			if entry.value_node != INVALID_NODE {
				text := node_text(ast, entry.value_node)
				if text != "" {
					strings.write_string(b, text)
				} else {
					strings.write_string(b, "?")
				}
			} else {
				strings.write_string(b, "?")
			}
		}
	} else if entry.value_node != INVALID_NODE {
		vk := node_kind(ast, entry.value_node)
		if vk == .ScopeNode {
			strings.write_string(b, scope_to_string(entry.value_node, sem, ast, depth + 1))
		} else {
			text := node_text(ast, entry.value_node)
			if text != "" {
				strings.write_string(b, text)
			} else {
				strings.write_string(b, "?")
			}
		}
	} else {
		strings.write_string(b, "?")
	}
}

print_reduced :: proc(rv: Reduced_Value, sem: ^Semantic = nil, ast: ^Ast = nil) {
	fmt.println(reduced_to_string(rv, sem, ast))
}
