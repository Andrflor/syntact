package kernel

import "core:slice"

// TYPES (specs/types.md §2)
//
// A type is an equation: the expression itself, in normal form. `a + 1` with a
// in u8 is the type `a + 1`; `b + 1` is another type, unless something proves
// a = b. A constant type is a set in normal form; an integer expression over
// unknowns is a polynomial; an operation that no law reduces stays an Apply.

Type :: union {
	Set, // a constant type (set.odin)
	Poly, // integers over unknowns (poly.odin)
	^Unknown, // ?k::L, when it is not an integer
	^Apply, // an operation that no law reduces
	^Frame, // a scope (scope.odin)
	Invalid, // an error already reported: what depends on it stays silent
}

Invalid :: struct {}

// Unknown: `??::L`, one value in its domain L (§5.2). Each `??` written is a
// distinct unknown; the same one comes back through a name.
Unknown :: struct {
	id:     int,
	domain: Type,
}

Op :: enum u8 {
	// §4.1, §4.4
	Or,
	And,
	Not,
	Is, // =t
	// §4.5, §4.6
	Add,
	Sub,
	Mul,
	Div,
	Mod,
	Neg,
	Bit_And,
	Bit_Or,
	Xor,
	Bit_Not,
	Shl,
	Shr,
	Less,
	Less_Eq,
	Greater,
	Greater_Eq,
	// §4.7
	In,
	// §4.3, a bound that depends on unknowns: [lo, hi], [lo], [hi]
	Range,
	Range_From,
	Range_To,
	// §6: [target, cover, product, …], a nil cover for the default branch
	Match,
	// §5.6: [frame]: a scope that names itself, carved and collapsed: never unfolded
	Recur,
}

Apply :: struct {
	op:   Op,
	args: []Type,
}

new_apply :: proc(op: Op, args: ..Type) -> Type {
	a := new(Apply)
	a^ = Apply{op, slice.clone(args)}
	return a
}

is_invalid :: proc(t: Type) -> bool {
	_, ok := t.(Invalid)
	return ok
}

is_constant :: proc(t: Type) -> bool {
	_, ok := t.(Set)
	return ok
}

type_true :: proc() -> Type {return set_bool(true)}
type_false :: proc() -> Type {return set_bool(false)}

// is_bool: t is the constant b.
is_bool :: proc(t: Type, b: bool) -> bool {
	s, ok := t.(Set)
	if !ok do return false
	p, single := set_single(s)
	v, is_b := p.(bool)
	return single && is_b && v == b
}

// new_unknown: ?k::domain. One possible value is that value; integer values
// make a polynomial.
new_unknown :: proc(k: ^Kernel, domain: Type) -> Type {
	if is_invalid(domain) do return Invalid{}
	if s, constant := domain.(Set); constant {
		if _, single := set_single(s); single do return s
	}
	u := new(Unknown)
	u^ = Unknown{k.unknowns, domain}
	k.unknowns += 1
	if family_of(domain) == {.Int} do return poly_var(u)
	return u
}

// family_of: the families the elements of a set-type belong to, by its form: a
// constant, a range of integers, a | of them.
family_of :: proc(t: Type) -> bit_set[Family] {
	#partial switch v in t {
	case Set:
		out: bit_set[Family]
		if !ints_empty(v.ints) do out += {.Int}
		if !reals_empty(v.reals) do out += {.Real}
		if !words_is_empty(set_words(v)) do out += {.String}
		if v.bools != {} do out += {.Bool}
		return out
	case ^Apply:
		#partial switch v.op {
		case .Range, .Range_From, .Range_To:
			return family_of_bound(v.args[0])
		case .Or:
			return family_of(v.args[0]) | family_of(v.args[1])
		case .And:
			return family_of(v.args[0]) & family_of(v.args[1])
		}
	}
	return {}
}

family_of_bound :: proc(t: Type) -> bit_set[Family] {
	#partial switch v in t {
	case Set:
		return family_of(v)
	case Poly:
		return {.Int}
	}
	return {}
}

// is_atom: t is one value for each value of its unknowns, not a set of values.
is_atom :: proc(t: Type) -> bool {
	switch v in t {
	case Set:
		if set_is_none(v) do return true
		_, single := set_single(v)
		return single
	case Poly, ^Unknown, ^Frame, Invalid:
		return true
	case ^Apply:
		#partial switch v.op {
		case .Or, .And, .Not, .Is, .Range, .Range_From, .Range_To:
			return false
		case .In, .Recur:
			return true
		case .Match:
			for i := 2; i < len(v.args); i += 2 do if !is_atom(v.args[i]) do return false
			return true
		}
		for a in v.args do if !is_atom(a) do return false
		return true
	}
	return false
}

// same: a and b are the same type by the laws: equal normal forms. An unknown is
// only itself; a | is the same whatever the order of its alternatives.
same :: proc(k: ^Kernel, a, b: Type) -> bool {
	if a == nil || b == nil do return a == nil && b == nil
	switch x in a {
	case Set:
		y, ok := b.(Set)
		return ok && set_equal(x, y)
	case Poly:
		y, ok := b.(Poly)
		return ok && poly_equal(x, y)
	case ^Unknown:
		y, ok := b.(^Unknown)
		return ok && x == y
	case ^Apply:
		y, ok := b.(^Apply)
		if !ok || x.op != y.op || len(x.args) != len(y.args) do return false
		if x.op == .Or do return same_alternatives(k, x, y)
		if x.op == .Recur do return frame_same(k, x.args[0].(^Frame), y.args[0].(^Frame))
		for arg, i in x.args do if !same(k, arg, y.args[i]) do return false
		return true
	case ^Frame:
		y, ok := b.(^Frame)
		return ok && frame_same(k, x, y)
	case Invalid:
	}
	return false
}

same_alternatives :: proc(k: ^Kernel, a, b: ^Apply) -> bool {
	xs, ys := make([dynamic]Type), make([dynamic]Type)
	alternatives(a, &xs)
	alternatives(b, &ys)
	contains :: proc(k: ^Kernel, list: []Type, t: Type) -> bool {
		for u in list do if same(k, u, t) do return true
		return false
	}
	for x in xs do if !contains(k, ys[:], x) do return false
	for y in ys do if !contains(k, xs[:], y) do return false
	return true
}

alternatives :: proc(t: Type, out: ^[dynamic]Type) {
	if a, ok := t.(^Apply); ok && a.op == .Or {
		for arg in a.args do alternatives(arg, out)
		return
	}
	append(out, t)
}

// closed: t has no unknown: a constant, a scope whose bindings are closed, a |
// of closed types.
closed :: proc(k: ^Kernel, t: Type) -> bool {
	#partial switch v in t {
	case Set:
		return true
	case ^Frame:
		for s in frame_slots(k, v) {
			if binding_of(s).kind == .Expand && binding_of(s).value == nil do return false
			if !closed(k, slot_value(k, s)) do return false
		}
		return true
	case ^Apply:
		return v.op == .Or && closed(k, v.args[0]) && closed(k, v.args[1])
	}
	return false
}

// target_unknown: the unknown t is, when it is one.
target_unknown :: proc(t: Type) -> ^Unknown {
	#partial switch v in t {
	case ^Unknown:
		return v
	case Poly:
		if len(v.monos) == 1 && v.constant == 0 && v.denom == 1 && v.monos[0].coef == 1 && len(v.monos[0].vars) == 1 do return v.monos[0].vars[0]
	}
	return nil
}

// poly_normal: a polynomial without unknowns is its constant.
poly_normal :: proc(p: Poly) -> Type {
	if c, constant := poly_is_constant(p); constant do return set_of(c)
	return p
}

as_poly :: proc(t: Type) -> (Poly, bool) {
	#partial switch v in t {
	case Poly:
		return v, true
	case Set:
		n, single := ints_single(v.ints)
		if single && set_equal(v, set_of(n)) do return poly_constant(n), true
	}
	return {}, false
}
