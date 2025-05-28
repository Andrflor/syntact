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

u8_binding := Binding {
	name = "u8",
	kind = .pointing_push,
}

i8_binding := Binding {
	name = "i8",
	kind = .pointing_push,
}

u16_binding := Binding {
	name = "u16",
	kind = .pointing_push,
}

i16_binding := Binding {
	name = "i16",
	kind = .pointing_push,
}

u32_binding := Binding {
	name = "u32",
	kind = .pointing_push,
}

i32_binding := Binding {
	name = "i32",
	kind = .pointing_push,
}

u64_binding := Binding {
	name = "u64",
	kind = .pointing_push,
}

i64_binding := Binding {
	name = "i64",
	kind = .pointing_push,
}

f32_binding := Binding {
	name = "f32",
	kind = .pointing_push,
}

f64_binding := Binding {
	name = "f64",
	kind = .pointing_push,
}

bool_binding := Binding {
	name = "bool",
	kind = .pointing_push,
}

char_binding := Binding {
	name = "char",
	kind = .pointing_push,
}

string_binding := Binding {
	name = "String",
	kind = .pointing_push,
}
