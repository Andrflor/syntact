# Shapes: a scope as a color

Any type can stand on the left of `:`, scopes included. A scope admits values by its
productions, or by its structure when it has none.

## A scope with productions admits what they produce

```syntact
Bit -> {
  -> 0
  -> 1
}
Bit:one -> 1        // proven
Bit:two -> 2        // refused
```

`{-> t}` admits `t` only: it is `=t`. A production `-> C:` produces what `C` admits:

```syntact
F32OrString -> {
  -> f32:
  -> string:
}
```

## A shape admits a structure

A scope without production is a shape. It admits the scopes of the same structure —
the same names, kinds and order — whose every binding its own color admits. Two
different structures have nothing in common.

```syntact
Pair -> {u8: u8:}
Pair:p -> {1 2}     // proven
Pair:q -> {1}       // refused: another structure
```

```text
{1 2} in {u8: u8:}       = true
{u8:} & {u8: u8:}        = none
```

### Runs

`...C:` in a shape admits a run of bindings that, taken as a scope, `C` admits. `...`
alone admits any run. A shape with a run has no fixed length:

```syntact
{...Pair: string:}:r -> {1 2 "x"}       // a pair, then a string
{... u8:b}:s -> {"a" true b -> 7}       // anything, then a u8 named b
{u8:x ...}:t -> {x -> 1 "rest" false}   // a u8 named x, then anything
```

### Unions of shapes

Shapes of one structure are products, and their `|` has one normal form: the first
place cut into blocks, the values the same shapes admit; the rest of each block in
that form; the blocks with the same rest joined, as (A×X) ∪ (B×X) = (A∪B)×X:

```text
{u8: string:} | {i8: string:}   = {(-128..255): string:}
{u8: string:} | {i8: bool:}     = {(-128..-1): bool:} | {(0..127): (string | bool):}
                                  | {(128..255): string:}
```

## The color flows into the value

In the value of a binding colored by a shape, a binding without a color takes the
color of its place. A carve of that value is checked against the color:

```syntact
Array -> {
  T -> {}
  -> {}
  -> {T: ...Array{T}:}
}
Array{u8}:xs -> {1 2 3}
ys -> xs{300}                       // refused: 300 is not in 0..255

Array{F32OrString}:array -> {0.1 2.0 "hello"}
```

No element of `array` is colored by hand: the color of `array` reaches each place.

## Anonymous bindings

`C:` is a binding colored by `C` without a name. In a value, it is the default of `C`;
in a shape, a place colored by `C`. It is how shapes and productions are written:
`{u8: u8:}`, `-> string:`.

`C:p{…}` colors `p` by `C` and gives it the default of `C`, carved:

```syntact
Point -> {u8:x  u8:y}
Point:p{x -> 10  y -> 20}        // Point{x -> 10  y -> 20}
Point:q{x -> 300}                // refused: 300 is not in 0..255
```

## An uncolored binding

A binding without a color imposes what its uses need. Used with `*`, it must admit
`*`; if a property of it is read, that property must exist and admit the use:

```text
{n -> 0  -> n * 2}              n admits * 2: an integer
{p -> {y -> 1}  -> p.y + 1}     p has a y that admits + 1
```

> **Open.** Refining a field in a carve, `Circle{radius?<10}`, is not written in
> `types.md` and is not built by the kernel yet.

---

[← Carving](04-carving.md) · [Index](README.md) · [Unknowns and the check →](06-unknowns-and-the-check.md)
