# The external boundary

> **Open.** `<lib>{…}` is not written in `types.md` and the kernel does not build it.
> The previous pipeline compiles it to real calls (see `docs/interop.md`).

What the program cannot compute — the operating system, a linked library, the
hardware — is a scope whose production points outside. Its result is an unknown of a
known layout:

```text
kernel -> <kernel.so>{
  write -> {
    u8:a  u8:b
    -> ??::u8
  }
}
```

`<kernel.so>` says where the scope's leaves come from. Everything inside is an
ordinary scope: `write` has colored bindings and a production `-> ??::u8`, a value
not computable here whose layout is `u8` (chapter 06).

## Calling outside is carving and collapsing

```text
kernel.write                  // the scope: nothing happens
kernel.write{2, 3}!           // carve, then collapse: the call happens here
partial -> kernel.write{b -> 4}
partial!                      // and here, only now
```

Carving an external does not run it. The effect is at `!`, and only there: crossing
the boundary is an effect, whatever comes back — a value, a constant, or nothing.

## No glue

There is one representation of values, so there is nothing to translate at the
boundary: you say where a scope comes from, color its bindings, and carve and
collapse it like any other. A property of what crosses can be proven before it does:

```syntact
CString -> (char & ~'\0') * 0.. + '\0'
CString:s -> "abc\0"          // proven: no '\0' before the end
```

A library written in Syntact is the same object seen from the other side: a scope
whose production reduces inward. The boundary is for code you do not control.

---

[← Effects and handlers](10-effects-and-handlers.md) · [Index](README.md) · [State →](12-state.md)
