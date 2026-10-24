package kernel

import syn "../compiler"
import "core:slice"

// THE KERNEL
//
// The type algebra of specs/types.md, and nothing else. The program, as written,
// is a scope (build.odin); each binding states an equation (scope.odin); the laws
// of the algebra put every type in normal form (op.odin, in.odin); the check asks
// whether `V in C` is true (check.odin).

Error_Kind :: enum u8 {
	Undefined_Identifier,
	Constraint_Mismatch, // a value that is not in its color
	Non_Exhaustive_Pattern,
	Invalid_Carve,
	Invalid_operator, // an operator on types not proven in a family it accepts
	Invalid_Range,
	Unproven, // the kernel cannot decide whether a value is in its color
	Unsupported, // a form this kernel does not build yet
}

Error :: struct {
	kind:    Error_Kind,
	message: string,
	span:    syn.Span,
}

Kernel :: struct {
	ast:    ^syn.Ast,
	errors: [dynamic]Error,
}

// report: an error, once; the type of what it concerns is Invalid.
report :: proc(k: ^Kernel, kind: Error_Kind, span: syn.Span, message: string) -> Type {
	e := Error{kind, message, span}
	if !slice.contains(k.errors[:], e) do append(&k.errors, e)
	return Invalid{}
}

// run: parses the source, builds the program and checks it. The program is the
// frame of the file, whose bindings carry their types.
run :: proc(source: string) -> (program: ^Frame, k: Kernel, parsed: bool) {
	words_reset()
	cache := new(syn.Cache)
	ast, ok := syn.parse(cache, source)
	if !ok do return nil, k, false
	k.ast = ast
	program = build_program(&k)
	check_frame(&k, program)
	return program, k, true
}
