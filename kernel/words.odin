package kernel

import "core:fmt"
import "core:slice"
import "core:strings"

// SETS OF STRINGS (specs/types.md §4.3, §4.6)
//
// A set of strings is a regular language, kept as the expression that writes it.
// A character is a string of length 1: a class of code points. The constructors
// apply the laws of the algebra (| & ~ of a Boolean algebra, + associative with ""
// neutral, the repetition laws of §4.6), and similar expressions are the same node
// (Owens, Reppy, Turon). Emptiness, inclusion and membership are decided by
// Brzozowski derivatives: a regular expression has finitely many of them.

MAX_RUNE :: 0x10FFFF

Words_Kind :: enum u8 {
	Empty, // no string
	Epsilon, // ""
	Class, // one character, among `class`
	Cat, // [a, b]: a then b, associated to the right
	Alt, // a | b | …: flattened, sorted by id, without duplicates
	And, // a & b & …: likewise
	Not, // [a]: every string but those of a
	Repeat, // [a]: a repeated a number of times taken in `counts`
}

Words :: struct {
	kind:     Words_Kind,
	class:    Ints, // Class: code points in 0..MAX_RUNE
	args:     []^Words,
	counts:   Ints, // Repeat: integers ≥ 0
	id:       int,
	nullable: bool, // "" is in it
}

// The nodes of the current run: similar expressions are one node, compared by
// address. words_reset starts a new table, in the current allocator.
@(thread_local)
words_table: map[string]^Words
@(thread_local)
derivatives: map[[2]int]^Words

words_reset :: proc() {
	words_table = make(map[string]^Words)
	derivatives = make(map[[2]int]^Words)
}

@(private = "file")
intern :: proc(w: Words) -> ^Words {
	b := strings.builder_make(context.temp_allocator)
	strings.write_int(&b, int(w.kind))
	for r in w.class.ranges do write_range(&b, r)
	strings.write_byte(&b, '|')
	for a in w.args {
		strings.write_int(&b, a.id)
		strings.write_byte(&b, ',')
	}
	strings.write_byte(&b, '|')
	for r in w.counts.ranges do write_range(&b, r)
	key := strings.to_string(b)
	if found, ok := words_table[key]; ok do return found
	n := new(Words)
	n^ = w
	n.args = slice.clone(w.args) // the arguments are often a literal on the stack
	n.id = len(words_table)
	words_table[strings.clone(key)] = n
	return n
}

@(private = "file")
write_range :: proc(b: ^strings.Builder, r: Int_Range) {
	if lo, ok := r.lo.?; ok do strings.write_string(b, fmt.tprint(lo))
	strings.write_byte(b, ':')
	if hi, ok := r.hi.?; ok do strings.write_string(b, fmt.tprint(hi))
	strings.write_byte(b, ';')
}

words_empty :: proc() -> ^Words {
	return intern(Words{kind = .Empty})
}

words_epsilon :: proc() -> ^Words {
	return intern(Words{kind = .Epsilon, nullable = true})
}

// words_class: one character among the code points of `points`.
words_class :: proc(points: Ints) -> ^Words {
	class := ints_intersect(points, ints_between(0, MAX_RUNE))
	if ints_empty(class) do return words_empty()
	return intern(Words{kind = .Class, class = class})
}

words_char :: proc(c: rune) -> ^Words {
	return words_class(ints_point(i128(c)))
}

// words_chars: every character.
words_chars :: proc() -> ^Words {
	return words_class(ints_between(0, MAX_RUNE))
}

// words_all: every string.
words_all :: proc() -> ^Words {
	return words_not(words_empty())
}

words_literal :: proc(s: string) -> ^Words {
	w := words_epsilon()
	runes := utf8_runes(s)
	#reverse for c in runes do w = words_cat(words_char(c), w)
	return w
}

utf8_runes :: proc(s: string) -> []rune {
	out := make([dynamic]rune, 0, len(s))
	for c in s do append(&out, c)
	return out[:]
}

// words_cat: a then b. ∅ is absorbing, "" neutral, + associative (§4.6).
words_cat :: proc(a, b: ^Words) -> ^Words {
	if a.kind == .Empty || b.kind == .Empty do return words_empty()
	if a.kind == .Epsilon do return b
	if b.kind == .Epsilon do return a
	if a.kind == .Cat do return words_cat(a.args[0], words_cat(a.args[1], b))
	return intern(Words{kind = .Cat, args = {a, b}, nullable = a.nullable && b.nullable})
}

words_alt :: proc(a, b: ^Words) -> ^Words {
	return words_combine(.Alt, {a, b})
}

words_and :: proc(a, b: ^Words) -> ^Words {
	return words_combine(.And, {a, b})
}

// words_combine: | or & of several sets, by the laws of a Boolean algebra
// (§4.1): flattened, sorted, without duplicates; the classes are merged; ∅ and
// every string are neutral or absorbing.
words_combine :: proc(kind: Words_Kind, parts: []^Words) -> ^Words {
	is_or := kind == .Alt
	neutral := is_or ? words_empty() : words_all()
	absorbing := is_or ? words_all() : words_empty()
	flat := make([dynamic]^Words)
	class: Maybe(Ints)
	stack := make([dynamic]^Words)
	append(&stack, ..parts)
	for len(stack) > 0 {
		p := pop(&stack)
		switch {
		case p == absorbing:
			return absorbing
		case p == neutral:
		case p.kind == kind:
			append(&stack, ..p.args)
		case p.kind == .Class:
			if c, ok := class.?; ok {
				class = is_or ? ints_union(c, p.class) : ints_intersect(c, p.class)
			} else {
				class = p.class
			}
		case:
			append(&flat, p)
		}
	}
	if c, ok := class.?; ok {
		w := words_class(c)
		if w == absorbing do return absorbing
		if w != neutral do append(&flat, w)
	}
	slice.sort_by(flat[:], proc(x, y: ^Words) -> bool {return x.id < y.id})
	unique := slice.unique(flat[:])
	switch len(unique) {
	case 0:
		return neutral
	case 1:
		return unique[0]
	}
	nullable := !is_or
	for u in unique do nullable = is_or ? nullable || u.nullable : nullable && u.nullable
	return intern(Words{kind = kind, args = unique, nullable = nullable})
}

words_not :: proc(a: ^Words) -> ^Words {
	if a.kind == .Not do return a.args[0]
	return intern(Words{kind = .Not, args = {a}, nullable = !a.nullable})
}

// words_repeat: a repeated n times, n in `counts` (§4.6). t * 0 = "",
// t * 1 = t. When "" is in a, a * n contains every a * m for m ≤ n: the counts
// close downward, which keeps the derivative rule exact.
words_repeat :: proc(a: ^Words, counts: Ints) -> ^Words {
	c := ints_intersect(counts, ints_between(0, nil))
	if ints_empty(c) do return words_empty()
	has_zero := ints_contains(c, 0)
	if a.kind == .Empty do return has_zero ? words_epsilon() : words_empty()
	if a.kind == .Epsilon do return words_epsilon()
	if a.nullable do c = ints_between(0, ints_max(c))
	if n, single := ints_single(c); single {
		if n == 0 do return words_epsilon()
		if n == 1 do return a
		if _, literal := words_single_word(a); literal && n <= 64 do return words_cat(a, words_repeat(a, ints_point(n - 1)))
	}
	return intern(Words{kind = .Repeat, args = {a}, counts = c, nullable = ints_contains(c, 0)})
}

// words_derive: the strings w such that c·w is in a (Brzozowski).
words_derive :: proc(a: ^Words, c: rune) -> ^Words {
	key := [2]int{a.id, int(c)}
	if d, ok := derivatives[key]; ok do return d
	d: ^Words
	switch a.kind {
	case .Empty, .Epsilon:
		d = words_empty()
	case .Class:
		d = ints_contains(a.class, i128(c)) ? words_epsilon() : words_empty()
	case .Cat:
		d = words_cat(words_derive(a.args[0], c), a.args[1])
		if a.args[0].nullable do d = words_alt(d, words_derive(a.args[1], c))
	case .Alt, .And:
		parts := make([]^Words, len(a.args))
		for x, i in a.args do parts[i] = words_derive(x, c)
		d = words_combine(a.kind, parts)
	case .Not:
		d = words_not(words_derive(a.args[0], c))
	case .Repeat:
		rest := ints_add(ints_intersect(a.counts, ints_between(1, nil)), ints_point(-1))
		d = words_cat(words_derive(a.args[0], c), words_repeat(a.args[0], rest))
	}
	derivatives[key] = d
	return d
}

// words_cuts: code points where the derivative may change: the bounds of every
// class in a. Between two cuts, every character derives a the same way.
@(private = "file")
words_cuts :: proc(a: ^Words) -> []rune {
	points := make(map[rune]bool)
	points[0] = true
	seen := make(map[int]bool)
	stack := make([dynamic]^Words)
	append(&stack, a)
	for len(stack) > 0 {
		w := pop(&stack)
		if seen[w.id] do continue
		seen[w.id] = true
		for r in w.class.ranges {
			lo, _ := r.lo.?
			hi, _ := r.hi.?
			points[rune(lo)] = true
			if hi < MAX_RUNE do points[rune(hi + 1)] = true
		}
		append(&stack, ..w.args)
	}
	out := make([dynamic]rune, 0, len(points))
	for p in points do append(&out, p)
	slice.sort(out[:])
	return out[:]
}

// words_witness: the shortest string of a, the first in code point order.
words_witness :: proc(a: ^Words) -> (string, bool) {
	Step :: struct {
		state: ^Words,
		from:  int, // the previous step, -1 for the start
		c:     rune,
	}
	cuts := words_cuts(a)
	steps := make([dynamic]Step)
	append(&steps, Step{a, -1, 0})
	seen := make(map[int]bool)
	seen[a.id] = true
	for i := 0; i < len(steps); i += 1 {
		s := steps[i]
		if s.state.nullable {
			runes := make([dynamic]rune)
			for j := i; steps[j].from >= 0; j = steps[j].from do append(&runes, steps[j].c)
			slice.reverse(runes[:])
			return runes_string(runes[:]), true
		}
		for c in cuts {
			d := words_derive(s.state, c)
			if d.kind == .Empty || seen[d.id] do continue
			seen[d.id] = true
			append(&steps, Step{d, i, c})
		}
	}
	return "", false
}

runes_string :: proc(runes: []rune) -> string {
	b := strings.builder_make()
	for c in runes do strings.write_rune(&b, c)
	return strings.to_string(b)
}

words_is_empty :: proc(a: ^Words) -> bool {
	if a.kind == .Empty do return true
	_, found := words_witness(a)
	return !found
}

words_subset :: proc(a, b: ^Words) -> bool {
	return a == b || words_is_empty(words_and(a, words_not(b)))
}

words_equal :: proc(a, b: ^Words) -> bool {
	return a == b || (words_subset(a, b) && words_subset(b, a))
}

words_contains :: proc(a: ^Words, s: string) -> bool {
	w := a
	for c in s do w = words_derive(w, c)
	return w.nullable
}

// words_single: the only string of a, when there is exactly one.
words_single :: proc(a: ^Words) -> (string, bool) {
	s, found := words_witness(a)
	if !found do return "", false
	return s, words_is_empty(words_and(a, words_not(words_literal(s))))
}

// words_single_word: a, when it is one fixed string, written as one: a chain of
// single characters.
words_single_word :: proc(a: ^Words) -> (string, bool) {
	runes := make([dynamic]rune)
	x := a
	for {
		#partial switch x.kind {
		case .Epsilon:
			return runes_string(runes[:]), true
		case .Class:
			c, single := ints_single(x.class)
			if !single do return "", false
			append(&runes, rune(c))
			return runes_string(runes[:]), true
		case .Cat:
			if x.args[0].kind != .Class do return "", false
			c, single := ints_single(x.args[0].class)
			if !single do return "", false
			append(&runes, rune(c))
			x = x.args[1]
		case:
			return "", false
		}
	}
}

// words_char_bounds: the smallest and largest code point of a set of characters.
words_char_bounds :: proc(a: ^Words) -> (lo, hi: i128, ok: bool) {
	if a.kind != .Class do return 0, 0, false
	l, _ := ints_min(a.class).?
	h, _ := ints_max(a.class).?
	return l, h, true
}
