# Syntact

> *A language where everything is a scope, nothing is a function, and execution is just reduction.*

---

## Why Syntact exists

The journey to create Syntact began with a deep sense of disappointment about the current state of programming.

We put a lot of effort into creating encapsulations, but then we end up writing a lot of code just to get around them, and it feels like there's no real purpose to them. With all the technological advancements we have, we should be able to create applications that run incredibly fast and smoothly. Instead, we're constantly dealing with frustratingly slow programs and artificial boundaries imposed by frameworks upon frameworks.

It's clear that current programming languages are inadequate, and we need to develop new ones that prioritize both expressiveness and high-order programming capabilities **without compromising performance**.

Despite incorporating genericity, most languages require excessive boilerplate for simple memory operations and fail to match C's performance while still restricting the extent of genericity. Languages that attempt zero-cost abstraction with ownership systems (Rust) end up with narrow, constrained syntax and ultra-slow compile times. Others rely on garbage collection, which incurs a hidden performance cost. None of them are honest about what programming actually *is*.

That's why Syntact is a step in a different direction — with its emphasis on flexibility, efficiency, and structural simplicity, it aims to be a more powerful tool for expressing computation without paying for it.

**At its core, Syntact is built around the idea that programming is simply the act of manipulating data.**

---

## The problem with functions

Programming languages have inherited a strange dogma from 18th-century mathematicians: that the *function* — a thing taking inputs and returning outputs — is the fundamental unit of computation. Every modern language is some variation of this assumption. We have free functions, methods, lambdas, closures, monadic bindings, async functions, generator functions, async generator functions… an entire phylogenetic tree of accidental complexity built on top of one borrowed idea.

But look at what a processor actually does. There are no functions in assembly. There are blocks of instructions, jumps, and data. The "function" is a calling convention — a social contract bolted on top of a stack pointer. It is not the essence of programming; it is an artifact of how mathematicians wanted to talk about computation two hundred years ago.

Syntact takes the opposite stance: **the function does not exist**. What does exist is the *scope* — a structured collection of named potentialities — and a small set of operators for binding scopes together and reducing them to values. Everything that functions traditionally do (and a great deal that they cannot) emerges naturally from this single primitive.

---

## The one and only primitive: the scope

A scope is a collection of bindings, written between braces:

```syntact
{
  u8:r
  u8:g
  u8:b
  u8:a -> 255
}
```

That's it. That is the entire structural vocabulary of the language.

But every kind of construct you've ever encountered in a programming language is *also* a scope:

- A **type** is a scope (`Color`, `User`, `Shape`).
- A **value** is a scope (`{255 0 128 255}`).
- A **module** is a scope.
- A **file** is a scope. Its top-level bindings are its contents.
- A **directory** is a scope. Its bindings are the files and subdirectories it contains.
- An **event** is a scope.
- A **pattern** is a scope.
- Even **primitive types** are scopes — `u8` is the scope containing all valid `u8` values, with `0` as its default.

This is not metaphor. It's the actual data structure the compiler manipulates. Because everything shares the same shape, the language is **homoiconic** (code is data, trivially) and **isomorphic** across every level — you operate on a struct literal exactly the way you operate on a directory tree.

---

## Bindings: how scopes connect

A program is built by *binding* scopes together. Syntact has six fundamental binding arrows, organized as three symmetric push/pull pairs:

| Pair | Push | Pull | Meaning |
|------|------|------|---------|
| **Pointing** | `->` | `<-` | Definition / data flow |
| **Event** | `>-` | `-<` | Emit / handle effects |
| **Resonance** | `>>-` | `-<<` | Drive / push reactive value |

Plus a few derived forms (`=<<`, `>>=` for reference-based resonance; `...` for inline expansion). That's the whole list. From these, the entire language is built.

### Pointing — the everyday arrow

`->` declares a binding. To the left, what you're naming; to the right, what it points to.

```syntact
greeting -> "hello"
answer   -> 42
double   -> { u8:n, -> n * 2 }
```

The pull form `<-` declares a binding that *cannot be directly overridden* — its value is decided later, by whoever uses it. This is how generics work, with no separate generic system:

```syntact
List -> {
  T <- None      // T is a hole — filled at use site
  -> {}
  -> { T:, ...List{T}: }
}

List{u8}:numbers     // T resolves to u8 here
List{String}:names   // and to String here
```

No `<T>`, no `Generic[T]`, no template metaprogramming dialect. Just the same arrow, pointed the other way.

### Events — algebraic effects, structurally

`>-` emits an effect. `-<` handles it.

```syntact
Log -> { String:message }

debugPrint -> {
  String:message
  >- Log{message->message}    // emit
}

main -> {
  Log -< e {                  // handle
    -> io.write{e.message}!
  }
  debugPrint{message->"hi"}!
}
```

The handler doesn't have to live near the emitter. The compiler statically proves that every emitted effect has a handler in scope at the point of collapse. The same `debugPrint` can be interpreted as real I/O, as a mock, as a replay log, or as a compile-time evaluation — depending entirely on which handlers are installed at the call site. Effects are never magic; they are just bindings.

### Resonance — reactivity without a framework

`>>-` says "this value is *driven* by that event." `-<<` pushes a new value into a resonant binding. There is no `useState`, no `Observable`, no `signal()` — just two arrows.

```syntact
Counter -> {
  Change -> { u8:value }
  -> {
    u8:value >>- Change -> 0      // value is driven by Change, default 0
    Change -< e {
      value -<< e.value           // push the new value
    }
    increment -> { >- Change{value+1} }
    decrement -> { >- Change{value-1} }
    -> value
  }
}
```

That's a complete reactive counter. No subscriptions to manage, no lifecycle, no diff. The same primitives also drive a UI, a piece of state, an animation, or a database row.

---

## Immutability and default values

**Everything in Syntact is immutable by default.** No binding can be reassigned. The "mutation" you see in `Counter` is not assignment — it is a new value produced in response to an event, via resonance. Mutation is not a primitive; it is a *pattern* you opt into.

**Every scope always has a value.** This is one of the language's quiet superpowers. There is no `null`, no "uninitialized," no `undefined`, no surprise zero-value. A scope's default is simply its *first declared potentiality*. For `u8`, that is `0`. For your own `Color`, it's `{0 0 0 255}`. For an `Option`-like type, it's whichever variant you list first.

```syntact
Color -> {
  -> { u8:r, u8:g, u8:b, u8:a -> 255 }
}

Color:c        // c is { r:0 g:0 b:0 a:255 } — automatically
```

This makes types **total** — every value of every type is constructible without ceremony — and gives the language a clean story about initialization that doesn't require constructors, factory methods, or `Default` traits.

---

## Types as enumerated potentiality

Because a type is just a scope, and a scope is a set of named potentialities, **a type is literally the set of values it can hold**. `u8` is the scope containing all 256 valid `u8` values; `Shape` is the scope of all shapes; `Color` is the scope of all colors. Pattern matching, refinement, and "type checking" are therefore the same operation: *constraining a scope to a sub-scope*.

The shape operator `:` enforces that a value collapses into a given scope:

```syntact
u8:age -> 30           // age is constrained to the u8 scope
Color:bg               // bg defaults to the first Color potentiality
```

Refinement extends this to arbitrary subsets:

```syntact
Adult -> ?User:{ age ?>= 18 }     // refinement type
even  -> %2 = 0                   // a predicate scope
```

Set operators compose types directly: `&` (intersection), `|` (union), `~` (complement). There is no separate "type algebra" — it's just scope arithmetic.

```syntact
NStar -> N ~ {}              // natural numbers minus zero
NumOrText -> u8 | String     // sum type, no enum keyword
```

---

## "Functions," redefined

Since there are no functions, what does a callable look like? A scope that produces a value:

```syntact
square -> {
  u8:n
  -> n * n
}
```

You "call" it by *overriding* its inputs and *collapsing* it:

```syntact
square{n->5}!     // override n to 5, collapse, get 25
```

Override (`{...}`) and collapse (`!`) are independent primitives. They compose. You can override without collapsing (partial application, for free):

```syntact
squareOf7 -> square{n->7}      // a scope, not yet collapsed
squareOf7!                      // 49, when you want it
```

You can pass a scope as a value (no special "function pointer"):

```syntact
map{ list->{1 2 3}, mapper->square }!
```

You can override the *body* of a callable, not just its inputs (override is structural, not positional):

```syntact
doubleIt -> square{n -> n + n}    // changes what square computes
```

You can derive new behaviors by composing scopes:

```syntact
transform -> {
  maybe{Shape}:shape
  transformer -> { maybe{Shape}:shape, -> shape }
  -> transformer{shape->shape}!
}

doubleV2 -> transform{transformer->double}    // same runtime cost as double
```

There is no calling convention, no closure capture rule, no method-vs-function distinction, no curry-vs-partial-application debate. There is one operation — override-and-collapse — and it does all of it.

---

## Collapse and how you get it done

`!` reduces a scope to its produced value. The wrappers around `!` say *where* and *how*:

```syntact
work!         // sequential
work<!>       // on another thread (locks/atomics handled for you)
work[!]       // parallel CPU (must be pure)
work(!)       // background — returns a re-collapsable handle
work|!|       // GPU (must be pure)
work([!])     // parallel CPU in background
work(|!|)     // GPU in background
```

These compose. `<[!]>` is "parallel CPU, on another thread." `(<[!]>)` is "the same, in background." Concurrency is a property of the *collapse*, not of the code being collapsed. The same scope can be run sequentially, on the GPU, or in a background thread pool, with no rewriting.

---

## Pattern matching: collapse along a potentiality

`?` matches a value against the potentialities of a scope:

```syntact
shape ? {
  Circle: -> shape{radius -> radius * 2}
  Square: -> shape{side -> side * 2}
  -> shape
}
```

Because types *are* their potentialities, the same operator handles structural destructuring, sum-type dispatch, refinement matching, and value comparison — they were never different things to begin with.

```syntact
n ? {
  0 -> "zero"
  >0 -> "positive"
  -> "negative"
}
```

---

## Compile-time is just collapse without effects

Pure reduction is the same operation at compile time and at run time. So the compiler does as much of it as it possibly can, ahead of time. A program with no effects literally compiles to a constant — there is nothing left to run.

Effects can be *lifted* to compile time explicitly:

```syntact
httpCompileTime -> !{@http}
configText -> httpCompileTime.get{"https://api.example.com/config"}!

result -> configText ? {
  "PRODUCTION"  -> "Production mode"
  "DEVELOPMENT" -> "Development mode"
  -> "Unknown mode"
}
```

The HTTP request happens during compilation. The result is baked into the binary. The pattern match collapses to a constant. There is no macro system because there does not need to be one — the language is its own metalanguage.

---

## Proofs: the same machinery, used for guarantees

`??` declares a symbolic unknown — a universally quantified value. `?!` enforces a property. Together, they let you write theorems the compiler must prove:

```syntact
incrementAlwaysIncreases -> {
  u8:prev -> ??
  Counter:count{value -> prev}
  count.increment!
  -> count! = prev + 1
}

addCommutative -> {
  Nat:a -> ??
  Nat:b -> ??
  -> add{a b}! = add{b a}! ?! true
}
```

The compiler reduces both sides symbolically and verifies the equality holds for *every* `prev`, every `a`, every `b`. Refusing to compile is the failure mode.

This isn't a separate proof assistant bolted on. It's the same reducer used for everything else, asked to prove an equality instead of compute a value.

---

## Files and folders are scopes too

```syntact
Plane2D -> @lib.geometry.Plane

// Expand a modified version of an entire directory into the current scope
...@lib.geometry{Plane -> Plane{dimension -> 3}}
```

`@` resolves the filesystem as a scope. `lib` is a folder-scope; `geometry` is a file-scope inside it; `Plane` is a binding inside that. The dot is the same property access you use on any other scope. Override and expansion work on directories the same way they work on struct literals.

There is no import system. There is no module system. There is one filesystem-backed scope graph, and the same five operators that work on everything else work on it too.

---

## How execution actually works

> **Running a program means collapsing the scope of a file.**

That's the entire execution model. There is no main loop, no runtime, no special entry function. The compiler takes a file, finds its produced value (`-> ...`), and reduces it.

```syntact
// some_file.syn
greeting -> "hello"
-> 0
```

This program returns `0`. With no effects in the chain, it compiles to a constant `return 0` — the binary literally does nothing else.

```syntact
// app.syn
main -> {
  Log -< e { -> io.write{e.message}! }
  >- Log{"hello"}
  -> 0
}

-> main!
```

This program *also* returns `0`. But to get there, the collapse of `main` traverses an effect emission, which forces the compiled binary to perform the I/O before returning. The compiler statically guarantees that every effect emitted along the way has a handler installed at the point of collapse. If it doesn't, the program does not compile. There is no exception handler, no runtime panic, no "effect not found" error at run time — the failure mode is a compile error, always.

The name `main` is a convention. You could call it `start`, `program`, `do_thing` — what matters is that the file ends with `-> something!`, and that "something" is what the program does.

---

## The shape of a real program

```syntact
Counter -> {
  Change -> { u8:value }
  -> {
    u8:value >>- Change -> 0
    Change -< e { value -<< e.value }
    increment -> { >- Change{value + 1} }
    decrement -> { >- Change{value - 1} }
    -> value
  }
}

Logging -> {
  Log -> { String:message }
  Log -< e { -> io.write{e.message}! }
}

main -> {
  ...Logging
  Counter:counter
  >- Log{counter!}    // 0
  counter.increment!
  >- Log{counter!}    // 1
  counter.decrement!
  >- Log{counter!}    // 0
}

-> main!
```

A reactive counter, an effect handler module, and a program that uses both — in twenty lines, with no framework, no class system, no async runtime, no observer pattern, no dependency injection, no import statement.

---

## What you give up, and what you get

Syntact gives up:

- The function as a primitive.
- Mutation as a primitive.
- The distinction between value, type, module, file, and effect.
- The distinction between compile time and run time.
- Separate systems for generics, traits, macros, modules, effects, reactivity, and proofs.

In exchange, you get:

- One structural primitive (scope) and six binding arrows.
- Everything is total. Everything has a default. Nothing is null.
- Generics, sum types, refinement types, pattern matching, dependent types, and proofs — all from the same operators.
- Algebraic effects with statically-proven handlers — no runtime cost beyond the I/O itself.
- Reactivity without a framework.
- Compile-time evaluation without a macro system.
- Composable concurrency wrappers (sequential, threaded, parallel, GPU, background) that don't require the code itself to know how it will run.
- A program that, in the absence of effects, compiles to a constant.

---

## Status

Syntact is in active development. The current bootstrap compiler is written in Odin and lives in `compiler/`; it parses, analyzes, and is in the process of regaining its x64 backend. An LSP is available in `lsp/`. A declarative test suite lives in `test/`.

The eventual goal is a self-hosted compiler written in Syntact itself — at which point the bootstrap can retire, and the language can begin proving things about its own implementation.

---

*Syntact is the language I wished existed. If, after reading this, you wish it existed too — you're in the right place.*
