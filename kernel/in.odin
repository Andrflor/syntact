package kernel

import "core:slice"

// `in` (specs/types.md §4.7)
//
// `x in c` is true when x is an element of c. It takes both arguments whole. Its
// laws, which put it in normal form:
//
//   x in (a | b)  = (x in a) [|] (x in b)          x ≠ none
//   x in (a & b)  = (x in a) [&] (x in b)          x ≠ none
//   x in ~a       = [~](x in a)                    x ≠ none
//   x in =t       = true when x and t are the same; false when both are known
//                   and differ, or their layouts have nothing in common
//   x in l..u     = l <= x [&] x <= u              x one value
//   x in p        = x in =p                        p one value
//   b in true     = b,  b in false = [~]b          b a boolean
//   none in t     = t is none
//   (t::L) in L   = true: an unknown, or a term over unknowns, is in what holds
//                   its layout, and in nothing disjoint from it
//   (a * u + b) in S = u in {v | a * v + b in S}   the preimage
//   x in (t ? {c -> p …}) = t ? {c -> x in p …}    a pattern gives one product
//   x in S        S a scope: what its productions give, or its shape (§5.4)
//
// On a constant type without scope, the laws of | & ~ are computed whole, by its
// reading (lattice.odin). What no law reduces stays `x in c`: the check proves it
// (prove.odin).

in_law :: proc(k: ^Kernel, x, c: Type) -> Type {
	if is_invalid(x) do return x
	if is_invalid(c) do return c
	if is_value(k, x) && same(k, x, c) do return Bool(true) // x in x = x in =x, x one value
	if p, ok := x.(^Pattern); ok do return enter_branches(k, p, proc(product, other: Type) -> Type {return new_operation(.In, product, other)}, c)
	if p, ok := c.(^Pattern); ok do return enter_branches(k, p, proc(product, other: Type) -> Type {return new_operation(.In, other, product)}, x)
	if u, ok := x.(^Unknown); ok && same(k, layout_of(k, u), c) do return Bool(true) // (t::L) in L
	// (t::L) in C when L ⊆ C (§4.1), t any term whose values are read — a binding of a
	// run in the layout of its items
	if _, read := x.(^Operation); read && !is_constant(x) {
		if set, known := values(k, x); known && included(k, set, c) do return Bool(true)
	}
	// x of degree 1 in an unknown: in S when that unknown is in the preimage of S (§4.7)
	// — the form of an atom whose unknowns are related, by S or by a layout over the
	// others; over unknowns nothing relates, the atom is already in normal form
	if _, is_op := x.(^Operation); is_op && !is_constant(x) && relates(k, x, c) {
		if u, set, read := term_preimage(k, x, c); read do return in_law(k, u, set)
	}
	// an unknown in a set over unknowns: in it when its layout is, out of it when its
	// layout is apart from it (§7)
	if u, is_unknown := x.(^Unknown); is_unknown && !is_constant(c) {
		layout := layout_of(k, u)
		if included(k, layout, c) do return Bool(true)
		if apart(k, layout, c) do return Bool(false)
	}
	// a term the ring does not read, in a set over unknowns: in it when its type, by
	// the law of its operator, is (§7, term_type)
	if !is_constant(c) {
		if type, typed := term_type(k, x); typed {
			if included(k, type, c) do return Bool(true)
			if apart(k, type, c) do return Bool(false)
		}
	}
	// a recursive call, by induction on its equation: in c, or in ~c — then not in c (§4.1)
	if call, ok := x.(^Collapse); ok && call.recursive {
		if call_in(k, call, c) do return Bool(true)
		if call_in(k, call, not_law(k, c)) do return Bool(false)
	}
	// what a call with effects gives back: in c by the same induction (§5.6, §4.8)
	if u, ok := x.(^Unknown); ok && u.call != nil && u.call.recursive && call_in(k, u.call, c) do return Bool(true)
	// a field, a binding, of what a call gives: in c by induction on it (call_in)
	if call, read := call_read(x); read && call_in(k, call, c, read_of(x)) do return Bool(true)
	if f, ok := x.(^Fold); ok && fold_induction(k, f, c) do return Bool(true)
	// t & A, t one value: t where it is in A (§4.2), in c when t is in ~A | c, out of
	// c when t is in ~A | ~c
	if meet, ok := x.(^And); ok {
		if t, sets, one := value_in_meet(k, meet); one {
			if is_bool(in_law(k, t, or_law(k, {not_law(k, sets), c})), true) do return Bool(true)
			if is_bool(in_law(k, t, or_law(k, {not_law(k, sets), not_law(k, c)})), true) do return Bool(false)
		}
	}
	// an operation on values is in the family its signature gives (§4.5)
	if _, ok := x.(^Operation); ok && is_value(k, x) {
		if f, known := family_of(k, x); known && same(k, c, family_term(f)) do return Bool(true)
	}
	// (t::L) in a | of shapes: L a scope whose productions are each one of them
	if any, either := c.(^Or); either && !is_constant(x) {
		if image, known := values(k, x); known do if s, is_scope := image.(^Scope); is_scope && !is_shape(k, s) && produced_within(k, s, any) do return Bool(true)
	}
	if s, ok := c.(^Scope); ok {
		// (t::L) in S: true when S holds L, false when they are apart
		if !is_constant(x) {
			if image, known := values(k, x); known {
				if included(k, image, s) || shape_in(k, image, s) do return Bool(true)
				if apart(k, image, s) do return Bool(false)
			}
		}
		if verdict, read := built_in(k, x, s); read do return verdict
		if runs_in(k, x, s) do return Bool(true)
		return admits(k, x, s)
	}
	if o, ok := c.(^Operation); ok && o.op == .Mul && of_values(o.args[0]) do return repeated_in(k, x, o.args[0], o.args[1])
	if i, ok := c.(^Is); ok do return equal_law(k, x, i.term)
	if is_none(x) {
		if is_none(c) do return Bool(true)
		if inhabited(k, c) do return Bool(false)
		return new_operation(.In, x, c)
	}
	if is_constant(c) {
		one: [1]Type
		cells, negated := cells_in(c, &one)
		if negated do return bool_not(k, in_law(k, x, cells_term(k, cells))) // x in ~a = [~](x in a)
		values := false
		for cell in cells do values ||= cell_family(cell) == .Value
		if !values do return in_cells(k, x, c, cells)
	} else if is_value(k, c) {
		return equal_law(k, x, c) // x in p = x in =p
	}
	#partial switch v in c {
	case ^Range:
		// one value from l to u: l <= x [&] x <= u (§4.3) — an unknown in a range over
		// unknowns is already the form the preimage gives: it stays
		if _, is_unknown := x.(^Unknown); is_value(k, x) && !(is_unknown && !is_constant(c)) {
			out: Type = Bool(true)
			if v.lo != nil do out = bool_and(k, out, operation_law(k, .Greater_Eq, {x, v.lo}, v.span))
			if v.hi != nil do out = bool_and(k, out, operation_law(k, .Less_Eq, {x, v.hi}, v.span))
			return out
		}
	case ^Or:
		out: Type = Bool(false)
		for term in v.terms do out = bool_or(k, out, in_law(k, x, term))
		return out
	case ^And:
		out: Type = Bool(true)
		for term in v.terms do out = bool_and(k, out, in_law(k, x, term))
		return out
	case ^Not:
		return bool_not(k, in_law(k, x, v.term))
	}
	return new_operation(.In, x, c)
}

// value_in_meet: t & A, t one value and A the sets beside it.
value_in_meet :: proc(k: ^Kernel, meet: ^And) -> (t: Type, sets: Type, ok: bool) {
	others := make([dynamic]Type)
	for term in meet.terms {
		if is_value(k, term) && !is_constant(term) {
			if t != nil do return
			t = term
		} else {
			append(&others, term)
		}
	}
	if t == nil || len(others) == 0 do return
	return t, and_law(k, others[:]), true
}

// of_values: a | of cells that are values — scopes, =t — and nothing else.
of_values :: proc(t: Type) -> bool {
	one: [1]Type
	cells, negated := cells_in(t, &one)
	if negated || len(cells) == 0 do return false
	for c in cells do if cell_family(c) != .Value do return false
	return true
}

// in_cells: x in a | of cells without a value (a scope, =t): its elements are
// primitives, and strings of them. A boolean b is in =true when it is true:
// b in true = b, b in false = [~]b.
in_cells :: proc(k: ^Kernel, x, c: Type, cells: []Type) -> Type {
	if is_primitive(x) {
		r := and_law(k, {x, c})
		if is_none(r) do return Bool(false)
		if same(k, r, x) do return Bool(true)
		return new_operation(.In, x, c)
	}
	if v, is_bool := c.(Bool); is_bool {
		if _, is_op := x.(^Operation); is_op {
			if f, known := family_of(k, x); known && f == .Bool do return bool(v) ? x : bool_not(k, x)
		}
	}
	if !is_value(k, x) do return Bool(false) // a set, taken as a value, is not a primitive
	#partial switch v in x {
	case ^Scope:
		return Bool(false)
	case ^Unknown:
		// its layout, or what that layout may hold when it reads other unknowns
		image, _ := layout_image(k, x)
		return layout_in(k, x, image, c)
	}
	// b << e and b ** e, b a constant: growing and one-to-one in e ≥ 0, its preimage a
	// set of e (§4.7)
	if e, set, exact := power_preimage(k, x, cells); exact do return in_law(k, e, set)
	if image, ok := layout_image(k, x); ok do return layout_in(k, x, image, c)
	return new_operation(.In, x, c)
}

// layout_in: x, one value of the layout L: x in c = true when L & ~c = none,
// false when L & c = none (§7).
layout_in :: proc(k: ^Kernel, x, layout, c: Type) -> Type {
	if included(k, layout, c) do return Bool(true)
	if apart(k, layout, c) do return Bool(false)
	return new_operation(.In, x, c)
}

// equal_law: x in =t.
equal_law :: proc(k: ^Kernel, x, t: Type) -> Type {
	if is_invalid(x) do return x
	if is_invalid(t) do return t
	if same(k, x, t) do return Bool(true)
	if is_constant(x) && is_constant(t) {
		if equal, known := values_equal(k, x, t); known do return Bool(equal)
	}
	if is_primitive(x) && is_value(k, t) do return in_law(k, t, x) // t in =x: a primitive is its own singleton
	// two values whose layouts have nothing in common are never equal
	if is_value(k, x) && is_value(k, t) {
		lx, known_x := layout_image(k, x)
		lt, known_t := layout_image(k, t)
		if known_x && known_t && apart(k, lx, lt) do return Bool(false)
	}
	return new_operation(.In, x, new_is(t))
}

// values_equal: two constant values are equal: two sets when a & ~b and b & ~a
// are none, and not when one shows an element; two scopes when their bindings
// are (§5.3). Not known otherwise.
values_equal :: proc(k: ^Kernel, a, b: Type) -> (equal: bool, known: bool) {
	x, a_scope := a.(^Scope)
	y, b_scope := b.(^Scope)
	if a_scope || b_scope do return a_scope && b_scope && (same(k, a, b) || same_bindings(k, x, y, false)), true
	l := and_law(k, {a, not_law(k, b)})
	r := and_law(k, {b, not_law(k, a)})
	if is_none(l) && is_none(r) do return true, true
	if inhabited(k, l) || inhabited(k, r) do return false, true
	return false, false
}

// is_value: t is one value for each value of its unknowns, not a set of them: an
// unknown, an operation on values, a pattern whose products are values.
is_value :: proc(k: ^Kernel, t: Type) -> bool {
	switch v in t {
	case Char, Int, Real, Bool, None, ^Unknown, ^Scope, ^Collapse, ^Fold, ^Least, ^Series, ^Recurrent, Invalid:
		return true
	case ^Operation:
		if v.op == .In do return true
		for a in v.args do if !is_value(k, a) do return false
		return true
	case ^Pattern:
		for b in v.branches do if !is_value(k, b.product) do return false
		return true
	case ^Access:
		return is_value(k, v.target) // a field of a value
	case ^And:
		// t & S, t one value: t where it is in S
		for a in v.terms do if is_value(k, a) do return true
		return false
	case ^Effect, ^Or, ^Not, ^Is, ^Range, ^Name, ^Carve, ^Default:
	}
	return false
}

// preimage: the integers v such that a * v + b is in the cells, a ≠ 0; false when a
// bound is beyond the integers written here, or when a cell is not of integers.
preimage :: proc(k: ^Kernel, cells: []Type, a, b: i128) -> (set: Type, ok: bool) {
	if b == min(i128) || a == min(i128) do return
	start := mark(k)
	defer release(k, start)
	for c in cells {
		if cell_family(c) != .Int do return
		lo, hi := discrete_bounds(c)
		lo = add_bound(lo, -b) or_return
		hi = add_bound(hi, -b) or_return
		if a < 0 {
			x := neg_bound(hi) or_return
			y := neg_bound(lo) or_return
			lo, hi = x, y
		}
		m := abs(a)
		from, to: Maybe(i128)
		if l, has := lo.?; has do from = ceil_div(l, m)
		if h, has := hi.?; has do to = floor_div(h, m)
		push(k, discrete_cell(.Int, from, to))
	}
	return cells_term(k, join_discrete(k, .Int, pushed(k, start))), true
}

floor_div :: proc(x, y: i128) -> i128 {
	q := x / y
	if x % y != 0 && (x < 0) != (y < 0) do q -= 1
	return q
}

ceil_div :: proc(x, y: i128) -> i128 {
	return -floor_div(-x, y)
}

// Read: what of a recursive call an induction is about: what it gives; a field of the
// scope it gives, x.a; or its bindings, x.#k.
Read :: struct {
	fields: bool,
	name:   string, // the field read; "" for every binding
}

// read_of: what the term t reads of a call.
read_of :: proc(t: Type) -> Read {
	#partial switch v in t {
	case ^Access:
		return {true, v.name}
	case ^Operation:
		if v.op == .Item do return {true, ""}
	}
	return {}
}

// call_in: a recursive call is in c (§5.6) — with a read, what it reads of the scope it
// gives is: by induction on the equation it reads; when that equation cannot be read
// where what the call carves is unknown (a hole the carve fills), the call is its
// production at the values its carve gives (§5.3), its calls the hypothesis meanwhile.
call_in :: proc(k: ^Kernel, call: ^Collapse, c: Type, fields := Read{}) -> bool {
	s := call.target.(^Scope) or_return
	key, through := call_key(s), through_of(k, s)
	eq, found := equation_found(k, origin(s), key, through)
	if !found do eq = equation_of(k, origin(s), key, through) or_return
	if eq.term == nil {
		// no equation where what the call carves is unknown (a hole the carve fills):
		// the call is its production at the values its carve gives (§5.3), its calls
		// the hypothesis meanwhile
		p := first_production(k, s) or_return
		if p.state == .In_Progress do return false
		eq.reading = true
		defer eq.reading = false
		return holds_in(k, binding_type(k, p), c, fields, eq.root)
	}
	for x in k.induced do if x.equation == eq.generic && x.fields == fields && same(k, x.set, c) do return x.proven
	at := len(k.induced)
	append(&k.induced, Induced{eq.generic, c, fields, false})
	// the proof reads the equation: meanwhile its calls are the hypothesis
	eq.reading = true
	proven := induced(k, eq, c, fields)
	eq.reading = false
	k.induced[at].proven = proven
	return proven
}

// Induced: an induction once proven, or not, for an equation, a set and a read.
Induced :: struct {
	equation: ^Scope,
	set:      Type,
	fields:   Read,
	proven:   bool,
}

induced :: proc(k: ^Kernel, eq: ^Recursion, c: Type, fields: Read) -> bool {
	root, e := eq.root, eq.term
	assumed: Rewrite
	taken :: proc(k: ^Kernel, c: Type) -> Type {
		u := new_unknown(k, nil)
		u.layout = c
		return u
	}
	// the hypothesis: a call of this equation, at values of its fields; a call of
	// another — root at a value not of its fields — by its own induction
	holds :: proc(k: ^Kernel, eq: ^Recursion, call: ^Collapse, c: Type, fields: Read) -> bool {
		if _, _, instance := moves(k, eq, call); instance do return true
		return call_in(k, call, c, fields)
	}
	if fields.fields {
		// what is read of its calls: taken in c; the calls themselves stay, the
		// hypothesis
		for read in call_reads(k, e, root) {
			if fields.name != "" && read_of(read) != fields do continue
			call, _ := call_read(read)
			if holds(k, eq, call, c, read_of(read)) do assumed = append_read(assumed, read, taken(k, c))
		}
	} else {
		// each call, and each one a read of a field holds
		calls := make([dynamic]^Collapse)
		append(&calls, ..calls_in(k, e, root))
		for read in call_reads(k, e, root) do if call, _ := call_read(read); !slice.contains(calls[:], call) do append(&calls, call)
		for inner in calls do if holds(k, eq, inner, c, fields) do assumed = rewriting_call(assumed, inner, taken(k, c))
		// a call with effects: what it gives back, its answer, is taken in c likewise
		for x in call_answers(k, e, root) do assumed = rewriting(assumed, x, taken(k, c))
	}
	// an effect is not a value: the verdict is read on what the effects wrap (§7)
	return holds_in(k, given(k, rewrite(k, e, assumed)), c, fields, root)
}

// holds_in: v in c; with a read, v is a scope what it reads of which is in c — through
// its patterns, which give one of their products (§6); a product that is a call of
// root, the hypothesis, adds nothing: X = X | P.
holds_in :: proc(k: ^Kernel, v: Type, c: Type, fields: Read, root: ^Scope = nil) -> bool {
	if !fields.fields {
		verdict, _ := prove(k, in_law(k, given(k, v), c))
		return verdict == .Proven
	}
	leaves := make([dynamic]Product)
	products(k, given(k, v), &leaves)
	for leaf in leaves {
		if is_none(leaf.term) do continue
		// a call of root, also where a branch narrows it: t & S is t where it is in S
		if root != nil && is_call_of(leaf.term, root) do continue
		if meet, narrowed := leaf.term.(^And); narrowed && root != nil {
			if t, _, one := value_in_meet(k, meet); one && is_call_of(t, root) do continue
		}
		shape := leaf.term.(^Scope) or_return
		for b in placed(k, shape, .Value) {
			if b.kind != .Push && b.kind != .Expand do continue
			if fields.name != "" && b.name != fields.name do continue
			verdict, _ := prove(k, in_law(k, given(k, read_in(k, leaf, binding_value(k, b))), c))
			if verdict != .Proven do return false
		}
	}
	return true
}

// call_read: x reads a field, or a binding, of a recursive call: the call — also of
// t & S, the call t where it is in S (§4.2).
call_read :: proc(x: Type) -> (^Collapse, bool) {
	read :: proc(t: Type) -> (^Collapse, bool) {
		if meet, narrowed := t.(^And); narrowed {
			for term in meet.terms do if c, is_call := as_call(term); is_call do return c, true
			return nil, false
		}
		return as_call(t)
	}
	#partial switch v in x {
	case ^Access:
		return read(v.target)
	case ^Operation:
		if v.op == .Item do return read(v.args[0])
	}
	return nil, false
}

// call_reads: the reads of fields, or bindings, of the calls of root in t.
call_reads :: proc(k: ^Kernel, t: Type, root: ^Scope) -> []Type {
	out := make([dynamic]Type)
	visit :: proc(k: ^Kernel, t: Type, root: ^Scope, out: ^[dynamic]Type) {
		if c, read := call_read(t); read {
			if s, is_scope := c.target.(^Scope); is_scope && origin(s) == root do append(out, t)
			return
		}
		#partial switch v in t {
		case ^Effect:
			if v.choice != nil do visit(k, v.choice, root, out)
			visit(k, v.then, root, out)
		case ^Pattern:
			for b in v.branches do visit(k, b.product, root, out)
		case ^Scope:
			for b in placed(k, v, .Value) do if b.kind != .Product && b.kind != .Handler do visit(k, binding_type(k, b), root, out)
		}
		for p in parts(t) do visit(k, p, root, out)
	}
	visit(k, t, root, &out)
	return out[:]
}

// call_answers: what the effects calling root in t give back.
call_answers :: proc(k: ^Kernel, t: Type, root: ^Scope) -> []^Unknown {
	out := make([dynamic]^Unknown)
	visit :: proc(k: ^Kernel, t: Type, root: ^Scope, out: ^[dynamic]^Unknown) {
		#partial switch v in t {
		case ^Effect:
			if v.call != nil && v.answer != nil {
				if s, is_scope := v.call.target.(^Scope); is_scope && origin(s) == root do append(out, v.answer)
			}
			if v.choice != nil do visit(k, v.choice, root, out)
			visit(k, v.then, root, out)
		case ^Pattern:
			visit(k, v.target, root, out)
			for b in v.branches do visit(k, b.product, root, out)
		case ^Scope:
			// what the scope places, as calls_in reads it
			for b in placed(k, v, .Value) do if b.kind != .Product && b.kind != .Handler do visit(k, binding_type(k, b), root, out)
		case:
			for p in parts(t) do visit(k, p, root, out)
		}
	}
	visit(k, t, root, &out)
	return out[:]
}

// built_in: a run a fold builds, {e₀ … eₙ₋₁}, or what of it follows k, in a shape
// of places then runs of pieces: the law of `in` on a concatenation (match_shape),
// on its length and on the values its steps place — each in the color of every
// place it may take. Not read when those values are not shown in those colors.
built_in :: proc(k: ^Kernel, x: Type, s: ^Scope) -> (verdict: Type, read: bool) {
	f, is_fold := x.(^Fold)
	if o, is_from := x.(^Operation); is_from && o.op == .From do f, is_fold = o.args[0].(^Fold)
	if !is_fold do return
	fixed, colors, counts := run_form(k, s) or_return
	_, es, builds := built(k, f)
	if !builds do return
	// each binding a step places, in each color: what it may hold within the color;
	// a scope, by `in` on its fields
	for c in colors do for e in es {
		x := given(k, e)
		set := values(k, x) or_return
		if _, is_scope := set.(^Scope); !is_scope {
			if !included(k, set, c) do return
			continue
		}
		verdict, _ := prove(k, in_law(k, x, c))
		if verdict != .Proven do return
	}
	length := run_law(k, .Length, {x}, f.span)
	if counts == nil do return in_law(k, length, range_law(k, Int(i128(fixed)), nil, .Int, f.span)), true
	return in_law(k, op(k, .Sub, length, Int(i128(fixed))), counts), true
}

// run_form: a shape of unnamed places then runs of pieces, read as a run: how many
// places it has, the colors its bindings may take, and how many bindings its runs
// take, each a set or a term — nil when a run takes any number (§5.3).
run_form :: proc(k: ^Kernel, s: ^Scope) -> (fixed: int, colors: []Type, counts: Type, ok: bool) {
	shape := s
	if recursive(s) do shape = arden(k, s) or_return
	if !is_shape(k, shape) do return
	runs := false
	found := make([dynamic]Type)
	counts = Int(0)
	for p in placed(k, shape, .Shape) {
		if !is_run(p) {
			if runs || p.name != "" do return // the bindings of a run are unnamed
			fixed += 1
			// what the place admits: its color, or the value written there
			c := binding_color(k, p)
			if c == nil && p.value != nil do c = place_set(k, p) or_return
			if c != nil do append(&found, c)
			continue
		}
		if p.color == nil {
			runs = true
			counts = nil
			continue
		}
		color := binding_color(k, p)
		// a run of the empty shape places nothing
		if empty, is_scope := color.(^Scope); is_scope && is_shape(k, empty) && len(placed(k, empty, .Shape)) == 0 do continue
		// a repetition A * n places pieces of A; a scope, the pieces of its runs
		pieces, m: Type
		if o, repeats := color.(^Operation); repeats && o.op == .Mul do pieces, m = o.args[0], o.args[1]
		else do pieces, m = layout_pieces(k, color) or_return
		piece := pieces.(^Scope) or_return
		inner := placed(k, piece, .Shape)
		if len(inner) != 1 || is_run(inner[0]) do return
		runs = true
		if counts != nil do counts = exact_law(k, .Add, {counts, m}, p.span)
		if c := binding_color(k, inner[0]); c != nil do append(&found, c)
	}
	return fixed, found[:], counts, true
}

// runs_in: x, a run, in a shape of places then runs of pieces: true when each of
// its bindings is in the colors of the shape and its length is one the shape
// admits — read on what x may be (§5.3).
runs_in :: proc(k: ^Kernel, x: Type, s: ^Scope) -> bool {
	fixed, colors, counts := run_form(k, s) or_return
	set := values(k, x) or_return
	if _, same_scope := set.(^Scope); same_scope && set == Type(s) do return false
	items := item_image(k, set) or_return
	length := length_image(k, set) or_return
	for c in colors do if !included(k, items, c) do return false
	if counts == nil do return included(k, length, range_law(k, Int(i128(fixed)), nil, .Int, s.span))
	return included(k, exact_law(k, .Sub, {length, Int(i128(fixed))}, s.span), layout_image(k, counts) or_return)
}

// fold_induction: a fold is in c when the states its value reads start in c, stay
// in c at each step, and its value is in c, each of those states taken in c; the
// other states are what their layouts say.
fold_induction :: proc(k: ^Kernel, f: ^Fold, c: Type) -> bool {
	assumed: Rewrite
	taken := make([]bool, len(f.states))
	for z, i in f.states {
		if !reads(k, f.value, z) do continue
		u := new_unknown(k, nil)
		u.layout = c
		assumed = rewriting(assumed, z, u)
		taken[i] = true
	}
	holds :: proc(k: ^Kernel, t, c: Type) -> bool {
		verdict, _ := prove(k, in_law(k, t, c))
		return verdict == .Proven
	}
	for t, i in f.inits do if taken[i] && !holds(k, t, c) do return false
	for t, i in f.updates do if taken[i] && !holds(k, rewrite(k, t, assumed), c) do return false
	return holds(k, rewrite(k, f.value, assumed), c)
}

// shape_in: every scope the shape l admits is in s: shapes of one structure are
// products (§5.4), included place by place — in s itself, or in a production of s;
// a | of shapes, when each is.
shape_in :: proc(k: ^Kernel, l: Type, s: ^Scope) -> bool {
	// one of several shapes: each in s
	if any, either := l.(^Or); either {
		for t in any.terms do if !shape_in(k, t, s) do return false
		return true
	}
	shape, is_scope := l.(^Scope)
	if !is_scope || !is_shape(k, shape) do return false
	for p in placed(k, s, .Shape) {
		if p.kind != .Product || p.value == nil do continue
		if target, is_shape_value := binding_type(k, p).(^Scope); is_shape_value && shape_within(k, shape, target) do return true
	}
	return false
}

// shape_within: every scope the shape l admits, the shape s admits: the same
// structure, each color within the other's, place by place (§5.4).
shape_within :: proc(k: ^Kernel, l, s: ^Scope) -> bool {
	if !is_shape(k, s) do return false
	places, others := placed(k, l, .Shape), placed(k, s, .Shape)
	if len(others) != len(places) do return false
	for x, i in places {
		y := others[i]
		if x.name != y.name || x.kind != y.kind || is_run(x) || is_run(y) do return false
		cy := binding_color(k, y)
		if cy == nil do continue
		cx := binding_color(k, x)
		if cx == nil || !same(k, cx, cy) && !included(k, cx, cy) do return false
	}
	return true
}

// produced_within: every value the scope s admits — what its productions give, each a
// shape (§5.4) — one of the shapes of c admits.
produced_within :: proc(k: ^Kernel, s: ^Scope, c: ^Or) -> bool {
	found := false
	for p in placed(k, s, .Shape) {
		if p.kind != .Product do continue
		shape, is_scope := binding_type(k, p).(^Scope)
		if p.value == nil || !is_scope || !is_shape(k, shape) do return false
		within := false
		for t in c.terms do if target, is_shape_value := t.(^Scope); is_shape_value && shape_within(k, shape, target) {
			within = true
			break
		}
		if !within do return false
		found = true
	}
	return found
}

// maybe_int: an end of a range, nil for none.
maybe_int :: proc(x: Maybe(i128)) -> Type {
	if v, has := x.?; has do return Int(v)
	return nil
}

// THE PREIMAGE (§4.7)
//
// x in S, x = a·u + b of degree 1 in an unknown u, b not reading u, is u in the
// preimage of S: {v | a·v + b in S}. For a = ±1 it is a·(S - b), S moved by a
// translation — one-to-one on the integers, which moves the ends of each range and
// keeps | & ~. u is one that no layout of the others reads: its layout says all that
// relates it to them. Over constants, any a: preimage.

// term_preimage: x of degree 1 in such an unknown: the unknown, and the preimage of s.
term_preimage :: proc(k: ^Kernel, x, s: Type) -> (u: ^Unknown, set: Type, ok: bool) {
	for d in degree_one(k, x) {
		if c, constant := d.b.(Int); constant && is_constant(s) {
			one: [1]Type
			cells, negated := cells_in(s, &one)
			if !negated do if p, exact := preimage(k, cells, d.a, i128(c)); exact do return d.u, p, true
		}
		if d.a != 1 && d.a != -1 do continue
		return d.u, moved(k, s, d.a, d.b) or_continue, true
	}
	return
}

// Degree_One: x = a·u + b, b not reading u.
Degree_One :: struct {
	u: ^Unknown,
	a: i128,
	b: Type,
}

// degree_one: the unknowns x is of degree 1 in, each one no layout of the others
// reads and not inside an atom — its layout says all that relates it to them —,
// with its coefficient and what is left of x.
degree_one :: proc(k: ^Kernel, x: Type) -> []Degree_One {
	back: Rewrite
	ms, divisor, ring := monomials(atomized(k, x, &back))
	if !ring || divisor != 1 do return nil
	us := make([dynamic]^Unknown)
	read_unknowns(x, &us)
	inside := make([dynamic]^Unknown)
	for r in back do if r.unknown != nil do read_unknowns(r.term, &inside)
	out := make([dynamic]Degree_One)
	next: for v in us {
		// not while a layout of another reads it, nor inside an atom
		for w in us do if !same_unknown(w, v) && layout_reads(k, w, v) do continue next
		for w in inside do if same_unknown(w, v) || layout_reads(k, w, v) do continue next
		a: i128 = 0
		rest := make([dynamic]Type)
		for m in ms {
			fs := factors(m)
			with := false
			for f in fs do with ||= same_unknown(f, v)
			if !with {
				append(&rest, m)
				continue
			}
			if a != 0 || len(fs) != 1 do continue next
			a = coefficient(m)
		}
		if a == 0 do continue
		append(&out, Degree_One{v, a, unatomized(ring_term(rest[:], 1) or_continue, back)})
	}
	return out[:]
}

// relates: the unknowns of x in c are related — c reads unknowns, or a layout of one of
// them reads others.
relates :: proc(k: ^Kernel, x, c: Type) -> bool {
	if !is_constant(c) do return true
	us := make([dynamic]^Unknown)
	read_unknowns(x, &us)
	for u in us do if !is_constant(layout_of(k, u)) do return true
	return false
}

// moved: {v | a·v + b in S}, a = ±1: S - b, or b - S.
moved :: proc(k: ^Kernel, s: Type, a: i128, b: Type) -> (out: Type, ok: bool) {
	// an end e of S gives e - b, or b - e; the ends swap when a = -1
	ends :: proc(k: ^Kernel, lo, hi: Type, a: i128, b: Type) -> (from, to: Type) {
		end :: proc(k: ^Kernel, e: Type, a: i128, b: Type) -> Type {
			if e == nil do return nil
			return a == 1 ? op(k, .Sub, e, b) : op(k, .Sub, b, e)
		}
		from, to = end(k, lo, a, b), end(k, hi, a, b)
		if a < 0 do from, to = to, from
		return
	}
	if is_constant(s) {
		one: [1]Type
		cells, negated := cells_in(s, &one)
		if negated do return
		parts := make([]Type, len(cells))
		for c, i in cells {
			if cell_family(c) != .Int do return
			lo, hi := discrete_bounds(c)
			from, to := ends(k, maybe_int(lo), maybe_int(hi), a, b)
			parts[i] = range_law(k, from, to, .Int, {})
		}
		return or_law(k, parts), true
	}
	#partial switch v in s {
	case ^Range:
		if v.family != .Int && v.family != .Any do return
		from, to := ends(k, v.lo, v.hi, a, b)
		return range_law(k, from, to, .Int, v.span), true
	case ^And:
		terms := make([]Type, len(v.terms))
		for x, i in v.terms do terms[i] = moved(k, x, a, b) or_return
		return and_law(k, terms), true
	case ^Or:
		terms := make([]Type, len(v.terms))
		for x, i in v.terms do terms[i] = moved(k, x, a, b) or_return
		return or_law(k, terms), true
	case ^Not:
		return not_law(k, moved(k, v.term, a, b) or_return), true
	case ^Is:
		return is_law(a == 1 ? op(k, .Sub, v.term, b) : op(k, .Sub, b, v.term)), true
	}
	return
}

// power_preimage: x = b << e (b·2^e) or b ** e, b ≥ 1 a constant (≥ 2 for **), in the
// cells: the counts e for which it is, cell by cell, from the least whose power reaches
// the cell to the greatest whose power stays in it.
power_preimage :: proc(k: ^Kernel, x: Type, cells: []Type) -> (e, set: Type, ok: bool) {
	o := x.(^Operation) or_return
	if o.op != .Shl && o.op != .Pow do return
	base, constant := o.args[0].(Int)
	if !constant do return
	factor, ratio := i128(base), i128(2)
	if o.op == .Pow do factor, ratio = 1, i128(base)
	if factor < 1 || ratio < 2 do return
	// the least count whose power is at least m, and the greatest whose power is at most m
	least :: proc(factor, ratio, m: i128) -> i128 {
		n: i128 = 0
		for p := factor; p < m; p *= ratio {
			n += 1
			if p > max(i128) / ratio do break
		}
		return n
	}
	greatest :: proc(factor, ratio, m: i128) -> (n: i128, any: bool) {
		if m < factor do return 0, false
		for p := factor; p <= m / ratio; p *= ratio do n += 1
		return n, true
	}
	parts := make([dynamic]Type)
	for c in cells {
		if cell_family(c) != .Int do return
		lo, hi := discrete_bounds(c)
		from: Maybe(i128) = 0
		if l, has := lo.?; has do from = least(factor, ratio, l)
		to: Maybe(i128)
		if h, has := hi.?; has {
			n, any := greatest(factor, ratio, h)
			if !any do continue
			to = n
		}
		append(&parts, discrete_cell(.Int, from, to))
	}
	return o.args[1], or_law(k, parts[:]), true
}

// THE MEET OF RANGES (§4.1)
//
// a..b & c..d = max(a, c)..min(b, d), none when they do not meet: a set over unknowns
// holds nothing when two of its ranges are apart — the lower end l of one above the
// upper end h of the other, h - l in ..(-1), an equation simplified in turn. & distributes
// over |; a range holds what is between its ends, either way: l..h = (l.. & ..h) |
// (h.. & ..l); ~(a | b) = ~a & ~b; on the integers ~(..h) = (h + 1).., ~(l..) = ..(l - 1).

// holds_nothing: the set t, over unknowns, holds no value by the law of the meet.
holds_nothing :: proc(k: ^Kernel, t: Type) -> bool {
	if is_none(t) do return true
	if either, is_or := t.(^Or); is_or {
		for x in either.terms do if !holds_nothing(k, x) do return false
		return true
	}
	terms := []Type{t}
	if meet, is_and := t.(^And); is_and do terms = meet.terms
	// & over a union: each of its terms
	for x, i in terms {
		parts := union_parts(k, x) or_continue
		rest := make([dynamic]Type)
		for y, j in terms do if j != i do append(&rest, y)
		for p in parts {
			append(&rest, p)
			if !holds_nothing(k, and_law(k, rest[:])) do return false
			pop(&rest)
		}
		return true
	}
	lows, highs := make([dynamic]Type), make([dynamic]Type)
	for x in terms do range_pieces(k, x, &lows, &highs)
	below := range_law(k, nil, Int(-1), .Int, {})
	for l in lows do for h in highs {
		if is_constant(l) && is_constant(h) do continue
		if is_bool(in_law(k, op(k, .Sub, h, l), below), true) do return true
	}
	return false
}

// union_parts: x as a union of several sets, when it is one: a union; a constant of
// several cells; a range between two ends over unknowns, either way; ~(a | b) = ~a & ~b
// is a meet, not a union.
union_parts :: proc(k: ^Kernel, x: Type) -> (parts: []Type, ok: bool) {
	if is_constant(x) {
		one: [1]Type
		cells, negated := cells_in(x, &one)
		if negated || len(cells) < 2 do return
		return cells, true
	}
	#partial switch v in x {
	case ^Or:
		return v.terms, true
	case ^Range:
		if v.lo == nil || v.hi == nil do return
		out := make([]Type, 2)
		out[0] = and_law(k, {range_law(k, v.lo, nil, .Int, {}), range_law(k, nil, v.hi, .Int, {})})
		out[1] = and_law(k, {range_law(k, v.hi, nil, .Int, {}), range_law(k, nil, v.lo, .Int, {})})
		return out, true
	case ^Not:
		// ~(l..h): below both ends, or above both — (..(l - 1) & ..(h - 1)) |
		// ((h + 1).. & (l + 1)..), on the integers
		r, is_range := v.term.(^Range)
		if !is_range || r.lo == nil || r.hi == nil do return
		out := make([]Type, 2)
		out[0], out[1] = below_both(k, r.lo, r.hi), above_both(k, r.lo, r.hi)
		return out, true
	}
	return
}

// below_both: the integers below both ends: ..(l - 1) & ..(h - 1).
below_both :: proc(k: ^Kernel, l, h: Type) -> Type {
	return and_law(k, {range_law(k, nil, op(k, .Sub, l, Int(1)), .Int, {}), range_law(k, nil, op(k, .Sub, h, Int(1)), .Int, {})})
}

// above_both: the integers above both ends: (l + 1).. & (h + 1)...
above_both :: proc(k: ^Kernel, l, h: Type) -> Type {
	return and_law(k, {range_law(k, op(k, .Add, l, Int(1)), nil, .Int, {}), range_law(k, op(k, .Add, h, Int(1)), nil, .Int, {})})
}

// range_pieces: the ends of the ranges of the integers a term of a meet is: a half-line
// its one end, a constant range its two; ~(..h) has h + 1 below, ~(l..) has l - 1 above;
// ~(a | b), those of ~a and ~b; =t, t; a meet, those of each term.
range_pieces :: proc(k: ^Kernel, x: Type, lows, highs: ^[dynamic]Type) {
	if is_constant(x) {
		one: [1]Type
		cells, negated := cells_in(x, &one)
		if negated || len(cells) != 1 || cell_family(cells[0]) != .Int do return
		lo, hi := discrete_bounds(cells[0])
		if l, has := lo.?; has do append(lows, Int(l))
		if h, has := hi.?; has do append(highs, Int(h))
		return
	}
	#partial switch v in x {
	case ^Range:
		if v.lo != nil && v.hi != nil do return
		if v.lo != nil do append(lows, v.lo)
		if v.hi != nil do append(highs, v.hi)
	case ^Not:
		if either, is_or := v.term.(^Or); is_or {
			for t in either.terms do range_pieces(k, not_law(k, t), lows, highs)
			return
		}
		r, is_range := v.term.(^Range)
		if !is_range do return
		if r.lo == nil && r.hi != nil do append(lows, op(k, .Add, r.hi, Int(1)))
		if r.hi == nil && r.lo != nil do append(highs, op(k, .Sub, r.lo, Int(1)))
	case ^Is:
		append(lows, v.term)
		append(highs, v.term)
	case ^And:
		for t in v.terms do range_pieces(k, t, lows, highs)
	}
}

// layout_reads: the layout of w reads u, itself or through the layouts it reads (a
// layout never reads its own unknown).
layout_reads :: proc(k: ^Kernel, w, u: ^Unknown) -> bool {
	l := layout_of(k, w)
	if l == nil || is_constant(l) do return false
	return holds_unknown(k, l, u)
}

// holds_unknown: t holds u, itself or through the layouts of the unknowns it holds.
holds_unknown :: proc(k: ^Kernel, t: Type, u: ^Unknown) -> bool {
	inner := make([dynamic]^Unknown)
	read_unknowns(t, &inner)
	for x in inner do if same_unknown(x, u) || layout_reads(k, x, u) do return true
	return false
}
