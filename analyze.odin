package compiler

import "core:fmt"
import "core:hash"
import "core:slice"
import "core:strings"
import "core:time"

Analyzer :: struct {
	errors:   [dynamic]Analyzer_Error,
	warnings: [dynamic]Analyzer_Error,
}

Analyzer_Error_Type :: enum {}

Analyzer_Error :: struct {
	type:     Analyzer_Error_Type,
	message:  string,
	position: Position,
}

analyze :: proc(cache: ^Cache) -> bool {
	if (cache.ast == nil) {
		return false
	}
	return true
}

enter_scope :: proc() {

}

leave_scope :: proc() {

}
