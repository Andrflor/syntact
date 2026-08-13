package codegen_test

import compiler "../../compiler"
import bc "../../compiler/bytecode"
import x64 "../../compiler/backends/x64"
import vmem "core:mem/virtual"
import "core:os"
import "core:testing"

@(test)
test_named_function_call_and_loop_frame :: proc(t: ^testing.T) {
	callee_insts := make([dynamic]bc.BC_Inst)
	callee_types := make([dynamic]bc.Machine_Type)
	callee_params := make([dynamic]bc.Machine_Type)
	entry_insts := make([dynamic]bc.BC_Inst)
	entry_types := make([dynamic]bc.Machine_Type)
	call_args := make([dynamic]bc.BC_Value)
	loop_insts := make([dynamic]bc.BC_Inst)
	loop_types := make([dynamic]bc.Machine_Type)
	loop_exits := make([dynamic]bc.BC_Label)
	loop_infos := make([dynamic]bc.Loop_Info)
	defer delete(callee_insts)
	defer delete(callee_types)
	defer delete(callee_params)
	defer delete(entry_insts)
	defer delete(entry_types)
	defer delete(call_args)
	defer delete(loop_insts)
	defer delete(loop_types)
	defer delete(loop_exits)
	defer delete(loop_infos)
	append(&callee_params, bc.Machine_Type.I64)
	append(&callee_types, bc.Machine_Type.I64)
	append(&callee_types, bc.Machine_Type.I64)
	append(&callee_insts, bc.BC_Bin_Imm{dst = 1, op = .Add, a = 0, imm = 1})
	append(&callee_insts, bc.BC_Ret{src = 1})
	append(&call_args, 0)
	append(&entry_types, bc.Machine_Type.I64)
	append(&entry_types, bc.Machine_Type.I64)
	append(&entry_insts, bc.BC_Const{dst = 0, imm = 41})
	append(&entry_insts, bc.BC_Call{dst = 1, func = 1, args = call_args[:]})
	append(&entry_insts, bc.BC_Ret{src = 1})
	append(&loop_types, bc.Machine_Type.I64)
	append(&loop_types, bc.Machine_Type.U8)
	append(&loop_types, bc.Machine_Type.I64)
	append(&loop_exits, 1)
	append(&loop_infos, bc.Loop_Info{header = 0, latch = 1, exits = loop_exits[:]})
	append(&loop_insts,
		bc.BC_Const{dst = 0, imm = 3},
		bc.BC_Label_Def{label = 0},
		bc.BC_Cmp_Imm{dst = 1, op = .Equal, a = 0, imm = 0},
		bc.BC_Branch_Zero{cond = 1, target = 1},
		bc.BC_Ret{src = 0},
		bc.BC_Label_Def{label = 1},
		bc.BC_Bin_Imm{dst = 2, op = .Subtract, a = 0, imm = 1},
		bc.BC_Move{dst = 0, src = 2},
		bc.BC_Jump{target = 0},
	)
	callee := bc.BC_Func{
		id = 1,
		identity = "inc",
		params = callee_params[:],
		result = .I64,
		insts = callee_insts[:],
		value_count = 2,
		value_types = callee_types[:],
	}
	entry := bc.BC_Func{
		id = 0,
		identity = "main",
		result = .I64,
		insts = entry_insts[:],
		value_count = 2,
		value_types = entry_types[:],
	}
	prog := bc.BC_Program{entry = 0}
	append(&prog.funcs, entry)
	append(&prog.funcs, callee)
	r := bc.interp_bytecode(&prog, nil)
	testing.expectf(t, r.ok && r.value == 42, "named call result=%d error=%s", r.value, r.error)

	loop := bc.BC_Func{
		id = 2,
		identity = "countdown",
		result = .I64,
		insts = loop_insts[:],
		value_count = 3,
		value_types = loop_types[:],
		label_count = 2,
		loops = loop_infos[:],
	}
	prog.funcs[0] = loop
	resize(&prog.funcs, 1)
	prog.entry = 2
	r = bc.interp_bytecode(&prog, nil)
	testing.expectf(t, r.ok && r.value == 0, "loop result=%d error=%s", r.value, r.error)
	delete(prog.funcs)
}

@(test)
test_materialize_uses_declared_aggregate_layout :: proc(t: ^testing.T) {
	// This is the neutral shape a foreign aggregate lowering must produce: the
	// address is an SSA result, while storage remains an abstract local slot.
	stores := make([dynamic]bc.BC_Materialize_Store)
	inputs := make([dynamic]bc.BC_Value)
	defer delete(stores)
	defer delete(inputs)
	append(&stores,
		bc.BC_Materialize_Store{offset = 0, value = 0, size = 4},
		bc.BC_Materialize_Store{offset = 8, value = 1, size = 8},
		bc.BC_Materialize_Store{offset = 16, value = 2, size = 4},
	)
	append(&inputs, 0, 1, 2)
	insts := make([dynamic]bc.BC_Inst)
	types := make([dynamic]bc.Machine_Type)
	slots := make([dynamic]bc.BC_Scratch_Slot)
	defer delete(insts)
	defer delete(types)
	defer delete(slots)
	append(&types, bc.Machine_Type.U32, bc.Machine_Type.U64, bc.Machine_Type.U32, bc.Machine_Type.U64)
	append(&slots, bc.BC_Scratch_Slot{id = 0, size = 24, align = 8})
	append(&insts,
		bc.BC_Const{dst = 0, imm = 7},
		bc.BC_Const{dst = 1, imm = 9},
		bc.BC_Const{dst = 2, imm = 11},
		bc.BC_Materialize{dst = 3, slot = 0, size = 24, stores = stores[:], inputs = inputs[:]},
		bc.BC_Ret{src = 3},
	)
	prog := bc.BC_Program{
		insts = insts,
		value_count = 4,
		value_types = types,
		result_type = .U64,
		scratch = slots,
	}
	out, msg := x64.emit_x64(&prog)
	defer delete(out.code)
	defer delete(out.rodata)
	testing.expectf(t, msg == "", "materialization emission failed: %s", msg)
	testing.expectf(t, out.scratch_size == 32, "scratch plan size=%d, want 32", out.scratch_size)
	testing.expectf(t, len(out.code) > 0, "materialization emitted no native code")
}

@(test)
test_lowering_materializes_large_foreign_input :: proc(t: ^testing.T) {
	arena: vmem.Arena
	defer vmem.arena_destroy(&arena)
	previous_allocator := context.allocator
	context.allocator = vmem.arena_allocator(&arena)
	defer context.allocator = previous_allocator

	source := "Big -> {\n  u32:a -> 1\n  u64:b -> 2\n  u32:c -> 3\n}\nlib -> <libc.so.6>{ take -> { Big:value, -> ??::u64 } }\n-> lib.take{value -> Big{a -> 7 b -> 9 c -> 11}}!"
	cache := new(compiler.Cache)
	ast, _ := compiler.parse(cache, source)
	analyzer := compiler.create_analyzer(ast)
	phase := compiler.Phase_Context{analyzer = &analyzer}
	previous_user_ptr := context.user_ptr
	context.user_ptr = &phase
	defer context.user_ptr = previous_user_ptr
	_ = compiler.analyze(cache)
	reducer := compiler.create_reducer()
	phase.reducer = &reducer
	result := compiler.reduce(cache.scope)
	prog := compiler.lower_to_bytecode(result)

	error := prog != nil ? prog.error : "nil bytecode"
	testing.expectf(t, prog != nil && prog.error == "", "aggregate lowering error: %s", error)
	if prog == nil || prog.error != "" do return
	testing.expectf(t, len(prog.scratch) == 1, "scratch slots=%d, want 1", len(prog.scratch))
	for inst in prog.insts {
		if materialize, ok := inst.(bc.BC_Materialize); ok {
			testing.expectf(t, materialize.size == 24, "materialized size=%d, want 24", materialize.size)
			testing.expectf(t, len(materialize.stores) == 3, "materialized stores=%d, want 3", len(materialize.stores))
			if len(materialize.stores) == 3 {
				testing.expectf(t, materialize.stores[0].offset == 0 && materialize.stores[0].size == 4, "first field layout=%v", materialize.stores[0])
				testing.expectf(t, materialize.stores[1].offset == 8 && materialize.stores[1].size == 8, "second field layout=%v", materialize.stores[1])
				testing.expectf(t, materialize.stores[2].offset == 16 && materialize.stores[2].size == 4, "third field layout=%v", materialize.stores[2])
			}
			return
		}
	}
	testing.expectf(t, false, "lowering emitted no BC_Materialize")
}

@(test)
test_neutral_rodata_blob_address_is_global :: proc(t: ^testing.T) {
	data := make([]u8, 4)
	defer delete(data)
	data[0], data[1], data[2], data[3] = 0x00, 0x3F, 0x80, 0x00
	prog := bc.BC_Program{}
	defer delete(prog.rodata_blobs)
	defer delete(prog.insts)
	defer delete(prog.value_types)
	blob := bc.BC_Append_Rodata_Blob(&prog, data, 4)
	append(&prog.value_types, bc.Machine_Type.U64)
	prog.value_count = 1
	prog.result_type = .U64
	append(&prog.insts, bc.BC_Rodata_Address{dst = 0, blob = blob, offset = 0}, bc.BC_Ret{src = 0})
	out, msg := x64.emit_x64(&prog)
	defer delete(out.code)
	defer delete(out.rodata)
	testing.expectf(t, msg == "", "blob address emission failed: %s", msg)
	testing.expectf(t, len(out.rodata) == 4 && out.rodata[1] == 0x3F, "neutral blob bytes were not preserved")
}

@(test)
test_native_memcmp_of_materialized_aggregates :: proc(t: ^testing.T) {
	arena: vmem.Arena
	defer vmem.arena_destroy(&arena)
	previous_allocator := context.allocator
	context.allocator = vmem.arena_allocator(&arena)
	defer context.allocator = previous_allocator

	source := "Big -> {\n  u32:a -> 1\n  u64:b -> 2\n  u32:c -> 3\n}\nlib -> <libc.so.6>{\n  memcmp -> {\n    Big:left =<< Big{a -> 1 b -> 2 c -> 3}\n    Big:right\n    u64:size\n    -> ??::i32\n  }\n}\n-> lib.memcmp{left -> Big{a -> 1 b -> 2 c -> 3} right -> Big{a -> 1 b -> 2 c -> 3} size -> 24}!"
	cache := new(compiler.Cache)
	ast, _ := compiler.parse(cache, source)
	analyzer := compiler.create_analyzer(ast)
	phase := compiler.Phase_Context{analyzer = &analyzer}
	previous_user_ptr := context.user_ptr
	context.user_ptr = &phase
	defer context.user_ptr = previous_user_ptr
	_ = compiler.analyze(cache)
	reducer := compiler.create_reducer()
	phase.reducer = &reducer
	result := compiler.reduce(cache.scope)
	prog := compiler.lower_to_bytecode(result)
	context.user_ptr = previous_user_ptr
	if prog == nil || prog.error != "" {
		testing.expectf(t, false, "native aggregate lowering error: %s", prog != nil ? prog.error : "nil bytecode")
		return
	}
	borrowed_seen := false
	for inst in prog.insts {
		if materialize, ok := inst.(bc.BC_Materialize); ok do borrowed_seen = borrowed_seen || materialize.borrowed
	}
	testing.expectf(t, borrowed_seen, "reactive-pull aggregate was not marked borrowed")

	path := "/tmp/syntact-roadmap-aggregate"
	emsg := x64.emit_executable(prog, path)
	defer os.remove(path)
	if emsg != "" {
		testing.expectf(t, false, "native aggregate emission error: %s", emsg)
		return
	}
	state, _, _, err := os.process_exec({command = []string{path}}, context.temp_allocator)
	testing.expectf(t, err == nil && state.success && state.exit_code == 0, "native memcmp aggregate result: success=%v exit=%d error=%v", state.success, state.exit_code, err)
}

@(test)
test_unsupported_aggregate_abi_shapes_are_diagnosed :: proc(t: ^testing.T) {
	expect_aggregate_abi_error(t, "Pair -> {\n  str:a -> \"value\"\n  u32:b -> 2\n}\nlib -> <libc.so.6>{ take -> { Pair:value, -> ??::u64 } }\n-> lib.take{value -> Pair{a -> \"value\" b -> 2}}!")
	expect_aggregate_abi_error(t, "Pair -> {\n  str:a -> \"value\"\n  u32:b -> 2\n}\nlib -> <libc.so.6>{ make -> { -> Pair } }\n-> lib.make!")
}

expect_aggregate_abi_error :: proc(t: ^testing.T, source: string) {
	arena: vmem.Arena
	defer vmem.arena_destroy(&arena)
	previous_allocator := context.allocator
	context.allocator = vmem.arena_allocator(&arena)
	defer context.allocator = previous_allocator

	cache := new(compiler.Cache)
	ast, _ := compiler.parse(cache, source)
	analyzer := compiler.create_analyzer(ast)
	phase := compiler.Phase_Context{analyzer = &analyzer}
	previous_user_ptr := context.user_ptr
	context.user_ptr = &phase
	defer context.user_ptr = previous_user_ptr
	_ = compiler.analyze(cache)
	reducer := compiler.create_reducer()
	phase.reducer = &reducer
	result := compiler.reduce(cache.scope)
	prog := compiler.lower_to_bytecode(result)
	testing.expectf(t, prog != nil && prog.error != "", "unsupported aggregate ABI shape was lowered without a diagnostic")
}
