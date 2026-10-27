package main

import code ".."
import c "../c"
import calc "../calc"
import x64 "../x64"
import kernel "../../kernel"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

// THE BENCH
//
// Each program, as the x86-64 backend writes it; as the C compiler writes it at -O3
// from a C loop written naively, the same loop on the same types; and from the
// program as C — the normal form of its computations without lanes, the C
// compiler's own vectors; and the normal form in lanes —; run on the same
// arguments: the best time of a few runs, against the naive C and the best C, and
// the code they exit with, which must be the same.
//
//   bench [DIR]: the executables in DIR, the temporary directory otherwise.

// Bench: a loop over n down to 0, its accumulator taking step at each turn; and the
// same step in C, naively.
Bench :: struct {
	name:  string,
	step:  string,
	naive: string,
	args:  []string,
}

LOOP :: [2]string{"f -> {u32:n -> ??  acc -> 0  -> n ? {0 -> acc  -> f{n -> n - 1  acc -> ", "}!}}\n-> f{n -> ??::u32}!"}

// NAIVE: the C loop, written naively, around a step.
NAIVE :: [2]string {
	`#include <stdint.h>
#include <stdlib.h>

int main(int argc, char **argv) {
    if (argc < 2) return 2;
    long long input = strtoll(argv[1], NULL, 10);
    if (input < 0 || input > 4294967295LL) return 2;
    int64_t acc = 0;
    for (uint32_t n = (uint32_t)input; n != 0; n--) {
        `,
	`
    }
    return (int)(acc & 255);
}
`,
}

BENCHES := []Bench {
	{"remainders", "acc + n % 7", "acc += n % 7;", {"300000000"}},
	{"masks", "acc + (n [&] 255) * 3", "acc += (n & 255) * 3;", {"300000000"}},
	{"squares", "acc ^ (n * n + 12345)", "acc ^= (int64_t)((uint64_t)n * n + 12345);", {"300000000"}},
	{"quotients", "acc ^ (n / 10)", "acc ^= n / 10;", {"300000000"}},
	{"branches", "acc + ((n % 3) ? {0 -> n  -> 1})", "acc += n % 3 == 0 ? n : 1;", {"300000000"}},
	{"bytes", "acc ^ ((n [&] 255) * 3)", "acc ^= (n & 255) * 3;", {"300000000"}},
}

RUNS :: 3

main :: proc() {
	dir := len(os.args) > 1 ? os.args[1] : fmt.tprintf("%s/syntact_bench_%d", os.temp_directory(context.allocator) or_else "/tmp", os.get_pid())
	os.make_directory_all(dir)
	fmt.printfln("%-12s %10s %10s %10s %10s %8s %8s", "", "x86-64", "C naive", "C normal", "C lanes", "÷naive", "÷best")
	for b, n in BENCHES {
		k, parsed := kernel.run(strings.concatenate({LOOP[0], b.step, LOOP[1]}))
		if !parsed || len(k.errors) > 0 {
			fmt.printfln("%-12s does not check", b.name)
			continue
		}
		direct, err := code.lower_program(&k)
		if err != "" {
			fmt.printfln("%-12s %s", b.name, err)
			continue
		}
		// 0: x86-64, 1: the naive C, 2: the normal form, 3: in lanes
		times: [4]f64
		exits: [4]int
		failed := ""
		for t in 0 ..< 4 {
			path := fmt.tprintf("%s/%d_%d", dir, n, t)
			msg: string
			switch t {
			case 1:
				msg = naive(strings.concatenate({NAIVE[0], b.naive, NAIVE[1]}), path)
			case:
				normal, optimized := calc.optimize(&direct, ([]^calc.Costs{&calc.X64, nil, &calc.GCC, &calc.C})[t])
				msg = optimized
				if msg == "" do msg = t == 0 ? x64.executable(&normal, path) : c.executable(&normal, path)
			}
			if msg != "" {
				failed = msg
				break
			}
			times[t], exits[t] = best(path, b.args)
		}
		if failed != "" {
			fmt.printfln("%-12s %s", b.name, failed)
			continue
		}
		same := exits[0] == exits[1] && exits[1] == exits[2] && exits[2] == exits[3] ? "" : fmt.tprintf("  exits differ: %v", exits)
		ms :: proc(t: f64) -> string {return fmt.tprintf("%.1fms", t)}
		ratio :: proc(a, b: f64) -> string {return fmt.tprintf("%.2f", a / b)}
		fmt.printfln("%-12s %10s %10s %10s %10s %8s %8s%s", b.name, ms(times[0]), ms(times[1]), ms(times[2]), ms(times[3]), ratio(times[0], times[1]), ratio(times[0], min(times[1], times[2], times[3])), same)
	}
}

// naive: the C source, compiled at path by the C compiler at -O3.
naive :: proc(source, path: string) -> string {
	file := fmt.tprintf("%s.c", path)
	if os.write_entire_file(file, transmute([]u8)source) != nil do return "the C file cannot be written"
	cc := os.get_env("CC", context.allocator)
	command := []string{cc != "" ? cc : "cc", "-std=c11", "-O3", "-Wall", "-Wextra", "-Werror", file, "-o", path}
	state, _, stderr, failed := os.process_exec(os.Process_Desc{command = command}, context.allocator)
	if failed != nil do return fmt.tprintf("the C compiler does not run: %v", failed)
	if state.exit_code != 0 do return fmt.tprintf("the C compiler fails:\n%s", string(stderr))
	return ""
}

// best: the least time of RUNS runs, in milliseconds, and the code it exits with.
best :: proc(path: string, args: []string) -> (ms: f64, exit: int) {
	command := make([dynamic]string)
	append(&command, path)
	append(&command, ..args)
	ms = max(f64)
	for _ in 0 ..< RUNS {
		start := time.now()
		state, _, _, failed := os.process_exec(os.Process_Desc{command = command[:]}, context.allocator)
		elapsed := time.duration_milliseconds(time.since(start))
		if failed != nil do return -1, -1
		ms = min(ms, elapsed)
		exit = state.exit_code
	}
	return
}
