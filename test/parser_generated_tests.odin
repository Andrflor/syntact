// AUTO-GENERATED. DO NOT EDIT.
package compiler_test

import "core:testing"

// run_single_test is provided by parser_test_harness.odin

@(test)
test_simple_typelike_def_0 :: proc(t: ^testing.T) {
	ok, msg := run_single_test("tests/simple_typelike_def.json")
	testing.expectf(t, ok, "%s", msg)
}

@(test)
test_simple_pattern_1 :: proc(t: ^testing.T) {
	ok, msg := run_single_test("tests/simple_pattern.json")
	testing.expectf(t, ok, "%s", msg)
}

@(test)
test_simple_pointing_2 :: proc(t: ^testing.T) {
	ok, msg := run_single_test("tests/simple_pointing.json")
	testing.expectf(t, ok, "%s", msg)
}

@(test)
test_resonant_3 :: proc(t: ^testing.T) {
	ok, msg := run_single_test("tests/resonant.json")
	testing.expectf(t, ok, "%s", msg)
}

@(test)
test_complex_4 :: proc(t: ^testing.T) {
	ok, msg := run_single_test("tests/complex.json")
	testing.expectf(t, ok, "%s", msg)
}

@(test)
test_pattern_5 :: proc(t: ^testing.T) {
	ok, msg := run_single_test("tests/pattern.json")
	testing.expectf(t, ok, "%s", msg)
}

@(test)
test_simple_reference_6 :: proc(t: ^testing.T) {
	ok, msg := run_single_test("tests/simple_reference.json")
	testing.expectf(t, ok, "%s", msg)
}

