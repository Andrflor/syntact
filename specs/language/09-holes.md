# Holes and genericity

> **Open.** Holes are not written in `types.md` yet, and the kernel does not build
> them. Their inference below is the intent; its law is to be written in the algebra
> before it is implemented.

`<-` declares a **hole**: a binding the use site fills. Until it is filled, a hole
holds its default, like any binding.

```text
identity -> {
  T <- none
  T:value -> none
  -> value
}
```

## Filling a hole

A hole is filled by `<-`, a field by `->`. The two arrows are not interchangeable:

```text
identity{T <- u8  value -> 5}!    // T is u8, value is 5
identity{T -> u8}!                // error: T is a hole, it is filled by <-
identity{value <- 5}!             // error: value is a field, it is filled by ->
```

An unnamed argument never lands in a hole: positions count the fields only. A scope
whose only bindings are holes has no position: `{x <- 0}{9}` is an invalid carve.

## Inferring a hole

A hole the carve does not fill is inferred from what the carve puts where the hole is
mentioned: in the color of a field it fills, or in the value that field had.

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

```text
identity{value -> 5}!             // T is 5
identity{T <- u8  value -> 5}!    // T is u8: 5 is in u8
identity{T <- 4  value -> 5}!     // error: 5 is not in 4
```

## Genericity

A generic scope is a scope with holes:

```text
map -> {
  T <- {}
  E <- {}
  Array{T}:source
  func -> {e -> T:  -> E:}
  -> source ? {
    {T:(e) ...Array{T}:(r)} -> {func{e -> e}! ...map{r, func}!}
    {} -> {}
  }
}

map{{2 3 4 5}, {u8:e  -> e + 1}}!     // T is u8: {3 4 5 6}
map{{2.4 3}, {u8:e  -> e + 1}}!       // error: 2.4 is not in u8
```

---

[← Recursion](08-recursion.md) · [Index](README.md) · [Effects and handlers →](10-effects-and-handlers.md)
