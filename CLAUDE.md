# CLAUDE.md

Guidance for Claude Code when working in this repository.

## Keeping this file current

**Update this file with the changes you make.** If a change makes a statement here wrong — what builds, the file map of `compiler/`, the builtin names, the constraint/domain semantics, the test harnesses, or the conventions — fix it in the same change. A stale CLAUDE.md is a bug. Keep it **concise**: describe the current state, not the history of fixes.

## Language convention

All code-facing content (comments, error messages, identifiers, docs including this file and `README.md`) **must be in English**. Conversations with the maintainer may be in another language; that must never leak into the codebase.

## Working on the backend

When optimizing codegen, **use LLVM as the reference implementation and adapt it to Syntact's case** — we copy LLVM's proven algorithms (InstCombine/Reassociate for affine canonicalization, X86ISelDAGToDAG for instruction selection, linear-scan + Briggs coalescing for allocation) and specialize them. Syntact's key advantage over LLVM: **the reducer knows every value's range by construction**, so there is *never* an overflow proof to do — the width is known up front (a result that fits i16 *is* i16). Read the LLVM source for the pattern, then implement the Syntact-specific version.

## Project overview

Bootstrap compiler for **Syntact**, an experimental language where everything is a scope and execution is structural reduction. Written in Odin, targets x86-64 Linux. Syntact has no functions, classes, modules, or types as primitives — only scopes manipulated via binding, carving, extension, collapse, patterns, constraints, and (planned) effects/resonance/reactivity. See `README.md` for the language design and `constraints.md` for the constraint/range system.

Central model:
- A **scope** `{}` is complete structured data; a file is the root scope.
- A function call decomposes into **carving** `scope{name -> v}` (derive a new scope) and **collapse** `scope!` (reduce through the scope's production). Functions are inlined/unfolded at compile time, not a runtime abstraction.
- `:` is **structural coloring**, not a type annotation: a constraint propagates implicitly. Syntact has no type system.

## Build & run

```bash
odin build compiler -out:compiler/compiler   # the full pipeline
odin build lsp                                # the LSP server

./compiler/compiler input.syn                 # reduce and print the value
./compiler/compiler input.syn --ast           # print the AST
./compiler/compiler input.syn --ir            # print the analyzer Type tree
./compiler/compiler input.syn --bc            # print the lowered bytecode
./compiler/compiler input.syn --regalloc      # bytecode annotated with register allocation
./compiler/compiler input.syn --run 7 3       # interpret; trailing args feed ??0, ??1, …
./compiler/compiler input.syn -o prog 7       # emit a native x86-64 ELF, then run: ./prog 7
./compiler/compiler input.syn --print-errors  # show parse/analysis errors
./compiler/compiler input.syn -t / -v         # timing / verbose

odin test test/typecheck                       # a suite (analyze/typecheck/reduce/default/codegen/parse)
odin test test/analyze -test-name test_constraint_builtin_array_valid_0  # one case
```

`-o FILE` implies `--emit` (gcc-style). When asked to "run the tests", default to `test/analyze` and `test/typecheck`.

**Regenerating a test harness** (after editing its `tests/*.json`): each suite has a `+build ignore` `generator.odin` that rewrites the auto-generated `generated_tests.odin`. Run from inside the category dir: `cd test/analyze && odin run generator.odin -file && cd -`.

## Architecture

Pipeline: **source → parse → analyze (constraint folding) → reduce → bytecode → backend**. A program compiles to a runnable static x86-64 ELF. Two backends consume the bytecode: a reference **interpreter** (`--run`, the oracle every other backend is validated against) and the **x64 ELF emitter** (`-o`). The interpreter handles every domain (int/float/string/bool); the x64 emitter does int/bool via exit-status, floats via XMM + decimal print, concrete strings via `write(1,…)`.

### Three codegen packages

Backend-specific code lives in `backends/<arch>/`, never at the `compiler/` root, so the neutral bytecode can be shared by future backends (aarch64/wasm) with no import cycle.

- **`compiler/bytecode/`** (`package bytecode`, depends on NOTHING in the compiler):
  - `bytecode.odin` — the **target-neutral bytecode**: SSA-like virtual registers (`BC_Value` = vN), its own operator enum `BC_Op`, the `Machine_Type` lattice (U8…I64/F32/F64/Str) + `mtype_*` helpers (incl. `mtype_for_range` — smallest type containing a `[lo,hi]`), the instructions (`BC_Const`/`_F`/`_Str_Const`/`Load_Arg`/`Bin`/`Bin_Imm`/`Cmp`/`Cmp_Imm`/`Move`/`Label_Def`/`Jump`/`Branch_Zero`/`Ret`), `BC_Program`, and the `--bc` dump. **Immediate operands are distinct mnemonics** (`BC_Bin_Imm` = `a op #imm`, like `add r,imm` vs `add r,r`) — a literal is an immediate on the instruction, never a separate value.
  - `interp.odin` — the **reference interpreter** (the oracle): executes a `BC_Program` over tagged i64/f64/string, `interp_bytecode(prog, args)` feeding ??N from argv strings parsed per domain.
- **`compiler/bytecode.odin`** (at the root, `package compiler`) — the **LOWERING** `^Type → bytecode.BC_Program`, the one part that knows both worlds. `lower_to_bytecode(reduce(scope))` memoizes by DAG node address (CSE survives). `machine_type_of` derives each value's `Machine_Type` from the reducer's range (a ??::u8 → U8, `11a+3b-4` whose range is `-4..3566` → I16). `op_to_bc` maps `Operator_Kind`→`BC_Op`. A typed ??'s domain normalization lives in `BC_Load_Arg` (its width/signed), realized by each backend (x64 movzx/movsx) — no separate mask instruction. A symbolic string / unsized domain is rejected with `prog.error`.
- **`compiler/backends/x64/`** (`package x64_assembler`, imports `bytecode`):
  - `x64_instructions/header/utility/test.odin` — the assembler (one proc per instruction, REX/ModRM/SIB, encodings validated against objdump). `x64_sse_scalar.odin` and `x64_movzx_mem.odin` add the SSE scalar ops (`addsd`/`mulsd`/`cvtsi2sd`/…), `cqo`, `shl/sar r64,cl`, and the memory `movzx/movsx` (r64 and r32 forms).
  - `isel.odin` — **instruction selection (LLVM X86ISelDAGToDAG-style).** `X64_Address{base, index, scale, disp}` = X86ISelAddressMode; `match_addr_rec` recursively folds an add/sub/`*{2,4,8,3,5,9}`/shift tree into one `lea base+index*scale+disp`. `lea_is_profitable` is the cost rule. A reg+reg add stays a leaf unless it's the root (so `(11a)+(3b)-4` is one `lea -4(rsi,rdi)`, but two computed sums become `lea(rsi,rdi)` not an overflowing fold).
  - `emit.odin` — the **emitter**: `bytecode.BC_Program` → `.text` + `.rodata`. Uses the linear-scan allocation (values in registers, spill only under pressure). **Strength reduction + immediate folding** (`*2^k`→shl, unsigned `/2^k`→shr, `%2^k`→and, `+0/*1` elided, `0-a`/`a*-1`→`neg`, const→imm). `emit_mul_const_into` decomposes a constant multiply à la clang/LLVM (lea 1cy/2-ports beats imul 3cy/1-port): `*{3,5,9}`→1 lea, `2^i×{3,5,9}`→shl+lea, `{3,5,9}²`→lea+lea, non-factorable→imul. **Unsigned division/modulo by a constant** uses Granlund-Montgomery multiply-high (`magicu64`/`emit_udiv_magic`: `movabs M; mul; shr` + add-correction path) instead of `idiv` — exact over the value's known range (signed div/mod still `idiv`). The non-factorable imul fallback reads its operand in place via the 3-operand `imul dst,src,imm` (no seed mov). **Width-correct 32-bit arithmetic**: `val_is_32bit` → ops in 32-bit registers (movzx r32, imul/add/lea r32) when the value fits — no REX.W, safe by construction (no overflow proof). `emit_load_imm_into` picks `mov r32,imm32` over `movabs`. The ARGS_TABLE base is loaded once into a scratch (`[base+8*slot]` per arg). A runtime **arg stub** parses `argv[1..]` into the table, UNROLLED per slot (the int/float domain of each `??` is known at compile time): an integer slot uses inline atoi (hot path `acc*10` via two `lea`); a FLOAT slot uses inline `emit_atof` (sign + integer part + `.`-fraction → `(ipart+frac/scale)` in scalar SSE → f64 bit pattern stored in the table, loaded straight as bits by `emit_load_arg`).
  - `regalloc.odin`/`regalloc_dump.odin` — liveness + **linear-scan** with **move-biased coalescing** (Briggs: a value prefers the register of an operand that dies at its def; the ret value prefers the exit register) so reg→reg copies elide. 10 allocatable GPRs (RAX/RDX the idiv scratch pair, RCX the shift count, RSP/RBP the frame, RBX the ARGS_TABLE base). `--regalloc` dumps it.
  - `elf.odin` — the **ELF64 writer**: `build_elf(code, rodata)` → static ET_EXEC, one RWX PT_LOAD, plus a minimal section table (`.text`/`.rodata`/`.shstrtab`) so the binary is `objdump -d`/gdb-inspectable. `ARGS_TABLE` at the fixed `ELF_BASE + 0x100000`.
  - `vectorize.odin` — auto-vectorization analysis, **no SIMD emitted yet** (honestly): Syntact folds all concrete computation, so the bytecode carries only scalar ops on individual `??` — nothing to vectorize until the language grows runtime-iterable data. A documented stub.

`resolve.odin` wires `lower_to_bytecode` → `bytecode.bytecode_to_string`/`interp_bytecode` (`--bc`/`--run`) and `x64.allocate_registers`/`x64.emit_executable` (`--regalloc`/`-o`).

### compiler/ package

All non-codegen stages share `package compiler`:

- **ast.odin** — the AST data model only: `Node_Kind`/`Literal_Kind`/`Operator_Kind`, the `*_Data` payloads + `Node_Data` union, the flat SOA `Ast` container (indexed by `Node_Index`), `Span`/`Position`, the `node_*` accessors + `print_ast`. Read nodes through `node_*`, never the raw union.
- **parse.odin** — lexer + parser machinery. Table-driven lexer, single-pass Pratt parser covering the full grammar (bindings `->`/`<-`, productions, carving `{}`, extension `+{}`, collapse `!`, patterns `?`, constraints `:`, raw casts `::`, ranges `..`, events/resonance/reactivity, property `.`, externals `@`). `::` lexes as one `Cast` token and parses at `CONSTRAINT` precedence (tighter than `+`, so `(a+b)::u8` needs parens). **Bit-level operators**: `^`/`<<`/`>>` are direct (Xor/LShift/RShift); only `[&]`/`[|]`/`[~]` are bracketed, to stay visually distinct from the set-algebra `&`/`|`/`~`. All fold via interval arithmetic in integer.odin and lower via `op_to_bc`. **Equality is a single `=`** — `==` is NOT an operator: the lexer flags it `Bad_Double_Equal`, `parse_binary` raises an error and recovers it as one `=`.
- **ir.odin** — the IR data model + its printing: the `Type` union (`Integer_Type`/`Float_Type`/`String_Type`/`Bool_Type`/`Scope_Type`/`Range_Type`/`Or_Type`/`And_Type`/`Negate_Type`/`Compose_Type`/`Cast_Type`/`Pattern_Type`/`Carve_Type`/`Mention_Type`/`Reference_Type`/`None_Type`/`Unknown_Type`/`Invalid_Type`), the interval payloads, and the renderers (`print_type` for `--ir`, `value_to_string`/`write_value` for the reduced value, `type_to_string` for errors).
- **analyze.odin** — semantic analysis. Builds a tree of `Scope_Type` (parallel arrays: `names`/`types`/`kind`/`values` + `type_folds`/`constraint_folds`). `walk()` dispatches on `Node_Kind` to per-kind `walk_<kind>` handlers. `sem_error`/`sem_warning` carry the node's `Span` + resolved position (the LSP reads the range directly). Carve specifics: `walk_property` resolves source-none properties against the carved scope; `recheck_carve` re-proves colored bindings after substitution (implicit-constraint mismatches).
- **integer.odin / float.odin / string.odin / bool.odin** — the four domains. Each does interval arithmetic and the subset (constraint-satisfaction) check over its interval kind. `int_layout` maps a canonical interval to `{bits, signed}`; the raw-cast bit layer (`Bit_Repr`/`resize_bits`) lives in integer.odin. String is a `[]String_Interval` union with ordered `+` sequences, codepoint negation, and three-bound ranges. Bool is the finite set `{true,false}` with `&`/`|`/`~` as set ops.
- **type.odin** — domain-agnostic fold dispatch: `fold_type` (the envelope a value produces), `fold_constraint`/`fold_value_type`/`satisfy`/`type_default`. A comparison over numeric families is not an error even though it yields a bool, not a numeric envelope. `fold_cast` is the `::` raw reinterpret-cast (forces bits into the target layout, never a proof). `fold_carve` materializes a carve into its substituted scope (clone + `repoint` references).
- **pattern.odin** — `target ? { match -> product, … }`. Two branch modes: typecheck `M -> p` (fires when `target ⊆ M`) and value `=v -> p`. Exhaustiveness = the Or of branch covers typechecks the target, else `Non_Exhaustive_Pattern`. A pattern never survives a fold — it resolves to the firing branch's product (or the combined `Or` when the firing branch isn't statically known).
- **reduce.odin** — **symbolic fixed-point reduction (DAG + CSE + affine canonicalization).** `reduce(scope)` collapses through `.Product`; each `??` is a free variable carried, not evaluated. Rule per node: if its `fold_type` is a concrete singleton, that *is* the reduction; else recurse into the value. `reduce_mention`/`reference` follow names to the atomic `??` (`follow_to_fixedpoint`), so every route to one unknown converges (`c -> 2*n; e -> n; c+e` → `3*??0`). **Affine canonicalization** (`collect_sum`/`flatten_sum`/`rebuild_sum`): along a `+`/`-` chain, distribute `const*(affine)` and collect like terms — `3*(2a-1)+5a` → `11a-3`. The cost guard (`op_cost`) only commits when ops don't grow, so a NON-linear product `(a+1)*(a+1)` and `var*var` stay factored. `simplify_arith` coalesces `*`-chain constants (`5*e*14`→`70*e`). Fixed points render as `??N` (`fixedpoint_id`, stable index). GOTCHAS: the DAG bookkeeping is `@(thread_local)` (the test runner reduces on multiple threads) and reset each `reduce()`; `dag_key` strings are heap-allocated.
- **resolve.odin** — compilation orchestrator: thread pool for parallel files, a `Cache` per file, `resolve_entry()` the entry. The per-file pipeline wires parse → analyze → reduce → bytecode → backend.
- **main.odin** — CLI; `parse_args()` into `Options`. On-disk caching is force-disabled in the bootstrap.
- **diagnostics.odin** — turns analysis failures into author-facing messages (the folds answer yes/no; this explains why).

Key conventions:
- **Builtin names are lowercase**: `int`/`float`/`string`/`bool`/`none` + the fixed-width `u8`/`i32`/`f64`/… A capitalized name (`Array`, `Circle`) is always a user scope, never a builtin.
- The constraint system is the analyzer's heart: `5` is `5..5`, `u8` is `0..255`, `true` is `{true}`. Constraints are **static contracts** — the analyzer proves `value ⊆ constraint` or it's a `Constraint_Mismatch`. No implicit coercion; `&` narrows (still proves the subset), `::` reinterprets bits (no proof). Read `constraints.md` before changing folding.
- A constraint must denote a **statically-known set**. A `??` on the constraint side (directly or under any operator) → `Insoluble_Constraint`; on the value side it's fine (`u8:a -> ??::u8`).
- Same-name bindings are valid, tracked by ordinal (`#0`,`#1`,…): access `.` resolves the **last**, carving `{}` targets the **first**.
- Errors use `Analyzer_Error_Type` and the word **constraint**, never "type" — Syntact has no types.
- **Constants carry no type** — they fold into immediates at the backend (a u8 calc stays u8; never promoted "for speed", which would break layout/wrap). The reducer canonicalizes affine arithmetic, NOT the bytecode pass (deleted) — fix the right level (reducer = algebra, backend = machine).
- **No ABI.** Functions unfold at compile time, so a program is one `_start` that exits by syscall — no call/ret, no caller/callee-saved distinction, all registers free scratch. A few functions may eventually survive (runtime recursion, or a binary-size inline cutoff); only then a *minimal* call convention. Don't add an ABI pre-emptively.

### test/ package — six harnesses

`test/{parse,analyze,typecheck,reduce,default,codegen}/` are independent Odin test packages, each with `tests/*.json` + a generated runner. `odin test test/<cat>` runs from anywhere (a `test_path` helper resolves JSON against the source dir).

- **codegen** — the **end-to-end** suite (44 cases, all pass). Each case (`source`+`args`+`expect`+`kind`) is checked against BOTH backends: the interpreter (the oracle) AND the native x64 (emit ELF → run via libc `popen` → compare exit-status/stdout). An interp/native divergence fails the case. Covers every domain + strength reductions, lea selection, 32-bit arithmetic, patterns, carve/collapse/refs/set-ops, strings, floats.
- **typecheck** — constraint-satisfaction (`expect_errors`): self-match, raw-cast `::`, composites, carve implicit-constraints, executes, references in `&`/`|`/`~`, patterns, string sequences/negation/tri-range. ~475 pass.
- **analyze** — `expect_errors` of `Analyzer_Error_Type` names (empty = clean).
- **reduce** — `expect` = the stringified reduced value (concrete `"25"` or symbolic `"11 * ??0 + 3 * ??1 - 4"`). ~12 fail on reducer/parser features not yet reimplemented (carve materialization, scope `+{}`) — gaps, not breakage.
- **default** — `binding` + `expect` (the materialized default across domains/composites). All pass.
- **parse** — `expect` = a serialized AST. ~10 fail on error-recovery cases.

Test function names are `test_{stem}_{index}` (find the exact name in `generated_tests.odin`).

### lsp/ package

- **lsp.odin** — LSP server (JSON-RPC): diagnostics (parse+analyze errors with precise ranges from each error's `span`), hover, go-to-definition, find-references, rename, completion, semantic tokens. Imports `compiler`.
- **semantic.odin** — the LSP's semantic layer. The analyzer keeps no node→Type map, so names resolve **lexically over the AST** (`build_parent_map`, `resolve_definition` honoring `#n` ordinals, `all_references`). Completion/hover use the analyzed `Scope_Type` via `scope_type_at`.
