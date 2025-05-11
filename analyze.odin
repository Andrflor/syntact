package compiler

import "core:fmt"
import "core:hash"
import "core:slice"
import "core:strings"
import "core:time"

Analyzer :: struct {
	errors:   [dynamic]Analyzer_Error,
	warnings: [dynamic]Analyzer_Error,
	root:     ^Scope,
	current:  ^Scope,
}

Analyzer_Error_Type :: enum {}

Binding_Kind :: enum {
	pointing_push,
	pointing_pull,
	event_push,
	event_pull,
	resonance_push,
	resonance_pull,
	product,
}

Analyzer_Error :: struct {
	type:     Analyzer_Error_Type,
	message:  string,
	position: Position,
}

analyze :: proc(cache: ^Cache, ast: ^Node) -> bool {
	if (ast == nil) {
		return false
	}

	root := new(Scope)
	root.name = cache.path
	root.content = make([dynamic]Scope, 8)

	analyzer := Analyzer {
		errors   = make([dynamic]Analyzer_Error, 1),
		warnings = make([dynamic]Analyzer_Error, 1),
		root     = root,
	}

	return true
}

enter_scope :: proc(symbol: ^Scope) {
}

leave_scope :: proc() {

}

Scope :: struct {
	name:         string,
	parent:       ^Scope,
	content:      [dynamic]Scope,
	binding_kind: Binding_Kind,
}
