package kernel

// CONSTANT TYPES (specs/types.md §1, §4.1–4.4)
//
// A type without unknowns, in normal form: one component per family of
// primitives. `|`, `&` and `~` act component by component; `~` is the absolute
// complement, so it complements every component. `none`, the empty type, is the
// set whose every component is empty: the zero value.

Bool_Value :: enum u8 {
	False,
	True,
}

Bools :: bit_set[Bool_Value]

Set :: struct {
	ints:   Ints,
	reals:  Reals,
	words:  ^Words, // nil: no string
	bools:  Bools,
	scopes: Scopes,
}

// Prim: a primitive value (§1). A character is a string of length 1.
Prim :: union {
	i128,
	f64,
	string,
	bool,
}

NONE :: Set{}

set_words :: proc(s: Set) -> ^Words {
	return s.words == nil ? words_empty() : s.words
}

set_of :: proc(p: Prim) -> Set {
	switch v in p {
	case i128:
		return Set{ints = ints_point(v)}
	case f64:
		return Set{reals = reals_point(v)}
	case string:
		return Set{words = words_literal(v)}
	case bool:
		return Set{bools = {v ? .True : .False}}
	}
	return NONE
}

set_bool :: proc(b: bool) -> Set {
	return set_of(b)
}

// set_everything: `~none`, every value.
set_everything :: proc() -> Set {
	return set_complement(NONE)
}

set_union :: proc(a, b: Set) -> Set {
	return Set {
		ints = ints_union(a.ints, b.ints),
		reals = reals_union(a.reals, b.reals),
		words = words_alt(set_words(a), set_words(b)),
		bools = a.bools | b.bools,
		scopes = scopes_union(a.scopes, b.scopes),
	}
}

set_intersect :: proc(a, b: Set) -> Set {
	return Set {
		ints = ints_intersect(a.ints, b.ints),
		reals = reals_intersect(a.reals, b.reals),
		words = words_and(set_words(a), set_words(b)),
		bools = a.bools & b.bools,
		scopes = scopes_intersect(a.scopes, b.scopes),
	}
}

set_complement :: proc(a: Set) -> Set {
	return Set {
		ints = ints_complement(a.ints),
		reals = reals_complement(a.reals),
		words = words_not(set_words(a)),
		bools = ~a.bools,
		scopes = scopes_complement(a.scopes),
	}
}

set_is_none :: proc(a: Set) -> bool {
	return(
		ints_empty(a.ints) &&
		reals_empty(a.reals) &&
		words_is_empty(set_words(a)) &&
		a.bools == {} &&
		scopes_empty(a.scopes) \
	)
}

set_subset :: proc(a, b: Set) -> bool {
	return set_is_none(set_intersect(a, set_complement(b)))
}

set_equal :: proc(a, b: Set) -> bool {
	return(
		ints_equal(a.ints, b.ints) &&
		reals_equal(a.reals, b.reals) &&
		words_equal(set_words(a), set_words(b)) &&
		a.bools == b.bools &&
		scopes_equal(a.scopes, b.scopes) \
	)
}

set_has :: proc(a: Set, p: Prim) -> bool {
	switch v in p {
	case i128:
		return ints_contains(a.ints, v)
	case f64:
		return reals_contains(a.reals, v)
	case string:
		return words_contains(set_words(a), v)
	case bool:
		return (v ? Bool_Value.True : Bool_Value.False) in a.bools
	}
	return false
}

// set_single: the only element of a, when a is one primitive.
set_single :: proc(a: Set) -> (p: Prim, ok: bool) {
	found := 0
	if !ints_empty(a.ints) {
		v, single := ints_single(a.ints)
		if !single do return nil, false
		p, found = v, found + 1
	}
	if !reals_empty(a.reals) {
		v, single := reals_single(a.reals)
		if !single do return nil, false
		p, found = v, found + 1
	}
	if w := set_words(a); !words_is_empty(w) {
		v, single := words_single(w)
		if !single do return nil, false
		p, found = v, found + 1
	}
	switch a.bools {
	case {.True}:
		p, found = true, found + 1
	case {.False}:
		p, found = false, found + 1
	case {.False, .True}:
		return nil, false
	}
	if !scopes_empty(a.scopes) do return nil, false
	return p, found == 1
}

// The families of primitives (§4.5): the sets an operator accepts.
Family :: enum u8 {
	Int,
	Real,
	String,
	Char,
	Bool,
	Count, // an integer ≥ 0: the count of a repetition
	Nonzero_Int, // a divisor: int & ~0
	Nonzero_Real, // float & ~0.0
}

family_set :: proc(f: Family) -> Set {
	switch f {
	case .Int:
		return Set{ints = ints_all()}
	case .Real:
		return Set{reals = reals_all()}
	case .String:
		return Set{words = words_all()}
	case .Char:
		return Set{words = words_chars()}
	case .Bool:
		return Set{bools = {.False, .True}}
	case .Count:
		return Set{ints = ints_between(0, nil)}
	case .Nonzero_Int:
		return Set{ints = ints_complement(ints_point(0))}
	case .Nonzero_Real:
		return Set{reals = reals_complement(reals_point(0))}
	}
	return NONE
}
