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
	^Unknown_Expr,
	^Scope, // a scope literal
	^Access_Expr,
	^Collapse_Expr,
	^Carve_Expr,
	^Default_Expr,
	Invalid, // an error already reported
}

// Access_Expr: `target.name`, `target.name#n`.
Access_Expr :: struct {
	target:  Expr,
	name:    string,
	ordinal: int, // -1: the last occurrence
	span:    syn.Span,
}

// Collapse_Expr: `target!`.
Collapse_Expr :: struct {
	target: Expr,
	span:   syn.Span,
}

// Carve_Expr: `target{args}`: the arguments are written where the carve is.
Carve_Expr :: struct {
	target: Expr,
	args:   []Carve_Arg_Expr,
	span:   syn.Span,
}

Carve_Arg_Expr :: struct {
	name:    string,
	ordinal: int,
	value:   Expr,
	span:    syn.Span,
}

// Default_Expr: `C:` in a value: an anonymous binding colored by C, complete with
// the default of C (specs/language/11, 12).
Default_Expr :: struct {
	color: Expr,
	span:  syn.Span,
}

// Unknown_Expr: `??` or `??::L`. Without a layout, `C:x -> ??` takes the layout of
// its color; elsewhere, it is any primitive.
Unknown_Expr :: struct {
	layout: Expr,
	span:   syn.Span,
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
	case ^Unknown_Expr:
		return new_unknown(k, v.layout == nil ? Type(everything()) : type_of(k, f, v.layout))
	case ^Scope:
		return literal_frame(k, v, f)
	case ^Access_Expr:
		return access(k, type_of(k, f, v.target), v.name, v.ordinal, v.span)
	case ^Collapse_Expr:
		return collapse(k, type_of(k, f, v.target), v.span)
	case ^Carve_Expr:
		target := type_of(k, f, v.target)
		args := make([]Carve_Arg, len(v.args))
		for a, i in v.args do args[i] = Carve_Arg{a.name, a.ordinal, type_of(k, f, a.value), a.span}
		return carve(k, target, args, v.span)
	case ^Default_Expr:
		return default_of(k, type_of(k, f, v.color))
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
	if dependent, ok := dependent_range(k, f, r); ok do return dependent
	ends, ok := range_ends(k, f, r)
	if !ok do return Invalid{}
	family, has_family := ends.family.?
	if !has_family do return everything()
	return range_set(k, ends.lo, ends.hi, family, r.span)
}

// range_set: every primitive from lo to hi, nil being infinite; between
// strings, the characters (ordinal).
range_set :: proc(k: ^Kernel, lo, hi: Maybe(Prim), family: Prim, span: syn.Span) -> Type {
	x, has_lo := lo.?
	y, has_hi := hi.?
	if has_lo && has_hi {
		if !same_family(x, y) do return report(k, .Invalid_Range, span, "the bounds of a range are of two families")
		if prim_less(y, x) do x, y = y, x
	}
	switch v in family {
	case i128:
		a, b: Maybe(i128)
		if has_lo do a = x.(i128)
		if has_hi do b = y.(i128)
		return Set{ints = ints_between(a, b)}
	case f64:
		rr: Real_Range
		if has_lo do rr.lo = x.(f64)
		if has_hi do rr.hi = y.(f64)
		return Set{reals = reals_of({rr})}
	case string:
		a, b: Maybe(i128)
		if has_lo && x.(string) != "" do a = i128(first_rune(x.(string)))
		if has_hi && y.(string) != "" do b = i128(first_rune(y.(string)))
		return Set{words = words_class(ints_between(a, b))}
	case bool:
	}
	return report(k, .Invalid_Range, span, "a range is between integers, reals or characters")
}

// dependent_range: a range whose bound depends on unknowns, `0..n` with n
// unknown: an operation of the algebra, computed once its bounds are known.
dependent_range :: proc(k: ^Kernel, f: ^Frame, r: ^Range_Expr) -> (Type, bool) {
	bounds := [2]Expr{r.lo, r.hi}
	types: [2]Type
	dependent := false
	for e, i in bounds {
		if e == nil do continue
		if _, nested := e.(^Range_Expr); nested do return nil, false
		types[i] = type_of(k, f, e)
		if is_invalid(types[i]) do return Invalid{}, true
		if _, constant := types[i].(Set); !constant do dependent = true
	}
	if !dependent do return nil, false
	switch {
	case r.lo != nil && r.hi != nil:
		return apply(k, .Range, {types[0], types[1]}, r.span), true
	case r.lo != nil:
		return apply(k, .Range_From, {types[0]}, r.span), true
	}
	return apply(k, .Range_To, {types[1]}, r.span), true
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
