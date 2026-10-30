# Syntact

> **The language for the LLM era: code that proves itself.**

Machines already write the code, faster than anyone can read it, and tests check ten
values of it. Syntact checks no value at all. The compiler solves the code, and proves
that every property you wrote holds. When one does not, it refuses the code and shows
you the value that breaks it.

**Self-proving code: there is no proof to write.**

- **Made for models.** You state the properties, the model writes the code, and the
  compiler proves it.
- **Never assumed.** A property is proven on the types, or the code is refused.
- **As fast as C, or faster.** What is proven is never checked at run time.
- **No memory to manage.** No GC, no `free`, no lifetimes.
- **Parallel or GPU, at the call:** `work[!]`, `work|!|`.

## Read Syntact in 30 seconds

| You write | It means |
|---|---|
| `x -> 5` | `x` is `5` |
| `u8:x -> 5` | `x` has the type `u8`: the compiler must prove that `5` is a `u8` |
| `u8:x -> ??` | `x` is an unknown of type `u8`: an input of the program |
| `true:x -> p` | `p` must have the type `true`: the equation `p` must hold |
| `m:x -> v` | `v` must have the type `m`: be `m` itself, since an unknown is a type too |
| `{ … -> r }` | a scope: fields, each with a default value, then its result `r` |
| `square{n -> 5}` | `square`, with its field `n` replaced by `5` |
| `square{n -> 5}!` | run it |
| `n ? {<0 -> a  -> b}` | `a` when `n < 0`, `b` otherwise |
| `!?` | an effect: something that comes from outside |

## Wrong code does not compile

```syntact
abs -> {
  i32:n                        // a field: n is an i32, 0 by default
  -> n ? {<0 -> 0 - n  -> n}   // the result: -n when n < 0, n otherwise
}

i32:n -> ??                    // n is an unknown, of type i32
i32:r -> abs{n}!               // the type of abs{n}! must be inside i32
// refused: when n is -2147483648, -n is 2147483648, which is not an i32
```

There is no test here, and no value is tried. The compiler computes the type of
`abs{n}!`: where `n < 0`, `-n` has the type `1..2147483648`. That type sticks out of
`i32` by one value, and the compiler tells you where it comes from:
`n = -2147483648`. The bug every C programmer has shipped once is refused.

## Made for models

```syntact
string:m -> ??                              // m: a string, no matter which
m:roundtrip -> decrypt{encrypt{m}!}!        // decrypt{encrypt{m}!}! has the type m
```

Take a string `m`, no matter which one. The second line says that
`decrypt{encrypt{m}!}!` has the type `m`: decrypting what was encrypted gives back
`m`. That one line is the property.

The same property can be written with the type `true`, on an equation:

```syntact
true:roundtrip -> decrypt{encrypt{m}!}! = m  // the equation has the type true
```

The compiler cannot compile this program unless it proves it. It does so by symbolic
resolution: it computes `decrypt{encrypt{m}!}!` with `m` kept as a symbol, and the
result must simplify to `m`. No string is ever tried.

1. **You** write the property.
2. **The model** writes `encrypt` and `decrypt`.
3. **The compiler** proves the property, or refuses the code with the value that
   breaks it.
4. **The model** fixes its code. Nobody ever writes a proof.

## Self-proving code

```syntact
sum -> {
  u64:n                                      // n is a u64, 0 by default
  -> n ? {0 -> 0  -> n + sum{n -> n - 1}!}   // 0 + 1 + … + n
}

u64:n -> ??                                  // n is an unknown, of type u64
true:gauss -> sum{n}! * 2 = n * (n + 1)      // gauss has the type true
```

`true` is a type: the type whose only value is `true`. So `gauss` must be `true`: the
property must hold at compile time, for an `n` that can be any `u64`.

Syntact does not test the values. It solves the recursion to `(n + n²) / 2`, and the
equation reduces to `true`. There is no lemma, no induction and no tactic: the code
proves itself.

**This is Curry–Howard, the right way.** A type is a proposition, and a value of that
type is its proof. Proof assistants make you write a second program whose only job is
to be that proof. In Syntact, the program you run is the proof: the compiler computes
its normal form and checks that it has the type you wrote.

| | Lean · Rocq · Bend 2 | Dafny · F* · Liquid Haskell | Syntact |
|---|---|---|---|
| You write | code, laws, and proofs | code, specs, and hints | code and its types |
| Checked by | tactics | an SMT solver, which may time out | the algebra: the same verdict every time |
| On failure | the proof does not close | unknown, or a timeout | the value that breaks it |

## Fast

What the compiler proves, the code uses: a bound that is proven is never checked, a
value proven to fit in 32 bits is computed in 32 bits, and a recursion that is solved
is no longer a loop.

```syntact
fib -> {
  u8:n
  -> n ? {<2 -> n  -> fib{n -> n - 1}! + fib{n -> n - 2}!}
}
```

| `fib(45)`, with n given at run time | |
|---|---|
| C, clang -O3 | 2.9 s |
| Syntact | **3 ms** |

clang runs the recursion. Syntact solves it.

## Under the hood: just the algebra of types

Types are so powerful that all of mathematics can be built on them. These are not the
poor types of everyday languages, a label on a box like `int` or `string`. They are
the rich types of type theory, which say exactly what a value is: `5`, `0..255`, an
email address, `k * k`. So Syntact builds all of the code on them, and on nothing else.

Syntact is just the algebra of types. Checking, proving and compiling are one
computation: simplifying types.

And the converse is the great part: since Syntact is just the algebra of types,
Syntact is just math.

A property is the type on the left: `T:x -> v` holds when the code `v` on the right
has the type `T`. That is Curry–Howard: the type is the proposition, and the code is
its proof.

Everything is a type:
- a value: `5` is the type with one value, `5`;
- a set of values: `u8` is `0..255`;
- an unknown: `??`;
- an effect: `!?`;
- a scope, and a whole program.

Types compose by an algebra:
- `|`, `&` and `~`: *or*, *and*, *not*;
- `+`, `*` and the other operators;
- replacing a field, running, matching.

Each operation gives a type, and the operation itself, once written, is a type too.
Nothing ever leaves the algebra:

```syntact
u8:a -> ??
u8:b -> ??
u16:p -> a * b     // proven: u8 * u8 is 0..65025, inside u16
u8:q -> a * b      // refused: 0..65025 is not inside u8
```

Strings too. `'a'..'z' * 1..` is one letter or more, and `+` puts strings one after
the other:

```syntact
Email -> 'a'..'z' * 1.. + '@' + 'a'..'z' * 1.. + '.' + 'a'..'z' * 2..

Email:ok -> "jo@mail.fr"    // proven
Email:bad -> "jo@mail"      // refused: no dot after the @
```

`Email` is a type, written like a regular expression and checked at compile time.

## No functions: only code

A function is a black box: you can only call it, and the compiler only sees its
signature. Syntact has no functions. `square` is a scope, and a scope is the code
itself:

```syntact
square -> {
  i32:n           // a field, 0 by default
  -> n * n        // the result
}

five -> square{n -> 5}   // code: square, with n replaced by 5
five.n                   // 5: you can still read inside it
five!                    // 25: run it

i32:k -> ??
sq -> square{n -> k}!    // its type: k * k
```

**Homoiconic, with types instead of lists.** In Lisp, code and data share one
representation: the list, which means nothing by itself.

In Syntact, the one representation is the type:
- the code you write is a type;
- every composition of types is a type: replacing a field, running, matching;
- the code that runs is a type: what is left of the program once it is simplified.

The type of `square{n -> k}!` is `k * k`, and `k * k` is also the code that runs.

Lisp's code is data. Syntact's code is types, and that is why the compiler can prove
things about it.

## Effects are in the type

An effect, `!?`, is anything that comes from outside: an input, a system call, a C
function. It is part of the type, in the order it is written. The compiler simplifies
everything around an effect, but never removes, copies or reorders one.

Calling C is an effect:

```syntact
libm -> <libm.so.6>{                  // the C math library
  sqrt -> {f64:x, -> !?::f64}         // its sqrt: an f64 in, an f64 from outside
}

y -> libm.sqrt{x -> 2.0}! * 2.0       // call C, then * 2.0
```

The type of `y` is the call to `sqrt`, then `* 2.0` on its answer.

A C function with no side effect can return an unknown, `??::f64`, instead. The
compiler may then move the call, or erase it when nothing reads it. An effect, never:

```syntact
read -> {u8:r -> !?  -> r}        // read a u8 from the outside
once -> {a -> read!  -> a - a}!   // one read, then 0: a - a is gone, the read stays
```

So the type of a program is what it does: its effects, in order, and what it computes
between them, already simplified. Compiling is typing.

## Why

- **The mathematicians' debt.** They gave us the function, a black box the compiler
  cannot see into.
- **The engineers' debt.** Compilers are full of ad hoc passes that are just algebra,
  rediscovered case by case.
- **The missing bridge.** Type theory is powerful, but it is far from everyday code.

Syntact pays all three: one algebra, as rigorous as math, as fast as C.

## Status

| Part | State |
|---|---|
| `kernel/` | the algebra and the check |
| `code/` | x86-64 and C backends |
| `lsp/` | diagnostics, hover, completion |
| **Next** | Syntact written in Syntact |

The reference is [`specs/types.md`](specs/types.md).

## Try it

```sh
odin build code/cmd -out:code.bin                # the compiler, built with Odin
echo '-> "Hello, world"' > hello.syn
./code.bin hello.syn -o hello && ./hello         # Hello, world
```

- `./code.bin program.syn` shows the code a program compiles to.
- A program's unknowns `??` are its inputs, given on the command line: `./prog 10`.
- `odin build kernel/cmd -out:kernel.bin`, then `./kernel.bin program.syn`, prints the
  type of each binding, then the errors.
