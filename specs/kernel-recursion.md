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
d'équations le représente en fini, et l'appartenance d'une valeur se décide (§3).
L'inclusion de deux tels types n'est pas décidable en général : `Unproven` quand
on ne sait pas, jamais une acceptation.

**G — doit passer.** L'argument change à chaque niveau (`T`, puis `{T:}`, puis
`{{T:}:}`…) : chaque niveau est une variable nouvelle, le système n'est pas fini.
Une valeur finie ne descend que d'un nombre fini de niveaux : l'appartenance se
décide en ne créant que les variables qu'elle visite. Reste à trouver la
représentation pour l'inclusion.

**H, I — illégaux** (§1, le cas de base).

## 3. Ce qu'on décide

- **Appartenance d'une valeur** (`a` est-il un `Array{u8}` ?) : la valeur est
  finie, on déplie le système sur elle. Inductif : une appartenance qui dépend
  d'elle-même n'est pas établie (`record_member`, `k.matching`, déjà là).
  Décidable dans **tous** les cas, F compris.
- **Inclusion et vide** (`Array{u8}` ⊆ `Array{u16}` ?) : coinductif, on suppose
  l'inclusion en cours vraie. Exact pour A–E (langages réguliers d'arbres).
  Pour F, `Unproven` quand on ne sait pas, jamais une acceptation.
- **Le défaut** : la solution de l'équation de la première production seule
  (§1) ; une solution infinie rend la définition illégale.

## 4. Les fonctions récursives

Une fonction récursive structurelle suit la récursion de sa donnée : `map`
appelle `map` sur la queue `r` de son argument. Si l'argument est `Array{T}`,
de type `{0..*T:}`, la queue a le **même** type `{0..*T:}`. L'appel récursif a
donc la même inconnue que l'appel en cours (§1) : le type du résultat est une
inconnue `Y` du système, `Y = {} | {E: ...Y}`, soit `{0..*E:}`. Pas de
déroulement : une équation de plus.

Une fonction sur des nombres (`f{n -> n - 1}`) n'a pas de structure : le type de
l'argument change à chaque niveau (`n`, `n - 1`, …), comme dans G. Il faut un
élargissement de l'argument (un intervalle qui grandit jusqu'à se stabiliser,
Cousot & Cousot 1977), ou dérouler quand les valeurs sont connues et qu'on sait
que ça termine.

## 5. À réfléchir

1. **G** — la représentation, pour décider l'inclusion.
2. **E** — dans `Even`/`Odd`, la seule production d'`Odd` passe par `Even` : est-ce
   un cas de base récursif (illégal), ou est-il admis parce que le défaut d'`Even`
   est `{}` ?
3. **Les nombres** (§4) — élargir, ou dérouler sous quelle condition ?
