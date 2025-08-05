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
import vmem "core:mem/virtual"

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
	Less, // <
	Greater, // >
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
	And, // &
	Or, // |
	Xor, // ^
	Not, // ~
  RShift, // >>
  LShift, // <<
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
    source:      string, // Source code being lexed
    position:    Position, // Current position in source (line, column, offset)
    peek_offset: int, // Lookahead for peeking at characters without advancing
    line_starts: []int, // Precomputed array of line start positions for faster line/column calculation
    source_len:  int, // Cache length to avoid repeated calls
}

/*
 * create_position creates a new Position struct
 */
create_position :: #force_inline proc(line, column, offset: int) -> Position {
    return Position{line = line, column = column, offset = offset}
}

/*
 * init_lexer initializes a lexer with the given source code with optimized line tracking
 */
init_lexer :: proc(l: ^Lexer, source: string) {
    l.source = source
    l.position = create_position(1, 1, 0) // Start at line 1, column 1
    l.peek_offset = 0
    l.source_len = len(source)

    // Pre-compute line starts for faster line/column calculation
    // This is a significant optimization for large files
    line_count := 1 // At least one line
    for i := 0; i < l.source_len; i += 1 {
        if source[i] == '\n' {
            line_count += 1
        }
    }

    // Allocate and initialize line starts array
    l.line_starts = make([]int, line_count, context.allocator)
    l.line_starts[0] = 0 // First line starts at offset 0

    line_idx := 1
    for i := 0; i < l.source_len; i += 1 {
        if source[i] == '\n' && line_idx < line_count {
            l.line_starts[line_idx] = i + 1
            line_idx += 1
        }
    }
}

/*
 * current_char returns the current character without advancing
 */
current_char :: #force_inline proc(l: ^Lexer) -> u8 {
    if l.position.offset >= l.source_len {
        return 0
    }
    return l.source[l.position.offset]
}

/*
 * peek_char looks ahead by n characters without advancing
 */
peek_char :: #force_inline proc(l: ^Lexer, n: int = 1) -> u8 {
    peek_pos := l.position.offset + n
    if peek_pos >= l.source_len {
        return 0
    }
    return l.source[peek_pos]
}

/*
 * advance_position moves the lexer position forward by one character,
 * using precomputed line starts for faster line/column updates
 */
advance_position :: #force_inline proc(l: ^Lexer) {
    if l.position.offset < l.source_len {
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
 * Optimized to avoid excessive function calls
 */
advance_by :: #force_inline proc(l: ^Lexer, n: int) {
    if n <= 0 do return

    for i := 0; i < n && l.position.offset < l.source_len; i += 1 {
        // Direct inlining of advance_position for speed
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
 * match_char checks if the current character matches expected
 * and advances if it does, returning true on match
 */
match_char :: #force_inline proc(l: ^Lexer, expected: u8) -> bool {
    if l.position.offset >= l.source_len || l.source[l.position.offset] != expected {
        return false
    }
    advance_position(l)
    return true
}

/*
 * match_str checks if the string at current position matches expected
 * and advances by the length of the string if it does
 */
match_str :: proc(l: ^Lexer, expected: string) -> bool {
    if l.position.offset + len(expected) > l.source_len {
        return false
    }

    for i := 0; i < len(expected); i += 1 {
        if l.source[l.position.offset + i] != expected[i] {
            return false
        }
    }

    advance_by(l, len(expected))
    return true
}

/*
 * next_token scans and returns the next token from the input source
 * Optimized for speed by reducing function calls and using direct pattern matching
 */
next_token :: proc(l: ^Lexer) -> Token {
    skip_whitespace(l)

    if l.position.offset >= l.source_len {
        return Token{kind = .EOF, position = l.position}
    }

    start_pos := l.position
    c := l.source[l.position.offset]

    // Use a jump table approach for faster dispatch
    switch c {
    case '\n':
        return scan_newline(l, start_pos)
    case '`', '"', '\'':
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
        // Optimized to use direct character checks instead of function calls
        if l.position.offset + 1 < l.source_len && l.source[l.position.offset + 1] == '.' {
            advance_by(l, 2) // Skip ".."

            // Check for ellipsis "..."
            if l.position.offset < l.source_len && l.source[l.position.offset] == '.' {
                advance_position(l)
                return Token{kind = .Ellipsis, text = "...", position = start_pos}
            }

            // Check for prefix range "..1"
            if l.position.offset < l.source_len && is_digit(l.source[l.position.offset]) {
                start_num := l.position.offset
                for l.position.offset < l.source_len && is_digit(l.source[l.position.offset]) {
                    advance_position(l)
                }
                return Token{kind = .PrefixRange, text = l.source[start_pos.offset:l.position.offset], position = start_pos}
            }

            return Token{kind = .DoubleDot, text = "..", position = start_pos}
        }

        advance_position(l)
        return Token{kind = .Dot, text = ".", position = start_pos}
    case '=':
        // Optimized equality check
        advance_position(l)
        if l.position.offset < l.source_len && l.source[l.position.offset] == '=' {
            advance_position(l)
            return Token{kind = .Equal, text = "==", position = start_pos}
        }
        return Token{kind = .Equal, text = "=", position = start_pos}
    case '<':
        // Optimized less-than related tokens
        advance_position(l)
        if l.position.offset < l.source_len {
            if l.source[l.position.offset] == '=' {
                advance_position(l)
                return Token{kind = .LessEqual, text = "<=", position = start_pos}
            } else if l.source[l.position.offset] == '<' {
                advance_position(l)
                return Token{kind = .LShift, text = "<<", position = start_pos}
            } else if l.source[l.position.offset] == '-' {
                advance_position(l)
                return Token{kind = .PointingPull, text = "<-", position = start_pos}
            }
        }
        return Token{kind = .Less, text = "<", position = start_pos}
    case '>':
        // Optimized greater-than related tokens
        advance_position(l)
        if l.position.offset < l.source_len {
            if l.source[l.position.offset] == '=' {
                advance_position(l)
                return Token{kind = .GreaterEqual, text = ">=", position = start_pos}
            } else if l.source[l.position.offset] == '>' {
              if  l.source[l.position.offset + 1] == '-' {
                advance_by(l, 2)
                return Token{kind = .ResonancePush, text = ">>-", position = start_pos}
              }
              advance_position(l)
              return Token{kind = .RShift, text = ">>", position = start_pos}
            } else if l.source[l.position.offset] == '-' {
                advance_position(l)
                return Token{kind = .EventPush, text = ">-", position = start_pos}
            }
        }
        return Token{kind = .Greater, text = ">", position = start_pos}
    case '-':
        // Optimized minus-related tokens
        advance_position(l)
        if l.position.offset < l.source_len {
            if l.source[l.position.offset] == '>' {
                advance_position(l)
                return Token{kind = .PointingPush, text = "->", position = start_pos}
            } else if l.source[l.position.offset] == '<' {
                advance_position(l)
                if l.position.offset < l.source_len && l.source[l.position.offset] == '<' {
                    advance_position(l)
                    return Token{kind = .ResonancePull, text = "-<<", position = start_pos}
                }
                return Token{kind = .EventPull, text = "-<", position = start_pos}
            }
        }
        return Token{kind = .Minus, text = "-", position = start_pos}
    case '/':
        // Single line comment - optimized with direct string matching
        if l.position.offset + 1 < l.source_len && l.source[l.position.offset + 1] == '/' {
            advance_by(l, 2)

            // Consume until newline
            for l.position.offset < l.source_len && l.source[l.position.offset] != '\n' {
                advance_position(l)
            }

            // Recursive call to get the next non-comment token
            return next_token(l)
        }

        // Multiplyi line comment
        if l.position.offset + 1 < l.source_len && l.source[l.position.offset + 1] == '*' {
            advance_by(l, 2)

            // Scan for */
            loop: for l.position.offset + 1 < l.source_len {
                if l.source[l.position.offset] == '*' && l.source[l.position.offset + 1] == '/' {
                    advance_by(l, 2) // Skip closing */
                    break loop
                }
                advance_position(l)
            }

            // Recursive call to get the next non-comment token
            return next_token(l)
        }

        advance_position(l)
        return Token{kind = .Slash, text = "/", position = start_pos}
    case '0':
        // Special number formats (hex, binary)
        if l.position.offset + 1 < l.source_len {
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
        return Token{kind = .And, text = "&", position = start_pos}
    case '|':
        advance_position(l)
        return Token{kind = .Or, text = "|", position = start_pos}
    case '^':
        advance_position(l)
        return Token{kind = .Xor, text = "^", position = start_pos}
    case '~':
        advance_position(l)
        return Token{kind = .Not, text = "~", position = start_pos}
    case:
        // Identifiers - optimized with direct character range checks
        if is_alpha(c) || c == '_' {
            // Fast path for identifiers
            advance_position(l)

            // Consume all alphanumeric characters
            for l.position.offset < l.source_len && is_alnum(l.source[l.position.offset]) {
                advance_position(l)
            }

            return Token{kind = .Identifier, text = l.source[start_pos.offset:l.position.offset], position = start_pos}
        }

        // Unknown character
        advance_position(l)
        return Token{kind = .Invalid, text = string([]u8{c}), position = start_pos}
    }
}

/*
 * scan_newline processes consecutive newline characters
 * Optimized with a direct loop instead of recursive function calls
 */
scan_newline :: #force_inline proc(l: ^Lexer, start_pos: Position) -> Token {
    // Consume first newline
    advance_position(l)

    // Consume all consecutive newlines
    for l.position.offset < l.source_len && l.source[l.position.offset] == '\n' {
        advance_position(l)
    }

    return Token{kind = .Newline, text = "\\n", position = start_pos}
}

/*
 * scan_string processes a string literal enclosed in provided delimiter
 * Optimized for speed with fewer function calls
 */
scan_string :: proc(l: ^Lexer, start_pos: Position) -> Token {
    delimiter := l.source[l.position.offset]
    // Skip opening delimiter
    advance_position(l)
    str_start := l.position.offset

    // Fast path: scan without escapes
    // This optimization significantly improves performance for strings without escape sequences
    escape_found := false
    for l.position.offset < l.source_len {
        current := l.source[l.position.offset]

        if current == delimiter {
            break
        }

        if current == '\\' {
            escape_found = true
            break
        }

        advance_position(l)
    }

    // If we found an escape sequence, handle the more complex path
    if escape_found {
        for l.position.offset < l.source_len && l.source[l.position.offset] != delimiter {
            // Handle escapes
            if l.source[l.position.offset] == '\\' && l.position.offset + 1 < l.source_len {
                advance_by(l, 2)  // Skip the escape sequence
            } else {
                advance_position(l)
            }
        }
    }

    if l.position.offset < l.source_len {
        text := l.source[str_start:l.position.offset]
        advance_position(l) // Skip closing delimiter
        return Token{kind = .String_Literal, text = text, position = start_pos}
    }

    return Token{kind = .Invalid, text = "Unterminated string", position = start_pos}
}

/*
 * scan_hexadecimal processes hexadecimal number literals
 * Optimized with direct character checks
 */
scan_hexadecimal :: #force_inline proc(l: ^Lexer, start_pos: Position) -> Token {
    // Skip "0x" prefix
    advance_by(l, 2)
    hex_start := l.position.offset

    // Fast path: use a tight loop to consume all hex digits
    for l.position.offset < l.source_len && is_hex_digit(l.source[l.position.offset]) {
        advance_position(l)
    }

    if l.position.offset == hex_start {
        return Token{kind = .Invalid, text = "Invalid hexadecimal number", position = start_pos}
    }

    return Token{kind = .Hexadecimal, text = l.source[start_pos.offset:l.position.offset], position = start_pos}
}

/*
 * scan_binary processes binary number literals
 * Optimized with direct character checks
 */
scan_binary :: #force_inline proc(l: ^Lexer, start_pos: Position) -> Token {
    // Skip "0b" prefix
    advance_by(l, 2)
    bin_start := l.position.offset

    // Fast path: use tight loop for binary digits
    for l.position.offset < l.source_len {
        c := l.source[l.position.offset]
        if c != '0' && c != '1' {
            break
        }
        advance_position(l)
    }

    if l.position.offset == bin_start {
        return Token{kind = .Invalid, text = "Invalid binary number", position = start_pos}
    }

    return Token{kind = .Binary, text = l.source[start_pos.offset:l.position.offset], position = start_pos}
}

/*
 * scan_number processes numeric literals and range notations
 * Optimized to use direct character checks for different paths
 */
scan_number :: proc(l: ^Lexer, start_pos: Position) -> Token {
    // Parse integer part with fast path
    for l.position.offset < l.source_len && is_digit(l.source[l.position.offset]) {
        advance_position(l)
    }

    // Check for range notation (e.g., 1..5)
    if l.position.offset + 1 < l.source_len &&
       l.source[l.position.offset] == '.' &&
       l.source[l.position.offset + 1] == '.' {

        advance_by(l, 2) // Skip the '..'

        // Check if there's a number after, making it a full range (1..5)
        if l.position.offset < l.source_len && is_digit(l.source[l.position.offset]) {
            for l.position.offset < l.source_len && is_digit(l.source[l.position.offset]) {
                advance_position(l)
            }
            return Token{kind = .Range, text = l.source[start_pos.offset:l.position.offset], position = start_pos}
        }

        // Just a postfix range (1..)
        return Token{kind = .PostfixRange, text = l.source[start_pos.offset:l.position.offset], position = start_pos}
    }

    // Check for floating point
    if l.position.offset < l.source_len && l.source[l.position.offset] == '.' {
        if l.position.offset + 1 < l.source_len && is_digit(l.source[l.position.offset + 1]) {
            advance_position(l) // Skip the '.'

            // Fast path for decimal digits
            for l.position.offset < l.source_len && is_digit(l.source[l.position.offset]) {
                advance_position(l)
            }

            return Token{kind = .Float, text = l.source[start_pos.offset:l.position.offset], position = start_pos}
        }
    }

    return Token{kind = .Integer, text = l.source[start_pos.offset:l.position.offset], position = start_pos}
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
	ScopeNode,
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
	External,
  Range,
}

NodeBase :: struct {
  position: Position, // Position information for error reporting
}

/*
 * Base struct containing common fields for all pointing types
 */
PointingBase :: struct {
  using _: NodeBase,
  name:     ^Node, // Name of the pointing
  value:    ^Node, // Value being pointed to/from
}

/*
 * Pointing represents a pointing declaration (name -> value)
 */
Pointing :: struct {
  using _: PointingBase,
}

/*
 * Pointing pull is a declaration later override derived value
 */
PointingPull :: struct {
  using _: PointingBase,
}

/*
 * EventPull represents a event being pull from resonance >-
 */
EventPull :: struct {
  using _: PointingBase,
}

/*
 * EventPush represents a event being pushed into resonance -
 */
EventPush :: struct {
  using _: PointingBase,
}

/*
 * ResonancePull is useed to change value of resonance driven -
 */
ResonancePull :: struct {
  using _: PointingBase,
}

/*
 * ResonancePush is useed to drive resonance >>-
 */
ResonancePush :: struct {
  using _: PointingBase,
}

/*
 * Identifier represents a named reference
 */
Identifier :: struct {
  using _: NodeBase,
	name:     string, // Name of the identifier
	parenthesized:  bool,   // True if the identifier was written as (name)
}

/*
 * ScopeNode represents a block of statements enclosed in braces
 */
ScopeNode :: struct {
  using _: NodeBase,
	value:    [dynamic]Node, // Statements in the scope
}

/*
 * Override represents modifications to a base entity
 */
Override :: struct {
  using _: NodeBase,
	source:    ^Node, // Base entity being modified
	overrides: [dynamic]Node, // Modifications
}

/*
 * Product represents a produced value (-> expr)
 */
Product :: struct {
  using _: NodeBase,
	value:    ^Node, // Value produced
}

/*
 * Pattern represents a pattern match expression
 */
Pattern :: struct {
  using _: NodeBase,
	target:   ^Node, // Value to match against
	value:    [dynamic]Branch, // Pattern branches
}

/*
 * Branch represents a single pattern match branch
 */
Branch :: struct {
  using _: NodeBase,
	source:   ^Node, // Pattern to match
	product:  ^Node, // Result if pattern matches
}

/*
 * Constraint represents a type constraint (Type: value)
 */
Constraint :: struct {
  using _: NodeBase,
	constraint: ^Node, // Type constraint
	value:      ^Node, // Optional value
}

/*
 * ExecutionWrapper represents a single wrapper in a potentially nested execution pattern
 */
ExecutionWrapper :: enum {
  Threading,       // < >
  Parallel_CPU,    // [ ]
  Background,      // ( )
  GPU,             // | |
}

/*
 * Execute represents an execution modifier
 */
Execute :: struct {
  using _: NodeBase,
  value:    ^Node,                     // Expression to execute
  wrappers: [dynamic]ExecutionWrapper, // Ordered list of execution wrappers (from outside to inside)
}

/*
 * Operator_Kind defines the types of operators
 */
Operator_Kind :: enum {
	Add,
	Subtract,
	Multiply,
	Divide,
	Mod, // For %
	Equal,
	Less,
	Greater,
  NotEqual,
	LessEqual,
	GreaterEqual,
	And, // &
	Or, // |
	Xor, // ^
	Not, // ~
  RShift, // >>
  LShift, // <<
}

/*
 * Operator represents a binary operation
 */
Operator :: struct {
  using _: NodeBase,
	kind:     Operator_Kind, // Type of operation
	left:     ^Node, // Left operand
	right:    ^Node, // Right operand
}

/*
 * Literal_Kind defines the types of literal values
 */
Literal_Kind :: enum {
	Integer,
	Float,
	String,
  Bool,
	Hexadecimal,
	Binary,
}

/*
 * Literal represents a literal value in the source
 */
Literal :: struct {
  using _: NodeBase,
	kind:     Literal_Kind, // Type of literal
	value:    string, // String representation of the value
}

/*
 * Property represents a property access (a.b)
 */
Property :: struct {
  using _: NodeBase,
	source:   ^Node, // Object being accessed
	property: ^Node, // Property being accessed
}

/*
 * Expand represents a content expansion (...expr)
 */
Expand :: struct {
  using _: NodeBase,
	target:   ^Node, // Content to expand
}

/*
 * External represents an external reference (@lib.geometry)
 */
External :: struct {
  using _: NodeBase,
  name:    string, // Name of the ref
	scope:   ^Node, // The external scope to be resolved
}

/*
 * Range represents a range expression (e.g., 1..5, 1.., ..5)
 */
Range :: struct {
  using _: NodeBase,
	start:    ^Node, // Start of range (may be nil for prefix range)
	end:      ^Node, // End of range (may be nil for postfix range)
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
 * Error_Type defines the type of parsing error encountered
 */
Parser_Error_Type :: enum {
    Syntax,           // Basic syntax errors
    Unexpected_Token, // Token didn't match what was expected
    Invalid_Expression, // Expression is malformed
    Unclosed_Delimiter, // Missing closing delimiter
    Invalid_Operation, // Operations not supported on types
    External_Error,  // Reference to undefined identifier
    Other,            // Other errors
}

/*
 * Parse_Error represents a detailed error encountered during parsing
 */
Parse_Error :: struct {
    type:     Parser_Error_Type,    // Type of error for categorization
    message:  string,        // Error message
    position: Position,      // Position where error occurred
    token:    Token,         // Token involved in the error
    expected: Token_Kind,    // The expected token kind (if applicable)
    found:    Token_Kind,    // The actual token kind found (if applicable)
}

/*
 * Parser maintains state during parsing
 */
Parser :: struct {
    file_cache:     ^Cache,
    lexer:           ^Lexer, // Lexer providing tokens
    current_token:   Token, // Current token being processed
    peek_token:      Token, // Next token (lookahead)
    panic_mode:      bool, // Flag for panic mode error recovery

    // Error tracking
    errors:     [dynamic]Parse_Error,
}

/*
 * initialize_parser sets up a parser with a lexer
 */
init_parser :: proc(cache: ^Cache, source: string) -> ^Parser{
  parser := new(Parser)
    parser.file_cache = cache
    parser.lexer = new(Lexer)
    init_lexer(parser.lexer, source)
  parser.panic_mode = false

    // Initialize with first two tokens
    parser.current_token = next_token(parser.lexer)
    parser.peek_token = next_token(parser.lexer)
    return parser
}

/*
 * advance_token moves to the next token in the stream
 */
advance_token :: #force_inline proc(parser: ^Parser) {
    parser.current_token = parser.peek_token
    parser.peek_token = next_token(parser.lexer)
}

/*
 * check checks if the current token has the expected kind without advancing
 */
check :: #force_inline proc(parser: ^Parser, kind: Token_Kind) -> bool {
    return parser.current_token.kind == kind
}

/*
 * match checks if the current token has the expected kind and advances if true
 */
match :: #force_inline proc(parser: ^Parser, kind: Token_Kind) -> bool {
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
expect_token :: #force_inline proc(parser: ^Parser, kind: Token_Kind) -> bool {
    if check(parser, kind) {
        advance_token(parser)
        return true
    }

    error_at_current(parser, fmt.tprintf("Expected %v but got %v", kind, parser.current_token.kind))
    return false
}

/*
 * error_at_current creates an error record for the current token
 */
error_at_current :: #force_inline proc(parser: ^Parser, message: string, error_type: Parser_Error_Type = .Syntax, expected: Token_Kind = .Invalid) {
    error_at(parser, parser.current_token, message, error_type, expected)
}


/*
 * error_at creates a detailed error record at a specific token
 */
error_at :: proc(parser: ^Parser, token: Token, message: string, error_type: Parser_Error_Type = .Syntax, expected: Token_Kind = .Invalid) {
    // Don't report errors in panic mode to avoid cascading
    if parser.panic_mode do return

    // Enter panic mode
    parser.panic_mode = true

    // Create detailed error record
    error := Parse_Error{
        type = error_type,
        message = message,
        position = token.position,
        token = token,
        expected = expected,
        found = token.kind,
    }

    // Add to errors list
    append(&parser.errors, error)
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
 * get_rule returns the parse rule for a given token kind
 */
get_rule :: #force_inline proc(kind: Token_Kind) -> Parse_Rule {
    #partial switch kind {
    // Integer and Float Literals
    case .Integer:
        return Parse_Rule{prefix = parse_literal, infix = nil, precedence = .NONE}
    case .Float:
        return Parse_Rule{prefix = parse_literal, infix = nil, precedence = .NONE}
    case .Hexadecimal:
        return Parse_Rule{prefix = parse_literal, infix = nil, precedence = .NONE}
    case .Binary:
        return Parse_Rule{prefix = parse_literal, infix = nil, precedence = .NONE}
    case .String_Literal:
        return Parse_Rule{prefix = parse_literal, infix = nil, precedence = .NONE}

    // Identifiers and basic symbols
    case .Identifier:
        return Parse_Rule{prefix = parse_identifier, infix = nil, precedence = .NONE}
    case .LeftBrace:
        return Parse_Rule{prefix = parse_scope, infix = parse_override, precedence = .CALL}
    case .LeftBracket:
        return Parse_Rule{prefix = nil, infix = parse_left_bracket, precedence = .CALL}
    case .LeftParen:
        return Parse_Rule{prefix = parse_grouping, infix = parse_left_paren, precedence = .CALL}
    case .RightBrace:
        return Parse_Rule{prefix = nil, infix = nil, precedence = .NONE}
    case .At:
        return Parse_Rule{prefix = parse_reference, infix = nil, precedence = .NONE}

    // Unary operators
    case .Not:
        return Parse_Rule{prefix = parse_unary, infix = nil, precedence = .UNARY}
    case .Minus:
        return Parse_Rule{prefix = parse_unary, infix = parse_binary, precedence = .TERM}


    // Postfix operator
    case .Execute:
    return Parse_Rule{prefix = nil, infix = parse_execute, precedence = .CALL}


    // Binary operators
    case .Plus:
        return Parse_Rule{prefix = nil, infix = parse_binary, precedence = .TERM}
    case .Asterisk:
        return Parse_Rule{prefix = nil, infix = parse_binary, precedence = .FACTOR}
    case .Slash:
        return Parse_Rule{prefix = nil, infix = parse_binary, precedence = .FACTOR}
    case .Percent:
        return Parse_Rule{prefix = nil, infix = parse_binary, precedence = .FACTOR}
    case .And:
        return Parse_Rule{prefix = nil, infix = parse_binary, precedence = .BITWISE}
    case .Or:
        return Parse_Rule{prefix = nil, infix = parse_bit_or, precedence = .BITWISE}
    case .Xor:
        return Parse_Rule{prefix = nil, infix = parse_binary, precedence = .BITWISE}
    case .RShift:
        return Parse_Rule{prefix = nil, infix = parse_binary, precedence = .BITWISE}
    case .LShift:
        return Parse_Rule{prefix = nil, infix = parse_binary, precedence = .BITWISE}
    case .Equal:
        return Parse_Rule{prefix = nil, infix = parse_binary, precedence = .EQUALITY}
    case .Less:
        return Parse_Rule{prefix = nil, infix = parse_less_than, precedence = .COMPARISON}
    case .Greater:
        return Parse_Rule{prefix = nil, infix = parse_binary, precedence = .COMPARISON}
    case .LessEqual:
        return Parse_Rule{prefix = nil, infix = parse_binary, precedence = .COMPARISON}
    case .GreaterEqual:
        return Parse_Rule{prefix = nil, infix = parse_binary, precedence = .COMPARISON}

    // Specialized operators
    case .Colon:
        return Parse_Rule{prefix = nil, infix = parse_constraint, precedence = .PRIMARY}

    // Assignment operators
    case .PointingPush:
        return Parse_Rule{prefix = parse_product_prefix, infix = parse_pointing_push, precedence = .ASSIGNMENT}
    case .PointingPull:
        return Parse_Rule{prefix = parse_pointing_pull_prefix, infix = parse_pointing_pull, precedence = .ASSIGNMENT}
    case .EventPush:
        return Parse_Rule{prefix = parse_event_push_prefix, infix = parse_event_push, precedence = .ASSIGNMENT}
    case .EventPull:
        return Parse_Rule{prefix = parse_event_pull_prefix, infix = parse_event_pull, precedence = .ASSIGNMENT}
    case .ResonancePush:
        return Parse_Rule{prefix = parse_resonance_push_prefix, infix = parse_resonance_push, precedence = .ASSIGNMENT}
    case .ResonancePull:
        return Parse_Rule{prefix = parse_resonance_pull_prefix, infix = parse_resonance_pull, precedence = .ASSIGNMENT}


    // Range notation
    case .DoubleDot:
        return Parse_Rule{prefix = parse_prefix_range, infix = parse_range, precedence = .RANGE}

    // Special cases
    case .Dot:
        return Parse_Rule{prefix = parse_prefix_property, infix = parse_property, precedence = .CALL}
    case .Question:
        return Parse_Rule{prefix = nil, infix = parse_pattern, precedence = .CALL}
    case .Ellipsis:
        return Parse_Rule{prefix = parse_expansion, infix = nil, precedence = .PRIMARY}
    }
    return Parse_Rule{} // Default empty rule
}

/*
 * parse program parses the entire program as a sequence of statements
 */
parse:: proc(cache: ^Cache, source: string) -> ^Node {
    parser := init_parser(cache, source)
    // Store the position of the first token
    position := parser.current_token.position

    scope := ScopeNode{
        value = make([dynamic]Node, 0, 2),
        position = position, // Store position
    }

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
    result^ = scope
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
    if parser.current_token.kind == .Newline {
        advance_token(parser)
        return nil
    }

    if parser.current_token.kind == .EOF || parser.current_token.kind == .RightBrace {
        // Acceptable empty statements — BUT force advancement
        advance_token(parser)
        return nil
    }

    expr := parse_expression(parser)

    // Defensive: ensure we're not stuck
    if expr == nil && parser.current_token.kind == .RightBrace {
        error_at_current(parser, "Unexpected }")
        advance_token(parser)
        return nil
    }

    return expr
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

    if left == nil {
        return nil
    }

    // Keep parsing infix expressions as long as they have higher precedence
    for {
        // Check if we should skip newlines to find a continuation operator
        if parser.current_token.kind == .Newline {
            // Look ahead past newlines to see if there's a ? operator
            saved_position := parser.lexer.position
            saved_current := parser.current_token
            saved_peek := parser.peek_token

            // Skip newlines
            for parser.current_token.kind == .Newline {
                advance_token(parser)
            }

            // Check if we have a ? operator that should continue the expression
            if parser.current_token.kind == .Question {
                // Great! We found a continuation operator, keep the newlines skipped
                // and continue with normal precedence checking
            } else {
                // No continuation operator, restore position and break
                parser.lexer.position = saved_position
                parser.current_token = saved_current
                parser.peek_token = saved_peek
                break
            }
        }

        // Normal precedence checking
        current_precedence := get_rule(parser.current_token.kind).precedence
        if precedence > current_precedence {
            break
        }

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
* Implementation of the override postfix rule
*/
parse_override :: proc(parser: ^Parser, left: ^Node, can_assign: bool) -> ^Node {
    // Save position of the left brace
    position := parser.current_token.position

    // Create an override node
    override := Override {
        source = left,
        overrides = make([dynamic]Node, 0, 2),
        position = position, // Store position
    }

    // Consume left brace (already checked by the caller)
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

    // Create and return the override node
    result := new(Node)
    result^ = override
    return result
}

/*
 * parse_execute handles postfix execution patterns like expr<[!]>
 */
parse_execute :: proc(parser: ^Parser, left: ^Node, can_assign: bool) -> ^Node {
    // Save position of the ! token
    position := parser.current_token.position

    // Create execute node
    execute := Execute{
        value = left,
        wrappers = make([dynamic]ExecutionWrapper, 0, 0),
        position = position,
    }

    // Consume the ! token
    advance_token(parser)

    // Create and return execute node
    result := new(Node)
    result^ = execute
    return result
}

/*
 * parse_product_prefix handles the standalone product expression (-> value)
 */
parse_product_prefix :: proc(parser: ^Parser, can_assign: bool) -> ^Node {
    // Save position of the -> token
    position := parser.current_token.position

    // Consume the ->
    advance_token(parser)

    product := Product{
        position = position, // Store position
    }

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
    result^ = product
    return result
}

/*
 * parse_literal handles literal values (numbers, strings)
 */
parse_literal :: proc(parser: ^Parser, can_assign: bool) -> ^Node {
    // Save position of the literal token
    position := parser.current_token.position

    literal := Literal {
      value = parser.current_token.text,
      position = position, // Store position
    }

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
    result^ = literal
    return result
}

/*
 * parse_identifier handles identifier expressions
 */
parse_identifier :: proc(parser: ^Parser, can_assign: bool) -> ^Node {
    // Save position of the identifier token
    position := parser.current_token.position

    // Create identifier node
    id_node := new(Node)
    id_node^ = Identifier{
        name = parser.current_token.text,
        position = position, // Store position
        parenthesized = false,
    }

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
    // Save position of the left brace
    position := parser.current_token.position

    // Consume opening brace
    advance_token(parser)

    scope := ScopeNode{
        value = make([dynamic]Node, 0, 2),
        position = position, // Store position
    }

    // Allow for empty scopes
    if parser.current_token.kind == .RightBrace {
        advance_token(parser)
        result := new(Node)
        result^ = scope
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
    result^ = scope
    return result
}

/*
 * parse_grouping parses grouping expressions (...)
 * If it's (identifier), treat it as parenthesized identifier
 */
parse_grouping :: proc(parser: ^Parser, can_assign: bool) -> ^Node {
    // Save position of the opening parenthesis
    position := parser.current_token.position

    // Consume opening parenthesis
    advance_token(parser)

    // Check if it's the simple case: (identifier)
    if parser.current_token.kind == .Identifier {
        identifier_name := parser.current_token.text
        identifier_pos := parser.current_token.position


        // Look ahead to see if there's a closing paren right after
        if parser.peek_token.kind == .RightParen {
            // It's (identifier) - consume both tokens
            advance_token(parser) // consume identifier
            advance_token(parser) // consume )

            // Return the identifier marked as parenthesized
            id_node := new(Node)
            id_node^ = Identifier{
                name = identifier_name,
                position = identifier_pos,
                parenthesized = true,
            }
            return id_node
        }
    }

    // Not the simple (identifier) case - parse as normal expression
    expr := parse_expression(parser)
    if expr == nil {
        // Handle empty parentheses gracefully
        if parser.current_token.kind == .RightParen {
            advance_token(parser)
            empty_scope := new(Node)
            empty_scope^ = ScopeNode{
                value = make([dynamic]Node, 0, 2),
                position = position,
            }
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
 * Parse bitwise or with disambiguation for GPU execution
 */
parse_bit_or :: proc(parser: ^Parser, left: ^Node, can_assign: bool) -> ^Node {
    // Try to parse as an execution pattern
    if node, is_execution := try_parse_wrapped_execute(parser, left); is_execution {
        return node
    }

    // Otherwise, parse as normal binary operator
    position := parser.current_token.position
    advance_token(parser) // Consume |

    // Get precedence rule for Or
    precedence := Precedence.BITWISE

    // Parse right operand with higher precedence
    right := parse_expression(parser, Precedence(int(precedence) + 1))
    if right == nil {
        error_at_current(parser, "Expected expression after '|'")
        return nil
    }

    // Create operator node
    op := Operator{
        kind = .Or,
        left = left,
        right = right,
        position = position,
    }

    result := new(Node)
    result^ = op
    return result
}

/*
 * try_parse_wrapped_execute attempts to parse an execute wrapped.
 * If successful, it returns the Execute node and true.
 * If not an execution pattern, it returns nil and false and leaves the parser position unchanged.
 */
try_parse_wrapped_execute :: proc(parser: ^Parser, left: ^Node) -> (^Node, bool) {
   // Save original parser position to restore if this isn't an execution pattern
    original_position := parser.lexer.position
    original_current := parser.current_token
    original_peek := parser.peek_token

    // Stack to track opening symbols for proper nesting
    stack := make([dynamic]Token_Kind)
    defer delete(stack)

    // Create execute node
    execute := Execute{
        value = left,
        wrappers = make([dynamic]ExecutionWrapper, 0, 4),
        position = parser.current_token.position,
    }

    // Process the execution pattern
    found_exclamation := false

    // Continue parsing until we have a complete execution pattern
    for {
        current := parser.current_token.kind

        #partial switch current {
        case .Execute:
            // Add sequential execution wrapper
            found_exclamation = true
            advance_token(parser)

        case .LeftParen:
            // Start of background execution
            append_elem(&execute.wrappers, ExecutionWrapper.Background)
            append_elem(&stack, Token_Kind.LeftParen)
            advance_token(parser)

        case .Less:
            // Start of threading execution
            append_elem(&execute.wrappers, ExecutionWrapper.Threading)
            append_elem(&stack, Token_Kind.Less)
            advance_token(parser)

        case .LeftBracket:
            // Start of parallel CPU execution
            append_elem(&execute.wrappers, ExecutionWrapper.Parallel_CPU)
            append_elem(&stack, Token_Kind.LeftBracket)
            advance_token(parser)

        case .Or:
            // Check if it's an opening or closing Or
            if len(stack) > 0 && stack[len(stack)-1] == Token_Kind.Or {
                // Closing Or, pop from stack
                ordered_remove(&stack, len(stack)-1)
                advance_token(parser)
            } else {
                // Opening Or, push to stack
                append_elem(&execute.wrappers, ExecutionWrapper.GPU)
                append_elem(&stack, Token_Kind.Or)
                advance_token(parser)
            }

        case .RightParen:
            // Check for corresponding opening parenthesis
            if len(stack) == 0 || stack[len(stack)-1] != Token_Kind.LeftParen {
                error_at_current(parser, "Mismatched ')' in execution pattern")
                parser.lexer.position = original_position
                parser.current_token = original_current
                parser.peek_token = original_peek
                return nil, false
            }

            // Pop opening parenthesis from stack
            ordered_remove(&stack, len(stack)-1)
            advance_token(parser)

        case .Greater:
            // Check for corresponding opening angle bracket
            if len(stack) == 0 || stack[len(stack)-1] != Token_Kind.Less {
                error_at_current(parser, "Mismatched '>' in execution pattern")
                parser.lexer.position = original_position
                parser.current_token = original_current
                parser.peek_token = original_peek
                return nil, false
            }

            // Pop opening angle bracket from stack
            ordered_remove(&stack, len(stack)-1)
            advance_token(parser)

        case .RightBracket:
            // Check for corresponding opening square bracket
            if len(stack) == 0 || stack[len(stack)-1] != Token_Kind.LeftBracket {
                error_at_current(parser, "Mismatched ']' in execution pattern")
                parser.lexer.position = original_position
                parser.current_token = original_current
                parser.peek_token = original_peek
                return nil, false
            }

            // Pop opening square bracket from stack
            ordered_remove(&stack, len(stack)-1)
            advance_token(parser)

        case:
          if !found_exclamation {
            return nil, false
          }
            break
        }

        // If stack is empty and we found an exclamation mark, we're done
        if len(stack) == 0 {
          if found_exclamation {
            break
          } else {
            return nil, false
          }
        }
    }

    // Verify we've found an exclamation mark and all opening tokens have been closed
    if !found_exclamation {
        error_at_current(parser, "Execution pattern must contain '!'")
        parser.lexer.position = original_position
        parser.current_token = original_current
        parser.peek_token = original_peek
        return nil, false
    }

    if len(stack) > 0 {
        // We have unclosed tokens in the stack
        token_kind := stack[len(stack)-1]
        closing_token: string

        #partial switch token_kind {
        case .LeftParen:    closing_token = ")"
        case .LeftBracket:  closing_token = "]"
        case .Less:     closing_token = ">"
        case .Or:        closing_token = "|"
        }

        error_at_current(parser, fmt.tprintf("Unclosed '%v' in execution pattern, expected '%s'",
                                           token_kind, closing_token))
        parser.lexer.position = original_position
        parser.current_token = original_current
        parser.peek_token = original_peek
        return nil, false
    }

    // Successfully parsed an execution pattern
    result := new(Node)
    result^ = execute
    return result, true
}

/*
 * Parse less than with disambiguation for threading execution
 */
parse_less_than :: proc(parser: ^Parser, left: ^Node, can_assign: bool) -> ^Node {
    // Try to parse as an execution pattern
    if node, is_execution := try_parse_wrapped_execute(parser, left); is_execution {
        return node
    }

    // Otherwise, parse as normal binary operator
    position := parser.current_token.position
    advance_token(parser) // Consume

    // It's a simple < operator
    op := Operator{
        kind = .Less,
        left = left,
        right = parse_expression(parser, Precedence(int(Precedence.COMPARISON) + 1)),
        position = position,
    }

    result := new(Node)
    result^ = op
    return result
}

/*
 * Parse left bracket with disambiguation for parallel execution
 */
parse_left_bracket :: proc(parser: ^Parser, left: ^Node, can_assign: bool) -> ^Node {
    // Try to parse as an execution pattern
    if node, is_execution := try_parse_wrapped_execute(parser, left); is_execution {
        return node
    }

    error_at_current(parser, "Trying to use left bracket [ for something else than execution wrapper like [!]")
    return nil
}

/*
 * Parse left parenthesis with disambiguation for background execution
 */
parse_left_paren :: proc(parser: ^Parser, left: ^Node, can_assign: bool) -> ^Node {
    // Try to parse as an execution pattern
    if node, is_execution := try_parse_wrapped_execute(parser, left); is_execution {
        return node
    }


    // Otherwhise it supposed to be grouping
    parse_grouping(parser, can_assign)
    return nil
}

/*
 * parse_unary parses unary operators (-, ~)
 */
parse_unary :: proc(parser: ^Parser, can_assign: bool) -> ^Node {
    // Save position of the unary operator
    position := parser.current_token.position

    // Remember the operator kind
    token_kind := parser.current_token.kind

    // Advance past the operator
    advance_token(parser)

    // Parse the operand
    operand := parse_expression(parser, .UNARY)
    if operand == nil {
        error_at_current(parser, "Expected expression after unary operator")
        return nil
    }

    // Create operator node
    op := Operator{
        right = operand,
        position = position, // Store position
    }

    // Set operator kind based on token
    #partial switch token_kind {
    case .Minus:
        op.kind = .Subtract
    case .Not:
        op.kind = .Not
    case:
        error_at_current(parser, "Unexpected unary operator")
        return nil
    }

    result := new(Node)
    result^ = op
    return result
}

/*
 * parse_binary handles binary operators (+, -, *, /, etc.)
 */
parse_binary :: proc(parser: ^Parser, left: ^Node, can_assign: bool) -> ^Node {
    // Save position of the binary operator
    position := parser.current_token.position

    // Remember the operator
    token_kind := parser.current_token.kind
    rule := get_rule(token_kind)

    // Move past the operator
    advance_token(parser)

    // Parse the right operand with higher precedence
    right := parse_expression(parser, Precedence(int(rule.precedence) + 1))
    if right == nil {
        error_at_current(parser, "Expected expression after binary operator")
        return nil
    }

    // Create operator node
    op := Operator{
        left = left,
        right = right,
        position = position, // Store position
    }

    // Set operator type
    #partial switch token_kind {
    case .Plus:          op.kind = .Add
    case .Minus:         op.kind = .Subtract
    case .Asterisk:      op.kind = .Multiply
    case .Slash:         op.kind = .Divide
    case .Percent:       op.kind = .Mod
    case .And:        op.kind = .And
    case .Or:         op.kind = .Or
    case .Xor:        op.kind = .Xor
    case .Equal:         op.kind = .Equal
    case .Less:          op.kind = .Less
    case .Greater:       op.kind = .Greater
    case .LessEqual:     op.kind = .LessEqual
    case .GreaterEqual:  op.kind = .GreaterEqual
    case .LShift:        op.kind = .LShift
    case .RShift:        op.kind = .RShift
    case:
        error_at_current(parser, fmt.tprintf("Unhandled binary operator type: %v", token_kind))
        return nil
    }

    result := new(Node)
    result^ = op
    return result
}

/*
 * parse_prefix_property handles property access (.prop)
 */
parse_prefix_property::proc(parser: ^Parser, can_assign: bool) -> ^Node {
  return parse_property(parser, nil, can_assign);
}

/*
 * parse_property handles property access (obj.prop)
 */
parse_property :: proc(parser: ^Parser, left: ^Node, can_assign: bool) -> ^Node {
    // Save position of the dot
    position := parser.current_token.position

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
    property := Property{
        source = left,
        position = position, // Store position
    }

    // Create property identifier
    prop_id := new(Node)
    prop_id^ = Identifier{
        name = prop_name,
        position = position, // Use dot position for the property identifier
    }
    property.property = prop_id

    // Return property node
    result := new(Node)
    result^ = property
    return result
}

/*
 * parse_pointing_push handles pointing operator (a -> b)
 */
parse_pointing_push :: proc(parser: ^Parser, left: ^Node, can_assign: bool) -> ^Node {
    // Save position of the -> token
    position := parser.current_token.position

    // Create pointing node
    pointing := Pointing{
        name = left,
        position = position, // Store position
    }

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
    result^ = pointing
    return result
}

/*
 * parse_pointing_pull_prefix handles prefix pointing pull operator (<- value)
 */
parse_pointing_pull_prefix :: proc(parser: ^Parser, can_assign: bool) -> ^Node {
    // Save position of the <- token
    position := parser.current_token.position

    // Create pointing pull node
    pointing_pull := PointingPull{
        position = position, // Store position
    }

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
    result^ = pointing_pull
    return result
}

/*
 * parse_pointing_pull handles infix pointing pull operator (a <- b)
 */
parse_pointing_pull :: proc(parser: ^Parser, left: ^Node, can_assign: bool) -> ^Node {
    // Save position of the <- token
    position := parser.current_token.position

    // Create pointing pull node
    pointing_pull := PointingPull{
        name = left,
        position = position, // Store position
    }

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
    result^ = pointing_pull
    return result
}

/*
 * parse_event_push_prefix handles prefix event push (>- value)
 */
parse_event_push_prefix :: proc(parser: ^Parser, can_assign: bool) -> ^Node {
    // Save position of the >- token
    position := parser.current_token.position

    // Create event push node
    event_push := EventPush{
        position = position, // Store position
    }

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
    result^ = event_push
    return result
}

/*
 * parse_event_push handles event push (a >- b)
 */
parse_event_push :: proc(parser: ^Parser, left: ^Node, can_assign: bool) -> ^Node {
    // Save position of the >- token
    position := parser.current_token.position

    // Create event push node
    event_push := EventPush{
        name = left,
        position = position, // Store position
    }

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
    result^ = event_push
    return result
}

/*
 * parse_event_pull_prefix handles prefix event pull (-< value)
 */
parse_event_pull_prefix :: proc(parser: ^Parser, can_assign: bool) -> ^Node {
    // Save position of the -< token
    position := parser.current_token.position

    // Create event pull node
    event_pull := EventPull{
        position = position, // Store position
    }

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
    result^ = event_pull
    return result
}

/*
 * parse_event_pull handles event pull (a -< b)
 */
parse_event_pull :: proc(parser: ^Parser, left: ^Node, can_assign: bool) -> ^Node {
    // Save position of the -< token
    position := parser.current_token.position

    // Create event pull node
    event_pull := EventPull{
        name = left,
        position = position, // Store position
    }

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
    result^ = event_pull
    return result
}

/*
 * parse_resonance_push_prefix handles prefix resonance push (>>- value)
 */
parse_resonance_push_prefix :: proc(parser: ^Parser, can_assign: bool) -> ^Node {
    // Save position of the >>- token
    position := parser.current_token.position

    // Create resonance push node
    resonance_push := ResonancePush{
        position = position, // Store position
    }

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
    result^ = resonance_push
    return result
}

/*
 * parse_resonance_push handles resonance push (a >>- b)
 */
parse_resonance_push :: proc(parser: ^Parser, left: ^Node, can_assign: bool) -> ^Node {
    // Save position of the >>- token
    position := parser.current_token.position

    // Create resonance push node
    resonance_push := ResonancePush{
        name = left,
        position = position, // Store position
    }

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
    result^ = resonance_push
    return result
}

/*
 * parse_resonance_pull_prefix handles prefix resonance pull (-<< value)
 */
parse_resonance_pull_prefix :: proc(parser: ^Parser, can_assign: bool) -> ^Node {
    // Save position of the -<< token
    position := parser.current_token.position

    // Create resonance pull node
    resonance_pull := ResonancePull{
        position = position, // Store position
    }

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
    result^ = resonance_pull
    return result
}

/*
 * parse_resonance_pull handles resonance pull (a -<< b)
 */
parse_resonance_pull :: proc(parser: ^Parser, left: ^Node, can_assign: bool) -> ^Node {
    // Save position of the -<< token
    position := parser.current_token.position

    // Create resonance pull node
    resonance_pull := ResonancePull{
        name = left,
        position = position, // Store position
    }

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
    result^ = resonance_pull
    return result
}

/*
 * parse_prefix_range handles prefix range (..5)
 */
parse_prefix_range :: proc(parser: ^Parser, can_assign: bool) -> ^Node {
    // Save position of the .. token
    position := parser.current_token.position

    // Consume ..
    advance_token(parser)

    // Parse end value or handle empty value
    end: ^Node = nil
    if !(parser.current_token.kind == .RightBrace ||
         parser.current_token.kind == .EOF ||
         parser.current_token.kind == .Newline) {
        end = parse_expression(parser, .RANGE)
    }

    // Create range node with position
    range := Range{
        end = end,
        position = position, // Store position
    }

    result := new(Node)
    result^ = range
    return result
}

/*
 * parse_range handles range expression (a..b)
 */
parse_range :: proc(parser: ^Parser, left: ^Node, can_assign: bool) -> ^Node {
    // Save position of the .. token
    position := parser.current_token.position

    // Consume ..
    advance_token(parser)

    // Create range node with position
    range := Range{
        start = left,
        position = position, // Store position
    }

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
    result^ = range
    return result
}

/*
 * parse_constraint handles constraint expressions (Type:value)
 */
parse_constraint :: proc(parser: ^Parser, left: ^Node, can_assign: bool) -> ^Node {
    // Save position of the : token
    position := parser.current_token.position

    // Check if left is nil before proceeding
    if left == nil {
        error_at_current(parser, "Constraint requires a type before ':'")
        advance_token(parser) // Skip the colon
        return nil
    }

    // Create constraint with position
    constraint := Constraint{
        constraint = left,
        position = position, // Store position
    }

    next_space := is_space(parser.lexer.source[parser.current_token.position.offset+1])
    // Move past :
    advance_token(parser)

    if(!next_space) {
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
        }
    }

    result := new(Node)
    result^ = constraint
    return result
}

/*
 * parse_pattern handles pattern match (target ? {...})
 */
parse_pattern :: proc(parser: ^Parser, left: ^Node, can_assign: bool) -> ^Node {
    // Save position of the ? token
    position := parser.current_token.position

    // Create pattern node with target and position
    pattern := Pattern{
        target = left,
        value = make([dynamic]Branch, 0, 2),
        position = position, // Store position
    }

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
        if(node != nil) {
            append(&pattern.value, node^)
        }
        skip_newlines(parser)
    }

    if !match(parser, .RightBrace) {
        error_at_current(parser, "Expected } after pattern branches")
        return nil
    }

    result := new(Node)
    result^ = pattern
    return result
}

/*
 * parse_branch parses a single branch in a pattern match
 */
parse_branch :: proc(parser: ^Parser) -> ^Branch {
    // Save position of the branch start
    position := parser.current_token.position

    // Don't try to parse a branch if we're at a token that can't start an expression
    if !is_expression_start(parser.current_token.kind) {
        advance_token(parser)  // Skip problematic token
        return nil
    }

    // Create branch with position
    branch := new(Branch)
    branch.position = position // Store position

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
                    constraint := Constraint{
                        constraint = parse.constraint,
                        position = parse.position, // Preserve constraint position
                    }
                    result := new(Node)
                    result^ = constraint
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
        product := Product{
            value = value,
            position = parser.current_token.position, // Use current token position
        }

        product_node := new(Node)
        product_node^ = product
        branch.product = product_node
    } else {
        // Handle case where there's no expression after ->
        product := Product{
            position = parser.current_token.position, // Use current token position
        }

        product_node := new(Node)
        product_node^ = product
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
    // Save position of the ellipsis token
    position := parser.current_token.position

    // Consume ellipsis token
    advance_token(parser)

    // Get the expression that follows with appropriate precedence
    // Use the UNARY precedence to ensure we get the entire expression
    target := parse_expression(parser, .UNARY)
    if target == nil {
        error_at_current(parser, "Expected expression after ...")
        return nil
    }

    // Create the expansion node with the target and position
    expand := Expand{
        target = target,
        position = position, // Store position
    }

    result := new(Node)
    result^ = expand
    return result
}

/*
 * parse_reference parses a file system reference */
parse_reference :: proc(parser: ^Parser, can_assign: bool) -> ^Node {
    position := parser.current_token.position
    advance_token(parser) // Consume @

    if parser.current_token.kind != .Identifier {
        error_at_current(parser, "Expected identifier after @")
        return nil
    }

    // Create the initial External node
    result := new(Node)
    result^ = External{
        position = position,
        name = parser.current_token.text,
    }

    advance_token(parser)

    // Start with our result node
    current := result

    // Chain property access
    for parser.current_token.kind == .Dot {
        advance_token(parser)

        if parser.current_token.kind != .Identifier {
            error_at_current(parser, "Expected identifier after '.'")
            break
        }

        // Create property identifier
        property_id := new(Node)
        property_id^ = Identifier{
            name = parser.current_token.text,
            position = parser.current_token.position,
        }

        // Create new Property node
        next := new(Node)
        next^ = Property{
            source = current,
            property = property_id,
            position = position,
        }

        // Update current to point to the new node
        current = next
        advance_token(parser)
    }

    process_filenode(current, parser.file_cache)

    return current
}

// ===========================================================================
// SECTION 4: UTILITY FUNCTIONS
// ===========================================================================

/*
 * Helper function to check if a token can start an execution pattern
 */
is_execution_pattern_start :: proc(kind: Token_Kind) -> bool {
    return kind == .Execute || kind == .LeftParen || kind == .Less ||
           kind == .LeftBracket || kind == .Or
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
        kind == .Not ||
        kind == .Minus||
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
 * is_digit checks if a character is a digit
 * Inlined for speed
 */
is_digit :: #force_inline proc(c: u8) -> bool {
    return c >= '0' && c <= '9'
}

/*
 * is_hex_digit checks if a character is a hexadecimal digit
 * Inlined for speed
 */
is_hex_digit :: #force_inline proc(c: u8) -> bool {
    return is_digit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
}

/*
 * is_alpha checks if a character is an alphabetic character
 * Inlined for speed
 */
is_alpha :: #force_inline proc(c: u8) -> bool {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

/*
 * is_alnum checks if a character is alphanumeric or underscore
 * Inlined for speed
 */
is_alnum :: #force_inline proc(c: u8) -> bool {
    return is_digit(c) || is_alpha(c) || c == '_'
}

/*
 * is_space checks if a character is a whitespace character
 * Inlined for speed
 */
is_space :: #force_inline proc(c: u8) -> bool {
    return c == ' ' || c == '\t' || c == '\r'
}

/*
 * skip_whitespace advances the lexer past any whitespace characters
 * but preserves newline tokens for statement separation
 * Optimized with a direct tight loop
 */
skip_whitespace :: #force_inline proc(l: ^Lexer) {
    for l.position.offset < l.source_len {
        c := l.source[l.position.offset]
        if !is_space(c) {
            break
        }
        advance_position(l)
    }
}

// ===========================================================================
// SECTION 5: DEBUG UTILITIES
// ===========================================================================

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
        fmt.printf("%sPointing -> (line %d, column %d)\n",
            indent_str, n.position.line, n.position.column)
        if n.name != nil {
            fmt.printf("%s  Name:\n", indent_str)
            print_ast(n.name, indent + 4)
        }
        if n.value != nil {
            fmt.printf("%s  Value:\n", indent_str)
            print_ast(n.value, indent + 4)
        }

    case PointingPull:
        fmt.printf("%sPointingPull <- (line %d, column %d)\n",
            indent_str, n.position.line, n.position.column)
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
        fmt.printf("%sEventPush >- (line %d, column %d)\n",
            indent_str, n.position.line, n.position.column)
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
        fmt.printf("%sEventPull -< (line %d, column %d)\n",
            indent_str, n.position.line, n.position.column)
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
        fmt.printf("%sResonancePush >>- (line %d, column %d)\n",
            indent_str, n.position.line, n.position.column)
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
        fmt.printf("%sResonancePull -<< (line %d, column %d)\n",
            indent_str, n.position.line, n.position.column)
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
      if(n.parenthesized) {
        fmt.printf("%sIdentifier: (%s) (line %d, column %d)\n",
            indent_str, n.name, n.position.line, n.position.column)
      } else {
        fmt.printf("%sIdentifier: %s (line %d, column %d)\n",
            indent_str, n.name, n.position.line, n.position.column)
      }

    case ScopeNode:
        fmt.printf("%sScopeNode (line %d, column %d)\n",
            indent_str, n.position.line, n.position.column)
        for i := 0; i < len(n.value); i += 1 {
            entry_node := new(Node)
            entry_node^ = n.value[i]
            print_ast(entry_node, indent + 2)
        }

    case Override:
        fmt.printf("%sOverride (line %d, column %d)\n",
            indent_str, n.position.line, n.position.column)
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
        fmt.printf("%sProperty (line %d, column %d)\n",
            indent_str, n.position.line, n.position.column)
        if n.source != nil {
            fmt.printf("%s  Source:\n", indent_str)
            print_ast(n.source, indent + 4)
        }
        if n.property != nil {
            fmt.printf("%s  Property:\n", indent_str)
            print_ast(n.property, indent + 4)
        }

    case Expand:
        fmt.printf("%sExpand (line %d, column %d)\n",
            indent_str, n.position.line, n.position.column)
        if n.target != nil {
            fmt.printf("%s  Target:\n", indent_str)
            print_ast(n.target, indent + 4)
        }

    case External:
        fmt.printf("%sExternal (line %d, column %d)\n",
            indent_str, n.position.line, n.position.column)
        if n.scope != nil {
            fmt.printf("%s  Target:\n", indent_str)
            print_ast(n.scope, indent + 4)
        }

    case Product:
        fmt.printf("%sProduct -> (line %d, column %d)\n",
            indent_str, n.position.line, n.position.column)
        if n.value != nil {
            print_ast(n.value, indent + 2)
        }

    case Pattern:
        fmt.printf("%sPattern ? (line %d, column %d)\n",
            indent_str, n.position.line, n.position.column)
        if n.target != nil {
            fmt.printf("%s  Target:\n", indent_str)
            print_ast(n.target, indent + 4)
        } else {
            fmt.printf("%s  Target: implicit\n", indent_str)
        }
        fmt.printf("%s  Branches\n", indent_str)
        for i := 0; i < len(n.value); i += 1 {
            branch := n.value[i]
            fmt.printf("%s    Branch: (line %d, column %d)\n",
                indent_str, branch.position.line, branch.position.column)
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
        fmt.printf("%sConstraint: (line %d, column %d)\n",
            indent_str, n.position.line, n.position.column)
        print_ast(n.constraint, indent + 2)
        if n.value != nil {
            fmt.printf("%s  Value:\n", indent_str)
            print_ast(n.value, indent + 4)
        } else {
            fmt.printf("%s  Value: none\n", indent_str)
        }

    case Operator:
        fmt.printf("%sOperator '%v' (line %d, column %d)\n",
            indent_str, n.kind, n.position.line, n.position.column)
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

      // First build opening symbols - from outer (first in list) to inner
      for wrapper in n.wrappers {
        switch wrapper {
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

      // Add exclamation mark in the middle
      pattern = strings.concatenate({pattern, "!"})

      // Add closing symbols in reverse order - from inner to outer
      for i := len(n.wrappers)-1; i >= 0; i -= 1 {
        switch n.wrappers[i] {
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

      fmt.printf("%sExecute %s (line %d, column %d)\n",
          indent_str, pattern, n.position.line, n.position.column)
      if n.value != nil {
          print_ast(n.value, indent + 2)
      }

    case Literal:
        fmt.printf("%sLiteral (%v): %s (line %d, column %d)\n",
            indent_str, n.kind, n.value, n.position.line, n.position.column)

    case Range:
        fmt.printf("%sRange (line %d, column %d)\n",
            indent_str, n.position.line, n.position.column)
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

