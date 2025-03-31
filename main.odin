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
			if branch.pattern != nil { 	// Changed from branch.constraint
				fmt.printf("%s      Pattern:\n", indent_str)
				print_ast(branch.pattern, indent + 8) // Changed from branch.constraint.value
			}
			if branch.product != nil {
				fmt.printf("%s      Match:\n", indent_str)
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

Property :: struct {
	source:   ^Node,
	property: ^Node,
}

Expand :: struct {
	target: ^Node,
}

FileSystem :: struct {
	target: ^Node,
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
	Property,
	Expand,
	FileSystem,
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


// Add this utility function to print token streams for debugging
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

    temp_lexer := parser.lexer^  // Make a copy of the lexer
    temp_parser: Parser
    init_parser(&temp_parser, &temp_lexer)

    // Advance to match the current state
    for temp_parser.current_token.pos < orig_current.pos &&
        temp_parser.current_token.kind != .EOF {
        advance_token(&temp_parser)
    }

    // Print the next 'count' tokens
    for i := 0; i < count && temp_parser.current_token.kind != .EOF; i += 1 {
        fmt.printf("%d: %v '%s'\n", i+1, temp_parser.current_token.kind, temp_parser.current_token.text)
        advance_token(&temp_parser)
    }

    fmt.println("=== END TOKEN STREAM ===\n")
}


// Add a new function to parse constraint statements (type:value)
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
        // No value after the colon, leave value as nil (Type:)
        constraint.value = nil
    }

    result := new(Node)
    result^ = constraint^
    return result
}

// Statement can be a pointing, pattern match, etc.
parse_statement :: proc(parser: ^Parser) -> ^Node {
    fmt.printf("\nParse statement, current token: %v '%s'\n",
               parser.current_token.kind, parser.current_token.text)

    #partial switch parser.current_token.kind {
    case .Integer, .Float, .Hexadecimal, .Binary, .String_Literal:
        fmt.println("Parsing literal")
        return parse_literal(parser)

case .Question:
    fmt.println("Found standalone ? token")
    advance_token(parser)

    if parser.current_token.kind == .LeftBrace {
        // This should create a pattern with an implicit target
        // NOT parse it as a scope
        pattern := new(Pattern)
        pattern.target = nil  // Implicit target
        pattern.value = make([dynamic]Branch)

        // Parse branches inside the braces
        advance_token(parser)  // Consume the {

        // [parsing branches code here]

        // Return a proper pattern node
        result := new(Node)
        result^ = pattern^
        return result
    } else {
        fmt.println("Error: Expected { after standalone ? token")
        return nil
    }
    case .Identifier:
        // Save the identifier name
        id_name := parser.current_token.text
        fmt.printf("Found identifier: '%s'\n", id_name)
        advance_token(parser)

        fmt.printf("After identifier, token: %v '%s'\n",
                   parser.current_token.kind, parser.current_token.text)

        // Check if it's a pattern match (identifier ?)
        if parser.current_token.kind == .Question {
            fmt.printf("Found ? after '%s', parsing as pattern\n", id_name)
            debug_print_tokens(parser, 5)  // Print next few tokens for debugging
            return parse_pattern(parser, id_name)
        }

        // Check if it's a pointing (identifier ->)
        if parser.current_token.kind == .PointingPush {
            fmt.printf("Found -> after '%s', parsing as pointing\n", id_name)
            return parse_pointing(parser, id_name)
        }

        // Check if it's a constraint (identifier:)
        if parser.current_token.kind == .Colon {
            fmt.printf("Found : after '%s', parsing as constraint\n", id_name)
            return parse_constraint_statement(parser, id_name)
        }

        // Check if this is an override (Identifier{...})
        if parser.current_token.kind == .LeftBrace {
            fmt.printf("Found { after '%s', parsing as override\n", id_name)
            return parse_override(parser, id_name)
        }

        // Just an identifier
        fmt.printf("Just identifier: '%s'\n", id_name)
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

parse_property_access :: proc(parser: ^Parser, source: ^Node) -> ^Node {
	// Create a property access node
	property_access := new(Property)
	property_access.source = source

	// Consume the dot
	advance_token(parser)

	// Parse the property identifier
	if parser.current_token.kind != .Identifier {
		fmt.println("Error: Expected identifier after dot in property access")
		return nil
	}

	property_name := parser.current_token.text
	advance_token(parser)

	// Create the property node
	property_node := new(Node)
	property_node^ = Identifier {
		name = property_name,
	}
	property_access.property = property_node

	// Check if there are more property accesses in a chain (a.b.c)
	if parser.current_token.kind == .Dot {
		result := new(Node)
		result^ = property_access^
		return parse_property_access(parser, result)
	}

	result := new(Node)
	result^ = property_access^
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

// Extract the override parsing logic to make the code more modular
parse_override :: proc(parser: ^Parser, id_name: string) -> ^Node {
    // Create an override node
    override := new(Override)

    // Create the source identifier node
    id := new(Node)
    id^ = Identifier{name = id_name}
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

// Parse a pattern match like: value ? { pattern1: -> result1, pattern2: -> result2 }
parse_pattern :: proc(parser: ^Parser, identifier_name: string) -> ^Node {
    // Create pattern node
    pattern := new(Pattern)

    // Set target identifier
    target := new(Node)
    target^ = Identifier{name = identifier_name}
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
            // Make a copy of the branch and add it to the pattern
            branch := branch_ptr^
            append(&pattern.value, branch)
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

// Parse a single branch in a pattern match
parse_branch :: proc(parser: ^Parser) -> ^Branch {
    // Create new branch
    branch := new(Branch)

    // Parse the pattern (constraint) part
    if parser.current_token.kind == .Identifier {
        // Simple identifier pattern
        pattern_name := parser.current_token.text
        advance_token(parser)

        pattern_node := new(Node)
        pattern_node^ = Identifier{name = pattern_name}
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
    // Note: parse_product consumes the -> token
    if product := parse_product(parser); product != nil {
        branch.product = product
    } else {
        fmt.println("Error: Failed to parse product after ->")
        return nil
    }

    return branch
}


// Updated product parsing to create proper Product nodes
parse_product :: proc(parser: ^Parser) -> ^Node {
    fmt.println("Parsing product with -> token")

    // Consume the ->
    advance_token(parser)
    fmt.printf("After ->, current: %v '%s'\n",
               parser.current_token.kind, parser.current_token.text)

    product := new(Product)

    // Parse the value
    if value := parse_expression(parser); value != nil {
        product.value = value
        fmt.println("Successfully parsed product value")
    } else {
        fmt.println("Error: Expected expression after ->")
        return nil
    }

    result := new(Node)
    result^ = product^
    return result
}

// Fix the parse_reference function to properly handle file system references
parse_reference :: proc(parser: ^Parser) -> ^Node {
	// Consommer @
	advance_token(parser)

	// Vérifier s'il y a un identifiant après @
	if parser.current_token.kind != .Identifier {
		fmt.println("Error: Expected identifier after @")
		return nil
	}

	// Créer le nœud FileSystem
	fs_node := new(FileSystem)

	// Analyser le premier identifiant
	id_name := parser.current_token.text
	advance_token(parser)

	// Créer un nœud identifiant initial
	ident_node := new(Node)
	ident_node^ = Identifier {
		name = id_name,
	}

	// Si aucun accès de propriété ne suit, retourner le nœud FileSystem de base
	if parser.current_token.kind != .Dot {
		fs_node.target = ident_node
		result := new(Node)
		result^ = fs_node^
		return result
	}

	// Gérer la chaîne de propriétés (lib.geometry.Plane)
	current_node := ident_node

	// Traiter tous les points et identifiants dans la chaîne
	for parser.current_token.kind == .Dot {
		// Consommer le point
		advance_token(parser)

		// S'attendre à un identifiant
		if parser.current_token.kind != .Identifier {
			fmt.println("Error: Expected identifier after dot")
			return nil
		}

		// Obtenir le nom de la propriété
		property_name := parser.current_token.text
		advance_token(parser)

		// Créer le nœud de propriété
		property := new(Property)
		property.source = current_node

		// Créer l'identifiant de propriété
		prop_ident := new(Node)
		prop_ident^ = Identifier {
			name = property_name,
		}
		property.property = prop_ident

		// Mettre à jour le nœud courant à cette propriété
		property_node := new(Node)
		property_node^ = property^
		current_node = property_node
	}

	// Définir la chaîne de propriétés finale comme cible du FileSystem
	fs_node.target = current_node

	result := new(Node)
	result^ = fs_node^
	return result
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

parse_expansion :: proc(parser: ^Parser) -> ^Node {
	// Consommer ...
	advance_token(parser)

	// Créer le nœud d'expansion
	expand := new(Expand)

	// Analyser l'expression cible
	if parser.current_token.kind == .At {
		// Cas spécial pour la référence au système de fichiers
		if target := parse_reference(parser); target != nil {
			expand.target = target
		} else {
			fmt.println("Error: Failed to parse file system reference after ...")
			return nil
		}
	} else {
		// Cas d'expression générale
		if target := parse_expression(parser); target != nil {
			expand.target = target
		} else {
			fmt.println("Error: Expected expression after ...")
			return nil
		}
	}

	// Créer le résultat pour le nœud d'expansion
	expand_result := new(Node)
	expand_result^ = expand^

	// Vérifier les overrides dans les accolades
	if parser.current_token.kind == .LeftBrace {
		// Créer un nœud override avec l'expansion comme source
		override := new(Override)
		override.source = expand_result

		// Consommer l'accolade gauche
		advance_token(parser)

		// Initialiser le tableau d'overrides
		override.overrides = make([dynamic]Node)

		// Analyser les instructions jusqu'à l'accolade fermante
		for parser.current_token.kind != .RightBrace && parser.current_token.kind != .EOF {
			// Ignorer les sauts de ligne
			for parser.current_token.kind == .Newline {
				advance_token(parser)
			}

			if parser.current_token.kind == .RightBrace {
				break
			}

			// Analyser l'instruction et l'ajouter aux overrides
			if node := parse_statement(parser); node != nil {
				append(&override.overrides, node^)
			} else {
				// Ignorer les tokens problématiques
				advance_token(parser)
			}

			// Ignorer les sauts de ligne finaux
			for parser.current_token.kind == .Newline {
				advance_token(parser)
			}
		}

		// Consommer l'accolade fermante
		if !expect_token(parser, .RightBrace) {
			return nil
		}

		// Retourner le nœud override
		result := new(Node)
		result^ = override^
		return result
	}

	// Si pas d'overrides, retourner simplement le nœud d'expansion
	return expand_result
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
            // Start building property chain
            current := id_node

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

            // Check for value after colon
            if parser.current_token.kind == .Identifier ||
               parser.current_token.kind == .Integer ||
               parser.current_token.kind == .Float ||
               parser.current_token.kind == .String_Literal ||
               parser.current_token.kind == .Hexadecimal ||
               parser.current_token.kind == .Binary ||
               parser.current_token.kind == .LeftBrace ||
               parser.current_token.kind == .At {

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

        // Check for override (identifier followed by left brace)
        if parser.current_token.kind == .LeftBrace {
            // Create an override node
            override := new(Override)

            // Set the source
            override.source = id_node

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

        // Just a regular identifier
        return id_node

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
