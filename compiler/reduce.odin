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
		return value
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

// reduce_mention follows a name to its binding. If the binding's value is a fixed
// point (an Unknown / unresolved cast) the mention IS a symbol — we keep it (so it
// renders as `a`, not `??`). Otherwise we reduce the bound value through.
reduce_mention :: proc(v: Mention_Type, node: ^Type) -> ^Type {
	if v.match_scope == nil || v.match_index < 0 do return node
	bound := v.match_scope.values[v.match_index]
	if is_fixed_point(bound) do return node
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
						if is_fixed_point(cv.values[i]) do return node
						return reduce_value(cv.values[i])
					}
				}
			}
		}
	}
	target := ref.match_scope.values[ref.match_index]
	if is_fixed_point(target) do return node
	return reduce_value(target)
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

	// Algebraic simplification for the ring/commutative operators, then reassociate
	// a constant up a chain (`(x*2)*2` → `x*4`, `(5*e)*14` → `70*e`).
	if simplified := simplify_arith(v.operator, left, right); simplified != nil {
		return simplified
	}

	return dag_intern(Compose_Type{left, right, v.operator, nil})
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
		return dag_intern(Compose_Type{sub, new_type(make_int_result(-delta)), .Subtract, nil})
	}
	return dag_intern(Compose_Type{sub, new_type(make_int_result(delta)), .Add, nil})
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
	if coeff == 0 do return new_type(make_int_result(0))
	if coeff == 1 do return sub
	return dag_intern(Compose_Type{new_type(make_int_result(coeff)), sub, .Multiply, nil})
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
		return fmt.aprintf("?%d", fixedpoint_id(t))
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
	// Fixed-point target: reduce each branch's product but keep the pattern shape
	// so the runtime selects. (A pattern that passed exhaustiveness always has a
	// firing branch at runtime.)
	if ft != nil {
		branches := make([]Pattern_Branch, len(p.branches))
		for branch, i in p.branches {
			branches[i] = Pattern_Branch{branch.value_match, branch.match, reduce_value(branch.product)}
		}
		r := new(Type)
		r^ = Pattern_Type{p.target, branches}
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
