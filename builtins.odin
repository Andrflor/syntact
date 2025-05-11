package compiler


builtin := init_builtins()

init_builtins :: proc() -> Scope {
	builtins := make([dynamic]Scope, 13)
	append(&builtin.content, u8_scope)
	append(&builtin.content, i8_scope)
	append(&builtin.content, u16_scope)
	append(&builtin.content, i16_scope)
	append(&builtin.content, u32_scope)
	append(&builtin.content, i32_scope)
	append(&builtin.content, u64_scope)
	append(&builtin.content, i64_scope)
	append(&builtin.content, f32_scope)
	append(&builtin.content, f64_scope)
	append(&builtin.content, bool_scope)
	append(&builtin.content, char_scope)
	append(&builtin.content, string_scope)

	builtin := Scope {
		name    = "builtin",
		content = builtins,
	}


	return builtin
}

u8_scope := Scope {
	name         = "u8",
	binding_kind = .pointing_push,
}

i8_scope := Scope {
	name         = "i8",
	binding_kind = .pointing_push,
}

u16_scope := Scope {
	name         = "u16",
	binding_kind = .pointing_push,
}

i16_scope := Scope {
	name         = "i16",
	binding_kind = .pointing_push,
}

u32_scope := Scope {
	name         = "u32",
	binding_kind = .pointing_push,
}

i32_scope := Scope {
	name         = "i32",
	binding_kind = .pointing_push,
}

u64_scope := Scope {
	name         = "u64",
	binding_kind = .pointing_push,
}

i64_scope := Scope {
	name         = "i64",
	binding_kind = .pointing_push,
}

f32_scope := Scope {
	name         = "f32",
	binding_kind = .pointing_push,
}

f64_scope := Scope {
	name         = "f64",
	binding_kind = .pointing_push,
}

bool_scope := Scope {
	name         = "bool",
	binding_kind = .pointing_push,
}

char_scope := Scope {
	name         = "char",
	binding_kind = .pointing_push,
}

string_scope := Scope {
	name         = "string",
	binding_kind = .pointing_push,
}
