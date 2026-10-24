package kernel

import "core:slice"

// CONSTANT TYPES (specs/types.md §4.1–4.4, §4.6)
//
// A constant type — a term without unknown — is read family by family (Reading):
// its integers, its reals, its strings (characters included), its booleans, its
// scopes. The laws of | & ~ act on each family; ~ is the absolute complement, so
// it complements every family. The reading decides whether a constant type is
// empty, in another, equal to another — three-valued: a reading that is not exact
// decides nothing. The normal form of a constant combination is rebuilt from its
// reading, as terms of the grammar.

Bool_Value :: enum u8 {
	False,
	True,
}

Bools :: bit_set[Bool_Value]

Reading :: struct {
	ints:       Ints,
	reals:      Reals,
	words:      ^Words,
	bools:      Bools,
	scopes:     [dynamic]Type, // scope values, or shapes, held as they are
	all_scopes: bool, // every scope: from a complement
	exact:      bool,
}

// Truth: what a decision answers. Unknown is never taken for true.
Truth :: enum u8 {
	False,
	True,
	Unknown,
}

truth :: proc(b: bool) -> Truth {
	return b ? .True : .False
}

reading_none :: proc() -> Reading {
	return Reading{words = words_empty(), exact = true}
}

// read: the reading of a constant term.
read :: proc(k: ^Kernel, t: Type) -> Reading {
	r := reading_none()
	switch v in t {
	case Char:
		r.words = words_char(rune(v))
	case Int:
		r.ints = slice.clone(Ints{{i128(v), i128(v)}})
	case Real:
		r.reals = slice.clone(Reals{{lo = f64(v), hi = f64(v)}})
	case Bool:
		r.bools = {bool(v) ? .True : .False}
	case None:
	case ^Or:
		for term in v.terms do r = reading_union(r, read(k, term))
	case ^And:
		r = read(k, v.terms[0])
		for term in v.terms[1:] do r = reading_intersect(k, r, read(k, term))
	case ^Not:
		r = reading_complement(read(k, v.term))
	case ^Range:
		r = read_range(v)
	case ^Is:
		if is_primitive(v.term) do return read(k, v.term)
		append(&r.scopes, t) // a set taken as a value: one value, held as it is
	case ^Operation:
		r = read_operation(k, v)
	case ^Scope:
		append(&r.scopes, t)
	case ^Unknown, ^Name, ^Access, ^Collapse, ^Carve, ^Default, ^Pattern, Invalid:
		r.exact = false
	}
	return r
}

read_range :: proc(v: ^Range) -> Reading {
	r := reading_none()
	family := v.lo != nil ? v.lo : v.hi
	#partial switch b in family {
	case Int:
		lo, hi: Maybe(i128)
		if x, ok := v.lo.(Int); ok do lo = i128(x)
		if x, ok := v.hi.(Int); ok do hi = i128(x)
		r.ints = ints_of({{lo, hi}})
	case Real:
		rr: Real_Range
		if x, ok := v.lo.(Real); ok do rr.lo = f64(x)
		if x, ok := v.hi.(Real); ok do rr.hi = f64(x)
		r.reals = reals_of({rr})
	case Char:
		lo, hi: Maybe(i128)
		if x, ok := v.lo.(Char); ok do lo = i128(x)
		if x, ok := v.hi.(Char); ok do hi = i128(x)
		r.words = words_class(ints_of({{lo, hi}}))
	case:
		if v.lo != nil || v.hi != nil {
			r.exact = false
			return r
		}
		switch v.family {
		case .Int:
			r.ints = slice.clone(Ints{{nil, nil}})
		case .Real:
			r.reals = slice.clone(Reals{{}})
		case .Any:
			// `..`: every primitive
			r.ints, r.reals, r.words, r.bools = slice.clone(Ints{{nil, nil}}), slice.clone(Reals{{}}), words_chars(), {.False, .True}
		}
	}
	return r
}

// read_operation: an operation left as it is on constants: the strings it builds
// (concatenation, repetition) are a reading; another image is not.
read_operation :: proc(k: ^Kernel, v: ^Operation) -> Reading {
	r := reading_none()
	#partial switch v.op {
	case .Add:
		w := words_epsilon()
		for a in v.args {
			x := read(k, a)
			if !x.exact || !reading_only_words(x) {
				r.exact = false
				return r
			}
			w = words_cat(w, x.words)
		}
		r.words = w
		return r
	case .Mul:
		x, n := read(k, v.args[0]), read(k, v.args[1])
		if x.exact && n.exact && reading_only_words(x) && reading_only_ints(n) {
			r.words = words_repeat(x.words, n.ints)
			return r
		}
	}
	r.exact = false
	return r
}

reading_only_words :: proc(r: Reading) -> bool {
	return len(r.ints) == 0 && len(r.reals) == 0 && r.bools == {} && len(r.scopes) == 0 && !r.all_scopes
}

reading_only_ints :: proc(r: Reading) -> bool {
	return len(r.reals) == 0 && words_is_empty(r.words) && r.bools == {} && len(r.scopes) == 0 && !r.all_scopes
}

reading_union :: proc(a, b: Reading) -> Reading {
	r := Reading {
		ints       = ints_union(a.ints, b.ints),
		reals      = reals_union(a.reals, b.reals),
		words      = words_alt(a.words, b.words),
		bools      = a.bools | b.bools,
		all_scopes = a.all_scopes || b.all_scopes,
		exact      = a.exact && b.exact,
	}
	append(&r.scopes, ..a.scopes[:])
	append(&r.scopes, ..b.scopes[:])
	return r
}

reading_intersect :: proc(k: ^Kernel, a, b: Reading) -> Reading {
	r := Reading {
		ints   = ints_intersect(a.ints, b.ints),
		reals  = reals_intersect(a.reals, b.reals),
		words  = words_and(a.words, b.words),
		bools  = a.bools & b.bools,
		exact  = a.exact && b.exact,
		all_scopes = a.all_scopes && b.all_scopes,
	}
	// scopes: those of one side that the other holds; two distinct scopes held as
	// they are may still share elements (two shapes): not exact
	switch {
	case a.all_scopes:
		append(&r.scopes, ..b.scopes[:])
	case b.all_scopes:
		append(&r.scopes, ..a.scopes[:])
	case:
		// two scopes have in common what is held by both; two shapes of different
		// structures, nothing (§5.4); otherwise it is not read here
		for x in a.scopes {
			for y in b.scopes {
				if same(k, x, y) {
					append(&r.scopes, x)
				} else if !different_structures(k, x, y) {
					r.exact = false
				}
			}
		}
	}
	return r
}

reading_complement :: proc(a: Reading) -> Reading {
	r := Reading {
		ints       = ints_complement(a.ints, {nil, nil}),
		reals      = reals_complement(a.reals),
		words      = words_not(a.words),
		bools      = ~a.bools,
		all_scopes = !a.all_scopes,
		exact      = a.exact && len(a.scopes) == 0, // ~{0}: every scope but one, not held here
	}
	return r
}

reading_is_empty :: proc(r: Reading) -> bool {
	return len(r.ints) == 0 && len(r.reals) == 0 && words_is_empty(r.words) && r.bools == {} && len(r.scopes) == 0 && !r.all_scopes
}

// --- decisions on constant types ---

// empty: the constant type t has no element.
empty :: proc(k: ^Kernel, t: Type) -> Truth {
	r := read(k, t)
	if !r.exact do return .Unknown
	return truth(reading_is_empty(r))
}

// subset: every element of a is in b.
subset :: proc(k: ^Kernel, a, b: Type) -> Truth {
	r := reading_intersect(k, read(k, a), reading_complement(read(k, b)))
	if !r.exact do return .Unknown
	return truth(reading_is_empty(r))
}

// disjoint: a and b have no element in common.
disjoint :: proc(k: ^Kernel, a, b: Type) -> Truth {
	r := reading_intersect(k, read(k, a), read(k, b))
	if !r.exact do return .Unknown
	return truth(reading_is_empty(r))
}

// --- normal forms of constant combinations ---

// rebuild: the normal form of a reading, as a term: the | of the integers, the
// reals, the strings, the booleans and the scopes it holds. A reading that holds
// every scope comes from a complement: it is written ~ of its complement.
rebuild :: proc(k: ^Kernel, r: Reading) -> Type {
	if r.all_scopes do return new_not(rebuild(k, reading_complement(r)))
	parts := make([dynamic]Type)
	for x in r.ints do append(&parts, int_range_term(x))
	for x in r.reals do append(&parts, real_range_term(x))
	if !words_is_empty(r.words) do append(&parts, words_term(r.words))
	if .False in r.bools do append(&parts, Bool(false))
	if .True in r.bools do append(&parts, Bool(true))
	append(&parts, ..r.scopes[:])
	switch len(parts) {
	case 0:
		return None{}
	case 1:
		return parts[0]
	}
	return new_or(..parts[:])
}

int_range_term :: proc(x: Int_Range) -> Type {
	lo, has_lo := x.lo.?
	hi, has_hi := x.hi.?
	if has_lo && has_hi && lo == hi do return Int(lo)
	return new_range(has_lo ? Type(Int(lo)) : nil, has_hi ? Type(Int(hi)) : nil, .Int)
}

real_range_term :: proc(x: Real_Range) -> Type {
	lo, has_lo := x.lo.?
	hi, has_hi := x.hi.?
	if has_lo && has_hi && lo == hi do return Real(lo)
	t := new_range(has_lo ? Type(Real(lo)) : nil, has_hi ? Type(Real(hi)) : nil, .Real)
	// an open bound: >t = t.. & ~t (§4.3)
	terms := make([dynamic]Type)
	append(&terms, t)
	if x.lo_open do append(&terms, new_not(Real(lo)))
	if x.hi_open do append(&terms, new_not(Real(hi)))
	return len(terms) == 1 ? t : new_and(..terms[:])
}

// words_term: a set of strings as a term: characters, ranges of characters, + for
// a concatenation, * for a repetition, | & of them; the complement within the
// strings is `string & ~x`.
words_term :: proc(w: ^Words) -> Type {
	switch w.kind {
	case .Empty:
		return None{}
	case .Epsilon:
		return empty_string()
	case .Class:
		parts := make([dynamic]Type)
		for r in w.class {
			lo, _ := r.lo.?
			hi, _ := r.hi.?
			if lo == hi {
				append(&parts, Char(rune(lo)))
			} else {
				append(&parts, new_range(Char(rune(lo)), hi == MAX_RUNE ? nil : Type(Char(rune(hi)))))
			}
		}
		return len(parts) == 1 ? parts[0] : new_or(..parts[:])
	case .Cat:
		parts := make([dynamic]Type)
		x := w
		for x.kind == .Cat {
			append(&parts, words_term(x.args[0]))
			x = x.args[1]
		}
		append(&parts, words_term(x))
		return concatenation(parts[:])
	case .Alt, .And:
		parts := make([]Type, len(w.args))
		for a, i in w.args do parts[i] = words_term(a)
		return w.kind == .Alt ? new_or(..parts) : new_and(..parts)
	case .Not:
		if w.args[0].kind == .Empty do return string_term()
		return new_and(string_term(), new_not(words_term(w.args[0])))
	case .Repeat:
		counts := make([dynamic]Type)
		for c in w.counts do append(&counts, int_range_term(c))
		count := len(counts) == 1 ? counts[0] : new_or(..counts[:])
		return new_operation(.Mul, words_term(w.args[0]), count)
	}
	return None{}
}

// string_term: every string, ''.. * 0.. (§3).
string_term :: proc() -> Type {
	return new_operation(.Mul, new_range(Char(0), nil), new_range(Int(0), nil, .Int))
}

// is_constant: a term without unknown, name, or operation left on a scope.
is_constant :: proc(t: Type) -> bool {
	switch v in t {
	case Char, Int, Real, Bool, None, ^Scope:
		return true
	case ^Or:
		for x in v.terms do if !is_constant(x) do return false
		return true
	case ^And:
		for x in v.terms do if !is_constant(x) do return false
		return true
	case ^Not:
		return is_constant(v.term)
	case ^Is:
		return is_constant(v.term)
	case ^Range:
		return (v.lo == nil || is_constant(v.lo)) && (v.hi == nil || is_constant(v.hi))
	case ^Operation:
		for x in v.args do if !is_constant(x) do return false
		return true
	case ^Unknown, ^Name, ^Access, ^Collapse, ^Carve, ^Default, ^Pattern, Invalid:
	}
	return false
}

sort_types :: proc(ts: []Type) {
	slice.sort_by(ts, proc(a, b: Type) -> bool {return print_type(a) < print_type(b)})
}
