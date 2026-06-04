package compiler

import "core:fmt"

// ============================================================================
// BYTECODE INTERPRETER — the reference backend.
//
// The fastest way to validate the lowering (^Type → bytecode) in isolation,
// before any machine backend exists: execute the BC_Program directly. Every
// other backend (x64→ELF, arm64, wasm) must agree with this interpreter on every
// program. `args` supplies the ??N fixed points positionally (args[slot]),
// exactly as argv will at runtime — an arg is a string (argv is strings), parsed
// to int or float per the consuming Load_Arg's domain.
//
// A virtual register holds a tagged value (int, float, or string pointer),
// because the bytecode now spans integer, float, and concrete-string domains.
// The arithmetic domain of an op is read from value_types[dst] (the Machine_Type
// the lowering attached), so the same BC_Bin does integer add vs float add.
// ============================================================================

BC_Val :: union {
	i64,
	f64,
	string,
}

BC_Interp_Result :: struct {
	value:  i64, // integer/bool result (exit-status channel)
	fvalue: f64, // float result
	svalue: string, // string result (written to stdout)
	rtype:  Machine_Type, // which of the above is meaningful
	ok:     bool,
	error:  string,
}

interp_bytecode :: proc(prog: ^BC_Program, args: []string) -> BC_Interp_Result {
	if prog == nil do return {ok = false, error = "no bytecode"}
	if prog.error != "" do return {ok = false, error = prog.error}

	regs := make([]BC_Val, prog.value_count)
	defer delete(regs)

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
		case BC_Const_F:
			regs[int(v.dst)] = v.fimm
		case BC_Str_Const:
			regs[int(v.dst)] = v.bytes
		case BC_Load_Arg:
			regs[int(v.dst)] = interp_load_arg(prog, v, args)
		case BC_Bin:
			dst_mt := prog.value_types[int(v.dst)]
			if mtype_is_float(dst_mt) {
				res, err := interp_bin_f(v.op, interp_f(regs[int(v.a)]), interp_f(regs[int(v.b)]))
				if err != "" do return {ok = false, error = err}
				regs[int(v.dst)] = res
			} else {
				res, err := interp_bin(v.op, interp_i(regs[int(v.a)]), interp_i(regs[int(v.b)]))
				if err != "" do return {ok = false, error = err}
				regs[int(v.dst)] = res
			}
		case BC_Cmp:
			// Compare in the operands' domain (float if either operand is float).
			if _, af := regs[int(v.a)].(f64); af {
				regs[int(v.dst)] = interp_cmp_f(v.op, interp_f(regs[int(v.a)]), interp_f(regs[int(v.b)])) ? i64(1) : i64(0)
			} else if _, bf := regs[int(v.b)].(f64); bf {
				regs[int(v.dst)] = interp_cmp_f(v.op, interp_f(regs[int(v.a)]), interp_f(regs[int(v.b)])) ? i64(1) : i64(0)
			} else {
				regs[int(v.dst)] = interp_cmp(v.op, interp_i(regs[int(v.a)]), interp_i(regs[int(v.b)])) ? i64(1) : i64(0)
			}
		case BC_Move:
			regs[int(v.dst)] = regs[int(v.src)]
		case BC_Label_Def:
		// no-op marker
		case BC_Jump:
			pc = label_pc[int(v.target)]
			continue
		case BC_Branch_Zero:
			if interp_i(regs[int(v.cond)]) == 0 {
				pc = label_pc[int(v.target)]
				continue
			}
		case BC_Ret:
			return interp_result(prog, regs[int(v.src)])
		}
		pc += 1
	}
	return {ok = false, error = "fell off end without ret"}
}

// interp_load_arg materializes a ??N from argv[slot] in the domain the Load_Arg
// declares: a float ?? parses to f64, an integer ?? parses to i64 and is then
// normalized (masked/sign-extended) by the bytecode that follows it.
interp_load_arg :: proc(prog: ^BC_Program, v: BC_Load_Arg, args: []string) -> BC_Val {
	raw := v.slot < len(args) ? args[v.slot] : ""
	mt := prog.value_types[int(v.dst)]
	if mtype_is_float(mt) {
		return interp_parse_f64(raw)
	}
	return interp_parse_i64(raw)
}

// print_interp_result renders the interpreter's result on the right channel:
// a string is written verbatim (stdout), a float as a decimal, an integer plain.
print_interp_result :: proc(r: BC_Interp_Result) {
	if r.rtype == .Str {
		fmt.println(r.svalue)
		return
	}
	if mtype_is_float(r.rtype) {
		fmt.println(float_display(r.fvalue))
		return
	}
	fmt.println(r.value)
}

interp_result :: proc(prog: ^BC_Program, val: BC_Val) -> BC_Interp_Result {
	switch r in val {
	case i64:
		return {value = r, rtype = prog.result_type, ok = true}
	case f64:
		return {fvalue = r, rtype = prog.result_type, ok = true}
	case string:
		return {svalue = r, rtype = .Str, ok = true}
	}
	return {ok = true, rtype = prog.result_type}
}

// --- coercions -------------------------------------------------------------

interp_i :: proc(v: BC_Val) -> i64 {
	switch x in v {
	case i64:
		return x
	case f64:
		return i64(x)
	case string:
		return 0
	}
	return 0
}

interp_f :: proc(v: BC_Val) -> f64 {
	switch x in v {
	case i64:
		return f64(x)
	case f64:
		return x
	case string:
		return 0
	}
	return 0
}

// --- argv parsing (mirrors the runtime prologue's atoi/atof) ----------------

interp_parse_i64 :: proc(s: string) -> i64 {
	acc: i64 = 0
	neg := false
	i := 0
	if len(s) > 0 && (s[0] == '-' || s[0] == '+') {
		neg = s[0] == '-'
		i = 1
	}
	for ; i < len(s); i += 1 {
		c := s[i]
		if c < '0' || c > '9' do break
		acc = acc * 10 + i64(c - '0')
	}
	return neg ? -acc : acc
}

interp_parse_f64 :: proc(s: string) -> f64 {
	// Integer part, optional fraction. Minimal; mirrors a small runtime atof.
	whole: f64 = 0
	frac: f64 = 0
	scale: f64 = 1
	neg := false
	i := 0
	if len(s) > 0 && (s[0] == '-' || s[0] == '+') {
		neg = s[0] == '-'
		i = 1
	}
	for ; i < len(s); i += 1 {
		c := s[i]
		if c < '0' || c > '9' do break
		whole = whole * 10 + f64(c - '0')
	}
	if i < len(s) && s[i] == '.' {
		i += 1
		for ; i < len(s); i += 1 {
			c := s[i]
			if c < '0' || c > '9' do break
			scale *= 10
			frac = frac * 10 + f64(c - '0')
		}
	}
	r := whole + frac / scale
	return neg ? -r : r
}

// --- integer ops -----------------------------------------------------------

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
	return 0, "unsupported integer binary operator in bytecode interpreter"
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

// --- float ops -------------------------------------------------------------

interp_bin_f :: proc(op: Operator_Kind, a, b: f64) -> (f64, string) {
	#partial switch op {
	case .Add:
		return a + b, ""
	case .Subtract:
		return a - b, ""
	case .Multiply:
		return a * b, ""
	case .Divide:
		return a / b, "" // IEEE: x/0 = ±inf/nan, no trap
	}
	return 0, "unsupported float binary operator in bytecode interpreter"
}

interp_cmp_f :: proc(op: Operator_Kind, a, b: f64) -> bool {
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
