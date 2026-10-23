# Contexte de travail : refonte de la décision du kernel (2026-10-23)

> Note de reprise. Elle résume la session du 2026-10-23 pour reprendre le travail
> ailleurs. La spec qui en sort : [`kernel-decision.md`](kernel-decision.md).
> Avis du maintainer sur cette spec : « assez bof », elle est à retravailler et
> n'est pas validée.

## Où on en est

- Dernier commit de code : `c8a38c1 Kernel: Move color unknowns to value side`
  (2026-10-20). Les commits suivants touchent les commentaires et `AGENTS.md`.
- `odin test kernel` : 36/36 passent. Le test `test_typecheck_corpus` se contente
  de logger ses échecs. Sur les 609 cas : **580 passent, 3 échouent, 26 sont hors
  kernel**. Les trois échecs :
  - `tc_cast_target_unsized_float_fail` : trou connu, il attend l'algèbre f32/f64 ;
  - `tc_insoluble_nested_compose` : `Unproven` au lieu d'OK ;
  - `tc_insoluble_untyped` : `Unproven` au lieu de `Constraint_Mismatch`.
- `odin test test/typecheck` lance l'**ancien analyseur** (`compiler/`), pas le
  kernel. Ses 15 échecs ne comptent pas pour le kernel.
- `kernel/cmd` : `odin build kernel/cmd -out:k`, puis `./k fichier.syn`. Il affiche
  le scope, ses types et les erreurs.

## Lois posées par le maintainer

- **2026-10-21, la couleur contient la valeur.** Un type est une équation
  définitionnelle. La couleur se type exactement comme une valeur, sans règle
  propre aux couleurs. Le check vérifie que type(couleur) contient type(valeur).
  Le type de `n -> ??::u8` est `n`. Chaque `??` écrit est sa propre inconnue :
  `b:a -> b` passe, `b -> ??::u8 ; ??::u8:a -> b` échoue.
- **2026-10-23, l'union.** On prouve d'abord contre l'union entière. Si elle n'est
  pas décidable à la compilation, on découpe par morceaux, et par valeur : un
  morceau indécidable n'empêche pas un autre de prouver. Par exemple,
  `??::u8 ∈ <100 | >=100` tient alors qu'aucun morceau ne tient seul.
- **2026-10-23, `a & <100`** veut dire « `a` si `a < 100`, rien sinon ». Sans
  contexte, on ne sait pas trancher ; dans un contexte qui sait `a < 40`, `a = 4`,
  etc., ça doit typecheck.
- Toujours en vigueur :
  - pas d'implémentation partielle ni de garde pour faire taire un crash ;
  - on n'ajoute ni nœud ni table pour un état déjà représentable ;
  - une définition se vérifie sur sa valeur, et `??` est le seul « pour tout » ;
  - on ne déplie jamais la récursion.

## Le diagnostic (audit du 2026-10-23)

Le maintainer en est à environ **10 tentatives** de refonte du kernel en algèbre
équationnelle. Toutes ont abouti à des tables de cas par forme, pas à une algèbre.
D'où l'audit, qui trouve six causes structurelles :

1. **Six représentations** d'un ensemble : `Set`, `Poly`, `Term`, `Var`,
   `Set_Form`, `Cases`. S'y ajoutent les shapes du BDD, dont les champs sont
   forcément clos. Chaque paire de formes oubliée donne `Unsupported`.
2. **Aucune loi booléenne sur les ensembles symboliques.** `simplified`
   (`set_form.odin`) ne fait que retirer un opérande vide ou absorber un opérande
   inclus.
3. **Le check ne sait faire que des ET.** `conditions` (`check.odin`) abandonne
   toute union ou tout complément qui dépend d'une inconnue.
4. **La décision empile des heuristiques** : enveloppe, puis forme affine, puis
   extrêmes linéaires, puis contre-exemple aux coins (`outside_at_bounds`).
   Ce n'est pas une procédure de décision.
5. **Le contexte ne connaît qu'une variable seule et son domaine** (`Fact`). Il
   n'existe que pour un pattern sur une inconnue nue.
6. **`Undecided` signale aussi une règle manquante.** Et `admits` finit par
   `return .Refuted` sur les formes qu'il ne connaît pas.

## Les sondes

`a -> ??::u8`, sauf mention contraire. Attendu = ce que dit la loi.

| source | attendu | kernel |
|---|---|---|
| `(a \| a):b -> a` | OK | Unproven |
| `(~~a):b -> a` | OK | Unproven |
| `((a\|5) & (a\|6)):b -> a` | OK | Unproven |
| `(>a \| <=a):c -> b`, `b -> ??::u8` | OK | Unproven |
| `a -> ??::bool`, `(a \| ~a):b -> true` | OK | Unproven |
| `(a..b):c -> a`, `b -> ??::u8` | OK | Unproven |
| `(a \| 300):b -> a` | OK | Unproven |
| `(a \| 300):b -> 300` | OK | Unproven |
| `s -> ??::string`, `(s \| "x"):b -> s` | OK | Unproven |
| `a -> ??::(0..39)`, `(u8 & >200 \| (a & <100)):b -> a` | OK | Unproven |
| `(u8 & >200 \| (a & <100)):b -> a` | Mismatch (`a = 150`) | Unproven |
| `n -> ??::(0..10)`, `>0:b -> (n-5)*(n-5)` | Mismatch (`n = 5`) | Unproven |
| `n -> ??::(0..10)`, `>=0:b -> (n-5)*(n-5)` | OK | Unproven |
| `b -> a*a - a`, `(0..65000):c -> b` | OK (max 64770) | Unproven |
| `r -> (a+1) ? {<50 -> a, -> 0}`, `(..48):c -> r` | OK | **Mismatch (faux)** |
| `t -> a < 100`, `r -> t ? {true -> a, -> 0}`, `(..99):c -> r` | OK | **Mismatch (faux)** |
| `a ? {<40 -> {(a & <100):b -> a …}}` | OK | Unsupported |
| `a ? {=b -> 1, -> 2}`, `b -> ??::u8` | typé par morceaux | Unsupported |
| `-(a \| 3)` | typé | Unsupported |
| `Shape -> {(0..a):x -> 0}` | typé | Unsupported |

Ce qui marche : les ensembles fermés, les polynômes linéaires, les patterns sur une
inconnue nue, `/` et `%`, le carve de scopes, la récursion simple `f{n -> a}!`, et
`>a` contre `a + 1`.

## La spec proposée : `kernel-decision.md`

En une phrase : une seule sorte de terme ; chaque ensemble se traduit en une
formule d'appartenance ; une seule question, « la formule d'échec
`domaines et contexte et non (v ∈ C)` est-elle possible ? ». Le contexte est une
formule. La décision se fait en trois temps : les lois booléennes sur des atomes
canoniques, puis les atomes clos décidés d'abord, puis des cellules décidées par
théorie. `Unproven` est réservé à une liste fermée. Le juge est l'oracle
(`kernel/oracle_test.odin`) sur des domaines finis.

Questions ouvertes, au §12 de la spec :

1. Polynômes non linéaires sur des domaines bornés : bissection complète, mais au
   pire aussi coûteuse que l'énumération. Admis ?
2. Une opération entre deux ensembles qui dépendent tous deux d'inconnues, en
   couleur (`(a | 3) * (b | 4)`) : elle crée un « pour tout ». `Unproven` ?
3. `=X` avec `X` qui dépend d'inconnues : même question.

## Méthode convenue, pour ne pas refaire du slop

1. La spec d'abord, validée par le maintainer avant tout code.
2. Un juge qu'on ne contourne pas : générer des cas au hasard, et le verdict du
   kernel doit être celui de l'oracle. Sur des domaines finis, `Unproven` compte
   comme un échec.
3. Un noyau neuf construit à côté de l'actuel. On bascule quand le juge est vert
   et que le corpus fait au moins aussi bien.
4. Pas d'`Unsupported` dans l'algèbre : une forme non couverte veut dire que la
   spec est incomplète, on s'arrête et on la complète.

## Prochaine étape

Retravailler `kernel-decision.md` avec le maintainer (« assez bof »), trancher
les trois questions, puis seulement écrire le générateur, le juge et le noyau
neuf.

Documents liés :
- [`kernel-equations.md`](kernel-equations.md) : un type est une équation ;
- [`equational.md`](equational.md) : le design de la branche équationnelle ;
- [`kernel-recursion.md`](kernel-recursion.md) : les types récursifs ;
- [`kernel-algebre.md`](kernel-algebre.md) : les preuves de l'algèbre close ;
- [`constraints.md`](constraints.md) : les ensembles et la négation ;
- [`language/12-patterns.md`](language/12-patterns.md) : les patterns.
