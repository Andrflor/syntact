// AUTO-GENERATED. DO NOT EDIT.
package compiler_test

import "core:testing"

// run_single_test is provided by parser_test_harness.odin

@(test)
test_resonant_0 :: proc(t: ^testing.T) {
	run_test("tests/resonant.json", t)
}

@(test)
test_simple_typelike_def_1 :: proc(t: ^testing.T) {
	run_test("tests/simple_typelike_def.json", t)
}

@(test)
test_pattern_2 :: proc(t: ^testing.T) {
	run_test("tests/pattern.json", t)
}

@(test)
test_simple_reference_3 :: proc(t: ^testing.T) {
	run_test("tests/simple_reference.json", t)
}

@(test)
test_refinement_4 :: proc(t: ^testing.T) {
	run_test("tests/refinement.json", t)
}

@(test)
test_complex_5 :: proc(t: ^testing.T) {
	run_test("tests/complex.json", t)
}

@(test)
test_simple_pointing_6 :: proc(t: ^testing.T) {
	run_test("tests/simple_pointing.json", t)
}

@(test)
test_simple_pattern_7 :: proc(t: ^testing.T) {
	run_test("tests/simple_pattern.json", t)
}
