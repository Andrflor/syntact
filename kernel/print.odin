package kernel

import "core:fmt"
import "core:strings"

// Impression de l'IR (et donc des types) en syntaxe Syntact.

print_expr :: proc(e: ^Expr) -> string {
	b := strings.builder_make()
	write_expr(&b, e)
	return strings.to_string(b)
}

write_expr :: proc(b: ^strings.Builder, e: ^Expr) {
	if e == nil {
		strings.write_string(b, "<nil>")
		return
	}
	switch v in e^ {
	case Set:
		strings.write_string(b, print_set(v))
	case ^Scope:
		write_scope(b, v)
	case Ref:
		fmt.sbprintf(b, "ref(%d,%d)", v.up, v.index)
	case Access:
		write_expr(b, v.target)
		fmt.sbprintf(b, ".%s", v.name)
	case Collapse:
		write_expr(b, v.target)
		strings.write_byte(b, '!')
	case Op:
		strings.write_byte(b, '(')
		if v.left != nil {
			write_expr(b, v.left)
			strings.write_byte(b, ' ')
		}
		fmt.sbprintf(b, "%v ", v.kind)
		write_expr(b, v.right)
		strings.write_byte(b, ')')
	case Range:
		if v.lo != nil do write_expr(b, v.lo)
		strings.write_string(b, "..")
		if v.hi != nil do write_expr(b, v.hi)
	case Unknown:
		strings.write_string(b, "??")
		if v.layout != nil {
			strings.write_string(b, "::")
			write_expr(b, v.layout)
		}
	case Many:
		strings.write_string(b, "<plusieurs>")
	case Invalid:
		strings.write_string(b, "<invalide>")
	}
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

write_scope :: proc(b: ^strings.Builder, s: ^Scope) {
	strings.write_byte(b, '{')
	for bd, i in s.bindings {
		if i > 0 do strings.write_string(b, "  ")
		if bd.color != nil {
			write_expr(b, bd.color)
			strings.write_byte(b, ':')
		}
		if bd.name != "" do strings.write_string(b, bd.name)
		if bd.capture != "" do fmt.sbprintf(b, "(%s)", bd.capture)
		if bd.value != nil {
			if bd.name != "" || bd.color != nil || bd.kind != .Push {
				if bd.name != "" || bd.color != nil do strings.write_byte(b, ' ')
				fmt.sbprintf(b, "%s ", ARROWS[bd.kind])
			}
			write_expr(b, bd.value)
		}
	}
	strings.write_byte(b, '}')
}

print_set :: proc(s: Set) -> string {
	parts := make([dynamic]string)
	for iv in s.ints.intervals do append(&parts, print_int_interval(iv))
	for iv in s.floats.intervals do append(&parts, print_float_interval(iv))
	if ints_subset(chars_all(), s.chars) {
		append(&parts, "char")
	} else {
		for iv in s.chars.intervals do append(&parts, print_char_interval(iv))
	}
	if len(s.strings.states) > 0 do append(&parts, print_strings(s.strings))
	switch s.bools {
	case {.False, .True}:
		append(&parts, "bool")
	case {.True}:
		append(&parts, "true")
	case {.False}:
		append(&parts, "false")
	}
	if len(parts) == 0 do return "none"
	return strings.join(parts[:], " | ")
}

print_char_interval :: proc(iv: Int_Interval) -> string {
	lo, _ := iv.lo.?
	hi, _ := iv.hi.?
	if lo == hi do return print_char(lo)
	return fmt.tprintf("%s..%s", print_char(lo), print_char(hi))
}

print_char :: proc(c: i128) -> string {
	if c == CHAR_EMPTY do return "''"
	return print_rune(rune(c))
}

print_int_interval :: proc(iv: Int_Interval) -> string {
	lo, lo_ok := iv.lo.?
	hi, hi_ok := iv.hi.?
	switch {
	case lo_ok && hi_ok && lo == hi:
		return fmt.tprintf("%d", lo)
	case lo_ok && hi_ok:
		return fmt.tprintf("%d..%d", lo, hi)
	case lo_ok:
		return fmt.tprintf("%d..", lo)
	case hi_ok:
		return fmt.tprintf("..%d", hi)
	}
	return "int"
}

print_float_interval :: proc(iv: Float_Interval) -> string {
	lo, lo_ok := iv.lo.?
	hi, hi_ok := iv.hi.?
	if lo_ok && hi_ok && lo == hi do return print_float(lo)
	if !lo_ok && !hi_ok do return "float"
	b := strings.builder_make()
	if lo_ok do strings.write_string(&b, print_float(lo))
	strings.write_string(&b, iv.lo_open ? "<" : "")
	strings.write_string(&b, "..")
	strings.write_string(&b, iv.hi_open ? "<" : "")
	if hi_ok do strings.write_string(&b, print_float(hi))
	return strings.to_string(b)
}

// Un flottant s'imprime toujours avec sa partie décimale, pour ne pas le confondre
// avec un entier.
print_float :: proc(v: f64) -> string {
	s := fmt.tprintf("%v", v)
	if strings.contains_any(s, ".eEnN") do return s
	return fmt.tprintf("%s.0", s)
}
