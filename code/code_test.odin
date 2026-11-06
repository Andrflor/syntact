package code

import kernel "../kernel"
import "core:fmt"
import vmem "core:mem/virtual"
import "core:os"
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
	testing.expectf(t, len(arm.values) == 1 && bounds_of(f, arm.values[0]) == Bounds{0, 32640}, "the value of the arm: %v\n%s", arm.values, print_program(&prog))
}

// A function whose calls are in tail position is a loop on its parameters.
@(test)
test_tail_call_is_a_loop :: proc(t: ^testing.T) {
	arena: vmem.Arena
	context.allocator = vmem.arena_allocator(&arena)
	defer vmem.arena_destroy(&arena)
	k, parsed := kernel.run("f -> {u32:n -> ??  acc -> 0  -> n ? {0 -> acc  1 -> acc  -> f{n -> n - 1  acc -> acc + 2}!}}\n-> f{n -> ??::u32}!")
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

// A field read of a scope of fields is the value of that field.
@(test)
test_scope_field :: proc(t: ^testing.T) {
	arena: vmem.Arena
	context.allocator = vmem.arena_allocator(&arena)
	defer vmem.arena_destroy(&arena)
	k, parsed := kernel.run("p -> {a -> ??::u8  b -> 3}\n-> p.a + p.b")
	if !testing.expect(t, parsed, "does not parse") do return
	prog, err := lower_program(&k)
	if !testing.expectf(t, err == "", "%s", err) do return
	run, failed := interpret(&prog, {4}, nil)
	testing.expectf(t, failed == "" && run.result.int == 7, "p.a + p.b = %d (%s)\n%s", run.result.int, failed, print_program(&prog))
}

// A recursion whose base cases are scopes gives the values of their fields: its
// function gives them all, a loop and a match in it too, its call takes them all,
// and a field read picks its own.
@(test)
test_function_gives_scope :: proc(t: ^testing.T) {
	arena: vmem.Arena
	context.allocator = vmem.arena_allocator(&arena)
	defer vmem.arena_destroy(&arena)
	F :: "f -> {u32:n -> ??  acc -> 0  -> n ? {0 -> {a -> acc  b -> 1}  1 -> {a -> acc  b -> 2}  -> f{n -> n - 1  acc -> (acc + n) % 1000}!}}\n"
	for c in ([]struct {
			field: string,
			n, int: i64,
		}{{"a", 10, 54}, {"b", 10, 2}, {"b", 0, 1}}) {
		k, parsed := kernel.run(fmt.tprintf("%s-> f{{n -> ??::u32}}!.%s", F, c.field))
		if !testing.expect(t, parsed, "does not parse") do return
		prog, err := lower_program(&k)
		if !testing.expectf(t, err == "", "%s", err) do return
		f := prog.funcs[1]
		loop, is_loop := f.body.insts[0].(Loop)
		testing.expectf(t, len(f.results) == 2 && is_loop && len(loop.dst) == 2, "f does not give two values in a loop\n%s", print_program(&prog))
		call, is_call := prog.funcs[0].body.insts[len(prog.funcs[0].body.insts) - 1].(Call)
		testing.expectf(t, is_call && len(call.dst) == 2, "the call of f does not take two values\n%s", print_program(&prog))
		run, failed := interpret(&prog, {c.n}, nil)
		testing.expectf(t, failed == "" && run.result.int == c.int, "f{n -> %d}!.%s = %d (%s), expected %d", c.n, c.field, run.result.int, failed, c.int)
	}
}

// The Goose benchmarks written in Syntact that the laws reduce to code: each is
// lowered, its normal form without error (bench/goose).
@(test)
test_benchmarks_lower :: proc(t: ^testing.T) {
	for name in ([]string{"sum", "tree", "interp", "bintrees", "records"}) {
		arena: vmem.Arena
		context.allocator = vmem.arena_allocator(&arena)
		path := fmt.tprintf("%s/../bench/goose/%s.syn", #directory, name)
		data, read_err := os.read_entire_file(path, context.allocator)
		if !testing.expectf(t, read_err == nil, "%s: cannot read", path) {
			vmem.arena_destroy(&arena)
			continue
		}
		k, parsed := kernel.run(string(data))
		if testing.expectf(t, parsed, "%s does not parse", name) {
			_, err := lower_program(&k)
			testing.expectf(t, err == "", "%s: %s", name, err)
		}
		vmem.arena_destroy(&arena)
	}
}
