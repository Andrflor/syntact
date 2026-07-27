# Productions and collapse

## Productions

A production is a binding without an explicit left side.

```syntact
greeting -> "hello"
-> greeting
```

The implicit source is the enclosing scope itself. The scope points itself at the value it produces.

This replaces `return`.

```syntact
add -> {
  a -> 1
  b -> 2
  -> a + b
}
```

The scope `add` produces `a + b` when collapsed.

A scope may have several productions.

```syntact
BoolLike -> {
  -> false
  -> true
}
```

The first production is the default. Additional productions are potentialities. This is what later allows sum-like shapes and pattern matching.

---

## Collapse

Collapse is written `!`.

```syntact
two -> {
  a -> 1
  b -> 1
  -> a + b
}

two.a // 1
two.b // 1
two!  // 2
```

`!` does not mean “evaluate this expression”. It specifically means: reduce this scope through its production.

A binding may point directly to a value:

```syntact
box -> {
  x -> 1
  y -> x + 1
}

box.y // 2
```

Here `y` is not a scope, so there is nothing to collapse.

A binding may also point to a scope:

```syntact
box -> {
  x -> 1
  y -> {
    -> x + 1
  }
}

box.y  // the scope bound to y
box.y! // 2
```

The rule is:

```text
expressions resolve
scopes collapse
```

A scope with no production collapses to `none`.

```syntact
empty -> {
  x -> 1
  y -> 2
}

empty! // none
```

Collapse is intentional. It happens where `!` appears. That explicitness is what lets the compiler reduce as much as possible before runtime.

---

---

[← Bindings](05-bindings.md) · [Index](README.md) · [Execution patterns →](07-execution-patterns.md)
