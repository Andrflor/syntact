# Unknowns and the check

## Unknowns

`??` is a value not known yet. `??::L` reads it in the layout `L`: one value of `L`.
Each `??` written is a distinct unknown, `?0`, `?1`…; the same one comes back through
a name, so a type is an equation over its unknowns, and it keeps what they share:

```syntact
a -> ??::u8
c -> a + 3          // ?0 + 3
d -> a - a          // 0: one unknown, not two values of u8
u8:n -> ??          // ?1: ?? takes the layout of its color
```

An unknown is an input: the type of a program is what is left to compute once the
inputs are known (chapter 15).

## The check

```text
C:x -> V     ⟺     V in C = true
```

Every binding with a color asks it. With unknowns, `V in C` is an equation in them,
each `?ₖ::L` ranging over `L`. The check simplifies it by the laws; it solves
nothing. Its result is a verdict:

- **proven** — the equation simplifies to `true`;
- **refuted** — it simplifies to `false` for values of the unknowns: a witness;
- **unproven** — it stays an equation, and the binding is refused.

```syntact
u8:x -> a + 1                     // refuted: false when ?0 is 255
u8:y -> a ? {<255 -> a + 1  -> 0} // proven
```

### How it decides

The layout of a term is the term with each unknown replaced by its layout; operators
distribute over `|`. `?0::u8 + 1` has the layout `1..256`.

```text
x in C = true      when the layout of x is in C:     L & ~C = none
x in C = false     when it is disjoint from C:       L & C = none
?ₖ::p  = p         p one primitive
```

What stays is split on an atom `u in S` (Boole), and each side reduces:

```text
eq = (u in S) ? {true -> eq  -> eq}
```

A branch narrows its target: where it is reached by `u in S`, the unknown `?ₖ::L` is
`?ₖ::(L & S)` in its product. In `y` above, `a` is `?0::(0..254)` in the first branch,
so `a + 1` is in `1..255`.

### What is checked, and where

- every binding of a scope that has a color;
- a definition along its base case, its first production; the other productions when
  they are asked;
- a carve where it is written, in what it changed (chapter 04);
- inside a branch, for the values that reach it (chapter 07).

An operator is legal only when its operands are proven to be in its family: that is
the same check (chapter 02).

## Proofs

There is no proof language: a color is a claim, and the check proves it. Since a
value is a type, `true` is a color like any other:

```syntact
true:check -> 2 = 2          // proven
true:oops -> 2 = 3           // refused: false is not in true
true:same -> a - a = 0       // proven, for every value of a
u16:p -> a * a               // proven: every square of a u8 fits in u16
```

A file that is accepted has all its claims proven, for every value of its unknowns.

---

[← Shapes](05-shapes.md) · [Index](README.md) · [Patterns →](07-patterns.md)
