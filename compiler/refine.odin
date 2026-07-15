package compiler

import "core:fmt"
import "core:strings"

// refine.odin — pattern-branch refinement.
//
// When a pattern branch fires, its cover M is logically ADDED to the scrutinee e:
// inside that branch's product, we know `e & M` (and `e & ~Mj` for every earlier
// branch j that did NOT fire). refine() pushes that conjunction through the
// structure of e down to the free fixed-point leaves (??i), and reports the
// narrowed domain each leaf must take inside the product.
//
// This is NOT a pass. It is called from two places, both scoped to one branch:
//   - reduce_pattern (reduce.odin): records the narrowed domains on the branch
//     product for the backend / for observability.
//   - walk_pattern (analyze.odin): installs the narrowed domains as binding
//     OVERRIDES while the branch product is walked + proven, so a constraint proof
//     inside the product (a carve like `f{n -> n-1}`) resolves the scrutinee binding
//     to its refined domain instead of its declared type. See install_branch_refinement.
// Outside a pattern branch, nothing refines.
//
// The whole engine is one law: push `&` through a constructor toward the leaves,
// reusing fold_type for the actual intersection at each leaf. `~` is De Morgan
// (fold already handles it); a positive add is `& M`, a negative one is `& ~M` —
// the engine treats them identically. When a node can't be inverted (both sides
// free, an opaque operator), it contributes no refinement: refine returns [].
// Correct always, complete when it can be — arbitrary expression complexity never
// breaks it, it only stops narrowing where it can't see through.

// One leaf-level narrowing: the free fixed point and the domain it must take.
Refinement :: struct {
	leaf:   ^Type, // the free fixed point (Unknown / Mention / Reference / Cast atom)
	domain: ^Type, // narrowed domain = fold_type(And_Type{ current_leaf_domain, pushed })
}

// refine pushes `add` (the cover being conjoined) through e toward its free leaves.
// Returns the refinements reachable through invertible structure; [] when none.
refine :: proc(e: ^Type, add: ^Type) -> []Refinement {
	if e == nil || add == nil do return {}

	// A refinable leaf — a free fixed point (`??`) OR a named binding (a Mention /
	// Reference resolving to a definition site). The `&` lands here: intersect the
	// leaf's current domain with the pushed add at the interval level. A bare `??`
	// has the unbounded top; a colored binding (`u64:n`) has its declared domain, so
	// `n ? {0->…, ->…}` narrows n to `~0 & u64` in the default branch.
	if is_refinable_leaf(e) {
		dom := domain_intersect(leaf_domain(e), add)
		if dom == nil do return {}
		out := make([]Refinement, 1)
		out[0] = Refinement{leaf = e, domain = dom}
		return out
	}

	#partial switch v in e^ {
	case Compose_Type:
		return refine_compose(v, add)
	case Or_Type:
		// (a | b) & V  =  (a & V) | (b & V): both sides see the same add.
		return concat_refinements(refine(v.left, add), refine(v.right, add))
	case And_Type:
		// (a & b) & V: each side's add is widened by the other side's value.
		return concat_refinements(
			refine(v.left, domain_intersect(v.right, add)),
			refine(v.right, domain_intersect(v.left, add)),
		)
	case Negate_Type:
		// ~a & V  →  a & ~V  (De Morgan; fold normalizes the complement).
		return refine(v.operand, new_type(Negate_Type{add}))
	}
	// Structural forms (carve / collapse / property / reference) never reach here in
	// the real pipeline: reduce_value resolves them to their underlying symbolic value
	// BEFORE reduce_pattern sees the target, so a property `arr.b` of `b -> n+1`
	// arrives already as the affine tree `??0 + 1`. The reducer collapsing structure
	// up front IS the structural inversion. A form that survives reduction is opaque
	// and contributes no refinement — correct, just not narrowing.
	return {}
}

// is_refinable_leaf reports whether refine should treat `e` as a leaf: a free fixed
// point, or a named binding (Mention/Reference with a definition site) whose domain
// a branch can narrow. Both stop the `&` push and yield a Refinement.
is_refinable_leaf :: proc(e: ^Type) -> bool {
	if e == nil do return false
	if is_fixed_point(e) do return true
	#partial switch v in e^ {
	case Mention_Type:
		return v.match_scope != nil && v.match_index >= 0
	case Reference_Type:
		return v.reference != nil && v.reference.match_scope != nil && v.reference.match_index >= 0
	}
	return false
}

// install_branch_refinement computes the scrutinee narrowing for one branch and
// installs it as binding overrides on the analyzer, returning the keys it added so
// uninstall can remove exactly those. `this_cover` is the branch's positive cover
// (nil for a default branch); `priors` are the covers of all earlier branches,
// negated into the conjunction. Only refinements that map back to a concrete binding
// site are installed; a leaf with no binding (a bare anonymous `??`) is skipped.
install_branch_refinement :: proc(
	a: ^Analyzer,
	target: ^Type,
	this_cover: ^Type,
	priors: []^Type,
) -> []Binding_Site {
	add := branch_add_from_covers(this_cover, priors)
	if add == nil do return {}
	refs := refine(target, add)
	if len(refs) == 0 do return {}

	installed := make([dynamic]Binding_Site, 0, len(refs))
	for r in refs {
		site, ok := leaf_binding_site(r.leaf)
		if !ok do continue
		// Don't clobber an outer (nested-pattern) override already on this site; the
		// inner branch only narrows further. Compose by intersecting if present.
		if existing, present := site.scope.refine_overrides[site.index]; present {
			site.scope.refine_overrides[site.index] = domain_intersect(existing, r.domain)
		} else {
			site.scope.refine_overrides[site.index] = r.domain
			a.active_override_sites[site] = true
			append(&installed, site)
		}
	}
	return installed[:]
}

// uninstall_branch_refinement removes exactly the overrides install added.
uninstall_branch_refinement :: proc(a: ^Analyzer, installed: []Binding_Site) {
	for site in installed {
		delete_key(&site.scope.refine_overrides, site.index)
		delete_key(&a.active_override_sites, site)
	}
}

// install_fold_refinement narrows the scrutinee's binding sites to what branch k
// of the pattern implies (`Mk & ~M(k-1) & … & ~M0`), for the duration of ONE fold
// of that branch's product. Unlike install_branch_refinement it needs NO analyzer:
// it writes the owning scopes' refine_overrides directly and returns the exact
// prior state, so it is callable from any phase (walk, recheck, or a reduce-side
// fold reuse). Restore with uninstall_fold_refinement, in the same expression.
Fold_Override_Save :: struct {
	site:    Binding_Site,
	value:   ^Type,
	present: bool,
}
install_fold_refinement :: proc(
	target: ^Type,
	branches: []Pattern_Branch,
	k: int,
) -> [dynamic]Fold_Override_Save {
	saved: [dynamic]Fold_Override_Save
	add := branch_refinement_add(branches, k)
	if add == nil do return saved
	refs := refine(target, add)
	for r in refs {
		site, ok := leaf_binding_site(r.leaf)
		if !ok do continue
		prev, present := site.scope.refine_overrides[site.index]
		append(&saved, Fold_Override_Save{site, prev, present})
		if present {
			// An outer override (walk-time branch proof) already narrows this site;
			// the branch fold only narrows further.
			site.scope.refine_overrides[site.index] = domain_intersect(prev, r.domain)
		} else {
			site.scope.refine_overrides[site.index] = r.domain
		}
	}
	return saved
}

// uninstall_fold_refinement restores exactly what install_fold_refinement changed,
// in reverse order so nested installs on the same site unwind correctly.
uninstall_fold_refinement :: proc(saved: [dynamic]Fold_Override_Save) {
	for i := len(saved) - 1; i >= 0; i -= 1 {
		s := saved[i]
		if s.present {
			s.site.scope.refine_overrides[s.site.index] = s.value
		} else {
			delete_key(&s.site.scope.refine_overrides, s.site.index)
		}
	}
	delete(saved)
}

// branch_add_from_covers builds `this_cover & ~prior0 & … & ~priorN`. A default
// branch (nil this_cover) starts from the unbounded integer top and only negates the
// priors. nil when there is nothing to add (no cover, no priors).
branch_add_from_covers :: proc(this_cover: ^Type, priors: []^Type) -> ^Type {
	add: ^Type
	if this_cover != nil {
		add = this_cover
	} else if len(priors) > 0 {
		add = integer_top()
	} else {
		return nil
	}
	for p in priors {
		if p == nil do continue
		neg := new(Type)
		neg^ = Negate_Type{p}
		conj := new(Type)
		conj^ = And_Type{add, neg}
		add = conj
	}
	return add
}

// leaf_binding_site maps a refined fixed-point leaf to the (scope, index) of the
// binding it names, so an override can be keyed on it. Follows a Mention/Reference
// to its definition site; a bare anonymous Unknown has no site (ok = false).
leaf_binding_site :: proc(leaf: ^Type) -> (Binding_Site, bool) {
	cur := leaf
	for cur != nil {
		#partial switch v in cur^ {
		case Mention_Type:
			if v.match_scope != nil && v.match_index >= 0 {
				return Binding_Site{v.match_scope, v.match_index}, true
			}
			return {}, false
		case Reference_Type:
			if v.reference != nil && v.reference.match_scope != nil && v.reference.match_index >= 0 {
				return Binding_Site{v.reference.match_scope, v.reference.match_index}, true
			}
			return {}, false
		case Cast_Type:
			cur = v.value
			continue
		}
		return {}, false
	}
	return {}, false
}

// contains_fixed_point reports whether a reduced value carries a free fixed point
// anywhere in its structure. A target free of fixed points has a decidable cover
// membership, so reduce_pattern can pick a branch statically; one that carries a
// `??` stays symbolic. Walks the structural backbone reached by reduction.
contains_fixed_point :: proc(t: ^Type) -> bool {
	if t == nil do return false
	if is_fixed_point(t) do return true
	#partial switch v in t^ {
	case Compose_Type:
		return contains_fixed_point(v.left) || contains_fixed_point(v.right)
	case And_Type:
		return contains_fixed_point(v.left) || contains_fixed_point(v.right)
	case Or_Type:
		return contains_fixed_point(v.left) || contains_fixed_point(v.right)
	case Negate_Type:
		return contains_fixed_point(v.operand)
	case Range_Type:
		return contains_fixed_point(v.left) || contains_fixed_point(v.right)
	case Cast_Type:
		// A composite-source cast (width wrapper) is symbolic iff its source is; a bare
		// `??::T` atom was already caught by is_fixed_point above.
		return contains_fixed_point(v.value)
	case Pattern_Type:
		if contains_fixed_point(v.target) do return true
		for branch in v.branches {
			if contains_fixed_point(branch.product) do return true
		}
		return false
	}
	return false
}

// refine_compose handles `left <op> right` when exactly one side is free: push the
// add through the operator's inverse onto the free side. Both-free or both-concrete
// → no refinement (under-determined / nothing to learn).
refine_compose :: proc(c: Compose_Type, add: ^Type) -> []Refinement {
	// Exactly one side may carry the (single) variable being narrowed; the other must
	// be a concrete constant for the inverse to exist. Both-variable / both-constant
	// (or two distinct variables on one side) → under-determined, no refinement.
	left_var := contains_refinable(c.left)
	right_var := contains_refinable(c.right)
	if left_var == right_var do return {} // both or neither: bail

	free := left_var ? c.left : c.right
	konst := left_var ? c.right : c.left

	inv := invert_operand(c.operator, add, konst, left_var)
	if inv == nil do return {}
	return refine(free, inv)
}

// contains_refinable reports whether an expression carries a refinable leaf anywhere
// (so refine_compose can tell the variable side from the constant side).
contains_refinable :: proc(t: ^Type) -> bool {
	if t == nil do return false
	if is_refinable_leaf(t) do return true
	#partial switch v in t^ {
	case Compose_Type:
		return contains_refinable(v.left) || contains_refinable(v.right)
	case And_Type:
		return contains_refinable(v.left) || contains_refinable(v.right)
	case Or_Type:
		return contains_refinable(v.left) || contains_refinable(v.right)
	case Negate_Type:
		return contains_refinable(v.operand)
	case Cast_Type:
		return contains_refinable(v.value)
	}
	return false
}

// invert_operand computes the add to push onto the free operand of `free <op> konst`
// (or `konst <op> free` when !free_is_left), given the add `V` on the whole node.
//   a + k ∈ V  → a ∈ V - k        a - k ∈ V → a ∈ V + k       k - a ∈ V → a ∈ k - V
//   a * k ∈ V  → a ∈ V / k        a << k ∈ V → a ∈ V >> k (mask)   ...
// Returns nil when the operator has no usable inverse here (→ no refinement).
// The whole step works in the integer domain (the only one with affine structure);
// V is folded to its envelope, k must be a concrete integer.
invert_operand :: proc(op: Operator_Kind, V, konst: ^Type, free_is_left: bool) -> ^Type {
	vt := fold_type_integer(V)
	if vt == nil do return nil
	vi := vt^.(Integer_Type)

	kt := fold_type_integer(konst)
	if kt == nil do return nil
	ki := kt^.(Integer_Type)
	if !int_is_concrete(ki) do return nil // a symbolic side carries no usable inverse
	k := int_value(ki)

	segs := vi.integer_intervals
	out: []Integer_Interval
	switch op {
	case .Add:
		// a + k ∈ V  →  a ∈ V - k   (commutative, side-independent)
		out = integer_intervals_shift(segs, -k)
	case .Subtract:
		if free_is_left {
			out = integer_intervals_shift(segs, k) // a - k ∈ V → a ∈ V + k
		} else {
			// k - a ∈ V → a ∈ k - V  = -(V) + k  (ARITHMETIC negation, not set ~)
			out = integer_intervals_shift(integer_intervals_arith_negate(segs), k)
		}
	case .Multiply:
		// a * k ∈ V  →  a ∈ V / k   (commutative). k==0 is a special case.
		if k == 0 {
			if integer_intervals_contains(segs, 0) do return nil // 0 ∈ V: no constraint
			out = {} // 0 ∉ V: branch infeasible, empty set
		} else {
			out = integer_intervals_div_const(segs, k)
		}
	case .LShift:
		// a << k ∈ V  →  a ∈ V >> k. Only meaningful when the free side is shifted.
		if !free_is_left || k < 0 do return nil
		out = integer_intervals_shr_const(segs, k)
	case .RShift:
		// a >> k ∈ V  →  a ∈ V << k, widened by the k low bits dropped on the way out:
		// a ∈ [Vlo<<k , (Vhi<<k) + (2^k - 1)].
		if !free_is_left || k < 0 do return nil
		out = integer_intervals_shl_widen(segs, k)
	case .Divide, .Mod, .Equal, .Less, .Greater, .NotEqual, .LessEqual,
	     .GreaterEqual, .And, .Or, .Xor, .Not, .BitAnd, .BitOr, .BitNot, .Cast:
		return nil // no usable inverse here
	}

	r := new(Type)
	r^ = Integer_Type{out, default_for_integer_intervals(out)}
	return r
}

// integer_intervals_shift translates every interval by d (nil bounds stay nil).
integer_intervals_shift :: proc(segs: []Integer_Interval, d: i128) -> []Integer_Interval {
	out := make([]Integer_Interval, len(segs))
	for s, i in segs {
		lo: Maybe(i128) = nil
		hi: Maybe(i128) = nil
		if v, ok := s.lo.(i128); ok do lo = v + d
		if v, ok := s.hi.(i128); ok do hi = v + d
		out[i] = Integer_Interval{lo, hi}
	}
	return out
}

// integer_intervals_arith_negate maps each interval [lo,hi] to [-hi,-lo] (the
// arithmetic image of -x), distinct from integer_intervals_negate (set complement).
integer_intervals_arith_negate :: proc(segs: []Integer_Interval) -> []Integer_Interval {
	out := make([]Integer_Interval, len(segs))
	for s, i in segs {
		lo: Maybe(i128) = nil
		hi: Maybe(i128) = nil
		if v, ok := s.hi.(i128); ok do lo = -v
		if v, ok := s.lo.(i128); ok do hi = -v
		out[i] = Integer_Interval{lo, hi}
	}
	return out
}

// integer_intervals_div_const divides every interval by a nonzero constant k.
// The exact preimage is only the multiples of k, but the smallest interval cover
// is [ceil(lo/k), floor(hi/k)] (bounds swapped when k<0). A correct over-approx.
integer_intervals_div_const :: proc(segs: []Integer_Interval, k: i128) -> []Integer_Interval {
	out := make([dynamic]Integer_Interval)
	for s in segs {
		lo: Maybe(i128) = nil
		hi: Maybe(i128) = nil
		if v, ok := s.lo.(i128); ok do lo = k > 0 ? div_ceil(v, k) : div_floor(v, k)
		if v, ok := s.hi.(i128); ok do hi = k > 0 ? div_floor(v, k) : div_ceil(v, k)
		if k < 0 do lo, hi = hi, lo // negative divisor flips the bounds
		if maybe_le(lo, hi) do append(&out, Integer_Interval{lo, hi})
	}
	return out[:]
}

// integer_intervals_shr_const: a << k ∈ V → a ∈ V >> k, the exact preimage being
// [ceil(lo/2^k), floor(hi/2^k)] (a<<k is monotone, k≥0).
integer_intervals_shr_const :: proc(segs: []Integer_Interval, k: i128) -> []Integer_Interval {
	return integer_intervals_div_const(segs, i128(1) << uint(k))
}

// integer_intervals_shl_widen: a >> k ∈ V → a ∈ [lo<<k , (hi<<k)+(2^k-1)]; the k
// low bits of a are lost by >>k, so each result value preimages a 2^k-wide band.
integer_intervals_shl_widen :: proc(segs: []Integer_Interval, k: i128) -> []Integer_Interval {
	mask := (i128(1) << uint(k)) - 1
	out := make([]Integer_Interval, len(segs))
	for s, i in segs {
		lo: Maybe(i128) = nil
		hi: Maybe(i128) = nil
		if v, ok := s.lo.(i128); ok do lo = v << uint(k)
		if v, ok := s.hi.(i128); ok do hi = (v << uint(k)) + mask
		out[i] = Integer_Interval{lo, hi}
	}
	return out
}

div_floor :: #force_inline proc(a, b: i128) -> i128 {
	q := a / b
	if (a % b != 0) && ((a < 0) != (b < 0)) do q -= 1
	return q
}

div_ceil :: #force_inline proc(a, b: i128) -> i128 {
	q := a / b
	if (a % b != 0) && ((a < 0) == (b < 0)) do q += 1
	return q
}

// leaf_domain returns the current domain of a free fixed point, to be intersected
// with the pushed add. A typed `??::T` folds to T's envelope (e.g. `0..255`); an
// untyped `??` has no static bound, so its domain is the unbounded integer top.
leaf_domain :: proc(leaf: ^Type) -> ^Type {
	if site, ok := leaf_binding_site(leaf); ok {
		// An active override (a nested-pattern narrowing already in effect) is the
		// current domain; refining on top of it composes correctly.
		if ov := refine_override_for(site.scope, site.index); ov != nil do return ov
		// A colored binding (`u64:n`) carries its domain on the CONSTRAINT side; read
		// the cached constraint_fold directly rather than folding the Mention (which
		// follows `types[]` to the value/default, e.g. 0, not the declared u64).
		s, i := site.scope, site.index
		if i < len(s.constraint_folds) && s.constraint_folds[i] != nil {
			if it := fold_type_integer(s.constraint_folds[i]); it != nil {
				if iv, ok := it^.(Integer_Type); ok && len(iv.integer_intervals) > 0 do return it
			}
		}
	}
	// Fall back to the value-side domain for a free `??::T` (e.g. `0..255`).
	if it := fold_type_integer(leaf); it != nil {
		if iv, ok := it^.(Integer_Type); ok && !int_is_concrete(iv) do return it
	}
	// An untyped `??` has no static bound: the unbounded integer top.
	return integer_top()
}

// domain_intersect intersects two integer domains at the interval level, returning
// the raw narrowed Integer_Type (not a meta producer scope, unlike fold_type's `&`).
// nil when either side isn't an integer domain or the result is empty.
domain_intersect :: proc(a, b: ^Type) -> ^Type {
	at := fold_type_integer(a)
	bt := fold_type_integer(b)
	if at == nil || bt == nil do return nil
	res := integer_type_intersect(at^.(Integer_Type), bt^.(Integer_Type))
	if len(res.integer_intervals) == 0 do return nil
	r := new(Type)
	r^ = res
	return r
}

// integer_top is the unconstrained integer domain (-inf..+inf).
integer_top :: proc() -> ^Type {
	segs := make([]Integer_Interval, 1)
	segs[0] = Integer_Interval{nil, nil}
	r := new(Type)
	r^ = Integer_Type{segs, nil}
	return r
}

// write_branch_refinements renders the refinements recorded for a branch product
// as `[??N=domain, …]` (nothing when there are none). Reads the per-reduce map on
// the current reducer; this is what makes refinements observable to the tests.
write_branch_refinements :: proc(b: ^strings.Builder, product: ^Type) -> () {
	reducer := current_reducer()
	if reducer == nil do return
	refs, ok := reducer.refinements[product]
	if !ok || len(refs) == 0 do return
	strings.write_byte(b, '[')
	for r, i in refs {
		if i > 0 do strings.write_string(b, ", ")
		fmt.sbprintf(b, "??%d=", fixedpoint_id(r.leaf))
		write_value(b, r.domain)
	}
	strings.write_byte(b, ']')
}

concat_refinements :: proc(a, b: []Refinement) -> []Refinement {
	if len(a) == 0 do return b
	if len(b) == 0 do return a
	out := make([]Refinement, len(a) + len(b))
	copy(out[:], a)
	copy(out[len(a):], b)
	return out
}
