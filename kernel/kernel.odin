package kernel

import syn "../compiler"
import "core:slice"

// THE KERNEL
//
// The type algebra of specs/types.md, and nothing else. A type is a term of its
// grammar (type.odin): the program as written is made of these terms, and the type
// of each is its normal form, given by orienting the laws (normal.odin, set.odin,
// arith.odin, in.odin, scope.odin, pattern.odin, recursion.odin). The check is
// `V in C = true` for every value of the unknowns (prove.odin): what the laws do
// not prove is refused.

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
	rewrite:    Rewrite, // the unknowns the branches around rewrite (rewrite.odin)
	site:       syn.Span, // the carve being checked: where its errors go
	pending:    [dynamic]^Scope, // the scopes reached, to check
	root:       ^Scope, // the file
}

// report: an error, once. What it concerns becomes Invalid, which stays silent.
report :: proc(k: ^Kernel, kind: Error_Kind, span: syn.Span, message: string) -> Type {
	e := Error{kind, message, k.site != {} ? k.site : span}
	if !slice.contains(k.errors[:], e) do append(&k.errors, e)
	return Invalid{}
}

// run: parses the source, builds the file as a scope and checks it.
run :: proc(source: string) -> (k: Kernel, parsed: bool) {
	cache := new(syn.Cache)
	ast, ok := syn.parse(cache, source)
	if !ok do return k, false
	k.ast = ast
	k.root = build_program(&k)
	check_program(&k)
	return k, true
}
