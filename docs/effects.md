# Syntact External Boundary & Effects — Design Notes

> Working notes, not spec. What was decided here is now in `specs/types.md` §4.8–4.9 and
> `specs/language/10`, `11`; this file keeps what is still open.

## Decided, and where it is written

- **An effect is `!?`, wherever it is written** — not only in a handler. No law copies,
  erases or reorders it; a pure computation crosses it (`types.md` §4.8, §8).
- **The effect is marked by provenance, not by the shape of the result.** The run of a
  symbol behind `<lib>{}` is an effect when its production is `!?::L`, whatever comes
  back: a value, a constant, or nothing (`!?::none`). A singleton or void answer does not
  erase the call. A production `??::L` is a pure symbol: a value the program does not
  compute, which nothing orders (chapter 11).
- **A handler is context found when the program is typed**, not a dynamic lookup:
  nothing is passed at run time (`types.md` §4.9).
- **Calling outside is carving and collapsing.** Carving a symbol calls nothing; the call
  is at `!` (chapter 11).
- **The program's inputs** are its unknowns `??`, read from the command line where it
  starts (`specs/language/15`).

## `::`

`??::L` and `!?::L` read an unknown, or what an effect gives back, in the layout L. `::` on
anything else is not built by the kernel ("`::` on anything but `??` and `!?`"). The
bit-level cast it was sketched as — narrowing `300::u8` to `44`, widening by sign- or
zero-extension — is **open**, and `\` is lexed as a cast the kernel does not build either.

## Pointers: not a language type — derived at the frontier

No pointer type in pure Syntact. A string, a list, a scope is a *value*, not an address.
The pointer only appears in the code of the boundary, by a size rule: what fits in
registers is passed by value, the rest by address. Today a scope of 1 to 16 bytes crosses
by value in registers, and a string of the image by its address (`docs/interop.md` §1).

Mechanics to remember for the backend:

1. **Large return = sret.** When a *return* exceeds two registers, the **caller**
   allocates the buffer and passes a hidden pointer as the implicit first argument
   (`rdi`); the callee writes into it.
2. **Two registers.** System V x86-64 passes aggregates up to 16 bytes in two registers;
   beyond, by address.

The open questions — cell identity, the write direction, ownership — are in
`docs/interop.md` §2.

## CString as a constraint (content), not a representation

```syntact
CString -> (char & ~'\0') * 0.. + '\0'   // non-null characters, then a final \0
```

A content constraint: a string in it is a well-formed C string, provable at compile time
before it crosses. It says nothing of the representation — the size rule does.

## ASM inline — deferred

Form sketch (not final):

```text
my_write -> <asm[x64]>{
  u8:a  u8:b
  -> !?::u8
  ---
  mov rax, 1
  syscall
}
```

Inline asm is **harder than a linked symbol** because there is no standard ABI to inherit
— the contract is supplied by hand. GCC "extended asm" has **4 sections**, all of which an
asm block must eventually express:

| Section | Question |
|---|---|
| Template | which instructions |
| Inputs | which bindings → which registers |
| Outputs | which register → the production |
| **Clobbers** | which registers/memory the asm destroys ← **the easily-forgotten one** |

- **Start with a fixed convention** (bindings → rdi/rsi/rdx…, return → rax, System V
  clobbers). An explicit `binding -> reg` mapping later is a superset, non-breaking.
- **Do not forget clobbers** even if fixed at first: a `syscall` clobbers rcx/r11.

## Per-platform lowering (same language form, different backend)

The boundary is **one language abstraction**; the backend lowers it per target:

| Target | External symbol lowering | Direct syscall viable? |
|---|---|---|
| Linux | `syscall` instruction (numbers stable/public) **or** linked `.so` (GOT) | **Yes** — static binary, no linking |
| Windows | `call [IAT slot]` + import table (no stable syscall numbers) | No |
| macOS | Mach-O, `dyld`, `__la_symbol_ptr` | Possible but Apple doesn't guarantee it; `libSystem` quasi-mandatory |
| iOS | Mach-O + `dyld` + **mandatory code signing** | No |
| Android | ELF + Bionic `linker64` (often `.so` via JNI) | Yes (subject to seccomp/SELinux) |

**The mechanism is universal:** empty slots patched by the loader at startup (IAT on
Windows, GOT on Linux/Android, stubs on Mach-O). Only the file/table format differs — a
backend concern (`docs/abi.md`, `docs/targets.md`).

**No libc.** On Linux a pure program is a static binary that makes its own syscalls;
linking a library is the exception, not the default.

## Open decisions

- **ABI of `<lib>` symbols:** per-function (default = platform C ABI, handles mixed
  conventions like Odin/Zig) vs per-block (simpler, Rust-style). Lean per-function with a
  default.
- **`::` as a bit cast:** whether it exists, and sign- vs zero-extension.
- **String marshalling:** `(ptr, len)` in two registers vs a C string (`\0`-terminated,
  one register), and sret for large returns.
