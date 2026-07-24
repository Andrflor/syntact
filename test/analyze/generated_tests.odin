// AUTO-GENERATED. DO NOT EDIT.
package analyze_test

import "core:testing"

@(test)
test_invalid_property_name_integer_0 :: proc(t: ^testing.T) {
	run_analyze_test("tests/invalid_property_name_integer.json", t)
}

@(test)
test_typecheck_u8_overflow_1 :: proc(t: ^testing.T) {
	run_analyze_test("tests/typecheck_u8_overflow.json", t)
}

@(test)
test_typecheck_bool_negate_fail_2 :: proc(t: ^testing.T) {
	run_analyze_test("tests/typecheck_bool_negate_fail.json", t)
}

@(test)
test_negrange_satisfy_invalid_3 :: proc(t: ^testing.T) {
	run_analyze_test("tests/negrange_satisfy_invalid.json", t)
}

@(test)
test_typecheck_f32_valid_4 :: proc(t: ^testing.T) {
	run_analyze_test("tests/typecheck_f32_valid.json", t)
}

@(test)
test_typecheck_bool_int_5 :: proc(t: ^testing.T) {
	run_analyze_test("tests/typecheck_bool_int.json", t)
}

@(test)
test_typecheck_bool_valid_true_6 :: proc(t: ^testing.T) {
	run_analyze_test("tests/typecheck_bool_valid_true.json", t)
}

@(test)
test_typecheck_i32_valid_7 :: proc(t: ^testing.T) {
	run_analyze_test("tests/typecheck_i32_valid.json", t)
}

@(test)
test_typecheck_bool_union_valid_8 :: proc(t: ^testing.T) {
	run_analyze_test("tests/typecheck_bool_union_valid.json", t)
}

@(test)
test_typecheck_u8_float_9 :: proc(t: ^testing.T) {
	run_analyze_test("tests/typecheck_u8_float.json", t)
}

@(test)
test_invalid_constraint_name_paren_expr_10 :: proc(t: ^testing.T) {
	run_analyze_test("tests/invalid_constraint_name_paren_expr.json", t)
}

@(test)
test_typecheck_u8_scope_11 :: proc(t: ^testing.T) {
	run_analyze_test("tests/typecheck_u8_scope.json", t)
}

@(test)
test_constraint_product_value_carve_wrong_param_fail_12 :: proc(t: ^testing.T) {
	run_analyze_test("tests/constraint_product_value_carve_wrong_param_fail.json", t)
}

@(test)
test_constraint_product_value_carve_pass_13 :: proc(t: ^testing.T) {
	run_analyze_test("tests/constraint_product_value_carve_pass.json", t)
}

@(test)
test_div_int_by_safe_const_14 :: proc(t: ^testing.T) {
	run_analyze_test("tests/div_int_by_safe_const.json", t)
}

@(test)
test_default_bool_only_15 :: proc(t: ^testing.T) {
	run_analyze_test("tests/default_bool_only.json", t)
}

@(test)
test_valid_colored_binding_name_16 :: proc(t: ^testing.T) {
	run_analyze_test("tests/valid_colored_binding_name.json", t)
}

@(test)
test_typecheck_u8_string_17 :: proc(t: ^testing.T) {
	run_analyze_test("tests/typecheck_u8_string.json", t)
}

@(test)
test_invalid_property_name_chained_integer_18 :: proc(t: ^testing.T) {
	run_analyze_test("tests/invalid_property_name_chained_integer.json", t)
}

@(test)
test_implicit_carve_missing_property_19 :: proc(t: ^testing.T) {
	run_analyze_test("tests/implicit_carve_missing_property.json", t)
}

@(test)
test_constraint_product_value_structural_wrong_param_fail_20 :: proc(t: ^testing.T) {
	run_analyze_test("tests/constraint_product_value_structural_wrong_param_fail.json", t)
}

@(test)
test_valid_plain_binding_name_21 :: proc(t: ^testing.T) {
	run_analyze_test("tests/valid_plain_binding_name.json", t)
}

@(test)
test_typecheck_bool_singleton_fail_22 :: proc(t: ^testing.T) {
	run_analyze_test("tests/typecheck_bool_singleton_fail.json", t)
}

@(test)
test_constraint_product_constraint_carve_fail_23 :: proc(t: ^testing.T) {
	run_analyze_test("tests/constraint_product_constraint_carve_fail.json", t)
}

@(test)
test_constraint_scope_in_string_24 :: proc(t: ^testing.T) {
	run_analyze_test("tests/constraint_scope_in_string.json", t)
}

@(test)
test_collapse_property_resolves_25 :: proc(t: ^testing.T) {
	run_analyze_test("tests/collapse_property_resolves.json", t)
}

@(test)
test_typecheck_u8_valid_max_26 :: proc(t: ^testing.T) {
	run_analyze_test("tests/typecheck_u8_valid_max.json", t)
}

@(test)
test_typecheck_u16_overflow_27 :: proc(t: ^testing.T) {
	run_analyze_test("tests/typecheck_u16_overflow.json", t)
}

@(test)
test_constraint_builtin_array_valid_28 :: proc(t: ^testing.T) {
	run_analyze_test("tests/constraint_builtin_array_valid.json", t)
}

@(test)
test_invalid_binding_name_scope_29 :: proc(t: ^testing.T) {
	run_analyze_test("tests/invalid_binding_name_scope.json", t)
}

@(test)
test_typecheck_i8_overflow_30 :: proc(t: ^testing.T) {
	run_analyze_test("tests/typecheck_i8_overflow.json", t)
}

@(test)
test_default_nested_production_lazy_31 :: proc(t: ^testing.T) {
	run_analyze_test("tests/default_nested_production_lazy.json", t)
}

@(test)
test_default_bool_false_first_32 :: proc(t: ^testing.T) {
	run_analyze_test("tests/default_bool_false_first.json", t)
}

@(test)
test_negrange_satisfy_valid_33 :: proc(t: ^testing.T) {
	run_analyze_test("tests/negrange_satisfy_valid.json", t)
}

@(test)
test_typecheck_bool_valid_false_34 :: proc(t: ^testing.T) {
	run_analyze_test("tests/typecheck_bool_valid_false.json", t)
}

@(test)
test_negrange_lower_bound_35 :: proc(t: ^testing.T) {
	run_analyze_test("tests/negrange_lower_bound.json", t)
}

@(test)
test_constraint_scope_in_builtin_array_36 :: proc(t: ^testing.T) {
	run_analyze_test("tests/constraint_scope_in_builtin_array.json", t)
}

@(test)
test_typecheck_bool_negate_valid_37 :: proc(t: ^testing.T) {
	run_analyze_test("tests/typecheck_bool_negate_valid.json", t)
}

@(test)
test_expand_capture_name_side_38 :: proc(t: ^testing.T) {
	run_analyze_test("tests/expand_capture_name_side.json", t)
}

@(test)
test_constraint_compound_array_valid_39 :: proc(t: ^testing.T) {
	run_analyze_test("tests/constraint_compound_array_valid.json", t)
}

@(test)
test_valid_colored_binding_capture_40 :: proc(t: ^testing.T) {
	run_analyze_test("tests/valid_colored_binding_capture.json", t)
}

@(test)
test_constraint_scope_element_direct_41 :: proc(t: ^testing.T) {
	run_analyze_test("tests/constraint_scope_element_direct.json", t)
}

@(test)
test_typecheck_f32_string_42 :: proc(t: ^testing.T) {
	run_analyze_test("tests/typecheck_f32_string.json", t)
}

@(test)
test_typecheck_no_constraint_43 :: proc(t: ^testing.T) {
	run_analyze_test("tests/typecheck_no_constraint.json", t)
}

@(test)
test_colored_carve_out_of_color_44 :: proc(t: ^testing.T) {
	run_analyze_test("tests/colored_carve_out_of_color.json", t)
}

@(test)
test_constraint_nested_scope_in_array_45 :: proc(t: ^testing.T) {
	run_analyze_test("tests/constraint_nested_scope_in_array.json", t)
}

@(test)
test_typecheck_i8_valid_max_46 :: proc(t: ^testing.T) {
	run_analyze_test("tests/typecheck_i8_valid_max.json", t)
}

@(test)
test_constraint_product_simple_constraint_fail_47 :: proc(t: ^testing.T) {
	run_analyze_test("tests/constraint_product_simple_constraint_fail.json", t)
}

@(test)
test_div_float_by_zero_range_ieee_48 :: proc(t: ^testing.T) {
	run_analyze_test("tests/div_float_by_zero_range_ieee.json", t)
}

@(test)
test_invalid_constraint_name_integer_arrow_49 :: proc(t: ^testing.T) {
	run_analyze_test("tests/invalid_constraint_name_integer_arrow.json", t)
}

@(test)
test_div_int_by_zero_range_50 :: proc(t: ^testing.T) {
	run_analyze_test("tests/div_int_by_zero_range.json", t)
}

@(test)
test_invalid_binding_name_paren_expr_51 :: proc(t: ^testing.T) {
	run_analyze_test("tests/invalid_binding_name_paren_expr.json", t)
}

@(test)
test_typecheck_string_valid_52 :: proc(t: ^testing.T) {
	run_analyze_test("tests/typecheck_string_valid.json", t)
}

@(test)
test_typecheck_i32_float_53 :: proc(t: ^testing.T) {
	run_analyze_test("tests/typecheck_i32_float.json", t)
}

@(test)
test_constraint_product_constraint_vs_value_distinction_54 :: proc(t: ^testing.T) {
	run_analyze_test("tests/constraint_product_constraint_vs_value_distinction.json", t)
}

@(test)
test_constraint_product_constraint_named_scope_pass_55 :: proc(t: ^testing.T) {
	run_analyze_test("tests/constraint_product_constraint_named_scope_pass.json", t)
}

@(test)
test_typecheck_u32_overflow_56 :: proc(t: ^testing.T) {
	run_analyze_test("tests/typecheck_u32_overflow.json", t)
}

@(test)
test_implicit_carve_valid_both_57 :: proc(t: ^testing.T) {
	run_analyze_test("tests/implicit_carve_valid_both.json", t)
}

@(test)
test_typecheck_u8_valid_zero_58 :: proc(t: ^testing.T) {
	run_analyze_test("tests/typecheck_u8_valid_zero.json", t)
}

@(test)
test_typecheck_string_bool_59 :: proc(t: ^testing.T) {
	run_analyze_test("tests/typecheck_string_bool.json", t)
}

@(test)
test_typecheck_u32_valid_60 :: proc(t: ^testing.T) {
	run_analyze_test("tests/typecheck_u32_valid.json", t)
}

@(test)
test_constraint_product_value_literal_fail_61 :: proc(t: ^testing.T) {
	run_analyze_test("tests/constraint_product_value_literal_fail.json", t)
}

@(test)
test_invalid_constraint_name_float_arrow_62 :: proc(t: ^testing.T) {
	run_analyze_test("tests/invalid_constraint_name_float_arrow.json", t)
}

@(test)
test_constraint_product_constraint_scope_literal_fail_63 :: proc(t: ^testing.T) {
	run_analyze_test("tests/constraint_product_constraint_scope_literal_fail.json", t)
}

@(test)
test_capture_invisible_to_property_64 :: proc(t: ^testing.T) {
	run_analyze_test("tests/capture_invisible_to_property.json", t)
}

@(test)
test_implicit_carve_numeric_string_65 :: proc(t: ^testing.T) {
	run_analyze_test("tests/implicit_carve_numeric_string.json", t)
}

@(test)
test_typecheck_constraint_only_66 :: proc(t: ^testing.T) {
	run_analyze_test("tests/typecheck_constraint_only.json", t)
}

@(test)
test_invalid_binding_name_string_67 :: proc(t: ^testing.T) {
	run_analyze_test("tests/invalid_binding_name_string.json", t)
}

@(test)
test_typecheck_i64_valid_large_68 :: proc(t: ^testing.T) {
	run_analyze_test("tests/typecheck_i64_valid_large.json", t)
}

@(test)
test_implicit_carve_non_scope_69 :: proc(t: ^testing.T) {
	run_analyze_test("tests/implicit_carve_non_scope.json", t)
}

@(test)
test_typecheck_u8_bool_70 :: proc(t: ^testing.T) {
	run_analyze_test("tests/typecheck_u8_bool.json", t)
}

@(test)
test_constraint_scope_in_compound_array_71 :: proc(t: ^testing.T) {
	run_analyze_test("tests/constraint_scope_in_compound_array.json", t)
}

@(test)
test_valid_chained_property_72 :: proc(t: ^testing.T) {
	run_analyze_test("tests/valid_chained_property.json", t)
}

@(test)
test_constraint_int_in_compound_array_73 :: proc(t: ^testing.T) {
	run_analyze_test("tests/constraint_int_in_compound_array.json", t)
}

@(test)
test_constraint_product_simple_constraint_pass_74 :: proc(t: ^testing.T) {
	run_analyze_test("tests/constraint_product_simple_constraint_pass.json", t)
}

@(test)
test_typecheck_i32_overflow_75 :: proc(t: ^testing.T) {
	run_analyze_test("tests/typecheck_i32_overflow.json", t)
}

@(test)
test_default_bool_true_first_76 :: proc(t: ^testing.T) {
	run_analyze_test("tests/default_bool_true_first.json", t)
}

@(test)
test_invalid_property_name_paren_expr_77 :: proc(t: ^testing.T) {
	run_analyze_test("tests/invalid_property_name_paren_expr.json", t)
}

@(test)
test_invalid_constraint_name_integer_78 :: proc(t: ^testing.T) {
	run_analyze_test("tests/invalid_constraint_name_integer.json", t)
}

@(test)
test_anonymous_capture_invisible_to_property_79 :: proc(t: ^testing.T) {
	run_analyze_test("tests/anonymous_capture_invisible_to_property.json", t)
}

@(test)
test_typecheck_u64_negative_80 :: proc(t: ^testing.T) {
	run_analyze_test("tests/typecheck_u64_negative.json", t)
}

@(test)
test_colored_carve_closed_81 :: proc(t: ^testing.T) {
	run_analyze_test("tests/colored_carve_closed.json", t)
}

@(test)
test_implicit_carve_missing_ordinal_82 :: proc(t: ^testing.T) {
	run_analyze_test("tests/implicit_carve_missing_ordinal.json", t)
}

@(test)
test_typecheck_i16_overflow_83 :: proc(t: ^testing.T) {
	run_analyze_test("tests/typecheck_i16_overflow.json", t)
}

@(test)
test_invalid_property_name_string_84 :: proc(t: ^testing.T) {
	run_analyze_test("tests/invalid_property_name_string.json", t)
}

@(test)
test_typecheck_u16_valid_85 :: proc(t: ^testing.T) {
	run_analyze_test("tests/typecheck_u16_valid.json", t)
}

@(test)
test_typecheck_bool_string_86 :: proc(t: ^testing.T) {
	run_analyze_test("tests/typecheck_bool_string.json", t)
}

@(test)
test_colored_carve_anonymous_87 :: proc(t: ^testing.T) {
	run_analyze_test("tests/colored_carve_anonymous.json", t)
}

@(test)
test_anonymous_capture_bare_88 :: proc(t: ^testing.T) {
	run_analyze_test("tests/anonymous_capture_bare.json", t)
}

@(test)
test_div_float_by_const_89 :: proc(t: ^testing.T) {
	run_analyze_test("tests/div_float_by_const.json", t)
}

@(test)
test_constraint_product_value_structural_pass_90 :: proc(t: ^testing.T) {
	run_analyze_test("tests/constraint_product_value_structural_pass.json", t)
}

@(test)
test_collapse_property_scalar_production_91 :: proc(t: ^testing.T) {
	run_analyze_test("tests/collapse_property_scalar_production.json", t)
}

@(test)
test_typecheck_bool_empty_complement_fail_92 :: proc(t: ^testing.T) {
	run_analyze_test("tests/typecheck_bool_empty_complement_fail.json", t)
}

@(test)
test_typecheck_f64_int_93 :: proc(t: ^testing.T) {
	run_analyze_test("tests/typecheck_f64_int.json", t)
}

@(test)
test_implicit_carve_valid_numeric_94 :: proc(t: ^testing.T) {
	run_analyze_test("tests/implicit_carve_valid_numeric.json", t)
}

@(test)
test_typecheck_string_int_95 :: proc(t: ^testing.T) {
	run_analyze_test("tests/typecheck_string_int.json", t)
}

@(test)
test_invalid_property_name_float_96 :: proc(t: ^testing.T) {
	run_analyze_test("tests/invalid_property_name_float.json", t)
}

@(test)
test_typecheck_i16_valid_97 :: proc(t: ^testing.T) {
	run_analyze_test("tests/typecheck_i16_valid.json", t)
}

@(test)
test_invalid_binding_name_integer_98 :: proc(t: ^testing.T) {
	run_analyze_test("tests/invalid_binding_name_integer.json", t)
}

@(test)
test_implicit_carve_valid_ordinal_99 :: proc(t: ^testing.T) {
	run_analyze_test("tests/implicit_carve_valid_ordinal.json", t)
}

@(test)
test_constraint_product_constraint_mixed_fail_100 :: proc(t: ^testing.T) {
	run_analyze_test("tests/constraint_product_constraint_mixed_fail.json", t)
}

@(test)
test_valid_anonymous_capture_101 :: proc(t: ^testing.T) {
	run_analyze_test("tests/valid_anonymous_capture.json", t)
}

@(test)
test_typecheck_f64_valid_102 :: proc(t: ^testing.T) {
	run_analyze_test("tests/typecheck_f64_valid.json", t)
}

@(test)
test_constraint_product_constraint_scope_literal_pass_103 :: proc(t: ^testing.T) {
	run_analyze_test("tests/constraint_product_constraint_scope_literal_pass.json", t)
}

