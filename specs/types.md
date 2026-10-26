# The type algebra

> **Status: reference.** The kernel (`kernel/`) implements it; the chapters of
> `specs/language/` present it, with examples.
>
> There is one type system: a unified equational algebra. A type is an equation,
> either constant or with unknowns. The primitive types are the values (§1). The
> algebra composes them (§2, §4), and so do scopes (§5). Scopes, names, carving,
> collapse, patterns, recursion and the check are operations of this algebra,
> defined by laws: equations between types. There is no other mechanism. An
> implementation that adds a path, a table or a case beside these laws is outside
> this spec.
>
> Where another document contradicts this one, this one wins (§8).

## 1. The primitive types

```text
''  'a'  'b'  '@'  …       every character; '' is the empty character, below all others
…  −1  0  1  2  …          every integer
0.5  −3.25  …              every real
true  false
none                       the empty type: the absence of type, itself a type
?                          the unknown
!?                         an effect
```

Each `?` written is a distinct unknown, indexed `?₁`, `?₂`. The same unknown comes
back through a name (§5.2). Each `!?` written is a distinct effect, indexed `ε₁`,
`ε₂` (§4.8).

## 2. The algebra

```text
t ::= p                          a primitive type
    | t | t     t & t     ~t     =t
    | t op t     op t            an operator (§4.5)
    | l..u   l..   ..u   ..      .. extends |, up to infinity
    | >t   >=t   <t   <=t
    | t::L                       t read in the layout L: ??::u8 is ?₁::u8
    | x                          a name: the type of its binding (§5.2)
    | {b…}                       a scope (§5)
    | s.x   s!   s{…}   ...s     access, collapse, carve, expansion (§5.3)
    | t ? {…}                    a pattern (§6)
```

Every operation on types gives a type. The whiteboard writes `a | b` as
`∨([a, b])`, `a & b` as `∧([a, b])`, `~a` as `~(a)`, `=a` as `=(a)`, and an operator
as `*([a, b], op)`. `∨([])` is `none`, the empty type; `∧([])` is `~none`,
everything.

## 3. Aliases

`int`, `float`, `char`, `string`, `bool`, `u8`… are not types: they are names, bound
in a prelude like any other binding (§5.2).

```text
int     -> ..0..                  every integer
float   -> ..0.0..                every real
char    -> ''..                   every character
string  -> ''.. * 0..             every string
bool    -> false | true
u8      -> 0..255        i8 -> −128..127        u16 -> 0..65535       …
```

## 4. The laws

The kernel computes a normal form by orienting these laws. Two equal constant types
have the same normal form.

### 4.1 `| & ~`: a Boolean algebra

```text
a | (b | c) = (a | b) | c        a | b = b | a        a | a = a        & likewise
a & (b | c) = (a & b) | (a & c)  a | (b & c) = (a | b) & (a | c)
a | (a & b) = a                  a & (a | b) = a
a | none = a                     a & ~none = a
a & none = none                  a | ~none = ~none
~~a = a                          ~(a | b) = ~a & ~b                 ~(a & b) = ~a | ~b
a & ~a = none                    a | ~a = ~none
```

`~` is the absolute complement: `~5` contains `"a"` and `false`. "Every integer but
5" is written `int & ~5`. `~true` is not `false`: `bool & ~true` is `false`.

### 4.2 Two different primitives have nothing in common

```text
0 & 1       = none
'a' & 'b'   = none
1.0 & 1     = none        1.0 is a real, 1 an integer
5 & 5       = 5
?₁ & 5      stays: ?₁ may be 5
```

This is the only law that makes `&` compute on values. The rest follows by
distributivity:

```text
u8 & 300      = (0 | 1 | … | 255) & 300  = (0 & 300) | … | (255 & 300)  = none
0..10 & 5..20 = 5..10
```

When a type is empty, its value is `none`.

### 4.3 `..` and bounds

```text
0..3      = 0 | 1 | 2 | 3
3..0      = 0..3                      .. is commutative; its default is not (§5.5)
0..       = 0 | 1 | 2 | …             up to infinity
0.0..     every real ≥ 0.0
''..      every character             '' as a bound: from the smallest
'a'..'z'  every character from 'a' to 'z'
..        every primitive
>=t = t..        <=t = ..t        >t = t.. & ~t        <t = ..t & ~t
```

A bound keeps the family of its primitive: `>5` and `0..` range over integers only,
`>5.0` and `0.0..` over reals only.

Between strings, `..` is about positions:

```text
"jwt"..       = "jwt" + string        starts with "jwt"
.."lel"       = string + "lel"        ends with "lel"
"jwt".."lel"  = ("jwt" + string) & (string + "lel")
```

`..` does not apply across two families (`'a'..3`), nor to a scope.

### 4.4 `=`

```text
=p = p             p a primitive: a primitive is its own singleton
=t                 admits t only: x in =t when x and t are equal (§4.7)
```

`=u8` is not `u8`: `u8` admits 0 to 255, `=u8` admits only u8.

### 4.5 Operators

An operator applies only to types proven to be in a family compatible with it.
Otherwise it is illegal. This proof is the same as the check (§7): `a + b` on
integers requires `a in int` and `b in int` to be true. Since an operator
distributes over `|`, a set is in a family when each of its elements is.

```text
int × int → int              +  -  *  [&]  [|]  ^  <<  >>
int × (int & ~0) → int       /  %        the divisor is not 0
int → int                    -  [~]
float × float → float        +  -  *
float × (float & ~0.0) → float   /
float → float                -
string × string → string     +           concatenation; a character is a string
string × int → string        *           repetition, the count ≥ 0 (§4.6)
bool × bool → bool           [&]  [|]  ^
bool → bool                  [~]
int × int → bool             <  <=  >  >=        likewise float × float, char × char
any × any → bool             in
```

```text
1.0 + 1.5      = 2.5
1 + 1.5        illegal: 1 is an integer, 1.5 a real
0 < "a"        illegal
?₁::u8 + 1     legal: ?₁::u8 in int
10 / ?₁::u8    illegal: ?₁ may be 0
```

`[~]` is the bitwise not: `[~]true = false`. It is not `~`. Equality is written
`=t`, difference `~t`: `a = b` is `a in =b`. There is no `==` and no `!=`.

Every operator except `in` distributes over `|`:

```text
(a | b) op c = (a op c) | (b op c)        c op (a | b) = (c op a) | (c op b)
none op c    = none
```

On known primitives, an operator gives its result:

```text
2 + 3 = 5        u8 + 1 = 1..256        u8 < 300 = true        2 > 2 = false
```

`u8 * u8` is the `|` of the products of its elements: it is not one range, and
stays written as it is. Its least and greatest elements are results at the bounds
of its operands, by the order of the integers (`a <= a'` and `b >= 0` give
`a * b <= a' * b`; likewise for `+ - /`):

```text
u8 * u8 in u16 = true          its elements are from 0 * 0 to 255 * 255
u8 * u8 in u8  = false         255 * 255 is one of them
```

On terms without `| & ~`, each family brings its laws:

```text
integers   + and * associative and commutative, * distributes over +, 0 and 1 neutral,
           -a is the opposite of a, (k * a) / k = a for k ≠ 0
           ?₁ - ?₁ = 0        ?₁ + ?₁ = 2 * ?₁
reals      a field: the same laws, and (a / b) * b = a for b ≠ 0
booleans   [~] [&] [|] ^: a Boolean algebra, [~][~]a = a
           b in true = b        b in false = [~]b
```

A comparison with one primitive is `in` of its bound (§4.3):

```text
x < c = x in <c        x <= c = x in <=c        and likewise > >=
```

What no law reduces stays as it is: `~5 + 1`, `?₁ in u8`.

### 4.6 Strings

A string is composed of characters. A character is a string of length 1.

```text
"jwt" = 'j' + 'w' + 't'
+ associative, "" neutral
t * 0 = ""
t * n = t + t * (n - 1)              n ≥ 1
t * (m | n) = (t * m) | (t * n)      the count: an integer ≥ 0 or a range ≥ 0
```

```text
'a'..'z' * 3        three characters, each from 'a' to 'z'
'a'..'z' * 1..      one or more
"ab" * 3            = "ababab"
Email -> emailChar * 1.. + '@' + emailChar * 1.. + '.' + alpha * 2..
```

### 4.7 `in`

`x in c` is true when x is an element of c. It takes both arguments whole: it does
not distribute over `|`.

```text
x in (a | b)  = (x in a) [|] (x in b)         x ≠ none
x in (a & b)  = (x in a) [&] (x in b)         x ≠ none
x in ~a       = [~](x in a)                   x ≠ none
x in =t       = true   when x and t are equal by these laws
              = false  when x and t have no ? and different normal forms
x in p        = x in =p                       p a primitive
none in t     = false                         t ≠ none
(t::L) in L   = true
```

`none` is the absence of type, and it is a type: its only element is itself.

```text
5 in u8       = true
u8 in u8      = false        u8 is not one of its elements
u8 in =u8     = true
none in none  = true
none in u8    = false
5 in none     = false
```

### 4.8 Effects

`!?` is an effect. What it does and where it comes from are not written: it is
there, and no law copies, replaces, erases or reorders it.

What it gives back is written like the layout of an unknown: `!?::L` gives back a
value in L; without `::`, in the layout of its color (§5.2). It is an unknown, or
not: `!?::none` gives nothing back, since `?ₖ::p = p` (§7).

An effect wraps the computation that follows it. `εₖ(x, t)` is the effect εₖ, x
what it gives back, bound in t; `εₖ(t)` when it gives nothing back. Written alone,
`!?::L` is `εₖ(x::L, x)`:

```text
u8:r -> !?          r = ε₁(x::u8, x)
w -> !?::none       w = ε₂(none)
```

A pure computation, one that holds no effect, crosses an effect, both ways; what
names x stays in it. A term that computes on an effect is that effect, wrapping the
term, and the effects of its parts are in the order they are written:

```text
εₖ(x, t) op c         = εₖ(x, t op c)               c pure
c op εₖ(x, t)         = εₖ(x, c op t)
εₖ(x, a) op εⱼ(y, b)  = εₖ(x, εⱼ(y, a op b))        the effects in the order written
εₖ(x, t) ? {…}        = εₖ(x, t ? {…})              likewise | & ~ = .. in, and the
                                                     target of .x ! {…}
```

The laws of §4 apply to what the effects wrap, never to an effect:

```text
εₖ(x, t)         ≠ t                        even when t does not name x
εₖ(x, εⱼ(y, t))  ≠ εⱼ(y, εₖ(x, t))
εₖ(x, x * 0)     = εₖ(x, 0)                 what it gives back is pure
```

A scope holds the effects of its bindings until it is collapsed. The type of a
production is what it gives, with the effects of the bindings above it, in the order
they are written, even those it does not name; another production is not run, and
what is written below it is not reached, like code after a return. Without
production, the default one gives none, with the effects of the bindings: its type is
not none. A pure binding crosses them:

```text
{w -> !?::none  -> 5}!                    = ε₁(5)
{w -> !?::none}!                          = ε₁(none)
{-> 5  w -> !?::none}!                    = 5
{u8:r -> !?  b -> r + 1  w -> !?::none  a -> 2 * 3  -> a + b}!
                                          = ε₁(x::u8, ε₂(x + 7))
{w -> !?::none  -> 5}{w -> 0}             invalid: a carve does not replace an effect
```

A name reads what its binding gives back, never its act: the act is the run's, and
each run gives back its own answer. Two collapses are two runs:

```text
g -> {u8:r -> !?  -> r}
{a -> g!  -> a - a}!       = ε₁(x::u8, 0)                  one run, named twice
g! - g!                    = ε₁(x::u8, ε₁(y::u8, x - y))   two runs
```

A recursive call of an equation that acts is an act. The equation acts when its
production, or a binding above it, acts besides its calls: each call runs it. What
the call gives back is bound in what follows it, and nothing crosses it but the pure;
the equation has no closed form, it stays (§5.6). An equation that does not act is
unchanged:

```text
loop -> {u8:n -> ??  -> n ? {0 -> 0  -> loop{n -> n - 1}! + !?::u8}}
loop{n -> m}!    = m ? {0 -> 0  -> ε<loop{n -> m - 1}!>(x, ε₁(y::u8, x + y))}
loop{n -> 3}! - loop{n -> 3}!   = ε<loop{n -> 3}!>(x, ε<loop{n -> 3}!>(y, x - y))
{u8:r -> !?  -> sum{n -> r}!}!   = ε₁(x::u8, x * (x + 1) / 2)
```

An effect in a branch is in that branch: it happens only when the branch is taken.

```text
n ? {0 -> !?::none  -> 5}       ε₁ happens when n is 0
```

## 5. Scopes

### 5.1 A scope is a new type

`{b…}` is an ordered sequence of bindings. Each scope creates a new type:

```text
0 ≠ {0}
```

Composition by scope is orthogonal to `|`. `{0 | 1}` is a scope whose binding is
the set `0 | 1` (a value is a set); `{0} | {1}` is one of two scopes. No law moves
`|` through `{…}`.

### 5.2 A scope is a system of equations

Each binding states an equation: its name denotes the type of its value. A name
denotes the last visible occurrence. Every mention of a name denotes the same type:
this is how an unknown comes back.

```text
a -> ??::u8            a = ?₁::u8
c -> a + 3             c = ?₁::u8 + 3
d -> a - a             d = 0
u8:n -> ??             n = ?₂::u8          ?? takes the layout of its color
```

### 5.3 Scope operations

```text
{… x -> v …}.x       = v              the last occurrence; x#n: the n-th
{… -> p …}!          = p              the first production, with the effects above it (§4.8)
{no production}!     = none             with the effects of its bindings (§4.8)
{1 ...{2 3} 4}       = {1 2 3 4}      expansion places the bindings as they are
s{x -> w}            = s where the first occurrence of x is w
```

A carve replaces an equation. Everything that names x follows, since its equation
mentions x:

```text
box -> {x -> 1  y -> x + 1}
box{x -> 10}.y       = 10 + 1 = 11
```

A carve creates no binding. An unnamed argument targets, in order, the bindings
that are neither productions nor holes.

Two scopes are equal when their bindings are, in order: the same names, the same
kinds, equal values.

### 5.4 A scope as a color

A scope with productions admits what they produce:

```text
{-> false  -> true}  admits false and true
{-> t}               admits t only: it is =t
```

A scope without production is a shape. It admits the scopes of the same structure
(same names, same kinds, same order) whose every binding is admitted by the color of
its own. Two different structures have nothing in common. Shapes of one structure
are products, and their `|` is written in one form: the first place cut into
blocks, the values the same shapes admit; the rest of each block in that form; the
blocks with the same rest joined, as (A×X) ∪ (B×X) = (A∪B)×X. `...C:` admits a run of
bindings that, taken as a scope, C admits; `...` alone admits any run
(specs/language/05):

```text
{1 2} in {u8: u8:}               = true
{1 2} in {u8:}                   = false         different structures
{u8:} & {u8: u8:}                = none
{u8: string:} | {i8: string:}    = {(-128..255): string:}
{u8: string:} | {i8: bool:}      = {(-128..-1): bool:} | {(0..127): (string | bool):}
                                   | {(128..255): string:}
Pair -> {u8: u8:}
{1 2 "x"} in {...Pair: string:}  = true
```

A produced shape admits through its colors, another produced value admits only
itself (specs/language/07): `{-> {-> u8}}` admits the scope `{-> u8}`, not `u8`.

The color of a binding flows down into its value (specs/language/05): in the value
of a binding colored by a shape, a binding without a color has the color of its
place in the shape. A carve of that value is checked against it:

```text
{string:}:a -> {""}
a{0}                        0 in string = false
```

A binding without a color imposes the structural constraints of its uses. Used with
`*`, it must admit `*`; if one of its properties is read, that property must exist
and admit the use made of it. Without a use, it imposes only its presence.

```text
{n -> 0  -> n * 2}             n admits * 2: an integer
{p -> {y -> 1}  -> p.y + 1}    p has a property y that admits + 1: an integer
```

### 5.5 Defaults

A binding without a value has the default of its color (specs/language/01):

```text
a set          its distinguished element: 0 when it has it, "" for strings, false for
               booleans; otherwise its first element, as written: the bound written
               first of a range (2..1 gives 2, 1..2 gives 1), the first term of a |
a scope        with productions, its first production; a shape, itself: complete
               with the defaults of its bindings
C:             in a value, an anonymous binding colored by C: the default of C
```

### 5.6 Recursion

A scope names itself only in its productions. Its type is then an equation that
mentions it. The first production is the base case, and it is not recursive: a
base case whose value places itself again is an infinite recursion — in a run of
its shape, or by a call outside any branch of a pattern, read on the equation as
written (under its defaults, a pattern on a known value is gone, not its guard). The equation
is never unfolded: asked again from its own production, the scope stays a carve
and a collapse, applied to types. It is solved — Arden, a closed form — or it
stays. A scope asked whether it is in an equation that is not solved is asked of
its productions (§5.4) when they are guarded. A carve of a solved equation substitutes its arguments into the solution:
`sum{n -> 5}!` is `sum!` with `n` = 5.

Arden, when the name is at the edge of the sequence:

```text
Array -> {-> {}  -> {T: ...Array:}}
X = {} | {T: ...X}      ⟹    X = {0..*T:}       the run of 0 or more T:
```

It is the same law as for strings: `X = A + X | B` gives `X = A * 0.. + B` when `""`
is not in A. A run is in `A * n` when it is cut into n pieces, each in A: the law of
`in` on a concatenation, over the lengths of the pieces A admits.

```text
X = {} | {u8: ...X} | {i8: string: ...X}   ⟹   X = {...(({u8:} | {i8: string:}) * 0..):}
{1 (-2) "x" 3} in X = {1} + {-2 "x"} + {3}, each in {u8:} | {i8: string:}   = true
```

Guarded, when in each production a run that names the scope comes with a binding:
each question is then on a run strictly shorter than the scope asked, and the
equation itself is not unfolded. Otherwise the equation stays.

```text
List -> {T -> {}  -> {}  -> {T: ...List{T}: T:}}
{10 10} in List{u8} = {10 10} in {}  [|]  {10 10} in {u8: ...List{u8}: u8:}
                    = 10 in u8  [&]  {} in List{u8}  [&]  10 in u8       = true
{10 10 10} in List{u8}                                                    = false
```

The closed form, when the name is called on an integer:

```text
sum -> {u8:n -> ??  -> n ? {0 -> 0  -> n + sum{n -> n - 1}!}}
sum{n -> m}! = m ? {0 -> 0  -> m + sum{n -> m - 1}!}     ⟹    sum{n -> m}! = m * (m + 1) / 2
```

In general, when `f{n -> m}! = m ? {b -> c  -> g(m) + f{n -> m - 1}!}`, then
`f{n -> m}! = c + g(b + 1) + … + g(m)`, a polynomial in m when g is one.

`sum{n -> m - 1}!` is not an extra notation: it is carving and collapse, applied to
types.

A carve of an equation that is not solved, collapsed where it is written, stays a
call; its production is asked, and typed for the values the carve gives (§7). A
recursive call whose base cases are scopes is a scope: `...` places it.

### 5.7 Holes

`x <- v` is a hole: a binding the use site fills. Until it is filled, it holds v,
like any binding. A carve fills a hole with `<-` and a field with `->`; an unnamed
argument never lands in a hole.

```text
identity -> {T <- none  T:value -> none  -> value}
identity{T <- u8  value -> 5}!     = 5
identity{T -> u8}                  invalid: T is a hole
identity{value <- 5}               invalid: value is a field
```

A hole the carve does not fill is inferred: what the carve puts where the hole is
mentioned lands in it. The places are read on a copy of the scope where the hole is
an unknown `?h` (§5.3): in the color of each field the carve fills, or in the value
that field had, set beside what the carve puts there. At the place of a value, what
lands is a sent value; at the place of a color, a required type. A fill `x <- t` is a
required type too.

```text
identity{value -> 5}           T:value beside 5: 5 is sent to T                 T = 5
data -> {u8:x -> 0}
pair -> {u8:e <- 2  data{e}:first  data{e}:second  -> e}
pair{data{6} data{6}}          data{?h} beside data{6}, twice: 6 is sent to e   e = 6
Array{T}:source -> {2 3}       Array{?h}: each element is at a place ?h: 2 and 3 are sent
func -> {e -> T:  -> E:}       beside {u8:e, -> e + 1}: u8 is at the place T:, required
```

The hole takes the required type: every required type is the same, and every sent
value is in it. Without one, it takes the sent value that holds all the others. It
never takes their union. Otherwise the carve is invalid. Then, as for any binding,
the hole's color applies.

```text
pair{data{6} data{3}}            invalid: neither 6 nor 3 holds the other
pair{e <- 4  data{6} data{6}}    invalid: 6 is not in 4
```

## 6. Patterns

A pattern is a type of the algebra, like `|` and `~`. In `t ? B`, B is a scope of
branches, and each branch is a scope whose production is written in its cover. Like
`in`, a pattern takes its target whole.

```text
t ? {c -> p  …} = p              when t in c = true
t ? {c -> p  …} = t ? {…}        when t in c = false
t ? {-> p  …}   = p              the branch without a cover admits everything
```

On an unknown target, `t in c` does not reduce, and the pattern stays an equation.
The link with the target is kept, since it is the same `?`:

```text
a -> ??::u8
r -> a ? {<10 -> a + 3  -> 10}       r = ?₁::u8 ? {<10 -> ?₁::u8 + 3  -> 10}
r - a                                 = (?₁::u8 ? {…}) - ?₁::u8
```

For each value of `?₁`, the laws apply: this is how the check decides (§7). A target
that no branch admits makes the pattern non-exhaustive.

A pattern gives one of its products, so `in` enters each branch, and a pattern
whose branches all give the same product is that product:

```text
x in (t ? {c -> p  …})   = t ? {c -> x in p  …}
(t ? {c -> p  …}) in C   = t ? {c -> p in C  …}
t ? {c -> p  -> p}       = p
```

What a branch types holds for the values of the target that reach it. Its checks
are guarded by the branch: with `reach` the target in its cover and in none of the
covers above, a check `r` inside it is `[~]reach [|] r`. A branch that no value
reaches is not typed.

```text
sum -> {u8:n -> ??  -> n ? {0 -> 0  -> n + sum{n -> n - 1}!}}
          the carve n -> n - 1 is checked for n in 1..255: (n in 0) [|] (n - 1 in u8)
```

## 7. The check

```text
C:x -> V    ⟺    V in C = true
```

| written | equation | |
|---|---|---|
| `u8:a -> 5` | `5 in u8 = true` | ✓ |
| `u8:a -> u8` | `u8 in u8 = false` | ✗ |
| `=u8:a -> u8` | `u8 in =u8 = true` | ✓ |
| `bool:x -> ~false` | `~false in bool = false` | ✗ |
| `{u8: u8:}:a -> {1 2}` | `{1 2} in {u8: u8:} = true` | ✓ |
| `none:l -> none` | `none in none = true` | ✓ |
| `u8:o -> none` | `none in u8 = false` | ✗ |

With `?`, `V in C` is an equation in these unknowns. Each `?ₖ::L` ranges over the
values of L. The check simplifies it by the laws; it solves nothing. Its result is
a verdict, not a type:

- **proven** when the equation simplifies to `true`;
- **refuted** when it simplifies to `false` for values of the `?`: a
  counterexample;
- **unproven** otherwise: it stays an equation, and the check says so.

An effect is not a value: the verdict is read on what the effects wrap (§4.8).

```text
u8:y -> {w -> !?::none  -> 5}!     ε₁(5 in u8) = ε₁(true)            ✓
u8:z -> !?                         ε₁(x::u8, x in u8) = ε₁(x, true)  ✓
```

The laws that simplify it are those of §4, and these:

```text
x in C = true      when the layout of x is in C:    L & ~C = none
x in C = false     when it is disjoint from C:      L & C = none
?ₖ::p  = p         p one primitive
```

The layout of `?ₖ::L` is L; the layout of a term over unknowns is the term with
each unknown replaced by its layout: an operator distributes over `|` (§4.5).
`?₁::u8 + 1` has the layout `1..256`.

A branch types its product for the values that reach it: where its reach says
`u in S`, the unknown `?ₖ::L` is rewritten `?ₖ::(L & S)` in the product (§6). An
atom `u in S` that stays is simplified on each side by the same law (Boole):

```text
eq = (u in S) ? {true -> eq  -> eq}
```

On each side the atom reduces, and eq with it.

```text
a -> ??::u8
u8:x -> a + 1                          refuted: false when ?₁ is 255
u8:y -> a ? {<255 -> a + 1  -> 0}      a is ?₁::(0..254) in the branch: 1..255  ✓
a ? {=3 -> a + 252  -> a}              = ?₁ ? {3 -> 255  -> ?₁}
```

What is checked, and where:

- every binding of a scope that has a color;
- a definition along its base case: its first production. The other productions
  are typed when they are asked: a collapse, a default, a color that reads them, a
  branch that fires;
- a carve where it is written, in what it changed: the rest was checked in its
  source;
- inside a branch, under the condition that reaches it (§6).

```text
a -> ??::u8
u8:r -> a ? {<10 -> a + 3  -> 10}     ✓    ?₁ < 10: 3..12;  otherwise: 10
```

## 8. Decisions

Where another document says otherwise, this one wins. In particular:

- `~` is absolute: `~5` holds every value but 5, of every family (§4.1).
- Operators distribute over `|`: there is no interval arithmetic (§4.5).
- `''..` is every character, and `string = ''.. * 0..`. A character is a string of
  length 1 (§3, §4.6).
- A pattern is a type of the algebra, and the domain of an unknown is in its type,
  `?₁::u8`: there is no type of cases beside it, and no context of facts (§6, §7).
- The checks of a branch are guarded by the condition that reaches it (§6).
- A binding without a color imposes the constraints of its uses (§5.4).
- `a = b` is `a in =b`: there is no `==` and no `!=` (§4.5).
- No law copies, replaces, erases or reorders an effect; a pure computation crosses
  it (§4.8).
