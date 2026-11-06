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
//
// A carve is a node too (§5.3): known by the scope it carves and the value it gives
// each binding it changes. Built twice, it is the same scope, whose bindings are
// typed once.

Shape :: enum u8 {
	Or,
	And,
	Not,
	Is,
	Range,
	Operation,
	Carve,
}

Key :: struct {
	shape:    Shape,
	op:       u8, // the operator of an operation; the family of a range
	children: []Type, // a carve: the scope it carves, then the values it gives
	changed:  []^Binding, // a carve: the bindings it changes, in their order
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
	if node := built_before(key); node != nil do return node
	node := build_node(key)
	put(key, node)
	return node
}

// built_before: the node of this key built before; nil when there is none.
built_before :: proc(key: Key) -> Type {
	if interned == nil do return nil
	table := interned
	if len(table.slots) == 0 do return nil
	mask := len(table.slots) - 1
	at := int(hash_key(key)) & mask
	for table.slots[at] != nil {
		if is_key(table.slots[at], key) do return table.slots[at]
		at = (at + 1) & mask
	}
	return nil
}

// put: node, new, under its key.
put :: proc(key: Key, node: Type) {
	if interned == nil do interned = new(Interned)
	table := interned
	if (table.count + 1) * 4 > len(table.slots) * 3 do grow(table)
	mask := len(table.slots) - 1
	at := int(hash_key(key)) & mask
	for table.slots[at] != nil do at = (at + 1) & mask
	table.slots[at] = node
	table.count += 1
}

// is_key: the node is the one of this key.
is_key :: proc(node: Type, key: Key) -> bool {
	if key.shape == .Carve {
		s, is_scope := node.(^Scope)
		if !is_scope || s.carved != key.children[0] || len(s.changes) != len(key.changed) do return false
		for b, i in key.changed {
			v, changed := s.changes[b]
			if !changed || v != key.children[i + 1] do return false
		}
		return true
	}
	room: [2]Type
	found, ok := key_of(node, &room)
	return ok && same_key(found, key)
}

grow :: proc(table: ^Interned) {
	old := table.slots
	table.slots = make([]Type, max(1024, 2 * len(old)))
	mask := len(table.slots) - 1
	room: [2]Type
	for t in old {
		if t == nil do continue
		key, is_term := key_of(t, &room)
		if !is_term do key = carve_key(t.(^Scope).carved, t.(^Scope).changes)
		at := int(hash_key(key)) & mask
		for table.slots[at] != nil do at = (at + 1) & mask
		table.slots[at] = t
	}
}

// carve_key: the key of the carve of root that gives these bindings these values.
carve_key :: proc(root: ^Scope, changes: map[^Binding]Type) -> Key {
	changed := in_order(changes)
	children := make([]Type, len(changed) + 1)
	children[0] = root
	for b, i in changed do children[i + 1] = changes[b]
	return {shape = .Carve, children = children, changed = changed}
}

// key_of: the key of a shared node; its children in the room given, for one that
// holds them one by one.
key_of :: proc(t: Type, room: ^[2]Type) -> (key: Key, ok: bool) {
	#partial switch v in t {
	case ^Or:
		return {shape = .Or, children = v.terms}, true
	case ^And:
		return {shape = .And, children = v.terms}, true
	case ^Not:
		room[0] = v.term
		return {shape = .Not, children = room[:1]}, true
	case ^Is:
		room[0] = v.term
		return {shape = .Is, children = room[:1]}, true
	case ^Range:
		room^ = {v.lo, v.hi}
		return {shape = .Range, op = u8(v.family), children = room[:]}, true
	case ^Operation:
		return {shape = .Operation, op = u8(v.op), children = v.args}, true
	}
	return {}, false
}

same_key :: proc(a, b: Key) -> bool {
	if a.shape != b.shape || a.op != b.op || len(a.children) != len(b.children) do return false
	for c, i in a.children do if c != b.children[i] do return false
	return true
}

// build_node: a new node of this key, its children its own. A carve is built by
// the kernel (carved_copy).
build_node :: proc(key: Key) -> Type {
	#partial switch key.shape {
	case .Or:
		o := new(Or)
		o.terms = clone_types(key.children)
		return o
	case .And:
		a := new(And)
		a.terms = clone_types(key.children)
		return a
	case .Not:
		n := new(Not)
		n.term = key.children[0]
		return n
	case .Is:
		i := new(Is)
		i.term = key.children[0]
		return i
	case .Range:
		r := new(Range)
		r.lo, r.hi, r.family = key.children[0], key.children[1], Range_Family(key.op)
		return r
	case .Operation:
		o := new(Operation)
		o.op, o.args = Operator(key.op), clone_types(key.children)
		return o
	}
	return nil
}

hash_key :: proc(key: Key) -> u64 {
	h := mix(u64(key.shape) << 8 | u64(key.op), 0)
	for c in key.children do h = mix(h, hash_term(c))
	for b in key.changed do h = mix(h, u64(uintptr(b)))
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
		return mix(mix(mix(3, u64(v.num) ~ u64(v.num >> 64)), u64(v.den) ~ u64(v.den >> 64)), u64(v.exp))
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
