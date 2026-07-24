# Syntact

> *A language where everything is a scope, nothing is a function, and execution is just reduction.*

---

Syntact is an experimental general-purpose programming language built around one primitive: the **scope**.

A scope is complete structured data. It can contain bindings, defaults, productions, constraints, patterns, handlers, and other scopes. It can be inspected, carved, matched, expanded, and collapsed. It is not a function, an object, a class, a struct, a module, a record, or an instance — although it can replace all of them.

The central idea is this:

> Programming languages usually split programs into data, blueprints, and functions. Syntact keeps one world: data.

In most languages, runtime values live in one world, classes and structs live in another, and functions live in a third. Then the language needs bridges: constructors, methods, interfaces, traits, generics, macros, reflection, imports, dependency injection, code generation, and frameworks.

Syntact treats that split as unnecessary. There is one algebraic object — the scope — and a small set of operations over it.

A function-like computation is a scope that can be collapsed. A type is a scope used as a shape. An instance is a scope constrained or carved from another scope. A module is a scope expanded into another scope. A macro-like transformation is just ordinary manipulation of a scope before collapse.

The keystone is **default completeness**:

> Every scope is complete by default.

A scope is not waiting for arguments. A shape is not waiting to be instantiated. A computation is not waiting to be called. Defaults make every scope real data immediately.

```syntact
square -> {
  n -> 0
  -> n * n
}

square.n         // 0
square!          // 0
square{n -> 5}!  // 25

square5 -> square{n -> 5}
square5.n        // 5
square5!         // 25
```

`square` is not a function. `n` is not a parameter. `square{n -> 5}!` is not a call.

`square` is a complete scope with a default binding `n -> 0` and a production `-> n * n`. `square{n -> 5}` derives a new scope. `!` collapses that scope through its production.

What other languages express as a function call, Syntact expresses as two independent operations:

```text
carving  derive a new scope
collapse reduce a scope through its production
```

That separation is the root of the language.

---

## Syntact in one sentence

> Syntact is a structural reduction language with nominal effects.

Its central claim is not that functions, types, modules, and objects are the same thing. Its claim is that they do not need to be primitive categories. They can emerge from operations over complete structures.

---

## How to read Syntact

Syntact intentionally uses familiar surface syntax.

A beginner may read:

```syntact
square -> {
  n -> 0
  -> n * n
}

square{n -> 5}!
```

as something close to:

```text
function square(n = 0) { return n * n }
square(5)
```

That reading is useful, but incomplete.

The structural reading is:

```text
square        a complete scope
n -> 0        a binding occurrence with a default
{n -> 5}      a structural derivation of the scope
!             explicit collapse through the scope production
```

Syntact is designed so shallow readings are productive, but deeper readings reveal the actual model.

A scope is not a function, object, module, record, class, or type. Those are projections produced by operations over scopes.

### Classical reading vs Syntact reading

| Surface form | Classical temptation | Syntact meaning |
|---|---|---|
| `n -> 0` | variable assignment | binding occurrence |
| `-> x` | return | production |
| `square{n -> 5}` | function call setup | structural derivation |
| `square!` | call/eval | collapse |
| `Point:p` | declaration of variable p | binding colored by `Point` — the constraint propagates structurally |
| `box.x` | field access | projection through current view |
| `Log -< e {...}` | callback/listener | nominal effect handler |
| `value >>- Change` | mutable variable | resonant binding driven by nominal event |
| `value -<< e.value` | assignment | resonant update inside handler |
| `x >>= expr` | computed property | reactive derived binding |
| `=<< expr` | reactive effect | reactive production |

The analogies in the middle column help you start reading code. They are not what the language actually does.

---

## Core rules

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

## Status

Syntact is in active development.

The bootstrap compiler is written in Odin and runs the full pipeline end to end: **parse → analyze (constraint folding) → reduce → bytecode → native x86-64 ELF**. A Syntact program compiles to a runnable static executable. The analyzer proves constraints from value ranges (there is no type system, only structural coloring); the reducer collapses everything reducible — carving, collapse, references, patterns, and affine arithmetic — to a minimal form; a target-neutral bytecode then feeds an optimizing x64 backend (linear-scan allocation, register coalescing, LEA-based instruction selection, width-correct 32-bit arithmetic). An LSP (diagnostics, hover, go-to-definition, rename, completion) and six declarative test suites are part of the project.

This README describes the **design direction** of the language, including features that are planned but not yet implemented. Events, resonance, and the full scope algebra are the layers still ahead of the implementation.

---

## Why Syntact exists

Modern programming often feels more complicated than the problems it is trying to solve.

We build abstractions, then write boilerplate to work around them. We create encapsulation, then add reflection to inspect it. We write types, then write serializers, validators, schemas, mappers, builders, adapters, mocks, and dependency containers around them. We use high-level frameworks, then hope the compiler removes the overhead.

Syntact starts from a different assumption:

> Many programming concepts are not fundamentally different. They are different projections of structured data and reduction.

Instead of adding another abstraction layer, Syntact tries to remove the artificial categories underneath.

The basic vocabulary is small:

```text
scope      complete structured data
binding    directed relation inside a scope
production what a scope yields when collapsed
carving    derivation of existing structure
shape      scope used as constraint
pattern    shape used analytically
collapse   explicit reduction
handler    scoped interpretation of a nominal effect
resonance  explicit state driven by nominal events
reactivity implicit derived binding that tracks its dependencies
```

The syntax is intentionally familiar. Braces, dots, arrows, and names should not make the language look alien. But the semantics are different.

`{...}` is not just a block.

`->` is not assignment.

`:` is not merely a type annotation. It is structural coloring that propagates implicitly.

`?` is not just a conditional.

`!` is not general evaluation.

The surface is approachable; the ontology is different.

---

## The problem with functions

Syntact removes the function as a primitive because a function is not really primitive. It is a bundle of several ideas:

```text
parameterization
environment
body
evaluation
calling convention
capture
effects
return
time
```

Most languages start with that bundle, then add features to recover the pieces: closures, lambdas, generics, async functions, iterators, traits, monads, effect systems, macros, partial evaluation.

Syntact decomposes the bundle directly:

```text
parameterization -> carving
environment      -> scope
relation         -> binding
execution        -> collapse
effect           -> event + handler
mutation         -> resonance
reactivity       -> reactive bindings
```

So “no functions” is not the goal. It is the consequence of choosing smaller primitives.

---

## Table of contents

* [First program](#first-program)
* [Scopes](#scopes)
* [Bindings](#bindings)
* [Same-name bindings are not redeclarations](#same-name-bindings-are-not-redeclarations)
* [Productions](#productions)
* [Collapse](#collapse)
* [Execution patterns](#execution-patterns)
* [Carving](#carving)
* [Carving is closed](#carving-is-closed)
* [Defaults and completeness](#defaults-and-completeness)
* [No null, no uninitialized state](#no-null-no-uninitialized-state)
* [Algebraic immutability](#algebraic-immutability)
* [Mutation and reactivity are opt-in](#mutation-and-reactivity-are-opt-in)
* [Values are sets](#values-are-sets)
* [Shapes](#shapes)
* [The pattern operator `?`](#the-pattern-operator-)
* [Destructuring patterns](#destructuring-patterns)
* [Carving versus destructuring](#carving-versus-destructuring)
* [Scope algebra](#scope-algebra)
* [Pull bindings and genericity](#pull-bindings-and-genericity)
* [Effects as nominal events](#effects-as-nominal-events)
* [The external boundary](#the-external-boundary)
* [Handlers as compile-time dependency injection](#handlers-as-compile-time-dependency-injection)
* [Resonance](#resonance)
* [Reactivity](#reactivity)
* [Files, folders, and imports](#files-folders-and-imports)
* [Compile-time and metaprogramming](#compile-time-and-metaprogramming)
* [Proofs](#proofs)
* [Why this should be fast](#why-this-should-be-fast)

---

## First program

A complete Syntact program can be one line:

```syntact
-> 0
```

The file is a scope. The production `-> 0` says that the file-scope produces `0`. Running the program means collapsing the file-scope.

A slightly larger program:

```syntact
greeting -> "hello"
answer -> 42
-> answer
```

This program produces `42`. The binding `greeting` is never used, so there is no reason for it to appear in the final binary.

For example, compiled for Linux x86-64, the resulting program can be as small as:

```asm
_start:
    mov     edi, 42         ; exit code = 42
    mov     eax, 60         ; syscall: exit
    syscall
```

No string `"hello"` remains. No hidden runtime is needed. The compiler reduced the program to what it actually does.

---

## Scopes

A scope is what `{...}` creates.

```syntact
point -> {
  x -> 10
  y -> 20
}

point.x // 10
point.y // 20
```

Scopes can nest:

```syntact
user -> {
  name -> "Alice"
  address -> {
    city -> "Toulouse"
    zip -> 31000
  }
}

user.address.city // "Toulouse"
```

A scope is a complete ordered structure. You can bind it to a name, read its bindings, derive it, constrain values by it, match against it, expand it, or collapse it if it has a production. The role it plays — value, type, module, function-like computation, instance — comes from the operation applied to it, not from a built-in category.

A file is a scope. A folder is a scope. A library is a scope. A primitive type is a scope. A pattern can be a scope. A program is a scope.

---

## Bindings

`->` is the basic binding arrow.

```syntact
name -> "Alice"
age -> 29
```

Read it as “name points to Alice” and “age points to 29”.

Bindings are top-down. A binding can use what exists above it in the same scope or in an enclosing scope.

```syntact
x -> 1
y -> x + 1 // valid
```

This is invalid:

```syntact
y -> x + 1 // invalid: x does not exist yet
x -> 1
```

A scope is not an unordered namespace. It is a directed structure. Later bindings may depend on earlier bindings. Reduction follows that structure.

This matters because there is no separate parameter zone. What other languages call a parameter is usually just an earlier binding with a default.

```syntact
square -> {
  n -> 0
  -> n * n
}
```

`n` is a binding. The production can use it because it appears above.

---

## Same-name bindings are not redeclarations

In a scope, two bindings can share a name. They are not in conflict and the second does not overwrite the first.

```syntact
box -> {
  x -> 1
  y -> x
  x -> 2
}
```

`box` contains two distinct bindings, `x#0` and `x#1`. They are independent entries in an ordered structure, not conflicting entries in a symbol table. The compiler tracks them by index.

This is not shadowing and not redefinition. It is a structural feature: a scope is a sequence of bindings, and several can share a name. Syntact treats a scope as data, not as a symbol table. A symbol table forces unique names. Data does not.

### Access and carving target different occurrences

Same-name bindings introduce a subtle but central rule: **access by name and carving do not look at the scope the same way**.

* **Access** (`box.x`) returns the **last** visible occurrence of `x`. It is a current-view resolution, walking the scope top-down and keeping the last one.
* **Carving** (`box{x -> ...}`) targets the **first** structural occurrence of `x` by default. It is a structural transformation of the scope's foundation.

So given the `box` above:

```syntact
box.x // 2          (last occurrence: x#1)
box.y // 1          (y was bound to x#0, the x in scope at that line)
```

And a carve:

```syntact
box2 -> box{x -> 10}

box2.x // 2         (still reads the last x, which is x#1, untouched)
box2.y // 10        (y depends on x#0, which was carved to 10)
```

Either occurrence can be targeted explicitly:

```syntact
box{x#0 -> 5}  // carve the first x
box{x#1 -> 9}  // carve the last x
box{x   -> 7}  // unqualified: carves x#0
```

A motivating example:

```syntact
Config -> {
  port -> 8080
  url  -> "localhost:" + port
  port -> 3000
}

Config.port // 3000              (last port)
Config.url  // "localhost:8080"  (url was built from the first port)

DevConfig -> Config{port -> 9000}

DevConfig.port // 3000
DevConfig.url  // "localhost:9000"
```

This is not an inconsistency. The two operators answer different questions:

* reading asks **what is the current view of this name**;
* carving asks **what is the structural source this scope is built on**.

Same-name bindings let you expose one value through the visible name while keeping the foundational value carvable. Shadowing and structural rewriting coexist instead of fighting each other.

---

## Productions

A production is a binding without an explicit left side.

```syntact
greeting -> "hello"
-> greeting
```

The implicit source is the enclosing scope itself. The scope points itself at the value it produces.

This replaces `return`.

```syntact
add -> {
  a -> 1
  b -> 2
  -> a + b
}
```

The scope `add` produces `a + b` when collapsed.

A scope may have several productions.

```syntact
BoolLike -> {
  -> false
  -> true
}
```

The first production is the default. Additional productions are potentialities. This is what later allows sum-like shapes and pattern matching.

---

## Collapse

Collapse is written `!`.

```syntact
two -> {
  a -> 1
  b -> 1
  -> a + b
}

two.a // 1
two.b // 1
two!  // 2
```

`!` does not mean “evaluate this expression”. It specifically means: reduce this scope through its production.

A binding may point directly to a value:

```syntact
box -> {
  x -> 1
  y -> x + 1
}

box.y // 2
```

Here `y` is not a scope, so there is nothing to collapse.

A binding may also point to a scope:

```syntact
box -> {
  x -> 1
  y -> {
    -> x + 1
  }
}

box.y  // the scope bound to y
box.y! // 2
```

The rule is:

```text
expressions resolve
scopes collapse
```

A scope with no production collapses to `none`.

```syntact
empty -> {
  x -> 1
  y -> 2
}

empty! // none
```

Collapse is intentional. It happens where `!` appears. That explicitness is what lets the compiler reduce as much as possible before runtime.

---

## Execution patterns

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

## Carving

`{...}` applied to an existing scope carves a derived scope.

```syntact
Point -> {
  x -> 0
  y -> 0
}

shifted -> Point{x -> 5}

Point.x   // 0
shifted.x // 5
shifted.y // 0
```

Carving does not mutate the original. It derives a new scope.

Carving propagates through dependent bindings.

```syntact
box -> {
  x -> 1
  y -> x + 1
}

box.y // 2

box2 -> box{x -> 10}
box2.y // 11
```

This is why carving is not argument passing. A function call passes values into a fixed body. A carve derives a new structure before reduction happens.

```syntact
square -> {
  n -> 0
  -> n * n
}

square{n -> 5}! // 25
```

Read it as:

```text
derive square with n = 5
then collapse the derived scope
```

---

## Carving is closed

Carving refines existing structure. It never adds new structure.

A scope is closed: its set of bindings is fixed the moment it is written. Carving can target any binding that already exists and derive a new scope with a different value, but it cannot introduce a binding that was not there.

```syntact
Role -> {
  -> "member"
  -> "admin"
}

User -> {
  string:name
  u8:age
  Role:role -> "member"
}

AdminUser -> User{
  role -> "admin" // refines the existing `role` binding
}
```

Targeting a name that does not exist is an error, not a silent addition. This protects the algebra: a typo cannot quietly grow a scope.

```syntact
User{
  raole -> "admin" // error: `raole` is not a binding of User
}
```

If you need a different shape, you write a different scope. A scope is complete *and* closed: you carve what is there, you do not bolt on what is not.

`{...}` means derivation or refinement of existing structure. There is no extension operator — there is no way to add a binding to an existing scope.

---

## Defaults and completeness

Defaults are not a small convenience feature. They are what make the one-world model possible.

A scope is complete because its bindings have defaults. A shaped binding is complete because its shape has a default. A computation is complete because it can be inspected or collapsed without being called.

```syntact
Point -> {
  u8:x
  u8:y
}

Point:p

p.x // 0
p.y // 0
```

`Point` is not a blueprint waiting for construction. It is already a complete scope.

```syntact
Point.x // 0
Point.y // 0
```

You can derive a specific point:

```syntact
p -> Point{x -> 10 y -> 20}
```

You can constrain a binding by it:

```syntact
Point:p{x -> 10 y -> 20}
```

You can inspect it:

```syntact
p.x
```

The difference between “type”, “value”, “blueprint”, and “instance” is not a difference of world. It is a difference of operation.

### Defaults compose

Defaults are compositional.

The default of a structured scope is obtained from the defaults of its shaped bindings. A complete structure composed of complete parts is itself complete.

```syntact
Vec2 -> {
  f32:x
  f32:y
}

Transform -> {
  Vec2:position
  Vec2:scale -> Vec2{x -> 1 y -> 1}
}

Transform.position.x // 0
Transform.position.y // 0
Transform.scale.x    // 1
Transform.scale.y    // 1
```

Defaults are not magic values produced by the compiler. They are the natural reading of a complete structure.

---

## No null, no uninitialized state

Syntact has no null.

There is no hidden “missing value” state and no uninitialized binding. A binding is complete because its shape provides a default, and defaults compose structurally.

```syntact
Point -> {
  u8:x
  u8:y
}

Point:p

p.x // 0
p.y // 0
```

`p` is not partially initialized. It is complete by composition.

If absence, failure, optionality, or emptiness is needed, it must be modeled structurally. It is never smuggled in as a null pointer or an uninitialized value.

---

## Algebraic immutability

This is the most important property of Syntact, and it must not be confused with the way mainstream languages talk about “immutability”.

**Nothing is ever modified.** A scope, once described, never changes. Every operator that looks like it changes something actually derives a *new* scope. The original is untouched and remains valid.

```syntact
box -> {
  x -> 1
  y -> x + 1
}

box2 -> box{x -> 10}
```

`box2` is **not** `box` with `x` patched. `box2` is a *new* scope derived from `box` by carving. In `box`, `x` is `1` and `y` is `2`. In `box2`, `x` is `10` and `y` is `11`. Both scopes coexist. Neither was mutated.

This is not “immutability by convention”. It is the meaning of carving. There is no operator in the language that mutates a binding in place. Every transformation is a fresh derivation in the algebra.

A consequence: there is no notion of “the value of `x` after we changed it”. There is only `box.x`, `box2.x`, and any other scope that participates in the derivation graph. Any of them can be inspected at any time.

---

## Mutation and reactivity are opt-in

Because the algebra is immutable, ordinary bindings cannot be mutated, reassigned, or updated in place. There are two separate mechanisms to model change, both layered on top of the immutable core:

- **Resonance** (`>>-` / `-<<`): explicit state driven by nominal events. A binding is declared resonant and its value evolves only when a named event is emitted and handled.
- **Reactivity** (`>>=` / `=<<`): implicit derived bindings that automatically recompute when their dependencies change. No explicit event is needed.

Resonance is the foundation: it is where mutation actually happens. Reactivity is built on top: a reactive binding observes other bindings (including resonant ones) and recomputes structurally.

A program with no resonant or reactive bindings is purely algebraic. Combined with the no-null rule above, this gives the core a strong guarantee: every binding has a value, no value is ever silently replaced, and the only way to model change is to opt in explicitly.

---

## Values are sets



There is no separate world of types. **Every value is a set — usually a set of one.**

`5` is the singleton set `5..5`. `0..255` is a set of 256 values. `>0` is a set. A
"type" is nothing more than a set standing on the left of `:`, and *any* value can
stand there — `5:x` colors `x` by the singleton `5`, which is a perfectly good
(one-inhabitant) type. Values and types are the same continuum, read from the two
ends.

The so-called primitive types are **builtin names for particular sets**:

```text
u8      0..255
i8      -128..127
u16     0..65535
i16     -32768..32767
u32     0..4294967295
i32     -2147483648..2147483647
u64     0..18446744073709551615
i64     -9223372036854775808..9223372036854775807
int     ..0..     every integer
f32     32-bit floats
f64     64-bit floats
float   every decimal
char    a single character
string  ''..      every string
bool    false | true
none    the empty set
```

A builtin is not a keyword: it resolves like any name, and a binding of the same
name shadows it. Domain "types" are the same thing written by hand — there is no
difference in kind between `u8` and:

```syntact
Port -> u16 & >0
Percent -> u8 & <=100
Digit -> '0'..'9'
```

The default of a set is its distinguished element: `0` for the numeric builtins
(including the signed ones), `""` for `string`, `false` for `bool`.

```syntact
u8:count       // 0
bool:enabled   // false
string:name    // ""
```

This is why proofs need no machinery of their own: the compiler tracks every
value's set by construction, and `:` demands the value's set be contained in the
color's. Arithmetic composes sets (`u8 + u8` is `0..510`), comparisons over
decided sets fold to their exact answer (`2 > 2` **is** `false`), and a mistake
is a set that escapes its color — reported at compile time.

---

## Shapes

`:` constrains a binding by a shape.

```syntact
u8:age
string:name
Point:p
```

Read `u8:age` as “age shaped like `u8`”.

A shaped binding can receive a value:

```syntact
u8:age -> 29
string:name -> "Alice"
```

or use its default:

```syntact
u8:age      // 0
string:name // ""
```

A shaped binding can be carved immediately:

```syntact
Point:p{x -> 10 y -> 20}
```

This means:

```text
create p
constrain p by Point
carve p with x -> 10 and y -> 20
```

`:` is not just documentation. It changes how the binding is checked and completed.

A scope used with `:` is interpreted as a shape. The same scope used with `!` is collapsed. The same scope used with `{...}` is carved.

The object is the same. The operator selects the operation.

### Anonymous shaped bindings

The name can be omitted.

```syntact
Circle:
```

This means “an anonymous binding shaped like `Circle`”. It is especially useful in patterns and structural definitions.

```syntact
Shape -> {
  -> Circle:
  -> Square:
}
```

This says that a `Shape` can produce a `Circle` or a `Square`.

### Constraints as implicit structural coloring

`:` does more than check a value against a shape. It **colors** the binding structurally: every constraint imposed by the shape propagates through the binding and everything it contains, without needing to be restated.

Any scope can be used as a constraint. Primitive types, user-defined scopes, carved scopes, refined scopes — the mechanism is the same.

```syntact
Array -> {
  T -> {}
  -> {}
  -> {T: ...Array:}
}
```

`Array` is a recursive scope parameterized by `T`. Its productions describe either an empty scope or a head shaped by `T` followed by more `Array`.

Now define a union-like scope:

```syntact
F32OrString -> {
  -> f32:
  -> string:
}
```

`F32OrString` is a scope whose productions are either `f32` or `String`. It is not a type declaration — it is a scope that produces one of two shapes.

Use it as a constraint through carving:

```syntact
Array{F32OrString}:array -> {0.1 2.0 "hello"}
```

What happens here:

```text
Array{F32OrString}    carve Array with T = F32OrString
:array                constrain array by the carved scope
-> {0.1 2.0 "hello"}  give it a value
```

The constraint on `array` is `Array{F32OrString}`. This means every element must satisfy `F32OrString`. But this constraint was never written on any individual element. `0.1` is not annotated as `f32:`. `"hello"` is not annotated as `string:`. The coloring is **implicit** — it flows from the constraint on the whole scope down to each structural position.

This is a direct consequence of default completeness and the scope model. A constraint is not an annotation that lives on one binding. It is a structural property of the scope, and it propagates inward.

If `array` is later passed to another scope that expects `Array:`, the `F32OrString` constraint on `T` travels with it. No re-annotation is needed at the receiving site.

```syntact
printAll -> {
  Array:items
  -> items ? {
    {} -> "done"
    {head ...tail} -> head + " " + printAll{items -> tail}!
  }
}

printAll{items -> array}!
```

`printAll` accepts any `Array:`. Because `array` was colored as `Array{F32OrString}`, the constraint is already satisfied. The coloring is carried by the value, not by the call site.

This is not type inference in the traditional sense. There is no separate type system reconstructing constraints from usage. Coloring is a structural property: once a scope is constrained, every operation that depends on it inherits the constraint. The scope carries its coloring the way data carries its shape.

---

## The pattern operator `?`

`?` is the pattern operator.

It takes a value on the left and a set of patterns on the right. The first matching pattern selects the corresponding production.

The simplest patterns are literal patterns:

```syntact
n ? {
  0 -> "zero"
  1 -> "one"
  -> "many"
}
```

The final branch has no explicit pattern. It is the default branch.

A pattern can be a shape:

```syntact
shape ? {
  Circle: -> "circle"
  Square: -> "square"
  -> "unknown"
}
```

Here `Circle:` is an anonymous binding shaped by `Circle` — a complete value, by default completeness. Matching is against that complete value: a structural shape carries its colored fields, and a colored field admits any value of its color, so any `Circle`-shaped value takes this branch.

For a primitive shape the complete value is a single leaf — the default — so the anonymous-binding form matches only that value:

```syntact
n ? {
  u8: -> "zero"    // u8: is an anonymous u8 binding — its complete value is 0
  -> "not zero"
}
```

To match a primitive's whole set, use the shape itself, bare:

```syntact
n ? {
  u8 -> "fits in a byte"
  -> "wider"
}
```

The rule is uniform: a branch match is an ordinary expression denoting a set of values, and the branch fires when the scrutinee belongs to it. A bare shape denotes its set. `C:` denotes the complete value of an anonymous binding colored by `C` — structure admits through its colors, a leaf admits only itself.

A pattern can be a refinement:

```syntact
n ? {
  0 -> "zero"
  >0 -> "positive"
  -> "negative"
}
```

A pattern can be composed:

```syntact
value ? {
  (u8 | i8) & >10 -> "small signed-or-unsigned int greater than 10"
  -> "something else"
}
```

This is why `?` is not just an if/switch replacement. It is the analytic side of the algebra.

---

## Destructuring patterns

Destructuring needs no syntax of its own: **a branch's product is lexically a
production of its cover**, so the cover's bindings are simply in scope on the
right side. When the branch fires, the matched pieces substitute into the cover
— reading them IS destructuring.

A named cover exposes its fields by name:

```syntact
Circle -> {
  u8:radius
}

area -> {
  Shape:shape

  -> shape ? {
    Circle: -> radius * radius * 3
    -> 0
  }
}
```

`Circle:` is the anonymous shaped binding; inside the branch, `radius` resolves
into the matched Circle — no extraction operator, just the ordinary resolution
chain.

A structural cover names its pieces with captures. `(x)` is an invisible alias:
not a field, unreachable by `.` or carving, mentionable only from the branch:

```syntact
x -> {3 4 5}

-> x ? {
  {u8:(h) ...u8:(t)} -> h    // h = 3, t = the rest {4 5} as a scope
  -> 0
}
```

The cons cover `{u8:(h) ...u8:(t)}` consumes the run the way the grammar does:
one colored head, an expand tail swallowing the rest — so recursion over a list
is a pattern whose cover mirrors the list's own grammar:

```syntact
sum -> {
  Array{u8}:list
  -> list ? {
    {} -> 0
    {u8:(h) ...Array{u8}:(t)} -> h + sum{list -> t}!
  }
}
```

Two shapes unify through a common projection because resolution is structural,
not nominal — both covers expose `side`:

```syntact
Square -> {
  u16:side
}

Diamond -> {
  u16:side
}

area -> {
  Shape:shape

  -> shape ? {
    Square: | Diamond: -> side * side
    -> 0
  }
}
```

No nominal interface is required. The cover says what structure it needs, and
what it names is what the product can read.

---

## Carving versus destructuring

This distinction is important. These two forms are different:

```syntact
Circle{radius?<10}
Circle{radius?<10}:
```

### `Circle{...}`

This carves or refines the scope `Circle` itself.

```syntact
SmallCircle -> Circle{radius?<10}
```

This defines a refined shape — a new scope, no binding, no capture.

### `Circle{...}:`

This creates an anonymous binding constrained by the carved shape.

```syntact
Circle{radius?<10}:
```

This means "some anonymous value shaped like a Circle whose radius is less than
10". As a pattern cover it matches such values, and its fields destructure the
usual way — the product reads them lexically:

```syntact
SmallCircle -> Circle{radius?<10}

shape ? {
  SmallCircle: -> radius * radius * 3
  -> 0
}
```

This separation keeps the syntax algebraic instead of magical: `{...}` always
derives, `:` always colors, and destructuring is never an operator — it is the
cover's bindings being in scope.

---

## Scope algebra

Syntact is meant to be an algebra of scopes, not merely a language with algebraic data types.

The same operators should apply to values, shapes, patterns, modules, refinements, grammars, and eventually proofs.

Examples:

```syntact
Positive -> >0
Small -> <100

PositiveU8 -> u8 & Positive
SmallPositiveU8 -> u8 & Positive & Small

weirdInt -> (u8 | i8) & >10
```

Direct use:

```syntact
((u8 | i8) & >10):x -> 42
```

Domain shapes:

```syntact
Port -> u16 & >0
Percent -> u8 & <=100
AdultAge -> u8 & >=18 & <=120
```

Refined structures:

```syntact
Circle -> {
  u8:radius
}

SmallCircle -> Circle{radius?<10}
MediumCircle -> Circle{radius?(>=10 & <50)}
BigCircle -> Circle{radius?>=50}
```

Structural override:

```syntact
Role -> {
  -> "member"
  -> "admin"
}

User -> {
  string:name
  u8:age
  Role:role -> "member"
}

AdminUser -> User{
  role -> "admin"
}
```

The goal is closure: construction, derivation, matching, destructuring, refinement, and expansion should be explained by the same algebra, not by separate feature systems.

### Grammars as shapes

String patterns and grammars should also live in the algebra.

A grammar is a set of strings, so a grammar IS a type — written with the same
operators as every other set:

```syntact
alpha -> 'a'..'z' | 'A'..'Z'
digit -> '0'..'9'
emailChar -> alpha | digit | '.' | '_' | '-'

Email -> emailChar*1.. + '@' + emailChar*1.. + '.' + alpha*2..
```

Regex-like validation is not a string passed to a library: `Email` is a constraint
like any other, and coloring is the validation.

```syntact
Email:contact -> "team@example.com"  // proven at compile time
Email:oops -> "not-an-email"         // Constraint_Mismatch
```

Another example:

```syntact
idChar -> 'a'..'z' | 'A'..'Z' | '0'..'9' | '_' | '-'

Identifier -> idChar*1.. & ~(.. + '_')

Identifier:someId -> "someId" // ok
Identifier:oops -> "bad_"     // rejected: ends with '_'
```

Data modeling, parsing, validation, and proofs are not separate worlds: they are
the one constraint algebra, applied to the string family.

---

## Pull bindings and genericity

`<-` declares a hole filled by the use site.

```syntact
identity -> {
  T <- none
  value <- none
  -> value
}

identity{value -> 5}!
identity{value -> "hello"}!
```

`T` and `value` are both holes. Carving with `value -> 5` fills `value`, and `T` is inferred from the shape of what filled it. The use site never has to mention `T` — it is recovered from the carving.

A hole can also be filled explicitly. Since a hole is *pulled*, not pushed, the fill arrow at the use site is `<-`, not `->`:

```syntact
identity{T <- u8 value -> 5}!
```

`value -> 5` is an ordinary push binding into the hole `value`. `T <- u8` says “fill the hole `T` with `u8`”. Mixing the two arrows is not a quirk: `->` pushes a value into a binding, `<-` pulls a value into a hole. The carve can do either at any position.

This is genericity without a separate generic syntax.

A list can be described as a scope with a pulled element shape:

```syntact
List -> {
  T <- none

  -> {}
  -> { T:, ...List{T}: }
}
```

The first production is the empty list. The second production is a head shaped like `T` followed by another `List{T}` expanded into the same structure. The recursive reference `List{T}` propagates the same hole — it does not refill it.

Use it:

```syntact
List{T <- u8}:numbers
```

`T <- u8` fills the hole at the use site. As with `identity`, `T` can also be left to inference when the carving carries enough shape to recover it.

Generic abstractions are just scopes with holes.

A serializer can be modeled the same way:

```syntact
Serializer -> {
  S <- {}
  R <- {}

  encode -> {
    S:value
    -> R:
  }

  decode -> {
    R:value
    -> S:
  }
}
```

Eventually, laws can be added to the same scope:

```syntact
Serializer -> {
  S <- {}
  R <- {}

  encode -> {
    S:value
    -> R:
  }

  decode -> {
    R:value
    -> S:
  }

  roundTrip <- {
    S:value -> ??
    -> true:(decode{value -> encode{value -> value}!}! = value)
  }
}
```

That is not only an interface. It is an algebraic contract: operations plus obligations.

Proof obligations are long-term. The generic structure does not depend on them.

---

## Effects as nominal events

> Syntact is structural by default. Effects are the exception: they are nominal because sometimes structural equality is not meaning equality.

Two events may have the same payload and still be different capabilities. A `Log` and an `Audit` event can carry the same string and still mean very different things. The structure cannot tell them apart; only the name can.

Nominality is not a property of ordinary data in Syntact. It is introduced explicitly through effects.

Values are structural. Shapes are structural. Patterns are structural. Modules are structural. Scopes are structural.

Effects are different. Effects are **nominal events** with structural payloads.

```syntact
Log -> {
  string:message
}

Audit -> {
  string:message
}
```

`Log` and `Audit` have the same structure, but they do not mean the same thing. A `Log` handler must not accidentally handle an `Audit` event.

So the rule is:

```text
internal computation is structural
effects are nominal capabilities
```

Emit an event with `>-`:

```syntact
>- Log{message -> "hello"}
```

Handle an event with `-<`:

```syntact
Log -< e {
  -> io.write{e.message}!
}
```

A full example:

```syntact
program -> {
  Log -< e {
    -> io.write{e.message}!
  }

  >- Log{message -> "hello"}
  -> 0
}

-> program!
```

Handlers are scoped. The first visible handler handles the event. After handling, execution resumes at the point where the event was emitted.

This is Syntact's version of algebraic effects. They are called events because they are emitted and handled, but they are not callbacks, observers, or pub/sub messages.

---

## The external boundary

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

> Note: the external boundary is design, not yet implemented. The `<lib>{}` provenance form, `::` raw casts, and the `??` unknown describe where the language is going; the cast and the unknown already fold in the bootstrap compiler, the `<lib>{}` boundary does not parse yet.

---

## Handlers as compile-time dependency injection

Handlers make many runtime dependency injection patterns unnecessary.

In a classical language, if code needs an allocator, logger, clock, database, random source, HTTP client, or filesystem, you often pass a value around:

```text
function(..., allocator, logger, db, clock)
```

or you hide it behind an object, interface, global, context, or DI container.

In Syntact, the code emits a nominal event. The surrounding scope decides how to interpret it.

```syntact
Alloc -> {
  u64:size
}

Buffer -> {
  u64:size
  ptr -> >- Alloc{size -> size}
  -> ptr
}
```

One scope may choose malloc:

```syntact
WithMalloc -> {
  Alloc -< e {
    -> malloc{e.size}!
  }

  -> Buffer{size -> 1024}!
}
```

Another may choose an arena:

```syntact
WithArena -> {
  Alloc -< e {
    -> arena.alloc{e.size}!
  }

  -> Buffer{size -> 1024}!
}
```

`Buffer` does not receive an allocator. There is no allocator variable. There is only a nominal effect resolved by the current scope.

A library can be specialized by carving its handler:

```syntact
FastLib -> SomeLib{
  Alloc -< e {
    -> arena.alloc{e.size}!
  }
}
```

This is dependency injection moved from runtime to compile time.

It is also an optimization surface. If the handler is known at collapse time, an allocation event can become a malloc call, an arena bump, a stack allocation, a pooled allocation, or disappear entirely if the reduction proves it unnecessary.

The same idea applies to:

```text
logging
profiling
database access
transactions
filesystem permissions
randomness
time
HTTP clients
test mocks
sandboxing
error policy
```

In other languages, this often requires DI, interfaces, mocks, macros, build-time configuration, or runtime lookup. In Syntact, it is scope and handler selection.

---

## Resonance

Resonance is the explicit model for state.

The idea:

```text
mutation = value driven by nominal event
```

A resonant binding uses `>>-` and `-<<`.

```syntact
Counter -> {
  Change -> { u8:value }

  -> {
    u8:value >>- Change -> 0

    Change -< e {
      value -<< e.value
    }

    increment -> {
      >- Change{value -> value + 1}
    }

    decrement -> {
      >- Change{value -> value - 1}
    }

    -> value
  }
}
```

`>>-` declares that a binding is **resonant**: it can change, but only through a named event. `-<<` performs the actual update inside the handler.

There is no hidden mutable field. The state changes only through a visible nominal event.

A reusable state abstraction can be a normal scope:

```syntact
State -> {
  T <- none
  T:initial

  -> {
    Update -> { T:value }

    T:value >>- Update -> initial

    Update -< e {
      value -<< e.value
    }

    set -> {
      T:value
      >- Update{value -> value}
    }

    -> {
      -> value
      set -> set
    }
  }!
}
```

Resonance is not part of the first implementation. Events come first. Resonance is built on top of events.

---

## Reactivity

Reactivity is the implicit model for derived state.

Where resonance requires an explicit event to drive change, a reactive binding automatically recomputes when its dependencies change. The operators are `>>=` and `=<<`.

### Reactive bindings with `>>=`

`>>=` declares a binding whose value is derived from an expression and recomputes when that expression's dependencies change.

```syntact
Counter:globalCounter

bool:counterPositive >>= globalCounter.value >= 0
```

`counterPositive` is not set once. It tracks `globalCounter.value` and recomputes whenever it changes. If `globalCounter` is driven by resonance, then `counterPositive` reacts to each resonant update without needing its own event.

A reactive binding can also be combined with resonance on the same binding:

```syntact
T:value >>- Update =<< initial
```

This means: `value` is resonant (driven by the `Update` event) and initially bound by reference to `initial`. The `>>=`/`=<<` side provides the initialization and structural link; the `>>-` side provides the mutation channel.

### Reactive productions with `=<<`

`=<<` without a left side declares a reactive production: a side effect that re-executes when its dependencies change.

```syntact
Text -> {
  string:text =<< ""
  =<< text ? {
    -> >- Redraw{}
  }
}
```

When `text` changes, the production re-evaluates and emits a `Redraw` event. This is how a UI component can react to its own state without polling or manual subscriptions.

### Resonance vs reactivity

The two mechanisms serve different roles and compose together:

```text
resonance   explicit state change through a nominal event
reactivity  implicit derived computation that tracks dependencies
```

Resonance is where mutation happens. Reactivity is where propagation happens. A reactive binding can observe resonant bindings, other reactive bindings, or any binding whose value may change.

```syntact
State -> {
  T <- none
  T:initial
  -> {
    Update -> { T:value }
    T:value >>- Update =<< initial
    Update -< e { value -<< e.value }
    update -> { T:value, >- Update{value} }
    -> { -> value, set -> update }
  }!
}
```

Then UI state can be built by libraries, not special syntax:

```syntact
CounterView -> {
  State{initial -> 0}:value

  -> Column{
    children -> {
      Text{content -> value!}

      Button{
        label -> "Increment"
        onClick -> {
          value.set{value -> value! + 1}!
        }
      }
    }
  }
}
```

`State`, `Column`, `Text`, and `Button` are scopes. The SDK should be a library of scopes, not a second language.

Neither resonance nor reactivity is part of the first implementation. Events come first. Resonance is built on top of events. Reactivity is built on top of resonance.

---

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

## Proofs

There is no proof operator, because there is no proof system: **the type system
is the prover**. A proof obligation is a coloring — `:` demands that a value's
set be contained in the color's set, the compiler must establish it, and a
failure is a compile error. Since any value is a type, `true` is a color like
any other:

```syntact
true:check -> 2 = 2     // proven: the comparison folds to true
true:oops -> 2 = 3      // Constraint_Mismatch: false does not satisfy true
```

Inline, the same obligation is a colored production:

```syntact
-> true:(2 = 2)
```

`??` provides the quantified values: a symbolic unknown ranges over its whole
set, so a property colored `true` over a `??` asks "does this hold for EVERY
value of that shape?" — the same question, asked of a wider set.

```syntact
decodeEncodeSymmetry -> {
  string:m -> ??
  true:holds -> decode{value -> encode{value -> m}!}! = m
}
```

Or as a law inside a scope:

```syntact
Serializer -> {
  S <- {}
  R <- {}

  encode -> {
    S:value
    -> R:
  }

  decode -> {
    R:value
    -> S:
  }

  roundTrip <- {
    S:value -> ??
    -> true:(decode{value -> encode{value -> value}!}! = value)
  }
}
```

The point is not to attach a separate proof assistant to the language: a proof
is the ordinary constraint contract, and the prover's strength is the reducer's
strength. Today it decides everything the set envelopes decide (concrete values,
decided ranges); symbolic quantification over `??` deepens as the reducer does —
carefully, because proofs can make compile time explode.

---

## Why this should be fast

Traditional languages create abstraction barriers, then optimizers try to remove them.

A function call hides a body. A method hides a function behind a receiver. A trait or interface hides an implementation. A closure hides capture. A dependency hides behind a parameter. A framework hides control flow.

Syntact exposes more structure directly.

When you write:

```syntact
square{n -> 5}!
```

you are asking the compiler to reduce the scope `square` under a known carved binding.

When you write:

```syntact
WithArena -> {
  Alloc -< e {
    -> arena.alloc{e.size}!
  }

  -> parse!
}
```

you are asking the compiler to reduce `parse` under a known interpretation of `Alloc`.

The compiler sees:

```text
bindings
defaults
carvings
productions
constraints
handlers
collapse points
```

It does not need to rediscover all of that through a maze of functions, objects, interfaces, and runtime configuration.

The collapse operator is therefore not just execution syntax. It is an optimization request:

> reduce everything that can be reduced, and keep only what must remain.

The ambition is to write extremely high abstractions and pay only for the machine work that survives reduction.

This is not just an aspiration — it is what the bootstrap compiler already does. A program that stacks dozens of multiplications, distributions, cancellations, and telescoping sums over three runtime arguments:

```syntact
a -> ??::u8 ; b -> ??::u8 ; c -> ??::u8
t1 -> (a*7 + 3)*5            // and many more layers…
u1 -> 2 * (t1 - 5*a)
v1 -> u1 + a*9 - a*9 + 100 - 100
// …seventeen lines of compounding arithmetic…
-> big*2 - (big + 7) + 8
```

reduces to its minimal affine form `60·a + 78·b + 40·c`, and the x64 backend emits the arithmetic core a production C compiler at `-O3` would — all 32-bit, every multiply by a constant folded into `imul`/`lea`, the additions fused into address-mode `lea`, no spills, no wasted moves. The abstractions cost nothing; only the surviving computation is paid for.

Benchmarked against the exact C equivalent (`return 60*a + 78*b + 40*c;`) on the same inputs:

| | Syntact | gcc -O3 | clang -O3 |
|---|---|---|---|
| **arithmetic core** | `imul`+`lea`, 8 insns | equivalent | equivalent |
| **binary size** | **472 B** | 15 976 B | 15 984 B |
| **process startup** (hyperfine) | **152 µs** | 450 µs | 462 µs |
| **compile time** — to a runnable executable (hyperfine `-N`) | **5.3 ms** | 36.9 ms | 52.1 ms |
| **compile time** — front-end + optimizer only (`-c`, object, not yet runnable) | — | 24.3 ms | 26.9 ms |

The generated arithmetic is **on par with -O3** — gcc/clang do not beat the LLVM-style instruction selector. Syntact's edge is structural: no ABI, no libc, a minimal static `_start` that parses argv inline and exits by syscall. So the binary is ~34× smaller and starts ~3× faster. (The startup gap is dominated by libc init and `strtol@plt` calls, which Syntact has neither of; a heavy compute loop would close it, since the arithmetic itself is equivalent.)

On **compile time** Syntact produces a runnable ELF in ~5.3 ms — ~7× faster than gcc and ~10× faster than clang to their final executables. The fair reading is structural, not a smarter optimizer:

- **Linking is a large slice of the gcc/clang number, not parsing.** Stopping at `-c` (object file, no link) drops gcc to 24.3 ms and clang to 26.9 ms — so the link step alone is ~12.6 ms for gcc and ~25.2 ms for clang (about half of clang's total). The front end is noise in both chains: C is not "bigger to parse" than Syntact. Syntact has no separate link step, no libc, no crt — its bytecode lowers straight to a monolithic static ELF.
- **Even removing the link entirely, gcc/clang stay ~4.6–5.1× slower** (24–27 ms for an object that still needs linking, vs Syntact's 5.3 ms for a finished executable). That residual gap is their general-purpose machinery — a heavyweight IR (GIMPLE/RTL, LLVM IR) and optimization passes that run in full on even a trivial program, including overflow-absence proofs and general dataflow analysis. Syntact's reducer knows every value's range *by construction*, so there is no overflow proof to do, and there is no general IR between bytecode and ELF.

So the compile-time win is the same architectural fact as the size and startup wins — no libc/link, range known by construction — not a cleverer optimizer.

---

## A small practical comparison

A server config in a classical language often needs a class, constructor defaults, validation, and a copy method.

In Syntact:

```syntact
Port -> u16 & >0

ServerConfig -> {
  string:host -> "localhost"
  Port:port -> 8080
  bool:debug -> false
}

ServerConfig:config{port -> 3000}

prod -> config{
  host -> "0.0.0.0"
  debug -> false
}
```

No constructor. No builder. No `copyWith`. No nullable parameters. The shape and carving algebra do the work.

An endpoint should not need endpoint-specific syntax. It should be a scope shaped by a library scope.

```syntact
RestEndPoint:userEndpoint{
  path -> "/users/:id"

  get -> {
    maybeId -> Maybe{value -> req.path.get{"id"}!}!

    -> maybeId ? {
      {}: -> HttpResponse{
        status -> 400
        message -> "Invalid id"
      }

      UserId:(id) -> {
        user -> db.users.find{id -> id}!

        -> user ? {
          none -> HttpResponse{
            status -> 404
            message -> "User not found"
          }

          User:{id name} -> HttpResponse{
            status -> 200
            message -> Json.encode{value -> user}!
          }
        }
      }
    }
  }
}
```

`RestEndPoint`, `HttpResponse`, `UserId`, `Maybe`, and `Json` are scopes. The SDK should provide powerful scopes, not ad-hoc syntax.

---

## What Syntact gives up

Syntact gives up:

```text
function as primitive
class as primitive
struct as primitive
module as primitive
mutation as primitive
runtime DI as primitive
macros as a separate language
imports as a separate system
type/value split as a hard boundary
```

In exchange, it tries to get:

```text
one world of data
complete scopes by default
structural derivation
explicit reduction
structural shapes
first-class patterns
nominal effects
scoped handlers
compile-time dependency injection
metaprogramming without a meta layer
resonance for explicit state
reactivity for derived bindings
proofs as future reduction obligations
```

The promise is not that everything becomes easy. The promise is that the hard things belong to one algebra instead of ten incompatible subsystems.

---

## Final note

Syntact is not trying to be a small syntax experiment.

It is an attempt to build a programming language from a different computational ontology: one world of complete scopes, manipulated algebraically, reduced explicitly.

If that idea feels strange at first, good. It should. The goal is not to decorate the old categories. The goal is to remove them.

*Syntact is the language I wished existed. If, after reading this, you wish it existed too — you're in the right place.*
