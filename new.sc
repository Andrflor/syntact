// This is a constaint
// Give me an identifier and you'll get a thing of that shape
PairU8.$ -> {
  u8.a -> 22 // Here is a default given
  u8.b  // Here is no defualt given then it default to u8 default which is 0
}

// Then i can say stuff like
// This is valid because it's having the good shape
PairU8.plop -> {
  a -> 21
  b -> 33
}

PairU8.plip // This is also valid because it's giving the default
PairU8.plap{a -> 30}

// A sort of function but not really
// It says give sum a pair it will collapse in a u8
u8.sum? ->
{
  PairU8.pair
  #Log{message->"Sum for pair $pair"}
  -> pair.a + pair.b
}

String.dynaString? ->
{
  str -> #Allocate{kind->String size->30}
  -> str
}

String.read? ->
{
  String.filename -> dynaString!
  content -> #ReadFile{filename->filename}
  -> content
}

main? ->
{
  {
    read{filename->"file.s"}
  } #ReadFile{filename} -> {
    -> io.readFile{filename->filename}!
  {
    sum!
  } #Log{message} -> {
    -> io.print{message->message}!
  }
}

-> main!

// It says that we make a version where pair point to plap
// As a result we get the promised u8
u8.sommed -> u8.sum{pair -> plap}!

// Creation d'une liste qui attent un type T
List -> {
  T.$ -> {} // Empty scope can be anything due to polymorphism
  -> .${
    _ -> {}
    -> _ ? {
      {} -> _
      {T. ...List{T->T}!.} -> _
      -> noCompile{message->'%_ does not match with %List'}!
    }
  }
}

ListU8 -> List{T->u8}! //List of u8 generating rule
ListU8.myList // List of first branch ok that's empty
List{T->u8}!.anotherEmpty //Again another empty list and that's ok
ListU8.someU8List -> {
  22
  12
  20
} // Also ok


u8.$ -> {
  _ -> 0
  -> _ ? {
    <=255  -> _
    >= 0 -> _
    -> noCompile{message->'u8 can only be between 0 and 255'}!
  }
}

i8.$ -> {
  _ -> 0
  -> _ ? {
    <=-128  -> _
    >= 127 -> _
    -> noCompile{message->'i8 can only be between -128 and 127'}!
  }
}

Vector3.$ -> {
  f32.~
  f32.~
  f32.~
}


Player.$ {
  Vector3.position~
  f32.velocity~
  f32.acceleration~
}


MaybeU8.$ -> {
  _ -> {}
  -> _ ? {
    u8 -> _
    {} -> _
    -> noComple{message->'Maybe U8 must be u8 or empty'}!
  }
}


Maybe ->
{
  T.$ -> {}
  -> .${
    _ -> {}
    -> _ ? {
      T -> _
      {} -> _
      -> noCompile{message -> 'MaybeT must be either a T or empty'}!  // Compile-time safety
    }
  }
}

// Defining a map to map t1 into t2
// A revoir aussi cette parti est plus claire non plus
List{T->R}!.map -> {
  List{T->S}!.source
  R.transform -> {S.e}
  -> source ?
  {
    {} -> {}
    -> {
      trnasform{e->x{%0}}!
      map{x->x-{%0} transform}
    }
  }
}

Pairu8.mapped -> map{source->plap u8.transform?u8.e->e+2}!

Color.$ -> {
  u8.r
  u8.g
  u8.b
  u8.a
}

// Defining a colornamescpae rule
Colors -> {
  Color.red -> {
    255
    0
    0
    255
  }
  Color.blue -> {
    0
    0
    255
    255
  }
}

// Copy color but with mutable a
AlphaMutableColor.$ -> {
  ...Color.${a~>a}
}

// Verbose way to say the same
AlphaMutableColor2.$ -> {
  u8.r
  u8.g
  u8.b
  u8.a ~> 0
}

makeOpake? -> {
  AlphaMutableColor.color
  color~{a->255}
}

AlphaMutableColor.red{r -> 255}
makeOpake{color->red}!
// Now the alphamutableColor is opaque

// Defining a middleColor
// IT says give me the rule for a and the rule for b and i will give you that
Color.middleColor? -> {
  Color.a
  Color.b
  -> {
    r -> (a.r + b.r)/2
    g -> (a.g + b.g)/2
    b -> (a.b + b.b)/2
    a -> (a.a + b.a)/2
  }
}

// Here we created a new rule with fixed b from middle Color
Color.middleFromRed? -> {
  Color.color
  -> middleColor{a->color b->Colors.red}
}

// Here we created a very similar rule
Color.middleFromRed2? -> middleColor{b->Colors.red}

// We add a new color to the Colors namesacpe structure
Colors -> Colors+{middleRedBlue -> middleColor{a->red b->blue}!}
// Replace using the same def with middleFromRed
// This will not preserve order
Colors -> Colors-{middleRedBlue}+{middleRedBlue -> middleFromRed{color->blue}!}
// Replace using the same def with middleFromRed2 and with direct update
// This will preserve the internal order and inforce the same signature
Colors -> Colors{middleRedBlue -> middleFromRed2{a->blue}!}

Widget.$ -> {
  Widget.build?BuildContext.context
}

Rectangle.$ -> {
  f32.width
  f32.height
  ...Widget..build?BuildContext.context-> //Definition of the build function for rectangle
}

f32.adder? -> {
  f32.x
  f32.y
  -> x + y
}

f32.ziiDoubleParam? -> {
  f32.x
  f32.y
}

f32.otherAdder? -> ziiDoubleParam+{->x+y}
f32.remover? -> adder{->x-y}

f32.hightOrder? -> {
  f32.x
  f32.y
  f32.compute? -> {f32.x f32.y}
  -> compute{x->x y->y}!
}

f32.a -> 3
f32.b -> 6

f32.adderForA? -> adder{x->a}
f32.aPlusB -> adder{x->a y->b}!
f32.hightOrdrAdder? -> f32.hightOrder{compute->adder}
f32.aPlusBFromHightOrder -> f32.hightOrdrAdder{x->a y->b}!


Player.$ -> {
  u8.health ~> 100
  removeHealth? -> $~{health->health-10}
  bool.dead? -> $.health = 0
}

Tank.$ -> {
  ...Player{removeHealth-> $~{health->health-5}}
}

processPlayer? -> {
  Player.player
  player.removeHealth!

  player.dead! ? {
    true -> print('dead')
    false -> print('alive')
  }
}

Tony.tony
Player.dan

processPlayer{player->tony}!
processPlayer{player->dan}!

Log -> {
  String.message
}

Input -> {
  String.message
}

Logger.$ -> {
  String.message
}

ArenaAlloc -> {
   u64.size
}

debugPrint -> {
  String.message
  >- Logger.debug{message->message}
}

printBack -> {
  String.message
  String.input >- Input{message->message}
  >- Log{message->input}
  debugPrint{message->message}!
}

main -> {
  Arena.arena
  Log -< e {
    -> io.write{e.message}!
  }
  Input -< e {
    -> io.read{e.message}!
  }
  ArenaAlloc -< e {
    -> arena.allocate{e.size}!
  }
  Logger.debug -< e {
    -> io.writeln{e.message}!
  }
  printBack{message->"Input something here"}!
  -> 0
}
