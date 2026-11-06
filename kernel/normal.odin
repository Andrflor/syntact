package kernel

import syn "../syntax"
import "core:fmt"
import "core:slice"

// NORMAL FORMS
//
// The type of a term is its normal form: the laws of specs/types.md §4–6, oriented,
// applied from the leaves up. A name is the normal form of its binding's value; a
// scope is itself, a new type. The laws of | & ~ (§4.1, §4.2) compute on constant
// types through their reading (lattice.odin); what holds an unknown keeps its terms.

normal :: proc(k: ^Kernel, t: Type) -> Type {
	if t == nil || normalized(t) do return t
	if form := remembered(t); form != nil do return form
	switch v in t {
	case Char, Int, Real, Bool, None, Invalid:
		return t
	case ^Unknown:
		return v
	case ^Effect:
		if v.emission != nil do return emission_law(k, v)
		if v.write != nil && v.write.place == nil do return write_law(k, v)
		return effect_law(k, v, normal(k, v.then))
	case ^Fold:
		return fold_law(k, v)
	case ^Least:
		return least_law(k, v.index, v.holds, v.span)
	case ^Series:
		s := new(Series)
		s^ = v^
		s.lo, s.hi, s.term = normal(k, v.lo), normal(k, v.hi), normal(k, v.term)
		return series_law(k, s)
	case ^Recurrent:
		return recurrent_law(k, v)
	case ^Name:
		return binding_value(k, v.binding)
	case ^Scope:
		return scope_law(k, v)
	case ^Operation:
		if is_string_value(t) do return t // a string: a primitive
		return remember(t, as_normal(sequence(k, t, normal_all(k, parts(t)), term_law)))
	case ^Or, ^And, ^Not, ^Is, ^Range, ^Access, ^Collapse, ^Carve, ^Default, ^Pattern:
		return remember(t, as_normal(sequence(k, t, normal_all(k, parts(t)), term_law)))
	}
	return t
}

// remembered: the normal form of a closed node, once computed: computed once.
remembered :: proc(t: Type) -> Type {
	#partial switch v in t {
	case ^Operation:
		return v.form
	case ^Or:
		return v.form
	case ^And:
		return v.form
	case ^Not:
		return v.form
	case ^Is:
		return v.form
	case ^Range:
		return v.form
	}
	return nil
}

// remember: form, the normal form of t, kept in t when t is closed.
remember :: proc(t: Type, form: Type) -> Type {
	#partial switch v in t {
	case ^Operation:
		if v.closed do v.form = form
	case ^Or:
		if v.closed do v.form = form
	case ^And:
		if v.closed do v.form = form
	case ^Not:
		if v.closed do v.form = form
	case ^Is:
		if v.closed do v.form = form
	case ^Range:
		if v.closed do v.form = form
	}
	return form
}

// normalized: t is a normal form — normal(normal(t)) = normal(t): what gave it, the
// laws, need not be computed again.
normalized :: proc(t: Type) -> bool {
	#partial switch v in t {
	case ^Operation:
		return v.normal
	case ^Pattern:
		return v.normal
	case ^Or:
		return v.normal
	case ^And:
		return v.normal
	case ^Not:
		return v.normal
	case ^Is:
		return v.normal
	case ^Range:
		return v.normal
	}
	return false
}

// as_normal: t, a normal form the laws gave, known as one.
as_normal :: proc(t: Type) -> Type {
	#partial switch v in t {
	case ^Operation:
		v.normal = true
	case ^Pattern:
		v.normal = true
	case ^Or:
		v.normal = true
	case ^And:
		v.normal = true
	case ^Not:
		v.normal = true
	case ^Is:
		v.normal = true
	case ^Range:
		v.normal = true
	}
	return t
}

// parts: what a term computes on, in the order it is written. A scope holds its
// bindings, a carve places its arguments, a pattern gives one of its branches:
// they are not computed with it.
parts :: proc(t: Type) -> []Type {
	#partial switch v in t {
	case ^Or:
		return v.terms
	case ^And:
		return v.terms
	case ^Not:
		return clone_types({v.term})
	case ^Is:
		return clone_types({v.term})
	case ^Range:
		return clone_types({v.lo, v.hi})
	case ^Operation:
		return v.args
	case ^Access:
		return clone_types({v.target})
	case ^Collapse:
		return clone_types({v.target})
	case ^Carve:
		return clone_types({v.target})
	case ^Default:
		return clone_types({v.color})
	case ^Pattern:
		return clone_types({v.target})
	}
	return nil
}

// term_law: the law of a term on its parts, in normal form and pure.
term_law :: proc(k: ^Kernel, t: Type, parts: []Type) -> Type {
	#partial switch v in t {
	case ^Or:
		return or_law(k, parts)
	case ^And:
		return and_law(k, parts)
	case ^Not:
		return not_law(k, parts[0])
	case ^Is:
		return is_law(parts[0])
	case ^Range:
		return range_law(k, parts[0], parts[1], v.family, v.span)
	case ^Operation:
		return operation_law(k, v.op, parts, v.span)
	case ^Access:
		return access_law(k, parts[0], v)
	case ^Collapse:
		return collapse_law(k, parts[0], v)
	case ^Carve:
		return carve_law(k, parts[0], v)
	case ^Default:
		return default_of(k, parts[0], v.span, v.color)
	case ^Pattern:
		return pattern_on(k, parts[0], v)
	}
	return t
}

normal_all :: proc(k: ^Kernel, ts: []Type) -> []Type {
	out := make([]Type, len(ts))
	for t, i in ts do out[i] = normal(k, t)
	return out
}

// --- | & ~ (§4.1, §4.2) ---

// or_law: | flattened, none neutral, ~none absorbing, a | a = a; its constant
// terms are one normal form.
or_law :: proc(k: ^Kernel, terms: []Type) -> Type {
	return lattice_law(k, terms, true)
}

and_law :: proc(k: ^Kernel, terms: []Type) -> Type {
	// a set the laws keep written, u8 * u8, lies in the range that bounds it: within
	// what that range is within, out of what it is out of
	for t, i in terms {
		o, written := t.(^Operation)
		if !written || o.op == .In || !is_constant(t) || len(terms) < 2 do continue
		h := int_hull(k, t)
		if same(k, h, t) do continue
		others := make([dynamic]Type)
		for x, j in terms do if j != i do append(&others, x)
		rest := len(others) == 1 ? others[0] : and_law(k, others[:])
		if !is_constant(rest) do continue
		if is_none(and_law(k, {h, rest})) do return None{}
		if is_none(and_law(k, {h, not_law(k, rest)})) do return t
	}
	// t & S, t one value: t where t in S is true, none where false (§4.1)
	at := -1
	for t, i in terms {
		if !is_value(k, t) || is_constant(t) && !written_value(t) do continue
		if at >= 0 do return lattice_law(k, terms, false)
		at = i
	}
	if at >= 0 && len(terms) > 1 {
		others := make([dynamic]Type)
		for t, i in terms do if i != at do append(&others, t)
		set := len(others) == 1 ? others[0] : lattice_law(k, others[:], false)
		in_s := in_law(k, terms[at], set)
		if is_bool(in_s, true) do return terms[at]
		if is_bool(in_s, false) do return None{}
		// a pattern gives one of its products: (t ? {c -> p …}) & S = t ? {c -> p & S …}
		if p, is_pattern := terms[at].(^Pattern); is_pattern && !has_effect(p) {
			branches := make([]Branch, len(p.branches))
			for b, i in p.branches do branches[i] = with_product(b, and_law(k, {b.product, set}))
			return pattern_law(k, branching(p, branches))
		}
	}
	return lattice_law(k, terms, false)
}

lattice_law :: proc(k: ^Kernel, terms: []Type, is_or: bool) -> Type {
	from := mark(k)
	defer release(k, from)
	if invalid := flattened(k, terms, is_or); invalid != nil do return invalid
	flat := pushed(k, from)
	// a bound closed by what it excludes, which may make it constant: read with the
	// constants
	if !is_or do closed_bounds(k, flat)
	constants := mark(k)
	for t in flat {
		if t == nil do continue
		switch {
		case is_none(t):
			if !is_or do return None{}
		case is_everything(t):
			if is_or do return everything()
		case is_constant(t):
			push(k, t)
		}
	}
	others := mark(k)
	for t in flat do if t != nil && !is_constant(t) && !contains_same(k, pushed(k, others), t) do push(k, t)
	// a & ~a = none, a | ~a = ~none (§2)
	for t in pushed(k, others) {
		n, negated := t.(^Not)
		if !negated || !contains_same(k, pushed(k, others), n.term) do continue
		return is_or ? everything() : None{}
	}
	parts := mark(k)
	push_all(k, k.scratch[others:parts])
	sort_types(pushed(k, parts))
	if constants < others {
		c := is_or ? or_constants(k, k.scratch[constants:others]) : and_constants(k, k.scratch[constants:others])
		if is_none(c) {
			if !is_or do return None{}
		} else if is_everything(c) {
			if is_or do return everything()
		} else if o, ok := c.(^Or); ok && is_or {
			push_all(k, o.terms)
		} else {
			push(k, c)
		}
	}
	combined := pushed(k, parts)
	switch len(combined) {
	case 0:
		return is_or ? Type(None{}) : everything()
	case 1:
		return combined[0]
	}
	return is_or ? new_or(..combined) : new_and(..combined)
}

// flattened: the terms of a | — or of a & —, pushed in order: a | (b | c) is
// a | b | c; the first invalid one instead.
flattened :: proc(k: ^Kernel, terms: []Type, is_or: bool) -> (invalid: Type) {
	for t in terms {
		if is_invalid(t) do return t
		if o, ok := t.(^Or); ok && is_or {
			if x := flattened(k, o.terms, is_or); x != nil do return x
			continue
		}
		if a, ok := t.(^And); ok && !is_or {
			if x := flattened(k, a.terms, is_or); x != nil do return x
			continue
		}
		push(k, t)
	}
	return nil
}

contains_same :: proc(k: ^Kernel, ts: []Type, t: Type) -> bool {
	for x in ts do if same(k, x, t) do return true
	return false
}

// not_law: ~~a = a; ~ of a constant is its complement, as a normal form.
not_law :: proc(k: ^Kernel, t: Type) -> Type {
	if is_invalid(t) do return t
	if n, ok := t.(^Not); ok do return n.term
	if is_constant(t) do return not_constant(k, t)
	return new_not(t)
}

// is_law: =p = p for a primitive (§4.4); =t stays: the scope that produces t.
is_law :: proc(t: Type) -> Type {
	if is_invalid(t) do return t
	if is_primitive(t) do return t
	return new_is(t)
}

// --- .. (§4.3) ---

// range_law: every primitive from the smallest bound to the largest, in the order
// of their family; a missing bound is infinite; a bound that is itself a range
// gives its extremities: `..0..` is every integer. A bound over unknowns leaves
// the range as it is written: 0..n.
range_law :: proc(k: ^Kernel, lo, hi: Type, family: Range_Family, span: syn.Span) -> Type {
	if is_invalid(lo) do return lo
	if is_invalid(hi) do return hi
	for b in ([2]Type{lo, hi}) do if b != nil && !is_constant(b) do return new_range(lo, hi, family, span)
	if is_word(lo) || is_word(hi) {
		// between strings, `..` is about positions: l..u = (l + string) & (string + u)
		parts := make([dynamic]Type)
		if lo != nil do append(&parts, concatenation({lo, string_term()}))
		if hi != nil do append(&parts, concatenation({string_term(), hi}))
		return and_law(k, parts[:])
	}
	values := make([dynamic]Type)
	below, above := lo == nil, hi == nil
	of := family
	for b in ([2]Type{lo, hi}) {
		if b == nil do continue
		if is_empty_string(b) {
			append(&values, Char(0)) // '' as a bound: the smallest character
			continue
		}
		if r, nested := b.(^Range); nested {
			if r.lo == nil do below = true
			if r.hi == nil do above = true
			if r.lo != nil do append(&values, r.lo)
			if r.hi != nil do append(&values, r.hi)
			if r.family != .Any do of = r.family
			continue
		}
		#partial switch _ in b {
		case Int, Real, Char:
			append(&values, b)
		case:
			return problem(.Invalid_Range, span, fmt.tprintf("a bound of a range is one integer, real or character, not %s", print_type(b)))
		}
	}
	if len(values) == 0 {
		switch of {
		case .Int:
			return discrete_cell(.Int, nil, nil)
		case .Real, .F16, .F32, .F64:
			return real_cell({format = real_format(of)})
		case .Any:
		}
		// `..`: every primitive
		return or_constants(k, {discrete_cell(.Int, nil, nil), real_cell({}), discrete_cell(.Char, 0, nil), Bool(false), Bool(true)})
	}
	f := bound_family(values[0])
	// the bounds of a range of a format are reals
	expected := real_format(of) != .Exact ? Range_Family.Real : of
	for v in values {
		if !same_bound_family(values[0], v) || of != .Any && f != expected {
			return problem(.Invalid_Range, span, fmt.tprintf("the bounds of %s..%s are of two families", print_type(lo), print_type(hi)))
		}
	}
	least, most := values[0], values[0]
	for v in values[1:] {
		if bound_less(v, least) do least = v
		if bound_less(most, v) do most = v
	}
	#partial switch x in least {
	case Real:
		b := Real_Bounds{format = real_format(of)}
		if !below do b.lo = x
		if !above do b.hi = most.(Real)
		return real_cell(b)
	case Char:
		lo, hi: Maybe(i128)
		if !below do lo = i128(x)
		if !above do hi = i128(most.(Char))
		return discrete_cell(.Char, lo, hi)
	case Int:
		lo, hi: Maybe(i128)
		if !below do lo = i128(x)
		if !above do hi = i128(most.(Int))
		return discrete_cell(.Int, lo, hi)
	}
	return problem(.Invalid_Range, span, "a range is between integers, reals or characters")
}

// is_word: a string of two characters or more.
is_word :: proc(t: Type) -> bool {
	o, ok := t.(^Operation)
	return ok && is_string_value(t) && len(o.args) >= 2
}

bound_family :: proc(b: Type) -> Range_Family {
	#partial switch _ in b {
	case Int:
		return .Int
	case Real:
		return .Real
	}
	return .Any
}

same_bound_family :: proc(a, b: Type) -> bool {
	#partial switch _ in a {
	case Int:
		_, ok := b.(Int)
		return ok
	case Real:
		_, ok := b.(Real)
		return ok
	case Char:
		_, ok := b.(Char)
		return ok
	}
	return false
}

bound_less :: proc(a, b: Type) -> bool {
	#partial switch x in a {
	case Int:
		return x < b.(Int)
	case Real:
		return real_less(x, b.(Real))
	case Char:
		return x < b.(Char)
	}
	return false
}

// --- bindings (§5.2) ---

// binding_color: the normal form of a binding's color; nil when it has none.
binding_color :: proc(k: ^Kernel, b: ^Binding) -> Type {
	if b.color == nil do return nil
	if b.typed_color == nil {
		b.typed_color = normal(k, b.color)
	}
	return b.typed_color
}

// binding_type: the normal form of a binding's value, given once. A binding
// without a value has the default of its color (§5.5); `??` takes the layout of
// its color. Asked again while it is given, it is an infinite recursion.
binding_type :: proc(k: ^Kernel, b: ^Binding) -> Type {
	switch b.state {
	case .Done:
		return b.typed_value
	case .In_Progress:
		return problem(.Infinite_Recursion, b.span, "this value places itself again")
	case .Not_Asked:
	}
	b.state = .In_Progress
	given_toggled(k, .Binding, b)
	color := binding_color(k, b)
	value: Type
	if b.value == nil {
		value = color != nil ? default_of(k, color, b.span, b.color) : None{}
	} else if b.kind == .Product {
		value = production_law(k, b)
	} else {
		value = normal(k, b.value)
	}
	// a binding that reads places reads them where it is written: a pin; a reactive
	// one reads them where it is read (§4.14)
	// an argument of a carve is read by what computes the carve, where it is
	if b.kind == .Push && b.resonance == nil && !b.reactive && !b.carved && b.name != "" && !has_effect(value) && reads_places(value) do value = pinned(k, value, b.span)
	// the program is collapsed by nothing: what comes up to it is answered by the
	// default of each emission (§4.9)
	// and the places that die with what it runs are freed (§4.12)
	if b.scope == k.root do value = freed(k, answered_by_program(k, value), k.root)
	// a production keeps the effects of the bindings above it, even those it does not
	// name (§4.8)
	if b.kind == .Product {
		b.typed_product = value
		value = with_effects(k, b.scope, b, value)
	}
	// a real in a color of a format is what the machine holds of it (format.odin)
	if f := color_format(color); f != .Exact && b.kind == .Push do value = round_law(k, value, f, b.span)
	// the color flows down into the value (§5.4): a shape, or the solution of a
	// recursive scope, which is one
	if shape, ok := color.(^Scope); ok && b.kind == .Push {
		if recursive(shape) do shape = arden(k, shape) or_else nil
		if s, is_scope := value.(^Scope); is_scope && shape != nil && is_shape(k, shape) do value = colored(k, s, shape)
	}
	b.typed_value, b.state = value, .Done
	given_toggled(k, .Binding, b)
	return value
}

// binding_value: what a binding gives back: what its name reads. Its effects are run
// by the scope that holds it (§4.8).
binding_value :: proc(k: ^Kernel, b: ^Binding) -> Type {
	return given(k, binding_type(k, b))
}

// written_value: a scope without production each of whose bindings is written
// with its value: one value, not a set of them (a shape, a scope that produces).
// {}, the empty run, is one.
written_value :: proc(t: Type) -> bool {
	s, is_scope := t.(^Scope)
	if !is_scope do return false
	for b in s.bindings do if b.kind == .Product || b.value == nil || b.color != nil do return false
	return true
}

// --- defaults (§5.5) ---

// default_of: the value a binding colored by c has without one: a set, its
// distinguished element: 0, "", false, otherwise its first; a scope with
// productions, its first; a shape, itself.
default_of :: proc(k: ^Kernel, c: Type, span: syn.Span, written: Type = nil) -> Type {
	#partial switch v in c {
	case Invalid:
		return c
	case ^Scope:
		if p, ok := first_production(k, v); ok {
			if places_itself(k, v, p) do return problem(.Infinite_Recursion, p.span, "the base case places its scope again")
			return binding_type(k, p)
		}
		return v
	case ^Is:
		return v.term
	case ^And:
		// a meet the laws keep written: the default of one of its terms that it holds
		for t in v.terms {
			if is_negated(t) do continue
			d := default_of(k, t, span)
			if !is_invalid(d) && is_bool(in_law(k, d, c), true) do return d
		}
		return unsupported_at(k, span, fmt.tprintf("the default of %s", print_type(c)))
	case ^Operation:
		// a run of n pieces: none of them, {}, when n may be 0; otherwise n times the
		// default of a piece of one binding: the run a fold builds (§5.5)
		if piece, pieces := v.args[0].(^Scope); pieces && v.op == .Mul {
			if is_bool(in_law(k, Int(0), v.args[1]), true) do return run_scope(k, nil)
			inner := placed(k, piece, .Shape)
			if len(inner) == 1 && !is_run(inner[0]) && inner[0].color != nil && is_value(k, v.args[1]) {
				f := new(Fold)
				f.index, f.span = new_unknown(k, nil), span
				f.index.layout = COUNTS
				f.start, f.next, f.stop = Int(0), op(k, .Add, f.index, Int(1)), new_range(v.args[1], nil, .Int)
				z := new_unknown(k, nil)
				z.layout = family_term(.Scope)
				f.states, f.inits = slice.clone([]^Unknown{z}), slice.clone([]Type{Type(run_scope(k, nil))})
				item := run_scope(k, nil)
				d := new_binding(item, .Push, span)
				d.value = default_of(k, binding_color(k, inner[0]), span)
				f.updates = slice.clone([]Type{joined(k, {z}, nil, nil, {Type(item)})})
				f.value, f.effects = z, None{}
				return folded(k, f)
			}
		}
	}
	if is_primitive(c) do return c
	// over unknowns: its distinguished element 0, when it is proven to hold it
	if !is_constant(c) {
		if verdict, _ := prove(k, in_law(k, Int(0), c)); verdict == .Proven do return Int(0)
		return unsupported_at(k, span, fmt.tprintf("the default of %s, a type over unknowns", print_type(c)))
	}
	// its distinguished element, when it holds it
	for d in ([3]Type{Int(0), real_int(0), empty_string()}) do if !is_none(and_law(k, {d, c})) && inhabited(k, and_law(k, {d, c})) do return d
	if !is_none(and_law(k, {Bool(false), c})) do return Bool(false)
	// otherwise its first element, as written: .. is commutative, the default is not
	if first, ok := written_first(k, written); ok && inhabited(k, and_law(k, {first, c})) do return first
	one: [1]Type
	cells, negated := cells_in(c, &one)
	if negated do return unsupported_at(k, span, fmt.tprintf("the default of %s", print_type(c)))
	for cell in cells {
		switch cell_family(cell) {
		case .Int:
			lo, hi := discrete_bounds(cell)
			if x, ok := lo.?; ok do return Int(x)
			if x, ok := hi.?; ok do return Int(x)
		case .Real:
			b := real_bounds(cell)
			if x, ok := b.lo.?; ok && !b.lo_open do return x
			return unsupported_at(k, span, fmt.tprintf("the default of %s, which has no first element", print_type(c)))
		case .Char:
			lo, _ := discrete_bounds(cell)
			return Char(rune(lo.? or_else 0))
		case .Text:
			w, _ := text_witness(cell)
			return string_value(w)
		case .Bool:
			return cell
		case .Value:
			if i, ok := cell.(^Is); ok do return i.term
			if _, scope := cell.(^Scope); scope do return default_of(k, cell, span)
			// a meet the laws leave: no first element is written
			return unsupported_at(k, span, fmt.tprintf("the default of %s", print_type(c)))
		case .Other:
			return unsupported_at(k, span, fmt.tprintf("the default of %s", print_type(c)))
		}
	}
	return None{}
}

// written_first: the first element of a color as written: the bound written first of
// a range, the first term of a |, through the names of the aliases.
written_first :: proc(k: ^Kernel, t: Type) -> (Type, bool) {
	#partial switch v in t {
	case ^Range:
		if v.lo == nil do return nil, false
		lo := normal(k, v.lo)
		return lo, is_primitive(lo)
	case ^Or:
		return written_first(k, v.terms[0])
	case ^Name:
		if v.binding.value != nil do return written_first(k, v.binding.value)
	}
	return nil, false
}

// places_itself: the first production of s, its base case, places s again (§5.6):
// a shape that places s in a run — as a value, the default of s, its base case,
// again —, or an equation, as written, that calls s outside any branch. Asked, it
// asks itself again: an infinite recursion. The equation is read as written: under
// the defaults, a pattern on a known value is gone, not its guard.
places_itself :: proc(k: ^Kernel, s: ^Scope, p: ^Binding) -> bool {
	if p.state == .In_Progress do return false
	if calls_itself(p.value) do return true
	shape, is_scope := binding_type(k, p).(^Scope)
	if !is_scope do return false
	if !is_shape(k, shape) do return false
	for b in placed(k, shape, .Shape) do if is_run(b) && b.color != nil && same(k, binding_color(k, b), s) do return true
	return false
}

// calls_itself: t makes a recursive call whatever the values: outside the branches
// of a pattern, and outside a scope, whose values are only read when asked.
calls_itself :: proc(t: Type) -> bool {
	#partial switch v in t {
	case ^Collapse:
		return v.recursive || calls_itself(v.target)
	case ^Operation:
		for a in v.args do if calls_itself(a) do return true
	case ^Or:
		for a in v.terms do if calls_itself(a) do return true
	case ^And:
		for a in v.terms do if calls_itself(a) do return true
	case ^Not:
		return calls_itself(v.term)
	case ^Is:
		return calls_itself(v.term)
	case ^Range:
		return calls_itself(v.lo) || calls_itself(v.hi)
	case ^Access:
		return calls_itself(v.target)
	case ^Carve:
		if calls_itself(v.target) do return true
		for a in v.args do if calls_itself(a.value) do return true
	case ^Pattern:
		return calls_itself(v.target)
	}
	return false
}

unsupported_at :: proc(k: ^Kernel, span: syn.Span, what: string) -> Type {
	return problem(.Unsupported, span, fmt.tprintf("not in the kernel yet: %s", what))
}

// closed_bounds: on the integers, a bound left open is the next one closed (§4.3):
// t.. & ~t = (t + 1).., ..t & ~t = ..(t - 1), and the complement of a ray is the
// other ray: int & ~(t..) = int & ..(t - 1), int & ~(..t) = int & (t + 1)... The
// terms it joins are set to nil.
closed_bounds :: proc(k: ^Kernel, terms: []Type) {
	integers := false
	for t in terms do if is_constant(t) && integer_set(t) do integers = true
	for t, i in terms {
		if n, is_not := t.(^Not); is_not && integers {
			if r, is_range := n.term.(^Range); is_range {
				if r.lo != nil && r.hi == nil && integer_term(k, r.lo) do terms[i] = range_law(k, nil, op(k, .Sub, r.lo, Int(1)), .Int, r.span)
				else if r.hi != nil && r.lo == nil && integer_term(k, r.hi) do terms[i] = range_law(k, op(k, .Add, r.hi, Int(1)), nil, .Int, r.span)
			}
		}
	}
	for t, i in terms {
		r, is_range := t.(^Range)
		if !is_range do continue
		for u, j in terms {
			n, is_not := u.(^Not)
			if !is_not || j == i do continue
			if !integer_term(k, n.term) do continue
			if r.lo != nil && r.hi == nil && same(k, r.lo, n.term) {
				terms[i], terms[j] = range_law(k, op(k, .Add, r.lo, Int(1)), nil, .Int, r.span), nil
				break
			}
			if r.hi != nil && r.lo == nil && same(k, r.hi, n.term) {
				terms[i], terms[j] = range_law(k, nil, op(k, .Sub, r.hi, Int(1)), .Int, r.span), nil
				break
			}
		}
	}
}

// integer_set: a constant set of integers only.
integer_set :: proc(t: Type) -> bool {
	one: [1]Type
	cells, negated := cells_in(t, &one)
	if negated || len(cells) == 0 do return false
	for c in cells do if cell_family(c) != .Int do return false
	return true
}

// integer_term: t is an integer by its form, without a proof: an integer, an
// unknown whose layout is integers, a +, - or * of such terms.
integer_term :: proc(k: ^Kernel, t: Type) -> bool {
	#partial switch v in t {
	case Int:
		return true
	case ^Unknown:
		layout := layout_of(k, v)
		return is_constant(layout) && integer_set(layout)
	case ^Operation:
		#partial switch v.op {
		case .Add, .Sub, .Mul, .Neg:
			for a in v.args do if !integer_term(k, a) do return false
			return true
		}
	}
	return false
}
