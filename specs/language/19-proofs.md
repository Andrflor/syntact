# Proofs

There is no proof operator, because there is no proof system: **the type system
is the prover**. A proof obligation is a coloring — `:` demands that a value's
set be contained in the color's set, the compiler must establish it, and a
failure is a compile error. Since any value is a type, `true` is a color like
any other:

```syntact
true:check -> 2 = 2     // proven: the comparison folds to true
true:oops -> 2 = 3      // Constraint_Mismatch: false does not satisfy true
```

Inline, the same obligation is a colored production:

```syntact
-> true:(2 = 2)
```

`??` provides the quantified values: a symbolic unknown ranges over its whole
set, so a property colored `true` over a `??` asks "does this hold for EVERY
value of that shape?" — the same question, asked of a wider set.

```syntact
decodeEncodeSymmetry -> {
  string:m -> ??
  true:holds -> decode{value -> encode{value -> m}!}! = m
}
```

Or as a law inside a scope:

```syntact
Serializer -> {
  S <- {}
  R <- {}

  encode -> {
    S:value
    -> R:
  }

  decode -> {
    R:value
    -> S:
  }

  roundTrip <- {
    S:value -> ??
    -> true:(decode{value -> encode{value -> value}!}! = value)
  }
}
```

The point is not to attach a separate proof assistant to the language: a proof
is the ordinary constraint contract, and the prover's strength is the reducer's
strength. Today it decides everything the set envelopes decide (concrete values,
decided ranges); symbolic quantification over `??` deepens as the reducer does —
carefully, because proofs can make compile time explode.

---

---

[← Files, folders, imports, metaprogramming](18-modules.md) · [Index](README.md) · [Why this should be fast →](20-performance.md)
