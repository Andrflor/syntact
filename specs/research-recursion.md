# Recherche — types récursifs et récursion en forme close dans Syntact

> Dossier pour des agents de recherche. Il donne le contexte du langage, ce qu'on
> cherche, et les références déjà identifiées. Chercher **tout ce qui peut servir**
> à implémenter ce qui suit dans un compilateur, en priorité : algorithmes
> concrets, implémentations existantes, limites prouvées.

## 1. Le contexte : Syntact en dix lignes

Syntact est un langage où **tout est un scope** : une suite ordonnée de bindings
(`x -> 5`, `u8:x`, `-> production`, `...expansion`). Un scope sert à la fois de
valeur, de type, de fonction et de module. Quatre propriétés rendent le
compilateur difficile :

1. **Les types sont des ensembles de valeurs.** `u8` est `0..255`, `5` est le
   singleton `{5}`, `??::u8` est une valeur inconnue dans `0..255`. Pour du code pur
   à entrées connues, le type **est** la valeur : `square{n -> 5}!` a le type `25`.
   Le typechecker est donc un **évaluateur partiel**.
2. **Tout est structurel**, rien n'est nominal : un type est sa structure, pas un
   nom. La récursion ne peut pas se « nouer » par un nom comme en Haskell.
3. **Rien n'est annoté** : le type d'une fonction se déduit de son corps.
4. **Les types doivent être parfaits** : jamais d'acceptation sans preuve
   (sémantique ensembliste, sous-typage = inclusion d'ensembles, comme CDuce).

Le kernel de types (Odin) représente déjà en fini des types infinis : intervalles
d'entiers (`1..`), complémentaires, langages réguliers de chaînes (dérivées de
Brzozowski), formes de scopes combinées en BDD paresseux (à la Frisch / Elixir),
polynômes sur des inconnues. Specs internes : `specs/kernel-subset.md`,
`specs/kernel-algebre.md`, `specs/kernel-recursion.md`.

Effets : algébriques (`>-` émet, `-<` installe un handler), résolus à la
compilation par le contexte de l'appel. Un appel impur a un type ≠ sa valeur.

## 2. Le problème : les scopes récursifs

```syntact
Array -> {
  T -> {}
  -> {}                      // cas de base
  -> {T: ...Array{T}:}       // une tête T, puis la suite d'un Array
}
```

La **self-référence** (`Array{T}` dans `Array`) est traitée comme une **inconnue
de type `X`** (différente d'une inconnue de valeur). Les productions typées avec
`X` donnent une **équation** ; sa solution est le type en représentation finie :

```text
X = {} | {T: ...X}     →  (lemme d'Arden)  →   X = {0..*T:}
```

Loi décidée : la **première production est le cas de base** ; elle n'est pas
récursive et finit. Le défaut d'un scope (sa première production) est la solution
de l'équation de la première production seule ; une solution infinie
(`{∞*T:}`) ou indéterminée rend la définition illégale.

## 3. Les cas, et la forme de type qu'il faut pour chacun

| cas | équation | type visé | forme de type nécessaire |
|---|---|---|---|
| A | `X = {} \| {T: ...X}` | `{0..*T:}` | répétition comptée (Arden) |
| B | `X = {} \| {...X  T:}` | `{0..*T:}` | idem (Arden à gauche) |
| C | `X = {T:} \| {T: ...X}` | `{1..*T:}` | idem |
| D | `X = {} \| {X:l  T:v  X:r}` (arbre) | le type se nomme lui-même | type récursif / langage régulier d'arbres |
| E | `Even = {} \| {u8: ...Odd}`, `Odd = {string: ...Even}` | `{0..*(u8: string:)}` | système d'équations, répétition de groupe |
| F | `X = {} \| {A: ...X  B:}` | `{n*A: n*B:}`, `n ∈ 0..` | **compte partagé** (non régulier, algébrique) |
| G | `X(T) = {} \| {T: ...X({T:})}` (polymorphe) | k-ième élément de type `Fᵏ(T)` | **répétition indexée** (type imbriqué) |
| H, I | pas de cas de base / non gardée | — | illégal |

À décider pour chaque forme : **appartenance** d'une valeur finie (toujours
décidable), **inclusion** et **vide** (exactes pour A–E, à étudier pour F et G).

## 4. La récursion sur des nombres : vers des formes closes

```syntact
sum -> {
  u64:n -> ??
  -> n ? {0 -> 0, -> n + sum{n -> n - 1}!}
}
```

L'argument n'a pas de structure (`n`, `n - 1`, …) : une seule équation n'existe
qu'en élargissant l'argument, ce qui donne un type imprécis (`0..`). La piste :
**résoudre la récurrence** `sum(n) = n + sum(n - 1)`, `sum(0) = 0` en **forme close**
`sum(n) = n·(n+1)/2`. Conséquences visées :

- le type de `sum{n -> ??}!` devient `??·(??+1)/2`, une forme normale du kernel
  (polynômes sur des inconnues), exacte ;
- `sum{n -> 5}!` vaut `15` par substitution, **sans dérouler**, donc sans question
  de terminaison ;
- le code émis peut remplacer la récursion par le **calcul plat** de la forme close.

Points durs à creuser :

- **Quelles classes de récurrences** ont une forme close calculable (C-finies,
  polynomiales, exponentielles, à coefficients polynomiaux…) ; que faire hors de
  ces classes (sur-approximation sûre).
- **L'arithmétique à largeur fixe** : `u64` déborde. La forme close doit respecter
  la sémantique de débordement du langage (ou prouver qu'il n'y a pas
  débordement) : `n·(n+1)/2` en `u64` n'est pas `n·(n+1)/2` sur ℤ.
- **Les branches et le cas de base** : extraire la récurrence d'un pattern `?`.
- **La terminaison** : quand dérouler est légitime si aucune forme close n'existe.
- **Les récursions non linéaires** (diviser pour régner, Fibonacci, Ackermann).

## 5. Références identifiées

### Équations de langages et lemme d'Arden
- D. N. Arden, « Delayed-logic and finite-state machines », *Switching Circuit
  Theory and Logical Design* (AIEE), 1961, pp. 133–151 —
  [Wikipedia : Arden's rule](https://en.wikipedia.org/wiki/Arden%27s_rule).
- J. A. Brzozowski, « Derivatives of regular expressions », *JACM*, 1964
  (à vérifier ; déjà utilisé dans le kernel pour les chaînes).
- R. E. Tarjan, « A unified approach to path problems », *JACM* 28(3):577–593,
  1981 — expressions de chemins par élimination, base de l'analyse algébrique —
  [Princeton](https://collaborate.princeton.edu/en/publications/a-unified-approach-to-path-problems/).

### Types ensemblistes et types réguliers
- A. Frisch, G. Castagna, V. Benzaken, « Semantic subtyping: dealing
  set-theoretically with function, union, intersection, and negation types »,
  *JACM*, 2008 (version longue de LICS 2002) — base de CDuce —
  [PDF](https://www.irif.fr/~gc/papers/semantic_subtyping.pdf).
- G. Castagna, « Programming with union, intersection, and negation types », dans
  *The French School of Programming*, Springer, 2023 —
  [arXiv 2111.03354](https://arxiv.org/pdf/2111.03354).
- G. Castagna et al., « Polymorphic Functions with Set-Theoretic Types »
  (types récursifs et polymorphes) — [HAL](https://hal.archives-ouvertes.fr/hal-00907166).
- H. Hosoya, J. Vouillon, B. C. Pierce, « Regular expression types for XML »,
  *TOPLAS* 27(1):46–90, 2005 — XDuce, `*` et `+` dans les types, sous-typage =
  inclusion — [Penn](https://repository.upenn.edu/cis_papers/82).
- H. Hosoya, B. C. Pierce, « Regular expression pattern matching for XML », *JFP*,
  2003 — [PDF](https://www.cambridge.org/core/services/aop-cambridge-core/content/view/C845B41E6B150FBD7731EE396FBCB911/S0956796802004410a.pdf/regular-expression-pattern-matching-for-xml.pdf).

### Automates d'arbres (cas D)
- H. Comon, M. Dauchet, R. Gilleron, F. Jacquemard, D. Lugiez, C. Löding,
  S. Tison, M. Tommasi, *Tree Automata Techniques and Applications* (TATA), 2008 —
  [PDF](https://www.csd.uoc.gr/~hy561/Data/Other/tata.pdf).

### Récursion polymorphe (cas G)
- R. Bird, L. Meertens, « Nested Datatypes », *MPC 1998*, LNCS 1422, pp. 52–67 —
  [PDF](https://www.kestrel.edu/people/meertens/pub/nest5.pdf).
- A. Mycroft, « Polymorphic type schemes and recursive definitions », 1984
  (à vérifier).

### Récurrences en forme close (section 4)
- Z. Kincaid, J. Breck, J. Cyphert, T. Reps, « Closed Forms for Numerical Loops »,
  *POPL 2019*, PACMPL 3, art. 55 —
  [PDF](https://www.cs.princeton.edu/~zkincaid/pub/popl19a.pdf).
- Z. Kincaid, J. Breck, A. Forouhi Boroujeni, T. Reps, « Compositional recurrence
  analysis revisited », *PLDI 2017* —
  [slides](https://www.cs.princeton.edu/~zkincaid/_static/pub/pldi17-slides.pdf).
- ICRA (version interprocédurale, récursions linéaires et non linéaires) — thèse
  de Wisconsin — [minds.wisconsin.edu](https://minds.wisconsin.edu/handle/1793/80426).
- Z. Kincaid, T. Reps, J. Cyphert, « Algebraic Program Analysis », *CAV 2021*
  (tutoriel), LNCS 12759, pp. 46–83 —
  [page](https://www.cs.princeton.edu/~zkincaid/apa.html).
- J. Esparza, S. Kiefer, M. Luttenberger, « Newtonian Program Analysis », *JACM*
  57(6), 2010 — résoudre des systèmes d'équations récursifs sur des semi-anneaux —
  [PDF](https://archive.model.in.tum.de/um/bibdb/esparza/JACM-EKL.pdf).
- E. Albert, P. Arenas, S. Genaim, G. Puebla, « Automatic Inference of Upper
  Bounds for Recurrence Relations in Cost Analysis », *SAS 2008*, et « Closed-Form
  Upper Bounds in Static Cost Analysis », *J. Automated Reasoning*, 2010 — COSTA /
  PUBS — [COSTA](https://costa.fdi.ucm.es/costa/about.php).
- O. Bachmann, P. Wang, E. Zima, « Chains of recurrences — a method to expedite
  the evaluation of closed-form functions » — utilisé par LLVM ScalarEvolution, qui
  remplace déjà des boucles simples par leur forme close —
  [ScalarEvolution.cpp](https://llvm.googlesource.com/llvm/+/refs/heads/release_20/lib/Analysis/ScalarEvolution.cpp).

### Terminaison
- C. S. Lee, N. D. Jones, A. M. Ben-Amram, « The size-change principle for program
  termination », *POPL 2001* —
  [PDF](https://khoury.northeastern.edu/~pete/courses/Formal-methods/2008-Fall/readings/lee01sizechange.pdf).
- P. Cousot, R. Cousot, « Abstract interpretation », *POPL 1977* — élargissement
  (widening), à vérifier.

## 6. Questions pour la recherche

1. Une **algèbre de types de séquences** avec répétition comptée, sur des suites
   d'éléments typés (pas des caractères) : qui l'a faite, comment décider
   l'inclusion, quelle complexité (XDuce, CDuce, Elixir, autres) ?
2. **Cas F** (compte partagé `{n*A: n*B:}`) : représentations finies de langages
   algébriques dans un système de types ; contraintes de Parikh / Presburger ;
   ce qui reste décidable.
3. **Cas G** (répétition indexée) : représentation et décision de l'inclusion
   pour les types imbriqués / la récursion polymorphe.
4. **Formes closes** : algorithmes et bibliothèques (Kincaid, COSTA, LLVM SCEV,
   solveurs de récurrences des systèmes de calcul formel) ; classes couvertes ;
   arithmétique à largeur fixe et débordement.
5. **Remplacer une récursion par sa forme close dans le code émis** : qui le fait,
   avec quelles garanties de sémantique (débordement, effets, terminaison) ?
6. **Fonctions récursives structurelles** (`map` sur `{0..*T:}`) : inférer le type
   du résultat par une équation sur les types (`Y = {} | {E: ...Y}`).
