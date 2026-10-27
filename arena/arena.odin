package arena

import "base:runtime"
import "core:mem"
import "core:mem/virtual"

// THE ARENA OF A COMPILE
//
// What a compile allocates lives as long as the compile: one range of virtual
// memory, reserved large and given by the system as it is first touched — in large
// pages, the range committed in large pieces. An allocation bumps the offset and is
// not zeroed: what is past the offset is zero, fresh or given back zeroed. Only the
// last allocation is reused — a resize extends it in place, a free gives it back —,
// the stack discipline of the parser's scratch; anything else is given back with the
// arena, at the end of the compile.

RESERVE :: 64 * mem.Gigabyte
COMMIT :: 256 * mem.Megabyte

Arena :: struct {
	memory:    []byte,
	offset:    int, // the first byte not given: past it, every byte is zero
	committed: int,
	last:      int, // where the last allocation starts; offset when there is none
}

init :: proc(a: ^Arena) -> runtime.Allocator_Error {
	a.memory = virtual.reserve(RESERVE) or_return
	a.offset, a.committed, a.last = 0, 0, 0
	return nil
}

allocator :: proc(a: ^Arena) -> runtime.Allocator {
	return runtime.Allocator{procedure = allocator_proc, data = a}
}

// give: size bytes past what is given, aligned on alignment; zero.
give :: proc(a: ^Arena, size, alignment: int) -> (out: []byte, err: runtime.Allocator_Error) {
	start := (a.offset + alignment - 1) & ~(alignment - 1)
	end := start + size
	if end > a.committed {
		if end > len(a.memory) do return nil, .Out_Of_Memory
		upto := min(len(a.memory), (end + COMMIT - 1) / COMMIT * COMMIT)
		virtual.commit(&a.memory[a.committed], uint(upto - a.committed)) or_return
		a.committed = upto
	}
	a.offset, a.last = end, start
	return a.memory[start:end], nil
}

// is_last: p is where the last allocation starts.
is_last :: proc(a: ^Arena, p: rawptr) -> bool {
	return a.last < a.offset && p == raw_data(a.memory[a.last:])
}

allocator_proc :: proc(data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int, old_memory: rawptr, old_size: int, loc := #caller_location) -> (out: []byte, err: runtime.Allocator_Error) {
	a := (^Arena)(data)
	switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		return give(a, size, alignment)
	case .Resize, .Resize_Non_Zeroed:
		if old_memory == nil do return give(a, size, alignment)
		if is_last(a, old_memory) {
			// the last allocation, extended or shrunk in place: what it leaves, zeroed
			if a.last + size < a.offset do mem.zero_slice(a.memory[a.last + size:a.offset])
			a.offset = a.last
			return give(a, size, 1)
		}
		out = give(a, size, alignment) or_return
		copy(out, ([^]byte)(old_memory)[:min(old_size, size)])
		return out, nil
	case .Free:
		// the last allocation is given back, zeroed; another, with the arena
		if is_last(a, old_memory) {
			mem.zero_slice(a.memory[a.last:a.offset])
			a.offset = a.last
		}
		return nil, nil
	case .Free_All:
		mem.zero_slice(a.memory[:a.offset])
		a.offset, a.last = 0, 0
		return nil, nil
	case .Query_Features:
		set := (^runtime.Allocator_Mode_Set)(old_memory)
		if set != nil do set^ = {.Alloc, .Alloc_Non_Zeroed, .Resize, .Resize_Non_Zeroed, .Free, .Free_All, .Query_Features}
		return nil, nil
	case .Query_Info:
		return nil, .Mode_Not_Implemented
	}
	return nil, nil
}
