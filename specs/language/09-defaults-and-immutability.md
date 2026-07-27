# Defaults, completeness, immutability

## Defaults and completeness

Defaults are not a small convenience feature. They are what make the one-world model possible.

A scope is complete because its bindings have defaults. A shaped binding is complete because its shape has a default. A computation is complete because it can be inspected or collapsed without being called.

```syntact
Point -> {
  u8:x
  u8:y
}

Point:p

p.x // 0
p.y // 0
```

`Point` is not a blueprint waiting for construction. It is already a complete scope.

```syntact
Point.x // 0
Point.y // 0
```

You can derive a specific point:

```syntact
p -> Point{x -> 10 y -> 20}
```

You can constrain a binding by it:

```syntact
Point:p{x -> 10 y -> 20}
```

You can inspect it:

```syntact
p.x
```

The difference between “type”, “value”, “blueprint”, and “instance” is not a difference of world. It is a difference of operation.

### Defaults compose

Defaults are compositional.

The default of a structured scope is obtained from the defaults of its shaped bindings. A complete structure composed of complete parts is itself complete.

```syntact
Vec2 -> {
  f32:x
  f32:y
}

Transform -> {
  Vec2:position
  Vec2:scale -> Vec2{x -> 1 y -> 1}
}

Transform.position.x // 0
Transform.position.y // 0
Transform.scale.x    // 1
Transform.scale.y    // 1
```

Defaults are not magic values produced by the compiler. They are the natural reading of a complete structure.

---

## No null, no uninitialized state

Syntact has no null.

There is no hidden “missing value” state and no uninitialized binding. A binding is complete because its shape provides a default, and defaults compose structurally.

```syntact
Point -> {
  u8:x
  u8:y
}

Point:p

p.x // 0
p.y // 0
```

`p` is not partially initialized. It is complete by composition.

If absence, failure, optionality, or emptiness is needed, it must be modeled structurally. It is never smuggled in as a null pointer or an uninitialized value.

---

## Algebraic immutability

This is the most important property of Syntact, and it must not be confused with the way mainstream languages talk about “immutability”.

**Nothing is ever modified.** A scope, once described, never changes. Every operator that looks like it changes something actually derives a *new* scope. The original is untouched and remains valid.

```syntact
box -> {
  x -> 1
  y -> x + 1
}

box2 -> box{x -> 10}
```

`box2` is **not** `box` with `x` patched. `box2` is a *new* scope derived from `box` by carving. In `box`, `x` is `1` and `y` is `2`. In `box2`, `x` is `10` and `y` is `11`. Both scopes coexist. Neither was mutated.

This is not “immutability by convention”. It is the meaning of carving. There is no operator in the language that mutates a binding in place. Every transformation is a fresh derivation in the algebra.

A consequence: there is no notion of “the value of `x` after we changed it”. There is only `box.x`, `box2.x`, and any other scope that participates in the derivation graph. Any of them can be inspected at any time.

---

## Mutation and reactivity are opt-in

Because the algebra is immutable, ordinary bindings cannot be mutated, reassigned, or updated in place. There are two separate mechanisms to model change, both layered on top of the immutable core:

- **Resonance** (`>>-` / `-<<`): explicit state driven by nominal events. A binding is declared resonant and its value evolves only when a named event is emitted and handled.
- **Reactivity** (`>>=` / `=<<`): implicit derived bindings that automatically recompute when their dependencies change. No explicit event is needed.

Resonance is the foundation: it is where mutation actually happens. Reactivity is built on top: a reactive binding observes other bindings (including resonant ones) and recomputes structurally.

A program with no resonant or reactive bindings is purely algebraic. Combined with the no-null rule above, this gives the core a strong guarantee: every binding has a value, no value is ever silently replaced, and the only way to model change is to opt in explicitly.

---

---

[← Carving](08-carving.md) · [Index](README.md) · [Values are sets →](10-values-are-sets.md)
