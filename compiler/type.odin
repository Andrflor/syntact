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

// reference_effective_value resolves the VALUE a Reference_Type denotes, honoring
// a carve in its target. A property reference `C.x` carries target = `C` (the
// carve) and a reference site pointing at the ORIGINAL field in the source scope.
// Reading the site directly yields the pre-carve value (5), missing the override
// (10). So when the target resolves to a carve that overrides this exact field,
// return the override's value instead — mirroring reduce_value's Reference case.
reference_effective_value :: proc(v: Reference_Type) -> ^Type {
	ref := v.reference
	if ref == nil || ref.match_scope == nil || ref.match_index < 0 do return nil
	original := ref.match_scope.values[ref.match_index]
	if v.target != nil {
		cur := follow(v.target)
		if cur != nil {
			#partial switch &cv in cur^ {
			case Carve_Type:
				for i := 0; i < len(cv.references); i += 1 {
					if cv.references[i].match_index == ref.match_index {
						return cv.values[i]
					}
				}
			}
		}
	}
	return original
}

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
		case Carve_Type:
			// A carve used as a constraint folds to its substituted scope.
			sub := fold_carve(t)
			if sub == nil do return nil
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
			// scope with no production collapses to `none`.
			prod, resolved := execute_production(v.target)
			if prod == nil {
				if resolved do return new_type(None_Type{})
				return nil
			}
			return fold_constraint(prod)
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
		case Cast_Type:
			// The envelope a `::` produces is exactly its target — the cast forces
			// the value into the target's layout, so the result always lands there.
			if v.type_fold != nil do return fold_constraint(v.type_fold)
			return fold_constraint(v.target)
		case Pattern_Type:
			// A pattern as a constraint resolves to ONE branch — the first whose
			// match the target satisfies (see fold_constraint_pattern).
			return fold_constraint_pattern(t)
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
		case Carve_Type:
			// A carve folds to the substituted scope, then to that scope's type.
			sub := fold_carve(t)
			if sub == nil do return nil
			st := new(Type)
			st^ = sub^
			return fold_value_type(st)
		case Mention_Type:
			if v.match_scope != nil && v.match_index >= 0 {
				return fold_value_type(v.match_scope.values[v.match_index])
			}
		case Reference_Type:
			eff := reference_effective_value(v)
			if eff != nil do return fold_value_type(eff)
		case Execute_Type:
			// `target!` produces the value of the production the collapse reduces
			// through (the first .Product of the target). A scope with no
			// production collapses to `none`.
			prod, resolved := execute_production(v.target)
			if prod == nil {
				if resolved do return new_type(None_Type{})
				return nil
			}
			return fold_value_type(prod)
		case Integer_Type:
			return value_type_envelope(fold_type_integer(t))
		case Float_Type:
			return value_type_envelope(fold_type_float(t))
		case String_Type:
			return value_type_envelope(fold_type_string(t))
		case Bool_Type:
			return value_type_envelope(fold_type_bool(t))
		case Cast_Type:
			// A cast's value type is its concrete folded result when the source was
			// concrete, otherwise the target itself — the cast forces the value into
			// the target's layout, so the target IS the value's envelope (not wrapped
			// in a producer scope: it already denotes the set the value lives in).
			if v.type_fold != nil do return fold_value_type(v.type_fold)
			return fold_constraint(v.target)
		case Compose_Type:
			// An arithmetic expression (`a+b`, `a*b`, …) is a computed VALUE, not a
			// reified type: its envelope is the set of results it can produce, and
			// the proof is `envelope ⊆ constraint` (constraints.md: `u8 + u8` ∈ u16).
			// So return the numeric envelope directly, UNWRAPPED — mirroring Cast_Type
			// above. Wrapping it in a producer scope would make a perfectly-bounded
			// `0..510` fail to satisfy a widened `u16` by the self-match rule, which
			// is exactly what we must avoid. (String/bool composes have no interval
			// envelope; they fall through to the domain probes below.)
			if env := fold_type_integer(t); env != nil do return env
			if env := fold_type_float(t); env != nil do return env
		case Pattern_Type:
			// A pattern as a value resolves to the COMBINED type of every reachable
			// branch (an Or of their products — see fold_type_pattern).
			return fold_type_pattern(t)
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
	// A union on the VALUE side (ft) — a type `a | b` satisfies the constraint fc
	// iff BOTH a and b do (every value the union can take must fall inside fc). This
	// mirrors the Or case on the constraint side below, but conjunctively. Checked
	// first so it applies whatever fc is (e.g. a pattern's combined product type
	// `"" | 10` proving against the color `"" | 10`).
	if vor, ok := ft^.(Or_Type); ok {
		return satisfy(fc, vor.left) && satisfy(fc, vor.right)
	}
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
				// The production may be stored RAW (a Range_Type `0..`, a Mention,
				// …) when the producer scope was not built by a fold — e.g. the
				// literal `{->0..}`. fold_constraint normalizes it to its domain set
				// (0..inf) so the comparison below is interval-against-interval, not
				// Range-against-Integer (which `satisfy` cannot match). A builtin
				// like `u8` is already an Integer, so folding is idempotent there.
				prod := fold_constraint(v.values[i])
				if prod == nil do prod = v.values[i]
				if (satisfy(prod, ft_content)) {
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

// execute_production resolves the target of a collapse (`target!`) down to the
// FIRST production it reduces through, mirroring reduce()/execute(): follow the
// target to a scope (peeling a carve), then return its first .Product value.
//
// `resolved` distinguishes the two empty cases for the caller: when the target
// resolves to a scope but that scope has NO production, the collapse yields
// `none` (resolved=true, prod=nil); when the target does not resolve to a scope
// at all, the collapse cannot be folded statically (resolved=false).
execute_production :: proc(t: ^Type) -> (prod: ^Type, resolved: bool) {
	cur := follow(t)
	for cur != nil {
		#partial switch &v in cur^ {
		case Scope_Type:
			for i := 0; i < len(v.kind); i += 1 {
				if v.kind[i] == .Product do return v.values[i], true
			}
			return nil, true
		case Carve_Type:
			sub := fold_carve(cur)
			if sub == nil do return nil, false
			for i := 0; i < len(sub.kind); i += 1 {
				if sub.kind[i] == .Product do return sub.values[i], true
			}
			return nil, true
		}
		break
	}
	return nil, false
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
	case Or_Type:
		// The default of a union is the default of its FIRST term (the left branch),
		// recursively. This is the only rule that spans families: `(u8|string)`
		// defaults to 0 (the u8), `(string|u8)` to "" (the string) — the single-
		// domain folds below cannot reduce a cross-family union, so we must pick the
		// first term here. (A same-family union folds fine below too, and its first
		// finite bound coincides with the left term's default, so this is consistent.)
		if d := type_default(v.left); d != nil do return d
		if d := type_default(v.right); d != nil do return d
	case Negate_Type:
		// The default of a STRING negation is the first string that does NOT match
		// the negated operand. Strings are ordered shortest-first, so try "", then
		// "a", "aa", … and pick the first one outside the operand. (Integer/char
		// negations fold into intervals below and have a numeric default; this only
		// kicks in when the operand is a positional string pattern that does not
		// fold — `~"piro"` → "".)
		inner := fold_constraint(v.operand)
		if inner != nil {
			if _, is_str := inner^.(String_Type); is_str {
				candidates := []string{"", "a", "aa", "b"}
				for cand in candidates {
					cv := new(Type)
					cv^ = make_string_const(cand, .double)
					if !satisfy(inner, cv) {
						return cv
					}
				}
			}
		}
	}
	// Domains: we fold into intervals and read the default_value computed on them.
	if folded := fold_constraint_integer(t); folded != nil {
		if it, ok := folded^.(Integer_Type); ok {
			// An integer fold with no intervals is the EMPTY SET (`~(~10|~20)` =
			// {10}&{20} = ∅): nothing satisfies it, so its default is `none`.
			if len(it.integer_intervals) == 0 {
				return new_type(None_Type{})
			}
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

// fold_cast resolves a `value :: target` raw binary reinterpret-cast. The cast
// is domain-agnostic: it extracts the source value's raw bit pattern (integer
// two's-complement, IEEE-754 float bits, bool 0/1, string/char bytes — all
// little-endian), pads/cuts those bits to the target's width (zero/sign-extend
// per the source signedness, truncate the high bits when narrowing), then
// reinterprets the resulting pattern under the target domain. The result always
// lands inside the target, so `::` never raises a Constraint_Mismatch — it can
// only fail statically with Invalid_Cast when the TARGET has no binary layout (a
// non-zero-based range like 10..37, an open range `>10`, a sum/product, or
// unbounded int/float). When the source is a single concrete value, fold_cast
// computes the exact reinterpreted value into `type_fold`; otherwise type_fold
// stays nil and the constraint/value folds fall back to the target envelope.
fold_cast :: proc(a: ^Analyzer, t: ^Type, node: Node_Index) {
	if t == nil do return
	cast_t, ok := &t^.(Cast_Type)
	if !ok do return

	target_fold := fold_constraint(cast_t.target)
	target, has_layout := cast_target(target_fold)
	if !has_layout {
		sem_error(
			a,
			fmt.tprintf(
				"invalid cast: %s has no binary layout to cast into (the target must be a fixed-width type like u8/i32/f64/bool/char or a string, not an open range, union, or unbounded int/float)",
				describe_value(target_fold),
			),
			.Invalid_Cast,
			node_pos(a, node),
		)
		return
	}

	// Concrete-source fast path: extract its bits and reinterpret into the target.
	// A value bound under a sized float color (`f32:a -> 1.0`) carries that width
	// in its CONSTRAINT, not its (unsized) value fold — pass the constraint so the
	// extractor can recolor the bits to the source's real width.
	src_fold := fold_value_type(cast_t.value)
	src_color := source_color(cast_t.value)
	if repr, is_concrete := cast_to_bits(src_fold, src_color); is_concrete {
		result := cast_from_bits(repr, target)
		if result != nil do cast_t.type_fold = result
	}
}

// Cast_Target_Kind names the domain a `::` lands in. Each carries the layout
// needed to lay bits back down.
Cast_Target_Kind :: enum {
	Integer,
	Float,
	Bool,
	String,
}

Cast_Target :: struct {
	kind:       Cast_Target_Kind,
	width:      uint,      // bit width for Integer/Float/Bool; ignored for String
	signed:     bool,      // Integer signedness
	float_kind: FloatKind, // for Float (f32 -> 32 bits, f64 -> 64 bits)
}

// cast_target derives the target domain + binary layout of a folded constraint,
// if it has one. Fixed-width integer builtins, f32/f64, bool, and string qualify;
// open ranges, arbitrary intervals, unions, and unbounded int/float do not.
cast_target :: proc(target_fold: ^Type) -> (Cast_Target, bool) {
	if target_fold == nil do return {}, false
	#partial switch v in target_fold^ {
	case Integer_Type:
		if len(v.integer_intervals) == 1 {
			if lay, ok := int_layout(v.integer_intervals[0]); ok {
				return {kind = .Integer, width = lay.bits, signed = lay.signed}, true
			}
		}
	case Float_Type:
		// Only the sized colors (f32/f64) have a layout; unsized `float` does not.
		switch v.kind {
		case .f32:
			return {kind = .Float, width = 32, float_kind = .f32}, true
		case .f64:
			return {kind = .Float, width = 64, float_kind = .f64}, true
		case .none:
		}
	case Bool_Type:
		// bool is a 1-bit domain; we lay it down in a byte's worth of pattern.
		return {kind = .Bool, width = 8}, true
	case String_Type:
		// A string target has no fixed width — it absorbs the source bytes as is.
		return {kind = .String}, true
	}
	return {}, false
}

// source_color resolves the COLOR (declared constraint) of a cast's source
// expression — distinct from its value. For `u8:a -> 65`, the value of `a` folds
// to 65 but its color is u8; the raw cast needs the color to know the source's
// bit width. Follows a Mention/Reference to its binding's `constraint_folds`
// slot; for a non-reference expression it falls back to its constraint fold.
source_color :: proc(value: ^Type) -> ^Type {
	if value == nil do return nil
	#partial switch v in value^ {
	case Mention_Type:
		if v.match_scope != nil && v.match_index >= 0 {
			cf := v.match_scope.constraint_folds[v.match_index]
			if cf != nil do return cf
		}
	case Reference_Type:
		ref := v.reference
		if ref != nil && ref.match_scope != nil && ref.match_index >= 0 {
			cf := ref.match_scope.constraint_folds[ref.match_index]
			if cf != nil do return cf
		}
	}
	return fold_constraint(value)
}

// colored_float_kind reads the FloatKind of a folded constraint (f32/f64), or
// .none if the constraint is not a sized float. Peels a producer scope `{->X}`
// that fold_constraint may wrap a value-typed color in.
colored_float_kind :: proc(color: ^Type) -> FloatKind {
	c := unwrap_producer(color)
	if c == nil do return .none
	#partial switch v in c^ {
	case Float_Type:
		return v.kind
	}
	return .none
}

// colored_int_layout reads the fixed-width layout of a folded int constraint.
colored_int_layout :: proc(color: ^Type) -> (Int_Layout, bool) {
	c := unwrap_producer(color)
	if c == nil do return {}, false
	#partial switch v in c^ {
	case Integer_Type:
		if len(v.integer_intervals) == 1 {
			return int_layout(v.integer_intervals[0])
		}
	}
	return {}, false
}

// unwrap_producer peels a single producer scope `{-> X}` down to X. fold_constraint
// of a value-typed binding can yield such a wrapper around the real domain leaf.
unwrap_producer :: proc(t: ^Type) -> ^Type {
	if t == nil do return nil
	#partial switch v in t^ {
	case Scope_Type:
		prods := scope_productions(v)
		if len(prods) == 1 do return prods[0]
	}
	return t
}

// cast_to_bits extracts the raw little-endian bit pattern of a concrete value of
// any domain, plus its source width/signedness (used to extend or truncate).
// `src_color` is the source's folded constraint, consulted when the value fold is
// unsized (a bare literal under a sized color): `f32:a -> 1.0` carries f32 in its
// constraint, so the float case reads its width from there. Returns ok=false when
// the source is not a single concrete value.
cast_to_bits :: proc(src_fold: ^Type, src_color: ^Type = nil) -> (Bit_Repr, bool) {
	if src_fold == nil do return {}, false
	#partial switch v in src_fold^ {
	case Integer_Type:
		if int_is_concrete(v) {
			width: uint = 128
			signed := true
			// Prefer the value's own builtin width; fall back to the constraint
			// color for a bare literal under a sized int (`u8:a -> 65`).
			if len(v.integer_intervals) == 1 {
				if lay, ok := int_layout(v.integer_intervals[0]); ok {
					width, signed = lay.bits, lay.signed
				} else if lay2, ok2 := colored_int_layout(src_color); ok2 {
					width, signed = lay2.bits, lay2.signed
				}
			}
			return {bits = transmute(u128)int_value(v), width = width, signed = signed}, true
		}
	case Float_Type:
		if float_is_concrete(v) {
			val := float_value(v)
			// Prefer the value's own color; fall back to the constraint color for
			// an unsized literal bound under f32/f64.
			kind := v.kind
			if kind == .none do kind = colored_float_kind(src_color)
			switch kind {
			case .f32:
				return {bits = u128(transmute(u32)f32(val)), width = 32, signed = false, from_float = val}, true
			case .f64, .none:
				// An unsized literal carries f64 bits.
				return {bits = u128(transmute(u64)val), width = 64, signed = false, from_float = val}, true
			}
		}
	case Bool_Type:
		if bool_is_concrete(v) {
			b: u128 = bool_value(v) ? 1 : 0
			return {bits = b, width = 8, signed = false}, true
		}
	case String_Type:
		if string_is_concrete(v) {
			s := string_value(v)
			// Little-endian: first byte is the low-order byte. Cap at 16 bytes
			// (128 bits) — wider strings keep their low 16 bytes.
			bits: u128 = 0
			n := min(len(s), 16)
			for i := 0; i < n; i += 1 {
				bits |= u128(s[i]) << uint(8 * i)
			}
			return {bits = bits, width = uint(8 * len(s)), signed = false}, true
		}
	}
	return {}, false
}

// cast_from_bits resizes a source bit pattern to the target width and lays it
// back down in the target domain, producing a concrete ^Type. Returns nil when
// the result cannot be materialized.
cast_from_bits :: proc(repr: Bit_Repr, target: Cast_Target) -> ^Type {
	r := new(Type)
	switch target.kind {
	case .Integer:
		val := bits_reinterpret_int(repr, target.width, target.signed)
		r^ = make_int_result(val)
	case .Float:
		// float -> float is a VALUE conversion (IEEE rounding), not a bit
		// transmute: f64 1.0 :: f32 -> 1.0f. Other sources (int/bool/string) are
		// reinterpreted bit-for-bit into the target float's layout.
		if fv, is_float := repr.from_float.(f64); is_float {
			switch target.float_kind {
			case .f32:
				r^ = make_float_result(f64(f32(fv)), .f32)
			case .f64, .none:
				r^ = make_float_result(fv, .f64)
			}
		} else {
			bits := resize_bits(repr.bits, repr.width, repr.signed, target.width)
			switch target.float_kind {
			case .f32:
				f := f64(transmute(f32)u32(bits & 0xFFFFFFFF))
				r^ = make_float_result(f, .f32)
			case .f64, .none:
				f := transmute(f64)u64(bits)
				r^ = make_float_result(f, .f64)
			}
		}
	case .Bool:
		// Any non-zero pattern reads as true; zero reads as false.
		bits := resize_bits(repr.bits, repr.width, repr.signed, target.width)
		r^ = make_bool_const(bits != 0)
	case .String:
		// Reinterpret the source bytes (little-endian) back into a string.
		bits := repr.bits
		n := (repr.width + 7) / 8
		buf := make([]u8, n)
		for i: uint = 0; i < n; i += 1 {
			buf[i] = u8((bits >> uint(8 * i)) & 0xFF)
		}
		r^ = make_string_const(string(buf), .double)
	}
	return r
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

// ===========================================================================
// CARVE — fold a carve to the substituted scope it derives.
//
// `source{ name -> v, … }` is resolved by materializing the override: copy the
// source scope, write each override value into the field it targets, then
// REPOINT every reference that named the source scope so it names the copy
// instead. Because references are (match_scope, match_index), repointing the
// scope pointer is enough — a sibling mention `z -> x` now reads the copy's new
// x, so the substitution cascades for free, including transitively (`y -> z -> x`).
// The folds are stale on the copy (values changed); the caller re-typechecks.
//
// fold_carve is PURE: it builds and returns the substituted scope (or nil if the
// source does not resolve to a scope). The Constraint_Mismatch is raised by the
// analyzer (walk_carve), which holds the source position — type.odin answers
// yes/no, analyze.odin explains why. Used by fold_type and fold_constraint.
// ===========================================================================

// fold_carve materializes the carve `t` into its substituted Scope_Type, or nil
// when the source can't be reduced to a scope.
fold_carve :: proc(t: ^Type) -> ^Scope_Type {
	carve, ok := &t^.(Carve_Type)
	if !ok do return nil

	// Resolve the source down to its underlying Scope_Type, peeling nested carves.
	src: ^Scope_Type = nil
	cur := follow(carve.source)
	for cur != nil {
		#partial switch &s in cur^ {
		case Scope_Type:
			src = &s
		case Carve_Type:
			// A carve of a carve: fold the inner one first so we substitute onto
			// the already-substituted scope.
			src = fold_carve(cur)
		}
		break
	}
	if src == nil do return nil

	copy := scope_clone(src)

	// Apply each override: write the new value into the field it targets, and
	// refresh its cached type_fold — the integer/float/... folders read a
	// mention's fold from the SCOPE's type_folds, not by re-folding its value,
	// so a stale fold here would hide the substitution from sibling mentions.
	for i in 0 ..< len(carve.references) {
		ref := carve.references[i]
		if ref.match_index >= 0 && ref.match_index < len(copy.values) {
			copy.values[ref.match_index] = carve.values[i]
			if ref.match_index < len(copy.type_folds) {
				copy.type_folds[ref.match_index] = fold_value_type(carve.values[i])
			}
		}
	}

	// Repoint every reference that named the source scope so it names the copy:
	// sibling mentions now read the substituted values, cascading transitively.
	for i in 0 ..< len(copy.values) {
		copy.values[i] = repoint(copy.values[i], src, copy)
	}

	// Refresh the cached fold of every DEPENDENT field — one whose value still
	// references another field (`y -> x+1`). After repointing, its value reads the
	// substituted `x`, but its type_fold still holds the pre-carve result; recompute
	// it so the materialized default (and any sibling reading it) sees `y = 101`.
	// Overridden fields were already refreshed above; concrete values are unchanged
	// by repoint, so re-folding them is harmless.
	overridden := make(map[int]bool)
	for ref in carve.references do overridden[ref.match_index] = true
	for i in 0 ..< len(copy.values) {
		if overridden[i] do continue
		if i < len(copy.type_folds) {
			if nf := fold_value_type(copy.values[i]); nf != nil {
				copy.type_folds[i] = nf
			}
		}
	}

	return copy
}

// scope_clone copies a scope's columns into a fresh Scope_Type so overrides and
// repointing don't mutate the shared source. The element ^Types are shared until
// repoint() copies-on-write the ones it actually rewrites; parent is preserved.
scope_clone :: proc(src: ^Scope_Type) -> ^Scope_Type {
	dst := new(Scope_Type)
	dst.parent = src.parent
	for n in src.names do append(&dst.names, n)
	for ty in src.types do append(&dst.types, ty)
	for k in src.kind do append(&dst.kind, k)
	for v in src.values do append(&dst.values, v)
	for f in src.type_folds do append(&dst.type_folds, f)
	for f in src.constraint_folds do append(&dst.constraint_folds, f)
	return dst
}

// repoint rewrites, copy-on-write, every Mention/Reference inside `t` whose
// match_scope is `old` to point at `dst` instead, descending through composite
// types and nested scopes. A node is cloned only when a descendant changed, so
// the source's ^Types are never mutated and unchanged subtrees stay shared.
repoint :: proc(t: ^Type, old, dst: ^Scope_Type) -> ^Type {
	if t == nil do return t
	#partial switch &v in t^ {
	case Mention_Type:
		if v.match_scope == old {
			return new_type(Mention_Type{v.name, dst, v.match_index})
		}
	case Reference_Type:
		// Repoint the resolved site and the target expression it was reached through.
		ref := v.reference
		nt := repoint(v.target, old, dst)
		if ref != nil && ref.match_scope == old {
			nref := new(Reference)
			nref^ = Reference{ref.name, ref.index, dst, ref.match_index}
			return new_type(Reference_Type{nt, nref})
		}
		if nt != v.target {
			return new_type(Reference_Type{nt, ref})
		}
	case Compose_Type:
		l := repoint(v.left, old, dst)
		r := repoint(v.right, old, dst)
		if l != v.left || r != v.right {
			return new_type(Compose_Type{l, r, v.operator, nil})
		}
	case Or_Type:
		l := repoint(v.left, old, dst)
		r := repoint(v.right, old, dst)
		if l != v.left || r != v.right {
			return new_type(Or_Type{l, r})
		}
	case And_Type:
		l := repoint(v.left, old, dst)
		r := repoint(v.right, old, dst)
		if l != v.left || r != v.right {
			return new_type(And_Type{l, r})
		}
	case Range_Type:
		l := repoint(v.left, old, dst)
		r := repoint(v.right, old, dst)
		if l != v.left || r != v.right {
			return new_type(Range_Type{l, r})
		}
	case Negate_Type:
		o := repoint(v.operand, old, dst)
		if o != v.operand {
			return new_type(Negate_Type{o})
		}
	case Execute_Type:
		tg := repoint(v.target, old, dst)
		if tg != v.target {
			return new_type(Execute_Type{tg})
		}
	case Carve_Type:
		s := repoint(v.source, old, dst)
		changed := s != v.source
		vals := make([dynamic]^Type, 0, len(v.values))
		for cv in v.values {
			nv := repoint(cv, old, dst)
			if nv != cv do changed = true
			append(&vals, nv)
		}
		if changed {
			refs := make([dynamic]Reference, 0, len(v.references))
			for rf in v.references do append(&refs, rf)
			return new_type(Carve_Type{s, refs, vals})
		}
	case Scope_Type:
		// A nested scope may reference the carved one; descend into its values
		// and parent chain. Clone the scope only if something below changed.
		changed := false
		new_vals := make([dynamic]^Type, 0, len(v.values))
		for sv in v.values {
			nv := repoint(sv, old, dst)
			if nv != sv do changed = true
			append(&new_vals, nv)
		}
		new_parent := v.parent == old ? dst : v.parent
		if new_parent != v.parent do changed = true
		if changed {
			ns := scope_clone(&v)
			ns.parent = new_parent
			delete(ns.values)
			ns.values = new_vals
			r := new(Type)
			r^ = ns^
			return r
		}
	}
	return t
}

// new_type boxes a Type value into a fresh ^Type.
new_type :: proc(v: Type) -> ^Type {
	r := new(Type)
	r^ = v
	return r
}
