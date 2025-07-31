Error -> {
  -> {
    // Not so good idea
    <- Error
    i32:code
    String:message
  }
}


// Nested processing
responseBody -> json.decode{param_1}! ? {
  Error:(e) -> e
  (json) -> request_from_internet{json}! ? {
    Error:(e) -> e
    (body) -> read_body{req}! ? {
      Error:(e) -> e
      (body) -> {print{body}! ->body}!
    }
  }
}

// Unnested Processing wth shadowed variable
r -> json.decode{param_1}! ? {
  Error:(e) -> e
  (json) -> request_from_internet{json}!
}
r -> r ? {
  Error:(e) -> e
  (req) -> read_body{req}!
}
r -> r ? {
  Error:(e) -> e
  (body) -> {print{body}! -> body}!
}

// Processing with ? operator chaining
responseBody -> json.decode{param_1}!
  ? { Error:(e) -> e (json) -> request_from_internet{json}!}
  ? { Error:(e) -> e (req)  -> read_body{req}!}
  ? { Error:(e) -> e (body) -> {print{body}! ->body}!}

Token -> {
  id -> String
}

User -> {
  name -> String
  token -> Token
}

UserRequest -> {
  user -> User
  action -> String
}

UserRequest:userReq

userReq ? {
  // :UserRequest mean structural and created from UserRequest
  :UserRequest:{user{token{(id)?("jwt"..|"JWT"..) }} (action)} ?? action != id-> funwith{id}!
  -> baseCaseShit!
}


:UserRequest:{user{(name)} (action)} ?? name=action ->
