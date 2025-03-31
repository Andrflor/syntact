package compiler

import "core:fmt"
import "core:os"
import "core:strings"
import "core:unicode/utf8" // For better character handling if needed
import "core:strconv" // For potential future literal parsing improvements

// === TOKEN ENUM ===
Token_Kind :: enum {
	Invalid,
	EOF,
	Identifier,

	// Literals
	Integer,
	Float,
	Hexadecimal,
	Binary,
	String_Literal, // Backtick strings ``

	// Keywords (Reserve space, none defined yet, but good practice)
	// e.g., If, Else, While, ... (if the language evolves)

	// Operators & Punctuation
	Execute,      // !
	At,           // @
	Colon,        // :
	Question,     // ?
	Dot,          // .
	DoubleDot,    // .. (potentially for ranges or other syntax)
	Ellipsis,     // ...

	// Assignators / Data Flow
	PointingPush,  // ->
	PointingPull,  // <- (Placeholder, might need specific AST)
	EventPush,     // >-
	EventPull,     // -<
	ResonancePush, // >>-
	ResonancePull, // -<<

	// Comparisons (Refined, added !=)
	Assign,       // = (Assuming single = is assignment/binding, not comparison)
	Equal,        // ==
	NotEqual,     // !=
	LessThan,     // <
	GreaterThan,  // >
	LessEqual,    // <=
	GreaterEqual, // >=

	// Separators
	Newline,    // \n (Significant or just whitespace?)
	Comma,      // , (Might be needed in lists, params, etc.)
	Semicolon,  // ; (Optional statement separator?)

	// Grouping
	LeftBrace,    // {
	RightBrace,   // }
	LeftParen,    // (
	RightParen,   // )
	LeftBracket,  // [
	RightBracket, // ]

	// Math & Logic (Keep standard ones)
	Plus,     // +
	Minus,    // -
	Asterisk, // *
	Slash,    // /
	Percent,  // %
	BitAnd,   // &
	BitOr,    // |
	BitXor,   // ^
	BitNot,   // ~

	// Range specific tokens (from original lexer)
	// These might be better handled by the parser looking at sequences
	// like Integer, DoubleDot, Integer. Let's remove them for now
	// and parse them compositionally.
	// Range, // 1..2
	// PrefixRange, // ..1
	// PostfixRange, // 1..

    // Potential future tokens
    Pipe, // | (Alternative to BitOr if used differently)

}

// === TOKEN STRUCT ===
Token :: struct {
	kind: Token_Kind,
	text: string,
	pos:  int, // Start position
	// Consider adding line/column numbers later
	// line: int,
	// col: int,
}

// === LEXER ===
Lexer :: struct {
	source:  string,
	pos:     int, // Current position (byte index)
	read_pos: int, // Next reading position
	ch:      rune, // Current character (rune for UTF-8 safety)
}

// Initialize Lexer
init_lexer :: proc(l: ^Lexer, source: string) {
	l.source = source
	l.pos = 0
	l.read_pos = 0
	advance_char(l) // Load the first character
}

// Read next UTF-8 character
advance_char :: proc(l: ^Lexer) {
	if l.read_pos >= len(l.source) {
		l.ch = 0 // EOF represented by 0 rune
	} else {
		// Odin strings are UTF-8, handle multi-byte characters
		r, width := utf8.decode_rune_in_string(l.source[l.read_pos:])
		l.ch = r
		l.pos = l.read_pos
		l.read_pos += width
	}
}

// Peek next character without advancing
peek_char :: proc(l: ^Lexer) -> rune {
	if l.read_pos >= len(l.source) {
		return 0
	}
	r, _ := utf8.decode_rune_in_string(l.source[l.read_pos:])
	return r
}

// Skip whitespace (excluding newline, which might be significant)
skip_whitespace :: proc(l: ^Lexer) {
	for l.ch == ' ' || l.ch == '\t' || l.ch == '\r' {
		advance_char(l)
	}
}

// Skip single-line and multi-line comments
skip_comments_and_whitespace :: proc(l: ^Lexer) -> bool {
    skipped := false
	for {
		start_again := false
		skip_whitespace(l)

		// Single line comment //
		if l.ch == '/' && peek_char(l) == '/' {
            skipped = true
			for l.ch != '\n' && l.ch != 0 {
				advance_char(l)
			}
            start_again = true // Check for more whitespace/comments after comment
		}

		// Multi line comment /* ... */
		if l.ch == '/' && peek_char(l) == '*' {
            skipped = true
			advance_char(l) // Consume /
			advance_char(l) // Consume *
			for !(l.ch == '*' && peek_char(l) == '/') && l.ch != 0 {
				advance_char(l)
			}
			if l.ch != 0 { advance_char(l) } // Consume *
			if l.ch != 0 { advance_char(l) } // Consume /
            start_again = true // Check for more whitespace/comments after comment
		}

		if !start_again {
			break // No more comments or whitespace found in this iteration
		}
	}
    return skipped
}


// Improved next_token
next_token :: proc(l: ^Lexer) -> Token {
	skip_comments_and_whitespace(l)

	start_pos := l.pos
	tok: Token

	switch l.ch {
	case 0:   tok = Token{kind = .EOF, pos = start_pos}
	case '\n': tok = Token{kind = .Newline, text = "\\n", pos = start_pos} ; advance_char(l) ; return tok // Keep simple for now
	case '!':
		if peek_char(l) == '=' {
			advance_char(l)
			tok = Token{kind = .NotEqual, text = "!=", pos = start_pos}
		} else {
			tok = Token{kind = .Execute, text = "!", pos = start_pos}
		}
	case '@': tok = Token{kind = .At, text = "@", pos = start_pos}
	case ':': tok = Token{kind = .Colon, text = ":", pos = start_pos}
	case '?': tok = Token{kind = .Question, text = "?", pos = start_pos}
	case '.':
		if peek_char(l) == '.' {
			advance_char(l)
			if peek_char(l) == '.' {
				advance_char(l)
				tok = Token{kind = .Ellipsis, text = "...", pos = start_pos}
			} else {
				tok = Token{kind = .DoubleDot, text = "..", pos = start_pos}
			}
		} else {
			tok = Token{kind = .Dot, text = ".", pos = start_pos}
		}
	case '=':
		if peek_char(l) == '=' {
			advance_char(l)
			tok = Token{kind = .Equal, text = "==", pos = start_pos}
		} else {
			tok = Token{kind = .Assign, text = "=", pos = start_pos} // Changed to Assign
		}
	case '<':
		peek := peek_char(l)
		if peek == '=' { advance_char(l); tok = Token{kind = .LessEqual, text = "<=", pos = start_pos}
		// else if peek == '-' { advance_char(l); tok = Token{kind = .PointingPull, text = "<-", pos = start_pos} } // Handled by '-'
        // else if peek == '!' && peek_char_after(l) == '>' { /* <!> */ } // Complex, handle in parser? Or lexer state?
    }else { tok = Token{kind = .LessThan, text = "<", pos = start_pos} }
	case '>':
		peek := peek_char(l)
		if peek == '=' { advance_char(l); tok = Token{kind = .GreaterEqual, text = ">=", pos = start_pos} }
		else if peek == '-' { advance_char(l); tok = Token{kind = .EventPush, text = ">-", pos = start_pos} }
		else if peek == '>' && peek_char_after(l) == '-' {
			advance_char(l); advance_char(l)
			tok = Token{kind = .ResonancePush, text = ">>-", pos = start_pos}
		}
		else { tok = Token{kind = .GreaterThan, text = ">", pos = start_pos} }
	case '-':
		peek := peek_char(l)
		if peek == '>' { advance_char(l); tok = Token{kind = .PointingPush, text = "->", pos = start_pos} }
		else if peek == '<' {
			advance_char(l)
			if peek_char(l) == '<' {
				advance_char(l)
				tok = Token{kind = .ResonancePull, text = "-<<", pos = start_pos}
			} else {
				tok = Token{kind = .EventPull, text = "-<", pos = start_pos}
			}
		} else {
			tok = Token{kind = .Minus, text = "-", pos = start_pos}
		}
	case '/':
        // Comments handled by skip_comments_and_whitespace
		tok = Token{kind = .Slash, text = "/", pos = start_pos}
	case '`': // Backtick string literal
		advance_char(l) // Consume opening `
		str_start := l.pos
		for l.ch != '`' && l.ch != 0 {
			advance_char(l)
		}
		if l.ch == '`' {
			tok = Token{kind = .String_Literal, text = l.source[str_start:l.pos], pos = str_start}
			advance_char(l) // Consume closing `
			return tok // Return directly as we consumed the closing backtick
		} else {
			tok = Token{kind = .Invalid, text = "Unterminated string", pos = str_start}
			// No advance_char here, let the main switch handle the final character
		}
	case '{': tok = Token{kind = .LeftBrace, text = "{", pos = start_pos}
	case '}': tok = Token{kind = .RightBrace, text = "}", pos = start_pos}
	case '(': tok = Token{kind = .LeftParen, text = "(", pos = start_pos}
	case ')': tok = Token{kind = .RightParen, text = ")", pos = start_pos}
	case '[': tok = Token{kind = .LeftBracket, text = "[", pos = start_pos}
	case ']': tok = Token{kind = .RightBracket, text = "]", pos = start_pos}
	case '+': tok = Token{kind = .Plus, text = "+", pos = start_pos}
	case '*': tok = Token{kind = .Asterisk, text = "*", pos = start_pos}
	case '%': tok = Token{kind = .Percent, text = "%", pos = start_pos}
	case '&': tok = Token{kind = .BitAnd, text = "&", pos = start_pos}
	case '|': tok = Token{kind = .BitOr, text = "|", pos = start_pos} // Need care if |!| is used
	case '^': tok = Token{kind = .BitXor, text = "^", pos = start_pos}
	case '~': tok = Token{kind = .BitNot, text = "~", pos = start_pos}
    case ',': tok = Token{kind = .Comma, text=",", pos=start_pos}
    case ';': tok = Token{kind = .Semicolon, text=";", pos=start_pos}
	case: // Default case for identifiers and numbers
		if is_letter(l.ch) || l.ch == '_' {
			ident := read_identifier(l)
            // Check for keywords here if any are added
			tok = Token{kind = .Identifier, text = ident, pos = start_pos}
			return tok // read_identifier already advances
		} else if is_digit(l.ch) {
			num_text, kind := read_number(l)
			tok = Token{kind = kind, text = num_text, pos = start_pos}
			return tok // read_number already advances
		} else {
			tok = Token{kind = .Invalid, text = string([]rune{l.ch}), pos = start_pos}
		}
	}

	advance_char(l) // Advance for the next token read
	return tok
}

// Helper to peek two chars ahead
peek_char_after :: proc(l: ^Lexer) -> rune {
    if l.read_pos >= len(l.source) { return 0 }
    _, width1 := utf8.decode_rune_in_string(l.source[l.read_pos:])
    next_pos := l.read_pos + width1
    if next_pos >= len(l.source) { return 0 }
     r, _ := utf8.decode_rune_in_string(l.source[next_pos:])
     return r
}

// Helper to read identifier
read_identifier :: proc(l: ^Lexer) -> string {
	start := l.pos
	for is_letter(l.ch) || is_digit(l.ch) || l.ch == '_' {
		advance_char(l)
	}
	return l.source[start:l.pos]
}

// Helper to read number (integer, float, hex, binary)
read_number :: proc(l: ^Lexer) -> (string, Token_Kind) {
	start := l.pos
	kind: Token_Kind = .Integer // Default

	// Check for Hex (0x) or Binary (0b)
	if l.ch == '0' && (peek_char(l) == 'x' || peek_char(l) == 'X') {
		advance_char(l) // 0
		advance_char(l) // x
		for is_hex_digit(l.ch) { advance_char(l) }
		return l.source[start:l.pos], .Hexadecimal
	}
	if l.ch == '0' && (peek_char(l) == 'b' || peek_char(l) == 'B') {
		advance_char(l) // 0
		advance_char(l) // b
		for l.ch == '0' || l.ch == '1' { advance_char(l) }
		return l.source[start:l.pos], .Binary
	}

	// Regular number (integer or float)
	for is_digit(l.ch) {
		advance_char(l)
	}

	// Check for float
	if l.ch == '.' && is_digit(peek_char(l)) {
		kind = .Float
		advance_char(l) // Consume '.'
		for is_digit(l.ch) {
			advance_char(l)
		}
        // TODO: Add exponent handling (e.g., 1.2e3) if needed
	}

    // Note: Range parsing (1..5) is deferred to the parser level

	return l.source[start:l.pos], kind
}

// Character classification helpers (using runes for potential UTF-8)
is_letter :: proc(ch: rune) -> bool {
	return ('a' <= ch && ch <= 'z') || ('A' <= ch && ch <= 'Z') // Basic ASCII letters
    // TODO: Add Unicode letter support if required using core:unicode
}

is_digit :: proc(ch: rune) -> bool {
	return '0' <= ch && ch <= '9'
}

is_hex_digit :: proc(ch: rune) -> bool {
    return is_digit(ch) || ('a' <= ch && ch <= 'f') || ('A' <= ch && ch <= 'F')
}

is_space :: proc(ch: rune) -> bool {
	return ch == ' ' || ch == '\t' || ch == '\r' // Excludes newline
}

// === AST NODES ===

// Forward declare Node
Node :: struct #raw_union {
	// Keep using #raw_union for simplicity, but be careful with lifetimes if nodes own others.
	// Consider tagged union or interfaces for more complex scenarios.
	using _: $Node_Union,
}

Node_Union :: union {
	Program,
	Identifier,
	Literal,
	Scope,
	Pointing,      // name -> value
	Product,       // -> value (anonymous pointing in a scope)
	Constraint,    // Type: maybe_value
	Pattern,       // target ? { branches... }
	Branch,        // pattern : -> product
	Override,      // source { overrides... }
	Expansion,     // ...source or ...source { overrides... }
	FileSystem,    // @a.b.c
	Property,      // source.property
	Execute,       // value! or value[!] etc.
	EventPush,     // >- target
	EventPull,     // -< handler
	ResonancePush, // target >>- source
	ResonancePull, // target -<< source
    Operator,      // left op right (For binary/unary ops if needed)
    // Add other node types as needed
}


Program :: struct {
	statements: [dynamic]^Node,
    // Optional final expression defining the program's result
    // result_expression: Maybe(^Node),
}

Identifier :: struct {
	name: string,
}

Literal_Kind :: enum { Integer, Float, String, Hexadecimal, Binary }
Literal :: struct {
	kind:  Literal_Kind,
	value: string,
}

Scope :: struct {
	statements: [dynamic]^Node,
}

Pointing :: struct {
	name:  string, // Name being pointed to
	value: ^Node,  // The expression/scope being assigned
}

Product :: struct { // Represents '-> value' inside a scope
	value: ^Node,
}

// Represents Type: Value or Type:
Constraint :: struct {
	constraint_type: ^Node, // Usually an Identifier, could be complex like 'maybe{T}' parsed into a special ident?
	value:           Maybe(^Node), // Optional value associated
}

Pattern :: struct {
	target:   ^Node,        // The expression being matched
	branches: [dynamic]Branch, // The pattern branches { pat1: -> res1, ... }
}

Branch :: struct {
	pattern: ^Node, // The pattern to match (e.g., Identifier, Literal, Scope structure)
	product: ^Node, // The result expression if the pattern matches (Node will be a Product type)
}

// source { override1 override2 }
Override :: struct {
	source:    ^Node,        // The original expression/scope being overridden
	overrides: [dynamic]^Node, // List of statements inside the {}
}

// ...source or ...source { overrides }
Expansion :: struct {
	source:  ^Node, // The expression/scope being expanded
    // Overrides are handled by parsing an Override node *after* the expansion primary
    // e.g., `...source` is Expansion, `...source { o1 }` is Override{ source: Expansion{...}, overrides: [o1] }
}

FileSystem :: struct { // Represents @a.b.c
	path: ^Node, // Typically an Identifier or Property chain
}

Property :: struct { // Represents source.property
	source:   ^Node, // Expression left of the dot
	property: Identifier, // Identifier right of the dot
}

Execution_Kind :: enum {
	Direct,       // !
	Parallel,     // [!]
	Threaded,     // <!> (Need lexer/parser adjustment)
	Background,   // (!)
	GPU,          // |!| (Need lexer/parser adjustment)

	// Composed / Background versions (Parse compositionally)
	ParallelBackground, // ([!]) -> Execute{ Background, Execute{Parallel, value} } ?
	ThreadedBackground, // (< ! >) -> Execute{ Background, Execute{Threaded, value} } ?
	GPUBackground,      // (|!|) -> Execute{ Background, Execute{GPU, value} } ?
}
Execute :: struct {
	kind:  Execution_Kind,
	value: ^Node, // The expression being executed
}

// >- target_expr
EventPush :: struct {
	target: ^Node,
}

// -< handler_expr
EventPull :: struct {
	handler: ^Node,
}

// target_expr >>- source_expr
ResonancePush :: struct {
	target: ^Node,
	source: ^Node,
}

// target_expr -<< source_expr
ResonancePull :: struct {
	target: ^Node,
	source: ^Node,
}

Operator_Kind :: enum { Plus, Minus, Mult, Div /*, ... */ }
Operator :: struct {
	kind:  Operator_Kind,
	left:  ^Node,
	right: ^Node,
}

// === PARSER ===
Parser :: struct {
	lexer:         ^Lexer,
	current_token: Token,
	peek_token:    Token,

	errors: [dynamic]string, // Collect errors instead of just printing
}

// Initialization
init_parser :: proc(p: ^Parser, l: ^Lexer) {
	p.lexer = l
	p.errors = make([dynamic]string)
	// Prime the pump with two tokens
	advance_token(p)
	advance_token(p)
}

// Advance tokens
advance_token :: proc(p: ^Parser) {
	p.current_token = p.peek_token
	p.peek_token = next_token(p.lexer)
}

// Error handling
parse_error :: proc(p: ^Parser, msg: string) {
	err_msg := fmt.tprintf("Parse Error at pos %d (token %v '%s'): %s",
		p.current_token.pos, p.current_token.kind, p.current_token.text, msg)
	append(&p.errors, err_msg)
}

// Expect token type - advances if match, errors if not
expect_peek :: proc(p: ^Parser, kind: Token_Kind) -> bool {
	if p.peek_token.kind == kind {
		advance_token(p)
		return true
	}
	parse_error(p, fmt.tprintf("Expected next token to be %v, got %v instead", kind, p.peek_token.kind))
	return false
}

// --- Main Parsing Logic ---

parse_program :: proc(p: ^Parser) -> ^Node {
	program := new(Program)
	program.statements = make([dynamic]^Node)

	// Keep parsing statements until EOF
	for p.current_token.kind != .EOF {
		// Skip leading newlines before a statement
		for p.current_token.kind == .Newline {
			advance_token(p)
		}
        if p.current_token.kind == .EOF { break } // Check again after skipping newlines

		stmt := parse_statement(p)
		if stmt != nil {
			append(&program.statements, stmt)
		} else {
			// Basic error recovery: skip until next newline or potential statement start
            // A better recovery might try to find synchronizing tokens like '}' or common statement starters
            parse_error(p, "Failed to parse statement, attempting recovery.")
			for p.current_token.kind != .EOF &&
                p.current_token.kind != .Newline &&
                p.current_token.kind != .RightBrace // Common sync point
            {
				advance_token(p)
			}
		}

        // Consume trailing newlines after a statement
        // Allow multiple newlines between statements
		for p.current_token.kind == .Newline {
			advance_token(p)
		}
	}

    // Check for final "-> expression" which might define the program's output
    // This requires looking at the last statement parsed, or a specific syntax.
    // For now, the program is just the list of statements.

	node := new(Node)
	node^ = program^
	return node
}

// --- Statement Parsing ---

// Dispatches to specific statement parsers
parse_statement :: proc(p: ^Parser) -> ^Node {
    #partial switch p.current_token.kind {
    case .Identifier:
        // Look ahead to determine the kind of statement
        #partial switch p.peek_token.kind {
        case .PointingPush: // name -> ...
            return parse_pointing_statement(p)
        case .Question:     // name ? ...
            return parse_pattern_statement(p)
        case .Colon:        // name : ...
             // Could be constraint `Type: name` or `name: Type`
             // Let's assume `name : TypeOrValue` or `Type : name`
             // Need to decide grammar. Assuming `Type : name` or `Type :`
             return parse_constraint_statement(p)
        case .LeftBrace:    // name { ... } (Override)
            // This looks like an expression, handle in parse_expression?
            // Let's parse `name { ... }` as an expression statement for now.
             return parse_expression_statement(p)
        case .Assign:       // name = value (Simple assignment if needed)
             // return parse_assignment_statement(p) // If '=' is assignment
             // Assuming '=' is not primary assignment, fall through to expression
             fallthrough
        case .ResonancePush: // name >>- ...
             // This needs the target (`name`) first, parse as expression?
             // target_expr >>- source_expr
             return parse_expression_statement(p)
        case .ResonancePull: // name -<< ...
             // target_expr -<< source_expr
             return parse_expression_statement(p)

        case: // Just an identifier, likely start of an expression statement (e.g., funcCall!)
            return parse_expression_statement(p)
        }

    case .PointingPush: // -> value (Anonymous pointing / Product)
        return parse_product_statement(p)
    case .EventPush:    // >- target
        return parse_event_push_statement(p)
    case .EventPull:    // -< handler
        return parse_event_pull_statement(p)
    case .Ellipsis:   // ...source or ...source { ... }
        return parse_expansion_statement(p) // Or handle as expression? Let's try statement first.
    case .LeftBrace:  // { ... } (Anonymous Scope)
        return parse_scope_expression(p) // Scopes seem more like expressions
    case .At:         // @path... (Reference, likely expression)
        return parse_expression_statement(p)

    // Literals at statement level? Maybe allowed.
    case .Integer, .Float, .Hexadecimal, .Binary, .String_Literal:
         return parse_expression_statement(p)

    case:
        parse_error(p, fmt.tprintf("Unexpected token at start of statement: %v", p.current_token.kind))
        return nil
    }
}

// name -> value
parse_pointing_statement :: proc(p: ^Parser) -> ^Node {
	pointing := new(Pointing)
	if p.current_token.kind != .Identifier {
		parse_error(p, "Expected identifier name for pointing statement")
		return nil
	}
	pointing.name = p.current_token.text
	advance_token(p) // Consume identifier

	if !expect_peek(p, .PointingPush) { // Changed to expect_peek because name was current token
        // Error handled by expect_peek
		return nil
	}
    // At this point, current_token is '->', advance past it.
    advance_token(p) // Consume '->'

	pointing.value = parse_expression(p)
	if pointing.value == nil {
		parse_error(p, "Expected expression after '->' in pointing statement")
		return nil
	}

	node := new(Node)
	node^ = pointing^
	return node
}

// -> value
parse_product_statement :: proc(p: ^Parser) -> ^Node {
    product := new(Product)
    if p.current_token.kind != .PointingPush {
         parse_error(p, "Expected '->' for product statement")
         return nil
    }
    advance_token(p) // Consume '->'

    product.value = parse_expression(p)
    if product.value == nil {
         parse_error(p, "Expected expression after '->' in product statement")
         return nil
    }
    node := new(Node)
    node^ = product^
    return node
}


// target ? { branches }
parse_pattern_statement :: proc(p: ^Parser) -> ^Node {
    pattern := new(Pattern)

    // The target was the identifier before the '?'
    target_ident_name := p.current_token.text
    advance_token(p) // Consume identifier (target)

    target_node := new(Node)
    target_node^ = Identifier{name = target_ident_name}
    pattern.target = target_node

    if p.current_token.kind != .Question {
        parse_error(p, "Internal Error: Expected '?' for pattern statement") // Should have been checked by caller
        return nil
    }
    advance_token(p) // Consume '?'

    if p.current_token.kind != .LeftBrace {
        parse_error(p, "Expected '{' to start pattern branches")
        return nil
    }
    advance_token(p) // Consume '{'

    pattern.branches = make([dynamic]Branch)
    for p.current_token.kind != .RightBrace && p.current_token.kind != .EOF {
        // Skip newlines within branches
		for p.current_token.kind == .Newline { advance_token(p) }
        if p.current_token.kind == .RightBrace || p.current_token.kind == .EOF { break }

        branch := parse_branch(p)
        if branch != nil {
             // Branch parsing already creates the struct, just append it
             append(&pattern.branches, branch^)
        } else {
            parse_error(p, "Failed to parse pattern branch, attempting recovery.")
            // Skip until next potential branch start (likely identifier or newline) or '}'
            for p.current_token.kind != .EOF &&
                p.current_token.kind != .RightBrace &&
                p.current_token.kind != .Newline &&
                p.current_token.kind != .Identifier // Heuristic recovery point
            {
                advance_token(p)
            }
        }
        // Allow optional comma or just newline separation
        if p.current_token.kind == .Comma {
            advance_token(p)
        }
        // Skip newlines after a branch/comma
		for p.current_token.kind == .Newline { advance_token(p) }
    }


    if !expect_peek(p, .RightBrace) { // Changed to expect_peek because '{' was consumed
        // Error handled by expect_peek
        // Need to advance past '}' if expect_peek was true (which it won't be on error)
        return nil
    }
     // If expect_peek was true, we are now past '}'
     // Correction: expect_peek *does* advance. But if the current token is already '}', expect_peek fails.
     // Let's adjust the logic.
     if p.current_token.kind != .RightBrace {
         parse_error(p, "Expected '}' to end pattern branches")
         return nil
     }
     advance_token(p) // Consume '}'


    node := new(Node)
	node^ = pattern^
	return node
}

// Parses one `pattern_expr : -> result_expr`
parse_branch :: proc(p: ^Parser) -> ^Branch {
    branch := new(Branch)

    // Parse the pattern part (left of ':')
    branch.pattern = parse_expression(p) // Assume patterns are expressions
    if branch.pattern == nil {
        parse_error(p, "Expected pattern expression in branch")
        return nil
    }

    if p.current_token.kind != .Colon {
        parse_error(p, "Expected ':' after pattern in branch")
        return nil
    }
    advance_token(p) // Consume ':'

    if p.current_token.kind != .PointingPush {
        parse_error(p, "Expected '->' after ':' in branch")
        return nil
    }
    // Don't consume '->' here, let parse_product handle it

    // Parse the result part (right of '->') as a Product node
    product_node := parse_product_statement(p) // This expects '->' and parses the following expr
    if product_node == nil {
         parse_error(p, "Expected product expression ('-> value') after ':' in branch")
         return nil
    }
    branch.product = product_node

    return branch
}


// Type: name or Type: {scope} or Type:
// Or name : Type (Need to clarify grammar. Assuming `Type : maybe_value`)
parse_constraint_statement :: proc(p: ^Parser) -> ^Node {
    constraint := new(Constraint)

    // The type part (before ':') is parsed as an expression
    constraint.constraint_type = parse_expression(p)
    if constraint.constraint_type == nil {
        parse_error(p, "Expected type expression before ':' in constraint statement")
        return nil
    }

    if p.current_token.kind != .Colon {
         // This might happen if parse_expression consumed the colon, adjust expr parsing?
         // Or if the statement started with Identifier and peek was Colon.
         parse_error(p, "Expected ':' after type expression in constraint statement")
         return nil
    }
    advance_token(p) // Consume ':'

    // Check if there's a value after the colon
    #partial switch p.current_token.kind {
    // Tokens that can start an expression (value)
    case .Identifier, .Integer, .Float, .Hexadecimal, .Binary, .String_Literal,
         .LeftBrace, .LeftParen, .At, .Ellipsis, .PointingPush, .Minus /* etc. */:
        value_expr := parse_expression(p)
        if value_expr != nil {
             value_maybe: Maybe(^Node)
             value_maybe = value_expr
             constraint.value = value_maybe
        } else {
            // Parsing expression failed after colon, treat as no value? Or error?
            parse_error(p, "Failed to parse value expression after ':' in constraint, assuming no value.")
            constraint.value = nil
        }
    case .Newline, .EOF, .RightBrace: // End of statement/scope likely means no value
         constraint.value = nil
    case: // Any other token likely indicates no value intended after ':'
         constraint.value = nil
    }

    node := new(Node)
    node^ = constraint^
    return node
}

// >- target
parse_event_push_statement :: proc(p: ^Parser) -> ^Node {
    push := new(EventPush)
    if p.current_token.kind != .EventPush {
        parse_error(p, "Expected '>-' for event push statement")
        return nil
    }
    advance_token(p) // Consume '>-'

    push.target = parse_expression(p)
    if push.target == nil {
        parse_error(p, "Expected target expression after '>-'")
        return nil
    }
    node := new(Node)
	node^ = push^
	return node
}

// -< handler
parse_event_pull_statement :: proc(p: ^Parser) -> ^Node {
    pull := new(EventPull)
     if p.current_token.kind != .EventPull {
        parse_error(p, "Expected '-<' for event pull statement")
        return nil
    }
    advance_token(p) // Consume '-<'

    pull.handler = parse_expression(p)
    if pull.handler == nil {
         parse_error(p, "Expected handler expression after '-<'")
         return nil
    }
    node := new(Node)
	node^ = pull^
	return node
}

// ...source or ...source { overrides }
// This looks more like an expression construct. Let's move it there.
parse_expansion_statement :: proc(p: ^Parser) -> ^Node {
     // Expansion is likely part of an expression, parse it as such.
     return parse_expression_statement(p)
}


// Statement that is just an expression (e.g., function call, reference)
parse_expression_statement :: proc(p: ^Parser) -> ^Node {
	expr := parse_expression(p)
	if expr == nil {
		// Error already reported by parse_expression
		return nil
	}

    // Optional semicolon statement terminator? If defined in grammar.
    // if p.current_token.kind == .Semicolon { advance_token(p) }

	return expr // The statement node *is* the expression node
}


// --- Expression Parsing ---

// Precedence levels (simple for now)
Precedence :: enum {
	Lowest,
	Resonance,    // >>- -<< (Binding/Assignment-like)
	Sum,          // + -
	Product,      // * / %
	Prefix,       // - ! ~
	Call,         // myFunc(...) - Not explicit yet
    Postfix,      // .prop {override} ? {pattern} ! [!] etc.
}

// TODO: Map Token_Kind to Precedence

// Main expression entry point (handles precedence later if needed)
parse_expression :: proc(p: ^Parser) -> ^Node {
	// For now, focus on primary and postfix expressions, then resonance
    left := parse_postfix_expression(p) // Start with highest precedence postfix/primary

    // Handle lowest precedence operators like resonance binding
    for p.current_token.kind == .ResonancePush || p.current_token.kind == .ResonancePull {
         op_kind := p.current_token.kind
         advance_token(p) // Consume '>>-' or '-<<'
         right := parse_postfix_expression(p) // Parse right-hand side
         if right == nil {
             parse_error(p, "Expected expression after resonance operator")
             return nil
         }

         if op_kind == .ResonancePush {
             push := new(ResonancePush)
             push.target = left // Target is on the left
             push.source = right
             new_left := new(Node)
             new_left^ = push^
             left = new_left
         } else { // ResonancePull
             pull := new(ResonancePull)
             pull.target = left // Target is on the left
             pull.source = right
             new_left := new(Node)
             new_left^ = pull^
             left = new_left
         }
    }

    return left // Return the potentially wrapped node
}


// Parse primary expressions and any postfix operators attached
parse_postfix_expression :: proc(p: ^Parser) -> ^Node {
	// 1. Parse the primary part
	left := parse_primary_expression(p)
	if left == nil {
		return nil
	}

	// 2. Loop for postfix operators
	loop: for {
		#partial switch p.current_token.kind {
		case .Dot: // Property Access: left.identifier
			advance_token(p) // Consume '.'
			if p.current_token.kind != .Identifier {
				parse_error(p, "Expected identifier after '.' for property access")
				return nil // Or return left? Depends on error recovery strategy
			}
			prop := new(Property)
			prop.source = left
			prop.property = Identifier{name = p.current_token.text}
			advance_token(p) // Consume identifier

			// Update left to be the new Property node for chaining (a.b.c)
			new_left := new(Node)
			new_left^ = prop^
			left = new_left

		case .LeftBrace: // Override: left { ... } or maybe Pattern target { ... } ?
            // Let's assume left { ... } is Override for now
			override := new(Override)
			override.source = left
			advance_token(p) // Consume '{'

			override.overrides = make([dynamic]^Node)
            // Parse statements inside the override block
            for p.current_token.kind != .RightBrace && p.current_token.kind != .EOF {
                 // Skip newlines
                for p.current_token.kind == .Newline { advance_token(p) }
                if p.current_token.kind == .RightBrace || p.current_token.kind == .EOF { break }

                stmt := parse_statement(p)
                if stmt != nil {
                    append(&override.overrides, stmt)
                } else {
                    parse_error(p, "Failed to parse statement inside override block, attempting recovery.")
                    // Basic recovery: skip until next newline or '}'
                    for p.current_token.kind != .EOF && p.current_token.kind != .Newline && p.current_token.kind != .RightBrace {
                        advance_token(p)
                    }
                }
                 // Skip newlines after statement
                for p.current_token.kind == .Newline { advance_token(p) }
            }

			if p.current_token.kind != .RightBrace {
				parse_error(p, "Expected '}' to close override block")
				// Return current `left`? Or nil?
                return nil
			}
			advance_token(p) // Consume '}'

			new_left := new(Node)
			new_left^ = override^
			left = new_left

        case .Question: // Pattern Match: left ? { ... }
            pattern := new(Pattern)
            pattern.target = left
            advance_token(p) // Consume '?'

            if p.current_token.kind != .LeftBrace {
                parse_error(p, "Expected '{' after '?' for pattern match expression")
                return nil
            }
            advance_token(p) // Consume '{'

            pattern.branches = make([dynamic]Branch)
            // Parse branches (similar logic to override block)
            for p.current_token.kind != .RightBrace && p.current_token.kind != .EOF {
                for p.current_token.kind == .Newline { advance_token(p) }
                if p.current_token.kind == .RightBrace || p.current_token.kind == .EOF { break }
                branch := parse_branch(p)
                if branch != nil {
                     append(&pattern.branches, branch^)
                } else {
                     parse_error(p, "Failed to parse branch in pattern expression, attempting recovery.")
                     for p.current_token.kind != .EOF && p.current_token.kind != .RightBrace && p.current_token.kind != .Newline && p.current_token.kind != .Identifier {
                         advance_token(p)
                     }
                }
                if p.current_token.kind == .Comma { advance_token(p) }
                for p.current_token.kind == .Newline { advance_token(p) }
            }

            if p.current_token.kind != .RightBrace {
                parse_error(p, "Expected '}' to close pattern match expression")
                return nil
            }
            advance_token(p) // Consume '}'

            new_left := new(Node)
            new_left^ = pattern^
            left = new_left


		case .Execute: // Direct execution: left!
             // Also handle variations like [!], (!), <!>, |!| here
             exec_kind := Execution_Kind.Direct
             advance_token(p) // Consume '!'

             exec := new(Execute)
             exec.kind = exec_kind
             exec.value = left

             new_left := new(Node)
             new_left^ = exec^
             left = new_left

        case .LeftBracket: // Potential Parallel execution: left [!]
             if p.peek_token.kind == .Execute {
                 advance_token(p) // Consume '['
                 advance_token(p) // Consume '!'
                 if p.current_token.kind == .RightBracket {
                     advance_token(p) // Consume ']'
                     exec := new(Execute)
                     exec.kind = .Parallel
                     exec.value = left
                     new_left := new(Node)
                     new_left^ = exec^
                     left = new_left
                 } else {
                     parse_error(p, "Expected ']' after '[!' for parallel execution")
                     break loop // Stop postfix parsing on error
                 }
             } else {
                 // Just a regular bracket, not execution syntax
                 break loop
             }

        case .LeftParen: // Potential Background execution: left (!) or Composition (value(arg))?
             // For now, assume left (!) is background execution
             if p.peek_token.kind == .Execute {
                 advance_token(p) // Consume '('
                 advance_token(p) // Consume '!'
                 if p.current_token.kind == .RightParen {
                     advance_token(p) // Consume ')'
                     exec := new(Execute)
                     exec.kind = .Background
                     exec.value = left
                     new_left := new(Node)
                     new_left^ = exec^
                     left = new_left
                 } else {
                     parse_error(p, "Expected ')' after '(!' for background execution")
                     break loop // Stop postfix parsing on error
                 }
             } else {
                 // Could be function call syntax value(arg) or just parenthesized expression
                 // If function calls are like `name{arg->val}!` then we don't need value(arg)
                 // Break loop if it's not execution
                 break loop
             }

         // TODO: Add cases for <!> and |!| if lexer supports them or parse them here compositionally

		case: // Not a postfix operator we handle here
			break loop
		}
	}

	return left
}


// Parse the most basic units of expressions
parse_primary_expression :: proc(p: ^Parser) -> ^Node {
	#partial switch p.current_token.kind {
	case .Identifier:
        // Handle 'maybe{Type}' syntax specifically if needed
        if p.current_token.text == "maybe" && p.peek_token.kind == .LeftBrace {
            advance_token(p) // Consume 'maybe'
            advance_token(p) // Consume '{'
            if p.current_token.kind != .Identifier {
                parse_error(p, "Expected type identifier inside maybe{}")
                return nil
            }
            inner_type_name := p.current_token.text
            advance_token(p) // Consume inner type
            if p.current_token.kind != .RightBrace {
                 parse_error(p, "Expected '}' closing maybe{}")
                 return nil
            }
            advance_token(p) // Consume '}'

            ident := new(Identifier)
            // Represent maybe{T} as a single identifier string for simplicity now
            // A better approach might involve a specific ParameterizedType node
            ident.name = fmt.tprintf("maybe{%s}", inner_type_name)
            node := new(Node)
            node^ = ident^
            return node
        } else {
            // Regular identifier
            ident := new(Identifier)
            ident.name = p.current_token.text
            advance_token(p)
            node := new(Node)
            node^ = ident^
            return node
        }

	case .Integer, .Float, .Hexadecimal, .Binary, .String_Literal:
		return parse_literal(p)

	case .LeftBrace: // Scope { ... }
		return parse_scope_expression(p)

	case .LeftParen: // Grouping ( expression )
		advance_token(p) // Consume '('
		expr := parse_expression(p)
		if expr == nil { return nil }
		if !expect_peek(p, .RightParen) { // Changed to expect_peek
             // Need proper logic here based on current/peek state after parse_expression
             if p.current_token.kind != .RightParen {
                parse_error(p, "Expected ')' after grouped expression")
                return nil
             }
             // If parse_expression left us at ')', consume it.
              advance_token(p)
        } else {
            // expect_peek consumed ')' if it was the peek token
        }
		return expr

    case .At: // Filesystem reference @a.b.c
         return parse_filesystem_reference(p)

    case .Ellipsis: // Expansion ...source
         advance_token(p) // Consume '...'
         expand := new(Expansion)
         expand.source = parse_primary_expression(p) // Recursion for what follows '...'
         if expand.source == nil {
             parse_error(p, "Expected expression after '...' expansion")
             return nil
         }
         node := new(Node)
         node^ = expand^
         // Note: Overrides `...source { o }` are handled by parse_postfix_expression seeing '{' after an Expansion node.
         return node

     // Prefix operators could be handled here if needed (e.g., -x, !bool)
     // case .Minus, .Execute, .BitNot:
     //    return parse_prefix_expression(p)

	case:
		parse_error(p, fmt.tprintf("Unexpected token in primary expression: %v ('%s')", p.current_token.kind, p.current_token.text))
		return nil
	}
}

parse_literal :: proc(p: ^Parser) -> ^Node {
	lit := new(Literal)
	lit.value = p.current_token.text

	#partial switch p.current_token.kind {
	case .Integer:        lit.kind = .Integer
	case .Float:          lit.kind = .Float
	case .Hexadecimal:    lit.kind = .Hexadecimal
	case .Binary:         lit.kind = .Binary
	case .String_Literal: lit.kind = .String
	case:
		parse_error(p, "Internal error: parse_literal called with non-literal token")
		return nil
	}
	advance_token(p)
	node := new(Node)
	node^ = lit^
	return node
}

// Parse a scope { stmt1 stmt2 ... } used as an expression
parse_scope_expression :: proc(p: ^Parser) -> ^Node {
	scope := new(Scope)
	scope.statements = make([dynamic]^Node)

	if p.current_token.kind != .LeftBrace {
        parse_error(p, "Expected '{' to start scope expression")
        return nil
    }
    advance_token(p) // Consume '{'

	// Parse statements until closing brace
	for p.current_token.kind != .RightBrace && p.current_token.kind != .EOF {
		// Skip newlines
        for p.current_token.kind == .Newline { advance_token(p) }
        if p.current_token.kind == .RightBrace || p.current_token.kind == .EOF { break }

		stmt := parse_statement(p)
		if stmt != nil {
			append(&scope.statements, stmt)
		} else {
			parse_error(p, "Failed to parse statement inside scope expression, attempting recovery.")
			// Basic recovery
            for p.current_token.kind != .EOF && p.current_token.kind != .Newline && p.current_token.kind != .RightBrace {
                advance_token(p)
            }
		}
        // Skip newlines after statement
        for p.current_token.kind == .Newline { advance_token(p) }
	}

	if p.current_token.kind != .RightBrace {
        parse_error(p, "Expected '}' to end scope expression")
        return nil // Or potentially return partially parsed scope?
    }
	advance_token(p) // Consume '}'

	node := new(Node)
	node^ = scope^
	return node
}

// Parse @a.b.c reference
parse_filesystem_reference :: proc(p: ^Parser) -> ^Node {
    fs_node := new(FileSystem)
    if p.current_token.kind != .At {
        parse_error(p, "Expected '@' to start filesystem reference")
        return nil
    }
    advance_token(p) // Consume '@'

    // The path part after '@' is parsed like a primary expression,
    // which will handle identifiers and subsequent property accesses.
    path_expr := parse_postfix_expression(p) // Use postfix to handle a.b.c correctly
    if path_expr == nil {
         parse_error(p, "Expected path expression (identifier or property access) after '@'")
         return nil
    }
    // Ensure it resulted in an Identifier or Property chain
    #partial switch path_expr^ {
        case Identifier, Property:
            // Okay
        case:
            parse_error(p, "Filesystem reference path must be an identifier or property access")
            return nil
    }

    fs_node.path = path_expr

    node := new(Node)
	node^ = fs_node^
	return node
}


// === MAIN FUNCTION (Entry Point) ===
main :: proc() {
	if len(os.args) < 2 {
		fmt.println("Usage: parser <filename>")
		os.exit(1)
	}

	filename := os.args[1]
	source_bytes, ok := os.read_entire_file(filename)
	if !ok {
		fmt.printf("Error: Could not read file '%s'\n", filename)
		os.exit(1)
	}
	defer delete(source_bytes)
	source := string(source_bytes) // Assume UTF-8

	// Initialize lexer & parser
	lexer: Lexer
	init_lexer(&lexer, source)

	parser: Parser
	init_parser(&parser, &lexer)

	fmt.println("Parsing file:", filename)

	// Parse the file
	ast_root := parse_program(&parser)

	// Check for errors
	if len(parser.errors) > 0 {
		fmt.printf("Parsing failed with %d errors:\n", len(parser.errors))
		for err in parser.errors {
			fmt.println("- ", err)
		}
		os.exit(1)
	}

	if ast_root == nil {
		fmt.println("Parsing failed: No AST generated (unexpected error).")
		os.exit(1)
	}

	// Print AST
	fmt.println("Successfully parsed file!")
	print_ast(ast_root, 0)

}

// === AST PRINTER (Updated for new/modified nodes) ===
print_ast :: proc(node: ^Node, indent: int) {
	if node == nil {
		fmt.printf("%s<nil>\n", strings.repeat("  ", indent))
		return
	}

	indent_str := strings.repeat("  ", indent)

	#partial switch n in node^ {
	case Program:
		fmt.printf("%sProgram\n", indent_str)
		for stmt in n.statements {
			print_ast(stmt, indent + 1)
		}
	case Pointing:
		fmt.printf("%sPointing '%s' ->\n", indent_str, n.name)
		print_ast(n.value, indent + 1)
	case Identifier:
		fmt.printf("%sIdentifier: %s\n", indent_str, n.name)
	case Scope:
		fmt.printf("%sScope\n", indent_str)
		for stmt in n.statements {
			print_ast(stmt, indent + 1)
		}
	case Override:
		fmt.printf("%sOverride\n", indent_str)
		fmt.printf("%s  Source:\n", indent_str)
		print_ast(n.source, indent + 2)
		fmt.printf("%s  Overrides:\n", indent_str)
		for override_stmt in n.overrides {
			print_ast(override_stmt, indent + 2)
		}
	case Product:
		fmt.printf("%sProduct ->\n", indent_str)
		print_ast(n.value, indent + 1)
	case Pattern:
		fmt.printf("%sPattern ?\n", indent_str)
		fmt.printf("%s  Target:\n", indent_str)
		print_ast(n.target, indent + 2)
		fmt.printf("%s  Branches:\n", indent_str)
		for branch in n.branches {
			print_ast(&branch, indent + 2) // Print Branch node itself
		}
	case Branch: // Added case for printing Branch directly
        // Note: Need to pass pointer to branch for this case
        b_ptr := (^Branch)(node) // Cast Node ptr back to Branch ptr
		fmt.printf("%sBranch:\n", indent_str)
		fmt.printf("%s  Pattern:\n", indent_str)
		print_ast(b_ptr.pattern, indent + 2)
		fmt.printf("%s  Result:\n", indent_str)
		print_ast(b_ptr.product, indent + 2) // Product is the -> expr node

	case Constraint:
		fmt.printf("%sConstraint:\n", indent_str)
        fmt.printf("%s  Type:\n", indent_str)
		print_ast(n.constraint_type, indent + 2)
		if val, ok := n.value.?; ok && val != nil {
			fmt.printf("%s  Value:\n", indent_str)
			print_ast(val, indent + 2)
		} else {
             fmt.printf("%s  Value: <none>\n", indent_str)
        }
	case Operator: // Basic binary operator printing
		fmt.printf("%sOperator '%v'\n", indent_str, n.kind)
		fmt.printf("%s  Left:\n", indent_str)
		print_ast(n.left, indent + 2)
		fmt.printf("%s  Right:\n", indent_str)
		print_ast(n.right, indent + 2)

	case Execute:
		fmt.printf("%sExecute [%v]\n", indent_str, n.kind) // Show execution kind
		print_ast(n.value, indent + 1)

	case Literal:
		fmt.printf("%sLiteral (%v): %s\n", indent_str, n.kind, n.value)

	case Property:
		fmt.printf("%sProperty Access\n", indent_str)
        fmt.printf("%s  Source:\n", indent_str)
		print_ast(n.source, indent + 1)
        fmt.printf("%s  Property: %s\n", indent_str, n.property.name)

	case Expansion:
		fmt.printf("%sExpansion ...\n", indent_str)
        fmt.printf("%s  Source:\n", indent_str)
		print_ast(n.source, indent + 1)

	case FileSystem:
		fmt.printf("%sFileSystem @\n", indent_str)
        fmt.printf("%s  Path:\n", indent_str)
		print_ast(n.path, indent + 1)

    // New Nodes
    case EventPush:
        fmt.printf("%sEventPush >-\n", indent_str)
        fmt.printf("%s  Target:\n", indent_str)
        print_ast(n.target, indent + 1)
    case EventPull:
        fmt.printf("%sEventPull -<\n", indent_str)
        fmt.printf("%s  Handler:\n", indent_str)
        print_ast(n.handler, indent + 1)
    case ResonancePush:
        fmt.printf("%sResonancePush >>-\n", indent_str)
        fmt.printf("%s  Target:\n", indent_str)
        print_ast(n.target, indent + 1)
        fmt.printf("%s  Source:\n", indent_str)
        print_ast(n.source, indent + 1)
    case ResonancePull:
        fmt.printf("%sResonancePull -<<\n", indent_str)
        fmt.printf("%s  Target:\n", indent_str)
        print_ast(n.target, indent + 1)
        fmt.printf("%s  Source:\n", indent_str)
        print_ast(n.source, indent + 1)

	case:
		fmt.printf("%sUnknown node type %T\n", indent_str, node^)
	}
}
