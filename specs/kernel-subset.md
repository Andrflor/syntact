# Proposition — un kernel construit autour de `subset`

Le typecheck pose une seule question :

```odin
subset(t, s)   // toute valeur possible de t est-elle dans s ?
```

Pour `C:x -> v`, `t = type_of(v)` et `s = color_of(C)`. La couleur est toujours
**close** : c'est un singleton, donc elle ne dépend d'aucune inconnue. Seul `t`
peut en dépendre.

Cette proposition dit comment représenter les types pour que `subset` soit :
- **décidable** ;
- **exact** : jamais « oui » sans preuve ;
- **pas cher** : on garde des formes simplifiées, sans tout déployer.

---

## 0. Ce que la théorie a déjà pour un système comme le nôtre

| Syntact | Théorie | Ce qu'on en prend |
|---|---|---|
| valeurs = ensembles, `\|` `&` `~`, couleur = inclusion | *semantic subtyping* : Frisch, Castagna, Benzaken (JACM 2008) ; CDuce ; le système de types d'Elixir (2024) | un composant par sorte ; `a ⊆ b ⇔ a ∖ b = ∅`, décidé sorte par sorte |
| combinaisons de formes de scopes | les records du semantic subtyping (thèse de Frisch, ch. 7 et 9) ; BDD paresseux d'Elixir 1.19 | un champ à la fois ; les unions restent paresseuses, jamais de DNF déployée |
| `'a'..'z' * 2.. + "!"`, `~`, `&` sur les chaînes | dérivées de Brzozowski (1964) ; forme de similarité d'Owens, Reppy et Turon (JFP 2009) | une forme pseudo-canonique partagée ; l'inclusion par exploration paresseuse des dérivées, sans automate |
| inconnues, `n..10`, `n * m` | types raffinés et dépendants : Dminor (semantic subtyping + SMT, JFP 2012), Liquid Types (PLDI 2008) | `∀σ ∈ Γ. v(σ) ∈ s`, décidé par paliers : enveloppe, linéaire, énumération |
| `C:x -> v` | typage bidirectionnel (Dunfield et Krishnaswami, 2021) | `check(v ⇐ C)` : la couleur descend, on ne calcule que ce que la question demande |
| `*` sur des ensembles | interprétation abstraite (Cousot) | exact quand c'est énumérable, sinon une enveloppe, qui n'est jamais une couleur |

**Pseudo-canonique, concrètement :**
- les intervalles ont une forme unique, et c'est gratuit ;
- les chaînes et les scopes sont partagés (*hash-consing*) et simplifiés à associativité,
  commutativité et idempotence près, plus quelques identités (`~~r = r`, ∅ et ε
  absorbés). Deux écritures « semblables » sont le même pointeur. Deux écritures
  équivalentes mais pas semblables sont départagées par `subset`, à la demande, avec
  mémoïsation ;
- on ne distribue jamais à l'avance. On distribue seulement en décidant, chemin par
  chemin du BDD.

---

## 1. Le type : un composant par sorte, et ses sortes

```odin
Sort :: enum u8 {Int, Float, Char, String, Bool, Scope}

// Un type est un ensemble de valeurs. Les sortes sont disjointes : un composant par
// sorte. `sorts` : les sortes dont l'ensemble parle, même quand leur composant est
// vide (le « color of the range » de constraints.md — rien à voir avec la couleur
// d'un binding). Elle ne sert qu'à calculer ~ : subset ne la lit jamais. Toute
// opération la garde, donc ~~X = X toujours, et une sorte ne se perd jamais.
Type :: struct {
	sorts:   bit_set[Sort],
	ints:    Ints,   // intervalles : forme unique (inchangé)
	floats:  Floats, // inchangé
	chars:   Ints,   // inchangé
	strings: ^Re,    // §2
	bools:   Bools,
	scopes:  Bdd,    // §3
}

// none : le type sans sorte. Il n'admet que la valeur none (règle actuelle).
is_none :: proc(t: Type) -> bool {
	return card(t.sorts) == 0
}

type_or :: proc(a, b: Type) -> Type {
	return Type {
		sorts   = a.sorts | b.sorts,
		ints    = ints_union(a.ints, b.ints),
		floats  = floats_union(a.floats, b.floats),
		chars   = ints_union(a.chars, b.chars),
		strings = re_or(a.strings, b.strings),
		bools   = a.bools | b.bools,
		scopes  = bdd_or(a.scopes, b.scopes),
	}
}

type_and :: proc(a, b: Type) -> Type // composant par composant, sorts = a.sorts & b.sorts
type_diff :: proc(a, b: Type) -> Type // a ∖ b composant par composant, sorts = a.sorts

// ~X : le complément dans les sortes de X (specs/constraints.md, « Negation »).
type_not :: proc(x: Type) -> Type {
	return type_diff(top_of(x.sorts), x)
}

type_is_empty :: proc(t: Type) -> bool {
	return len(t.ints.intervals) == 0 && len(t.floats.intervals) == 0 &&
		len(t.chars.intervals) == 0 && re_is_empty(t.strings) &&
		t.bools == {} && bdd_is_empty(t.scopes)
}
```

```
~(u8 | string)    = {sorts: {Int, String}  ints: ..-1 | 256..  strings: ∅}
~~(u8 | string)   = u8 | string                 // la sorte String est restée
~bool             = {sorts: {Bool}}             // « aucun booléen » : ce n'est pas none
u8 & string       = {sorts: {}}                 // none (spec : String & >10 → None)
```

---

## 2. Les chaînes : la forme de similarité et les dérivées

On remplace les automates (Thompson, déterminisation, émondage) par les dérivées.
On garde une seule représentation, l'expression, et on la partage.

```odin
Re_Kind :: enum u8 {Word, Class, Cat, Alt, And, Not, Rep}

// Une expression régulière partagée : deux écritures semblables (Owens et al.,
// déf. 4.1) sont le même pointeur. On compare donc les états par adresse.
Re :: struct {
	kind:   Re_Kind,
	word:   string,     // Word ; "" est ε
	class:  Rune_Range, // Class : au moins deux caractères
	parts:  []^Re,      // Cat : [tête, reste] ; Alt, And : triés par id, sans doublon ; Not, Rep : [r]
	counts: Ints,       // Rep : des naturels ; si r accepte ε, 0..max (sans perte)
	id:     int,
}

EMPTY: ^Re // Alt sans partie : ∅
ANY:   ^Re // ~∅ : toute chaîne

// Les constructeurs appliquent la similarité, et elle seule :
//   |, & : aplatis, triés, sans doublon ; ∅ | r = r ; ~∅ | r = ~∅ ; ∅ & r = ∅ ; ~∅ & r = r
//   ·    : associé à droite ; ∅·r = r·∅ = ∅ ; ε·r = r·ε = r ; mot·mot = mot
//   ~~r = r ;  r * {0} = ε ;  r * {1} = r ;  mot * {n} = motⁿ
re_or :: proc(a, b: ^Re) -> ^Re {
	parts := make([dynamic]^Re)
	for x in ([2]^Re{a, b}) {
		for p in flat(x, .Alt) {
			if p == ANY do return ANY
			if p != EMPTY do append(&parts, p)
		}
	}
	return intern_set(.Alt, parts[:]) // trie par id, dédoublonne ; 0 partie : EMPTY ; 1 : elle
}

nullable :: proc(r: ^Re) -> bool {
	switch r.kind {
	case .Word:
		return r.word == ""
	case .Class:
		return false
	case .Cat, .And:
		for p in r.parts do if !nullable(p) do return false
		return true
	case .Alt:
		for p in r.parts do if nullable(p) do return true
		return false
	case .Not:
		return !nullable(r.parts[0])
	case .Rep:
		return ints_contains(r.counts, 0)
	}
	return false
}

// derive : les suffixes des mots de r qui commencent par c (Brzozowski).
derive :: proc(r: ^Re, c: rune) -> ^Re {
	switch r.kind {
	case .Word:
		head, size := utf8.decode_rune(r.word)
		return r.word != "" && head == c ? word(r.word[size:]) : EMPTY
	case .Class:
		return c >= r.class.lo && c <= r.class.hi ? EPS : EMPTY
	case .Cat:
		d := re_cat(derive(r.parts[0], c), r.parts[1])
		return nullable(r.parts[0]) ? re_or(d, derive(r.parts[1], c)) : d
	case .Alt:
		return fold(r.parts, c, re_or)
	case .And:
		return fold(r.parts, c, re_and)
	case .Not:
		return re_not(derive(r.parts[0], c))
	case .Rep:
		// r^C, puis C - 1 : le premier morceau non vide, puis les autres
		return re_cat(derive(r.parts[0], c), re_rep(r.parts[0], counts_minus_one(r.counts)))
	}
	return EMPTY
}

// cuts : les bornes de l'alphabet où la dérivée peut changer (classes de
// dérivées, Owens et al. §4.2). On calcule une dérivée par plage, avec son plus
// petit caractère comme représentant.
cuts :: proc(r: ^Re, out: ^[dynamic]rune) {
	switch r.kind {
	case .Word:
		if r.word != "" {
			c, _ := utf8.decode_rune(r.word)
			append(out, c, c + 1)
		}
	case .Class:
		append(out, r.class.lo, r.class.hi + 1)
	case .Cat:
		cuts(r.parts[0], out)
		if nullable(r.parts[0]) do cuts(r.parts[1], out)
	case .Alt, .And, .Not, .Rep:
		for p in r.parts do cuts(p, out)
	}
}

// re_witness : le plus petit mot de r (le plus court, puis le premier dans
// l'ordre des points de code), s'il y en a un. C'est un parcours en largeur des
// dérivées, comparées par adresse. Il termine parce qu'il n'y a qu'un nombre fini
// de dérivées dissemblables (Brzozowski).
re_witness :: proc(r: ^Re) -> (string, bool) {
	Visit :: struct {
		re:   ^Re,
		word: string,
	}
	seen := make(map[^Re]bool)
	queue := make([dynamic]Visit)
	append(&queue, Visit{r, ""})
	seen[r] = true
	for i := 0; i < len(queue); i += 1 {
		v := queue[i]
		if nullable(v.re) do return v.word, true
		for c in representatives(v.re) { 	// croissants : le premier témoin est le plus petit
			d := derive(v.re, c)
			if d == EMPTY || seen[d] do continue
			seen[d] = true
			append(&queue, Visit{d, fmt.tprintf("%s%c", v.word, c)})
		}
	}
	return "", false
}

re_subset :: proc(a, b: ^Re) -> bool {
	_, found := re_witness(re_and(a, re_not(b)))
	return !found
}

// Le défaut d'un langage est son plus petit mot.
re_default :: re_witness

// re_count, saturé à 2 : deux recherches de témoin suffisent.
re_count :: proc(r: ^Re) -> int {
	w, found := re_witness(r)
	if !found do return 0
	_, other := re_witness(re_and(r, re_not(word(w))))
	return other ? 2 : 1
}
```

Le défaut, le singleton et l'inclusion sortent tous de `re_witness`. Il n'y a plus
de déterminisation, ni d'émondage, ni d'automate gardé.

---

## 3. Les scopes : des formes, et un BDD paresseux

Une couleur de scope sans production est une **forme** : sa structure, et ce que
chaque binding admet. Les combinaisons `|`, `&` et `~` de formes sont un BDD
d'Elixir, où les unions restent dans la branche « peut-être ».

```odin
// Une forme de scope, partagée comme les Re : son id ordonne les nœuds du BDD.
Record :: struct {
	fields: []Field,
	id:     int,
}

Field :: struct {
	name: string,
	kind: Binding_Kind,
	type: Type, // ce que le binding admet ; toutes les valeurs s'il n'impose rien
}

// {a, oui, peut, non} = (a & oui) | peut | (~a & non). Les unions restent dans
// `peut` au lieu d'être distribuées : la taille reste celle de l'écriture.
Bdd :: union {
	Bdd_Leaf,
	^Bdd_Node,
}

Bdd_Leaf :: enum u8 {
	Bottom,
	Top,
}

Bdd_Node :: struct {
	atom:            ^Record,
	yes, maybe, no: Bdd,
}

bdd_or :: proc(a, b: Bdd) -> Bdd {
	if a == .Top || b == .Top do return .Top
	if a == .Bottom do return b
	if b == .Bottom do return a
	x, y := a.(^Bdd_Node), b.(^Bdd_Node)
	switch {
	case x.atom == y.atom:
		return node(x.atom, bdd_or(x.yes, y.yes), bdd_or(x.maybe, y.maybe), bdd_or(x.no, y.no))
	case x.atom.id < y.atom.id:
		return node(x.atom, x.yes, bdd_or(x.maybe, b), x.no) // l'union reste paresseuse
	}
	return node(y.atom, y.yes, bdd_or(a, y.maybe), y.no)
}

// a ∖ b : on ne distribue que le long de l'atome courant.
bdd_diff :: proc(a, b: Bdd) -> Bdd {
	if b == .Top || a == .Bottom do return .Bottom
	if b == .Bottom do return a
	y := b.(^Bdd_Node)
	x, a_node := a.(^Bdd_Node)
	switch {
	case !a_node || y.atom.id < x.atom.id:
		return node(y.atom, bdd_diff(a, bdd_or(y.yes, y.maybe)), .Bottom, bdd_diff(a, bdd_or(y.no, y.maybe)))
	case x.atom == y.atom:
		return node(
			x.atom,
			bdd_diff(bdd_or(x.yes, x.maybe), bdd_or(y.yes, y.maybe)),
			.Bottom,
			bdd_diff(bdd_or(x.no, x.maybe), bdd_or(y.no, y.maybe)),
		)
	}
	return node(x.atom, bdd_diff(x.yes, b), bdd_diff(x.maybe, b), bdd_diff(x.no, b))
}

bdd_and :: proc(a, b: Bdd) -> Bdd // même schéma (Frisch, ch. 7)

// bdd_is_empty : chaque chemin est une intersection de formes moins des formes. Le
// BDD est vide si chaque chemin l'est. C'est ici, et seulement ici, qu'on distribue.
bdd_is_empty :: proc(b: Bdd, pos: []^Record = nil, neg: []^Record = nil) -> bool {
	switch v in b {
	case Bdd_Leaf:
		return v == .Bottom || records_empty(pos, neg)
	case ^Bdd_Node:
		return(
			bdd_is_empty(v.yes, with(pos, v.atom), neg) &&
			bdd_is_empty(v.maybe, pos, neg) &&
			bdd_is_empty(v.no, pos, with(neg, v.atom)) \
		)
	}
	return true
}

// ∩pos ∖ ∪neg = ∅ ? Deux structures différentes ne se rencontrent pas.
records_empty :: proc(pos, neg: []^Record) -> bool {
	if len(pos) == 0 do return false // tous les scopes moins quelques formes : jamais vide
	fields := field_types(pos[0])
	for r in pos[1:] {
		if !same_structure(r, pos[0]) do return true
		for &f, i in fields do f = type_and(f, r.fields[i].type)
	}
	cover := make([dynamic][]Type)
	for r in neg do if same_structure(r, pos[0]) do append(&cover, field_types(r))
	return product_covered(fields, cover[:])
}

// F₁ × … × Fₙ ⊆ ∪ cover ? On retire une forme N à la fois. Ce qui reste de F hors
// de N est l'union, pour chaque champ i, de F avec Fᵢ ∖ Nᵢ (Frisch, ch. 7).
product_covered :: proc(fields: []Type, cover: [][]Type) -> bool {
	for f in fields do if type_is_empty(f) do return true
	if len(cover) == 0 do return false
	n := cover[0]
	for f, i in fields {
		rest := slice.clone(fields)
		rest[i] = type_diff(f, n[i])
		if !product_covered(rest, cover[1:]) do return false
	}
	return true
}
```

```
Point -> {u8:x  u8:y}
Point:p -> {x -> 1  y -> 300}       // le champ y : 300 ∉ u8           → ✗
(Point | {string:name}):q -> …      // une union : un nœud, pas de DNF
(Point & ~{0:x  u8:y}):r -> {x -> 0  y -> 5}
                                    // chemin Point ∖ {0:x u8:y}       → ✗
```

---

## 4. Les inconnues : des types raffinés, décidés par paliers

On garde les formes normales actuelles (`Poly`, `Term`, tables), qui donnent la
précision (`n - n` vaut `0`). Ce qui change : on ne calcule plus à l'avance
toutes les valeurs (65 536 évaluations). On répond à la question posée, du moins
cher au plus cher.

```odin
Verdict :: enum u8 {
	Proved,
	Refuted,
	Undecided,
}

// value_in : ∀σ ∈ Γ, ⟦v⟧σ ∈ s. La couleur s est close.
value_in :: proc(k: ^Kernel, v: ^Expr, s: Type) -> Verdict {
	// 1. L'enveloppe, par intervalles sur la forme normale, ou par langage pour un
	//    mot dont aucune inconnue ne se répète (exacte alors).
	env, exact := envelope(k, v)
	if subset(env, s) do return .Proved
	if type_is_empty(type_and(env, s)) || exact do return .Refuted

	// 2. Une forme linéaire sur des boîtes : son min et son max sont atteints aux coins.
	if p, ok := linear(v); ok {
		lo, hi := linear_range(k, p)
		if within_one_interval(s.ints, lo, hi) do return .Proved
		if !ints_contains(s.ints, lo) || !ints_contains(s.ints, hi) do return .Refuted
	}

	// 3. Exact, si les inconnues s'énumèrent (≤ 65 536 affectations).
	if vals, ok := enumerate(k, v); ok do return subset(vals, s) ? .Proved : .Refuted

	// 4. On ne sait pas le prouver. C'est une erreur explicite, jamais une acceptation.
	return .Undecided
}
```

```
n -> ??::u8   u16:z -> n * n          // palier 1 : 0..65025 ⊆ u16, sans énumérer
n -> ??::u64  m -> ??::u64
u64:d -> n + m                        // palier 2 : max = 2·(2⁶⁴-1) ∉ u64 → ✗, sans énumérer
true:e -> n - n = 0                   // la forme normale : 0 = 0
n -> ??::u8   true:f -> n*n - 2*n + 1 >= 0
                                      // l'enveloppe échoue, palier 3 : 256 cas → ✓
```

Plus tard, quand une inconnue dépendra d'une autre (`m -> ??::(0..n)`), Γ ne sera
plus une boîte. Le palier 2 deviendra Fourier–Motzkin (arithmétique linéaire
relationnelle), sans rien changer au reste.

---

## 5. `subset`, `admits`, et le check bidirectionnel

```odin
// subset : a ⊆ b pour deux types clos. Sorte par sorte, a ∖ b est vide. `sorts`
// n'y entre pas : seules les valeurs comptent.
subset :: proc(a, b: Type) -> bool {
	return(
		ints_subset(a.ints, b.ints) &&
		floats_subset(a.floats, b.floats) &&
		ints_subset(a.chars, b.chars) &&
		re_subset(a.strings, b.strings) &&
		a.bools <= b.bools &&
		bdd_is_empty(bdd_diff(a.scopes, b.scopes)) \
	)
}

// admits : la question du typecheck, pour tout type de valeur.
admits :: proc(k: ^Kernel, colour: Type, t: ^Expr) -> Verdict {
	#partial switch v in t^ {
	case Type:
		if is_none(v) do return is_none(colour) ? .Proved : .Refuted // none n'est admis que par none
		return subset(lift_chars(v, colour), colour) ? .Proved : .Refuted // string admet 'c'
	case Poly, Term:
		return value_in(k, t, colour)
	case ^Scope:
		return scope_in(k, v, colour.scopes) // chaque champ contre la forme qui l'attend
	case Family:
		return every_cell(k, v, colour)
	}
	return .Refuted
}

// check : la couleur descend dans l'expression. On ne calcule que ce que la
// question demande.
check :: proc(k: ^Kernel, e: ^Expr, env: ^Scope, colour: Type, b: ^Binding) -> ^Expr {
	#partial switch v in e^ {
	case Unknown:
		if v.layout == nil do return new_symbol(k, colour) // ?? prend sa couleur
	case ^Scope:
		// un scope littéral contre une forme : chaque binding contre son champ
		if r, ok := single_record(colour.scopes); ok do return check_fields(k, v, env, r)
	}
	t := type_of(k, e, env)
	switch admits(k, colour, t) {
	case .Proved:
	case .Refuted:
		report(k, .Constraint_Mismatch, b.span, …)
	case .Undecided:
		report(k, .Unproven, b.span, …) // nouvelle erreur : « je ne sais pas le prouver »
	}
	return t
}
```

---

## 6. Ce que ça change dans `kernel/`

| Fichier | Aujourd'hui | Proposé |
|---|---|---|
| `set.odin` | `Set` = 5 composants | `type.odin` : `Type` = sortes + 6 composants (scopes en plus) ; `Ints` et `Floats` inchangés |
| `regular.odin` | expression + Thompson, déterminisation, émondage | `re.odin` : similarité + partage + dérivées ; plus d'automate |
| — | les scopes comparés à la main (`scope_admits`) | `bdd.odin` : formes, BDD paresseux, `product_covered` |
| `unknown.odin` | `values_of` énumère toujours | `value_in` par paliers ; l'énumération n'est plus que le palier 3 |
| `check.odin` | `contains` / `type_subset` / `atoms_admitted` | `subset` + `admits`, un seul chemin ; nouvelle erreur `Unproven` |
| `type_of.odin` | on type, puis on vérifie tout à la fin | `check(e ⇐ couleur)` bidirectionnel, appelé par `type_binding` |
| `family.odin` | tables, enveloppes | inchangé ; « table constante » = égalité par double `subset` |

## 7. Ce qui reste ouvert

1. **`0 & 1`.** C'est un vide de sorte `Int`, pas none (`u8 & string` est none).
   Est-ce qu'il doit admettre la valeur none ? La proposition dit non.
2. **`Unproven`.** C'est une troisième issue du typecheck : ni accepté, ni faux,
   « pas prouvé ». La proposition la rend explicite plutôt que de rejeter en
   silence.
3. **Formes récursives** (`List{data}`). C'est l'inclusion coinductive de CDuce :
   on suppose `a ⊆ b` pendant qu'on le vérifie, avec mémoïsation. Elle arrive avec
   l'algèbre des scopes.

## Sources

- [Castagna, Duboc, Valim — The Design Principles of the Elixir Type System](https://arxiv.org/pdf/2306.06391)
- [Elixir — Lazier BDDs for set-theoretic types](https://elixir-lang.org/blog/2025/12/02/lazier-bdds-for-set-theoretic-types/)
- [Elixir — Lazy BDDs with eager literal differences](https://elixir-lang.org/blog/2026/03/19/lazy-bdds-with-eager-literal-differences/)
- [Frisch, Castagna, Benzaken — Semantic subtyping](https://www.irif.fr/~gc/papers/semantic_subtyping.pdf)
- [Castagna — Covariance and Contravariance: a fresh look](https://arxiv.org/pdf/1809.01427)
- [Owens, Reppy, Turon — Regular-expression derivatives re-examined](https://www.khoury.northeastern.edu/home/turon/re-deriv.pdf)
- [Bierman, Gordon, Hriţcu, Langworthy — Semantic subtyping with an SMT solver](https://www.cambridge.org/core/journals/journal-of-functional-programming/article/semantic-subtyping-with-an-smt-solver/5093B3D8253A1A47E50357AFC7A321EF)
