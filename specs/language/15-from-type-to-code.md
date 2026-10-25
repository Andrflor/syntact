# From type to code

The type of a program is its normal form: the equation left once the laws have
simplified what they can. What is left depends only on the unknowns — the inputs. It
is the program that remains to run, and the code to generate.

## What is known disappears

```syntact
greeting -> "hello"
answer -> 42
-> answer
```

The type of this program is `42`. `greeting` is not used, so nothing of it remains;
compiled, the program can be as small as:

```asm
_start:
    mov     edi, 42         ; exit code 42
    mov     eax, 60         ; exit
    syscall
```

Carves, defaults, patterns on known values, handlers known where a call is written:
what the laws reduce costs nothing at run time. What survives is what you pay.

## What depends on an input stays

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

The residual reads as code directly:

```text
?0                 the input, a u8
? {..1 -> …}       a branch on a scalar
_fib{n -> …}!      a call: a scope whose fields are its parameters,
                   and whose body is the normal form of its production
```

`_fib` is a recursion without a closed form, so it stays a call; its own body,
`i ? {<n -> _fib{…}!  -> cur}`, is a loop.

## Status

The kernel computes the normal form of a program; `kernel/cmd` prints it, and the
language server shows it for any expression. Code is not generated from it yet:
executables still come from the previous pipeline, whose benchmarks are in
[`docs/performance.md`](../../docs/performance.md). The residual program waits for the
effects (chapter 10): an emission must stay in it, in order, and the handler that
serves it depends on the context of the call.

---

[← Modules](14-modules.md) · [Index](README.md)
