package compiler

import "core:fmt"
import "core:unicode/utf8"

// reference_effective_value resolves the VALUE a Reference_Type denotes, honoring
// a carve in its target: when the target resolves to a carve overriding this exact
// field, return the override's value, not the stale pre-carve site value.
reference_effective_value :: proc(v: Reference_Type) -> ^Type {
	ref := v.reference
	if ref == nil || ref.match_scope == nil || ref.match_index < 0 do return nil
	original := ref.match_scope.types[ref.match_index]
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
	nref^ = Reference{ref.name, ref.index, prop_scope, prop_index}
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

// fold_type yields the TYPE of a value (the RIGHT side, a typeof).
// Singleton -> the value itself; any wider set -> the producer scope {-> set}.
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
				return fold_type(v.match_scope.types[v.match_index])
			}
		case Reference_Type:
			eff := reference_effective_value(v)
			if eff != nil do return fold_type(eff)
		case Recursive_Mention_Type:
			return t
		case And_Type:
			if env := fold_type_integer(t); env != nil do return value_type_envelope(env)
			if env := fold_type_float(t); env != nil do return value_type_envelope(env)
			if env := fold_type_bool(t); env != nil do return value_type_envelope(env)
			if env := fold_type_string(t); env != nil do return value_type_envelope(env)
			return new_type(And_Type{fold_type(v.left), fold_type(v.right)})
		case Or_Type:
			if env := fold_type_integer(t); env != nil do return value_type_envelope(env)
			if env := fold_type_float(t); env != nil do return value_type_envelope(env)
			if env := fold_type_bool(t); env != nil do return value_type_envelope(env)
			if env := fold_type_string(t); env != nil do return value_type_envelope(env)
			return new_type(Or_Type{fold_type(v.left), fold_type(v.right)})
		case Negate_Type:
			if env := fold_type_integer(t); env != nil do return value_type_envelope(env)
			if env := fold_type_float(t); env != nil do return value_type_envelope(env)
			if env := fold_type_bool(t); env != nil do return value_type_envelope(env)
			if env := fold_type_string(t); env != nil do return value_type_envelope(env)
			return new_type(Negate_Type{fold_type(v.operand)})
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
			// A comparison is a bool VALUE; its typeof is the full `{true,false}` so a
			// `=true -> … =false -> …` pattern over it is exhaustive.
			if is_comparison_op(v.operator) {
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
execute_production :: proc(t: ^Type) -> (prod: ^Type, resolved: bool) {
	cur := follow(t)
	for cur != nil {
		#partial switch &v in cur^ {
		case Scope_Type:
			for i := 0; i < len(v.kind); i += 1 {
				if v.kind[i] == .Product do return v.types[i], true
			}
			return nil, true
		case Carve_Type:
			sub := fold_carve_type(cur)
			if sub == nil do return nil, false
			for i := 0; i < len(sub.kind); i += 1 {
				if sub.kind[i] == .Product do return sub.types[i], true
			}
			return nil, true
		}
		break
	}
	return nil, false
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
			for i := 0; i < len(v.kind); i += 1 {
				if v.kind[i] == .Product {
					def := type_default(v.types[i])
					if def != nil do return def
					return v.types[i]
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
	// A comparison produces a BOOL, never an interval — fold to a full Bool so a
	// `=true -> … =false -> …` pattern over it is exhaustive.
	if is_comparison_op(comp.operator) {
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

carve_substitute :: proc(t: ^Type, carve: ^Carve_Type, src: ^Scope_Type) -> ^Scope_Type {
	copy := scope_clone(src)

	// Apply each override and refresh its cached type_fold — the folders read a
	// mention's fold from the SCOPE's type_folds, so a stale fold here would hide
	// the substitution from sibling mentions.
	for i in 0 ..< len(carve.references) {
		ref := carve.references[i]
		if ref.match_index >= 0 && ref.match_index < len(copy.types) {
			if mv, is_m := carve.types[i]^.(Mention_Type);
			   is_m && mv.match_scope == src && mv.match_index == ref.match_index {
				continue
			}
			if ref.match_index < len(copy.constraints) &&
			   copy.constraints[ref.match_index] != nil {
				unify_pull(copy.constraints[ref.match_index], carve.types[i], copy, src)
			}
			copy.types[ref.match_index] = carve.types[i]
			if ref.match_index < len(copy.type_folds) {
				copy.type_folds[ref.match_index] = fold_type(carve.types[i])
			}
		}
	}

	// Repoint every reference naming the source scope to name the copy, so dependent
	// fields (`y -> x+1`) read the substituted values, cascading transitively. Done
	// in place on `copy`, then refresh the cached folds.
	for v, i in copy.types do copy.types[i] = repoint(v, src, copy)
	for ty, i in copy.constraints do copy.constraints[i] = repoint(ty, src, copy)
	for f, i in copy.type_folds do copy.type_folds[i] = fold_type(copy.types[i])
	for f, i in copy.constraint_folds do copy.constraint_folds[i] = fold_constraint(copy.constraints[i])

	return copy
}

// scope_clone is a PURE copy: shares each element ^Type pointer and copies the
// cached folds as-is. NO refold here — refolding a still-carved field would re-enter
// fold_carve_constraint on fresh clones forever (the node-keyed guard can't catch
// ever-new clones). carve_substitute repoints and refreshes the folds afterward.
scope_clone :: proc(src: ^Scope_Type) -> ^Scope_Type {
	dst := new(Scope_Type)
	dst.parent = src.parent
	for n in src.names do append(&dst.names, n)
	for v in src.types do append(&dst.types, v)
	for ty in src.constraints do append(&dst.constraints, ty)
	for k in src.kind do append(&dst.kind, k)
	for f in src.type_folds do append(&dst.type_folds, f)
	for f in src.constraint_folds do append(&dst.constraint_folds, f)
	for c in src.captures do append(&dst.captures, c)
	return dst
}

scope_repoint :: proc(src, old, dst: ^Scope_Type) -> ^Scope_Type {
	rst := new(Scope_Type)
	rst.parent = src.parent
	for n in src.names do append(&rst.names, n)
	for ty in src.constraints do append(&rst.constraints, repoint(ty, old, dst))
	for k in src.kind do append(&rst.kind, k)
	for v in src.types do append(&rst.types, repoint(v, old, dst))
	for f, i in src.type_folds do append(&rst.type_folds, fold_type(rst.types[i]))
	for f, i in src.constraint_folds do append(&rst.constraint_folds, fold_constraint(rst.constraints[i]))
	for c in src.captures do append(&rst.captures, c)
	return rst
}

// repoint rewrites, copy-on-write, every Mention/Reference inside `t` whose
// match_scope is `old` to point at `dst`, descending through composites and nested
// scopes. A node is cloned only when a descendant changed (unchanged subtrees stay
// shared, the source's ^Types are never mutated).
repoint :: proc(t: ^Type, old, dst: ^Scope_Type) -> ^Type {
	if t == nil do return t

	#partial switch &v in t^ {
	case Mention_Type:
		if v.match_scope == old {
			return new_type(Mention_Type{v.name, dst, v.match_index})
		}
	case Reference_Type:
		ref := v.reference
		nt := repoint(v.target, old, dst)
		// If the TARGET was substituted, the frozen `(scope, index)` site is stale:
		// re-resolve the property NAME in the new target. Only when the target changed
		// and the reference is name-keyed (a property access, not a plain mention-ref).
		if ref != nil && nt != v.target {
			if _, has_name := ref.name.(string); has_name {
				if rr := reresolve_property(nt, ref); rr != nil {
					return rr
				}
			}
		}
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
	case Pattern_Type:
		// A pattern's target/branches may mention the carved scope. A rewritten branch
		// MATCH has a stale cover_fold (the analysis-time fold of the OLD match) that
		// reduce_branch_fires would fire — re-fold it so reduce agrees with branch_covers.
		// An UNCHANGED match keeps its cached cover_fold.
		tg := repoint(v.target, old, dst)
		changed := tg != v.target
		branches := make([]Pattern_Branch, len(v.branches))
		for branch, i in v.branches {
			m := repoint(branch.match, old, dst)
			p := repoint(branch.product, old, dst)
			cf := branch.cover_fold
			if m != branch.match {
				changed = true
				cf = m != nil ? fold_constraint(m) : nil
			}
			if p != branch.product do changed = true
			branches[i] = Pattern_Branch{m, p, cf}
		}
		if changed {
			return new_type(Pattern_Type{tg, branches})
		}
	case Carve_Type:
		s := repoint(v.source, old, dst)
		changed := s != v.source
		vals := make([dynamic]^Type, 0, len(v.types))
		for cv in v.types {
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
		rs := scope_repoint(&v, old, dst)
		return new_type(rs^)
	}
	return t
}

new_type :: proc(v: Type) -> ^Type {
	r := new(Type)
	r^ = v
	return r
}
