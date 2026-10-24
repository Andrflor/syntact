package kernel

import "core:fmt"
import "core:slice"
import "core:strings"

// WORDS
//
// The strings of a constant type, read as a regular language: what the laws of
// | & ~, + and * on strings (§4.1, §4.6) compute on, to decide whether a set of
// strings is empty or in another (set.odin). A character is a word of length 1.
// Similar expressions are one node (Owens, Reppy, Turon); emptiness and membership
// are decided by Brzozowski derivatives, of which a regular expression has finitely
// many. Words are never a type: a type is a term of type.odin.

MAX_RUNE :: 0x10FFFF

Words_Kind :: enum u8 {
	Empty, // no word
	Epsilon, // ""
	Class, // one character among `class`
	Cat, // [a, b]: a then b
	Alt, // a | b | …
	And, // a & b & …
	Not, // every word but those of a
	Repeat, // a repeated n times, n in `counts`
}

Words :: struct {
	kind:     Words_Kind,
	class:    Ints, // Class: code points
	args:     []^Words,
	counts:   Ints, // Repeat: integers ≥ 0
	id:       int,
	nullable: bool, // "" is in it
}

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
	fmt.sbprintf(&b, "%d|", int(w.kind))
	for r in w.class do fmt.sbprintf(&b, "%v:%v;", r.lo, r.hi)
	strings.write_byte(&b, '|')
	for a in w.args do fmt.sbprintf(&b, "%d,", a.id)
	strings.write_byte(&b, '|')
	for r in w.counts do fmt.sbprintf(&b, "%v:%v;", r.lo, r.hi)
	key := strings.to_string(b)
	if found, ok := words_table[key]; ok do return found
	n := new(Words)
	n^ = w
	n.args = slice.clone(w.args)
	n.class = slice.clone(w.class)
	n.counts = slice.clone(w.counts)
	n.id = len(words_table)
	words_table[strings.clone(key)] = n
	return n
}

words_empty :: proc() -> ^Words {return intern(Words{kind = .Empty})}
words_epsilon :: proc() -> ^Words {return intern(Words{kind = .Epsilon, nullable = true})}
words_all :: proc() -> ^Words {return words_not(words_empty())}
words_chars :: proc() -> ^Words {return words_class({{0, MAX_RUNE}})}

words_class :: proc(points: Ints) -> ^Words {
	class := ints_intersect(points, {{0, MAX_RUNE}})
	if len(class) == 0 do return words_empty()
	return intern(Words{kind = .Class, class = class})
}

words_char :: proc(c: rune) -> ^Words {
	return words_class({{i128(c), i128(c)}})
}

words_cat :: proc(a, b: ^Words) -> ^Words {
	if a.kind == .Empty || b.kind == .Empty do return words_empty()
	if a.kind == .Epsilon do return b
	if b.kind == .Epsilon do return a
	if a.kind == .Cat do return words_cat(a.args[0], words_cat(a.args[1], b))
	return intern(Words{kind = .Cat, args = {a, b}, nullable = a.nullable && b.nullable})
}

words_alt :: proc(a, b: ^Words) -> ^Words {return words_combine(.Alt, {a, b})}
words_and :: proc(a, b: ^Words) -> ^Words {return words_combine(.And, {a, b})}

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

// words_repeat: a * counts (§4.6): t * 0 = "", t * 1 = t. When "" is in a, the
// counts close downward, which keeps the derivative exact.
words_repeat :: proc(a: ^Words, counts: Ints) -> ^Words {
	c := ints_intersect(counts, {{0, nil}})
	if len(c) == 0 do return words_empty()
	if a.kind == .Empty do return ints_contains(c, 0) ? words_epsilon() : words_empty()
	if a.kind == .Epsilon do return words_epsilon()
	if a.nullable do c = {{0, c[len(c) - 1].hi}}
	if n, single := ints_single(c); single {
		if n == 0 do return words_epsilon()
		if n == 1 do return a
	}
	return intern(Words{kind = .Repeat, args = {a}, counts = c, nullable = ints_contains(c, 0)})
}

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
		rest := ints_add(ints_intersect(a.counts, {{1, nil}}), {{-1, -1}})
		d = words_cat(words_derive(a.args[0], c), words_repeat(a.args[0], rest))
	}
	derivatives[key] = d
	return d
}

// words_cuts: the code points where a derivative may change: the bounds of the
// classes in a.
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
		for r in w.class {
			lo, _ := r.lo.?
			hi, _ := r.hi.?
			points[rune(lo)] = true
			if hi < MAX_RUNE do points[rune(hi + 1)] = true
		}
		append(&stack, ..w.args)
	}
	out := make([dynamic]rune)
	for p in points do append(&out, p)
	slice.sort(out[:])
	return out[:]
}

// words_witness: the shortest word of a, the first in code point order.
words_witness :: proc(a: ^Words) -> (string, bool) {
	Step :: struct {
		state: ^Words,
		from:  int,
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
			b := strings.builder_make()
			for c in runes do strings.write_rune(&b, c)
			return strings.to_string(b), true
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

words_is_empty :: proc(a: ^Words) -> bool {
	if a.kind == .Empty do return true
	_, found := words_witness(a)
	return !found
}

words_subset :: proc(a, b: ^Words) -> bool {
	return a == b || words_is_empty(words_and(a, words_not(b)))
}

words_contains :: proc(a: ^Words, s: string) -> bool {
	w := a
	for c in s do w = words_derive(w, c)
	return w.nullable
}

words_literal :: proc(s: string) -> ^Words {
	w := words_epsilon()
	runes := make([dynamic]rune)
	for c in s do append(&runes, c)
	#reverse for c in runes do w = words_cat(words_char(c), w)
	return w
}
