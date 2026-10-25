# Execution patterns

> **Open.** Execution patterns are not written in `types.md` and the kernel does not
> build them. They choose how a collapse runs; they do not change what it gives, so
> they do not change its type.

`!` collapses a scope in sequence. An execution pattern wraps it to say how:

```text
work!       in sequence
work<!>     on another thread
work[!]     in parallel, on the CPU
work(!)     in the background
work|!|     on the GPU
```

They compose: `work<[!]>` is threaded parallel, `work(|!|)` a background GPU collapse.

The strategy belongs to the collapse, not to the computation: `work` is not declared
async, parallel or GPU-aware, and the same scope can be collapsed in different ways
in different places.

```text
map{list -> {1 2 3 4 5}  mapper -> double}[!]
reduce{list -> packed!  reducer -> add}<!>
```

A pattern is legal only for what it collapses: a parallel or GPU collapse requires a
scope whose effects its handlers allow there.

A pattern constrains the strategy, not the machine code. A GPU collapse may give no
kernel at all when everything reduces at compile time, one kernel, several, a library
call — or an error, when the region cannot run on a GPU.

---

[← State](12-state.md) · [Index](README.md) · [Modules →](14-modules.md)
