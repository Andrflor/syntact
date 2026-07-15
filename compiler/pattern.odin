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
	// The fired product folds with its cover substituted by the matched pieces
	// (destructuring) — `{u8:(v)} -> v + 1` over `{3}` folds as 4, not as the
	// cover default.
	if pattern_target_is_concrete(ft) {
		for branch in p.branches {
			if branch_covers(branch, ft) {
				return fold_type(fired_product(branch, ft))
			}
		}
	}

	// Set target: deterministic ONLY when the FIRST branch covers the whole target.
	// A covering branch AFTER intercepting ones is NOT deterministic — earlier
	// branches steal values, so the result is the combined Or type.
	if len(p.branches) > 0 && branch_covers(p.branches[0], ft) {
		return fold_type(fired_product(p.branches[0], ft))
	}

	combined: ^Type = nil
	for branch, i in p.branches {
		// Fold the product with the scrutinee narrowed to what THIS branch implies
		// (cover & ~priors): inside `0 -> n` the mention n folds to 0, not to n's
		// declared domain. This is what lets a terminating recursion over a symbolic
		// argument fold to its exit value (`f{n -> ??::u64}!` → the exit branch's
		// singleton), exactly like a constant exit product would. A scope target's
		// pieces destructure into the cover the same way (fired_product falls back
		// to the raw product when there is nothing to destructure).
		saved := install_fold_refinement(p.target, p.branches[:], i)
		pf := fold_type(fired_product(branch, ft))
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

// destructure_cover materializes the substitution a fired branch implies: a clone
// of the literal scope cover whose structural fields carry the matched PIECES of
// the scrutinee, consumed positionally exactly like the scope_satisfy_range proof
// that fired the branch — one value per plain field, an Expand (`...C:(r)`)
// swallowing the whole remaining run as a fresh scope (the cons tail). Productions
// are not destructured. nil when there is nothing structural to bind or the
// scrutinee is not a scope of pieces.
destructure_cover :: proc(cover: ^Scope_Type, pieces: ^Scope_Type) -> ^Scope_Type {
	structural := false
	for k in cover.kind do if k != .Product do structural = true
	if !structural do return nil

	sub := scope_clone(cover)
	vi := 0
	for i := 0; i < len(sub.kind); i += 1 {
		if sub.kind[i] == .Product do continue
		if sub.kind[i] == .Expand {
			rest := new_type(Scope_Type{parent = pieces.parent})
			rs := &rest.(Scope_Type)
			for k := vi; k < len(pieces.types); k += 1 {
				append(&rs.names, k < len(pieces.names) ? pieces.names[k] : "")
				append(&rs.kind, k < len(pieces.kind) ? pieces.kind[k] : Binding_Kind.Pointing_Push)
				append(&rs.types, pieces.types[k])
				append(&rs.constraints, k < len(pieces.constraints) ? pieces.constraints[k] : nil)
				append(&rs.captures, k < len(pieces.captures) ? pieces.captures[k] : "")
				append(&rs.type_folds, k < len(pieces.type_folds) ? pieces.type_folds[k] : nil)
				append(&rs.constraint_folds, k < len(pieces.constraint_folds) ? pieces.constraint_folds[k] : nil)
			}
			sub.types[i] = rest
			if i < len(sub.type_folds) do sub.type_folds[i] = rest
			vi = len(pieces.types)
			continue
		}
		if vi < len(pieces.types) {
			sub.types[i] = pieces.types[vi]
			if i < len(sub.type_folds) {
				sub.type_folds[i] = vi < len(pieces.type_folds) ? pieces.type_folds[vi] : nil
			}
			vi += 1
		}
	}
	return sub
}

// fired_product: the product of a fired branch with its cover SUBSTITUTED by the
// scrutinee's matched pieces — firing IS a carve of the cover by the scrutinee.
// The substitution is the ordinary copy-on-write repoint (the carve machinery), so
// mentions of the cover's fields/captures inside the product read the destructured
// values through every fold/reduce path with no side state. Falls back to the raw
// product when there is nothing to destructure (non-scope cover, `=v` producer,
// non-scope scrutinee).
fired_product :: proc(branch: Pattern_Branch, scrutinee: ^Type) -> ^Type {
	if branch.match == nil || branch.product == nil || scrutinee == nil do return branch.product
	cover, c_ok := &branch.match^.(Scope_Type)
	if !c_ok do return branch.product
	res := follow(scrutinee)
	if res == nil do return branch.product
	pieces, p_ok := &res^.(Scope_Type)
	if !p_ok do return branch.product
	sub := destructure_cover(cover, pieces)
	if sub == nil do return branch.product
	return repoint(branch.product, cover, sub)
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
