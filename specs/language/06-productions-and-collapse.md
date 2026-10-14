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

## Productions are lazy

A production is evaluated only when its value is asked for:

- a collapse `!`;
- a default — the default of a scope with productions is its first one;
- a color that reads the scope as a set of values;
- a pattern branch that fires.

Nothing else evaluates it. A carve derives a scope and checks the bindings it changes; it does not run the derived scope's production:

```syntact
f -> {
  u8:n
  -> n + 1
}

g -> f{n -> 5}    // a scope: its production is not evaluated
g!                // 6 — evaluated here, because it is asked for
```

This is what lets a scope mention itself. `List{T}` inside `List`, or `f{n -> n - 1}!` inside `f`, only unfolds as far as a value is actually asked for.

---

---

[← Bindings](05-bindings.md) · [Index](README.md) · [Execution patterns →](07-execution-patterns.md)
