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
	// cache first. A reduce-side clone invalidates it to nil (repoint refold=false);
	// reduce_branch_fires then refolds it on demand.
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
	// cover default. No rebound shadowing here: with a concrete scrutinee the
	// current frame IS the only path, so a rebound binding's frame value is exact.
	if pattern_target_is_concrete(ft) {
		for branch in p.branches {
			if branch_covers(branch, ft) {
				return fold_type(fired_product(branch, ft))
			}
		}
	}

	// SET target: a recursive carve inside a branch product (`f{n->n-1, acc->acc+n}`)
	// makes every binding it REBINDS path-dependent — each materialization carries
	// its own value, so folding such a mention to the CURRENT frame's value would
	// bake the first frame into every path (`0 -> acc` folded acc to its initial 0:
	// silently wrong). Those sites fold as Unknown while the branch products fold;
	// a branch-cover refinement still wins for the scrutinee itself (`0 -> n` keeps
	// folding n to 0 — install_rebound_shadow skips already-overridden sites).
	rebound := pattern_rebound_sites(&p, t)
	defer delete(rebound)

	// Deterministic ONLY when the FIRST branch covers the whole target.
	// A covering branch AFTER intercepting ones is NOT deterministic — earlier
	// branches steal values, so the result is the combined Or type.
	if len(p.branches) > 0 && branch_covers(p.branches[0], ft) {
		shadow := install_rebound_shadow(rebound[:])
		defer uninstall_fold_refinement(shadow)
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
		shadow := install_rebound_shadow(rebound[:])
		pf := fold_type(fired_product(branch, ft))
		uninstall_fold_refinement(shadow)
		uninstall_fold_refinement(saved)
		if pf == nil {
			// A branch that folds to nothing is skippable ONLY when it is the pure
			// tail re-entry of this very pattern — its value IS the eventual exit
			// value, already contributed by the exit branches. Any other unfoldable
			// branch might fire with a value of its own (`n * f{…}!`): claiming the
			// Or of the remaining branches would bake a wrong constant, so the
			// pattern folds to nothing and stays symbolic.
			if product_is_pure_tail(branch.product, pattern_home_scope(&p), t) do continue
			return nil
		}
		if combined == nil {
			combined = pf
		} else {
			combined = new_type(Or_Type{combined, pf})
		}
	}
	return combined
}

// grammar_tail_domain: the union of a grammar machine's productions' expand
// tails — the domain of "the rest of a run" of that grammar (for Array, the cons
// tail `Array{T}`).
grammar_tail_domain :: proc(machine: ^Scope_Type) -> ^Type {
	out: ^Type
	for i in 0 ..< len(machine.kind) {
		if machine.kind[i] != .Product do continue
		prod := stored_type_fold_at(machine, i)
		if prod == nil && i < len(machine.types) do prod = machine.types[i]
		if prod == nil do continue
		ps, ok := &prod^.(Scope_Type)
		if !ok do continue
		for j in 0 ..< len(ps.kind) {
			if ps.kind[j] != .Expand do continue
			t := stored_constraint_fold_at(ps, j)
			if t == nil && j < len(ps.constraints) do t = ps.constraints[j]
			if t == nil do continue
			out = out == nil ? t : new_type(Or_Type{out, t})
		}
	}
	return out
}

// stamp_cover_tail_domain infers the domain of a BARE trailing `...(r)` in a
// scope cover from the scrutinee's declared grammar: the rest of a run of
// `Array{T}` is an `Array{T}`, so the capture r carries the grammar tail exactly
// as if `...Array{T}:(r)` had been written. Purely additive — a WRITTEN tail
// constraint is never touched.
stamp_cover_tail_domain :: proc(match: ^Type, target: ^Type) {
	if match == nil || target == nil do return
	ms, is_scope := &match^.(Scope_Type)
	if !is_scope do return
	idx := -1
	for i in 0 ..< len(ms.kind) do if ms.kind[i] == .Expand do idx = i
	if idx < 0 || idx >= len(ms.constraint_folds) do return
	if idx < len(ms.constraints) && ms.constraints[idx] != nil do return
	if ms.constraint_folds[idx] != nil do return
	cf: ^Type
	if v, is_m := target^.(Mention_Type); is_m && v.match_scope != nil && v.match_index >= 0 {
		cf = stored_constraint_fold_at(v.match_scope, v.match_index)
	}
	if cf == nil do return
	machine, ok := &cf^.(Scope_Type)
	if !ok do return
	if tail := grammar_tail_domain(machine); tail != nil {
		ms.constraint_folds[idx] = tail
	}
}

// pattern_home_scope: the scope the pattern's scrutinee lives in — the pattern's
// own world in WHICHEVER materialization is being folded (a clone's target mention
// was repointed to the clone). nil when the scrutinee is not a direct binding.
pattern_home_scope :: proc(p: ^Pattern_Type) -> ^Scope_Type {
	if p.target == nil do return nil
	#partial switch v in p.target^ {
	case Mention_Type:
		return v.match_scope
	case Reference_Type:
		if v.reference != nil do return v.reference.match_scope
	}
	return nil
}

// pattern_recursive_carve reports whether `carve` re-enters the scope this
// pattern belongs to — the self-recursion of a recursive collapse. The carve
// sources the CANONICAL scope while the folded pattern may live in a clone, so
// the comparison reads through the clone chain (scope_canon); the direct
// production-node check covers a pattern whose scrutinee is not a plain binding.
pattern_recursive_carve :: proc(carve: ^Carve_Type, home: ^Scope_Type, pattern: ^Type) -> bool {
	src := collapse_source(carve.source)
	if src == nil do return false
	if home != nil && scope_canon(home) == scope_canon(src) do return true
	for i in 0 ..< len(src.kind) {
		if src.kind[i] == .Product && src.types[i] == pattern do return true
	}
	return false
}

// product_is_pure_tail: the branch product IS the recursive collapse itself
// (`-> f{…}!`), so its value equals the pattern's eventual exit value and the
// pattern fold may skip it. Anything WRAPPING the recursion (`n * f{…}!`, a
// scope of collapses) contributes value of its own and cannot be skipped.
product_is_pure_tail :: proc(product: ^Type, home: ^Scope_Type, pattern: ^Type) -> bool {
	if product == nil do return false
	ex, ok := product^.(Execute_Type)
	if !ok do return false
	cur := follow(ex.target)
	if cur == nil do return false
	cv, c_ok := &cur^.(Carve_Type)
	if !c_ok do return false
	return pattern_recursive_carve(cv, home, pattern)
}

// pattern_rebound_sites collects the binding sites a RECURSIVE carve inside any
// branch product rebinds (`f{n->n-1, acc->acc+n}` rebinds n and acc). The sites
// are anchored on the pattern's HOME scope — the clone the product's mentions
// actually resolve against — mapping each reference through carve_ref_index
// (the refs themselves still point at the canonical scope).
pattern_rebound_sites :: proc(p: ^Pattern_Type, pattern: ^Type) -> [dynamic]Binding_Site {
	sites: [dynamic]Binding_Site
	home := pattern_home_scope(p)
	if home == nil do return sites
	for branch in p.branches {
		collect_rebound_sites(branch.product, home, pattern, &sites)
	}
	return sites
}

// collect_rebound_sites walks the same structural backbone as contains_open_unfold,
// appending the override targets of every carve that re-enters the pattern's scope.
collect_rebound_sites :: proc(t: ^Type, home: ^Scope_Type, pattern: ^Type, sites: ^[dynamic]Binding_Site) {
	if t == nil do return
	#partial switch &v in t^ {
	case Execute_Type:
		collect_rebound_sites(v.target, home, pattern, sites)
	case Carve_Type:
		if pattern_recursive_carve(&v, home, pattern) {
			for ref in v.references {
				idx := carve_ref_index(ref, home)
				if idx < 0 || idx >= len(home.types) do continue
				append(sites, Binding_Site{home, idx})
			}
		}
		collect_rebound_sites(v.source, home, pattern, sites)
		for ov in v.types do collect_rebound_sites(ov, home, pattern, sites)
	case Compose_Type:
		collect_rebound_sites(v.left, home, pattern, sites)
		collect_rebound_sites(v.right, home, pattern, sites)
	case Or_Type:
		collect_rebound_sites(v.left, home, pattern, sites)
		collect_rebound_sites(v.right, home, pattern, sites)
	case And_Type:
		collect_rebound_sites(v.left, home, pattern, sites)
		collect_rebound_sites(v.right, home, pattern, sites)
	case Negate_Type:
		collect_rebound_sites(v.operand, home, pattern, sites)
	case Range_Type:
		collect_rebound_sites(v.left, home, pattern, sites)
		collect_rebound_sites(v.right, home, pattern, sites)
	case Cast_Type:
		collect_rebound_sites(v.value, home, pattern, sites)
	case Scope_Type:
		for ft in v.types do collect_rebound_sites(ft, home, pattern, sites)
	case Pattern_Type:
		collect_rebound_sites(v.target, home, pattern, sites)
		for branch in v.branches do collect_rebound_sites(branch.product, home, pattern, sites)
	}
}

// install_rebound_shadow overrides each rebound site with Unknown so its mention
// folds symbolic. A site ALREADY overridden is skipped — the branch-cover
// refinement (installed just before) or an outer frame's narrowing wins, which is
// what keeps the sound `0 -> n` exit folding to 0. Undone by
// uninstall_fold_refinement like any override batch.
install_rebound_shadow :: proc(sites: []Binding_Site) -> [dynamic]Fold_Override_Save {
	saved: [dynamic]Fold_Override_Save
	for site in sites {
		if _, present := site.scope.refine_overrides[site.index]; present do continue
		append(&saved, Fold_Override_Save{site, nil, false})
		site.scope.refine_overrides[site.index] = new_type(Unknown_Type{})
	}
	return saved
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
// refold (default true, analyze path) is threaded to repoint; reduce passes false so
// the substitution never re-enters the analyzer-only fold layer (see repoint).
fired_product :: proc(branch: Pattern_Branch, scrutinee: ^Type, refold := true) -> ^Type {
	if branch.match == nil || branch.product == nil || scrutinee == nil do return branch.product
	cover, c_ok := &branch.match^.(Scope_Type)
	if !c_ok do return branch.product
	res := follow(scrutinee)
	if res == nil do return branch.product
	pieces, p_ok := &res^.(Scope_Type)
	if !p_ok do return branch.product
	sub := destructure_cover(cover, pieces)
	if sub == nil do return branch.product
	return repoint(branch.product, cover, sub, refold)
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
	ft := pattern_target_coverage(p)
	// A match/target that is not a static set (e.g. `2>2`) can't prove coverage and
	// must not reach satisfy_root with a nil.
	if fc == nil || ft == nil do return false
	return satisfy_root(fc, ft)
}

// pattern_target_coverage: the set of values the scrutinee can take — its
// DECLARED domain (constraint side) when it is a LEXICALLY MENTIONED colored
// binding, else its value fold. A lexical binding is the carve-parameter surface:
// any carve of the enclosing scope may rebind it to anything in its color, so
// exhaustiveness is a contract over the DOMAIN (`Array{T}:source` must be covered
// for every list, not just for source's current default). A property reference
// (`C.x`) reads an already-MATERIALIZED value — its fold is what it is. A grammar
// machine (a scope whose value-set is its productions' union — the producer rule)
// expands to that union so each production is proven against the covers.
pattern_target_coverage :: proc(p: Pattern_Type) -> ^Type {
	cf: ^Type
	if p.target != nil {
		if v, is_mention := p.target^.(Mention_Type); is_mention {
			if v.match_scope != nil && v.match_index >= 0 {
				cf = stored_constraint_fold_at(v.match_scope, v.match_index)
			}
		}
	}
	if cf == nil do return fold_type(p.target)
	if s, ok := &cf^.(Scope_Type); ok {
		if prod_union := scope_production_union(s); prod_union != nil do return prod_union
	}
	return cf
}

// scope_production_union: the Or of a machine scope's production sets (the
// value-side mirror of satisfy_root's producer-only rule). nil when the scope
// carries no production.
scope_production_union :: proc(s: ^Scope_Type) -> ^Type {
	out: ^Type
	for i in 0 ..< len(s.kind) {
		if s.kind[i] != .Product do continue
		prod := stored_constraint_fold_at(s, i)
		if prod == nil do prod = stored_type_fold_at(s, i)
		if prod == nil do prod = s.types[i]
		if prod == nil do continue
		out = out == nil ? prod : new_type(Or_Type{out, prod})
	}
	return out
}

describe_pattern :: proc(p: Pattern_Type) -> string {
	return fmt.tprintf("a pattern with %d branch(es)", len(p.branches))
}
