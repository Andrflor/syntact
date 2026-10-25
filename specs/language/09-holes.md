# Holes and genericity

`<-` declares a **hole**: a binding the use site fills. Until it is filled, a hole
holds its default, like any binding.

```syntact
identity -> {
  T <- none
  T:value -> none
  -> value
}
```

## Filling a hole

A hole is filled by `<-`, a field by `->`. The two arrows are not interchangeable:

```syntact
a -> identity{T <- u8  value -> 5}!    // 5: T is u8
b -> identity{T -> u8}!                // refused: T is a hole, filled by <-
c -> identity{value <- 5}!             // refused: value is a field, filled by ->
```

An unnamed argument never lands in a hole: positions count the fields only. A scope
whose only bindings are holes has no position.

```syntact
base -> {
  x <- 0
  u8:a -> 1
  u8:b -> 2
}
p -> base{10, 20}          // a 10, b 20; x keeps its value
only -> {x <- 0}
q -> only{9}               // refused: no binding left to carve
```

## Inferring a hole

A hole the carve does not fill is inferred from what the carve puts where the hole is
mentioned: in the color of a field it fills, or in the value that field had. The
places are read on a copy of the scope where the hole is an unknown, set beside what
the carve puts there.

What lands in a hole is of one of two kinds:

- a **sent value**: `5` in `identity{value -> 5}`, or the elements of a list. A value
  can be read in a larger type without changing its meaning;
- a **required type**: the color of something the carve provides, or an explicit
  fill `T <- u8`. A required type cannot be read as a larger one: a scope that takes
  `(2.4 | 3):e`, read as one that takes `(u8 | float):e`, would accept values it
  refuses.

The hole takes the one that holds all the others — never their union:

- if something requires a type, every required type is the same, and the hole is that
  type; every sent value must be in it;
- otherwise one of the sent values holds all the others, and the hole is that one.

Anything else is an error. Then, as for every binding, the hole's own color applies.

```syntact
d -> identity{value -> 5}!             // T is 5
e -> identity{T <- 4  value -> 5}!     // refused: 5 is not in 4

data -> {u8:x -> 0}
pair -> {
  u8:e <- 2
  data{e}:first
  data{e}:second
  -> e
}
r -> pair{data{6} data{6}}!            // 6: e is 6
s -> pair{data{6} data{3}}!            // refused: neither 6 nor 3 holds the other
t -> pair{e <- 4  data{6} data{6}}!    // refused: 6 is not in 4
```

## Genericity

A generic scope is a scope with holes:

```syntact
Array -> {
  T -> {}
  -> {}
  -> {T: ...Array{T}:}
}
map -> {
  T <- {}
  E <- {}
  Array{T}:source
  func -> {e -> T:, -> E:}
  -> source ? {
    {T:(e) ...Array{T}:(r)} -> {func{e -> e}! ...map{r, func}!}
    {} -> {}
  }
}
ok -> map{{2 3 4 5}, {u8:e, -> e + 1}}!    // T is u8: u8 is required by func
bad -> map{{2.4 3}, {u8:e, -> e + 1}}!     // refused: 2.4 is not in u8
```

`map{…}!` stays a call: the recursion has no closed form. Its production is typed for
the values the carve gives, and the recursive call in it, a scope by its base cases,
is placed by `...`.

---

[← Recursion](08-recursion.md) · [Index](README.md) · [Effects and handlers →](10-effects-and-handlers.md)
