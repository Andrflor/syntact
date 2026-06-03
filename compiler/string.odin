package compiler

import "core:fmt"
import "core:strings"
import "core:unicode/utf8"

// ============================================================================
// string/char family — unified model over []String_Interval.
//
// A String_Interval carries its bounds (lo, hi: Maybe(string)) and an `ordinal`
// flag that IS the mode (set once at construction by quotation_is_ordinal):
//   ORDINAL    (ordinal=true): a codepoint range — 'a'..'z' = any single char in
//              [lo,hi]. A single-quote literal ≤ 1 codepoint.
//   POSITIONAL (ordinal=false): lo = required prefix, hi = required suffix —
//              "a".."z" = starts with a, ends with z (positional even for 1-char
//              bounds!), and any double-quote / multi-char literal.
// So `"a".."z"` is positional, NOT ordinal — only single-quote single-char bounds
// are ordinal. The rest of the file reads `iv.ordinal` and never a quotation.
//
// A []String_Interval is always a UNION of alternatives. The ordered concatenation
// `+` is NOT flattened here: it stays a Compose_Type and is matched in order at
// satisfy time (fold_string_sequence / string_compose_satisfy). A three-bound range
// `"ab".."cd".."ef"` likewise stays a raw Range_Type (string_tri_range_satisfy).
//
// Modeled on fold_integer.odin / fold_float.odin: a concrete Type is a
// degenerate interval (lo == hi) with a single segment.
// ============================================================================


// ---------------------------------------------------------------------------
// Construction
// ---------------------------------------------------------------------------

// count_one : the default repetition {1..1} (one occurrence). Reused
// everywhere a String_Interval has no explicit `*`.
count_one :: proc() -> Integer_Type {
	segs := make([]Integer_Interval, 1)
	segs[0] = Integer_Interval{i128(1), i128(1)}
	return Integer_Type{segs, i128(1)}
}


// count_is_one : true if the count is exactly {1..1} (no repetition).
count_is_one :: proc(c: Integer_Type) -> bool {
	if len(c.integer_intervals) != 1 do return false
	lo, lo_ok := c.integer_intervals[0].lo.(i128)
	hi, hi_ok := c.integer_intervals[0].hi.(i128)
	return lo_ok && hi_ok && lo == 1 && hi == 1
}


// count_negation_sentinel : the impossible count {-1..-1} used to TAG a sequence
// segment as a POSITIONAL word-negation (`~"piro"`). A real repetition count is
// always ≥ 0, so -1 never collides; seg_is_negation reads it back. The segment's
// lo carries the negated word.
count_negation_sentinel :: proc() -> Integer_Type {
	segs := make([]Integer_Interval, 1)
	segs[0] = Integer_Interval{i128(-1), i128(-1)}
	return Integer_Type{segs, i128(-1)}
}


// seg_is_negation : true if the segment is the word-negation sentinel.
seg_is_negation :: proc(seg: String_Interval) -> bool {
	if len(seg.count.integer_intervals) != 1 do return false
	lo, lo_ok := seg.count.integer_intervals[0].lo.(i128)
	hi, hi_ok := seg.count.integer_intervals[0].hi.(i128)
	return lo_ok && hi_ok && lo == -1 && hi == -1
}


// quotation_is_ordinal : the ORDINAL/positional decision is made ONCE, at literal
// construction, from the quotation and the bound length — a single-quote (.simple)
// literal whose value is ≤ 1 codepoint is an ordinal char ('a'); everything else
// (double/backtick quotes, multi-char single quotes) is positional. The result is
// stored in String_Interval.ordinal so the rest of the file never re-derives it
// from a quotation (which the interval no longer carries).
quotation_is_ordinal :: proc(value: string, quotation: String_Quotation) -> bool {
	return quotation == .simple && rune_count_le_one(value)
}

// Concrete (degenerate) string value: lo == hi. The default is the value
// itself, like make_int_result/make_float_result.
make_string_const :: proc(value: string, quotation: String_Quotation) -> Type {
	intervals := make([]String_Interval, 1)
	intervals[0] = String_Interval{value, value, quotation_is_ordinal(value, quotation), count_one()}
	return String_Type{intervals, value, quotation}
}


// `String` builtin = all strings = an open positional interval.
// Default = the empty string (the open lower bound of the positional).
make_string_any :: proc() -> Type {
	intervals := make([]String_Interval, 1)
	intervals[0] = String_Interval{nil, nil, false, count_one()}
	return String_Type{intervals, "", .double}
}


// ---------------------------------------------------------------------------
// Predicates
// ---------------------------------------------------------------------------

string_is_concrete :: #force_inline proc(t: String_Type) -> bool {
	if len(t.string_intervals) != 1 do return false
	return string_interval_is_concrete(t.string_intervals[0])
}


// Concrete value, repetition unfolded. Presupposes string_is_concrete(t).
string_value :: #force_inline proc(t: String_Type) -> string {
	return string_interval_concrete_value(t.string_intervals[0])
}


// Semantic mode of an interval (cf. header). ORDINAL requires a single-quote
// (.simple) literal whose present bounds are each ≤ 1 codepoint; EVERYTHING else
// is positional (prefix/suffix), including double-quote / backtick literals of any
// length and single-quote multi-char literals. An empty string counts as an open
// bound. NB: `"a".."z"` is positional, not ordinal — the quote, not just the
// length, gates ordinal mode.
String_Mode :: enum {
	ordinal,    // 'a'..'z' : one single-quote char, codepoint in [lo, hi]
	positional, // "p".."s" / 'ab'..'cd' / `x`..`y` : starts with lo, ends with hi
}


// rune_count_le_one : true if the string is empty or a single codepoint.
rune_count_le_one :: proc(s: string) -> bool {
	count := 0
	for _ in s {
		count += 1
		if count > 1 do return false
	}
	return true
}


// first_rune returns the first codepoint of a non-empty string.
first_rune :: proc(s: string) -> rune {
	for r in s do return r
	return 0
}


// The mode is now carried DIRECTLY by the interval's `ordinal` flag (set at
// construction by quotation_is_ordinal), not re-derived from a quotation. An
// ordinal interval is a codepoint range ('a'..'z'); a positional one is a
// prefix/suffix pattern ("a".."z").
string_interval_mode :: proc(iv: String_Interval) -> String_Mode {
	return iv.ordinal ? .ordinal : .positional
}


// Concrete = equal bounds AND a fixed concrete count (a single known length).
// "ab"*3 is concrete (unfolds to "ababab"); "ab"*2..3 is not.
string_interval_is_concrete :: #force_inline proc(iv: String_Interval) -> bool {
	lo, lo_ok := iv.lo.(string)
	hi, hi_ok := iv.hi.(string)
	if !lo_ok || !hi_ok || lo != hi do return false
	return int_is_concrete(iv.count)
}


// Unfolded concrete value: the string literal the interval denotes, repeated
// `count` times. Presupposes string_interval_is_concrete(iv).
string_interval_concrete_value :: proc(iv: String_Interval) -> string {
	base := iv.lo.(string)
	n := int(int_value(iv.count))
	if n <= 1 do return base
	parts := make([]string, n)
	for i in 0 ..< n do parts[i] = base
	return strings.concatenate(parts)
}


// ---------------------------------------------------------------------------
// Printing
// ---------------------------------------------------------------------------

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


// interval_quote : the quote to render an interval with, derived from its mode —
// an ordinal char prints single-quoted ('a'), a positional string double-quoted.
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
	// Repetition: suffix `* count` if it is not the default value {1..1}.
	if !count_is_one(iv.count) {
		fmt.printf(" * %s", pretty_integer_intervals(iv.count.integer_intervals))
	}
}


// Renders a String_Type into a builder for diagnostic messages.
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
	// "string" case: a single fully open interval.
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


// ---------------------------------------------------------------------------
// Decoding of escapes according to the quotation.
//   .simple / .double : \n \t \r \0 \\ \' \" \` interpreted
//   .backtick         : raw, no escapes
// The received text has already been stripped of delimiters by the parser.
// ---------------------------------------------------------------------------

decode_string_literal :: proc(text: string, quotation: String_Quotation) -> string {
	if quotation == .backtick {
		return text
	}
	if strings.index_byte(text, '\\') < 0 {
		return text // no escape: nothing to decode
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
				// unknown escape: keep the sequence as is
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


// ===========================================================================
// DOMAIN ENTRY POINTS — mirror of fold_type_integer / fold_constraint_integer.
// ===========================================================================

// A folded []String_Interval is ALWAYS a UNION of alternatives now (the `|`
// case). The ordered concatenation (`+`) is NOT flattened here — it stays a
// Compose_Type and is matched as an ordered sequence at satisfy time (see
// string_compose_satisfy / fold_string_sequence). So this wrapper has no
// is_sequence knob: a String_Type's segments are always read as a union.
wrap_string_intervals :: proc(segs: []String_Interval) -> ^Type {
	r := new(Type)
	def, def_q := default_for_string_intervals(segs)
	r^ = String_Type{segs, def, def_q}
	return r
}

// seg_default : one segment's default string — its low bound (or high if no low),
// repeated by the LOW bound of its count ("ab"*3 → "ababab", 'a'..'z'*0.. → "").
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

// The default of a UNION (the only thing a []String_Interval is) is the first
// term's default, rendered with that term's quote (ordinal → single, else double).
default_for_string_intervals :: proc(segs: []String_Interval) -> (Maybe(string), String_Quotation) {
	if len(segs) == 0 do return nil, .double
	return seg_default(segs[0]), interval_quote(segs[0])
}

// fold_type_string : string envelope produced by a value, or nil.
fold_type_string :: proc(t: ^Type) -> ^Type {
	segs, ok := fold_string_intervals(t, false).([]String_Interval)
	if !ok do return nil
	return wrap_string_intervals(segs)
}

// fold_constraint_string : resolved string constraint, or nil.
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

// fold_string_intervals : reduces a ^Type to its string segments. `as_constraint`
// distinguishes the value fold (the string the expression produces) from the
// constraint fold (the imposed set) — the difference shows up on
// Mention/Reference where the constraint follows the target's VALUE, not its type.
// A `+` concatenation does NOT fold to a flat union here (it stays a Compose_Type,
// matched in order — see fold_string_sequence); only its concrete collapse does.
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
				return fold_string_intervals(v.values[i], as_constraint)
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
			// `+` of TWO CONCRETE single segments folds to one concrete literal
			// ("jw" + "t" → "jwt").
			if joined, ok := string_concat_concrete(lseg, rseg); ok {
				return joined
			}
			// A purely POSITIONAL `+` (every segment a concrete/prefix/suffix, no
			// ordinal class and no repetition) flattens to the legacy {prefix, suffix}
			// positional interval — negation/intersection/default need a String_Type
			// here (`~("".. + '_')`, `'a'..'z'+'@'+'a'..'z'`). A `+` that carries an
			// ordinal CLASS or a repetition is an ORDERED SEQUENCE we do NOT flatten:
			// it stays a Compose_Type and is matched in order by string_compose_satisfy
			// (fold_constraint keeps the raw Compose). Returning nil signals that.
			if positional_concat(lseg, rseg) {
				return concat_positional_fold(lseg, rseg)
			}
			return nil
		}
		if v.operator == .Multiply {
			// string * integer : repetition. The left operand is string, the right
			// an integer (range) ≥ 0. We multiply the count of each string segment
			// by the multiplier via the existing integer arithmetic.
			lseg, l_ok := fold_string_intervals(v.left, as_constraint).([]String_Interval)
			if !l_ok do return nil
			mult, m_ok := fold_type_intervals(v.right).([]Integer_Interval)
			if !m_ok do return nil
			return string_intervals_repeat(lseg, mult)
		}
		return nil
	case Or_Type:
		// Folds to string ONLY if both branches do (otherwise mixed → failure,
		// symbolic + satisfy per branch).
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
		// An ORDINAL negation expands to codepoint-complement intervals (~'a'..'z').
		// A POSITIONAL negation (~"x", ~"piro") has no interval form — negate yields
		// an empty list. Returning nil (not []) lets a `+` keep it as a segment-
		// negation in the ordered sequence (fold_string_sequence), and keeps a bare
		// `~"x"` symbolic so satisfy handles it as NOT satisfy(x).
		if len(neg) == 0 do return nil
		return neg
	case Mention_Type:
		if v.match_scope != nil && v.match_index >= 0 {
			if as_constraint {
				return fold_string_intervals(v.match_scope.values[v.match_index], true)
			}
			if s, ok := stored_string_intervals(v.match_scope.type_folds[v.match_index]).([]String_Interval); ok {
				return s
			}
			if s, ok := stored_string_intervals(v.match_scope.constraint_folds[v.match_index]).([]String_Interval); ok {
				return s
			}
		}
		return nil
	case Reference_Type:
		ref := v.reference
		if ref != nil && ref.match_scope != nil && ref.match_index >= 0 {
			if as_constraint {
				return fold_string_intervals(ref.match_scope.values[ref.match_index], true)
			}
			if s, ok := stored_string_intervals(ref.match_scope.type_folds[ref.match_index]).([]String_Interval); ok {
				return s
			}
			if s, ok := stored_string_intervals(ref.match_scope.constraint_folds[ref.match_index]).([]String_Interval); ok {
				return s
			}
		}
		return nil
	}
	return nil
}


// fold_string_range : assembles a string range from the segments of both bounds.
// Lower bound = lo of the left segment, upper bound = hi of the right segment. The
// result is ORDINAL iff both bounds are ordinal single chars ('a'..'z'); any
// positional (double-quote / multi-char) bound makes it positional ("a".."z").
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
	// Ordinal only when every PRESENT bound is ordinal.
	ordinal := (!got_l || l_ord) && (!got_r || r_ord) && (got_l || got_r)
	res := make([]String_Interval, 1)
	res[0] = String_Interval{lo, hi, ordinal, count_one()}
	return res
}


// ===========================================================================
// SATISFIES — the contract. Prove that value ⊆ constraint.
// ===========================================================================

// string_interval_satisfy : true if ALL the strings described by `v` are also
// described by `c`. v is the value (left of ->), c the constraint.
//
// Two orthogonal axes: the PATTERN (bounds + mode) and the COUNT (repetition,
// = length of the sequence). Repetition changes neither the mode nor the
// pattern, it just says "how many times".
string_interval_satisfy :: proc(v, c: String_Interval) -> bool {
	c_simple := count_is_one(c.count)
	v_simple := count_is_one(v.count)

	// No repetition on the constraint side: pure pattern. (The repeated regime is
	// handled upstream by sequence_satisfy, which does not go through here.) If
	// the value carries a repetition but the constraint does not, only a concrete
	// unfoldable value can satisfy — string_interval_is_concrete handles the unfolding.
	if c_simple {
		if v_simple {
			return string_pattern_satisfy(v, c)
		}
		// repeated value, simple constraint: holds only if the value unfolds to a
		// single concrete value that satisfies the pattern.
		if string_interval_is_concrete(v) {
			s := string_interval_concrete_value(v)
			concrete := String_Interval{s, s, v.ordinal, count_one()}
			return string_pattern_satisfy(concrete, c)
		}
		return false
	}

	// Repeated constraint outside a sequence (should not happen via the dispatcher).
	return false
}


// string_pattern_satisfy : satisfiability of the PATTERN alone (count = 1 on
// both sides). This is the pure ordinal/positional logic.
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


// ordinal_within : [vlo, vhi] ⊆ [clo, chi] over the codepoints of the first char.
// A nil bound on the constraint side = open (±∞). On the value side, nil = ±∞
// too, which can only be contained in an open constraint on the same side.
ordinal_within :: proc(vlo, vhi, clo, chi: Maybe(string)) -> bool {
	// Lower bound: clo (if present) must be ≤ vlo.
	if clo_s, ok := clo.(string); ok && clo_s != "" {
		vlo_s, vok := vlo.(string)
		if !vok || vlo_s == "" do return false // value open below, constraint not
		if first_rune(vlo_s) < first_rune(clo_s) do return false
	}
	// Upper bound: chi (if present) must be ≥ vhi.
	if chi_s, ok := chi.(string); ok && chi_s != "" {
		vhi_s, vok := vhi.(string)
		if !vok || vhi_s == "" do return false
		if first_rune(vhi_s) > first_rune(chi_s) do return false
	}
	return true
}


// string_intervals_satisfy : proves value ⊆ constraint.
//
// Two regimes:
//   1. The constraint contains a REPETITION (at least one segment with count ≠ 1).
//      Then the constraint describes a SEQUENCE: the concatenation of `count`
//      elements, each element ∈ union of the segments. A concrete value is
//      checked char-by-char against this union, length ∈ count. Ex:
//      ('a'..'z'|'-')*1.. accepts "a-b" (each char in a segment, len≥1).
//   2. No repetition: each value segment ⊆ at least one constraint segment
//      (classic membership).
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


// constraint_has_repeat : at least one segment carries a count ≠ {1..1}.
constraint_has_repeat :: proc(segs: []String_Interval) -> bool {
	for s in segs do if !count_is_one(s.count) do return true
	return false
}


// sequence_satisfy : the constraint is a repeated sequence. All its segments
// share the same logical repetition (a pattern * count). We check that the
// (concrete) value is a concatenation of chars each ∈ union of the elements,
// with a length allowed by the combined count of the segments.
sequence_satisfy :: proc(value_segs, constraint_segs: []String_Interval) -> bool {
	// The global allowed count = union of the counts of all the segments.
	count_union := make([dynamic]Integer_Interval)
	for cs in constraint_segs {
		for ci in cs.count.integer_intervals do append(&count_union, ci)
	}
	allowed := integer_intervals_normalize(count_union[:])

	for vs in value_segs {
		// Each value segment must be a valid sequence.
		if !string_interval_is_concrete(vs) {
			// Ordinal repeated value: its chars ⊆ union of the elements, count ⊆ allowed.
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


// concrete_in_sequence : a concrete string `s` satisfies a repeated sequence
// (the constraint segments, each a `pattern * count`) iff it splits into `k`
// consecutive elements with `k ∈ allowed` and every element matching one of the
// segment patterns. `count` is the number of ELEMENTS, not of chars: "ab"*3 is
// 3 elements of "ab" (6 chars), while 'a'..'z'*3 is 3 elements of one char.
//
// We greedily consume one element at a time. At each position we try every
// segment element; an ordinal element consumes one codepoint, a concrete
// element consumes its own length. The greedy walk is exact when all elements
// of a given length agree (the common case); the empty string is the k=0 match.
concrete_in_sequence :: proc(s: string, segs: []String_Interval, allowed: []Integer_Interval) -> bool {
	rest := s
	k := 0
	for len(rest) > 0 {
		consumed := consume_one_element(rest, segs)
		if consumed == 0 do return false // no element matches the head
		rest = rest[consumed:]
		k += 1
	}
	return int_in_intervals(i128(k), allowed)
}


// consume_one_element : matches the head of `rest` against the element of one
// segment and returns the number of BYTES consumed (0 = no match). Concrete
// multi-char elements ("ab") are matched as a literal prefix; ordinal/1-char
// elements consume a single codepoint.
consume_one_element :: proc(rest: string, segs: []String_Interval) -> int {
	for cs in segs {
		// The ELEMENT is the pattern (lo..hi) WITHOUT the repetition count, so we
		// read cs.lo/cs.hi directly — string_interval_concrete_value would unfold
		// the count and give the whole sequence ("ab"*3 → "ababab"), not "ab".
		if string_interval_mode(cs) == .ordinal {
			r := first_rune(rest)
			rs := rune_to_string(r)
			if ordinal_within(rs, rs, cs.lo, cs.hi) do return len(rs)
			continue
		}
		// Positional element: a concrete literal element matches as a prefix.
		lo, lo_ok := cs.lo.(string)
		hi, hi_ok := cs.hi.(string)
		if lo_ok && hi_ok && lo == hi && lo != "" {
			if strings.has_prefix(rest, lo) do return len(lo)
		}
	}
	return 0
}


// ===========================================================================
// Ordered-sequence matching (concatenation `+`)
// ===========================================================================

// string_value_satisfies_sequence : the constraint is an ORDERED concatenation
// of segments (`"id_" + '0'..'9'*1..`). A concrete value satisfies it iff it
// splits, left to right, into the segments in order — each segment matched
// `count` times (count is a range, so we backtrack over how many occurrences a
// segment consumes). Only a concrete value can be checked against a sequence; a
// pattern value (itself a set) cannot be proven to be a subset positionally here.
string_value_satisfies_sequence :: proc(ft: String_Type, segs: []String_Interval) -> bool {
	if len(ft.string_intervals) != 1 do return false
	v := ft.string_intervals[0]
	if !string_interval_is_concrete(v) do return false
	s := string_interval_concrete_value(v)
	return seq_match(s, segs, 0)
}

// seq_match : can `rest` be consumed by segments[si:] in order? Each segment is a
// pattern element repeated within its count range [lo, hi] (hi nil = unbounded).
// We try every allowed occurrence count for the current segment (greedy-then-
// backtrack) and recurse on the remainder.
seq_match :: proc(rest: string, segs: []String_Interval, si: int) -> bool {
	if si >= len(segs) {
		return len(rest) == 0 // all segments consumed iff nothing is left
	}
	seg := segs[si]

	// Segment-negation (`~"piro" + …`): consume a VARIABLE-length prefix that is NOT
	// the negated word, then recurse on the rest. We try every split point (0 bytes
	// up to the whole remainder) and accept the first where the consumed prefix is
	// not the negated word AND the remaining segments match. The negated word lives
	// in seg.lo; seg.hi is unused.
	if seg_is_negation(seg) {
		neg_word, _ := seg.lo.(string)
		for cut := 0; cut <= len(rest); cut += 1 {
			prefix := rest[:cut]
			if prefix == neg_word do continue // the forbidden word: skip this split
			if seq_match(rest[cut:], segs, si + 1) do return true
		}
		return false
	}

	lo_n, hi_n := seg_count_bounds(seg)

	// Enumerate occurrence counts k from lo_n upward; for each, consume k elements
	// then recurse. An unbounded hi stops when no further element can be consumed.
	// Build the list of cut points (byte offsets) reachable by consuming 0,1,2,…
	// elements, then try those with k in [lo_n, hi_n].
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

// seg_count_bounds : the [lo, hi] occurrence range of a segment's count (hi = -1
// means unbounded / +∞). Reads the first/last interval of the count.
seg_count_bounds :: proc(seg: String_Interval) -> (lo_n: int, hi_n: int) {
	ivs := seg.count.integer_intervals
	if len(ivs) == 0 do return 1, 1
	lo_n = 1
	if l, ok := ivs[0].lo.(i128); ok do lo_n = int(l)
	hi_n = -1
	if h, ok := ivs[len(ivs) - 1].hi.(i128); ok do hi_n = int(h)
	return
}

// seg_consume_one : consume ONE occurrence of a segment's element from the head
// of `rest`, returning the bytes consumed (0 = no match). An ordinal element
// consumes one codepoint in [lo,hi]; a concrete positional element matches its
// literal as a prefix.
seg_consume_one :: proc(rest: string, seg: String_Interval) -> int {
	if len(rest) == 0 do return 0
	if string_interval_mode(seg) == .ordinal {
		r := first_rune(rest)
		rs := rune_to_string(r)
		if ordinal_within(rs, rs, seg.lo, seg.hi) do return len(rs)
		return 0
	}
	// Positional element. A concrete literal (lo == hi) matches as a prefix.
	lo, lo_ok := seg.lo.(string)
	hi, hi_ok := seg.hi.(string)
	if lo_ok && hi_ok && lo == hi {
		if lo == "" do return 0
		if strings.has_prefix(rest, lo) do return len(lo)
		return 0
	}
	// A non-concrete positional element inside a sequence (e.g. a bare "ab".. prefix
	// pattern) is not consumable element-by-element here; sequences are built from
	// concrete literals and ordinal classes in practice.
	return 0
}


// ordinal_in_element_union : is the range [lo,hi] contained in the ordinal
// element of a single segment (case value = repeated range of chars)?
ordinal_in_element_union :: proc(lo, hi: Maybe(string), segs: []String_Interval) -> bool {
	for cs in segs {
		if string_interval_mode(cs) != .ordinal do continue
		if ordinal_within(lo, hi, cs.lo, cs.hi) do return true
	}
	return false
}


// string_satisfy : the constraint is a UNION of alternatives (a folded
// String_Type). value ⊆ constraint via string_intervals_satisfy. The ordered
// concatenation (`+`) does NOT come here — it stays a Compose_Type and is handled
// by string_compose_satisfy (called from satisfy in type.odin).
string_satisfy :: proc(fc, ft: String_Type) -> bool {
	return string_intervals_satisfy(ft.string_intervals, fc.string_intervals)
}

// string_sequence_default : the materialized default of a `+` string sequence —
// the in-order concatenation of each segment's default. Returns nil when `t` is
// not a string sequence (so type_default can fall through to other domains).
string_sequence_default :: proc(t: ^Type) -> ^Type {
	segs, ok := fold_string_sequence(t, true).([]String_Interval)
	if !ok || len(segs) == 0 do return nil
	b := strings.builder_make()
	for iv in segs do strings.write_string(&b, seg_default(iv))
	r := new(Type)
	r^ = make_string_const(strings.to_string(b), .double)
	return r
}

// string_compose_satisfy : the constraint is a string concatenation `+` kept as a
// Compose_Type (an ORDERED SEQUENCE). The value (a concrete string) must split,
// left to right, into the sequence's segments in order. `fc` is the ^Type Compose.
string_compose_satisfy :: proc(fc: ^Type, ft: String_Type) -> bool {
	segs, ok := fold_string_sequence(fc, true).([]String_Interval)
	if !ok do return false
	return string_value_satisfies_sequence(ft, segs)
}

// string_is_tri_range : true when `t` is a THREE-bound STRING range — a Range_Type
// whose right operand is itself a Range_Type, and whose bounds fold to strings.
// `"ab".."cd".."ef"` = Range{ab, Range{cd, ef}}.
string_is_tri_range :: proc(t: ^Type) -> bool {
	r, ok := t^.(Range_Type)
	if !ok || r.left == nil || r.right == nil do return false
	_, inner_is_range := follow(r.right)^.(Range_Type)
	if !inner_is_range do return false
	// All three bounds must be strings (so this is a string tri-range, not numeric).
	return fold_constraint_string(t) != nil
}

// string_tri_range_bounds : the (prefix, middle, suffix) literals of a three-bound
// string range. prefix = lo of left, middle = lo of inner-left, suffix = hi of
// inner-right. Each may be empty (open bound).
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

// string_tri_range_satisfy : a concrete value satisfies `"ab".."cd".."ef"` iff it
// starts with "ab", CONTAINS "cd" (anywhere between prefix and suffix), and ends
// with "ef". Only a concrete value can be checked.
string_tri_range_satisfy :: proc(fc: ^Type, ft: String_Type) -> bool {
	if !string_is_concrete(ft) do return false
	s := string_value(ft)
	prefix, middle, suffix := string_tri_range_bounds(fc)
	if prefix != "" && !strings.has_prefix(s, prefix) do return false
	if suffix != "" && !strings.has_suffix(s, suffix) do return false
	if middle != "" && !strings.contains(s, middle) do return false
	return true
}


// ===========================================================================
// SET OPERATIONS — | (union), & (intersection), ~ (negation)
// ===========================================================================

// Union : we simply concatenate the segments (string sets do not "merge" as
// cleanly as integers; we keep the list, and satisfy walks all the segments
// anyway). We deduplicate identical ones.
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


// Intersection : cartesian product segment×segment, keeping the pairs whose
// intersection is non-empty.
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


// Intersection of two intervals. Returns ok=false if empty (None). The count of
// the result is the intersection of the counts (length axis orthogonal to the pattern).
string_interval_intersect :: proc(x, y: String_Interval) -> (String_Interval, bool) {
	xm := string_interval_mode(x)
	ym := string_interval_mode(y)

	count_segs := integer_intervals_intersect(x.count.integer_intervals, y.count.integer_intervals)
	if len(count_segs) == 0 do return {}, false
	count := Integer_Type{count_segs, default_for_integer_intervals(count_segs)}

	// Two ordinals: intersection of the codepoint ranges.
	if xm == .ordinal && ym == .ordinal {
		lo := ordinal_max_lo(x.lo, y.lo)
		hi := ordinal_min_hi(x.hi, y.hi)
		if !ordinal_lo_le_hi(lo, hi) do return {}, false
		return String_Interval{lo, hi, true, count}, true
	}

	// At least one concrete: the intersection is that concrete if it satisfies the other.
	if string_interval_is_concrete(x) && string_interval_satisfy(x, y) do return {x.lo, x.hi, x.ordinal, count}, true
	if string_interval_is_concrete(y) && string_interval_satisfy(y, x) do return {y.lo, y.hi, y.ordinal, count}, true

	// Two positionals: combine the longest compatible prefix and suffix.
	if xm == .positional && ym == .positional {
		pre, pre_ok := longest_compatible(x.lo, y.lo, true)
		if !pre_ok do return {}, false
		suf, suf_ok := longest_compatible(x.hi, y.hi, false)
		if !suf_ok do return {}, false
		return String_Interval{pre, suf, false, count}, true
	}

	// Non-concrete ordinal/positional mix: conservatively empty.
	return {}, false
}


// longest_compatible : for two prefixes (is_prefix=true) or suffixes, one must
// be an affix of the other; we return the most constraining (the longest). If
// neither is an affix of the other, the intersection is empty.
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


// Ordinal negation : ~'A'..'Z' = chars outside [A, Z]. We only cleanly negate
// the ordinal (positional bounds don't negate into simple intervals).
string_intervals_negate :: proc(segs: []String_Interval) -> []String_Interval {
	result := make([dynamic]String_Interval)
	for iv in segs {
		if string_interval_mode(iv) != .ordinal do continue
		lo, lo_ok := iv.lo.(string)
		hi, hi_ok := iv.hi.(string)
		// before the lower bound
		if lo_ok && lo != "" {
			r := first_rune(lo)
			if r > 0 {
				append(&result, String_Interval{nil, rune_to_string(r - 1), true, count_one()})
			}
		}
		// after the upper bound
		if hi_ok && hi != "" {
			r := first_rune(hi)
			append(&result, String_Interval{rune_to_string(r + 1), nil, true, count_one()})
		}
	}
	return result[:]
}


// negate_ordinal_string : expands ~X into intervals ONLY if X folds into a pure
// ordinal string (each segment ordinal, count 1, complement representable in
// codepoints). Otherwise nil → the negation stays symbolic (Negate_Type) and is
// handled at the satisfy level as NOT satisfy(X). Avoids silently "missing"
// positional negations as it does today.
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


// ===========================================================================
// CONCATENATION — + on strings/chars
// ===========================================================================

// string_concat_concrete : `a + b` when BOTH sides are a single concrete segment
// → one concrete literal ("jw" + "t" → "jwt"). Returns ok=false otherwise (a
// non-concrete `+` is an ordered sequence kept symbolic, see fold_string_sequence).
string_concat_concrete :: proc(a, b: []String_Interval) -> ([]String_Interval, bool) {
	if len(a) != 1 || len(b) != 1 do return nil, false
	x := a[0]
	y := b[0]
	if !string_interval_is_concrete(x) || !string_interval_is_concrete(y) do return nil, false
	joined := strings.concatenate({string_interval_concrete_value(x), string_interval_concrete_value(y)})
	res := make([]String_Interval, 1)
	// A concatenation is a multi-char STRING → positional (not ordinal).
	res[0] = String_Interval{joined, joined, false, count_one()}
	return res, true
}

// positional_concat : true when a `+` is PURELY positional — every operand
// segment is a concrete literal or a prefix/suffix pattern with no ordinal class
// and no repetition. Such a concat is just "starts with …, ends with …" and folds
// to a single positional interval (legacy), so negation/intersection keep working.
// A single ordinal class ('a'..'z') or any repetition makes it an ordered sequence.
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

// concat_positional_fold : the legacy {prefix(a), suffix(b)} positional interval
// for a purely positional `a + b`. prefix = guaranteed prefix of the left side,
// suffix = guaranteed suffix of the right side.
concat_positional_fold :: proc(a, b: []String_Interval) -> []String_Interval {
	pre: Maybe(string) = nil
	suf: Maybe(string) = nil
	if len(a) == 1 do pre = concat_prefix(a[0])
	if len(b) == 1 do suf = concat_suffix(b[0])
	res := make([]String_Interval, 1)
	res[0] = String_Interval{pre, suf, false, count_one()}
	return res
}

// fold_string_sequence : the ORDERED list of segments of a `+` chain, left to
// right, WITHOUT flattening into a union. `"id_" + '0'..'9'*1..` → [{"id_"},
// {'0'..'9' *1..}]. Each operand may itself be a `+` (associativity), a single
// interval, or a union (kept as one alternative-group segment — rare). Returns nil
// when an operand is not a string. This is what the sequence matcher walks.
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
			mult, m_ok := fold_type_intervals(v.right).([]Integer_Interval)
			if !m_ok do return nil
			return string_intervals_repeat(lseg, mult)
		}
		return nil
	case Negate_Type:
		// A negation operand of a sequence (`~"piro" + …`). If it folds cleanly into
		// ordinal complement intervals (a char negation like `~'0'..'9'`), use those —
		// they are consumable as ordinary ordinal segments. Otherwise (a POSITIONAL
		// word negation like `~"piro"`) we keep it as a SEGMENT-NEGATION sentinel: a
		// String_Interval whose lo is the negated word and whose count is the
		// impossible {-1..-1}, recognized by seg_is_negation / seg_consume below. It
		// matches a variable-length prefix that is NOT the negated word.
		if neg := negate_ordinal_string(v.operand); neg != nil {
			return fold_string_intervals(neg, as_constraint)
		}
		inner, ok := fold_string_intervals(v.operand, as_constraint).([]String_Interval)
		if !ok || len(inner) == 0 do return nil
		segs := make([]String_Interval, len(inner))
		for iv, i in inner do segs[i] = String_Interval{iv.lo, iv.hi, iv.ordinal, count_negation_sentinel()}
		return segs
	}
	// A non-Compose operand folds to its (union) segments — one sequence element.
	return fold_string_intervals(t, as_constraint)
}


// ===========================================================================
// REPETITION — * on strings/chars
// ===========================================================================

// string_intervals_repeat : multiplies the count of each string segment by the
// integer multiplier `mult` (reuses the integer interval arithmetic). The
// multiplier must be ≥ 0 everywhere; otherwise nil (→ error upstream via
// string_repeat_mult_valid).
string_intervals_repeat :: proc(segs: []String_Interval, mult: []Integer_Interval) -> []String_Interval {
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


// count_mul : multiplication of two count intervals, both ≥ 0. The upper bounds
// may be open (+∞). The lower bounds are always finite ≥ 0 (guaranteed by
// string_repeat_mult_valid + the default count). So [a,b]*[c,d] = [a*c, b*d]
// with ∞ absorbing at the top (unless the other equals 0).
count_mul :: proc(x, y: Integer_Interval) -> Integer_Interval {
	xlo := x.lo.(i128) or_else 0
	ylo := y.lo.(i128) or_else 0
	lo := xlo * ylo

	xhi, xhi_ok := x.hi.(i128)
	yhi, yhi_ok := y.hi.(i128)
	// Upper bound: ∞ if one of the two is open AND the other is not bounded to 0.
	if !xhi_ok || !yhi_ok {
		// open * 0 = 0 (if the other has hi=0); otherwise ∞.
		if xhi_ok && xhi == 0 do return Integer_Interval{lo, i128(0)}
		if yhi_ok && yhi == 0 do return Integer_Interval{lo, i128(0)}
		return Integer_Interval{lo, nil}
	}
	return Integer_Interval{lo, xhi * yhi}
}


// string_repeat_mult_valid : the multiplier of a string repetition must be an
// integer (range) ≥ 0 — no negative lower bound.
string_repeat_mult_valid :: proc(mult: []Integer_Interval) -> bool {
	if len(mult) == 0 do return false
	for m in mult {
		lo, lo_ok := m.lo.(i128)
		if !lo_ok do return false // open lower bound (-∞): may be negative
		if lo < 0 do return false
	}
	return true
}


// The guaranteed prefix of an interval used as the left operand of a concat.
concat_prefix :: proc(iv: String_Interval) -> Maybe(string) {
	if string_interval_is_concrete(iv) do return iv.lo
	switch string_interval_mode(iv) {
	case .positional:
		return iv.lo // starts with iv.lo
	case .ordinal:
		return nil // variable char: no guaranteed literal prefix
	}
	return nil
}


// The guaranteed suffix of an interval used as the right operand of a concat.
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


// ===========================================================================
// Ordinal / miscellaneous helpers
// ===========================================================================

string_interval_equal :: proc(a, b: String_Interval) -> bool {
	if !(maybe_string_eq(a.lo, b.lo) && maybe_string_eq(a.hi, b.hi) && a.ordinal == b.ordinal) {
		return false
	}
	// equal counts: same segment length, same bounds.
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

// ordinal_max_lo / ordinal_min_hi : codepoint bounds, nil = open.
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

// rune_count : number of codepoints in a string.
rune_count :: proc(s: string) -> int {
	n := 0
	for _ in s do n += 1
	return n
}

// int_in_intervals : val ∈ one of the integer segments.
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
