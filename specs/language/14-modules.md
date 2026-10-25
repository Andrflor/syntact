# Files, folders, and modules

> **Open.** `@` is not written in `types.md` and the kernel does not build it. A file
> is a scope; the rest of this chapter is the intent.

A file is a scope whose bindings are its top-level declarations. A folder is a scope
whose bindings are its files and subfolders. `@` reads the filesystem as that graph of
scopes:

```text
Plane2D -> @lib.geometry.Plane
```

Importing is expansion, and a library can be carved before it is placed:

```text
...@lib.geometry
...@lib.geometry{
  Plane -> Plane{dimension -> 3}
}
FastGeometry -> @lib.geometry{
  Alloc -< e { -> arena.alloc{e.size}! }
}
```

There is no import system beside the scope operations.

## Metaprogramming is programming

A program before collapse is already a value of the algebra. What needs reflection,
code generation or macros elsewhere is an ordinary operation here:

```text
constructor              defaults and a carve
copy with a change       a carve
specialization           a carve, a hole
dependency injection     a handler
mock                     a handler in the context of a test
compile-time constant    a collapse whose inputs are known
```

The compiler does not run a second language: it computes the normal form of the
program, which is what the program is (chapter 15).

---

[← Execution patterns](13-execution-patterns.md) · [Index](README.md) · [From type to code →](15-from-type-to-code.md)
