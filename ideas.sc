// Refinement type
intPlus -> {
  -> {
    (v) -> 0
    -> v ?! >0
   }
}

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
RSAIdentity -> {
  PubKey:pub
  PrivKey:priv
  -> {
    String:m -> ??
    -> decrypt{encrypt{m, priv}! pub}! = m ?! true
  }
}

// Compile time effect trigered on anythinhg
compileTimeGet -> !{get}
// Can be used on anything

Nat -> {
  -> {}
  -> {{} ...Nat:}
}

succ -> {
  Nat:nat
  -> {...nat {}}
}


one -> {{}}
two -> {{}{}}

succ{one}! = two // true

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
  Nat:n -> ??
  -> mult{n {{}}}! = n ?! true
}

addCommutative -> {
  Nat:a -> ??
  Nat:b -> ??
  -> add{a b}! = add{b a}! ?! true
}

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
    T:a -> ??
    T:b -> ??
    -> add{a b}! = add{b a}! ?! true
  }
  multByOne -> {
  T:n -> ??
  -> mult{n {{}}}! = n ?! true
  }
}
