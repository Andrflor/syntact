package kernel

import "base:runtime"
import "core:fmt"
import "core:math/rand"
import vmem "core:mem/virtual"
import "core:slice"
import "core:strings"
import "core:testing"

// LES LOIS. Chaque algèbre est confrontée à un modèle brut sur des cas tirés au
// hasard (graine fixe : les tests sont reproductibles). Les lois s'éprouvent par
// les décisions que le typecheck utilise — l'inclusion, l'égalité comme double
// inclusion — et, là où la forme normale est unique (intervalles, polynômes), par
// la structure elle-même.

ROUNDS :: 400

seeded :: proc(state: ^rand.Default_Random_State, seed: u64) -> runtime.Random_Generator {
	state^ = rand.create(seed)
	return rand.default_random_generator(state)
}

// --- entiers ---

random_ints :: proc(gen: runtime.Random_Generator) -> (Ints, []Int_Interval) {
	raw := make([dynamic]Int_Interval)
	for _ in 0 ..< rand.int_range(0, 4, gen) {
		lo: Maybe(i128) = i128(rand.int_range(-12, 13, gen))
		hi: Maybe(i128) = lo.? or_else 0 + i128(rand.int_range(-1, 7, gen))
		if rand.int_max(10, gen) == 0 do lo = nil
		if rand.int_max(10, gen) == 0 do hi = nil
		append(&raw, Int_Interval{lo, hi})
	}
	return ints_of(raw[:]), raw[:]
}

in_raw :: proc(raw: []Int_Interval, x: i128) -> bool {
	for iv in raw {
		if lo, ok := iv.lo.?; ok && x < lo do continue
		if hi, ok := iv.hi.?; ok && x > hi do continue
		return true
	}
	return false
}

INT_POINTS := [?]i128{-1000, -31, -20, -13, -12, -11, -7, -3, -2, -1, 0, 1, 2, 3, 5, 8, 12, 13, 14, 19, 20, 31, 1000}

same_ints :: proc(a, b: Ints) -> bool {
	return slice.equal(a.intervals, b.intervals)
}

is_normal :: proc(a: Ints) -> bool {
	for iv, i in a.intervals {
		lo, lo_ok := iv.lo.?
		hi, hi_ok := iv.hi.?
		if lo_ok && hi_ok && lo > hi do return false
		if i == 0 do continue
		prev_hi, prev_ok := a.intervals[i - 1].hi.?
		if !prev_ok || !lo_ok || prev_hi + 1 >= lo do return false
	}
	return true
}

@(test)
test_law_ints :: proc(t: ^testing.T) {
	arena: vmem.Arena
	context.allocator = vmem.arena_allocator(&arena)
	defer vmem.arena_destroy(&arena)
	state: rand.Default_Random_State
	gen := seeded(&state, 1)
	for _ in 0 ..< ROUNDS {
		a, ra := random_ints(gen)
		b, rb := random_ints(gen)
		testing.expectf(t, is_normal(a), "forme normale : %v", a)
		for x in INT_POINTS {
			testing.expectf(t, ints_contains(a, x) == in_raw(ra, x), "ints_of %v en %d", ra, x)
			testing.expectf(t, ints_contains(ints_union(a, b), x) == (in_raw(ra, x) || in_raw(rb, x)), "union en %d", x)
			testing.expectf(t, ints_contains(ints_intersect(a, b), x) == (in_raw(ra, x) && in_raw(rb, x)), "inter en %d", x)
			testing.expectf(t, ints_contains(ints_complement(a), x) == !in_raw(ra, x), "complément de %v en %d", ra, x)
		}
		subset := true
		for x in INT_POINTS do if in_raw(ra, x) && !in_raw(rb, x) do subset = false
		if !subset do testing.expectf(t, !ints_subset(a, b), "%v ⊄ %v", ra, rb)
		// la forme normale des intervalles est unique : les lois tiennent sur la structure
		testing.expect(t, same_ints(ints_union(a, b), ints_union(b, a)), "union commutative")
		testing.expect(t, same_ints(ints_intersect(a, b), ints_intersect(b, a)), "inter commutative")
		testing.expect(t, same_ints(ints_complement(ints_complement(a)), a), "~~a = a")
		testing.expect(t, same_ints(ints_complement(ints_union(a, b)), ints_intersect(ints_complement(a), ints_complement(b))), "De Morgan")
		testing.expect(t, ints_subset(ints_intersect(a, b), a), "a ∩ b ⊆ a")
	}
	// l'arithmétique d'intervalles contient toujours les résultats exacts
	for _ in 0 ..< ROUNDS {
		a := ints_range(i128(rand.int_range(-9, 9, gen)), nil)
		a = ints_intersect(a, ints_range(nil, i128(rand.int_range(-9, 9, gen))))
		b := ints_intersect(ints_range(i128(rand.int_range(-9, 9, gen)), nil), ints_range(nil, i128(rand.int_range(-9, 9, gen))))
		for op in Arith {
			r, _ := ints_arith(op, a, b)
			for x in -9 ..= 9 do for y in -9 ..= 9 {
				if !ints_contains(a, i128(x)) || !ints_contains(b, i128(y)) do continue
				v := op == .Add ? x + y : (op == .Sub ? x - y : x * y)
				testing.expectf(t, ints_contains(r, i128(v)), "%v %v %v ne contient pas %d", a, op, b, v)
			}
		}
		for n in 1 ..= 3 {
			r := ints_pow(a, n)
			for x in -9 ..= 9 {
				if !ints_contains(a, i128(x)) do continue
				p := 1
				for _ in 0 ..< n do p *= x
				testing.expectf(t, ints_contains(r, i128(p)), "%v^%d ne contient pas %d", a, n, p)
			}
		}
	}
	// les débordements deviennent des bornes infinies, jamais des valeurs fausses
	huge := ints_range(I128_MAX - 1, I128_MAX)
	product, product_exact := ints_arith(.Mul, huge, huge)
	sum, sum_exact := ints_arith(.Add, huge, huge)
	testing.expect(t, !product_exact && ints_contains(product, I128_MAX), "débordement de * : borne ouverte, signalé")
	testing.expect(t, !sum_exact && ints_contains(sum, I128_MAX), "débordement de + : borne ouverte, signalé")
	testing.expect(t, ints_contains(ints_pow(ints_range(-1_000_000_000_000, 1_000_000_000_000), 4), I128_MAX), "débordement de puissance")
}

// --- flottants ---

FLOAT_BOUNDS := [?]f64{-3, -2, -1, -0.5, 0, 0.5, 1, 2, 3}

random_floats :: proc(gen: runtime.Random_Generator) -> (Floats, []Float_Interval) {
	raw := make([dynamic]Float_Interval)
	for _ in 0 ..< rand.int_range(0, 4, gen) {
		iv := Float_Interval {
			lo      = rand.choice(FLOAT_BOUNDS[:], gen),
			hi      = rand.choice(FLOAT_BOUNDS[:], gen),
			lo_open = rand.int_max(2, gen) == 0,
			hi_open = rand.int_max(2, gen) == 0,
		}
		if rand.int_max(8, gen) == 0 do iv.lo = nil
		if rand.int_max(8, gen) == 0 do iv.hi = nil
		append(&raw, iv)
	}
	return floats_of(raw[:]), raw[:]
}

in_float_raw :: proc(raw: []Float_Interval, x: f64) -> bool {
	for iv in raw {
		if lo, ok := iv.lo.?; ok && (x < lo || (iv.lo_open && x == lo)) do continue
		if hi, ok := iv.hi.?; ok && (x > hi || (iv.hi_open && x == hi)) do continue
		return true
	}
	return false
}

same_floats :: proc(a, b: Floats) -> bool {
	return slice.equal(a.intervals, b.intervals)
}

@(test)
test_law_floats :: proc(t: ^testing.T) {
	arena: vmem.Arena
	context.allocator = vmem.arena_allocator(&arena)
	defer vmem.arena_destroy(&arena)
	state: rand.Default_Random_State
	gen := seeded(&state, 2)
	points := make([dynamic]f64)
	for x := -4.0; x <= 4.0; x += 0.25 do append(&points, x)
	append(&points, -1e9, 1e9)
	for _ in 0 ..< ROUNDS {
		a, ra := random_floats(gen)
		b, rb := random_floats(gen)
		for x in points {
			testing.expectf(t, floats_contains(a, x) == in_float_raw(ra, x), "floats_of %v en %v", ra, x)
			testing.expectf(t, floats_contains(floats_union(a, b), x) == (in_float_raw(ra, x) || in_float_raw(rb, x)), "union en %v", x)
			testing.expectf(t, floats_contains(floats_intersect(a, b), x) == (in_float_raw(ra, x) && in_float_raw(rb, x)), "inter en %v", x)
			testing.expectf(t, floats_contains(floats_complement(a), x) == !in_float_raw(ra, x), "complément de %v en %v", ra, x)
		}
		testing.expect(t, same_floats(floats_union(a, b), floats_union(b, a)), "union commutative")
		testing.expect(t, same_floats(floats_complement(floats_complement(a)), a), "~~a = a")
		if d, ok := floats_default(a); ok do testing.expectf(t, floats_contains(a, d), "le défaut %v de %v en fait partie", d, ra)
	}
	testing.expect(t, same_floats(floats_point(-0.0), floats_point(0.0)), "-0.0 s'écrit 0.0")
}

// --- chaînes : les décisions contre l'énumération des mots de longueur ≤ 5 ---

MAX_LEN :: 5
ALPHABET :: "abc"

all_words :: proc() -> []string {
	out := make([dynamic]string)
	append(&out, "")
	for i := 0; i < len(out); i += 1 {
		if len(out[i]) == MAX_LEN do continue
		for c in ALPHABET do append(&out, fmt.tprintf("%s%c", out[i], c))
	}
	return out[:]
}

Words :: map[string]bool

Lang :: struct {
	lang:  Strings,
	words: Words, // le langage restreint aux mots de longueur ≤ MAX_LEN sur ALPHABET
	text:  string,
}

words_of :: proc(ws: []string) -> Words {
	m := make(Words)
	for w in ws do m[w] = true
	return m
}

random_lang :: proc(gen: runtime.Random_Generator, universe: []string, depth: int) -> Lang {
	pick := depth <= 0 ? rand.int_max(3, gen) : rand.int_max(10, gen)
	switch pick {
	case 0:
		w := rand.choice([]string{"", "a", "b", "ab", "ba", "c", "aa"}, gen)
		return Lang{strings_point(w), words_of({w}), fmt.tprintf("%q", w)}
	case 1:
		return Lang{strings_runes('a', 'b'), words_of({"a", "b"}), "'a'..'b'"}
	case 2:
		return Lang{strings_runes('b', 'c'), words_of({"b", "c"}), "'b'..'c'"}
	case 3:
		x, y := random_lang(gen, universe, depth - 1), random_lang(gen, universe, depth - 1)
		m := make(Words)
		for w in x.words do m[w] = true
		for w in y.words do m[w] = true
		return Lang{strings_union(x.lang, y.lang), m, fmt.tprintf("(%s | %s)", x.text, y.text)}
	case 4:
		x, y := random_lang(gen, universe, depth - 1), random_lang(gen, universe, depth - 1)
		m := make(Words)
		for w in x.words do if y.words[w] do m[w] = true
		return Lang{strings_intersect(x.lang, y.lang), m, fmt.tprintf("(%s & %s)", x.text, y.text)}
	case 5:
		x := random_lang(gen, universe, depth - 1)
		m := make(Words)
		for w in universe do if !x.words[w] do m[w] = true
		return Lang{strings_complement(x.lang), m, fmt.tprintf("~%s", x.text)}
	case 6:
		x, y := random_lang(gen, universe, depth - 1), random_lang(gen, universe, depth - 1)
		return Lang{strings_concat(x.lang, y.lang), cat_words(x.words, y.words), fmt.tprintf("(%s + %s)", x.text, y.text)}
	case 7:
		x := random_lang(gen, universe, depth - 1)
		lo := rand.int_range(0, 3, gen)
		bounded := rand.int_max(2, gen) == 0
		hi := lo + rand.int_range(0, 3, gen)
		counts := bounded ? ints_range(i128(lo), i128(hi)) : ints_range(i128(lo), nil)
		r, _ := strings_repeat(x.lang, counts)
		m := make(Words)
		top := bounded ? hi : max(lo, MAX_LEN) + 1
		for n in lo ..= top {
			p := words_of({""})
			for _ in 0 ..< n do p = cat_words(p, x.words)
			for w in p do m[w] = true
		}
		return Lang{r, m, fmt.tprintf("(%s * %v)", x.text, counts)}
	case 8:
		x := random_lang(gen, universe, depth - 1)
		return Lang{strings_prefixed(x.lang), cat_words(x.words, words_of(universe)), fmt.tprintf("(%s..)", x.text)}
	case 9:
		x := random_lang(gen, universe, depth - 1)
		return Lang{strings_suffixed(x.lang), cat_words(words_of(universe), x.words), fmt.tprintf("(..%s)", x.text)}
	}
	return {}
}

cat_words :: proc(a, b: Words) -> Words {
	m := make(Words)
	for u in a do for v in b do if len(u) + len(v) <= MAX_LEN do m[strings.concatenate({u, v})] = true
	return m
}

@(test)
test_law_strings :: proc(t: ^testing.T) {
	arena: vmem.Arena
	context.allocator = vmem.arena_allocator(&arena)
	defer vmem.arena_destroy(&arena)
	state: rand.Default_Random_State
	gen := seeded(&state, 3)
	universe := all_words()
	for _ in 0 ..< ROUNDS / 2 {
		a := random_lang(gen, universe, 3)
		b := random_lang(gen, universe, 2)
		c := random_lang(gen, universe, 2)
		// l'expression reconnaît exactement le langage
		for w in universe {
			if strings_contains(a.lang, w) != a.words[w] {
				testing.expectf(t, false, "%s : %q %v", a.text, w, a.words[w])
				break
			}
		}
		// les lois, décidées par double inclusion
		testing.expectf(t, strings_equal(strings_union(a.lang, b.lang), strings_union(b.lang, a.lang)), "union commutative : %s, %s", a.text, b.text)
		testing.expectf(t, strings_equal(strings_intersect(a.lang, b.lang), strings_intersect(b.lang, a.lang)), "inter commutative : %s, %s", a.text, b.text)
		testing.expectf(t, strings_equal(strings_complement(strings_complement(a.lang)), a.lang), "~~a = a : %s", a.text)
		testing.expectf(t, strings_equal(strings_union(a.lang, a.lang), a.lang), "a | a = a : %s", a.text)
		testing.expectf(
			t,
			strings_equal(strings_intersect(a.lang, strings_union(b.lang, c.lang)), strings_union(strings_intersect(a.lang, b.lang), strings_intersect(a.lang, c.lang))),
			"distributivité : %s, %s, %s", a.text, b.text, c.text,
		)
		testing.expectf(
			t,
			strings_equal(strings_complement(strings_union(a.lang, b.lang)), strings_intersect(strings_complement(a.lang), strings_complement(b.lang))),
			"De Morgan : %s, %s", a.text, b.text,
		)
		testing.expectf(
			t,
			strings_equal(strings_concat(strings_concat(a.lang, b.lang), c.lang), strings_concat(a.lang, strings_concat(b.lang, c.lang))),
			"concaténation associative : %s, %s, %s", a.text, b.text, c.text,
		)
		testing.expectf(t, strings_equal(strings_concat(a.lang, strings_empty_word()), a.lang), "a + \"\" = a : %s", a.text)
		rep, _ := strings_repeat(a.lang, ints_range(0, 2))
		testing.expectf(t, strings_equal(rep, strings_union(strings_empty_word(), strings_union(a.lang, strings_concat(a.lang, a.lang)))), "a * 0..2 : %s", a.text)
		testing.expect(t, strings_subset(strings_intersect(a.lang, b.lang), a.lang), "a & b ⊆ a")
		// comptage, mot unique, défaut
		short := make([dynamic]string)
		for w in a.words do append(&short, w)
		slice.sort_by(short[:], proc(x, y: string) -> bool {return len(x) != len(y) ? len(x) < len(y) : x < y})
		n := strings_count(a.lang)
		if len(short) > 0 do testing.expectf(t, n >= 1, "%s a des mots", a.text)
		if n == 0 do testing.expectf(t, len(short) == 0, "%s est vide", a.text)
		if n == 1 && len(short) == 1 {
			w, _ := strings_single(a.lang)
			testing.expectf(t, w == short[0], "%s : mot unique %q", a.text, short[0])
		}
		if len(short) > 0 && !strings.contains_any(a.text, "~") {
			d, _ := strings_default(a.lang)
			testing.expectf(t, d == short[0], "%s : défaut %q, attendu %q", a.text, d, short[0])
		}
	}
	testing.expect(t, strings_count(Strings{}) == 0 && strings_count(strings_empty_word()) == 1, "∅ ≠ {\"\"}")
	testing.expect(t, strings_equal(strings_prefixed(strings_empty_word()), strings_all()), "\"\".. est toute chaîne")
	testing.expect(t, strings_equal(strings_of_words({"ba", "a", "ab"}), strings_union(strings_point("ab"), strings_union(strings_point("a"), strings_point("ba")))), "arbre de mots")
}

// --- caractères ---

@(test)
test_law_chars :: proc(t: ^testing.T) {
	arena: vmem.Arena
	context.allocator = vmem.arena_allocator(&arena)
	defer vmem.arena_destroy(&arena)
	empty := set_of_chars(ints_point(CHAR_EMPTY))
	a := set_of_chars(ints_range('a', 'c'))
	comp := set_complement(a)
	testing.expect(t, ints_contains(comp.chars, CHAR_EMPTY), "~'a'..'c' contient le caractère vide")
	testing.expect(t, ints_contains(comp.chars, i128(MAX_RUNE)) && !ints_contains(comp.chars, i128(MAX_RUNE) + 1), "le complément reste dans les caractères")
	testing.expect(t, strings_count(comp.strings) == 0, "le complément d'un caractère n'est pas une chaîne")
	testing.expect(t, set_equal(set_complement(comp), a), "~~a = a")
	lifted := chars_as_strings(set_union(a, empty).chars)
	testing.expect(t, strings_equal(lifted, strings_of_words({"", "a", "b", "c"})), "les caractères comme chaînes, '' comme \"\"")
	testing.expect(t, atoms_admitted(a, set_of_strings(strings_all())), "string admet les caractères")
	testing.expect(t, !atoms_admitted(set_of_strings(strings_point("a")), set_of_chars(chars_all())), "char n'admet pas \"a\"")
	testing.expect(t, !set_equal(set_of_chars(ints_point('a')), set_of_strings(strings_point("a"))), "'a' et \"a\" sont deux valeurs")
}

// --- polynômes : forme normale contre l'évaluation directe ---

Tree :: struct {
	op:          u8, // 0 feuille, '+', '-', '*'
	leaf_sym:    int, // -1 : constante
	leaf_const:  i128,
	left, right: ^Tree,
}

random_tree :: proc(gen: runtime.Random_Generator, depth: int) -> ^Tree {
	t := new(Tree)
	if depth == 0 || rand.int_max(3, gen) == 0 {
		t.leaf_sym = rand.int_range(-1, 3, gen)
		t.leaf_const = i128(rand.int_range(-3, 4, gen))
		return t
	}
	t.op = rand.choice([]u8{'+', '-', '*'}, gen)
	t.left = random_tree(gen, depth - 1)
	t.right = random_tree(gen, depth - 1)
	return t
}

// mirror : la même expression, opérandes des opérations commutatives échangés.
mirror :: proc(t: ^Tree) -> ^Tree {
	if t.op == 0 || t.op == '-' {
		if t.op == 0 do return t
		m := new(Tree)
		m^ = t^
		m.left, m.right = mirror(t.left), mirror(t.right)
		return m
	}
	m := new(Tree)
	m^ = t^
	m.left, m.right = mirror(t.right), mirror(t.left)
	return m
}

tree_poly :: proc(t: ^Tree) -> Poly {
	if t.op == 0 {
		if t.leaf_sym < 0 do return Poly{const = t.leaf_const}
		return poly_var(t.leaf_sym)
	}
	a, b := tree_poly(t.left), tree_poly(t.right)
	r: Poly
	switch t.op {
	case '+':
		r, _ = poly_add(a, b)
	case '-':
		r, _ = poly_sub(a, b)
	case:
		r, _ = poly_mul(a, b)
	}
	return r
}

tree_eval :: proc(t: ^Tree, env: [3]i128) -> i128 {
	if t.op == 0 do return t.leaf_sym < 0 ? t.leaf_const : env[t.leaf_sym]
	a, b := tree_eval(t.left, env), tree_eval(t.right, env)
	switch t.op {
	case '+':
		return a + b
	case '-':
		return a - b
	}
	return a * b
}

@(test)
test_law_polynomials :: proc(t: ^testing.T) {
	arena: vmem.Arena
	context.allocator = vmem.arena_allocator(&arena)
	defer vmem.arena_destroy(&arena)
	state: rand.Default_Random_State
	gen := seeded(&state, 4)
	k: Kernel
	for _ in 0 ..< 3 do append(&k.symbols, set_of_ints(ints_range(-3, 3)))
	for _ in 0 ..< ROUNDS {
		tree := random_tree(gen, 3)
		p := poly_type(tree_poly(tree))
		// la forme normale ne dépend pas de l'ordre des opérandes
		testing.expect(t, expr_equal(&k, p, poly_type(tree_poly(mirror(tree)))), "commutativité")
		// elle vaut l'expression en tout point, et ses valeurs sont exactes
		brute := make([dynamic]Atom)
		for x in -3 ..= 3 do for y in -3 ..= 3 do for z in -3 ..= 3 {
			env := [3]i128{i128(x), i128(y), i128(z)}
			v, ok := eval(p, {env[0], env[1], env[2]})
			testing.expectf(t, ok && v.(i128) == tree_eval(tree, env), "évaluation de %s", print_expr(p))
			append(&brute, tree_eval(tree, env))
		}
		vals, exact := values_of(&k, p)
		testing.expectf(t, exact && set_equal(vals, set_of_atoms(brute[:])), "valeurs de %s", print_expr(p))
		// une comparaison est décidée exactement quand sa vérité ne varie pas
		for op in ([?]Compare_Op{.Lt, .Le, .Gt, .Ge, .Eq, .Ne}) {
			r, _ := int_compare(&k, op, tree_poly(tree))
			seen: [2]bool
			for x in -3 ..= 3 do for y in -3 ..= 3 do for z in -3 ..= 3 {
				v := tree_eval(tree, {i128(x), i128(y), i128(z)})
				truth: bool
				switch op {
				case .Lt:
					truth = v < 0
				case .Le:
					truth = v <= 0
				case .Gt:
					truth = v > 0
				case .Ge:
					truth = v >= 0
				case .Eq:
					truth = v == 0
				case .Ne:
					truth = v != 0
				}
				seen[int(truth)] = true
				// la forme écrite garde la même vérité
				got, ok := eval(r, {i128(x), i128(y), i128(z)})
				testing.expectf(t, ok && got.(bool) == truth, "%v de %s en (%d,%d,%d)", op, print_expr(p), x, y, z)
			}
			_, decided := r^.(Set)
			testing.expectf(t, decided == !(seen[0] && seen[1]), "%v de %s : décidé %v", op, print_expr(p), decided)
		}
	}
	// des identités : une seule forme
	a, b := poly_var(0), poly_var(1)
	s, _ := poly_add(a, b)
	d, _ := poly_sub(a, b)
	l, _ := poly_mul(s, d)
	aa, _ := poly_mul(a, a)
	bb, _ := poly_mul(b, b)
	r, _ := poly_sub(aa, bb)
	testing.expect(t, expr_equal(&k, poly_type(l), poly_type(r)), "(a+b)(a-b) = a² - b²")
	z, _ := poly_sub(a, a)
	testing.expect(t, expr_equal(&k, poly_type(z), new_expr(set_of_ints(ints_point(0)))), "a - a = 0")
}

// --- les ensembles qui dépendent d'inconnues : la table contre le calcul direct ---

@(test)
test_law_families :: proc(t: ^testing.T) {
	arena: vmem.Arena
	context.allocator = vmem.arena_allocator(&arena)
	defer vmem.arena_destroy(&arena)
	state: rand.Default_Random_State
	gen := seeded(&state, 5)
	k: Kernel
	append(&k.symbols, set_of_ints(ints_range(0, 3)))
	append(&k.symbols, set_of_ints(ints_range(5, 6)))
	known := [?]Set{set_of_ints(ints_range(0, 4)), set_of_ints(ints_point(6)), set_of_ints(ints_range(2, 9)), Set{}}
	checked, families := 0, 0
	for _ in 0 ..< ROUNDS {
		// une expression d'ensembles aléatoire, évaluée de deux façons
		build :: proc(k: ^Kernel, gen: runtime.Random_Generator, known: []Set, depth: int) -> (^Expr, [dynamic]Set) {
			// le résultat attendu pour chaque (n, m), n ∈ 0..3, m ∈ 5..6, dans l'ordre de l'odomètre
			expected := make([dynamic]Set)
			pick := depth == 0 ? rand.int_max(3, gen) : rand.int_max(7, gen)
			switch pick {
			case 0, 1:
				id := pick
				for m in i128(5) ..= 6 do for n in i128(0) ..= 3 do append(&expected, set_of_ints(ints_point(id == 0 ? n : m)))
				return new_expr(poly_var(id)), expected
			case 2:
				s := rand.choice(known, gen)
				for _ in 0 ..< 8 do append(&expected, s)
				return singleton(new_expr(s)), expected
			}
			a, ea := build(k, gen, known, depth - 1)
			b, eb := build(k, gen, known, depth - 1)
			op: Set_Op
			switch pick {
			case 3:
				op = Set_Op{kind = .Union}
			case 4:
				op = Set_Op{kind = .Inter}
			case 5:
				op = Set_Op{kind = .Range}
			case 6:
				op = Set_Op{kind = .Comp}
			}
			args := op.kind == .Comp ? []^Expr{a} : []^Expr{a, b}
			r := set_operation(k, op, {}, ..args)
			for i in 0 ..< 8 {
				operands := op.kind == .Comp ? []Set{ea[i]} : []Set{ea[i], eb[i]}
				v, status := apply_set_op(op, operands)
				if status != .Ok do v = Set{ints = ints_point(-999)} // marqueur : l'opération est invalide
				append(&expected, v)
			}
			return r, expected
		}
		clear(&k.errors)
		e, expected := build(&k, gen, known[:], 3)
		if len(k.errors) > 0 do continue // une plage entre sortes différentes : signalée, pas un résultat
		checked += 1
		// la table, ou l'ensemble constant, vaut le calcul direct pour chaque (n, m)
		for m in i128(5) ..= 6 do for n in i128(0) ..= 3 {
			i := int(m - 5) * 4 + int(n)
			got: Set
			#partial switch v in e^ {
			case Family:
				digits := make([]int, len(v.syms))
				for id, j in v.syms do digits[j] = id == 0 ? int(n) : int(m - 5)
				doms := make([][]Atom, len(v.syms))
				for id, j in v.syms do doms[j], _ = atoms_of_set(k.symbols[id], 100)
				got = v.sets[sub_index(v, v.syms, doms, digits)]
			case:
				got, _ = known_set(e)
				if p, ok := e^.(Poly); ok do got = set_of_ints(ints_point(p.monos[0].vars[0] == 0 ? n : m))
			}
			testing.expectf(t, set_equal(got, expected[i]) && set_is_empty(got) == set_is_empty(expected[i]), "%s en n=%d m=%d : %s attendu %s", print_expr(e), n, m, print_set(got), print_set(expected[i]))
		}
		if _, is_family := e^.(Family); is_family do families += 1
	}
	// le test ne passe pas à vide : assez de cas vérifiés, dont de vraies tables
	testing.expectf(t, checked >= ROUNDS / 2 && families >= ROUNDS / 8, "cas vérifiés : %d, dont tables : %d", checked, families)
}

// --- LES FORMES NORMALES ET LES DÉCISIONS ---
//
// Les intervalles et les polynômes ont une forme normale unique : même structure
// ⇔ même ensemble, l'égalité étant décidée indépendamment de la structure. Les
// chaînes et les ensembles mixtes n'en promettent pas : on éprouve directement la
// décision d'inclusion, sur des paires égales par une loi et contre un modèle.

// split_ints : le même ensemble, écrit en morceaux mélangés.
split_ints :: proc(gen: runtime.Random_Generator, raw: []Int_Interval) -> []Int_Interval {
	out := make([dynamic]Int_Interval)
	for iv in raw {
		lo, lo_ok := iv.lo.?
		hi, hi_ok := iv.hi.?
		if lo_ok && hi_ok && hi > lo {
			m := lo + i128(rand.int_max(int(hi - lo), gen))
			append(&out, Int_Interval{lo, m}, Int_Interval{m + 1, hi}, Int_Interval{m, m})
		} else {
			append(&out, iv)
		}
	}
	rand.shuffle(out[:], gen)
	return out[:]
}

@(test)
test_normal_ints :: proc(t: ^testing.T) {
	arena: vmem.Arena
	context.allocator = vmem.arena_allocator(&arena)
	defer vmem.arena_destroy(&arena)
	state: rand.Default_Random_State
	gen := seeded(&state, 6)
	equal_pairs := 0
	for _ in 0 ..< ROUNDS * 2 {
		a, ra := random_ints(gen)
		x, _ := random_ints(gen)
		b: Ints
		switch rand.int_max(6, gen) {
		case 0:
			b = ints_of(split_ints(gen, ra))
		case 1:
			b = ints_union(a, ints_intersect(a, x)) // absorption
		case 2:
			b = ints_union(ints_intersect(a, x), ints_intersect(a, ints_complement(x)))
		case 3:
			b = ints_complement(ints_complement(a))
		case:
			b, _ = random_ints(gen)
		}
		semantic := ints_subset(a, b) && ints_subset(b, a)
		if semantic do equal_pairs += 1
		testing.expectf(t, same_ints(a, b) == semantic, "%v et %v : structure %v, ensembles égaux %v", a, b, same_ints(a, b), semantic)
	}
	testing.expectf(t, equal_pairs >= ROUNDS, "paires égales : %d", equal_pairs)
}

split_floats :: proc(gen: runtime.Random_Generator, raw: []Float_Interval) -> []Float_Interval {
	out := make([dynamic]Float_Interval)
	for iv in raw {
		lo, lo_ok := iv.lo.?
		hi, hi_ok := iv.hi.?
		if lo_ok && hi_ok && hi > lo {
			m := (lo + hi) / 2
			cut := rand.int_max(2, gen) == 0
			append(&out, Float_Interval{lo, m, iv.lo_open, cut}, Float_Interval{m, hi, !cut, iv.hi_open})
		} else {
			append(&out, iv)
		}
	}
	rand.shuffle(out[:], gen)
	return out[:]
}

@(test)
test_normal_floats :: proc(t: ^testing.T) {
	arena: vmem.Arena
	context.allocator = vmem.arena_allocator(&arena)
	defer vmem.arena_destroy(&arena)
	state: rand.Default_Random_State
	gen := seeded(&state, 7)
	equal_pairs := 0
	for _ in 0 ..< ROUNDS * 2 {
		a, ra := random_floats(gen)
		x, _ := random_floats(gen)
		b: Floats
		switch rand.int_max(6, gen) {
		case 0:
			b = floats_of(split_floats(gen, ra))
		case 1:
			b = floats_union(a, floats_intersect(a, x))
		case 2:
			b = floats_union(floats_intersect(a, x), floats_intersect(a, floats_complement(x)))
		case 3:
			b = floats_complement(floats_complement(a))
		case:
			b, _ = random_floats(gen)
		}
		semantic := floats_subset(a, b) && floats_subset(b, a)
		if semantic do equal_pairs += 1
		testing.expectf(t, same_floats(a, b) == semantic, "%v et %v : structure %v, ensembles égaux %v", a, b, same_floats(a, b), semantic)
	}
	testing.expectf(t, equal_pairs >= ROUNDS, "paires égales : %d", equal_pairs)
}

// law_pair : deux écritures du même langage, par une loi tirée au hasard.
law_pair :: proc(gen: runtime.Random_Generator, universe: []string) -> (a, b: Strings, law: string) {
	a = random_lang(gen, universe, 3).lang
	x := random_lang(gen, universe, 2).lang
	y := random_lang(gen, universe, 2).lang
	switch rand.int_max(6, gen) {
	case 0:
		return a, strings_union(a, strings_intersect(a, x)), "absorption"
	case 1:
		return a, strings_union(strings_intersect(a, x), strings_intersect(a, strings_complement(x))), "partition"
	case 2:
		return a, strings_complement(strings_complement(a)), "~~a"
	case 3:
		return a, strings_concat(strings_empty_word(), a), "\"\" + a"
	case 4:
		return strings_concat(strings_concat(a, x), y), strings_concat(a, strings_concat(x, y)), "associativité"
	}
	r, _ := strings_repeat(a, ints_range(0, 2))
	b, _ = strings_repeat(a, ints_range(1, 3))
	return strings_concat(a, r), b, "a + a * 0..2"
}

@(test)
test_decide_strings :: proc(t: ^testing.T) {
	arena: vmem.Arena
	context.allocator = vmem.arena_allocator(&arena)
	defer vmem.arena_destroy(&arena)
	state: rand.Default_Random_State
	gen := seeded(&state, 8)
	universe := all_words()
	refuted, included := 0, 0
	for _ in 0 ..< ROUNDS {
		a, b, law := law_pair(gen, universe)
		testing.expectf(t, strings_equal(a, b), "%s : %s et %s", law, print_strings(a), print_strings(b))
		// une inclusion décidée vaut sur les mots courts ; une inclusion refusée a un
		// témoin, dans a et hors de b
		x := random_lang(gen, universe, 3)
		y := random_lang(gen, universe, 3)
		if strings_subset(x.lang, y.lang) {
			included += 1
			for w in x.words do testing.expectf(t, y.words[w], "%s ⊆ %s, mais pas %q", x.text, y.text, w)
		} else {
			refuted += 1
			w, ok := strings_default(strings_intersect(x.lang, strings_complement(y.lang)))
			testing.expectf(t, ok && strings_contains(x.lang, w) && !strings_contains(y.lang, w), "%s ⊄ %s : témoin %q", x.text, y.text, w)
		}
	}
	testing.expectf(t, refuted >= ROUNDS / 8 && included >= ROUNDS / 8, "inclusions refusées : %d, décidées : %d", refuted, included)
}

random_set :: proc(gen: runtime.Random_Generator, universe: []string) -> Set {
	s: Set
	if rand.int_max(2, gen) == 0 do s.ints, _ = random_ints(gen)
	if rand.int_max(3, gen) == 0 do s.floats, _ = random_floats(gen)
	if rand.int_max(3, gen) == 0 do s.chars = ints_intersect(ints_range(CHAR_EMPTY, 'z'), ints_range(i128(rand.int_range(90, 110, gen)), nil))
	if rand.int_max(3, gen) == 0 do s.strings = random_lang(gen, universe, 2).lang
	if rand.int_max(3, gen) == 0 do s.bools = rand.choice([]Bools{{}, {.True}, {.False}, {.False, .True}}, gen)
	return s
}

// sample_atoms : des atomes de chaque sorte, pour comparer deux ensembles point par point.
sample_atoms :: proc(universe: []string) -> []Atom {
	out := make([dynamic]Atom)
	for x in INT_POINTS do append(&out, x)
	for x in FLOAT_BOUNDS do append(&out, x, x + 0.25)
	append(&out, Char_Atom(CHAR_EMPTY))
	for c in i128(85) ..= 125 do append(&out, Char_Atom(c))
	for w in universe do append(&out, w)
	append(&out, false, true)
	return out[:]
}

has_atom :: proc(s: Set, a: Atom) -> bool {
	return set_subset(set_of_atoms({a}), s)
}

@(test)
test_decide_sets :: proc(t: ^testing.T) {
	arena: vmem.Arena
	context.allocator = vmem.arena_allocator(&arena)
	defer vmem.arena_destroy(&arena)
	state: rand.Default_Random_State
	gen := seeded(&state, 9)
	universe := all_words()
	atoms := sample_atoms(universe)
	for _ in 0 ..< ROUNDS {
		a := random_set(gen, universe)
		x := random_set(gen, universe)
		b: Set
		switch rand.int_max(3, gen) {
		case 0:
			b = set_union(a, set_intersect(a, x))
		case 1:
			b = set_intersect(set_union(a, x), a) // le complément ne vaut que dans les sortes de x : pas de partition ici
		case 2:
			b = set_union(x, a)
			a = set_union(a, x)
		}
		testing.expectf(t, set_equal(a, b), "%s et %s", print_set(a), print_set(b))
		// une inclusion décidée vaut en chaque point ; un point de x hors de y la refuse
		y := random_set(gen, universe)
		decided := set_subset(x, y)
		for p in atoms {
			if has_atom(x, p) && !has_atom(y, p) {
				testing.expectf(t, !decided, "%s ⊆ %s, mais pas %v", print_set(x), print_set(y), p)
				break
			}
		}
	}
}

// Les polynômes : même forme ⇔ même polynôme. L'identité est décidée sans la forme,
// par évaluation en des points tirés au hasard (Schwartz–Zippel : deux polynômes
// distincts de degré ≤ 8 coïncident rarement sur 8 points pris dans [-10⁴, 10⁴]³).
rewrite :: proc(gen: runtime.Random_Generator, t: ^Tree) -> ^Tree {
	if t.op == 0 do return t
	l, r := rewrite(gen, t.left), rewrite(gen, t.right)
	node :: proc(op: u8, l, r: ^Tree) -> ^Tree {
		n := new(Tree)
		n.op, n.left, n.right = op, l, r
		return n
	}
	switch {
	case t.op == '*' && (r.op == '+' || r.op == '-') && rand.int_max(2, gen) == 0:
		return node(r.op, node('*', l, r.left), node('*', l, r.right)) // a(b ± c) = ab ± ac
	case t.op == '-' && rand.int_max(2, gen) == 0:
		minus := new(Tree)
		minus.leaf_sym, minus.leaf_const = -1, -1
		return node('+', l, node('*', minus, r)) // a - b = a + (-1)b
	case t.op != '-' && rand.int_max(2, gen) == 0:
		return node(t.op, r, l) // commutativité
	}
	return node(t.op, l, r)
}

@(test)
test_normal_polynomials :: proc(t: ^testing.T) {
	arena: vmem.Arena
	context.allocator = vmem.arena_allocator(&arena)
	defer vmem.arena_destroy(&arena)
	state: rand.Default_Random_State
	gen := seeded(&state, 10)
	k: Kernel
	for _ in 0 ..< 3 do append(&k.symbols, set_of_ints(ints_range(-3, 3)))
	equal_pairs := 0
	for _ in 0 ..< ROUNDS {
		a := random_tree(gen, 3)
		b := rand.int_max(2, gen) == 0 ? rewrite(gen, a) : random_tree(gen, 3)
		identical := true
		for _ in 0 ..< 8 {
			env := [3]i128{i128(rand.int_range(-10_000, 10_000, gen)), i128(rand.int_range(-10_000, 10_000, gen)), i128(rand.int_range(-10_000, 10_000, gen))}
			if tree_eval(a, env) != tree_eval(b, env) do identical = false
		}
		if identical do equal_pairs += 1
		same := expr_equal(&k, poly_type(tree_poly(a)), poly_type(tree_poly(b)))
		testing.expectf(t, same == identical, "%s et %s : même forme %v, même polynôme %v", print_expr(poly_type(tree_poly(a))), print_expr(poly_type(tree_poly(b))), same, identical)
	}
	testing.expectf(t, equal_pairs >= ROUNDS / 3, "paires égales : %d", equal_pairs)
}

// Les tables : deux tables qui sont la même fonction ont la même écriture, même
// quand l'une a été construite avec une inconnue dont elle ne dépend pas.
@(test)
test_normal_families :: proc(t: ^testing.T) {
	arena: vmem.Arena
	context.allocator = vmem.arena_allocator(&arena)
	defer vmem.arena_destroy(&arena)
	k: Kernel
	append(&k.symbols, set_of_ints(ints_range(0, 3)))
	append(&k.symbols, set_of_ints(ints_range(5, 6)))
	n, m := new_expr(poly_var(0)), new_expr(poly_var(1))
	none := singleton(new_expr(Set{}))
	only_n := set_operation(&k, Set_Op{kind = .Union}, {}, n, singleton(new_expr(set_of_ints(ints_point(9)))))
	// la même table, construite en passant par m : (n | 9) | (m & ∅)
	through_m := set_operation(&k, Set_Op{kind = .Union}, {}, only_n, set_operation(&k, Set_Op{kind = .Inter}, {}, m, none))
	testing.expect(t, expr_equal(&k, only_n, through_m), "une inconnue inutile disparaît de la table")
	// et une table qui ne dépend de rien est son ensemble
	constant := set_operation(&k, Set_Op{kind = .Union}, {}, n, singleton(new_expr(set_of_ints(ints_range(0, 3)))))
	_, is_set := known_set(constant)
	testing.expect(t, is_set, "n | 0..3 est l'ensemble 0..3")
}

// --- la vérification par paliers : jamais « prouvé » ni « réfuté » à tort ---

@(test)
test_law_value_in :: proc(t: ^testing.T) {
	arena: vmem.Arena
	context.allocator = vmem.arena_allocator(&arena)
	defer vmem.arena_destroy(&arena)
	state: rand.Default_Random_State
	gen := seeded(&state, 16)
	k: Kernel
	domains := [3]Ints{ints_range(-3, 3), ints_range(0, 5), ints_range(2, 4)}
	for d in domains do append(&k.symbols, set_of_ints(d))
	decided := [Verdict]int{}
	for _ in 0 ..< ROUNDS {
		tree := random_tree(gen, 3)
		p := poly_type(tree_poly(tree))
		c, _ := random_ints(gen)
		all := true
		for x in -3 ..= 3 do for y in 0 ..= 5 do for z in 2 ..= 4 {
			if !ints_contains(c, tree_eval(tree, {i128(x), i128(y), i128(z)})) do all = false
		}
		v := admits(&k, new_expr(set_of_ints(c)), p)
		decided[v] += 1
		testing.expectf(t, v != .Proved || all, "%s ⊆ %v déclaré prouvé à tort", print_expr(p), c)
		testing.expectf(t, v != .Refuted || !all, "%s ⊆ %v déclaré réfuté à tort", print_expr(p), c)
		testing.expectf(t, v != .Undecided, "%s ⊆ %v : petit domaine, toujours décidé", print_expr(p), c)
	}
	testing.expectf(t, decided[.Proved] >= ROUNDS / 10 && decided[.Refuted] >= ROUNDS / 10, "verdicts : %v", decided)
}

// a·x + b sur un domaine trop grand pour être énuméré : le palier affine décide
// seul, et juste.
@(test)
test_law_affine :: proc(t: ^testing.T) {
	arena: vmem.Arena
	context.allocator = vmem.arena_allocator(&arena)
	defer vmem.arena_destroy(&arena)
	state: rand.Default_Random_State
	gen := seeded(&state, 17)
	N :: 100_000 // au-delà de la limite d'énumération
	k: Kernel
	append(&k.symbols, set_of_ints(ints_range(0, N)))
	x := poly_var(0)
	outcomes := [Verdict]int{}
	for _ in 0 ..< 60 {
		a := i128(rand.int_range(-7, 8, gen))
		if a == 0 do a = 3
		b := i128(rand.int_range(-20, 21, gen))
		ax, _ := poly_scale(x, a)
		p, _ := poly_add(ax, Poly{const = b})
		// une couleur à trous : tout sauf quelques points ou petits intervalles
		holes := make([dynamic]Int_Interval)
		for _ in 0 ..< rand.int_range(1, 4, gen) {
			at := i128(rand.int_range(-60, 61, gen)) * (rand.int_max(2, gen) == 0 ? 1 : a)
			append(&holes, Int_Interval{at, at + i128(rand.int_range(0, 2, gen))})
		}
		c := ints_complement(ints_of(holes[:]))
		all := true
		for v in 0 ..= N do if !ints_contains(c, a * i128(v) + b) {
			all = false
			break
		}
		r := admits(&k, new_expr(set_of_ints(c)), poly_type(p))
		outcomes[r] += 1
		testing.expectf(t, r == verdict(all), "%s ⊆ %v : %v, attendu %v", print_expr(poly_type(p)), c, r, verdict(all))
	}
	testing.expectf(t, outcomes[.Proved] > 0 && outcomes[.Refuted] > 0, "verdicts : %v", outcomes)
}
