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
--target <t>        repeatable; defaults from the manifest
--artifact <a>      Executable | Shared_Library | Static_Library | Object
                    | App_Package        (§5 — there is no library artifact)
--profile debug|release     overrides the default above
--device <id>       run/test only
-o <path>
```

**`run` requires the root file-scope to have a production** — collapsing it *is* running the
program (README:270). A tree with no root production has nothing to run; use `bundle` or
`test` instead. This is a structural precondition, not a project category (§5).

**Why `run` defaults to debug and `build`/`bundle` to release:** `run` means "I am iterating"
— interpreter, hot reload, full DWARF. `build`/`bundle` mean "I am producing an artifact" —
AOT native, packaged, signed. Both defaults are overridable with `--profile`; nothing about
the pipeline is profile-locked.

See `targets.md` §6.3 for exactly what the two profiles change. The important property:
reduce is semantics, not optimization, so **both profiles compute the same residual by
construction** — there is no "works in debug, breaks in release" class of bug here.

---

## 3. Project manifest

An SDK needs a project file. What it must carry:

```
name            project identity
root            the root .syn file — the file-scope that is the program
targets         DEFAULT target list       (convenience; --target overrides)
artifact        DEFAULT artifact          (convenience; --artifact overrides)
exports         which bindings cross the C ABI, when bundling  (§5)
libs            per-target external library name mapping (abi.md §4)
dependencies    where to find other libraries — paths/sources for `@` to resolve (§5)
signing         per-platform identity config (§7.4)
```

**There is no `kind` field, deliberately.** Declaring what a project *is* would be exactly the
sort of built-in category the language rejects — *"the role it plays … comes from the
operation applied to it, not from a built-in category"* (README:323). A project is a source
tree. Which role it plays is decided by the command:

```
run / build   → the root file-scope's production is the program
bundle        → the named `exports` are C-ABI symbols
consumed by @ → it is a scope another tree expands
```

The same tree can serve all three at once. `targets` and `artifact` in the manifest are
**defaults so you do not retype flags**, nothing more — not a declaration of what the project
*is*.

**Proposal — write the manifest in Syntact.** A manifest is a set of named bindings; a
Syntact scope *is* a set of named bindings. So `project.syn` can be an ordinary scope,
reduced by the existing reducer, with no YAML/TOML/JSON parser and no second configuration
language. It also means the manifest is *computable* — a target list can be a fold, signing
config can carve per platform.

This is consistent with the project's stated aim (composable, algebraic, consistent) and it
removes a whole dependency. **Marked as a decision, not settled** — the risk is
bootstrapping order (the manifest must be readable before the project is configured) and
error quality for malformed manifests.

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
  project/           manifest parse/resolve, library resolution for `@`
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
folder. README:1579 — *"there is no separate notion of 'a library'"* — and README:1581 —
*"There is nothing to bundle."* A folder is a scope, a file is a scope, `@` resolves the
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
only `check`, `test`, `format`, and dependency resolution (§3). Nothing declares that; it is
just which commands are meaningful.

### What each command requires

Since nothing is declared, each command has a **structural** precondition it checks:

| Command | Requires |
|---|---|
| `run` / `build` | the root file-scope has a production — *"Running the program means collapsing the file-scope"* (README:270). No production ⇒ nothing to run. |
| `bundle` | at least one declared export |
| `check` / `test` / `format` | nothing |

Both preconditions are properties of the source, checked by the compiler, not categories
recorded in a manifest.

**Open: how are exports declared?** The manifest `exports` list is the obvious first answer
and keeps the language untouched. A language-level marker would be more expressive but adds
surface. Not settled.

---

## 6. `create`

```
syntact create cli <name>
syntact create gui <name>
```

`cli` is small: `project.syn`, a source root with a root production, a test stub.

**`gui` is the substantial one, because a GUI app needs per-platform host material** — the
same reason `flutter create` lays down `android/`, `ios/`, `macos/`, `linux/`, `windows/`
alongside `lib/`. An app is not just code; each platform requires its own metadata and assets
to be installable, and those cannot be derived from the source tree.

```
myapp/
  project.syn
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

**Open — folder or manifest?** The declarative half (app id, permissions, entitlements) could
live in `project.syn` and be carved per platform, which is more in the spirit of the language
and avoids five config dialects. Assets are binary files and must sit on disk regardless. So
the folders are certainly needed for assets; whether they also carry config, or whether config
is carved in the manifest and *emitted* into the package at build time, is not settled.

For reference, entry point is selected by `--artifact` × platform — not by which template was
used. This is what `Platform.entry_exe` / `entry_app` / `entry_lib` in `targets.md` §4 encode:

| Artifact | Linux / Windows / macOS | Android | iOS |
|---|---|---|---|
| `Executable` | `_start`, argc/argv | `_start` (adb shell) | not a user-facing concept |
| `App_Package` | window + native event loop | `JNI_OnLoad` / NativeActivity | `UIApplicationMain` |
| `Shared_Library` | dylib init | `JNI_OnLoad` | dylib init |

A tree intended for Syntact consumers needs no scaffold beyond a directory and a
`project.syn`, so there is no template for it.

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
resolve manifest
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
go-to-definition, rename, completion, and semantic tokens (README:145). Changes:

- becomes `syntact lsp` — one binary, so editors configure one command and version skew
  between compiler and server becomes impossible;
- gains `textDocument/formatting` and `textDocument/rangeFormatting`, both delegating to
  `sdk/format/` (§10) — currently absent;
- shares `project/` so it resolves library dependencies the same way `build` does, rather
  than guessing;
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

**Manifest in Syntact or not** (§3).

**How are exports declared** — manifest list or a language-level marker (§5).

**Per-platform config: folder or carved in the manifest** (§6).

---

## 13. What blocks what

Facts, not an ordering — the sequencing is yours to choose.

| Item | Cannot happen until |
|---|---|
| subcommand skeleton, `project/`, `clean`, `check`, folding `lsp` in | nothing — pure refactor of existing behaviour |
| `format` | the lexer retains comment text and the glue rules are respected (§10) |
| `run` with hot reload | `targets.md` §10 — reduce cache, resident VM, patch protocol |
| `run` on a device | that device's transport (§7.1), plus a VM binary for its target (§12) |
| `bundle` | exported symbols in the image layer, and `abi.md` |
| multi-target `build`/`bundle` | the combination rules in `targets.md` §6.4 |
| `create cli` | nothing beyond the skeleton — a CLI is what the compiler already emits: argc/argv via `emit_arg_stub` (`emit.odin:161`), exit status via `emit_exit` (`emit.odin:467`) |
| `create gui` | an event loop, plus the GUI/game library existing — which itself needs aggregates and callbacks at the frontier (`targets.md` §11, `abi.md` §6-§7) |
| `doctor` / `devices` | nothing to build for — only deploy-side probes (§7.3) |

The skeleton and `format` touch no backend code at all.
