# Scopes

A scope is what `{...}` creates.

```syntact
point -> {
  x -> 10
  y -> 20
}

point.x // 10
point.y // 20
```

Scopes can nest:

```syntact
user -> {
  name -> "Alice"
  address -> {
    city -> "Toulouse"
    zip -> 31000
  }
}

user.address.city // "Toulouse"
```

A scope is a complete ordered structure. You can bind it to a name, read its bindings, derive it, constrain values by it, match against it, expand it, or collapse it if it has a production. The role it plays — value, type, module, function-like computation, instance — comes from the operation applied to it, not from a built-in category.

## Expansion `...`

`...E` places the bindings of the value of `E` right here — all of them, as
they are, exactly as if they were written by hand:

```syntact
xs -> {2 3}
ys -> {1 ...xs 4}       // {1 2 3 4}

point -> {x -> 1  y -> 2}
moved -> {...point  z -> 3}
moved.y                 // 2
```

Nothing is special about what gets placed: a production is placed as a
production (`{...{-> 5}}!` is `5`), and a name already present is simply a
second occurrence, as in any scope (`{x -> 0  ...{x -> 1}}.x` is `1`, the last
one; `.x#0` is `0`). Only a scope can be expanded.

A carve reaches through an expansion: carving a binding that an expansion
placed carves the expanded value, and everything that depends on it there
follows:

```syntact
a -> {u8:x -> 1  u8:y -> x + 1}
b -> {...a  z -> 9}
b{x -> 5}.y             // 6 — `{...a  z -> 9}{x -> 5}` is `{...a{x -> 5}  z -> 9}`
```

Expanded alone, `...` places any scope at all — as `..` alone is any atom. In a
shape, it is a run of any bindings:

```syntact
{... u8:b}:a            // a: any scope whose last binding is a u8 named b
```

A file is a scope. A folder is a scope. A library is a scope. A primitive type is a scope. A pattern can be a scope. A program is a scope.

---

---

[← First program](03-first-program.md) · [Index](README.md) · [Bindings →](05-bindings.md)
