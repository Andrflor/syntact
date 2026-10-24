package kernel

import "core:slice"

// SETS OF REALS (specs/types.md §4.2, §4.3)
//
// The reals of a type, in normal form: intervals sorted, non-empty, and such that
// no two of them form an interval together. A missing bound is infinite and has
// no openness. -0.0 is written 0.0.

Real_Range :: struct {
	lo:      Maybe(f64), // nil: -∞
	hi:      Maybe(f64), // nil: +∞
	lo_open: bool,
	hi_open: bool,
}

Reals :: struct {
	ranges: []Real_Range,
}

reals_point :: proc(v: f64) -> Reals {
	return reals_of({{lo = v, hi = v}})
}

reals_all :: proc() -> Reals {
	return reals_of({{}})
}

real_range_empty :: proc(r: Real_Range) -> bool {
	lo, has_lo := r.lo.?
	hi, has_hi := r.hi.?
	if !has_lo || !has_hi do return false
	return lo > hi || (lo == hi && (r.lo_open || r.hi_open))
}

// reals_of: the normal form of any list of intervals.
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
		joined := !has_lo || lo < last_hi || (lo == last_hi && !(last.hi_open && r.lo_open))
		if !joined {
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
	return Reals{out[:]}
}

reals_union :: proc(a, b: Reals) -> Reals {
	all := make([dynamic]Real_Range, 0, len(a.ranges) + len(b.ranges))
	append(&all, ..a.ranges)
	append(&all, ..b.ranges)
	return reals_of(all[:])
}

reals_intersect :: proc(a, b: Reals) -> Reals {
	out := make([dynamic]Real_Range)
	for x in a.ranges {
		for y in b.ranges {
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
	gap := Real_Range{} // starts at -∞
	for r in a.ranges {
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

reals_empty :: proc(a: Reals) -> bool {
	return len(a.ranges) == 0
}

reals_full :: proc(a: Reals) -> bool {
	return len(a.ranges) == 1 && a.ranges[0].lo == nil && a.ranges[0].hi == nil
}

reals_contains :: proc(a: Reals, v: f64) -> bool {
	for r in a.ranges {
		if lo, ok := r.lo.?; ok && (v < lo || (v == lo && r.lo_open)) do continue
		if hi, ok := r.hi.?; ok && (v > hi || (v == hi && r.hi_open)) do continue
		return true
	}
	return false
}

reals_equal :: proc(a, b: Reals) -> bool {
	return slice.equal(a.ranges, b.ranges)
}

reals_single :: proc(a: Reals) -> (f64, bool) {
	if len(a.ranges) != 1 do return 0, false
	lo, has_lo := a.ranges[0].lo.?
	hi, has_hi := a.ranges[0].hi.?
	return lo, has_lo && has_hi && lo == hi
}

// reals_add: { x + y | x ∈ a, y ∈ b }, exact: the sum of two intervals is an
// interval, open at a bound when one of the two is open there.
reals_add :: proc(a, b: Reals) -> Reals {
	out := make([dynamic]Real_Range)
	for x in a.ranges {
		for y in b.ranges {
			r: Real_Range
			if p, ok := x.lo.?; ok do if q, ok2 := y.lo.?; ok2 do r.lo, r.lo_open = p + q, x.lo_open || y.lo_open
			if p, ok := x.hi.?; ok do if q, ok2 := y.hi.?; ok2 do r.hi, r.hi_open = p + q, x.hi_open || y.hi_open
			append(&out, r)
		}
	}
	return reals_of(out[:])
}

reals_neg :: proc(a: Reals) -> Reals {
	out := make([dynamic]Real_Range, 0, len(a.ranges))
	for r in a.ranges {
		n := Real_Range{lo_open = r.hi_open, hi_open = r.lo_open}
		if v, ok := r.hi.?; ok do n.lo = -v
		if v, ok := r.lo.?; ok do n.hi = -v
		append(&out, n)
	}
	return reals_of(out[:])
}

// reals_mul: { x * y | x ∈ a, y ∈ b } when every interval is closed and bounded:
// the product of two such intervals is the interval of its corner products.
// Otherwise false: the product stays an operation.
reals_mul :: proc(a, b: Reals) -> (Reals, bool) {
	out := make([dynamic]Real_Range)
	for x in a.ranges {
		for y in b.ranges {
			xs, x_ok := closed_bounds(x)
			ys, y_ok := closed_bounds(y)
			if !x_ok || !y_ok do return {}, false
			lo, hi := xs[0] * ys[0], xs[0] * ys[0]
			for p in xs do for q in ys {
				lo = min(lo, p * q)
				hi = max(hi, p * q)
			}
			append(&out, Real_Range{lo = lo, hi = hi})
		}
	}
	return reals_of(out[:]), true
}

// reals_div: { x / y | x ∈ a, y ∈ b }, b closed, bounded and without 0: a times
// the interval of the inverses.
reals_div :: proc(a, b: Reals) -> (Reals, bool) {
	inverses := make([dynamic]Real_Range)
	for y in b.ranges {
		ys, ok := closed_bounds(y)
		if !ok || (ys[0] <= 0 && ys[1] >= 0) do return {}, false
		append(&inverses, Real_Range{lo = 1 / ys[1], hi = 1 / ys[0]})
	}
	return reals_mul(a, reals_of(inverses[:]))
}

closed_bounds :: proc(r: Real_Range) -> ([2]f64, bool) {
	lo, has_lo := r.lo.?
	hi, has_hi := r.hi.?
	return {lo, hi}, has_lo && has_hi && !r.lo_open && !r.hi_open
}
