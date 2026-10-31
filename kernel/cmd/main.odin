package main

import syn "../../syntax"
import kernel ".."
import "core:fmt"
import "core:os"

// kernel FILE: the type of each binding of the file, with its size in bits, then the
// errors.
main :: proc() {
	if len(os.args) < 2 {
		fmt.eprintln("usage: kernel FILE")
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
	for b in k.root.bindings {
		name := b.name == "" ? "_" : b.name
		t := kernel.binding_type(&k, b)
		fmt.printfln("%s: %s  (%s bits)", name, kernel.print_type(t), kernel.print_type(kernel.size(&k, t)))
	}
	for e in k.errors {
		pos := syn.span_to_position(k.ast, e.span.start)
		fmt.printfln("  %v %d:%d  %s", e.kind, pos.line, pos.column, e.message)
	}
	os.exit(len(k.errors) == 0 ? 0 : 1)
}
