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
	// Fresh per-reduction symbol bookkeeping, allocated in the CURRENT context (the
	// test harness runs each case in its own arena that is destroyed afterward, so a
	// map carried over from a previous reduce would dangle). Reset every call.
	symbol_seq = make(map[rawptr]int)
	symbol_seq_next = 0
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
// COMPOSE — the symbolic arithmetic core.
// ============================================================================

// reduce_compose partially evaluates an arithmetic node. For the ring operators
// (`+ - *`) it normalizes the whole subtree into a canonical polynomial over the
// surviving fixed points and emits the operation-minimal tree. For non-ring
// operators it reduces the operands and, if both became concrete, evaluates;
// otherwise it stays symbolic with reduced operands.
reduce_compose :: proc(v: Compose_Type) -> ^Type {
	#partial switch v.operator {
	case .Add, .Subtract, .Multiply:
		if poly, ok := build_poly(v); ok {
			return poly_to_type(poly)
		}
	}
	// Non-ring operator, or a polynomial we could not build: reduce operands and
	// evaluate concretely if possible, else keep symbolic with reduced children.
	left := v.left != nil ? reduce_value(v.left) : nil
	right := v.right != nil ? reduce_value(v.right) : nil
	if (v.left == nil || is_concrete_leaf(left)) && is_concrete_leaf(right) {
		if concrete := eval_concrete(v.operator, left, right); concrete != nil {
			return concrete
		}
	}
	r := new(Type)
	r^ = Compose_Type{left, right, v.operator, nil}
	return r
}

// is_concrete_leaf reports whether a reduced ^Type is a single concrete value.
is_concrete_leaf :: proc(t: ^Type) -> bool {
	return fold_is_concrete_value(t)
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
// POLYNOMIAL — canonical sum-of-monomials over the fixed-point symbols.
//
// A Poly is a list of Terms; a Term is an integer coefficient times a Monomial.
// A Monomial is the sorted product of symbol powers (the empty monomial = the
// constant term). Symbols are keyed by identity (a named binding's site, or a
// per-occurrence id for an anonymous `??`/opaque subexpression) so `a + a`
// collects into `2*a` but two distinct `??` stay apart.
// ============================================================================

Symbol :: struct {
	key:  string, // stable identity for collection
	node: ^Type, // the original ^Type, for rendering (a Mention renders as `a`)
}

Factor :: struct {
	sym:   Symbol,
	power: int,
}

Term :: struct {
	coeff:    i128,
	monomial: []Factor, // sorted by symbol key; empty = constant
}

Poly :: struct {
	terms: [dynamic]Term,
}

// build_poly attempts to normalize a `+ - *` subtree into a Poly. It returns
// ok=false if the subtree mixes in a non-integer concrete (a float/string — those
// are not in the integer polynomial ring and fall back to the generic path).
build_poly :: proc(v: Compose_Type) -> (Poly, bool) {
	t := new(Type)
	t^ = v
	return expr_to_poly(t)
}

// expr_to_poly converts any reduced expression into a Poly. Concrete integers
// become the constant term; fixed points become degree-1 monomials; `+ - *`
// recurse; anything else (a non-ring op over a symbol, a float, …) becomes a
// single opaque symbol of degree 1 — UNLESS it is a concrete non-integer, in
// which case we bail (ok=false) so the caller keeps the generic concrete path.
expr_to_poly :: proc(t: ^Type) -> (Poly, bool) {
	if t == nil do return {}, false

	#partial switch v in t^ {
	case Compose_Type:
		#partial switch v.operator {
		case .Add, .Subtract:
			if v.left == nil {
				// Unary: `+x` -> x, `-x` -> negate.
				rp, rok := expr_to_poly(v.right)
				if !rok do return {}, false
				if v.operator == .Subtract do return poly_neg(rp), true
				return rp, true
			}
			// Visit LEFT first so symbols get appearance-ordered sequence numbers in
			// source order (`a*2 + b*3` assigns a before b).
			lp, lok := expr_to_poly(v.left)
			if !lok do return {}, false
			rp, rok := expr_to_poly(v.right)
			if !rok do return {}, false
			if v.operator == .Subtract do return poly_add(lp, poly_neg(rp)), true
			return poly_add(lp, rp), true
		case .Multiply:
			lp, lok := expr_to_poly(v.left)
			if !lok do return {}, false
			rp, rok := expr_to_poly(v.right)
			if !rok do return {}, false
			return poly_mul(lp, rp), true
		}
		// Non-ring operator (`/`, comparisons, bit ops): reduce it, then treat the
		// reduced node as an opaque symbol if it is still symbolic, or as a constant
		// if it collapsed to an integer.
		reduced := reduce_compose(v)
		return leaf_to_poly(reduced)
	}
	return leaf_to_poly(t)
}

// leaf_to_poly turns a non-Compose reduced node into a Poly: a concrete integer is
// the constant term, a TRUE fixed point a degree-1 symbol, a concrete non-integer
// bails. A reference whose target is NOT a fixed point (e.g. `b -> a*2`) is NOT a
// symbol — we FOLLOW it: reduce the bound value and re-polynomialize, so a chain of
// reference-bound expressions distributes through (`b + 2` with `b -> a*2`,
// `a -> ??::u8*2` becomes `4 * a + 2`, not the opaque symbol `b + 2`). Only a
// reference that bottoms out in a `??` stays a symbol — and then keyed by its OWN
// site so repeated mentions of the same name collect.
leaf_to_poly :: proc(t: ^Type) -> (Poly, bool) {
	if t == nil do return {}, false
	#partial switch v in t^ {
	case Integer_Type:
		if int_is_concrete(v) do return poly_const(int_value(v)), true
		// A non-singleton integer envelope is a fixed point too (its concrete value
		// is unknown): carry it as an opaque symbol.
		return poly_symbol(make_symbol(t)), true
	case Float_Type:
		return {}, false // floats are not in the integer ring
	case String_Type:
		return {}, false
	case Bool_Type:
		return {}, false
	case None_Type:
		return {}, false
	case Mention_Type:
		// Always FOLLOW a name to its bound value and re-polynomialize. A name is
		// never itself a symbol — we want to SEE the `??` it bottoms out in, not the
		// alias. `b -> a*2` distributes; `b -> a -> ??::u8` collapses to the `??::u8`
		// atom (rendered `??::u8`), so two aliases of the same unknown collect.
		if v.match_scope != nil && v.match_index >= 0 {
			return expr_to_poly(reduce_value(v.match_scope.values[v.match_index]))
		}
		return poly_symbol(make_symbol(t)), true
	case Reference_Type:
		eff := reference_effective_value(v)
		if eff != nil do return expr_to_poly(reduce_value(eff))
		return poly_symbol(make_symbol(t)), true
	}
	// Cast(??) / Unknown / opaque Compose: the atomic symbol. This is the only node
	// that becomes a Symbol — the actual fixed point the runtime/linker resolves.
	return poly_symbol(make_symbol(t)), true
}

// --- symbol identity ---
//
// Symbols are ordered by FIRST APPEARANCE, not by address: a global sequence map
// assigns each distinct fixed point a stable index the first time make_symbol sees
// it, and the rendered key embeds that index (`s<seq>:…`). Sorting monomials by
// key then yields a deterministic order independent of allocation/ASLR — `a*2 +
// b*3` always renders with `a`'s term before `b`'s, whatever the heap layout.

symbol_seq:      map[rawptr]int
symbol_seq_next: int

// symbol_index returns a stable, appearance-ordered index for a node identity.
symbol_index :: proc(id: rawptr) -> int {
	if idx, ok := symbol_seq[id]; ok do return idx
	idx := symbol_seq_next
	symbol_seq_next += 1
	symbol_seq[id] = idx
	return idx
}

// make_symbol derives a Symbol with a stable identity key from a node. The fixed
// point a name bottoms out in is a single SHARED `^Type` (every mention of `a`
// reduces to the same `??::u8` node), so we key by that node's ADDRESS — two
// mentions of the same unknown then collect (`a + a` → `2 * ??::u8`), while two
// distinct `??` (different nodes) stay apart.
//
// Keys must outlive the temp allocator (they index maps across many folds), so
// they are heap-allocated (fmt.aprintf, not tprintf's transient buffer).
make_symbol :: proc(node: ^Type) -> Symbol {
	// The identity that decides collection (same id → same symbol). For a name it
	// is the binding site, for an atomic `??` the node address.
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
	// Embed the appearance-ordered index so sort_by(key) is deterministic.
	seq := symbol_index(id)
	return Symbol{fmt.aprintf("s%08d:%p", seq, id), node}
}

// --- poly constructors ---

poly_zero :: proc() -> Poly {
	return Poly{make([dynamic]Term)}
}

poly_const :: proc(c: i128) -> Poly {
	p := poly_zero()
	if c != 0 do append(&p.terms, Term{c, {}})
	return p
}

poly_symbol :: proc(s: Symbol) -> Poly {
	p := poly_zero()
	mono := make([]Factor, 1)
	mono[0] = Factor{s, 1}
	append(&p.terms, Term{1, mono})
	return p
}

// --- poly arithmetic (collecting like monomials) ---

poly_add :: proc(a, b: Poly) -> Poly {
	out := poly_zero()
	for t in a.terms do poly_accumulate(&out, t.coeff, t.monomial)
	for t in b.terms do poly_accumulate(&out, t.coeff, t.monomial)
	return out
}

poly_neg :: proc(a: Poly) -> Poly {
	out := poly_zero()
	for t in a.terms do poly_accumulate(&out, -t.coeff, t.monomial)
	return out
}

poly_mul :: proc(a, b: Poly) -> Poly {
	out := poly_zero()
	for ta in a.terms {
		for tb in b.terms {
			poly_accumulate(&out, ta.coeff * tb.coeff, monomial_mul(ta.monomial, tb.monomial))
		}
	}
	return out
}

// poly_accumulate adds `coeff * monomial` into p, merging with a like monomial and
// dropping the term if the coefficient reaches zero.
poly_accumulate :: proc(p: ^Poly, coeff: i128, monomial: []Factor) {
	if coeff == 0 do return
	mono := monomial_normalize(monomial)
	key := monomial_key(mono)
	for &t, i in p.terms {
		if monomial_key(t.monomial) == key {
			t.coeff += coeff
			if t.coeff == 0 do ordered_remove(&p.terms, i)
			return
		}
	}
	append(&p.terms, Term{coeff, mono})
}

// monomial_mul concatenates two monomials and normalizes (combines powers).
monomial_mul :: proc(a, b: []Factor) -> []Factor {
	combined := make([dynamic]Factor, 0, len(a) + len(b))
	for f in a do append(&combined, f)
	for f in b do append(&combined, f)
	return monomial_normalize(combined[:])
}

// monomial_normalize sorts factors by symbol key and sums the powers of repeats,
// so `a*a` becomes `a^2` and the canonical key is order-independent.
monomial_normalize :: proc(factors: []Factor) -> []Factor {
	if len(factors) == 0 do return {}
	collected := make(map[string]Factor)
	order := make([dynamic]string)
	for f in factors {
		if f.power == 0 do continue
		if existing, ok := collected[f.sym.key]; ok {
			collected[f.sym.key] = Factor{existing.sym, existing.power + f.power}
		} else {
			collected[f.sym.key] = f
			append(&order, f.sym.key)
		}
	}
	slice.sort(order[:])
	out := make([dynamic]Factor, 0, len(order))
	for k in order {
		f := collected[k]
		if f.power != 0 do append(&out, f)
	}
	return out[:]
}

// monomial_key is the canonical string identity of a monomial (factors already
// sorted by monomial_normalize). The empty monomial keys as "" (the constant).
monomial_key :: proc(factors: []Factor) -> string {
	if len(factors) == 0 do return ""
	b := strings.builder_make()
	for f, i in factors {
		if i > 0 do strings.write_byte(&b, '*')
		strings.write_string(&b, f.sym.key)
		if f.power != 1 do fmt.sbprintf(&b, "^%d", f.power)
	}
	return strings.to_string(b)
}

// ============================================================================
// POLY -> TYPE — emit the operation-minimal Compose tree.
//
// Order the terms for stable, readable output: symbolic terms first (sorted by
// monomial key, then descending degree-ish), the constant last. A term renders as
// `coeff * monomial` with the coefficient elided when it is 1 (or rendered as a
// leading `-` and a subtraction when negative). The whole sum chains with `+`/`-`
// so a negative term becomes a subtraction (`6*a - 3`, not `6*a + -3`).
// ============================================================================

poly_to_type :: proc(p: Poly) -> ^Type {
	if len(p.terms) == 0 {
		return new_type(make_int_result(0))
	}

	// Stable order: non-constant terms first (by monomial key), constant last.
	terms := make([dynamic]Term, 0, len(p.terms))
	for t in p.terms do if len(t.monomial) > 0 do append(&terms, t)
	slice.sort_by(terms[:], proc(a, b: Term) -> bool {
		return monomial_key(a.monomial) < monomial_key(b.monomial)
	})
	// Append the constant term (if any) at the end.
	for t in p.terms do if len(t.monomial) == 0 do append(&terms, t)

	result: ^Type = nil
	for t, i in terms {
		term_node, term_neg := term_to_type(t)
		if result == nil {
			if term_neg {
				// Leading negative term: 0 - |term|, or just -|term| via unary.
				result = new_type(Compose_Type{nil, term_node, .Subtract, nil})
			} else {
				result = term_node
			}
		} else {
			op: Operator_Kind = term_neg ? .Subtract : .Add
			result = new_type(Compose_Type{result, term_node, op, nil})
		}
		_ = i
	}
	if result == nil do return new_type(make_int_result(0))
	return result
}

// term_to_type renders one term as `|coeff| * monomial` (coefficient elided when
// 1) and reports whether the term is negative (so the caller subtracts it).
term_to_type :: proc(t: Term) -> (^Type, bool) {
	neg := t.coeff < 0
	mag := neg ? -t.coeff : t.coeff

	if len(t.monomial) == 0 {
		// Pure constant: render its magnitude, the caller subtracts if negative.
		return new_type(make_int_result(mag)), neg
	}

	mono := monomial_to_type(t.monomial)
	if mag == 1 {
		return mono, neg
	}
	coeff_node := new_type(make_int_result(mag))
	return new_type(Compose_Type{coeff_node, mono, .Multiply, nil}), neg
}

// monomial_to_type renders a product of symbol powers as a chain of multiplies,
// expanding a power `a^n` into `a * a * … * a` (n factors) so codegen sees plain
// multiplications. Factors keep their original ^Type node (so a Mention renders
// as its name).
monomial_to_type :: proc(factors: []Factor) -> ^Type {
	result: ^Type = nil
	for f in factors {
		for _ in 0 ..< f.power {
			if result == nil {
				result = f.sym.node
			} else {
				result = new_type(Compose_Type{result, f.sym.node, .Multiply, nil})
			}
		}
	}
	return result
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
