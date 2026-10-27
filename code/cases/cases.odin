package code_cases

import code ".."
import kernel "../../kernel"
import "core:fmt"
import vmem "core:mem/virtual"
import "core:os"
import "core:testing"

// THE PROGRAMS EVERY BACKEND RUNS
//
// Programs built into executables by a backend, and run: what they write and the
// code they exit with, for given arguments — the inputs of the program.
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
PRINTF :: "io -> <libc.so.6>{\n  printf -> {string:format, i64:n, -> !?::i32}\n}\n"
LIBC :: "libc -> <libc.so.6>{\n  puts -> {string:s, -> !?::i32}\n  abs -> {i32:n, -> !?::i32}\n  atoi -> {string:s, -> !?::i32}\n  srand -> {u32:seed, -> !?::none}\n}\n"

CASES := []Binary_Case {
	{"known", "greeting -> \"hello\"\nanswer -> 42\n-> answer", {{exit = 42}}},
	{"no production", "a -> 1", {{exit = 0}}},
	{"folded", "-> 2 * 3 + 4 * 5", {{exit = 26}}},
	{"input", "n -> ??::u8\n-> n * 2 + 1", {{args = {"20"}, exit = 41}}},
	{"negative input", "n -> ??::i8\n-> n + 100", {{args = {"-5"}, exit = 95}}},
	{"missing input", "n -> ??::u8\n-> n", {{exit = 2}}},
	{"input out of its layout", "n -> ??::u8\n-> n", {{args = {"300"}, exit = 2}, {args = {"-1"}, exit = 2}, {args = {"255"}, exit = 255}}},
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
	{"iteration", "fact -> {u8:n -> ??  -> n ? {0 -> 1  -> n * fact{n -> n - 1}!}}\n-> fact{n -> 5}!", {{exit = 120}}},
	{"iteration through any step", "half -> {u8:n -> ??  -> n ? {0 -> 0  -> 1 + half{n -> n / 2}!}}\n-> half{n -> ??::u8}!", {{args = {"100"}, exit = 7}, {args = {"0"}, exit = 0}}},
	{"affine context", "g -> {u8:n -> ??  -> n ? {0 -> 1  -> 2 * g{n -> n / 2}! + 1}}\n-> g{n -> ??::u8}!", {{args = {"100"}, exit = 255}}},
	{"window", "fib -> {u8:n -> ??  -> n ? {<2 -> n  -> fib{n -> n - 1}! + fib{n -> n - 2}!}}\n-> fib{n -> ??::u8}! % 256", {{args = {"10"}, exit = 55}, {args = {"0"}, exit = 0}, {args = {"1"}, exit = 1}, {args = {"90"}, exit = 2880067194370816120 % 256}}},
	{"C-finite, with a constant", "t -> {u8:n -> ??  -> n ? {<2 -> 1  -> 3 * t{n -> n - 1}! - 2 * t{n -> n - 2}! + 1}}\n-> t{n -> ??::u8}! % 256", {{args = {"20"}, exit = 1048556 % 256}, {args = {"1"}, exit = 1}}},
	{"C-finite, a double root", "t -> {u8:n -> ??  -> n ? {<2 -> n  -> 4 * t{n -> n - 1}! - 4 * t{n -> n - 2}!}}\n-> t{n -> ??::u8}!", {{args = {"5"}, exit = 80}}},
	{"geometric", "hanoi -> {u8:n -> ??  -> n ? {0 -> 0  -> 2 * hanoi{n -> n - 1}! + 1}}\n-> hanoi{n -> ??::u8}! % 256", {{args = {"7"}, exit = 127}}},
	{"length of an orbit", "half -> {u8:n -> ??  -> n ? {0 -> 0  -> 1 + half{n -> n / 2}!}}\n-> half{n -> ??::u8}!", {{args = {"200"}, exit = 8}, {args = {"1"}, exit = 1}}},
	{"power", "n -> ??::u8\n-> 3 ** (n % 20) % 1000 + (-2) ** 3", {{args = {"13"}, exit = 59}}},
	{"geometric, any base", "t -> {u8:n -> ??  -> n ? {0 -> 1  -> 3 * t{n -> n - 1}! + n}}\n-> t{n -> ??::u8}! % 256", {{args = {"5"}, exit = 422 % 256}}},
	{"orbit by a quotient", "q -> {u8:n -> ??  -> n ? {0 -> 1  -> q{n -> n / 3}! * q{n -> n / 3}! + 1}}\n-> q{n -> ??::u8}! % 256", {{args = {"11"}, exit = 26}, {args = {"30"}, exit = 165}}},
	{"function", "w -> {u8:n -> ??  -> n ? {0 -> 1  -> w{n -> 2 * n / 3}! * w{n -> 2 * n / 3}! + 1}}\n-> w{n -> ??::u8}!", {{args = {"4"}, exit = 26}}},
	{"loop", "_fib -> {\n  n -> 2  i -> 2  prev -> 0  cur -> 1\n  -> i ? {<n -> _fib{n i+1 cur cur+prev}!  -> cur}\n}\nfib -> {\n  n -> 0\n  -> n ? {<2 -> n  -> _fib{n+1}!}\n}\n-> fib{??::u8}!", {{args = {"0"}, exit = 0}, {args = {"10"}, exit = 55}, {args = {"13"}, exit = 233}}},
	{"tail call", "f -> {u32:n -> ??  acc -> 0  -> n ? {0 -> acc  -> f{n -> n - 1  acc -> (acc + n) % 1000}!}}\n-> f{n -> ??::u32}! % 256", {{args = {"10000000"}, exit = 0}, {args = {"10"}, exit = 55}}},
	{"tail call with effects", LIBC + "tick -> {u8:n -> ??  -> n ? {0 -> 0  -> {r -> libc.puts{s -> \"tick\"}!  -> tick{n -> n - 1}!}!}}\n-> tick{n -> ??::u8}!", {{args = {"2"}, stdout = "tick\ntick\n", exit = 0}}},
	// a recursion is an iteration (specs/types.md §5.6): a loop, its effects in the
	// order the equation runs them — up from the base case when the call comes
	// first, down from n when an effect comes before it
	{"effects after the call", PRINTF + "count -> {u8:n -> ??  -> n ? {0 -> 0  -> {a -> count{n -> n - 1}!  -> a + io.printf{format -> \"%d \"  n -> n}!}!}}\n-> count{n -> ??::u8}! % 256", {{args = {"4"}, stdout = "1 2 3 4 ", exit = 8}}},
	{"effects before the call", PRINTF + "say -> {u8:n -> ??  -> n ? {0 -> 0  -> io.printf{format -> \"%d \"  n -> n}! + say{n -> n - 1}!}}\n-> say{n -> ??::u8}! % 256", {{args = {"4"}, stdout = "4 3 2 1 ", exit = 8}, {args = {"0"}, exit = 0}}},
	{"value across the effects", LIBC + "tick -> {u8:n -> ??  -> n ? {0 -> 0  -> {r -> libc.puts{s -> \"tick\"}!  -> 1 + tick{n -> n - 1}!}!}}\n-> tick{n -> ??::u8}! * 10", {{args = {"3"}, stdout = "tick\ntick\ntick\n", exit = 30}}},
	{"product", "fact -> {u8:n -> ??  -> n ? {0 -> 1  -> n * fact{n -> n - 1}!}}\n-> fact{n -> ??::u8}! % 251", {{args = {"5"}, exit = 120}, {args = {"20"}, exit = 2432902008176640000 % 251}}},
	{"recursion with effects", LIBC + "say -> {u8:n -> ??  -> n ? {0 -> 0  -> {r -> libc.puts{s -> \"tick\"}!  -> 1 + say{n -> n - 1}!}!}}\n-> say{n -> ??::u8}!", {{args = {"3"}, stdout = "tick\ntick\ntick\n", exit = 3}, {args = {"0"}, exit = 0}}},
	{"answers of a recursion", LIBC + "cnt -> {u8:n -> ??  -> n ? {0 -> 0  -> libc.abs{n -> -2}! + cnt{n -> n - 1}!}}\n-> cnt{n -> ??::u8}!", {{args = {"4"}, exit = 8}}},
	// beyond the registers the ABI gives arguments, on the stack: to a foreign
	// function, and to a recursion that turns its own around
	{"arguments on the stack", "io -> <libc.so.6>{\n  printf -> {string:format, i64:a, i64:b, i64:c, i64:d, i64:e, i64:f, i64:g, -> !?::i32}\n}\nn -> ??::u8\n-> io.printf{format -> \"%d %d %d %d %d %d %d\"  a -> n  b -> n + 1  c -> n + 2  d -> n + 3  e -> n + 4  f -> n + 5  g -> n + 6}!", {{args = {"10"}, stdout = "10 11 12 13 14 15 16", exit = 20}}},
	// a scope of fields, passed as its fields
	{"scope as a parameter", "Vec -> {(0..99):x (0..99):y}\nwalk -> {\n  u8:n -> ??\n  Vec:p\n  -> n ? {\n    0 -> p.x + p.y\n    -> walk{n -> n - 1  p -> Vec{(p.x + 1) % 100  (p.y + 2) % 100}}!\n  }\n}\n-> walk{n -> ??::u8}!", {{args = {"10"}, exit = 30}, {args = {"0"}, exit = 0}, {args = {"60"}, exit = 80}}},
	{"generic scope as a parameter", "Vec -> {\n  X <- i32\n  Y <- i32\n  X:x\n  Y:y\n}\nBoard -> Vec{X <- 0..99  Y <- 0..99}\nwalk -> {\n  u8:n -> ??\n  Board:p -> Vec{0 0}\n  -> n ? {\n    0 -> p.x + p.y\n    -> walk{n -> n - 1  p -> Vec{(p.x + 1) % 100  (p.y + 2) % 100}}!\n  }\n}\n-> walk{n -> ??::u8}!", {{args = {"10"}, exit = 30}, {args = {"60"}, exit = 80}}},
	{"parameters on the stack", PRINTF +"walk -> {u8:n -> ??  u8:a -> ??  u8:b -> ??  u8:c -> ??  u8:d -> ??  u8:e -> ??  u8:f -> ??  u8:g -> ??  -> n ? {0 -> 0  -> {r -> walk{n -> n - 1  a -> b  b -> c  c -> d  d -> e  e -> f  f -> g  g -> a}!  -> r + io.printf{format -> \"%d \"  n -> g}!}!}}\n-> walk{n -> ??::u8  a -> 1  b -> 2  c -> 3  d -> 4  e -> 5  f -> 6  g -> 7}! % 256", {{args = {"9"}, stdout = "1 7 6 5 4 3 2 1 7 ", exit = 18}}},
	// reading: gets into a buffer malloc gives, fgets from the stream fdopen gives
	{"gets", "io -> <libc.so.6>{\n  malloc -> {u64:size, -> !?::u64}\n  gets -> {u64:buf, -> !?::string}\n  puts -> {string:s, -> !?::i32}\n  atoi -> {string:s, -> !?::i32}\n  fdopen -> {i32:fd, string:mode, -> !?::u64}\n  fgets -> {u64:buf, i32:size, u64:stream, -> !?::string}\n  printf -> {string:format, string:s, -> !?::i32}\n}\nget -> {-> io.gets{buf -> io.malloc{size -> 4096}!}!}\nfirst -> get!\nsecond -> get!\nsaid -> io.puts{s -> second}!\nagain -> io.puts{s -> first}!", {{stdin = "one\ntwo\n", stdout = "two\none\n"}}},
	{"read a number", "io -> <libc.so.6>{\n  malloc -> {u64:size, -> !?::u64}\n  gets -> {u64:buf, -> !?::string}\n  puts -> {string:s, -> !?::i32}\n  atoi -> {string:s, -> !?::i32}\n  fdopen -> {i32:fd, string:mode, -> !?::u64}\n  fgets -> {u64:buf, i32:size, u64:stream, -> !?::string}\n  printf -> {string:format, string:s, -> !?::i32}\n}\nget -> {-> io.gets{buf -> io.malloc{size -> 4096}!}!}\nn -> io.atoi{s -> get!}!\n-> n * 2", {{stdin = "21\n", exit = 42}}},
	{"fgets", "io -> <libc.so.6>{\n  malloc -> {u64:size, -> !?::u64}\n  gets -> {u64:buf, -> !?::string}\n  puts -> {string:s, -> !?::i32}\n  atoi -> {string:s, -> !?::i32}\n  fdopen -> {i32:fd, string:mode, -> !?::u64}\n  fgets -> {u64:buf, i32:size, u64:stream, -> !?::string}\n  printf -> {string:format, string:s, -> !?::i32}\n}\nget -> {-> io.gets{buf -> io.malloc{size -> 4096}!}!}\nstdin -> io.fdopen{fd -> 0  mode -> \"r\"}!\nname -> io.fgets{buf -> io.malloc{size -> 256}!  size -> 256  stream -> stdin}!\nsaid -> io.printf{format -> \"Hello, %s\"  s -> name}!", {{stdin = "Kensai\n", stdout = "Hello, Kensai\n"}}},
	// a scope crosses as C lays out a struct: struct in_addr in an integer register,
	// double complex in two SSE registers
	{"scope packed", "Addr -> {u8:a u8:b u8:c u8:d}\nlibc -> <libc.so.6>{\n  inet_ntoa -> {Addr:addr, -> !?::string}\n}\n-> libc.inet_ntoa{addr -> Addr{192 168 1 42}}!", {{stdout = "192.168.1.42\n"}}},
	{"scope of floats", "Complex -> {f64:re f64:im}\nlibm -> <libm.so.6>{\n  cabs -> {Complex:z, -> !?::f64}\n}\n-> libm.cabs{z -> Complex{3.0 4.0}}!", {{stdout = "5.000000\n"}}},
	{
		"call on one path",
		LIBM + "n -> ??::u8\n-> n ? {0 -> libm.sqrt{x -> 16.0}!  -> 1.0}",
		{{args = {"0"}, stdout = "4.000000\n"}, {args = {"1"}, stdout = "1.000000\n"}},
	},
}

// Build: a backend: the program as an executable at path; "" when built.
Build :: proc(p: ^code.Program, path: string) -> string

// run: each case built by the backend, then run.
run :: proc(t: ^testing.T, build: Build) {
	arena: vmem.Arena
	context.allocator = vmem.arena_allocator(&arena)
	defer vmem.arena_destroy(&arena)
	base, _ := os.temp_directory(context.allocator)
	dir := fmt.tprintf("%s/syntact_code_test_%d", base, os.get_pid())
	os.make_directory_all(dir)
	defer os.remove_all(dir)
	for c, n in CASES {
		k, parsed := kernel.run(c.source)
		if !testing.expectf(t, parsed, "%s: does not parse", c.name) do continue
		prog, err := code.lower_program(&k)
		if !testing.expectf(t, err == "", "%s: %s", c.name, err) do continue
		path := fmt.tprintf("%s/case_%d", dir, n)
		if msg := build(&prog, path); !testing.expectf(t, msg == "", "%s: %s", c.name, msg) do continue
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
