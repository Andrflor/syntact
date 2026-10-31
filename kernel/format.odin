package kernel

import syn "../syntax"
import "core:fmt"

// FORMATS: WHAT A MACHINE HOLDS OF A REAL (real.odin)
//
// A floating-point format is a set of reals: f16, f32, f64 are types like u8. A real
// in a color of a format, and what an operation computes on values of formats, is
// what the machine holds of it: round_w(t), the value of the format of w bits nearest
// the real t, the even one on a tie. Its laws:
//
//   round(r)               = the nearest value, exactly       r a known real
//   round(t)               = t                                t a value of the format
//   round_f(round_g(t))    = round_g(t)                       f holds every value of g
//   round(εₖ(x, t))        = εₖ(x, round(t))
//   round(t ? {c -> p …})  = t ? {c -> round(p) …}
//   round of a set         = the values of the format between its rounded least and
//                            greatest — rounding keeps the order —; every value when
//                            the set has no bound, or one beyond the greatest value
//   a op b                 = round_f(a op b), f the widest format of a and b: the
//                            exact result; a known operand is first rounded to f

// round_law: round_f(t), written at span.
round_law :: proc(k: ^Kernel, t: Type, f: Real_Format, span: syn.Span) -> Type {
	if f == .Exact do return t
	#partial switch v in t {
	case Invalid:
		return t
	case Real:
		r, ok := round_real(v, f)
		if !ok do return problem(.Constraint_Mismatch, span, fmt.tprintf("%s is beyond the greatest %s", print_type(t), format_name[f]))
		return r
	case ^Effect:
		return wrapped(v, v.answer, round_law(k, v.then, f, span))
	case ^Pattern:
		branches := make([]Branch, len(v.branches))
		for b, i in v.branches do branches[i] = Branch{cover = b.cover, product = round_law(k, b.product, f, span), span = b.span}
		return pattern_law(k, branching(v, branches))
	case ^Operation:
		if v.op == .Round && holds_all(f, rounded_format(v)) do return t
	}
	if is_constant(t) do return round_set(k, t, f)
	if family, known := family_of(k, t); !known || family != .Real && family != .Nonzero_Real do return t
	if proven_in(k, t, real_cell({format = f})) do return t
	return new_operation(.Round, t, Int(FORMATS[f].bits))
}

// round_set: the values of the format f the reals of the set s round to: s itself
// when f holds them all.
round_set :: proc(k: ^Kernel, s: Type, f: Real_Format) -> Type {
	one: [1]Type
	cells, negated := cells_in(s, &one)
	if len(cells) == 0 && !negated do return s
	for c in cells do if cell_family(c) != .Real do return s
	if negated do return everything()
	held := true
	for c in cells do held &&= real_within(real_bounds(c), {format = f})
	if held do return s
	least, has_lo := real_bounds(cells[0]).lo.?
	greatest, has_hi := real_bounds(cells[len(cells) - 1]).hi.?
	if !has_lo || !has_hi do return everything()
	lo, lo_ok := round_real(least, f)
	hi, hi_ok := round_real(greatest, f)
	if !lo_ok || !hi_ok do return everything()
	return real_cell({lo = lo, hi = hi, format = f})
}

// rounded_format: the format a rounding rounds to.
rounded_format :: proc(o: ^Operation) -> Real_Format {
	return bits_format(o.args[1])
}

// bits_format: the format whose values take these bits.
bits_format :: proc(bits: Type) -> Real_Format {
	n, is_int := bits.(Int)
	if !is_int do return .Exact
	for f in Real_Format do if f != .Exact && i128(FORMATS[f].bits) == i128(n) do return f
	return .Exact
}

// operands_format: the widest format of the operands of an operation that computes
// a real; Exact when none is of a format.
operands_format :: proc(k: ^Kernel, op: Operator, args: []Type) -> Real_Format {
	#partial switch op {
	case .Add, .Sub, .Mul, .Div, .Neg, .Pow:
	case:
		return .Exact
	}
	out := Real_Format.Exact
	for a, i in args {
		if op == .Pow && i == 1 do break // the count of a power
		if f := term_format(k, a); f != .Exact do out = out == .Exact ? f : max(out, f)
	}
	return out
}

// term_format: the format a real term is a value of: a rounding, its own; an
// unknown or another term, that of its layout. A known real has none of its own.
term_format :: proc(k: ^Kernel, t: Type) -> Real_Format {
	if o, ok := t.(^Operation); ok && o.op == .Round do return rounded_format(o)
	if is_constant(t) do return reals_format(t, false)
	image, ok := layout_image(k, t)
	return ok ? reals_format(image, false) : .Exact
}

// color_format: the format of the reals a color admits, when formats hold them all.
color_format :: proc(color: Type) -> Real_Format {
	if color == nil || !is_constant(color) do return .Exact
	return reals_format(color, true)
}

// reals_format: the widest format of the real intervals of the constant s; Exact
// when one holds every real, or, unless others are allowed, when s has more than
// reals.
reals_format :: proc(s: Type, others: bool) -> Real_Format {
	one: [1]Type
	cells, negated := cells_in(s, &one)
	if negated do return .Exact
	out := Real_Format.Exact
	for c in cells {
		if cell_family(c) != .Real {
			if others do continue
			return .Exact
		}
		b := real_bounds(c)
		if is_point(b) do continue
		if b.format == .Exact do return .Exact
		out = out == .Exact ? b.format : max(out, b.format)
	}
	return out
}
