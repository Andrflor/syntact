package x64_assembler

import "core:testing"

@(test)
testing_sysv_abi_assigns_stack_arguments :: proc(t: ^testing.T) {
	classes := []X64_ABI_Class{.Integer, .Integer, .Integer, .Integer, .Integer, .Integer, .Integer}
	assignment := x64_sysv_assign(classes)
	defer delete(assignment.locations)
	testing.expectf(t, assignment.integer_count == 6 && assignment.stack_count == 1, "counts=%d/%d", assignment.integer_count, assignment.stack_count)
	testing.expectf(t, assignment.locations[6].class == .Stack && assignment.locations[6].stack_offset == 0, "seventh integer location=%v", assignment.locations[6])
	testing.expectf(t, assignment.stack_size == 16, "outgoing stack size=%d", assignment.stack_size)
}

@(test)
testing_sysv_abi_uses_independent_integer_and_sse_sequences :: proc(t: ^testing.T) {
	classes := []X64_ABI_Class{.Integer, .SSE, .Integer, .SSE, .Integer, .SSE, .Integer}
	assignment := x64_sysv_assign(classes)
	defer delete(assignment.locations)
	testing.expectf(t, assignment.locations[0].register == 0 && assignment.locations[1].register == 0, "first mixed locations=%v/%v", assignment.locations[0], assignment.locations[1])
	testing.expectf(t, assignment.locations[2].register == 1 && assignment.locations[3].register == 1, "second mixed locations=%v/%v", assignment.locations[2], assignment.locations[3])
	testing.expectf(t, assignment.integer_count == 4 && assignment.sse_count == 3 && assignment.stack_count == 0, "counts=%d/%d/%d", assignment.integer_count, assignment.sse_count, assignment.stack_count)
}
