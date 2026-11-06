package kernel

import syn "../syntax"
import "core:slice"

// THE KERNEL
//
// The type algebra of specs/types.md, and nothing else. A type is a term of its
// grammar (type.odin): the program as written is made of these terms, and the type
// of each is its normal form, given by orienting the laws (normal.odin, lattice.odin,
// arith.odin, in.odin, scope.odin, pattern.odin, recursion.odin, effect.odin). The
// check is `V in C = true` for every value of the unknowns (prove.odin): what the
// laws do not prove is refused.

Error_Kind :: enum u8 {
	Undefined_Identifier,
	Constraint_Mismatch, // `V in C` is not proven true
	Non_Exhaustive_Pattern, // a value of the target is not proven taken by a branch
	Invalid_Carve,
	Invalid_operator, // an operator on types not proven in a family it accepts
	Invalid_Range,
	Invalid_Property_Access, // `.x` on what has no x
	Invalid_Execute, // `!` on what is not a scope
	Infinite_Recursion, // a base case that comes back to itself
	Invalid_Emission, // an emission of what is not an event, or without a handler visible where it is written (§4.9)
	Invalid_Write, // `-<<` on what is not a resonant binding, or a value not in its color (§4.14)
	Unsupported, // a form this kernel does not build yet
}

Error :: struct {
	kind:    Error_Kind,
	message: string,
	span:    syn.Span,
}

Kernel :: struct {
	ast:        ^syn.Ast,
	errors:     [dynamic]Error,
	unknowns:   int, // the unknowns written: their ids
	effects:    int, // the effects written: their ids
	emissions:  int, // the emissions written: their ids
	answering:  [dynamic]^Binding, // the handlers whose run is being typed: one that answers itself again is an infinite recursion
	summed:     [dynamic]Summed,
	tupled:     [dynamic]Tupled, // the equations of an equation over a range of one of its fields (recursion.odin) // the equations of sums of an equation over one of its fields (recursion.odin)
	images:     [dynamic]Image, // the bounds of the calls of an equation, given once (recursion.odin)
	induced:    [dynamic]Induced, // whether the calls of an equation are in a set, proven once (in.odin)
	fields:     [dynamic]Field, // the colors of the fields of the scope of an equation, read once (rewrite.odin)
	plain:      map[rawptr]Plain, // what is known of a term over plain unknowns, once (rewrite.odin)
	read:       map[Read_Key]bool, // whether a node reads an unknown, once asked (rewrite.odin)
	valued:     map[rawptr]Type, // what a shared node may hold, once read (size.odin)
	generics:   [dynamic]Generic, // the solutions of equations where what is given is unknown, once (recursion.odin)
	equations:  [dynamic]^Call_Equation, // the equations calls read, where what they carve is unknown, once (recursion.odin)
	markers:    int, // the unknowns that stand for a hole while it is inferred
	pending:    [dynamic]^Scope, // the scopes reached, to check
	root:       ^Scope, // the file
	scratch:    [dynamic]Type, // what the laws gather, in an arena of its own (scratch.odin)
	interned:   ^Interned, // its shared terms (intern.odin)
	// what is being given — the bindings asked, the equations read, the bounds and
	// proofs under way: the hypotheses (§5.6) —, each one's mark toggled in and out
	// of it (given_toggled)
	state:      u64,
	// the same, by what each mark is about: an equation, by its scope; a binding; what
	// concerns no term it is apart
	marks:      map[rawptr]u64,
	apart:      u64,
	anchors:    map[rawptr][]rawptr, // what the image of a term holding calls depends on, once (rewrite.odin)
	images_in:  map[Image_Key]Image_Known, // the image of a term holding calls, in a state (rewrite.odin)
	readings:   map[Reading_Key]^Unknown, // the unknown that reads a quotient, a remainder, x [&] m, one for each node (rewrite.odin)
	rewrites:   map[Rewrite_Key]Type, // the operations rewritten within the rewrite under way (rewrite.odin)
	rewriting:  int, // the rewrites of operations under way
}

Given_Kind :: enum u64 {
	Binding, // a binding being given
	Read, // an equation read
	Deriving, // an equation being derived
	Bounds, // the bounds of a call being given
	Proof, // an induction under way
	Answering, // a handler answering
	Summed, // an equation of sums being made
	Tupled, // an equation of tuples being made
}

// given_toggled: what is being given gains, or loses, item: what the laws answer
// may differ (§5.6: a call whose equation is read is the hypothesis). The state is
// the sum, without carry, of the marks of what is given: the same hypotheses, the
// same state.
given_toggled :: proc(k: ^Kernel, kind: Given_Kind, item: rawptr, at := 0) {
	// what the mark is about: the scope of an equation, a binding, or no term
	about: rawptr
	#partial switch kind {
	case .Binding:
		about = item
	case .Read, .Deriving, .Bounds, .Proof:
		about = origin((^Call_Equation)(item).root)
	}
	x := u64(uintptr(item)) ~ (u64(kind) << 58) ~ (u64(at) * 0x9e3779b97f4a7c15)
	// splitmix64
	x = (x ~ (x >> 30)) * 0xbf58476d1ce4e5b9
	x = (x ~ (x >> 27)) * 0x94d049bb133111eb
	x ~= x >> 31
	k.state ~= x
	if about == nil do k.apart ~= x
	else do k.marks[about] ~= x
}

// read_equation: eq read, or no longer, at the values of a call (§5.6).
read_equation :: proc(k: ^Kernel, eq: ^Call_Equation, read: bool) {
	if eq.read == read do return
	eq.read = read
	given_toggled(k, .Read, eq)
}

// report: an error, once. What it concerns becomes Invalid, which stays silent.
report :: proc(k: ^Kernel, kind: Error_Kind, span: syn.Span, message: string) -> Type {
	e := Error{kind, message, span}
	if !slice.contains(k.errors[:], e) do append(&k.errors, e)
	return Invalid{}
}

// check: builds the file the AST writes as a scope, and checks it.
check :: proc(ast: ^syn.Ast) -> (k: Kernel) {
	k.ast = ast
	init_scratch(&k)
	// the terms it shares live as long as the kernel: what builds them from now on,
	// on this thread, builds them in its table
	k.interned = new(Interned)
	interned = k.interned
	k.root = build_program(&k)
	check_program(&k)
	return k
}

// run: parses the source, and checks it.
run :: proc(source: string) -> (k: Kernel, parsed: bool) {
	ast, ok := syn.parse(source)
	if !ok do return k, false
	return check(ast), true
}
