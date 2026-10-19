# Le kernel : un seul système d'équations

> **État : proposition validée dans son principe, rien n'est implémenté.** Elle
> unifie ce que le kernel fait aujourd'hui avec deux mécanismes séparés, les
> inconnues `??` et les self-références (`specs/kernel-recursion.md`).

## 1. Tout binding est une équation

Un scope est un système d'équations, une par binding. Un binding en porte deux :

- l'équation de sa **couleur** (`color_type`), s'il en a une ;
- l'équation de sa **valeur** (`value_type`).

Typer, c'est poser et résoudre ces équations. Typecheck un binding, c'est prouver
que l'équation de la couleur **contient** l'équation de la valeur. C'est la seule
question du kernel ; elle ne change pas, elle porte désormais sur des équations.

| binding | équation | état |
|---|---|---|
| `x -> 3` | `x = 3` | résolue : `3` |
| `n -> ??::u8` | `n = ??`, dans `0..255` | inconnue, de domaine `0..255` |
| `a -> n * 2 + n` | `a = 3·n` | résolue en fonction de `n` |
| `Array -> {… ...Array{T}: …}` | `X = {} \| {T: ...X}` | se mentionne : Arden donne `{0..*T:}` |
| `f{n -> n - 1}!` dans `f` | `Y(n - 1)`, l'équation de `f` appliquée | se mentionne : forme close, ou l'équation |

`x = 3` est une équation déjà résolue. Il n'y a pas de cas à part.

## 2. Une seule notion d'inconnue

Une inconnue est une équation pas encore résolue. Le kernel a aujourd'hui deux
mécanismes : les inconnues de `??` (`k.symbols`, des domaines) et la
self-référence (`Itself`, une forme à part). Ils deviennent un seul :

```odin
Symbol :: struct {
	equation: ^Expr,   // le côté droit : ??::u8, le scope d'Array, la production de f
	args:     []^Expr, // l'équation appliquée à ces arguments : Y(n - 1)
}
symbols: [dynamic]Symbol
```

- `??::u8` : un symbole dont l'équation est un domaine, déjà résolue.
- une self-référence : un symbole dont l'équation est le scope en cours de
  définition ; `Itself` disparaît.
- un appel récursif `f{n -> n - 1}!` : un symbole dont l'équation est celle de `f`,
  appliquée à `n - 1`.

## 3. Les expressions portent tous les symboles

Les polynômes, les termes et les ensembles qui dépendent d'inconnues (`Poly`,
`Term`, `Set_Form`) portent n'importe quel symbole. `n + Y(n - 1)` est un
polynôme en deux inconnues ; la substitution (`substitute`) et l'énumération sur
des domaines bornés s'appliquent à tous.

## 4. Une seule résolution

Résoudre une équation, c'est réécrire son côté droit sans l'inconnue, du plus
simple au plus riche :

1. déjà résolue : `3` ;
2. un domaine : `??::u8` ;
3. une suite récursive : Arden, `{0..*T:}` ;
4. une récurrence sur des nombres : une forme close, `n·(n+1)/2` ;
5. sinon on garde l'équation, et on typecheck directement dessus — sans jamais la
   déplier.

## 5. Ce que ça change

C'est ce que le kernel fait déjà, unifié : les mêmes polynômes, les mêmes
domaines, la même inclusion. L'unification est ce qui fait de Syntact le système
algébrique de son design : une seule algèbre d'équations, où une valeur, un type,
une inconnue et une récursion ne sont que des équations plus ou moins résolues.
