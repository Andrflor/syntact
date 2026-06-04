package compiler

import "core:fmt"
import "core:slice"
import "core:strings"

// ============================================================================
// SYMBOLIC FIXED-POINT REDUCTION
//
// Syntact execution is structural reduction. A program reduces to the value its
// root scope produces. When that value is fully determined at compile time it is
// a concrete singleton and reduction is just evaluation. But a program may depend
// on UNKNOWNS — `??` (an external the linker resolves: argc, an env value, …).
// Each `??` is a FIXED POINT: a free variable the reducer cannot evaluate, only
// carry. Reduction then becomes PARTIAL EVALUATION: fold everything concrete,
// keep the fixed points symbolic, and emit the operation-minimal expression so
// the runtime does as little as possible.
//
// THE RULE, applied to every node:
//   1. Look at its fold_type (already computed by the analyzer, maximally folded).
//   2. If that fold is a CONCRETE SINGLETON, it already IS the reduction of what
//      the node points to — return it, no evaluation.
//   3. Otherwise a fixed point survives inside it: do NOT use the fold as the
//      result. Recurse into the node's VALUE (the raw expression) and partially
//      evaluate it, isolating the `??` so the minimum of work is left for runtime.
//
// `((a*2)+3-4)*3` with `a -> ??:u8` is not a singleton, so we descend into the
// value, normalize the arithmetic into a canonical polynomial over the fixed
// point `a`, and emit `6 * a - 3` — one multiply, one subtract at runtime.
//
// The canonical form is a SUM OF MONOMIALS (a multivariate polynomial over the
// symbols): map monomial -> integer coefficient, plus a constant term. `+ - *`
// are the ring operations; any symbol reached through a non-polynomial operator
// (`/`, `%`, a comparison, a bit op, a collapse that cannot resolve, …) becomes
// an OPAQUE atomic symbol — still combinable linearly (`(a/b)+(a/b)` -> `2*(a/b)`)
// but never expanded. The polynomial is then rendered back to a Compose_Type tree
// chosen to minimize runtime operations (constant last, unit coefficients elided).
// ============================================================================

// reduce collapses a scope through its Product binding. The product's fold_type,
// if a concrete singleton, is the answer outright; otherwise we descend into the
// product's value and reduce it symbolically.
reduce :: proc(scope: ^Scope_Type) -> ^Type {
	// Fresh per-reduction DAG bookkeeping, allocated in the CURRENT context (the
	// test harness runs each case in its own arena that is destroyed afterward, so a
	// map carried over from a previous reduce would dangle). Reset every call.
	dag_reset()
	for i := 0; i < len(scope.kind); i += 1 {
		if scope.kind[i] == .Product {
			if i < len(scope.type_folds) {
				if shortcut := singleton_shortcut(scope.type_folds[i]); shortcut != nil {
					return shortcut
				}
			}
			return reduce_value(scope.values[i])
		}
	}
	return nil
}

// singleton_shortcut returns the fold itself when it is a concrete singleton (a
// value already fully reduced), else nil — signalling "descend into the value".
singleton_shortcut :: proc(tf: ^Type) -> ^Type {
	if tf == nil do return nil
	if fold_is_concrete_value(tf) do return tf
	return nil
}

// reduce_value is the recursive partial evaluator. It returns a reduced ^Type:
// a concrete value when everything resolved, or a symbolic expression (a
// normalized Compose tree over the surviving fixed points) otherwise.
reduce_value :: proc(value: ^Type) -> ^Type {
	if value == nil do return nil
	switch &v in value^ {
	case Execute_Type:
		return reduce_value(execute(v))
	case Compose_Type:
		return reduce_compose(v)
	case Cast_Type:
		// A cast over a concrete source has its reinterpreted value cached; a cast
		// over a fixed point (`??::u8`) stays symbolic (it IS a fixed point).
		if v.type_fold != nil && fold_is_concrete_value(v.type_fold) {
			return reduce_value(v.type_fold)
		}
		// A bare `??::u8` is an ATOM — the unknown itself; carry it as is. But a cast
		// over a COMPOSITE source (`(a+b)::u8`) is a WRAPPER: reduce the inner
		// expression and re-wrap, so the wrapped terms (and the cast) survive instead
		// of collapsing the whole node to one opaque `??`.
		if cast_is_atom(value) do return value
		inner := reduce_value(v.value)
		if inner == v.value do return value
		wrapped := new(Type)
		wrapped^ = Cast_Type{inner, v.target, nil}
		return wrapped
	case Carve_Type:
		return reduce_carve(v)
	case Mention_Type:
		return reduce_mention(v, value)
	case Reference_Type:
		return reduce_reference(v, value)
	case Scope_Type:
		return reduce_scope(&v)
	case Integer_Type:
		return value
	case Float_Type:
		return value
	case String_Type:
		return value
	case Bool_Type:
		return value
	case Range_Type:
		return value
	case None_Type:
		return value
	case Invalid_Type:
		return value
	case Unknown_Type:
		// A bare fixed point: nothing to evaluate, carry it as is.
		return value
	case Or_Type:
		return reduce_set_op(value)
	case And_Type:
		return reduce_set_op(value)
	case Negate_Type:
		return reduce_set_op(value)
	case Pattern_Type:
		return reduce_pattern(v)
	}
	return value
}

// reduce_mention follows a name to its binding and reduces the bound value
// through. If the value bottoms out in a fixed point we DON'T stop at this alias —
// we follow to the ATOMIC `??` node (follow_to_fixedpoint) and return THAT, so
// every route to the same unknown converges on one node and thus one `??N` index
// (`c -> 2*n`, `e -> n` both reach n's `??`, so `c + e` collects). Otherwise we
// reduce the bound value.
reduce_mention :: proc(v: Mention_Type, node: ^Type) -> ^Type {
	if v.match_scope == nil || v.match_index < 0 do return node
	bound := v.match_scope.values[v.match_index]
	if is_fixed_point(bound) do return follow_to_fixedpoint(bound)
	return reduce_value(bound)
}

// reduce_reference mirrors reduce_mention for ordinal/property references,
// honoring a carve override in the target (a carved field reads the override).
reduce_reference :: proc(v: Reference_Type, node: ^Type) -> ^Type {
	ref := v.reference
	if ref == nil || ref.match_scope == nil || ref.match_index < 0 do return node
	if v.target != nil {
		cur := follow(v.target)
		if cur != nil {
			#partial switch &cv in cur^ {
			case Carve_Type:
				for i := 0; i < len(cv.references); i += 1 {
					if cv.references[i].match_index == ref.match_index {
						if is_fixed_point(cv.values[i]) do return follow_to_fixedpoint(cv.values[i])
						return reduce_value(cv.values[i])
					}
				}
			}
		}
	}
	target := ref.match_scope.values[ref.match_index]
	if is_fixed_point(target) do return follow_to_fixedpoint(target)
	return reduce_value(target)
}

// follow_to_fixedpoint chases a fixed-point value down THROUGH aliases to the
// atomic `??` node (the Cast(Unknown)/Unknown itself), so all references to one
// unknown share that single node — and therefore one fixedpoint_id. Stops at the
// first Cast/Unknown; returns the input unchanged if no atom is found.
follow_to_fixedpoint :: proc(t: ^Type) -> ^Type {
	cur := t
	for cur != nil {
		#partial switch v in cur^ {
		case Unknown_Type:
			return cur
		case Cast_Type:
			if v.type_fold != nil && fold_is_concrete_value(v.type_fold) do return cur
			return cur // the `??::u8` atom — key the symbol by THIS node
		case Mention_Type:
			if v.match_scope != nil && v.match_index >= 0 {
				cur = v.match_scope.values[v.match_index]
				continue
			}
			return t
		case Reference_Type:
			if v.reference != nil && v.reference.match_scope != nil && v.reference.match_index >= 0 {
				cur = v.reference.match_scope.values[v.reference.match_index]
				continue
			}
			return t
		}
		return t
	}
	return t
}

// is_fixed_point reports whether `t` ultimately denotes an UNKNOWN — a value the
// reducer cannot evaluate and must carry as a free variable. A bare `??`, a cast
// of an unknown whose result did not become concrete, or a reference chasing down
// to one. Following stops at the first concrete/structural node.
is_fixed_point :: proc(t: ^Type) -> bool {
	cur := t
	for cur != nil {
		#partial switch v in cur^ {
		case Unknown_Type:
			return true
		case Cast_Type:
			// `??::u8` is a fixed point; `5::u8` (cached concrete) is not.
			if v.type_fold != nil && fold_is_concrete_value(v.type_fold) do return false
			cur = v.value
			continue
		case Mention_Type:
			if v.match_scope != nil && v.match_index >= 0 {
				cur = v.match_scope.values[v.match_index]
				continue
			}
			return false
		case Reference_Type:
			if v.reference != nil && v.reference.match_scope != nil && v.reference.match_index >= 0 {
				cur = v.reference.match_scope.values[v.reference.match_index]
				continue
			}
			return false
		}
		return false
	}
	return false
}

// cast_is_atom reports whether a Cast node is a bare `??::T` ATOM — its source,
// followed through aliases, bottoms out in the Unknown itself (the runtime input).
// Such a cast IS the fixed point and is carried unreduced. A cast whose source is a
// composite expression (`(a+b)::u8`) is NOT an atom: it is a width WRAPPER and must
// have its inner expression reduced and the cast preserved around it.
cast_is_atom :: proc(t: ^Type) -> bool {
	ct, ok := &t.(Cast_Type)
	if !ok do return false
	cur := ct.value
	for cur != nil {
		#partial switch v in cur^ {
		case Unknown_Type:
			return true
		case Mention_Type:
			if v.match_scope != nil && v.match_index >= 0 {
				cur = v.match_scope.values[v.match_index]
				continue
			}
			return false
		case Reference_Type:
			if v.reference != nil && v.reference.match_scope != nil && v.reference.match_index >= 0 {
				cur = v.reference.match_scope.values[v.reference.match_index]
				continue
			}
			return false
		case Cast_Type:
			cur = v.value
			continue
		}
		return false
	}
	return false
}

// reduce_scope reduces a non-root scope to itself with each product/value field
// reduced in place — used when a value resolves to a structural scope (e.g. a
// carve result rendered without collapse).
reduce_scope :: proc(s: ^Scope_Type) -> ^Type {
	// A pure producer scope {-> X} (single anonymous product): reduce its product.
	if len(s.kind) == 1 && s.kind[0] == .Product && s.names[0] == "" {
		// Keep the scope shape; callers (reduce) peel the root themselves.
	}
	r := new(Type)
	r^ = s^
	return r
}

// ============================================================================
// COMPOSE — the symbolic arithmetic core (DAG + constant folding + CSE).
//
// The reduced form is NOT distributed: distributing a product of sums (`(4x+2+5e)
// *14*e`) multiplies the number of terms and of multiplications, which is the
// OPPOSITE of operation-minimal. Instead we keep the author's factored structure
// and only:
//   * FOLD CONSTANTS — both operands concrete → evaluate; chains of constants
//     collapse (`5*e*14` → `70*e`, `a*2*2` with a=??*2 → `4*??`).
//   * ELIMINATE IDENTITIES — `*1`/`1*`, `+0`/`0+`, `-0`, `x-x`→0, `*0`→0.
//   * SHARE COMMON SUBEXPRESSIONS (CSE) — a structurally identical subexpression
//     is interned to a single node (`dag_intern`), so `e` (and `(…)*e`) is built
//     once and reused. The emitted DAG is what codegen wants: minimal mul/add with
//     shared rebinds, not an expanded polynomial.
// A surviving fixed point `??` is a leaf, indexed stably as `??0`, `??1`, … so two
// DISTINCT unknowns are visibly distinct (the linker resolves each separately).
// ============================================================================

// reduce_compose partially evaluates one arithmetic node: reduce the operands
// (already interned/folded), then fold constants and apply the algebraic
// identities, and finally intern the resulting node for CSE.
reduce_compose :: proc(v: Compose_Type) -> ^Type {
	left := v.left != nil ? reduce_value(v.left) : nil
	right := v.right != nil ? reduce_value(v.right) : nil

	// Constant fold: every concrete operand present → evaluate outright.
	if (v.left == nil || is_concrete_leaf(left)) && is_concrete_leaf(right) {
		if concrete := eval_concrete(v.operator, left, right); concrete != nil {
			return concrete
		}
	}

	// A binary +/- : COLLECT like terms across the whole sum chain — `k*x + m*x` →
	// `(k+m)*x`, the constant folded, even when the two sides arrive already reduced
	// from distinct references (`c + e`). This REDUCES operations (always a win); it
	// is NOT distribution — products of sums stay factored.
	if (v.operator == .Add || v.operator == .Subtract) && v.left != nil {
		if collected := collect_sum(left, right, v.operator); collected != nil {
			return collected
		}
	}

	// Algebraic simplification for the multiply chain (`(x*2)*2` → `x*4`, `5*e*14` →
	// `70*e`) and the unary minus / identities.
	if simplified := simplify_arith(v.operator, left, right); simplified != nil {
		return simplified
	}

	return dag_intern(Compose_Type{left, right, v.operator, nil})
}

// ============================================================================
// SUM COLLECTION — gather a +/- chain's like terms (k*x + m*x → (k+m)*x), fold
// the constant, and re-emit the minimal sum. This is purely ADDITIVE collection:
// it never multiplies sums out (no distribution). A "term" is (coefficient, base)
// where base is keyed by dag_key; the bare constant is collected separately.
// ============================================================================

Sum_Term :: struct {
	coeff: i128,
	base:  ^Type, // nil for the constant accumulator
}

// collect_sum reduces `left <op> right` (op is + or -) by flattening BOTH sides
// into additive terms, summing coefficients of equal bases, and rebuilding the
// minimal sum. Returns nil if nothing actually combined (so the caller keeps the
// plain interned node and we don't churn).
collect_sum :: proc(left, right: ^Type, op: Operator_Kind) -> ^Type {
	terms: [dynamic]Sum_Term
	constant: i128 = 0
	flatten_sum(left, 1, &terms, &constant)
	flatten_sum(right, op == .Subtract ? -1 : 1, &terms, &constant)

	// Merge equal bases.
	merged: [dynamic]Sum_Term
	for t in terms {
		found := false
		for &m in merged {
			if dag_key(m.base) == dag_key(t.base) {
				m.coeff += t.coeff
				found = true
				break
			}
		}
		if !found do append(&merged, t)
	}
	// Drop zero-coefficient terms.
	kept: [dynamic]Sum_Term
	for t in merged do if t.coeff != 0 do append(&kept, t)

	rebuilt := rebuild_sum(kept[:], constant)

	// Common-factor extraction (LLVM Reassociate dual): `a*b + a*c` → `a*(b+c)`.
	// Try it on the collected terms; keep it only if it lowers the op count (the
	// same cost guard). This is what makes a sum of base-products beat staying
	// expanded — gated so it never grows the expression.
	if factored := factor_common(kept[:], constant); factored != nil {
		if op_cost(factored) < op_cost(rebuilt) {
			rebuilt = factored
		}
	}

	// Commit only if the canonical form is no MORE expensive than the original
	// (operation-minimal: distributing 3*(2a-1)+5a → 11a-3 reduces the op count,
	// so it commits; a form that would grow stays as-is). The original cost is the
	// two operands plus the joining +/-; we compare node counts (Compose nodes).
	orig := op_cost(left) + op_cost(right) + 1
	if op_cost(rebuilt) > orig do return nil // would grow → keep the plain node
	// Avoid pointless churn: if nothing structurally changed, bail.
	if op_cost(rebuilt) == orig && len(kept) == count_sum_leaves(left) + count_sum_leaves(right) && constant == 0 {
		return nil
	}
	return rebuilt
}

// op_cost counts the arithmetic Compose nodes in a reduced expression — its
// operation count, used to decide whether canonicalization actually reduced work.
op_cost :: proc(node: ^Type) -> int {
	if node == nil do return 0
	#partial switch v in node^ {
	case Compose_Type:
		return 1 + op_cost(v.left) + op_cost(v.right)
	}
	return 0
}

// flatten_sum decomposes `node` SCALED BY `coeff` into additive terms appended to
// `terms`, accumulating the bare constant into `constant`. `coeff` is a full
// integer coefficient (not just a ±1 sign), which is what enables DISTRIBUTION:
// `coeff * base` recurses into `base` with the product coefficient, so
// `3 * (2a - 1)` flattens to `6·a + (-3)`. A `const * sub` product distributes the
// constant into the whole affine sub-form; a `var * var` product does NOT (it is
// kept as one opaque atom — no distribution of the non-linear part, preserving
// `(a+1)*(a+1)` and `a*a`).
flatten_sum :: proc(node: ^Type, coeff: i128, terms: ^[dynamic]Sum_Term, constant: ^i128) {
	if node == nil do return
	if c, ok := int_of(node); ok {
		constant^ += coeff * c
		return
	}
	#partial switch v in node^ {
	case Compose_Type:
		#partial switch v.operator {
		case .Add:
			flatten_sum(v.left, coeff, terms, constant)
			flatten_sum(v.right, coeff, terms, constant)
			return
		case .Subtract:
			if v.left == nil {
				flatten_sum(v.right, -coeff, terms, constant) // unary minus
			} else {
				flatten_sum(v.left, coeff, terms, constant)
				flatten_sum(v.right, -coeff, terms, constant)
			}
			return
		case .Multiply:
			// `k * sub` (constant on either side): DISTRIBUTE k into sub by
			// recursing with the product coefficient. So `3 * (2a-1)` → flatten
			// (2a-1) scaled by 3 → 6a − 3. The other factor must be the constant;
			// the variable factor (`sub`) is flattened, never multiplied out against
			// another variable.
			if c, ok := coeff_of(v.left); ok {
				flatten_sum(v.right, coeff * c, terms, constant)
				return
			}
			if c, ok := coeff_of(v.right); ok {
				flatten_sum(v.left, coeff * c, terms, constant)
				return
			}
			// var * var → an opaque atom (no distribution).
		}
	}
	append(terms, Sum_Term{coeff, node})
}

// count_sum_leaves counts the additive leaves of a +/- chain (a product or atom is
// one leaf), to detect whether collection actually reduced the term count.
count_sum_leaves :: proc(node: ^Type) -> int {
	if node == nil do return 0
	#partial switch v in node^ {
	case Compose_Type:
		if v.operator == .Add || v.operator == .Subtract {
			l := v.left != nil ? count_sum_leaves(v.left) : 0
			return l + count_sum_leaves(v.right)
		}
	}
	return 1
}

// sum_has_constant_pair reports whether both sides contribute a bare constant (so
// folding them is a genuine simplification even if term count is unchanged).
sum_has_constant_pair :: proc(left, right: ^Type) -> bool {
	return sum_constant_count(left) + sum_constant_count(right) >= 2
}

sum_constant_count :: proc(node: ^Type) -> int {
	if node == nil do return 0
	if _, ok := int_of(node); ok do return 1
	#partial switch v in node^ {
	case Compose_Type:
		if v.operator == .Add || v.operator == .Subtract {
			l := v.left != nil ? sum_constant_count(v.left) : 0
			return l + sum_constant_count(v.right)
		}
	}
	return 0
}

// rebuild_sum emits the minimal sum from collected terms + a constant: each term as
// `coeff * base` (coeff 1 elided, negatives become subtractions), constant last.
rebuild_sum :: proc(terms: []Sum_Term, constant: i128) -> ^Type {
	result: ^Type = nil
	for t in terms {
		mag := t.coeff < 0 ? -t.coeff : t.coeff
		node := scale_node(t.base, mag) // mag>=1 here (zero terms dropped)
		if result == nil {
			result = t.coeff < 0 ? new_type(Compose_Type{nil, node, .Subtract, nil}) : node
		} else {
			op: Operator_Kind = t.coeff < 0 ? .Subtract : .Add
			result = dag_intern(Compose_Type{result, node, op, nil})
		}
	}
	if constant != 0 {
		if result == nil {
			result = new_type(make_int_result(constant))
		} else {
			result = offset_node(result, constant)
		}
	}
	if result == nil do return new_type(make_int_result(0))
	return result
}

// ============================================================================
// COMMON-FACTOR EXTRACTION — the DUAL of sum collection, transposed from LLVM's
// Reassociate::OptimizeAdd: `a*b + a*c` → `a*(b+c)`. Sum collection works the `+`
// axis (coefficients of equal bases); this works the `*` axis (bases sharing a
// factor). LLVM's two guards, reproduced exactly:
//   1. a factor must occur in ≥ 2 terms (MaxOcc > 1) — else no gain,
//   2. count occurrences PER TERM (a*a contributes `a` once to its term).
// Like LLVM's Reassociate this does NOT model latency / instruction-level
// parallelism: it factors on op-count alone (the out-of-order x86-64 core
// recovers the parallelism). The op_cost guard in collect_sum still applies.
// ============================================================================

// mul_factors decomposes a base node into its flat list of multiplicative factors
// (LLVM FindSingleUseMultiplyFactors): `a*b*c` → [a,b,c], a bare `??` → [itself].
// Only a `var * var` Multiply is split; a `const * x` is not a multiply-of-bases.
mul_factors :: proc(node: ^Type, out: ^[dynamic]^Type) {
	if node != nil {
		#partial switch v in node^ {
		case Compose_Type:
			if v.operator == .Multiply && v.left != nil {
				// A constant operand means this isn't a pure base product (handled by
				// the affine pass); keep the node whole.
				_, lc := coeff_of(v.left)
				_, rc := coeff_of(v.right)
				if !lc && !rc {
					mul_factors(v.left, out)
					mul_factors(v.right, out)
					return
				}
			}
		}
	}
	append(out, node)
}

// remove_one_factor rebuilds a base product with ONE occurrence of `factor`
// removed (by dag_key). Returns (residual, true) if the factor was present; the
// residual is `1` (nil base → caller uses constant 1) when it was the only factor.
remove_one_factor :: proc(base: ^Type, factor_key: string) -> (^Type, bool) {
	factors: [dynamic]^Type
	defer delete(factors)
	mul_factors(base, &factors)
	removed := false
	kept: [dynamic]^Type
	defer delete(kept)
	for f in factors {
		if !removed && dag_key(f) == factor_key {
			removed = true
			continue
		}
		append(&kept, f)
	}
	if !removed do return nil, false
	if len(kept) == 0 do return nil, true // factor was the whole base → residual 1
	prod := kept[0]
	for i in 1 ..< len(kept) {
		prod = dag_intern(Compose_Type{prod, kept[i], .Multiply, nil})
	}
	return prod, true
}

// factor_common attempts `Σ coeff_i·base_i (+ const)` → `factor·(Σ residual_i) +
// (untouched terms) + const`, extracting the factor present in the most terms (≥2).
// Returns nil when no factor occurs in ≥2 terms (LLVM's MaxOcc>1 guard).
factor_common :: proc(terms: []Sum_Term, constant: i128) -> ^Type {
	if len(terms) < 2 do return nil

	// Count, per term, how many terms contain each factor (keyed by dag_key).
	occ: map[string]int
	defer delete(occ)
	rep: map[string]^Type // a representative node for each factor key
	defer delete(rep)
	for t in terms {
		factors: [dynamic]^Type
		mul_factors(t.base, &factors)
		seen: map[string]bool // dedup within this term
		for f in factors {
			k := dag_key(f)
			if seen[k] do continue
			seen[k] = true
			occ[k] += 1
			rep[k] = f
		}
		delete(seen)
		delete(factors)
	}

	// Pick the factor in the most terms; require ≥2 (else no gain).
	best_key: string
	best_occ := 1
	for k, n in occ {
		if n > best_occ {
			best_occ = n
			best_key = k
		}
	}
	if best_occ < 2 do return nil
	factor := rep[best_key]

	// Split: terms that contain the factor → residuals (with coeff carried);
	// the rest stay as ordinary terms.
	residuals: [dynamic]Sum_Term
	defer delete(residuals)
	rest: [dynamic]Sum_Term
	defer delete(rest)
	for t in terms {
		if res, ok := remove_one_factor(t.base, best_key); ok {
			// residual base is `res` (or the constant 1 when nil), same coeff.
			residuals = append_term(residuals, Sum_Term{t.coeff, res})
		} else {
			rest = append_term(rest, t)
		}
	}

	// Build `factor * (Σ residuals)`. The residual sum is rebuilt (it may itself
	// collect, e.g. b + b → 2b).
	inner := rebuild_sum(residuals[:], 0)
	product := dag_intern(Compose_Type{factor, inner, .Multiply, nil})

	// Add back the untouched terms and the constant.
	result := product
	for t in rest {
		mag := t.coeff < 0 ? -t.coeff : t.coeff
		node := scale_node(t.base, mag)
		op: Operator_Kind = t.coeff < 0 ? .Subtract : .Add
		result = dag_intern(Compose_Type{result, node, op, nil})
	}
	if constant != 0 do result = offset_node(result, constant)
	return result
}

// append_term is a tiny helper so factor_common reads linearly (Odin's append
// returns the slice by value for dynamic arrays passed around).
append_term :: proc(arr: [dynamic]Sum_Term, t: Sum_Term) -> [dynamic]Sum_Term {
	a := arr
	append(&a, t)
	return a
}

// is_concrete_leaf reports whether a reduced ^Type is a single concrete value.
is_concrete_leaf :: proc(t: ^Type) -> bool {
	return fold_is_concrete_value(t)
}

// int_of returns the concrete i128 value of a node, if it is one.
int_of :: proc(t: ^Type) -> (i128, bool) {
	if t == nil do return 0, false
	#partial switch v in t^ {
	case Integer_Type:
		if int_is_concrete(v) do return int_value(v), true
	}
	return 0, false
}

// coeff_of returns the integer coefficient of a concrete numeric node for the
// affine pass. Like int_of, but also accepts a whole-valued float constant (an
// affine coefficient over a float base is a Float_Type, e.g. `2.0` in `2.0*x`),
// so distribution/collection keeps working across the float domain. A non-integer
// float (e.g. 2.5) is NOT a coefficient — the affine pass stays integer-monomial.
coeff_of :: proc(t: ^Type) -> (i128, bool) {
	if t == nil do return 0, false
	#partial switch v in t^ {
	case Integer_Type:
		if int_is_concrete(v) do return int_value(v), true
	case Float_Type:
		if float_is_concrete(v) {
			f := float_value(v)
			i := i128(f)
			if f64(i) == f do return i, true
		}
	}
	return 0, false
}

// simplify_arith applies the operation-minimal identities WITHOUT distributing,
// and reassociates a constant up a `*`/`+` chain so constants coalesce. Returns
// nil when no simplification applies (caller interns the plain node).
simplify_arith :: proc(op: Operator_Kind, left, right: ^Type) -> ^Type {
	#partial switch op {
	case .Multiply:
		lc, l_ok := int_of(left)
		rc, r_ok := int_of(right)
		if l_ok && lc == 0 do return new_type(make_int_result(0)) // 0 * x
		if r_ok && rc == 0 do return new_type(make_int_result(0)) // x * 0
		if l_ok && lc == 1 do return right // 1 * x
		if r_ok && rc == 1 do return left // x * 1
		// Reassociate: (sub * k1) * k2 → sub * (k1*k2); k1 * (sub * k2) → sub*(k1*k2).
		if r_ok {
			if folded := fold_const_into_mul(left, rc); folded != nil do return folded
		}
		if l_ok {
			if folded := fold_const_into_mul(right, lc); folded != nil do return folded
		}
		// Canonical orientation: constant on the LEFT (`2 * x`, not `x * 2`).
		if r_ok && !l_ok {
			return dag_intern(Compose_Type{right, left, .Multiply, nil})
		}
	case .Add:
		lc, l_ok := int_of(left)
		rc, r_ok := int_of(right)
		if l_ok && lc == 0 do return right // 0 + x
		if r_ok && rc == 0 do return left // x + 0
		// x + x → 2 * x
		if dag_key(left) == dag_key(right) {
			return dag_intern(Compose_Type{new_type(make_int_result(2)), left, .Multiply, nil})
		}
		// Coalesce a constant into a sub-sum that already carries one
		// (`(sub + 3) + (-4)` → `sub - 1`). Try both sides.
		if r_ok {
			if folded := fold_const_into_add(left, rc); folded != nil do return folded
		}
		if l_ok {
			if folded := fold_const_into_add(right, lc); folded != nil do return folded
		}
	case .Subtract:
		if left != nil {
			rc, r_ok := int_of(right)
			if r_ok && rc == 0 do return left // x - 0
			if dag_key(left) == dag_key(right) {
				return new_type(make_int_result(0)) // x - x → 0
			}
			// `(sub ± c) - k` → fold the constants by adding -k.
			if r_ok {
				if folded := fold_const_into_add(left, -rc); folded != nil do return folded
			}
		}
	}
	return nil
}

// fold_const_into_add coalesces the additive constant `k` into a node that is
// itself `sub + c` or `sub - c` (or `c + sub`), returning `sub + (c+k)` rendered
// as an add/subtract by sign. Returns nil when the node carries no foldable
// constant. Does NOT distribute — it only merges adjacent additive constants.
fold_const_into_add :: proc(node: ^Type, k: i128) -> ^Type {
	if node == nil do return nil
	#partial switch v in node^ {
	case Compose_Type:
		#partial switch v.operator {
		case .Add:
			if c, ok := int_of(v.right); ok do return offset_node(v.left, c + k)
			if c, ok := int_of(v.left); ok do return offset_node(v.right, c + k)
		case .Subtract:
			if v.left != nil {
				if c, ok := int_of(v.right); ok do return offset_node(v.left, -c + k) // (sub - c) + k
			}
		}
	}
	return nil
}

// offset_node returns `sub + delta`, dropping the term when delta is 0 and
// rendering a negative delta as a subtraction (`sub - 1`).
offset_node :: proc(sub: ^Type, delta: i128) -> ^Type {
	if delta == 0 do return sub
	if delta < 0 {
		return dag_intern(Compose_Type{sub, affine_const(sub, -delta), .Subtract, nil})
	}
	return dag_intern(Compose_Type{sub, affine_const(sub, delta), .Add, nil})
}

// node_float_kind reports whether a reduced node lives in the float domain, and
// its FloatKind. A float `??::f64` is a Cast over a float target; a concrete
// float / float Compose folds to a Float_Type. Mirrors machine_type_of's float
// detection so an affine coefficient over a float base is itself a float.
node_float_kind :: proc(node: ^Type) -> (FloatKind, bool) {
	if node == nil do return .none, false
	#partial switch v in node^ {
	case Float_Type:
		return v.kind, true
	case Cast_Type:
		if tgt, ok := cast_target(v.target); ok && tgt.kind == .Float {
			return tgt.float_kind, true
		}
	case Compose_Type:
		if env := fold_value_type(node); env != nil && env != node {
			return node_float_kind(env)
		}
		if k, ok := node_float_kind(v.left); ok do return k, true
		return node_float_kind(v.right)
	}
	return .none, false
}

// affine_const builds the integer/float literal `mag` matched to the base node's
// domain: a float base yields a Float_Type coefficient (so `x+x+x` over `??::f64`
// renders `3.0 * ??0`, and the native backend loads it as a float, not int bits),
// otherwise an Integer_Type.
affine_const :: proc(base: ^Type, mag: i128) -> ^Type {
	if k, ok := node_float_kind(base); ok {
		return new_type(make_float_result(f64(mag), k))
	}
	return new_type(make_int_result(mag))
}

// fold_const_into_mul folds `k` into a node that is itself a multiply by a
// constant (`(sub * c)` or `(c * sub)`), returning `sub * (c*k)`; nil otherwise.
fold_const_into_mul :: proc(node: ^Type, k: i128) -> ^Type {
	if node == nil do return nil
	#partial switch v in node^ {
	case Compose_Type:
		if v.operator == .Multiply {
			if c, ok := int_of(v.left); ok {
				return scale_node(v.right, c * k)
			}
			if c, ok := int_of(v.right); ok {
				return scale_node(v.left, c * k)
			}
		}
	}
	return nil
}

// scale_node returns `coeff * sub`, collapsing the coeff into the node when it is
// 0 or 1 (`0*x`→0, `1*x`→x). Constant on the left for canonical orientation.
scale_node :: proc(sub: ^Type, coeff: i128) -> ^Type {
	if coeff == 0 do return affine_const(sub, 0)
	if coeff == 1 do return sub
	return dag_intern(Compose_Type{affine_const(sub, coeff), sub, .Multiply, nil})
}

// eval_concrete runs the existing concrete evaluators for one operator on already
// reduced (concrete) operands, returning nil when it cannot evaluate.
eval_concrete :: proc(op: Operator_Kind, left, right: ^Type) -> ^Type {
	lv: Type = left != nil ? left^ : nil
	rv: Type = right != nil ? right^ : nil
	result := new(Type)
	#partial switch op {
	case .Add:
		result^ = compose_arith(lv, rv, .Add)
	case .Subtract:
		result^ = compose_arith(lv, rv, .Subtract)
	case .Multiply:
		result^ = compose_arith(lv, rv, .Multiply)
	case .Divide:
		result^ = compose_arith(lv, rv, .Divide)
	case .Mod:
		result^ = compose_arith(lv, rv, .Mod)
	case .Equal:
		result^ = compose_eq(lv, rv, true)
	case .NotEqual:
		result^ = compose_eq(lv, rv, false)
	case .Less:
		result^ = compose_ord(lv, rv, .Less)
	case .Greater:
		result^ = compose_ord(lv, rv, .Greater)
	case .LessEqual:
		result^ = compose_ord(lv, rv, .LessEqual)
	case .GreaterEqual:
		result^ = compose_ord(lv, rv, .GreaterEqual)
	case .BitAnd:
		result^ = compose_bitlogic(lv, rv, .BitAnd)
	case .BitOr:
		result^ = compose_bitlogic(lv, rv, .BitOr)
	case .Xor:
		result^ = compose_bitlogic(lv, rv, .Xor)
	case .LShift:
		result^ = compose_shift(lv, rv, true)
	case .RShift:
		result^ = compose_shift(lv, rv, false)
	case .BitNot, .Not:
		#partial switch l in lv {
		case Integer_Type:
			if int_is_concrete(l) do result^ = make_int_result(~int_value(l))
		case Bool_Type:
			if bool_is_concrete(l) do result^ = make_bool_const(!bool_value(l))
		}
	}
	if result^ == nil do return nil
	return result
}

// ============================================================================
// DAG LAYER — interning (CSE), structural keys, fixed-point indexing.
//
// reduce_value follows names to their bound values and reduces through, so the
// ONLY symbolic leaf that survives is the atomic fixed point (`??` / a `::`-cast
// of one). dag_intern hash-conses every constructed node by its STRUCTURAL key,
// so two equal subexpressions share one ^Type — the CSE that lets codegen compute
// `e` (and any `(…)*e`) exactly once.
// ============================================================================

// Interning table: structural key → the canonical ^Type for that shape. Reset per
// reduce() (the test harness destroys its arena between cases — a carried-over map
// would dangle). THREAD-LOCAL: the test runner reduces cases on multiple threads
// concurrently, and a shared global map would data-race into corruption/segfault.
@(thread_local) dag_table: map[string]^Type
@(thread_local) fixedpoint_index: map[rawptr]int
@(thread_local) fixedpoint_next: int

dag_reset :: proc() {
	dag_table = make(map[string]^Type)
	fixedpoint_index = make(map[rawptr]int)
	fixedpoint_next = 0
}

// dag_intern returns the canonical node for a Compose shape: if an identical shape
// was already built, the existing node is returned (sharing), else this one is
// stored. Keys are by the operands' own structural keys, so sharing is transitive.
dag_intern :: proc(c: Compose_Type) -> ^Type {
	node := new(Type)
	node^ = c
	key := dag_key(node)
	if existing, ok := dag_table[key]; ok do return existing
	dag_table[key] = node
	return node
}

// dag_key is the structural identity of a reduced node: equal keys ⟺ equal value.
// A concrete int is its number; a fixed point its stable index; a compose its
// `op(leftkey,rightkey)`. Commutative ops (`+`,`*`) sort their operand keys so
// `a+b` and `b+a` share. Used both for CSE and for the `x-x`/`x+x` identities.
dag_key :: proc(t: ^Type) -> string {
	if t == nil do return "_"
	#partial switch v in t^ {
	case Integer_Type:
		if int_is_concrete(v) do return fmt.aprintf("i%d", int_value(v))
		return fmt.aprintf("I%s", integer_to_string(v))
	case Float_Type:
		return fmt.aprintf("f%s", float_to_string(v))
	case String_Type:
		return fmt.aprintf("s%s", string_value(v))
	case Bool_Type:
		return fmt.aprintf("b%v", bool_is_concrete(v) ? bool_value(v) : false)
	case None_Type:
		return "n"
	case Compose_Type:
		lk := dag_key(v.left)
		rk := dag_key(v.right)
		if v.operator == .Add || v.operator == .Multiply {
			if lk > rk do lk, rk = rk, lk // commutative: canonical operand order
		}
		return fmt.aprintf("(%s%s%s)", lk, op_symbol(v.operator), rk)
	case Cast_Type:
		// A bare `??::T` atom keys by its fixed-point index; a width WRAPPER over a
		// composite source keys by its inner structure plus the target so two distinct
		// wrappers don't collide on one `?N`.
		if cast_is_atom(t) do return fmt.aprintf("?%d", fixedpoint_id(t))
		return fmt.aprintf("cast(%s,%s)", dag_key(v.value), type_to_string(v.target))
	case Unknown_Type:
		return fmt.aprintf("?%d", fixedpoint_id(t))
	case Mention_Type:
		return fmt.aprintf("?%d", fixedpoint_id(t))
	case Reference_Type:
		return fmt.aprintf("?%d", fixedpoint_id(t))
	}
	return fmt.aprintf("@%p", t)
}

// fixedpoint_id assigns a stable, appearance-ordered index to a fixed point. Keyed
// by node ADDRESS (every mention of the same `??` reduces to the same shared node)
// so two mentions of one unknown share an index, two distinct `??` do not. The
// index drives both CSE (same id → same key) and rendering (`??0`, `??1`).
fixedpoint_id :: proc(node: ^Type) -> int {
	id: rawptr = node
	#partial switch v in node^ {
	case Mention_Type:
		if v.match_scope != nil && v.match_index >= 0 {
			id = rawptr(uintptr(v.match_scope) ~ uintptr(v.match_index))
		}
	case Reference_Type:
		ref := v.reference
		if ref != nil && ref.match_scope != nil && ref.match_index >= 0 {
			id = rawptr(uintptr(ref.match_scope) ~ uintptr(ref.match_index))
		}
	}
	if idx, ok := fixedpoint_index[id]; ok do return idx
	idx := fixedpoint_next
	fixedpoint_next += 1
	fixedpoint_index[id] = idx
	return idx
}

// ============================================================================
// PATTERN / SET / CARVE / EXECUTE — the rest of Syntact.
// ============================================================================

// reduce_pattern collapses a pattern to the product of the FIRST branch that fires
// for the target. If the target is a fixed point we cannot pick a branch at
// compile time — but if EXACTLY ONE branch can fire (the others provably can't) we
// still resolve it; otherwise the pattern stays symbolic (the runtime decides).
reduce_pattern :: proc(p: Pattern_Type) -> ^Type {
	ft := fold_value_type(p.target)
	if ft != nil && !is_fixed_point(p.target) {
		for branch in p.branches {
			if branch_can_match(branch, ft) {
				return reduce_value(branch.product)
			}
		}
	}
	// Fixed-point target: the runtime selects the branch, so keep the pattern shape
	// but reduce the target (to its `??N`) and each branch's product. (A pattern that
	// passed exhaustiveness always has a firing branch at runtime.)
	if ft != nil {
		branches := make([]Pattern_Branch, len(p.branches))
		for branch, i in p.branches {
			branches[i] = Pattern_Branch{branch.value_match, branch.match, reduce_value(branch.product)}
		}
		r := new(Type)
		r^ = Pattern_Type{reduce_value(p.target), branches}
		return r
	}
	r := new(Type)
	r^ = Invalid_Type{}
	return r
}

// reduce_set_op materializes a |/&/~ expression to a concrete value (the default
// of the resulting domain), or keeps it symbolic when the domain can't be
// resolved statically (mixed families, symbolic negation).
reduce_set_op :: proc(value: ^Type) -> ^Type {
	folded := fold_constraint(value)
	if folded == nil do return value
	if _, is_none := folded^.(None_Type); is_none do return folded
	def := default_value(folded)
	if def != nil do return def
	return folded
}

execute :: proc(value: Execute_Type) -> ^Type {
	reduced := reduce_value(value.target)
	if reduced == nil do return value.target
	#partial switch &s in reduced^ {
	case Scope_Type:
		return reduce(&s)
	}
	return reduced
}

// reduce_carve materializes a carve into its substituted scope, reducing each of
// the resulting fields. A field overridden with (or depending on) a fixed point
// stays symbolic; concrete fields fold through.
reduce_carve :: proc(value: Carve_Type) -> ^Type {
	t := new(Type)
	t^ = value
	sub := fold_carve(t)
	if sub == nil {
		// Source did not resolve to a scope: reduce the source through.
		return reduce_value(value.source)
	}
	// Reduce each field's value in place (best-effort: keep symbolic on failure).
	for i := 0; i < len(sub.values); i += 1 {
		if sub.kind[i] == .Product {
			sub.values[i] = reduce_value(sub.values[i])
		}
	}
	r := new(Type)
	r^ = sub^
	return r
}

// ============================================================================
// CONCRETE EVALUATORS — used by eval_concrete for non-ring operators (and by the
// ring path's leaf folding). These operate on already-reduced concrete operands.
// ============================================================================

compose_arith :: proc(lv, rv: Type, op: Operator_Kind) -> Type {
	li, li_ok := lv.(Integer_Type)
	ri, ri_ok := rv.(Integer_Type)
	lf, lf_ok := lv.(Float_Type)
	rf, rf_ok := rv.(Float_Type)

	if lv == nil && op == .Subtract {
		if ri_ok && int_is_concrete(ri) {
			return make_int_result(-int_value(ri))
		}
		if rf_ok && float_is_concrete(rf) {
			return make_float_result(-float_value(rf), rf.kind)
		}
		return nil
	}

	if li_ok && ri_ok && int_is_concrete(li) && int_is_concrete(ri) {
		a := int_value(li)
		b := int_value(ri)
		#partial switch op {
		case .Add:
			return make_int_result(a + b)
		case .Subtract:
			return make_int_result(a - b)
		case .Multiply:
			return make_int_result(a * b)
		case .Divide:
			if b != 0 do return make_int_result(a / b)
		case .Mod:
			if b != 0 do return make_int_result(a % b)
		}
		return nil
	}

	fl, fr: f64
	fk: FloatKind

	if lf_ok && rf_ok && float_is_concrete(lf) && float_is_concrete(rf) {
		fl = float_value(lf)
		fr = float_value(rf)
		fk = promote_float_kind(lf.kind, rf.kind)
	} else if lf_ok && float_is_concrete(lf) && ri_ok && int_is_concrete(ri) {
		fl = float_value(lf)
		fr = int_to_f64(ri)
		fk = lf.kind
	} else if li_ok && int_is_concrete(li) && rf_ok && float_is_concrete(rf) {
		fl = int_to_f64(li)
		fr = float_value(rf)
		fk = rf.kind
	} else {
		if op == .Add {
			ls, ls_ok := lv.(String_Type)
			rs, rs_ok := rv.(String_Type)
			if ls_ok && rs_ok && string_is_concrete(ls) && string_is_concrete(rs) {
				joined := strings.concatenate({string_value(ls), string_value(rs)})
				return make_string_const(joined, .double)
			}
		}
		return nil
	}

	#partial switch op {
	case .Add:
		return make_float_result(fl + fr, fk)
	case .Subtract:
		return make_float_result(fl - fr, fk)
	case .Multiply:
		return make_float_result(fl * fr, fk)
	case .Divide:
		return make_float_result(fl / fr, fk)
	}
	return nil
}


promote_float_kind :: #force_inline proc(a, b: FloatKind) -> FloatKind {
	if a == .none do return b
	if b == .none do return a
	if a == .f64 || b == .f64 do return .f64
	return .f32
}

compose_eq :: proc(lv, rv: Type, eq: bool) -> Bool_Type {
	#partial switch l in lv {
	case Integer_Type:
		if !int_is_concrete(l) do return make_bool_const(false)
		r_i, r_i_ok := rv.(Integer_Type)
		r_f, r_f_ok := rv.(Float_Type)
		if r_i_ok && int_is_concrete(r_i) {
			return make_bool_const(eq == (int_value(l) == int_value(r_i)))
		}
		if r_f_ok && float_is_concrete(r_f) {
			return make_bool_const(eq == (int_to_f64(l) == float_value(r_f)))
		}
	case Float_Type:
		if !float_is_concrete(l) do return make_bool_const(false)
		r_f, r_f_ok := rv.(Float_Type)
		r_i, r_i_ok := rv.(Integer_Type)
		lf := float_value(l)
		if r_f_ok && float_is_concrete(r_f) do return make_bool_const(eq == (lf == float_value(r_f)))
		if r_i_ok && int_is_concrete(r_i) do return make_bool_const(eq == (lf == int_to_f64(r_i)))
	case Bool_Type:
		r := rv.(Bool_Type)
		if bool_is_concrete(l) && bool_is_concrete(r) {
			return make_bool_const(eq == (bool_value(l) == bool_value(r)))
		}
		return make_bool_const(false)
	case String_Type:
		r := rv.(String_Type)
		if string_is_concrete(l) && string_is_concrete(r) {
			return make_bool_const(eq == (string_value(l) == string_value(r)))
		}
		return make_bool_const(!eq)
	}
	return make_bool_const(false)
}

compose_ord :: proc(lv, rv: Type, op: Operator_Kind) -> Bool_Type {
	#partial switch l in lv {
	case Integer_Type:
		if !int_is_concrete(l) do return make_bool_const(false)
		r_i, r_i_ok := rv.(Integer_Type)
		r_f, r_f_ok := rv.(Float_Type)
		if r_i_ok && int_is_concrete(r_i) do return make_bool_const(i128_cmp(int_value(l), int_value(r_i), op))
		if r_f_ok && float_is_concrete(r_f) do return make_bool_const(float_cmp(int_to_f64(l), float_value(r_f), op))
	case Float_Type:
		if !float_is_concrete(l) do return make_bool_const(false)
		r_f, r_f_ok := rv.(Float_Type)
		r_i, r_i_ok := rv.(Integer_Type)
		lf := float_value(l)
		if r_f_ok && float_is_concrete(r_f) do return make_bool_const(float_cmp(lf, float_value(r_f), op))
		if r_i_ok && int_is_concrete(r_i) do return make_bool_const(float_cmp(lf, int_to_f64(r_i), op))
	}
	return make_bool_const(false)
}


i128_cmp :: #force_inline proc(a, b: i128, op: Operator_Kind) -> bool {
	#partial switch op {
	case .Less:
		return a < b
	case .Greater:
		return a > b
	case .LessEqual:
		return a <= b
	case .GreaterEqual:
		return a >= b
	}
	return false
}


float_cmp :: #force_inline proc(a, b: f64, op: Operator_Kind) -> bool {
	#partial switch op {
	case .Less:
		return a < b
	case .Greater:
		return a > b
	case .LessEqual:
		return a <= b
	case .GreaterEqual:
		return a >= b
	}
	return false
}

compose_bitlogic :: proc(lv, rv: Type, op: Operator_Kind) -> Type {
	#partial switch l in lv {
	case Integer_Type:
		if !int_is_concrete(l) do return nil
		r, r_ok := rv.(Integer_Type)
		if !r_ok || !int_is_concrete(r) do return nil
		a := int_value(l)
		b := int_value(r)
		val: i128
		#partial switch op {
		case .BitAnd:
			val = a & b
		case .BitOr:
			val = a | b
		case .Xor:
			val = a ~ b
		}
		return make_int_result(val)
	case Bool_Type:
		r := rv.(Bool_Type)
		if bool_is_concrete(l) && bool_is_concrete(r) {
			a := bool_value(l)
			b := bool_value(r)
			#partial switch op {
			case .BitAnd:
				return make_bool_const(a && b)
			case .BitOr:
				return make_bool_const(a || b)
			case .Xor:
				return make_bool_const(a ~ b)
			}
		}
	}
	return nil
}

compose_shift :: proc(lv, rv: Type, is_left: bool) -> Type {
	l, l_ok := lv.(Integer_Type)
	r, r_ok := rv.(Integer_Type)
	if !l_ok || !r_ok do return nil
	if !int_is_concrete(l) || !int_is_concrete(r) do return nil
	a := int_value(l)
	b := int_value(r)
	if b < 0 || b >= 128 do return nil

	val: i128
	ub := u64(b)
	if is_left {
		val = i128(u128(a) << ub)
	} else {
		val = i128(u128(a) >> ub)
	}
	return make_int_result(val)
}
