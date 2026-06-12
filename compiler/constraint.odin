package compiler

import "core:fmt"

// ===========================================================================
// CONSTRAINT side: fold_constraint resolves the set a binding IMPOSES, and
// satisfy proves a value's type is a subset of it. Split out of type.odin so
// the constraint proof (left of `:`) is separated from the value/type fold
// (right of `->`). Same package as type.odin — they call each other freely.
// ===========================================================================

fold_constraint :: proc(t: ^Type) -> ^Type {
	if t != nil {
		#partial switch v in t^ {
		case Unknown_Type:
			// A `??` can never denote a statically-known set: the Unknown IS the
			// fold result, propagated by every composite case below.
			return t
		case Recursive_Mention_Type:
			return t
		case Scope_Type:
			if scope_fields_fold_unknown(t, v.types[:]) do return new_type(Unknown_Type{})
			return t
		case Carve_Type:
			// A carve used as a constraint folds to its substituted scope — which
			// must itself be a statically-known set: an unknown source or override
			// is insoluble, same as the Scope case (the carve node is the guard
			// key, so a self-referential carve is not rescanned forever).
			sub := fold_carve_constraint(t)
			if sub == nil {
				if sf := fold_constraint(v.source); fold_is_unknown(sf) do return sf
				return nil
			}
			if scope_fields_fold_unknown(t, sub.types[:]) do return new_type(Unknown_Type{})
			r := new(Type)
			r^ = sub^
			return r
		case Mention_Type:
			if v.match_scope != nil && v.match_index >= 0 {
				return fold_constraint_target(v.match_scope, v.match_index)
			}
		case Reference_Type:
			ref := v.reference
			if ref != nil && ref.match_scope != nil && ref.match_index >= 0 {
				return fold_constraint_target(ref.match_scope, ref.match_index)
			}
		case Execute_Type:
			// `target!` as a constraint folds to the constraint of the production
			// the collapse reduces through (the first .Product of the target). A
			// scope with no production collapses to `none`. A RECURSIVE collapse
			// bails to nil (execute_fold_enter) instead of unfolding forever.
			key, blocked := execute_fold_enter(v.target)
			if blocked do return nil
			defer execute_fold_leave(key)
			prod, resolved := execute_production(v.target)
			if prod == nil {
				if resolved do return new_type(None_Type{})
				// An unresolvable target may itself be an unknown (`??!`).
				if tf := fold_constraint(v.target); fold_is_unknown(tf) do return tf
				return nil
			}
			return fold_constraint(prod)
		case And_Type:
			left := fold_constraint(v.left)
			right := fold_constraint(v.right)
			if fold_is_unknown(left) do return left
			if fold_is_unknown(right) do return right
			// Pure numeric reduction (intersection) if possible — ..9 & 11.. etc.
			// Symbolic otherwise: mixed families (String & Int), positional
			// negation (pattern & ~(ends with '_')), scopes.
			syn := new_type(And_Type{left, right})
			if r := fold_constraint_integer(syn); r != nil do return r
			if r := fold_constraint_float(syn); r != nil do return r
			if r := fold_constraint_bool(syn); r != nil do return r
			return syn
		case Or_Type:
			left := fold_constraint(v.left)
			right := fold_constraint(v.right)
			if fold_is_unknown(left) do return left
			if fold_is_unknown(right) do return right
			syn := new_type(Or_Type{left, right})
			if r := fold_constraint_integer(syn); r != nil do return r
			if r := fold_constraint_float(syn); r != nil do return r
			if r := fold_constraint_bool(syn); r != nil do return r
			return syn
		case Negate_Type:
			// De Morgan normalization in the same pass: we push ~ toward the
			// leaves and collapse the ~~. The result stays folded by this same
			// function, so the tree never has a ~ stacked on a &/|/~.
			//   ~~X      → X
			//   ~(A & B) → ~A | ~B
			//   ~(A | B) → ~A & ~B
			// A ~range / ~literal leaf folds through the domain kernels
			// (interval complement for ordinal/numeric) or stays symbolic
			// (positional string negation), handled by satisfy.
			inner := follow(v.operand)
			if inner != nil {
				#partial switch iv in inner^ {
				case Negate_Type:
					return fold_constraint(iv.operand) // ~~X → X
				case And_Type:
					// De Morgan : ~(A & B) → ~A | ~B. We rebuild the unfolded tree
					// and pass it back to fold_constraint, which will reduce the Or into intervals.
					r := new(Type)
					r^ = Or_Type{negated(iv.left), negated(iv.right)}
					return fold_constraint(r)
				case Or_Type:
					r := new(Type)
					r^ = And_Type{negated(iv.left), negated(iv.right)}
					return fold_constraint(r)
				}
			}
			// Negative leaf: numeric complement if possible, otherwise symbolic.
			operand := fold_constraint(v.operand)
			if fold_is_unknown(operand) do return operand
			syn := new_type(Negate_Type{operand})
			if r := fold_constraint_integer(syn); r != nil do return r
			if r := fold_constraint_float(syn); r != nil do return r
			if r := fold_constraint_bool(syn); r != nil do return r
			if neg := negate_ordinal_string(v.operand); neg != nil do return neg
			return syn
		case Integer_Type:
			return fold_constraint_integer(t)
		case Float_Type:
			return fold_constraint_float(t)
		case String_Type:
			return fold_constraint_string(t)
		case Bool_Type:
			return fold_constraint_bool(t)
		case Cast_Type:
			// The envelope a `::` produces is exactly its target — the cast forces
			// the value into the target's layout, so the result always lands there.
			// As a CONSTRAINT though, a cast of an unpinned unknown (`??::u8`) is
			// ONE indeterminate element of the target, not the whole set —
			// insoluble, unless the cast pinned to a concrete singleton.
			if v.type_fold == nil || !fold_is_concrete_value(v.type_fold) {
				if vf := fold_constraint(v.value); fold_is_unknown(vf) do return vf
			}
			if v.type_fold != nil do return fold_constraint(v.type_fold)
			return fold_constraint(v.target)
		case Pattern_Type:
			// A pattern as a constraint resolves to ONE branch — the first whose
			// match the target satisfies (see fold_constraint_pattern).
			return fold_constraint_pattern(t)
		case Compose_Type:
			// An expression over an unknown operand (`a+10` where a -> ??) is one
			// indeterminate value, not a set — insoluble, even though its numeric
			// ENVELOPE folds fine (10..265 is the envelope, not the constraint).
			left := fold_constraint(v.left)
			right := fold_constraint(v.right)
			if fold_is_unknown(left) do return left
			if fold_is_unknown(right) do return right
			// A string concatenation `+` that is an ordered SEQUENCE (did not collapse
			// to a concrete literal) keeps its Compose shape as the constraint — satisfy
			// matches the value in order (string_compose_satisfy). Only when it is NOT a
			// string sequence does it fold through the numeric/string kernels.
			if v.operator == .Add {
				if _, ok := fold_string_sequence(t, true).([]String_Interval); ok {
					if fold_constraint_string(t) == nil do return t
				}
			}
			// The family of an expression is decided by its operands, not its tag:
			// run the kernels over the folded children (the synthetic node carries
			// no type_fold, so the arithmetic runs on the children — never on the
			// cached value ENVELOPE, which would hide what the constraint depends on).
			syn := new_type(Compose_Type{operator = v.operator, left = left, right = right})
			if r := fold_constraint_integer(syn); r != nil do return r
			if r := fold_constraint_float(syn); r != nil do return r
			if r := fold_constraint_string(syn); r != nil do return r
			if r := fold_constraint_bool(syn); r != nil do return r
			return nil
		case Range_Type:
			// A THREE-bound string range `"ab".."cd".."ef"` (a Range whose right is
			// itself a Range) means: starts with "ab", CONTAINS "cd", ends with "ef".
			// The flat string fold loses the middle, so keep the Range_Type itself as
			// the constraint and let satisfy enforce all three (string_tri_range_satisfy).
			if string_is_tri_range(t) do return t
			left := fold_constraint(v.left)
			right := fold_constraint(v.right)
			if fold_is_unknown(left) do return left
			if fold_is_unknown(right) do return right
			// A missing bound (`5..`, `..10`) stays nil on the synthetic node — the
			// kernels read it as open to infinity on that side.
			syn := new_type(Range_Type{left, right})
			if r := fold_constraint_integer(syn); r != nil do return r
			if r := fold_constraint_float(syn); r != nil do return r
			if r := fold_constraint_string(syn); r != nil do return r
			if r := fold_constraint_bool(syn); r != nil do return r
			return nil
		}
	}
	// Leftover kinds (unresolved mentions/references, none, invalid): probe each
	// domain in turn as a last resort.
	if r := fold_constraint_integer(t); r != nil do return r
	if r := fold_constraint_float(t); r != nil do return r
	if r := fold_constraint_string(t); r != nil do return r
	if r := fold_constraint_bool(t); r != nil do return r
	return nil
}

// negated : wraps a ^Type in a Negate_Type (to rewrite De Morgan on the fly).
// fold_constraint will re-normalize it (a ~ on a & descends again, etc.).
negated :: proc(t: ^Type) -> ^Type {
	r := new(Type)
	r^ = Negate_Type{t}
	return r
}

// fold_constraint_target folds the value at scope[i] when it is used as a
// constraint. If that value is Unknown (??), the constraint is only resolvable
// when the Unknown's type is a single concrete value: a singleton constraint
// fold becomes that value, anything else stays Unknown (which never satisfies).
fold_constraint_target :: proc(scope: ^Scope_Type, i: int) -> ^Type {
	value := scope.types[i]
	if value != nil {
		if _, is_unknown := value^.(Unknown_Type); is_unknown {
			ty := scope.constraint_folds[i]
			if ty != nil && fold_is_concrete_value(ty) do return ty
			r := new(Type)
			r^ = Unknown_Type{}
			return r
		}
		// A mention chain that cycles back onto itself (a binding referring to
		// itself) can never fold; recursing into it blindly would loop forever.
		// follow's exact-cycle guard detects it: a chase that STOPS on another
		// indirection cycled — unresolvable, nil.
		#partial switch _ in value^ {
		case Mention_Type, Reference_Type:
			res := follow(value)
			if res != nil {
				#partial switch _ in res^ {
				case Mention_Type, Reference_Type:
					return nil
				}
			}
		}
	}
	return fold_constraint(value)
}

// fold_is_unknown reports whether a folded constraint landed on Unknown — the
// marker that the constraint depends on a `??` and is insoluble. nil-safe.
fold_is_unknown :: proc(t: ^Type) -> bool {
	if t == nil do return false
	_, unk := t^.(Unknown_Type)
	return unk
}

// scope_fields_fold_unknown reports whether any field value of a scope-shaped
// constraint folds to Unknown — i.e. the scope does not denote a statically-
// known set (`Shape -> {x -> ??::u8}` used as a constraint is insoluble).
// `key` identifies the scope/carve node on the in-progress stack.
//
// The scan stack (guarding self-referential constraints `A -> {x -> A}` against
// re-entry — the outermost scan decides) lives on the analyzer, not a global, so
// its backing dies with this pass's arena. Reached via current_analyzer().
scope_fields_fold_unknown :: proc(key: ^Type, values: []^Type) -> bool {
	a := current_analyzer()
	if a == nil do return false
	for active in a.scope_scan_stack {
		if active == key do return false
	}
	append(&a.scope_scan_stack, key)
	defer pop(&a.scope_scan_stack)
	for val in values {
		if val == nil do continue
		// A recursive tail — the explicit recursive reference, or a carve over
		// one — is NOT an unknown: the value is constrained by induction, which
		// the satisfy layer consumes level by level against a shrinking value.
		// Folding it here would materialize one clone per scan, forever (each
		// clone repoints a FRESH carve node, so no node-identity guard helps).
		if is_recursive_tail(val) do continue
		if fold_is_unknown(fold_constraint(val)) do return true
	}
	return false
}

// is_recursive_tail reports whether `t` is the marker of a recursive
// constraint: the Recursive_Mention node itself, or a carve whose source is
// one (`...Array{T}` — also after repoint, which clones the carve but never
// rewrites the mention).
is_recursive_tail :: proc(t: ^Type) -> bool {
	if t == nil do return false
	#partial switch v in t^ {
	case Recursive_Mention_Type:
		return true
	case Carve_Type:
		if v.source != nil {
			if _, is_rr := v.source^.(Recursive_Mention_Type); is_rr do return true
		}
	}
	return false
}

satisfy :: proc(fc, ft: ^Type) -> bool {
	if fc == nil || ft == nil do return false
	// A value-side union (`"" | 10`, a mixed Or kept structural because the
	// branches live in different domains) fits the constraint iff EVERY branch
	// does: (A|B) ⊆ C ⟺ A⊆C ∧ B⊆C — the dual of the constraint-side Or below
	// (which is a ||). Same-domain unions already folded to one domain set
	// (Integer_Type with disjoint intervals), so a surviving Or_Type on the
	// value side is exactly the mixed/symbolic case this decomposes.
	if vor, ok := ft^.(Or_Type); ok {
		return satisfy(fc, vor.left) && satisfy(fc, vor.right)
	}
	#partial switch f in fc^ {
	case Recursive_Mention_Type:
		c := fold_constraint(f.match_scope.types[f.match_index])
		return satisfy(c, ft)
	case Compose_Type:
		// A string concatenation `+` kept as a Compose is an ordered SEQUENCE
		// constraint: the value (a concrete string) must split, left to right, into
		// the sequence's segments in order (string_compose_satisfy).
		if f.operator == .Add {
			vt, ok := ft^.(String_Type)
			if !ok do return false
			return string_compose_satisfy(fc, vt)
		}
		return false
	case Range_Type:
		// A three-bound string range kept raw (`"ab".."cd".."ef"`): the value must
		// start with the prefix, contain the middle, and end with the suffix.
		vt, ok := ft^.(String_Type)
		if !ok do return false
		return string_tri_range_satisfy(fc, vt)
	case Integer_Type:
		v, ok := ft^.(Integer_Type)
		return ok && integer_satisfy(f, v)
	case Float_Type:
		v, ok := ft^.(Float_Type)
		return ok && float_satisfy(f, v)
	case String_Type:
		v, ok := ft^.(String_Type)
		return ok && string_satisfy(f, v)
	case Bool_Type:
		v, ok := ft^.(Bool_Type)
		return ok && bool_satisfy(f, v)
	case Scope_Type:
		v, ok := ft^.(Scope_Type)
		if !ok do return false
		return scope_satisfy(f, v)
	case And_Type:
		return satisfy(f.left, ft) && satisfy(f.right, ft)
	case Or_Type:
		return satisfy(f.left, ft) || satisfy(f.right, ft)
	case Negate_Type:
		// value ⊆ ~X  ⟺  value is not in X. Decidable and exact for a concrete
		// value: ~(ends with '_') accepts 'identifier', rejects 'foo_'. Handles the
		// positional/mixed negation that the fold does not expand into intervals.
		return !satisfy(f.operand, ft)
	}
	return false
}

// value_elements returns a scope value's positional elements (its pushed
// bindings), in order — the list a recursive constraint consumes head-first. A
// producer/expand binding is not a positional element and is skipped.
value_elements :: proc(vs: Scope_Type) -> [dynamic]^Type {
	out := make([dynamic]^Type, 0, len(vs.kind))
	for i in 0 ..< len(vs.kind) {
		#partial switch vs.kind[i] {
		case .Pointing_Push:
			append(&out, vs.types[i])
		}
	}
	return out
}

satisfy_root :: proc(fc, ft: ^Type) -> bool {
	c, ok := fc^.(Scope_Type)
	if ok {
		prods := scope_productions(c)
		prod_count := len(prods)
		switch prod_count {
		case 0:
			t, ok := ft^.(Scope_Type)
			if ok {
				return scope_satisfy(c, t)
			}
			return false
		case:
			for i := 0; i < prod_count; i += 1 {
				if satisfy(fold_value_type(prods[i]), ft) {
					return true
				}
			}
		}
	}
	return satisfy(fc, ft)
}


scope_satisfy :: proc(cs, vs: Scope_Type) -> bool {
	return scope_satisfy_range(cs, 0, len(cs.names), vs, 0, len(vs.names))
}

scope_satisfy_range :: proc(cs: Scope_Type, ci, cend: int, vs: Scope_Type, vi, vend: int) -> bool {
	if ci == cend {
		return vi == vend
	}

	if vi >= vend {
		return false
	}

	if !binding_satisfy(cs, ci, vs, vi) {
		return false
	}

	return scope_satisfy_range(cs, ci + 1, cend, vs, vi + 1, vend)
}

binding_satisfy :: proc(cs: Scope_Type, i: int, vs: Scope_Type, j: int) -> bool {
	if cs.names[i] != vs.names[j] || cs.kind[i] != vs.kind[j] {
		return false
	}
	if cs.constraint_folds[i] == nil {
		// A non-production uncolored field (`x -> 1`) only constrains the shape:
		// the field must exist with the matching name/kind (proved above), but its
		// value imposes nothing on the corresponding value field. A production
		// (`-> v`) is not a named field — it IS the constraint, so prove it.
		if cs.kind[i] != .Product {
			return true
		}
		return satisfy(fold_constraint(cs.types[i]), vs.type_folds[j])
	} else {
		v, ok := cs.constraint_folds[i].(Recursive_Mention_Type)
		if (ok) {
			return satisfy_root(
				fold_constraint_target(v.match_scope, v.match_index),
				vs.type_folds[j],
			)
		} else {
			return satisfy_root(cs.constraint_folds[i], vs.type_folds[j])
		}
	}
}

scope_productions :: proc(s: Scope_Type) -> [dynamic]^Type {
	out := make([dynamic]^Type, 0, len(s.kind))
	for i in 0 ..< len(s.kind) {
		if s.kind[i] == .Product do append(&out, s.types[i])
	}
	return out
}

// fold_carve_constraint materializes the carve `t` into its substituted
// Scope_Type as a CONSTRAINT (the left-of-`:` side): the source is peeled
// through fold_carve_constraint, so a nested carve resolves on the constraint
// side. Returns nil when the source can't be reduced to a scope.
fold_carve_constraint :: proc(t: ^Type) -> ^Scope_Type {
	carve, ok := &t^.(Carve_Type)
	if !ok do return nil

	// Resolve the source down to its underlying Scope_Type, peeling nested carves
	// on the CONSTRAINT side.
	src: ^Scope_Type = nil
	cur := follow(carve.source)
	for cur != nil {
		#partial switch &s in cur^ {
		case Scope_Type:
			src = &s
		case Carve_Type:
			src = fold_carve_constraint(cur)
		}
		break
	}
	if src == nil do return nil
	return carve_substitute(t, carve, src)
}
