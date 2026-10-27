# Syntact

> Programming is one algebra, and that algebra is an algebra of types.

---

## The idea

A value is a type: the type of `5` is `5`. `u8` is `0..255`, the `|` of 256 values.
Types combine by laws — `|`, `&`, `~`, ranges, `+ - * /` on every primitive,
strings by concatenation and repetition — and each law is an equation between types.

A type can have unknowns. `??::u8` is one value of `0..255`, not known yet. A type is
then an equation over its unknowns, and it keeps what they share:

```syntact
a -> ??::u8
c -> a + 3      // ?0 + 3
d -> a - a      // 0, not -255..255
```

Structure is in the algebra too. A scope `{…}` is a sequence of bindings, each an
equation `C:x -> v`. Its operations are laws: an access reads a binding, a collapse
`!` reads the production, a carve `s{x -> w}` is the same scope with one equation
replaced — a copy with substitution —, and a pattern `t ? {c -> p …}` is a type like
`|`. A program is a scope, so a program is a type.

Its type is its normal form: the equation that is left once the laws have
simplified what they can. That one computation is all there is:

- **typing** — `C:x -> v` asks `v in C`. It is proven, refuted with a witness, or
  not proven, and then refused;
- **proving** — a color is a claim. A file that is accepted has its claims proven:
  there is no separate proof language;
- **running** — what stays in the normal form depends only on the unknowns, the
  inputs. It is the residual program: the code to generate.

The algebra is written in [`specs/types.md`](specs/types.md). It is the reference:
where another document disagrees, it wins.

---

## Examples

A recursion is never unfolded. It is solved, or it stays an equation:

```syntact
sum -> {
  u8:n -> ??
  -> n ? {0 -> 0  -> n + sum{n -> n - 1}!}
}
total -> sum!            // (?0 + ?0 * ?0) / 2: its closed form
five -> sum{n -> 5}!     // 15
```

A color is proven for every value of the unknowns:

```syntact
u8:a -> ??
u8:b -> ??
u16:p -> a * b           // proven: every product of two u8 is a u16
u8:q -> a * b            // refused: not proven to be in 0..255
```

A shape is a type, recursion included, and a carve is checked against it:

```syntact
Array -> {
  T -> {}
  -> {}
  -> {T: ...Array{T}:}
}
Array{u8}:xs -> {1 2 3}
ys -> xs{300}            // refused: 300 is not in 0..255
```

A string type is a set of strings:

```syntact
Email -> 'a'..'z' * 1.. + '@' + 'a'..'z' * 1.. + '.' + 'a'..'z' * 2..
Email:ok -> "jo@mail.fr"
Email:bad -> "jo@mail"   // refused
```

And the type of a program is what is left to run:

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

---

## What follows from it

- **No function.** A computation is a scope with a production. It is called by
  carving it and collapsing it: `square{n -> 5}!`. A scope is always complete:
  every binding has a value, its default, so `square!` is a value too.
- **No separate type language.** A color is any type: `u8:x`, `(0..10 | 100):x`,
  `{u8: string:}:p`, `Array{u8}:xs`, `Email:e`.
- **No null.** `none` is the empty type. A binding without a value has its default.
- **No generic syntax.** A hole `T <- …` is filled where the scope is used.
- **No proof system.** A color is the proof obligation; the check discharges it.
- **Effects are explicit.** Events and handlers (`>-`, `-<`) are the only place where
  the outside is reached; state changes only through resonance.

---

## Status

| Part | State |
|---|---|
| [`specs/types.md`](specs/types.md) | the algebra: the reference |
| `kernel/` | the algebra on its terms: the typecheck, holes included. Every case of the spec passes, and the corpus cases whose forms it builds, but for five that contradict the spec. The cast `\` and events are not built yet |
| `lsp/` | diagnostics, the type of any expression on hover, and completion, from the kernel |
| `syntax/` | the parser, used by everything |
| `code/` | the normal form of a program as code: a bytecode, its interpreter, and executables for x86-64 Linux (`code/x64`, on the encoder, the ELF writer and the System V ABI of `code/x64/asm`). Scopes as values, arguments on the stack and `f32` are not code yet |

Next: effects and state in the algebra, then the residual program to bytecode.

---

## Building

```sh
odin build kernel/cmd -out:kernel.bin
./kernel.bin program.syn                  # the type of each binding, then the errors
odin test kernel                          # the cases of the spec, and the corpus

odin build lsp -out:lsp/lsp               # the language server

odin build code/cmd -out:code.bin
./code.bin program.syn                    # the code of the program
./code.bin program.syn -o program         # an executable for x86-64 Linux
./program 10                              # its unknowns `??`, in order, on the command line
odin test code && odin test code/x64      # the code of each case, then the executables run

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
