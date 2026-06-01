package compiler

import "core:fmt"
import "core:strings"
import "core:unicode/utf8"

// ============================================================================
// Famille string/char — modèle unifié sur []String_Interval.
//
// Un String_Interval porte ses bornes (lo, hi: Maybe(string)) et le quotation
// d'origine. La sémantique du range dérive du quotation + de la longueur des
// bornes (cf. String_Interval dans analyzer.odin) :
//   .simple   + borne(s) de longueur ≤ 1 → ordinal  (codepoints)
//   .simple   + borne plus longue         → string mode
//   .double / .backtick                   → positionnel (préfixe..suffixe)
//
// Calqué sur fold_integer.odin / fold_float.odin : un Type concret est un
// intervalle dégénéré (lo == hi) à un seul segment.
// ============================================================================


// ---------------------------------------------------------------------------
// Construction
// ---------------------------------------------------------------------------

// Valeur string concrète (dégénérée) : lo == hi. Le default est la valeur
// elle-même, comme make_int_result/make_float_result.
make_string_const :: proc(value: string, quotation: String_Quotation) -> Type {
	intervals := make([]String_Interval, 1)
	intervals[0] = String_Interval{value, value, quotation}
	return String_Type{intervals, value, quotation}
}


// `String` builtin = toutes les strings = un intervalle positionnel ouvert.
// Default = la string vide (borne basse ouverte du positionnel).
make_string_any :: proc() -> Type {
	intervals := make([]String_Interval, 1)
	intervals[0] = String_Interval{nil, nil, .double}
	return String_Type{intervals, "", .double}
}


// ---------------------------------------------------------------------------
// Prédicats
// ---------------------------------------------------------------------------

string_is_concrete :: #force_inline proc(t: String_Type) -> bool {
	if len(t.string_intervals) != 1 do return false
	iv := t.string_intervals[0]
	lo, lo_ok := iv.lo.(string)
	hi, hi_ok := iv.hi.(string)
	return lo_ok && hi_ok && lo == hi
}


string_value :: #force_inline proc(t: String_Type) -> string {
	return t.string_intervals[0].lo.(string)
}


// Mode sémantique d'un intervalle (cf. en-tête). Dérivé de quotation + longueur
// des bornes. Une borne ordinale est un char unique (rune) ; tout le reste est
// positionnel (préfixe/suffixe). La string vide compte comme borne ouverte.
String_Mode :: enum {
	ordinal,    // 'a'..'z' : un char, codepoint dans [lo, hi]
	positional, // "p".."s" : commence par p, finit par s
}


// rune_count_le_one : true si la string est vide ou d'un seul codepoint.
rune_count_le_one :: proc(s: string) -> bool {
	count := 0
	for _ in s {
		count += 1
		if count > 1 do return false
	}
	return true
}


// first_rune renvoie le premier codepoint d'une string non vide.
first_rune :: proc(s: string) -> rune {
	for r in s do return r
	return 0
}


string_interval_mode :: proc(iv: String_Interval) -> String_Mode {
	if iv.quotation != .simple do return .positional
	// simple : ordinal seulement si les deux bornes présentes sont ≤ 1 char.
	if lo, ok := iv.lo.(string); ok && !rune_count_le_one(lo) do return .positional
	if hi, ok := iv.hi.(string); ok && !rune_count_le_one(hi) do return .positional
	return .ordinal
}


string_interval_is_concrete :: #force_inline proc(iv: String_Interval) -> bool {
	lo, lo_ok := iv.lo.(string)
	hi, hi_ok := iv.hi.(string)
	return lo_ok && hi_ok && lo == hi
}


// ---------------------------------------------------------------------------
// Impression
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


print_string_interval :: proc(iv: String_Interval) {
	open, close := string_quote_pair(iv.quotation)
	lo, lo_ok := iv.lo.(string)
	hi, hi_ok := iv.hi.(string)
	if lo_ok && hi_ok && lo == hi {
		fmt.printf("%r%s%r", open, lo, close)
		return
	}
	if lo_ok do fmt.printf("%r%s%r", open, lo, close)
	fmt.print("..")
	if hi_ok do fmt.printf("%r%s%r", open, hi, close)
}


// Rend un String_Type dans un builder pour les messages de diagnostic.
write_string_desc :: proc(b: ^strings.Builder, t: String_Type) {
	if string_is_concrete(t) {
		open, close := string_quote_pair(t.string_intervals[0].quotation)
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
			strings.write_string(b, "String")
			return
		}
	}
	strings.write_string(b, "string")
}


print_string_type :: proc(t: String_Type) {
	// Cas "String" : intervalle unique entièrement ouvert.
	if len(t.string_intervals) == 1 {
		iv := t.string_intervals[0]
		_, lo_ok := iv.lo.(string)
		_, hi_ok := iv.hi.(string)
		if !lo_ok && !hi_ok {
			fmt.print("String")
			return
		}
	}
	for iv, i in t.string_intervals {
		if i > 0 do fmt.print(" | ")
		print_string_interval(iv)
	}
}


// ---------------------------------------------------------------------------
// Décodage des échappements selon le quotation.
//   .simple / .double : \n \t \r \0 \\ \' \" \` interprétés
//   .backtick         : brut, aucun échappement
// Le texte reçu est déjà débarrassé des délimiteurs par le parser.
// ---------------------------------------------------------------------------

decode_string_literal :: proc(text: string, quotation: String_Quotation) -> string {
	if quotation == .backtick {
		return text
	}
	if strings.index_byte(text, '\\') < 0 {
		return text // pas d'échappement : rien à décoder
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
				// échappement inconnu : on conserve la séquence telle quelle
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
// ENTRÉES DOMAINE — miroir de fold_type_integer / fold_constraint_integer.
// ===========================================================================

wrap_string_intervals :: proc(segs: []String_Interval) -> ^Type {
	r := new(Type)
	def, def_q := default_for_string_intervals(segs)
	r^ = String_Type{segs, def, def_q}
	return r
}

default_for_string_intervals :: proc(segs: []String_Interval) -> (Maybe(string), String_Quotation) {
	if len(segs) == 0 do return nil, .double
	iv := segs[0]
	if lo, ok := iv.lo.(string); ok do return lo, iv.quotation
	if hi, ok := iv.hi.(string); ok do return hi, iv.quotation
	return "", iv.quotation
}

// fold_type_string : enveloppe string produite par une valeur, ou nil.
fold_type_string :: proc(t: ^Type) -> ^Type {
	segs, ok := fold_string_intervals(t, false).([]String_Interval)
	if !ok do return nil
	return wrap_string_intervals(segs)
}

// fold_constraint_string : contrainte string résolue, ou nil.
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

// fold_string_intervals : ramène un ^Type à ses segments string. `as_constraint`
// distingue le fold de la valeur (la string que produit l'expression) du fold de
// la contrainte (le set imposé) — la différence se voit sur Mention/Reference où
// la contrainte suit la VALEUR de la cible, pas son type.
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
			return string_intervals_concat(lseg, rseg)
		}
		return nil
	case Or_Type:
		lseg, l_ok := fold_string_intervals(v.left, as_constraint).([]String_Interval)
		rseg, r_ok := fold_string_intervals(v.right, as_constraint).([]String_Interval)
		if !l_ok do return r_ok ? rseg : nil
		if !r_ok do return lseg
		return string_intervals_union(lseg, rseg)
	case And_Type:
		lseg, l_ok := fold_string_intervals(v.left, as_constraint).([]String_Interval)
		rseg, r_ok := fold_string_intervals(v.right, as_constraint).([]String_Interval)
		if !l_ok || !r_ok do return nil
		return string_intervals_intersect(lseg, rseg)
	case Negate_Type:
		inner, ok := fold_string_intervals(v.operand, as_constraint).([]String_Interval)
		if !ok do return nil
		return string_intervals_negate(inner)
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


// fold_string_range : assemble un range string à partir des segments des deux
// bornes. Un range a une borne basse (lo du segment gauche) et une borne haute
// (hi du segment droit). Le quotation provient des bornes ; ordinal vs
// positionnel se dérive ensuite via string_interval_mode.
fold_string_range :: proc(lseg, rseg: []String_Interval) -> []String_Interval {
	lo: Maybe(string) = nil
	hi: Maybe(string) = nil
	q: String_Quotation = .double
	got_q := false
	if len(lseg) > 0 {
		lo = lseg[0].lo
		q = lseg[0].quotation
		got_q = true
	}
	if len(rseg) > 0 {
		hi = rseg[0].hi
		if !got_q do q = rseg[0].quotation
	}
	res := make([]String_Interval, 1)
	res[0] = String_Interval{lo, hi, q}
	return res
}


// ===========================================================================
// SATISFIES — le contrat. Prouver que value ⊆ constraint.
// ===========================================================================

// string_interval_satisfy : vrai si TOUTES les strings décrites par `v` sont
// aussi décrites par `c`. v est la valeur (gauche du ->), c la contrainte.
string_interval_satisfy :: proc(v, c: String_Interval) -> bool {
	vmode := string_interval_mode(v)
	cmode := string_interval_mode(c)

	switch cmode {
	case .ordinal:
		// La contrainte impose : un seul char, codepoint dans [c.lo, c.hi].
		switch vmode {
		case .ordinal:
			// [v.lo, v.hi] ⊆ [c.lo, c.hi] sur les codepoints.
			return ordinal_within(v.lo, v.hi, c.lo, c.hi)
		case .positional:
			// Une string positionnelle n'est garantie d'un seul char que si elle
			// est concrète de longueur 1 ; sinon on ne peut pas prouver.
			if !string_interval_is_concrete(v) do return false
			s := v.lo.(string)
			if !rune_count_le_one(s) || len(s) == 0 do return false
			return ordinal_within(s, s, c.lo, c.hi)
		}
	case .positional:
		// La contrainte impose : commence par c.lo (préfixe), finit par c.hi
		// (suffixe). Borne nil = pas de contrainte de ce côté.
		switch vmode {
		case .positional:
			// v garantit de commencer par v.lo et finir par v.hi.
			// Pour que v ⊆ c : le préfixe garanti de v doit lui-même commencer
			// par le préfixe exigé c.lo, et le suffixe garanti finir par c.hi.
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
			// v est un char unique (ou une plage de chars). Il satisfait un
			// pattern positionnel seulement si on peut prouver préfixe ET suffixe.
			// Un range ordinal non concret ne le peut pas (chars variables) sauf
			// si la contrainte n'exige rien (préfixe/suffixe vides → String).
			cpre, cpre_ok := c.lo.(string)
			csuf, csuf_ok := c.hi.(string)
			pre_free := !cpre_ok || cpre == ""
			suf_free := !csuf_ok || csuf == ""
			if pre_free && suf_free do return true // contrainte = String, tout passe
			// Sinon il faut une value concrète pour vérifier.
			if !string_interval_is_concrete(v) do return false
			s := v.lo.(string)
			if cpre_ok && !strings.has_prefix(s, cpre) do return false
			if csuf_ok && !strings.has_suffix(s, csuf) do return false
			return true
		}
	}
	return false
}


// ordinal_within : [vlo, vhi] ⊆ [clo, chi] sur les codepoints du premier char.
// Une borne nil côté contrainte = ouverte (±∞). Côté valeur, nil = ±∞ aussi,
// qui ne peut être contenu que dans une contrainte ouverte du même côté.
ordinal_within :: proc(vlo, vhi, clo, chi: Maybe(string)) -> bool {
	// Borne basse : clo (si présente) doit être ≤ vlo.
	if clo_s, ok := clo.(string); ok && clo_s != "" {
		vlo_s, vok := vlo.(string)
		if !vok || vlo_s == "" do return false // value ouverte en bas, contrainte non
		if first_rune(vlo_s) < first_rune(clo_s) do return false
	}
	// Borne haute : chi (si présente) doit être ≥ vhi.
	if chi_s, ok := chi.(string); ok && chi_s != "" {
		vhi_s, vok := vhi.(string)
		if !vok || vhi_s == "" do return false
		if first_rune(vhi_s) > first_rune(chi_s) do return false
	}
	return true
}


// string_intervals_satisfy : chaque segment de value doit être couvert par AU
// MOINS un segment de constraint (comme integer_intervals_satisfy).
string_intervals_satisfy :: proc(value_segs, constraint_segs: []String_Interval) -> bool {
	if value_segs == nil || constraint_segs == nil do return false
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


string_satisfy :: proc(fc, ft: String_Type) -> bool {
	return string_intervals_satisfy(ft.string_intervals, fc.string_intervals)
}


// ===========================================================================
// OPÉRATIONS D'ENSEMBLE — | (union), & (intersection), ~ (négation)
// ===========================================================================

// Union : on concatène simplement les segments (les ensembles string ne se
// "fusionnent" pas aussi proprement que les entiers ; on garde la liste, le
// satisfy parcourt tous les segments de toute façon). On déduplique l'identique.
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


// Intersection : produit cartésien segment×segment, en gardant les paires dont
// l'intersection est non vide.
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


// Intersection de deux intervalles. Renvoie ok=false si vide (None).
string_interval_intersect :: proc(x, y: String_Interval) -> (String_Interval, bool) {
	xm := string_interval_mode(x)
	ym := string_interval_mode(y)

	// Deux ordinaux : intersection des plages de codepoints.
	if xm == .ordinal && ym == .ordinal {
		lo := ordinal_max_lo(x.lo, y.lo)
		hi := ordinal_min_hi(x.hi, y.hi)
		if !ordinal_lo_le_hi(lo, hi) do return {}, false
		return String_Interval{lo, hi, .simple}, true
	}

	// Au moins un concret : l'intersection est ce concret s'il satisfait l'autre.
	if string_interval_is_concrete(x) && string_interval_satisfy(x, y) do return x, true
	if string_interval_is_concrete(y) && string_interval_satisfy(y, x) do return y, true

	// Deux positionnels : combiner préfixe le plus long compatible et suffixe.
	if xm == .positional && ym == .positional {
		pre, pre_ok := longest_compatible(x.lo, y.lo, true)
		if !pre_ok do return {}, false
		suf, suf_ok := longest_compatible(x.hi, y.hi, false)
		if !suf_ok do return {}, false
		q := x.quotation == .backtick || y.quotation == .backtick ? String_Quotation.backtick : .double
		return String_Interval{pre, suf, q}, true
	}

	// Mélange ordinal/positionnel non concret : conservativement vide.
	return {}, false
}


// longest_compatible : pour deux préfixes (is_prefix=true) ou suffixes, l'un doit
// être affixe de l'autre ; on renvoie le plus contraignant (le plus long). Si
// aucun n'est affixe de l'autre, intersection vide.
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


// Négation ordinale : ~'A'..'Z' = chars hors [A, Z]. On ne nie proprement que
// l'ordinal (les bornes positionnelles ne se nient pas en intervalles simples).
string_intervals_negate :: proc(segs: []String_Interval) -> []String_Interval {
	result := make([dynamic]String_Interval)
	for iv in segs {
		if string_interval_mode(iv) != .ordinal do continue
		lo, lo_ok := iv.lo.(string)
		hi, hi_ok := iv.hi.(string)
		// avant la borne basse
		if lo_ok && lo != "" {
			r := first_rune(lo)
			if r > 0 {
				append(&result, String_Interval{nil, rune_to_string(r - 1), .simple})
			}
		}
		// après la borne haute
		if hi_ok && hi != "" {
			r := first_rune(hi)
			append(&result, String_Interval{rune_to_string(r + 1), nil, .simple})
		}
	}
	return result[:]
}


// ===========================================================================
// CONCATÉNATION — + sur strings/chars
// ===========================================================================

// string_intervals_concat : a + b. Deux concrètes → concaténation concrète.
// Sinon, pattern positionnel "commence par préfixe(a), finit par suffixe(b)".
string_intervals_concat :: proc(a, b: []String_Interval) -> []String_Interval {
	if len(a) == 1 && len(b) == 1 {
		x := a[0]
		y := b[0]
		if string_interval_is_concrete(x) && string_interval_is_concrete(y) {
			joined := strings.concatenate({x.lo.(string), y.lo.(string)})
			q := x.quotation == .backtick || y.quotation == .backtick ? String_Quotation.backtick : .double
			res := make([]String_Interval, 1)
			res[0] = String_Interval{joined, joined, q}
			return res
		}
		// Pattern : préfixe = ce que a garantit en tête, suffixe = ce que b
		// garantit en fin. Le résultat commence par prefix(a), finit par suffix(b).
		pre := concat_prefix(x)
		suf := concat_suffix(y)
		res := make([]String_Interval, 1)
		res[0] = String_Interval{pre, suf, .double}
		return res
	}
	return nil
}


// Le préfixe garanti d'un intervalle utilisé comme membre gauche d'une concat.
concat_prefix :: proc(iv: String_Interval) -> Maybe(string) {
	if string_interval_is_concrete(iv) do return iv.lo
	switch string_interval_mode(iv) {
	case .positional:
		return iv.lo // commence par iv.lo
	case .ordinal:
		return nil // char variable : aucun préfixe littéral garanti
	}
	return nil
}


// Le suffixe garanti d'un intervalle utilisé comme membre droit d'une concat.
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
// Helpers ordinaux / divers
// ===========================================================================

string_interval_equal :: proc(a, b: String_Interval) -> bool {
	return maybe_string_eq(a.lo, b.lo) && maybe_string_eq(a.hi, b.hi) && a.quotation == b.quotation
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

// ordinal_max_lo / ordinal_min_hi : bornes de codepoint, nil = ouverte.
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

ordinal_lo_le_hi :: proc(lo, hi: Maybe(string)) -> bool {
	lo_s, lo_ok := lo.(string)
	hi_s, hi_ok := hi.(string)
	if !lo_ok || lo_s == "" do return true
	if !hi_ok || hi_s == "" do return true
	return first_rune(lo_s) <= first_rune(hi_s)
}
