package compiler

/*
 * ======================================================================
 * Language Compiler Implementation
 *
 * This package implements a compiler for a custom language with features
 * like pointings, patterns, and constraints.
 *
 * Organization:
 * 1. Token definitions and lexer (unchanged)
 * 2. AST node definitions (unchanged)
 * 3. Fixed parser implementation with Pratt parsing for expressions
 * 4. Utility functions (unchanged)
 * 5. Improved error handling and recovery
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
	// Skip opening backtick
	l.pos += 1
	str_start := l.pos

	// Scan until closing backtick, handling escaped characters if needed
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
	PointingPull,
	EventPush,
	EventPull,
	ResonancePush,
	ResonancePull,
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
  Range,
}

/*
 * Pointing represents a pointing declaration (name -> value)
 */
Pointing :: struct {
	name:  ^Node, // Name of the pointing
	value: ^Node, // Value being pointed to
}

/*
 * Pointing pull is a declaration later override derived value
 */
PointingPull :: struct {
	name:  ^Node, // Name of the pointing
	value: ^Node, // Value being pointed from
}

/*
 * EventPull represents a event being pull from resonance >-
 */
EventPull :: struct {
	name:  ^Node, // Name of the pointing
	value: ^Node, // Value being pointed to
}

/*
 * EventPush represents a event being pushed into resonance -<
 */
EventPush :: struct {
	name:  ^Node, // Name of the pointing
	value: ^Node, // Value being pointed to
}

/*
 * ResonancePull is useed to change value of resonance driven -<<
 */
ResonancePull :: struct {
	name:  ^Node, // Name of the pointing
	value: ^Node, // Value being pointed to
}

/*
 * ResonancePush is useed to drive resonance >>-
 */
ResonancePush :: struct {
	name:  ^Node, // Name of the pointing
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
	Mod, // For %
	Equal,
	LessThan,
	GreaterThan,
	LessEqual,
	GreaterEqual,
	BitAnd, // &
	BitOr, // |
	BitXor, // ^
	BitNot, // ~
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

/*
 * Range represents a range expression (e.g., 1..5, 1.., ..5)
 */
Range :: struct {
	start: ^Node, // Start of range (may be nil for prefix range)
	end:   ^Node, // End of range (may be nil for postfix range)
}

// ===========================================================================
// SECTION 3: PARSER IMPLEMENTATION
// ===========================================================================

/*
 * Precedence levels for operators, higher value means higher precedence
 */
Precedence :: enum {
    NONE,       // No precedence
    ASSIGNMENT, // =, ->, <-, >-, -<, >>-, -<<
    LOGICAL,    // Reserved for logical operators (&&, ||)
    EQUALITY,   // ==
    COMPARISON, // <, >, <=, >=
    RANGE,      // ..
    TERM,       // +, -
    FACTOR,     // *, /, %
    BITWISE,    // &, |, ^
    UNARY,      // !, ~, unary -
    CALL,       // (), .
    PRIMARY,    // Literals, identifiers
}

/*
 * Parse_Rule defines how to parse a given token as prefix or infix
 */
Parse_Rule :: struct {
    prefix:     proc(parser: ^Parser, can_assign: bool) -> ^Node,
    infix:      proc(parser: ^Parser, left: ^Node, can_assign: bool) -> ^Node,
    precedence: Precedence,
}

/*
 * Parser maintains state during parsing
 */
Parser :: struct {
    lexer:           ^Lexer, // Lexer providing tokens
    current_token:   Token, // Current token being processed
    peek_token:      Token, // Next token (lookahead)
    had_error:       bool, // Flag indicating if an error occurred
    panic_mode:      bool, // Flag for panic mode error recovery
    error_count:     int, // Count of errors encountered
}

/*
 * initialize_parser sets up a parser with a lexer
 */
init_parser :: proc(parser: ^Parser, lexer: ^Lexer) {
    parser.lexer = lexer
    parser.had_error = false
    parser.panic_mode = false
    parser.error_count = 0

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
 * check checks if the current token has the expected kind without advancing
 */
check :: proc(parser: ^Parser, kind: Token_Kind) -> bool {
    return parser.current_token.kind == kind
}

/*
 * match checks if the current token has the expected kind and advances if true
 */
match :: proc(parser: ^Parser, kind: Token_Kind) -> bool {
    if !check(parser, kind) {
        return false
    }
    advance_token(parser)
    return true
}

/*
 * expect_token checks if the current token is of the expected kind,
 * advances to the next token if true, and reports an error if false
 */
expect_token :: proc(parser: ^Parser, kind: Token_Kind) -> bool {
    if check(parser, kind) {
        advance_token(parser)
        return true
    }

    error_at_current(parser, fmt.tprintf("Expected %v but got %v", kind, parser.current_token.kind))
    return false
}

/*
 * error_at_current reports an error at the current token
 */
error_at_current :: proc(parser: ^Parser, message: string) {
    error_at(parser, parser.current_token, message)
}

/*
 * error_at reports an error at a specific token
 */
error_at :: proc(parser: ^Parser, token: Token, message: string) {
    // Don't report errors in panic mode to avoid cascading
    if parser.panic_mode do return

    parser.panic_mode = true
    parser.had_error = true
    parser.error_count += 1

    fmt.eprintf("Error at position %d: ", token.pos)

    if token.kind == .EOF {
        fmt.eprintf("at end")
    } else if token.kind == .Invalid {
        fmt.eprintf("at '%s'", token.text)
    } else {
        fmt.eprintf("at '%s'", token.text)
    }

    fmt.eprintf(": %s\n", message)
}

/*
 * synchronize recovers from panic mode by skipping tokens until a synchronization point
 */
synchronize :: proc(parser: ^Parser) {
    parser.panic_mode = false

    // Track position to detect lack of progress
    start_pos := parser.current_token.pos

    // Skip tokens until we find a good synchronization point
    for parser.current_token.kind != .EOF {
        // Remember token kind to determine if we've advanced
        prev_token_kind := parser.current_token.kind

        // Use certain tokens as synchronization points
        if parser.current_token.kind == .Newline ||
           parser.current_token.kind == .RightBrace {
            advance_token(parser)
            return
        }

        // Look ahead to see if the next token is a good sync point
        if parser.peek_token.kind == .PointingPush ||  // ->
           parser.peek_token.kind == .PointingPull ||  // <-
           parser.peek_token.kind == .Colon ||         // :
           parser.peek_token.kind == .LeftBrace ||     // {
           parser.peek_token.kind == .RightBrace {     // }
            advance_token(parser)
            return
        }

        advance_token(parser)

        // Safety check to prevent infinite loops
        if parser.current_token.pos == start_pos && parser.current_token.kind == prev_token_kind {
            // We're stuck at the same position, force advance
            if parser.current_token.kind != .EOF {
                advance_token(parser)
            }
            return
        }
    }
}

/*
 * parse is the main entry point for the parser
 */
parse :: proc(parser: ^Parser) -> ^Node {
    return parse_program(parser)
}

/*
 * get_rule returns the parse rule for a given token kind
 */
get_rule :: proc(kind: Token_Kind) -> Parse_Rule {
    rules := make(map[Token_Kind]Parse_Rule)

    // Integer and Float Literals
    rules[.Integer] = Parse_Rule{prefix = parse_literal, infix = nil, precedence = .NONE}
    rules[.Float] = Parse_Rule{prefix = parse_literal, infix = nil, precedence = .NONE}
    rules[.Hexadecimal] = Parse_Rule{prefix = parse_literal, infix = nil, precedence = .NONE}
    rules[.Binary] = Parse_Rule{prefix = parse_literal, infix = nil, precedence = .NONE}
    rules[.String_Literal] = Parse_Rule{prefix = parse_literal, infix = nil, precedence = .NONE}

    // Identifiers and basic symbols
    rules[.Identifier] = Parse_Rule{prefix = parse_identifier, infix = nil, precedence = .NONE}
    rules[.LeftBrace] = Parse_Rule{prefix = parse_scope, infix = nil, precedence = .NONE}
    rules[.LeftParen] = Parse_Rule{prefix = parse_grouping, infix = nil, precedence = .NONE}
    rules[.RightBrace] = Parse_Rule{prefix = nil, infix = nil, precedence = .NONE}
    rules[.At] = Parse_Rule{prefix = parse_reference, infix = nil, precedence = .NONE}

    // Unary operators
    rules[.BitNot] = Parse_Rule{prefix = parse_unary, infix = nil, precedence = .UNARY}
    rules[.Minus] = Parse_Rule{prefix = parse_unary, infix = parse_binary, precedence = .TERM}
    rules[.Execute] = Parse_Rule{prefix = parse_execute_prefix, infix = parse_execution, precedence = .UNARY}

    // Binary operators
    rules[.Plus] = Parse_Rule{prefix = nil, infix = parse_binary, precedence = .TERM}
    rules[.Asterisk] = Parse_Rule{prefix = nil, infix = parse_binary, precedence = .FACTOR}
    rules[.Slash] = Parse_Rule{prefix = nil, infix = parse_binary, precedence = .FACTOR}
    rules[.Percent] = Parse_Rule{prefix = nil, infix = parse_binary, precedence = .FACTOR}
    rules[.BitAnd] = Parse_Rule{prefix = nil, infix = parse_binary, precedence = .BITWISE}
    rules[.BitOr] = Parse_Rule{prefix = nil, infix = parse_binary, precedence = .BITWISE}
    rules[.BitXor] = Parse_Rule{prefix = nil, infix = parse_binary, precedence = .BITWISE}
    rules[.Equal] = Parse_Rule{prefix = nil, infix = parse_binary, precedence = .EQUALITY}
    rules[.LessThan] = Parse_Rule{prefix = nil, infix = parse_binary, precedence = .COMPARISON}
    rules[.GreaterThan] = Parse_Rule{prefix = nil, infix = parse_binary, precedence = .COMPARISON}
    rules[.LessEqual] = Parse_Rule{prefix = nil, infix = parse_binary, precedence = .COMPARISON}
    rules[.GreaterEqual] = Parse_Rule{prefix = nil, infix = parse_binary, precedence = .COMPARISON}

    // Specialized operators
    rules[.PointingPush] = Parse_Rule{prefix = parse_product_prefix, infix = parse_pointing_push, precedence = .ASSIGNMENT}
    rules[.PointingPull] = Parse_Rule{prefix = parse_pointing_pull_prefix, infix = parse_pointing_pull, precedence = .ASSIGNMENT}
    rules[.EventPush] = Parse_Rule{prefix = parse_event_push_prefix, infix = parse_event_push, precedence = .ASSIGNMENT}
    rules[.EventPull] = Parse_Rule{prefix = parse_event_pull_prefix, infix = parse_event_pull, precedence = .ASSIGNMENT}
    rules[.ResonancePush] = Parse_Rule{prefix = parse_resonance_push_prefix, infix = parse_resonance_push, precedence = .ASSIGNMENT}
    rules[.ResonancePull] = Parse_Rule{prefix = parse_resonance_pull_prefix, infix = parse_resonance_pull, precedence = .ASSIGNMENT}

    // Range notation
    rules[.DoubleDot] = Parse_Rule{prefix = parse_prefix_range, infix = parse_range, precedence = .RANGE}

    // Special cases
    rules[.Dot] = Parse_Rule{prefix = nil, infix = parse_property, precedence = .CALL}
    rules[.Question] = Parse_Rule{prefix = parse_standalone_pattern, infix = parse_pattern, precedence = .NONE}
    rules[.Colon] = Parse_Rule{prefix = nil, infix = parse_constraint, precedence = .ASSIGNMENT}
    rules[.Ellipsis] = Parse_Rule{prefix = parse_expansion, infix = nil, precedence = .NONE}

    if kind in rules {
        return rules[kind]
    }

    return Parse_Rule{}
}

/*
 * parse_program parses the entire program as a sequence of statements
 */
parse_program :: proc(parser: ^Parser) -> ^Node {
    scope := new(Scope)
    scope.value = make([dynamic]Node)

    // Keep parsing until EOF
    for parser.current_token.kind != .EOF {
        // Skip newlines between statements
        for parser.current_token.kind == .Newline {
            advance_token(parser)
        }

        if parser.current_token.kind == .EOF {
            break
        }

        if node := parse_with_recovery(parser); node != nil {
            append(&scope.value, node^)
        }
    }

    result := new(Node)
    result^ = scope^
    return result
}

/*
 * parse_with_recovery attempts to parse a statement and recovers from errors
 */
parse_with_recovery :: proc(parser: ^Parser) -> ^Node {
    if parser.panic_mode {
        synchronize(parser)
    }

    node := parse_statement(parser)

    // Skip any newlines after a statement
    for parser.current_token.kind == .Newline {
        advance_token(parser)
    }

    return node
}

/*
 * parse_statement parses a single statement
 */
parse_statement :: proc(parser: ^Parser) -> ^Node {
    // Skip empty statements
    if parser.current_token.kind == .Newline {
        advance_token(parser)
        return nil
    }

    #partial switch parser.current_token.kind {
    case .Question:
        return parse_standalone_pattern(parser, false)
    case .Ellipsis:
        return parse_expansion(parser, false)
    case .PointingPush: // Handle standalone -> expressions
        return parse_product_prefix(parser, false)
    case .EOF, .RightBrace:
        // Empty statement - don't report an error
        return nil
    case:
        // Try to parse as an expression by default
        expr := parse_expression(parser)

        // For empty statements (just identifier or constraint), don't expect a newline
        return expr
    }
}

/*
 * parse_expression parses expressions using Pratt parsing
 */
parse_expression :: proc(parser: ^Parser, precedence := Precedence.ASSIGNMENT) -> ^Node {
    if parser.current_token.kind == .EOF || parser.current_token.kind == .RightBrace {
        // Handle empty expressions without error
        return nil
    }

    // Get prefix rule for current token
    rule := get_rule(parser.current_token.kind)
    if rule.prefix == nil {
        // Check for special cases like empty constraints or products
        if parser.current_token.kind == .Colon {
            error_at_current(parser, "Unexpected ':' without a type constraint")
            return nil
        }

        // Return nil instead of reporting error for some tokens
        if parser.current_token.kind == .Newline ||
           parser.current_token.kind == .RightBrace {
            return nil
        }

        // Gracefully handle unexpected tokens by reporting the error once
        if !parser.panic_mode {
            error_at_current(parser, fmt.tprintf("Expected expression, found '%v'", parser.current_token.kind))
        }
        return nil
    }

    // Remember if we're in a context where assignment is allowed
    can_assign := precedence <= .ASSIGNMENT

    // Parse the prefix expression
    left := rule.prefix(parser, can_assign)
    if left == nil {
        return nil
    }

    // Keep parsing infix expressions as long as they have higher precedence
    for precedence <= get_rule(parser.current_token.kind).precedence {
        rule = get_rule(parser.current_token.kind)
        if rule.infix == nil {
            break
        }

        left = rule.infix(parser, left, can_assign)
        if left == nil {
            return nil
        }
    }

    return left
}

/*
 * parse_product_prefix handles the standalone product expression (-> value)
 */
parse_product_prefix :: proc(parser: ^Parser, can_assign: bool) -> ^Node {
    // Consume the ->
    advance_token(parser)

    product := new(Product)

    // Parse the value or handle empty product
    if parser.current_token.kind == .RightBrace || parser.current_token.kind == .EOF ||
       parser.current_token.kind == .Newline {
        // Empty product - this is valid
        product.value = nil
    } else {
        // Parse the value
        if value := parse_expression(parser); value != nil {
            product.value = value
        } else {
            // Error already reported
            return nil
        }
    }

    result := new(Node)
    result^ = product^
    return result
}

/*
 * parse_literal handles literal values (numbers, strings)
 */
parse_literal :: proc(parser: ^Parser, can_assign: bool) -> ^Node {
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
        error_at_current(parser, "Unknown literal type")
        return nil
    }

    advance_token(parser)

    result := new(Node)
    result^ = literal^
    return result
}

/*
 * parse_identifier handles identifier expressions
 */
parse_identifier :: proc(parser: ^Parser, can_assign: bool) -> ^Node {
    // Create identifier node
    id_node := new(Node)
    id_node^ = Identifier{name = parser.current_token.text}

    // Advance past identifier
    advance_token(parser)

    return id_node
}

/*
 * skip_newlines skips consecutive newline tokens
 */
skip_newlines :: proc(parser: ^Parser) {
    for parser.current_token.kind == .Newline {
        advance_token(parser)
    }
}

/*
 * parse_scope parses a scope block {...} - improved to handle empty scopes
 */
parse_scope :: proc(parser: ^Parser, can_assign: bool) -> ^Node {
    // Consume opening brace
    advance_token(parser)

    scope := new(Scope)
    scope.value = make([dynamic]Node)

    // Allow for empty scopes
    if parser.current_token.kind == .RightBrace {
        advance_token(parser)
        result := new(Node)
        result^ = scope^
        return result
    }

    // Parse statements until closing brace
    for parser.current_token.kind != .RightBrace && parser.current_token.kind != .EOF {
        // Skip newlines between statements
        skip_newlines(parser)

        if parser.current_token.kind == .RightBrace {
            break
        }

        // Parse statement and add non-nil results to the scope
        if node := parse_statement(parser); node != nil {
            append(&scope.value, node^)
        }

        // Skip newlines after statements
        skip_newlines(parser)
    }

    // Consume closing brace
    if !match(parser, .RightBrace) {
        error_at_current(parser, "Expected '}' to close scope")
    }

    result := new(Node)
    result^ = scope^
    return result
}

/*
 * parse_grouping parses grouping expressions (...)
 */
parse_grouping :: proc(parser: ^Parser, can_assign: bool) -> ^Node {
    // Consume opening parenthesis
    advance_token(parser)

    // Parse expression inside parentheses
    expr := parse_expression(parser)
    if expr == nil {
        // Handle empty parentheses gracefully
        if parser.current_token.kind == .RightParen {
            advance_token(parser)
            // Return an empty scope as a placeholder
            empty_scope := new(Node)
            empty_scope^ = Scope{value = make([dynamic]Node)}
            return empty_scope
        }

        error_at_current(parser, "Expected expression after '('")
        return nil
    }

    // Expect closing parenthesis
    if !expect_token(parser, .RightParen) {
        return nil
    }

    return expr
}

/*
 * parse_unary parses unary operators (-, ~)
 */
parse_unary :: proc(parser: ^Parser, can_assign: bool) -> ^Node {
    // Remember the operator kind
    operator_kind := parser.current_token.kind

    // Advance past the operator
    advance_token(parser)

    // Parse the operand
    operand := parse_expression(parser, .UNARY)
    if operand == nil {
        error_at_current(parser, "Expected expression after unary operator")
        return nil
    }

    // Create operator node
    op := new(Operator)
    op.right = operand

    // Set operator kind based on token
    #partial switch operator_kind {
    case .Minus:
        op.kind = .Minus
    case .BitNot:
        op.kind = .BitNot
    case:
        error_at_current(parser, "Unexpected unary operator")
        return nil
    }

    result := new(Node)
    result^ = op^
    return result
}

/*
 * parse_execute_prefix parses a prefix execute operator (!expr)
 */
parse_execute_prefix :: proc(parser: ^Parser, can_assign: bool) -> ^Node {
    // Consume ! token
    advance_token(parser)

    // Parse the expression to execute
    expr := parse_expression(parser, .UNARY)
    if expr == nil {
        error_at_current(parser, "Expected expression after '!'")
        return nil
    }

    // Create execute node
    execute := new(Execute)
    execute.value = expr

    result := new(Node)
    result^ = execute^
    return result
}

/*
 * parse_binary handles binary operators (+, -, *, /, etc.)
 */
parse_binary :: proc(parser: ^Parser, left: ^Node, can_assign: bool) -> ^Node {
    // Remember the operator
    operator_kind := parser.current_token.kind
    rule := get_rule(operator_kind)

    // Move past the operator
    advance_token(parser)

    // Parse the right operand with higher precedence
    right := parse_expression(parser, Precedence(int(rule.precedence) + 1))
    if right == nil {
        error_at_current(parser, "Expected expression after binary operator")
        return nil
    }

    // Create operator node
    op := new(Operator)
    op.left = left
    op.right = right

    // Set operator type
    #partial switch operator_kind {
    case .Plus:          op.kind = .Plus
    case .Minus:         op.kind = .Minus
    case .Asterisk:      op.kind = .Mult
    case .Slash:         op.kind = .Div
    case .Percent:       op.kind = .Mod
    case .BitAnd:        op.kind = .BitAnd
    case .BitOr:         op.kind = .BitOr
    case .BitXor:        op.kind = .BitXor
    case .Equal:         op.kind = .Equal
    case .LessThan:      op.kind = .LessThan
    case .GreaterThan:   op.kind = .GreaterThan
    case .LessEqual:     op.kind = .LessEqual
    case .GreaterEqual:  op.kind = .GreaterEqual
    case:
        error_at_current(parser, fmt.tprintf("Unhandled binary operator type: %v", operator_kind))
        return nil
    }

    result := new(Node)
    result^ = op^
    return result
}

/*
 * parse_property handles property access (obj.prop)
 */
parse_property :: proc(parser: ^Parser, left: ^Node, can_assign: bool) -> ^Node {
    // Consume the dot
    advance_token(parser)

    // Expect identifier for property name
    if parser.current_token.kind != .Identifier {
        error_at_current(parser, "Expected property name after '.'")
        return nil
    }

    // Get property name
    prop_name := parser.current_token.text
    advance_token(parser)

    // Create property node
    property := new(Property)
    property.source = left

    // Create property identifier
    prop_id := new(Node)
    prop_id^ = Identifier{name = prop_name}
    property.property = prop_id

    // Return property node
    result := new(Node)
    result^ = property^
    return result
}

/*
 * parse_execution handles execution modifiers (!expr)
 */
parse_execution :: proc(parser: ^Parser, left: ^Node, can_assign: bool) -> ^Node {
    // Consume ! token
    advance_token(parser)

    // Create execute node
    execute := new(Execute)
    execute.value = left

    result := new(Node)
    result^ = execute^
    return result
}

/*
 * parse_pointing_push handles pointing operator (a -> b)
 * Improved to handle empty expressions
 */
parse_pointing_push :: proc(parser: ^Parser, left: ^Node, can_assign: bool) -> ^Node {
    // Create pointing node
    pointing := new(Pointing)
    pointing.name = left

    // Consume ->
    advance_token(parser)

    // Handle the case where there's nothing after the arrow
    if parser.current_token.kind == .RightBrace ||
       parser.current_token.kind == .EOF ||
       parser.current_token.kind == .Newline {
        pointing.value = nil
    } else {
        // Parse value
        value := parse_expression(parser)
        pointing.value = value
    }

    result := new(Node)
    result^ = pointing^
    return result
}
/*
 * parse_pointing_pull_prefix handles prefix pointing pull operator (<- value)
 */
parse_pointing_pull_prefix :: proc(parser: ^Parser, can_assign: bool) -> ^Node {
    // Create pointing pull node
    pointing_pull := new(PointingPull)
    pointing_pull.name = nil // Anonymous

    // Consume <-
    advance_token(parser)

    // Parse value or handle empty value
    if parser.current_token.kind == .RightBrace ||
       parser.current_token.kind == .EOF ||
       parser.current_token.kind == .Newline {
        pointing_pull.value = nil
    } else {
        // Parse value
        value := parse_expression(parser)
        pointing_pull.value = value
    }

    result := new(Node)
    result^ = pointing_pull^
    return result
}

/*
 * parse_pointing_pull handles infix pointing pull operator (a <- b)
 */
parse_pointing_pull :: proc(parser: ^Parser, left: ^Node, can_assign: bool) -> ^Node {
    // Create pointing pull node
    pointing_pull := new(PointingPull)
    pointing_pull.name = left

    // Consume <-
    advance_token(parser)

    // Parse value or handle empty value
    if parser.current_token.kind == .RightBrace ||
       parser.current_token.kind == .EOF ||
       parser.current_token.kind == .Newline {
        pointing_pull.value = nil
    } else {
        // Parse value
        value := parse_expression(parser)
        pointing_pull.value = value
    }

    result := new(Node)
    result^ = pointing_pull^
    return result
}

/*
 * parse_event_push_prefix handles prefix event push (>- value)
 */
parse_event_push_prefix :: proc(parser: ^Parser, can_assign: bool) -> ^Node {
    // Create event push node
    event_push := new(EventPush)
    event_push.name = nil // Anonymous

    // Consume >-
    advance_token(parser)

    // Parse value or handle empty value
    if parser.current_token.kind == .RightBrace ||
       parser.current_token.kind == .EOF ||
       parser.current_token.kind == .Newline {
        event_push.value = nil
    } else {
        // Parse value
        value := parse_expression(parser)
        event_push.value = value
    }

    result := new(Node)
    result^ = event_push^
    return result
}

/*
 * parse_event_push handles event push (a >- b)
 */
parse_event_push :: proc(parser: ^Parser, left: ^Node, can_assign: bool) -> ^Node {
    // Create event push node
    event_push := new(EventPush)
    event_push.name = left

    // Consume >-
    advance_token(parser)

    // Parse value or handle empty value
    if parser.current_token.kind == .RightBrace ||
       parser.current_token.kind == .EOF ||
       parser.current_token.kind == .Newline {
        event_push.value = nil
    } else {
        // Parse value
        value := parse_expression(parser)
        event_push.value = value
    }

    result := new(Node)
    result^ = event_push^
    return result
}

/*
 * parse_event_pull_prefix handles prefix event pull (-< value)
 */
parse_event_pull_prefix :: proc(parser: ^Parser, can_assign: bool) -> ^Node {
    // Create event pull node
    event_pull := new(EventPull)
    event_pull.name = nil // Anonymous

    // Consume -<
    advance_token(parser)

    // Parse value or handle empty value
    if parser.current_token.kind == .RightBrace ||
       parser.current_token.kind == .EOF ||
       parser.current_token.kind == .Newline {
        event_pull.value = nil
    } else {
        // Parse value
        value := parse_expression(parser)
        event_pull.value = value
    }

    result := new(Node)
    result^ = event_pull^
    return result
}

/*
 * parse_event_pull handles event pull (a -< b)
 */
parse_event_pull :: proc(parser: ^Parser, left: ^Node, can_assign: bool) -> ^Node {
    // Create event pull node
    event_pull := new(EventPull)
    event_pull.name = left

    // Consume -<
    advance_token(parser)

    // Parse value or handle empty value
    if parser.current_token.kind == .RightBrace ||
       parser.current_token.kind == .EOF ||
       parser.current_token.kind == .Newline {
        event_pull.value = nil
    } else {
        // Parse value
        value := parse_expression(parser)
        event_pull.value = value
    }

    result := new(Node)
    result^ = event_pull^
    return result
}

/*
 * parse_resonance_push_prefix handles prefix resonance push (>>- value)
 */
parse_resonance_push_prefix :: proc(parser: ^Parser, can_assign: bool) -> ^Node {
    // Create resonance push node
    resonance_push := new(ResonancePush)
    resonance_push.name = nil // Anonymous

    // Consume >>-
    advance_token(parser)

    // Parse value or handle empty value
    if parser.current_token.kind == .RightBrace ||
       parser.current_token.kind == .EOF ||
       parser.current_token.kind == .Newline {
        resonance_push.value = nil
    } else {
        // Parse value
        value := parse_expression(parser)
        resonance_push.value = value
    }

    result := new(Node)
    result^ = resonance_push^
    return result
}

/*
 * parse_resonance_push handles resonance push (a >>- b)
 */
parse_resonance_push :: proc(parser: ^Parser, left: ^Node, can_assign: bool) -> ^Node {
    // Create resonance push node
    resonance_push := new(ResonancePush)
    resonance_push.name = left

    // Consume >>-
    advance_token(parser)

    // Parse value or handle empty value
    if parser.current_token.kind == .RightBrace ||
       parser.current_token.kind == .EOF ||
       parser.current_token.kind == .Newline {
        resonance_push.value = nil
    } else {
        // Parse value
        value := parse_expression(parser)
        resonance_push.value = value
    }

    result := new(Node)
    result^ = resonance_push^
    return result
}

/*
 * parse_resonance_pull_prefix handles prefix resonance pull (-<< value)
 */
parse_resonance_pull_prefix :: proc(parser: ^Parser, can_assign: bool) -> ^Node {
    // Create resonance pull node
    resonance_pull := new(ResonancePull)
    resonance_pull.name = nil // Anonymous

    // Consume -<<
    advance_token(parser)

    // Parse value or handle empty value
    if parser.current_token.kind == .RightBrace ||
       parser.current_token.kind == .EOF ||
       parser.current_token.kind == .Newline {
        resonance_pull.value = nil
    } else {
        // Parse value
        value := parse_expression(parser)
        resonance_pull.value = value
    }

    result := new(Node)
    result^ = resonance_pull^
    return result
}

/*
 * parse_resonance_pull handles resonance pull (a -<< b)
 */
parse_resonance_pull :: proc(parser: ^Parser, left: ^Node, can_assign: bool) -> ^Node {
    // Create resonance pull node
    resonance_pull := new(ResonancePull)
    resonance_pull.name = left

    // Consume -<<
    advance_token(parser)

    // Parse value or handle empty value
    if parser.current_token.kind == .RightBrace ||
       parser.current_token.kind == .EOF ||
       parser.current_token.kind == .Newline {
        resonance_pull.value = nil
    } else {
        // Parse value
        value := parse_expression(parser)
        resonance_pull.value = value
    }

    result := new(Node)
    result^ = resonance_pull^
    return result
}

/*
 * parse_prefix_range handles prefix range (..5)
 */
parse_prefix_range :: proc(parser: ^Parser, can_assign: bool) -> ^Node {
    // Consume ..
    advance_token(parser)

    // Parse end value or handle empty value
    end: ^Node = nil
    if !(parser.current_token.kind == .RightBrace ||
         parser.current_token.kind == .EOF ||
         parser.current_token.kind == .Newline) {
        end = parse_expression(parser, .RANGE)
    }

    // Create range node
    range := new(Range)
    range.start = nil // No start for prefix range
    range.end = end

    result := new(Node)
    result^ = range^
    return result
}

/*
 * parse_range handles range expression (a..b)
 */
parse_range :: proc(parser: ^Parser, left: ^Node, can_assign: bool) -> ^Node {
    // Consume ..
    advance_token(parser)

    // Create range node
    range := new(Range)
    range.start = left

    // Check if there's an end expression
    if parser.current_token.kind == .EOF ||
       parser.current_token.kind == .Newline ||
       parser.current_token.kind == .RightBrace ||
       parser.current_token.kind == .RightParen {
        // This is a postfix range (a..)
        range.end = nil
    } else {
        // This is a full range (a..b)
        end := parse_expression(parser, .RANGE)
        range.end = end
    }

    result := new(Node)
    result^ = range^
    return result
}

/*
 * parse_constraint handles constraint expressions (Type: value)
 * Improved to handle empty constraints (Type:)
 */
parse_constraint :: proc(parser: ^Parser, left: ^Node, can_assign: bool) -> ^Node {
    // Create constraint
    constraint := new(Constraint)
    constraint.constraint = left

    // Move past :
    advance_token(parser)

    // Parse value if present, otherwise it's an empty constraint
    if parser.current_token.kind == .RightBrace ||
       parser.current_token.kind == .EOF ||
       parser.current_token.kind == .Newline ||
       parser.current_token.kind == .PointingPush {
        // Empty constraint (Type:)
        constraint.value = nil
    } else if is_expression_start(parser.current_token.kind) {
        // Constraint with value (Type: value)
        if value := parse_expression(parser); value != nil {
            value_maybe: Maybe(^Node)
            value_maybe = value
            constraint.value = value_maybe
        }
    } else {
        // No value, but it's allowed
        constraint.value = nil
    }

    result := new(Node)
    result^ = constraint^
    return result
}

/*
 * parse_standalone_pattern parses a pattern with no explicit target (? {...})
 */
parse_standalone_pattern :: proc(parser: ^Parser, can_assign: bool) -> ^Node {
    // Consume ? token
    advance_token(parser)

    if parser.current_token.kind == .LeftBrace {
        // Create a pattern with an implicit target
        pattern := new(Pattern)
        pattern.target = nil // Implicit target
        pattern.value = make([dynamic]Branch)

        // Consume the '{'
        advance_token(parser)

        // Allow empty pattern
        if parser.current_token.kind == .RightBrace {
            advance_token(parser)
            result := new(Node)
            result^ = pattern^
            return result
        }

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
                // Error recovery
                synchronize(parser)
            }

            // Skip newlines after a branch
            for parser.current_token.kind == .Newline {
                advance_token(parser)
            }
        }

        // Expect closing brace
        if !match(parser, .RightBrace) {
            error_at_current(parser, "Expected } to close pattern")
        }

        result := new(Node)
        result^ = pattern^
        return result
    }

    error_at_current(parser, "Expected { after standalone ? token")
    return nil
}

/*
 * parse_pattern handles pattern match (target ? {...})
 */
parse_pattern :: proc(parser: ^Parser, left: ^Node, can_assign: bool) -> ^Node {
    // Create pattern node
    pattern := new(Pattern)
    pattern.target = left
    pattern.value = make([dynamic]Branch)

    // Consume ? token
    advance_token(parser)

    // Expect {
    if !expect_token(parser, .LeftBrace) {
        error_at_current(parser, "Expected { after ? in pattern")
        return nil
    }

    // Allow empty pattern
    if parser.current_token.kind == .RightBrace {
        advance_token(parser)
        result := new(Node)
        result^ = pattern^
        return result
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
            // Error recovery
            synchronize(parser)
        }

        // Skip newlines between branches
        for parser.current_token.kind == .Newline {
            advance_token(parser)
        }
    }

    // Expect closing brace
    if !match(parser, .RightBrace) {
        error_at_current(parser, "Expected } to close pattern")
    }

    // Create and return pattern node
    result := new(Node)
    result^ = pattern^
    return result
}

/*
 * parse_branch parses a single branch in a pattern match
 * Improved to handle empty cases and standalone identifiers
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
            error_at_current(parser, "Failed to parse pattern in branch")
            return nil
        }
    }

    // Expect colon
    if !match(parser, .Colon) {
        error_at_current(parser, "Expected : after pattern")
        return nil
    }

    // Check for -> (product)
    if match(parser, .PointingPush) {
        // Parse the product value
        value_expr := parse_expression(parser)
        if value_expr != nil {
            // Handle case where value has an override expression
            if parser.current_token.kind == .LeftBrace {
                // Check if it's an override on a previous expression
                if id, ok := value_expr^.(Identifier); ok {
                    // Parse the override
                    override := new(Override)
                    override.source = value_expr
                    override.overrides = make([dynamic]Node)

                    // Consume the {
                    advance_token(parser)

                    // Parse statements in the override
                    for parser.current_token.kind != .RightBrace && parser.current_token.kind != .EOF {
                        // Skip newlines
                        for parser.current_token.kind == .Newline {
                            advance_token(parser)
                        }

                        if parser.current_token.kind == .RightBrace {
                            break
                        }

                        // Parse override expressions
                        if stmt := parse_statement(parser); stmt != nil {
                            append(&override.overrides, stmt^)
                        } else {
                            synchronize(parser)
                        }

                        // Skip newlines
                        for parser.current_token.kind == .Newline {
                            advance_token(parser)
                        }
                    }

                    // Consume the closing }
                    if !match(parser, .RightBrace) {
                        error_at_current(parser, "Expected } to close override in branch")
                    }

                    // Create the override node
                    override_node := new(Node)
                    override_node^ = override^

                    // Create product with the override as value
                    product := new(Product)
                    product.value = override_node

                    // Set the branch product
                    branch_product := new(Node)
                    branch_product^ = product^
                    branch.product = branch_product
                } else {
                    // Error - cannot override non-identifier
                    error_at_current(parser, "Cannot apply override to non-identifier in branch")

                    // Create a simple product with the value
                    product := new(Product)
                    product.value = value_expr

                    branch_product := new(Node)
                    branch_product^ = product^
                    branch.product = branch_product
                }
            } else {
                // Simple product with the value
                product := new(Product)
                product.value = value_expr

                branch_product := new(Node)
                branch_product^ = product^
                branch.product = branch_product
            }
        } else {
            // Empty product
            product := new(Product)
            product.value = nil

            branch_product := new(Node)
            branch_product^ = product^
            branch.product = branch_product
        }
    } else {
        // No product specified (implicit empty product)
        product := new(Product)
        product.value = nil

        branch_product := new(Node)
        branch_product^ = product^
        branch.product = branch_product
    }

    return branch
}

/*
 * parse_product parses a product expression (-> value)
 * This is for standalone -> expressions
 */
parse_product :: proc(parser: ^Parser) -> ^Node {
    return parse_product_prefix(parser, false)
}

/*
 * parse_expansion parses a content expansion (...expr)
 */
parse_expansion :: proc(parser: ^Parser, can_assign: bool) -> ^Node {
    // Consume ...
    advance_token(parser)

    // Create expansion node
    expand := new(Expand)

    // Parse the target expression
    if parser.current_token.kind == .At {
        // Special case for file system reference
        if target := parse_reference(parser, can_assign); target != nil {
            expand.target = target
        } else {
            error_at_current(parser, "Failed to parse file system reference after ...")
            return nil
        }
    } else {
        // General expression case
        if target := parse_expression(parser); target != nil {
            expand.target = target
        } else {
            error_at_current(parser, "Expected expression after ...")
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

        // Allow empty overrides
        if parser.current_token.kind == .RightBrace {
            advance_token(parser)
            result := new(Node)
            result^ = override^
            return result
        }

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
            if node := parse_expression(parser); node != nil {
                append(&override.overrides, node^)
            } else {
                // Error recovery
                synchronize(parser)
            }

            // Skip trailing newlines
            for parser.current_token.kind == .Newline {
                advance_token(parser)
            }
        }

        // Consume closing brace
        if !match(parser, .RightBrace) {
            error_at_current(parser, "Expected } after expansion overrides")
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
parse_reference :: proc(parser: ^Parser, can_assign: bool) -> ^Node {
    // Consume @
    advance_token(parser)

    // Check for identifier after @
    if parser.current_token.kind != .Identifier {
        error_at_current(parser, "Expected identifier after @")
        return nil
    }

    // Create FileSystem node
    fs_node := new(FileSystem)

    // Parse first identifier
    id_name := parser.current_token.text
    advance_token(parser)

    // Create initial identifier node
    ident_node := new(Node)
    ident_node^ = Identifier{
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
            error_at_current(parser, "Expected identifier after dot")
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
        prop_ident^ = Identifier{
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

// ===========================================================================
// SECTION 4: UTILITY FUNCTIONS
// ===========================================================================

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
        kind == .LeftParen ||
        kind == .At ||
        kind == .BitNot ||
        kind == .Minus ||
        kind == .Execute ||
        kind == .PointingPull ||
        kind == .EventPush ||
        kind == .EventPull ||
        kind == .ResonancePush ||
        kind == .ResonancePull ||
        kind == .DoubleDot ||
        kind == .Question ||
        kind == .Ellipsis ||
        kind == .PointingPush
    )
}

/*
 * is_operator checks if a token is a binary operator
 */
is_operator :: proc(kind: Token_Kind) -> bool {
    return(
        kind == .Equal ||
        kind == .LessThan ||
        kind == .GreaterThan ||
        kind == .LessEqual ||
        kind == .GreaterEqual ||
        kind == .Plus ||
        kind == .Minus ||
        kind == .Asterisk ||
        kind == .Slash ||
        kind == .Percent ||
        kind == .BitAnd ||
        kind == .BitOr ||
        kind == .BitXor ||
        kind == .BitNot ||
        kind == .PointingPush ||
        kind == .PointingPull ||
        kind == .EventPush ||
        kind == .EventPull ||
        kind == .ResonancePush ||
        kind == .ResonancePull ||
        kind == .DoubleDot
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
        fmt.printf("%sPointing ->\n", indent_str)
        if n.name != nil {
            fmt.printf("%s  Name:\n", indent_str)
            print_ast(n.name, indent + 4)
        }
        if n.value != nil {
            fmt.printf("%s  Value:\n", indent_str)
            print_ast(n.value, indent + 4)
        }

    case PointingPull:
        fmt.printf("%sPointingPull <-\n", indent_str)
        if n.name != nil {
            fmt.printf("%s  Name:\n", indent_str)
            print_ast(n.name, indent + 4)
        } else {
            fmt.printf("%s  Name: anonymous\n", indent_str)
        }
        if n.value != nil {
            fmt.printf("%s  Value:\n", indent_str)
            print_ast(n.value, indent + 4)
        }

    case EventPush:
        fmt.printf("%sEventPush >-\n", indent_str)
        if n.name != nil {
            fmt.printf("%s  Name:\n", indent_str)
            print_ast(n.name, indent + 4)
        } else {
            fmt.printf("%s  Name: anonymous\n", indent_str)
        }
        if n.value != nil {
            fmt.printf("%s  Value:\n", indent_str)
            print_ast(n.value, indent + 4)
        }

    case EventPull:
        fmt.printf("%sEventPull -<\n", indent_str)
        if n.name != nil {
            fmt.printf("%s  Name:\n", indent_str)
            print_ast(n.name, indent + 4)
        } else {
            fmt.printf("%s  Name: anonymous\n", indent_str)
        }
        if n.value != nil {
            fmt.printf("%s  Value:\n", indent_str)
            print_ast(n.value, indent + 4)
        }

    case ResonancePush:
        fmt.printf("%sResonancePush >>-\n", indent_str)
        if n.name != nil {
            fmt.printf("%s  Name:\n", indent_str)
            print_ast(n.name, indent + 4)
        } else {
            fmt.printf("%s  Name: anonymous\n", indent_str)
        }
        if n.value != nil {
            fmt.printf("%s  Value:\n", indent_str)
            print_ast(n.value, indent + 4)
        }

    case ResonancePull:
        fmt.printf("%sResonancePull -<<\n", indent_str)
        if n.name != nil {
            fmt.printf("%s  Name:\n", indent_str)
            print_ast(n.name, indent + 4)
        } else {
            fmt.printf("%s  Name: anonymous\n", indent_str)
        }
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
        } else {
            fmt.printf("%s  Target: implicit\n", indent_str)
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
            } else {
                fmt.printf("%s  Value: none\n", indent_str)
            }
        } else {
            fmt.printf("%s  Value: none\n", indent_str)
        }

    case Operator:
        fmt.printf("%sOperator '%v'\n", indent_str, n.kind)
        if n.left != nil {
            fmt.printf("%s  Left:\n", indent_str)
            print_ast(n.left, indent + 4)
        } else {
            fmt.printf("%s  Left: none (unary operator)\n", indent_str)
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

    case Range:
        fmt.printf("%sRange\n", indent_str)
        if n.start != nil {
            fmt.printf("%s  Start:\n", indent_str)
            print_ast(n.start, indent + 4)
        } else {
            fmt.printf("%s  Start: none (prefix range)\n", indent_str)
        }
        if n.end != nil {
            fmt.printf("%s  End:\n", indent_str)
            print_ast(n.end, indent + 4)
        } else {
            fmt.printf("%s  End: none (postfix range)\n", indent_str)
        }

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
parse_file :: proc(lexer: ^Lexer) -> (^Node, bool) {
    parser: Parser
    init_parser(&parser, lexer)

    // Parse the program
    ast := parse_program(&parser)

    // Return the AST and success status
    return ast, !parser.had_error
}

/*
 * main is the entry point of the compiler
 * It reads a file, parses it, and prints the resulting AST
 */
main :: proc() {
    if len(os.args) < 2 {
        fmt.println("Usage: parser <filename> [--debug]")
        os.exit(1)
    }

    filename := os.args[1]
    debug_mode := len(os.args) > 2 && os.args[2] == "--debug"

    source, ok := os.read_entire_file(filename)
    if !ok {
        fmt.printf("Error: Could not read file '%s'\n", filename)
        os.exit(1)
    }
    defer delete(source)

    // Initialize lexer
    lexer := Lexer{
        source = string(source),
    }

    fmt.println("Parsing file:", filename)

    // Parse the file
    ast, success := parse_file(&lexer)
    if ast == nil {
        fmt.println("Parsing failed completely!")
        os.exit(1)
    }

    if !success {
        fmt.println("Parsing completed with errors!")
    } else {
        fmt.println("Successfully parsed file!")
    }

    // Print AST
    print_ast(ast, 0)

    // If in debug mode, print a summary
    if debug_mode {
        fmt.println("\n=== DEBUG SUMMARY ===")

        // Count different node types in the AST
        scope, ok := ast^.(Scope)
        if ok {
            fmt.printf("Top level statements: %d\n", len(scope.value))
        }

        // This could include more debug info like node counts by type, etc.
        fmt.println("=== END DEBUG SUMMARY ===")
    }
}
