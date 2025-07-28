// Dependent type
intPlus -> {
  -> {
    (v) -> 0
    -> v ? {
      0.. -> v
      -> @panic{"This should only be positive"}!
    }
  }!

intPlus:b -> 4
intPlus:c -> 10

Foo -> {
  T -> 0
  -> T%2 ? {
    0 -> // something
    1 -> // something else
  }
}


// Theorem proving trough constraint constant default
theorem -> {
  PubKey:pub
  PrivKey:priv
  -> {
    String:m -> @unknown
    -> decrypt{encrypt{m, priv}! pub}! = m
  }!
}

assert -> {
  T -> {
    -> bool:
  }
  -> {
    T:proof ? {
      true -> {}
      false -> @panic{"Theorem is refuted"}
    }
  }
}
assert{theorem}!

// Compile time effect trigered on anythinhg
compileTimeGet -> @compile{get}
// Can be used on anything

Nat -> {
  -> {}
  -> {{} ...Nat:}
}

add -> {
  Nat:a
  Nat:b
  -> {...a ...b}
}

mult -> {
  Nat:a
  Nat:b
  -> a ? {
    {} -> {}
    {{} ...Nat:(r)} -> {...b ...mult{r b}!}
  }
}

multByOne -> {
  Nat:n -> @unknown
  -> mult{n {{}}}! = n
}

addCommutative -> {
  Nat:a -> @unknown
  Nat:b -> @unknown
  -> add{a b}! = add{b a}!
}

proove{multByOne}!
proove{addCommutative}!

Ring {
  T -> {}
  addNeutral -> {}
  add -> {
    T: a
    T: b
    -> {...a ...b}
  }
  mult -> {
    T:a
    T:b
    -> a ? {
      {} -> {}
      {{} ...T:(r)} -> {...b ...mult{r b}!}
    }
  }
  addCommutative -> {
    T:a -> @unknown
    T:b -> @unknown
    -> add{a b}! = add{b a}!
  }
  multByOne -> {
  T:n -> @unknown
  -> mult{n {{}}}! = n
  }
}
