# Syntact Constraint System Specification

## Fundamental Principle

Everything is a continuum between concrete value and constraint. A concrete value `5` is a degenerate range `5..5`. Types like `u8` are sugar for `0..255`. The constraint system describes **sets of possible values** structurally.

## Range `..`

The range operator is the foundation of the constraint system. It operates only on fundamental units:
- **Integers**: `1..4`, `0..255`, `..`, `5..`, `..10`
- **Decimals**: `1.0..4.0`, `..0.0..`, `6.0..`
- **Chars**: `'a'..'z'` — means all characters between a and z (ordinal range)
- **Strings**: `"jwt".."lel"` — means starts with "jwt" and ends with "lel"

Chars and strings both use the string family but ranges have different semantics:
- **Char range** `'a'..'z'`: ordinal — everything between a and z
- **String range** `"abc".."xyz"`: positional — starts with "abc", ends with "xyz"

Ranges do NOT apply to:
- Scopes: `..{}` is invalid
- Named types: `i8..u8` is invalid
- Cross-family: `'a'..3` is invalid

### Coloring

A range takes the "color" (family) of what it carries. `..` alone is uncolored and takes the color of its first contact.

- `1..4` → integer range
- `1.0..4.0` → decimal range
- `'a'..'z'` → char range (ordinal between a and z)
- `"jwt"..` → string range (starts with "jwt", anything after)
- `..` → uncolored = `any`

A range cannot carry contradictory colors: `'a'..3` is forbidden.

### Chained Ranges

Ranges can be chained: `1..4..2..7`. This expands the bounds — equivalent to `1..7`. Not forbidden, just potentially redundant.

### Open Ranges

- `5..` → from 5 to +infinity
- `..10` → from -infinity to 10
- `..` → everything (any)
- `..0.0..` → all decimals (negative and positive)
- `''..` ≡ `..''` ≡ `''..''` ≡ `..''..` ≡ `String` — all strings

### Inclusivity

Ranges are inclusive on both ends: `1..4` includes 1, 2, 3, 4.

### Degenerate Ranges

`5..5` ≡ `5`. A degenerate range is a concrete value. Concrete values can participate in arithmetic operations (compose). Non-degenerate ranges cannot.

## Builtin Aliases

These are sugar for ranges:
- `u8` ≡ `0..255`
- `u16` ≡ `0..65535`
- `u32` ≡ `0..4294967295`
- `u64` ≡ `0..18446744073709551615`
- `i8` ≡ `-128..127`
- `i16` ≡ `-32768..32767`
- `i32` ≡ `-2147483648..2147483647`
- `i64` ≡ `-9223372036854775808..9223372036854775807`
- `Int` ≡ `..0..` (all integers)
- `f32` ≡ decimal range (32-bit float bounds)
- `f64` ≡ decimal range (64-bit float bounds)
- `Float` ≡ `..0.0..` (all decimals)
- `String` ≡ `''..` (all strings)
- `Bool` ≡ `true|false`
- `None` ≡ empty set (nothing satisfies it)

## Arithmetic and Range Propagation

Arithmetic operators on constrained values produce **computed ranges**. The compiler tracks exact bounds through operations.

### Interval Arithmetic Rules

For ranges `a..b` and `c..d`:
- **Addition**: `a..b + c..d` = `(a+c)..(b+d)`
- **Subtraction**: `a..b - c..d` = `(a-d)..(b-c)`
- **Multiplication**: `a..b * c..d` = `min(a*c, a*d, b*c, b*d)..max(a*c, a*d, b*c, b*d)`
- **Division**: not computed (result is opaque `Int` or `Float`)
- **Modulo**: not computed (result is opaque)

Concrete values are degenerate ranges: `5` = `5..5`. So `5 + 3` = `8..8` = `8`.

### Examples

```
u8:a -> ??          -- a ∈ 0..255
u8:b -> ??          -- b ∈ 0..255
-> a + b            -- type = 0..510 (no constraint, OK)
u16:c -> a + b      -- 0..510 ⊆ 0..65535 → OK
u8:d -> a + b       -- 0..510 ⊄ 0..255 → ERROR

0..100:a -> ??
0..100:b -> ??
u8:c -> a + b       -- 0..200 ⊆ 0..255 → OK
u8:d -> a * b       -- 0..10000 ⊄ 0..255 → ERROR
u16:d -> a * b      -- 0..10000 ⊆ 0..65535 → OK
```

### Concrete Value Optimization

When values are known at compile time, the compiler computes the exact result:
```
u8:a -> 200
u8:b -> 50
u8:c -> a + b       -- 250..250 ⊆ 0..255 → OK
u8:d -> a + b + 10  -- 260..260 ⊄ 0..255 → ERROR
```

## Constraint as Contract (No Implicit Coercion)

Constraints are **static contracts**, not coercions. The compiler must **prove** at compile time that a value satisfies its constraint. If it cannot prove it, it is an error.

There is **no implicit wrapping, clamping, or promotion**. The programmer has three options:

### Option 1: Widen the constraint
```
u8:a -> ??
u8:b -> ??
u16:c -> a + b      -- 0..510 ⊆ 0..65535 → OK
```

### Option 2: Explicit cast with `&` (intersection)
```
u8:a -> ??
u8:b -> ??
u8:c -> (a + b) & u8   -- explicit: "I want this truncated to u8"
```

The `&` operator is the **intersection** — it means "take the result AND constrain it to this range". When used as a cast, the compiler generates the appropriate truncation/wrapping at runtime.

### Option 3: Use tighter input constraints
```
0..100:a -> ??
0..100:b -> ??
u8:c -> a + b       -- 0..200 ⊆ 0..255 → OK, proven safe
```

### Signed/Unsigned Interaction
```
u8:a -> ??          -- 0..255
i8:b -> ??          -- -128..127
-> a + b            -- -128..382 (no constraint, OK)
i16:c -> a + b      -- -128..382 ⊆ -32768..32767 → OK
u16:d -> a + b      -- -128..382 ⊄ 0..65535 → ERROR (negatives!)
i8:e -> a - b       -- -127..383 ⊄ -128..127 → ERROR
i8:e -> (a - b) & i8  -- explicit cast → OK
```

## Addition `+`

### On strings/chars (concatenation)
String/char patterns can be concatenated. This builds a sequence pattern. Works the same for chars and strings.
- `"jwt" + "@" + "example.com"` → exact string `"jwt@example.com"` (degenerate)
- `'a'..'z' + '@' + 'a'..'z'` → pattern: one lowercase char, then @, then one lowercase char
- `"hello" + ''..` → strings starting with "hello"

### On numbers
Produces a computed range via interval arithmetic (see above).
- `5 + 3` → `8` (concrete)
- `u8 + u8` → `0..510` (range arithmetic)

## Subtraction `-`

### On numbers
Produces a computed range via interval arithmetic.
- `10 - 3` → `7` (concrete)
- `u8 - u8` → `-255..255` (range arithmetic)

### Not valid on strings.

## Multiplication `*`

### On strings/chars (repetition)
Multiplication distributes over concatenation. Works the same for chars and strings. The right operand must be a positive integer or a positive integer range.
- `'a'..'z' * 3` → exactly 3 lowercase chars
- `'a'..'z' * 3..8` → between 3 and 8 lowercase chars
- `'a'..'z' * 1..` → one or more lowercase chars
- `'a'..'z' * 0..` → zero or more lowercase chars
- `"ab" * 3` → `"ababab"` (degenerate — concrete string repeated)

### On numbers
Produces a computed range via interval arithmetic.
- `5 * 3` → `15` (concrete)
- `0..100 * 0..100` → `0..10000` (range arithmetic)

## Char vs String pattern semantics

Chars (single quotes) and strings (double quotes) are both in the string family but behave differently in patterns:

### Char patterns
- `'a'..'z'` → ordinal range: any single character between a and z
- `'a'..'z' * 3` → exactly 3 characters, each in range a..z
- `'a' | 'b' | 'c'` → one of a, b, or c

### String patterns
- `"abc".."xyz"` → positional: starts with "abc", ends with "xyz"
- `"jwt"..` → starts with "jwt", anything after
- `"hello" * 3` → `"hellohellohello"` (concrete repetition)
- `''..` → any string = `String`

### Interaction
Chars and strings can be combined via `+` (concatenation):
- `'a'..'z' + "@" + 'a'..'z'` → one lowercase, then literal @, then one lowercase

The `*` operator on a char range produces a string pattern (multi-char). A char is just a string of length 1.

## Comparison Operators (Unary) `>`, `<`, `>=`, `<=`

These work only on ranges and produce ranges:
- `>=5` ≡ `5..`
- `>6.0` → all floats strictly greater than 6.0 (useful because ranges are inclusive, `6.0..` would include 6.0)
- `<0` → all negative numbers
- `<=100` → `..100`

This enables expressing exclusive bounds that inclusive ranges cannot represent directly.

## Union `|` and Intersection `&`

`|` and `&` are constraint composition operators. Bitwise operators use bracket syntax: `[|]`, `[&]`, `[~]`.

### Union `|`

Any two things can be combined with `|`. Always valid. Works on values too.
- `0 | 1` → the set {0, 1} (like a boolean)
- `u8 | i8` → anything that is either u8 or i8
- `>10 | <(-5)` → greater than 10 or less than -5
- `String | Int` → a string or an integer
- `'a'..'z' | 'A'..'Z' | '-' | '_'` → lowercase, uppercase, hyphen, or underscore

### Intersection `&`

Any two things can be combined with `&`. Always valid, but may produce `None` if the intersection is empty. **When used as a cast, the compiler generates runtime truncation/wrapping.**
- `0 & 1` → `None` (nothing is both 0 and 1)
- `u8 & >10` → `11..255`
- `u8 & 11..` → same thing
- `String & >10` → `None` (nothing is both a string and greater than 10)
- `i32 & >=0` → `0..2147483647`
- `(u8 + u8) & u8` → explicit cast: truncate the 0..510 result to 0..255

### Bitwise operators (bracket syntax)

- `[&]` — bitwise AND
- `[|]` — bitwise OR
- `[~]` — bitwise NOT (unary)
- `^` — bitwise XOR
- `<<` — left shift
- `>>` — right shift

## Negation `~`

Negation operates within the color of the range:
- `~'A'` → all chars except A
- `~'A'..` → all strings that don't start with A
- `~5` → all integers except 5
- `~0..10` → all integers outside 0..10

## Complex Pattern Examples

### Email validation
```
('a'..'z' | '.' | '0'..'9') * 2..
+ '@'
+ ('a'..'z' | '.' | '0'..'9') * 2..
+ '.'
+ 'a'..'z' * 2..
```

### Identifier (no trailing underscore)
```
('a'..'z' | 'A'..'Z' | '-' | '_') * 1.. & ~('' * 0.. + '_')
```
Note: `'' * 0..` means "zero or more of any char" — the negation means "does not end with underscore".

### Whitespace
```
'\t' | '\n' | '\r' | ' '
```

### JSON-like data type
```
data -> {
  -> ..0.0..:
  -> String:
  -> Bool:
  -> List{data}:
  -> List{{String:name data:value}}:
}
```

## Satisfiability Check `satisfies(value, constraint) -> bool`

Given a value (or constraint) A and a constraint B, verify that every possible value in A is also in B (A ⊆ B).

### Base cases
- `5` satisfies `u8` → 5 ∈ 0..255 → true
- `256` satisfies `u8` → 256 ∈ 0..255 → false
- `"hello"` satisfies `String` → true
- `5` satisfies `String` → false (color mismatch)

### Range inclusion
- `0..100` satisfies `u8` → 0..100 ⊆ 0..255 → true
- `0..300` satisfies `u8` → 0..300 ⊆ 0..255 → false
- `i8` satisfies `i16` → -128..127 ⊆ -32768..32767 → true

### Arithmetic result
- `u8 + u8` satisfies `u16` → 0..510 ⊆ 0..65535 → true
- `u8 + u8` satisfies `u8` → 0..510 ⊆ 0..255 → false
- `u8 - u8` satisfies `i16` → -255..255 ⊆ -32768..32767 → true

### Compound
- `5` satisfies `u8 & >3` → 5 ∈ 0..255 AND 5 > 3 → true
- `u8` satisfies `Int | String` → u8 ⊆ Int → true
- `"abc"` satisfies `'a'..'z' * 3` → each char in a..z AND length = 3 → true
- `"ab"` satisfies `'a'..'z' * 3..8` → length 2 < 3 → false

## Open Questions

- **Scope constraints**: How do scopes integrate as types? Shape matching — a scope satisfies another scope if it has all the same bindings with compatible constraints. Deferred for now.
- **Recursive types**: `List{data}` where `data` references itself. Requires cycle detection in satisfiability checks.
- **Pattern negation semantics**: `~(''..*0.. + '_')` — negating a concatenation pattern. How does this decompose?
- **Strict inequality in ranges**: `>6.0` cannot be expressed as an inclusive range. Needs explicit open/closed bound tracking, or is the unary operator form sufficient?
- **`&` as cast semantics**: When `&` is used to truncate (e.g., `(a+b) & u8`), what is the exact runtime behavior? Wrapping (modulo) or truncation (bitwise mask)? For integers, wrapping (modulo 256 for u8) is the natural choice.
