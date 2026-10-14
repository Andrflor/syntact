# Pull bindings and genericity

`<-` declares a **hole**: a binding the use site fills. Until it is filled, a hole holds its default, like any binding.

```syntact
identity -> {
  T <- none
  T:value -> none
  -> value
}
```

`T` is a hole. `value` is an ordinary field, colored by `T`.

## Filling a hole

A hole is filled by `<-`, a field by `->`. The two arrows are not interchangeable: `->` pushes a value into a field, `<-` pulls a value into a hole.

```syntact
identity{T <- u8 value -> 5}!   // T is u8, value is 5
identity{T -> u8}!              // error: T is a hole, it is filled by <-
identity{value <- 5}!           // error: value is a field, it is filled by ->
```

A positional argument never lands in a hole: positions count only the fields.

```syntact
base -> {
  x <- 0
  u8:a -> 1
  u8:b -> 2
}

base{10, 20}   // a -> 10, b -> 20; x keeps its default
```

A scope whose only bindings are holes has no position: `{ x <- 0 }{9}` is an invalid carve.

## Inferring a hole

A hole the carve does not fill is inferred from the carve. Everything the carve puts where the hole is mentioned — in the color of a field it fills, or in the value that field had — lands in the hole:

```syntact
identity{value -> 5}!   // 5 lands in T: T is 5
```

What lands in a hole is of one of two kinds:

- a **sent value**: `5` above, or the elements of a list. A value can be read in a larger type without changing its meaning: `{2.4 3 4 5}` read as `u8|f32` is still `{2.4 3 4 5}`.
- a **required type**: the color of something the carve provides, or an explicit fill `T <- u8`. A required type cannot be read as a larger one: a function that takes `(2.4|3|4|5):e`, read as one that takes `(u8|f32):e`, would accept values it refuses.

The hole takes the one that holds all the others. It is never their union: the type must already be one of them.

- If something requires a type, every required type is the same, and the hole is that type. Every sent value must be in it.
- Otherwise, one of the sent values holds all the others, and the hole is that one.

Anything else is an error. Then, as for every binding, the hole's own color applies.

```syntact
identity{T <- u8 value -> 5}!   // T requires u8, 5 is in u8: T is u8
identity{T <- 4 value -> 5}!    // error: 5 is not in 4
```

Two fields that mention the same hole must agree:

```syntact
data -> { u8:x -> 0 }

pair -> {
  u8:e <- 2
  data{e}:first
  data{e}:second
  -> e
}

pair{data{6} data{6}}!          // e is 6
pair{data{6} data{3}}!          // error: neither 6 nor 3 holds the other
pair{e <- 4 data{6} data{6}}!   // error: e requires 4, 6 is not in 4
```

The rule is the same for a generic function. Here `T` receives the elements of `source` (sent values), and the color of `e` in `func` (a required type):

```syntact
Array -> {
  T -> {}
  -> {}
  -> { T: ...Array{T}: }
}

map -> {
  T <- {}
  E <- {}
  Array{T}:source
  func -> { e -> T:, -> E: }
  -> source ? {
    { T:(e) ...Array{T}:(r) } -> { func{e -> e}! ...map{r, func}! }
    {} -> {}
  }
}

map{{2.4 3 4 5}, {(u8|f32):e, -> e*10}}!       // T is u8|f32: 2.4, 3, 4 and 5 are in it
map{{2.4 3 4 5}, {(2.4|3|4|5):e, -> e*10}}!    // T is 2.4|3|4|5
map{{2.4 3 4 5}, {string:e, -> e}}!            // error: 2.4|3|4|5 is not in string
```

The other way round is an error too. If `source` only knows its elements as `u8|f32`, a `func` that takes `(2.4|3|4|5):e` cannot receive them: `u8|f32` is required on both sides, and the two differ.

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

---

---

[← Scope algebra](13-scope-algebra.md) · [Index](README.md) · [Effects, events, and handlers →](15-effects-and-handlers.md)
