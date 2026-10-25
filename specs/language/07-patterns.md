# Patterns

`t ? {c -> p …}` is a pattern: a type of the algebra, like `|` and `~`. Its branches
are scopes whose production is written in their cover. It takes its target whole, and
gives the product of the first branch whose cover admits it:

```text
t ? {c -> p  …} = p              when t in c = true
t ? {c -> p  …} = t ? {…}        when t in c = false
t ? {-> p  …}   = p              a branch without a cover admits everything
t ? {c -> p  -> p} = p           a pattern whose branches give one product is it
```

A cover is any type: a value, a set, a shape, a composition.

```syntact
n -> ??::u8
name -> n ? {
  0 -> "zero"
  1 -> "one"
  -> "many"
}
```

Write one branch per line when a cover starts with an operator: `"zero" >0` would read
as a comparison.

## An unknown target

On an unknown target, `t in c` does not reduce, and the pattern stays an equation.
The link with the target is kept: it is the same unknown.

```syntact
a -> ??::u8
r -> a ? {<10 -> a + 3  -> 10}      // ?0 ? {..9 -> ?0 + 3  -> 10}
```

Each branch takes what the branches above left, and inside it the target is narrowed
to that (chapter 06). A value that no branch takes is an error: the pattern is not
exhaustive.

```syntact
u8:k -> ??
h -> k ? {=5 -> 1}          // refused: 0..4 and 6..255 are taken by no branch
```

A pattern covers the value of its target, not its color. A known target fires
exactly one branch:

```syntact
f -> {
  u8:x -> 5
  -> x ? {=5 -> 1}          // x is 5: exhaustive
}
g -> f{x -> 6}!             // refused: no branch takes 6
```

## Destructuring

A branch's product is a production of its cover: the names the cover gives are in
scope on the right, bound to the pieces of the target. There is no extraction
operator.

```syntact
Circle -> {u8:radius}
c -> Circle{radius -> 5}
area -> c ? {
  Circle: -> radius * radius      // 25
  -> 0
}
```

A cover written as a scope names its pieces by captures. `(h)` is an alias that only
the product reads: not a field, not reachable by `.` or by a carve. `u8(h)` is the
same capture as `u8:(h)`:

```syntact
xs -> {3 4 5}
head -> xs ? {
  {u8:(h) ...Array{u8}:(t)} -> h  // 3
  -> 0
}
tail -> xs ? {
  {u8(h) ...Array{u8}:(t)} -> t   // {4 5}
  -> {}
}
```

Two shapes that give the same names unify, since resolution is structural:

```syntact
Square -> {u16:side}
Diamond -> {u16:side}
s -> Diamond{side -> 7}
sarea -> s ? {
  Square: | Diamond: -> side * side   // 49
  -> 0
}
```

---

[← Unknowns and the check](06-unknowns-and-the-check.md) · [Index](README.md) · [Recursion →](08-recursion.md)
