# Syntact language reference

The normative description of the language, split out of the project README. Read in order the
first time — each part builds on the ones before it.

> **Design direction, not implementation status.** These documents describe the language as
> intended, including features not yet implemented. What the bootstrap compiler does *today* is
> in the root [`README.md`](../../README.md) under *Status*. The per-area working notes are the
> sibling documents in [`specs/`](..).

## Orientation

- [**How to read Syntact**](01-reading.md) — the classical reading vs the structural one, side by side
- [**Core rules**](02-core-rules.md) — twelve lines. Most surprises resolve to one of them

## The model

- [**First program**](03-first-program.md) — a file is a scope; running it is collapsing it
- [**Scopes**](04-scopes.md) — the one primitive. What `{...}` creates
- [**Bindings**](05-bindings.md) — `->`, ordering, and why two bindings may share a name
- [**Productions and collapse**](06-productions-and-collapse.md) — `->` without a left side, and what `!` actually means
- [**Execution patterns**](07-execution-patterns.md) — `<!>` `[!]` `(!)` `|!|` — strategy at the collapse site, not in the computation
- [**Carving**](08-carving.md) — deriving a new scope, and why a scope is closed
- [**Defaults, completeness, immutability**](09-defaults-and-immutability.md) — why there is no null and nothing is ever mutated

## Shapes, sets, and patterns

- [**Values are sets**](10-values-are-sets.md) — there is no separate world of types; `5` is a singleton set
- [**Shapes**](11-shapes.md) — `:` as structural coloring that propagates inward
- [**Patterns and destructuring**](12-patterns.md) — `?`, covers, captures, and why destructuring needs no operator
- [**Scope algebra**](13-scope-algebra.md) — `&`, `|`, `~`, refinement — and grammars as ordinary sets
- [**Pull bindings and genericity**](14-genericity.md) — `<-` holes. Generics without generic syntax

## Effects, state, and the outside world

- [**Effects, events, and handlers**](15-effects-and-handlers.md) — the one nominal thing in a structural language; DI at compile time
- [**The external boundary**](16-external-boundary.md) — `<lib>{}` and `??::u8` — a scope whose production points out
- [**Resonance and reactivity**](17-resonance-and-reactivity.md) — `>>-` / `-<<` for state, `>>=` / `=<<` for derived bindings
- [**Files, folders, imports, metaprogramming**](18-modules.md) — the filesystem as a scope graph; why metaprogramming is just programming

## Proofs and performance

- [**Proofs**](19-proofs.md) — no proof system — the coloring *is* the obligation
- [**Why this should be fast**](20-performance.md) — what survives reduction is what you pay for, with benchmarks

---

## Design notes — siblings, not language reference

| Document | Covers |
|---|---|
| [`constraints.md`](../constraints.md) | the constraint system in full: ranges, interval arithmetic, coercion rules |
| [`effects.md`](../effects.md) | external boundary and effects, design decisions and open questions |
| [`interop.md`](../interop.md) | what `<lib>` does today, verified libraries, the open memory-model question |
| [`abi.md`](../abi.md) | cross-platform calling conventions, link mechanisms, library naming |
| [`targets.md`](../targets.md) | multi-target backend architecture — PIE, Mach-O, PE, signing, hot reload |
| [`sdk.md`](../sdk.md) | the `syntact` command surface — run, build, bundle, doctor, format, lsp |
