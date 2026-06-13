package compiler

import "core:fmt"
import "core:strings"


int_is_concrete :: #force_inline proc(t: Integer_Type) -> bool {
	return integer_intervals_is_concrete(t.integer_intervals)
}


integer_intervals_is_concrete :: #force_inline proc(
	integer_intervals: []Integer_Interval,
) -> bool {
	if len(integer_intervals) != 1 do return false
	lo, lo_ok := integer_intervals[0].lo.(i128)
	hi, hi_ok := integer_intervals[0].hi.(i128)
	return lo_ok && hi_ok && lo == hi
}


int_value :: #force_inline proc(t: Integer_Type) -> i128 {
	return t.integer_intervals[0].lo.(i128)
}


make_int_result :: #force_inline proc(val: i128) -> Type {
	integer_intervals := make([]Integer_Interval, 1)
	integer_intervals[0] = Integer_Interval{val, val}
	return Integer_Type{integer_intervals, val}
}


make_int_range :: proc(lo: Maybe(i128), hi: Maybe(i128)) -> Integer_Type {
	integer_intervals := make([]Integer_Interval, 1)
	integer_intervals[0] = Integer_Interval{lo, hi}
	return Integer_Type{integer_intervals, default_for_integer_intervals(integer_intervals)}
}

// Range with an EXPLICIT default; signed builtins use it so `i8` defaults to 0, not -128.
make_int_range_default :: proc(lo: Maybe(i128), hi: Maybe(i128), def: i128) -> Integer_Type {
	integer_intervals := make([]Integer_Interval, 1)
	integer_intervals[0] = Integer_Interval{lo, hi}
	return Integer_Type{integer_intervals, def}
}


make_int_const :: proc(val: i128) -> Integer_Type {
	return make_int_range(val, val)
}


// Structural fallback default (no propagated default): first finite bound while
// scanning lo₁, hi₁, lo₂, …; fully open set → 0.
default_for_integer_intervals :: proc(integer_intervals: []Integer_Interval) -> Maybe(i128) {
	if len(integer_intervals) == 0 do return nil
	for interval in integer_intervals {
		if lo, ok := interval.lo.(i128); ok do return lo
		if hi, ok := interval.hi.(i128); ok do return hi
	}
	return i128(0)
}


int_to_f64 :: #force_inline proc(i: Integer_Type) -> f64 {
	return f64(int_value(i))
}

// --- integer domain entry points (return reduced ^Type / bool / string) ---

fold_type_integer :: proc(t: ^Type) -> ^Type {
	it, ok := fold_type_intervals(t).(Integer_Type)
	if !ok do return nil
	r := new(Type)
	r^ = it
	return r
}

fold_constraint_integer :: proc(t: ^Type) -> ^Type {
	it, ok := fold_constraint_intervals(t).(Integer_Type)
	if !ok do return nil
	r := new(Type)
	r^ = it
	return r
}

integer_satisfy :: proc(fc, ft: Integer_Type) -> bool {
	return integer_intervals_satisfy(ft.integer_intervals, fc.integer_intervals)
}

integer_to_string :: proc(t: Integer_Type) -> string {
	return pretty_integer_intervals(t.integer_intervals)
}

stored_fold_intervals :: proc(t: ^Type) -> Maybe(Integer_Type) {
	if t == nil do return nil
	#partial switch v in t^ {
	case Integer_Type:
		return v
	}
	return nil
}

// --- integer interval fold ---

fold_type_intervals :: proc(t: ^Type) -> Maybe(Integer_Type) {
	if t == nil do return nil
	#partial switch v in t^ {
	case Scope_Type:
		for i := 0; i < len(v.kind); i += 1 {
			if v.kind[i] == .Product {
				if s, ok := stored_fold_intervals(v.type_folds[i]).(Integer_Type); ok {
					return s
				}
				return fold_type_intervals(v.types[i])
			}
		}
		return nil
	case Integer_Type:
		return v
	case Range_Type:
		left, left_ok := fold_type_intervals(v.left).(Integer_Type)
		right, right_ok := fold_type_intervals(v.right).(Integer_Type)
		if v.left != nil && !left_ok do return nil
		if v.right != nil && !right_ok do return nil
		// A range (possibly chained like `10..0..30`) covers the span of ALL
		// its bounds: lo = global min, hi = global max. Since sub-ranges have
		// already been folded into their span, merging is enough. A missing
		// bound (`5..`, `..10`) = open to infinity on that side.
		lo, hi := range_span_bounds(
			left.integer_intervals,
			right.integer_intervals,
			v.left == nil,
			v.right == nil,
		)
		segs := make([]Integer_Interval, 1)
		segs[0] = Integer_Interval{lo, hi}
		return Integer_Type{segs, default_for_integer_intervals(segs)}
	case Compose_Type:
		if v.type_fold != nil {
			return fold_type_intervals(v.type_fold)
		}
		if v.left == nil {
			right, right_ok := fold_type_intervals(v.right).(Integer_Type)
			if !right_ok do return nil
			right_segs := right.integer_intervals
			segs := make([]Integer_Interval, 1)
			#partial switch v.operator {
			case .Greater:
				hi, hi_ok := right_segs[0].hi.(i128)
				if !hi_ok do return nil
				segs[0] = Integer_Interval{hi + 1, nil}
				return Integer_Type{segs, default_for_integer_intervals(segs)}
			case .GreaterEqual:
				segs[0] = Integer_Interval{right_segs[0].lo, nil}
				return Integer_Type{segs, default_for_integer_intervals(segs)}
			case .Less:
				lo, lo_ok := right_segs[0].lo.(i128)
				if !lo_ok do return nil
				segs[0] = Integer_Interval{nil, lo - 1}
				return Integer_Type{segs, default_for_integer_intervals(segs)}
			case .LessEqual:
				segs[0] = Integer_Interval{nil, right_segs[0].hi}
				return Integer_Type{segs, default_for_integer_intervals(segs)}
			case .Subtract:
				lo, lo_ok := right_segs[0].lo.(i128)
				hi, hi_ok := right_segs[0].hi.(i128)
				if !lo_ok || !hi_ok do return nil
				segs[0] = Integer_Interval{-hi, -lo}
				return Integer_Type{segs, default_for_integer_intervals(segs)}
			}
			return nil
		}
		left, left_ok := fold_type_intervals(v.left).(Integer_Type)
		right, right_ok := fold_type_intervals(v.right).(Integer_Type)
		if !left_ok || !right_ok do return nil
		left_segs := left.integer_intervals
		right_segs := right.integer_intervals
		if len(left_segs) == 0 || len(right_segs) == 0 do return nil
		result := make([dynamic]Integer_Interval)
		for ls in left_segs {
			for rs in right_segs {
				pair, pair_ok := fold_arith_integer_intervals(
					ls,
					rs,
					v.operator,
				).([]Integer_Interval)
				if !pair_ok do return nil
				for s in pair {
					append(&result, s)
				}
			}
		}
		segs := integer_intervals_normalize(result[:])
		return Integer_Type{segs, default_for_integer_intervals(segs)}
	case Cast_Type:
		if v.type_fold != nil {
			return fold_type_intervals(v.type_fold)
		}
		return fold_constraint_intervals(v.target)
	case Or_Type:
		left, left_ok := fold_type_intervals(v.left).(Integer_Type)
		right, right_ok := fold_type_intervals(v.right).(Integer_Type)
		if !left_ok || !right_ok do return nil
		return integer_type_union(left, right)
	case And_Type:
		left, left_ok := fold_type_intervals(v.left).(Integer_Type)
		right, right_ok := fold_type_intervals(v.right).(Integer_Type)
		if !left_ok || !right_ok do return nil
		return integer_type_intersect(left, right)
	case Negate_Type:
		inner, inner_ok := fold_type_intervals(v.operand).(Integer_Type)
		if !inner_ok do return nil
		return integer_type_negate(inner)
	case Mention_Type:
		if v.match_scope != nil && v.match_index >= 0 {
			if s, ok := stored_fold_intervals(
				   v.match_scope.type_folds[v.match_index],
			   ).(Integer_Type); ok {
				return s
			}
			if s, ok := stored_fold_intervals(
				   v.match_scope.constraint_folds[v.match_index],
			   ).(Integer_Type); ok {
				return s
			}
		}
		return nil
	case Reference_Type:
		ref := v.reference
		if ref == nil || ref.match_scope == nil || ref.match_index < 0 do return nil
		if s, ok := stored_fold_intervals(
			   ref.match_scope.type_folds[ref.match_index],
		   ).(Integer_Type); ok {
			return s
		}
		if s, ok := stored_fold_intervals(
			   ref.match_scope.constraint_folds[ref.match_index],
		   ).(Integer_Type); ok {
			return s
		}
		return nil
	}
	return nil
}

fold_constraint_intervals :: proc(t: ^Type) -> Maybe(Integer_Type) {
	if t == nil do return nil
	#partial switch v in t^ {
	case Scope_Type:
		for i := 0; i < len(v.kind); i += 1 {
			if v.kind[i] == .Product {
				return fold_constraint_intervals(v.types[i])
			}
		}
		return nil
	case Integer_Type:
		return v
	case Range_Type:
		left, left_ok := fold_constraint_intervals(v.left).(Integer_Type)
		right, right_ok := fold_constraint_intervals(v.right).(Integer_Type)
		if v.left != nil && !left_ok do return nil
		if v.right != nil && !right_ok do return nil
		lo, hi := range_span_bounds(
			left.integer_intervals,
			right.integer_intervals,
			v.left == nil,
			v.right == nil,
		)
		segs := make([]Integer_Interval, 1)
		segs[0] = Integer_Interval{lo, hi}
		return Integer_Type{segs, default_for_integer_intervals(segs)}
	case Compose_Type:
		if v.type_fold != nil {
			return fold_constraint_intervals(v.type_fold)
		}
		return fold_type_intervals(t)
	case Or_Type:
		left, left_ok := fold_constraint_intervals(v.left).(Integer_Type)
		right, right_ok := fold_constraint_intervals(v.right).(Integer_Type)
		if !left_ok || !right_ok do return nil
		return integer_type_union(left, right)
	case And_Type:
		left, left_ok := fold_constraint_intervals(v.left).(Integer_Type)
		right, right_ok := fold_constraint_intervals(v.right).(Integer_Type)
		if !left_ok || !right_ok do return nil
		return integer_type_intersect(left, right)
	case Negate_Type:
		inner, inner_ok := fold_constraint_intervals(v.operand).(Integer_Type)
		if !inner_ok do return nil
		return integer_type_negate(inner)
	case Mention_Type:
		if v.match_scope != nil && v.match_index >= 0 {
			return fold_constraint_intervals(v.match_scope.types[v.match_index])
		}
	case Reference_Type:
		ref := v.reference
		if ref != nil && ref.match_scope != nil && ref.match_index >= 0 {
			return fold_constraint_intervals(ref.match_scope.types[ref.match_index])
		}
	}
	return nil
}

// Span of a range: global min of the `lo`, global max of the `hi`; order only
// changes the default, not the envelope. An open bound (±∞) dominates.
range_span_bounds :: proc(
	left_segs, right_segs: []Integer_Interval,
	left_open := false,
	right_open := false,
) -> (
	Maybe(i128),
	Maybe(i128),
) {
	lo: Maybe(i128) = nil
	hi: Maybe(i128) = nil
	lo_set := false
	hi_set := false
	consider :: proc(
		segs: []Integer_Interval,
		lo: ^Maybe(i128),
		hi: ^Maybe(i128),
		lo_set, hi_set: ^bool,
	) {
		for s in segs {
			if l, ok := s.lo.(i128); ok {
				if !lo_set^ {
					lo^ = l
					lo_set^ = true
				} else if cur, cok := lo^.(i128); cok && l < cur {
					lo^ = l
				}
			} else {
				lo^ = nil
				lo_set^ = true
			}
			if h, ok := s.hi.(i128); ok {
				if !hi_set^ {
					hi^ = h
					hi_set^ = true
				} else if cur, cok := hi^.(i128); cok && h > cur {
					hi^ = h
				}
			} else {
				hi^ = nil
				hi_set^ = true
			}
		}
	}
	consider(left_segs, &lo, &hi, &lo_set, &hi_set)
	consider(right_segs, &lo, &hi, &lo_set, &hi_set)
	// A bound missing in the source (`5..`, `..10`) is open to infinity on that side.
	if left_open do lo = nil
	if right_open do hi = nil
	return lo, hi
}

// --- integer interval arithmetic ---

fold_arith_integer_intervals :: proc(
	a, b: Integer_Interval,
	op: Operator_Kind,
) -> Maybe([]Integer_Interval) {
	a_lo, a_lo_ok := a.lo.(i128)
	a_hi, a_hi_ok := a.hi.(i128)
	b_lo, b_lo_ok := b.lo.(i128)
	b_hi, b_hi_ok := b.hi.(i128)

	integer_intervals := make([]Integer_Interval, 1)

	#partial switch op {
	case .Add:
		lo: Maybe(i128) = a_lo_ok && b_lo_ok ? a_lo + b_lo : nil
		hi: Maybe(i128) = a_hi_ok && b_hi_ok ? a_hi + b_hi : nil
		integer_intervals[0] = Integer_Interval{lo, hi}
		return integer_intervals
	case .Subtract:
		lo: Maybe(i128) = a_lo_ok && b_hi_ok ? a_lo - b_hi : nil
		hi: Maybe(i128) = a_hi_ok && b_lo_ok ? a_hi - b_lo : nil
		integer_intervals[0] = Integer_Interval{lo, hi}
		return integer_intervals
	case .Multiply:
		if !a_lo_ok || !a_hi_ok || !b_lo_ok || !b_hi_ok do return nil
		p1 := a_lo * b_lo
		p2 := a_lo * b_hi
		p3 := a_hi * b_lo
		p4 := a_hi * b_hi
		integer_intervals[0] = Integer_Interval{min(p1, p2, p3, p4), max(p1, p2, p3, p4)}
		return integer_intervals
	case .Divide:
		// idiv traps (SIGFPE) on a 0 divisor, so the divisor must be proven bounded and non-zero.
		if !b_lo_ok || !b_hi_ok do return nil // divisor not statically bounded
		if b_lo <= 0 && b_hi >= 0 do return nil // divisor range includes 0
		lo, hi: Maybe(i128)
		if a_lo_ok && a_hi_ok {
			p1 := a_lo / b_lo
			p2 := a_lo / b_hi
			p3 := a_hi / b_lo
			p4 := a_hi / b_hi
			lo = min(p1, p2, p3, p4)
			hi = max(p1, p2, p3, p4)
		}
		integer_intervals[0] = Integer_Interval{lo, hi}
		return integer_intervals
	case .Mod:
		// GOTCHA: `%` is not monotonic — corner-sampling is INVALID (the four endpoints
		// can coincide, e.g. 0%3 = 255%3 = 0, collapsing a real [0,2] to a false 0).
		// Derive the envelope from the magnitude bound. Like Divide, traps on a 0 divisor.
		if !b_lo_ok || !b_hi_ok do return nil // divisor not statically bounded
		if b_lo <= 0 && b_hi >= 0 do return nil // divisor range includes 0
		max_b := max(abs(b_lo), abs(b_hi))
		m := max_b - 1
		lo, hi: Maybe(i128)
		if a_lo_ok && a_lo >= 0 {
			lo = i128(0)
			hi = a_hi_ok ? min(a_hi, m) : m
		} else if a_hi_ok && a_hi <= 0 {
			lo = a_lo_ok ? max(a_lo, -m) : -m
			hi = i128(0)
		} else {
			lo = a_lo_ok ? max(a_lo, -m) : -m
			hi = a_hi_ok ? min(a_hi, m) : m
		}
		integer_intervals[0] = Integer_Interval{lo, hi}
		return integer_intervals
	case .LShift:
		if !a_lo_ok || !a_hi_ok || !b_lo_ok || !b_hi_ok do return nil
		if b_lo < 0 || b_hi >= 128 do return nil
		p1 := a_lo << u64(b_lo)
		p2 := a_lo << u64(b_hi)
		p3 := a_hi << u64(b_lo)
		p4 := a_hi << u64(b_hi)
		integer_intervals[0] = Integer_Interval{min(p1, p2, p3, p4), max(p1, p2, p3, p4)}
		return integer_intervals
	case .RShift:
		if !a_lo_ok || !a_hi_ok || !b_lo_ok || !b_hi_ok do return nil
		if b_lo < 0 || b_hi >= 128 do return nil
		p1 := a_lo >> u64(b_lo)
		p2 := a_lo >> u64(b_hi)
		p3 := a_hi >> u64(b_lo)
		p4 := a_hi >> u64(b_hi)
		integer_intervals[0] = Integer_Interval{min(p1, p2, p3, p4), max(p1, p2, p3, p4)}
		return integer_intervals
	case .BitAnd:
		if !a_lo_ok || !a_hi_ok || !b_lo_ok || !b_hi_ok do return nil
		if a_lo == a_hi && b_lo == b_hi {
			val := a_lo & b_lo
			integer_intervals[0] = Integer_Interval{val, val}
			return integer_intervals
		}
		integer_intervals[0] = Integer_Interval{i128(0), min(a_hi, b_hi)}
		return integer_intervals
	case .BitOr:
		if !a_lo_ok || !a_hi_ok || !b_lo_ok || !b_hi_ok do return nil
		if a_lo == a_hi && b_lo == b_hi {
			val := a_lo | b_lo
			integer_intervals[0] = Integer_Interval{val, val}
			return integer_intervals
		}
		integer_intervals[0] = Integer_Interval{max(a_lo, b_lo), max(a_hi, b_hi)}
		return integer_intervals
	case .Xor:
		if !a_lo_ok || !a_hi_ok || !b_lo_ok || !b_hi_ok do return nil
		if a_lo == a_hi && b_lo == b_hi {
			val := a_lo ~ b_lo
			integer_intervals[0] = Integer_Interval{val, val}
			return integer_intervals
		}
		integer_intervals[0] = Integer_Interval{i128(0), max(a_hi, b_hi)}
		return integer_intervals
	}
	return nil
}

// --- integer set operations carrying the default (Integer_Type level) ---
// The default follows the SOURCE order (left operand first) when it survives the
// fold, else the right's, else the structural fallback.

integer_type_union :: proc(a, b: Integer_Type) -> Integer_Type {
	segs := integer_intervals_union(a.integer_intervals, b.integer_intervals)
	return Integer_Type{segs, integer_pick_default(segs, a.default_value, b.default_value)}
}

integer_type_intersect :: proc(a, b: Integer_Type) -> Integer_Type {
	segs := integer_intervals_intersect(a.integer_intervals, b.integer_intervals)
	return Integer_Type{segs, integer_pick_default(segs, a.default_value, b.default_value)}
}

integer_type_negate :: proc(a: Integer_Type) -> Integer_Type {
	segs := integer_intervals_negate(a.integer_intervals)
	return Integer_Type{segs, default_for_integer_intervals(segs)}
}

// Keeps the left default when it still belongs to the folded result, else the
// right's, else the structural fallback. The membership test matters for `&`,
// which can narrow the left default out of the set.
integer_pick_default :: proc(segs: []Integer_Interval, left, right: Maybe(i128)) -> Maybe(i128) {
	if l, ok := left.(i128); ok && integer_intervals_contains(segs, l) do return l
	if r, ok := right.(i128); ok && integer_intervals_contains(segs, r) do return r
	return default_for_integer_intervals(segs)
}

integer_intervals_contains :: proc(segs: []Integer_Interval, v: i128) -> bool {
	for s in segs {
		lo, lo_ok := s.lo.(i128)
		hi, hi_ok := s.hi.(i128)
		if (!lo_ok || lo <= v) && (!hi_ok || v <= hi) do return true
	}
	return false
}

// --- integer interval set operations ---

integer_intervals_union :: proc(a, b: []Integer_Interval) -> []Integer_Interval {
	merged := make([dynamic]Integer_Interval)
	i, j := 0, 0
	for i < len(a) || j < len(b) {
		interval: Integer_Interval
		if i < len(a) && (j >= len(b) || interval_lo(a[i]) <= interval_lo(b[j])) {
			interval = a[i];i += 1
		} else {
			interval = b[j];j += 1
		}
		if len(merged) > 0 &&
		   integer_intervals_overlap_or_adjacent(merged[len(merged) - 1], interval) {
			merged[len(merged) - 1] = integer_interval_merge(merged[len(merged) - 1], interval)
		} else {
			append(&merged, interval)
		}
	}
	return merged[:]
}

integer_intervals_intersect :: proc(a, b: []Integer_Interval) -> []Integer_Interval {
	result := make([dynamic]Integer_Interval)
	j := 0
	for i := 0; i < len(a); i += 1 {
		for j < len(b) && !maybe_le(a[i].lo, b[j].hi) {
			j += 1
		}
		for k := j; k < len(b); k += 1 {
			lo := max_lo(a[i].lo, b[k].lo)
			hi := min_hi(a[i].hi, b[k].hi)
			if maybe_le(lo, hi) {
				append(&result, Integer_Interval{lo, hi})
			}
		}
	}
	return result[:]
}

integer_intervals_negate :: proc(integer_intervals: []Integer_Interval) -> []Integer_Interval {
	result := make([dynamic]Integer_Interval)
	prev_hi: Maybe(i128) = nil
	for interval in integer_intervals {
		lo, lo_ok := interval.lo.(i128)
		if lo_ok {
			append(&result, Integer_Interval{prev_hi, lo - 1})
		}
		hi, hi_ok := interval.hi.(i128)
		if hi_ok {
			prev_hi = hi + 1
		} else {
			prev_hi = nil
		}
	}
	if prev_hi != nil {
		append(&result, Integer_Interval{prev_hi, nil})
	}
	return result[:]
}

integer_intervals_normalize :: proc(integer_intervals: []Integer_Interval) -> []Integer_Interval {
	if len(integer_intervals) <= 1 do return integer_intervals
	sorted := make([]Integer_Interval, len(integer_intervals))
	copy(sorted, integer_intervals)
	for i := 1; i < len(sorted); i += 1 {
		key := sorted[i]
		j := i - 1
		for j >= 0 && interval_lo(sorted[j]) > interval_lo(key) {
			sorted[j + 1] = sorted[j]
			j -= 1
		}
		sorted[j + 1] = key
	}
	merged := make([dynamic]Integer_Interval)
	append(&merged, sorted[0])
	for i := 1; i < len(sorted); i += 1 {
		if integer_intervals_overlap_or_adjacent(merged[len(merged) - 1], sorted[i]) {
			merged[len(merged) - 1] = integer_interval_merge(merged[len(merged) - 1], sorted[i])
		} else {
			append(&merged, sorted[i])
		}
	}
	return merged[:]
}

integer_intervals_satisfy :: proc(value_segs, constraint_segs: []Integer_Interval) -> bool {
	if value_segs == nil || constraint_segs == nil do return false
	for vs in value_segs {
		found := false
		for cs in constraint_segs {
			if maybe_le(cs.lo, vs.lo) && maybe_le_hi(vs.hi, cs.hi) {
				found = true
				break
			}
		}
		if !found do return false
	}
	return true
}

// --- integer interval helpers ---


interval_lo :: #force_inline proc(s: Integer_Interval) -> i128 {
	lo, ok := s.lo.(i128)
	return ok ? lo : min(i128)
}


integer_intervals_overlap_or_adjacent :: #force_inline proc(a, b: Integer_Interval) -> bool {
	a_hi, a_ok := a.hi.(i128)
	b_lo, b_ok := b.lo.(i128)
	if !a_ok do return true
	if !b_ok do return true
	return a_hi >= b_lo - 1
}


integer_interval_merge :: #force_inline proc(a, b: Integer_Interval) -> Integer_Interval {
	return Integer_Interval{min_lo(a.lo, b.lo), max_hi(a.hi, b.hi)}
}


max_lo :: #force_inline proc(a, b: Maybe(i128)) -> Maybe(i128) {
	av, a_ok := a.(i128)
	bv, b_ok := b.(i128)
	if !a_ok do return b
	if !b_ok do return a
	return max(av, bv)
}


min_lo :: #force_inline proc(a, b: Maybe(i128)) -> Maybe(i128) {
	av, a_ok := a.(i128)
	_, b_ok := b.(i128)
	if !a_ok do return a
	if !b_ok do return b
	return av < b.(i128) ? a : b
}


max_hi :: #force_inline proc(a, b: Maybe(i128)) -> Maybe(i128) {
	av, a_ok := a.(i128)
	_, b_ok := b.(i128)
	if !a_ok do return a
	if !b_ok do return b
	return av > b.(i128) ? a : b
}


min_hi :: #force_inline proc(a, b: Maybe(i128)) -> Maybe(i128) {
	av, a_ok := a.(i128)
	bv, b_ok := b.(i128)
	if !a_ok do return b
	if !b_ok do return a
	return min(av, bv)
}


maybe_le :: #force_inline proc(lo: Maybe(i128), hi: Maybe(i128)) -> bool {
	l, l_ok := lo.(i128)
	h, h_ok := hi.(i128)
	if !l_ok || !h_ok do return true
	return l <= h
}


maybe_le_hi :: #force_inline proc(a, b: Maybe(i128)) -> bool {
	av, a_ok := a.(i128)
	bv, b_ok := b.(i128)
	if !a_ok do return !b_ok
	if !b_ok do return true
	return av <= bv
}

// --- builtin names ---

builtin_name :: proc(interval: Integer_Interval) -> Maybe(string) {
	lo, lo_ok := interval.lo.(i128)
	hi, hi_ok := interval.hi.(i128)
	if !lo_ok && !hi_ok do return "int"
	if !lo_ok || !hi_ok do return nil
	switch {
	case lo == 0 && hi == 255:
		return "u8"
	case lo == -128 && hi == 127:
		return "i8"
	case lo == 0 && hi == 65535:
		return "u16"
	case lo == -32768 && hi == 32767:
		return "i16"
	case lo == 0 && hi == 4294967295:
		return "u32"
	case lo == -2147483648 && hi == 2147483647:
		return "i32"
	case lo == 0 && hi == 18446744073709551615:
		return "u64"
	case lo == -9223372036854775808 && hi == 9223372036854775807:
		return "i64"
	}
	return nil
}

builtin_alias :: proc(interval: Integer_Interval) -> string {
	lo, lo_ok := interval.lo.(i128)
	hi, hi_ok := interval.hi.(i128)
	if !lo_ok || !hi_ok do return ""
	if lo == 0 && hi == 255 do return "u8"
	if lo == -128 && hi == 127 do return "i8"
	if lo == 0 && hi == 65535 do return "u16"
	if lo == -32768 && hi == 32767 do return "i16"
	if lo == 0 && hi == 4294967295 do return "u32"
	if lo == -2147483648 && hi == 2147483647 do return "i32"
	if lo == 0 && hi == 18446744073709551615 do return "u64"
	if lo == -9223372036854775808 && hi == 9223372036854775807 do return "i64"
	return ""
}

// Binary layout (bit width + signedness) of a single integer interval, used by
// the raw cast `::`. Only the fixed-width builtins have a canonical layout;
// everything else returns ok=false (the cast is then an Invalid_Cast).
Int_Layout :: struct {
	bits:   uint, // 8, 16, 32, 64
	signed: bool,
}

int_layout :: proc(interval: Integer_Interval) -> (Int_Layout, bool) {
	lo, lo_ok := interval.lo.(i128)
	hi, hi_ok := interval.hi.(i128)
	if !lo_ok || !hi_ok do return {}, false
	switch {
	case lo == 0 && hi == 255:
		return {8, false}, true
	case lo == -128 && hi == 127:
		return {8, true}, true
	case lo == 0 && hi == 65535:
		return {16, false}, true
	case lo == -32768 && hi == 32767:
		return {16, true}, true
	case lo == 0 && hi == 4294967295:
		return {32, false}, true
	case lo == -2147483648 && hi == 2147483647:
		return {32, true}, true
	case lo == 0 && hi == 18446744073709551615:
		return {64, false}, true
	case lo == -9223372036854775808 && hi == 9223372036854775807:
		return {64, true}, true
	}
	return {}, false
}

// Bit_Repr is the raw bit pattern of a concrete value of ANY domain, with the
// width/signedness to extend or truncate it; the `::` raw cast works in this
// representation (see type.odin). `bits` holds the low `width` bits. `from_float`
// is set for a float source so a float->float cast converts the VALUE (IEEE
// rounding) rather than transmuting bits (`f64 1.0 :: f32` yields 1.0f).
Bit_Repr :: struct {
	bits:       u128,
	width:      uint,
	signed:     bool,
	from_float: Maybe(f64),
}

// resize_bits pads or cuts a `from_width`-wide pattern to `to_width`: sign-extend
// a signed source with its top bit set, zero-extend otherwise, truncate when narrowing.
resize_bits :: proc(bits: u128, from_width: uint, from_signed: bool, to_width: uint) -> u128 {
	b := bits
	if from_width < 128 {
		b &= (u128(1) << from_width) - 1
	}
	if to_width < from_width {
		if to_width < 128 {
			b &= (u128(1) << to_width) - 1
		}
	} else if to_width > from_width {
		if from_signed && from_width < 128 {
			sign_bit := u128(1) << (from_width - 1)
			if b & sign_bit != 0 {
				fill := ~((u128(1) << from_width) - 1)
				if to_width < 128 do fill &= (u128(1) << to_width) - 1
				b |= fill
			}
		}
	}
	return b
}

bits_reinterpret_int :: proc(repr: Bit_Repr, to_width: uint, to_signed: bool) -> i128 {
	b := resize_bits(repr.bits, repr.width, repr.signed, to_width)
	if to_signed && to_width < 128 {
		sign_bit := u128(1) << (to_width - 1)
		if b & sign_bit != 0 {
			return i128(b) - i128(u128(1) << to_width)
		}
	}
	return i128(b)
}

pretty_integer_intervals :: proc(integer_intervals: []Integer_Interval) -> string {
	if len(integer_intervals) == 1 {
		alias := builtin_alias(integer_intervals[0])
		if alias != "" do return alias
	}
	b := strings.builder_make()
	for interval, i in integer_intervals {
		if i > 0 do strings.write_string(&b, " | ")
		lo, lo_ok := interval.lo.(i128)
		hi, hi_ok := interval.hi.(i128)
		if lo_ok && hi_ok && lo == hi {
			strings.write_string(&b, fmt.tprintf("%d", lo))
		} else {
			if lo_ok {
				strings.write_string(&b, fmt.tprintf("%d", lo))
			} else {
				strings.write_string(&b, "-inf")
			}
			strings.write_string(&b, "..")
			if hi_ok {
				strings.write_string(&b, fmt.tprintf("%d", hi))
			} else {
				strings.write_string(&b, "inf")
			}
		}
	}
	return strings.to_string(b)
}
