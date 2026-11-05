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
	plain:      map[^Operation]Plain, // what is known of an operation over plain unknowns, once (rewrite.odin)
	read:       map[Read_Key]bool, // whether a node reads an unknown, once asked (rewrite.odin)
	valued:     map[rawptr]Type, // what a shared node may hold, once read (size.odin)
	generics:   [dynamic]Generic, // the solutions of equations where what is given is unknown, once (recursion.odin)
	equations:  [dynamic]^Call_Equation, // the equations calls read, where what they carve is unknown, once (recursion.odin)
	markers:    int, // the unknowns that stand for a hole while it is inferred
	pending:    [dynamic]^Scope, // the scopes reached, to check
	root:       ^Scope, // the file
	scratch:    [dynamic]Type, // what the laws gather, in an arena of its own (scratch.odin)
	interned:   ^Interned, // its shared terms (intern.odin)
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
