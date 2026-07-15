package compiler

import "core:fmt"

// Pattern domain — `target ? { match -> product, … }`. Three branch modes:
// typecheck (`u8 -> …`, fires when target ⊆ match's constraint), value
// (`=5 -> …`, fires on equality), default (`-> …`, matches anything). Branches
// are considered IN ORDER. The IR lives in ir.odin; this file builds, folds, and
// proves exhaustiveness.

// build_pattern_branch boxes a walked (match, product) pair. A `=v` value-match is
// already desugared by walk into the producer scope `{-> v}` in `match`, so the firing
// set is always `fold_constraint(match)` — no per-branch mode to thread through.
build_pattern_branch :: proc(match: ^Type, product: ^Type) -> Pattern_Branch {
	b := Pattern_Branch {
		match   = match,
		product = product,
	}
	// Cache the branch's firing set NOW (analysis time): reduce_pattern reads this
	// cache — no fold ever runs during reduce.
	if match != nil {
		b.cover_fold = fold_constraint(match)
	}
	return b
}

// branch_covers reports whether a branch fully ABSORBS the target (every target
// value lands here, so later branches are dead). A default branch covers
// everything. The ordinary satisfy_root proof run for one branch's match.
branch_covers :: proc(branch: Pattern_Branch, ft: ^Type) -> bool {
	if branch.match == nil do return true // default covers everything
	if ft == nil do return false
	mc := branch_match_cover(branch)
	if mc == nil do return false
	// A match that does not fold to a static set (e.g. `2>2`) covers nothing —
	// don't hand a nil to satisfy_root.
	fc := fold_constraint(mc)
	if fc == nil do return false
	return satisfy_root(fc, ft)
}

// branch_can_match is the in-order firing test (alias over branch_covers).
branch_can_match :: proc(branch: Pattern_Branch, ft: ^Type) -> bool {
	return branch_covers(branch, ft)
}

pattern_target_fold :: proc(p: Pattern_Type) -> ^Type {
	return fold_type(p.target)
}

// pattern_target_is_concrete reports whether a folded target is a singleton
// (directly or wrapped in a producer scope `{-> v}`). A concrete target lets fold
// pick the first matching branch in order; a set target does not.
pattern_target_is_concrete :: proc(ft: ^Type) -> bool {
	if ft == nil do return false
	if fold_is_concrete_value(ft) do return true
	#partial switch v in ft^ {
	case Scope_Type:
		prods := scope_productions(v)
		if len(prods) == 1 do return fold_is_concrete_value(prods[0])
	}
	return false
}

// fold_constraint_pattern resolves a pattern used as a CONSTRAINT to the product of
// the FIRST branch whose match the target satisfies. A target depending on an
// unknown propagates Unknown (so it is diagnosed Insoluble rather than skipped).
fold_constraint_pattern :: proc(t: ^Type) -> ^Type {
	p, ok := t^.(Pattern_Type)
	if !ok do return nil
	if tf := fold_constraint(p.target); fold_is_unknown(tf) do return tf
	ft := pattern_target_fold(p)
	if ft == nil do return nil
	for branch in p.branches {
		if branch_can_match(branch, ft) {
			return fold_constraint(branch.product)
		}
	}
	return nil
}

// fold_type_pattern resolves a pattern used as a VALUE to its product type. If one
// branch covers the target the fold is exactly its product; otherwise the value is
// the Or of every reachable branch's product.
fold_type_pattern :: proc(t: ^Type) -> ^Type {
	p, ok := t^.(Pattern_Type)
	if !ok do return nil
	ft := pattern_target_fold(p)
	if ft == nil do return nil

	// Concrete singleton target: run branches in order, take the FIRST that matches.
	if pattern_target_is_concrete(ft) {
		for branch in p.branches {
			if branch_covers(branch, ft) {
				return fold_type(branch.product)
			}
		}
	}

	// Set target: deterministic ONLY when the FIRST branch covers the whole target.
	// A covering branch AFTER intercepting ones is NOT deterministic — earlier
	// branches steal values, so the result is the combined Or type.
	if len(p.branches) > 0 && branch_covers(p.branches[0], ft) {
		return fold_type(p.branches[0].product)
	}

	combined: ^Type = nil
	for branch, i in p.branches {
		// Fold the product with the scrutinee narrowed to what THIS branch implies
		// (cover & ~priors): inside `0 -> n` the mention n folds to 0, not to n's
		// declared domain. This is what lets a terminating recursion over a symbolic
		// argument fold to its exit value (`f{n -> ??::u64}!` → the exit branch's
		// singleton), exactly like a constant exit product would.
		saved := install_fold_refinement(p.target, p.branches[:], i)
		pf := fold_type(branch.product)
		uninstall_fold_refinement(saved)
		if pf == nil do continue
		if combined == nil {
			combined = pf
		} else {
			combined = new_type(Or_Type{combined, pf})
		}
	}
	return combined
}

// branch_match_cover yields the match a branch contributes to the coverage union:
// a typecheck branch `M` as-is, a default branch nil. A value branch `=v` is the
// producer `{-> v}` in `match`. SINGLETON SUGAR: when `v` is a singleton (a bottom
// type — `true`, `false`, `10`, a one-value set), `=v` and `v` denote the same thing
// (there is no difference between "is the value v" and "is of type v" when type v
// has exactly one value), so the cover is the singleton `v`, exactly like a bare `v`
// branch. This makes `=true | =false` exhaustive over bool, like `true | false`. A
// NON-singleton `=v` (e.g. `=u8`) keeps the producer — there `=v` ≠ `v` by design.
branch_match_cover :: proc(branch: Pattern_Branch) -> ^Type {
	if branch.match == nil do return nil
	leaf := cover_leaf(fold_constraint(branch.match))
	if leaf != nil && fold_is_concrete_value(leaf) do return leaf
	return branch.match
}

// pattern_is_exhaustive reports whether the pattern covers its whole target:
// either a branch is the empty-arrow default, or the Or of all branch matches
// typechecks against the target (the ordinary satisfy_root proof on the union).
pattern_is_exhaustive :: proc(p: Pattern_Type) -> bool {
	for branch in p.branches {
		if branch.match == nil do return true // empty-arrow default covers everything
	}
	cover: ^Type = nil
	for branch in p.branches {
		mc := branch_match_cover(branch)
		if mc == nil do continue
		if cover == nil {
			cover = mc
		} else {
			cover = new_type(Or_Type{cover, mc})
		}
	}
	if cover == nil do return false
	fc := fold_constraint(cover)
	ft := fold_type(p.target)
	// A match/target that is not a static set (e.g. `2>2`) can't prove coverage and
	// must not reach satisfy_root with a nil.
	if fc == nil || ft == nil do return false
	return satisfy_root(fc, ft)
}

describe_pattern :: proc(p: Pattern_Type) -> string {
	return fmt.tprintf("a pattern with %d branch(es)", len(p.branches))
}
