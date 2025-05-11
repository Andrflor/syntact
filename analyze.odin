package compiler

import "core:fmt"
import "core:hash"
import "core:slice"
import "core:strings"
import "core:time"

Analyzer :: struct {
	errors:   [dynamic]Analyzer_Error,
	warnings: [dynamic]Analyzer_Error,
	root:     Symbol,
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

	analyzer := Analyzer {
		errors   = make([dynamic]Analyzer_Error, 1),
		warnings = make([dynamic]Analyzer_Error, 1),
	}
	return true
}

enter_scope :: proc(symbol: ^Symbol) {
}

leave_scope :: proc() {

}

Symbol :: struct {
	name:         string,
	content:      [dynamic]Symbol,
	binding_kind: Binding_Kind,
}
