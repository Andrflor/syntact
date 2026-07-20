// AUTO-GENERATED. DO NOT EDIT.
package typecheck_test

import "core:testing"

@(test)
test_tc_int_mixed_sign_u16_bad_0 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_int_mixed_sign_u16_bad.json", t)
}

@(test)
test_tc_carve_impl_dep_bad_1 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_impl_dep_bad.json", t)
}

@(test)
test_tc_self_ref_singleton_ok_2 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_self_ref_singleton_ok.json", t)
}

@(test)
test_tc_flt_mul_range_ok_3 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_flt_mul_range_ok.json", t)
}

@(test)
test_tc_str_neg_word_lit_ok_4 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_neg_word_lit_ok.json", t)
}

@(test)
test_tc_union_bool_int_ok_5 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_union_bool_int_ok.json", t)
}

@(test)
test_tc_execute_value_overflow_bad_6 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_execute_value_overflow_bad.json", t)
}

@(test)
test_tc_str_neg_ord_class_bad_7 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_neg_ord_class_bad.json", t)
}

@(test)
test_tc_ref_union_singletons_ok_8 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ref_union_singletons_ok.json", t)
}

@(test)
test_tc_union_bad_9 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_union_bad.json", t)
}

@(test)
test_tc_str_pos_both_bad_10 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_pos_both_bad.json", t)
}

@(test)
test_tc_soluble_unknown_value_ok_11 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_soluble_unknown_value_ok.json", t)
}

@(test)
test_tc_demorgan_deep_bad_12 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_demorgan_deep_bad.json", t)
}

@(test)
test_tc_neg_triple_ok_13 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg_triple_ok.json", t)
}

@(test)
test_tc_str_backtick_eq_dquote_ok_14 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_backtick_eq_dquote_ok.json", t)
}

@(test)
test_tc_pat_target_ref_ok_15 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_target_ref_ok.json", t)
}

@(test)
test_tc_seq_tag_bad_16 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_seq_tag_bad.json", t)
}

@(test)
test_tc_value_union_ok_17 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_value_union_ok.json", t)
}

@(test)
test_tc_insoluble_arith_operand_18 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_insoluble_arith_operand.json", t)
}

@(test)
test_tc_insoluble_untyped_19 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_insoluble_untyped.json", t)
}

@(test)
test_tc_neg_union_bad10_20 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg_union_bad10.json", t)
}

@(test)
test_tc_eqset_str_neg_id_ok_21 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_eqset_str_neg_id_ok.json", t)
}

@(test)
test_tc_map_mixed_string_bad_22 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_map_mixed_string_bad.json", t)
}

@(test)
test_tc_flt_neg_ok_23 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_flt_neg_ok.json", t)
}

@(test)
test_tc_str_neg_ord_range_one_ok_24 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_neg_ord_range_one_ok.json", t)
}

@(test)
test_tc_self_bool_singleton_ok_25 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_self_bool_singleton_ok.json", t)
}

@(test)
test_tc_comp_negrange_or_pt_ok5_26 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_comp_negrange_or_pt_ok5.json", t)
}

@(test)
test_tc_pat_prod_execute_ok_27 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_prod_execute_ok.json", t)
}

@(test)
test_tc_pull_three_agree_ok_28 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pull_three_agree_ok.json", t)
}

@(test)
test_tc_ref_nested_mix_ok_29 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ref_nested_mix_ok.json", t)
}

@(test)
test_tc_pat_prod_int_ok_30 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_prod_int_ok.json", t)
}

@(test)
test_tc_str_pos_both_ok_31 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_pos_both_ok.json", t)
}

@(test)
test_tc_comp_inter_unions_bad_32 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_comp_inter_unions_bad.json", t)
}

@(test)
test_tc_bool_inter_empty_bad_33 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_bool_inter_empty_bad.json", t)
}

@(test)
test_tc_ident_bad_34 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ident_bad.json", t)
}

@(test)
test_tc_eqset_neg_sub_bad_35 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_eqset_neg_sub_bad.json", t)
}

@(test)
test_tc_union_tri_str_ok_36 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_union_tri_str_ok.json", t)
}

@(test)
test_tc_pat_refine_recursive_u64_ok_37 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_refine_recursive_u64_ok.json", t)
}

@(test)
test_tc_int_sub_range_lo_ok_38 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_int_sub_range_lo_ok.json", t)
}

@(test)
test_tc_carve_implicit_compose_compensated_ok_39 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_implicit_compose_compensated_ok.json", t)
}

@(test)
test_tc_nontail_recursion_ok_40 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_nontail_recursion_ok.json", t)
}

@(test)
test_tc_cast_unknown_sum_recast_ok_41 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cast_unknown_sum_recast_ok.json", t)
}

@(test)
test_tc_union_rep_ok_42 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_union_rep_ok.json", t)
}

@(test)
test_tc_pos_prefix_ok_43 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pos_prefix_ok.json", t)
}

@(test)
test_tc_prod_int_union_gap_bad_44 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_prod_int_union_gap_bad.json", t)
}

@(test)
test_tc_str_range_pos_noprefix_bad_45 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_range_pos_noprefix_bad.json", t)
}

@(test)
test_tc_str_neg_plus_lit_ok_46 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_neg_plus_lit_ok.json", t)
}

@(test)
test_tc_str_union_multi_bad_47 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_union_multi_bad.json", t)
}

@(test)
test_tc_prop_family_bad_48 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_prop_family_bad.json", t)
}

@(test)
test_tc_pat_grammar_exh_structural_bad_49 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_grammar_exh_structural_bad.json", t)
}

@(test)
test_tc_str_char_bad_50 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_char_bad.json", t)
}

@(test)
test_tc_pat_prod_ref_ok_51 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_prod_ref_ok.json", t)
}

@(test)
test_tc_cmp_gt5_ok_52 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cmp_gt5_ok.json", t)
}

@(test)
test_tc_carve_impl_dep_compensated_ok_53 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_impl_dep_compensated_ok.json", t)
}

@(test)
test_tc_eqset_dneg_collapse_bad_54 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_eqset_dneg_collapse_bad.json", t)
}

@(test)
test_tc_pat_nested_ok_55 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_nested_ok.json", t)
}

@(test)
test_tc_pos_str_bad_56 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pos_str_bad.json", t)
}

@(test)
test_tc_eqset_or_id_ok_57 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_eqset_or_id_ok.json", t)
}

@(test)
test_tc_pat_prod_string_ok_58 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_prod_string_ok.json", t)
}

@(test)
test_tc_flt_open_lo_ok_59 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_flt_open_lo_ok.json", t)
}

@(test)
test_tc_pull_named_vs_struct_agree_ok_60 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pull_named_vs_struct_agree_ok.json", t)
}

@(test)
test_tc_pat_target_arith_nonexh_61 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_target_arith_nonexh.json", t)
}

@(test)
test_tc_pat_bool_typecheck_exh_62 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_bool_typecheck_exh.json", t)
}

@(test)
test_tc_eqset_flt_neg_diff_bad_63 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_eqset_flt_neg_diff_bad.json", t)
}

@(test)
test_tc_cast_i32_to_f32_ok_64 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cast_i32_to_f32_ok.json", t)
}

@(test)
test_tc_unk_mul_u32_ok_65 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_unk_mul_u32_ok.json", t)
}

@(test)
test_tc_neg_and_negs_bad_66 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg_and_negs_bad.json", t)
}

@(test)
test_tc_carve_pos_skips_pull_overflow_bad_67 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_pos_skips_pull_overflow_bad.json", t)
}

@(test)
test_tc_str_union_multi_ok_68 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_union_multi_ok.json", t)
}

@(test)
test_tc_str_concat_lit_class_bad_69 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_concat_lit_class_bad.json", t)
}

@(test)
test_tc_scope_two_ok_70 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_scope_two_ok.json", t)
}

@(test)
test_tc_neg_range_bad_71 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg_range_bad.json", t)
}

@(test)
test_tc_insoluble_range_72 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_insoluble_range.json", t)
}

@(test)
test_tc_pat_prod_int_overflow_bad_73 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_prod_int_overflow_bad.json", t)
}

@(test)
test_tc_comp_inter_unions_bad2_74 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_comp_inter_unions_bad2.json", t)
}

@(test)
test_tc_pat_str_target_ok_75 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_str_target_ok.json", t)
}

@(test)
test_tc_cmp_ge5_bad_76 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cmp_ge5_bad.json", t)
}

@(test)
test_tc_pat_prod_carve_ok_77 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_prod_carve_ok.json", t)
}

@(test)
test_tc_unk_sub_i16_ok_78 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_unk_sub_i16_ok.json", t)
}

@(test)
test_tc_carve_subst_inner_constraint_ok_79 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_subst_inner_constraint_ok.json", t)
}

@(test)
test_tc_union_ok_80 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_union_ok.json", t)
}

@(test)
test_tc_union_char_alts_up_ok_81 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_union_char_alts_up_ok.json", t)
}

@(test)
test_tc_str_backtick_range_ok_82 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_backtick_range_ok.json", t)
}

@(test)
test_tc_cmp_lt0_bad_83 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cmp_lt0_bad.json", t)
}

@(test)
test_tc_str_rep_range_ok_84 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_rep_range_ok.json", t)
}

@(test)
test_tc_str_range_pos_nosuffix_bad_85 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_range_pos_nosuffix_bad.json", t)
}

@(test)
test_tc_rep_exact_ok_86 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_rep_exact_ok.json", t)
}

@(test)
test_tc_insoluble_direct_87 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_insoluble_direct.json", t)
}

@(test)
test_tc_self_u8_bad_88 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_self_u8_bad.json", t)
}

@(test)
test_tc_cast_neg_into_u8_ok_89 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cast_neg_into_u8_ok.json", t)
}

@(test)
test_tc_neg_and_negs_ok_90 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg_and_negs_ok.json", t)
}

@(test)
test_tc_cast_cross_domain_float_to_i32_ok_91 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cast_cross_domain_float_to_i32_ok.json", t)
}

@(test)
test_tc_ref_range_and_bad_92 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ref_range_and_bad.json", t)
}

@(test)
test_tc_eqset_bool_id_ok_93 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_eqset_bool_id_ok.json", t)
}

@(test)
test_tc_str_pos_prefix_bad_94 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_pos_prefix_bad.json", t)
}

@(test)
test_tc_str_neg_word_seq_ok_95 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_neg_word_seq_ok.json", t)
}

@(test)
test_tc_eqset_negunion_reorder_ok_96 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_eqset_negunion_reorder_ok.json", t)
}

@(test)
test_tc_flt_mul_range_bad_97 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_flt_mul_range_bad.json", t)
}

@(test)
test_tc_prod_int_union_ok_98 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_prod_int_union_ok.json", t)
}

@(test)
test_tc_prop_compute_ok_99 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_prop_compute_ok.json", t)
}

@(test)
test_tc_cast_target_bool_ok_100 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cast_target_bool_ok.json", t)
}

@(test)
test_tc_cast_overflow_into_u8_ok_101 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cast_overflow_into_u8_ok.json", t)
}

@(test)
test_tc_bool_union_false_ok_102 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_bool_union_false_ok.json", t)
}

@(test)
test_tc_int_add_u8u8_u8_default0_ok_103 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_int_add_u8u8_u8_default0_ok.json", t)
}

@(test)
test_tc_str_range_tri_contiguous_ok_104 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_range_tri_contiguous_ok.json", t)
}

@(test)
test_tc_execute_none_into_u8_bad_105 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_execute_none_into_u8_bad.json", t)
}

@(test)
test_tc_carve_implicit_transitive_fail_106 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_implicit_transitive_fail.json", t)
}

@(test)
test_tc_color_u8_overflow_bad_107 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_color_u8_overflow_bad.json", t)
}

@(test)
test_tc_cast_cross_domain_string_to_u8_ok_108 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cast_cross_domain_string_to_u8_ok.json", t)
}

@(test)
test_tc_str_concat_pattern_ok_109 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_concat_pattern_ok.json", t)
}

@(test)
test_tc_neg_or_negs_none_bad_110 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg_or_negs_none_bad.json", t)
}

@(test)
test_tc_seq_two_classes_fewletters_bad_111 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_seq_two_classes_fewletters_bad.json", t)
}

@(test)
test_tc_cast_unknown_sum_overflow_fail_112 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cast_unknown_sum_overflow_fail.json", t)
}

@(test)
test_tc_infinite_default_113 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_infinite_default.json", t)
}

@(test)
test_tc_execute_carve_as_type_ok_114 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_execute_carve_as_type_ok.json", t)
}

@(test)
test_tc_pat_char_value_ok_115 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_char_value_ok.json", t)
}

@(test)
test_tc_str_ord_above_bad_116 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_ord_above_bad.json", t)
}

@(test)
test_tc_cast_u8_to_f32_ok_117 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cast_u8_to_f32_ok.json", t)
}

@(test)
test_tc_unk_sub_u8_bad_118 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_unk_sub_u8_bad.json", t)
}

@(test)
test_tc_neg_int_bad_119 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg_int_bad.json", t)
}

@(test)
test_tc_pat_grammar_exh_bare_tail_120 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_grammar_exh_bare_tail.json", t)
}

@(test)
test_tc_comp_inter_unions_ok_121 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_comp_inter_unions_ok.json", t)
}

@(test)
test_tc_refchain_triple_ok_122 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_refchain_triple_ok.json", t)
}

@(test)
test_tc_ref_arith_ok_123 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ref_arith_ok.json", t)
}

@(test)
test_tc_neg_union_ok_124 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg_union_ok.json", t)
}

@(test)
test_tc_eqset_neg_val_bad_125 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_eqset_neg_val_bad.json", t)
}

@(test)
test_tc_neg_or_self_ok_126 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg_or_self_ok.json", t)
}

@(test)
test_tc_map_inner_proof_ok_127 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_map_inner_proof_ok.json", t)
}

@(test)
test_tc_cast_overflow_no_cast_fail_128 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cast_overflow_no_cast_fail.json", t)
}

@(test)
test_tc_carve_shorthand_field_overflow_bad_129 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_shorthand_field_overflow_bad.json", t)
}

@(test)
test_tc_pat_mixed_modes_gap_130 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_mixed_modes_gap.json", t)
}

@(test)
test_tc_bool_false_bad_131 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_bool_false_bad.json", t)
}

@(test)
test_tc_ref_type_concrete_ok_132 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ref_type_concrete_ok.json", t)
}

@(test)
test_tc_unk_mul_u16_ok_133 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_unk_mul_u16_ok.json", t)
}

@(test)
test_tc_carve_pos_out_of_range_bad_134 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_pos_out_of_range_bad.json", t)
}

@(test)
test_tc_prop_compute_bad_135 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_prop_compute_bad.json", t)
}

@(test)
test_tc_flt_union_bad_136 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_flt_union_bad.json", t)
}

@(test)
test_tc_carve_dep_string_concat_ok_137 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_dep_string_concat_ok.json", t)
}

@(test)
test_tc_range_ok_138 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_range_ok.json", t)
}

@(test)
test_tc_self_str_singleton_ok_139 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_self_str_singleton_ok.json", t)
}

@(test)
test_tc_scope_two_missing_bad_140 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_scope_two_missing_bad.json", t)
}

@(test)
test_tc_execute_none_ok_141 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_execute_none_ok.json", t)
}

@(test)
test_tc_ref_and_range_bad_142 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ref_and_range_bad.json", t)
}

@(test)
test_tc_comp_and_or_bad_gap_143 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_comp_and_or_bad_gap.json", t)
}

@(test)
test_tc_flt_add_range_ok_144 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_flt_add_range_ok.json", t)
}

@(test)
test_tc_neg_union_bad5_145 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg_union_bad5.json", t)
}

@(test)
test_tc_union_u8_f32_int_ok_146 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_union_u8_f32_int_ok.json", t)
}

@(test)
test_tc_carve_pos_skips_pull_second_ok_147 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_pos_skips_pull_second_ok.json", t)
}

@(test)
test_tc_union_char_int_str_ok_148 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_union_char_int_str_ok.json", t)
}

@(test)
test_tc_ref_nested_mix_neg_ok_149 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ref_nested_mix_neg_ok.json", t)
}

@(test)
test_tc_ref_nested_mix_bad_150 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ref_nested_mix_bad.json", t)
}

@(test)
test_tc_execute_constraint_ok_151 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_execute_constraint_ok.json", t)
}

@(test)
test_tc_cast_target_disjoint_union_fail_152 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cast_target_disjoint_union_fail.json", t)
}

@(test)
test_tc_scope_calc_two_refs_ok_153 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_scope_calc_two_refs_ok.json", t)
}

@(test)
test_tc_u8_ok_154 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_u8_ok.json", t)
}

@(test)
test_tc_execute_constraint_fail_155 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_execute_constraint_fail.json", t)
}

@(test)
test_tc_scope_calc_mul_bad_156 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_scope_calc_mul_bad.json", t)
}

@(test)
test_tc_neg_str_exact_ok_157 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg_str_exact_ok.json", t)
}

@(test)
test_tc_cast_target_range_no_layout_fail_158 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cast_target_range_no_layout_fail.json", t)
}

@(test)
test_tc_scope_mixed_fields_bad_159 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_scope_mixed_fields_bad.json", t)
}

@(test)
test_tc_neg_triple_bad_160 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg_triple_bad.json", t)
}

@(test)
test_tc_ref_neg_singleton_ok_161 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ref_neg_singleton_ok.json", t)
}

@(test)
test_tc_demorgan_bad_162 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_demorgan_bad.json", t)
}

@(test)
test_tc_execute_empty_none_ok_163 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_execute_empty_none_ok.json", t)
}

@(test)
test_tc_color_carve_pos_ok_164 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_color_carve_pos_ok.json", t)
}

@(test)
test_tc_union_u8_f32_str_bad_165 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_union_u8_f32_str_bad.json", t)
}

@(test)
test_tc_refchain_constraint_ok_166 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_refchain_constraint_ok.json", t)
}

@(test)
test_tc_seq_two_classes_short_bad_167 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_seq_two_classes_short_bad.json", t)
}

@(test)
test_tc_symbolic_compose_ok_168 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_symbolic_compose_ok.json", t)
}

@(test)
test_tc_execute_of_carve_overflow_bad_169 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_execute_of_carve_overflow_bad.json", t)
}

@(test)
test_tc_cast_sum_overflow_forced_ok_170 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cast_sum_overflow_forced_ok.json", t)
}

@(test)
test_tc_str_backtick_union_bad_171 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_backtick_union_bad.json", t)
}

@(test)
test_tc_eqset_xd_u8_str_bad_172 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_eqset_xd_u8_str_bad.json", t)
}

@(test)
test_tc_neg10_ok_173 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg10_ok.json", t)
}

@(test)
test_tc_seq_backtrack_ok_174 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_seq_backtrack_ok.json", t)
}

@(test)
test_tc_carve_pos_only_pull_out_of_range_bad_175 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_pos_only_pull_out_of_range_bad.json", t)
}

@(test)
test_tc_pat_domain_exh_u8_176 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_domain_exh_u8.json", t)
}

@(test)
test_tc_color_u8_negative_bad_177 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_color_u8_negative_bad.json", t)
}

@(test)
test_tc_str_pos_prefix_ok_178 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_pos_prefix_ok.json", t)
}

@(test)
test_tc_neg_pos_ok_179 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg_pos_ok.json", t)
}

@(test)
test_tc_carve_as_type_overflow_bad_180 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_as_type_overflow_bad.json", t)
}

@(test)
test_tc_pull_two_independent_ok_181 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pull_two_independent_ok.json", t)
}

@(test)
test_tc_scope_uncolored_ok_182 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_scope_uncolored_ok.json", t)
}

@(test)
test_tc_neg_double_ok_183 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg_double_ok.json", t)
}

@(test)
test_tc_inter_str_int_none_bad_184 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_inter_str_int_none_bad.json", t)
}

@(test)
test_tc_insoluble_via_binding_185 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_insoluble_via_binding.json", t)
}

@(test)
test_tc_map_inner_proof_bad_186 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_map_inner_proof_bad.json", t)
}

@(test)
test_tc_soluble_singleton_ref_ok_187 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_soluble_singleton_ref_ok.json", t)
}

@(test)
test_tc_rep_range_ok_188 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_rep_range_ok.json", t)
}

@(test)
test_tc_str_neg_word_seq_bad_189 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_neg_word_seq_bad.json", t)
}

@(test)
test_tc_bool_union_true_ok_190 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_bool_union_true_ok.json", t)
}

@(test)
test_tc_bool_inter_same_ok_191 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_bool_inter_same_ok.json", t)
}

@(test)
test_tc_neg_ord_range_bad_192 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg_ord_range_bad.json", t)
}

@(test)
test_tc_color_carve_chain_bad_193 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_color_carve_chain_bad.json", t)
}

@(test)
test_tc_carve_implicit_ref_fail_194 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_implicit_ref_fail.json", t)
}

@(test)
test_tc_eq_neg_strict_bad_195 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_eq_neg_strict_bad.json", t)
}

@(test)
test_tc_pat_float_typecheck_exh_196 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_float_typecheck_exh.json", t)
}

@(test)
test_tc_eqset_dneg_collapse_ok_197 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_eqset_dneg_collapse_ok.json", t)
}

@(test)
test_tc_ref_neg_singleton_bad2_198 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ref_neg_singleton_bad2.json", t)
}

@(test)
test_tc_scope_shape_calc_ok_199 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_scope_shape_calc_ok.json", t)
}

@(test)
test_tc_union_bool_int_intok_200 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_union_bool_int_intok.json", t)
}

@(test)
test_tc_cast_into_i8_ok_201 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cast_into_i8_ok.json", t)
}

@(test)
test_tc_str_tri_range_noprefix_bad_202 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_tri_range_noprefix_bad.json", t)
}

@(test)
test_tc_pat_two_values_nonexh_203 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_two_values_nonexh.json", t)
}

@(test)
test_tc_color_nested_carve_ok_204 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_color_nested_carve_ok.json", t)
}

@(test)
test_tc_str_tri_range_nomid_bad_205 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_tri_range_nomid_bad.json", t)
}

@(test)
test_tc_cmp_le100_bad_206 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cmp_le100_bad.json", t)
}

@(test)
test_tc_eqset_single_ok_207 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_eqset_single_ok.json", t)
}

@(test)
test_tc_cast_unknown_forced_ok_208 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cast_unknown_forced_ok.json", t)
}

@(test)
test_tc_str_range_tri_ok_209 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_range_tri_ok.json", t)
}

@(test)
test_tc_str_neg_ord_seq_short_ok_210 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_neg_ord_seq_short_ok.json", t)
}

@(test)
test_tc_int_and_cast_i8_ok_211 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_int_and_cast_i8_ok.json", t)
}

@(test)
test_tc_ref_or_family_bad_212 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ref_or_family_bad.json", t)
}

@(test)
test_tc_ref_union_singletons_bad_213 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ref_union_singletons_bad.json", t)
}

@(test)
test_tc_unk_mul_u8_bad_214 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_unk_mul_u8_bad.json", t)
}

@(test)
test_tc_carve_subst_inner_carve_missing_bad_215 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_subst_inner_carve_missing_bad.json", t)
}

@(test)
test_tc_execute_of_carve_ok_216 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_execute_of_carve_ok.json", t)
}

@(test)
test_tc_color_u8_carve_ok_217 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_color_u8_carve_ok.json", t)
}

@(test)
test_tc_str_squote_multi_pos_ok_218 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_squote_multi_pos_ok.json", t)
}

@(test)
test_tc_neg_or_self_other_ok_219 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg_or_self_other_ok.json", t)
}

@(test)
test_tc_pos_prefix_bad_220 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pos_prefix_bad.json", t)
}

@(test)
test_tc_scope_field_union_ok_221 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_scope_field_union_ok.json", t)
}

@(test)
test_tc_carve_override_bad_222 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_override_bad.json", t)
}

@(test)
test_tc_seq_tag_ok_223 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_seq_tag_ok.json", t)
}

@(test)
test_tc_ref_type_concrete_bad_224 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ref_type_concrete_bad.json", t)
}

@(test)
test_tc_eqset_u8_sub_bad_225 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_eqset_u8_sub_bad.json", t)
}

@(test)
test_tc_pat_combined_union_bad_226 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_combined_union_bad.json", t)
}

@(test)
test_tc_grammar_via_mention_ok_227 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_grammar_via_mention_ok.json", t)
}

@(test)
test_tc_execute_ref_producer_bad_228 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_execute_ref_producer_bad.json", t)
}

@(test)
test_tc_str_neg_word_seq_digits_ok_229 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_neg_word_seq_digits_ok.json", t)
}

@(test)
test_tc_bool_neg_false_ok_230 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_bool_neg_false_ok.json", t)
}

@(test)
test_tc_char_union_neg_ok_231 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_char_union_neg_ok.json", t)
}

@(test)
test_tc_str_neg_ord_range_multi_bad_232 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_neg_ord_range_multi_bad.json", t)
}

@(test)
test_tc_pull_three_last_diverges_bad_233 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pull_three_last_diverges_bad.json", t)
}

@(test)
test_tc_ref_arith_nested_bad_234 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ref_arith_nested_bad.json", t)
}

@(test)
test_tc_prop_as_value_ok_235 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_prop_as_value_ok.json", t)
}

@(test)
test_tc_str_neg_ord_seq_nonull_bad_236 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_neg_ord_seq_nonull_bad.json", t)
}

@(test)
test_tc_str_backtick_range_bad_237 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_backtick_range_bad.json", t)
}

@(test)
test_tc_color_multi_field_bad_238 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_color_multi_field_bad.json", t)
}

@(test)
test_tc_pat_exh_value_singleton_239 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_exh_value_singleton.json", t)
}

@(test)
test_tc_int_mul_range_u16_ok_240 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_int_mul_range_u16_ok.json", t)
}

@(test)
test_tc_eqset_xd_int_str_bad_241 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_eqset_xd_int_str_bad.json", t)
}

@(test)
test_tc_demorgan_ok_242 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_demorgan_ok.json", t)
}

@(test)
test_tc_char_builtin_accepts_char_243 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_char_builtin_accepts_char.json", t)
}

@(test)
test_tc_insoluble_neg_244 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_insoluble_neg.json", t)
}

@(test)
test_tc_union_char_alts_bad_245 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_union_char_alts_bad.json", t)
}

@(test)
test_tc_str_rep_exact_bad_246 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_rep_exact_bad.json", t)
}

@(test)
test_tc_execute_carve_as_type_bad_247 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_execute_carve_as_type_bad.json", t)
}

@(test)
test_tc_execute_chain_ref_ok_248 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_execute_chain_ref_ok.json", t)
}

@(test)
test_tc_ref_arith_overflow_bad_249 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ref_arith_overflow_bad.json", t)
}

@(test)
test_tc_color_nested_carve_bad_250 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_color_nested_carve_bad.json", t)
}

@(test)
test_tc_str_concat_concrete_ok_251 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_concat_concrete_ok.json", t)
}

@(test)
test_tc_carve_subst_inner_constraint_bad_252 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_subst_inner_constraint_bad.json", t)
}

@(test)
test_tc_carve_implicit_compose_fail_253 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_implicit_compose_fail.json", t)
}

@(test)
test_tc_scope_union_ok1_254 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_scope_union_ok1.json", t)
}

@(test)
test_tc_pat_bool_nonexh_255 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_bool_nonexh.json", t)
}

@(test)
test_tc_refchain_triple_bad_256 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_refchain_triple_bad.json", t)
}

@(test)
test_tc_int_sub_u8u8_i16_ok_257 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_int_sub_u8u8_i16_ok.json", t)
}

@(test)
test_tc_scope_prop_258 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_scope_prop.json", t)
}

@(test)
test_tc_pat_refine_even_odd_ok_259 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_refine_even_odd_ok.json", t)
}

@(test)
test_tc_bool_true_bad_260 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_bool_true_bad.json", t)
}

@(test)
test_tc_eqset_struct_not_denot_bad_261 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_eqset_struct_not_denot_bad.json", t)
}

@(test)
test_tc_cmp_gt5_bad_262 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cmp_gt5_bad.json", t)
}

@(test)
test_tc_eq_neg_union_bad_263 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_eq_neg_union_bad.json", t)
}

@(test)
test_tc_neg_ord_ok_264 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg_ord_ok.json", t)
}

@(test)
test_tc_ord_char_ok_265 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ord_char_ok.json", t)
}

@(test)
test_tc_rep_char_bad_266 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_rep_char_bad.json", t)
}

@(test)
test_tc_scope_two_extra_bad_267 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_scope_two_extra_bad.json", t)
}

@(test)
test_tc_execute_set_not_element_bad_268 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_execute_set_not_element_bad.json", t)
}

@(test)
test_tc_execute_value_fail_269 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_execute_value_fail.json", t)
}

@(test)
test_tc_str_neg_ord_class_ok_270 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_neg_ord_class_ok.json", t)
}

@(test)
test_tc_carve_pos_two_pushes_ok_271 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_pos_two_pushes_ok.json", t)
}

@(test)
test_tc_ref_prop_arith_bad_272 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ref_prop_arith_bad.json", t)
}

@(test)
test_tc_cast_bool_to_u8_ok_273 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cast_bool_to_u8_ok.json", t)
}

@(test)
test_tc_ref_arith_nested_ok_274 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ref_arith_nested_ok.json", t)
}

@(test)
test_tc_neg_and_neg_bad_275 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg_and_neg_bad.json", t)
}

@(test)
test_tc_self_range_bad_276 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_self_range_bad.json", t)
}

@(test)
test_tc_comp_double_and_bad_hi_277 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_comp_double_and_bad_hi.json", t)
}

@(test)
test_tc_pat_prod_string_on_int_bad_278 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_prod_string_on_int_bad.json", t)
}

@(test)
test_tc_ref_prop_arith_ok_279 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ref_prop_arith_ok.json", t)
}

@(test)
test_tc_cmp_le100_ok_280 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cmp_le100_ok.json", t)
}

@(test)
test_tc_self_string_set_bad_281 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_self_string_set_bad.json", t)
}

@(test)
test_tc_scope_field_union_bad_282 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_scope_field_union_bad.json", t)
}

@(test)
test_tc_pat_exh_value_open_range_283 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_exh_value_open_range.json", t)
}

@(test)
test_tc_pat_target_carve_ok_284 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_target_carve_ok.json", t)
}

@(test)
test_tc_pat_prod_ref_overflow_bad_285 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_prod_ref_overflow_bad.json", t)
}

@(test)
test_tc_carve_value_ok_286 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_value_ok.json", t)
}

@(test)
test_tc_neg_and_neg_ok_287 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg_and_neg_ok.json", t)
}

@(test)
test_tc_str_tri_range_url_ok_288 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_tri_range_url_ok.json", t)
}

@(test)
test_tc_str_rep_exact_ok_289 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_rep_exact_ok.json", t)
}

@(test)
test_tc_str_range_prefix_ok_290 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_range_prefix_ok.json", t)
}

@(test)
test_tc_str_union_pat_ok_291 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_union_pat_ok.json", t)
}

@(test)
test_tc_pat_nested_overflow_bad_292 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_nested_overflow_bad.json", t)
}

@(test)
test_tc_eqset_u8_super_bad_293 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_eqset_u8_super_bad.json", t)
}

@(test)
test_tc_insoluble_nested_compose_294 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_insoluble_nested_compose.json", t)
}

@(test)
test_tc_str_backtick_exact_ok_295 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_backtick_exact_ok.json", t)
}

@(test)
test_tc_str_range_tri_noprefix_bad_296 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_range_tri_noprefix_bad.json", t)
}

@(test)
test_tc_union_char_alts_ok_297 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_union_char_alts_ok.json", t)
}

@(test)
test_tc_color_nested_deep_ok_298 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_color_nested_deep_ok.json", t)
}

@(test)
test_tc_union_bool_int_float_bad_299 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_union_bool_int_float_bad.json", t)
}

@(test)
test_tc_color_multi_field_ok_300 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_color_multi_field_ok.json", t)
}

@(test)
test_tc_str_char_ok_301 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_char_ok.json", t)
}

@(test)
test_tc_scope_calc_two_refs_bad_302 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_scope_calc_two_refs_bad.json", t)
}

@(test)
test_tc_flt_sub_concrete_ok_303 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_flt_sub_concrete_ok.json", t)
}

@(test)
test_tc_insoluble_ref_chain_304 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_insoluble_ref_chain.json", t)
}

@(test)
test_tc_str_union_pat_bad_305 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_union_pat_bad.json", t)
}

@(test)
test_tc_insoluble_and_306 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_insoluble_and.json", t)
}

@(test)
test_tc_neg_self_ok_307 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg_self_ok.json", t)
}

@(test)
test_tc_str_neg_concat_ok_308 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_neg_concat_ok.json", t)
}

@(test)
test_tc_carve_shorthand_two_fields_ok_309 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_shorthand_two_fields_ok.json", t)
}

@(test)
test_tc_carve_value_override_bad_310 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_value_override_bad.json", t)
}

@(test)
test_tc_ref_neg_singleton_bad_311 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ref_neg_singleton_bad.json", t)
}

@(test)
test_tc_cross_range_312 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cross_range.json", t)
}

@(test)
test_tc_pat_prod_float_ok_313 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_prod_float_ok.json", t)
}

@(test)
test_tc_cross_str_int_314 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cross_str_int.json", t)
}

@(test)
test_tc_cast_target_neg_union_fail_315 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cast_target_neg_union_fail.json", t)
}

@(test)
test_tc_ref_singleton_other_bad_316 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ref_singleton_other_bad.json", t)
}

@(test)
test_tc_execute_ref_producer_ok_317 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_execute_ref_producer_ok.json", t)
}

@(test)
test_tc_pull_named_vs_struct_conflict_bad_318 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pull_named_vs_struct_conflict_bad.json", t)
}

@(test)
test_tc_str_ord_mid_ok_319 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_ord_mid_ok.json", t)
}

@(test)
test_tc_comp_negrange_or_pt_bad_320 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_comp_negrange_or_pt_bad.json", t)
}

@(test)
test_tc_carve_implicit_override_both_ok_321 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_implicit_override_both_ok.json", t)
}

@(test)
test_tc_carve_property_ok_322 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_property_ok.json", t)
}

@(test)
test_tc_pat_default_first_323 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_default_first.json", t)
}

@(test)
test_tc_str_dquote_1char_pos_az_ok_324 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_dquote_1char_pos_az_ok.json", t)
}

@(test)
test_tc_carve_then_execute_ok_325 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_then_execute_ok.json", t)
}

@(test)
test_tc_carve_subst_field_gone_326 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_subst_field_gone.json", t)
}

@(test)
test_tc_insoluble_colored_binding_327 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_insoluble_colored_binding.json", t)
}

@(test)
test_tc_pat_prod_set_bad_328 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_prod_set_bad.json", t)
}

@(test)
test_tc_carve_self_property_ref_glued_ok_329 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_self_property_ref_glued_ok.json", t)
}

@(test)
test_tc_pat_refine_no_exclusion_bad_330 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_refine_no_exclusion_bad.json", t)
}

@(test)
test_tc_refchain_constraint_bad_331 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_refchain_constraint_bad.json", t)
}

@(test)
test_tc_carve_subst_rank_ok_332 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_subst_rank_ok.json", t)
}

@(test)
test_tc_str_concat_lit_class_ok_333 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_concat_lit_class_ok.json", t)
}

@(test)
test_tc_neg_char_ok_334 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg_char_ok.json", t)
}

@(test)
test_tc_scope_nested_bad_335 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_scope_nested_bad.json", t)
}

@(test)
test_tc_pat_nonexh_gap_336 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_nonexh_gap.json", t)
}

@(test)
test_tc_int_mul_range_u8_default0_ok_337 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_int_mul_range_u8_default0_ok.json", t)
}

@(test)
test_tc_demorgan_deep_ok_338 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_demorgan_deep_ok.json", t)
}

@(test)
test_tc_int_mixed_sign_i16_ok_339 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_int_mixed_sign_i16_ok.json", t)
}

@(test)
test_tc_str_tri_range_middle_ok_340 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_tri_range_middle_ok.json", t)
}

@(test)
test_tc_u8_overflow_341 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_u8_overflow.json", t)
}

@(test)
test_tc_union_u8_f32_overflow_bad_342 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_union_u8_f32_overflow_bad.json", t)
}

@(test)
test_tc_pat_nonexh_singleton_wrong_343 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_nonexh_singleton_wrong.json", t)
}

@(test)
test_tc_pat_nonexh_value_open_344 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_nonexh_value_open.json", t)
}

@(test)
test_tc_scope_union_ok2_345 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_scope_union_ok2.json", t)
}

@(test)
test_tc_prod_u8_346 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_prod_u8.json", t)
}

@(test)
test_tc_ref_and_range_ok_347 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ref_and_range_ok.json", t)
}

@(test)
test_tc_self_char_singleton_ok_348 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_self_char_singleton_ok.json", t)
}

@(test)
test_tc_neg_range_ok_349 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg_range_ok.json", t)
}

@(test)
test_tc_carve_pos_skips_pull_ok_350 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_pos_skips_pull_ok.json", t)
}

@(test)
test_tc_pull_unify_ok_351 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pull_unify_ok.json", t)
}

@(test)
test_tc_flt_inter_ok_352 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_flt_inter_ok.json", t)
}

@(test)
test_tc_str_neg_word_lit_bad_353 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_neg_word_lit_bad.json", t)
}

@(test)
test_tc_carve_shorthand_vs_positional_foreign_ok_354 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_shorthand_vs_positional_foreign_ok.json", t)
}

@(test)
test_tc_pat_float_value_nonexh_355 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_float_value_nonexh.json", t)
}

@(test)
test_tc_int_and_gt_ok_356 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_int_and_gt_ok.json", t)
}

@(test)
test_tc_pull_named_only_ok_357 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pull_named_only_ok.json", t)
}

@(test)
test_tc_carve_override_is_ref_ok_358 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_override_is_ref_ok.json", t)
}

@(test)
test_tc_ident_no_trail_bad_359 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ident_no_trail_bad.json", t)
}

@(test)
test_tc_flt_add_range_bad_360 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_flt_add_range_bad.json", t)
}

@(test)
test_tc_flt_range_bad_361 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_flt_range_bad.json", t)
}

@(test)
test_tc_scope_shape_ok_362 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_scope_shape_ok.json", t)
}

@(test)
test_tc_carve_property_compute_bad_363 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_property_compute_bad.json", t)
}

@(test)
test_tc_neg_subset_ok_364 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg_subset_ok.json", t)
}

@(test)
test_tc_str_union_class_literal_class_ok_365 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_union_class_literal_class_ok.json", t)
}

@(test)
test_tc_prod_int_union_subset_ok_366 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_prod_int_union_subset_ok.json", t)
}

@(test)
test_tc_str_union_class_literal_bad_367 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_union_class_literal_bad.json", t)
}

@(test)
test_tc_carve_dep_string_repeat_ok_368 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_dep_string_repeat_ok.json", t)
}

@(test)
test_tc_pat_prod_arith_overflow_bad_369 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_prod_arith_overflow_bad.json", t)
}

@(test)
test_tc_comp_double_and_bad_lo_370 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_comp_double_and_bad_lo.json", t)
}

@(test)
test_tc_str_concat_lit_class_prefix_bad_371 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_concat_lit_class_prefix_bad.json", t)
}

@(test)
test_tc_pull_conflict_bad_372 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pull_conflict_bad.json", t)
}

@(test)
test_tc_eqset_flt_neg_id_ok_373 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_eqset_flt_neg_id_ok.json", t)
}

@(test)
test_tc_pat_prod_arith_ok_374 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_prod_arith_ok.json", t)
}

@(test)
test_tc_scope_calc_range_field_bad_375 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_scope_calc_range_field_bad.json", t)
}

@(test)
test_tc_int_mul_concrete_ok_376 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_int_mul_concrete_ok.json", t)
}

@(test)
test_tc_pat_combined_union_ok_377 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_combined_union_ok.json", t)
}

@(test)
test_tc_str_range_pos_mid_ok_378 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_range_pos_mid_ok.json", t)
}

@(test)
test_tc_int_and_cast_u8_ok_379 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_int_and_cast_u8_ok.json", t)
}

@(test)
test_tc_char_rep_union_bad_380 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_char_rep_union_bad.json", t)
}

@(test)
test_tc_color_carve_chain_ok_381 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_color_carve_chain_ok.json", t)
}

@(test)
test_tc_carve_override_ref_overflow_bad_382 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_override_ref_overflow_bad.json", t)
}

@(test)
test_tc_neg_double_bad_383 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg_double_bad.json", t)
}

@(test)
test_tc_pat_prod_cast_ok_384 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_prod_cast_ok.json", t)
}

@(test)
test_tc_pat_insoluble_target_unknown_385 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_insoluble_target_unknown.json", t)
}

@(test)
test_tc_grammar_via_mention_bad_386 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_grammar_via_mention_bad.json", t)
}

@(test)
test_tc_unk_add_u16_ok_387 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_unk_add_u16_ok.json", t)
}

@(test)
test_tc_str_backtick_exact_bad_388 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_backtick_exact_bad.json", t)
}

@(test)
test_tc_eqset_bool_diff_bad_389 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_eqset_bool_diff_bad.json", t)
}

@(test)
test_tc_eqset_or_width_bad_390 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_eqset_or_width_bad.json", t)
}

@(test)
test_tc_pat_exh_default_391 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_exh_default.json", t)
}

@(test)
test_tc_flt_union_ok_392 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_flt_union_ok.json", t)
}

@(test)
test_tc_carve_shorthand_field_ok_393 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_shorthand_field_ok.json", t)
}

@(test)
test_tc_int_and_empty_bad_394 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_int_and_empty_bad.json", t)
}

@(test)
test_tc_prod_nest_bad_395 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_prod_nest_bad.json", t)
}

@(test)
test_tc_int_mul_concrete_bad_396 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_int_mul_concrete_bad.json", t)
}

@(test)
test_tc_carve_subst_inner_carve_present_ok_397 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_subst_inner_carve_present_ok.json", t)
}

@(test)
test_tc_ref_or_family_ok_398 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ref_or_family_ok.json", t)
}

@(test)
test_tc_carve_as_type_via_ref_bad_399 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_as_type_via_ref_bad.json", t)
}

@(test)
test_tc_color_nested_deep_bad_400 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_color_nested_deep_bad.json", t)
}

@(test)
test_tc_carve_self_property_ref_overflow_bad_401 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_self_property_ref_overflow_bad.json", t)
}

@(test)
test_tc_pat_grammar_exh_structural_402 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_grammar_exh_structural.json", t)
}

@(test)
test_tc_eqset_negunion_diff_bad_403 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_eqset_negunion_diff_bad.json", t)
}

@(test)
test_tc_carve_self_property_ref_spaced_ok_404 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_self_property_ref_spaced_ok.json", t)
}

@(test)
test_tc_eq_neg_exact_ok_405 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_eq_neg_exact_ok.json", t)
}

@(test)
test_tc_pat_char_value_nonexh_406 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_char_value_nonexh.json", t)
}

@(test)
test_tc_ref_neg_range_ok_407 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ref_neg_range_ok.json", t)
}

@(test)
test_tc_mixed_str_in_strf32_408 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_mixed_str_in_strf32.json", t)
}

@(test)
test_tc_int_add_concrete_ok_409 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_int_add_concrete_ok.json", t)
}

@(test)
test_tc_eqset_single_bad_410 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_eqset_single_bad.json", t)
}

@(test)
test_tc_union_rep_bad_411 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_union_rep_bad.json", t)
}

@(test)
test_tc_eqset_xd_str_int_bad_412 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_eqset_xd_str_int_bad.json", t)
}

@(test)
test_tc_cast_sum_no_cast_bad_413 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cast_sum_no_cast_bad.json", t)
}

@(test)
test_tc_carve_nested_bad_414 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_nested_bad.json", t)
}

@(test)
test_tc_comp_double_and_ok_415 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_comp_double_and_ok.json", t)
}

@(test)
test_tc_carve_nested_ok_416 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_nested_ok.json", t)
}

@(test)
test_tc_str_concat_pattern_bad_417 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_concat_pattern_bad.json", t)
}

@(test)
test_tc_execute_empty_none_fail_418 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_execute_empty_none_fail.json", t)
}

@(test)
test_tc_pat_bool_exh_419 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_bool_exh.json", t)
}

@(test)
test_tc_seq_email_ok_420 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_seq_email_ok.json", t)
}

@(test)
test_tc_comp_inter_unions_ok2_421 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_comp_inter_unions_ok2.json", t)
}

@(test)
test_tc_self_ref_set_bad_422 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_self_ref_set_bad.json", t)
}

@(test)
test_tc_bool_any_false_ok_423 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_bool_any_false_ok.json", t)
}

@(test)
test_tc_str_backtick_union_ok_424 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_backtick_union_ok.json", t)
}

@(test)
test_tc_int_mod_opaque_int_ok_425 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_int_mod_opaque_int_ok.json", t)
}

@(test)
test_tc_carve_sibling_override_subst_bad_426 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_sibling_override_subst_bad.json", t)
}

@(test)
test_tc_eqset_orneg_id_ok_427 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_eqset_orneg_id_ok.json", t)
}

@(test)
test_tc_pat_combined_bool_string_ok_428 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_combined_bool_string_ok.json", t)
}

@(test)
test_tc_pat_target_execute_ok_429 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_target_execute_ok.json", t)
}

@(test)
test_tc_cast_target_open_fail_430 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cast_target_open_fail.json", t)
}

@(test)
test_tc_str_range_pos_edge_ok_431 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_range_pos_edge_ok.json", t)
}

@(test)
test_tc_ident_ok_432 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ident_ok.json", t)
}

@(test)
test_tc_int_sub_concrete_bad_433 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_int_sub_concrete_bad.json", t)
}

@(test)
test_tc_flt_mul_concrete_ok_434 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_flt_mul_concrete_ok.json", t)
}

@(test)
test_tc_union_tri_int_ok_435 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_union_tri_int_ok.json", t)
}

@(test)
test_tc_mixed_int_bad_436 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_mixed_int_bad.json", t)
}

@(test)
test_tc_union_tri_bool_bad_437 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_union_tri_bool_bad.json", t)
}

@(test)
test_tc_int_div_opaque_int_ok_438 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_int_div_opaque_int_ok.json", t)
}

@(test)
test_tc_pat_combined_bool_string_bad_439 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_combined_bool_string_bad.json", t)
}

@(test)
test_tc_str_range_tri_nomid_bad_440 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_range_tri_nomid_bad.json", t)
}

@(test)
test_tc_eqset_or_reorder_ok_441 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_eqset_or_reorder_ok.json", t)
}

@(test)
test_tc_int_sub_range_bad_442 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_int_sub_range_bad.json", t)
}

@(test)
test_tc_pat_exh_typecheck_full_443 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_exh_typecheck_full.json", t)
}

@(test)
test_tc_comp_tri_union_mid_ok_444 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_comp_tri_union_mid_ok.json", t)
}

@(test)
test_tc_pat_exh_union_covers_445 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_exh_union_covers.json", t)
}

@(test)
test_tc_execute_as_type_bad_446 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_execute_as_type_bad.json", t)
}

@(test)
test_tc_bool_neg_true_ok_447 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_bool_neg_true_ok.json", t)
}

@(test)
test_tc_pat_prod_bool_ok_448 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_prod_bool_ok.json", t)
}

@(test)
test_tc_execute_as_type_ok_449 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_execute_as_type_ok.json", t)
}

@(test)
test_tc_scope_shape_wrong_name_bad_450 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_scope_shape_wrong_name_bad.json", t)
}

@(test)
test_tc_flt_add_concrete_bad_451 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_flt_add_concrete_bad.json", t)
}

@(test)
test_tc_pat_grammar_exh_full_452 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_grammar_exh_full.json", t)
}

@(test)
test_tc_cmp_lt0_ok_453 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cmp_lt0_ok.json", t)
}

@(test)
test_tc_str_range_prefix_bad_454 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_range_prefix_bad.json", t)
}

@(test)
test_tc_soluble_set_constraint_ok_455 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_soluble_set_constraint_ok.json", t)
}

@(test)
test_tc_map_mixed_union_ok_456 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_map_mixed_union_ok.json", t)
}

@(test)
test_tc_neg_pos_bad_457 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg_pos_bad.json", t)
}

@(test)
test_tc_int_add_u8u8_u16_ok_458 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_int_add_u8u8_u16_ok.json", t)
}

@(test)
test_tc_str_tri_range_nosuffix_bad_459 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_tri_range_nosuffix_bad.json", t)
}

@(test)
test_tc_str_ord_below_bad_460 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_ord_below_bad.json", t)
}

@(test)
test_tc_bool_true_ok_461 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_bool_true_ok.json", t)
}

@(test)
test_tc_int_and_gt_bad_462 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_int_and_gt_bad.json", t)
}

@(test)
test_tc_rep_exact_bad_463 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_rep_exact_bad.json", t)
}

@(test)
test_tc_scope_calc_field_bad_464 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_scope_calc_field_bad.json", t)
}

@(test)
test_tc_eqset_neg_range_diff_bad_465 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_eqset_neg_range_diff_bad.json", t)
}

@(test)
test_tc_str_squote_multi_pos_bad_466 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_squote_multi_pos_bad.json", t)
}

@(test)
test_tc_carve_as_type_via_ref_ok_467 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_as_type_via_ref_ok.json", t)
}

@(test)
test_tc_cast_target_unsized_float_fail_468 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cast_target_unsized_float_fail.json", t)
}

@(test)
test_tc_pat_mixed_modes_exh_469 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_mixed_modes_exh.json", t)
}

@(test)
test_tc_int_sub_concrete_ok_470 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_int_sub_concrete_ok.json", t)
}

@(test)
test_tc_scope_shape_calc_bad_471 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_scope_shape_calc_bad.json", t)
}

@(test)
test_tc_execute_value_ok_472 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_execute_value_ok.json", t)
}

@(test)
test_tc_str_union_mixed_len_ok_473 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_union_mixed_len_ok.json", t)
}

@(test)
test_tc_eqset_and_diff_bad_474 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_eqset_and_diff_bad.json", t)
}

@(test)
test_tc_cast_then_overflow_ok_475 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cast_then_overflow_ok.json", t)
}

@(test)
test_tc_cmp_gt6f_bad_476 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cmp_gt6f_bad.json", t)
}

@(test)
test_tc_str_neg_concat_bad_477 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_neg_concat_bad.json", t)
}

@(test)
test_tc_str_neg_plus_lit_bad_478 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_neg_plus_lit_bad.json", t)
}

@(test)
test_tc_scope_mixed_fields_ok_479 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_scope_mixed_fields_ok.json", t)
}

@(test)
test_tc_flt_open_hi_ok_480 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_flt_open_hi_ok.json", t)
}

@(test)
test_tc_prod_ok_481 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_prod_ok.json", t)
}

@(test)
test_tc_nested_prop_482 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_nested_prop.json", t)
}

@(test)
test_tc_scope_two_order_bad_483 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_scope_two_order_bad.json", t)
}

@(test)
test_tc_grammar_default_terminal_first_484 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_grammar_default_terminal_first.json", t)
}

@(test)
test_tc_ref_neg_range_bad_485 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ref_neg_range_bad.json", t)
}

@(test)
test_tc_union_char_int_bad_486 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_union_char_int_bad.json", t)
}

@(test)
test_tc_pat_target_arith_exh_487 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_target_arith_exh.json", t)
}

@(test)
test_tc_eqset_and_id_ok_488 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_eqset_and_id_ok.json", t)
}

@(test)
test_tc_str_rep_range_bad_489 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_rep_range_bad.json", t)
}

@(test)
test_tc_int_mixed_sign_u16_default_ok_490 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_int_mixed_sign_u16_default_ok.json", t)
}

@(test)
test_tc_neg_str_exact_bad_491 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg_str_exact_bad.json", t)
}

@(test)
test_tc_ident_no_trail_ok_492 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ident_no_trail_ok.json", t)
}

@(test)
test_tc_scope_calc_range_field_ok_493 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_scope_calc_range_field_ok.json", t)
}

@(test)
test_tc_prod_nest_ok_494 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_prod_nest_ok.json", t)
}

@(test)
test_tc_comp_and_or_ok_neg_495 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_comp_and_or_ok_neg.json", t)
}

@(test)
test_tc_scope_calc_mul_ok_496 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_scope_calc_mul_ok.json", t)
}

@(test)
test_tc_scope_two_second_overflow_bad_497 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_scope_two_second_overflow_bad.json", t)
}

@(test)
test_tc_map_mixed_u8_bad_498 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_map_mixed_u8_bad.json", t)
}

@(test)
test_tc_carve_as_type_ok_499 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_as_type_ok.json", t)
}

@(test)
test_tc_pull_unify_agree_ok_500 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pull_unify_agree_ok.json", t)
}

@(test)
test_tc_eqset_negunion_id_ok_501 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_eqset_negunion_id_ok.json", t)
}

@(test)
test_tc_str_union_class_literal_ok_502 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_union_class_literal_ok.json", t)
}

@(test)
test_tc_mixed_strint_int_503 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_mixed_strint_int.json", t)
}

@(test)
test_tc_int_sub_u8u8_u8_default0_ok_504 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_int_sub_u8u8_u8_default0_ok.json", t)
}

@(test)
test_tc_eqset_xd_negflt_str_bad_505 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_eqset_xd_negflt_str_bad.json", t)
}

@(test)
test_tc_carve_dep_incoherent_sub_bad_506 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_dep_incoherent_sub_bad.json", t)
}

@(test)
test_tc_comp_tri_union_gap_bad_507 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_comp_tri_union_gap_bad.json", t)
}

@(test)
test_tc_ref_range_and_ok_508 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ref_range_and_ok.json", t)
}

@(test)
test_tc_neg10_bad_509 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg10_bad.json", t)
}

@(test)
test_tc_cast_target_int_fail_510 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cast_target_int_fail.json", t)
}

@(test)
test_tc_carve_implicit_independent_ok_511 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_implicit_independent_ok.json", t)
}

@(test)
test_tc_seq_range_count_bad_512 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_seq_range_count_bad.json", t)
}

@(test)
test_tc_carve_override_ok_513 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_override_ok.json", t)
}

@(test)
test_tc_carve_514 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve.json", t)
}

@(test)
test_tc_mixed_strint_float_515 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_mixed_strint_float.json", t)
}

@(test)
test_tc_eqset_neg_range_id_ok_516 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_eqset_neg_range_id_ok.json", t)
}

@(test)
test_tc_ref_neg_singleton_ok2_517 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ref_neg_singleton_ok2.json", t)
}

@(test)
test_tc_union_char_int_char_ok_518 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_union_char_int_char_ok.json", t)
}

@(test)
test_tc_eqset_u8_id_ok_519 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_eqset_u8_id_ok.json", t)
}

@(test)
test_tc_bool_any_true_ok_520 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_bool_any_true_ok.json", t)
}

@(test)
test_tc_scope_calc_field_ok_521 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_scope_calc_field_ok.json", t)
}

@(test)
test_tc_ord_char_bad_522 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_ord_char_bad.json", t)
}

@(test)
test_tc_bool_neg_true_bad_523 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_bool_neg_true_bad.json", t)
}

@(test)
test_tc_insoluble_scope_field_524 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_insoluble_scope_field.json", t)
}

@(test)
test_tc_char_union_neg_bad_525 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_char_union_neg_bad.json", t)
}

@(test)
test_tc_scope_shape_wrong_family_bad_526 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_scope_shape_wrong_family_bad.json", t)
}

@(test)
test_tc_comp_and_or_ok_hi_527 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_comp_and_or_ok_hi.json", t)
}

@(test)
test_tc_seq_range_count_ok_528 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_seq_range_count_ok.json", t)
}

@(test)
test_tc_pat_grammar_exh_head_only_529 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_grammar_exh_head_only.json", t)
}

@(test)
test_tc_cast_target_unbounded_int_fail_530 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cast_target_unbounded_int_fail.json", t)
}

@(test)
test_tc_seq_two_classes_ok_531 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_seq_two_classes_ok.json", t)
}

@(test)
test_tc_flt_neg_bad_532 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_flt_neg_bad.json", t)
}

@(test)
test_tc_execute_ref_binding_ok_533 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_execute_ref_binding_ok.json", t)
}

@(test)
test_tc_eqset_str_neg_diff_bad_534 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_eqset_str_neg_diff_bad.json", t)
}

@(test)
test_tc_color_carve_pos_bad_535 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_color_carve_pos_bad.json", t)
}

@(test)
test_tc_str_neg_ord_seq_ok_536 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_neg_ord_seq_ok.json", t)
}

@(test)
test_tc_carve_dep_incoherent_add_bad_537 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_dep_incoherent_add_bad.json", t)
}

@(test)
test_tc_str_dquote_1char_pos_bad_538 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_dquote_1char_pos_bad.json", t)
}

@(test)
test_tc_cmp_gt6f_ok_539 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cmp_gt6f_ok.json", t)
}

@(test)
test_tc_scope_shape_overflow_bad_540 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_scope_shape_overflow_bad.json", t)
}

@(test)
test_tc_flt_add_concrete_ok_541 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_flt_add_concrete_ok.json", t)
}

@(test)
test_tc_bool_false_ok_542 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_bool_false_ok.json", t)
}

@(test)
test_tc_str_dquote_1char_pos_ok_543 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_dquote_1char_pos_ok.json", t)
}

@(test)
test_tc_str_rep_concrete_ok_544 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_rep_concrete_ok.json", t)
}

@(test)
test_tc_seq_email_bad_545 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_seq_email_bad.json", t)
}

@(test)
test_tc_int_sub_range_hi_ok_546 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_int_sub_range_hi_ok.json", t)
}

@(test)
test_tc_scope_nested_ok_547 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_scope_nested_ok.json", t)
}

@(test)
test_tc_neg_char_bad_548 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg_char_bad.json", t)
}

@(test)
test_tc_str_tri_range_url_bad_549 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_tri_range_url_bad.json", t)
}

@(test)
test_tc_prod_int_union_wider_bad_550 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_prod_int_union_wider_bad.json", t)
}

@(test)
test_tc_self_singleton_ok_551 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_self_singleton_ok.json", t)
}

@(test)
test_tc_union_u8_f32_float_ok_552 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_union_u8_f32_float_ok.json", t)
}

@(test)
test_tc_eqset_xd_negint_negstr_bad_553 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_eqset_xd_negint_negstr_bad.json", t)
}

@(test)
test_tc_insoluble_or_554 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_insoluble_or.json", t)
}

@(test)
test_tc_union_tri_float_ok_555 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_union_tri_float_ok.json", t)
}

@(test)
test_tc_int_add_overflow_bad_556 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_int_add_overflow_bad.json", t)
}

@(test)
test_tc_pat_grammar_exh_empty_only_557 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_pat_grammar_exh_empty_only.json", t)
}

@(test)
test_tc_neg_ord_range_ok_558 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg_ord_range_ok.json", t)
}

@(test)
test_tc_neg_int_ok_559 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_neg_int_ok.json", t)
}

@(test)
test_tc_cast_char_to_u8_ok_560 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cast_char_to_u8_ok.json", t)
}

@(test)
test_tc_mixed_strint_str_561 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_mixed_strint_str.json", t)
}

@(test)
test_tc_cast_f64_to_f32_ok_562 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cast_f64_to_f32_ok.json", t)
}

@(test)
test_tc_flt_range_ok_563 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_flt_range_ok.json", t)
}

@(test)
test_tc_char_builtin_rejects_int_564 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_char_builtin_rejects_int.json", t)
}

@(test)
test_tc_str_backtick_in_string_ok_565 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_backtick_in_string_ok.json", t)
}

@(test)
test_tc_char_rep_union_ok_566 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_char_rep_union_ok.json", t)
}

@(test)
test_tc_mixed_float_567 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_mixed_float.json", t)
}

@(test)
test_tc_str_tri_range_contains_ok_568 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_tri_range_contains_ok.json", t)
}

@(test)
test_tc_str_neg_concat_digits_ok_569 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_str_neg_concat_digits_ok.json", t)
}

@(test)
test_tc_cmp_ge5_ok_570 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_cmp_ge5_ok.json", t)
}

@(test)
test_tc_carve_sibling_override_subst_571 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_carve_sibling_override_subst.json", t)
}

@(test)
test_tc_flt_inter_bad_572 :: proc(t: ^testing.T) {
	run_typecheck_test("tests/tc_flt_inter_bad.json", t)
}

