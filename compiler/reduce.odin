package compiler

import "core:fmt"
import "core:slice"
import "core:strings"

// ============================================================================
// SYMBOLIC FIXED-POINT REDUCTION
//
// Partial evaluation: each `??` is a fixed point the reducer carries as a free
// variable; everything concrete is folded, and the surviving symbolic expression
// is emitted operation-minimal. A concrete-singleton fold IS the reduction;
// otherwise descend into the node's value and reduce symbolically.
// ============================================================================

// reduce collapses a scope through its Product binding.
//
// An `...A` expansion (`.Expand`) pastes A's bindings — INCLUDING its production
// — at that position. So the FIRST production reached in binding order wins, and
// an expansion that carries a production fires BEFORE a later in-place `-> v`
// (`{...double#0; -> 6}` collapses through double#0's production, not the `6`).
reduce :: proc(scope: ^Scope_Type) -> ^Type {
	for i := 0; i < len(scope.kind); i += 1 {
		if scope.kind[i] == .Product {
			if i < len(scope.type_folds) {
				if shortcut := singleton_shortcut(scope.type_folds[i]); shortcut != nil {
					return shortcut
				}
			}
			return reduce_value(scope.types[i])
		}
		if scope.kind[i] == .Expand {
			if prod := reduce_expand_production(scope.types[i]); prod != nil {
				return prod
			}
		}
	}
	// A scope with no Product binding reduces to none — the empty value, not nil.
	return new_type(None_Type{})
}

// reduce_expand_production resolves an `...A` operand to its scope and returns
// A's production reduction, or nil when A is not a scope or carries no product
// (a productionless expansion is transparent — collapse falls through to the
// next binding).
reduce_expand_production :: proc(value: ^Type) -> ^Type {
	resolved := follow(value)
	if resolved == nil do return nil
	#partial switch &s in resolved^ {
	case Scope_Type:
		for i := 0; i < len(s.kind); i += 1 {
			if s.kind[i] == .Product {
				if i < len(s.type_folds) {
					if shortcut := singleton_shortcut(s.type_folds[i]); shortcut != nil {
						return shortcut
					}
				}
				return reduce_value(s.types[i])
			}
			if s.kind[i] == .Expand {
				if prod := reduce_expand_production(s.types[i]); prod != nil {
					return prod
				}
			}
		}
	}
	return nil
}

// singleton_shortcut returns the fold when it is a concrete singleton, else nil
// (signalling "descend into the value").
singleton_shortcut :: proc(tf: ^Type) -> ^Type {
	if tf == nil do return nil
	if fold_is_concrete_value(tf) do return tf
	return nil
}

// reduce_value is the recursive partial evaluator: a concrete value when
// everything resolved, else a symbolic Compose tree over the fixed points.
reduce_value :: proc(value: ^Type) -> ^Type {
	if value == nil do return nil
	switch &v in value^ {
	case Execute_Type:
		return reduce_value(execute(v))
	case Compose_Type:
		return reduce_compose(v)
	case Cast_Type:
		// Concrete source → use the cached reinterpreted value.
		if v.type_fold != nil && fold_is_concrete_value(v.type_fold) {
			return reduce_value(v.type_fold)
		}
		// A bare `??::u8` is an atom; a cast over a composite source is a width
		// WRAPPER: reduce the inner expression and re-wrap.
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
	case Recursive_Mention_Type:
		return reduce_recursive_mention(v, value)
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

// reduce_mention follows a name to its binding and reduces through. A fixed-point
// binding follows to the atomic `??` node so every route to one unknown converges
// on one node (and thus one `??N` index, so they collect).
reduce_mention :: proc(v: Mention_Type, node: ^Type) -> ^Type {
	if v.match_scope == nil || v.match_index < 0 do return node
	bound := v.match_scope.types[v.match_index]
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
						if is_fixed_point(cv.types[i]) do return follow_to_fixedpoint(cv.types[i])
						return reduce_value(cv.types[i])
					}
				}
			}
		}
	}
	target := ref.match_scope.types[ref.match_index]
	if is_fixed_point(target) do return follow_to_fixedpoint(target)
	return reduce_value(target)
}

// reduce_recursive_mention mirrors reduce_mention for a self mention; an
// unresolved one (analysis errored) stays opaque.
reduce_recursive_mention :: proc(v: Recursive_Mention_Type, node: ^Type) -> ^Type {
	if v.match_scope == nil || v.match_index < 0 do return node
	bound := v.match_scope.types[v.match_index]
	if is_fixed_point(bound) do return follow_to_fixedpoint(bound)
	return reduce_value(bound)
}

// follow_to_fixedpoint chases a fixed-point value through aliases to the atomic
// `??` node, so all references to one unknown share that node (and fixedpoint_id).
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
				cur = v.match_scope.types[v.match_index]
				continue
			}
			return t
		case Reference_Type:
			if v.reference != nil &&
			   v.reference.match_scope != nil &&
			   v.reference.match_index >= 0 {
				cur = v.reference.match_scope.types[v.reference.match_index]
				continue
			}
			return t
		}
		return t
	}
	return t
}

// is_fixed_point reports whether `t` ultimately denotes an UNKNOWN the reducer
// must carry as a free variable.
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
				cur = v.match_scope.types[v.match_index]
				continue
			}
			return false
		case Reference_Type:
			if v.reference != nil &&
			   v.reference.match_scope != nil &&
			   v.reference.match_index >= 0 {
				cur = v.reference.match_scope.types[v.reference.match_index]
				continue
			}
			return false
		}
		return false
	}
	return false
}

// cast_is_atom reports whether a Cast node is a bare `??::T` atom (its source,
// followed through aliases, bottoms out in the Unknown). A composite source
// (`(a+b)::u8`) is a width WRAPPER, not an atom.
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
				cur = v.match_scope.types[v.match_index]
				continue
			}
			return false
		case Reference_Type:
			if v.reference != nil &&
			   v.reference.match_scope != nil &&
			   v.reference.match_index >= 0 {
				cur = v.reference.match_scope.types[v.reference.match_index]
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

// reduce_scope reduces a non-root scope to itself — used when a value resolves to
// a structural scope (e.g. a carve result rendered without collapse).
// reduce_scope reduces a scope VALUE: everything is a scope, so the value of a
// scope is the scope of its fields' reduced values — each pointing field reduces
// through (a fired pattern product `{func{e->e}! ...map{r, func}!}` materializes
// its collapses), and an `...A` expansion whose operand reduces to a scope PASTES
// that scope's bindings at its position (the value-side of the paste rule
// execute_production applies to productions) — the flat cons list. A production
// stays lazy (it is the collapse target, reduced by `!`), and a scope already
// mid-reduction above (a self-referential field) is returned as-is — laziness
// exactly where eagerness cannot terminate.
reduce_scope :: proc(s: ^Scope_Type) -> ^Type {
	reducer := current_reducer()
	if reducer != nil {
		for open in reducer.scope_stack do if open == s do return new_type(s^)
		append(&reducer.scope_stack, s)
	}
	defer if reducer != nil do pop(&reducer.scope_stack)

	changed := false
	reduced_vals := make([]^Type, len(s.types))
	splice := make([]^Scope_Type, len(s.types))
	for i in 0 ..< len(s.kind) {
		if s.types[i] == nil do continue
		// A bare recursive-tail CARVE reached as a value (the grammar's own cons
		// machinery, `...Array{T}:` inside the materialized machine) re-materializes
		// itself forever — keep it residual (terminate.odin's unfold stack marks the
		// grammar open). A COLLAPSE (`...m{r, func}!`) is NOT skipped: execute's own
		// guards decide it and concrete data terminates it.
		if cv, is_carve := s.types[i]^.(Carve_Type); is_carve {
			if unfold_open(collapse_source(cv.source)) do continue
		}
		#partial switch s.kind[i] {
		case .Pointing_Push, .Pointing_Pull:
			r := reduce_value(s.types[i])
			if r != nil && r != s.types[i] {
				reduced_vals[i] = r
				changed = true
			}
		case .Expand:
			r := reduce_value(s.types[i])
			if r == nil do continue
			res := follow(r)
			if res == nil do continue
			if rs, ok := &res^.(Scope_Type); ok {
				splice[i] = rs
				changed = true
			} else if r != s.types[i] {
				reduced_vals[i] = r
				changed = true
			}
		}
	}
	if !changed do return new_type(s^)

	out := new(Scope_Type)
	out.parent = s.parent
	for i in 0 ..< len(s.kind) {
		if sp := splice[i]; sp != nil {
			for j in 0 ..< len(sp.kind) {
				append(&out.names, j < len(sp.names) ? sp.names[j] : "")
				append(&out.kind, sp.kind[j])
				append(&out.types, j < len(sp.types) ? sp.types[j] : nil)
				append(&out.constraints, j < len(sp.constraints) ? sp.constraints[j] : nil)
				append(&out.type_folds, j < len(sp.type_folds) ? sp.type_folds[j] : nil)
				append(&out.constraint_folds, j < len(sp.constraint_folds) ? sp.constraint_folds[j] : nil)
				append(&out.captures, j < len(sp.captures) ? sp.captures[j] : "")
			}
			continue
		}
		append(&out.names, i < len(s.names) ? s.names[i] : "")
		append(&out.kind, s.kind[i])
		append(&out.types, reduced_vals[i] != nil ? reduced_vals[i] : s.types[i])
		append(&out.constraints, i < len(s.constraints) ? s.constraints[i] : nil)
		// A reduced field's cached fold is stale: invalidate; consumers refold on demand.
		append(&out.type_folds, reduced_vals[i] != nil ? nil : (i < len(s.type_folds) ? s.type_folds[i] : nil))
		append(&out.constraint_folds, i < len(s.constraint_folds) ? s.constraint_folds[i] : nil)
		append(&out.captures, i < len(s.captures) ? s.captures[i] : "")
	}
	return new_type(out^)
}

// ============================================================================
// COMPOSE — the symbolic arithmetic core (DAG + constant folding + CSE).
//
// The reduced form is NOT distributed (distribution grows the op count, the
// opposite of operation-minimal). We keep the factored structure and only fold
// constants, eliminate identities, and share common subexpressions via CSE.
// ============================================================================

// reduce_compose partially evaluates one arithmetic node: reduce the operands,
// fold constants, apply the algebraic identities, then intern for CSE.
reduce_compose :: proc(v: Compose_Type) -> ^Type {
	left := v.left != nil ? reduce_value(v.left) : nil
	right := v.right != nil ? reduce_value(v.right) : nil

	// Constant fold: every concrete operand present → evaluate outright.
	if (v.left == nil || is_concrete_leaf(left)) && is_concrete_leaf(right) {
		if concrete := eval_concrete(v.operator, left, right); concrete != nil {
			return concrete
		}
	}

	// Binary +/- : collect like terms across the sum chain (`k*x + m*x` → `(k+m)*x`).
	if (v.operator == .Add || v.operator == .Subtract) && v.left != nil {
		if collected := collect_sum(left, right, v.operator); collected != nil {
			return collected
		}
	}

	// Algebraic simplification: multiply chains, unary minus, identities.
	if simplified := simplify_arith(v.operator, left, right); simplified != nil {
		return simplified
	}

	return dag_intern(Compose_Type{left, right, v.operator, nil})
}

// SUM COLLECTION — gather a +/- chain's like terms (k*x + m*x → (k+m)*x), fold
// the constant, re-emit the minimal sum. Purely additive (no distribution). A
// "term" is (coefficient, base) keyed by dag_key; the bare constant is separate.

Sum_Term :: struct {
	coeff: i128,
	base:  ^Type, // nil for the constant accumulator
}

// collect_sum flattens both sides of `left <op> right` (op + or -) into additive
// terms, sums coefficients of equal bases, and rebuilds the minimal sum. Returns
// nil if nothing combined (caller keeps the plain node, no churn).
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

	// Common-factor extraction (LLVM Reassociate dual): `a*b + a*c` → `a*(b+c)`,
	// kept only if it lowers the op count.
	if factored := factor_common(kept[:], constant); factored != nil {
		if op_cost(factored) < op_cost(rebuilt) {
			rebuilt = factored
		}
	}

	// Commit only if the canonical form is no more expensive than the original.
	orig := op_cost(left) + op_cost(right) + 1
	if op_cost(rebuilt) > orig do return nil // would grow → keep the plain node
	// Avoid pointless churn: if nothing structurally changed, bail.
	if op_cost(rebuilt) == orig &&
	   len(kept) == count_sum_leaves(left) + count_sum_leaves(right) &&
	   constant == 0 {
		return nil
	}
	return rebuilt
}

// op_cost counts the arithmetic Compose nodes in a reduced expression.
op_cost :: proc(node: ^Type) -> int {
	if node == nil do return 0
	#partial switch v in node^ {
	case Compose_Type:
		return 1 + op_cost(v.left) + op_cost(v.right)
	}
	return 0
}

// flatten_sum decomposes `node` scaled by `coeff` into additive terms, the bare
// constant into `constant`. `coeff` is a full integer coefficient, so a `const*sub`
// product distributes the constant into the affine sub-form (`3*(2a-1)` → `6a-3`);
// a `var*var` product is kept as one opaque atom (no distribution of nonlinear).
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
			// `k * sub`: distribute k by recursing into sub with the product coeff.
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

// count_sum_leaves counts the additive leaves of a +/- chain (a product or atom
// is one leaf).
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

// rebuild_sum emits the minimal sum from collected terms + a constant: each term
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
// COMMON-FACTOR EXTRACTION — dual of sum collection (LLVM Reassociate::OptimizeAdd):
// `a*b + a*c` → `a*(b+c)`. Two guards: a factor must occur in ≥2 terms, counted
// per term (a*a contributes `a` once). op_cost guard in collect_sum still applies.
// ============================================================================

// mul_factors decomposes a base into its flat list of multiplicative factors
// (`a*b*c` → [a,b,c]). Only a `var * var` Multiply is split.
mul_factors :: proc(node: ^Type, out: ^[dynamic]^Type) {
	if node != nil {
		#partial switch v in node^ {
		case Compose_Type:
			if v.operator == .Multiply && v.left != nil {
				// A constant operand means this isn't a pure base product (the affine
				// pass handles it); keep the node whole.
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
// removed (by dag_key). Returns (residual, true) if present; residual is nil
// (caller uses constant 1) when the factor was the whole base.
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
// (untouched terms) + const`, extracting the factor present in the most terms.
// Returns nil when no factor occurs in ≥2 terms.
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

// coeff_of returns the integer coefficient of a concrete numeric node. Like int_of,
// but also accepts a whole-valued float constant (`2.0` in `2.0*x`); a non-integer
// float (2.5) is NOT a coefficient.
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

// simplify_arith applies the identities without distributing, and reassociates a
// constant up a `*`/`+` chain so constants coalesce. Returns nil when nothing
// applies (caller interns the plain node).
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

// fold_const_into_add coalesces constant `k` into a node that is itself `sub ± c`
// (or `c + sub`), returning `sub + (c+k)`. Returns nil when no foldable constant.
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

// node_float_kind reports whether a reduced node lives in the float domain and its
// FloatKind. Mirrors machine_type_of's float detection so an affine coefficient
// over a float base is itself a float.
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
		// Read the analyzer's cached envelope (reduce never re-folds); a
		// reducer-built Compose has no cache and falls through to its operands.
		if v.type_fold != nil && v.type_fold != node {
			if k, ok := node_float_kind(v.type_fold); ok do return k, true
		}
		if k, ok := node_float_kind(v.left); ok do return k, true
		return node_float_kind(v.right)
	}
	return .none, false
}

// affine_const builds the literal `mag` matched to the base node's domain: a float
// base yields a Float_Type coefficient, otherwise an Integer_Type.
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
	// A STRING operand (`e + "!"` concat, `e * 3` repetition): the string kernel
	// owns the semantics — delegate, as the analyze-time fold does.
	l_str, r_str := false, false
	if left != nil {
		_, l_str = left^.(String_Type)
	}
	if right != nil {
		_, r_str = right^.(String_Type)
	}
	if l_str || r_str {
		syn := new_type(Compose_Type{left, right, op, nil})
		if r := fold_type_string(syn); r != nil && fold_is_concrete_value(r) do return r
		return nil
	}
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
// The only symbolic leaf that survives is the atomic fixed point. dag_intern
// hash-conses every node by its structural key, so equal subexpressions share one
// ^Type (the CSE that lets codegen compute a shared subexpression once).
// ============================================================================

// Reducer state lives on context.user_ptr, fresh per reduce(): the test harness
// destroys its arena between cases (a carried-over map would dangle) and reduces
// cases on multiple threads (a shared global map would data-race).
Reducer :: struct {
	collapse_stack:   [dynamic]^Scope_Type,
	// Canonical sources whose carve materialization is mid-field-reduction; the
	// symbolic-pattern residual guard (see terminate.odin) reads it.
	unfold_stack:     [dynamic]^Scope_Type,
	// Scope values whose fields are mid-reduction (reduce_scope): a self-referential
	// field re-entering its own scope stays lazy instead of looping.
	scope_stack:      [dynamic]^Scope_Type,
	dag_table:        map[string]^Type,
	fixedpoint_index: map[rawptr]int,
	fixedpoint_next:  int,
	// Per-branch refinements computed by reduce_pattern, keyed by the branch product
	// node: inside that product, each listed fixed-point leaf carries `domain`. Lets
	// the backend read the narrowed range, and the tests observe the refinement.
	refinements:      map[rawptr][]Refinement,
}

// current_reducer fetches the in-flight reducer from the phase context (nil outside
// reduce). See Phase_Context (analyze.odin) — both handles share one user_ptr slot.
current_reducer :: #force_inline proc() -> ^Reducer {
	pc := cast(^Phase_Context)context.user_ptr
	if pc == nil do return nil
	return pc.reducer
}

create_reducer :: proc() -> Reducer {
	return Reducer {
		collapse_stack = make([dynamic]^Scope_Type),
		unfold_stack = make([dynamic]^Scope_Type),
		dag_table = make(map[string]^Type),
		fixedpoint_index = make(map[rawptr]int),
		fixedpoint_next = 0,
		refinements = make(map[rawptr][]Refinement),
	}
}

// dag_intern returns the canonical node for a Compose shape, sharing an existing
// identical one. Keys are by the operands' keys, so sharing is transitive.
dag_intern :: proc(c: Compose_Type) -> ^Type {
	node := new(Type)
	node^ = c
	key := dag_key(node)
	reducer := current_reducer()
	if existing, ok := reducer.dag_table[key]; ok do return existing
	reducer.dag_table[key] = node
	return node
}

// dag_key is the structural identity of a reduced node: equal keys ⟺ equal value.
// Commutative ops (`+`,`*`) sort their operand keys so `a+b` and `b+a` share.
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
		// A bare `??::T` atom keys by its fixed-point index; a width wrapper keys by
		// inner structure + target so distinct wrappers don't collide on one `?N`.
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

// fixedpoint_id assigns a stable, appearance-ordered index to a fixed point, keyed
// by node address (mentions of one `??` share the node, hence the index; distinct
// `??` do not). Drives both CSE and rendering (`??0`, `??1`).
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
	reducer := current_reducer()
	if idx, ok := reducer.fixedpoint_index[id]; ok do return idx
	idx := reducer.fixedpoint_next
	reducer.fixedpoint_next += 1
	reducer.fixedpoint_index[id] = idx
	return idx
}

// ============================================================================
// PATTERN / SET / CARVE / EXECUTE — the rest of Syntact.
// ============================================================================

// reduce_pattern collapses a pattern to the product of the first branch that fires.
// A fixed-point target can't pick a branch at compile time; the pattern stays
// symbolic. The firing test reads cached cover_folds, refolding on demand when a
// reduce-side clone invalidated one (reduce_branch_fires).
reduce_pattern :: proc(p: Pattern_Type) -> ^Type {
	if !is_fixed_point(p.target) {
		target := reduce_value(p.target)
		// A branch can be picked at compile time only when the reduced target carries
		// NO free fixed point — then its membership in each cover is decidable. A
		// target with a free `??` (e.g. `??0 + 2`, a Compose over fixed points) stays
		// symbolic and the refinement pass below records the per-branch narrowings.
		if target != nil && !contains_fixed_point(target) {
			decide: for branch in p.branches {
				switch reduce_branch_fires(branch, target) {
				case .Yes:
					// Destructuring: the fired product reduces with its cover
					// substituted by the scrutinee's matched pieces (repoint — the
					// same substitution a carve uses).
					return reduce_value(fired_product(branch, target, false))
				case .No:
					continue
				case .Undecidable:
					// An undecidable cover must not fall through to a later branch
					// (mis-firing the default): the pattern stays symbolic.
					break decide
				}
			}
		}
	}
	// Symbolic target: keep the pattern shape, reduce the target and each branch's
	// product; the runtime selects the branch. Inside branch k the scrutinee is known
	// to be `target & ~M0 & … & ~M(k-1) & Mk`; refine() pushes that conjunction down
	// to the free leaves and we record the narrowed domains on the branch product.
	target := reduce_value(p.target)
	reducer := current_reducer()
	branches := make([]Pattern_Branch, len(p.branches))
	for branch, i in p.branches {
		// A product that re-enters an unfold already open above this pattern cannot
		// terminate under a symbolic scrutinee (the pivot stays symbolic every
		// round): keep it residual instead of unfolding forever.
		product := branch.product
		if !contains_open_unfold(branch.product) {
			product = reduce_value(branch.product)
		}
		branches[i] = Pattern_Branch {
			match      = branch.match,
			product    = product,
			cover_fold = branch.cover_fold,
		}
		add := branch_refinement_add(p.branches[:], i)
		if add != nil && product != nil {
			refs := refine(target, add)
			if len(refs) > 0 do reducer.refinements[product] = refs
		}
	}
	r := new(Type)
	r^ = Pattern_Type{target, branches}
	return r
}

// branch_refinement_add builds the type added to the scrutinee inside branch k:
// `Mk & ~M(k-1) & … & ~M0`. A bare/default branch (nil cover) contributes nothing
// positive; earlier defaults can't precede a real branch in a well-formed pattern,
// so a nil earlier cover is simply skipped.
branch_refinement_add :: proc(branches: []Pattern_Branch, k: int) -> ^Type {
	mk := branches[k].cover_fold
	// The positive term: a real branch contributes its cover Mk; a default branch
	// (nil cover) contributes only the negations of every earlier branch (~M0 & …),
	// so it starts from the unbounded top.
	add: ^Type
	if mk != nil {
		// Read through a `=v` producer scope `{-> v}` to its production leaf, mirroring
		// reduce_branch_fires, so the cover is the leaf domain not the meta-scope.
		add = cover_leaf(mk)
	} else {
		add = integer_top()
	}
	for j := k - 1; j >= 0; j -= 1 {
		mj := branches[j].cover_fold
		if mj == nil do continue
		neg := new(Type)
		neg^ = Negate_Type{cover_leaf(mj)}
		conj := new(Type)
		conj^ = And_Type{add, neg}
		add = conj
	}
	return add
}

// cover_leaf reads through a single-product `{-> v}` producer scope to the leaf,
// so a `=v` value-match cover is treated as the domain of v.
cover_leaf :: proc(cover: ^Type) -> ^Type {
	if cover == nil do return nil
	if s, is_scope := cover^.(Scope_Type); is_scope {
		prods := scope_productions(s)
		if len(prods) == 1 && prods[0] != nil do return prods[0]
	}
	return cover
}

// The reduce-side firing decision. Yes/No when the membership is decidable;
// Undecidable keeps the whole pattern SYMBOLIC — it must never fall through to a
// later branch (that would mis-fire the default on a value an earlier cover
// actually matches). Reduce bases the decision on what is ALREADY FOLDED and
// refolds on demand (a reduce-side clone invalidates cached folds; recompute them
// lazily at the decision point) — the fast kernel walk (reduce_scope_fires) decides
// the common shapes, everything past it goes to the ordinary satisfy proof over the
// folded values. This call gate is only reached for a target with no free `??`
// (reduce_pattern's static path), where membership is genuinely decidable.
Fire_Decision :: enum u8 {
	No,
	Yes,
	Undecidable,
}

reduce_branch_fires :: proc(branch: Pattern_Branch, target: ^Type) -> Fire_Decision {
	if branch.match == nil do return .Yes
	cf := branch.cover_fold
	if cf == nil && branch.match != nil {
		// Invalidated by a reduce-side clone (repoint refold=false): refold on demand.
		cf = fold_constraint(branch.match)
	}
	if cf == nil || target == nil do return .Undecidable
	// A value-match (`=v`) cover folds to the producer scope `{-> v}`; read through it
	// to the production leaf so the leaf domain test below decides v's membership.
	// A structural scope cover (no production) is a destructuring shape: decide it
	// with the mirrored structural walk against a scope target.
	if s, is_scope := &cf^.(Scope_Type); is_scope {
		prods := scope_productions(s^)
		if len(prods) == 1 && prods[0] != nil {
			cf = prods[0]
		} else if len(prods) == 0 {
			res := follow(target)
			if res == nil do return .Undecidable
			ts, t_ok := &res^.(Scope_Type)
			if !t_ok do return .No
			return reduce_scope_fires(s, ts, 0, 0)
		}
	}
	// A `=v` whose v is itself a SCOPE VALUE (`={x->6}`) fires on structural value
	// equality, decided field-wise with the kernels.
	if _, cf_is_scope := cf^.(Scope_Type); cf_is_scope {
		return reduce_value_equal(cf, target)
	}
	return reduce_leaf_fires(cf, target)
}

// reduce_value_equal decides structural VALUE equality of two reduced values:
// two-way kernel satisfaction on domain leaves (equality for singletons),
// name-sensitive field-wise recursion on scopes.
reduce_value_equal :: proc(l, r: ^Type) -> Fire_Decision {
	lv := reduce_value(l)
	rv := reduce_value(r)
	if lv == nil || rv == nil do return .Undecidable
	if ls, l_ok := &lv^.(Scope_Type); l_ok {
		res := follow(rv)
		if res == nil do return .Undecidable
		rs, r_ok := &res^.(Scope_Type)
		if !r_ok do return .No
		if len(ls.types) != len(rs.types) do return .No
		for i in 0 ..< len(ls.types) {
			ln := i < len(ls.names) ? ls.names[i] : ""
			rn := i < len(rs.names) ? rs.names[i] : ""
			if ln != rn do return .No
			d := reduce_value_equal(ls.types[i], rs.types[i])
			if d != .Yes do return d
		}
		return .Yes
	}
	d1 := reduce_leaf_fires(lv, rv)
	if d1 == .Undecidable do return .Undecidable
	d2 := reduce_leaf_fires(rv, lv)
	if d2 == .Undecidable do return .Undecidable
	return (d1 == .Yes && d2 == .Yes) ? .Yes : .No
}

// reduce_leaf_fires decides one domain-leaf membership with the kernels.
reduce_leaf_fires :: proc(cf: ^Type, target: ^Type) -> Fire_Decision {
	if cf == nil || target == nil do return .Undecidable
	#partial switch f in cf^ {
	case Integer_Type:
		v, ok := target^.(Integer_Type)
		if !ok do return .No
		return integer_satisfy(f, v) ? .Yes : .No
	case Float_Type:
		v, ok := target^.(Float_Type)
		if !ok do return .No
		return float_satisfy(f, v) ? .Yes : .No
	case String_Type:
		v, ok := target^.(String_Type)
		if !ok do return .No
		return string_satisfy(f, v) ? .Yes : .No
	case Bool_Type:
		v, ok := target^.(Bool_Type)
		if !ok do return .No
		return bool_satisfy(f, v) ? .Yes : .No
	}
	return .Undecidable
}

// cover_constraint_fold reads a cover field's constraint fold, recomputing it on
// demand when a reduce-side clone invalidated it (repoint refold=false) — reduce
// bases decisions on existing folds and refolds as needed. The recomputed fold is
// cached back so the next decision reuses it.
cover_constraint_fold :: proc(cover: ^Scope_Type, c: int) -> ^Type {
	cf := c < len(cover.constraint_folds) ? cover.constraint_folds[c] : nil
	if cf == nil && c < len(cover.constraints) && cover.constraints[c] != nil {
		cf = fold_constraint(cover.constraints[c])
		if c < len(cover.constraint_folds) do cover.constraint_folds[c] = cf
	}
	return cf
}

// scope_ensure_value_folds fills the missing type_folds of a reduced scope so the
// satisfy machinery (which reads folds) can prove against it — same on-demand rule.
scope_ensure_value_folds :: proc(ts: ^Scope_Type) {
	for k in 0 ..< len(ts.types) {
		if k < len(ts.type_folds) && ts.type_folds[k] == nil && ts.types[k] != nil {
			ts.type_folds[k] = fold_type(reduce_value(ts.types[k]))
		}
	}
}

// reduce_scope_fires mirrors scope_satisfy_range for the reduce side: cover fields
// in lockstep with target fields (names must agree — shape matching is
// name-sensitive), an Expand cover field swallowing the remaining run. A domain-LEAF
// expand (`...u8`) repeats the kernel test; a structural expand (the recursive tail
// `...Array{T}:`) goes to the ordinary satisfy proof (expand_satisfies) over the
// folded run — decidable here because the static path guarantees a `??`-free target.
reduce_scope_fires :: proc(cover: ^Scope_Type, ts: ^Scope_Type, ci, vi: int) -> Fire_Decision {
	c := ci
	for c < len(cover.kind) && cover.kind[c] == .Product do c += 1
	if c >= len(cover.kind) {
		return vi >= len(ts.types) ? .Yes : .No
	}
	if cover.kind[c] == .Expand {
		cf := cover_constraint_fold(cover, c)
		if cf == nil do return vi >= len(ts.types) ? .Yes : .No
		for k := vi; k < len(ts.types); k += 1 {
			d := reduce_leaf_fires(cf, reduce_value(ts.types[k]))
			if d == .Undecidable {
				// Structural expand: the full satisfy proof over the folded run.
				scope_ensure_value_folds(ts)
				return expand_satisfies(cf, ts^, k, len(ts.types)) ? .Yes : .No
			}
			if d == .No do return .No
		}
		return .Yes
	}
	if vi >= len(ts.types) do return .No
	if c < len(cover.names) && vi < len(ts.names) && cover.names[c] != ts.names[vi] {
		return .No
	}
	cf := cover_constraint_fold(cover, c)
	if cf == nil do return .Undecidable
	elem := reduce_value(ts.types[vi])
	d := reduce_leaf_fires(cf, elem)
	if d == .Undecidable {
		// Non-kernel cover fold (a set fold, a nested destructuring shape): the
		// ordinary satisfy proof on the folded element.
		vf := fold_type(elem)
		if vf == nil do return .Undecidable
		d = satisfy_root(cf, vf) ? .Yes : .No
	}
	if d != .Yes do return d
	return reduce_scope_fires(cover, ts, c + 1, vi + 1)
}

// reduce_set_op materializes a |/&/~ expression to a concrete value (the default
// of the resulting domain), or keeps it symbolic when the domain can't resolve
// statically. Operands reduced first, then combined through the per-domain kernels
// (never the analyzer's fold_constraint).
reduce_set_op :: proc(value: ^Type) -> ^Type {
	syn: ^Type
	#partial switch v in value^ {
	case Or_Type:
		l := reduce_value(v.left)
		r := reduce_value(v.right)
		if l == nil || r == nil do return value
		syn = new_type(Or_Type{l, r})
	case And_Type:
		l := reduce_value(v.left)
		r := reduce_value(v.right)
		if l == nil || r == nil do return value
		syn = new_type(And_Type{l, r})
	case Negate_Type:
		o := reduce_value(v.operand)
		if o == nil do return value
		syn = new_type(Negate_Type{o})
	case:
		return value
	}
	folded := fold_constraint_integer(syn)
	if folded == nil do folded = fold_constraint_float(syn)
	if folded == nil do folded = fold_constraint_string(syn)
	if folded == nil do folded = fold_constraint_bool(syn)
	if folded == nil do return value
	if def := type_default(folded); def != nil do return def
	return folded
}

execute :: proc(value: Execute_Type) -> ^Type {
	// Re-entering a source scope already being unfolded does not terminate statically
	// (pivot is a `??`): stop unfolding, keep the target symbolic. Not an error: see
	// terminate.odin.
	src := collapse_source(value.target)
	if src != nil && collapse_would_recurse(src) {
		return value.target
	}
	reduced := reduce_value(value.target)
	if reduced == nil do return value.target
	#partial switch &s in reduced^ {
	case Scope_Type:
		collapse_enter(src)
		defer collapse_leave()
		return reduce(&s)
	}
	return reduced
}

// reduce_carve materializes a carve into its substituted scope, reducing each
// resulting field.
reduce_carve :: proc(value: Carve_Type) -> ^Type {
	sub := reduce_substitute_carve(value)
	if sub == nil {
		// Source did not resolve to a scope: reduce the source through.
		return reduce_value(value.source)
	}
	// Reduce each field's value in place (best-effort: keep symbolic on failure).
	// The canonical source is marked open while its fields reduce: a SYMBOLIC
	// pattern below keeps a re-entrant recursive branch residual instead of
	// unfolding forever (terminate.odin); a concrete pattern still picks its
	// branch statically and unfolds through to the base case.
	src := collapse_source(value.source)
	unfold_enter(src)
	defer unfold_leave(src)
	for i := 0; i < len(sub.types); i += 1 {
		if sub.kind[i] == .Product {
			sub.types[i] = reduce_value(sub.types[i])
		}
	}
	r := new(Type)
	r^ = sub^
	return r
}

// reduce_substitute_carve is the reduce-side carve materialization: resolve the
// source scope, clone it (scope_clone, a PURE copy — never scope_repoint, whose
// fold refresh re-enters the analyzer's fold layer), unify pulls, write overrides,
// repoint sibling references. It clears the cached type_folds of every field it
// substitutes or repoints so reduce_value reads the value itself; untouched
// fields keep their analyze-time folds.
reduce_substitute_carve :: proc(value: Carve_Type) -> ^Scope_Type {
	src: ^Scope_Type = nil
	cur := follow(value.source)
	for cur != nil {
		#partial switch &s in cur^ {
		case Scope_Type:
			src = &s
		case Carve_Type:
			// A carve of a carve: substitute the inner one first so we override
			// onto the already-substituted scope.
			src = reduce_substitute_carve(s)
		}
		break
	}
	if src == nil do return nil

	copy := scope_clone(src)

	for i in 0 ..< len(value.references) {
		ref := value.references[i]
		// A substitution may have replaced the source with a structurally different
		// scope — re-resolve a named reference against it (see carve_ref_index).
		idx := carve_ref_index(ref, copy)
		if idx >= 0 && idx < len(copy.types) {
			// Identity override (`Array{T}` overriding T with the same T) would, after
			// repoint, leave a self-mention — an unresolvable cycle. Changes nothing; skip.
			if mv, is_m := value.types[i]^.(Mention_Type);
			   is_m && mv.match_scope == src && mv.match_index == idx {
				continue
			}
			// PULL UNIFICATION: a field constraint mentioning a pull binds the pull from
			// the supplied value (`data{6}` → e = 6), so every mention of e reads 6.
			if idx < len(copy.constraints) &&
			   copy.constraints[idx] != nil {
				reduce_unify_pull(copy.constraints[idx], value.types[i], copy, src)
			}
			copy.types[idx] = value.types[i]
			// Clear the pre-carve cached fold (a stale singleton would shadow it).
			if idx < len(copy.type_folds) {
				copy.type_folds[idx] = nil
			}
		}
	}

	// Repoint references that named the source so they name the copy (sibling
	// mentions read the substituted values, cascading); clear repointed folds.
	// refold=false: reduce owns user_ptr (the Reducer), so scope_repoint must NOT
	// re-enter the analyzer-only fold layer — it invalidates nested folds instead.
	for i in 0 ..< len(copy.types) {
		repointed := repoint(copy.types[i], src, copy, false)
		if repointed != copy.types[i] {
			copy.types[i] = repointed
			if i < len(copy.type_folds) do copy.type_folds[i] = nil
		}
	}
	return copy
}

// reduce_unify_pull mirrors the analyzer's unify_pull for reduce-side substitution
// — same structural matching, no fold calls.
reduce_unify_pull :: proc(constraint, value: ^Type, copy, src: ^Scope_Type) {
	if constraint == nil || value == nil do return

	// Unification matches the VALUE's structure: a mention/reference/collapse is
	// resolved to its reduced structure on demand (a recursive carve passes the
	// cover capture `r` — a mention of the destructured tail scope).
	value := value
	#partial switch _ in value^ {
	case Mention_Type, Reference_Type, Execute_Type:
		value = reduce_value(value)
		if value == nil do return
	}

	// A mention of a pull on the constraint side: bind it to the value.
	if m, ok := constraint^.(Mention_Type); ok {
		if m.match_scope == src && m.match_index >= 0 && m.match_index < len(copy.kind) {
			if copy.kind[m.match_index] == .Pointing_Pull {
				copy.types[m.match_index] = value
				if m.match_index < len(copy.type_folds) {
					copy.type_folds[m.match_index] = nil
				}
			}
		}
		return
	}

	// Two carves: unify each constraint override against the value override that
	// targets the same source slot. A SCOPE value against a grammar carve
	// (`Array{T}:source` proven by `{2 3 4 5}`) reuses the analyzer's grammar
	// unroll (unify_pull_carve_scope) — reduce refolds on demand, so re-entering
	// the fold layer at this bounded point is fine.
	if cc, c_ok := &constraint^.(Carve_Type); c_ok {
		if vc, v_ok := &value^.(Carve_Type); v_ok {
			for ci in 0 ..< len(cc.references) {
				slot := cc.references[ci].match_index
				for vi in 0 ..< len(vc.references) {
					if vc.references[vi].match_index == slot {
						reduce_unify_pull(cc.types[ci], vc.types[vi], copy, src)
						break
					}
				}
			}
		} else if vs, vs_ok := &value^.(Scope_Type); vs_ok {
			unify_pull_carve_scope(cc, vs^, copy, src)
		}
		return
	}

	// Two scopes: unify field-by-field by position.
	if cs, c_ok := &constraint^.(Scope_Type); c_ok {
		if vs, v_ok := &value^.(Scope_Type); v_ok {
			n := min(len(cs.types), len(vs.types))
			for i in 0 ..< n {
				reduce_unify_pull(cs.types[i], vs.types[i], copy, src)
			}
		}
	}
}

// ============================================================================
// CONCRETE EVALUATORS — operate on already-reduced concrete operands.
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
