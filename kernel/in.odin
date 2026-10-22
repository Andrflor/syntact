package kernel

// THE TYPE `x in c`
//
// `C:x -> V` holds when, for every value of the unknowns, V is an element of C:
// the type `V in C` holds. The color and the value are typed the same way
// (type_of); the difference is in `in` alone. `u8 in u8` does not hold — the set
// u8 is not one of its elements — while `u8 in =u8` does. An atom (5, n, 'a',
// none) is its own singleton, `=a = a`: for it, being an element and being equal
// are the same.
//
// `x in c` is a type of the algebra, a boolean like a comparison. A truth holds
// when true is one of its elements; & | ~ on truths are then ∧ ∨ ¬, with nothing
// else: `true | false` holds, `true & false` does not. An unknown is in its
// domain, a branch knows `target in part`: the same type.
//
// in_type writes `x in c` in normal form, by the law of what builds c:
//
//   x in K             K a known set: decided on a known x, otherwise it stays
//   x in a             a an atom: x = a                         =a = a
//   x in A | B         (x in A) | (x in B)
//   x in A & B         (x in A) & (x in B)
//   x in ~A            (x in the sorts of A) & ~(x in A)
//   x in lo..hi        (lo <= x) & (x <= hi)  |  (hi <= x) & (x <= lo)
//   x in >y            x > y                                    and <, >=, <=, !=
//   x in cases         in each case, under what its branch knows
//   x in S             S a scope: in its normal form — what its productions
//                      admit, Arden's solution when it mentions itself, or its
//                      shape; read directly when that form depends on unknowns
//
// What no law rewrites stays `x in c`; decide.odin decides whether a truth holds
// for every value of the unknowns.

// Element: what `in` asks about — a type, or a run of bindings: the part of a scope
// that a run of a shape receives, itself a scope. A scope is asked as the run of
// all its places.
Element :: union {
	^Expr,
	[]Place,
}

// in_type: the type `x in c`, in normal form, in the context ctx.
in_type :: proc(k: ^Kernel, x: Element, c: ^Expr, ctx: Context) -> ^Expr {
	if c == nil || is_invalid(c) do return truth(true) // already reported
	if e, is_expr := x.(^Expr); is_expr {
		if e == nil || is_invalid(e) do return truth(true)
		#partial switch v in e^ {
		case ^Scope:
			return in_type(k, places(v), c, ctx)
		case Cases:
			out := make([dynamic]Case)
			for w in v.cases do if reachable(k, ctx, w.fact) do append(&out, Case{w.fact, in_type(k, w.value, c, with(ctx, w.fact))})
			return by_cases(out[:])
		}
	}
	if _, _, recursive := equation_var(c); recursive {
		set, _ := normal_set(k, c)
		return in_set(k, x, set)
	}
	#partial switch v in c^ {
	case Cases:
		out := make([dynamic]Case)
		for w in v.cases do if reachable(k, ctx, w.fact) do append(&out, Case{w.fact, in_type(k, x, w.value, with(ctx, w.fact))})
		return by_cases(out[:])
	case Set:
		return in_set(k, x, v)
	case ^Scope:
		if set, known := normal_set(k, c); known do return in_set(k, x, set)
		return in_scope(k, x, v, false, ctx)
	case Set_Form:
		return in_form(k, x, v, ctx)
	case Poly, Term, ^Var:
		// an atom is its own singleton
		e, is_expr := x.(^Expr)
		if !is_expr do return truth(false) // a scope is not an atom
		return equal(k, e, c)
	}
	return truth(false)
}

// single: `x in =t` — x is the value t itself. An atom is its own singleton:
// x in t. A scope is read exactly: a binding with a color admits by it, the others
// only their value. A set of several values admits only itself.
single :: proc(k: ^Kernel, x: Element, t: ^Expr, ctx: Context) -> ^Expr {
	if t == nil || is_invalid(t) do return truth(true)
	if set, known := single_set(k, t); known do return in_set(k, x, set)
	if _, d, recursive := equation_var(t); recursive do return in_scope(k, x, d, true, ctx)
	#partial switch v in t^ {
	case ^Scope:
		return in_scope(k, x, v, true, ctx)
	case Cases:
		out := make([dynamic]Case)
		for w in v.cases do if reachable(k, ctx, w.fact) do append(&out, Case{w.fact, single(k, x, w.value, with(ctx, w.fact))})
		return by_cases(out[:])
	}
	e, is_expr := x.(^Expr)
	if !is_expr do return truth(false) // a scope is not a value of another kind
	if is_value(t) do return in_type(k, e, t, ctx)
	return equal(k, e, t)
}

// in_set: x in K, K a known set. A scope is read in its shapes; a known value is
// decided; a single boolean x is in K by its booleans — x in true is x; another
// value stays x in K.
in_set :: proc(k: ^Kernel, x: Element, set: Set) -> ^Expr {
	if view, is_view := x.([]Place); is_view do return in_bdd(k, view, set.scopes)
	e := x.(^Expr)
	if v, known := e^.(Set); known do return truth(set_member(v, set))
	if d, ok := value_domain(k, e); ok && d == .Bools && is_value(e) {
		switch set.bools {
		case {.False, .True}:
			return truth(true)
		case {.True}:
			return e
		case {.False}:
			return complement(k, e)
		}
		return truth(false)
	}
	return in_term(k, e, new_expr(set))
}

// set_member: the known value v is an element of the set c. An atom (or none) is
// its own singleton, read among the atoms of c; a set of several values is an
// element only of a set that has it as one: `u8 in u8` does not hold, `u8 in =u8`
// does.
set_member :: proc(v, c: Set) -> bool {
	if is_atom(v) do return atoms_admitted(v, c)
	return values_contains(c.sets, v)
}

// in_term: `x in c` where no law rewrites further — known already when the
// envelope of x lies within c, or outside it.
in_term :: proc(k: ^Kernel, x, c: ^Expr) -> ^Expr {
	if set, known := c^.(Set); known && is_value(x) {
		env, _ := envelope(k, x)
		if atoms_admitted(env, set) do return truth(true)
		if none_admitted(env, set) do return truth(false)
	}
	return new_expr(Term{op = .In, args = pair(x, c)})
}

// equal: the truth `a = b` between two values. Values (atoms, forms over unknowns)
// compare by their normal forms, and an atom is its own singleton: `a = 5` is
// `a in 5`. A known set of several values equals only the same set; a set that
// depends on unknowns stays an equality.
equal :: proc(k: ^Kernel, a, b: ^Expr) -> ^Expr {
	x, a_known := a^.(Set)
	y, b_known := b^.(Set)
	if a_known && b_known do return truth(set_equal(x, y))
	if is_value(a) && is_value(b) {
		if a_known do return in_term(k, b, a)
		if b_known do return in_term(k, a, b)
		if r, ok := compare(k, .Eq, a, b); ok do return r
	}
	// an atom is never a known set of several values
	if (is_value(a) && b_known) || (is_value(b) && a_known) do return truth(false)
	if expr_equal(k, a, b) do return truth(true)
	l, r := ordered(a, b)
	return new_expr(Term{op = .Eq, args = pair(l, r)})
}

// compare: the truth `a ⋈ b` between two values, in normal form. An order between
// two different sorts does not hold: x of another sort is not between the bounds.
// False when ⋈ does not apply.
compare :: proc(k: ^Kernel, op: Compare_Op, a, b: ^Expr) -> (^Expr, bool) {
	r, status := compare_values(k, op, a, b)
	if status == .Invalid do return truth(false), true
	return r, status == .Ok
}

// in_form: x in f, an operation on sets whose operands depend on unknowns — the
// law of the operation.
in_form :: proc(k: ^Kernel, x: Element, f: Set_Form, ctx: Context) -> ^Expr {
	#partial switch f.op.kind {
	case .Union:
		return alternative(k, in_type(k, x, f.args[0], ctx), in_type(k, x, f.args[1], ctx))
	case .Inter:
		return requires(k, in_type(k, x, f.args[0], ctx), in_type(k, x, f.args[1], ctx))
	case .Comp:
		if env, ok := set_envelope(k, f.args[0]); ok {
			return requires(k, in_type(k, x, new_expr(sorts_of(env)), ctx), complement(k, in_type(k, x, f.args[0], ctx)))
		}
	}
	e, is_expr := x.(^Expr)
	if !is_expr do return truth(false) // a scope is in no set of atoms
	if is_value(e) {
		#partial switch f.op.kind {
		case .Half:
			if r, ok := compare(k, compare_op_of(f.op.half), e, f.args[0]); ok do return r
		case .Range:
			if r, ok := in_range(k, e, f); ok do return r
		}
	}
	return in_term(k, e, new_expr(f))
}

// in_range: x in lo..hi between numbers or characters — lo <= x <= hi, in either
// order. Between strings, `..` means "starts with" and "ends with", which no
// comparison writes; bounds that are sets make a union of ranges: false.
in_range :: proc(k: ^Kernel, x: ^Expr, f: Set_Form) -> (r: ^Expr, ok: bool) {
	lo, hi := f.args[0], f.args[1]
	for bound, i in f.args {
		open := i == 0 ? f.op.lo_open : f.op.hi_open
		if !open && !(is_value(bound) && ordered_sort(k, bound)) do return nil, false
	}
	if f.op.lo_open do return compare(k, .Le, x, hi)
	if f.op.hi_open do return compare(k, .Le, lo, x)
	l1 := compare(k, .Le, lo, x) or_return
	h1 := compare(k, .Le, x, hi) or_return
	l2 := compare(k, .Le, hi, x) or_return
	h2 := compare(k, .Le, x, lo) or_return
	return alternative(k, requires(k, l1, h1), requires(k, l2, h2)), true
}

// ordered_sort: t is a value of an ordered sort — a number or a character.
ordered_sort :: proc(k: ^Kernel, t: ^Expr) -> bool {
	d, ok := value_domain(k, t)
	return ok && (d == .Ints || d == .Floats || d == .Chars)
}

// --- scopes ---

// Shape_Field: a place of a shape, and what it admits.
Shape_Field :: struct {
	name:   string,
	kind:   Binding_Kind,
	admits: ^Expr, // nil: anything — a named binding without color imposes nothing
	single: bool, // admits only the value `admits` itself: a binding without color, read exactly
	run:    bool, // `...C:`: a run of bindings, which forms a scope that C admits
	counts: Ints, // a counted run: n pieces, n among counts, each admitted; empty: a single one
}

// Matching: a membership being written — the shape, and what is asked of it.
Matching :: struct {
	shape: rawptr,
	exact: bool,
	asked: rawptr,
	len:   int,
}

// matching: the key of a membership; false when it is being written already. A
// shape that mentions itself can ask again the same thing (`X -> {...X:}`): a
// membership that depends on itself does not hold — the least solution, that of
// finite values.
matching :: proc(k: ^Kernel, shape: rawptr, exact: bool, x: Element) -> (key: Matching, fresh: bool) {
	key = Matching{shape, exact, nil, -1}
	switch v in x {
	case ^Expr:
		key.asked = v
	case []Place:
		key.asked, key.len = raw_data(v), len(v)
	}
	if key in k.matching do return key, false
	k.matching[key] = {}
	return key, true
}

// in_scope: x in s, s a scope whose normal form depends on unknowns — read
// directly. With productions, s admits what each one admits: a colored production
// `-> C:`, the elements of C; another, its value itself. Without, s is a shape: x
// is a scope of the same places, each admitted by its own. `exact`: x in =s, x is
// the scope s itself — every place of s is one of x, a production as well, and a
// binding without color admits only its value.
in_scope :: proc(k: ^Kernel, x: Element, s: ^Scope, exact: bool, ctx: Context) -> ^Expr {
	key, fresh := matching(k, s, exact, x)
	if !fresh do return truth(false)
	defer delete_key(&k.matching, key)
	if !exact && first_production(s) != nil {
		result := truth(false)
		for p in places(s) {
			b := binding_at(p)
			if b.kind != .Product do continue
			if b.color_type != nil do result = alternative(k, result, in_type(k, x, b.color_type, ctx))
			else if b.value_type != nil do result = alternative(k, result, single(k, x, b.value_type, ctx))
		}
		return result
	}
	view, is_view := x.([]Place)
	if !is_view do return truth(false) // only a scope has the places of a shape
	fields := make([dynamic]Shape_Field, context.temp_allocator)
	shape_fields(s, exact, &fields)
	return match_fields(k, fields[:], view, ctx)
}

// shape_fields: the places of the shape s, each by its contract — its color,
// written or received from the shape around it (implicit coloring). `...xs` lays
// down the places of xs; `...C:` is a run. A binding without color admits its
// value; named, in a shape that is not exact, it imposes nothing: a carve can give
// it any value.
shape_fields :: proc(s: ^Scope, exact: bool, out: ^[dynamic]Shape_Field) {
	for b in s.bindings {
		if b.kind == .Expand {
			if b.color == nil {
				if v, ok := expanded(b); ok do shape_fields(v, exact, out)
				continue
			}
			append(out, Shape_Field{kind = .Expand, admits = b.color_type, run = true})
			continue
		}
		f := Shape_Field{name = b.name, kind = b.kind}
		switch {
		case b.color_type != nil:
			f.admits = b.color_type
		case b.name != "" && !exact:
		case:
			f.admits, f.single = b.value_type, true
		}
		append(out, f)
	}
}

// in_bdd: a scope in a combination of shapes, a node {a, yes, maybe, no} being
// (a & yes) | maybe | (~a & no): the laws of |, & and ~.
in_bdd :: proc(k: ^Kernel, view: []Place, b: Bdd) -> ^Expr {
	switch v in b {
	case Bdd_Leaf:
		return truth(v == .Top)
	case ^Bdd_Node:
		atom := in_record(k, v.atom, view)
		result := requires(k, atom, in_bdd(k, view, v.yes))
		result = alternative(k, result, in_bdd(k, view, v.maybe))
		if !is_leaf(v.no, .Bottom) do result = alternative(k, result, requires(k, complement(k, atom), in_bdd(k, view, v.no)))
		return result
	}
	return truth(false)
}

// in_record: the run view has the shape r, each of whose fields admits its set. A
// self-reference is read on the value: in the normal form of its equation, or in
// its scope directly when that form depends on unknowns.
in_record :: proc(k: ^Kernel, r: ^Record, view: []Place) -> ^Expr {
	key, fresh := matching(k, r, false, view)
	if !fresh do return truth(false)
	defer delete_key(&k.matching, key)
	if r.equation != nil {
		if set, solved := normal_set(k, new_expr(r.shape)); solved do return in_bdd(k, view, set.scopes)
		return in_scope(k, view, r.shape, false, nil)
	}
	fields := make([]Shape_Field, len(r.fields), context.temp_allocator)
	for f, i in r.fields {
		fields[i] = Shape_Field{name = f.name, kind = f.kind, run = f.run, counts = f.counts}
		if !f.free do fields[i].admits = new_expr(f.set)
	}
	return match_fields(k, fields, view, nil)
}

// match_fields: the run of bindings view has the places fields — each place takes
// a binding, a run takes a part of any length: every split is tried.
match_fields :: proc(k: ^Kernel, fields: []Shape_Field, view: []Place, ctx: Context) -> ^Expr {
	memo := make(map[[2]int]^Expr, context.temp_allocator)
	return match_from(k, fields, view, 0, 0, &memo, ctx)
}

// match_from: view[i:] has the places fields[j:] — the alternatives that can hold,
// joined by |.
match_from :: proc(k: ^Kernel, fields: []Shape_Field, view: []Place, i, j: int, memo: ^map[[2]int]^Expr, ctx: Context) -> ^Expr {
	if j == len(fields) do return truth(i == len(view))
	if m, seen := memo[{i, j}]; seen do return m
	f := fields[j]
	result := truth(false)
	if f.run {
		for e in i ..= len(view) {
			part := in_run(k, f, view[i:e], ctx)
			if never(part) do continue
			result = alternative(k, result, requires(k, part, match_from(k, fields, view, e, j + 1, memo, ctx)))
			if always(result) do break
		}
	} else if i < len(view) {
		here := in_field(k, f, binding_at(view[i])^, ctx)
		if !never(here) do result = requires(k, here, match_from(k, fields, view, i + 1, j + 1, memo, ctx))
	}
	memo[{i, j}] = result
	return result
}

// in_run: the run view is admitted by the run f — as a single piece, or as n
// non-empty pieces, n among its counts, each admitted.
in_run :: proc(k: ^Kernel, f: Shape_Field, view: []Place, ctx: Context) -> ^Expr {
	if len(f.counts.intervals) == 0 do return in_type(k, view, f.admits, ctx)
	repeated :: proc(k: ^Kernel, f: Shape_Field, view: []Place, n: i128, ctx: Context) -> ^Expr {
		if len(view) == 0 do return truth(ints_contains(f.counts, n))
		result := truth(false)
		for e in 1 ..= len(view) {
			piece := in_type(k, view[:e], f.admits, ctx)
			if never(piece) do continue
			result = alternative(k, result, requires(k, piece, repeated(k, f, view[e:], n + 1, ctx)))
			if always(result) do break
		}
		return result
	}
	return repeated(k, f, view, 0, ctx)
}

// in_field: the binding b takes the place f — the same name and arrow, and admitted
// by what f admits. A binding colored within the color of f is admitted: its value
// is in its own color, or its own check reports it.
in_field :: proc(k: ^Kernel, f: Shape_Field, b: Binding, ctx: Context) -> ^Expr {
	if f.name != b.name || f.kind != b.kind do return truth(false)
	if f.admits == nil do return truth(true)
	if f.single do return single(k, b.value_type, f.admits, ctx)
	if b.color_type != nil && color_within(k, b.color_type, f.admits) do return truth(true)
	return in_type(k, b.value_type, f.admits, ctx)
}

// color_within: every element of the color c is one of s — the same type, or the
// normal form of c within that of s.
color_within :: proc(k: ^Kernel, c, s: ^Expr) -> bool {
	if c == s do return true
	a, a_known := normal_set(k, c)
	b, b_known := normal_set(k, s)
	return a_known && b_known && atoms_subset(a, b)
}

// --- truths ---

// &, | and ~ of the algebra, on types already typed: on truths, ∧ ∨ ¬.
inter :: proc(k: ^Kernel, a, b: ^Expr) -> ^Expr {
	return set_operation(k, Set_Op{kind = .Inter}, {}, a, b)
}

unite :: proc(k: ^Kernel, a, b: ^Expr) -> ^Expr {
	return set_operation(k, Set_Op{kind = .Union}, {}, a, b)
}

complement :: proc(k: ^Kernel, a: ^Expr) -> ^Expr {
	return set_operation(k, Set_Op{kind = .Comp}, {}, a)
}

// requires: what is required so far, and one more truth — joined by &. A truth
// that holds requires nothing more; one that never holds can never be met.
requires :: proc(k: ^Kernel, so_far, next: ^Expr) -> ^Expr {
	if never(so_far) || always(next) do return so_far
	if always(so_far) || never(next) do return next
	return inter(k, so_far, next)
}

// alternative: the alternatives so far, and one more — joined by |. An
// alternative that never holds offers nothing; one that holds is enough.
alternative :: proc(k: ^Kernel, so_far, next: ^Expr) -> ^Expr {
	if always(so_far) || never(next) do return so_far
	if never(so_far) || always(next) do return next
	return unite(k, so_far, next)
}

// truth: a known truth.
truth :: proc(b: bool) -> ^Expr {
	return bool_atom(b)
}

// never: t is a known truth that does not hold — true is not one of its elements.
never :: proc(t: ^Expr) -> bool {
	s, known := t^.(Set)
	return known && .True not_in s.bools
}

// always: t is a known truth that holds.
always :: proc(t: ^Expr) -> bool {
	s, known := t^.(Set)
	return known && .True in s.bools
}

// by_cases: a truth by cases — known when every case says the same; without a
// case, nothing is asked.
by_cases :: proc(cases: []Case) -> ^Expr {
	if len(cases) == 0 do return truth(true)
	for holds in ([2]bool{true, false}) {
		all := true
		for c in cases do all &&= holds ? always(c.value) : never(c.value)
		if all do return truth(holds)
	}
	return new_expr(Cases{cases})
}
