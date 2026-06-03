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

// branch_match_constraint folds a branch's match to the constraint SET it tests
// against — the same for both modes: a value match `=5` tests the singleton {5},
// a typecheck match `u8` tests the set 0..255. Returns nil for a default branch
// or an unresolved match.
branch_match_constraint :: proc(branch: Pattern_Branch) -> ^Type {
	if branch.match == nil do return nil
	return fold_constraint(branch.match)
}

// branch_covers reports whether a branch fully ABSORBS the target's folded value
// `ft` — i.e. ft ⊆ match. When true, every target value lands in this branch, so
// later branches are dead (the first covering branch wins, in order). A default
// branch (nil match) covers everything. This is the predicate both the in-order
// single-branch selection and the runtime reduction use.
branch_covers :: proc(branch: Pattern_Branch, ft: ^Type) -> bool {
	if branch.match == nil do return true // default covers everything
	if ft == nil do return false
	mc := branch_match_constraint(branch)
	if mc == nil do return false
	return satisfy_root(mc, ft)
}

// branch_can_match is the in-order firing test: a branch fires for `ft` iff it
// covers it (its match set contains the whole target value). Kept as a thin alias
// over branch_covers so callers read intent-first.
branch_can_match :: proc(branch: Pattern_Branch, ft: ^Type) -> bool {
	return branch_covers(branch, ft)
}

// pattern_target_fold folds a pattern's target to its value type (the typeof the
// branches are matched against). Returns nil when the target can't be resolved.
pattern_target_fold :: proc(p: Pattern_Type) -> ^Type {
	return fold_value_type(p.target)
}

// fold_constraint_pattern resolves a pattern used as a CONSTRAINT to a single
// branch: the product of the FIRST branch whose match the target satisfies. When
// the target itself can't be folded statically (e.g. an unknown), no branch can
// be selected and the fold fails (nil).
fold_constraint_pattern :: proc(t: ^Type) -> ^Type {
	p, ok := t^.(Pattern_Type)
	if !ok do return nil
	ft := pattern_target_fold(p)
	if ft == nil do return nil
	for branch in p.branches {
		if branch_can_match(branch, ft) {
			return fold_constraint(branch.product)
		}
	}
	return nil
}

// fold_type_pattern resolves a pattern used as a VALUE to the COMBINED type of
// every branch the target can reach (an Or of their products, in order). With a
// statically-known target only the reachable branches contribute; with one
// reachable branch it collapses to that product's type.
fold_type_pattern :: proc(t: ^Type) -> ^Type {
	p, ok := t^.(Pattern_Type)
	if !ok do return nil
	ft := pattern_target_fold(p)
	if ft == nil do return nil

	reachable := make([dynamic]^Type, 0, len(p.branches))
	for branch in p.branches {
		// In-order semantics: the FIRST branch that fully COVERS the target wins and
		// makes every later branch dead. For a statically-known (singleton) target a
		// branch fires iff it covers, so the first covering branch is the only
		// reachable product — an exact fold. Stop there.
		if branch_covers(branch, ft) {
			pf := fold_value_type(branch.product)
			if pf != nil do append(&reachable, pf)
			break
		}
	}
	if len(reachable) == 0 do return nil
	if len(reachable) == 1 do return reachable[0]
	// Combine the reachable products into a union type, left-folded in order.
	combined := reachable[0]
	for i := 1; i < len(reachable); i += 1 {
		combined = new_type(Or_Type{combined, reachable[i]})
	}
	return combined
}

// pattern_is_exhaustive reports whether the pattern covers its whole target.
// A pattern is exhaustive when EITHER a branch is the empty-arrow default
// (match == nil), OR the union of every branch's match covers the target's type.
//
// The union check is exact only for the cases the satisfy machinery decides: we
// prove the target's type satisfies the OR of all branch matches (each match
// folded to its constraint set). When the target can't be folded, we treat the
// pattern as non-exhaustive unless a default is present (we cannot prove cover).
pattern_is_exhaustive :: proc(p: Pattern_Type) -> bool {
	for branch in p.branches {
		if branch.match == nil do return true // empty-arrow default covers everything
	}
	ft := pattern_target_fold(p)
	if ft == nil do return false

	// Build the union of all branch matches (their constraint sets) and prove the
	// target's type falls inside it. Value-mode matches contribute their singleton.
	cover: ^Type = nil
	for branch in p.branches {
		mc := fold_constraint(branch.match)
		if mc == nil do return false // an unresolved match: cannot prove cover
		if cover == nil {
			cover = mc
		} else {
			cover = new_type(Or_Type{cover, mc})
		}
	}
	if cover == nil do return false
	return set_subset(ft, cover)
}

// set_subset proves `sub ⊆ sup` as a PURE set inclusion — every value of sub is
// in sup. Unlike satisfy_root it does NOT apply the self-match rule (a set DOES
// cover an equal set here), because pattern exhaustiveness is exactly "is the
// target's type_fold contained in the union of the branch matches" — a typecheck
// in reverse where `0..` must be coverable by `=0..`. Producer-scope wrappers are
// peeled so a match set compares interval-to-interval. Domain dispatch; a union on
// either side splits; cross-family → false.
set_subset :: proc(sub, sup: ^Type) -> bool {
	if sub == nil || sup == nil do return false
	s := unwrap_producer(sub)
	p := unwrap_producer(sup)
	#partial switch sv in s^ {
	case Integer_Type:
		if pv, ok := p^.(Integer_Type); ok {
			return integer_intervals_satisfy(sv.integer_intervals, pv.integer_intervals)
		}
	case Float_Type:
		if pv, ok := p^.(Float_Type); ok {
			return float_intervals_satisfy(sv.float_intervals, pv.float_intervals)
		}
	case String_Type:
		if pv, ok := p^.(String_Type); ok {
			return string_intervals_satisfy(sv.string_intervals, pv.string_intervals)
		}
	case Bool_Type:
		if pv, ok := p^.(Bool_Type); ok {
			return bool_satisfy(pv, sv) // bool_satisfy(constraint, value) proves value ⊆ constraint
		}
	case None_Type:
		return true // the empty set is a subset of anything
	case Or_Type:
		return set_subset(sv.left, sup) && set_subset(sv.right, sup)
	}
	// A union on the sup side: the sub must fall entirely in one of the parts.
	if pv, ok := p^.(Or_Type); ok {
		return set_subset(sub, pv.left) || set_subset(sub, pv.right)
	}
	return false
}

// describe_pattern renders a compact pattern for diagnostics.
describe_pattern :: proc(p: Pattern_Type) -> string {
	return fmt.tprintf("a pattern with %d branch(es)", len(p.branches))
}
