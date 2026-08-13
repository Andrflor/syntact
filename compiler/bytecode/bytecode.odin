package bytecode

import "core:fmt"
import "core:strings"

// ============================================================================
// BYTECODE — the target-neutral bridge between the reducer and every backend.
//
// This package is NEUTRAL: it depends on nothing in the compiler. It defines the
// bytecode (SSA-like virtual registers, instructions, the Program container), an
// operator enum (BC_Op) of its own so it needn't know the compiler's AST, the
// Machine_Type lattice, and the reference interpreter. Every backend (x64,
// future aarch64/wasm) imports THIS package and consumes a BC_Program.
//
// The LOWERING (^Type → BC_Program) lives in the `compiler` package, not here:
// it is the one part that must know both worlds (the reducer's IR and this
// bytecode), so it stays with the compiler and translates Operator_Kind → BC_Op.
// ============================================================================

// A virtual register: v0, v1, … — SSA, assigned exactly once.
BC_Value :: distinct int

BC_INVALID_VALUE :: BC_Value(-1)

// A function identity is dense and local to one BC_Program. Keeping the identity
// separate from its printable name lets calls remain compact while dumps and
// later object writers retain a stable binding name.
Func_Id :: distinct int

BC_INVALID_FUNC :: Func_Id(-1)

// A jump target inside the instruction stream.
BC_Label :: distinct int

// A scratch slot is an abstract, function-local storage location. Backends lay
// slots out in a frame or image tail; no machine address is exposed to lowering.
BC_Scratch_Id :: distinct int

BC_INVALID_SCRATCH :: BC_Scratch_Id(-1)

// BC_Op is the bytecode's OWN operator set, so the package doesn't depend on the
// compiler's Operator_Kind. The lowering maps one to the other.
BC_Op :: enum u8 {
	Add,
	Subtract,
	Multiply,
	Divide,
	Mod,
	BitAnd,
	BitOr,
	BitXor,
	LShift,
	RShift,
	Equal,
	NotEqual,
	Less,
	Greater,
	LessEqual,
	GreaterEqual,
}

bc_op_is_comparison :: proc(op: BC_Op) -> bool {
	#partial switch op {
	case .Equal, .NotEqual, .Less, .Greater, .LessEqual, .GreaterEqual:
		return true
	}
	return false
}

bc_op_symbol :: proc(op: BC_Op) -> string {
	switch op {
	case .Add:          return "+"
	case .Subtract:     return "-"
	case .Multiply:     return "*"
	case .Divide:       return "/"
	case .Mod:          return "%"
	case .BitAnd:       return "&"
	case .BitOr:        return "|"
	case .BitXor:       return "^"
	case .LShift:       return "<<"
	case .RShift:       return ">>"
	case .Equal:        return "=="
	case .NotEqual:     return "!="
	case .Less:         return "<"
	case .Greater:      return ">"
	case .LessEqual:    return "<="
	case .GreaterEqual: return ">="
	}
	return "?"
}

// ----------------------------------------------------------------------------
// Machine_Type — the EXACT machine domain+width of a value. Syntact fixes this
// semantically (structural coloring), so the bytecode PRESERVES it: a u8 stays
// U8, f32 vs f64 follow declared precision. Constants are NEUTRAL (no type) and
// fold to immediates at the backend.
// ----------------------------------------------------------------------------

Machine_Type :: enum u8 {
	None, // not codegen-able (symbolic string, unsized domain) → reject
	U8,
	I8,
	U16,
	I16,
	U32,
	I32,
	U64,
	I64,
	F32,
	F64,
	Str, // concrete string (pointer into .rodata), length tracked separately
}

mtype_is_float :: proc(m: Machine_Type) -> bool {
	return m == .F32 || m == .F64
}

mtype_is_int :: proc(m: Machine_Type) -> bool {
	#partial switch m {
	case .U8, .I8, .U16, .I16, .U32, .I32, .U64, .I64:
		return true
	}
	return false
}

mtype_bits :: proc(m: Machine_Type) -> uint {
	#partial switch m {
	case .U8, .I8:
		return 8
	case .U16, .I16:
		return 16
	case .U32, .I32, .F32:
		return 32
	case .U64, .I64, .F64:
		return 64
	}
	return 0
}

mtype_signed :: proc(m: Machine_Type) -> bool {
	#partial switch m {
	case .I8, .I16, .I32, .I64:
		return true
	}
	return false
}

mtype_name :: proc(m: Machine_Type) -> string {
	switch m {
	case .None: return "none"
	case .U8:   return "u8"
	case .I8:   return "i8"
	case .U16:  return "u16"
	case .I16:  return "i16"
	case .U32:  return "u32"
	case .I32:  return "i32"
	case .U64:  return "u64"
	case .I64:  return "i64"
	case .F32:  return "f32"
	case .F64:  return "f64"
	case .Str:  return "str"
	}
	return "?"
}

mtype_from_layout :: proc(bits: uint, signed: bool) -> Machine_Type {
	switch bits {
	case 8:
		return signed ? .I8 : .U8
	case 16:
		return signed ? .I16 : .U16
	case 32:
		return signed ? .I32 : .U32
	case 64:
		return signed ? .I64 : .U64
	}
	return .I64
}

mtype_for_int_value :: proc(x: i64) -> Machine_Type {
	if x >= 0 {
		switch {
		case x <= 255:        return .U8
		case x <= 65535:      return .U16
		case x <= 4294967295: return .U32
		}
		return .I64
	}
	switch {
	case x >= -128:        return .I8
	case x >= -32768:      return .I16
	case x >= -2147483648: return .I32
	}
	return .I64
}

// mtype_for_range returns the SMALLEST machine integer type whose value range
// contains [lo, hi]. Syntact knows this range from the reducer's envelope, so the
// width is determined BY CONSTRUCTION — no overflow analysis needed. A negative
// lo forces a signed type; an all-nonneg range fits the smallest unsigned type.
// nil bounds (±∞) fall back to I64.
mtype_for_range :: proc(lo: Maybe(i64), hi: Maybe(i64)) -> Machine_Type {
	l, lok := lo.?
	h, hok := hi.?
	if !lok || !hok do return .I64
	if l >= 0 {
		switch {
		case h <= 255:        return .U8
		case h <= 65535:      return .U16
		case h <= 4294967295: return .U32
		}
		return .I64
	}
	// Signed: need both l and h to fit the signed type's [min, max].
	switch {
	case l >= -128 && h <= 127:               return .I8
	case l >= -32768 && h <= 32767:           return .I16
	case l >= -2147483648 && h <= 2147483647: return .I32
	}
	return .I64
}

// mtype_wider returns the wider of two machine types (used to pick an arithmetic
// node's result width from its operands when the fold envelope is unavailable).
mtype_wider :: proc(a, b: Machine_Type) -> Machine_Type {
	if a == .None do return b
	if b == .None do return a
	if mtype_is_float(a) || mtype_is_float(b) {
		if a == .F64 || b == .F64 do return .F64
		return .F32
	}
	return mtype_bits(a) >= mtype_bits(b) ? a : b
}

// ----------------------------------------------------------------------------
// Instructions.
// ----------------------------------------------------------------------------

// The bytecode uses DISTINCT mnemonics for the register and immediate forms of
// an operation — like a real ISA (`add r,r` vs `add r,imm`). So a literal is an
// immediate ON the instruction (BC_Bin_Imm), never a separate BC_Const value: a
// constant doesn't occupy a virtual register or an instruction unless it is
// genuinely live in one. The backend routes by mnemonic with no "is this a
// constant?" inspection.
BC_Inst :: union {
	BC_Const, // dst = imm — a constant that must live in a register (rare: e.g. ret of a bare const)
	BC_Const_F, // dst = fimm (float constant)
	BC_Str_Const, // dst = pointer to a concrete string in .rodata
	BC_Rodata_Address, // dst = address of a program-global neutral rodata blob
	BC_Materialize, // dst = address of a function-local scratch aggregate
	BC_Load, // dst = scalar read from a function-local scratch aggregate
	BC_Load_Aggregate, // dst = address of a copy of a function-local aggregate
	BC_Load_Indirect, // dst = scalar read from an abstract aggregate address
	BC_Load_Arg, // dst = argv[slot] (a ??N fixed point), int/float domain
	BC_Bin, // dst = a op b      (reg op reg)
	BC_Bin_Imm, // dst = a op #imm   (reg op immediate)
	BC_Cmp, // dst = (a op b) ? 1 : 0     (reg cmp reg → 0/1)
	BC_Cmp_Imm, // dst = (a op #imm) ? 1 : 0  (reg cmp immediate → 0/1)
	BC_Move, // dst = src — a copy; reused as the phi/merge mechanism (several Moves into one dst). NOT pattern-specific: any merge point (pattern branch, loop-carried accumulator) writes a common dst this way
	BC_Label_Def, // label: (a jump destination)
	BC_Jump, // goto target — back-edge too, so the Label/Jump/Branch_Zero/Move set forms a full CFG: conditionals AND loops are expressible
	BC_Branch_Zero, // if cond == 0 goto target
	BC_Ret, // return src (becomes the program's result)
	BC_Foreign_Call, // dst = call [GOT slot](args…) — crosses the external frontier
	BC_Call, // dst = call internal function(args…)
}

BC_Const :: struct {
	dst: BC_Value,
	imm: i64,
}

BC_Const_F :: struct {
	dst:  BC_Value,
	fimm: f64,
}

// A concrete string constant: dst holds a pointer to `bytes` laid down in a
// read-only data section. The length is `len(bytes)` — known statically.
BC_Str_Const :: struct {
	dst:   BC_Value,
	bytes: string,
	id:    int, // .rodata slot index (assigned at lowering)
}

BC_Rodata_Blob :: struct {
	data:  []u8,
	align: int,
}

BC_Rodata_Address :: struct {
	dst:    BC_Value,
	blob:   int,
	offset: int,
}

BC_Scratch_Slot :: struct {
	id:    BC_Scratch_Id,
	size:  int,
	align: int,
}

BC_Materialize_Store :: struct {
	offset:     int,
	value:      BC_Value,
	size:       int,
	copy_bytes: bool, // value is an address of another abstract scratch slot
}

BC_Materialize :: struct {
	dst:      BC_Value,
	slot:     BC_Scratch_Id,
	size:     int,
	borrowed: bool, // metadata only: no writeback or resonance semantics here
	stores:   []BC_Materialize_Store,
	inputs:   []BC_Value, // flattened source values for liveness; same order as stores
}

BC_Load :: struct {
	dst:    BC_Value,
	slot:   BC_Scratch_Id,
	offset: int,
	width:  uint,
	signed: bool,
}

BC_Load_Aggregate :: struct {
	dst:      BC_Value,
	src_slot: BC_Scratch_Id,
	dst_slot: BC_Scratch_Id,
	size:     int,
}

BC_Load_Indirect :: struct {
	dst:    BC_Value,
	address: BC_Value,
	offset: int,
	width:  uint,
	signed: bool,
}

BC_Load_Arg :: struct {
	dst:    BC_Value,
	slot:   int,
	width:  uint, // domain bit width (8/16/32/64), 0 = unsized → full i64
	signed: bool, // domain signedness, drives mask vs sign-extend at the entry
}

// An aggregate's fixed C layout, expressed without a target address.  Pieces
// are the non-padding portions of the aggregate's eightbyte chunks.  Backends
// classify the pieces for their own calling convention; lowering never turns
// an aggregate into a source-visible pointer or a guessed scalar.
BC_Aggregate_Piece :: struct {
	offset:  int,
	size:    int,
	machine: Machine_Type,
}

BC_Aggregate_Layout :: struct {
	size:     int,
	align:    int,
	pieces:   []BC_Aggregate_Piece,
	memory:   bool, // SysV MEMORY: the existing abstract aggregate cell is passed
	indirect: bool, // explicit existing indirect lowering (e.g. writable/borrowed)
}

BC_Bin :: struct {
	dst:  BC_Value,
	op:   BC_Op,
	a, b: BC_Value,
}

// dst = a op #imm — the immediate form. `op` is non-commutative-aware: `a - #imm`
// means a minus imm (imm is always the right operand), `a >> #imm` shifts a by
// imm, etc. The lowering puts the literal here directly.
BC_Bin_Imm :: struct {
	dst: BC_Value,
	op:  BC_Op,
	a:   BC_Value,
	imm: i64,
}

BC_Cmp :: struct {
	dst:  BC_Value,
	op:   BC_Op,
	a, b: BC_Value,
}

BC_Cmp_Imm :: struct {
	dst: BC_Value,
	op:  BC_Op,
	a:   BC_Value,
	imm: i64,
}

BC_Move :: struct {
	dst: BC_Value,
	src: BC_Value,
}

BC_Label_Def :: struct {
	label: BC_Label,
}

BC_Jump :: struct {
	target: BC_Label,
}

BC_Branch_Zero :: struct {
	cond:   BC_Value,
	target: BC_Label,
}

BC_Ret :: struct {
	src: BC_Value,
}

// A call across the external frontier: `dst = call [GOT slot](args…)`.
//
// `slot` indexes BC_Program.imports, which is also the GOT slot the loader fills at
// startup — so the emitter can address the target without knowing the final table
// layout. `args` are in DECLARATION order, which the backend maps onto the target
// ABI's registers by their Machine_Type (integers and floats use separate register
// classes in System V, so the split happens at emit time, not here).
//
// `dst` carries the DECLARED result layout. It is still a definition even for a void
// external: the call happens regardless of whether anything meaningful is returned.
BC_Foreign_Call :: struct {
	dst:  BC_Value,
	slot: int,
	args: []BC_Value,
	// One entry per argument when an aggregate has layout-sensitive ABI lowering.
	// Empty layouts denote the ordinary scalar path and preserve old hand-built
	// bytecode users.
	arg_layouts: []BC_Aggregate_Layout,
	// Foreign scalar ABI types come from the declared boundary constraints, not
	// necessarily from the concrete source value (for example an f32 formal can
	// be carved with an f64 literal).
	arg_types: []Machine_Type,
	result_layout: BC_Aggregate_Layout,
	has_result_layout: bool,
}

// A call to another function in the same program. Arguments are evaluated in
// declaration order and are received by the callee's v0..v(len(params)-1).
BC_Call :: struct {
	dst:  BC_Value,
	func: Func_Id,
	args: []BC_Value,
	arg_layouts: []BC_Aggregate_Layout,
	result_layout: BC_Aggregate_Layout,
	has_result_layout: bool,
}

// Structured loop metadata is deliberately descriptive: the executable control
// flow remains the existing Label/Jump/Branch instruction set.
Loop_Info :: struct {
	header: BC_Label,
	latch:  BC_Label,
	exits:  []BC_Label,
}

BC_Func :: struct {
	id:          Func_Id,
	identity:    string,
	params:      []Machine_Type,
	param_layouts: []BC_Aggregate_Layout,
	param_scratch: []BC_Scratch_Id,
	result:      Machine_Type,
	result_layout: BC_Aggregate_Layout,
	has_result_layout: bool,
	sret_slot:   BC_Scratch_Id,
	insts:       []BC_Inst,
	value_count: int,
	label_count: int,
	value_types: []Machine_Type,
	loops:       []Loop_Info,
	scratch:     []BC_Scratch_Slot,
}

// A lowered program: a flat instruction list plus the value/label counters so a
// backend knows how many virtual registers to allocate. `error` is non-empty
// when lowering hit a construct it cannot codegen yet (a symbolic string, an
// unsized domain) — the pipeline reports it instead of emitting wrong bytecode.
// One imported symbol: the library it comes from and its name. The pair is written
// verbatim into the link tables (.dynstr/.dynsym) — neither string is interpreted.
// The index of an entry in BC_Program.imports IS its GOT slot number, so codegen can
// address the slot before the tables exist.
BC_Import :: struct {
	lib:    string,
	symbol: string,
}

BC_Program :: struct {
	// Named function model. The legacy fields below remain a compatibility view for
	// existing pure codegen and hand-built ABI tests; new programs should populate
	// funcs and entry as well.
	funcs:       [dynamic]BC_Func,
	entry:       Maybe(Func_Id),
	exports:     []Func_Id,

	// Legacy flat entry view. It is intentionally kept until all machine backends
	// consume BC_Func directly.
	insts:       [dynamic]BC_Inst,
	params:      [dynamic]Machine_Type,
	param_layouts: [dynamic]BC_Aggregate_Layout,
	param_scratch: [dynamic]BC_Scratch_Id,
	value_count: int,
	label_count: int,
	value_types: [dynamic]Machine_Type, // Machine_Type per BC_Value (indexed by vN)
	rodata:      [dynamic]string, // concrete string literals → .rodata, indexed by id
	rodata_blobs: [dynamic]BC_Rodata_Blob, // neutral bytes, program-global
	scratch:     [dynamic]BC_Scratch_Slot, // legacy entry function's local plan
	// Symbols this program calls across the external frontier, deduplicated. Empty
	// for a pure program — and an empty list is what keeps the default output a
	// static binary with no interpreter and no dynamic tables at all.
	imports:     [dynamic]BC_Import,
	loops:       [dynamic]Loop_Info,
	result_type: Machine_Type, // Machine_Type of the program's returned value
	result_layout: BC_Aggregate_Layout,
	has_result_layout: bool,
	sret_slot: BC_Scratch_Id,
	error:       string,
}

bc_program_entry :: proc(prog: ^BC_Program) -> (BC_Func, bool) {
	if prog == nil || len(prog.funcs) == 0 do return {}, false
	id := Func_Id(0)
	if selected, ok := prog.entry.?; ok do id = selected
	for f in prog.funcs do if f.id == id do return f, true
	return {}, false
}

bc_program_has_named_funcs :: proc(prog: ^BC_Program) -> bool {
	return prog != nil && len(prog.funcs) > 0
}

// bc_intern_import returns the GOT slot for (lib, symbol), appending it on first
// use so repeated calls to the same symbol share one slot.
bc_intern_import :: proc(prog: ^BC_Program, lib, symbol: string) -> int {
	for imp, i in prog.imports {
		if imp.lib == lib && imp.symbol == symbol do return i
	}
	append(&prog.imports, BC_Import{lib = lib, symbol = symbol})
	return len(prog.imports) - 1
}

// bc_append_rodata_blob interns target-neutral bytes in program-global rodata.
// The returned index is stable for the lifetime of the program and is resolved
// to an address only by a concrete image backend.
BC_Append_Rodata_Blob :: proc(prog: ^BC_Program, data: []u8, align: int = 1) -> int {
	append(&prog.rodata_blobs, BC_Rodata_Blob{data = data, align = align})
	return len(prog.rodata_blobs) - 1
}

// ----------------------------------------------------------------------------
// Dump — `--bc` prints the bytecode so it can be inspected independently of any
// machine backend.
// ----------------------------------------------------------------------------

bytecode_to_string :: proc(prog: ^BC_Program) -> string {
	if prog == nil do return "<no bytecode>"
	sb := strings.builder_make()
	if prog.error != "" {
		fmt.sbprintf(&sb, "; ERROR: %s\n", prog.error)
	}
	for s, i in prog.rodata {
		fmt.sbprintf(&sb, "; .rodata[%d] = %q\n", i, s)
	}
	for blob, i in prog.rodata_blobs {
		fmt.sbprintf(&sb, "; .blob[%d] = %d bytes align %d\n", i, len(blob.data), blob.align)
	}
	if len(prog.funcs) > 0 {
		for fn in prog.funcs {
			fmt.sbprintf(&sb, "func @f%d %s() -> %s {{\n", int(fn.id), fn.identity, mtype_name(fn.result))
			view := BC_Program{result_type = fn.result, imports = prog.imports}
			for inst in fn.insts do fmt.sbprintf(&sb, "%s\n", bc_inst_line(inst, &view))
			for loop in fn.loops {
				fmt.sbprintf(&sb, "  ; loop L%d..L%d", int(loop.header), int(loop.latch))
				for exit in loop.exits do fmt.sbprintf(&sb, " exit L%d", int(exit))
				strings.write_byte(&sb, '\n')
			}
			strings.write_string(&sb, "}\n")
		}
		return strings.to_string(sb)
	}
	for inst in prog.insts {
		fmt.sbprintf(&sb, "%s\n", bc_inst_line(inst, prog))
	}
	return strings.to_string(sb)
}

// bc_inst_line renders a single instruction WITHOUT the trailing newline; shared
// by the dump and the regalloc annotation.
bc_inst_line :: proc(inst: BC_Inst, prog: ^BC_Program = nil) -> string {
	switch v in inst {
	case BC_Const:
		return fmt.tprintf("  v%d = const %d", int(v.dst), v.imm)
	case BC_Const_F:
		return fmt.tprintf("  v%d = constf %v", int(v.dst), v.fimm)
	case BC_Str_Const:
		return fmt.tprintf("  v%d = str .rodata[%d]", int(v.dst), v.id)
	case BC_Rodata_Address:
		return fmt.tprintf("  v%d = address .blob[%d]+%d", int(v.dst), v.blob, v.offset)
	case BC_Materialize:
		return fmt.tprintf("  v%d = materialize scratch[%d] size=%d", int(v.dst), int(v.slot), v.size)
	case BC_Load:
		return fmt.tprintf("  v%d = load scratch[%d]+%d :%s%d", int(v.dst), int(v.slot), v.offset, v.signed ? "i" : "u", v.width)
	case BC_Load_Aggregate:
		return fmt.tprintf("  v%d = load aggregate scratch[%d] -> scratch[%d] size=%d", int(v.dst), int(v.src_slot), int(v.dst_slot), v.size)
	case BC_Load_Indirect:
		return fmt.tprintf("  v%d = load *v%d+%d :%s%d", int(v.dst), int(v.address), v.offset, v.signed ? "i" : "u", v.width)
	case BC_Load_Arg:
		if v.width != 0 && v.width < 64 {
			return fmt.tprintf("  v%d = arg %d :%s%d", int(v.dst), v.slot, v.signed ? "i" : "u", v.width)
		}
		return fmt.tprintf("  v%d = arg %d", int(v.dst), v.slot)
	case BC_Bin:
		return fmt.tprintf("  v%d = %s v%d v%d", int(v.dst), bc_op_symbol(v.op), int(v.a), int(v.b))
	case BC_Bin_Imm:
		return fmt.tprintf("  v%d = %s v%d #%d", int(v.dst), bc_op_symbol(v.op), int(v.a), v.imm)
	case BC_Cmp:
		return fmt.tprintf("  v%d = cmp%s v%d v%d", int(v.dst), bc_op_symbol(v.op), int(v.a), int(v.b))
	case BC_Cmp_Imm:
		return fmt.tprintf("  v%d = cmp%s v%d #%d", int(v.dst), bc_op_symbol(v.op), int(v.a), v.imm)
	case BC_Move:
		return fmt.tprintf("  v%d = move v%d", int(v.dst), int(v.src))
	case BC_Label_Def:
		return fmt.tprintf("L%d:", int(v.label))
	case BC_Jump:
		return fmt.tprintf("  jmp L%d", int(v.target))
	case BC_Branch_Zero:
		return fmt.tprintf("  brz v%d L%d", int(v.cond), int(v.target))
	case BC_Ret:
		rt := prog != nil ? mtype_name(prog.result_type) : ""
		return fmt.tprintf("  ret v%d  ; %s", int(v.src), rt)
	case BC_Foreign_Call:
		b := strings.builder_make()
		fmt.sbprintf(&b, "  v%d = call [got %d](", int(v.dst), v.slot)
		for a, i in v.args {
			if i > 0 do strings.write_string(&b, ", ")
			fmt.sbprintf(&b, "v%d", int(a))
		}
		strings.write_byte(&b, ')')
		if prog != nil && v.slot < len(prog.imports) {
			imp := prog.imports[v.slot]
			fmt.sbprintf(&b, "  ; <%s>.%s", imp.lib, imp.symbol)
		}
		return strings.to_string(b)
	case BC_Call:
		b := strings.builder_make()
		fmt.sbprintf(&b, "  v%d = call @f%d(", int(v.dst), int(v.func))
		for a, i in v.args {
			if i > 0 do strings.write_string(&b, ", ")
			fmt.sbprintf(&b, "v%d", int(a))
		}
		strings.write_byte(&b, ')')
		return strings.to_string(b)
	}
	return ""
}
