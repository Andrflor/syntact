package kernel

import "core:fmt"
import "core:strings"

// PRINTING TYPES, in the syntax of the language.

print_types :: proc(ts: []Type) -> string {
	parts := make([]string, len(ts))
	for t, i in ts do parts[i] = print_type(t)
	return strings.join(parts, ", ")
}

print_type :: proc(t: Type) -> string {
	switch v in t {
	case Set:
		return print_set(v)
	case ^Apply:
		return print_apply(v)
	case Poly:
		return print_poly(v)
	case ^Unknown:
		return fmt.tprintf("?%d", v.id)
	case ^Frame:
		return print_frame(v, 0)
	case Invalid:
		return "<invalid>"
	}
	return "<nil>"
}

// print_frame: a scope with the types of its bindings, as far as they are known.
print_frame :: proc(f: ^Frame, depth: int) -> string {
	if depth > 3 do return "{…}"
	parts := make([dynamic]string)
	for b, i in f.scope.bindings {
		value := "…"
		if f.states[i] == .Done {
			if g, is_frame := f.values[i].(^Frame); is_frame {
				value = print_frame(g, depth + 1)
			} else {
				value = print_type(f.values[i])
			}
		}
		switch b.kind {
		case .Product:
			append(&parts, fmt.tprintf("-> %s", value))
		case .Expand:
			append(&parts, fmt.tprintf("...%s", value))
		case .Pull:
			append(&parts, fmt.tprintf("%s <- %s", b.name, value))
		case .Push:
			if b.name == "" {
				append(&parts, value)
			} else {
				append(&parts, fmt.tprintf("%s -> %s", b.name, value))
			}
		}
	}
	return fmt.tprintf("{{%s}}", strings.join(parts[:], "  "))
}

OP_SPELLING := [Op]string {
	.Or         = "|",
	.And        = "&",
	.Not        = "~",
	.Is         = "=",
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
	.Range      = "..",
	.Range_From = "..",
	.Range_To   = "..",
	.Match      = "?",
}

print_poly :: proc(p: Poly) -> string {
	b := strings.builder_make()
	for m, i in p.monos {
		c := m.coef
		if i > 0 {
			strings.write_string(&b, c < 0 ? " - " : " + ")
			c = abs(c)
		} else if c < 0 {
			strings.write_string(&b, "-")
			c = -c
		}
		if c != 1 do fmt.sbprintf(&b, "%v * ", c)
		for v, j in m.vars {
			if j > 0 do strings.write_string(&b, " * ")
			fmt.sbprintf(&b, "?%d", v.id)
		}
	}
	if p.constant != 0 || len(p.monos) == 0 {
		if len(p.monos) > 0 {
			fmt.sbprintf(&b, p.constant < 0 ? " - %v" : " + %v", abs(p.constant))
		} else {
			fmt.sbprintf(&b, "%v", p.constant)
		}
	}
	s := strings.to_string(b)
	if p.denom != 1 do s = fmt.tprintf("(%s) / %v", s, p.denom)
	return s
}

print_apply :: proc(a: ^Apply) -> string {
	#partial switch a.op {
	case .Match:
		parts := make([dynamic]string)
		for i := 1; i + 1 < len(a.args); i += 2 {
			if a.args[i] == nil {
				append(&parts, fmt.tprintf("-> %s", print_type(a.args[i + 1])))
			} else {
				append(&parts, fmt.tprintf("%s -> %s", print_type(a.args[i]), print_type(a.args[i + 1])))
			}
		}
		return fmt.tprintf("%s ? {{%s}}", print_operand(a.args[0]), strings.join(parts[:], "  "))
	case .Range:
		return fmt.tprintf("%s..%s", print_operand(a.args[0]), print_operand(a.args[1]))
	case .Range_From:
		return fmt.tprintf("%s..", print_operand(a.args[0]))
	case .Range_To:
		return fmt.tprintf("..%s", print_operand(a.args[0]))
	}
	if len(a.args) == 1 do return fmt.tprintf("%s%s", OP_SPELLING[a.op], print_operand(a.args[0]))
	return fmt.tprintf("%s %s %s", print_operand(a.args[0]), OP_SPELLING[a.op], print_operand(a.args[1]))
}

print_operand :: proc(t: Type) -> string {
	s := print_type(t)
	if _, is_apply := t.(^Apply); is_apply || strings.contains(s, " ") do return fmt.tprintf("(%s)", s)
	return s
}

print_set :: proc(s: Set) -> string {
	if set_is_none(s) do return "none"
	if set_equal(s, set_everything()) do return "~none"
	parts := make([dynamic]string)
	if ints_full(s.ints) {
		append(&parts, "int")
	} else {
		for r in s.ints.ranges do append(&parts, print_int_range(r))
	}
	if reals_full(s.reals) {
		append(&parts, "float")
	} else {
		for r in s.reals.ranges do append(&parts, print_real_range(r))
	}
	if w := set_words(s); !words_is_empty(w) do append(&parts, print_words(w))
	switch s.bools {
	case {.False}:
		append(&parts, "false")
	case {.True}:
		append(&parts, "true")
	case {.False, .True}:
		append(&parts, "bool")
	}
	if !scopes_empty(s.scopes) do append(&parts, "{...}")
	return strings.join(parts[:], " | ")
}

print_int_range :: proc(r: Int_Range) -> string {
	lo, has_lo := r.lo.?
	hi, has_hi := r.hi.?
	switch {
	case has_lo && has_hi && lo == hi:
		return fmt.tprint(lo)
	case has_lo && has_hi:
		return fmt.tprintf("%v..%v", lo, hi)
	case has_lo:
		return fmt.tprintf("%v..", lo)
	case has_hi:
		return fmt.tprintf("..%v", hi)
	}
	return "int"
}

print_real :: proc(v: f64) -> string {
	s := fmt.tprint(v)
	if !strings.contains_any(s, ".eE") do s = fmt.tprintf("%s.0", s)
	return s
}

print_real_range :: proc(r: Real_Range) -> string {
	lo, has_lo := r.lo.?
	hi, has_hi := r.hi.?
	if has_lo && has_hi && lo == hi do return print_real(lo)
	if !r.lo_open && !r.hi_open {
		a := has_lo ? print_real(lo) : ""
		b := has_hi ? print_real(hi) : ""
		return fmt.tprintf("%s..%s", a, b)
	}
	parts := make([dynamic]string)
	if has_lo do append(&parts, fmt.tprintf("%s%s", r.lo_open ? ">" : ">=", print_real(lo)))
	if has_hi do append(&parts, fmt.tprintf("%s%s", r.hi_open ? "<" : "<=", print_real(hi)))
	return strings.join(parts[:], " & ")
}

print_words :: proc(w: ^Words) -> string {
	switch w.kind {
	case .Empty:
		return "none"
	case .Epsilon:
		return `""`
	case .Class:
		if ints_equal(w.class, ints_between(0, MAX_RUNE)) do return "''.."
		parts := make([dynamic]string)
		for r in w.class.ranges {
			lo, _ := r.lo.?
			hi, _ := r.hi.?
			if lo == hi {
				append(&parts, fmt.tprintf("'%c'", rune(lo)))
			} else {
				append(&parts, fmt.tprintf("'%c'..'%c'", rune(lo), rune(hi)))
			}
		}
		return strings.join(parts[:], " | ")
	case .Cat:
		// a chain: the single characters that follow each other are one string
		parts := make([dynamic]string)
		run := make([dynamic]rune)
		flush :: proc(parts: ^[dynamic]string, run: ^[dynamic]rune) {
			switch len(run) {
			case 0:
			case 1:
				append(parts, fmt.tprintf("'%c'", run[0]))
			case:
				append(parts, fmt.tprintf("%q", runes_string(run[:])))
			}
			clear(run)
		}
		for x := w; x != nil; {
			head, rest := x, (^Words)(nil)
			if x.kind == .Cat do head, rest = x.args[0], x.args[1]
			c, single := ints_single(head.class)
			if head.kind == .Class && single {
				append(&run, rune(c))
			} else {
				flush(&parts, &run)
				append(&parts, print_words_operand(head))
			}
			x = rest
		}
		flush(&parts, &run)
		return strings.join(parts[:], " + ")
	case .Alt, .And:
		parts := make([dynamic]string)
		for a in w.args do append(&parts, print_words_operand(a))
		return strings.join(parts[:], w.kind == .Alt ? " | " : " & ")
	case .Not:
		if w.args[0].kind == .Empty do return "string"
		return fmt.tprintf("~%s", print_words_operand(w.args[0]))
	case .Repeat:
		return fmt.tprintf("%s * %s", print_words_operand(w.args[0]), print_set(Set{ints = w.counts}))
	}
	return "?"
}

print_words_operand :: proc(w: ^Words) -> string {
	s := print_words(w)
	if strings.contains(s, " ") && w.kind != .Class do return fmt.tprintf("(%s)", s)
	return s
}
