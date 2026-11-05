package kernel

import syn "../syntax"
import "core:fmt"
import "core:strings"

// SIZES (specs/types.md §4.11)
//
// A type carries its size: the least number of bits that tells its values apart,
// ⌈log₂ |T|⌉, |T| the count of the values it may take where it is. What is known
// takes 0 bits: only unknowns, and what depends on them, take bits.
//
// The algebra gives the set of the values a term may take — an unknown, its layout;
// a term over unknowns, its layout image; a pattern, the | of what its branches
// give —, and the size is read on that set: its count is an integer term, exact,
// over the unknowns the set depends on (`'a'..'z' * n` counts 26 ** n), computed by
// the laws of the integers:
//
//   |none| = 0      |p| = 1, p one value      |lo..hi| = hi - lo + 1
//   |a | b| = |a| + |b|, the cells of a normal form being apart
//   |A + B| = |A| · |B|      |A * n| = Σ |A| ** k over the counts k of n
//   |{C₁: … Cₙ:}| = Π |Cᵢ|   a shape: what it admits
//   |f16 & lo..hi| = the values of the format between lo and hi
//
// A set of strings is counted on the system of its quotients, exactly. A set the
// laws leave as an operation on integers — `u8 * u8` — is counted by computing its
// results, up to ENUMERATED of them; beyond, it counts at most the values between
// its least and greatest elements, and at most the product of the counts of its
// operands. An infinite set has no finite size.
//
// A scope as a value takes what its bindings take, summed: a hole takes 0, filled
// when the program is typed and erased; a production 0, devirtualized; a handler
// what it gives back.

// Size: ⌈log₂⌉ of each count, summed: the bits of the counts the laws computed, and
// the counts that stay terms over the unknowns.
Size :: struct {
	bits:      i128, // the bits of the counts known
	logs:      [dynamic]Type, // counts over unknowns: each takes ⌈log₂ c⌉ bits
	unbounded: bool, // a set with infinitely many values: no finite size
	problem:   Type, // Invalid: a term whose size is not computed
}

// size: the bits the value t takes, t in normal form.
size :: proc(k: ^Kernel, t: Type) -> (s: Size) {
	#partial switch v in t {
	case Invalid:
		s.problem = t
		return
	case ^Effect:
		return size(k, given(k, t))
	case ^Scope:
		return fields_size(k, v)
	}
	if is_constant(t) do return // known: one value
	set, ok := values(k, t)
	if !ok {
		s.problem = problem(.Unsupported, {}, fmt.tprintf("the values of %s are not read by this kernel yet", print_type(t)))
		return
	}
	add_count(&s, least_count(count(k, set), unknowns_count(k, t)))
	return
}

// unknowns_count: a term takes at most one value for each values of the unknowns
// it reads: the product of the counts of their layouts. ?₁ * ?₁ takes no more
// values than ?₁.
unknowns_count :: proc(k: ^Kernel, t: Type) -> Count {
	seen := make([dynamic]^Unknown)
	read_unknowns(t, &seen)
	total := Count(Type(Int(1)))
	for u in seen do total = count_mul(k, total, count(k, layout_of(k, u)))
	return total
}

// read_unknowns: the unknowns t reads, each once, by its index: the first met, the
// target of a pattern before the branches that narrow it. What a fold, a series or
// μ binds is not read.
read_unknowns :: proc(t: Type, out: ^[dynamic]^Unknown) {
	bound :: proc(t: Type, binds: []^Unknown, out: ^[dynamic]^Unknown) {
		inner := make([dynamic]^Unknown)
		read_unknowns(t, &inner)
		next: for u in inner {
			for b in binds do if b.id == u.id do continue next
			for x in out do if x.id == u.id do continue next
			append(out, u)
		}
	}
	#partial switch v in t {
	case ^Unknown:
		for u in out do if u.id == v.id do return
		append(out, v)
		return
	case ^Fold:
		binds := make([dynamic]^Unknown)
		append(&binds, v.index)
		append(&binds, ..v.states)
		for p in fold_parts(v) do if p != nil do bound(p, binds[:], out)
		return
	case ^Series:
		for p in ([]Type{v.lo, v.hi, v.term}) do bound(p, {v.index}, out)
		return
	case ^Least:
		bound(v.holds, {v.index}, out)
		return
	case ^Recurrent:
		for p in v.initial do read_unknowns(p, out)
		read_unknowns(v.at, out)
		return
	case ^Pattern:
		read_unknowns(v.target, out)
		for b in v.branches do read_unknowns(b.product, out)
		return
	case ^Effect:
		read_unknowns(v.then, out)
		return
	}
	for p in parts(t) do if p != nil do read_unknowns(p, out)
}

// least_count: the lesser of two counts of the same set, each at least its count.
least_count :: proc(a, b: Count) -> Count {
	x, a_finite := a.(Type)
	y, b_finite := b.(Type)
	if !a_finite do return b
	if !b_finite do return a
	m, m_known := x.(Int)
	n, n_known := y.(Int)
	if m_known && n_known do return Type(Int(min(m, n)))
	if m_known do return a
	return b
}

// fields_size: what the bindings of the scope s take, summed.
fields_size :: proc(k: ^Kernel, s: ^Scope) -> (total: Size) {
	for b in placed(k, s, .Value) {
		part: Size
		#partial switch b.kind {
		case .Push:
			// an emission no name holds gives nothing back to hold
			if b.name == "" && is_emission(b.value) do continue
			part = size(k, binding_type(k, b))
		case .Handler:
			part = handler_size(k, b)
		case:
			continue // a hole: erased; a production: devirtualized
		}
		add_size(&total, part)
		if total.problem != nil do return
	}
	return
}

// handler_size: what the handler h gives back, for what may be sent: its scope run
// with what is sent the event, each of its fields an unknown of its color.
handler_size :: proc(k: ^Kernel, h: ^Binding) -> Size {
	scope, is_scope := binding_type(k, h).(^Scope)
	if !is_scope || len(scope.bindings) == 0 do return {}
	sent := scope.bindings[0] // what is sent (build_handler)
	if sent.color == nil do return {}
	args := []Carve_Arg{Carve_Arg{ordinal = -1, value = unknown_value(k, binding_color(k, sent), h.span), span = h.span}}
	carved, ok := carve(k, scope, args, h.span).(^Scope)
	if !ok do return {}
	c := new(Collapse)
	c.target, c.span = carved, h.span
	return size(k, collapsed(k, carved, c))
}

// unknown_value: a value of the color c, no matter which: a shape, each of its
// fields an unknown of its color; another color, an unknown of it.
unknown_value :: proc(k: ^Kernel, c: Type, span: syn.Span) -> Type {
	shape, is_scope := c.(^Scope)
	if !is_scope || !is_shape(k, shape) do return new_unknown(k, c)
	args := make([dynamic]Carve_Arg)
	for b in placed(k, shape, .Value) {
		if b.kind != .Push || b.name == "" || b.color == nil do continue
		append(&args, Carve_Arg{name = b.name, ordinal = -1, value = unknown_value(k, binding_color(k, b), span), span = span})
	}
	return carve(k, shape, args[:], span)
}

// values: the set of the values the term t may take: an unknown, its layout; a
// pattern, what its branches give; a rounding, values of its format; another term
// over unknowns, its layout image.
values :: proc(k: ^Kernel, t: Type) -> (set: Type, ok: bool) {
	#partial switch v in t {
	case ^Unknown:
		return layout_of(k, v), true
	case ^Scope:
		return v, true // a scope is one value
	case ^Pattern:
		products := make([]Type, len(v.branches))
		for b, i in v.branches do products[i] = values(k, given(k, b.product)) or_return
		return or_law(k, products), true
	case ^Operation:
		if v.op == .Round {
			// a value of its format, between its rounded bounds when they are read
			f := rounded_format(v)
			if image, ok := layout_image(k, v); ok {
				if _, finite := count(k, image).(Type); finite do return image, true
			}
			return real_cell({format = f}), true
		}
	}
	if is_constant(t) do return t, true
	return layout_image(k, t)
}

// Count: the count of the values of a set, an integer term; Infinite when it has
// infinitely many.
Count :: union {
	Type,
	Infinite,
}

Infinite :: struct {}

// count: |s|, s a constant set in normal form, or one whose bounds are terms over
// unknowns.
count :: proc(k: ^Kernel, s: Type) -> Count {
	if is_text(s) && is_constant(s) do return text_count(k, s)
	one: [1]Type
	cells, negated := cells_in(s, &one)
	if negated do return Infinite{}
	total := Count(Type(Int(0)))
	for c in cells do total = count_add(k, total, cell_count(k, c))
	return total
}

// cell_count: the count of one cell of a normal form.
cell_count :: proc(k: ^Kernel, c: Type) -> Count {
	#partial switch v in c {
	case None:
		return Type(Int(0))
	case Char, Int, Real, Bool, ^Is:
		return Type(Int(1))
	case ^Range:
		return range_count(k, v)
	case ^And:
		#partial switch cell_family(c) {
		case .Real:
			return real_count(real_bounds(c))
		case .Int, .Char:
			lo, hi := discrete_bounds(c)
			return discrete_count(lo, hi)
		}
		// a set of strings carved by & ~: at most what its first term holds
		return count(k, v.terms[0])
	case ^Scope:
		return scope_count(k, v)
	case ^Operation:
		return operation_count(k, v)
	}
	if is_string_value(c) do return Type(Int(1))
	return Infinite{}
}

range_count :: proc(k: ^Kernel, r: ^Range) -> Count {
	#partial switch r.family {
	case .Real, .F16, .F32, .F64:
		return real_count(real_bounds(r))
	case .Any:
		if _, is_char := r.lo.(Char); !is_char do return Infinite{} // `..`: every primitive
	}
	lo, hi := discrete_bounds(r)
	if lo != nil && hi != nil do return discrete_count(lo, hi)
	if r.lo == nil || r.hi == nil do return Infinite{}
	// bounds over unknowns: hi - lo + 1, as written
	return operation_law(k, .Add, {operation_law(k, .Sub, {r.hi, r.lo}, {}), Int(1)}, {})
}

discrete_count :: proc(lo, hi: Maybe(i128)) -> Count {
	l, has_lo := lo.?
	h, has_hi := hi.?
	if !has_lo || !has_hi do return Infinite{}
	if l > h do return Type(Int(0))
	if span, fits := add_checked(h, -l); fits && l != min(i128) {
		if n, ok := add_checked(span, 1); ok do return Type(Int(n))
	}
	// beyond the integers written here: the term stays
	return Type(new_operation(.Add, new_operation(.Sub, Int(h), Int(l)), Int(1)))
}

// real_count: the reals of b: one when b is a point; the values of its format
// between its bounds; infinitely many in an interval of the exact reals.
real_count :: proc(b: Real_Bounds) -> Count {
	if is_point(b) do return Type(Int(1))
	if real_empty(b) do return Type(Int(0))
	if b.format == .Exact do return Infinite{}
	greatest := greatest_ordinal(b.format)
	lo, hi := -greatest, greatest
	if x, has := b.lo.?; has {
		up, ok := round_real(x, b.format, .Up)
		if !ok do return Type(Int(0)) // above the greatest value
		lo = max(lo, format_ordinal(up, b.format) + (b.lo_open && up == x ? 1 : 0))
	}
	if x, has := b.hi.?; has {
		down, ok := round_real(x, b.format, .Down)
		if ok do hi = min(hi, format_ordinal(down, b.format) - (b.hi_open && down == x ? 1 : 0))
		else if real_less(x, Real{0, 1}) do return Type(Int(0)) // below the least value
	}
	if hi < lo do return Type(Int(0))
	return Type(Int(hi - lo + 1))
}

// greatest_ordinal: the place of the greatest finite value of the format f,
// (2^p - 1) · 2^(emax - p + 1).
greatest_ordinal :: proc(f: Real_Format) -> i128 {
	format := FORMATS[f]
	p, q := format.precision, format.min_exponent
	t := format.max_exponent - p + 1
	return i128(t - q) << uint(p - 1) + (i128(1) << uint(p) - 1)
}

// format_ordinal: the place of r, a value of the format f, among its values in
// order, 0 at 0: consecutive values have consecutive places, as their encodings do.
format_ordinal :: proc(r: Real, f: Real_Format) -> i128 {
	if r.num < 0 do return -format_ordinal(Real{-r.num, r.den}, f)
	m, e, _ := dyadic(r)
	if m == 0 do return 0
	format := FORMATS[f]
	p, q := format.precision, format.min_exponent
	top := e + bit_length(u128(m)) - 1 // 2^top <= r < 2^(top + 1)
	if top < q + p - 1 do return m << uint(e - q) // a subnormal: r / 2^q
	t := top - p + 1 // r / 2^t holds p bits, the first one set
	return i128(t - q) << uint(p - 1) + m << uint(e - t)
}

// scope_count: a shape admits the scopes of its structure, each binding admitted
// by its color: the product of their counts; a scope with productions, the shape
// Arden solves it to, or what its productions give.
scope_count :: proc(k: ^Kernel, s: ^Scope) -> Count {
	if !is_shape(k, s) {
		if solution, solved := arden(k, s); solved && solution != s do return scope_count(k, solution)
		// an equation that holds itself unsolved, as a tree: no bound on its values
		if recursive(s) do return Infinite{}
		total := Count(Type(Int(0)))
		for b in placed(k, s, .Value) {
			if b.kind != .Product do continue
			set, ok := values(k, binding_type(k, b))
			if !ok do return Infinite{}
			total = count_add(k, total, count(k, set))
		}
		return total
	}
	total := Count(Type(Int(1)))
	for b in placed(k, s, .Shape) {
		if b.kind == .Pull || b.kind == .Handler do continue
		set: Type
		if b.value != nil {
			v, ok := values(k, binding_type(k, b))
			if !ok do return Infinite{}
			set = v
		} else {
			set = binding_color(k, b)
			if set == nil do return Infinite{}
		}
		total = count_mul(k, total, count(k, set))
	}
	return total
}

// operation_count: a set the laws leave as an operation.
operation_count :: proc(k: ^Kernel, o: ^Operation) -> Count {
	if o.op == .Mul && repeats(o.args[0]) do return repeat_count(k, count(k, o.args[0]), o.args[1])
	if o.op == .Add && is_text(o) {
		total := Count(Type(Int(1)))
		for a in o.args do total = count_mul(k, total, count(k, a))
		return total
	}
	if n, enumerated := enumerated_count(k, o); enumerated do return Type(Int(n))
	// beyond what is enumerated: at most the values between its least and greatest,
	// and at most the product of the counts of its operands
	product := Count(Type(Int(1)))
	for a in o.args do product = count_mul(k, product, count(k, a))
	if lo, hi, ok := int_bounds(k, o); ok {
		return least_count(product, discrete_count(lo, hi))
	}
	return product
}

// ENUMERATED: the most results an operation on sets of integers is computed on, to
// count those that differ.
ENUMERATED :: 1 << 20

// enumerated_count: the count of the distinct results of an operation on sets of
// integers, each computed: false when its operands are not cells of integers, or
// give more than ENUMERATED results.
enumerated_count :: proc(k: ^Kernel, o: ^Operation) -> (n: i128, ok: bool) {
	if len(o.args) == 0 || len(o.args) > 2 do return
	operands := make([][]i128, len(o.args))
	results := 1
	for a, i in o.args {
		one: [1]Type
		cells, negated := cells_in(a, &one)
		if negated do return
		xs := make([dynamic]i128)
		for c in cells {
			if cell_family(c) != .Int do return
			lo, hi := discrete_bounds(c)
			l := lo.? or_return
			h := hi.? or_return
			if h - l >= ENUMERATED do return
			for x := l; x <= h; x += 1 do append(&xs, x)
		}
		operands[i] = xs[:]
		results *= max(len(xs), 1)
		if results > ENUMERATED do return
	}
	seen := make(map[i128]bool)
	if len(operands) == 1 {
		// -x and [~]x = -x - 1 give as many values as x
		if o.op != .Neg && o.op != .Bit_Not do return
		return i128(len(operands[0])), true
	}
	for x in operands[0] {
		for y in operands[1] {
			r := int_operation(o.op, x, y) or_return
			seen[r] = true
		}
	}
	return i128(len(seen)), true
}

// text_count: the count of the strings of t, a constant set of strings, on the
// system of its quotients (strings.odin): the strings of a quotient are "" when it
// holds it, and, for each class of characters, each character of the class before
// each string of the quotient it leads to. A quotient on a cycle that leads to a
// string has infinitely many.
text_count :: proc(k: ^Kernel, t: Type) -> Count {
	system := equations(t)
	n := len(system)
	// the quotients that hold a string: "" in one, or a term leading to one
	live := make([]bool, n)
	for changed := true; changed; {
		changed = false
		for e, i in system {
			if live[i] do continue
			holds := !is_none(e.empty)
			for x in e.terms do holds ||= live[x.target]
			if holds {
				live[i] = true
				changed = true
			}
		}
	}
	counts := make([]Count, n)
	state := make([]u8, n) // 0: not counted, 1: being counted, 2: counted
	count_of :: proc(k: ^Kernel, system: [dynamic]Equation, live: []bool, counts: []Count, state: []u8, i: int) -> Count {
		if state[i] == 2 do return counts[i]
		if state[i] == 1 do return Infinite{} // a cycle: reached again while counted
		state[i] = 1
		total := Count(Type(Int(is_none(system[i].empty) ? 0 : 1)))
		for x in system[i].terms {
			if !live[x.target] do continue
			total = count_add(k, total, count_mul(k, chars_count(x.coefficient), count_of(k, system, live, counts, state, x.target)))
		}
		state[i] = 2
		counts[i] = total
		return total
	}
	return live[0] ? count_of(k, system, live, counts, state, 0) : Count(Type(Int(0)))
}

// chars_count: the count of a set of characters, a class of the system of quotients.
chars_count :: proc(c: Type) -> Count {
	one: [1]Type
	cells, _ := cells_in(c, &one)
	total: i128 = 0
	for cell in cells {
		lo, hi := discrete_bounds(cell)
		total += hi.? - lo.? + 1
	}
	return Type(Int(total))
}

// repeat_count: |A * n| = Σ |A| ** k over the counts k of n.
repeat_count :: proc(k: ^Kernel, c: Count, n: Type) -> Count {
	base, finite := c.(Type)
	if !finite do return Infinite{}
	if is_value(k, n) && !is_constant(n) do return operation_law(k, .Pow, {base, n}, {}) // a count over unknowns
	one: [1]Type
	cells, negated := cells_in(n, &one)
	if negated do return Infinite{}
	total := Count(Type(Int(0)))
	for cell in cells {
		lo, hi := discrete_bounds(cell)
		l, has_lo := lo.?
		h, has_hi := hi.?
		if !has_lo do return Infinite{}
		if !has_hi {
			// infinitely many lengths: infinitely many strings, unless there is at most one
			if b, known := base.(Int); known && b <= 1 {
				total = count_add(k, total, Type(Int(b == 1 ? 1 : (l == 0 ? 1 : 0))))
				continue
			}
			return Infinite{}
		}
		// Σ base ** j, j from l to h: (base ** (h + 1) - base ** l) / (base - 1)
		if b, known := base.(Int); known && b <= 1 {
			total = count_add(k, total, b == 1 ? Type(Int(h - l + 1)) : Type(Int(l == 0 ? 1 : 0)))
			continue
		}
		upper := operation_law(k, .Pow, {base, Int(h + 1)}, {})
		lower := operation_law(k, .Pow, {base, Int(l)}, {})
		sum := operation_law(k, .Div, {operation_law(k, .Sub, {upper, lower}, {}), operation_law(k, .Sub, {base, Int(1)}, {})}, {})
		total = count_add(k, total, sum)
	}
	return total
}

count_add :: proc(k: ^Kernel, a, b: Count) -> Count {
	x, a_finite := a.(Type)
	y, b_finite := b.(Type)
	if !a_finite || !b_finite do return Infinite{}
	return operation_law(k, .Add, {x, y}, {})
}

count_mul :: proc(k: ^Kernel, a, b: Count) -> Count {
	x, a_finite := a.(Type)
	y, b_finite := b.(Type)
	if a_finite && is_zero_count(x) || b_finite && is_zero_count(y) do return Type(Int(0))
	if !a_finite || !b_finite do return Infinite{}
	return operation_law(k, .Mul, {x, y}, {})
}

is_zero_count :: proc(c: Type) -> bool {
	n, known := c.(Int)
	return known && n == 0
}

// add_count: ⌈log₂ c⌉ bits more.
add_count :: proc(s: ^Size, c: Count) {
	n, finite := c.(Type)
	if !finite {
		s.unbounded = true
		return
	}
	if is_invalid(n) {
		s.problem = n
		return
	}
	if known, is_int := n.(Int); is_int {
		if known > 1 do s.bits += bits_for(u128(known))
		return
	}
	append(&s.logs, n)
}

add_size :: proc(total: ^Size, part: Size) {
	if part.problem != nil do total.problem = part.problem
	total.bits += part.bits
	append(&total.logs, ..part.logs[:])
	total.unbounded ||= part.unbounded
}

print_size :: proc(s: Size) -> string {
	if s.problem != nil do return print_type(s.problem)
	if s.unbounded do return "unbounded"
	parts := make([dynamic]string)
	if s.bits != 0 || len(s.logs) == 0 do append(&parts, fmt.tprintf("%d", s.bits))
	for c in s.logs do append(&parts, fmt.tprintf("⌈log₂ (%s)⌉", print_type(c)))
	return strings.join(parts[:], " + ")
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

// bits_for: the least b with 2^b >= n, n >= 1: what tells n values apart.
bits_for :: proc(n: u128) -> i128 {
	b: i128 = 0
	for b < 128 && u128(1) << uint(b) < n do b += 1
	return b
}

// MEMORY (specs/types.md §4.13)
//
// What a value keeps in memory: the places it still reads or writes — a resonant
// binding whose reads the laws did not all replace by what was written, or that
// what it gives holds —, each taking the size of its color. A place the laws
// simplified away takes nothing: a binding written and read with nothing unknown
// between is its value.

// Memory: the places a value keeps, and the bits they take.
Memory :: struct {
	places: [dynamic]^Unknown,
	size:   Size,
}

memory :: proc(k: ^Kernel, t: Type) -> (m: Memory) {
	kept_places(t, &m.places)
	for p in m.places do add_size(&m.size, size(k, p))
	return
}

// kept_places: the places t reads or writes, each once, the scopes it gives
// included.
kept_places :: proc(t: Type, out: ^[dynamic]^Unknown) {
	keep :: proc(u: ^Unknown, out: ^[dynamic]^Unknown) {
		if u == nil || u.place == nil || u.before do return
		for p in out do if same_unknown(p, u) do return
		append(out, u)
	}
	if t == nil do return
	#partial switch v in t {
	case ^Unknown:
		keep(v, out)
	case ^Effect:
		if v.write != nil {
			keep(v.write.place, out)
			kept_places(v.write.value, out)
		}
		if v.emission != nil do kept_places(v.emission.sent, out)
		if v.choice != nil do kept_places(v.choice, out)
		kept_places(v.then, out)
	case ^Pattern:
		kept_places(v.target, out)
		for b in v.branches do kept_places(b.product, out)
	case ^Scope:
		for _, x in v.changes do kept_places(x, out)
	case:
		for p in parts(t) do kept_places(p, out)
	}
}
