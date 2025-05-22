package compiler


builtin := init_builtins()

init_builtins :: proc() -> ScopeData {
	builtins := make([dynamic]^Binding, 13)
	append_elem(&builtin.content, &u8_binding)
	append_elem(&builtin.content, &i8_binding)
	append_elem(&builtin.content, &u16_binding)
	append_elem(&builtin.content, &i16_binding)
	append_elem(&builtin.content, &u32_binding)
	append_elem(&builtin.content, &i32_binding)
	append_elem(&builtin.content, &u64_binding)
	append_elem(&builtin.content, &i64_binding)
	append_elem(&builtin.content, &f32_binding)
	append_elem(&builtin.content, &f64_binding)
	append_elem(&builtin.content, &bool_binding)
	append_elem(&builtin.content, &char_binding)
	append_elem(&builtin.content, &string_binding)

	builtin := ScopeData {
		content = builtins,
	}


	return builtin
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
	name = "string",
	kind = .pointing_push,
}
