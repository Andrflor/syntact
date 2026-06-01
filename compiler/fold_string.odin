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

// count_one : la répétition par défaut {1..1} (une occurrence). Réutilisée
// partout où un String_Interval n'a pas de `*` explicite.
count_one :: proc() -> Integer_Type {
	segs := make([]Integer_Interval, 1)
	segs[0] = Integer_Interval{i128(1), i128(1)}
	return Integer_Type{segs, i128(1)}
}


// count_is_one : true si le count est exactement {1..1} (pas de répétition).
count_is_one :: proc(c: Integer_Type) -> bool {
	if len(c.integer_intervals) != 1 do return false
	lo, lo_ok := c.integer_intervals[0].lo.(i128)
	hi, hi_ok := c.integer_intervals[0].hi.(i128)
	return lo_ok && hi_ok && lo == 1 && hi == 1
}


// Valeur string concrète (dégénérée) : lo == hi. Le default est la valeur
// elle-même, comme make_int_result/make_float_result.
make_string_const :: proc(value: string, quotation: String_Quotation) -> Type {
	intervals := make([]String_Interval, 1)
	intervals[0] = String_Interval{value, value, quotation, count_one()}
	return String_Type{intervals, value, quotation}
}


// `String` builtin = toutes les strings = un intervalle positionnel ouvert.
// Default = la string vide (borne basse ouverte du positionnel).
make_string_any :: proc() -> Type {
	intervals := make([]String_Interval, 1)
	intervals[0] = String_Interval{nil, nil, .double, count_one()}
	return String_Type{intervals, "", .double}
}


// ---------------------------------------------------------------------------
// Prédicats
// ---------------------------------------------------------------------------

string_is_concrete :: #force_inline proc(t: String_Type) -> bool {
	if len(t.string_intervals) != 1 do return false
	return string_interval_is_concrete(t.string_intervals[0])
}


// Valeur concrète, répétition dépliée. Présuppose string_is_concrete(t).
string_value :: #force_inline proc(t: String_Type) -> string {
	return string_interval_concrete_value(t.string_intervals[0])
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


// Concret = bornes égales ET count fixe concret (une seule longueur connue).
// "ab"*3 est concret (déplie en "ababab") ; "ab"*2..3 ne l'est pas.
string_interval_is_concrete :: #force_inline proc(iv: String_Interval) -> bool {
	lo, lo_ok := iv.lo.(string)
	hi, hi_ok := iv.hi.(string)
	if !lo_ok || !hi_ok || lo != hi do return false
	return int_is_concrete(iv.count)
}


// Valeur concrète dépliée : la string littérale que l'intervalle dénote, en
// répétant `count` fois. Présuppose string_interval_is_concrete(iv).
string_interval_concrete_value :: proc(iv: String_Interval) -> string {
	base := iv.lo.(string)
	n := int(int_value(iv.count))
	if n <= 1 do return base
	parts := make([]string, n)
	for i in 0 ..< n do parts[i] = base
	return strings.concatenate(parts)
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
	} else {
		if lo_ok do fmt.printf("%r%s%r", open, lo, close)
		fmt.print("..")
		if hi_ok do fmt.printf("%r%s%r", open, hi, close)
	}
	// Répétition : suffixe `* count` si ce n'est pas la valeur par défaut {1..1}.
	if !count_is_one(iv.count) {
		fmt.printf(" * %s", pretty_integer_intervals(iv.count.integer_intervals))
	}
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
		if v.operator == .Multiply {
			// string * entier : répétition. Le membre gauche est string, le droit
			// un entier (range) ≥ 0. On multiplie le count de chaque segment string
			// par le multiplicateur via l'arithmétique entière existante.
			lseg, l_ok := fold_string_intervals(v.left, as_constraint).([]String_Interval)
			if !l_ok do return nil
			mult, m_ok := fold_type_intervals(v.right).([]Integer_Interval)
			if !m_ok do return nil
			return string_intervals_repeat(lseg, mult)
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
	res[0] = String_Interval{lo, hi, q, count_one()}
	return res
}


// ===========================================================================
// SATISFIES — le contrat. Prouver que value ⊆ constraint.
// ===========================================================================

// string_interval_satisfy : vrai si TOUTES les strings décrites par `v` sont
// aussi décrites par `c`. v est la valeur (gauche du ->), c la contrainte.
//
// Deux axes orthogonaux : le PATTERN (bornes + mode) et le COUNT (répétition,
// = longueur de la séquence). La répétition ne change pas le mode ni le pattern,
// elle dit juste « combien de fois ».
string_interval_satisfy :: proc(v, c: String_Interval) -> bool {
	c_simple := count_is_one(c.count)
	v_simple := count_is_one(v.count)

	// Sans répétition côté contrainte : pattern pur. (Le régime répété est géré
	// en amont par sequence_satisfy, qui ne passe pas par ici.) Si la value porte
	// une répétition mais pas la contrainte, seule une value concrète dépliable
	// peut satisfaire — string_interval_is_concrete gère le dépliage.
	if c_simple {
		if v_simple {
			return string_pattern_satisfy(v, c)
		}
		// value répétée, contrainte simple : ne vaut que si la value déplie en une
		// valeur concrète unique qui satisfait le pattern.
		if string_interval_is_concrete(v) {
			s := string_interval_concrete_value(v)
			concrete := String_Interval{s, s, v.quotation, count_one()}
			return string_pattern_satisfy(concrete, c)
		}
		return false
	}

	// Contrainte répétée hors séquence (ne devrait pas arriver via le dispatcher).
	return false
}


// string_pattern_satisfy : satisfiabilité du PATTERN seul (count = 1 des deux
// côtés). C'est la logique ordinal/positionnel pure.
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


// string_intervals_satisfy : prouve value ⊆ constraint.
//
// Deux régimes :
//   1. La contrainte contient une RÉPÉTITION (au moins un segment count ≠ 1).
//      Alors la contrainte décrit une SÉQUENCE : la concaténation de `count`
//      éléments, chaque élément ∈ union des segments. Une value concrète est
//      vérifiée char-par-char contre cette union, longueur ∈ count. Ex:
//      ('a'..'z'|'-')*1.. accepte "a-b" (chaque char dans un segment, len≥1).
//   2. Pas de répétition : chaque segment de value ⊆ au moins un segment de
//      constraint (membership classique).
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


// constraint_has_repeat : au moins un segment porte un count ≠ {1..1}.
constraint_has_repeat :: proc(segs: []String_Interval) -> bool {
	for s in segs do if !count_is_one(s.count) do return true
	return false
}


// sequence_satisfy : la contrainte est une séquence répétée. Tous ses segments
// partagent la même répétition logique (un pattern * count). On vérifie que la
// value (concrète) est une concaténation de chars chacun ∈ union des éléments,
// avec une longueur autorisée par le count combiné des segments.
sequence_satisfy :: proc(value_segs, constraint_segs: []String_Interval) -> bool {
	// Le count global autorisé = union des counts de tous les segments.
	count_union := make([dynamic]Integer_Interval)
	for cs in constraint_segs {
		for ci in cs.count.integer_intervals do append(&count_union, ci)
	}
	allowed := integer_intervals_normalize(count_union[:])

	for vs in value_segs {
		// Chaque segment de value doit être une séquence valide.
		if !string_interval_is_concrete(vs) {
			// Value répétée ordinale : ses chars ⊆ union des éléments, count ⊆ allowed.
			if string_interval_mode(vs) == .ordinal {
				if !ordinal_in_element_union(vs.lo, vs.hi, constraint_segs) do return false
				if !integer_intervals_satisfy(vs.count.integer_intervals, allowed) do return false
				continue
			}
			return false
		}
		s := string_interval_concrete_value(vs)
		n := rune_count(s)
		if !int_in_intervals(i128(n), allowed) do return false
		// Chaque char ∈ au moins un élément (borne ordinale) des segments.
		for r in s {
			rs := rune_to_string(r)
			if !char_in_element_union(rs, constraint_segs) do return false
		}
	}
	return true
}


// char_in_element_union : le char `rs` appartient-il à l'élément (bornes
// ordinales) d'au moins un segment de la contrainte ?
char_in_element_union :: proc(rs: string, segs: []String_Interval) -> bool {
	for cs in segs {
		if string_interval_mode(cs) == .ordinal {
			if ordinal_within(rs, rs, cs.lo, cs.hi) do return true
		} else if string_interval_is_concrete(cs) {
			// élément concret de longueur 1 : comparaison directe
			base := cs.lo.(string)
			if rune_count_le_one(base) && base == rs do return true
		}
	}
	return false
}


// ordinal_in_element_union : la plage [lo,hi] est-elle incluse dans l'élément
// ordinal d'un seul segment (cas value = range de chars répété) ?
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


// Intersection de deux intervalles. Renvoie ok=false si vide (None). Le count du
// résultat est l'intersection des counts (axe longueur orthogonal au pattern).
string_interval_intersect :: proc(x, y: String_Interval) -> (String_Interval, bool) {
	xm := string_interval_mode(x)
	ym := string_interval_mode(y)

	count_segs := integer_intervals_intersect(x.count.integer_intervals, y.count.integer_intervals)
	if len(count_segs) == 0 do return {}, false
	count := Integer_Type{count_segs, default_for_integer_intervals(count_segs)}

	// Deux ordinaux : intersection des plages de codepoints.
	if xm == .ordinal && ym == .ordinal {
		lo := ordinal_max_lo(x.lo, y.lo)
		hi := ordinal_min_hi(x.hi, y.hi)
		if !ordinal_lo_le_hi(lo, hi) do return {}, false
		return String_Interval{lo, hi, .simple, count}, true
	}

	// Au moins un concret : l'intersection est ce concret s'il satisfait l'autre.
	if string_interval_is_concrete(x) && string_interval_satisfy(x, y) do return {x.lo, x.hi, x.quotation, count}, true
	if string_interval_is_concrete(y) && string_interval_satisfy(y, x) do return {y.lo, y.hi, y.quotation, count}, true

	// Deux positionnels : combiner préfixe le plus long compatible et suffixe.
	if xm == .positional && ym == .positional {
		pre, pre_ok := longest_compatible(x.lo, y.lo, true)
		if !pre_ok do return {}, false
		suf, suf_ok := longest_compatible(x.hi, y.hi, false)
		if !suf_ok do return {}, false
		q := x.quotation == .backtick || y.quotation == .backtick ? String_Quotation.backtick : .double
		return String_Interval{pre, suf, q, count}, true
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
				append(&result, String_Interval{nil, rune_to_string(r - 1), .simple, count_one()})
			}
		}
		// après la borne haute
		if hi_ok && hi != "" {
			r := first_rune(hi)
			append(&result, String_Interval{rune_to_string(r + 1), nil, .simple, count_one()})
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
			joined := strings.concatenate({string_interval_concrete_value(x), string_interval_concrete_value(y)})
			q := x.quotation == .backtick || y.quotation == .backtick ? String_Quotation.backtick : .double
			res := make([]String_Interval, 1)
			res[0] = String_Interval{joined, joined, q, count_one()}
			return res
		}
		// Pattern : préfixe = ce que a garantit en tête, suffixe = ce que b
		// garantit en fin. Le résultat commence par prefix(a), finit par suffix(b).
		pre := concat_prefix(x)
		suf := concat_suffix(y)
		res := make([]String_Interval, 1)
		res[0] = String_Interval{pre, suf, .double, count_one()}
		return res
	}
	return nil
}


// ===========================================================================
// RÉPÉTITION — * sur strings/chars
// ===========================================================================

// string_intervals_repeat : multiplie le count de chaque segment string par le
// multiplicateur entier `mult` (réutilise l'arithmétique d'intervalles entiers).
// Le multiplicateur doit être ≥ 0 partout ; sinon nil (→ erreur en amont via
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
			iv.quotation,
			Integer_Type{norm, default_for_integer_intervals(norm)},
		}
	}
	return result
}


// count_mul : multiplication de deux intervalles de count, tous deux ≥ 0. Les
// bornes hautes peuvent être ouvertes (+∞). Les bornes basses sont toujours
// finies ≥ 0 (garanties par string_repeat_mult_valid + count par défaut). Donc
// [a,b]*[c,d] = [a*c, b*d] avec ∞ absorbant en haut (sauf si l'autre vaut 0).
count_mul :: proc(x, y: Integer_Interval) -> Integer_Interval {
	xlo := x.lo.(i128) or_else 0
	ylo := y.lo.(i128) or_else 0
	lo := xlo * ylo

	xhi, xhi_ok := x.hi.(i128)
	yhi, yhi_ok := y.hi.(i128)
	// Borne haute : ∞ si l'un des deux est ouvert ET l'autre n'est pas borné à 0.
	if !xhi_ok || !yhi_ok {
		// ouvert * 0 = 0 (si l'autre a hi=0) ; sinon ∞.
		if xhi_ok && xhi == 0 do return Integer_Interval{lo, i128(0)}
		if yhi_ok && yhi == 0 do return Integer_Interval{lo, i128(0)}
		return Integer_Interval{lo, nil}
	}
	return Integer_Interval{lo, xhi * yhi}
}


// string_repeat_mult_valid : le multiplicateur d'une répétition string doit être
// un entier (range) ≥ 0 — pas de borne basse négative.
string_repeat_mult_valid :: proc(mult: []Integer_Interval) -> bool {
	if len(mult) == 0 do return false
	for m in mult {
		lo, lo_ok := m.lo.(i128)
		if !lo_ok do return false // borne basse ouverte (-∞) : peut être négatif
		if lo < 0 do return false
	}
	return true
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
	if !(maybe_string_eq(a.lo, b.lo) && maybe_string_eq(a.hi, b.hi) && a.quotation == b.quotation) {
		return false
	}
	// counts égaux : même longueur de segments, mêmes bornes.
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

// rune_count : nombre de codepoints d'une string.
rune_count :: proc(s: string) -> int {
	n := 0
	for _ in s do n += 1
	return n
}

// int_in_intervals : val ∈ un des segments entiers.
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
