package compiler

import "core:fmt"
import "core:strings"

/* ======================================================================
 * SECTION 1: FUNDAMENTAL TYPES
 * ====================================================================== */

Span :: struct {
	start: u32,
	end:   u32,
}

EMPTY_SPAN :: Span{0, 0}

Node_Index :: distinct u32
INVALID_NODE :: Node_Index(0xFFFFFFFF)

Node_Kind :: enum u8 {
	Pointing,
	PointingPull,
	EventPush,
	EventPull,
	ResonancePush,
	ResonancePull,
	ScopeNode,
	Carve,
	Product,
	Branch,
	Identifier,
	Pattern,
	Constraint,
	Operator,
	Execute,
	CompileTime,
	Literal,
	Property,
	Expand,
	External,
	Range,
	Enforce,
	Unknown,
}

Literal_Kind :: enum u8 {
	Integer,
	Float,
	String,
	Bool,
	Hexadecimal,
	Binary,
}

Operator_Kind :: enum u8 {
	Add,
	Subtract,
	Multiply,
	Divide,
	Mod,
	Equal,
	Less,
	Greater,
	NotEqual,
	LessEqual,
	GreaterEqual,
	And,
	Or,
	Xor,
	Not,
	RShift,
	LShift,
}

ExecutionWrapper :: enum u8 {
	Threading,
	Parallel_CPU,
	Background,
	GPU,
}

Index_Range :: struct {
	start: u32,
	len:   u32,
}

EMPTY_RANGE :: Index_Range{0, 0}

Binary_Data :: struct {
	left:  Node_Index,
	right: Node_Index,
}

Unary_Data :: struct {
	operand: Node_Index,
}

Literal_Data :: struct {
	kind: Literal_Kind,
}

Identifier_Data :: struct {
	name:    Span,
	capture: Span,
}

Scope_Data :: struct {
	using _: Index_Range,
}

Carve_Data :: struct {
	source:   Node_Index,
	children: Index_Range,
}

Pattern_Data :: struct {
	target:   Node_Index,
	branches: Index_Range,
}

Execute_Data :: struct {
	target:   Node_Index,
	wrappers: Index_Range,
}

Operator_Node_Data :: struct {
	kind:  Operator_Kind,
	left:  Node_Index,
	right: Node_Index,
}

External_Data :: struct {
	name:  Span,
	scope: Node_Index,
}

EventPull_Data :: struct {
	from:       Node_Index,
	to:         Node_Index,
	catch_span: Span,
}

Node_Data :: struct #raw_union {
	binary:     Binary_Data,
	unary:      Unary_Data,
	literal:    Literal_Data,
	identifier: Identifier_Data,
	scope:      Scope_Data,
	carve:      Carve_Data,
	pattern:    Pattern_Data,
	execute:    Execute_Data,
	operator:   Operator_Node_Data,
	external:   External_Data,
	event_pull: EventPull_Data,
}

Ast :: struct {
	source:              string,
	node_kinds:          []Node_Kind,
	node_spans:          []Span,
	node_data:           []Node_Data,
	extra:               []Node_Index,
	extra_u8:            []u8,
	line_starts:         [dynamic]u32,
	line_starts_computed: bool,
}

Position :: struct {
	line:   int,
	column: int,
	offset: int,
}

ensure_line_starts :: proc(ast: ^Ast) {
	if ast.line_starts_computed do return
	ast.line_starts_computed = true
	if ast.line_starts == nil {
		ast.line_starts = make([dynamic]u32, 0, 64)
	}
	append(&ast.line_starts, 0)
	for i := 0; i < len(ast.source); i += 1 {
		if ast.source[i] == '\n' {
			append(&ast.line_starts, u32(i + 1))
		}
	}
}

span_to_position :: proc(ast: ^Ast, offset: u32) -> Position {
	ensure_line_starts(ast)
	lo, hi := 0, len(ast.line_starts) - 1
	for lo < hi {
		mid := (lo + hi + 1) / 2
		if ast.line_starts[mid] <= offset {
			lo = mid
		} else {
			hi = mid - 1
		}
	}
	return Position{
		line   = lo + 1,
		column = int(offset) - int(ast.line_starts[lo]) + 1,
		offset = int(offset),
	}
}

/* ======================================================================
 * SECTION 2: AST ACCESSOR API
 * ====================================================================== */

node_kind :: #force_inline proc(ast: ^Ast, idx: Node_Index) -> Node_Kind {
	return ast.node_kinds[idx]
}

node_span :: #force_inline proc(ast: ^Ast, idx: Node_Index) -> Span {
	return ast.node_spans[idx]
}

node_data :: #force_inline proc(ast: ^Ast, idx: Node_Index) -> Node_Data {
	return ast.node_data[idx]
}

node_position :: proc(ast: ^Ast, idx: Node_Index) -> Position {
	return span_to_position(ast, ast.node_spans[idx].start)
}

node_text :: #force_inline proc(ast: ^Ast, idx: Node_Index) -> string {
	s := ast.node_spans[idx]
	return ast.source[s.start:s.end]
}

node_left :: #force_inline proc(ast: ^Ast, idx: Node_Index) -> Node_Index {
	return ast.node_data[idx].binary.left
}

node_right :: #force_inline proc(ast: ^Ast, idx: Node_Index) -> Node_Index {
	return ast.node_data[idx].binary.right
}

node_children :: proc(ast: ^Ast, idx: Node_Index) -> []Node_Index {
	r := ast.node_data[idx].scope
	if r.len == 0 do return nil
	return ast.extra[r.start : r.start + r.len]
}

node_carve_source :: #force_inline proc(ast: ^Ast, idx: Node_Index) -> Node_Index {
	return ast.node_data[idx].carve.source
}

node_carve_children :: proc(ast: ^Ast, idx: Node_Index) -> []Node_Index {
	r := ast.node_data[idx].carve.children
	if r.len == 0 do return nil
	return ast.extra[r.start : r.start + r.len]
}

node_pattern_target :: #force_inline proc(ast: ^Ast, idx: Node_Index) -> Node_Index {
	return ast.node_data[idx].pattern.target
}

node_pattern_branches :: proc(ast: ^Ast, idx: Node_Index) -> []Node_Index {
	r := ast.node_data[idx].pattern.branches
	if r.len == 0 do return nil
	return ast.extra[r.start : r.start + r.len]
}

node_execute_target :: #force_inline proc(ast: ^Ast, idx: Node_Index) -> Node_Index {
	return ast.node_data[idx].execute.target
}

node_execute_wrappers :: proc(ast: ^Ast, idx: Node_Index) -> []u8 {
	r := ast.node_data[idx].execute.wrappers
	if r.len == 0 do return nil
	return ast.extra_u8[r.start : r.start + r.len]
}

node_operator_kind :: #force_inline proc(ast: ^Ast, idx: Node_Index) -> Operator_Kind {
	return ast.node_data[idx].operator.kind
}

node_operator_left :: #force_inline proc(ast: ^Ast, idx: Node_Index) -> Node_Index {
	return ast.node_data[idx].operator.left
}

node_operator_right :: #force_inline proc(ast: ^Ast, idx: Node_Index) -> Node_Index {
	return ast.node_data[idx].operator.right
}

node_unary_operand :: #force_inline proc(ast: ^Ast, idx: Node_Index) -> Node_Index {
	return ast.node_data[idx].unary.operand
}

node_name_span :: #force_inline proc(ast: ^Ast, idx: Node_Index) -> Span {
	return ast.node_data[idx].identifier.name
}

node_name_str :: proc(ast: ^Ast, idx: Node_Index) -> string {
	s := ast.node_data[idx].identifier.name
	if s.start == s.end do return ""
	return ast.source[s.start:s.end]
}

node_capture_str :: proc(ast: ^Ast, idx: Node_Index) -> string {
	s := ast.node_data[idx].identifier.capture
	if s.start == s.end do return ""
	return ast.source[s.start:s.end]
}

node_literal_kind :: #force_inline proc(ast: ^Ast, idx: Node_Index) -> Literal_Kind {
	return ast.node_data[idx].literal.kind
}

node_external_name :: proc(ast: ^Ast, idx: Node_Index) -> string {
	s := ast.node_data[idx].external.name
	if s.start == s.end do return ""
	return ast.source[s.start:s.end]
}

node_external_scope :: #force_inline proc(ast: ^Ast, idx: Node_Index) -> Node_Index {
	return ast.node_data[idx].external.scope
}

node_event_pull_from :: #force_inline proc(ast: ^Ast, idx: Node_Index) -> Node_Index {
	return ast.node_data[idx].event_pull.from
}

node_event_pull_to :: #force_inline proc(ast: ^Ast, idx: Node_Index) -> Node_Index {
	return ast.node_data[idx].event_pull.to
}

node_event_pull_catch :: proc(ast: ^Ast, idx: Node_Index) -> string {
	s := ast.node_data[idx].event_pull.catch_span
	if s.start == s.end do return ""
	return ast.source[s.start:s.end]
}

/* ======================================================================
 * SECTION 3: TOKEN DEFINITIONS AND LEXER
 * ====================================================================== */

Token_Kind :: enum u8 {
	Invalid,
	EOF,
	Identifier,

	Integer,
	Float,
	Hexadecimal,
	Binary,

	String_Literal,
	Bool_Literal,

	Execute,
	At,

	PointingPush,
	PointingPull,
	EventPush,
	EventPull,
	ResonancePush,
	ResonancePull,

	Equal,
	NotEqual,
	Less,
	Greater,
	LessEqual,
	GreaterEqual,

	PropertyAccess,
	PropertyFromNone,
	PropertyToNone,

	ConstraintBind,
	ConstraintFromNone,
	ConstraintToNone,

	Colon,
	Question,
	DoubleQuestion,
	QuestionExclamation,
	Dot,
	DoubleDot,
	Ellipsis,
	Range,
	PrefixRange,
	PostfixRange,

	LeftBrace,
	LeftBraceCarve,
	RightBrace,
	LeftParen,
	LeftParenNoSpace,
	RightParen,
	LeftBracket,
	RightBracket,

	Plus,
	Minus,
	Asterisk,
	Slash,
	Percent,
	And,
	Or,
	Xor,
	Not,
	RShift,
	LShift,
}

Token_Flags :: enum u8 {
	Line_Before      = 0,
	Space_Before     = 1,
	Separator_Before = 2,
}

Token :: struct {
	kind:  Token_Kind,
	span:  Span,
	flags: u8,
}

has_flag :: #force_inline proc(t: Token, flag: Token_Flags) -> bool {
	return (t.flags & (1 << u8(flag))) != 0
}

set_flag :: #force_inline proc(flags: ^u8, flag: Token_Flags) {
	flags^ |= (1 << u8(flag))
}

token_text :: #force_inline proc(source: string, t: Token) -> string {
	return source[t.span.start:t.span.end]
}

Lexer :: struct {
	source:     string,
	offset:     u32,
	source_len: u32,
}

init_lexer :: #force_inline proc(l: ^Lexer, source: string) {
	l.source = source
	l.offset = 0
	l.source_len = u32(len(source))
}

current_char :: #force_inline proc(l: ^Lexer) -> u8 {
	if l.offset >= l.source_len do return 0
	return l.source[l.offset]
}

peek_char :: #force_inline proc(l: ^Lexer, n: u32 = 1) -> u8 {
	pos := l.offset + n
	if pos >= l.source_len do return 0
	return l.source[pos]
}

has_space_before :: #force_inline proc(l: ^Lexer) -> bool {
	return l.offset > 0 && is_space(l.source[l.offset - 1])
}

has_space_after_char :: #force_inline proc(l: ^Lexer, char: u8) -> bool {
	if l.offset < l.source_len && l.source[l.offset] == char {
		return l.offset + 1 < l.source_len && is_space(l.source[l.offset + 1])
	}
	return false
}

skip_trivia :: #force_inline proc(l: ^Lexer) -> u8 {
	flags: u8 = 0
	for l.offset < l.source_len {
		c := l.source[l.offset]
		switch c {
		case ' ', '\t', '\r':
			set_flag(&flags, .Space_Before)
			l.offset += 1
		case '\n', ',':
			set_flag(&flags, .Line_Before)
			set_flag(&flags, .Separator_Before)
			l.offset += 1
		case:
			return flags
		}
	}
	return flags
}

next_token :: proc(l: ^Lexer) -> Token {
	flags: u8
	start: u32
	c: u8

	for {
		flags = skip_trivia(l)

		if l.offset >= l.source_len {
			return Token{kind = .EOF, span = Span{l.offset, l.offset}, flags = flags}
		}

		start = l.offset
		c = l.source[l.offset]

		// Comment handling (iterative, not recursive)
		if c == '/' && l.offset + 1 < l.source_len {
			if l.source[l.offset + 1] == '/' {
				l.offset += 2
				for l.offset < l.source_len && l.source[l.offset] != '\n' {
					l.offset += 1
				}
				continue
			}
			if l.source[l.offset + 1] == '*' {
				l.offset += 2
				depth : u32 = 1
				for l.offset < l.source_len && depth > 0 {
					if l.offset + 1 < l.source_len && l.source[l.offset] == '/' && l.source[l.offset + 1] == '*' {
						l.offset += 2
						depth += 1
					} else if l.offset + 1 < l.source_len && l.source[l.offset] == '*' && l.source[l.offset + 1] == '/' {
						l.offset += 2
						depth -= 1
					} else {
						l.offset += 1
					}
				}
				continue
			}
		}
		break
	}

	switch c {
	case '`', '"', '\'':
		return scan_string(l, start, flags)
	case '@':
		l.offset += 1
		return Token{kind = .At, span = Span{start, l.offset}, flags = flags}
	case '{':
		space_before := has_space_before(l)
		l.offset += 1
		if space_before || start == 0 {
			return Token{kind = .LeftBrace, span = Span{start, l.offset}, flags = flags}
		} else {
			return Token{kind = .LeftBraceCarve, span = Span{start, l.offset}, flags = flags}
		}
	case '}':
		l.offset += 1
		return Token{kind = .RightBrace, span = Span{start, l.offset}, flags = flags}
	case '[':
		l.offset += 1
		return Token{kind = .LeftBracket, span = Span{start, l.offset}, flags = flags}
	case ']':
		l.offset += 1
		return Token{kind = .RightBracket, span = Span{start, l.offset}, flags = flags}
	case '(':
		space_before := has_space_before(l)
		l.offset += 1
		if space_before || start == 0 {
			return Token{kind = .LeftParen, span = Span{start, l.offset}, flags = flags}
		} else {
			return Token{kind = .LeftParenNoSpace, span = Span{start, l.offset}, flags = flags}
		}
	case ')':
		l.offset += 1
		return Token{kind = .RightParen, span = Span{start, l.offset}, flags = flags}
	case '!':
		l.offset += 1
		if l.offset < l.source_len && l.source[l.offset] == '=' {
			l.offset += 1
			return Token{kind = .NotEqual, span = Span{start, l.offset}, flags = flags}
		}
		return Token{kind = .Execute, span = Span{start, l.offset}, flags = flags}
	case ':':
		space_before := has_space_before(l)
		space_after := has_space_after_char(l, ':')
		l.offset += 1
		if space_before {
			if space_after {
				return Token{kind = .Colon, span = Span{start, l.offset}, flags = flags}
			} else {
				return Token{kind = .ConstraintFromNone, span = Span{start, l.offset}, flags = flags}
			}
		} else {
			if space_after {
				return Token{kind = .ConstraintToNone, span = Span{start, l.offset}, flags = flags}
			} else {
				return Token{kind = .ConstraintBind, span = Span{start, l.offset}, flags = flags}
			}
		}
	case '?':
		l.offset += 1
		if l.offset < l.source_len {
			switch l.source[l.offset] {
			case '?':
				l.offset += 1
				return Token{kind = .DoubleQuestion, span = Span{start, l.offset}, flags = flags}
			case '!':
				l.offset += 1
				return Token{kind = .QuestionExclamation, span = Span{start, l.offset}, flags = flags}
			}
		}
		return Token{kind = .Question, span = Span{start, l.offset}, flags = flags}
	case '.':
		if l.offset + 1 < l.source_len && l.source[l.offset + 1] == '.' {
			has_before_delimiter := l.offset == 0 || is_before_delimiter(l.source[l.offset - 1])
			has_after_delimiter := l.offset + 2 >= l.source_len || is_after_delimiter(l.source[l.offset + 2])
			l.offset += 2
			if l.offset < l.source_len && l.source[l.offset] == '.' {
				l.offset += 1
				return Token{kind = .Ellipsis, span = Span{start, l.offset}, flags = flags}
			}
			if has_before_delimiter && has_after_delimiter {
				return Token{kind = .DoubleDot, span = Span{start, l.offset}, flags = flags}
			} else if has_before_delimiter {
				return Token{kind = .PrefixRange, span = Span{start, l.offset}, flags = flags}
			} else if has_after_delimiter {
				return Token{kind = .PostfixRange, span = Span{start, l.offset}, flags = flags}
			} else {
				return Token{kind = .Range, span = Span{start, l.offset}, flags = flags}
			}
		}
		space_before_dot := l.offset == 0 || is_before_delimiter(l.source[l.offset - 1])
		space_after_dot := has_space_after_char(l, '.') || (l.offset + 1 >= l.source_len)
		l.offset += 1
		if space_before_dot {
			if space_after_dot {
				return Token{kind = .Dot, span = Span{start, l.offset}, flags = flags}
			} else {
				return Token{kind = .PropertyFromNone, span = Span{start, l.offset}, flags = flags}
			}
		} else {
			if space_after_dot {
				return Token{kind = .PropertyToNone, span = Span{start, l.offset}, flags = flags}
			} else {
				return Token{kind = .PropertyAccess, span = Span{start, l.offset}, flags = flags}
			}
		}
	case '=':
		l.offset += 1
		return Token{kind = .Equal, span = Span{start, l.offset}, flags = flags}
	case '<':
		l.offset += 1
		if l.offset < l.source_len {
			if l.source[l.offset] == '=' {
				l.offset += 1
				return Token{kind = .LessEqual, span = Span{start, l.offset}, flags = flags}
			} else if l.source[l.offset] == '<' {
				l.offset += 1
				return Token{kind = .LShift, span = Span{start, l.offset}, flags = flags}
			} else if l.source[l.offset] == '-' {
				l.offset += 1
				return Token{kind = .PointingPull, span = Span{start, l.offset}, flags = flags}
			}
		}
		return Token{kind = .Less, span = Span{start, l.offset}, flags = flags}
	case '>':
		l.offset += 1
		if l.offset < l.source_len {
			if l.source[l.offset] == '=' {
				l.offset += 1
				return Token{kind = .GreaterEqual, span = Span{start, l.offset}, flags = flags}
			} else if l.source[l.offset] == '>' {
				if l.offset + 1 < l.source_len && l.source[l.offset + 1] == '-' {
					l.offset += 2
					return Token{kind = .ResonancePush, span = Span{start, l.offset}, flags = flags}
				}
				l.offset += 1
				return Token{kind = .RShift, span = Span{start, l.offset}, flags = flags}
			} else if l.source[l.offset] == '-' {
				l.offset += 1
				return Token{kind = .EventPush, span = Span{start, l.offset}, flags = flags}
			}
		}
		return Token{kind = .Greater, span = Span{start, l.offset}, flags = flags}
	case '-':
		l.offset += 1
		if l.offset < l.source_len {
			if l.source[l.offset] == '>' {
				l.offset += 1
				return Token{kind = .PointingPush, span = Span{start, l.offset}, flags = flags}
			} else if l.source[l.offset] == '<' {
				l.offset += 1
				if l.offset < l.source_len && l.source[l.offset] == '<' {
					l.offset += 1
					return Token{kind = .ResonancePull, span = Span{start, l.offset}, flags = flags}
				}
				return Token{kind = .EventPull, span = Span{start, l.offset}, flags = flags}
			}
		}
		return Token{kind = .Minus, span = Span{start, l.offset}, flags = flags}
	case '/':
		// Non-comment slash (comments handled above)
		l.offset += 1
		return Token{kind = .Slash, span = Span{start, l.offset}, flags = flags}
	case '0':
		if l.offset + 1 < l.source_len {
			next := l.source[l.offset + 1]
			if next == 'x' || next == 'X' {
				return scan_hexadecimal(l, start, flags)
			}
			if next == 'b' || next == 'B' {
				return scan_binary(l, start, flags)
			}
		}
		fallthrough
	case '1', '2', '3', '4', '5', '6', '7', '8', '9':
		return scan_number(l, start, flags)
	case '+':
		l.offset += 1
		return Token{kind = .Plus, span = Span{start, l.offset}, flags = flags}
	case '*':
		l.offset += 1
		return Token{kind = .Asterisk, span = Span{start, l.offset}, flags = flags}
	case '%':
		l.offset += 1
		return Token{kind = .Percent, span = Span{start, l.offset}, flags = flags}
	case '&':
		l.offset += 1
		return Token{kind = .And, span = Span{start, l.offset}, flags = flags}
	case '|':
		l.offset += 1
		return Token{kind = .Or, span = Span{start, l.offset}, flags = flags}
	case '^':
		l.offset += 1
		return Token{kind = .Xor, span = Span{start, l.offset}, flags = flags}
	case '~':
		l.offset += 1
		return Token{kind = .Not, span = Span{start, l.offset}, flags = flags}
	case:
		if IDENT_START[c] {
			l.offset += 1
			for l.offset < l.source_len && IDENT_CONTINUE[l.source[l.offset]] {
				l.offset += 1
			}
			text := l.source[start:l.offset]
			if text == "true" || text == "false" {
				return Token{kind = .Bool_Literal, span = Span{start, l.offset}, flags = flags}
			}
			return Token{kind = .Identifier, span = Span{start, l.offset}, flags = flags}
		}
		l.offset += 1
		return Token{kind = .Invalid, span = Span{start, l.offset}, flags = flags}
	}
}

scan_string :: proc(l: ^Lexer, start: u32, f: u8) -> Token {
	delimiter := l.source[l.offset]
	l.offset += 1
	for l.offset < l.source_len {
		current := l.source[l.offset]
		if current == delimiter {
			break
		}
		if current == '\\' && l.offset + 1 < l.source_len {
			l.offset += 2
		} else {
			l.offset += 1
		}
	}
	if l.offset < l.source_len {
		l.offset += 1
		return Token{kind = .String_Literal, span = Span{start, l.offset}, flags = f}
	}
	return Token{kind = .Invalid, span = Span{start, l.offset}, flags = f}
}

scan_hexadecimal :: #force_inline proc(l: ^Lexer, start: u32, f: u8) -> Token {
	l.offset += 2
	hex_start := l.offset
	for l.offset < l.source_len && is_hex_digit(l.source[l.offset]) {
		l.offset += 1
	}
	if l.offset == hex_start {
		return Token{kind = .Invalid, span = Span{start, l.offset}, flags = f}
	}
	return Token{kind = .Hexadecimal, span = Span{start, l.offset}, flags = f}
}

scan_binary :: #force_inline proc(l: ^Lexer, start: u32, f: u8) -> Token {
	l.offset += 2
	bin_start := l.offset
	for l.offset < l.source_len {
		c := l.source[l.offset]
		if c != '0' && c != '1' do break
		l.offset += 1
	}
	if l.offset == bin_start {
		return Token{kind = .Invalid, span = Span{start, l.offset}, flags = f}
	}
	return Token{kind = .Binary, span = Span{start, l.offset}, flags = f}
}

scan_number :: proc(l: ^Lexer, start: u32, f: u8) -> Token {
	for l.offset < l.source_len && is_digit(l.source[l.offset]) {
		l.offset += 1
	}
	if l.offset < l.source_len && l.source[l.offset] == '.' {
		if l.offset + 1 < l.source_len {
			next_char := l.source[l.offset + 1]
			if is_digit(next_char) {
				l.offset += 1
				for l.offset < l.source_len && is_digit(l.source[l.offset]) {
					l.offset += 1
				}
				return Token{kind = .Float, span = Span{start, l.offset}, flags = f}
			}
		}
	}
	return Token{kind = .Integer, span = Span{start, l.offset}, flags = f}
}


/* ======================================================================
 * SECTION 4: PARSER
 * ====================================================================== */

Precedence :: enum {
	NONE = 0,
	POINTING,
	ASSIGNMENT,
	PATTERN,
	OR,
	AND,
	EQUALITY,
	COMPARISON,
	TERM,
	FACTOR,
	CONSTRAINT,
	UNARY,
	SHIFT,
	RANGE,
	CALL,
	PRIMARY,
}

Parser_Error_Type :: enum {
	Syntax,
	Unexpected_Token,
	Invalid_Expression,
	Unclosed_Delimiter,
	Invalid_Operation,
	External_Error,
	Other,
}

Parse_Error :: struct {
	type:     Parser_Error_Type,
	message:  string,
	span:     Span,
	token:    Token,
	expected: Token_Kind,
	found:    Token_Kind,
}

Prefix_Proc :: proc(parser: ^Parser) -> Node_Index
Infix_Proc  :: proc(parser: ^Parser, left: Node_Index) -> Node_Index

prefix_table: [Token_Kind]Prefix_Proc
infix_table:  [Token_Kind]Infix_Proc
prec_table:   [Token_Kind]Precedence

@(init)
init_parse_tables :: proc "contextless" () {
	prefix_table[.Integer]         = parse_literal
	prefix_table[.Float]           = parse_literal
	prefix_table[.Hexadecimal]     = parse_literal
	prefix_table[.Binary]          = parse_literal
	prefix_table[.String_Literal]  = parse_literal
	prefix_table[.Bool_Literal]    = parse_literal
	prefix_table[.Identifier]      = parse_identifier

	prefix_table[.LeftBrace]        = parse_scope
	prefix_table[.LeftBraceCarve]   = parse_scope
	prefix_table[.LeftParen]        = parse_grouping
	prefix_table[.LeftParenNoSpace] = parse_grouping
	prefix_table[.At]               = parse_reference

	prefix_table[.PropertyFromNone]    = parse_property_from_none
	prefix_table[.Dot]                 = parse_invalid_property
	prefix_table[.ConstraintFromNone]  = parse_constraint_from_none
	prefix_table[.Colon]              = parse_invalid_constraint

	prefix_table[.Execute]           = parse_execute_prefix
	prefix_table[.Not]               = parse_unary
	prefix_table[.Minus]             = parse_unary
	prefix_table[.Equal]             = parse_prefix_comparison
	prefix_table[.NotEqual]          = parse_prefix_comparison
	prefix_table[.Less]              = parse_prefix_comparison
	prefix_table[.Greater]           = parse_prefix_comparison
	prefix_table[.LessEqual]         = parse_prefix_comparison
	prefix_table[.GreaterEqual]      = parse_prefix_comparison

	prefix_table[.DoubleDot]          = parse_empty_range
	prefix_table[.PrefixRange]        = parse_prefix_range
	prefix_table[.Range]              = parse_prefix_range
	prefix_table[.DoubleQuestion]     = parse_unknown
	prefix_table[.PointingPush]       = parse_product_prefix
	prefix_table[.PointingPull]       = parse_pointing_pull_prefix
	prefix_table[.EventPush]          = parse_event_push_prefix
	prefix_table[.EventPull]          = parse_event_pull_prefix
	prefix_table[.ResonancePush]      = parse_resonance_push_prefix
	prefix_table[.ResonancePull]      = parse_resonance_pull_prefix
	prefix_table[.Ellipsis]           = parse_expansion

	infix_table[.LeftBraceCarve]      = parse_carve
	infix_table[.LeftBracket]         = parse_left_bracket
	infix_table[.LeftParenNoSpace]    = parse_left_paren
	infix_table[.PropertyAccess]      = parse_property_access
	infix_table[.PropertyToNone]      = parse_property_to_none
	infix_table[.Dot]                 = parse_invalid_property_infix
	infix_table[.ConstraintBind]      = parse_constraint_bind
	infix_table[.ConstraintToNone]    = parse_constraint_to_none
	infix_table[.Colon]               = parse_invalid_constraint_infix
	infix_table[.Question]            = parse_pattern
	infix_table[.Execute]             = parse_execute
	infix_table[.Minus]               = parse_binary
	infix_table[.And]                 = parse_binary
	infix_table[.Or]                  = parse_bit_or
	infix_table[.Xor]                 = parse_binary
	infix_table[.RShift]              = parse_binary
	infix_table[.LShift]              = parse_binary
	infix_table[.Plus]                = parse_binary
	infix_table[.Asterisk]            = parse_binary
	infix_table[.Slash]               = parse_binary
	infix_table[.Percent]             = parse_binary
	infix_table[.Equal]               = parse_binary
	infix_table[.NotEqual]            = parse_binary
	infix_table[.Less]                = parse_less_than
	infix_table[.Greater]             = parse_binary
	infix_table[.LessEqual]           = parse_binary
	infix_table[.GreaterEqual]        = parse_binary
	infix_table[.PostfixRange]        = parse_postfix_range
	infix_table[.Range]               = parse_range
	infix_table[.QuestionExclamation] = parse_enforce
	infix_table[.PointingPush]        = parse_pointing_push
	infix_table[.PointingPull]        = parse_pointing_pull
	infix_table[.EventPush]           = parse_event_push
	infix_table[.EventPull]           = parse_event_pull
	infix_table[.ResonancePush]       = parse_resonance_push
	infix_table[.ResonancePull]       = parse_resonance_pull

	prec_table[.Integer]         = .PRIMARY
	prec_table[.Float]           = .PRIMARY
	prec_table[.Hexadecimal]     = .PRIMARY
	prec_table[.Binary]          = .PRIMARY
	prec_table[.String_Literal]  = .PRIMARY
	prec_table[.Bool_Literal]    = .PRIMARY
	prec_table[.Identifier]      = .PRIMARY

	prec_table[.LeftBrace]       = .CALL
	prec_table[.LeftBraceCarve]  = .CALL
	prec_table[.LeftBracket]     = .CALL
	prec_table[.LeftParen]       = .CALL
	prec_table[.LeftParenNoSpace] = .CALL
	prec_table[.At]              = .PRIMARY

	prec_table[.PropertyAccess]    = .CALL
	prec_table[.PropertyFromNone]  = .CALL
	prec_table[.PropertyToNone]    = .CALL
	prec_table[.Dot]               = .CALL

	prec_table[.ConstraintBind]      = .CONSTRAINT
	prec_table[.ConstraintFromNone]  = .CONSTRAINT
	prec_table[.ConstraintToNone]    = .CONSTRAINT
	prec_table[.Colon]               = .CONSTRAINT

	prec_table[.Question]          = .PATTERN
	prec_table[.Execute]           = .CALL

	prec_table[.Not]    = .UNARY
	prec_table[.Minus]  = .TERM

	prec_table[.And]    = .AND
	prec_table[.Or]     = .OR
	prec_table[.Xor]    = .AND
	prec_table[.RShift] = .SHIFT
	prec_table[.LShift] = .SHIFT

	prec_table[.Plus]     = .TERM
	prec_table[.Asterisk] = .FACTOR
	prec_table[.Slash]    = .FACTOR
	prec_table[.Percent]  = .FACTOR

	prec_table[.Equal]        = .EQUALITY
	prec_table[.NotEqual]     = .EQUALITY
	prec_table[.Less]         = .COMPARISON
	prec_table[.Greater]      = .COMPARISON
	prec_table[.LessEqual]    = .COMPARISON
	prec_table[.GreaterEqual] = .COMPARISON

	prec_table[.DoubleDot]    = .PRIMARY
	prec_table[.PrefixRange]  = .RANGE
	prec_table[.PostfixRange] = .RANGE
	prec_table[.Range]        = .RANGE

	prec_table[.DoubleQuestion]      = .PRIMARY
	prec_table[.QuestionExclamation] = .PATTERN

	prec_table[.PointingPush]  = .POINTING
	prec_table[.PointingPull]  = .ASSIGNMENT
	prec_table[.EventPush]     = .ASSIGNMENT
	prec_table[.EventPull]     = .ASSIGNMENT
	prec_table[.ResonancePush] = .ASSIGNMENT
	prec_table[.ResonancePull] = .ASSIGNMENT

	prec_table[.Ellipsis] = .PRIMARY
}

grow_buffer :: proc($T: typeid, buf: ^[]T, current_len: int) {
	old := buf^
	new_cap := len(old) * 2
	new_buf := make([]T, new_cap)
	copy(new_buf[:current_len], old[:current_len])
	delete(old)
	buf^ = new_buf
}

Scratch_Buffer :: struct {
	items: []Node_Index,
	count: int,
}

scratch_begin :: #force_inline proc(s: ^Scratch_Buffer) -> int {
	return s.count
}

scratch_end :: #force_inline proc(s: ^Scratch_Buffer, checkpoint: int) -> []Node_Index {
	return s.items[checkpoint:s.count]
}

scratch_reset :: #force_inline proc(s: ^Scratch_Buffer, checkpoint: int) {
	s.count = checkpoint
}

scratch_append :: #force_inline proc(s: ^Scratch_Buffer, idx: Node_Index) {
	if s.count >= len(s.items) {
		grow_buffer(Node_Index, &s.items, s.count)
	}
	s.items[s.count] = idx
	s.count += 1
}

Parser :: struct {
	source:        string,
	lexer:         Lexer,
	current_token: Token,
	peek_token:    Token,
	node_kinds:    []Node_Kind,
	node_spans:    []Span,
	node_data:     []Node_Data,
	node_count:    u32,
	extra:         []Node_Index,
	extra_count:   u32,
	extra_u8:      []u8,
	extra_u8_count: u32,
	errors:        [dynamic]Parse_Error,
	panic_mode:    bool,
	file_cache:    ^Cache,
	scratch:       Scratch_Buffer,
}

init_parser :: proc(parser: ^Parser, cache: ^Cache, source: string) {
	parser.source = source
	parser.file_cache = cache
	init_lexer(&parser.lexer, source)
	parser.panic_mode = false

	src_len := len(source)
	estimated_nodes: int
	if src_len < 4_000 {
		estimated_nodes = max(256, src_len / 4)
	} else if src_len < 10_000 {
		estimated_nodes = src_len / 3
	} else if src_len < 100_000 {
		estimated_nodes = src_len / 6
	} else {
		estimated_nodes = src_len / 8
	}
	estimated_extra := estimated_nodes / 3
	parser.node_kinds = make([]Node_Kind, estimated_nodes)
	parser.node_spans = make([]Span, estimated_nodes)
	parser.node_data = make([]Node_Data, estimated_nodes)
	parser.node_count = 0
	parser.extra = make([]Node_Index, estimated_extra)
	parser.extra_count = 0
	parser.extra_u8 = make([]u8, max(64, estimated_extra / 4))
	parser.extra_u8_count = 0
	parser.scratch.items = make([]Node_Index, max(256, estimated_nodes / 4))
	parser.scratch.count = 0

	parser.current_token = next_token(&parser.lexer)
	parser.peek_token = next_token(&parser.lexer)
}

advance_token :: #force_inline proc(parser: ^Parser) {
	parser.current_token = parser.peek_token
	parser.peek_token = next_token(&parser.lexer)
}

check :: #force_inline proc(parser: ^Parser, kind: Token_Kind) -> bool {
	return parser.current_token.kind == kind
}

match_token :: #force_inline proc(parser: ^Parser, kind: Token_Kind) -> bool {
	if !check(parser, kind) do return false
	advance_token(parser)
	return true
}

expect_token :: #force_inline proc(parser: ^Parser, kind: Token_Kind) -> bool {
	if check(parser, kind) {
		advance_token(parser)
		return true
	}
	error_at_current(parser, fmt.tprintf("Expected %v but got %v", kind, parser.current_token.kind))
	return false
}

error_at_current :: #force_inline proc(parser: ^Parser, message: string, error_type: Parser_Error_Type = .Syntax, expected: Token_Kind = .Invalid) {
	error_at(parser, parser.current_token, message, error_type, expected)
}

error_at :: proc(parser: ^Parser, token: Token, message: string, error_type: Parser_Error_Type = .Syntax, expected: Token_Kind = .Invalid) {
	if parser.panic_mode do return
	parser.panic_mode = true
	error := Parse_Error{
		type     = error_type,
		message  = message,
		span     = token.span,
		token    = token,
		expected = expected,
		found    = token.kind,
	}
	append(&parser.errors, error)
}

synchronize :: proc(parser: ^Parser) {
	parser.panic_mode = false
	start_offset := parser.current_token.span.start
	start_kind := parser.current_token.kind

	for parser.current_token.kind != .EOF {
		if has_flag(parser.current_token, .Separator_Before) ||
		   parser.current_token.kind == .RightBrace ||
		   parser.current_token.kind == .PointingPush ||
		   parser.current_token.kind == .PointingPull {
			return
		}
		current_offset := parser.current_token.span.start
		current_kind := parser.current_token.kind
		advance_token(parser)
		if parser.current_token.span.start == current_offset &&
		   parser.current_token.kind == current_kind {
			if parser.current_token.kind == .EOF do return
			advance_token(parser)
			return
		}
	}
}

add_node :: #force_inline proc(p: ^Parser, kind: Node_Kind, data: Node_Data, span: Span) -> Node_Index {
	i := p.node_count
	if int(i) >= len(p.node_kinds) {
		grow_buffer(Node_Kind, &p.node_kinds, int(i))
		grow_buffer(Span, &p.node_spans, int(i))
		grow_buffer(Node_Data, &p.node_data, int(i))
	}
	p.node_count = i + 1
	p.node_kinds[i] = kind
	p.node_spans[i] = span
	p.node_data[i] = data
	return Node_Index(i)
}

add_extra :: proc(p: ^Parser, indices: []Node_Index) -> Index_Range {
	start := p.extra_count
	needed := p.extra_count + u32(len(indices))
	if int(needed) > len(p.extra) {
		grow_buffer(Node_Index, &p.extra, int(p.extra_count))
	}
	for idx in indices {
		p.extra[p.extra_count] = idx
		p.extra_count += 1
	}
	return Index_Range{start = start, len = u32(len(indices))}
}

add_extra_u8 :: proc(p: ^Parser, wrappers: []u8) -> Index_Range {
	start := p.extra_u8_count
	needed := p.extra_u8_count + u32(len(wrappers))
	if int(needed) > len(p.extra_u8) {
		grow_buffer(u8, &p.extra_u8, int(p.extra_u8_count))
	}
	for w in wrappers {
		p.extra_u8[p.extra_u8_count] = w
		p.extra_u8_count += 1
	}
	return Index_Range{start = start, len = u32(len(wrappers))}
}

/* ======================================================================
 * SECTION 5: PARSE RULES TABLE
 * ====================================================================== */

/* (parse rule tables are initialized in init_parse_tables above) */

/* ======================================================================
 * SECTION 6: MAIN PARSE ENTRY POINTS
 * ====================================================================== */

parse :: proc(cache: ^Cache, source: string) -> ^Ast {
	parser: Parser
	init_parser(&parser, cache, source)
	span_start := parser.current_token.span.start

	cp := scratch_begin(&parser.scratch)

	for parser.current_token.kind != .EOF {
		if node := parse_with_recovery(&parser); node != INVALID_NODE {
			scratch_append(&parser.scratch, node)
		}
	}

	children := scratch_end(&parser.scratch, cp)
	data: Node_Data
	r := add_extra(&parser, children[:])
	scratch_reset(&parser.scratch, cp)
	data.scope = {start = r.start, len = r.len}
	root_span := Span{span_start, parser.current_token.span.end}
	add_node(&parser, .ScopeNode, data, root_span)

	ast := new(Ast)
	ast.source = source
	ast.node_kinds = parser.node_kinds[:parser.node_count]
	ast.node_spans = parser.node_spans[:parser.node_count]
	ast.node_data = parser.node_data[:parser.node_count]
	ast.extra = parser.extra[:parser.extra_count]
	ast.extra_u8 = parser.extra_u8[:parser.extra_u8_count]

	for error in parser.errors {
		debug_parse_error(error, source, ast)
	}

	return ast
}

debug_parse_error :: proc(error: Parse_Error, source: string, ast: ^Ast) {
	pos: Position
	if ast != nil {
		pos = span_to_position(ast, error.span.start)
	} else {
		temp_ast := Ast{source = source}
		pos = span_to_position(&temp_ast, error.span.start)
	}
	fmt.printf("  [%v] at line %d, col %d: %s\n", error.type, pos.line, pos.column, error.message)
}

parse_with_recovery :: proc(parser: ^Parser) -> Node_Index {
	if parser.panic_mode {
		synchronize(parser)
	}
	return parse_statement(parser)
}

parse_statement :: proc(parser: ^Parser) -> Node_Index {
	if parser.current_token.kind == .EOF || parser.current_token.kind == .RightBrace {
		advance_token(parser)
		return INVALID_NODE
	}
	expr := parse_expression(parser)
	if expr == INVALID_NODE && parser.current_token.kind == .RightBrace {
		error_at_current(parser, "Unexpected }")
		advance_token(parser)
		return INVALID_NODE
	}
	return expr
}

is_infix_operator :: #force_inline proc(kind: Token_Kind) -> bool {
	#partial switch kind {
	case .Plus, .Minus, .Asterisk, .Slash, .Percent, .And, .Or:
		return true
	}
	return false
}

parse_expression :: proc(parser: ^Parser, precedence := Precedence.NONE) -> Node_Index {
	if parser.current_token.kind == .EOF || parser.current_token.kind == .RightBrace {
		return INVALID_NODE
	}

	prefix := prefix_table[parser.current_token.kind]
	if prefix == nil {
		advance_token(parser)
		if parser.current_token.kind == .EOF || parser.current_token.kind == .RightBrace {
			return INVALID_NODE
		}
		return parse_expression(parser, precedence)
	}

	left := prefix(parser)
	if left == INVALID_NODE do return INVALID_NODE

	infix_loop: for {
		if has_flag(parser.current_token, .Separator_Before) {
			if !is_infix_operator(parser.current_token.kind) {
				break
			}
		}
		kind := parser.current_token.kind
		infix := infix_table[kind]
		if infix == nil || prec_table[kind] < precedence {
			break
		}
		if kind == .PointingPush {
			left_kind := parser.node_kinds[left]
			if left_kind == .Product || left_kind == .Pointing {
				break infix_loop
			}
		}
		left = infix(parser, left)
		if left == INVALID_NODE do return INVALID_NODE
	}
	return left
}

/* ======================================================================
 * SECTION 7: PARSE FUNCTIONS
 * ====================================================================== */

parse_literal :: proc(parser: ^Parser) -> Node_Index {
	span := parser.current_token.span
	data: Node_Data
	#partial switch parser.current_token.kind {
	case .Integer:        data.literal = Literal_Data{kind = .Integer}
	case .Float:          data.literal = Literal_Data{kind = .Float}
	case .Hexadecimal:    data.literal = Literal_Data{kind = .Hexadecimal}
	case .Binary:         data.literal = Literal_Data{kind = .Binary}
	case .String_Literal:
		data.literal = Literal_Data{kind = .String}
		span = Span{span.start + 1, span.end - 1}
	case .Bool_Literal:   data.literal = Literal_Data{kind = .Bool}
	case:
		error_at_current(parser, "Unknown literal type")
		return INVALID_NODE
	}
	advance_token(parser)
	return add_node(parser, .Literal, data, span)
}

parse_identifier :: proc(parser: ^Parser) -> Node_Index {
	span := parser.current_token.span
	name_span := span
	capture_span := EMPTY_SPAN

	advance_token(parser)

	if parser.current_token.kind == .LeftParenNoSpace {
		if parser.peek_token.kind == .Identifier {
			advance_token(parser)
			capture_span = parser.current_token.span
			advance_token(parser)
			if parser.current_token.kind == .RightParen {
				advance_token(parser)
			} else {
				error_at_current(parser, "Expected ')' after capture")
			}
		}
	}

	data: Node_Data
	data.identifier = Identifier_Data{name = name_span, capture = capture_span}
	full_span := Span{span.start, max(name_span.end, capture_span.end)}
	if capture_span != EMPTY_SPAN {
		full_span.end += 1
	}
	return add_node(parser, .Identifier, data, full_span)
}

parse_scope :: proc(parser: ^Parser) -> Node_Index {
	span_start := parser.current_token.span.start
	advance_token(parser)

	if parser.current_token.kind == .RightBrace {
		span_end := parser.current_token.span.end
		advance_token(parser)
		data: Node_Data
		data.scope = {start = 0, len = 0}
		return add_node(parser, .ScopeNode, data, Span{span_start, span_end})
	}

	cp := scratch_begin(&parser.scratch)
	defer scratch_reset(&parser.scratch, cp)

	for parser.current_token.kind != .RightBrace && parser.current_token.kind != .EOF {
		if parser.panic_mode {
			synchronize(parser)
			if parser.current_token.kind == .RightBrace do break
		}

		if node := parse_statement(parser); node != INVALID_NODE {
			scratch_append(&parser.scratch, node)
		}
	}

	span_end := parser.current_token.span.end
	if !match_token(parser, .RightBrace) {
		error_at_current(parser, "Expected '}' to close scope")
	}

	children := scratch_end(&parser.scratch, cp)
	data: Node_Data
	r2 := add_extra(parser, children[:])
	data.scope = {start = r2.start, len = r2.len}
	return add_node(parser, .ScopeNode, data, Span{span_start, span_end})
}

parse_carve :: proc(parser: ^Parser, left: Node_Index) -> Node_Index {
	span_start := parser.current_token.span.start
	advance_token(parser)

	cp := scratch_begin(&parser.scratch)
	defer scratch_reset(&parser.scratch, cp)

	for parser.current_token.kind != .RightBrace && parser.current_token.kind != .EOF {
		if node := parse_statement(parser); node != INVALID_NODE {
			scratch_append(&parser.scratch, node)
		} else {
			synchronize(parser)
			if parser.current_token.kind == .RightBrace do break
		}
	}

	span_end := parser.current_token.span.end
	if !match_token(parser, .RightBrace) {
		error_at_current(parser, "Expected } after carves")
	}

	children := scratch_end(&parser.scratch, cp)
	data: Node_Data
	data.carve = Carve_Data{source = left, children = add_extra(parser, children[:])}
	return add_node(parser, .Carve, data, Span{span_start, span_end})
}

parse_grouping :: proc(parser: ^Parser) -> Node_Index {
	span_start := parser.current_token.span.start
	advance_token(parser)

	if parser.current_token.kind == .Identifier && parser.peek_token.kind == .RightParen {
		capture_span := parser.current_token.span
		advance_token(parser)
		span_end := parser.current_token.span.end
		advance_token(parser)
		data: Node_Data
		data.identifier = Identifier_Data{name = EMPTY_SPAN, capture = capture_span}
		return add_node(parser, .Identifier, data, Span{span_start, span_end})
	}

	if parser.current_token.kind == .RightParen {
		span_end := parser.current_token.span.end
		advance_token(parser)
		data: Node_Data
		data.scope = {start = 0, len = 0}
		return add_node(parser, .ScopeNode, data, Span{span_start, span_end})
	}

	expr := parse_expression(parser)
	if expr == INVALID_NODE {
		error_at_current(parser, "Expected expression after '('")
		return INVALID_NODE
	}

	if !expect_token(parser, .RightParen) {
		return INVALID_NODE
	}

	return expr
}

parse_execute_prefix :: proc(parser: ^Parser) -> Node_Index {
	span := parser.current_token.span
	advance_token(parser)

	if !is_expression_start(parser.current_token.kind) &&
	   parser.current_token.kind != .LeftBraceCarve {
		data: Node_Data
		data.execute = Execute_Data{target = INVALID_NODE, wrappers = EMPTY_RANGE}
		return add_node(parser, .Execute, data, span)
	}

	operand := parse_expression(parser, Precedence.UNARY)
	data: Node_Data
	data.unary = Unary_Data{operand = operand}
	return add_node(parser, .CompileTime, data, Span{span.start, parser.node_spans[operand].end})
}

parse_execute :: proc(parser: ^Parser, left: Node_Index) -> Node_Index {
	span := parser.current_token.span
	advance_token(parser)
	data: Node_Data
	data.execute = Execute_Data{target = left, wrappers = EMPTY_RANGE}
	return add_node(parser, .Execute, data, Span{parser.node_spans[left].start, span.end})
}

parse_product_prefix :: proc(parser: ^Parser) -> Node_Index {
	span_start := parser.current_token.span.start
	advance_token(parser)

	if parser.current_token.kind == .RightBrace || parser.current_token.kind == .EOF ||
	   has_flag(parser.current_token, .Separator_Before) {
		data: Node_Data
		data.unary = Unary_Data{operand = INVALID_NODE}
		return add_node(parser, .Product, data, Span{span_start, parser.current_token.span.start})
	}

	to := parse_expression(parser, .PATTERN)
	if to == INVALID_NODE do return INVALID_NODE

	data: Node_Data
	data.unary = Unary_Data{operand = to}
	return add_node(parser, .Product, data, Span{span_start, parser.node_spans[to].end})
}

parse_binary :: proc(parser: ^Parser, left: Node_Index) -> Node_Index {
	span_start := parser.node_spans[left].start
	token_kind := parser.current_token.kind
	prec := prec_table[token_kind]
	advance_token(parser)

	right := parse_expression(parser, Precedence(int(prec) + 1))
	if right == INVALID_NODE {
		error_at_current(parser, "Expected expression after binary operator")
		parser.panic_mode = false
		return left
	}

	op_kind: Operator_Kind
	#partial switch token_kind {
	case .Plus:          op_kind = .Add
	case .Minus:         op_kind = .Subtract
	case .Asterisk:      op_kind = .Multiply
	case .Slash:         op_kind = .Divide
	case .Percent:       op_kind = .Mod
	case .And:           op_kind = .And
	case .Or:            op_kind = .Or
	case .Xor:           op_kind = .Xor
	case .Equal:         op_kind = .Equal
	case .NotEqual:      op_kind = .NotEqual
	case .Less:          op_kind = .Less
	case .Greater:       op_kind = .Greater
	case .LessEqual:     op_kind = .LessEqual
	case .GreaterEqual:  op_kind = .GreaterEqual
	case .LShift:        op_kind = .LShift
	case .RShift:        op_kind = .RShift
	case:
		error_at_current(parser, fmt.tprintf("Unhandled binary operator type: %v", token_kind))
		return INVALID_NODE
	}

	data: Node_Data
	data.operator = Operator_Node_Data{kind = op_kind, left = left, right = right}
	return add_node(parser, .Operator, data, Span{span_start, parser.node_spans[right].end})
}

parse_unary :: proc(parser: ^Parser) -> Node_Index {
	span_start := parser.current_token.span.start
	token_kind := parser.current_token.kind
	advance_token(parser)

	operand := parse_expression(parser, .UNARY)
	if operand == INVALID_NODE {
		error_at_current(parser, "Expected expression after unary operator")
		return INVALID_NODE
	}

	op_kind: Operator_Kind
	#partial switch token_kind {
	case .Minus: op_kind = .Subtract
	case .Not:   op_kind = .Not
	case:
		error_at_current(parser, "Unexpected unary operator")
		return INVALID_NODE
	}

	data: Node_Data
	data.operator = Operator_Node_Data{kind = op_kind, left = INVALID_NODE, right = operand}
	return add_node(parser, .Operator, data, Span{span_start, parser.node_spans[operand].end})
}

parse_property_access :: proc(parser: ^Parser, left: Node_Index) -> Node_Index {
	span_start := parser.node_spans[left].start
	advance_token(parser)

	if parser.current_token.kind != .Identifier {
		error_at_current(parser, "Expected property name after '.'")
		return INVALID_NODE
	}

	prop_span := parser.current_token.span
	advance_token(parser)

	prop_data: Node_Data
	prop_data.identifier = Identifier_Data{name = prop_span, capture = EMPTY_SPAN}
	prop_id := add_node(parser, .Identifier, prop_data, prop_span)

	data: Node_Data
	data.binary = Binary_Data{left = left, right = prop_id}
	return add_node(parser, .Property, data, Span{span_start, prop_span.end})
}

parse_property_from_none :: proc(parser: ^Parser) -> Node_Index {
	span_start := parser.current_token.span.start
	advance_token(parser)

	if parser.current_token.kind != .Identifier {
		error_at_current(parser, "Expected property name after '.'")
		return INVALID_NODE
	}

	prop_span := parser.current_token.span
	advance_token(parser)

	prop_data: Node_Data
	prop_data.identifier = Identifier_Data{name = prop_span, capture = EMPTY_SPAN}
	prop_id := add_node(parser, .Identifier, prop_data, prop_span)

	data: Node_Data
	data.binary = Binary_Data{left = INVALID_NODE, right = prop_id}
	return add_node(parser, .Property, data, Span{span_start, prop_span.end})
}

parse_property_to_none :: proc(parser: ^Parser, left: Node_Index) -> Node_Index {
	span_start := parser.node_spans[left].start
	advance_token(parser)

	data: Node_Data
	data.binary = Binary_Data{left = left, right = INVALID_NODE}
	return add_node(parser, .Property, data, Span{span_start, parser.current_token.span.start})
}

parse_constraint_bind :: proc(parser: ^Parser, left: Node_Index) -> Node_Index {
	span_start := parser.node_spans[left].start
	advance_token(parser)

	name := INVALID_NODE
	if parser.current_token.kind == .RightBrace ||
	   parser.current_token.kind == .EOF ||
	   has_flag(parser.current_token, .Separator_Before) {
	} else if parser.current_token.kind == .LeftParenNoSpace {
		name = parse_grouping(parser)
	} else if parser.current_token.kind == .LeftBrace {
	} else if is_expression_start(parser.current_token.kind) {
		name = parse_expression(parser, Precedence(int(Precedence.CALL) + 1))
	}

	data: Node_Data
	data.binary = Binary_Data{left = left, right = name}
	span_end := parser.current_token.span.start
	if name != INVALID_NODE {
		span_end = parser.node_spans[name].end
	}
	node := add_node(parser, .Constraint, data, Span{span_start, span_end})

	if parser.current_token.kind == .LeftBraceCarve {
		return parse_carve(parser, node)
	}
	return node
}

parse_constraint_from_none :: proc(parser: ^Parser) -> Node_Index {
	span_start := parser.current_token.span.start
	advance_token(parser)

	name := INVALID_NODE
	if parser.current_token.kind == .RightBrace ||
	   parser.current_token.kind == .EOF ||
	   has_flag(parser.current_token, .Separator_Before) {
	} else if parser.current_token.kind == .LeftParenNoSpace {
		name = parse_grouping(parser)
	} else if parser.current_token.kind == .LeftBrace {
	} else if is_expression_start(parser.current_token.kind) {
		name = parse_expression(parser, Precedence(int(Precedence.CALL) + 1))
	}

	data: Node_Data
	data.binary = Binary_Data{left = INVALID_NODE, right = name}
	span_end := parser.current_token.span.start
	if name != INVALID_NODE {
		span_end = parser.node_spans[name].end
	}
	node := add_node(parser, .Constraint, data, Span{span_start, span_end})

	if parser.current_token.kind == .LeftBraceCarve {
		return parse_carve(parser, node)
	}
	return node
}

parse_constraint_to_none :: proc(parser: ^Parser, left: Node_Index) -> Node_Index {
	span_start := parser.node_spans[left].start
	advance_token(parser)

	data: Node_Data
	data.binary = Binary_Data{left = left, right = INVALID_NODE}
	node := add_node(parser, .Constraint, data, Span{span_start, parser.current_token.span.start})

	if parser.current_token.kind == .LeftBraceCarve {
		return parse_carve(parser, node)
	}
	return node
}

parse_invalid_property :: proc(parser: ^Parser) -> Node_Index {
	error_at_current(parser, "Invalid property syntax with spaces around '.' - use 'a.b', '.b', or 'a.'")
	advance_token(parser)
	return INVALID_NODE
}

parse_invalid_property_infix :: proc(parser: ^Parser, left: Node_Index) -> Node_Index {
	error_at_current(parser, "Invalid property syntax with spaces around '.' - use 'a.b', '.b', or 'a.'")
	advance_token(parser)
	parser.panic_mode = false
	return left
}

parse_invalid_constraint :: proc(parser: ^Parser) -> Node_Index {
	error_at_current(parser, "Invalid constraint syntax with spaces around ':' - use 'a:b', ':b', or 'a:'")
	advance_token(parser)
	return INVALID_NODE
}

parse_invalid_constraint_infix :: proc(parser: ^Parser, left: Node_Index) -> Node_Index {
	error_at_current(parser, "Invalid constraint syntax with spaces around ':' - use 'a:b', ':b', or 'a:'")
	advance_token(parser)
	parser.panic_mode = false
	return left
}

parse_pointing_push :: proc(parser: ^Parser, left: Node_Index) -> Node_Index {
	span_start := parser.node_spans[left].start
	advance_token(parser)

	to := INVALID_NODE
	if parser.current_token.kind != .RightBrace &&
	   parser.current_token.kind != .EOF &&
	   !has_flag(parser.current_token, .Separator_Before) {
		to = parse_expression(parser, .ASSIGNMENT)
	}

	data: Node_Data
	data.binary = Binary_Data{left = left, right = to}
	span_end := parser.current_token.span.start
	if to != INVALID_NODE {
		span_end = parser.node_spans[to].end
	}
	return add_node(parser, .Pointing, data, Span{span_start, span_end})
}

parse_pointing_pull_prefix :: proc(parser: ^Parser) -> Node_Index {
	span_start := parser.current_token.span.start
	advance_token(parser)

	to := INVALID_NODE
	if parser.current_token.kind != .RightBrace &&
	   parser.current_token.kind != .EOF &&
	   !has_flag(parser.current_token, .Separator_Before) {
		to = parse_expression(parser, .ASSIGNMENT)
	}

	data: Node_Data
	data.binary = Binary_Data{left = INVALID_NODE, right = to}
	span_end := parser.current_token.span.start
	if to != INVALID_NODE {
		span_end = parser.node_spans[to].end
	}
	return add_node(parser, .PointingPull, data, Span{span_start, span_end})
}

parse_pointing_pull :: proc(parser: ^Parser, left: Node_Index) -> Node_Index {
	span_start := parser.node_spans[left].start
	advance_token(parser)

	to := INVALID_NODE
	if parser.current_token.kind != .RightBrace &&
	   parser.current_token.kind != .EOF &&
	   !has_flag(parser.current_token, .Separator_Before) {
		to = parse_expression(parser, .ASSIGNMENT)
	}

	data: Node_Data
	data.binary = Binary_Data{left = left, right = to}
	span_end := parser.current_token.span.start
	if to != INVALID_NODE {
		span_end = parser.node_spans[to].end
	}
	return add_node(parser, .PointingPull, data, Span{span_start, span_end})
}

parse_event_push_prefix :: proc(parser: ^Parser) -> Node_Index {
	span_start := parser.current_token.span.start
	advance_token(parser)

	to := INVALID_NODE
	if parser.current_token.kind != .RightBrace &&
	   parser.current_token.kind != .EOF &&
	   !has_flag(parser.current_token, .Separator_Before) {
		to = parse_expression(parser)
	}

	data: Node_Data
	data.binary = Binary_Data{left = INVALID_NODE, right = to}
	span_end := parser.current_token.span.start
	if to != INVALID_NODE {
		span_end = parser.node_spans[to].end
	}
	return add_node(parser, .EventPush, data, Span{span_start, span_end})
}

parse_event_push :: proc(parser: ^Parser, left: Node_Index) -> Node_Index {
	span_start := parser.node_spans[left].start
	advance_token(parser)

	to := INVALID_NODE
	if parser.current_token.kind != .RightBrace &&
	   parser.current_token.kind != .EOF &&
	   !has_flag(parser.current_token, .Separator_Before) {
		to = parse_expression(parser)
	}

	data: Node_Data
	data.binary = Binary_Data{left = left, right = to}
	span_end := parser.current_token.span.start
	if to != INVALID_NODE {
		span_end = parser.node_spans[to].end
	}
	return add_node(parser, .EventPush, data, Span{span_start, span_end})
}

parse_event_pull_prefix :: proc(parser: ^Parser) -> Node_Index {
	span_start := parser.current_token.span.start
	advance_token(parser)

	catch_span := EMPTY_SPAN
	if parser.current_token.kind == .Identifier {
		catch_span = parser.current_token.span
		advance_token(parser)
	}

	to := INVALID_NODE
	if parser.current_token.kind != .RightBrace &&
	   parser.current_token.kind != .EOF &&
	   !has_flag(parser.current_token, .Separator_Before) {
		to = parse_expression(parser)
	}

	data: Node_Data
	data.event_pull = EventPull_Data{from = INVALID_NODE, to = to, catch_span = catch_span}
	span_end := parser.current_token.span.start
	if to != INVALID_NODE {
		span_end = parser.node_spans[to].end
	}
	return add_node(parser, .EventPull, data, Span{span_start, span_end})
}

parse_event_pull :: proc(parser: ^Parser, left: Node_Index) -> Node_Index {
	span_start := parser.node_spans[left].start
	advance_token(parser)

	catch_span := EMPTY_SPAN
	if parser.current_token.kind == .Identifier {
		catch_span = parser.current_token.span
		advance_token(parser)
	}

	to := INVALID_NODE
	if parser.current_token.kind != .RightBrace &&
	   parser.current_token.kind != .EOF &&
	   !has_flag(parser.current_token, .Separator_Before) {
		to = parse_expression(parser)
	}

	data: Node_Data
	data.event_pull = EventPull_Data{from = left, to = to, catch_span = catch_span}
	span_end := parser.current_token.span.start
	if to != INVALID_NODE {
		span_end = parser.node_spans[to].end
	}
	return add_node(parser, .EventPull, data, Span{span_start, span_end})
}

parse_resonance_push_prefix :: proc(parser: ^Parser) -> Node_Index {
	span_start := parser.current_token.span.start
	advance_token(parser)

	to := INVALID_NODE
	if parser.current_token.kind != .RightBrace &&
	   parser.current_token.kind != .EOF &&
	   !has_flag(parser.current_token, .Separator_Before) {
		to = parse_expression(parser, Precedence(int(Precedence.ASSIGNMENT) + 1))
	}

	data: Node_Data
	data.binary = Binary_Data{left = INVALID_NODE, right = to}
	span_end := parser.current_token.span.start
	if to != INVALID_NODE {
		span_end = parser.node_spans[to].end
	}
	return add_node(parser, .ResonancePush, data, Span{span_start, span_end})
}

parse_resonance_push :: proc(parser: ^Parser, left: Node_Index) -> Node_Index {
	span_start := parser.node_spans[left].start
	advance_token(parser)

	to := INVALID_NODE
	if parser.current_token.kind != .RightBrace &&
	   parser.current_token.kind != .EOF &&
	   !has_flag(parser.current_token, .Separator_Before) {
		to = parse_expression(parser, Precedence(int(Precedence.ASSIGNMENT) + 1))
	}

	data: Node_Data
	data.binary = Binary_Data{left = left, right = to}
	span_end := parser.current_token.span.start
	if to != INVALID_NODE {
		span_end = parser.node_spans[to].end
	}
	return add_node(parser, .ResonancePush, data, Span{span_start, span_end})
}

parse_resonance_pull_prefix :: proc(parser: ^Parser) -> Node_Index {
	span_start := parser.current_token.span.start
	advance_token(parser)

	to := INVALID_NODE
	if parser.current_token.kind != .RightBrace &&
	   parser.current_token.kind != .EOF &&
	   !has_flag(parser.current_token, .Separator_Before) {
		to = parse_expression(parser, Precedence(int(Precedence.ASSIGNMENT) + 1))
	}

	data: Node_Data
	data.binary = Binary_Data{left = INVALID_NODE, right = to}
	span_end := parser.current_token.span.start
	if to != INVALID_NODE {
		span_end = parser.node_spans[to].end
	}
	return add_node(parser, .ResonancePull, data, Span{span_start, span_end})
}

parse_resonance_pull :: proc(parser: ^Parser, left: Node_Index) -> Node_Index {
	span_start := parser.node_spans[left].start
	advance_token(parser)

	to := INVALID_NODE
	if parser.current_token.kind != .RightBrace &&
	   parser.current_token.kind != .EOF &&
	   !has_flag(parser.current_token, .Separator_Before) {
		to = parse_expression(parser, Precedence(int(Precedence.ASSIGNMENT) + 1))
	}

	data: Node_Data
	data.binary = Binary_Data{left = left, right = to}
	span_end := parser.current_token.span.start
	if to != INVALID_NODE {
		span_end = parser.node_spans[to].end
	}
	return add_node(parser, .ResonancePull, data, Span{span_start, span_end})
}

parse_empty_range :: proc(parser: ^Parser) -> Node_Index {
	span := parser.current_token.span
	advance_token(parser)
	data: Node_Data
	data.binary = Binary_Data{left = INVALID_NODE, right = INVALID_NODE}
	return add_node(parser, .Range, data, span)
}

parse_prefix_range :: proc(parser: ^Parser) -> Node_Index {
	span_start := parser.current_token.span.start
	advance_token(parser)

	end := INVALID_NODE
	if parser.current_token.kind != .RightBrace &&
	   parser.current_token.kind != .EOF &&
	   !has_flag(parser.current_token, .Separator_Before) {
		end = parse_expression(parser, .RANGE)
	}

	data: Node_Data
	data.binary = Binary_Data{left = INVALID_NODE, right = end}
	span_end := parser.current_token.span.start
	if end != INVALID_NODE {
		span_end = parser.node_spans[end].end
	}
	return add_node(parser, .Range, data, Span{span_start, span_end})
}

parse_postfix_range :: proc(parser: ^Parser, left: Node_Index) -> Node_Index {
	span_start := parser.node_spans[left].start
	advance_token(parser)

	data: Node_Data
	data.binary = Binary_Data{left = left, right = INVALID_NODE}
	return add_node(parser, .Range, data, Span{span_start, parser.current_token.span.start})
}

parse_range :: proc(parser: ^Parser, left: Node_Index) -> Node_Index {
	span_start := parser.node_spans[left].start
	advance_token(parser)

	end := INVALID_NODE
	if parser.current_token.kind != .RightBrace &&
	   parser.current_token.kind != .EOF &&
	   !has_flag(parser.current_token, .Separator_Before) {
		end = parse_expression(parser, .RANGE)
	}

	data: Node_Data
	data.binary = Binary_Data{left = left, right = end}
	span_end := parser.current_token.span.start
	if end != INVALID_NODE {
		span_end = parser.node_spans[end].end
	}
	return add_node(parser, .Range, data, Span{span_start, span_end})
}

parse_prefix_comparison :: proc(parser: ^Parser) -> Node_Index {
	span_start := parser.current_token.span.start
	token_kind := parser.current_token.kind
	advance_token(parser)

	operand := parse_expression(parser, .UNARY)
	if operand == INVALID_NODE {
		error_at_current(parser, "Expected expression after prefix comparison operator")
		return INVALID_NODE
	}

	op_kind: Operator_Kind
	#partial switch token_kind {
	case .Equal:        op_kind = .Equal
	case .NotEqual:     op_kind = .NotEqual
	case .Less:         op_kind = .Less
	case .Greater:      op_kind = .Greater
	case .LessEqual:    op_kind = .LessEqual
	case .GreaterEqual: op_kind = .GreaterEqual
	case:
		error_at_current(parser, "Unexpected prefix comparison operator")
		return INVALID_NODE
	}

	data: Node_Data
	data.operator = Operator_Node_Data{kind = op_kind, left = INVALID_NODE, right = operand}
	return add_node(parser, .Operator, data, Span{span_start, parser.node_spans[operand].end})
}

parse_pattern :: proc(parser: ^Parser, left: Node_Index) -> Node_Index {
	span_start := parser.node_spans[left].start
	advance_token(parser)

	cp := scratch_begin(&parser.scratch)
	defer scratch_reset(&parser.scratch, cp)

	if parser.current_token.kind == .LeftBrace {
		advance_token(parser)

		for parser.current_token.kind != .RightBrace && parser.current_token.kind != .EOF {
			source_idx, product_idx := parse_branch(parser)
			scratch_append(&parser.scratch, source_idx)
			scratch_append(&parser.scratch, product_idx)
		}

		if !match_token(parser, .RightBrace) {
			error_at_current(parser, "Expected } after pattern branches")
		}
	} else {
		inline_expr := INVALID_NODE
		if parser.current_token.kind == .LeftParenNoSpace {
			inline_expr = parse_grouping(parser)
		} else if is_expression_start(parser.current_token.kind) {
			inline_expr = parse_expression(parser, .OR)
		} else {
			error_at_current(parser, "Expected pattern expression after ?")
			return INVALID_NODE
		}
		if inline_expr != INVALID_NODE {
			scratch_append(&parser.scratch, inline_expr)
			scratch_append(&parser.scratch, INVALID_NODE)
		}
	}

	branch_indices := scratch_end(&parser.scratch, cp)
	data: Node_Data
	data.pattern = Pattern_Data{target = left, branches = add_extra(parser, branch_indices[:])}
	span_end := parser.current_token.span.start
	return add_node(parser, .Pattern, data, Span{span_start, span_end})
}

parse_branch :: proc(parser: ^Parser) -> (source_idx: Node_Index, product_idx: Node_Index) {
	if !is_expression_start(parser.current_token.kind) {
		advance_token(parser)
		return INVALID_NODE, INVALID_NODE
	}

	if parser.current_token.kind == .PointingPush {
		advance_token(parser)
		product := parse_expression(parser, .ASSIGNMENT)
		return INVALID_NODE, product
	}

	source := parse_expression(parser, .ASSIGNMENT)
	product := INVALID_NODE
	if parser.current_token.kind == .PointingPush {
		advance_token(parser)
		product = parse_expression(parser, .ASSIGNMENT)
	}

	return source, product
}

parse_enforce :: proc(parser: ^Parser, left: Node_Index) -> Node_Index {
	span_start := parser.node_spans[left].start
	token_kind := parser.current_token.kind
	prec := prec_table[token_kind]
	advance_token(parser)

	right := parse_expression(parser, Precedence(int(prec) + 1))
	if right == INVALID_NODE {
		error_at_current(parser, "Expected expression after binary operator")
		return INVALID_NODE
	}

	data: Node_Data
	data.binary = Binary_Data{left = left, right = right}
	return add_node(parser, .Enforce, data, Span{span_start, parser.node_spans[right].end})
}

parse_unknown :: proc(parser: ^Parser) -> Node_Index {
	span := parser.current_token.span
	advance_token(parser)
	data: Node_Data
	return add_node(parser, .Unknown, data, span)
}

parse_expansion :: proc(parser: ^Parser) -> Node_Index {
	span_start := parser.current_token.span.start
	advance_token(parser)

	target := parse_expression(parser, .CONSTRAINT)
	if target == INVALID_NODE {
		error_at_current(parser, "Expected expression after ...")
		return INVALID_NODE
	}

	data: Node_Data
	data.unary = Unary_Data{operand = target}
	return add_node(parser, .Expand, data, Span{span_start, parser.node_spans[target].end})
}

parse_reference :: proc(parser: ^Parser) -> Node_Index {
	span_start := parser.current_token.span.start
	advance_token(parser)

	if parser.current_token.kind != .Identifier {
		error_at_current(parser, "Expected identifier after @")
		return INVALID_NODE
	}

	name_span := parser.current_token.span
	advance_token(parser)

	data: Node_Data
	data.external = External_Data{name = name_span, scope = INVALID_NODE}
	current := add_node(parser, .External, data, Span{span_start, name_span.end})

	for parser.current_token.kind == .Dot {
		advance_token(parser)
		if parser.current_token.kind != .Identifier {
			error_at_current(parser, "Expected identifier after '.'")
			break
		}

		prop_span := parser.current_token.span
		prop_data: Node_Data
		prop_data.identifier = Identifier_Data{name = prop_span, capture = EMPTY_SPAN}
		prop_id := add_node(parser, .Identifier, prop_data, prop_span)

		prop_node_data: Node_Data
		prop_node_data.binary = Binary_Data{left = current, right = prop_id}
		current = add_node(parser, .Property, prop_node_data, Span{span_start, prop_span.end})
		advance_token(parser)
	}

	process_filenode_flat(current, parser)

	return current
}

parse_bit_or :: proc(parser: ^Parser, left: Node_Index) -> Node_Index {
	if node, is_execution := try_parse_wrapped_execute(parser, left); is_execution {
		return node
	}
	return parse_binary(parser, left)
}

parse_less_than :: proc(parser: ^Parser, left: Node_Index) -> Node_Index {
	if node, is_execution := try_parse_wrapped_execute(parser, left); is_execution {
		return node
	}

	span_start := parser.node_spans[left].start
	advance_token(parser)

	right := parse_expression(parser, Precedence(int(Precedence.COMPARISON) + 1))
	data: Node_Data
	data.operator = Operator_Node_Data{kind = .Less, left = left, right = right}
	span_end := parser.current_token.span.start
	if right != INVALID_NODE {
		span_end = parser.node_spans[right].end
	}
	return add_node(parser, .Operator, data, Span{span_start, span_end})
}

parse_left_bracket :: proc(parser: ^Parser, left: Node_Index) -> Node_Index {
	if node, is_execution := try_parse_wrapped_execute(parser, left); is_execution {
		return node
	}
	error_at_current(parser, "Trying to use left bracket [ for something else than execution wrapper like [!]")
	return INVALID_NODE
}

parse_left_paren :: proc(parser: ^Parser, left: Node_Index) -> Node_Index {
	if node, is_execution := try_parse_wrapped_execute(parser, left); is_execution {
		return node
	}
	parse_grouping(parser)
	return left
}

try_parse_wrapped_execute :: proc(parser: ^Parser, left: Node_Index) -> (Node_Index, bool) {
	MAX_WRAPPER_DEPTH :: 8
	original_offset := parser.lexer.offset
	original_current := parser.current_token
	original_peek := parser.peek_token
	nodes_len := parser.node_count

	restore :: proc(parser: ^Parser, offset: u32, current, peek: Token, nlen: u32) {
		parser.lexer.offset = offset
		parser.current_token = current
		parser.peek_token = peek
		parser.node_count = nlen
	}

	wrappers: [MAX_WRAPPER_DEPTH]u8
	stack: [MAX_WRAPPER_DEPTH]Token_Kind
	wrappers_len: u8 = 0
	stack_len: u8 = 0

	found_exclamation := false

	for {
		current := parser.current_token.kind
		#partial switch current {
		case .Execute:
			found_exclamation = true
			advance_token(parser)
		case .LeftParen, .LeftParenNoSpace:
			if wrappers_len >= MAX_WRAPPER_DEPTH {
				restore(parser, original_offset, original_current, original_peek, nodes_len)
				return INVALID_NODE, false
			}
			wrappers[wrappers_len] = u8(ExecutionWrapper.Background)
			stack[stack_len] = Token_Kind.LeftParen
			wrappers_len += 1
			stack_len += 1
			advance_token(parser)
		case .Less:
			if wrappers_len >= MAX_WRAPPER_DEPTH {
				restore(parser, original_offset, original_current, original_peek, nodes_len)
				return INVALID_NODE, false
			}
			wrappers[wrappers_len] = u8(ExecutionWrapper.Threading)
			stack[stack_len] = Token_Kind.Less
			wrappers_len += 1
			stack_len += 1
			advance_token(parser)
		case .LeftBracket:
			if wrappers_len >= MAX_WRAPPER_DEPTH {
				restore(parser, original_offset, original_current, original_peek, nodes_len)
				return INVALID_NODE, false
			}
			wrappers[wrappers_len] = u8(ExecutionWrapper.Parallel_CPU)
			stack[stack_len] = Token_Kind.LeftBracket
			wrappers_len += 1
			stack_len += 1
			advance_token(parser)
		case .Or:
			if stack_len > 0 && stack[stack_len-1] == Token_Kind.Or {
				stack_len -= 1
				advance_token(parser)
			} else {
				if wrappers_len >= MAX_WRAPPER_DEPTH {
					restore(parser, original_offset, original_current, original_peek, nodes_len)
					return INVALID_NODE, false
				}
				wrappers[wrappers_len] = u8(ExecutionWrapper.GPU)
				stack[stack_len] = Token_Kind.Or
				wrappers_len += 1
				stack_len += 1
				advance_token(parser)
			}
		case .RightParen:
			if stack_len == 0 || stack[stack_len-1] != Token_Kind.LeftParen {
				restore(parser, original_offset, original_current, original_peek, nodes_len)
				return INVALID_NODE, false
			}
			stack_len -= 1
			advance_token(parser)
		case .Greater:
			if stack_len == 0 || stack[stack_len-1] != Token_Kind.Less {
				restore(parser, original_offset, original_current, original_peek, nodes_len)
				return INVALID_NODE, false
			}
			stack_len -= 1
			advance_token(parser)
		case .RightBracket:
			if stack_len == 0 || stack[stack_len-1] != Token_Kind.LeftBracket {
				restore(parser, original_offset, original_current, original_peek, nodes_len)
				return INVALID_NODE, false
			}
			stack_len -= 1
			advance_token(parser)
		case:
			if !found_exclamation {
				restore(parser, original_offset, original_current, original_peek, nodes_len)
				return INVALID_NODE, false
			}
			break
		}

		if stack_len == 0 {
			if found_exclamation {
				break
			} else {
				restore(parser, original_offset, original_current, original_peek, nodes_len)
				return INVALID_NODE, false
			}
		}
	}

	if !found_exclamation || stack_len > 0 {
		restore(parser, original_offset, original_current, original_peek, nodes_len)
		return INVALID_NODE, false
	}

	data: Node_Data
	data.execute = Execute_Data{target = left, wrappers = add_extra_u8(parser, wrappers[:wrappers_len])}
	span := Span{parser.node_spans[left].start, parser.current_token.span.start}
	return add_node(parser, .Execute, data, span), true
}

/* ======================================================================
 * SECTION 8: UTILITY FUNCTIONS
 * ====================================================================== */

is_execution_pattern_start :: proc(kind: Token_Kind) -> bool {
	return kind == .Execute || kind == .LeftParen || kind == .Less ||
	       kind == .LeftBracket || kind == .Or
}

is_expression_start :: proc(kind: Token_Kind) -> bool {
	return(
		kind == .Identifier ||
		kind == .Integer ||
		kind == .Float ||
		kind == .String_Literal ||
		kind == .Bool_Literal ||
		kind == .Hexadecimal ||
		kind == .Binary ||
		kind == .LeftBrace ||
		kind == .LeftParen ||
		kind == .LeftParenNoSpace ||
		kind == .At ||
		kind == .Not ||
		kind == .Minus ||
		kind == .PointingPull ||
		kind == .EventPush ||
		kind == .EventPull ||
		kind == .ResonancePush ||
		kind == .ResonancePull ||
		kind == .DoubleDot ||
		kind == .Question ||
		kind == .Ellipsis ||
		kind == .PointingPush ||
		kind == .Equal ||
		kind == .NotEqual ||
		kind == .LessEqual ||
		kind == .Less ||
		kind == .Greater ||
		kind == .GreaterEqual ||
		kind == .Range ||
		kind == .PostfixRange ||
		kind == .PrefixRange ||
		kind == .DoubleQuestion ||
		kind == .Execute ||
		kind == .ConstraintFromNone ||
		kind == .PropertyFromNone
	)
}

IDENT_START:    [256]bool
IDENT_CONTINUE: [256]bool

@(init)
init_ident_tables :: proc "contextless" () {
	for c in u8('a')..=u8('z') { IDENT_START[c] = true; IDENT_CONTINUE[c] = true }
	for c in u8('A')..=u8('Z') { IDENT_START[c] = true; IDENT_CONTINUE[c] = true }
	IDENT_START['_'] = true
	IDENT_CONTINUE['_'] = true
	for c in u8('0')..=u8('9') { IDENT_CONTINUE[c] = true }
}

is_digit :: #force_inline proc(c: u8) -> bool {
	return c >= '0' && c <= '9'
}

is_hex_digit :: #force_inline proc(c: u8) -> bool {
	return is_digit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
}

is_alpha :: #force_inline proc(c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

is_alnum :: #force_inline proc(c: u8) -> bool {
	return is_digit(c) || is_alpha(c) || c == '_'
}

is_before_delimiter :: #force_inline proc(c: u8) -> bool {
	return is_space(c) || c == '\n' || c == ':' || c == ',' || c == '{' || c == '('
}

is_after_delimiter :: #force_inline proc(c: u8) -> bool {
	return is_space(c) || c == '\n' || c == '}' || c == ')' || c == ',' || c == ':'
}

is_space :: #force_inline proc(c: u8) -> bool {
	return c == ' ' || c == '\t' || c == '\r'
}

/* ======================================================================
 * SECTION 9: DEBUG UTILITIES
 * ====================================================================== */

print_ast :: proc(ast: ^Ast, idx: Node_Index, indent: int) {
	if idx == INVALID_NODE do return

	indent_str := strings.repeat(" ", indent)
	n_kind := ast.node_kinds[idx]
	n_span := ast.node_spans[idx]
	n_data := ast.node_data[idx]
	pos := span_to_position(ast, n_span.start)

	switch n_kind {
	case .Pointing:
		fmt.printf("%sPointing -> (line %d, column %d)\n", indent_str, pos.line, pos.column)
		if n_data.binary.left != INVALID_NODE {
			fmt.printf("%s  From:\n", indent_str)
			print_ast(ast, n_data.binary.left, indent + 4)
		}
		if n_data.binary.right != INVALID_NODE {
			fmt.printf("%s  To:\n", indent_str)
			print_ast(ast, n_data.binary.right, indent + 4)
		}
	case .PointingPull:
		fmt.printf("%sPointingPull <- (line %d, column %d)\n", indent_str, pos.line, pos.column)
		if n_data.binary.left != INVALID_NODE {
			fmt.printf("%s  From:\n", indent_str)
			print_ast(ast, n_data.binary.left, indent + 4)
		} else {
			fmt.printf("%s  From: anonymous\n", indent_str)
		}
		if n_data.binary.right != INVALID_NODE {
			fmt.printf("%s  To:\n", indent_str)
			print_ast(ast, n_data.binary.right, indent + 4)
		}
	case .EventPush:
		fmt.printf("%sEventPush >- (line %d, column %d)\n", indent_str, pos.line, pos.column)
		if n_data.binary.left != INVALID_NODE {
			fmt.printf("%s  From:\n", indent_str)
			print_ast(ast, n_data.binary.left, indent + 4)
		} else {
			fmt.printf("%s  From: anonymous\n", indent_str)
		}
		if n_data.binary.right != INVALID_NODE {
			fmt.printf("%s  To:\n", indent_str)
			print_ast(ast, n_data.binary.right, indent + 4)
		}
	case .EventPull:
		fmt.printf("%sEventPull -< (line %d, column %d)\n", indent_str, pos.line, pos.column)
		catch_str := node_event_pull_catch(ast, idx)
		if catch_str != "" {
			fmt.printfln("%s  Catch: %s", indent_str, catch_str)
		}
		if n_data.event_pull.from != INVALID_NODE {
			fmt.printf("%s  From:\n", indent_str)
			print_ast(ast, n_data.event_pull.from, indent + 4)
		} else {
			fmt.printf("%s  From: anonymous\n", indent_str)
		}
		if n_data.event_pull.to != INVALID_NODE {
			fmt.printf("%s  To:\n", indent_str)
			print_ast(ast, n_data.event_pull.to, indent + 4)
		}
	case .ResonancePush:
		fmt.printf("%sResonancePush >>- (line %d, column %d)\n", indent_str, pos.line, pos.column)
		if n_data.binary.left != INVALID_NODE {
			fmt.printf("%s  From:\n", indent_str)
			print_ast(ast, n_data.binary.left, indent + 4)
		} else {
			fmt.printf("%s  From: anonymous\n", indent_str)
		}
		if n_data.binary.right != INVALID_NODE {
			fmt.printf("%s  To:\n", indent_str)
			print_ast(ast, n_data.binary.right, indent + 4)
		}
	case .ResonancePull:
		fmt.printf("%sResonancePull -<< (line %d, column %d)\n", indent_str, pos.line, pos.column)
		if n_data.binary.left != INVALID_NODE {
			fmt.printf("%s  From:\n", indent_str)
			print_ast(ast, n_data.binary.left, indent + 4)
		} else {
			fmt.printf("%s  From: anonymous\n", indent_str)
		}
		if n_data.binary.right != INVALID_NODE {
			fmt.printf("%s  To:\n", indent_str)
			print_ast(ast, n_data.binary.right, indent + 4)
		}
	case .Identifier:
		name := node_name_str(ast, idx)
		capture := node_capture_str(ast, idx)
		if capture != "" {
			fmt.printf("%sIdentifier: %s(%s) (line %d, column %d)\n", indent_str, name, capture, pos.line, pos.column)
		} else {
			fmt.printf("%sIdentifier: %s (line %d, column %d)\n", indent_str, name, pos.line, pos.column)
		}
	case .ScopeNode:
		fmt.printf("%sScopeNode (line %d, column %d)\n", indent_str, pos.line, pos.column)
		for child in node_children(ast, idx) {
			print_ast(ast, child, indent + 2)
		}
	case .Carve:
		fmt.printf("%sCarve (line %d, column %d)\n", indent_str, pos.line, pos.column)
		if n_data.carve.source != INVALID_NODE {
			fmt.printf("%s  Source:\n", indent_str)
			print_ast(ast, n_data.carve.source, indent + 4)
			fmt.printf("%s  Carves:\n", indent_str)
			for child in node_carve_children(ast, idx) {
				print_ast(ast, child, indent + 4)
			}
		}
	case .Property:
		fmt.printf("%sProperty (line %d, column %d)\n", indent_str, pos.line, pos.column)
		if n_data.binary.left != INVALID_NODE {
			fmt.printf("%s  Source:\n", indent_str)
			print_ast(ast, n_data.binary.left, indent + 4)
		}
		if n_data.binary.right != INVALID_NODE {
			fmt.printf("%s  Property:\n", indent_str)
			print_ast(ast, n_data.binary.right, indent + 4)
		}
	case .Expand:
		fmt.printf("%sExpand (line %d, column %d)\n", indent_str, pos.line, pos.column)
		if n_data.unary.operand != INVALID_NODE {
			fmt.printf("%s  Target:\n", indent_str)
			print_ast(ast, n_data.unary.operand, indent + 4)
		}
	case .External:
		fmt.printf("%sExternal (line %d, column %d)\n", indent_str, pos.line, pos.column)
		if n_data.external.scope != INVALID_NODE {
			fmt.printf("%s  Target:\n", indent_str)
			print_ast(ast, n_data.external.scope, indent + 4)
		}
	case .Product:
		fmt.printf("%sProduct -> (line %d, column %d)\n", indent_str, pos.line, pos.column)
		if n_data.unary.operand != INVALID_NODE {
			print_ast(ast, n_data.unary.operand, indent + 2)
		}
	case .Pattern:
		fmt.printf("%sPattern ? (line %d, column %d)\n", indent_str, pos.line, pos.column)
		if n_data.pattern.target != INVALID_NODE {
			fmt.printf("%s  Target:\n", indent_str)
			print_ast(ast, n_data.pattern.target, indent + 4)
		} else {
			fmt.printf("%s  Target: implicit\n", indent_str)
		}
		fmt.printf("%s  Branches\n", indent_str)
		branches := node_pattern_branches(ast, idx)
		for i := 0; i < len(branches); i += 2 {
			source := branches[i]
			product := INVALID_NODE
			if i + 1 < len(branches) do product = branches[i+1]
			if source != INVALID_NODE {
				fmt.printf("%s      Pattern:\n", indent_str)
				print_ast(ast, source, indent + 8)
			}
			if product != INVALID_NODE {
				fmt.printf("%s      Match:\n", indent_str)
				print_ast(ast, product, indent + 8)
			}
		}
	case .Constraint:
		fmt.printf("%sConstraint: (line %d, column %d)\n", indent_str, pos.line, pos.column)
		if n_data.binary.left != INVALID_NODE {
			print_ast(ast, n_data.binary.left, indent + 2)
		}
		if n_data.binary.right != INVALID_NODE {
			fmt.printf("%s  To:\n", indent_str)
			print_ast(ast, n_data.binary.right, indent + 4)
		} else {
			fmt.printf("%s  To: none\n", indent_str)
		}
	case .Operator:
		fmt.printf("%sOperator '%v' (line %d, column %d)\n", indent_str, n_data.operator.kind, pos.line, pos.column)
		if n_data.operator.left != INVALID_NODE {
			fmt.printf("%s  Left:\n", indent_str)
			print_ast(ast, n_data.operator.left, indent + 4)
		} else {
			fmt.printf("%s  Left: none (unary operator)\n", indent_str)
		}
		if n_data.operator.right != INVALID_NODE {
			fmt.printf("%s  Right:\n", indent_str)
			print_ast(ast, n_data.operator.right, indent + 4)
		}
	case .Enforce:
		fmt.printf("%sEnforce ?! (line %d, column %d)\n", indent_str, pos.line, pos.column)
		if n_data.binary.left != INVALID_NODE {
			fmt.printf("%s  Left:\n", indent_str)
			print_ast(ast, n_data.binary.left, indent + 4)
		} else {
			fmt.printf("%s  Left: none (unary operator)\n", indent_str)
		}
		if n_data.binary.right != INVALID_NODE {
			fmt.printf("%s  Right:\n", indent_str)
			print_ast(ast, n_data.binary.right, indent + 4)
		}
	case .Branch:
	case .Execute:
		wrappers := node_execute_wrappers(ast, idx)
		pattern := ""
		for w in wrappers {
			switch ExecutionWrapper(w) {
			case .Threading:    pattern = strings.concatenate({pattern, "<"})
			case .Parallel_CPU: pattern = strings.concatenate({pattern, "["})
			case .Background:   pattern = strings.concatenate({pattern, "("})
			case .GPU:          pattern = strings.concatenate({pattern, "|"})
			}
		}
		pattern = strings.concatenate({pattern, "!"})
		for i := len(wrappers) - 1; i >= 0; i -= 1 {
			switch ExecutionWrapper(wrappers[i]) {
			case .Threading:    pattern = strings.concatenate({pattern, ">"})
			case .Parallel_CPU: pattern = strings.concatenate({pattern, "]"})
			case .Background:   pattern = strings.concatenate({pattern, ")"})
			case .GPU:          pattern = strings.concatenate({pattern, "|"})
			}
		}
		fmt.printf("%sExecute %s (line %d, column %d)\n", indent_str, pattern, pos.line, pos.column)
		if n_data.execute.target != INVALID_NODE {
			print_ast(ast, n_data.execute.target, indent + 2)
		}
	case .CompileTime:
		fmt.printf("%sCompileTime ! (line %d, column %d)\n", indent_str, pos.line, pos.column)
		if n_data.unary.operand != INVALID_NODE {
			print_ast(ast, n_data.unary.operand, indent + 2)
		}
	case .Literal:
		fmt.printf("%sLiteral (%v): %s (line %d, column %d)\n", indent_str, n_data.literal.kind, node_text(ast, idx), pos.line, pos.column)
	case .Range:
		fmt.printf("%sRange (line %d, column %d)\n", indent_str, pos.line, pos.column)
		if n_data.binary.left != INVALID_NODE {
			fmt.printf("%s  Start:\n", indent_str)
			print_ast(ast, n_data.binary.left, indent + 4)
		} else {
			fmt.printf("%s  Start: none (prefix range)\n", indent_str)
		}
		if n_data.binary.right != INVALID_NODE {
			fmt.printf("%s  End:\n", indent_str)
			print_ast(ast, n_data.binary.right, indent + 4)
		} else {
			fmt.printf("%s  End: none (postfix range)\n", indent_str)
		}
	case .Unknown:
		fmt.printf("%sUnknown\n", indent_str)
	}
}

ast_root :: #force_inline proc(ast: ^Ast) -> Node_Index {
	return Node_Index(len(ast.node_kinds) - 1)
}
