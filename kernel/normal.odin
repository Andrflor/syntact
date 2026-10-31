package kernel

import syn "../syntax"
import "core:fmt"

// NORMAL FORMS
//
// The type of a term is its normal form: the laws of specs/types.md §4–6, oriented,
// applied from the leaves up. A name is the normal form of its binding's value; a
// scope is itself, a new type. The laws of | & ~ (§4.1, §4.2) compute on constant
// types through their reading (set.odin); what holds an unknown keeps its terms.

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
		return effect_law(k, v, normal(k, v.then))
	case ^Fold:
		return fold_law(k, v)
	case ^Least:
		return least_law(k, v.index, v.holds, v.span)
	case ^Series:
		return series_law(k, v)
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
	return lattice_law(k, terms, false)
}

lattice_law :: proc(k: ^Kernel, terms: []Type, is_or: bool) -> Type {
	from := mark(k)
	defer release(k, from)
	if invalid := flattened(k, terms, is_or); invalid != nil do return invalid
	flat := pushed(k, from)
	constants := mark(k)
	for t in flat {
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
	for t in flat do if !is_constant(t) && !contains_same(k, pushed(k, others), t) do push(k, t)
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
	color := binding_color(k, b)
	value: Type
	if b.value == nil {
		value = color != nil ? default_of(k, color, b.span, b.color) : None{}
	} else if b.kind == .Product {
		value = production_law(k, b)
	} else {
		value = normal(k, b.value)
	}
	// the program is collapsed by nothing: what comes up to it is answered by the
	// default of each emission (§4.9)
	if b.scope == k.root do value = answered_by_program(k, value)
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
	return value
}

// binding_value: what a binding gives back: what its name reads. Its effects are run
// by the scope that holds it (§4.8).
binding_value :: proc(k: ^Kernel, b: ^Binding) -> Type {
	return given(k, binding_type(k, b))
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
	}
	if is_primitive(c) do return c
	if !is_constant(c) do return unsupported_at(k, span, fmt.tprintf("the default of %s, a type over unknowns", print_type(c)))
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
			return default_of(k, cell, span)
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
