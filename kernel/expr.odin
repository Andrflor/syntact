package kernel

import syn "../compiler"

// THE PROGRAM AS WRITTEN
//
// An expression is a type of the algebra as it is written (specs/types.md §2),
// names included. type_of puts it in normal form in a frame: a name becomes the
// type of its binding (§5.2), and each operation is applied by its laws.

Expr :: union {
	Set, // a literal or a builtin
	Name,
	^Operation,
	^Range_Expr,
	Invalid, // an error already reported
}

is_invalid_expr :: proc(e: Expr) -> bool {
	if e == nil do return true
	_, ok := e.(Invalid)
	return ok
}

// Name: a binding, resolved where it is written: the last visible occurrence.
Name :: struct {
	scope: ^Scope,
	index: int,
	span:  syn.Span,
}

Operation :: struct {
	op:   Op,
	args: []Expr,
	span: syn.Span,
}

// Range_Expr: `lo..hi`, a bound may be missing (§4.3). Between single-quoted
// literals the range is over the characters (ordinal); between strings, over the
// positions.
Range_Expr :: struct {
	lo, hi:  Expr,
	ordinal: bool,
	span:    syn.Span,
}

type_of :: proc(k: ^Kernel, f: ^Frame, e: Expr) -> Type {
	switch v in e {
	case Set:
		return v
	case Name:
		g := frame_of(f, v.scope)
		return value_type(k, g, v.index)
	case ^Operation:
		args := make([]Type, len(v.args))
		for a, i in v.args do args[i] = type_of(k, f, a)
		return apply(k, v.op, args, v.span)
	case ^Range_Expr:
		return type_range(k, f, v)
	case Invalid:
		return Invalid{}
	}
	return Invalid{}
}

// type_range: l..u is the | of every primitive from l to u, in the order of their
// family (§4.3), whichever bound is written first. A missing bound is infinite;
// the bound '' is the smallest character. A bound that is itself a range gives its
// extremities: `..0..` is every integer. Between strings, `..` is about positions:
//
//   "jwt"..       = "jwt" + string
//   .."lel"       = string + "lel"
//   "jwt".."lel"  = ("jwt" + string) & (string + "lel")
type_range :: proc(k: ^Kernel, f: ^Frame, r: ^Range_Expr) -> Type {
	if !r.ordinal {
		if w, positional, ok := string_range(k, f, r); positional {
			if !ok do return Invalid{}
			return Set{words = w}
		}
	}
	ends, ok := range_ends(k, f, r)
	if !ok do return Invalid{}
	family, has_family := ends.family.?
	if !has_family do return everything()
	switch _ in family {
	case i128:
		lo, has_lo := ends.lo.?
		hi, has_hi := ends.hi.?
		a: Maybe(i128) = has_lo ? Maybe(i128)(lo.(i128)) : nil
		b: Maybe(i128) = has_hi ? Maybe(i128)(hi.(i128)) : nil
		return Set{ints = ints_between(a, b)}
	case f64:
		rr: Real_Range
		if lo, has := ends.lo.?; has do rr.lo = lo.(f64)
		if hi, has := ends.hi.?; has do rr.hi = hi.(f64)
		return Set{reals = reals_of({rr})}
	case string:
		lo, has_lo := ends.lo.?
		hi, has_hi := ends.hi.?
		a: Maybe(i128) = has_lo && lo.(string) != "" ? Maybe(i128)(i128(first_rune(lo.(string)))) : nil
		b: Maybe(i128) = has_hi && hi.(string) != "" ? Maybe(i128)(i128(first_rune(hi.(string)))) : nil
		return Set{words = words_class(ints_between(a, b))}
	case bool:
	}
	return report(k, .Invalid_Range, r.span, "a range is between integers, reals or characters")
}

// string_range: a range between strings, about positions (§4.3). A bound is any
// set of strings, a nested range included: "ab".."cd".."ef" starts with "ab",
// then has "cd", and ends with "ef".
//
//   l..u = (l + string) & (string + u)      l.. = l + string      ..u = string + u
string_range :: proc(k: ^Kernel, f: ^Frame, r: ^Range_Expr) -> (w: ^Words, positional: bool, ok: bool) {
	bounds: [2]Maybe(^Words)
	for e, i in ([2]Expr{r.lo, r.hi}) {
		if e == nil do continue
		t := type_of(k, f, e)
		if is_invalid(t) do return nil, true, false
		s, constant := t.(Set)
		if !constant || set_is_none(s) || !set_subset(s, family_set(.String)) do return nil, false, false
		bounds[i] = set_words(s)
	}
	if bounds[0] == nil && bounds[1] == nil do return nil, false, false
	w = words_all()
	if lo, has := bounds[0].?; has do w = words_and(w, words_cat(lo, words_all()))
	if hi, has := bounds[1].?; has do w = words_and(w, words_cat(words_all(), hi))
	return w, true, true
}

// Ends: the extremities of a range; nil is infinite.
Ends :: struct {
	lo, hi: Maybe(Prim),
	family: Maybe(Prim), // a primitive of the family of the range; nil for `..`
}

// range_ends: the extremities of r. For integers, reals and characters, the
// smallest and the largest of all its ends, whichever is written first; a missing
// bound, or a nested range open on a side, is infinite on that side. Between
// strings, the bounds as written.
range_ends :: proc(k: ^Kernel, f: ^Frame, r: ^Range_Expr) -> (ends: Ends, ok: bool) {
	sides: [2]Maybe(Ends)
	for e, i in ([2]Expr{r.lo, r.hi}) {
		if e == nil do continue
		if inner, nested := e.(^Range_Expr); nested {
			sides[i] = range_ends(k, f, inner) or_return
			continue
		}
		p := range_bound(k, f, e, r.span) or_return
		sides[i] = Ends{p, p, p}
	}
	values := make([dynamic]Prim)
	below, above := r.lo == nil, r.hi == nil // infinite on that side
	for side in sides {
		e := side.? or_continue
		if family, has := e.family.?; has {
			if current, set := ends.family.?; set && !same_family(current, family) {
				report(k, .Invalid_Range, r.span, "the bounds of a range are of two families")
				return {}, false
			}
			ends.family = family
		}
		if lo, has := e.lo.?; has {
			append(&values, lo)
		} else if e.family != nil {
			below = true
		}
		if hi, has := e.hi.?; has {
			append(&values, hi)
		} else if e.family != nil {
			above = true
		}
	}
	if len(values) == 0 do return ends, true
	lo, hi := values[0], values[0]
	for v in values[1:] {
		if prim_less(v, lo) do lo = v
		if prim_less(hi, v) do hi = v
	}
	if !below do ends.lo = lo
	if !above do ends.hi = hi
	return ends, true
}

// prim_less: a < b, two primitives of one family; characters by code point.
prim_less :: proc(a, b: Prim) -> bool {
	switch x in a {
	case i128:
		return x < b.(i128)
	case f64:
		return x < b.(f64)
	case string:
		return first_rune(x) < first_rune(b.(string))
	case bool:
	}
	return false
}

// range_bound: a bound is one primitive.
range_bound :: proc(k: ^Kernel, f: ^Frame, e: Expr, span: syn.Span) -> (Prim, bool) {
	t := type_of(k, f, e)
	if is_invalid(t) do return nil, false
	if s, ok := t.(Set); ok {
		if p, single := set_single(s); single do return p, true
	}
	report(k, .Invalid_Range, span, "a bound of a range is one primitive")
	return nil, false
}

same_family :: proc(a, b: Prim) -> bool {
	switch _ in a {
	case i128:
		_, ok := b.(i128)
		return ok
	case f64:
		_, ok := b.(f64)
		return ok
	case string:
		_, ok := b.(string)
		return ok
	case bool:
		_, ok := b.(bool)
		return ok
	}
	return false
}

first_rune :: proc(s: string) -> rune {
	for c in s do return c
	return 0
}

// everything: `..` alone, every primitive (§4.3).
everything :: proc() -> Set {
	return Set{ints = ints_all(), reals = reals_all(), words = words_chars(), bools = {.False, .True}}
}
