Array -> {
  T -> {}
  -> {}
  -> {T ...Array{T}}
}

count -> {
  T <- {}
  Array{T}:array
  elements -> 0
  -> array ? {
    {}: -> elements
    {T ...Array{T}}: -> count{array->array{1..} elements->elements+1}!
  }
}

for -> {
  i -> 0
  compute -> {
    i -> 0
  }
  _for -> {
    _i -> 0
    compute{_i}!
    -> _i {
      i -> {}!
      _ -> _for{_i++}!
    }
  }
  -> _for!
}

for{22 {
  i -> 0
  // Do something with i
}}!


String -> {
  Update -> {
    Array{Char}:value
  }
  -> {
    Array{Char}:value
    u64:length -> count{value}!
    value -<< Update
    length -<< count{value}!
    Update -< update {
      value >>- update.value
    }
    length -> length
    -> value
  }
}
