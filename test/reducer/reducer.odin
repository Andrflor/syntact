package reducer_test

import compiler "../../compiler"

import "core:encoding/json"
import "core:fmt"
import vmem "core:mem/virtual"
import "core:os"
import "core:testing"

Reducer_Test_Case :: struct {
	name:        string `json:"name"`,
	description: string `json:"description"`,
	source:      string `json:"source"`,
	expect:      string `json:"expect"`,
}

load_reducer_test_file :: proc(path: string) -> (Reducer_Test_Case, bool, string) {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil do return {}, false, fmt.tprintf("Failed to read test file: %s", path)
	tc: Reducer_Test_Case
	if err := json.unmarshal(data, &tc); err != nil {
		return {}, false, fmt.tprintf("Failed to parse JSON in %s: %v", path, err)
	}
	return tc, true, ""
}

run_reducer_test :: proc(path: string, t: ^testing.T) {
	arena: vmem.Arena
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)

	tc, ok, msg := load_reducer_test_file(path)
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
