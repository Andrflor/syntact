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

`...C:` expands an anonymous binding colored by `C`, as `u8:` is an anonymous
binding colored by `u8`. As a value, it places the default of `C`; in a shape, it
admits any scope that `C` admits, so the shape no longer has a fixed length:

```syntact
Pair -> {u8: u8:}
{...Pair: string:}:a -> {1 2 "x"}     // a pair, then a string
```

`...` alone is `...` of any scope — as `..` alone is any atom. Its default, like
the default of every scope at all, is the empty scope `{}`, as the default of every
string is `""`. It is written
detached: `...xs` expands `xs`, while `... ` followed by a space, a new line or a
closing brace expands any scope:

```syntact
{... u8:b}:a            // a: any scope whose last binding is a u8 named b
{u8:x ...}:c            // c: a u8 named x, then anything
```

A file is a scope. A folder is a scope. A library is a scope. A primitive type is a scope. A pattern can be a scope. A program is a scope.

---

---

[← First program](03-first-program.md) · [Index](README.md) · [Bindings →](05-bindings.md)
