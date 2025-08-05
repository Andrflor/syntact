Action -> {
  u8:value
  bool:valid
}


Record -> {
  -> {
    Action:action
    String:payLoad
  }
}

Pac -> {
  -> {
    u8:payLoad
    String:content
  }
}

Data -> Pac | Record

User -> {
  -> {
    String:name
    Data:data
  }
}

UserAction -> User | Action
UserAction:userAction

userAction ? {
  User:{data?(Record:{action?{valid?true payLoad(v)}} | Pac:{payLoad?2 content(v)})} -> v
  User:{name(n)} -> n
  -> "NotOk"
}

// TODO: add ?! and ?? tokens to nodes
// TODO: make so that patterns are parse and detructured according to idea
