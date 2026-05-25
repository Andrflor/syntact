// AUTO-GENERATED. DO NOT EDIT.
package analyzer_test

import "core:testing"

@(test)
test_implicit_carve_valid_both_0 :: proc(t: ^testing.T) {
	run_analyzer_test("tests/implicit_carve_valid_both.json", t)
}

@(test)
test_implicit_carve_missing_property_1 :: proc(t: ^testing.T) {
	run_analyzer_test("tests/implicit_carve_missing_property.json", t)
}

@(test)
test_implicit_carve_non_scope_2 :: proc(t: ^testing.T) {
	run_analyzer_test("tests/implicit_carve_non_scope.json", t)
}

@(test)
test_typecheck_i32_valid_3 :: proc(t: ^testing.T) {
	run_analyzer_test("tests/typecheck_i32_valid.json", t)
}

@(test)
test_implicit_carve_valid_numeric_4 :: proc(t: ^testing.T) {
	run_analyzer_test("tests/implicit_carve_valid_numeric.json", t)
}

@(test)
test_constraint_product_constraint_carve_fail_5 :: proc(t: ^testing.T) {
	run_analyzer_test("tests/constraint_product_constraint_carve_fail.json", t)
}

@(test)
test_scope_add_property_base_6 :: proc(t: ^testing.T) {
	run_analyzer_test("tests/scope_add_property_base.json", t)
}

@(test)
test_typecheck_u8_string_7 :: proc(t: ^testing.T) {
	run_analyzer_test("tests/typecheck_u8_string.json", t)
}

@(test)
test_constraint_product_constraint_vs_value_distinction_8 :: proc(t: ^testing.T) {
	run_analyzer_test("tests/constraint_product_constraint_vs_value_distinction.json", t)
}

@(test)
test_constraint_scope_in_string_9 :: proc(t: ^testing.T) {
	run_analyzer_test("tests/constraint_scope_in_string.json", t)
}

@(test)
test_typecheck_i32_overflow_10 :: proc(t: ^testing.T) {
	run_analyzer_test("tests/typecheck_i32_overflow.json", t)
}

@(test)
test_implicit_carve_missing_ordinal_11 :: proc(t: ^testing.T) {
	run_analyzer_test("tests/implicit_carve_missing_ordinal.json", t)
}

@(test)
test_constraint_product_value_structural_wrong_param_fail_12 :: proc(t: ^testing.T) {
	run_analyzer_test("tests/constraint_product_value_structural_wrong_param_fail.json", t)
}

@(test)
test_typecheck_char_valid_13 :: proc(t: ^testing.T) {
	run_analyzer_test("tests/typecheck_char_valid.json", t)
}

@(test)
test_implicit_carve_numeric_string_14 :: proc(t: ^testing.T) {
	run_analyzer_test("tests/implicit_carve_numeric_string.json", t)
}

@(test)
test_typecheck_no_constraint_15 :: proc(t: ^testing.T) {
	run_analyzer_test("tests/typecheck_no_constraint.json", t)
}

@(test)
test_constraint_builtin_array_valid_16 :: proc(t: ^testing.T) {
	run_analyzer_test("tests/constraint_builtin_array_valid.json", t)
}

@(test)
test_typecheck_u8_bool_17 :: proc(t: ^testing.T) {
	run_analyzer_test("tests/typecheck_u8_bool.json", t)
}

@(test)
test_typecheck_bool_string_18 :: proc(t: ^testing.T) {
	run_analyzer_test("tests/typecheck_bool_string.json", t)
}

@(test)
test_scope_add_property_override_19 :: proc(t: ^testing.T) {
	run_analyzer_test("tests/scope_add_property_override.json", t)
}

@(test)
test_typecheck_string_bool_20 :: proc(t: ^testing.T) {
	run_analyzer_test("tests/typecheck_string_bool.json", t)
}

@(test)
test_constraint_product_value_literal_fail_21 :: proc(t: ^testing.T) {
	run_analyzer_test("tests/constraint_product_value_literal_fail.json", t)
}

@(test)
test_typecheck_u32_overflow_22 :: proc(t: ^testing.T) {
	run_analyzer_test("tests/typecheck_u32_overflow.json", t)
}

@(test)
test_typecheck_i8_overflow_23 :: proc(t: ^testing.T) {
	run_analyzer_test("tests/typecheck_i8_overflow.json", t)
}

@(test)
test_typecheck_i64_valid_large_24 :: proc(t: ^testing.T) {
	run_analyzer_test("tests/typecheck_i64_valid_large.json", t)
}

@(test)
test_typecheck_u8_scope_25 :: proc(t: ^testing.T) {
	run_analyzer_test("tests/typecheck_u8_scope.json", t)
}

@(test)
test_typecheck_constraint_only_26 :: proc(t: ^testing.T) {
	run_analyzer_test("tests/typecheck_constraint_only.json", t)
}

@(test)
test_constraint_scope_element_direct_27 :: proc(t: ^testing.T) {
	run_analyzer_test("tests/constraint_scope_element_direct.json", t)
}

@(test)
test_typecheck_i16_valid_28 :: proc(t: ^testing.T) {
	run_analyzer_test("tests/typecheck_i16_valid.json", t)
}

@(test)
test_typecheck_string_valid_29 :: proc(t: ^testing.T) {
	run_analyzer_test("tests/typecheck_string_valid.json", t)
}

@(test)
test_constraint_product_value_carve_pass_30 :: proc(t: ^testing.T) {
	run_analyzer_test("tests/constraint_product_value_carve_pass.json", t)
}

@(test)
test_constraint_product_value_carve_wrong_param_fail_31 :: proc(t: ^testing.T) {
	run_analyzer_test("tests/constraint_product_value_carve_wrong_param_fail.json", t)
}

@(test)
test_typecheck_u8_overflow_32 :: proc(t: ^testing.T) {
	run_analyzer_test("tests/typecheck_u8_overflow.json", t)
}

@(test)
test_typecheck_u16_valid_33 :: proc(t: ^testing.T) {
	run_analyzer_test("tests/typecheck_u16_valid.json", t)
}

@(test)
test_typecheck_f32_valid_34 :: proc(t: ^testing.T) {
	run_analyzer_test("tests/typecheck_f32_valid.json", t)
}

@(test)
test_typecheck_bool_valid_true_35 :: proc(t: ^testing.T) {
	run_analyzer_test("tests/typecheck_bool_valid_true.json", t)
}

@(test)
test_typecheck_u16_overflow_36 :: proc(t: ^testing.T) {
	run_analyzer_test("tests/typecheck_u16_overflow.json", t)
}

@(test)
test_constraint_int_in_compound_array_37 :: proc(t: ^testing.T) {
	run_analyzer_test("tests/constraint_int_in_compound_array.json", t)
}

@(test)
test_constraint_product_constraint_mixed_fail_38 :: proc(t: ^testing.T) {
	run_analyzer_test("tests/constraint_product_constraint_mixed_fail.json", t)
}

@(test)
test_typecheck_string_int_39 :: proc(t: ^testing.T) {
	run_analyzer_test("tests/typecheck_string_int.json", t)
}

@(test)
test_typecheck_f64_valid_40 :: proc(t: ^testing.T) {
	run_analyzer_test("tests/typecheck_f64_valid.json", t)
}

@(test)
test_constraint_product_constraint_scope_literal_pass_41 :: proc(t: ^testing.T) {
	run_analyzer_test("tests/constraint_product_constraint_scope_literal_pass.json", t)
}

@(test)
test_typecheck_i8_valid_max_42 :: proc(t: ^testing.T) {
	run_analyzer_test("tests/typecheck_i8_valid_max.json", t)
}

@(test)
test_typecheck_u8_float_43 :: proc(t: ^testing.T) {
	run_analyzer_test("tests/typecheck_u8_float.json", t)
}

@(test)
test_constraint_scope_in_builtin_array_44 :: proc(t: ^testing.T) {
	run_analyzer_test("tests/constraint_scope_in_builtin_array.json", t)
}

@(test)
test_typecheck_bool_valid_false_45 :: proc(t: ^testing.T) {
	run_analyzer_test("tests/typecheck_bool_valid_false.json", t)
}

@(test)
test_constraint_product_simple_constraint_pass_46 :: proc(t: ^testing.T) {
	run_analyzer_test("tests/constraint_product_simple_constraint_pass.json", t)
}

@(test)
test_typecheck_char_overflow_47 :: proc(t: ^testing.T) {
	run_analyzer_test("tests/typecheck_char_overflow.json", t)
}

@(test)
test_constraint_product_simple_constraint_fail_48 :: proc(t: ^testing.T) {
	run_analyzer_test("tests/constraint_product_simple_constraint_fail.json", t)
}

@(test)
test_typecheck_u32_valid_49 :: proc(t: ^testing.T) {
	run_analyzer_test("tests/typecheck_u32_valid.json", t)
}

@(test)
test_constraint_product_constraint_scope_literal_fail_50 :: proc(t: ^testing.T) {
	run_analyzer_test("tests/constraint_product_constraint_scope_literal_fail.json", t)
}

@(test)
test_typecheck_u8_valid_zero_51 :: proc(t: ^testing.T) {
	run_analyzer_test("tests/typecheck_u8_valid_zero.json", t)
}

@(test)
test_typecheck_u64_negative_52 :: proc(t: ^testing.T) {
	run_analyzer_test("tests/typecheck_u64_negative.json", t)
}

@(test)
test_constraint_scope_in_compound_array_53 :: proc(t: ^testing.T) {
	run_analyzer_test("tests/constraint_scope_in_compound_array.json", t)
}

@(test)
test_constraint_product_value_structural_pass_54 :: proc(t: ^testing.T) {
	run_analyzer_test("tests/constraint_product_value_structural_pass.json", t)
}

@(test)
test_typecheck_i32_float_55 :: proc(t: ^testing.T) {
	run_analyzer_test("tests/typecheck_i32_float.json", t)
}

@(test)
test_typecheck_bool_int_56 :: proc(t: ^testing.T) {
	run_analyzer_test("tests/typecheck_bool_int.json", t)
}

@(test)
test_typecheck_f64_int_57 :: proc(t: ^testing.T) {
	run_analyzer_test("tests/typecheck_f64_int.json", t)
}

@(test)
test_typecheck_i16_overflow_58 :: proc(t: ^testing.T) {
	run_analyzer_test("tests/typecheck_i16_overflow.json", t)
}

@(test)
test_typecheck_f32_string_59 :: proc(t: ^testing.T) {
	run_analyzer_test("tests/typecheck_f32_string.json", t)
}

@(test)
test_implicit_carve_valid_ordinal_60 :: proc(t: ^testing.T) {
	run_analyzer_test("tests/implicit_carve_valid_ordinal.json", t)
}

@(test)
test_constraint_compound_array_valid_61 :: proc(t: ^testing.T) {
	run_analyzer_test("tests/constraint_compound_array_valid.json", t)
}

@(test)
test_constraint_product_constraint_named_scope_pass_62 :: proc(t: ^testing.T) {
	run_analyzer_test("tests/constraint_product_constraint_named_scope_pass.json", t)
}

@(test)
test_constraint_nested_scope_in_array_63 :: proc(t: ^testing.T) {
	run_analyzer_test("tests/constraint_nested_scope_in_array.json", t)
}

@(test)
test_scope_add_property_extension_64 :: proc(t: ^testing.T) {
	run_analyzer_test("tests/scope_add_property_extension.json", t)
}

@(test)
test_typecheck_u8_valid_max_65 :: proc(t: ^testing.T) {
	run_analyzer_test("tests/typecheck_u8_valid_max.json", t)
}

