package code_x64

import cases "../cases"
import "core:testing"

@(test)
test_binaries :: proc(t: ^testing.T) {
	cases.run(t, executable)
}
