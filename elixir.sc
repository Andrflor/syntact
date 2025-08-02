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
  ? { :Error:(e) -> e (json) -> request_from_internet{json}!}
  ? { :Error:(e) -> e (req)  -> read_body{req}!}
  ? { :Error:(e) -> e (body) -> {print{body}! ->body}!}

User -> {
  -> {
    String:name
    String:token
  }
}

UserRequest -> {
  -> {
    User:user
    String:action
  }
}

UserRequest:userReq

userReq ? {
  // Structural polymorphic match of UserReq
  :UserRequest:{user{token{(id)?("jwt"..|"JWT"..) }} (action)} & action != id-> funwith{id}!
  -> baseCaseShit!
}

Rectangle:(e) & (Diamond:(e) & e.width = 10)

Circle:{radius(r)} & r > 10

Circle:{radius?(>5 & <10)}-> MediumCircle{r}!

area -> {
  Shape:shape
  -> shape ? {
    Circle:{radius(r)} -> r * r * 3
    Square:{side(s)} | Diamond:{side(s)}  -> s * s
    Triangle:{a b c} ? {
      a+b>c & b+c>a & c+a>b -> (a + b + c) / 2
      -> sqrt{s * (s - a) * (s - b) * (s - c)}
    }
  }
}

// Jwt will panic if not jwt
Jwt -> {
  String:(s) -> 'jwt' ? {
    'jwt'.. -> s
    -> panic{'String is not valid jwt'}!
  }
}

// Jwt is enforce by compiler to start with jwt
// Refuse to compile if cannot be proven jwt
Jwt -> {
  String:(s) -> 'jwt'
  // Refinedment
  -> s ?! 'jwt'..
}

decode -> {
  String:m
  -> // decode logic
}

encode -> {
  String:m
  -> // encode logic
}

Serializer {
  S <- {}
  R <- {}
  encode -> {
    S:
    -> R:
  }
  decode -> {
    R:
    -> S:
  }

  (serializerRoundTrip) <- {
    S:value -> ??
    -> decode{encode{value}!}! = value ?! true
  }
}


Json -> {
  data -> {
    -> ..0.0..:
    -> String:
    -> bool:
    -> List{data}:
    -> List{{String:name data:value}}:
  }

  string -> {

  }

  ...Serializer{
    encode -> {
      (value) -> {}:
      -> value ? {
        {}: -> {}
        {(T):(n) -> (v) ...rest} -> '{$n: $v, ...encode{{rest}}!}'
        {...rest} -> encode{{rest}}!
      }
    }

    decode-> {
      String:(value)
      -> value ? {
        // TODO: find regex like to transform into json object maybe also using Json.data and Json.string???
        `{r'w'}`
      }
    }

  }

  -> data:
  // Other properties we may want to have...
}

Email -> {
  -> String:
    !? ('a'_'z'|'.'|'0'_'9')*2..
    +'@'
    +('a'_'z'|'.'|'0'_'9')*2..
    +'.'
    +'a'_'z'*2..
}

space -> '\t'|'\n'|'\r'|' '
s -> space*0..
alnum -> ('a'..z'|'.'|'0'..'9')*1..

Identifier -> {
  ('a'..'z'|'A'..'Z'|'-'|'_')*1..&~(...'_'):init -> 'defaultId'
  -> init
}

Identifier:id // Valud is defaultId
Identifier:someId -> 'someId' //Value someId ok
Identifier:oopsi -> 'wthareyoudoing_' // Won't compile

json -> '$s{$s"$alnum":$s$value$s}$s'

// This is a compile time garantee
decodeEncodeSymmetry -> {
  String:m -> ??
  -> decode{encode{m}!}! = m ?! true
}

Maybe -> {
  T -> {}
  value -> {}:
  -> value ? {
    T:(v) -> v
    -> {}:
  }
  -> T:
}


toJson -> {
  (value) -> {}:
  -> value ? {
    {}: -> {}
    {(T):(n) -> (v) ...rest} -> '{$n: $v, ...toJson{{rest}}!}'
    {...rest} -> toJson{{rest}!
  }
}

fromJson -> {
  T -> {}:
  value
  -> value ? {
  }
}

// Assert if a string is jwt
isJwt ->  {
  String:s
  -> s ? 'jwt'..
}

// Some thing writen differently
isJwt ->  {
  String:s
  -> s ? Jwt:
}


String:data -> 'notjwt'
Maybe{Jwt data}:r // r would just be {} side
Jwt:jwt -> data // Won't compile this is not provable jwt
isJwt{data}! // False

String:data -> 'jwtweare'
Maybe{Jwt data}:r // r would be Jwt side
Jwt:jwt -> data // Will compile this is provable jwt
isJwt{data}! // True

u8:data
Maybe{String data}:r // r would be {} cause data is not matching string

// We could also say
r -> Maybe{String data}! // Same stuff
