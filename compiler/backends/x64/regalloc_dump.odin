package x64_assembler

import "core:fmt"
import "core:strings"
import bc "../../bytecode"

// regalloc_to_string annotates each bytecode instruction with the machine
// location its defined value landed in (a register or a stack slot) — a debug
// view of the linear-scan result, printed by --regalloc.
regalloc_to_string :: proc(prog: ^bc.BC_Program, alloc: Reg_Alloc) -> string {
	sb := strings.builder_make()
	fmt.sbprintf(&sb, "; stack spill area: %d bytes\n", alloc.stack_size)
	for inst, pc in prog.insts {
		line := bc.bc_inst_line(inst, prog)
		if d, ok := bc_def(inst); ok {
			fmt.sbprintf(&sb, "%-28s ; v%d -> %s\n", line, d, loc_to_string(alloc.locs[d]))
		} else {
			fmt.sbprintf(&sb, "%s\n", line)
		}
		_ = pc
	}
	return strings.to_string(sb)
}

loc_to_string :: proc(loc: VReg_Loc) -> string {
	switch loc.kind {
	case .Register:
		return reg64_name(loc.reg)
	case .Stack:
		return fmt.tprintf("[rbp-%d]", loc.offset)
	}
	return "?"
}

reg64_name :: proc(r: Register64) -> string {
	switch r {
	case .RAX: return "rax"
	case .RCX: return "rcx"
	case .RDX: return "rdx"
	case .RBX: return "rbx"
	case .RSP: return "rsp"
	case .RBP: return "rbp"
	case .RSI: return "rsi"
	case .RDI: return "rdi"
	case .R8:  return "r8"
	case .R9:  return "r9"
	case .R10: return "r10"
	case .R11: return "r11"
	case .R12: return "r12"
	case .R13: return "r13"
	case .R14: return "r14"
	case .R15: return "r15"
	}
	return "?"
}

