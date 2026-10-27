package code

import kernel "../kernel"
import "core:math"
import vmem "core:mem/virtual"
import "core:slice"
import "core:testing"

// Programs, lowered to code and run by the reference interpreter: the value of the
// run and the symbols it called, in order, for given inputs.
Code_Case :: struct {
	name:   string,
	source: string,
	inputs: []i64,
	int:    i64, // the result, when an integer
	real:   f64, // the result, when a float
	text:   string, // the result, when a text
	calls:  []string, // the symbols called, in order
	error:  string, // "" when the program lowers
}

LIBM :: "libm -> <libm.so.6>{\n  sqrt -> {f64:x, -> !?::f64}\n  pow -> {f64:b, f64:e, -> !?::f64}\n}\n"
WORDS :: "lib -> <libc.so.6>{\n  one -> {S:s, -> !?::i64}\n  two -> {S:s, -> !?::i64}\n}\n"

LIBC :: "libc -> <libc.so.6>{\n  puts -> {string:s, -> !?::i32}\n  abs -> {i32:n, -> !?::i32}\n  srand -> {u32:seed, -> !?::none}\n}\n"

CODE_CASES := []Code_Case {
	{name = "known", source = "greeting -> \"hello\"\nanswer -> 42\n-> answer", int = 42},
	{name = "no production", source = "a -> 1", int = 0},
	{name = "folded", source = "-> 2 * 3 + 4 * 5", int = 26},
	{name = "input", source = "n -> ??::u8\n-> n * 2 + 1", inputs = {20}, int = 41},
	{name = "branch taken", source = "n -> ??::u8\n-> n ? {<10 -> n + 3  -> 10}", inputs = {5}, int = 8},
	{name = "branch default", source = "n -> ??::u8\n-> n ? {<10 -> n + 3  -> 10}", inputs = {50}, int = 10},
	{name = "branches", source = "n -> ??::u8\n-> n ? {0 -> 100  1..9 -> 200  -> 300}", inputs = {4}, int = 200},
	{name = "comparison", source = "n -> ??::u8\n-> n < 10", inputs = {3}, int = 1},
	{name = "text", source = "-> \"hi\"", text = "hi"},
	{name = "call", source = LIBM + "-> libm.sqrt{x -> 2.0}!", real = math.SQRT_TWO, calls = {"sqrt"}},
	// a scope crosses as C lays out a struct of its fields, in words of 8 bytes
	{name = "scope in a word", source = "S -> {u8:a u8:b u8:c u8:d}\n" + WORDS + "-> lib.one{s -> S{1 2 3 4}}!", int = 0x04030201, calls = {"one"}},
	{name = "signed field", source = "S -> {i8:x u8:y}\n" + WORDS + "-> lib.one{s -> S{-1 2}}!", int = 0x02FF, calls = {"one"}},
	{name = "aligned field", source = "S -> {u8:a i32:b}\n" + WORDS + "-> lib.one{s -> S{1 2}}!", int = 1 | 2 << 32, calls = {"one"}},
	{name = "nested scope", source = "P -> {u8:x u16:y}\nS -> {u8:a P:p}\n" + WORDS + "-> lib.one{s -> S{1 P{2 3}}}!", int = 1 | 2 << 16 | 3 << 32, calls = {"one"}},
	{name = "scope in two words", source = "S -> {i64:a u8:b}\n" + WORDS + "-> lib.two{s -> S{5 7}}!", int = 5 * 1000 + 7, calls = {"two"}},
	{name = "scope of floats", source = "S -> {f64:re f64:im}\nlibm -> <libm.so.6>{\n  cabs -> {S:z, -> !?::f64}\n}\n-> libm.cabs{z -> S{3.0 4.0}}!", real = 5, calls = {"cabs"}},
	{name = "scope too large", source = "S -> {f64:a f64:b f64:c}\n" + WORDS + "-> lib.one{s -> S{1.0 2.0 3.0}}!", error = "the field `s` of one is a scope of 24 bytes: only 1 to 16 cross in registers yet"},
	{name = "call crossed", source = LIBM + "-> libm.sqrt{x -> 2.0}! * 2.0", real = 2 * math.SQRT_TWO, calls = {"sqrt"}},
	{name = "two calls", source = LIBM + "-> libm.sqrt{x -> 4.0}! + libm.sqrt{x -> 9.0}!", real = 5, calls = {"sqrt", "sqrt"}},
	{name = "nested calls", source = LIBM + "-> libm.sqrt{x -> libm.pow{b -> 3.0  e -> 4.0}!}!", real = 9, calls = {"pow", "sqrt"}},
	{name = "unused answer kept", source = LIBC + "r -> libc.puts{s -> \"hello\"}!\n-> libc.abs{n -> -42}!", int = 42, calls = {"puts", "abs"}},
	{name = "gives nothing", source = LIBC + "s -> libc.srand{seed -> 7}!\n-> 1", int = 1, calls = {"srand"}},
	{name = "call on one path", source = LIBM + "n -> ??::u8\n-> n ? {0 -> libm.sqrt{x -> 16.0}!  -> 1.0}", inputs = {0}, real = 4, calls = {"sqrt"}},
	{name = "call not on this path", source = LIBM + "n -> ??::u8\n-> n ? {0 -> libm.sqrt{x -> 16.0}!  -> 1.0}", inputs = {1}, real = 1},
	{name = "order of runs", source = LIBC + "a -> {r -> libc.puts{s -> \"one\"}!  -> 1}!\nb -> {r -> libc.puts{s -> \"two\"}!  -> 2}!\n-> b - a", int = 1, calls = {"puts", "puts"}},
	{name = "answer read twice", source = LIBC + "-> {a -> libc.abs{n -> -3}!  -> a * a}!", int = 9, calls = {"abs"}},
	{name = "unserved effect", source = "-> !?::u8", error = "the effect ε0 is served by no boundary"},
	// a character is a string of length 1: where a text goes, it is one
	{name = "character as text", source = "c -> <libc.so.6>{\n  fdopen -> {i32:fd, string:mode, -> !?::u64}\n}\nf -> c.fdopen{fd -> 0  mode -> \"r\"}!\n-> 1", int = 1, calls = {"fdopen"}},
	// a recursion on a counter is an iteration: a loop
	{name = "iteration", source = "fact -> {u8:n -> ??  -> n ? {0 -> 1  -> n * fact{n -> n - 1}!}}\n-> fact{n -> 5}!", int = 120},
	{name = "iteration of an input", source = "fact -> {u8:n -> ??  -> n ? {0 -> 1  -> n * fact{n -> n - 1}!}}\n-> fact{n -> ??::u8}!", inputs = {6}, int = 720},
	// a recursion that stays is a function: its fields its parameters
	{name = "function", source = "half -> {u8:n -> ??  -> n ? {0 -> 0  -> 1 + half{n -> n / 2}!}}\n-> half{n -> ??::u8}!", inputs = {100}, int = 7},
	{name = "loop", source = "_fib -> {\n  n -> 2  i -> 2  prev -> 0  cur -> 1\n  -> i ? {<n -> _fib{n i+1 cur cur+prev}!  -> cur}\n}\nfib -> {\n  n -> 0\n  -> n ? {<2 -> n  -> _fib{n+1}!}\n}\n-> fib{??::u8}!", inputs = {10}, int = 55},
	// a call in tail position is a loop: the stack does not grow with its turns
	{name = "tail call", source = "f -> {u32:n -> ??  acc -> 0  -> n ? {0 -> acc  -> f{n -> n - 1  acc -> acc + 2}!}}\n-> f{n -> ??::u32}!", inputs = {300_000}, int = 600_000},
	{name = "tail call with effects", source = LIBC + "tick -> {u8:n -> ??  -> n ? {0 -> 0  -> {r -> libc.puts{s -> \"tick\"}!  -> tick{n -> n - 1}!}!}}\n-> tick{n -> ??::u8}!", inputs = {3}, int = 0, calls = {"puts", "puts", "puts"}},
	{name = "closed form, no function", source = "sum -> {u8:n -> ??  -> n ? {0 -> 0  -> n + sum{n -> n - 1}!}}\n-> sum{n -> ??::u8}!", inputs = {10}, int = 55},
	{name = "recursion with effects", source = LIBC + "say -> {u8:n -> ??  -> n ? {0 -> 0  -> {r -> libc.puts{s -> \"tick\"}!  -> 1 + say{n -> n - 1}!}!}}\n-> say{n -> ??::u8}!", inputs = {3}, int = 3, calls = {"puts", "puts", "puts"}},
	{name = "answer read by the next effect", source = LIBC + "cnt -> {u8:n -> ??  -> n ? {0 -> 0  -> {a -> libc.abs{n -> -2}!  b -> libc.abs{n -> a}!  -> b + cnt{n -> n - 1}!}!}}\n-> cnt{n -> ??::u8}!", inputs = {3}, int = 6, calls = {"abs", "abs", "abs", "abs", "abs", "abs"}},
	{name = "answers of a recursion", source = LIBC + "cnt -> {u8:n -> ??  -> n ? {0 -> 0  -> libc.abs{n -> -2}! + cnt{n -> n - 1}!}}\n-> cnt{n -> ??::u8}!", inputs = {3}, int = 6, calls = {"abs", "abs", "abs"}},
}

// test_symbols: what the libraries of the cases answer.
test_symbols :: proc() -> map[string]Symbol {
	m := make(map[string]Symbol)
	m["sqrt"] = proc(a: []Datum) -> Datum {return Datum{real = math.sqrt(a[0].real)}}
	m["pow"] = proc(a: []Datum) -> Datum {return Datum{real = math.pow(a[0].real, a[1].real)}}
	m["abs"] = proc(a: []Datum) -> Datum {return Datum{int = abs(a[0].int)}}
	m["puts"] = proc(a: []Datum) -> Datum {return Datum{int = 0}}
	m["srand"] = proc(a: []Datum) -> Datum {return Datum{}}
	m["fdopen"] = proc(a: []Datum) -> Datum {return Datum{int = a[1].text == "r" ? 1 : 0}}
	m["one"] = proc(a: []Datum) -> Datum {return Datum{int = a[0].int}}
	m["two"] = proc(a: []Datum) -> Datum {return Datum{int = a[0].int * 1000 + a[1].int}}
	m["cabs"] = proc(a: []Datum) -> Datum {return Datum{real = math.sqrt(a[0].real * a[0].real + a[1].real * a[1].real)}}
	return m
}

@(test)
test_code :: proc(t: ^testing.T) {
	arena: vmem.Arena
	context.allocator = vmem.arena_allocator(&arena)
	defer vmem.arena_destroy(&arena)
	symbols := test_symbols()
	for c in CODE_CASES {
		k, parsed := kernel.run(c.source)
		if !testing.expectf(t, parsed, "%s: does not parse", c.name) do continue
		prog, err := lower_program(&k)
		if c.error != "" {
			testing.expectf(t, err == c.error, "%s: lowered with %q, expected %q", c.name, err, c.error)
			continue
		}
		if !testing.expectf(t, err == "", "%s: %s", c.name, err) do continue
		run, failed := interpret(&prog, c.inputs, symbols)
		if !testing.expectf(t, failed == "", "%s: %s\n%s", c.name, failed, print_program(&prog)) do continue
		switch prog.funcs[0].result {
		case .Int, .None:
			testing.expectf(t, run.result.int == c.int, "%s: %d, expected %d\n%s", c.name, run.result.int, c.int, print_program(&prog))
		case .Real:
			testing.expectf(t, abs(run.result.real - c.real) < 1e-12, "%s: %v, expected %v\n%s", c.name, run.result.real, c.real, print_program(&prog))
		case .Text:
			testing.expectf(t, run.result.text == c.text, "%s: %q, expected %q", c.name, run.result.text, c.text)
		}
		testing.expectf(t, slice.equal(run.calls[:], c.calls), "%s: called %v, expected %v", c.name, run.calls[:], c.calls)
	}
}

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
