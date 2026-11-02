# The external boundary

What the program cannot compute — the operating system, a linked library, the
hardware — is a scope whose leaves are outside (`types.md` §4.8):

```syntact
kernel -> <kernel.so>{
  write -> {
    u8:a  u8:b
    -> !?::u8
  }
}
```

`<kernel.so>` says where the scope's symbols — the scopes written in it — are run.
Everything inside is an ordinary scope: `write` has colored fields and a production
`!?::u8`, an effect that gives back a `u8` (chapter 10).

## Calling outside is carving and collapsing

```text
kernel.write                  // the scope: nothing happens
kernel.write{2, 3}!           // carve, then collapse: ε<write{a -> 2  b -> 3}!>(x::u8, x)
partial -> kernel.write{b -> 4}
partial!                      // and here, only now
```

Carving a symbol calls nothing. The call is at `!`, and only there: it is the effect
of the production, in the order it is written. The effects of the fields run before
it, and the call takes their answers as values.

## Pure symbols

A symbol whose production is an unknown, `??::L`, has no effect: its answer is a
value in L that this program does not compute. It is a term like any other: what
nothing reads is erased, and it is not ordered with the effects.

```syntact
libm -> <libm.so.6>{
  cbrt -> {f64:x, -> ??::f64}
}
one -> {r -> libm.cbrt{x -> 8.0}!  -> 1}!    // 1: nothing reads r, no call
```

A field that comes right before the production ends with a comma: `{f64:x, -> …}`.
Without it, `f64:x -> …` is one binding, `x` with that value.

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
