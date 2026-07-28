# Syntact multi-target backend — architecture specification

> Design notes, not a record of work done. **Nothing in the "target architecture" sections
> below is implemented yet.** Current state is x86-64 Linux only; every file reference to
> today's code is given as `file:line` so it can be found and changed.
>
> Scope decision (taken): **native platforms first.** C, JS and wasm emitters are deferred
> — see §12. Flutter's target set minus Web = Linux, Windows, macOS, Android, iOS.

---

## 1. Why this is tractable

Three structural facts carry the whole design.

**The bytecode is the waist.** `BC_Program` (`compiler/bytecode/bytecode.odin`) is
target-neutral. Everything above it — parse, analyze, reduce, ~20k lines — is written once
and never touched per target. All target work lives strictly below.

**The two-tier model already exists.** `compiler/bytecode/interp.odin` describes itself as
"the reference backend, the oracle — every machine backend must agree with it on every
program." That is Flutter's architecture (VM in debug, AOT in release) already in place.
Nothing to invent, only to finish.

**Targets factor into axes, not a matrix.** ISA × container × platform would mean a fork
per target. Factored, 8 targets come out of 2 ISAs + 3 image formats + 6 platform records
(§6.1), plus 2 signers.

Related: reduce collapses everything reducible before codegen (`specs/language/20-performance.md`), so backend
cost scales with the *surviving residual*, not with source size. Fast compilation is a
property of the design, not a tuning exercise.

---

## 2. The pipeline

```
AST / IR  →  BC_Program                          ← target-neutral (exists)
              ├─→ interp                          ← oracle + debug tier, all platforms
              └─→ isa/<arch>   → Code_Object      ← code + relocs + symbols, NO addresses
                    → image/<fmt> → []u8          ← ELF / Mach-O / PE
                        → sign/<scheme> → []u8    ← ad-hoc Mach-O, APK v2
                            → package/<kind>      ← raw exe, .so/.dylib, .apk, .app
```

---

## 3. The ISA ↔ image contract

The centrepiece. This single struct is what makes PIE, `.so`, Mach-O and PE fall out of one
mechanism instead of each needing its own hack.

```odin
Reloc_Kind :: enum {
    Abs64,             // absolute address of a symbol
    Rel32,             // PC-relative 32-bit — x64 RIP-relative, call/jmp
    Aarch64_Adrp_Hi21, // page delta: (target>>12) - (pc>>12)
    Aarch64_Add_Lo12,  // low 12 bits; pairs with the above
    Aarch64_Call26,    // bl
}

Reloc :: struct { at: int, kind: Reloc_Kind, sym: Sym_Id, addend: i64 }

Sym :: struct {
    name:    string,
    kind:    enum { Local, Global_Def, Undef_Import },
    section: enum { Code, Rodata, Data, Bss },
    offset:  int,
    lib:     string,   // provenance string from <lib>, for imports
}

Code_Object :: struct {
    code, rodata: []u8,
    bss_size:     int,
    relocs:       []Reloc,
    syms:         []Sym,
    entry:        int,        // offset into code
    lines:        []Line_Map, // debug spine
}
```

**What this fixes.** `emit_foreign_call` (`compiler/backends/x64/emit.odin:713`) currently
emits `movabs r10, GOT_VADDR + 8*slot` — a baked absolute address. Under this contract it
emits a reference to symbol `__syn_got` + `8*slot` plus a `Reloc`, and **the image writer
decides where that lives.** Same for `emit_load_arg` and `ARGS_TABLE_VADDR`. ET_EXEC,
ET_DYN, MH_EXECUTE and PE disagree about exactly this, and only this.

---

## 4. Platform as data, not code

`emit_exit` (`emit.odin:467`) hardcodes `rax=60`. To avoid `if android {} else if macos {}`
sprawl inside the encoders, the platform is a **record the ISA layer reads**:

```odin
Platform :: struct {
    // Entry and result depend on (Artifact × platform), not on platform alone — an
    // Executable and an App_Package on the same OS start completely differently.
    // Indexed by Artifact (§6.2); see sdk.md §6 for the matrix.
    entry_exe:   enum { Sysv_Stack_Argv, None },
    entry_app:   enum { Native_Event_Loop, Jni_OnLoad, Ui_Application_Main, None },
    entry_lib:   enum { Dylib_Init, Jni_OnLoad, None },
    result_kind: enum { Exit_Status, Return_Value, Write_Stdout, Lifecycle },
    syscalls:    Maybe(Syscall_Table),  // nil ⇒ must route through libc
    libc_name:   string,                // "libSystem.B.dylib", "libc.so"
    interp:      string,                // loader path; "" = static
    lib_ref:     enum { Soname, Unversioned_Soname, Path },
    page_align:  int,
    sym_prefix:  string,                // "_" on Mach-O, "" on ELF
    pie:         enum { Optional, Required },
}
```

The ISA layer then has exactly three procs that touch platform at all — `emit_entry`,
`emit_result`, `emit_call_out` — and each switches on these **fields**, never on a platform
name.

**This record is also what `@platform` exposes to source** (`sdk.md` §3.1) — the same knowledge
under source-facing names, so a program can branch on the platform with no configuration layer
anywhere. The two must be **one definition with two views, not two lists that drift.** The
entry/result fields stay backend-only: a program has no use for how its own entry stub is
shaped. Everything else — `syscalls`, `libc_name`, `lib_ref`, `sym_prefix`, `pie`, page size,
plus arch/os/abi/image identity and the pointer-width shapes — is readable from source.

`syscalls: nil` on macOS/iOS is what mechanically forces the libc path that effects.md:121
predicted. It also means `emit_exit` needs a libc-call variant, not merely a different
syscall number.

---

## 5. Tree

```
compiler/
  bytecode/                    ← the waist; imports nothing from compiler/ (already true)
    bytecode.odin
    interp.odin                + reload entry point
  reload/
    cache.odin                 content-addressed reduce cache, binding-level
    session.odin               resident VM + patch socket
  backends/
    target.odin                Target record + the --target table
    isa/
      common/
        regalloc.odin          ← MOVED from x64/, parameterized by Reg_File
        codeobj.odin           Code_Object, Reloc, Sym
      x64/                     isel, emit, instructions, sse, vectorize, tests
      arm64/                   isel, emit, instructions, neon, tests
    image/
      elf/                     ← MOVED out of package x64_assembler
      macho/
      pe/
      dwarf/                   shared by elf + macho
    platform/                  linux, android, macos, ios, windows  (data only)
    sign/
      macho_adhoc/             CodeDirectory + SuperBlob (core:crypto/sha2)
      apk/                     ZIP + v2 block (core:crypto/sha2, core:crypto/ecdsa)
    package/
      raw, sharedlib, staticlib, object, apk, appbundle
      multi/                   universal / multi-ABI combination (§6.4)
```

The SDK layer above this — `sdk/cli`, `sdk/project`, `sdk/device`, `sdk/format`,
`sdk/session` — is specified in `sdk.md` §4. The compiler proper stays a library with no CLI
and no I/O policy.

**Share regalloc, don't share isel.** Linear-scan over SSA live intervals is
arch-independent; only the register file differs. Parameterize on
`Reg_File{allocatable, reserved, caller_saved, class_of(Machine_Type)}`. aarch64's 31 GPRs
then just mean less spilling, for free. By contrast x64's LEA/address-mode matching and
aarch64's `madd`/shifted-operand/pre-index patterns have nothing in common — two isel
files, deliberately.

Also x64-only and staying put: `vectorize.odin`, `x64_sse_scalar.odin`,
`x64_movzx_mem.odin`, and the 8k-line `x64_test.odin` encoding suite. arm64 needs its own
equivalent of the last one.

---

## 6. Three orthogonal axes

A build request is **(Target, Artifact, Profile)** — three independent axes, not rows in one
table. `android-arm64-apk` is not a target: it is target `android-arm64` with artifact
`App_Package`. The SDK surface that selects them is specified in `sdk.md`.

### 6.1 Target — *where it runs*

```
--target          arch      image   platform   pie   sign
linux-x64         x86_64    elf     linux      opt   —
linux-arm64       aarch64   elf     linux      opt   —
windows-x64       x86_64    pe      windows    yes   —
macos-x64         x86_64    macho   macos      yes   adhoc
macos-arm64       aarch64   macho   macos      yes   adhoc (req'd)
android-arm64     aarch64   elf     android    req   —
ios-sim-arm64     aarch64   macho   ios_sim    yes   adhoc
ios-arm64         aarch64   macho   ios        yes   external
```

8 targets from 2 ISAs + 3 image formats + 6 platform records.

**Skip armv7.** Play Store has required 64-bit since 2019 and 32-bit-only Android devices
are effectively gone. Don't pay for a third ISA.

### 6.2 Artifact — *what shape the output takes*

**An artifact exists only where Syntact meets the non-Syntact world.** There is no artifact
for a Syntact library consumed by Syntact — see the rule below.

```odin
Artifact :: enum {
    Executable,      // exe / Mach-O MH_EXECUTE / PE image     — the OS runs it
    Shared_Library,  // .so / .dylib / .dll                    — another language links it
    Static_Library,  // .a / .lib                               — likewise
    Object,          // .o / .obj                               — likewise
    App_Package,     // apk, aab, .app, .ipa, msix              — a platform installer takes it
}
```

| Artifact | Needs |
|---|---|
| `Executable` | entry stub, `LC_MAIN`/`e_entry` |
| `Shared_Library` | **defined** globals in `.dynsym` / export table, no `_start`, init path — `elf_dynamic.odin` today writes only `SHN_UNDEF` imports, see §8.5 |
| `Static_Library` | ET_REL / MH_OBJECT / COFF object + `ar` archive writer — relocation *sections*, not internally-resolved relocs |
| `Object` | same minus the archive |
| `App_Package` | signing + platform container; sits above `sign/` in the pipeline |

Good news for §3: `Code_Object` already carries relocations and symbols, so
`Static_Library` / `Object` are almost entirely an image-layer concern. The relocation
refactor pays for object emission too.

### A Syntact library has no artifact

> *"An external library is a scope whose production points out; a library written in Syntact
> is a scope whose production reduces in. They are the same object, seen from two sides —
> **there is no separate notion of 'a library'**."*
>
> *"…it cross-compiles by an arch flag instead of shipping one binary per platform.
> **There is nothing to bundle.**"*
> — both from `specs/language/16-external-boundary.md`

A Syntact library is a **folder of `.syn` files**. A folder is a scope and a file is a scope
(`specs/language/04-scopes.md`), the filesystem is resolved as a scope graph by `@`, and importing
is expansion (`specs/language/18-modules.md`):

```syntact
...@lib.geometry
```

The consumer reads the source, expands it into its own scope, and reduces it *there* — which
is what makes it specialize at the call site through carving and cross-compile by an arch
flag. There is no package format, no serialized IR to ship, no interface file, no ABI, and
no version-compatibility surface, because nothing is ever compiled ahead of the consumer.

**To publish a library, you ship the folder.** That is the whole distribution story, and it
is a consequence of the algebra rather than a missing feature.

Do not confuse this with the content-addressed reduce cache (§10). That cache stores reduced
forms keyed by content hash so the compiler and LSP can skip work — it is an internal,
regenerable, machine-local implementation detail. It is never an output, never shipped, and
never a dependency. Deleting it changes nothing but speed.

### 6.3 Profile — *debug or release*

| | `debug` | `release` |
|---|---|---|
| execution | bytecode interpreter (resident VM) | AOT native |
| isel / regalloc | **skipped entirely** | full |
| reduce | full — it is the semantics | full |
| hot reload | yes | no |
| debug info | full DWARF | line tables or none |
| signing | ad-hoc where required | real identity |
| output | run in place | packaged artifact |

**Reduce is semantics, not optimization** — so both profiles compute the same residual by
construction. The whole class of "works in debug, breaks in release" bugs that plagues
C++/Dart is structurally much smaller here. What differs is only whether the residual goes
to machine code or to the interpreter.

**Consequence that matters for on-device debug:** the resident VM has to *run* somewhere, so
a debug build for a device is `native VM binary (AOT, built once per target) + bytecode
payload pushed and hot-reloaded`. That is exactly Flutter's split (AOT engine, kernel-bytecode
app). It means **the interpreter must itself be compilable to every target** — see the
open decision in `sdk.md` about shipping prebuilt VMs vs cross-building them with Odin.

### 6.4 Multi-target combination

`--target` is repeatable on both `build` and `bundle` (`sdk.md` §5). Each platform joins
multiple targets differently:

| Platform | Mechanism |
|---|---|
| macOS / iOS | universal binary — one file, N Mach-O slices (`FAT_MAGIC`, §8.3) |
| Android | one APK/AAB with `lib/arm64-v8a/`, `lib/x86_64/` … |
| Apple, `Shared_Library` output | XCFramework — a *directory* of per-platform slices |
| Windows | no fat format; separate files per arch |

That is a small `package/multi` layer above `package/`.

### Dependency structure — what gates what

| Platform | New ISA? | New container? |
|---|---|---|
| Linux/x64 | — ✅ | — ✅ |
| **Windows/x64** | **no** | **PE/COFF** |
| **Linux/aarch64** | **aarch64** | **no** |
| macOS | aarch64 (Apple Silicon) | Mach-O |
| Android | aarch64 | ELF `.so` + PIE |
| iOS | aarch64 | Mach-O |

Two of these isolate exactly one variable: Windows is a new container against a known ISA;
Linux/aarch64 is a new ISA against a known container. Together they exercise the layer split
from both directions — aarch64 tests "no OS code in ISA packages", PE tests "no arch code in
image writers".

**Never debug a new ISA through a new container.** Android and iOS each combine both.

---

## 7. The six invariants

1. `bytecode/` imports nothing from `compiler/`. (Already true — protect it; it is what
   keeps the oracle honest.)
2. `isa/*` imports the `target` records only — never an `image/*` or `platform/*`
   implementation.
3. `image/*` never imports `isa/*`. Arch enters only as a constant lookup on `Target.arch`.
4. **No absolute virtual address ever appears in `isa/*`.** Every cross-reference is
   symbol + reloc.
5. `sign/*` and `package/*` operate on finished bytes. One exception: the Mach-O writer
   must *reserve* the signature slot and emit `LC_CODE_SIGNATURE`; the signer fills it.
   Standard two-pass.
6. Every backend agrees with `interp` on every program — the existing law. Today that is
   `interp` vs x64; adding arm64 makes it three-way. It is not per-platform: one ISA backend
   serves every platform that uses it.

**Invariant 4 is load-bearing and is precisely what the code violates today.** `ELF_BASE`
(`elf.odin:40`), `ARGS_TABLE_VADDR` (`elf.odin:60`) and `GOT_VADDR` (`elf.odin:77`) are
absolute constants the emitter reads directly. Everything else in this document is
downstream of fixing that.

---

## 8. Per-format specifics

> Constants below are from memory of the ABI documents. **Verify each against `elf.h`,
> `mach-o/loader.h` and the AArch64 ELF spec at implementation time** — a wrong relocation
> number is a silent, miserable bug.

### 8.1 ELF: x86-64 vs aarch64

| Field | x86_64 | aarch64 |
|---|---|---|
| `e_machine` (`elf.odin:135`) | `0x3E` | `0xB7` |
| `p_align` (`elf.odin:156`) | `0x1000` | **`0x10000`** |
| `R_*_GLOB_DAT` (`elf_dynamic.odin`) | `6` | `1025` |
| `R_*_RELATIVE` | `8` | `1027` |
| `DEFAULT_INTERP` | `/lib64/ld-linux-x86-64.so.2` | `/lib/ld-linux-aarch64.so.1` |
| syscall insn / nr register | `syscall` / `rax` | `svc #0` / `x8` |
| `write` / `exit` | `1` / `60` | `64` / `93` |
| `e_flags` | 0 | 0 |

Two of these bite:

- **`p_align` must be `0x10000` on aarch64.** Linux/aarch64 kernels ship with 4K, 16K *or*
  64K pages (Fedora/RHEL/SUSE use 64K). A segment aligned only to `0x1000` mismaps or is
  rejected on a 64K-page kernel. 64K also satisfies Android 15+'s ≥16K requirement, so one
  value covers everything.
- **The interp path changes in all three parts** — directory, name, *and* version suffix.
  Not a substring edit.

### 8.2 PIE

`e_type` (`elf.odin:134`) goes `2` (ET_EXEC) → `3` (ET_DYN); `ELF_BASE` becomes `0` so
`p_vaddr` is an image-relative offset.

There are exactly **two absolute references** in the emitted code today — `ARGS_TABLE_VADDR`
and `GOT_VADDR`, both deliberately fixed per the comments at `elf.odin:57-79`. Make both
PC-relative and PIE is done.

**Key consequence: if every internal reference is PC-relative, a static PIE needs ZERO
runtime relocations.** No `PT_INTERP`, no self-relocation stub, no `R_*_RELATIVE`
processing at startup — ET_DYN with an empty reloc table just works, because the kernel
maps the image anywhere and nothing in the code cares where. The emitted code is simple
enough that this is fully achievable. **Do not build a bootstrap relocator.** (Dynamic PIE
with imports is unchanged — the loader fills the GOT.)

**How PC-relative differs per ISA:**

*x86_64* — RIP-relative is a native addressing mode, one instruction, ±2 GB:
```
lea rax, [rip + disp32]        ; disp32 patched at layout time
```
Needs a RIP-relative form in `AddressComponents` if absent. Cheap.

*aarch64* — no PC-relative load of a full address. A **two-instruction pair**:
```
adrp x0, <page>     ; ±4 GB, gives the 4 KB PAGE base, low 12 bits zeroed
add  x0, x0, #lo12  ; offset within the page
```
Relocation pair: `R_AARCH64_ADR_PREL_PG_HI21` (275) + `R_AARCH64_ADD_ABS_LO12_NC` (277).
`adr` is the one-instruction form but only ±1 MB. The skeleton at
`compiler/backends/arm64/arm64` already stubs `adrp_x64` / `adr_x64`, so this was
anticipated.

**Trap to watch:** `adrp` works in 4 KB pages *regardless of `p_align`*. The patch value is
`(target >> 12) - (pc >> 12)`, not a byte delta, and it stays 4 KB even with
`p_align = 0x10000`. That off-by-page is the classic aarch64 codegen bug.

### 8.3 Mach-O (macOS, iOS)

macOS is **Mach-O**, not ELF. Same for iOS/tvOS/watchOS.

| Piece | Value |
|---|---|
| Magic | `MH_MAGIC_64` = `0xFEEDFACF` (`mach_header_64`) |
| cputype | `CPU_TYPE_X86_64` = `0x01000007` · `CPU_TYPE_ARM64` = `0x0100000C` |
| filetype | `MH_EXECUTE` = 2 · `MH_DYLIB` = 6 |
| Fat/universal wrapper | `FAT_MAGIC` = `0xCAFEBABE`, **big-endian** fields, N slices |
| arm64 page size | 16 KB → segment align `0x4000` |
| `LC_BUILD_VERSION` platform | macOS = 1 · iOS = 2 · iOS Simulator = 7 (dyld checks it) |

**Load commands replace program headers** — a variable-length list, not a fixed table:
`LC_SEGMENT_64` (`__PAGEZERO`, `__TEXT`, `__DATA`, `__LINKEDIT`), `LC_MAIN` (entry),
`LC_LOAD_DYLINKER` (`/usr/lib/dyld`), `LC_LOAD_DYLIB` per library, `LC_SYMTAB`,
`LC_DYSYMTAB`, `LC_DYLD_CHAINED_FIXUPS` on modern macOS, `LC_CODE_SIGNATURE`. PIE is the
default (`MH_PIE`).

Three things that hurt:

1. **Code signing is kernel-enforced on Apple Silicon** — see §9.
2. **Dylibs load by PATH, not soname.** `LC_LOAD_DYLIB` carries
   `/usr/lib/libSystem.B.dylib`. interop.md's stated principle — *"libraries themselves are
   named, never pathed"* — is Linux-specific and breaks here. Resolved in `abi.md` §4.
3. **Symbols are underscore-prefixed** (`_sqrt`, not `sqrt`), and libSystem is effectively
   mandatory because Apple does not guarantee syscall numbers. The "direct syscalls, no
   libc, static binary" default does not survive on Apple platforms at all.

### 8.4 PE/COFF (Windows)

Reuses the existing x64 backend untouched — new container only. IAT-based imports (the
loader patches an import address table; same mechanism as the GOT, different table). No
signing needed to execute; Authenticode only affects SmartScreen reputation on downloaded
files.

Known accepted gap: ELF and Mach-O both take DWARF, so `image/dwarf` is shared, but PE
wants CodeView/PDB. DWARF-in-PE works with gdb/lldb and not with WinDbg/MSVC. Fine to start
there — a known gap, not a bug.

### 8.5 Android ELF specifics

- PIE **required** (API 28+ rejects non-PIE executables; a `.so` is ET_DYN by definition).
- `DEFAULT_INTERP` → `/system/bin/linker64`.
- **No versioned sonames.** `libm.so`, not `libm.so.6`. Every `<libm.so.6>` in the corpus
  is Linux-only. Resolved in `abi.md` §4.
- `p_align` ≥ 16 KB (Android 15+ / Play requirement); `0x10000` from §8.1 covers it.
- **Linker namespaces:** since Android 7 an app may only load the NDK-public set (libc,
  libm, libdl, liblog, libz, libEGL/libGLESv*, libvulkan, libOpenSLES, libaaudio,
  libjnigraphics, libnativewindow, libmediandk, libcamera2ndk). `libcrypto`, `libpcre2`,
  `libasound`, `libSDL2` from interop.md's verified table are **not** loadable from an app
  namespace — they must ship inside the APK. That verification matrix needs re-running
  against the NDK set.
- **Split RX / RW segments.** The current single RWX `PT_LOAD` (`elf.odin:148-150`,
  `p_flags = 7`) is blocked by SELinux for app processes (`execmem`/`execmod` denials).
  This reintroduces the second-segment alignment constraint the comment at `elf.odin:68-70`
  was avoiding.
- **JNI path needs exported symbols.** `elf_dynamic.odin` today writes only `SHN_UNDEF`
  import entries; a `.so` needs *defined* globals in `.dynsym` (`JNI_OnLoad` or
  `Java_pkg_Class_method`), plus `.init_array`. The 8-bit exit-status result channel is
  also meaningless across JNI — needs real return values.

---

## 9. Signing — Android vs Apple are different categories

**Android signs the APK (the ZIP), not the ELF.** The kernel never checks a signature on an
ELF binary.

- The **`adb push` executable path needs no signing at all.** Push to `/data/local/tmp`,
  `chmod +x`, run. The first Android milestone is signature-free.
- APK signing is **self-signed** — you generate the key; no vendor, no approval, no
  account. Scheme v2/v3 is a signing block inserted in the ZIP before the Central
  Directory, over a chunked digest of the file.
- Fully implementable in-house: Odin core has `core:crypto/sha2` and `core:crypto/ecdsa`,
  and v2 supports ECDSA P-256 (no RSA in core; not needed). APK entries may be `STORED`, so
  no deflate required either.
- Play App Signing is *distribution*, not execution.

**Apple signs the binary, and the kernel enforces it.**

- **macOS arm64: mandatory even for a local run.** An unsigned arm64 Mach-O is killed by
  the kernel.
- **Ad-hoc signing needs no certificate and no key.** A CodeDirectory blob holding SHA-256
  of every 4 KB page of the file, wrapped in a SuperBlob with the `CS_ADHOC` flag, placed
  in `__LINKEDIT` and pointed at by `LC_CODE_SIGNATURE`. `core:crypto/sha2` covers it. The
  kernel accepts ad-hoc for local execution.
- **No Xcode required for macOS.** Not Xcode, clang, ld64, an SDK, `codesign(1)`, or an
  Apple account. At runtime you need only `dyld` + `libSystem`, which ship with the OS.
  Gatekeeper/notarization applies to *distributed* (quarantined) binaries; locally built
  ones just run.
- References to diff bytes against: **`rcodesign`** (Rust) and **`ldid`** (saurik) both
  sign Mach-O without Xcode. Constants live in public xnu/dyld sources.
- **iOS device: not self-contained, and it is policy, not technology.** Requires a
  signature chained to an Apple-issued certificate plus a provisioning profile with the
  device UDID and entitlements, validated on-device by `amfid`. Ad-hoc is rejected. A paid
  Apple Developer account is unavoidable. Xcode-the-IDE is avoidable (rcodesign/ldid apply
  a real signature given cert + profile; libimobiledevice installs).
- **Staging step that matters: the iOS Simulator.** macOS-hosted, `LC_BUILD_VERSION`
  platform 7, signed like a macOS binary — **ad-hoc works.** iOS-shaped output can run with
  no Apple account; the wall is only at physical-device deploy. Start iOS work there.

### Scorecard: "the compiler writes every byte"

| Target | Runs unsigned? | Fully self-contained? |
|---|---|---|
| Linux ELF | yes | ✅ already proven |
| Windows PE | yes | ✅ |
| Android — `adb` executable | yes, nothing checks ELF | ✅ |
| Android — installable APK | no | ✅ self-signed; sha2 + ecdsa in Odin core |
| macOS x86_64 | yes | ✅ |
| macOS arm64 | **no** — kernel-enforced | ✅ ad-hoc, no cert |
| iOS Simulator | ad-hoc accepted | ✅ |
| iOS device / App Store | no | ❌ Apple cert + profile |

**iOS-on-device is the single place the zero-dependency principle breaks**, and it breaks
on Apple policy, not on anything engineerable. Everywhere else, every byte stays ours.

---

## 10. Hot reload

**This is not UI hot reload, and it must not be designed as if it were.** Flutter's reload is
inseparable from the widget tree: it pushes a kernel diff, then the *framework* completes the
operation by rebuilding (`reassemble()`). For a Dart program with no UI framework, reload
changes the code and nothing re-invokes it — so it is close to useless. Syntact's must work for
a CLI, a test run, a server, and a GUI alike.

The general form falls out of the language rather than a framework hook: **running is collapsing
the file-scope** (`specs/language/03-first-program.md`), so reload is *re-collapsing from the point the change
invalidated*. Because `reduce` is pure and dependency-tracked, that point is known exactly.

**Reload unit = a binding in a scope.** Content-address each binding as
`hash(source_text, hashes_of_dependency_reduced_forms)`. On change: re-parse, re-analyze,
re-reduce only bindings whose hash moved, push the changed bytecode range. Perfect memoization
— a build system with exact invalidation, not a VM hack. Dart cannot do this; there is no
mutable class identity to preserve.

**The reload boundary is the collapse point that re-reads the changed binding.** No framework
participation is required, which is what makes this work without a GUI. Three cases, and the
resident VM must handle all three — it may not assume a frame loop or an event pump:

| Program state | Reload means |
|---|---|
| already terminated (a CLI, a test) | re-collapse the root — an *incremental re-run*, near-instant because everything unchanged is cached. Degenerating to a fast re-run for a batch program is the honest answer, and still the whole feedback loop. |
| inside a loop (server, game, event pump) | swap the bindings; the next iteration re-reads them. Nothing to notify. |
| blocked on a syscall | swap the bindings; they take effect when the blocking call returns. |

**One cache, two jobs.** The same content-addressed store serves hot reload *and*
cold-build speed. `resolve.odin:36` already has a per-file `Cache` struct and a thread
pool; the on-disk cache is stubbed off (`main.odin:33` forces `no_cache = true`, flags
commented at `main.odin:71-74`). Build it once, deliberately.

**Resident VM.** `interp_bytecode` is one-shot: run, return. It becomes a long-lived process
holding a `BC_Program`, listening on a socket (`adb forward` / local port), accepting a
patch, swapping instructions, re-entering. The VM stays in `bytecode/` to preserve
invariant 1; the session wrapper lives in `compiler/reload/`.

**The state rule — decide it WITH the effects design, not after.** Today there is no mutable
state at all, so reload preserves nothing because there is nothing to preserve. Once
effects.md's handlers land there is live state, and the rule is scoped precisely to it: *state
lives in resonant bindings inside handlers; a handler whose shape is unchanged keeps its state,
a handler whose shape changed resets.* Note this is narrower and better-defined than Flutter's
widget-identity rule — resonance is the only place mutation exists
(`specs/language/17-resonance-and-reactivity.md`), so it is the only thing a reload can disturb. Retrofitting this later is how these systems get ugly.

**The interpreter is the debug tier on all five platforms** — and on iOS it is *mandatory*,
since JIT is forbidden. So this is built once and shipped everywhere. It is also, with C/JS
deferred, the **only oracle**: `test/codegen` differentials interp vs native with no third
opinion. That raises the stakes on `interp.odin` being correct — worth an explicit audit
pass rather than an assumption.

---

## 11. Open questions

**External linking and ABI — now specified separately in `abi.md`.** That document covers the
three concerns this one previously scattered as per-format trivia: calling conventions per
(arch, OS), link mechanism per container, and library naming per platform. Two items from it
that change decisions in *this* document:

- The **library reference model** (four different names for `libm` across platforms) is
  resolved there in §4: provenance stays opaque to the compiler, and the per-target name is an
  ordinary comptime branch in source (`sdk.md` §3.1) — no configuration layer.
  `Platform.lib_ref` here covers only the *form* the container needs, never the name.
- **`Abi` becomes a record** alongside `Platform` (§4 here), and `emit_foreign_call`'s SysV
  hardcoding — register lists, independent int/SSE counters, the 6-argument ceiling — becomes
  data. Windows x64 needs positional slots and 32-byte shadow space; Apple aarch64 passes
  variadics on the stack. See `abi.md` §2.2.

**interop.md §2 — addresses, pointers, structs, callbacks — still OPEN, and it is now on the
critical path** (see below). It gates anything past scalar arguments, which is the current
documented limit. `abi.md` §6 records why aggregate passing is four implementations rather
than one feature, and §7 why callbacks are the reverse-direction problem.

### UI and games: one Syntact library, no embedded engine — DECIDED

No third-party engine is bound. The GUI framework and the game framework are **one ordinary
Syntact library** — a folder of `.syn` (§6.2), expanded through `@`, reduced at the consumer.
This is what `specs/language/17-resonance-and-reactivity.md` already sketches, ending on
*"`State`, `Column`, `Text`, and `Button` are scopes. The SDK should be a library of scopes, not a
second language."*

Unifying GUI and games is more defensible here than in most ecosystems. The usual split is
retained-mode/event-driven/layout on one side and immediate-mode/frame-driven on the other —
but reactivity (`>>=`) gives the retained-mode propagation and the execution patterns (`[!]`, `|!|`)
give frame-parallel and GPU dispatch, over the same scope algebra — see
`specs/language/17-resonance-and-reactivity.md` and `specs/language/07-execution-patterns.md`. Both faces, one set of primitives. What genuinely differs is **frame pacing and
allocation discipline**: games need predictable per-frame cost, GUI tolerates variance. The
`Alloc` handler pattern (`specs/language/15-effects-and-handlers.md`) is where that is expressed, so it is a handler
choice rather than two frameworks.

**Two consequences that change this document's priorities:**

**1. The frontier stops being optional.** A Syntact-native renderer must call Vulkan / Metal /
D3D / GL, and windowing and input must call Win32 / Cocoa / X11-Wayland / NativeActivity /
UIKit. Those are struct-heavy APIs and every one of them delivers input through callbacks. So
`abi.md` §6 (aggregates) and §7 (callbacks) plus interop.md §2 (addresses) are **prerequisites
for GUI**, not later refinements. Scalars-in-registers cannot bind Vulkan.

Note that this is *not* `|!|`. The GPU execution pattern is a **collapse strategy for compute**
— `specs/language/07-execution-patterns.md` is explicit that a GPU collapse may yield zero kernels,
one, several, or library calls, and that it "does not expose a kernel model in the source language". Rendering is
a different thing: a swapchain, command buffers, pipeline state objects, frame synchronization,
a presentation lifecycle. That is driving a graphics API through `<lib>`, not asking for a scope
to be collapsed on the GPU. Both uses of the GPU coexist and must not be conflated — `|!|` for
compute, `<lib>` for the renderer.

**Impeller's thesis and Syntact's thesis coincide**, which is worth exploiting deliberately.
Impeller exists because Skia's runtime shader compilation causes jank; its answer is to compile
every shader and pipeline ahead of time. Syntact's answer to everything is to reduce ahead of
time. So pipeline state and shader specialization should be *reduced forms* — resolved by the
reducer at compile time, not assembled at runtime. A renderer built this way gets Impeller's
central property for free rather than as an engineering effort.

**2. Debug-profile framerate is an open problem.** Flutter's debug mode interprets only *app*
code; its renderer is AOT native C++. If the renderer is Syntact and the debug profile runs on
the interpreter (§6.3), a 60 Hz frame loop goes through the interpreter too, and that is
unlikely to hold frame rate. The likely answer is a **mixed tier** — AOT the library
dependencies, interpret only the scope being edited — which directly constrains the reload unit
in §10, since the reload boundary and the AOT/interpreted boundary would have to agree. Not
solved here; flagged because it follows directly from the decision above and is cheaper to
design for now than to retrofit.

**Volatile vs the reducer** (deferred with embedded, but noted): a volatile read is stronger
than an effectful call — two reads of the same address must both survive. `foreign_lib` on
`Scope_Type` is the existing "don't fold through this" hook but does not express that yet.

---

## 12. What blocks what

Facts and hard constraints, not an ordering — the sequencing is yours to choose. The
per-target dependency table is at the end of §6.

### Work the current code demands, independent of any target

| Item | Why | Where |
|---|---|---|
| `Target` record + `--target` + dispatch | no target concept exists; `x64.*` is called directly | `resolve.odin:455-469` |
| Relocation-based codegen | absolute addresses in the emitter violate invariant 4; blocks PIE, `.so`, Mach-O, PE | §3, §7, `elf.odin:40/60/77` |
| Layer split | ELF lives inside `package x64_assembler` | §5 |
| Loops / backward edges | liveness is forward-only by design; also gates the recursion→loop lowering | `regalloc.odin:15-19` |
| DWARF line mapping | no debug info exists | §5 |
| Interpreter audit | it is the only oracle once C/JS are deferred | §10 |
| `Abi` record | `emit_foreign_call` is SysV-hardcoded | `abi.md` §2.3 |

### Hard constraints, not preferences

- **A new ISA and a new container should not be debugged together** (§6.2). Windows is a new
  container against a known ISA; Linux/aarch64 is a new ISA against a known container.
- **aarch64 gates Android, iOS, and Apple Silicon macOS.** Nothing else does.
- **Mach-O gates macOS and iOS**, and macOS arm64 additionally requires ad-hoc signing to
  execute at all (§9).
- **macOS x86_64 runs unsigned; macOS arm64 does not** — so the Mach-O writer can be developed
  and tested on Intel before signing exists (§9).
- **iOS Simulator accepts ad-hoc signing; iOS device does not** — so everything except physical
  deployment can proceed without an Apple Developer account (§9).
- **Android needs no signing for the `adb` executable path**, only for an installable APK (§9).
- **PIE with no absolute references needs zero runtime relocations** — no self-relocation stub
  (§8.2).
- **`p_align` must be `0x10000` on aarch64** or the image mismaps on 64K-page kernels (§8.1).

### Deferred, per the §1 scope decision

C-hosted, C-freestanding (embedded), JS, wasm. Two notes kept because they constrain decisions
made earlier:

- The **structurizer/relooper** is needed only by JS and wasm. It is nearly free while branches
  are forward-only and hard once loops land — so if wasm or JS are ever wanted, the loop work
  must be designed with structured control flow in view.
- A **C backend would add a third differential oracle**, which is the one thing that would
  relax the interpreter-audit item in the first table above.
