package code_x64

import code ".."
import kernel "../../kernel"
import "core:fmt"
import vmem "core:mem/virtual"
import "core:os"
import "core:testing"

// Programs compiled to executables for x86-64 Linux, and run: what they write and
// the code they exit with, for given arguments — the inputs of the program.
Binary_Case :: struct {
	name:   string,
	source: string,
	runs:   []Binary_Run,
}

Binary_Run :: struct {
	args:   []string,
	stdin:  string, // what the program reads
	stdout: string,
	exit:   int,
}

LIBM :: "libm -> <libm.so.6>{\n  sqrt -> {f64:x, -> !?::f64}\n  pow -> {f64:b, f64:e, -> !?::f64}\n}\n"
LIBC :: "libc -> <libc.so.6>{\n  puts -> {string:s, -> !?::i32}\n  abs -> {i32:n, -> !?::i32}\n  atoi -> {string:s, -> !?::i32}\n}\n"

BINARY_CASES := []Binary_Case {
	{"known", "greeting -> \"hello\"\nanswer -> 42\n-> answer", {{exit = 42}}},
	{"no production", "a -> 1", {{exit = 0}}},
	{"folded", "-> 2 * 3 + 4 * 5", {{exit = 26}}},
	{"input", "n -> ??::u8\n-> n * 2 + 1", {{args = {"20"}, exit = 41}}},
	{"negative input", "n -> ??::i8\n-> n + 100", {{args = {"-5"}, exit = 95}}},
	{"missing input", "n -> ??::u8\n-> n", {{exit = 2}}},
	{"division", "n -> ??::u8\n-> 100 / (n + 1) + 100 % (n + 1)", {{args = {"6"}, exit = 16}}},
	{
		"branches",
		"n -> ??::u8\n-> n ? {0 -> 100  1..9 -> 200  -> 30}",
		{{args = {"0"}, exit = 100}, {args = {"4"}, exit = 200}, {args = {"50"}, exit = 30}},
	},
	{"comparison", "n -> ??::u8\n-> n < 10", {{args = {"3"}, exit = 1}, {args = {"30"}, exit = 0}}},
	{"booleans", "n -> ??::u8\n-> (n < 10) [&] (n > 2)", {{args = {"5"}, exit = 1}, {args = {"1"}, exit = 0}}},
	{"text", "-> \"hi\"", {{stdout = "hi\n"}}},
	{"real", "-> 0.0 - 1.5", {{stdout = "-1.500000\n"}}},
	{"call", LIBM + "-> libm.sqrt{x -> 2.0}!", {{stdout = "1.414214\n"}}},
	{"call crossed", LIBM + "-> libm.sqrt{x -> 2.0}! * 2.0", {{stdout = "2.828427\n"}}},
	{"call negative", LIBM + "-> libm.sqrt{x -> 2.0}! - 3.0", {{stdout = "-1.585786\n"}}},
	{"two calls", LIBM + "-> libm.sqrt{x -> 4.0}! + libm.sqrt{x -> 9.0}!", {{stdout = "5.000000\n"}}},
	{"nested calls", LIBM + "-> libm.sqrt{x -> libm.pow{b -> 3.0  e -> 4.0}!}!", {{stdout = "9.000000\n"}}},
	{"unused answer kept", LIBC + "r -> libc.puts{s -> \"hello\"}!\n-> libc.abs{n -> -42}!", {{stdout = "hello\n", exit = 42}}},
	{"order of runs", LIBC + "a -> {r -> libc.puts{s -> \"one\"}!  -> 1}!\nb -> {r -> libc.puts{s -> \"two\"}!  -> 2}!\n-> b - a", {{stdout = "one\ntwo\n", exit = 1}}},
	{"answer read twice", LIBC + "-> {a -> libc.abs{n -> -3}!  -> a * a}!", {{exit = 9}}},
	{"signed answer", LIBC + "-> libc.atoi{s -> \"-5\"}! + 10", {{exit = 5}}},
	{"function", "fact -> {u8:n -> ??  -> n ? {0 -> 1  -> n * fact{n -> n - 1}!}}\n-> fact{n -> 5}!", {{exit = 120}}},
	{"loop", "_fib -> {\n  n -> 2  i -> 2  prev -> 0  cur -> 1\n  -> i ? {<n -> _fib{n i+1 cur cur+prev}!  -> cur}\n}\nfib -> {\n  n -> 0\n  -> n ? {<2 -> n  -> _fib{n+1}!}\n}\n-> fib{??::u8}!", {{args = {"0"}, exit = 0}, {args = {"10"}, exit = 55}, {args = {"13"}, exit = 233}}},
	{"recursion that acts", LIBC + "say -> {u8:n -> ??  -> n ? {0 -> 0  -> {r -> libc.puts{s -> \"tick\"}!  -> 1 + say{n -> n - 1}!}!}}\n-> say{n -> ??::u8}!", {{args = {"3"}, stdout = "tick\ntick\ntick\n", exit = 3}, {args = {"0"}, exit = 0}}},
	{"answers of a recursion", LIBC + "cnt -> {u8:n -> ??  -> n ? {0 -> 0  -> libc.abs{n -> -2}! + cnt{n -> n - 1}!}}\n-> cnt{n -> ??::u8}!", {{args = {"4"}, exit = 8}}},
	// reading: gets into a buffer malloc gives, fgets from the stream fdopen gives
	{"gets", "io -> <libc.so.6>{\n  malloc -> {u64:size, -> !?::u64}\n  gets -> {u64:buf, -> !?::string}\n  puts -> {string:s, -> !?::i32}\n  atoi -> {string:s, -> !?::i32}\n  fdopen -> {i32:fd, string:mode, -> !?::u64}\n  fgets -> {u64:buf, i32:size, u64:stream, -> !?::string}\n  printf -> {string:format, string:s, -> !?::i32}\n}\nget -> {-> io.gets{buf -> io.malloc{size -> 4096}!}!}\nfirst -> get!\nsecond -> get!\nsaid -> io.puts{s -> second}!\nagain -> io.puts{s -> first}!", {{stdin = "one\ntwo\n", stdout = "two\none\n"}}},
	{"read a number", "io -> <libc.so.6>{\n  malloc -> {u64:size, -> !?::u64}\n  gets -> {u64:buf, -> !?::string}\n  puts -> {string:s, -> !?::i32}\n  atoi -> {string:s, -> !?::i32}\n  fdopen -> {i32:fd, string:mode, -> !?::u64}\n  fgets -> {u64:buf, i32:size, u64:stream, -> !?::string}\n  printf -> {string:format, string:s, -> !?::i32}\n}\nget -> {-> io.gets{buf -> io.malloc{size -> 4096}!}!}\nn -> io.atoi{s -> get!}!\n-> n * 2", {{stdin = "21\n", exit = 42}}},
	{"fgets", "io -> <libc.so.6>{\n  malloc -> {u64:size, -> !?::u64}\n  gets -> {u64:buf, -> !?::string}\n  puts -> {string:s, -> !?::i32}\n  atoi -> {string:s, -> !?::i32}\n  fdopen -> {i32:fd, string:mode, -> !?::u64}\n  fgets -> {u64:buf, i32:size, u64:stream, -> !?::string}\n  printf -> {string:format, string:s, -> !?::i32}\n}\nget -> {-> io.gets{buf -> io.malloc{size -> 4096}!}!}\nstdin -> io.fdopen{fd -> 0  mode -> \"r\"}!\nname -> io.fgets{buf -> io.malloc{size -> 256}!  size -> 256  stream -> stdin}!\nsaid -> io.printf{format -> \"Hello, %s\"  s -> name}!", {{stdin = "Kensai\n", stdout = "Hello, Kensai\n"}}},
	{
		"call on one path",
		LIBM + "n -> ??::u8\n-> n ? {0 -> libm.sqrt{x -> 16.0}!  -> 1.0}",
		{{args = {"0"}, stdout = "4.000000\n"}, {args = {"1"}, stdout = "1.000000\n"}},
	},
}

@(test)
test_binaries :: proc(t: ^testing.T) {
	arena: vmem.Arena
	context.allocator = vmem.arena_allocator(&arena)
	defer vmem.arena_destroy(&arena)
	base, _ := os.temp_directory(context.allocator)
	dir := fmt.tprintf("%s/syntact_code_test_%d", base, os.get_pid())
	os.make_directory_all(dir)
	defer os.remove_all(dir)
	for c, n in BINARY_CASES {
		k, parsed := kernel.run(c.source)
		if !testing.expectf(t, parsed, "%s: does not parse", c.name) do continue
		prog, err := code.lower_program(&k)
		if !testing.expectf(t, err == "", "%s: %s", c.name, err) do continue
		path := fmt.tprintf("%s/case_%d", dir, n)
		if msg := executable(&prog, path); !testing.expectf(t, msg == "", "%s: %s", c.name, msg) do continue
		for r in c.runs {
			command := make([dynamic]string)
			append(&command, path)
			append(&command, ..r.args)
			desc := os.Process_Desc{command = command[:]}
			if r.stdin != "" {
				input := fmt.tprintf("%s/case_%d.in", dir, n)
				written := os.write_entire_file(input, transmute([]u8)r.stdin)
				if !testing.expectf(t, written == nil, "%s: the input cannot be written", c.name) do continue
				file, opened := os.open(input)
				if !testing.expectf(t, opened == nil, "%s: the input cannot be opened", c.name) do continue
				desc.stdin = file
			}
			state, stdout, _, failed := os.process_exec(desc, context.allocator)
			if desc.stdin != nil do os.close(desc.stdin)
			if !testing.expectf(t, failed == nil, "%s: does not run: %v", c.name, failed) do continue
			testing.expectf(t, string(stdout) == r.stdout, "%s %v: wrote %q, expected %q", c.name, r.args, string(stdout), r.stdout)
			testing.expectf(t, state.exit_code == r.exit, "%s %v: exited %d, expected %d", c.name, r.args, state.exit_code, r.exit)
		}
	}
}
