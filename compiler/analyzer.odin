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

Scope_Type :: struct {
	names:  [dynamic]string,
	types:  [dynamic]Type,
	kind:   [dynamic]Binding_Kind,
	values: [dynamic]Type,
}

Execute_Type :: struct {
	target: ^Type,
}

Carve_Type :: struct {
	target: ^Scope_Type,
}

Integer_Type :: struct {
	kind:        IntegerKind,
	value:       Maybe(Integer_Data),
	strict_type: ^Type,
}

Integer_Data :: struct {
	value:    u64,
	negative: bool,
}

Float_Type :: struct {
	kind:        FloatKind,
	value:       Maybe(f64),
	strict_type: ^Type,
}

Compose_Type :: struct {
	left:     ^Type,
	right:    ^Type,
	operator: Operator_Kind,
}

Range_Type :: struct {
	left:  ^Type,
	right: ^Type,
}

Bool_Type :: struct {
	value: bool,
}

String_Type :: struct {
	value:       Maybe(string),
	strict_type: ^Type,
}

None_Type :: struct {}

Type :: union {
	Sum_Type,
	Product_Type,
	Compose_Type,
	String_Type,
	Scope_Type,
	Integer_Type,
	Float_Type,
	Bool_Type,
	None_Type,
}

Analyzer :: struct {
	ast:      ^Ast,
	errors:   [dynamic]Analyzer_Error,
	warnings: [dynamic]Analyzer_Error,
}

/* ======================================================================
 * SECTION 3: ANALYZER CORE
 * ====================================================================== */
analyze :: proc(cache: ^Cache, ast: ^Ast) -> bool {
	a := Analyzer {
		ast      = ast,
		errors   = make([dynamic]Analyzer_Error, 0),
		warnings = make([dynamic]Analyzer_Error, 0),
	}

	root := ast_root(ast)
	walk(&a, root)

	cache.analyze_errors = a.errors[:]
	cache.analyze_warnings = a.warnings[:]

	if resolver.options.print_errors && len(a.errors) > 0 {
		debug_sem_errors(&a)
	}

	return len(a.errors) == 0
}

walk :: proc(a: ^Analyzer, idx: Node_Index) {
	ast := a.ast
	kind := ast.node_kinds[idx]
	data := ast.node_data[idx]

	switch kind {

	case .ScopeNode:
		r := data.scope
		children := ast.extra[r.start:][:r.len]

		for child in children {
			walk(a, child)
		}

	case .Pointing:
		walk(a, data.binary.left)
		walk(a, data.binary.right)

	case .PointingPull:
		walk(a, data.binary.left)
		walk(a, data.binary.right)

	case .EventPush:
		walk(a, data.binary.left)
		walk(a, data.binary.right)

	case .EventPull:
		walk(a, data.event_pull.from)
		walk(a, data.event_pull.to)

	case .ResonancePush:
		walk(a, data.binary.left)
		walk(a, data.binary.right)

	case .ResonancePull:
		walk(a, data.binary.left)
		walk(a, data.binary.right)

	case .ReactivePush:
		walk(a, data.binary.left)
		walk(a, data.binary.right)

	case .ReactivePull:
		walk(a, data.binary.left)
		walk(a, data.binary.right)

	case .Product:
		walk(a, data.unary.operand)

	case .Expand:
		walk(a, data.unary.operand)

	case .CompileTime:
		walk(a, data.unary.operand)

	case .Constraint:
		walk(a, data.binary.left)
		walk(a, data.binary.right)

	case .Property:
		walk(a, data.binary.left)
		walk(a, data.binary.right)

	case .Enforce:
		walk(a, data.binary.left)
		walk(a, data.binary.right)

	case .Range:
		walk(a, data.binary.left)
		walk(a, data.binary.right)

	case .Operator:
		walk(a, data.operator.left)
		walk(a, data.operator.right)

	case .Carve:
		walk(a, data.carve.source)
		r := data.carve.children
		carve_children := ast.extra[r.start:][:r.len]
		for child in carve_children {
			walk(a, child)
		}

	case .Pattern:
		walk(a, data.pattern.target)
		r := data.pattern.branches
		branches := ast.extra[r.start:][:r.len]
		for i := 0; i < len(branches); i += 2 {
			walk(a, branches[i])
			if i + 1 < len(branches) {
				walk(a, branches[i + 1])
			}
		}

	case .Execute:
		walk(a, data.execute.target)

	case .External:
		walk(a, data.external.scope)

	case .Literal:
	// feuille

	case .Identifier:
	// feuille

	case .Branch:
	// pas utilisé directement, inline dans Pattern

	case .Unknown:

	}
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

/* ======================================================================
 * SECTION 9: LITERAL EVALUATION
 * ====================================================================== */

sem_anotate_literal :: proc(s: ^Analyzer, idx: Node_Index) -> Binding_Value {
	ast := s.ast
	lit_kind := ast.node_data[idx].literal.kind

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

sem_value_str :: proc(s: ^Analyzer, sv: Binding_Value) -> string {
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
