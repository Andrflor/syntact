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

A file is a scope. A folder is a scope. A library is a scope. A primitive type is a scope. A pattern can be a scope. A program is a scope.

---

---

[← First program](03-first-program.md) · [Index](README.md) · [Bindings →](05-bindings.md)
