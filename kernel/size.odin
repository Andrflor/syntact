package kernel

// SIZES
//
// A type carries its size, as an unknown carries its domain: the bits a value of it
// takes. The size is itself a type — a term over the unknowns the type depends on —,
// whose least and greatest elements are the least and greatest sizes, the greatest
// infinite when nothing bounds it. What is known takes nothing: one value has
// nothing to hold. The backend only aligns what the type says.
//
// A term is one value: a set written as a value — `u8`, `{u8: u8:}` — is the type
// itself, known. A set is the values an unknown may take: its layout.
//
//   size(t), t known        = 0                      one value: nothing to hold
//   size(?ₖ::L)             = size of the set L
//   size(t over unknowns)   = size of the set of its values: its layout
//   size(t ? {c -> p …})    = size(p) | …             the size of the branch taken
//   size(εₖ(x, t))          = size(t)                 what it gives back
//   size({b…})              = Σ size(b)               a field takes what its type
//                                                     takes; a hole, a handler, a
//                                                     production take nothing
//
//   the set lo..hi          = bits(hi - lo + 1)       integers, characters: the span
//   the set false | true    = 1
//   the set s₁ | … | sₙ     = bits(n)                 strings, all known: which one
//   the set A + B           = size(A) + size(B)       a string: its pieces
//   the set A * n           = n * size(A)             a repetition: a string, a run
//   the set {C₁: …C₂: …}    = Σ size(Cᵢ)              a shape: its places; a run
//                                                     `...C:`, what C admits taken
//                                                     as a scope

// size: the bits the value t takes, t in normal form, as a type.
size :: proc(k: ^Kernel, t: Type) -> Type {
	#partial switch v in t {
	case Invalid:
		return t
	case ^Unknown:
		return set_size(k, layout_of(k, v))
	case ^Effect:
		return size(k, given(k, t))
	case ^Pattern:
		sizes := make([]Type, len(v.branches))
		for b, i in v.branches do sizes[i] = size(k, b.product)
		return or_law(k, sizes)
	case ^Scope:
		return fields_size(k, v)
	case ^Operation:
		// a rounding is what the machine holds: a value of its format
		if v.op == .Round do return Int(i128(FORMATS[rounded_format(v)].bits))
	}
	if is_constant(t) do return Int(0)
	image, ok := layout_image(k, t)
	if !ok do return problem(.Unsupported, {}, "this term has no size this kernel computes yet")
	return set_size(k, image)
}

// fields_size: the sum of what the fields of the scope s take. A hole is filled when
// the program is typed, a handler answers then, an emission whose answer no name
// holds gives nothing to hold, a production is computed by a collapse: none of them
// is held.
fields_size :: proc(k: ^Kernel, s: ^Scope) -> Type {
	total := Type(Int(0))
	for b in placed(k, s, .Value) {
		if b.kind != .Push || b.name == "" && is_emission(b.value) do continue
		taken := size(k, binding_type(k, b))
		if is_invalid(taken) do return taken
		total = sum_sizes(k, total, taken)
	}
	return total
}

// set_size: the bits a value of the set s takes.
set_size :: proc(k: ^Kernel, s: Type) -> Type {
	#partial switch v in s {
	case Invalid:
		return s
	case Char, Int, Real, Bool, None:
		return Int(0)
	case ^Scope:
		return shape_size(k, v)
	case ^Operation:
		if v.op == .Mul && repeats(v.args[0]) do return repeat_size(k, v.args[1], set_size(k, v.args[0]))
		if v.op == .Add && is_text(s) {
			total := Type(Int(0))
			for a in v.args do total = sum_sizes(k, total, set_size(k, a))
			return total
		}
	}
	if lo, hi, ok := int_bounds(k, s); ok {
		if lo == nil || hi == nil do return unbounded_size()
		return Int(bits_for(count_between(lo.?, hi.?)))
	}
	one: [1]Type
	cells, negated := cells_in(s, &one)
	if negated || len(cells) == 0 do return unbounded_size()
	families: bit_set[Cell_Family]
	for c in cells do families += {cell_family(c)}
	switch {
	case families == {.Bool}:
		return Int(bits_for(u128(len(cells))))
	case families == {.Char}:
		lo, _ := discrete_bounds(cells[0])
		_, hi := discrete_bounds(cells[len(cells) - 1])
		if lo == nil || hi == nil do return unbounded_size()
		return Int(bits_for(count_between(lo.?, hi.?)))
	case families == {.Real}:
		return reals_size(cells)
	case families <= {.Text, .Char}:
		for c in cells {
			if _, is_char := c.(Char); !is_char && !is_string_value(c) {
				return problem(.Unsupported, {}, "the size of a union of strings not all known is not decided yet")
			}
		}
		return Int(bits_for(u128(len(cells))))
	}
	return problem(.Unsupported, {}, "the size of a union of several families or shapes is not decided yet")
}

// reals_size: the bits a value of real cells takes: known reals, which one; the
// reals of formats, the widest — each known real among them held by it —; every
// real of an interval, no bound.
reals_size :: proc(cells: []Type) -> Type {
	points := 0
	widest := Real_Format.F16
	for c in cells {
		b := real_bounds(c)
		if is_point(b) {
			points += 1
			continue
		}
		if b.format == .Exact do return unbounded_size()
		widest = max(widest, b.format)
	}
	if points == len(cells) do return Int(bits_for(u128(points)))
	for c in cells {
		if b := real_bounds(c); is_point(b) && !representable(b.lo.?, widest) do return unbounded_size()
	}
	return Int(i128(FORMATS[widest].bits))
}

// shape_size: the bits a value the scope s admits takes. A shape: the sum of its
// places, each what its color admits — a run `...C:`, what C admits taken as a
// scope (§5.4). A scope with productions: the shape Arden solves it to (§5.6).
shape_size :: proc(k: ^Kernel, s: ^Scope) -> Type {
	if !is_shape(k, s) {
		solution, solved := arden(k, s)
		if !solved || solution == s do return problem(.Unsupported, {}, "the size of what these productions admit is not computed yet")
		return shape_size(k, solution)
	}
	total := Type(Int(0))
	for b in placed(k, s, .Shape) {
		if b.kind == .Pull || b.kind == .Handler do continue
		color := binding_color(k, b)
		taken := color == nil ? unbounded_size() : set_size(k, color)
		if is_invalid(taken) do return taken
		total = sum_sizes(k, total, taken)
	}
	return total
}

// sum_sizes: a + b, two sizes; nothing added to a size leaves it.
sum_sizes :: proc(k: ^Kernel, a, b: Type) -> Type {
	if takes_nothing(a) do return b
	if takes_nothing(b) do return a
	return operation_law(k, .Add, {a, b}, {})
}

// repeat_size: n repetitions of what takes s; repeating nothing takes nothing.
repeat_size :: proc(k: ^Kernel, n, s: Type) -> Type {
	if takes_nothing(s) do return Int(0)
	return operation_law(k, .Mul, {n, s}, {})
}

// takes_nothing: the size s is 0.
takes_nothing :: proc(s: Type) -> bool {
	n, is_int := s.(Int)
	return is_int && n == 0
}

// repeats: t, on the left of a *, is what a run repeats — strings or scopes —, not
// an integer multiplied.
repeats :: proc(t: Type) -> bool {
	if is_text(t) do return true
	one: [1]Type
	cells, _ := cells_in(t, &one)
	for c in cells do if cell_family(c) != .Value do return false
	return len(cells) > 0
}

// is_emission: t, as written, is an emission (§4.9).
is_emission :: proc(t: Type) -> bool {
	e, is_effect := t.(^Effect)
	return is_effect && e.emission != nil
}

// unbounded_size: the size of a set with no greatest element: at least one bit, and
// no bound above.
unbounded_size :: proc() -> Type {
	return POSITIVE
}

// count_between: the count of the integers from lo to hi, lo <= hi.
count_between :: proc(lo, hi: i128) -> u128 {
	return u128(hi) - u128(lo) + 1
}

// bits_for: the least b with 2^b >= n, n >= 1: what holds one of n values.
bits_for :: proc(n: u128) -> i128 {
	b: i128 = 0
	for b < 128 && u128(1) << uint(b) < n do b += 1
	return b
}
