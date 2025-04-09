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
 * 3. Fixed parser implementation with Pratt parsing for expressions
 * 4. Utility functions
 * 5. Error handling and recovery
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
  LeftBracket, // [
  RightBracket, // ]

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
 * Position represents a location in the source code with line and column information
 */
Position :: struct {
    line:   int, // Line number (1-based)
    column: int, // Column number (1-based)
    offset: int, // Absolute offset in source
}

/*
 * Token represents a lexical token with its kind, text content and position
 */
Token :: struct {
    kind:     Token_Kind, // Type of token
    text:     string,     // Original text of the token
    position: Position,   // Position information (line, column, offset)
}

/*
 * Lexer maintains state during lexical analysis
 */
Lexer :: struct {
    source:   string, // Source code being lexed
    position: Position, // Current position in source (line, column, offset)
}

/*
 * create_position creates a new Position struct
 */
create_position :: proc(line, column, offset: int) -> Position {
    return Position{line = line, column = column, offset = offset}
}

// ===========================================================================
// LEXER IMPLEMENTATION
// ===========================================================================

/*
 * init_lexer initializes a lexer with the given source code
 */
init_lexer :: proc(l: ^Lexer, source: string) {
    l.source = source
    l.position = create_position(1, 1, 0) // Start at line 1, column 1
}

/*
 * advance_position moves the lexer position forward by one character,
 * updating line and column information appropriately
 */
advance_position :: proc(l: ^Lexer) {
    if l.position.offset < len(l.source) {
        // Check if we're at a newline character
        if l.source[l.position.offset] == '\n' {
            l.position.line += 1
            l.position.column = 1
        } else {
            l.position.column += 1
        }
        l.position.offset += 1
    }
}

/*
 * advance_by advances the lexer position by n characters
 */
advance_by :: proc(l: ^Lexer, n: int) {
    for i := 0; i < n && l.position.offset < len(l.source); i += 1 {
        advance_position(l)
    }
}

/*
 * next_token scans and returns the next token from the input source
 * It moves the lexer position forward as it consumes characters
 */
next_token :: proc(l: ^Lexer) -> Token {
    skip_whitespace(l)

    if l.position.offset >= len(l.source) {
        return Token{kind = .EOF, position = l.position}
    }

    start_pos := l.position
    c := l.source[l.position.offset]

    switch c {
    case '\n':
        return scan_newline(l, start_pos)
    case '`', '"',  '\'':
        return scan_string(l, start_pos)
    case '@':
        advance_position(l)
        return Token{kind = .At, text = "@", position = start_pos}
    case '{':
        advance_position(l)
        return Token{kind = .LeftBrace, text = "{", position = start_pos}
    case '}':
        advance_position(l)
        return Token{kind = .RightBrace, text = "}", position = start_pos}
  case '[':
        advance_position(l)
        return Token{kind = .LeftBracket, text = "[", position = start_pos}
    case ']':
        advance_position(l)
        return Token{kind = .RightBracket, text = "]", position = start_pos}
    case '(':
        advance_position(l)
        return Token{kind = .LeftParen, text = "(", position = start_pos}
    case ')':
        advance_position(l)
        return Token{kind = .RightParen, text = ")", position = start_pos}
    case '!':
        advance_position(l)
        return Token{kind = .Execute, text = "!", position = start_pos}
    case ':':
        advance_position(l)
        return Token{kind = .Colon, text = ":", position = start_pos}
    case '?':
        advance_position(l)
        return Token{kind = .Question, text = "?", position = start_pos}
    case '.':
        return scan_dot(l, start_pos)
    case '=':
        return scan_equal(l, start_pos)
    case '<':
        return scan_less_than(l, start_pos)
    case '>':
        return scan_greater_than(l, start_pos)
    case '-':
        return scan_minus(l, start_pos)
    case '/':
        return scan_slash(l, start_pos)
    case '+':
        advance_position(l)
        return Token{kind = .Plus, text = "+", position = start_pos}
    case '*':
        advance_position(l)
        return Token{kind = .Asterisk, text = "*", position = start_pos}
    case '%':
        advance_position(l)
        return Token{kind = .Percent, text = "%", position = start_pos}
    case '&':
        advance_position(l)
        return Token{kind = .BitAnd, text = "&", position = start_pos}
    case '|':
        advance_position(l)
        return Token{kind = .BitOr, text = "|", position = start_pos}
    case '^':
        advance_position(l)
        return Token{kind = .BitXor, text = "^", position = start_pos}
    case '~':
        advance_position(l)
        return Token{kind = .BitNot, text = "~", position = start_pos}
    case '0':
        // Special number formats (hex, binary)
        if l.position.offset + 1 < len(l.source) {
            next := l.source[l.position.offset + 1]

            if next == 'x' || next == 'X' {
                return scan_hexadecimal(l, start_pos)
            }

            if next == 'b' || next == 'B' {
                return scan_binary(l, start_pos)
            }
        }
        // Fall through to regular number handling
        fallthrough
    case '1', '2', '3', '4', '5', '6', '7', '8', '9':
        return scan_number(l, start_pos)
    case:
        // Identifiers
        if is_alpha(c) || c == '_' {
            return scan_identifier(l, start_pos)
        }

        // Unknown character
        advance_position(l)
        return Token{kind = .Invalid, text = string([]u8{c}), position = start_pos}
    }
}

/*
 * scan_newline processes consecutive newline characters
 */
scan_newline :: proc(l: ^Lexer, start_pos: Position) -> Token {
    advance_position(l) // Consume first newline
    for l.position.offset < len(l.source) && l.source[l.position.offset] == '\n' {
        advance_position(l)
    }
    return Token{kind = .Newline, text = "\\n", position = start_pos}
}

/*
 * scan_string processes a string literal enclosed in provided delimiter
 */
scan_string :: proc(l: ^Lexer, start_pos: Position) -> Token {
    delimiter := l.source[l.position.offset]
    // Skip opening delimiter
    advance_position(l)
    str_start := l.position.offset

    // Scan until closing delimited, handling escaped characters if needed
    for l.position.offset < len(l.source) && l.source[l.position.offset] != delimiter {
        // Handle escaped delimiters and other escape sequences
        if l.source[l.position.offset] == '\\' && l.position.offset + 1 < len(l.source) {
            advance_by(l, 2)  // Skip the escape sequence
        } else {
            advance_position(l)
        }
    }

    if l.position.offset < len(l.source) {
        text := l.source[str_start:l.position.offset]
        advance_position(l) // Skip closing delimiter
        return Token{kind = .String_Literal, text = text, position = start_pos}
    }

    return Token{kind = .Invalid, text = "Unterminated string", position = start_pos}
}

/*
 * scan_dot processes dot-related tokens (./ ../.../..)
 */
scan_dot :: proc(l: ^Lexer, start_pos: Position) -> Token {
    // Check for ranges
    if l.position.offset + 1 < len(l.source) && l.source[l.position.offset + 1] == '.' {
        advance_by(l, 2) // Skip ".."

        // Check for ellipsis "..."
        if l.position.offset < len(l.source) && l.source[l.position.offset] == '.' {
            advance_position(l)
            return Token{kind = .Ellipsis, text = "...", position = start_pos}
        }

        // Check for prefix range "..1"
        if l.position.offset < len(l.source) && is_digit(l.source[l.position.offset]) {
            start_num := l.position.offset
            for l.position.offset < len(l.source) && is_digit(l.source[l.position.offset]) {
                advance_position(l)
            }
            return Token{kind = .PrefixRange, text = l.source[start_pos.offset:l.position.offset], position = start_pos}
        }

        return Token{kind = .DoubleDot, text = "..", position = start_pos}
    }

    advance_position(l)
    return Token{kind = .Dot, text = ".", position = start_pos}
}

/*
 * scan_equal processes equal-related tokens (= and ==)
 */
scan_equal :: proc(l: ^Lexer, start_pos: Position) -> Token {
    advance_position(l)
    if l.position.offset < len(l.source) && l.source[l.position.offset] == '=' {
        advance_position(l)
        return Token{kind = .Equal, text = "==", position = start_pos}
    }
    return Token{kind = .Equal, text = "=", position = start_pos}
}

/*
 * scan_less_than processes less-than-related tokens (<, <=, <-)
 */
scan_less_than :: proc(l: ^Lexer, start_pos: Position) -> Token {
    advance_position(l)
    if l.position.offset < len(l.source) {
        if l.source[l.position.offset] == '=' {
            advance_position(l)
            return Token{kind = .LessEqual, text = "<=", position = start_pos}
        } else if l.source[l.position.offset] == '-' {
            advance_position(l)
            return Token{kind = .PointingPull, text = "<-", position = start_pos}
        }
    }
    return Token{kind = .LessThan, text = "<", position = start_pos}
}

/*
 * scan_greater_than processes greater-than-related tokens (>, >=, >-, >>-)
 */
scan_greater_than :: proc(l: ^Lexer, start_pos: Position) -> Token {
    advance_position(l)
    if l.position.offset < len(l.source) {
        if l.source[l.position.offset] == '=' {
            advance_position(l)
            return Token{kind = .GreaterEqual, text = ">=", position = start_pos}
        } else if l.source[l.position.offset] == '-' {
            advance_position(l)
            return Token{kind = .EventPush, text = ">-", position = start_pos}
        } else if l.position.offset + 1 < len(l.source) &&
           l.source[l.position.offset] == '>' &&
           l.source[l.position.offset + 1] == '-' {
            advance_by(l, 2)
            return Token{kind = .ResonancePush, text = ">>-", position = start_pos}
        }
    }
    return Token{kind = .GreaterThan, text = ">", position = start_pos}
}

/*
 * scan_minus processes minus-related tokens (-, ->, -<, -<<)
 */
scan_minus :: proc(l: ^Lexer, start_pos: Position) -> Token {
    advance_position(l)
    if l.position.offset < len(l.source) {
        if l.source[l.position.offset] == '>' {
            advance_position(l)
            return Token{kind = .PointingPush, text = "->", position = start_pos}
        } else if l.source[l.position.offset] == '<' {
            advance_position(l)
            if l.position.offset < len(l.source) && l.source[l.position.offset] == '<' {
                advance_position(l)
                return Token{kind = .ResonancePull, text = "-<<", position = start_pos}
            }
            return Token{kind = .EventPull, text = "-<", position = start_pos}
        }
    }
    return Token{kind = .Minus, text = "-", position = start_pos}
}

/*
 * scan_slash processes slash and comments
 */
scan_slash :: proc(l: ^Lexer, start_pos: Position) -> Token {
    // Single line comment
    if l.position.offset + 1 < len(l.source) && l.source[l.position.offset + 1] == '/' {
        advance_by(l, 2)
        for l.position.offset < len(l.source) && l.source[l.position.offset] != '\n' {
            advance_position(l)
        }
        return next_token(l)
    }

    // Multi line comment
    if l.position.offset + 1 < len(l.source) && l.source[l.position.offset + 1] == '*' {
        advance_by(l, 2)
        for l.position.offset + 1 < len(l.source) && !(l.source[l.position.offset] == '*' && l.source[l.position.offset + 1] == '/') {
            advance_position(l)
        }
        if l.position.offset + 1 < len(l.source) {
            advance_by(l, 2) // Skip closing */
        }
        return next_token(l)
    }

    advance_position(l)
    return Token{kind = .Slash, text = "/", position = start_pos}
}

/*
 * scan_hexadecimal processes hexadecimal number literals
 */
scan_hexadecimal :: proc(l: ^Lexer, start_pos: Position) -> Token {
    advance_by(l, 2)
    hex_start := l.position.offset
    for l.position.offset < len(l.source) && is_hex_digit(l.source[l.position.offset]) {
        advance_position(l)
    }
    if l.position.offset == hex_start {
        return Token{kind = .Invalid, text = "Invalid hexadecimal number", position = start_pos}
    }
    return Token{kind = .Hexadecimal, text = l.source[start_pos.offset:l.position.offset], position = start_pos}
}

/*
 * scan_binary processes binary number literals
 */
scan_binary :: proc(l: ^Lexer, start_pos: Position) -> Token {
    advance_by(l, 2)
    bin_start := l.position.offset
    for l.position.offset < len(l.source) && (l.source[l.position.offset] == '0' || l.source[l.position.offset] == '1') {
        advance_position(l)
    }
    if l.position.offset == bin_start {
        return Token{kind = .Invalid, text = "Invalid binary number", position = start_pos}
    }
    return Token{kind = .Binary, text = l.source[start_pos.offset:l.position.offset], position = start_pos}
}

/*
 * scan_number processes numeric literals and range notations
 */
scan_number :: proc(l: ^Lexer, start_pos: Position) -> Token {
    // Parse integer part
    for l.position.offset < len(l.source) && is_digit(l.source[l.position.offset]) {
        advance_position(l)
    }

    // Check for range notation (e.g., 1..5)
    if l.position.offset + 1 < len(l.source) &&
       l.source[l.position.offset] == '.' &&
       l.source[l.position.offset + 1] == '.' {

        advance_by(l, 2) // Skip the '..'

        // Check if there's a number after, making it a full range (1..5)
        if l.position.offset < len(l.source) && is_digit(l.source[l.position.offset]) {
            for l.position.offset < len(l.source) && is_digit(l.source[l.position.offset]) {
                advance_position(l)
            }
            return Token{kind = .Range, text = l.source[start_pos.offset:l.position.offset], position = start_pos}
        }

        // Just a postfix range (1..)
        return Token{kind = .PostfixRange, text = l.source[start_pos.offset:l.position.offset], position = start_pos}
    }

    // Check for floating point
    if l.position.offset < len(l.source) && l.source[l.position.offset] == '.' {
        if l.position.offset + 1 < len(l.source) && is_digit(l.source[l.position.offset + 1]) {
            advance_position(l) // Skip the '.'
            for l.position.offset < len(l.source) && is_digit(l.source[l.position.offset]) {
                advance_position(l)
            }
            return Token{kind = .Float, text = l.source[start_pos.offset:l.position.offset], position = start_pos}
        }
    }

    return Token{kind = .Integer, text = l.source[start_pos.offset:l.position.offset], position = start_pos}
}

/*
 * scan_identifier processes identifier tokens
 */
scan_identifier :: proc(l: ^Lexer, start_pos: Position) -> Token {
    for l.position.offset < len(l.source) && is_alnum(l.source[l.position.offset]) {
        advance_position(l)
    }
    return Token{kind = .Identifier, text = l.source[start_pos.offset:l.position.offset], position = start_pos}
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
	source: ^Node, // Pattern to match
	product: ^Node, // Result if pattern matches
}

/*
 * Constraint represents a type constraint (Type: value)
 */
Constraint :: struct {
	constraint: ^Node, // Type constraint
	value:      ^Node, // Optional value
}

/*
 * ExecutionWrapper represents a single wrapper in a potentially nested execution pattern
 */
ExecutionWrapper :: enum {
    None,
    Sequential,      // !
    Threading,       // < >
    Parallel_CPU,    // [ ]
    Background,      // ( )
    GPU,             // | |
}

/*
 * Execute represents an execution modifier
 */
Execute :: struct {
    value: ^Node,                     // Expression to execute
    wrappers: [dynamic]ExecutionWrapper, // Ordered list of execution wrappers (from outside to inside)
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
    CALL,       // (), ., : (constraint now at this level)
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
 * error_at reports an error at a specific token with line and column info
 */
error_at :: proc(parser: ^Parser, token: Token, message: string) {
    // Don't report errors in panic mode to avoid cascading
    if parser.panic_mode do return

    parser.panic_mode = true
    parser.had_error = true
    parser.error_count += 1

    fmt.eprintf("Error at line %d, column %d: ", token.position.line, token.position.column)

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

    // Record position to detect lack of progress
    start_pos := parser.current_token.position.offset
    start_kind := parser.current_token.kind

    // Skip tokens until we find a good synchronization point
    for parser.current_token.kind != .EOF {
        // Check if current token is a synchronization point
        if parser.current_token.kind == .Newline ||
           parser.current_token.kind == .RightBrace ||
           parser.current_token.kind == .PointingPush ||
           parser.current_token.kind == .PointingPull {
            advance_token(parser)
            return
        }

        // Current position before advancing
        current_pos := parser.current_token.position.offset
        current_kind := parser.current_token.kind

        // Try to advance
        advance_token(parser)

        // If we're not making progress (position and token kind haven't changed),
        // force advancement to break potential infinite loops
        if parser.current_token.position.offset == current_pos &&
           parser.current_token.kind == current_kind {
            // Stuck at same token - force advancement
            if parser.current_token.kind == .EOF {
                return
            }
            advance_token(parser)
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
    rules[.Execute] = Parse_Rule{prefix = parse_execute_prefix, infix = nil, precedence = .UNARY}

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

    // Specialized operators - MODIFIED PRECEDENCE LEVELS
    // Constraint should have higher precedence than assignment operators
    rules[.Colon] = Parse_Rule{prefix = nil, infix = parse_constraint, precedence = .CALL}

    // Assignment operators
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
    rules[.Question] = Parse_Rule{prefix = nil, infix = parse_pattern, precedence = .CALL}
    rules[.Ellipsis] = Parse_Rule{prefix = parse_expansion, infix = nil, precedence = .PRIMARY}

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
    case .Ellipsis:
        return parse_expansion(parser, false)
    case .PointingPush: // Handle standalone -> expressions
        return parse_product(parser)
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
        // Better error messages for common cases
        if parser.current_token.kind == .Colon {
            error_at_current(parser, "Unexpected ':' without a type constraint")
        } else if parser.current_token.kind == .PointingPush {
            error_at_current(parser, "Unexpected '->' without a name to point from")
        } else if !parser.panic_mode {
            error_at_current(parser, fmt.tprintf("Expected expression, found '%v'", parser.current_token.kind))
        }

        // Advance past the problematic token to avoid getting stuck
        advance_token(parser)
        return nil
    }

    // Remember if we're in a context where assignment is allowed
    can_assign := precedence <= .ASSIGNMENT

    // Parse the prefix expression
    left := rule.prefix(parser, can_assign)
    // Check for execution pattern after expression
    if parser.current_token.kind == .Execute {
        // Create execute node with sequential execution
        execute := new(Execute)
        execute.value = left
        execute.wrappers = make([dynamic]ExecutionWrapper)
        append_elem(&execute.wrappers, ExecutionWrapper.Sequential)

        // Consume the !
        advance_token(parser)

        result := new(Node)
        result^ = execute^
        left = result
    } else if parser.current_token.kind == .LeftBracket {
        // Handle [!] pattern
        opening := parser.current_token.kind
        advance_token(parser)

        // Look for ! inside brackets
        if parser.current_token.kind == .Execute {
            execute := new(Execute)
            execute.value = left
            execute.wrappers = make([dynamic]ExecutionWrapper)
            append_elem(&execute.wrappers, ExecutionWrapper.Parallel_CPU)
            append_elem(&execute.wrappers, ExecutionWrapper.Sequential)

            // Consume the !
            advance_token(parser)

            // Expect closing bracket
            if parser.current_token.kind != .RightBracket {
                error_at_current(parser, "Expected ']' after execution pattern")
                return nil
            }
            advance_token(parser)

            result := new(Node)
            result^ = execute^
            left = result
        }
    } else if parser.current_token.kind == .LessThan {
        // Handle <[!]> pattern
        advance_token(parser)

    if parser.current_token.kind == .LeftBracket {
        // Handle <[!]> pattern
        advance_token(parser)

        if parser.current_token.kind == .Execute {
            execute := new(Execute)
            execute.value = left
            execute.wrappers = make([dynamic]ExecutionWrapper)
            append_elem(&execute.wrappers, ExecutionWrapper.Threading)
            append_elem(&execute.wrappers, ExecutionWrapper.Parallel_CPU)
            append_elem(&execute.wrappers, ExecutionWrapper.Sequential)

            // Consume the !
            advance_token(parser)

            // Expect closing bracket and angle bracket
            if parser.current_token.kind != .RightBracket {
                error_at_current(parser, "Expected ']' in execution pattern")
                return nil
            }
            advance_token(parser)

            if parser.current_token.kind != .GreaterThan {
                error_at_current(parser, "Expected '>' to close execution pattern")
                return nil
            }
            advance_token(parser)

            result := new(Node)
            result^ = execute^
            left = result
        }
    }
}
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

    // Check for execution pattern postfix
    if is_execution_pattern_start(parser.current_token.kind) {
        left = parse_execution_pattern_postfix(parser, left)
        if left == nil {
            return nil
        }
    }

    // Check for override expressions (expression followed by braces)
    if parser.current_token.kind == .LeftBrace {
        // Create an override node
        override := new(Override)
        override.source = left
        override.overrides = make([dynamic]Node)

        // Consume left brace
        advance_token(parser)

        // Parse statements inside the braces as overrides
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
                // Error recovery
                synchronize(parser)

                // Check if we synchronized to the end of the overrides
                if parser.current_token.kind == .RightBrace {
                    break
                }
            }

            // Skip newlines
            for parser.current_token.kind == .Newline {
                advance_token(parser)
            }
        }

        // Expect closing brace
        if !match(parser, .RightBrace) {
            error_at_current(parser, "Expected } after overrides")
            return nil
        }

        // Create and set the override as our left-hand expression
        result := new(Node)
        result^ = override^
        left = result

        // Check for execution pattern after the override
        if is_execution_pattern_start(parser.current_token.kind) {
            left = parse_execution_pattern_postfix(parser, left)
            if left == nil {
                return nil
            }
        }

        // Check if there are infix operations that can follow the override
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
    }

    return left
}

/*
 * parse_execution_pattern_postfix handles postfix execution patterns like expr<[!]>
 */
parse_execution_pattern_postfix :: proc(parser: ^Parser, left: ^Node) -> ^Node {
    // Create execute node to hold the left expression
    execute := new(Execute)
    execute.value = left
    execute.wrappers = make([dynamic]ExecutionWrapper)

    // Process the execution pattern
    found_exclamation := false

    // Stack to track opening symbols for proper nesting
    stack := make([dynamic]Token_Kind)
    defer delete(stack)

    // Continue parsing until we have a complete execution pattern
    for {
        current := parser.current_token.kind

        if current == .Execute {
            // Add sequential execution wrapper
            append_elem(&execute.wrappers, ExecutionWrapper.Sequential)
            found_exclamation = true
            advance_token(parser)
        } else if current == .LeftParen {
            // Start of background execution
            append_elem(&execute.wrappers, ExecutionWrapper.Background)
            append_elem(&stack, Token_Kind.LeftParen)
            advance_token(parser)
        } else if current == .LessThan {
            // Start of threading execution
            append_elem(&execute.wrappers, ExecutionWrapper.Threading)
            append_elem(&stack, Token_Kind.LessThan)
            advance_token(parser)
        } else if current == .LeftBracket {
            // Start of parallel CPU execution
            append_elem(&execute.wrappers, ExecutionWrapper.Parallel_CPU)
            append_elem(&stack, Token_Kind.LeftBracket)
            advance_token(parser)
        } else if current == .BitOr {
            // Check if it's an opening or closing BitOr
            if len(stack) > 0 && stack[len(stack)-1] == Token_Kind.BitOr {
                // Closing BitOr, pop from stack
                ordered_remove(&stack, len(stack)-1)
                advance_token(parser)
            } else {
                // Opening BitOr, push to stack
                append_elem(&execute.wrappers, ExecutionWrapper.GPU)
                append_elem(&stack, Token_Kind.BitOr)
                advance_token(parser)
            }
        } else if current == .RightParen {
            // Check for corresponding opening parenthesis
            if len(stack) == 0 || stack[len(stack)-1] != Token_Kind.LeftParen {
                error_at_current(parser, "Mismatched ')' in execution pattern")
                return nil
            }

            // Pop opening parenthesis from stack
            ordered_remove(&stack, len(stack)-1)
            advance_token(parser)
        } else if current == .GreaterThan {
            // Check for corresponding opening angle bracket
            if len(stack) == 0 || stack[len(stack)-1] != Token_Kind.LessThan {
                error_at_current(parser, "Mismatched '>' in execution pattern")
                return nil
            }

            // Pop opening angle bracket from stack
            ordered_remove(&stack, len(stack)-1)
            advance_token(parser)
        } else if current == .RightBracket {
            // Check for corresponding opening square bracket
            if len(stack) == 0 || stack[len(stack)-1] != Token_Kind.LeftBracket {
                error_at_current(parser, "Mismatched ']' in execution pattern")
                return nil
            }

            // Pop opening square bracket from stack
            ordered_remove(&stack, len(stack)-1)
            advance_token(parser)
        } else {
            // No more execution pattern tokens
            break
        }

        // If stack is empty and we found an exclamation mark, we're done
        if len(stack) == 0 && found_exclamation {
            break
        }
    }

    // Ensure we found an exclamation mark
    if !found_exclamation {
        error_at_current(parser, "Execution pattern must contain '!'")
        return nil
    }

    // Create and return execute node
    result := new(Node)
    result^ = execute^

    // Check if there's a new execution pattern immediately following
    if is_execution_pattern_start(parser.current_token.kind) {
        return parse_execution_pattern_postfix(parser, result)
    }

    return result
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
    print_ast(result, 0)
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

        // Parse statement with error recovery
        if parser.panic_mode {
            synchronize(parser)

            // After synchronizing, check if we're at the end of the scope
            if parser.current_token.kind == .RightBrace {
                break
            }
        }

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
 * parse_execute_prefix handles prefix execution with ! pattern (e.g., !expr)
 */
parse_execute_prefix :: proc(parser: ^Parser, can_assign: bool) -> ^Node {
    // Consume the !
    advance_token(parser)

    // Parse the expression to execute
    expr := parse_expression(parser, .UNARY)
    if expr == nil {
        error_at_current(parser, "Expected expression after '!'")
        return nil
    }

    // Create execute node with sequential execution
    execute := new(Execute)
    execute.value = expr
    execute.wrappers = make([dynamic]ExecutionWrapper)
    append_elem(&execute.wrappers, ExecutionWrapper.Sequential)

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
 * parse_execution handles execution modifiers with arbitrary compositions
 */
parse_execution :: proc(parser: ^Parser, left: ^Node, can_assign: bool) -> ^Node {
    // Parse the execution pattern
    wrappers, found_exclamation := parse_execution_pattern(parser)

    if !found_exclamation {
        error_at_current(parser, "Execution pattern must contain '!'")
        return nil
    }

    // Create execute node
    execute := new(Execute)
    execute.value = left
    execute.wrappers = wrappers

    result := new(Node)
    result^ = execute^
    return result
}

/*
 * parse_execution_pattern parses complex execution patterns recursively
 */
parse_execution_pattern :: proc(parser: ^Parser) -> (wrappers: [dynamic]ExecutionWrapper, found_exclamation: bool) {
    wrappers = make([dynamic]ExecutionWrapper)
    found_exclamation = false

    // Loop to handle nested/composed execution patterns
    for {
        // Save the current token
        current := parser.current_token.kind

        // Check for wrapper start tokens
        if current == .LeftParen {
            // Background wrapper
            append_elem(&wrappers, ExecutionWrapper.Background)  // Fixed append call
            advance_token(parser)

            // ... rest of the function ...
        } else if current == .LessThan {
            // Threading wrapper
            append_elem(&wrappers, ExecutionWrapper.Threading)  // Fixed append call
            advance_token(parser)

            // ... rest of the function ...
        } else if current == .LeftBracket {
            // Parallel CPU wrapper
            append_elem(&wrappers, ExecutionWrapper.Parallel_CPU)  // Fixed append call
            advance_token(parser)

            // ... rest of the function ...
        } else if current == .BitOr {
            // GPU wrapper
            append_elem(&wrappers, ExecutionWrapper.GPU)  // Fixed append call
            advance_token(parser)

            // ... rest of the function ...
        } else if current == .Execute {
            // Found the exclamation mark
            append_elem(&wrappers, ExecutionWrapper.Sequential)  // Fixed append call
            advance_token(parser)
            found_exclamation = true


            // Check if we need to continue parsing more
            next := parser.current_token.kind
            if !(next == .RightParen || next == .RightBracket ||
                next == .GreaterThan || next == .BitOr) {
                // We've reached the end of the execution pattern
                break
            }
        } else {
            // No more execution pattern tokens
            break
        }
    }

    return wrappers, found_exclamation
}


/*
 * parse_pointing_push handles pointing operator (a -> b)
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
 */
parse_constraint :: proc(parser: ^Parser, left: ^Node, can_assign: bool) -> ^Node {
    // Check if left is nil before proceeding
    if left == nil {
        error_at_current(parser, "Constraint requires a type before ':'")
        advance_token(parser) // Skip the colon
        return nil
    }

    // Create constraint
    constraint := new(Constraint)
    constraint.constraint = left

    // Move past :
    advance_token(parser)

    // Parse value if present, otherwise it's an empty constraint
    if parser.current_token.kind == .RightBrace ||
       parser.current_token.kind == .EOF ||
       parser.current_token.kind == .Newline {
        // Empty constraint (Type:)
        constraint.value = nil
    } else if is_expression_start(parser.current_token.kind) {
        // Constraint with value (Type: value)
        // Use a different precedence level to ensure constraints bind tighter than pointings
        if value := parse_expression(parser, .CALL); value != nil {
            constraint.value = value
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
 * parse_pattern handles pattern match (target ? {...})
 */
parse_pattern :: proc(parser: ^Parser, left: ^Node, can_assign: bool) -> ^Node {
    // Create pattern node with target
    pattern := new(Pattern)
    pattern.target = left
    pattern.value = make([dynamic]Branch)

    // Consume ? token
    advance_token(parser)

    // Skip newlines between ? and {
    skip_newlines(parser)

    // Expect opening brace
    if !match(parser, .LeftBrace) {
        error_at_current(parser, "Expected { after ? in pattern")
        return nil
    }

    // Skip newlines after opening brace
    skip_newlines(parser)

    // Handle empty pattern block
    for parser.current_token.kind != .RightBrace && parser.current_token.kind != .EOF {
      node := parse_branch(parser)
      if(node!=nil) {
        append(&pattern.value, node^)
      }
      skip_newlines(parser)
    }

    if !match(parser, .RightBrace) {
        error_at_current(parser, "Expected } after pattern branches")
        return nil
    }

    result := new(Node)
    result^ = pattern^
    return result
}

/*
 * parse_branch parses a single branch in a pattern match
 */
parse_branch :: proc(parser: ^Parser) -> ^Branch {
    // Don't try to parse a branch if we're at a token that can't start an expression
    if !is_expression_start(parser.current_token.kind) {
        advance_token(parser)  // Skip problematic token
        return nil
    }

    // Create branch
    branch := new(Branch)

    // Parse pattern expression (the left side of ->)
    if pattern := parse_expression(parser, ); pattern != nil {
      #partial switch parse in pattern {

      case Pointing:
        branch.source = parse.name
        branch.product = parse.value
        return branch
      case Constraint:
      if parse.value != nil {
          #partial switch value in parse.value {
          case Product:
            branch.product = value.value
            constraint := new(Constraint)
            constraint.constraint = parse.constraint
            result := new(Node)
            result^ = constraint^
            branch.source = result
            return branch
          }
        }
      }
      branch.source = pattern
    } else {
        // Error already reported
        return nil
    }

    // Expect pointing arrow for pattern branches
    if !match(parser, .PointingPush) {
        error_at_current(parser, "Expected -> in pattern branch")
        return nil
    }

    // Parse the result expression (right side of ->)
    if value := parse_expression(parser); value != nil {
        // Create product node to hold the result
        product := new(Product)
        product.value = value

        product_node := new(Node)
        product_node^ = product^
        branch.product = product_node
    } else {
        // Handle case where there's no expression after ->
        product := new(Product)
        product.value = nil

        product_node := new(Node)
        product_node^ = product^
        branch.product = product_node
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
    // Consume ellipsis token
    advance_token(parser)

    // Get the expression that follows with appropriate precedence
    // Use the UNARY precedence to ensure we get the entire expression
    target := parse_expression(parser, .UNARY)
    if target == nil {
        error_at_current(parser, "Expected expression after ...")
        return nil
    }

    // Create the expansion node with the target
    expand := new(Expand)
    expand.target = target

    result := new(Node)
    result^ = expand^
    return result
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
 * Helper function to check if a token can start an execution pattern
 */
is_execution_pattern_start :: proc(kind: Token_Kind) -> bool {
    return kind == .Execute || kind == .LeftParen || kind == .LessThan ||
           kind == .LeftBracket || kind == .BitOr
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
 * but preserves newline tokens for statement separation
 */
skip_whitespace :: proc(l: ^Lexer) {
    for l.position.offset < len(l.source) && is_space(l.source[l.position.offset]) {
        advance_position(l)
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
    fmt.printf("Current: %v '%s' at line %d, column %d\n",
               parser.current_token.kind,
               parser.current_token.text,
               parser.current_token.position.line,
               parser.current_token.position.column)

    fmt.printf("Peek: %v '%s' at line %d, column %d\n",
               parser.peek_token.kind,
               parser.peek_token.text,
               parser.peek_token.position.line,
               parser.peek_token.position.column)

    // Print a few tokens ahead
    fmt.println("\nUpcoming tokens:")

    // Create a temporary lexer and parser to scan ahead
    temp_lexer := parser.lexer^ // Make a copy of the lexer
    temp_parser: Parser
    init_parser(&temp_parser, &temp_lexer)

    // Advance to match the current state
    for temp_parser.current_token.position.offset < orig_current.position.offset &&
        temp_parser.current_token.kind != .EOF {
        advance_token(&temp_parser)
    }

    // Print the next 'count' tokens
    for i := 0; i < count && temp_parser.current_token.kind != .EOF; i += 1 {
        fmt.printf(
            "%d: %v '%s' at line %d, column %d\n",
            i + 1,
            temp_parser.current_token.kind,
            temp_parser.current_token.text,
            temp_parser.current_token.position.line,
            temp_parser.current_token.position.column
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
            if branch.source != nil {
                fmt.printf("%s      Pattern:\n", indent_str)
                print_ast(branch.source, indent + 8)
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
            fmt.printf("%s  Value:\n", indent_str)
            print_ast(n.value, indent + 4)
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
        // Build the pattern string with proper nesting
        pattern := ""

        // Count each wrapper type
        sequential_count := 0
        threading_open := 0
        parallel_open := 0
        background_open := 0
        gpu_open := 0

        // Count the wrappers
        for wrapper in n.wrappers {
            #partial switch wrapper {
            case .Sequential:
                sequential_count += 1
            case .Threading:
                threading_open += 1
            case .Parallel_CPU:
                parallel_open += 1
            case .Background:
                background_open += 1
            case .GPU:
                gpu_open += 1
            }
        }

        // Build pattern
        for i := 0; i < threading_open; i += 1 { pattern = strings.concatenate({pattern, "<"}) }
        for i := 0; i < parallel_open; i += 1 { pattern = strings.concatenate({pattern, "["}) }
        for i := 0; i < background_open; i += 1 { pattern = strings.concatenate({pattern, "("}) }
        for i := 0; i < gpu_open; i += 1 { pattern = strings.concatenate({pattern, "|"}) }

        // Add the exclamation mark
        pattern = strings.concatenate({pattern, "!"})

        // Add closing symbols
        for i := 0; i < gpu_open; i += 1 { pattern = strings.concatenate({pattern, "|"}) }
        for i := 0; i < background_open; i += 1 { pattern = strings.concatenate({pattern, ")"}) }
        for i := 0; i < parallel_open; i += 1 { pattern = strings.concatenate({pattern, "]"}) }
        for i := 0; i < threading_open; i += 1 { pattern = strings.concatenate({pattern, ">"}) }

        fmt.printf("%sExecute %s\n", indent_str, pattern)
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
    lexer: Lexer
    init_lexer(&lexer, string(source))

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
