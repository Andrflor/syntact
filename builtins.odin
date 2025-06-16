package compiler

builtin := init_builtins()

init_builtins :: proc() -> ScopeData {
	builtins := make([dynamic]^Binding, 13)
	for i in 0 ..< len(builtin_bindings) {
		append(&builtins, &builtin_bindings[i])
	}

	builtin := ScopeData {
		content = builtins,
	}

	return builtin
}

@(private = "file")
builtin_bindings := [13]Binding {
	u8_binding,
	i8_binding,
	u16_binding,
	i16_binding,
	u32_binding,
	i32_binding,
	u64_binding,
	i64_binding,
	f32_binding,
	f64_binding,
	bool_binding,
	char_binding,
	string_binding,
}

create_integer_default :: proc(enum_value: IntegerKind) -> ^ScopeData {
	binding := new(Binding)
	binding.name = ""
	binding.kind = .product
	binding.value = new(IntegerData)
	(binding.value.(^IntegerData)).content = 0
	(binding.value.(^IntegerData)).kind = enum_value
  scope := new(ScopeData)
  scope.content = make([dynamic]^Binding, 1)
  append(&scope.content, binding)
  return scope
}

create_float_default :: proc(enum_value: FloatKind) -> ^ScopeData {
	binding := new(Binding)
	binding.name = ""
	binding.kind = .product
	binding.value = new(FloatData)
	(binding.value.(^FloatData)).content = 0.0
	(binding.value.(^FloatData)).kind = enum_value
  scope := new(ScopeData)
  scope.content = make([dynamic]^Binding, 1)
  append(&scope.content, binding)
  return scope
}

create_bool_default :: proc() -> ^ScopeData {
	binding := new(Binding)
	binding.name = ""
	binding.kind = .product
	binding.value = new(BoolData)
	(binding.value.(^BoolData)).content = false
  scope := new(ScopeData)
  scope.content = make([dynamic]^Binding, 1)
  append(&scope.content, binding)
  return scope
}

create_string_default :: proc() -> ^ScopeData {
	binding := new(Binding)
	binding.name = ""
	binding.kind = .product
	binding.value = new(StringData)
	(binding.value.(^StringData)).content = ""
  scope := new(ScopeData)
  scope.content = make([dynamic]^Binding, 1)
  append(&scope.content, binding)
  return scope
}

u8_binding := Binding {
	name = "u8",
	kind = .pointing_push,
	value = create_integer_default(.u8),
}

i8_binding := Binding {
	name = "i8",
	kind = .pointing_push,
	value = create_integer_default(.i8),
}

u16_binding := Binding {
	name = "u16",
	kind = .pointing_push,
	value = create_integer_default(.u16),
}

i16_binding := Binding {
	name = "i16",
	kind = .pointing_push,
	value = create_integer_default(.i16),
}

u32_binding := Binding {
	name = "u32",
	kind = .pointing_push,
	value = create_integer_default(.u32),
}

i32_binding := Binding {
	name = "i32",
	kind = .pointing_push,
	value =create_integer_default(.i32),
}

u64_binding := Binding {
	name = "u64",
	kind = .pointing_push,
	value =  create_integer_default(.u64),
}

i64_binding := Binding {
	name = "i64",
	kind = .pointing_push,
	value = create_integer_default(.i64),
}

f32_binding := Binding {
	name = "f32",
	kind = .pointing_push,
	value = create_float_default(.f32)
}

f64_binding := Binding {
	name = "f64",
	kind = .pointing_push,
	value = create_float_default(.f64)
}

bool_binding := Binding {
	name = "bool",
	kind = .pointing_push,
	value =create_bool_default(),
}

// Pour char, j'assume que c'est un u8
char_binding := Binding {
	name = "char",
	kind = .pointing_push,
	value =create_integer_default(.u8),
}

string_binding := Binding {
	name = "String",
	kind = .pointing_push,
	value =
		create_string_default()
}


