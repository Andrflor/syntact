bounded -> {
  min -> 0
  max -> 255
  default -> 0
  -> {
    e -> default
    -> e ? {
      <= max -> e
      >= min -> e
      -> invalid{message->"Constraint $min<=$e<=$max is not respected"}!
    }
  }
}


u8 -> bounded!
i8 -> bounded{min->-128 max->127}!


Color -> {
    r -> 0
    g -> 0
    b -> 0
    a -> 0
}

sum -> {
  a -> Color
  b -> Color
  -> Color{
    r->a.r+b.r
    g->a.g+b.g
    b->a.b+b.b
    a->a.a+b.a
  }
}

Colors -> {
  red -> Color{r->u8{e->255}!}
  blue -> Color{b->u8{e->255}!}
  purple -> sum{a->red b->blue}!
}

Maybe -> {
  T -> {}
  -> {
    e -> T!
    -> e {
      T -> e
      {} -> e
      -> invalid{message->"$e is not Maybe$T it should match $T or {}"}!
    }
  }
}

MaybeU8 -> Maybe{T->u8}!
maybeU8 -> MaybeU8{e->{}}
