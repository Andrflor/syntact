# The Syntact language

Syntact is one algebra of types. Its reference is [`types.md`](../types.md); each
chapter here presents one part of it, with examples the kernel checks. Where a chapter
and `types.md` disagree, `types.md` wins.

## The algebra

- [**Values are types**](01-values-are-types.md) — primitives, `| & ~ =`, ranges, `none`, `:` and `in`, defaults
- [**Operators**](02-operators.md) — families, legality, terms over unknowns, strings and grammars
- [**Scopes**](03-scopes.md) — bindings, occurrences, productions, collapse, expansion
- [**Carving**](04-carving.md) — a copy with substitution; calling is carving, then collapsing
- [**Shapes**](05-shapes.md) — a scope as a color: productions, structures, runs, the color that flows
- [**Unknowns and the check**](06-unknowns-and-the-check.md) — `??`, equations, the three verdicts, proofs
- [**Patterns**](07-patterns.md) — `?` as a type, unknown targets, destructuring
- [**Recursion**](08-recursion.md) — closed forms, Arden, guarded productions
- [**Holes and genericity**](09-holes.md) — `<-`, filled at the use site or inferred

## Open

These parts are the intent: they are not written in `types.md` yet, and the kernel
does not build them.

- [**Effects and handlers**](10-effects-and-handlers.md) — `>-` and `-<`, served by the context of the call
- [**The external boundary**](11-external-boundary.md) — `<lib>{…}`: a scope whose production points outside
- [**State**](12-state.md) — resonance `>>-` `-<<`, reactivity `>>=` `=<<`
- [**Execution patterns**](13-execution-patterns.md) — `<!>` `[!]` `(!)` `|!|`
- [**Modules**](14-modules.md) — files and folders as scopes, `@`

## To code

- [**From type to code**](15-from-type-to-code.md) — the normal form is the program

---

Design notes outside the language — the SDK, targets, the ABI, interop, benchmarks —
are in [`docs/`](../../docs).
