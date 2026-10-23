# La décision du kernel : une seule question

> **État : proposition, à valider avant tout code.** Remplace la vérification
> actuelle du kernel (`check.odin`, `set_form.odin`, les paliers de `value_in`, les
> `Fact`). Elle s'appuie sur `specs/kernel-equations.md` (un type est une équation)
> et ne change aucune loi du langage.

## 1. Pourquoi

Le kernel actuel n'a pas une algèbre mais six représentations (`Set`, `Poly`, `Term`,
`Var`, `Set_Form`, `Cases`), et une table de cas par paire de formes. La décision est
faite d'heuristiques empilées : une enveloppe, une forme affine, des extrêmes
linéaires, un témoin aux coins des domaines. Chaque forme oubliée devient
`Unsupported` ou `Unproven`. Sur 40 sondes, 18 échouent, dont `a ∈ a | a`, `a ∈ ~~a`,
`true ∈ a | ~a`, et un programme valide refusé (`(a + 1) ? {<50 -> a, -> 0}` contre
`..48`).

Cette spec pose **une** représentation, **une** traduction et **une** question.
Tout le reste en découle.

## 2. Les termes

Un type est un terme. Il n'y en a qu'une sorte :

```text
T ::= K                  un ensemble connu : l'algèbre de set.odin, regular.odin, bdd.odin
    | x                  une variable ; elle porte son domaine, qui est un terme
    | op(T, …)           + - * / % \, concaténation, répétition, comparaison
    | T | T   T & T   ~T
    | T..T   >T  <T  >=T  <=T  !=T
    | g₁ → T₁ ; … ; gₙ → Tₙ        un terme par morceaux : le résultat d'un pattern
    | {b₁ … bₙ}           un scope : des bindings, chacun avec ses termes
    | X   Y(T, …)         une inconnue d'équation (specs/kernel-recursion.md)
```

- Un **terme valeur** désigne une seule valeur pour chaque valeur des variables
  (`5`, `x`, `x + 1`, `"a" + s`). Un **terme ensemble** désigne un ensemble (`u8`,
  `>x`, `x | 300`). Une valeur est son singleton : `5` est `5..5`, `x` est `{x}`.
  La différence se lit sur le terme ; elle n'est pas une seconde représentation.
- Deux mentions d'une variable sont le **même** nœud ; deux `??` écrits sont deux
  variables.
- Les formes normales existantes restent : les polynômes entiers, les mots, les
  comparaisons normalisées (`unknown.odin`). Elles servent à l'égalité de termes et
  à la canonicité des atomes (§6), pas à la décision.

## 3. L'appartenance : chaque ensemble est un prédicat

Le cœur de la spec. Pour tout terme `T` et toute valeur `y`, `y ∈ T` se traduit en
une **formule** sur `y` et les variables, par une seule fonction récursive :

| terme | `y ∈ terme` |
|---|---|
| `K` connu | l'atome `y ∈ K` |
| un terme valeur `v` | `y = v` |
| `A \| B` | `y ∈ A  ou  y ∈ B` |
| `A & B` | `y ∈ A  et  y ∈ B` |
| `~A` | `sorte(y) ∈ sortes(A)  et  non (y ∈ A)` |
| `>v`, `<v`, `>=v`, `<=v`, `!=v` | `y > v`, … (`y` de la sorte de `v`) |
| `lo..hi` (nombres, caractères) | `(lo ≤ y ≤ hi)  ou  (hi ≤ y ≤ lo)` |
| `lo..hi` (chaînes) | `y` commence par `lo` et finit par `hi` |
| `K + v`, `K - v` | `y - v ∈ K`, `y + v ∈ K` |
| `A ⊕ B`, deux ensembles qui dépendent de variables | `il existe a ∈ A, b ∈ B, y = a ⊕ b` |
| `g₁ → T₁ ; … ` | `(g₁ et y ∈ T₁)  ou  …` |
| une forme `{C₁:f₁ …}` | `y` a la structure de la forme, `et  y.f₁ ∈ C₁  et …` |
| `=X` | `y` est l'ensemble `X` (égalité d'ensembles) |
| `X` équation | `y ∈ corps(X)`, lu le long de `y` (§7) |

La sorte d'un `~` est celle que l'ensemble porte (`specs/constraints.md`) : `~a`
avec `a ∈ u8` est « tout entier sauf `a` ».

Exemple, la question du maintainer : `y ∈ a & <100` donne `y = a  et  a < 100`.
C'est « `a` si `a < 100`, rien sinon ». Sans contexte, on ne sait pas si `a < 100` ;
dans une branche qui sait `a < 40`, c'est vrai (§5).

## 4. La question unique

Typecheck `C:x -> v`, c'est prouver que pour toute valeur des variables admise par
leurs domaines et par le contexte `Γ`, `v ∈ C`. On pose la **formule d'échec** :

```text
Échec  =  domaines  et  Γ  et  non (v ∈ C)
```

- **Échec impossible** : prouvé.
- **Échec possible**, avec un **témoin** (une valeur de chaque variable) : réfuté,
  `Constraint_Mismatch`. L'erreur montre le témoin : « `a = 150` : 150 ∉ ..99 ».
- **Le kernel ne sait pas décider** une partie de la formule, et aucune autre partie
  ne donne de témoin : `Unproven`. Seulement pour les cas de la liste fermée du §8.

`Unproven` n'est donc plus « une règle manque » : c'est « cette théorie est
indécidable ici », et la liste dit où.

Les autres questions du kernel sont **la même** question, avec une autre formule :

| question | formule d'échec |
|---|---|
| un binding coloré | `non (v ∈ C)` |
| un pattern exhaustif | `non (cible ∈ cover₁ ou … ou cible ∈ coverₙ)` |
| une branche atteignable | la garde de la branche est-elle possible ? (le témoin est la réponse) |
| un diviseur | `diviseur = 0` |
| un trou (`hole.odin`) | `non (envoyé ∈ requis)` |

## 5. Le contexte est une formule

Le contexte `Γ` est la conjonction de ce que savent les branches qui entourent le
binding. La garde de la branche `i` d'un pattern est :

```text
cible ∈ coverᵢ  et  non (cible ∈ cover₁)  et … et  non (cible ∈ coverᵢ₋₁)
```

- La cible est **n'importe quel terme**, pas seulement une variable seule :
  `(a + 1) ? {<50 -> a}` donne `a + 1 < 50`, donc `a ≤ 48`.
- Un booléen est un terme comme un autre : `t -> a < 100`, puis `t ? {true -> a}`
  donne `a < 100`.
- Un cover qui dépend d'une variable est une formule comme une autre :
  `a ? {=b -> …}` donne `a = b`. Les faits relationnels viennent d'eux-mêmes.

Le résultat d'un pattern est le terme par morceaux `garde₁ → produit₁ ; …`. Il n'est
jamais aplati ; un produit peut être un scope.

## 6. La décision

1. **Simplifier la formule** par les lois de l'algèbre de Boole, sur des **atomes
   canoniques** : idempotence, absorption, `non non A = A`, `A ou non A = vrai`,
   De Morgan. Un atome est canonique quand deux atomes équivalents s'écrivent pareil :
   `y ≤ a` est `non (y > a)` sur les entiers, par la normalisation de
   `int_compare`. Ainsi `y > a ou y ≤ a` est `vrai` sans calcul.
2. **Décider les atomes clos** par l'algèbre des ensembles connus. C'est la loi de
   l'union (« on prouve l'union entière d'abord ») : une partie close se décide
   seule, et `11 ∈ 6..255` rend `vrai` toute la disjonction, quoi que vaille l'autre
   membre.
3. **Découper** ce qui reste en **cellules** : chaque cellule est une conjonction
   d'atomes, et la formule est vide si chaque cellule l'est. Le découpage est
   paresseux, comme le BDD des formes (`bdd.odin`) : on ne distribue qu'en décidant.
   C'est la loi « par morceaux, par valeur » : un morceau indécidable n'empêche pas
   un autre de prouver.
4. **Décider chaque cellule** par la théorie de sa sorte (§7). Une cellule possible
   donne le témoin.

Verdict : une cellule possible → réfuté ; toutes impossibles → prouvé ; sinon,
`Unproven`.

## 7. Les théories

Chaque cellule ne parle que de variables typées par sorte. Les sortes sont
disjointes ; une égalité entre deux sortes différentes est fausse.

- **Entiers, caractères.** Les atomes sont des comparaisons de polynômes, et
  l'appartenance d'un polynôme à une union d'intervalles. `/` et `%` introduisent un
  quotient et un reste : `a = b·q + r`, avec `r` borné par `b` (`\` vers un layout
  est un `%`).
  - **Linéaire** : décidé exactement, bornes infinies comprises (Presburger ; le test
    Omega de Pugh, 1991). `≠` se découpe en `<` ou `>`.
  - **Non linéaire, domaines bornés** : propagation d'intervalles, puis bissection
    du domaine d'une variable ; complet, puisque les domaines sont finis. Question 1.
  - **Non linéaire, domaine infini** : `Unproven` si la propagation ne conclut pas.
- **Booléens.** Domaine fini de deux valeurs : décidé.
- **Chaînes.** Chaque variable a un domaine régulier. Une concaténation de variables
  et de littéraux appartient à un langage régulier : décidé (produit des automates
  des dérivées, `regular.odin`). Une égalité entre deux mots qui ont tous deux des
  variables est une équation de mots : `Unproven`.
- **Flottants.** En attente de l'algèbre f32/f64 (`f32-f64` reste un trou connu).
  D'ici là, des intervalles réels, comme aujourd'hui.
- **Scopes.** Une forme se traduit champ par champ (§3) : la cellule reçoit des
  atomes sur les champs. Une forme qui dépend d'une variable n'est plus un cas à
  part. Les formes closes gardent leur BDD.
- **Ensembles comme valeurs (`=X`).** `X` clos : l'égalité d'ensembles de §2 de
  `kernel-algebre.md`. `X` qui dépend de variables : question 3.
- **Équations (`X`, `Y(…)`).** L'appartenance d'une valeur finie se lit le long de
  la valeur : chaque lecture consomme un binding de la valeur, donc elle termine (la
  loi de garde de `kernel-recursion.md` §1). L'inclusion de deux équations suit
  `kernel-recursion.md` §6. Un appel récursif résolu en forme close est un terme
  ordinaire.

## 8. `Unproven` : la liste fermée

1. Polynômes non linéaires sur un domaine infini, quand la propagation ne conclut
   pas.
2. Équations de mots : variables des deux côtés d'une égalité de chaînes.
3. `il existe` d'une opération entre deux ensembles qui dépendent tous deux de
   variables (§3), et `=X` avec `X` dépendant de variables : questions 2 et 3.
4. Inclusion de deux équations non résolues que `kernel-recursion.md` §6 ne sait pas
   comparer.
5. Flottants, tant que l'algèbre f32/f64 n'existe pas.

Une forme hors de cette liste qui donne `Unproven` est un bug du kernel, pas un
résultat.

## 9. Le juge

L'oracle (`oracle_test.odin`) énumère les valeurs des variables sur des domaines
finis. Un générateur produit au hasard des couleurs et des valeurs : tous les
constructeurs du §2, variables partagées entre couleur et valeur, patterns,
contextes. Pour chaque cas :

- le verdict du kernel est **celui de l'oracle** ;
- sur des domaines finis, `Unproven` est un échec du test (le §7 y est complet) ;
- un témoin donné par le kernel est vérifié par évaluation.

C'est la seule porte : on ne passe pas un test du corpus avec une règle de forme.

## 10. Ce qui disparaît, ce qui reste

**Disparaît** : `Set_Form` et `simplified` ; `conditions`, `admitted`, `admits`,
`value_in`, `affine_in`, `linear_extremes`, `outside_at_bounds`, `corners`,
`form_in` ; `Fact` et le contexte par variable seule ; les `Unsupported` « cover qui
dépend d'une inconnue », « branche qui donne un scope », « forme qui dépend d'une
inconnue », « `-` sur un ensemble qui dépend d'une inconnue ».

**Reste** : l'algèbre des ensembles connus (`set.odin`, `regular.odin`, `bdd.odin`),
les formes normales (`unknown.odin`), la construction de l'IR, le carve, les
expansions, l'impression, l'oracle.

Le noyau neuf se construit à côté de l'actuel. On bascule quand le juge est vert et
que le corpus fait au moins aussi bien.

## 11. Les sondes, résolues

| sonde | formule d'échec | verdict |
|---|---|---|
| `(a \| a):b -> a` | `non (a = a ou a = a)` → faux | prouvé |
| `(~~a):b -> a` | `non non non (a = a)` → faux | prouvé |
| `(a \| ~a):b -> true` | `non (vrai)` | prouvé |
| `(>a \| <=a):c -> b` | `non (b > a ou non b > a)` | prouvé |
| `(a..b):c -> a` | `non ((a≤a≤b) ou (b≤a≤a))` → `non (a≤b ou b≤a)` | prouvé |
| `11 ∈ (u8 & >5) \| (a & <100)` | `non (vrai ou …)` (atome clos) | prouvé |
| `a -> ??`, `a:b -> 10` | `non (10 = a)` | réfuté, `a = 0` |
| `(u8 & >200 \| (a & <100)):b -> a` | `a ≤ 200 et non (a < 100)` | réfuté, `a = 100` |
| `(n-5)*(n-5)`, `>0`, `n ∈ 0..10` | `n² - 10n + 25 ≤ 0` | réfuté, `n = 5` |
| `(a+1) ? {<50 -> a, -> 0}` contre `..48` | garde `a+1 < 50 et non (a ≤ 48)` ; garde `non (a+1 < 50) et non (0 ≤ 48)` | prouvé |
| `t -> a < 100 ; t ? {true -> a, -> 0}` contre `..99` | garde `a < 100 et non (a ≤ 99)` | prouvé |
| `a ? {=b -> 1, -> 2}` | une garde `a = b`, l'autre `a ≠ b` | typé, par morceaux |

## 12. Questions

1. **Non linéaire borné.** La bissection d'un domaine fini est complète, mais elle
   peut coûter, dans le pire cas, autant que l'énumération. Est-ce admis ? Sinon,
   `Unproven` au-delà d'un budget, et le juge doit le tolérer.
2. **Opération entre deux ensembles symboliques** (`(a | 3) * (b | 4)` comme
   couleur). La traduction a un `il existe`, qui devient un `pour tout` dans la
   formule d'échec. `Unproven` (liste fermée), ou faut-il l'éliminer ?
3. **`=X` avec `X` symbolique** (`=(a | 3):c -> …`). L'égalité de deux ensembles
   qui dépendent de variables est une formule avec un `pour tout` sur leurs éléments.
   Même question.
