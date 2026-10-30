# Syntact

> **The code is the proof.**

Soon, machines will write most of the code, and nobody will read it. The question is
no longer how to write a program. It is how to trust a program you never read.

The answer is proof. But a proof, the way we write them today, is a second program,
written in a language above the code: longer than the first, built case by case,
rewrite by rewrite. In Lean, in Rocq, in Bend 2, you state a law, then someone — you,
or a model searching for hours — has to write its proof.

In Syntact there is no proof to write. **The code is the proof, by construction.** If
it compiles, it is proven.

And it does not stop there: the same algebra that proves your program makes it fast,
runs it in parallel or on the GPU, and manages its memory without a garbage collector.

---

## Curry–Howard, the other way round

Curry–Howard: a proposition is a type, and a proof is a program of that type. Proof
assistants exploit it one way. To prove a proposition, you write a program whose only
job is to inhabit it: a proof term, built by hand or by tactics, checked, then erased.
It never runs. Beside it, the program that runs proves nothing.

Syntact exploits it the other way: **the program that runs is the proof.** Its colors
are the propositions, and the program inhabits them. The compiler checks that it does
by computing what the program is, its normal form. There is no second program and no
second language: every program proves its colors, and what runs is what was proven.

```syntact
pack -> {
  u16:n -> 0
  -> n * 2 + 1
}
unpack -> {
  u32:m -> 1
  -> (m - 1) / 2
}

n -> ??::u16
u32:packed -> pack{n}!              // proven: every packed value fits in a u32
n:roundtrip -> unpack{pack{n}!}!    // proven: unpack undoes pack
```

`n:` is the law. It says that `roundtrip` gives back `n` — the same unknown, for all of
its 65 536 values at once. No lemma, no induction, no tactic, no proof term: the
compiler simplified the program, and what was left was the law.

Recursion is never unfolded. It is solved:

```syntact
sum -> {
  u64:n -> ??
  -> n ? {0 -> 0  -> n + sum{n -> n - 1}!}
}

n -> ??::u64
true:gauss -> sum{n}! * 2 = n * (n + 1)    // proven, for every u64
```

The recursion was solved to its closed form, `(n + n²) / 2`, and the law reduced to
`true`. Nobody wrote an induction.

| | Lean · Rocq · Bend 2 | Syntact |
|---|---|---|
| You write | the code, the laws, and their proofs | the code and its colors |
| Proof language | tactics, proof terms | none: a color is a type |
| Recursion | an induction, by hand | solved, to its closed form |
| When it fails | the proof does not close | the value that breaks it |

## Wrong code does not compile. The compiler says why.

```syntact
abs -> {
  i32:n -> ??
  -> n ? {<0 -> 0 - n  -> n}
}

n -> ??::i32
i32:r -> abs{n}!     // refused: not an i32 when n is -2147483648
```

The bug every C programmer has shipped once, refused with the value that breaks it.
The check has three verdicts, and only one of them compiles:

- **proven** — true for every value of the unknowns;
- **refuted** — false for some value, and that value is given back;
- **unproven** — the laws do not decide it, and the code is refused. Syntact never
  guesses.

## Made for models

A model writes code well. Proofs are where it struggles: a proof is a search, and a
search burns tokens and hours. Syntact splits the work where it belongs:

- **you** state the laws, as colors: what must hold;
- **the model** writes the code: what it already knows how to do;
- **the compiler** proves it, or hands back the counterexample — exactly what the
  model needs for its next try.

No proof file beside the code: the laws are the colors, in the code. No proof search,
no solver that times out, no tactic to guess. The check is the algebra:
deterministic, the same answer every time. Write the colors, let the model write the
code. If it compiles, it ships.

---

## One algebra

The code can prove itself because, in Syntact, programming is one algebra, and that
algebra is an algebra of types.

- **A value is a type.** The type of `5` is `5`. `u8` is `0..255`, the `|` of 256
  values.
- **Types combine by laws:** `|`, `&`, `~`, ranges, `+ - * /` on every primitive,
  strings by concatenation and repetition. Logic is the same algebra: `&` is *and*,
  `|` is *or*, `~` is *not*.
- **A type can have unknowns.** It is then an equation, and it keeps what they share:
  `a - a` is `0`, not `-255..255`.
- **A program is a scope, and a scope is a type.** A scope `{…}` is a system of
  equations; an access, a collapse `!`, a carve `s{x -> w}` and a pattern are laws.
  The type of a program is its normal form.

So there is one computation: simplify. **Typing** is that computation. **Proving** is
that computation. **Running** is what is left once the inputs are the only unknowns:
the residual program, the code to generate. There is no type checker beside the
compiler, and no prover beside the type checker.

Any type can be a color, and any color is a claim:

```syntact
u8:a -> ??
u8:b -> ??
u16:p -> a * b                     // proven: a product of two u8 fits in a u16
u8:q -> a * b                      // refused

Email -> 'a'..'z' * 1.. + '@' + 'a'..'z' * 1.. + '.' + 'a'..'z' * 2..
Email:ok -> "jo@mail.fr"           // proven
Email:bad -> "jo@mail"             // refused

Array -> {
  T -> {}
  -> {}
  -> {T: ...Array{T}:}
}
Array{u8}:xs -> {1 2 3}
ys -> xs{300}                      // refused: 300 is not in 0..255
```

What follows from it:

- **No function.** You hold the code itself, never a black box: see below.
- **No separate type language.** A color is any type: `u8:x`, `(0..10 | 100):x`,
  `{u8: string:}:p`, `Array{u8}:xs`, `Email:e`.
- **No null.** `none` is the empty type. A binding without a value has its default.
- **No generic syntax.** A hole `T <- …` is filled where the scope is used.
- **No proof system.** A color is the proof obligation; the check discharges it.

---

## Homoiconic, the right way

A function is a black box. Once it is defined, all you can do is call it: its body
is hidden behind its signature, and its type, `i32 -> i32`, only approximates what it
does. Everything built on functions — closures, methods, interfaces, callbacks —
hides code behind something opaque, and then the compiler spends its time trying to
see through it again.

Syntact has no function. A computation is a scope: bindings and a production. A scope
is a value, and that value is the code itself, as written. You never hold anything
opaque. You hold the code, and every operation on it is a law of the algebra:

```syntact
square -> {
  i32:n -> 0
  -> n * n
}

square{n -> 5}!     // carve, then collapse: 25
square!             // every binding has its default, so a scope always runs: 0
five -> square{n -> 5}
five.n              // still code, read like code: 5
five!               // 25
```

Lisp made code data, but data without meaning: a list of symbols that a macro
rewrites before anything is known about it — and once evaluated, a lambda is as
opaque there as anywhere else. In Syntact the code is a value of the algebra, with
its meaning. A carve is the same scope with one equation replaced, checked where it
is written. A collapse is its normal form. The program and the compiler handle the
same thing, the code, and both see all the way through it.

What a function does, a scope does in the open:

- **a call** is a carve, then a collapse: `square{n -> 5}!`;
- **a partial application** is a carve alone: `square{n -> 5}` is still code;
- **a generic** is a hole `T <- …`, filled where the scope is used;
- **a closure** is a scope that reads the bindings written above it.

This is why the code can be the proof: the compiler never reasons on a signature, it
reads the code. `unpack{pack{n}!}!` is not two opaque calls. It is `pack` and `unpack`
themselves, put together and simplified, and the law `n:` is what is left. And this is
why the code is fast: there is no abstraction barrier to remove, because nothing was
ever hidden behind a call.

---

## Effects are in the type, and the type is the program

Lisp's code-as-data is blind to effects. Any function can print, write a file or send
a request, and nothing in the code says so: a list of symbols does not know what it
does to the world. A Lisp program can rewrite its code, but it cannot know what that
code does.

In Syntact, an effect is a term of the algebra. `!?` is the outside — an input, a
system call, a C function — and it is part of the type: `!?::u8` gives back a value of
`u8` not known yet, and wraps everything that follows it. The laws simplify everything
an effect wraps, and never the effect itself: no law copies, erases or reorders one.

```syntact
read -> {u8:r -> !?  -> r}

once -> {a -> read!  -> a - a}!    // ε0(x::u8, 0)
twice -> read! - read!             // ε0(x::u8, ε0(y::u8, x - y))
```

`a - a` is `0`, and the subtraction is gone, but the read stays: it happens.
`read! - read!` is two reads, kept in the order they are written.

So the type of a program is the program:

```syntact
sum -> {
  u8:n -> ??
  -> n ? {0 -> 0  -> n + sum{n -> n - 1}!}
}

-> {u8:r -> !?  -> sum{n -> r}!}!  // ε1(x::u8, (x + x * x) / 2)
```

Read a `u8`, sum up to it. The type of this program is one read, then a closed form.
Nothing else is left, and nothing else runs. Compiling is typing: what the compiler
emits is that normal form, the effects in their order, and the pure computation
between them already simplified.

Calling C is an effect like any other. The call is in the type, and what it gives back
is a value of its color, checked like any other:

```syntact
libm -> <libm.so.6>{
  sqrt -> {f64:x, -> !?::f64}
}
root -> libm.sqrt{x -> 2.0}! * 2.0   // ε<sqrt{x -> 2.0}!>(x::f64, x * 2.0)
```

**Handlers are context, at no cost.** An event, emitted with `>-`, is answered by a
handler, `-<`, found when the program is typed and never at run time: nothing is
passed, and an emission costs what its handler costs. A logger, an allocator or a test
double is a handler put around a computation, and the same code collapsed somewhere
else is answered by another one.

This is what homoiconicity was for. The code is a value, and its type is its normal
form. With the effects in it, that normal form is the whole program: what it
computes, what it does, and in what order. The compiler, the prover and the optimizer
all read that one thing.

---

## And it is fast

**The proof makes the code.** What the compiler proved, the code knows. A bound that
is proven is a check the code never makes. A value proven to fit in 32 bits is
computed in 32-bit lanes. A loop solved to its closed form is no longer a loop. A
division by a constant, on proven bounds, is a multiplication. The type of a program
is what is left to run:

```syntact
_fib -> {
  n -> 2  i -> 2  prev -> 0  cur -> 1
  -> i ? {<n -> _fib{n i+1 cur cur+prev}!  -> cur}
}
fib -> {
  n -> 0
  -> n ? {<2 -> n  -> _fib{n+1}!}
}
-> fib{??::u8}!          // ?0 ? {..1 -> ?0  -> _fib{n -> ?0 + 1}!}
```

**A second algebra picks the cheapest program.** Its objects are computations, and
its normal form is the computation of least cost on the machine: vectorization,
strength reduction, closed forms of loops, a branch or a select — laws chosen by cost,
not passes run in some order. On our benchmarks, Syntact's x86-64 code is already on
par with `gcc -O3`.

**Memory without a garbage collector.** Nothing in the algebra is ever modified, and
nothing is shared behind your back: where a value lives and when it dies is known when
the program is compiled. No collector, no `free`, no lifetimes to annotate. Allocation
itself is an event: an arena, a pool or the stack is the handler you put around a
computation.

**Parallel and GPU, by the collapse.** A computation is never declared async, parallel
or GPU-aware. How it runs is chosen where it is collapsed, and the same scope can run
differently in different places:

```text
work!       in sequence
work<!>     on another thread
work[!]     in parallel, on the CPU
work(!)     in the background
work|!|     on the GPU
```

---

## Status

| Part | State |
|---|---|
| [`specs/types.md`](specs/types.md) | the algebra: the reference. Where another document disagrees, it wins |
| `kernel/` | the algebra, implemented: the check is the proof. Recursions solved to their closed forms (sums of powers, C-finite sequences, Arden), strings as sets, holes, effects and handlers |
| `code/` | the residual program as code: a bytecode that keeps what the kernel proved of each value, the algebra of computations (`code/calc`), executables for x86-64 Linux (`code/x64`), and C (`code/c`) |
| `lsp/` | diagnostics, the type of any expression on hover, and completion, from the kernel |
| `syntax/` | the parser |

Next: **Syntact written in Syntact.** Then state and reactivity, parallel and GPU
collapses, and arm64.

---

## Building

```sh
odin build kernel/cmd -out:kernel.bin
./kernel.bin program.syn                  # the type of each binding, then the errors
odin test kernel                          # the cases of the spec, and the corpus

odin build lsp -out:lsp/lsp               # the language server

odin build code/cmd -out:code.bin
./code.bin program.syn                    # the code of the program, as the normal form of its computations
./code.bin program.syn -l                 # the code as the kernel lowers it, before
./code.bin program.syn -o program         # an executable for x86-64 Linux
./program 10                              # its unknowns `??`, in order, on the command line
./code.bin program.syn -c program.c       # the program as C: cc -O3 program.c -o program
odin test code && odin test code/calc && odin test code/x64 && odin test code/c   # the code of each case, its normal form, then the executables of each backend run

odin test test/parse                      # the parser
odin test code/x64/asm                    # the encoder, against GNU as
```

## Repository

```
specs/types.md       the algebra
specs/language/      the language, chapter by chapter
docs/                design notes outside the language: SDK, targets, ABI, interop
syntax/              the parser
kernel/              the algebra, implemented
code/                the code of a program, and its executables
lsp/                 the language server
test/                the corpus and the suites
```
