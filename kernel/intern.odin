package kernel

// SHARED TERMS
//
// A term of the algebra built twice is the same node — hash-consing —: a law that
// builds a term it built before finds that node, in normal form already when it
// was put in it, and `same` sees the identity of the nodes. A node is known by its
// form, its operator — or the family of a range —, and its children, each the very
// term it holds: a child is shared too, or a node of its own (an unknown, a scope,
// a term written in the source). A term is not changed once built; a term written
// in the source, which holds where it is, is a node of its own (written).

Shape :: enum u8 {
	Or,
	And,
	Not,
	Is,
	Range,
	Operation,
}

Key :: struct {
	shape:    Shape,
	op:       u8, // the operator of an operation; the family of a range
	children: []Type,
}

// Interned: the shared nodes, by their keys, in an open table: nil is an empty slot.
// A kernel has its own, which lives as long as the nodes it holds (check).
Interned :: struct {
	slots: []Type,
	count: int,
}

// the table of the kernel at work on this thread; another one for what is built
// out of a kernel, as the constants are
@(thread_local)
interned: ^Interned

// intern: the node of this key: the one built before, or a new one.
intern :: proc(key: Key) -> Type {
	if interned == nil do interned = new(Interned)
	table := interned
	if (table.count + 1) * 4 > len(table.slots) * 3 do grow(table)
	mask := len(table.slots) - 1
	at := int(hash_key(key)) & mask
	room: [2]Type
	for table.slots[at] != nil {
		if found, ok := key_of(table.slots[at], &room); ok && same_key(found, key) do return table.slots[at]
		at = (at + 1) & mask
	}
	node := build_node(key)
	table.slots[at] = node
	table.count += 1
	return node
}

grow :: proc(table: ^Interned) {
	old := table.slots
	table.slots = make([]Type, max(1024, 2 * len(old)))
	mask := len(table.slots) - 1
	room: [2]Type
	for t in old {
		if t == nil do continue
		key, _ := key_of(t, &room)
		at := int(hash_key(key)) & mask
		for table.slots[at] != nil do at = (at + 1) & mask
		table.slots[at] = t
	}
}

// key_of: the key of a shared node; its children in the room given, for one that
// holds them one by one.
key_of :: proc(t: Type, room: ^[2]Type) -> (key: Key, ok: bool) {
	#partial switch v in t {
	case ^Or:
		return {.Or, 0, v.terms}, true
	case ^And:
		return {.And, 0, v.terms}, true
	case ^Not:
		room[0] = v.term
		return {.Not, 0, room[:1]}, true
	case ^Is:
		room[0] = v.term
		return {.Is, 0, room[:1]}, true
	case ^Range:
		room^ = {v.lo, v.hi}
		return {.Range, u8(v.family), room[:]}, true
	case ^Operation:
		return {.Operation, u8(v.op), v.args}, true
	}
	return {}, false
}

same_key :: proc(a, b: Key) -> bool {
	if a.shape != b.shape || a.op != b.op || len(a.children) != len(b.children) do return false
	for c, i in a.children do if c != b.children[i] do return false
	return true
}

// build_node: a new node of this key, its children its own.
build_node :: proc(key: Key) -> Type {
	closed := true
	for c in key.children do closed &&= is_closed(c)
	switch key.shape {
	case .Or:
		o := new(Or)
		o.terms, o.closed = clone_types(key.children), closed
		return o
	case .And:
		a := new(And)
		a.terms, a.closed = clone_types(key.children), closed
		return a
	case .Not:
		n := new(Not)
		n.term, n.closed = key.children[0], closed
		return n
	case .Is:
		i := new(Is)
		i.term, i.closed = key.children[0], closed
		return i
	case .Range:
		r := new(Range)
		r.lo, r.hi, r.family, r.closed = key.children[0], key.children[1], Range_Family(key.op), closed
		return r
	case .Operation:
		o := new(Operation)
		o.op, o.args, o.closed = Operator(key.op), clone_types(key.children), closed
		return o
	}
	return nil
}

// is_closed: a child whose normal form is its own wherever it is asked: a value, an
// unknown — but what a recursive call gives back, known as its equation is solved —,
// a closed node; a name is not, its normal form is its binding's, being typed.
is_closed :: proc(t: Type) -> bool {
	#partial switch v in t {
	case nil, Char, Int, Real, Bool, None, Invalid:
		return true
	case ^Unknown:
		return v.call == nil
	case ^Or:
		return v.closed
	case ^And:
		return v.closed
	case ^Not:
		return v.closed
	case ^Is:
		return v.closed
	case ^Range:
		return v.closed
	case ^Operation:
		return v.closed
	}
	return false
}

hash_key :: proc(key: Key) -> u64 {
	h := mix(u64(key.shape) << 8 | u64(key.op), 0)
	for c in key.children do h = mix(h, hash_term(c))
	return h
}

// hash_term: a child as the very term it is: a value by its value, a node by where
// it is.
hash_term :: proc(t: Type) -> u64 {
	switch v in t {
	case nil:
		return 0
	case Char:
		return mix(1, u64(v))
	case Int:
		return mix(mix(2, u64(i128(v))), u64(i128(v) >> 64))
	case Real:
		return mix(mix(3, u64(v.num) ~ u64(v.num >> 64)), u64(v.den) ~ u64(v.den >> 64))
	case Bool:
		return mix(4, u64(v))
	case None:
		return 5
	case Invalid:
		return mix(6, u64(uintptr(v.problem)))
	case ^Unknown, ^Effect, ^Or, ^And, ^Not, ^Is, ^Range, ^Operation, ^Name, ^Scope, ^Access, ^Collapse, ^Carve, ^Default, ^Pattern, ^Fold, ^Least, ^Series, ^Recurrent:
		// a node: the address it holds, first in the union
		t := t
		return mix(7, u64((^uintptr)(&t)^))
	}
	return 0
}

mix :: #force_inline proc(h, x: u64) -> u64 {
	return (h ~ x) * 0x100000001b3 ~ (h >> 29)
}
