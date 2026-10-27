package code_x64

import code ".."
import calc "../calc"
import cases "../cases"
import "core:testing"

// The cases every backend runs, as the normal form of their computations, built
// into executables.
@(test)
test_binaries :: proc(t: ^testing.T) {
	cases.run(t, proc(p: ^code.Program, path: string) -> string {
		normal, failed := calc.optimize(p, &calc.X64)
		if failed != "" do return failed
		return executable(&normal, path)
	})
}
