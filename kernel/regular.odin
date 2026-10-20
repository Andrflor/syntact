package kernel

import "base:runtime"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:unicode/utf8"

// SETS OF STRINGS: regular languages, kept as the expression that writes them, in
// similarity form (Owens, Reppy, Turon, "Regular-expression derivatives
// re-examined", def. 4.1) and shared: two similar writings are the same node. The
// form is not unique — two equivalent but dissimilar writings remain two nodes —
// and does not have to be: inclusion is decided on demand, by Brzozowski
// derivatives, without an automaton.
//
//   "a" | "ab"        Words    a finite set of words ({""} is ε)
//   'a'..'z'          Class    a one-letter word in the range
//   x + y             Cat      right-associated: [head, rest]
//   x | y             Alt      flattened, sorted, without duplicates
//   x & y             And      flattened, sorted, without duplicates
//   ~x                Not      ~∅: any string
//   x * 2..4          Repeat   by a set of natural counts

MAX_RUNE :: rune(0x10FFFF)

// Beyond this, a repetition is not built: each derivative keeps the remaining
// count, there would be as many of them as repetitions.
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
	words:  []string, // Words: non-empty, without duplicates, from shortest to longest then in order
	class:  Rune_Range, // Class: at least two characters (a single one is a word)
	parts:  []^Regex, // Cat: [head, rest]; Alt, And: at least two, sorted by id; Not, Repeat: [r]
	counts: Ints, // Repeat: naturals, neither {0} nor {1}; 0..max if r accepts ""
	id:     int, // the creation order: it sorts the operands of | and &
}

Strings :: struct {
	re: ^Regex, // nil: the empty language
}

Rune_Range :: struct {
	lo, hi: rune, // inclusive
}

// --- sharing ---

// The node table, per thread. Nodes are immutable and live as long as the
// program: they are allocated outside the passes' arenas.
@(thread_local)
regex_nodes: map[string]^Regex

// intern: the shared node of this structure.
intern :: proc(r: Regex) -> ^Regex {
	key := regex_key(r)
	if n, ok := regex_nodes[key]; ok do return n
	context.allocator = runtime.heap_allocator()
	n := new(Regex)
	n^ = r
	n.words = slice.clone(r.words)
	for &w in n.words do w = strings.clone(w)
	n.parts = slice.clone(r.parts)
	n.counts = Ints{slice.clone(r.counts.intervals)}
	n.id = len(regex_nodes)
	regex_nodes[strings.clone(key)] = n
	return n
}

// regex_key: the structure of a node, its operands by id.
regex_key :: proc(r: Regex) -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "%v %d %d", r.kind, r.class.lo, r.class.hi)
	for w in r.words do fmt.sbprintf(&b, " %d:%s", len(w), w)
	for p in r.parts do fmt.sbprintf(&b, " #%d", p == nil ? -1 : p.id)
	for iv in r.counts.intervals do fmt.sbprintf(&b, " %v..%v", iv.lo, iv.hi)
	return strings.to_string(b)
}

// --- constructions: similarity, and only similarity ---

strings_point :: proc(word: string) -> Strings {
	return strings_of_words({word})
}

strings_empty_word :: proc() -> Strings {
	return strings_point("")
}

// strings_of_words: the finite language of these words.
strings_of_words :: proc(words: []string) -> Strings {
	if len(words) == 0 do return {}
	sorted := slice.clone(words, context.temp_allocator)
	slice.sort_by(sorted, shortlex)
	return Strings{intern({kind = .Words, words = slice.unique(sorted)})}
}

// shortlex: the shortest first, then code point order.
shortlex :: proc(a, b: string) -> bool {
	la, lb := strings.rune_count(a), strings.rune_count(b)
	return la != lb ? la < lb : a < b
}

// strings_runes: the one-character words within [lo, hi].
strings_runes :: proc(lo, hi: rune) -> Strings {
	if lo == hi do return strings_point(fmt.tprintf("%c", lo))
	return Strings{intern({kind = .Class, class = {min(lo, hi), max(lo, hi)}})}
}

strings_all :: proc() -> Strings {
	return strings_complement({})
}

is_all :: proc(r: ^Regex) -> bool {
	return r != nil && r.kind == .Not && r.parts[0] == nil
}

is_epsilon :: proc(r: ^Regex) -> bool {
	w, single := single_word(r)
	return single && w == ""
}

single_word :: proc(r: ^Regex) -> (string, bool) {
	if r != nil && r.kind == .Words && len(r.words) == 1 do return r.words[0], true
	return "", false
}

// members: the operands of a flattened operation — those of `r` if it is one of
// the same kind, otherwise `r` itself.
members :: proc(r: ^Regex, kind: Regex_Kind) -> []^Regex {
	if r.kind == kind do return r.parts
	one := make([]^Regex, 1, context.temp_allocator)
	one[0] = r
	return one
}

// operation: `|` or `&` over operands sorted by id and without duplicates.
operation :: proc(kind: Regex_Kind, parts: []^Regex) -> ^Regex {
	slice.sort_by(parts, proc(a, b: ^Regex) -> bool {return a.id < b.id})
	unique := slice.unique(parts)
	if len(unique) == 1 do return unique[0]
	return intern({kind = kind, parts = unique})
}

strings_union :: proc(a, b: Strings) -> Strings {
	return Strings{regex_or(a.re, b.re)}
}

regex_or :: proc(a, b: ^Regex) -> ^Regex {
	if a == nil do return b
	if b == nil do return a
	if is_all(a) || is_all(b) do return a if is_all(a) else b
	words := make([dynamic]string, context.temp_allocator)
	parts := make([dynamic]^Regex, context.temp_allocator)
	for x in ([2]^Regex{a, b}) {
		for m in members(x, .Alt) {
			if m.kind == .Words do append(&words, ..m.words)
			else do append(&parts, m)
		}
	}
	if len(words) > 0 do append(&parts, strings_of_words(words[:]).re)
	return operation(.Alt, parts[:])
}

strings_intersect :: proc(a, b: Strings) -> Strings {
	return Strings{regex_and(a.re, b.re)}
}

regex_and :: proc(a, b: ^Regex) -> ^Regex {
	if a == nil || b == nil do return nil
	if is_all(a) do return b
	if is_all(b) do return a
	parts := make([dynamic]^Regex, context.temp_allocator)
	for x in ([2]^Regex{a, b}) do append(&parts, ..members(x, .And))
	// With a finite set of words, the result is finite: those of its words that
	// all the other parts recognize.
	for p, i in parts {
		if p.kind != .Words do continue
		kept := make([dynamic]string, context.temp_allocator)
		word: for w in p.words {
			for q, j in parts do if j != i && !regex_contains(q, w) do continue word
			append(&kept, w)
		}
		return strings_of_words(kept[:]).re
	}
	return operation(.And, parts[:])
}

// The complement within the set of all strings.
strings_complement :: proc(a: Strings) -> Strings {
	return Strings{regex_not(a.re)}
}

regex_not :: proc(a: ^Regex) -> ^Regex {
	if a != nil && a.kind == .Not do return a.parts[0]
	return intern({kind = .Not, parts = []^Regex{a}})
}

strings_concat :: proc(a, b: Strings) -> Strings {
	return Strings{regex_cat(a.re, b.re)}
}

regex_cat :: proc(a, b: ^Regex) -> ^Regex {
	if a == nil || b == nil do return nil
	if is_epsilon(a) do return b
	if is_epsilon(b) do return a
	if a.kind == .Cat do return regex_cat(a.parts[0], regex_cat(a.parts[1], b)) // to the right
	if w, single := single_word(a); single {
		if v, also := single_word(b); also do return strings_point(strings.concatenate({w, v}, context.temp_allocator)).re
		if b.kind == .Cat {
			if v, head := single_word(b.parts[0]); head {
				return regex_cat(strings_point(strings.concatenate({w, v}, context.temp_allocator)).re, b.parts[1])
			}
		}
	}
	return intern({kind = .Cat, parts = []^Regex{a, b}})
}

// strings_repeat: L^c for every count c of `counts` (negative counts do not
// exist). `ok` is false when a finite count is too large.
strings_repeat :: proc(a: Strings, counts: Ints) -> (Strings, bool) {
	natural := ints_intersect(counts, ints_range(0, nil))
	for iv in natural.intervals {
		lo, _ := iv.lo.?
		hi, bounded := iv.hi.?
		if lo > MAX_REPEAT || (bounded && hi > MAX_REPEAT) do return {}, false
	}
	return Strings{regex_repeat(a.re, natural)}, true
}

regex_repeat :: proc(r: ^Regex, natural: Ints) -> ^Regex {
	counts := natural
	if len(counts.intervals) == 0 do return nil
	epsilon := strings_empty_word().re
	if r == nil do return epsilon if ints_contains(counts, 0) else nil // ∅⁰ = {""}
	if is_epsilon(r) do return epsilon
	if regex_nullable(r) {
		// "" ∈ r: r^c contains r^d for every d ≤ c, so r^C = r^(0..max C)
		_, top := ints_bounds(counts)
		counts = ints_range(0, top)
	}
	if ints_count(counts) == 1 {
		n, _ := ints_default(counts)
		switch {
		case n == 0:
			return epsilon
		case n == 1:
			return r
		}
		if w, single := single_word(r); single do return strings_point(strings.repeat(w, int(n), context.temp_allocator)).re
	}
	return intern({kind = .Repeat, parts = []^Regex{r}, counts = counts})
}

// "p"..: starts with a word of p; .."s": ends with a word of s.
strings_prefixed :: proc(p: Strings) -> Strings {
	return strings_concat(p, strings_all())
}

strings_suffixed :: proc(s: Strings) -> Strings {
	return strings_concat(strings_all(), s)
}

// --- derivatives ---

regex_nullable :: proc(r: ^Regex) -> bool {
	if r == nil do return false
	switch r.kind {
	case .Words:
		return r.words[0] == ""
	case .Class:
		return false
	case .Cat, .And:
		for p in r.parts do if !regex_nullable(p) do return false
		return true
	case .Alt:
		for p in r.parts do if regex_nullable(p) do return true
		return false
	case .Not:
		return !regex_nullable(r.parts[0])
	case .Repeat:
		return ints_contains(r.counts, 0)
	}
	return false
}

// derive: the suffixes of the words of r that start with c (Brzozowski).
derive :: proc(r: ^Regex, c: rune) -> ^Regex {
	if r == nil do return nil
	switch r.kind {
	case .Words:
		suffixes := make([dynamic]string, context.temp_allocator)
		for w in r.words {
			head, size := utf8.decode_rune(w)
			if w != "" && head == c do append(&suffixes, w[size:])
		}
		return strings_of_words(suffixes[:]).re
	case .Class:
		return c >= r.class.lo && c <= r.class.hi ? strings_empty_word().re : nil
	case .Cat:
		d := regex_cat(derive(r.parts[0], c), r.parts[1])
		return regex_or(d, derive(r.parts[1], c)) if regex_nullable(r.parts[0]) else d
	case .Alt:
		d: ^Regex = nil
		for p in r.parts do d = regex_or(d, derive(p, c))
		return d
	case .And:
		d := derive(r.parts[0], c)
		for p in r.parts[1:] do d = regex_and(d, derive(p, c))
		return d
	case .Not:
		return regex_not(derive(r.parts[0], c))
	case .Repeat:
		// the first piece, then the others: r^C gives ∂r · r^(C-1)
		return regex_cat(derive(r.parts[0], c), regex_repeat(r.parts[0], counts_minus_one(r.counts)))
	}
	return nil
}

// counts_minus_one: { c - 1 | c ∈ C, c ≥ 1 }.
counts_minus_one :: proc(counts: Ints) -> Ints {
	out := make([dynamic]Int_Interval, context.temp_allocator)
	for iv in counts.intervals {
		lo, _ := iv.lo.?
		shifted := Int_Interval{max(lo - 1, 0), iv.hi}
		if hi, bounded := iv.hi.?; bounded {
			if hi == 0 do continue
			shifted.hi = hi - 1
		}
		append(&out, shifted)
	}
	return ints_of(out[:])
}

// cuts: the bounds of the alphabet where the derivative can change (the
// derivative classes of Owens et al., §4.2, over-approximated): one derivative
// per range suffices.
cuts :: proc(r: ^Regex, out: ^[dynamic]rune) {
	if r == nil do return
	switch r.kind {
	case .Words:
		for w in r.words {
			if w == "" do continue
			head, _ := utf8.decode_rune(w)
			append(out, head, head + 1)
		}
	case .Class:
		append(out, r.class.lo, r.class.hi + 1)
	case .Cat:
		cuts(r.parts[0], out)
		if regex_nullable(r.parts[0]) do cuts(r.parts[1], out)
	case .Alt, .And, .Not, .Repeat:
		for p in r.parts do cuts(p, out)
	}
}

// classes: the ranges of the alphabet over which the derivative of r is the same,
// in order; each is represented by its smallest character.
classes :: proc(r: ^Regex) -> []Rune_Range {
	bounds := make([dynamic]rune, context.temp_allocator)
	append(&bounds, 0)
	cuts(r, &bounds)
	slice.sort(bounds[:])
	unique := slice.unique(bounds[:])
	out := make([dynamic]Rune_Range, 0, len(unique), context.temp_allocator)
	for b, i in unique {
		if b > MAX_RUNE do break
		hi := i + 1 < len(unique) ? min(unique[i + 1] - 1, MAX_RUNE) : MAX_RUNE
		append(&out, Rune_Range{b, hi})
	}
	return out[:]
}

regex_contains :: proc(r: ^Regex, word: string) -> bool {
	cur := r
	for c in word {
		cur = derive(cur, c)
		if cur == nil do return false
	}
	return regex_nullable(cur)
}

// witness: the smallest word of r — the shortest, then the first in code point
// order —, if there is one. A breadth-first traversal of the derivatives,
// compared by address; it terminates because an expression has only a finite
// number of dissimilar derivatives (Brzozowski).
witness :: proc(r: ^Regex) -> (string, bool) {
	Visit :: struct {
		re:   ^Regex,
		word: string,
	}
	if r == nil do return "", false
	seen := make(map[^Regex]bool, allocator = context.temp_allocator)
	queue := make([dynamic]Visit, context.temp_allocator)
	append(&queue, Visit{r, ""})
	seen[r] = true
	for i := 0; i < len(queue); i += 1 {
		v := queue[i]
		if regex_nullable(v.re) do return strings.clone(v.word), true
		for class in classes(v.re) {
			d := derive(v.re, class.lo)
			if d == nil || seen[d] do continue
			seen[d] = true
			append(&queue, Visit{d, fmt.tprintf("%s%c", v.word, class.lo)})
		}
	}
	return "", false
}

// --- decisions, memoized per node: nodes are shared and immutable ---

@(thread_local)
subset_memo: map[[2]int]bool

@(thread_local)
count_memo: map[int]int

strings_subset :: proc(a, b: Strings) -> bool {
	if a.re == nil || is_all(b.re) do return true
	if a.re.kind == .Words {
		for w in a.re.words do if !regex_contains(b.re, w) do return false
		return true
	}
	key := [2]int{a.re.id, b.re == nil ? -1 : b.re.id}
	if known, ok := subset_memo[key]; ok do return known
	_, found := witness(regex_and(a.re, regex_not(b.re)))
	context.allocator = runtime.heap_allocator()
	subset_memo[key] = !found
	return !found
}

strings_equal :: proc(a, b: Strings) -> bool {
	return strings_subset(a, b) && strings_subset(b, a)
}

strings_contains :: proc(a: Strings, word: string) -> bool {
	return regex_contains(a.re, word)
}

// strings_count: the number of words, saturated at 2 — two witness searches.
strings_count :: proc(a: Strings) -> int {
	if a.re == nil do return 0
	#partial switch a.re.kind {
	case .Words:
		return min(len(a.re.words), 2)
	case .Class:
		return 2
	}
	if known, ok := count_memo[a.re.id]; ok do return known
	n := 0
	if w, found := witness(a.re); found {
		_, other := witness(regex_and(a.re, regex_not(strings_point(w).re)))
		n = other ? 2 : 1
	}
	context.allocator = runtime.heap_allocator()
	count_memo[a.re.id] = n
	return n
}

// strings_default: the smallest word.
strings_default :: proc(a: Strings) -> (string, bool) {
	if a.re != nil && a.re.kind == .Words do return a.re.words[0], true
	return witness(a.re)
}

// strings_single: the unique word of a language that has only one.
strings_single :: proc(a: Strings) -> (string, bool) {
	if strings_count(a) != 1 do return "", false
	return strings_default(a)
}

// strings_words: all the words of a finite language, if it has at most `limit` of
// them — through the derivative automaton, trimmed.
strings_words :: proc(a: Strings, limit: int) -> ([]string, bool) {
	if a.re == nil do return nil, true
	if a.re.kind == .Words do return a.re.words, len(a.re.words) <= limit
	return dfa_words(derivative_dfa(a.re), limit)
}

// --- the derivative automaton: only for enumerating ---

Edge :: struct {
	using range: Rune_Range,
	to:          int,
}

Dfa_State :: struct {
	accept: bool,
	edges:  []Edge, // sorted, disjoint
}

// A trimmed deterministic automaton: every state is reachable from the initial
// one (0) and leads to an accepting state.
Dfa :: struct {
	states: []Dfa_State,
}

// derivative_dfa: the states are the derivatives of r, the edges its classes
// (Owens et al., fig. 1).
derivative_dfa :: proc(r: ^Regex) -> Dfa {
	index := make(map[^Regex]int, allocator = context.temp_allocator)
	order := make([dynamic]^Regex, context.temp_allocator)
	raw := make([dynamic]Dfa_State)
	index[r] = 0
	append(&order, r)
	for i := 0; i < len(order); i += 1 {
		q := order[i]
		edges := make([dynamic]Edge)
		for class in classes(q) {
			d := derive(q, class.lo)
			if d == nil do continue
			id, known := index[d]
			if !known {
				id = len(order)
				index[d] = id
				append(&order, d)
			}
			append(&edges, Edge{class, id})
		}
		append(&raw, Dfa_State{regex_nullable(q), edges[:]})
	}
	return trim(raw[:], 0)
}

// trim: keeps the states reachable from `start` that lead to an accepting state,
// numbered in the order they are met.
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

dfa_words :: proc(a: Dfa, limit: int) -> ([]string, bool) {
	out := make([dynamic]string)
	if len(a.states) == 0 do return out[:], true
	walk :: proc(a: Dfa, s: int, prefix: ^strings.Builder, out: ^[dynamic]string, limit, depth: int) -> bool {
		if depth > len(a.states) do return false // a cycle: infinite
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
