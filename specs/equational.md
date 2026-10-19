# Le kernel équationnel

> **État : conception, à valider avant la réécriture.** Branche `equational`.
> Remplace l'organisation actuelle du kernel (`kernel/`) par une seule algèbre.
> Principe : `specs/kernel-equations.md`.

## 1. Le principe

Un type est une **équation**. Un type « non équationnel » est une équation
constante.

```text
n -> 3              type(n) = 3
v -> ??::u8         type(v) = v∈u8           v est une variable de domaine u8
c -> v + n          type(c) = v∈u8 + 3
Array -> {…}        type(Array) = X, avec X = {} | {T: ...X}
f{n -> n - 1}!      Y(n - 1), avec Y l'équation de f
```

Typecheck `C:x -> v`, c'est prouver que l'équation de `v` est **contenue** dans celle
de `C`, dans le contexte où le binding est écrit. C'est la seule question.

## 2. La représentation

Une équation est un arbre d'expressions, simplifié en forme normale :

| nœud | exemple | ce qu'il dit |
|---|---|---|
| constante | `3`, `0..255`, `"a"..` | un ensemble connu (l'algèbre actuelle de `set.odin`, `regular.odin`) |
| variable | `v∈u8` | une valeur inconnue ; **elle porte son domaine**, qui est un type, donc une équation |
| opération | `v∈u8 + 3`, `x ++ y`, `A \| B` | arithmétique, concaténation, algèbre d'ensembles |
| scope | `{u8:x  string:y}` | une suite de bindings, chacun avec ses deux équations |
| suite comptée | `{0..*T:}` | la répétition d'une suite, comptée par un ensemble |
| cas | `v<10 → v + 3 ; sinon → 10` | une équation par morceaux : le résultat d'un pattern |
| inconnue d'équation | `X`, `Y(n - 1)` | un type défini par une équation qui la mentionne |

- **Pas de table.** Une variable est un nœud qui porte son domaine. Le domaine est un
  type comme un autre, donc une équation : `v∈u8`, `v∈Array{u8}`, `v∈(w∈u8 + 1)`.
  Deux mentions de
  `v` sont le **même** nœud : `v + v = 2·v`, alors que deux `??` distincts restent
  deux variables.
- **Pas d'aplatissement.** Le résultat d'un pattern reste un **cas** ; il n'est jamais
  remplacé par une nouvelle inconnue sur l'union des résultats.
- **Une seule sorte d'inconnue.** `??` est une variable dont le domaine est connu ;
  une self-référence et un appel récursif sont des inconnues d'équation. Elles
  entrent toutes dans les opérations : `n + Y(n - 1)` est une expression comme une
  autre.

## 3. Le contexte

Le raffinement n'est pas une réécriture : c'est une **information contextuelle**.
Chaque binding est typé dans un contexte, un ensemble de faits sur les variables :

```syntact
u8:l -> v ? {<10 -> c, -> 10}
```

- dans la première branche, le contexte dit `v ∈ 0..9` ;
- dans la seconde, `v ∈ 10..255` ;
- `c` a toujours l'équation `v∈u8 + 3` ; c'est le contexte qui la rend contenue dans
  `u8` (`v ∈ 0..9` donne `3..12`).

Le contexte est passé explicitement au typage et à la vérification, jamais rangé
dans un état global. Une branche ajoute un fait ; en sortir le retire.

Le type de `l` est le cas `v<10 → v∈u8 + 3 ; sinon → 10` : il garde l'information.

## 4. Les opérations

1. **Simplifier** en forme normale : polynômes (déjà dans `unknown.odin`), ensembles,
   chaînes, scopes ; puis résoudre ce qui peut l'être — Arden (suites comptées),
   forme close (récurrences sur des nombres).
2. **Contenir** (`A ⊆ B` sous un contexte) : la seule décision. Par paliers, sans
   énumérer quand une règle algébrique suffit (enveloppe, forme affine, intervalle) ;
   énumérer un domaine borné en dernier recours ; `Unproven` si on ne sait pas.
3. **Substituer** : une inconnue d'équation appliquée à des arguments
   (`Y(5)`, `Y(v∈u8)`), une variable par son domaine raffiné.
4. **Lire sur une valeur** : l'appartenance d'une valeur finie à une équation
   récursive, sans la déplier.

## 5. La récursion

Les lois de `specs/kernel-recursion.md` restent : un scope ne voit son nom que dans
ses productions ; le cas de base vient en premier, non récursif ; la terminaison est
prouvée ; on ne déplie jamais. La self-référence et l'appel récursif deviennent des
inconnues d'équation ordinaires, dans la même algèbre que tout le reste.

## 6. Ce qui disparaît du kernel actuel

- `k.symbols` (les domaines rangés à part) : la variable porte son domaine ;
- `k.refined` (les raffinements empilés) : le contexte passé au typage ;
- `Itself`, `k.defining`, `k.building` : la self-référence est une inconnue
  d'équation, la visibilité se décide à la construction ;
- `new_symbol` sur l'union des résultats d'un pattern : le cas.

## 7. Ce qui reste

L'algèbre des ensembles (`set.odin`, `regular.odin`, `bdd.odin`), les polynômes
(`unknown.odin`), la construction de l'IR (`build.odin`), le carve, les trous,
l'impression, les tests et le corpus : ils servent de base et de référence. Le
corpus (`test/typecheck/tests`) doit passer au moins aussi bien qu'aujourd'hui
(555 réussis).

## 8. Questions à trancher

1. **L'écriture du domaine** : comment s'imprime une variable (`v∈u8`, `(v:u8)`…) ?
2. **L'identité d'une variable** : deux `??` écrits à deux endroits sont deux
   variables ; une même variable est partagée par toutes ses mentions. Les copies
   d'un carve : nouvelles variables, ou les mêmes ?
