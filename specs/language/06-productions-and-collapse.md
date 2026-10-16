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

### A production is evaluated at its call

A production runs where it is called, never where it is written, never where it is carved. A definition is not run with its defaults: `f` above is not evaluated by being written, so `f{n -> n - 1}` inside it is not checked against a value nobody asked for.

The call is not a value fixed once and for all. It runs in the **context of the call**: the handlers installed around it ([Effects](15-effects-and-handlers.md)). The same collapse can produce different values in different contexts:

```syntact
Log -> { string:message }
Log -< e { -> "default" }

lib -> {
  r >- Log{message -> "x"}
  -> r
}

quiet -> {
  Log -< e { -> "quiet" }
  -> lib!
}

lib!     // "default"
quiet!   // "quiet" — the same lib!, called in another context
```

So a collapse is an act, not a cached value. Reducing a call to a constant at compile time is an optimisation, valid only when the call is pure and its inputs are known; otherwise the call stays a call.

### Compiled, not interpreted

Effects happen at run time. The type system is a partial evaluator: it reduces what is known and pure, and leaves the rest in the compiled program. For each call, it knows statically which handlers serve it — the context is written around the call — so it types the call in that context. The type of an emission is what its handler can answer; the emission itself is never reduced away: it stays in the compiled program, as an act, even when its answer is known.

---

---

[← Bindings](05-bindings.md) · [Index](README.md) · [Execution patterns →](07-execution-patterns.md)
