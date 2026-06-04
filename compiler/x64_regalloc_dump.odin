package compiler

import "core:fmt"
import "core:strings"
import x64 "./backends/x64"

// regalloc_to_string annotates each bytecode instruction with the machine
// location its defined value landed in (a register or a stack slot) — a debug
// view of the linear-scan result, printed by --regalloc.
regalloc_to_string :: proc(prog: ^BC_Program, alloc: Reg_Alloc) -> string {
	sb := strings.builder_make()
	fmt.sbprintf(&sb, "; stack spill area: %d bytes\n", alloc.stack_size)
	for inst, pc in prog.insts {
		line := bc_inst_line(inst)
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

reg64_name :: proc(r: x64.Register64) -> string {
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

// bc_inst_line renders a single instruction WITHOUT the trailing newline, reused
// by the regalloc dump.
bc_inst_line :: proc(inst: BC_Inst) -> string {
	switch v in inst {
	case BC_Const:
		return fmt.tprintf("  v%d = const %d", int(v.dst), v.imm)
	case BC_Const_F:
		return fmt.tprintf("  v%d = constf %v", int(v.dst), v.fimm)
	case BC_Str_Const:
		return fmt.tprintf("  v%d = str .rodata[%d]", int(v.dst), v.id)
	case BC_Move:
		return fmt.tprintf("  v%d = move v%d", int(v.dst), int(v.src))
	case BC_Load_Arg:
		if v.width != 0 && v.width < 64 {
			return fmt.tprintf("  v%d = arg %d :%s%d", int(v.dst), v.slot, v.signed ? "i" : "u", v.width)
		}
		return fmt.tprintf("  v%d = arg %d", int(v.dst), v.slot)
	case BC_Bin:
		return fmt.tprintf("  v%d = %s v%d v%d", int(v.dst), op_symbol(v.op), int(v.a), int(v.b))
	case BC_Cmp:
		return fmt.tprintf("  v%d = cmp%s v%d v%d", int(v.dst), op_symbol(v.op), int(v.a), int(v.b))
	case BC_Label_Def:
		return fmt.tprintf("L%d:", int(v.label))
	case BC_Jump:
		return fmt.tprintf("  jmp L%d", int(v.target))
	case BC_Branch_Zero:
		return fmt.tprintf("  brz v%d L%d", int(v.cond), int(v.target))
	case BC_Ret:
		return fmt.tprintf("  ret v%d", int(v.src))
	}
	return ""
}
