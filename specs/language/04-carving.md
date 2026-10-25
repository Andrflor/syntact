# Carving

`s{x -> w}` is a carve: the scope `s` where the first occurrence of `x` is `w`. A carve
is a copy with substitution of the original. It replaces an equation, and everything
whose equation names `x` follows:

```syntact
box -> {
  x -> 1
  y -> x + 1
}
b2 -> box{x -> 10}
b2y -> b2.y            // 11
```

`box` is untouched: `box.y` is still 2. Nothing is ever modified; a carve is a new
scope.

## Calling is carving, then collapsing

```syntact
square -> {
  n -> 0
  -> n * n
}
sq -> square{n -> 5}!      // 25
```

`square` is a complete scope, not a function, and `n` is a binding, not a parameter.
`square{n -> 5}` derives a scope; `!` collapses it.

## Arguments

A named argument targets the first occurrence of its name; `x#n -> w` the n-th. An
unnamed argument targets, in order, the bindings that are neither productions nor
holes (chapter 09):

```syntact
Point -> {x -> 0  y -> 0}
shifted -> Point{x -> 5}     // x 5, y 0
p34 -> Point{3, 4}           // x 3, y 4
```

`.x` without a scope is the current scope's `x`: inside a carve's arguments, the scope
being carved.

### A carve carves any binding

`z{…}` as an argument carves the binding `z` of the target in turn:

```syntact
nest -> {box -> {x -> 1}  -> 0}
deep -> nest{box{x -> 5}}.box.x     // 5
```

## A scope is closed

A carve replaces equations; it never adds one. A name the scope does not have is an
error, not a new binding:

```syntact
bad -> Point{z -> 1}       // refused: Point has no binding z
```

A different structure is a different scope, written as such.

## A carve is checked where it is written

A carve is checked in what it changed: the replaced equations, and those that name
them. The rest was checked where the scope is written.

```syntact
B -> {u8:n -> 1}
cb -> B{n -> 300}          // refused: 300 is not in 0..255
```

The value of a binding colored by `C`, carved, is checked against `C` (chapter 05).
A carve of a solved recursive equation substitutes its arguments into the solution
(chapter 08): `sum{n -> 5}!` is the closed form of `sum!` with `n` = 5.

> **Open.** A carve that reaches a binding placed by an expansion — `{...a  z -> 9}{x
> -> 5}`, meant as `{...a{x -> 5}  z -> 9}` — is not built by the kernel yet.

---

[← Scopes](03-scopes.md) · [Index](README.md) · [Shapes →](05-shapes.md)
