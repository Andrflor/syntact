package x64_assembler

import bc "../../bytecode"

// The only ABI understood by this backend. The assignment is kept separate
// from instruction emission so calls and named functions use the same layout.
X64_ABI_Class :: enum {
	Integer,
	SSE,
	Stack,
}

X64_ABI_Location :: struct {
	class:        X64_ABI_Class,
	register:     int,
	stack_offset: int,
}

X64_ABI_Assignment :: struct {
	locations:       []X64_ABI_Location,
	piece_locations: [][]X64_ABI_Location,
	integer_count:   int,
	sse_count:       int,
	stack_count:     int,
	stack_size:      int,
}

SYSV_INT_ARGS := [?]Register64{.RDI, .RSI, .RDX, .RCX, .R8, .R9}
SYSV_SSE_ARGS := [?]XMMRegister{.XMM0, .XMM1, .XMM2, .XMM3, .XMM4, .XMM5, .XMM6, .XMM7}
SYSV_INT_RET := [?]Register64{.RAX, .RDX}

x64_abi_align16 :: proc(size: int) -> int {
	return (size + 15) & ~int(15)
}

// Small aggregate arguments are assigned as one eightbyte group: if either
// register class is exhausted, the whole aggregate goes to the stack as SysV
// requires. MEMORY and explicit indirect aggregates retain their abstract-cell
// pointer lowering. A hidden sret consumes the first INTEGER argument.
x64_sysv_assign :: proc(
	types: []bc.Machine_Type,
	layouts: []bc.BC_Aggregate_Layout = nil,
	has_sret: bool = false,
) -> (X64_ABI_Assignment, string) {
	locations := make([]X64_ABI_Location, len(types))
	piece_locations := make([][]X64_ABI_Location, len(types))
	int_count, sse_count, stack_count := 0, 0, 0
	stack_offset := 0
	if has_sret do int_count = 1

	for mt, i in types {
		classes: [dynamic]X64_ABI_Class
		if i < len(layouts) && layouts[i].size > 0 {
			layout := layouts[i]
			if layout.memory || layout.indirect {
				append(&classes, X64_ABI_Class.Integer)
			} else {
				if len(layout.pieces) == 0 || len(layout.pieces) > 2 {
					delete(classes); delete(piece_locations); delete(locations)
					return {}, "x64 SysV ABI: aggregate has no supported register pieces"
				}
				for piece in layout.pieces {
					if piece.machine == .None || piece.size <= 0 || piece.size > 8 {
						delete(classes); delete(piece_locations); delete(locations)
						return {}, "x64 SysV ABI: aggregate piece has an invalid layout"
					}
					class := bc.mtype_is_float(piece.machine) ? X64_ABI_Class.SSE : X64_ABI_Class.Integer
					append(&classes, class)
				}
			}
		} else if mt == .None {
			delete(piece_locations); delete(locations)
			return {}, "x64 SysV ABI: argument has no machine type"
		} else if bc.mtype_is_float(mt) {
			append(&classes, X64_ABI_Class.SSE)
		} else if bc.mtype_is_int(mt) || mt == .Str {
			append(&classes, X64_ABI_Class.Integer)
		} else {
			delete(piece_locations); delete(locations)
			return {}, "x64 SysV ABI: unsupported argument machine type"
		}

		need_int, need_sse := 0, 0
		for class in classes {
			if class == .Integer {
				need_int += 1
			} else {
				need_sse += 1
			}
		}
		all_in_regs := int_count + need_int <= len(SYSV_INT_ARGS) && sse_count + need_sse <= len(SYSV_SSE_ARGS)
		parts := make([]X64_ABI_Location, len(classes))
		if all_in_regs {
			for class, piece in classes {
				if class == .Integer {
					parts[piece] = X64_ABI_Location{class = .Integer, register = int_count}
					int_count += 1
				} else {
					parts[piece] = X64_ABI_Location{class = .SSE, register = sse_count}
					sse_count += 1
				}
			}
		} else {
			for piece in 0 ..< len(classes) {
				parts[piece] = X64_ABI_Location{class = .Stack, stack_offset = stack_offset}
				stack_offset += 8
				stack_count += 1
			}
		}
		piece_locations[i] = parts
		locations[i] = parts[0]
		delete(classes)
	}

	return X64_ABI_Assignment{
		locations = locations,
		piece_locations = piece_locations,
		integer_count = int_count,
		sse_count = sse_count,
		stack_count = stack_count,
		stack_size = x64_abi_align16(stack_offset),
	}, ""
}
