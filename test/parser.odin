package compiler_test

import compiler "../compiler"

import "core:encoding/json"
import "core:fmt"
import vmem "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

// ===========================================================================
// SIMPLE STRING-BASED TEST FORMAT
// ===========================================================================

Test_Case :: struct {
	name:        string `json:"name"`,
	description: string `json:"description"`,
	source:      string `json:"source"`,
	expect:      string `json:"expect"`, // Simple string representation
}

// ===========================================================================
// AST TO STRING CONVERSION
// ===========================================================================

ast_to_string :: proc(node: ^compiler.Node) -> string {
	if node == nil {
		return "nil"
	}

	#partial switch n in node^ {
	case compiler.Identifier:
		if n.capture != "" {
			return fmt.tprintf("Identifier(%s,%s)", n.name, n.capture)
		}
		return fmt.tprintf("Identifier(%s)", n.name)

	case compiler.Literal:
		return fmt.tprintf("Literal(%v,%s)", n.kind, n.to)

	case compiler.Pointing:
		from_str := ast_to_string(n.from)
		to_str := ast_to_string(n.to)
		return fmt.tprintf("Pointing(%s,%s)", from_str, to_str)

	case compiler.PointingPull:
		from_str := ast_to_string(n.from)
		to_str := ast_to_string(n.to)
		return fmt.tprintf("PointingPull(%s,%s)", from_str, to_str)

	case compiler.EventPush:
		from_str := ast_to_string(n.from)
		to_str := ast_to_string(n.to)
		return fmt.tprintf("EventPush(%s,%s)", from_str, to_str)

	case compiler.EventPull:
		from_str := ast_to_string(n.from)
		to_str := ast_to_string(n.to)
		return fmt.tprintf("EventPull(%s,%s)", from_str, to_str)

	case compiler.ResonancePush:
		from_str := ast_to_string(n.from)
		to_str := ast_to_string(n.to)
		return fmt.tprintf("ResonancePush(%s,%s)", from_str, to_str)

	case compiler.ResonancePull:
		from_str := ast_to_string(n.from)
		to_str := ast_to_string(n.to)
		return fmt.tprintf("ResonancePull(%s,%s)", from_str, to_str)

	case compiler.ScopeNode:
		if len(n.to) == 0 {
			return "Scope[]"
		}

		parts := make([dynamic]string, context.temp_allocator)
		for i in 0 ..< len(n.to) {
			stmt := new(compiler.Node, context.temp_allocator)
			stmt^ = n.to[i]
			append(&parts, ast_to_string(stmt))
		}

		statements := strings.join(parts[:], ",", context.temp_allocator)
		return fmt.tprintf("Scope[%s]", statements)

	case compiler.Override:
		source_str := ast_to_string(n.source)

		override_parts := make([dynamic]string, context.temp_allocator)
		for i in 0 ..< len(n.overrides) {
			override := new(compiler.Node, context.temp_allocator)
			override^ = n.overrides[i]
			append(&override_parts, ast_to_string(override))
		}

		overrides_str := strings.join(override_parts[:], ",", context.temp_allocator)
		return fmt.tprintf("Override(%s,[%s])", source_str, overrides_str)

	case compiler.Property:
		source_str := ast_to_string(n.source)
		prop_str := ast_to_string(n.property)
		return fmt.tprintf("Property(%s,%s)", source_str, prop_str)

	case compiler.Operator:
		left_str := ast_to_string(n.left)
		right_str := ast_to_string(n.right)
		return fmt.tprintf("Operator(%v,%s,%s)", n.kind, left_str, right_str)

	case compiler.Execute:
		to_str := ast_to_string(n.to)

		wrapper_strs := make([dynamic]string, context.temp_allocator)
		for wrapper in n.wrappers {
			append(&wrapper_strs, fmt.tprintf("%v", wrapper))
		}

		wrappers_str := strings.join(wrapper_strs[:], ",", context.temp_allocator)
		return fmt.tprintf("Execute(%s,[%s])", to_str, wrappers_str)

	case compiler.Range:
		start_str := ast_to_string(n.start)
		end_str := ast_to_string(n.end)
		return fmt.tprintf("Range(%s,%s)", start_str, end_str)

	case compiler.Pattern:
		target_str := ast_to_string(n.target)

		branch_strs := make([dynamic]string, context.temp_allocator)
		for branch in n.to {
			source_str := ast_to_string(branch.source)
			product_str := ast_to_string(branch.product)
			append(&branch_strs, fmt.tprintf("Branch(%s,%s)", source_str, product_str))
		}

		branches_str := strings.join(branch_strs[:], ",", context.temp_allocator)
		return fmt.tprintf("Pattern(%s,[%s])", target_str, branches_str)

	case compiler.Constraint:
		constraint_str := ast_to_string(n.constraint)
		name_str := ast_to_string(n.name)
		return fmt.tprintf("Constraint(%s,%s)", constraint_str, name_str)

	case compiler.Product:
		to_str := ast_to_string(n.to)
		return fmt.tprintf("Product(%s)", to_str)

	case compiler.Expand:
		target_str := ast_to_string(n.target)
		return fmt.tprintf("Expand(%s)", target_str)

	case compiler.External:
		scope_str := ast_to_string(n.scope)
		return fmt.tprintf("External(%s,%s)", n.name, scope_str)

	case compiler.Unknown:
		return "Unknown"

	case compiler.Enforce:
		left_str := ast_to_string(n.left)
		right_str := ast_to_string(n.right)
		return fmt.tprintf("Enforce(%s,%s)", left_str, right_str)

	case:
		return fmt.tprintf("UnhandledNode(%T)", n)
	}
}

// ===========================================================================
// DETAILED DIFF UTILITIES
// ===========================================================================

/*
 * Split a string representation into meaningful tokens for easier comparison
 */
tokenize_ast_string :: proc(s: string) -> []string {
	tokens := make([dynamic]string, context.temp_allocator)

	i := 0
	for i < len(s) {
		switch s[i] {
		case ' ', '\t', '\n', '\r':
			i += 1 // Skip whitespace
		case '(':
			append(&tokens, "(")
			i += 1
		case ')':
			append(&tokens, ")")
			i += 1
		case '[':
			append(&tokens, "[")
			i += 1
		case ']':
			append(&tokens, "]")
			i += 1
		case ',':
			append(&tokens, ",")
			i += 1
		case:
			// Collect alphanumeric/identifier content
			start := i
			for i < len(s) &&
			    s[i] != '(' &&
			    s[i] != ')' &&
			    s[i] != '[' &&
			    s[i] != ']' &&
			    s[i] != ',' &&
			    s[i] != ' ' &&
			    s[i] != '\t' &&
			    s[i] != '\n' &&
			    s[i] != '\r' {
				i += 1
			}
			if i > start {
				token := s[start:i]
				if len(token) > 0 {
					append(&tokens, token)
				}
			}
		}
	}

	return tokens[:]
}

/*
 * Create a readable representation by joining tokens smartly
 */
join_tokens_readable :: proc(tokens: []string, max_tokens: int = 10) -> string {
	if len(tokens) == 0 do return ""

	result := make([dynamic]string, context.temp_allocator)

	count := min(max_tokens, len(tokens))
	for i in 0 ..< count {
		token := tokens[i]

		// Add the token
		append(&result, token)

		// Add appropriate spacing
		if i < count - 1 {
			next_token := tokens[i + 1]

			// Don't add space before closing delimiters or commas
			if next_token != ")" && next_token != "]" && next_token != "," {
				append(&result, " ")
			}
		}
	}

	if len(tokens) > max_tokens {
		append(&result, "...")
	}

	return strings.concatenate(result[:], context.temp_allocator)
}

/*
 * Find the first difference between two token arrays
 */
find_first_difference :: proc(expected_tokens, actual_tokens: []string) -> (int, string) {
	min_len := min(len(expected_tokens), len(actual_tokens))

	for i in 0 ..< min_len {
		if expected_tokens[i] != actual_tokens[i] {
			// Build context around the difference
			start := max(0, i - 3)
			end_expected := min(len(expected_tokens), i + 4)
			end_actual := min(len(actual_tokens), i + 4)

			expected_context := join_tokens_readable(
				expected_tokens[start:end_expected],
				end_expected - start,
			)
			actual_context := join_tokens_readable(
				actual_tokens[start:end_actual],
				end_actual - start,
			)

			diff_msg := fmt.tprintf(
				"First difference at token %d:\n  Expected: ...%s\n  Actual:   ...%s\n  >>> Expected token: '%s'\n  >>> Actual token:   '%s'",
				i,
				expected_context,
				actual_context,
				expected_tokens[i],
				actual_tokens[i],
			)

			return i, diff_msg
		}
	}

	// Length difference
	if len(expected_tokens) != len(actual_tokens) {
		diff_msg := fmt.tprintf(
			"Length difference at token %d:\n  Expected length: %d\n  Actual length:   %d",
			min_len,
			len(expected_tokens),
			len(actual_tokens),
		)

		if len(expected_tokens) > len(actual_tokens) {
			missing_start := min_len
			missing_end := min(len(expected_tokens), missing_start + 5)
			missing_tokens := join_tokens_readable(expected_tokens[missing_start:missing_end], 5)
			diff_msg = fmt.tprintf("%s\n  Missing tokens: %s", diff_msg, missing_tokens)
		} else {
			extra_start := min_len
			extra_end := min(len(actual_tokens), extra_start + 5)
			extra_tokens := join_tokens_readable(actual_tokens[extra_start:extra_end], 5)
			diff_msg = fmt.tprintf("%s\n  Extra tokens: %s", diff_msg, extra_tokens)
		}

		return min_len, diff_msg
	}

	return -1, "No differences found"
}

/*
 * Extract structural differences by looking for common patterns
 */
find_structural_differences :: proc(expected, actual: string) -> []string {
	differences := make([dynamic]string, context.temp_allocator)

	// Look for missing major nodes
	major_nodes := []string {
		"Pointing(Identifier(List)",
		"Pointing(Identifier(Error)",
		"Pointing(Identifier(transform)",
		"Pointing(Identifier(NonEmptyList)",
	}

	for node in major_nodes {
		if strings.contains(expected, node) && !strings.contains(actual, node) {
			append(&differences, fmt.tprintf("Missing major node: %s", node))
		}
	}

	// Look for structural pattern differences
	pattern_checks := []struct {
		pattern:     string,
		description: string,
	} {
		{"Branch(nil,nil)", "Empty pattern branches (should have content)"},
		{"Override(Pointing(", "Incorrect Override structure (should be simpler)"},
		{"Property(Property(External", "Double-wrapped External property"},
	}

	for check in pattern_checks {
		expected_count := strings.count(expected, check.pattern)
		actual_count := strings.count(actual, check.pattern)

		if expected_count != actual_count {
			append(
				&differences,
				fmt.tprintf(
					"%s: Expected %d occurrences, got %d",
					check.description,
					expected_count,
					actual_count,
				),
			)
		}
	}

	return differences[:]
}

normalize_string :: proc(s: string) -> string {
	// Remove extra spaces and normalize
	normalized := strings.trim_space(s)
	normalized, _ = strings.replace_all(normalized, " ", "", context.temp_allocator)
	normalized, _ = strings.replace_all(normalized, "\t", "", context.temp_allocator)
	normalized, _ = strings.replace_all(normalized, "\n", "", context.temp_allocator)
	normalized, _ = strings.replace_all(normalized, "\r", "", context.temp_allocator)
	return normalized
}

/*
 * Create a detailed diff report
 */
create_detailed_diff :: proc(expected, actual: string, test_name: string) -> string {
	report := make([dynamic]string, context.temp_allocator)

	append(&report, fmt.tprintf("=== DETAILED DIFF REPORT FOR: %s ===", test_name))

	// Normalize and tokenize
	expected_normalized := normalize_string(expected)
	actual_normalized := normalize_string(actual)

	expected_tokens := tokenize_ast_string(expected_normalized)
	actual_tokens := tokenize_ast_string(actual_normalized)

	// Find first token difference
	diff_pos, diff_msg := find_first_difference(expected_tokens, actual_tokens)
	if diff_pos >= 0 {
		append(&report, "")
		append(&report, "TOKEN-LEVEL DIFFERENCE:")
		append(&report, diff_msg)
	}

	// Find structural differences
	structural_diffs := find_structural_differences(expected_normalized, actual_normalized)
	if len(structural_diffs) > 0 {
		append(&report, "")
		append(&report, "STRUCTURAL DIFFERENCES:")
		for diff in structural_diffs {
			append(&report, fmt.tprintf("  - %s", diff))
		}
	}

	// Length comparison
	append(&report, "")
	append(&report, fmt.tprintf("LENGTH COMPARISON:"))
	append(&report, fmt.tprintf("  Expected tokens: %d", len(expected_tokens)))
	append(&report, fmt.tprintf("  Actual tokens:   %d", len(actual_tokens)))
	append(
		&report,
		fmt.tprintf("  Difference:      %+d", len(actual_tokens) - len(expected_tokens)),
	)

	// Show first few and last few tokens
	show_count := 10
	if len(expected_tokens) > 0 {
		append(&report, "")
		append(&report, "FIRST FEW EXPECTED TOKENS:")
		first_tokens := join_tokens_readable(expected_tokens, show_count)
		append(&report, fmt.tprintf("  %s", first_tokens))
	}

	if len(actual_tokens) > 0 {
		append(&report, "")
		append(&report, "FIRST FEW ACTUAL TOKENS:")
		first_tokens := join_tokens_readable(actual_tokens, show_count)
		append(&report, fmt.tprintf("  %s", first_tokens))
	}

	if diff_pos >= 0 && diff_pos < min(len(expected_tokens), len(actual_tokens)) {
		append(&report, "")
		append(&report, "CONTEXT AROUND DIFFERENCE:")

		// Show more context around the difference
		context_size := 8
		start := max(0, diff_pos - context_size)

		expected_end := min(len(expected_tokens), diff_pos + context_size + 1)
		actual_end := min(len(actual_tokens), diff_pos + context_size + 1)

		expected_context := join_tokens_readable(
			expected_tokens[start:expected_end],
			expected_end - start,
		)
		actual_context := join_tokens_readable(actual_tokens[start:actual_end], actual_end - start)

		append(&report, fmt.tprintf("  Expected: %s", expected_context))
		append(&report, fmt.tprintf("  Actual:   %s", actual_context))

		// Add pointer to show exactly where
		pointer_pos := 0
		for i in start ..< diff_pos {
			if i < len(expected_tokens) {
				pointer_pos += len(expected_tokens[i]) + 1 // +1 for space
			}
		}
		pointer := strings.concatenate({strings.repeat(" ", pointer_pos), "^"})
		append(&report, fmt.tprintf("            %s", pointer))
	}

	append(&report, "")
	append(&report, "=== END DIFF REPORT ===")

	return strings.join(report[:], "\n", context.temp_allocator)
}

// ===========================================================================
// FILE OPERATIONS
// ===========================================================================

load_test_file :: proc(filepath: string) -> (Test_Case, bool) {
	content, read_ok := os.read_entire_file(filepath, context.temp_allocator)
	if !read_ok {
		fmt.printf("Failed to read test file: %s\n", filepath)
		return {}, false
	}

	test_case: Test_Case
	err := json.unmarshal(content, &test_case, allocator = context.temp_allocator)
	if err != nil {
		fmt.printf("Failed to parse JSON in %s: %v\n", filepath, err)
		return {}, false
	}

	return test_case, true
}

// ===========================================================================
// TEST EXECUTION
// ===========================================================================

run_single_test :: proc(t: ^testing.T, filepath: string, verbose: bool = false) -> bool {
	// Use a temporary arena for this test
	arena: vmem.Arena
	arena_allocator := vmem.arena_allocator(&arena)

	defer vmem.arena_destroy(&arena)

	context.allocator = arena_allocator

	test_case, load_ok := load_test_file(filepath)
	if !load_ok {
		testing.expectf(t, false, "Failed to load test file: %s", filepath)
		return false
	}

	if verbose {
		fmt.printf("\n=== %s ===\n", test_case.name)
		if test_case.description != "" {
			fmt.printf("Description: %s\n", test_case.description)
		}
		fmt.printf("Source: %s\n", test_case.source)
	}

	// Create a simple cache for testing
	cache := new(compiler.Cache)

	// Parse the source
	ast := compiler.parse(cache, test_case.source)
	if ast == nil {
		testing.expectf(t, false, "Failed to parse source in test '%s'", test_case.name)
		return false
	}

	// Convert to string and compare
	actual := ast_to_string(ast)

	actual_normalized := normalize_string(actual)
	expected_normalized := normalize_string(test_case.expect)

	if actual_normalized != expected_normalized {
		// Create detailed diff report
		diff_report := create_detailed_diff(test_case.expect, actual, test_case.name)

		testing.expectf(t, false, "Test '%s' failed:\n%s", test_case.name, diff_report)

		return false
	}

	if verbose {
		fmt.printf("✓ PASSED\n")
	}

	return true
}

run_all_tests_in_dir :: proc(t: ^testing.T, test_dir: string, verbose: bool = false) {
	if !os.exists(test_dir) {
		fmt.printf("Test directory does not exist: %s\n", test_dir)
		return
	}

	// Get directory handle
	dir_handle, open_err := os.open(test_dir)
	if open_err != nil {
		testing.expectf(t, false, "Failed to open test directory: %s", test_dir)
		return
	}
	defer os.close(dir_handle)

	// Read directory entries
	file_infos, read_err := os.read_dir(dir_handle, -1, context.temp_allocator)
	if read_err != nil {
		testing.expectf(t, false, "Failed to read test directory: %s", test_dir)
		return
	}

	// Find JSON test files
	test_files := make([dynamic]string, context.temp_allocator)

	for info in file_infos {
		if strings.has_suffix(info.name, ".json") && !info.is_dir {
			full_path := filepath.join({test_dir, info.name}, context.temp_allocator)
			append(&test_files, full_path)
		}
	}

	if len(test_files) == 0 {
		fmt.printf("No JSON test files found in %s\n", test_dir)
		return
	}

	fmt.printf("Running %d tests from %s\n", len(test_files), test_dir)

	passed := 0
	failed := 0

	for test_file in test_files {
		filename := filepath.base(test_file)

		if run_single_test(t, test_file, verbose) {
			passed += 1
			if !verbose {
				fmt.printf("✓ %s\n", filename)
			}
		} else {
			failed += 1
			fmt.printf("✗ %s\n", filename)
		}
	}

	fmt.printf("\nSummary: %d passed, %d failed\n", passed, failed)
}

// ===========================================================================
// TEMPLATE GENERATION
// ===========================================================================

generate_test_template :: proc(
	source: string,
	output_file: string,
	name: string = "",
	description: string = "",
) -> bool {
	cache := new(compiler.Cache, context.temp_allocator)
	ast := compiler.parse(cache, source)

	if ast == nil {
		fmt.printf("Failed to parse source for template generation\n")
		return false
	}

	expected := ast_to_string(ast)

	test_name := name if name != "" else filepath.stem(output_file)
	test_desc := description if description != "" else "Generated test"

	test_case := Test_Case {
		name        = test_name,
		description = test_desc,
		source      = source,
		expect      = expected,
	}

	json_data, marshal_err := json.marshal(test_case, {pretty = true})
	if marshal_err != nil {
		fmt.printf("Failed to marshal JSON: %v\n", marshal_err)
		return false
	}

	write_ok := os.write_entire_file(output_file, json_data)
	if !write_ok {
		fmt.printf("Failed to write file: %s\n", output_file)
		return false
	}

	fmt.printf("Generated test template: %s\n", output_file)
	return true
}

// ===========================================================================
// MAIN TEST FUNCTIONS
// ===========================================================================

@(test)
test_all_parser_files :: proc(t: ^testing.T) {
	run_all_tests_in_dir(t, "tests/", false)
}

@(test)
test_all_parser_files_verbose :: proc(t: ^testing.T) {
	run_all_tests_in_dir(t, "tests/", true)
}
