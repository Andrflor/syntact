# Scope algebra

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

---

[← Patterns and destructuring](12-patterns.md) · [Index](README.md) · [Pull bindings and genericity →](14-genericity.md)
