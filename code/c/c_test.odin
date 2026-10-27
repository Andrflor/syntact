package code_c

import code ".."
import calc "../calc"
import cases "../cases"
import "core:testing"

// The cases every backend runs, as the normal form of their computations, written
// as C and compiled by the C compiler.
@(test)
test_binaries :: proc(t: ^testing.T) {
	cases.run(t, proc(p: ^code.Program, path: string) -> string {
		normal, failed := calc.optimize(p, &calc.X64)
		if failed != "" do return failed
		return executable(&normal, path)
	})
}
