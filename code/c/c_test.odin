package code_c

import cases "../cases"
import "core:testing"

// The cases every backend runs, as C compiled by the C compiler.
@(test)
test_binaries :: proc(t: ^testing.T) {
	cases.run(t, executable)
}
