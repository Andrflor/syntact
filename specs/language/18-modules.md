# Files, folders, imports, metaprogramming

## Files, folders, and imports

Files and folders are scopes.

`@` resolves the filesystem as a scope graph.

```syntact
Plane2D -> @lib.geometry.Plane
```

A folder is a scope whose bindings are its files and subfolders. A file is a scope whose bindings are its top-level declarations.

Importing is expansion:

```syntact
...@lib.geometry
```

A library can be carved before expansion:

```syntact
...@lib.geometry{
  Plane -> Plane{dimension -> 3}
}
```

A handler can be overridden the same way:

```syntact
FastGeometry -> @lib.geometry{
  Alloc -< e {
    -> arena.alloc{e.size}!
  }
}
```

There is no separate import ontology. The filesystem is a scope graph, and imports are scope operations.

---

## Compile-time and metaprogramming

Syntact blurs the line between programming and metaprogramming because a program before collapse is already data.

In other languages, manipulating a class as data requires reflection, annotations, code generation, templates, macros, or compiler plugins.

In Syntact, the “class” is a scope. You can carve it, inspect it, constrain with it, expand it, or collapse it with the same operators used everywhere else.

Many things that are metaprogramming elsewhere become ordinary programming:

```text
constructor generation  -> defaults + carving
copyWith                -> carving
schema derivation       -> scope inspection
generic specialization  -> pull binding + carving
macro expansion         -> scope transformation
DI configuration        -> handler override
mocking                 -> local handler override
compile-time constants  -> pure collapse
module specialization   -> carved expansion
```

A pure computation can be reduced by the compiler:

```syntact
greeting -> "hello, " + "world"
-> greeting
```

No runtime concatenation is necessary.

Effects mark the boundary. If collapse reaches an event that must happen at runtime, that work remains runtime. If the event has a compile-time interpretation, it can be reduced earlier.

The compiler and runtime are not different semantic engines. The compiler is the reducer used before runtime.

---

---

[← Resonance and reactivity](17-resonance-and-reactivity.md) · [Index](README.md) · [Proofs →](19-proofs.md)
