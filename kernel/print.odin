package kernel

import syn "../compiler"
import "core:fmt"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"

// Impression de l'IR (et donc des types) en syntaxe Syntact, avec les seules
// parenthèses qu'exige la précédence du parser : chaque écriture rend aussi le
// niveau auquel elle lie.

Level :: syn.Precedence

print_expr :: proc(e: ^Expr) -> string {
	s, _ := printed(e)
	return s
}

// print_at : `e` à une place qui lie au niveau `level`, entre parenthèses s'il
// lie plus lâchement.
print_at :: proc(e: ^Expr, level: Level) -> string {
	s, own := printed(e)
	return wrap(s, own, level)
}

wrap :: proc(s: string, own, level: Level) -> string {
	return own < level ? fmt.tprintf("(%s)", s) : s
}

above :: proc(level: Level) -> Level {
	return Level(int(level) + 1)
}

// brief : une écriture raccourcie, pour un message d'erreur.
brief :: proc(e: ^Expr) -> string {
	s := print_expr(e)
	if len(s) <= 120 do return s
	cut := 120
	for cut > 0 && !utf8.rune_start(s[cut]) do cut -= 1
	return fmt.tprintf("%s…", s[:cut])
}

printed :: proc(e: ^Expr) -> (string, Level) {
	if e == nil do return "<nil>", .PRIMARY
	b := strings.builder_make()
	switch v in e^ {
	case Set:
		return printed_set(v)
	case Poly:
		return printed_poly(v)
	case Term:
		return printed_term(v)
	case ^Scope:
		write_scope(&b, v)
	case Family:
		write_family(&b, v)
	case Subsets:
		write_subsets(&b, v)
	case Ref:
		fmt.sbprintf(&b, "ref(%d,%d)", v.up, v.index)
	case Access:
		fmt.sbprintf(&b, "%s.%s", print_at(v.target, .CALL), v.name)
	case Collapse:
		fmt.sbprintf(&b, "%s!", print_at(v.target, .CALL))
	case Op:
		if v.left != nil do fmt.sbprintf(&b, "(%s %v %s)", print_expr(v.left), v.kind, print_expr(v.right))
		else do fmt.sbprintf(&b, "(%v %s)", v.kind, print_expr(v.right))
	case Range:
		lo := v.lo != nil ? print_at(v.lo, .CALL) : ""
		hi := v.hi != nil ? print_at(v.hi, .CALL) : ""
		return fmt.tprintf("%s..%s", lo, hi), .RANGE
	case Unknown:
		if v.layout == nil do return "??", .PRIMARY
		return fmt.tprintf("??::%s", print_at(v.layout, .CALL)), .CALL
	case Invalid:
		strings.write_string(&b, "<invalide>")
	}
	return strings.to_string(b), .PRIMARY
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

// Une couleur est l'opérande gauche de `:` : elle doit lier plus fort que lui.
write_scope :: proc(b: ^strings.Builder, s: ^Scope) {
	strings.write_byte(b, '{')
	for bd, i in s.bindings {
		if i > 0 do strings.write_string(b, "  ")
		if bd.color != nil do fmt.sbprintf(b, "%s:", print_at(bd.color, above(.CONSTRAINT)))
		if bd.name != "" do strings.write_string(b, bd.name)
		if bd.capture != "" do fmt.sbprintf(b, "(%s)", bd.capture)
		if bd.value != nil {
			if bd.name != "" || bd.color != nil || bd.kind != .Push {
				if bd.name != "" || bd.color != nil do strings.write_byte(b, ' ')
				fmt.sbprintf(b, "%s ", ARROWS[bd.kind])
			}
			strings.write_string(b, print_expr(bd.value))
		}
	}
	strings.write_byte(b, '}')
}

// --- ensembles ---

print_set :: proc(s: Set) -> string {
	text, _ := printed_set(s)
	return text
}

// printed_set : une composante par sorte, unies par `|`.
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
	// une sorte portée mais vide : « aucun entier », etc.
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

// Une borne fermée s'écrit dans la plage (`0.5..1.0`) ; une borne ouverte, par une
// demi-droite (`>0.5 & <1.0`).
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

// print_float : l'écriture décimale la plus courte qui relit la même valeur, sans
// exposant (Syntact n'en lit pas), toujours avec un point pour ne pas la lire
// comme un entier.
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

// Une plage de caractères qui touche une extrémité s'écrit ouverte de ce côté :
// `'d'..` va jusqu'au dernier caractère, `..'c'` part du caractère vide.
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

// quote_text : un texte entre délimiteurs, avec les seuls échappements que Syntact
// lit (\n \t \r \0, et l'échappement du délimiteur et de \).
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

// --- chaînes ---

print_strings :: proc(a: Strings) -> string {
	text, _ := printed_strings(a)
	return text
}

printed_strings :: proc(a: Strings) -> (string, Level) {
	b := strings.builder_make()
	level := write_regex(&b, a.re, textual = false)
	return strings.to_string(b), level
}

// write_regex écrit `re` et rend le niveau auquel l'écriture lie. `textual` :
// la place lit déjà un caractère comme une chaîne (dans `+`, à gauche de `*`) ;
// ailleurs, une plage de caractères seule se lirait comme des caractères, et
// s'écrit concaténée au mot vide.
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
		// associée à droite : on écrit la suite de ses parties
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
		slice.sort_by(parts, proc(x, y: ^Regex) -> bool {return x.kind == .Words && y.kind != .Words}) // les mots d'abord
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
