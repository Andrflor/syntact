`trolol
dwdwk fait du \n multiline whoula`
super 0.22
0xff22
2 1 1
0b101
1..2
2&2
2^2
2%2
2*2
2+2
2-2
2/2
~2
^2
super..plop
Counter -> {
  Change -> {
    u8:value
  }
  -> {
    u8:value -> 0
    // Value is now driven via Change resonance
    value >>- Change
    Change -< e {
      // We can use resonance to drive value here
      value -<< e.value
    }
    increment -> {
      >- Change{value+1}
    }
    decrement -> {
      >- Change{value-1}
    }
    // This is the correct Change driven value
    -> value
  }
}

Counter:globalCounter
// counterPositive is true
bool:counterPositive >>- globalCounter.value >= 0
funWithCounter -> {
  globalCounter.decrement!
  globalCounter.increment!
}

funWithCounter! // counterPositive updates to false then to true again

State -> {
  T <- None
  T:initial
  Update -> {
    T:value
  }
  -> {
    T:value -> initial
    value >>- Update
    Update -< e {
      value >>- e.value
    }
    update -> {
      T:value
      >- Update{value}
    }
    -> value
  }
}

DynList -> {
  T -> None
  Update -> {
    T:data
    u64:length
  }
  -> {
    u64:_length
    List{T}:value
    _length -> // Need to compute initial length
    // The bind >>- remove the visibility from outside
    // It's possible to bind to nothingness (data >>-)
    // This allow access controll
    _length >>- Update
    value >>- Update
    Update -< e {
      value >>- e.data
      _length >>- e.length
    }
    push -> {
      T:element
      >- Update{{...value element} _length+1}
    }
    length -> _length
    -> value
  }
}

DynList{u8}:dynList{value->{1 2 3 4 5}}
dynList.length // 5
dynList.push{6}!
dynList! // {1 2 3 4 5 6}
dynList.length // 6

Logging -> {
  Log -> {
    String:message
  }
  Log -< e {
    -> io.write{e.message}!
  }
}

main -> {
  ...Logging
   Counter:counter
   >- Log{counter!} // 0
   counter.increment!
   >- Log{counter!} // 1
   counter.decrement!
   >- Log{counter!} // 0
}

main!
