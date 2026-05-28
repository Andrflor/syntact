package compiler

import "core:fmt"
import "core:strings"


int_is_concrete :: #force_inline proc(t: Integer_Type) -> bool {
	return segs_is_concrete(t.segments)
}


segs_is_concrete :: #force_inline proc(segs: []Segment) -> bool {
	if len(segs) != 1 do return false
	lo, lo_ok := segs[0].lo.(i64)
	hi, hi_ok := segs[0].hi.(i64)
	return lo_ok && hi_ok && lo == hi
}


int_value :: #force_inline proc(t: Integer_Type) -> i64 {
	return t.segments[0].lo.(i64)
}


make_int_result :: #force_inline proc(val: i64) -> Type {
	segs := make([]Segment, 1)
	segs[0] = Segment{val, val}
	return Integer_Type{segs, val}
}


int_to_f64 :: #force_inline proc(i: Integer_Type) -> f64 {
	return f64(int_value(i))
}

// --- segment fold ---

fold_to_segments :: proc(t: ^Type) -> Maybe([]Segment) {
	if t == nil do return nil
	#partial switch v in t^ {
	case Scope_Type:
		for i := 0; i < len(v.kind); i += 1 {
			if v.kind[i] == .Product {
				if v.type_folds[i] != nil do return v.type_folds[i]
				return fold_to_segments(v.values[i])
			}
		}
		return nil
	case Integer_Type:
		return v.segments
	case Range_Type:
		left_segs, left_ok := fold_to_segments(v.left).([]Segment)
		right_segs, right_ok := fold_to_segments(v.right).([]Segment)
		if v.left != nil && !left_ok do return nil
		if v.right != nil && !right_ok do return nil
		lo: Maybe(i64) = nil
		hi: Maybe(i64) = nil
		if left_ok && len(left_segs) > 0 {
			lo = left_segs[0].lo
		}
		if right_ok && len(right_segs) > 0 {
			hi = right_segs[len(right_segs) - 1].hi
		}
		segs := make([]Segment, 1)
		segs[0] = Segment{lo, hi}
		return segs
	case Compose_Type:
		if v.type_fold != nil {
			return fold_to_segments(v.type_fold)
		}
		if v.left == nil {
			right_segs, right_ok := fold_to_segments(v.right).([]Segment)
			if !right_ok do return nil
			#partial switch v.operator {
			case .Greater:
				hi, hi_ok := right_segs[0].hi.(i64)
				if !hi_ok do return nil
				segs := make([]Segment, 1)
				segs[0] = Segment{hi + 1, nil}
				return segs
			case .GreaterEqual:
				segs := make([]Segment, 1)
				segs[0] = Segment{right_segs[0].lo, nil}
				return segs
			case .Less:
				lo, lo_ok := right_segs[0].lo.(i64)
				if !lo_ok do return nil
				segs := make([]Segment, 1)
				segs[0] = Segment{nil, lo - 1}
				return segs
			case .LessEqual:
				segs := make([]Segment, 1)
				segs[0] = Segment{nil, right_segs[0].hi}
				return segs
			case .Subtract:
				lo, lo_ok := right_segs[0].lo.(i64)
				hi, hi_ok := right_segs[0].hi.(i64)
				if !lo_ok || !hi_ok do return nil
				segs := make([]Segment, 1)
				segs[0] = Segment{-hi, -lo}
				return segs
			}
			return nil
		}
		left_segs, left_ok := fold_to_segments(v.left).([]Segment)
		right_segs, right_ok := fold_to_segments(v.right).([]Segment)
		if !left_ok || !right_ok do return nil
		if len(left_segs) == 0 || len(right_segs) == 0 do return nil
		result := make([dynamic]Segment)
		for ls in left_segs {
			for rs in right_segs {
				pair, pair_ok := fold_arith_segments(ls, rs, v.operator).([]Segment)
				if !pair_ok do return nil
				for s in pair {
					append(&result, s)
				}
			}
		}
		return segments_normalize(result[:])
	case Mention_Type:
		if v.match_scope != nil && v.match_index >= 0 {
			if v.match_scope.type_folds[v.match_index] != nil {
				return v.match_scope.type_folds[v.match_index]
			}
			if v.match_scope.constraint_folds[v.match_index] != nil {
				return v.match_scope.constraint_folds[v.match_index]
			}
		}
		return nil
	case Reference_Type:
		ref := v.reference
		if ref == nil || ref.match_scope == nil || ref.match_index < 0 do return nil
		if v.target != nil {
			carve_segs := carve_fold_lookup(v.target, ref.match_index)
			if carve_segs != nil do return carve_segs
		}
		if ref.match_scope.type_folds[ref.match_index] != nil {
			return ref.match_scope.type_folds[ref.match_index]
		}
		if ref.match_scope.constraint_folds[ref.match_index] != nil {
			return ref.match_scope.constraint_folds[ref.match_index]
		}
		return nil
	}
	return nil
}

fold_constraint :: proc(t: ^Type) -> Maybe([]Segment) {
	if t == nil do return nil
	#partial switch v in t^ {
	case Scope_Type:
		for i := 0; i < len(v.kind); i += 1 {
			if v.kind[i] == .Product {
				if v.type_folds[i] != nil do return v.type_folds[i]
				return fold_constraint(v.values[i])
			}
		}
		return nil
	case Integer_Type:
		return v.segments
	case Range_Type:
		left_segs, left_ok := fold_constraint(v.left).([]Segment)
		right_segs, right_ok := fold_constraint(v.right).([]Segment)
		if v.left != nil && !left_ok do return nil
		if v.right != nil && !right_ok do return nil
		lo: Maybe(i64) = nil
		hi: Maybe(i64) = nil
		if left_ok && len(left_segs) > 0 {
			lo = left_segs[0].lo
		}
		if right_ok && len(right_segs) > 0 {
			hi = right_segs[len(right_segs) - 1].hi
		}
		segs := make([]Segment, 1)
		segs[0] = Segment{lo, hi}
		return segs
	case Compose_Type:
		if v.type_fold != nil {
			return fold_constraint(v.type_fold)
		}
		return fold_to_segments(t)
	case Sum_Type:
		left, left_ok := fold_constraint(v.left).([]Segment)
		right, right_ok := fold_constraint(v.right).([]Segment)
		if !left_ok do return right_ok ? right : nil
		if !right_ok do return left
		return segments_union(left, right)
	case Product_Type:
		left, left_ok := fold_constraint(v.left).([]Segment)
		right, right_ok := fold_constraint(v.right).([]Segment)
		if !left_ok || !right_ok do return nil
		return segments_intersect(left, right)
	case Negate_Type:
		inner, inner_ok := fold_constraint(v.operand).([]Segment)
		if !inner_ok do return nil
		return segments_negate(inner)
	case Mention_Type:
		if v.match_scope != nil && v.match_index >= 0 {
			if v.match_scope.constraint_folds[v.match_index] != nil {
				return v.match_scope.constraint_folds[v.match_index]
			}
			if v.match_scope.type_folds[v.match_index] != nil {
				return v.match_scope.type_folds[v.match_index]
			}
			return fold_constraint(v.match_scope.values[v.match_index])
		}
	case Reference_Type:
		ref := v.reference
		if ref != nil && ref.match_scope != nil && ref.match_index >= 0 {
			if ref.match_scope.constraint_folds[ref.match_index] != nil {
				return ref.match_scope.constraint_folds[ref.match_index]
			}
			if ref.match_scope.type_folds[ref.match_index] != nil {
				return ref.match_scope.type_folds[ref.match_index]
			}
			return fold_constraint(ref.match_scope.values[ref.match_index])
		}
	}
	return nil
}

carve_fold_lookup :: proc(t: ^Type, index: int) -> []Segment {
	if t == nil do return nil
	target := t
	for {
		#partial switch v in target^ {
		case Carve_Type:
			for i := 0; i < len(v.references); i += 1 {
				if v.references[i].match_index == index {
					segs, ok := fold_to_segments(v.values[i]).([]Segment)
					if ok do return segs
					segs2, ok2 := fold_constraint(v.values[i]).([]Segment)
					if ok2 do return segs2
					return nil
				}
			}
			target = v.source
			continue
		case Mention_Type:
			if v.match_scope != nil && v.match_index >= 0 {
				target = v.match_scope.values[v.match_index]
				continue
			}
		}
		break
	}
	return nil
}

// --- segment arithmetic ---

fold_arith_segments :: proc(a, b: Segment, op: Operator_Kind) -> Maybe([]Segment) {
	a_lo, a_lo_ok := a.lo.(i64)
	a_hi, a_hi_ok := a.hi.(i64)
	b_lo, b_lo_ok := b.lo.(i64)
	b_hi, b_hi_ok := b.hi.(i64)

	segs := make([]Segment, 1)

	#partial switch op {
	case .Add:
		lo: Maybe(i64) = a_lo_ok && b_lo_ok ? a_lo + b_lo : nil
		hi: Maybe(i64) = a_hi_ok && b_hi_ok ? a_hi + b_hi : nil
		segs[0] = Segment{lo, hi}
		return segs
	case .Subtract:
		lo: Maybe(i64) = a_lo_ok && b_hi_ok ? a_lo - b_hi : nil
		hi: Maybe(i64) = a_hi_ok && b_lo_ok ? a_hi - b_lo : nil
		segs[0] = Segment{lo, hi}
		return segs
	case .Multiply:
		if !a_lo_ok || !a_hi_ok || !b_lo_ok || !b_hi_ok do return nil
		p1 := a_lo * b_lo
		p2 := a_lo * b_hi
		p3 := a_hi * b_lo
		p4 := a_hi * b_hi
		segs[0] = Segment{min(p1, p2, p3, p4), max(p1, p2, p3, p4)}
		return segs
	case .Divide:
		if !a_lo_ok || !a_hi_ok || !b_lo_ok || !b_hi_ok do return nil
		if b_lo == 0 && b_hi == 0 do return nil
		bl := b_lo == 0 ? i64(1) : b_lo
		bh := b_hi == 0 ? i64(-1) : b_hi
		if bl > bh do return nil
		p1 := a_lo / bl
		p2 := a_lo / bh
		p3 := a_hi / bl
		p4 := a_hi / bh
		segs[0] = Segment{min(p1, p2, p3, p4), max(p1, p2, p3, p4)}
		return segs
	case .Mod:
		if !a_lo_ok || !a_hi_ok || !b_lo_ok || !b_hi_ok do return nil
		if b_lo == 0 && b_hi == 0 do return nil
		bl := b_lo == 0 ? i64(1) : b_lo
		bh := b_hi == 0 ? i64(-1) : b_hi
		if bl > bh do return nil
		p1 := a_lo %% bl
		p2 := a_lo %% bh
		p3 := a_hi %% bl
		p4 := a_hi %% bh
		segs[0] = Segment{min(p1, p2, p3, p4), max(p1, p2, p3, p4)}
		return segs
	case .LShift:
		if !a_lo_ok || !a_hi_ok || !b_lo_ok || !b_hi_ok do return nil
		if b_lo < 0 || b_hi >= 64 do return nil
		p1 := a_lo << u64(b_lo)
		p2 := a_lo << u64(b_hi)
		p3 := a_hi << u64(b_lo)
		p4 := a_hi << u64(b_hi)
		segs[0] = Segment{min(p1, p2, p3, p4), max(p1, p2, p3, p4)}
		return segs
	case .RShift:
		if !a_lo_ok || !a_hi_ok || !b_lo_ok || !b_hi_ok do return nil
		if b_lo < 0 || b_hi >= 64 do return nil
		p1 := a_lo >> u64(b_lo)
		p2 := a_lo >> u64(b_hi)
		p3 := a_hi >> u64(b_lo)
		p4 := a_hi >> u64(b_hi)
		segs[0] = Segment{min(p1, p2, p3, p4), max(p1, p2, p3, p4)}
		return segs
	case .BitAnd:
		if !a_lo_ok || !a_hi_ok || !b_lo_ok || !b_hi_ok do return nil
		if a_lo == a_hi && b_lo == b_hi {
			val := a_lo & b_lo
			segs[0] = Segment{val, val}
			return segs
		}
		segs[0] = Segment{i64(0), min(a_hi, b_hi)}
		return segs
	case .BitOr:
		if !a_lo_ok || !a_hi_ok || !b_lo_ok || !b_hi_ok do return nil
		if a_lo == a_hi && b_lo == b_hi {
			val := a_lo | b_lo
			segs[0] = Segment{val, val}
			return segs
		}
		segs[0] = Segment{max(a_lo, b_lo), max(a_hi, b_hi)}
		return segs
	case .Xor:
		if !a_lo_ok || !a_hi_ok || !b_lo_ok || !b_hi_ok do return nil
		if a_lo == a_hi && b_lo == b_hi {
			val := a_lo ~ b_lo
			segs[0] = Segment{val, val}
			return segs
		}
		segs[0] = Segment{i64(0), max(a_hi, b_hi)}
		return segs
	}
	return nil
}

// --- segment set operations ---

segments_union :: proc(a, b: []Segment) -> []Segment {
	merged := make([dynamic]Segment)
	i, j := 0, 0
	for i < len(a) || j < len(b) {
		seg: Segment
		if i < len(a) && (j >= len(b) || seg_lo(a[i]) <= seg_lo(b[j])) {
			seg = a[i];i += 1
		} else {
			seg = b[j];j += 1
		}
		if len(merged) > 0 && segments_overlap_or_adjacent(merged[len(merged) - 1], seg) {
			merged[len(merged) - 1] = segment_merge(merged[len(merged) - 1], seg)
		} else {
			append(&merged, seg)
		}
	}
	return merged[:]
}

segments_intersect :: proc(a, b: []Segment) -> []Segment {
	result := make([dynamic]Segment)
	j := 0
	for i := 0; i < len(a); i += 1 {
		for j < len(b) && !maybe_le(a[i].lo, b[j].hi) {
			j += 1
		}
		for k := j; k < len(b); k += 1 {
			lo := max_lo(a[i].lo, b[k].lo)
			hi := min_hi(a[i].hi, b[k].hi)
			if maybe_le(lo, hi) {
				append(&result, Segment{lo, hi})
			}
		}
	}
	return result[:]
}

segments_negate :: proc(segs: []Segment) -> []Segment {
	result := make([dynamic]Segment)
	prev_hi: Maybe(i64) = nil
	for seg in segs {
		lo, lo_ok := seg.lo.(i64)
		if lo_ok {
			append(&result, Segment{prev_hi, lo - 1})
		}
		hi, hi_ok := seg.hi.(i64)
		if hi_ok {
			prev_hi = hi + 1
		} else {
			prev_hi = nil
		}
	}
	if prev_hi != nil {
		append(&result, Segment{prev_hi, nil})
	}
	return result[:]
}

segments_normalize :: proc(segs: []Segment) -> []Segment {
	if len(segs) <= 1 do return segs
	sorted := make([]Segment, len(segs))
	copy(sorted, segs)
	for i := 1; i < len(sorted); i += 1 {
		key := sorted[i]
		j := i - 1
		for j >= 0 && seg_lo(sorted[j]) > seg_lo(key) {
			sorted[j + 1] = sorted[j]
			j -= 1
		}
		sorted[j + 1] = key
	}
	merged := make([dynamic]Segment)
	append(&merged, sorted[0])
	for i := 1; i < len(sorted); i += 1 {
		if segments_overlap_or_adjacent(merged[len(merged) - 1], sorted[i]) {
			merged[len(merged) - 1] = segment_merge(merged[len(merged) - 1], sorted[i])
		} else {
			append(&merged, sorted[i])
		}
	}
	return merged[:]
}

segments_satisfies :: proc(value_segs, constraint_segs: []Segment) -> bool {
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

// --- segment helpers ---


seg_lo :: #force_inline proc(s: Segment) -> i64 {
	lo, ok := s.lo.(i64)
	return ok ? lo : min(i64)
}


segments_overlap_or_adjacent :: #force_inline proc(a, b: Segment) -> bool {
	a_hi, a_ok := a.hi.(i64)
	b_lo, b_ok := b.lo.(i64)
	if !a_ok do return true
	if !b_ok do return true
	return a_hi >= b_lo - 1
}


segment_merge :: #force_inline proc(a, b: Segment) -> Segment {
	return Segment{min_lo(a.lo, b.lo), max_hi(a.hi, b.hi)}
}


max_lo :: #force_inline proc(a, b: Maybe(i64)) -> Maybe(i64) {
	av, a_ok := a.(i64)
	bv, b_ok := b.(i64)
	if !a_ok do return b
	if !b_ok do return a
	return max(av, bv)
}


min_lo :: #force_inline proc(a, b: Maybe(i64)) -> Maybe(i64) {
	av, a_ok := a.(i64)
	_, b_ok := b.(i64)
	if !a_ok do return a
	if !b_ok do return b
	return av < b.(i64) ? a : b
}


max_hi :: #force_inline proc(a, b: Maybe(i64)) -> Maybe(i64) {
	av, a_ok := a.(i64)
	_, b_ok := b.(i64)
	if !a_ok do return a
	if !b_ok do return b
	return av > b.(i64) ? a : b
}


min_hi :: #force_inline proc(a, b: Maybe(i64)) -> Maybe(i64) {
	av, a_ok := a.(i64)
	bv, b_ok := b.(i64)
	if !a_ok do return b
	if !b_ok do return a
	return min(av, bv)
}


maybe_le :: #force_inline proc(lo: Maybe(i64), hi: Maybe(i64)) -> bool {
	l, l_ok := lo.(i64)
	h, h_ok := hi.(i64)
	if !l_ok || !h_ok do return true
	return l <= h
}


maybe_le_hi :: #force_inline proc(a, b: Maybe(i64)) -> bool {
	av, a_ok := a.(i64)
	bv, b_ok := b.(i64)
	if !a_ok do return !b_ok
	if !b_ok do return true
	return av <= bv
}

// --- builtin names ---

builtin_name :: proc(seg: Segment) -> Maybe(string) {
	lo, lo_ok := seg.lo.(i64)
	hi, hi_ok := seg.hi.(i64)
	if !lo_ok && !hi_ok do return "Int"
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
	case lo == 0 && hi == 9223372036854775807:
		return "u64"
	case lo == -9223372036854775808 && hi == 9223372036854775807:
		return "i64"
	}
	return nil
}

builtin_alias :: proc(seg: Segment) -> string {
	lo, lo_ok := seg.lo.(i64)
	hi, hi_ok := seg.hi.(i64)
	if !lo_ok || !hi_ok do return ""
	if lo == 0 && hi == 255 do return "u8"
	if lo == -128 && hi == 127 do return "i8"
	if lo == 0 && hi == 65535 do return "u16"
	if lo == -32768 && hi == 32767 do return "i16"
	if lo == 0 && hi == 4294967295 do return "u32"
	if lo == -2147483648 && hi == 2147483647 do return "i32"
	if lo == 0 && hi == 9223372036854775807 do return "u64"
	if lo == -9223372036854775808 && hi == 9223372036854775807 do return "i64"
	return ""
}

pretty_segments :: proc(segs: []Segment) -> string {
	if len(segs) == 1 {
		alias := builtin_alias(segs[0])
		if alias != "" do return alias
	}
	b := strings.builder_make()
	for seg, i in segs {
		if i > 0 do strings.write_string(&b, " | ")
		lo, lo_ok := seg.lo.(i64)
		hi, hi_ok := seg.hi.(i64)
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
