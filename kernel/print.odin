package kernel

import syn "../compiler"
import "core:fmt"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"

// Printing of the IR in Syntact syntax, with only the parentheses that the
// parser's precedence requires: each writing also returns the level at which it
// binds. The same IR has two readings: the program, colors and values as
// written; and its types, color_type and value_type.

Level :: syn.Precedence

View :: enum u8 {
	Program,
	Type,
}

print_expr :: proc(e: ^Expr) -> string {
	s, _ := printed(e, .Program)
	return s
}

print_type :: proc(t: ^Expr) -> string {
	s, _ := printed(t, .Type)
	return s
}

// print_at: `e` at a place that binds at the level `level`, in parentheses if it
// binds more loosely.
print_at :: proc(e: ^Expr, level: Level, view := View.Program) -> string {
	s, own := printed(e, view)
	return wrap(s, own, level)
}

print_type_at :: proc(t: ^Expr, level: Level) -> string {
	return print_at(t, level, .Type)
}

wrap :: proc(s: string, own, level: Level) -> string {
	return own < level ? fmt.tprintf("(%s)", s) : s
}

above :: proc(level: Level) -> Level {
	return Level(int(level) + 1)
}

// brief: a type, in shortened writing, for an error message.
brief :: proc(t: ^Expr) -> string {
	s := print_type(t)
	if len(s) <= 120 do return s
	cut := 120
	for cut > 0 && !utf8.rune_start(s[cut]) do cut -= 1
	return fmt.tprintf("%s…", s[:cut])
}

printed :: proc(e: ^Expr, view: View) -> (string, Level) {
	if e == nil do return "<nil>", .PRIMARY
	switch v in e^ {
	case Set:
		return printed_set(v)
	case Poly:
		return printed_poly(v)
	case Term:
		return printed_term(v)
	case ^Var:
		return print_var(v), .CALL
	case Set_Form:
		return printed_set_form(v)
	case Cases:
		return printed_cases(v)
	case ^Scope:
		return print_scope(v, view), .PRIMARY
	case Ref:
		return v.name, .PRIMARY
	case Access:
		return fmt.tprintf("%s.%s", print_at(v.target, .CALL, view), v.name), .CALL
	case Collapse:
		return fmt.tprintf("%s!", print_at(v.target, .CALL, view)), .CALL
	case Carve:
		return fmt.tprintf("%s%s", print_at(v.target, .CALL, view), print_scope(v.args, .Program, v.ordinals)), .CALL
	case Carved:
		return printed(v.args.bindings[v.index].value, .Program) // the argument, as written
	case Inferred:
		return printed(v.type, .Program)
	case Carving:
		return "", .PRIMARY // `.x`: the source is the carved scope
	case Shorthand:
		if v.field.ordinal >= 0 do return fmt.tprintf("%s#%d", v.field.name, v.field.ordinal), .PRIMARY
		return v.field.name, .PRIMARY
	case Op:
		o := OPERATORS[v.kind]
		if v.left == nil do return fmt.tprintf("%s%s", o.text, print_at(v.right, .UNARY, view)), .UNARY
		return fmt.tprintf("%s %s %s", print_at(v.left, o.level, view), o.text, print_at(v.right, above(o.level), view)), o.level
	case Match:
		parts := make([dynamic]string, context.temp_allocator)
		for b in v.branches {
			product := print_at(b.bindings[0].value, .NONE, view)
			if b.cover == nil do append(&parts, fmt.tprintf("-> %s", product))
			else do append(&parts, fmt.tprintf("%s -> %s", print_at(b.cover, .NONE, view), product))
		}
		return fmt.tprintf("%s ? {{%s}}", print_at(v.target, .CALL, view), strings.join(parts[:], "  ")), .PATTERN
	case Range:
		lo := v.lo != nil ? print_at(v.lo, .CALL, view) : ""
		hi := v.hi != nil ? print_at(v.hi, .CALL, view) : ""
		return fmt.tprintf("%s..%s", lo, hi), .RANGE
	case Unknown:
		if v.layout == nil do return "??", .PRIMARY
		return fmt.tprintf("??::%s", print_at(v.layout, .CALL, view)), .CALL
	case Invalid:
		return "<invalid>", .PRIMARY
	}
	return "", .PRIMARY
}

Operator :: struct {
	text:  string,
	level: Level,
}

OPERATORS := [syn.Operator_Kind]Operator {
	.Add          = {"+", .TERM},
	.Subtract     = {"-", .TERM},
	.Multiply     = {"*", .FACTOR},
	.Divide       = {"/", .FACTOR},
	.Mod          = {"%", .FACTOR},
	.Equal        = {"=", .EQUALITY},
	.NotEqual     = {"!=", .EQUALITY},
	.Less         = {"<", .COMPARISON},
	.Greater      = {">", .COMPARISON},
	.LessEqual    = {"<=", .COMPARISON},
	.GreaterEqual = {">=", .COMPARISON},
	.And          = {"&", .AND},
	.Or           = {"|", .OR},
	.Xor          = {"^", .AND},
	.Not          = {"~", .UNARY},
	.BitAnd       = {"[&]", .AND},
	.BitOr        = {"[|]", .OR},
	.BitNot       = {"[~]", .UNARY},
	.RShift       = {">>", .SHIFT},
	.LShift       = {"<<", .SHIFT},
	.Cast         = {"\\", .CAST},
	.Layout       = {"::", .CALL},
}

ARROWS := [Binding_Kind]string {
	.Push           = "->",
	.Pull           = "<-",
	.Product        = "->",
	.Expand         = "...",
	.Event_Push     = ">-",
	.Event_Pull     = "-<",
	.Resonance_Push = ">>-",
	.Resonance_Pull = "-<<",
	.Reactive_Push  = ">>=",
	.Reactive_Pull  = "=<<",
}

// print_scope: a scope, read as a program or as a type. A color is the left
// operand of `:`: it must bind tighter than it. `ordinals`: for the arguments of
// a carve, the occurrence each one aims at (`x#1`).
print_scope :: proc(s: ^Scope, view: View, ordinals: []int = nil) -> string {
	b := strings.builder_make()
	strings.write_byte(&b, '{')
	shown := make([dynamic]Binding, context.temp_allocator)
	if view == .Type do presented(s, &shown) // the scope as it presents itself
	else do append(&shown, ..s.bindings[:])
	for bd, i in shown {
		if i > 0 do strings.write_string(&b, "  ")
		write_binding(&b, bd, view, i < len(ordinals) ? ordinals[i] : -1)
	}
	strings.write_byte(&b, '}')
	return strings.to_string(b)
}

// print_binding: a lone binding, read as a program or as a type.
print_binding :: proc(bd: Binding, view: View) -> string {
	b := strings.builder_make()
	write_binding(&b, bd, view, -1)
	return strings.to_string(b)
}

// write_binding: `ordinal`, the occurrence a carve argument aims at (`x#1`); -1
// otherwise.
write_binding :: proc(b: ^strings.Builder, bd: Binding, view: View, ordinal: int) {
	color, value := bd.color, bd.value
	at := view
	if view == .Type do color, value = bd.color_type, bd.value_type
	if bd.kind == .Expand {
		// `...xs`, `...C:(t)`, `...`: the expansion, then what it deposits
		strings.write_string(b, ARROWS[.Expand])
		if bd.color != nil {
			if !is_all_scopes(bd.color) do fmt.sbprintf(b, "%s:", print_at(bd.color, above(.CONSTRAINT), view))
			if bd.name != "" do strings.write_string(b, bd.name)
			if bd.capture != "" do fmt.sbprintf(b, "(%s)", bd.capture)
		} else if value != nil {
			strings.write_string(b, print_at(value, .NONE, view))
		}
		return
	}
	if bd.kind == .Product && color != nil {
		// `-> C:`, or `-> C:(v)`: a colored production
		fmt.sbprintf(b, "%s %s:", ARROWS[.Product], print_at(color, above(.CONSTRAINT), at))
		if value != nil do fmt.sbprintf(b, "(%s)", print_at(value, .NONE, at))
		return
	}
	if color != nil do fmt.sbprintf(b, "%s:", print_at(color, above(.CONSTRAINT), at))
	if bd.name != "" do strings.write_string(b, bd.name)
	if ordinal >= 0 do fmt.sbprintf(b, "#%d", ordinal)
	if bd.capture != "" do fmt.sbprintf(b, "(%s)", bd.capture)
	if value != nil {
		if bd.name != "" || color != nil || bd.kind != .Push {
			if bd.name != "" || color != nil do strings.write_byte(b, ' ')
			fmt.sbprintf(b, "%s ", ARROWS[bd.kind])
		}
		strings.write_string(b, print_at(value, .NONE, at))
	}
}

// print_var: a variable — `??0` for a `??`, the equation as written for a
// self-reference.
print_var :: proc(v: ^Var) -> string {
	if _, solved := v.type^.(Set); solved do return fmt.tprintf("??%d", v.id)
	if derived(v) do return print_type_at(v.type, .CALL) // the operation, in parentheses if needed
	return print_equation(v.type)
}

// print_equation: the type of a self-reference, never unfolded — the scope by the
// name that defines it, its arguments, its collapse.
print_equation :: proc(t: ^Expr) -> string {
	#partial switch v in t^ {
	case Collapse:
		return fmt.tprintf("%s!", print_equation(v.target))
	case Carve:
		return fmt.tprintf("%s%s", print_equation(v.target), print_scope(v.args, .Program, v.ordinals))
	case ^Scope:
		return name_of(v)
	}
	return print_expr(t)
}

// name_of: the name of the binding that defines the scope s — written, or copied
// (a copy keeps the span of what it copies).
name_of :: proc(s: ^Scope) -> string {
	for sc := s.parent; sc != nil; sc = sc.parent {
		for b in sc.bindings {
			if v, literal := scope_literal(b.value); literal && v.span == s.span && b.name != "" do return b.name
		}
	}
	return "{…}"
}

// --- sets ---

print_set :: proc(s: Set) -> string {
	text, _ := printed_set(s)
	return text
}

// printed_set: one component per sort, joined by `|`.
printed_set :: proc(s: Set) -> (string, Level) {
	Part :: struct {
		text:  string,
		level: Level,
	}
	parts := make([dynamic]Part)
	if ints_subset(ints_all(), s.ints) {
		append(&parts, Part{"int", .PRIMARY})
	} else {
		for iv in s.ints.intervals {
			text, level := printed_int_interval(iv)
			append(&parts, Part{text, level})
		}
	}
	if floats_subset(floats_all(), s.floats) {
		append(&parts, Part{"float", .PRIMARY})
	} else {
		for iv in s.floats.intervals {
			text, level := printed_float_interval(iv)
			append(&parts, Part{text, level})
		}
	}
	if ints_subset(chars_all(), s.chars) {
		append(&parts, Part{"char", .PRIMARY})
	} else {
		for iv in s.chars.intervals do append(&parts, Part{print_char_interval(iv), .RANGE})
	}
	if domain_count(s, .Strings) > 0 {
		text, level := printed_strings(s.strings)
		append(&parts, Part{text, level})
	}
	switch s.bools {
	case {.False, .True}:
		append(&parts, Part{"bool", .PRIMARY})
	case {.True}:
		append(&parts, Part{"true", .PRIMARY})
	case {.False}:
		append(&parts, Part{"false", .PRIMARY})
	}
	if domain_count(s, .Scopes) > 0 {
		text, level := printed_bdd(s.scopes)
		append(&parts, Part{text, level})
	}
	if domain_count(s, .Sets) > 0 {
		text, level := printed_values(s.sets)
		append(&parts, Part{text, level})
	}
	// a sort carried but empty: "no integer", etc.
	for d in s.sorts do if domain_count(s, d) == 0 do append(&parts, Part{fmt.tprintf("~%s", SORT_NAMES[d]), .UNARY})
	switch len(parts) {
	case 0:
		return "none", .PRIMARY
	case 1:
		return parts[0].text, parts[0].level
	}
	texts := make([]string, len(parts))
	for p, i in parts do texts[i] = wrap(p.text, p.level, above(.OR))
	return strings.join(texts, " | "), .OR
}

SORT_NAMES := [Domain]string {
	.Ints    = "int",
	.Floats  = "float",
	.Chars   = "char",
	.Strings = "string",
	.Bools   = "bool",
	.Scopes  = "scope",
	.Sets    = "set",
}

// printed_values: the sets admitted as values, `{-> u8  -> i8}`; their
// complement, `~{-> u8}`; all of them, `set`.
printed_values :: proc(a: Set_Values) -> (string, Level) {
	if len(a.values) == 0 do return "set", .PRIMARY
	b := strings.builder_make()
	strings.write_byte(&b, '{')
	for v, i in a.values {
		if i > 0 do strings.write_string(&b, "  ")
		fmt.sbprintf(&b, "-> %s", print_set(v))
	}
	strings.write_byte(&b, '}')
	if a.cofinite do return fmt.tprintf("~%s", strings.to_string(b)), .UNARY
	return strings.to_string(b), .PRIMARY
}

print_ints :: proc(a: Ints) -> string {
	if len(a.intervals) == 0 do return "none"
	texts := make([]string, len(a.intervals))
	for iv, i in a.intervals {
		text, level := printed_int_interval(iv)
		texts[i] = len(a.intervals) > 1 ? wrap(text, level, above(.OR)) : text
	}
	return strings.join(texts, " | ")
}

printed_int_interval :: proc(iv: Int_Interval) -> (string, Level) {
	lo, lo_ok := iv.lo.?
	hi, hi_ok := iv.hi.?
	switch {
	case lo_ok && hi_ok && lo == hi:
		return fmt.tprintf("%d", lo), lo < 0 ? .UNARY : .PRIMARY
	case lo_ok && hi_ok:
		return fmt.tprintf("%d..%d", lo, hi), .RANGE
	case lo_ok:
		return fmt.tprintf("%d..", lo), .RANGE
	case hi_ok:
		return fmt.tprintf("..%d", hi), .RANGE
	}
	return "int", .PRIMARY
}

// A closed bound is written in the range (`0.5..1.0`); an open bound, by a
// half-line (`>0.5 & <1.0`).
printed_float_interval :: proc(iv: Float_Interval) -> (string, Level) {
	lo, lo_ok := iv.lo.?
	hi, hi_ok := iv.hi.?
	if lo_ok && hi_ok && lo == hi do return print_float(lo), lo < 0 ? .UNARY : .PRIMARY
	if !iv.lo_open && !iv.hi_open {
		return fmt.tprintf("%s..%s", lo_ok ? print_float(lo) : "", hi_ok ? print_float(hi) : ""), .RANGE
	}
	lower, upper: string
	if lo_ok do lower = fmt.tprintf("%s%s", iv.lo_open ? ">" : ">=", print_float(lo))
	if hi_ok do upper = fmt.tprintf("%s%s", iv.hi_open ? "<" : "<=", print_float(hi))
	if lower == "" do return upper, .COMPARISON
	if upper == "" do return lower, .COMPARISON
	return fmt.tprintf("%s & %s", lower, upper), .AND
}

// print_float: the shortest decimal writing that reads back the same value,
// without exponent (Syntact does not read one), always with a point so as not to
// read it as an integer.
print_float :: proc(v: f64) -> string {
	s := fmt.tprintf("%v", v)
	sign := ""
	if strings.has_prefix(s, "-") {
		sign = "-"
		s = s[1:]
	}
	if !strings.contains_any(s[:1], "0123456789") do return fmt.tprintf("%s%s", sign, s) // inf, nan
	mantissa, exponent := s, 0
	if i := strings.index_any(s, "eE"); i >= 0 {
		mantissa = s[:i]
		exponent, _ = strconv.parse_int(s[i + 1:])
	}
	whole, _, frac := strings.partition(mantissa, ".")
	digits := strings.concatenate({whole, frac})
	point := len(whole) + exponent
	switch {
	case point <= 0:
		whole, frac = "0", strings.concatenate({strings.repeat("0", -point), digits})
	case point >= len(digits):
		whole, frac = strings.concatenate({digits, strings.repeat("0", point - len(digits))}), ""
	case:
		whole, frac = digits[:point], digits[point:]
	}
	whole = strings.trim_left(whole, "0")
	frac = strings.trim_right(frac, "0")
	if whole == "" do whole = "0"
	if frac == "" do frac = "0"
	return fmt.tprintf("%s%s.%s", sign, whole, frac)
}

// A range of characters that touches an end is written open on that side:
// `'d'..` goes up to the last character, `..'c'` starts from the empty character.
print_char_interval :: proc(iv: Int_Interval) -> string {
	lo, _ := iv.lo.?
	hi, _ := iv.hi.?
	if lo == hi do return print_char(lo)
	return fmt.tprintf("%s..%s", lo == CHAR_EMPTY ? "" : print_char(lo), hi == i128(MAX_RUNE) ? "" : print_char(hi))
}

print_char_range :: proc(r: Rune_Range) -> string {
	return print_char_interval(Int_Interval{i128(r.lo), i128(r.hi)})
}

print_char :: proc(c: i128) -> string {
	if c == CHAR_EMPTY do return "''"
	return quote_text(fmt.tprintf("%c", rune(c)), '\'')
}

// quote_text: a text between delimiters, with only the escapes that Syntact reads
// (\n \t \r \0, and the escape of the delimiter and of \).
quote_text :: proc(text: string, quote: byte) -> string {
	b := strings.builder_make()
	strings.write_byte(&b, quote)
	for r in text {
		switch r {
		case '\n':
			strings.write_string(&b, "\\n")
		case '\t':
			strings.write_string(&b, "\\t")
		case '\r':
			strings.write_string(&b, "\\r")
		case 0:
			strings.write_string(&b, "\\0")
		case '\\':
			strings.write_string(&b, "\\\\")
		case:
			if r == rune(quote) do strings.write_byte(&b, '\\')
			strings.write_rune(&b, r)
		}
	}
	strings.write_byte(&b, quote)
	return strings.to_string(b)
}

// --- strings ---

print_strings :: proc(a: Strings) -> string {
	text, _ := printed_strings(a)
	return text
}

printed_strings :: proc(a: Strings) -> (string, Level) {
	b := strings.builder_make()
	level := write_regex(&b, a.re, textual = false)
	return strings.to_string(b), level
}

// write_regex writes `re` and returns the level at which the writing binds.
// `textual`: the place already reads a character as a string (in `+`, left of
// `*`); elsewhere, a lone range of characters would read as characters, and is
// written concatenated to the empty word.
write_regex :: proc(b: ^strings.Builder, re: ^Regex, textual: bool) -> Level {
	if re == nil {
		strings.write_string(b, "none")
		return .PRIMARY
	}
	sub :: proc(b: ^strings.Builder, re: ^Regex, level: Level, textual: bool) {
		inner := strings.builder_make()
		own := write_regex(&inner, re, textual)
		strings.write_string(b, wrap(strings.to_string(inner), own, level))
	}
	switch re.kind {
	case .Words:
		for w, i in re.words {
			if i > 0 do strings.write_string(b, " | ")
			strings.write_string(b, quote_text(w, '"'))
		}
		return len(re.words) > 1 ? .OR : .PRIMARY
	case .Class:
		if textual {
			strings.write_string(b, print_char_range(re.class))
			return .RANGE
		}
		fmt.sbprintf(b, "\"\" + %s", print_char_range(re.class))
		return .TERM
	case .Cat:
		// right-associated: the sequence of its parts is written
		for part, first := re, true; part != nil; first = false {
			if !first do strings.write_string(b, " + ")
			head := part.parts[0] if part.kind == .Cat else part
			sub(b, head, above(.TERM), textual = true)
			part = part.parts[1] if part.kind == .Cat else nil
		}
		return .TERM
	case .Alt, .And:
		level := re.kind == .Alt ? Level.OR : Level.AND
		parts := slice.clone(re.parts, context.temp_allocator)
		slice.sort_by(parts, proc(x, y: ^Regex) -> bool {return x.kind == .Words && y.kind != .Words}) // the words first
		for p, i in parts {
			if i > 0 do strings.write_string(b, re.kind == .Alt ? " | " : " & ")
			sub(b, p, above(level), textual = false)
		}
		return level
	case .Not:
		if re.parts[0] == nil {
			strings.write_string(b, "string")
			return .PRIMARY
		}
		strings.write_byte(b, '~')
		sub(b, re.parts[0], .UNARY, textual = false)
		return .UNARY
	case .Repeat:
		sub(b, re.parts[0], .FACTOR, textual = true)
		counts := print_ints(re.counts)
		fmt.sbprintf(b, " * %s", len(re.counts.intervals) > 1 ? fmt.tprintf("(%s)", counts) : counts)
		return .FACTOR
	}
	return .PRIMARY
}

// is_all_scopes: the color of `...` alone, all scopes.
is_all_scopes :: proc(e: ^Expr) -> bool {
	s, ok := e^.(Set)
	return ok && s.sorts == {.Scopes} && is_leaf(s.scopes, .Top)
}

// presented: the bindings a scope presents, for the printing of its type. An
// expansion of a value deposits its bindings; a colored expansion stays a
// sequence, `...C:` — what it deposits is not a value.
presented :: proc(s: ^Scope, out: ^[dynamic]Binding) {
	for b in s.bindings {
		if b.kind == .Expand && b.color == nil {
			if v, ok := expanded(b); ok do presented(v, out)
			continue
		}
		append(out, b)
	}
}
