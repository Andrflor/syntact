package kernel

// TYPES (specs/types.md §2)
//
// A type is a term of the algebra. In normal form it is a constant set, a scope
// value, or an operation of the algebra that no law reduces, applied to types in
// normal form. Every operation on types gives a type: `apply` (op.odin) builds
// the term an operation gives, by the laws of the spec.

Type :: union {
	Set, // a constant type (set.odin)
	Poly, // integer arithmetic on unknowns (poly.odin)
	^Unknown, // ?k::L (unknown.odin)
	^Apply, // an operation that no law reduces
	^Frame, // a scope (scope.odin)
	Invalid, // an error already reported: what depends on it stays silent
}

Invalid :: struct {}

is_invalid :: proc(t: Type) -> bool {
	_, ok := t.(Invalid)
	return ok
}

// Op: the operations of the algebra on types.
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
	// §4.3, with a bound that depends on unknowns: [lo, hi], [lo], [hi]
	Range,
	Range_From,
	Range_To,
	// §6: [target, cover, product, …], a nil cover for the default branch
	Match,
}

Apply :: struct {
	op:   Op,
	args: []Type,
}

new_apply :: proc(op: Op, args: ..Type) -> Type {
	a := new(Apply)
	a^ = Apply{op, clone_types(args)}
	return a
}

clone_types :: proc(ts: []Type) -> []Type {
	out := make([]Type, len(ts))
	copy(out, ts)
	return out
}

// TRUE, FALSE: the two booleans, as types.
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
