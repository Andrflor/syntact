package kernel

import "core:slice"

// INTERVALS
//
// The integers, the reals and the characters of a constant type, read as sorted,
// disjoint intervals: what the laws of | & ~ (§4.1) compute on, to decide whether
// a constant type is empty, or in another (set.odin). They are never a type: a
// type is a term of type.odin.

// Ints: integers in sorted, disjoint, non-adjacent ranges; nil is infinite.
// Characters are their code points.
Int_Range :: struct {
	lo, hi: Maybe(i128),
}

Ints :: []Int_Range

INT_MAX :: max(i128)

ints_of :: proc(raw: []Int_Range) -> Ints {
	kept := make([dynamic]Int_Range, 0, len(raw))
	for r in raw {
		lo, has_lo := r.lo.?
		hi, has_hi := r.hi.?
		if has_lo && has_hi && lo > hi do continue
		append(&kept, r)
	}
	slice.sort_by(kept[:], proc(a, b: Int_Range) -> bool {
		x, has_x := a.lo.?
		y, has_y := b.lo.?
		if !has_x do return has_y
		return has_y && x < y
	})
	out := make([dynamic]Int_Range, 0, len(kept))
	for r in kept {
		if len(out) == 0 {
			append(&out, r)
			continue
		}
		last := &out[len(out) - 1]
		last_hi, bounded := last.hi.?
		if !bounded do break
		lo, has_lo := r.lo.?
		if !has_lo || lo - 1 <= last_hi {
			if hi, has_hi := r.hi.?; !has_hi || hi > last_hi do last.hi = r.hi
		} else {
			append(&out, r)
		}
	}
	return out[:]
}

ints_union :: proc(a, b: Ints) -> Ints {
	all := make([dynamic]Int_Range)
	append(&all, ..a)
	append(&all, ..b)
	return ints_of(all[:])
}

ints_intersect :: proc(a, b: Ints) -> Ints {
	out := make([dynamic]Int_Range)
	for x in a do for y in b do append(&out, Int_Range{max_bound(x.lo, y.lo), min_bound(x.hi, y.hi)})
	return ints_of(out[:])
}

// ints_complement: within [lo, hi] of the universe given (nil: infinite).
ints_complement :: proc(a: Ints, universe: Int_Range) -> Ints {
	out := make([dynamic]Int_Range)
	from := universe.lo
	for r in a {
		if lo, ok := r.lo.?; ok {
			if f, bounded := from.?; !bounded || lo > f do append(&out, Int_Range{from, lo - 1})
		}
		hi, ok := r.hi.?
		if !ok do return ints_intersect(ints_of(out[:]), {universe})
		from = hi + 1
	}
	append(&out, Int_Range{from, universe.hi})
	return ints_intersect(ints_of(out[:]), {universe})
}

ints_contains :: proc(a: Ints, v: i128) -> bool {
	for r in a {
		if lo, ok := r.lo.?; ok && v < lo do continue
		if hi, ok := r.hi.?; ok && v > hi do continue
		return true
	}
	return false
}

ints_single :: proc(a: Ints) -> (i128, bool) {
	if len(a) != 1 do return 0, false
	lo, has_lo := a[0].lo.?
	hi, has_hi := a[0].hi.?
	return lo, has_lo && has_hi && lo == hi
}

ints_equal :: proc(a, b: Ints) -> bool {
	return slice.equal(a, b)
}

// ints_add: { x + y }, exact: the sum of two ranges is a range.
ints_add :: proc(a, b: Ints) -> Ints {
	out := make([dynamic]Int_Range)
	for x in a do for y in b do append(&out, Int_Range{add_bound(x.lo, y.lo), add_bound(x.hi, y.hi)})
	return ints_of(out[:])
}

ints_neg :: proc(a: Ints) -> Ints {
	out := make([dynamic]Int_Range)
	for r in a do append(&out, Int_Range{neg_bound(r.hi), neg_bound(r.lo)})
	return ints_of(out[:])
}

max_bound :: proc(a, b: Maybe(i128)) -> Maybe(i128) {
	x, has_x := a.?
	y, has_y := b.?
	if !has_x do return b
	if !has_y do return a
	return max(x, y)
}

min_bound :: proc(a, b: Maybe(i128)) -> Maybe(i128) {
	x, has_x := a.?
	y, has_y := b.?
	if !has_x do return b
	if !has_y do return a
	return min(x, y)
}

neg_bound :: proc(a: Maybe(i128)) -> Maybe(i128) {
	if v, ok := a.?; ok do return -v
	return nil
}

add_bound :: proc(a, b: Maybe(i128)) -> Maybe(i128) {
	x, has_x := a.?
	y, has_y := b.?
	if !has_x || !has_y do return nil
	s, ok := add_checked(x, y)
	return ok ? Maybe(i128)(s) : nil
}

add_checked :: proc(a, b: i128) -> (i128, bool) {
	if b > 0 && a > INT_MAX - b do return 0, false
	if b < 0 && a < -INT_MAX - b do return 0, false
	return a + b, true
}

mul_checked :: proc(a, b: i128) -> (i128, bool) {
	if a == 0 || b == 0 do return 0, true
	if abs(a) > INT_MAX / abs(b) do return 0, false
	return a * b, true
}

// Reals: reals in sorted intervals, open or closed at each bound; nil is infinite.
Real_Range :: struct {
	lo, hi:           Maybe(f64),
	lo_open, hi_open: bool,
}

Reals :: []Real_Range

real_range_empty :: proc(r: Real_Range) -> bool {
	lo, has_lo := r.lo.?
	hi, has_hi := r.hi.?
	if !has_lo || !has_hi do return false
	return lo > hi || (lo == hi && (r.lo_open || r.hi_open))
}

reals_of :: proc(raw: []Real_Range) -> Reals {
	kept := make([dynamic]Real_Range, 0, len(raw))
	for r in raw {
		if real_range_empty(r) do continue
		n := r
		if v, ok := n.lo.?; ok {
			if v == 0 do n.lo = 0.0
		} else {
			n.lo_open = false
		}
		if v, ok := n.hi.?; ok {
			if v == 0 do n.hi = 0.0
		} else {
			n.hi_open = false
		}
		append(&kept, n)
	}
	slice.sort_by(kept[:], proc(a, b: Real_Range) -> bool {
		x, has_x := a.lo.?
		y, has_y := b.lo.?
		if !has_x do return has_y
		if !has_y do return false
		return x < y || (x == y && !a.lo_open && b.lo_open)
	})
	out := make([dynamic]Real_Range, 0, len(kept))
	for r in kept {
		if len(out) == 0 {
			append(&out, r)
			continue
		}
		last := &out[len(out) - 1]
		last_hi, bounded := last.hi.?
		if !bounded do break
		lo, has_lo := r.lo.?
		if has_lo && (lo > last_hi || (lo == last_hi && last.hi_open && r.lo_open)) {
			append(&out, r)
			continue
		}
		hi, has_hi := r.hi.?
		switch {
		case !has_hi:
			last.hi, last.hi_open = nil, false
		case hi > last_hi:
			last.hi, last.hi_open = r.hi, r.hi_open
		case hi == last_hi:
			last.hi_open = last.hi_open && r.hi_open
		}
	}
	return out[:]
}

reals_union :: proc(a, b: Reals) -> Reals {
	all := make([dynamic]Real_Range)
	append(&all, ..a)
	append(&all, ..b)
	return reals_of(all[:])
}

reals_intersect :: proc(a, b: Reals) -> Reals {
	out := make([dynamic]Real_Range)
	for x in a {
		for y in b {
			r := x
			if y_lo, ok := y.lo.?; ok {
				x_lo, has := x.lo.?
				if !has || y_lo > x_lo {
					r.lo, r.lo_open = y.lo, y.lo_open
				} else if y_lo == x_lo {
					r.lo_open = x.lo_open || y.lo_open
				}
			}
			if y_hi, ok := y.hi.?; ok {
				x_hi, has := x.hi.?
				if !has || y_hi < x_hi {
					r.hi, r.hi_open = y.hi, y.hi_open
				} else if y_hi == x_hi {
					r.hi_open = x.hi_open || y.hi_open
				}
			}
			append(&out, r)
		}
	}
	return reals_of(out[:])
}

reals_complement :: proc(a: Reals) -> Reals {
	out := make([dynamic]Real_Range)
	gap := Real_Range{}
	for r in a {
		if _, ok := r.lo.?; ok {
			gap.hi, gap.hi_open = r.lo, !r.lo_open
			append(&out, gap)
		}
		if _, ok := r.hi.?; !ok do return reals_of(out[:])
		gap = Real_Range{lo = r.hi, lo_open = !r.hi_open}
	}
	append(&out, gap)
	return reals_of(out[:])
}

reals_contains :: proc(a: Reals, v: f64) -> bool {
	for r in a {
		if lo, ok := r.lo.?; ok && (v < lo || (v == lo && r.lo_open)) do continue
		if hi, ok := r.hi.?; ok && (v > hi || (v == hi && r.hi_open)) do continue
		return true
	}
	return false
}

reals_single :: proc(a: Reals) -> (f64, bool) {
	if len(a) != 1 do return 0, false
	lo, has_lo := a[0].lo.?
	hi, has_hi := a[0].hi.?
	return lo, has_lo && has_hi && lo == hi
}

reals_equal :: proc(a, b: Reals) -> bool {
	return slice.equal(a, b)
}

// reals_add: { x + y }, exact: open where either bound is open.
reals_add :: proc(a, b: Reals) -> Reals {
	out := make([dynamic]Real_Range)
	for x in a {
		for y in b {
			r: Real_Range
			if p, ok := x.lo.?; ok do if q, ok2 := y.lo.?; ok2 do r.lo, r.lo_open = p + q, x.lo_open || y.lo_open
			if p, ok := x.hi.?; ok do if q, ok2 := y.hi.?; ok2 do r.hi, r.hi_open = p + q, x.hi_open || y.hi_open
			append(&out, r)
		}
	}
	return reals_of(out[:])
}

reals_neg :: proc(a: Reals) -> Reals {
	out := make([dynamic]Real_Range)
	for r in a {
		n := Real_Range{lo_open = r.hi_open, hi_open = r.lo_open}
		if v, ok := r.hi.?; ok do n.lo = -v
		if v, ok := r.lo.?; ok do n.hi = -v
		append(&out, n)
	}
	return reals_of(out[:])
}

// reals_mul: { x * y } on closed, bounded intervals: the image of a connected set
// by a continuous operator is the interval between its extreme products. False
// for an open or infinite bound.
reals_mul :: proc(a, b: Reals) -> (Reals, bool) {
	out := make([dynamic]Real_Range)
	for x in a {
		for y in b {
			if x.lo_open || x.hi_open || y.lo_open || y.hi_open do return nil, false
			p, has_p := x.lo.?
			q, has_q := x.hi.?
			r, has_r := y.lo.?
			s, has_s := y.hi.?
			if !has_p || !has_q || !has_r || !has_s do return nil, false
			corners := [4]f64{p * r, p * s, q * r, q * s}
			lo, hi := corners[0], corners[0]
			for c in corners[1:] {
				lo = min(lo, c)
				hi = max(hi, c)
			}
			append(&out, Real_Range{lo = lo, hi = hi})
		}
	}
	return reals_of(out[:]), true
}
