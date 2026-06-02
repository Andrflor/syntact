# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Keeping this file current

**This file must be updated on the basis of the changes you make.** Whenever a change alters something documented here — what builds, the file/line map of `compiler/`, the builtin names, the constraint/domain semantics, the test harnesses and how to run them, or the language conventions — update the relevant section in the same change. Treat a stale CLAUDE.md as a bug: if you touch the codebase and a statement here becomes wrong, fix it before finishing. When this is the only thing that needed updating, say so.

## Language convention

All code-facing content **must be written in English**: comments, error messages, identifiers, and documentation (this file, `README.md`, etc.). Conversations with the maintainer may happen in another language, but that must never leak into the codebase or its documentation.

## Project overview

Bootstrap compiler for **Syntact**, an experimental language where everything is a scope and execution is structural reduction. The compiler is written in Odin and targets x86-64 Linux. Syntact has no functions, classes, modules, or types as primitives — only scopes manipulated via binding, carving, extension, collapse, patterns, constraints, and (planned) effects/resonance/reactivity. See `README.md` for the full language design and `constraints.md` for the constraint/range system the analyzer implements.

Syntact's central model (from `README.md`):
- A **scope** `{}` is complete structured data; a file is the root scope.
- A function call decomposes into two independent operations: **carving** `scope{name -> v}` (derive a new scope) and **collapse** `scope!` (reduce through the scope's production).
- `:` is not a type annotation — it is **structural coloring**: a constraint propagates implicitly through the binding and everything it contains. Syntact has no type system.

## Current state of the codebase

The compiler is mid-rewrite around a new constraint/`Type` system. Know what builds before you touch it:

- **`odin build compiler`** — builds. This is the live pipeline: `parse → analyze → reduce`.
- **`odin build lsp`** — **does NOT build.** `lsp/lsp.odin` references symbols deleted in the analyzer rewrite (`Sem_Binding_Kind`, `Static_Value`, `is_builtin_name`, `node_position`, …). It targets the old `Semantic`/`Scope_Id` API and is stale.
- **`odin test test/analyzer`** — builds and runs.
- **`odin test test/typecheck`** — builds and runs (constraint-satisfaction cases).
- **`odin test test/reducer`** — builds and runs. Ported to the current API (`reduce(cache.scope)` + `value_to_string`). ~16 cases still fail on reducer features not yet reimplemented (carve materialization, scope `+{}` extension, pattern matching, scope/f64/i32 defaults, `==`) — those are reducer gaps, not harness breakage.
- **`odin test test/parser`** — **does NOT build.** Its harness calls the old API (`node_position`, `reduce(cache.semantic, ast)`, `reduced_to_string`, `cache.semantic`).

Every test harness loads its `tests/*.json` via a path **relative to the current working directory**, so run each suite from inside its own directory: `cd test/analyzer && odin test .` (likewise `test/typecheck`, `test/reducer`). Running `odin test test/analyzer` from the repo root compiles but fails every case with "Failed to read test file".

When asked to "run the tests", default to `test/analyzer` and `test/typecheck` unless told otherwise. Do not assume the parser harness or the LSP compile — verify first.

## Build & run commands

```bash
# Build the compiler (the only consistently-building target)
odin build compiler -out:compiler/compiler

# Run the compiler on a .syn file
./compiler/compiler input.syn
./compiler/compiler input.syn --parse-only    # parse only, no analysis
./compiler/compiler input.syn --analyze-only  # parse + analyze, no reduction
./compiler/compiler input.syn --ast           # print AST
./compiler/compiler input.syn --ir            # print analyzer output (Type tree of root scope)
./compiler/compiler input.syn --print-errors  # show parse/analysis errors
./compiler/compiler input.syn -t              # timing info (parse/analyze/reduce)
./compiler/compiler input.syn -v              # verbose pipeline logging

# Run the analyzer test suite (the suite that currently builds)
odin test test/analyzer

# Run a single analyzer test by name (name is test_<stem>_<index> — find it in generated_tests.odin)
odin test test/analyzer -test-name test_constraint_builtin_array_valid_0
```

### Regenerating test harnesses

Each test category has its own `generator.odin` (marked `+build ignore`) that scans `tests/*.json` and rewrites `generated_tests.odin` (auto-generated — never hand-edit). Run from inside the category directory:

```bash
cd test/analyzer && odin run generator.odin -file && cd -
# same pattern for test/parser and test/reducer
```

## Architecture

Pipeline: **source → parser → analyzer (+ constraint folding) → reduce**. Code generation (`generate.odin`, `backends/`) is WIP / inactive.

### compiler/ package

All stages share one `package compiler`:

- **parser.odin** (~3100 lines) — Lexer + parser. Produces a flat, arena-allocated AST: SOA arrays (`node_kinds`, `node_data`, `node_spans`, `extra`) indexed by `Node_Index` (distinct u32), `INVALID_NODE` sentinel. Single-pass, top-down, covers the full grammar: bindings (`->`/`<-`), productions, carving (`{}`), extension (`+{}`), collapse (`!`), patterns (`?`), constraints (`:`), ranges (`..`), events (`>-`/`-<`), resonance (`>>-`/`-<<`), reactivity (`>>=`/`=<<`), property access (`.`), externals (`@`), operators. Use `node_*` accessors, not raw field access.
- **analyzer.odin** (~1080 lines) — Semantic analysis. Builds a tree of `Scope_Type` (parallel `[dynamic]` arrays: `names`, `types` (constraints), `kind` (`Binding_Kind`), `values`, plus `type_folds`/`constraint_folds`). Everything is modeled as a `Type` union (`Integer_Type`, `Float_Type`, `String_Type`, `Bool_Type`, `Scope_Type`, `Range_Type`, `Sum_Type`/`Product_Type`/`Negate_Type` for `|`/`&`/`~`, `Compose_Type` for arithmetic, `Carve_Type`, `Mention_Type`, `Reference_Type`, `None_Type`, `Unknown_Type`, `Invalid_Type`). `walk()` (around line 432) is the AST→Type recursion; `analyze()` is the entry; `follow()` chases references; `sem_error()` records `Analyzer_Error` with an `Analyzer_Error_Type`. The result lands in `cache.scope` / `cache.analyze_errors`.
- **integer.odin** (~725 lines, formerly `fold_integer.odin`) — Interval arithmetic over `Integer_Interval{lo, hi: Maybe(i64)}` (nil = ±∞), implementing `constraints.md`. Folds compose/range types to `[]Integer_Interval`, does interval add/sub/mul, union/intersect/negate/normalize, and `integer_intervals_satisfy` for the subset check (the constraint-as-contract proof). `builtin_name`/`builtin_alias` map intervals back to `u8`, `i32`, etc.
- **float.odin** (~629 lines) — The float domain, mirror of `integer.odin` over `[]Float_Interval`. Interval arithmetic and subset checks for the float family.
- **string.odin** (~968 lines) — The string/char family, a unified model over `[]String_Interval`.
- **bool.odin** — The boolean domain, a finite set over `{true, false}`. `Bool_Type{value: Maybe(bool), default: bool}`: `value` is the concrete element for a singleton, `nil` for the full `{true,false}`; `default` is the materialized default — the **first source term** of the domain (`true` → true, `false` → false, `(true|false)` → true, `(false|true)` → false, the `bool` builtin → false). `&`/`|`/`~` are **set operations** (intersection/union/complement within `{true,false}`), not runtime logic: `true & false` → `none` (empty set), `(true|false)` → `{true,false}`, `~true` → `{false}`. The empty set folds to `None_Type`. Mirrors the string-family entry points (`fold_type_bool`/`fold_constraint_bool`/`bool_satisfy`).
- **type.odin** (~1049 lines, formerly `fold_type.odin`) — Generic, domain-agnostic fold dispatch: `fold_type` derives the constraint a value *produces* (its envelope), routing to the integer/float/string/bool domains. Higher-level `fold_compose`/`fold_range` (validates range operand kinds and color matching — integer/float/string, no cross-family) plus type-shape checks. `value_to_string` renders a reduced/default value for the reducer tests. Emits `Invalid_operator`/`Invalid_Range` errors when operands can't fold.
- **diagnostics.odin** (~351 lines) — Turns analysis failures into author-facing messages. The fold procedures answer a yes/no question (does this resolve?); this layer explains *why* it didn't.
- **reduce.odin** (~440 lines) — Runtime reduction. `reduce(scope: ^Scope_Type) -> ^Type` collapses a scope through its `.Product` binding; `reduce_value` evaluates `Execute_Type` (collapse), `Compose_Type` (arithmetic), `Carve_Type`, references, etc. Prefers precomputed concrete `type_folds` when available.
- **resolver.odin** (~840 lines) — Compilation orchestrator. Thread pool for parallel files, `Cache` struct per file (`scope`, parse/analyze errors+warnings, `status`). Entry point `resolve_entry()`; the per-file pipeline that wires parse → analyze → (`--ir` print) → reduce → `print_type` is around line 370.
- **main.odin** — CLI; `parse_args()` into the `Options` struct. On-disk caching is force-disabled in the bootstrap (`no_cache = true`).
- **generate.odin**, **backends/x64|wasm|arm64/** — x64/codegen, WIP and not in the active pipeline.

Key conventions:
- **Builtin names are lowercase.** The generic-domain builtins are `int`, `float`, `string`, `bool`, `none` (registered in `init_builtins`), alongside the fixed-width `u8`/`i32`/`f64`/… The open-domain printers (`integer.odin`/`float.odin`/`string.odin`/`bool.odin`) print these same lowercase names, so source, IR, and diagnostics agree. There is no `Int`/`Bool`/`String` — a capitalized name like `Array` or `F32ORString` is always a user-defined scope, never a builtin.
- The constraint system is the heart of the analyzer. A concrete value `5` is the degenerate range `5..5`; `u8` is `0..255`; `true` is the singleton `{true}`. Constraints are **static contracts** — the analyzer must *prove* `value ⊆ constraint` (via `integer_intervals_satisfy`, `bool_satisfy`, …) or it's a `Constraint_Mismatch`. There is no implicit coercion; `&` is the explicit cast/intersection. Read `constraints.md` before changing folding.
- Same-name bindings are valid and tracked by ordinal (`#0`, `#1`, …) — a core feature, not a bug. Access (`.`) resolves the **last** occurrence; carving (`{}`) targets the **first** by default.
- Errors use the `Analyzer_Error_Type` enum and the term **constraint** (`Constraint_Mismatch`, `sem_error`-style naming), never "type"/"typecheck" — Syntact has no types.

### test/ package — four independent harnesses

`test/parser/`, `test/analyzer/`, `test/typecheck/`, `test/reducer/` are separate Odin test packages, each with `tests/*.json`, a `generated_tests.odin`, a `generator.odin`, and a runner. Run each **from inside its own directory** (`cd test/<category> && odin test .`) — the runner reads `tests/*.json` relative to the CWD.

- **parser** — JSON has `expect`, a serialized AST like `Scope[Operator(Add,Literal(Integer,1),Literal(Integer,2))]`. *Harness does not build* (stale API).
- **analyzer** — JSON has `expect_errors: []string` of `Analyzer_Error_Type` names (empty array = must analyze cleanly). The runner parses, analyzes, and compares the error list. *Builds and runs.*
- **typecheck** — same JSON shape as analyzer (`expect_errors`), focused on constraint-satisfaction cases (`(string|u8):b -> "hi"`, `~10:a -> 5`, …). *Builds and runs.*
- **reducer** — JSON has `expect`, the stringified reduced value (e.g. `"25"`). The runner calls `reduce(cache.scope)` then `value_to_string`. *Builds and runs*; some cases still fail on unimplemented reducer features (see "Current state").

Test JSON shape:
```json
{ "name": "...", "description": "...", "source": "u8:a -> 200\n-> a", "expect_errors": [] }
```
Test function names are `test_{stem}_{index}`; find the exact name in the category's `generated_tests.odin`.

### lsp/ package

- **lsp.odin** (~1630 lines) — LSP server (diagnostics, hover, go-to-def, completion) importing the `compiler` package. **Currently broken against the rewritten analyzer** — it must be ported from the old `Semantic`/`Scope_Id` API to the new `Scope_Type`/`Type` model before it builds again.
