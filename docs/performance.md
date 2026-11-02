# Why this should be fast

> Rationale, and benchmarks. The numbers under "Measured today" are those of the current
> backend (`code/`); those further down are of the previous pipeline (analyze → reduce →
> bytecode → x86-64), kept for the record. The language itself is in `specs/`.

## Measured today

On an Intel Xeon at 2.1 GHz, 4 cores, in a shared VM: expect noise of ±20%.

**A recursion the laws solve.** `fib` written naively (README), `n` given at run time,
against the same naive recursion in C:

| `fib(45)` | |
|---|---|
| C, clang -O3 | 3.6 s |
| Syntact, x86-64 | 3 ms |

The time is the start of the process: the kernel solves the recursion to a C-finite
sequence, computed in O(log n).

**Loops the laws do not remove.** `code/bench`: a loop over n down to 0, its accumulator
taking a step at each turn, n = 300 000 000; against the same loop written naively in C,
and against the program as C (`code/c`), without and with lanes, all at clang -O3:

| | x86-64 | C naive | C normal | C lanes | ÷ naive | ÷ best |
|---|---|---|---|---|---|---|
| remainders `acc + n % 7` | 247 ms | 167 ms | 285 ms | 515 ms | 1.48 | 1.48 |
| masks `acc + (n [&] 255) * 3` | 130 ms | 84 ms | 209 ms | 109 ms | 1.54 | 1.54 |
| squares `acc ^ (n * n + 12345)` | 104 ms | 139 ms | 101 ms | 186 ms | 0.75 | 1.04 |
| quotients `acc ^ (n / 10)` | 236 ms | 117 ms | 147 ms | 152 ms | 2.01 | 2.01 |
| branches `acc + ((n % 3) ? {0 -> n  -> 1})` | 399 ms | 218 ms | 240 ms | 718 ms | 1.83 | 1.83 |
| bytes `acc ^ ((n [&] 255) * 3)` | 64 ms | 83 ms | 208 ms | 53 ms | 0.77 | 1.20 |

÷ is the time of x86-64 over the other: below 1, Syntact is faster. Where nothing is
solved, the x86-64 backend is not yet at the level of clang on a plain loop: up to twice
slower on a division or a remainder by a constant, and on a branch in the loop.

## Why

Traditional languages create abstraction barriers, then optimizers try to remove them.

A function call hides a body. A method hides a function behind a receiver. A trait or interface hides an implementation. A closure hides capture. A dependency hides behind a parameter. A framework hides control flow.

Syntact exposes more structure directly.

When you write:

```syntact
square{n -> 5}!
```

you are asking the compiler to reduce the scope `square` under a known carved binding.

When you write:

```syntact
WithArena -> {
  Alloc -< e {
    -> arena.alloc{e.size}!
  }

  -> parse!
}
```

you are asking the compiler to reduce `parse` under a known interpretation of `Alloc`.

The compiler sees:

```text
bindings
defaults
carvings
productions
constraints
handlers
collapse points
```

It does not need to rediscover all of that through a maze of functions, objects, interfaces, and runtime configuration.

The collapse operator is therefore not just execution syntax. It is an optimization request:

> reduce everything that can be reduced, and keep only what must remain.

The ambition is to write extremely high abstractions and pay only for the machine work that survives reduction.

This is not just an aspiration — it is what the previous pipeline already did. A program that stacks dozens of multiplications, distributions, cancellations, and telescoping sums over three runtime arguments:

```syntact
a -> ??::u8 ; b -> ??::u8 ; c -> ??::u8
t1 -> (a*7 + 3)*5            // and many more layers…
u1 -> 2 * (t1 - 5*a)
v1 -> u1 + a*9 - a*9 + 100 - 100
// …seventeen lines of compounding arithmetic…
-> big*2 - (big + 7) + 8
```

reduces to its minimal affine form `60·a + 78·b + 40·c`, and the x64 backend emits the arithmetic core a production C compiler at `-O3` would — all 32-bit, every multiply by a constant folded into `imul`/`lea`, the additions fused into address-mode `lea`, no spills, no wasted moves. The abstractions cost nothing; only the surviving computation is paid for.

Benchmarked against the exact C equivalent (`return 60*a + 78*b + 40*c;`) on the same inputs:

| | Syntact | gcc -O3 | clang -O3 |
|---|---|---|---|
| **arithmetic core** | `imul`+`lea`, 8 insns | equivalent | equivalent |
| **binary size** | **472 B** | 15 976 B | 15 984 B |
| **process startup** (hyperfine) | **152 µs** | 450 µs | 462 µs |
| **compile time** — to a runnable executable (hyperfine `-N`) | **5.3 ms** | 36.9 ms | 52.1 ms |
| **compile time** — front-end + optimizer only (`-c`, object, not yet runnable) | — | 24.3 ms | 26.9 ms |

The generated arithmetic is **on par with -O3** — gcc/clang do not beat the LLVM-style instruction selector. Syntact's edge is structural: no ABI, no libc, a minimal static `_start` that parses argv inline and exits by syscall. So the binary is ~34× smaller and starts ~3× faster. (The startup gap is dominated by libc init and `strtol@plt` calls, which Syntact has neither of; a heavy compute loop would close it, since the arithmetic itself is equivalent.)

On **compile time** Syntact produces a runnable ELF in ~5.3 ms — ~7× faster than gcc and ~10× faster than clang to their final executables. The fair reading is structural, not a smarter optimizer:

- **Linking is a large slice of the gcc/clang number, not parsing.** Stopping at `-c` (object file, no link) drops gcc to 24.3 ms and clang to 26.9 ms — so the link step alone is ~12.6 ms for gcc and ~25.2 ms for clang (about half of clang's total). The front end is noise in both chains: C is not "bigger to parse" than Syntact. Syntact has no separate link step, no libc, no crt — its bytecode lowers straight to a monolithic static ELF.
- **Even removing the link entirely, gcc/clang stay ~4.6–5.1× slower** (24–27 ms for an object that still needs linking, vs Syntact's 5.3 ms for a finished executable). That residual gap is their general-purpose machinery — a heavyweight IR (GIMPLE/RTL, LLVM IR) and optimization passes that run in full on even a trivial program, including overflow-absence proofs and general dataflow analysis. Syntact's reducer knows every value's range *by construction*, so there is no overflow proof to do, and there is no general IR between bytecode and ELF.

So the compile-time win is the same architectural fact as the size and startup wins — no libc/link, range known by construction — not a cleverer optimizer.

---

## A small practical comparison

A server config in a classical language often needs a class, constructor defaults, validation, and a copy method.

In Syntact:

```syntact
Port -> u16 & >0

ServerConfig -> {
  string:host -> "localhost"
  Port:port -> 8080
  bool:debug -> false
}

ServerConfig:config{port -> 3000}

prod -> config{
  host -> "0.0.0.0"
  debug -> false
}
```

No constructor. No builder. No `copyWith`. No nullable parameters. The shape and carving algebra do the work.

An endpoint should not need endpoint-specific syntax. It should be a scope shaped by a library scope.

```syntact
RestEndPoint:userEndpoint{
  path -> "/users/:id"

  get -> {
    maybeId -> Maybe{value -> req.path.get{"id"}!}!

    -> maybeId ? {
      {}: -> HttpResponse{
        status -> 400
        message -> "Invalid id"
      }

      UserId:(id) -> {
        user -> db.users.find{id -> id}!

        -> user ? {
          none -> HttpResponse{
            status -> 404
            message -> "User not found"
          }

          User:{id name} -> HttpResponse{
            status -> 200
            message -> Json.encode{value -> user}!
          }
        }
      }
    }
  }
}
```

`RestEndPoint`, `HttpResponse`, `UserId`, `Maybe`, and `Json` are scopes. The SDK should provide powerful scopes, not ad-hoc syntax.
