package code_calc

import code ".."
import "core:hash"
import "core:mem"

// THE ALGEBRA OF COMPUTATIONS
//
// The kernel says what a program computes: the normal form of its type, which the
// code (code/) reads as instructions. Many computations give that same value; this
// is their algebra, the second, over the first. Its objects are computations — the
// operations of a machine, matches, loops, effects —; its equations are the laws
// (laws.odin), each under the facts the kernel proved; a class holds the
// computations of one value, and the normal form of a class is its computation of
// least cost on a machine (extract.odin): cost is a homomorphism into the tropical
// semiring, min over the computations of a class, + along a computation.
//
// The classes are an e-graph: a node is an operation on classes, hash-consed; a law
// adds nodes and merges classes and never removes one, so that no law comes before
// another. The facts of a class — its machine, its bounds, its constant — hold for
// each of its computations: merging two classes meets them.
//
// A match is a node on its target and on what each of its arms gives, a loop a node
// on what its parameters start from and on the tail of its body: an Again of what
// they take next, an Exit of what the loop gives, or a match of tails. A parameter
// of a loop, and the arm a narrowing is read in, are leaves of their own. The
// effects are ordered by a state each takes and gives back — the state the function
// starts in, an arm starts in, a turn of a loop starts in —; a pure computation takes
// none, and goes where its uses need it, out of the loops it does not read
// (place.odin).

Class :: distinct int

NO_CLASS :: Class(-1)

Kind :: enum u8 {
	Int, // value: the integer
	Real, // value: the bits of the float
	Text, // index: the text of the program
	Input, // index: the input of the program
	Argument, // index: the parameter of the function
	Start, // the state the function starts in
	Param, // owner: the loop; index: its parameter, in this turn — the last its state, when it has effects
	Arm, // owner: the match; index: the arm — the state the arm starts in, and what it narrows in
	Unary, // op a
	Binary, // a op b
	In, // index: the cover; x in it, 1 or 0
	Narrow, // x as the arm it is read in narrows it; the arm
	Foreign, // index: the symbol; the state, then the arguments — gives the state after, and the answer
	Call, // index: the function; its arguments, after the state when it has effects — then gives the state after, and the answer
	Match, // owner: the match; the target, the state when its arms have effects, then what each arm gives
	Loop, // owner: the loop; what each parameter starts from, then the tail of its body
	Again, // owner: the loop; what each parameter takes next
	Exit, // owner: the loop; what it gives: its value, its state
	Get, // index: one of what a node gives
}

Node :: struct {
	kind:  Kind,
	op:    code.Op,
	value: i64,
	index: int,
	owner: int,
	args:  []Class,
}

// Region: where a computation runs: the function, an arm of a match, the body of a
// loop.
Region_Kind :: enum u8 {
	Root,
	Arm,
	Body,
}

Region :: struct {
	kind:  Region_Kind,
	owner: int,
	arm:   int,
}

ROOT :: Region{}

// Match_Info: a match: the region it runs in, the cover of each arm, and what each
// arm gives: a value, the state after its effects — or, in the body of a loop, a
// tail.
Match_Info :: struct {
	parent: Region,
	covers: []code.Cover,
	value:  bool,
	state:  bool,
	tail:   bool,
}

// Loop_Info: a loop: the region it runs in, its node, the machine of each parameter
// by its index — the state's None —, the index of the state, -1 when its body has
// no effects, how a law carries each parameter — what each turn does to it; nil
// for the loop's own —, and whether it gives a value.
Loop_Info :: struct {
	parent:   Region,
	node:     int,
	machines: [dynamic]code.Machine,
	state:    int,
	carried:  [dynamic]Maybe(code.Op),
	value:    bool,
}

// Facts: what holds of every computation of a class.
Facts :: struct {
	machine:  code.Machine,
	bounds:   code.Bounds,
	constant: Maybe(i64),
}

Graph :: struct {
	prog:    ^code.Program,
	func:    ^code.Func,
	nodes:   [dynamic]Node,
	home:    [dynamic]Class, // the class each node was added to
	parent:  [dynamic]Class, // per class: the class it was merged into, or itself
	facts:   [dynamic]Facts, // per class, kept on the class merged into
	table:   map[u64][dynamic]int, // the nodes, by their hash
	covers:  [dynamic]code.Cover,
	matches: [dynamic]Match_Info,
	loops:   [dynamic]Loop_Info,
	merges:  int, // how many merges were made
	members: [][dynamic]int, // per class: its nodes, as they were when the laws last looked
	scope:   []Maybe(Region), // per class: where it is defined, then
}

find :: proc(g: ^Graph, c: Class) -> Class {
	c := c
	for g.parent[c] != c {
		g.parent[c] = g.parent[g.parent[c]]
		c = g.parent[c]
	}
	return c
}

// add: the class of a node: the class of an equal node already there, or a new one.
add :: proc(g: ^Graph, n: Node) -> Class {
	n := n
	args := make([]Class, len(n.args))
	for a, i in n.args do args[i] = find(g, a)
	n.args = args
	if id, found := lookup(g, n); found do return find(g, g.home[id])
	c := Class(len(g.parent))
	append(&g.parent, c)
	append(&g.facts, derive(g, n))
	append(&g.home, c)
	append(&g.nodes, n)
	index(g, n, len(g.nodes) - 1)
	return c
}

// index: the node id, n, in the table.
index :: proc(g: ^Graph, n: Node, id: int) {
	h := hash_node(n)
	if h not_in g.table do g.table[h] = make([dynamic]int)
	append(&g.table[h], id)
}

// lookup: the node equal to n, its arguments canonical.
lookup :: proc(g: ^Graph, n: Node) -> (int, bool) {
	if bucket, found := g.table[hash_node(n)]; found {
		for id in bucket do if same_node(g, g.nodes[id], n) do return id, true
	}
	return -1, false
}

// merge: a and b are one value: their classes, one class, its facts both's.
merge :: proc(g: ^Graph, a, b: Class) -> Class {
	a, b := find(g, a), find(g, b)
	if a == b do return a
	g.parent[b] = a
	g.facts[a] = meet(g.facts[a], g.facts[b])
	g.merges += 1
	return a
}

// rebuild: the nodes made canonical again after merges; two that became equal merge
// their classes, until none do.
rebuild :: proc(g: ^Graph) {
	for {
		merged := false
		for _, bucket in g.table do delete(bucket)
		clear(&g.table)
		for &n, id in g.nodes {
			for &a in n.args do a = find(g, a)
			if other, found := lookup(g, n); found {
				if find(g, g.home[other]) != find(g, g.home[id]) {
					merge(g, g.home[other], g.home[id])
					merged = true
				}
			}
			index(g, n, id)
		}
		if !merged do return
	}
}

// index_members: the nodes of each class, from the canonical classes.
index_members :: proc(g: ^Graph) {
	g.members = make([][dynamic]int, len(g.parent))
	for _, id in g.nodes do append(&g.members[find(g, g.home[id])], id)
}

hash_node :: proc(n: Node) -> u64 {
	key := [5]i64{i64(n.kind), i64(n.op), n.value, i64(n.index), i64(n.owner)}
	h := hash.fnv64a(mem.slice_to_bytes(key[:]))
	if len(n.args) > 0 do h = hash.fnv64a(mem.slice_to_bytes(n.args), h)
	return h
}

same_node :: proc(g: ^Graph, a, b: Node) -> bool {
	if a.kind != b.kind || a.op != b.op || a.value != b.value || a.index != b.index || a.owner != b.owner || len(a.args) != len(b.args) do return false
	for x, i in a.args do if find(g, x) != find(g, b.args[i]) do return false
	return true
}

// observe: the facts the code gives a value, which hold of its class.
observe :: proc(g: ^Graph, c: Class, kind: code.Kind) {
	c := find(g, c)
	g.facts[c] = meet(g.facts[c], Facts{machine = kind.machine, bounds = kind.machine == .Int ? kind.bounds : code.EVERY})
}

meet :: proc(a, b: Facts) -> Facts {
	out := a
	if out.machine == .None do out.machine = b.machine
	out.bounds = code.meet(a.bounds, b.bounds)
	if out.constant == nil do out.constant = b.constant
	return out
}
