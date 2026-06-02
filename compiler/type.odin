package compiler

import "core:fmt"

// --- generic fold (domain-agnostic dispatch) ---
//
// fold_type derives the constraint a value *produces* (its envelope): for `5`
// it is `5..5`, for `a + b` the envelope of the sum, for a reference the
// target's. fold_constraint resolves the constraint a binding *imposes*; it
// must reduce to a closed, compile-time-known object. Both return a reduced
// ^Type or nil when the form cannot be resolved statically.
//
// satisfy(fc, ft) proves ft ⊆ fc. These three functions are pure dispatch —
// every domain-specific operation lives in its domain file (fold_integer.odin).
// To add a domain (float, string), give it fold_*_<domain>/<domain>_satisfy/
// <domain>_to_string and add a case here.

// A binding `constraint : … -> value` is checked by matching the *type* of the
// value against the *value* of the constraint:
//
//   - LEFT of `:` (the constraint) folds to its VALUE — the set it denotes.
//     u8 -> Integer_Type{0..255}. That is fold_constraint.
//   - RIGHT of `->` (the value) folds to its TYPE (a typeof). A concrete
//     singleton (10, or 5..5) is its own type: Integer_Type{10,10}. A set
//     (u8, 1..2, >=20) is NOT a value, so its type is the producer scope
//     {-> set}. That is fold_value_type. The value/set split is SEMANTIC:
//     singleton (hi==lo) -> value, otherwise -> producer.
//
// satisfy then proves fold_value_type(value) fits fold_constraint(constraint).

// fold_constraint folds the imposed constraint to the set the value must fall
// into (the LEFT side). A producer scope {-> X} is NOT flattened: its value is
// the producer of fold_constraint(X), mirroring fold_value_type on the right so
// {->u8} (constraint) matches u8 (value). A plain (non-producer) scope keeps
// its shape. Returns nil when it cannot be resolved statically.
fold_constraint :: proc(t: ^Type) -> ^Type {
	if t != nil {
		#partial switch v in t^ {
		case Scope_Type:
			return t
		case Mention_Type:
			if v.match_scope != nil && v.match_index >= 0 {
				return fold_constraint_target(v.match_scope, v.match_index)
			}
		case Reference_Type:
			ref := v.reference
			if ref != nil && ref.match_scope != nil && ref.match_index >= 0 {
				return fold_constraint_target(ref.match_scope, ref.match_index)
			}
		case And_Type:
			// Pure numeric reduction (intersection) if possible — ..9 & 11.. etc.
			// Symbolic otherwise: mixed families (String & Int), positional
			// negation (pattern & ~(ends with '_')), scopes.
			if r := fold_constraint_integer(t); r != nil do return r
			if r := fold_constraint_float(t); r != nil do return r
			if r := fold_constraint_bool(t); r != nil do return r
			r := new(Type)
			r^ = And_Type{fold_constraint(v.left), fold_constraint(v.right)}
			return r
		case Or_Type:
			if r := fold_constraint_integer(t); r != nil do return r
			if r := fold_constraint_float(t); r != nil do return r
			if r := fold_constraint_bool(t); r != nil do return r
			r := new(Type)
			r^ = Or_Type{fold_constraint(v.left), fold_constraint(v.right)}
			return r
		case Negate_Type:
			// De Morgan normalization in the same pass: we push ~ toward the
			// leaves and collapse the ~~. The result stays folded by this same
			// function, so the tree never has a ~ stacked on a &/|/~.
			//   ~~X      → X
			//   ~(A & B) → ~A | ~B
			//   ~(A | B) → ~A & ~B
			// A ~range / ~literal leaf falls into the domain probes below
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
			if r := fold_constraint_integer(t); r != nil do return r
			if r := fold_constraint_float(t); r != nil do return r
			if r := fold_constraint_bool(t); r != nil do return r
			if neg := negate_ordinal_string(v.operand); neg != nil do return neg
			r := new(Type)
			r^ = Negate_Type{fold_constraint(v.operand)}
			return r
		case Integer_Type:
			return fold_constraint_integer(t)
		case Float_Type:
			return fold_constraint_float(t)
		case String_Type:
			return fold_constraint_string(t)
		case Bool_Type:
			return fold_constraint_bool(t)
		}
	}
	// Range_Type / Compose_Type are domain-ambiguous: their family is decided by
	// their operands, not their tag. Try integer, then float, then string, bool.
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
	value := scope.values[i]
	if value != nil {
		if _, is_unknown := value^.(Unknown_Type); is_unknown {
			ty := scope.constraint_folds[i]
			if ty != nil && fold_is_concrete_value(ty) do return ty
			r := new(Type)
			r^ = Unknown_Type{}
			return r
		}
	}
	return fold_constraint(value)
}

// fold_value_type yields the TYPE of a value (the RIGHT side, a typeof).
// Singleton -> the value itself; any wider set -> the producer scope {-> set}.
fold_value_type :: proc(t: ^Type) -> ^Type {
	// A producer scope {-> X} on the right is itself a value of a higher meta
	// level: its type is the producer of fold_value_type(X). This mirrors
	// fold_constraint on the left so {->X} matches across sides.
	if t != nil {
		#partial switch v in t^ {
		case Scope_Type:
			prods := scope_productions(v)
			if len(prods) > 0 {
				folded := make([dynamic]^Type, 0, len(prods))
				for p in prods {
					fp := fold_value_type(p)
					if fp == nil do return nil
					append(&folded, fp)
				}
				return make_producer_scope_multi(folded[:])
			}
			// Structural scope (named bindings, no production): its type is
			// itself — its bindings already carry their folds from analysis.
			// scope_satisfy compares each binding's constraint against value.
			return t
		case Mention_Type:
			if v.match_scope != nil && v.match_index >= 0 {
				return fold_value_type(v.match_scope.values[v.match_index])
			}
		case Reference_Type:
			ref := v.reference
			if ref != nil && ref.match_scope != nil && ref.match_index >= 0 {
				return fold_value_type(ref.match_scope.values[ref.match_index])
			}
		case Integer_Type:
			return value_type_envelope(fold_type_integer(t))
		case Float_Type:
			return value_type_envelope(fold_type_float(t))
		case String_Type:
			return value_type_envelope(fold_type_string(t))
		case Bool_Type:
			return value_type_envelope(fold_type_bool(t))
		}
	}
	// Range/Compose/Negate are domain-ambiguous (family decided by operands),
	// and sets built with ~ | & only resolve through the constraint fold — so
	// probe each domain in turn.
	env := fold_type_integer(t)
	if env == nil do env = fold_constraint_integer(t)
	if env == nil do env = fold_type_float(t)
	if env == nil do env = fold_constraint_float(t)
	if env == nil do env = fold_type_string(t)
	if env == nil do env = fold_constraint_string(t)
	if env == nil do env = fold_type_bool(t)
	if env == nil do env = fold_constraint_bool(t)
	return value_type_envelope(env)
}

// value_type_envelope wraps a folded numeric envelope as a typeof: a singleton
// is its own value, any wider set becomes the producer scope {-> set}.
value_type_envelope :: proc(env: ^Type) -> ^Type {
	if env == nil do return nil
	if fold_is_concrete_value(env) do return env
	return make_producer_scope(env)
}

// fold_is_concrete_value reports whether a folded ^Type denotes one concrete
// value (a singleton) rather than a set/range. Domain dispatch.
fold_is_concrete_value :: proc(t: ^Type) -> bool {
	if t == nil do return false
	#partial switch v in t^ {
	case Integer_Type:
		return integer_intervals_is_concrete(v.integer_intervals)
	case Float_Type:
		return float_intervals_is_concrete(v.float_intervals)
	case String_Type:
		return string_is_concrete(v)
	case Bool_Type:
		return bool_is_concrete(v)
	}
	return false
}

// make_producer_scope builds the scope {-> produces} — the type of a set, one
// meta level up. Reuses Scope_Type (a single .Product binding).
make_producer_scope :: proc(produces: ^Type) -> ^Type {
	if produces == nil do return nil
	return make_producer_scope_multi([]^Type{produces})
}

// make_producer_scope_multi builds a producer scope with one .Product binding
// per element of produces (preserving order).
make_producer_scope_multi :: proc(produces: []^Type) -> ^Type {
	scope := new(Scope_Type)
	for p in produces {
		append(&scope.names, "")
		append(&scope.types, nil)
		append(&scope.kind, Binding_Kind.Product)
		append(&scope.values, p)
		append(&scope.type_folds, nil)
		append(&scope.constraint_folds, nil)
	}
	r := new(Type)
	r^ = scope^
	return r
}

// satisfy proves the folded value ft (a typeof) fits the folded constraint fc.
// fc is on the LEFT, ft on the RIGHT — mirroring the language, where the
// constraint sits left of `:` and the value right of `->`.
//
//   - fc Integer_Type vs ft Integer_Type : a concrete value against a set →
//     membership (10 ∈ u8). u8:a -> 10 ✅.
//   - fc Integer_Type vs ft Scope (producer) : a set is not a member of a set →
//     fail. u8:a -> u8 ❌ (u8 is not of type u8).
//   - fc Scope vs ft Scope : two producers → match their productions in order.
//     {->u8}:a -> u8 ✅.
satisfy :: proc(fc, ft: ^Type) -> bool {
	if fc == nil || ft == nil do return false
	#partial switch f in fc^ {
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

satisfy_root :: proc(fc, ft: ^Type) -> bool {
	v, ok := fc^.(Scope_Type)
	if ok {
		hasProd := false
		// A constraint root with productions is a sum: the value satisfies it
		// if it matches AT LEAST ONE production. Each production IS the target
		// constraint (the content the value must be). The value fold ft carries
		// one extra producer level for sets ({->u8}) but not for singletons
		// (10) — so compare the production against ft's content: ft's own
		// production when ft is a producer, ft itself otherwise.
		ft_content := ft
		if vt, vt_ok := ft^.(Scope_Type); vt_ok {
			prods := scope_productions(vt)
			if len(prods) == 1 do ft_content = prods[0]
		}
		for i := 0; i < len(v.kind); i += 1 {

			if (v.kind[i] == .Product) {
				hasProd = true
				if (satisfy(v.values[i], ft_content)) {
					return true
				}
			}
		}
		if (hasProd) {
			return false
		}
	}
	return satisfy(fc, ft)
}


scope_satisfy :: proc(cs, vs: Scope_Type) -> bool {
	if len(vs.names) != len(cs.names) do return false
	for i in 0 ..< len(cs.names) {
		if vs.names[i] != cs.names[i] do return false
		if vs.kind[i] != cs.kind[i] do return false

		if cs.kind[i] == .Product {
			// Producer binding: match the produced CONTENT, not just shape —
			// a producer of u8 ({->u8}) must not satisfy a producer of a
			// producer ({->{->u8}}).
			if !satisfy(cs.values[i], vs.values[i]) do return false
			continue
		}

		// Structural binding (named): structural coloring. The constraint
		// colored onto cs's binding (u8 on x) must be satisfied by vs's value
		// (10 on x). Each side carries its fold from analysis: cs the
		// constraint fold, vs the value type fold. A side with no constraint
		// (plain `x -> 10`) imposes nothing → skip.
		cc := i < len(cs.constraint_folds) ? cs.constraint_folds[i] : nil
		if cc == nil do continue
		vt := i < len(vs.type_folds) ? vs.type_folds[i] : nil
		if !satisfy_root(cc, vt) do return false
	}
	return true
}

scope_productions :: proc(s: Scope_Type) -> [dynamic]^Type {
	out := make([dynamic]^Type, 0, len(s.kind))
	for i in 0 ..< len(s.kind) {
		if s.kind[i] == .Product do append(&out, s.values[i])
	}
	return out
}

// ===========================================================================
// DEFAULT — the concrete value a constraint produces when no value is given
// (`u8:a` → a equals 0). The default is ALWAYS computed on the final fold
// intervals, never on the raw structure: ~10, ..9|11.. and ~(~10&~20) follow the
// same path and yield consistent defaults.
// ===========================================================================

// default_value : the concrete value to lay down when a binding has no `->`.
// Follows the scope/carve down to a production, then materializes its default.
default_value :: proc(t: ^Type) -> ^Type {
	if t == nil do return t
	target := follow(t)
	cur := target
	for {
		#partial switch &v in cur^ {
		case Scope_Type:
			for i := 0; i < len(v.kind); i += 1 {
				if v.kind[i] == .Product {
					def := type_default(v.values[i])
					if def != nil do return def
					return v.values[i]
				}
			}
			return t
		case Carve_Type:
			if v.source != nil {
				cur = follow(v.source)
				continue
			}
		}
		break
	}
	def := type_default(target)
	if def != nil do return def
	return t
}

// type_default : materializes the default of a type into a concrete value.
// We fold the constraint into intervals (which recursively reduces Range / And /
// Or / Negate / Compose, and computes the default_value of the set), then read
// that default_value. No reading of raw structure: the syntax has no effect.
type_default :: proc(t: ^Type) -> ^Type {
	if t == nil do return nil
	// Mention/Reference : the default is that of the targeted value.
	#partial switch v in t^ {
	case Mention_Type:
		if v.match_scope != nil && v.match_index >= 0 {
			return type_default(v.match_scope.values[v.match_index])
		}
	case Reference_Type:
		if v.reference != nil && v.reference.match_scope != nil && v.reference.match_index >= 0 {
			return type_default(v.reference.match_scope.values[v.reference.match_index])
		}
	}
	// Domains: we fold into intervals and read the default_value computed on them.
	if folded := fold_constraint_integer(t); folded != nil {
		if it, ok := folded^.(Integer_Type); ok {
			if d, ok2 := it.default_value.(i128); ok2 {
				r := new(Type)
				r^ = make_int_const(d)
				return r
			}
		}
	}
	if folded := fold_constraint_float(t); folded != nil {
		if ft, ok := folded^.(Float_Type); ok {
			if d, ok2 := ft.default_value.(f64); ok2 {
				r := new(Type)
				r^ = make_float_const(d)
				return r
			}
		}
	}
	if folded := fold_constraint_string(t); folded != nil {
		if st, ok := folded^.(String_Type); ok {
			if d, ok2 := st.default_value.(string); ok2 {
				r := new(Type)
				r^ = make_string_const(d, st.default_quotation)
				return r
			}
		}
	}
	if folded := fold_constraint_bool(t); folded != nil {
		// The default of a boolean domain is its first source term, materialized
		// as a concrete boolean value. The empty set folds to None (handled above).
		if bt, ok := folded^.(Bool_Type); ok {
			r := new(Type)
			r^ = make_bool_const(bt.default)
			return r
		}
	}
	return nil
}

fold_compose :: proc(a: ^Analyzer, t: ^Type, node: Node_Index) {
	if t == nil do return
	comp, ok := &t^.(Compose_Type)
	if !ok do return
	// fold_compose stores the raw numeric envelope of the arithmetic (a value),
	// not its typeof — the envelope is consumed by further interval arithmetic.
	folded := fold_type_integer(t)
	if folded == nil do folded = fold_type_float(t)
	if folded == nil do folded = fold_type_string(t)
	if folded != nil {
		comp.type_fold = folded
		return
	}
	// The fold failed. Hand off to the diagnostic layer, which inspects the
	// operands and emits a precise, author-facing explanation (incompatible
	// families, mismatched float colors, non-numeric operand, …).
	diagnose_compose(a, comp^, node)
}

fold_range :: proc(a: ^Analyzer, t: ^Type, node: Node_Index) {
	if t == nil do return
	range, ok := t^.(Range_Type)
	if !ok do return

	left_resolved := follow(range.left)
	right_resolved := follow(range.right)

	left_kind := range_operand_kind(left_resolved)
	right_kind := range_operand_kind(right_resolved)

	if left_kind == .Invalid {
		sem_error(
			a,
			fmt.tprintf("invalid range: left bound %s is not an integer, float, or string", describe_value(left_resolved)),
			.Invalid_Range,
			node_pos(a, node),
		)
		return
	}
	if right_kind == .Invalid {
		sem_error(
			a,
			fmt.tprintf("invalid range: right bound %s is not an integer, float, or string", describe_value(right_resolved)),
			.Invalid_Range,
			node_pos(a, node),
		)
		return
	}

	if left_kind != .None && right_kind != .None && left_kind != right_kind {
		sem_error(
			a,
			fmt.tprintf(
				"invalid range %s..%s: both bounds must be the same family",
				describe_value(left_resolved),
				describe_value(right_resolved),
			),
			.Invalid_Range,
			node_pos(a, node),
		)
	}
}

Range_Operand_Kind :: enum {
	None,
	Integer,
	Float,
	String,
	Invalid,
}


range_operand_kind :: proc(t: ^Type) -> Range_Operand_Kind {
	if t == nil do return .None
	#partial switch v in t^ {
	case Integer_Type:
		return .Integer
	case Float_Type:
		return .Float
	case String_Type:
		return .String
	case None_Type:
		return .Invalid
	case Range_Type:
		// Chained range (`10..0..30`) : the family is that of its bounds. If both
		// bounds are themselves invalid scalars, the sub-range is invalid; but an
		// INTERNAL family inconsistency (`0..30.0`) has already been reported by the
		// sub-range's own fold_range call — we do not re-report it to the parent, we
		// return its representative family (that of left, the default) so as not to
		// produce a misleading "right bound not a ..." message.
		lk := range_operand_kind(follow(v.left))
		rk := range_operand_kind(follow(v.right))
		if lk == .Invalid && rk == .Invalid do return .Invalid
		if lk == .None do return rk
		if rk == .None do return lk
		if lk == .Invalid do return rk
		if rk == .Invalid do return lk
		return lk
	case Scope_Type:
		for i := 0; i < len(v.kind); i += 1 {
			if v.kind[i] == .Product {
				return range_operand_kind(v.values[i])
			}
		}
		return .Invalid
	case Mention_Type:
		if v.match_scope != nil && v.match_index >= 0 {
			return range_operand_kind(v.match_scope.values[v.match_index])
		}
		return .Invalid
	case Reference_Type:
		if v.reference != nil && v.reference.match_scope != nil && v.reference.match_index >= 0 {
			return range_operand_kind(v.reference.match_scope.values[v.reference.match_index])
		}
		return .Invalid
	}
	return .Invalid
}


range_kind_name :: #force_inline proc(kind: Range_Operand_Kind) -> string {
	switch kind {
	case .Integer:
		return "Integer"
	case .Float:
		return "Float"
	case .String:
		return "String"
	case .None:
		return "none"
	case .Invalid:
		return "invalid"
	}
	return "unknown"
}
