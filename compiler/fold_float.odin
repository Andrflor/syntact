package compiler

import "core:fmt"
import "core:strings"

// fold_float.odin — the float domain, mirror of fold_integer.odin.
//
// A Float_Type carries three things: a list of Float_Intervals (the numeric
// envelope, nil bound = ±∞), a FloatKind color (.none / .f32 / .f64), and a
// default_value. f32 is Float_Type{[{nil,nil}], .f32, 0}; f64 likewise with
// .f64; a literal 3.14 is Float_Type{[{3.14,3.14}], .none, 3.14}; a float
// range low..hi is Float_Type{[{low,hi}], .none, …}.
//
// The .none kind means "uncolored" — a literal or range. Color compatibility
// (float_kind_compatible) is the extra check the integer domain doesn't have:
//   - a .none constraint accepts .none / .f32 / .f64 values (any float fits)
//   - a .f64 constraint accepts only .f64 or .none values
//   - a .f32 constraint accepts only .f32 or .none values
// i.e. the kinds match when they're equal or at least one side is .none.


float_is_concrete :: #force_inline proc(t: Float_Type) -> bool {
	return float_intervals_is_concrete(t.float_intervals)
}


float_intervals_is_concrete :: #force_inline proc(float_intervals: []Float_Interval) -> bool {
	if len(float_intervals) != 1 do return false
	lo, lo_ok := float_intervals[0].lo.(f64)
	hi, hi_ok := float_intervals[0].hi.(f64)
	return lo_ok && hi_ok && lo == hi
}


float_value :: #force_inline proc(t: Float_Type) -> f64 {
	return t.float_intervals[0].lo.(f64)
}


make_float_result :: #force_inline proc(val: f64, kind: FloatKind = .none) -> Type {
	float_intervals := make([]Float_Interval, 1)
	float_intervals[0] = Float_Interval{val, val}
	return Float_Type{float_intervals, kind, val}
}

// float_kind_compatible reports whether a value of kind `vk` may be colored by
// a constraint of kind `ck`. Equal kinds match; .none on either side matches.
float_kind_compatible :: #force_inline proc(ck, vk: FloatKind) -> bool {
	if ck == .none || vk == .none do return true
	return ck == vk
}

// --- float domain entry points (return reduced ^Type / bool / string) ---

// fold_type_float derives the float envelope a value produces and wraps it in a
// Float_Type, or nil if the value is not float-foldable.
fold_type_float :: proc(t: ^Type) -> ^Type {
	segs, kind, ok := fold_type_float_intervals(t)
	if !ok do return nil
	return wrap_float_intervals(segs, kind)
}

// fold_constraint_float resolves a float constraint to a closed Float_Type, or
// nil if it cannot be resolved statically.
fold_constraint_float :: proc(t: ^Type) -> ^Type {
	segs, kind, ok := fold_constraint_float_intervals(t)
	if !ok do return nil
	return wrap_float_intervals(segs, kind)
}

wrap_float_intervals :: proc(segs: []Float_Interval, kind: FloatKind) -> ^Type {
	r := new(Type)
	r^ = Float_Type{segs, kind, default_for_float_intervals(segs)}
	return r
}

// float_satisfy proves ft ⊆ fc when both are float-domain Float_Types: the
// numeric envelope must fit AND the colors must be compatible.
float_satisfy :: proc(fc, ft: Float_Type) -> bool {
	if !float_kind_compatible(fc.kind, ft.kind) do return false
	return float_intervals_satisfy(ft.float_intervals, fc.float_intervals)
}

float_to_string :: proc(t: Float_Type) -> string {
	return pretty_float_intervals(t.float_intervals, t.kind)
}

// stored_fold_float extracts the (intervals, kind) payload from a folded ^Type
// as cached in type_folds / constraint_folds when it is a Float_Type.
stored_fold_float :: proc(t: ^Type) -> (segs: []Float_Interval, kind: FloatKind, ok: bool) {
	if t == nil do return nil, .none, false
	#partial switch v in t^ {
	case Float_Type:
		return v.float_intervals, v.kind, true
	}
	return nil, .none, false
}

// --- float interval fold ---

fold_type_float_intervals :: proc(
	t: ^Type,
) -> (
	segs: []Float_Interval,
	kind: FloatKind,
	ok: bool,
) {
	if t == nil do return nil, .none, false
	#partial switch v in t^ {
	case Scope_Type:
		for i := 0; i < len(v.kind); i += 1 {
			if v.kind[i] == .Product {
				if s, k, sok := stored_fold_float(v.type_folds[i]); sok {
					return s, k, true
				}
				return fold_type_float_intervals(v.values[i])
			}
		}
		return nil, .none, false
	case Float_Type:
		return v.float_intervals, v.kind, true
	case Range_Type:
		left_segs, left_kind, left_ok := fold_type_float_intervals(v.left)
		right_segs, right_kind, right_ok := fold_type_float_intervals(v.right)
		if v.left != nil && !left_ok do return nil, .none, false
		if v.right != nil && !right_ok do return nil, .none, false
		lo: Maybe(f64) = nil
		hi: Maybe(f64) = nil
		if left_ok && len(left_segs) > 0 do lo = left_segs[0].lo
		if right_ok && len(right_segs) > 0 do hi = right_segs[len(right_segs) - 1].hi
		float_intervals := make([]Float_Interval, 1)
		float_intervals[0] = Float_Interval{lo, hi}
		return float_intervals, promote_float_kind(left_kind, right_kind), true
	case Compose_Type:
		if v.type_fold != nil {
			return fold_type_float_intervals(v.type_fold)
		}
		if v.left == nil {
			right_segs, right_kind, right_ok := fold_type_float_intervals(v.right)
			if !right_ok do return nil, .none, false
			#partial switch v.operator {
			case .Greater:
				hi, hi_ok := right_segs[0].hi.(f64)
				if !hi_ok do return nil, .none, false
				float_intervals := make([]Float_Interval, 1)
				float_intervals[0] = Float_Interval{hi, nil}
				return float_intervals, right_kind, true
			case .GreaterEqual:
				float_intervals := make([]Float_Interval, 1)
				float_intervals[0] = Float_Interval{right_segs[0].lo, nil}
				return float_intervals, right_kind, true
			case .Less:
				lo, lo_ok := right_segs[0].lo.(f64)
				if !lo_ok do return nil, .none, false
				float_intervals := make([]Float_Interval, 1)
				float_intervals[0] = Float_Interval{nil, lo}
				return float_intervals, right_kind, true
			case .LessEqual:
				float_intervals := make([]Float_Interval, 1)
				float_intervals[0] = Float_Interval{nil, right_segs[0].hi}
				return float_intervals, right_kind, true
			case .Subtract:
				lo, lo_ok := right_segs[0].lo.(f64)
				hi, hi_ok := right_segs[0].hi.(f64)
				if !lo_ok || !hi_ok do return nil, .none, false
				float_intervals := make([]Float_Interval, 1)
				float_intervals[0] = Float_Interval{-hi, -lo}
				return float_intervals, right_kind, true
			}
			return nil, .none, false
		}
		left_segs, left_kind, left_ok := fold_type_float_intervals(v.left)
		right_segs, right_kind, right_ok := fold_type_float_intervals(v.right)
		if !left_ok || !right_ok do return nil, .none, false
		// Two floats only combine if their colors are compatible (f32 vs f64
		// don't). An incompatible pair fails the fold → diagnose_compose explains.
		if !float_kind_compatible(left_kind, right_kind) do return nil, .none, false
		if len(left_segs) == 0 || len(right_segs) == 0 do return nil, .none, false
		result := make([dynamic]Float_Interval)
		for ls in left_segs {
			for rs in right_segs {
				pair, pair_ok := fold_arith_float_intervals(ls, rs, v.operator).([]Float_Interval)
				if !pair_ok do return nil, .none, false
				for s in pair do append(&result, s)
			}
		}
		return float_intervals_normalize(result[:]), promote_float_kind(left_kind, right_kind), true
	case Mention_Type:
		if v.match_scope != nil && v.match_index >= 0 {
			if s, k, sok := stored_fold_float(v.match_scope.type_folds[v.match_index]); sok {
				return s, k, true
			}
			if s, k, sok := stored_fold_float(v.match_scope.constraint_folds[v.match_index]); sok {
				return s, k, true
			}
		}
		return nil, .none, false
	case Reference_Type:
		ref := v.reference
		if ref == nil || ref.match_scope == nil || ref.match_index < 0 do return nil, .none, false
		if s, k, sok := stored_fold_float(ref.match_scope.type_folds[ref.match_index]); sok {
			return s, k, true
		}
		if s, k, sok := stored_fold_float(ref.match_scope.constraint_folds[ref.match_index]); sok {
			return s, k, true
		}
		return nil, .none, false
	}
	return nil, .none, false
}

fold_constraint_float_intervals :: proc(
	t: ^Type,
) -> (
	segs: []Float_Interval,
	kind: FloatKind,
	ok: bool,
) {
	if t == nil do return nil, .none, false
	#partial switch v in t^ {
	case Scope_Type:
		for i := 0; i < len(v.kind); i += 1 {
			if v.kind[i] == .Product {
				return fold_constraint_float_intervals(v.values[i])
			}
		}
		return nil, .none, false
	case Float_Type:
		return v.float_intervals, v.kind, true
	case Range_Type:
		left_segs, left_kind, left_ok := fold_constraint_float_intervals(v.left)
		right_segs, right_kind, right_ok := fold_constraint_float_intervals(v.right)
		if v.left != nil && !left_ok do return nil, .none, false
		if v.right != nil && !right_ok do return nil, .none, false
		lo: Maybe(f64) = nil
		hi: Maybe(f64) = nil
		if left_ok && len(left_segs) > 0 do lo = left_segs[0].lo
		if right_ok && len(right_segs) > 0 do hi = right_segs[len(right_segs) - 1].hi
		float_intervals := make([]Float_Interval, 1)
		float_intervals[0] = Float_Interval{lo, hi}
		return float_intervals, promote_float_kind(left_kind, right_kind), true
	case Compose_Type:
		if v.type_fold != nil {
			return fold_constraint_float_intervals(v.type_fold)
		}
		return fold_type_float_intervals(t)
	case Or_Type:
		left, left_kind, left_ok := fold_constraint_float_intervals(v.left)
		right, right_kind, right_ok := fold_constraint_float_intervals(v.right)
		if !left_ok do return right, right_kind, right_ok
		if !right_ok do return left, left_kind, true
		return float_intervals_union(left, right), promote_float_kind(left_kind, right_kind), true
	case And_Type:
		left, left_kind, left_ok := fold_constraint_float_intervals(v.left)
		right, right_kind, right_ok := fold_constraint_float_intervals(v.right)
		if !left_ok || !right_ok do return nil, .none, false
		return float_intervals_intersect(left, right),
			promote_float_kind(left_kind, right_kind),
			true
	case Negate_Type:
		inner, inner_kind, inner_ok := fold_constraint_float_intervals(v.operand)
		if !inner_ok do return nil, .none, false
		return float_intervals_negate(inner), inner_kind, true
	case Mention_Type:
		if v.match_scope != nil && v.match_index >= 0 {
			return fold_constraint_float_intervals(v.match_scope.values[v.match_index])
		}
	case Reference_Type:
		ref := v.reference
		if ref != nil && ref.match_scope != nil && ref.match_index >= 0 {
			return fold_constraint_float_intervals(ref.match_scope.values[ref.match_index])
		}
	}
	return nil, .none, false
}

// --- float interval arithmetic ---

fold_arith_float_intervals :: proc(
	a, b: Float_Interval,
	op: Operator_Kind,
) -> Maybe([]Float_Interval) {
	a_lo, a_lo_ok := a.lo.(f64)
	a_hi, a_hi_ok := a.hi.(f64)
	b_lo, b_lo_ok := b.lo.(f64)
	b_hi, b_hi_ok := b.hi.(f64)

	float_intervals := make([]Float_Interval, 1)

	#partial switch op {
	case .Add:
		lo: Maybe(f64) = a_lo_ok && b_lo_ok ? a_lo + b_lo : nil
		hi: Maybe(f64) = a_hi_ok && b_hi_ok ? a_hi + b_hi : nil
		float_intervals[0] = Float_Interval{lo, hi}
		return float_intervals
	case .Subtract:
		lo: Maybe(f64) = a_lo_ok && b_hi_ok ? a_lo - b_hi : nil
		hi: Maybe(f64) = a_hi_ok && b_lo_ok ? a_hi - b_lo : nil
		float_intervals[0] = Float_Interval{lo, hi}
		return float_intervals
	case .Multiply:
		if !a_lo_ok || !a_hi_ok || !b_lo_ok || !b_hi_ok do return nil
		p1 := a_lo * b_lo
		p2 := a_lo * b_hi
		p3 := a_hi * b_lo
		p4 := a_hi * b_hi
		float_intervals[0] = Float_Interval{min(p1, p2, p3, p4), max(p1, p2, p3, p4)}
		return float_intervals
	case .Divide:
		if !a_lo_ok || !a_hi_ok || !b_lo_ok || !b_hi_ok do return nil
		if b_lo <= 0 && b_hi >= 0 do return nil // divisor interval straddles 0
		p1 := a_lo / b_lo
		p2 := a_lo / b_hi
		p3 := a_hi / b_lo
		p4 := a_hi / b_hi
		float_intervals[0] = Float_Interval{min(p1, p2, p3, p4), max(p1, p2, p3, p4)}
		return float_intervals
	}
	return nil
}

// --- float interval set operations ---

float_intervals_union :: proc(a, b: []Float_Interval) -> []Float_Interval {
	merged := make([dynamic]Float_Interval)
	i, j := 0, 0
	for i < len(a) || j < len(b) {
		interval: Float_Interval
		if i < len(a) && (j >= len(b) || float_interval_lo(a[i]) <= float_interval_lo(b[j])) {
			interval = a[i];i += 1
		} else {
			interval = b[j];j += 1
		}
		if len(merged) > 0 && float_intervals_overlap(merged[len(merged) - 1], interval) {
			merged[len(merged) - 1] = float_interval_merge(merged[len(merged) - 1], interval)
		} else {
			append(&merged, interval)
		}
	}
	return merged[:]
}

float_intervals_intersect :: proc(a, b: []Float_Interval) -> []Float_Interval {
	result := make([dynamic]Float_Interval)
	for i := 0; i < len(a); i += 1 {
		for k := 0; k < len(b); k += 1 {
			lo := float_max_lo(a[i].lo, b[k].lo)
			hi := float_min_hi(a[i].hi, b[k].hi)
			if float_maybe_le(lo, hi) {
				append(&result, Float_Interval{lo, hi})
			}
		}
	}
	return result[:]
}

// float_intervals_negate mirrors the integer negate but over the real line —
// there is no +1/-1 adjacency for floats, so the complement of [lo, hi] is
// (-∞, lo) ∪ (hi, +∞). We keep closed bounds (lo / hi) as the cut points; the
// resulting intervals are the open-ended complement, which is sufficient for
// the subset checks the analyzer performs.
float_intervals_negate :: proc(float_intervals: []Float_Interval) -> []Float_Interval {
	result := make([dynamic]Float_Interval)
	prev_hi: Maybe(f64) = nil
	for interval in float_intervals {
		lo, lo_ok := interval.lo.(f64)
		if lo_ok {
			append(&result, Float_Interval{prev_hi, lo})
		}
		hi, hi_ok := interval.hi.(f64)
		if hi_ok {
			prev_hi = hi
		} else {
			prev_hi = nil
		}
	}
	if prev_hi != nil {
		append(&result, Float_Interval{prev_hi, nil})
	}
	return result[:]
}

float_intervals_normalize :: proc(float_intervals: []Float_Interval) -> []Float_Interval {
	if len(float_intervals) <= 1 do return float_intervals
	sorted := make([]Float_Interval, len(float_intervals))
	copy(sorted, float_intervals)
	for i := 1; i < len(sorted); i += 1 {
		key := sorted[i]
		j := i - 1
		for j >= 0 && float_interval_lo(sorted[j]) > float_interval_lo(key) {
			sorted[j + 1] = sorted[j]
			j -= 1
		}
		sorted[j + 1] = key
	}
	merged := make([dynamic]Float_Interval)
	append(&merged, sorted[0])
	for i := 1; i < len(sorted); i += 1 {
		if float_intervals_overlap(merged[len(merged) - 1], sorted[i]) {
			merged[len(merged) - 1] = float_interval_merge(merged[len(merged) - 1], sorted[i])
		} else {
			append(&merged, sorted[i])
		}
	}
	return merged[:]
}

float_intervals_satisfy :: proc(value_segs, constraint_segs: []Float_Interval) -> bool {
	if value_segs == nil || constraint_segs == nil do return false
	for vs in value_segs {
		found := false
		for cs in constraint_segs {
			if float_maybe_le(cs.lo, vs.lo) && float_maybe_le_hi(vs.hi, cs.hi) {
				found = true
				break
			}
		}
		if !found do return false
	}
	return true
}

// --- float interval helpers ---

float_interval_lo :: #force_inline proc(s: Float_Interval) -> f64 {
	lo, ok := s.lo.(f64)
	return ok ? lo : min(f64)
}


float_intervals_overlap :: #force_inline proc(a, b: Float_Interval) -> bool {
	a_hi, a_ok := a.hi.(f64)
	b_lo, b_ok := b.lo.(f64)
	if !a_ok do return true
	if !b_ok do return true
	return a_hi >= b_lo
}


float_interval_merge :: #force_inline proc(a, b: Float_Interval) -> Float_Interval {
	return Float_Interval{float_min_lo(a.lo, b.lo), float_max_hi(a.hi, b.hi)}
}


float_max_lo :: #force_inline proc(a, b: Maybe(f64)) -> Maybe(f64) {
	av, a_ok := a.(f64)
	bv, b_ok := b.(f64)
	if !a_ok do return b
	if !b_ok do return a
	return max(av, bv)
}


float_min_lo :: #force_inline proc(a, b: Maybe(f64)) -> Maybe(f64) {
	av, a_ok := a.(f64)
	bv, b_ok := b.(f64)
	if !a_ok do return a
	if !b_ok do return b
	return av < bv ? a : b
}


float_max_hi :: #force_inline proc(a, b: Maybe(f64)) -> Maybe(f64) {
	av, a_ok := a.(f64)
	bv, b_ok := b.(f64)
	if !a_ok do return a
	if !b_ok do return b
	return av > bv ? a : b
}


float_min_hi :: #force_inline proc(a, b: Maybe(f64)) -> Maybe(f64) {
	av, a_ok := a.(f64)
	bv, b_ok := b.(f64)
	if !a_ok do return b
	if !b_ok do return a
	return min(av, bv)
}


float_maybe_le :: #force_inline proc(lo: Maybe(f64), hi: Maybe(f64)) -> bool {
	l, l_ok := lo.(f64)
	h, h_ok := hi.(f64)
	if !l_ok || !h_ok do return true
	return l <= h
}


float_maybe_le_hi :: #force_inline proc(a, b: Maybe(f64)) -> bool {
	av, a_ok := a.(f64)
	bv, b_ok := b.(f64)
	if !a_ok do return !b_ok
	if !b_ok do return true
	return av <= bv
}

// --- pretty printing ---

float_format :: proc(b: ^strings.Builder, f: f64) {
	strings.write_string(b, float_display(f))
}

// float_display renders a float so it always reads as a float — a whole value
// like 4.0 prints "4.0", never "4" (which would look like an integer).
float_display :: proc(f: f64) -> string {
	s := fmt.tprintf("%v", f)
	if strings.index_byte(s, '.') < 0 &&
	   strings.index_byte(s, 'e') < 0 &&
	   strings.index_byte(s, 'E') < 0 &&
	   strings.index_byte(s, 'n') < 0 && // nan
	   strings.index_byte(s, 'i') < 0 { 	// inf
		return strings.concatenate({s, ".0"})
	}
	return s
}

pretty_float_intervals :: proc(float_intervals: []Float_Interval, kind: FloatKind) -> string {
	b := strings.builder_make()
	if len(float_intervals) == 1 {
		lo, lo_ok := float_intervals[0].lo.(f64)
		hi, hi_ok := float_intervals[0].hi.(f64)
		if !lo_ok && !hi_ok {
			switch kind {
			case .none:
				strings.write_string(&b, "Float")
			case .f32:
				strings.write_string(&b, "f32")
			case .f64:
				strings.write_string(&b, "f64")
			}
			return strings.to_string(b)
		}
		if lo_ok && hi_ok && lo == hi {
			float_format(&b, lo)
			return strings.to_string(b)
		}
	}
	for interval, i in float_intervals {
		if i > 0 do strings.write_string(&b, " | ")
		lo, lo_ok := interval.lo.(f64)
		hi, hi_ok := interval.hi.(f64)
		if lo_ok && hi_ok && lo == hi {
			float_format(&b, lo)
		} else {
			if lo_ok {
				float_format(&b, lo)
			} else {
				strings.write_string(&b, "-inf")
			}
			strings.write_string(&b, "..")
			if hi_ok {
				float_format(&b, hi)
			} else {
				strings.write_string(&b, "inf")
			}
		}
	}
	return strings.to_string(b)
}
