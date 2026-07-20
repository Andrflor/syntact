package compiler

import "core:fmt"
import "core:strings"
import "core:unicode/utf8"

// string/char family — unified model over []String_Interval. `ordinal` is the
// mode (codepoint range vs prefix/suffix); a []String_Interval is always a UNION,
// while `+` stays a Compose_Type matched in order (fold_string_sequence).

count_one :: proc() -> Integer_Type {
	segs := make([]Integer_Interval, 1)
	segs[0] = Integer_Interval{i128(1), i128(1)}
	return Integer_Type{segs, i128(1)}
}


count_is_one :: proc(c: Integer_Type) -> bool {
	if len(c.integer_intervals) != 1 do return false
	lo, lo_ok := c.integer_intervals[0].lo.(i128)
	hi, hi_ok := c.integer_intervals[0].hi.(i128)
	return lo_ok && hi_ok && lo == 1 && hi == 1
}


// The impossible count {-1..-1} tags a sequence segment as a word-negation
// (`~"piro"`); real counts are ≥ 0, so -1 never collides. lo carries the word.
count_negation_sentinel :: proc() -> Integer_Type {
	segs := make([]Integer_Interval, 1)
	segs[0] = Integer_Interval{i128(-1), i128(-1)}
	return Integer_Type{segs, i128(-1)}
}


seg_is_negation :: proc(seg: String_Interval) -> bool {
	if len(seg.count.integer_intervals) != 1 do return false
	lo, lo_ok := seg.count.integer_intervals[0].lo.(i128)
	hi, hi_ok := seg.count.integer_intervals[0].hi.(i128)
	return lo_ok && hi_ok && lo == -1 && hi == -1
}


// A single-quote literal of ≤ 1 codepoint is ordinal; everything else positional.
quotation_is_ordinal :: proc(value: string, quotation: String_Quotation) -> bool {
	return quotation == .simple && rune_count_le_one(value)
}

make_string_const :: proc(value: string, quotation: String_Quotation) -> Type {
	intervals := make([]String_Interval, 1)
	intervals[0] = String_Interval {
		value,
		value,
		quotation_is_ordinal(value, quotation),
		count_one(),
	}
	return String_Type{intervals, value, quotation}
}


// `string` builtin = all strings = an open positional interval, default "".
make_string_any :: proc() -> Type {
	intervals := make([]String_Interval, 1)
	intervals[0] = String_Interval{nil, nil, false, count_one()}
	return String_Type{intervals, "", .double}
}


// `char` builtin = any single codepoint = ordinal '\x00'..'\U0010FFFF'. This is
// string-domain, NOT an integer alias.
CHAR_MAX_CODEPOINT :: 0x10FFFF
make_char_any :: proc() -> Type {
	intervals := make([]String_Interval, 1)
	lo := utf8.runes_to_string({rune(0)})
	hi := utf8.runes_to_string({rune(CHAR_MAX_CODEPOINT)})
	intervals[0] = String_Interval{lo, hi, true, count_one()}
	return String_Type{intervals, lo, .simple}
}


string_is_concrete :: #force_inline proc(t: String_Type) -> bool {
	if len(t.string_intervals) != 1 do return false
	return string_interval_is_concrete(t.string_intervals[0])
}


// Presupposes string_is_concrete(t).
string_value :: #force_inline proc(t: String_Type) -> string {
	return string_interval_concrete_value(t.string_intervals[0])
}


String_Mode :: enum {
	ordinal, // 'a'..'z' : one single-quote char, codepoint in [lo, hi]
	positional, // "p".."s" : starts with lo, ends with hi
}


rune_count_le_one :: proc(s: string) -> bool {
	count := 0
	for _ in s {
		count += 1
		if count > 1 do return false
	}
	return true
}


first_rune :: proc(s: string) -> rune {
	for r in s do return r
	return 0
}


string_interval_mode :: proc(iv: String_Interval) -> String_Mode {
	return iv.ordinal ? .ordinal : .positional
}


// Concrete = equal bounds AND a fixed count ("ab"*3 yes; "ab"*2..3 no).
string_interval_is_concrete :: #force_inline proc(iv: String_Interval) -> bool {
	lo, lo_ok := iv.lo.(string)
	hi, hi_ok := iv.hi.(string)
	if !lo_ok || !hi_ok || lo != hi do return false
	return int_is_concrete(iv.count)
}


// Presupposes string_interval_is_concrete(iv).
string_interval_concrete_value :: proc(iv: String_Interval) -> string {
	base := iv.lo.(string)
	n := int(int_value(iv.count))
	if n <= 1 do return base
	parts := make([]string, n)
	for i in 0 ..< n do parts[i] = base
	return strings.concatenate(parts)
}


string_quote_pair :: #force_inline proc(q: String_Quotation) -> (open: rune, close: rune) {
	switch q {
	case .simple:
		return '\'', '\''
	case .double:
		return '"', '"'
	case .backtick:
		return '`', '`'
	}
	return '"', '"'
}


interval_quote :: proc(iv: String_Interval) -> String_Quotation {
	return iv.ordinal ? String_Quotation.simple : .double
}

print_string_interval :: proc(iv: String_Interval) {
	open, close := string_quote_pair(interval_quote(iv))
	lo, lo_ok := iv.lo.(string)
	hi, hi_ok := iv.hi.(string)
	if lo_ok && hi_ok && lo == hi {
		fmt.printf("%r%s%r", open, lo, close)
	} else {
		if lo_ok do fmt.printf("%r%s%r", open, lo, close)
		fmt.print("..")
		if hi_ok do fmt.printf("%r%s%r", open, hi, close)
	}
	if !count_is_one(iv.count) {
		fmt.printf(" * %s", pretty_integer_intervals(iv.count.integer_intervals))
	}
}


write_string_desc :: proc(b: ^strings.Builder, t: String_Type) {
	if string_is_concrete(t) {
		open, close := string_quote_pair(interval_quote(t.string_intervals[0]))
		strings.write_rune(b, open)
		strings.write_string(b, string_value(t))
		strings.write_rune(b, close)
		return
	}
	if len(t.string_intervals) == 1 {
		iv := t.string_intervals[0]
		_, lo_ok := iv.lo.(string)
		_, hi_ok := iv.hi.(string)
		if !lo_ok && !hi_ok {
			strings.write_string(b, "string")
			return
		}
	}
	strings.write_string(b, "string")
}


print_string_type :: proc(t: String_Type) {
	// a single fully open interval renders as "string"
	if len(t.string_intervals) == 1 {
		iv := t.string_intervals[0]
		_, lo_ok := iv.lo.(string)
		_, hi_ok := iv.hi.(string)
		if !lo_ok && !hi_ok {
			fmt.print("string")
			return
		}
	}
	for iv, i in t.string_intervals {
		if i > 0 do fmt.print(" | ")
		print_string_interval(iv)
	}
}


// Decodes escapes (.backtick is raw). Text already stripped of delimiters.
decode_string_literal :: proc(text: string, quotation: String_Quotation) -> string {
	if quotation == .backtick {
		return text
	}
	if strings.index_byte(text, '\\') < 0 {
		return text
	}

	b := strings.builder_make()
	i := 0
	for i < len(text) {
		c := text[i]
		if c == '\\' && i + 1 < len(text) {
			next := text[i + 1]
			switch next {
			case 'n':
				strings.write_byte(&b, '\n')
			case 't':
				strings.write_byte(&b, '\t')
			case 'r':
				strings.write_byte(&b, '\r')
			case '0':
				strings.write_byte(&b, 0)
			case '\\':
				strings.write_byte(&b, '\\')
			case '\'':
				strings.write_byte(&b, '\'')
			case '"':
				strings.write_byte(&b, '"')
			case '`':
				strings.write_byte(&b, '`')
			case:
				strings.write_byte(&b, '\\')
				strings.write_byte(&b, next)
			}
			i += 2
		} else {
			strings.write_byte(&b, c)
			i += 1
		}
	}
	return strings.to_string(b)
}


// DOMAIN ENTRY POINTS — mirror of fold_type_integer / fold_constraint_integer.

wrap_string_intervals :: proc(segs: []String_Interval) -> ^Type {
	r := new(Type)
	def, def_q := default_for_string_intervals(segs)
	r^ = String_Type{segs, def, def_q}
	return r
}

// One segment's default: its low bound (or high), repeated by its count's low bound.
seg_default :: proc(iv: String_Interval) -> string {
	base: string = ""
	if lo, ok := iv.lo.(string); ok do base = lo
	else if hi, ok2 := iv.hi.(string); ok2 do base = hi
	n := 1
	if len(iv.count.integer_intervals) > 0 {
		if lo, ok := iv.count.integer_intervals[0].lo.(i128); ok do n = int(lo)
	}
	if n <= 0 do return ""
	if n == 1 do return base
	b := strings.builder_make()
	for _ in 0 ..< n do strings.write_string(&b, base)
	return strings.to_string(b)
}

// A union's default is the first term's default, in that term's quote.
default_for_string_intervals :: proc(
	segs: []String_Interval,
) -> (
	Maybe(string),
	String_Quotation,
) {
	if len(segs) == 0 do return nil, .double
	return seg_default(segs[0]), interval_quote(segs[0])
}

fold_type_string :: proc(t: ^Type) -> ^Type {
	segs, ok := fold_string_intervals(t, false).([]String_Interval)
	if !ok do return nil
	return wrap_string_intervals(segs)
}

fold_constraint_string :: proc(t: ^Type) -> ^Type {
	segs, ok := fold_string_intervals(t, true).([]String_Interval)
	if !ok do return nil
	return wrap_string_intervals(segs)
}

stored_string_intervals :: proc(t: ^Type) -> Maybe([]String_Interval) {
	if t == nil do return nil
	#partial switch v in t^ {
	case String_Type:
		return v.string_intervals
	}
	return nil
}

// Reduces a ^Type to its string segments. `as_constraint` selects the value fold
// vs the imposed-set fold (differs on Mention/Reference). A `+` stays symbolic.
fold_string_intervals :: proc(t: ^Type, as_constraint: bool) -> Maybe([]String_Interval) {
	if t == nil do return nil
	#partial switch v in t^ {
	case String_Type:
		return v.string_intervals
	case Scope_Type:
		for i := 0; i < len(v.kind); i += 1 {
			if v.kind[i] == .Product {
				if s, ok := stored_string_intervals(v.type_folds[i]).([]String_Interval); ok {
					return s
				}
				return fold_string_intervals(v.types[i], as_constraint)
			}
		}
		return nil
	case Range_Type:
		lseg, l_ok := fold_string_intervals(v.left, as_constraint).([]String_Interval)
		rseg, r_ok := fold_string_intervals(v.right, as_constraint).([]String_Interval)
		if v.left != nil && !l_ok do return nil
		if v.right != nil && !r_ok do return nil
		return fold_string_range(lseg, rseg)
	case Compose_Type:
		if v.operator == .Add {
			lseg, l_ok := fold_string_intervals(v.left, as_constraint).([]String_Interval)
			rseg, r_ok := fold_string_intervals(v.right, as_constraint).([]String_Interval)
			if !l_ok || !r_ok do return nil
			if joined, ok := string_concat_concrete(lseg, rseg); ok {
				return joined
			}
			// A purely positional `+` flattens to a {prefix, suffix} interval (needed
			// by negation/intersection/default); an ordinal class or repetition stays
			// an ordered sequence (nil here, kept as Compose).
			if positional_concat(lseg, rseg) {
				return concat_positional_fold(lseg, rseg)
			}
			return nil
		}
		if v.operator == .Multiply {
			// string * integer≥0 : repetition (multiply each segment's count).
			lseg, l_ok := fold_string_intervals(v.left, as_constraint).([]String_Interval)
			if !l_ok do return nil
			mult_it, m_ok := fold_type_intervals(v.right).(Integer_Type)
			if !m_ok do return nil
			return string_intervals_repeat(lseg, mult_it.integer_intervals)
		}
		return nil
	case Or_Type:
		lseg, l_ok := fold_string_intervals(v.left, as_constraint).([]String_Interval)
		rseg, r_ok := fold_string_intervals(v.right, as_constraint).([]String_Interval)
		if !l_ok || !r_ok do return nil
		return string_intervals_union(lseg, rseg)
	case And_Type:
		lseg, l_ok := fold_string_intervals(v.left, as_constraint).([]String_Interval)
		rseg, r_ok := fold_string_intervals(v.right, as_constraint).([]String_Interval)
		if !l_ok || !r_ok do return nil
		return string_intervals_intersect(lseg, rseg)
	case Negate_Type:
		inner, ok := fold_string_intervals(v.operand, as_constraint).([]String_Interval)
		if !ok do return nil
		neg := string_intervals_negate(inner)
		// Ordinal negation expands to complement intervals; a positional one has none
		// — nil keeps it symbolic (a `+` segment-negation, or NOT satisfy(x)).
		if len(neg) == 0 do return nil
		return neg
	case Mention_Type:
		if v.match_scope != nil && v.match_index >= 0 && v.match_index < len(v.match_scope.types) {
			if as_constraint {
				return fold_string_intervals(v.match_scope.types[v.match_index], true)
			}
			if s, ok := stored_string_intervals(
				   stored_type_fold_at(v.match_scope, v.match_index),
			   ).([]String_Interval); ok {
				return s
			}
			if s, ok := stored_string_intervals(
				   stored_constraint_fold_at(v.match_scope, v.match_index),
			   ).([]String_Interval); ok {
				return s
			}
			// The cached *_folds envelope to `{string}`, losing the bounds a
			// repetition needs — fall back to the binding's actual value.
			return fold_string_intervals(v.match_scope.types[v.match_index], false)
		}
		return nil
	case Reference_Type:
		ref := v.reference
		if ref != nil && ref.match_scope != nil && ref.match_index >= 0 &&
		   ref.match_index < len(ref.match_scope.types) {
			if as_constraint {
				return fold_string_intervals(ref.match_scope.types[ref.match_index], true)
			}
			if s, ok := stored_string_intervals(
				   stored_type_fold_at(ref.match_scope, ref.match_index),
			   ).([]String_Interval); ok {
				return s
			}
			if s, ok := stored_string_intervals(
				   stored_constraint_fold_at(ref.match_scope, ref.match_index),
			   ).([]String_Interval); ok {
				return s
			}
			return fold_string_intervals(ref.match_scope.types[ref.match_index], false)
		}
		return nil
	}
	return nil
}


// Range from lo of left and hi of right; ordinal iff both bounds are ordinal.
fold_string_range :: proc(lseg, rseg: []String_Interval) -> []String_Interval {
	lo: Maybe(string) = nil
	hi: Maybe(string) = nil
	l_ord := false
	r_ord := false
	got_l := false
	got_r := false
	if len(lseg) > 0 {
		lo = lseg[0].lo
		l_ord = lseg[0].ordinal
		got_l = true
	}
	if len(rseg) > 0 {
		hi = rseg[0].hi
		r_ord = rseg[0].ordinal
		got_r = true
	}
	ordinal := (!got_l || l_ord) && (!got_r || r_ord) && (got_l || got_r)
	res := make([]String_Interval, 1)
	res[0] = String_Interval{lo, hi, ordinal, count_one()}
	return res
}


// SATISFIES — prove that value ⊆ constraint.

// True if every string `v` denotes is also denoted by `c`. Repeated constraints
// are handled upstream by sequence_satisfy, not here.
string_interval_satisfy :: proc(v, c: String_Interval) -> bool {
	c_simple := count_is_one(c.count)
	v_simple := count_is_one(v.count)

	if c_simple {
		if v_simple {
			return string_pattern_satisfy(v, c)
		}
		// repeated value, simple constraint: holds only if it unfolds to a single
		// concrete value satisfying the pattern.
		if string_interval_is_concrete(v) {
			s := string_interval_concrete_value(v)
			concrete := String_Interval{s, s, v.ordinal, count_one()}
			return string_pattern_satisfy(concrete, c)
		}
		return false
	}

	return false
}


// Pattern satisfiability alone (count = 1 both sides): ordinal/positional logic.
string_pattern_satisfy :: proc(v, c: String_Interval) -> bool {
	vmode := string_interval_mode(v)
	cmode := string_interval_mode(c)

	switch cmode {
	case .ordinal:
		switch vmode {
		case .ordinal:
			return ordinal_within(v.lo, v.hi, c.lo, c.hi)
		case .positional:
			if !string_interval_is_concrete(v) do return false
			s := v.lo.(string)
			if !rune_count_le_one(s) || len(s) == 0 do return false
			return ordinal_within(s, s, c.lo, c.hi)
		}
	case .positional:
		switch vmode {
		case .positional:
			cpre, cpre_ok := c.lo.(string)
			csuf, csuf_ok := c.hi.(string)
			if cpre_ok && cpre != "" {
				vpre, vpre_ok := v.lo.(string)
				if !vpre_ok || !strings.has_prefix(vpre, cpre) do return false
			}
			if csuf_ok && csuf != "" {
				vsuf, vsuf_ok := v.hi.(string)
				if !vsuf_ok || !strings.has_suffix(vsuf, csuf) do return false
			}
			return true
		case .ordinal:
			cpre, cpre_ok := c.lo.(string)
			csuf, csuf_ok := c.hi.(string)
			pre_free := !cpre_ok || cpre == ""
			suf_free := !csuf_ok || csuf == ""
			if pre_free && suf_free do return true
			if !string_interval_is_concrete(v) do return false
			s := v.lo.(string)
			if cpre_ok && !strings.has_prefix(s, cpre) do return false
			if csuf_ok && !strings.has_suffix(s, csuf) do return false
			return true
		}
	}
	return false
}


// [vlo, vhi] ⊆ [clo, chi] over first-char codepoints; nil bound = open (±∞).
ordinal_within :: proc(vlo, vhi, clo, chi: Maybe(string)) -> bool {
	if clo_s, ok := clo.(string); ok && clo_s != "" {
		vlo_s, vok := vlo.(string)
		if !vok || vlo_s == "" do return false
		if first_rune(vlo_s) < first_rune(clo_s) do return false
	}
	if chi_s, ok := chi.(string); ok && chi_s != "" {
		vhi_s, vok := vhi.(string)
		if !vok || vhi_s == "" do return false
		if first_rune(vhi_s) > first_rune(chi_s) do return false
	}
	return true
}


// value ⊆ constraint. A constraint with a repetition is a sequence (checked
// char-by-char via sequence_satisfy); otherwise each value seg ⊆ some constraint seg.
string_intervals_satisfy :: proc(value_segs, constraint_segs: []String_Interval) -> bool {
	if value_segs == nil || constraint_segs == nil do return false

	if constraint_has_repeat(constraint_segs) {
		return sequence_satisfy(value_segs, constraint_segs)
	}

	for vs in value_segs {
		found := false
		for cs in constraint_segs {
			if string_interval_satisfy(vs, cs) {
				found = true
				break
			}
		}
		if !found do return false
	}
	return true
}


constraint_has_repeat :: proc(segs: []String_Interval) -> bool {
	for s in segs do if !count_is_one(s.count) do return true
	return false
}


// The constraint is a repeated sequence: the concrete value must be a
// concatenation of elements each ∈ the segment union, length ∈ the combined count.
sequence_satisfy :: proc(value_segs, constraint_segs: []String_Interval) -> bool {
	count_union := make([dynamic]Integer_Interval)
	for cs in constraint_segs {
		for ci in cs.count.integer_intervals do append(&count_union, ci)
	}
	allowed := integer_intervals_normalize(count_union[:])

	for vs in value_segs {
		if !string_interval_is_concrete(vs) {
			// ordinal repeated value: chars ⊆ element union, count ⊆ allowed.
			if string_interval_mode(vs) == .ordinal {
				if !ordinal_in_element_union(vs.lo, vs.hi, constraint_segs) do return false
				if !integer_intervals_satisfy(vs.count.integer_intervals, allowed) do return false
				continue
			}
			return false
		}
		s := string_interval_concrete_value(vs)
		if !concrete_in_sequence(s, constraint_segs, allowed) do return false
	}
	return true
}


// `s` splits greedily into `k` elements (k ∈ allowed), each matching a segment.
// `count` is the number of ELEMENTS, not chars ("ab"*3 = 3 elements / 6 chars).
// The greedy walk is exact when all same-length elements agree (the common case).
concrete_in_sequence :: proc(
	s: string,
	segs: []String_Interval,
	allowed: []Integer_Interval,
) -> bool {
	rest := s
	k := 0
	for len(rest) > 0 {
		consumed := consume_one_element(rest, segs)
		if consumed == 0 do return false
		rest = rest[consumed:]
		k += 1
	}
	return int_in_intervals(i128(k), allowed)
}


// Matches the head of `rest` against one segment's element, returning bytes
// consumed (0 = no match).
consume_one_element :: proc(rest: string, segs: []String_Interval) -> int {
	for cs in segs {
		// Read cs.lo/cs.hi directly (the element WITHOUT the count) — concrete_value
		// would unfold the count to the whole sequence.
		if string_interval_mode(cs) == .ordinal {
			r := first_rune(rest)
			rs := rune_to_string(r)
			if ordinal_within(rs, rs, cs.lo, cs.hi) do return len(rs)
			continue
		}
		// concrete positional literal: matches as a prefix.
		lo, lo_ok := cs.lo.(string)
		hi, hi_ok := cs.hi.(string)
		if lo_ok && hi_ok && lo == hi && lo != "" {
			if strings.has_prefix(rest, lo) do return len(lo)
		}
	}
	return 0
}


// Ordered-sequence matching (concatenation `+`)

// The constraint is an ordered concat; a concrete value satisfies it iff it
// splits left-to-right into the segments in order (each matched `count` times,
// with backtracking). Only a concrete value can be checked.
string_value_satisfies_sequence :: proc(ft: String_Type, segs: []String_Interval) -> bool {
	if len(ft.string_intervals) != 1 do return false
	v := ft.string_intervals[0]
	if !string_interval_is_concrete(v) do return false
	s := string_interval_concrete_value(v)
	return seq_match(s, segs, 0)
}

// Can `rest` be consumed by segments[si:] in order? Tries every allowed
// occurrence count for the current segment (greedy-then-backtrack) and recurses.
seq_match :: proc(rest: string, segs: []String_Interval, si: int) -> bool {
	if si >= len(segs) {
		return len(rest) == 0
	}
	seg := segs[si]

	// Segment-negation (`~"piro" + …`): consume a variable-length prefix that is NOT
	// the negated word (in seg.lo), trying every split point.
	if seg_is_negation(seg) {
		neg_word, _ := seg.lo.(string)
		for cut := 0; cut <= len(rest); cut += 1 {
			prefix := rest[:cut]
			if prefix == neg_word do continue
			if seq_match(rest[cut:], segs, si + 1) do return true
		}
		return false
	}

	lo_n, hi_n := seg_count_bounds(seg)

	offset := 0
	k := 0
	for {
		if k >= lo_n && (hi_n < 0 || k <= hi_n) {
			if seq_match(rest[offset:], segs, si + 1) do return true
		}
		if hi_n >= 0 && k >= hi_n do break
		consumed := seg_consume_one(rest[offset:], seg)
		if consumed == 0 do break
		offset += consumed
		k += 1
	}
	return false
}

// The [lo, hi] occurrence range of a segment's count (hi = -1 means unbounded).
seg_count_bounds :: proc(seg: String_Interval) -> (lo_n: int, hi_n: int) {
	ivs := seg.count.integer_intervals
	if len(ivs) == 0 do return 1, 1
	lo_n = 1
	if l, ok := ivs[0].lo.(i128); ok do lo_n = int(l)
	hi_n = -1
	if h, ok := ivs[len(ivs) - 1].hi.(i128); ok do hi_n = int(h)
	return
}

// Consume ONE occurrence of a segment's element from the head, returning bytes
// consumed (0 = no match).
seg_consume_one :: proc(rest: string, seg: String_Interval) -> int {
	if len(rest) == 0 do return 0
	if string_interval_mode(seg) == .ordinal {
		r := first_rune(rest)
		rs := rune_to_string(r)
		if ordinal_within(rs, rs, seg.lo, seg.hi) do return len(rs)
		return 0
	}
	// concrete positional literal (lo == hi) matches as a prefix.
	lo, lo_ok := seg.lo.(string)
	hi, hi_ok := seg.hi.(string)
	if lo_ok && hi_ok && lo == hi {
		if lo == "" do return 0
		if strings.has_prefix(rest, lo) do return len(lo)
		return 0
	}
	// non-concrete positional element: not consumable element-by-element here.
	return 0
}


// Is [lo,hi] contained in the ordinal element of some segment?
ordinal_in_element_union :: proc(lo, hi: Maybe(string), segs: []String_Interval) -> bool {
	for cs in segs {
		if string_interval_mode(cs) != .ordinal do continue
		if ordinal_within(lo, hi, cs.lo, cs.hi) do return true
	}
	return false
}


string_satisfy :: proc(fc, ft: String_Type) -> bool {
	return string_intervals_satisfy(ft.string_intervals, fc.string_intervals)
}

// Materialized default of a `+` sequence: in-order concat of each segment's
// default. nil when `t` is not a string sequence.
string_sequence_default :: proc(t: ^Type) -> ^Type {
	segs, ok := fold_string_sequence(t, true).([]String_Interval)
	if !ok || len(segs) == 0 do return nil
	b := strings.builder_make()
	for iv in segs do strings.write_string(&b, seg_default(iv))
	r := new(Type)
	r^ = make_string_const(strings.to_string(b), .double)
	return r
}

// Constraint is a `+` Compose (ordered sequence); the value must split into it.
string_compose_satisfy :: proc(fc: ^Type, ft: String_Type) -> bool {
	segs, ok := fold_string_sequence(fc, true).([]String_Interval)
	if !ok do return false
	return string_value_satisfies_sequence(ft, segs)
}

// True when `t` is a three-bound string range `"ab".."cd".."ef"` = Range{ab, Range{cd, ef}}.
string_is_tri_range :: proc(t: ^Type) -> bool {
	r, ok := t^.(Range_Type)
	if !ok || r.left == nil || r.right == nil do return false
	_, inner_is_range := follow(r.right)^.(Range_Type)
	if !inner_is_range do return false
	return fold_constraint_string(t) != nil
}

// The (prefix, middle, suffix) literals of a three-bound string range.
string_tri_range_bounds :: proc(t: ^Type) -> (prefix, middle, suffix: string) {
	r := t^.(Range_Type)
	inner := follow(r.right)^.(Range_Type)
	str_bound :: proc(t: ^Type, want_lo: bool) -> string {
		if t == nil do return ""
		segs, ok := fold_string_intervals(t, true).([]String_Interval)
		if !ok || len(segs) == 0 do return ""
		b: Maybe(string) = want_lo ? segs[0].lo : segs[0].hi
		if s, sok := b.(string); sok do return s
		return ""
	}
	prefix = str_bound(r.left, true)
	middle = str_bound(inner.left, true)
	suffix = str_bound(inner.right, false)
	return
}

// A concrete value satisfies `"ab".."cd".."ef"` iff it starts with ab, contains
// cd, and ends with ef.
string_tri_range_satisfy :: proc(fc: ^Type, ft: String_Type) -> bool {
	if !string_is_concrete(ft) do return false
	s := string_value(ft)
	prefix, middle, suffix := string_tri_range_bounds(fc)
	if prefix != "" && !strings.has_prefix(s, prefix) do return false
	if suffix != "" && !strings.has_suffix(s, suffix) do return false
	if middle != "" && !strings.contains(s, middle) do return false
	return true
}


// SET OPERATIONS — | (union), & (intersection), ~ (negation)

// Union = concatenate the segments (deduped); satisfy walks all of them.
string_intervals_union :: proc(a, b: []String_Interval) -> []String_Interval {
	result := make([dynamic]String_Interval)
	add :: proc(result: ^[dynamic]String_Interval, iv: String_Interval) {
		for existing in result {
			if string_interval_equal(existing, iv) do return
		}
		append(result, iv)
	}
	for iv in a do add(&result, iv)
	for iv in b do add(&result, iv)
	return result[:]
}


// Intersection = cartesian product, keeping non-empty pairs.
string_intervals_intersect :: proc(a, b: []String_Interval) -> []String_Interval {
	result := make([dynamic]String_Interval)
	for x in a {
		for y in b {
			if iv, ok := string_interval_intersect(x, y); ok {
				append(&result, iv)
			}
		}
	}
	return result[:]
}


// Intersection of two intervals; ok=false if empty.
string_interval_intersect :: proc(x, y: String_Interval) -> (String_Interval, bool) {
	xm := string_interval_mode(x)
	ym := string_interval_mode(y)

	count_segs := integer_intervals_intersect(x.count.integer_intervals, y.count.integer_intervals)
	if len(count_segs) == 0 do return {}, false
	count := Integer_Type{count_segs, default_for_integer_intervals(count_segs)}

	if xm == .ordinal && ym == .ordinal {
		lo := ordinal_max_lo(x.lo, y.lo)
		hi := ordinal_min_hi(x.hi, y.hi)
		if !ordinal_lo_le_hi(lo, hi) do return {}, false
		return String_Interval{lo, hi, true, count}, true
	}

	// one concrete: the intersection is that concrete if it satisfies the other.
	if string_interval_is_concrete(x) && string_interval_satisfy(x, y) do return {x.lo, x.hi, x.ordinal, count}, true
	if string_interval_is_concrete(y) && string_interval_satisfy(y, x) do return {y.lo, y.hi, y.ordinal, count}, true

	if xm == .positional && ym == .positional {
		pre, pre_ok := longest_compatible(x.lo, y.lo, true)
		if !pre_ok do return {}, false
		suf, suf_ok := longest_compatible(x.hi, y.hi, false)
		if !suf_ok do return {}, false
		return String_Interval{pre, suf, false, count}, true
	}

	// non-concrete ordinal/positional mix: conservatively empty.
	return {}, false
}


// One affix must contain the other; returns the longest. Empty if neither does.
longest_compatible :: proc(a, b: Maybe(string), is_prefix: bool) -> (Maybe(string), bool) {
	as_, a_ok := a.(string)
	bs_, b_ok := b.(string)
	if !a_ok || as_ == "" do return b, true
	if !b_ok || bs_ == "" do return a, true
	if is_prefix {
		if strings.has_prefix(as_, bs_) do return as_, true
		if strings.has_prefix(bs_, as_) do return bs_, true
	} else {
		if strings.has_suffix(as_, bs_) do return as_, true
		if strings.has_suffix(bs_, as_) do return bs_, true
	}
	return nil, false
}


// Ordinal negation only: ~'A'..'Z' = chars outside [A, Z]; positional skipped.
string_intervals_negate :: proc(segs: []String_Interval) -> []String_Interval {
	result := make([dynamic]String_Interval)
	for iv in segs {
		if string_interval_mode(iv) != .ordinal do continue
		lo, lo_ok := iv.lo.(string)
		hi, hi_ok := iv.hi.(string)
		if lo_ok && lo != "" {
			r := first_rune(lo)
			if r > 0 {
				append(&result, String_Interval{nil, rune_to_string(r - 1), true, count_one()})
			}
		}
		if hi_ok && hi != "" {
			r := first_rune(hi)
			append(&result, String_Interval{rune_to_string(r + 1), nil, true, count_one()})
		}
	}
	return result[:]
}


// Expands ~X into intervals only if X is a pure ordinal string; else nil (stays
// symbolic, handled as NOT satisfy(X)).
negate_ordinal_string :: proc(content: ^Type) -> ^Type {
	segs, ok := fold_string_intervals(content, true).([]String_Interval)
	if !ok || len(segs) == 0 do return nil
	for s in segs {
		if string_interval_mode(s) != .ordinal do return nil
		if !count_is_one(s.count) do return nil
	}
	neg := string_intervals_negate(segs)
	if len(neg) == 0 do return nil
	return wrap_string_intervals(neg)
}


// CONCATENATION — + on strings/chars

// `a + b` when both sides are a single concrete segment → one literal; else ok=false.
string_concat_concrete :: proc(a, b: []String_Interval) -> ([]String_Interval, bool) {
	if len(a) != 1 || len(b) != 1 do return nil, false
	x := a[0]
	y := b[0]
	if !string_interval_is_concrete(x) || !string_interval_is_concrete(y) do return nil, false
	joined := strings.concatenate(
		{string_interval_concrete_value(x), string_interval_concrete_value(y)},
	)
	res := make([]String_Interval, 1)
	res[0] = String_Interval{joined, joined, false, count_one()}
	return res, true
}

// True when a `+` is purely positional (no ordinal class, no repetition) — folds
// to a single positional interval; an ordinal class or repetition is a sequence.
positional_concat :: proc(a, b: []String_Interval) -> bool {
	check :: proc(segs: []String_Interval) -> bool {
		for iv in segs {
			if !count_is_one(iv.count) do return false
			if iv.ordinal && !string_interval_is_concrete(iv) do return false
		}
		return true
	}
	return check(a) && check(b)
}

// The {prefix(a), suffix(b)} positional interval for a purely positional `a + b`.
concat_positional_fold :: proc(a, b: []String_Interval) -> []String_Interval {
	pre: Maybe(string) = nil
	suf: Maybe(string) = nil
	if len(a) == 1 do pre = concat_prefix(a[0])
	if len(b) == 1 do suf = concat_suffix(b[0])
	res := make([]String_Interval, 1)
	res[0] = String_Interval{pre, suf, false, count_one()}
	return res
}

// The ordered list of segments of a `+` chain, left to right, NOT flattened into a
// union. nil when an operand is not a string. Walked by the sequence matcher.
fold_string_sequence :: proc(t: ^Type, as_constraint: bool) -> Maybe([]String_Interval) {
	if t == nil do return nil
	#partial switch v in t^ {
	case Compose_Type:
		if v.operator == .Add {
			lseg, l_ok := fold_string_sequence(v.left, as_constraint).([]String_Interval)
			rseg, r_ok := fold_string_sequence(v.right, as_constraint).([]String_Interval)
			if !l_ok || !r_ok do return nil
			all := make([dynamic]String_Interval, 0, len(lseg) + len(rseg))
			for iv in lseg do append(&all, iv)
			for iv in rseg do append(&all, iv)
			return all[:]
		}
		if v.operator == .Multiply {
			lseg, l_ok := fold_string_sequence(v.left, as_constraint).([]String_Interval)
			if !l_ok do return nil
			mult_it, m_ok := fold_type_intervals(v.right).(Integer_Type)
			if !m_ok do return nil
			return string_intervals_repeat(lseg, mult_it.integer_intervals)
		}
		return nil
	case Negate_Type:
		// Negation operand of a sequence: a char negation folds to ordinal complement
		// segments; a positional word negation becomes a segment-negation sentinel
		// (lo = the word, count = {-1..-1}), matching a non-word prefix.
		if neg := negate_ordinal_string(v.operand); neg != nil {
			return fold_string_intervals(neg, as_constraint)
		}
		inner, ok := fold_string_intervals(v.operand, as_constraint).([]String_Interval)
		if !ok || len(inner) == 0 do return nil
		segs := make([]String_Interval, len(inner))
		for iv, i in inner do segs[i] = String_Interval{iv.lo, iv.hi, iv.ordinal, count_negation_sentinel()}
		return segs
	}
	// non-Compose operand: its segments are one sequence element.
	return fold_string_intervals(t, as_constraint)
}


// REPETITION — * on strings/chars

// Multiplies each segment's count by `mult` (must be ≥ 0; else nil).
string_intervals_repeat :: proc(
	segs: []String_Interval,
	mult: []Integer_Interval,
) -> []String_Interval {
	if !string_repeat_mult_valid(mult) do return nil
	result := make([]String_Interval, len(segs))
	for iv, i in segs {
		new_count := make([dynamic]Integer_Interval)
		for c in iv.count.integer_intervals {
			for m in mult {
				append(&new_count, count_mul(c, m))
			}
		}
		norm := integer_intervals_normalize(new_count[:])
		result[i] = String_Interval {
			iv.lo,
			iv.hi,
			iv.ordinal,
			Integer_Type{norm, default_for_integer_intervals(norm)},
		}
	}
	return result
}


// [a,b]*[c,d] of two counts ≥ 0; ∞ absorbs at the top unless the other is 0.
count_mul :: proc(x, y: Integer_Interval) -> Integer_Interval {
	xlo := x.lo.(i128) or_else 0
	ylo := y.lo.(i128) or_else 0
	lo := xlo * ylo

	xhi, xhi_ok := x.hi.(i128)
	yhi, yhi_ok := y.hi.(i128)
	if !xhi_ok || !yhi_ok {
		// open * 0 = 0; otherwise ∞.
		if xhi_ok && xhi == 0 do return Integer_Interval{lo, i128(0)}
		if yhi_ok && yhi == 0 do return Integer_Interval{lo, i128(0)}
		return Integer_Interval{lo, nil}
	}
	return Integer_Interval{lo, xhi * yhi}
}


// A repetition multiplier must be an integer (range) ≥ 0.
string_repeat_mult_valid :: proc(mult: []Integer_Interval) -> bool {
	if len(mult) == 0 do return false
	for m in mult {
		lo, lo_ok := m.lo.(i128)
		if !lo_ok do return false
		if lo < 0 do return false
	}
	return true
}


concat_prefix :: proc(iv: String_Interval) -> Maybe(string) {
	if string_interval_is_concrete(iv) do return iv.lo
	switch string_interval_mode(iv) {
	case .positional:
		return iv.lo
	case .ordinal:
		return nil
	}
	return nil
}


concat_suffix :: proc(iv: String_Interval) -> Maybe(string) {
	if string_interval_is_concrete(iv) do return iv.hi
	switch string_interval_mode(iv) {
	case .positional:
		return iv.hi
	case .ordinal:
		return nil
	}
	return nil
}


// Ordinal / miscellaneous helpers

string_interval_equal :: proc(a, b: String_Interval) -> bool {
	if !(maybe_string_eq(a.lo, b.lo) && maybe_string_eq(a.hi, b.hi) && a.ordinal == b.ordinal) {
		return false
	}
	if len(a.count.integer_intervals) != len(b.count.integer_intervals) do return false
	for i in 0 ..< len(a.count.integer_intervals) {
		ai := a.count.integer_intervals[i]
		bi := b.count.integer_intervals[i]
		if !maybe_i128_eq(ai.lo, bi.lo) || !maybe_i128_eq(ai.hi, bi.hi) do return false
	}
	return true
}

maybe_i128_eq :: proc(a, b: Maybe(i128)) -> bool {
	av, a_ok := a.(i128)
	bv, b_ok := b.(i128)
	if a_ok != b_ok do return false
	if !a_ok do return true
	return av == bv
}

maybe_string_eq :: proc(a, b: Maybe(string)) -> bool {
	as_, a_ok := a.(string)
	bs_, b_ok := b.(string)
	if a_ok != b_ok do return false
	if !a_ok do return true
	return as_ == bs_
}

rune_to_string :: proc(r: rune) -> string {
	bytes, n := utf8.encode_rune(r)
	return strings.clone(string(bytes[:n]))
}

// codepoint bounds, nil = open.
ordinal_max_lo :: proc(a, b: Maybe(string)) -> Maybe(string) {
	as_, a_ok := a.(string)
	bs_, b_ok := b.(string)
	if !a_ok || as_ == "" do return b
	if !b_ok || bs_ == "" do return a
	return first_rune(as_) >= first_rune(bs_) ? a : b
}

ordinal_min_hi :: proc(a, b: Maybe(string)) -> Maybe(string) {
	as_, a_ok := a.(string)
	bs_, b_ok := b.(string)
	if !a_ok || as_ == "" do return b
	if !b_ok || bs_ == "" do return a
	return first_rune(as_) <= first_rune(bs_) ? a : b
}

rune_count :: proc(s: string) -> int {
	n := 0
	for _ in s do n += 1
	return n
}

int_in_intervals :: proc(val: i128, segs: []Integer_Interval) -> bool {
	for s in segs {
		lo_ok := true
		hi_ok := true
		if lo, ok := s.lo.(i128); ok do lo_ok = val >= lo
		if hi, ok := s.hi.(i128); ok do hi_ok = val <= hi
		if lo_ok && hi_ok do return true
	}
	return false
}

ordinal_lo_le_hi :: proc(lo, hi: Maybe(string)) -> bool {
	lo_s, lo_ok := lo.(string)
	hi_s, hi_ok := hi.(string)
	if !lo_ok || lo_s == "" do return true
	if !hi_ok || hi_s == "" do return true
	return first_rune(lo_s) <= first_rune(hi_s)
}
