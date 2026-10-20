package kernel

import "core:fmt"
import "core:slice"
import "core:strings"

// UNKNOWNS AND THEIR NORMAL FORMS
//
// An unknown (`??::u8`, `string:s -> ??`) is a variable that carries its domain,
// the set of its possible values (specs/equational.md). An expression that depends
// on it keeps its form, normalized to be precise (`n - n` is 0, not -255..255):
//
//   integers      a polynomial: Σ coef·monomial + constant, monomials sorted,
//                 nonzero coefficients; without a monomial, it is the atom.
//                 n - n → 0      n*3 + n → 4*??0      (n + 1)*2 → 2*??0 + 2
//   floats        a term reduced by the only laws that are exact in IEEE: the
//                 commutativity of + and *, -(-x) = x, x*1.0 = x.
//   strings       a word: flattened concatenation, neighboring literals merged.
//   comparisons   on integers p < 0, p = 0, p ≠ 0 with p normalized (gcd,
//                 sign); otherwise a < b, a <= b (fixed direction), a = b (ordered).
//
// The normal form IS the type: exact, never replaced by an approximation.
// Its possible values are computed only to decide (check.odin): exact when its
// unknowns can be enumerated, a safe envelope otherwise. A color can depend on
// unknowns too (check.odin, admitted).

// Var: a variable — an unknown value that carries its type. All its mentions are
// the same node; `id` only serves for ordering and printing.
//
// The type of a `??` is a set. That of a self-reference is the equation it
// designates, as an expression writes it (specs/equational.md §2): the scope being
// defined (X), this scope carved by other arguments, or its production (a
// recursive call: `f{n -> n - 1}!`).
Var :: struct {
	id:   int,
	type: ^Expr,
}

Mono :: struct {
	coef: i128,
	vars: []^Var, // sorted by id, repeated for powers: n² = [n, n]
}
Poly :: struct {
	monos: []Mono, // sorted, nonzero coefficients
	const: i128,
	denom: i128, // the common denominator, positive, reduced; 0 means 1. The values stay integers: n·(n+1)/2
}

// den: the denominator of a polynomial.
den :: proc(p: Poly) -> i128 {
	return p.denom == 0 ? 1 : p.denom
}

// numerator: the polynomial without its denominator.
numerator :: proc(p: Poly) -> Poly {
	q := p
	q.denom = 0
	return q
}

// over: num / d, reduced by the gcd of its coefficients and of d.
over :: proc(num: Poly, d: i128) -> Poly {
	if d == 1 do return num
	g := d
	for m in num.monos do g = gcd(g, abs(m.coef))
	g = gcd(g, abs(num.const))
	monos := make([]Mono, len(num.monos))
	for m, i in num.monos do monos[i] = Mono{m.coef / g, m.vars}
	r := Poly{monos = monos, const = num.const / g, denom = d / g}
	if r.denom == 1 do r.denom = 0
	return r
}

Term_Op :: enum u8 {
	F_Add, // floats: commutative, ordered operands
	F_Mul,
	F_Neg,
	Concat, // strings: a word
	Repeat, // [text, count]: a repetition whose count is unknown
	Lt, // integers: [p] for p < 0; otherwise [a, b] for a < b
	Le, // [a, b] for a <= b
	Eq, // integers: [p] for p = 0; otherwise [a, b] ordered
	Ne,
	Cast, // [value, layout]: the value forced into the layout (op.odin, cast_into)
	Div, // integers: [a, b], a / b truncated toward zero, b never zero (op.odin, division)
	Mod, // integers: [a, b], the remainder, with the sign of a
	F_Div, // floats: [a, b], the IEEE 754 division
}

Term :: struct {
	op:   Term_Op,
	args: []^Expr,
}


// --- symbols ---

// new_symbol: a variable of type `set`. A variable with a single
// possible value is that value.
new_symbol :: proc(k: ^Kernel, set: Set) -> ^Expr {
	if is_atom(set) do return new_expr(set)
	v := new_var(k, set)
	if d, pure := pure_domain(set); pure && d == .Ints {
		return new_expr(poly_var(v))
	}
	return new_expr(v)
}

// new_var: a variable of domain `set`.
new_var :: proc(k: ^Kernel, set: Set) -> ^Var {
	v := new(Var)
	v^ = Var{k.variables, new_expr(set)}
	k.variables += 1
	return v
}

// new_equation_var: a variable whose type is an equation — `type` written on the
// scope being defined.
new_equation_var :: proc(k: ^Kernel, type: ^Expr) -> ^Expr {
	v := new(Var)
	v^ = Var{k.variables, type}
	k.variables += 1
	return new_expr(v)
}

// equation_of: the scope of which the type of v is the equation, and the
// expression that writes it: the scope itself, carved, or collapsed (a call).
equation_of :: proc(v: ^Var) -> (d: ^Scope, carve: Maybe(Carve), call: bool, ok: bool) {
	t := v.type
	if c, collapsed := t^.(Collapse); collapsed {
		t = c.target
		call = true
	}
	if x, carved := t^.(Carve); carved {
		carve = x
		t = x.target
	}
	d, ok = t^.(^Scope)
	return
}

// equation_var: t is a self-reference that designates a scope (X, carved or not);
// its variable, and the scope of which it is the equation.
equation_var :: proc(t: ^Expr) -> (^Var, ^Scope, bool) {
	v, is_var := t^.(^Var)
	if !is_var do return nil, nil, false
	d, _, call, ok := equation_of(v)
	return v, d, ok && !call
}

// pending: t is a variable whose domain is an equation not yet solved; it takes
// the sort of the operation where it appears.
pending :: proc(t: ^Expr) -> (^Var, bool) {
	v, is_var := t^.(^Var)
	if !is_var do return nil, false
	_, solved := domain(v)
	return v, !solved
}

// domain: the set of possible values of a variable; false when its type is an
// equation not yet solved.
domain :: proc(v: ^Var) -> (Set, bool) {
	s, solved := v.type^.(Set)
	return s, solved
}

// --- the context ---

// Fact: what a branch knows about a variable — within it, the variable is only
// `domain`.
Fact :: struct {
	var:    ^Var,
	domain: Set,
}

// Context: the facts that hold at a place, those of the branches that surround it
// (specs/equational.md §3). Refinement is not a rewriting: the types do not
// change, what is known about their variables is what changes.
Context :: []Fact

// known_domain: the domain of v in the context ctx; false when its domain is an
// equation not yet solved.
known_domain :: proc(k: ^Kernel, ctx: Context, v: ^Var) -> (d: Set, solved: bool) {
	if derived(v) {
		d, _ = envelope(k, v.type, ctx) // an operation: the values of its expression
		return d, true
	}
	d = domain(v) or_return
	for f in ctx do if f.var == v do d = set_intersect(d, f.domain)
	return d, true
}

// derived: v names an integer operation that is not a polynomial (a division, a
// cast) so that it enters a polynomial: its type is that operation. It is
// transparent — its values, its unknowns, its evaluation are those of its
// expression.
derived :: proc(v: ^Var) -> bool {
	_, is_term := v.type^.(Term)
	return is_term
}

// as_int_poly: an integer value as a polynomial — an operation that is not one
// enters it through a derived variable (derived).
as_int_poly :: proc(k: ^Kernel, t: ^Expr) -> (Poly, bool) {
	if p, ok := as_poly(t); ok do return p, true
	if _, is_term := t^.(Term); is_term {
		v := new(Var)
		v^ = Var{k.variables, t}
		k.variables += 1
		return poly_var(v), true
	}
	return {}, false
}

// with: the context, and one more fact.
with :: proc(ctx: Context, f: Fact) -> Context {
	if f.var == nil do return ctx
	out := make([]Fact, len(ctx) + 1, context.temp_allocator)
	copy(out, ctx)
	out[len(ctx)] = f
	return out
}

// context_of: the facts that hold in s — those of the branches that surround it.
context_of :: proc(s: ^Scope) -> Context {
	facts := make([dynamic]Fact, context.temp_allocator)
	for sc := s; sc != nil; sc = sc.parent do if sc.fact.var != nil do append(&facts, sc.fact)
	return facts[:]
}

// --- the cases ---

// Case: a reached branch of a pattern — its value, and what it knows about the
// unknown (no fact when the target is not a lone unknown).
Case :: struct {
	fact:  Fact,
	value: ^Expr,
}

// Cases: the type of a pattern on an unknown. It is never flattened into a new
// unknown: each case keeps its value and what its branch knows
// (specs/equational.md §2).
Cases :: struct {
	cases: []Case,
}

poly_var :: proc(x: ^Var) -> Poly {
	vars := make([]^Var, 1)
	vars[0] = x
	monos := make([]Mono, 1)
	monos[0] = Mono{1, vars}
	return Poly{monos = monos}
}

// is_value: a value type — an atom, or a form over unknowns.
is_value :: proc(t: ^Expr) -> bool {
	#partial switch v in t^ {
	case Set:
		return is_atom(v)
	case Poly, Term, ^Var:
		return true
	}
	return false
}

// value_domain: the sort of a value, known or not.
value_domain :: proc(k: ^Kernel, t: ^Expr) -> (Domain, bool) {
	#partial switch v in t^ {
	case Set:
		return pure_domain(v)
	case Poly:
		return .Ints, true
	case ^Var:
		d, solved := domain(v)
		if !solved do return .Ints, false
		return pure_domain(d)
	case Term:
		switch v.op {
		case .F_Add, .F_Mul, .F_Neg:
			return .Floats, true
		case .Concat, .Repeat:
			return .Strings, true
		case .Lt, .Le, .Eq, .Ne:
			return .Bools, true
		case .Cast:
			s, _ := v.args[1]^.(Set)
			return pure_domain(s)
		case .Div, .Mod:
			return .Ints, true
		case .F_Div:
			return .Floats, true
		}
	}
	return .Ints, false
}

is_textual :: proc(d: Domain) -> bool {
	return d == .Strings || d == .Chars
}

// --- integer polynomials ---

as_poly :: proc(t: ^Expr) -> (Poly, bool) {
	#partial switch v in t^ {
	case Poly:
		return v, true
	case Set:
		if ints_count(v.ints) == 1 && set_count(v) == 1 {
			c, _ := ints_default(v.ints)
			return Poly{const = c}, true
		}
	}
	return {}, false
}

// poly_type: the normal form of a polynomial; without a monomial, it is an atom.
poly_type :: proc(p: Poly) -> ^Expr {
	if len(p.monos) == 0 && p.const % den(p) == 0 do return new_expr(set_of_ints(ints_point(p.const / den(p))))
	return new_expr(p)
}

mono_less :: proc(a, b: Mono) -> bool {
	if len(a.vars) != len(b.vars) do return len(a.vars) < len(b.vars)
	for v, i in a.vars do if v != b.vars[i] do return v.id < b.vars[i].id
	return false
}

var_less :: proc(a, b: ^Var) -> bool {
	return a.id < b.id
}

// poly_of: sorts, merges equal monomials, removes zero coefficients.
poly_of :: proc(monos: []Mono, c: i128) -> (Poly, bool) {
	sorted := slice.clone(monos)
	slice.sort_by(sorted, mono_less)
	out := make([dynamic]Mono, 0, len(sorted))
	for m in sorted {
		if len(out) > 0 && slice.equal(out[len(out) - 1].vars, m.vars) {
			s, ok := add_checked(out[len(out) - 1].coef, m.coef)
			if !ok do return {}, false
			out[len(out) - 1].coef = s
		} else {
			append(&out, m)
		}
	}
	kept := make([dynamic]Mono, 0, len(out))
	for m in out do if m.coef != 0 do append(&kept, m)
	return Poly{monos = kept[:], const = c}, true
}

// With denominators: the sum over the least common multiple, the product over the
// product, then reduced. The operations on the numerators are integer ones.

poly_add :: proc(a, b: Poly) -> (r: Poly, ok: bool) {
	da, db := den(a), den(b)
	if da == 1 && db == 1 do return num_add(a, b)
	l := mul_checked(da / gcd(da, db), db) or_return
	x := num_scale(numerator(a), l / da) or_return
	y := num_scale(numerator(b), l / db) or_return
	s := num_add(x, y) or_return
	return over(s, l), true
}

poly_scale :: proc(a: Poly, s: i128) -> (r: Poly, ok: bool) {
	n := num_scale(numerator(a), s) or_return
	return over(n, den(a)), true
}

poly_mul :: proc(a, b: Poly) -> (r: Poly, ok: bool) {
	d := mul_checked(den(a), den(b)) or_return
	n := num_mul(numerator(a), numerator(b)) or_return
	return over(n, d), true
}

num_add :: proc(a, b: Poly) -> (Poly, bool) {
	all := make([dynamic]Mono, 0, len(a.monos) + len(b.monos))
	append(&all, ..a.monos)
	append(&all, ..b.monos)
	c, ok := add_checked(a.const, b.const)
	if !ok do return {}, false
	return poly_of(all[:], c)
}

num_scale :: proc(a: Poly, s: i128) -> (Poly, bool) {
	out := make([]Mono, len(a.monos))
	for m, i in a.monos {
		c, ok := mul_checked(m.coef, s)
		if !ok do return {}, false
		out[i] = Mono{c, m.vars}
	}
	c, ok := mul_checked(a.const, s)
	if !ok do return {}, false
	return poly_of(out, c)
}

poly_sub :: proc(a, b: Poly) -> (Poly, bool) {
	nb, ok := poly_scale(b, -1)
	if !ok do return {}, false
	return poly_add(a, nb)
}

num_mul :: proc(a, b: Poly) -> (Poly, bool) {
	out := make([dynamic]Mono)
	c: i128 = 0
	for x in with_const(a) {
		for y in with_const(b) {
			coef, ok := mul_checked(x.coef, y.coef)
			if !ok do return {}, false
			vars := make([dynamic]^Var, 0, len(x.vars) + len(y.vars))
			append(&vars, ..x.vars)
			append(&vars, ..y.vars)
			slice.sort_by(vars[:], var_less)
			if len(vars) > 0 {
				append(&out, Mono{coef, vars[:]})
				continue
			}
			sum, s_ok := add_checked(c, coef)
			if !s_ok do return {}, false
			c = sum
		}
	}
	return poly_of(out[:], c)
}

// with_const: the monomials and the constant, the constant as an empty monomial.
with_const :: proc(p: Poly) -> []Mono {
	out := make([dynamic]Mono, 0, len(p.monos) + 1)
	append(&out, ..p.monos)
	if p.const != 0 do append(&out, Mono{p.const, nil})
	return out[:]
}

// poly_envelope: the values of a polynomial, by intervals, without enumerating.
// `exact` when each unknown appears in it once, with coefficient ±1: the sum of
// independent sets is then exact.
poly_envelope :: proc(k: ^Kernel, p: Poly, ctx: Context = nil) -> (sum: Ints, exact: bool) {
	if d := den(p); d > 1 {
		// the numerator, then the division: the values are integers
		n, _ := poly_envelope(k, numerator(p), ctx)
		lo, hi := ints_bounds(n)
		l, h: Maybe(i128)
		if x, ok := lo.?; ok do l = -floor_div(-x, d)
		if x, ok := hi.?; ok do h = floor_div(x, d)
		return ints_range(l, h), false
	}
	sum = ints_point(p.const)
	exact = true
	for m in p.monos {
		exact &&= len(m.vars) == 1 && abs(m.coef) == 1
		prod := ints_point(m.coef)
		for i := 0; i < len(m.vars); {
			j := i
			for j < len(m.vars) && m.vars[j] == m.vars[i] do j += 1
			ok: bool
			d, solved := known_domain(k, ctx, m.vars[i])
			if !solved do d = set_of_ints(ints_all()) // an equation not yet solved: any integer
			prod, ok = ints_arith(.Mul, prod, ints_pow(d.ints, j - i))
			exact &&= solved
			exact &&= ok
			i = j
		}
		ok: bool
		sum, ok = ints_arith(.Add, sum, prod) // a bound that overflows becomes infinite
		exact &&= ok
	}
	return
}

// --- floats, strings, comparisons: normalizing constructors ---

term_of :: proc(op: Term_Op, args: ..^Expr) -> ^Expr {
	return new_expr(Term{op = op, args = slice.clone(args)})
}

// ordered: the operands of a commutative operation in a fixed order.
ordered :: proc(a, b: ^Expr) -> (^Expr, ^Expr) {
	if expr_less(b, a) do return b, a
	return a, b
}

expr_less :: proc(a, b: ^Expr) -> bool {
	return print_type(a) < print_type(b)
}

float_add :: proc(a, b: ^Expr) -> ^Expr {
	x, y := ordered(a, b)
	return term_of(.F_Add, x, y)
}

float_mul :: proc(a, b: ^Expr) -> ^Expr {
	if is_float_atom(a, 1) do return b // x · 1.0 = x, exactly
	if is_float_atom(b, 1) do return a
	x, y := ordered(a, b)
	return term_of(.F_Mul, x, y)
}

float_neg :: proc(a: ^Expr) -> ^Expr {
	if s, ok := a^.(Set); ok do return new_expr(set_of_floats(floats_neg(s.floats)))
	if t, ok := a^.(Term); ok && t.op == .F_Neg do return t.args[0] // -(-x) = x
	return term_of(.F_Neg, a)
}

is_float_atom :: proc(e: ^Expr, v: f64) -> bool {
	s, ok := e^.(Set)
	return ok && floats_count(s.floats) == 1 && set_count(s) == 1 && floats_contains(s.floats, v)
}

// concat: a word. Neighboring known parts merge into one string; all known, it
// is an atom; the empty word disappears. A lone unknown character stays in a
// word, which is a string.
concat :: proc(k: ^Kernel, a, b: ^Expr) -> ^Expr {
	parts := make([dynamic]^Expr)
	append_parts(&parts, a)
	append_parts(&parts, b)
	if len(parts) == 0 do return new_expr(set_of_strings(strings_point("")))
	if len(parts) == 1 {
		if d, ok := value_domain(k, parts[0]); ok && d == .Strings do return parts[0]
	}
	return new_expr(Term{op = .Concat, args = parts[:]})
}

append_parts :: proc(parts: ^[dynamic]^Expr, e: ^Expr) {
	if t, ok := e^.(Term); ok && t.op == .Concat {
		for p in t.args do append_parts(parts, p)
		return
	}
	s, known := e^.(Set)
	if !known {
		append(parts, e)
		return
	}
	word, _ := strings_single(as_strings(s))
	if word == "" do return // the empty word changes nothing
	if len(parts) > 0 {
		if last, last_known := parts[len(parts) - 1]^.(Set); last_known {
			prev, _ := strings_single(as_strings(last))
			parts[len(parts) - 1] = new_expr(set_of_strings(strings_point(fmt.tprintf("%s%s", prev, word))))
			return
		}
	}
	append(parts, new_expr(set_of_strings(strings_point(word))))
}

// repeat_term: a text repeated a known number of times is a word; an unknown
// count keeps the repetition.
repeat_term :: proc(k: ^Kernel, text, count: ^Expr) -> (^Expr, Arith_Status) {
	if n, ok := as_poly(count); ok && len(n.monos) == 0 {
		if n.const < 0 do return nil, .Invalid
		if n.const > MAX_REPEAT do return nil, .Unsupported
		r := new_expr(set_of_strings(strings_point("")))
		for _ in 0 ..< n.const do r = concat(k, r, text)
		return r, .Ok
	}
	return term_of(.Repeat, text, count), .Ok
}

// --- comparisons ---

Compare_Op :: enum u8 {
	Lt,
	Le,
	Gt,
	Ge,
	Eq,
	Ne,
}

// int_compare: `a ⋈ b` from p = a - b, decided when the values of p decide it,
// in normal form otherwise.
int_compare :: proc(k: ^Kernel, op: Compare_Op, p_in: Poly) -> (^Expr, Arith_Status) {
	p := numerator(p_in) // the denominator is positive: the sign is that of the numerator
	q := p
	kind := Term_Op.Lt
	ok := true
	switch op {
	case .Lt:
	case .Gt:
		q, ok = poly_scale(p, -1)
	case .Le:
		q, ok = poly_add(p, Poly{const = -1}) // p ≤ 0 ⇔ p - 1 < 0
	case .Ge:
		q, ok = poly_scale(p, -1)
		if ok do q, ok = poly_add(q, Poly{const = -1})
	case .Eq:
		kind = .Eq
	case .Ne:
		kind = .Ne
	}
	if !ok do return nil, .Unsupported
	if len(q.monos) == 0 do return bool_atom(decide_int(kind, q.const)), .Ok
	vals, _ := values_of(k, new_expr(q))
	lo, hi := ints_bounds(vals.ints)
	#partial switch kind {
	case .Lt:
		if h, h_ok := hi.?; h_ok && h < 0 do return bool_atom(true), .Ok
		if l, l_ok := lo.?; l_ok && l >= 0 do return bool_atom(false), .Ok
	case .Eq, .Ne:
		if !ints_contains(vals.ints, 0) do return bool_atom(kind == .Ne), .Ok
		if ints_count(vals.ints) == 1 do return bool_atom(kind == .Eq), .Ok
	}
	// Normalization: divide by the gcd of the coefficients, fix the sign.
	g: i128 = 0
	for m in q.monos do g = gcd(g, abs(m.coef))
	monos := make([]Mono, len(q.monos))
	for m, i in q.monos do monos[i] = Mono{m.coef / g, m.vars}
	c := q.const
	if kind == .Lt {
		c = floor_div(c, g) // g·r + c < 0 ⇔ r + ⌊c/g⌋ < 0
	} else {
		if c % g != 0 do return bool_atom(kind == .Ne), .Ok // g·r = -c has no integer solution
		c = c / g
		if monos[0].coef < 0 {
			for &m in monos do m.coef = -m.coef
			c = -c
		}
	}
	return term_of(kind, new_expr(Poly{monos = monos, const = c})), .Ok
}

decide_int :: proc(kind: Term_Op, c: i128) -> bool {
	#partial switch kind {
	case .Lt:
		return c < 0
	case .Eq:
		return c == 0
	}
	return c != 0
}

// general_compare: on a sort without a polynomial form. Decided when the values
// decide it; otherwise `>` and `>=` are written `<` and `<=` by swapping, `=` and
// `!=` order their operands.
general_compare :: proc(k: ^Kernel, op: Compare_Op, a, b: ^Expr) -> (^Expr, Arith_Status) {
	// Two equal normal forms are the same value.
	if expr_equal(k, a, b) do return bool_atom(op == .Eq || op == .Le || op == .Ge), .Ok
	va, _ := values_of(k, a)
	vb, _ := values_of(k, b)
	#partial switch op {
	case .Eq, .Ne:
		verdict := equal_verdict(va, vb)
		if card(verdict) == 1 {
			if op == .Ne do verdict = ~verdict
			return new_expr(set_of_bools(verdict)), .Ok
		}
		x, y := ordered(a, b)
		return term_of(op == .Eq ? .Eq : .Ne, x, y), .Ok
	}
	verdict, ok := order_verdict(op, va, vb)
	if !ok do return nil, .Invalid
	if card(verdict) == 1 do return new_expr(set_of_bools(verdict)), .Ok
	#partial switch op {
	case .Lt:
		return term_of(.Lt, a, b), .Ok
	case .Le:
		return term_of(.Le, a, b), .Ok
	case .Gt:
		return term_of(.Lt, b, a), .Ok
	}
	return term_of(.Le, b, a), .Ok
}

gcd :: proc(a, b: i128) -> i128 {
	if a == 0 && b == 0 do return 1
	x, y := a, b
	for y != 0 do x, y = y, x % y
	return x
}

floor_div :: proc(a, b: i128) -> i128 {
	q := a / b
	if (a % b != 0) && ((a < 0) != (b < 0)) do q -= 1
	return q
}

bool_atom :: proc(v: bool) -> ^Expr {
	return new_expr(set_of_bools(bools_point(v)))
}

// --- possible values ---

// values_of: the possible values of a value type, by its envelope — exact when the
// algebra allows it, over-approximated otherwise. Nothing is enumerated.
values_of :: proc(k: ^Kernel, t: ^Expr) -> (vals: Set, exact: bool) {
	#partial switch v in t^ {
	case Set:
		return v, true
	case Poly, Term, ^Var:
		return envelope(k, t)
	}
	return {}, false
}

// envelope: the possible values of a form, without enumerating. `exact` when no
// unknown repeats in it and the operation is exact on independent sets (a sum
// ±x ± y…, a concatenation of words); over-approximated otherwise.
envelope :: proc(k: ^Kernel, t: ^Expr, ctx: Context = nil) -> (vals: Set, exact: bool) {
	#partial switch v in t^ {
	case Set:
		return v, true
	case Poly:
		ints, ints_exact := poly_envelope(k, v, ctx)
		return set_of_ints(ints), ints_exact
	case Cases:
		for c in v.cases {
			s, _ := envelope(k, c.value, with(ctx, c.fact))
			vals = set_union(vals, s)
		}
		return vals, false
	case ^Var:
		d, solved := known_domain(k, ctx, v)
		if !solved do return set_everything(), false // an equation not yet solved
		return d, true
	case Term:
		arg :: proc(k: ^Kernel, t: Term, i: int, ctx: Context) -> Set {
			s, _ := envelope(k, t.args[i], ctx)
			return s
		}
		switch v.op {
		case .F_Add:
			return set_of_floats(floats_arith(.Add, arg(k, v, 0, ctx).floats, arg(k, v, 1, ctx).floats)), false
		case .F_Mul:
			return set_of_floats(floats_arith(.Mul, arg(k, v, 0, ctx).floats, arg(k, v, 1, ctx).floats)), false
		case .F_Neg:
			return set_of_floats(floats_neg(arg(k, v, 0, ctx).floats)), false
		case .Concat:
			l := strings_point("")
			for i in 0 ..< len(v.args) do l = strings_concat(l, as_strings(arg(k, v, i, ctx)))
			return set_of_strings(l), words_independent(v)
		case .Repeat:
			r, ok := strings_repeat(as_strings(arg(k, v, 0, ctx)), arg(k, v, 1, ctx).ints)
			if !ok do return set_of_strings(strings_all()), false
			return set_of_strings(r), false
		case .Lt, .Le, .Eq, .Ne:
			return set_of_bools(comparison_envelope(k, v, ctx)), false
		case .Cast:
			// what fits in the layout does not change; otherwise, the whole layout
			layout, _ := v.args[1]^.(Set)
			inner, _ := envelope(k, v.args[0], ctx)
			if atoms_subset(inner, layout) do return inner, false
			return layout, false
		case .Div:
			return set_of_ints(div_envelope(arg(k, v, 0, ctx).ints, arg(k, v, 1, ctx).ints)), false
		case .Mod:
			return set_of_ints(mod_envelope(arg(k, v, 0, ctx).ints, arg(k, v, 1, ctx).ints)), false
		case .F_Div:
			return set_of_floats(floats_all()), false
		}
	}
	return {}, false
}

// comparison_envelope: the possible truths of a comparison, by the envelope of its
// operands in the context — `v < 20` is always true when v ∈ 0..9.
comparison_envelope :: proc(k: ^Kernel, t: Term, ctx: Context) -> Bools {
	if len(t.args) == 1 {
		// [p] : p < 0, p = 0, p ≠ 0
		e, _ := envelope(k, t.args[0], ctx)
		lo, hi := ints_bounds(e.ints)
		l, l_ok := lo.?
		h, h_ok := hi.?
		#partial switch t.op {
		case .Lt:
			if h_ok && h < 0 do return {.True}
			if l_ok && l >= 0 do return {.False}
		case .Eq, .Ne:
			truth: Bools = {.False, .True}
			if !ints_contains(e.ints, 0) do truth = {.False}
			else if ints_count(e.ints) == 1 do truth = {.True}
			if t.op == .Ne && card(truth) == 1 do truth = ~truth
			return truth
		}
		return {.False, .True}
	}
	a, _ := envelope(k, t.args[0], ctx)
	b, _ := envelope(k, t.args[1], ctx)
	#partial switch t.op {
	case .Lt:
		if truth, ok := order_verdict(.Lt, a, b); ok do return truth
	case .Le:
		if truth, ok := order_verdict(.Le, a, b); ok do return truth
	case .Eq:
		return equal_verdict(a, b)
	case .Ne:
		truth := equal_verdict(a, b)
		if card(truth) == 1 do truth = ~truth
		return truth
	}
	return {.False, .True}
}

// words_independent: a word each part of which is known or an unknown that does
// not repeat in it — its values are exactly the concatenation of the sets.
words_independent :: proc(t: Term) -> bool {
	seen := make(map[^Var]bool, allocator = context.temp_allocator)
	for a in t.args {
		#partial switch v in a^ {
		case Set:
			continue
		case Term:
		case ^Var:
			if !seen[v] {
				seen[v] = true
				continue
			}
		}
		return false
	}
	return true
}

// --- exact enumeration ---

Char_Atom :: distinct i128

Atom :: union {
	i128,
	f64,
	Char_Atom,
	string,
	bool,
}

collect_symbols :: proc(t: ^Expr, out: ^[dynamic]^Var) {
	#partial switch v in t^ {
	case Poly:
		for m in v.monos do for x in m.vars {
			if derived(x) do collect_symbols(x.type, out)
			else do append(out, x)
		}
	case ^Var:
		append(out, v)
	case Term:
		for a in v.args do collect_symbols(a, out)
	case Set_Form:
		for a in v.args do collect_symbols(a, out)
	case Cases:
		for c in v.cases {
			if c.fact.var != nil do append(out, c.fact.var)
			collect_symbols(c.value, out)
		}
	}
}

// atoms_of_set: all the elements of a set, if it has at most `limit`.
atoms_of_set :: proc(s: Set, limit: int) -> ([]Atom, bool) {
	if domain_count(s, .Scopes) > 0 || domain_count(s, .Sets) > 0 do return nil, false // neither scopes nor sets enumerate into atoms
	out := make([dynamic]Atom)
	for iv in s.ints.intervals {
		lo, lo_ok := iv.lo.?
		hi, hi_ok := iv.hi.?
		if !lo_ok || !hi_ok || !narrow(lo, hi, limit) do return nil, false
		for v := lo; v <= hi; v += 1 do append(&out, v)
	}
	for iv in s.chars.intervals {
		lo, _ := iv.lo.?
		hi, _ := iv.hi.?
		if !narrow(lo, hi, limit) do return nil, false
		for v := lo; v <= hi; v += 1 do append(&out, Char_Atom(v))
	}
	if floats_count(s.floats) > 1 do return nil, false
	if floats_count(s.floats) == 1 {
		v, _ := floats_default(s.floats)
		append(&out, v)
	}
	if s.strings.re != nil {
		words, ok := strings_words(s.strings, limit)
		if !ok do return nil, false
		for w in words do append(&out, w)
	}
	if .False in s.bools do append(&out, false)
	if .True in s.bools do append(&out, true)
	return out[:], len(out) <= limit
}

// narrow: lo..hi has fewer than `limit` elements, without overflowing (hi - lo
// can exceed I128_MAX).
narrow :: proc(lo, hi: i128, limit: int) -> bool {
	if lo > I128_MAX - i128(limit) do return true
	return hi < lo + i128(limit)
}

set_of_atoms :: proc(atoms: []Atom) -> Set {
	ints := make([dynamic]i128)
	chars := make([dynamic]i128)
	floats := make([dynamic]Float_Interval)
	words := make([dynamic]string)
	bools: Bools
	for a in atoms {
		switch v in a {
		case i128:
			append(&ints, v)
		case Char_Atom:
			append(&chars, i128(v))
		case f64:
			append(&floats, Float_Interval{lo = v, hi = v})
		case string:
			append(&words, v)
		case bool:
			bools += {v ? .True : .False}
		}
	}
	return Set {
		ints = ints_of_points(ints[:]),
		floats = floats_of(floats[:]),
		chars = ints_of_points(chars[:]),
		strings = strings_of_words(words[:]),
		bools = bools,
	}
}

// ints_of_points: the set of these integers, consecutive runs as intervals.
ints_of_points :: proc(points: []i128) -> Ints {
	slice.sort(points)
	runs := make([dynamic]Int_Interval)
	for v in points {
		if len(runs) > 0 {
			last := &runs[len(runs) - 1]
			if hi, _ := last.hi.?; v - 1 <= hi { 	// v ≥ -I128_MAX: v - 1 does not overflow
				last.hi = max(hi, v)
				continue
			}
		}
		append(&runs, Int_Interval{v, v})
	}
	return ints_of(runs[:])
}

// atom_of: the value of a known atom.
atom_of :: proc(s: Set) -> (Atom, bool) {
	atoms, ok := atoms_of_set(s, 1)
	if !ok || len(atoms) != 1 do return nil, false
	return atoms[0], true
}

// eval: the value of `t` when each unknown `id` is env[id].
eval :: proc(t: ^Expr, env: []Atom) -> (Atom, bool) {
	#partial switch v in t^ {
	case Set:
		return atom_of(v)
	case ^Var:
		return env[v.id], true
	case Cases:
		// the case whose fact holds for these values
		for c in v.cases {
			if c.fact.var == nil do return nil, false
			if atoms_subset(set_of_atoms({env[c.fact.var.id]}), c.fact.domain) do return eval(c.value, env)
		}
		return nil, false
	case Poly:
		sum := v.const
		for m in v.monos {
			prod := m.coef
			for id in m.vars {
				value := env[id.id]
				if derived(id) {
					known: bool
					value, known = eval(id.type, env)
					if !known do return nil, false
				}
				x, is_int := value.(i128)
				if !is_int do return nil, false
				p, ok := mul_checked(prod, x)
				if !ok do return nil, false
				prod = p
			}
			s, ok := add_checked(sum, prod)
			if !ok do return nil, false
			sum = s
		}
		if sum % den(v) != 0 do return nil, false
		return sum / den(v), true
	case Term:
		if v.op == .Cast {
			x, known := eval(v.args[0], env)
			if !known do return nil, false
			layout, _ := v.args[1]^.(Set)
			l, ok := layout_of(layout)
			if !ok do return nil, false
			return cast_atom(x, l)
		}
		args := make([]Atom, len(v.args))
		for a, i in v.args {
			x, ok := eval(a, env)
			if !ok do return nil, false
			args[i] = x
		}
		#partial switch v.op {
		case .F_Add, .F_Mul:
			x, x_ok := args[0].(f64)
			y, y_ok := args[1].(f64)
			if !x_ok || !y_ok do return nil, false
			return v.op == .F_Add ? x + y : x * y, true
		case .F_Neg:
			x, ok := args[0].(f64)
			return -x, ok
		case .Div, .Mod:
			x, x_ok := args[0].(i128)
			y, y_ok := args[1].(i128)
			if !x_ok || !y_ok || y == 0 do return nil, false
			return v.op == .Div ? x / y : x % y, true
		case .F_Div:
			x, x_ok := args[0].(f64)
			y, y_ok := args[1].(f64)
			return x / y, x_ok && y_ok
		case .Concat:
			b := strings.builder_make()
			for a in args do strings.write_string(&b, atom_text(a))
			return strings.to_string(b), true
		case .Repeat:
			n, ok := args[1].(i128)
			if !ok || n < 0 || n > MAX_REPEAT do return nil, false
			return strings.repeat(atom_text(args[0]), int(n)), true
		case .Lt, .Le, .Eq, .Ne:
			if len(args) == 1 {
				p, ok := args[0].(i128)
				return decide_int(v.op, p), ok
			}
			return compare_atoms(v.op, args[0], args[1])
		}
	}
	return nil, false
}

// atom_text: a character or a string, as a string.
atom_text :: proc(a: Atom) -> string {
	#partial switch v in a {
	case string:
		return v
	case Char_Atom:
		if i128(v) == CHAR_EMPTY do return ""
		return fmt.tprintf("%c", rune(v))
	}
	return ""
}

compare_atoms :: proc(op: Term_Op, a, b: Atom) -> (Atom, bool) {
	if op == .Eq || op == .Ne do return atom_equal(a, b) == (op == .Eq), true
	less, ok := atom_less(a, b)
	if !ok do return nil, false
	if op == .Lt do return less, true
	greater, _ := atom_less(b, a)
	return !greater, true // a <= b
}

atom_equal :: proc(a, b: Atom) -> bool {
	switch x in a {
	case i128:
		y, ok := b.(i128)
		return ok && x == y
	case f64:
		y, ok := b.(f64)
		return ok && x == y
	case Char_Atom:
		y, ok := b.(Char_Atom)
		return ok && x == y
	case string:
		y, ok := b.(string)
		return ok && x == y
	case bool:
		y, ok := b.(bool)
		return ok && x == y
	}
	return false
}

atom_less :: proc(a, b: Atom) -> (bool, bool) {
	#partial switch x in a {
	case i128:
		y, ok := b.(i128)
		return x < y, ok
	case f64:
		y, ok := b.(f64)
		return x < y, ok
	case Char_Atom:
		y, ok := b.(Char_Atom)
		return x < y, ok
	}
	return false, false
}

// --- equality of forms ---

expr_equal :: proc(k: ^Kernel, a, b: ^Expr) -> bool {
	if a == nil || b == nil do return a == b
	if a == b do return true // the same type: a scope is its own type
	#partial switch x in a^ {
	case Set:
		y, ok := b^.(Set)
		return ok && atoms_subset(x, y) && atoms_subset(y, x)
	case Poly:
		y, ok := b^.(Poly)
		if !ok || x.const != y.const || den(x) != den(y) || len(x.monos) != len(y.monos) do return false
		for m, i in x.monos {
			if m.coef != y.monos[i].coef || !slice.equal(m.vars, y.monos[i].vars) do return false
		}
		return true
	case Term:
		y, ok := b^.(Term)
		if !ok || x.op != y.op || len(x.args) != len(y.args) do return false
		for e, i in x.args do if !expr_equal(k, e, y.args[i]) do return false
		return true
	case ^Var:
		y, ok := b^.(^Var)
		return ok && x == y
	case Cases:
		y, ok := b^.(Cases)
		if !ok || len(x.cases) != len(y.cases) do return false
		for c, i in x.cases {
			d := y.cases[i]
			if c.fact.var != d.fact.var || !set_equal(c.fact.domain, d.fact.domain) || !expr_equal(k, c.value, d.value) do return false
		}
		return true
	}
	return false
}

// printed_cases: `??0 ? {0..9 -> ??0 + 3  10..255 -> 10}`, the pattern that gives
// it; without a fact, the possible values.
printed_cases :: proc(c: Cases) -> (string, Level) {
	parts := make([dynamic]string, context.temp_allocator)
	on := c.cases[0].fact.var
	for x in c.cases {
		if x.fact.var != on || on == nil {
			on = nil
			break
		}
	}
	if on == nil {
		for x in c.cases do append(&parts, print_type_at(x.value, above(.OR)))
		return strings.join(parts[:], " | "), .OR
	}
	for x in c.cases do append(&parts, fmt.tprintf("%s -> %s", print_set(x.fact.domain), print_type_at(x.value, .NONE)))
	return fmt.tprintf("??%d ? {{%s}}", on.id, strings.join(parts[:], "  ")), .PATTERN
}

// --- printing ---

printed_poly :: proc(p_in: Poly) -> (string, Level) {
	if d := den(p_in); d > 1 {
		text, _ := printed_poly(numerator(p_in))
		return fmt.tprintf("(%s)/%d", text, d), .FACTOR
	}
	p := p_in
	b := strings.builder_make()
	for m, i in p.monos {
		coef := m.coef
		if i > 0 {
			strings.write_string(&b, coef < 0 ? " - " : " + ")
			coef = abs(coef)
		} else if coef < 0 {
			strings.write_byte(&b, '-')
			coef = -coef
		}
		if coef != 1 do fmt.sbprintf(&b, "%d*", coef)
		for v, j in m.vars {
			if j > 0 do strings.write_byte(&b, '*')
			strings.write_string(&b, print_var(v))
		}
	}
	if p.const > 0 do fmt.sbprintf(&b, " + %d", p.const)
	if p.const < 0 do fmt.sbprintf(&b, " - %d", -p.const)
	level := Level.TERM
	if len(p.monos) == 1 && p.const == 0 {
		m := p.monos[0]
		switch {
		case m.coef == 1 && len(m.vars) == 1:
			level = .PRIMARY
		case m.coef == -1 && len(m.vars) == 1:
			level = .UNARY
		case:
			level = .FACTOR
		}
	}
	return strings.to_string(b), level
}

// printed_term: the operands of a float operation are all in parentheses if
// needed — `(a + b) + c` is not `a + (b + c)` in IEEE.
printed_term :: proc(t: Term) -> (string, Level) {
	infix :: proc(args: []^Expr, symbol: string, operand: Level) -> string {
		parts := make([]string, len(args))
		for a, i in args do parts[i] = print_type_at(a, operand)
		return strings.join(parts, symbol)
	}
	switch t.op {
	case .F_Neg:
		return fmt.tprintf("-%s", print_type_at(t.args[0], .CALL)), .UNARY
	case .F_Add, .Concat:
		return infix(t.args, " + ", above(.TERM)), .TERM
	case .F_Mul, .Repeat:
		return infix(t.args, " * ", above(.FACTOR)), .FACTOR
	case .Lt, .Le:
		if len(t.args) == 1 do return fmt.tprintf("%s %s 0", print_type_at(t.args[0], above(.COMPARISON)), t.op == .Lt ? "<" : "<="), .COMPARISON
		return infix(t.args, t.op == .Lt ? " < " : " <= ", above(.COMPARISON)), .COMPARISON
	case .Eq, .Ne:
		if len(t.args) == 1 do return fmt.tprintf("%s %s 0", print_type_at(t.args[0], above(.EQUALITY)), t.op == .Eq ? "=" : "!="), .EQUALITY
		return infix(t.args, t.op == .Eq ? " = " : " != ", above(.EQUALITY)), .EQUALITY
	case .Cast:
		return fmt.tprintf("%s \\ %s", print_type_at(t.args[0], above(.CAST)), print_type_at(t.args[1], above(.CAST))), .CAST
	case .Div, .F_Div:
		return fmt.tprintf("%s / %s", print_type_at(t.args[0], .FACTOR), print_type_at(t.args[1], above(.FACTOR))), .FACTOR
	case .Mod:
		return fmt.tprintf("%s %% %s", print_type_at(t.args[0], .FACTOR), print_type_at(t.args[1], above(.FACTOR))), .FACTOR
	}
	return "", .PRIMARY
}
