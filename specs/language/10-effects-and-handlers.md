# Effects and handlers

An effect is what comes from outside; an event is a question a scope asks of its
context. Both stay in the type of a program, where they are written: no law copies,
erases or reorders them (`types.md` §4.8, §4.9).

## Effects

`!?` is an effect: an input, a system call, a C function (chapter 11). What it gives
back is written like the layout of an unknown: `!?::u8` gives back a `u8`, and
`!?::none` gives nothing back. Colored, it takes the layout of its color:

```syntact
read -> {u8:r -> !?  -> r}           // read a u8 from outside
```

An effect wraps the computation that follows it: `ε(x, t)` is the effect, `x` what
it gives back, bound in `t`. What is pure crosses it, so the laws simplify everything
around an effect, never the effect itself:

```syntact
once -> {a -> read!  -> a - a}!      // ε0(x::u8, 0): a - a is gone, the read stays
twice -> read! - read!               // two runs, two answers: ε0(x, ε0(y, x - y))
```

A scope holds the effects of its bindings until it is collapsed. A production gives
its value with the effects of the bindings above it, in the order they are written,
even those it does not name:

```syntact
log -> {w -> !?::none  -> 5}!        // ε1(5): w runs, though nothing reads it
```

An effect in a branch happens only when the branch is taken. A recursion whose
equation has effects is solved to an iteration that runs them in order (chapter 08).

## Events

An event is declared like any scope; its bindings are the shape of what it carries:

```text
Log -> {string:message}
```

A **handler** is installed with `-<`. Its left side is the event, its right side
captures what is sent and gives the handler's body:

```text
Log -< e {
  -> e.message + "!"
}
```

An event is **emitted** with `>-`, a binding like `->`. The binding receives the
answer of the handler:

```text
r >- Log{message -> "hi"}     // r is "hi!"
>- Log{message -> "hi"}       // the same emission, anonymous
```

An event is its handle: the binding its name resolves to. `Log` and `Audit` with the
same shape are two events. What is sent carries no identity: it only has to fit the
shape of the event.

## Which handler answers

A handler is context, found when the program is typed, never at run time: nothing is
passed, and an emission costs what its handler costs, a carve and a collapse.

An emission is answered where the scope that holds it is collapsed: when `s!` is
written in a scope that has a handler of the event, that handler answers. Otherwise
the emission comes up with what `s!` gives, to where the scope holding `s!` is
collapsed, and so on. The program is collapsed by nothing: an emission that comes up
to it is answered by its **default**, the handler visible where it is written. An
emission without a default is an error.

```syntact
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
a -> lib!          // "default"
b -> main!         // "main": answered where lib! is collapsed
c -> {-> lib!}!    // "default": nothing answers between, it comes up to the program
```

A scope answers the emissions of the scopes it collapses, not its own. Each emission
comes up on its own, to the first scope that answers its event. A recursive call
whose equation emits is answered where it is collapsed, at each step.

Handlers are not where effects happen: a handler has effects only if its scope has
some, and an effect needs no handler.

## Specializing

A handler is replaced in two ways:

- **by the context**: a scope installs a handler, then collapses something;
- **by carving it**: `lib{Log -< e { -> "fast" }}` is a copy of `lib` whose handler
  is another one. A scope is closed: a carve replaces a handler, it never adds one.

Either way, the answer is checked where it is given, like a carve:

```syntact
lib -> {
  Log -> {string:message}
  Log -< e { -> 1 }
  u16:r >- Log{message -> "x"}
  -> r + 1
}
a -> lib!                        // 2
b -> lib{Log -< e { -> 300 }}!   // 301
c -> lib{Log -< e { -> "a" }}!   // refused: "a" is not in u16
```

## Dependencies are events

What other languages pass as a parameter or inject through a container — an
allocator, a logger, a clock, a database — is an event answered by the context:

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

`Buffer` receives no allocator: it emits, and the scope that collapses it answers.
The handler is known where the collapse is written, so the choice is made at compile
time.

---

[← Holes and genericity](09-holes.md) · [Index](README.md) · [The external boundary →](11-external-boundary.md)
