# Recursion

A scope names itself only in its productions. Its type is then an equation that
mentions it. The first production is the base case, and it is not recursive: a base
case that places its scope again is an infinite recursion.

```syntact
Nat -> {
  -> {...Nat:}       // refused: the base case places its scope again
  -> {}
}
```

The equation is never unfolded. Asked again from its own production, the scope stays
a carve and a collapse applied to types. It is solved, or it stays.

## Closed forms

When the name is called on an integer, `f{n -> m}! = m ? {b -> c  -> g(m) + f{n -> m - 1}!}`
gives `f{n -> m}! = c + g(b + 1) + … + g(m)`, a polynomial in `m` when `g` is one:

```syntact
sum -> {
  u8:n -> ??
  -> n ? {0 -> 0  -> n + sum{n -> n - 1}!}
}
total -> sum!            // (?0 + ?0 * ?0) / 2
five -> sum{n -> 5}!     // 15
```

A carve of a solved equation puts its arguments in the solution. An equation without
a closed form stays as it is written:

```syntact
fact -> {
  u8:n -> ??
  -> n ? {0 -> 1  -> n * fact{n -> n - 1}!}
}
f5 -> fact{n -> 5}!      // fact{n -> 5}!
```

## Recursive shapes

### Arden

When the name is at the edge of the sequence, Arden solves the equation, as for
strings (`X = A + X | B` gives `X = A * 0.. + B` when `""` is not in `A`):

```text
Array -> {T -> {}  -> {}  -> {T: ...Array{T}:}}
X = {} | {T: ...X}      ⟹    X = the run of zero or more T:
```

The pieces of the run need not have one length: a run is in `A * n` when it is cut
into `n` pieces, each in `A`.

```syntact
Mixed -> {
  -> {}
  -> {u8: ...Mixed:}
  -> {i8: string: ...Mixed:}
}
Mixed:m -> {1 (-2) "x" 3}      // {1} + {-2 "x"} + {3}
```

### Guarded productions

When the name is not at the edge, a scope is asked of the productions when they are
guarded: in each production, a run that names the scope comes with a binding. Each
question is then on a run strictly shorter than the one asked, and the equation is not
unfolded. Otherwise the equation stays.

```syntact
Mirror -> {
  T -> {}
  -> {}
  -> {T: ...Mirror{T}: T:}
}
Mirror{u8}:e -> {1 2 3 4}      // proven
Mirror{u8}:o -> {1 2 3}        // refused: the equation gives even lengths

Tree -> {
  -> {}
  -> {u8: ...Tree: ...Tree:}
}
Tree:t -> {1}                  // a node, and two empty trees
```

### The name in a carve

In a carve, the name written in a production is still the scope it names. To carry an
argument through the recursion, write it: `...Array{T}:`, not `...Array:`.

```syntact
L -> {
  T -> {}
  -> {}
  -> {T: ...L:}
}
L{u8}:bad -> {10 10}       // refused: the tail is an L of {}
```

---

[← Patterns](07-patterns.md) · [Index](README.md) · [Holes and genericity →](09-holes.md)
