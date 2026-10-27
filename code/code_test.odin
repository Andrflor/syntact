package code

import kernel "../kernel"
import vmem "core:mem/virtual"
import "core:testing"

// A boolean that comes back from a symbol is a byte: the bits above it are not
// part of the answer.
@(test)
test_boolean_answer :: proc(t: ^testing.T) {
	arena: vmem.Arena
	context.allocator = vmem.arena_allocator(&arena)
	defer vmem.arena_destroy(&arena)
	k, parsed := kernel.run("lib -> <libc.so.6>{\n  ready -> {-> !?::bool}\n}\n-> lib.ready! ? {true -> 7  -> 3}")
	if !testing.expect(t, parsed, "does not parse") do return
	prog, err := lower_program(&k)
	if !testing.expectf(t, err == "", "%s", err) do return
	imp := prog.imports[0]
	testing.expectf(t, imp.result_bits == 8 && !imp.result_signed, "a boolean comes back in %d bits, signed %v", imp.result_bits, imp.result_signed)
}

// What the kernel proved comes along: the bounds of each integer, narrowed where an
// arm narrows its target.
@(test)
test_facts :: proc(t: ^testing.T) {
	arena: vmem.Arena
	context.allocator = vmem.arena_allocator(&arena)
	defer vmem.arena_destroy(&arena)
	k, parsed := kernel.run("n -> ??::i32\n-> n ? {0..255 -> (n + n * n) / 2  -> 0}")
	if !testing.expect(t, parsed, "does not parse") do return
	prog, err := lower_program(&k)
	if !testing.expectf(t, err == "", "%s", err) do return
	f := prog.funcs[0]
	m, is_match := f.body.insts[len(f.body.insts) - 1].(Match)
	if !testing.expectf(t, is_match, "no match\n%s", print_program(&prog)) do return
	testing.expectf(t, bounds_of(f, m.target) == Bounds{-1 << 31, 1 << 31 - 1}, "the target: %v", bounds_of(f, m.target))
	testing.expectf(t, len(m.arms[0].cover.ints) == 1 && m.arms[0].cover.ints[0] == Bounds{0, 255}, "the cover: %v", m.arms[0].cover)
	arm := m.arms[0].body
	narrow, is_narrow := arm.insts[0].(Narrow)
	testing.expectf(t, is_narrow && bounds_of(f, narrow.dst) == Bounds{0, 255}, "the target in the arm\n%s", print_program(&prog))
	testing.expectf(t, bounds_of(f, arm.value) == Bounds{0, 32640}, "the value of the arm: %v\n%s", bounds_of(f, arm.value), print_program(&prog))
}

// A function whose calls are in tail position is a loop on its parameters.
@(test)
test_tail_call_is_a_loop :: proc(t: ^testing.T) {
	arena: vmem.Arena
	context.allocator = vmem.arena_allocator(&arena)
	defer vmem.arena_destroy(&arena)
	k, parsed := kernel.run("f -> {u32:n -> ??  acc -> 0  -> n ? {0 -> acc  -> f{n -> n - 1  acc -> acc + 2}!}}\n-> f{n -> ??::u32}!")
	if !testing.expect(t, parsed, "does not parse") do return
	prog, err := lower_program(&k)
	if !testing.expectf(t, err == "", "%s", err) do return
	f := prog.funcs[1]
	_, is_loop := f.body.insts[0].(Loop)
	testing.expectf(t, len(f.body.insts) == 1 && is_loop, "the body of f is not a loop\n%s", print_program(&prog))
}

// A recursion on a counter is an iteration (specs/types.md §5.6): a loop, not a
// function.
@(test)
test_iteration_is_a_loop :: proc(t: ^testing.T) {
	arena: vmem.Arena
	context.allocator = vmem.arena_allocator(&arena)
	defer vmem.arena_destroy(&arena)
	k, parsed := kernel.run("fact -> {u8:n -> ??  -> n ? {0 -> 1  -> n * fact{n -> n - 1}!}}\n-> fact{n -> ??::u8}!")
	if !testing.expect(t, parsed, "does not parse") do return
	prog, err := lower_program(&k)
	if !testing.expectf(t, err == "", "%s", err) do return
	f := prog.funcs[0]
	_, is_loop := f.body.insts[len(f.body.insts) - 1].(Loop)
	testing.expectf(t, len(prog.funcs) == 1 && is_loop, "fact is not a loop\n%s", print_program(&prog))
	run, failed := interpret(&prog, {6}, nil)
	testing.expectf(t, failed == "" && run.result.int == 720, "fact{n -> 6}! = %d (%s)", run.result.int, failed)
}
