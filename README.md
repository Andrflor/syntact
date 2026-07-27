# Syntact

> *A language where everything is a scope, nothing is a function, and execution is just reduction.*

---

Syntact is an experimental general-purpose programming language built around one primitive: the **scope**.

A scope is complete structured data. It can contain bindings, defaults, productions, constraints, patterns, handlers, and other scopes. It can be inspected, carved, matched, expanded, and collapsed. It is not a function, an object, a class, a struct, a module, a record, or an instance — although it can replace all of them.

The central idea is this:

> Programming languages usually split programs into data, blueprints, and functions. Syntact keeps one world: data.

In most languages, runtime values live in one world, classes and structs live in another, and functions live in a third. Then the language needs bridges: constructors, methods, interfaces, traits, generics, macros, reflection, imports, dependency injection, code generation, and frameworks.

Syntact treats that split as unnecessary. There is one algebraic object — the scope — and a small set of operations over it.

A function-like computation is a scope that can be collapsed. A type is a scope used as a shape. An instance is a scope constrained or carved from another scope. A module is a scope expanded into another scope. A macro-like transformation is just ordinary manipulation of a scope before collapse.

The keystone is **default completeness**:

> Every scope is complete by default.

A scope is not waiting for arguments. A shape is not waiting to be instantiated. A computation is not waiting to be called. Defaults make every scope real data immediately.

```syntact
square -> {
  n -> 0
  -> n * n
}

square.n         // 0
square!          // 0
square{n -> 5}!  // 25

square5 -> square{n -> 5}
square5.n        // 5
square5!         // 25
```

`square` is not a function. `n` is not a parameter. `square{n -> 5}!` is not a call.

`square` is a complete scope with a default binding `n -> 0` and a production `-> n * n`. `square{n -> 5}` derives a new scope. `!` collapses that scope through its production.

What other languages express as a function call, Syntact expresses as two independent operations:

```text
carving  derive a new scope
collapse reduce a scope through its production
```

That separation is the root of the language.

---

---

## Syntact in one sentence

> Syntact is a structural reduction language with nominal effects.

Its central claim is not that functions, types, modules, and objects are the same thing. Its claim is that they do not need to be primitive categories. They can emerge from operations over complete structures.

---

---

## Why Syntact exists

Modern programming often feels more complicated than the problems it is trying to solve.

We build abstractions, then write boilerplate to work around them. We create encapsulation, then add reflection to inspect it. We write types, then write serializers, validators, schemas, mappers, builders, adapters, mocks, and dependency containers around them. We use high-level frameworks, then hope the compiler removes the overhead.

Syntact starts from a different assumption:

> Many programming concepts are not fundamentally different. They are different projections of structured data and reduction.

Instead of adding another abstraction layer, Syntact tries to remove the artificial categories underneath.

The basic vocabulary is small:

```text
scope      complete structured data
binding    directed relation inside a scope
production what a scope yields when collapsed
carving    derivation of existing structure
shape      scope used as constraint
pattern    shape used analytically
collapse   explicit reduction
handler    scoped interpretation of a nominal effect
resonance  explicit state driven by nominal events
reactivity implicit derived binding that tracks its dependencies
```

The syntax is intentionally familiar. Braces, dots, arrows, and names should not make the language look alien. But the semantics are different.

`{...}` is not just a block.

`->` is not assignment.

`:` is not merely a type annotation. It is structural coloring that propagates implicitly.

`?` is not just a conditional.

`!` is not general evaluation.

The surface is approachable; the ontology is different.

---

---

## The problem with functions

Syntact removes the function as a primitive because a function is not really primitive. It is a bundle of several ideas:

```text
parameterization
environment
body
evaluation
calling convention
capture
effects
return
time
```

Most languages start with that bundle, then add features to recover the pieces: closures, lambdas, generics, async functions, iterators, traits, monads, effect systems, macros, partial evaluation.

Syntact decomposes the bundle directly:

```text
parameterization -> carving
environment      -> scope
relation         -> binding
execution        -> collapse
effect           -> event + handler
mutation         -> resonance
reactivity       -> reactive bindings
```

So “no functions” is not the goal. It is the consequence of choosing smaller primitives.

---

---

## Documentation

The full language reference lives in **[`specs/language/`](specs/language/README.md)** — start
at [How to read Syntact](specs/language/01-reading.md), or jump to the
[core rules](specs/language/02-core-rules.md) if you prefer the twelve-line version.

| If you want… | Read |
|---|---|
| the language, in reading order | [`specs/language/`](specs/language/README.md) |
| why abstractions cost nothing here, with benchmarks | [Why this should be fast](specs/language/20-performance.md) |
| how constraints and ranges actually work | [`specs/constraints.md`](specs/constraints.md) |
| calling C libraries — state and open questions | [`specs/interop.md`](specs/interop.md) |
| effects and the external boundary, by design | [`specs/effects.md`](specs/effects.md) |
| cross-platform ABI, linking, library naming | [`specs/abi.md`](specs/abi.md) |
| the multi-target backend — PIE, Mach-O, PE, signing, hot reload | [`specs/targets.md`](specs/targets.md) |
| the `syntact` command surface | [`specs/sdk.md`](specs/sdk.md) |

The `specs/language/` documents describe the **design direction**, including features that are
planned but not yet implemented. What the bootstrap compiler does *today* is the Status section
below. The other documents in `specs/` are working design notes and say so at the top.

---

## Status

Syntact is in active development.

The bootstrap compiler is written in Odin and runs the full pipeline end to end: **parse → analyze (constraint folding) → reduce → bytecode → native x86-64 ELF**. A Syntact program compiles to a runnable static executable — or, when it declares an external boundary, to a dynamically linked one: the compiler emits the ELF dynamic tables (`.interp`, `.dynstr`, `.dynsym`, `.hash`, `.rela`, `.dynamic`) itself, so linking against a `.so` needs no external linker and no build system. Only scalar arguments and results are supported so far (see `interop.md`). The analyzer proves constraints from value ranges (there is no type system, only structural coloring); the reducer collapses everything reducible — carving, collapse, references, patterns, and affine arithmetic — to a minimal form; a target-neutral bytecode then feeds an optimizing x64 backend (linear-scan allocation, register coalescing, LEA-based instruction selection, width-correct 32-bit arithmetic). An LSP (diagnostics, hover, go-to-definition, rename, completion) and six declarative test suites are part of the project.

This README describes the **design direction** of the language, including features that are planned but not yet implemented. Events, resonance, and the full scope algebra are the layers still ahead of the implementation.

---

---

## Repository layout

```
compiler/            the bootstrap compiler, in Odin
  bytecode/          target-neutral bytecode + the reference interpreter (the oracle)
  backends/x64/      instruction selection, register allocation, ELF writer
lsp/                 language server
test/                six declarative test suites
specs/               design notes and the language reference
  language/          the language reference
```

## Building

```sh
odin build compiler -out:compiler.bin
./compiler.bin program.syn -o program     # compile to a native executable
./compiler.bin program.syn --run          # run on the bytecode interpreter
./compiler.bin program.syn --ir --bc      # inspect the reduced IR and bytecode
```

---

## What Syntact gives up

Syntact gives up:

```text
function as primitive
class as primitive
struct as primitive
module as primitive
mutation as primitive
runtime DI as primitive
macros as a separate language
imports as a separate system
type/value split as a hard boundary
```

In exchange, it tries to get:

```text
one world of data
complete scopes by default
structural derivation
explicit reduction
structural shapes
first-class patterns
nominal effects
scoped handlers
compile-time dependency injection
metaprogramming without a meta layer
resonance for explicit state
reactivity for derived bindings
proofs as future reduction obligations
```

The promise is not that everything becomes easy. The promise is that the hard things belong to one algebra instead of ten incompatible subsystems.

---

---

## Final note

Syntact is not trying to be a small syntax experiment.

It is an attempt to build a programming language from a different computational ontology: one world of complete scopes, manipulated algebraically, reduced explicitly.

If that idea feels strange at first, good. It should. The goal is not to decorate the old categories. The goal is to remove them.

*Syntact is the language I wished existed. If, after reading this, you wish it existed too — you're in the right place.*
