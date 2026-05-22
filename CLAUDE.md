# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project overview

Bootstrap compiler for **Syntact**, an experimental programming language where everything is a scope and execution is structural reduction. The compiler is written in Odin and targets x86-64 Linux. The language has no functions, classes, or modules as primitives — only scopes manipulated via binding, carving, extension, collapse, patterns, and effects.

## Build commands

```bash
# Build the compiler
odin build compiler -out:compiler/compiler

# Build the LSP server
odin build lsp -out:lsp/lsp

# Run the compiler on a .syn file
./compiler/compiler input.syn
./compiler/compiler input.syn --parse-only    # parse only, no analysis
./compiler/compiler input.syn --analyze-only  # parse + analyze, no codegen
./compiler/compiler input.syn --ast           # print AST
./compiler/compiler input.syn --print-errors  # show parse/analysis errors
./compiler/compiler input.syn -t              # timing info

# Run the full test suite (1239 JSON-based parser tests)
odin test test

# Run a single test by name
odin test test -test-name test_op_add_0

# Regenerate test harness from JSON test files (run from test/)
odin build test/generator.odin -file -out:test/generator && ./test/generator
```

## Architecture

The compiler pipeline flows: **source → parser → analyzer → reducer → (generate)**.

### compiler/ package

All compiler stages share one `package compiler`:

- **parser.odin** (~3200 lines) — Lexer + parser. Produces a flat arena-allocated AST (`Ast` struct with SOA node arrays). Node types defined via `Node_Kind` enum. Uses `Node_Index` (distinct u32) for references, `INVALID_NODE` as sentinel. The parser is single-pass, top-down, handling the full Syntact grammar: bindings (`->`), productions, carving (`{}`), extension (`+{}`), collapse (`!`), patterns (`?`), constraints (`:`), events (`-<`, `>-`), resonance (`>>-`, `-<<`), reactivity (`>>=`, `=<<`), properties (`.`), ranges (`..`), externals (`@`), and operators.
- **analyzer.odin** (~1650 lines) — Semantic analysis. Builds `Semantic` structure with `Scope_Id`/`Binding_Id` indexed types. Resolves identifiers, validates constraints, checks shapes, detects circular references.
- **reduce.odin** (~770 lines) — Runtime reduction/evaluation. Collapses scopes through their productions, evaluates operators, handles carving overrides. `Reducer` struct maintains an environment stack (`Env_Frame` with overrides). Max recursion depth: `REDUCE_MAX_DEPTH` (1024).
- **resolver.odin** (~820 lines) — Compilation orchestrator. Thread pool for parallel file processing. `Cache` struct per file tracks parse/analysis status. Entry point: `resolve_entry()`.
- **generate.odin** — x64 code generation (largely commented out / WIP).
- **main.odin** — CLI entry point, argument parsing into `Options` struct.
- **backends/x64/** — x64 assembler utilities (ELF headers, instruction encoding).

### test/ package

- **parser.odin** — Test harness. `run_test` loads a JSON test case, parses the source, serializes the AST via `ast_to_string`, and compares with `expect`. Provides source-level diff on failure with position mapping back to AST nodes.
- **generator.odin** — Reads JSON files from `test/tests/` and generates `parser_generated_tests.odin` (auto-generated, do not edit).
- **tests/** — 1239 JSON test cases, each with `name`, `description`, `source`, `expect` fields. The `expect` field uses a serialized AST format like `Scope[Pointing(Identifier(n),Literal(Integer,0))]`.

### lsp/ package

- **lsp.odin** — Language Server Protocol implementation. Provides diagnostics, hover, go-to-definition, completion. Imports `compiler` package directly for parsing and analysis.

## Test format

Test JSON files follow this structure:
```json
{
  "name": "Operator Add",
  "description": "Binary addition",
  "source": "1 + 2",
  "expect": "Scope[Operator(Add,Literal(Integer,1),Literal(Integer,2))]"
}
```

Test names become Odin test function names via `test_{stem}_{index}`. To run a specific test: `odin test test -test-name test_op_add_42` (find the exact name in `parser_generated_tests.odin`).

## Key Syntact language concepts for the compiler

- **Scope**: fundamental unit — `{}` creates one, a file is the root scope
- **Binding**: `name -> value` (push), `name <- value` (pull)
- **Production**: `-> expr` (anonymous binding, what a scope yields on collapse)
- **Carving**: `scope{name -> value}` derives a new scope
- **Extension**: `scope +{...}` adds new structure
- **Collapse**: `scope!` reduces through production
- **Pattern**: `expr ? { branches }` structural matching
- **Constraint/Shape**: `Shape:name` constrains a binding
- **Events**: `>-` emit, `-<` handle (nominal effects)
- **Property access**: `scope.name` resolves last visible occurrence
- **External/Import**: `@path` filesystem scope resolution
- **Resonance**: `>>-` / `-<<` (explicit state via events)
- **Reactivity**: `>>=` / `=<<` (derived bindings)

## Important conventions

- The AST is flat and arena-allocated — nodes are accessed by `Node_Index`, not pointers. Use `node_*` accessor procs (e.g., `node_kind`, `node_left`, `node_right`, `node_children`).
- Same-name bindings are valid and tracked by ordinal (`#0`, `#1`, etc.) — this is a core language feature, not a bug.
- Access (`.`) resolves the **last** occurrence; carving targets the **first** by default.
- Code generation is largely WIP. The active pipeline is parse → analyze → reduce.
