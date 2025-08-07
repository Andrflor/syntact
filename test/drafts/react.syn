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


App {
  Counter:counter
  -> {
    div -> {
      className -> `App`
    }
    h1 -> {
      -> `Hello CodeSandBOx`
    }
    h2 -<< {
      -> `You clicked ${counter.value} times!`
    }
    button -> {
      onClick -> counter.decrement!
      -> `Decrement`
    }
    button -> {
      onClick -> counter.increment!
      -> `Increment`
    }
  }
}

App(!html)
