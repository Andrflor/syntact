package kernel

import syn "../compiler"
import "core:fmt"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"

// Impression de l'IR en syntaxe Syntact, avec les seules parenthèses qu'exige la
// précédence du parser : chaque écriture rend aussi le niveau auquel elle lie.
// Une même IR a deux lectures : le programme, couleurs et valeurs telles
// qu'écrites ; et ses types, color_type et value_type.

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

// print_at : `e` à une place qui lie au niveau `level`, entre parenthèses s'il
// lie plus lâchement.
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

// brief : un type, en écriture raccourcie, pour un message d'erreur.
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
	case Set_Form:
		return printed_set_form(v)
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
		return printed(v.args.bindings[v.index].value, .Program) // l'argument, tel qu'écrit
	case Inferred:
		return printed(v.type, .Program)
	case Carving:
		return "", .PRIMARY // `.x` : la source est le scope carvé
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
		return "<invalide>", .PRIMARY
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
	.Cast         = {"::", .CALL},
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

// print_scope : un scope, lu comme programme ou comme type. Une couleur est
// l'opérande gauche de `:` : elle doit lier plus fort que lui. `ordinals` : pour
// les arguments d'un carve, l'occurrence que vise chacun (`x#1`).
print_scope :: proc(s: ^Scope, view: View, ordinals: []int = nil) -> string {
	b := strings.builder_make()
	strings.write_byte(&b, '{')
	shown := make([dynamic]Binding, context.temp_allocator)
	if view == .Type {
		for p in places(s) do append(&shown, binding_at(p)^) // le scope tel qu'il se présente
	} else {
		append(&shown, ..s.bindings[:])
	}
	for bd, i in shown {
		color, value := bd.color, bd.value
		if view == .Type do color, value = bd.color_type, bd.value_type
		if i > 0 do strings.write_string(&b, "  ")
		if color != nil do fmt.sbprintf(&b, "%s:", print_at(color, above(.CONSTRAINT), view))
		if bd.name != "" do strings.write_string(&b, bd.name)
		if i < len(ordinals) && ordinals[i] >= 0 do fmt.sbprintf(&b, "#%d", ordinals[i])
		if bd.capture != "" do fmt.sbprintf(&b, "(%s)", bd.capture)
		if value != nil {
			if bd.name != "" || color != nil || bd.kind != .Push {
				if bd.name != "" || color != nil do strings.write_byte(&b, ' ')
				fmt.sbprintf(&b, "%s ", ARROWS[bd.kind])
			}
			strings.write_string(&b, print_at(value, .NONE, view))
		}
	}
	strings.write_byte(&b, '}')
	return strings.to_string(b)
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
	if domain_count(s, .Sets) > 0 {
		text, level := printed_values(s.sets)
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
	.Sets    = "set",
}

// printed_values : les ensembles admis comme valeurs, `{-> u8  -> i8}` ; leur
// complément, `~{-> u8}` ; tous, `set`.
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
