package compiler

import "core:fmt"
import "core:strings"

// ============================================================================
// BYTECODE — the target-neutral bridge between the reducer and every backend.
//
// reduce() yields a DAG of ^Type (CSE done, constants folded, factored). A
// machine wants a linear instruction stream. The bytecode IS that stream, in a
// form no single backend owns: SSA-like virtual registers, infinitely many,
// each value numbered once and never reassigned — which mirrors the reducer's
// output exactly (a shared DAG node lowers to a single vN, so CSE survives for
// free). Each backend (x64→ELF, arm64, wasm, the interpreter below) consumes
// the SAME Program and allocates the vN however it likes.
//
// A ??N fixed point becomes Load_Arg{slot: N}, where N is fixedpoint_id's
// stable, appearance-ordered index — so `./prog 7 3` feeds ??0=7, ??1=3.
// ============================================================================

// A virtual register: v0, v1, … — SSA, assigned exactly once.
BC_Value :: distinct int

BC_INVALID_VALUE :: BC_Value(-1)

// Machine_Type is the EXACT machine domain+width of a value, derived once from
// the analyzer's fold_type/cast_target. Syntact fixes this semantically (the
// structural coloring), so the bytecode PRESERVES it rather than re-deriving or
// optimizing it: a u8 stays U8 (list layout = 1 byte, wrap is intended), f32 vs
// f64 follow the declared precision (addss vs addsd). Constants are NEUTRAL —
// they carry no Machine_Type and fold into immediates at the backend.
Machine_Type :: enum u8 {
	None, // not yet codegen-able (string symbolic, unsized float/int) → reject
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

// machine_type_of derives the Machine_Type of a reduced node from its fold. This
// is the SINGLE point of truth for the int/float-width-and-signedness mapping, so
// nothing else re-derives it. Returns .None when the node has no materializable
// machine layout yet (unsized int/float, symbolic string) — the caller rejects.
machine_type_of :: proc(node: ^Type) -> Machine_Type {
	if node == nil do return .None
	#partial switch v in node^ {
	case Integer_Type:
		// A concrete singleton integer has no declared width (it's an untyped
		// constant); its Machine_Type is decided by its USE, so it is handled as
		// an immediate, not here. We still answer with a sensible width for the
		// rare case a bare integer is a value: smallest signed type holding it.
		if int_is_concrete(v) {
			return mtype_for_int_value(i64(int_value(v)))
		}
		// Non-concrete integer = a fixed point; its width is in its color, read
		// via a Cast_Type wrapper (handled in the Cast_Type case). A bare
		// unsized integer interval defaults to I64.
		if len(v.integer_intervals) == 1 {
			if lay, ok := int_layout(v.integer_intervals[0]); ok {
				return mtype_from_layout(lay.bits, lay.signed)
			}
		}
		return .I64
	case Float_Type:
		switch v.kind {
		case .f32:
			return .F32
		case .f64:
			return .F64
		case .none:
			// An unsized float literal defaults to F64 (the safe, standard
			// default; f32 only when explicitly declared).
			return .F64
		}
	case Bool_Type:
		return .U8
	case String_Type:
		// A concrete (singleton) string is materializable to .rodata; a symbolic
		// one is not yet (needs pattern capture).
		if string_is_concrete(v) do return .Str
		return .None
	case Cast_Type:
		// ??::u8 etc. — the cast target carries the declared width/signedness.
		if tgt, ok := cast_target(v.target); ok {
			switch tgt.kind {
			case .Integer:
				return mtype_from_layout(tgt.width, tgt.signed)
			case .Float:
				return tgt.float_kind == .f32 ? .F32 : .F64
			case .Bool:
				return .U8
			case .String:
				return .Str
			}
		}
		return .None
	case Compose_Type:
		// An arithmetic node's width is its envelope's width; fold it and recurse
		// on the result. (fold_value_type returns the numeric envelope.)
		if env := fold_value_type(node); env != nil && env != node {
			return machine_type_of(env)
		}
		// Fall back to the wider operand's type.
		lm := machine_type_of(v.left)
		rm := machine_type_of(v.right)
		return mtype_wider(lm, rm)
	}
	return .None
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

// mtype_wider returns the wider of two machine types (used to pick an arithmetic
// node's result width from its operands when the fold envelope is unavailable).
mtype_wider :: proc(a, b: Machine_Type) -> Machine_Type {
	if a == .None do return b
	if b == .None do return a
	if mtype_is_float(a) || mtype_is_float(b) {
		// Float dominates; widest precision wins.
		if a == .F64 || b == .F64 do return .F64
		return .F32
	}
	return mtype_bits(a) >= mtype_bits(b) ? a : b
}

// A jump target inside the instruction stream.
BC_Label :: distinct int

BC_Inst :: union {
	BC_Const, // dst = imm (integer/bool)
	BC_Const_F, // dst = fimm (float constant)
	BC_Str_Const, // dst = pointer to a concrete string in .rodata
	BC_Load_Arg, // dst = argv[slot] (a ??N fixed point), int/float domain
	BC_Bin, // dst = a op b   (arithmetic / bitwise / shift) — domain on value_types
	BC_Cmp, // dst = (a op b) ? 1 : 0   (comparison → 0/1)
	BC_Move, // dst = src    (a phi merge — pattern branches write a common dst)
	BC_Label_Def, // label: (a jump destination)
	BC_Jump, // goto target
	BC_Branch_Zero, // if cond == 0 goto target
	BC_Ret, // return src (becomes the program's result)
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
// read-only data section. The length is `len(bytes)` — known statically, carried
// here, and materialized only if an operation consumes it (else it is just the
// pointer + an immediate length at the write site).
BC_Str_Const :: struct {
	dst:   BC_Value,
	bytes: string,
	id:    int, // .rodata slot index (assigned at lowering)
}

BC_Load_Arg :: struct {
	dst:    BC_Value,
	slot:   int,
	width:  uint, // domain bit width (8/16/32/64), 0 = unsized → full i64
	signed: bool, // domain signedness, drives mask vs sign-extend at the entry
}

BC_Bin :: struct {
	dst:  BC_Value,
	op:   Operator_Kind,
	a, b: BC_Value,
}

BC_Cmp :: struct {
	dst:  BC_Value,
	op:   Operator_Kind,
	a, b: BC_Value,
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

// A lowered program: a flat instruction list plus the value/label counters so a
// backend knows how many virtual registers to allocate. `error` is non-empty
// when lowering hit a construct it cannot codegen yet (a symbolic string, an
// unsized domain) — the pipeline reports it instead of emitting wrong bytecode.
BC_Program :: struct {
	insts:        [dynamic]BC_Inst,
	value_count:  int,
	label_count:  int,
	value_types:  [dynamic]Machine_Type, // Machine_Type per BC_Value (indexed by vN)
	rodata:       [dynamic]string, // concrete string literals → .rodata, indexed by id
	result_type:  Machine_Type, // Machine_Type of the program's returned value
	error:        string,
}

// ----------------------------------------------------------------------------
// Lowering: ^Type (reduced DAG) → BC_Program.
//
// Post-order DFS with memoization keyed by node ADDRESS — this is what carries
// the reducer's CSE through to the bytecode: a DAG node reached twice returns
// the same vN both times, so it is computed once.
// ----------------------------------------------------------------------------

BC_Lower :: struct {
	prog: ^BC_Program,
	memo: map[^Type]BC_Value, // DAG node → its already-lowered vN (CSE)
}

// bc_fresh_value mints a new SSA value and records its Machine_Type (defaulting
// to I64 for scratch values — masks, shift counts, the integer immediates whose
// width the backend re-derives from the use). value_types stays index-aligned
// with the value count.
bc_fresh_value :: proc(l: ^BC_Lower, mt: Machine_Type = .I64) -> BC_Value {
	v := BC_Value(l.prog.value_count)
	l.prog.value_count += 1
	append(&l.prog.value_types, mt)
	return v
}

// bc_fail records the first lowering error and returns a placeholder value, so
// the caller can keep going without crashing while the program is marked failed.
bc_fail :: proc(l: ^BC_Lower, msg: string) -> BC_Value {
	if l.prog.error == "" do l.prog.error = msg
	return bc_fresh_value(l)
}

bc_fresh_label :: proc(l: ^BC_Lower) -> BC_Label {
	lab := BC_Label(l.prog.label_count)
	l.prog.label_count += 1
	return lab
}

bc_emit :: proc(l: ^BC_Lower, inst: BC_Inst) {
	append(&l.prog.insts, inst)
}

// lower_to_bytecode is the one hard maillon, written once: it turns the reduced
// DAG into the neutral bytecode every backend shares. `root` is the value the
// main scope reduces to (reduce(scope)). Returns nil if root is nil.
lower_to_bytecode :: proc(root: ^Type) -> ^BC_Program {
	if root == nil do return nil
	prog := new(BC_Program)
	l := BC_Lower {
		prog = prog,
		memo = make(map[^Type]BC_Value),
	}
	defer delete(l.memo)
	result := bc_lower_value(&l, root)
	prog.result_type = machine_type_of(root)
	if prog.result_type == .None && int(result) < len(prog.value_types) {
		prog.result_type = prog.value_types[result]
	}
	bc_emit(&l, BC_Ret{result})
	return prog
}

bc_lower_value :: proc(l: ^BC_Lower, node: ^Type) -> BC_Value {
	if node == nil {
		// Defensive: a missing operand becomes a zero const.
		dst := bc_fresh_value(l)
		bc_emit(l, BC_Const{dst, 0})
		return dst
	}
	if v, ok := l.memo[node]; ok do return v // ← CSE: shared DAG node, one vN

	dst: BC_Value
	#partial switch v in node^ {
	case Integer_Type:
		if int_is_concrete(v) {
			// Untyped integer constant → a neutral immediate (the backend folds
			// it to the use's width); recorded as I64 scratch here.
			dst = bc_fresh_value(l, .I64)
			bc_emit(l, BC_Const{dst, i64(int_value(v))})
		} else {
			// A non-concrete integer that reached lowering is a fixed point
			// (the reducer keeps ?? as the only symbolic leaf).
			dst = bc_lower_fixed_point(l, node)
		}

	case Float_Type:
		if float_is_concrete(v) {
			dst = bc_fresh_value(l, machine_type_of(node))
			bc_emit(l, BC_Const_F{dst, float_value(v)})
		} else {
			// A symbolic float is a fixed point (??::f64 / ??::f32).
			dst = bc_lower_fixed_point(l, node)
		}

	case Bool_Type:
		dst = bc_fresh_value(l, .U8)
		bc_emit(l, BC_Const{dst, bool_is_concrete(v) && bool_value(v) ? 1 : 0})

	case None_Type:
		// The empty set / absence of a value (e.g. `true & false`). Materializes
		// as 0 (exit 0 / empty), the natural "nothing" result.
		dst = bc_fresh_value(l, .I64)
		bc_emit(l, BC_Const{dst, 0})

	case String_Type:
		if string_is_concrete(v) {
			dst = bc_lower_string_const(l, string_value(v))
		} else {
			// A symbolic string needs pattern capture (count, concat with a ??),
			// which is not implemented yet — reject instead of emitting wrong code.
			dst = bc_fail(l, "codegen: symbolic string not yet supported (needs pattern capture)")
		}

	case Cast_Type:
		// reduce keeps a raw cast around a fixed point as Cast(Unknown); the
		// envelope is the target but the runtime value is the unknown's bits.
		dst = bc_lower_fixed_point(l, node)

	case Unknown_Type:
		dst = bc_lower_fixed_point(l, node)

	case Compose_Type:
		// A string-domain compose ("hi " + ??::string) is an ordered sequence,
		// not arithmetic — it needs runtime concat + length tracking (pattern
		// capture), not implemented yet. Reject before lowering its operands.
		if bc_compose_is_string(node) {
			dst = bc_fail(l, "codegen: symbolic string concatenation not yet supported (needs pattern capture)")
		} else {
			a := bc_lower_value(l, v.left)
			b := bc_lower_value(l, v.right)
			mt := machine_type_of(node)
			if mt == .None do mt = mtype_wider(l.prog.value_types[a], l.prog.value_types[b])
			dst = bc_fresh_value(l, bc_is_comparison(v.operator) ? .U8 : mt)
			if bc_is_comparison(v.operator) {
				bc_emit(l, BC_Cmp{dst, v.operator, a, b})
			} else {
				bc_emit(l, BC_Bin{dst, v.operator, a, b})
			}
		}

	case Pattern_Type:
		dst = bc_lower_pattern(l, v)

	case:
		// A domain we cannot lower yet — reject explicitly rather than emit a
		// silent `const 0` (which produced wrong programs).
		dst = bc_fail(l, fmt.tprintf("codegen: unsupported value in lowering"))
	}

	l.memo[node] = dst
	return dst
}

// A ??N fixed point → Load_Arg{slot: N}. fixedpoint_id gives the stable,
// appearance-ordered index, which is exactly the argv position.
//
// The ??'s declared domain (its ::u8 / ::i32 envelope) is read here and the
// value is NORMALIZED to that domain ONCE, at the entry: an unsigned u8 is
// masked (`and 0xff`), a signed i8 is sign-extended (`shl 56; sar 56`). After
// this single normalization the analyzer has proven the whole downstream stays
// in range, so NO further masking is emitted — wrap-at-the-domain, then clean.
bc_lower_fixed_point :: proc(l: ^BC_Lower, node: ^Type) -> BC_Value {
	slot := fixedpoint_id(node)
	mt := machine_type_of(node)

	// A float ?? (??::f64 / ??::f32): load the argument as a double, no masking.
	// argv parsing produces a double directly; f32 narrows it (handled downstream).
	if mtype_is_float(mt) {
		raw := bc_fresh_value(l, mt)
		bc_emit(l, BC_Load_Arg{raw, slot, mtype_bits(mt), true})
		return raw
	}

	width, signed := bc_unknown_domain(node)

	raw := bc_fresh_value(l, mt == .None ? .I64 : mt)
	bc_emit(l, BC_Load_Arg{raw, slot, width, signed})

	// A 64-bit (or unsized) domain needs no normalization — argv is already i64.
	if width == 0 || width >= 64 do return raw

	if !signed {
		// Unsigned truncation: and with (2^width - 1).
		mask := i64((u64(1) << width) - 1)
		m := bc_fresh_value(l); bc_emit(l, BC_Const{m, mask})
		dst := bc_fresh_value(l, mt)
		bc_emit(l, BC_Bin{dst, .BitAnd, raw, m})
		return dst
	}

	// Signed: shift left then arithmetic-shift right to sign-extend the low
	// `width` bits across the full i64.
	shift := i64(64 - width)
	s1 := bc_fresh_value(l); bc_emit(l, BC_Const{s1, shift})
	hi := bc_fresh_value(l); bc_emit(l, BC_Bin{hi, .LShift, raw, s1})
	s2 := bc_fresh_value(l); bc_emit(l, BC_Const{s2, shift})
	dst := bc_fresh_value(l, mt)
	bc_emit(l, BC_Bin{dst, .RShift, hi, s2})
	return dst
}

// bc_lower_string_const lays a concrete string into the program's .rodata pool
// and emits a pointer to it. The length is len(bytes), known statically.
bc_lower_string_const :: proc(l: ^BC_Lower, s: string) -> BC_Value {
	id := len(l.prog.rodata)
	append(&l.prog.rodata, s)
	dst := bc_fresh_value(l, .Str)
	bc_emit(l, BC_Str_Const{dst, s, id})
	return dst
}

// bc_unknown_domain reads a ??'s declared domain width/signedness from the
// Cast_Type that pins it (??::u8 → {8,false}). A bare Unknown with no cast is
// unsized → {0,false} (full i64, no normalization).
bc_unknown_domain :: proc(node: ^Type) -> (width: uint, signed: bool) {
	if node == nil do return 0, false
	#partial switch v in node^ {
	case Cast_Type:
		if tgt, ok := cast_target(v.target); ok {
			if tgt.kind == .Integer do return tgt.width, tgt.signed
			if tgt.kind == .Bool do return 8, false
		}
	}
	return 0, false
}

// A pattern whose target survives as a fixed point becomes a branch chain: test
// each branch's match against the target, jump to the firing product. (Concrete
// targets are already resolved away by reduce_pattern, so a Pattern_Type here
// always has a symbolic target.) For the first cut we only lower integer
// range/value matches into comparisons; richer matches fall back to the first
// branch product so the pipeline stays whole.
bc_lower_pattern :: proc(l: ^BC_Lower, p: Pattern_Type) -> BC_Value {
	target := bc_lower_value(l, p.target)
	end := bc_fresh_label(l)
	// The merge slot: every branch writes its product here via BC_Move, so the
	// allocator pins all writers to one location (a proper phi, not the old
	// `Or x x` hack). Type it from the first branch product's machine type.
	rt := len(p.branches) > 0 ? machine_type_of(p.branches[0].product) : Machine_Type.I64
	if rt == .None do rt = .I64
	result := bc_fresh_value(l, rt)

	for branch in p.branches {
		lo, hi, ok := bc_branch_int_range(branch)
		if !ok {
			// Default / non-range branch: take it unconditionally.
			prod := bc_lower_value(l, branch.product)
			bc_emit(l, BC_Move{result, prod})
			bc_emit(l, BC_Jump{end})
			continue
		}
		next := bc_fresh_label(l)
		// if target < lo goto next
		lo_v := bc_fresh_value(l); bc_emit(l, BC_Const{lo_v, lo})
		ge_lo := bc_fresh_value(l, .U8); bc_emit(l, BC_Cmp{ge_lo, .GreaterEqual, target, lo_v})
		bc_emit(l, BC_Branch_Zero{ge_lo, next})
		// if target > hi goto next
		hi_v := bc_fresh_value(l); bc_emit(l, BC_Const{hi_v, hi})
		le_hi := bc_fresh_value(l, .U8); bc_emit(l, BC_Cmp{le_hi, .LessEqual, target, hi_v})
		bc_emit(l, BC_Branch_Zero{le_hi, next})
		// matched: result := product, goto end
		prod := bc_lower_value(l, branch.product)
		bc_emit(l, BC_Move{result, prod})
		bc_emit(l, BC_Jump{end})
		bc_emit(l, BC_Label_Def{next})
	}
	bc_emit(l, BC_Label_Def{end})
	return result
}

// Extract a concrete integer [lo,hi] match from a pattern branch, if it is one.
bc_branch_int_range :: proc(branch: Pattern_Branch) -> (lo: i64, hi: i64, ok: bool) {
	if branch.match == nil do return 0, 0, false
	if ints, ok := fold_type_intervals(branch.match).?; ok {
		if len(ints) == 1 {
			if lo, has_lo := ints[0].lo.?; has_lo {
				if hi, has_hi := ints[0].hi.?; has_hi {
					return i64(lo), i64(hi), true
				}
			}
		}
	}
	return 0, 0, false
}

// bc_compose_is_string reports whether an arithmetic node operates on strings —
// detected by either operand folding to the string domain (a string `+` is an
// ordered sequence, not a number). Walks one level into nested composes.
bc_compose_is_string :: proc(node: ^Type) -> bool {
	if node == nil do return false
	#partial switch v in node^ {
	case Compose_Type:
		return bc_operand_is_string(v.left) || bc_operand_is_string(v.right)
	}
	return false
}

bc_operand_is_string :: proc(node: ^Type) -> bool {
	if node == nil do return false
	#partial switch v in node^ {
	case String_Type:
		return true
	case Compose_Type:
		return bc_compose_is_string(node)
	case Cast_Type:
		if tgt, ok := cast_target(v.target); ok do return tgt.kind == .String
	}
	// A ?? string has no Cast_Type sometimes; check the fold envelope.
	if env := fold_value_type(node); env != nil {
		#partial switch e in env^ {
		case String_Type:
			return true
		}
	}
	return false
}

bc_is_comparison :: proc(op: Operator_Kind) -> bool {
	#partial switch op {
	case .Equal, .NotEqual, .Less, .Greater, .LessEqual, .GreaterEqual:
		return true
	}
	return false
}

// ----------------------------------------------------------------------------
// Dump — `--bc` prints the bytecode so we can inspect the linearization before
// (and independently of) any machine backend.
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
	for inst in prog.insts {
		switch v in inst {
		case BC_Const:
			fmt.sbprintf(&sb, "  v%d = const %d\n", int(v.dst), v.imm)
		case BC_Const_F:
			fmt.sbprintf(&sb, "  v%d = constf %v\n", int(v.dst), v.fimm)
		case BC_Str_Const:
			fmt.sbprintf(&sb, "  v%d = str .rodata[%d]\n", int(v.dst), v.id)
		case BC_Load_Arg:
			if v.width != 0 && v.width < 64 {
				fmt.sbprintf(&sb, "  v%d = arg %d :%s%d\n", int(v.dst), v.slot, v.signed ? "i" : "u", v.width)
			} else {
				fmt.sbprintf(&sb, "  v%d = arg %d\n", int(v.dst), v.slot)
			}
		case BC_Bin:
			fmt.sbprintf(&sb, "  v%d = %s v%d v%d\n", int(v.dst), op_symbol(v.op), int(v.a), int(v.b))
		case BC_Cmp:
			fmt.sbprintf(&sb, "  v%d = cmp%s v%d v%d\n", int(v.dst), op_symbol(v.op), int(v.a), int(v.b))
		case BC_Move:
			fmt.sbprintf(&sb, "  v%d = move v%d\n", int(v.dst), int(v.src))
		case BC_Label_Def:
			fmt.sbprintf(&sb, "L%d:\n", int(v.label))
		case BC_Jump:
			fmt.sbprintf(&sb, "  jmp L%d\n", int(v.target))
		case BC_Branch_Zero:
			fmt.sbprintf(&sb, "  brz v%d L%d\n", int(v.cond), int(v.target))
		case BC_Ret:
			fmt.sbprintf(&sb, "  ret v%d  ; %s\n", int(v.src), mtype_name(prog.result_type))
		}
	}
	return strings.to_string(sb)
}
