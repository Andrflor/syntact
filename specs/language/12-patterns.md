# Patterns and destructuring

## The pattern operator `?`

`?` is the pattern operator.

It takes a value on the left and a set of patterns on the right. The first matching pattern selects the corresponding production.

The simplest patterns are literal patterns:

```syntact
n ? {
  0 -> "zero"
  1 -> "one"
  -> "many"
}
```

The final branch has no explicit pattern. It is the default branch.

A pattern can be a shape:

```syntact
shape ? {
  Circle: -> "circle"
  Square: -> "square"
  -> "unknown"
}
```

Here `Circle:` is an anonymous binding shaped by `Circle` — a complete value, by default completeness. Matching is against that complete value: a structural shape carries its colored fields, and a colored field admits any value of its color, so any `Circle`-shaped value takes this branch.

For a primitive shape the complete value is a single leaf — the default — so the anonymous-binding form matches only that value:

```syntact
n ? {
  u8: -> "zero"    // u8: is an anonymous u8 binding — its complete value is 0
  -> "not zero"
}
```

To match a primitive's whole set, use the shape itself, bare:

```syntact
n ? {
  u8 -> "fits in a byte"
  -> "wider"
}
```

The rule is uniform: a branch match is an ordinary expression denoting a set of values, and the branch fires when the scrutinee belongs to it. A bare shape denotes its set. `C:` denotes the complete value of an anonymous binding colored by `C` — structure admits through its colors, a leaf admits only itself.

A pattern can be a refinement:

```syntact
n ? {
  0 -> "zero"
  >0 -> "positive"
  -> "negative"
}
```

A pattern can be composed:

```syntact
value ? {
  (u8 | i8) & >10 -> "small signed-or-unsigned int greater than 10"
  -> "something else"
}
```

This is why `?` is not just an if/switch replacement. It is the analytic side of the algebra.

---

## Destructuring patterns

Destructuring needs no syntax of its own: **a branch's product is lexically a
production of its cover**, so the cover's bindings are simply in scope on the
right side. When the branch fires, the matched pieces substitute into the cover
— reading them IS destructuring.

A named cover exposes its fields by name:

```syntact
Circle -> {
  u8:radius
}

area -> {
  Shape:shape

  -> shape ? {
    Circle: -> radius * radius * 3
    -> 0
  }
}
```

`Circle:` is the anonymous shaped binding; inside the branch, `radius` resolves
into the matched Circle — no extraction operator, just the ordinary resolution
chain.

A structural cover names its pieces with captures. `(x)` is an invisible alias:
not a field, unreachable by `.` or carving, mentionable only from the branch:

```syntact
x -> {3 4 5}

-> x ? {
  {u8:(h) ...u8:(t)} -> h    // h = 3, t = the rest {4 5} as a scope
  -> 0
}
```

A capture may also glue directly onto the name it aliases: `u8(h)` is the same
capture as `u8:(h)`. The parenthesized name is never a call — collapse is `!` —
so even `u8(u8)` reads unambiguously as "a `u8`, captured under the name `u8`".

The cons cover `{u8:(h) ...u8:(t)}` consumes the run the way the grammar does:
one colored head, an expand tail swallowing the rest — so recursion over a list
is a pattern whose cover mirrors the list's own grammar:

```syntact
sum -> {
  Array{u8}:list
  -> list ? {
    {} -> 0
    {u8:(h) ...Array{u8}:(t)} -> h + sum{list -> t}!
  }
}
```

Two shapes unify through a common projection because resolution is structural,
not nominal — both covers expose `side`:

```syntact
Square -> {
  u16:side
}

Diamond -> {
  u16:side
}

area -> {
  Shape:shape

  -> shape ? {
    Square: | Diamond: -> side * side
    -> 0
  }
}
```

No nominal interface is required. The cover says what structure it needs, and
what it names is what the product can read.

---

## Carving versus destructuring

This distinction is important. These two forms are different:

```syntact
Circle{radius?<10}
Circle{radius?<10}:
```

### `Circle{...}`

This carves or refines the scope `Circle` itself.

```syntact
SmallCircle -> Circle{radius?<10}
```

This defines a refined shape — a new scope, no binding, no capture.

### `Circle{...}:`

This creates an anonymous binding constrained by the carved shape.

```syntact
Circle{radius?<10}:
```

This means "some anonymous value shaped like a Circle whose radius is less than
10". As a pattern cover it matches such values, and its fields destructure the
usual way — the product reads them lexically:

```syntact
SmallCircle -> Circle{radius?<10}

shape ? {
  SmallCircle: -> radius * radius * 3
  -> 0
}
```

This separation keeps the syntax algebraic instead of magical: `{...}` always
derives, `:` always colors, and destructuring is never an operator — it is the
cover's bindings being in scope.

---

---

[← Shapes](11-shapes.md) · [Index](README.md) · [Scope algebra →](13-scope-algebra.md)
