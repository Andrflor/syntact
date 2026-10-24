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
	Invalid_Property_Access, // `.x` on what has no x
	Invalid_Execute, // `!` on what is not a scope
	Infinite_Recursion, // a type that comes back to itself without progress: a base case that recurses
	Unproven, // the kernel cannot decide whether a value is in its color
	Unsupported, // a form this kernel does not build yet
}

Error :: struct {
	kind:    Error_Kind,
	message: string,
	span:    syn.Span,
}

Kernel :: struct {
	ast:       ^syn.Ast,
	errors:    [dynamic]Error,
	unknowns:  int, // the count of unknowns created: their ids
	literals:  map[[2]rawptr]^Frame, // the frame of each scope literal, in each frame
	carves:    map[string]^Frame, // the frame of each carve, by its source and arguments
	admitting: map[string]bool, // the admissions in progress (scope.odin)
	pending:   [dynamic]^Frame, // the frames created, to check
	quiet:     int, // > 0: errors are not reported, only noted
	hushed:    bool, // an error happened while quiet
	site:      syn.Span, // the carve whose frame is being checked: its errors go there
	colored:   map[[2]rawptr]^Frame, // a scope value under the shape of its color
	depth:     int, // the bindings being typed, one inside the other
}

// report: an error, once, at the carve being checked if any; the type of what it
// concerns is Invalid.
report :: proc(k: ^Kernel, kind: Error_Kind, span: syn.Span, message: string) -> Type {
	if k.quiet > 0 {
		k.hushed = true
		return Invalid{}
	}
	e := Error{kind, message, k.site != {} ? k.site : span}
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
	for i := 0; i < len(k.pending); i += 1 do check_frame(&k, k.pending[i])
	return program, k, true
}
