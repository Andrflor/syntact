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

---

---

[← Defaults, completeness, immutability](09-defaults-and-immutability.md) · [Index](README.md) · [Shapes →](11-shapes.md)
