# Pull bindings and genericity

`<-` declares a hole filled by the use site.

```syntact
identity -> {
  T <- none
  T:value -> none
  -> value
}

identity{value -> 5}!
identity{value -> "hello"}!
```

`T` is a hole. `value` is an ordinary field whose color mentions `T`. Carving with `value -> 5` pushes into `value`, and because the color of `value` mentions `T`, the carve infers `T` from the shape of what filled it. The use site never has to mention `T` — it is recovered from the carving.

A hole is inferred only through the colors that mention it. Every field that mentions the same hole must agree on it:

```syntact
data -> { u8:x -> 0 }

pair -> {
  u8:e <- 2
  data{e}:first
  data{e}:second
  -> e
}

pair{data{6} data{6}}!   // e = 6
pair{data{6} data{3}}!   // error: e cannot be both 6 and 3
```

A hole can also be filled explicitly. Since a hole is *pulled*, not pushed, the fill arrow at the use site is `<-`, not `->`:

```syntact
identity{T <- u8 value -> 5}!
```

`value -> 5` pushes a value into the field `value`. `T <- u8` says “fill the hole `T` with `u8`”. Mixing the two arrows is not a quirk: `->` pushes a value into a binding, `<-` pulls a value into a hole. A hole is filled only by `<-`, and a field only by `->`.

An explicit fill is one more constraint on the hole, not an override: `pair{e <- 4 data{6} data{6}}` is an error, since the carve forces `e = 6`.

A positional carve argument never lands in a hole. Positions count only the push fields, so holes are skipped:

```syntact
base -> {
  x <- 0
  u8:a -> 1
  u8:b -> 2
}

base{10, 20}   // a -> 10, b -> 20; x keeps its default
```

A scope whose only fields are holes has no positional slot: `{ x <- 0 }{9}` is an invalid carve.

This is genericity without a separate generic syntax.

A list can be described as a scope with a pulled element shape:

```syntact
List -> {
  T <- none

  -> {}
  -> { T:, ...List{T}: }
}
```

The first production is the empty list. The second production is a head shaped like `T` followed by another `List{T}` expanded into the same structure. The recursive reference `List{T}` propagates the same hole — it does not refill it.

Use it:

```syntact
List{T <- u8}:numbers
```

`T <- u8` fills the hole at the use site. As with `identity`, `T` can also be left to inference when the carving carries enough shape to recover it.

Generic abstractions are just scopes with holes.

A serializer can be modeled the same way:

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
}
```

Eventually, laws can be added to the same scope:

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

That is not only an interface. It is an algebraic contract: operations plus obligations.

Proof obligations are long-term. The generic structure does not depend on them.

---

---

[← Scope algebra](13-scope-algebra.md) · [Index](README.md) · [Effects, events, and handlers →](15-effects-and-handlers.md)
