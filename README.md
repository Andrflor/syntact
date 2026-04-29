# Syntact

> *A language where everything is a scope, nothing is a function, and execution is just reduction.*

---

Syntact is an experimental general-purpose programming language built around one primitive: the **scope**. A scope is a complete, executable structure made of bindings. It can be inspected, derived from, constrained, expanded, and reduced — but it is never a function, an object, a module, or a record, even though it can replace all of them.

What other languages express with function calls, Syntact expresses with two independent operations: *carve* a new scope from an existing one, and *collapse* a scope to the value it produces. From this model — scope, binding, carving, collapse — everything else emerges: types, generics, modules, pattern matching, algebraic effects, reactivity, compile-time evaluation, and eventually proofs. There is no class system, no trait system, no macro system, no async runtime. There is one structural primitive, and a handful of operators.

Here is what writing Syntact actually looks like:

```dart
square -> {
  n -> 0
  -> n * n
}

square.n         // 0
square!          // 0
square{n -> 5}!  // 25
```

`square` is a complete scope with one binding (`n`) and one production (`n * n`). You can read its bindings directly (`square.n`), reduce it with `!`, or carve a new scope from it (`square{n -> 5}`) and reduce that. There is no function being called anywhere; there are only scopes, bindings, derivation, and reduction.

That model scales. Here is a larger example using effects and reactivity:

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

The performance hypothesis is unusual: by removing function boundaries and making reduction explicit, Syntact gives the compiler more structure to work with than traditional compiled languages typically expose. The collapse operator `!` is fundamentally an optimization mechanism. The long-term ambition is to outperform traditional compiled languages by reducing more of the program before runtime — and to make high abstractions cost no more than the underlying assembly they reduce to.

The rest of this document walks through the language from the ground up. By the end, you'll be able to read every snippet above without translation.

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

## Contents

**The three fundamentals**
- [The Syntact trinity: scope, binding, collapse](#the-syntact-trinity-scope-binding-collapse)

**Writing Syntact**
- [Your first program](#your-first-program)
- [Bindings and pointing](#bindings-and-pointing)
- [Scopes](#scopes)
- [Collapse: turning a scope into a value](#collapse-turning-a-scope-into-a-value)
- [Carving: declaring and deriving with `{...}`](#carving-declaring-and-deriving-with-)
- [Deriving and collapsing scopes](#deriving-and-collapsing-scopes)

**Values, types, and matching**
- [Default values, immutability, totality](#default-values-immutability-totality)
- [Primitive types are scopes](#primitive-types-are-scopes)
- [The shape operator `:`](#the-shape-operator-)
- [Pattern matching with `?`](#pattern-matching-with-)
- [Pull bindings: holes filled later with `<-`](#pull-bindings-holes-filled-later-with--)
- [Building a list, step by step](#building-a-list-step-by-step)

**Effects, reactivity, concurrency**
- [Effects: `>-` and `-<`](#effects---and--)
- [Resonance: reactivity with `>>-` and `-<<`](#resonance-reactivity-with----and--)
- [Concurrency: choosing how to collapse](#concurrency-choosing-how-to-collapse)

**The execution model**
- [How a Syntact program runs](#how-a-syntact-program-runs)
- [Files and folders are scopes](#files-and-folders-are-scopes)
- [Compile-time is collapse without effects](#compile-time-is-collapse-without-effects)
- [Proofs with `??` and `?!`](#proofs-with--and-)

**Closing**
- [Why this is fast](#why-this-is-fast)
- [A complete example](#a-complete-example)
- [What you give up, and what you get](#what-you-give-up-and-what-you-get)
- [Status](#status)

---

## The Syntact trinity: scope, binding, collapse

Syntact rests on three fundamental units. These are the entire conceptual surface of the language. Everything else is built from how they combine.

### 1. The scope — the object that was always there

Every programming language has a notion of *scope*. C has scopes. Python has scopes. Rust has scopes. JavaScript has scopes. They are the bracketed regions inside which names are visible. They are universal — and yet, somehow, no language treats them as a *first-class object*. They are a side-effect of declaring a function, a class, a block, a module. They exist, but you can't pick one up and pass it around.

This is strange, because the scope is the truly fundamental object: a structured collection of named things. A class is a scope. A module is a scope. A function body is a scope. A struct literal is a scope. A namespace is a scope. Languages keep reinventing this concept under different names with different rules, instead of admitting that it's the same thing each time.

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

Syntact says no. **Execution is a separate operation, orthogonal to scope and orthogonal to binding.** It has its own symbol: `!`, the **collapse**. Without `!`, the scope is simply not reduced at that point — it is still a complete, executable structure that you can inspect, carve, expand, or pass around. With `!`, Syntact reduces the scope through its production to a value.

This sounds like a small thing. It is not. It means you can pass any computation around as data without ceremony, override the body of a computation before it runs, let the compiler reduce as much as it wants ahead of time (because reduction is an explicit operator and not a side-effect of merely existing), choose your concurrency strategy at the call site (`!`, `<!>`, `[!]`, `(!)`, `|!|`), and treat compile-time evaluation as just collapse done early — no separate macro language needed.

**Scope, binding, collapse.** Three concepts. That is the entire conceptual budget of Syntact. The next sections show what writing the language actually looks like.

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

This program produces `42`. The binding `greeting` is computed but ignored, because nothing depends on it — and since Syntact reduces statically, the unused work is simply never emitted in the binary. To make that concrete, if we compile for Linux on x86-64, here is the entire program the compiler produces for the snippet above:

```asm
_start:
    mov     edi, 42         ; exit code = 42
    mov     eax, 60         ; syscall: exit
    syscall
```

That's the whole binary. No string `"hello"` appears anywhere — it was reduced away at compile time, along with the binding that held it. Two syscalls' worth of instructions, because that's all the program actually does.

---

## Bindings and pointing

The `->` operator is a **pointing**. It takes a *source* on the left and a *target* on the right, and binds the source to the target.

```dart
name -> "Alice"
age  -> 30
pi   -> 3.14159
```

Each line is a binding: the label on the left is *pointed at* the value on the right.

### Top-down structure

Bindings in Syntact are **top-down**. A binding can only see what already exists above it in the same scope, or in an enclosing scope. There is no hoisting and no forward reference.

```dart
x -> 1
y -> x + 1    // valid: x exists above y
```

But this is invalid:

```dart
y -> x + 1    // invalid: x does not exist yet when y is bound
x -> 1
```

This is not only a visibility rule. It is part of the execution model. A scope is not an unordered namespace — it is a **directed reduction structure**. The order of bindings is the order in which the scope is built, and later bindings may depend on earlier ones — never the reverse. Reduction follows the same direction: a collapse walks the scope downward through dependencies that already exist by construction.

A consequence worth naming: **there is no separate parameter zone in Syntact.** What other languages would call a "function parameter" is simply an earlier binding that later bindings or productions depend on. Look back at:

```dart
square -> {
  n -> 0
  -> n * n
}
```

`n` is not declared as a parameter. It is just a binding, and the production `-> n * n` is allowed to depend on it because `n` appears above. Nothing more. That is why `square.n` and `square!` both work without supplying anything — `square` is already complete, and `n` already exists.

If you want a different `n`, you don't pass an argument; you carve a new scope, which produces a new structure where `n` is overridden *before* the production reads it:

```dart
square{n -> 5}!    // 25
```

The model is still top-down. The production can use `n` because `n` is structurally above it; carving replaces that earlier binding before the production runs.

### Productions: pointing without a label

The label on the left can be **omitted**. When you write a pointing with nothing on the left, the source isn't missing — it's the **enclosing scope itself**. The scope is pointing *itself* at the value on the right. We call this a **production**: not a separate operator, just the same `->` with an implicit source.

```dart
greeting -> "hello"
-> greeting        // this scope points itself at "hello"
```

When the scope is collapsed, its value is what it has been pointed at. That's how a program — itself a scope — produces a value. There is no `return` keyword in Syntact, because there doesn't need to be one. Returning a value is just pointing the surrounding scope at it.

### A scope can be bound to several things

A binding source can be repeated, including the implicit source. You can write multiple productions in the same scope, and they all coexist as alternative potentialities the scope can resolve to:

```dart
maybe_value -> {
  -> 0           // first potentiality (default)
  -> 1
  -> 2
}
```

The first potentiality is the default. The others remain available. This isn't a special syntax for "alternatives" — it is the natural shape of binding when the source is implicit and can be repeated.

Keep this property in mind: it's what later makes types in Syntact work the way they do.

---

## Scopes

A scope is what `{...}` produces — a collection of bindings:

```dart
point -> {
  x -> 10
  y -> 20
}
```

`point` is a scope with two bindings. You access them with `.`:

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

A file is itself a scope (its top-level bindings are its contents). A directory is a scope (its bindings are the files and subdirectories it contains). A primitive type is a scope. An event is a scope. A pattern is a scope. Everything you encounter in Syntact is a scope of some kind.

---

## Collapse: reducing a scope

Every scope in Syntact is executable.

A scope is not a function waiting for arguments. It is already a complete structure: it has bindings, it may have productions, and it can be inspected, carved, expanded, constrained, or reduced. It is a structured value with a reduction behavior.

**Collapse**, written `!`, is the operation that reduces a scope through its production to a value.

```dart
two -> {
  a -> 1
  b -> 1
  -> a + b
}

two.a    // 1
two.b    // 1
two!     // 2
```

`two` is already a complete scope. Nothing about it is missing. You can read its bindings (`two.a`, `two.b`), you can carve a new scope from it, you can pass it around — all of these are valid because the scope already exists. Without `!`, the scope is simply not reduced at that point. With `!`, Syntact reduces it through its production.

### `!` is not evaluation

A subtlety worth being precise about: **`!` is not general expression evaluation. `!` is scope collapse.**

`!` does not mean "evaluate this expression." It specifically means: take this scope and reduce it through its production. That distinction matters because a binding can point at two very different kinds of thing.

A binding can point directly to a value or expression:

```dart
base -> {
  x -> 1
  y -> x + 1
}

base.y    // 2
```

Here `y` is not a scope — it is a binding pointing at the expression `x + 1`. There is nothing to collapse. Reading `base.y` resolves to `2` by following the binding.

A binding can also point at a scope:

```dart
base -> {
  x -> 1
  y -> {
    -> x + 1
  }
}

base.y     // the scope bound to y
base.y!    // 2
```

Now `y` is a binding pointing at a scope. Reading `base.y` gives you that scope. Writing `base.y!` is what reduces it.

The rule is simple: **expressions resolve, scopes collapse.** `!` only appears when the thing being reduced is a scope.

### Reduction is intentional

This separation is the engine of Syntact. **Collapse never happens by accident.** It happens exactly where you write `!`, and nowhere else. That is what lets the compiler reason about your program: every reduction has a place on the page, and so does every non-reduction.

The `!` has variants that say *how* the reduction should happen — but they're all the same fundamental operation, just routed differently. We'll come back to them in [Concurrency](#concurrency-choosing-how-to-collapse).

---

## Carving: declaring and deriving with `{...}`

You've already seen `{...}` used to declare a fresh scope. There's more to it than that. `{...}` is the **carving operator**, and it does two things — depending on whether something sits to its left.

**Applied to nothing**, it carves a fresh scope from the void:

```dart
point -> {
  x -> 0
  y -> 0
}
```

The braces open an empty space, and the bindings inside fill it. This is what we've been doing all along.

**Applied to an existing scope**, it carves a *new* scope derived from that one, with the bindings inside the braces overlaid on top:

```dart
shifted -> point{x -> 5}
```

`point{x->5}` doesn't modify `point`. It carves a brand-new scope that *is* `point`, except `x` is now `5`. The original is untouched:

```dart
point.x         // still 0
shifted.x       // 5
shifted.y       // 0   (inherited from point)
```

The same operator does both. **Declaration is just carving from nothing; override is carving from something.** There is no separate "modify" syntax in Syntact, because modification doesn't exist — only derivation.

This is what other languages would call inheritance, instantiation, configuration, partial application, or "with"-syntax. They were all the same operation; Syntact gives it one name and one symbol.

### Carving propagates structurally

Because scopes are top-down reduction structures, overriding an earlier binding propagates naturally to anything declared below it that depended on it.

```dart
base -> {
  x -> 1
  y -> x + 1
}

base.y                   // 2

derived -> base{x -> 10}
derived.y                // 11
```

`y` is not a collapsed scope here — it is a binding whose target depends on `x`. When `x` is carved over in `derived`, `y` is resolved in the new derived structure, so it sees the new `x` and resolves to `11`. Carving doesn't poke into a fixed object; it derives a new structure where the rest of the scope is reinterpreted with the new binding in place.

If you want `y` itself to be a scope (something you'd reduce with `!`), you write one:

```dart
base -> {
  x -> 1
  y -> {
    -> x + 1
  }
}

base.y      // the scope bound to y
base.y!     // 2
```

Same top-down propagation, same carving rules — `!` shows up only because `y` is now a scope, not an expression.

This is what makes carving + collapse genuinely different from a function call: a function applies an argument to a fixed body, while carving rewrites the structure itself before reduction touches it.

---

## Deriving and collapsing scopes

What other languages model as a function call, Syntact expresses as two independent operations: carve a new scope from an existing one, then collapse it.

```dart
square -> {
  n -> 0
  -> n * n
}

square.n             // 0
square!              // 0    (the default n -> 0 is used)
square{n->5}         // a new scope, derived from square with n overridden
square{n->5}!        // 25
```

Read this carefully:

- `square` is already a complete scope. It has a binding `n` (with value `0`) and a production (`n * n`).
- `square.n` reads that binding. Nothing is "called" — `square` already has an `n`.
- `square!` reduces the scope through its production. Since `n` is `0`, the result is `0`.
- `square{n->5}` is a brand-new scope, derived from `square` with `n` carved over. It has not been reduced.
- `square{n->5}!` reduces that new scope. The result is `25`.

### Why this is not a function

A common first reaction is to read this:

```dart
square -> {
  n -> 0
  -> n * n
}
```

as if it meant `square(n) = n * n`. It does not.

`n` is not a parameter. It is a binding inside the scope. `square` is not waiting for `n` — it already *has* `n`. That is why `square.n` and `square!` are both valid right away, without supplying anything.

A function call supplies missing arguments to an abstraction. A Syntact carving does not supply arguments — it *derives a new complete scope from an existing complete scope*. There is no function object, no parameter list, no call boundary, and no privileged body. There are only scopes, bindings, carving, and collapse.

### What this composition replaces

Once you accept that carving is derivation and collapse is reduction, you get for free everything other languages bolt on as separate features:

- **Default values**: every binding has one (`n -> 0`). It is used when you don't override.
- **Partial application**: override some bindings now, others later. `squareOf7 -> square{n->7}` is a derived scope; collapse it later with `squareOf7!`.
- **Higher-order parameters**: a scope is a value, so you pass scopes around like any other data.
- **Methods**: bindings inside a scope are accessed with `.`. There is no method-vs-function distinction.

You can override *any* binding, not just the input-looking ones. Override what the scope produces:

```dart
square{-> 99}!    // ignores n, produces 99
```

Or override the body to compute differently:

```dart
double -> square{-> n + n}      // same n, different production
double{n->5}!                    // 10
```

There is no function declaration, no function type, no calling convention — and consequently nothing for the optimizer to lose information across.

---

## Default values, immutability, totality

Two structural properties make Syntact code unusually safe.

**Every scope always has a value.** There is no `null`, no "uninitialized," no `undefined`. A scope's value, when nothing is overridden, is its first declared potentiality. If you write `Color:bg` and never set anything, `bg` is the first potentiality of `Color` — automatically. The compiler never has to ask "is this thing initialized yet?" — the answer is always yes.

**Bindings are immutable.** Once you write `name -> "Alice"`, `name` *is* `"Alice"` for the rest of that scope. To get a different value, you carve a new scope (override) or you reach for *resonance* (covered later) — which is itself just a structured way of producing new scopes in response to events.

The benefit is that the compiler can reason about every value statically. There are no mutable aliases to track, no surprise null deref, no "did this get initialized" question. Programs are *total* by construction.

---

## Primitive types are scopes

Now the second use of multiple productions starts to show up. The primitive types — `u8`, `i32`, `f64`, `bool`, `String`, etc. — are not built-in keywords with special status. They are **scopes**, and their productions are *all the values they can hold*.

`u8` is a scope with 256 productions, one for each valid value, with `0` as the first one (and therefore the default). `bool` has two productions, `false` and `true`, defaulting to `false`. `String` is the scope of all strings, defaulting to `""`. Nothing about them is special — they're declared the same way you'd declare your own types, just bigger.

Because they're just scopes, you write them with the same syntax as everything else:

```dart
counter -> 0           // a u8, defaulting to 0
flag    -> true        // a bool
name    -> "Alice"     // a String
```

The compiler infers the most specific type from the value you wrote. You can also be explicit, which is what the next section is about.

---

## The shape operator `:`

`:` constrains a binding to a particular **shape** — a particular scope. Read `u8:age` as "age, shaped like a u8."

```dart
u8:age          // age is a u8, defaulting to 0
String:name     // name is a String, defaulting to ""
Color:bg        // bg is a Color, defaulting to its first production
```

Because every scope has a default, `u8:age` already gives `age` a meaningful value. You can override it:

```dart
u8:age -> 30
```

This is what other languages would call a "type annotation," but it isn't a separate annotation system — it's just an operator that says "constrain this binding to a sub-scope of that scope."

It works on any scope, not just primitives:

```dart
Point -> {
  u8:x
  u8:y
}

Point:p              // p is {x:0 y:0}
Point:p2 -> {x->5}   // p2 is {x:5 y:0}
```

You can combine `:` and carving to constrain *and* override at once:

```dart
Point:origin{x->10 y->20}
```

### You don't have to use `:`

A point worth making clearly: **you can write entire Syntact programs without ever using `:`**. The shape operator is a tool for when you want the compiler to enforce a constraint. Pointing and carving alone — `->` and `{...}` — are enough to write working programs.

```dart
greeting -> "hello"
person -> {
  name -> "Alice"
  age -> 30
}
older -> person{age -> 31}
-> older.name
```

That's a complete program. No `:`, no type annotations, no boilerplate. The compiler infers everything from the values you wrote.

Use `:` when you want to:
- Document an intent ("this binding holds a `u8`").
- Refine a value into a sub-scope ("this binding must satisfy `Adult`").
- Make the compiler verify a structural property at the boundary.

Otherwise, leave it out. Syntact is meant to feel light when you want it light.

---

## Pattern matching with `?`

`?` matches a value against the productions of a scope, or against literal patterns:

```dart
n ? {
  0 -> "zero"
  1 -> "one"
  -> "many"          // the default branch (no left-hand pattern)
}
```

Branches are tried top-down. The last branch with no pattern is the default.

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

Because *types are their productions* in Syntact, `?` doesn't distinguish between "matching a sum type" and "matching a value" and "checking a refinement" — all three are the same operation: constrain a value to a sub-scope and pick the matching branch.

---

## Pull bindings: holes filled later with `<-`

`->` is *push*: the value flows from right to left, fixed where it's written. `<-` is *pull*: the binding declares a hole that will be filled by *whoever uses this scope*. This is how Syntact does generics — without a separate generic system.

```dart
identity -> {
  T <- None        // T is a hole, filled at the use site
  T:value
  -> value
}

identity{T->u8 value->5}!         // 5, with T resolved to u8
identity{T->String value->"hi"}!  // "hi", with T resolved to String
```

The pull arrow tells the compiler: "this binding is not the place to fix `T` — wait until someone uses this scope, and let *their* override decide." That single behavior — "wait until consumed" — is what makes a scope parametrically polymorphic, with no `<T>` syntax or template machinery.

You'll see `<-` everywhere generics would appear in another language: in containers, in mappers, in algebraic structures.

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

Three things are happening:

1. `T <- None` declares the element type as a hole. It defaults to `None` (a built-in empty scope) and is filled by whoever uses `List`.
2. `-> {}` says "one of the things a `List` can be is the empty scope." This is the first production, and therefore the default.
3. `-> { T:, ...List{T}: }` says "another thing a `List` can be is a scope containing a `T` followed by the contents of another `List{T}`." `T:` is an anonymous binding shaped like `T`. `...` *expands* the contents of another scope into this one.

To use it:

```dart
List{T->u8}:numbers              // an empty u8 list (the default)
List{T->u8}:numbers -> {1 2 3}   // a u8 list with three elements
```

Because `...` flattens, you don't need to write `{1 {2 {3 {}}}}` — `{1 2 3}` *is* the nested form, written flat. The two are the same data.

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

You now have a fully generic `map`, written using only the operators we've seen so far. There was no class, no interface, no `Functor`, no template, no `<T>`. Just scopes, bindings, carving, collapse, expansion, and pattern matching.

---

## Effects: `>-` and `-<`

So far everything has been pure. Real programs need to talk to the world — to print things, to read files, to make HTTP calls. Syntact handles this through **algebraic effects**, with two arrows: `>-` to emit, `-<` to handle.

An effect is just a scope. You declare it like any other:

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
  debugPrint{message->"hello"}!           // emit propagates up to handler
}

-> program!
```

The compiler **statically proves** that every emitted effect has a handler in scope at the point of collapse. If it doesn't, the program does not compile. There is no exception, no runtime error, no "effect not handled" surprise — only compile errors.

This is enormously powerful. The same `debugPrint` can be:

- Real I/O (handler writes to stdout).
- A unit test (handler captures the messages into a list).
- A replay log (handler timestamps and stores them).
- A compile-time evaluation (handler runs at compile time — see later).

The code you wrote doesn't change. Only the handler does.

---

## Resonance: reactivity with `>>-` and `-<<`

Sometimes a value isn't a single computation — it changes over time in response to events. Syntact handles this with **resonance**, written `>>-` ("driven by") and `-<<` ("push to"). And here's the structural punchline: **mutability in Syntact is an effect**. There is no in-place modification anywhere in the language. What looks like mutation is always a value being driven by an event, with the event flowing through a handler the compiler can see.

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

There's no framework here. No subscriptions. No diffing. No lifecycle. Two arrows.

The same machinery handles UI reactivity, observable streams, signal-based state management, and database row subscriptions — they were never different things. They were all just "value driven by event."

Because mutation is structurally an effect, the compiler can isolate it just like any other effect. Pure code is provably pure. Reactive code is provably reactive. There is no hidden state lurking inside a scope, because there is no way to introduce hidden state in the first place.

---

## Concurrency: choosing how to collapse

`!` has variants. They all collapse the scope they're attached to, but they say *where* and *how*:

```dart
result -> work!         // sequential, right here
result -> work<!>       // on another thread (locks/atomics auto-managed)
result -> work[!]       // parallel CPU (the work must be pure)
result -> work(!)       // background — returns a re-collapsable handle
result -> work|!|       // GPU (the work must be pure)
result -> work([!])     // parallel CPU, in background
result -> work(|!|)     // GPU, in background
```

The wrappers compose freely. `<[!]>` is "parallel CPU, on another thread." `(<[!]>)` wraps that in a background handle.

Three things matter here:

1. **The code being collapsed doesn't know how it will run.** The same `work` scope can be collapsed sequentially in tests and in parallel in production. No rewriting.
2. **Purity is enforced statically.** `[!]` and `|!|` will not compile if the scope they wrap can emit effects whose handlers aren't safe to run in that mode.
3. **Background collapses produce a handle.** To wait, you collapse the handle: `result!`. This is the same `!` you've been using all along — there is no `await` keyword, because there doesn't need to be one.

Concurrency in Syntact is a property of the *call site*, not of the code. That is the consequence of having execution be a separate operator with its own symbol.

---

## How a Syntact program runs

> **Running a Syntact program means collapsing the scope of a file.**

That's the entire execution model. The compiler takes your entry file, finds its production (`-> something`), and reduces.

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

This program returns `0`. But the collapse of `program` traverses an effect emission, so the binary writes `"hello"` to stdout before returning `0`. The handler is statically resolved — no runtime lookup, no dispatch table, nothing dynamic — just the I/O call inlined where the emit was.

The name `program` is arbitrary. You could call it `main`, `start`, `run`, `do_thing`, `xyz`. What matters is that the *file* ends with `-> something!`, and that "something" is what the program does.

---

## Files and folders are scopes

The execution model above mentions "your entry file" as a scope. That's literal. `@` resolves the filesystem as a scope graph: a folder is a scope whose bindings are its files and subfolders, and a file is a scope whose bindings are its top-level pointings.

```dart
Plane2D -> @lib.geometry.Plane

// expand a modified version of an entire directory into the current scope
...@lib.geometry{Plane -> Plane{dimension -> 3}}
```

Read the second line slowly: `@lib.geometry` is a folder-scope. `{Plane -> Plane{dimension -> 3}}` carves a derived version with one binding overridden. `...` expands the result into the current scope. So this single line takes a whole library, modifies one piece of it, and dumps it into the current namespace.

There is no import system, no module syntax, no `from … import …`. There is one scope graph, and the same operators that work on everything else work on it too.

---

## Compile-time is collapse without effects

Here is a quietly enormous property of Syntact: **the compiler is the same engine as the runtime**, just used at a different time.

A pure computation has no effects. A pure computation can therefore be fully reduced by the compiler. The result is baked into the binary. Nothing is left to run.

```dart
greeting -> "hello, " + "world"
-> greeting
```

This program contains no effects. The compiler reduces `"hello, " + "world"` to `"hello, world"` and the binary is a constant. No string concat happens at runtime.

This generalizes. You can lift an effectful operation into compile-time evaluation by wrapping its scope:

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

## Why this is fast

We've been hinting at this. Now that you've seen the language, the argument lands cleanly.

In a typical compiled language, an abstraction is an opaque barrier — a function call, an interface dispatch, a virtual method, a closure capture. Optimizers work hard to see through these barriers, and they often fail. The cost of an abstraction in those languages is real, even when "zero-cost" is on the marketing page.

In Syntact, there are no such barriers. There is one primitive: scope reduction. Every "abstraction" — generics, higher-order callables, modules, traits, effect handlers, even reactivity — is just a particular shape of scope being reduced. The compiler doesn't have to *see through* abstractions; there is nothing to see through.

The collapse operator `!` is, fundamentally, **an optimization mechanism**. When you write `f{x->5}!`, you are not "calling a function with the value 5." You are asking the compiler to reduce the scope `f` with `x` overridden to `5`, as far as it can. Often, that reduction is total — the entire `f` evaporates into a constant. Sometimes it bottoms out at an effect that has to wait for runtime. Either way, no abstraction has been preserved beyond what was necessary.

And because effects are isolated (every emit must reach a handler the compiler can see), the *shape of the reduction* is the *shape of the code*. There is no hidden state, no accidental dependency, no implicit graph the optimizer has to reverse-engineer. The compiler simply runs the reduction, and what doesn't reduce is exactly what has to remain at runtime.

The intended programming experience: **think at the level of data and machine instructions, write extremely high abstractions, pay nothing for them.** The high-level shape of your code and the low-level shape of your binary are bridged by a single uniform reduction process. The language design is itself an optimization engine — that's the strongest reason to expect Syntact to outperform languages built on the function abstraction.

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

- A reactive counter type (`Counter`).
- An effect handler module (`Logging`), expanded inline.
- A program that uses both.

What's missing — and notably so — is everything you'd expect to see in another language: no class declaration, no constructor, no observer pattern, no event subscription, no async runtime, no framework, no import statement, no entry-point boilerplate. About twenty lines, and the language gave you all of it for free.

---

## What you give up, and what you get

Syntact gives up:

- The function as a primitive.
- Mutation as a primitive.
- The distinction between value, type, module, file, and effect.
- The distinction between compile time and run time.
- Separate systems for generics, traits, macros, modules, effects, reactivity, and proofs.

In exchange:

- One structural primitive (scope), six binding arrows, one reduction operator, one carving operator. That's it.
- Everything is total. Everything has a default. Nothing is null.
- Generics, sum types, refinement types, pattern matching, dependent types, and proofs — all from the same operators.
- Algebraic effects with statically-proven handlers — no runtime cost beyond the I/O itself.
- Reactivity without a framework. Mutability that is structurally an effect.
- Compile-time evaluation without a macro system.
- Composable concurrency wrappers (sequential, threaded, parallel, GPU, background) that don't require the code itself to know how it will run.
- Performance ambitions beyond traditional compiled languages, because there are no abstraction barriers for the optimizer to fight.

---

## Status

Syntact is in active development. The current bootstrap compiler is written in Odin and lives in `compiler/`; it parses, analyzes, and is in the process of regaining its x64 backend. An LSP is available in `lsp/`. A declarative test suite lives in `test/`.

The eventual goal is a self-hosted compiler written in Syntact itself — at which point the bootstrap can retire, and the language can begin proving things about its own implementation.

---

*Syntact is the language I wished existed. If, after reading this, you wish it existed too — you're in the right place.*
