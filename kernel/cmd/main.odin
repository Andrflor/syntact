package main

import arena "../../arena"
import syn "../../syntax"
import kernel ".."
import "core:fmt"
import "core:os"

// kernel FILE: the type of each binding of the file, with its size in bits and the
// places it keeps in memory, then the
// errors.
main :: proc() {
	if len(os.args) < 2 {
		fmt.eprintln("usage: kernel FILE")
		os.exit(2)
	}
	// the whole check in one arena (arena/arena.odin)
	check: arena.Arena
	if err := arena.init(&check); err != nil {
		fmt.eprintln("no memory for the check:", err)
		os.exit(2)
	}
	context.allocator = arena.allocator(&check)
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
	for b in k.root.bindings {
		name := b.name == "" ? "_" : b.name
		t := kernel.binding_type(&k, b)
		m := kernel.memory(&k, t)
		kept := len(m.places) == 0 ? "" : fmt.tprintf(", keeps %d places: %s bits", len(m.places), kernel.print_size(m.size))
		fmt.printfln("%s: %s  (%s bits%s)", name, kernel.print_type(t), kernel.print_size(kernel.size(&k, t)), kept)
	}
	for e in k.errors {
		pos := syn.span_to_position(k.ast, e.span.start)
		fmt.printfln("  %v %d:%d  %s", e.kind, pos.line, pos.column, e.message)
	}
	os.exit(len(k.errors) == 0 ? 0 : 1)
}
