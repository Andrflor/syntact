package compiler

builtin := init_builtins()

init_builtins :: proc() -> ScopeData {
	builtins := make([dynamic]^Binding, 0)
	for i in 0 ..< len(builtin_bindings) {
		append(&builtins, &builtin_bindings[i])
	}

	builtin := ScopeData {
		content = builtins,
	}

	return builtin
}

u8_binding := create_integer_default("u8", .u8)
i8_binding := create_integer_default("i8", .i8)
u16_binding := create_integer_default("u16", .u16)
i16_binding := create_integer_default("i16", .i16)
u32_binding := create_integer_default("u32", .u32)
i32_binding := create_integer_default("i32", .i32)
u64_binding := create_integer_default("u64", .u64)
i64_binding := create_integer_default("i64", .i64)
f32_binding := create_float_default("f32", .f32)
f64_binding := create_float_default("f64", .f64)
bool_binding := create_bool_default()
char_binding := create_integer_default("char", .u8)
string_binding := create_string_default()

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

create_integer_default :: proc(name: string, enum_value: IntegerKind) -> Binding {
	binding := new(Binding)
	binding.name = ""
	binding.kind = .product
	binding.symbolic_value = new(IntegerData)
	(binding.symbolic_value.(^IntegerData)).content = 0
	(binding.symbolic_value.(^IntegerData)).kind = enum_value
	binding.static_value = binding.symbolic_value
	scope := new(ScopeData)
	scope.content = make([dynamic]^Binding, 0)
	append(&scope.content, binding)
	return Binding {
		name = name,
		kind = .pointing_push,
		symbolic_value = scope,
		static_value = scope,
	}
}

create_float_default :: proc(name: string, enum_value: FloatKind) -> Binding {
	binding := new(Binding)
	binding.name = ""
	binding.kind = .product
	binding.symbolic_value = new(FloatData)
	(binding.symbolic_value.(^FloatData)).content = 0.0
	(binding.symbolic_value.(^FloatData)).kind = enum_value
	binding.static_value = binding.symbolic_value
	scope := new(ScopeData)
	scope.content = make([dynamic]^Binding, 0)
	append(&scope.content, binding)
	return Binding {
		name = name,
		kind = .pointing_push,
		symbolic_value = scope,
		static_value = scope,
	}
}

create_bool_default :: proc() -> Binding {
	binding := new(Binding)
	binding.name = ""
	binding.kind = .product
	binding.symbolic_value = new(BoolData)
	(binding.symbolic_value.(^BoolData)).content = false
	binding.static_value = binding.symbolic_value
	scope := new(ScopeData)
	scope.content = make([dynamic]^Binding, 0)
	append(&scope.content, binding)
	return Binding {
		name = "bool",
		kind = .pointing_push,
		symbolic_value = scope,
		static_value = scope,
	}
}

create_string_default :: proc() -> Binding {
	binding := new(Binding)
	binding.name = ""
	binding.kind = .product
	binding.symbolic_value = new(StringData)
	(binding.symbolic_value.(^StringData)).content = ""
	binding.static_value = binding.symbolic_value
	scope := new(ScopeData)
	scope.content = make([dynamic]^Binding, 0)
	append(&scope.content, binding)
	return Binding {
		name = "string",
		kind = .pointing_push,
		symbolic_value = scope,
		static_value = scope,
	}
}
