# Values are sets



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

## A set as a value: `=`

As a color, a set admits its **elements**. To admit the set itself, as one
value, prefix it with `=`:

```syntact
u8:a -> 5      // 5 is an element of u8
u8:b -> u8     // error: the set u8 is not an element of u8
=u8:c -> u8    // the value u8 itself
=u8:d -> 5     // error: 5 is not the set u8
```

`=X` is the scope `{-> X}`: a color whose only element is the value `X`. On a
single value it changes nothing — `=true:x` and `true:x` admit the same thing.

Two sets are equal when they have the same elements, however they are written:

```syntact
=(10 | ~20 | u8):e -> (u8 | 10 | ~20)    // the same set, reordered
=~~5:f -> 5                              // ~~5 is 5
=(~5 | 5):g -> int                       // both are every integer
=~10:h -> ~(10 | 11)                     // error: 11 is in ~10, not in ~(10 | 11)
```

Writings that look different can still be the same set. Compute the elements
before deciding:

- `~5 | 5`: `~5` is every integer except 5, and `| 5` puts 5 back. That is every
  integer, which is `int`. So `=(~5 | 5):g -> int` is valid.
- `10 | ~20 | u8`: `~20` is every integer except 20, and `u8` contains 20, so
  the union is every integer. `10 | ~20 | u16` is every integer for the same
  reason (`u16` contains 20 too). So `=(10 | ~20 | u8):a -> (10 | ~20 | u16)` is
  valid: `u8` and `u16` differ, but here both only put 20 back.
- `~10` and `~(10 | 11)` really differ: 11 is in the first, not in the second.
  That one is an error.

---

---

[← Defaults, completeness, immutability](09-defaults-and-immutability.md) · [Index](README.md) · [Shapes →](11-shapes.md)
