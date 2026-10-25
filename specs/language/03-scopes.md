# Scopes

`{…}` is a scope: an ordered sequence of bindings. Each binding is an equation —
its name denotes the type of its value —, so a scope is a system of equations, and
a new type: `0` is not `{0}`.

```syntact
point -> {
  x -> 10
  y -> 20
}
px -> point.x      // 10
```

A file is a scope. Running a program is collapsing it: `-> 0` is a whole program.

## Bindings

```text
name -> value        a binding
C:name -> value      colored by C
C:name               colored, with the default of C
-> value             a production: the scope's own value
value                an anonymous binding
```

A binding sees what is written above it, in its scope and in the scopes around it.
`y -> x + 1` above `x -> 1` is an error: `x` is not defined above.

### Occurrences

Two bindings may share a name. They are two occurrences, not a redefinition:

```syntact
box -> {
  x -> 1
  y -> x
  x -> 2
}
bx -> box.x        // 2: an access reads the last occurrence
by -> box.y        // 1: y was written under the first
b0 -> box.x#0      // 1: x#n reads the n-th
```

A carve targets the first occurrence (chapter 04), so the two questions differ:
reading asks what a name shows now, carving asks what the scope is built on.

```syntact
Config -> {
  port -> 8080
  next -> port + 1
  port -> 3000
}
Dev -> Config{port -> 9000}

cp -> Config.port    // 3000
cn -> Config.next    // 8081
dp -> Dev.port       // 3000
dn -> Dev.next       // 9001
```

## Laws

```text
{… x -> v …}.x       = v                the last occurrence; x#n, the n-th
{… -> p …}!          = p                the first production
{no production}!     = none
{1 ...{2 3} 4}       = {1 2 3 4}        expansion places the bindings as they are
```

### Productions and collapse

`-> p` is a binding without a left side: the scope points at what it produces. `!`
collapses a scope through its first production. That replaces `return` and the call:

```syntact
two -> {
  a -> 1
  b -> 1
  -> a + b
}
twoc -> two!           // 2
empty -> {x -> 1}
none_ -> empty!        // none
```

A scope may have several productions: the first one is its value, the others are what
it may produce (chapter 05). A production is typed when it is asked: by a collapse,
a default, a color that reads it, or a branch that fires.

### Expansion

`...e` places the bindings of the scope `e` right here, as if they were written by
hand: a production as a production, a name already present as a second occurrence.
Only a scope can be expanded.

```syntact
xs -> {2 3}
ys -> {1 ...xs 4}      // {1 2 3 4}
```

`...C:` places an anonymous binding colored by `C`: in a value, the default of `C`; in
a shape, a run of bindings that `C` admits (chapter 05). `...` alone, written apart,
is any run.

## Complete, and never changed

Every binding has a value, its default if none is written (chapter 01). A scope is
therefore complete: it can be read, carved or collapsed as soon as it is written, and
the defaults of its parts compose:

```syntact
Vec2 -> {f32:x  f32:y}
Transform -> {
  Vec2:position
  Vec2:scale -> Vec2{x -> 1.0  y -> 1.0}
}
tpx -> Transform.position.x     // 0.0
tsx -> Transform.scale.x        // 1.0
```

Nothing is ever modified. A carve derives a new scope; the one it carves stays as it
is. Change over time is modelled by events and resonance, which are explicit
(chapters 10 and 12).

---

[← Operators](02-operators.md) · [Index](README.md) · [Carving →](04-carving.md)
