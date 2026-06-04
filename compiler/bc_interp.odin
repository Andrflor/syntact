package compiler

// ============================================================================
// BYTECODE INTERPRETER — the reference backend.
//
// The fastest way to validate the lowering (^Type → bytecode) in isolation,
// before any machine backend exists: execute the BC_Program directly over i64
// virtual registers. Every other backend (x64→ELF, arm64, wasm) must agree with
// this interpreter on every program. `args` supplies the ??N fixed points
// positionally (args[slot]), exactly as argv will at runtime.
// ============================================================================

BC_Interp_Result :: struct {
	value: i64,
	ok:    bool,
	error: string,
}

interp_bytecode :: proc(prog: ^BC_Program, args: []i64) -> BC_Interp_Result {
	if prog == nil do return {0, false, "no bytecode"}

	regs := make([]i64, prog.value_count)
	defer delete(regs)

	// Resolve labels to instruction indices for O(1) jumps.
	label_pc := make([]int, prog.label_count)
	defer delete(label_pc)
	for inst, pc in prog.insts {
		if def, is := inst.(BC_Label_Def); is {
			label_pc[int(def.label)] = pc
		}
	}

	pc := 0
	for pc < len(prog.insts) {
		switch v in prog.insts[pc] {
		case BC_Const:
			regs[int(v.dst)] = v.imm
		case BC_Load_Arg:
			regs[int(v.dst)] = v.slot < len(args) ? args[v.slot] : 0
		case BC_Bin:
			res, err := interp_bin(v.op, regs[int(v.a)], regs[int(v.b)])
			if err != "" do return {0, false, err}
			regs[int(v.dst)] = res
		case BC_Cmp:
			regs[int(v.dst)] = interp_cmp(v.op, regs[int(v.a)], regs[int(v.b)]) ? 1 : 0
		case BC_Label_Def:
		// no-op marker
		case BC_Jump:
			pc = label_pc[int(v.target)]
			continue
		case BC_Branch_Zero:
			if regs[int(v.cond)] == 0 {
				pc = label_pc[int(v.target)]
				continue
			}
		case BC_Ret:
			return {regs[int(v.src)], true, ""}
		}
		pc += 1
	}
	return {0, false, "fell off end without ret"}
}

interp_bin :: proc(op: Operator_Kind, a, b: i64) -> (i64, string) {
	#partial switch op {
	case .Add:
		return a + b, ""
	case .Subtract:
		return a - b, ""
	case .Multiply:
		return a * b, ""
	case .Divide:
		if b == 0 do return 0, "division by zero"
		return a / b, ""
	case .Mod:
		if b == 0 do return 0, "modulo by zero"
		return a % b, ""
	case .And, .BitAnd:
		return a & b, ""
	case .Or, .BitOr:
		return a | b, ""
	case .Xor:
		return a ~ b, ""
	case .LShift:
		return a << u64(b), ""
	case .RShift:
		return a >> u64(b), ""
	}
	return 0, "unsupported binary operator in bytecode interpreter"
}

interp_cmp :: proc(op: Operator_Kind, a, b: i64) -> bool {
	#partial switch op {
	case .Equal:
		return a == b
	case .NotEqual:
		return a != b
	case .Less:
		return a < b
	case .Greater:
		return a > b
	case .LessEqual:
		return a <= b
	case .GreaterEqual:
		return a >= b
	}
	return false
}
