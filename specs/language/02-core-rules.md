# Core rules

1. A scope is an ordered structure, not a symbol table.
2. A binding is an occurrence, not a variable slot.
3. A name is a projection, not an identity.
4. Access resolves a name through the current view.
5. Carving derives a new scope by targeting existing structural occurrences.
6. A scope is closed: carving refines existing bindings, it never adds new ones.
7. Collapse reduces a scope through its production.
8. Shapes are scopes used as structural constraints.
9. Patterns are scopes used analytically.
10. Effects are nominal; everything else is structural.
11. Defaults compose structurally.
12. No binding is ever mutated by the core language.

Come back to this list when a section feels surprising. Most surprises resolve to one of these rules.

---

---

[← How to read Syntact](01-reading.md) · [Index](README.md) · [First program →](03-first-program.md)
