# State: resonance and reactivity

> **Open.** Resonance and reactivity are built on events (chapter 10). They are not
> written in `types.md` and the kernel does not build them.

Nothing in the algebra is ever modified. Change over time is opt-in, and explicit:

```text
resonance   >>-  -<<     a binding that changes only through a named event
reactivity  >>=  =<<     a binding that is recomputed when what it reads changes
```

A program without them is purely algebraic.

## Resonance

```text
Counter -> {
  Change -> {u8:value}
  -> {
    u8:value >>- Change -> 0
    Change -< e {
      value -<< e.value
    }
    increment -> {
      >- Change{value -> value + 1}
    }
    -> value
  }
}
```

`>>-` declares that `value` is resonant: it changes, but only through the event
`Change`. `-<<` performs the update, inside the handler. There is no hidden mutable
field: every change goes through a visible event.

## Reactivity

```text
Counter:counter
bool:positive >>= counter.value >= 0
```

`positive` is not computed once: it follows `counter.value`. A reactive production
`=<<` re-runs when what it reads changes:

```text
Text -> {
  string:text =<< ""
  =<< text ? {
    -> >- Redraw{}
  }
}
```

Resonance is where state changes; reactivity is where the change propagates. A state
abstraction, a UI component, a store are scopes built on them, not special syntax.

---

[← The external boundary](11-external-boundary.md) · [Index](README.md) · [Execution patterns →](13-execution-patterns.md)
