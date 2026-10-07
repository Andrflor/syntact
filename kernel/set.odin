package kernel

import "core:slice"

// Les ensembles de valeurs atomiques, sous forme canonique. Un littéral est un
// ensemble à un élément (`5` est `5..5`), un builtin est un ensemble (`u8` est
// `0..255`), `none` est l'ensemble vide. Un ensemble mixte (`u8 | string`) a une
// composante canonique par sorte ; chaque composante est une algèbre close.
// Deux ensembles égaux ont la même structure, quelle que soit leur écriture :
// `2|1` et `2..1` sont `1..2`, `2|"a"|3..4` et `"a"|2..4` sont `2..4 | "a"`.

Domain :: enum u8 {
	Ints,
	Floats,
	Chars,
	Strings,
	Bools,
}

Set :: struct {
	ints:    Ints,
	floats:  Floats,
	// Les caractères, par leur point de code ; CHAR_EMPTY est le caractère vide `''`,
	// le plus bas de tous. Une couleur `string` admet un caractère comme la chaîne
	// d'une lettre (`string:s -> 'c'`), mais `'a'` et `"a"` restent deux valeurs.
	chars:   Ints,
	strings: Strings,
	bools:   Bools,
}

// --- entiers : intervalles triés, disjoints, non adjacents ---

Int_Interval :: struct {
	lo: Maybe(i128), // nil = -∞
	hi: Maybe(i128), // nil = +∞
}

Ints :: struct {
	intervals: []Int_Interval,
}

ints_point :: proc(v: i128) -> Ints {
	return ints_of({Int_Interval{v, v}})
}

ints_range :: proc(lo, hi: Maybe(i128)) -> Ints {
	return ints_of({Int_Interval{lo, hi}})
}

ints_all :: proc() -> Ints {
	return ints_range(nil, nil)
}

// ints_of normalise une liste quelconque d'intervalles.
ints_of :: proc(raw: []Int_Interval) -> Ints {
	kept := make([dynamic]Int_Interval, 0, len(raw))
	for iv in raw {
		lo, lo_ok := iv.lo.?
		hi, hi_ok := iv.hi.?
		if lo_ok && hi_ok && lo > hi do continue
		append(&kept, iv)
	}
	slice.sort_by(kept[:], proc(a, b: Int_Interval) -> bool {
		al, a_ok := a.lo.?
		bl, b_ok := b.lo.?
		if !a_ok do return b_ok
		if !b_ok do return false
		return al < bl
	})
	out := make([dynamic]Int_Interval, 0, len(kept))
	for iv in kept {
		if len(out) == 0 {
			append(&out, iv)
			continue
		}
		last := &out[len(out) - 1]
		last_hi, last_bounded := last.hi.?
		if !last_bounded do break // le dernier va déjà jusqu'à +∞
		lo, lo_ok := iv.lo.?
		if !lo_ok || lo <= last_hi + 1 {
			hi, hi_ok := iv.hi.?
			if !hi_ok || hi > last_hi do last.hi = iv.hi
		} else {
			append(&out, iv)
		}
	}
	return Ints{out[:]}
}

ints_union :: proc(a, b: Ints) -> Ints {
	all := make([dynamic]Int_Interval, 0, len(a.intervals) + len(b.intervals))
	append(&all, ..a.intervals)
	append(&all, ..b.intervals)
	return ints_of(all[:])
}

ints_intersect :: proc(a, b: Ints) -> Ints {
	out := make([dynamic]Int_Interval)
	for x in a.intervals {
		for y in b.intervals {
			append(&out, Int_Interval{max_lo(x.lo, y.lo), min_hi(x.hi, y.hi)})
		}
	}
	return ints_of(out[:])
}

ints_complement :: proc(a: Ints) -> Ints {
	out := make([dynamic]Int_Interval)
	cursor: Maybe(i128) = nil // début du trou courant ; nil = -∞
	open := true // le trou courant est encore ouvert
	for iv in a.intervals {
		if lo, ok := iv.lo.?; ok {
			append(&out, Int_Interval{cursor, lo - 1})
		}
		hi, ok := iv.hi.?
		if !ok {
			open = false
			break
		}
		cursor = hi + 1
	}
	if open do append(&out, Int_Interval{cursor, nil})
	return ints_of(out[:])
}

ints_subset :: proc(a, b: Ints) -> bool {
	return len(ints_intersect(a, ints_complement(b)).intervals) == 0
}

// ints_count compte les éléments, saturé à 2 (on ne veut savoir que 0, 1 ou plusieurs).
ints_count :: proc(a: Ints) -> int {
	if len(a.intervals) == 0 do return 0
	if len(a.intervals) > 1 do return 2
	lo, lo_ok := a.intervals[0].lo.?
	hi, hi_ok := a.intervals[0].hi.?
	return lo_ok && hi_ok && lo == hi ? 1 : 2
}

ints_contains :: proc(a: Ints, v: i128) -> bool {
	for iv in a.intervals {
		if lo, ok := iv.lo.?; ok && v < lo do continue
		if hi, ok := iv.hi.?; ok && v > hi do continue
		return true
	}
	return false
}

// Le défaut d'un ensemble d'entiers : 0 s'il y est, sinon sa première borne finie.
ints_default :: proc(a: Ints) -> (i128, bool) {
	if len(a.intervals) == 0 do return 0, false
	if ints_contains(a, 0) do return 0, true
	if lo, ok := a.intervals[0].lo.?; ok do return lo, true
	hi, _ := a.intervals[0].hi.?
	return hi, true
}

ints_bounds :: proc(a: Ints) -> (lo, hi: Maybe(i128)) {
	if len(a.intervals) == 0 do return nil, nil
	return a.intervals[0].lo, a.intervals[len(a.intervals) - 1].hi
}

// Arithmétique d'intervalles : { x op y | x ∈ a, y ∈ b }, sur-approximée par intervalle.
ints_arith :: proc(op: Arith, a, b: Ints) -> Ints {
	out := make([dynamic]Int_Interval)
	for x in a.intervals {
		for y in b.intervals {
			switch op {
			case .Add:
				append(&out, Int_Interval{add_bound(x.lo, y.lo), add_bound(x.hi, y.hi)})
			case .Sub:
				append(&out, Int_Interval{add_bound(x.lo, neg_bound(y.hi)), add_bound(x.hi, neg_bound(y.lo))})
			case .Mul:
				append(&out, mul_interval(x, y))
			}
		}
	}
	return ints_of(out[:])
}

ints_neg :: proc(a: Ints) -> Ints {
	out := make([dynamic]Int_Interval, 0, len(a.intervals))
	for iv in a.intervals do append(&out, Int_Interval{neg_bound(iv.hi), neg_bound(iv.lo)})
	return ints_of(out[:])
}

Arith :: enum u8 {
	Add,
	Sub,
	Mul,
}

I128_MAX :: max(i128)
I128_MIN :: min(i128)

max_lo :: proc(a, b: Maybe(i128)) -> Maybe(i128) {
	x, x_ok := a.?
	y, y_ok := b.?
	if !x_ok do return b
	if !y_ok do return a
	return max(x, y)
}

min_hi :: proc(a, b: Maybe(i128)) -> Maybe(i128) {
	x, x_ok := a.?
	y, y_ok := b.?
	if !x_ok do return b
	if !y_ok do return a
	return min(x, y)
}

neg_bound :: proc(a: Maybe(i128)) -> Maybe(i128) {
	if v, ok := a.?; ok do return -v
	return nil
}

// Une somme qui déborde i128 devient infinie : c'est une sur-approximation sûre.
add_bound :: proc(a, b: Maybe(i128)) -> Maybe(i128) {
	x, x_ok := a.?
	y, y_ok := b.?
	if !x_ok || !y_ok do return nil
	if y > 0 && x > I128_MAX - y do return nil
	if y < 0 && x < I128_MIN - y do return nil
	return x + y
}

mul_interval :: proc(x, y: Int_Interval) -> Int_Interval {
	xl, xl_ok := x.lo.?
	xh, xh_ok := x.hi.?
	yl, yl_ok := y.lo.?
	yh, yh_ok := y.hi.?
	// Un facteur exactement nul annule tout, même un intervalle infini.
	if (xl_ok && xh_ok && xl == 0 && xh == 0) || (yl_ok && yh_ok && yl == 0 && yh == 0) {
		return Int_Interval{i128(0), i128(0)}
	}
	if !(xl_ok && xh_ok && yl_ok && yh_ok) do return Int_Interval{nil, nil}
	lo, hi := I128_MAX, I128_MIN
	for p in ([4][2]i128{{xl, yl}, {xl, yh}, {xh, yl}, {xh, yh}}) {
		v, ok := mul_checked(p[0], p[1])
		if !ok do return Int_Interval{nil, nil}
		lo, hi = min(lo, v), max(hi, v)
	}
	return Int_Interval{lo, hi}
}

mul_checked :: proc(a, b: i128) -> (i128, bool) {
	if a == 0 || b == 0 do return 0, true
	r := a * b
	if r / b != a do return 0, false
	return r, true
}

// --- flottants : intervalles à bornes ouvertes ou fermées ---

Float_Interval :: struct {
	lo:      Maybe(f64), // nil = -∞
	hi:      Maybe(f64), // nil = +∞
	lo_open: bool,
	hi_open: bool,
}

Floats :: struct {
	intervals: []Float_Interval,
}

floats_point :: proc(v: f64) -> Floats {
	return floats_of({Float_Interval{lo = v, hi = v}})
}

floats_all :: proc() -> Floats {
	return floats_of({Float_Interval{}})
}

// Une forme canonique n'a qu'un zéro : -0.0 s'écrit 0.0.
canonical_zero :: proc(b: Maybe(f64)) -> Maybe(f64) {
	if v, ok := b.?; ok && v == 0 do return f64(0)
	return b
}

float_interval_empty :: proc(iv: Float_Interval) -> bool {
	lo, lo_ok := iv.lo.?
	hi, hi_ok := iv.hi.?
	if !lo_ok || !hi_ok do return false
	return lo > hi || (lo == hi && (iv.lo_open || iv.hi_open))
}

floats_of :: proc(raw: []Float_Interval) -> Floats {
	kept := make([dynamic]Float_Interval, 0, len(raw))
	for iv in raw {
		if float_interval_empty(iv) do continue
		append(&kept, Float_Interval{canonical_zero(iv.lo), canonical_zero(iv.hi), iv.lo_open, iv.hi_open})
	}
	slice.sort_by(kept[:], proc(a, b: Float_Interval) -> bool {
		al, a_ok := a.lo.?
		bl, b_ok := b.lo.?
		if !a_ok do return b_ok
		if !b_ok do return false
		if al != bl do return al < bl
		return !a.lo_open && b.lo_open
	})
	out := make([dynamic]Float_Interval, 0, len(kept))
	for iv in kept {
		if len(out) == 0 {
			append(&out, iv)
			continue
		}
		last := &out[len(out) - 1]
		last_hi, last_bounded := last.hi.?
		if !last_bounded do break
		lo, lo_ok := iv.lo.?
		touches := !lo_ok || lo < last_hi || (lo == last_hi && !(last.hi_open && iv.lo_open))
		if !touches {
			append(&out, iv)
			continue
		}
		hi, hi_ok := iv.hi.?
		if !hi_ok {
			last.hi, last.hi_open = nil, false
		} else if hi > last_hi || (hi == last_hi && !iv.hi_open) {
			last.hi, last.hi_open = hi, iv.hi_open
		}
	}
	return Floats{out[:]}
}

floats_union :: proc(a, b: Floats) -> Floats {
	all := make([dynamic]Float_Interval, 0, len(a.intervals) + len(b.intervals))
	append(&all, ..a.intervals)
	append(&all, ..b.intervals)
	return floats_of(all[:])
}

floats_intersect :: proc(a, b: Floats) -> Floats {
	out := make([dynamic]Float_Interval)
	for x in a.intervals {
		for y in b.intervals {
			iv: Float_Interval
			iv.lo, iv.lo_open = tighter_lo(x, y)
			iv.hi, iv.hi_open = tighter_hi(x, y)
			append(&out, iv)
		}
	}
	return floats_of(out[:])
}

tighter_lo :: proc(x, y: Float_Interval) -> (Maybe(f64), bool) {
	a, a_ok := x.lo.?
	b, b_ok := y.lo.?
	if !a_ok do return y.lo, y.lo_open
	if !b_ok do return x.lo, x.lo_open
	if a > b do return a, x.lo_open
	if b > a do return b, y.lo_open
	return a, x.lo_open || y.lo_open
}

tighter_hi :: proc(x, y: Float_Interval) -> (Maybe(f64), bool) {
	a, a_ok := x.hi.?
	b, b_ok := y.hi.?
	if !a_ok do return y.hi, y.hi_open
	if !b_ok do return x.hi, x.hi_open
	if a < b do return a, x.hi_open
	if b < a do return b, y.hi_open
	return a, x.hi_open || y.hi_open
}

floats_complement :: proc(a: Floats) -> Floats {
	out := make([dynamic]Float_Interval)
	gap := Float_Interval{} // de -∞
	open := true
	for iv in a.intervals {
		if lo, ok := iv.lo.?; ok {
			gap.hi, gap.hi_open = lo, !iv.lo_open
			append(&out, gap)
		}
		hi, ok := iv.hi.?
		if !ok {
			open = false
			break
		}
		gap = Float_Interval{lo = hi, lo_open = !iv.hi_open}
	}
	if open do append(&out, gap)
	return floats_of(out[:])
}

floats_subset :: proc(a, b: Floats) -> bool {
	return len(floats_intersect(a, floats_complement(b)).intervals) == 0
}

floats_count :: proc(a: Floats) -> int {
	if len(a.intervals) == 0 do return 0
	if len(a.intervals) > 1 do return 2
	iv := a.intervals[0]
	lo, lo_ok := iv.lo.?
	hi, hi_ok := iv.hi.?
	return lo_ok && hi_ok && lo == hi ? 1 : 2
}

floats_contains :: proc(a: Floats, v: f64) -> bool {
	return floats_subset(floats_point(v), a)
}

// Le défaut : 0.0 s'il y est, sinon un élément du premier intervalle (sa borne
// basse si elle est fermée, sinon un point intérieur).
floats_default :: proc(a: Floats) -> (f64, bool) {
	if len(a.intervals) == 0 do return 0, false
	if floats_contains(a, 0) do return 0, true
	iv := a.intervals[0]
	lo, lo_ok := iv.lo.?
	hi, hi_ok := iv.hi.?
	switch {
	case lo_ok && !iv.lo_open:
		return lo, true
	case lo_ok && hi_ok:
		return (lo + hi) / 2, true
	case lo_ok:
		return lo + 1, true
	case hi_ok && !iv.hi_open:
		return hi, true
	case hi_ok:
		return hi - 1, true
	}
	return 0, true
}

floats_arith :: proc(op: Arith, a, b: Floats) -> Floats {
	out := make([dynamic]Float_Interval)
	for x in a.intervals {
		for y in b.intervals {
			append(&out, float_interval_arith(op, x, y))
		}
	}
	return floats_of(out[:])
}

// Arithmétique flottante sur l'enveloppe fermée : une sur-approximation sûre.
float_interval_arith :: proc(op: Arith, x, y: Float_Interval) -> Float_Interval {
	xl, xl_ok := x.lo.?
	xh, xh_ok := x.hi.?
	yl, yl_ok := y.lo.?
	yh, yh_ok := y.hi.?
	switch op {
	case .Add:
		return Float_Interval{lo = fsum(xl, xl_ok, yl, yl_ok), hi = fsum(xh, xh_ok, yh, yh_ok)}
	case .Sub:
		return Float_Interval{lo = fsum(xl, xl_ok, -yh, yh_ok), hi = fsum(xh, xh_ok, -yl, yl_ok)}
	case .Mul:
		if !(xl_ok && xh_ok && yl_ok && yh_ok) do return Float_Interval{}
		ps := [4]f64{xl * yl, xl * yh, xh * yl, xh * yh}
		return Float_Interval{lo = slice.min(ps[:]), hi = slice.max(ps[:])}
	}
	return Float_Interval{}
}

fsum :: proc(a: f64, a_ok: bool, b: f64, b_ok: bool) -> Maybe(f64) {
	if !a_ok || !b_ok do return nil
	return a + b
}

floats_neg :: proc(a: Floats) -> Floats {
	out := make([dynamic]Float_Interval, 0, len(a.intervals))
	for iv in a.intervals {
		lo: Maybe(f64) = nil
		hi: Maybe(f64) = nil
		if v, ok := iv.hi.?; ok do lo = -v
		if v, ok := iv.lo.?; ok do hi = -v
		append(&out, Float_Interval{lo, hi, iv.hi_open, iv.lo_open})
	}
	return floats_of(out[:])
}

floats_bounds :: proc(a: Floats) -> (lo, hi: Maybe(f64)) {
	if len(a.intervals) == 0 do return nil, nil
	return a.intervals[0].lo, a.intervals[len(a.intervals) - 1].hi
}

// --- booléens ---

Bool_Elem :: enum u8 {
	False,
	True,
}

Bools :: bit_set[Bool_Elem]

bools_point :: proc(v: bool) -> Bools {
	return v ? {.True} : {.False}
}

// --- l'ensemble mixte ---

set_of_ints :: proc(i: Ints) -> Set {
	return Set{ints = i}
}

set_of_floats :: proc(f: Floats) -> Set {
	return Set{floats = f}
}

CHAR_EMPTY :: i128(-1)

set_of_chars :: proc(c: Ints) -> Set {
	return Set{chars = c}
}

// chars_all : tous les caractères, le caractère vide compris.
chars_all :: proc() -> Ints {
	return ints_range(CHAR_EMPTY, i128(MAX_RUNE))
}

// chars_as_strings : chaque caractère comme la chaîne d'une lettre ; le caractère
// vide comme la chaîne vide.
chars_as_strings :: proc(c: Ints) -> Strings {
	out := Strings{}
	for iv in c.intervals {
		lo, _ := iv.lo.?
		hi, _ := iv.hi.?
		if lo == CHAR_EMPTY {
			out = strings_union(out, strings_empty_word())
			lo = 0
		}
		if lo <= hi do out = strings_union(out, strings_runes(rune(lo), rune(hi)))
	}
	return out
}

// as_strings : les chaînes d'un ensemble, ses caractères compris.
as_strings :: proc(s: Set) -> Strings {
	return strings_union(s.strings, chars_as_strings(s.chars))
}

set_of_strings :: proc(s: Strings) -> Set {
	return Set{strings = s}
}

set_of_bools :: proc(b: Bools) -> Set {
	return Set{bools = b}
}

set_count :: proc(s: Set) -> int {
	n := ints_count(s.ints) + floats_count(s.floats) + ints_count(s.chars) + strings_count(s.strings) + card(s.bools)
	return min(n, 2)
}

set_is_empty :: proc(s: Set) -> bool {
	return set_count(s) == 0
}

// La première sorte non vide, dans l'ordre fixe des sortes : le défaut d'un
// ensemble ne dépend pas de la façon dont il a été écrit.
set_first_domain :: proc(s: Set) -> (Domain, bool) {
	for d in Domain do if domain_count(s, d) > 0 do return d, true
	return .Ints, false
}

domain_count :: proc(s: Set, d: Domain) -> int {
	switch d {
	case .Ints:
		return ints_count(s.ints)
	case .Floats:
		return floats_count(s.floats)
	case .Chars:
		return ints_count(s.chars)
	case .Strings:
		return strings_count(s.strings)
	case .Bools:
		return card(s.bools)
	}
	return 0
}

set_union :: proc(a, b: Set) -> Set {
	return Set {
		ints = ints_union(a.ints, b.ints),
		floats = floats_union(a.floats, b.floats),
		chars = ints_union(a.chars, b.chars),
		strings = strings_union(a.strings, b.strings),
		bools = a.bools | b.bools,
	}
}

set_intersect :: proc(a, b: Set) -> Set {
	return Set {
		ints = ints_intersect(a.ints, b.ints),
		floats = floats_intersect(a.floats, b.floats),
		chars = ints_intersect(a.chars, b.chars),
		strings = strings_intersect(a.strings, b.strings),
		bools = a.bools & b.bools,
	}
}

// Le complément se prend dans les sortes que l'ensemble porte : `~5` est « tout
// entier sauf 5 », `~'A'` « tout caractère sauf A », `~"piro"` « toute chaîne sauf
// piro » — jamais « tout sauf » (specs/constraints.md, Negation).
set_complement :: proc(a: Set) -> Set {
	r := Set{}
	if domain_count(a, .Ints) > 0 do r.ints = ints_complement(a.ints)
	if domain_count(a, .Floats) > 0 do r.floats = floats_complement(a.floats)
	if domain_count(a, .Chars) > 0 do r.chars = ints_intersect(ints_complement(a.chars), chars_all())
	if domain_count(a, .Strings) > 0 do r.strings = strings_complement(a.strings)
	if domain_count(a, .Bools) > 0 do r.bools = ~a.bools
	return r
}

// set_top : toutes les valeurs atomiques. C'est `..` seul : il prend la sorte de ce
// qu'il rencontre (`.. + '_'` : toute chaîne qui finit par _).
set_top :: proc() -> Set {
	return Set{ints = ints_all(), floats = floats_all(), chars = chars_all(), strings = strings_all(), bools = {.False, .True}}
}

set_subset :: proc(a, b: Set) -> bool {
	return ints_subset(a.ints, b.ints) &&
		floats_subset(a.floats, b.floats) &&
		ints_subset(a.chars, b.chars) &&
		strings_subset(a.strings, b.strings) &&
		a.bools <= b.bools
}

set_equal :: proc(a, b: Set) -> bool {
	return set_subset(a, b) && set_subset(b, a)
}

// Le défaut d'un ensemble : l'élément distingué de sa première sorte.
set_default :: proc(s: Set) -> (Set, bool) {
	d, ok := set_first_domain(s)
	if !ok do return {}, false
	switch d {
	case .Ints:
		v, _ := ints_default(s.ints)
		return set_of_ints(ints_point(v)), true
	case .Floats:
		v, _ := floats_default(s.floats)
		return set_of_floats(floats_point(v)), true
	case .Chars:
		lo, _ := ints_bounds(s.chars) // le plus bas : le caractère vide s'il y est
		return set_of_chars(ints_point(lo.? or_else CHAR_EMPTY)), true
	case .Strings:
		v, _ := strings_default(s.strings)
		return set_of_strings(strings_point(v)), true
	case .Bools:
		return set_of_bools(.False in s.bools ? {.False} : {.True}), true
	}
	return {}, false
}
