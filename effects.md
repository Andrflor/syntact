# Syntact External Boundary & Effects — Design Notes

> Working notes, not spec. Decisions reached in design discussion. Some points still open.

## Core principle: effects live only in handlers

- Everything in pure Syntact folds toward **singletons** (structural reduction).
- An **event handler** (`-<`) is the **only** place allowed to be effectful — the only place where a fold may legitimately stop on a non-singleton.
- An effect has **no reified trace**. The trace is implicit: a frontier produces a non-singleton type (e.g. `??:u8`), so the value cannot fold to a point, so the compiler sees the compute path *for free*. Non-singleton **is** the effect marker.

## External boundary: `<lib>{ ... }`

A linked external library is declared as a normal scope whose production points outside:

```syntact
kernel -> <kernel.so>{
  write -> {
    u8:a  u8:b
    -> ??:u8
  }
  read -> {
    i32:fd  usize:len
    -> isize:
  }
}
```

- `<kernel.so>` = provenance, maps 1:1 to one import descriptor (PE `IMAGE_IMPORT_DESCRIPTOR` / ELF `DT_NEEDED`).
- Each symbol is an **ordinary scope**: input bindings are colored constraints, the production is a colored type. The body is "empty" — its production is a *type*, not a value. That is what makes it an external leaf.
- **Provenance lives in the code, not in an external build system.** Goal: source is self-sufficient, compiler knows what to link. No Makefile/linker-config dance. (Long-term: compiler is its own toolchain, à la Zig — embeds assembler+linker. Short-term: emit textual `.s` and shell out to `as`/`ld`, internalize later.)

### Calling an external = ordinary scope algebra

Because `write` is just a scope, everything falls out for free, no special rule:

```syntact
kernel.write              // projection — the scope, NOT executed
kernel.write{2, 3}!       // positional carve (a<-2, b<-3) then collapse
kernel.write{a->2, b->6}! // nominal carve then collapse
b4 -> kernel.write{b->4}  // PARTIAL carve, NO collapse — pure data, no effect
b4!                       // collapse here → effect happens HERE, only now
```

**Carving an external does not execute it.** The effect occurs only at `!`. A partially-applied external is just another scope. Consistent with "effectful only in a handler": the collapse of an external is the one collapse that cannot fold (production is non-singleton `??:T`), so codegen must emit the external call.

## Cast `::` (already implemented in parse/analyze)

- `::` is **bit-level**, distinct from `&` (which stays set intersection, can yield `None`).
- Narrowing (`300 ::u8`): cut to the low bits → `44`. Total, never an error.
- Widening: pad-left. **Open:** sign-extend vs zero-extend when source is signed — decide by source signedness (sign-extend signed, zero-extend unsigned) is the "correct" option but needs the fold to track signedness.
- Lexes as a single `Cast` token, parses as infix `Operator_Kind.Cast` at `CONSTRAINT` precedence (tighter than `+`): `a+b::u8` is `a+(b::u8)`; casting a sum needs `(a+b)::u8`.

## Pointers: NOT a language type — derived at the frontier

**No pointer type in pure Syntact.** A String/array/scope is a *value*, not an address. The pointer only appears in the external-boundary codegen.

**The deciding rule (mechanical, no annotation):**

> If `sizeof(type) > sizeof(pointer_for_target_arch)` → passed/returned **by address** (pointer).
> Otherwise → fits in a register → **by value**.

- `sizeof(pointer)` = register width of the target (8 on x64/arm64, 4 on wasm32). Derived from the build arch flag.
- `u8/i32/i64/f64/ptr` ≤ 8 → register, by value.
- String (variable byte length), array, large scope → > 8 → by address.
- The trigger is **byte size**, NOT singleton-ness. `"hello"` (fixed-size singleton) still needs an address to be passed to `write` — because its byte size exceeds register width.

**Codegen nuances (mechanics, not design — remember for backend):**
1. **Large return = sret convention.** When a *return* type exceeds register width, System V does NOT magically put a pointer in `rax`: the **caller** allocates the buffer and passes a hidden pointer as the implicit first arg (`rdi`); callee writes into it. "Return > 8 ⇒ pointer" is right, but the mechanism is caller-provides-buffer.
2. **Threshold approximation.** System V x86-64 can pass aggregates up to 16 bytes in *two* registers. The simple rule "> pointer width ⇒ by address" is a **safe approximation** (sub-optimal, never wrong). Refine only if bit-exact C interop is needed.

## CString as a constraint (content), not a representation

```syntact
CString -> (anyChar & ~'\0').. + '\0'   // chars-non-null repeated, then a final \0
```

- This is a **content constraint**: a String satisfying it IS a well-formed cstring (no interior null). Good for coloring a frontier and *statically proving* a string is safe to pass to a C API.
- It does **NOT** capture representation (the "it's an address" part) — that is handled by the size rule above + marshalling.
- **Open / to clarify:** `''` semantics. `''..` ≡ `String` (all strings) per constraints.md. For "any single non-null char" we need the char-domain universe, not the empty string. Likely want `(.. & ~'\0')` in the char domain, or an `anyChar` alias. Verify against `string.odin`.

## ASM inline — DEFERRED (after lib-linking path works)

Form sketch (not final):

```syntact
my_write -> <asm[x64]>{
  u8:a  u8:b
  -> ??:u8
  ---
  mov rax, 1
  syscall
}
```

Inline asm is **harder than a linked symbol** because there is no standard ABI to inherit — you must supply the contract by hand. GCC "extended asm" has **4 sections**, all of which an asm block must eventually express:

| Section | Question |
|---|---|
| Template | which instructions |
| Inputs | which bindings → which registers |
| Outputs | which register → the production (`: isize`) |
| **Clobbers** | which registers/memory the asm destroys ← **the easily-forgotten one** |

- **Recommendation:** start with a **fixed convention** (bindings → rdi/rsi/rdx…, return → rax, System V clobbers), no per-binding mapping. Adding explicit `binding -> reg` mapping later is a superset, non-breaking.
- **Do not forget clobbers** even if fixed at first: a `syscall` clobbers rcx/r11; if the compiler doesn't know, the surrounding generated code is silently wrong (nondeterministic bugs).

## Per-platform lowering (same language form, different backend)

The boundary is **one language abstraction**; the backend lowers per target:

| Target | External symbol lowering | Direct syscall viable? |
|---|---|---|
| Linux | `syscall` instruction (numbers stable/public) **or** linked `.so` (GOT/PLT) | **Yes** — static binary, no linking, the preferred path |
| Windows | `call [IAT slot]` + import table (no stable syscall numbers) | No |
| macOS | Mach-O, `dyld`, `__la_symbol_ptr` | Possible but Apple doesn't guarantee it; `libSystem` quasi-mandatory |
| iOS | Mach-O + `dyld` + **mandatory code signing** | No |
| Android | ELF + Bionic `linker64` (often `.so` via JNI) | Yes (subject to seccomp/SELinux) |

**Mechanism is universal:** empty slots patched by the loader at startup (IAT on Windows, GOT on Linux/Android, stubs on Mach-O). Only the file/table format differs → purely a backend concern, language semantics unchanged.

**No libc.** On Linux: direct syscalls, static binary, zero linking. Lib linking is the exception, not the default.

## Open decisions (not yet trapped)

- **ABI of `<lib>` symbols:** per-function (default = platform C ABI, handles mixed conventions like Odin/Zig) vs per-block (simpler, Rust-style). Lean per-function-with-default.
- **`::` widening:** sign-extend vs zero-extend vs by-source-signedness.
- **`argv` retrieval:** kernel puts `argc`/`argv` on the stack at `_start` (NOT a syscall). Options: a pre-filled root scope (`args` binding on the file scope, marshalled once at startup) vs an "intrinsic" external. Note: it's stack-reading, not a syscall instruction — a special kind of external.
- **String marshalling:** materialize a String-value into bytes for the frontier — `(ptr, len)` two-register form vs cstring (`\0`-terminated, one register). Plus sret for large returns.
- **`anyChar` / `''` semantics** for the CString constraint (see above).

## Build order (agreed)

1. cast `::` — ✅ done (lexed/parsed/folded)
2. **pattern types** — NEXT (`walk_pattern` should produce the `Or_Type` of satisfiable branch productions; reuse `satisfy`/`Or_Type`/interval intersection; narrowing `>0 ->` is just domain intersection)
3. external boundary `<lib>{}` — design decided here, implement in analyzer
4. reducer — close the core (make `square{n->5}!` actually yield `25`); this is the real blocker for codegen
5. codegen: emit asm + link lib → executable (textual `.s` + external `as`/`ld` first, internalize later)
6. asm inline — last, when needed

External (`<lib>`) and reducer meet cleanly: an external collapse is the only collapse that does NOT fold (non-singleton `??:T`); the reducer leaves it as an "external call" node, codegen turns it into `call [linked symbol]`.
