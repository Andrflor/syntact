package main

import code ".."
import c "../c"
import calc "../calc"
import x64 "../x64"
import arena "../../arena"
import kernel "../../kernel"
import "core:fmt"
import "core:os"

// code FILE [-l | -o OUT | -c OUT.c]: the code of the program the file writes, as
// the normal form of its computations (code/calc); with -l, as the kernel lowers
// it, before; with -o, the executable for x86-64 Linux; with -c, the program as C.
main :: proc() {
	usage := len(os.args) == 2 || len(os.args) == 3 && os.args[2] == "-l" || len(os.args) == 4 && (os.args[2] == "-o" || os.args[2] == "-c")
	if !usage {
		fmt.eprintln("usage: code FILE [-l | -o OUT | -c OUT.c]")
		os.exit(2)
	}
	// the whole compile in one arena (arena/arena.odin)
	compile: arena.Arena
	if err := arena.init(&compile); err != nil {
		fmt.eprintln("no memory for the compile:", err)
		os.exit(2)
	}
	context.allocator = arena.allocator(&compile)
	context.temp_allocator = context.allocator
	data, err := os.read_entire_file(os.args[1], context.allocator)
	if err != nil {
		fmt.eprintln("cannot read:", os.args[1])
		os.exit(2)
	}
	k, parsed := kernel.run(string(data))
	if !parsed {
		fmt.eprintln("parse error")
		os.exit(1)
	}
	for e in k.errors do fmt.eprintfln("%v  %s", e.kind, e.message)
	direct, msg := code.lower_program(&k)
	if msg != "" {
		fmt.eprintln(msg)
		os.exit(1)
	}
	if len(os.args) == 3 {
		fmt.print(code.print_program(&direct))
		return
	}
	costs := len(os.args) == 4 && os.args[2] == "-c" ? &calc.C : &calc.X64
	prog, failed := calc.optimize(&direct, costs)
	if failed != "" {
		fmt.eprintln(failed)
		os.exit(1)
	}
	if len(os.args) == 2 {
		fmt.print(code.print_program(&prog))
		return
	}
	write := os.args[2] == "-o" ? x64.executable : c.write
	if msg := write(&prog, os.args[3]); msg != "" {
		fmt.eprintln(msg)
		os.exit(1)
	}
}
