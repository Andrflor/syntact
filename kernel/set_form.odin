package kernel

import syn "../compiler"
import "core:fmt"
import "core:slice"
import "core:strings"

// SET OPERATIONS, AND SETS THAT DEPEND ON UNKNOWNS
//
// `|`, `&`, `~`, arithmetic, `..` and the half-lines operate on sets. On known
// sets, the type is the computed set. When an operand depends on unknowns
// (`??0..10`, `u8 & >??0`, `??0 | 6`), the type keeps the form of the operation:
// for each value of the unknowns, it is worth the operation on the values of its
// operands. The correlation is kept: in `(n | 6) & (n | 7)`, it is the same n
// twice.
//
// The form is simplified by exact laws: an empty operand, or an operand always
// included in the other, drops out (`n | 0..3` is worth 0..3 when n is in 0..3);
// the complement of a comparison is its opposite (`~(n < 5)` is `n >= 5`), and
// `~~x` is x. On truths — the types `x in c` and the comparisons — & | ~ are
// ∧ ∨ ¬: a truth holds when true is one of its elements (in.odin).

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

// A set that depends on unknowns. Its operands are types.
Set_Form :: struct {
	op:   Set_Op,
	args: []^Expr,
}

// set_operation: applies `op` to types. All known, it is the computed set;
// otherwise, the form of the operation, whose sorts are checked on the envelopes.
set_operation :: proc(k: ^Kernel, op: Set_Op, span: syn.Span, args: ..^Expr) -> ^Expr {
	known := make([]Set, len(args))
	all_known := true
	for a, i in args {
		s, ok := normal_set(k, a)
		known[i] = s
		all_known &&= ok
	}
	if all_known {
		r, status := apply_set_op(op, known)
		if status != .Ok do return set_op_failure(k, op, status, span, args)
		return new_expr(r)
	}
	// the bound of a half-line is a single value, never a set
	if op.kind == .Half && is_set_form(args[0]) do return set_op_failure(k, op, .Invalid, span, args)
	if _, status := enveloped(k, op, args); status != .Ok do return set_op_failure(k, op, status, span, args)
	return simplified(k, op, args)
}

is_set_form :: proc(t: ^Expr) -> bool {
	_, ok := t^.(Set_Form)
	return ok
}

// simplified: the form of the operation, after the exact laws that drop an
// operand — none, neutral for | and absorbing for &; and an operand x always
// included in a known set s: x | s = s and x & s = x. The complement of a
// complement is what it complements; that of a comparison, a single boolean, is
// the opposite comparison.
simplified :: proc(k: ^Kernel, op: Set_Op, args: []^Expr) -> ^Expr {
	if op.kind == .Comp {
		if inner, is_form := args[0]^.(Set_Form); is_form && inner.op.kind == .Comp do return inner.args[0]
		if opposite, ok := opposite_comparison(k, args[0]); ok do return opposite
	}
	if op.kind == .Union || op.kind == .Inter {
		for a, i in args {
			s, known := normal_set(k, a)
			if !known do continue
			other := args[1 - i]
			if carried(s) == {} do return op.kind == .Union ? other : a
			if env, ok := set_envelope(k, other); ok && within(env, s) do return op.kind == .Union ? a : other
		}
	}
	return new_expr(Set_Form{op, slice.clone(args)})
}

// within: each value of `env` is in `s`, and each sort it carries too.
within :: proc(env, s: Set) -> bool {
	return set_subset(env, s) && carried(env) <= carried(s)
}

// set_envelope: the union of all the possible values of a type — exact for a
// known set, over-approximated otherwise. It serves to decide and to check the
// sorts; it is never a type.
set_envelope :: proc(k: ^Kernel, t: ^Expr) -> (Set, bool) {
	if s, known := normal_set(k, t); known do return s, true
	#partial switch v in t^ {
	case Poly, Term, ^Var, Cases:
		vals, _ := envelope(k, t)
		return vals, true
	case Set_Form:
		s, status := enveloped(k, v.op, v.args)
		return s, status == .Ok
	}
	return {}, false
}

// enveloped: the operation on the envelopes of the operands. Each operation is
// monotone on the envelopes, except the complement, whose envelope is the whole
// sort, and `!=x`, which covers the whole sort as soon as x has several values.
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
		return range_set(uppers[0], op.lo_open, uppers[1], op.hi_open) // the envelope of all the ranges
	case .Comp:
		return sorts_of(uppers[0]), .Ok
	case .Half:
		return half_envelope(op.half, uppers[0])
	}
	return {}, .Invalid
}

// never_empty: the type has at least one value, whatever the unknowns.
never_empty :: proc(k: ^Kernel, t: ^Expr) -> bool {
	#partial switch v in t^ {
	case Poly, Term, ^Var:
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
	s, known := normal_set(k, t)
	return known && !set_is_empty(s)
}

// eval_set: the set a type is worth when each unknown `id` is worth env[id].
eval_set :: proc(t: ^Expr, env: []Atom) -> (set: Set, ok: bool) {
	#partial switch v in t^ {
	case Set:
		return v, true
	case Poly, Term, ^Var:
		a := eval(t, env) or_return
		return set_of_atoms({a}), true
	case Set_Form:
		args := make([]Set, len(v.args))
		for x, i in v.args do args[i] = eval_set(x, env) or_return
		r, status := apply_set_op(v.op, args)
		return r, status == .Ok
	case Cases:
		// the case whose fact holds for these values
		for c in v.cases {
			holds := holds_at(c.fact, env) or_return
			if holds do return eval_set(c.value, env)
		}
	}
	return {}, false
}

// opposite_comparison: ~t, t a comparison — a single boolean, whose complement is
// its opposite: `~(p < 0)` is `p >= 0`, `~(a = b)` is `a != b`. Between floats, an
// order has no opposite comparison (NaN).
opposite_comparison :: proc(k: ^Kernel, t: ^Expr) -> (^Expr, bool) {
	c, is_term := t^.(Term)
	if !is_term do return nil, false
	#partial switch c.op {
	case .Eq, .Ne:
		return new_expr(Term{op = c.op == .Eq ? .Ne : .Eq, args = c.args}), true
	case .Lt, .Le:
		if len(c.args) == 1 {
			p, _ := as_poly(c.args[0])
			r, status := int_compare(k, .Ge, p) // ¬(p < 0) is p >= 0
			return r, status == .Ok
		}
		if d, ok := value_domain(k, c.args[0]); ok && (d == .Ints || d == .Chars) {
			// a total order: ¬(a < b) is b <= a
			return new_expr(Term{op = c.op == .Lt ? .Le : .Lt, args = pair(c.args[1], c.args[0])}), true
		}
	}
	return nil, false
}

// sorts_of: all the values of the sorts that a set carries.
sorts_of :: proc(s: Set) -> Set {
	return set_complement(Set{sorts = carried(s)})
}

// half_envelope: the union of `>x` for every x of `xs` (and likewise for the
// others).
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
	if status == .Unsupported do return report(k, .Unsupported, span, fmt.tprintf("not in the kernel yet: %v on %s", op.kind, operands))
	if op.kind == .Range || op.kind == .Half {
		return report(k, .Invalid_Range, span, fmt.tprintf("the bounds of an interval are numbers, characters or strings of the same sort: %s", operands))
	}
	return report(k, .Invalid_operator, span, fmt.tprintf("%v does not apply to %s", op.kind, operands))
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

// range_set: `lo..hi` on known sets. It is the union of the ranges x..y for
// x ∈ lo, y ∈ hi. Between numbers or characters, it is the envelope of
// lo ∪ hi (`2..1` is `1..2`, `1..4..2..7` is `1..7`): any value between two
// bounds is between a bound of lo and a bound of hi. Between strings, "starts
// with" and "ends with". `..` alone, everything.
range_set :: proc(lo: Set, lo_open: bool, hi: Set, hi_open: bool) -> (Set, Arith_Status) {
	if lo_open && hi_open do return set_top(), .Ok
	ld, l_pure := pure_domain(lo)
	hd, h_pure := pure_domain(hi)
	if lo_open do ld, l_pure = hd, h_pure
	if hi_open do hd, h_pure = ld, l_pure
	if !l_pure || !h_pure do return {}, .Invalid
	both := set_union(lo, hi) // an open bound is empty: it does not count
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

// half_line: `>x` is the set of the numbers of the sort of x greater than x.
half_line :: proc(kind: syn.Operator_Kind, x: Set) -> (Set, Arith_Status) {
	d, pure := pure_domain(x)
	if !pure || set_count(x) != 1 do return {}, .Invalid
	#partial switch d {
	case .Ints:
		v, _ := ints_default(x.ints)
		#partial switch kind {
		case .Greater:
			if v == I128_MAX do return set_of_ints({}), .Ok // no integer beyond the universe
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

// --- printing, in Syntact ---

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
