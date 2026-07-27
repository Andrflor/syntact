# Bindings

## Bindings

`->` is the basic binding arrow.

```syntact
name -> "Alice"
age -> 29
```

Read it as “name points to Alice” and “age points to 29”.

Bindings are top-down. A binding can use what exists above it in the same scope or in an enclosing scope.

```syntact
x -> 1
y -> x + 1 // valid
```

This is invalid:

```syntact
y -> x + 1 // invalid: x does not exist yet
x -> 1
```

A scope is not an unordered namespace. It is a directed structure. Later bindings may depend on earlier bindings. Reduction follows that structure.

This matters because there is no separate parameter zone. What other languages call a parameter is usually just an earlier binding with a default.

```syntact
square -> {
  n -> 0
  -> n * n
}
```

`n` is a binding. The production can use it because it appears above.

---

## Same-name bindings are not redeclarations

In a scope, two bindings can share a name. They are not in conflict and the second does not overwrite the first.

```syntact
box -> {
  x -> 1
  y -> x
  x -> 2
}
```

`box` contains two distinct bindings, `x#0` and `x#1`. They are independent entries in an ordered structure, not conflicting entries in a symbol table. The compiler tracks them by index.

This is not shadowing and not redefinition. It is a structural feature: a scope is a sequence of bindings, and several can share a name. Syntact treats a scope as data, not as a symbol table. A symbol table forces unique names. Data does not.

### Access and carving target different occurrences

Same-name bindings introduce a subtle but central rule: **access by name and carving do not look at the scope the same way**.

* **Access** (`box.x`) returns the **last** visible occurrence of `x`. It is a current-view resolution, walking the scope top-down and keeping the last one.
* **Carving** (`box{x -> ...}`) targets the **first** structural occurrence of `x` by default. It is a structural transformation of the scope's foundation.

So given the `box` above:

```syntact
box.x // 2          (last occurrence: x#1)
box.y // 1          (y was bound to x#0, the x in scope at that line)
```

And a carve:

```syntact
box2 -> box{x -> 10}

box2.x // 2         (still reads the last x, which is x#1, untouched)
box2.y // 10        (y depends on x#0, which was carved to 10)
```

Either occurrence can be targeted explicitly:

```syntact
box{x#0 -> 5}  // carve the first x
box{x#1 -> 9}  // carve the last x
box{x   -> 7}  // unqualified: carves x#0
```

A motivating example:

```syntact
Config -> {
  port -> 8080
  url  -> "localhost:" + port
  port -> 3000
}

Config.port // 3000              (last port)
Config.url  // "localhost:8080"  (url was built from the first port)

DevConfig -> Config{port -> 9000}

DevConfig.port // 3000
DevConfig.url  // "localhost:9000"
```

This is not an inconsistency. The two operators answer different questions:

* reading asks **what is the current view of this name**;
* carving asks **what is the structural source this scope is built on**.

Same-name bindings let you expose one value through the visible name while keeping the foundational value carvable. Shadowing and structural rewriting coexist instead of fighting each other.

---

---

[← Scopes](04-scopes.md) · [Index](README.md) · [Productions and collapse →](06-productions-and-collapse.md)
