// AUTO-GENERATED. DO NOT EDIT.
package typecheck_test

import "core:testing"

@(test)
test_tc_neg_range_ok_0 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg_range_ok.json", t)
}

@(test)
test_tc_str_range_tri_noprefix_bad_1 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_range_tri_noprefix_bad.json", t)
}

@(test)
test_tc_union_ok_2 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_union_ok.json", t)
}

@(test)
test_tc_neg_ord_range_bad_3 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg_ord_range_bad.json", t)
}

@(test)
test_tc_carve_nested_bad_4 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_nested_bad.json", t)
}

@(test)
test_tc_str_range_prefix_bad_5 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_range_prefix_bad.json", t)
}

@(test)
test_tc_flt_add_concrete_ok_6 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_flt_add_concrete_ok.json", t)
}

@(test)
test_tc_carve_7 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve.json", t)
}

@(test)
test_tc_neg_str_exact_bad_8 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg_str_exact_bad.json", t)
}

@(test)
test_tc_str_concat_lit_class_bad_9 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_concat_lit_class_bad.json", t)
}

@(test)
test_tc_ref_singleton_other_bad_10 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ref_singleton_other_bad.json", t)
}

@(test)
test_tc_demorgan_ok_11 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_demorgan_ok.json", t)
}

@(test)
test_tc_prop_compute_bad_12 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_prop_compute_bad.json", t)
}

@(test)
test_tc_carve_as_type_via_ref_ok_13 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_as_type_via_ref_ok.json", t)
}

@(test)
test_tc_union_bool_int_float_bad_14 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_union_bool_int_float_bad.json", t)
}

@(test)
test_tc_ref_neg_range_ok_15 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ref_neg_range_ok.json", t)
}

@(test)
test_tc_ref_nested_mix_ok_16 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ref_nested_mix_ok.json", t)
}

@(test)
test_tc_flt_union_bad_17 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_flt_union_bad.json", t)
}

@(test)
test_tc_scope_prop_18 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_scope_prop.json", t)
}

@(test)
test_tc_neg_char_ok_19 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg_char_ok.json", t)
}

@(test)
test_tc_flt_sub_concrete_ok_20 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_flt_sub_concrete_ok.json", t)
}

@(test)
test_tc_execute_ref_producer_bad_21 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_execute_ref_producer_bad.json", t)
}

@(test)
test_tc_mixed_int_bad_22 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_mixed_int_bad.json", t)
}

@(test)
test_tc_ref_prop_arith_bad_23 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ref_prop_arith_bad.json", t)
}

@(test)
test_tc_str_squote_multi_pos_ok_24 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_squote_multi_pos_ok.json", t)
}

@(test)
test_tc_cmp_le100_ok_25 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cmp_le100_ok.json", t)
}

@(test)
test_tc_scope_two_second_overflow_bad_26 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_scope_two_second_overflow_bad.json", t)
}

@(test)
test_tc_refchain_constraint_ok_27 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_refchain_constraint_ok.json", t)
}

@(test)
test_tc_flt_inter_ok_28 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_flt_inter_ok.json", t)
}

@(test)
test_tc_execute_as_type_ok_29 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_execute_as_type_ok.json", t)
}

@(test)
test_tc_execute_set_not_element_bad_30 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_execute_set_not_element_bad.json", t)
}

@(test)
test_tc_execute_none_into_u8_bad_31 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_execute_none_into_u8_bad.json", t)
}

@(test)
test_tc_comp_tri_union_mid_ok_32 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_comp_tri_union_mid_ok.json", t)
}

@(test)
test_tc_execute_of_carve_overflow_bad_33 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_execute_of_carve_overflow_bad.json", t)
}

@(test)
test_tc_cast_cross_domain_float_to_i32_ok_34 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cast_cross_domain_float_to_i32_ok.json", t)
}

@(test)
test_tc_unk_mul_u8_bad_35 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_unk_mul_u8_bad.json", t)
}

@(test)
test_tc_mixed_strint_int_36 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_mixed_strint_int.json", t)
}

@(test)
test_tc_pos_prefix_bad_37 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pos_prefix_bad.json", t)
}

@(test)
test_tc_union_char_int_str_ok_38 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_union_char_int_str_ok.json", t)
}

@(test)
test_tc_neg_int_ok_39 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg_int_ok.json", t)
}

@(test)
test_tc_int_sub_u8u8_u8_default0_ok_40 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_int_sub_u8u8_u8_default0_ok.json", t)
}

@(test)
test_tc_union_rep_ok_41 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_union_rep_ok.json", t)
}

@(test)
test_tc_cast_u8_to_f32_ok_42 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cast_u8_to_f32_ok.json", t)
}

@(test)
test_tc_scope_shape_ok_43 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_scope_shape_ok.json", t)
}

@(test)
test_tc_int_and_gt_ok_44 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_int_and_gt_ok.json", t)
}

@(test)
test_tc_cast_target_unsized_float_fail_45 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cast_target_unsized_float_fail.json", t)
}

@(test)
test_tc_pos_str_bad_46 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pos_str_bad.json", t)
}

@(test)
test_tc_execute_as_type_bad_47 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_execute_as_type_bad.json", t)
}

@(test)
test_tc_int_mul_range_u16_ok_48 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_int_mul_range_u16_ok.json", t)
}

@(test)
test_tc_comp_inter_unions_bad2_49 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_comp_inter_unions_bad2.json", t)
}

@(test)
test_tc_cmp_lt0_ok_50 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cmp_lt0_ok.json", t)
}

@(test)
test_tc_str_rep_range_bad_51 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_rep_range_bad.json", t)
}

@(test)
test_tc_str_neg_plus_lit_bad_52 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_neg_plus_lit_bad.json", t)
}

@(test)
test_tc_ref_arith_nested_bad_53 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ref_arith_nested_bad.json", t)
}

@(test)
test_tc_str_union_pat_ok_54 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_union_pat_ok.json", t)
}

@(test)
test_tc_pos_prefix_ok_55 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pos_prefix_ok.json", t)
}

@(test)
test_tc_neg_triple_bad_56 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg_triple_bad.json", t)
}

@(test)
test_tc_self_u8_bad_57 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_self_u8_bad.json", t)
}

@(test)
test_tc_neg_str_exact_ok_58 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg_str_exact_ok.json", t)
}

@(test)
test_tc_prop_compute_ok_59 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_prop_compute_ok.json", t)
}

@(test)
test_tc_int_sub_concrete_ok_60 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_int_sub_concrete_ok.json", t)
}

@(test)
test_tc_neg_or_self_ok_61 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg_or_self_ok.json", t)
}

@(test)
test_tc_prod_ok_62 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_prod_ok.json", t)
}

@(test)
test_tc_bool_false_bad_63 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_bool_false_bad.json", t)
}

@(test)
test_tc_seq_email_ok_64 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_seq_email_ok.json", t)
}

@(test)
test_tc_neg_ord_range_ok_65 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg_ord_range_ok.json", t)
}

@(test)
test_tc_insoluble_neg_66 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_insoluble_neg.json", t)
}

@(test)
test_tc_comp_tri_union_gap_bad_67 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_comp_tri_union_gap_bad.json", t)
}

@(test)
test_tc_cmp_le100_bad_68 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cmp_le100_bad.json", t)
}

@(test)
test_tc_ref_arith_ok_69 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ref_arith_ok.json", t)
}

@(test)
test_tc_carve_impl_dep_bad_70 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_impl_dep_bad.json", t)
}

@(test)
test_tc_scope_field_union_bad_71 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_scope_field_union_bad.json", t)
}

@(test)
test_tc_str_concat_lit_class_ok_72 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_concat_lit_class_ok.json", t)
}

@(test)
test_tc_insoluble_nested_compose_73 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_insoluble_nested_compose.json", t)
}

@(test)
test_tc_cast_sum_no_cast_bad_74 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cast_sum_no_cast_bad.json", t)
}

@(test)
test_tc_neg_int_bad_75 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg_int_bad.json", t)
}

@(test)
test_tc_demorgan_deep_ok_76 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_demorgan_deep_ok.json", t)
}

@(test)
test_tc_execute_carve_as_type_ok_77 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_execute_carve_as_type_ok.json", t)
}

@(test)
test_tc_comp_and_or_ok_neg_78 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_comp_and_or_ok_neg.json", t)
}

@(test)
test_tc_refchain_triple_ok_79 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_refchain_triple_ok.json", t)
}

@(test)
test_tc_union_u8_f32_str_bad_80 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_union_u8_f32_str_bad.json", t)
}

@(test)
test_tc_execute_constraint_fail_81 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_execute_constraint_fail.json", t)
}

@(test)
test_tc_char_rep_union_ok_82 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_char_rep_union_ok.json", t)
}

@(test)
test_tc_cross_str_int_83 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cross_str_int.json", t)
}

@(test)
test_tc_cast_target_int_fail_84 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cast_target_int_fail.json", t)
}

@(test)
test_tc_cast_target_open_fail_85 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cast_target_open_fail.json", t)
}

@(test)
test_tc_neg_or_negs_none_bad_86 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg_or_negs_none_bad.json", t)
}

@(test)
test_tc_ord_char_ok_87 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ord_char_ok.json", t)
}

@(test)
test_tc_soluble_unknown_value_ok_88 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_soluble_unknown_value_ok.json", t)
}

@(test)
test_tc_flt_mul_range_bad_89 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_flt_mul_range_bad.json", t)
}

@(test)
test_tc_cast_bool_to_u8_ok_90 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cast_bool_to_u8_ok.json", t)
}

@(test)
test_tc_insoluble_direct_91 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_insoluble_direct.json", t)
}

@(test)
test_tc_insoluble_ref_chain_92 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_insoluble_ref_chain.json", t)
}

@(test)
test_tc_scope_calc_mul_bad_93 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_scope_calc_mul_bad.json", t)
}

@(test)
test_tc_rep_range_ok_94 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_rep_range_ok.json", t)
}

@(test)
test_tc_cast_target_disjoint_union_fail_95 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cast_target_disjoint_union_fail.json", t)
}

@(test)
test_tc_cmp_gt5_bad_96 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cmp_gt5_bad.json", t)
}

@(test)
test_tc_cast_neg_into_u8_ok_97 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cast_neg_into_u8_ok.json", t)
}

@(test)
test_tc_seq_email_bad_98 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_seq_email_bad.json", t)
}

@(test)
test_tc_carve_implicit_override_both_ok_99 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_implicit_override_both_ok.json", t)
}

@(test)
test_tc_ref_arith_overflow_bad_100 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ref_arith_overflow_bad.json", t)
}

@(test)
test_tc_bool_union_true_ok_101 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_bool_union_true_ok.json", t)
}

@(test)
test_tc_execute_of_carve_ok_102 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_execute_of_carve_ok.json", t)
}

@(test)
test_tc_str_union_pat_bad_103 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_union_pat_bad.json", t)
}

@(test)
test_tc_cast_target_range_no_layout_fail_104 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cast_target_range_no_layout_fail.json", t)
}

@(test)
test_tc_rep_exact_bad_105 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_rep_exact_bad.json", t)
}

@(test)
test_tc_int_mul_concrete_bad_106 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_int_mul_concrete_bad.json", t)
}

@(test)
test_tc_neg_char_bad_107 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg_char_bad.json", t)
}

@(test)
test_tc_unk_sub_u8_bad_108 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_unk_sub_u8_bad.json", t)
}

@(test)
test_tc_ref_neg_singleton_bad2_109 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ref_neg_singleton_bad2.json", t)
}

@(test)
test_tc_str_backtick_range_ok_110 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_backtick_range_ok.json", t)
}

@(test)
test_tc_str_range_pos_edge_ok_111 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_range_pos_edge_ok.json", t)
}

@(test)
test_tc_str_rep_exact_bad_112 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_rep_exact_bad.json", t)
}

@(test)
test_tc_cast_target_neg_union_fail_113 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cast_target_neg_union_fail.json", t)
}

@(test)
test_tc_str_rep_range_ok_114 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_rep_range_ok.json", t)
}

@(test)
test_tc_int_sub_range_bad_115 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_int_sub_range_bad.json", t)
}

@(test)
test_tc_ref_range_and_bad_116 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ref_range_and_bad.json", t)
}

@(test)
test_tc_int_mixed_sign_u16_bad_117 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_int_mixed_sign_u16_bad.json", t)
}

@(test)
test_tc_scope_union_ok1_118 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_scope_union_ok1.json", t)
}

@(test)
test_tc_carve_implicit_compose_compensated_ok_119 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_implicit_compose_compensated_ok.json", t)
}

@(test)
test_tc_neg_and_neg_bad_120 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg_and_neg_bad.json", t)
}

@(test)
test_tc_cmp_gt5_ok_121 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cmp_gt5_ok.json", t)
}

@(test)
test_tc_scope_calc_range_field_bad_122 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_scope_calc_range_field_bad.json", t)
}

@(test)
test_tc_prop_as_value_ok_123 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_prop_as_value_ok.json", t)
}

@(test)
test_tc_cast_char_to_u8_ok_124 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cast_char_to_u8_ok.json", t)
}

@(test)
test_tc_self_bool_singleton_ok_125 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_self_bool_singleton_ok.json", t)
}

@(test)
test_tc_execute_empty_none_fail_126 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_execute_empty_none_fail.json", t)
}

@(test)
test_tc_bool_neg_true_bad_127 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_bool_neg_true_bad.json", t)
}

@(test)
test_tc_carve_as_type_via_ref_bad_128 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_as_type_via_ref_bad.json", t)
}

@(test)
test_tc_insoluble_scope_field_129 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_insoluble_scope_field.json", t)
}

@(test)
test_tc_bool_union_false_ok_130 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_bool_union_false_ok.json", t)
}

@(test)
test_tc_mixed_strint_str_131 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_mixed_strint_str.json", t)
}

@(test)
test_tc_union_u8_f32_float_ok_132 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_union_u8_f32_float_ok.json", t)
}

@(test)
test_tc_insoluble_colored_binding_133 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_insoluble_colored_binding.json", t)
}

@(test)
test_tc_execute_value_overflow_bad_134 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_execute_value_overflow_bad.json", t)
}

@(test)
test_tc_prod_u8_135 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_prod_u8.json", t)
}

@(test)
test_tc_str_concat_pattern_bad_136 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_concat_pattern_bad.json", t)
}

@(test)
test_tc_cast_target_bool_ok_137 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cast_target_bool_ok.json", t)
}

@(test)
test_tc_demorgan_bad_138 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_demorgan_bad.json", t)
}

@(test)
test_tc_union_tri_str_ok_139 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_union_tri_str_ok.json", t)
}

@(test)
test_tc_seq_range_count_ok_140 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_seq_range_count_ok.json", t)
}

@(test)
test_tc_comp_negrange_or_pt_ok5_141 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_comp_negrange_or_pt_ok5.json", t)
}

@(test)
test_tc_str_concat_pattern_ok_142 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_concat_pattern_ok.json", t)
}

@(test)
test_tc_seq_range_count_bad_143 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_seq_range_count_bad.json", t)
}

@(test)
test_tc_cmp_gt6f_bad_144 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cmp_gt6f_bad.json", t)
}

@(test)
test_tc_prop_family_bad_145 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_prop_family_bad.json", t)
}

@(test)
test_tc_bool_true_ok_146 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_bool_true_ok.json", t)
}

@(test)
test_tc_ref_nested_mix_bad_147 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ref_nested_mix_bad.json", t)
}

@(test)
test_tc_union_u8_f32_overflow_bad_148 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_union_u8_f32_overflow_bad.json", t)
}

@(test)
test_tc_str_union_mixed_len_ok_149 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_union_mixed_len_ok.json", t)
}

@(test)
test_tc_scope_shape_wrong_name_bad_150 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_scope_shape_wrong_name_bad.json", t)
}

@(test)
test_tc_carve_property_ok_151 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_property_ok.json", t)
}

@(test)
test_tc_cast_f64_to_f32_ok_152 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cast_f64_to_f32_ok.json", t)
}

@(test)
test_tc_comp_and_or_ok_hi_153 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_comp_and_or_ok_hi.json", t)
}

@(test)
test_tc_int_and_gt_bad_154 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_int_and_gt_bad.json", t)
}

@(test)
test_tc_scope_shape_calc_bad_155 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_scope_shape_calc_bad.json", t)
}

@(test)
test_tc_self_char_singleton_ok_156 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_self_char_singleton_ok.json", t)
}

@(test)
test_tc_demorgan_deep_bad_157 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_demorgan_deep_bad.json", t)
}

@(test)
test_tc_ref_neg_singleton_bad_158 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ref_neg_singleton_bad.json", t)
}

@(test)
test_tc_carve_value_ok_159 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_value_ok.json", t)
}

@(test)
test_tc_neg_or_self_other_ok_160 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg_or_self_other_ok.json", t)
}

@(test)
test_tc_flt_neg_bad_161 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_flt_neg_bad.json", t)
}

@(test)
test_tc_flt_union_ok_162 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_flt_union_ok.json", t)
}

@(test)
test_tc_ref_union_singletons_ok_163 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ref_union_singletons_ok.json", t)
}

@(test)
test_tc_self_str_singleton_ok_164 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_self_str_singleton_ok.json", t)
}

@(test)
test_tc_prod_nest_ok_165 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_prod_nest_ok.json", t)
}

@(test)
test_tc_rep_exact_ok_166 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_rep_exact_ok.json", t)
}

@(test)
test_tc_str_union_class_literal_bad_167 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_union_class_literal_bad.json", t)
}

@(test)
test_tc_carve_property_compute_bad_168 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_property_compute_bad.json", t)
}

@(test)
test_tc_execute_ref_binding_ok_169 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_execute_ref_binding_ok.json", t)
}

@(test)
test_tc_neg_double_ok_170 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg_double_ok.json", t)
}

@(test)
test_tc_union_rep_bad_171 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_union_rep_bad.json", t)
}

@(test)
test_tc_flt_inter_bad_172 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_flt_inter_bad.json", t)
}

@(test)
test_tc_cast_target_unbounded_int_fail_173 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cast_target_unbounded_int_fail.json", t)
}

@(test)
test_tc_ref_and_range_bad_174 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ref_and_range_bad.json", t)
}

@(test)
test_tc_scope_nested_bad_175 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_scope_nested_bad.json", t)
}

@(test)
test_tc_scope_nested_ok_176 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_scope_nested_ok.json", t)
}

@(test)
test_tc_seq_two_classes_ok_177 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_seq_two_classes_ok.json", t)
}

@(test)
test_tc_bool_true_bad_178 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_bool_true_bad.json", t)
}

@(test)
test_tc_cmp_gt6f_ok_179 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cmp_gt6f_ok.json", t)
}

@(test)
test_tc_flt_open_lo_ok_180 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_flt_open_lo_ok.json", t)
}

@(test)
test_tc_union_char_alts_ok_181 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_union_char_alts_ok.json", t)
}

@(test)
test_tc_str_concat_lit_class_prefix_bad_182 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_concat_lit_class_prefix_bad.json", t)
}

@(test)
test_tc_execute_carve_as_type_bad_183 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_execute_carve_as_type_bad.json", t)
}

@(test)
test_tc_cast_sum_overflow_forced_ok_184 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cast_sum_overflow_forced_ok.json", t)
}

@(test)
test_tc_neg_pos_bad_185 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg_pos_bad.json", t)
}

@(test)
test_tc_int_and_cast_i8_ok_186 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_int_and_cast_i8_ok.json", t)
}

@(test)
test_tc_str_ord_below_bad_187 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_ord_below_bad.json", t)
}

@(test)
test_tc_str_backtick_exact_bad_188 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_backtick_exact_bad.json", t)
}

@(test)
test_tc_refchain_constraint_bad_189 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_refchain_constraint_bad.json", t)
}

@(test)
test_tc_insoluble_via_binding_190 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_insoluble_via_binding.json", t)
}

@(test)
test_tc_scope_calc_field_bad_191 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_scope_calc_field_bad.json", t)
}

@(test)
test_tc_mixed_strint_float_192 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_mixed_strint_float.json", t)
}

@(test)
test_tc_carve_then_execute_ok_193 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_then_execute_ok.json", t)
}

@(test)
test_tc_carve_impl_dep_compensated_ok_194 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_impl_dep_compensated_ok.json", t)
}

@(test)
test_tc_str_neg_concat_digits_ok_195 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_neg_concat_digits_ok.json", t)
}

@(test)
test_tc_insoluble_range_196 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_insoluble_range.json", t)
}

@(test)
test_tc_str_union_class_literal_ok_197 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_union_class_literal_ok.json", t)
}

@(test)
test_tc_str_rep_exact_ok_198 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_rep_exact_ok.json", t)
}

@(test)
test_tc_neg_and_negs_ok_199 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg_and_negs_ok.json", t)
}

@(test)
test_tc_comp_negrange_or_pt_bad_200 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_comp_negrange_or_pt_bad.json", t)
}

@(test)
test_tc_union_bad_201 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_union_bad.json", t)
}

@(test)
test_tc_str_dquote_1char_pos_bad_202 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_dquote_1char_pos_bad.json", t)
}

@(test)
test_tc_str_union_multi_bad_203 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_union_multi_bad.json", t)
}

@(test)
test_tc_scope_shape_wrong_family_bad_204 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_scope_shape_wrong_family_bad.json", t)
}

@(test)
test_tc_self_range_bad_205 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_self_range_bad.json", t)
}

@(test)
test_tc_str_pos_prefix_bad_206 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_pos_prefix_bad.json", t)
}

@(test)
test_tc_str_char_ok_207 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_char_ok.json", t)
}

@(test)
test_tc_carve_override_ok_208 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_override_ok.json", t)
}

@(test)
test_tc_cross_range_209 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cross_range.json", t)
}

@(test)
test_tc_unk_sub_i16_ok_210 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_unk_sub_i16_ok.json", t)
}

@(test)
test_tc_str_backtick_in_string_ok_211 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_backtick_in_string_ok.json", t)
}

@(test)
test_tc_ident_no_trail_bad_212 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ident_no_trail_bad.json", t)
}

@(test)
test_tc_str_rep_concrete_ok_213 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_rep_concrete_ok.json", t)
}

@(test)
test_tc_neg_triple_ok_214 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg_triple_ok.json", t)
}

@(test)
test_tc_unk_add_u16_ok_215 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_unk_add_u16_ok.json", t)
}

@(test)
test_tc_str_range_pos_nosuffix_bad_216 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_range_pos_nosuffix_bad.json", t)
}

@(test)
test_tc_str_range_tri_nomid_bad_217 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_range_tri_nomid_bad.json", t)
}

@(test)
test_tc_int_sub_u8u8_i16_ok_218 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_int_sub_u8u8_i16_ok.json", t)
}

@(test)
test_tc_prod_nest_bad_219 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_prod_nest_bad.json", t)
}

@(test)
test_tc_str_neg_concat_ok_220 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_neg_concat_ok.json", t)
}

@(test)
test_tc_union_char_alts_bad_221 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_union_char_alts_bad.json", t)
}

@(test)
test_tc_ref_prop_arith_ok_222 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ref_prop_arith_ok.json", t)
}

@(test)
test_tc_union_char_int_char_ok_223 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_union_char_int_char_ok.json", t)
}

@(test)
test_tc_neg_ord_ok_224 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg_ord_ok.json", t)
}

@(test)
test_tc_flt_add_range_ok_225 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_flt_add_range_ok.json", t)
}

@(test)
test_tc_char_union_neg_ok_226 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_char_union_neg_ok.json", t)
}

@(test)
test_tc_carve_implicit_independent_ok_227 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_implicit_independent_ok.json", t)
}

@(test)
test_tc_neg_union_ok_228 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg_union_ok.json", t)
}

@(test)
test_tc_bool_any_true_ok_229 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_bool_any_true_ok.json", t)
}

@(test)
test_tc_soluble_singleton_ref_ok_230 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_soluble_singleton_ref_ok.json", t)
}

@(test)
test_tc_execute_chain_ref_ok_231 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_execute_chain_ref_ok.json", t)
}

@(test)
test_tc_int_sub_concrete_bad_232 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_int_sub_concrete_bad.json", t)
}

@(test)
test_tc_int_mod_opaque_int_ok_233 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_int_mod_opaque_int_ok.json", t)
}

@(test)
test_tc_soluble_set_constraint_ok_234 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_soluble_set_constraint_ok.json", t)
}

@(test)
test_tc_neg_and_neg_ok_235 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg_and_neg_ok.json", t)
}

@(test)
test_tc_self_ref_singleton_ok_236 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_self_ref_singleton_ok.json", t)
}

@(test)
test_tc_carve_implicit_ref_fail_237 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_implicit_ref_fail.json", t)
}

@(test)
test_tc_bool_inter_empty_bad_238 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_bool_inter_empty_bad.json", t)
}

@(test)
test_tc_flt_add_range_bad_239 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_flt_add_range_bad.json", t)
}

@(test)
test_tc_scope_calc_field_ok_240 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_scope_calc_field_ok.json", t)
}

@(test)
test_tc_scope_two_order_bad_241 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_scope_two_order_bad.json", t)
}

@(test)
test_tc_int_and_empty_bad_242 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_int_and_empty_bad.json", t)
}

@(test)
test_tc_bool_neg_true_ok_243 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_bool_neg_true_ok.json", t)
}

@(test)
test_tc_execute_ref_producer_ok_244 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_execute_ref_producer_ok.json", t)
}

@(test)
test_tc_self_ref_set_bad_245 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_self_ref_set_bad.json", t)
}

@(test)
test_tc_cast_cross_domain_string_to_u8_ok_246 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cast_cross_domain_string_to_u8_ok.json", t)
}

@(test)
test_tc_ref_or_family_ok_247 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ref_or_family_ok.json", t)
}

@(test)
test_tc_neg_union_bad5_248 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg_union_bad5.json", t)
}

@(test)
test_tc_str_range_tri_contiguous_ok_249 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_range_tri_contiguous_ok.json", t)
}

@(test)
test_tc_bool_inter_same_ok_250 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_bool_inter_same_ok.json", t)
}

@(test)
test_tc_str_backtick_union_ok_251 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_backtick_union_ok.json", t)
}

@(test)
test_tc_cast_into_i8_ok_252 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cast_into_i8_ok.json", t)
}

@(test)
test_tc_insoluble_arith_operand_253 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_insoluble_arith_operand.json", t)
}

@(test)
test_tc_union_u8_f32_int_ok_254 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_union_u8_f32_int_ok.json", t)
}

@(test)
test_tc_cast_unknown_sum_overflow_fail_255 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cast_unknown_sum_overflow_fail.json", t)
}

@(test)
test_tc_int_add_u8u8_u16_ok_256 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_int_add_u8u8_u16_ok.json", t)
}

@(test)
test_tc_str_pos_both_bad_257 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_pos_both_bad.json", t)
}

@(test)
test_tc_int_add_overflow_bad_258 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_int_add_overflow_bad.json", t)
}

@(test)
test_tc_ref_arith_nested_ok_259 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ref_arith_nested_ok.json", t)
}

@(test)
test_tc_cast_overflow_into_u8_ok_260 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cast_overflow_into_u8_ok.json", t)
}

@(test)
test_tc_scope_two_missing_bad_261 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_scope_two_missing_bad.json", t)
}

@(test)
test_tc_int_add_concrete_ok_262 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_int_add_concrete_ok.json", t)
}

@(test)
test_tc_ref_neg_singleton_ok2_263 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ref_neg_singleton_ok2.json", t)
}

@(test)
test_tc_comp_inter_unions_bad_264 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_comp_inter_unions_bad.json", t)
}

@(test)
test_tc_ref_range_and_ok_265 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ref_range_and_ok.json", t)
}

@(test)
test_tc_str_dquote_1char_pos_az_ok_266 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_dquote_1char_pos_az_ok.json", t)
}

@(test)
test_tc_neg_range_bad_267 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg_range_bad.json", t)
}

@(test)
test_tc_str_ord_above_bad_268 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_ord_above_bad.json", t)
}

@(test)
test_tc_seq_backtrack_ok_269 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_seq_backtrack_ok.json", t)
}

@(test)
test_tc_scope_mixed_fields_ok_270 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_scope_mixed_fields_ok.json", t)
}

@(test)
test_tc_ref_neg_singleton_ok_271 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ref_neg_singleton_ok.json", t)
}

@(test)
test_tc_execute_value_fail_272 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_execute_value_fail.json", t)
}

@(test)
test_tc_inter_str_int_none_bad_273 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_inter_str_int_none_bad.json", t)
}

@(test)
test_tc_scope_union_ok2_274 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_scope_union_ok2.json", t)
}

@(test)
test_tc_cast_unknown_sum_recast_ok_275 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cast_unknown_sum_recast_ok.json", t)
}

@(test)
test_tc_unk_mul_u16_ok_276 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_unk_mul_u16_ok.json", t)
}

@(test)
test_tc_rep_char_bad_277 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_rep_char_bad.json", t)
}

@(test)
test_tc_ref_neg_range_bad_278 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ref_neg_range_bad.json", t)
}

@(test)
test_tc_neg10_bad_279 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg10_bad.json", t)
}

@(test)
test_tc_ord_char_bad_280 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ord_char_bad.json", t)
}

@(test)
test_tc_flt_range_bad_281 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_flt_range_bad.json", t)
}

@(test)
test_tc_u8_ok_282 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_u8_ok.json", t)
}

@(test)
test_tc_carve_implicit_compose_fail_283 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_implicit_compose_fail.json", t)
}

@(test)
test_tc_carve_override_ref_overflow_bad_284 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_override_ref_overflow_bad.json", t)
}

@(test)
test_tc_neg_pos_ok_285 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg_pos_ok.json", t)
}

@(test)
test_tc_cmp_lt0_bad_286 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cmp_lt0_bad.json", t)
}

@(test)
test_tc_str_backtick_union_bad_287 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_backtick_union_bad.json", t)
}

@(test)
test_tc_neg_union_bad10_288 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg_union_bad10.json", t)
}

@(test)
test_tc_scope_field_union_ok_289 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_scope_field_union_ok.json", t)
}

@(test)
test_tc_union_char_int_bad_290 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_union_char_int_bad.json", t)
}

@(test)
test_tc_flt_add_concrete_bad_291 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_flt_add_concrete_bad.json", t)
}

@(test)
test_tc_mixed_float_292 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_mixed_float.json", t)
}

@(test)
test_tc_comp_and_or_bad_gap_293 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_comp_and_or_bad_gap.json", t)
}

@(test)
test_tc_str_ord_mid_ok_294 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_ord_mid_ok.json", t)
}

@(test)
test_tc_neg_and_negs_bad_295 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg_and_negs_bad.json", t)
}

@(test)
test_tc_bool_false_ok_296 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_bool_false_ok.json", t)
}

@(test)
test_tc_scope_shape_overflow_bad_297 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_scope_shape_overflow_bad.json", t)
}

@(test)
test_tc_int_div_opaque_int_ok_298 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_int_div_opaque_int_ok.json", t)
}

@(test)
test_tc_flt_neg_ok_299 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_flt_neg_ok.json", t)
}

@(test)
test_tc_comp_inter_unions_ok2_300 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_comp_inter_unions_ok2.json", t)
}

@(test)
test_tc_union_tri_bool_bad_301 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_union_tri_bool_bad.json", t)
}

@(test)
test_tc_str_range_pos_noprefix_bad_302 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_range_pos_noprefix_bad.json", t)
}

@(test)
test_tc_cast_then_overflow_ok_303 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cast_then_overflow_ok.json", t)
}

@(test)
test_tc_str_range_pos_mid_ok_304 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_range_pos_mid_ok.json", t)
}

@(test)
test_tc_carve_override_bad_305 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_override_bad.json", t)
}

@(test)
test_tc_comp_double_and_bad_hi_306 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_comp_double_and_bad_hi.json", t)
}

@(test)
test_tc_bool_neg_false_ok_307 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_bool_neg_false_ok.json", t)
}

@(test)
test_tc_str_union_class_literal_class_ok_308 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_union_class_literal_class_ok.json", t)
}

@(test)
test_tc_str_pos_prefix_ok_309 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_pos_prefix_ok.json", t)
}

@(test)
test_tc_self_string_set_bad_310 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_self_string_set_bad.json", t)
}

@(test)
test_tc_ident_ok_311 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ident_ok.json", t)
}

@(test)
test_tc_union_tri_float_ok_312 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_union_tri_float_ok.json", t)
}

@(test)
test_tc_ident_no_trail_ok_313 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ident_no_trail_ok.json", t)
}

@(test)
test_tc_union_char_alts_up_ok_314 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_union_char_alts_up_ok.json", t)
}

@(test)
test_tc_char_union_neg_bad_315 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_char_union_neg_bad.json", t)
}

@(test)
test_tc_scope_shape_calc_ok_316 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_scope_shape_calc_ok.json", t)
}

@(test)
test_tc_int_add_u8u8_u8_default0_ok_317 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_int_add_u8u8_u8_default0_ok.json", t)
}

@(test)
test_tc_flt_mul_range_ok_318 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_flt_mul_range_ok.json", t)
}

@(test)
test_tc_str_neg_plus_lit_ok_319 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_neg_plus_lit_ok.json", t)
}

@(test)
test_tc_seq_tag_ok_320 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_seq_tag_ok.json", t)
}

@(test)
test_tc_int_mixed_sign_i16_ok_321 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_int_mixed_sign_i16_ok.json", t)
}

@(test)
test_tc_ref_or_family_bad_322 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ref_or_family_bad.json", t)
}

@(test)
test_tc_ident_bad_323 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ident_bad.json", t)
}

@(test)
test_tc_refchain_triple_bad_324 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_refchain_triple_bad.json", t)
}

@(test)
test_tc_execute_empty_none_ok_325 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_execute_empty_none_ok.json", t)
}

@(test)
test_tc_int_sub_range_hi_ok_326 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_int_sub_range_hi_ok.json", t)
}

@(test)
test_tc_carve_value_override_bad_327 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_value_override_bad.json", t)
}

@(test)
test_tc_cast_i32_to_f32_ok_328 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cast_i32_to_f32_ok.json", t)
}

@(test)
test_tc_int_mul_range_u8_default0_ok_329 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_int_mul_range_u8_default0_ok.json", t)
}

@(test)
test_tc_execute_constraint_ok_330 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_execute_constraint_ok.json", t)
}

@(test)
test_tc_bool_any_false_ok_331 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_bool_any_false_ok.json", t)
}

@(test)
test_tc_neg_double_bad_332 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg_double_bad.json", t)
}

@(test)
test_tc_insoluble_or_333 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_insoluble_or.json", t)
}

@(test)
test_tc_union_bool_int_ok_334 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_union_bool_int_ok.json", t)
}

@(test)
test_tc_seq_two_classes_short_bad_335 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_seq_two_classes_short_bad.json", t)
}

@(test)
test_tc_ref_type_concrete_ok_336 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ref_type_concrete_ok.json", t)
}

@(test)
test_tc_carve_as_type_ok_337 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_as_type_ok.json", t)
}

@(test)
test_tc_carve_implicit_transitive_fail_338 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_implicit_transitive_fail.json", t)
}

@(test)
test_tc_unk_mul_u32_ok_339 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_unk_mul_u32_ok.json", t)
}

@(test)
test_tc_scope_mixed_fields_bad_340 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_scope_mixed_fields_bad.json", t)
}

@(test)
test_tc_ref_nested_mix_neg_ok_341 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ref_nested_mix_neg_ok.json", t)
}

@(test)
test_tc_execute_value_ok_342 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_execute_value_ok.json", t)
}

@(test)
test_tc_ref_type_concrete_bad_343 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ref_type_concrete_bad.json", t)
}

@(test)
test_tc_str_backtick_range_bad_344 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_backtick_range_bad.json", t)
}

@(test)
test_tc_carve_as_type_overflow_bad_345 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_as_type_overflow_bad.json", t)
}

@(test)
test_tc_flt_open_hi_ok_346 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_flt_open_hi_ok.json", t)
}

@(test)
test_tc_cmp_ge5_ok_347 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cmp_ge5_ok.json", t)
}

@(test)
test_tc_union_bool_int_intok_348 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_union_bool_int_intok.json", t)
}

@(test)
test_tc_scope_calc_mul_ok_349 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_scope_calc_mul_ok.json", t)
}

@(test)
test_tc_str_range_tri_ok_350 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_range_tri_ok.json", t)
}

@(test)
test_tc_ref_union_singletons_bad_351 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ref_union_singletons_bad.json", t)
}

@(test)
test_tc_seq_tag_bad_352 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_seq_tag_bad.json", t)
}

@(test)
test_tc_execute_none_ok_353 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_execute_none_ok.json", t)
}

@(test)
test_tc_str_neg_concat_bad_354 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_neg_concat_bad.json", t)
}

@(test)
test_tc_ref_and_range_ok_355 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ref_and_range_ok.json", t)
}

@(test)
test_tc_cast_overflow_no_cast_fail_356 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cast_overflow_no_cast_fail.json", t)
}

@(test)
test_tc_str_backtick_exact_ok_357 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_backtick_exact_ok.json", t)
}

@(test)
test_tc_cast_unknown_forced_ok_358 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cast_unknown_forced_ok.json", t)
}

@(test)
test_tc_scope_two_ok_359 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_scope_two_ok.json", t)
}

@(test)
test_tc_scope_calc_two_refs_ok_360 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_scope_calc_two_refs_ok.json", t)
}

@(test)
test_tc_range_ok_361 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_range_ok.json", t)
}

@(test)
test_tc_char_rep_union_bad_362 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_char_rep_union_bad.json", t)
}

@(test)
test_tc_carve_override_is_ref_ok_363 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_override_is_ref_ok.json", t)
}

@(test)
test_tc_carve_nested_ok_364 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_nested_ok.json", t)
}

@(test)
test_tc_comp_double_and_ok_365 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_comp_double_and_ok.json", t)
}

@(test)
test_tc_str_pos_both_ok_366 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_pos_both_ok.json", t)
}

@(test)
test_tc_seq_two_classes_fewletters_bad_367 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_seq_two_classes_fewletters_bad.json", t)
}

@(test)
test_tc_str_char_bad_368 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_char_bad.json", t)
}

@(test)
test_tc_int_and_cast_u8_ok_369 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_int_and_cast_u8_ok.json", t)
}

@(test)
test_tc_str_concat_concrete_ok_370 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_concat_concrete_ok.json", t)
}

@(test)
test_tc_int_sub_range_lo_ok_371 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_int_sub_range_lo_ok.json", t)
}

@(test)
test_tc_neg10_ok_372 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg10_ok.json", t)
}

@(test)
test_tc_str_dquote_1char_pos_ok_373 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_dquote_1char_pos_ok.json", t)
}

@(test)
test_tc_self_singleton_ok_374 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_self_singleton_ok.json", t)
}

@(test)
test_tc_flt_range_ok_375 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_flt_range_ok.json", t)
}

@(test)
test_tc_flt_mul_concrete_ok_376 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_flt_mul_concrete_ok.json", t)
}

@(test)
test_tc_scope_calc_range_field_ok_377 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_scope_calc_range_field_ok.json", t)
}

@(test)
test_tc_str_squote_multi_pos_bad_378 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_squote_multi_pos_bad.json", t)
}

@(test)
test_tc_scope_calc_two_refs_bad_379 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_scope_calc_two_refs_bad.json", t)
}

@(test)
test_tc_nested_prop_380 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_nested_prop.json", t)
}

@(test)
test_tc_str_range_prefix_ok_381 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_range_prefix_ok.json", t)
}

@(test)
test_tc_scope_two_extra_bad_382 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_scope_two_extra_bad.json", t)
}

@(test)
test_tc_str_union_multi_ok_383 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_union_multi_ok.json", t)
}

@(test)
test_tc_mixed_str_in_strf32_384 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_mixed_str_in_strf32.json", t)
}

@(test)
test_tc_comp_double_and_bad_lo_385 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_comp_double_and_bad_lo.json", t)
}

@(test)
test_tc_u8_overflow_386 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_u8_overflow.json", t)
}

@(test)
test_tc_str_backtick_eq_dquote_ok_387 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_backtick_eq_dquote_ok.json", t)
}

@(test)
test_tc_int_mul_concrete_ok_388 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_int_mul_concrete_ok.json", t)
}

@(test)
test_tc_insoluble_untyped_389 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_insoluble_untyped.json", t)
}

@(test)
test_tc_comp_inter_unions_ok_390 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_comp_inter_unions_ok.json", t)
}

@(test)
test_tc_scope_uncolored_ok_391 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_scope_uncolored_ok.json", t)
}

@(test)
test_tc_insoluble_and_392 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_insoluble_and.json", t)
}

@(test)
test_tc_cmp_ge5_bad_393 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cmp_ge5_bad.json", t)
}

@(test)
test_tc_union_tri_int_ok_394 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_union_tri_int_ok.json", t)
}

