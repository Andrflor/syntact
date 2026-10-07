package kernel

import syn "../compiler"
import "base:runtime"
import "core:fmt"
import "core:math/rand"
import vmem "core:mem/virtual"
import "core:slice"
import "core:strings"
import "core:testing"

// LA COUVERTURE DU RESTE DE L'ALGÈBRE : chaque opération qui n'était vérifiée que
// par des exemples est confrontée à un modèle brut sur des cas tirés au hasard.

// --- générateurs partagés ---

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

// float_samples : des points d'un ensemble de flottants (bornes fermées, milieux).
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

// --- flottants : arithmétique et négation ---

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
				testing.expectf(t, floats_contains(r, v), "%v %v %v ne contient pas %v (%v, %v)", a, op, b, v, x, y)
			}
		}
		n := floats_neg(a)
		for x in float_samples(a) do testing.expectf(t, floats_contains(n, -x), "-%v ne contient pas %v", a, -x)
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
		for x in INT_POINTS do testing.expectf(t, ints_contains(n, -x) == in_raw(ra, x), "-%v en %d", ra, -x)
		testing.expect(t, same_ints(ints_neg(n), a), "-(-a) = a")
	}
}

// --- défauts : l'élément distingué est dans l'ensemble, et suit la règle ---

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
		testing.expect(t, ok == !set_is_empty(s), "un défaut existe ssi l'ensemble est non vide")
		if !ok do continue
		testing.expectf(t, is_atom(d) && atoms_subset(d, s), "le défaut %s de %s en fait partie", print_set(d), print_set(s))
		first, _ := set_first_domain(s)
		dd, _ := pure_domain(d)
		testing.expectf(t, dd == first, "le défaut de %s est pris dans la première sorte", print_set(s))
		#partial switch first {
		case .Ints:
			v, _ := ints_default(d.ints)
			lo, _ := ints_bounds(s.ints)
			want := ints_contains(s.ints, 0) ? 0 : (lo.? or_else v)
			testing.expectf(t, v == want, "défaut entier de %s : %d, attendu %d", print_set(s), v, want)
		case .Chars:
			v, _ := ints_bounds(d.chars)
			lo, _ := ints_bounds(s.chars)
			testing.expect(t, v == lo, "défaut caractère : le plus bas")
		case .Bools:
			testing.expect(t, (.False in s.bools) == (.False in d.bools), "défaut booléen : false s'il y est")
		}
	}
	none_default, ok := set_default(Set{})
	testing.expect(t, !ok && set_is_empty(none_default), "none n'a pas de défaut : sa seule valeur est none")
}

// --- caractères : l'algèbre complète, le plongement dans les chaînes ---

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
			testing.expectf(t, ints_contains(set_union(a, b).chars, x) == (in_raw(ra, x) || in_raw(rb, x)), "union en %d", x)
			testing.expectf(t, ints_contains(set_intersect(a, b).chars, x) == (in_raw(ra, x) && in_raw(rb, x)), "inter en %d", x)
			if !set_is_empty(a) do testing.expectf(t, ints_contains(comp.chars, x) == !in_raw(ra, x), "~%v en %d", ra, x)
		}
		testing.expect(t, !ints_contains(comp.chars, CHAR_EMPTY - 1) && !ints_contains(comp.chars, i128(MAX_RUNE) + 1), "le complément reste dans les caractères")
		testing.expect(t, set_is_empty(set_of_strings(comp.strings)) && set_is_empty(set_of_ints(comp.ints)), "le complément reste dans la sorte")
		testing.expect(t, set_equal(set_complement(comp), a) || set_is_empty(a), "~~a = a")
		testing.expect(t, set_equal(set_complement(set_union(a, b)), set_intersect(set_complement(a), set_complement(b))) || set_is_empty(a) || set_is_empty(b), "De Morgan")
		// les caractères comme chaînes d'une lettre, le vide comme ""
		lifted := chars_as_strings(ca)
		for x in CHAR_POINTS {
			word := x == CHAR_EMPTY ? "" : fmt.tprintf("%c", rune(x))
			testing.expectf(t, strings_contains(lifted, word) == in_raw(ra, x), "plongement de %v en %d", ra, x)
		}
	}
}

// --- booléens ---

@(test)
test_law_bools :: proc(t: ^testing.T) {
	arena: vmem.Arena
	context.allocator = vmem.arena_allocator(&arena)
	defer vmem.arena_destroy(&arena)
	all :=[]Bools{{}, {.False}, {.True}, {.False, .True}}
	for a in all do for b in all {
		sa, sb := set_of_bools(a), set_of_bools(b)
		testing.expect(t, set_union(sa, sb).bools == a | b && set_intersect(sa, sb).bools == a & b, "union, inter")
		if card(a) > 0 do testing.expect(t, set_complement(sa).bools == ~a, "complément")
		testing.expect(t, set_subset(sa, sb) == (a <= b), "inclusion")
	}
}

// --- un ensemble mixte : le complément ne touche que les sortes portées ---

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
			if !has do testing.expectf(t, domain_count(c, d) == 0, "%s : le complément n'invente pas la sorte %v", print_set(s), d)
		}
		if domain_count(s, .Ints) > 0 do testing.expect(t, same_ints(c.ints, ints_complement(s.ints)), "entiers")
		if domain_count(s, .Strings) > 0 do testing.expect(t, strings_equal(c.strings, strings_complement(s.strings)), "chaînes")
		testing.expectf(t, set_equal(set_complement(c), s), "~~%s", print_set(s))
	}
}

// --- l'arithmétique d'ensembles, sorte par sorte ---

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
				testing.expectf(t, status != .Ok, "%s %v %s : aucune paire compatible", print_set(a), op, print_set(b))
				continue
			}
			if status != .Ok do continue // une répétition trop grande pour être exacte
			if has(a, .Ints) && has(b, .Ints) {
				atoms_a, _ := atoms_of_set(set_of_ints(a.ints), 64)
				atoms_b, _ := atoms_of_set(set_of_ints(b.ints), 64)
				for x in atoms_a do for y in atoms_b {
					p, q := x.(i128), y.(i128)
					v := op == .Add ? p + q : (op == .Sub ? p - q : p * q)
					testing.expectf(t, ints_contains(r.ints, v), "entiers : %d %v %d", p, op, q)
				}
			}
			if op == .Add && textual(a) && textual(b) {
				testing.expect(t, strings_equal(r.strings, strings_concat(as_strings(a), as_strings(b))), "+ concatène, les caractères comptant comme des chaînes")
			}
			if op == .Mul && textual(a) && has(b, .Ints) {
				words, _ := strings_words(as_strings(a), 64)
				counts, _ := atoms_of_set(set_of_ints(ints_intersect(b.ints, ints_range(0, 3))), 64)
				for w in words do for n in counts do testing.expectf(t, strings_contains(r.strings, strings.repeat(w, int(n.(i128)))), "%q * %v", w, n)
			}
		}
	}
}

// --- les intervalles, toutes sortes ---

@(test)
test_law_ranges :: proc(t: ^testing.T) {
	arena: vmem.Arena
	context.allocator = vmem.arena_allocator(&arena)
	defer vmem.arena_destroy(&arena)
	state: rand.Default_Random_State
	gen := seeded(&state, 17)
	universe := all_words()
	for _ in 0 ..< ROUNDS {
		// entiers : l'enveloppe des bornes, à l'endroit ou à l'envers, chaînées
		lo, hi := small_ints(gen), small_ints(gen)
		r, status := range_set(set_of_ints(lo), false, set_of_ints(hi), false)
		l1, h1 := ints_bounds(lo)
		l2, h2 := ints_bounds(hi)
		want := ints_range(min(l1.?, l2.?), max(h1.?, h2.?))
		testing.expectf(t, status == .Ok && same_ints(r.ints, want), "%v..%v", lo, hi)
		open_hi, _ := range_set(set_of_ints(lo), false, Set{}, true)
		testing.expect(t, same_ints(open_hi.ints, ints_range(l1.?, nil)), "lo..")
		// caractères : la plage, ouverte vers '' ou vers le dernier caractère
		a, b := i128(rand.int_range('a', 'z', gen)), i128(rand.int_range('a', 'z', gen))
		cr, _ := range_set(set_of_chars(ints_point(a)), false, set_of_chars(ints_point(b)), false)
		testing.expect(t, same_ints(cr.chars, ints_range(min(a, b), max(a, b))), "'a'..'z'")
		from_empty, _ := range_set(Set{}, true, set_of_chars(ints_point(b)), false)
		testing.expect(t, same_ints(from_empty.chars, ints_range(CHAR_EMPTY, b)), "..'z' part du caractère vide")
		// chaînes : commence par un mot de lo, finit par un mot de hi
		pl, sl := strings_of_words(small_words(gen)), strings_of_words(small_words(gen))
		sr, _ := range_set(set_of_strings(pl), false, set_of_strings(sl), false)
		for w in universe {
			starts, ends := false, false
			for p in small_words_of(pl) do starts ||= strings.has_prefix(w, p)
			for s in small_words_of(sl) do ends ||= strings.has_suffix(w, s)
			testing.expectf(t, strings_contains(sr.strings, w) == (starts && ends), "%q dans %s..%s", w, print_strings(pl), print_strings(sl))
		}
		// des sortes différentes : pas un intervalle
		_, bad := range_set(set_of_ints(lo), false, set_of_strings(pl), false)
		testing.expect(t, bad != .Ok, "un intervalle entre un entier et une chaîne")
	}
	top, _ := range_set(Set{}, true, Set{}, true)
	testing.expect(t, set_equal(top, set_top()), ".. est tout")
}

small_words_of :: proc(s: Strings) -> []string {
	w, _ := strings_words(s, 64)
	return w
}

// --- les demi-droites ---

@(test)
test_law_half_lines :: proc(t: ^testing.T) {
	arena: vmem.Arena
	context.allocator = vmem.arena_allocator(&arena)
	defer vmem.arena_destroy(&arena)
	kinds := []syn.Operator_Kind{.Greater, .GreaterEqual, .Less, .LessEqual, .NotEqual}
	for x in -5 ..= 5 do for kind in kinds {
		r, status := half_line(kind, set_of_ints(ints_point(i128(x))))
		testing.expect(t, status == .Ok, "demi-droite entière")
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
			testing.expectf(t, ints_contains(r.ints, i128(y)) == want, "%v %d en %d", kind, x, y)
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
			testing.expectf(t, floats_contains(fr.floats, y) == want, "%v %v en %v", kind, fx, y)
		}
	}
	_, status := half_line(.Greater, set_of_ints(ints_range(1, 2)))
	testing.expect(t, status != .Ok, ">x attend un seul nombre")
}

// --- les enveloppes : elles contiennent toujours l'ensemble réel ---

Sx :: struct {
	kind:  Set_Op_Kind,
	half:  syn.Operator_Kind,
	known: Set,
	leaf:  int, // 0 : l'inconnue n ; 1 : un ensemble connu ; 2 : une opération
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
	if x.kind == .Half do x.a.leaf = 0 // >n : la borne est l'inconnue
	return x
}

build_sx :: proc(k: ^Kernel, x: ^Sx, n: ^Expr) -> ^Expr {
	switch x.leaf {
	case 0:
		return n
	case 1:
		return singleton(new_expr(x.known))
	}
	op := Set_Op{kind = x.kind, half = x.half, arith = .Add}
	switch x.kind {
	case .Comp, .Half:
		return set_operation(k, op, {}, build_sx(k, x.a, n))
	case .Union, .Inter, .Arith, .Range:
	}
	return set_operation(k, op, {}, build_sx(k, x.a, n), build_sx(k, x.b, n))
}

@(test)
test_law_envelopes :: proc(t: ^testing.T) {
	arena: vmem.Arena
	context.allocator = vmem.arena_allocator(&arena)
	defer vmem.arena_destroy(&arena)
	state: rand.Default_Random_State
	gen := seeded(&state, 18)
	k: Kernel
	big := new_symbol(&k, set_of_ints(ints_range(-100_000, 100_000))) // trop grand pour énumérer
	enveloped_seen := 0
	for _ in 0 ..< ROUNDS {
		x := random_sx(gen, 3)
		clear(&k.errors)
		e := build_sx(&k, x, big)
		if len(k.errors) > 0 do continue
		upper, ok := upper_of(&k, e)
		testing.expect(t, ok, "toute forme d'ensemble a une enveloppe")
		if _, is_env := e^.(Subsets); is_env do enveloped_seen += 1
		for _ in 0 ..< 20 {
			v := i128(rand.int_range(-100_000, 100_001, gen))
			clear(&k.errors)
			exact := build_sx(&k, x, new_expr(set_of_ints(ints_point(v))))
			if len(k.errors) > 0 do continue
			s, known := known_set(exact)
			testing.expectf(t, known && set_subset(s, upper), "n = %d : %s ⊄ %s", v, print_expr(exact), print_set(upper))
		}
	}
	testing.expectf(t, enveloped_seen >= ROUNDS / 8, "enveloppes vérifiées : %d", enveloped_seen)
}

// --- les comparaisons qui ne sont pas entières ---

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
		testing.expect(t, status == .Ok, "comparaison valide")
		if status != .Ok do continue
		// la vérité, sur toutes les valeurs des inconnues
		syms := make([dynamic]int)
		collect_symbols(a, &syms)
		collect_symbols(b, &syms)
		slice.sort(syms[:])
		ids := slice.unique(syms[:])
		domains, _ := symbol_domains(&k, ids)
		digits := make([]int, len(ids))
		total := 1
		for dm in domains do total *= len(dm)
		seen: [2]bool
		for _ in 0 ..< total {
			env := make([]Atom, len(k.symbols))
			for id, i in ids do env[id] = domains[i][digits[i]]
			x, _ := eval(a, env)
			y, _ := eval(b, env)
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
			got, ok := eval(r, env)
			testing.expectf(t, ok && got.(bool) == truth, "%v de %s et %s", op, print_expr(a), print_expr(b))
			odometer(digits, domains)
		}
		_, decided := r^.(Set)
		testing.expectf(t, decided == !(seen[0] && seen[1]), "%v de %s et %s : décidé %v", op, print_expr(a), print_expr(b), decided)
	}
}

// --- les termes flottants : normalisés à la commutativité près, évalués exactement ---

Fx :: struct {
	op:   u8, // 0 feuille, '+', '-', '*', 'n' (négation)
	sym:  int, // -1 : constante
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
		testing.expectf(t, expr_equal(&k, e, fx_build(syms, x, true)), "commutativité : %s", print_expr(e))
		vals, _ := values_of(&k, e)
		for p in ([?][2]f64{{-2, 0.5}, {3, 4}, {0, 1}, {1.25, 2.5}, {-1, 3.75}}) {
			got, ok := eval(e, {p[0], p[1]})
			want := fx_eval(x, p)
			testing.expectf(t, ok && got.(f64) == want, "%s en %v : %v, attendu %v", print_expr(e), p, got, want)
			testing.expectf(t, floats_contains(vals.floats, want), "valeurs de %s : %v manque", print_expr(e), want)
		}
	}
}

// --- les mots de chaînes et les répétitions à compte inconnu ---

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
		// une suite de parties, concaténée de gauche à droite et de droite à gauche,
		// avec les littéraux coupés en morceaux d'un côté : une seule forme
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
		testing.expectf(t, expr_equal(&k, left, right), "%s et %s", print_expr(left), print_expr(right))
		// répétée un nombre inconnu de fois : la valeur et les valeurs possibles exactes
		rep, _ := repeat_term(&k, left, count)
		vals, exact := values_of(&k, rep)
		testing.expect(t, exact, "valeurs énumérées")
		for w in ([?]string{"x", "yy"}) do for c in ([?]rune{'p', 'q'}) do for n in 0 ..= 3 {
			env := []Atom{w, Char_Atom(c), i128(n)}
			one, ok := eval(left, env)
			testing.expect(t, ok, "évaluation du mot")
			word := atom_text(one)
			got, _ := eval(rep, env)
			testing.expectf(t, atom_text(got) == strings.repeat(word, n), "%s * %d", print_expr(left), n)
			testing.expectf(t, strings_contains(vals.strings, strings.repeat(word, n)), "valeurs de %s", print_expr(rep))
		}
	}
}

// --- les valeurs sur-approchées contiennent toujours la valeur réelle ---

@(test)
test_law_approximation :: proc(t: ^testing.T) {
	arena: vmem.Arena
	context.allocator = vmem.arena_allocator(&arena)
	defer vmem.arena_destroy(&arena)
	state: rand.Default_Random_State
	gen := seeded(&state, 22)
	k: Kernel
	for _ in 0 ..< 3 do append(&k.symbols, set_of_ints(ints_range(-1_000_000, 1_000_000)))
	for _ in 0 ..< ROUNDS {
		tree := random_tree(gen, 3)
		p := poly_type(tree_poly(tree))
		vals, exact := values_of(&k, p)
		if _, constant := p^.(Set); !constant do testing.expect(t, !exact, "trop grand : sur-approché")
		for _ in 0 ..< 30 {
			env := [3]i128{i128(rand.int_range(-1_000_000, 1_000_001, gen)), i128(rand.int_range(-1_000_000, 1_000_001, gen)), i128(rand.int_range(-1_000_000, 1_000_001, gen))}
			v := tree_eval(tree, env)
			testing.expectf(t, ints_contains(vals.ints, v), "%s en %v = %d hors de %v", print_expr(p), env, v, vals.ints)
		}
	}
}

// --- l'admission par une couleur d'atomes ---

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
			// un caractère est admis par une couleur de chaînes, comme une chaîne d'une lettre
			if ch, is_char := a.(Char_Atom); is_char && !inside do inside = strings_contains(c.strings, atom_text(ch))
			want &&= inside
		}
		if domain_count(tv, .Floats) > 0 do continue // des intervalles de réels : pas énumérables
		testing.expectf(t, atoms_admitted(tv, c) == want, "%s admis par %s : %v", print_set(tv), print_set(c), want)
	}
}
