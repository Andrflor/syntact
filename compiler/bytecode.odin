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

// A jump target inside the instruction stream.
BC_Label :: distinct int

BC_Inst :: union {
	BC_Const, // dst = imm
	BC_Load_Arg, // dst = argv[slot] (a ??N fixed point)
	BC_Bin, // dst = a op b   (arithmetic / bitwise / shift)
	BC_Cmp, // dst = (a op b) ? 1 : 0   (comparison → 0/1)
	BC_Label_Def, // label: (a jump destination)
	BC_Jump, // goto target
	BC_Branch_Zero, // if cond == 0 goto target
	BC_Ret, // return src (becomes the program's result)
}

BC_Const :: struct {
	dst: BC_Value,
	imm: i64,
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
// backend knows how many virtual registers to allocate.
BC_Program :: struct {
	insts:      [dynamic]BC_Inst,
	value_count: int,
	label_count: int,
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

bc_fresh_value :: proc(l: ^BC_Lower) -> BC_Value {
	v := BC_Value(l.prog.value_count)
	l.prog.value_count += 1
	return v
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
			dst = bc_fresh_value(l)
			bc_emit(l, BC_Const{dst, i64(int_value(v))})
		} else {
			// A non-concrete integer that reached lowering is a fixed point
			// (the reducer keeps ?? as the only symbolic leaf).
			dst = bc_lower_fixed_point(l, node)
		}

	case Bool_Type:
		dst = bc_fresh_value(l)
		bc_emit(l, BC_Const{dst, bool_is_concrete(v) && bool_value(v) ? 1 : 0})

	case Cast_Type:
		// reduce keeps a raw cast around a fixed point as Cast(Unknown); the
		// envelope is the target but the runtime value is the unknown's bits.
		dst = bc_lower_fixed_point(l, node)

	case Unknown_Type:
		dst = bc_lower_fixed_point(l, node)

	case Compose_Type:
		a := bc_lower_value(l, v.left)
		b := bc_lower_value(l, v.right)
		dst = bc_fresh_value(l)
		if bc_is_comparison(v.operator) {
			bc_emit(l, BC_Cmp{dst, v.operator, a, b})
		} else {
			bc_emit(l, BC_Bin{dst, v.operator, a, b})
		}

	case Pattern_Type:
		dst = bc_lower_pattern(l, v)

	case:
		// Anything else surviving lowering is not yet codegen-able; emit 0 so
		// the pipeline produces SOMETHING rather than crashing, and the caller
		// can diagnose via the bytecode dump.
		dst = bc_fresh_value(l)
		bc_emit(l, BC_Const{dst, 0})
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
	width, signed := bc_unknown_domain(node)

	raw := bc_fresh_value(l)
	bc_emit(l, BC_Load_Arg{raw, slot, width, signed})

	// A 64-bit (or unsized) domain needs no normalization — argv is already i64.
	if width == 0 || width >= 64 do return raw

	if !signed {
		// Unsigned truncation: and with (2^width - 1).
		mask := i64((u64(1) << width) - 1)
		m := bc_fresh_value(l); bc_emit(l, BC_Const{m, mask})
		dst := bc_fresh_value(l)
		bc_emit(l, BC_Bin{dst, .BitAnd, raw, m})
		return dst
	}

	// Signed: shift left then arithmetic-shift right to sign-extend the low
	// `width` bits across the full i64.
	shift := i64(64 - width)
	s1 := bc_fresh_value(l); bc_emit(l, BC_Const{s1, shift})
	hi := bc_fresh_value(l); bc_emit(l, BC_Bin{hi, .LShift, raw, s1})
	s2 := bc_fresh_value(l); bc_emit(l, BC_Const{s2, shift})
	dst := bc_fresh_value(l)
	bc_emit(l, BC_Bin{dst, .RShift, hi, s2})
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
	result := bc_fresh_value(l) // a "phi" slot the backend treats as mutable

	for branch in p.branches {
		lo, hi, ok := bc_branch_int_range(branch)
		if !ok {
			// Default / non-range branch: take it unconditionally.
			prod := bc_lower_value(l, branch.product)
			bc_emit(l, BC_Bin{result, .Or, prod, prod}) // result := prod (mov)
			bc_emit(l, BC_Jump{end})
			continue
		}
		next := bc_fresh_label(l)
		// if target < lo goto next
		lo_v := bc_fresh_value(l); bc_emit(l, BC_Const{lo_v, lo})
		ge_lo := bc_fresh_value(l); bc_emit(l, BC_Cmp{ge_lo, .GreaterEqual, target, lo_v})
		bc_emit(l, BC_Branch_Zero{ge_lo, next})
		// if target > hi goto next
		hi_v := bc_fresh_value(l); bc_emit(l, BC_Const{hi_v, hi})
		le_hi := bc_fresh_value(l); bc_emit(l, BC_Cmp{le_hi, .LessEqual, target, hi_v})
		bc_emit(l, BC_Branch_Zero{le_hi, next})
		// matched: result := product, goto end
		prod := bc_lower_value(l, branch.product)
		bc_emit(l, BC_Bin{result, .Or, prod, prod})
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
	for inst in prog.insts {
		switch v in inst {
		case BC_Const:
			fmt.sbprintf(&sb, "  v%d = const %d\n", int(v.dst), v.imm)
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
		case BC_Label_Def:
			fmt.sbprintf(&sb, "L%d:\n", int(v.label))
		case BC_Jump:
			fmt.sbprintf(&sb, "  jmp L%d\n", int(v.target))
		case BC_Branch_Zero:
			fmt.sbprintf(&sb, "  brz v%d L%d\n", int(v.cond), int(v.target))
		case BC_Ret:
			fmt.sbprintf(&sb, "  ret v%d\n", int(v.src))
		}
	}
	return strings.to_string(sb)
}
