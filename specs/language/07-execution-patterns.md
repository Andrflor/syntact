# Execution patterns

`!` is the basic collapse operator, but collapse can be wrapped by **execution patterns**.

An execution pattern says *how* a collapse should happen, without changing the scope being collapsed.

Basic patterns:

```text
!   sequential collapse
<>  threading
[]  parallel CPU
()  background
||  GPU
```

These patterns compose around `!`.

```syntact
result -> work!       // sequential
result -> work<!>     // collapse on another thread
result -> work[!]     // collapse in parallel on CPU
result -> work(!)     // collapse in background
result -> work|!|     // collapse on GPU
```

The important part is that execution strategy belongs to the collapse site, not to the computation itself.

`work` does not have to be declared as async, threaded, parallel, background, or GPU-aware. The same scope can be collapsed differently in different contexts.

```syntact
result -> packed<[!]>     // threaded parallel execution
result -> packed([<!>])   // parallel threaded execution
result -> packed<(!)>     // threaded background execution
result -> packed(<!>)     // background threaded execution
result -> packed<|!|>     // threaded GPU execution
result -> packed(|!|)     // background GPU execution
```

Patterns may be nested arbitrarily as long as the composition is valid for the scope being collapsed.

```syntact
result -> packed(<[!]>)    // background threaded parallel execution
result -> packed(|<[!]>|)  // GPU background threaded parallel execution
result -> packed([([!])])  // parallel background parallel execution
```

Execution patterns are not special function calls. They are collapse forms.

They can be applied to carved scopes:

```syntact
map{list -> {1 2 3 4 5} mapper -> double}![!]
reduce{list -> packed! reducer -> add}<!>
transform{shape -> shape transformer -> double}(<[!]>)
```

They can also be applied to other reducible expressions where the result is meaningful:

```syntact
Circle{radius -> 10}<[!]>
(1 + 2)<!>
map{list -> {2 3}}[!] + reduce{reducer -> plop}<!>
```

The compiler is responsible for checking whether a pattern is legal. For example, parallel CPU or GPU collapse may require purity or effect handlers compatible with that execution mode. A scope that emits unsafe effects cannot simply be sent to a parallel or GPU collapse unless the surrounding handlers make that legal.

This keeps concurrency, background work, threading, and GPU dispatch out of the computation itself. They are not different function kinds and do not require separate async syntax. They are different ways to collapse the same scope.

### Patterns constrain strategy, not machine form

A GPU collapse does not mean “compile this scope into exactly one GPU kernel”.

Depending on the reduced structure, a GPU collapse may produce:

```text
zero kernels       if everything is reduced at compile time
one kernel         for simple data-parallel work
multiple kernels   for reductions or complex pipelines
library calls      for specialized operations such as matrix multiplication
a compile error    if the region is not legal for GPU execution
```

`|!|` constrains the collapse strategy. It does not expose a kernel model in the source language. The same is true of `[!]`, `<!>`, and `(!)`: they declare a strategy, not a fixed lowering.

---

---

[← Productions and collapse](06-productions-and-collapse.md) · [Index](README.md) · [Carving →](08-carving.md)
