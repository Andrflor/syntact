package compiler

/*
 * ======================================================================
 * Language Compiler Implementation
 *
 * This package implements a compiler for a custom language with features
 * like pointings, patterns, and constraints.
 *
 * Organization:
 * 1. Token definitions and lexer
 * 2. AST node definitions
 * 3. Parser implementation
 * 4. Utility functions
 * 5. Main execution and debugging
 * ======================================================================
 */

import "core:fmt"
import "core:os"
import "core:strings"

// ===========================================================================
// SECTION 1: TOKEN DEFINITIONS AND LEXER
// ===========================================================================

/*
 * Token_Kind represents all possible token types in the language
 */
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

/*
 * Token represents a lexical token with its kind, text content and position
 */
Token :: struct {
	kind: Token_Kind, // Type of token
	text: string, // Original text of the token
	pos:  int, // Position in source
}

/*
 * Lexer maintains state during lexical analysis
 */
Lexer :: struct {
	source: string, // Source code being lexed
	pos:    int, // Current position in source
}

// ===========================================================================
// LEXER IMPLEMENTATION
// ===========================================================================

/*
 * next_token scans and returns the next token from the input source
 * It moves the lexer position forward as it consumes characters
 */
next_token :: proc(l: ^Lexer) -> Token {
	skip_whitespace(l)

	if l.pos >= len(l.source) {
		return Token{kind = .EOF, pos = l.pos}
	}

	start := l.pos
	c := l.source[l.pos]

	switch c {
	case '\n':
		return scan_newline(l, start)
	case '`':
		return scan_backtick_string(l, start)
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
		return scan_dot(l, start)
	case '=':
		return scan_equal(l, start)
	case '<':
		return scan_less_than(l, start)
	case '>':
		return scan_greater_than(l, start)
	case '-':
		return scan_minus(l, start)
	case '/':
		return scan_slash(l, start)
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
		// Special number formats (hex, binary)
		if l.pos + 1 < len(l.source) {
			next := l.source[l.pos + 1]

			if next == 'x' || next == 'X' {
				return scan_hexadecimal(l, start)
			}

			if next == 'b' || next == 'B' {
				return scan_binary(l, start)
			}
		}
		// Fall through to regular number handling
		fallthrough
	case '1', '2', '3', '4', '5', '6', '7', '8', '9':
		return scan_number(l, start)
	case:
		// Identifiers
		if is_alpha(c) || c == '_' {
			return scan_identifier(l, start)
		}

		// Unknown character
		l.pos += 1
		return Token{kind = .Invalid, text = string([]u8{c}), pos = start}
	}
}

/*
 * scan_newline processes consecutive newline characters
 */
scan_newline :: proc(l: ^Lexer, start: int) -> Token {
	l.pos += 1
	for l.pos < len(l.source) && l.source[l.pos] == '\n' {
		l.pos += 1
	}
	return Token{kind = .Newline, text = "\\n", pos = start}
}

/*
 * scan_backtick_string processes a string literal enclosed in backticks
 */
scan_backtick_string :: proc(l: ^Lexer, start: int) -> Token {
	// Backtick string literal
	l.pos += 1
	str_start := l.pos
	for l.pos < len(l.source) && l.source[l.pos] != '`' {
		l.pos += 1
	}
	if l.pos < len(l.source) {
		text := l.source[str_start:l.pos]
		l.pos += 1 // Skip closing backtick
		return Token{kind = .String_Literal, text = text, pos = start}
	}
	return Token{kind = .Invalid, text = "Unterminated string", pos = start}
}

/*
 * scan_dot processes dot-related tokens (./ ../.../..)
 */
scan_dot :: proc(l: ^Lexer, start: int) -> Token {
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
}

/*
 * scan_equal processes equal-related tokens (= and ==)
 */
scan_equal :: proc(l: ^Lexer, start: int) -> Token {
	l.pos += 1
	if l.pos < len(l.source) && l.source[l.pos] == '=' {
		l.pos += 1
		return Token{kind = .Equal, text = "==", pos = start}
	}
	return Token{kind = .Equal, text = "=", pos = start}
}

/*
 * scan_less_than processes less-than-related tokens (<, <=, <-)
 */
scan_less_than :: proc(l: ^Lexer, start: int) -> Token {
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
}

/*
 * scan_greater_than processes greater-than-related tokens (>, >=, >-, >>-)
 */
scan_greater_than :: proc(l: ^Lexer, start: int) -> Token {
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
}

/*
 * scan_minus processes minus-related tokens (-, ->, -<, -<<)
 */
scan_minus :: proc(l: ^Lexer, start: int) -> Token {
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
}

/*
 * scan_slash processes slash and comments
 */
scan_slash :: proc(l: ^Lexer, start: int) -> Token {
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
		for l.pos + 1 < len(l.source) && !(l.source[l.pos] == '*' && l.source[l.pos + 1] == '/') {
			l.pos += 1
		}
		if l.pos + 1 < len(l.source) {
			l.pos += 2 // Skip
		}
		return next_token(l)
	}

	l.pos += 1
	return Token{kind = .Slash, text = "/", pos = start}
}

/*
 * scan_hexadecimal processes hexadecimal number literals
 */
scan_hexadecimal :: proc(l: ^Lexer, start: int) -> Token {
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

/*
 * scan_binary processes binary number literals
 */
scan_binary :: proc(l: ^Lexer, start: int) -> Token {
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

/*
 * scan_number processes numeric literals and range notations
 */
scan_number :: proc(l: ^Lexer, start: int) -> Token {
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
}

/*
 * scan_identifier processes identifier tokens
 */
scan_identifier :: proc(l: ^Lexer, start: int) -> Token {
	for l.pos < len(l.source) && is_alnum(l.source[l.pos]) {
		l.pos += 1
	}
	return Token{kind = .Identifier, text = l.source[start:l.pos], pos = start}
}

// ===========================================================================
// SECTION 2: AST NODE DEFINITIONS
// ===========================================================================

/*
 * Node is a union of all possible AST node types
 */
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
	Property,
	Expand,
	FileSystem,
}

/*
 * Pointing represents a pointing declaration (name -> value)
 */
Pointing :: struct {
	name:  string, // Name of the pointing
	value: ^Node, // Value being pointed to
}

/*
 * Identifier represents a named reference
 */
Identifier :: struct {
	name: string, // Name of the identifier
}

/*
 * Scope represents a block of statements enclosed in braces
 */
Scope :: struct {
	value: [dynamic]Node, // Statements in the scope
}

/*
 * Override represents modifications to a base entity
 */
Override :: struct {
	source:    ^Node, // Base entity being modified
	overrides: [dynamic]Node, // Modifications
}

/*
 * Product represents a produced value (-> expr)
 */
Product :: struct {
	value: ^Node, // Value produced
}

/*
 * Pattern represents a pattern match expression
 */
Pattern :: struct {
	target: ^Node, // Value to match against
	value:  [dynamic]Branch, // Pattern branches
}

/*
 * Branch represents a single pattern match branch
 */
Branch :: struct {
	pattern: ^Node, // Pattern to match
	product: ^Node, // Result if pattern matches
}

/*
 * Constraint represents a type constraint (Type: value)
 */
Constraint :: struct {
	constraint: ^Node, // Type constraint
	value:      Maybe(^Node), // Optional value
}

/*
 * Execute represents an execution modifier
 */
Execute :: struct {
	value: ^Node, // Expression to execute
}

/*
 * Operator_Kind defines the types of operators
 */
Operator_Kind :: enum {
	Plus,
	Minus,
	Mult,
	Div,
}

/*
 * Operator represents a binary operation
 */
Operator :: struct {
	kind:  Operator_Kind, // Type of operation
	left:  ^Node, // Left operand
	right: ^Node, // Right operand
}

/*
 * Literal_Kind defines the types of literal values
 */
Literal_Kind :: enum {
	Integer,
	Float,
	String,
	Hexadecimal,
	Binary,
}

/*
 * Literal represents a literal value in the source
 */
Literal :: struct {
	kind:  Literal_Kind, // Type of literal
	value: string, // String representation of the value
}

/*
 * Property represents a property access (a.b)
 */
Property :: struct {
	source:   ^Node, // Object being accessed
	property: ^Node, // Property being accessed
}

/*
 * Expand represents a content expansion (...expr)
 */
Expand :: struct {
	target: ^Node, // Content to expand
}

/*
 * FileSystem represents a file system reference (@lib.module)
 */
FileSystem :: struct {
	target: ^Node, // Target content in file system
}

// ===========================================================================
// SECTION 3: PARSER IMPLEMENTATION
// ===========================================================================

/*
 * Parser maintains state during parsing
 */
Parser :: struct {
	lexer:         ^Lexer, // Lexer providing tokens
	current_token: Token, // Current token being processed
	peek_token:    Token, // Next token (lookahead)
}

/*
 * init_parser initializes a parser with a lexer and reads initial tokens
 */
init_parser :: proc(parser: ^Parser, lexer: ^Lexer) {
	parser.lexer = lexer
	// Initialize with first two tokens
	parser.current_token = next_token(lexer)
	parser.peek_token = next_token(lexer)
}

/*
 * advance_token moves to the next token in the stream
 */
advance_token :: proc(parser: ^Parser) {
	parser.current_token = parser.peek_token
	parser.peek_token = next_token(parser.lexer)
}

/*
 * expect_token checks if the current token is of the expected kind,
 * advances to the next token if true, and returns the result
 */
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

/*
 * parse is the main entry point for the parser
 */
parse :: proc(parser: ^Parser) -> ^Node {
	return parse_program(parser)
}

/*
 * parse_program parses the entire program as a sequence of statements
 */
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

/*
 * parse_statement parses a single statement
 */
parse_statement :: proc(parser: ^Parser) -> ^Node {
	#partial switch parser.current_token.kind {
	case .Integer, .Float, .Hexadecimal, .Binary, .String_Literal:
		return parse_literal(parser)

	case .Question:
		return parse_standalone_pattern(parser)

	case .Identifier:
		// Save the identifier name
		id_name := parser.current_token.text
		advance_token(parser)

		// Check what follows the identifier
		if parser.current_token.kind == .Question {
			return parse_pattern(parser, id_name)
		} else if parser.current_token.kind == .PointingPush {
			return parse_pointing(parser, id_name)
		} else if parser.current_token.kind == .Colon {
			return parse_constraint_statement(parser, id_name)
		} else if parser.current_token.kind == .LeftBrace {
			return parse_override(parser, id_name)
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

/*
 * parse_standalone_pattern parses a pattern with no explicit target (? {...})
 */
parse_standalone_pattern :: proc(parser: ^Parser) -> ^Node {
	advance_token(parser)

	if parser.current_token.kind == .LeftBrace {
		// Create a pattern with an implicit target
		pattern := new(Pattern)
		pattern.target = nil // Implicit target
		pattern.value = make([dynamic]Branch)

		// Consume the '{'
		advance_token(parser)

		// Parse branches until closing brace
		for parser.current_token.kind != .RightBrace && parser.current_token.kind != .EOF {
			// Skip newlines between branches
			for parser.current_token.kind == .Newline {
				advance_token(parser)
			}

			if parser.current_token.kind == .RightBrace {
				break
			}

			// Parse a branch
			if branch_ptr := parse_branch(parser); branch_ptr != nil {
				append(&pattern.value, branch_ptr^)
			} else {
				// Skip to next significant token for error recovery
				for parser.current_token.kind != .Newline &&
				    parser.current_token.kind != .RightBrace &&
				    parser.current_token.kind != .EOF {
					advance_token(parser)
				}
			}

			// Skip newlines after a branch
			for parser.current_token.kind == .Newline {
				advance_token(parser)
			}
		}

		// Expect closing brace
		if !expect_token(parser, .RightBrace) {
			return nil
		}

		result := new(Node)
		result^ = pattern^
		return result
	}

	fmt.println("Error: Expected { after standalone ? token")
	return nil
}

/*
 * parse_constraint_statement parses type constraints (Type: value)
 */
parse_constraint_statement :: proc(parser: ^Parser, type_name: string) -> ^Node {
	// Create a constraint node
	constraint := new(Constraint)

	// Check if the type might be a complex type like maybe{Shape}
	if type_name == "maybe" && parser.current_token.kind == .LeftBrace {
		// We have a maybe{Type} construct
		advance_token(parser) // consume the '{'

		// Parse the inner type
		if parser.current_token.kind != .Identifier {
			fmt.println("Error: Expected identifier inside maybe{}")
			return nil
		}

		inner_type_name := parser.current_token.text
		advance_token(parser) // consume the inner type name

		// Expect closing brace
		if !expect_token(parser, .RightBrace) {
			fmt.println("Error: Expected closing brace after maybe{Type}")
			return nil
		}

		// Create a more complex type identifier for maybe{Type}
		type_node := new(Node)
		type_node^ = Identifier {
			name = fmt.tprintf("maybe{%s}", inner_type_name),
		}
		constraint.constraint = type_node
	} else {
		// Simple type name
		type_node := new(Node)
		type_node^ = Identifier {
			name = type_name,
		}
		constraint.constraint = type_node
	}

	// Consume the colon
	if parser.current_token.kind != .Colon {
		fmt.println("Error: Expected colon in constraint")
		return nil
	}
	advance_token(parser)

	// Check if there's a value after the colon
	if is_expression_start(parser.current_token.kind) {
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
		// No value after the colon, leave value as nil (Type:)
		constraint.value = nil
	}

	result := new(Node)
	result^ = constraint^
	return result
}

/*
 * is_expression_start checks if a token can start an expression
 */
is_expression_start :: proc(kind: Token_Kind) -> bool {
	return(
		kind == .Identifier ||
		kind == .Integer ||
		kind == .Float ||
		kind == .String_Literal ||
		kind == .Hexadecimal ||
		kind == .Binary ||
		kind == .LeftBrace ||
		kind == .At \
	)
}

/*
 * parse_override parses an override expression (Base{...})
 */
parse_override :: proc(parser: ^Parser, id_name: string) -> ^Node {
	// Create an override node
	override := new(Override)

	// Create the source identifier node
	id := new(Node)
	id^ = Identifier {
		name = id_name,
	}
	override.source = id

	// Consume the left brace
	advance_token(parser)

	// Initialize the overrides array
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

	// Return the override node
	result := new(Node)
	result^ = override^
	return result
}

/*
 * parse_pattern parses a pattern match (target ? {...})
 */
parse_pattern :: proc(parser: ^Parser, identifier_name: string) -> ^Node {
	// Create pattern node
	pattern := new(Pattern)

	// Set target identifier
	target := new(Node)
	target^ = Identifier {
		name = identifier_name,
	}
	pattern.target = target

	// Initialize branches array
	pattern.value = make([dynamic]Branch)

	// Consume ? token
	advance_token(parser)

	// Expect {
	if !expect_token(parser, .LeftBrace) {
		fmt.println("Error: Expected { after ? in pattern")
		return nil
	}

	// Parse branches until closing brace
	for parser.current_token.kind != .RightBrace && parser.current_token.kind != .EOF {
		// Skip newlines
		for parser.current_token.kind == .Newline {
			advance_token(parser)
		}

		if parser.current_token.kind == .RightBrace {
			break
		}

		// Parse a branch and add it to the pattern
		branch_ptr := parse_branch(parser)
		if branch_ptr != nil {
			append(&pattern.value, branch_ptr^)
		} else {
			fmt.println("Error: Failed to parse branch in pattern")
			// Skip to next newline or closing brace to recover
			for parser.current_token.kind != .Newline &&
			    parser.current_token.kind != .RightBrace &&
			    parser.current_token.kind != .EOF {
				advance_token(parser)
			}
		}

		// Skip newlines between branches
		for parser.current_token.kind == .Newline {
			advance_token(parser)
		}
	}

	// Expect closing brace
	if !expect_token(parser, .RightBrace) {
		fmt.println("Error: Expected } to close pattern")
		return nil
	}

	// Create and return pattern node
	result := new(Node)
	result^ = pattern^
	return result
}

/*
 * parse_branch parses a single branch in a pattern match
 */
parse_branch :: proc(parser: ^Parser) -> ^Branch {
	// Create new branch
	branch := new(Branch)

	// Parse the pattern (constraint) part
	if parser.current_token.kind == .Identifier {
		// Simple identifier pattern
		pattern_name := parser.current_token.text
		advance_token(parser)

		pattern_node := new(Node)
		pattern_node^ = Identifier {
			name = pattern_name,
		}
		branch.pattern = pattern_node
	} else {
		// More complex pattern expression
		if pattern := parse_expression(parser); pattern != nil {
			branch.pattern = pattern
		} else {
			fmt.println("Error: Failed to parse pattern in branch")
			return nil
		}
	}

	// Expect colon
	if parser.current_token.kind != .Colon {
		fmt.println("Error: Expected : after pattern")
		return nil
	}
	advance_token(parser)

	// Expect ->
	if parser.current_token.kind != .PointingPush {
		fmt.println("Error: Expected -> after : in branch")
		return nil
	}

	// Parse the product (-> expression)
	if product := parse_product(parser); product != nil {
		branch.product = product
	} else {
		fmt.println("Error: Failed to parse product after ->")
		return nil
	}

	return branch
}

/*
 * parse_pointing parses a pointing definition (name -> value)
 */
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

/*
 * parse_product parses a product expression (-> value)
 */
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

/*
 * parse_pointing_pull parses a pointing pull (<- value)
 */
parse_pointing_pull :: proc(parser: ^Parser) -> ^Node {
	// Consume <-
	advance_token(parser)

	pointing := new(Pointing)
	pointing.name = "" // Anonymous pointing

	// Parse the value
	if value := parse_expression(parser); value != nil {
		pointing.value = value
	} else {
		fmt.println("Error: Expected expression after <-")
		return nil
	}

	result := new(Node)
	result^ = pointing^
	return result
}

/*
 * parse_event_push parses an event push (>- value)
 */
parse_event_push :: proc(parser: ^Parser) -> ^Node {
	// Consume >-
	advance_token(parser)

	// Use a special pointing for event push
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

/*
 * parse_event_pull parses an event pull (-< value)
 */
parse_event_pull :: proc(parser: ^Parser) -> ^Node {
	// Consume -<
	advance_token(parser)

	// Use a special pointing for event pull
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

/*
 * parse_scope parses a scope block {...}
 */
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

/*
 * parse_expansion parses a content expansion (...target)
 */
parse_expansion :: proc(parser: ^Parser) -> ^Node {
	// Consume ...
	advance_token(parser)

	// Create expansion node
	expand := new(Expand)

	// Parse the target expression
	if parser.current_token.kind == .At {
		// Special case for file system reference
		if target := parse_reference(parser); target != nil {
			expand.target = target
		} else {
			fmt.println("Error: Failed to parse file system reference after ...")
			return nil
		}
	} else {
		// General expression case
		if target := parse_expression(parser); target != nil {
			expand.target = target
		} else {
			fmt.println("Error: Expected expression after ...")
			return nil
		}
	}

	// Create result for the expansion node
	expand_result := new(Node)
	expand_result^ = expand^

	// Check for overrides in braces
	if parser.current_token.kind == .LeftBrace {
		// Create an override node with the expansion as source
		override := new(Override)
		override.source = expand_result

		// Consume left brace
		advance_token(parser)

		// Initialize overrides array
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

			// Parse statement and add to overrides
			if node := parse_statement(parser); node != nil {
				append(&override.overrides, node^)
			} else {
				// Skip problematic tokens
				advance_token(parser)
			}

			// Skip trailing newlines
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

	// If no overrides, simply return the expansion node
	return expand_result
}

/*
 * parse_reference parses a file system reference (@module.lib)
 */
parse_reference :: proc(parser: ^Parser) -> ^Node {
	// Consume @
	advance_token(parser)

	// Check for identifier after @
	if parser.current_token.kind != .Identifier {
		fmt.println("Error: Expected identifier after @")
		return nil
	}

	// Create FileSystem node
	fs_node := new(FileSystem)

	// Parse first identifier
	id_name := parser.current_token.text
	advance_token(parser)

	// Create initial identifier node
	ident_node := new(Node)
	ident_node^ = Identifier {
		name = id_name,
	}

	// If no property access follows, return basic FileSystem node
	if parser.current_token.kind != .Dot {
		fs_node.target = ident_node
		result := new(Node)
		result^ = fs_node^
		return result
	}

	// Handle property chain (lib.geometry.Plane)
	current_node := ident_node

	// Process all dots and identifiers in the chain
	for parser.current_token.kind == .Dot {
		// Consume dot
		advance_token(parser)

		// Expect identifier
		if parser.current_token.kind != .Identifier {
			fmt.println("Error: Expected identifier after dot")
			return nil
		}

		// Get property name
		property_name := parser.current_token.text
		advance_token(parser)

		// Create property node
		property := new(Property)
		property.source = current_node

		// Create property identifier
		prop_ident := new(Node)
		prop_ident^ = Identifier {
			name = property_name,
		}
		property.property = prop_ident

		// Update current node to this property
		property_node := new(Node)
		property_node^ = property^
		current_node = property_node
	}

	// Set final property chain as FileSystem target
	fs_node.target = current_node

	result := new(Node)
	result^ = fs_node^
	return result
}

/*
 * parse_expression parses expressions (literals, identifiers, operators, etc.)
 */
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

/*
 * parse_primary parses primary expressions (literals, identifiers, scopes)
 */
parse_primary :: proc(parser: ^Parser) -> ^Node {
	#partial switch parser.current_token.kind {
	case .Identifier:
		return parse_identifier_expression(parser)
	case .Integer, .Float, .Hexadecimal, .Binary, .String_Literal:
		return parse_literal(parser)
	case .LeftBrace:
		return parse_scope(parser)
	case .At:
		return parse_reference(parser)
	case:
		fmt.printf("Unexpected token in expression: %v\n", parser.current_token.kind)
		return nil
	}
}

/*
 * parse_identifier_expression parses identifier expressions which may include
 * property access, constraints, or overrides
 */
parse_identifier_expression :: proc(parser: ^Parser) -> ^Node {
	// Save the identifier name
	id_name := parser.current_token.text
	advance_token(parser)

	// Create the identifier node
	id_node := new(Node)
	id_node^ = Identifier {
		name = id_name,
	}

	// Check for property access (identifier followed by dot)
	if parser.current_token.kind == .Dot {
		return parse_property_chain(parser, id_node)
	}

	// Check for constraint (identifier followed by colon)
	if parser.current_token.kind == .Colon {
		return parse_inline_constraint(parser, id_name)
	}

	// Check for override (identifier followed by left brace)
	if parser.current_token.kind == .LeftBrace {
		return parse_inline_override(parser, id_node)
	}

	// Just a regular identifier
	return id_node
}

/*
 * parse_property_chain parses a chain of property accesses (a.b.c)
 */
parse_property_chain :: proc(parser: ^Parser, first_node: ^Node) -> ^Node {
	// Start building property chain
	current := first_node

	// Handle property access chain
	for parser.current_token.kind == .Dot {
		advance_token(parser)

		if parser.current_token.kind != .Identifier {
			fmt.println("Error: Expected identifier after dot")
			return nil
		}

		prop_name := parser.current_token.text
		advance_token(parser)

		prop := new(Property)
		prop.source = current

		prop_id := new(Node)
		prop_id^ = Identifier {
			name = prop_name,
		}
		prop.property = prop_id

		prop_node := new(Node)
		prop_node^ = prop^
		current = prop_node
	}

	return current
}

/*
 * parse_inline_constraint parses a constraint within an expression
 */
parse_inline_constraint :: proc(parser: ^Parser, type_name: string) -> ^Node {
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

	// Check for value after colon
	if is_expression_start(parser.current_token.kind) {
		if value := parse_expression(parser); value != nil {
			value_maybe: Maybe(^Node)
			value_maybe = value
			constraint.value = value_maybe
		}
	}

	result := new(Node)
	result^ = constraint^
	return result
}

/*
 * parse_inline_override parses an override within an expression
 */
parse_inline_override :: proc(parser: ^Parser, source_node: ^Node) -> ^Node {
	// Create an override node
	override := new(Override)

	// Set the source
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

	// Return the override node
	result := new(Node)
	result^ = override^
	return result
}

/*
 * parse_literal parses literal values (numbers, strings)
 */
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

/*
 * parse_binary_expression parses a binary operation expression
 */
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

/*
 * parse_execution parses execution modifiers (!expr, [!], etc)
 */
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

// ===========================================================================
// SECTION 4: UTILITY FUNCTIONS
// ===========================================================================

/*
 * is_binary_operator checks if a token is a binary operator
 */
is_binary_operator :: proc(kind: Token_Kind) -> bool {
	return(
		kind == .Plus ||
		kind == .Minus ||
		kind == .Asterisk ||
		kind == .Slash ||
		kind == .Percent \
	)
}

/*
 * is_execution_modifier checks if a token is an execution modifier
 */
is_execution_modifier :: proc(kind: Token_Kind) -> bool {
	return kind == .Execute || kind == .LeftBrace || kind == .LeftParen
}

/*
 * is_digit checks if a character is a digit
 */
is_digit :: proc(c: u8) -> bool {
	return c >= '0' && c <= '9'
}

/*
 * is_hex_digit checks if a character is a hexadecimal digit
 */
is_hex_digit :: proc(c: u8) -> bool {
	return is_digit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
}

/*
 * is_alpha checks if a character is an alphabetic character
 */
is_alpha :: proc(c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

/*
 * is_alnum checks if a character is alphanumeric or underscore
 */
is_alnum :: proc(c: u8) -> bool {
	return is_digit(c) || is_alpha(c) || c == '_'
}

/*
 * is_space checks if a character is a whitespace character
 */
is_space :: proc(c: u8) -> bool {
	return c == ' ' || c == '\t' || c == '\r'
}

/*
 * skip_whitespace advances the lexer past any whitespace characters
 */
skip_whitespace :: proc(l: ^Lexer) {
	for l.pos < len(l.source) && is_space(l.source[l.pos]) {
		l.pos += 1
	}
}

// ===========================================================================
// SECTION 5: DEBUG UTILITIES
// ===========================================================================

/*
 * debug_print_tokens prints a sequence of upcoming tokens for debugging
 */
debug_print_tokens :: proc(parser: ^Parser, count: int) {
	fmt.println("\n=== TOKEN STREAM ===")

	// Store original parser state
	orig_current := parser.current_token
	orig_peek := parser.peek_token

	// Print current and peek tokens
	fmt.printf("Current: %v '%s'\n", parser.current_token.kind, parser.current_token.text)
	fmt.printf("Peek: %v '%s'\n", parser.peek_token.kind, parser.peek_token.text)

	// Print a few tokens ahead
	fmt.println("\nUpcoming tokens:")

	temp_lexer := parser.lexer^ // Make a copy of the lexer
	temp_parser: Parser
	init_parser(&temp_parser, &temp_lexer)

	// Advance to match the current state
	for temp_parser.current_token.pos < orig_current.pos &&
	    temp_parser.current_token.kind != .EOF {
		advance_token(&temp_parser)
	}

	// Print the next 'count' tokens
	for i := 0; i < count && temp_parser.current_token.kind != .EOF; i += 1 {
		fmt.printf(
			"%d: %v '%s'\n",
			i + 1,
			temp_parser.current_token.kind,
			temp_parser.current_token.text,
		)
		advance_token(&temp_parser)
	}

	fmt.println("=== END TOKEN STREAM ===\n")
}

/*
 * print_ast prints the AST with indentation for readability
 */
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

	case Property:
		fmt.printf("%sProperty\n", indent_str)
		if n.source != nil {
			fmt.printf("%s  Source:\n", indent_str)
			print_ast(n.source, indent + 4)
		}
		if n.property != nil {
			fmt.printf("%s  Property:\n", indent_str)
			print_ast(n.property, indent + 4)
		}

	case Expand:
		fmt.printf("%sExpand\n", indent_str)
		if n.target != nil {
			fmt.printf("%s  Target:\n", indent_str)
			print_ast(n.target, indent + 4)
		}

	case FileSystem:
		fmt.printf("%sFileSystem\n", indent_str)
		if n.target != nil {
			fmt.printf("%s  Target:\n", indent_str)
			print_ast(n.target, indent + 4)
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
		fmt.printf("%s  Branches\n", indent_str)
		for i := 0; i < len(n.value); i += 1 {
			branch := n.value[i]
			fmt.printf("%s    Branch:\n", indent_str)
			if branch.pattern != nil {
				fmt.printf("%s      Pattern:\n", indent_str)
				print_ast(branch.pattern, indent + 8)
			}
			if branch.product != nil {
				fmt.printf("%s      Match:\n", indent_str)
				print_ast(branch.product, indent + 8)
			}
		}

	case Constraint:
		fmt.printf("%sConstraint:\n", indent_str)
		print_ast(n.constraint, indent + 2)
		if n.value != nil {
			if v, ok := n.value.?; ok && v != nil {
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

// ===========================================================================
// SECTION 6: MAIN EXECUTION
// ===========================================================================

/*
 * parse_file initializes a parser with the given lexer and returns the parsed AST
 */
parse_file :: proc(lexer: ^Lexer) -> ^Node {
	parser: Parser
	init_parser(&parser, lexer)
	return parse(&parser)
}

/*
 * main is the entry point of the compiler
 * It reads a file, parses it, and prints the resulting AST
 */
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
