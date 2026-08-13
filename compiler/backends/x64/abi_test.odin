package x64_assembler

import bc "../../bytecode"
import "core:os"
import "core:testing"

@(test)
testing_sysv_abi_assigns_stack_arguments :: proc(t: ^testing.T) {
	types := []bc.Machine_Type{.I64, .I64, .I64, .I64, .I64, .I64, .I64}
	assignment, msg := x64_sysv_assign(types)
	defer delete_x64_assignment(&assignment)
	testing.expectf(t, msg == "", "ABI assignment failed: %s", msg)
	testing.expectf(t, assignment.integer_count == 6 && assignment.stack_count == 1, "counts=%d/%d", assignment.integer_count, assignment.stack_count)
	testing.expectf(t, assignment.locations[6].class == .Stack && assignment.locations[6].stack_offset == 0, "seventh integer location=%v", assignment.locations[6])
	testing.expectf(t, assignment.stack_size == 16, "outgoing stack size=%d", assignment.stack_size)
}

@(test)
testing_sysv_abi_uses_independent_integer_and_sse_sequences :: proc(t: ^testing.T) {
	types := []bc.Machine_Type{.I64, .F64, .I64, .F32, .I64, .F64, .I64}
	assignment, msg := x64_sysv_assign(types)
	defer delete_x64_assignment(&assignment)
	testing.expectf(t, msg == "", "ABI assignment failed: %s", msg)
	testing.expectf(t, assignment.locations[0].register == 0 && assignment.locations[1].register == 0, "first mixed locations=%v/%v", assignment.locations[0], assignment.locations[1])
	testing.expectf(t, assignment.locations[2].register == 1 && assignment.locations[3].register == 1, "second mixed locations=%v/%v", assignment.locations[2], assignment.locations[3])
	testing.expectf(t, assignment.integer_count == 4 && assignment.sse_count == 3 && assignment.stack_count == 0, "counts=%d/%d/%d", assignment.integer_count, assignment.sse_count, assignment.stack_count)
}

@(test)
testing_sysv_abi_classifies_small_aggregates_and_sret :: proc(t: ^testing.T) {
	pair_pieces := make([]bc.BC_Aggregate_Piece, 2)
	pair_pieces[0] = bc.BC_Aggregate_Piece{offset = 0, size = 8, machine = .U64}
	pair_pieces[1] = bc.BC_Aggregate_Piece{offset = 8, size = 8, machine = .U64}
	mixed_pieces := make([]bc.BC_Aggregate_Piece, 2)
	mixed_pieces[0] = bc.BC_Aggregate_Piece{offset = 0, size = 8, machine = .U64}
	mixed_pieces[1] = bc.BC_Aggregate_Piece{offset = 8, size = 8, machine = .F64}
	layouts := []bc.BC_Aggregate_Layout{
		{size = 16, align = 8, pieces = pair_pieces},
		{size = 16, align = 8, pieces = mixed_pieces},
	}
	assignment, msg := x64_sysv_assign([]bc.Machine_Type{.U64, .U64}, layouts)
	defer delete_x64_assignment(&assignment)
	delete(pair_pieces)
	delete(mixed_pieces)
	testing.expectf(t, msg == "", "aggregate ABI assignment failed: %s", msg)
	if msg != "" do return
	testing.expectf(t, assignment.piece_locations[0][0].class == .Integer && assignment.piece_locations[0][1].class == .Integer, "pair classes=%v", assignment.piece_locations[0])
	testing.expectf(t, assignment.piece_locations[1][0].class == .Integer && assignment.piece_locations[1][1].class == .SSE, "mixed classes=%v", assignment.piece_locations[1])
	second, second_msg := x64_sysv_assign([]bc.Machine_Type{.U64}, []bc.BC_Aggregate_Layout{{size = 24, align = 8, memory = true}}, true)
	defer delete_x64_assignment(&second)
	testing.expectf(t, second_msg == "" && second.locations[0].class == .Integer && second.locations[0].register == 1, "sret did not consume RDI: %v %s", second.locations, second_msg)
}

@(test)
testing_named_function_two_register_aggregate_round_trip :: proc(t: ^testing.T) {
	pair := abi_pair_layout()
	defer delete(pair.pieces)
	entry_types := make([dynamic]bc.Machine_Type, 7)
	defer delete(entry_types)
	for i in 0 ..< len(entry_types) do entry_types[i] = .U64
	entry_insts := make([dynamic]bc.BC_Inst)
	defer delete(entry_insts)
	stores := make([]bc.BC_Materialize_Store, 2)
	defer delete(stores)
	stores[0] = bc.BC_Materialize_Store{offset = 0, value = 0, size = 8}
	stores[1] = bc.BC_Materialize_Store{offset = 8, value = 1, size = 8}
	append(&entry_insts,
		bc.BC_Const{dst = 0, imm = 10},
		bc.BC_Const{dst = 1, imm = 20},
		bc.BC_Materialize{dst = 2, slot = 0, size = 16, stores = stores},
		bc.BC_Materialize{dst = 3, slot = 1, size = 16},
	)
	call_args := make([]bc.BC_Value, 1)
	defer delete(call_args)
	call_args[0] = 2
	call_layouts := make([]bc.BC_Aggregate_Layout, 1)
	defer delete(call_layouts)
	call_layouts[0] = pair
	append(&entry_insts, bc.BC_Call{dst = 3, func = 1, args = call_args, arg_layouts = call_layouts, result_layout = pair, has_result_layout = true})
	append(&entry_insts,
		bc.BC_Load{dst = 4, slot = 1, offset = 0, width = 64},
		bc.BC_Load{dst = 5, slot = 1, offset = 8, width = 64},
		bc.BC_Bin{dst = 6, op = .Add, a = 4, b = 5},
		bc.BC_Ret{src = 6},
	)
	callee_types := make([dynamic]bc.Machine_Type, 1)
	defer delete(callee_types)
	callee_types[0] = .U64
	callee_params := make([dynamic]bc.Machine_Type, 1)
	defer delete(callee_params)
	callee_params[0] = .U64
	callee_insts := make([dynamic]bc.BC_Inst, 1)
	defer delete(callee_insts)
	callee_insts[0] = bc.BC_Ret{src = 0}
	callee_scratch := make([dynamic]bc.BC_Scratch_Slot, 1)
	defer delete(callee_scratch)
	callee_scratch[0] = bc.BC_Scratch_Slot{id = 0, size = 16, align = 8}
	entry_scratch := make([dynamic]bc.BC_Scratch_Slot, 2)
	defer delete(entry_scratch)
	entry_scratch[0] = bc.BC_Scratch_Slot{id = 0, size = 16, align = 8}
	entry_scratch[1] = bc.BC_Scratch_Slot{id = 1, size = 16, align = 8}
	param_scratch := make([dynamic]bc.BC_Scratch_Id, 1)
	defer delete(param_scratch)
	param_scratch[0] = 0
	callee := bc.BC_Func{
		id = 1, identity = "pair_identity", params = callee_params[:], param_layouts = call_layouts, param_scratch = param_scratch[:],
		result = .U64, result_layout = pair, has_result_layout = true, insts = callee_insts[:], value_count = 1, value_types = callee_types[:],
		scratch = callee_scratch[:],
	}
	entry := bc.BC_Func{id = 0, identity = "main", result = .U64, insts = entry_insts[:], value_count = len(entry_types), value_types = entry_types[:], scratch = entry_scratch[:]}
	prog := bc.BC_Program{entry = 0}
	append(&prog.funcs, entry, callee)
	path := "/tmp/syntact-abi-aggregate-pair"
	defer os.remove(path)
	msg := emit_executable(&prog, path)
	testing.expectf(t, msg == "", "two-register aggregate emission failed: %s", msg)
	if msg == "" {
		state, _, _, err := os.process_exec({command = []string{path}}, context.temp_allocator)
		testing.expectf(t, err == nil && state.exit_code == 30, "two-register aggregate result: success=%v exit=%d error=%v", state.success, state.exit_code, err)
	}
	delete(prog.funcs)
}

@(test)
testing_named_function_memory_aggregate_sret_round_trip :: proc(t: ^testing.T) {
	big := abi_big_layout()
	defer delete(big.pieces)
	entry_types := make([dynamic]bc.Machine_Type, 10)
	defer delete(entry_types)
	for i in 0 ..< len(entry_types) do entry_types[i] = .U64
	entry_insts := make([dynamic]bc.BC_Inst)
	defer delete(entry_insts)
	stores := make([]bc.BC_Materialize_Store, 3)
	defer delete(stores)
	stores[0] = bc.BC_Materialize_Store{offset = 0, value = 0, size = 8}
	stores[1] = bc.BC_Materialize_Store{offset = 8, value = 1, size = 8}
	stores[2] = bc.BC_Materialize_Store{offset = 16, value = 2, size = 8}
	append(&entry_insts,
		bc.BC_Const{dst = 0, imm = 1}, bc.BC_Const{dst = 1, imm = 2}, bc.BC_Const{dst = 2, imm = 4},
		bc.BC_Materialize{dst = 3, slot = 0, size = 24, stores = stores},
		bc.BC_Materialize{dst = 4, slot = 1, size = 24},
	)
	call_args := make([]bc.BC_Value, 1)
	defer delete(call_args)
	call_args[0] = 3
	call_layouts := make([]bc.BC_Aggregate_Layout, 1)
	defer delete(call_layouts)
	call_layouts[0] = big
	append(&entry_insts, bc.BC_Call{dst = 4, func = 1, args = call_args, arg_layouts = call_layouts, result_layout = big, has_result_layout = true})
	append(&entry_insts,
		bc.BC_Load{dst = 5, slot = 1, offset = 0, width = 64},
		bc.BC_Load{dst = 6, slot = 1, offset = 8, width = 64},
		bc.BC_Load{dst = 7, slot = 1, offset = 16, width = 64},
		bc.BC_Bin{dst = 8, op = .Add, a = 5, b = 6}, bc.BC_Bin{dst = 9, op = .Add, a = 8, b = 7}, bc.BC_Ret{src = 9},
	)
	callee_types := make([dynamic]bc.Machine_Type, 1)
	defer delete(callee_types)
	callee_types[0] = .U64
	callee_params := make([dynamic]bc.Machine_Type, 1)
	defer delete(callee_params)
	callee_params[0] = .U64
	callee_insts := make([dynamic]bc.BC_Inst, 1)
	defer delete(callee_insts)
	callee_insts[0] = bc.BC_Ret{src = 0}
	callee_scratch := make([dynamic]bc.BC_Scratch_Slot, 1)
	defer delete(callee_scratch)
	callee_scratch[0] = bc.BC_Scratch_Slot{id = 0, size = 8, align = 8}
	entry_scratch := make([dynamic]bc.BC_Scratch_Slot, 2)
	defer delete(entry_scratch)
	entry_scratch[0] = bc.BC_Scratch_Slot{id = 0, size = 24, align = 8}
	entry_scratch[1] = bc.BC_Scratch_Slot{id = 1, size = 24, align = 8}
	param_scratch := make([dynamic]bc.BC_Scratch_Id, 1)
	defer delete(param_scratch)
	param_scratch[0] = bc.BC_INVALID_SCRATCH
	callee := bc.BC_Func{
		id = 1, identity = "big_identity", params = callee_params[:], param_layouts = call_layouts, param_scratch = param_scratch[:],
		result = .U64, result_layout = big, has_result_layout = true, sret_slot = 0, insts = callee_insts[:], value_count = 1, value_types = callee_types[:],
		scratch = callee_scratch[:],
	}
	entry := bc.BC_Func{id = 0, identity = "main", result = .U64, insts = entry_insts[:], value_count = len(entry_types), value_types = entry_types[:], scratch = entry_scratch[:]}
	prog := bc.BC_Program{entry = 0}
	append(&prog.funcs, entry, callee)
	path := "/tmp/syntact-abi-aggregate-sret"
	defer os.remove(path)
	msg := emit_executable(&prog, path)
	testing.expectf(t, msg == "", "sret aggregate emission failed: %s", msg)
	if msg == "" {
		state, _, _, err := os.process_exec({command = []string{path}}, context.temp_allocator)
		testing.expectf(t, err == nil && state.exit_code == 7, "sret aggregate result: success=%v exit=%d error=%v", state.success, state.exit_code, err)
	}
	delete(prog.funcs)
}

abi_pair_layout :: proc() -> bc.BC_Aggregate_Layout {
	pieces := make([]bc.BC_Aggregate_Piece, 2)
	pieces[0] = bc.BC_Aggregate_Piece{offset = 0, size = 8, machine = .U64}
	pieces[1] = bc.BC_Aggregate_Piece{offset = 8, size = 8, machine = .U64}
	return bc.BC_Aggregate_Layout{size = 16, align = 8, pieces = pieces}
}

abi_big_layout :: proc() -> bc.BC_Aggregate_Layout {
	return bc.BC_Aggregate_Layout{size = 24, align = 8, memory = true}
}

delete_x64_assignment :: proc(assignment: ^X64_ABI_Assignment) {
	delete(assignment.locations)
	for parts in assignment.piece_locations do if parts != nil do delete(parts)
	delete(assignment.piece_locations)
}

@(test)
testing_named_function_call_uses_sysv_stack_arguments :: proc(t: ^testing.T) {
	callee_insts := make([dynamic]bc.BC_Inst)
	callee_types := make([dynamic]bc.Machine_Type, 13)
	callee_params := make([dynamic]bc.Machine_Type, 7)
	entry_insts := make([dynamic]bc.BC_Inst)
	entry_types := make([dynamic]bc.Machine_Type, 8)
	args := make([dynamic]bc.BC_Value)
	defer delete(callee_insts)
	defer delete(callee_types)
	defer delete(callee_params)
	defer delete(entry_insts)
	defer delete(entry_types)
	defer delete(args)
	for i in 0 ..< 13 do callee_types[i] = .I64
	for i in 0 ..< 7 do callee_params[i] = .I64
	for i in 0 ..< 8 do entry_types[i] = .I64
	append(&callee_insts, bc.BC_Bin{dst = 7, op = .Add, a = 0, b = 1})
	for i in 2 ..< 7 {
		append(&callee_insts, bc.BC_Bin{dst = bc.BC_Value(6 + i), op = .Add, a = bc.BC_Value(5 + i), b = bc.BC_Value(i)})
	}
	append(&callee_insts, bc.BC_Ret{src = 12})
	for i in 0 ..< 7 {
		append(&entry_insts, bc.BC_Const{dst = bc.BC_Value(i), imm = i64(i + 1)})
		append(&args, bc.BC_Value(i))
	}
	append(&entry_insts, bc.BC_Call{dst = 7, func = 1, args = args[:]})
	append(&entry_insts, bc.BC_Ret{src = 7})

	entry := bc.BC_Func{id = 0, identity = "main", result = .I64, insts = entry_insts[:], value_count = 8, value_types = entry_types[:]}
	callee := bc.BC_Func{id = 1, identity = "sum7", params = callee_params[:], result = .I64, insts = callee_insts[:], value_count = 13, value_types = callee_types[:]}
	prog := bc.BC_Program{entry = 0}
	append(&prog.funcs, entry, callee)
	path := "/tmp/syntact-abi-internal-7"
	defer os.remove(path)
	msg := emit_executable(&prog, path)
	testing.expectf(t, msg == "", "internal 7-argument emission failed: %s", msg)
	if msg != "" do return
	state, _, _, err := os.process_exec({command = []string{path}}, context.temp_allocator)
	testing.expectf(t, err == nil && state.exit_code == 28, "internal 7-argument result: success=%v exit=%d error=%v", state.success, state.exit_code, err)
	delete(prog.funcs)
}

@(test)
testing_foreign_call_preserves_live_values :: proc(t: ^testing.T) {
	prog := bc_program_for_abi(4, .I64)
	defer delete_abi_program(&prog)
	append(&prog.insts, bc.BC_Const{dst = 0, imm = 7})
	append(&prog.insts, bc.BC_Foreign_Call{dst = 1, slot = 0, args = []bc.BC_Value{0}})
	append(&prog.insts, bc.BC_Bin{dst = 2, op = .Add, a = 0, b = 1})
	append(&prog.insts, bc.BC_Ret{src = 2})

	alloc := allocate_registers(&prog)
	defer delete(alloc.locs)

	loc := alloc.locs[0]
	testing.expectf(
		t,
		loc.kind == .Register && reg_is_call_preserved(loc.reg),
		"value live across foreign call was allocated to %v",
		loc,
	)
	for r in ALLOCATABLE_REGS {
		testing.expectf(t, r != .R10, "reserved GOT scratch R10 is allocatable")
	}
}

@(test)
testing_foreign_call_aligns_spill_frame :: proc(t: ^testing.T) {
	prog := bc_program_for_abi(12, .I64)
	defer delete_abi_program(&prog)
	for i in 0 ..< 6 {
		append(&prog.insts, bc.BC_Const{dst = bc.BC_Value(i), imm = i64(i + 1)})
	}
	append(&prog.insts, bc.BC_Foreign_Call{dst = 6, slot = 0})
	append(&prog.insts, bc.BC_Bin{dst = 7, op = .Add, a = 0, b = 1})
	append(&prog.insts, bc.BC_Bin{dst = 8, op = .Add, a = 7, b = 2})
	append(&prog.insts, bc.BC_Bin{dst = 9, op = .Add, a = 8, b = 3})
	append(&prog.insts, bc.BC_Bin{dst = 10, op = .Add, a = 9, b = 4})
	append(&prog.insts, bc.BC_Bin{dst = 11, op = .Add, a = 10, b = 5})
	append(&prog.insts, bc.BC_Ret{src = 11})

	alloc := allocate_registers(&prog)
	testing.expectf(t, alloc.stack_size > 0, "test program did not create spill pressure")
	delete(alloc.locs)

	out, msg := emit_x64(&prog)
	defer delete(out.code)
	defer delete(out.rodata)
	testing.expectf(t, msg == "", "emit failed: %s", msg)
	// and rsp, -16: 48 81 e4 f0 ff ff ff. It must be present in the
	// spill-frame prologue before the foreign call.
	testing.expectf(t, contains_bytes(out.code, []u8{0x48, 0x81, 0xE4, 0xF0, 0xFF, 0xFF, 0xFF}), "foreign-call spill frame is not aligned")
}

@(test)
testing_foreign_float_call_keeps_value_out_of_xmm_clobbers :: proc(t: ^testing.T) {
	prog := bc_program_for_abi(3, .F64)
	defer delete_abi_program(&prog)
	append(&prog.insts, bc.BC_Const_F{dst = 0, fimm = 1.25})
	append(&prog.insts, bc.BC_Foreign_Call{dst = 1, slot = 0, args = []bc.BC_Value{0}})
	append(&prog.insts, bc.BC_Bin{dst = 2, op = .Add, a = 0, b = 1})
	append(&prog.insts, bc.BC_Ret{src = 2})

	alloc := allocate_registers(&prog)
	defer delete(alloc.locs)

	loc := alloc.locs[0]
	// Float values are represented as GPR-held bit patterns between operations;
	// XMM0-XMM15 are transient and therefore safely call-clobbered.
	testing.expectf(t, loc.kind == .Register && reg_is_call_preserved(loc.reg), "float value live across foreign call was allocated to %v", loc)
}

@(test)
testing_native_strings_are_terminated_without_length_change :: proc(t: ^testing.T) {
	prog := bc_program_for_abi(1, .Str)
	defer delete_abi_program(&prog)
	append(&prog.rodata, "abc")
	append(&prog.insts, bc.BC_Str_Const{dst = 0, bytes = "abc", id = 0})
	append(&prog.insts, bc.BC_Ret{src = 0})

	out, msg := emit_x64(&prog)
	defer delete(out.code)
	defer delete(out.rodata)
	testing.expectf(t, msg == "", "emit failed: %s", msg)
	testing.expectf(t, len(out.rodata) == 4, "expected one terminator, got rodata length %d", len(out.rodata))
	testing.expectf(t, out.rodata[0] == 'a' && out.rodata[1] == 'b' && out.rodata[2] == 'c' && out.rodata[3] == 0, "string literal is not NUL-terminated")
	// emit_exit must still pass the logical length (3), not len(rodata) (4).
	testing.expectf(t, contains_bytes(out.code, []u8{0xBA, 0x03, 0x00, 0x00, 0x00}), "string write length includes the terminator")
}

bc_program_for_abi :: proc(value_count: int, result_type: bc.Machine_Type) -> bc.BC_Program {
	types := make([dynamic]bc.Machine_Type, value_count)
	for i in 0 ..< value_count do types[i] = result_type
	return bc.BC_Program{value_count = value_count, value_types = types, result_type = result_type}
}

delete_abi_program :: proc(prog: ^bc.BC_Program) {
	delete(prog.insts)
	delete(prog.value_types)
	delete(prog.rodata)
	delete(prog.imports)
}

reg_is_call_preserved :: proc(reg: Register64) -> bool {
	for preserved in CALL_PRESERVED_REGS {
		if reg == preserved do return true
	}
	return false
}

contains_bytes :: proc(haystack, needle: []u8) -> bool {
	if len(needle) == 0 do return true
	if len(needle) > len(haystack) do return false
	for i := 0; i <= len(haystack) - len(needle); i += 1 {
		match := true
		for j in 0 ..< len(needle) {
			if haystack[i + j] != needle[j] {
				match = false
				break
			}
		}
		if match do return true
	}
	return false
}
