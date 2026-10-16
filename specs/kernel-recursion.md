# Les types récursifs : une représentation finie de types infinis

> **État : réflexion en cours, rien n'est implémenté.**

Le kernel représente déjà des types infinis en fini : `1..` (tous les entiers à
partir de 1), `~5`, `'a'..'z' * 2..` (un langage régulier de chaînes), `{...C:}`
(toute suite de bindings que C admet). Un type récursif est un type infini de
plus : `Array{T}` est l'ensemble de toutes les suites finies de `T`, ce qu'on
écrirait `{0..*T:}` — sa première production est `{}`, sa seconde `{1..*T:}`.

Ce document fait la liste des cas, et pour chacun : sa représentation finie, et
ce que le kernel sait en décider.

## 1. La représentation : un système d'équations

Un scope récursif se lit comme une **équation** dont il est l'inconnue. Une
variable, c'est un scope écrit et les types de ses arguments :
`Array{u8}` est la variable `X`, et

```text
X = {} | {u8: ...X}
```

Toutes les récursions d'un programme forment un système fini d'équations :
c'est la représentation finie. Dans le kernel, c'est un graphe de formes avec des
cycles — une forme (`Record`) dont un champ, ou une suite, a pour ensemble la
variable elle-même.

Pour nouer le cycle, il faut reconnaître la variable : `Array{T}` écrit dans la
production d'`Array`, avec `T` le même, **est** `X`. Deux carves de la même cible
avec des arguments de même type (formes normales, `kernel-algebre.md` §2–3) sont
le même scope. Sans ça, chaque occurrence crée une variable nouvelle et le système
est infini : c'est la boucle d'aujourd'hui.

## 2. Les cas

| | exemple | équation | type | régulier |
|---|---|---|---|---|
| A | liste, récursion en queue | `X = {} \| {T: ...X}` | `{0..*T:}` | oui |
| B | liste, récursion en tête | `X = {} \| {...X  T:}` | `{0..*T:}` | oui |
| C | liste non vide | `X = {T:} \| {T: ...X}` | `{1..*T:}` | oui |
| D | arbre, récursion par un champ | `X = {} \| {X:l  T:v  X:r}` | arbre régulier | oui |
| E | mutuelle | `X = {} \| {A: ...Y}`, `Y = {B: ...X}` | `{0..*(A: B:)}` | oui |
| F | au milieu d'une suite | `X = {} \| {A: ...X  B:}` | `AⁿBⁿ` | **non** |
| G | polymorphe | `X{T} = {} \| {T: ...X{{T:}}}` | une variable par niveau | **non fini** |
| H | sans cas de base | `X = {T: ...X}` | vide : aucune valeur finie | — |
| I | non gardée | `X = {...X} \| {}` | rien n'est consommé | — |

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

**F — pas régulier.** La variable apparaît au milieu d'une suite. `AⁿBⁿ` n'est pas
un langage régulier : c'est une grammaire algébrique. Le système d'équations le
représente quand même en fini, et l'appartenance d'une valeur se décide (§3).
L'inclusion de deux tels types est indécidable en général. XDuce interdit ces
définitions pour cette raison.

**G — pas fini.** L'argument change à chaque niveau (`T`, puis `{T:}`, puis
`{{T:}:}`…). Chaque niveau est une variable nouvelle : le système n'est pas
fini.

**H — vide.** Aucune valeur finie : le plus petit point fixe est vide. Colorer
par `X` n'admet rien, et le défaut n'existe pas.

**I — non gardée.** `{...X}` ne consomme aucun binding avant de revenir à `X` :
l'équation `X = X | {}` ne dit rien de plus que `X = {}`. Il faut décider si
c'est une erreur.

## 3. Ce qu'on décide

- **Appartenance d'une valeur** (`a` est-il un `Array{u8}` ?) : la valeur est
  finie, on déplie le système sur elle. Inductif : une appartenance qui dépend
  d'elle-même n'est pas établie (`record_member`, `k.matching`, déjà là).
  Décidable dans **tous** les cas, F compris.
- **Inclusion et vide** (`Array{u8}` ⊆ `Array{u16}` ?) : coinductif, on suppose
  l'inclusion en cours vraie. Exact pour A–E (langages réguliers d'arbres).
  Pour F, `Unproven` quand on ne sait pas, jamais une acceptation.
- **Le défaut** : une valeur, donc finie. C'est le premier défaut du système qui
  est **productif** (qui atteint une valeur finie, l'algorithme classique des
  symboles productifs d'une grammaire). La première production d'`Array` est `{}`
  : le défaut est `{}`. Si la première production revient à `X` sans cas de base
  (`tc_infinite_default`), le défaut est infini : erreur.

## 4. Les fonctions récursives

Une fonction récursive structurelle suit la récursion de sa donnée : `map`
appelle `map` sur la queue `r` de son argument. Si l'argument est `Array{T}`,
de type `{0..*T:}`, la queue a le **même** type `{0..*T:}`. L'appel récursif a
donc la même variable que l'appel en cours (§1) : le type du résultat est une
inconnue `Y` du système, `Y = {} | {E: ...Y}`, soit `{0..*E:}`. Pas de
déroulement : une équation de plus.

Une fonction sur des nombres (`f{n -> n - 1}`) n'a pas de structure : le type de
l'argument change à chaque niveau (`n`, `n - 1`, …), comme dans G. Il faut un
élargissement de l'argument (un intervalle qui grandit jusqu'à se stabiliser,
Cousot & Cousot 1977), ou dérouler quand les valeurs sont connues et qu'on sait
que ça termine.

## 5. À réfléchir

1. **F** — refuser la définition (comme XDuce), ou l'accepter avec une inclusion
   `Unproven` quand elle n'est pas décidable ?
2. **G** — refuser, ou borner ?
3. **I** — une récursion non gardée est-elle une erreur ?
4. **Les nombres** (§4) — élargir, ou dérouler sous quelle condition ?
