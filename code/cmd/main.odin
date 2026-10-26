package main

import code ".."
import x64 "../x64"
import kernel "../../kernel"
import "core:fmt"
import "core:os"

// code FILE [-o OUT]: the code of the program the file writes; with -o, the
// executable for x86-64 Linux.
main :: proc() {
	if len(os.args) < 2 {
		fmt.eprintln("usage: code FILE [-o OUT]")
		os.exit(2)
	}
	out := ""
	if len(os.args) >= 4 && os.args[2] == "-o" do out = os.args[3]
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
	prog, msg := code.lower_program(&k)
	if msg != "" {
		fmt.eprintln(msg)
		os.exit(1)
	}
	if out == "" {
		fmt.print(code.print_program(&prog))
		return
	}
	if msg := x64.executable(&prog, out); msg != "" {
		fmt.eprintln(msg)
		os.exit(1)
	}
}
