# Effects and handlers

> **Open.** Events and handlers are not written in `types.md` yet, and the kernel
> does not build them. An emission is an effect, not a value: the laws that simplify a
> type must neither erase nor reorder it. Writing what an emission is in the algebra,
> and which laws it stops, comes before the residual program and its code
> (chapter 15).

## Events

An event is declared like any scope; its bindings are the shape of what it carries:

```text
Log -> {string:message}
```

A **handler** is installed with `-<`. Its left side is a handle — a reference to the
event —, its right side captures what is sent and gives the handler's body:

```text
Log -< e {
  -> e.message + "!"
}
```

An event is **emitted** with `>-`, a binding like `->`. The emission is sent to the
handler, and the binding receives its answer:

```text
r >- Log{message -> "hi"}     // r is "hi!"
>- Log{message -> "hi"}       // the same emission, anonymous
```

A handle is a reference to a binding, resolved like any name: two events are the same
when their handles reference the same binding. `Log` and `Audit` with the same shape
are two events. What is sent carries no identity: it only has to fit the shape of the
event.

## When an emission happens

An emission happens when the scope that holds it is collapsed, whether or not anything
reads its answer: the emissions of a collapse happen in the order they are written,
each once. Handlers are the only place where effects happen — the outside is reached
inside a handler.

## Which handler answers

An emission is served by:

1. the handler installed for its handle in the **context of the call**: the scope
   that collapses, then the call that collapsed it, and so on up the calls in
   progress;
2. otherwise, the handler visible from where the emitting scope is written: its
   default.

Every emission must have a default. An emission without one is an error at compile
time, whatever handlers a caller may install. After the handler answers, execution
resumes where the event was emitted.

```text
lib -> {
  Log -> {string:message}
  Log -< e { -> "default" }
  r >- Log{message -> "x"}
  -> r
}
main -> {
  lib.Log -< e { -> "main" }
  -> lib!
}
lib!     // "default"
main!    // "main"
```

So a collapse is an effect in a context, not a value fixed once: the same `lib!` gives
two answers in two contexts.

## Specializing

A handler is replaced in two ways:

- **in the context of a call**: a scope installs a handler, then collapses something;
- **by carving the default**: `lib{Log -< e { -> "fast" }}` is a copy of `lib` whose
  handler is another one. A scope is closed: the carve replaces a handler, it never
  adds one.

Either way, the replacing handler must support everything done with its answer:

```text
lib -> {
  Log -> {string:message}
  Log -< e { -> 1 }
  u16:r >- Log{message -> "x"}
  -> r + 1
}
lib{Log -< e { -> 300 }}!    // 301
lib{Log -< e { -> "a" }}!    // error at the carve: "a" is not a u16
```

A handler lives as long as the collapse of the scope that installs it.

## Dependencies are events

What other languages pass as a parameter or inject through a container — an
allocator, a logger, a clock, a database — is an event served by the context:

```text
Alloc -> {u64:size}
Alloc -< e { -> malloc{e.size}! }

Buffer -> {
  u64:size
  ptr >- Alloc{size -> size}
  -> ptr
}

WithArena -> {
  Alloc -< e { -> arena.alloc{e.size}! }
  -> Buffer{size -> 1024}!
}
```

`Buffer` receives no allocator: it emits, and the context of the call answers. The
handler is known where the call is written, so the choice is made at compile time.

---

[← Holes and genericity](09-holes.md) · [Index](README.md) · [The external boundary →](11-external-boundary.md)
