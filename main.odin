package compiler

import "core:fmt"
import "core:os"

// === TOKEN ENUM ===
Token_Kind :: enum {
	Invalid,
	EOF,
	Identifier,

	// Numbers
	Integer,
	Float,
	Hexadecimal,
	Binary,

	// String Literal
	String_Literal,

	// Executors
	Execute, // !
	At,

	// Assignators
	PointingPush, // ->
	PointingPull, // <-
	EventPush, // >-
	EventPull, // -<
	ResonancePush, // >>-
	ResonancePull, // -<<

	// Comparisons
	Equal, // =
	LessThan, // <
	GreaterThan, // >
	LessEqual, // <=
	GreaterEqual, // >=

	// Separators
	Colon, // :
	Question, // ?
	Dot, // .
	DoubleDot, // ..
	Ellipsis, // ...
	Newline, // \n
	Range, // 1..2 (full range)
	PrefixRange, // ..1
	PostfixRange, // 1..

	// Grouping
	LeftBrace, // {
	RightBrace, // }
	LeftParen, // (
	RightParen, // )

	// Math & Logic
	Plus, // +
	Minus, // -
	Asterisk, // *
	Slash, // /
	Percent, // %
	BitAnd, // &
	BitOr, // |
	BitXor, // ^
	BitNot, // ~
}

Token :: struct {
	kind: Token_Kind,
	text: string,
	pos:  int,
}

Lexer :: struct {
	source: string,
	pos:    int,
}


Parser :: struct {
	lexer:   ^Lexer,
	current: Token,
}

// === PARSING FUNCTIONS ===
parse_next :: proc(p: ^Parser) {
	p.current = next_token(p.lexer)
}


// === LEXER FUNCTION ===
next_token :: proc(l: ^Lexer) -> Token {
	skip_whitespace(l)

	if l.pos >= len(l.source) {
		return Token{kind = .EOF, pos = l.pos}
	}

	start := l.pos
	c := l.source[l.pos]

	switch c {
	case '\n':
		l.pos += 1
		for l.pos < len(l.source) && l.source[l.pos] == '\n' {
			l.pos += 1
		}
		return Token{kind = .Newline, text = "\\n", pos = start}

	case '`':
		// Backtick string literal
		l.pos += 1
		start = l.pos
		for l.pos < len(l.source) && l.source[l.pos] != '`' {
			l.pos += 1
		}
		if l.pos < len(l.source) {
			text := l.source[start:l.pos]
			l.pos += 1 // Skip closing backtick
			return Token{kind = .String_Literal, text = text, pos = start}
		}
		return Token{kind = .Invalid, text = "Unterminated string", pos = start}

	case '@':
		l.pos += 1;return Token{kind = .At, text = "@", pos = start}
	case '{':
		l.pos += 1;return Token{kind = .LeftBrace, text = "{", pos = start}
	case '}':
		l.pos += 1;return Token{kind = .RightBrace, text = "}", pos = start}
	case '(':
		l.pos += 1;return Token{kind = .LeftParen, text = "(", pos = start}
	case ')':
		l.pos += 1;return Token{kind = .RightParen, text = ")", pos = start}
	case '!':
		l.pos += 1;return Token{kind = .Execute, text = "!", pos = start}
	case ':':
		l.pos += 1;return Token{kind = .Colon, text = ":", pos = start}
	case '?':
		l.pos += 1;return Token{kind = .Question, text = "?", pos = start}

	case '.':
		// Check for ranges
		if l.pos + 1 < len(l.source) && l.source[l.pos + 1] == '.' {
			l.pos += 2 // Skip ".."

			// Check for ellipsis "..."
			if l.pos < len(l.source) && l.source[l.pos] == '.' {
				l.pos += 1
				return Token{kind = .Ellipsis, text = "...", pos = start}
			}

			// Check for prefix range "..1"
			if l.pos < len(l.source) && is_digit(l.source[l.pos]) {
				start_num := l.pos
				for l.pos < len(l.source) && is_digit(l.source[l.pos]) {
					l.pos += 1
				}
				return Token{kind = .PrefixRange, text = l.source[start:l.pos], pos = start}
			}

			return Token{kind = .DoubleDot, text = "..", pos = start}
		}

		l.pos += 1
		return Token{kind = .Dot, text = ".", pos = start}

	case '=':
		l.pos += 1
		if l.pos < len(l.source) && l.source[l.pos] == '=' {
			l.pos += 1
			return Token{kind = .Equal, text = "==", pos = start}
		}
		return Token{kind = .Equal, text = "=", pos = start}

	case '<':
		l.pos += 1
		if l.pos < len(l.source) {
			if l.source[l.pos] == '=' {
				l.pos += 1
				return Token{kind = .LessEqual, text = "<=", pos = start}
			} else if l.source[l.pos] == '-' {
				l.pos += 1
				return Token{kind = .PointingPull, text = "<-", pos = start}
			}
		}
		return Token{kind = .LessThan, text = "<", pos = start}

	case '>':
		l.pos += 1
		if l.pos < len(l.source) {
			if l.source[l.pos] == '=' {
				l.pos += 1
				return Token{kind = .GreaterEqual, text = ">=", pos = start}
			} else if l.source[l.pos] == '-' {
				l.pos += 1
				return Token{kind = .EventPush, text = ">-", pos = start}
			} else if l.pos + 1 < len(l.source) &&
			   l.source[l.pos] == '>' &&
			   l.source[l.pos + 1] == '-' {
				l.pos += 2
				return Token{kind = .ResonancePush, text = ">>-", pos = start}
			}
		}
		return Token{kind = .GreaterThan, text = ">", pos = start}

	case '-':
		l.pos += 1
		if l.pos < len(l.source) {
			if l.source[l.pos] == '>' {
				l.pos += 1
				return Token{kind = .PointingPush, text = "->", pos = start}
			} else if l.source[l.pos] == '<' {
				l.pos += 1
				if l.pos < len(l.source) && l.source[l.pos] == '<' {
					l.pos += 1
					return Token{kind = .ResonancePull, text = "-<<", pos = start}
				}
				return Token{kind = .EventPull, text = "-<", pos = start}
			}
		}
		return Token{kind = .Minus, text = "-", pos = start}

	case '/':
		// Single line comment
		if l.pos + 1 < len(l.source) && l.source[l.pos + 1] == '/' {
			l.pos += 2
			for l.pos < len(l.source) && l.source[l.pos] != '\n' {
				l.pos += 1
			}
			return next_token(l)
		}

		// Multi line comment
		if l.pos + 1 < len(l.source) && l.source[l.pos + 1] == '*' {
			l.pos += 2
			for l.pos + 1 < len(l.source) &&
			    !(l.source[l.pos] == '*' && l.source[l.pos + 1] == '/') {
				l.pos += 1
			}
			if l.pos + 1 < len(l.source) {
				l.pos += 2 // Skip */
			}
			return next_token(l)
		}

		l.pos += 1
		return Token{kind = .Slash, text = "/", pos = start}

	case '+':
		l.pos += 1;return Token{kind = .Plus, text = "+", pos = start}
	case '*':
		l.pos += 1;return Token{kind = .Asterisk, text = "*", pos = start}
	case '%':
		l.pos += 1;return Token{kind = .Percent, text = "%", pos = start}
	case '&':
		l.pos += 1;return Token{kind = .BitAnd, text = "&", pos = start}
	case '|':
		l.pos += 1;return Token{kind = .BitOr, text = "|", pos = start}
	case '^':
		l.pos += 1;return Token{kind = .BitXor, text = "^", pos = start}
	case '~':
		l.pos += 1;return Token{kind = .BitNot, text = "~", pos = start}

	case '0':
		// Handle special number formats (hex, binary)
		if l.pos + 1 < len(l.source) {
			next := l.source[l.pos + 1]

			// Hexadecimal
			if next == 'x' || next == 'X' {
				l.pos += 2
				hex_start := l.pos
				for l.pos < len(l.source) && is_hex_digit(l.source[l.pos]) {
					l.pos += 1
				}
				if l.pos == hex_start {
					return Token{kind = .Invalid, text = "Invalid hexadecimal number", pos = start}
				}
				return Token{kind = .Hexadecimal, text = l.source[start:l.pos], pos = start}
			}

			// Binary
			if next == 'b' || next == 'B' {
				l.pos += 2
				bin_start := l.pos
				for l.pos < len(l.source) && (l.source[l.pos] == '0' || l.source[l.pos] == '1') {
					l.pos += 1
				}
				if l.pos == bin_start {
					return Token{kind = .Invalid, text = "Invalid binary number", pos = start}
				}
				return Token{kind = .Binary, text = l.source[start:l.pos], pos = start}
			}
		}

		// Fall through to regular number handling
		fallthrough

	case '1', '2', '3', '4', '5', '6', '7', '8', '9':
		// Parse integer part
		for l.pos < len(l.source) && is_digit(l.source[l.pos]) {
			l.pos += 1
		}

		// Check for range notation (e.g., 1..5)
		if l.pos + 1 < len(l.source) && l.source[l.pos] == '.' && l.source[l.pos + 1] == '.' {
			int_part := l.source[start:l.pos]
			l.pos += 2 // Skip the '..'

			// Check if there's a number after, making it a full range (1..5)
			if l.pos < len(l.source) && is_digit(l.source[l.pos]) {
				range_start := l.pos
				for l.pos < len(l.source) && is_digit(l.source[l.pos]) {
					l.pos += 1
				}
				return Token{kind = .Range, text = l.source[start:l.pos], pos = start}
			}

			// Just a postfix range (1..)
			return Token{kind = .PostfixRange, text = l.source[start:l.pos], pos = start}
		}

		// Check for floating point
		if l.pos < len(l.source) && l.source[l.pos] == '.' {
			if l.pos + 1 < len(l.source) && is_digit(l.source[l.pos + 1]) {
				l.pos += 1 // Skip the '.'
				for l.pos < len(l.source) && is_digit(l.source[l.pos]) {
					l.pos += 1
				}
				return Token{kind = .Float, text = l.source[start:l.pos], pos = start}
			}
		}

		return Token{kind = .Integer, text = l.source[start:l.pos], pos = start}

	case:
		// Identifiers
		if is_alpha(c) || c == '_' {
			for l.pos < len(l.source) && is_alnum(l.source[l.pos]) {
				l.pos += 1
			}
			return Token{kind = .Identifier, text = l.source[start:l.pos], pos = start}
		}

		// Unknown character
		l.pos += 1
		return Token{kind = .Invalid, text = string([]u8{c}), pos = start}
	}
}

// === HELPERS ===
is_digit :: proc(c: u8) -> bool {
	return c >= '0' && c <= '9'
}

is_hex_digit :: proc(c: u8) -> bool {
	return is_digit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
}

is_alpha :: proc(c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

is_alnum :: proc(c: u8) -> bool {
	return is_digit(c) || is_alpha(c) || c == '_'
}

is_space :: proc(c: u8) -> bool {
	return c == ' ' || c == '\t' || c == '\r'
}

skip_whitespace :: proc(l: ^Lexer) {
	for l.pos < len(l.source) && is_space(l.source[l.pos]) {
		l.pos += 1
	}
}

// // === FILE READING & TOKEN PRINTING ===
// main :: proc() {
// 	if len(os.args) < 2 {
// 		fmt.println("Usage: lexer <filename>")
// 		os.exit(1)
// 	}

// 	filename := os.args[1]
// 	source, ok := os.read_entire_file(filename)
// 	if !ok {
// 		fmt.printf("Error: Could not read file '%s'\n", filename)
// 		os.exit(1)
// 	}
// 	defer delete(source)

// 	lexer := Lexer {
// 		source = string(source),
// 	}
// 	fmt.println("Tokenizing file:", filename)


// 	for {
// 		token := next_token(&lexer)
// 		fmt.printf("Token: %-15s Text: '%s' Position: %d\n", token.kind, token.text, token.pos)
// 		if token.kind == .EOF {
// 			break
// 		}
// 	}
// }

Pointing :: struct {
	name:       string,
	constraint: ^Constraint,
	value:      [dynamic]Node,
}

Override :: struct {
	source: ^Node,
}

Product :: struct {
	value: ^Node,
}

Statement :: struct {}

Pattern :: struct {
	target: ^Node,
	value:  [dynamic]Branch,
}

Branch :: struct {
	constraint: ^Constraint,
	product:    ^Product,
}

Constraint :: struct {
	value: ^Node,
}

Execute :: struct {
	value: ^Node,
}

Operator :: struct {}


// === AST STRUCTURE DEFINITIONS ===

// Type of literals
Literal_Kind :: enum {
	Integer,
	Float,
	String,
	Hexadecimal,
	Binary,
}

// Literal value node
Literal :: struct {
	kind:  Literal_Kind,
	value: string,
}

// Reference node (for @lib.geometry style references)
Reference :: struct {
	path: string, // Full dot-separated path
}

// Expansion node (for ... operator)
Expansion :: struct {
	target: ^Node,
}

// Event node (for event handling >- and -<)
Event :: struct {
	name:    string,
	is_push: bool, // true for >-, false for -<
	handler: ^Node,
}

// Scope node (a block with multiple statements)
Scope :: struct {
	statements: [dynamic]Node,
}


// Call node (for function calls with !)
Call :: struct {
	target: ^Node,
	mode:   string, // "!", "[!]", "<!>", etc.
}

// Update our Node union to include these new types
Node :: union {
	Pointing, // Variable definition or constraint
	Override, // Override field in an object
	Product, // Return value of a scope
	Branch, // Pattern matching branch
	Statement, // Generic statement
	Pattern, // Pattern matching construct
	Constraint, // Type or value constraint
	Operator, // Mathematical operation
	Execute, // Execute operator (!)
	Literal, // Literal values
	Reference, // External reference (@)
	Expansion, // Expansion operator (...)
	Event, // Event handling
	Scope, // A block of code
	Call, // Function call
}

// Helper function to create a new scope
new_scope :: proc() -> Scope {
	return Scope{statements = make([dynamic]Node)}
}

// Helper to create literals
new_literal :: proc(kind: Literal_Kind, value: string) -> Literal {
	return Literal{kind = kind, value = value}
}

// Create integer literal
new_integer :: proc(value: string) -> Literal {
	return new_literal(.Integer, value)
}

// Create string literal
new_string :: proc(value: string) -> Literal {
	return new_literal(.String, value)
}

// Create float literal
new_float :: proc(value: string) -> Literal {
	return new_literal(.Float, value)
}

// Modifiez la signature de print_ast pour accepter un pointeur vers Node
print_ast :: proc(node: ^Node, indent: int = 0) {
	indent_str := ""
	for i := 0; i < indent; i += 1 {
		indent_str = fmt.tprintf("%s  ", indent_str)
	}

	#partial switch n in node^ { 	// Notez le déréférencement ici
	case Pointing:
		fmt.printf("%sPointing: %s\n", indent_str, n.name)
		if len(n.value) > 0 {
			fmt.printf("%s  Value:\n", indent_str)
			for value in n.value {
				print_ast(&value, indent + 2) // Passez l'adresse de value
			}
		}

	case Literal:
		fmt.printf("%sLiteral: %v '%s'\n", indent_str, n.kind, n.value)

	case Reference:
		fmt.printf("%sReference: %s\n", indent_str, n.path)

	case Expansion:
		fmt.printf("%sExpansion:\n", indent_str)
		print_ast(n.target, indent + 1)

	case Scope:
		fmt.printf("%sScope: {\n", indent_str)
		for stmt in n.statements {
			print_ast(&stmt, indent + 1) // Passez l'adresse de stmt
		}
		fmt.printf("%s}\n", indent_str)

	case Execute:
		fmt.printf("%sExecute:\n", indent_str)
		print_ast(n.value, indent + 1)

	case Call:
		fmt.printf("%sCall (mode: %s):\n", indent_str, n.mode)
		print_ast(n.target, indent + 1)

	case Pattern:
		fmt.printf("%sPattern Match:\n", indent_str)
		fmt.printf("%s  Target:\n", indent_str)
		print_ast(n.target, indent + 2)
		fmt.printf("%s  Branches:\n", indent_str)
		for branch in n.value {
			fmt.printf("%s    Branch:\n", indent_str)
			fmt.printf("%s      Constraint:\n", indent_str)
			print_ast(branch.constraint.value, indent + 4)
			fmt.printf("%s      Product:\n", indent_str)
			print_ast(branch.product.value, indent + 4)
		}

	case:
		fmt.printf("%sUnknown Node: %T\n", indent_str, node^)
	}
}
// === AST Parsing Implementation ===

// Initialize parser
init_parser :: proc(p: ^Parser, l: ^Lexer) {
	p.lexer = l
	parse_next(p) // Prime the parser with the first token
}

// Main entry point for parsing a file
parse_file :: proc(source: string) -> (Node, bool) {
	lexer := Lexer {
		source = source,
	}
	parser := Parser {
		lexer = &lexer,
	}

	init_parser(&parser, &lexer)

	// Parse the top-level expression
	result, ok := parse_expression(&parser)
	if !ok {
		fmt.println("Error: Failed to parse file")
		return {}, false
	}

	return result, true
}

// Parse expressions (top-level constructs)
parse_expression :: proc(p: ^Parser) -> (Node, bool) {
	switch p.current.kind {
	case .Identifier:
		return parse_pointing_or_execute(p)
	case .LeftBrace:
		return parse_scope(p)
	case .At:
		return parse_reference(p)
	case .Ellipsis:
		return parse_expansion(p)
	case .Integer, .Float, .Hexadecimal, .Binary, .String_Literal:
		return parse_literal(p)
	case:
		fmt.printf("Error: Unexpected token %v at position %d\n", p.current.kind, p.current.pos)
		return {}, false
	}
}

// Parse a pointing construct (e.g., "name -> {...}")
parse_pointing_or_execute :: proc(p: ^Parser) -> (Node, bool) {
	if p.current.kind != .Identifier {
		fmt.printf(
			"Error: Expected identifier, got %v at position %d\n",
			p.current.kind,
			p.current.pos,
		)
		return {}, false
	}

	name := p.current.text
	parse_next(p)

	// Check if it's an execute expression
	if p.current.kind == .Execute {
		parse_next(p)
		value, ok := parse_expression(p)
		if !ok {
			return {}, false
		}

		execute := Execute {
			value = value,
		}
		return execute, true
	}

	// Otherwise expect a pointing operation
	if p.current.kind != .PointingPush && p.current.kind != .PointingPull {
		fmt.printf(
			"Error: Expected -> or <-, got %v at position %d\n",
			p.current.kind,
			p.current.pos,
		)
		return {}, false
	}

	is_push := p.current.kind == .PointingPush
	parse_next(p)

	// Parse what's on the right side of the arrow
	value, ok := parse_expression(p)
	if !ok {
		return {}, false
	}

	// Create pointing node
	if is_push {
		pointing := Pointing {
			name  = name,
			value = make([dynamic]Node, 0),
		}
		append(&pointing.value, value)
		return pointing, true
	} else {
		// Handle pull operation (assign constraint)
		constraint := Constraint {
			value = value,
		}
		pointing := Pointing {
			name       = name,
			constraint = constraint,
			value      = make([dynamic]Node, 0),
		}
		return pointing, true
	}
}

// Parse a scope/block (e.g., "{...}")
parse_scope :: proc(p: ^Parser) -> (Node, bool) {
	if p.current.kind != .LeftBrace {
		fmt.printf("Error: Expected {, got %v at position %d\n", p.current.kind, p.current.pos)
		return {}, false
	}

	parse_next(p)

	// Parse all statements in the scope
	statements := make([dynamic]Node)

	for p.current.kind != .RightBrace && p.current.kind != .EOF {
		stmt, ok := parse_expression(p)
		if !ok {
			delete(statements)
			return {}, false
		}

		append(&statements, stmt)

		// Skip optional newlines
		for p.current.kind == .Newline {
			parse_next(p)
		}
	}

	if p.current.kind != .RightBrace {
		fmt.printf("Error: Expected }, got %v at position %d\n", p.current.kind, p.current.pos)
		delete(statements)
		return {}, false
	}
	parse_next(p)

	// Create a product node to represent the scope
	product := Product {
		value = Statement{},
	} // Temporary until we define scope type
	return product, true
}

// Parse a reference expression (e.g., "@lib.geometry.Plane")
parse_reference :: proc(p: ^Parser) -> (Node, bool) {
	if p.current.kind != .At {
		fmt.printf("Error: Expected @, got %v at position %d\n", p.current.kind, p.current.pos)
		return {}, false
	}

	parse_next(p)

	// Parse the path (e.g., "lib.geometry.Plane")
	path := ""

	for p.current.kind == .Identifier || p.current.kind == .Dot {
		path = strings.concatenate({path, p.current.text})
		parse_next(p)
	}

	// Create reference node (for now using a statement node)
	statement := Statement{} // Placeholder - create a proper Reference type
	return statement, true
}

// Parse expansion (e.g., "...@lib.geometry{...}")
parse_expansion :: proc(p: ^Parser) -> (Node, bool) {
	if p.current.kind != .Ellipsis {
		fmt.printf("Error: Expected ..., got %v at position %d\n", p.current.kind, p.current.pos)
		return {}, false
	}

	parse_next(p)

	// Parse what's being expanded
	expr, ok := parse_expression(p)
	if !ok {
		return {}, false
	}

	// Create expansion node (using Statement for now)
	statement := Statement{} // Placeholder - create a proper Expansion type
	return statement, true
}

// Parse literal values (numbers, strings)
parse_literal :: proc(p: ^Parser) -> (Node, bool) {
	value := p.current.text
	kind := p.current.kind
	parse_next(p)

	// Create literal node (using Statement for now)
	statement := Statement{} // Placeholder - create a proper Literal type
	return statement, true
}

// Parse pattern matching (e.g., "-> shape ? {...}")
parse_pattern :: proc(p: ^Parser) -> (Node, bool) {
	if p.current.kind != .Question {
		fmt.printf("Error: Expected ?, got %v at position %d\n", p.current.kind, p.current.pos)
		return {}, false
	}

	parse_next(p)

	// Expect a brace to open the pattern match block
	if p.current.kind != .LeftBrace {
		fmt.printf(
			"Error: Expected { after ?, got %v at position %d\n",
			p.current.kind,
			p.current.pos,
		)
		return {}, false
	}
	parse_next(p)

	// Parse all branches
	branches := make([dynamic]Branch)

	for p.current.kind != .RightBrace && p.current.kind != .EOF {
		// Skip newlines
		for p.current.kind == .Newline {
			parse_next(p)
		}

		if p.current.kind == .RightBrace {
			break
		}

		// Parse constraint
		constraint_expr, ok := parse_expression(p)
		if !ok {
			delete(branches)
			return {}, false
		}

		// Expect a colon
		if p.current.kind != .Colon {
			fmt.printf(
				"Error: Expected : after constraint, got %v at position %d\n",
				p.current.kind,
				p.current.pos,
			)
			delete(branches)
			return {}, false
		}
		parse_next(p)

		// Parse product (what happens for this branch)
		product_expr, ok := parse_expression(p)
		if !ok {
			delete(branches)
			return {}, false
		}

		// Create branch
		constraint := Constraint {
			value = constraint_expr,
		}
		product := Product {
			value = product_expr,
		}
		branch := Branch {
			constraint = constraint,
			product    = product,
		}

		append(&branches, branch)

		// Skip optional newlines
		for p.current.kind == .Newline {
			parse_next(p)
		}
	}

	if p.current.kind != .RightBrace {
		fmt.printf(
			"Error: Expected } to close pattern, got %v at position %d\n",
			p.current.kind,
			p.current.pos,
		)
		delete(branches)
		return {}, false
	}
	parse_next(p)

	// Create pattern node
	pattern := Pattern {
		target = Statement{}, // Placeholder - the target is implicit in your language
		value  = branches,
	}

	return pattern, true
}

// === EXTENDED PARSING FUNCTIONS ===

// Parse a call expression with execution mode (!, <!>, [!], etc.)
parse_call :: proc(p: ^Parser) -> (Node, bool) {
	// First check the token kind
	if p.current.kind != .Execute &&
	   p.current.kind != .LeftParen &&
	   p.current.kind != .LeftBrace &&
	   p.current.kind != .LessThan &&
	   p.current.kind != .BitOr {
		fmt.printf(
			"Error: Expected call token (!, (, [, <, |), got %v at position %d\n",
			p.current.kind,
			p.current.pos,
		)
		return {}, false
	}

	// Determine call mode
	mode := ""

	switch p.current.kind {
	case .Execute:
		mode = "!"
		parse_next(p)

	case .LeftParen:
		// Check for background mode (!)
		parse_next(p)
		if p.current.kind == .Execute {
			mode = "(!)"
			parse_next(p)
			// Expect closing paren
			if p.current.kind != .RightParen {
				fmt.printf(
					"Error: Expected ) after (!, got %v at position %d\n",
					p.current.kind,
					p.current.pos,
				)
				return {}, false
			}
			parse_next(p)
		} else {
			// Handle more complex modes like ([!]) if needed
			// For now, error out for unsupported modes
			fmt.printf("Error: Unsupported call mode at position %d\n", p.current.pos)
			return {}, false
		}

	case .LeftBrace:
		parse_next(p)
		if p.current.kind == .Execute {
			mode = "[!]"
			parse_next(p)
			// Expect closing bracket
			if p.current.kind != .RightParen {
				fmt.printf(
					"Error: Expected ] after [!, got %v at position %d\n",
					p.current.kind,
					p.current.pos,
				)
				return {}, false
			}
			parse_next(p)
		} else {
			fmt.printf(
				"Error: Expected ! after [, got %v at position %d\n",
				p.current.kind,
				p.current.pos,
			)
			return {}, false
		}

	case .LessThan:
		parse_next(p)
		if p.current.kind == .Execute {
			mode = "<!>"
			parse_next(p)
			// Expect closing angle bracket
			if p.current.kind != .GreaterThan {
				fmt.printf(
					"Error: Expected > after <!, got %v at position %d\n",
					p.current.kind,
					p.current.pos,
				)
				return {}, false
			}
			parse_next(p)
		} else {
			fmt.printf(
				"Error: Expected ! after <, got %v at position %d\n",
				p.current.kind,
				p.current.pos,
			)
			return {}, false
		}

	case .BitOr:
		parse_next(p)
		if p.current.kind == .Execute {
			mode = "|!|"
			parse_next(p)
			// Expect closing pipe
			if p.current.kind != .BitOr {
				fmt.printf(
					"Error: Expected | after |!, got %v at position %d\n",
					p.current.kind,
					p.current.pos,
				)
				return {}, false
			}
			parse_next(p)
		} else {
			fmt.printf(
				"Error: Expected ! after |, got %v at position %d\n",
				p.current.kind,
				p.current.pos,
			)
			return {}, false
		}
	}

	// Create call node
	call := Call {
		target = Statement{}, // Placeholder - this would normally be a previously parsed expression
		mode   = mode,
	}

	return call, true
}

// Parse a list of expressions (e.g., for function arguments)
parse_list :: proc(p: ^Parser) -> (Node, bool) {
	list := new_list()

	// Parse expressions until we hit a delimiter
	for p.current.kind != .EOF && p.current.kind != .RightBrace && p.current.kind != .RightParen {

		// Skip optional newlines
		for p.current.kind == .Newline {
			parse_next(p)
		}

		// Parse one expression
		expr, ok := parse_expression(p)
		if !ok {
			fmt.printf("Error: Failed to parse list item at position %d\n", p.current.pos)
			return {}, false
		}

		append(&list.items, expr)

		// Skip optional newlines again
		for p.current.kind == .Newline {
			parse_next(p)
		}
	}

	return list, true
}

// Parse event expressions (>- and -<)
parse_event :: proc(p: ^Parser) -> (Node, bool) {
	is_push := p.current.kind == .EventPush || p.current.kind == .ResonancePush
	is_resonance := p.current.kind == .ResonancePush || p.current.kind == .ResonancePull

	parse_next(p)

	// Parse event target
	expr, ok := parse_expression(p)
	if !ok {
		return {}, false
	}

	// Parse handler (if any)
	// In your language, event handlers usually have a specific structure
	// but for now we'll just capture the expression

	event := Event {
		name    = "", // Name would typically be extracted from the expression
		is_push = is_push,
		handler = expr,
	}

	return event, true
}

// Improved scope parsing with direct Scope type
parse_improved_scope :: proc(p: ^Parser) -> (Node, bool) {
	if p.current.kind != .LeftBrace {
		fmt.printf("Error: Expected {, got %v at position %d\n", p.current.kind, p.current.pos)
		return {}, false
	}

	parse_next(p)

	scope := new_scope()

	for p.current.kind != .RightBrace && p.current.kind != .EOF {
		// Skip optional newlines
		for p.current.kind == .Newline {
			parse_next(p)
		}

		if p.current.kind == .RightBrace {
			break
		}

		// Parse one statement
		stmt, ok := parse_expression(p)
		if !ok {
			fmt.printf("Error: Failed to parse statement at position %d\n", p.current.pos)
			return {}, false
		}

		append(&scope.statements, stmt)

		// Skip optional newlines again
		for p.current.kind == .Newline {
			parse_next(p)
		}
	}

	if p.current.kind != .RightBrace {
		fmt.printf(
			"Error: Expected } to close scope, got %v at position %d\n",
			p.current.kind,
			p.current.pos,
		)
		return {}, false
	}
	parse_next(p)

	return scope, true
}

// Improved literal parsing
parse_improved_literal :: proc(p: ^Parser) -> (Node, bool) {
	kind: Literal_Kind

	switch p.current.kind {
	case .Integer:
		kind = .Integer
	case .Float:
		kind = .Float
	case .Hexadecimal:
		kind = .Hexadecimal
	case .Binary:
		kind = .Binary
	case .String_Literal:
		kind = .String
	case:
		fmt.printf(
			"Error: Unexpected token for literal: %v at position %d\n",
			p.current.kind,
			p.current.pos,
		)
		return {}, false
	}

	value := p.current.text
	parse_next(p)

	return new_literal(kind, value), true
}

// Parse a reference (e.g., @lib.geometry.Plane)
parse_improved_reference :: proc(p: ^Parser) -> (Node, bool) {
	if p.current.kind != .At {
		fmt.printf("Error: Expected @, got %v at position %d\n", p.current.kind, p.current.pos)
		return {}, false
	}

	parse_next(p)

	path_builder: strings.Builder
	strings.builder_init(&path_builder)
	defer strings.builder_destroy(&path_builder)

	// Parse first identifier
	if p.current.kind != .Identifier {
		fmt.printf(
			"Error: Expected identifier after @, got %v at position %d\n",
			p.current.kind,
			p.current.pos,
		)
		return {}, false
	}

	strings.write_string(&path_builder, p.current.text)
	parse_next(p)

	// Parse remaining path components
	for p.current.kind == .Dot {
		strings.write_string(&path_builder, ".")
		parse_next(p)

		if p.current.kind != .Identifier {
			fmt.printf(
				"Error: Expected identifier after dot, got %v at position %d\n",
				p.current.kind,
				p.current.pos,
			)
			return {}, false
		}

		strings.write_string(&path_builder, p.current.text)
		parse_next(p)
	}

	// Check if we have an optional scope modification
	if p.current.kind == .LeftBrace {
		// This would handle the case of @lib.geometry{...}
		// For now we'll just parse and discard the scope
		_, ok := parse_improved_scope(p)
		if !ok {
			return {}, false
		}
	}

	ref := Reference {
		path = strings.to_string(path_builder),
	}

	return ref, true
}

// Parse an expansion expression (e.g., ...@lib.geometry)
parse_improved_expansion :: proc(p: ^Parser) -> (Node, bool) {
	if p.current.kind != .Ellipsis {
		fmt.printf("Error: Expected ..., got %v at position %d\n", p.current.kind, p.current.pos)
		return {}, false
	}

	parse_next(p)

	// Parse the expression being expanded
	expr, ok := parse_expression(p)
	if !ok {
		return {}, false
	}

	expansion := Expansion {
		target = expr,
	}

	return expansion, true
}

// === IMPROVED PARSE EXPRESSION ===
// This would replace the original parse_expression function
parse_improved_expression :: proc(p: ^Parser) -> (Node, bool) {
	switch p.current.kind {
	case .Identifier:
		// Could be a variable reference, function call, etc.
		return parse_pointing_or_execute(p)

	case .LeftBrace:
		return parse_improved_scope(p)

	case .At:
		return parse_improved_reference(p)

	case .Ellipsis:
		return parse_improved_expansion(p)

	case .Integer, .Float, .Hexadecimal, .Binary, .String_Literal:
		return parse_improved_literal(p)

	case .EventPush, .EventPull, .ResonancePush, .ResonancePull:
		return parse_event(p)

	case .Execute, .LeftParen, .LeftBrace, .LessThan, .BitOr:
		return parse_call(p)

	case .Question:
		// This would be pattern matching, but it usually comes after an expression
		// For standalone parsing, we'd need to have a placeholder target
		return parse_pattern(p)

	case:
		fmt.printf("Error: Unexpected token %v at position %d\n", p.current.kind, p.current.pos)
		return {}, false
	}
}

// === MAIN FUNCTION UPDATE ===
main :: proc() {
	if len(os.args) < 2 {
		fmt.println("Usage: compiler <filename>")
		os.exit(1)
	}

	filename := os.args[1]
	source, ok := os.read_entire_file(filename)
	if !ok {
		fmt.printf("Error: Could not read file '%s'\n", filename)
		os.exit(1)
	}
	defer delete(source)

	// Select mode: tokenize or parse
	mode := "parse"
	if len(os.args) >= 3 {
		mode = os.args[2]
	}

	if mode == "tokenize" {
		// Tokenize mode
		lexer := Lexer {
			source = string(source),
		}
		fmt.println("Tokenizing file:", filename)

		for {
			token := next_token(&lexer)
			fmt.printf("Token: %-15s Text: '%s' Position: %d\n", token.kind, token.text, token.pos)
			if token.kind == .EOF {
				break
			}
		}
	} else {
		// Parse mode
		fmt.println("Parsing file:", filename)
		ast, parse_ok := parse_file(string(source))
		if parse_ok {
			fmt.println("Parsing succeeded!")
			// Here you would do something with the AST
		} else {
			fmt.println("Parsing failed!")
		}
	}
}
