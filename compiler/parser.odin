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

Node :: struct {
	kind: Node_Kind,
	span: Span,
	data: Node_Data,
}

Ast :: struct {
	source:              string,
	nodes:               [dynamic]Node,
	extra:               [dynamic]Node_Index,
	extra_u8:            [dynamic]u8,
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
	return ast.nodes[idx].kind
}

node_span :: #force_inline proc(ast: ^Ast, idx: Node_Index) -> Span {
	return ast.nodes[idx].span
}

node_position :: proc(ast: ^Ast, idx: Node_Index) -> Position {
	return span_to_position(ast, ast.nodes[idx].span.start)
}

node_text :: #force_inline proc(ast: ^Ast, idx: Node_Index) -> string {
	s := ast.nodes[idx].span
	return ast.source[s.start:s.end]
}

node_left :: #force_inline proc(ast: ^Ast, idx: Node_Index) -> Node_Index {
	return ast.nodes[idx].data.binary.left
}

node_right :: #force_inline proc(ast: ^Ast, idx: Node_Index) -> Node_Index {
	return ast.nodes[idx].data.binary.right
}

node_children :: proc(ast: ^Ast, idx: Node_Index) -> []Node_Index {
	r := ast.nodes[idx].data.scope
	if r.len == 0 do return nil
	return ast.extra[r.start : r.start + r.len]
}

node_carve_source :: #force_inline proc(ast: ^Ast, idx: Node_Index) -> Node_Index {
	return ast.nodes[idx].data.carve.source
}

node_carve_children :: proc(ast: ^Ast, idx: Node_Index) -> []Node_Index {
	r := ast.nodes[idx].data.carve.children
	if r.len == 0 do return nil
	return ast.extra[r.start : r.start + r.len]
}

node_pattern_target :: #force_inline proc(ast: ^Ast, idx: Node_Index) -> Node_Index {
	return ast.nodes[idx].data.pattern.target
}

node_pattern_branches :: proc(ast: ^Ast, idx: Node_Index) -> []Node_Index {
	r := ast.nodes[idx].data.pattern.branches
	if r.len == 0 do return nil
	return ast.extra[r.start : r.start + r.len]
}

node_execute_target :: #force_inline proc(ast: ^Ast, idx: Node_Index) -> Node_Index {
	return ast.nodes[idx].data.execute.target
}

node_execute_wrappers :: proc(ast: ^Ast, idx: Node_Index) -> []u8 {
	r := ast.nodes[idx].data.execute.wrappers
	if r.len == 0 do return nil
	return ast.extra_u8[r.start : r.start + r.len]
}

node_operator_kind :: #force_inline proc(ast: ^Ast, idx: Node_Index) -> Operator_Kind {
	return ast.nodes[idx].data.operator.kind
}

node_operator_left :: #force_inline proc(ast: ^Ast, idx: Node_Index) -> Node_Index {
	return ast.nodes[idx].data.operator.left
}

node_operator_right :: #force_inline proc(ast: ^Ast, idx: Node_Index) -> Node_Index {
	return ast.nodes[idx].data.operator.right
}

node_unary_operand :: #force_inline proc(ast: ^Ast, idx: Node_Index) -> Node_Index {
	return ast.nodes[idx].data.unary.operand
}

node_name_span :: #force_inline proc(ast: ^Ast, idx: Node_Index) -> Span {
	return ast.nodes[idx].data.identifier.name
}

node_name_str :: proc(ast: ^Ast, idx: Node_Index) -> string {
	s := ast.nodes[idx].data.identifier.name
	if s.start == s.end do return ""
	return ast.source[s.start:s.end]
}

node_capture_str :: proc(ast: ^Ast, idx: Node_Index) -> string {
	s := ast.nodes[idx].data.identifier.capture
	if s.start == s.end do return ""
	return ast.source[s.start:s.end]
}

node_literal_kind :: #force_inline proc(ast: ^Ast, idx: Node_Index) -> Literal_Kind {
	return ast.nodes[idx].data.literal.kind
}

node_external_name :: proc(ast: ^Ast, idx: Node_Index) -> string {
	s := ast.nodes[idx].data.external.name
	if s.start == s.end do return ""
	return ast.source[s.start:s.end]
}

node_external_scope :: #force_inline proc(ast: ^Ast, idx: Node_Index) -> Node_Index {
	return ast.nodes[idx].data.external.scope
}

node_event_pull_from :: #force_inline proc(ast: ^Ast, idx: Node_Index) -> Node_Index {
	return ast.nodes[idx].data.event_pull.from
}

node_event_pull_to :: #force_inline proc(ast: ^Ast, idx: Node_Index) -> Node_Index {
	return ast.nodes[idx].data.event_pull.to
}

node_event_pull_catch :: proc(ast: ^Ast, idx: Node_Index) -> string {
	s := ast.nodes[idx].data.event_pull.catch_span
	if s.start == s.end do return ""
	return ast.source[s.start:s.end]
}

/* ======================================================================
 * SECTION 3: TOKEN DEFINITIONS AND LEXER
 * ====================================================================== */

Token_Kind :: enum {
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
	Newline,
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

Token :: struct {
	kind:         Token_Kind,
	span:         Span,
	space_before: bool,
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

skip_whitespace :: #force_inline proc(l: ^Lexer) {
	for l.offset < l.source_len && is_space(l.source[l.offset]) {
		l.offset += 1
	}
}

next_token :: proc(l: ^Lexer) -> Token {
	skip_whitespace(l)

	if l.offset >= l.source_len {
		return Token{kind = .EOF, span = Span{l.offset, l.offset}}
	}

	start := l.offset
	sb := l.offset > 0 && is_space(l.source[l.offset - 1])
	c := l.source[l.offset]

	switch c {
	case '\n', ',':
		return scan_newline(l, start, sb)
	case '`', '"', '\'':
		return scan_string(l, start, sb)
	case '@':
		l.offset += 1
		return Token{kind = .At, span = Span{start, l.offset}, space_before = sb}
	case '{':
		space_before := has_space_before(l)
		l.offset += 1
		if space_before || start == 0 {
			return Token{kind = .LeftBrace, span = Span{start, l.offset}, space_before = sb}
		} else {
			return Token{kind = .LeftBraceCarve, span = Span{start, l.offset}, space_before = sb}
		}
	case '}':
		l.offset += 1
		return Token{kind = .RightBrace, span = Span{start, l.offset}, space_before = sb}
	case '[':
		l.offset += 1
		return Token{kind = .LeftBracket, span = Span{start, l.offset}, space_before = sb}
	case ']':
		l.offset += 1
		return Token{kind = .RightBracket, span = Span{start, l.offset}, space_before = sb}
	case '(':
		space_before := has_space_before(l)
		l.offset += 1
		if space_before || start == 0 {
			return Token{kind = .LeftParen, span = Span{start, l.offset}, space_before = sb}
		} else {
			return Token{kind = .LeftParenNoSpace, span = Span{start, l.offset}, space_before = sb}
		}
	case ')':
		l.offset += 1
		return Token{kind = .RightParen, span = Span{start, l.offset}, space_before = sb}
	case '!':
		l.offset += 1
		if l.offset < l.source_len && l.source[l.offset] == '=' {
			l.offset += 1
			return Token{kind = .NotEqual, span = Span{start, l.offset}, space_before = sb}
		}
		return Token{kind = .Execute, span = Span{start, l.offset}, space_before = sb}
	case ':':
		space_before := has_space_before(l)
		space_after := has_space_after_char(l, ':')
		l.offset += 1
		if space_before {
			if space_after {
				return Token{kind = .Colon, span = Span{start, l.offset}, space_before = sb}
			} else {
				return Token{kind = .ConstraintFromNone, span = Span{start, l.offset}, space_before = sb}
			}
		} else {
			if space_after {
				return Token{kind = .ConstraintToNone, span = Span{start, l.offset}, space_before = sb}
			} else {
				return Token{kind = .ConstraintBind, span = Span{start, l.offset}, space_before = sb}
			}
		}
	case '?':
		l.offset += 1
		if l.offset < l.source_len {
			switch l.source[l.offset] {
			case '?':
				l.offset += 1
				return Token{kind = .DoubleQuestion, span = Span{start, l.offset}, space_before = sb}
			case '!':
				l.offset += 1
				return Token{kind = .QuestionExclamation, span = Span{start, l.offset}, space_before = sb}
			}
		}
		return Token{kind = .Question, span = Span{start, l.offset}, space_before = sb}
	case '.':
		if l.offset + 1 < l.source_len && l.source[l.offset + 1] == '.' {
			has_before_delimiter := l.offset == 0 || is_before_delimiter(l.source[l.offset - 1])
			has_after_delimiter := l.offset + 2 >= l.source_len || is_after_delimiter(l.source[l.offset + 2])
			l.offset += 2
			if l.offset < l.source_len && l.source[l.offset] == '.' {
				l.offset += 1
				return Token{kind = .Ellipsis, span = Span{start, l.offset}, space_before = sb}
			}
			if has_before_delimiter && has_after_delimiter {
				return Token{kind = .DoubleDot, span = Span{start, l.offset}, space_before = sb}
			} else if has_before_delimiter {
				return Token{kind = .PrefixRange, span = Span{start, l.offset}, space_before = sb}
			} else if has_after_delimiter {
				return Token{kind = .PostfixRange, span = Span{start, l.offset}, space_before = sb}
			} else {
				return Token{kind = .Range, span = Span{start, l.offset}, space_before = sb}
			}
		}
		space_before_dot := l.offset == 0 || is_before_delimiter(l.source[l.offset - 1])
		space_after_dot := has_space_after_char(l, '.') || (l.offset + 1 >= l.source_len)
		l.offset += 1
		if space_before_dot {
			if space_after_dot {
				return Token{kind = .Dot, span = Span{start, l.offset}, space_before = sb}
			} else {
				return Token{kind = .PropertyFromNone, span = Span{start, l.offset}, space_before = sb}
			}
		} else {
			if space_after_dot {
				return Token{kind = .PropertyToNone, span = Span{start, l.offset}, space_before = sb}
			} else {
				return Token{kind = .PropertyAccess, span = Span{start, l.offset}, space_before = sb}
			}
		}
	case '=':
		l.offset += 1
		return Token{kind = .Equal, span = Span{start, l.offset}, space_before = sb}
	case '<':
		l.offset += 1
		if l.offset < l.source_len {
			if l.source[l.offset] == '=' {
				l.offset += 1
				return Token{kind = .LessEqual, span = Span{start, l.offset}, space_before = sb}
			} else if l.source[l.offset] == '<' {
				l.offset += 1
				return Token{kind = .LShift, span = Span{start, l.offset}, space_before = sb}
			} else if l.source[l.offset] == '-' {
				l.offset += 1
				return Token{kind = .PointingPull, span = Span{start, l.offset}, space_before = sb}
			}
		}
		return Token{kind = .Less, span = Span{start, l.offset}, space_before = sb}
	case '>':
		l.offset += 1
		if l.offset < l.source_len {
			if l.source[l.offset] == '=' {
				l.offset += 1
				return Token{kind = .GreaterEqual, span = Span{start, l.offset}, space_before = sb}
			} else if l.source[l.offset] == '>' {
				if l.offset + 1 < l.source_len && l.source[l.offset + 1] == '-' {
					l.offset += 2
					return Token{kind = .ResonancePush, span = Span{start, l.offset}, space_before = sb}
				}
				l.offset += 1
				return Token{kind = .RShift, span = Span{start, l.offset}, space_before = sb}
			} else if l.source[l.offset] == '-' {
				l.offset += 1
				return Token{kind = .EventPush, span = Span{start, l.offset}, space_before = sb}
			}
		}
		return Token{kind = .Greater, span = Span{start, l.offset}, space_before = sb}
	case '-':
		l.offset += 1
		if l.offset < l.source_len {
			if l.source[l.offset] == '>' {
				l.offset += 1
				return Token{kind = .PointingPush, span = Span{start, l.offset}, space_before = sb}
			} else if l.source[l.offset] == '<' {
				l.offset += 1
				if l.offset < l.source_len && l.source[l.offset] == '<' {
					l.offset += 1
					return Token{kind = .ResonancePull, span = Span{start, l.offset}, space_before = sb}
				}
				return Token{kind = .EventPull, span = Span{start, l.offset}, space_before = sb}
			}
		}
		return Token{kind = .Minus, span = Span{start, l.offset}, space_before = sb}
	case '/':
		if l.offset + 1 < l.source_len && l.source[l.offset + 1] == '/' {
			l.offset += 2
			for l.offset < l.source_len && l.source[l.offset] != '\n' {
				l.offset += 1
			}
			return next_token(l)
		}
		if l.offset + 1 < l.source_len && l.source[l.offset + 1] == '*' {
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
			return next_token(l)
		}
		l.offset += 1
		return Token{kind = .Slash, span = Span{start, l.offset}, space_before = sb}
	case '0':
		if l.offset + 1 < l.source_len {
			next := l.source[l.offset + 1]
			if next == 'x' || next == 'X' {
				return scan_hexadecimal(l, start, sb)
			}
			if next == 'b' || next == 'B' {
				return scan_binary(l, start, sb)
			}
		}
		fallthrough
	case '1', '2', '3', '4', '5', '6', '7', '8', '9':
		return scan_number(l, start, sb)
	case '+':
		l.offset += 1
		return Token{kind = .Plus, span = Span{start, l.offset}, space_before = sb}
	case '*':
		l.offset += 1
		return Token{kind = .Asterisk, span = Span{start, l.offset}, space_before = sb}
	case '%':
		l.offset += 1
		return Token{kind = .Percent, span = Span{start, l.offset}, space_before = sb}
	case '&':
		l.offset += 1
		return Token{kind = .And, span = Span{start, l.offset}, space_before = sb}
	case '|':
		l.offset += 1
		return Token{kind = .Or, span = Span{start, l.offset}, space_before = sb}
	case '^':
		l.offset += 1
		return Token{kind = .Xor, span = Span{start, l.offset}, space_before = sb}
	case '~':
		l.offset += 1
		return Token{kind = .Not, span = Span{start, l.offset}, space_before = sb}
	case:
		if is_alpha(c) || c == '_' {
			l.offset += 1
			for l.offset < l.source_len && is_alnum(l.source[l.offset]) {
				l.offset += 1
			}
			text := l.source[start:l.offset]
			if text == "true" || text == "false" {
				return Token{kind = .Bool_Literal, span = Span{start, l.offset}, space_before = sb}
			}
			return Token{kind = .Identifier, span = Span{start, l.offset}, space_before = sb}
		}
		l.offset += 1
		return Token{kind = .Invalid, span = Span{start, l.offset}, space_before = sb}
	}
}

scan_newline :: #force_inline proc(l: ^Lexer, start: u32, sb: bool) -> Token {
	l.offset += 1
	for l.offset < l.source_len && l.source[l.offset] == '\n' {
		l.offset += 1
	}
	return Token{kind = .Newline, span = Span{start, l.offset}, space_before = sb}
}

scan_string :: proc(l: ^Lexer, start: u32, sb: bool) -> Token {
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
		return Token{kind = .String_Literal, span = Span{start, l.offset}, space_before = sb}
	}
	return Token{kind = .Invalid, span = Span{start, l.offset}, space_before = sb}
}

scan_hexadecimal :: #force_inline proc(l: ^Lexer, start: u32, sb: bool) -> Token {
	l.offset += 2
	hex_start := l.offset
	for l.offset < l.source_len && is_hex_digit(l.source[l.offset]) {
		l.offset += 1
	}
	if l.offset == hex_start {
		return Token{kind = .Invalid, span = Span{start, l.offset}, space_before = sb}
	}
	return Token{kind = .Hexadecimal, span = Span{start, l.offset}, space_before = sb}
}

scan_binary :: #force_inline proc(l: ^Lexer, start: u32, sb: bool) -> Token {
	l.offset += 2
	bin_start := l.offset
	for l.offset < l.source_len {
		c := l.source[l.offset]
		if c != '0' && c != '1' do break
		l.offset += 1
	}
	if l.offset == bin_start {
		return Token{kind = .Invalid, span = Span{start, l.offset}, space_before = sb}
	}
	return Token{kind = .Binary, span = Span{start, l.offset}, space_before = sb}
}

scan_number :: proc(l: ^Lexer, start: u32, sb: bool) -> Token {
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
				return Token{kind = .Float, span = Span{start, l.offset}, space_before = sb}
			}
		}
	}
	return Token{kind = .Integer, span = Span{start, l.offset}, space_before = sb}
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

Parse_Rule :: struct {
	prefix:     proc(parser: ^Parser) -> Node_Index,
	infix:      proc(parser: ^Parser, left: Node_Index) -> Node_Index,
	precedence: Precedence,
}

Parser :: struct {
	source:        string,
	lexer:         Lexer,
	current_token: Token,
	peek_token:    Token,
	nodes:         [dynamic]Node,
	extra:         [dynamic]Node_Index,
	extra_u8:      [dynamic]u8,
	errors:        [dynamic]Parse_Error,
	panic_mode:    bool,
	file_cache:    ^Cache,
}

init_parser :: proc(parser: ^Parser, cache: ^Cache, source: string) {
	parser.source = source
	parser.file_cache = cache
	init_lexer(&parser.lexer, source)
	parser.panic_mode = false

	estimated_nodes := max(len(source) / 8, 64)
	estimated_extra := estimated_nodes / 3
	parser.nodes = make([dynamic]Node, 0, estimated_nodes)
	parser.extra = make([dynamic]Node_Index, 0, estimated_extra)
	parser.extra_u8 = make([dynamic]u8, 0, 32)

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
		if parser.current_token.kind == .Newline ||
		   parser.current_token.kind == .RightBrace ||
		   parser.current_token.kind == .PointingPush ||
		   parser.current_token.kind == .PointingPull {
			advance_token(parser)
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
	index := Node_Index(len(p.nodes))
	append(&p.nodes, Node{kind = kind, span = span, data = data})
	return index
}

add_extra :: proc(p: ^Parser, indices: []Node_Index) -> Index_Range {
	start := u32(len(p.extra))
	for idx in indices {
		append(&p.extra, idx)
	}
	return Index_Range{start = start, len = u32(len(indices))}
}

add_extra_u8 :: proc(p: ^Parser, wrappers: []u8) -> Index_Range {
	start := u32(len(p.extra_u8))
	for w in wrappers {
		append(&p.extra_u8, w)
	}
	return Index_Range{start = start, len = u32(len(wrappers))}
}

skip_newlines :: proc(parser: ^Parser) {
	for parser.current_token.kind == .Newline {
		advance_token(parser)
	}
}

/* ======================================================================
 * SECTION 5: PARSE RULES TABLE
 * ====================================================================== */

get_rule :: #force_inline proc(kind: Token_Kind) -> Parse_Rule {
	#partial switch kind {
	case .Integer:         return Parse_Rule{prefix = parse_literal, precedence = .PRIMARY}
	case .Float:           return Parse_Rule{prefix = parse_literal, precedence = .PRIMARY}
	case .Hexadecimal:     return Parse_Rule{prefix = parse_literal, precedence = .PRIMARY}
	case .Binary:          return Parse_Rule{prefix = parse_literal, precedence = .PRIMARY}
	case .String_Literal:  return Parse_Rule{prefix = parse_literal, precedence = .PRIMARY}
	case .Bool_Literal:    return Parse_Rule{prefix = parse_literal, precedence = .PRIMARY}
	case .Identifier:      return Parse_Rule{prefix = parse_identifier, precedence = .PRIMARY}

	case .LeftBrace:       return Parse_Rule{prefix = parse_scope, precedence = .CALL}
	case .LeftBraceCarve:  return Parse_Rule{prefix = parse_scope, infix = parse_carve, precedence = .CALL}
	case .LeftBracket:     return Parse_Rule{infix = parse_left_bracket, precedence = .CALL}
	case .LeftParen:       return Parse_Rule{prefix = parse_grouping, precedence = .CALL}
	case .LeftParenNoSpace: return Parse_Rule{prefix = parse_grouping, infix = parse_left_paren, precedence = .CALL}
	case .At:              return Parse_Rule{prefix = parse_reference, precedence = .PRIMARY}

	case .PropertyAccess:    return Parse_Rule{infix = parse_property_access, precedence = .CALL}
	case .PropertyFromNone:  return Parse_Rule{prefix = parse_property_from_none, precedence = .CALL}
	case .PropertyToNone:    return Parse_Rule{infix = parse_property_to_none, precedence = .CALL}
	case .Dot:               return Parse_Rule{prefix = parse_invalid_property, infix = parse_invalid_property_infix, precedence = .CALL}

	case .ConstraintBind:      return Parse_Rule{infix = parse_constraint_bind, precedence = .CONSTRAINT}
	case .ConstraintFromNone:  return Parse_Rule{prefix = parse_constraint_from_none, precedence = .CONSTRAINT}
	case .ConstraintToNone:    return Parse_Rule{infix = parse_constraint_to_none, precedence = .CONSTRAINT}
	case .Colon:               return Parse_Rule{prefix = parse_invalid_constraint, infix = parse_invalid_constraint_infix, precedence = .CONSTRAINT}

	case .Question:          return Parse_Rule{infix = parse_pattern, precedence = .PATTERN}
	case .Execute:           return Parse_Rule{prefix = parse_execute_prefix, infix = parse_execute, precedence = .CALL}

	case .Not:   return Parse_Rule{prefix = parse_unary, precedence = .UNARY}
	case .Minus: return Parse_Rule{prefix = parse_unary, infix = parse_binary, precedence = .TERM}

	case .And:    return Parse_Rule{infix = parse_binary, precedence = .AND}
	case .Or:     return Parse_Rule{infix = parse_bit_or, precedence = .OR}
	case .Xor:    return Parse_Rule{infix = parse_binary, precedence = .AND}
	case .RShift: return Parse_Rule{infix = parse_binary, precedence = .SHIFT}
	case .LShift: return Parse_Rule{infix = parse_binary, precedence = .SHIFT}

	case .Plus:     return Parse_Rule{infix = parse_binary, precedence = .TERM}
	case .Asterisk: return Parse_Rule{infix = parse_binary, precedence = .FACTOR}
	case .Slash:    return Parse_Rule{infix = parse_binary, precedence = .FACTOR}
	case .Percent:  return Parse_Rule{infix = parse_binary, precedence = .FACTOR}

	case .Equal:        return Parse_Rule{prefix = parse_prefix_comparison, infix = parse_binary, precedence = .EQUALITY}
	case .NotEqual:     return Parse_Rule{prefix = parse_prefix_comparison, infix = parse_binary, precedence = .EQUALITY}
	case .Less:         return Parse_Rule{prefix = parse_prefix_comparison, infix = parse_less_than, precedence = .COMPARISON}
	case .Greater:      return Parse_Rule{prefix = parse_prefix_comparison, infix = parse_binary, precedence = .COMPARISON}
	case .LessEqual:    return Parse_Rule{prefix = parse_prefix_comparison, infix = parse_binary, precedence = .COMPARISON}
	case .GreaterEqual: return Parse_Rule{prefix = parse_prefix_comparison, infix = parse_binary, precedence = .COMPARISON}

	case .DoubleDot:    return Parse_Rule{prefix = parse_empty_range, precedence = .PRIMARY}
	case .PrefixRange:  return Parse_Rule{prefix = parse_prefix_range, precedence = .RANGE}
	case .PostfixRange: return Parse_Rule{infix = parse_postfix_range, precedence = .RANGE}
	case .Range:        return Parse_Rule{prefix = parse_prefix_range, infix = parse_range, precedence = .RANGE}

	case .DoubleQuestion:      return Parse_Rule{prefix = parse_unknown, precedence = .PRIMARY}
	case .QuestionExclamation: return Parse_Rule{infix = parse_enforce, precedence = .PATTERN}

	case .PointingPush:  return Parse_Rule{prefix = parse_product_prefix, infix = parse_pointing_push, precedence = .POINTING}
	case .PointingPull:  return Parse_Rule{prefix = parse_pointing_pull_prefix, infix = parse_pointing_pull, precedence = .ASSIGNMENT}
	case .EventPush:     return Parse_Rule{prefix = parse_event_push_prefix, infix = parse_event_push, precedence = .ASSIGNMENT}
	case .EventPull:     return Parse_Rule{prefix = parse_event_pull_prefix, infix = parse_event_pull, precedence = .ASSIGNMENT}
	case .ResonancePush: return Parse_Rule{prefix = parse_resonance_push_prefix, infix = parse_resonance_push, precedence = .ASSIGNMENT}
	case .ResonancePull: return Parse_Rule{prefix = parse_resonance_pull_prefix, infix = parse_resonance_pull, precedence = .ASSIGNMENT}

	case .Ellipsis: return Parse_Rule{prefix = parse_expansion, precedence = .PRIMARY}
	}
	return Parse_Rule{}
}

/* ======================================================================
 * SECTION 6: MAIN PARSE ENTRY POINTS
 * ====================================================================== */

parse :: proc(cache: ^Cache, source: string) -> ^Ast {
	parser: Parser
	init_parser(&parser, cache, source)
	span_start := parser.current_token.span.start

	children := make([dynamic]Node_Index, 0, 16, context.temp_allocator)

	for parser.current_token.kind != .EOF {
		for parser.current_token.kind == .Newline {
			advance_token(&parser)
		}
		if parser.current_token.kind == .EOF do break

		if node := parse_with_recovery(&parser); node != INVALID_NODE {
			append(&children, node)
		}
	}

	data: Node_Data
	r := add_extra(&parser, children[:])
	data.scope = {start = r.start, len = r.len}
	root_span := Span{span_start, parser.current_token.span.end}
	add_node(&parser, .ScopeNode, data, root_span)

	ast := new(Ast)
	ast.source = source
	ast.nodes = parser.nodes
	ast.extra = parser.extra
	ast.extra_u8 = parser.extra_u8

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
	node := parse_statement(parser)
	for parser.current_token.kind == .Newline {
		advance_token(parser)
	}
	return node
}

parse_statement :: proc(parser: ^Parser) -> Node_Index {
	if parser.current_token.kind == .Newline {
		advance_token(parser)
		return INVALID_NODE
	}
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

	rule := get_rule(parser.current_token.kind)
	if rule.prefix == nil {
		advance_token(parser)
		if parser.current_token.kind == .EOF || parser.current_token.kind == .RightBrace {
			return INVALID_NODE
		}
		return parse_expression(parser, precedence)
	}

	left := rule.prefix(parser)
	if left == INVALID_NODE do return INVALID_NODE

	infix_loop: for {
		if parser.current_token.kind == .Newline {
			saved_current := parser.current_token
			saved_peek := parser.peek_token
			saved_offset := parser.lexer.offset
			skip_newlines(parser)
			if is_infix_operator(parser.current_token.kind) {
				continue
			}
			parser.current_token = saved_current
			parser.peek_token = saved_peek
			parser.lexer.offset = saved_offset
		}
		rule := get_rule(parser.current_token.kind)
		if rule.infix == nil || rule.precedence < precedence {
			break
		}
		if parser.current_token.kind == .PointingPush {
			left_kind := parser.nodes[left].kind
			if left_kind == .Product || left_kind == .Pointing {
				break infix_loop
			}
		}
		left = rule.infix(parser, left)
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

	children := make([dynamic]Node_Index, 0, 4, context.temp_allocator)

	for parser.current_token.kind != .RightBrace && parser.current_token.kind != .EOF {
		skip_newlines(parser)
		if parser.current_token.kind == .RightBrace do break

		if parser.panic_mode {
			synchronize(parser)
			if parser.current_token.kind == .RightBrace do break
		}

		if node := parse_statement(parser); node != INVALID_NODE {
			append(&children, node)
		}
		skip_newlines(parser)
	}

	span_end := parser.current_token.span.end
	if !match_token(parser, .RightBrace) {
		error_at_current(parser, "Expected '}' to close scope")
	}

	data: Node_Data
	r2 := add_extra(parser, children[:])
	data.scope = {start = r2.start, len = r2.len}
	return add_node(parser, .ScopeNode, data, Span{span_start, span_end})
}

parse_carve :: proc(parser: ^Parser, left: Node_Index) -> Node_Index {
	span_start := parser.current_token.span.start
	advance_token(parser)

	children := make([dynamic]Node_Index, 0, 4, context.temp_allocator)

	for parser.current_token.kind != .RightBrace && parser.current_token.kind != .EOF {
		for parser.current_token.kind == .Newline {
			advance_token(parser)
		}
		if parser.current_token.kind == .RightBrace do break

		if node := parse_statement(parser); node != INVALID_NODE {
			append(&children, node)
		} else {
			synchronize(parser)
			if parser.current_token.kind == .RightBrace do break
		}

		for parser.current_token.kind == .Newline {
			advance_token(parser)
		}
	}

	span_end := parser.current_token.span.end
	if !match_token(parser, .RightBrace) {
		error_at_current(parser, "Expected } after carves")
	}

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
	return add_node(parser, .CompileTime, data, Span{span.start, parser.nodes[operand].span.end})
}

parse_execute :: proc(parser: ^Parser, left: Node_Index) -> Node_Index {
	span := parser.current_token.span
	advance_token(parser)
	data: Node_Data
	data.execute = Execute_Data{target = left, wrappers = EMPTY_RANGE}
	return add_node(parser, .Execute, data, Span{parser.nodes[left].span.start, span.end})
}

parse_product_prefix :: proc(parser: ^Parser) -> Node_Index {
	span_start := parser.current_token.span.start
	advance_token(parser)

	if parser.current_token.kind == .RightBrace || parser.current_token.kind == .EOF ||
	   parser.current_token.kind == .Newline {
		data: Node_Data
		data.unary = Unary_Data{operand = INVALID_NODE}
		return add_node(parser, .Product, data, Span{span_start, parser.current_token.span.start})
	}

	to := parse_expression(parser, .PATTERN)
	if to == INVALID_NODE do return INVALID_NODE

	data: Node_Data
	data.unary = Unary_Data{operand = to}
	return add_node(parser, .Product, data, Span{span_start, parser.nodes[to].span.end})
}

parse_binary :: proc(parser: ^Parser, left: Node_Index) -> Node_Index {
	span_start := parser.nodes[left].span.start
	token_kind := parser.current_token.kind
	rule := get_rule(token_kind)
	advance_token(parser)
	skip_newlines(parser)

	right := parse_expression(parser, Precedence(int(rule.precedence) + 1))
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
	return add_node(parser, .Operator, data, Span{span_start, parser.nodes[right].span.end})
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
	return add_node(parser, .Operator, data, Span{span_start, parser.nodes[operand].span.end})
}

parse_property_access :: proc(parser: ^Parser, left: Node_Index) -> Node_Index {
	span_start := parser.nodes[left].span.start
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
	span_start := parser.nodes[left].span.start
	advance_token(parser)

	data: Node_Data
	data.binary = Binary_Data{left = left, right = INVALID_NODE}
	return add_node(parser, .Property, data, Span{span_start, parser.current_token.span.start})
}

parse_constraint_bind :: proc(parser: ^Parser, left: Node_Index) -> Node_Index {
	span_start := parser.nodes[left].span.start
	advance_token(parser)

	name := INVALID_NODE
	if parser.current_token.kind == .RightBrace ||
	   parser.current_token.kind == .EOF ||
	   parser.current_token.kind == .Newline {
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
		span_end = parser.nodes[name].span.end
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
	   parser.current_token.kind == .Newline {
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
		span_end = parser.nodes[name].span.end
	}
	node := add_node(parser, .Constraint, data, Span{span_start, span_end})

	if parser.current_token.kind == .LeftBraceCarve {
		return parse_carve(parser, node)
	}
	return node
}

parse_constraint_to_none :: proc(parser: ^Parser, left: Node_Index) -> Node_Index {
	span_start := parser.nodes[left].span.start
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
	span_start := parser.nodes[left].span.start
	advance_token(parser)

	to := INVALID_NODE
	if parser.current_token.kind != .RightBrace &&
	   parser.current_token.kind != .EOF &&
	   parser.current_token.kind != .Newline {
		to = parse_expression(parser, .ASSIGNMENT)
	}

	data: Node_Data
	data.binary = Binary_Data{left = left, right = to}
	span_end := parser.current_token.span.start
	if to != INVALID_NODE {
		span_end = parser.nodes[to].span.end
	}
	return add_node(parser, .Pointing, data, Span{span_start, span_end})
}

parse_pointing_pull_prefix :: proc(parser: ^Parser) -> Node_Index {
	span_start := parser.current_token.span.start
	advance_token(parser)

	to := INVALID_NODE
	if parser.current_token.kind != .RightBrace &&
	   parser.current_token.kind != .EOF &&
	   parser.current_token.kind != .Newline {
		to = parse_expression(parser, .ASSIGNMENT)
	}

	data: Node_Data
	data.binary = Binary_Data{left = INVALID_NODE, right = to}
	span_end := parser.current_token.span.start
	if to != INVALID_NODE {
		span_end = parser.nodes[to].span.end
	}
	return add_node(parser, .PointingPull, data, Span{span_start, span_end})
}

parse_pointing_pull :: proc(parser: ^Parser, left: Node_Index) -> Node_Index {
	span_start := parser.nodes[left].span.start
	advance_token(parser)

	to := INVALID_NODE
	if parser.current_token.kind != .RightBrace &&
	   parser.current_token.kind != .EOF &&
	   parser.current_token.kind != .Newline {
		to = parse_expression(parser, .ASSIGNMENT)
	}

	data: Node_Data
	data.binary = Binary_Data{left = left, right = to}
	span_end := parser.current_token.span.start
	if to != INVALID_NODE {
		span_end = parser.nodes[to].span.end
	}
	return add_node(parser, .PointingPull, data, Span{span_start, span_end})
}

parse_event_push_prefix :: proc(parser: ^Parser) -> Node_Index {
	span_start := parser.current_token.span.start
	advance_token(parser)

	to := INVALID_NODE
	if parser.current_token.kind != .RightBrace &&
	   parser.current_token.kind != .EOF &&
	   parser.current_token.kind != .Newline {
		to = parse_expression(parser)
	}

	data: Node_Data
	data.binary = Binary_Data{left = INVALID_NODE, right = to}
	span_end := parser.current_token.span.start
	if to != INVALID_NODE {
		span_end = parser.nodes[to].span.end
	}
	return add_node(parser, .EventPush, data, Span{span_start, span_end})
}

parse_event_push :: proc(parser: ^Parser, left: Node_Index) -> Node_Index {
	span_start := parser.nodes[left].span.start
	advance_token(parser)

	to := INVALID_NODE
	if parser.current_token.kind != .RightBrace &&
	   parser.current_token.kind != .EOF &&
	   parser.current_token.kind != .Newline {
		to = parse_expression(parser)
	}

	data: Node_Data
	data.binary = Binary_Data{left = left, right = to}
	span_end := parser.current_token.span.start
	if to != INVALID_NODE {
		span_end = parser.nodes[to].span.end
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
	   parser.current_token.kind != .Newline {
		to = parse_expression(parser)
	}

	data: Node_Data
	data.event_pull = EventPull_Data{from = INVALID_NODE, to = to, catch_span = catch_span}
	span_end := parser.current_token.span.start
	if to != INVALID_NODE {
		span_end = parser.nodes[to].span.end
	}
	return add_node(parser, .EventPull, data, Span{span_start, span_end})
}

parse_event_pull :: proc(parser: ^Parser, left: Node_Index) -> Node_Index {
	span_start := parser.nodes[left].span.start
	advance_token(parser)

	catch_span := EMPTY_SPAN
	if parser.current_token.kind == .Identifier {
		catch_span = parser.current_token.span
		advance_token(parser)
	}

	to := INVALID_NODE
	if parser.current_token.kind != .RightBrace &&
	   parser.current_token.kind != .EOF &&
	   parser.current_token.kind != .Newline {
		to = parse_expression(parser)
	}

	data: Node_Data
	data.event_pull = EventPull_Data{from = left, to = to, catch_span = catch_span}
	span_end := parser.current_token.span.start
	if to != INVALID_NODE {
		span_end = parser.nodes[to].span.end
	}
	return add_node(parser, .EventPull, data, Span{span_start, span_end})
}

parse_resonance_push_prefix :: proc(parser: ^Parser) -> Node_Index {
	span_start := parser.current_token.span.start
	advance_token(parser)

	to := INVALID_NODE
	if parser.current_token.kind != .RightBrace &&
	   parser.current_token.kind != .EOF &&
	   parser.current_token.kind != .Newline {
		to = parse_expression(parser, Precedence(int(Precedence.ASSIGNMENT) + 1))
	}

	data: Node_Data
	data.binary = Binary_Data{left = INVALID_NODE, right = to}
	span_end := parser.current_token.span.start
	if to != INVALID_NODE {
		span_end = parser.nodes[to].span.end
	}
	return add_node(parser, .ResonancePush, data, Span{span_start, span_end})
}

parse_resonance_push :: proc(parser: ^Parser, left: Node_Index) -> Node_Index {
	span_start := parser.nodes[left].span.start
	advance_token(parser)

	to := INVALID_NODE
	if parser.current_token.kind != .RightBrace &&
	   parser.current_token.kind != .EOF &&
	   parser.current_token.kind != .Newline {
		to = parse_expression(parser, Precedence(int(Precedence.ASSIGNMENT) + 1))
	}

	data: Node_Data
	data.binary = Binary_Data{left = left, right = to}
	span_end := parser.current_token.span.start
	if to != INVALID_NODE {
		span_end = parser.nodes[to].span.end
	}
	return add_node(parser, .ResonancePush, data, Span{span_start, span_end})
}

parse_resonance_pull_prefix :: proc(parser: ^Parser) -> Node_Index {
	span_start := parser.current_token.span.start
	advance_token(parser)

	to := INVALID_NODE
	if parser.current_token.kind != .RightBrace &&
	   parser.current_token.kind != .EOF &&
	   parser.current_token.kind != .Newline {
		to = parse_expression(parser, Precedence(int(Precedence.ASSIGNMENT) + 1))
	}

	data: Node_Data
	data.binary = Binary_Data{left = INVALID_NODE, right = to}
	span_end := parser.current_token.span.start
	if to != INVALID_NODE {
		span_end = parser.nodes[to].span.end
	}
	return add_node(parser, .ResonancePull, data, Span{span_start, span_end})
}

parse_resonance_pull :: proc(parser: ^Parser, left: Node_Index) -> Node_Index {
	span_start := parser.nodes[left].span.start
	advance_token(parser)

	to := INVALID_NODE
	if parser.current_token.kind != .RightBrace &&
	   parser.current_token.kind != .EOF &&
	   parser.current_token.kind != .Newline {
		to = parse_expression(parser, Precedence(int(Precedence.ASSIGNMENT) + 1))
	}

	data: Node_Data
	data.binary = Binary_Data{left = left, right = to}
	span_end := parser.current_token.span.start
	if to != INVALID_NODE {
		span_end = parser.nodes[to].span.end
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
	   parser.current_token.kind != .Newline {
		end = parse_expression(parser, .RANGE)
	}

	data: Node_Data
	data.binary = Binary_Data{left = INVALID_NODE, right = end}
	span_end := parser.current_token.span.start
	if end != INVALID_NODE {
		span_end = parser.nodes[end].span.end
	}
	return add_node(parser, .Range, data, Span{span_start, span_end})
}

parse_postfix_range :: proc(parser: ^Parser, left: Node_Index) -> Node_Index {
	span_start := parser.nodes[left].span.start
	advance_token(parser)

	data: Node_Data
	data.binary = Binary_Data{left = left, right = INVALID_NODE}
	return add_node(parser, .Range, data, Span{span_start, parser.current_token.span.start})
}

parse_range :: proc(parser: ^Parser, left: Node_Index) -> Node_Index {
	span_start := parser.nodes[left].span.start
	advance_token(parser)

	end := INVALID_NODE
	if parser.current_token.kind != .RightBrace &&
	   parser.current_token.kind != .EOF &&
	   parser.current_token.kind != .Newline {
		end = parse_expression(parser, .RANGE)
	}

	data: Node_Data
	data.binary = Binary_Data{left = left, right = end}
	span_end := parser.current_token.span.start
	if end != INVALID_NODE {
		span_end = parser.nodes[end].span.end
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
	return add_node(parser, .Operator, data, Span{span_start, parser.nodes[operand].span.end})
}

parse_pattern :: proc(parser: ^Parser, left: Node_Index) -> Node_Index {
	span_start := parser.nodes[left].span.start
	advance_token(parser)

	skip_newlines(parser)

	branch_indices := make([dynamic]Node_Index, 0, 4, context.temp_allocator)

	if parser.current_token.kind == .LeftBrace {
		advance_token(parser)
		skip_newlines(parser)

		for parser.current_token.kind != .RightBrace && parser.current_token.kind != .EOF {
			source_idx, product_idx := parse_branch(parser)
			append(&branch_indices, source_idx)
			append(&branch_indices, product_idx)
			skip_newlines(parser)
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
			append(&branch_indices, inline_expr)
			append(&branch_indices, INVALID_NODE)
		}
	}

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
	span_start := parser.nodes[left].span.start
	token_kind := parser.current_token.kind
	rule := get_rule(token_kind)
	advance_token(parser)
	skip_newlines(parser)

	right := parse_expression(parser, Precedence(int(rule.precedence) + 1))
	if right == INVALID_NODE {
		error_at_current(parser, "Expected expression after binary operator")
		return INVALID_NODE
	}

	data: Node_Data
	data.binary = Binary_Data{left = left, right = right}
	return add_node(parser, .Enforce, data, Span{span_start, parser.nodes[right].span.end})
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
	return add_node(parser, .Expand, data, Span{span_start, parser.nodes[target].span.end})
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

	span_start := parser.nodes[left].span.start
	advance_token(parser)

	right := parse_expression(parser, Precedence(int(Precedence.COMPARISON) + 1))
	data: Node_Data
	data.operator = Operator_Node_Data{kind = .Less, left = left, right = right}
	span_end := parser.current_token.span.start
	if right != INVALID_NODE {
		span_end = parser.nodes[right].span.end
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
	original_offset := parser.lexer.offset
	original_current := parser.current_token
	original_peek := parser.peek_token
	nodes_len := len(parser.nodes)

	wrappers := make([dynamic]u8, 0, 4, context.temp_allocator)
	stack := make([dynamic]Token_Kind, 0, 4, context.temp_allocator)

	found_exclamation := false

	for {
		current := parser.current_token.kind
		#partial switch current {
		case .Execute:
			found_exclamation = true
			advance_token(parser)
		case .LeftParen, .LeftParenNoSpace:
			append(&wrappers, u8(ExecutionWrapper.Background))
			append(&stack, Token_Kind.LeftParen)
			advance_token(parser)
		case .Less:
			append(&wrappers, u8(ExecutionWrapper.Threading))
			append(&stack, Token_Kind.Less)
			advance_token(parser)
		case .LeftBracket:
			append(&wrappers, u8(ExecutionWrapper.Parallel_CPU))
			append(&stack, Token_Kind.LeftBracket)
			advance_token(parser)
		case .Or:
			if len(stack) > 0 && stack[len(stack)-1] == Token_Kind.Or {
				ordered_remove(&stack, len(stack)-1)
				advance_token(parser)
			} else {
				append(&wrappers, u8(ExecutionWrapper.GPU))
				append(&stack, Token_Kind.Or)
				advance_token(parser)
			}
		case .RightParen:
			if len(stack) == 0 || stack[len(stack)-1] != Token_Kind.LeftParen {
				parser.lexer.offset = original_offset
				parser.current_token = original_current
				parser.peek_token = original_peek
				resize(&parser.nodes, nodes_len)
				return INVALID_NODE, false
			}
			ordered_remove(&stack, len(stack)-1)
			advance_token(parser)
		case .Greater:
			if len(stack) == 0 || stack[len(stack)-1] != Token_Kind.Less {
				parser.lexer.offset = original_offset
				parser.current_token = original_current
				parser.peek_token = original_peek
				resize(&parser.nodes, nodes_len)
				return INVALID_NODE, false
			}
			ordered_remove(&stack, len(stack)-1)
			advance_token(parser)
		case .RightBracket:
			if len(stack) == 0 || stack[len(stack)-1] != Token_Kind.LeftBracket {
				parser.lexer.offset = original_offset
				parser.current_token = original_current
				parser.peek_token = original_peek
				resize(&parser.nodes, nodes_len)
				return INVALID_NODE, false
			}
			ordered_remove(&stack, len(stack)-1)
			advance_token(parser)
		case:
			if !found_exclamation {
				parser.lexer.offset = original_offset
				parser.current_token = original_current
				parser.peek_token = original_peek
				resize(&parser.nodes, nodes_len)
				return INVALID_NODE, false
			}
			break
		}

		if len(stack) == 0 {
			if found_exclamation {
				break
			} else {
				parser.lexer.offset = original_offset
				parser.current_token = original_current
				parser.peek_token = original_peek
				resize(&parser.nodes, nodes_len)
				return INVALID_NODE, false
			}
		}
	}

	if !found_exclamation || len(stack) > 0 {
		parser.lexer.offset = original_offset
		parser.current_token = original_current
		parser.peek_token = original_peek
		resize(&parser.nodes, nodes_len)
		return INVALID_NODE, false
	}

	data: Node_Data
	data.execute = Execute_Data{target = left, wrappers = add_extra_u8(parser, wrappers[:])}
	span := Span{parser.nodes[left].span.start, parser.current_token.span.start}
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
	n := ast.nodes[idx]
	pos := span_to_position(ast, n.span.start)

	switch n.kind {
	case .Pointing:
		fmt.printf("%sPointing -> (line %d, column %d)\n", indent_str, pos.line, pos.column)
		if n.data.binary.left != INVALID_NODE {
			fmt.printf("%s  From:\n", indent_str)
			print_ast(ast, n.data.binary.left, indent + 4)
		}
		if n.data.binary.right != INVALID_NODE {
			fmt.printf("%s  To:\n", indent_str)
			print_ast(ast, n.data.binary.right, indent + 4)
		}
	case .PointingPull:
		fmt.printf("%sPointingPull <- (line %d, column %d)\n", indent_str, pos.line, pos.column)
		if n.data.binary.left != INVALID_NODE {
			fmt.printf("%s  From:\n", indent_str)
			print_ast(ast, n.data.binary.left, indent + 4)
		} else {
			fmt.printf("%s  From: anonymous\n", indent_str)
		}
		if n.data.binary.right != INVALID_NODE {
			fmt.printf("%s  To:\n", indent_str)
			print_ast(ast, n.data.binary.right, indent + 4)
		}
	case .EventPush:
		fmt.printf("%sEventPush >- (line %d, column %d)\n", indent_str, pos.line, pos.column)
		if n.data.binary.left != INVALID_NODE {
			fmt.printf("%s  From:\n", indent_str)
			print_ast(ast, n.data.binary.left, indent + 4)
		} else {
			fmt.printf("%s  From: anonymous\n", indent_str)
		}
		if n.data.binary.right != INVALID_NODE {
			fmt.printf("%s  To:\n", indent_str)
			print_ast(ast, n.data.binary.right, indent + 4)
		}
	case .EventPull:
		fmt.printf("%sEventPull -< (line %d, column %d)\n", indent_str, pos.line, pos.column)
		catch_str := node_event_pull_catch(ast, idx)
		if catch_str != "" {
			fmt.printfln("%s  Catch: %s", indent_str, catch_str)
		}
		if n.data.event_pull.from != INVALID_NODE {
			fmt.printf("%s  From:\n", indent_str)
			print_ast(ast, n.data.event_pull.from, indent + 4)
		} else {
			fmt.printf("%s  From: anonymous\n", indent_str)
		}
		if n.data.event_pull.to != INVALID_NODE {
			fmt.printf("%s  To:\n", indent_str)
			print_ast(ast, n.data.event_pull.to, indent + 4)
		}
	case .ResonancePush:
		fmt.printf("%sResonancePush >>- (line %d, column %d)\n", indent_str, pos.line, pos.column)
		if n.data.binary.left != INVALID_NODE {
			fmt.printf("%s  From:\n", indent_str)
			print_ast(ast, n.data.binary.left, indent + 4)
		} else {
			fmt.printf("%s  From: anonymous\n", indent_str)
		}
		if n.data.binary.right != INVALID_NODE {
			fmt.printf("%s  To:\n", indent_str)
			print_ast(ast, n.data.binary.right, indent + 4)
		}
	case .ResonancePull:
		fmt.printf("%sResonancePull -<< (line %d, column %d)\n", indent_str, pos.line, pos.column)
		if n.data.binary.left != INVALID_NODE {
			fmt.printf("%s  From:\n", indent_str)
			print_ast(ast, n.data.binary.left, indent + 4)
		} else {
			fmt.printf("%s  From: anonymous\n", indent_str)
		}
		if n.data.binary.right != INVALID_NODE {
			fmt.printf("%s  To:\n", indent_str)
			print_ast(ast, n.data.binary.right, indent + 4)
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
		if n.data.carve.source != INVALID_NODE {
			fmt.printf("%s  Source:\n", indent_str)
			print_ast(ast, n.data.carve.source, indent + 4)
			fmt.printf("%s  Carves:\n", indent_str)
			for child in node_carve_children(ast, idx) {
				print_ast(ast, child, indent + 4)
			}
		}
	case .Property:
		fmt.printf("%sProperty (line %d, column %d)\n", indent_str, pos.line, pos.column)
		if n.data.binary.left != INVALID_NODE {
			fmt.printf("%s  Source:\n", indent_str)
			print_ast(ast, n.data.binary.left, indent + 4)
		}
		if n.data.binary.right != INVALID_NODE {
			fmt.printf("%s  Property:\n", indent_str)
			print_ast(ast, n.data.binary.right, indent + 4)
		}
	case .Expand:
		fmt.printf("%sExpand (line %d, column %d)\n", indent_str, pos.line, pos.column)
		if n.data.unary.operand != INVALID_NODE {
			fmt.printf("%s  Target:\n", indent_str)
			print_ast(ast, n.data.unary.operand, indent + 4)
		}
	case .External:
		fmt.printf("%sExternal (line %d, column %d)\n", indent_str, pos.line, pos.column)
		if n.data.external.scope != INVALID_NODE {
			fmt.printf("%s  Target:\n", indent_str)
			print_ast(ast, n.data.external.scope, indent + 4)
		}
	case .Product:
		fmt.printf("%sProduct -> (line %d, column %d)\n", indent_str, pos.line, pos.column)
		if n.data.unary.operand != INVALID_NODE {
			print_ast(ast, n.data.unary.operand, indent + 2)
		}
	case .Pattern:
		fmt.printf("%sPattern ? (line %d, column %d)\n", indent_str, pos.line, pos.column)
		if n.data.pattern.target != INVALID_NODE {
			fmt.printf("%s  Target:\n", indent_str)
			print_ast(ast, n.data.pattern.target, indent + 4)
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
		if n.data.binary.left != INVALID_NODE {
			print_ast(ast, n.data.binary.left, indent + 2)
		}
		if n.data.binary.right != INVALID_NODE {
			fmt.printf("%s  To:\n", indent_str)
			print_ast(ast, n.data.binary.right, indent + 4)
		} else {
			fmt.printf("%s  To: none\n", indent_str)
		}
	case .Operator:
		fmt.printf("%sOperator '%v' (line %d, column %d)\n", indent_str, n.data.operator.kind, pos.line, pos.column)
		if n.data.operator.left != INVALID_NODE {
			fmt.printf("%s  Left:\n", indent_str)
			print_ast(ast, n.data.operator.left, indent + 4)
		} else {
			fmt.printf("%s  Left: none (unary operator)\n", indent_str)
		}
		if n.data.operator.right != INVALID_NODE {
			fmt.printf("%s  Right:\n", indent_str)
			print_ast(ast, n.data.operator.right, indent + 4)
		}
	case .Enforce:
		fmt.printf("%sEnforce ?! (line %d, column %d)\n", indent_str, pos.line, pos.column)
		if n.data.binary.left != INVALID_NODE {
			fmt.printf("%s  Left:\n", indent_str)
			print_ast(ast, n.data.binary.left, indent + 4)
		} else {
			fmt.printf("%s  Left: none (unary operator)\n", indent_str)
		}
		if n.data.binary.right != INVALID_NODE {
			fmt.printf("%s  Right:\n", indent_str)
			print_ast(ast, n.data.binary.right, indent + 4)
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
		if n.data.execute.target != INVALID_NODE {
			print_ast(ast, n.data.execute.target, indent + 2)
		}
	case .CompileTime:
		fmt.printf("%sCompileTime ! (line %d, column %d)\n", indent_str, pos.line, pos.column)
		if n.data.unary.operand != INVALID_NODE {
			print_ast(ast, n.data.unary.operand, indent + 2)
		}
	case .Literal:
		fmt.printf("%sLiteral (%v): %s (line %d, column %d)\n", indent_str, n.data.literal.kind, node_text(ast, idx), pos.line, pos.column)
	case .Range:
		fmt.printf("%sRange (line %d, column %d)\n", indent_str, pos.line, pos.column)
		if n.data.binary.left != INVALID_NODE {
			fmt.printf("%s  Start:\n", indent_str)
			print_ast(ast, n.data.binary.left, indent + 4)
		} else {
			fmt.printf("%s  Start: none (prefix range)\n", indent_str)
		}
		if n.data.binary.right != INVALID_NODE {
			fmt.printf("%s  End:\n", indent_str)
			print_ast(ast, n.data.binary.right, indent + 4)
		} else {
			fmt.printf("%s  End: none (postfix range)\n", indent_str)
		}
	case .Unknown:
		fmt.printf("%sUnknown\n", indent_str)
	}
}

ast_root :: #force_inline proc(ast: ^Ast) -> Node_Index {
	return Node_Index(len(ast.nodes) - 1)
}
