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
// Each program, as the x86-64 backend writes it, and as the C compiler writes it at
// -O3 from the program as C — each from the normal form of its computations for its
// machine —, run on the same arguments: the best time of a few runs, and the code
// they exit with, which must be the same.
//
//   bench [DIR]: the executables in DIR, the temporary directory otherwise.

// Bench: a loop over n down to 0, its accumulator taking step at each turn.
Bench :: struct {
	name: string,
	step: string,
	args: []string,
}

LOOP :: [2]string{"f -> {u32:n -> ??  acc -> 0  -> n ? {0 -> acc  -> f{n -> n - 1  acc -> ", "}!}}\n-> f{n -> ??::u32}!"}

BENCHES := []Bench {
	{"remainders", "acc + n % 7", {"300000000"}},
	{"masks", "acc + (n [&] 255) * 3", {"300000000"}},
	{"squares", "acc ^ (n * n + 12345)", {"300000000"}},
	{"quotients", "acc ^ (n / 10)", {"300000000"}},
	{"branches", "acc + ((n % 3) ? {0 -> n  -> 1})", {"300000000"}},
}

RUNS :: 3

main :: proc() {
	dir := len(os.args) > 1 ? os.args[1] : fmt.tprintf("%s/syntact_bench_%d", os.temp_directory(context.allocator) or_else "/tmp", os.get_pid())
	os.make_directory_all(dir)
	fmt.printfln("%-12s %12s %12s %8s", "", "x86-64", "C -O3", "ratio")
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
		mine, mine_failed := calc.optimize(&direct, &calc.X64)
		theirs, theirs_failed := calc.optimize(&direct, &calc.C)
		if mine_failed != "" || theirs_failed != "" {
			fmt.printfln("%-12s %s%s", b.name, mine_failed, theirs_failed)
			continue
		}
		ours := fmt.tprintf("%s/%d_x64", dir, n)
		gcc := fmt.tprintf("%s/%d_c", dir, n)
		if msg := x64.executable(&mine, ours); msg != "" {
			fmt.printfln("%-12s %s", b.name, msg)
			continue
		}
		if msg := c.executable(&theirs, gcc); msg != "" {
			fmt.printfln("%-12s %s", b.name, msg)
			continue
		}
		t_ours, exit_ours := best(ours, b.args)
		t_gcc, exit_gcc := best(gcc, b.args)
		same := exit_ours == exit_gcc ? "" : fmt.tprintf("  exits differ: %d, %d", exit_ours, exit_gcc)
		fmt.printfln("%-12s %12s %12s %8s%s", b.name, fmt.tprintf("%.1fms", t_ours), fmt.tprintf("%.1fms", t_gcc), fmt.tprintf("%.2f", t_ours / t_gcc), same)
	}
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
