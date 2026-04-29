# Syntact

> *A language where everything is a scope, nothing is a function, and execution is just reduction.*

---

Syntact is an experimental general-purpose programming language built on a single radical idea: **the function is an 18th-century idea, and we don't need it.**

In its place, Syntact has *scopes* — structured collections of named things — and a small set of arrows for binding scopes together. From those primitives, everything emerges: types, generics, modules, pattern matching, algebraic effects, reactivity, even compile-time-verified proofs. There is no class system, no trait system, no macro system, no async runtime. There is one structural primitive, and a handful of operators.

A complete program looks like this:

```dart
Counter -> {
  Change -> { u8:value }
  -> {
    u8:value >>- Change -> 0
    Change -< e { value -<< e.value }
    increment -> { >- Change{value + 1} }
    -> value
  }
}

program -> {
  Log -> { String:message }
  Log -< e { -> io.write{e.message}! }

  Counter:counter
  >- Log{counter!}        // "0"
  counter.increment!
  >- Log{counter!}        // "1"
  -> 0
}

-> program!
```

That's a reactive counter, an effect handler, and a program that uses both — in fifteen lines, with no framework, no class, no observer pattern, no subscription, no `useState`, no import statement. The compiler reduces everything it can ahead of time, statically proves that every effect has a handler, and produces a binary with zero abstraction overhead.

The performance ambition is unusual: Syntact aims to be **faster than traditional compiled languages**, because it has no abstraction barriers for the optimizer to fight against. The collapse operator `!` is, fundamentally, an optimization mechanism. You write at the level of high abstractions, and you pay the cost of the underlying assembly — nothing more.

The rest of this document walks through the language one operator at a time. By the end, you'll be able to read every snippet above without translation.

---

## Contents

**Motivation**
- [Why Syntact exists](#why-syntact-exists)
- [The problem with functions](#the-problem-with-functions)
- [The Syntact trinity: scope, binding, collapse](#the-syntact-trinity-scope-binding-collapse)

**The basics**
- [Your first program](#your-first-program)
- [Bindings: pointing with `->`](#bindings-pointing-with--)
- [Scopes: the only structure there is](#scopes-the-only-structure-there-is)
- [Collapse: turning a scope into a value with `!`](#collapse-turning-a-scope-into-a-value-with-)
- [Override: producing new scopes from old ones](#override-producing-new-scopes-from-old-ones)
- [Putting it together: callables without functions](#putting-it-together-callables-without-functions)

**Values, types, and matching**
- [Default values, immutability, and totality](#default-values-immutability-and-totality)
- [Primitive types: scopes of all their values](#primitive-types-scopes-of-all-their-values)
- [The shape operator `:`](#the-shape-operator-)
- [You don't have to use `:`](#you-dont-have-to-use-)
- [Pattern matching with `?`](#pattern-matching-with-)

**Building real programs**
- [Pull bindings: holes filled later with `<-`](#pull-bindings-holes-filled-later-with--)
- [Building a list, step by step](#building-a-list-step-by-step)
- [Effects: `>-` and `-<`](#effects---and--)
- [Resonance: reactivity with `>>-` and `-<<`](#resonance-reactivity-with----and--)
- [Files and folders are scopes](#files-and-folders-are-scopes)

**Beyond runtime**
- [Compile-time is just collapse without effects](#compile-time-is-just-collapse-without-effects)
- [Proofs with `??` and `?!`](#proofs-with--and-)
- [Concurrency: choosing how to collapse](#concurrency-choosing-how-to-collapse)

**Closing**
- [Why this is fast](#why-this-is-fast)
- [How a program runs](#how-a-program-runs)
- [A complete example](#a-complete-example)
- [What you give up, and what you get](#what-you-give-up-and-what-you-get)
- [Status](#status)

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

Programming languages have inherited a strange dogma from 18th-century mathematicians: that the *function* — a thing taking inputs and returning outputs — is the fundamental unit of computation. Every modern language is some variation of this assumption. We have free functions, methods, lambdas, closures, monadic bindings, async functions, generator functions, async generator functions… an entire phylogenetic tree of accidental complexity built on one borrowed idea.

But look at what a processor actually does. There are no functions in assembly. There are blocks of instructions, jumps, and data. The "function" is a calling convention — a social contract bolted onto a stack pointer. It is not the essence of programming; it is an artifact of how mathematicians wanted to talk about computation two hundred years ago.

Syntact takes the opposite stance: **the function does not exist**. What does exist is the *scope* — a structured collection of named potentialities — and a small set of operators for binding scopes together and reducing them to values. Everything that functions traditionally do (and a great deal that they cannot) emerges naturally from this single primitive.

This isn't a stunt. It's the door to something practical: an optimization model where high-level abstractions cost exactly nothing, because there is no abstraction barrier to optimize across.

---

## The Syntact trinity: scope, binding, collapse

Syntact rests on three fundamental units. Together they form the entire conceptual surface of the language. Everything else is built from how they combine.

### 1. The scope — the object that was always there

Every programming language has a notion of *scope*. C has scopes. Python has scopes. Rust has scopes. JavaScript has scopes. They are the bracketed regions inside which names are visible. They are universal — and yet, somehow, no language treats them as a *first-class object*. They are a side-effect of declaring a function, a class, a block, a module. They exist, but you can't pick one up and pass it around.

This is strange, because the scope is the truly fundamental object: a structured collection of named things. A class is a scope (with mutable fields). A module is a scope (with exports). A function body is a scope (with local variables). A struct literal is a scope. A namespace is a scope. Languages keep reinventing this concept under different names with different rules, instead of admitting that it's the same thing each time.

Syntact takes the obvious step: scopes are the only structure. They're first-class. You can name them, store them, pass them around, modify them, reduce them. There is one syntax for them — `{ ... }` — and it works at every level.

### 2. The binding — generalized assignment

The second fundamental unit is the **binding**. This is also something every language has, but in a degraded form: most languages took the `=` sign from algebra and turned it into a single overloaded operator called *assignment*. Then they noticed that you also need other ways of "putting names in front of values" — declaring a class, defining a function, exporting from a module, importing into one, subscribing to an event, deriving a trait — and instead of recognizing these as *different kinds of binding*, languages bolted on ad-hoc keywords for each one. `class`, `def`, `import`, `export`, `let`, `const`, `var`, `extends`, `implements`, `subscribe`, `bind`, `provide`, `inject`. A new keyword every time someone realized there was yet another way to associate a name with a thing.

The result is the boilerplate and the libraries-in-every-direction we all live with. There are no fundamental abstractions, only ad-hoc patches.

Syntact recognizes that "assignment" was always too narrow a word for what was happening. It generalizes the operation into the **binding**, and admits that there are several genuinely distinct ways to bind things — so it gives them distinct symbols:

- `->` push pointing — the standard "this is that"
- `<-` pull pointing — "this is a hole, fill it from where I'm used"
- `>-` push event — "emit this"
- `-<` pull event — "handle this when it happens"
- `>>-` push resonance — "this value is driven by that event"
- `-<<` pull resonance — "push this new value into the resonant binding"

Six arrows. They cover everything other languages do with dozens of keywords and entire framework ecosystems — because they correctly carve up what *binding* actually is.

### 3. The collapse — execution as a separate operation

This is the unit that makes Syntact different from every other language.

In traditional languages, **execution is the default**. Write an expression, it runs. Write a statement, it runs. Write a function call, it runs immediately, no questions asked. To *stop* execution from happening — to delay it, capture it, pass it around, run it differently — you have to reach for a workaround: a closure, a thunk, a lambda, a `Promise`, a `Future`, a `Lazy<T>`, a coroutine, reflection, an AST library. The default forces you to fight the language whenever you want to think about computation as data.

Syntact says no. **Execution is a separate operation, orthogonal to scope and orthogonal to binding.** It has its own symbol: `!`, the **collapse**. Without `!`, nothing runs. A scope is a description; a binding associates names with descriptions; collapse is the act of reducing a description to a value.

This sounds like a small thing. It is not. It means:

- You can pass any computation around as data, without ceremony.
- You can override the *body* of a computation before it runs.
- The compiler can reduce as much as it wants ahead of time, because reduction is an explicit operator and not a side-effect of merely existing.
- Concurrency is a property of *how* you collapse (`!`, `<!>`, `[!]`, `(!)`, `|!|`), not of what you wrote.
- Compile-time evaluation is just collapse done early. There's no separate macro language.

The trinity — **scope, binding, collapse** — is everything fundamental. Three concepts. That's the entire conceptual budget of the language.

### What you do with the trinity

Three concepts get you very far, but you'd have to rewrite a lot if you couldn't *modify* what you have. So Syntact adds the **override** — the `{...}` syntax that produces a new scope from an old one, with some bindings replaced. Override is what lets you reuse and compose: it's the operation that derives a new piece of data from an existing one, the same way a class derives from a parent or a function instantiates a generic — but uniformly, structurally, with one syntax.

A few more operators round out the language: `:` constrains a binding to a sub-scope, `?` matches against a scope's potentialities, `...` expands one scope into another, `??` and `?!` carve out a corner for compile-time proofs. None of them introduce new fundamental concepts — they're all expressed in terms of scope, binding, and collapse.

### Why this gives you optimization for free

Syntact is a modern language, and it cares about isolation, immutability, and effect tracking. In Syntact, **mutability itself is an effect** — there is no in-place modification, only resonance against events, which is structurally explicit. Effects are isolated by construction (every emit `>-` must reach a handler `-<` that the compiler can see).

Once effects are isolated, the reduction of a program becomes obvious: everything that isn't an effect can be reduced ahead of time. The shape of the code *is* the shape of the reduction. There is nothing for an optimizer to discover, because there is nothing hidden.

This is why Syntact is hard to outperform with traditional optimization techniques: the language design itself is an optimization engine. The compiler isn't "trying to figure out" what your code means and how to fold it into machine instructions — your code is already structured as a reduction, and the compiler simply runs it as far as it can.

The rest of this README walks through scope, binding, and collapse one at a time — and then through the small set of derived operators that build the rest.

---

## Your first program

Here is a complete Syntact program:

```dart
-> 0
```

That's it. The arrow `->` says "produce." The file produces the value `0`. Compiling this and running it returns `0`. There is no `main`, no entry point, no boilerplate — the file *is* the program, and a program is something that produces a value.

A slightly less trivial one:

```dart
greeting -> "hello"
answer   -> 42
-> answer
```

This program produces `42`. The binding `greeting` is computed but ignored, because nothing depends on it — and since Syntact reduces statically, the unused work is simply never emitted in the binary. To make that concrete, here is the entire x86-64 program the compiler produces for the snippet above:

```asm
_start:
    mov     edi, 42         ; exit code = 42
    mov     eax, 60         ; syscall: exit
    syscall
```

That's the whole binary. No string `"hello"` appears anywhere — it was reduced away at compile time, along with the binding that held it. Two syscalls' worth of instructions, because that's all the program actually does.

That second program contains the language's two most important ideas already: **bindings** (`greeting -> "hello"`) and **production** (`-> answer`). Everything else is built from these.

---

## Bindings: pointing with `->`

The `->` operator is a *pointing*. To the left, a name; to the right, what it points to.

```dart
name -> "Alice"
age  -> 30
pi   -> 3.14159
```

Bindings are read **top-down**: a binding can only see what was declared above it in the same scope (or in enclosing scopes). There is no hoisting, no forward reference. This makes the order of code on the page also the order of evaluation in the compiler's mind, which makes everything easier to reason about.

A binding without a left-hand name is a *production* — it tells the enclosing scope what to produce when reduced:

```dart
greeting -> "hello"
-> greeting        // this scope produces "hello"
```

A scope can have several productions; they are alternative potentialities, and the first one is the default. (We'll come back to this when we talk about types.)

---

## Scopes: the only structure there is

A scope is a collection of bindings between braces:

```dart
point -> {
  x -> 10
  y -> 20
}
```

`point` is now a scope with two bindings. You access them with `.`:

```dart
point.x        // 10
point.y        // 20
```

Scopes nest:

```dart
user -> {
  name -> "Alice"
  address -> {
    city -> "Lyon"
    zip  -> 69000
  }
}

user.address.city     // "Lyon"
```

A file is itself a scope. So is a directory. So is a primitive type. So is an event. So is a pattern. Everything you encounter in Syntact is a scope of some kind, which is what makes the language *homoiconic* (code and data have the same shape) and *uniform* (one set of operators works on everything).

---

## Collapse: turning a scope into a value with `!`

A scope by itself is a description, not a value. To get the value it represents, you **collapse** it with `!`:

```dart
two -> {
  a -> 1
  b -> 1
  -> a + b
}

two!     // 2
```

Without the `!`, `two` is just a scope — a recipe. With `!`, it is reduced to its produced value.

This split is the engine of Syntact. **Computation never happens by accident.** A scope can be passed around, stored, overridden, inspected, or examined symbolically without ever being executed. It runs only when you say so.

The `!` has variants that say *how* the collapse should happen:

```dart
work!         // sequential, right here
work<!>       // on another thread (locks/atomics handled for you)
work[!]       // parallel CPU (the work must be pure)
work(!)       // background — returns a re-collapsable handle
work|!|       // GPU (the work must be pure)
work([!])     // parallel CPU, in background
work(|!|)     // GPU, in background
```

The wrappers compose freely: `<[!]>` is "parallel CPU, on another thread." `(<[!]>)` wraps that in a background handle. The same scope `work` can be collapsed sequentially, on the GPU, or in a background thread pool — without rewriting it. Concurrency is a property of the *collapse*, not of the code.

A background collapse `work(!)` produces a handle. You collapse that handle later (`handle!`) to wait for the result. There is no separate `Future`, `Promise`, or `async/await` machinery — just `(!)` and `!`.

---

## Override: producing new scopes from old ones

Once you have a scope, you can produce a *new* scope based on it by overriding some of its bindings. The override syntax is `{...}` directly after the scope:

```dart
point -> {
  x -> 0
  y -> 0
}

origin    -> point             // {x:0 y:0}
shifted   -> point{x->5}       // {x:5 y:0}
diagonal  -> point{x->5 y->5}  // {x:5 y:5}
```

`point` itself is unchanged. Override produces a new scope — Syntact is **immutable by default**. There is no assignment operator, anywhere, ever. The only way to "change" anything is to produce a new scope from an old one.

Overrides can also *add* bindings, replace whole sub-scopes, or change what the scope produces. They are structural, not positional, so you don't care about the order things were declared in.

---

## Putting it together: callables without functions

Override and collapse, used together, are how Syntact does what other languages call "calling a function."

```dart
square -> {
  n -> 0
  -> n * n
}

square!              // 0   (uses the default n -> 0)
square{n->5}!        // 25
square{n->10}!       // 100
```

`square` is just a scope. `square{n->5}` is the same scope with `n` overridden — still a scope, not yet computed. `square{n->5}!` collapses it to `25`.

This is general enough that it replaces every callable-related concept other languages have:

- **Default arguments**: just give the binding a value (`n -> 0`).
- **Partial application**: override some bindings now, others later. `squareOf7 -> square{n->7}` — this is a scope, callable later.
- **Higher-order callables**: a scope is a value, so you pass scopes around like any other data.
- **Methods**: bindings inside a scope are accessed with `.`. There is no method-vs-function distinction.

Crucially, you can override *any* binding, not just the input-looking ones. You can override what the scope produces:

```dart
square{-> 99}!    // ignores n, produces 99
```

Or override the body to compute differently:

```dart
double -> square{-> n + n}      // same n, different body
double{n->5}!                    // 10
```

A "function" in Syntact is just *override + collapse*, in either order. There is no function declaration, no function type, no calling convention — and consequently nothing for an optimizer to lose information across.

---

## Default values, immutability, and totality

Two properties make Syntact code unusually safe:

**Every scope always has a value.** There is no `null`, no "uninitialized," no `undefined`. A scope's value, when no override is applied, is its first declared potentiality.

```dart
Color -> {
  -> { r -> 0, g -> 0, b -> 0, a -> 255 }
}

Color:bg     // automatically {r:0 g:0 b:0 a:255}
```

**Bindings are immutable.** Once you write `name -> "Alice"`, `name` *is* `"Alice"` for the rest of that scope. To get a different value, you produce a new scope (with override) or you reach for *resonance* (covered later) — which is itself just a structured way of producing new scopes in response to events.

The benefit is that the compiler can reason about every value statically. There are no mutable aliases to worry about, no surprise `null` deref, no "did this get initialized yet" question. Programs are *total* by construction.

---

## Primitive types: scopes of all their values

This is where Syntact starts looking unlike other languages. The primitive types — `u8`, `i32`, `f64`, `bool`, `String`, etc. — are not built-in keywords with special status. They are **scopes**, and their bindings are *all the values they can hold*.

`u8` is the scope of all 256 valid `u8` values, with `0` as its first (and therefore default) potentiality. `bool` is a scope with two potentialities: `false` and `true`, defaulting to `false`. `String` is the scope of all strings, defaulting to `""`.

Because they are just scopes, you write them with the same syntax as anything else:

```dart
counter -> 0           // a u8, defaulting to 0
flag    -> true        // a bool
name    -> "Alice"     // a String
```

The compiler infers the most specific type from the value you wrote. You can also be explicit (next section).

---

## The shape operator `:`

`:` constrains a binding to a particular *shape* — a particular scope. Read `u8:age` as "age, shaped like a u8."

```dart
u8:age          // age is a u8, defaulting to 0
String:name     // name is a String, defaulting to ""
Color:bg        // bg is a Color, defaulting to its first potentiality
```

Because every scope has a default, `u8:age` already gives `age` a meaningful value (`0`). You can override it the usual way:

```dart
u8:age -> 30
```

This is what other languages would call a "type annotation," but it isn't a separate annotation system — it's just an operator that constrains a binding to a sub-scope.

It works for any scope, not just primitives:

```dart
Point -> {
  u8:x
  u8:y
}

Point:p              // p is {x:0 y:0}
Point:p2 -> {x->5}   // p2 is {x:5 y:0}
```

Combine `:` with the override syntax to constrain *and* override at once:

```dart
Point:origin{x->10 y->20}
```

---

## You don't have to use `:`

Here is something important that often surprises newcomers: **you can write entire Syntact programs without ever using `:`**. The shape operator is a tool for when you want the compiler to enforce a constraint. But pointing and override alone — `->` and `{...}` — are enough to write working programs.

```dart
greeting -> "hello"
person -> {
  name -> "Alice"
  age -> 30
}
older -> person{age -> 31}
-> older.name
```

That's a complete program. No `:`, no type annotations, no boilerplate. The compiler infers everything it needs from the values you wrote.

Use `:` when you want to:
- Document an intent ("this binding holds a `u8`").
- Refine a value into a sub-scope ("this binding must satisfy `Adult`").
- Make the compiler verify a structural property at the boundary.

Otherwise, leave it out. Syntact is meant to feel light when you want it light.

---

## Pattern matching with `?`

`?` matches a value against the potentialities of a scope, or against literal patterns:

```dart
n ? {
  0 -> "zero"
  1 -> "one"
  -> "many"
}
```

The last branch (no left-hand pattern) is the default. Branches are tried top-down.

You can match on shape:

```dart
shape ? {
  Circle: -> "round"
  Square: -> "square"
  -> "unknown"
}
```

You can match on refinements (sub-scopes):

```dart
n ? {
  0  -> "zero"
  >0 -> "positive"
  -> "negative"
}
```

You can destructure:

```dart
point ? {
  {x -> 0, y -> 0} -> "origin"
  {x -> (x)} -> "x is " + x
}
```

Because *types are their potentialities* in Syntact, `?` doesn't distinguish between "matching a sum type" and "matching a value" and "checking a refinement" — all three are the same operation: constrain a value to a sub-scope and pick the matching branch.

---

## Pull bindings: holes filled later with `<-`

`->` is *push*: the value flows from right to left. `<-` is *pull*: the binding declares a hole that will be filled by *whoever uses this scope*. This is how Syntact does generics — without a separate generic system.

```dart
identity -> {
  T <- None        // T is a hole, filled at the use site
  T:value
  -> value
}

identity{T->u8 value->5}!       // 5, with T resolved to u8
identity{T->String value->"hi"}!  // "hi", with T resolved to String
```

The pull arrow tells the compiler: "this binding is not the place to fix `T` — wait until someone uses this scope, and let *their* override decide." This is what makes a scope *parametrically polymorphic* without any `<T>` syntax or template machinery.

In practice you'll see `<-` everywhere generics would appear in another language: in containers, in mappers, in algebraic structures.

---

## Building a list, step by step

Let's build a `List` type from scratch, slowly, to see how the pieces fit.

A list is either empty, or it is one element followed by another list. In Syntact, we say that by giving the scope two productions — two potentialities for what a `List` can be:

```dart
List -> {
  T <- None              // element type, filled at use site
  -> {}                  // potentiality 1: empty list
  -> { T:, ...List{T}: } // potentiality 2: an element, then another list
}
```

Three things are happening here:

1. `T <- None` declares the element type as a hole. It defaults to `None` (a built-in empty scope), and is filled by whoever uses `List`.
2. `-> {}` says "one of the things a `List` can be is the empty scope." This is the first potentiality, and therefore the default.
3. `-> { T:, ...List{T}: }` says "another thing a `List` can be is a scope containing a `T` followed by the contents of another `List{T}`." `T:` is a binding shaped like `T`, anonymous. `...` *expands* the contents of another scope into this one. So the second potentiality is "one element, then everything that's in another list."

To use it:

```dart
List{T->u8}:numbers              // an empty u8 list (the default)
List{T->u8}:numbers -> {1 2 3}   // a u8 list with three elements
```

Because `...` flattens, you don't need to write `{1 {2 {3 {}}}}` — `{1 2 3}` *is* the nested form, written flatly. The two are the same data.

A `map` over a list:

```dart
map -> {
  S <- None
  R <- None
  List{S}:list
  mapper -> {
    S:(e)        // takes an S, captured as e
    -> R:        // produces an R
  }
  -> list ? {
    {} -> {}                                       // empty list maps to empty list
    {S:(e) ...List{S}:(rest)} ->                   // first element + the rest
      {mapper{e}! ...map{list->rest mapper}!}
  }
}
```

Read the body slowly:
- The pattern `{}` matches the empty list — produce the empty list.
- The pattern `{S:(e) ...List{S}:(rest)}` matches a non-empty list, capturing the head as `e` and the tail as `rest`.
- The result is `{mapper{e}! ...map{list->rest mapper}!}` — apply `mapper` to `e`, then expand the recursive map of the tail.

You now have a fully generic `map`, written using only the operators we've seen so far. There was no class, no interface, no `Functor`, no template, no `<T>`. Just scopes, bindings, override, collapse, expansion, and pattern match.

---

## Effects: `>-` and `-<`

So far everything has been pure. Real programs need to talk to the world — to print things, to read files, to make HTTP calls. Syntact handles this through **algebraic effects**, with two arrows: `>-` to emit, `-<` to handle.

An effect is just a scope (of course). You declare it like any other:

```dart
Log -> {
  String:message
}
```

To emit a `Log` effect, use `>-`:

```dart
debugPrint -> {
  String:message
  >- Log{message}
}
```

To handle it, use `-<`. The handler captures the emitted scope (here as `e`):

```dart
Log -< e {
  -> io.write{e.message}!
}
```

The trick is that *the handler doesn't need to be near the emitter*. You install handlers wherever you want the effects to take meaning — typically near the top of your program:

```dart
program -> {
  Log -< e { -> io.write{e.message}! }    // install handler
  debugPrint{message->"hello"}!            // emit propagates up to handler
}

-> program!
```

The compiler **statically proves** that every emitted effect has a handler in scope at the point of collapse. If it doesn't, the program does not compile. There is no exception, no runtime error, no "effect not handled" surprise — only compile errors.

This is enormously powerful. The same `debugPrint` can be:
- Real I/O (handler writes to stdout).
- A unit test (handler captures the messages into a list).
- A replay log (handler timestamps and stores them).
- A compile-time evaluation (handler runs at compile time, see later).

The code you wrote doesn't change. Only the handler does.

---

## Resonance: reactivity with `>>-` and `-<<`

Sometimes a value isn't a single computation — it changes over time in response to events. Syntact handles this with **resonance**, written `>>-` ("driven by") and `-<<` ("push to").

A counter:

```dart
Counter -> {
  Change -> { u8:value }       // the event that changes the counter
  -> {
    u8:value >>- Change -> 0   // value is driven by Change, defaults to 0
    Change -< e {              // when Change fires...
      value -<< e.value        // ...push the new value into `value`
    }
    increment -> { >- Change{value+1} }
    decrement -> { >- Change{value-1} }
    -> value
  }
}
```

Read this carefully:
- `value >>- Change -> 0` says "`value` is a `u8` driven by the `Change` event, with initial value `0`."
- `Change -< e { value -<< e.value }` is the handler — when `Change` fires, push the new value into `value`.
- `increment` emits `Change{value+1}`, which causes `value` to update.

There's no framework here. No subscriptions. No diffing. No lifecycle. Just two arrows.

The same machinery handles UI reactivity, observable streams, signal-based state management, and database row subscriptions — they were never different things. They were all just "value driven by event."

---

## Files and folders are scopes

`@` resolves the filesystem as a scope graph. A folder is a scope; its bindings are its files and subfolders. A file is a scope; its bindings are its top-level pointings.

```dart
Plane2D -> @lib.geometry.Plane

// expand a modified version of an entire directory into the current scope
...@lib.geometry{Plane -> Plane{dimension -> 3}}
```

Read the second line slowly: `@lib.geometry` is a folder-scope. `{Plane -> Plane{dimension -> 3}}` overrides one of its bindings. `...` expands the result into the current scope. So this single line takes a whole library, modifies one piece of it, and dumps it into the current namespace.

There is no import system, no module syntax, no `from … import …`. There is one scope graph, and the same five operators that work on everything else work on it too.

---

## Compile-time is just collapse without effects

Here's a quietly enormous property of Syntact: **the compiler is the same engine as the runtime**, used at a different time.

A pure computation has no effects. A pure computation can therefore be fully reduced by the compiler. The result is baked into the binary. There is nothing left to run.

```dart
greeting -> "hello, " + "world"
-> greeting
```

This program contains no effects. The compiler reduces `"hello, " + "world"` to `"hello, world"` and the binary is a constant. No string concat happens at runtime.

This generalizes. You can lift an effectful operation into compile-time evaluation by wrapping it:

```dart
compileTimeHttp -> !{@http}

configText -> compileTimeHttp.get{"https://api.example.com/config"}!

result -> configText ? {
  "PRODUCTION"  -> "Production mode"
  "DEVELOPMENT" -> "Development mode"
  -> "Unknown mode"
}
```

The HTTP call happens during compilation. The pattern match collapses to a constant. The runtime program is a single string load. There is no macro system in Syntact because there does not need to be one — the language is its own metalanguage.

---

## Proofs with `??` and `?!`

Two more operators let you write theorems that the compiler proves at compile time:

- `??` declares a *symbolic unknown* — a value that stands for "any value of this shape."
- `?!` *enforces* a property — the compiler must prove it holds, or the program does not compile.

```dart
incrementAlwaysIncreases -> {
  u8:prev -> ??              // for any prev
  Counter:count{value -> prev}
  count.increment!
  -> count! = prev + 1       // the result must equal prev + 1
}
```

The compiler symbolically reduces both sides for every possible `prev`. If it can't prove the equality, the program is rejected.

```dart
addCommutative -> {
  Nat:a -> ??
  Nat:b -> ??
  -> add{a b}! = add{b a}! ?! true
}
```

This isn't a separate proof assistant glued onto the language. It's the *same* reducer used for everything else, asked a slightly different question: "for all values of these holes, does this equation hold?"

---

## Concurrency: choosing how to collapse

We mentioned the collapse wrappers earlier. Here they are again, in context:

```dart
result -> heavyComputation!       // run it now, sequentially
result -> heavyComputation<!>     // on another thread; locks/atomics auto-managed
result -> heavyComputation[!]     // parallel CPU (data-parallel; must be pure)
result -> heavyComputation(!)     // background; result is a handle
result -> heavyComputation|!|     // GPU (must be pure)
result -> heavyComputation([!])   // parallel CPU, in background
```

The wrappers compose: `<[!]>` is "parallel CPU on another thread," `(<[!]>)` is "the same, deferred until you collapse the handle."

Three things matter here:

1. The *code being collapsed* doesn't know how it will run. The same `heavyComputation` scope can be collapsed sequentially in tests and in parallel in production. No rewriting.
2. Purity is enforced statically by the compiler. `[!]` and `|!|` will not compile if the scope they wrap can emit effects with non-commutative handlers.
3. Background collapses produce a handle. To wait, you collapse the handle: `result!`. This is the same `!` you've been using all along — there is no `await` keyword.

---

## Why this is fast

Syntact has performance ambitions that are unusual for a high-level language: it aims to be **faster than traditional compiled languages**, not despite its abstractions but *because of* them.

The argument is simple. In a typical language, an abstraction is an opaque barrier — a function call, an interface dispatch, a virtual method, a closure capture. Optimizers work hard to see through these barriers, and they often fail. The cost of an abstraction in those languages is real.

In Syntact, there are no such barriers. There is one primitive: scope reduction. Every "abstraction" in Syntact — generics, higher-order callables, modules, traits, effect handlers, even reactivity — is just a particular shape of scope being reduced. The compiler doesn't have to *see through* abstractions; there is nothing to see through.

The collapse operator `!` is, fundamentally, **an optimization mechanism**. When you write `f{x->5}!`, you are not "calling a function with the value 5." You are asking the compiler to reduce the scope `f` with `x` overridden to `5`, as far as it can. Often, that reduction is total: the entire `f` evaporates into a constant. Sometimes it bottoms out at an effect that has to wait for runtime. Either way, no abstraction has been preserved beyond what was necessary.

The intended programming experience is this: **you should be able to think at the level of data and machine instructions, while writing extremely high abstractions, and pay nothing for them.** The high-level shape of your code and the low-level shape of your binary are bridged by a single uniform reduction process. There is no semantic gap to optimize across, because there are no extra semantic layers to begin with.

This is the reason Syntact rejects the function as a primitive. The function is exactly the kind of opaque abstraction barrier that prevents languages from compiling to optimal code.

---

## How a program runs

> **Running a Syntact program means collapsing the scope of a file.**

That's the entire execution model. The compiler takes your entry file. It finds the file's production (`-> something`). It reduces.

If the production has no effects, the program *is* its result. It compiles to a constant. The binary literally returns a value and exits.

```dart
-> 42       // compiles to: return 42
```

If the production passes through effects, the compiler arranges for those effects to fire in the right order before the result is produced. It statically guarantees that every effect has a handler in scope.

```dart
program -> {
  Log -< e { -> io.write{e.message}! }
  >- Log{"hello"}
  -> 0
}

-> program!
```

This program returns `0`. But the collapse of `program` traverses an effect emission, so the binary writes "hello" to stdout before returning `0`. The handler is statically resolved, so there is no runtime lookup, no dispatch table, nothing dynamic — just the I/O call inlined where the emit was.

The name `program` is arbitrary. You could call it `main`, `start`, `run`, `do_thing`, `xyz`. What matters is that the *file* ends with `-> something!`, and that "something" is what the program does.

---

## A complete example

Putting it together — a reactive counter, an effect handler module, and a program that uses both:

```dart
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

program -> {
  ...Logging                  // install the Log handler
  Counter:counter             // a counter, defaults to 0
  >- Log{counter!}            // "0"
  counter.increment!
  >- Log{counter!}            // "1"
  counter.decrement!
  >- Log{counter!}            // "0"
  -> 0
}

-> program!
```

What you have here:
- A reactive counter type.
- An effect handler module, expanded inline.
- A program that uses both.

What's missing — and notably so — is everything you'd expect to see in another language: no class declaration, no constructor, no observer pattern, no event subscription, no async runtime, no framework, no import statement, no entry-point boilerplate. Twenty lines, and the language gave you all of that for free.

---

## What you give up, and what you get

Syntact gives up:

- The function as a primitive.
- Mutation as a primitive.
- The distinction between value, type, module, file, and effect.
- The distinction between compile time and run time.
- Separate systems for generics, traits, macros, modules, effects, reactivity, and proofs.

In exchange:

- One structural primitive (scope) and a small set of binding arrows.
- Everything is total. Everything has a default. Nothing is null.
- Generics, sum types, refinement types, pattern matching, dependent types, and proofs — all from the same operators.
- Algebraic effects with statically-proven handlers — no runtime cost beyond the I/O itself.
- Reactivity without a framework.
- Compile-time evaluation without a macro system.
- Composable concurrency wrappers (sequential, threaded, parallel, GPU, background) that don't require the code itself to know how it will run.
- Performance ambitions beyond traditional languages, because there are no abstraction barriers for the optimizer to fight.

---

## Status

Syntact is in active development. The current bootstrap compiler is written in Odin and lives in `compiler/`; it parses, analyzes, and is in the process of regaining its x64 backend. An LSP is available in `lsp/`. A declarative test suite lives in `test/`.

The eventual goal is a self-hosted compiler written in Syntact itself — at which point the bootstrap can retire, and the language can begin proving things about its own implementation.

---

*Syntact is the language I wished existed. If, after reading this, you wish it existed too — you're in the right place.*
