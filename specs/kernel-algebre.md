# Le kernel des types — propriétés algébriques et preuves

> Ce document prouve, de bout en bout, ce dont le typecheck a besoin (`kernel/`) :
> - les **décisions** sur les types sont exactes : appartenance, inclusion, égalité
>   comme double inclusion, « est un singleton » ;
> - `type_of` ne ment jamais sur les valeurs possibles (**correction**) ;
> - la vérification n'accepte jamais une couleur violée (**sûreté**).
>
> Les types n'ont pas d'écriture unique, et n'en ont pas besoin. Ils ont une
> **forme normale simple**, choisie pour que ces décisions soient faciles. Elle est
> unique là où cela ne coûte rien (intervalles, polynômes). Chaque théorème renvoie
> au code qui le réalise et au test qui le vérifie. Les limites sont dites, pas
> cachées (§7).

---

## 0. Notations

- `V` : les valeurs. `⟦e⟧σ` : la valeur de l'expression `e` quand les inconnues
  valent `σ` (une affectation de chaque inconnue dans son ensemble).
- Un **type** est un ensemble de valeurs possibles. `type_of(e)` en est une écriture.
- Un **singleton** est un type à un seul élément ; son **élément** est cette valeur.
- Une **couleur** `C` d'un binding `C:x -> v` est l'élément du singleton
  `type_of(C)` ; elle désigne un ensemble `⟦C⟧`.
- Le typecheck ne demande que trois décisions :

  ```
  is_singleton(type_of(C))                 la couleur désigne un seul ensemble
  subset(A, B)   ⇔  A ∩ ~B = ∅             les valeurs possibles sont admises
  equal(A, B)    ⇔  subset(A, B) ∧ subset(B, A)
  ```

  Aucune ne lit la structure d'une écriture : seulement l'ensemble qu'elle désigne.

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

## 2. Les ensembles : une algèbre de Boole par sorte, l'inclusion décidée

Un ensemble a une composante par sorte : entiers, flottants, caractères, chaînes,
booléens, scopes (`Set`, `set.odin`). Les opérations se font composante par
composante, et l'inclusion se décide sorte par sorte, par `A ∖ B = ∅`.

**Les sortes portées.** Le complément se prend dans les sortes dont l'ensemble
parle : `~5` est « tout entier sauf 5 » (`specs/constraints.md`, Negation). Un
ensemble retient ces sortes (`sorts`, `carried`), même quand leur composante est
vide :

```
~(u8 | string)    = ..-1 | 256.. | ~string     la sorte string reste portée
~~(u8 | string)   = u8 | string
u8 & string       = none                       aucune sorte commune
0 & 1             = ~int                       vide, mais parle des entiers
```

Dans chaque sorte, `∪ ∩ ~` forment une algèbre de Boole. Comme `~` garde les
sortes, **`~~X = X` pour tout X**, y compris à travers une ref. `subset` et
l'égalité ne lisent que les valeurs, jamais les sortes.

### Théorème 2.1 — entiers (et caractères) : forme normale unique

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

Le vide est la suite vide : `A ∩ ~B = ∅` se lit directement.

**L'univers.** Les entiers finis vivent dans `[-(2¹²⁷-1), 2¹²⁷-1]`. Cet univers est
symétrique : la négation n'y déborde jamais. Au bord, une borne finie et une borne
infinie désignent les mêmes valeurs ; la forme normale écrit la borne infinie,
sauf pour le point du bord lui-même (`at_edges`), ce qui garde l'unicité.

*Code* : `ints_of`, qui établit l'invariant. *Tests* : `is_normal`,
`test_law_ints`, `test_normal_ints`. Les caractères sont le même ensemble sur
`[ε_c, 0x10FFFF]`.

### Théorème 2.2 — flottants : forme normale unique sur les réels

> Toute union finie d'intervalles de `ℝ`, bornes ouvertes ou fermées, éventuellement
> infinies, s'écrit d'une seule façon comme une suite d'intervalles non vides, triés,
> deux à deux **non fusionnables**. Deux intervalles sont fusionnables quand leur
> union est un intervalle.

*Preuve.* C'est l'argument de 2.1 sur les composantes connexes de `ℝ`. Deux
conventions rendent l'écriture des bornes unique :
- une borne infinie ne porte pas de drapeau ouvert/fermé ;
- `-0.0` s'écrit `0.0`. ∎

*Code* : `floats_of`, `normal_zero`. *Tests* : `test_law_floats`,
`test_normal_floats`.

### Théorème 2.3 — chaînes : l'inclusion est décidée exactement, par les dérivées

Un ensemble de chaînes est un langage régulier, gardé sous la forme de
l'expression qui l'écrit, en **forme de similarité** et partagée (`Regex`,
`regular.odin`) :

```
"a" | "ab"     Words    un ensemble fini de mots ({""} est ε)
'a'..'z'       Class    un mot d'une lettre dans la plage
x + y          Cat      associée à droite
x | y   x & y  Alt, And aplaties, triées par id, sans doublon
~x             Not      (~∅ : toute chaîne)
x * 2..4       Repeat   par un ensemble de comptes naturels
```

> **(a)** Chaque construction (`strings_union`, `_intersect`, `_complement`,
> `_concat`, `_repeat`, `_prefixed`, `_suffixed`) rend une expression du langage
> attendu. Deux expressions semblables (Owens, Reppy, Turon, déf. 4.1) sont le
> même nœud.
>
> **(b)** `strings_subset(A, B)` est vrai si et seulement si `L(A) ⊆ L(B)`.

*Preuve de (a).* Chaque constructeur applique des réécritures, et chacune garde le
langage :
- l'aplatissement de `|` et `&`, triés et sans doublon (associativité,
  commutativité, idempotence) ;
- `+` associée à droite ;
- ∅ absorbant pour `+` et `&`, neutre pour `|` ; `~∅` absorbant pour `|`, neutre
  pour `&` ;
- `""` neutre pour `+` ;
- la fusion de deux mots voisins dans `+` ;
- la réunion des ensembles finis de mots dans `|` ;
- `~~x = x` ;
- `Words & X` = les mots de `Words` que `X` reconnaît ;
- `x * {0} = ""`, `x * {1} = x`, `w * {n} = wⁿ`, les comptes négatifs retirés ;
- `x * C = x * 0..max C` quand `"" ∈ x`, car alors `xᶜ ⊇ xᵈ` pour `d ≤ c`.

Le partage (`intern`) identifie deux nœuds de même structure, opérandes comparés
par adresse. ∎

*Preuve de (b).* Par les **dérivées de Brzozowski** (`derive`) : `∂c L = { w |
c·w ∈ L }`, calculée sur l'expression par les règles d'Owens et al. (§3.1). Pour la
répétition, `∂c(x^C) = ∂c(x) · x^(C-1)` : on dérive le premier morceau non vide. La
normalisation de (a) rend cette règle juste aussi quand `"" ∈ x`.
1. `w ∈ L(r)` ⇔ la dérivée de r par les lettres de w accepte "" (`regex_contains`).
2. On n'a besoin que d'une dérivée par **classe** de caractères. Ce sont les plages
   où la dérivée ne change pas, sur-approchées par les bornes des plages et la
   première lettre des mots (`cuts`, `classes` ; Owens et al. §4.2).
3. `witness(r)` explore les dérivées en largeur, comparées par adresse. Il rend le
   premier mot accepté rencontré, donc le plus court, puis le premier dans l'ordre
   des points de code. Il termine parce qu'une expression n'a qu'un nombre fini de
   dérivées à similarité près (Brzozowski, 1964).

Donc `L(A) ⊆ L(B)` ⇔ `L(A & ~B) = ∅` ⇔ `witness(A & ~B)` ne trouve rien. Quand `A`
est un ensemble fini de mots, on teste chaque mot dans `B`, ce qui revient au même. ∎

**Lectures.** Elles ne dépendent que du langage, jamais de l'écriture :
- `strings_default` : `witness`, donc le plus petit mot ;
- `strings_count`, saturé à 2 : un témoin `w`, puis un témoin de `L ∖ {w}` ;
- `strings_words` : l'automate des dérivées, émondé (Owens et al., fig. 1).

Les décisions sont mémoïsées par nœud, puisque les nœuds sont partagés et
immuables. Il n'y a ni déterminisation, ni produit d'automates, ni automate gardé.

*Tests* :
- `test_law_strings` : l'appartenance contre l'énumération des mots de longueur
  ≤ 5 ; les lois décidées par double inclusion ; le compte, le mot unique, le défaut ;
- `test_decide_strings` : des paires égales par une loi ; une inclusion décidée vaut
  sur les mots courts ; une inclusion refusée a un témoin, dans `A` et hors de `B`.

### Théorème 2.4 — scopes : les formes et leurs combinaisons

Une couleur de scope sans production est une **forme** : l'ensemble des scopes de
même structure (noms et kinds, dans l'ordre) dont chaque binding est admis par le
sien. Un binding nommé sans couleur n'impose rien. Les combinaisons `|`, `&` et `~`
de formes sont un **BDD paresseux** (`bdd.odin` ; Frisch, thèse, ch. 7 ;
Elixir 1.19) : `{a, oui, peut, non} = (a & oui) | peut | (~a & non)`.

> `bdd_subset(A, B)` est vrai si et seulement si tout scope de `A` est dans `B`.

*Preuve.*
- **Les opérations gardent l'ensemble.** `bdd_or`, `bdd_and` et `bdd_diff`
  appliquent les identités booléennes, atome par atome dans l'ordre des ids. Une
  union reste dans `peut` au lieu d'être distribuée.
- **Le vide se lit chemin par chemin.** Un chemin est une intersection de formes
  positives moins des formes négatives. Le BDD est vide si et seulement si chaque
  chemin l'est (`bdd_is_empty`).
- **Un chemin se lit champ par champ.** Des formes de structures différentes sont
  disjointes. Sans forme positive, il reste toujours des scopes, car il existe
  d'autres structures. Sinon, l'intersection des positives est un produit
  `F₁ × … × Fₙ`, et il faut décider s'il est couvert par l'union des négatives de
  même structure. On retire une négative `N` à la fois : `F ∖ N` est l'union, pour
  chaque champ i, de `F` avec `Fᵢ ∖ Nᵢ` (`product_covered`). Chaque champ est un
  ensemble, décidé par ce §2. ∎

**L'admission d'un scope valeur** (`bdd_admits`) suit le BDD, avec une appartenance
à quatre valeurs : toujours, pas toujours, jamais, inconnu.
- « Pas toujours » veut dire qu'une valeur des inconnues sort de l'ensemble. Il ne
  se nie pas, et deux « pas toujours » ne se combinent pas par « ou » : ce ne sont
  pas forcément les mêmes valeurs.
- « Jamais » se combine librement.

Sur une valeur sans inconnue, « pas toujours » est « jamais », et l'admission est
exacte.

*Tests* : `test_law_scopes`. Il confronte le BDD à un modèle fini **exact** : un
univers qui contient un représentant de chaque classe de scopes, y compris les
structures et les valeurs qu'aucune forme n'atteint. L'appartenance, le vide et
l'inclusion doivent coïncider exactement.

### Théorème 2.5 — ensembles mixtes

> `set_subset(A, B)` est vrai si et seulement si `A ⊆ B`.

*Preuve.* Les sortes sont disjointes : `A ⊆ B` si et seulement si l'inclusion vaut
dans chaque sorte, et chacune est décidée par 2.1 à 2.4. Le défaut ne dépend que
de l'ensemble. On prend la première sorte non vide dans un ordre fixe, puis son
élément distingué, qui est une fonction de la composante (2.1–2.3). Une forme seule
a pour défaut la forme elle-même. ∎
*Tests* : `test_decide_sets`, `test_law_defaults`, `test_law_mixed_complement`.

### Clôture

- **Entiers et flottants.** Les opérations `∪ ∩ ~` restent dans les unions finies
  d'intervalles. L'arithmétique `+ - *` est sur-approchée par intervalles : c'est
  un sur-ensemble, voir §4.
- **Chaînes.** Les langages réguliers sont clos par `∪ ∩ ~`, par la concaténation et
  par la répétition `L^S`, où `S` est une union finie d'intervalles de `ℕ`. Les
  plages de caractères `'a'..'z'`, les préfixes `p..` et les suffixes `..s` sont
  réguliers.
- **Caractères.** Ils se plongent dans les chaînes (un caractère comme la chaîne
  d'une lettre, `ε_c` comme `""`) pour `+`, `*`, et pour l'admission par une
  couleur `string`.

---

## 3. Les inconnues : une forme normale par algèbre

Une inconnue est un symbole `??k` qui porte l'ensemble de ses valeurs possibles.
Une inconnue dont l'ensemble n'a qu'une valeur est cette valeur (`new_symbol`).
Ici, la forme normale sert la **précision** : `n - n` doit valoir `0`, pas
`-255..255`.

### Théorème 3.1 — entiers : forme normale unique des polynômes

> Tout polynôme de `ℤ[??₀, ??₁, …]` a une seule écriture `Σ cᵢ·mᵢ + c`, où les
> monômes `mᵢ` sont distincts et triés (par degré, puis par ids), et où les
> coefficients `cᵢ` sont non nuls. Sans monôme, c'est l'atome `c`.

*Preuve.* Les monômes forment une base du `ℤ`-module `ℤ[X]` : la décomposition sur
une base est unique. L'ordre total fixé sur les monômes rend l'écriture unique.
`poly_add`, `poly_sub` et `poly_mul` (`unknown.odin`) calculent dans cette base et
renormalisent : ils trient, fusionnent les monômes égaux et retirent les zéros. ∎

*Tests* :
- `test_law_polynomials` : évaluation en tout point d'un domaine ; commutativité ;
  `(a+b)(a-b) = a² - b²` ;
- `test_normal_polynomials` : même forme ⇔ même polynôme, l'identité étant décidée
  par évaluation en des points aléatoires (lemme de Schwartz–Zippel).

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

### Théorème 3.3 — chaînes inconnues : forme normale des mots

> Une concaténation dont des parties sont inconnues s'écrit comme la suite aplatie
> de ses parties, les littéraux voisins fusionnés et le mot vide retiré.

*Preuve.* C'est la forme normale du monoïde libre engendré par les littéraux et les
symboles, modulo l'associativité de la concaténation et la fusion des littéraux. ∎

### Théorème 3.4 — flottants inconnus

> Deux expressions flottantes ont la même écriture si elles sont égales modulo la
> commutativité de `+` et de `*`, `-(-x) = x`, `a - b = a + (-b)` et `x·1.0 = x`.

*Preuve.* Ces lois sont exactes en IEEE 754. Les opérandes sont ordonnés par leur
écriture, et les constructeurs appliquent ces lois et aucune autre. ∎
L'associativité n'est **pas** une loi IEEE : elle n'est pas appliquée (§7).

### Théorème 3.5 — ensembles qui dépendent d'inconnues

> Un ensemble qui dépend d'inconnues énumérables est une fonction des valeurs des
> inconnues vers les ensembles. Il s'écrit comme la table de ses valeurs, restreinte
> aux inconnues dont elle dépend vraiment. **Une table constante est son ensemble** :
> c'est un singleton, donc une couleur possible.

*Preuve.*
- Une fonction dépend d'une inconnue s'il existe deux affectations qui ne diffèrent
  qu'en elle et donnent des ensembles différents. `prune` compare les entrées par
  double inclusion (§2), et retire exactement les inconnues dont la table ne dépend
  pas.
- Sans inconnue retenue, la fonction est constante : c'est l'ensemble. ∎

La corrélation est gardée : `(n | 6) & (n | 7)` vaut `{n}` pour chaque n.
*Code* : `set_operation`, `family_expr`, `prune` (`family.odin`). *Tests* :
`test_law_families` (la table contre le calcul direct, pour chaque affectation),
`test_normal_families`.

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
- **opérateur sur des valeurs** : la forme normale est une équivalence (§3), donc
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
3. **L'admission a trois issues** (`admits`, `check.odin`) : prouvée, réfutée, ou
   non prouvée. Seule « prouvée » accepte. « Non prouvée » est l'erreur
   `Unproven`, jamais une acceptation.
   - un atome doit être élément de la couleur (§2, exact) ;
   - `none` n'est admis que par une couleur vide ;
   - un caractère est admis par une couleur de chaînes ;
   - un scope valeur est admis par une forme, ou une combinaison de formes (2.4).
     Une couleur de scope qui n'est pas close se lit binding par binding
     (`scope_admits`), avec les mêmes trois issues ;
   - une valeur sur des inconnues (`value_in`) se décide **par paliers**, du moins
     cher au plus cher :
     1. **l'enveloppe** (`envelope`), sans énumérer. Elle est sûre (§4), et
        **exacte** quand aucune inconnue ne se répète et que l'opération est exacte
        sur des ensembles indépendants (`±x ± y`, une concaténation de mots). Une
        enveloppe admise prouve ; une enveloppe exacte non admise, ou dont rien
        n'est admis, réfute ;
     2. **`a·x + b`**, une seule inconnue, se décide exactement (`affine_in`) :
        l'antécédent d'un trou de la couleur est un intervalle de x, croisé avec
        l'ensemble de x. Sinon, pour une forme de degré 1, le min et le max sont
        **atteints** aux bornes des inconnues (`linear_extremes`) : s'ils sortent
        de la couleur, c'est réfuté ;
     3. **l'énumération** exacte, si les inconnues s'énumèrent ;
     4. sinon, `Unproven`.

   Chaque palier ne dit « prouvé » ou « réfuté » que quand c'est vrai : une
   sur-approximation ne prouve que si elle est admise toute entière. ∎

*Tests* : `test_law_value_in` (paliers contre la force brute, petits domaines),
`test_law_affine` (domaines trop grands pour être énumérés), `test_law_admission`.

**Typage bidirectionnel.** La couleur attendue descend dans la valeur : un `??` la
prend, et un scope littéral passe à chaque binding la couleur de la forme qui
l'attend. Pour une combinaison de formes, c'est la seule forme de sa structure.
Cela ne change pas la sûreté (la vérification finale a lieu quand même). Cela
rend précis ce qui ne l'était pas : `Point:p -> {x -> ??  y -> 2}` donne à l'inconnue
la couleur `u8`.

**Corollaire.** Un programme accepté respecte toutes ses couleurs, quelles que soient
les valeurs de ses inconnues. Les preuves `true:p -> …` en sont un cas particulier.

---

## 6. Les lois

Une loi vraie sur les ensembles est vérifiée par la décision d'égalité (double
inclusion). Pour les intervalles et les polynômes, la forme normale étant unique,
elle est aussi vérifiée sur la structure.

| Loi | Où elle est vérifiée |
|---|---|
| `A ∪ B = B ∪ A`, `A ∩ B = B ∩ A` | `test_law_*`, `test_decide_sets` |
| `A ∪ A = A`, absorption `A ∪ (A ∩ X) = A` | `test_law_strings`, `test_decide_*`, `test_normal_*` |
| `~~A = A`, De Morgan | `test_law_ints`, `test_law_floats`, `test_law_strings` |
| `A ∩ (B ∪ C) = (A ∩ B) ∪ (A ∩ C)` | `test_law_strings` |
| `(A ∩ X) ∪ (A ∩ ~X) = A` (X de même sorte) | `test_normal_*`, `test_decide_strings` |
| `(A + B) + C = A + (B + C)`, `A + "" = A` | `test_law_strings`, `test_decide_strings` |
| `A * 0..2 = "" ∪ A ∪ AA`, `A * 1..3 = A + A * 0..2` | `test_law_strings`, `test_decide_strings` |
| `2|1 = 2..1`, `2|"a"|3..4 = "a"|2..4` | `kernel_test.odin` |
| `n - n = 0`, `(a+b)(a-b) = a² - b²`, distributivité | `test_law_polynomials`, `test_normal_polynomials` |
| `~~A = A` à travers les sortes (`~~(u8 \| string)`) | `test_law_mixed_complement`, `kernel_test.odin` |
| `|`, `&`, `~` de formes : appartenance, vide, inclusion | `test_law_scopes` |

---

## 7. Limites, dites

1. **Polynômes et comparaisons.** Leur forme est unique en tant que **polynômes**, pas
   en tant que fonctions sur le domaine des inconnues : `n² - n` et `0` coïncident
   sur n ∈ {0,1} mais s'écrivent différemment, et de même `n < 3` et `n² < 9` sur
   `u8`. Les **valeurs** restent exactes (énumération), donc la vérification n'est
   pas affectée. Seule l'égalité des formes l'est.
2. **Flottants.** Leurs ensembles sont des ensembles de réels, pas de valeurs f64
   discrètes. Une expression flottante inconnue n'est réduite qu'aux lois IEEE
   exactes (3.4).
3. **Inconnues liées.** Les paliers supposent des inconnues indépendantes (chacune
   dans son ensemble). Quand le domaine d'une inconnue dépendra d'une autre
   (`m -> ??::(0..n)`), le palier 2 deviendra relationnel (Fourier–Motzkin).
4. **Enveloppes.** `{-> ⊆ U}` est une sur-approximation. Elle n'est jamais utilisée
   pour affirmer une égalité ou une inclusion de types, ni comme couleur.
5. **Limites de taille.**
   - Au-delà de 65 536 affectations, on n'énumère plus : les valeurs sont
     sur-approchées.
   - Au-delà de 4 096 répétitions, une répétition n'est pas construite.
   - Un littéral, ou un calcul exact sur des valeurs ou des ensembles, qui sortirait
     de l'univers des entiers (2.1) n'est pas calculé.

   Ces trois cas sont des erreurs explicites (`Unsupported`), jamais une
   approximation de couleur. Seule une enveloppe de valeurs (§4) qui sort de
   l'univers devient infinie de ce côté, ce qui est une sur-approximation sûre.
6. **Pas encore dans le kernel.** Les propriétés ci-dessus portent sur ce que le
   kernel implémente. Le carve, les patterns, la récursion (formes récursives :
   l'inclusion coinductive de CDuce), les trous `<-` et les effets restent à prouver
   de la même façon quand ils seront ajoutés. Toute forme non implémentée signale
   `Unsupported` : elle ne produit jamais un résultat non couvert par ces théorèmes.

---

## 8. Où vérifier

| Propriété | Code | Tests |
|---|---|---|
| 2.1 entiers, caractères | `set.odin` : `ints_of` | `test_law_ints`, `test_normal_ints`, `test_law_chars*` |
| 2.2 flottants | `set.odin` : `floats_of` | `test_law_floats`, `test_normal_floats`, `test_law_float_arith` |
| 2.3 chaînes | `regular.odin` : constructeurs, `derive`, `witness` | `test_law_strings`, `test_decide_strings` |
| 2.4 scopes | `bdd.odin` : `bdd_*`, `product_covered`, `bdd_admits` | `test_law_scopes` |
| 2.5 mixtes, sortes portées | `set.odin` : `carried`, `set_complement` | `test_decide_sets`, `test_law_defaults`, `test_law_mixed_complement` |
| 3.1–3.4 inconnues | `unknown.odin` | `test_law_polynomials`, `test_normal_polynomials`, `test_law_float_terms`, `test_law_words` |
| 3.5 tables | `family.odin` | `test_law_families`, `test_normal_families`, `test_law_envelopes` |
| 4.1 correction | `type_of.odin`, `op.odin` | `test_law_*`, corpus `test/typecheck` |
| 5.1 sûreté, paliers | `check.odin` | `test_law_value_in`, `test_law_affine`, `test_law_admission`, corpus `test/typecheck` (383 cas), `kernel_test.odin` |

`odin test kernel` exécute tout.
