package compiler

import "core:fmt"
import "core:os"

// === TOKEN ENUM ===
Token_Kind :: enum {
	Invalid, EOF, Identifier,

	// Numbers
	Integer, Float, Hexadecimal, Binary,

	// String Literal
	String_Literal,

	// Executors
	Execute, // !

	// Assignators
	PointingPush, // ->
	PointingPull, // <-
	EventPush,    // >-
	EventPull,    // -<
	ResonancePush, // >>-
	ResonancePull, // -<<

	// Comparisons
	Equal,        // =
	LessThan,     // <
	GreaterThan,  // >
	LessEqual,    // <=
	GreaterEqual, // >=

	// Separators
	Colon,      // :
	Question,   // ?
	Dot,        // .
	DoubleDot,  // ..
	Ellipsis,   // ...
	Newline,    // \n

  Range,      // 1..2 (full range)
	PrefixRange,// ..1
	PostfixRange,// 1..

	// Grouping
	LeftBrace,  // {
	RightBrace, // }
	LeftParen,  // (
	RightParen, // )

	// Math & Logic
	Plus,      // +
	Minus,     // -
	Asterisk,  // *
	Slash,     // /
	Percent,   // %
	BitAnd,    // &
	BitOr,     // |
	BitXor,    // ^
	BitNot,    // ~

	// Comments (Not returned, just skipped)
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
	switch l.source[l.pos] {
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
			l.pos += 1
			return Token{kind = .String_Literal, text = l.source[start:l.pos - 1], pos = start}
		}
		return Token{kind = .Invalid, text = "Unterminated string", pos = start}
	case '{': l.pos += 1; return Token{kind = .LeftBrace, text = "{", pos = start}
	case '}': l.pos += 1; return Token{kind = .RightBrace, text = "}", pos = start}
	case '(': l.pos += 1; return Token{kind = .LeftParen, text = "(", pos = start}
	case ')': l.pos += 1; return Token{kind = .RightParen, text = ")", pos = start}
	case '!': l.pos += 1; return Token{kind = .Execute, text = "!", pos = start}
	case ':': l.pos += 1; return Token{kind = .Colon, text = ":", pos = start}
  case '.':
		// Check for ranges
		if l.pos + 1 < len(l.source) && l.source[l.pos + 1] == '.' {
			l.pos += 2  // Skip ".."
			// Open-ended range "..."
			if l.pos < len(l.source) && l.source[l.pos] == '.' {
				l.pos += 1
				return Token{kind = .Ellipsis, text = "...", pos = start}
			}
			// Prefix range "..1"
			if is_digit(l.source[l.pos]) {
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
			}
		}
		return Token{kind = .GreaterThan, text = ">", pos = start}
	case '/':
		if l.pos + 1 < len(l.source) && l.source[l.pos + 1] == '/' {
			l.pos += 2
			for l.pos < len(l.source) && l.source[l.pos] != '\n' {
				l.pos += 1
			}
			return next_token(l)
		}
		if l.pos + 1 < len(l.source) && l.source[l.pos + 1] == '*' {
			l.pos += 2
			for l.pos + 1 < len(l.source) &&
				!(l.source[l.pos] == '*' && l.source[l.pos + 1] == '/') {
				l.pos += 1
			}
			l.pos += 2
			return next_token(l)
		}
		l.pos += 1
		return Token{kind = .Slash, text = "/", pos = start}
	case '+': l.pos += 1; return Token{kind = .Plus, text = "+", pos = start}
	case '-':
		l.pos += 1
		return Token{kind = .Minus, text = "-", pos = start}
	case '*': l.pos += 1; return Token{kind = .Asterisk, text = "*", pos = start}
	case '%': l.pos += 1; return Token{kind = .Percent, text = "%", pos = start}
	case '|': l.pos += 1; return Token{kind = .BitOr, text = "|", pos = start}
	case '&': l.pos += 1; return Token{kind = .BitAnd, text = "&", pos = start}
	case '^': l.pos += 1; return Token{kind = .BitXor, text = "^", pos = start}
	case '~': l.pos += 1; return Token{kind = .BitNot, text = "~", pos = start}


case '0':
		if l.pos + 1 < len(l.source) {
			// Hexadecimal
			if l.source[l.pos + 1] == 'x' {
				l.pos += 2
				start = l.pos
				for l.pos < len(l.source) && is_hex_digit(l.source[l.pos]) {
					l.pos += 1
				}
				return Token{kind = .Hexadecimal, text = l.source[start:l.pos], pos = start}
			} else if l.source[l.pos + 1] == 'b' {
				l.pos += 2
				start = l.pos
				for l.pos < len(l.source) && (l.source[l.pos] == '0' || l.source[l.pos] == '1') {
					l.pos += 1
				}
				return Token{kind = .Binary, text = l.source[start:l.pos], pos = start}
			} else if l.pos < len(l.source) && l.source[l.pos] == '.' {
				if l.pos + 1 < len(l.source) && is_digit(l.source[l.pos + 1]) {
					l.pos += 1
					for l.pos < len(l.source) && is_digit(l.source[l.pos]) {
						l.pos += 1
					}
					// If another `.` follows, it's invalid (`2.2..2.45.3`)
					if l.pos < len(l.source) && l.source[l.pos] == '.' {
						return Token{kind = .Invalid, text = "Invalid floating-point number", pos = start}
					}
					return Token{kind = .Float, text = l.source[start:l.pos], pos = start}
				}
			}

	case '.':
		// Check for ranges
		if l.pos + 1 < len(l.source) && l.source[l.pos + 1] == '.' {
			l.pos += 2
			if l.pos < len(l.source) && l.source[l.pos] == '.' {
				l.pos += 1
				return Token{kind = .Ellipsis, text = "...", pos = start} // `...`
			}
			return Token{kind = .DoubleDot, text = "..", pos = start} // `..`
		}
		l.pos += 1
		return Token{kind = .Dot, text = ".", pos = start}

	case '=':
		l.pos += 1
		return Token{kind = .Equal, text = "=", pos = start}

	case:
		// Check if it's a number
		if is_digit(l.source[l.pos]) {
			start = l.pos
			for l.pos < len(l.source) && is_digit(l.source[l.pos]) {
				l.pos += 1
			}
			// Floating point check
			if l.pos < len(l.source) && l.source[l.pos] == '.' {
				if l.pos + 1 < len(l.source) && is_digit(l.source[l.pos + 1]) {
					l.pos += 1
					for l.pos < len(l.source) && is_digit(l.source[l.pos]) {
						l.pos += 1
					}
					// If another `.` follows, it's invalid (`2.2..2.45.3`)
					if l.pos < len(l.source) && l.source[l.pos] == '.' {
						return Token{kind = .Invalid, text = "Invalid floating-point number", pos = start}
					}
					return Token{kind = .Float, text = l.source[start:l.pos], pos = start}
				}
			}
			return Token{kind = .Integer, text = l.source[start:l.pos], pos = start}
		}

		// Identifiers
		if is_alnum(l.source[l.pos]) {
			start = l.pos
			for l.pos < len(l.source) && is_alnum(l.source[l.pos]) {
				l.pos += 1
			}
			return Token{kind = .Identifier, text = l.source[start:l.pos], pos = start}
		}
	}


	// **Catch unknown tokens**
	l.pos += 1
	return Token{kind = .Invalid, text = string(l.source[start:l.pos]), pos = start}
}

// === HELPERS ===
is_digit :: proc(c: u8) -> bool {return c >= '0' && c <= '9'}
is_hex_digit :: proc(c: u8) -> bool {return(
		is_digit(c) ||
		(c >= 'a' && c <= 'f') ||
		(c >= 'A' && c <= 'F') \
	)}

// === HELPERS ===
is_space :: #force_inline proc(c: u8) -> bool {
	return c == ' ' || c == '\t' || c == '\r'
}


is_alnum :: proc(c: u8) -> bool {
	return is_digit(c) || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_'
}

skip_whitespace :: #force_inline proc(l: ^Lexer) {
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

	for {
		token := next_token(&lexer)
		fmt.printf("Token: %-15s Text: '%s' Position: %d\n", token.kind, token.text, token.pos)
		if token.kind == .EOF {
			break
		}
	}
}
