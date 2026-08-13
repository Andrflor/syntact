package ffi_test

import compiler "../../compiler"
import x64 "../../compiler/backends/x64"
import bc "../../compiler/bytecode"
import "core:dynlib"
import "core:fmt"
import vmem "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

Pair :: struct {
	a: u64,
	b: u64,
}

Mixed :: struct {
	a: u64,
	b: f64,
}

Big :: struct {
	a: u64,
	b: u64,
	c: u64,
}

// Fixture is the stable symbol surface shared by native-only FFI tests.
Fixture :: struct {
	handle:          dynlib.Library,
	clobber_pair:    proc "c" (u64, u64) -> u64 `dynlib:"syntact_ffi_clobber_pair"`,
	stack_alignment: proc "c" () -> u64 `dynlib:"syntact_ffi_stack_alignment_probe"`,
	cstring_contract: proc "c" (cstring, u64) -> u64 `dynlib:"syntact_ffi_cstring_contract"`,
	sum_seven:       proc "c" (u64, u64, u64, u64, u64, u64, u64) -> u64 `dynlib:"syntact_ffi_sum_seven"`,
	sum_mixed:       proc "c" (u64, f64, u64, f32, u64, f64, u64) -> u64 `dynlib:"syntact_ffi_sum_mixed"`,
	stack_seven:     proc "c" (u64, u64, u64, u64, u64, u64, u64) -> u64 `dynlib:"syntact_ffi_stack_alignment_seven"`,
	make_pair:       proc "c" () -> Pair `dynlib:"syntact_ffi_make_pair"`,
	take_pair:       proc "c" (Pair) -> u64 `dynlib:"syntact_ffi_take_pair"`,
	make_mixed:      proc "c" () -> Mixed `dynlib:"syntact_ffi_make_mixed"`,
	take_mixed:      proc "c" (Mixed) -> u64 `dynlib:"syntact_ffi_take_mixed"`,
	make_big:        proc "c" () -> Big `dynlib:"syntact_ffi_make_big"`,
}

fixture_source_path :: proc() -> string {
	dir := filepath.dir(#location().file_path)
	path, _ := filepath.join({dir, "fixture.c"}, context.temp_allocator)
	return path
}

fixture_output_path :: proc(label: string) -> string {
	return fmt.tprintf("/tmp/syntact_ffi_fixture_%d_%s.so.6", os.get_pid(), label)
}

// build_fixture compiles only the checked-in C source.  The resulting shared
// object is always outside the repository and is removed by close_fixture.
build_fixture :: proc(t: ^testing.T, label: string) -> (Fixture, string, bool) {
	source := fixture_source_path()
	output := fixture_output_path(label)
	if !build_fixture_library(t, source, output) do return {}, "", false

	fixture: Fixture
	count, loaded := dynlib.initialize_symbols(&fixture, output, "", "handle")
	if !loaded || count != 11 {
		testing.expectf(t, false, "loading FFI fixture failed: loaded=%v symbols=%d error=%s", loaded, count, dynlib.last_error())
		return {}, "", false
	}
	return fixture, output, true
}

build_fixture_library :: proc(t: ^testing.T, source, output: string) -> bool {
	command := []string {
		"cc",
		"-shared",
		"-fPIC",
		"-O2",
		"-std=c11",
		source,
		"-o",
		output,
	}
	state, _, stderr, err := os.process_exec({command = command}, context.temp_allocator)
	if err != nil {
		testing.expectf(t, false, "building FFI fixture failed: %v", err)
		return false
	}
	if !state.success {
		testing.expectf(t, false, "building FFI fixture exited with %d: %s", state.exit_code, strings.trim_space(string(stderr)))
		return false
	}
	return true
}

@(test)
test_ffi_struct_return_and_argument_fixture :: proc(t: ^testing.T) {
	fixture, output, ok := build_fixture(t, "aggregate-direct")
	if !ok do return
	defer close_fixture(&fixture, output)
	pair := fixture.make_pair()
	mixed := fixture.make_mixed()
	testing.expectf(t, fixture.take_pair(pair) == 7, "two-register integer aggregate round-trip failed")
	testing.expectf(t, fixture.take_mixed(mixed) == 7, "mixed integer/SSE aggregate round-trip failed")
}

@(test)
test_ffi_generated_syntact_aggregate_abi :: proc(t: ^testing.T) {
	_, output, ok := build_fixture(t, "aggregate_syntact")
	if !ok do return
	defer os.remove(output)
	library := output
	run_aggregate_source(t, fmt.tprintf("Pair -> {{\n  u64:a -> 0\n  u64:b -> 0\n}}\nlib -> <%s>{{\n  syntact_ffi_make_pair -> {{ -> Pair }}\n  syntact_ffi_take_pair -> {{ Pair:value, -> ??::u64 }}\n}}\n-> lib.syntact_ffi_take_pair{{value -> lib.syntact_ffi_make_pair!}}!", library), output, 7)
	run_aggregate_source(t, fmt.tprintf("Mixed -> {{\n  u64:a -> 0\n  f64:b -> 0.0\n}}\nlib -> <%s>{{\n  syntact_ffi_make_mixed -> {{ -> Mixed }}\n  syntact_ffi_take_mixed -> {{ Mixed:value, -> ??::u64 }}\n}}\n-> lib.syntact_ffi_take_mixed{{value -> lib.syntact_ffi_make_mixed!}}!", library), output, 7)
	run_aggregate_source(t, fmt.tprintf("Big -> {{\n  u64:a -> 0\n  u64:b -> 0\n  u64:c -> 0\n}}\nlib -> <%s>{{\n  syntact_ffi_make_big -> {{ -> Big }}\n  syntact_ffi_take_big -> {{ Big:value, -> ??::u64 }}\n}}\n-> lib.syntact_ffi_take_big{{value -> lib.syntact_ffi_make_big!}}!", library), output, 7)
	run_aggregate_source(t, fmt.tprintf("SsePair -> {{\n  f64:a -> 0.0\n  f64:b -> 0.0\n}}\nlib -> <%s>{{\n  syntact_ffi_make_sse_pair -> {{ -> SsePair }}\n  syntact_ffi_take_sse_pair -> {{ SsePair:value, -> ??::u64 }}\n}}\n-> lib.syntact_ffi_take_sse_pair{{value -> lib.syntact_ffi_make_sse_pair!}}!", library), output, 1)
	run_aggregate_source(t, fmt.tprintf("F32Pair -> {{\n  f32:a -> 0.0\n  f32:b -> 0.0\n}}\nlib -> <%s>{{\n  syntact_ffi_make_f32_pair -> {{ -> F32Pair }}\n  syntact_ffi_take_f32_pair -> {{ F32Pair:value, -> ??::u64 }}\n}}\n-> lib.syntact_ffi_take_f32_pair{{value -> lib.syntact_ffi_make_f32_pair!}}!", library), output, 1)
	run_aggregate_source(t, fmt.tprintf("Big -> {{\n  u64:a -> 0\n  u64:b -> 0\n  u64:c -> 0\n}}\nlib -> <%s>{{\n  syntact_ffi_make_big_with_args -> {{ u64:a, u64:b, u64:c, u64:d, u64:e, u64:f, u64:g, -> Big }}\n  syntact_ffi_take_big -> {{ Big:value, -> ??::u64 }}\n}}\n-> lib.syntact_ffi_take_big{{value -> lib.syntact_ffi_make_big_with_args{{a -> 1 b -> 2 c -> 3 d -> 4 e -> 5 f -> 6 g -> 7}}!}}!", library), output, 36)
}

run_aggregate_source :: proc(t: ^testing.T, source, library_path: string, expected: int) {
	run_syntact_source(t, source, library_path, expected, "aggregate")
}

run_syntact_source :: proc(t: ^testing.T, source, library_path: string, expected: int, label: string) {
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
	analyze_ok := compiler.analyze(cache)
	if !analyze_ok {
		testing.expectf(t, false, "generated aggregate analysis error: %v\nsource:\n%s", cache.analyze_errors, source)
		return
	}
	reducer := compiler.create_reducer()
	phase.reducer = &reducer
	context.user_ptr = &phase
	result := compiler.reduce(cache.scope)
	prog := compiler.lower_to_bytecode(result)
	if prog == nil || prog.error != "" {
		testing.expectf(t, false, "generated aggregate lowering error: %s", prog != nil ? prog.error : "nil bytecode")
		return
	}
	path := fmt.tprintf("/tmp/syntact-ffi-%d-%s", os.get_pid(), label)
	defer os.remove(path)
	message := x64.emit_executable(prog, path)
	testing.expectf(t, message == "", "generated aggregate emission error: %s\n%s", message, bc.bytecode_to_string(prog))
	if message != "" do return
	library_dir := filepath.dir(library_path)
	state, _, stderr, err := os.process_exec({command = []string{"env", fmt.tprintf("LD_LIBRARY_PATH=%s", library_dir), path}}, context.temp_allocator)
	testing.expectf(t, err == nil && state.exit_code == expected, "generated aggregate result: success=%v exit=%d error=%v stderr=%s\n%s", state.success, state.exit_code, err, strings.trim_space(string(stderr)), bc.bytecode_to_string(prog))
}

@(test)
test_ffi_generated_scalar_width_and_float_matrix :: proc(t: ^testing.T) {
	source := fixture_source_path()
	output := fixture_output_path("generated-scalars")
	if !build_fixture_library(t, source, output) do return
	defer os.remove(output)

	cases := []struct {symbol, constraint, value, label: string} {
		{"syntact_ffi_check_i8", "i8", "-1", "i8"},
		{"syntact_ffi_check_u8", "u8", "255", "u8"},
		{"syntact_ffi_check_i16", "i16", "-12345", "i16"},
		{"syntact_ffi_check_u16", "u16", "54321", "u16"},
		{"syntact_ffi_check_i32", "i32", "-1234567", "i32"},
		{"syntact_ffi_check_u32", "u32", "4000000000", "u32"},
		{"syntact_ffi_check_i64", "i64", "-123456789012345", "i64"},
		{"syntact_ffi_check_u64", "u64", "123456789012345", "u64"},
		{"syntact_ffi_check_f32", "f32", "1.5", "f32"},
		{"syntact_ffi_check_f64", "f64", "-2.25", "f64"},
	}
	for tc in cases {
		source_text := fmt.tprintf("lib -> <%s>{{ %s -> {{ %s:value, -> ??::u64 }} }}\n-> lib.%s{{value -> %s}}!", output, tc.symbol, tc.constraint, tc.symbol, tc.value)
		run_syntact_source(t, source_text, output, 1, tc.label)
	}
}

@(test)
test_ffi_generated_cstring_argument :: proc(t: ^testing.T) {
	run_generated_fixture_case(t, "cstring", "lib -> <%s>{{ syntact_ffi_check_cstring -> {{ string:value, u64:expected, -> ??::u64 }} }}\n-> lib.syntact_ffi_check_cstring{{value -> \"syntact\" expected -> 7}}!", 1)
}

@(test)
test_ffi_generated_seven_integer_arguments :: proc(t: ^testing.T) {
	run_generated_fixture_case(t, "seven", "lib -> <%s>{{ syntact_ffi_sum_seven -> {{ u64:a, u64:b, u64:c, u64:d, u64:e, u64:f, u64:g, -> ??::u64 }} }}\n-> lib.syntact_ffi_sum_seven{{a -> 1 b -> 2 c -> 3 d -> 4 e -> 5 f -> 6 g -> 7}}!", 28)
}

@(test)
test_ffi_generated_multiple_stack_integer_arguments :: proc(t: ^testing.T) {
	run_generated_fixture_case(t, "ten-integer", "lib -> <%s>{{ syntact_ffi_sum_ten -> {{ u64:a, u64:b, u64:c, u64:d, u64:e, u64:f, u64:g, u64:h, u64:i, u64:j, -> ??::u64 }} }}\n-> lib.syntact_ffi_sum_ten{{a -> 1 b -> 2 c -> 3 d -> 4 e -> 5 f -> 6 g -> 7 h -> 8 i -> 9 j -> 10}}!", 55)
}

@(test)
test_ffi_generated_mixed_integer_sse_arguments :: proc(t: ^testing.T) {
	run_generated_fixture_case(t, "mixed", "lib -> <%s>{{ syntact_ffi_sum_mixed -> {{ u64:a, f64:b, u64:c, f32:d, u64:e, f64:f, u64:g, -> ??::u64 }} }}\n-> lib.syntact_ffi_sum_mixed{{a -> 1 b -> 2.0 c -> 3 d -> 4.0 e -> 5 f -> 6.0 g -> 7}}!", 28)
}

@(test)
test_ffi_generated_multiple_stack_mixed_arguments :: proc(t: ^testing.T) {
	run_generated_fixture_case(t, "many-mixed", "lib -> <%s>{{ syntact_ffi_sum_mixed_many -> {{ u64:a, f64:b, u64:c, f32:d, u64:e, f64:f, u64:g, f32:h, u64:i, f64:j, -> ??::u64 }} }}\n-> lib.syntact_ffi_sum_mixed_many{{a -> 1 b -> 2.0 c -> 3 d -> 4.0 e -> 5 f -> 6.0 g -> 7 h -> 8.0 i -> 9 j -> 10.0}}!", 55)
}

@(test)
test_ffi_generated_integer_aggregate_after_register_exhaustion :: proc(t: ^testing.T) {
	run_generated_fixture_case(t, "pair-after-six", "Pair -> {{ u64:a -> 0 u64:b -> 0 }}\nlib -> <%s>{{ syntact_ffi_take_pair_after_six -> {{ u64:a, u64:b, u64:c, u64:d, u64:e, u64:f, Pair:value, -> ??::u64 }} }}\n-> lib.syntact_ffi_take_pair_after_six{{a -> 1 b -> 2 c -> 3 d -> 4 e -> 5 f -> 6 value -> Pair{{a -> 7 b -> 8}}}}!", 1)
}

@(test)
test_ffi_generated_sse_aggregate_after_register_exhaustion :: proc(t: ^testing.T) {
	run_generated_fixture_case(t, "sse-pair-after-seven", "SsePair -> {{ f64:a -> 0.0 f64:b -> 0.0 }}\nlib -> <%s>{{ syntact_ffi_take_sse_pair_after_seven -> {{ f64:a, f64:b, f64:c, f64:d, f64:e, f64:f, f64:g, SsePair:value, -> ??::u64 }} }}\n-> lib.syntact_ffi_take_sse_pair_after_seven{{a -> 1.0 b -> 2.0 c -> 3.0 d -> 4.0 e -> 5.0 f -> 6.0 g -> 7.0 value -> SsePair{{a -> 1.25 b -> 2.5}}}}!", 1)
}

@(test)
test_ffi_generated_stack_alignment_with_seven_arguments :: proc(t: ^testing.T) {
	run_generated_fixture_case(t, "alignment", "lib -> <%s>{{ syntact_ffi_stack_alignment_seven -> {{ u64:a, u64:b, u64:c, u64:d, u64:e, u64:f, u64:g, -> ??::u64 }} }}\n-> lib.syntact_ffi_stack_alignment_seven{{a -> 1 b -> 2 c -> 3 d -> 4 e -> 5 f -> 6 g -> 7}}!", 1)
}

@(test)
test_ffi_generated_caller_clobber_with_live_values :: proc(t: ^testing.T) {
	run_generated_fixture_case(t, "clobber", "lib -> <%s>{{ syntact_ffi_clobber_pair -> {{ u64:left, u64:right, -> ??::u64 }} }}\nprogram -> {{ seed -> 19 first -> lib.syntact_ffi_clobber_pair{{left -> seed right -> 7}}! second -> lib.syntact_ffi_clobber_pair{{left -> seed right -> 11}}! -> seed + first + second }}\n-> program!", 75)
}

run_generated_fixture_case :: proc(t: ^testing.T, label, source_format: string, expected: int) {
	source := fixture_source_path()
	output := fixture_output_path(fmt.tprintf("generated-%s", label))
	if !build_fixture_library(t, source, output) do return
	defer os.remove(output)
	run_syntact_source(t, fmt.tprintf(source_format, output), output, expected, label)
}

close_fixture :: proc(fixture: ^Fixture, output: string) {
	if fixture.handle != nil {
		_ = dynlib.unload_library(fixture.handle)
	}
	if output != "" {
		_ = os.remove(output)
	}
}

@(test)
test_ffi_multiple_calls_preserve_live_values :: proc(t: ^testing.T) {
	fixture, output, ok := build_fixture(t, "multiple-calls")
	if !ok do return
	defer close_fixture(&fixture, output)

	seed: u64 = 19
	first := fixture.clobber_pair(seed, 7)
	second := fixture.clobber_pair(seed, 11)
	got := seed + first + second
	testing.expectf(t, got == 75, "caller-clobber fixture result: got %d, want 75", got)
}

@(test)
test_ffi_stack_alignment :: proc(t: ^testing.T) {
	fixture, output, ok := build_fixture(t, "stack-alignment")
	if !ok do return
	defer close_fixture(&fixture, output)

	got := fixture.stack_alignment()
	testing.expectf(t, got == 1, "stack alignment probe: got %d, want 1", got)
}

@(test)
test_ffi_nul_terminated_strings :: proc(t: ^testing.T) {
	fixture, output, ok := build_fixture(t, "nul-strings")
	if !ok do return
	defer close_fixture(&fixture, output)

	values := [3]string{"", "hello", "syntact ffi"}
	for value in values {
		cvalue := strings.clone_to_cstring(value, context.temp_allocator)
		got := fixture.cstring_contract(cvalue, u64(len(value)))
		testing.expectf(t, got == 1, "C-string contract for %q: got %d, want 1", value, got)
	}
}

@(test)
test_ffi_sysv_stack_and_mixed_arguments :: proc(t: ^testing.T) {
	fixture, output, ok := build_fixture(t, "sysv-abi")
	if !ok do return
	defer close_fixture(&fixture, output)

	testing.expectf(t, fixture.sum_seven(1, 2, 3, 4, 5, 6, 7) == 28, "seven integer arguments were not assigned correctly")
	testing.expectf(t, fixture.sum_mixed(1, 2.0, 3, 4.0, 5, 6.0, 7) == 28, "mixed integer/floating arguments were not assigned correctly")
	testing.expectf(t, fixture.stack_seven(1, 2, 3, 4, 5, 6, 7) == 1, "stack-passed call did not preserve SysV alignment")
}
