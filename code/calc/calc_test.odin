package code_calc

import code ".."
import cases "../cases"
import kernel "../../kernel"
import vmem "core:mem/virtual"
import "core:slice"
import "core:testing"

// The programs the interpreter runs, as the kernel lowers them and as the normal
// form of their computations: the same runs.
@(test)
test_interpreted :: proc(t: ^testing.T) {
	arena: vmem.Arena
	context.allocator = vmem.arena_allocator(&arena)
	defer vmem.arena_destroy(&arena)
	symbols := cases.symbols()
	for c in cases.CODE_CASES {
		k, parsed := kernel.run(c.source)
		if !testing.expectf(t, parsed, "%s: does not parse", c.name) do continue
		direct, err := code.lower_program(&k)
		if c.error != "" {
			testing.expectf(t, err == c.error, "%s: lowered with %q, expected %q", c.name, err, c.error)
			continue
		}
		if !testing.expectf(t, err == "", "%s: %s", c.name, err) do continue
		normal, failed := optimize(&direct, &X64)
		if !testing.expectf(t, failed == "", "%s: %s\n%s", c.name, failed, code.print_program(&direct)) do continue
		for &prog, form in ([]code.Program{direct, normal}) {
			name := form == 0 ? "lowered" : "normal form"
			run, failed := code.interpret(&prog, c.inputs, symbols)
			if !testing.expectf(t, failed == "", "%s, %s: %s\n%s", c.name, name, failed, code.print_program(&prog)) do continue
			switch prog.funcs[0].result {
			case .Int, .None:
				testing.expectf(t, run.result.int == c.int, "%s, %s: %d, expected %d\n%s", c.name, name, run.result.int, c.int, code.print_program(&prog))
			case .Real:
				testing.expectf(t, abs(run.result.real - c.real) < 1e-12, "%s, %s: %v, expected %v\n%s", c.name, name, run.result.real, c.real, code.print_program(&prog))
			case .Text:
				testing.expectf(t, run.result.text == c.text, "%s, %s: %q, expected %q", c.name, name, run.result.text, c.text)
			}
			testing.expectf(t, slice.equal(run.calls[:], c.calls), "%s, %s: called %v, expected %v", c.name, name, run.calls[:], c.calls)
		}
	}
}
