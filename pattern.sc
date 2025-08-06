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
UserAction:userAction{data{payLoad->2}}

userAction ?  {
  User:{data?(Record:{action{valid?=true payLoad(v)}} | Pac:{payLoad?>2 content(v)})} -> v
  User:{name(n)} -> n
  -> "NotOk"
}

// TODO: make analyzer properly use unknow and enforce
// TODO: make analyzer structures for patterns
// TODO: adapt old example with new syntax ideas
// TODO: make sure that structure is used as default for sure
// Pattern assert on shape directly if we want value we use =value
// Thing to consider is that the shape of object witout production rule is itself

// That mean
Record -> {
  -> {
    Action:action
    String:payLoad
  }
}

// Now become
Record -> {
  Action:action
  String:payLoad
}
