# Shapes

`:` constrains a binding by a shape.

```syntact
u8:age
string:name
Point:p
```

Read `u8:age` as “age shaped like `u8`”.

A shaped binding can receive a value:

```syntact
u8:age -> 29
string:name -> "Alice"
```

or use its default:

```syntact
u8:age      // 0
string:name // ""
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

### Constraints as implicit structural coloring

`:` does more than check a value against a shape. It **colors** the binding structurally: every constraint imposed by the shape propagates through the binding and everything it contains, without needing to be restated.

Any scope can be used as a constraint. Primitive types, user-defined scopes, carved scopes, refined scopes — the mechanism is the same.

```syntact
Array -> {
  T -> {}
  -> {}
  -> {T: ...Array:}
}
```

`Array` is a recursive scope parameterized by `T`. Its productions describe either an empty scope or a head shaped by `T` followed by more `Array`.

Now define a union-like scope:

```syntact
F32OrString -> {
  -> f32:
  -> string:
}
```

`F32OrString` is a scope whose productions are either `f32` or `String`. It is not a type declaration — it is a scope that produces one of two shapes.

Use it as a constraint through carving:

```syntact
Array{F32OrString}:array -> {0.1 2.0 "hello"}
```

What happens here:

```text
Array{F32OrString}    carve Array with T = F32OrString
:array                constrain array by the carved scope
-> {0.1 2.0 "hello"}  give it a value
```

The constraint on `array` is `Array{F32OrString}`. This means every element must satisfy `F32OrString`. But this constraint was never written on any individual element. `0.1` is not annotated as `f32:`. `"hello"` is not annotated as `string:`. The coloring is **implicit** — it flows from the constraint on the whole scope down to each structural position.

This is a direct consequence of default completeness and the scope model. A constraint is not an annotation that lives on one binding. It is a structural property of the scope, and it propagates inward.

If `array` is later passed to another scope that expects `Array:`, the `F32OrString` constraint on `T` travels with it. No re-annotation is needed at the receiving site.

```syntact
printAll -> {
  Array:items
  -> items ? {
    {} -> "done"
    {head ...tail} -> head + " " + printAll{items -> tail}!
  }
}

printAll{items -> array}!
```

`printAll` accepts any `Array:`. Because `array` was colored as `Array{F32OrString}`, the constraint is already satisfied. The coloring is carried by the value, not by the call site.

This is not type inference in the traditional sense. There is no separate type system reconstructing constraints from usage. Coloring is a structural property: once a scope is constrained, every operation that depends on it inherits the constraint. The scope carries its coloring the way data carries its shape.

---

---

[← Values are sets](10-values-are-sets.md) · [Index](README.md) · [Patterns and destructuring →](12-patterns.md)
