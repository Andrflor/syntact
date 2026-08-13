package compiler

import "core:fmt"
import "core:unicode/utf8"

// C_Field_Layout is the ABI-neutral layout of one declared aggregate member.
// `indirect` is metadata for a reactive-pull member: the field occupies one
// machine pointer in the C representation, while the language still has no
// pointer value.
C_Field_Layout :: struct {
	offset:   int,
	size:     int,
	align:    int,
	indirect: bool,
}

C_Layout :: struct {
	size:   int,
	align:  int,
	fields: []C_Field_Layout,
}

// c_layout computes the C aggregate layout from declared constraints. It is
// intentionally independent of the materialized values in `Scope_Type.types`:
// a field declared u32 but defaulted to 0 is still four bytes in C.
c_layout :: proc(scope: ^Scope_Type) -> (C_Layout, bool) {
	seen := make(map[rawptr]bool)
	defer delete(seen)
	return c_layout_scope(scope, &seen)
}

c_layout_scope :: proc(scope: ^Scope_Type, seen: ^map[rawptr]bool) -> (C_Layout, bool) {
	if scope == nil do return {}, false
	key := rawptr(scope_canon(scope))
	if seen^[key] do return {}, false
	seen^[key] = true
	defer delete_key(seen, key)

	fields := make([dynamic]C_Field_Layout)
	offset := 0
	max_align := 1
	for i in 0 ..< len(scope.kind) {
		if scope.kind[i] == .Product || scope.kind[i] == .Expand do continue
		declared := i < len(scope.constraints) ? scope.constraints[i] : nil
		if declared == nil && i < len(scope.constraint_folds) do declared = scope.constraint_folds[i]
		if declared == nil do return {}, false

		field_align := 1
		field_size := 0
		indirect := scope.kind[i] == .Reactive_Pull
		if indirect {
			// Reactive pull is borrowed indirect input. The referent is represented
			// only by the boundary plan; it is never a source-level address.
			field_size, field_align = 8, 8
		} else {
			field, ok := c_layout_type(fold_constraint(declared), seen)
			if !ok do return {}, false
			field_size, field_align = field.size, field.align
		}
		if field_align > max_align do max_align = field_align
		offset = c_align_up(offset, field_align)
		append(&fields, C_Field_Layout{offset, field_size, field_align, indirect})
		offset += field_size
	}

	return C_Layout{size = c_align_up(offset, max_align), align = max_align, fields = fields[:]}, true
}

c_layout_type :: proc(t: ^Type, seen: ^map[rawptr]bool) -> (C_Layout, bool) {
	if t == nil do return {}, false
	cur := follow(t)
	if cur == nil do return {}, false
	#partial switch &v in cur^ {
	case Scope_Type:
		// A producer-only scope is a value wrapper, not a C struct. A scope with
		// ordinary members and a production remains an aggregate; the production
		// is not a field.
		has_member := false
		for k in v.kind do if k != .Product && k != .Expand {has_member = true; break}
		if !has_member {
			prods := scope_productions(v)
			defer delete(prods)
			if len(prods) == 1 do return c_layout_type(prods[0], seen)
		}
		return c_layout_scope(&v, seen)
	case Foreign_Call_Type:
		return c_layout_type(v.production, seen)
	case Cast_Type:
		if target, ok := cast_target(fold_constraint(v.target)); ok do return c_layout_scalar(target)
	case Integer_Type:
		if len(v.integer_intervals) == 1 {
			if lay, ok := int_layout(v.integer_intervals[0]); ok {
			return C_Layout{size = int(lay.bits / 8), align = int(lay.bits / 8)}, true
			}
		}
	case Float_Type:
		if v.kind == .f32 do return C_Layout{size = 4, align = 4}, true
		if v.kind == .f64 do return C_Layout{size = 8, align = 8}, true
	case Bool_Type:
		return C_Layout{size = 1, align = 1}, true
	case String_Type:
		// A Syntact string at a C frontier is a const char*.
		return C_Layout{size = 8, align = 8}, true
	case None_Type:
		return C_Layout{size = 0, align = 1}, true
	}
	if target, ok := cast_target(fold_constraint(cur)); ok do return c_layout_scalar(target)
	return {}, false
}

c_layout_scalar :: proc(target: Cast_Target) -> (C_Layout, bool) {
	switch target.kind {
	case .Integer:
		sz := int(target.width / 8)
		return C_Layout{size = sz, align = sz}, sz > 0
	case .Float:
		sz := int(target.width / 8)
		return C_Layout{size = sz, align = sz}, sz > 0
	case .Bool:
		return C_Layout{size = 1, align = 1}, true
	case .String, .Char:
		return C_Layout{size = 8, align = 8}, true
	}
	return {}, false
}

c_align_up :: proc(value, alignment: int) -> int {
	if alignment <= 1 do return value
	return (value + alignment - 1) & ~(alignment - 1)
}

// reference_effective_value resolves the VALUE a Reference_Type denotes, honoring
// a carve in its target: when the target resolves to a carve overriding this exact
// field, return the override's value, not the stale pre-carve site value.
reference_effective_value :: proc(v: Reference_Type) -> ^Type {
	ref := v.reference
	if ref == nil || ref.match_scope == nil || ref.match_index < 0 do return nil
	original := slot_value(ref.match_scope, ref.match_index)
	if v.target != nil {
		cur := follow(v.target)
		if cur != nil {
			#partial switch &cv in cur^ {
			case Carve_Type:
				for i := 0; i < len(cv.references); i += 1 {
					if cv.references[i].match_index == ref.match_index {
						return cv.types[i]
					}
				}
			}
		}
	}
	return original
}

// reresolve_property re-resolves a property access (`target.name`) after its
// TARGET was substituted by a carve: the old Reference's frozen `(scope, index)`
// pair is stale, so the name is looked up again in the NEW value. Returns the
// freshly-resolved Reference, or an Invalid_Type if the property is gone. `nt`
// is the already-repointed target expression; `ref` carries the property name.
reresolve_property :: proc(nt: ^Type, ref: ^Reference) -> ^Type {
	name, has_name := ref.name.(string)
	if !has_name do return nil // not a name-keyed access: nothing to re-resolve
	ordinal: i16 = -1
	if o, ok := ref.index.(u64); ok do ordinal = i16(o)

	// Same lookup walk_property uses — shared so substitution resolves identically.
	prop_scope, prop_index := resolve_property_site(nt, name, ordinal)
	if prop_scope == nil {
		// Only emit while a carve is being rechecked (recheck_span set) — fold_carve
		// also runs from reduce/materialization where this would duplicate the diagnostic.
		if a := current_analyzer();
		   a != nil && (a.recheck_span.start != 0 || a.recheck_span.end != 0) {
			label := name != "" ? fmt.tprintf("'%s'", name) : fmt.tprintf("#%d", ordinal)
			sem_error(
				a,
				fmt.tprintf(
					"implicit constraint mismatch: property %s does not exist after carve substitution",
					label,
				),
				.Constraint_Mismatch,
				a.recheck_span,
			)
		}
		return new_type(Invalid_Type{})
	}
	nref := new(Reference)
	nref^ = Reference{ref.name, ref.index, prop_scope, prop_index, ref.span}
	return new_type(Reference_Type{nt, nref})
}

// execute_target_scope resolves a collapse target to the underlying ^Scope_Type
// it reduces through, peeling carves WITHOUT folding them (no clone) — the stable
// identity for the recursion guard.
execute_target_scope :: proc(t: ^Type) -> ^Scope_Type {
	cur := follow(t)
	for cur != nil {
		#partial switch &v in cur^ {
		case Scope_Type:
			return &v
		case Carve_Type:
			cur = follow(v.source)
			continue
		}
		break
	}
	return nil
}

// execute_fold_enter/leave guard folding a collapse: a RECURSIVE collapse would
// unfold forever at fold time. Re-entering the same target scope reports
// blocked=true and the caller bails to nil (recursion is reduce's job).
execute_fold_enter :: proc(t: ^Type) -> (key: ^Scope_Type, blocked: bool) {
	key = execute_target_scope(t)
	if key == nil do return nil, false
	a := current_analyzer()
	if a == nil do return nil, false
	for k in a.execute_stack {
		if k == key do return nil, true
	}
	append(&a.execute_stack, key)
	return key, false
}

execute_fold_leave :: proc(key: ^Scope_Type) {
	if key == nil do return
	if a := current_analyzer(); a != nil do pop(&a.execute_stack)
}

// value_fold_enter/leave guard folding a binding's VALUE through its site: a
// self-referential value (a carved override mentioning its own binding, `n -> n-1`
// repointed into the clone) re-enters forever through a Compose — the direct
// mention-chain guard in fold_constraint_target can't see it. Re-entry reports
// blocked=true and the caller bails to nil. The marker lives on the SCOPE (like
// refine_overrides), never on context.user_ptr, so any phase may fold safely.
value_fold_enter :: proc(scope: ^Scope_Type, i: int) -> (entered: bool, blocked: bool) {
	if scope == nil do return false, false
	if scope.folding_values[i] do return false, true
	scope.folding_values[i] = true
	return true, false
}

value_fold_leave :: proc(scope: ^Scope_Type, i: int, entered: bool) {
	if !entered || scope == nil do return
	delete_key(&scope.folding_values, i)
}

// fold_type_set is the typeof of a set-algebra value (`~ | &`). It collapses to a
// domain set ONLY when the expression reduces to a concrete singleton (e.g.
// `~~5` -> 5), preserving identity. Otherwise it keeps the `~ | &` structure
// SYMBOLIC and lifts it one meta level as the producer `{-> <canonical set>}`,
// uniformly across domains (integers no longer distribute into a collapsed
// interval). This is what lets `=X` match X structurally and cross-domain:
// `(10|~20|u8)` stays distinct from `(10|~20|u16)` even though both denote
// every integer, and `~10.0` never silently matches a string.
fold_type_set :: proc(t: ^Type) -> ^Type {
	if e := fold_type_integer(t); e != nil && fold_is_concrete_value(e) do return e
	if e := fold_type_float(t); e != nil && fold_is_concrete_value(e) do return e
	if e := fold_type_bool(t); e != nil && fold_is_concrete_value(e) do return e
	if e := fold_type_string(t); e != nil && fold_is_concrete_value(e) do return e
	return make_producer_scope(fold_set_value(t))
}

// fold_set_value folds a set-algebra expression to its canonical SYMBOLIC form:
// the `~ | &` tree is kept intact (never distributed/collapsed), and each leaf is
// folded to its bare domain envelope (no producer wrap). The structure travels so
// a `=X` value-match can compare it as written.
fold_set_value :: proc(t: ^Type) -> ^Type {
	if t == nil do return nil
	#partial switch v in t^ {
	case Negate_Type:
		return new_type(Negate_Type{fold_set_value(v.operand)})
	case Or_Type:
		return new_type(Or_Type{fold_set_value(v.left), fold_set_value(v.right)})
	case And_Type:
		return new_type(And_Type{fold_set_value(v.left), fold_set_value(v.right)})
	}
	if e := fold_type_integer(t); e != nil do return e
	if e := fold_type_float(t); e != nil do return e
	if e := fold_type_string(t); e != nil do return e
	if e := fold_type_bool(t); e != nil do return e
	return fold_type(t)
}

// capture_color_domain returns the color-SET of a capture that is still an unfilled
// cover placeholder, else nil. A capture `(e)` shares its slot index with the cover
// field `T:(e)`; while the scrutinee is symbolic the slot holds only the empty
// placeholder scope the cover was built from, so `e` would fold to a bare scope and
// lose its domain. Returning the color keeps every proof over `e` running on its
// full applied set — primitive, structural, or a union of both (`u8|Array{u8}`).
// An EXPAND capture (`...C:(r)`, the destructured tail) keeps its placeholder: its
// SHAPE drives destructuring. A capture already holding a real destructured value
// is left alone.
capture_color_domain :: proc(scope: ^Scope_Type, index: int) -> ^Type {
	if scope == nil || index < 0 || index >= len(scope.captures) do return nil
	if scope.captures[index] == "" do return nil // not a capture slot
	// Only an UNRESOLVED slot (marked at cover build, cleared by destructuring)
	// reads through its color — a slot holding a real value, including a real
	// `{}`, is an ordinary binding.
	if index not_in scope.unresolved_captures do return nil
	// An EXPAND capture (`...C:(r)`, the destructured tail) keeps its placeholder —
	// its SHAPE matters for destructuring, not its set.
	if index < len(scope.kind) && scope.kind[index] == .Expand do return nil
	// Re-fold the CONSTRAINT expression, not the cached fold: the cached color was
	// folded when the cover was built (a pull `T` still unbound, folding to `{}`), but
	// the mention of T now resolves to its inferred domain (2..5). Fall back to the
	// cache when there is no live constraint expression.
	color: ^Type = nil
	if index < len(scope.constraints) && scope.constraints[index] != nil {
		color = fold_constraint(scope.constraints[index])
	}
	if color == nil && index < len(scope.constraint_folds) {
		color = scope.constraint_folds[index]
	}
	// A color that is itself the empty scope is the unbound-pull placeholder ("the
	// color is not inferred yet") — and a missing color is the same state: the
	// slot's value is UNKNOWN. Never a conclusive `{}`.
	if color == nil do return new_type(Unknown_Type{})
	if ds, is_scope := color^.(Scope_Type); is_scope && len(ds.kind) == 0 {
		return new_type(Unknown_Type{})
	}
	return color
}

// binding_value_view returns the ^Type a binding's VALUE denotes to any observer —
// the ONE value-resolution law, shared by folding and the diagnostics layer so a
// proof always classifies the same value the fold would produce:
//   1. the branch-refinement override, when one is installed for this branch;
//   2. the capture's applied COLOR, while its slot still holds the unfilled cover
//      placeholder (fold_type's capture rule — without it a diagnostic reads the
//      raw placeholder scope and concludes "a scope" for a value whose domain is
//      really `u8|string`);
//   3. the value it stated, or — having stated none — its color's default
//      (slot_value).
// Steps 1–2 return already-folded domains; step 3 returns the raw expression.
binding_value_view :: proc(scope: ^Scope_Type, index: int) -> ^Type {
	if scope == nil || index < 0 || index >= len(scope.types) do return nil
	if ov := refine_override_for(scope, index); ov != nil do return ov
	// capture_color_domain owns the unresolved-capture law: the applied color for
	// an unresolved slot, Unknown while that color is not inferred yet, nil for a
	// resolved slot (whose stored value — a real `{}` included — is the value).
	if dom := capture_color_domain(scope, index); dom != nil do return dom
	return slot_value(scope, index)
}

// color_is_leaf_domain reports whether a folded color denotes a LEAF set (integer/float/
// string/bool), reading through a producer scope `{-> set}` (how a pull-derived domain
// like T=2..5 folds). A structural scope/carve (`Array{T}`) is NOT a leaf domain.
color_is_leaf_domain :: proc(color: ^Type) -> bool {
	c := color
	#partial switch v in c^ {
	case Integer_Type, Float_Type, String_Type, Bool_Type:
		return true
	case Or_Type:
		// A CROSS-FAMILY union (`2.4|3..5` — the kernels keep it symbolic) is still
		// a leaf domain: every leaf is one, and satisfy decomposes the set algebra.
		return color_is_leaf_domain(v.left) && color_is_leaf_domain(v.right)
	case And_Type:
		return color_is_leaf_domain(v.left) && color_is_leaf_domain(v.right)
	case Negate_Type:
		return color_is_leaf_domain(v.operand)
	case Scope_Type:
		// A pure producer `{-> set}`: its production is the domain — check it.
		prods := scope_productions(v)
		if len(prods) == 1 && len(v.names) == 1 {
			pf := fold_constraint(prods[0])
			if pf == nil do return false
			return color_is_leaf_domain(pf)
		}
	}
	return false
}

// fold_type yields the TYPE of a value (the RIGHT side, a typeof).
// Singleton -> the value itself; any wider set -> the producer scope {-> set}.
// scope_canon reads through the clone chain to the canonical (walk-built) scope —
// the "same scope up to materialization" identity.
scope_canon :: #force_inline proc(s: ^Scope_Type) -> ^Scope_Type {
	if s == nil do return nil
	return s.origin != nil ? s.origin : s
}

// Bounds-guarded fold reads: a mid-construction or freshly cloned scope may not
// have its fold columns filled yet — an out-of-range index reads as "no fold".
stored_type_fold_at :: #force_inline proc(s: ^Scope_Type, i: int) -> ^Type {
	return i >= 0 && i < len(s.type_folds) ? s.type_folds[i] : nil
}

stored_constraint_fold_at :: #force_inline proc(s: ^Scope_Type, i: int) -> ^Type {
	return i >= 0 && i < len(s.constraint_folds) ? s.constraint_folds[i] : nil
}

fold_type :: proc(t: ^Type) -> ^Type {
	if t != nil {
		switch v in t^ {
		case Scope_Type:
			return t
		case Carve_Type:
			sub := fold_carve_type(t)
			if sub == nil do return nil
			st := new(Type)
			st^ = sub^
			return fold_type(st)
		case Mention_Type:
			if v.match_scope != nil && v.match_index >= 0 {
				// A pattern-branch refinement override replaces the binding's value with
				// its narrowed domain (so `n-1` inside `n ? {0->…, ->…}` folds n over its
				// refined domain, not its default value). Returned UNWRAPPED, like the
				// arithmetic envelopes: the override is the ENVELOPE of a symbolic value
				// (`n` ranges over 5..9), not the set-as-a-value meta level — wrapping it
				// in a producer would make it fail against the leaf color it inhabits.
				if ov := refine_override_for(v.match_scope, v.match_index); ov != nil {
					return ov
				}
				// A LEAF-COLORED capture (`(e)` in `{u8:(e) …}`) still awaiting a concrete
				// scrutinee has only its empty cover placeholder in `types[]`, which would
				// fold to a bare scope and drop the domain. Fold to its color instead, so a
				// use of `e` carries `u8`/`2..5` — this lets an inner carve `func{e->e}`
				// prove `e` against func's color. Restricted to a LEAF domain: a structural
				// capture (`(r):Array{T}`) keeps its placeholder (its shape matters, not a set).
				if dom := capture_color_domain(v.match_scope, v.match_index); dom != nil {
					return dom
				}
				// Site guard: a self-referential value (carve-repointed `n -> n-1`)
				// re-enters this fold forever through a Compose.
				entered, blocked := value_fold_enter(v.match_scope, v.match_index)
				if blocked do return nil
				defer value_fold_leave(v.match_scope, v.match_index, entered)
				return fold_type(slot_value(v.match_scope, v.match_index))
			}
		case Reference_Type:
			if v.reference != nil && v.reference.match_scope != nil && v.reference.match_index >= 0 {
				// Unwrapped for the same reason as the Mention override above.
				if ov := refine_override_for(v.reference.match_scope, v.reference.match_index); ov != nil {
					return ov
				}
				entered, blocked := value_fold_enter(v.reference.match_scope, v.reference.match_index)
				if blocked do return nil
				defer value_fold_leave(v.reference.match_scope, v.reference.match_index, entered)
				eff := reference_effective_value(v)
				if eff != nil do return fold_type(eff)
				return nil
			}
			eff := reference_effective_value(v)
			if eff != nil do return fold_type(eff)
		case Recursive_Mention_Type:
			return t
		case Foreign_Call_Type:
			// The typeof a foreign call is its DECLARED production layout: the value
			// itself is not computable, only its shape is known. The effect is not
			// erased by this — the call node survives in the reduction.
			return fold_type(v.production)
		case Effect_Sequence_Type:
			// Effects do not change the value's static shape.
			return fold_type(v.value)
		case And_Type:
			return fold_type_set(t)
		case Or_Type:
			return fold_type_set(t)
		case Negate_Type:
			return fold_type_set(t)
		case Range_Type:
			if env := fold_type_integer(t); env != nil do return value_type_envelope(env)
			if env := fold_type_float(t); env != nil do return value_type_envelope(env)
			if env := fold_type_string(t); env != nil do return value_type_envelope(env)
			return new_type(Range_Type{fold_type(v.left), fold_type(v.right)})
		case Invalid_Type, None_Type, Unknown_Type:
			return t
		case Execute_Type:
			key, blocked := execute_fold_enter(v.target)
			if blocked do return nil
			defer execute_fold_leave(key)
			prod, resolved := execute_production(v.target)
			if prod == nil {
				if resolved do return new_type(None_Type{}) // no production: collapses to `none`
				return nil
			}
			return fold_type(prod)
		case Integer_Type:
			return value_type_envelope(fold_type_integer(t))
		case Float_Type:
			return value_type_envelope(fold_type_float(t))
		case String_Type:
			return value_type_envelope(fold_type_string(t))
		case Bool_Type:
			return value_type_envelope(fold_type_bool(t))
		case Cast_Type:
			if v.type_fold != nil do return fold_type(v.type_fold)
			return fold_constraint(v.target)
		case Compose_Type:
			// A comparison is a bool VALUE: exact when both operands are concrete
			// (the concrete-value law), else the full `{true,false}` so a
			// `=true -> … =false -> …` pattern over it is exhaustive.
			if is_comparison_op(v.operator) {
				if r := fold_comparison_envelope(v); r != nil do return r
				return new_type(make_bool_any())
			}
			// Arithmetic envelope returned UNWRAPPED: wrapping `0..510` in a producer
			// would make it fail self-match against a widened `u16`.
			if env := fold_type_integer(t); env != nil do return env
			if env := fold_type_float(t); env != nil do return env
		case Pattern_Type:
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

// value_type_envelope wraps a folded envelope as a typeof: a singleton is its own
// value, any wider set becomes the producer scope {-> set}.
value_type_envelope :: proc(env: ^Type) -> ^Type {
	if env == nil do return nil
	if fold_is_concrete_value(env) do return env
	return make_producer_scope(env)
}

// fold_is_concrete_value reports whether a folded ^Type denotes one concrete
// value (a singleton) rather than a set/range.
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
// meta level up.
make_producer_scope :: proc(produces: ^Type) -> ^Type {
	if produces == nil do return nil
	return make_producer_scope_multi([]^Type{produces})
}

// make_producer_scope_multi builds a producer scope with one .Product binding
// per element of produces, in order.
make_producer_scope_multi :: proc(produces: []^Type) -> ^Type {
	scope := new(Scope_Type)
	for p in produces {
		append(&scope.names, "")
		append(&scope.constraints, nil)
		append(&scope.kind, Binding_Kind.Product)
		append(&scope.types, p)
		append(&scope.type_folds, p)
		append(&scope.constraint_folds, nil)
	}
	r := new(Type)
	r^ = scope^
	return r
}

// execute_production resolves the target of a collapse (`target!`) down to the
// FIRST production it reduces through (follow to a scope, peeling a carve).
// `resolved` splits the two empty cases: a scope with no production yields `none`
// (resolved=true, prod=nil); a non-scope target can't fold statically (resolved=false).
//
// An `...A` expansion (`.Expand`) pastes A's bindings — INCLUDING its production —
// at that position, so an expansion carrying a production fires BEFORE a later
// in-place `-> v` (`{...double#0; -> 6}` collapses through double#0's production).
// foreign_target_scope returns the LIBRARY scope a collapse target belongs to when
// that target is a foreign symbol, else nil. The provenance sits on the library
// scope and the target is one of its symbols, so the marker is read through the
// symbol's parent — carves preserve the parent chain, so a partially applied
// external is still recognized.
//
// This is THE effect marker, and it is deliberately independent of the production's
// shape: singleton, non-singleton or void all cross the frontier alike.
foreign_target_scope :: proc(t: ^Type) -> ^Scope_Type {
	s := execute_target_scope(t)
	if s == nil do return nil
	if s.parent == nil || s.parent.foreign_lib == "" do return nil
	return s.parent
}

execute_production :: proc(t: ^Type) -> (prod: ^Type, resolved: bool) {
	cur := follow(t)
	for cur != nil {
		#partial switch &v in cur^ {
		case Scope_Type:
			return scope_first_production(&v)
		case Carve_Type:
			sub := fold_carve_type(cur)
			if sub == nil do return nil, false
			return scope_first_production(sub)
		}
		break
	}
	return nil, false
}

// scope_first_production returns the first production reachable in binding order,
// pasting any `...A` expansion's production in place (see execute_production).
scope_first_production :: proc(s: ^Scope_Type) -> (prod: ^Type, resolved: bool) {
	for i := 0; i < len(s.kind); i += 1 {
		if s.kind[i] == .Product do return slot_value(s, i), true
		if s.kind[i] == .Expand {
			if p, ok := execute_production(slot_value(s, i)); ok && p != nil {
				return p, true
			}
		}
	}
	return nil, true
}

// DEFAULT — the concrete value a constraint produces when no value is given
// (`u8:a` → a equals 0). ALWAYS computed on the final fold intervals, never on
// the raw structure, so `~10`, `..9|11..`, `~(~10&~20)` yield consistent defaults.

// default_value : the concrete value to lay down when a binding has no `->`.
// Follows the scope/carve down to a production, then materializes its default.
default_value :: proc(t: ^Type) -> ^Type {
	if t == nil do return t
	target := follow(t)
	cur := target
	for {
		#partial switch &v in cur^ {
		case Scope_Type:
			// A scope with a production denotes its production's value-set (even
			// with structural fields alongside — those are the machine's innards,
			// e.g. a grammar's type parameter): the default reads through the
			// production. To default to a STRUCTURE, color with a producer OF the
			// structure: `{-> {T:e, -> E:}}:func` defaults to the shape scope.
			for i := 0; i < len(v.kind); i += 1 {
				if v.kind[i] == .Product {
					prod := slot_value(&v, i)
					def := type_default(prod)
					if def != nil do return def
					return prod
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

// slot_default materializes the value of a VALUELESS colored binding (`u8:x`,
// `-> C:`, `...C:`): it stated no value, so its COLOR is the only source of truth
// and its value is that color's default. Nothing is stored in `types[i]` for such
// a binding, which is what makes substitution self-correcting: `maybe{u8}` rewrites
// the color to u8 and the value follows to 0, with no per-slot bookkeeping and
// nothing left over from before the carve.
slot_default :: proc(s: ^Scope_Type, i: int) -> ^Type {
	if s == nil || i < 0 || i >= len(s.constraints) do return nil
	// An unresolvable color denotes no set at all, so the binding's value is the error
	// sentinel — NOT nothing: the diagnostic already fired at the color itself, and the
	// sentinel is what keeps every later use of the binding silent (the law
	// materialize_bare_constraint states for the same form).
	if is_broken(s.constraints[i]) do return make_invalid()
	color := i < len(s.constraint_folds) ? s.constraint_folds[i] : nil
	if color == nil do color = fold_constraint(s.constraints[i])
	if color == nil do return nil
	return default_value(color)
}

// slot_value is THE read of a binding's value: the value it stated, else — having
// stated none — its color's default. Every consumer that reads `types[i]` for a
// value goes through here, so the two cases can never diverge.
slot_value :: proc(s: ^Scope_Type, i: int) -> ^Type {
	if s == nil || i < 0 || i >= len(s.types) do return nil
	if s.types[i] != nil do return s.types[i]
	return slot_default(s, i)
}

// type_default : materializes the default of a type into a concrete value by
// folding the constraint into intervals and reading the computed default_value.
type_default :: proc(t: ^Type) -> ^Type {
	if t == nil do return nil
	#partial switch v in t^ {
	case Compose_Type:
		// A string sequence `+`: default is the in-order concat of each segment's
		// default ('a'..'z' + '@' + 'a'..'z' → "a@a"). nil when not a sequence.
		if v.operator == .Add {
			if d := string_sequence_default(t); d != nil do return d
		}
	case Mention_Type:
		if v.match_scope != nil && v.match_index >= 0 {
			return type_default(v.match_scope.types[v.match_index])
		}
	case Reference_Type:
		if v.reference != nil && v.reference.match_scope != nil && v.reference.match_index >= 0 {
			return type_default(v.reference.match_scope.types[v.reference.match_index])
		}
	case Or_Type:
		// Default of a union = default of its FIRST term. The only cross-family rule:
		// `(u8|string)`→0, `(string|u8)`→"" — the single-domain folds below can't
		// reduce a cross-family union, so the first term must be picked here.
		if d := type_default(v.left); d != nil do return d
		if d := type_default(v.right); d != nil do return d
	case Negate_Type:
		// Default of a STRING negation: the first string (shortest-first) outside the
		// negated operand. Only fires for a positional pattern that doesn't fold
		// (`~"piro"` → ""); numeric negations fold to intervals below.
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
	if folded := fold_constraint_integer(t); folded != nil {
		if it, ok := folded^.(Integer_Type); ok {
			// No intervals = the empty set (`~(~10|~20)` = ∅): default is `none`.
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
	// Stores the raw numeric envelope (a value), not its typeof — consumed by
	// further interval arithmetic.
	folded := fold_type_integer(t)
	if folded == nil do folded = fold_type_float(t)
	if folded == nil do folded = fold_type_string(t)
	if folded != nil {
		comp.type_fold = folded
		return
	}
	// A string `+` that didn't collapse to a literal is an ordered SEQUENCE matched
	// in order at satisfy time (string_compose_satisfy). Valid — no diagnostic.
	if comp.operator == .Add {
		if _, ok := fold_string_sequence(t, true).([]String_Interval); ok do return
	}
	// A comparison produces a BOOL. Two concrete operands compute the exact
	// singleton (the concrete-value law); a symbolic one keeps the full Bool so a
	// `=true -> … =false -> …` pattern over it is exhaustive.
	if is_comparison_op(comp.operator) {
		if r := fold_comparison_envelope(comp^); r != nil {
			comp.type_fold = r
			return
		}
		lf := family_of(comp.left)
		rf := family_of(comp.right)
		if is_numeric_family(lf) && is_numeric_family(rf) {
			comp.type_fold = new_type(make_bool_any())
			return
		}
	}
	// Envelope fold failed. An unresolved arithmetic is NOT an error — an unknown
	// operand keeps it symbolic (`??0 + 1`). Only a genuine incompatibility (int/float
	// mix, divergent float colors, non-numeric operand, possible /0) is. diagnose_compose
	// draws that line, shared with the re-fold path (detect_invalid).
	diagnose_compose(a, comp^, node_span(a, node))
}

// is_comparison_op reports whether an operator yields a bool rather than a number.
is_comparison_op :: proc(op: Operator_Kind) -> bool {
	#partial switch op {
	case .Less, .Greater, .LessEqual, .GreaterEqual, .Equal, .NotEqual:
		return true
	}
	return false
}

// fold_comparison_envelope decides a comparison from its operands' ENVELOPES —
// the concrete-value law generalized: a singleton is a degenerate range, so
// `2 > 2` folds false and a `0..255` value `< 300` folds true by the SAME rule:
// the comparison folds to its exact bool whenever every (left, right) pair of
// values agrees on the answer. An overlap (or an unbounded deciding side) keeps
// the full {true,false} envelope — which is what keeps `=true/=false` exhaustive
// over a genuinely undecided comparison. Two integer envelopes decide exactly in
// i128; a float or mixed pair decides in f64 (the integer side promotes),
// conservatively: floats only decide across a STRICT separation, so an open
// bound can never flip a verdict.
fold_comparison_envelope :: proc(comp: Compose_Type) -> ^Type {
	if !is_comparison_op(comp.operator) do return nil

	llo_i, lhi_i, l_int := integer_envelope_bounds(comp.left)
	rlo_i, rhi_i, r_int := integer_envelope_bounds(comp.right)
	if l_int && r_int {
		def_lt, def_le, def_gt, def_ge, eq: bool
		if l, lok := lhi_i.(i128); lok {
			if r, rok := rlo_i.(i128); rok {
				def_lt = l < r
				def_le = l <= r
			}
		}
		if l, lok := llo_i.(i128); lok {
			if r, rok := rhi_i.(i128); rok {
				def_gt = l > r
				def_ge = l >= r
			}
		}
		eq = maybe_i128_singleton_equal(llo_i, lhi_i, rlo_i, rhi_i)
		return comparison_verdict(comp.operator, def_lt, def_le, def_gt, def_ge, eq)
	}

	llo, lhi, l_num := number_envelope_bounds(comp.left)
	rlo, rhi, r_num := number_envelope_bounds(comp.right)
	if l_num && r_num {
		def_lt, def_le, def_gt, def_ge, eq: bool
		if l, lok := lhi.(f64); lok {
			if r, rok := rlo.(f64); rok {
				def_lt = l < r // strict separation only: open bounds can't flip this
				def_le = l < r
			}
		}
		if l, lok := llo.(f64); lok {
			if r, rok := rhi.(f64); rok {
				def_gt = l > r
				def_ge = l > r
			}
		}
		return comparison_verdict(comp.operator, def_lt, def_le, def_gt, def_ge, eq)
	}
	return nil
}

// comparison_verdict turns the definite order relations between two envelopes
// into a bool singleton, or nil when the operator's answer is not decided.
comparison_verdict :: proc(op: Operator_Kind, def_lt, def_le, def_gt, def_ge, singletons_equal: bool) -> ^Type {
	decided, value: bool
	#partial switch op {
	case .Less:
		if def_lt {value, decided = true, true} else if def_ge do decided = true
	case .LessEqual:
		if def_le || singletons_equal {value, decided = true, true} else if def_gt do decided = true
	case .Greater:
		if def_gt {value, decided = true, true} else if def_le do decided = true
	case .GreaterEqual:
		if def_ge || singletons_equal {value, decided = true, true} else if def_lt do decided = true
	case .Equal:
		if singletons_equal {value, decided = true, true} else if def_lt || def_gt do decided = true
	case .NotEqual:
		if def_lt || def_gt {value, decided = true, true} else if singletons_equal do decided = true
	}
	if !decided do return nil
	return new_type(make_bool_const(value))
}

maybe_i128_singleton_equal :: proc(llo, lhi, rlo, rhi: Maybe(i128)) -> bool {
	a, ok1 := llo.(i128)
	b, ok2 := lhi.(i128)
	c, ok3 := rlo.(i128)
	d, ok4 := rhi.(i128)
	return ok1 && ok2 && ok3 && ok4 && a == b && c == d && a == c
}

// integer_envelope_bounds folds an operand's integer envelope down to its overall
// [lo, hi] bounds (nil = unbounded on that side); ok=false for a non-integer or
// empty envelope.
integer_envelope_bounds :: proc(t: ^Type) -> (lo, hi: Maybe(i128), ok: bool) {
	it := fold_type_integer(t)
	if it == nil do return nil, nil, false
	iv, is_int := it^.(Integer_Type)
	if !is_int || len(iv.integer_intervals) == 0 do return nil, nil, false
	first := true
	for seg in iv.integer_intervals {
		if first {
			lo, hi = seg.lo, seg.hi
			first = false
			continue
		}
		if cur, has := lo.(i128); has {
			if sl, seg_has := seg.lo.(i128); seg_has {
				if sl < cur do lo = sl
			} else {
				lo = nil
			}
		}
		if cur, has := hi.(i128); has {
			if sh, seg_has := seg.hi.(i128); seg_has {
				if sh > cur do hi = sh
			} else {
				hi = nil
			}
		}
	}
	return lo, hi, true
}

// number_envelope_bounds reads an operand's numeric envelope as f64 bounds — the
// integer envelope promoted, else the float envelope (open flags dropped: the
// caller only decides across strict separation, where openness cannot matter).
number_envelope_bounds :: proc(t: ^Type) -> (lo, hi: Maybe(f64), ok: bool) {
	if ilo, ihi, is_int := integer_envelope_bounds(t); is_int {
		if v, has := ilo.(i128); has do lo = f64(v)
		if v, has := ihi.(i128); has do hi = f64(v)
		return lo, hi, true
	}
	ft := fold_type_float(t)
	if ft == nil do return nil, nil, false
	fv, is_float := ft^.(Float_Type)
	if !is_float || len(fv.float_intervals) == 0 do return nil, nil, false
	first := true
	for seg in fv.float_intervals {
		if first {
			lo, hi = seg.lo, seg.hi
			first = false
			continue
		}
		if cur, has := lo.(f64); has {
			if sl, seg_has := seg.lo.(f64); seg_has {
				if sl < cur do lo = sl
			} else {
				lo = nil
			}
		}
		if cur, has := hi.(f64); has {
			if sh, seg_has := seg.hi.(f64); seg_has {
				if sh > cur do hi = sh
			} else {
				hi = nil
			}
		}
	}
	return lo, hi, true
}

// fold_cast resolves a `value :: target` raw binary reinterpret-cast: extract the
// source's raw little-endian bits, resize to the target width, reinterpret under
// the target domain. The result always lands inside the target, so `::` never
// raises a Constraint_Mismatch — only Invalid_Cast when the TARGET has no binary
// layout (open range, union, unbounded int/float). A concrete source yields the
// exact value in `type_fold`; otherwise the folds fall back to the target envelope.
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
			node_span(a, node),
		)
		return
	}

	// Concrete-source fast path. A value under a sized color (`f32:a -> 1.0`) carries
	// its width in the CONSTRAINT, not the unsized value fold — pass src_color so the
	// extractor recolors the bits to the real width.
	src_fold := fold_type(cast_t.value)
	src_color := source_color(cast_t.value)
	if repr, is_concrete := cast_to_bits(src_fold, src_color); is_concrete {
		result := cast_from_bits(repr, target)
		if result != nil do cast_t.type_fold = result
	}
}

// Cast_Target_Kind names the domain a `::` lands in.
Cast_Target_Kind :: enum {
	Integer,
	Float,
	Bool,
	String,
	Char,
}

Cast_Target :: struct {
	kind:       Cast_Target_Kind,
	width:      uint, // bit width for Integer/Float/Bool; ignored for String
	signed:     bool, // Integer signedness
	float_kind: FloatKind, // for Float (f32 -> 32 bits, f64 -> 64 bits)
}

// cast_target derives the target domain + binary layout of a folded constraint,
// if it has one. Fixed-width int builtins, f32/f64, bool, string qualify; open
// ranges, arbitrary intervals, unions, unbounded int/float do not.
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
		return {kind = .Bool, width = 8}, true
	case String_Type:
		// `char` (the ordinal single-codepoint string) reads the source as a CODEPOINT
		// NUMBER, not a byte transmute (65::char -> 'A'). Any other string takes the bytes.
		if len(v.string_intervals) == 1 && v.string_intervals[0].ordinal {
			return {kind = .Char}, true
		}
		return {kind = .String}, true
	}
	return {}, false
}

// source_color resolves the COLOR (declared constraint) of a cast's source,
// distinct from its value: `u8:a -> 65` folds to value 65 but color u8, and the
// raw cast needs the color for the source's bit width. Falls back to the value's
// own constraint fold for a non-reference expression.
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

// unwrap_producer peels a single producer scope `{-> X}` down to X (fold_constraint
// of a value-typed binding can wrap the domain leaf in one).
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
// any domain, plus its source width/signedness. `src_color` is consulted when the
// value fold is unsized (a bare literal under a sized color, e.g. `f32:a -> 1.0`).
// Returns ok=false when the source is not a single concrete value.
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
				return {
						bits = u128(transmute(u32)f32(val)),
						width = 32,
						signed = false,
						from_float = val,
					},
					true
			case .f64, .none:
				// An unsized literal carries f64 bits.
				return {
						bits = u128(transmute(u64)val),
						width = 64,
						signed = false,
						from_float = val,
					},
					true
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
		// float -> float is a VALUE conversion (IEEE rounding), not a bit transmute
		// (f64 1.0 :: f32 -> 1.0f). Other sources transmute bit-for-bit.
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
	case .Char:
		// Read the source bits as a codepoint NUMBER and emit that one character
		// (65::char -> 'A'). An out-of-range value wraps into the valid Unicode
		// space so the result is always a single codepoint.
		cp := rune(bits_reinterpret_int(repr, 32, false) & 0x1FFFFF)
		if cp > CHAR_MAX_CODEPOINT do cp = rune(int(cp) % (CHAR_MAX_CODEPOINT + 1))
		r^ = make_string_const(utf8.runes_to_string({cp}), .simple)
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
			fmt.tprintf(
				"invalid range: left bound %s is not an integer, float, or string",
				describe_value(left_resolved),
			),
			.Invalid_Range,
			node_span(a, node),
		)
		return
	}
	if right_kind == .Invalid {
		sem_error(
			a,
			fmt.tprintf(
				"invalid range: right bound %s is not an integer, float, or string",
				describe_value(right_resolved),
			),
			.Invalid_Range,
			node_span(a, node),
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
			node_span(a, node),
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
		// Chained range (`10..0..30`): family is that of its bounds. An internal
		// inconsistency (`0..30.0`) was already reported by the sub-range's own
		// fold_range — return left's family rather than re-report a misleading error.
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
				return range_operand_kind(v.types[i])
			}
		}
		return .Invalid
	case Mention_Type:
		if v.match_scope != nil && v.match_index >= 0 {
			return range_operand_kind(v.match_scope.types[v.match_index])
		}
		return .Invalid
	case Reference_Type:
		if v.reference != nil && v.reference.match_scope != nil && v.reference.match_index >= 0 {
			return range_operand_kind(v.reference.match_scope.types[v.reference.match_index])
		}
		return .Invalid
	case Negate_Type, And_Type, Or_Type, Compose_Type, Cast_Type:
		// A computed bound (set-algebra, arithmetic, raw cast): family is whatever it
		// folds to, so probe the domains in turn.
		if fold_constraint_integer(t) != nil do return .Integer
		if fold_constraint_float(t) != nil do return .Float
		if fold_constraint_string(t) != nil do return .String
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

fold_carve_type :: proc(t: ^Type) -> ^Scope_Type {
	carve, ok := &t^.(Carve_Type)
	if !ok do return nil

	// Re-entry guard ARMED HERE, not just in carve_substitute: a self-referential
	// carve loops in fold_type(carve.source) below, before carve_substitute is reached.
	// Key on the carve node so the inner re-entry bails to nil.
	a := current_analyzer()
	if a != nil {
		for k in a.carve_fold_stack {
			if k == t do return nil
		}
		append(&a.carve_fold_stack, t)
	}
	defer if a != nil do pop(&a.carve_fold_stack)

	folded := fold_type(carve.source)
	if folded == nil do return nil // self-referential source: the guard cut it
	src, ok2 := &folded^.(Scope_Type)
	if ok2 {
		return carve_substitute(t, carve, src)
	}
	// TODO: err here
	return nil
}

// carve_ref_index maps a carve reference onto the MATERIALIZED source `sub`. The
// frozen match_index describes the DEFINITION-TIME structure; when a substitution
// replaced the source with a structurally different scope (`m{func -> {string:e,
// e->e+""}}` then `func{e->e}` in m's body), the frozen index lands on the wrong
// field — a NAMED reference re-resolves against `sub` by the same rule the
// definition used: the ordinal `#n` when given, else the occurrence rank the frozen
// index had among same-named fields of its definition scope (scope_resolve's carve
// mode picked the first, rank 0). On an unchanged source this recomputes the frozen
// index exactly. -1 when the occurrence is gone from the substituted scope (the
// caller reports). A positional (unnamed) reference keeps its frozen index. Pure
// bookkeeping — no folds, callable from reduce.
carve_ref_index :: proc(ref: Reference, sub: ^Scope_Type) -> int {
	name, has_name := ref.name.(string)
	if !has_name || name == "" do return ref.match_index
	rank := 0
	if o, has_o := ref.index.(u64); has_o {
		rank = int(o)
	} else if ref.match_scope != nil &&
	   ref.match_index >= 0 && ref.match_index < len(ref.match_scope.names) {
		for j in 0 ..< ref.match_index {
			if ref.match_scope.names[j] == name do rank += 1
		}
	}
	idx, _ := nth_named(sub, name, rank)
	return idx
}

carve_substitute :: proc(t: ^Type, carve: ^Carve_Type, src: ^Scope_Type) -> ^Scope_Type {
	copy := scope_clone(src)

	// Apply each override and refresh its cached type_fold — the folders read a
	// mention's fold from the SCOPE's type_folds, so a stale fold here would hide
	// the substitution from sibling mentions.
	for i in 0 ..< len(carve.references) {
		ref := carve.references[i]
		idx := carve_ref_index(ref, copy)
		if idx >= 0 && idx < len(copy.types) {
			if carve.types[i] == nil do continue // malformed override: no replacement
			if mv, is_m := carve.types[i]^.(Mention_Type);
			   is_m && mv.match_scope == src && mv.match_index == idx {
				continue
			}
			if idx < len(copy.constraints) &&
			   copy.constraints[idx] != nil {
				unify_pull(copy.constraints[idx], carve.types[i], copy, src)
			}
			copy.types[idx] = carve.types[i]
			if idx < len(copy.type_folds) {
				copy.type_folds[idx] = fold_type(carve.types[i])
			}
		} else if ref.match_index >= len(copy.types) || (idx < 0 && ref.match_index >= 0) {
			// The override targets a field ABSENT from the substituted source. A carve
			// written literally in source is proven eagerly (carve_resolve_children), but
			// a carve materialized AFTER a substitution — a param carved to `{}` then
			// re-carved `func{e->3}` in the body — reaches here with the field gone: the
			// source shrank under it. Left silent, the override would just vanish and the
			// collapse fold to `none`. emit reports it on recheck_carve's armed span; a
			// nil analyzer (rendering under reduce) no-ops, staying safe.
			name := ref.name.(string) or_else ""
			target := name != "" ? fmt.tprintf("'%s'", name) : "a positional field"
			emit(fmt.tprintf("%s does not exist in the carved scope", target), .Invalid_Carve)
		}
	}

	// Repoint every reference naming the source scope to name the copy, so dependent
	// fields (`y -> x+1`) read the substituted values, cascading transitively. Done
	// in place on `copy`, then refresh the cached folds.
	for v, i in copy.types do copy.types[i] = repoint(v, src, copy)
	for ty, i in copy.constraints do copy.constraints[i] = repoint(ty, src, copy)
	for f, i in copy.constraint_folds do copy.constraint_folds[i] = fold_constraint(copy.constraints[i])
	// The colors are substituted, so re-read every value: a stated one re-folds
	// (`c -> a+b` becomes `"ab"`), a valueless colored one re-materializes from its
	// new color (`-> T:` under `{T -> u8}` is `-> u8:`, i.e. 0). Colors first — the
	// second read consults them.
	for f, i in copy.type_folds do copy.type_folds[i] = fold_type(slot_value(copy, i))

	// Materialization IS the proof obligation: every field of the substituted scope
	// must still inhabit its color. Proving here — not in any walk — is what makes
	// the proof compositional: any fold that materializes a carve, at any depth,
	// under any wrapper, in any environment (walk-time branch refinement or
	// fold_type_pattern's re-install), proves it. No-ops without a live analyzer.
	prove_materialized_carve(carve, copy)
	return copy
}

// scope_clone is a PURE copy: shares each element ^Type pointer and copies the
// cached folds as-is. NO refold here — refolding a still-carved field would re-enter
// fold_carve_constraint on fresh clones forever (the node-keyed guard can't catch
// ever-new clones). carve_substitute repoints and refreshes the folds afterward.
scope_clone :: proc(src: ^Scope_Type) -> ^Scope_Type {
	dst := new(Scope_Type)
	dst.parent = src.parent
	dst.origin = scope_canon(src)
	for n in src.names do append(&dst.names, n)
	for v in src.types do append(&dst.types, v)
	for ty in src.constraints do append(&dst.constraints, ty)
	for k in src.kind do append(&dst.kind, k)
	for f in src.type_folds do append(&dst.type_folds, f)
	for f in src.constraint_folds do append(&dst.constraint_folds, f)
	for c in src.captures do append(&dst.captures, c)
	for i in src.unresolved_captures do dst.unresolved_captures[i] = true
	// Provenance survives cloning: a carved external is still external, so the
	// effect is lifted at the collapse of the clone just as on the original.
	dst.foreign_lib = src.foreign_lib
	return dst
}

// scope_repoint_node rewrites a nested scope's references from `old` to `dst`,
// building the clone IN PLACE inside its final ^Type node (one identity — the
// address internal mentions are repointed to IS the node every consumer sees).
// The clone is a NEW identity, so the scope's own internal self-mentions (a
// production or sibling field mentioning this very scope) are repointed src→clone
// in a second pass — the same law carve_substitute applies to its copy; without
// it a later substitution on the clone misses the internal mentions and their
// stale cached folds survive (`m{func -> {u8:e, -> e+2}}` then `func{e->5}!`
// folding e at its default).
// The fold refresh must NOT run under reduce (reduce_substitute_carve → repoint →
// here): re-entering the analyzer fold layer there would re-materialize carves on
// ever-fresh clones the node-keyed guard can't catch — an unbounded re-fold. So
// the reduce path passes repoint(..., refold=false): the folds are invalidated
// (nil) and recomputed lazily by reduce's own consumers.
scope_repoint_node :: proc(src, old, dst: ^Scope_Type, refold := true) -> ^Type {
	node := new(Type)
	node^ = Scope_Type{}
	rst := &node^.(Scope_Type)
	rst.parent = src.parent
	rst.origin = scope_canon(src)
	for n in src.names do append(&rst.names, n)
	for ty in src.constraints do append(&rst.constraints, repoint(ty, old, dst, refold))
	for k in src.kind do append(&rst.kind, k)
	for v in src.types do append(&rst.types, repoint(v, old, dst, refold))
	// Identity pass: follow internal self-mentions onto the clone.
	for v, i in rst.types do rst.types[i] = repoint(v, src, rst, refold)
	for ty, i in rst.constraints do rst.constraints[i] = repoint(ty, src, rst, refold)
	if refold {
		for f, i in src.constraint_folds do append(&rst.constraint_folds, fold_constraint(rst.constraints[i]))
		// Colors first, then the values that read them (see carve_substitute).
		for f, i in src.type_folds do append(&rst.type_folds, fold_type(slot_value(rst, i)))
	} else {
		for _ in src.type_folds do append(&rst.type_folds, nil)
		for _ in src.constraint_folds do append(&rst.constraint_folds, nil)
	}
	for c in src.captures do append(&rst.captures, c)
	for i in src.unresolved_captures do rst.unresolved_captures[i] = true
	// Provenance survives repointing, for the same reason it survives cloning.
	rst.foreign_lib = src.foreign_lib
	return node
}

// repoint rewrites, copy-on-write, every Mention/Reference inside `t` whose
// match_scope is `old` to point at `dst`, descending through composites and nested
// scopes. A node is cloned only when a descendant changed (unchanged subtrees stay
// shared, the source's ^Types are never mutated). `refold` (default true, analyze
// path) recomputes nested scopes' cached folds; reduce passes false so the fold layer
// (analyzer-only) is never re-entered — folds are invalidated (nil) and recomputed
// lazily instead.
repoint :: proc(t: ^Type, old, dst: ^Scope_Type, refold := true) -> ^Type {
	if t == nil do return t

	#partial switch &v in t^ {
	case Mention_Type:
		if v.match_scope == old {
			return new_type(Mention_Type{v.name, dst, v.match_index})
		}
	case Reference_Type:
		ref := v.reference
		nt := repoint(v.target, old, dst, refold)
		// If the TARGET was substituted, the frozen `(scope, index)` site is stale:
		// re-resolve the property NAME in the new target (this detects a property that
		// disappears after the carve, e.g. `arr->{}` then `arr.#0`).
		if ref != nil && nt != v.target {
			if _, has_name := ref.name.(string); has_name {
				if rr := reresolve_property(nt, ref); rr != nil {
					return rr
				}
			}
		}
		// Repointing the frozen site applies ONLY to a direct ordinal mention-reference
		// (`a#1`: target == nil AND index set). NOT to:
		//  - a property access (`a.r`, target != nil): it reads off whatever `a` resolves
		//    to; rewriting it followed `a` into the carved scope (`a.r` -> `a.r`);
		//  - a source-none property (`.x`: target == nil, index nil): the `.` ALWAYS reads
		//    the ORIGINAL field, so it must keep `old`. Rewriting it to `dst` made `.x`
		//    point at the override that IS `.x` — an infinite self-reference.
		if v.target == nil && ref != nil && ref.index != nil && ref.match_scope == old {
			nref := new(Reference)
			nref^ = Reference{ref.name, ref.index, dst, ref.match_index, ref.span}
			return new_type(Reference_Type{nil, nref})
		}
		if nt != v.target {
			return new_type(Reference_Type{nt, ref})
		}
	case Compose_Type:
		l := repoint(v.left, old, dst, refold)
		r := repoint(v.right, old, dst, refold)
		if l != v.left || r != v.right {
			return new_type(Compose_Type{l, r, v.operator, nil})
		}
	case Or_Type:
		l := repoint(v.left, old, dst, refold)
		r := repoint(v.right, old, dst, refold)
		if l != v.left || r != v.right {
			return new_type(Or_Type{l, r})
		}
	case And_Type:
		l := repoint(v.left, old, dst, refold)
		r := repoint(v.right, old, dst, refold)
		if l != v.left || r != v.right {
			return new_type(And_Type{l, r})
		}
	case Range_Type:
		l := repoint(v.left, old, dst, refold)
		r := repoint(v.right, old, dst, refold)
		if l != v.left || r != v.right {
			return new_type(Range_Type{l, r})
		}
	case Negate_Type:
		o := repoint(v.operand, old, dst, refold)
		if o != v.operand {
			return new_type(Negate_Type{o})
		}
	case Execute_Type:
		tg := repoint(v.target, old, dst, refold)
		if tg != v.target {
			return new_type(Execute_Type{target = tg, caller_scope = v.caller_scope})
		}
	case Pattern_Type:
		// A pattern's target/branches may mention the carved scope. A rewritten branch
		// MATCH has a stale cover_fold (the analysis-time fold of the OLD match) that
		// reduce_branch_fires would fire — re-fold it so reduce agrees with branch_covers.
		// An UNCHANGED match keeps its cached cover_fold.
		tg := repoint(v.target, old, dst, refold)
		changed := tg != v.target
		branches := make([]Pattern_Branch, len(v.branches))
		for branch, i in v.branches {
			m := repoint(branch.match, old, dst, refold)
			p := repoint(branch.product, old, dst, refold)
			cf := branch.cover_fold
			if m != branch.match {
				changed = true
				// refold=false (reduce path): don't re-enter the fold layer; invalidate
				// the stale cover_fold so a reduce-side consumer recomputes it.
				cf = (refold && m != nil) ? fold_constraint(m) : nil
				// The product is lexically a production OF the cover (walk_pattern), so
				// its mentions of the cover's bindings/captures point at the OLD cover
				// scope — which `old`→`dst` doesn't rewrite. Cascade them to the rewritten
				// cover, the same repoint fired_product does, so a substituted constraint
				// inside the cover (e.g. a pull bound by this carve) reaches the product.
				if branch.match != nil && m != nil {
					if oc, o_ok := &branch.match^.(Scope_Type); o_ok {
						if nc, n_ok := &m^.(Scope_Type); n_ok {
							p = repoint(p, oc, nc, refold)
						}
					}
				}
			}
			if p != branch.product do changed = true
			branches[i] = Pattern_Branch{m, p, cf}
		}
		if changed {
			return new_type(Pattern_Type{tg, branches})
		}
	case Carve_Type:
		s := repoint(v.source, old, dst, refold)
		changed := s != v.source
		vals := make([dynamic]^Type, 0, len(v.types))
		for cv in v.types {
			nv := repoint(cv, old, dst, refold)
			if nv != cv do changed = true
			append(&vals, nv)
		}
		if changed {
			refs := make([dynamic]Reference, 0, len(v.references))
			for rf in v.references do append(&refs, rf)
			return new_type(Carve_Type{s, refs, vals, v.span})
		}
	case Scope_Type:
		return scope_repoint_node(&v, old, dst, refold)
	}
	return t
}

new_type :: proc(v: Type) -> ^Type {
	r := new(Type)
	r^ = v
	return r
}
