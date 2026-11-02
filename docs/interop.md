# Syntact ↔ external world — state, open questions, remaining work

> Working notes. What the external boundary does today, what it cannot do yet, and the
> design questions still open. Decisions marked **OPEN** are deliberately not taken.

---

## 1. What works today

`<lib>{}` is a scope whose symbols are run in lib (`specs/types.md` §4.8, chapter 11).
The run of a symbol is an effect; `code/` lowers it to a call, and `code/x64` writes the
executable. **No external linker is invoked** — the compiler writes every byte of the
ELF, including the dynamic tables `ld` would normally emit.

```syntact
libm -> <libm.so.6>{
  sqrt -> {f64:x, -> !?::f64}
}
-> libm.sqrt{x -> 2.0}!        // prints 1.414214
```

### Verified with the current backend

| Library | Call | Result | Exercises |
|---|---|---|---|
| `libm.so.6` | `sqrt(2.0)` | `1.414214` | 1 float arg, a real printed |
| `libm.so.6` | `sqrt(pow(3.0, 4.0))` | `9.000000` | nested calls, two GOT slots, one `DT_NEEDED` |
| `libc.so.6` | `abs(-42)` | exit `42` | int arg (`rdi`) |
| `libc.so.6` | `puts("hi")` | `hi` | the address of a string of the image |
| `libz.so.1` | `compressBound(1000) - 1000` | exit `13` | `u64` |

- **No library is privileged** — the compiler contains no mention of any library name;
  the provenance travels as an opaque string into `.dynstr`.
- **Pure programs stay static** — no call behind a boundary ⇒ no `PT_INTERP`, no
  `.dynamic`; `ldd` reports "not a dynamic executable".
- **More than 6 arguments** go on the stack (`pass`, `code/x64/function.odin`).
- **A scope of 1 to 16 bytes** crosses by value, in registers, laid out as C lays it out
  (`crossing`, `code/lower.odin`).

### How it is wired

| Piece | Where |
|---|---|
| `Foreign` AST node, the library path | `syntax/ast.odin`, `syntax/parse.odin` |
| the boundary on the scope, its symbols | `kernel/build.odin` (`boundary`), `kernel/effect.odin` (`symbol_of`) |
| the effect `ε<sym{…}!>(x::L, t)` | `kernel/effect.odin` |
| `Foreign` instruction, `Import` | `code/code.odin`, `code/lower.odin` (`effect`, `crossing`) |
| System V argument assignment | `code/x64/asm/abi.odin`, `code/x64/function.odin` (`pass`) |
| `call [GOT]` | `code/x64/x64.odin` (`call_import`) |
| `.interp/.dynstr/.dynsym/.hash/.rela/.dynamic` | `code/x64/asm/elf_dynamic.odin` |
| `PT_INTERP`/`PT_DYNAMIC`, GOT layout | `code/x64/asm/elf.odin` |
| the same calls as C | `code/c/c.odin` (a symbol bound by an asm label) |

Two non-obvious things that cost debugging time, worth not re-discovering:

1. **`DT_PLTGOT` must point at a 3-entry reserved header**, not at slot 0. The ABI has the
   loader write its own bookkeeping there.
2. **`DT_JMPREL` is the wrong tag here.** It declares *PLT* relocations, tied to the
   lazy-binding machinery (a PLT stub per symbol, a resolver trampoline) — none of which
   exists in this design, since the call goes straight through the GOT. The right tag is
   **`DT_RELA` with `R_X86_64_GLOB_DAT`**: ordinary relocations, applied unconditionally
   at load time.

---

## 2. The open design question: addresses

**No pointer type in the language.** The pointer only appears in boundary codegen,
derived mechanically by a size rule: a value larger than two registers is passed by
address, otherwise by value.

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
  and it is not a hijack of the operator: chapter 12 reads `=<<` as a binding that is
  recomputed when what it reads changes.

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
| **opaque handle** (`FILE*`, SDL handle) — received and handed back, never dereferenced | a `u64` with no read semantics | worked in the previous pipeline (`snd_asoundlib_version`) |
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
- **Q4.** Is memory access a **value** or an **effect**? Chapter 10 already treats
  *obtaining* memory as an event (`ptr >- Alloc{size -> size}`, answered by the scope
  that collapses it). If that holds for obtaining it, maybe writing through the frontier is
  an event too — a `Write` the scope resolves — rather than a pointer passed around. This
  may be why the sketch feels half-wrong: it makes an address a *value* while the rest of
  the design treats memory access as an *effect*.
- **Q5.** Ownership / lifetime. `strdup` returns memory to free; `fopen` a handle to close.
  Does this belong to the boundary at all, or to the handler/event layer?

*(Allocation itself deliberately set aside for now.)*

---

## 3. Remaining work — mechanical, no design decision needed

- **Pure symbols** — a symbol whose production is `??::L` (chapter 11) is not lowered
  to a call yet: its answer is taken for an input of the program.
- **`sret`** — aggregate return > 16 bytes. The *caller* allocates and passes a hidden
  pointer in `rdi`. Needs somewhere for the buffer to live.
- **A scope larger than 16 bytes** as an argument — by address, by the size rule.
- **`f32`** arguments and results: only `f64` crosses yet (needs `cvtsd2ss`).
- **Symbol-existence check at build time** — read the target `.so`'s `.dynsym` and reject
  an undeclared symbol with a compile error instead of a startup `symbol lookup error`.
  Worth noting: **signatures cannot be checked, ever** — a `.so` carries the name, address,
  size, type and version of a symbol, but *nothing* about argument or return types. So
  `sqrt -> {u8:x, -> !?::u8}` links fine and silently produces garbage. The signature is a
  user assertion, unverifiable in principle — the same `unsafe` frontier every language has.
  This check earns its keep mainly for **cross-compilation** (no first local run to catch
  it), and it needs a sysroot: verifying against the *target's* `.so`, not the host's.

---

## 4. ABI details that bite in practice

- **Symbol versioning** (`GLIBC_2.29` vs `GLIBC_2.2.5`). Observed on `pow` and `exp`, which
  exist in two versions in `libm.so.6`. Without `.gnu.version_r` the default version is
  taken; usually fine, `memcpy` is the classic counter-example.
- **Variadics** — `al` (SSE register count) is set (`call_import`), but they also need a
  register save area.
- **Structs by value** — System V's field-by-field classification (INTEGER/SSE/MEMORY) is
  the genuinely tedious part of the ABI.
- **Callbacks** (passing Syntact code to `qsort`) — `code/` has functions now (a recursion
  that stays), but none is given an address a library can call.

---

## 5. Scope and tooling

- **Interpreter path** is the constant `DEFAULT_INTERP` in
  `code/x64/asm/elf_dynamic.odin`. This is the one absolute path a dynamic executable
  cannot avoid — the bootstrap cannot be delegated, since something must start the chain
  and that something is a literal `open()` by the kernel. It is a property of the target
  platform (arch + libc), **not** of any library. Needs a `--dynamic-linker` override
  and/or a per-target table for cross-compilation. Reference points: musl x86-64
  `/lib/ld-musl-x86_64.so.1`, glibc aarch64 `/lib/ld-linux-aarch64.so.1`, Android
  `/system/bin/linker64`, NixOS an unpredictable store path.
- **Other platforms** — Windows (IAT, and a different ABI: 4 registers `rcx/rdx/r8/r9`),
  macOS (Mach-O, `dyld`). A backend concern (`abi.md`, `targets.md`).
- **`.gnu.hash`** — optional, faster than `DT_HASH`. Not needed.
- **Section headers for the dynamic tables** — cosmetic: `readelf -d` warns "no .dynamic
  section in the dynamic segment". The kernel and loader only read *segments*, so execution
  is unaffected, but `gdb` symbol handling would want them.

---

## 6. Known gaps

- **Inputs are integers only.** `f64:x -> ??` then `-> x + 1.0` is refused at
  lowering: "the input ?0 is not an integer".
- **A field right before the production ends with a comma** (`{f64:x, -> …}`); without
  it, `f64:x -> …` is one binding. This is the grammar (`specs/language/README.md`), not
  a bug, but it is easy to miss when declaring symbols.

---

## 7. Order that follows from the above

If "fully interoperable" means "call any C API on Linux":

1. **Pure symbols, `f32`, scopes by address** → mechanical.
2. **The memory question (§2)** → opens in/out pointers, i.e. most of the rest.
3. **Callbacks** → an address for a function of `code/`. Large, orthogonal.
4. **Structs by value beyond 16 bytes, variadics** → tedious, rare.

Step 2 is the only one waiting on a language decision.

**What separates this from real interop is a decision, not a volume of code.**
