# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## ⚠️ GIT IS THE MAINTAINER'S — NEVER TOUCH IT

**The maintainer manages ALL git operations.** Do NOT run `git stash`, `git checkout`, `git reset`, `git commit`, `git merge`, `git pop`, `git rebase`, `git add`, or anything that mutates the working tree or git state — not even to "check before/after" a change, and not even to read `.git`. `git stash` in particular has corrupted the working tree here. When unsure whether a change is good, do NOT verify via git or by diffing states — just make the edit and write a report; the maintainer decides if it's correct.

## Running tests: YOU run them and report; the MAINTAINER validates

It is YOUR job to run the relevant suite after a change and paste back the raw results (pass/fail counts, failing case names and messages). Do NOT pre-run a baseline before a change just to diff before/after, and do NOT silently judge a result as "fine" — surface it and let the maintainer validate.

## Keeping this file current

Update this file with the changes you make. If a change makes a statement here wrong — what builds, the file map of `compiler/`, the builtin names, the constraint/domain semantics, the test harnesses, or the conventions — fix it in the same change. A stale CLAUDE.md is a bug. Keep it concise: describe the current state, not the history of fixes.

## Language convention

All code-facing content (comments, error messages, identifiers, docs including this file and `README.md`) **must be in English**. Conversations with the maintainer may be in another language; that must never leak into the codebase.

## Working on the backend

When optimizing codegen, **use LLVM as the reference implementation and adapt it to Syntact's case** — we copy LLVM's proven algorithms (InstCombine/Reassociate for affine canonicalization, X86ISelDAGToDAG for instruction selection, linear-scan + Briggs coalescing for allocation) and specialize them. Syntact's key advantage over LLVM: **the reducer knows every value's range by construction**, so there is *never* an overflow proof to do — the width is known up front (a result that fits i16 *is* i16). Read the LLVM source for the pattern, then implement the Syntact-specific version.

## Project overview

Bootstrap compiler for **Syntact**, an experimental language where everything is a scope and execution is structural reduction. Written in Odin, targets x86-64 Linux. Syntact has no functions, classes, modules, or types as primitives — only scopes manipulated via binding, carving, extension, collapse, patterns, constraints, and (planned) effects/resonance/reactivity. See `README.md` for the language design and `constraints.md` / `effects.md` for the constraint/range and effect systems.

Central model:
- A **scope** `{}` is complete structured data; a file is the root scope.
- A function call decomposes into **carving** `scope{name -> v}` (derive a new scope) and **collapse** `scope!` (reduce through the scope's production). Functions are inlined/unfolded at compile time, not a runtime abstraction.
- `:` is **structural coloring**, not a type annotation: a constraint propagates implicitly. Syntact has no type system.

Source files use the `.syn` extension. (The external-import resolver in `resolve.odin` currently looks for `.st` — a known inconsistency in the bootstrap; the canonical extension is `.syn`.)

## Build & run

```bash
odin build compiler -out:compiler/compiler   # the full pipeline
odin build lsp                                # the LSP server (package lsp/)

./compiler/compiler input.syn                 # reduce and print the value
./compiler/compiler input.syn --ast           # print the AST
./compiler/compiler input.syn --ir            # print the analyzer Type tree
./compiler/compiler input.syn --bc            # print the lowered bytecode
./compiler/compiler input.syn --regalloc      # bytecode annotated with register allocation
./compiler/compiler input.syn --run 7 3       # interpret; trailing args feed ??0, ??1, …
./compiler/compiler input.syn -o prog 7       # emit a native x86-64 ELF, then run: ./prog 7
./compiler/compiler input.syn --print-errors  # show parse/analysis errors
./compiler/compiler input.syn -t / -v         # timing / verbose
```

`-o FILE` implies `--emit` (gcc-style); without it, the trailing positional args feed the `??N` runtime slots for `--run`. On-disk caching is force-disabled in the bootstrap.

### Tests

```bash
odin test test -all-packages                   # EVERYTHING at once (all seven suites)
odin test test/typecheck                       # a single suite
odin test test/codegen                         # end-to-end: interpreter oracle vs native x64
```

`odin test test -all-packages` is the one-shot runner: `test/all_tests.odin` (package `all_test`) blank-imports every suite, and `-all-packages` runs each one's `@(test)` procs. It also picks up the x64 instruction-encoding tests (`package x64_assembler`, imported transitively by `compiler`); those need GNU `as` and are run separately with `odin test compiler/backends/x64` — treat the seven JSON suites as the canonical target.

When a suite case fails, the message embeds the case name AND its `.syn` source (`Source:\n…`) plus expected/actual, so you don't need to reopen the JSON to see what ran. Odin also prints a `-define:ODIN_TEST_NAMES=…` line listing the failures, ready to paste back to rerun only those.

When asked to "run the tests", default to `test/analyze` and `test/typecheck` (plus `test/codegen` for backend work), or `odin test test -all-packages` for a full sweep.

**Regenerating a test harness** (after editing its `tests/*.json`): each suite has a `+build ignore` `generator.odin` that rewrites the auto-generated `generated_tests.odin` by scanning `tests/*.json`. Run it from inside the category dir:

```bash
cd test/analyze && odin run generator.odin -file && cd -
```

Test function names are `test_{json-stem}_{index}` — find the exact name in that suite's `generated_tests.odin`.

## Architecture

Pipeline: **source → parse → analyze (constraint folding) → reduce → bytecode → backend**. A program compiles to a runnable static x86-64 ELF. Two backends consume the neutral bytecode: a reference **interpreter** (`--run`, the oracle every other backend is validated against) and the **x64 ELF emitter** (`-o`). The interpreter handles every domain (int/float/string/bool); the x64 emitter does int/bool via exit-status, floats via XMM + decimal print, concrete strings via `write(1,…)`.

### Three codegen packages

Backend-specific code lives in `backends/<arch>/`, never at the `compiler/` root, so the neutral bytecode can be shared by future backends (`backends/arm64`, `backends/wasm` are stubs) with no import cycle.

- **`compiler/bytecode/`** (`package bytecode`, depends on NOTHING in the compiler):
  - `bytecode.odin` — the **target-neutral bytecode**: SSA-like virtual registers (`BC_Value` = vN), its own operator enum `BC_Op`, the `Machine_Type` lattice (U8…I64/F32/F64/Str) + `mtype_*` helpers (incl. `mtype_for_range` — smallest type containing a `[lo,hi]`), the instructions, `BC_Program`, and the `--bc` dump. **Immediate operands are distinct mnemonics** (`BC_Bin_Imm` = `a op #imm`, like `add r,imm` vs `add r,r`) — a literal is an immediate on the instruction, never a separate value.
  - `interp.odin` — the **reference interpreter** (the oracle): executes a `BC_Program` over tagged i64/f64/string; `interp_bytecode(prog, args)` feeds ??N from argv strings parsed per domain.
- **`compiler/bytecode.odin`** (at the root, `package compiler`) — the **LOWERING** `^Type → bytecode.BC_Program`, the one part that knows both worlds. `lower_to_bytecode(reduce(scope))` memoizes by DAG node address (CSE survives). `machine_type_of` derives each value's `Machine_Type` from the reducer's range. `op_to_bc` maps `Operator_Kind`→`BC_Op`. A typed ??'s domain normalization lives in `BC_Load_Arg` (its width/signed), realized by each backend (x64 movzx/movsx) — no separate mask instruction. A symbolic string / unsized domain is rejected with `prog.error`.
- **`compiler/backends/x64/`** (`package x64_assembler`, imports `bytecode`):
  - `x64_instructions/header/utility/test.odin` — the assembler (one proc per instruction, REX/ModRM/SIB, encodings validated against objdump). `x64_sse_scalar.odin` / `x64_movzx_mem.odin` add SSE scalar ops, `cqo`, `shl/sar r64,cl`, and memory `movzx/movsx`.
  - `isel.odin` — **instruction selection (LLVM X86ISelDAGToDAG-style).** `X64_Address{base,index,scale,disp}`; `match_addr_rec` folds an add/sub/`*{2,4,8,3,5,9}`/shift tree into one `lea`. `lea_is_profitable` is the cost rule.
  - `emit.odin` — the **emitter**: `bytecode.BC_Program` → `.text` + `.rodata`. Linear-scan allocation, **strength reduction + immediate folding** (`*2^k`→shl, unsigned `/2^k`→shr, `%2^k`→and, etc.), **Granlund-Montgomery multiply-high** for unsigned div/mod by a constant (signed still `idiv`), **width-correct 32-bit arithmetic** (`val_is_32bit` → 32-bit registers, no overflow proof needed). A runtime arg stub parses `argv[1..]` into the `ARGS_TABLE`; float `??` slots get a second `emit_atof` pass.
  - `regalloc.odin`/`regalloc_dump.odin` — liveness + **linear-scan with move-biased coalescing** (Briggs). 10 allocatable GPRs (RAX/RDX = idiv scratch, RCX = shift count, RSP/RBP = frame, RBX = ARGS_TABLE base). `--regalloc` dumps it.
  - `elf.odin` — the **ELF64 writer**: static ET_EXEC, one RWX PT_LOAD, minimal section table so the binary is `objdump -d`/gdb-inspectable.
  - `vectorize.odin` — auto-vectorization analysis, **no SIMD emitted yet** (documented stub): Syntact folds all concrete computation, so the bytecode carries only scalar ops on individual `??`.

`resolve.odin` wires `lower_to_bytecode` → `bytecode.bytecode_to_string`/`interp_bytecode` (`--bc`/`--run`) and `x64.allocate_registers`/`x64.emit_executable` (`--regalloc`/`-o`).

### compiler/ package

All non-codegen stages share `package compiler`:

- **ast.odin** — the AST data model only: `Node_Kind`/`Literal_Kind`/`Operator_Kind`, the `*_Data` payloads + `Node_Data` union, the flat SOA `Ast` container (indexed by `Node_Index`), `Span`/`Position`, the `node_*` accessors + `print_ast`. Read nodes through `node_*`, never the raw union.
- **parse.odin** — lexer + parser machinery. Table-driven lexer, single-pass Pratt parser covering the full grammar (bindings `->`/`<-`, productions, carving `{}`, extension `+{}`, collapse `!`, patterns `?`, constraints `:`, raw casts `::`, ranges `..`, events/resonance/reactivity, property `.`, externals `@`). **Unary precedence is operator-specific**: arithmetic `-` binds tighter than range/shift (`-5..5` is `(-5)..5`); set operators `~`/`!` stay looser (`~'a'..'z'` is `~('a'..'z')`). **Bit-level operators** `^`/`<<`/`>>` are direct; `[&]`/`[|]`/`[~]` are bracketed to stay distinct from the set-algebra `&`/`|`/`~`. **Equality is a single `=`** — `==` is NOT an operator (lexer flags `Bad_Double_Equal`, parser recovers as one `=`). The `.` token's kind is delimiter-sensitive (`lex_dot`): a left delimiter before it → source-none property (self-mention into the carved scope).
- **ir.odin** — the IR data model + printing: the `Type` union (`Integer_Type`/`Float_Type`/`String_Type`/`Bool_Type`/`Scope_Type`/`Range_Type`/`Or_Type`/`And_Type`/`Negate_Type`/`Compose_Type`/`Cast_Type`/`Pattern_Type`/`Carve_Type`/`Mention_Type`/`Reference_Type`/`None_Type`/`Unknown_Type`/`Invalid_Type`), interval payloads, renderers (`print_type` for `--ir`, `value_to_string`/`write_value`, `type_to_string` for errors). There is no `=v` node: `=v` is desugared at walk into the producer scope `{-> v}` (see pattern.odin).
- **analyze.odin** — semantic analysis. Builds a tree of `Scope_Type` (parallel arrays: `names`/`types`/`kind`/`values` + `type_folds`/`constraint_folds`). `walk()` dispatches on `Node_Kind` to per-kind `walk_<kind>` handlers. `sem_error`/`sem_warning` carry the node's `Span` + resolved position (the LSP reads the range directly). Carve specifics: `walk_property` resolves source-none properties against the carved scope; `recheck_carve` re-proves colored bindings after substitution. A carve child `z{…}` whose source names a DIRECT field of the scope being carved is sugar for `z->.z{…}` (`carve_shorthand_field`).
- **type.odin** — domain-agnostic fold dispatch: `fold_type`, `fold_constraint`/`fold_value_type`/`satisfy`/`type_default`. `fold_cast` is the `::` raw reinterpret-cast (forces bits, never a proof). `fold_carve` materializes a carve (clone + `repoint` references).
- **constraint.odin** — carve/constraint folding helpers (`fold_carve_constraint`, `carve_substitute`). *(Note: this file is the main work-in-progress area; expect it to be the one most often mid-edit.)*
- **unify.odin** — structural unification / refinement support.
- **integer.odin / float.odin / string.odin / bool.odin** — the four domains. Each does interval arithmetic and the subset (constraint-satisfaction) check over its interval kind. `int_layout` maps a canonical interval to `{bits, signed}`; the raw-cast bit layer (`Bit_Repr`/`resize_bits`) lives in integer.odin. String is a `[]String_Interval` union with ordered `+` sequences, codepoint negation, three-bound ranges. Bool is the finite set `{true,false}`. **Default value is PROPAGATED, not recomputed**: each integer/bool leaf carries its `default_value`, threaded through `&`/`|` along SOURCE order (signed builtins `i8/i16/i32/i64/int` carry an EXPLICIT `0` default). Float/string still recompute structurally.
- **pattern.odin** — `target ? { match -> product, … }`. Two branch modes: typecheck `M -> p` (fires when `target ⊆ M`) and value `=v -> p`. **`=v` is PURE SUGAR for the producer scope `{-> v}`, everywhere** — `walk_operator` desugars a unary `=` into a freshly-built `{-> v}` scope (exactly as a source `{-> v}` would walk, folds via the normal machinery so the inner value re-reifies; NOT `make_producer_scope`, which pre-bakes folds one level too shallow). So `a ? {b->}` is `satisfy(a, b)` and `a ? {=b->}` is `satisfy(a, {-> b})` — the ONE rule. There is NO pattern-direct mode and no per-branch flag: `=` composes naturally (`=10 | =20` is `Or({-> 10}, {-> 20})`) and is NOT transparent outside a branch (`a -> =10` is the producer `{-> 10}`, `={x->0}` is `{-> {x->0}}`). The same sugar applies in constraints: `=u8:b` colors b with `{-> u8}`, so `b` must be *statically* the value `u8`, not merely of u8's shape (`=u8:b -> 5` is a `Constraint_Mismatch`; `u8:b -> 5` is fine). `reduce_branch_fires` reads through the `{-> v}` producer to the leaf. Exhaustiveness = the Or of branch covers typechecks the target, else `Non_Exhaustive_Pattern`. A pattern branch is the constraint dual: `a ? {b -> …}` is `b:x -> a` — so `u8 ? {u8 -> …}` is NON-exhaustive (the *type* `u8` is not a value of `u8`, just like `u8:x -> u8` fails), while `u8 ? {=u8 -> …}` IS exhaustive (`{-> u8}:x -> u8` proves, the scrutinee type satisfies the producer). Don't confuse the scrutinee TYPE with a value of that type.
- **reduce.odin** — **symbolic fixed-point reduction (DAG + CSE + affine canonicalization).** `reduce(scope)` collapses through `.Product`; each `??` is a free variable carried, not evaluated. **Affine canonicalization** (`collect_sum`/`flatten_sum`/`rebuild_sum`): distribute `const*(affine)` and collect like terms (`3*(2a-1)+5a` → `11a-3`). **Common-factor extraction** (`factor_common`, transposed from LLVM Reassociate): `a*b + a*c` → `a*(b+c)`, gated by `op_cost` so it commits only when ops strictly drop. Fixed points render as `??N` (`fixedpoint_id`, stable index). GOTCHAS: the DAG bookkeeping is `@(thread_local)` (the test runner reduces on multiple threads) and reset each `reduce()`.
- **resolve.odin** — compilation orchestrator: thread pool for parallel files, a `Cache` per file, `resolve_entry()` the entry; wires parse → analyze → reduce → bytecode → backend.
- **main.odin** — CLI; `parse_args()` into `Options`.
- **diagnostics.odin** — turns analysis failures into author-facing messages (the folds answer yes/no; this explains why).
- **terminate.odin** — termination / recursion-bound checking.
- **generate.odin** — legacy direct codegen path (superseded by the bytecode pipeline).

Key conventions:
- **Builtin names are lowercase**: `int`/`float`/`string`/`char`/`bool`/`none` + fixed-width `u8`/`i32`/`f64`/…. A capitalized name (`Array`, `Circle`) is always a user scope, never a builtin. `char` is the single-codepoint string set (ordinal) — NOT an int alias: `char:a -> 'A'` holds but `char:a -> 65` is a Constraint_Mismatch.
- The constraint system is the analyzer's heart: `5` is `5..5`, `u8` is `0..255`, `true` is `{true}`. Constraints are **static contracts** — the analyzer proves `value ⊆ constraint` or it's a `Constraint_Mismatch`. No implicit coercion; `&` narrows (still proves the subset), `::` reinterprets bits (no proof). Read `constraints.md` before changing folding.
- A constraint must denote a **statically-known set**. A `??` on the constraint side → `Insoluble_Constraint`; on the value side it's fine (`u8:a -> ??::u8`).
- Same-name bindings are valid, tracked by ordinal (`#0`,`#1`,…): access `.` resolves the **last**, carving `{}` targets the **first**.
- **Capture** `name(e)` / `(e)`: a SECOND, INVISIBLE alias of a binding (the `Scope_Type.captures` column). `.`/carve scan `names` only, so a capture is invisible to them; only the mention path sees it.
- **Division by zero is domain-split.** Integer `/`,`%` lower to `idiv` (traps on 0 → SIGFPE), so the fold requires the DIVISOR statically bounded to exclude 0. Float `/` follows IEEE 754 (never traps), so `float.odin` never rejects.
- Errors use `Analyzer_Error_Type` and the word **constraint**, never "type" — Syntact has no types.
- **Constants carry no type** — they fold into immediates at the backend; never promoted "for speed" (would break layout/wrap). The **reducer** canonicalizes affine arithmetic, NOT the bytecode pass — fix the right level (reducer = algebra, backend = machine).
- **No ABI.** Functions unfold at compile time, so a program is one `_start` that exits by syscall — no call/ret, no caller/callee-saved distinction, all registers free scratch. Don't add an ABI pre-emptively.

### test/ package — seven harnesses

`test/{parse,analyze,typecheck,reduce,default,codegen,pattern}/` are independent Odin test packages, each with `tests/*.json` + a generated runner. `odin test test/<cat>` runs from anywhere (a `test_path` helper resolves JSON against the source dir). `test/all_tests.odin` is the aggregator package that blank-imports all seven so `odin test test -all-packages` runs them in one command. Every suite's failure message includes the failing case's `.syn` source.

- **codegen** — the **end-to-end** suite (multi-combo: each case runs many `(args → expect)` pairs). Each case is checked against BOTH backends: the interpreter (oracle) AND native x64 (emit ELF → run via libc `popen` → compare exit-status/stdout). An interp/native divergence fails the case.
- **typecheck** — constraint-satisfaction (`expect_errors`): self-match, raw-cast `::`, composites, carve implicit-constraints, executes, set ops, patterns, string sequences/negation/tri-range, self-property carve refs, negative-bound ranges, proof-by-default.
- **analyze** — `expect_errors` of `Analyzer_Error_Type` names (empty = clean).
- **reduce** — `expect` = the stringified reduced value (concrete `"25"` or symbolic `"11 * ??0 + 3 * ??1 - 4"`). Some cases fail on reducer/parser features not yet reimplemented — gaps, not breakage.
- **default** — `binding` + `expect` (the materialized default across domains/composites).
- **parse** — `expect` = a serialized AST. Some error-recovery cases fail.
- **pattern** — pattern matching + the `=v` → `{-> v}` sugar. Each case carries `expect_errors` (exhaustiveness/typecheck) and optionally `expect` (a reduced value): value-match `=v`, nested `=10 | =20`, `=` as a producer outside a branch (no transparency), value-vs-shape (`=u8` ≠ `u8`), `=` in constraints, type-not-value exhaustiveness (`u8?{u8}` non-exhaustive vs `u8?{=u8}` exhaustive), mixed typecheck/value branches, default-only.

### lsp/ package

- **lsp.odin** — LSP server (JSON-RPC): diagnostics (parse+analyze errors with precise ranges from each error's `span`), hover, go-to-definition, find-references, rename, completion, semantic tokens. Imports `compiler`.
- **semantic.odin** — the LSP's semantic layer. The analyzer keeps no node→Type map, so names resolve **lexically over the AST** (`build_parent_map`, `resolve_definition` honoring `#n` ordinals, `all_references`). Completion/hover use the analyzed `Scope_Type` via `scope_type_at`.
