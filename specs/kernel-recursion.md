# Conception — les types récursifs dans le kernel

> **État : proposition, rien n'est implémenté.** À valider avant tout code. Les
> points marqués **À trancher** sont des choix de langage, pas d'implémentation.

## 0. Le problème

Le kernel calcule des **types**. Un type est l'ensemble des valeurs possibles ; il
ne se confond avec la valeur que si le code est pur et ses entrées connues
(`square{n -> 5}!` a le type `25`). Une valeur n'existe qu'au runtime.

Deux sortes de scopes ont un type qui se définit par lui-même :

```syntact
Array -> {                       // une grammaire : Array{T} contient Array{T}
  T -> {}
  -> {}
  -> {T: ...Array{T}:}
}

f -> {                           // une fonction : le type de f{n -> ??}! dépend
  u64:n                          // de celui de f{n -> n - 1}!
  -> n ? { 1 -> 2, -> f{n -> n - 1}! }
}
```

Aujourd'hui le kernel n'a aucune représentation pour un type qui se contient :

- `Array{u8}:a` boucle jusqu'au débordement de pile. `type_carve` copie `Array`,
  type la copie ; sa production contient `...Array{T}:`, qui recarve `Array` avec
  **le même argument** `T = u8`, donc une nouvelle copie, et ainsi de suite
  (`carve.odin:31` → `expand.odin:69` → `type_of.odin:127` → `carve.odin:25`).
- `f` est refusée à sa définition (`type_ref` trouve le type de `f` en cours :
  « la récursion »). Appelée avec `??`, elle boucle : chaque niveau crée une copie
  et une inconnue nouvelles (`??1 - 1`, `??1 - 2`, …), rien ne se répète.

La première sorte est un **type régulier** : un graphe fini avec des cycles. La
seconde est une **équation sur des types**, dont on cherche le plus petit point
fixe.

## 1. Ce que la théorie a déjà

- **Types récursifs ensemblistes** : CDuce (Frisch, Castagna, Benzaken, *Semantic
  subtyping*, JACM 2008 ; Frisch, thèse, ch. 7 et 9). Un type récursif est un
  arbre régulier, représenté par un graphe fini. L'appartenance d'une valeur est
  **inductive** (les valeurs sont finies : plus petit point fixe) ; l'inclusion de
  deux types est **coinductive** (on suppose l'inclusion en cours et on vérifie le
  reste : plus grand point fixe). C'est déjà le point 5 de `kernel-subset.md` §7.
- **Point fixe de fonctions sur des treillis** : Kleene ; l'interprétation
  abstraite (Cousot & Cousot, POPL 1977) pour les domaines infinis — un
  *élargissement* (widening) garantit que l'itération s'arrête.

Le kernel a déjà la moitié inductive : `record_member` (`bdd.odin`) retient les
appartenances en cours dans `k.matching`, et une appartenance qui dépend
d'elle-même n'est pas établie. Il manque de quoi **construire** le graphe.

## 2. L'identité d'un carve

Un carve est déterminé par sa cible et par les types de ses arguments. Deux carves
de la même cible avec des arguments de même type désignent **le même scope**.

```text
carve(S, args) = carve(S, args')   si   S est le même scope et type(args) = type(args')
```

`type_carve` garde, pour chaque carve en cours ou fini, la clé
`(source, types des arguments)` → la copie dérivée. Un carve dont la clé est déjà
là rend cette copie au lieu d'en faire une autre.

- Pour `Array{u8}` : la copie `A` est enregistrée **avant** d'être typée. Sa
  production recarve `Array` avec `T = u8`, la même clé, et reçoit `A` elle-même.
  L'expansion `...Array{T}:` de `A` a pour type `A` : le graphe a un cycle, et il
  est fini.
- L'égalité des types d'arguments est celle des formes normales du kernel
  (`kernel-algebre.md` §2 et §3 : une forme normale unique par algèbre). Un scope
  argument se compare par identité, ce qui suffit puisque les carves égaux sont
  désormais le même scope.

Il faut aussi qu'un scope puisse se nommer pendant qu'il se type. Un scope est son
propre type (`type_of(scope) = scope`) : une référence à `f` depuis l'intérieur de
`f` désigne ce scope, même si ses bindings ne sont pas encore tous typés.
Aujourd'hui `type_ref` refuse (« la récursion ») parce que le binding `f` n'a pas
encore de `value_type` ; il doit rendre le scope écrit, qui existe déjà.

Ce n'est pas un cache ajouté à côté : c'est la loi « deux scopes de même cible et
de mêmes arguments sont le même scope », et le graphe en découle.

**À trancher (Q1)** — un carve est-il bien déterminé par sa cible et les types de
ses arguments ? C'est la lecture structurelle du langage ; elle exclut qu'un
carve ait une identité propre (deux `Point{x -> 1}` écrits à deux endroits sont le
même scope).

## 3. Un graphe avec des cycles, partout où on parcourt un type

Tout ce qui parcourt un type récursivement doit s'arrêter sur un cycle. Chaque
parcours a sa loi, il n'y a pas de garde générique :

| parcours | où | sur un cycle |
|---|---|---|
| lire comme couleur | `color_set` | §4 : un atome qui renvoie au scope en cours |
| appartenance d'une valeur | `record_member` | inductif, déjà là : pas établie |
| inclusion, vide | `bdd_is_empty`, `subset` | coinductif : supposée en cours |
| défaut | `default_of` | §5 : un défaut infini est une erreur |
| imprimer | `print.odin` | le carve tel qu'écrit, `Array{u8}`, au lieu de le déplier |
| `is_closed_type`, `fixed_length`, `places` | `bdd.odin`, `type_of.odin`, `expand.odin` | marqué visité : un cycle n'ajoute rien |
| marquer ce qui change | `mark_changes` | déjà par portée lexicale : ne traverse pas les copies |

## 4. Lire un scope récursif comme couleur

`color_set` lit un scope une fois et le garde dans `k.shapes`. Pour un scope
récursif, le résultat dépend de lui-même : `Array{u8}` admet `{}` ou
`{u8: ...X}` où `X` est `Array{u8}`.

On enregistre dans `k.shapes`, **avant** de lire le scope, un ensemble qui le
désigne par référence : un atome du BDD dont la forme est « ce que ce scope
admet », déplié seulement quand on décide. Un champ `...Array{T}:` reçoit cet
atome ; le cycle passe par lui. C'est le BDD paresseux de `kernel-subset.md` §3,
avec des atomes qui peuvent renvoyer à un scope en cours.

- **Appartenance** (une valeur est-elle admise) : inductive, par `k.matching`,
  comme aujourd'hui. `{1 2 3}` est dans `Array{u8}` en trois dépliages.
- **Inclusion et vide** (`Array{u8}` ⊆ `Array{u16}` ?) : coinductive. On suppose
  l'inclusion en cours vraie et on vérifie le reste (l'algorithme de CDuce).

## 5. Le défaut d'un scope récursif

Le défaut est une **valeur**, donc finie. `Array` a pour défaut sa première
production `{}`. Si la première production se déplie sans fin
(`-> {T: ...Array{T}:}` en premier), le défaut est infini : c'est une erreur, au
binding qui le demande. C'est ce qu'attend `tc_infinite_default`.

`default_of` retient les défauts en cours ; un défaut qui se redemande lui-même est
infini.

## 6. Les fonctions récursives : un point fixe sur les types

Pour `f{n -> ??}!`, les arguments changent à chaque niveau (`??1 - 1`, `??1 - 2`,
…) : l'identité du §2 ne les rejoint jamais. Il faut résoudre l'équation.

Quand le typage d'une production redemande **la même production** pendant qu'il
est en cours (même source, §2), on ne la déplie pas. On cherche son type comme un
point fixe :

1. L'argument est **élargi** à ce qu'il peut valoir sur tous les niveaux : pour
   `f`, `n` passe de `??1` à une inconnue sur l'union de ses valeurs, au pire sa
   couleur (`u64`). L'élargissement garantit que l'itération s'arrête.
2. On type la production avec l'appel récursif valant `X`, en partant de `X = ∅`,
   et on recommence avec le résultat jusqu'à ce qu'il ne change plus.
   Pour `f` : `X₁ = {2} ∪ ∅ = {2}`, `X₂ = {2} ∪ {2} = {2}` : stable. Le type de
   `f{n -> ??}!` est `2`.
3. Les vérifications se font sur ce point fixe. Ici, la branche par défaut reçoit
   `n = 0`, et `n - 1` sort de `u64` : l'erreur est réelle, et elle est trouvée.

À sa **définition**, `f` se type avec ses valeurs (loi « value, not color ») :
`u64:n` vaut 0, la branche par défaut se déclenche, et `f{n -> 0 - 1}` est refusé
au carve. Pour vérifier `f` sur toute sa couleur, on écrit `u64:n -> ??`. C'est ce
qu'attend `tc_pat_refine_no_exclusion_bad`.

Avec des arguments **connus**, chaque niveau est un carve différent mais connu :
`f{n -> 5}!` peut se dérouler jusqu'à `2`. Dérouler n'est légitime que si l'on
**sait** que ça termine (pas d'effet, pas de frontière, une terminaison prouvée).

**À trancher (Q2)** — la terminaison. Quand le kernel peut-il dérouler un appel
récursif à arguments connus au lieu de prendre le point fixe ? Des règles
possibles : une mesure qui décroît dans un ensemble bien fondé ; une borne sur le
nombre de dépliages (le mode prod de tes trois modes) ; ou jamais en mode
typecheck, où le point fixe suffit à prouver les types.

**À trancher (Q3)** — l'élargissement. Quand l'argument ne se stabilise pas,
on le remplace par sa couleur (le plus simple, sûr), ou par l'enveloppe des valeurs
vues (plus précis) ?

## 7. Ce qui ne change pas

- Une production a toujours un type, calculé à sa définition : c'est son check.
  Les erreurs de `-> "a" + 1` sont signalées où elles sont écrites.
- Les effets donneront un contexte au typage d'un appel (les handlers en place) ;
  la clé du §2 et le point fixe du §6 le contiendront. Pas avant l'étape des
  effets.

## 8. Ordre de travail, chaque étape testée sur le corpus

1. **L'identité des carves** (§2) et les parcours sur cycles (§3), y compris
   l'impression. Le corpus ne doit plus crasher.
2. **La couleur récursive** (§4) : les tests `tc_grammar_*`, `tc_pat_grammar_exh_*`,
   `tc_carve_sibling_override_subst*`.
3. **Le défaut infini** (§5) : `tc_infinite_default*`.
4. **Le point fixe des fonctions** (§6), une fois Q2 et Q3 tranchées : `recurse.syn`,
   `tc_map_*`.
