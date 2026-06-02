package reduce_test

import compiler "../../compiler"

import "core:encoding/json"
import "core:fmt"
import vmem "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:testing"

// Resolve a test-relative path (e.g. "tests/foo.json") against the directory of
// this source file, so the suite runs regardless of the current working
// directory. #location().file_path is the absolute path baked in at compile time.
test_path :: proc(rel: string) -> string {
	dir := filepath.dir(#location().file_path)
	joined, _ := filepath.join({dir, rel}, context.allocator)
	return joined
}

Reduce_Test_Case :: struct {
	name:        string `json:"name"`,
	description: string `json:"description"`,
	source:      string `json:"source"`,
	expect:      string `json:"expect"`,
}

load_reduce_test_file :: proc(rel: string) -> (Reduce_Test_Case, bool, string) {
	path := test_path(rel)
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil do return {}, false, fmt.tprintf("Failed to read test file: %s", path)
	tc: Reduce_Test_Case
	if err := json.unmarshal(data, &tc); err != nil {
		return {}, false, fmt.tprintf("Failed to parse JSON in %s: %v", path, err)
	}
	return tc, true, ""
}

run_reduce_test :: proc(path: string, t: ^testing.T) {
	arena: vmem.Arena
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)

	tc, ok, msg := load_reduce_test_file(path)
	if !ok {
		testing.expectf(t, false, "%s", msg)
		return
	}

	cache := new(compiler.Cache)
	ast, _ := compiler.parse(cache, tc.source)
	compiler.analyze(cache, ast)

	result := compiler.reduce(cache.scope)
	actual := compiler.value_to_string(result)

	if actual != tc.expect {
		msg = fmt.tprintf(
			"\n\nReducer test failed (%s)\nSource:   %s\nExpected: %s\nActual:   %s",
			tc.name,
			tc.source,
			tc.expect,
			actual,
		)
		testing.expectf(t, false, "%s", msg)
	}
}
