package compiler

import "core:fmt"
import "core:strconv"

// Lexer + parser for Syntact. Pipeline: bytes → tokens (a table-driven lexer,
// one handler per leading byte) → a flat, arena-allocated AST consumed by the
// analyzer. The parser is a single-pass Pratt parser (prefix/infix dispatch
// tables keyed by token, ordered by `Precedence`).
//
// This file is the lexer + parser machinery only. The AST data model it builds
// — node tags, payload unions, the SOA `Ast` container, the `node_*` accessors,
// and `print_ast` — lives in ast.odin.

// --- tokens and lexer ---
//
// Syntact is whitespace-sensitive: the same byte lexes to different tokens
// depending on the spaces around it (`{` opens a scope, `{` glued to an operand
// opens a carve; `:` is a constraint bind or a plain colon by its neighbours).
// The lexer therefore tracks surrounding-space facts both as per-token `flags`
// (was there a space/newline/comma before this token?) and, for the operators
// where it matters, by peeking at adjacent bytes. Dispatch is table-driven:
// LEX_DISPATCH[leading byte] picks the handler, and small PAIR_* tables resolve
// multi-byte operators without nested branching.

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
	ReactivePush,
	ReactivePull,
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
	Cast, // `::` — raw binary reinterpret-cast into the target's layout
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
	BitAnd,
	BitOr,
	BitNot,
	RShift,
	LShift,
}

// Trivia facts about what preceded a token, packed as bit positions into the
// token's `flags` byte. The parser reads these to make grammar decisions a pure
// token stream can't: a `Separator_Before` (newline or comma) ends a binding
// even with no explicit terminator, and a `Space_Before` distinguishes an infix
// operator from a prefix one.
Token_Flags :: enum u8 {
	Line_Before      = 0,
	Space_Before     = 1,
	Separator_Before = 2, // newline or comma — a soft statement boundary
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
	src:        [^]u8,
	offset:     u32,
	source_len: u32,
}

init_lexer :: #force_inline proc(l: ^Lexer, source: string) {
	l.source = source
	l.src = raw_data(source)
	l.offset = 0
	l.source_len = u32(len(source))
}

current_char :: #force_inline proc(l: ^Lexer) -> u8 {
	if l.offset >= l.source_len do return 0
	return l.src[l.offset]
}

peek_char :: #force_inline proc(l: ^Lexer, n: u32 = 1) -> u8 {
	pos := l.offset + n
	if pos >= l.source_len do return 0
	return l.src[pos]
}

// has_space_before reports whether the byte just before the cursor is a space —
// the primitive behind the {/{carve and (/(call distinctions.
has_space_before :: #force_inline proc(l: ^Lexer) -> bool {
	return l.offset > 0 && IS_SPACE[l.src[l.offset - 1]]
}

has_space_after_char :: #force_inline proc(l: ^Lexer, char: u8) -> bool {
	if l.offset < l.source_len && l.src[l.offset] == char {
		return l.offset + 1 < l.source_len && IS_SPACE[l.src[l.offset + 1]]
	}
	return false
}

// skip_trivia advances past spaces, newlines and commas, returning the trivia
// flags to stamp on the next token. Newline and comma are folded together as
// Separator_Before: both are soft statement boundaries in Syntact, so the parser
// treats `a\nb` and `a, b` identically.
skip_trivia :: #force_inline proc(l: ^Lexer) -> u8 {
	flags: u8 = 0
	src := l.src
	slen := l.source_len
	off := l.offset
	for off < slen {
		c := src[off]
		if IS_SPACE[c] {
			set_flag(&flags, .Space_Before)
			off += 1
		} else if c == '\n' || c == ',' {
			set_flag(&flags, .Line_Before)
			set_flag(&flags, .Separator_Before)
			off += 1
		} else {
			break
		}
	}
	l.offset = off
	return flags
}

// One handler per possible leading byte. Indexing a 256-entry table beats a long
// switch: the hot loop is a single load + indirect call, branch-predictor-friendly.
Lex_Handler :: #type proc(l: ^Lexer, start: u32, flags: u8) -> Token

LEX_DISPATCH: [256]Lex_Handler

// Resolves a two-byte operator from its second byte: `len` 0 means "no pair, the
// leading byte stands alone", otherwise (kind, len) is the combined token.
Pair_Result :: struct {
	kind: Token_Kind,
	len:  u8,
}

// Second-byte lookup tables, one per multi-byte-starting operator. e.g. PAIR_MINUS['>']
// = {.PointingPush, 2} turns `->` into one token; a 3-byte form like `-<<` is
// handled by the handler peeking one byte further (see lex_minus).
PAIR_LESS: [256]Pair_Result
PAIR_GREATER: [256]Pair_Result
PAIR_MINUS: [256]Pair_Result
PAIR_BANG: [256]Pair_Result
PAIR_QUESTION: [256]Pair_Result
PAIR_ZERO: [256]Pair_Result

// `:` disambiguated by [space-before][space-after]. ` : ` (spaces both sides) is
// a plain Colon; glued forms are the constraint-bind family. See lex_colon.
COLON_TABLE: [2][2]Token_Kind

// init_lex_dispatch wires every byte to its handler and fills the PAIR_*/COLON
// tables. Runs once at startup (@init). Bytes with no entry fall through to
// lex_invalid.
@(init)
init_lex_dispatch :: proc "contextless" () {
	for i in 0 ..< 256 {LEX_DISPATCH[i] = lex_invalid}

	LEX_DISPATCH['@'] = lex_single_at
	LEX_DISPATCH['}'] = lex_single_rbrace
	LEX_DISPATCH[']'] = lex_single_rbracket
	LEX_DISPATCH[')'] = lex_single_rparen
	LEX_DISPATCH['='] = lex_single_equal
	LEX_DISPATCH['+'] = lex_single_plus
	LEX_DISPATCH['*'] = lex_single_asterisk
	LEX_DISPATCH['%'] = lex_single_percent
	LEX_DISPATCH['&'] = lex_single_and
	LEX_DISPATCH['|'] = lex_single_or
	LEX_DISPATCH['^'] = lex_single_xor
	LEX_DISPATCH['~'] = lex_single_not
	LEX_DISPATCH['/'] = lex_single_slash
	LEX_DISPATCH['['] = lex_single_lbracket

	LEX_DISPATCH['`'] = scan_string
	LEX_DISPATCH['"'] = scan_string
	LEX_DISPATCH['\''] = scan_string

	LEX_DISPATCH['{'] = lex_lbrace
	LEX_DISPATCH['('] = lex_lparen
	LEX_DISPATCH['!'] = lex_bang
	LEX_DISPATCH[':'] = lex_colon
	LEX_DISPATCH['?'] = lex_question
	LEX_DISPATCH['.'] = lex_dot
	LEX_DISPATCH['<'] = lex_less
	LEX_DISPATCH['>'] = lex_greater
	LEX_DISPATCH['-'] = lex_minus

	LEX_DISPATCH['0'] = lex_zero
	for c in u8('1') ..= u8('9') {LEX_DISPATCH[c] = scan_number}
	for c in u8('a') ..= u8('z') {LEX_DISPATCH[c] = lex_ident}
	for c in u8('A') ..= u8('Z') {LEX_DISPATCH[c] = lex_ident}
	LEX_DISPATCH['_'] = lex_ident
	LEX_DISPATCH['#'] = lex_hash

	PAIR_LESS['='] = {.LessEqual, 2}
	PAIR_LESS['<'] = {.LShift, 2}
	PAIR_LESS['-'] = {.PointingPull, 2}

	PAIR_GREATER['='] = {.GreaterEqual, 2}
	PAIR_GREATER['>'] = {.RShift, 2}
	PAIR_GREATER['-'] = {.EventPush, 2}

	PAIR_MINUS['>'] = {.PointingPush, 2}
	PAIR_MINUS['<'] = {.EventPull, 2}

	PAIR_BANG['='] = {.NotEqual, 2}

	PAIR_QUESTION['?'] = {.DoubleQuestion, 2}
	PAIR_QUESTION['!'] = {.QuestionExclamation, 2}

	PAIR_ZERO['x'] = {.Hexadecimal, 0}
	PAIR_ZERO['X'] = {.Hexadecimal, 0}
	PAIR_ZERO['b'] = {.Binary, 0}
	PAIR_ZERO['B'] = {.Binary, 0}

	COLON_TABLE[0][0] = .ConstraintBind
	COLON_TABLE[0][1] = .ConstraintToNone
	COLON_TABLE[1][0] = .ConstraintFromNone
	COLON_TABLE[1][1] = .Colon
}

lex_single_at :: #force_inline proc(l: ^Lexer, s: u32, f: u8) -> Token {l.offset = s + 1
	return Token{.At, Span{s, s + 1}, f}}
lex_single_rbrace :: #force_inline proc(l: ^Lexer, s: u32, f: u8) -> Token {l.offset = s + 1
	return Token{.RightBrace, Span{s, s + 1}, f}}
lex_single_rbracket :: #force_inline proc(l: ^Lexer, s: u32, f: u8) -> Token {l.offset = s + 1
	return Token{.RightBracket, Span{s, s + 1}, f}}
lex_single_rparen :: #force_inline proc(l: ^Lexer, s: u32, f: u8) -> Token {l.offset = s + 1
	return Token{.RightParen, Span{s, s + 1}, f}}
// `=` is single, except `=<<` which is the reactive-pull operator.
lex_single_equal :: #force_inline proc(l: ^Lexer, s: u32, f: u8) -> Token {
	if s + 2 < l.source_len && l.src[s + 1] == '<' && l.src[s + 2] == '<' {
		l.offset = s + 3
		return Token{kind = .ReactivePull, span = Span{s, s + 3}, flags = f}
	}
	l.offset = s + 1
	return Token{.Equal, Span{s, s + 1}, f}}
lex_single_plus :: #force_inline proc(l: ^Lexer, s: u32, f: u8) -> Token {l.offset = s + 1
	return Token{.Plus, Span{s, s + 1}, f}}
lex_single_asterisk :: #force_inline proc(l: ^Lexer, s: u32, f: u8) -> Token {l.offset = s + 1
	return Token{.Asterisk, Span{s, s + 1}, f}}
lex_single_percent :: #force_inline proc(l: ^Lexer, s: u32, f: u8) -> Token {l.offset = s + 1
	return Token{.Percent, Span{s, s + 1}, f}}
lex_single_and :: #force_inline proc(l: ^Lexer, s: u32, f: u8) -> Token {l.offset = s + 1
	return Token{.And, Span{s, s + 1}, f}}
lex_single_or :: #force_inline proc(l: ^Lexer, s: u32, f: u8) -> Token {l.offset = s + 1
	return Token{.Or, Span{s, s + 1}, f}}
lex_single_xor :: #force_inline proc(l: ^Lexer, s: u32, f: u8) -> Token {l.offset = s + 1
	return Token{.Xor, Span{s, s + 1}, f}}
lex_single_not :: #force_inline proc(l: ^Lexer, s: u32, f: u8) -> Token {l.offset = s + 1
	return Token{.Not, Span{s, s + 1}, f}}
lex_single_slash :: #force_inline proc(l: ^Lexer, s: u32, f: u8) -> Token {l.offset = s + 1
	return Token{.Slash, Span{s, s + 1}, f}}
// `[` is a left bracket, except the bracketed bitwise operators `[&]`, `[|]`,
// `[~]` — three-byte tokens that keep the bitwise ops visually distinct from the
// set-algebra `&`/`|`/`~`.
lex_single_lbracket :: #force_inline proc(l: ^Lexer, s: u32, f: u8) -> Token {
	if s + 2 < l.source_len && l.src[s + 2] == ']' {
		switch l.src[s + 1] {
		case '&':
			l.offset = s + 3
			return Token{.BitAnd, Span{s, s + 3}, f}
		case '|':
			l.offset = s + 3
			return Token{.BitOr, Span{s, s + 3}, f}
		case '~':
			l.offset = s + 3
			return Token{.BitNot, Span{s, s + 3}, f}
		}
	}
	l.offset = s + 1
	return Token{.LeftBracket, Span{s, s + 1}, f}
}

// `{` with a space before it opens a fresh scope; glued to an operand (`x{…}`)
// it opens a carve of that operand. The parser keys the carve infix rule on
// LeftBraceCarve, so the distinction is decided here, at the byte.
lex_lbrace :: #force_inline proc(l: ^Lexer, start: u32, flags: u8) -> Token {
	sb := start == 0 || IS_SPACE[l.src[start - 1]]
	l.offset = start + 1
	return Token {
		kind = sb ? .LeftBrace : .LeftBraceCarve,
		span = Span{start, start + 1},
		flags = flags,
	}
}

// Same space rule as `{`: a glued `(` (LeftParenNoSpace) binds tightly to the
// preceding operand (it can start a call/group on it), a spaced `(` is a plain group.
lex_lparen :: #force_inline proc(l: ^Lexer, start: u32, flags: u8) -> Token {
	sb := start == 0 || IS_SPACE[l.src[start - 1]]
	l.offset = start + 1
	return Token {
		kind = sb ? .LeftParen : .LeftParenNoSpace,
		span = Span{start, start + 1},
		flags = flags,
	}
}

// `!` is the collapse operator (Execute), unless followed by `=` to form `!=`.
lex_bang :: #force_inline proc(l: ^Lexer, start: u32, flags: u8) -> Token {
	nc := start + 1 < l.source_len ? l.src[start + 1] : u8(0)
	p := PAIR_BANG[nc]
	kind := p.len != 0 ? p.kind : Token_Kind.Execute
	tlen := u32(p.len != 0 ? p.len : 1)
	l.offset = start + tlen
	return Token{kind = kind, span = Span{start, start + tlen}, flags = flags}
}

// `:` is structural coloring, and its exact flavor depends on whitespace.
// COLON_TABLE[space_before][space_after] picks among ConstraintBind (`c:x`),
// ConstraintFromNone (` :x`), ConstraintToNone (`c: `), and plain Colon (` : `).
// `sa` is the byte immediately after the `:`; a bare `c:x` therefore stays a
// tight constraint bind. `::` is intercepted first: it is the raw-cast operator,
// a single two-byte token regardless of surrounding whitespace.
lex_colon :: #force_inline proc(l: ^Lexer, start: u32, flags: u8) -> Token {
	src := l.src
	if start + 1 < l.source_len && src[start + 1] == ':' {
		l.offset = start + 2
		return Token{kind = .Cast, span = Span{start, start + 2}, flags = flags}
	}
	sb := u8(start > 0 && IS_SPACE[src[start - 1]])
	sa := u8(
		start < l.source_len &&
		src[start] == ':' &&
		start + 1 < l.source_len &&
		IS_SPACE[src[start + 1]],
	)
	l.offset = start + 1
	return Token{kind = COLON_TABLE[sb][sa], span = Span{start, start + 1}, flags = flags}
}

lex_question :: #force_inline proc(l: ^Lexer, start: u32, flags: u8) -> Token {
	nc := start + 1 < l.source_len ? l.src[start + 1] : u8(0)
	p := PAIR_QUESTION[nc]
	kind := p.len != 0 ? p.kind : Token_Kind.Question
	tlen := u32(p.len != 0 ? p.len : 1)
	l.offset = start + tlen
	return Token{kind = kind, span = Span{start, start + tlen}, flags = flags}
}

lex_less :: #force_inline proc(l: ^Lexer, start: u32, flags: u8) -> Token {
	nc := start + 1 < l.source_len ? l.src[start + 1] : u8(0)
	p := PAIR_LESS[nc]
	kind := p.len != 0 ? p.kind : Token_Kind.Less
	tlen := u32(p.len != 0 ? p.len : 1)
	l.offset = start + tlen
	return Token{kind = kind, span = Span{start, start + tlen}, flags = flags}
}

// `>` resolves via PAIR_GREATER to `>=`/`>>`/`>-`, but `>>` is only the start of
// the three-byte resonance/reactivity push operators: `>>-` (ResonancePush) and
// `>>=` (ReactivePush). Peek the third byte before settling for RShift.
lex_greater :: #force_inline proc(l: ^Lexer, start: u32, flags: u8) -> Token {
	nc := start + 1 < l.source_len ? l.src[start + 1] : u8(0)
	p := PAIR_GREATER[nc]
	if p.kind == .RShift && start + 2 < l.source_len {
		c3 := l.src[start + 2]
		if c3 == '-' {
			l.offset = start + 3
			return Token{kind = .ResonancePush, span = Span{start, start + 3}, flags = flags}
		}
		if c3 == '=' {
			l.offset = start + 3
			return Token{kind = .ReactivePush, span = Span{start, start + 3}, flags = flags}
		}
	}
	kind := p.len != 0 ? p.kind : Token_Kind.Greater
	tlen := u32(p.len != 0 ? p.len : 1)
	l.offset = start + tlen
	return Token{kind = kind, span = Span{start, start + tlen}, flags = flags}
}

// `-` resolves via PAIR_MINUS to `->`/`-<`, but `-<` extends to the three-byte
// `-<<` (ResonancePull). Same one-byte lookahead as lex_greater.
lex_minus :: #force_inline proc(l: ^Lexer, start: u32, flags: u8) -> Token {
	nc := start + 1 < l.source_len ? l.src[start + 1] : u8(0)
	p := PAIR_MINUS[nc]
	if p.kind == .EventPull && start + 2 < l.source_len && l.src[start + 2] == '<' {
		l.offset = start + 3
		return Token{kind = .ResonancePull, span = Span{start, start + 3}, flags = flags}
	}
	kind := p.len != 0 ? p.kind : Token_Kind.Minus
	tlen := u32(p.len != 0 ? p.len : 1)
	l.offset = start + tlen
	return Token{kind = kind, span = Span{start, start + tlen}, flags = flags}
}

// A leading `0` may introduce a radix prefix (`0x`/`0X`, `0b`/`0B`); PAIR_ZERO
// recognizes the prefix byte and routes to the matching scanner, else it's a
// plain decimal number.
lex_zero :: #force_inline proc(l: ^Lexer, start: u32, flags: u8) -> Token {
	nc := start + 1 < l.source_len ? l.src[start + 1] : u8(0)
	p := PAIR_ZERO[nc]
	if p.kind == .Hexadecimal {return scan_hexadecimal(l, start, flags)}
	if p.kind == .Binary {return scan_binary(l, start, flags)}
	return scan_number(l, start, flags)
}

// The dot family is the most context-sensitive token. `...` is always Ellipsis.
// `..` is a range, but its precise kind tells the parser whether each side has an
// operand: with a value-delimiter on both sides it's a DoubleDot (both bounds
// present, `a..b`), only before → PrefixRange (`..b`), only after → PostfixRange
// (`a..`), neither → bare Range. A single `.` is the same idea for member access:
// delimiters both sides → Dot, otherwise the half-open Property{From,To}None
// forms. "Delimiter" here means a byte that can't be part of an operand, so the
// lexer can tell `a.b` (property) from `a. ` / `.b` without parser feedback.
lex_dot :: #force_inline proc(l: ^Lexer, start: u32, flags: u8) -> Token {
	src := l.src
	slen := l.source_len
	off := start
	if off + 1 < slen && src[off + 1] == '.' {
		has_before := off == 0 || IS_BEFORE_DELIM[src[off - 1]]
		has_after := off + 2 >= slen || IS_AFTER_DELIM[src[off + 2]]
		off += 2
		if off < slen && src[off] == '.' {
			off += 1
			l.offset = off
			return Token{kind = .Ellipsis, span = Span{start, off}, flags = flags}
		}
		l.offset = off
		kind := Token_Kind.Range
		if has_before &&
		   has_after {kind = .DoubleDot} else if has_before {kind = .PrefixRange} else if has_after {kind = .PostfixRange}
		return Token{kind = kind, span = Span{start, off}, flags = flags}
	}
	bd := off == 0 || IS_BEFORE_DELIM[src[off - 1]]
	ad := (off + 1 >= slen) || (src[off] == '.' && off + 1 < slen && IS_SPACE[src[off + 1]])
	off += 1
	l.offset = off
	kind := Token_Kind.PropertyAccess
	if bd &&
	   ad {kind = .Dot} else if bd {kind = .PropertyFromNone} else if ad {kind = .PropertyToNone}
	return Token{kind = kind, span = Span{start, off}, flags = flags}
}

// An identifier run, with two special cases folded in: the literals `true`/
// `false` lex as Bool_Literal (Syntact has no keywords otherwise), and a trailing
// `#<digits>` is consumed as part of the identifier — it is the ordinal selector
// that picks among same-name bindings (`a#1`). The ordinal is split back out at
// parse time (parse_identifier).
lex_ident :: #force_inline proc(l: ^Lexer, start: u32, flags: u8) -> Token {
	src := l.src
	slen := l.source_len
	off := start + 1
	for off < slen && IDENT_CONTINUE[src[off]] {
		off += 1
	}
	l.offset = off
	ilen := off - start
	if ilen == 4 &&
	   src[start] == 't' &&
	   src[start + 1] == 'r' &&
	   src[start + 2] == 'u' &&
	   src[start + 3] == 'e' {
		return Token{kind = .Bool_Literal, span = Span{start, off}, flags = flags}
	}
	if ilen == 5 &&
	   src[start] == 'f' &&
	   src[start + 1] == 'a' &&
	   src[start + 2] == 'l' &&
	   src[start + 3] == 's' &&
	   src[start + 4] == 'e' {
		return Token{kind = .Bool_Literal, span = Span{start, off}, flags = flags}
	}
	if off < slen && src[off] == '#' && off + 1 < slen && IS_DIGIT[src[off + 1]] {
		off += 1
		for off < slen && IS_DIGIT[src[off]] {
			off += 1
		}
		l.offset = off
	}
	return Token{kind = .Identifier, span = Span{start, off}, flags = flags}
}

// A bare `#<digits>` (no leading identifier) is an anonymous ordinal selector,
// lexed as an Identifier whose name span is just the `#n`. A lone `#` is invalid.
lex_hash :: proc(l: ^Lexer, start: u32, flags: u8) -> Token {
	src := l.src
	slen := l.source_len
	off := start + 1
	if off < slen && IS_DIGIT[src[off]] {
		for off < slen && IS_DIGIT[src[off]] {
			off += 1
		}
		l.offset = off
		return Token{kind = .Identifier, span = Span{start, off}, flags = flags}
	}
	l.offset = start + 1
	return Token{kind = .Invalid, span = Span{start, start + 1}, flags = flags}
}

lex_invalid :: #force_inline proc(l: ^Lexer, start: u32, flags: u8) -> Token {
	l.offset = start + 1
	return Token{kind = .Invalid, span = Span{start, start + 1}, flags = flags}
}

// next_token is the lexer's pull interface: skip trivia (recording its flags),
// skip comments, then dispatch on the leading byte. Comments are not tokens — a
// `//` line comment runs to the newline, and `/* … */` block comments nest (the
// `depth` counter), so a commented-out region containing comments closes cleanly.
// After skipping either kind we loop back to re-skip trivia, since a comment may
// be followed by more whitespace or another comment.
next_token :: proc(l: ^Lexer) -> Token {
	flags: u8
	src := l.src
	slen := l.source_len
	off: u32

	for {
		flags = skip_trivia(l)
		off = l.offset

		if off >= slen {
			return Token{kind = .EOF, span = Span{off, off}, flags = flags}
		}

		c := src[off]

		if c == '/' && off + 1 < slen {
			nc := src[off + 1]
			if nc == '/' {
				off += 2
				for off < slen && src[off] != '\n' {
					off += 1
				}
				l.offset = off
				continue
			}
			if nc == '*' {
				off += 2
				depth: u32 = 1
				for off < slen && depth > 0 {
					if off + 1 < slen && src[off] == '/' && src[off + 1] == '*' {
						off += 2
						depth += 1
					} else if off + 1 < slen && src[off] == '*' && src[off + 1] == '/' {
						off += 2
						depth -= 1
					} else {
						off += 1
					}
				}
				l.offset = off
				continue
			}
		}
		break
	}

	return LEX_DISPATCH[src[off]](l, off, flags)
}

// scan_string consumes a quoted literal up to the matching delimiter. The
// delimiter byte (`'`, `"`, or backtick) is preserved in the span so the parser
// can recover the quotation kind. In non-raw modes `\x` escapes skip two bytes
// so an escaped delimiter doesn't end the string; backtick is raw, so `\` is
// literal. An unterminated literal returns Invalid.
scan_string :: proc(l: ^Lexer, start: u32, f: u8) -> Token {
	src := l.src
	slen := l.source_len
	delimiter := src[l.offset]
	raw := delimiter == '`' // backtick = raw: '\' is not an escape
	l.offset += 1
	for l.offset < slen {
		current := src[l.offset]
		if current == delimiter {
			break
		}
		if !raw && current == '\\' && l.offset + 1 < slen {
			l.offset += 2
		} else {
			l.offset += 1
		}
	}
	if l.offset < slen {
		l.offset += 1
		return Token{kind = .String_Literal, span = Span{start, l.offset}, flags = f}
	}
	return Token{kind = .Invalid, span = Span{start, l.offset}, flags = f}
}

scan_hexadecimal :: #force_inline proc(l: ^Lexer, start: u32, f: u8) -> Token {
	src := l.src
	slen := l.source_len
	l.offset += 2
	hex_start := l.offset
	for l.offset < slen && IS_HEX[src[l.offset]] {
		l.offset += 1
	}
	if l.offset == hex_start {
		return Token{kind = .Invalid, span = Span{start, l.offset}, flags = f}
	}
	return Token{kind = .Hexadecimal, span = Span{start, l.offset}, flags = f}
}

scan_binary :: #force_inline proc(l: ^Lexer, start: u32, f: u8) -> Token {
	src := l.src
	slen := l.source_len
	l.offset += 2
	bin_start := l.offset
	for l.offset < slen {
		c := src[l.offset]
		if c != '0' && c != '1' do break
		l.offset += 1
	}
	if l.offset == bin_start {
		return Token{kind = .Invalid, span = Span{start, l.offset}, flags = f}
	}
	return Token{kind = .Binary, span = Span{start, l.offset}, flags = f}
}

// scan_number reads a decimal run; a `.` followed by another digit turns it into
// a Float. The digit lookahead is what keeps `1.foo` (member access on `1`) and
// `1..2` (a range) from being mis-scanned as floats — a `.` not followed by a
// digit is left for lex_dot.
scan_number :: #force_inline proc(l: ^Lexer, start: u32, f: u8) -> Token {
	src := l.src
	slen := l.source_len
	for l.offset < slen && IS_DIGIT[src[l.offset]] {
		l.offset += 1
	}
	if l.offset < slen && src[l.offset] == '.' {
		if l.offset + 1 < slen {
			if IS_DIGIT[src[l.offset + 1]] {
				l.offset += 1
				for l.offset < slen && IS_DIGIT[src[l.offset]] {
					l.offset += 1
				}
				return Token{kind = .Float, span = Span{start, l.offset}, flags = f}
			}
		}
	}
	return Token{kind = .Integer, span = Span{start, l.offset}, flags = f}
}


// --- parser (Pratt / precedence-climbing) ---
//
// A token-keyed Pratt parser. Each token may register a prefix handler (it can
// start an expression — a literal, `-x`, `(…)`), an infix handler (it continues
// one — `a + b`, `a.b`, `a{…}`), and a left binding power in `prec_table`. The
// core loop (parse_expression) parses a prefix, then folds infix operators while
// their precedence exceeds the caller's, so binding tightness is data, not code.

// Binding powers, weakest to tightest. parse_expression keeps consuming infix
// operators whose prec_table entry is strictly higher than the precedence it was
// invoked with; an infix handler that wants right-associativity recurses at its
// own level rather than level+1 (see parse_binary).
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

// A prefix handler parses a token that begins an expression; an infix handler
// extends an already-parsed `left` with the current operator token.
Prefix_Proc :: proc(parser: ^Parser) -> Node_Index
Infix_Proc :: proc(parser: ^Parser, left: Node_Index) -> Node_Index

// The Pratt dispatch tables, indexed by Token_Kind. A token may appear in both
// prefix_table and infix_table (e.g. `-` is unary negate and binary subtract);
// prec_table gives its infix binding power. Unset entries are nil/NONE.
prefix_table: [Token_Kind]Prefix_Proc
infix_table: [Token_Kind]Infix_Proc
prec_table: [Token_Kind]Precedence

// init_parse_tables populates the dispatch tables once at startup (@init).
@(init)
init_parse_tables :: proc "contextless" () {
	prefix_table[.Integer] = parse_literal
	prefix_table[.Float] = parse_literal
	prefix_table[.Hexadecimal] = parse_literal
	prefix_table[.Binary] = parse_literal
	prefix_table[.String_Literal] = parse_literal
	prefix_table[.Bool_Literal] = parse_literal
	prefix_table[.Identifier] = parse_identifier

	prefix_table[.LeftBrace] = parse_scope
	prefix_table[.LeftBraceCarve] = parse_scope
	prefix_table[.LeftParen] = parse_grouping
	prefix_table[.LeftParenNoSpace] = parse_grouping
	prefix_table[.At] = parse_reference

	prefix_table[.PropertyFromNone] = parse_property_from_none
	prefix_table[.Dot] = parse_invalid_property
	prefix_table[.ConstraintFromNone] = parse_constraint_from_none
	prefix_table[.Colon] = parse_invalid_constraint

	prefix_table[.Execute] = parse_execute_prefix
	prefix_table[.Not] = parse_unary
	prefix_table[.BitNot] = parse_unary
	prefix_table[.Minus] = parse_unary
	prefix_table[.Equal] = parse_prefix_comparison
	prefix_table[.NotEqual] = parse_prefix_comparison
	prefix_table[.Less] = parse_prefix_comparison
	prefix_table[.Greater] = parse_prefix_comparison
	prefix_table[.LessEqual] = parse_prefix_comparison
	prefix_table[.GreaterEqual] = parse_prefix_comparison

	prefix_table[.DoubleDot] = parse_empty_range
	prefix_table[.PrefixRange] = parse_prefix_range
	prefix_table[.Range] = parse_prefix_range
	prefix_table[.DoubleQuestion] = parse_unknown
	prefix_table[.PointingPush] = parse_product_prefix
	prefix_table[.PointingPull] = parse_pointing_pull_prefix
	prefix_table[.EventPush] = parse_event_push_prefix
	prefix_table[.EventPull] = parse_event_pull_prefix
	prefix_table[.ResonancePush] = parse_resonance_push_prefix
	prefix_table[.ResonancePull] = parse_resonance_pull_prefix
	prefix_table[.ReactivePush] = parse_reactive_push_prefix
	prefix_table[.ReactivePull] = parse_reactive_pull_prefix
	prefix_table[.Ellipsis] = parse_expansion

	infix_table[.LeftBraceCarve] = parse_carve
	infix_table[.LeftBracket] = parse_left_bracket
	infix_table[.LeftParenNoSpace] = parse_left_paren
	infix_table[.PropertyAccess] = parse_property_access
	infix_table[.PropertyToNone] = parse_property_to_none
	infix_table[.Dot] = parse_invalid_property_infix
	infix_table[.ConstraintBind] = parse_constraint_bind
	infix_table[.ConstraintToNone] = parse_constraint_to_none
	infix_table[.Colon] = parse_invalid_constraint_infix
	infix_table[.Cast] = parse_binary
	infix_table[.Question] = parse_pattern
	infix_table[.Execute] = parse_execute
	infix_table[.Minus] = parse_binary
	infix_table[.And] = parse_binary
	infix_table[.Or] = parse_bit_or
	infix_table[.Xor] = parse_binary
	infix_table[.BitAnd] = parse_binary
	infix_table[.BitOr] = parse_binary
	infix_table[.RShift] = parse_binary
	infix_table[.LShift] = parse_binary
	infix_table[.Plus] = parse_binary
	infix_table[.Asterisk] = parse_binary
	infix_table[.Slash] = parse_binary
	infix_table[.Percent] = parse_binary
	infix_table[.Equal] = parse_binary
	infix_table[.NotEqual] = parse_binary
	infix_table[.Less] = parse_less_than
	infix_table[.Greater] = parse_binary
	infix_table[.LessEqual] = parse_binary
	infix_table[.GreaterEqual] = parse_binary
	infix_table[.PostfixRange] = parse_postfix_range
	infix_table[.Range] = parse_range
	infix_table[.QuestionExclamation] = parse_enforce
	infix_table[.PointingPush] = parse_pointing_push
	infix_table[.PointingPull] = parse_pointing_pull
	infix_table[.EventPush] = parse_event_push
	infix_table[.EventPull] = parse_event_pull
	infix_table[.ResonancePush] = parse_resonance_push
	infix_table[.ResonancePull] = parse_resonance_pull
	infix_table[.ReactivePush] = parse_reactive_push
	infix_table[.ReactivePull] = parse_reactive_pull

	prec_table[.Integer] = .PRIMARY
	prec_table[.Float] = .PRIMARY
	prec_table[.Hexadecimal] = .PRIMARY
	prec_table[.Binary] = .PRIMARY
	prec_table[.String_Literal] = .PRIMARY
	prec_table[.Bool_Literal] = .PRIMARY
	prec_table[.Identifier] = .PRIMARY

	prec_table[.LeftBrace] = .CALL
	prec_table[.LeftBraceCarve] = .CALL
	prec_table[.LeftBracket] = .CALL
	prec_table[.LeftParen] = .CALL
	prec_table[.LeftParenNoSpace] = .CALL
	prec_table[.At] = .PRIMARY

	prec_table[.PropertyAccess] = .CALL
	prec_table[.PropertyFromNone] = .CALL
	prec_table[.PropertyToNone] = .CALL
	prec_table[.Dot] = .CALL

	prec_table[.ConstraintBind] = .CONSTRAINT
	prec_table[.ConstraintFromNone] = .CONSTRAINT
	prec_table[.ConstraintToNone] = .CONSTRAINT
	prec_table[.Colon] = .CONSTRAINT
	// `::` binds tighter than arithmetic — `a+b::u8` parses as `a+(b::u8)`,
	// so casting the sum requires explicit parens: `(a+b)::u8`.
	prec_table[.Cast] = .CONSTRAINT

	prec_table[.Question] = .PATTERN
	prec_table[.Execute] = .CALL

	prec_table[.Not] = .UNARY
	prec_table[.Minus] = .TERM

	prec_table[.And] = .AND
	prec_table[.Or] = .OR
	prec_table[.Xor] = .AND
	prec_table[.BitAnd] = .AND
	prec_table[.BitOr] = .OR
	prec_table[.BitNot] = .UNARY
	prec_table[.RShift] = .SHIFT
	prec_table[.LShift] = .SHIFT

	prec_table[.Plus] = .TERM
	prec_table[.Asterisk] = .FACTOR
	prec_table[.Slash] = .FACTOR
	prec_table[.Percent] = .FACTOR

	prec_table[.Equal] = .EQUALITY
	prec_table[.NotEqual] = .EQUALITY
	prec_table[.Less] = .COMPARISON
	prec_table[.Greater] = .COMPARISON
	prec_table[.LessEqual] = .COMPARISON
	prec_table[.GreaterEqual] = .COMPARISON

	prec_table[.DoubleDot] = .PRIMARY
	prec_table[.PrefixRange] = .RANGE
	prec_table[.PostfixRange] = .RANGE
	prec_table[.Range] = .RANGE

	prec_table[.DoubleQuestion] = .PRIMARY
	prec_table[.QuestionExclamation] = .PATTERN

	prec_table[.PointingPush] = .POINTING
	prec_table[.PointingPull] = .ASSIGNMENT
	prec_table[.EventPush] = .ASSIGNMENT
	prec_table[.EventPull] = .ASSIGNMENT
	prec_table[.ResonancePush] = .ASSIGNMENT
	prec_table[.ResonancePull] = .ASSIGNMENT
	prec_table[.ReactivePush] = .ASSIGNMENT
	prec_table[.ReactivePull] = .ASSIGNMENT

	prec_table[.Ellipsis] = .PRIMARY
}

// grow_buffer doubles a slice's capacity in place. Geometric growth keeps the
// amortized cost of the many small appends during parsing O(1) per element.
grow_buffer :: proc($T: typeid, buf: ^[]T, current_len: int) {
	old := buf^
	new_cap := len(old) * 2
	new_buf := make([]T, new_cap)
	copy(new_buf[:current_len], old[:current_len])
	delete(old)
	buf^ = new_buf
}

// A stack-discipline staging area for variable-arity children. A handler that
// collects an unknown number of children (scope body, carve overrides, …)
// records a checkpoint with scratch_begin, appends as it goes, then scratch_end
// hands back the slice to flush into `extra` and scratch_reset rewinds. Nesting
// works because every level only ever rewinds to its own checkpoint.
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
	source:         string,
	lexer:          Lexer,
	current_token:  Token,
	peek_token:     Token,
	node_kinds:     []Node_Kind,
	node_spans:     []Span,
	node_data:      []Node_Data,
	node_count:     u32,
	extra:          []Node_Index,
	extra_count:    u32,
	extra_u8:       []u8,
	extra_u8_count: u32,
	errors:         [dynamic]Parse_Error,
	panic_mode:     bool,
	file_cache:     ^Cache,
	scratch:        Scratch_Buffer,
}

// init_parser allocates the SOA node store up front, sized from the source
// length so the common case never reallocates. The bytes-per-node ratio shrinks
// as files grow (larger files are denser in operators per byte, so fewer nodes
// per byte); the buckets are tuned guesses, and grow_buffer covers any underestimate.
// It also primes the two-token lookahead (current + peek).
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
	error_at_current(
		parser,
		fmt.tprintf("Expected %v but got %v", kind, parser.current_token.kind),
	)
	return false
}

error_at_current :: #force_inline proc(
	parser: ^Parser,
	message: string,
	error_type: Parser_Error_Type = .Syntax,
	expected: Token_Kind = .Invalid,
) {
	error_at(parser, parser.current_token, message, error_type, expected)
}

error_at :: proc(
	parser: ^Parser,
	token: Token,
	message: string,
	error_type: Parser_Error_Type = .Syntax,
	expected: Token_Kind = .Invalid,
) {
	if parser.panic_mode do return
	parser.panic_mode = true
	error := Parse_Error {
		type     = error_type,
		message  = message,
		span     = token.span,
		token    = token,
		expected = expected,
		found    = token.kind,
	}
	append(&parser.errors, error)
}

// synchronize is panic-mode recovery: after an error it skips tokens until it
// reaches a likely statement boundary (a separator, a `}`, or a binding operator),
// so one syntax error doesn't cascade into a flood. The offset/kind guard at the
// bottom is a safety net — if advance_token fails to make progress (a stuck
// token), it force-advances once so the loop can never spin forever.
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

// add_node appends one node to the SOA store and returns its index — the single
// constructor for every AST node. The three parallel arrays grow together.
add_node :: #force_inline proc(
	p: ^Parser,
	kind: Node_Kind,
	data: Node_Data,
	span: Span,
) -> Node_Index {
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

// add_extra flushes a batch of child indices (typically a scratch slice) into the
// shared `extra` array and returns the Index_Range a parent node stores to find them.
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

// --- entry points and the core expression loop ---

// parse is the top-level entry: it parses statements until EOF, gathering them as
// the children of a synthetic root ScopeNode (the file *is* a scope). The parsed
// arrays are sliced down to their used length into a freshly allocated Ast. The
// boolean reports whether parsing was error-free.
parse :: proc(cache: ^Cache, source: string) -> (^Ast, bool) {
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
	data.scope = {
		start = r.start,
		len   = r.len,
	}
	root_span := Span{span_start, parser.current_token.span.end}
	add_node(&parser, .ScopeNode, data, root_span)

	ast := new(Ast)
	ast.source = source
	ast.node_kinds = parser.node_kinds[:parser.node_count]
	ast.node_spans = parser.node_spans[:parser.node_count]
	ast.node_data = parser.node_data[:parser.node_count]
	ast.extra = parser.extra[:parser.extra_count]
	ast.extra_u8 = parser.extra_u8[:parser.extra_u8_count]

	cache.parse_errors = parser.errors

	if resolver.options.print_errors {
		for error in parser.errors {
			debug_parse_error(error, source, ast)
		}
	}

	return ast, len(parser.errors) == 0
}

debug_parse_error :: proc(error: Parse_Error, source: string, ast: ^Ast) {
	pos: Position
	if ast != nil {
		pos = span_to_position(ast, error.span.start)
	} else {
		temp_ast := Ast {
			source = source,
		}
		pos = span_to_position(&temp_ast, error.span.start)
	}
	fmt.eprintf("  [%v] at line %d, col %d: %s\n", error.type, pos.line, pos.column, error.message)
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

// The arithmetic/logical operators that may continue an expression across a soft
// separator. A line break before, say, `+` still means `a\n+ b`, but a line break
// before a binding `->` ends the statement — see the Separator_Before check in
// parse_expression. Only these few operators are allowed to "reach back".
is_infix_operator :: #force_inline proc(kind: Token_Kind) -> bool {
	#partial switch kind {
	case .Plus, .Minus, .Asterisk, .Slash, .Percent, .And, .Or:
		return true
	}
	return false
}

// The Pratt core. Parse a prefix, then fold infix operators while their binding
// power is ≥ `precedence`. Three guards shape Syntact-specific behavior:
//   * a separator before a non-arithmetic operator ends the expression (so a
//     newline terminates a binding but not `a\n+ b`);
//   * a `->` is not chained onto an existing Product/Pointing left (those forms
//     already consumed their right side);
//   * a glued `(` after a *named* identifier is left for a later rule, but a
//     glued `(` after an anonymous identifier breaks out (avoids a spurious call).
// A missing prefix handler skips the stray token and retries rather than aborting.
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
		if kind == .LeftParenNoSpace && parser.node_kinds[left] == .Identifier {
			left_data := parser.node_data[left].identifier
			if left_data.name == EMPTY_SPAN {
				break infix_loop
			}
		}
		left = infix(parser, left)
		if left == INVALID_NODE do return INVALID_NODE
	}
	return left
}

// --- parse handlers ---
//
// One handler per grammar form, registered in the prefix/infix tables. Prefix
// handlers run on the current token; infix handlers receive the already-parsed
// `left`. Most are mechanical (advance, build a Node_Data, add_node); the comments
// below flag the ones whose control flow encodes a real grammar decision.

// For a string literal the surrounding quotes are stripped from the span and the
// quotation kind is recovered from the opening byte (it drives ordinal vs
// positional semantics later). Other literals keep their span verbatim.
parse_literal :: proc(parser: ^Parser) -> Node_Index {
	span := parser.current_token.span
	data: Node_Data
	#partial switch parser.current_token.kind {
	case .Integer:
		data.literal = Literal_Data {
			kind = .Integer,
		}
	case .Float:
		data.literal = Literal_Data {
			kind = .Float,
		}
	case .Hexadecimal:
		data.literal = Literal_Data {
			kind = .Hexadecimal,
		}
	case .Binary:
		data.literal = Literal_Data {
			kind = .Binary,
		}
	case .String_Literal:
		quotation: String_Quotation
		switch parser.lexer.src[span.start] {
		case '"':
			quotation = .double
		case '`':
			quotation = .backtick
		case:
			quotation = .simple
		}
		data.literal = Literal_Data {
			kind      = .String,
			quotation = quotation,
		}
		span = Span{span.start + 1, span.end - 1}
	case .Bool_Literal:
		data.literal = Literal_Data {
			kind = .Bool,
		}
	case:
		error_at_current(parser, "Unknown literal type")
		return INVALID_NODE
	}
	advance_token(parser)
	return add_node(parser, .Literal, data, span)
}

// parse_identifier splits the lexer's combined `name#n` token back into a name
// span and an ordinal (the occurrence selector; -1 when absent), then optionally
// consumes a glued `(capture)`. The capture must be a single identifier in
// parens, matched by the current+peek lookahead.
parse_identifier :: proc(parser: ^Parser) -> Node_Index {
	span := parser.current_token.span
	name_span := span
	capture_span := EMPTY_SPAN
	ordinal: i16 = -1

	src := parser.lexer.src
	for i in span.start ..< span.end {
		if src[i] == '#' {
			name_span.end = i
			ord, ok := strconv.parse_int(string(src[i + 1:span.end]))
			if ok do ordinal = i16(ord)
			break
		}
	}

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
	data.identifier = Identifier_Data {
		name    = name_span,
		capture = capture_span,
		ordinal = ordinal,
	}
	full_span := Span{span.start, max(span.end, capture_span.end)}
	if capture_span != EMPTY_SPAN {
		full_span.end += 1
	}
	return add_node(parser, .Identifier, data, full_span)
}

// parse_scope parses a `{ … }` literal: statements collected via the scratch
// buffer until the closing `}`, flushed into `extra`. It recovers in place
// (synchronize on panic) so one bad statement doesn't abandon the whole scope.
parse_scope :: proc(parser: ^Parser) -> Node_Index {
	span_start := parser.current_token.span.start
	advance_token(parser)

	if parser.current_token.kind == .RightBrace {
		span_end := parser.current_token.span.end
		advance_token(parser)
		data: Node_Data
		data.scope = {
			start = 0,
			len   = 0,
		}
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
	data.scope = {
		start = r2.start,
		len   = r2.len,
	}
	return add_node(parser, .ScopeNode, data, Span{span_start, span_end})
}

// parse_carve handles the infix `left{ … }` (a LeftBraceCarve glued to `left`):
// the overrides inside the braces are parsed like a scope body, with `left` kept
// as the carve source.
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
	data.carve = Carve_Data {
		source   = left,
		children = add_extra(parser, children[:]),
	}
	return add_node(parser, .Carve, data, Span{span_start, span_end})
}

// parse_grouping handles a spaced `( … )`. A lone identifier in parens, `(x)`, is
// a capture (an identifier node with an empty name and `x` as the capture), not a
// grouping — checked first. Otherwise the parens just bracket a sub-expression
// and contribute no node of their own; `()` is empty → INVALID_NODE.
parse_grouping :: proc(parser: ^Parser) -> Node_Index {
	span_start := parser.current_token.span.start
	advance_token(parser)

	if parser.current_token.kind == .Identifier && parser.peek_token.kind == .RightParen {
		capture_span := parser.current_token.span
		advance_token(parser)
		span_end := parser.current_token.span.end
		advance_token(parser)
		data: Node_Data
		data.identifier = Identifier_Data {
			name    = EMPTY_SPAN,
			capture = capture_span,
		}
		return add_node(parser, .Identifier, data, Span{span_start, span_end})
	}

	if parser.current_token.kind == .RightParen {
		advance_token(parser)
		return INVALID_NODE
	}

	expr := parse_expression(parser)
	if expr == INVALID_NODE {
		error_at_current(parser, "Expected expression after '('")
		return INVALID_NODE
	}

	if !expect_token(parser, .RightParen) {
		return expr
	}

	return expr
}

// A leading `!` is overloaded. With no expression following it is a bare collapse
// (Execute with no target — collapse of the enclosing scope). Followed by an
// expression it is the compile-time marker on that operand (CompileTime node).
parse_execute_prefix :: proc(parser: ^Parser) -> Node_Index {
	span := parser.current_token.span
	advance_token(parser)

	if !IS_EXPRESSION_START[parser.current_token.kind] &&
	   parser.current_token.kind != .LeftBraceCarve {
		data: Node_Data
		data.execute = Execute_Data {
			target   = INVALID_NODE,
			wrappers = EMPTY_RANGE,
		}
		return add_node(parser, .Execute, data, span)
	}

	operand := parse_expression(parser, Precedence.CALL)
	data: Node_Data
	data.unary = Unary_Data {
		operand = operand,
	}
	return add_node(parser, .CompileTime, data, Span{span.start, parser.node_spans[operand].end})
}

parse_execute :: proc(parser: ^Parser, left: Node_Index) -> Node_Index {
	span := parser.current_token.span
	advance_token(parser)
	data: Node_Data
	data.execute = Execute_Data {
		target   = left,
		wrappers = EMPTY_RANGE,
	}
	return add_node(parser, .Execute, data, Span{parser.node_spans[left].start, span.end})
}

// A prefix `->` is the scope's production. With nothing after it (end of scope,
// EOF, or a separator) it is a bare Product (operand INVALID_NODE); otherwise it
// produces the following expression. A separator after `->` thus terminates it,
// matching how bindings end at a soft boundary.
parse_product_prefix :: proc(parser: ^Parser) -> Node_Index {
	span_start := parser.current_token.span.start
	advance_token(parser)

	if parser.current_token.kind == .RightBrace ||
	   parser.current_token.kind == .EOF ||
	   has_flag(parser.current_token, .Separator_Before) {
		data: Node_Data
		data.unary = Unary_Data {
			operand = INVALID_NODE,
		}
		return add_node(parser, .Product, data, Span{span_start, parser.current_token.span.start})
	}

	to := parse_expression(parser, .PATTERN)
	if to == INVALID_NODE do return INVALID_NODE

	data: Node_Data
	data.unary = Unary_Data {
		operand = to,
	}
	return add_node(parser, .Product, data, Span{span_start, parser.node_spans[to].end})
}

// The generic infix operator handler. It recurses at `prec + 1`, which makes
// every binary operator left-associative (`a - b - c` parses as `(a - b) - c`):
// the right operand only absorbs operators strictly tighter than this one. The
// switch maps the operator token to its Operator_Kind.
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
	case .Plus:
		op_kind = .Add
	case .Minus:
		op_kind = .Subtract
	case .Asterisk:
		op_kind = .Multiply
	case .Slash:
		op_kind = .Divide
	case .Percent:
		op_kind = .Mod
	case .And:
		op_kind = .And
	case .Or:
		op_kind = .Or
	case .Xor:
		op_kind = .Xor
	case .BitAnd:
		op_kind = .BitAnd
	case .BitOr:
		op_kind = .BitOr
	case .Equal:
		op_kind = .Equal
	case .NotEqual:
		op_kind = .NotEqual
	case .Less:
		op_kind = .Less
	case .Greater:
		op_kind = .Greater
	case .LessEqual:
		op_kind = .LessEqual
	case .GreaterEqual:
		op_kind = .GreaterEqual
	case .LShift:
		op_kind = .LShift
	case .RShift:
		op_kind = .RShift
	case .Cast:
		op_kind = .Cast
	case:
		error_at_current(parser, fmt.tprintf("Unhandled binary operator type: %v", token_kind))
		return INVALID_NODE
	}

	data: Node_Data
	data.operator = Operator_Node_Data {
		kind  = op_kind,
		left  = left,
		right = right,
	}
	return add_node(parser, .Operator, data, Span{span_start, parser.node_spans[right].end})
}

// Prefix `-`, `~`, `!` (logical not). Modeled as an Operator node with
// left == INVALID_NODE; recursing at UNARY level gives the standard
// "unary binds tighter than the binary forms" behavior.
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
	case .Minus:
		op_kind = .Subtract
	case .Not:
		op_kind = .Not
	case .BitNot:
		op_kind = .BitNot
	case:
		error_at_current(parser, "Unexpected unary operator")
		return INVALID_NODE
	}

	data: Node_Data
	data.operator = Operator_Node_Data {
		kind  = op_kind,
		left  = INVALID_NODE,
		right = operand,
	}
	return add_node(parser, .Operator, data, Span{span_start, parser.node_spans[operand].end})
}

// `left.name`. If no identifier follows (or one follows across a separator), it
// is a property access with a missing name (right == INVALID_NODE) — kept as a
// node so the analyzer can report it precisely rather than the parser guessing.
parse_property_access :: proc(parser: ^Parser, left: Node_Index) -> Node_Index {
	span_start := parser.node_spans[left].start
	dot_span_end := parser.current_token.span.end
	advance_token(parser)

	if parser.current_token.kind != .Identifier ||
	   has_flag(parser.current_token, .Separator_Before) {
		data: Node_Data
		data.binary = Binary_Data {
			left  = left,
			right = INVALID_NODE,
		}
		return add_node(parser, .Property, data, Span{span_start, dot_span_end})
	}

	prop_id := parse_identifier(parser)
	prop_span := parser.node_spans[prop_id]

	data: Node_Data
	data.binary = Binary_Data {
		left  = left,
		right = prop_id,
	}
	return add_node(parser, .Property, data, Span{span_start, prop_span.end})
}

// The half-open property forms the lexer already disambiguated: `.name` (prefix,
// source is none → PropertyFromNone) and `left.` (postfix → PropertyToNone, below).
// Both build a Property node with the missing side set to INVALID_NODE.
parse_property_from_none :: proc(parser: ^Parser) -> Node_Index {
	span_start := parser.current_token.span.start
	advance_token(parser)

	if parser.current_token.kind != .Identifier {
		error_at_current(parser, "Expected property name after '.'")
		return INVALID_NODE
	}

	prop_id := parse_identifier(parser)
	prop_span := parser.node_spans[prop_id]

	data: Node_Data
	data.binary = Binary_Data {
		left  = INVALID_NODE,
		right = prop_id,
	}
	return add_node(parser, .Property, data, Span{span_start, prop_span.end})
}

parse_property_to_none :: proc(parser: ^Parser, left: Node_Index) -> Node_Index {
	span_start := parser.node_spans[left].start
	advance_token(parser)

	data: Node_Data
	data.binary = Binary_Data {
		left  = left,
		right = INVALID_NODE,
	}
	return add_node(parser, .Property, data, Span{span_start, parser.current_token.span.start})
}

// The constraint-bind family `constraint : name`. The three variants
// (bind / from_none / to_none) differ only in which side is present, matching the
// lexer's whitespace-driven colon kinds. The name parses at just-above-CALL
// precedence so it stays a single tight operand and doesn't swallow following
// operators. A trailing `name{…}` is folded in as a carve on the constraint node,
// supporting `constraint : name{ overrides }`.
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
	} else if IS_EXPRESSION_START[parser.current_token.kind] {
		name = parse_expression(parser, Precedence(int(Precedence.CALL) + 1))
	}

	data: Node_Data
	data.binary = Binary_Data {
		left  = left,
		right = name,
	}
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
	} else if IS_EXPRESSION_START[parser.current_token.kind] {
		name = parse_expression(parser, Precedence(int(Precedence.CALL) + 1))
	}

	data: Node_Data
	data.binary = Binary_Data {
		left  = INVALID_NODE,
		right = name,
	}
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
	data.binary = Binary_Data {
		left  = left,
		right = INVALID_NODE,
	}
	node := add_node(parser, .Constraint, data, Span{span_start, parser.current_token.span.start})

	if parser.current_token.kind == .LeftBraceCarve {
		return parse_carve(parser, node)
	}
	return node
}

// Handlers for the ill-spaced `.`/`:` tokens (a space on only the wrong side).
// The lexer still emits a token so the parser can point at the exact spot and
// give an actionable message rather than a generic "unexpected token". The infix
// variants clear panic_mode and return `left` so recovery continues from there.
parse_invalid_property :: proc(parser: ^Parser) -> Node_Index {
	error_at_current(
		parser,
		"Invalid property syntax with spaces around '.' - use 'a.b', '.b', or 'a.'",
	)
	advance_token(parser)
	return INVALID_NODE
}

parse_invalid_property_infix :: proc(parser: ^Parser, left: Node_Index) -> Node_Index {
	error_at_current(
		parser,
		"Invalid property syntax with spaces around '.' - use 'a.b', '.b', or 'a.'",
	)
	advance_token(parser)
	parser.panic_mode = false
	return left
}

parse_invalid_constraint :: proc(parser: ^Parser) -> Node_Index {
	error_at_current(
		parser,
		"Invalid constraint syntax with spaces around ':' - use 'a:b', ':b', or 'a:'",
	)
	advance_token(parser)
	return INVALID_NODE
}

parse_invalid_constraint_infix :: proc(parser: ^Parser, left: Node_Index) -> Node_Index {
	error_at_current(
		parser,
		"Invalid constraint syntax with spaces around ':' - use 'a:b', ':b', or 'a:'",
	)
	advance_token(parser)
	parser.panic_mode = false
	return left
}

// The directional binding operators (pointing / event / resonance / reactive)
// all share this shape, repeated below in prefix and infix forms: optionally
// parse a right-hand value at ASSIGNMENT precedence, stopping at a scope end, EOF,
// or a separator (so `a ->\nb` does not pull `b` into the binding). The prefix
// form leaves `left` == INVALID_NODE (the push/pull has no left operand); the
// infix form uses the parsed `left`. Only the Node_Kind/data field differs per
// operator. The event-pull pair additionally captures an optional catch name.
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
	data.binary = Binary_Data {
		left  = left,
		right = to,
	}
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
	data.binary = Binary_Data {
		left  = INVALID_NODE,
		right = to,
	}
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
	data.binary = Binary_Data {
		left  = left,
		right = to,
	}
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
		to = parse_expression(parser, .ASSIGNMENT)
	}

	data: Node_Data
	data.binary = Binary_Data {
		left  = INVALID_NODE,
		right = to,
	}
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
		to = parse_expression(parser, .ASSIGNMENT)
	}

	data: Node_Data
	data.binary = Binary_Data {
		left  = left,
		right = to,
	}
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
	data.event_pull = EventPull_Data {
		from       = INVALID_NODE,
		to         = to,
		catch_span = catch_span,
	}
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
	data.event_pull = EventPull_Data {
		from       = left,
		to         = to,
		catch_span = catch_span,
	}
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
	data.binary = Binary_Data {
		left  = INVALID_NODE,
		right = to,
	}
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
		to = parse_expression(parser, .ASSIGNMENT)
	}

	data: Node_Data
	data.binary = Binary_Data {
		left  = left,
		right = to,
	}
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
	data.binary = Binary_Data {
		left  = INVALID_NODE,
		right = to,
	}
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
		to = parse_expression(parser, .ASSIGNMENT)
	}

	data: Node_Data
	data.binary = Binary_Data {
		left  = left,
		right = to,
	}
	span_end := parser.current_token.span.start
	if to != INVALID_NODE {
		span_end = parser.node_spans[to].end
	}
	return add_node(parser, .ResonancePull, data, Span{span_start, span_end})
}

parse_reactive_push_prefix :: proc(parser: ^Parser) -> Node_Index {
	span_start := parser.current_token.span.start
	advance_token(parser)

	to := INVALID_NODE
	if parser.current_token.kind != .RightBrace &&
	   parser.current_token.kind != .EOF &&
	   !has_flag(parser.current_token, .Separator_Before) {
		to = parse_expression(parser, Precedence(int(Precedence.ASSIGNMENT) + 1))
	}

	data: Node_Data
	data.binary = Binary_Data {
		left  = INVALID_NODE,
		right = to,
	}
	span_end := parser.current_token.span.start
	if to != INVALID_NODE {
		span_end = parser.node_spans[to].end
	}
	return add_node(parser, .ReactivePush, data, Span{span_start, span_end})
}

parse_reactive_push :: proc(parser: ^Parser, left: Node_Index) -> Node_Index {
	span_start := parser.node_spans[left].start
	advance_token(parser)

	to := INVALID_NODE
	if parser.current_token.kind != .RightBrace &&
	   parser.current_token.kind != .EOF &&
	   !has_flag(parser.current_token, .Separator_Before) {
		to = parse_expression(parser, .ASSIGNMENT)
	}

	data: Node_Data
	data.binary = Binary_Data {
		left  = left,
		right = to,
	}
	span_end := parser.current_token.span.start
	if to != INVALID_NODE {
		span_end = parser.node_spans[to].end
	}
	return add_node(parser, .ReactivePush, data, Span{span_start, span_end})
}

parse_reactive_pull_prefix :: proc(parser: ^Parser) -> Node_Index {
	span_start := parser.current_token.span.start
	advance_token(parser)

	to := INVALID_NODE
	if parser.current_token.kind != .RightBrace &&
	   parser.current_token.kind != .EOF &&
	   !has_flag(parser.current_token, .Separator_Before) {
		to = parse_expression(parser, Precedence(int(Precedence.ASSIGNMENT) + 1))
	}

	data: Node_Data
	data.binary = Binary_Data {
		left  = INVALID_NODE,
		right = to,
	}
	span_end := parser.current_token.span.start
	if to != INVALID_NODE {
		span_end = parser.node_spans[to].end
	}
	return add_node(parser, .ReactivePull, data, Span{span_start, span_end})
}

parse_reactive_pull :: proc(parser: ^Parser, left: Node_Index) -> Node_Index {
	span_start := parser.node_spans[left].start
	advance_token(parser)

	to := INVALID_NODE
	if parser.current_token.kind != .RightBrace &&
	   parser.current_token.kind != .EOF &&
	   !has_flag(parser.current_token, .Separator_Before) {
		to = parse_expression(parser, .ASSIGNMENT)
	}

	data: Node_Data
	data.binary = Binary_Data {
		left  = left,
		right = to,
	}
	span_end := parser.current_token.span.start
	if to != INVALID_NODE {
		span_end = parser.node_spans[to].end
	}
	return add_node(parser, .ReactivePull, data, Span{span_start, span_end})
}

// The range family, one handler per lexer range kind (the lexer already decided
// which bounds are present from the surrounding delimiters): `..` empty (both
// bounds open), `..hi` prefix, `lo..` postfix, `lo..hi` full. Every Range node
// uses INVALID_NODE for an absent bound — the analyzer reads that as "unbounded
// on that side", distinct from a bound whose value is none.
parse_empty_range :: proc(parser: ^Parser) -> Node_Index {
	span := parser.current_token.span
	advance_token(parser)
	data: Node_Data
	data.binary = Binary_Data {
		left  = INVALID_NODE,
		right = INVALID_NODE,
	}
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
	data.binary = Binary_Data {
		left  = INVALID_NODE,
		right = end,
	}
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
	data.binary = Binary_Data {
		left  = left,
		right = INVALID_NODE,
	}
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
	data.binary = Binary_Data {
		left  = left,
		right = end,
	}
	span_end := parser.current_token.span.start
	if end != INVALID_NODE {
		span_end = parser.node_spans[end].end
	}
	return add_node(parser, .Range, data, Span{span_start, span_end})
}

// A comparison operator used in prefix position (`>= 0`, `< 10`) — a constraint
// shorthand for "the set of values satisfying this comparison". Built as an
// Operator node with no left operand.
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
	case .Equal:
		op_kind = .Equal
	case .NotEqual:
		op_kind = .NotEqual
	case .Less:
		op_kind = .Less
	case .Greater:
		op_kind = .Greater
	case .LessEqual:
		op_kind = .LessEqual
	case .GreaterEqual:
		op_kind = .GreaterEqual
	case:
		error_at_current(parser, "Unexpected prefix comparison operator")
		return INVALID_NODE
	}

	data: Node_Data
	data.operator = Operator_Node_Data {
		kind  = op_kind,
		left  = INVALID_NODE,
		right = operand,
	}
	return add_node(parser, .Operator, data, Span{span_start, parser.node_spans[operand].end})
}

// `target ? …` has two shapes. Braced (`target ? { … }`) collects branches via
// parse_branch; inline (`target ? expr`) is sugar for a single branch. Both store
// branches as flat (source, product) pairs in `extra`, so the inline form pushes
// (expr, INVALID_NODE). The pair layout is what node_pattern_branches walks.
parse_pattern :: proc(parser: ^Parser, left: Node_Index) -> Node_Index {
	span_start := parser.node_spans[left].start
	advance_token(parser)

	cp := scratch_begin(&parser.scratch)
	defer scratch_reset(&parser.scratch, cp)

	if parser.current_token.kind == .LeftBrace {
		advance_token(parser)

		for parser.current_token.kind != .RightBrace && parser.current_token.kind != .EOF {
			source_idx, product_idx := parse_branch(parser)
			if source_idx != INVALID_NODE || product_idx != INVALID_NODE {
				scratch_append(&parser.scratch, source_idx)
				scratch_append(&parser.scratch, product_idx)
			}
		}

		if !match_token(parser, .RightBrace) {
			error_at_current(parser, "Expected } after pattern branches")
		}
	} else {
		inline_expr := INVALID_NODE
		if parser.current_token.kind == .LeftParenNoSpace {
			inline_expr = parse_grouping(parser)
		} else if IS_EXPRESSION_START[parser.current_token.kind] {
			inline_expr = parse_expression(parser, .OR)
		} else {
			error_at_current(parser, "Expected pattern expression after ?")
			return left
		}
		if inline_expr != INVALID_NODE {
			scratch_append(&parser.scratch, inline_expr)
			scratch_append(&parser.scratch, INVALID_NODE)
		}
	}

	branch_indices := scratch_end(&parser.scratch, cp)
	data: Node_Data
	data.pattern = Pattern_Data {
		target   = left,
		branches = add_extra(parser, branch_indices[:]),
	}
	span_end := parser.current_token.span.start
	return add_node(parser, .Pattern, data, Span{span_start, span_end})
}

// One pattern branch, returned as a (source, product) pair. A leading `->`
// branch has no source (the default/fallthrough). Otherwise the source is parsed,
// and a `-> product` is optional — a source with no product is a guard that
// produces nothing. A non-expression token is skipped to keep the branch loop moving.
parse_branch :: proc(parser: ^Parser) -> (source_idx: Node_Index, product_idx: Node_Index) {
	if !IS_EXPRESSION_START[parser.current_token.kind] {
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
		if !has_flag(parser.current_token, .Separator_Before) {
			product = parse_expression(parser, .ASSIGNMENT)
		}
	}

	return source, product
}

parse_enforce :: proc(parser: ^Parser, left: Node_Index) -> Node_Index {
	span_start := parser.node_spans[left].start
	token_kind := parser.current_token.kind
	prec := prec_table[token_kind]
	advance_token(parser)

	right := parse_expression(parser, prec)
	if right == INVALID_NODE {
		error_at_current(parser, "Expected expression after ?!")
		parser.panic_mode = false
		return left
	}

	data: Node_Data
	data.binary = Binary_Data {
		left  = left,
		right = right,
	}
	return add_node(parser, .Enforce, data, Span{span_start, parser.node_spans[right].end})
}

parse_unknown :: proc(parser: ^Parser) -> Node_Index {
	span := parser.current_token.span
	advance_token(parser)
	data: Node_Data
	return add_node(parser, .Unknown, data, span)
}

// `+expr` / `...expr` — the expand (extension) prefix. Parsed at CONSTRAINT
// precedence so it captures the constrained operand but not looser operators.
parse_expansion :: proc(parser: ^Parser) -> Node_Index {
	span_start := parser.current_token.span.start
	advance_token(parser)

	target := parse_expression(parser, .CONSTRAINT)
	if target == INVALID_NODE {
		error_at_current(parser, "Expected expression after ...")
		return INVALID_NODE
	}

	data: Node_Data
	data.unary = Unary_Data {
		operand = target,
	}
	return add_node(parser, .Expand, data, Span{span_start, parser.node_spans[target].end})
}

// `@name.a.b` — an external reference. The `@name` is the External node; any
// trailing `.a.b` is folded into a chain of Property nodes over it, so externals
// support member access just like ordinary values.
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
	data.external = External_Data {
		name  = name_span,
		scope = INVALID_NODE,
	}
	current := add_node(parser, .External, data, Span{span_start, name_span.end})

	for parser.current_token.kind == .Dot {
		advance_token(parser)
		if parser.current_token.kind != .Identifier {
			error_at_current(parser, "Expected identifier after '.'")
			break
		}

		prop_span := parser.current_token.span
		prop_data: Node_Data
		prop_data.identifier = Identifier_Data {
			name    = prop_span,
			capture = EMPTY_SPAN,
		}
		prop_id := add_node(parser, .Identifier, prop_data, prop_span)

		prop_node_data: Node_Data
		prop_node_data.binary = Binary_Data {
			left  = current,
			right = prop_id,
		}
		current = add_node(parser, .Property, prop_node_data, Span{span_start, prop_span.end})
		advance_token(parser)
	}

	process_filenode_flat(current, parser)

	return current
}

// `|`, `<`, `[`, `(` are each ambiguous: they may begin an execution-wrapper
// chain (`x<!>`, `x[!]`, `x|!|`, `x(!)`) or be their ordinary selves (bit-or,
// less-than, a bracket error, a grouping). Each handler speculatively tries the
// wrapped-execute parse first (which backtracks on failure) and falls back to the
// ordinary meaning if it isn't a wrapper.
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
	data.operator = Operator_Node_Data {
		kind  = .Less,
		left  = left,
		right = right,
	}
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
	error_at_current(
		parser,
		"Trying to use left bracket [ for something else than execution wrapper like [!]",
	)
	return INVALID_NODE
}

parse_left_paren :: proc(parser: ^Parser, left: Node_Index) -> Node_Index {
	if node, is_execution := try_parse_wrapped_execute(parser, left); is_execution {
		return node
	}
	parse_grouping(parser)
	return left
}

// Speculatively parse a wrapped collapse: `left` followed by nested execution-
// context brackets enclosing exactly one `!` (e.g. `left<[!]>` runs the collapse
// threaded then parallel). It is a small bracket-matching state machine: each
// opener pushes its kind and a wrapper code, each closer must match the top of
// the stack, and exactly one `!` must appear with the stack balanced. Any
// mismatch — wrong closer, depth overflow, no `!`, leftover open brackets — is
// not an error: we snapshot the lexer/token/node-count on entry and `restore` it,
// returning false so the caller falls back to the ordinary operator. Success
// emits one Execute node carrying the wrapper sequence. The snapshot of
// node_count matters because speculative parsing may have appended nodes that
// must be discarded on backtrack.
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
			if stack_len > 0 && stack[stack_len - 1] == Token_Kind.Or {
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
			if stack_len == 0 || stack[stack_len - 1] != Token_Kind.LeftParen {
				restore(parser, original_offset, original_current, original_peek, nodes_len)
				return INVALID_NODE, false
			}
			stack_len -= 1
			advance_token(parser)
		case .Greater:
			if stack_len == 0 || stack[stack_len - 1] != Token_Kind.Less {
				restore(parser, original_offset, original_current, original_peek, nodes_len)
				return INVALID_NODE, false
			}
			stack_len -= 1
			advance_token(parser)
		case .RightBracket:
			if stack_len == 0 || stack[stack_len - 1] != Token_Kind.LeftBracket {
				restore(parser, original_offset, original_current, original_peek, nodes_len)
				return INVALID_NODE, false
			}
			stack_len -= 1
			advance_token(parser)
		case:
			if !found_exclamation || stack_len > 0 {
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
	data.execute = Execute_Data {
		target   = left,
		wrappers = add_extra_u8(parser, wrappers[:wrappers_len]),
	}
	span := Span{parser.node_spans[left].start, parser.current_token.span.start}
	return add_node(parser, .Execute, data, span), true
}

// --- lookup tables ---

// The tokens that can begin an execution-wrapper chain — the openers
// try_parse_wrapped_execute speculates on.
IS_EXECUTION_PATTERN_START: [Token_Kind]bool = #partial {
	.Execute     = true,
	.LeftParen   = true,
	.Less        = true,
	.LeftBracket = true,
	.Or          = true,
}

// The tokens that can start an expression. Handlers consult this to decide
// whether an optional operand follows (e.g. `->` with vs. without a value) rather
// than each re-listing the set. Membership = "has a prefix handler or begins one".
IS_EXPRESSION_START: [Token_Kind]bool = #partial {
	.Identifier         = true,
	.Integer            = true,
	.Float              = true,
	.String_Literal     = true,
	.Bool_Literal       = true,
	.Hexadecimal        = true,
	.Binary             = true,
	.LeftBrace          = true,
	.LeftParen          = true,
	.LeftParenNoSpace   = true,
	.At                 = true,
	.Not                = true,
	.BitNot             = true,
	.Minus              = true,
	.PointingPull       = true,
	.EventPush          = true,
	.EventPull          = true,
	.ResonancePush      = true,
	.ResonancePull      = true,
	.ReactivePush       = true,
	.ReactivePull       = true,
	.DoubleDot          = true,
	.Question           = true,
	.Ellipsis           = true,
	.PointingPush       = true,
	.Equal              = true,
	.NotEqual           = true,
	.LessEqual          = true,
	.Less               = true,
	.Greater            = true,
	.GreaterEqual       = true,
	.Range              = true,
	.PostfixRange       = true,
	.PrefixRange        = true,
	.DoubleQuestion     = true,
	.Execute            = true,
	.ConstraintFromNone = true,
	.PropertyFromNone   = true,
}

// Byte-classification tables for the lexer, filled once at startup. The two delim
// tables encode the whitespace-sensitivity rules: IS_BEFORE_DELIM / IS_AFTER_DELIM
// mark bytes that cannot be part of an operand, which is how lex_dot tells `a.b`
// (property) from `a. `/`.b` without parser feedback. They are deliberately not
// identical — a `{` may precede an operand but a `}` may follow one.
IDENT_START: [256]bool
IDENT_CONTINUE: [256]bool
IS_SPACE: [256]bool
IS_BEFORE_DELIM: [256]bool
IS_AFTER_DELIM: [256]bool
IS_DIGIT: [256]bool
IS_HEX: [256]bool

@(init)
init_ident_tables :: proc "contextless" () {
	for c in u8('a') ..= u8('z') {IDENT_START[c] = true;IDENT_CONTINUE[c] = true}
	for c in u8('A') ..= u8('Z') {IDENT_START[c] = true;IDENT_CONTINUE[c] = true}
	IDENT_START['_'] = true
	IDENT_CONTINUE['_'] = true
	for c in u8('0') ..= u8('9') {IDENT_CONTINUE[c] = true}

	IS_SPACE[' '] = true;IS_SPACE['\t'] = true;IS_SPACE['\r'] = true

	IS_BEFORE_DELIM[' '] = true;IS_BEFORE_DELIM['\t'] = true;IS_BEFORE_DELIM['\r'] = true
	IS_BEFORE_DELIM['\n'] = true;IS_BEFORE_DELIM[':'] = true;IS_BEFORE_DELIM[','] = true
	IS_BEFORE_DELIM['{'] = true;IS_BEFORE_DELIM['('] = true

	IS_AFTER_DELIM[' '] = true;IS_AFTER_DELIM['\t'] = true;IS_AFTER_DELIM['\r'] = true
	IS_AFTER_DELIM['\n'] = true;IS_AFTER_DELIM['}'] = true;IS_AFTER_DELIM[')'] = true
	IS_AFTER_DELIM[','] = true;IS_AFTER_DELIM[':'] = true

	for c in u8('0') ..= u8('9') {IS_DIGIT[c] = true;IS_HEX[c] = true}
	for c in u8('a') ..= u8('f') {IS_HEX[c] = true}
	for c in u8('A') ..= u8('F') {IS_HEX[c] = true}
}


