package kernel

import syn "../compiler"
import "core:slice"

// THE KERNEL
//
// The type algebra of specs/types.md, and nothing else. A type is an equation:
// the expression itself, over unknowns that carry their domain. The laws of the
// algebra put it in normal form (law.odin, in.odin). A scope is a system of
// equations (scope.odin). The check proves `V in C` from what is known — the
// domains of the unknowns and what the patterns around prove (prove.odin). What
// is not proven is refused. Nothing is computed beside the laws: no search over
// values, no unfolding.

Error_Kind :: enum u8 {
	Undefined_Identifier,
	Constraint_Mismatch, // a value not proven in its color
	Non_Exhaustive_Pattern, // a value of the target not proven taken by a branch
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
	ast:       ^syn.Ast,
	errors:    [dynamic]Error,
	unknowns:  int, // the unknowns created: their ids
	literals:  map[[2]rawptr]^Frame, // the frame of each scope literal in each frame
	carves:    map[string]^Frame, // the frame of each carve, by source and arguments
	colored:   map[[2]rawptr]^Frame, // a scope value under the shape of its color
	admitting: map[string]bool, // the admissions being proven (scope.odin)
	pending:   [dynamic]^Frame, // the frames created, to check
	facts:     Facts, // what the patterns around prove, while a branch is typed
	site:      syn.Span, // the carve whose frame is checked: where its errors go
}

// report: an error, once; what it concerns is Invalid, and stays silent.
report :: proc(k: ^Kernel, kind: Error_Kind, span: syn.Span, message: string) -> Type {
	e := Error{kind, message, k.site != {} ? k.site : span}
	if !slice.contains(k.errors[:], e) do append(&k.errors, e)
	return Invalid{}
}

// run: parses the source, builds the program and checks it. The program is the
// frame of the file.
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
