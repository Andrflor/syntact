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
test_tc_mixed_strint_int_5 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_mixed_strint_int.json", t)
}

@(test)
test_tc_pos_prefix_bad_6 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pos_prefix_bad.json", t)
}

@(test)
test_tc_pos_str_bad_7 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pos_str_bad.json", t)
}

@(test)
test_tc_pos_prefix_ok_8 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pos_prefix_ok.json", t)
}

@(test)
test_tc_prod_ok_9 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_prod_ok.json", t)
}

@(test)
test_tc_execute_constraint_fail_10 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_execute_constraint_fail.json", t)
}

@(test)
test_tc_cross_str_int_11 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cross_str_int.json", t)
}

@(test)
test_tc_ord_char_ok_12 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ord_char_ok.json", t)
}

@(test)
test_tc_rep_range_ok_13 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_rep_range_ok.json", t)
}

@(test)
test_tc_carve_implicit_override_both_ok_14 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_implicit_override_both_ok.json", t)
}

@(test)
test_tc_rep_exact_bad_15 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_rep_exact_bad.json", t)
}

@(test)
test_tc_carve_implicit_compose_compensated_ok_16 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_implicit_compose_compensated_ok.json", t)
}

@(test)
test_tc_execute_empty_none_fail_17 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_execute_empty_none_fail.json", t)
}

@(test)
test_tc_mixed_strint_str_18 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_mixed_strint_str.json", t)
}

@(test)
test_tc_prod_u8_19 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_prod_u8.json", t)
}

@(test)
test_tc_demorgan_bad_20 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_demorgan_bad.json", t)
}

@(test)
test_tc_prod_nest_ok_21 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_prod_nest_ok.json", t)
}

@(test)
test_tc_rep_exact_ok_22 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_rep_exact_ok.json", t)
}

@(test)
test_tc_neg_pos_bad_23 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg_pos_bad.json", t)
}

@(test)
test_tc_mixed_strint_float_24 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_mixed_strint_float.json", t)
}

@(test)
test_tc_union_bad_25 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_union_bad.json", t)
}

@(test)
test_tc_cross_range_26 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cross_range.json", t)
}

@(test)
test_tc_prod_nest_bad_27 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_prod_nest_bad.json", t)
}

@(test)
test_tc_neg_ord_ok_28 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg_ord_ok.json", t)
}

@(test)
test_tc_carve_implicit_independent_ok_29 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_implicit_independent_ok.json", t)
}

@(test)
test_tc_carve_implicit_ref_fail_30 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_implicit_ref_fail.json", t)
}

@(test)
test_tc_execute_value_fail_31 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_execute_value_fail.json", t)
}

@(test)
test_tc_rep_char_bad_32 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_rep_char_bad.json", t)
}

@(test)
test_tc_neg10_bad_33 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg10_bad.json", t)
}

@(test)
test_tc_ord_char_bad_34 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ord_char_bad.json", t)
}

@(test)
test_tc_u8_ok_35 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_u8_ok.json", t)
}

@(test)
test_tc_carve_implicit_compose_fail_36 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_implicit_compose_fail.json", t)
}

@(test)
test_tc_neg_pos_ok_37 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg_pos_ok.json", t)
}

@(test)
test_tc_mixed_float_38 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_mixed_float.json", t)
}

@(test)
test_tc_ident_ok_39 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ident_ok.json", t)
}

@(test)
test_tc_ident_bad_40 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ident_bad.json", t)
}

@(test)
test_tc_execute_empty_none_ok_41 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_execute_empty_none_ok.json", t)
}

@(test)
test_tc_execute_constraint_ok_42 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_execute_constraint_ok.json", t)
}

@(test)
test_tc_carve_implicit_transitive_fail_43 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_implicit_transitive_fail.json", t)
}

@(test)
test_tc_execute_value_ok_44 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_execute_value_ok.json", t)
}

@(test)
test_tc_range_ok_45 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_range_ok.json", t)
}

@(test)
test_tc_neg10_ok_46 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg10_ok.json", t)
}

@(test)
test_tc_nested_prop_47 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_nested_prop.json", t)
}

@(test)
test_tc_mixed_str_in_strf32_48 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_mixed_str_in_strf32.json", t)
}

@(test)
test_tc_u8_overflow_49 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_u8_overflow.json", t)
}

