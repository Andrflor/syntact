Color -> {
  -> {
    u8:r
    u8:g
    u8:b
    u8:a -> 255
  }
}

num -> {
  -> u8:
  -> u32:
  -> u64:
}

// Reference from current scope
// thiis mean the lib folder file geomrtry scope Plane
Plane2D -> @lib.geometry.Plane

// Indead we can tread the filesystem with our code as any othe data
// This expand the content of the modified ersion of geometry here
...@lib.geometry{Plane->Plane{dimenion->3}}

// we cold also do anyother sutff
// the scope with @ are nothing special there are the same as anything else
Plane3D -> Plane

Circle->{->{u8:radius}}
Square->{->{u8:side}}

Shape -> {
  circle -> Circle
  square -> Square
  -> circle:
  -> square:
}

None->{}
maybe -> {
  T -> None
  -> None:
  -> T:
}

double -> {
  maybe{Shape}:shape
  -> shape ? {
    None: -> shape
    Circle: -> shape{radius->radius*2}
    Square: -> shape{side->side*2}
  }
}

List -> {
  T -> None
  -> {}
  -> {
    T:
    ...List{T}: // Expansion of the scope in this one
  }
}
// Because of ...{1 2 3 4} is list no need for {1 {2 {3 {4}}}}
map -> {
  S <- None
  R <- None
  List{S}:list
  mapper -> {
    S:(e)
    -> R:
  }
  -> list ? {
    None: -> list
    {S:(e) ...List{S}:(l)}: -> map{{mapper{e}! ...l} mapper->mapper}!
  }
}

NonEmptyList -> {
  T -> None
  -> {T: ...List{T}:}
}

reduce -> {
  T <- None
  NonEmptyList{T}:list
  reducer -> {
    T:(a)
    T:(b)
    -> T:
  }
  -> list ? {
    {T:(e)}: -> e
    {T:(e1) T:(e2) ...List{T}:(l)}: -> reduce{
      list->{reducer{a->e1 b->e2}! ...l}
      reducer->reducer
    }!
  }
}

Error -> {
  String:(message)
}

errorNoneReduce -> {
  T <- None
  List{T}:list
  reducer -> {
    T:(a)
    T:(b)
    -> T:
  }
  -> list ? {
    None: -> Error{"Trying to reduce empty list"}
    {T:(e)}: -> e
    {T:(e1) T:(e2) ...List{T}:(l)}: -> reduce{
      list->{reducer{a->e1 b->e2}! ...l}
      reducer->reducer
    }!
  }
}

transform -> {
  maybe{Shape}:shape
  transformer -> {
    maybe{Shape}:shape
    -> shape
  }
  -> transformer{shape->shape}!
}

// This is the exact same thing as double
// This has also the eact same runtime cost (if any)
doubleV2 -> transform{transformer->double}

maybe{u8}:data -> 22
maybe{Shape}:shape -> data ? {
 None: -> data
 u8: -> Circle:{radius->data}
}

shape -> double{shape->shape}!
//Shape is now Circle radius 44
shape -> doubleV2{shape->shape}!
//Shape is not Circle radius 88

square -> {
  maybe{num}:n
  -> n ? {
    None: -> 0
    num: -> n*n
    }
  }
}
maybe{u32}:plop -> 12

square{n->22}! //484 u8
square{n->plop}! //144 u32
square{n->{}}! //0 u8

Log -> {
  String:message
}

Input -> {
  String:message
}

Logger -> {
  -> {
    String:message
  }
}

Get -> {
  String:url
}

ArenaAlloc -> {
   u64:size
}

debugPrint -> {
  String:message
  >- Logger:debug{message->message}
}

printBack -> {
  String:message
  String:input >- Input{message->message}
  >- Log{message->input}
  debugPrint{message->message}!
}

getPony -> {
  response >- Get{url->"www.pony.com"}
  -> response
}

// Create compile-time of the http ref
// That mean that side effect in httpCompileTime are now compile time
httpCompileTime -> @compile{@http}!

// Config Text is a string here
String:configText -> httpCompileTime.get{"https://api.myservice.com/config"}!

// Pattern match directly on the string
result -> configText ? {
  "PRODUCTION" -> "Production mode"
  "DEVELOPMENT" -> "Development mode"
  -> "Unknown mode"
}

main -> {
  Arena:arena
  Log -< e {
    -> io.write{e.message}!
  }
  Get -< e {
    -> http.get{e.url}!
  }
  Input -< e {
    -> io.read{e.message}!
  }
  ArenaAlloc -< e {
    -> arena.allocate{e.size}!
  }
  Logger:debug -< e {
    -> io.writeln{e.message}!
  }
  response -> getPony(!)
  printBack{message->"Input something here"}!
  debugPrint{message->response!}(!)
  // The result is compile time constant and thus a binary value in the final executable
  debugPrint{message->result}
  packed -> map{
    mapper->double
    list->{1 2 3 4 5}
  }

  result -> packed([!])

  // Example on how to collapse
  packed!     // Sequential
  packed<!>   // In another thread (handle state access automaticcally with atomics/locks)
  packed[!]   // Parallel CPU (must be pure) (aka auto thread pool the computation)
  packed(!)   // Background(return a scope that can be collapsed in sync to extract value)
  packed([!]) // Parallel in background(also collapsable scope wrap)
  packed|!|   // GPU (must be pure)
  packed(|!|) // GPU in background(also collapsable scope wrap)
  // You can do other compositions like <[!]> or even (<[!]>) liek you want..

  debugPrint{message->result!}!
  -> 0
}

// This is the return of the file
// Without that there is nothing to compute
// Rq: side effect make binary not just a 0
// If there where no side effects the program will just compile to a return 0
// Still everything is optimized around those side effects in the produced binary
// So it's optimized as hell
->main!
