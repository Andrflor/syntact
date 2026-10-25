package kernel

import "core:fmt"
import "core:strings"
import "core:unicode"

// PRINTING
//
// A term as the language writes it: `0..255`, `?0 + 3`, `"jwt" + string`.

print_type :: proc(t: Type) -> string {
	b := strings.builder_make(context.temp_allocator)
	write_type(&b, t, 0)
	return strings.to_string(b)
}

print_types :: proc(ts: []Type) -> string {
	parts := make([dynamic]string, context.temp_allocator)
	for t in ts do append(&parts, print_type(t))
	return strings.join(parts[:], ", ", context.temp_allocator)
}


PREC_OR :: 1
PREC_AND :: 2
PREC_COMPARE :: 3
PREC_SHIFT :: 4
PREC_ADD :: 5
PREC_MUL :: 6
PREC_PREFIX :: 7
PREC_ATOM :: 9

operator_text := [Operator]string {
	.Add        = "+",
	.Sub        = "-",
	.Mul        = "*",
	.Div        = "/",
	.Mod        = "%",
	.Neg        = "-",
	.Bit_And    = "[&]",
	.Bit_Or     = "[|]",
	.Xor        = "^",
	.Bit_Not    = "[~]",
	.Shl        = "<<",
	.Shr        = ">>",
	.Less       = "<",
	.Less_Eq    = "<=",
	.Greater    = ">",
	.Greater_Eq = ">=",
	.In         = "in",
}

operator_prec :: proc(op: Operator) -> int {
	switch op {
	case .Add, .Sub:
		return PREC_ADD
	case .Mul, .Div, .Mod:
		return PREC_MUL
	case .Shl, .Shr:
		return PREC_SHIFT
	case .Neg, .Bit_Not:
		return PREC_PREFIX
	case .Bit_And, .Bit_Or, .Xor, .Less, .Less_Eq, .Greater, .Greater_Eq, .In:
		return PREC_COMPARE
	}
	return PREC_ATOM
}

write_type :: proc(b: ^strings.Builder, t: Type, outer: int) {
	prec := type_prec(t)
	if prec < outer do strings.write_byte(b, '(')
	write_bare(b, t)
	if prec < outer do strings.write_byte(b, ')')
}

type_prec :: proc(t: Type) -> int {
	#partial switch v in t {
	case ^Or:
		return PREC_OR
	case ^And:
		if _, ok := bound_of(v); ok do return PREC_PREFIX
		return PREC_AND
	case ^Not, ^Is:
		return PREC_PREFIX
	case ^Operation:
		if is_string_value(t) || is_string_term(t) do return PREC_ATOM
		if len(v.args) == 0 do return PREC_ATOM
		return operator_prec(v.op)
	case ^Pattern:
		return PREC_OR
	case ^Range:
		if v.lo != nil || v.hi != nil do return PREC_COMPARE
	case Int:
		if v < 0 do return PREC_PREFIX
	case Real:
		if v.num < 0 do return PREC_PREFIX
	}
	return PREC_ATOM
}

// bound_of: `t.. & ~t` is `>t`, `..t & ~t` is `<t` (§4.3).
bound_of :: proc(a: ^And) -> (string, bool) {
	if len(a.terms) != 2 do return "", false
	r, is_range := a.terms[0].(^Range)
	n, is_not := a.terms[1].(^Not)
	if !is_range || !is_not do return "", false
	if r.hi == nil && r.lo != nil && same_primitive(r.lo, n.term) do return fmt.tprintf(">%s", print_type(r.lo)), true
	if r.lo == nil && r.hi != nil && same_primitive(r.hi, n.term) do return fmt.tprintf("<%s", print_type(r.hi)), true
	return "", false
}

same_primitive :: proc(a, b: Type) -> bool {
	#partial switch x in a {
	case Int:
		y, ok := b.(Int)
		return ok && x == y
	case Real:
		y, ok := b.(Real)
		return ok && x == y
	case Char:
		y, ok := b.(Char)
		return ok && x == y
	}
	return false
}

is_string_term :: proc(t: Type) -> bool {
	o, ok := t.(^Operation)
	if !ok || o.op != .Mul || len(o.args) != 2 do return false
	c, is_range := o.args[0].(^Range)
	n, is_count := o.args[1].(^Range)
	if !is_range || !is_count do return false
	lo, is_char := c.lo.(Char)
	from, is_int := n.lo.(Int)
	return is_char && lo == 0 && c.hi == nil && is_int && from == 0 && n.hi == nil
}

write_bare :: proc(b: ^strings.Builder, t: Type) {
	if t == nil {
		strings.write_string(b, "nil")
		return
	}
	switch v in t {
	case Char:
		write_char(b, rune(v), '\'')
	case Int:
		fmt.sbprintf(b, "%v", i128(v))
	case Real:
		write_real(b, v)
	case Bool:
		strings.write_string(b, bool(v) ? "true" : "false")
	case None:
		strings.write_string(b, "none")
	case Invalid:
		strings.write_string(b, "<invalid>")
	case ^Unknown:
		fmt.sbprintf(b, "?%d", v.id)
		if v.instance != nil do write_changes(b, v.instance) // ?ₖ read in a carve
	case ^Or:
		for x, i in v.terms {
			if i > 0 do strings.write_string(b, " | ")
			write_type(b, x, lattice_operand(x, PREC_OR))
		}
	case ^And:
		if text, ok := bound_of(v); ok {
			strings.write_string(b, text)
			return
		}
		for x, i in v.terms {
			if i > 0 do strings.write_string(b, " & ")
			write_type(b, x, lattice_operand(x, PREC_AND))
		}
	case ^Not:
		strings.write_byte(b, '~')
		write_type(b, v.term, PREC_PREFIX)
	case ^Is:
		strings.write_byte(b, '=')
		write_type(b, v.term, PREC_PREFIX)
	case ^Range:
		write_range(b, v)
	case ^Operation:
		write_operation(b, v)
	case ^Name:
		strings.write_string(b, v.binding.name)
	case ^Scope:
		write_scope(b, v)
	case ^Access:
		write_type(b, v.target, PREC_ATOM)
		fmt.sbprintf(b, ".%s", v.name)
		if v.ordinal >= 0 do fmt.sbprintf(b, "#%d", v.ordinal)
	case ^Collapse:
		write_type(b, v.target, PREC_ATOM)
		strings.write_byte(b, '!')
	case ^Carve:
		write_type(b, v.target, PREC_ATOM)
		strings.write_byte(b, '{')
		for a, i in v.args {
			if i > 0 do strings.write_string(b, "  ")
			if a.name != "" do fmt.sbprintf(b, "%s -> ", a.name)
			write_type(b, a.value, 0)
		}
		strings.write_byte(b, '}')
	case ^Default:
		write_type(b, v.color, PREC_ATOM)
		strings.write_byte(b, ':')
	case ^Pattern:
		write_type(b, v.target, PREC_PREFIX)
		strings.write_string(b, " ? {")
		for br, i in v.branches {
			if i > 0 do strings.write_string(b, "  ")
			if br.cover != nil {
				write_type(b, br.cover, 0)
				strings.write_byte(b, ' ')
			}
			strings.write_string(b, "-> ")
			write_type(b, br.product, 0)
		}
		strings.write_byte(b, '}')
	}
}

// lattice_operand: an operation inside | or & is written between parentheses.
lattice_operand :: proc(t: Type, prec: int) -> int {
	#partial switch _ in t {
	case ^Operation:
		return PREC_PREFIX
	case ^Range:
		return PREC_COMPARE
	}
	return prec + 1
}

write_char :: proc(b: ^strings.Builder, c: rune, quote: byte) {
	if quote != 0 do strings.write_byte(b, quote)
	switch c {
	case 0:
		strings.write_string(b, "\\0")
	case '\n':
		strings.write_string(b, "\\n")
	case '\t':
		strings.write_string(b, "\\t")
	case '\r':
		strings.write_string(b, "\\r")
	case '\\':
		strings.write_string(b, "\\\\")
	case:
		if c == rune(quote) do strings.write_byte(b, '\\')
		// a character that does not print is shown by its code
		if unicode.is_print(c) do strings.write_rune(b, c)
		else if c <= 0xff do fmt.sbprintf(b, "\\x%02x", c)
		else do fmt.sbprintf(b, "\\u{%x}", c)
	}
	if quote != 0 do strings.write_byte(b, quote)
}


write_range :: proc(b: ^strings.Builder, r: ^Range) {
	if r.lo == nil && r.hi == nil {
		switch r.family {
		case .Int:
			strings.write_string(b, "int")
		case .Real:
			strings.write_string(b, "float")
		case .Any:
			strings.write_string(b, "..")
		}
		return
	}
	if c, is_char := r.lo.(Char); is_char && c == 0 {
		strings.write_string(b, "''") // from the smallest character
	} else if r.lo != nil {
		write_type(b, r.lo, PREC_ATOM)
	}
	strings.write_string(b, "..")
	if r.hi != nil do write_type(b, r.hi, PREC_ATOM)
}

write_operation :: proc(b: ^strings.Builder, o: ^Operation) {
	if is_string_value(o) {
		if len(o.args) == 0 {
			strings.write_string(b, `""`)
			return
		}
		strings.write_byte(b, '"')
		for a in o.args do write_char(b, rune(a.(Char)), 0)
		strings.write_byte(b, '"')
		return
	}
	if is_string_term(o) {
		strings.write_string(b, "string")
		return
	}
	prec := operator_prec(o.op)
	if o.op == .Neg || o.op == .Bit_Not {
		strings.write_string(b, operator_text[o.op])
		write_type(b, o.args[0], PREC_PREFIX)
		return
	}
	for a, i in o.args {
		if i > 0 do fmt.sbprintf(b, " %s ", operator_text[o.op])
		write_type(b, a, i == 0 ? prec : prec + 1)
	}
}

write_scope :: proc(b: ^strings.Builder, s: ^Scope) {
	if s.carved != nil {
		write_scope(b, s.carved)
		write_changes(b, s)
		return
	}
	if s.source != nil && s.source != s {
		write_scope(b, s.source)
		return
	}
	if s.name != "" {
		strings.write_string(b, s.name)
		return
	}
	write_body(b, s)
}

// write_body: the bindings of a scope, as written.
write_body :: proc(b: ^strings.Builder, s: ^Scope) {
	strings.write_byte(b, '{')
	for x, i in s.bindings {
		if i > 0 do strings.write_string(b, "  ")
		write_binding(b, x)
	}
	strings.write_byte(b, '}')
}

// print_binding: a binding with the normal forms of its color and its value,
// `C:x -> v`, or `C:x` when no value is written; the scope it gives, unless a
// carve, written out with the normal forms of its bindings.
print_binding :: proc(k: ^Kernel, x: ^Binding) -> string {
	b := strings.builder_make(context.temp_allocator)
	write_typed(&b, k, x, true)
	return strings.to_string(b)
}

write_typed :: proc(b: ^strings.Builder, k: ^Kernel, x: ^Binding, expand: bool) {
	switch x.kind {
	case .Product:
		strings.write_string(b, "-> ")
	case .Expand:
		strings.write_string(b, "...")
	case .Push, .Pull:
	}
	if c := binding_color(k, x); c != nil {
		write_type(b, c, PREC_ATOM)
		strings.write_byte(b, ':')
	}
	strings.write_string(b, x.name)
	if x.capture != "" do fmt.sbprintf(b, "(%s)", x.capture)
	if x.value == nil do return
	v := binding_type(k, x)
	if x.kind != .Product && x.kind != .Expand && (x.name != "" || x.color != nil) {
		strings.write_string(b, x.kind == .Pull ? " <- " : " -> ")
	}
	s, is_scope := v.(^Scope)
	if !expand || !is_scope || s.carved != nil {
		write_type(b, v, 0)
		return
	}
	strings.write_byte(b, '{')
	for inner, i in s.bindings {
		if i > 0 do strings.write_string(b, "  ")
		write_typed(b, k, inner, false)
	}
	strings.write_byte(b, '}')
}

// write_changes: the arguments of a carve, {x -> v …}.
write_changes :: proc(b: ^strings.Builder, s: ^Scope) {
	strings.write_byte(b, '{')
	first := true
	for x in s.carved.bindings {
		v, carved := s.changes[x]
		if !carved do continue
		if !first do strings.write_string(b, "  ")
		first = false
		if x.name != "" do fmt.sbprintf(b, "%s -> ", x.name)
		write_type(b, v, 0)
	}
	strings.write_byte(b, '}')
}

write_binding :: proc(b: ^strings.Builder, x: ^Binding) {
	switch x.kind {
	case .Product:
		strings.write_string(b, "-> ")
	case .Expand:
		strings.write_string(b, "...")
	case .Push, .Pull:
	}
	if x.color != nil {
		write_type(b, x.color, PREC_ATOM)
		strings.write_byte(b, ':')
	}
	strings.write_string(b, x.name)
	if x.value == nil do return
	if x.name != "" || x.color != nil do strings.write_string(b, x.kind == .Pull ? " <- " : " -> ")
	write_type(b, x.value, 0)
}
