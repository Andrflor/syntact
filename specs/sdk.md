# Syntact SDK — command surface specification

> Design notes. **Nothing here is implemented.** Today there are two separate binaries
> (`compiler.bin` from `compiler/`, `lsp.bin` from `lsp/`) and `main.odin`'s flag parser
> *is* the entire interface.
>
> Companion document: `targets.md` specifies the backend architecture and the
> (Target, Artifact, Profile) triple this surface selects. This document specifies the SDK
> around it — the Flutter-shaped tool, not the compiler.

---

## 1. One binary, subcommands

`syntact <command> [args]`. This replaces both `compiler.bin` and `lsp.bin`; the LSP becomes
`syntact lsp` rather than a second executable (§9).

Today's developer flags — `--ast --ir --bc --regalloc --emit --parse-only --analyze-only
--print-errors --run --timing` (`main.odin:40-78`) — survive as inspection flags on
`build` and `check`, not as the primary interface.

---

## 2. The command surface

| Command | Default profile | Purpose |
|---|---|---|
| `syntact create <template>` | — | scaffold a project (§6) |
| `syntact run` | **debug** | build → deploy → connect → watch → hot reload (§8) |
| `syntact build` | **release** | produce something **the OS or a user runs** — `Executable`, `App_Package` |
| `syntact bundle` | **release** | produce something **another toolchain links** — `.so` / `.dylib` / `.dll` / `.a` / `.lib` / `.o` |
| `syntact test` | debug | the six declarative suites + project tests |
| `syntact check` | — | parse + analyze, no codegen (today's `--analyze-only`) |
| `syntact format` | — | format in place; `--check` for CI (§10) |
| `syntact lsp` | — | language server on stdio (§9) |
| `syntact devices` | — | list connected/available devices (§7) |
| `syntact doctor` | — | probe the environment; explain what is missing (§7.3) |
| `syntact clean` | — | remove build outputs and caches (§11) |

Every build-shaped command accepts:

```
--target <t>        repeatable; defaults to host
--artifact <a>      Executable | Shared_Library | Static_Library | Object
                    | App_Package        (§5 — there is no library artifact)
--profile debug|release     overrides the default above
--device <id>       run/test only
-o <path>
```

**`run` requires the root file-scope to have a production** — collapsing it *is* running the
program (`specs/language/03-first-program.md`). A tree with no root production has nothing to run; use `bundle` or
`test` instead. This is a structural precondition, not a project category (§5).

**Why `run` defaults to debug and `build`/`bundle` to release:** `run` means "I am iterating"
— interpreter, hot reload, full DWARF. `build`/`bundle` mean "I am producing an artifact" —
AOT native, packaged, signed. Both defaults are overridable with `--profile`; nothing about
the pipeline is profile-locked.

See `targets.md` §6.3 for exactly what the two profiles change. The important property:
reduce is semantics, not optimization, so **both profiles compute the same residual by
construction** — there is no "works in debug, breaks in release" class of bug here.

---

## 3. There is no project file

**There is no manifest, no project descriptor, no configuration format.** Not a YAML file, not
a TOML file, and not a `project.syn` either. The SDK takes a source file and reduces it.

### Finding the root

```
syntact build foo.syn     → the file given
syntact build             → main.syn, else lib/main.syn, else error
```

That is the whole of project resolution. No search for a descriptor, no project directory
detection, no notion of "being inside a project."

### Why there is nothing else to configure

Everything a manifest would have carried is either already expressible *in the source*, or is
a property of the invocation. It is never project data:

| Would-be field | Where it actually lives |
|---|---|
| project identity | the artifact name — the root file's name, or `-o` |
| root file | the resolution rule above |
| target list | chosen at the invocation: `build` selects the target(s) it emits for, `run` selects one (possibly from connected devices, §7) |
| artifact | chosen at the invocation: `--artifact` |
| external library names | ordinary Syntact — a binding that differs per target (§3.1) |
| exports | ordinary Syntact — what the source says it exposes |
| dependencies | `@` resolves the filesystem as a scope graph (`specs/language/18-modules.md`); there is no dependency list to declare |
| signing identity | a property of the machine, not the source — discovered or passed at invocation (§7.4) |

A configuration layer for any of these would be a **second, weaker language** sitting beside
Syntact and duplicating what scopes already do. That is precisely the sort of parallel ontology
the language rejects: *"there is no separate import ontology"*, *"the compiler is the reducer
used before runtime"* (`specs/language/18-modules.md`).

### 3.1 `@platform`

`@` prefixes name **namespaces you operate in**, not special cases inside one shared space.
`@platform` is the namespace for what is platform-determined. Importing files from the current
tree is a *different* namespace under its own prefix — potentially `@lib`, **not settled**
(§3.2).

`@platform` is supplied by the compiler, so everything under it is known at comptime. Which
means **nothing special is needed to branch on it**: no conditional-compilation directive, no
`#if`, no attribute. A branch on a comptime value is reduced by the ordinary reducer and the
dead branch is gone — the same mechanism that turns `"hello, " + "world"` into one string.

A library can therefore be declared differently per platform:

```syntact
libm -> @platform.os ? {
  linux  -> <libm.so.6>{ sqrt -> { f64:x -> ??::f64 } }
  macos  -> <libSystem.B.dylib>{ sqrt -> { f64:x -> ??::f64 } }
}
```

and a program can refuse a platform outright, at compile time:

```syntact
@platform.arch ? {
  aarch64 -> ...
  ~aarch64 -> !unsupported_target
}
```

This is why library naming needs no manifest and no compiler table. The invariant *"no library
is privileged — the compiler contains no mention of any library name"* (`interop.md` §1) holds
unchanged: the name lives in source, in a branch that reduces.

#### What `@platform` exposes

**The governing principle is that the programmer gets the power.** `@platform` is not a
curated set of blessed predicates — it is what the compiler knows about the machine, handed
over. If the compiler had to know something to emit code, the program can read it and branch on
it. Anything withheld would force exactly the escape hatches (config layers, build scripts,
per-platform source trees) this design removes.

**Identity — what machine this is.** Sets, so they are branched on and constrained with the
ordinary algebra:

```
os              linux | macos | ios | ios_sim | android | windows
arch            x86_64 | aarch64
abi             sysv | win64 | aapcs64 | aapcs64_apple
image           elf | macho | pe
family          unix | windows          derived; convenience for the common branch
```

**Layout — the shapes that differ per platform.** These are *shapes*, not descriptors: they
color bindings directly, which is what makes a `size_t` at the C frontier writable without the
compiler privileging anything.

```
usize           unsigned integer shape, pointer-width
isize           signed integer shape, pointer-width
ptr_width       64                          the number, when the shape is not what is wanted
endianness      little | big
char_signed     whether C `char` is signed  (differs: x86 Linux vs ARM)
long_width      C `long` — 64 on LP64, 32 on Windows LLP64
align_max       maximum fundamental alignment
```

`@platform.usize:len -> 0` is then an ordinary colored binding.

**Capability — what the platform can do.** These are what make a branch *meaningful* rather
than cosmetic, and each corresponds to a real divergence already recorded in `targets.md` §4:

```
syscalls        whether direct syscalls are available; false ⇒ must route through libc
                (nil on macOS/iOS — `targets.md` §4, and the mechanism effects.md:121 predicted)
libc_name       "libc.so.6" | "libSystem.B.dylib" | …
lib_ref         soname | unversioned_soname | path       how a library is referenced
sym_prefix      "_" on Mach-O, "" on ELF
pie             optional | required
page_size       platform page size
```

**Build context — what this invocation is.** The target and artifact are chosen at the
invocation (§3), and the program can read what was chosen:

```
artifact        Executable | Shared_Library | Static_Library | Object | App_Package
profile         debug | release
```

`profile` is deliberately readable: a program may want debug-only assertions or logging that
reduce away entirely in release. That is the reduce mechanism doing what it already does, not a
preprocessor.

**ISA features** — SIMD width and extension bits (`sse4.2`, `avx2`, `neon`, …) are the obvious
next block, and the one that most rewards handing power to the programmer, since a Syntact
library specializes by carving rather than by shipping per-CPU binaries. Left **open** here:
`vectorize.odin` is x64-only today, so the honest feature list is whatever the backend actually
tracks, and that is one ISA short.

**Alignment with `targets.md` §4.** The `Platform` record there is the backend's form of this
same knowledge, oriented toward emission (`entry_exe`, `entry_app`, `result_kind`). The
capability block above is deliberately the same data under source-facing names. **They must be
one definition with two views, not two lists that drift** — the entry/result fields stay
backend-only, since a program has no use for how its own entry stub is shaped.

Default mappings for common C libraries are then just an ordinary Syntact library — a folder of
`.syn` reached through its namespace prefix, carrying exactly the branch above. Not compiler
data, and not project data.

### 3.2 Open — the namespace prefixes

`@platform` is settled. What is **not** settled is the rest of the prefix space: the prefix for
importing from the current tree (potentially `@lib`), whether third-party libraries get their
own, and whether the set of root namespaces is fixed by the compiler or extensible. The
resolution rule for each namespace follows from what it names, so this has to be decided before
`@` resolution is implemented.

---

## 4. Where it lives

The compiler becomes a library; the SDK is a layer above it.

```
compiler/            the compiler proper — no CLI, no I/O policy
  ...
  backends/          (targets.md §5)
lsp/                 ← MOVED under sdk/, or kept and invoked by sdk/cli
sdk/
  cli/               subcommand dispatch, flag parsing, help
  source/            root resolution (§3), `@` scope-graph resolution
  device/            discovery + transport (§7)
  toolchain/         doctor probes, signing identity discovery
  templates/         create scaffolds (§6)
  session/           the run loop: build → deploy → connect → watch → reload (§8)
  format/            the formatter (§10) — shared with lsp
```

`format/` must be a library, not a command, because `syntact format`, the LSP's
`textDocument/formatting`, and `create`'s template emission all need the same one.

---

## 5. Libraries — there is no library artifact

A Syntact library is **a folder of `.syn` files**, and publishing it means shipping the
folder. `specs/language/16-external-boundary.md` states both halves: *"there is no separate notion of
'a library'"* and *"There is nothing to bundle."* A folder is a scope, a file is a scope, `@` resolves the
filesystem as a scope graph, and `...@lib.geometry` expands it into the consumer, which
reduces it *there*. No package format, no serialized IR, no interface file, no ABI, no
version-compatibility surface. Full statement in `targets.md` §6.2.

So the artifact axis only has entries where Syntact meets something that is **not** Syntact:

| I want to… | Artifact |
|---|---|
| publish a library for Syntact consumers | **nothing — ship the folder** |
| let C/Rust/Python link my code | `Shared_Library` / `Static_Library` / `Object` |
| ship a runnable program | `Executable` |
| ship an installable app | `App_Package` |

**So `bundle` is the C-ABI direction**, and that is its whole job: turn a Syntact source tree
into `.so` / `.dylib` / `.dll` / `.a` / `.lib` / `.o` so that C, Rust, Python, or anything
else can link it. `--artifact` selects which of those.

**Which means there is no such thing as "a library project."** Bundling is a question you ask
of a source tree, not a property the tree declares. Any tree with `exports` can be bundled,
and the same tree can have a root production and be `build`-able as a program at the same
time.

The three build commands therefore divide by **who consumes the output**:

```
run      → nobody; it runs now, in debug, hot-reloadable
build    → the OS or a user          Executable, App_Package
bundle   → another toolchain         Shared_Library, Static_Library, Object
```

**Multi-target is a flag, not a command.** `--target` is repeatable on both `build` and
`bundle`, and the platform's combination rule (`targets.md` §6.4) fires automatically:

```
syntact build  --target macos-arm64 --target macos-x64    → universal executable
syntact bundle --target macos-arm64 --target macos-x64    → universal .dylib
syntact bundle --target android-arm64                     → .so
syntact build  --target android-arm64 --artifact App_Package  → multi-ABI APK
```

A tree written purely for Syntact consumers simply never gets `build` or `bundle` run on it —
only `check`, `test`, `format`, and being reached through `@`. Nothing declares that; it is
just which commands are meaningful.

### What each command requires

Since nothing is declared, each command has a **structural** precondition it checks:

| Command | Requires |
|---|---|
| `run` / `build` | the root file-scope has a production — *"Running the program means collapsing the file-scope"* (`specs/language/03-first-program.md`). No production ⇒ nothing to run. |
| `bundle` | at least one declared export |
| `check` / `test` / `format` | nothing |

Both preconditions are properties of the source, checked by the compiler — not declared
anywhere.

**Open: how are exports declared?** In the source, since there is nowhere else (§3). A scope
already *has* a production and a set of bindings; what `bundle` needs is to know which bindings
become C-ABI symbols. Whether that is read off the scope's structure directly or needs a
language-level marker is not settled. What is settled: it is not an external list.

---

## 6. `create`

```
syntact create cli <name>
syntact create gui <name>
```

`cli` is small: a `main.syn` with a root production, and a test stub. Nothing else — there is
no project file to scaffold (§3).

**`gui` is the substantial one, because a GUI app needs per-platform host material** — the
same reason `flutter create` lays down `android/`, `ios/`, `macos/`, `linux/`, `windows/`
alongside `lib/`. An app is not just code; each platform requires its own metadata and assets
to be installable, and those cannot be derived from the source tree.

```
myapp/
  main.syn
  src/
  test/
  android/     AndroidManifest.xml, app id, permissions, min SDK, icons, resources
  ios/         Info.plist, entitlements, icons, launch screen
  macos/       Info.plist, entitlements, icons
  windows/     icon, version info, application manifest
  linux/       .desktop entry, icon
```

**But those folders hold declarative metadata and assets — not build systems.** Flutter's
`android/` is a full Gradle project and its `ios/` is a full Xcode project, because Flutter
delegates building to those toolchains. Syntact writes every byte of the binary itself
(`targets.md` §9), so there is no Gradle, no Xcode project, no CMake. What remains is exactly
the material the *platform* demands and the compiler cannot invent: the Android manifest, the
Apple `Info.plist`, entitlements, icons, launch images.

This is the same asymmetry as §7.3: much less scaffolding than Flutter, for the same
structural reason.

**The declarative half belongs in source.** App id, permissions, entitlements are named
values — so they are bindings, carved per platform through `@platform` like anything else (§3.1),
and *emitted* into the package at build time. That avoids five config dialects and needs no
project file. Assets are binary files and must sit on disk regardless, so the folders stay for
assets.

What is not settled is the emission side: which platform files are generated wholly from
source, and whether any must remain hand-editable on disk for the cases the compiler cannot
anticipate.

For reference, entry point is selected by `--artifact` × platform — not by which template was
used. This is what `Platform.entry_exe` / `entry_app` / `entry_lib` in `targets.md` §4 encode:

| Artifact | Linux / Windows / macOS | Android | iOS |
|---|---|---|---|
| `Executable` | `_start`, argc/argv | `_start` (adb shell) | not a user-facing concept |
| `App_Package` | window + native event loop | `JNI_OnLoad` / NativeActivity | `UIApplicationMain` |
| `Shared_Library` | dylib init | `JNI_OnLoad` | dylib init |

A tree intended for Syntact consumers needs no scaffold beyond a directory and a `.syn` file,
so there is no template for it.

---

## 7. Devices, transports, doctor

### 7.1 The abstraction

```odin
Transport :: enum { Local, Adb, Simctl, Ios_Device }

Device :: struct {
    id:        string,
    name:      string,
    target:    string,     // which --target this device accepts
    transport: Transport,
    online:    bool,
}
```

A transport owns five operations, and that is the whole interface `session/` needs:
**push** the artifact, **spawn** it, **forward** the reload port, **stream** stdout/logs,
**kill**.

| Transport | push | spawn | forward | logs |
|---|---|---|---|---|
| `Local` | copy | exec | localhost socket | pipe |
| `Adb` | `adb push /data/local/tmp` | `adb shell` | `adb forward tcp:P tcp:P` | `adb logcat` |
| `Simctl` | `simctl install` | `simctl launch` | localhost socket | `simctl spawn log` |
| `Ios_Device` | `ideviceinstaller` | debugserver proxy | usbmux tunnel | `idevicesyslog` |

**This is the "connect" half of hot reload.** `targets.md` §10 specifies a resident VM
listening on a socket; `Transport.forward` is what makes that socket reachable from the host.
`Adb` needs `adb forward`; everything else is a local port. Port forwarding belongs to the
transport, not to the VM.

### 7.2 `devices`

Discovery per transport: always report the local host; then `adb devices`,
`xcrun simctl list -j`, `idevice_id -l`. Report offline/unauthorized devices too, with the
reason — an unauthorized `adb` device is the single most common confusing state.

### 7.3 `doctor`

The point worth making up front: **`syntact doctor` will be nearly empty compared to
`flutter doctor`, and that is a direct consequence of the write-every-byte principle.**
Flutter's doctor is enormous because Flutter delegates building to Gradle, Xcode, and the
NDK. Syntact delegates none of it. So doctor checks what is needed to *deploy and run*, not
to build:

| Target | To **build** | To **run** |
|---|---|---|
| linux-x64 / arm64 | nothing | nothing (or `qemu-aarch64` to cross-run) |
| windows-x64 | nothing | Windows host |
| macos-x64 / arm64 | nothing | macOS host |
| android-arm64 | nothing | `adb` + an authorized device |
| ios-sim-arm64 | nothing | macOS host + `xcrun simctl` |
| ios-arm64 | **Apple cert + provisioning profile** | libimobiledevice / ideviceinstaller |

Every "nothing" in the build column is a claim the architecture has to keep earning. Doctor
should also state host constraints plainly (macOS and iOS targets can be *built* anywhere but
can only be *run* on a macOS host) and name the one hard wall: **iOS-on-device requires an
Apple Developer account**, per `targets.md` §9.

### 7.4 Signing identities

`doctor` and `build` share one probe. Three cases, three behaviours:

- **ad-hoc Mach-O** (macOS, iOS Simulator) — nothing to discover; the SDK generates it
  itself from `core:crypto/sha2`.
- **APK v2** — a self-signed key; generate and cache one per project on first use, like
  Android's debug keystore. No user setup.
- **iOS device / App Store** — must locate a real certificate and a matching provisioning
  profile. The only case that can fail for reasons the SDK cannot fix.

---

## 8. The `run` loop

```
resolve the root file (§3)
  → select (target, artifact=Executable, profile=debug)
  → ensure a native VM binary exists for that target        ← see §12 open decision
  → compile source to BC_Program
  → transport.push(vm, bytecode) ; transport.spawn ; transport.forward(port)
  → connect to the resident VM
  → watch the source tree
       on change: re-reduce only bindings whose content hash moved   (targets.md §10)
                  push the changed bytecode range
                  VM swaps instructions and re-enters
  → stream stdout/logs; 'r' to force reload, 'R' to restart, 'q' to quit
```

The watch → re-reduce → patch middle is `targets.md` §10 and is the same mechanism as the
cold-build cache. The push/forward/stream outside is §7.1. Nothing else is needed.

---

## 9. `lsp`

The server already exists (`lsp/lsp.odin`, `lsp/semantic.odin`) with diagnostics, hover,
go-to-definition, rename, completion, and semantic tokens (the root `README.md` Status section). Changes:

- becomes `syntact lsp` — one binary, so editors configure one command and version skew
  between compiler and server becomes impossible;
- gains `textDocument/formatting` and `textDocument/rangeFormatting`, both delegating to
  `sdk/format/` (§10) — currently absent;
- shares `source/` so it resolves `@` imports the same way `build` does, rather than guessing;
- shares the content-addressed cache from `targets.md` §10, so an LSP keystroke and a
  `run` reload reuse each other's reduce results instead of duplicating work.

Note: `~/.config/nvim/lsp.lua` already wires a `syntact` server against the current binary,
so the rename is a breaking change for the existing editor setup — worth doing in one step
with an alias, not silently.

---

## 10. `format` — and the constraint that makes it hard

Two facts from the current lexer make this materially harder than a normal formatter, and
both must be resolved before writing one line of it:

**(a) Syntact is whitespace-sensitive.** `parse.odin:11` — "the same byte lexes differently
by surrounding spaces" — and `COLON_TABLE[space_before][space_after]` (`parse.odin:372`)
picks the flavour of `:` from the spacing around it. Glue is decided by
`TRIVIA_BEFORE_MASK` (`parse.odin:331`).

> **A naive pretty-printer would silently change program meaning.** This is not true of
> gofmt, rustfmt, or clang-format, and it is the single most important thing to know about
> formatting this language.

**(b) Comments are discarded.** `skip_trivia` (`parse.odin:156`) treats comments as
whitespace and retains only *flags* about what preceded a token — the comment **text is not
kept**. A formatter cannot reproduce a file whose comments it never received.

So the formatter needs three things, in order:

1. **A trivia-retaining lex mode.** Either a lossless token stream (token + preceding
   trivia text) or comment nodes attached to AST positions. This is a real change to
   `parse.odin`, not an add-on — and it benefits the LSP too (comment-aware hover,
   doc-comment extraction).
2. **A glue-aware emitter.** The printer must know the whitespace-significance rules and be
   *forbidden* from emitting a spacing that would re-flavour a token. Formatting decisions
   are constrained by semantics, not only by style.
3. **A verification pass, non-optional.** Format → re-lex → re-parse → compare ASTs, and
   **refuse to write if they differ.** Given (a), this is not paranoia; it is the only way
   to know the formatter is sound. It also gives `--check` for free.

`--check` exits non-zero on any file that is not already canonical, printing a diff. No
in-place writes.

---

## 11. `clean`

Removes: build outputs, the on-disk reduce cache (`targets.md` §10), pushed device artifacts
where a transport can reach them, and generated signing material *except* a project's cached
APK debug key (deleting that would change the app's identity — it needs an explicit
`--all`).

---

## 12. Open decisions

**How does a device get its VM?** `run --target android-arm64` needs a syntact interpreter
binary *for* android-arm64. Two options:

- **Ship prebuilt VMs** per target with the SDK — Flutter's approach, because their engine is
  enormous. Costs release infrastructure and a per-target artifact matrix.
- **Cross-build the VM on demand with Odin.** The VM is `interp.odin`, ~338 lines, so
  compiling it per target is plausible — but Odin cross-compilation to Android/iOS is its
  own problem, and it reintroduces a toolchain dependency the rest of the design avoids.

A third path worth considering: once the aarch64 backend exists, the VM could in principle
be *hosted* — but it is written in Odin, not Syntact, so that only becomes real after
self-hosting. Not a near-term option.

**The namespace prefixes other than `@platform`** — current-tree imports, third-party
libraries, and whether the root set is fixed or extensible (§3.2).

**ISA feature exposure under `@platform`** — honest list requires a second backend's feature
tracking (§3.1).

**One definition, two views** for `@platform`'s capability block and `targets.md` §4's
`Platform` record, so they cannot drift (§3.1).

**How are exports declared** — read off the scope's structure, or a language-level marker (§5).

**Which platform files are generated from source vs. hand-editable on disk** (§6).

---

## 13. What blocks what

Facts, not an ordering — the sequencing is yours to choose.

| Item | Cannot happen until |
|---|---|
| subcommand skeleton, `source/`, `clean`, `check`, folding `lsp` in | nothing — pure refactor of existing behaviour |
| `format` | the lexer retains comment text and the glue rules are respected (§10) |
| `run` with hot reload | `targets.md` §10 — reduce cache, resident VM, patch protocol |
| `run` on a device | that device's transport (§7.1), plus a VM binary for its target (§12) |
| `bundle` | exported symbols in the image layer, and `abi.md` |
| multi-target `build`/`bundle` | the combination rules in `targets.md` §6.4 |
| `create cli` | nothing beyond the skeleton — a CLI is what the compiler already emits: argc/argv via `emit_arg_stub` (`emit.odin:161`), exit status via `emit_exit` (`emit.odin:467`) |
| `create gui` | an event loop, plus the GUI/game library existing — which itself needs aggregates and callbacks at the frontier (`targets.md` §11, `abi.md` §6-§7) |
| `doctor` / `devices` | nothing to build for — only deploy-side probes (§7.3) |

The skeleton and `format` touch no backend code at all.
