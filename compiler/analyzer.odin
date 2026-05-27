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
	parent: ^Scope_Type,
	names:  [dynamic]string,
	types:  [dynamic]Type,
	kind:   [dynamic]Binding_Kind,
	values: [dynamic]Type,
}

Execute_Type :: struct {
	target: ^Type,
}

Carve_Type :: struct {
	target:     ^Scope_Type,
	references: [dynamic]Reference,
	values:     [dynamic]Type,
}

Reference :: struct {
	name:  Maybe(string),
	index: Maybe(u64),
}

Reference_Type :: struct {
	target:    ^Type,
	reference: ^Reference,
}

Mention_Type :: struct {
	target: ^Type,
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

Unknown_Type :: struct {}

Invalid_Type :: struct {}

Type :: union {
	Sum_Type,
	Product_Type,
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

walk :: proc(a: ^Analyzer, current_scope: ^Scope_Type, idx: Node_Index) -> Type {
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

	case .Pointing ||
	     .PointingPull ||
	     .EventPush ||
	     .EventPull ||
	     .ResonancePush ||
	     .ResonancePull ||
	     .ReactivePush ||
	     .ReactivePull:
		left := data.binary.left
		switch left {
		case .Constraint:
		case .Identifier:
		case:
			sem_error(
				a,
				"Error baby",
				U,
				// GEt position baby,
			)
		}
		right := data.binary.right

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
