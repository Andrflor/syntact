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
test_tc_pat_prod_string_on_int_bad_3 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_prod_string_on_int_bad.json", t)
}

@(test)
test_tc_neg_ord_range_bad_4 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg_ord_range_bad.json", t)
}

@(test)
test_tc_carve_nested_bad_5 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_nested_bad.json", t)
}

@(test)
test_tc_str_range_prefix_bad_6 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_range_prefix_bad.json", t)
}

@(test)
test_tc_flt_add_concrete_ok_7 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_flt_add_concrete_ok.json", t)
}

@(test)
test_tc_carve_8 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve.json", t)
}

@(test)
test_tc_neg_str_exact_bad_9 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg_str_exact_bad.json", t)
}

@(test)
test_tc_str_concat_lit_class_bad_10 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_concat_lit_class_bad.json", t)
}

@(test)
test_tc_ref_singleton_other_bad_11 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ref_singleton_other_bad.json", t)
}

@(test)
test_tc_demorgan_ok_12 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_demorgan_ok.json", t)
}

@(test)
test_tc_prop_compute_bad_13 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_prop_compute_bad.json", t)
}

@(test)
test_tc_pat_float_value_nonexh_14 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_float_value_nonexh.json", t)
}

@(test)
test_tc_carve_as_type_via_ref_ok_15 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_as_type_via_ref_ok.json", t)
}

@(test)
test_tc_union_bool_int_float_bad_16 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_union_bool_int_float_bad.json", t)
}

@(test)
test_tc_pat_str_target_ok_17 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_str_target_ok.json", t)
}

@(test)
test_tc_pat_exh_value_singleton_18 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_exh_value_singleton.json", t)
}

@(test)
test_tc_pat_prod_execute_ok_19 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_prod_execute_ok.json", t)
}

@(test)
test_tc_ref_neg_range_ok_20 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ref_neg_range_ok.json", t)
}

@(test)
test_tc_ref_nested_mix_ok_21 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ref_nested_mix_ok.json", t)
}

@(test)
test_tc_flt_union_bad_22 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_flt_union_bad.json", t)
}

@(test)
test_tc_scope_prop_23 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_scope_prop.json", t)
}

@(test)
test_tc_neg_char_ok_24 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg_char_ok.json", t)
}

@(test)
test_tc_flt_sub_concrete_ok_25 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_flt_sub_concrete_ok.json", t)
}

@(test)
test_tc_execute_ref_producer_bad_26 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_execute_ref_producer_bad.json", t)
}

@(test)
test_tc_mixed_int_bad_27 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_mixed_int_bad.json", t)
}

@(test)
test_tc_ref_prop_arith_bad_28 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ref_prop_arith_bad.json", t)
}

@(test)
test_tc_str_squote_multi_pos_ok_29 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_squote_multi_pos_ok.json", t)
}

@(test)
test_tc_cmp_le100_ok_30 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cmp_le100_ok.json", t)
}

@(test)
test_tc_scope_two_second_overflow_bad_31 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_scope_two_second_overflow_bad.json", t)
}

@(test)
test_tc_refchain_constraint_ok_32 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_refchain_constraint_ok.json", t)
}

@(test)
test_tc_flt_inter_ok_33 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_flt_inter_ok.json", t)
}

@(test)
test_tc_execute_as_type_ok_34 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_execute_as_type_ok.json", t)
}

@(test)
test_tc_execute_set_not_element_bad_35 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_execute_set_not_element_bad.json", t)
}

@(test)
test_tc_pat_prod_arith_ok_36 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_prod_arith_ok.json", t)
}

@(test)
test_tc_execute_none_into_u8_bad_37 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_execute_none_into_u8_bad.json", t)
}

@(test)
test_tc_carve_pos_two_pushes_ok_38 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_pos_two_pushes_ok.json", t)
}

@(test)
test_tc_comp_tri_union_mid_ok_39 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_comp_tri_union_mid_ok.json", t)
}

@(test)
test_tc_execute_of_carve_overflow_bad_40 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_execute_of_carve_overflow_bad.json", t)
}

@(test)
test_tc_str_tri_range_nomid_bad_41 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_tri_range_nomid_bad.json", t)
}

@(test)
test_tc_cast_cross_domain_float_to_i32_ok_42 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cast_cross_domain_float_to_i32_ok.json", t)
}

@(test)
test_tc_unk_mul_u8_bad_43 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_unk_mul_u8_bad.json", t)
}

@(test)
test_tc_mixed_strint_int_44 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_mixed_strint_int.json", t)
}

@(test)
test_tc_pos_prefix_bad_45 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pos_prefix_bad.json", t)
}

@(test)
test_tc_carve_pos_only_pull_out_of_range_bad_46 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_pos_only_pull_out_of_range_bad.json", t)
}

@(test)
test_tc_pat_target_carve_ok_47 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_target_carve_ok.json", t)
}

@(test)
test_tc_union_char_int_str_ok_48 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_union_char_int_str_ok.json", t)
}

@(test)
test_tc_neg_int_ok_49 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg_int_ok.json", t)
}

@(test)
test_tc_int_sub_u8u8_u8_default0_ok_50 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_int_sub_u8u8_u8_default0_ok.json", t)
}

@(test)
test_tc_union_rep_ok_51 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_union_rep_ok.json", t)
}

@(test)
test_tc_cast_u8_to_f32_ok_52 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cast_u8_to_f32_ok.json", t)
}

@(test)
test_tc_scope_shape_ok_53 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_scope_shape_ok.json", t)
}

@(test)
test_tc_int_and_gt_ok_54 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_int_and_gt_ok.json", t)
}

@(test)
test_tc_cast_target_unsized_float_fail_55 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cast_target_unsized_float_fail.json", t)
}

@(test)
test_tc_pat_mixed_modes_exh_56 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_mixed_modes_exh.json", t)
}

@(test)
test_tc_pos_str_bad_57 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pos_str_bad.json", t)
}

@(test)
test_tc_execute_as_type_bad_58 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_execute_as_type_bad.json", t)
}

@(test)
test_tc_int_mul_range_u16_ok_59 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_int_mul_range_u16_ok.json", t)
}

@(test)
test_tc_comp_inter_unions_bad2_60 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_comp_inter_unions_bad2.json", t)
}

@(test)
test_tc_cmp_lt0_ok_61 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cmp_lt0_ok.json", t)
}

@(test)
test_tc_str_rep_range_bad_62 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_rep_range_bad.json", t)
}

@(test)
test_tc_str_neg_plus_lit_bad_63 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_neg_plus_lit_bad.json", t)
}

@(test)
test_tc_ref_arith_nested_bad_64 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ref_arith_nested_bad.json", t)
}

@(test)
test_tc_str_union_pat_ok_65 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_union_pat_ok.json", t)
}

@(test)
test_tc_pat_bool_typecheck_exh_66 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_bool_typecheck_exh.json", t)
}

@(test)
test_tc_pos_prefix_ok_67 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pos_prefix_ok.json", t)
}

@(test)
test_tc_str_neg_word_seq_bad_68 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_neg_word_seq_bad.json", t)
}

@(test)
test_tc_neg_triple_bad_69 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg_triple_bad.json", t)
}

@(test)
test_tc_pull_three_last_diverges_bad_70 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pull_three_last_diverges_bad.json", t)
}

@(test)
test_tc_self_u8_bad_71 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_self_u8_bad.json", t)
}

@(test)
test_tc_neg_str_exact_ok_72 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg_str_exact_ok.json", t)
}

@(test)
test_tc_prop_compute_ok_73 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_prop_compute_ok.json", t)
}

@(test)
test_tc_int_sub_concrete_ok_74 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_int_sub_concrete_ok.json", t)
}

@(test)
test_tc_pat_prod_int_overflow_bad_75 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_prod_int_overflow_bad.json", t)
}

@(test)
test_tc_pat_combined_bool_string_bad_76 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_combined_bool_string_bad.json", t)
}

@(test)
test_tc_pat_default_first_77 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_default_first.json", t)
}

@(test)
test_tc_neg_or_self_ok_78 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg_or_self_ok.json", t)
}

@(test)
test_tc_prod_ok_79 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_prod_ok.json", t)
}

@(test)
test_tc_str_neg_ord_class_bad_80 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_neg_ord_class_bad.json", t)
}

@(test)
test_tc_bool_false_bad_81 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_bool_false_bad.json", t)
}

@(test)
test_tc_seq_email_ok_82 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_seq_email_ok.json", t)
}

@(test)
test_tc_neg_ord_range_ok_83 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg_ord_range_ok.json", t)
}

@(test)
test_tc_insoluble_neg_84 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_insoluble_neg.json", t)
}

@(test)
test_tc_carve_pos_skips_pull_second_ok_85 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_pos_skips_pull_second_ok.json", t)
}

@(test)
test_tc_comp_tri_union_gap_bad_86 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_comp_tri_union_gap_bad.json", t)
}

@(test)
test_tc_str_tri_range_contains_ok_87 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_tri_range_contains_ok.json", t)
}

@(test)
test_tc_cmp_le100_bad_88 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cmp_le100_bad.json", t)
}

@(test)
test_tc_pat_exh_union_covers_89 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_exh_union_covers.json", t)
}

@(test)
test_tc_ref_arith_ok_90 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ref_arith_ok.json", t)
}

@(test)
test_tc_carve_impl_dep_bad_91 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_impl_dep_bad.json", t)
}

@(test)
test_tc_scope_field_union_bad_92 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_scope_field_union_bad.json", t)
}

@(test)
test_tc_str_concat_lit_class_ok_93 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_concat_lit_class_ok.json", t)
}

@(test)
test_tc_insoluble_nested_compose_94 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_insoluble_nested_compose.json", t)
}

@(test)
test_tc_cast_sum_no_cast_bad_95 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cast_sum_no_cast_bad.json", t)
}

@(test)
test_tc_neg_int_bad_96 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg_int_bad.json", t)
}

@(test)
test_tc_demorgan_deep_ok_97 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_demorgan_deep_ok.json", t)
}

@(test)
test_tc_execute_carve_as_type_ok_98 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_execute_carve_as_type_ok.json", t)
}

@(test)
test_tc_comp_and_or_ok_neg_99 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_comp_and_or_ok_neg.json", t)
}

@(test)
test_tc_refchain_triple_ok_100 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_refchain_triple_ok.json", t)
}

@(test)
test_tc_union_u8_f32_str_bad_101 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_union_u8_f32_str_bad.json", t)
}

@(test)
test_tc_pat_exh_default_102 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_exh_default.json", t)
}

@(test)
test_tc_execute_constraint_fail_103 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_execute_constraint_fail.json", t)
}

@(test)
test_tc_carve_pos_skips_pull_overflow_bad_104 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_pos_skips_pull_overflow_bad.json", t)
}

@(test)
test_tc_char_rep_union_ok_105 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_char_rep_union_ok.json", t)
}

@(test)
test_tc_cross_str_int_106 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cross_str_int.json", t)
}

@(test)
test_tc_cast_target_int_fail_107 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cast_target_int_fail.json", t)
}

@(test)
test_tc_cast_target_open_fail_108 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cast_target_open_fail.json", t)
}

@(test)
test_tc_neg_or_negs_none_bad_109 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg_or_negs_none_bad.json", t)
}

@(test)
test_tc_ord_char_ok_110 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ord_char_ok.json", t)
}

@(test)
test_tc_soluble_unknown_value_ok_111 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_soluble_unknown_value_ok.json", t)
}

@(test)
test_tc_flt_mul_range_bad_112 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_flt_mul_range_bad.json", t)
}

@(test)
test_tc_cast_bool_to_u8_ok_113 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cast_bool_to_u8_ok.json", t)
}

@(test)
test_tc_insoluble_direct_114 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_insoluble_direct.json", t)
}

@(test)
test_tc_insoluble_ref_chain_115 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_insoluble_ref_chain.json", t)
}

@(test)
test_tc_scope_calc_mul_bad_116 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_scope_calc_mul_bad.json", t)
}

@(test)
test_tc_rep_range_ok_117 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_rep_range_ok.json", t)
}

@(test)
test_tc_cast_target_disjoint_union_fail_118 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cast_target_disjoint_union_fail.json", t)
}

@(test)
test_tc_cmp_gt5_bad_119 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cmp_gt5_bad.json", t)
}

@(test)
test_tc_cast_neg_into_u8_ok_120 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cast_neg_into_u8_ok.json", t)
}

@(test)
test_tc_seq_email_bad_121 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_seq_email_bad.json", t)
}

@(test)
test_tc_carve_implicit_override_both_ok_122 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_implicit_override_both_ok.json", t)
}

@(test)
test_tc_ref_arith_overflow_bad_123 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ref_arith_overflow_bad.json", t)
}

@(test)
test_tc_pat_insoluble_target_unknown_124 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_insoluble_target_unknown.json", t)
}

@(test)
test_tc_bool_union_true_ok_125 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_bool_union_true_ok.json", t)
}

@(test)
test_tc_execute_of_carve_ok_126 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_execute_of_carve_ok.json", t)
}

@(test)
test_tc_str_union_pat_bad_127 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_union_pat_bad.json", t)
}

@(test)
test_tc_cast_target_range_no_layout_fail_128 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cast_target_range_no_layout_fail.json", t)
}

@(test)
test_tc_rep_exact_bad_129 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_rep_exact_bad.json", t)
}

@(test)
test_tc_int_mul_concrete_bad_130 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_int_mul_concrete_bad.json", t)
}

@(test)
test_tc_neg_char_bad_131 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg_char_bad.json", t)
}

@(test)
test_tc_unk_sub_u8_bad_132 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_unk_sub_u8_bad.json", t)
}

@(test)
test_tc_ref_neg_singleton_bad2_133 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ref_neg_singleton_bad2.json", t)
}

@(test)
test_tc_str_backtick_range_ok_134 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_backtick_range_ok.json", t)
}

@(test)
test_tc_str_range_pos_edge_ok_135 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_range_pos_edge_ok.json", t)
}

@(test)
test_tc_str_rep_exact_bad_136 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_rep_exact_bad.json", t)
}

@(test)
test_tc_cast_target_neg_union_fail_137 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cast_target_neg_union_fail.json", t)
}

@(test)
test_tc_str_rep_range_ok_138 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_rep_range_ok.json", t)
}

@(test)
test_tc_int_sub_range_bad_139 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_int_sub_range_bad.json", t)
}

@(test)
test_tc_ref_range_and_bad_140 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ref_range_and_bad.json", t)
}

@(test)
test_tc_int_mixed_sign_u16_bad_141 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_int_mixed_sign_u16_bad.json", t)
}

@(test)
test_tc_scope_union_ok1_142 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_scope_union_ok1.json", t)
}

@(test)
test_tc_carve_implicit_compose_compensated_ok_143 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_implicit_compose_compensated_ok.json", t)
}

@(test)
test_tc_pull_named_only_ok_144 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pull_named_only_ok.json", t)
}

@(test)
test_tc_pull_three_agree_ok_145 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pull_three_agree_ok.json", t)
}

@(test)
test_tc_neg_and_neg_bad_146 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg_and_neg_bad.json", t)
}

@(test)
test_tc_cmp_gt5_ok_147 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cmp_gt5_ok.json", t)
}

@(test)
test_tc_scope_calc_range_field_bad_148 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_scope_calc_range_field_bad.json", t)
}

@(test)
test_tc_pat_nonexh_singleton_wrong_149 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_nonexh_singleton_wrong.json", t)
}

@(test)
test_tc_prop_as_value_ok_150 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_prop_as_value_ok.json", t)
}

@(test)
test_tc_cast_char_to_u8_ok_151 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cast_char_to_u8_ok.json", t)
}

@(test)
test_tc_pat_target_arith_exh_152 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_target_arith_exh.json", t)
}

@(test)
test_tc_self_bool_singleton_ok_153 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_self_bool_singleton_ok.json", t)
}

@(test)
test_tc_execute_empty_none_fail_154 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_execute_empty_none_fail.json", t)
}

@(test)
test_tc_bool_neg_true_bad_155 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_bool_neg_true_bad.json", t)
}

@(test)
test_tc_carve_as_type_via_ref_bad_156 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_as_type_via_ref_bad.json", t)
}

@(test)
test_tc_pat_prod_set_bad_157 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_prod_set_bad.json", t)
}

@(test)
test_tc_insoluble_scope_field_158 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_insoluble_scope_field.json", t)
}

@(test)
test_tc_bool_union_false_ok_159 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_bool_union_false_ok.json", t)
}

@(test)
test_tc_mixed_strint_str_160 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_mixed_strint_str.json", t)
}

@(test)
test_tc_str_neg_ord_range_one_ok_161 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_neg_ord_range_one_ok.json", t)
}

@(test)
test_tc_union_u8_f32_float_ok_162 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_union_u8_f32_float_ok.json", t)
}

@(test)
test_tc_insoluble_colored_binding_163 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_insoluble_colored_binding.json", t)
}

@(test)
test_tc_pat_nested_ok_164 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_nested_ok.json", t)
}

@(test)
test_tc_execute_value_overflow_bad_165 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_execute_value_overflow_bad.json", t)
}

@(test)
test_tc_prod_u8_166 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_prod_u8.json", t)
}

@(test)
test_tc_str_concat_pattern_bad_167 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_concat_pattern_bad.json", t)
}

@(test)
test_tc_cast_target_bool_ok_168 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cast_target_bool_ok.json", t)
}

@(test)
test_tc_demorgan_bad_169 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_demorgan_bad.json", t)
}

@(test)
test_tc_union_tri_str_ok_170 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_union_tri_str_ok.json", t)
}

@(test)
test_tc_seq_range_count_ok_171 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_seq_range_count_ok.json", t)
}

@(test)
test_tc_comp_negrange_or_pt_ok5_172 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_comp_negrange_or_pt_ok5.json", t)
}

@(test)
test_tc_pat_target_arith_nonexh_173 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_target_arith_nonexh.json", t)
}

@(test)
test_tc_str_concat_pattern_ok_174 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_concat_pattern_ok.json", t)
}

@(test)
test_tc_seq_range_count_bad_175 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_seq_range_count_bad.json", t)
}

@(test)
test_tc_cmp_gt6f_bad_176 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cmp_gt6f_bad.json", t)
}

@(test)
test_tc_prop_family_bad_177 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_prop_family_bad.json", t)
}

@(test)
test_tc_bool_true_ok_178 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_bool_true_ok.json", t)
}

@(test)
test_tc_ref_nested_mix_bad_179 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ref_nested_mix_bad.json", t)
}

@(test)
test_tc_union_u8_f32_overflow_bad_180 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_union_u8_f32_overflow_bad.json", t)
}

@(test)
test_tc_str_union_mixed_len_ok_181 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_union_mixed_len_ok.json", t)
}

@(test)
test_tc_scope_shape_wrong_name_bad_182 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_scope_shape_wrong_name_bad.json", t)
}

@(test)
test_tc_carve_property_ok_183 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_property_ok.json", t)
}

@(test)
test_tc_cast_f64_to_f32_ok_184 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cast_f64_to_f32_ok.json", t)
}

@(test)
test_tc_comp_and_or_ok_hi_185 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_comp_and_or_ok_hi.json", t)
}

@(test)
test_tc_int_and_gt_bad_186 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_int_and_gt_bad.json", t)
}

@(test)
test_tc_scope_shape_calc_bad_187 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_scope_shape_calc_bad.json", t)
}

@(test)
test_tc_self_char_singleton_ok_188 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_self_char_singleton_ok.json", t)
}

@(test)
test_tc_demorgan_deep_bad_189 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_demorgan_deep_bad.json", t)
}

@(test)
test_tc_ref_neg_singleton_bad_190 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ref_neg_singleton_bad.json", t)
}

@(test)
test_tc_carve_value_ok_191 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_value_ok.json", t)
}

@(test)
test_tc_neg_or_self_other_ok_192 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg_or_self_other_ok.json", t)
}

@(test)
test_tc_pat_mixed_modes_gap_193 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_mixed_modes_gap.json", t)
}

@(test)
test_tc_flt_neg_bad_194 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_flt_neg_bad.json", t)
}

@(test)
test_tc_flt_union_ok_195 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_flt_union_ok.json", t)
}

@(test)
test_tc_ref_union_singletons_ok_196 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ref_union_singletons_ok.json", t)
}

@(test)
test_tc_pat_exh_value_open_range_197 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_exh_value_open_range.json", t)
}

@(test)
test_tc_self_str_singleton_ok_198 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_self_str_singleton_ok.json", t)
}

@(test)
test_tc_prod_nest_ok_199 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_prod_nest_ok.json", t)
}

@(test)
test_tc_rep_exact_ok_200 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_rep_exact_ok.json", t)
}

@(test)
test_tc_str_union_class_literal_bad_201 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_union_class_literal_bad.json", t)
}

@(test)
test_tc_pat_bool_nonexh_202 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_bool_nonexh.json", t)
}

@(test)
test_tc_carve_property_compute_bad_203 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_property_compute_bad.json", t)
}

@(test)
test_tc_execute_ref_binding_ok_204 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_execute_ref_binding_ok.json", t)
}

@(test)
test_tc_neg_double_ok_205 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg_double_ok.json", t)
}

@(test)
test_tc_union_rep_bad_206 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_union_rep_bad.json", t)
}

@(test)
test_tc_flt_inter_bad_207 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_flt_inter_bad.json", t)
}

@(test)
test_tc_str_tri_range_nosuffix_bad_208 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_tri_range_nosuffix_bad.json", t)
}

@(test)
test_tc_cast_target_unbounded_int_fail_209 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cast_target_unbounded_int_fail.json", t)
}

@(test)
test_tc_ref_and_range_bad_210 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ref_and_range_bad.json", t)
}

@(test)
test_tc_scope_nested_bad_211 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_scope_nested_bad.json", t)
}

@(test)
test_tc_scope_nested_ok_212 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_scope_nested_ok.json", t)
}

@(test)
test_tc_seq_two_classes_ok_213 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_seq_two_classes_ok.json", t)
}

@(test)
test_tc_bool_true_bad_214 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_bool_true_bad.json", t)
}

@(test)
test_tc_cmp_gt6f_ok_215 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cmp_gt6f_ok.json", t)
}

@(test)
test_tc_flt_open_lo_ok_216 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_flt_open_lo_ok.json", t)
}

@(test)
test_tc_union_char_alts_ok_217 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_union_char_alts_ok.json", t)
}

@(test)
test_tc_str_concat_lit_class_prefix_bad_218 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_concat_lit_class_prefix_bad.json", t)
}

@(test)
test_tc_execute_carve_as_type_bad_219 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_execute_carve_as_type_bad.json", t)
}

@(test)
test_tc_cast_sum_overflow_forced_ok_220 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cast_sum_overflow_forced_ok.json", t)
}

@(test)
test_tc_neg_pos_bad_221 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg_pos_bad.json", t)
}

@(test)
test_tc_int_and_cast_i8_ok_222 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_int_and_cast_i8_ok.json", t)
}

@(test)
test_tc_str_ord_below_bad_223 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_ord_below_bad.json", t)
}

@(test)
test_tc_str_backtick_exact_bad_224 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_backtick_exact_bad.json", t)
}

@(test)
test_tc_refchain_constraint_bad_225 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_refchain_constraint_bad.json", t)
}

@(test)
test_tc_insoluble_via_binding_226 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_insoluble_via_binding.json", t)
}

@(test)
test_tc_scope_calc_field_bad_227 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_scope_calc_field_bad.json", t)
}

@(test)
test_tc_mixed_strint_float_228 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_mixed_strint_float.json", t)
}

@(test)
test_tc_carve_then_execute_ok_229 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_then_execute_ok.json", t)
}

@(test)
test_tc_carve_impl_dep_compensated_ok_230 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_impl_dep_compensated_ok.json", t)
}

@(test)
test_tc_str_neg_concat_digits_ok_231 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_neg_concat_digits_ok.json", t)
}

@(test)
test_tc_insoluble_range_232 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_insoluble_range.json", t)
}

@(test)
test_tc_str_union_class_literal_ok_233 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_union_class_literal_ok.json", t)
}

@(test)
test_tc_str_rep_exact_ok_234 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_rep_exact_ok.json", t)
}

@(test)
test_tc_neg_and_negs_ok_235 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg_and_negs_ok.json", t)
}

@(test)
test_tc_str_neg_ord_range_multi_bad_236 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_neg_ord_range_multi_bad.json", t)
}

@(test)
test_tc_comp_negrange_or_pt_bad_237 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_comp_negrange_or_pt_bad.json", t)
}

@(test)
test_tc_union_bad_238 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_union_bad.json", t)
}

@(test)
test_tc_str_dquote_1char_pos_bad_239 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_dquote_1char_pos_bad.json", t)
}

@(test)
test_tc_str_union_multi_bad_240 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_union_multi_bad.json", t)
}

@(test)
test_tc_scope_shape_wrong_family_bad_241 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_scope_shape_wrong_family_bad.json", t)
}

@(test)
test_tc_self_range_bad_242 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_self_range_bad.json", t)
}

@(test)
test_tc_pat_prod_ref_overflow_bad_243 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_prod_ref_overflow_bad.json", t)
}

@(test)
test_tc_str_pos_prefix_bad_244 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_pos_prefix_bad.json", t)
}

@(test)
test_tc_str_char_ok_245 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_char_ok.json", t)
}

@(test)
test_tc_carve_override_ok_246 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_override_ok.json", t)
}

@(test)
test_tc_cross_range_247 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cross_range.json", t)
}

@(test)
test_tc_unk_sub_i16_ok_248 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_unk_sub_i16_ok.json", t)
}

@(test)
test_tc_pat_target_ref_ok_249 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_target_ref_ok.json", t)
}

@(test)
test_tc_str_backtick_in_string_ok_250 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_backtick_in_string_ok.json", t)
}

@(test)
test_tc_ident_no_trail_bad_251 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ident_no_trail_bad.json", t)
}

@(test)
test_tc_str_neg_word_seq_ok_252 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_neg_word_seq_ok.json", t)
}

@(test)
test_tc_str_rep_concrete_ok_253 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_rep_concrete_ok.json", t)
}

@(test)
test_tc_pull_named_vs_struct_agree_ok_254 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pull_named_vs_struct_agree_ok.json", t)
}

@(test)
test_tc_neg_triple_ok_255 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg_triple_ok.json", t)
}

@(test)
test_tc_unk_add_u16_ok_256 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_unk_add_u16_ok.json", t)
}

@(test)
test_tc_str_range_pos_nosuffix_bad_257 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_range_pos_nosuffix_bad.json", t)
}

@(test)
test_tc_str_range_tri_nomid_bad_258 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_range_tri_nomid_bad.json", t)
}

@(test)
test_tc_int_sub_u8u8_i16_ok_259 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_int_sub_u8u8_i16_ok.json", t)
}

@(test)
test_tc_prod_nest_bad_260 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_prod_nest_bad.json", t)
}

@(test)
test_tc_str_neg_concat_ok_261 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_neg_concat_ok.json", t)
}

@(test)
test_tc_union_char_alts_bad_262 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_union_char_alts_bad.json", t)
}

@(test)
test_tc_ref_prop_arith_ok_263 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ref_prop_arith_ok.json", t)
}

@(test)
test_tc_union_char_int_char_ok_264 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_union_char_int_char_ok.json", t)
}

@(test)
test_tc_neg_ord_ok_265 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg_ord_ok.json", t)
}

@(test)
test_tc_flt_add_range_ok_266 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_flt_add_range_ok.json", t)
}

@(test)
test_tc_str_tri_range_middle_ok_267 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_tri_range_middle_ok.json", t)
}

@(test)
test_tc_char_union_neg_ok_268 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_char_union_neg_ok.json", t)
}

@(test)
test_tc_carve_implicit_independent_ok_269 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_implicit_independent_ok.json", t)
}

@(test)
test_tc_neg_union_ok_270 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg_union_ok.json", t)
}

@(test)
test_tc_str_tri_range_url_ok_271 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_tri_range_url_ok.json", t)
}

@(test)
test_tc_bool_any_true_ok_272 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_bool_any_true_ok.json", t)
}

@(test)
test_tc_soluble_singleton_ref_ok_273 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_soluble_singleton_ref_ok.json", t)
}

@(test)
test_tc_execute_chain_ref_ok_274 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_execute_chain_ref_ok.json", t)
}

@(test)
test_tc_int_sub_concrete_bad_275 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_int_sub_concrete_bad.json", t)
}

@(test)
test_tc_int_mod_opaque_int_ok_276 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_int_mod_opaque_int_ok.json", t)
}

@(test)
test_tc_pat_two_values_nonexh_277 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_two_values_nonexh.json", t)
}

@(test)
test_tc_soluble_set_constraint_ok_278 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_soluble_set_constraint_ok.json", t)
}

@(test)
test_tc_str_neg_ord_seq_nonull_bad_279 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_neg_ord_seq_nonull_bad.json", t)
}

@(test)
test_tc_neg_and_neg_ok_280 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg_and_neg_ok.json", t)
}

@(test)
test_tc_self_ref_singleton_ok_281 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_self_ref_singleton_ok.json", t)
}

@(test)
test_tc_pull_conflict_bad_282 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pull_conflict_bad.json", t)
}

@(test)
test_tc_pat_nonexh_value_open_283 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_nonexh_value_open.json", t)
}

@(test)
test_tc_carve_implicit_ref_fail_284 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_implicit_ref_fail.json", t)
}

@(test)
test_tc_bool_inter_empty_bad_285 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_bool_inter_empty_bad.json", t)
}

@(test)
test_tc_flt_add_range_bad_286 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_flt_add_range_bad.json", t)
}

@(test)
test_tc_scope_calc_field_ok_287 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_scope_calc_field_ok.json", t)
}

@(test)
test_tc_scope_two_order_bad_288 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_scope_two_order_bad.json", t)
}

@(test)
test_tc_int_and_empty_bad_289 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_int_and_empty_bad.json", t)
}

@(test)
test_tc_bool_neg_true_ok_290 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_bool_neg_true_ok.json", t)
}

@(test)
test_tc_execute_ref_producer_ok_291 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_execute_ref_producer_ok.json", t)
}

@(test)
test_tc_self_ref_set_bad_292 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_self_ref_set_bad.json", t)
}

@(test)
test_tc_pat_nested_overflow_bad_293 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_nested_overflow_bad.json", t)
}

@(test)
test_tc_cast_cross_domain_string_to_u8_ok_294 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cast_cross_domain_string_to_u8_ok.json", t)
}

@(test)
test_tc_ref_or_family_ok_295 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ref_or_family_ok.json", t)
}

@(test)
test_tc_pat_prod_float_ok_296 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_prod_float_ok.json", t)
}

@(test)
test_tc_neg_union_bad5_297 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg_union_bad5.json", t)
}

@(test)
test_tc_str_range_tri_contiguous_ok_298 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_range_tri_contiguous_ok.json", t)
}

@(test)
test_tc_bool_inter_same_ok_299 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_bool_inter_same_ok.json", t)
}

@(test)
test_tc_str_backtick_union_ok_300 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_backtick_union_ok.json", t)
}

@(test)
test_tc_cast_into_i8_ok_301 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cast_into_i8_ok.json", t)
}

@(test)
test_tc_insoluble_arith_operand_302 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_insoluble_arith_operand.json", t)
}

@(test)
test_tc_union_u8_f32_int_ok_303 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_union_u8_f32_int_ok.json", t)
}

@(test)
test_tc_cast_unknown_sum_overflow_fail_304 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cast_unknown_sum_overflow_fail.json", t)
}

@(test)
test_tc_carve_pos_out_of_range_bad_305 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_pos_out_of_range_bad.json", t)
}

@(test)
test_tc_int_add_u8u8_u16_ok_306 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_int_add_u8u8_u16_ok.json", t)
}

@(test)
test_tc_pull_unify_ok_307 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pull_unify_ok.json", t)
}

@(test)
test_tc_str_pos_both_bad_308 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_pos_both_bad.json", t)
}

@(test)
test_tc_int_add_overflow_bad_309 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_int_add_overflow_bad.json", t)
}

@(test)
test_tc_str_neg_ord_seq_short_ok_310 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_neg_ord_seq_short_ok.json", t)
}

@(test)
test_tc_pat_target_execute_ok_311 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_target_execute_ok.json", t)
}

@(test)
test_tc_ref_arith_nested_ok_312 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ref_arith_nested_ok.json", t)
}

@(test)
test_tc_cast_overflow_into_u8_ok_313 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cast_overflow_into_u8_ok.json", t)
}

@(test)
test_tc_scope_two_missing_bad_314 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_scope_two_missing_bad.json", t)
}

@(test)
test_tc_int_add_concrete_ok_315 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_int_add_concrete_ok.json", t)
}

@(test)
test_tc_ref_neg_singleton_ok2_316 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ref_neg_singleton_ok2.json", t)
}

@(test)
test_tc_comp_inter_unions_bad_317 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_comp_inter_unions_bad.json", t)
}

@(test)
test_tc_ref_range_and_ok_318 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ref_range_and_ok.json", t)
}

@(test)
test_tc_str_dquote_1char_pos_az_ok_319 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_dquote_1char_pos_az_ok.json", t)
}

@(test)
test_tc_str_neg_ord_class_ok_320 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_neg_ord_class_ok.json", t)
}

@(test)
test_tc_neg_range_bad_321 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg_range_bad.json", t)
}

@(test)
test_tc_str_ord_above_bad_322 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_ord_above_bad.json", t)
}

@(test)
test_tc_seq_backtrack_ok_323 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_seq_backtrack_ok.json", t)
}

@(test)
test_tc_scope_mixed_fields_ok_324 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_scope_mixed_fields_ok.json", t)
}

@(test)
test_tc_ref_neg_singleton_ok_325 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ref_neg_singleton_ok.json", t)
}

@(test)
test_tc_execute_value_fail_326 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_execute_value_fail.json", t)
}

@(test)
test_tc_inter_str_int_none_bad_327 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_inter_str_int_none_bad.json", t)
}

@(test)
test_tc_scope_union_ok2_328 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_scope_union_ok2.json", t)
}

@(test)
test_tc_pull_named_vs_struct_conflict_bad_329 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pull_named_vs_struct_conflict_bad.json", t)
}

@(test)
test_tc_cast_unknown_sum_recast_ok_330 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cast_unknown_sum_recast_ok.json", t)
}

@(test)
test_tc_unk_mul_u16_ok_331 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_unk_mul_u16_ok.json", t)
}

@(test)
test_tc_rep_char_bad_332 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_rep_char_bad.json", t)
}

@(test)
test_tc_ref_neg_range_bad_333 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ref_neg_range_bad.json", t)
}

@(test)
test_tc_neg10_bad_334 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg10_bad.json", t)
}

@(test)
test_tc_pat_prod_string_ok_335 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_prod_string_ok.json", t)
}

@(test)
test_tc_ord_char_bad_336 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ord_char_bad.json", t)
}

@(test)
test_tc_flt_range_bad_337 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_flt_range_bad.json", t)
}

@(test)
test_tc_u8_ok_338 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_u8_ok.json", t)
}

@(test)
test_tc_carve_implicit_compose_fail_339 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_implicit_compose_fail.json", t)
}

@(test)
test_tc_carve_override_ref_overflow_bad_340 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_override_ref_overflow_bad.json", t)
}

@(test)
test_tc_neg_pos_ok_341 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg_pos_ok.json", t)
}

@(test)
test_tc_cmp_lt0_bad_342 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cmp_lt0_bad.json", t)
}

@(test)
test_tc_str_backtick_union_bad_343 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_backtick_union_bad.json", t)
}

@(test)
test_tc_pat_exh_typecheck_full_344 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_exh_typecheck_full.json", t)
}

@(test)
test_tc_neg_union_bad10_345 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg_union_bad10.json", t)
}

@(test)
test_tc_scope_field_union_ok_346 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_scope_field_union_ok.json", t)
}

@(test)
test_tc_union_char_int_bad_347 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_union_char_int_bad.json", t)
}

@(test)
test_tc_flt_add_concrete_bad_348 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_flt_add_concrete_bad.json", t)
}

@(test)
test_tc_mixed_float_349 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_mixed_float.json", t)
}

@(test)
test_tc_comp_and_or_bad_gap_350 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_comp_and_or_bad_gap.json", t)
}

@(test)
test_tc_str_ord_mid_ok_351 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_ord_mid_ok.json", t)
}

@(test)
test_tc_neg_and_negs_bad_352 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg_and_negs_bad.json", t)
}

@(test)
test_tc_bool_false_ok_353 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_bool_false_ok.json", t)
}

@(test)
test_tc_scope_shape_overflow_bad_354 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_scope_shape_overflow_bad.json", t)
}

@(test)
test_tc_int_div_opaque_int_ok_355 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_int_div_opaque_int_ok.json", t)
}

@(test)
test_tc_flt_neg_ok_356 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_flt_neg_ok.json", t)
}

@(test)
test_tc_str_neg_word_lit_ok_357 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_neg_word_lit_ok.json", t)
}

@(test)
test_tc_comp_inter_unions_ok2_358 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_comp_inter_unions_ok2.json", t)
}

@(test)
test_tc_union_tri_bool_bad_359 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_union_tri_bool_bad.json", t)
}

@(test)
test_tc_str_range_pos_noprefix_bad_360 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_range_pos_noprefix_bad.json", t)
}

@(test)
test_tc_pat_combined_bool_string_ok_361 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_combined_bool_string_ok.json", t)
}

@(test)
test_tc_cast_then_overflow_ok_362 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cast_then_overflow_ok.json", t)
}

@(test)
test_tc_pat_combined_union_ok_363 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_combined_union_ok.json", t)
}

@(test)
test_tc_str_range_pos_mid_ok_364 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_range_pos_mid_ok.json", t)
}

@(test)
test_tc_carve_override_bad_365 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_override_bad.json", t)
}

@(test)
test_tc_comp_double_and_bad_hi_366 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_comp_double_and_bad_hi.json", t)
}

@(test)
test_tc_bool_neg_false_ok_367 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_bool_neg_false_ok.json", t)
}

@(test)
test_tc_str_union_class_literal_class_ok_368 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_union_class_literal_class_ok.json", t)
}

@(test)
test_tc_str_pos_prefix_ok_369 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_pos_prefix_ok.json", t)
}

@(test)
test_tc_self_string_set_bad_370 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_self_string_set_bad.json", t)
}

@(test)
test_tc_pat_char_value_ok_371 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_char_value_ok.json", t)
}

@(test)
test_tc_ident_ok_372 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ident_ok.json", t)
}

@(test)
test_tc_pat_float_typecheck_exh_373 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_float_typecheck_exh.json", t)
}

@(test)
test_tc_union_tri_float_ok_374 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_union_tri_float_ok.json", t)
}

@(test)
test_tc_ident_no_trail_ok_375 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ident_no_trail_ok.json", t)
}

@(test)
test_tc_union_char_alts_up_ok_376 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_union_char_alts_up_ok.json", t)
}

@(test)
test_tc_char_union_neg_bad_377 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_char_union_neg_bad.json", t)
}

@(test)
test_tc_pat_combined_union_bad_378 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_combined_union_bad.json", t)
}

@(test)
test_tc_scope_shape_calc_ok_379 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_scope_shape_calc_ok.json", t)
}

@(test)
test_tc_int_add_u8u8_u8_default0_ok_380 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_int_add_u8u8_u8_default0_ok.json", t)
}

@(test)
test_tc_str_neg_word_lit_bad_381 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_neg_word_lit_bad.json", t)
}

@(test)
test_tc_pat_prod_bool_ok_382 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_prod_bool_ok.json", t)
}

@(test)
test_tc_flt_mul_range_ok_383 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_flt_mul_range_ok.json", t)
}

@(test)
test_tc_str_neg_plus_lit_ok_384 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_neg_plus_lit_ok.json", t)
}

@(test)
test_tc_seq_tag_ok_385 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_seq_tag_ok.json", t)
}

@(test)
test_tc_int_mixed_sign_i16_ok_386 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_int_mixed_sign_i16_ok.json", t)
}

@(test)
test_tc_ref_or_family_bad_387 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ref_or_family_bad.json", t)
}

@(test)
test_tc_ident_bad_388 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ident_bad.json", t)
}

@(test)
test_tc_refchain_triple_bad_389 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_refchain_triple_bad.json", t)
}

@(test)
test_tc_execute_empty_none_ok_390 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_execute_empty_none_ok.json", t)
}

@(test)
test_tc_int_sub_range_hi_ok_391 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_int_sub_range_hi_ok.json", t)
}

@(test)
test_tc_pat_prod_cast_ok_392 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_prod_cast_ok.json", t)
}

@(test)
test_tc_pat_char_value_nonexh_393 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_char_value_nonexh.json", t)
}

@(test)
test_tc_carve_value_override_bad_394 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_value_override_bad.json", t)
}

@(test)
test_tc_cast_i32_to_f32_ok_395 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cast_i32_to_f32_ok.json", t)
}

@(test)
test_tc_int_mul_range_u8_default0_ok_396 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_int_mul_range_u8_default0_ok.json", t)
}

@(test)
test_tc_execute_constraint_ok_397 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_execute_constraint_ok.json", t)
}

@(test)
test_tc_bool_any_false_ok_398 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_bool_any_false_ok.json", t)
}

@(test)
test_tc_pat_prod_int_ok_399 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_prod_int_ok.json", t)
}

@(test)
test_tc_neg_double_bad_400 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg_double_bad.json", t)
}

@(test)
test_tc_insoluble_or_401 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_insoluble_or.json", t)
}

@(test)
test_tc_pat_nonexh_gap_402 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_nonexh_gap.json", t)
}

@(test)
test_tc_pat_prod_arith_overflow_bad_403 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_prod_arith_overflow_bad.json", t)
}

@(test)
test_tc_union_bool_int_ok_404 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_union_bool_int_ok.json", t)
}

@(test)
test_tc_seq_two_classes_short_bad_405 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_seq_two_classes_short_bad.json", t)
}

@(test)
test_tc_ref_type_concrete_ok_406 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ref_type_concrete_ok.json", t)
}

@(test)
test_tc_carve_as_type_ok_407 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_as_type_ok.json", t)
}

@(test)
test_tc_carve_implicit_transitive_fail_408 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_implicit_transitive_fail.json", t)
}

@(test)
test_tc_unk_mul_u32_ok_409 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_unk_mul_u32_ok.json", t)
}

@(test)
test_tc_scope_mixed_fields_bad_410 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_scope_mixed_fields_bad.json", t)
}

@(test)
test_tc_ref_nested_mix_neg_ok_411 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ref_nested_mix_neg_ok.json", t)
}

@(test)
test_tc_execute_value_ok_412 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_execute_value_ok.json", t)
}

@(test)
test_tc_ref_type_concrete_bad_413 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ref_type_concrete_bad.json", t)
}

@(test)
test_tc_str_backtick_range_bad_414 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_backtick_range_bad.json", t)
}

@(test)
test_tc_carve_as_type_overflow_bad_415 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_as_type_overflow_bad.json", t)
}

@(test)
test_tc_flt_open_hi_ok_416 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_flt_open_hi_ok.json", t)
}

@(test)
test_tc_cmp_ge5_ok_417 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cmp_ge5_ok.json", t)
}

@(test)
test_tc_union_bool_int_intok_418 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_union_bool_int_intok.json", t)
}

@(test)
test_tc_scope_calc_mul_ok_419 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_scope_calc_mul_ok.json", t)
}

@(test)
test_tc_str_range_tri_ok_420 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_range_tri_ok.json", t)
}

@(test)
test_tc_ref_union_singletons_bad_421 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ref_union_singletons_bad.json", t)
}

@(test)
test_tc_seq_tag_bad_422 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_seq_tag_bad.json", t)
}

@(test)
test_tc_execute_none_ok_423 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_execute_none_ok.json", t)
}

@(test)
test_tc_str_neg_concat_bad_424 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_neg_concat_bad.json", t)
}

@(test)
test_tc_ref_and_range_ok_425 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ref_and_range_ok.json", t)
}

@(test)
test_tc_cast_overflow_no_cast_fail_426 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cast_overflow_no_cast_fail.json", t)
}

@(test)
test_tc_str_backtick_exact_ok_427 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_backtick_exact_ok.json", t)
}

@(test)
test_tc_cast_unknown_forced_ok_428 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cast_unknown_forced_ok.json", t)
}

@(test)
test_tc_scope_two_ok_429 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_scope_two_ok.json", t)
}

@(test)
test_tc_scope_calc_two_refs_ok_430 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_scope_calc_two_refs_ok.json", t)
}

@(test)
test_tc_range_ok_431 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_range_ok.json", t)
}

@(test)
test_tc_char_rep_union_bad_432 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_char_rep_union_bad.json", t)
}

@(test)
test_tc_carve_override_is_ref_ok_433 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_override_is_ref_ok.json", t)
}

@(test)
test_tc_carve_nested_ok_434 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_nested_ok.json", t)
}

@(test)
test_tc_comp_double_and_ok_435 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_comp_double_and_ok.json", t)
}

@(test)
test_tc_str_pos_both_ok_436 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_pos_both_ok.json", t)
}

@(test)
test_tc_seq_two_classes_fewletters_bad_437 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_seq_two_classes_fewletters_bad.json", t)
}

@(test)
test_tc_str_char_bad_438 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_char_bad.json", t)
}

@(test)
test_tc_carve_pos_skips_pull_ok_439 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_pos_skips_pull_ok.json", t)
}

@(test)
test_tc_int_and_cast_u8_ok_440 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_int_and_cast_u8_ok.json", t)
}

@(test)
test_tc_str_tri_range_noprefix_bad_441 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_tri_range_noprefix_bad.json", t)
}

@(test)
test_tc_str_tri_range_url_bad_442 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_tri_range_url_bad.json", t)
}

@(test)
test_tc_str_concat_concrete_ok_443 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_concat_concrete_ok.json", t)
}

@(test)
test_tc_int_sub_range_lo_ok_444 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_int_sub_range_lo_ok.json", t)
}

@(test)
test_tc_neg10_ok_445 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg10_ok.json", t)
}

@(test)
test_tc_str_neg_ord_seq_ok_446 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_neg_ord_seq_ok.json", t)
}

@(test)
test_tc_str_dquote_1char_pos_ok_447 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_dquote_1char_pos_ok.json", t)
}

@(test)
test_tc_self_singleton_ok_448 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_self_singleton_ok.json", t)
}

@(test)
test_tc_pat_prod_carve_ok_449 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_prod_carve_ok.json", t)
}

@(test)
test_tc_flt_range_ok_450 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_flt_range_ok.json", t)
}

@(test)
test_tc_flt_mul_concrete_ok_451 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_flt_mul_concrete_ok.json", t)
}

@(test)
test_tc_pull_unify_agree_ok_452 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pull_unify_agree_ok.json", t)
}

@(test)
test_tc_str_neg_word_seq_digits_ok_453 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_neg_word_seq_digits_ok.json", t)
}

@(test)
test_tc_scope_calc_range_field_ok_454 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_scope_calc_range_field_ok.json", t)
}

@(test)
test_tc_str_squote_multi_pos_bad_455 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_squote_multi_pos_bad.json", t)
}

@(test)
test_tc_scope_calc_two_refs_bad_456 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_scope_calc_two_refs_bad.json", t)
}

@(test)
test_tc_nested_prop_457 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_nested_prop.json", t)
}

@(test)
test_tc_str_range_prefix_ok_458 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_range_prefix_ok.json", t)
}

@(test)
test_tc_scope_two_extra_bad_459 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_scope_two_extra_bad.json", t)
}

@(test)
test_tc_str_union_multi_ok_460 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_union_multi_ok.json", t)
}

@(test)
test_tc_pat_prod_ref_ok_461 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_prod_ref_ok.json", t)
}

@(test)
test_tc_mixed_str_in_strf32_462 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_mixed_str_in_strf32.json", t)
}

@(test)
test_tc_comp_double_and_bad_lo_463 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_comp_double_and_bad_lo.json", t)
}

@(test)
test_tc_u8_overflow_464 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_u8_overflow.json", t)
}

@(test)
test_tc_str_backtick_eq_dquote_ok_465 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_backtick_eq_dquote_ok.json", t)
}

@(test)
test_tc_int_mul_concrete_ok_466 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_int_mul_concrete_ok.json", t)
}

@(test)
test_tc_insoluble_untyped_467 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_insoluble_untyped.json", t)
}

@(test)
test_tc_comp_inter_unions_ok_468 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_comp_inter_unions_ok.json", t)
}

@(test)
test_tc_scope_uncolored_ok_469 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_scope_uncolored_ok.json", t)
}

@(test)
test_tc_insoluble_and_470 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_insoluble_and.json", t)
}

@(test)
test_tc_pull_two_independent_ok_471 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pull_two_independent_ok.json", t)
}

@(test)
test_tc_cmp_ge5_bad_472 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cmp_ge5_bad.json", t)
}

@(test)
test_tc_union_tri_int_ok_473 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_union_tri_int_ok.json", t)
}

@(test)
test_tc_pat_bool_exh_474 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_bool_exh.json", t)
}

