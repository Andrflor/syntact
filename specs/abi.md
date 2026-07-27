# Syntact ↔ external world — cross-platform ABI and linking

> **Position relative to `interop.md`:** that document records what the `<lib>` boundary does
> *today*, which is Linux/x86-64/ELF/System V only, and it is accurate. This document
> specifies the **portable model** — what has to become data instead of hardcoded, and what
> genuinely differs per platform. Companion to `targets.md` (backend architecture) and
> `sdk.md` (tool surface).
>
> Nothing here is implemented.

---

## 1. Three separable concerns

"Linking with external libs" is habitually treated as one problem. It is three, and they
vary independently:

| Concern | Varies by | Today |
|---|---|---|
| **Calling convention** — where args go, who saves what | (arch, OS) | System V x86-64, hardcoded |
| **Link mechanism** — how an address gets into the image | container format | ELF GOT + `.rela` |
| **Library naming** — how a library is identified | platform | verbatim soname string |

Conflating them is why the current code has SysV register lists sitting in the same
procedure as GOT slot arithmetic (`emit.odin:713-770`). They belong to different layers of
`targets.md` §5: convention → `isa/*`, mechanism → `image/*`, naming → `platform/*` plus
the manifest.

---

## 2. Calling conventions

### 2.1 The matrix

| (arch, OS) | Integer args | Float args | Slot numbering | Notes |
|---|---|---|---|---|
| x86-64 SysV — Linux, macOS, Android-x86 | RDI RSI RDX RCX R8 R9 | XMM0–7 | **independent** counters | AL = SSE-reg count for variadics; 128-byte red zone |
| x86-64 Windows | RCX RDX R8 R9 | XMM0–3 | **positional** — shared | **32-byte shadow space**, caller-allocated; no red zone |
| aarch64 AAPCS64 — Linux, Android | X0–X7 | V0–V7 | independent | no AL equivalent |
| aarch64 **Apple** — macOS, iOS | X0–X7 | V0–V7 | independent | **variadic args go on the STACK** |
| aarch64 Windows | X0–X7 | V0–V7 | independent | broadly AAPCS64 |

All: stack 16-byte aligned at the call. Integer return in RAX / X0, float in XMM0 / V0.

### 2.2 The three that will actually bite

**Windows x64 positional slots.** Argument *n* goes in the *n*-th slot, and that slot is a
GPR or an XMM depending on the argument's type — the two register files share one counter.
So `f(int, double, int)` uses RCX, XMM1, R8 — note the *gap* in each file. The current code
(`emit.odin:735-750`) walks `int_i` and `sse_i` as independent counters, which is correct
for SysV and **wrong for Windows**.

**Windows x64 shadow space.** The caller must allocate 32 bytes above the return address for
the callee to spill its four register args into. Omit it and the callee corrupts your frame.
There is also no red zone, so the "float-print scratch lives in the red zone below rsp"
shortcut noted at `emit.odin:451-457` is not portable.

**Apple aarch64 variadics go on the stack.** On macOS/iOS, *all* variadic arguments are
passed on the stack (8-byte slots), not in X0–X7/V0–V7. A correct AAPCS64 implementation
built against the Linux rules will produce wrong calls to any variadic function on Apple
platforms — `printf`-shaped targets being the obvious victim, and `interop.md` records that
variadics were deliberately made to work.

### 2.3 ABI as a record

Same treatment as `Platform` in `targets.md` §4 — data the ISA layer reads, not branches
inside the encoder:

```odin
Abi :: struct {
    int_args:     []Reg,
    float_args:   []Reg,
    slot_mode:    enum { Independent, Positional },       // SysV vs Win64
    shadow_space: int,                                    // 32 on Win64, else 0
    red_zone:     int,                                    // 128 on SysV, else 0
    stack_align:  int,                                    // 16
    variadic:     enum { Same_As_Fixed, Al_Sse_Count, All_On_Stack },
    ret_int:      Reg,
    ret_float:    Reg,
    sret:         enum { Hidden_First_Arg },               // large returns
    callee_saved: []Reg,
    sym_prefix:   string,                                  // "_" on Mach-O, "" elsewhere
}
```

`emit_foreign_call` then becomes ABI-driven. Its present limits are all SysV artifacts:
6 arguments max (`len(SYSV_INT_ARGS)`), no stack-passed arguments, AL always set, independent
counters, and `movabs R10, GOT_VADDR` for the indirect call.

**Stack-passed arguments are the missing capability**, not just a different register list.
Today's hard error — "more than 6 arguments to an external is not supported yet" — has to go
away before Windows (4 register slots) is usable at all.

---

## 3. Link mechanism

How a resolved address gets into the image. Universal shape: **empty slots the loader fills
at startup.** Only the table format differs.

| Container | Table | Filled by | Reloc / encoding |
|---|---|---|---|
| ELF | GOT + `.rela` | loader, from relocations | `R_X86_64_GLOB_DAT` (6) / `R_AARCH64_GLOB_DAT` (1025) |
| Mach-O, classic | `__got` / `__la_symbol_ptr` + `LC_DYLD_INFO_ONLY` | dyld, from a **bind-opcode bytecode** | opcode stream |
| Mach-O, modern | `LC_DYLD_CHAINED_FIXUPS` | dyld, walking a chained pointer list | encoded in the pointers |
| PE | Import Directory + IAT | loader | IAT entries by name/ordinal |

The existing ELF path is already correct and worth preserving as the reference: direct GOT
call, no PLT, no lazy binding, `DT_RELA` + `R_*_GLOB_DAT` rather than `DT_JMPREL` — the
reasoning is recorded in `interop.md` §1 and `elf_dynamic.odin`, including the two mistakes
that cost debugging time. Don't re-derive those.

**Open, needs verifying against a current macOS before implementing:** whether classic
`LC_DYLD_INFO_ONLY` bind opcodes are still accepted on the macOS versions being targeted, or
whether `LC_DYLD_CHAINED_FIXUPS` is now effectively required. Classic is far better
documented; chained is required for arm64e (pointer authentication) but plain arm64 may not
need it. This decides how much Mach-O work macOS actually is, so resolve it before starting
rather than assuming.

---

## 4. Library naming — the four-name problem

This is the part that leaks into the *language*, which makes it the most important item here.

`sqrt` lives in a differently-named library on every platform:

| Platform | Identified by | `sqrt` lives in |
|---|---|---|
| Linux | versioned soname, searched by name | `libm.so.6` |
| Android | **un**versioned soname | `libm.so` |
| macOS / iOS | **full install path** | `/usr/lib/libSystem.B.dylib` |
| Windows | DLL filename | `ucrtbase.dll` (or an api-set) |

So `libm -> <libm.so.6>{ … }` — the form `interop.md` documents and verified against seven
real libraries — **hardcodes Linux into the source text.**

Two properties are in tension and both are worth keeping:

- *"No library is privileged — the compiler contains no mention of any library name"*
  (interop.md §1). A real invariant; don't give it up.
- Source should not have to be rewritten per platform.

### The resolution

**Keep `<…>` provenance opaque to the compiler, and put the per-platform mapping in the
project manifest.**

Source names a *logical* library; the manifest — which is itself a Syntact scope per
`sdk.md` §3 — carves the real name per target:

```
libm -> <libm>{ sqrt -> { f64:x  -> ??::f64 } }
```

with the mapping supplied as ordinary project data, not compiler data. The compiler still
contains zero library names: it receives a resolved string exactly as it does today, from
the manifest instead of from source. Default mappings for the common C libraries ship as an
ordinary Syntact library — a folder of `.syn` resolved through `@`, not a compiler builtin.

`Platform.lib_ref` (`targets.md` §4) then covers only the *form* the container needs
(soname / unversioned soname / path / DLL name); the manifest covers the *name*. Both are
required; they are different questions.

**Escape hatch to keep:** a `<…>` containing a platform-specific literal must still work
verbatim, unresolved, for the case where someone genuinely wants one exact library. That is
today's behaviour and it should not regress.

This supersedes the OPEN item in `targets.md` §11 and the corresponding note in
`interop.md`.

---

## 5. Static linking — deliberately out of scope

`.a` archives would require parsing `ar`, resolving symbols across members, and pulling in
transitive dependencies by hand — `interop.md` already notes the `.a` case has no automatic
transitive resolution, unlike `.so`. That is writing a real linker.

Position: **dynamic only for consuming external libraries.** Emitting `Static_Library` /
`Object` artifacts for *others* to link (`targets.md` §6.2) is a separate and much smaller
job — it needs relocation *sections* in the output, which `Code_Object` already carries, and
no symbol resolution at all.

---

## 6. Structs by value — four implementations, not one feature

The reason `interop.md` still says "only scalar arguments and results are supported" is that
aggregate passing is genuinely per-ABI, not one algorithm:

| ABI | Rule |
|---|---|
| SysV x86-64 | classify each 8-byte chunk INTEGER / SSE / MEMORY; ≤16 bytes may go in two registers, else memory |
| AAPCS64 | HFA/HVA (homogeneous float/vector aggregates) get up to 4 V-registers; ≤16 bytes in X-registers; else by reference |
| Win64 | anything not 1/2/4/8 bytes is passed by a **hidden pointer** the caller allocates |
| Apple aarch64 | AAPCS64, plus the variadic divergence in §2.2 |

Plus `sret`: large returns take a hidden first-argument pointer, and *which* returns count as
large differs by the same rules.

Practical consequence: **do not design "struct support" as one feature.** Design the
`Abi.classify(type) -> []Arg_Location` hook, implement SysV first (already exercised by the
verified library set), and add the others with the platform that needs them. This is also
where `interop.md` §2's OPEN pointer/address question has to land, since by-reference passing
*is* an address.

---

## 7. Callbacks — the reverse direction

Everything today is one-directional: syntact calls out. The GUI/game library (`targets.md` §11)
needs the reverse — foreign code calling *into* syntact — because every windowing and input API
delivers events through callbacks.

That requires emitting a function whose entry obeys the platform ABI rather than the program
entry stub: arguments arrive in ABI registers instead of via the args table, callee-saved
registers must actually be saved, and the frame has to be a real ABI frame. Note that
`regalloc.odin:39-45` currently excludes RBX precisely because nothing is a real ABI function
yet — that comment marks the exact spot this changes.

For debug profile it is harder still: a callback into a *hot-reloadable* program means the
foreign side holds a pointer that must survive a reload. That interacts directly with the
state rule in `targets.md` §10 and should be decided with it.

---

## 8. What blocks what

| Item | Cannot happen until | Note |
|---|---|---|
| `Abi` record + ABI-driven `emit_foreign_call` | nothing | pure refactor of working code, checkable against the seven-library set in `interop.md` |
| stack-passed arguments | the `Abi` record | removes the 6-argument ceiling; Win64 has only 4 register slots, so it is a prerequisite there |
| library naming via manifest | `sdk.md`'s `project/` exists | language-visible (§4), so it constrains `<lib>` source written before it |
| AAPCS64 | the aarch64 ISA | variadics must be verified against **both** Linux and Apple rules — they differ (§2.2) |
| Mach-O binding | the classic-vs-chained question is resolved (§3) | |
| Win64 convention + PE IAT | the `Abi` record and stack-passed arguments | |
| `Abi.classify` for aggregates | nothing technically | four implementations, not one feature (§6); driven by whichever real library first needs it |
| callbacks | nothing technically | **prerequisite for the GUI/game library** (`targets.md` §11) — every windowing and input API delivers events through callbacks; also interacts with the reload state rule (§7) |
