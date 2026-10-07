package kernel

import "core:fmt"
import "core:slice"
import "core:strings"

// LES ENSEMBLES DE CHAÎNES : des langages réguliers, gardés sous la forme de
// l'expression qui les écrit. Cette forme est seulement normalisée — mots finis
// regroupés et triés, concaténations aplaties, mots voisins fusionnés, ∅ et ""
// absorbés — sans prétendre à l'unicité : l'égalité est l'inclusion dans les deux
// sens, et l'inclusion se décide sur un automate construit au moment de décider.
//
//   "a" | "ab"        Words    un ensemble fini de mots
//   'a'..'z'          Class    un mot d'une lettre dans la plage
//   x + y             Cat
//   x | y             Alt
//   x & y             And
//   ~x                Not      ~∅ : toute chaîne
//   x * 2..4          Repeat   par un ensemble de comptes naturels

MAX_RUNE :: rune(0x10FFFF)

// Au-delà, une répétition n'est pas construite : son automate aurait autant
// d'états que de répétitions.
MAX_REPEAT :: 4096

Regex_Kind :: enum u8 {
	Words,
	Class,
	Cat,
	Alt,
	And,
	Not,
	Repeat,
}

Regex :: struct {
	kind:   Regex_Kind,
	words:  []string, // Words : non vide, sans doublon, du plus court au plus long puis dans l'ordre
	class:  Rune_Range, // Class : au moins deux caractères (un seul est un mot)
	parts:  []^Regex, // Cat, Alt, And ; Not et Repeat : parts[0]
	counts: Ints, // Repeat : des naturels, ni {0} ni {1}
}

Strings :: struct {
	re: ^Regex, // nil : le langage vide
}

Rune_Range :: struct {
	lo, hi: rune, // inclus
}

// --- constructions ---

regex :: proc(r: Regex) -> Strings {
	p := new(Regex)
	p^ = r
	return Strings{p}
}

strings_point :: proc(word: string) -> Strings {
	return strings_of_words({word})
}

strings_empty_word :: proc() -> Strings {
	return strings_point("")
}

// strings_of_words : le langage fini de ces mots.
strings_of_words :: proc(words: []string) -> Strings {
	if len(words) == 0 do return {}
	sorted := slice.clone(words)
	slice.sort_by(sorted, shortlex)
	return regex({kind = .Words, words = slice.unique(sorted)})
}

// shortlex : le plus court d'abord, puis l'ordre des points de code.
shortlex :: proc(a, b: string) -> bool {
	la, lb := strings.rune_count(a), strings.rune_count(b)
	return la != lb ? la < lb : a < b
}

// strings_runes : les mots d'un caractère compris dans [lo, hi].
strings_runes :: proc(lo, hi: rune) -> Strings {
	if lo == hi do return strings_point(fmt.tprintf("%c", lo))
	return regex({kind = .Class, class = {min(lo, hi), max(lo, hi)}})
}

strings_all :: proc() -> Strings {
	return strings_complement({})
}

is_all :: proc(a: Strings) -> bool {
	return a.re != nil && a.re.kind == .Not && a.re.parts[0] == nil
}

single_word :: proc(re: ^Regex) -> (string, bool) {
	if re != nil && re.kind == .Words && len(re.words) == 1 do return re.words[0], true
	return "", false
}

// members : les opérandes d'une opération aplatie — ceux de `re` s'il en est une
// du même genre, sinon `re` lui-même.
members :: proc(re: ^Regex, kind: Regex_Kind) -> []^Regex {
	if re.kind == kind do return re.parts
	one := make([]^Regex, 1)
	one[0] = re
	return one
}

add_new :: proc(parts: ^[dynamic]^Regex, re: ^Regex) {
	for p in parts do if regex_same(p, re) do return
	append(parts, re)
}

// regex_same : la même écriture. Une simple économie : deux écritures différentes
// peuvent être le même langage.
regex_same :: proc(a, b: ^Regex) -> bool {
	if a == nil || b == nil do return a == b
	if a.kind != b.kind || a.class != b.class || len(a.parts) != len(b.parts) do return false
	if !slice.equal(a.words, b.words) || !slice.equal(a.counts.intervals, b.counts.intervals) do return false
	for p, i in a.parts do if !regex_same(p, b.parts[i]) do return false
	return true
}

strings_union :: proc(a, b: Strings) -> Strings {
	if a.re == nil do return b
	if b.re == nil do return a
	if is_all(a) || is_all(b) do return strings_all()
	words := make([dynamic]string)
	parts := make([dynamic]^Regex)
	for x in ([2]^Regex{a.re, b.re}) {
		for m in members(x, .Alt) {
			if m.kind == .Words do append(&words, ..m.words)
			else do add_new(&parts, m)
		}
	}
	if len(words) > 0 do inject_at(&parts, 0, strings_of_words(words[:]).re)
	if len(parts) == 1 do return Strings{parts[0]}
	return regex({kind = .Alt, parts = parts[:]})
}

strings_intersect :: proc(a, b: Strings) -> Strings {
	if a.re == nil || b.re == nil do return {}
	if is_all(a) do return b
	if is_all(b) do return a
	parts := make([dynamic]^Regex)
	for x in ([2]^Regex{a.re, b.re}) do for m in members(x, .And) do add_new(&parts, m)
	// Avec un ensemble fini de mots, le résultat est fini : ceux de ses mots que
	// toutes les autres parties reconnaissent.
	for p, i in parts {
		if p.kind != .Words do continue
		others := make([dynamic]Dfa)
		for q, j in parts do if j != i do append(&others, dfa_of(q))
		kept := make([dynamic]string)
		word: for w in p.words {
			for d in others do if !dfa_accepts(d, w) do continue word
			append(&kept, w)
		}
		return strings_of_words(kept[:])
	}
	if len(parts) == 1 do return Strings{parts[0]}
	return regex({kind = .And, parts = parts[:]})
}

// Le complément dans l'ensemble de toutes les chaînes.
strings_complement :: proc(a: Strings) -> Strings {
	if a.re != nil && a.re.kind == .Not do return Strings{a.re.parts[0]}
	inner := make([]^Regex, 1)
	inner[0] = a.re
	return regex({kind = .Not, parts = inner})
}

strings_concat :: proc(a, b: Strings) -> Strings {
	if a.re == nil || b.re == nil do return {}
	parts := make([dynamic]^Regex)
	for x in ([2]^Regex{a.re, b.re}) {
		for m in members(x, .Cat) {
			w, single := single_word(m)
			if single && w == "" do continue
			if single && len(parts) > 0 {
				if prev, prev_single := single_word(parts[len(parts) - 1]); prev_single {
					parts[len(parts) - 1] = strings_point(strings.concatenate({prev, w})).re
					continue
				}
			}
			append(&parts, m)
		}
	}
	switch len(parts) {
	case 0:
		return strings_empty_word()
	case 1:
		return Strings{parts[0]}
	}
	return regex({kind = .Cat, parts = parts[:]})
}

// strings_repeat : L^c pour tout compte c de `counts` (les comptes négatifs
// n'existent pas). `ok` est faux quand un compte fini est trop grand pour être
// construit.
strings_repeat :: proc(a: Strings, counts: Ints) -> (Strings, bool) {
	natural := ints_intersect(counts, ints_range(0, nil))
	for iv in natural.intervals {
		lo, _ := iv.lo.?
		hi, bounded := iv.hi.?
		if lo > MAX_REPEAT || (bounded && hi > MAX_REPEAT) do return {}, false
	}
	if len(natural.intervals) == 0 do return {}, true
	with_zero := ints_contains(natural, 0)
	if a.re == nil do return with_zero ? strings_empty_word() : {}, true // ∅⁰ = {""}
	w, single := single_word(a.re)
	if single && w == "" do return a, true
	if ints_count(natural) == 1 {
		n, _ := ints_default(natural)
		switch {
		case n == 0:
			return strings_empty_word(), true
		case n == 1:
			return a, true
		case single:
			return strings_point(strings.repeat(w, int(n))), true
		}
	}
	inner := make([]^Regex, 1)
	inner[0] = a.re
	return regex({kind = .Repeat, parts = inner, counts = natural}), true
}

// "p".. : commence par un mot de p ; .."s" : finit par un mot de s.
strings_prefixed :: proc(p: Strings) -> Strings {
	return strings_concat(p, strings_all())
}

strings_suffixed :: proc(s: Strings) -> Strings {
	return strings_concat(strings_all(), s)
}

// --- décisions ---

strings_subset :: proc(a, b: Strings) -> bool {
	if a.re == nil || is_all(b) do return true
	if a.re.kind == .Words {
		d := dfa_of(b.re)
		for w in a.re.words do if !dfa_accepts(d, w) do return false
		return true
	}
	return len(dfa_of(strings_intersect(a, strings_complement(b)).re).states) == 0
}

strings_equal :: proc(a, b: Strings) -> bool {
	return strings_subset(a, b) && strings_subset(b, a)
}

strings_contains :: proc(a: Strings, word: string) -> bool {
	if a.re != nil && a.re.kind == .Words do return slice.contains(a.re.words, word)
	return dfa_accepts(dfa_of(a.re), word)
}

// strings_count : le nombre de mots, saturé à 2.
strings_count :: proc(a: Strings) -> int {
	if a.re == nil do return 0
	#partial switch a.re.kind {
	case .Words:
		return min(len(a.re.words), 2)
	case .Class:
		return 2
	}
	return dfa_count(dfa_of(a.re))
}

// strings_default : le plus court mot, et parmi eux le plus petit.
strings_default :: proc(a: Strings) -> (string, bool) {
	if a.re == nil do return "", false
	if a.re.kind == .Words do return a.re.words[0], true
	return dfa_default(dfa_of(a.re))
}

// strings_single : le mot unique d'un langage qui n'en a qu'un.
strings_single :: proc(a: Strings) -> (string, bool) {
	if strings_count(a) != 1 do return "", false
	return strings_default(a)
}

// strings_words : tous les mots d'un langage fini, s'il en a au plus `limit`.
strings_words :: proc(a: Strings, limit: int) -> ([]string, bool) {
	if a.re == nil do return nil, true
	if a.re.kind == .Words do return a.re.words, len(a.re.words) <= limit
	return dfa_words(dfa_of(a.re), limit)
}

// --- les automates : construits pour décider, jamais gardés ---

Edge :: struct {
	using range: Rune_Range,
	to:          int,
}

Dfa_State :: struct {
	accept: bool,
	edges:  []Edge, // triées, disjointes
}

// Un automate déterministe émondé : tout état est accessible depuis l'initial (0)
// et mène à un état acceptant. Sans état, il reconnaît le langage vide.
Dfa :: struct {
	states: []Dfa_State,
}

dfa_of :: proc(re: ^Regex) -> Dfa {
	if re == nil do return {}
	#partial switch re.kind {
	case .And:
		d := dfa_of(re.parts[0])
		for p in re.parts[1:] do d = dfa_intersect(d, dfa_of(p))
		return d
	case .Not:
		return dfa_complement(dfa_of(re.parts[0]))
	}
	n: Nfa
	start, end := fragment(&n, re)
	n.states[end].accept = true
	return determinize(&n, start)
}

Nfa_State :: struct {
	accept: bool,
	edges:  [dynamic]Edge,
	eps:    [dynamic]int,
}

Nfa :: struct {
	states: [dynamic]Nfa_State,
}

nfa_add :: proc(n: ^Nfa) -> int {
	append(&n.states, Nfa_State{})
	return len(n.states) - 1
}

// fragment : ajoute à `n` un morceau qui reconnaît `re`, d'une entrée à une sortie
// (la construction de Thompson). And et Not passent par leur automate déterministe.
fragment :: proc(n: ^Nfa, re: ^Regex) -> (start, end: int) {
	start, end = nfa_add(n), nfa_add(n)
	if re == nil do return
	switch re.kind {
	case .Words:
		for w in re.words {
			cur := start
			for r in w {
				next := nfa_add(n)
				append(&n.states[cur].edges, Edge{{r, r}, next})
				cur = next
			}
			append(&n.states[cur].eps, end)
		}
	case .Class:
		append(&n.states[start].edges, Edge{re.class, end})
	case .Cat:
		cur := start
		for p in re.parts do cur = then(n, cur, p)
		append(&n.states[cur].eps, end)
	case .Alt:
		for p in re.parts {
			s, e := fragment(n, p)
			append(&n.states[start].eps, s)
			append(&n.states[e].eps, end)
		}
	case .Repeat:
		for iv in re.counts.intervals {
			lo, _ := iv.lo.?
			cur := nfa_add(n)
			append(&n.states[start].eps, cur)
			for _ in 0 ..< lo do cur = then(n, cur, re.parts[0])
			if hi, bounded := iv.hi.?; bounded {
				for _ in lo ..< hi {
					append(&n.states[cur].eps, end)
					cur = then(n, cur, re.parts[0])
				}
			} else {
				s, e := fragment(n, re.parts[0])
				append(&n.states[cur].eps, s)
				append(&n.states[e].eps, cur)
			}
			append(&n.states[cur].eps, end)
		}
	case .And, .Not:
		d := dfa_of(re)
		base := len(n.states)
		for s in d.states {
			id := nfa_add(n)
			for e in s.edges do append(&n.states[id].edges, Edge{e.range, base + e.to})
			if s.accept do append(&n.states[id].eps, end)
		}
		if len(d.states) > 0 do append(&n.states[start].eps, base)
	}
	return
}

// then : enchaîne après `cur` un morceau qui reconnaît `re` ; renvoie sa sortie.
then :: proc(n: ^Nfa, cur: int, re: ^Regex) -> int {
	s, e := fragment(n, re)
	append(&n.states[cur].eps, s)
	return e
}

closure :: proc(n: ^Nfa, set: []int) -> []int {
	seen := make(map[int]bool)
	stack := make([dynamic]int)
	for s in set {
		if !seen[s] {
			seen[s] = true
			append(&stack, s)
		}
	}
	for len(stack) > 0 {
		s := pop(&stack)
		for t in n.states[s].eps {
			if !seen[t] {
				seen[t] = true
				append(&stack, t)
			}
		}
	}
	out := make([dynamic]int, 0, len(seen))
	for s in seen do append(&out, s)
	slice.sort(out[:])
	return out[:]
}

// determinize : la construction par sous-ensembles, sur des arêtes étiquetées par
// des plages de caractères découpées en intervalles élémentaires.
determinize :: proc(n: ^Nfa, start: int) -> Dfa {
	raw := make([dynamic]Dfa_State)
	index := make(map[string]int)
	sets := make([dynamic][]int)
	first := closure(n, {start})
	index[fmt.tprint(first)] = 0
	append(&sets, first)
	append(&raw, Dfa_State{})
	for i := 0; i < len(sets); i += 1 {
		set := sets[i]
		accept := false
		bounds := make([dynamic]rune)
		for s in set {
			accept ||= n.states[s].accept
			for e in n.states[s].edges {
				append(&bounds, e.lo)
				if e.hi < MAX_RUNE do append(&bounds, e.hi + 1)
			}
		}
		slice.sort(bounds[:])
		cuts := slice.unique(bounds[:])
		edges := make([dynamic]Edge)
		for b, j in cuts {
			hi := j + 1 < len(cuts) ? cuts[j + 1] - 1 : MAX_RUNE
			targets := make([dynamic]int)
			for s in set {
				for e in n.states[s].edges do if b >= e.lo && b <= e.hi do append(&targets, e.to)
			}
			if len(targets) == 0 do continue
			target := closure(n, targets[:])
			key := fmt.tprint(target)
			id, known := index[key]
			if !known {
				id = len(sets)
				index[key] = id
				append(&sets, target)
				append(&raw, Dfa_State{})
			}
			append(&edges, Edge{{b, hi}, id})
		}
		raw[i] = Dfa_State{accept, edges[:]}
	}
	return trim(raw[:], 0)
}

// trim : garde les états accessibles depuis `start` qui mènent à un état
// acceptant, numérotés dans l'ordre où on les rencontre.
trim :: proc(raw: []Dfa_State, start: int) -> Dfa {
	n := len(raw)
	preds := make([][dynamic]int, n)
	alive := make([]bool, n)
	stack := make([dynamic]int)
	for s, i in raw {
		for e in s.edges do append(&preds[e.to], i)
		if s.accept {
			alive[i] = true
			append(&stack, i)
		}
	}
	for len(stack) > 0 {
		s := pop(&stack)
		for p in preds[s] do if !alive[p] {
			alive[p] = true
			append(&stack, p)
		}
	}
	if n == 0 || !alive[start] do return {}
	order := make(map[int]int)
	queue := make([dynamic]int)
	order[start] = 0
	append(&queue, start)
	for i := 0; i < len(queue); i += 1 {
		for e in raw[queue[i]].edges {
			if !alive[e.to] || e.to in order do continue
			order[e.to] = len(queue)
			append(&queue, e.to)
		}
	}
	states := make([]Dfa_State, len(queue))
	for old, i in queue {
		edges := make([dynamic]Edge, 0, len(raw[old].edges))
		for e in raw[old].edges do if alive[e.to] do append(&edges, Edge{e.range, order[e.to]})
		states[i] = Dfa_State{raw[old].accept, edges[:]}
	}
	return Dfa{states}
}

// dfa_complement : compléter avec un puits, puis inverser l'acceptation.
dfa_complement :: proc(a: Dfa) -> Dfa {
	n := len(a.states)
	raw := make([]Dfa_State, n + 1)
	sink := n
	for s, i in a.states do raw[i] = Dfa_State{!s.accept, fill_gaps(s.edges, sink)}
	raw[sink] = Dfa_State{true, fill_gaps(nil, sink)}
	return trim(raw, n == 0 ? sink : 0)
}

fill_gaps :: proc(edges: []Edge, sink: int) -> []Edge {
	out := make([dynamic]Edge, 0, 2 * len(edges) + 1)
	next := rune(0)
	for e in edges {
		if e.lo > next do append(&out, Edge{{next, e.lo - 1}, sink})
		append(&out, e)
		next = e.hi + 1
	}
	if next <= MAX_RUNE do append(&out, Edge{{next, MAX_RUNE}, sink})
	return out[:]
}

// dfa_intersect : l'automate des paires.
dfa_intersect :: proc(a, b: Dfa) -> Dfa {
	if len(a.states) == 0 || len(b.states) == 0 do return {}
	Pair :: [2]int
	index := make(map[Pair]int)
	pairs := make([dynamic]Pair)
	raw := make([dynamic]Dfa_State)
	index[{0, 0}] = 0
	append(&pairs, Pair{0, 0})
	append(&raw, Dfa_State{})
	for i := 0; i < len(pairs); i += 1 {
		p := pairs[i]
		edges := make([dynamic]Edge)
		for x in a.states[p[0]].edges {
			for y in b.states[p[1]].edges {
				lo, hi := max(x.lo, y.lo), min(x.hi, y.hi)
				if lo > hi do continue
				target := Pair{x.to, y.to}
				id, known := index[target]
				if !known {
					id = len(pairs)
					index[target] = id
					append(&pairs, target)
					append(&raw, Dfa_State{})
				}
				append(&edges, Edge{{lo, hi}, id})
			}
		}
		raw[i] = Dfa_State{a.states[p[0]].accept && b.states[p[1]].accept, edges[:]}
	}
	return trim(raw[:], 0)
}

dfa_accepts :: proc(a: Dfa, word: string) -> bool {
	if len(a.states) == 0 do return false
	cur := 0
	for r in word {
		next := -1
		for e in a.states[cur].edges {
			if r >= e.lo && r <= e.hi {
				next = e.to
				break
			}
		}
		if next < 0 do return false
		cur = next
	}
	return a.states[cur].accept
}

// dfa_count : le nombre de mots, saturé à 2. L'automate est émondé : un cycle
// signifie une infinité de mots.
dfa_count :: proc(a: Dfa) -> int {
	if len(a.states) == 0 do return 0
	memo := make([]int, len(a.states))
	for &m in memo do m = -1
	on_path := make([]bool, len(a.states))
	count :: proc(a: Dfa, s: int, memo: []int, on_path: []bool) -> int {
		if on_path[s] do return 2
		if memo[s] >= 0 do return memo[s]
		on_path[s] = true
		n := a.states[s].accept ? 1 : 0
		for e in a.states[s].edges {
			width := int(e.hi - e.lo) + 1
			n += min(width, 2) * count(a, e.to, memo, on_path)
			if n >= 2 do break
		}
		on_path[s] = false
		memo[s] = min(n, 2)
		return memo[s]
	}
	return count(a, 0, memo, on_path)
}

// dfa_default : à chaque pas, le plus petit caractère qui reste sur un plus court
// chemin vers un état acceptant.
dfa_default :: proc(a: Dfa) -> (string, bool) {
	if len(a.states) == 0 do return "", false
	dist := make([]int, len(a.states))
	for &d in dist do d = max(int)
	for s, i in a.states do if s.accept do dist[i] = 0
	for changed := true; changed; {
		changed = false
		for s, i in a.states {
			for e in s.edges {
				if dist[e.to] != max(int) && dist[e.to] + 1 < dist[i] {
					dist[i] = dist[e.to] + 1
					changed = true
				}
			}
		}
	}
	b := strings.builder_make()
	cur := 0
	for !a.states[cur].accept {
		for e in a.states[cur].edges {
			if dist[e.to] == dist[cur] - 1 {
				strings.write_rune(&b, e.lo)
				cur = e.to
				break
			}
		}
	}
	return strings.to_string(b), true
}

dfa_words :: proc(a: Dfa, limit: int) -> ([]string, bool) {
	out := make([dynamic]string)
	if len(a.states) == 0 do return out[:], true
	walk :: proc(a: Dfa, s: int, prefix: ^strings.Builder, out: ^[dynamic]string, limit, depth: int) -> bool {
		if depth > len(a.states) do return false // un cycle : infini
		if a.states[s].accept {
			if len(out) >= limit do return false
			append(out, strings.clone(strings.to_string(prefix^)))
		}
		for e in a.states[s].edges {
			if int(e.hi - e.lo) >= limit do return false
			for r := e.lo; r <= e.hi; r += 1 {
				mark := strings.builder_len(prefix^)
				strings.write_rune(prefix, r)
				if !walk(a, e.to, prefix, out, limit, depth + 1) do return false
				resize(&prefix.buf, mark)
			}
		}
		return true
	}
	b := strings.builder_make()
	if !walk(a, 0, &b, &out, limit, 0) do return nil, false
	slice.sort_by(out[:], shortlex)
	return out[:], true
}
