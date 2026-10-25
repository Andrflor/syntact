# Operators

An operator applies to every primitive of the families it accepts, and to nothing
else. Since a set is the `|` of its elements, an operator distributes over `|`:
`(a | b) + c` is `(a + c) | (b + c)`. So it applies to sets as well as to values.

## Families

```text
int × int → int              +  -  *  [&]  [|]  ^  <<  >>
int × (int & ~0) → int       /  %          the divisor is not 0
int → int                    -  [~]
float × float → float        +  -  *
float × (float & ~0.0) → float   /
string × string → string     +             concatenation
string × int → string        *             repetition, the count ≥ 0
bool × bool → bool           [&]  [|]  ^
bool → bool                  [~]
int × int → bool             <  <=  >  >=  likewise float × float, char × char
```

An operator is legal only when its operands are proven to be in a family it
accepts. That proof is the check itself (chapter 06): `?₁::u8 + 1` is legal because
every `u8` is an integer; `10 / ??::u8` is not, because the unknown may be 0.

```syntact
a -> 1.0 + 1.5     // 2.5
b -> 1 + 1.5       // illegal: 1 is an integer, 1.5 a real
c -> u8 + 1        // 1..256
d -> u8 < 300      // true
e -> 2 > 2         // false
h -> 10 / 4        // 2
```

`[~]` is the bitwise not and `~` the complement: `[~]true` is `false`, `~true` holds
every value but `true`. Equality is `a = b`, which is `a in =b`; difference is
`~`. There is no `==` and no `!=`.

## Terms over unknowns

On terms without `| & ~`, each family brings its laws, and they give the normal form
of an equation:

```text
integers   + and * associative and commutative, * distributes over +,
           0 and 1 neutral, -a the opposite of a, (k * a) / k = a for k ≠ 0
reals      a field: the same, and (a / b) * b = a for b ≠ 0
booleans   a Boolean algebra: [~][~]a = a
```

```syntact
a -> ??::u8
d -> a - a         // 0
```

A comparison with one primitive is `in` of a bound: `x < 10` is `x in <10`. A set
built by an operator keeps its bounds: the least and greatest elements of `u8 * u8`
are `0 * 0` and `255 * 255`, so it is in `u16` and not in `u8`.

```syntact
u16:p -> ??::u8 * ??::u8     // proven
```

## Strings

A string is made of characters, and a character is a string of length 1:

```text
"jwt" = 'j' + 'w' + 't'        + is associative, "" neutral
t * 0 = ""        t * n = t + t * (n - 1)
t * (m | n) = (t * m) | (t * n)          the count: an integer ≥ 0, or a range of them
```

```syntact
f -> "ab" * 3          // "ababab"
g -> "jwt" + "!"       // "jwt!"
```

Between strings, `..` is about positions: `"jwt"..` is every string that starts with
`"jwt"` (`"jwt" + string`), `.."lel"` every string that ends with `"lel"`.

### Grammars are types

A grammar is a set of strings, so it is a type, written with the same operators.
Coloring by it is the validation:

```syntact
alpha -> 'a'..'z' | 'A'..'Z'
digit -> '0'..'9'
Identifier -> (alpha | digit | '_') * 1.. & ~(string + '_')

Identifier:ok -> "someId"      // proven
Identifier:bad -> "bad_"       // refused: it ends with '_'

Email -> 'a'..'z' * 1.. + '@' + 'a'..'z' * 1.. + '.' + 'a'..'z' * 2..
Email:mail -> "jo@mail.fr"     // proven

CString -> (char & ~'\0') * 0.. + '\0'
CString:cs -> "abc\0"          // proven: no '\0' before the end
```

---

[← Values are types](01-values-are-types.md) · [Index](README.md) · [Scopes →](03-scopes.md)
