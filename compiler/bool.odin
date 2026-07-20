package compiler

import "core:strings"

// bool family — a finite domain over {true, false}. A Bool_Type always denotes a
// NON-EMPTY set; the empty set (e.g. ~Bool) folds to None_Type. `value` is the
// concrete element for a singleton, nil for {true,false}; `default` is the first
// source term. `|` = union (default = first operand), `&` = intersect, `~` = complement.


// --- Construction ---

make_bool_const :: proc(v: bool) -> Bool_Type {
	return Bool_Type{v, v}
}

// make_bool_any : the `bool` builtin = false|true, default false.
make_bool_any :: proc() -> Bool_Type {
	return Bool_Type{nil, false}
}


// --- Predicates ---

bool_is_concrete :: #force_inline proc(t: Bool_Type) -> bool {
	_, ok := t.value.(bool)
	return ok
}

bool_value :: #force_inline proc(t: Bool_Type) -> bool {
	return t.value.(bool)
}

// Membership flags of the denoted set.
bool_has_true :: proc(t: Bool_Type) -> bool {
	if v, ok := t.value.(bool); ok do return v
	return true // value == nil → {true,false}
}

bool_has_false :: proc(t: Bool_Type) -> bool {
	if v, ok := t.value.(bool); ok do return !v
	return true
}


// --- Printing ---

bool_to_string :: proc(t: Bool_Type) -> string {
	if v, ok := t.value.(bool); ok do return v ? "true" : "false"
	return t.default ? "true|false" : "bool"
}

write_bool_desc :: proc(b: ^strings.Builder, t: Bool_Type) {
	strings.write_string(b, bool_to_string(t))
}


// --- DOMAIN ENTRY POINTS — mirror of fold_type_string / fold_constraint_string ---
// Fold to a Maybe(Bool_Domain); nil = "not a boolean expression". The empty set is
// materialized as None_Type by the wrapper, never as a Bool_Type.

Bool_Domain :: struct {
	has_true:    bool,
	has_false:   bool,
	default:     bool, // first source term (meaningful only when non-empty)
	has_default: bool,
}

// wrap_bool_domain : empty set → None; otherwise a Bool_Type with value + default.
wrap_bool_domain :: proc(d: Bool_Domain) -> ^Type {
	r := new(Type)
	if !d.has_true && !d.has_false {
		r^ = None_Type{}
		return r
	}
	value: Maybe(bool) = nil
	if d.has_true && !d.has_false do value = true
	if d.has_false && !d.has_true do value = false
	def := d.default
	if !d.has_default {
		def = d.has_true && !d.has_false ? true : false
	}
	r^ = Bool_Type{value, def}
	return r
}

fold_type_bool :: proc(t: ^Type) -> ^Type {
	d, ok := fold_bool_domain(t, false).(Bool_Domain)
	if !ok do return nil
	return wrap_bool_domain(d)
}

fold_constraint_bool :: proc(t: ^Type) -> ^Type {
	d, ok := fold_bool_domain(t, true).(Bool_Domain)
	if !ok do return nil
	return wrap_bool_domain(d)
}

stored_bool_domain :: proc(t: ^Type) -> Maybe(Bool_Domain) {
	if t == nil do return nil
	#partial switch v in t^ {
	case Bool_Type:
		return bool_type_domain(v)
	}
	return nil
}

bool_type_domain :: proc(v: Bool_Type) -> Bool_Domain {
	return Bool_Domain{bool_has_true(v), bool_has_false(v), v.default, true}
}

// `as_constraint` distinguishes value vs constraint fold; the difference only
// shows on Mention/Reference, which follow the target's VALUE when a constraint.
fold_bool_domain :: proc(t: ^Type, as_constraint: bool) -> Maybe(Bool_Domain) {
	if t == nil do return nil
	#partial switch v in t^ {
	case Bool_Type:
		return bool_type_domain(v)
	case Scope_Type:
		for i := 0; i < len(v.kind); i += 1 {
			if v.kind[i] == .Product {
				if d, ok := stored_bool_domain(v.type_folds[i]).(Bool_Domain); ok {
					return d
				}
				return fold_bool_domain(v.types[i], as_constraint)
			}
		}
		return nil
	case Or_Type:
		ld, l_ok := fold_bool_domain(v.left, as_constraint).(Bool_Domain)
		rd, r_ok := fold_bool_domain(v.right, as_constraint).(Bool_Domain)
		if !l_ok || !r_ok do return nil
		return bool_domain_union(ld, rd)
	case And_Type:
		ld, l_ok := fold_bool_domain(v.left, as_constraint).(Bool_Domain)
		rd, r_ok := fold_bool_domain(v.right, as_constraint).(Bool_Domain)
		if !l_ok || !r_ok do return nil
		return bool_domain_intersect(ld, rd)
	case Negate_Type:
		inner, ok := fold_bool_domain(v.operand, as_constraint).(Bool_Domain)
		if !ok do return nil
		return bool_domain_negate(inner)
	case Mention_Type:
		if v.match_scope != nil && v.match_index >= 0 && v.match_index < len(v.match_scope.types) {
			if as_constraint {
				return fold_bool_domain(v.match_scope.types[v.match_index], true)
			}
			if d, ok := stored_bool_domain(stored_type_fold_at(v.match_scope, v.match_index)).(Bool_Domain);
			   ok {
				return d
			}
			if d, ok := stored_bool_domain(
				   stored_constraint_fold_at(v.match_scope, v.match_index),
			   ).(Bool_Domain); ok {
				return d
			}
		}
		return nil
	case Reference_Type:
		ref := v.reference
		if ref != nil && ref.match_scope != nil && ref.match_index >= 0 &&
		   ref.match_index < len(ref.match_scope.types) {
			if as_constraint {
				return fold_bool_domain(ref.match_scope.types[ref.match_index], true)
			}
			if d, ok := stored_bool_domain(
				   stored_type_fold_at(ref.match_scope, ref.match_index),
			   ).(Bool_Domain); ok {
				return d
			}
			if d, ok := stored_bool_domain(
				   stored_constraint_fold_at(ref.match_scope, ref.match_index),
			   ).(Bool_Domain); ok {
				return d
			}
		}
		return nil
	}
	return nil
}


// --- SET OPERATIONS — | (union), & (intersection), ~ (negation) ---

// Union : membership OR'd; default = left operand's (first source term), falling
// back to the right's if the left set is empty.
bool_domain_union :: proc(a, b: Bool_Domain) -> Bool_Domain {
	r := Bool_Domain {
		has_true    = a.has_true || b.has_true,
		has_false   = a.has_false || b.has_false,
		has_default = a.has_default || b.has_default,
	}
	if a.has_default && (a.has_true || a.has_false) {
		r.default = a.default
	} else {
		r.default = b.default
	}
	return r
}

// Intersection : membership AND'd; default = left's if it survives, else right's.
bool_domain_intersect :: proc(a, b: Bool_Domain) -> Bool_Domain {
	r := Bool_Domain {
		has_true  = a.has_true && b.has_true,
		has_false = a.has_false && b.has_false,
	}
	if a.default && r.has_true || !a.default && r.has_false {
		r.default = a.default
		r.has_default = true
	} else if b.default && r.has_true || !b.default && r.has_false {
		r.default = b.default
		r.has_default = true
	}
	return r
}

// Negation : complement within {true,false}; ~(true|false) = {} (None).
bool_domain_negate :: proc(a: Bool_Domain) -> Bool_Domain {
	r := Bool_Domain {
		has_true  = !a.has_true,
		has_false = !a.has_false,
	}
	if r.has_true || r.has_false {
		r.default = r.has_true ? true : false
		r.has_default = true
	}
	return r
}


// --- SATISFIES — prove value ⊆ constraint ---

// bool_satisfy : every element of ft is also in fc.
bool_satisfy :: proc(fc, ft: Bool_Type) -> bool {
	if bool_has_true(ft) && !bool_has_true(fc) do return false
	if bool_has_false(ft) && !bool_has_false(fc) do return false
	return true
}
