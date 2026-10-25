# Values are types

There is one world. A value is a type: the type of `5` is `5`. A set of values is a
type: `0..255` is the `|` of 256 values. What other languages call "the type" and
"the value" are the same objects, combined by the same laws.

## The primitives

```text
''  'a'  'b'  '@'  …       every character
…  -1  0  1  2  …          every integer
0.5  -3.25  …              every real
true  false
none                       the empty type: the absence of type, itself a type
??                         an unknown (chapter 06)
```

Two different primitives have nothing in common. An integer is never a real:
`1.0 & 1` is `none`. A character is a string of length 1 (chapter 02).

## The algebra

```text
a | b      either
a & b      both
~a         everything but a: ~5 holds "a" and false
=a         a itself, as one value
l..u       every primitive from l to u: 0..3 = 0 | 1 | 2 | 3
l..  ..u   up to infinity on one side; .. alone, every primitive
>t >=t <t <=t
```

`| & ~` form a Boolean algebra, and every law of one holds. `~` is absolute: "every
integer but 5" is `int & ~5`. A bound keeps the family of its primitive: `>5` ranges
over integers only, `>5.0` over reals only.

```syntact
x -> 0..10 & 5..20     // 5..10
y -> int & ~5          // ..4 | 6..
z -> bool & ~true      // false
w -> u8 & 300          // none
```

`3..0` is the same set as `0..3`; only its default differs (below).

## Names for sets

`int`, `u8`, `string`… are not keywords. They are bindings of a prelude, resolved
like any name, and a binding of the same name shadows them:

```text
int     ..0..                 every integer
float   ..0.0..               every real        f32, f64: the same
char    ''..                  every character
string  ''.. * 0..            every string
bool    false | true
u8      0..255     i8   -128..127     u16   0..65535     …   u64, i64, usize, isize
```

A domain is written the same way:

```syntact
Port -> u16 & >0               // 1..65535
Percent -> u8 & <=100          // 0..100
Percent:p -> 101               // refused: 101 is not in 0..100
```

## `:` and `in`

`C:x -> v` colors the binding `x` by `C`: the value `v` must be an element of `C`.
That is the law `in`, and the check of the whole language (chapter 06):

```text
5 in u8      = true
u8 in u8     = false        the set u8 is not one of its elements
u8 in =u8    = true         =u8 admits u8 itself
none in none = true         none is the only element of none
none in u8   = false
```

```syntact
u8:a -> 5        // proven
u8:b -> 300      // refused: 300 is not in 0..255
u8:c -> u8       // refused: u8 is not an element of u8
=u8:d -> u8      // proven
```

`=t` admits `t` alone. On one value it changes nothing: `=true:x` and `true:x` admit
the same thing. Two writings of one set are equal:

```syntact
=(int & ~5 | 5):g -> int       // int & ~5 | 5 is int
```

## Defaults

A binding without a value has the default of its color:

```text
a set      its distinguished element: 0 when it has it, "" for strings, false for
           booleans; otherwise its first element, as written: the bound written
           first of a range, the first term of a |
a scope    its first production; a shape, itself (chapter 05)
```

```syntact
u8:count       // 0
bool:enabled   // false
string:name    // ""
(2..1):r       // 2
(1..2):s       // 1
```

So no binding is ever without a value, and there is no null: `none` is a type like
the others, with one element.

---

[Index](README.md) · [Operators →](02-operators.md)
