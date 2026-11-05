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
??                         the unknown
!?                         an effect
```

Each `??` written is a distinct unknown, indexed `?₁`, `?₂`. The same unknown comes
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
    | >- t                       an emission, answered by a handler (§4.9)
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
f16  f32  f64                     the reals each format holds (§4.10)
char    -> ''..                   every character
string  -> ''.. * 0..             every string
bool    -> false | true
u8      -> 0..255        i8 -> −128..127        u16 -> 0..65535       …
u64     -> 0..2⁶⁴-1      i64 -> -2⁶³..2⁶³-1      usize = u64            isize = i64
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

A value over unknowns meets a set by `in`: `t & S` is t when `t in S` is true, none
when it is false, and otherwise stays, t where it is in S (§6). A pattern gives one
of its products: `(t ? {c -> p …}) & S = t ? {c -> p & S …}`.

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
int × (int & 0..) → int      **          the power: the count is not negative
int → int                    -  [~]
float × float → float        +  -  *
float × (float & ~0.0) → float   /
float × (int & 0..) → float  **
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

`**` binds tighter than `*` and than a prefix `-`, and to the right:
`-2 ** 2 = -(2 ** 2)`, `2 ** 3 ** 2 = 2 ** 9`. Its laws:

```text
x ** 0 = 1     x ** 1 = x     1 ** n = 1     0 ** n = 0, n ≥ 1
(x ** a) ** b = x ** (a * b)
(c * x * y) ** e = c ** e * x ** e * y ** e        e an integer
x ** n ≥ 1 when x ≥ 1: a divisor
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
           -a is the opposite of a, (k * a) / k = a for k ≠ 0: polynomials over
           atoms — an unknown, or a term the ring does not read, a pattern, a power
           ?₁ - ?₁ = 0        ?₁ + ?₁ = 2 * ?₁        1 * p = p        p - p = 0
reals      a field: the same laws, and (a / b) * b = a for b ≠ 0
booleans   [~] [&] [|] ^: a Boolean algebra, [~][~]a = a
           b in true = b        b in false = [~]b
```

A comparison with one primitive is `in` of its bound (§4.3):

```text
x < c = x in <c        x <= c = x in <=c        and likewise > >=
```

An integer `/` rounds toward 0, and `%` has the sign of what it divides:
`a = (a / b) * b + a % b`.

```text
7 / 2 = 3        -7 / 2 = -3        -7 % 2 = -1        7 % -2 = 1
```

What no law reduces stays as it is: `?₁ in u8`. An operator whose operands are not
proven in a family is illegal, not left as it is: `~5 + 1` is illegal, since `~5`
holds values of every family.

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
there, and no law copies, replaces, erases or reorders it. Normalization keeps
exactly the effects that run, in their order, on every path of execution, whether or
not what they give back is used.

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

The program is the type of the file's production, its entry point: what it gives,
with the effects it holds. The file is not collapsed: a binding of the file runs
only where the production holds it, and what it does not hold is not code. A file
without production is a program without main: it gives none, and runs nothing.

```text
main -> {w -> !?::none}
main!                                     the program: none, nothing runs
-> main!                                  the program: ε₁(none)
```

A name reads what its binding gives back, never its effect: the effect is the
run's, and each run gives back its own answer. Two collapses are two runs:

```text
g -> {u8:r -> !?  -> r}
{a -> g!  -> a - a}!       = ε₁(x::u8, 0)                  one run, named twice
g! - g!                    = ε₁(x::u8, ε₁(y::u8, x - y))   two runs
```

A recursive call of an equation with effects is an effect. The equation has effects
when its production, or a binding above it, has some besides its calls: each call
runs it. What the call gives back is bound in what follows it, and nothing crosses
it but the pure. Solved, the equation is an iteration that runs the effects of each
step in the order the equation runs them (§5.6): an effect, whose answer is the
value of the iteration. Each call is a run. An equation without effects is
unchanged:

```text
loop -> {u8:n -> ??  -> n ? {0 -> 0  -> loop{n -> n - 1}! + !?::u8}}
loop{n -> m}!    = ε<⟳(i: m - 1 ↦ i - 1 until ..(-1); ε₁(y); x: 0 ↦ y + x; x)>(z, z)
loop{n -> 3}! - loop{n -> 3}!   = ε<⟳(…)>(x, ε<⟳(…)>(y, x - y))       two runs
{u8:r -> !?  -> sum{n -> r}!}!   = ε₁(x::u8, x * (x + 1) / 2)
```

A call takes its arguments as values: the effects that give them run before it. An
expansion is computed where it is written, and the bindings it places run in the
scope that places them:

```text
sum{n -> !?::u8}!              = ε₁(x::u8, x * (x + 1) / 2)
loop{n -> !?::u8}!             = ε₂(x::u8, ε<⟳(i: x - 1 ↦ i - 1 until ..(-1); …)>(y, y))
g -> {w -> !?::none  -> {k -> 1}}
{...g!, -> 1}!                 = ε₁(1)
```

An effect in a branch is in that branch: it happens only when the branch is taken.
A cover is computed when its branch is tested, after the target, on the paths that
come to it: a pattern is its first branch, then the others,

```text
n ? {0 -> !?::none  -> 5}                ε₁ happens when n is 0
t ? {c₀ -> p₀  cᵢ -> pᵢ  …}             = t ? {c₀ -> p₀  -> t ? {cᵢ -> pᵢ  …}}
n ? {0 -> 1  (!?::u8) -> 2  -> 3}        = n ? {0 -> 1  -> ε₁(x::u8, n ? {x -> 2  -> 3})}
```

`<lib>{…}` is a boundary: a scope whose symbols — the scopes written in it — are run
outside, in lib. The run of a symbol is the call of the symbol, with what the run
carved: the effect of its production `!?::L` is that call, and what it gives back is
in L. A symbol is a scope like any other: carving it calls nothing, and the effects
of its fields run before the call, which takes their answers as values.

```text
libm -> <libm.so.6>{
  sqrt -> {f64:x, -> !?::f64}
}
libm.sqrt                          a scope: nothing happens
libm.sqrt{x -> 2.0}! * 2.0         = ε<sqrt{x -> 2.0}!>(y::f64, round64(y * 2.0))
libm.sqrt{x -> !?::f64}!           = ε₁(x::f64, ε<sqrt{x -> x}!>(y::f64, y))
```

A symbol whose production has no effect is pure: `??::L` is a value in L that this
program does not compute, not an effect. Its run is a term like any other: what
reads nothing of it is erased, and it is not ordered with the effects.

```text
libm -> <libm.so.6>{
  cbrt -> {f64:x, -> ??::f64}
}
{r -> libm.cbrt{x -> 8.0}!  -> 1}!     = 1                 nothing reads r
```

### 4.9 Handlers

A handler is context: who answers an event where a scope is collapsed. It is found
when the program is typed, never at run time: nothing is passed, and an emission
costs what its handler costs, a carve and a collapse. A handler is not an effect: it
has effects only if its scope has some (§4.8).

An event is a scope; its bindings are the shape of what it carries. `E -< e {…}` is a
binding: the handler of E, a scope in which e is what is sent. `r >- E{…}` is an
emission, r what it answers. `⟨E{…}⟩(x, t)` is the emission, x its answer, bound in
t; written alone, `>- E{…}` is `⟨E{…}⟩(x, x)`.

An event is its handle: the binding its name is resolved to, like any name. A
handler answers an emission only when both handles are exactly the same binding; a
copy of the scope that writes it (§5.3) keeps it. The same shape is not the same
event, and what is sent carries no identity: it only has to fit the shape.

```text
Log -> {string:message}
Audit -> {string:message}            the same shape, another event
Log -< e { -> 1 }
>- Audit{message -> "x"}             not answered by the handler of Log
```

An emission is answered where the scope that holds it is collapsed. When `s!` is
written in a scope that has a handler h of E, each emission of E in s is answered by
h: it is the run of h with e carved to what is sent, and x is what that run gives
back. Otherwise it stays in what `s!` gives, and is answered where the scope that
holds `s!` is collapsed, and so on up. Until it is answered, an emission stays where
it is written, between the effects around it: its handler may have effects, so no
law copies, erases or reorders it.

```text
⟨E{a}⟩(x, t)   answered by E -< e {…}   =   {x -> {…}{e -> E{a}}!  -> t}!
```

The program is collapsed by nothing: an emission that comes up to it is answered by
its default, the handler of E visible where the emission is written. An emission
without one is invalid.

A scope answers the emissions of the scopes it collapses, not its own: those written
in it, or in a scope written in it — the run of one of its handlers too —, in any
copy of these. Its own emissions come up to where it is collapsed; its handlers are
their defaults. A recursive call is a copy: what it emits is the scope's own, and
comes up with it, each step answered where the first call is collapsed.

```text
lib -> {
  Log -> {string:message}
  Log -< e { -> "default" }
  r >- Log{message -> "x"}
  -> r
}
main -> {
  lib.Log -< e { -> "main" }
  -> lib!
}
lib!               = "default"          answered by its default
main!              = "main"             answered where lib! is collapsed
{-> lib!}!         = "default"          nothing between: it comes up to the program
```

There are as many events as are written, and a scope has as many handlers as it
writes, one for each event. Each emission comes up on its own, to the first scope
that answers its event:

```text
work -> {
  Log -> {string:message}   Log -< e { -> 0 }
  Alloc -> {u64:size}       Alloc -< e { -> 0 }
  a >- Log{message -> "start"}
  p >- Alloc{size -> 16}
  -> p
}
app -> {
  work.Log -< e { -> 1 }
  -> {work.Alloc -< e { -> e.size * 2 }  -> work!}!
}
app!               = 32                 Alloc answered inside, Log where app is
```

A recursive call whose equation emits is answered where it is collapsed, like an
emission: the scopes it is collapsed in answer what each step emits. Solved, the
answers are in its solution; a call that stays is the code of its equation in that
context, one for each context, nothing passed.

```text
count -> {
  Tick -> {}
  Tick -< e { -> 0 }
  u8:n -> ??
  -> n ? {0 -> 0  -> {u8:t >- Tick{}  -> t}! + count{n -> n - 1}!}
}
count{n -> 3}!                                 = 0
{count.Tick -< e { -> 1 }  -> count{n -> 3}!}!   = 3     each step answered by 1
```

A carve replaces a handler like any binding: the emissions it answered are answered
by the new one. A scope is closed: a carve replaces a handler, it never adds one. A
recursive call is written as it is: the carve of a handler is that of the call
carved, not of the calls its production writes, unless written there (`List{T}`,
§5.6). No carve replaces an emission (§4.8). The answer is checked where it is
given, like a carve (§7): the bindings that read x are checked with what the
handler gives back.

```text
lib -> {
  Log -> {string:message}
  Log -< e { -> 1 }
  u16:r >- Log{message -> "x"}
  -> r + 1
}
lib!                           = 2
lib{Log -< e { -> 300 }}!      = 301
lib{Log -< e { -> "a" }}!      invalid: "a" is not in u16
```

### 4.10 Formats

A real written is exact: `0.1 + 0.2 = 0.3`, `1.0 / 3.0` stays that quotient. A
floating-point format is a set of reals, a type like `u8`: `f16`, `f32`, `f64` hold
the reals of IEEE 754 binary16, binary32, binary64 — `m * 2 ** e`, m and e within
the bounds of the format, its subnormals included. ±∞ and NaN are not reals: no
format holds them.

```text
f16 ⊂ f32 ⊂ f64 ⊂ float
0.5 in f32 = true          0.1 in f32 = false          0.1 is not a dyadic
```

`round_w(t)` is what a machine of w bits holds of the real t: the value of the
format nearest t, the even one on a tie. A real in a color of a format, and what an
operator computes on values of formats, is that value:

```text
f32:x -> 0.1                     x = 0.100000001490116119384765625
f16:y -> 70000.0                 invalid: beyond the greatest f16
f32:a -> ??   f64:b -> ??
a + b                            = round64(?₁ + ?₂)     the widest format of its operands
a + 0.5                          = round32(?₁ + 0.5)    a known real is rounded first
```

Its laws:

```text
round(r)               = the nearest value, exactly       r a known real
round(t)               = t                                t a value of the format
round_f(round_g(t))    = round_g(t)                       f holds every value of g
round(εₖ(x, t))        = εₖ(x, round(t))
round(t ? {c -> p …})  = t ? {c -> round(p) …}
round of a set         = the values of the format between its rounded least and
                         greatest; ~none when the set has no bound, or one beyond
                         the greatest value: ±∞ is not a real, so nothing is proven
                         of it
```

```text
f32:a -> ??
f16:x -> a                       invalid: a may be beyond the greatest f16
f32:y -> a * a                   invalid: a * a may be beyond the greatest f32
f64:z -> a                       = ?₁        f64 holds every f32
```

The laws of a field (§4.5) hold on the exact reals, not across a rounding:
`round32(?₁ + ?₂) - ?₂` is not `?₁`.

**What the code computes.** The code may compute a value otherwise than the machine
would, step by step: it is exact up to the precision its color states. A value of
color C, computed from exact terms, is within the rounding of C of the exact value,
`|computed − exact| ≤ ε_C`, ε_C half the gap of C at that value — as if computed
exactly and rounded once. The code may change representation by a homomorphism φ —
reals the kernel bounds into integers at a scale 2^k, and back — when the error φ
adds, propagated by the laws of the operations, stays within ε_C. Steps that compose
— `x ↦ M·x + b` over a ring: the integers, the reals, the bits under `^` (GF(2)) —
run L at a time in the lanes of the machine: `x_{n+L} = M^L·x_n + b_L`, each lane
one of L interleaved orbits, recombined by the law of their monoid. A fold of N
steps that compose is also the fold of its blocks: its orbit cut into L runs of
B = ⌈N/L⌉ steps, run k starting at x_{k·B} = M^{k·B}·x₀ (the closed form of the
orbit, M^n by squares, or r(M) for r = tⁿ mod the characteristic polynomial of M
(Cayley–Hamilton)), each run in a lane by M itself; what the fold gathers along
the orbit is recombined by the law of its monoid, in the order of the runs.

Folds over one orbit are the fold of their pair (banana split): two loops of one
region whose counters start from one value, step by one δ and stop at one bound run
the same turns; where neither reads what the other gives, they are one loop carrying
the parameters of both and giving what each gives. Its effects are those of the one
that has some, in their order: two loops with effects are not one. Two parameters of
a loop that start from one value, and whose nexts are one computation where the two
are identified, are one (by induction on the turns).

```text
⟳(x ↦ f(x)) × ⟳(y ↦ h(y))  = ⟳((x, y) ↦ (f(x), h(y)))      one orbit, one bound
⟳(p ↦ f(p, q), q ↦ f(q, p)) = ⟳(p ↦ f(p, p))               p₀ = q₀
```

A reservation is cells no other shares; an address read from it is base + offset,
and of the offset the code knows its residue modulo m, m dividing the word
(ℤ → ℤ/m is a homomorphism of rings, kept by + − and a product by a constant;
joined where two computations meet, m the gcd of the moduli and of the difference of
the residues). What reads its cells: each load whose value is used, at its residue;
each function the address is given to, by what that function reads through it;
every cell where the address escapes — to a symbol, into memory, out of the
function. A store no reader reads is not done; an effect on memory only and a call
of a symbol given no address commute — what the symbol does it does to the world,
what the memory holds it holds:

```text
store(s, a + k, v) = s          no reader of a reads a cell of a + k (mod m)
M(F(s, x))         = F(M(s), x)  M on memory only, F a symbol given no address,
                                 M reading nothing F gives
```

A computation reached from several of the values a function gives is computed once:
a loop gives each of its values once, and the code reads them all from it where that
costs least. A computation runs on the paths that use it: one that some arms of a
match need is computed in each of them, not above the others, unless running it
where it is not needed costs less than a branch saves — never a call, which costs
its function. A computation equal to the machine's own, bit for bit, is a choice the
program states (open: a flag of exact machine arithmetic).

### 4.11 Sizes

A type carries its size: the least number of bits that tells its values apart,
⌈log₂ |T|⌉, |T| the count of the values it may take where it is. The size is given
by the type: it depends on what the type depends on — unknowns, lengths, the branch
that narrows them —, wherever it is computed.

What is known at compile time takes 0 bits: only unknowns, and what depends on
them, take bits.

```text
5                        0          known
u8                       0          a set written as a value: known
?₁::u8                   8          256 values
?₁::u8 + 1               8          1..256: 256 values
?₁::u8 ? {<10 -> 1  -> 2}   1      1 or 2
?₁::(100..103)           2
?₁::(u8 | bool)          9          258 values
?₁::('a'..'z' * n)       ⌈n · log₂ 26⌉     depends on n
```

A scope takes what its bindings take, summed. A hole takes 0: it is filled when the
program is typed, and erased. A handler takes what it gives back. A production takes
0: it is always devirtualized, computed where the scope is collapsed.

The size is the minimum. The code may widen a value to compute on it — `1..256` in 9
bits of binary, a character in a byte —; its memory is then reserved for what that
encoding takes: the same dependencies, in the unit the encoding chooses.

### 4.12 Lifetimes

A type carries its lifetime, as it carries its size: the scope whose collapse frees
what it holds. What is known has none: it takes nothing (§4.11).

- A value held in the bindings of a scope lives until the collapse of that scope
  ends.
- A production is devirtualized: its value lives in the scope that collapses it.
- A reference — a bind `>>=` `=<<` to a resonant binding (specs/language/12) — keeps
  that binding alive as long as the scope that holds the reference.
- A value put in a resonant binding by `-<<` lives as long as that binding.

The lifetime of a value is the outermost of the scopes that hold it, directly or by
a reference: a carve, an emission, an effect that holds it extends it as far as it
is held. Nothing is written for it, and nothing is refused for it: the compiler
computes it.

### 4.13 Memory

There is no heap, no collector and no count of references. A value that takes bits
is placed where its lifetime ends: in the memory of the scope whose collapse frees
it, freed with it, all at once. Since the lifetime is known when the program is
typed, it is placed there when it is built, never moved.

Its size is known before it is built, as a term over what it depends on (§4.11):
its place is reserved whole. Only a resonant binding whose size changes with its
state (`{...value element}`) grows after it is built: it is placed last in a memory
of its own, where growing moves nothing. The compiler gives each one such a memory,
as registers are given: two that live at once never share one. So does a value
whose size is only known as it is built — a run or a tree its effects build, read
from an input: it grows while it is built, placed last in a memory of its own.

The memory of a scope is in its frame when the size the kernel gives is bounded and
small, in pages the system gives otherwise. Neither is a heap: nothing is freed
alone; the memory of a scope is freed at its end, all at once.

A value placed in another is laid out inside it, unless it grows after it is
placed: then it is in a memory of its own, and the value that holds it holds its
place. A value that stops growing before the next one is placed is laid out inline.

On each form of the algebra:

- **a pattern**: the branch is chosen before its product is built, so what is
  reserved is the size of the product of the branch taken, not of the largest;
- **a fold**: what a step builds and does not pass on is freed at the end of the
  step, its memory used again by the next one. A state that grows along the fold
  has its final size in closed form (§5.6): it is reserved whole before the first
  step, and does not grow;
- **an effect**: what it gives back lives where it is held; given back and read by
  nothing, it takes nothing;
- **a handler**: its run is a collapse where the emission is answered; what it gives
  back lives where the answer is held.

**Reuse.** No value is ever modified, but where a value is read for the last time
to build another that fits in its place, the new one is built in that place. Every
last read is known when the program is typed: an update `x ↦ f(x)`, a carve of a
scope nothing reads anymore, are made in place, with nothing counted at run time.

### 4.14 Mutation and reactivity

A resonant binding `T:x >>- E -> v` (specs/language/12) is a place: its value
changes, only through the handler of E, with `x -<< …`. Its handler is found when
the program is typed (§4.9): every write to it is known.

- **A write** `-<<` is made only in the run of the handler of E, which answers an
  emission `>- E{…}`.
- **A read** is the value of the place at that point, between the writes around it.
  Where the writes that reach a read are known, the read is their value, and the
  laws simplify it like any other: a resonant binding costs only where its value
  depends on what the program does at run time.
- **Its size** is that of the values it may take (§4.11), its lifetime that of the
  scope that declares it, as far as references hold it (§4.12). A write whose value
  fits in the place is made in it; one that grows it grows it at the end of its own
  memory (§4.13).

**What may be reordered.** The effects are opaque: how they act on one another is
not known, so no law reorders two effects (§4.8). How resonant bindings act on one
another is known: the reads and writes of each place, every handler found when the
program is typed. So:

- two reads or writes of resonant bindings are reordered when neither depends on
  the other — they touch different places, or both only read;
- a read or write of a resonant binding and an effect are reordered when neither
  depends on the other — the effect does not take the value read, the write does
  not take what the effect gives back;
- two effects are never reordered;
- what is pure crosses all of them.

A binding `x -> v` that reads places reads them where it is written: what reads x
reads them as they were there, whatever is written after. A reactive bind `>>=`
`=<<` follows what it reads:

- **A reference** — a bind that resolves to a resonant binding — is that binding's
  handle. Its type is the set of handles it may designate: known when the program
  is typed, it takes nothing, and reading through it is reading the place itself.
  It takes bits only where which place it designates depends on run time:
  ⌈log₂ n⌉ for n places.
- **A computed bind** — `counter.value >= 0` — is a term over the places it reads.
  Since every write to them is known, the compiler either computes it where it is
  read, taking nothing, or keeps its value and computes it again after each write
  that changes what it reads, taking its size: whichever costs less. There is no
  list of subscribers at run time.

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

A run is read by its places, with terms like any other — known when the run is:

```text
|x|                  the number of bindings of the run x
x.#k                 its binding k, from 0
x from k             the run of its bindings from k on

|{1 2 3}| = 3        {1 2 3}.#1 = 2        {1 2 3} from 1 = {2 3}
|{...x  r}| = |x| + 1                       x a run not known yet
x from 0 = x         (x from a) from b = x from (a + b)
(x from a).#b = x.#(a + b)                  |x from k| = |x| - k, k in 0..|x|
```

A field of one of several scopes is the field of those that have it:

```text
x.a, x one of s₁ | … | sₙ    the field a of those that have it, its values the union
                             of theirs; invalid for the values of x that reach one
                             without a
({id -> 1  dx -> 2} | {id -> 3  code -> 4}).id = 1 | 3
```

A run is carved by place: `x{#k -> v}` is the run x with its binding k carved to
v, k proven a place of x (k < |x|). It is a new value; made in place when x is
read for the last time (§4.13):

```text
|x{#k -> v}| = |x|        x{#k -> v}.#k = v        x{#k -> v}.#j = x.#j, j ≠ k
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
and a collapse, applied to types. It is solved — Arden, an iteration — or it
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

A fold, when the calls change the integer the name is called on, and that only —
or carry states besides it (below):

```text
f{n -> m}! = m ? {B -> c(m)  -> pre(m) · f{n -> s(m)}! · post(m)}
```

A run follows the orbit of m by s until B: the effects before the call run going
down, those after it coming back up — the solution, by Arden, of the equation of its
effects, `R(m) = pre(m) · R(s(m)) · post(m)`. Its value is v(m, y) after post, y
what the call gives back. `⟳(k: a ↦ s until B; ε…; x: e ↦ t, …; w)` is a fold: k = a
and each state its init; while k is not in B, the effects of a step, then the
states take their updates, all at once, and k = s; then w. `μ(i: t)` is the least
i ≥ 0 where t holds (Kleene's μ).

The orbit has a closed form when s moves by a constant, or halves: its i-th point
`kᵢ = sⁱ(m)` and its length `n = μ(i: kᵢ in B)`,

```text
s(k) = k + c           kᵢ = m + c·i                          n = m - b, or 0, when B = ..b or the point b
s(k) = α·k + c         kᵢ = α ** i * m + c * (α ** i - 1) / (α - 1)
s(k) = k / c, k ≥ 0    kᵢ = m / c ** i                       n = μ(i: m / c ** i in B)
s(k) = k >> c          kᵢ = m >> c·i
s(k) = k from c        kᵢ = m from c·i                       n = |m| / c, when B is the runs of fewer than c pieces
```

A run is the orbit of its positions: a recursion whose call takes the rest of the
run its pattern cuts — `xs ? {{T₁(h₁) … T_c(h_c) ...R:(t)} -> … f{xs -> t}! …  -> b}`
— is a fold on the position k of xs, from 0 by c until fewer than c pieces are
left, |xs| / c steps: hⱼ is `xs.#(k + j - 1)`, t is `xs from k + c`. The pieces a
cover cuts from a run not known yet are these terms.

A run a fold builds, c bindings a step from `{}` — `⟳(i: 0 ↦ i + 1 …; y: {} ↦ {...y
e₀ … e_{c-1}}, z: …; y)` — has c bindings for each step of the fold, and its binding
c·i + j is eⱼ at step i. A fold that reads it at its own step i, from 0 by 1, the
bindings c·i + j, carries the states z beside its own: the run is never built, and
takes nothing.

```text
total{xs -> build{n -> m}!}!   = ⟳(i: 0 ↦ i + 1 until m..; y: 0 ↦ y + e(z), z: z₀ ↦ s(z); y)
```

Then the equation itself is folded from the base case up, over the steps i from
n - 1 down to 0, after the effects before the call going down — unless post reads
what they give back. Calls further along the orbit, `f{n -> m - 2}!` …, are a
window of states, the values at the next points:

```text
f{n -> m}! = ⟳(i: 0 ↦ i + 1 until n..; pre(kᵢ); none) · ⟳(i: n - 1 ↦ i - 1 until ..(-1); post(kᵢ); x: c(kₙ) ↦ v(kᵢ, x); x)
```

Otherwise, when post has no effect and v is affine in y, `v = α·y + β`, the maps
compose into one, `(A, B) ∘ (α, β) = (A·α, B + A·β)`, and the fold goes down the
orbit, the effects before the call in its steps:

```text
f{n -> m}! = ⟳(k: m ↦ s(k) until B; pre(k); A: 1 ↦ A·α(k), B: 0 ↦ B + A·β(k); A·c(k) + B)
```

Modulo m > 0 constant, when v = (α·y + β) % m and c, α, β ≥ 0, the maps compose
modulo m: `A: 1 ↦ (A·α) % m, B: 0 ↦ (B + A·β) % m`, the value `(A·c + B) % m`.

Runs compose likewise: when v = {...P  ...y  ...Q}, y placed once as a run and P,
Q not reading it, `(A, B) ∘ (P, Q) = ({...A ...P}, {...Q ...B})`, and the fold goes
down the orbit: `A: {} ↦ {...A ...P(k)}, B: {} ↦ {...Q(k) ...B}`, the value
`{...A ...c(k) ...B}`.

```text
log{n -> m}! = m ? {0 -> {}  -> {e(m) ...log{n -> m - 1}!}}
             = ⟳(i: 0 ↦ i + 1 until m..; A: {} ↦ {...A  e(m - i)}; A)
```

**States carried by the call.** Besides the integer it moves along the orbit, a call
may carve other bindings of the scope: each is a state of the fold. Its init is what
the first carve gives it, its update what the call carves it to, all at once with k:

```text
f{n -> m  r -> a}! = m ? {B -> c(m, r)  -> pre · f{n -> s(m)  r -> u(m, r)}!}
f{n -> m  r -> a}! = ⟳(k: m ↦ s(k) until B; pre(k, r); r: a ↦ u(k, r); c(k, r))
```

Such a state follows the orbit going down: the fold goes down, v affine in y.

```text
count -> {u32:n -> ??  u64:r -> ??  -> n ? {0 -> r  -> count{n -> n - 1  r -> r ^ n}!}}
count{n -> 3  r -> 0}!   = ⟳(x: 0 ↦ x + 1 until 3..; y: 0 ↦ y ^ (3 - x); y)
```

**A recursion over what a fold builds** is the fold of the recursion:
`f{t -> ⟳(…; y: c ↦ u(y); y)}! = ⟳(…; w: f{t -> c}! ↦ f{t -> u(z)}!; w)`, where the
production of f at u(z) reads z only through f{t -> z}!, which is w; z is a state
after the first, of the shape of u, in the color of t. Nothing is built:

```text
check{t -> make{depth -> d}!}!   = 2 * 2 ** d - 1      make: y ↦ {l -> y  r -> y}
```

An unknown whose layout is a shape is in a scope one of whose productions has its
structure, place by place (§5.4): `?::{Node:l Node:r}` is in Node.

**Tupling.** A fold along a counter i over lo..hi known that reads calls of an
equation that differ by one field only, `f{x  p -> i}!`, f keeping p in its calls,
reads the bindings of one call: `f{x  p -> i}! = T{x}!.#(i - lo)`. T is f where each
product is the scope of its copies at p = lo … hi, each call of f in them, at p,
the binding of the same call of T: one recursion for the whole range. It applies
to what the other laws of a fold leave.

```text
⟳(p: 0..7; z ↦ (z + eval{e  p -> p}!) % m)   = ⟳(p: 0..7; z ↦ (z + ⊗eval{e}!.#p) % m)
```

What would keep the orbit, or what pre gives back, stays. The laws of a fold:

```text
x: e ↦ u(x), u reading x alone, u(e) = e     x is e
a state nothing reads                      is not folded
nothing left to fold, w not reading k      w
a state not reading what the effects give back, nor read by them: it crosses them
```

and, along a counter — i by one over lo..hi, n steps —, a state read by the value
only whose update is a first-order linear recurrence leaves the fold:

```text
x ↦ x + g(i)        x = x₀ + Σ(i: lo..hi, g(i))
x ↦ α(i)·x          x = x₀ · Π(i: lo..hi, α(i))
x ↦ r·x + g(i)      x = P(n) + (x₀ - P(0)) * r ** n     r ≠ 1 an integer, g a polynomial,
                                                       P(t + 1) = r·P(t) + g(t), by its coefficients
```

States whose updates are a linear map with integer coefficients, `x ↦ M·x + b`, are
each a C-finite sequence: by Cayley–Hamilton, each satisfies the recurrence of the
characteristic polynomial of M — b a state of its own, always 1. `C⟨c₁ … c_d |
x₀ … x_{d-1}⟩(s)` is the s-th term of the sequence `x_t = c₁·x_{t-1} + … +
c_d·x_{t-d}` from its first terms. With α a root of `x^d - c₁·x^{d-1} - … - c_d`,
`x_s = Σ_j x_j·[αˢ]_j`, the coordinates of αˢ in ℤ[α]: a power, computed in
O(log s). Its laws:

```text
s known                                    its value, by αˢ in ℤ[α]
d = 1                                      x₀ * c₁ ** s
d = 2, the roots of x² - c₁·x - c₂ integers, by the discriminant c₁² + 4·c₂:
  r₁ ≠ r₂                                  A * r₁ ** s + B * r₂ ** s
  r₁ = r₂ = r                              (A + B * s) * r ** s
                                           A, B from x₀ and x₁
```

`Σ(i: lo..hi, t)` is the sum of t for i from lo to hi, 0 over an empty range;
`Π(i: lo..hi, t)` their product, 1 over an empty range. Their laws:

```text
Σ(i: lo..hi, t), t a polynomial in i       G(hi) - G(lo - 1)     G(m) = t(0) + … + t(m), by the sums of powers
Σ(j: lo..hi, ⟳(…; x: 0 ↦ x + g; x))        ⟳(…; x: 0 ↦ x + Σ(j: lo..hi, g); x)     nothing else in the fold reads j
Σ(i: lo..hi, v ⊕ i), ⊕ in ^ [&] [|]       bit by bit: v ≥ 0 not reading i, N the count of i, C_b of those whose
                                                     bit b is 1; bit b gives 2ᵇ·(C_b + v_b·(N - 2·C_b)) for ^,
                                                     2ᵇ·v_b·C_b for [&], 2ᵇ·(C_b + v_b·(N - C_b)) for [|];
                                                     the bits with one factor K are one mask, K·(v [&] mask)
Σ(i: 0..7, v ^ i), v in 0..999             28 + 8 · (v [&] 1016)
Σ(j: lo..hi, f{x  p -> j}!)                F{x}!     f's products a term and calls that keep p: F is f, its
                                                     terms Σ(j: lo..hi, term), its calls F's, without p
Π(i: lo..hi, t), t not reading i           t ** n
Π(i: lo..hi, c·t), c the content of t      c ** n * Π(i: lo..hi, t)
Π(i: lo..hi, uᵃ·iᵖ)                        u ** (a·n) * Π(i: lo..hi, i) ** p
Π(i: lo..hi, ±i + b)                       Π(j: lo'..hi', j), over the integers it runs through, upward
Π(j: a..b, j), a ≤ 0 ≤ b                   0
```

The ring computes over atoms — a μ, a series, `r ** n` —; the whole stays one
polynomial over one divisor, whatever its parts are worth alone. On examples:

```text
sum -> {u8:n -> ??  -> n ? {0 -> 0  -> n + sum{n -> n - 1}!}}
sum{n -> m}!    = m * (m + 1) / 2
hanoi -> {u8:n -> ??  -> n ? {0 -> 0  -> 2 * hanoi{n -> n - 1}! + 1}}
hanoi{n -> m}!  = 2 ** m - 1
t -> {u8:n -> ??  -> n ? {0 -> 1  -> 3 * t{n -> n - 1}! + n}}
t{n -> m}!      = (7 * 3 ** m - 2 * m - 3) / 4
half -> {u8:n -> ??  -> n ? {0 -> 0  -> 1 + half{n -> n / 2}!}}
half{n -> m}!   = μ(i: m / 2 ** i in 0)                     the length of m in bits
g -> {u8:n -> ??  -> n ? {0 -> 1  -> 2 * g{n -> n / 2}! + 1}}
g{n -> m}!      = 2 * 2 ** μ(i: m / 2 ** i in 0) - 1
fact -> {u8:n -> ??  -> n ? {0 -> 1  -> n * fact{n -> n - 1}!}}
fact{n -> m}!   = Π(i: 1..m, i)
f -> {u8:n -> ??  -> n ? {0 -> 1  -> 2 * n * f{n -> n - 1}!}}
f{n -> m}!      = 2 ** m * Π(i: 1..m, i)
fib -> {u8:n -> ??  -> n ? {<2 -> n  -> fib{n -> n - 1}! + fib{n -> n - 2}!}}
fib{n -> m}!    = C⟨1 1 | 1 1⟩(m - 1), m ≥ 1                  in O(log m)
fib{n -> 90}!   = 2880067194370816120
t -> {u8:n -> ??  -> n ? {<2 -> n  -> 3 * t{n -> n - 1}! - 2 * t{n -> n - 2}!}}
t{n -> m}!      = 2 ** m - 1, m ≥ 1                         the roots 2 and 1
say -> {u8:n -> ??  -> n ? {0 -> 0  -> io.printf{…  n -> n}! + say{n -> n - 1}!}}
say{n -> m}!    = ε<⟳(i: 0 ↦ i + 1 until m..; ε<printf{…  n -> m - i}!>(y); x: 0 ↦ y + x; x)>(z, z)
count -> {u8:n -> ??  -> n ? {0 -> 0  -> {a -> count{n -> n - 1}!  -> a + io.printf{…  n -> n}!}!}}
count{n -> m}!  = ε<⟳(i: m - 1 ↦ i - 1 until ..(-1); ε<printf{…  n -> m - i}!>(y); x: 0 ↦ y + x; x)>(z, z)
tick -> {u8:n -> ??  -> n ? {0 -> 0  -> {r -> io.puts{…}!  -> 1 + tick{n -> n - 1}!}!}}
tick{n -> m}!   = ε<⟳(i: 0 ↦ i + 1 until m..; ε<puts{…}!>(y); none)>(m)    the value crosses
```

Like the equation, a fold or a series is never unfolded: `fact{n -> 5}!` is
`Π(i: 1..5, i)`.

`sum{n -> m - 1}!` is not an extra notation: it is carving and collapse, applied to
types.

A carve of an equation that is not solved, collapsed where it is written, stays a
call; its production is asked, and typed for the values the carve gives (§7). When,
at those values, the production calls nothing, it is the value of the call:
`sum{t -> {}}!` is 0.

A call reads its equation where what it carves, and what its calls carve, are
unknowns of their colors: never at the values its fields hold by default. What a
call proves — by induction, a call in c when its equation is, each call it makes
taken in c — holds for every value of those fields. A field of what it gives is in c
when every field of each scope the equation gives is, each field of its calls taken
in c. While the equation is read, where what is carved is unknown or at the values
of a call, its calls are the hypothesis: they stay calls, and nothing is proven of
them yet.

The values of a call that stays are bounded by the recursion of its bounds. What is
bounded is a measure of what the call gives: its value, its length, or a sum over its
bindings `Σ(x: 0..|X| - 1, g(X.#x))` — split over the bindings of a scope, an
expansion by the sum of what it expands, a pattern by its products; a sum over the
bindings of a call is that measure of the call. The bounds lo, hi are unknowns, and
functions of the measures mⱼ of the fields the call carves — an integer, the length
of a run —: `hi = c + Σ aⱼ·mⱼ`, aⱼ ≥ 0, lo likewise. Its equation, each call in it
taken at the bound of what it carves and every other term at its own image, gives
`hi ≥ …` and `lo ≤ …` over its products, for every value their branches let the
fields take: linear in c and the aⱼ, their least solution, the aⱼ first, in closed
form. With no field read, `hi = max(…)` and `lo = min(…)`. A product reading no
call is a constant bound; `x % m`, m > 0 constant, lies in -(m - 1)..m - 1, and in 0..m - 1 when x ≥ 0;
a step `α·y + g`, α ≥ 0, keeps hi when `α·hi + max(g) ≤ hi`, lo likewise, and
otherwise leaves that side without bound. The least solution, the narrowest range,
is proven by induction: the solving only proposes it. A field every call keeps holds
what the call gives it. On a counter, each call taken at the bound y of the step
after, the greatest is `y ↦ α·y + max(g)` from `max(c)`, the least likewise — folds,
solved by their laws, read at what the call gives the counter. A run is the orbit of
its positions: a call that takes the rest `m from c` makes |m| / c steps when the
bases take only the runs of fewer than c pieces, at most as many otherwise. Its
length likewise, each call's length taken in lo..hi. A
field the call gives a call of another equation keeps it, over that equation's own
fields, each an unknown of its color: the recursion follows what the other builds.
A step that is a pattern gives one of its products, `αᵢ·y + gᵢ`: when no value is
negative, the greatest follows the greatest αᵢ and gᵢ, the least the least:

```text
Σ(x: 0..|split{t -> s  w -> {}}!| - 1, |split{…}!.#x|)  in 0..|s|      hi = |t| + |w|
sum{t -> build{depth -> d}!}!   in 0..1022 * 2 ** d - 511      y ↦ 2·y + 511, from 511
count{e -> build{depth -> d}!}! in d + 1..2 ** (d + 1) - 1      y ↦ 2·y + 1 above, y + 1 below
eval{e -> build{depth -> d}!  p -> q}! in 0..m - 1               every product x % m, x ≥ 0 in 0..m - 1
```

A recursive call whose base cases are scopes is a scope: `...` places it.

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
The link with the target is kept, since it is the same unknown:

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
(t ? {c -> p  …}) ? B    = t ? {c -> p ? B  …}
t ? {c -> p  -> p}       = p
```

A pattern on a call of an equation, read from outside it, is read on its production
at the values the carve gives. A recursion that cuts what another recursion builds
calls itself where that one calls itself: what is built is never built.

```text
sum{t -> build{d -> m  s -> a}!}!    an equation in m and a: no tree
```

A branch narrows the unknowns its reach speaks of: `u in S` gives `?ₖ::(L & S)`,
`[~](u in S)` gives `?ₖ::(L & ~S)`, S over other unknowns as well: the layout of u
then reads them. `a·u + t in S`, t not reading u, is `u in (S - t) / a`: with a = ±1
that set exactly, otherwise its bounds at the bounds of t. A layout never reads,
through other layouts, its own unknown: there, a set over unknowns narrows by its
bounds — u is in what S may hold when the literal holds, out of what S always holds
when it does not. A disjunction narrows each unknown to the union of what its sides
narrow it to. A term t the reach speaks of, `t in S`, is `t & S` in the branch, as
an unknown is `?ₖ::(L & S)`: one value, t where t in S (§4.1). What the reach says
beyond that stays its guard.

```text
r % 8 ? {<4 -> (r % 8) ? {6 -> a  -> b}  -> c}
      in the first branch r % 8 is (r % 8) & ..3: never 6, the inner pattern is b
(t ? {c -> p  …}) & S = t ? {c -> p & S  …}        a pattern gives one of its products
```

The image of a term reads such a layout with what relates them: a·u + r, u between
l and h, lies between a·l + r and a·h + r.

```text
max::0..30, d::0..32
d ? {>max -> 0  -> 1 << (max - d + 4)}
      d is ?::(0..32 & ..max): max - d + 4 lies in 4..(max + 4), in 4..34   ✓
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

A real in a color of a format is first what the machine holds of it (§4.10):
`C:x -> V ⟺ round_C(V) in C`, and V beyond the greatest value of C is invalid.

With unknowns, `V in C` is an equation in these unknowns. Each `?ₖ::L` ranges over the
values of L. The check simplifies it by the laws; it solves nothing. Its result is
a verdict, not a type:

- **proven** when the equation simplifies to `true`;
- **refuted** when it simplifies to `false` for values of the unknowns: a
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
- A real is exact; a format is a set of reals, and a color of a format rounds to it
  (§4.10).
- `''..` is every character, and `string = ''.. * 0..`. A character is a string of
  length 1 (§3, §4.6).
- A pattern is a type of the algebra, and the domain of an unknown is in its type,
  `?₁::u8`: there is no type of cases beside it, and no context of facts (§6, §7).
- The checks of a branch are guarded by the condition that reaches it (§6).
- A binding without a color imposes the constraints of its uses (§5.4).
- `a = b` is `a in =b`: there is no `==` and no `!=` (§4.5).
- No law copies, replaces, erases or reorders an effect; a pure computation crosses
  it (§4.8).
- A handler is context found when the program is typed: an emission is the carve and
  the collapse of its handler, nothing is passed at run time, and effects are not
  confined to handlers (§4.9).
