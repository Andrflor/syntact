package kernel

import "core:slice"

// SETS OF INTEGERS (specs/types.md §4.2, §4.3)
//
// The integers of a type, in normal form: ranges sorted, disjoint, non-adjacent
// and non-empty. Two equal sets have the same ranges. A missing bound is
// infinite. Finite values live in [-INT_MAX, INT_MAX], a symmetric universe where
// negation never overflows; at its edge, a finite bound is written infinite.

INT_MAX :: max(i128)

Int_Range :: struct {
	lo: Maybe(i128), // nil: -∞
	hi: Maybe(i128), // nil: +∞
}

Ints :: struct {
	ranges: []Int_Range,
}

ints_point :: proc(v: i128) -> Ints {
	return ints_of({{v, v}})
}

ints_between :: proc(lo, hi: Maybe(i128)) -> Ints {
	return ints_of({{lo, hi}})
}

ints_all :: proc() -> Ints {
	return ints_of({{nil, nil}})
}

// ints_of: the normal form of any list of ranges.
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
		if !bounded do break // the last range already reaches +∞
		lo, has_lo := r.lo.?
		if !has_lo || lo - 1 <= last_hi {
			if hi, has_hi := r.hi.?; !has_hi || hi > last_hi do last.hi = r.hi
		} else {
			append(&out, r)
		}
	}
	for &r in out {
		if lo, ok := r.lo.?; ok && lo == -INT_MAX && r.hi != Maybe(i128)(-INT_MAX) do r.lo = nil
		if hi, ok := r.hi.?; ok && hi == INT_MAX && r.lo != Maybe(i128)(INT_MAX) do r.hi = nil
	}
	return Ints{out[:]}
}

ints_union :: proc(a, b: Ints) -> Ints {
	all := make([dynamic]Int_Range, 0, len(a.ranges) + len(b.ranges))
	append(&all, ..a.ranges)
	append(&all, ..b.ranges)
	return ints_of(all[:])
}

ints_intersect :: proc(a, b: Ints) -> Ints {
	out := make([dynamic]Int_Range)
	for x in a.ranges do for y in b.ranges do append(&out, Int_Range{max_lo(x.lo, y.lo), min_hi(x.hi, y.hi)})
	return ints_of(out[:])
}

ints_complement :: proc(a: Ints) -> Ints {
	out := make([dynamic]Int_Range)
	from: Maybe(i128) // the start of the current gap; nil: -∞
	for r in a.ranges {
		if lo, ok := r.lo.?; ok && lo > -INT_MAX do append(&out, Int_Range{from, lo - 1})
		hi, ok := r.hi.?
		if !ok || hi == INT_MAX do return ints_of(out[:])
		from = hi + 1
	}
	append(&out, Int_Range{from, nil})
	return ints_of(out[:])
}

ints_empty :: proc(a: Ints) -> bool {
	return len(a.ranges) == 0
}

ints_full :: proc(a: Ints) -> bool {
	return len(a.ranges) == 1 && a.ranges[0].lo == nil && a.ranges[0].hi == nil
}

ints_contains :: proc(a: Ints, v: i128) -> bool {
	for r in a.ranges {
		if lo, ok := r.lo.?; ok && v < lo do continue
		if hi, ok := r.hi.?; ok && v > hi do continue
		return true
	}
	return false
}

ints_equal :: proc(a, b: Ints) -> bool {
	return slice.equal(a.ranges, b.ranges)
}

// ints_single: the only element, when there is exactly one.
ints_single :: proc(a: Ints) -> (i128, bool) {
	if len(a.ranges) != 1 do return 0, false
	lo, has_lo := a.ranges[0].lo.?
	hi, has_hi := a.ranges[0].hi.?
	return lo, has_lo && has_hi && lo == hi
}

// ints_size: the number of elements, when it is finite and at most `limit`.
ints_size :: proc(a: Ints, limit: i128) -> (i128, bool) {
	n: i128
	for r in a.ranges {
		lo, has_lo := r.lo.?
		hi, has_hi := r.hi.?
		if !has_lo || !has_hi || hi - lo >= limit do return 0, false
		n += hi - lo + 1
		if n > limit do return 0, false
	}
	return n, true
}

// ints_values: the elements of a finite set, in order.
ints_values :: proc(a: Ints) -> []i128 {
	out := make([dynamic]i128)
	for r in a.ranges {
		lo, _ := r.lo.?
		hi, _ := r.hi.?
		for v := lo; v <= hi; v += 1 do append(&out, v)
	}
	return out[:]
}

ints_min :: proc(a: Ints) -> Maybe(i128) {
	return len(a.ranges) == 0 ? nil : a.ranges[0].lo
}

ints_max :: proc(a: Ints) -> Maybe(i128) {
	return len(a.ranges) == 0 ? nil : a.ranges[len(a.ranges) - 1].hi
}

// ints_add: { x + y | x ∈ a, y ∈ b }, exact: the sum of two ranges is a range.
// A finite bound pushed out of the universe becomes infinite.
ints_add :: proc(a, b: Ints) -> Ints {
	out := make([dynamic]Int_Range)
	for x in a.ranges do for y in b.ranges do append(&out, Int_Range{add_bound(x.lo, y.lo), add_bound(x.hi, y.hi)})
	return ints_of(out[:])
}

ints_neg :: proc(a: Ints) -> Ints {
	out := make([dynamic]Int_Range, 0, len(a.ranges))
	for r in a.ranges do append(&out, Int_Range{neg_bound(r.hi), neg_bound(r.lo)})
	return ints_of(out[:])
}

max_lo :: proc(a, b: Maybe(i128)) -> Maybe(i128) {
	x, has_x := a.?
	y, has_y := b.?
	if !has_x do return b
	if !has_y do return a
	return max(x, y)
}

min_hi :: proc(a, b: Maybe(i128)) -> Maybe(i128) {
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
