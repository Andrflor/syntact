package compiler

import "core:fmt"
import "core:os"
import "core:strings"

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

// === FILE READING & TOKEN PRINTING ===
main :: proc() {
	if len(os.args) < 2 {
		fmt.println("Usage: parser <filename>")
		os.exit(1)
	}

	filename := os.args[1]
	source, ok := os.read_entire_file(filename)
	if !ok {
		fmt.printf("Error: Could not read file '%s'\n", filename)
		os.exit(1)
	}
	defer delete(source)

	// Initialize lexer
	lexer := Lexer {
		source = string(source),
	}

	fmt.println("Parsing file:", filename)

	// Parse the file
	ast := parse_file(&lexer)
	if ast == nil {
		fmt.println("Parsing failed!")
		os.exit(1)
	}

	// Print AST
	fmt.println("Successfully parsed file!")
	print_ast(ast, 0)
}

// Helper function to print the AST with indentation
print_ast :: proc(node: ^Node, indent: int) {
	if node == nil {
		return
	}

	indent_str := strings.repeat(" ", indent)

	#partial switch n in node^ {
	case Pointing:
		fmt.printf("%sPointing '%s' ->\n", indent_str, n.name)
		if n.value != nil {
			fmt.printf("%s  Value:\n", indent_str)
			print_ast(n.value, indent + 4)
		}

	case Identifier:
		fmt.printf("%sIdentifier: %s\n", indent_str, n.name)

	case Scope:
		fmt.printf("%sScope\n", indent_str)
		for i := 0; i < len(n.value); i += 1 {
			entry_node := new(Node)
			entry_node^ = n.value[i]
			print_ast(entry_node, indent + 2)
		}

	case Override:
		fmt.printf("%sOverride\n", indent_str)
		if n.source != nil {
			fmt.printf("%s  Source:\n", indent_str)
			print_ast(n.source, indent + 4)
			fmt.printf("%s  Overrides:\n", indent_str)
			for i := 0; i < len(n.overrides); i += 1 {
				override_node := new(Node)
				override_node^ = n.overrides[i]
				print_ast(override_node, indent + 4)
			}
		}

	case Product:
		fmt.printf("%sProduct ->\n", indent_str)
		if n.value != nil {
			print_ast(n.value, indent + 2)
		}

	case Pattern:
		fmt.printf("%sPattern ?\n", indent_str)
		if n.target != nil {
			fmt.printf("%s  Target:\n", indent_str)
			print_ast(n.target, indent + 4)
		}
		fmt.printf("%s  Branches {\n", indent_str)
		for i := 0; i < len(n.value); i += 1 {
			branch := n.value[i]
			fmt.printf("%s    Branch:\n", indent_str)
			if branch.pattern != nil { 	// Changed from branch.constraint
				fmt.printf("%s      Constraint:\n", indent_str)
				print_ast(branch.pattern, indent + 8) // Changed from branch.constraint.value
			}
			if branch.product != nil {
				fmt.printf("%s      Product:\n", indent_str)
				print_ast(branch.product, indent + 8) // Changed from branch.product.value
			}
		}

	case Constraint:
		fmt.printf("%sConstraint:\n", indent_str)
		print_ast(n.constraint, indent + 2) // Fixed typo: index -> indent
		if n.value != nil {
			if v, ok := n.value.?; ok && v != nil { 	// Handle Maybe(^Node) correctly
				fmt.printf("%s  Value:\n", indent_str)
				print_ast(v, indent + 4)
			}
		}
	case Operator:
		fmt.printf("%sOperator '%v'\n", indent_str, n.kind)
		if n.left != nil {
			fmt.printf("%s  Left:\n", indent_str)
			print_ast(n.left, indent + 4)
		}
		if n.right != nil {
			fmt.printf("%s  Right:\n", indent_str)
			print_ast(n.right, indent + 4)
		}

	case Execute:
		fmt.printf("%sExecute !\n", indent_str)
		if n.value != nil {
			print_ast(n.value, indent + 2)
		}

	case Literal:
		fmt.printf("%sLiteral (%v): %s\n", indent_str, n.kind, n.value)

	case:
		fmt.printf("%sUnknown node type\n", indent_str)
	}
}

Pointing :: struct {
	name:  string,
	value: ^Node,
}

Identifier :: struct {
	name: string,
}

Scope :: struct {
	value: [dynamic]Node,
}

Override :: struct {
	source:    ^Node,
	overrides: [dynamic]Node,
}

Product :: struct {
	value: ^Node,
}

Pattern :: struct {
	target: ^Node,
	value:  [dynamic]Branch,
}

Branch :: struct {
	pattern: ^Node,
	product: ^Node,
}

Constraint :: struct {
	constraint: ^Node,
	value:      Maybe(^Node),
}

Execute :: struct {
	value: ^Node,
}

Operator :: struct {
	kind:  Operator_Kind,
	left:  ^Node,
	right: ^Node,
}

Operator_Kind :: enum {
	Plus,
	Minus,
	Mult,
	Div,
}

Literal_Kind :: enum {
	Integer,
	Float,
	String,
	Hexadecimal,
	Binary,
}

Literal :: struct {
	kind:  Literal_Kind,
	value: string,
}


Node :: union {
	Pointing,
	Scope,
	Override,
	Product,
	Branch,
	Identifier,
	Pattern,
	Constraint,
	Operator,
	Execute,
	Literal,
}

Parser :: struct {
	lexer:         ^Lexer,
	current_token: Token,
	peek_token:    Token,
}

init_parser :: proc(parser: ^Parser, lexer: ^Lexer) {
	parser.lexer = lexer
	// Initialize with first two tokens
	parser.current_token = next_token(lexer)
	parser.peek_token = next_token(lexer)
}

advance_token :: proc(parser: ^Parser) {
	parser.current_token = parser.peek_token
	parser.peek_token = next_token(parser.lexer)
}

expect_token :: proc(parser: ^Parser, kind: Token_Kind) -> bool {
	if parser.current_token.kind == kind {
		advance_token(parser)
		return true
	}
	fmt.printf(
		"Error: Expected token %v, but got %v at position %d\n",
		kind,
		parser.current_token.kind,
		parser.current_token.pos,
	)
	return false
}

// Main parsing function
parse :: proc(parser: ^Parser) -> ^Node {
	return parse_program(parser)
}

// Program is the top-level construct
parse_program :: proc(parser: ^Parser) -> ^Node {
	scope := new(Scope)
	scope.value = make([dynamic]Node)

	// Keep parsing until EOF
	for parser.current_token.kind != .EOF {
		if node := parse_statement(parser); node != nil {
			append(&scope.value, node^)
		} else {
			// Skip problematic tokens to recover from errors
			advance_token(parser)
		}

		// Skip any newlines between statements
		for parser.current_token.kind == .Newline {
			advance_token(parser)
		}
	}

	result := new(Node)
	result^ = scope^
	return result
}


// Add a new function to parse constraint statements (type:value)
parse_constraint_statement :: proc(parser: ^Parser, type_name: string) -> ^Node {
	// Create a constraint node
	constraint := new(Constraint)

	// Set the constraint type
	type_node := new(Node)
	type_node^ = Identifier {
		name = type_name,
	}
	constraint.constraint = type_node

	// Consume the colon
	advance_token(parser)

	// Check if there's a value after the colon or if it's just a standalone constraint (u8:)
	if parser.current_token.kind == .Identifier ||
	   parser.current_token.kind == .Integer ||
	   parser.current_token.kind == .Float ||
	   parser.current_token.kind == .String_Literal ||
	   parser.current_token.kind == .Hexadecimal ||
	   parser.current_token.kind == .Binary ||
	   parser.current_token.kind == .LeftBrace ||
	   parser.current_token.kind == .At {

		// Parse the value (right side of colon)
		if value := parse_expression(parser); value != nil {
			value_maybe: Maybe(^Node)
			value_maybe = value
			constraint.value = value_maybe
		} else {
			fmt.println("Error: Failed to parse expression after colon in constraint")
			return nil
		}
	} else {
		// No value after the colon, leave value as nil (u8:)
		constraint.value = nil
	}

	result := new(Node)
	result^ = constraint^
	return result
}

// Statement can be a pointing, pattern match, etc.
parse_statement :: proc(parser: ^Parser) -> ^Node {
	#partial switch parser.current_token.kind {
	case .Integer, .Float, .Hexadecimal, .Binary, .String_Literal:
		// Handle literals as standalone statements
		return parse_literal(parser)

	case .Identifier:
		// Save the identifier name
		id_name := parser.current_token.text
		advance_token(parser)

		// Check if it's a pointing (identifier ->)
		if parser.current_token.kind == .PointingPush {
			return parse_pointing(parser, id_name)
		}

		// Check if it's a pattern match (identifier ?)
		if parser.current_token.kind == .Question {
			return parse_pattern(parser, id_name)
		}

		// Check if it's a constraint (identifier:)
		if parser.current_token.kind == .Colon {
			constraint_node := parse_constraint_statement(parser, id_name)

			// After parsing the constraint, check if it's followed by ->
			// which would make it a pointing with constraint as value
			if parser.current_token.kind == .PointingPush {
				// This is a pointing with the constraint as a value (u8:a -> 255)
				pointing := new(Pointing)

				// Extract the identifier name from the constraint value
				constraint := cast(^Constraint)constraint_node
				if constraint != nil && constraint.value != nil {
					if v, ok := constraint.value.?; ok {
						// Check if the value is an identifier
						id, id_ok := v^.(Identifier)
						if id_ok {
							pointing.name = id.name
						} else {
							pointing.name = "" // Not an identifier
						}
					} else {
						pointing.name = "" // No value
					}
				} else {
					pointing.name = "" // Not a constraint or no value
				}

				// Consume the ->
				advance_token(parser)

				// Parse the value that follows ->
				if value := parse_expression(parser); value != nil {
					// Create a new constraint with the type from original constraint
					constraint := cast(^Constraint)constraint_node
					if constraint != nil {
						new_constraint := new(Constraint)
						new_constraint.constraint = constraint.constraint

						value_maybe: Maybe(^Node)
						value_maybe = value
						new_constraint.value = value_maybe

						pointing.value = new(Node)
						pointing.value^ = new_constraint^
					} else {
						// Fallback if we can't extract the constraint properly
						pointing.value = value
					}

					result := new(Node)
					result^ = pointing^
					return result
				} else {
					fmt.println("Error: Expected expression after -> in pointing")
					return nil
				}
			}

			return constraint_node
		}

		// Just an identifier
		result := new(Node)
		result^ = Identifier {
			name = id_name,
		}
		return result

	case .LeftBrace:
		// Anonymous scope
		return parse_scope(parser)
	case .Ellipsis:
		// Scope expansion
		return parse_expansion(parser)
	case .At:
		// Reference to external scope
		return parse_reference(parser)
	case .PointingPush:
		return parse_product(parser)
	case .PointingPull:
		return parse_pointing_pull(parser)
	case .EventPush:
		return parse_event_push(parser)
	case .EventPull:
		return parse_event_pull(parser)
	case:
		fmt.printf("Unexpected token at start of statement: %v\n", parser.current_token.kind)
		return nil
	}
}


// Parse a pointing definition or pattern match
parse_pointing_or_pattern :: proc(parser: ^Parser) -> ^Node {
	// Save the identifier
	identifier_name := parser.current_token.text
	advance_token(parser)

	// Check if it's a pointing
	if parser.current_token.kind == .PointingPush {
		return parse_pointing(parser, identifier_name)
	}

	// Check if it's a pattern match
	if parser.current_token.kind == .Question {
		return parse_pattern(parser, identifier_name)
	}

	// Just an identifier
	result := new(Node)
	result^ = Identifier {
		name = identifier_name,
	}
	return result
}

// Parse a pointing like: name -> {...}
parse_pointing :: proc(parser: ^Parser, identifier_name: string) -> ^Node {
	pointing := new(Pointing)
	pointing.name = identifier_name

	// Consume the ->
	advance_token(parser)

	// Parse the value the pointing points to
	if value := parse_expression(parser); value != nil {
		pointing.value = value
	} else {
		fmt.println("Error: Expected expression after pointing operator")
		return nil
	}

	result := new(Node)
	result^ = pointing^
	return result
}

// Parse a pattern match like: value ? { pattern1: -> result1, pattern2: -> result2 }
parse_pattern :: proc(parser: ^Parser, identifier_name: string) -> ^Node {
	pattern := new(Pattern)

	// Create target node (the value being matched)
	target := new(Node)
	target^ = Identifier {
		name = identifier_name,
	}
	pattern.target = target

	// Consume the ?
	advance_token(parser)

	// Expect opening brace for pattern cases
	if !expect_token(parser, .LeftBrace) {
		return nil
	}

	// Initialize the branches dynamic array
	pattern.value = make([dynamic]Branch)

	// Parse each pattern branch
	for parser.current_token.kind != .RightBrace && parser.current_token.kind != .EOF {
		// Skip newlines between branches
		for parser.current_token.kind == .Newline {
			advance_token(parser)
		}

		if parser.current_token.kind == .RightBrace {
			break
		}

		// Parse one branch
		branch := parse_branch(parser)
		if branch != nil {
			append(&pattern.value, branch^)
		}

		// Skip newlines after a branch
		for parser.current_token.kind == .Newline {
			advance_token(parser)
		}
	}

	// Consume closing brace
	if !expect_token(parser, .RightBrace) {
		return nil
	}

	result := new(Node)
	result^ = pattern^
	return result
}

// Parse a single branch in a pattern match
parse_branch :: proc(parser: ^Parser) -> ^Branch {
	branch := new(Branch)

	// Parse the pattern (constraint)
	if pattern := parse_expression(parser); pattern != nil {
		branch.pattern = pattern // Use pattern field instead of constraint
	} else {
		fmt.println("Error: Expected pattern in branch")
		return nil
	}

	// Expect colon
	if !expect_token(parser, .Colon) {
		return nil
	}

	// Parse the result product
	if product := parse_product(parser); product != nil {
		// Store the product node directly
		branch.product = product // Changed from (^Product)(product)
	} else {
		fmt.println("Error: Expected product after pattern in branch")
		return nil
	}

	return branch
}

// Parse a constraint
parse_constraint :: proc(parser: ^Parser) -> ^Constraint {
	constraint := new(Constraint)

	// Parse the value of the constraint
	if value := parse_expression(parser); value != nil {
		constraint.value = value
	} else {
		fmt.println("Error: Expected expression in constraint")
		return nil
	}

	return constraint
}

// Parse a scope {...}
parse_scope :: proc(parser: ^Parser) -> ^Node {
	// Consume opening brace
	advance_token(parser)

	scope := new(Scope)
	scope.value = make([dynamic]Node)

	// Parse statements until closing brace
	for parser.current_token.kind != .RightBrace && parser.current_token.kind != .EOF {
		// Skip newlines between statements
		for parser.current_token.kind == .Newline {
			advance_token(parser)
		}

		if parser.current_token.kind == .RightBrace {
			break
		}

		if node := parse_statement(parser); node != nil {
			append(&scope.value, node^)
		} else {
			// Skip problematic tokens
			advance_token(parser)
		}

		// Skip newlines after statements
		for parser.current_token.kind == .Newline {
			advance_token(parser)
		}
	}

	// Consume closing brace
	if !expect_token(parser, .RightBrace) {
		return nil
	}

	result := new(Node)
	result^ = scope^
	return result
}

// Parse a scope expansion like: ...@lib.geometry{Plane->Plane{dimension->3}}
parse_expansion :: proc(parser: ^Parser) -> ^Node {
	// Consume ...
	advance_token(parser)

	override := new(Override)

	// Parse the source
	if source := parse_expression(parser); source != nil {
		override.source = source
	} else {
		fmt.println("Error: Expected expression after ...")
		return nil
	}

	// Parse any overrides if there are braces
	if parser.current_token.kind == .LeftBrace {
		advance_token(parser)

		override.overrides = make([dynamic]Node)

		// Parse override expressions until closing brace
		for parser.current_token.kind != .RightBrace && parser.current_token.kind != .EOF {
			// Skip newlines
			for parser.current_token.kind == .Newline {
				advance_token(parser)
			}

			if parser.current_token.kind == .RightBrace {
				break
			}

			if node := parse_statement(parser); node != nil {
				append(&override.overrides, node^)
			} else {
				// Skip problematic tokens
				advance_token(parser)
			}

			// Skip newlines
			for parser.current_token.kind == .Newline {
				advance_token(parser)
			}
		}

		// Consume closing brace
		if !expect_token(parser, .RightBrace) {
			return nil
		}
	}

	result := new(Node)
	result^ = override^
	return result
}

// Parse a reference like: @lib.geometry.Plane
parse_reference :: proc(parser: ^Parser) -> ^Node {
	// Consume @
	advance_token(parser)

	// Parse the path as a dot-separated identifier
	path := parser.current_token.text
	advance_token(parser)

	for parser.current_token.kind == .Dot {
		advance_token(parser)
		if parser.current_token.kind != .Identifier {
			fmt.println("Error: Expected identifier after dot in reference path")
			return nil
		}
		path = fmt.tprintf("%s.%s", path, parser.current_token.text)
		advance_token(parser)
	}

	// Create a special reference node (you might want to add this to your AST)
	// For now, using Identifier with a special prefix
	result := new(Node)
	result^ = Identifier {
		name = fmt.tprintf("@%s", path),
	}
	return result
}

// Parse execution modifiers like [!], (!), etc.
parse_execution :: proc(parser: ^Parser, expr: ^Node) -> ^Node {
	execute := new(Execute)
	execute.value = expr

	// Determine the type of execution
	if parser.current_token.kind == .LeftBrace {
		// Handle [!]
		advance_token(parser)
		if !expect_token(parser, .Execute) || !expect_token(parser, .RightBrace) {
			return nil
		}
	} else if parser.current_token.kind == .LeftParen {
		// Handle (!)
		advance_token(parser)
		if !expect_token(parser, .Execute) || !expect_token(parser, .RightParen) {
			return nil
		}
	} else if parser.current_token.kind == .Execute {
		// Handle simple !
		advance_token(parser)
	} else {
		fmt.println("Error: Expected execution operator")
		return nil
	}

	result := new(Node)
	result^ = execute^
	return result
}

// Parse expressions (identifiers, literals, operators, etc.)
parse_expression :: proc(parser: ^Parser) -> ^Node {
	// Start with a primary expression
	expr := parse_primary(parser)
	if expr == nil {
		return nil
	}

	// Check for binary operators
	if is_binary_operator(parser.current_token.kind) {
		return parse_binary_expression(parser, expr)
	}

	// Check for execution modifiers
	if is_execution_modifier(parser.current_token.kind) {
		return parse_execution(parser, expr)
	}

	return expr
}

// Parse primary expressions (literals, identifiers, scopes)
parse_primary :: proc(parser: ^Parser) -> ^Node {
	#partial switch parser.current_token.kind {
	case .Identifier:
		// Handle identifier
		id_name := parser.current_token.text
		advance_token(parser)

		// Check if it's a constraint (identifier followed by colon)
		if parser.current_token.kind == .Colon {
			// Create a constraint node
			constraint := new(Constraint)

			// Set the constraint type
			type_node := new(Node)
			type_node^ = Identifier {
				name = id_name,
			}
			constraint.constraint = type_node

			// Consume the colon
			advance_token(parser)

			// Check if there's a value after the colon
			if parser.current_token.kind == .Identifier ||
			   parser.current_token.kind == .Integer ||
			   parser.current_token.kind == .Float ||
			   parser.current_token.kind == .String_Literal ||
			   parser.current_token.kind == .Hexadecimal ||
			   parser.current_token.kind == .Binary ||
			   parser.current_token.kind == .LeftBrace ||
			   parser.current_token.kind == .At {

				// Parse the value (right side of colon)
				if value := parse_expression(parser); value != nil {
					value_maybe: Maybe(^Node)
					value_maybe = value
					constraint.value = value_maybe
				}
			}

			// Return the constraint node
			result := new(Node)
			result^ = constraint^
			return result
		}

		// Check for override (identifier followed by left brace)
		if parser.current_token.kind == .LeftBrace {
			// Create an override node
			override := new(Override)

			// The source is the identifier we just parsed
			source_node := new(Node)
			source_node^ = Identifier {
				name = id_name,
			}
			override.source = source_node

			// Parse the overrides inside the braces
			advance_token(parser) // Consume the left brace

			override.overrides = make([dynamic]Node)

			// Parse statements until closing brace
			for parser.current_token.kind != .RightBrace && parser.current_token.kind != .EOF {
				// Skip newlines
				for parser.current_token.kind == .Newline {
					advance_token(parser)
				}

				if parser.current_token.kind == .RightBrace {
					break
				}

				if node := parse_statement(parser); node != nil {
					append_elem(&override.overrides, node^)
				} else {
					// Skip problematic tokens
					advance_token(parser)
				}

				// Skip newlines
				for parser.current_token.kind == .Newline {
					advance_token(parser)
				}
			}

			// Consume closing brace
			if !expect_token(parser, .RightBrace) {
				return nil
			}

			// Return the override node
			result := new(Node)
			result^ = override^
			return result
		}

		// Just a regular identifier
		result := new(Node)
		result^ = Identifier {
			name = id_name,
		}
		return result

	case .Integer, .Float, .Hexadecimal, .Binary, .String_Literal:
		// Handle literals
		return parse_literal(parser)

	case .LeftBrace:
		// Handle scope
		return parse_scope(parser)

	case .At:
		// Handle reference
		return parse_reference(parser)

	case:
		fmt.printf("Unexpected token in expression: %v\n", parser.current_token.kind)
		return nil
	}
}
// Parse literal values
parse_literal :: proc(parser: ^Parser) -> ^Node {
	literal := new(Literal)
	literal.value = parser.current_token.text

	#partial switch parser.current_token.kind {
	case .Integer:
		literal.kind = .Integer
	case .Float:
		literal.kind = .Float
	case .Hexadecimal:
		literal.kind = .Hexadecimal
	case .Binary:
		literal.kind = .Binary
	case .String_Literal:
		literal.kind = .String
	case:
		fmt.println("Error: Unknown literal type")
		return nil
	}

	advance_token(parser)

	result := new(Node)
	result^ = literal^
	return result
}

// Parse binary expressions
parse_binary_expression :: proc(parser: ^Parser, left: ^Node) -> ^Node {
	operator := new(Operator)
	operator.left = left

	// Set operator kind
	#partial switch parser.current_token.kind {
	case .Plus:
		operator.kind = .Plus
	case .Minus:
		operator.kind = .Minus
	case .Asterisk:
		operator.kind = .Mult
	case .Slash:
		operator.kind = .Div
	case:
		fmt.println("Error: Unknown binary operator")
		return nil
	}

	advance_token(parser)

	// Parse right operand
	if right := parse_expression(parser); right != nil {
		operator.right = right
	} else {
		fmt.println("Error: Expected expression after binary operator")
		return nil
	}

	result := new(Node)
	result^ = operator^
	return result
}

// Helper function to check if token is a binary operator
is_binary_operator :: proc(kind: Token_Kind) -> bool {
	return(
		kind == .Plus ||
		kind == .Minus ||
		kind == .Asterisk ||
		kind == .Slash ||
		kind == .Percent \
	)
}

// Helper function to check if token is an execution modifier
is_execution_modifier :: proc(kind: Token_Kind) -> bool {
	return kind == .Execute || kind == .LeftBrace || kind == .LeftParen
}

// Additional parsing functions for remaining constructs
parse_product :: proc(parser: ^Parser) -> ^Node {
	// Consume the ->
	advance_token(parser)

	product := new(Product)

	// Parse the value
	if value := parse_expression(parser); value != nil {
		product.value = value
	} else {
		fmt.println("Error: Expected expression after ->")
		return nil
	}

	result := new(Node)
	result^ = product^
	return result
}

parse_pointing_pull :: proc(parser: ^Parser) -> ^Node {
	// Implementation for <-
	advance_token(parser)

	pointing := new(Pointing)
	pointing.name = "" // Anonymous pointing

	// Parse the value
	if value := parse_expression(parser); value != nil {
		pointing.value = value // Use value field instead of constraint
	} else {
		fmt.println("Error: Expected expression after <-")
		return nil
	}

	result := new(Node)
	result^ = pointing^
	return result
}


parse_event_push :: proc(parser: ^Parser) -> ^Node {
	// Implementation for >-
	// Similar structure to pointing_push but with different semantics
	advance_token(parser)

	// For now, treat it as a special type of pointing
	pointing := new(Pointing)
	pointing.name = ">-" // Special identifier for event push

	// Parse the value
	if value := parse_expression(parser); value != nil {
		pointing.value = value
	} else {
		fmt.println("Error: Expected expression after >-")
		return nil
	}

	result := new(Node)
	result^ = pointing^
	return result
}

parse_event_pull :: proc(parser: ^Parser) -> ^Node {
	// Implementation for -<
	advance_token(parser)

	// For now, treat it as a special type of pointing
	pointing := new(Pointing)
	pointing.name = "-<" // Special identifier for event pull

	// Parse the value
	if value := parse_expression(parser); value != nil {
		pointing.value = value
	} else {
		fmt.println("Error: Expected expression after -<")
		return nil
	}

	result := new(Node)
	result^ = pointing^
	return result
}

// Main parsing entry point to replace your current implementation
parse_file :: proc(lexer: ^Lexer) -> ^Node {
	parser: Parser
	init_parser(&parser, lexer)
	return parse(&parser)
}
