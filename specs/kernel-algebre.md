# Le kernel des types — propriétés algébriques et preuves

> Ce document prouve, de bout en bout, les propriétés du kernel (`kernel/`) :
> que chaque type a une écriture unique (canonicité), que `type_of` ne ment jamais
> sur les valeurs possibles (correction), et que la vérification n'accepte jamais
> une couleur violée (sûreté). Chaque théorème renvoie au code qui le réalise et au
> test qui le vérifie. Les limites sont dites, pas cachées (§7).

---

## 0. Notations

- `V` : les valeurs. `⟦e⟧σ` : la valeur de l'expression `e` quand les inconnues
  valent `σ` (une affectation de chaque inconnue dans son ensemble).
- Un **type** est un ensemble de valeurs possibles. `type_of(e)` en est une écriture.
- Un **singleton** est un type à un seul élément ; son **élément** est cette valeur.
- Une **couleur** `C` d'un binding `C:x -> v` est l'élément du singleton
  `type_of(C)` ; elle désigne un ensemble `⟦C⟧`.
- « Canonique » : une fonction `N` des écritures vers les représentations telle que
  **`N(A) = N(B)` ⇔ `A` et `B` désignent le même ensemble** (égalité de structure
  ⇔ égalité sémantique).

---

## 1. Les valeurs

1. **Atomes**, en cinq sortes disjointes :
   - entiers `ℤ` ;
   - flottants (lus comme des réels, voir §7) ;
   - caractères : points de code `0..0x10FFFF`, plus le caractère vide `''`, noté `ε_c`, placé en dessous de tous ;
   - chaînes `Σ*` ;
   - booléens.
2. **Les valeurs sont des ensembles.** Un atome `a` s'identifie au singleton `{a}`.
   `none` est l'ensemble vide : une valeur, son propre singleton.
3. **Scopes** : suites finies de bindings `(nom, kind, couleur, valeur)`.
4. **Le niveau au-dessus.** Un ensemble `S` à au moins deux éléments, vu comme une
   valeur, s'écrit `{-> S}` : le singleton dont `S` est l'élément. C'est la loi du
   producteur : un scope dénote ses productions.

`singleton(x)` vaut `x` si `x` est un atome ou `none` (au plus un élément), et
`{-> x}` sinon. `the_element` est son inverse. Ces deux procédures
(`type_of.odin`) sont les seules à franchir un niveau, ce qui exclut toute
confusion entre « la valeur `0..255` » et « une valeur parmi `0..255` ».

---

## 2. Les ensembles d'atomes : une algèbre de Boole par sorte, canonique

Un ensemble d'atomes est un quintuplet `(Z, R, C, S, B)`, une composante par sorte
(`Set`, `set.odin`). Les opérations se font composante par composante. Le
complément se prend dans les sortes que l'ensemble porte : `~5` est « tout entier
sauf 5 » (spécification, `specs/constraints.md`). Dans chaque sorte, `∪ ∩ ~`
forment une algèbre de Boole. L'inclusion se décide par `A ∩ ~B = ∅`, sorte par
sorte.

### Théorème 2.1 — entiers (et caractères) : écriture unique

> Toute union finie d'intervalles de `ℤ`, bornes éventuellement infinies, s'écrit
> d'une seule façon comme une suite d'intervalles **non vides, triés, disjoints et
> non adjacents**.

*Preuve.*
- **Existence.** On trie les intervalles et on fusionne ceux qui se chevauchent ou
  se touchent (`l ≤ h' + 1`). Chaque fusion garde l'union.
- **Unicité.** Dans une telle suite, chaque intervalle est une composante
  « connexe » maximale de l'ensemble : il ne peut pas grandir sans sortir de
  l'ensemble, sinon il chevaucherait ou toucherait son voisin. Les composantes
  maximales d'un ensemble ne dépendent que de l'ensemble, donc deux écritures
  normales du même ensemble ont les mêmes intervalles, dans le même ordre. ∎

*Code* : `ints_of`, qui établit l'invariant. *Tests* : `is_normal`,
`test_law_ints`, `test_canonical_ints`. Les caractères sont le même ensemble sur
`[ε_c, 0x10FFFF]`.

### Théorème 2.2 — flottants : écriture unique sur les réels

> Toute union finie d'intervalles de `ℝ`, bornes ouvertes ou fermées, éventuellement
> infinies, s'écrit d'une seule façon comme une suite d'intervalles non vides, triés,
> deux à deux **non fusionnables**. Deux intervalles sont fusionnables quand leur
> union est un intervalle.

*Preuve.* C'est l'argument de 2.1 sur les composantes connexes de `ℝ`. Deux
conventions rendent l'écriture des bornes unique :
- une borne infinie ne porte pas de drapeau ouvert/fermé ;
- `-0.0` s'écrit `0.0`.

Avant ces conventions, une même composante avait deux écritures ; le test de
canonicité l'a détecté et c'est corrigé. ∎

*Code* : `floats_of`, `canonical_zero`. *Tests* : `test_law_floats`,
`test_canonical_floats`.

### Théorème 2.3 — chaînes : écriture unique (Myhill–Nerode)

> Tout langage régulier a une seule représentation : l'automate déterministe minimal
> sans état mort, dont les états sont numérotés en largeur depuis l'initial en
> suivant les arêtes dans l'ordre des caractères, et dont les arêtes voisines vers le
> même état sont fusionnées.

*Preuve.*
- **Myhill–Nerode.** Un langage régulier `L` a un automate minimal unique à
  isomorphisme près : ses états sont les classes de la congruence de Nerode. Retirer
  l'état mort (celui de la classe des mots sans suffixe acceptant) garde l'unicité.
- **`minimize` calcule cet automate.** On ne garde que les états accessibles et
  vivants. Le raffinement de Moore part de la partition
  {acceptants, non acceptants} et sépare deux états dès que leurs transitions mènent
  à des classes différentes. Il converge vers l'équivalence de Nerode sur cet
  automate. Les signatures fusionnent les plages voisines, donc deux états de même
  comportement dont les plages sont découpées différemment ont la même signature.
- **La numérotation retire l'isomorphisme.** Un parcours en largeur depuis
  l'initial, qui visite les arêtes par caractère croissant, assigne un numéro à
  chaque état en fonction du seul langage. Deux automates minimaux isomorphes
  reçoivent donc la même numérotation, c'est-à-dire la même structure. ∎

*Code* : `minimize`, `signature`, `determinize`, `product` (`regular.odin`).
*Tests* : `test_law_strings` (appartenance contre l'énumération des mots de
longueur ≤ 5), `test_canonical_strings`.

### Théorème 2.4 — ensembles mixtes

> L'écriture d'un ensemble mixte est unique.

*Preuve.* Les sortes sont disjointes. Un ensemble est donc la donnée de ses cinq
composantes, chacune unique par 2.1 à 2.3. Le défaut ne dépend pas de l'ordre
d'écriture : on prend la première sorte non vide dans un ordre fixe. ∎
*Test* : `test_canonical_sets`.

### Clôture

- **Entiers et flottants.** Les opérations `∪ ∩ ~` restent dans les unions finies
  d'intervalles. L'arithmétique `+ - *` est sur-approchée par intervalles : c'est
  un sur-ensemble, voir §4.
- **Chaînes.** Les langages réguliers sont clos par `∪ ∩ ~`, par la concaténation et
  par la répétition `L^S` où `S` est une union finie d'intervalles de `ℕ` :
  `L^{a..b} = L^a·(ε|L)^{b-a}` et `L^{a..} = L^a·L*`. Les plages de caractères
  `'a'..'z'`, les préfixes `p..` et les suffixes `..s` sont réguliers.
- **Caractères.** Ils se plongent dans les chaînes (un caractère comme la chaîne
  d'une lettre, `ε_c` comme `""`) pour `+`, `*`, et pour l'admission par une
  couleur `string`.

---

## 3. Les inconnues : une forme normale par algèbre

Une inconnue est un symbole `??k` qui porte l'ensemble de ses valeurs possibles.
Une inconnue dont l'ensemble n'a qu'une valeur est cette valeur (`new_symbol`).

### Théorème 3.1 — entiers : écriture unique des polynômes

> Tout polynôme de `ℤ[??₀, ??₁, …]` a une seule écriture `Σ cᵢ·mᵢ + c`, où les
> monômes `mᵢ` sont distincts et triés (par degré, puis par ids), et où les
> coefficients `cᵢ` sont non nuls. Sans monôme, c'est l'atome `c`.

*Preuve.* Les monômes forment une base du `ℤ`-module `ℤ[X]` : la décomposition sur
une base est unique. L'ordre total fixé sur les monômes rend l'écriture unique.
`poly_add`, `poly_sub` et `poly_mul` (`canon.odin`) calculent dans cette base et
renormalisent : ils trient, fusionnent les monômes égaux et retirent les zéros. ∎

*Tests* : `test_law_polynomials` (évaluation en tout point d'un domaine ;
commutativité ; `(a+b)(a-b) = a² - b²`), `test_canonical_polynomials` (même forme
⇔ même polynôme, l'identité étant décidée par évaluation en des points aléatoires,
lemme de Schwartz–Zippel).

### Théorème 3.2 — comparaisons entières

> `a ⋈ b` s'écrit en fonction du seul polynôme `p = a - b` :
> - `≤`, `>` et `≥` se ramènent à `<` (`p ≤ 0 ⇔ p - 1 < 0` sur `ℤ`, et un changement
>   de signe pour `>` et `≥`) ;
> - on divise par le pgcd `g` des coefficients des monômes (`g·r + c < 0 ⇔
>   r + ⌊c/g⌋ < 0`, et `g·r + c = 0` n'a pas de solution si `g ∤ c`) ;
> - pour `=` et `≠`, on fixe le signe du premier monôme.
>
> La comparaison est **décidée** (`true` ou `false`) exactement quand sa vérité ne
> varie pas sur les valeurs possibles, dès que ces valeurs sont énumérées.

*Preuve.* Chaque étape est une équivalence sur `ℤ`. La décision lit les valeurs
exactes de `p`, sur la même énumération que le §4. ∎
*Test* : `test_law_polynomials`. Pour chaque opérateur, il vérifie que la forme
écrite garde la vérité en tout point, et que la comparaison est décidée si et
seulement si sa vérité est constante.

### Théorème 3.3 — chaînes : écriture unique des mots

> Une concaténation dont des parties sont inconnues a une seule écriture : la suite
> aplatie de ses parties, les littéraux voisins fusionnés et le mot vide retiré.

*Preuve.* C'est la forme normale du monoïde libre engendré par les littéraux et les
symboles, modulo l'associativité de la concaténation et la fusion des littéraux. ∎

### Théorème 3.4 — flottants inconnus

> Deux expressions flottantes ont la même écriture si et seulement si elles sont
> égales modulo la commutativité de `+` et de `*`, `-(-x) = x`, `a - b = a + (-b)`
> et `x·1.0 = x`.

*Preuve.* Ces lois sont exactes en IEEE 754. Les opérandes sont ordonnés par une
écriture canonique, et les constructeurs appliquent ces lois et aucune autre. ∎
L'associativité n'est **pas** une loi IEEE : elle n'est pas appliquée (§7).

### Théorème 3.5 — ensembles qui dépendent d'inconnues

> Un ensemble qui dépend d'inconnues énumérables est une fonction des valeurs des
> inconnues vers les ensembles. Il a une seule écriture : la table de ses valeurs,
> restreinte aux inconnues dont elle dépend vraiment (dans un ordre fixe, les valeurs
> énumérées dans l'ordre de leur ensemble), chaque entrée étant canonique par §2.
> Une table sans inconnue est son ensemble.

*Preuve.*
- **Les inconnues retenues sont fixées.** Une fonction dépend d'une inconnue s'il
  existe deux affectations qui ne diffèrent qu'en elle et donnent des ensembles
  différents. C'est une propriété de la fonction : deux tables égales retiennent les
  mêmes inconnues, et `prune` les retire toutes. Avant `prune`, une table construite
  en passant par une inconnue inutile s'écrivait autrement ; c'est corrigé.
- **Les entrées sont fixées.** Sur les mêmes inconnues, la table est la fonction
  elle-même, lue dans un ordre fixe. ∎

La corrélation est gardée : `(n | 6) & (n | 7)` vaut `{n}` pour chaque n.
*Code* : `set_operation`, `family_expr`, `prune` (`family.odin`). *Tests* :
`test_law_families` (la table contre le calcul direct, pour chaque affectation),
`test_canonical_families`.

---

## 4. Correction de `type_of`

> **Théorème 4.1.** Pour toute expression `e` et toute affectation `σ` des inconnues
> (chacune dans son ensemble), `⟦e⟧σ` est une valeur possible de `type_of(e)`.

Pour un type de valeur, les valeurs possibles sont données par `values_of`, exacte
ou sur-approchée. Pour une table, ce sont ses entrées. Pour une enveloppe
`{-> ⊆ U}`, ce sont les sous-ensembles de `U`.

*Preuve, par induction sur la forme de `e` :*
- **littéral, builtin** : la valeur est l'élément de son singleton ;
- **`??::T`, `??` coloré** : un symbole dont l'ensemble est celui de `T` (ou de la
  couleur) ; `σ` l'y place ;
- **Ref** : par induction, le type mémorisé du binding contient sa valeur ;
- **scope** : son type est le singleton du scope typé ; chaque binding y est
  correct par induction, dans l'ordre (un binding ne voit que ceux du dessus) ;
- **`s.x`, `s!`** : on lit le type de la dernière occurrence de `x`, ou de la
  première production, qui contient sa valeur par induction ;
- **opérateur sur des valeurs** : la forme canonique est une équivalence (§3), donc
  elle a la même valeur en `σ`. Ses valeurs possibles sont soit l'énumération exacte
  sur toutes les affectations, qui contient donc `σ`, soit une sur-approximation par
  intervalles (arithmétique d'intervalles, qui contient tout résultat exact,
  `test_law_ints`) ;
- **opérateur sur des ensembles** : sur des ensembles connus, c'est le calcul exact
  du §2 ; sur une table, l'entrée de `σ` est exactement l'ensemble calculé en `σ`
  (`test_law_families`) ; sur une enveloppe, chaque opération est monotone (`∪`, `∩`,
  arithmétique, plages) ou couvre toute la sorte (complément, `!=`). L'enveloppe du
  résultat contient donc l'ensemble de `σ`. ∎

---

## 5. Sûreté de la vérification

> **Théorème 5.1.** Si la vérification ne signale aucune erreur, alors pour tout
> binding `C:x -> v` et toute affectation `σ`, `⟦v⟧σ ∈ ⟦C⟧`.

*Preuve.*
1. **La couleur ne dépend d'aucune inconnue.** `color_of` exige que `type_of(C)`
   soit un singleton : sinon c'est `Insoluble_Constraint`. Un singleton a un seul
   élément, donc `⟦C⟧` est le même pour toute `σ`. Une table non constante ou une
   enveloppe n'est jamais un singleton.
2. **Les valeurs possibles contiennent la valeur réelle.** Par le théorème 4.1,
   `⟦v⟧σ` est une valeur possible de `type_of(v)` ; `values_of` en donne un
   sur-ensemble.
3. **L'admission.** `check` vérifie que chaque valeur possible est admise par `⟦C⟧` :
   - un atome doit être élément de la couleur ;
   - `none` n'est admis que par la couleur `none` ;
   - un caractère est admis par une couleur de chaînes ;
   - pour un scope, l'admission passe par une production, ou par la même structure
     avec chaque binding coloré admis.

   Une sur-approximation ne peut que **refuser** davantage, jamais accepter une
   valeur réelle hors couleur. ∎

**Corollaire.** Un programme accepté respecte toutes ses couleurs, quelles que soient
les valeurs de ses inconnues. Les preuves `true:p -> …` en sont un cas particulier.

---

## 6. Les lois, vérifiées structurellement

Par la canonicité, toute loi vraie sur les ensembles est vraie **sur l'écriture** :
les deux membres ont la même structure, sans calcul supplémentaire.

| Loi | Où elle est vérifiée |
|---|---|
| `A ∪ B = B ∪ A`, `A ∩ B = B ∩ A` | `test_law_*`, `test_canonical_sets` |
| `A ∪ A = A`, absorption `A ∪ (A ∩ X) = A` | `test_law_strings`, `test_canonical_*` |
| `~~A = A`, De Morgan | `test_law_ints`, `test_law_floats`, `test_law_strings` |
| `A ∩ (B ∪ C) = (A ∩ B) ∪ (A ∩ C)` | `test_law_strings` |
| `(A ∩ X) ∪ (A ∩ ~X) = A` | `test_canonical_*` |
| `(A + B) + C = A + (B + C)`, `A + "" = A` | `test_law_strings`, `test_canonical_strings` |
| `A * 0..2 = "" ∪ A ∪ AA`, `A * 1..3 = A + A * 0..2` | `test_law_strings`, `test_canonical_strings` |
| `2|1 = 2..1`, `2|"a"|3..4 = "a"|2..4` | `kernel_test.odin` |
| `n - n = 0`, `(a+b)(a-b) = a² - b²`, distributivité | `test_law_polynomials`, `test_canonical_polynomials` |

---

## 7. Limites, dites

1. **Polynômes et comparaisons.** Ils sont canoniques en tant que **polynômes**, pas en
   tant que fonctions sur le domaine des inconnues : `n² - n` et `0` coïncident sur
   n ∈ {0,1} mais s'écrivent différemment, et de même `n < 3` et `n² < 9` sur `u8`.
   Les **valeurs** restent exactes (énumération), donc la vérification n'est pas
   affectée. Seule l'égalité des formes l'est.
2. **Flottants.** Leurs ensembles sont canoniques sur les réels, pas sur les valeurs
   f64 discrètes. Une expression flottante inconnue n'est canonique qu'aux lois IEEE
   exactes près (3.4).
3. **Enveloppes.** `{-> ⊆ U}` est une sur-approximation. Elle n'est jamais utilisée
   pour affirmer une égalité ou une inclusion de types, ni comme couleur.
4. **Limites de taille.** Au-delà de 65 536 affectations, on n'énumère plus : les
   valeurs sont sur-approchées. Au-delà de 4 096 répétitions, un automate exact
   n'est pas construit : c'est une erreur explicite, jamais une approximation de
   couleur.
5. **Pas encore dans le kernel.** Les propriétés ci-dessus portent sur ce que le
   kernel implémente. Le carve, les patterns, la récursion, les trous `<-`,
   l'algèbre des scopes (`|` et `&` de formes) et les effets restent à prouver de la
   même façon quand ils seront ajoutés. Toute forme non implémentée signale
   `Unsupported` : elle ne produit jamais un résultat non couvert par ces théorèmes.

---

## 8. Où vérifier

| Propriété | Code | Tests |
|---|---|---|
| 2.1 entiers, caractères | `set.odin` : `ints_of` | `test_law_ints`, `test_canonical_ints` |
| 2.2 flottants | `set.odin` : `floats_of` | `test_law_floats`, `test_canonical_floats` |
| 2.3 chaînes | `regular.odin` : `minimize` | `test_law_strings`, `test_canonical_strings` |
| 2.4 mixtes | `set.odin` | `test_canonical_sets` |
| 3.1–3.4 inconnues | `canon.odin` | `test_law_polynomials`, `test_canonical_polynomials`, `kernel_test.odin` |
| 3.5 tables | `family.odin` | `test_law_families`, `test_canonical_families` |
| 4.1 correction | `type_of.odin`, `op.odin` | `test_law_*`, corpus `test/typecheck` |
| 5.1 sûreté | `check.odin` | corpus `test/typecheck` (381 cas), `kernel_test.odin` |

`odin test kernel` exécute tout.
