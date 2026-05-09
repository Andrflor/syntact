# Syntact

> *A language where everything is a scope, nothing is a function, and execution is just reduction.*

---

Syntact is an experimental general-purpose programming language built around one primitive: the **scope**.

A scope is complete structured data. It can contain bindings, defaults, productions, constraints, patterns, handlers, and other scopes. It can be inspected, carved, extended, matched, expanded, and collapsed. It is not a function, an object, a class, a struct, a module, a record, or an instance — although it can replace all of them.

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

## Status

Syntact is in active development.

The current bootstrap compiler is written in Odin. It parses, analyzes, and is being rebuilt around the current semantics. An LSP and a declarative test suite are also part of the project.

This README describes the design direction of the language, including features that are planned but not part of the first implementation. The implementation plan near the end separates the core from later layers such as events, resonance, full scope algebra, and proofs.

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
extension  explicit addition of new structure
shape      scope used as constraint
pattern    shape used analytically
collapse   explicit reduction
handler    scoped interpretation of a nominal effect
```

The syntax is intentionally familiar. Braces, dots, arrows, and names should not make the language look alien. But the semantics are different.

`{...}` is not just a block.

`->` is not assignment.

`:` is not merely a type annotation.

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
```

So “no functions” is not the goal. It is the consequence of choosing smaller primitives.

---

## Table of contents

* [First program](#first-program)
* [Scopes](#scopes)
* [Bindings](#bindings)
* [Productions](#productions)
* [Collapse](#collapse)
* [Execution patterns](#execution-patterns)
* [Carving](#carving)
* [Extension](#extension)
* [Defaults and completeness](#defaults-and-completeness)
* [Primitive types](#primitive-types)
* [Shapes](#shapes)
* [The pattern operator `?`](#the-pattern-operator-)
* [Destructuring patterns](#destructuring-patterns)
* [Carving versus destructuring](#carving-versus-destructuring)
* [Scope algebra](#scope-algebra)
* [Pull bindings and genericity](#pull-bindings-and-genericity)
* [Effects as nominal events](#effects-as-nominal-events)
* [Handlers as compile-time dependency injection](#handlers-as-compile-time-dependency-injection)
* [Resonance](#resonance)
* [Files, folders, and imports](#files-folders-and-imports)
* [Compile-time and metaprogramming](#compile-time-and-metaprogramming)
* [Proofs](#proofs)
* [Why this should be fast](#why-this-should-be-fast)
* [Implementation plan](#implementation-plan)

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

A scope is not only a lexical region. It is data. You can bind it to a name, read its bindings, derive it, constrain values by it, match against it, expand it, or collapse it if it has a production.

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

## Extension

Carving changes existing structure. It should not silently add new structure.

If a binding does not exist yet, use extension:

```syntact
User -> {
  String:name
  u8:age
}

AdminUser -> User+{
  role -> "admin"
}
```

If the binding already exists, use carving:

```syntact
Role -> {
  -> "member"
  -> "admin"
}

User -> {
  String:name
  u8:age
  Role:role -> "member"
}

AdminUser -> User{
  role -> "admin"
}
```

This distinction protects the algebra. A typo should not create a new field by accident.

```syntact
User{
  raole -> "admin" // invalid if `raole` does not exist
}
```

`{...}` means derivation or refinement of existing structure.

`+{...}` means explicit structural extension.

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

Bindings are immutable. To change something, derive a new scope.

```syntact
alice -> User{name -> "Alice" age -> 29}
older -> alice{age -> 30}
```

No null. No uninitialized value. No hidden mutation. Absence must be modeled explicitly.

---

## Primitive types

Primitive types are scopes known by the compiler.

They are primitive in representation, not in ontology.

A minimal primitive set may include:

```text
none      empty value sentinel
bool      false or true
u8        unsigned 8-bit integer
i8        signed 8-bit integer
u16       unsigned 16-bit integer
i16       signed 16-bit integer
u32       unsigned 32-bit integer
i32       signed 32-bit integer
u64       unsigned 64-bit integer
i64       signed 64-bit integer
usize     architecture-sized unsigned integer
isize     architecture-sized signed integer
f32       32-bit floating point
f64       64-bit floating point
char      character / scalar value
String    string data
```

`u8` is the shape of unsigned 8-bit values, defaulting to `0`.

`bool` is the shape of `false` and `true`, defaulting to `false`.

`String` is the shape of strings, defaulting to `""`.

```syntact
u8:count       // 0
bool:enabled   // false
String:name    // ""
```

The exact primitive set may evolve, but the rule should not: primitives behave like scopes in the language model.

---

## Shapes

`:` constrains a binding by a shape.

```syntact
u8:age
String:name
Point:p
```

Read `u8:age` as “age shaped like `u8`”.

A shaped binding can receive a value:

```syntact
u8:age -> 29
String:name -> "Alice"
```

or use its default:

```syntact
u8:age      // 0
String:name // ""
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

Here `Circle:` means “matches the `Circle` shape anonymously”.

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

Patterns can destructure.

```syntact
Circle -> {
  u8:radius
}

area -> {
  Shape:shape

  -> shape ? {
    Circle:{radius(r)} -> r * r * 3
  }
}
```

`Circle:{radius(r)}` means:

```text
match a Circle
open its structure
extract radius
capture radius as r
make r available on the right side
```

You can refine while destructuring:

```syntact
shape ? {
  Circle:{radius(r)?<10} -> r * r * 3
  Circle:{radius(r)}     -> r * r * 3
}
```

You can unify different shapes through a common projection:

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
    Square:{side(s)} | Diamond:{side(s)} -> s * s
  }
}
```

No nominal interface is required. The pattern says what structure it needs.

---

## Carving versus destructuring

This distinction is important.

These three forms are different:

```syntact
Circle:{radius?<10}
Circle{radius?<10}
Circle{radius?<10}:
```

### `Circle:{...}`

This is shape constraint plus local destructuring or patterning.

```syntact
Circle:{radius(r)?<10} -> r
```

It creates an anonymous value constrained by `Circle`, inspects its `radius`, captures it as `r`, and checks `r < 10`.

The capture exists in the branch or scope where the pattern is used.

### `Circle{...}`

This carves or refines the scope `Circle` itself.

```syntact
SmallCircle -> Circle{radius?<10}
```

This defines a refined shape. It does not capture `radius` into a local name.

### `Circle{...}:`

This creates an anonymous binding constrained by the carved shape.

```syntact
Circle{radius?<10}:
```

This means “some anonymous value shaped like a Circle whose radius is less than 10”. It still does not create a local `r` unless you destructure it.

To get `r`:

```syntact
SmallCircle -> Circle{radius?<10}

SmallCircle:{radius(r)} -> r * r * 3
```

This separation keeps the syntax algebraic instead of magical.

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

Structural extension:

```syntact
User -> {
  String:name
  u8:age
}

AdminUser -> User+{
  role -> "admin"
}
```

Structural override:

```syntact
Role -> {
  -> "member"
  -> "admin"
}

User -> {
  String:name
  u8:age
  Role:role -> "member"
}

AdminUser -> User{
  role -> "admin"
}
```

The goal is closure: construction, derivation, extension, matching, destructuring, refinement, and expansion should be explained by the same algebra, not by separate feature systems.

### Grammars as shapes

String patterns and grammars should also live in the algebra.

```syntact
alpha -> 'a'..'z' | 'A'..'Z'
digit -> '0'..'9'
emailChar -> alpha | digit | '.' | '_' | '-'

Email -> {
  String:(s) -> "email@example.com"

  -> s ?!
    emailChar*1..
    + '@'
    + emailChar*1..
    + '.'
    + alpha*2..
}
```

The long-term idea is that regex-like validation is not a string passed to a library. It is a grammar-shaped constraint in the language algebra.

Another example:

```syntact
idChar -> 'a'..'z' | 'A'..'Z' | '0'..'9' | '_' | '-'

Identifier -> {
  String:(s) -> "defaultId"

  -> s ?!
    idChar*1..
    & ~(.. + '_')
}
```

Then:

```syntact
Identifier:id                 // defaultId
Identifier:someId -> "someId" // ok
Identifier:oops -> "bad_"     // rejected if statically known/provable
```

This is not meant to be in the first implementation. But it shows the direction: data modeling, parsing, validation, and proofs should not be separate worlds.

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
    -> decode{value -> encode{value -> value}!}! = value ?! true
  }
}
```

That is not only an interface. It is an algebraic contract: operations plus obligations.

Proof obligations are long-term. The generic structure does not depend on them.

---

## Effects as nominal events

Syntact is structural almost everywhere.

Values are structural. Shapes are structural. Patterns are structural. Modules are structural. Scopes are structural.

Effects are different.

Effects are **nominal events** with structural payloads.

```syntact
Log -> {
  String:message
}

Audit -> {
  String:message
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
  usize:size
}

Buffer -> {
  usize:size
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

Resonance is the planned model for state and reactivity.

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

Resonance is not part of the first implementation. Events come first. Resonance is built on top of events.

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

In Syntact, the “class” is a scope. You can carve it, extend it, inspect it, constrain with it, expand it, or collapse it with the same operators used everywhere else.

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

Proofs are long-term, not part of the first usable version.

The intended operators are:

```text
??  symbolic unknown
?!  proof obligation
```

Example:

```syntact
decodeEncodeSymmetry -> {
  String:m -> ??
  -> decode{value -> encode{value -> m}!}! = m ?! true
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
    -> decode{value -> encode{value -> value}!}! = value ?! true
  }
}
```

The point is not to attach a separate proof assistant to the language. The point is to ask the same reducer a stronger question: can this property be proven for every value of this shape?

This must be added carefully. Proofs can make compile time explode. The first versions should not depend on them.

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

---

## A small practical comparison

A server config in a classical language often needs a class, constructor defaults, validation, and a copy method.

In Syntact:

```syntact
Port -> u16 & >0

ServerConfig -> {
  String:host -> "localhost"
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
explicit extension
explicit reduction
structural shapes
first-class patterns
nominal effects
scoped handlers
compile-time dependency injection
metaprogramming without a meta layer
reactivity through resonance
proofs as future reduction obligations
```

The promise is not that everything becomes easy. The promise is that the hard things belong to one algebra instead of ten incompatible subsystems.

---

## Implementation plan

Syntact is too ambitious to build all at once.

The implementation should grow in layers. Each layer must be useful by itself.

### V0 — Core executable language

Goal: prove that `scope + binding + carving + extension + collapse` works.

Include:

```text
parser
scopes
bindings with ->
productions
access with .
carving with {...}
extension with +{...}
collapse with !
primitive values
basic static analysis
simple backend
```

Exclude:

```text
events
resonance
full scope algebra
proofs
concurrency
advanced grammars
large SDK
```

This must work:

```syntact
square -> {
  n -> 0
  -> n * n
}

-> square{n -> 5}!
```

### V1 — Shapes and patterns

Goal: make Syntact useful for small real programs.

Include:

```text
:
primitive shapes
user-defined shapes
pattern matching with ?
structural destructuring
anonymous shaped bindings
basic refinements
```

This enables:

```syntact
Circle -> {
  u8:radius
}

SmallCircle -> Circle{radius?<10}

area -> {
  SmallCircle:{radius(r)}
  -> r * r * 3
}
```

### V2 — Nominal events

Goal: introduce Syntact's algebraic effects.

Include:

```text
nominal event declaration
event emission with >-
handlers with -<
lexical handler resolution
missing-handler errors
handler override through carving
```

This enables:

```syntact
Log -> {
  String:message
}

program -> {
  Log -< e {
    -> io.write{e.message}!
  }

  >- Log{message -> "hello"}
  -> 0
}
```

### V3 — Resonance

Goal: model state and reactivity through events.

Include:

```text
>>-
-<<
resonant bindings
state abstractions as library scopes
UI-friendly reactive patterns
```

### V4 — Fuller scope algebra

Goal: close the algebra.

Include progressively:

```text
&
|
~
ranges
sequence grammars
shape refinement
exact vs derived shape relations
first-class reusable patterns
module/scope algebra
```

This is where `Email`, `Identifier`, `SmallCircle`, `weirdInt`, JSON grammars, and refined domain shapes become central.

### V5 — Proofs

Goal: add compile-time obligations carefully.

Include only after the rest is stable:

```text
??
?!
limited symbolic reduction
law checking
serializer round trips
simple algebraic properties
```

Proofs are powerful, but they are not required to make the language useful. They are the long-term destination.

---

## Final note

Syntact is not trying to be a small syntax experiment.

It is an attempt to build a programming language from a different computational ontology: one world of complete scopes, manipulated algebraically, reduced explicitly.

If that idea feels strange at first, good. It should. The goal is not to decorate the old categories. The goal is to remove them.

*Syntact is the language I wished existed. If, after reading this, you wish it existed too — you're in the right place.*
