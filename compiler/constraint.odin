package compiler

import "core:fmt"

// CONSTRAINT side: fold_constraint resolves the set a binding IMPOSES (left of
// `:`), satisfy proves a value's type is a subset of it. Same package as type.odin.

fold_constraint :: proc(t: ^Type) -> ^Type {
	if t != nil {
		#partial switch v in t^ {
		case Unknown_Type:
			// A `??` never denotes a statically-known set: the Unknown IS the fold result.
			return t
		case Recursive_Mention_Type:
			return t
		case Scope_Type:
			if scope_fields_fold_unknown(t, v.types[:]) do return new_type(Unknown_Type{})
			return t
		case Carve_Type:
			// A RECURSIVE carve tail (`Array{T}:` inside Array's own body) stays LAZY:
			// materializing it here would clone the still-walking scope and recurse with
			// no value to bound it, forever. binding_satisfy unfolds it one level at a
			// time against the finite value, which terminates it.
			if is_recursive_tail(t) do return t
			// A carve constraint folds to its substituted scope, which must itself be a
			// statically-known set (an unknown source/override is insoluble).
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
			key, blocked := execute_fold_enter(v.target)
			if blocked do return nil
			defer execute_fold_leave(key)
			prod, resolved := execute_production(v.target)
			if prod == nil {
				if resolved do return new_type(None_Type{}) // no production: collapses to `none`
				if tf := fold_constraint(v.target); fold_is_unknown(tf) do return tf // `??!`
				return nil
			}
			return fold_constraint(prod)
		case And_Type:
			left := fold_constraint(v.left)
			right := fold_constraint(v.right)
			if fold_is_unknown(left) do return left
			if fold_is_unknown(right) do return right
			// Numeric intersection if possible (`..9 & 11..`); symbolic otherwise
			// (mixed families, positional negation, scopes).
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
			// De Morgan normalization, in the same pass: push ~ toward the leaves and
			// collapse ~~, so the folded tree never has a ~ stacked on a &/|/~.
			//   ~~X → X    ~(A & B) → ~A | ~B    ~(A | B) → ~A & ~B
			inner := follow(v.operand)
			if inner != nil {
				#partial switch iv in inner^ {
				case Negate_Type:
					return fold_constraint(iv.operand) // ~~X → X
				case And_Type:
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
			// As a CONSTRAINT, a cast of an unpinned unknown (`??::u8`) is ONE
			// indeterminate element of the target, not the whole set — insoluble,
			// unless the cast pinned to a concrete singleton.
			if v.type_fold == nil || !fold_is_concrete_value(v.type_fold) {
				if vf := fold_constraint(v.value); fold_is_unknown(vf) do return vf
			}
			if v.type_fold != nil do return fold_constraint(v.type_fold)
			return fold_constraint(v.target)
		case Pattern_Type:
			return fold_constraint_pattern(t)
		case Compose_Type:
			// An expression over an unknown operand (`a+10` where a -> ??) is one
			// indeterminate value, not a set — insoluble, even though its numeric
			// ENVELOPE folds fine.
			left := fold_constraint(v.left)
			right := fold_constraint(v.right)
			if fold_is_unknown(left) do return left
			if fold_is_unknown(right) do return right
			// A string `+` sequence keeps its Compose shape as the constraint — satisfy
			// matches in order. Otherwise it folds through the numeric/string kernels.
			if v.operator == .Add {
				if _, ok := fold_string_sequence(t, true).([]String_Interval); ok {
					if fold_constraint_string(t) == nil do return t
				}
			}
			// Run the kernels over the folded CHILDREN (the synthetic node has no
			// type_fold), never the cached envelope — which would hide the dependency.
			syn := new_type(Compose_Type{operator = v.operator, left = left, right = right})
			if r := fold_constraint_integer(syn); r != nil do return r
			if r := fold_constraint_float(syn); r != nil do return r
			if r := fold_constraint_string(syn); r != nil do return r
			if r := fold_constraint_bool(syn); r != nil do return r
			return nil
		case Range_Type:
			// A three-bound string range `"ab".."cd".."ef"` (starts/contains/ends): the
			// flat fold loses the middle, so keep the Range and let satisfy enforce all three.
			if string_is_tri_range(t) do return t
			left := fold_constraint(v.left)
			right := fold_constraint(v.right)
			if fold_is_unknown(left) do return left
			if fold_is_unknown(right) do return right
			// A missing bound (`5..`, `..10`) stays nil — the kernels read it as open.
			syn := new_type(Range_Type{left, right})
			if r := fold_constraint_integer(syn); r != nil do return r
			if r := fold_constraint_float(syn); r != nil do return r
			if r := fold_constraint_string(syn); r != nil do return r
			if r := fold_constraint_bool(syn); r != nil do return r
			return nil
		}
	}
	// Leftover kinds (unresolved mentions/references, none, invalid): probe each domain.
	if r := fold_constraint_integer(t); r != nil do return r
	if r := fold_constraint_float(t); r != nil do return r
	if r := fold_constraint_string(t); r != nil do return r
	if r := fold_constraint_bool(t); r != nil do return r
	return nil
}

// negated wraps a ^Type in a Negate_Type; fold_constraint re-normalizes it.
negated :: proc(t: ^Type) -> ^Type {
	r := new(Type)
	r^ = Negate_Type{t}
	return r
}

// fold_constraint_target folds the value at scope[i] used as a constraint. An
// Unknown (??) resolves only when its type is a single concrete value; otherwise
// it stays Unknown (which never satisfies).
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
		// A self-referential mention chain can never fold (recursing would loop).
		// follow's cycle guard detects it: a chase that STOPS on an indirection cycled.
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

// scope_fields_fold_unknown reports whether any field of a scope-shaped constraint
// folds to Unknown — i.e. the scope is not a statically-known set. `key` identifies
// the scope/carve node on the scan stack (guards self-referential constraints
// `A -> {x -> A}`; the stack lives on the analyzer, dying with this pass's arena).
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
		// A recursive tail is NOT unknown (the value is constrained by induction,
		// consumed level by level by satisfy). Folding it here would materialize one
		// fresh clone per scan, forever (no node-identity guard helps).
		if is_recursive_tail(val) do continue
		if fold_is_unknown(fold_constraint(val)) do return true
	}
	return false
}

// is_recursive_tail reports whether `t` marks a recursive constraint: the
// Recursive_Mention node itself, or a carve whose source is one (`Array{T}`).
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
	// A value-side union fits the constraint iff EVERY branch does:
	// (A|B) ⊆ C ⟺ A⊆C ∧ B⊆C. (A surviving Or here is the mixed/symbolic case;
	// same-domain unions already folded to one domain set.)
	if vor, ok := ft^.(Or_Type); ok {
		return satisfy(fc, vor.left) && satisfy(fc, vor.right)
	}
	#partial switch f in fc^ {
	case Recursive_Mention_Type:
		c := fold_constraint(f.match_scope.types[f.match_index])
		return satisfy(c, ft)
	case Compose_Type:
		// A string `+` sequence: the value must split, left to right, into its segments.
		if f.operator == .Add {
			vt, ok := ft^.(String_Type)
			if !ok do return false
			return string_compose_satisfy(fc, vt)
		}
		return false
	case Range_Type:
		// A three-bound string range (`"ab".."cd".."ef"`): start/contain/end.
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
		// value ⊆ ~X ⟺ value not in X. Handles positional/mixed negation the fold
		// does not expand into intervals.
		return !satisfy(f.operand, ft)
	}
	return false
}

// value_elements returns a scope value's positional (pushed) elements, in order —
// the list a recursive constraint consumes head-first. Producer/expand are skipped.
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
		hasProd := false
		for i := 0; i < len(c.kind); i += 1 {
			if c.kind[i] == .Product {
				hasProd = true
				if c.constraint_folds[i] != nil {
					if satisfy(c.constraint_folds[i], ft) {
						return true
					}
				} else if satisfy((c.type_folds[i]), ft) {
					return true
				}
			}
		}
		if (hasProd) do return false
	}
	return satisfy(fc, ft)
}


scope_satisfy :: proc(cs, vs: Scope_Type) -> bool {
	satisfied := scope_satisfy_range(cs, 0, len(cs.names), vs, 0, len(vs.names))
	if satisfied {
		// Color-on-proof: once vs ⊆ cs holds, stamp cs's per-field colors onto vs so
		// the value carries its constraint intrinsically. Done here (the one place
		// scope-vs-scope is decided) so every path benefits.
		color_scope_with_constaint(cs, vs)
	}
	return satisfied
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

// recursive_tail_unfold resolves a recursive constraint marker ONE level deep,
// recovering the constraint to prove the current value field against. The bare
// mention (`Array:`) reads the live scope's binding; the carve tail (`Array{T}:`)
// additionally substitutes its overrides into it (the inner tail stays a lazy
// marker, unfolded only as the finite value descends). nil if neither form.
recursive_tail_unfold :: proc(fold: ^Type) -> ^Type {
	if fold == nil do return nil
	#partial switch v in fold^ {
	case Recursive_Mention_Type:
		return fold_constraint_target(v.match_scope, v.match_index)
	case Carve_Type:
		carve := &fold^.(Carve_Type)
		rec, is_rec := v.source^.(Recursive_Mention_Type)
		if !is_rec do return nil
		live := fold_constraint_target(rec.match_scope, rec.match_index)
		if live == nil do return nil
		src, ok := &live^.(Scope_Type)
		if !ok do return nil
		sub := carve_substitute(fold, carve, src)
		if sub == nil do return nil
		r := new(Type)
		r^ = sub^
		return r
	}
	return nil
}

binding_satisfy :: proc(cs: Scope_Type, i: int, vs: Scope_Type, j: int) -> bool {
	if cs.names[i] != vs.names[j] || cs.kind[i] != vs.kind[j] {
		return false
	}
	if cs.constraint_folds[i] == nil {
		return satisfy((cs.type_folds[i]), vs.type_folds[j])
	} else {
		// A recursive tail is unfolded one level against the live scope; everything
		// else is the already-materialized constraint scope.
		if is_recursive_tail(cs.constraint_folds[i]) {
			return satisfy_root(recursive_tail_unfold(cs.constraint_folds[i]), vs.type_folds[j])
		}
		return satisfy_root(cs.constraint_folds[i], vs.type_folds[j])
	}
}

// binding_color computes the COLOR `cs[i]` imposes on the value field — the same
// constraint binding_satisfy proves against, recovered here to stamp onto the value.
// nil for a shape-only field. Mirrors binding_satisfy's branch structure exactly.
binding_color :: proc(cs: Scope_Type, i: int) -> ^Type {
	if cs.constraint_folds[i] == nil {
		if cs.kind[i] != .Product {
			return nil
		}
		return fold_constraint(cs.types[i])
	}
	if is_recursive_tail(cs.constraint_folds[i]) {
		return recursive_tail_unfold(cs.constraint_folds[i])
	}
	return cs.constraint_folds[i]
}

// color_scope_with_constaint stamps `cs`'s per-field colors onto `vs` after
// scope_satisfy proved vs ⊆ cs, so the constraint travels WITH the value. Only ONE
// level (nested scopes were colored by their own recursive pass). An existing color
// is narrowed with `&`, never lost. Field pairing follows scope_satisfy_range.
color_scope_with_constaint :: proc(cs, vs: Scope_Type) {
	n := min(len(cs.names), len(vs.names))
	for k in 0 ..< n {
		if k >= len(vs.constraint_folds) do break
		color := binding_color(cs, k)
		if color == nil do continue
		existing := vs.constraint_folds[k]
		if existing == nil {
			vs.constraint_folds[k] = color
		} else {
			vs.constraint_folds[k] = new_type(And_Type{existing, color})
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

// fold_carve_constraint materializes the carve `t` into its substituted Scope_Type
// as a CONSTRAINT (left-of-`:`). nil when the source can't reduce to a scope.
fold_carve_constraint :: proc(t: ^Type) -> ^Scope_Type {
	carve, ok := &t^.(Carve_Type)
	if !ok do return nil

	// Re-entry guard ARMED HERE (mirrors fold_carve_type): a self-referential
	// carve loops in fold_constraint(carve.source) below, before carve_substitute.
	a := current_analyzer()
	if a != nil {
		for k in a.carve_fold_stack {
			if k == t do return nil
		}
		append(&a.carve_fold_stack, t)
	}
	defer if a != nil do pop(&a.carve_fold_stack)

	folded := fold_constraint(carve.source)
	if folded == nil do return nil
	// A recursive tail folds its source to a Recursive_Mention, not a Scope: resolve
	// through the binding site to recover the scope to substitute into. Without this
	// the inductive element carries no constraint (`Array{string}:a -> {"aa" 0}` would
	// wrongly accept 0).
	if rec, is_rec := folded^.(Recursive_Mention_Type); is_rec {
		folded = fold_constraint_target(rec.match_scope, rec.match_index)
		if folded == nil do return nil
	}
	src, ok2 := &folded^.(Scope_Type)
	if ok2 {
		return carve_substitute(t, carve, src)
	}
	// TODO: err here
	return nil
}
