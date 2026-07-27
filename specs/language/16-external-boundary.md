# The external boundary

Pure Syntact reduces toward singletons. But a real program eventually has to talk to something it cannot reduce: the kernel, a linked library, the hardware. That is the **external boundary**, and it is not a special feature — it is just a scope whose production points *outside*.

```syntact
kernel -> <kernel.so>{
  write -> {
    u8:a  u8:b
    -> ??::u8
  }
  read -> {
    i32:fd  u64:len
    -> ??::i64
  }
}
```

`<kernel.so>` is **provenance**: it tells the compiler where the scope's leaves come from, and maps directly to one import descriptor. Everything inside is an ordinary scope. `write` is a scope with colored input bindings (`u8:a`, `u8:b`) and a production `-> ??::u8`.

That production is the key. `??` is an unknown value; `::u8` forces it into the `u8` layout. So `??::u8` reads as *"a value that is not computable in pure Syntact, but whose layout is known to be u8"*. The body is structurally empty — only the shape of the result is known, not the result. That is exactly what makes a leaf external.

### Calling an external is ordinary scope algebra

Because `write` is just a scope, there is no special call syntax. Carving and collapse do the work, the same as everywhere else:

```syntact
kernel.write              // projection — the scope, not executed
kernel.write{2, 3}!       // positional carve (a <- 2, b <- 3), then collapse
kernel.write{a -> 2 b -> 6}! // nominal carve, then collapse

partial -> kernel.write{b -> 4}  // partial carve, NO collapse — pure data, no effect
partial!                         // collapse here → the effect happens here, only now
```

**Carving an external does not execute it.** A partially-applied external is just another scope — pure data. The effect happens at `!`, and only there. This is consistent with the rest of the language: effects live at collapse points.

### The effect marker is the frontier, not the result

An external collapse is effectful **because the target is an external leaf**, not because its production fails to reduce to a point. This matters:

- A `void`/no-return external (e.g. closing a handle for its side effect) still performs an effect, even though its result folds to `none`.
- An external returning a constant still performs an effect — the *act* of crossing the boundary is the effect, not the shape of what comes back.

So the rule is: an effect is lifted whenever a collapse crosses the external frontier, regardless of whether the production is singleton, non-singleton, or void.

### No glue

This is where the one-world model pays off. In a language with a boxed runtime, calling a C library means writing a translation layer — unwrapping objects, marshalling, refcounting — for every binding, maintained by hand. That glue exists because there are *two* representations that do not speak to each other.

Syntact has one representation. A string, an array, a scope are *values* in the machine layout, not boxed objects — there is no pointer type in the pure language; the pointer only appears in boundary codegen, derived mechanically by a size rule (a value larger than a register is passed by address, otherwise by value). So there is nothing to translate. You declare the provenance, color the signatures, and the library is a scope you carve and collapse like any other.

You can even prove safety *at* the frontier. A C string is "any non-null char, then a terminator", which is a content constraint:

```syntact
CString -> (~'\0').. + '\0'
```

A string satisfying `CString` is statically known to be a well-formed C string — no interior null — *before* it ever crosses the boundary.

### Writing a library in Syntact

The same shape works in reverse. An external library is a scope whose production points out; a library *written in Syntact* is a scope whose production reduces *in*. They are the same object, seen from two sides — there is no separate notion of "a library".

So you do not need to drop into C for the fast path. A Syntact library is structure that folds: when its inputs are known it reduces to a singleton at compile time, and when they are not it reduces to its op-minimal symbolic form. It reaches codegen already optimized by construction, it is inspectable instead of being an opaque blob, it specializes at the call site through carving, and it cross-compiles by an arch flag instead of shipping one binary per platform. There is nothing to bundle.

The external boundary is therefore the *exception* — reserved for code you do not control (the kernel, a proprietary `.so`). Everything else is written in Syntact: pure, reducible, optimized by reduction.

> Note: the external boundary is **partially implemented**. `<lib>{}` parses, analyzes and reduces; a collapse across the frontier becomes a real call in the emitted executable, and the compiler writes the ELF dynamic tables itself — no external linker is invoked. Verified against `libm`, `libc`, `libz`, `libcrypto`, `libpcre2`, `libasound` and `libSDL2`, including two libraries in one binary. What works today is scalars that fit a register (integers and floats, up to six arguments, in any mix); passing an address — and therefore the whole `String`/array side of the size rule — is not implemented, and the memory model it depends on is still an open design question. See `interop.md` for the full state and the open questions.

---

---

[← Effects, events, and handlers](15-effects-and-handlers.md) · [Index](README.md) · [Resonance and reactivity →](17-resonance-and-reactivity.md)
