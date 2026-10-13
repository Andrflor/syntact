package kernel

import syn "../compiler"
import "core:fmt"
import "core:slice"
import "core:strings"

// LES OPÉRATIONS D'ENSEMBLES, ET LES ENSEMBLES QUI DÉPENDENT D'INCONNUES
//
// `|`, `&`, `~`, l'arithmétique, `..` et les demi-droites opèrent sur des
// ensembles. Sur des ensembles connus, le type est l'ensemble calculé. Quand un
// opérande dépend d'inconnues (`??0..10`, `u8 & >??0`, `??0 | 6`), le type garde
// la forme de l'opération : pour chaque valeur des inconnues, il vaut l'opération
// sur les valeurs de ses opérandes. La corrélation est gardée : dans
// `(n | 6) & (n | 7)`, c'est deux fois le même n.
//
// La forme est simplifiée par des lois exactes : un opérande vide, ou un opérande
// toujours inclus dans l'autre, tombe (`n | 0..3` vaut 0..3 quand n est dans
// 0..3). Une forme dépend d'inconnues : ce n'est jamais une couleur.

Set_Op_Kind :: enum u8 {
	Union,
	Inter,
	Comp,
	Arith,
	Range,
	Half, // >x, <x, >=x, <=x, !=x
}

Set_Op :: struct {
	kind:    Set_Op_Kind,
	arith:   Arith,
	half:    syn.Operator_Kind,
	lo_open: bool,
	hi_open: bool,
}

// Un ensemble qui dépend d'inconnues. Ses opérandes sont des types.
Set_Form :: struct {
	op:   Set_Op,
	args: []^Expr,
}

// set_operation : applique `op` à des types. Tous connus, c'est l'ensemble calculé ;
// sinon, la forme de l'opération, dont les sortes sont vérifiées sur les enveloppes.
set_operation :: proc(k: ^Kernel, op: Set_Op, span: syn.Span, args: ..^Expr) -> ^Expr {
	known := make([]Set, len(args))
	all_known := true
	for a, i in args {
		s, ok := color_set(k, a)
		known[i] = s
		all_known &&= ok
	}
	if all_known {
		r, status := apply_set_op(op, known)
		if status != .Ok do return set_op_failure(k, op, status, span, args)
		return new_expr(r)
	}
	// la borne d'une demi-droite est une seule valeur, jamais un ensemble
	if op.kind == .Half && is_set_form(args[0]) do return set_op_failure(k, op, .Invalid, span, args)
	if _, status := enveloped(k, op, args); status != .Ok do return set_op_failure(k, op, status, span, args)
	return simplified(k, op, args)
}

is_set_form :: proc(t: ^Expr) -> bool {
	_, ok := t^.(Set_Form)
	return ok
}

// simplified : la forme de l'opération, après les lois exactes qui font tomber un
// opérande — none, neutre pour | et absorbant pour & ; et un opérande x toujours
// inclus dans un ensemble connu s : x | s = s et x & s = x.
simplified :: proc(k: ^Kernel, op: Set_Op, args: []^Expr) -> ^Expr {
	if op.kind == .Union || op.kind == .Inter {
		for a, i in args {
			s, known := color_set(k, a)
			if !known do continue
			other := args[1 - i]
			if carried(s) == {} do return op.kind == .Union ? other : a
			if env, ok := set_envelope(k, other); ok && within(env, s) do return op.kind == .Union ? a : other
		}
	}
	return new_expr(Set_Form{op, slice.clone(args)})
}

// within : chaque valeur de `env` est dans `s`, et chaque sorte qu'il porte aussi.
within :: proc(env, s: Set) -> bool {
	return set_subset(env, s) && carried(env) <= carried(s)
}

// set_envelope : l'union de toutes les valeurs possibles d'un type — exacte pour un
// ensemble connu, sur-approchée sinon. Elle sert à décider et à vérifier les
// sortes ; ce n'est jamais un type.
set_envelope :: proc(k: ^Kernel, t: ^Expr) -> (Set, bool) {
	if s, known := color_set(k, t); known do return s, true
	#partial switch v in t^ {
	case Poly, Term:
		vals, _ := values_of(k, t)
		return vals, true
	case Set_Form:
		s, status := enveloped(k, v.op, v.args)
		return s, status == .Ok
	}
	return {}, false
}

// enveloped : l'opération sur les enveloppes des opérandes. Chaque opération est
// monotone sur les enveloppes, sauf le complément, dont l'enveloppe est toute la
// sorte, et `!=x`, qui couvre toute la sorte dès que x a plusieurs valeurs.
enveloped :: proc(k: ^Kernel, op: Set_Op, args: []^Expr) -> (Set, Arith_Status) {
	uppers := make([]Set, len(args))
	for a, i in args {
		u, ok := set_envelope(k, a)
		if !ok do return {}, .Unsupported
		uppers[i] = u
	}
	switch op.kind {
	case .Union, .Inter, .Arith:
		return apply_set_op(op, uppers)
	case .Range:
		return range_set(uppers[0], op.lo_open, uppers[1], op.hi_open) // l'enveloppe de toutes les plages
	case .Comp:
		return sorts_of(uppers[0]), .Ok
	case .Half:
		return half_envelope(op.half, uppers[0])
	}
	return {}, .Invalid
}

// never_empty : le type a au moins une valeur, quelles que soient les inconnues.
never_empty :: proc(k: ^Kernel, t: ^Expr) -> bool {
	#partial switch v in t^ {
	case Poly, Term:
		return true
	case Set_Form:
		#partial switch v.op.kind {
		case .Union:
			return never_empty(k, v.args[0]) || never_empty(k, v.args[1])
		case .Range:
			return (v.op.lo_open || never_empty(k, v.args[0])) && (v.op.hi_open || never_empty(k, v.args[1]))
		}
		return false
	}
	s, known := color_set(k, t)
	return known && !set_is_empty(s)
}

// eval_set : l'ensemble que vaut un type quand chaque inconnue `id` vaut env[id].
eval_set :: proc(k: ^Kernel, t: ^Expr, env: []Atom) -> (set: Set, ok: bool) {
	if s, known := color_set(k, t); known do return s, true
	#partial switch v in t^ {
	case Poly, Term:
		a := eval(t, env) or_return
		return set_of_atoms({a}), true
	case Set_Form:
		args := make([]Set, len(v.args))
		for x, i in v.args do args[i] = eval_set(k, x, env) or_return
		r, status := apply_set_op(v.op, args)
		return r, status == .Ok
	}
	return {}, false
}

// sorts_of : toutes les valeurs des sortes qu'un ensemble porte.
sorts_of :: proc(s: Set) -> Set {
	return set_complement(Set{sorts = carried(s)})
}

// half_envelope : l'union de `>x` pour tout x de `xs` (et de même pour les autres).
half_envelope :: proc(kind: syn.Operator_Kind, xs: Set) -> (Set, Arith_Status) {
	d, pure := pure_domain(xs)
	if !pure || (d != .Ints && d != .Floats) do return {}, .Invalid
	if kind == .NotEqual do return sorts_of(xs), .Ok
	if d == .Ints {
		l, h := ints_bounds(xs.ints)
		if kind == .Greater || kind == .GreaterEqual {
			if v, ok := l.?; ok do return half_line(kind, set_of_ints(ints_point(v)))
		} else {
			if v, ok := h.?; ok do return half_line(kind, set_of_ints(ints_point(v)))
		}
		return sorts_of(xs), .Ok
	}
	l, h := floats_bounds(xs.floats)
	if kind == .Greater || kind == .GreaterEqual {
		if v, ok := l.?; ok do return half_line(kind, set_of_floats(floats_point(v)))
	} else {
		if v, ok := h.?; ok do return half_line(kind, set_of_floats(floats_point(v)))
	}
	return sorts_of(xs), .Ok
}

set_op_failure :: proc(k: ^Kernel, op: Set_Op, status: Arith_Status, span: syn.Span, args: []^Expr) -> ^Expr {
	parts := make([dynamic]string)
	for a in args do append(&parts, print_type(a))
	operands := strings.join(parts[:], ", ")
	if status == .Unsupported do return report(k, .Unsupported, span, fmt.tprintf("pas encore dans le kernel : %v sur %s", op.kind, operands))
	if op.kind == .Range || op.kind == .Half {
		return report(k, .Invalid_Range, span, fmt.tprintf("les bornes d'un intervalle sont des nombres, des caractères ou des chaînes de même sorte : %s", operands))
	}
	return report(k, .Invalid_operator, span, fmt.tprintf("%v ne s'applique pas à %s", op.kind, operands))
}

apply_set_op :: proc(op: Set_Op, args: []Set) -> (Set, Arith_Status) {
	switch op.kind {
	case .Union:
		return set_union(args[0], args[1]), .Ok
	case .Inter:
		return set_intersect(args[0], args[1]), .Ok
	case .Comp:
		return set_complement(args[0]), .Ok
	case .Arith:
		return arith_sets(op.arith, args[0], args[1])
	case .Range:
		return range_set(args[0], op.lo_open, args[1], op.hi_open)
	case .Half:
		return half_line(op.half, args[0])
	}
	return {}, .Invalid
}

// range_set : `lo..hi` sur des ensembles connus. C'est l'union des plages x..y pour
// x ∈ lo, y ∈ hi. Entre des nombres ou des caractères, c'est l'enveloppe de
// lo ∪ hi (`2..1` est `1..2`, `1..4..2..7` est `1..7`) : toute valeur entre deux
// bornes est entre une borne de lo et une borne de hi. Entre des chaînes, « commence
// par » et « finit par ». `..` seul, tout.
range_set :: proc(lo: Set, lo_open: bool, hi: Set, hi_open: bool) -> (Set, Arith_Status) {
	if lo_open && hi_open do return set_top(), .Ok
	ld, l_pure := pure_domain(lo)
	hd, h_pure := pure_domain(hi)
	if lo_open do ld, l_pure = hd, h_pure
	if hi_open do hd, h_pure = ld, l_pure
	if !l_pure || !h_pure do return {}, .Invalid
	both := set_union(lo, hi) // une borne ouverte est vide : elle ne compte pas
	switch {
	case ld == .Ints && hd == .Ints:
		l, h := ints_bounds(both.ints)
		return set_of_ints(ints_range(lo_open ? nil : l, hi_open ? nil : h)), .Ok
	case ld == .Chars && hd == .Chars:
		l, h := ints_bounds(both.chars)
		return set_of_chars(ints_range(lo_open ? CHAR_EMPTY : l, hi_open ? i128(MAX_RUNE) : h)), .Ok
	case ld == .Floats && hd == .Floats:
		f := both.floats.intervals
		hull := Float_Interval{f[0].lo, f[len(f) - 1].hi, f[0].lo_open, f[len(f) - 1].hi_open}
		if lo_open do hull.lo, hull.lo_open = nil, false
		if hi_open do hull.hi, hull.hi_open = nil, false
		return set_of_floats(floats_of({hull})), .Ok
	case is_textual(ld) && is_textual(hd):
		l := strings_all()
		if !lo_open do l = strings_prefixed(as_strings(lo))
		if !hi_open do l = strings_intersect(l, strings_suffixed(as_strings(hi)))
		return set_of_strings(l), .Ok
	}
	return {}, .Invalid
}

// half_line : `>x` est l'ensemble des nombres de la sorte de x plus grands que x.
half_line :: proc(kind: syn.Operator_Kind, x: Set) -> (Set, Arith_Status) {
	d, pure := pure_domain(x)
	if !pure || set_count(x) != 1 do return {}, .Invalid
	#partial switch d {
	case .Ints:
		v, _ := ints_default(x.ints)
		#partial switch kind {
		case .Greater:
			if v == I128_MAX do return set_of_ints({}), .Ok // aucun entier au-delà de l'univers
			return set_of_ints(ints_range(v + 1, nil)), .Ok
		case .GreaterEqual:
			return set_of_ints(ints_range(v, nil)), .Ok
		case .Less:
			if v == -I128_MAX do return set_of_ints({}), .Ok
			return set_of_ints(ints_range(nil, v - 1)), .Ok
		case .LessEqual:
			return set_of_ints(ints_range(nil, v)), .Ok
		}
		return set_of_ints(ints_complement(ints_point(v))), .Ok // !=
	case .Floats:
		v, _ := floats_default(x.floats)
		#partial switch kind {
		case .Greater:
			return set_of_floats(floats_of({Float_Interval{lo = v, lo_open = true}})), .Ok
		case .GreaterEqual:
			return set_of_floats(floats_of({Float_Interval{lo = v}})), .Ok
		case .Less:
			return set_of_floats(floats_of({Float_Interval{hi = v, hi_open = true}})), .Ok
		case .LessEqual:
			return set_of_floats(floats_of({Float_Interval{hi = v}})), .Ok
		}
		return set_of_floats(floats_complement(floats_point(v))), .Ok
	}
	return {}, .Invalid
}

// --- impression, en Syntact ---

printed_set_form :: proc(f: Set_Form) -> (string, Level) {
	binary :: proc(a, b: ^Expr, symbol: string, level: Level) -> (string, Level) {
		return fmt.tprintf("%s %s %s", print_type_at(a, level), symbol, print_type_at(b, above(level))), level
	}
	switch f.op.kind {
	case .Union:
		return binary(f.args[0], f.args[1], "|", .OR)
	case .Inter:
		return binary(f.args[0], f.args[1], "&", .AND)
	case .Arith:
		#partial switch f.op.arith {
		case .Add:
			return binary(f.args[0], f.args[1], "+", .TERM)
		case .Sub:
			return binary(f.args[0], f.args[1], "-", .TERM)
		}
		return binary(f.args[0], f.args[1], "*", .FACTOR)
	case .Comp:
		return fmt.tprintf("~%s", print_type_at(f.args[0], .UNARY)), .UNARY
	case .Half:
		return fmt.tprintf("%s%s", HALF_SYMBOLS[f.op.half], print_type_at(f.args[0], .UNARY)), .COMPARISON
	case .Range:
		lo := f.op.lo_open ? "" : print_type_at(f.args[0], .CALL)
		hi := f.op.hi_open ? "" : print_type_at(f.args[1], .CALL)
		return fmt.tprintf("%s..%s", lo, hi), .RANGE
	}
	return "", .PRIMARY
}

HALF_SYMBOLS := #partial [syn.Operator_Kind]string {
	.Greater      = ">",
	.GreaterEqual = ">=",
	.Less         = "<",
	.LessEqual    = "<=",
	.NotEqual     = "!=",
}
