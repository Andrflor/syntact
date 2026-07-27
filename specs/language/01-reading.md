# How to read Syntact

Syntact intentionally uses familiar surface syntax.

A beginner may read:

```syntact
square -> {
  n -> 0
  -> n * n
}

square{n -> 5}!
```

as something close to:

```text
function square(n = 0) { return n * n }
square(5)
```

That reading is useful, but incomplete.

The structural reading is:

```text
square        a complete scope
n -> 0        a binding occurrence with a default
{n -> 5}      a structural derivation of the scope
!             explicit collapse through the scope production
```

Syntact is designed so shallow readings are productive, but deeper readings reveal the actual model.

A scope is not a function, object, module, record, class, or type. Those are projections produced by operations over scopes.

### Classical reading vs Syntact reading

| Surface form | Classical temptation | Syntact meaning |
|---|---|---|
| `n -> 0` | variable assignment | binding occurrence |
| `-> x` | return | production |
| `square{n -> 5}` | function call setup | structural derivation |
| `square!` | call/eval | collapse |
| `Point:p` | declaration of variable p | binding colored by `Point` — the constraint propagates structurally |
| `box.x` | field access | projection through current view |
| `Log -< e {...}` | callback/listener | nominal effect handler |
| `value >>- Change` | mutable variable | resonant binding driven by nominal event |
| `value -<< e.value` | assignment | resonant update inside handler |
| `x >>= expr` | computed property | reactive derived binding |
| `=<< expr` | reactive effect | reactive production |

The analogies in the middle column help you start reading code. They are not what the language actually does.

---

---

[Index](README.md) · [Core rules →](02-core-rules.md)
