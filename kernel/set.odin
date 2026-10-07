package kernel

import "core:math"
import "core:slice"

// Les ensembles de valeurs atomiques, sous forme normale. Un littéral est un
// ensemble à un élément (`5` est `5..5`), un builtin est un ensemble (`u8` est
// `0..255`), `none` est l'ensemble vide. Un ensemble mixte (`u8 | string`) a une
// composante par sorte ; chaque composante est une algèbre close. L'égalité est
// l'inclusion dans les deux sens : `2|1` et `2..1` sont égaux, comme `2|"a"|3..4`
// et `"a"|2..4`. Les intervalles ont même une écriture unique (`1..2`).

Domain :: enum u8 {
	Ints,
	Floats,
	Chars,
	Strings,
	Bools,
	Scopes,
}

Set :: struct {
	// Les sortes dont l'ensemble parle, même quand leur composant est vide : `~bool`
	// ne contient aucun booléen mais parle toujours des booléens. C'est ce qui fait
	// de ~ une involution (`~~X = X`). Une sorte qui a des valeurs est toujours
	// portée (`carried`) ; subset et l'égalité ne lisent que les valeurs.
	sorts:   bit_set[Domain],
	ints:    Ints,
	floats:  Floats,
	// Les caractères, par leur point de code ; CHAR_EMPTY est le caractère vide `''`,
	// le plus bas de tous. Une couleur `string` admet un caractère comme la chaîne
	// d'une lettre (`string:s -> 'c'`), mais `'a'` et `"a"` restent deux valeurs.
	chars:   Ints,
	strings: Strings,
	bools:   Bools,
	scopes:  Bdd, // des combinaisons de formes de scopes (bdd.odin)
}

// --- entiers : intervalles triés, disjoints, non adjacents ---
//
// L'univers des entiers finis est [-I128_MAX, I128_MAX] : symétrique, la négation
// n'y déborde jamais, et un calcul exact qui en sortirait échoue (add_checked,
// mul_checked). Au bord, une borne finie et une borne infinie désignent les mêmes
// valeurs : la forme normale écrit la borne infinie, sauf pour le point du bord.

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
		if !lo_ok || lo - 1 <= last_hi { 	// lo ≥ -I128_MAX : lo - 1 ne déborde pas
			hi, hi_ok := iv.hi.?
			if !hi_ok || hi > last_hi do last.hi = iv.hi
		} else {
			append(&out, iv)
		}
	}
	for &iv in out do iv = at_edges(iv)
	return Ints{out[:]}
}

// at_edges : une borne au bord de l'univers s'écrit infinie, sauf pour le point du
// bord lui-même, qui reste un point.
at_edges :: proc(iv: Int_Interval) -> Int_Interval {
	lo, lo_ok := iv.lo.?
	hi, hi_ok := iv.hi.?
	r := iv
	if lo_ok && lo == I128_MAX do return Int_Interval{lo, lo}
	if hi_ok && hi == -I128_MAX do return Int_Interval{hi, hi}
	if lo_ok && lo == -I128_MAX do r.lo = nil
	if hi_ok && hi == I128_MAX do r.hi = nil
	return r
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
		if lo, ok := iv.lo.?; ok && lo > -I128_MAX {
			append(&out, Int_Interval{cursor, lo - 1})
		}
		hi, ok := iv.hi.?
		if !ok || hi == I128_MAX {
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

// ints_arith : { x op y | x ∈ a, y ∈ b }, par intervalles — exact pour + et -,
// l'enveloppe pour *. `exact` est faux quand une borne finie sortirait de
// l'univers : elle devient infinie de son côté, une sur-approximation sûre.
ints_arith :: proc(op: Arith, a, b: Ints) -> (r: Ints, exact: bool) {
	out := make([dynamic]Int_Interval)
	exact = true
	for x in a.intervals {
		for y in b.intervals {
			iv: Int_Interval
			ok: bool
			switch op {
			case .Add:
				iv, ok = add_interval(x, y)
			case .Sub:
				iv, ok = add_interval(x, Int_Interval{neg_bound(y.hi), neg_bound(y.lo)})
			case .Mul:
				iv, ok = mul_interval(x, y)
			}
			exact &&= ok
			append(&out, iv)
		}
	}
	return ints_of(out[:]), exact
}

add_interval :: proc(x, y: Int_Interval) -> (Int_Interval, bool) {
	lo, lo_ok := add_bound(x.lo, y.lo)
	hi, hi_ok := add_bound(x.hi, y.hi)
	return Int_Interval{lo, hi}, lo_ok && hi_ok
}

// ints_pow : { xⁿ | x ∈ a } sur l'enveloppe de chaque intervalle — une puissance
// paire ne descend pas sous 0.
ints_pow :: proc(a: Ints, n: int) -> Ints {
	if n == 1 do return a
	out := make([dynamic]Int_Interval, 0, len(a.intervals))
	for iv in a.intervals do append(&out, pow_interval(iv, n))
	return ints_of(out[:])
}

pow_bound :: proc(b: Maybe(i128), n: int) -> Maybe(i128) {
	v, ok := b.?
	if !ok do return nil
	r: i128 = 1
	for _ in 0 ..< n {
		p, p_ok := mul_checked(r, v)
		if !p_ok do return nil // trop grand : infini, une sur-approximation sûre
		r = p
	}
	return r
}

pow_interval :: proc(iv: Int_Interval, n: int) -> Int_Interval {
	if n % 2 == 1 do return Int_Interval{pow_bound(iv.lo, n), pow_bound(iv.hi, n)}
	lo, lo_ok := iv.lo.?
	hi, hi_ok := iv.hi.?
	if lo_ok && lo >= 0 do return Int_Interval{pow_bound(iv.lo, n), pow_bound(iv.hi, n)}
	if hi_ok && hi <= 0 do return Int_Interval{pow_bound(iv.hi, n), pow_bound(iv.lo, n)}
	if !lo_ok || !hi_ok do return Int_Interval{i128(0), nil}
	a, b := pow_bound(iv.lo, n), pow_bound(iv.hi, n)
	x, x_ok := a.?
	y, y_ok := b.?
	if !x_ok || !y_ok do return Int_Interval{i128(0), nil}
	return Int_Interval{i128(0), max(x, y)}
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

// add_bound : deux bornes du même côté. Une borne infinie l'emporte ; une somme qui
// sort de l'univers devient infinie (`ok` faux).
add_bound :: proc(a, b: Maybe(i128)) -> (Maybe(i128), bool) {
	x, x_ok := a.?
	y, y_ok := b.?
	if !x_ok || !y_ok do return nil, true
	s, ok := add_checked(x, y)
	if !ok do return nil, false
	return s, true
}

add_checked :: proc(a, b: i128) -> (i128, bool) {
	if b > 0 && a > I128_MAX - b do return 0, false
	if b < 0 && a < -I128_MAX - b do return 0, false
	return a + b, true
}

mul_checked :: proc(a, b: i128) -> (i128, bool) {
	// Sous 2⁶³ en valeur absolue, le produit tient : pas de division 128 bits.
	SMALL :: i128(1) << 63
	if a > -SMALL && a < SMALL && b > -SMALL && b < SMALL do return a * b, true
	if a == 0 || b == 0 do return 0, true
	if abs(a) > I128_MAX / abs(b) do return 0, false
	return a * b, true
}

// Ext : une borne étendue, pour multiplier des intervalles infinis.
Ext :: struct {
	v:   i128,
	inf: int, // -1 : -∞, 1 : +∞, 0 : la valeur finie v
}

ext_of :: proc(b: Maybe(i128), side: int) -> Ext {
	if v, ok := b.?; ok do return Ext{v, 0}
	return Ext{0, side}
}

ext_sign :: proc(e: Ext) -> int {
	if e.inf != 0 do return e.inf
	return e.v > 0 ? 1 : (e.v < 0 ? -1 : 0)
}

// ext_mul : 0·∞ = 0, car les valeurs sont finies et seules les bornes sont des
// limites. Un produit qui sort de l'univers devient infini, de son signe.
ext_mul :: proc(a, b: Ext) -> (Ext, bool) {
	sa, sb := ext_sign(a), ext_sign(b)
	if sa == 0 || sb == 0 do return Ext{}, true
	if a.inf != 0 || b.inf != 0 do return Ext{0, sa * sb}, true
	p, ok := mul_checked(a.v, b.v)
	if !ok do return Ext{0, sa * sb}, false
	return Ext{p, 0}, true
}

ext_less :: proc(a, b: Ext) -> bool {
	if a.inf != b.inf do return a.inf < b.inf
	return a.inf == 0 && a.v < b.v
}

ext_bound :: proc(e: Ext) -> Maybe(i128) {
	if e.inf != 0 do return nil
	return e.v
}

// mul_interval : le produit d'intervalles est atteint aux coins.
mul_interval :: proc(x, y: Int_Interval) -> (Int_Interval, bool) {
	xs := [2]Ext{ext_of(x.lo, -1), ext_of(x.hi, 1)}
	ys := [2]Ext{ext_of(y.lo, -1), ext_of(y.hi, 1)}
	lo, hi: Ext
	exact := true
	for a, i in xs {
		for b, j in ys {
			p, ok := ext_mul(a, b)
			exact &&= ok
			if (i == 0 && j == 0) || ext_less(p, lo) do lo = p
			if (i == 0 && j == 0) || ext_less(hi, p) do hi = p
		}
	}
	return Int_Interval{ext_bound(lo), ext_bound(hi)}, exact
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

// Une forme normale n'a qu'un zéro : -0.0 s'écrit 0.0.
normal_zero :: proc(b: Maybe(f64)) -> Maybe(f64) {
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
		// Une borne infinie n'est ni ouverte ni fermée : une seule écriture.
		_, lo_finite := iv.lo.?
		_, hi_finite := iv.hi.?
		append(&kept, Float_Interval{normal_zero(iv.lo), normal_zero(iv.hi), iv.lo_open && lo_finite, iv.hi_open && hi_finite})
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

// Le défaut, comme pour les entiers : 0.0 s'il y est, sinon le plus petit flottant
// du premier intervalle — sa borne basse, ou le flottant juste au-dessus d'une borne
// ouverte ; sans borne basse, le plus grand — sa borne haute, ou juste en dessous.
floats_default :: proc(a: Floats) -> (f64, bool) {
	if len(a.intervals) == 0 do return 0, false
	if floats_contains(a, 0) do return 0, true
	iv := a.intervals[0]
	if lo, ok := iv.lo.?; ok do return iv.lo_open ? math.nextafter(lo, math.INF_F64) : lo, true
	hi, _ := iv.hi.? // sans aucune borne, l'intervalle contiendrait 0
	return iv.hi_open ? math.nextafter(hi, math.NEG_INF_F64) : hi, true
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
	return Set{sorts = {.Ints}, ints = i}
}

set_of_floats :: proc(f: Floats) -> Set {
	return Set{sorts = {.Floats}, floats = f}
}

CHAR_EMPTY :: i128(-1)

set_of_chars :: proc(c: Ints) -> Set {
	return Set{sorts = {.Chars}, chars = c}
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
	return Set{sorts = {.Strings}, strings = s}
}

set_of_bools :: proc(b: Bools) -> Set {
	return Set{sorts = {.Bools}, bools = b}
}

// carried : les sortes dont l'ensemble parle — celles qu'il a gardées, et celles où
// son écriture a quelque chose.
carried :: proc(s: Set) -> bit_set[Domain] {
	r := s.sorts
	if len(s.ints.intervals) > 0 do r += {.Ints}
	if len(s.floats.intervals) > 0 do r += {.Floats}
	if len(s.chars.intervals) > 0 do r += {.Chars}
	if s.strings.re != nil do r += {.Strings}
	if s.bools != {} do r += {.Bools}
	if !is_leaf(s.scopes, .Bottom) do r += {.Scopes}
	return r
}

set_count :: proc(s: Set) -> int {
	n := 0
	for d in Domain {
		n += domain_count(s, d)
		if n >= 2 do return 2
	}
	return n
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
	case .Scopes:
		// un ensemble de scopes n'est jamais un atome : un scope valeur est un ^Scope
		return bdd_is_empty(s.scopes) ? 0 : 2
	}
	return 0
}

set_union :: proc(a, b: Set) -> Set {
	return Set {
		sorts = carried(a) | carried(b),
		ints = ints_union(a.ints, b.ints),
		floats = floats_union(a.floats, b.floats),
		chars = ints_union(a.chars, b.chars),
		strings = strings_union(a.strings, b.strings),
		bools = a.bools | b.bools,
		scopes = bdd_or(a.scopes, b.scopes),
	}
}

// Deux sortes différentes ne se rencontrent pas : `u8 & string` ne parle de rien,
// c'est none ; `0 & 1` parle encore des entiers.
set_intersect :: proc(a, b: Set) -> Set {
	return Set {
		sorts = carried(a) & carried(b),
		ints = ints_intersect(a.ints, b.ints),
		floats = floats_intersect(a.floats, b.floats),
		chars = ints_intersect(a.chars, b.chars),
		strings = strings_intersect(a.strings, b.strings),
		bools = a.bools & b.bools,
		scopes = bdd_and(a.scopes, b.scopes),
	}
}

// Le complément se prend dans les sortes que l'ensemble porte : `~5` est « tout
// entier sauf 5 », `~'A'` « tout caractère sauf A », `~"piro"` « toute chaîne sauf
// piro » — jamais « tout sauf » (specs/constraints.md, Negation).
set_complement :: proc(a: Set) -> Set {
	r := Set{sorts = carried(a)}
	if .Ints in r.sorts do r.ints = ints_complement(a.ints)
	if .Floats in r.sorts do r.floats = floats_complement(a.floats)
	if .Chars in r.sorts do r.chars = ints_intersect(ints_complement(a.chars), chars_all())
	if .Strings in r.sorts do r.strings = strings_complement(a.strings)
	if .Bools in r.sorts do r.bools = ~a.bools
	if .Scopes in r.sorts do r.scopes = bdd_diff(.Top, a.scopes)
	return r
}

// set_diff : a ∖ b, sorte par sorte ; a garde ses sortes.
set_diff :: proc(a, b: Set) -> Set {
	return Set {
		sorts = carried(a),
		ints = ints_intersect(a.ints, ints_complement(b.ints)),
		floats = floats_intersect(a.floats, floats_complement(b.floats)),
		chars = ints_intersect(a.chars, ints_complement(b.chars)),
		strings = strings_intersect(a.strings, strings_complement(b.strings)),
		bools = a.bools - b.bools,
		scopes = bdd_diff(a.scopes, b.scopes),
	}
}

// set_top : toutes les valeurs atomiques. C'est `..` seul : il prend la sorte de ce
// qu'il rencontre (`.. + '_'` : toute chaîne qui finit par _).
set_top :: proc() -> Set {
	return Set{sorts = ~{}, ints = ints_all(), floats = floats_all(), chars = chars_all(), strings = strings_all(), bools = {.False, .True}}
}

set_subset :: proc(a, b: Set) -> bool {
	return ints_subset(a.ints, b.ints) &&
		floats_subset(a.floats, b.floats) &&
		ints_subset(a.chars, b.chars) &&
		strings_subset(a.strings, b.strings) &&
		a.bools <= b.bools &&
		bdd_subset(a.scopes, b.scopes)
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
	case .Scopes:
		return {}, false // un scope n'est pas un atome : voir default_of
	}
	return {}, false
}
