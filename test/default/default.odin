package default_test

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

// A "default" suite checks the DEFAULT value a binding receives when no explicit
// value is given (`u8:a` → a is 0). We analyze, find the binding by name in the
// root scope, and compare its value fold (type_folds, the materialized value) to
// the expected string.
Default_Test_Case :: struct {
	name:        string `json:"name"`,
	description: string `json:"description"`,
	source:      string `json:"source"`,
	binding:     string `json:"binding"`, // name of the binding to inspect
	expect:      string `json:"expect"`,  // expected default, rendered compactly
}

load_default_test_file :: proc(rel: string) -> (Default_Test_Case, bool, string) {
	path := test_path(rel)
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil do return {}, false, fmt.tprintf("Failed to read test file: %s", path)
	tc: Default_Test_Case
	if err := json.unmarshal(data, &tc); err != nil {
		return {}, false, fmt.tprintf("Failed to parse JSON in %s: %v", path, err)
	}
	return tc, true, ""
}

run_default_test :: proc(path: string, t: ^testing.T) {
	arena: vmem.Arena
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)

	tc, ok, msg := load_default_test_file(path)
	if !ok {
		testing.expectf(t, false, "%s", msg)
		return
	}

	cache := new(compiler.Cache)
	ast, _ := compiler.parse(cache, tc.source)
	compiler.analyze(cache, ast)

	scope := cache.scope
	if scope == nil {
		testing.expectf(t, false, "Default test '%s': nil scope", tc.name)
		return
	}

	// Find the LAST binding bearing the requested name (duplicate names are
	// resolved by ordinal; for a test we take the last occurrence).
	idx := -1
	for i := 0; i < len(scope.names); i += 1 {
		if scope.names[i] == tc.binding {
			idx = i
		}
	}
	if idx < 0 {
		testing.expectf(t, false, "Default test '%s': binding '%s' not found", tc.name, tc.binding)
		return
	}

	value := scope.values[idx]
	if idx < len(scope.type_folds) && scope.type_folds[idx] != nil {
		value = scope.type_folds[idx]
	}

	actual := compiler.value_to_string(value)
	if actual != tc.expect {
		testing.expectf(
			t,
			false,
			"\n\nDefault test failed (%s)\nbinding '%s': expected %q but got %q",
			tc.name,
			tc.binding,
			tc.expect,
			actual,
		)
	}
}
