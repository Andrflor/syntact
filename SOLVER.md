# The solver of the kernel (design, for review)

The kernel is a solver over the algebra of types, built as an SMT solver is: theories,
each exact on its own signature, composed. It recognizes no shape. A term is reduced
by the theories; a recursion is a definition the theories solve; `V in C` is a query.

## 1. Terms

The terms are the grammar of `kernel/type.odin`, hash-consed (`intern.odin`): a term
built twice is one node, so the terms of a program are a graph of shared nodes (the
e-graph). Equal terms are one node; an equality a theory finds merges two nodes, and
every term over them sees it (congruence).

## 2. Theories

Each theory has a signature, a normal form, and a decision procedure for the atoms
of its signature: true, false, or, with unknowns, the exact set of values where it
holds. None works on bounds of its terms.

| Theory | Signature | Normal form, decision |
|---|---|---|
| Sets (§2, §4.1) | `\|` `&` `~` `in` over constant sets | cells; inclusion and disjointness decided on cells |
| Integers (§4.5) | `+ - * / % ** << >> [&] [\|] ^`, comparisons | polynomials over atoms; `/ %` by Euclid; an atom `a·u + b in S` decided on S exactly (the preimage of a set is a set) |
| Reals (§4.5, §4.10) | `+ - * /`, rounding to a format | the field of rationals; a format is a set of reals |
| Runs (§5.3) | `{...x ...y}`, `\|x\|`, `x.#k`, `x from k`, `x{#k -> v}` | the free monoid; `\|·\|` a morphism into the integers |
| Scopes (§5) | fields, carves, productions, shapes | records with functional update; shapes are constructors: distinct shapes are disjoint |
| Patterns (§6) | `t ? {c -> p …}` | case analysis: each branch under its condition; an operation on a pattern is the pattern of the operation |

## 3. Composition

A term that mixes theories is split: each foreign subterm is named by a fresh
unknown, and its defining equation is kept (`ℓ = |x|`, `ℓ` an integer, `x` a run).
The theories exchange the equalities and memberships they derive over the shared
unknowns until none derives more (Nelson–Oppen). A fact found by one theory is used
by every other: there is no glue written for a pair of them.

## 4. Recursion

A scope that names itself is a recursive definition `f(x) = body(f, x)`, a term
whose calls of `f` are themselves terms. Solving it is reducing the definition by the
theories:

- The calls of `f` in the body are named; the body is then a term of the theories over
  them. Where it is affine in those names in a theory — integers, runs (concatenation),
  sets (union) — the steps are maps of that theory, they compose by its own operation,
  and the solution is the composition of the steps along the orbit of the argument:
  the fold ⟳ (§5.6), whose closed forms the theory gives (a polynomial sum, a power,
  a C-finite sequence, a concatenation, Arden for sets of runs).
- Two calls equal in the theories are one name (`c(l) + c(r)` with `c(l) = c(r)` is
  `2·c`): the theories decide equality, not a rule written for it.
- A definition the theories do not reduce stays a function symbol with its definition
  as an axiom: a call computed at run time (a loop when its calls are in tail position).

## 5. Proof

`C:x -> V` is the query: is `V ∉ C` satisfiable? The theories answer:

- unsatisfiable: `V in C` is proven;
- a model: refuted, with the values of the unknowns that make it false;
- otherwise: not proven.

A recursive call that stays is proven by induction: the property holds of the bases,
and of the body assuming it of the calls (the hypothesis). When the definition is
solved, its solution is a term of the theories and the query is about that term.
When it stays, its type is the least set the definition maps into itself, found by
the same theories.

## 6. What goes

Everything that recognizes shapes or works on bounds: `iteration` and its catalogue,
the cascade of cases of `in_law`, the images by intervals (`int_hull`, `hull_times`,
`sum_image`, `least_image`, `term_bound`, `outer_set`), the fallbacks that read a call
at its values, and the passages of specs/types.md that state cases or bounds.
