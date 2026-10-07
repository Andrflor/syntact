package kernel

import "core:fmt"
import "core:slice"
import "core:strings"

// Les ensembles de chaînes : des langages réguliers. La forme canonique d'un
// langage est son automate déterministe minimal, sans état mort, dont les états
// sont numérotés en largeur depuis l'initial (0) en suivant les arêtes dans
// l'ordre des caractères. Deux langages égaux ont la même structure.
//
// L'algèbre est close : union, intersection, complément, concaténation (`+`),
// répétition par un ensemble de comptes (`L * 0..10`), intervalles de caractères
// (`'a'..'z'`) et de positions (`"jwt"..` commence par, `.."_"` finit par).

MAX_RUNE :: rune(0x10FFFF)

// Au-delà, une répétition n'est plus construite exactement : l'automate exact
// aurait autant d'états que de répétitions.
MAX_REPEAT :: 4096

Rune_Range :: struct {
	lo, hi: rune, // inclus
}

Edge :: struct {
	using range: Rune_Range,
	to:          int,
}

Dfa_State :: struct {
	accept: bool,
	edges:  []Edge, // triées, disjointes, les plages voisines vers le même état fusionnées
}

Strings :: struct {
	states: []Dfa_State, // vide : le langage vide
}

// --- constructions de base ---

// strings_point : le langage d'un seul mot.
strings_point :: proc(word: string) -> Strings {
	n: Nfa
	cur := nfa_add(&n)
	for r in word {
		next := nfa_add(&n)
		append(&n.states[cur].edges, Edge{{r, r}, next})
		cur = next
	}
	n.states[cur].accept = true
	return determinize(&n, 0)
}

// strings_runes : les mots d'un caractère compris dans [lo, hi].
strings_runes :: proc(lo, hi: rune) -> Strings {
	n: Nfa
	start := nfa_add(&n)
	end := nfa_add(&n, true)
	append(&n.states[start].edges, Edge{{min(lo, hi), max(lo, hi)}, end})
	return determinize(&n, start)
}

strings_all :: proc() -> Strings {
	return strings_complement(Strings{})
}

// strings_of_words : le langage fini de ces mots (un arbre de préfixes, minimisé).
strings_of_words :: proc(words: []string) -> Strings {
	if len(words) == 0 do return Strings{}
	n: Nfa
	root := nfa_add(&n)
	for w in words {
		cur := root
		for r in w {
			next := -1
			for e in n.states[cur].edges do if e.lo == r {
				next = e.to
				break
			}
			if next < 0 {
				next = nfa_add(&n)
				append(&n.states[cur].edges, Edge{{r, r}, next})
			}
			cur = next
		}
		n.states[cur].accept = true
	}
	return determinize(&n, root)
}

strings_empty_word :: proc() -> Strings {
	return strings_point("")
}

// --- algèbre de Boole ---

strings_union :: proc(a, b: Strings) -> Strings {
	return product(a, b, true)
}

strings_intersect :: proc(a, b: Strings) -> Strings {
	return product(a, b, false)
}

// Le complément dans l'ensemble de toutes les chaînes.
strings_complement :: proc(a: Strings) -> Strings {
	// Compléter l'automate avec un puits, puis inverser l'acceptation.
	n := len(a.states)
	raw := make([]Dfa_State, n + 1)
	sink := n
	for s, i in a.states {
		raw[i] = Dfa_State{!s.accept, fill_gaps(s.edges, sink)}
	}
	full := make([]Edge, 1)
	full[0] = Edge{{0, MAX_RUNE}, sink}
	raw[sink] = Dfa_State{true, full}
	if n == 0 do return minimize(raw[sink:], 0) // le complément du vide : tout
	return minimize(raw, 0)
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

strings_subset :: proc(a, b: Strings) -> bool {
	return len(strings_intersect(a, strings_complement(b)).states) == 0
}

strings_equal :: proc(a, b: Strings) -> bool {
	if len(a.states) != len(b.states) do return false
	for s, i in a.states {
		t := b.states[i]
		if s.accept != t.accept || len(s.edges) != len(t.edges) do return false
		for e, j in s.edges do if e != t.edges[j] do return false
	}
	return true
}

// --- concaténation, répétition, positions ---

strings_concat :: proc(a, b: Strings) -> Strings {
	if len(a.states) == 0 || len(b.states) == 0 do return Strings{}
	n: Nfa
	sa, acc_a := nfa_copy(&n, a)
	sb, acc_b := nfa_copy(&n, b)
	for q in acc_a {
		n.states[q].accept = false
		append(&n.states[q].eps, sb)
	}
	for q in acc_b do n.states[q].accept = true
	return determinize(&n, sa)
}

// strings_repeat : L^c pour tout compte c de `counts` (les comptes négatifs
// n'existent pas). `ok` est faux quand un compte fini est trop grand pour être
// construit exactement.
strings_repeat :: proc(a: Strings, counts: Ints) -> (Strings, bool) {
	natural := ints_intersect(counts, ints_range(0, nil))
	result := Strings{}
	for iv in natural.intervals {
		lo, _ := iv.lo.?
		hi, bounded := iv.hi.?
		if lo > MAX_REPEAT || (bounded && hi > MAX_REPEAT) do return {}, false
		part := power(a, int(lo))
		if bounded {
			optional := strings_union(a, strings_empty_word())
			part = strings_concat(part, power(optional, int(hi - lo)))
		} else {
			part = strings_concat(part, star(a))
		}
		result = strings_union(result, part)
	}
	return result, true
}

power :: proc(a: Strings, n: int) -> Strings {
	r := strings_empty_word()
	for _ in 0 ..< n do r = strings_concat(r, a)
	return r
}

star :: proc(a: Strings) -> Strings {
	n: Nfa
	start := nfa_add(&n, true)
	if len(a.states) == 0 do return determinize(&n, start)
	sa, acc := nfa_copy(&n, a)
	append(&n.states[start].eps, sa)
	for q in acc do append(&n.states[q].eps, start)
	return determinize(&n, start)
}

// "p".. : commence par un mot de p ; .."s" : finit par un mot de s.
strings_prefixed :: proc(p: Strings) -> Strings {
	return strings_concat(p, strings_all())
}

strings_suffixed :: proc(s: Strings) -> Strings {
	return strings_concat(strings_all(), s)
}

// --- lecture ---

strings_contains :: proc(a: Strings, word: string) -> bool {
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

// strings_count : le nombre de mots, saturé à 2. L'automate minimal n'a pas
// d'état mort : un cycle signifie une infinité de mots.
strings_count :: proc(a: Strings) -> int {
	if len(a.states) == 0 do return 0
	memo := make([]int, len(a.states))
	for &m in memo do m = -1
	on_path := make([]bool, len(a.states))
	count :: proc(a: Strings, s: int, memo: []int, on_path: []bool) -> int {
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

// strings_default : le plus court mot, et parmi eux le plus petit.
strings_default :: proc(a: Strings) -> (string, bool) {
	if len(a.states) == 0 do return "", false
	dist := distances_to_accept(a)
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

// strings_single : le mot unique d'un langage qui n'en a qu'un.
strings_single :: proc(a: Strings) -> (string, bool) {
	if strings_count(a) != 1 do return "", false
	return strings_default(a)
}

distances_to_accept :: proc(a: Strings) -> []int {
	dist := make([]int, len(a.states))
	for &d in dist do d = max(int)
	for s, i in a.states do if s.accept do dist[i] = 0
	changed := true
	for changed {
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
	return dist
}

// strings_words : tous les mots d'un langage fini, s'il en a au plus `limit`.
strings_words :: proc(a: Strings, limit: int) -> ([]string, bool) {
	out := make([dynamic]string)
	if len(a.states) == 0 do return out[:], true
	walk :: proc(a: Strings, s: int, prefix: ^strings.Builder, out: ^[dynamic]string, limit, depth: int) -> bool {
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
	slice.sort(out[:])
	return out[:], true
}

// --- automates non déterministes, déterminisation, minimisation ---

Nfa_State :: struct {
	accept: bool,
	edges:  [dynamic]Edge,
	eps:    [dynamic]int,
}

Nfa :: struct {
	states: [dynamic]Nfa_State,
}

nfa_add :: proc(n: ^Nfa, accept := false) -> int {
	append(&n.states, Nfa_State{accept = accept})
	return len(n.states) - 1
}

// nfa_copy recopie un automate dans `n` ; renvoie son état initial et ses états
// acceptants.
nfa_copy :: proc(n: ^Nfa, a: Strings) -> (start: int, accepts: []int) {
	base := len(n.states)
	acc := make([dynamic]int)
	for s, i in a.states {
		id := nfa_add(n, s.accept)
		for e in s.edges do append(&n.states[id].edges, Edge{e.range, base + e.to})
		if s.accept do append(&acc, base + i)
	}
	return base, acc[:]
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
determinize :: proc(n: ^Nfa, start: int) -> Strings {
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
		bounds_u := slice.unique(bounds[:])
		edges := make([dynamic]Edge)
		for b, j in bounds_u {
			hi := j + 1 < len(bounds_u) ? bounds_u[j + 1] - 1 : MAX_RUNE
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
	return minimize(raw[:], 0)
}

// minimize : retire les états inaccessibles et morts, fusionne les états
// équivalents (raffinement de partition), puis numérote en largeur.
minimize :: proc(raw: []Dfa_State, start: int) -> Strings {
	n := len(raw)
	if n == 0 do return Strings{}
	reach := make([]bool, n)
	stack := make([dynamic]int)
	reach[start] = true
	append(&stack, start)
	for len(stack) > 0 {
		s := pop(&stack)
		for e in raw[s].edges do if !reach[e.to] {
			reach[e.to] = true
			append(&stack, e.to)
		}
	}
	alive := make([]bool, n) // peut atteindre un état acceptant
	for s, i in raw do if s.accept && reach[i] do alive[i] = true
	changed := true
	for changed {
		changed = false
		for s, i in raw {
			if alive[i] || !reach[i] do continue
			for e in s.edges do if alive[e.to] {
				alive[i] = true
				changed = true
				break
			}
		}
	}
	if !alive[start] do return Strings{}
	useful := make([dynamic]int)
	for i in 0 ..< n do if reach[i] && alive[i] do append(&useful, i)

	class := make([]int, n)
	for i in useful do class[i] = raw[i].accept ? 1 : 0
	count := -1
	for {
		keys := make(map[string]int)
		next := make([]int, n)
		for i in useful {
			key := fmt.tprint(class[i], signature(raw[i].edges, class, alive))
			id, known := keys[key]
			if !known {
				id = len(keys)
				keys[key] = id
			}
			next[i] = id
		}
		class = next
		if len(keys) == count do break
		count = len(keys)
	}

	// Numérotation canonique : en largeur depuis l'initial, arêtes dans l'ordre.
	order := make(map[int]int) // classe → numéro
	queue := make([dynamic]int) // un représentant par classe
	order[class[start]] = 0
	append(&queue, start)
	for qi := 0; qi < len(queue); qi += 1 {
		for e in signature(raw[queue[qi]].edges, class, alive) {
			if _, seen := order[e.to]; !seen {
				order[e.to] = len(queue)
				for i in useful do if class[i] == e.to {
					append(&queue, i)
					break
				}
			}
		}
	}
	states := make([]Dfa_State, len(queue))
	for rep, i in queue {
		sig := signature(raw[rep].edges, class, alive)
		edges := make([]Edge, len(sig))
		for e, j in sig do edges[j] = Edge{e.range, order[e.to]}
		states[i] = Dfa_State{raw[rep].accept, edges}
	}
	return Strings{states}
}

// signature : les arêtes vers des états vivants, avec leur classe pour cible, les
// plages voisines vers la même classe fusionnées.
signature :: proc(edges: []Edge, class: []int, alive: []bool) -> []Edge {
	out := make([dynamic]Edge, 0, len(edges))
	for e in edges {
		if !alive[e.to] do continue
		c := class[e.to]
		if len(out) > 0 {
			last := &out[len(out) - 1]
			if last.to == c && last.hi + 1 == e.lo {
				last.hi = e.hi
				continue
			}
		}
		append(&out, Edge{e.range, c})
	}
	return out[:]
}

// product : l'automate des paires, pour l'union ou l'intersection.
product :: proc(a, b: Strings, union_: bool) -> Strings {
	Pair :: [2]int // -1 : l'état mort implicite
	raw := make([dynamic]Dfa_State)
	index := make(map[Pair]int)
	pairs := make([dynamic]Pair)
	start := Pair{len(a.states) > 0 ? 0 : -1, len(b.states) > 0 ? 0 : -1}
	if start == {-1, -1} do return Strings{}
	index[start] = 0
	append(&pairs, start)
	append(&raw, Dfa_State{})
	edges_of :: proc(x: Strings, s: int) -> []Edge {
		return s < 0 ? nil : x.states[s].edges
	}
	accepts :: proc(x: Strings, s: int) -> bool {
		return s >= 0 && x.states[s].accept
	}
	step :: proc(edges: []Edge, r: rune) -> int {
		for e in edges do if r >= e.lo && r <= e.hi do return e.to
		return -1
	}
	for i := 0; i < len(pairs); i += 1 {
		p := pairs[i]
		ea := edges_of(a, p[0])
		eb := edges_of(b, p[1])
		bounds := make([dynamic]rune)
		for e in ea {
			append(&bounds, e.lo)
			if e.hi < MAX_RUNE do append(&bounds, e.hi + 1)
		}
		for e in eb {
			append(&bounds, e.lo)
			if e.hi < MAX_RUNE do append(&bounds, e.hi + 1)
		}
		slice.sort(bounds[:])
		bounds_u := slice.unique(bounds[:])
		edges := make([dynamic]Edge)
		for r, j in bounds_u {
			hi := j + 1 < len(bounds_u) ? bounds_u[j + 1] - 1 : MAX_RUNE
			target := Pair{step(ea, r), step(eb, r)}
			if target == {-1, -1} do continue
			id, known := index[target]
			if !known {
				id = len(pairs)
				index[target] = id
				append(&pairs, target)
				append(&raw, Dfa_State{})
			}
			append(&edges, Edge{{r, hi}, id})
		}
		acc_a, acc_b := accepts(a, p[0]), accepts(b, p[1])
		raw[i] = Dfa_State{union_ ? acc_a || acc_b : acc_a && acc_b, edges[:]}
	}
	return minimize(raw[:], 0)
}

// --- impression ---

// print_strings : un langage fini et petit s'écrit par ses mots ; tout autre
// s'écrit par une expression tirée de l'automate canonique (élimination des
// états dans l'ordre canonique), donc unique elle aussi.
print_strings :: proc(a: Strings) -> string {
	if words, ok := strings_words(a, 8); ok {
		if len(words) == 0 do return ""
		parts := make([dynamic]string, 0, len(words))
		for w in words do append(&parts, fmt.tprintf("%q", w))
		return strings.join(parts[:], " | ")
	}
	if strings_equal(a, strings_all()) do return "string"
	return eliminate(a)
}

eliminate :: proc(a: Strings) -> string {
	n := len(a.states)
	S, F := n, n + 1
	R := make([][]Maybe(string), n + 2)
	for &row in R do row = make([]Maybe(string), n + 2)
	alt :: proc(x: Maybe(string), y: string) -> Maybe(string) {
		if v, ok := x.?; ok do return fmt.tprintf("(%s | %s)", v, y)
		return y
	}
	R[S][0] = `""`
	for s, i in a.states {
		if s.accept do R[i][F] = `""`
		for e in s.edges do R[i][e.to] = alt(R[i][e.to], print_rune_range(e.range))
	}
	cat :: proc(parts: ..string) -> string {
		kept := make([dynamic]string)
		for p in parts do if p != `""` do append(&kept, p)
		if len(kept) == 0 do return `""`
		return strings.join(kept[:], " + ")
	}
	for k := n - 1; k >= 0; k -= 1 {
		loop := ""
		if l, ok := R[k][k].?; ok do loop = fmt.tprintf("(%s)*0..", l)
		for i in 0 ..< n + 2 {
			if i == k do continue
			into, in_ok := R[i][k].?
			if !in_ok do continue
			for j in 0 ..< n + 2 {
				if j == k do continue
				out, out_ok := R[k][j].?
				if !out_ok do continue
				R[i][j] = alt(R[i][j], loop == "" ? cat(into, out) : cat(into, loop, out))
			}
		}
		for i in 0 ..< n + 2 do R[i][k] = nil
		for j in 0 ..< n + 2 do R[k][j] = nil
	}
	return R[S][F].? or_else "none"
}

print_rune_range :: proc(r: Rune_Range) -> string {
	if r.lo == r.hi do return print_rune(r.lo)
	return fmt.tprintf("%s..%s", print_rune(r.lo), print_rune(r.hi))
}

// Un caractère s'écrit entre apostrophes : `'a'..'z'` est une plage de caractères.
print_rune :: proc(r: rune) -> string {
	return fmt.tprintf("%q", r)
}
