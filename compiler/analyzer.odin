package compiler

import "core:fmt"
import "core:strconv"
import "core:strings"

/* ======================================================================
 * SECTION 1: SHARED TYPES
 * ====================================================================== */
Segment :: struct {
	lo: Maybe(i64),  // nil = -∞
	hi: Maybe(i64),  // nil = +∞
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

Binding_Kind :: enum u8 {
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

Sum_Type :: struct {
	left:  ^Type,
	right: ^Type,
}

Product_Type :: struct {
	left:  ^Type,
	right: ^Type,
}

Negate_Type :: struct {
	operand: ^Type,
}

Scope_Type :: struct {
	parent: ^Scope_Type,
	names:  [dynamic]string,
	types:  [dynamic]^Type,
	kind:   [dynamic]Binding_Kind,
	values: [dynamic]^Type,
}

Execute_Type :: struct {
	target: ^Type,
}

Carve_Type :: struct {
	source:     ^Type,
	references: [dynamic]Reference,
	values:     [dynamic]^Type,
}

Reference :: struct {
	name:       Maybe(string),
	index:      Maybe(u64),
	match:      ^Type,
	constraint: ^Type,
}

Reference_Type :: struct {
	target:    ^Type,
	reference: ^Reference,
}

Mention_Type :: struct {
	name:       string,
	target:     ^Type,
	constraint: ^Type,
}

Integer_Type :: struct {
	segments: []Segment,
}

Float_Type :: struct {
	kind:  FloatKind,
	value: Maybe(f64),
}

Compose_Type :: struct {
	left:      ^Type,
	right:     ^Type,
	operator:  Operator_Kind,
	type_fold: ^Type,
}

Range_Type :: struct {
	left:  ^Type,
	right: ^Type,
}

Bool_Type :: struct {
	value: bool,
}

String_Type :: struct {
	value: Maybe(string),
}

None_Type :: struct {}

Unknown_Type :: struct {}

Invalid_Type :: struct {}

Type :: union {
	Sum_Type,
	Product_Type,
	Negate_Type,
	Compose_Type,
	String_Type,
	Scope_Type,
	Integer_Type,
	Float_Type,
	Execute_Type,
	Range_Type,
	Bool_Type,
	None_Type,
	Invalid_Type,
	Unknown_Type,
	Carve_Type,
	Mention_Type,
	Reference_Type,
}

Analyzer :: struct {
	ast:      ^Ast,
	scope:    ^Scope_Type,
	errors:   [dynamic]Analyzer_Error,
	warnings: [dynamic]Analyzer_Error,
}

/* ======================================================================
 * SECTION 3: ANALYZER CORE
 * ====================================================================== */
analyze :: proc(cache: ^Cache, ast: ^Ast) -> bool {
	a := Analyzer {
		ast      = ast,
		scope    = new(Scope_Type),
		errors   = make([dynamic]Analyzer_Error, 0),
		warnings = make([dynamic]Analyzer_Error, 0),
	}

	root := ast_root(ast)
	root_data := ast.node_data[root]
	r := root_data.scope
	children := ast.extra[r.start:][:r.len]
	for child in children {
		child_kind := ast.node_kinds[child]
		#partial switch child_kind {
		case .Pointing,
		     .PointingPull,
		     .EventPush,
		     .EventPull,
		     .ResonancePush,
		     .ResonancePull,
		     .ReactivePush,
		     .ReactivePull,
		     .Product,
		     .Expand,
		     .Constraint:
			walk(&a, a.scope, child)
		case:
			value := walk(&a, a.scope, child)
			append(&a.scope.names, "")
			append(&a.scope.types, nil)
			append(&a.scope.kind, Binding_Kind.Pointing_Push)
			append(&a.scope.values, value)
		}
	}

	cache.scope = a.scope
	cache.analyze_errors = a.errors
	cache.analyze_warnings = a.warnings

	if resolver.options.print_errors && len(a.errors) > 0 {
		debug_sem_errors(&a)
	}

	return len(a.errors) == 0
}

span_str :: proc(ast: ^Ast, s: Span) -> string {
	return ast.source[s.start:s.end]
}

node_pos :: proc(a: ^Analyzer, idx: Node_Index) -> Position {
	return span_to_position(a.ast, a.ast.node_spans[idx].start)
}

binding_kind_from_node :: proc(kind: Node_Kind) -> Binding_Kind {
	#partial switch kind {
	case .Pointing:
		return .Pointing_Push
	case .PointingPull:
		return .Pointing_Pull
	case .EventPush:
		return .Event_Push
	case .EventPull:
		return .Event_Pull
	case .ResonancePush:
		return .Resonance_Push
	case .ResonancePull:
		return .Resonance_Pull
	case .ReactivePush:
		return .Reactive_Push
	case .ReactivePull:
		return .Reactive_Pull
	case:
		return .Pointing_Push
	}
}

scope_resolve :: proc(scope: ^Scope_Type, name: string, ordinal: i16, last: bool) -> (^Type, ^Type) {
	if ordinal >= 0 {
		if name == "" {
			if int(ordinal) < len(scope.values) {
				return scope.values[int(ordinal)], scope.types[int(ordinal)]
			}
			return nil, nil
		}
		count := 0
		for i := 0; i < len(scope.names); i += 1 {
			if scope.names[i] == name {
				if count == int(ordinal) {
					return scope.values[i], scope.types[i]
				}
				count += 1
			}
		}
		return nil, nil
	}

	if last {
		for i := len(scope.names) - 1; i >= 0; i -= 1 {
			if scope.names[i] == name {
				return scope.values[i], scope.types[i]
			}
		}
	} else {
		for i := 0; i < len(scope.names); i += 1 {
			if scope.names[i] == name {
				return scope.values[i], scope.types[i]
			}
		}
	}

	if scope.parent != nil {
		return scope_resolve(scope.parent, name, ordinal, last)
	}
	return nil, nil
}

default_value :: proc(t: ^Type) -> ^Type {
	if t == nil do return t
	target := follow(t)
	cur := target
	for {
		#partial switch &v in cur^ {
		case Scope_Type:
			for i := 0; i < len(v.kind); i += 1 {
				if v.kind[i] == .Product {
					return v.values[i]
				}
			}
			return t
		case Carve_Type:
			if v.source != nil {
				cur = follow(v.source)
				continue
			}
		}
		break
	}
	return t
}

follow :: proc(t: ^Type) -> ^Type {
	if t == nil do return nil
	#partial switch v in t^ {
	case Mention_Type:
		return follow(v.target)
	case Reference_Type:
		return follow(v.reference.match)
	}
	return t
}

walk :: proc(a: ^Analyzer, current_scope: ^Scope_Type, idx: Node_Index) -> ^Type {
	if idx == INVALID_NODE {
		result := new(Type)
		result^ = None_Type{}
		return result
	}
	ast := a.ast
	kind := ast.node_kinds[idx]
	data := ast.node_data[idx]

	#partial switch kind {

	case .ScopeNode:
		scope := new(Scope_Type)
		scope.parent = current_scope
		r := data.scope
		children := ast.extra[r.start:][:r.len]
		for child in children {
			child_kind := ast.node_kinds[child]
			#partial switch child_kind {
			case .Pointing,
			     .PointingPull,
			     .EventPush,
			     .EventPull,
			     .ResonancePush,
			     .ResonancePull,
			     .ReactivePush,
			     .ReactivePull,
			     .Product,
			     .Expand,
			     .Constraint:
				walk(a, scope, child)
			case:
				value := walk(a, scope, child)
				append(&scope.names, "")
				append(&scope.types, nil)
				append(&scope.kind, Binding_Kind.Pointing_Push)
				append(&scope.values, value)
			}
		}
		result := new(Type)
		result^ = scope^
		return result

	case .Pointing,
	     .PointingPull,
	     .EventPush,
	     .EventPull,
	     .ResonancePush,
	     .ResonancePull,
	     .ReactivePush,
	     .ReactivePull:
		left_idx := data.binary.left
		right_idx := data.binary.right
		bk := binding_kind_from_node(kind)

		name := ""
		constraint: ^Type = nil
		left_kind := ast.node_kinds[left_idx]

		if left_kind == .Constraint {
			cdata := ast.node_data[left_idx]
			constraint_idx := cdata.binary.left
			name_idx := cdata.binary.right
			constraint = walk(a, current_scope, constraint_idx)
			if name_idx != INVALID_NODE {
				nk := ast.node_kinds[name_idx]
				if nk == .Identifier {
					name = span_str(ast, ast.node_data[name_idx].identifier.name)
				} else if nk == .Carve {
					// constraint:name{carves} — le carve source est le nom
					csrc := ast.node_data[name_idx].carve.source
					if ast.node_kinds[csrc] == .Identifier {
						name = span_str(ast, ast.node_data[csrc].identifier.name)
					}
				}
			}
		} else if left_kind == .Identifier {
			name = span_str(ast, ast.node_data[left_idx].identifier.name)
		} else {
			sem_error(a, "Invalid binding name", .Invalid_Binding_Name, node_pos(a, left_idx))
		}

		right_kind := ast.node_kinds[right_idx]
		if right_kind == .ScopeNode {
			result := new(Type)
			result^ = Scope_Type {
				parent = current_scope,
			}
			scope := &result.(Scope_Type)
			append(&current_scope.names, name)
			append(&current_scope.types, constraint)
			append(&current_scope.kind, bk)
			append(&current_scope.values, result)

			rdata := ast.node_data[right_idx]
			r := rdata.scope
			scope_children := ast.extra[r.start:][:r.len]
			for child in scope_children {
				child_kind := ast.node_kinds[child]
				#partial switch child_kind {
				case .Pointing,
				     .PointingPull,
				     .EventPush,
				     .EventPull,
				     .ResonancePush,
				     .ResonancePull,
				     .ReactivePush,
				     .ReactivePull,
				     .Product,
				     .Expand,
				     .Constraint:
					walk(a, scope, child)
				case:
					val := walk(a, scope, child)
					append(&scope.names, "")
					append(&scope.types, nil)
					append(&scope.kind, Binding_Kind.Pointing_Push)
					append(&scope.values, val)
				}
			}
			return result
		}
		value := walk(a, current_scope, right_idx)
		append(&current_scope.names, name)
		append(&current_scope.types, constraint)
		append(&current_scope.kind, bk)
		append(&current_scope.values, value)
		return value

	case .Product:
		value := walk(a, current_scope, data.unary.operand)
		append(&current_scope.names, "")
		append(&current_scope.types, nil)
		append(&current_scope.kind, Binding_Kind.Product)
		append(&current_scope.values, value)
		return value

	case .Expand:
		operand_idx := data.unary.operand
		constraint: ^Type = nil
		if ast.node_kinds[operand_idx] == .Constraint {
			cdata := ast.node_data[operand_idx]
			constraint = walk(a, current_scope, cdata.binary.left)
			value: ^Type = nil
			if cdata.binary.right != INVALID_NODE {
				value = walk(a, current_scope, cdata.binary.right)
			} else {
				value = default_value(constraint)
			}
			append(&current_scope.names, "")
			append(&current_scope.types, constraint)
			append(&current_scope.kind, Binding_Kind.Expand)
			append(&current_scope.values, value)
			return value
		}
		value := walk(a, current_scope, operand_idx)
		append(&current_scope.names, "")
		append(&current_scope.types, nil)
		append(&current_scope.kind, Binding_Kind.Expand)
		append(&current_scope.values, value)
		return value

	case .CompileTime:
		return walk(a, current_scope, data.unary.operand)

	case .Constraint:
		constraint := walk(a, current_scope, data.binary.left)
		value := default_value(constraint)
		name := ""
		if data.binary.right != INVALID_NODE {
			right_kind := ast.node_kinds[data.binary.right]
			if right_kind == .Identifier {
				name = span_str(ast, ast.node_data[data.binary.right].identifier.name)
			} else if right_kind == .Carve {
				csrc := ast.node_data[data.binary.right].carve.source
				if ast.node_kinds[csrc] == .Identifier {
					name = span_str(ast, ast.node_data[csrc].identifier.name)
				}
			}
		}
		append(&current_scope.names, name)
		append(&current_scope.types, constraint)
		append(&current_scope.kind, Binding_Kind.Pointing_Push)
		append(&current_scope.values, value)
		return value

	case .Property:
		target := walk(a, current_scope, data.binary.left)
		right_idx := data.binary.right
		prop_name := span_str(ast, ast.node_data[right_idx].identifier.name)
		prop_ordinal := ast.node_data[right_idx].identifier.ordinal

		resolved: ^Type = nil
		resolved_constraint: ^Type = nil
		resolved_target := follow(target)
		prop_target := resolved_target
		for {
			#partial switch &t in prop_target^ {
			case Scope_Type:
				resolved, resolved_constraint = scope_resolve(&t, prop_name, prop_ordinal, true)
			case Carve_Type:
				if t.source != nil {
					prop_target = follow(t.source)
					continue
				}
			}
			break
		}

		if resolved == nil {
			sem_error(
				a,
				fmt.tprintf("Cannot resolve property '%s'", prop_name),
				.Invalid_Property_Access,
				node_pos(a, right_idx),
			)
			result := new(Type)
			result^ = Invalid_Type{}
			return result
		}

		ref := new(Reference)
		ref^ = Reference {
			prop_name,
			prop_ordinal >= 0 ? Maybe(u64)(u64(prop_ordinal)) : nil,
			resolved_target,
			resolved_constraint,
		}
		result := new(Type)
		result^ = Reference_Type{target, ref}
		return result

	case .Enforce:
		left := walk(a, current_scope, data.binary.left)
		right := walk(a, current_scope, data.binary.right)
		result := new(Type)
		result^ = Sum_Type{left, right}
		return result

	case .Range:
		left := walk(a, current_scope, data.binary.left)
		right := walk(a, current_scope, data.binary.right)
		result := new(Type)
		result^ = Range_Type{left, right}
		return result

	case .Operator:
		left: ^Type = nil
		if data.operator.left != INVALID_NODE {
			left = walk(a, current_scope, data.operator.left)
		}
		right := walk(a, current_scope, data.operator.right)
		result := new(Type)
		#partial switch data.operator.kind {
		case .And:
			result^ = Product_Type{left, right}
		case .Or:
			result^ = Sum_Type{left, right}
		case .Not:
			result^ = Negate_Type{right}
		case:
			result^ = Compose_Type{left, right, data.operator.kind, nil}
			fold_compose(a, result, node_pos(a, idx))
		}
		return result

	case .Carve:
		source := walk(a, current_scope, data.carve.source)
		r := data.carve.children
		carve_children := ast.extra[r.start:][:r.len]

		src_scope: ^Scope_Type = nil
		resolved_source := follow(source)
		src_target := resolved_source
		for {
			#partial switch &s in src_target^ {
			case Scope_Type:
				src_scope = &s
			case Carve_Type:
				if s.source != nil {
					src_target = follow(s.source)
					continue
				}
			}
			break
		}

		refs := make([dynamic]Reference)
		vals := make([dynamic]^Type)

		positional_idx := 0
		for child in carve_children {
			child_kind := ast.node_kinds[child]
			child_data := ast.node_data[child]

			if child_kind == .Pointing || child_kind == .PointingPull {
				name_idx := child_data.binary.left
				val_idx := child_data.binary.right
				cname := ""
				cordinal: i16 = -1

				if ast.node_kinds[name_idx] == .Identifier {
					cname = span_str(ast, ast.node_data[name_idx].identifier.name)
					cordinal = ast.node_data[name_idx].identifier.ordinal
				}

				matched: ^Type = nil
				matched_constraint: ^Type = nil
				if src_scope != nil {
					matched, matched_constraint = scope_resolve(src_scope, cname, cordinal, false)
				}
				if matched == nil {
					sem_error(
						a,
						fmt.tprintf("Cannot resolve '%s' in carve target", cname),
						.Invalid_Carve,
						node_pos(a, name_idx),
					)
				}

				val := walk(a, current_scope, val_idx)
				append(
					&refs,
					Reference{cname, cordinal >= 0 ? Maybe(u64)(u64(cordinal)) : nil, matched, matched_constraint},
				)
				append(&vals, val)
			} else {
				matched: ^Type = nil
				matched_constraint: ^Type = nil
				cname := ""
				if src_scope != nil && positional_idx < len(src_scope.names) {
					cname = src_scope.names[positional_idx]
					matched = src_scope.values[positional_idx]
					matched_constraint = src_scope.types[positional_idx]
				}
				if matched == nil {
					sem_error(
						a,
						"Positional carve out of range",
						.Invalid_Carve,
						node_pos(a, child),
					)
				}

				val := walk(a, current_scope, child)
				append(&refs, Reference{nil, nil, matched, matched_constraint})
				append(&vals, val)
				positional_idx += 1
			}
		}

		result := new(Type)
		result^ = Carve_Type{source, refs, vals}
		return result

	case .Pattern:
		target := walk(a, current_scope, data.pattern.target)
		_ = target
		r := data.pattern.branches
		branches := ast.extra[r.start:][:r.len]
		for i := 0; i < len(branches); i += 2 {
			walk(a, current_scope, branches[i])
			if i + 1 < len(branches) {
				walk(a, current_scope, branches[i + 1])
			}
		}
		result := new(Type)
		result^ = Unknown_Type{}
		return result

	case .Execute:
		target := walk(a, current_scope, data.execute.target)
		result := new(Type)
		result^ = Execute_Type{target}
		return result

	case .External:
		result := new(Type)
		result^ = Unknown_Type{}
		return result

	case .Literal:
		return walk_literal(a, idx)

	case .Identifier:
		return walk_identifier(a, current_scope, idx)

	case .Branch:
		result := new(Type)
		result^ = Unknown_Type{}
		return result

	case .Unknown:
		result := new(Type)
		result^ = Unknown_Type{}
		return result
	}

	result := new(Type)
	result^ = Unknown_Type{}
	return result
}

walk_literal :: proc(a: ^Analyzer, idx: Node_Index) -> ^Type {
	ast := a.ast
	data := ast.node_data[idx]
	span := ast.node_spans[idx]
	text := ast.source[span.start:span.end]

	result := new(Type)

	switch data.literal.kind {
	case .Integer:
		val, ok := strconv.parse_u64_of_base(text, 10)
		if ok {
			segs := make([]Segment, 1)
			segs[0] = Segment{i64(val), i64(val)}
			result^ = Integer_Type{segs}
		} else {
			result^ = Invalid_Type{}
		}
	case .Hexadecimal:
		raw := len(text) > 2 ? text[2:] : text
		val, ok := strconv.parse_u64_of_base(raw, 16)
		if ok {
			segs := make([]Segment, 1)
			segs[0] = Segment{i64(val), i64(val)}
			result^ = Integer_Type{segs}
		} else {
			result^ = Invalid_Type{}
		}
	case .Binary:
		raw := len(text) > 2 ? text[2:] : text
		val, ok := strconv.parse_u64_of_base(raw, 2)
		if ok {
			segs := make([]Segment, 1)
			segs[0] = Segment{i64(val), i64(val)}
			result^ = Integer_Type{segs}
		} else {
			result^ = Invalid_Type{}
		}
	case .Float:
		val, ok := strconv.parse_f64(text)
		result^ = Float_Type{.none, ok ? val : nil}
	case .String:
		result^ = String_Type{text}
	case .Bool:
		result^ = Bool_Type{text == "true"}
	}

	return result
}

make_int_range :: proc(lo: Maybe(i64), hi: Maybe(i64)) -> Integer_Type {
	segs := make([]Segment, 1)
	segs[0] = Segment{lo, hi}
	return Integer_Type{segs}
}

make_int_const :: proc(val: i64) -> Integer_Type {
	return make_int_range(val, val)
}

resolve_builtin :: proc(name: string) -> ^Type {
	result := new(Type)
	switch name {
	case "u8":
		result^ = make_int_range(0, 255)
	case "i8":
		result^ = make_int_range(-128, 127)
	case "u16":
		result^ = make_int_range(0, 65535)
	case "i16":
		result^ = make_int_range(-32768, 32767)
	case "u32":
		result^ = make_int_range(0, 4294967295)
	case "i32":
		result^ = make_int_range(-2147483648, 2147483647)
	case "u64":
		result^ = make_int_range(0, 9223372036854775807)
	case "i64":
		result^ = make_int_range(-9223372036854775808, 9223372036854775807)
	case "f32":
		result^ = Float_Type{.f32, nil}
	case "f64":
		result^ = Float_Type{.f64, nil}
	case "Int":
		result^ = make_int_range(nil, nil)
	case "Float":
		result^ = Float_Type{.none, nil}
	case "String":
		result^ = String_Type{nil}
	case "Bool":
		result^ = Bool_Type{}
	case "None":
		result^ = None_Type{}
	case:
		free(result)
		return nil
	}
	return result
}

walk_identifier :: proc(a: ^Analyzer, scope: ^Scope_Type, idx: Node_Index) -> ^Type {
	ast := a.ast
	data := ast.node_data[idx]
	name := span_str(ast, data.identifier.name)
	ordinal := data.identifier.ordinal

	resolved, resolved_constraint := scope_resolve(scope, name, ordinal, true)
	if resolved != nil {
		if ordinal >= 0 {
			ref := new(Reference)
			ref^ = Reference {
				name != "" ? Maybe(string)(name) : nil,
				Maybe(u64)(u64(ordinal)),
				resolved,
				resolved_constraint,
			}
			result := new(Type)
			result^ = Reference_Type{nil, ref}
			return result
		}
		result := new(Type)
		result^ = Mention_Type{name, resolved, resolved_constraint}
		return result
	}

	if ordinal < 0 {
		builtin := resolve_builtin(name)
		if builtin != nil do return builtin
	}

	sem_error(
		a,
		fmt.tprintf("Undefined identifier '%s'", name),
		.Undefined_Identifier,
		node_pos(a, idx),
	)
	result := new(Type)
	result^ = Invalid_Type{}
	return result
}


fold_compose :: proc(a: ^Analyzer, t: ^Type, pos: Position) {
	if t == nil do return
	comp, ok := &t^.(Compose_Type)
	if !ok do return
	segs, segs_ok := fold_to_segments(t).([]Segment)
	if segs_ok {
		tf := new(Type)
		tf^ = Integer_Type{segs}
		comp.type_fold = tf
	} else {
		sem_error(a, "Cannot fold type: operands must be integers", .Invalid_operator, pos)
	}
}

validate_type :: proc(type: ^Type) {
	if (type == nil) {
		return
	}
	switch t in type {
	case Sum_Type:
		validate_type(t.left)
		validate_type(t.right)
	case Product_Type:
		validate_type(t.left)
		validate_type(t.right)
	case Negate_Type:
		validate_type(t.operand)
	case Compose_Type:
		check_operator_compat(t.left, t.right, t.operator)
	case Scope_Type:
		for i := 0; i < len(t.types); i += 1 {
			compare_types(t.types[i], t.values[i])
		}
	case String_Type:
	case Integer_Type:
	case Float_Type:
	case Execute_Type:
		validate_type(t.target)
	case Range_Type:
	case Bool_Type:
	case None_Type:
	case Invalid_Type:
	case Unknown_Type:
	case Mention_Type:
	case Reference_Type:
	case Carve_Type:
	}
}

check_carve_possible :: proc(target: ^Type, reference: ^Reference) {}
check_range_compat :: proc(left: ^Type, right: ^Type, operator: Operator_Kind) {}
check_operator_compat :: proc(left: ^Type, right: ^Type, operator: Operator_Kind) {}
compare_types :: proc(constraint: ^Type, concrete: ^Type) {}

/* ======================================================================
 * SECTION 17: ERROR REPORTING
 * ====================================================================== */

sem_error :: proc(
	s: ^Analyzer,
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
	s: ^Analyzer,
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

debug_sem_errors :: proc(s: ^Analyzer) {
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
