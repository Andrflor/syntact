package main

import code ".."
import kernel "../../kernel"
import "core:fmt"
import "core:os"

// code FILE: the code of the program the file writes.
main :: proc() {
	if len(os.args) < 2 {
		fmt.eprintln("usage: code FILE")
		os.exit(2)
	}
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
	fmt.print(code.print_program(&prog))
}
