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
		return {}, "", false
	}
	if !state.success {
		testing.expectf(t, false, "building FFI fixture exited with %d: %s", state.exit_code, strings.trim_space(string(stderr)))
		return {}, "", false
	}

	fixture: Fixture
	count, loaded := dynlib.initialize_symbols(&fixture, output, "", "handle")
	if !loaded || count != 11 {
		testing.expectf(t, false, "loading FFI fixture failed: loaded=%v symbols=%d error=%s", loaded, count, dynlib.last_error())
		return {}, "", false
	}
	return fixture, output, true
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
}

run_aggregate_source :: proc(t: ^testing.T, source, library_path: string, expected: int) {
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
	result := compiler.reduce(cache.scope)
	prog := compiler.lower_to_bytecode(result)
	if prog == nil || prog.error != "" {
		testing.expectf(t, false, "generated aggregate lowering error: %s", prog != nil ? prog.error : "nil bytecode")
		return
	}
	path := fmt.tprintf("/tmp/syntact-ffi-aggregate-%d", os.get_pid())
	defer os.remove(path)
	message := x64.emit_executable(prog, path)
	testing.expectf(t, message == "", "generated aggregate emission error: %s\n%s", message, bc.bytecode_to_string(prog))
	if message != "" do return
	library_dir := filepath.dir(library_path)
	state, _, stderr, err := os.process_exec({command = []string{"env", fmt.tprintf("LD_LIBRARY_PATH=%s", library_dir), path}}, context.temp_allocator)
	testing.expectf(t, err == nil && state.exit_code == expected, "generated aggregate result: success=%v exit=%d error=%v stderr=%s\n%s", state.success, state.exit_code, err, strings.trim_space(string(stderr)), bc.bytecode_to_string(prog))
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
