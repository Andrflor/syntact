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

parse_expression :: proc(p: ^Parser) -> Node {
	left := parse_primary(p)

	for p.current.kind == Token_Kind.Plus || p.current.kind == Token_Kind.Minus {
		op := p.current
		next_token(p)
		right := parse_primary(p)
		left = Node {
			kind   = Node_Kind.BinaryOp,
			binary = BinaryNode{left, op, right},
		}
	}

	return left
}

parse_primary :: proc(p: ^Parser) -> Node {
	if p.current.kind == Token_Kind.Identifier {
		node := Node {
			kind = Node_Kind.Identifier,
			text = p.current.text,
		}
		next_token(p)
		return node
	}
	if p.current.kind == Token_Kind.Integer {
		node := Node {
			kind  = Node_Kind.Literal,
			value = p.current.text,
		}
		next_token(p)
		return node
	}
	return Node{} // Error case
}

parse_statement :: proc(p: ^Parser) -> Node {
	if p.current.kind == Token_Kind.Identifier {
		ident := p.current
		next_token(p)
		if p.current.kind == Token_Kind.PointingPush {
			next_token(p)
			expr := parse_expression(p)
			return Node{kind = Node_Kind.Assignment, assign = AssignmentNode{ident, expr}}
		}
	}
	return Node{}
}

// === CODE GENERATION ===
Codegen :: struct {
	code: []u8,
}

emit_mov_imm :: proc(gen: ^Codegen, reg: u8, imm: i32) {
	gen.code = append(gen.code, 0xB8 + reg)
	gen.code = append(
		gen.code,
		u8(imm & 0xFF),
		u8((imm >> 8) & 0xFF),
		u8((imm >> 16) & 0xFF),
		u8((imm >> 24) & 0xFF),
	)
}

emit_add :: proc(gen: ^Codegen, dst: u8, src: u8) {
	gen.code = append(gen.code, 0x01, 0xC0 + dst + (src << 3))
}

codegen_expr :: proc(gen: ^Codegen, node: Node) {
	if node.kind == Node_Kind.Literal {
		emit_mov_imm(gen, 0, std.str_to_i32(node.value))
	} else if node.kind == Node_Kind.BinaryOp {
		codegen_expr(gen, node.binary.left)
		emit_mov_imm(gen, 1, std.str_to_i32(node.binary.right.value))
		emit_add(gen, 0, 1)
	}
}

compile :: proc(source: string) -> []u8 {
	lexer := Lexer{source, 0}
	parser := Parser{&lexer}
	next_token(&parser)
	node := parse_statement(&parser)
	gen := Codegen{[]u8{}}
	codegen_expr(&gen, node.assign.expr)
	return gen.code
}

// === ELF FILE WRITING ===
write_elf :: proc(code: []u8) {
	elf_header := []u8 {
		0x7F,
		'E',
		'L',
		'F', // Magic number
		2,
		1,
		1,
		0, // 64-bit, little-endian, ELF version
		0,
		0,
		0,
		0,
		0,
		0,
		0,
		0, // Padding
		2,
		0,
		0x3E,
		0, // Executable file, x86-64
		1,
		0,
		0,
		0, // ELF version
		0x78,
		0x00,
		0x40,
		0, // Entry point
		0x40,
		0,
		0,
		0, // Program header table offset
		0,
		0,
		0,
		0, // Section header table offset
		0,
		0,
		0,
		0, // Flags
		0x40,
		0,
		0x38,
		0, // Header size, program header entry size
		1,
		0,
		0,
		0, // Number of program headers
		0,
		0,
		0,
		0, // Number of section headers
	}

	// Write ELF header and machine code to file
	file := os.create("output.elf")
	defer file.close()
	file.write(elf_header)
	file.write(code)
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
		fmt.println("Usage: lexer <filename>")
		os.exit(1)
	}

	filename := os.args[1]
	source, ok := os.read_entire_file(filename)
	if !ok {
		fmt.printf("Error: Could not read file '%s'\n", filename)
		os.exit(1)
	}
	defer delete(source)

	lexer := Lexer {
		source = string(source),
	}
	fmt.println("Tokenizing file:", filename)


	code := compile(source)
	write_elf(code)

	// for {
	// 	token := next_token(&lexer)
	// 	fmt.printf("Token: %-15s Text: '%s' Position: %d\n", token.kind, token.text, token.pos)
	// 	if token.kind == .EOF {
	// 		break
	// 	}
	// }
}
