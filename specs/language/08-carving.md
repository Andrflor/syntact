# Carving

## Carving

`{...}` applied to an existing scope carves a derived scope.

```syntact
Point -> {
  x -> 0
  y -> 0
}

shifted -> Point{x -> 5}

Point.x   // 0
shifted.x // 5
shifted.y // 0
```

Carving does not mutate the original. It derives a new scope.

Carving propagates through dependent bindings.

```syntact
box -> {
  x -> 1
  y -> x + 1
}

box.y // 2

box2 -> box{x -> 10}
box2.y // 11
```

This is why carving is not argument passing. A function call passes values into a fixed body. A carve derives a new structure before reduction happens.

```syntact
square -> {
  n -> 0
  -> n * n
}

square{n -> 5}! // 25
```

Read it as:

```text
derive square with n = 5
then collapse the derived scope
```

---

## Carving is closed

Carving refines existing structure. It never adds new structure.

A scope is closed: its set of bindings is fixed the moment it is written. Carving can target any binding that already exists and derive a new scope with a different value, but it cannot introduce a binding that was not there.

```syntact
Role -> {
  -> "member"
  -> "admin"
}

User -> {
  string:name
  u8:age
  Role:role -> "member"
}

AdminUser -> User{
  role -> "admin" // refines the existing `role` binding
}
```

Targeting a name that does not exist is an error, not a silent addition. This protects the algebra: a typo cannot quietly grow a scope.

```syntact
User{
  raole -> "admin" // error: `raole` is not a binding of User
}
```

If you need a different shape, you write a different scope. A scope is complete *and* closed: you carve what is there, you do not bolt on what is not.

`{...}` means derivation or refinement of existing structure. There is no extension operator — there is no way to add a binding to an existing scope.

---

---

[← Execution patterns](07-execution-patterns.md) · [Index](README.md) · [Defaults, completeness, immutability →](09-defaults-and-immutability.md)
