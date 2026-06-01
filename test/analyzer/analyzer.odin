package analyzer_test

import compiler "../../compiler"

import "core:encoding/json"
import "core:fmt"
import vmem "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:testing"

Analyzer_Test_Case :: struct {
	name:          string         `json:"name"`,
	description:   string         `json:"description"`,
	source:        string         `json:"source"`,
	expect_errors: []string       `json:"expect_errors"`,
}

load_analyzer_test_file :: proc(path: string) -> (Analyzer_Test_Case, bool, string) {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil do return {}, false, fmt.tprintf("Failed to read test file: %s", path)
	tc: Analyzer_Test_Case
	if err := json.unmarshal(data, &tc); err != nil {
		return {}, false, fmt.tprintf("Failed to parse JSON in %s: %v", path, err)
	}
	return tc, true, ""
}

error_type_from_string :: proc(s: string) -> (compiler.Analyzer_Error_Type, bool) {
	switch s {
	case "Undefined_Identifier":    return .Undefined_Identifier, true
	case "Invalid_Binding_Name":    return .Invalid_Binding_Name, true
	case "Invalid_Carve":           return .Invalid_Carve, true
	case "Invalid_Property_Access": return .Invalid_Property_Access, true
	case "Constraint_Mismatch":     return .Constraint_Mismatch, true
	case "Invalid_Constraint":      return .Invalid_Constraint, true
	case "Invalid_Constraint_Name": return .Invalid_Constraint_Name, true
	case "Invalid_Constraint_Value": return .Invalid_Constraint_Value, true
	case "Circular_Reference":      return .Circular_Reference, true
	case "Invalid_Event_Pull":      return .Invalid_Event_Pull, true
	case "Invalid_Binding_Value":   return .Invalid_Binding_Value, true
	case "Invalid_Expand":          return .Invalid_Expand, true
	case "Invalid_Execute":         return .Invalid_Execute, true
	case "Invalid_operator":        return .Invalid_operator, true
	case "Invalid_Range":           return .Invalid_Range, true
	case "Infinite_Recursion":      return .Infinite_Recursion, true
	case "Default":                 return .Default, true
	}
	return .Default, false
}

run_analyzer_test :: proc(path: string, t: ^testing.T) {
	arena: vmem.Arena
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)

	tc, ok, msg := load_analyzer_test_file(path)
	if !ok {
		testing.expectf(t, false, "%s", msg)
		return
	}

	cache := new(compiler.Cache)
	ast, _ := compiler.parse(cache, tc.source)
	compiler.analyze(cache, ast)

	actual_errors := cache.analyze_errors
	expected_count := len(tc.expect_errors)
	actual_count := len(actual_errors)

	if expected_count == 0 {
		if actual_count > 0 {
			parts := make([dynamic]string)
			for err in actual_errors {
				append(&parts, fmt.tprintf("  %v: %s (line %d, col %d)", err.type, err.message, err.position.line, err.position.column))
			}
			msg = fmt.tprintf(
				"\n\nAnalyzer test failed (%s)\nExpected no errors but got %d:\n%s",
				tc.name,
				actual_count,
				strings.join(parts[:], "\n"),
			)
			testing.expectf(t, false, "%s", msg)
		}
		return
	}

	if actual_count != expected_count {
		parts := make([dynamic]string)
		for err in actual_errors {
			append(&parts, fmt.tprintf("  %v: %s", err.type, err.message))
		}
		actual_str := strings.join(parts[:], "\n") if len(parts) > 0 else "  (none)"
		msg = fmt.tprintf(
			"\n\nAnalyzer test failed (%s)\nExpected %d error(s) but got %d\nExpected: %v\nActual:\n%s",
			tc.name,
			expected_count,
			actual_count,
			tc.expect_errors,
			actual_str,
		)
		testing.expectf(t, false, "%s", msg)
		return
	}

	for expected_str, i in tc.expect_errors {
		expected_type, valid := error_type_from_string(expected_str)
		if !valid {
			msg = fmt.tprintf(
				"\n\nAnalyzer test failed (%s)\nUnknown error type in test: '%s'",
				tc.name,
				expected_str,
			)
			testing.expectf(t, false, "%s", msg)
			return
		}
		actual_type := actual_errors[i].type
		if actual_type != expected_type {
			msg = fmt.tprintf(
				"\n\nAnalyzer test failed (%s)\nError #%d: expected %v but got %v (%s)",
				tc.name,
				i,
				expected_type,
				actual_type,
				actual_errors[i].message,
			)
			testing.expectf(t, false, "%s", msg)
			return
		}
	}
}
