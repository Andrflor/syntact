# Syntact

> **The code is the proof.**

Machines already write the code. Your tests check ten values of it. Syntact checks
all of them, and shows you the one that breaks.

```syntact
abs -> {
  i32:n
  -> n ? {<0 -> 0 - n  -> n}
}

i32:n -> ??                    // ?? = any value of its type
i32:r -> abs{n}!               // ! = run it
// refused: not an i32 when n is -2147483648
```

- **No proof to write.** The code is the proof.
- **Never assumed.** A claim is proven for every value, or refused, with the value
  that breaks it.
- **As fast as C, or faster.** What is proven is never checked at run time.
- **No memory to manage.** No GC, no `free`, no lifetimes.
- **Parallel or GPU, at the call:** `work[!]`, `work|!|`.

## The code is the proof

```syntact
sum -> {
  u64:n
  -> n ? {0 -> 0  -> n + sum{n -> n - 1}!}
}

u64:n -> ??
true:gauss -> sum{n}! * 2 = n * (n + 1)   // proven, for every u64
```

No value is tried. The recursion is solved to `(n + n²) / 2`, and the law reduces to
`true`. No lemma, no induction, no tactic.

A **color** is the type before a name: `u64:n`, `true:gauss`. It is the claim, and the
code proves it.

**Curry–Howard, by normalization.** There is no proof term to write and then erase:
the normal form of the program is both the proof and the code that runs.

| | Lean · Rocq · Bend 2 | Dafny · F* · Liquid Haskell | Syntact |
|---|---|---|---|
| You write | code, laws, proofs | code, specs, hints | code and its colors |
| Checked by | tactics | an SMT solver, which may time out | the algebra: same verdict every time |
| On failure | the proof does not close | unknown, or a timeout | the value that breaks it |

## Made for models

```text
you        m: -> decrypt{encrypt{m}!}!     the law, one line
model      writes encrypt and decrypt
compiler   refused: the value that breaks it
model      fixes the code, never a proof
compiler   proven. It ships.
```

## Fast

What is proven, the code uses: no check on a proven bound, 32-bit lanes where values
fit, a closed form instead of a loop. Then a second algebra picks the cheapest equal
program.

```syntact
fib -> {
  u8:n
  -> n ? {<2 -> n  -> fib{n -> n - 1}! + fib{n -> n - 2}!}
}
```

| `fib(45)`, n given at run time | |
|---|---|
| C, clang -O3 | 2.9 s |
| Syntact | **3 ms** |

clang runs the recursion. Syntact solves it.

## How

- **A value is a type.** `5` is a type, and `u8` is `0..255`. `&`, `|` and `~` are *and*,
  *or* and *not*.
- **Unknowns make equations.** `a - a` is `0`, not `-255..255`.
- **No function, just the code.** A function is a black box. A scope is the code
  itself, carved and run in the open: homoiconic, the right way.
- **Effects are in the type.** `!?` is the outside. The laws simplify around it, never
  through it, so the type of a program is the program.

```syntact
square -> {
  i32:n
  -> n * n
}
five -> square{n -> 5}            // still code: five.n is 5
five!                             // 25

read -> {u8:r -> !?  -> r}        // !? = the outside
once -> {a -> read!  -> a - a}!   // one read, and a - a is gone
```

## Why

- **The mathematicians' debt:** the function, a black box the compiler cannot see
  into.
- **The engineers' debt:** compilers full of ad hoc passes that are just algebra,
  rediscovered case by case.
- **The missing bridge:** type theory, powerful and far from everyday code.

Syntact pays all three: one algebra, as rigorous as math, as fast as C.

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
