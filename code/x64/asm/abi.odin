package x64_assembler

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
	locations:     []X64_ABI_Location,
	integer_count: int,
	sse_count:     int,
	stack_count:   int,
	stack_size:    int,
}

SYSV_INT_ARGS := [?]Register64{.RDI, .RSI, .RDX, .RCX, .R8, .R9}
SYSV_SSE_ARGS := [?]XMMRegister{.XMM0, .XMM1, .XMM2, .XMM3, .XMM4, .XMM5, .XMM6, .XMM7}
SYSV_INT_RET := [?]Register64{.RAX, .RDX}

x64_abi_align16 :: proc(size: int) -> int {
	return (size + 15) & ~int(15)
}

// x64_sysv_assign: the location of each argument, given its class — Integer or SSE
// for a value in a register, Stack for one passed in memory. The integer and SSE
// registers are taken in order, each sequence on its own; an argument whose
// sequence is exhausted goes on the stack, in eightbytes.
x64_sysv_assign :: proc(classes: []X64_ABI_Class) -> X64_ABI_Assignment {
	locations := make([]X64_ABI_Location, len(classes))
	int_count, sse_count, stack_count := 0, 0, 0
	stack_offset := 0
	for class, i in classes {
		switch {
		case class == .Integer && int_count < len(SYSV_INT_ARGS):
			locations[i] = X64_ABI_Location{class = .Integer, register = int_count}
			int_count += 1
		case class == .SSE && sse_count < len(SYSV_SSE_ARGS):
			locations[i] = X64_ABI_Location{class = .SSE, register = sse_count}
			sse_count += 1
		case:
			locations[i] = X64_ABI_Location{class = .Stack, stack_offset = stack_offset}
			stack_offset += 8
			stack_count += 1
		}
	}
	return X64_ABI_Assignment{
		locations = locations,
		integer_count = int_count,
		sse_count = sse_count,
		stack_count = stack_count,
		stack_size = x64_abi_align16(stack_offset),
	}
}
