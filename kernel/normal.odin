package kernel

import syn "../compiler"
import "core:fmt"

// NORMAL FORMS
//
// The type of a term is its normal form: the laws of specs/types.md §4–6, oriented,
// applied from the leaves up. A name is the normal form of its binding's value; a
// scope is itself, a new type. The laws of | & ~ (§4.1, §4.2) compute on constant
// types through their reading (set.odin); what holds an unknown keeps its terms.

normal :: proc(k: ^Kernel, t: Type) -> Type {
	if t == nil do return nil
	switch v in t {
	case Char, Int, Real, Bool, None, Invalid:
		return t
	case ^Unknown:
		ready_layout(k, v)
		return v
	case ^Or:
		return or_law(k, normal_all(k, v.terms))
	case ^And:
		return and_law(k, normal_all(k, v.terms))
	case ^Not:
		return not_law(k, normal(k, v.term))
	case ^Is:
		return is_law(normal(k, v.term))
	case ^Range:
		return range_law(k, normal(k, v.lo), normal(k, v.hi), v.family, v.span)
	case ^Operation:
		if is_string_value(t) do return t // a string: a primitive
		return operation_law(k, v.op, normal_all(k, v.args), v.span)
	case ^Name:
		if v.self != nil do return v.self // the scope being defined: a carve and a collapse apply to it (§5.6)
		return binding_type(k, v.binding)
	case ^Scope:
		return scope_law(k, v)
	case ^Access:
		return access_law(k, normal(k, v.target), v)
	case ^Collapse:
		return collapse_law(k, v)
	case ^Carve:
		return carve_law(k, v)
	case ^Default:
		return default_of(k, normal(k, v.color), v.span)
	case ^Pattern:
		return pattern_law(k, v)
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
	flat := make([dynamic]Type)
	stack := make([dynamic]Type)
	#reverse for t in terms do append(&stack, t)
	for len(stack) > 0 {
		t := pop(&stack)
		if is_invalid(t) do return Invalid{}
		if o, ok := t.(^Or); ok && is_or {
			#reverse for x in o.terms do append(&stack, x)
			continue
		}
		if a, ok := t.(^And); ok && !is_or {
			#reverse for x in a.terms do append(&stack, x)
			continue
		}
		append(&flat, t)
	}
	constants := make([dynamic]Type)
	others := make([dynamic]Type)
	for t in flat {
		switch {
		case is_none(t):
			if !is_or do return None{}
		case is_everything(t):
			if is_or do return everything()
		case is_constant(t):
			append(&constants, t)
		case:
			if !contains_same(k, others[:], t) do append(&others, t)
		}
	}
	if len(constants) > 0 {
		r := read(k, constants[0])
		for c in constants[1:] do r = is_or ? reading_union(r, read(k, c)) : reading_intersect(k, r, read(k, c))
		if r.exact {
			c := rebuild(k, r)
			clear(&constants)
			if is_none(c) {
				if !is_or do return None{}
			} else if is_everything(c) {
				if is_or do return everything()
			} else if o, ok := c.(^Or); ok && is_or {
				append(&constants, ..o.terms)
			} else if a, ok := c.(^And); ok && !is_or {
				append(&constants, ..a.terms)
			} else {
				append(&constants, c)
			}
		}
	}
	parts := make([dynamic]Type)
	append(&parts, ..others[:])
	sort_types(parts[:])
	append(&parts, ..constants[:])
	switch len(parts) {
	case 0:
		return is_or ? Type(None{}) : everything()
	case 1:
		return parts[0]
	}
	return is_or ? new_or(..parts[:]) : new_and(..parts[:])
}

contains_same :: proc(k: ^Kernel, ts: []Type, t: Type) -> bool {
	for x in ts do if same(k, x, t) do return true
	return false
}

// not_law: ~~a = a; ~ of a constant is its complement, as a normal form.
not_law :: proc(k: ^Kernel, t: Type) -> Type {
	if is_invalid(t) do return Invalid{}
	if n, ok := t.(^Not); ok do return n.term
	if is_constant(t) {
		r := read(k, t)
		if r.exact do return rebuild(k, reading_complement(r))
	}
	return new_not(t)
}

// is_law: =p = p for a primitive (§4.4); =t stays: the scope that produces t.
is_law :: proc(t: Type) -> Type {
	if is_invalid(t) do return Invalid{}
	if is_primitive(t) do return t
	return new_is(t)
}

// --- .. (§4.3) ---

// range_law: every primitive from the smallest bound to the largest, in the order
// of their family; a missing bound is infinite; a bound that is itself a range
// gives its extremities: `..0..` is every integer. A bound over unknowns leaves
// the range as it is written: 0..n.
range_law :: proc(k: ^Kernel, lo, hi: Type, family: Range_Family, span: syn.Span) -> Type {
	if is_invalid(lo) || is_invalid(hi) do return Invalid{}
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
			return report(k, .Invalid_Range, span, fmt.tprintf("a bound of a range is one integer, real or character, not %s", print_type(b)))
		}
	}
	if len(values) == 0 do return new_range(nil, nil, of, span)
	f := bound_family(values[0])
	for v in values {
		if !same_bound_family(values[0], v) || of != .Any && f != of {
			return report(k, .Invalid_Range, span, fmt.tprintf("the bounds of %s..%s are of two families", print_type(lo), print_type(hi)))
		}
	}
	of = f
	least, most := values[0], values[0]
	for v in values[1:] {
		if bound_less(v, least) do least = v
		if bound_less(most, v) do most = v
	}
	out := new(Range)
	out^ = Range{family = of, span = span}
	if !below do out.lo = least
	if !above do out.hi = most
	if _, is_char := least.(Char); is_char && out.lo == nil do out.lo = Char(0) // from the smallest character
	r := read(k, out)
	if !r.exact do return out
	return rebuild(k, r)
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
		return x < b.(Real)
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
		saved := k.facts
		k.facts = scope_facts(b.scope)
		b.typed_color = normal(k, b.color)
		k.facts = saved
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
		return report(k, .Infinite_Recursion, b.span, "this value places itself again")
	case .Not_Asked:
	}
	b.state = .In_Progress
	saved := k.facts
	k.facts = scope_facts(b.scope)
	color := binding_color(k, b)
	value: Type
	if u, is_unknown := b.value.(^Unknown); is_unknown && u.written == nil && u.layout == nil {
		u.layout = color != nil ? color : everything()
		value = u
	} else if b.value == nil {
		value = color != nil ? default_of(k, color, b.span) : None{}
	} else if b.kind == .Product {
		root := origin(b.scope)
		k.giving[root] += 1
		value = normal(k, b.value)
		k.giving[root] -= 1
		value = recursion_law(k, b, value)
	} else {
		value = normal(k, b.value)
	}
	if shape, ok := color.(^Scope); ok && b.kind == .Push && is_shape(k, shape) {
		if s, is_scope := value.(^Scope); is_scope do value = colored(k, s, shape)
	}
	k.facts = saved
	b.typed_value, b.state = value, .Done
	return value
}

// scope_facts: the layouts narrowed where a scope is typed: those of the nearest
// branch or carve around it.
scope_facts :: proc(s: ^Scope) -> Facts {
	for sc := s; sc != nil; sc = sc.parent do if sc.facts != nil do return sc.facts
	return nil
}

// ready_layout: the layout of an unknown, in normal form, once.
ready_layout :: proc(k: ^Kernel, u: ^Unknown) {
	if u.layout != nil do return
	u.layout = everything()
	if u.written != nil do u.layout = normal(k, u.written)
}

// --- defaults (§5.5) ---

// default_of: the value a binding colored by c has without one: a set, its
// distinguished element: 0, "", false, otherwise its first; a scope with
// productions, its first; a shape, itself.
default_of :: proc(k: ^Kernel, c: Type, span: syn.Span) -> Type {
	#partial switch v in c {
	case Invalid:
		return Invalid{}
	case ^Scope:
		if p, ok := first_production(k, v); ok do return binding_type(k, p)
		return v
	case ^Is:
		return v.term
	}
	if is_primitive(c) do return c
	if !is_constant(c) do return unsupported_at(k, span, fmt.tprintf("the default of %s, a type over unknowns", print_type(c)))
	r := read(k, c)
	if !r.exact do return unsupported_at(k, span, fmt.tprintf("the default of %s", print_type(c)))
	switch {
	case ints_contains(r.ints, 0):
		return Int(0)
	case reals_contains(r.reals, 0):
		return Real(0)
	case r.words.nullable:
		return empty_string()
	case .False in r.bools:
		return Bool(false)
	case len(r.ints) > 0:
		first := r.ints[0]
		if lo, ok := first.lo.?; ok do return Int(lo)
		hi, _ := first.hi.?
		return Int(hi)
	case len(r.reals) > 0:
		first := r.reals[0]
		if lo, ok := first.lo.?; ok && !first.lo_open do return Real(lo)
		return unsupported_at(k, span, fmt.tprintf("the default of %s, which has no first element", print_type(c)))
	case !words_is_empty(r.words):
		w, _ := words_witness(r.words)
		return string_value(w)
	case .True in r.bools:
		return Bool(true)
	case len(r.scopes) > 0:
		return default_of(k, r.scopes[0], span)
	}
	return None{}
}

unsupported_at :: proc(k: ^Kernel, span: syn.Span, what: string) -> Type {
	return report(k, .Unsupported, span, fmt.tprintf("not in the kernel yet: %s", what))
}
