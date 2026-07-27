# Resonance and reactivity

## Resonance

Resonance is the explicit model for state.

The idea:

```text
mutation = value driven by nominal event
```

A resonant binding uses `>>-` and `-<<`.

```syntact
Counter -> {
  Change -> { u8:value }

  -> {
    u8:value >>- Change -> 0

    Change -< e {
      value -<< e.value
    }

    increment -> {
      >- Change{value -> value + 1}
    }

    decrement -> {
      >- Change{value -> value - 1}
    }

    -> value
  }
}
```

`>>-` declares that a binding is **resonant**: it can change, but only through a named event. `-<<` performs the actual update inside the handler.

There is no hidden mutable field. The state changes only through a visible nominal event.

A reusable state abstraction can be a normal scope:

```syntact
State -> {
  T <- none
  T:initial

  -> {
    Update -> { T:value }

    T:value >>- Update -> initial

    Update -< e {
      value -<< e.value
    }

    set -> {
      T:value
      >- Update{value -> value}
    }

    -> {
      -> value
      set -> set
    }
  }!
}
```

Resonance is not part of the first implementation. Events come first. Resonance is built on top of events.

---

## Reactivity

Reactivity is the implicit model for derived state.

Where resonance requires an explicit event to drive change, a reactive binding automatically recomputes when its dependencies change. The operators are `>>=` and `=<<`.

### Reactive bindings with `>>=`

`>>=` declares a binding whose value is derived from an expression and recomputes when that expression's dependencies change.

```syntact
Counter:globalCounter

bool:counterPositive >>= globalCounter.value >= 0
```

`counterPositive` is not set once. It tracks `globalCounter.value` and recomputes whenever it changes. If `globalCounter` is driven by resonance, then `counterPositive` reacts to each resonant update without needing its own event.

A reactive binding can also be combined with resonance on the same binding:

```syntact
T:value >>- Update =<< initial
```

This means: `value` is resonant (driven by the `Update` event) and initially bound by reference to `initial`. The `>>=`/`=<<` side provides the initialization and structural link; the `>>-` side provides the mutation channel.

### Reactive productions with `=<<`

`=<<` without a left side declares a reactive production: a side effect that re-executes when its dependencies change.

```syntact
Text -> {
  string:text =<< ""
  =<< text ? {
    -> >- Redraw{}
  }
}
```

When `text` changes, the production re-evaluates and emits a `Redraw` event. This is how a UI component can react to its own state without polling or manual subscriptions.

### Resonance vs reactivity

The two mechanisms serve different roles and compose together:

```text
resonance   explicit state change through a nominal event
reactivity  implicit derived computation that tracks dependencies
```

Resonance is where mutation happens. Reactivity is where propagation happens. A reactive binding can observe resonant bindings, other reactive bindings, or any binding whose value may change.

```syntact
State -> {
  T <- none
  T:initial
  -> {
    Update -> { T:value }
    T:value >>- Update =<< initial
    Update -< e { value -<< e.value }
    update -> { T:value, >- Update{value} }
    -> { -> value, set -> update }
  }!
}
```

Then UI state can be built by libraries, not special syntax:

```syntact
CounterView -> {
  State{initial -> 0}:value

  -> Column{
    children -> {
      Text{content -> value!}

      Button{
        label -> "Increment"
        onClick -> {
          value.set{value -> value! + 1}!
        }
      }
    }
  }
}
```

`State`, `Column`, `Text`, and `Button` are scopes. The SDK should be a library of scopes, not a second language.

Neither resonance nor reactivity is part of the first implementation. Events come first. Resonance is built on top of events. Reactivity is built on top of resonance.

---

---

[← The external boundary](16-external-boundary.md) · [Index](README.md) · [Files, folders, imports, metaprogramming →](18-modules.md)
