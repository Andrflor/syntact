// AUTO-GENERATED. DO NOT EDIT.
package typecheck_test

import "core:testing"

@(test)
test_tc_union_ok_0 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_union_ok.json", t)
}

@(test)
test_tc_carve_1 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve.json", t)
}

@(test)
test_tc_demorgan_ok_2 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_demorgan_ok.json", t)
}

@(test)
test_tc_scope_prop_3 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_scope_prop.json", t)
}

@(test)
test_tc_mixed_int_bad_4 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_mixed_int_bad.json", t)
}

@(test)
test_tc_cast_cross_domain_float_to_i32_ok_5 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cast_cross_domain_float_to_i32_ok.json", t)
}

@(test)
test_tc_mixed_strint_int_6 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_mixed_strint_int.json", t)
}

@(test)
test_tc_pos_prefix_bad_7 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pos_prefix_bad.json", t)
}

@(test)
test_tc_cast_target_unsized_float_fail_8 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cast_target_unsized_float_fail.json", t)
}

@(test)
test_tc_pos_str_bad_9 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pos_str_bad.json", t)
}

@(test)
test_tc_pos_prefix_ok_10 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pos_prefix_ok.json", t)
}

@(test)
test_tc_prod_ok_11 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_prod_ok.json", t)
}

@(test)
test_tc_execute_constraint_fail_12 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_execute_constraint_fail.json", t)
}

@(test)
test_tc_cross_str_int_13 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cross_str_int.json", t)
}

@(test)
test_tc_ord_char_ok_14 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ord_char_ok.json", t)
}

@(test)
test_tc_rep_range_ok_15 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_rep_range_ok.json", t)
}

@(test)
test_tc_cast_target_disjoint_union_fail_16 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cast_target_disjoint_union_fail.json", t)
}

@(test)
test_tc_carve_implicit_override_both_ok_17 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_implicit_override_both_ok.json", t)
}

@(test)
test_tc_cast_target_range_no_layout_fail_18 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cast_target_range_no_layout_fail.json", t)
}

@(test)
test_tc_rep_exact_bad_19 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_rep_exact_bad.json", t)
}

@(test)
test_tc_carve_implicit_compose_compensated_ok_20 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_implicit_compose_compensated_ok.json", t)
}

@(test)
test_tc_execute_empty_none_fail_21 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_execute_empty_none_fail.json", t)
}

@(test)
test_tc_mixed_strint_str_22 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_mixed_strint_str.json", t)
}

@(test)
test_tc_prod_u8_23 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_prod_u8.json", t)
}

@(test)
test_tc_demorgan_bad_24 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_demorgan_bad.json", t)
}

@(test)
test_tc_prod_nest_ok_25 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_prod_nest_ok.json", t)
}

@(test)
test_tc_rep_exact_ok_26 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_rep_exact_ok.json", t)
}

@(test)
test_tc_cast_target_unbounded_int_fail_27 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cast_target_unbounded_int_fail.json", t)
}

@(test)
test_tc_neg_pos_bad_28 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg_pos_bad.json", t)
}

@(test)
test_tc_mixed_strint_float_29 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_mixed_strint_float.json", t)
}

@(test)
test_tc_union_bad_30 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_union_bad.json", t)
}

@(test)
test_tc_cross_range_31 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cross_range.json", t)
}

@(test)
test_tc_prod_nest_bad_32 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_prod_nest_bad.json", t)
}

@(test)
test_tc_neg_ord_ok_33 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg_ord_ok.json", t)
}

@(test)
test_tc_carve_implicit_independent_ok_34 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_implicit_independent_ok.json", t)
}

@(test)
test_tc_carve_implicit_ref_fail_35 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_implicit_ref_fail.json", t)
}

@(test)
test_tc_cast_cross_domain_string_to_u8_ok_36 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cast_cross_domain_string_to_u8_ok.json", t)
}

@(test)
test_tc_cast_unknown_sum_overflow_fail_37 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cast_unknown_sum_overflow_fail.json", t)
}

@(test)
test_tc_cast_overflow_into_u8_ok_38 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cast_overflow_into_u8_ok.json", t)
}

@(test)
test_tc_execute_value_fail_39 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_execute_value_fail.json", t)
}

@(test)
test_tc_cast_unknown_sum_recast_ok_40 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cast_unknown_sum_recast_ok.json", t)
}

@(test)
test_tc_rep_char_bad_41 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_rep_char_bad.json", t)
}

@(test)
test_tc_neg10_bad_42 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg10_bad.json", t)
}

@(test)
test_tc_ord_char_bad_43 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ord_char_bad.json", t)
}

@(test)
test_tc_u8_ok_44 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_u8_ok.json", t)
}

@(test)
test_tc_carve_implicit_compose_fail_45 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_implicit_compose_fail.json", t)
}

@(test)
test_tc_neg_pos_ok_46 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg_pos_ok.json", t)
}

@(test)
test_tc_mixed_float_47 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_mixed_float.json", t)
}

@(test)
test_tc_ident_ok_48 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ident_ok.json", t)
}

@(test)
test_tc_ident_bad_49 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ident_bad.json", t)
}

@(test)
test_tc_execute_empty_none_ok_50 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_execute_empty_none_ok.json", t)
}

@(test)
test_tc_execute_constraint_ok_51 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_execute_constraint_ok.json", t)
}

@(test)
test_tc_carve_implicit_transitive_fail_52 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_implicit_transitive_fail.json", t)
}

@(test)
test_tc_execute_value_ok_53 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_execute_value_ok.json", t)
}

@(test)
test_tc_cast_overflow_no_cast_fail_54 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cast_overflow_no_cast_fail.json", t)
}

@(test)
test_tc_cast_unknown_forced_ok_55 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cast_unknown_forced_ok.json", t)
}

@(test)
test_tc_range_ok_56 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_range_ok.json", t)
}

@(test)
test_tc_neg10_ok_57 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg10_ok.json", t)
}

@(test)
test_tc_nested_prop_58 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_nested_prop.json", t)
}

@(test)
test_tc_mixed_str_in_strf32_59 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_mixed_str_in_strf32.json", t)
}

@(test)
test_tc_u8_overflow_60 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_u8_overflow.json", t)
}

