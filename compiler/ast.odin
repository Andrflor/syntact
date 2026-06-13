package compiler

import "core:fmt"
import "core:strings"

// AST data model for Syntact — node tags, payload unions, the flat SOA `Ast`
// container, span/position mapping, and the `node_*` accessors + `print_ast`. The
// lexer and parser that build this AST live in parse.odin.

Span :: struct {
	start: u32,
	end:   u32,
}

EMPTY_SPAN :: Span{0, 0}

Node_Index :: distinct u32
INVALID_NODE :: Node_Index(0xFFFFFFFF) // absent child / no node

Node_Kind :: enum u8 {
	Pointing,
	PointingPull,
	EventPush,
	EventPull,
	ResonancePush,
	ResonancePull,
	ReactivePush,
	ReactivePull,
	ScopeNode,
	Carve,
	Product,
	Branch,
	Identifier,
	Pattern,
	Constraint,
	Operator,
	Execute,
	CompileTime,
	Literal,
	Property,
	Expand,
	External,
	Range,
	Enforce,
	Unknown,
}

Literal_Kind :: enum u8 {
	Integer,
	Float,
	String,
	Bool,
	Hexadecimal,
	Binary,
}

Operator_Kind :: enum u8 {
	Add,
	Subtract,
	Multiply,
	Divide,
	Mod,
	Equal,
	Less,
	Greater,
	NotEqual,
	LessEqual,
	GreaterEqual,
	And,
	Or,
	Xor,
	Not,
	BitAnd,
	BitOr,
	BitNot,
	RShift,
	LShift,
	Cast, // `::` — raw reinterpret-cast of `left` into `right`'s layout
}

ExecutionWrapper :: enum u8 {
	Threading,
	Parallel_CPU,
	Background,
	GPU,
}

// A slice of the shared `extra` array for variable-arity children, so the
// fixed-size node need not grow.
Index_Range :: struct {
	start: u32,
	len:   u32,
}

EMPTY_RANGE :: Index_Range{0, 0}

// Two-child node (binding sides, property, range bounds). Either side may be
// INVALID_NODE for half-open forms (`->v`, `.b`, `lo..`).
Binary_Data :: struct {
	left:  Node_Index,
	right: Node_Index,
}

// One-child node (product, expand, compile-time, unary operators).
Unary_Data :: struct {
	operand: Node_Index,
}

String_Quotation :: enum u8 {
	simple, // '…'  — char/ordinal depending on length
	double, // "…"  — positional string, escapes interpreted
	backtick, // `…`  — raw positional string, no escaping
}

Literal_Data :: struct {
	kind:      Literal_Kind,
	quotation: String_Quotation, // only meaningful when kind == .String
}

// An identifier reference. `ordinal` < 0 means no `#n` suffix; `capture` is the
// optional `(…)` capture span.
Identifier_Data :: struct {
	name:    Span,
	capture: Span,
	ordinal: i16,
}

// A scope literal `{ … }` — children are an Index_Range into `extra`.
Scope_Data :: struct {
	using _: Index_Range,
}

// `source{ … }` — `source` carved, `children` the overrides.
Carve_Data :: struct {
	source:   Node_Index,
	children: Index_Range,
}

// `target ? { … }` — `branches` stores (condition, result) as consecutive pairs:
// branch k at extra[start + 2k] / extra[start + 2k + 1].
Pattern_Data :: struct {
	target:   Node_Index,
	branches: Index_Range,
}

// `target!` — `wrappers` are the optional execution-context wrappers.
Execute_Data :: struct {
	target:   Node_Index,
	wrappers: Index_Range,
}

// An operator application. Unary operators leave `left` == INVALID_NODE.
Operator_Node_Data :: struct {
	kind:  Operator_Kind,
	left:  Node_Index,
	right: Node_Index,
}

External_Data :: struct {
	name:  Span,
	scope: Node_Index,
}

EventPull_Data :: struct {
	from:       Node_Index,
	to:         Node_Index,
	catch_span: Span,
}

// The payload for one node. A raw union with no tag of its own — `node_kinds[i]`
// is the discriminant. Sized to the largest variant to keep `node_data` flat.
Node_Data :: struct #raw_union {
	binary:     Binary_Data,
	unary:      Unary_Data,
	literal:    Literal_Data,
	identifier: Identifier_Data,
	scope:      Scope_Data,
	carve:      Carve_Data,
	pattern:    Pattern_Data,
	execute:    Execute_Data,
	operator:   Operator_Node_Data,
	external:   External_Data,
	event_pull: EventPull_Data,
}

// The parsed program. The first four arrays are the SOA node store (by Node_Index);
// `extra`/`extra_u8` hold variable-arity children. `line_starts` is lazily built on
// first position query (ensure_line_starts).
Ast :: struct {
	source:               string,
	node_kinds:           []Node_Kind,
	node_spans:           []Span,
	node_data:            []Node_Data,
	extra:                []Node_Index,
	extra_u8:             []u8,
	line_starts:          [dynamic]u32,
	line_starts_computed: bool,
}

Position :: struct {
	line:   int,
	column: int,
	offset: int,
}

// Builds and memoizes the line-start table on demand (only when a position is queried).
ensure_line_starts :: #force_inline proc(ast: ^Ast) {
	if ast.line_starts_computed do return
	ast.line_starts_computed = true
	if ast.line_starts == nil {
		ast.line_starts = make([dynamic]u32, 0, 64)
	}
	append(&ast.line_starts, 0)
	for i := 0; i < len(ast.source); i += 1 {
		if ast.source[i] == '\n' {
			append(&ast.line_starts, u32(i + 1))
		}
	}
}

// Maps a byte offset to (line, column) by binary-searching for the greatest
// line-start ≤ offset. The `+1` in the midpoint biases upward to avoid oscillating.
span_to_position :: #force_inline proc(ast: ^Ast, offset: u32) -> Position {
	ensure_line_starts(ast)
	lo, hi := 0, len(ast.line_starts) - 1
	for lo < hi {
		mid := (lo + hi + 1) / 2
		if ast.line_starts[mid] <= offset {
			lo = mid
		} else {
			hi = mid - 1
		}
	}
	return Position {
		line = lo + 1,
		column = int(offset) - int(ast.line_starts[lo]) + 1,
		offset = int(offset),
	}
}

// --- AST accessors and debug output ---
//
// The node_* helpers hide the raw-union field selection and resolve Index_Ranges
// into `extra` slices, so callers never index the union directly.

node_text :: proc(ast: ^Ast, idx: Node_Index) -> string {
	s := ast.node_spans[idx]
	return ast.source[s.start:s.end]
}

node_name_str :: proc(ast: ^Ast, idx: Node_Index) -> string {
	s := ast.node_data[idx].identifier.name
	return ast.source[s.start:s.end]
}

node_capture_str :: proc(ast: ^Ast, idx: Node_Index) -> string {
	s := ast.node_data[idx].identifier.capture
	if s == EMPTY_SPAN do return ""
	return ast.source[s.start:s.end]
}

node_children :: proc(ast: ^Ast, idx: Node_Index) -> []Node_Index {
	r := ast.node_data[idx].scope
	return ast.extra[r.start:][:r.len]
}

node_carve_children :: proc(ast: ^Ast, idx: Node_Index) -> []Node_Index {
	r := ast.node_data[idx].carve.children
	return ast.extra[r.start:][:r.len]
}

node_pattern_branches :: proc(ast: ^Ast, idx: Node_Index) -> []Node_Index {
	r := ast.node_data[idx].pattern.branches
	return ast.extra[r.start:][:r.len]
}

node_execute_wrappers :: proc(ast: ^Ast, idx: Node_Index) -> []u8 {
	r := ast.node_data[idx].execute.wrappers
	return ast.extra_u8[r.start:][:r.len]
}

node_event_pull_catch :: proc(ast: ^Ast, idx: Node_Index) -> string {
	s := ast.node_data[idx].event_pull.catch_span
	if s == EMPTY_SPAN do return ""
	return ast.source[s.start:s.end]
}

print_ast :: proc(ast: ^Ast, idx: Node_Index, indent: int) {
	if idx == INVALID_NODE do return

	indent_str := strings.repeat(" ", indent)
	n_kind := ast.node_kinds[idx]
	n_span := ast.node_spans[idx]
	n_data := ast.node_data[idx]
	pos := span_to_position(ast, n_span.start)

	switch n_kind {
	case .Pointing:
		fmt.printf("%sPointing -> (line %d, column %d)\n", indent_str, pos.line, pos.column)
		if n_data.binary.left != INVALID_NODE {
			fmt.printf("%s  From:\n", indent_str)
			print_ast(ast, n_data.binary.left, indent + 4)
		}
		if n_data.binary.right != INVALID_NODE {
			fmt.printf("%s  To:\n", indent_str)
			print_ast(ast, n_data.binary.right, indent + 4)
		}
	case .PointingPull:
		fmt.printf("%sPointingPull <- (line %d, column %d)\n", indent_str, pos.line, pos.column)
		if n_data.binary.left != INVALID_NODE {
			fmt.printf("%s  From:\n", indent_str)
			print_ast(ast, n_data.binary.left, indent + 4)
		} else {
			fmt.printf("%s  From: anonymous\n", indent_str)
		}
		if n_data.binary.right != INVALID_NODE {
			fmt.printf("%s  To:\n", indent_str)
			print_ast(ast, n_data.binary.right, indent + 4)
		}
	case .EventPush:
		fmt.printf("%sEventPush >- (line %d, column %d)\n", indent_str, pos.line, pos.column)
		if n_data.binary.left != INVALID_NODE {
			fmt.printf("%s  From:\n", indent_str)
			print_ast(ast, n_data.binary.left, indent + 4)
		} else {
			fmt.printf("%s  From: anonymous\n", indent_str)
		}
		if n_data.binary.right != INVALID_NODE {
			fmt.printf("%s  To:\n", indent_str)
			print_ast(ast, n_data.binary.right, indent + 4)
		}
	case .EventPull:
		fmt.printf("%sEventPull -< (line %d, column %d)\n", indent_str, pos.line, pos.column)
		catch_str := node_event_pull_catch(ast, idx)
		if catch_str != "" {
			fmt.printfln("%s  Catch: %s", indent_str, catch_str)
		}
		if n_data.event_pull.from != INVALID_NODE {
			fmt.printf("%s  From:\n", indent_str)
			print_ast(ast, n_data.event_pull.from, indent + 4)
		} else {
			fmt.printf("%s  From: anonymous\n", indent_str)
		}
		if n_data.event_pull.to != INVALID_NODE {
			fmt.printf("%s  To:\n", indent_str)
			print_ast(ast, n_data.event_pull.to, indent + 4)
		}
	case .ResonancePush:
		fmt.printf("%sResonancePush >>- (line %d, column %d)\n", indent_str, pos.line, pos.column)
		if n_data.binary.left != INVALID_NODE {
			fmt.printf("%s  From:\n", indent_str)
			print_ast(ast, n_data.binary.left, indent + 4)
		} else {
			fmt.printf("%s  From: anonymous\n", indent_str)
		}
		if n_data.binary.right != INVALID_NODE {
			fmt.printf("%s  To:\n", indent_str)
			print_ast(ast, n_data.binary.right, indent + 4)
		}
	case .ResonancePull:
		fmt.printf("%sResonancePull -<< (line %d, column %d)\n", indent_str, pos.line, pos.column)
		if n_data.binary.left != INVALID_NODE {
			fmt.printf("%s  From:\n", indent_str)
			print_ast(ast, n_data.binary.left, indent + 4)
		} else {
			fmt.printf("%s  From: anonymous\n", indent_str)
		}
		if n_data.binary.right != INVALID_NODE {
			fmt.printf("%s  To:\n", indent_str)
			print_ast(ast, n_data.binary.right, indent + 4)
		}
	case .ReactivePush:
		fmt.printf("%sReactivePush >>= (line %d, column %d)\n", indent_str, pos.line, pos.column)
		if n_data.binary.left != INVALID_NODE {
			fmt.printf("%s  From:\n", indent_str)
			print_ast(ast, n_data.binary.left, indent + 4)
		} else {
			fmt.printf("%s  From: anonymous\n", indent_str)
		}
		if n_data.binary.right != INVALID_NODE {
			fmt.printf("%s  To:\n", indent_str)
			print_ast(ast, n_data.binary.right, indent + 4)
		}
	case .ReactivePull:
		fmt.printf("%sReactivePull =<< (line %d, column %d)\n", indent_str, pos.line, pos.column)
		if n_data.binary.left != INVALID_NODE {
			fmt.printf("%s  From:\n", indent_str)
			print_ast(ast, n_data.binary.left, indent + 4)
		} else {
			fmt.printf("%s  From: anonymous\n", indent_str)
		}
		if n_data.binary.right != INVALID_NODE {
			fmt.printf("%s  To:\n", indent_str)
			print_ast(ast, n_data.binary.right, indent + 4)
		}
	case .Identifier:
		name := node_name_str(ast, idx)
		capture := node_capture_str(ast, idx)
		if capture != "" {
			fmt.printf(
				"%sIdentifier: %s(%s) (line %d, column %d)\n",
				indent_str,
				name,
				capture,
				pos.line,
				pos.column,
			)
		} else {
			fmt.printf(
				"%sIdentifier: %s (line %d, column %d)\n",
				indent_str,
				name,
				pos.line,
				pos.column,
			)
		}
	case .ScopeNode:
		fmt.printf("%sScopeNode (line %d, column %d)\n", indent_str, pos.line, pos.column)
		for child in node_children(ast, idx) {
			print_ast(ast, child, indent + 2)
		}
	case .Carve:
		fmt.printf("%sCarve (line %d, column %d)\n", indent_str, pos.line, pos.column)
		if n_data.carve.source != INVALID_NODE {
			fmt.printf("%s  Source:\n", indent_str)
			print_ast(ast, n_data.carve.source, indent + 4)
			fmt.printf("%s  Carves:\n", indent_str)
			for child in node_carve_children(ast, idx) {
				print_ast(ast, child, indent + 4)
			}
		}
	case .Property:
		fmt.printf("%sProperty (line %d, column %d)\n", indent_str, pos.line, pos.column)
		if n_data.binary.left != INVALID_NODE {
			fmt.printf("%s  Source:\n", indent_str)
			print_ast(ast, n_data.binary.left, indent + 4)
		}
		if n_data.binary.right != INVALID_NODE {
			fmt.printf("%s  Property:\n", indent_str)
			print_ast(ast, n_data.binary.right, indent + 4)
		}
	case .Expand:
		fmt.printf("%sExpand (line %d, column %d)\n", indent_str, pos.line, pos.column)
		if n_data.unary.operand != INVALID_NODE {
			fmt.printf("%s  Target:\n", indent_str)
			print_ast(ast, n_data.unary.operand, indent + 4)
		}
	case .External:
		fmt.printf("%sExternal (line %d, column %d)\n", indent_str, pos.line, pos.column)
		if n_data.external.scope != INVALID_NODE {
			fmt.printf("%s  Target:\n", indent_str)
			print_ast(ast, n_data.external.scope, indent + 4)
		}
	case .Product:
		fmt.printf("%sProduct -> (line %d, column %d)\n", indent_str, pos.line, pos.column)
		if n_data.unary.operand != INVALID_NODE {
			print_ast(ast, n_data.unary.operand, indent + 2)
		}
	case .Pattern:
		fmt.printf("%sPattern ? (line %d, column %d)\n", indent_str, pos.line, pos.column)
		if n_data.pattern.target != INVALID_NODE {
			fmt.printf("%s  Target:\n", indent_str)
			print_ast(ast, n_data.pattern.target, indent + 4)
		} else {
			fmt.printf("%s  Target: implicit\n", indent_str)
		}
		fmt.printf("%s  Branches\n", indent_str)
		branches := node_pattern_branches(ast, idx)
		for i := 0; i < len(branches); i += 2 {
			source := branches[i]
			product := INVALID_NODE
			if i + 1 < len(branches) do product = branches[i + 1]
			if source != INVALID_NODE {
				fmt.printf("%s      Pattern:\n", indent_str)
				print_ast(ast, source, indent + 8)
			}
			if product != INVALID_NODE {
				fmt.printf("%s      Match:\n", indent_str)
				print_ast(ast, product, indent + 8)
			}
		}
	case .Constraint:
		fmt.printf("%sConstraint: (line %d, column %d)\n", indent_str, pos.line, pos.column)
		if n_data.binary.left != INVALID_NODE {
			print_ast(ast, n_data.binary.left, indent + 2)
		}
		if n_data.binary.right != INVALID_NODE {
			fmt.printf("%s  To:\n", indent_str)
			print_ast(ast, n_data.binary.right, indent + 4)
		} else {
			fmt.printf("%s  To: none\n", indent_str)
		}
	case .Operator:
		fmt.printf(
			"%sOperator '%v' (line %d, column %d)\n",
			indent_str,
			n_data.operator.kind,
			pos.line,
			pos.column,
		)
		if n_data.operator.left != INVALID_NODE {
			fmt.printf("%s  Left:\n", indent_str)
			print_ast(ast, n_data.operator.left, indent + 4)
		} else {
			fmt.printf("%s  Left: none (unary operator)\n", indent_str)
		}
		if n_data.operator.right != INVALID_NODE {
			fmt.printf("%s  Right:\n", indent_str)
			print_ast(ast, n_data.operator.right, indent + 4)
		}
	case .Enforce:
		fmt.printf("%sEnforce ?! (line %d, column %d)\n", indent_str, pos.line, pos.column)
		if n_data.binary.left != INVALID_NODE {
			fmt.printf("%s  Left:\n", indent_str)
			print_ast(ast, n_data.binary.left, indent + 4)
		} else {
			fmt.printf("%s  Left: none (unary operator)\n", indent_str)
		}
		if n_data.binary.right != INVALID_NODE {
			fmt.printf("%s  Right:\n", indent_str)
			print_ast(ast, n_data.binary.right, indent + 4)
		}
	case .Branch:
	case .Execute:
		wrappers := node_execute_wrappers(ast, idx)
		pattern := ""
		for w in wrappers {
			switch ExecutionWrapper(w) {
			case .Threading:
				pattern = strings.concatenate({pattern, "<"})
			case .Parallel_CPU:
				pattern = strings.concatenate({pattern, "["})
			case .Background:
				pattern = strings.concatenate({pattern, "("})
			case .GPU:
				pattern = strings.concatenate({pattern, "|"})
			}
		}
		pattern = strings.concatenate({pattern, "!"})
		for i := len(wrappers) - 1; i >= 0; i -= 1 {
			switch ExecutionWrapper(wrappers[i]) {
			case .Threading:
				pattern = strings.concatenate({pattern, ">"})
			case .Parallel_CPU:
				pattern = strings.concatenate({pattern, "]"})
			case .Background:
				pattern = strings.concatenate({pattern, ")"})
			case .GPU:
				pattern = strings.concatenate({pattern, "|"})
			}
		}
		fmt.printf(
			"%sExecute %s (line %d, column %d)\n",
			indent_str,
			pattern,
			pos.line,
			pos.column,
		)
		if n_data.execute.target != INVALID_NODE {
			print_ast(ast, n_data.execute.target, indent + 2)
		}
	case .CompileTime:
		fmt.printf("%sCompileTime ! (line %d, column %d)\n", indent_str, pos.line, pos.column)
		if n_data.unary.operand != INVALID_NODE {
			print_ast(ast, n_data.unary.operand, indent + 2)
		}
	case .Literal:
		fmt.printf(
			"%sLiteral (%v): %s (line %d, column %d)\n",
			indent_str,
			n_data.literal.kind,
			node_text(ast, idx),
			pos.line,
			pos.column,
		)
	case .Range:
		fmt.printf("%sRange (line %d, column %d)\n", indent_str, pos.line, pos.column)
		if n_data.binary.left != INVALID_NODE {
			fmt.printf("%s  Start:\n", indent_str)
			print_ast(ast, n_data.binary.left, indent + 4)
		} else {
			fmt.printf("%s  Start: none (prefix range)\n", indent_str)
		}
		if n_data.binary.right != INVALID_NODE {
			fmt.printf("%s  End:\n", indent_str)
			print_ast(ast, n_data.binary.right, indent + 4)
		} else {
			fmt.printf("%s  End: none (postfix range)\n", indent_str)
		}
	case .Unknown:
		fmt.printf("%sUnknown\n", indent_str)
	}
}

// The root ScopeNode is always the last node added (parse() appends the wrapping
// scope last).
ast_root :: #force_inline proc(ast: ^Ast) -> Node_Index {
	return Node_Index(len(ast.node_kinds) - 1)
}
