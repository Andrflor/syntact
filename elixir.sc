Error -> {
  -> {
    // Not so good idea
    <- Error
    i32:code
    String:message
  }
}

json.decode{param_1}! ? {
  Error: -> {}
  (json) -> request_from_internet{json}! ? {
    Error: -> {}
    (body) -> read_body{req}! ? {
      Error: -> {}
      (body) -> print{body}!
    }
  }
}

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
}


:UserRequest:{user{(name)} (action)} ?? name=action ->
