# Les types récursifs : une représentation finie de types infinis

> **État : réflexion en cours, rien n'est implémenté.**

Le kernel représente déjà des types infinis en fini : `1..` (tous les entiers à
partir de 1), `~5`, `'a'..'z' * 2..` (un langage régulier de chaînes), `{...C:}`
(toute suite de bindings que C admet). Un type récursif est un type infini de
plus : `Array{T}` est l'ensemble de toutes les suites finies de `T`, ce qu'on
écrirait `{0..*T:}` — sa première production est `{}`, sa seconde `{1..*T:}`.

Ce document fait la liste des cas, et pour chacun : sa représentation finie, et
ce que le kernel sait en décider.

## 1. La self-référence est une inconnue de type

Dans `Array`, `...Array{T}:` désigne le type qu'on est en train de définir. On le
traite comme une **inconnue** : `X`, le type d'`Array{T}`.

Ce n'est pas l'inconnue de `??`. `??::u8` est une **valeur** inconnue, dont le
type est connu (`??0 ∈ 0..255`). `X` est un **type** inconnu : c'est lui qu'on
cherche. Une référence au scope qu'on définit, avec ses propres arguments, est
`X` ; `G` (`Nest{T -> {T:}}`) est `X` appliqué à d'autres arguments, une inconnue
paramétrée `X(T)`.

On type les productions avec `X` à la place de la self-référence, et une
**équation** émerge :

```text
X = {} | {T: ...X}
```

Sa solution est le type, en représentation finie :

```text
X = {0..*T:}          la première production : {}, la seconde : {1..*T:}
```

Toutes les self-références d'un programme forment un système fini d'équations
(une par scope récursif, mutuelles comprises) : c'est la représentation finie
d'un type infini.

### Le cas de base découle de l'équation

Le défaut d'un scope est sa première production. Son type est la solution de
l'équation de la **première production seule** :

- `Array` : `d = {}`, une valeur finie ;
- première production récursive (`Infinite`, `tc_infinite_default`) ou pas de cas
  de base (H) : `d = {T: ...d}`, dont la seule solution est `{∞*T:}`, une valeur
  infinie : la définition est illégale ;
- non gardée (I) : `d = {...d}` ne consomme rien, l'équation ne détermine aucune
  valeur : illégale.

La loi « le cas de base vient en premier, n'est pas récursif, et finit » n'est pas
une règle de plus : c'est ce que dit la solution.

## 2. Les cas

| | exemple | équation | type | régulier |
|---|---|---|---|---|
| A | liste, récursion en queue | `X = {} \| {T: ...X}` | `{0..*T:}` | oui |
| B | liste, récursion en tête | `X = {} \| {...X  T:}` | `{0..*T:}` | oui |
| C | liste non vide | `X = {T:} \| {T: ...X}` | `{1..*T:}` | oui |
| D | arbre, récursion par un champ | `X = {} \| {X:l  T:v  X:r}` | arbre régulier | oui |
| E | mutuelle | `X = {} \| {A: ...Y}`, `Y = {B: ...X}` | `{0..*(A: B:)}` | oui |
| F | au milieu d'une suite | `X = {} \| {A: ...X  B:}` | `AⁿBⁿ` | non |
| G | polymorphe | `X{T} = {} \| {T: ...X{{T:}}}` | une variable par niveau | non fini |
| H | sans cas de base | `X = {T: ...X}` | — | **illégal** |
| I | non gardée | `X = {...X} \| {}` | — | **illégal** |

H, I et une première production récursive sont illégaux (§1, le cas de base). A,
B, C, D et F sont supportés. G doit passer aussi.

**A, B, C, E — une suite régulière.** Un scope est une suite de bindings, comme
une chaîne est une suite de caractères. Une équation où la variable n'apparaît
qu'à une extrémité d'une suite se résout par le lemme d'Arden :
`X = A·X | B` donne `X = A*·B` ; `X = X·A | B` donne `X = B·A*`. Le résultat est
une suite répétée, `{0..*T:}`, de la même algèbre que `'a'..'z' * 2..` sur les
chaînes (`regular.odin`) : concaténation, union, répétition par un ensemble de
comptes. La forme se calcule, elle n'est pas un cas particulier.

**D — un arbre régulier.** La variable apparaît dans un champ, un scope imbriqué,
pas dans la suite. Le type reste un graphe fini avec un cycle par le champ : ce
sont les types récursifs de CDuce (Frisch, Castagna, Benzaken, JACM 2008). Les
suites à l'intérieur de chaque niveau restent régulières (A–C) : ce sont les types
« expressions régulières » de XDuce (Hosoya, Vouillon, Pierce, TOPLAS 2005), où
un scope est une haie (une suite d'arbres étiquetés).

**F — supporté, pas régulier.** La variable apparaît au milieu d'une suite.
`AⁿBⁿ` n'est pas un langage régulier : c'est une grammaire algébrique. Le système
d'équations le représente en fini, et l'appartenance d'une valeur se décide (§6).
L'inclusion de deux tels types n'est pas décidable en général : `Unproven` quand
on ne sait pas, jamais une acceptation.

**G — doit passer.** L'argument change à chaque niveau (`T`, puis `{T:}`, puis
`{{T:}:}`…) : chaque niveau est une variable nouvelle, le système n'est pas fini.
Une valeur finie ne descend que d'un nombre fini de niveaux : l'appartenance se
décide en ne créant que les variables qu'elle visite. Reste à trouver la
représentation pour l'inclusion.

**H, I — illégaux** (§1, le cas de base).

## 3. Les types, cas par cas

| cas | équation | type | défaut |
|---|---|---|---|
| A | `X = {} \| {T: ...X}` | `{0..*T:}` | `{}` |
| B | `X = {} \| {...X  T:}` | `{0..*T:}` | `{}` |
| C | `X = {T:} \| {T: ...X}` | `{1..*T:}` | `{T:}` |
| D | `X = {} \| {X:l  T:v  X:r}` | `X = {} \| {X:l  T:v  X:r}` : le type se nomme lui-même | `{}` |
| E | `Even = {} \| {u8: ...Odd}`, `Odd = {string: ...Even}` | `Even = {0..*(u8: string:)}`, `Odd = {string: 0..*(u8: string:)}` | `{}`, `{string:}` |
| F | `X = {} \| {A: ...X  B:}` | `{n*A:  n*B:}`, `n ∈ 0..` | `{}` |
| G | `X(T) = {} \| {T: ...X({T:})}` | n éléments, le k-ième de type `Fᵏ(T)`, `F(T) = {T:}` | `{}` |
| Nested | `X = {} \| {u8: ...X  string:} \| {bool: ...X  f64:}` | l'équation elle-même | `{}` |

`Odd` (E) n'a qu'une production, qui passe par `Even`, mais son défaut
`{string: ...défaut(Even)}` vaut `{string:}`, fini : il est légal.

## 4. Deux nouvelles formes de type

1. **Les suites comptées.** Une suite de bindings, ou d'un groupe de bindings,
   répétée par un ensemble de comptes : `{0..*T:}`, `{1..*T:}`,
   `{0..*(u8: string:)}`. Avec deux variantes : le compte partagé
   (`{n*A:  n*B:}`, `n ∈ 0..`, une inconnue entière comme celles de `??`) et la
   répétition indexée (le k-ième élément de type `Fᵏ(T)`). Même algèbre que
   `'a'..'z' * 2..` sur les chaînes (`regular.odin`).
2. **Les types équation.** L'équation elle-même, gardée comme type :
   `X = {} | {u8: ...X  string:} | {bool: ...X  f64:}`, où `X` désigne le type.
   C'est la forme de base : elle est finie et exacte pour tout type récursif.

## 5. Résoudre quand c'est possible

On résout l'équation en suite comptée quand on le peut :

- récursion à un bout d'une suite (A, B, C, E) : le lemme d'Arden ;
- une seule paire autour de la récursion (F) : un compte partagé ;
- l'argument qui change à chaque niveau (G) : une répétition indexée.

Sinon, le type **reste une équation** : récursion dans un champ (D, les arbres),
plusieurs paires (`Nested`), plusieurs self-références dans une suite. Une forme
comptée de ces types serait une sur-approximation (elle admettrait des valeurs
fausses) : on ne s'en sert jamais comme type.

## 6. Typecheck avec un type équation

**On ne déplie jamais.** Le typechecker travaille sur l'équation telle quelle :

- **Une valeur dans le type** (`Nested:c -> {1 true 2.5 "x"}`) : la valeur est
  finie, on la lit contre l'équation. Toujours décidable.
- **Un type inclus dans un autre** (`Nested:r -> gen{n -> ??}!`, §7) : la
  comparaison porte sur **ce que les types admettent**, jamais sur leur écriture.
  `X = {} | {u8: u8: ...X}` est inclus dans `Y = {} | {u8: ...Y}` alors qu'aucune
  production de X ne correspond à une production de Y.
  - deux suites comptées : on compare les comptes et les éléments (les entiers pairs
    sont inclus dans tous les entiers) ;
  - sinon, élément par élément : ce que chaque type admet en premier, puis ce qu'il
    reste à admettre (les dérivées de Brzozowski, déjà utilisées pour les chaînes),
    en retenant les paires déjà comparées.

  Le kernel s'arrête toujours : sur une paire qu'il ne sait pas comparer, il répond
  « pas prouvé » (`Unproven`), jamais une acceptation. L'inclusion de deux grammaires
  quelconques est indécidable (Bar-Hillel, Perles, Shamir 1961), mais seulement
  pour des types artificiels que personne n'écrit.
- **Un pattern exhaustif** : les branches couvrent-elles chaque production ?
- **Le défaut** : la solution de l'équation de la première production seule
  (§1) ; une solution infinie rend la définition illégale.

## 7. Les fonctions récursives

Une fonction récursive structurelle suit la récursion de sa donnée : `map`
appelle `map` sur la queue `r` de son argument. Si l'argument est `Array{T}`,
de type `{0..*T:}`, la queue a le **même** type `{0..*T:}`. L'appel récursif a
donc la même inconnue que l'appel en cours (§1) : le type du résultat est une
inconnue `Y` du système, `Y = {} | {E: ...Y}`, soit `{0..*E:}`. Pas de
déroulement : une équation de plus.

Une fonction récursive appelée avec une inconnue donne elle aussi un type
équation :

```syntact
gen -> {
  u8:n -> ??
  -> n ? {0 -> {}, -> {1 ...gen{n -> n - 1}!  "x"}}
}

Nested:r -> gen{n -> ??}!
```

`gen{n -> ??}!` a pour type `Y = {} | {1 ...Y "x"}`, soit `{n*1:  n*"x":}`.
Vérifier `r`, c'est vérifier que ce type est inclus dans `Nested` (§6).

Une fonction sur des nombres suit la même loi : on ne la déplie jamais, son
appel récursif est une inconnue, et son type est une équation. Comme pour les
types, on la **résout quand c'est possible**, ici en forme close :

```syntact
sum -> {
  u8:n -> ??
  -> n ? {0 -> 0, -> n + sum{n -> n - 1}!}
}
```

L'équation `sum(n) = n + sum(n - 1)`, `sum(0) = 0` se résout en
`sum(n) = n·(n+1)/2` : le type de `sum{n -> ??}!` est cette forme close, et
`sum{n -> 5}!` vaut `15` par substitution. Sinon, le type reste l'équation.

Les entrées sont en général **bornées** (`u8:n` : `n ∈ 0..255`). La borne sert à
prouver que la forme close ne déborde pas (`255·256/2 = 32640`), et l'ensemble des
valeurs du résultat se calcule sur cette borne.

## 8. À réfléchir

1. **G** — décider l'inclusion de deux répétitions indexées.
2. **Les formes closes** (§7) — quelles classes de récurrences on résout, et le
   débordement à largeur fixe (`specs/research-recursion.md`).
