package kernel

import arena "../arena"
import "core:mem"

// THE SCRATCH
//
// What a law gathers to build a term, it gathers on one stack, as the parser gathers
// the children of a node: from a mark, it pushes, and what it gives back is what it
// pushed — a slice of the stack, its result moved down to its mark —; the term it
// builds copies what it keeps, once, at its size; the stack is given back to the
// mark. The stack lives alone in its own arena: it grows in place and never moves,
// so what a law reads of it stays where it is while the laws it calls push above.

SCRATCH_RESERVE :: 4 * mem.Gigabyte

// init_scratch: the scratch of k, in an arena of its own.
init_scratch :: proc(k: ^Kernel) {
	region := new(arena.Arena)
	if arena.init(region, SCRATCH_RESERVE) != nil do panic("no memory for the scratch of the kernel")
	k.scratch = make([dynamic]Type, arena.allocator(region))
}

// mark: the top of the scratch.
mark :: #force_inline proc(k: ^Kernel) -> int {
	return len(k.scratch)
}

push :: #force_inline proc(k: ^Kernel, t: Type) {
	append(&k.scratch, t)
}

push_all :: #force_inline proc(k: ^Kernel, ts: []Type) {
	append(&k.scratch, ..ts)
}

// pushed: what was pushed from the mark.
pushed :: #force_inline proc(k: ^Kernel, from: int) -> []Type {
	return k.scratch[from:]
}

// sink: result, which was pushed above the mark, moved down to it: what is left from
// the mark is the result.
sink :: proc(k: ^Kernel, from: int, result: []Type) -> []Type {
	n := len(result)
	if n > 0 && raw_data(result) != raw_data(k.scratch[from:]) {
		if len(k.scratch) < from + n do resize(&k.scratch, from + n)
		copy(k.scratch[from:from + n], result)
	}
	resize(&k.scratch, from + n)
	return k.scratch[from:]
}

// release: the scratch given back to the mark.
release :: #force_inline proc(k: ^Kernel, from: int) {
	resize(&k.scratch, from)
}
