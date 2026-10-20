package kernel

import syn "../compiler"
import "base:runtime"
import "core:fmt"
import "core:math/rand"
import vmem "core:mem/virtual"
import "core:slice"
import "core:strings"
import "core:testing"

// THE COVERAGE OF THE REST OF THE ALGEBRA: each operation that was only checked
// by examples is confronted with a brute-force model on randomly drawn cases.

// --- shared generators ---

small_ints :: proc(gen: runtime.Random_Generator) -> Ints {
	lo := i128(rand.int_range(-6, 7, gen))
	return ints_range(lo, lo + i128(rand.int_range(0, 4, gen)))
}

small_words :: proc(gen: runtime.Random_Generator) -> []string {
	pool := []string{"", "a", "b", "ab", "ba", "aa"}
	out := make([dynamic]string)
	for w in pool do if rand.int_max(3, gen) == 0 do append(&out, w)
	if len(out) == 0 do append(&out, "a")
	return out[:]
}

random_mixed :: proc(gen: runtime.Random_Generator) -> Set {
	s: Set
	if rand.int_max(2, gen) == 0 do s.ints = small_ints(gen)
	if rand.int_max(4, gen) == 0 do s.floats = floats_of({Float_Interval{lo = f64(rand.int_range(-2, 2, gen)), hi = 2}})
	if rand.int_max(3, gen) == 0 do s.chars = ints_range(i128(rand.int_range('a', 'c', gen)), 'c')
	if rand.int_max(3, gen) == 0 do s.strings = strings_of_words(small_words(gen))
	if rand.int_max(4, gen) == 0 do s.bools = rand.choice([]Bools{{.True}, {.False}, {.False, .True}}, gen)
	return s
}

// float_samples: points of a set of floats (closed bounds, midpoints).
float_samples :: proc(f: Floats) -> []f64 {
	out := make([dynamic]f64)
	for iv in f.intervals {
		lo, lo_ok := iv.lo.?
		hi, hi_ok := iv.hi.?
		if lo_ok && !iv.lo_open do append(&out, lo)
		if hi_ok && !iv.hi_open do append(&out, hi)
		if lo_ok && hi_ok do append(&out, (lo + hi) / 2, lo + (hi - lo) / 4)
		if lo_ok && !hi_ok do append(&out, lo + 1, lo + 100)
		if !lo_ok && hi_ok do append(&out, hi - 1, hi - 100)
		if !lo_ok && !hi_ok do append(&out, -5, 0, 7)
	}
	return out[:]
}

// --- floats: arithmetic and negation ---

@(test)
test_law_float_arith :: proc(t: ^testing.T) {
	arena: vmem.Arena
	context.allocator = vmem.arena_allocator(&arena)
	defer vmem.arena_destroy(&arena)
	state: rand.Default_Random_State
	gen := seeded(&state, 11)
	for _ in 0 ..< ROUNDS {
		a, _ := random_floats(gen)
		b, _ := random_floats(gen)
		for op in Arith {
			r := floats_arith(op, a, b)
			for x in float_samples(a) do for y in float_samples(b) {
				v := op == .Add ? x + y : (op == .Sub ? x - y : x * y)
				testing.expectf(t, floats_contains(r, v), "%v %v %v does not contain %v (%v, %v)", a, op, b, v, x, y)
			}
		}
		n := floats_neg(a)
		for x in float_samples(a) do testing.expectf(t, floats_contains(n, -x), "-%v does not contain %v", a, -x)
		testing.expect(t, same_floats(floats_neg(n), a), "-(-a) = a")
	}
}

@(test)
test_law_int_negation :: proc(t: ^testing.T) {
	arena: vmem.Arena
	context.allocator = vmem.arena_allocator(&arena)
	defer vmem.arena_destroy(&arena)
	state: rand.Default_Random_State
	gen := seeded(&state, 12)
	for _ in 0 ..< ROUNDS {
		a, ra := random_ints(gen)
		n := ints_neg(a)
		for x in INT_POINTS do testing.expectf(t, ints_contains(n, -x) == in_raw(ra, x), "-%v at %d", ra, -x)
		testing.expect(t, same_ints(ints_neg(n), a), "-(-a) = a")
	}
}

// --- defaults: the distinguished element is in the set, and follows the rule ---

@(test)
test_law_defaults :: proc(t: ^testing.T) {
	arena: vmem.Arena
	context.allocator = vmem.arena_allocator(&arena)
	defer vmem.arena_destroy(&arena)
	state: rand.Default_Random_State
	gen := seeded(&state, 13)
	for _ in 0 ..< ROUNDS {
		s := random_mixed(gen)
		d, ok := set_default(s)
		testing.expect(t, ok == !set_is_empty(s), "a default exists iff the set is non-empty")
		if !ok do continue
		testing.expectf(t, is_atom(d) && atoms_subset(d, s), "the default %s of %s belongs to it", print_set(d), print_set(s))
		first, _ := set_first_domain(s)
		dd, _ := pure_domain(d)
		testing.expectf(t, dd == first, "the default of %s is taken from the first sort", print_set(s))
		#partial switch first {
		case .Ints:
			v, _ := ints_default(d.ints)
			lo, _ := ints_bounds(s.ints)
			want := ints_contains(s.ints, 0) ? 0 : (lo.? or_else v)
			testing.expectf(t, v == want, "integer default of %s: %d, expected %d", print_set(s), v, want)
		case .Chars:
			v, _ := ints_bounds(d.chars)
			lo, _ := ints_bounds(s.chars)
			testing.expect(t, v == lo, "character default: the lowest")
		case .Bools:
			testing.expect(t, (.False in s.bools) == (.False in d.bools), "boolean default: false if it is there")
		}
	}
	none_default, ok := set_default(Set{})
	testing.expect(t, !ok && set_is_empty(none_default), "none has no default: its only value is none")
}

// --- characters: the complete algebra, the embedding into strings ---

CHAR_POINTS := [?]i128{CHAR_EMPTY, 0, 1, 2, 3, 5, 7, 9, 10, 11, 12, i128(MAX_RUNE) - 1, i128(MAX_RUNE)}

random_chars :: proc(gen: runtime.Random_Generator) -> (Ints, []Int_Interval) {
	raw := make([dynamic]Int_Interval)
	for _ in 0 ..< rand.int_range(0, 4, gen) {
		lo := i128(rand.int_range(-1, 11, gen))
		hi := lo + i128(rand.int_range(0, 4, gen))
		if rand.int_max(8, gen) == 0 do hi = i128(MAX_RUNE)
		append(&raw, Int_Interval{lo, hi})
	}
	return ints_of(raw[:]), raw[:]
}

@(test)
test_law_chars_full :: proc(t: ^testing.T) {
	arena: vmem.Arena
	context.allocator = vmem.arena_allocator(&arena)
	defer vmem.arena_destroy(&arena)
	state: rand.Default_Random_State
	gen := seeded(&state, 14)
	for _ in 0 ..< ROUNDS {
		ca, ra := random_chars(gen)
		cb, rb := random_chars(gen)
		a, b := set_of_chars(ca), set_of_chars(cb)
		comp := set_complement(a)
		for x in CHAR_POINTS {
			testing.expectf(t, ints_contains(set_union(a, b).chars, x) == (in_raw(ra, x) || in_raw(rb, x)), "union at %d", x)
			testing.expectf(t, ints_contains(set_intersect(a, b).chars, x) == (in_raw(ra, x) && in_raw(rb, x)), "inter at %d", x)
			if !set_is_empty(a) do testing.expectf(t, ints_contains(comp.chars, x) == !in_raw(ra, x), "~%v at %d", ra, x)
		}
		testing.expect(t, !ints_contains(comp.chars, CHAR_EMPTY - 1) && !ints_contains(comp.chars, i128(MAX_RUNE) + 1), "the complement stays within characters")
		testing.expect(t, set_is_empty(set_of_strings(comp.strings)) && set_is_empty(set_of_ints(comp.ints)), "the complement stays within the sort")
		testing.expect(t, set_equal(set_complement(comp), a) || set_is_empty(a), "~~a = a")
		testing.expect(t, set_equal(set_complement(set_union(a, b)), set_intersect(set_complement(a), set_complement(b))) || set_is_empty(a) || set_is_empty(b), "De Morgan")
		// characters as one-letter strings, the empty one as ""
		lifted := chars_as_strings(ca)
		for x in CHAR_POINTS {
			word := x == CHAR_EMPTY ? "" : fmt.tprintf("%c", rune(x))
			testing.expectf(t, strings_contains(lifted, word) == in_raw(ra, x), "embedding of %v at %d", ra, x)
		}
	}
}

// --- booleans ---

@(test)
test_law_bools :: proc(t: ^testing.T) {
	arena: vmem.Arena
	context.allocator = vmem.arena_allocator(&arena)
	defer vmem.arena_destroy(&arena)
	all :=[]Bools{{}, {.False}, {.True}, {.False, .True}}
	for a in all do for b in all {
		sa, sb := set_of_bools(a), set_of_bools(b)
		testing.expect(t, set_union(sa, sb).bools == a | b && set_intersect(sa, sb).bools == a & b, "union, inter")
		if card(a) > 0 do testing.expect(t, set_complement(sa).bools == ~a, "complement")
		testing.expect(t, set_subset(sa, sb) == (a <= b), "inclusion")
	}
}

// --- sets taken as values: finite and cofinite lists, against a model ---
//
// The universe: four distinct sets, and a fifth one that no list names, which
// stands for all the others. A list is compared with its mask.

@(test)
test_law_set_values :: proc(t: ^testing.T) {
	arena: vmem.Arena
	context.allocator = vmem.arena_allocator(&arena)
	defer vmem.arena_destroy(&arena)
	state: rand.Default_Random_State
	gen := seeded(&state, 24)
	pool := [4]Set{set_of_ints(ints_range(0, 1)), set_of_ints(ints_range(0, 2)), set_of_strings(strings_of_words({"a", "b"})), set_of_bools({.False, .True})}
	// the same sets, written differently: equality is that of sets
	rewritten := [4]Set{set_of_ints(ints_of({{1, 1}, {0, 0}})), set_of_ints(ints_of({{2, 2}, {0, 1}})), set_of_strings(strings_of_words({"b", "a", "b"})), set_of_bools({.True, .False})}
	other := set_of_ints(ints_range(5, 6))
	OTHER :: u8(1 << 4)
	Model :: struct {
		set:  Set,
		mask: u8,
	}
	random_values :: proc(gen: runtime.Random_Generator, pool: [4]Set) -> Model {
		listed := make([dynamic]Set)
		mask: u8
		for p, i in pool do if rand.int_max(2, gen) == 0 {
			append(&listed, p)
			mask |= 1 << uint(i)
		}
		cofinite := rand.int_max(2, gen) == 0
		if cofinite do mask = ~mask & 0x1F
		return Model{Set{sorts = {.Sets}, sets = Set_Values{listed[:], cofinite}}, mask}
	}
	for _ in 0 ..< ROUNDS {
		a, b := random_values(gen, pool), random_values(gen, pool)
		check :: proc(t: ^testing.T, s: Set, mask: u8, rewritten: [4]Set, other: Set, what: string) {
			for p, i in rewritten do testing.expectf(t, values_contains(s.sets, p) == (mask & (1 << uint(i)) != 0), "%s: element %d", what, i)
			testing.expectf(t, values_contains(s.sets, other) == (mask & OTHER != 0), "%s: the other sets", what)
		}
		check(t, set_union(a.set, b.set), a.mask | b.mask, rewritten, other, "union")
		check(t, set_intersect(a.set, b.set), a.mask & b.mask, rewritten, other, "intersection")
		check(t, set_diff(a.set, b.set), a.mask & ~b.mask, rewritten, other, "difference")
		check(t, set_complement(a.set), ~a.mask & 0x1F, rewritten, other, "complement")
		testing.expect(t, set_equal(set_complement(set_complement(a.set)), a.set), "~~a = a")
		testing.expect(t, set_subset(a.set, b.set) == (a.mask & ~b.mask == 0), "inclusion")
		testing.expect(t, set_is_empty(a.set) == (a.mask == 0), "empty")
		testing.expect(t, set_equal(set_complement(set_union(a.set, b.set)), set_intersect(set_complement(a.set), set_complement(b.set))), "De Morgan")
	}
}

// --- a mixed set: the complement touches only the carried sorts ---

@(test)
test_law_mixed_complement :: proc(t: ^testing.T) {
	arena: vmem.Arena
	context.allocator = vmem.arena_allocator(&arena)
	defer vmem.arena_destroy(&arena)
	state: rand.Default_Random_State
	gen := seeded(&state, 15)
	for _ in 0 ..< ROUNDS {
		s := random_mixed(gen)
		c := set_complement(s)
		for d in Domain {
			has := domain_count(s, d) > 0
			if !has do testing.expectf(t, domain_count(c, d) == 0, "%s: the complement does not invent the sort %v", print_set(s), d)
		}
		if domain_count(s, .Ints) > 0 do testing.expect(t, same_ints(c.ints, ints_complement(s.ints)), "integers")
		if domain_count(s, .Strings) > 0 do testing.expect(t, strings_equal(c.strings, strings_complement(s.strings)), "strings")
		testing.expectf(t, set_equal(set_complement(c), s), "~~%s", print_set(s))
	}
}

// --- set arithmetic, sort by sort ---

@(test)
test_law_arith_sets :: proc(t: ^testing.T) {
	arena: vmem.Arena
	context.allocator = vmem.arena_allocator(&arena)
	defer vmem.arena_destroy(&arena)
	state: rand.Default_Random_State
	gen := seeded(&state, 16)
	textual :: proc(s: Set) -> bool {
		return domain_count(s, .Strings) > 0 || domain_count(s, .Chars) > 0
	}
	has :: proc(s: Set, d: Domain) -> bool {
		return domain_count(s, d) > 0
	}
	for _ in 0 ..< ROUNDS {
		a, b := random_mixed(gen), random_mixed(gen)
		for op in Arith {
			r, status := arith_sets(op, a, b)
			compatible :=
				(has(a, .Ints) && has(b, .Ints)) ||
				(has(a, .Floats) && has(b, .Floats)) ||
				(op == .Add && textual(a) && textual(b)) ||
				(op == .Mul && ((textual(a) && has(b, .Ints)) || (has(a, .Ints) && textual(b))))
			if !compatible {
				testing.expectf(t, status != .Ok, "%s %v %s: no compatible pair", print_set(a), op, print_set(b))
				continue
			}
			if status != .Ok do continue // a repetition too large to be exact
			if has(a, .Ints) && has(b, .Ints) {
				atoms_a, _ := atoms_of_set(set_of_ints(a.ints), 64)
				atoms_b, _ := atoms_of_set(set_of_ints(b.ints), 64)
				for x in atoms_a do for y in atoms_b {
					p, q := x.(i128), y.(i128)
					v := op == .Add ? p + q : (op == .Sub ? p - q : p * q)
					testing.expectf(t, ints_contains(r.ints, v), "integers: %d %v %d", p, op, q)
				}
			}
			if op == .Add && textual(a) && textual(b) {
				testing.expect(t, strings_equal(r.strings, strings_concat(as_strings(a), as_strings(b))), "+ concatenates, characters counting as strings")
			}
			if op == .Mul && textual(a) && has(b, .Ints) {
				words, _ := strings_words(as_strings(a), 64)
				counts, _ := atoms_of_set(set_of_ints(ints_intersect(b.ints, ints_range(0, 3))), 64)
				for w in words do for n in counts do testing.expectf(t, strings_contains(r.strings, strings.repeat(w, int(n.(i128)))), "%q * %v", w, n)
			}
		}
	}
}

// --- ranges, all sorts ---

@(test)
test_law_ranges :: proc(t: ^testing.T) {
	arena: vmem.Arena
	context.allocator = vmem.arena_allocator(&arena)
	defer vmem.arena_destroy(&arena)
	state: rand.Default_Random_State
	gen := seeded(&state, 17)
	universe := all_words()
	for _ in 0 ..< ROUNDS {
		// integers: the envelope of the bounds, forward or reversed, chained
		lo, hi := small_ints(gen), small_ints(gen)
		r, status := range_set(set_of_ints(lo), false, set_of_ints(hi), false)
		l1, h1 := ints_bounds(lo)
		l2, h2 := ints_bounds(hi)
		want := ints_range(min(l1.?, l2.?), max(h1.?, h2.?))
		testing.expectf(t, status == .Ok && same_ints(r.ints, want), "%v..%v", lo, hi)
		open_hi, _ := range_set(set_of_ints(lo), false, Set{}, true)
		testing.expect(t, same_ints(open_hi.ints, ints_range(l1.?, nil)), "lo..")
		// characters: the range, open toward '' or toward the last character
		a, b := i128(rand.int_range('a', 'z', gen)), i128(rand.int_range('a', 'z', gen))
		cr, _ := range_set(set_of_chars(ints_point(a)), false, set_of_chars(ints_point(b)), false)
		testing.expect(t, same_ints(cr.chars, ints_range(min(a, b), max(a, b))), "'a'..'z'")
		from_empty, _ := range_set(Set{}, true, set_of_chars(ints_point(b)), false)
		testing.expect(t, same_ints(from_empty.chars, ints_range(CHAR_EMPTY, b)), "..'z' starts from the empty character")
		// strings: starts with a word of lo, ends with a word of hi
		pl, sl := strings_of_words(small_words(gen)), strings_of_words(small_words(gen))
		sr, _ := range_set(set_of_strings(pl), false, set_of_strings(sl), false)
		for w in universe {
			starts, ends := false, false
			for p in small_words_of(pl) do starts ||= strings.has_prefix(w, p)
			for s in small_words_of(sl) do ends ||= strings.has_suffix(w, s)
			testing.expectf(t, strings_contains(sr.strings, w) == (starts && ends), "%q in %s..%s", w, print_strings(pl), print_strings(sl))
		}
		// different sorts: not a range
		_, bad := range_set(set_of_ints(lo), false, set_of_strings(pl), false)
		testing.expect(t, bad != .Ok, "a range between an integer and a string")
	}
	top, _ := range_set(Set{}, true, Set{}, true)
	testing.expect(t, set_equal(top, set_top()), ".. is everything")
}

small_words_of :: proc(s: Strings) -> []string {
	w, _ := strings_words(s, 64)
	return w
}

// --- half-lines ---

@(test)
test_law_half_lines :: proc(t: ^testing.T) {
	arena: vmem.Arena
	context.allocator = vmem.arena_allocator(&arena)
	defer vmem.arena_destroy(&arena)
	kinds := []syn.Operator_Kind{.Greater, .GreaterEqual, .Less, .LessEqual, .NotEqual}
	for x in -5 ..= 5 do for kind in kinds {
		r, status := half_line(kind, set_of_ints(ints_point(i128(x))))
		testing.expect(t, status == .Ok, "integer half-line")
		for y in -9 ..= 9 {
			want: bool
			#partial switch kind {
			case .Greater:
				want = y > x
			case .GreaterEqual:
				want = y >= x
			case .Less:
				want = y < x
			case .LessEqual:
				want = y <= x
			case .NotEqual:
				want = y != x
			}
			testing.expectf(t, ints_contains(r.ints, i128(y)) == want, "%v %d at %d", kind, x, y)
		}
		fr, _ := half_line(kind, set_of_floats(floats_point(f64(x))))
		for y := -6.0; y <= 6.0; y += 0.5 {
			want: bool
			fx := f64(x)
			#partial switch kind {
			case .Greater:
				want = y > fx
			case .GreaterEqual:
				want = y >= fx
			case .Less:
				want = y < fx
			case .LessEqual:
				want = y <= fx
			case .NotEqual:
				want = y != fx
			}
			testing.expectf(t, floats_contains(fr.floats, y) == want, "%v %v at %v", kind, fx, y)
		}
	}
	_, status := half_line(.Greater, set_of_ints(ints_range(1, 2)))
	testing.expect(t, status != .Ok, ">x expects a single number")
}

// --- envelopes: they always contain the actual set ---

Sx :: struct {
	kind:  Set_Op_Kind,
	half:  syn.Operator_Kind,
	known: Set,
	leaf:  int, // 0: the unknown n; 1: a known set; 2: an operation
	a, b:  ^Sx,
}

random_sx :: proc(gen: runtime.Random_Generator, depth: int) -> ^Sx {
	x := new(Sx)
	if depth == 0 || rand.int_max(3, gen) == 0 {
		x.leaf = rand.int_max(2, gen)
		x.known = set_of_ints(small_ints(gen))
		return x
	}
	x.leaf = 2
	x.kind = rand.choice([]Set_Op_Kind{.Union, .Inter, .Comp, .Arith, .Range, .Half}, gen)
	x.half = rand.choice([]syn.Operator_Kind{.Greater, .Less, .GreaterEqual, .LessEqual, .NotEqual}, gen)
	x.a = random_sx(gen, depth - 1)
	x.b = random_sx(gen, depth - 1)
	if x.kind == .Half do x.a.leaf = 0 // >n: the bound is the unknown
	return x
}

build_sx :: proc(k: ^Kernel, x: ^Sx, n: ^Expr) -> ^Expr {
	switch x.leaf {
	case 0:
		return n
	case 1:
		return new_expr(x.known)
	}
	op := Set_Op{kind = x.kind, half = x.half, arith = .Add}
	switch x.kind {
	case .Comp, .Half:
		return set_operation(k, op, {}, build_sx(k, x.a, n))
	case .Union, .Inter, .Arith, .Range:
	}
	return set_operation(k, op, {}, build_sx(k, x.a, n), build_sx(k, x.b, n))
}

// The form of a set that depends on an unknown, simplified, equals the direct
// computation for each value of the unknown, and its envelope contains it.
@(test)
test_law_set_forms_large :: proc(t: ^testing.T) {
	arena: vmem.Arena
	context.allocator = vmem.arena_allocator(&arena)
	defer vmem.arena_destroy(&arena)
	state: rand.Default_Random_State
	gen := seeded(&state, 18)
	k: Kernel
	big := new_symbol(&k, set_of_ints(ints_range(-100_000, 100_000))) // too large to enumerate
	id := big^.(Poly).monos[0].vars[0]
	forms := 0
	for _ in 0 ..< ROUNDS {
		x := random_sx(gen, 3)
		clear(&k.errors)
		e := build_sx(&k, x, big)
		if len(k.errors) > 0 do continue
		upper, ok := set_envelope(&k, e)
		testing.expect(t, ok, "every set form has an envelope")
		if is_set_form(e) do forms += 1
		env := make([]Atom, k.variables)
		for _ in 0 ..< 20 {
			v := i128(rand.int_range(-100_000, 100_001, gen))
			clear(&k.errors)
			exact := build_sx(&k, x, new_expr(set_of_ints(ints_point(v))))
			if len(k.errors) > 0 do continue // an operation invalid for this value: the empty operand, open question
			s, known := color_set(&k, exact)
			testing.expectf(t, known && set_subset(s, upper), "n = %d: %s ⊄ %s", v, print_type(exact), print_set(upper))
			env[id.id] = v
			got, got_ok := eval_set(&k, e, env)
			testing.expectf(t, got_ok && set_equal(got, s) && carried(got) == carried(s), "n = %d: %s is %s, expected %s", v, print_type(e), print_set(got), print_set(s))
		}
	}
	testing.expectf(t, forms >= ROUNDS / 8, "forms checked: %d", forms)
}

// --- comparisons that are not on integers ---

@(test)
test_law_general_compare :: proc(t: ^testing.T) {
	arena: vmem.Arena
	context.allocator = vmem.arena_allocator(&arena)
	defer vmem.arena_destroy(&arena)
	state: rand.Default_Random_State
	gen := seeded(&state, 19)
	k: Kernel
	sorts := []Set{set_of_chars(ints_range('a', 'e')), set_of_strings(strings_of_words({"a", "b", "ab"})), set_of_bools({.False, .True})}
	for _ in 0 ..< ROUNDS {
		s := rand.choice(sorts, gen)
		operand :: proc(k: ^Kernel, gen: runtime.Random_Generator, s: Set) -> ^Expr {
			if rand.int_max(2, gen) == 0 do return new_symbol(k, s)
			atoms, _ := atoms_of_set(s, 64)
			return new_expr(set_of_atoms({rand.choice(atoms, gen)}))
		}
		a, b := operand(&k, gen, s), operand(&k, gen, s)
		d, _ := pure_domain(s)
		ops := d == .Chars ? []Compare_Op{.Lt, .Le, .Gt, .Ge, .Eq, .Ne} : []Compare_Op{.Eq, .Ne}
		op := rand.choice(ops, gen)
		r, status := general_compare(&k, op, a, b)
		testing.expect(t, status == .Ok, "valid comparison")
		if status != .Ok do continue
		// the truth, over all the values of the unknowns
		syms := make([dynamic]^Var)
		collect_symbols(a, &syms)
		collect_symbols(b, &syms)
		slice.sort_by(syms[:], var_less)
		ids := slice.unique(syms[:])
		as, _ := assignments_of(&k, ids)
		seen: [2]bool
		for {
			x, _ := eval(a, as.env)
			y, _ := eval(b, as.env)
			truth: bool
			switch op {
			case .Eq:
				truth = atom_equal(x, y)
			case .Ne:
				truth = !atom_equal(x, y)
			case .Lt:
				truth, _ = atom_less(x, y)
			case .Gt:
				truth, _ = atom_less(y, x)
			case .Le:
				l, _ := atom_less(y, x)
				truth = !l
			case .Ge:
				l, _ := atom_less(x, y)
				truth = !l
			}
			seen[int(truth)] = true
			got, ok := eval(r, as.env)
			testing.expectf(t, ok && got.(bool) == truth, "%v of %s and %s", op, print_type(a), print_type(b))
			if !next_assignment(&as) do break
		}
		_, decided := r^.(Set)
		testing.expectf(t, decided == !(seen[0] && seen[1]), "%v of %s and %s: decided %v", op, print_type(a), print_type(b), decided)
	}
}

// --- float terms: normalized up to commutativity, evaluated exactly ---

Fx :: struct {
	op:   u8, // 0 leaf, '+', '-', '*', 'n' (negation)
	sym:  int, // -1: constant
	c:    f64,
	a, b: ^Fx,
}

random_fx :: proc(gen: runtime.Random_Generator, depth: int) -> ^Fx {
	x := new(Fx)
	if depth == 0 || rand.int_max(3, gen) == 0 {
		x.sym = rand.int_range(-1, 2, gen)
		x.c = rand.choice([]f64{0.5, 1, 2, -1.5, 0.1}, gen)
		return x
	}
	x.op = rand.choice([]u8{'+', '-', '*', 'n'}, gen)
	x.a, x.b = random_fx(gen, depth - 1), random_fx(gen, depth - 1)
	return x
}

fx_build :: proc(syms: []^Expr, x: ^Fx, swap: bool) -> ^Expr {
	switch x.op {
	case 0:
		return x.sym < 0 ? new_expr(set_of_floats(floats_point(x.c))) : syms[x.sym]
	case 'n':
		return float_neg(fx_build(syms, x.a, swap))
	case '-':
		return float_add(fx_build(syms, x.a, swap), float_neg(fx_build(syms, x.b, swap)))
	}
	l, r := fx_build(syms, x.a, swap), fx_build(syms, x.b, swap)
	if swap do l, r = r, l
	return x.op == '+' ? float_add(l, r) : float_mul(l, r)
}

fx_eval :: proc(x: ^Fx, env: [2]f64) -> f64 {
	switch x.op {
	case 0:
		return x.sym < 0 ? x.c : env[x.sym]
	case 'n':
		return -fx_eval(x.a, env)
	case '+':
		return fx_eval(x.a, env) + fx_eval(x.b, env)
	case '-':
		return fx_eval(x.a, env) - fx_eval(x.b, env)
	}
	return fx_eval(x.a, env) * fx_eval(x.b, env)
}

@(test)
test_law_float_terms :: proc(t: ^testing.T) {
	arena: vmem.Arena
	context.allocator = vmem.arena_allocator(&arena)
	defer vmem.arena_destroy(&arena)
	state: rand.Default_Random_State
	gen := seeded(&state, 20)
	k: Kernel
	syms := []^Expr{new_symbol(&k, set_of_floats(floats_of({Float_Interval{lo = -2, hi = 3}}))), new_symbol(&k, set_of_floats(floats_of({Float_Interval{lo = 0.5, hi = 4}})))}
	for _ in 0 ..< ROUNDS {
		x := random_fx(gen, 3)
		e := fx_build(syms, x, false)
		testing.expectf(t, expr_equal(&k, e, fx_build(syms, x, true)), "commutativity: %s", print_type(e))
		vals, _ := values_of(&k, e)
		for p in ([?][2]f64{{-2, 0.5}, {3, 4}, {0, 1}, {1.25, 2.5}, {-1, 3.75}}) {
			got, ok := eval(e, {p[0], p[1]})
			want := fx_eval(x, p)
			testing.expectf(t, ok && got.(f64) == want, "%s at %v: %v, expected %v", print_type(e), p, got, want)
			testing.expectf(t, floats_contains(vals.floats, want), "values of %s: %v missing", print_type(e), want)
		}
	}
}

// --- string words and repetitions with an unknown count ---

@(test)
test_law_words :: proc(t: ^testing.T) {
	arena: vmem.Arena
	context.allocator = vmem.arena_allocator(&arena)
	defer vmem.arena_destroy(&arena)
	state: rand.Default_Random_State
	gen := seeded(&state, 21)
	k: Kernel
	s0 := new_symbol(&k, set_of_strings(strings_of_words({"x", "yy"})))
	s1 := new_symbol(&k, set_of_chars(ints_range('p', 'q')))
	count := new_symbol(&k, set_of_ints(ints_range(0, 3)))
	for _ in 0 ..< ROUNDS {
		// a sequence of parts, concatenated left to right and right to left,
		// with the literals cut into pieces on one side: a single form
		parts := make([dynamic]^Expr)
		pieces := make([dynamic]^Expr)
		for _ in 0 ..< rand.int_range(1, 6, gen) {
			switch rand.int_max(4, gen) {
			case 0:
				append(&parts, s0)
				append(&pieces, s0)
			case 1:
				append(&parts, s1)
				append(&pieces, s1)
			case:
				w := rand.choice([]string{"", "a", "ab", "ba"}, gen)
				append(&parts, new_expr(set_of_strings(strings_point(w))))
				for r in w do append(&pieces, new_expr(set_of_chars(ints_point(i128(r)))))
			}
		}
		left := new_expr(set_of_strings(strings_point("")))
		for p in parts do left = concat(&k, left, p)
		right := new_expr(set_of_strings(strings_point("")))
		#reverse for p in pieces do right = concat(&k, p, right)
		testing.expectf(t, expr_equal(&k, left, right), "%s and %s", print_type(left), print_type(right))
		// repeated an unknown number of times: the value and the exact possible values
		rep, _ := repeat_term(&k, left, count)
		vals, _ := values_of(&k, rep)
		for w in ([?]string{"x", "yy"}) do for c in ([?]rune{'p', 'q'}) do for n in 0 ..= 3 {
			env := []Atom{w, Char_Atom(c), i128(n)}
			one, ok := eval(left, env)
			testing.expect(t, ok, "evaluation of the word")
			word := atom_text(one)
			got, _ := eval(rep, env)
			testing.expectf(t, atom_text(got) == strings.repeat(word, n), "%s * %d", print_type(left), n)
			testing.expectf(t, strings_contains(vals.strings, strings.repeat(word, n)), "values of %s", print_type(rep))
		}
	}
}

// --- over-approximated values always contain the actual value ---

@(test)
test_law_approximation :: proc(t: ^testing.T) {
	arena: vmem.Arena
	context.allocator = vmem.arena_allocator(&arena)
	defer vmem.arena_destroy(&arena)
	state: rand.Default_Random_State
	gen := seeded(&state, 22)
	k: Kernel
	declare_vars(&k, set_of_ints(ints_range(-1_000_000, 1_000_000)), set_of_ints(ints_range(-1_000_000, 1_000_000)), set_of_ints(ints_range(-1_000_000, 1_000_000)))
	for _ in 0 ..< ROUNDS {
		tree := random_tree(gen, 3)
		p := poly_type(tree_poly(tree))
		vals, _ := values_of(&k, p)
		for _ in 0 ..< 30 {
			env := [3]i128{i128(rand.int_range(-1_000_000, 1_000_001, gen)), i128(rand.int_range(-1_000_000, 1_000_001, gen)), i128(rand.int_range(-1_000_000, 1_000_001, gen))}
			v := tree_eval(tree, env)
			testing.expectf(t, ints_contains(vals.ints, v), "%s at %v = %d outside %v", print_type(p), env, v, vals.ints)
		}
	}
}

// --- the admission of atoms by a color ---

@(test)
test_law_admission :: proc(t: ^testing.T) {
	arena: vmem.Arena
	context.allocator = vmem.arena_allocator(&arena)
	defer vmem.arena_destroy(&arena)
	state: rand.Default_Random_State
	gen := seeded(&state, 23)
	for _ in 0 ..< ROUNDS {
		tv, c := random_mixed(gen), random_mixed(gen)
		atoms, _ := atoms_of_set(tv, 4096)
		want := true
		if set_is_empty(tv) do want = set_is_empty(c)
		for a in atoms {
			inside := atoms_subset(set_of_atoms({a}), c)
			// a character is admitted by a string color, as a one-letter string
			if ch, is_char := a.(Char_Atom); is_char && !inside do inside = strings_contains(c.strings, atom_text(ch))
			want &&= inside
		}
		if domain_count(tv, .Floats) > 0 do continue // intervals of reals: not enumerable
		testing.expectf(t, atoms_admitted(tv, c) == want, "%s admitted by %s: %v", print_set(tv), print_set(c), want)
	}
}
