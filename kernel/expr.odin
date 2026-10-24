package kernel

import syn "../compiler"

// THE PROGRAM AS WRITTEN
//
// An expression is a type of the algebra as it is written (specs/types.md §2),
// names included. type_of puts it in normal form in a frame: a name becomes the
// type of its binding (§5.2), each operation is applied by its laws.

Expr :: union {
	Set, // a literal or an alias of the prelude
	Name,
	^Operation,
	^Range_Expr,
	^Unknown_Expr,
	^Scope, // a scope literal
	^Access_Expr,
	^Collapse_Expr,
	^Carve_Expr,
	^Default_Expr,
	^Match_Expr,
	Invalid, // an error already reported
}

// Name: a binding, the last occurrence visible where the name is written. `self`:
// the scope being defined, named from one of its productions (§5.6).
Name :: struct {
	scope: ^Scope,
	index: int,
	self:  bool,
	span:  syn.Span,
}

Operation :: struct {
	op:   Op,
	args: []Expr,
	span: syn.Span,
}

// Range_Expr: `lo..hi`, a bound may be missing (§4.3). Between characters written
// between apostrophes, the range is over the characters; between strings, over
// the positions.
Range_Expr :: struct {
	lo, hi:  Expr,
	ordinal: bool,
	span:    syn.Span,
}

// Unknown_Expr: `??` or `??::L`. Without a layout, `C:x -> ??` takes its color;
// elsewhere it is any primitive.
Unknown_Expr :: struct {
	layout: Expr,
	span:   syn.Span,
}

Access_Expr :: struct {
	target:  Expr,
	name:    string,
	ordinal: int, // -1: the last occurrence
	span:    syn.Span,
}

// Collapse_Expr: `target!`. `recursive`: the target is the scope being defined,
// named from its production: a recursive call, which stays an equation.
Collapse_Expr :: struct {
	target:    Expr,
	recursive: bool,
	span:      syn.Span,
}

Carve_Expr :: struct {
	target: Expr,
	args:   []Carve_Arg_Expr,
	span:   syn.Span,
}

Carve_Arg_Expr :: struct {
	name:    string, // "" for a positional argument
	ordinal: int,
	value:   Expr,
	span:    syn.Span,
}

// Default_Expr: `C:` as a value: an anonymous binding colored by C, complete with
// the default of C.
Default_Expr :: struct {
	color: Expr,
	span:  syn.Span,
}

is_invalid_expr :: proc(e: Expr) -> bool {
	if e == nil do return true
	_, ok := e.(Invalid)
	return ok
}

type_of :: proc(k: ^Kernel, f: ^Frame, e: Expr) -> Type {
	switch v in e {
	case Set:
		return v
	case Name:
		return value_type(k, frame_of(f, v.scope), v.index)
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
		target := type_of(k, f, v.target)
		if v.recursive {
			g, is_frame := target.(^Frame)
			if !is_frame do return collapse(k, target, v.span)
			return new_apply(.Recur, g) // never unfolded (§5.6)
		}
		return collapse(k, target, v.span)
	case ^Carve_Expr:
		target := type_of(k, f, v.target)
		args := make([]Carve_Arg, len(v.args))
		for a, i in v.args do args[i] = Carve_Arg{a.name, a.ordinal, type_of(k, f, a.value), a.span}
		return carve(k, target, args, v.span)
	case ^Default_Expr:
		return default_of(k, type_of(k, f, v.color))
	case ^Match_Expr:
		return type_match(k, f, v)
	case Invalid:
		return Invalid{}
	}
	return Invalid{}
}

// type_range: l..u is the | of every primitive from l to u in the order of their
// family, whichever bound is written first (§4.3). A missing bound is infinite;
// '' as a bound is the smallest character; a bound that is itself a range gives
// its extremities (`..0..` is every integer). Between strings, about positions:
//
//   l..u = (l + string) & (string + u)      l.. = l + string      ..u = string + u
//
// A bound that depends on unknowns leaves the range an operation: 0..n.
type_range :: proc(k: ^Kernel, f: ^Frame, r: ^Range_Expr) -> Type {
	types: [2]Type
	nested := false
	for e, i in ([2]Expr{r.lo, r.hi}) {
		if e == nil do continue
		if _, is_range := e.(^Range_Expr); is_range do nested = true
		types[i] = type_of(k, f, e)
		if is_invalid(types[i]) do return Invalid{}
	}
	if !r.ordinal {
		strings_only := true
		any := false
		for t in types do if t != nil {
			any = true
			s, constant := t.(Set)
			strings_only &&= constant && !set_is_none(s) && set_subset(s, family_set(.String))
		}
		if any && strings_only {
			w := words_all()
			if types[0] != nil do w = words_and(w, words_cat(set_words(types[0].(Set)), words_all()))
			if types[1] != nil do w = words_and(w, words_cat(words_all(), set_words(types[1].(Set))))
			return Set{words = w}
		}
	}
	if !nested {
		dependent := false
		for t in types do if t != nil && !is_constant(t) do dependent = true
		if dependent {
			switch {
			case r.lo != nil && r.hi != nil:
				return apply(k, .Range, {types[0], types[1]}, r.span)
			case r.lo != nil:
				return apply(k, .Range_From, {types[0]}, r.span)
			}
			return apply(k, .Range_To, {types[1]}, r.span)
		}
	}
	ends, ok := range_ends(k, f, r)
	if !ok do return Invalid{}
	family, has_family := ends.family.?
	if !has_family do return everything()
	return range_set(k, ends.lo, ends.hi, family, r.span)
}

// range_set: every primitive from lo to hi, nil being infinite; between strings,
// the characters.
range_set :: proc(k: ^Kernel, lo, hi: Maybe(Prim), family: Prim, span: syn.Span) -> Type {
	x, has_lo := lo.?
	y, has_hi := hi.?
	if has_lo && has_hi {
		if !same_family(x, y) do return report(k, .Invalid_Range, span, "the bounds of a range are of two families")
		if prim_less(y, x) do x, y = y, x
	}
	switch _ in family {
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

// Ends: the extremities of a range; nil is infinite.
Ends :: struct {
	lo, hi: Maybe(Prim),
	family: Maybe(Prim), // a primitive of the family of the range; nil for `..`
}

// range_ends: the smallest and the largest of all the ends of r; a missing bound,
// or a nested range open on a side, is infinite on that side.
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
	below, above := r.lo == nil, r.hi == nil
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
