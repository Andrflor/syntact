package kernel

// `in` (specs/types.md §4.7)
//
// `x in c` is true when x is an element of c. It takes both arguments whole: it
// does not distribute over |. Its laws:
//
//   x in (a | b)  = (x in a) [|] (x in b)        x ≠ none
//   x in (a & b)  = (x in a) [&] (x in b)        x ≠ none
//   x in ~a       = [~](x in a)                  x ≠ none
//   x in =t       = true when x and t are equal, false when they are known and differ
//   x in p        = x in =p                      p a primitive
//   none in t     = false                        t ≠ none
//
// On a constant c the normal form decides at once: a primitive x is in c when c
// has it; none is in c only when c is none; a set taken as a value is in c only
// when c has it as an element (§5.4). What no law reduces stays `x in c`.

type_in :: proc(k: ^Kernel, x, c: Type) -> Type {
	if is_invalid(x) || is_invalid(c) do return Invalid{}
	xs, x_constant := x.(Set)
	cs, c_constant := c.(Set)
	if x_constant && c_constant do return set_bool(set_in(xs, cs))
	if c, is_frame := c.(^Frame); is_frame do return frame_admits(k, x, c)
	if _, is_frame := x.(^Frame); is_frame && c_constant do return set_bool(cs.scopes.all)
	if x_constant && set_is_none(xs) {
		if c_constant do return set_bool(set_is_none(cs))
	}
	if a, is_apply := c.(^Apply); is_apply && a.op == .Is do return type_equal(k, x, a.args[0])
	if !c_constant && is_atom(c) do return type_equal(k, x, c) // x in p = x in =p
	if a, is_apply := c.(^Apply); is_apply && !(x_constant && set_is_none(xs)) {
		#partial switch a.op {
		case .Or:
			return bool_operation(.Bit_Or, type_in(k, x, a.args[0]), type_in(k, x, a.args[1]))
		case .And:
			return bool_operation(.Bit_And, type_in(k, x, a.args[0]), type_in(k, x, a.args[1]))
		case .Not:
			return bool_operation(.Bit_Not, type_in(k, x, a.args[0]), nil)
		}
	}
	return new_apply(.In, x, c)
}

// type_equal: x in =t. True when x and t are equal by the laws, false when both
// are constant and differ.
type_equal :: proc(k: ^Kernel, x, t: Type) -> Type {
	if type_same(k, x, t) do return type_true()
	if known(k, x) && known(k, t) do return type_false() // two known values, not the same
	return new_apply(.In, x, new_apply(.Is, t))
}

// known: t has no unknown, and is in normal form: a constant, a scope whose
// bindings are known, or a | of known values.
known :: proc(k: ^Kernel, t: Type) -> bool {
	#partial switch v in t {
	case Set:
		return true
	case ^Apply:
		return v.op == .Or && known(k, v.args[0]) && known(k, v.args[1])
	case ^Frame:
		for s in frame_slots(k, v) {
			if binding_of(s).kind == .Expand && binding_of(s).value == nil do return false
			if !known(k, slot_value(k, s)) do return false
		}
		return true
	}
	return false
}

// set_in: x in c, both constant.
set_in :: proc(x, c: Set) -> bool {
	if set_is_none(x) do return set_is_none(c)
	if p, single := set_single(x); single do return set_has(c, p)
	return scopes_have_value(c.scopes, x)
}

// bool_operation: [|] [&] [~] on two booleans, by the laws of a Boolean algebra
// (§4.5): computed when both are known, simplified when one is.
bool_operation :: proc(op: Op, a, b: Type) -> Type {
	if is_invalid(a) || is_invalid(b) do return Invalid{}
	if op == .Bit_Not {
		if is_bool(a, true) do return type_false()
		if is_bool(a, false) do return type_true()
		if n, ok := a.(^Apply); ok && n.op == .Bit_Not do return n.args[0]
		return new_apply(.Bit_Not, a)
	}
	absorbing := op == .Bit_Or // true absorbs [|], false absorbs [&]
	if is_bool(a, absorbing) || is_bool(b, absorbing) do return set_bool(absorbing)
	if is_bool(a, !absorbing) do return b
	if is_bool(b, !absorbing) do return a
	return new_apply(op, a, b)
}
