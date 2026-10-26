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
}

// test_symbols: what the libraries of the cases answer.
test_symbols :: proc() -> map[string]Symbol {
	m := make(map[string]Symbol)
	m["sqrt"] = proc(a: []Datum) -> Datum {return Datum{real = math.sqrt(a[0].real)}}
	m["pow"] = proc(a: []Datum) -> Datum {return Datum{real = math.pow(a[0].real, a[1].real)}}
	m["abs"] = proc(a: []Datum) -> Datum {return Datum{int = abs(a[0].int)}}
	m["puts"] = proc(a: []Datum) -> Datum {return Datum{int = 0}}
	m["srand"] = proc(a: []Datum) -> Datum {return Datum{}}
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
