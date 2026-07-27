# Effects, events, and handlers

## Effects as nominal events

> Syntact is structural by default. Effects are the exception: they are nominal because sometimes structural equality is not meaning equality.

Two events may have the same payload and still be different capabilities. A `Log` and an `Audit` event can carry the same string and still mean very different things. The structure cannot tell them apart; only the name can.

Nominality is not a property of ordinary data in Syntact. It is introduced explicitly through effects.

Values are structural. Shapes are structural. Patterns are structural. Modules are structural. Scopes are structural.

Effects are different. Effects are **nominal events** with structural payloads.

```syntact
Log -> {
  string:message
}

Audit -> {
  string:message
}
```

`Log` and `Audit` have the same structure, but they do not mean the same thing. A `Log` handler must not accidentally handle an `Audit` event.

So the rule is:

```text
internal computation is structural
effects are nominal capabilities
```

Emit an event with `>-`:

```syntact
>- Log{message -> "hello"}
```

Handle an event with `-<`:

```syntact
Log -< e {
  -> io.write{e.message}!
}
```

A full example:

```syntact
program -> {
  Log -< e {
    -> io.write{e.message}!
  }

  >- Log{message -> "hello"}
  -> 0
}

-> program!
```

Handlers are scoped. The first visible handler handles the event. After handling, execution resumes at the point where the event was emitted.

This is Syntact's version of algebraic effects. They are called events because they are emitted and handled, but they are not callbacks, observers, or pub/sub messages.

---
---

## Handlers as compile-time dependency injection

Handlers make many runtime dependency injection patterns unnecessary.

In a classical language, if code needs an allocator, logger, clock, database, random source, HTTP client, or filesystem, you often pass a value around:

```text
function(..., allocator, logger, db, clock)
```

or you hide it behind an object, interface, global, context, or DI container.

In Syntact, the code emits a nominal event. The surrounding scope decides how to interpret it.

```syntact
Alloc -> {
  u64:size
}

Buffer -> {
  u64:size
  ptr -> >- Alloc{size -> size}
  -> ptr
}
```

One scope may choose malloc:

```syntact
WithMalloc -> {
  Alloc -< e {
    -> malloc{e.size}!
  }

  -> Buffer{size -> 1024}!
}
```

Another may choose an arena:

```syntact
WithArena -> {
  Alloc -< e {
    -> arena.alloc{e.size}!
  }

  -> Buffer{size -> 1024}!
}
```

`Buffer` does not receive an allocator. There is no allocator variable. There is only a nominal effect resolved by the current scope.

A library can be specialized by carving its handler:

```syntact
FastLib -> SomeLib{
  Alloc -< e {
    -> arena.alloc{e.size}!
  }
}
```

This is dependency injection moved from runtime to compile time.

It is also an optimization surface. If the handler is known at collapse time, an allocation event can become a malloc call, an arena bump, a stack allocation, a pooled allocation, or disappear entirely if the reduction proves it unnecessary.

The same idea applies to:

```text
logging
profiling
database access
transactions
filesystem permissions
randomness
time
HTTP clients
test mocks
sandboxing
error policy
```

In other languages, this often requires DI, interfaces, mocks, macros, build-time configuration, or runtime lookup. In Syntact, it is scope and handler selection.

---

---

[← Pull bindings and genericity](14-genericity.md) · [Index](README.md) · [The external boundary →](16-external-boundary.md)
