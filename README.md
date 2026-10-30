# Syntact

> **The code is the proof.**

Machines already write the code, and nobody reads it. Syntact does not compile code
that breaks what it claims — for any value, and with no proof to write.

- **Proven, not tested.** Every claim holds for all values, or the compiler shows the
  value that breaks it.
- **No proof to write.** The code is the proof.
- **As fast as C, or faster.** A naive `fib(45)`: 3 ms, against 2.9 s with clang -O3.
- **No memory to manage.** No GC, no `free`, no lifetimes.
- **Parallel or GPU, at the call:** `work[!]`, `work|!|`.

## Why

**The mathematicians' debt.** The first programmers were mathematicians, and they
gave us the function: a black box from inputs to outputs. That is fine on paper. On a
machine, the compiler cannot see inside it and its type only approximates it.
Everything built on it — methods, closures, interfaces, callbacks — hides more code.

**The engineers' debt.** Then programmers stopped being mathematicians. Compilers grew
hundreds of ad hoc passes that are just algebra, rediscovered one case at a time.
Languages piled up layers: VMs, garbage collectors, frameworks on frameworks. Python
is glue over C, and JavaScript was designed in ten days. "Developer experience" made
the first line cheap and every line after it expensive. Machines got a thousand times
faster, and software got slower. Now models trained on that code write more of it.

**The missing bridge.** Type theory has never been so powerful, nor so far from
software. Lean and Rocq speak to mathematicians. Mainstream languages are built
without the math. Nobody joined the two.

Syntact pays both debts: one algebra, as rigorous as mathematics, compiled as fast as
C. Nothing hidden, no layer to pay for, no type that lies.

## The code is the proof

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
n:roundtrip -> unpack{pack{n}!}!   // proven, for all 65 536 values
```

`n:` is the law: `roundtrip` gives back `n`. No lemma, no induction, no tactic.

Wrong code does not compile, and the compiler says why:

```syntact
abs -> {
  i32:n -> ??
  -> n ? {<0 -> 0 - n  -> n}
}

n -> ??::i32
i32:r -> abs{n}!   // refused: not an i32 when n is -2147483648
```

**Curry–Howard, the other way round.** Proof assistants make you write a second
program, the proof, and then erase it. In Syntact, the program that runs is the proof.

| | Lean · Rocq · Bend 2 | Syntact |
|---|---|---|
| You write | code, laws, proofs | code and its colors |
| Recursion | an induction, by hand | solved to its closed form |
| When it fails | the proof does not close | the value that breaks it |

## Made for models

A law is one line:

```syntact
m -> ??::string
m: -> decrypt{encrypt{m}!}!   // what is encrypted, decrypted, is m again
```

- **You** write the law.
- **The model** writes `encrypt` and `decrypt`.
- **The compiler** proves the law for every string, or returns the one that breaks it.

No proof search, no solver that times out. If it compiles, it ships.

## One algebra

- **A value is a type.** The type of `5` is `5`. `u8` is `0..255`.
- **Logic is the algebra.** `&`, `|` and `~` are *and*, *or* and *not*.
- **Unknowns make equations.** `a - a` is `0`, not `-255..255`.
- **A program is a type.** Its normal form is both the proof and the code to run.

## Code, not functions

A function is a black box: you only see its signature. A scope is the code itself.
This is homoiconicity done right: the compiler reads the code, and never guesses from
a signature.

```syntact
square -> {
  i32:n -> 0
  -> n * n
}

five -> square{n -> 5}   // still code
five.n                   // 5
five!                    // 25
```

## Effects are in the type

In Lisp, code is data, but its effects are invisible. In Syntact, an effect `!?` is
a term of the algebra. The laws simplify around it, never through it:

```syntact
read -> {u8:r -> !?  -> r}
once -> {a -> read!  -> a - a}!   // ε0(x::u8, 0): one read, and no subtraction
```

The type of a program is the program.

## Fast

**The proof makes the code:**
- proven bounds mean no checks;
- values proven to fit in 32 bits run in 32-bit lanes;
- a recursion solved to its closed form is no longer a loop.

Fibonacci, written naively:

```syntact
fib -> {
  u8:n -> ??
  -> n ? {<2 -> n  -> fib{n -> n - 1}! + fib{n -> n - 2}!}
}
```

With n = 45 given at run time, it takes **3 ms** in Syntact and **2.9 s** in C with
clang -O3. clang runs the recursion. Syntact solves it.

A second algebra then picks the cheapest equal program. On our benchmarks, it is
already on par with `gcc -O3`.

```text
work!     in sequence        work<!>   on a thread
work[!]   in parallel        work|!|   on the GPU
```

## Status

| Part | State |
|---|---|
| `kernel/` | the algebra and the check |
| `code/` | x86-64 and C backends |
| `lsp/` | diagnostics, hover, completion |
| **Next** | Syntact written in Syntact |

The reference is [`specs/types.md`](specs/types.md).

## Build

```sh
odin build kernel/cmd -out:kernel.bin && ./kernel.bin program.syn    # check
odin build code/cmd -out:code.bin && ./code.bin program.syn -o prog  # compile
odin test kernel                                                     # test
```
