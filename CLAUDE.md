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
- **`test/analyze`** — builds and runs (`cd test/analyze && odin test .`).
- **`test/typecheck`** — builds and runs (constraint-satisfaction cases).
- **`test/reduce`** — builds and runs. Ported to the current API (`reduce(cache.scope)` + `value_to_string`). ~16 cases still fail on reducer features not yet reimplemented (carve materialization, scope `+{}` extension, pattern matching, scope/f64/i32 defaults, `==`) — those are reducer gaps, not harness breakage.
- **`test/parse`** — builds and runs (1239 cases; ~10 fail on error-recovery / ambiguous-pattern cases).

The test directories and the compiler files were renamed off the agent-noun convention: `parser`→`parse`, `analyzer`→`analyze`, `resolver`→`resolve`, `reducer`→`reduce` (the entry procs `parse`/`analyze`/`reduce` were already named that way). The compiler-internal `resolver` global, the `Resolver` type, and `resolve_entry()` keep their names.

Every test harness loads its `tests/*.json` via a path **relative to the current working directory**, so run each suite from inside its own directory: `cd test/analyze && odin test .` (likewise `test/typecheck`, `test/reduce`, `test/parse`). Running `odin test test/analyze` from the repo root compiles but fails every case with "Failed to read test file".

When asked to "run the tests", default to `test/analyze` and `test/typecheck` unless told otherwise. Verify the LSP compile before assuming it — it is stale.

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

# Run the analyzer test suite (run from inside the directory — see "Current state")
cd test/analyze && odin test . && cd -

# Run a single analyzer test by name (name is test_<stem>_<index> — find it in generated_tests.odin)
cd test/analyze && odin test . -test-name test_constraint_builtin_array_valid_0 && cd -
```

### Regenerating test harnesses

Each test category has its own `generator.odin` (marked `+build ignore`) that scans `tests/*.json` and rewrites `generated_tests.odin` (auto-generated — never hand-edit). Run from inside the category directory:

```bash
cd test/analyze && odin run generator.odin -file && cd -
# same pattern for test/parse, test/typecheck and test/reduce
```

## Architecture

Pipeline: **source → parser → analyzer (+ constraint folding) → reduce**. Code generation (`generate.odin`, `backends/`) is WIP / inactive.

### compiler/ package

All stages share one `package compiler`:

- **ast.odin** (~610 lines) — The AST **data model only**, split out of `parse.odin`: the `Node_Kind`/`Literal_Kind`/`Operator_Kind` tags, the `*_Data` payloads and the `Node_Data` raw union, the flat SOA `Ast` container (`node_kinds`/`node_data`/`node_spans`/`extra` indexed by `Node_Index`, `INVALID_NODE` sentinel), `Span`/`Position` + span→position mapping, and the `node_*` accessors + `print_ast`/`ast_root`. No lexer/parser logic. Read a node through the `node_*` accessors, never the raw union.
- **parse.odin** (~2830 lines, formerly `parser.odin`) — Lexer + parser **machinery only** (the AST it builds lives in `ast.odin`). Table-driven lexer (one handler per leading byte), single-pass top-down Pratt parser, covers the full grammar: bindings (`->`/`<-`), productions, carving (`{}`), extension (`+{}`), collapse (`!`), patterns (`?`), constraints (`:`), ranges (`..`), events (`>-`/`-<`), resonance (`>>-`/`-<<`), reactivity (`>>=`/`=<<`), property access (`.`), externals (`@`), operators. Entry point `parse(cache, source)`.
- **ir.odin** (~720 lines) — The IR **data model + its printing**, split out of `analyze.odin` (data) and `type.odin` (printing), mirroring how `ast.odin` carries both the AST structs and `print_ast`. Holds the `Type` union and every variant (`Integer_Type`, `Float_Type`, `String_Type`, `Bool_Type`, `Scope_Type`, `Range_Type`, `Or_Type`/`And_Type`/`Negate_Type` for `|`/`&`/`~`, `Compose_Type` for arithmetic, `Carve_Type`, `Mention_Type`, `Reference_Type`, `None_Type`, `Unknown_Type`, `Invalid_Type`), the domain interval payloads (`Integer_Interval`/`Float_Interval`/`String_Interval`, `FloatKind`), `Binding_Kind`, plus the renderers: `print_type` (the `--ir` tree dump), `value_to_string`/`write_value` (concrete reduced/default value, used by the reducer tests), `type_to_string` (folded type for error messages), and `op_symbol`/`print_*_interval`. Per-domain rendering still lives in each domain file (`integer_to_string`, `bool_to_string`, …); this file composes them.
- **analyze.odin** (~955 lines, formerly `analyzer.odin`) — Semantic analysis **logic** (the IR types it builds live in `ir.odin`). Builds a tree of `Scope_Type` (parallel `[dynamic]` arrays: `names`, `types` (constraints), `kind` (`Binding_Kind`), `values`, plus `type_folds`/`constraint_folds`). `walk()` is the AST→`Type` recursion; `analyze()` is the entry; `follow()` chases references; `sem_error()` records an `Analyzer_Error` (the `Analyzer_Error`/`Analyzer_Error_Type` diagnostics stay here, with the analyzer state). The result lands in `cache.scope` / `cache.analyze_errors`.
- **integer.odin** (~725 lines, formerly `fold_integer.odin`) — Interval arithmetic over `Integer_Interval{lo, hi: Maybe(i64)}` (nil = ±∞), implementing `constraints.md`. Folds compose/range types to `[]Integer_Interval`, does interval add/sub/mul, union/intersect/negate/normalize, and `integer_intervals_satisfy` for the subset check (the constraint-as-contract proof). `builtin_name`/`builtin_alias` map intervals back to `u8`, `i32`, etc.
- **float.odin** (~629 lines) — The float domain, mirror of `integer.odin` over `[]Float_Interval`. Interval arithmetic and subset checks for the float family.
- **string.odin** (~968 lines) — The string/char family, a unified model over `[]String_Interval`.
- **bool.odin** — The boolean domain, a finite set over `{true, false}`. `Bool_Type{value: Maybe(bool), default: bool}`: `value` is the concrete element for a singleton, `nil` for the full `{true,false}`; `default` is the materialized default — the **first source term** of the domain (`true` → true, `false` → false, `(true|false)` → true, `(false|true)` → false, the `bool` builtin → false). `&`/`|`/`~` are **set operations** (intersection/union/complement within `{true,false}`), not runtime logic: `true & false` → `none` (empty set), `(true|false)` → `{true,false}`, `~true` → `{false}`. The empty set folds to `None_Type`. Mirrors the string-family entry points (`fold_type_bool`/`fold_constraint_bool`/`bool_satisfy`).
- **type.odin** (~590 lines, formerly `fold_type.odin`) — Generic, domain-agnostic fold dispatch **only** (the `Type` rendering moved to `ir.odin`): `fold_type` derives the constraint a value *produces* (its envelope), routing to the integer/float/string/bool domains; `fold_constraint`/`fold_value_type`/`satisfy`/`type_default`/`default_value` resolve and check constraints. Higher-level `fold_compose`/`fold_range` (validates range operand kinds and color matching — integer/float/string, no cross-family) plus type-shape checks. Emits `Invalid_operator`/`Invalid_Range` errors when operands can't fold.
- **diagnostics.odin** (~351 lines) — Turns analysis failures into author-facing messages. The fold procedures answer a yes/no question (does this resolve?); this layer explains *why* it didn't.
- **reduce.odin** (~440 lines) — Runtime reduction. `reduce(scope: ^Scope_Type) -> ^Type` collapses a scope through its `.Product` binding; `reduce_value` evaluates `Execute_Type` (collapse), `Compose_Type` (arithmetic), `Carve_Type`, references, etc. Prefers precomputed concrete `type_folds` when available.
- **resolve.odin** (~840 lines, formerly `resolver.odin`) — Compilation orchestrator. Thread pool for parallel files, `Cache` struct per file (`scope`, parse/analyze errors+warnings, `status`). Entry point `resolve_entry()`; the per-file pipeline that wires parse → analyze → (`--ir` print) → reduce → `print_type` is around line 370.
- **main.odin** — CLI; `parse_args()` into the `Options` struct. On-disk caching is force-disabled in the bootstrap (`no_cache = true`).
- **generate.odin**, **backends/x64|wasm|arm64/** — x64/codegen, WIP and not in the active pipeline.

Key conventions:
- **Builtin names are lowercase.** The generic-domain builtins are `int`, `float`, `string`, `bool`, `none` (registered in `init_builtins`), alongside the fixed-width `u8`/`i32`/`f64`/… The open-domain printers (`integer.odin`/`float.odin`/`string.odin`/`bool.odin`) print these same lowercase names, so source, IR, and diagnostics agree. There is no `Int`/`Bool`/`String` — a capitalized name like `Array` or `F32ORString` is always a user-defined scope, never a builtin.
- The constraint system is the heart of the analyzer. A concrete value `5` is the degenerate range `5..5`; `u8` is `0..255`; `true` is the singleton `{true}`. Constraints are **static contracts** — the analyzer must *prove* `value ⊆ constraint` (via `integer_intervals_satisfy`, `bool_satisfy`, …) or it's a `Constraint_Mismatch`. There is no implicit coercion; `&` is the explicit cast/intersection. Read `constraints.md` before changing folding.
- Same-name bindings are valid and tracked by ordinal (`#0`, `#1`, …) — a core feature, not a bug. Access (`.`) resolves the **last** occurrence; carving (`{}`) targets the **first** by default.
- Errors use the `Analyzer_Error_Type` enum and the term **constraint** (`Constraint_Mismatch`, `sem_error`-style naming), never "type"/"typecheck" — Syntact has no types.

### test/ package — four independent harnesses

`test/parse/`, `test/analyze/`, `test/typecheck/`, `test/reduce/` are separate Odin test packages (packages `parse_test`/`analyze_test`/`typecheck_test`/`reduce_test`), each with `tests/*.json`, a `generated_tests.odin`, a `generator.odin`, and a runner. Run each **from inside its own directory** (`cd test/<category> && odin test .`) — the runner reads `tests/*.json` relative to the CWD.

- **parse** — JSON has `expect`, a serialized AST like `Scope[Operator(Add,Literal(Integer,1),Literal(Integer,2))]`. *Builds and runs* (1239 cases; ~10 fail on error-recovery / ambiguous-pattern cases).
- **analyze** — JSON has `expect_errors: []string` of `Analyzer_Error_Type` names (empty array = must analyze cleanly). The runner parses, analyzes, and compares the error list. *Builds and runs.*
- **typecheck** — same JSON shape as analyze (`expect_errors`), focused on constraint-satisfaction cases (`(string|u8):b -> "hi"`, `~10:a -> 5`, …). *Builds and runs.*
- **reduce** — JSON has `expect`, the stringified reduced value (e.g. `"25"`). The runner calls `reduce(cache.scope)` then `value_to_string`. *Builds and runs*; some cases still fail on unimplemented reducer features (see "Current state").

Test JSON shape:
```json
{ "name": "...", "description": "...", "source": "u8:a -> 200\n-> a", "expect_errors": [] }
```
Test function names are `test_{stem}_{index}`; find the exact name in the category's `generated_tests.odin`.

### lsp/ package

- **lsp.odin** (~1630 lines) — LSP server (diagnostics, hover, go-to-def, completion) importing the `compiler` package. **Currently broken against the rewritten analyzer** — it must be ported from the old `Semantic`/`Scope_Id` API to the new `Scope_Type`/`Type` model before it builds again.
