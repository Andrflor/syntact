# Effects, events, and handlers

## Events and handles

An event is declared like any scope. Its bindings are the shape of what it carries:

```syntact
Log -> {
  string:message
}
```

A **handler** is installed with `-<`. Its left side is a **handle**: a reference to the event. Its right side captures what is sent, then gives the handler's body:

```syntact
Log -< e {
  -> e.message + "!"
}
```

`e` captures the value that is sent. It can be colored like any binding (`Log -< {string:message}:e {…}`), and the coloring is checked the ordinary way.

An event is **emitted** with `>-`, which is a binding like `->`. The emission is sent to the handler, and the binding receives the handler's answer:

```syntact
r >- Log{message -> "hi"}   // r is "hi!"
>- Log{message -> "hi"}     // the same emission, in an anonymous binding
```

### A handle is a reference

There is no special nominal identity. A handle is a reference to a binding, resolved like any name. Two events are the same when their handles reference the same binding:

```syntact
Log -> { string:message }
Audit -> { string:message }   // the same shape, another binding: another event
```

- `Log` and `Audit` have the same shape and are different events: they are two bindings.
- An alias references the same binding, so it is the same event: after `L -> lib.Log`, `L -< e {…}` handles `lib.Log`.
- A carved copy keeps the bindings of its source: after `fast -> lib{…}`, `fast.Log` is `lib.Log`.
- Another declaration is another event, even with the same name and the same shape. A `Log` declared in `main` is not `lib.Log`; to handle the event `lib` emits, write `lib.Log -< e {…}`.

What is sent carries no identity. `{message -> "hi"}` is an ordinary structural value: it only has to fit the shape of the event its handle references. `Log{message -> "hi"}` sends that value to the handle `Log`.

`-<` with nothing on its left installs nothing: there is no handle. `>- {message -> "hi"}` or `>- 42` are well formed bindings, but they reference no handle, so there is no handler to address: an error, like an emission that no handler serves.

### Which handler answers

An emission happens when the scope that holds it is collapsed ([Productions are evaluated at their call](06-productions-and-collapse.md#a-production-is-evaluated-at-its-call)), whether or not anything reads its answer. Laziness is about values; an emission is an act. Handlers are the only place where effects happen — the external boundary is crossed inside a handler — so an emission nobody reads still happens:

```syntact
program -> {
  Log -< e { -> io.write{e.message}! }
  >- Log{message -> "hello"}   // written, though nothing reads the answer
  -> 0
}

-> program!
```

The emissions of a collapse happen in the order they are written, each once: reading `r` twice reads one answer, it does not emit twice.

It is served by:

1. the handler installed for its handle in the **context of the call** — the scope that collapses, then the call that collapsed it, and so on up the calls in progress;
2. otherwise, the handler visible from where the emitting scope is written — the **callee's** handler, its default.

Every emission must have a default: a handler for its handle, visible from where it is written. An emission without one is an error at compile time, whatever handlers a caller may install.

```syntact
lib -> {
  Log -> { string:message }
  Log -< e { -> "default" }
  r >- Log{message -> "x"}
  -> r
}

main -> {
  lib.Log -< e { -> "main" }
  -> lib!
}

lib!    // "default"
main!   // "main"
```

After the handler answers, execution resumes where the event was emitted.

### Two ways to specialize

A handler is replaced in two different ways:

- **In the context of a call.** A scope installs a handler, then collapses something: `main` above. The callee is untouched; only the calls made from that context are specialized.
- **By carving the default.** `fast -> lib{ Log -< e { -> "fast" } }` derives a copy of `lib` whose default handler for `Log` is another one. A scope is closed: the carve replaces a handler `lib` installs, it never adds one.

Both obey the same contract. The replacing handler does not have to answer with the type of the one it replaces: it has to support **everything done with its answer**.

```syntact
lib -> {
  Log -> { string:message }
  Log -< e { -> 1 }
  u16:r >- Log{message -> "x"}
  -> r + 1
}

lib{ Log -< e { -> 300 } }!   // 301: 300 is not what the default answered, but it fits u16 and + 1
lib{ Log -< e { -> "a" } }!   // error at the carve: "a" is not a u16
```

### Lifecycle

A handler lives as long as the collapse of the scope that installs it. When that scope has finished collapsing, its handlers are freed. Contexts are shared by everything called inside them, and end with them.

This is contextual specialization: an event is declared once, and each context that calls into it decides how it is served, for exactly as long as that context runs.

This is Syntact's version of algebraic effects. They are called events because they are emitted and handled, but they are not callbacks, observers, or pub/sub messages.

---

## Handlers as compile-time dependency injection

Handlers make many runtime dependency injection patterns unnecessary.

In a classical language, if code needs an allocator, logger, clock, database, random source, HTTP client, or filesystem, you often pass a value around:

```text
function(..., allocator, logger, db, clock)
```

or you hide it behind an object, interface, global, context, or DI container.

In Syntact, the code emits an event. The context of the call decides how to serve it.

```syntact
Alloc -> {
  u64:size
}

Alloc -< e {
  -> malloc{e.size}!
}

Buffer -> {
  u64:size
  ptr >- Alloc{size -> size}
  -> ptr
}
```

By default, `Buffer` allocates with malloc: that is the handler visible from where it is written.

A scope may choose an arena for everything it calls:

```syntact
WithArena -> {
  Alloc -< e {
    -> arena.alloc{e.size}!
  }

  -> Buffer{size -> 1024}!
}
```

`Buffer` does not receive an allocator. There is no allocator variable. There is only an event, served by the context of the call.

A library can also be specialized by carving the handler it installs:

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
