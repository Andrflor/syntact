# Syntact ↔ external world — state, open questions, remaining work

> Working notes. What the external boundary does today, what it cannot do yet, and the
> design questions still open. Decisions marked **OPEN** are deliberately not taken.

---

## 1. What works today

The `<lib>{}` boundary parses, analyzes, reduces, and produces working executables.
**No external linker is invoked** — the compiler writes every byte of the ELF, including
the dynamic tables `ld` would normally emit.

```syntact
libm -> <libm.so.6>{
  sqrt -> {
    f64:x
    -> ??::f64
  }
}
-> libm.sqrt{x->2.0}!        // → 1.414213
```

### Verified against 7 real libraries

| Library | Call | Result | Exercises |
|---|---|---|---|
| `libm.so.6` | `sqrt(2.0)` | `1.414213` | 1 float arg |
| `libm.so.6` | `pow(2.0,10.0)` | `1024.0` | 2 float args (`xmm0`,`xmm1`) |
| `libm.so.6` | `cos(0.0)` | `1.0` | — |
| `libc.so.6` | `abs(-42)` | `42` | int arg (`rdi`) |
| `libz.so.1` | `compressBound(1000)` | `1013` | `u64` |
| `libcrypto.so.3` | `OPENSSL_version_major()` | `3` | **zero args** |
| `libpcre2-8.so.0` | `pcre2_config(0,NULL)` | `4` | 2 int args, NULL pointer |
| `libasound.so.2` | `snd_asoundlib_version()` | non-null | **opaque handle return** |
| `libSDL2-2.0.so.0` | `SDL_GetTicks()` | runs | heavy transitive deps |

Also verified:

- **Nested foreign calls** — `sqrt(pow(3,4))` → `9.0`, two GOT slots, one `DT_NEEDED`.
- **Two different libraries in one binary**, chained — `compressBound(OPENSSL_version_major())` → `16`, two `DT_NEEDED`.
- **Transitive dependencies resolve themselves** — declaring only SDL2 pulls `libc.so.6`
  via SDL2's own `DT_NEEDED`. No manual dependency list, unlike the static (`.a`) case.
- **No library is privileged** — the compiler contains no mention of any library name;
  the provenance travels as an opaque string into `.dynstr`.
- **Pure programs stay static** — no `<lib>` in the source ⇒ no `PT_INTERP`, no
  `.dynamic`, single `PT_LOAD`; `ldd` reports "not a dynamic executable".

### How it is wired

| Piece | Where |
|---|---|
| `Foreign` AST node, `Foreign_Data{lib, scope}` | `compiler/ast.odin` |
| `scan_lib_path` / `try_parse_foreign` (prefix position only) | `compiler/parse.odin` |
| `walk_foreign`, provenance stamped on the scope | `compiler/analyze.odin` |
| `foreign_lib` on `Scope_Type` — **the effect marker** | `compiler/ir.odin` |
| `Foreign_Call_Type` residual node | `compiler/ir.odin` |
| `foreign_call_of` / `holds_foreign_collapse` | `compiler/reduce.odin` |
| `BC_Import`, `BC_Foreign_Call`, `bc_intern_import` | `compiler/bytecode/bytecode.odin` |
| `emit_foreign_call` — System V args + `call [GOT]` | `compiler/backends/x64/emit.odin` |
| `.interp/.dynstr/.dynsym/.hash/.rela/.dynamic` | `compiler/backends/x64/elf_dynamic.odin` |
| `PT_INTERP`/`PT_DYNAMIC`, GOT layout | `compiler/backends/x64/elf.odin` |

Two non-obvious things that cost debugging time, worth not re-discovering:

1. **`DT_PLTGOT` must point at a 3-entry reserved header**, not at slot 0. The ABI has the
   loader write its own bookkeeping there.
2. **`DT_JMPREL` is the wrong tag here.** It declares *PLT* relocations, tied to the
   lazy-binding machinery (a PLT stub per symbol, a resolver trampoline) — none of which
   exists in this design, since the call goes straight through the GOT. The right tag is
   **`DT_RELA` with `R_X86_64_GLOB_DAT`**: ordinary relocations, applied unconditionally
   at load time. `DT_BIND_NOW` was solving the wrong problem.

---

## 2. The open design question: addresses

**No pointer type in the language.** The README already fixes this (§ "No glue"):

> there is no pointer type in the pure language; the pointer only appears in boundary
> codegen, derived mechanically by a size rule (a value larger than a register is passed
> by address, otherwise by value).

So the size rule covers `String`/array/scope automatically, with nothing written by the
user. What remains open is everything the size rule does *not* cover.

### The sketch under consideration

```syntact
Address -> {
  T <- {}
  value =<< T:
}
```

What each piece does:

- `T <- {}` — the generic hole: *address of what*. Filled at the use site or inferred.
  Gives typing without a primitive pointer type (§ "Pull bindings and genericity").
- `T:` — a colored constraint, unnamed: "a value shaped like `T`", not a stored value.
- `=<< ` — a **reactive** production. `value` is not a copy, it is a link that
  re-evaluates. **Dereferencing is re-evaluation** — this is the part that feels right,
  and it is not a hijack of the operator: the README already glosses `=<<` as binding
  "by reference" (`T:value >>- Update =<< initial`).

### Why it feels half-right — the useful distinction

A C pointer does two jobs that Syntact deliberately separates:

| Job | Syntact mechanism |
|---|---|
| read through | reactivity (`=<<`) — the sketch handles this |
| write through | mutation ⇒ resonance (`>>-`/`-<<`) ⇒ a **named event** |

So the sketch is not flawed; "pointer" is a *fused* concept that this semantics
decomposes. That is arguably a good sign, but it means one `Address` is probably not
enough — either two forms, or one parameterized by direction.

### The sharper cut: variable vs fixed

**This is the distinction that unblocks the problem.**

| Case | What it needs | Status |
|---|---|---|
| **fixed address, read** (literal in `.rodata`, global, fixed cell) | the address as a constant | implementable, **nothing to decide** |
| **opaque handle** (`FILE*`, SDL handle) — received and handed back, never dereferenced | a `u64` with no read semantics | **already works** (`snd_asoundlib_version`) |
| **variable pointer, dereferenced** | cell identity, aliasing, validity | this is what `Address` is for |

Only the third case genuinely requires a language decision — and it is the *rarest* at the
boundary. Most C APIs hand back opaque handles or take buffers whose location the caller
fixes.

### OPEN questions

- **Q1.** Does the sketch need to denote the address *number* at all? Nothing in it does.
  That may be intentional (the number is precisely what the pure language must not see).
  But then: what carries **cell identity** in the IR, so two distinct `Address` values are
  not structurally equal?
- **Q2.** Write direction. Is an output buffer a resonant `Address` (mutation via named
  event), which would be consistent with "mutable state goes through an event"?
- **Q3.** Is `Address` **additive** (covering only what the size rule misses: address of a
  scalar, output buffers) or the **canonical form** replacing the size rule and made
  visible in the language? Both defensible; they lead to different compilers. The first is
  purely additive, the second changes what `String:buf` means at the frontier.
- **Q4.** Is memory access a **value** or an **effect**? The README already treats
  *obtaining* memory as an event (`ptr -> >- Alloc{size -> size}`, resolved by the
  enclosing scope). If that holds for obtaining it, maybe writing through the frontier is
  an event too — a `Write` the scope resolves — rather than a pointer passed around. This
  may be why the sketch feels half-wrong: it makes an address a *value* while the rest of
  the design treats memory access as an *effect*.
- **Q5.** Ownership / lifetime. `strdup` returns memory to free; `fopen` a handle to close.
  Does this belong to the boundary at all, or to the handler/event layer?

*(Allocation itself deliberately set aside for now.)*

---

## 3. Remaining work — mechanical, no design decision needed

- **More than 6 arguments** → stack passing. Note: this also perturbs the stack-alignment
  arithmetic in `emit_foreign_call`, currently correct only because the push/pop pairs are
  balanced.
- **`sret`** — aggregate return > 16 bytes. The *caller* allocates and passes a hidden
  pointer in `rdi`. Needs somewhere for the buffer to live.
- **Two-register aggregates** (9–16 bytes). System V passes these in two registers; the
  README's "> register ⇒ by address" is a safe but suboptimal approximation. Only matters
  for bit-exact C interop.
- **Address of a literal** (`.rodata`) — the pure fixed case. `.rodata` already exists
  (`-> "hello"` prints `hello`), so passing that address in a register is mechanical, with
  no allocation and no ownership question. **This is the one step that opens input-pointer
  APIs (`write`, `puts`, `crc32`, `fopen`) without pre-empting any design decision.**
- **Missing types**: `isize`/`usize` are not builtins yet (README notes this); `f32`
  arguments need `cvtsd2ss`.
- **String results** currently rejected at lowering (`codegen: string results ... do not
  lower yet`).
- **Symbol-existence check at build time** — read the target `.so`'s `.dynsym` and reject
  an undeclared symbol with a compile error instead of a startup `symbol lookup error`.
  Worth noting: **signatures cannot be checked, ever** — a `.so` carries the name, address,
  size, type and version of a symbol, but *nothing* about argument or return types. So
  `sqrt -> { u8:x -> ??::u8 }` links fine and silently produces garbage. The signature is a
  user assertion, unverifiable in principle — the same `unsafe` frontier every language has.
  This check earns its keep mainly for **cross-compilation** (no first local run to catch
  it), and it needs a sysroot: verifying against the *target's* `.so`, not the host's.

---

## 4. ABI details that bite in practice

- **Symbol versioning** (`GLIBC_2.29` vs `GLIBC_2.2.5`). Observed on `pow` and `exp`, which
  exist in two versions in `libm.so.6`. Without `.gnu.version_r` the default version is
  taken; usually fine, `memcpy` is the classic counter-example.
- **Variadics** — `al` (SSE register count) is already set, which is why printf-shaped
  targets are half-ready, but they also need stack args and a register save area.
- **Structs by value** — System V's field-by-field classification (INTEGER/SSE/MEMORY) is
  the genuinely tedious part of the ABI.
- **Callbacks** (passing a Syntact function to `qsort`) — requires emitting a real function
  with prologue/epilogue, hence a call model, which the bytecode does not have yet ("the
  bytecode has no loops yet"). Large, independent piece of work.
- **Stack alignment** — correct today, fragile: a single stack-passed argument breaks it.

---

## 5. Scope and tooling

- **Interpreter path** is the constant `DEFAULT_INTERP` in `elf_dynamic.odin`. This is the
  one absolute path a dynamic executable cannot avoid — the bootstrap cannot be delegated,
  since something must start the chain and that something is a literal `open()` by the
  kernel. It is a property of the target platform (arch + libc), **not** of any library.
  Needs a `--dynamic-linker` override and/or a per-target table for cross-compilation.
  Reference points: musl x86-64 `/lib/ld-musl-x86_64.so.1`, glibc aarch64
  `/lib/ld-linux-aarch64.so.1`, Android `/system/bin/linker64`, NixOS an unpredictable
  store path.
- **Other platforms** — Windows (IAT, and a different ABI: 4 registers `rcx/rdx/r8/r9`),
  macOS (Mach-O, `dyld`). README states this is purely a backend concern.
- **`.gnu.hash`** — optional, faster than `DT_HASH`. Not needed.
- **Section headers for the dynamic tables** — cosmetic: `readelf -d` warns "no .dynamic
  section in the dynamic segment". The kernel and loader only read *segments*, so execution
  is unaffected, but `gdb` symbol handling would want them.

---

## 6. Pre-existing bugs found along the way

Both confirmed against the **unmodified** compiler (`git stash`) — neither is caused by the
foreign-boundary work, and neither depends on any design decision.

- **A scope written on one line without a comma loses its type.**
  `f -> { f64:x  -> x }` produces nothing (`result_type` = `none`); with a comma,
  `f -> { f64:x, -> x }` yields `f64` correctly. Reproduces in pure Syntact, no externals
  involved. Worth fixing early: it silently yields an empty program rather than an error,
  and it bit this session twice while testing `libm.cos`.
- **Float `??` arguments read as zero in the x64 stub.**
  `-> ??:f64 + 1.0` run with `2.5` prints `1.000000` instead of `3.5`. Integer arguments are
  fine (`-> ??:u8 + 1` with `5` exits 6). The bytecode interpreter gives `3.0` for the same
  input, so it reads the value but is not exact either. Localized to
  `emit_arg_stub`/atof around `ARGS_TABLE`.

---

## 7. Order that follows from the above

If "fully interoperable" means "call any C API on Linux":

1. **Literal address + stack args** → opens input-pointer APIs. No design decision needed.
2. **The memory question (§2)** → opens in/out pointers, i.e. most of the rest.
3. **Callbacks** → needs a call model in the bytecode. Large, orthogonal.
4. **Structs by value** → tedious, rare.

Steps 1, 3, 4 are mechanical work. Step 2 is the only one waiting on a language decision.

**What separates this from real interop is a decision, not a volume of code.**
