package main

import syn "../../compiler"
import kernel ".."
import "core:fmt"
import "core:os"

// kernel FILE : imprime le scope du fichier, tel qu'écrit puis ses types, et les erreurs.
main :: proc() {
	if len(os.args) < 2 {
		fmt.eprintln("usage: kernel FILE")
		os.exit(2)
	}
	data, err := os.read_entire_file(os.args[1], context.allocator)
	if err != nil {
		fmt.eprintln("lecture impossible:", os.args[1])
		os.exit(2)
	}
	program, k, parsed := kernel.run(string(data))
	if !parsed {
		fmt.eprintln("erreur de parse")
		os.exit(1)
	}
	fmt.println(kernel.print_expr(kernel.new_expr(program)))
	fmt.println(kernel.print_type(kernel.new_expr(program)))
	for e in k.errors {
		pos := syn.span_to_position(k.ast, e.span.start)
		fmt.printf("  %v %d:%d  %s", e.kind, pos.line, pos.column, e.message)
		if e.origin != e.span {
			src := syn.span_to_position(k.ast, e.origin.start)
			fmt.printf("  (écrit en %d:%d)", src.line, src.column)
		}
		fmt.println()
	}
	os.exit(len(k.errors) == 0 ? 0 : 1)
}
