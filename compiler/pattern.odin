package compiler

import "core:fmt"

// Pattern domain — `target ? { match -> product, … }`.
//
// A pattern is assessed ON something (its `target`). Each branch carries a
// `match` and a `product`, plus a `value_match` mode flag:
//
//   * TYPECHECK mode (value_match = false, written `u8 -> …`): the match is a
//     CONSTRAINT. The branch fires for a target value v iff v satisfies the
//     match's constraint set — fold_value_type(v) ⊆ fold_constraint(match).
//   * VALUE mode (value_match = true, written `=5 -> …`): the match is a VALUE.
//     The branch fires iff the target value EQUALS the match value (singleton
//     membership on both sides).
//   * DEFAULT (match = nil, written `-> …`): matches anything; makes the pattern
//     exhaustive on its own.
//
// Branches are always considered IN ORDER. Folding splits three ways:
//   * fold_constraint(pattern)  → resolves to ONE branch: the product of the
//     FIRST branch whose match the target satisfies (the deterministic case).
//   * fold_value_type(pattern)  → may resolve to MULTIPLE branches: the combined
//     type (Or of every product whose branch the target CAN reach).
//   * exhaustiveness            → the union of all branch matches must cover the
//     target's type, OR one branch must be the empty-arrow default.
//
// The IR (Pattern_Type / Pattern_Branch) lives in ir.odin; this file builds it
// from the analyzer (build_pattern), folds it, and proves exhaustiveness.

// build_pattern_branch assembles one Pattern_Branch from a walked (match, product)
// pair. A match expression written with the unary `=` prefix arrives as an
// Operator_Type-less node — actually a Compose/Operator we detect by shape: the
// analyzer hands us `value_match` already split out (see walk_pattern), so here we
// only box the parts.
build_pattern_branch :: proc(match: ^Type, product: ^Type, value_match: bool) -> Pattern_Branch {
	return Pattern_Branch{value_match = value_match, match = match, product = product}
}

// branch_covers reports whether a branch fully ABSORBS the target — i.e. the
// target's type_fold satisfies this branch's match (a typecheck branch `M` taken
// as M, a value branch `=v` taken as the producer `{-> v}`). When true, EVERY
// target value lands in this branch, so it fires deterministically and later
// branches are dead. A default branch (nil match) covers everything. This is the
// ordinary binding proof satisfy_root(fc, ft) run for a single branch's match.
branch_covers :: proc(branch: Pattern_Branch, ft: ^Type) -> bool {
	if branch.match == nil do return true // default covers everything
	if ft == nil do return false
	mc := branch_match_cover(branch)
	if mc == nil do return false
	// A match that does not fold to a constraint set (e.g. a comparison `2>2`,
	// which is not a static set) covers nothing — don't hand a nil to satisfy_root.
	fc := fold_constraint(mc)
	if fc == nil do return false
	return satisfy_root(fc, ft)
}

// branch_can_match is the in-order firing test: a branch fires for `ft` iff it
// covers it. Thin alias over branch_covers so callers read intent-first.
branch_can_match :: proc(branch: Pattern_Branch, ft: ^Type) -> bool {
	return branch_covers(branch, ft)
}

// pattern_target_fold folds a pattern's target to its value type (the typeof the
// branches are matched against). Returns nil when the target can't be resolved.
pattern_target_fold :: proc(p: Pattern_Type) -> ^Type {
	return fold_value_type(p.target)
}

// pattern_target_is_concrete reports whether a folded target value is a single
// concrete value (a singleton) — directly, or wrapped in a producer scope `{-> v}`
// (which fold_value_type builds for a value). A concrete target lets fold pick the
// first matching branch in order; a set target does not.
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

// fold_constraint_pattern resolves a pattern used as a CONSTRAINT to a single
// branch: the product of the FIRST branch whose match the target satisfies. When
// the target itself can't be folded statically the fold fails (nil) — except a
// target that depends on an unknown, which propagates Unknown so the constraint
// is diagnosed Insoluble_Constraint rather than silently skipped.
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

// fold_type_pattern resolves a pattern used as a VALUE to its product type.
//
// Two cases, per the spec:
//   * If ONE branch fully COVERS the target, we know AT COMPILE TIME which branch
//     fires (the first such branch, in order) — the fold is exactly its product.
//   * Otherwise we cannot tell statically which branch will fire, so the value is
//     the COMBINED type of every branch's product: an Or, left-folded in order.
//     (e.g. target u8, branches `0..120 -> ""`, `22..255 -> 10` — neither covers
//     u8 alone, so the type is `"" | 10`.)
fold_type_pattern :: proc(t: ^Type) -> ^Type {
	p, ok := t^.(Pattern_Type)
	if !ok do return nil
	ft := pattern_target_fold(p)
	if ft == nil do return nil

	// When the target is a CONCRETE singleton we know its exact value, so we can run
	// the branches in order and take the FIRST that matches — fully deterministic
	// (`5 ? {=7 -> 100, -> 0}` fires the default → 0). branch_covers is exact here.
	if pattern_target_is_concrete(ft) {
		for branch in p.branches {
			if branch_covers(branch, ft) {
				return fold_value_type(branch.product)
			}
		}
	}

	// Otherwise the target is a SET (a range / `??`): deterministic ONLY when the
	// FIRST branch already covers the whole target (it always fires, later branches
	// dead). A branch that covers but sits AFTER branches intercepting part of the
	// target is NOT deterministic — earlier branches steal some values, so the result
	// is the combined type. (Bug if we returned the first *covering* branch: `?? :
	// u8 ? {0..127 -> 0, -> 1}` would fold to `1`, dropping `0`, instead of `0 | 1`.)
	if len(p.branches) > 0 && branch_covers(p.branches[0], ft) {
		return fold_value_type(p.branches[0].product)
	}

	// Non-deterministic: combine every branch's product into one Or type.
	combined: ^Type = nil
	for branch in p.branches {
		pf := fold_value_type(branch.product)
		if pf == nil do continue
		if combined == nil {
			combined = pf
		} else {
			combined = new_type(Or_Type{combined, pf})
		}
	}
	return combined
}

// branch_match_cover yields the match a branch contributes to the coverage union.
// A typecheck branch `M` contributes M as-is (a type). A value branch `=v`
// contributes `{-> v}` — v bundled in a producer scope, because `=v` means "the
// value IS v", exactly what a producer constraint expresses. A default branch
// (nil match) returns nil. This is the ONLY place the two modes differ.
branch_match_cover :: proc(branch: Pattern_Branch) -> ^Type {
	if branch.match == nil do return nil
	if branch.value_match do return make_producer_scope(branch.match)
	return branch.match
}

// pattern_is_exhaustive reports whether the pattern covers its whole target.
// A pattern is exhaustive when EITHER a branch is the empty-arrow default
// (match == nil), OR the OR of all branch matches typechecks against the target —
// i.e. fold_value_type(target) satisfies fold_constraint(Or of matches). This is
// just the ordinary binding proof `satisfy_root(fc, ft)` run against the union the
// branches build: a value branch `=v` enters the union as `{-> v}`, a typecheck
// branch `M` as M. So `(0..120 | 22..255)` covers a u8 target exactly as the
// binding `(0..120 | 22..255):data -> ??::u8` typechecks.
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
	ft := fold_value_type(p.target)
	// A match or target that does not resolve to a static set (e.g. a comparison
	// `2>2`) can't prove coverage — and must not reach satisfy_root with a nil.
	if fc == nil || ft == nil do return false
	return satisfy_root(fc, ft)
}

// describe_pattern renders a compact pattern for diagnostics.
describe_pattern :: proc(p: Pattern_Type) -> string {
	return fmt.tprintf("a pattern with %d branch(es)", len(p.branches))
}
