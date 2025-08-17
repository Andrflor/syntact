package compiler_test

import compiler "../compiler"

import "core:encoding/json"
import "core:fmt"
import vmem "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:strings"

// ---------- Test case ----------
Test_Case :: struct {
	name:        string `json:"name"`,
	description: string `json:"description"`,
	source:      string `json:"source"`,
	expect:      string `json:"expect"`
}

// ---------- AST -> string ----------
ast_to_string :: proc(node: ^compiler.Node) -> string {
	if node == nil do return "nil"
	#partial switch n in node^ {
	case compiler.Identifier:
		if n.capture != "" {
			return fmt.tprintf("Identifier(%s,%s)", n.name, n.capture)
		}
		return fmt.tprintf("Identifier(%s)", n.name)
	case compiler.Literal:
		return fmt.tprintf("Literal(%v,%s)", n.kind, n.to)
	case compiler.Pointing:
		return fmt.tprintf("Pointing(%s,%s)", ast_to_string(n.from), ast_to_string(n.to))
	case compiler.PointingPull:
		return fmt.tprintf("PointingPull(%s,%s)", ast_to_string(n.from), ast_to_string(n.to))
	case compiler.EventPush:
		return fmt.tprintf("EventPush(%s,%s)", ast_to_string(n.from), ast_to_string(n.to))
	case compiler.EventPull:
		return fmt.tprintf("EventPull(%s,%s)", ast_to_string(n.from), ast_to_string(n.to))
	case compiler.ResonancePush:
		return fmt.tprintf("ResonancePush(%s,%s)", ast_to_string(n.from), ast_to_string(n.to))
	case compiler.ResonancePull:
		return fmt.tprintf("ResonancePull(%s,%s)", ast_to_string(n.from), ast_to_string(n.to))
	case compiler.ScopeNode:
		if len(n.to) == 0 do return "Scope[]"
		parts := make([dynamic]string, context.temp_allocator)
		for i in 0 ..< len(n.to) {
			stmt := new(compiler.Node, context.temp_allocator)
			stmt^ = n.to[i]
			append(&parts, ast_to_string(stmt))
		}
		return fmt.tprintf("Scope[%s]", strings.join(parts[:], ",", context.temp_allocator))
	case compiler.Override:
		ov := make([dynamic]string, context.temp_allocator)
		for i in 0 ..< len(n.overrides) {
			x := new(compiler.Node, context.temp_allocator)
			x^ = n.overrides[i]
			append(&ov, ast_to_string(x))
		}
		return fmt.tprintf("Override(%s,[%s])", ast_to_string(n.source),
		                   strings.join(ov[:], ",", context.temp_allocator))
	case compiler.Property:
		return fmt.tprintf("Property(%s,%s)", ast_to_string(n.source), ast_to_string(n.property))
	case compiler.Operator:
		return fmt.tprintf("Operator(%v,%s,%s)", n.kind, ast_to_string(n.left), ast_to_string(n.right))
	case compiler.Execute:
		ws := make([dynamic]string, context.temp_allocator)
		for w in n.wrappers do append(&ws, fmt.tprintf("%v", w))
		return fmt.tprintf("Execute(%s,[%s])", ast_to_string(n.to),
		                   strings.join(ws[:], ",", context.temp_allocator))
	case compiler.Range:
		return fmt.tprintf("Range(%s,%s)", ast_to_string(n.start), ast_to_string(n.end))
	case compiler.Pattern:
		bs := make([dynamic]string, context.temp_allocator)
		for b in n.to do append(&bs, fmt.tprintf("Branch(%s,%s)", ast_to_string(b.source), ast_to_string(b.product)))
		return fmt.tprintf("Pattern(%s,[%s])", ast_to_string(n.target),
		                   strings.join(bs[:], ",", context.temp_allocator))
	case compiler.Constraint:
		return fmt.tprintf("Constraint(%s,%s)", ast_to_string(n.constraint), ast_to_string(n.name))
	case compiler.Product:
		return fmt.tprintf("Product(%s)", ast_to_string(n.to))
	case compiler.Expand:
		return fmt.tprintf("Expand(%s)", ast_to_string(n.target))
	case compiler.External:
		return fmt.tprintf("External(%s,%s)", n.name, ast_to_string(n.scope))
	case compiler.Unknown:
		return "Unknown"
	case compiler.Enforce:
		return fmt.tprintf("Enforce(%s,%s)", ast_to_string(n.left), ast_to_string(n.right))
	case compiler.Branch:
		return fmt.tprintf("Branch(%s,%s)", ast_to_string(n.source), ast_to_string(n.product))
	case:
		return fmt.tprintf("UnhandledNode(%T)", n)
	}
}

// Find line/column from offset in source
get_line_column :: proc(source: string, offset: int) -> (line: int, column: int) {
	line = 1
	column = 1
	for i := 0; i < offset && i < len(source); i += 1 {
		if source[i] == '\n' {
			line += 1
			column = 1
		} else {
			column += 1
		}
	}
	return
}

// Show source context around line/column
show_source_context :: proc(source: string, line: int, column: int) -> string {
	lines := strings.split_lines(source, context.temp_allocator)
	if line <= 0 || line > len(lines) {
		return "Invalid line"
	}

	result := make([dynamic]string, context.temp_allocator)

	start_line := max(1, line - 2)
	end_line := min(len(lines), line + 2)

	for i := start_line; i <= end_line; i += 1 {
		prefix := "  "
		if i == line {
			prefix = "> "
		}
		append(&result, fmt.tprintf("%s%3d: %s", prefix, i, lines[i-1]))
		if i == line {
			pointer := strings.repeat(" ", 6 + column - 1, context.temp_allocator)
			append(&result, fmt.tprintf("%s^", pointer))
		}
	}

	return strings.join(result[:], "\n", context.temp_allocator)
}

// Track positions while building AST string
Position_Info :: struct {
	start_pos: int,  // Position in output string
	end_pos: int,    // Position in output string
	line: int,       // Line in source
	column: int,     // Column in source
}

ast_to_string_with_positions :: proc(node: ^compiler.Node, positions: ^[dynamic]Position_Info) -> string {
	if node == nil do return "nil"

	start_pos := 0
	if positions != nil && len(positions^) > 0 {
		// Calculate current position in output string
		for pos in positions^ {
			start_pos = max(start_pos, pos.end_pos)
		}
	}

	result := ""

	#partial switch n in node^ {
	case compiler.Identifier:
		if n.capture != "" {
			result = fmt.tprintf("Identifier(%s,%s)", n.name, n.capture)
		} else {
			result = fmt.tprintf("Identifier(%s)", n.name)
		}
	case compiler.Literal:
		result = fmt.tprintf("Literal(%v,%s)", n.kind, n.to)
	case compiler.Pointing:
		left := ast_to_string_with_positions(n.from, positions)
		right := ast_to_string_with_positions(n.to, positions)
		result = fmt.tprintf("Pointing(%s,%s)", left, right)
	case compiler.PointingPull:
		left := ast_to_string_with_positions(n.from, positions)
		right := ast_to_string_with_positions(n.to, positions)
		result = fmt.tprintf("PointingPull(%s,%s)", left, right)
	case compiler.EventPush:
		left := ast_to_string_with_positions(n.from, positions)
		right := ast_to_string_with_positions(n.to, positions)
		result = fmt.tprintf("EventPush(%s,%s)", left, right)
	case compiler.EventPull:
		left := ast_to_string_with_positions(n.from, positions)
		right := ast_to_string_with_positions(n.to, positions)
		result = fmt.tprintf("EventPull(%s,%s)", left, right)
	case compiler.ResonancePush:
		left := ast_to_string_with_positions(n.from, positions)
		right := ast_to_string_with_positions(n.to, positions)
		result = fmt.tprintf("ResonancePush(%s,%s)", left, right)
	case compiler.ResonancePull:
		left := ast_to_string_with_positions(n.from, positions)
		right := ast_to_string_with_positions(n.to, positions)
		result = fmt.tprintf("ResonancePull(%s,%s)", left, right)
	case compiler.ScopeNode:
		if len(n.to) == 0 {
			result = "Scope[]"
		} else {
			parts := make([dynamic]string, context.temp_allocator)
			for i in 0 ..< len(n.to) {
				stmt := new(compiler.Node, context.temp_allocator)
				stmt^ = n.to[i]
				append(&parts, ast_to_string_with_positions(stmt, positions))
			}
			result = fmt.tprintf("Scope[%s]", strings.join(parts[:], ",", context.temp_allocator))
		}
	case compiler.Override:
		ov := make([dynamic]string, context.temp_allocator)
		for i in 0 ..< len(n.overrides) {
			x := new(compiler.Node, context.temp_allocator)
			x^ = n.overrides[i]
			append(&ov, ast_to_string_with_positions(x, positions))
		}
		source_str := ast_to_string_with_positions(n.source, positions)
		result = fmt.tprintf("Override(%s,[%s])", source_str, strings.join(ov[:], ",", context.temp_allocator))
	case compiler.Property:
		source_str := ast_to_string_with_positions(n.source, positions)
		prop_str := ast_to_string_with_positions(n.property, positions)
		result = fmt.tprintf("Property(%s,%s)", source_str, prop_str)
	case compiler.Operator:
		left_str := ast_to_string_with_positions(n.left, positions)
		right_str := ast_to_string_with_positions(n.right, positions)
		result = fmt.tprintf("Operator(%v,%s,%s)", n.kind, left_str, right_str)
	case compiler.Execute:
		ws := make([dynamic]string, context.temp_allocator)
		for w in n.wrappers do append(&ws, fmt.tprintf("%v", w))
		to_str := ast_to_string_with_positions(n.to, positions)
		result = fmt.tprintf("Execute(%s,[%s])", to_str, strings.join(ws[:], ",", context.temp_allocator))
	case compiler.Range:
		start_str := ast_to_string_with_positions(n.start, positions)
		end_str := ast_to_string_with_positions(n.end, positions)
		result = fmt.tprintf("Range(%s,%s)", start_str, end_str)
	case compiler.Pattern:
		bs := make([dynamic]string, context.temp_allocator)
		for b in n.to {
			source_str := ast_to_string_with_positions(b.source, positions)
			prod_str := ast_to_string_with_positions(b.product, positions)
			append(&bs, fmt.tprintf("Branch(%s,%s)", source_str, prod_str))
		}
		target_str := ast_to_string_with_positions(n.target, positions)
		result = fmt.tprintf("Pattern(%s,[%s])", target_str, strings.join(bs[:], ",", context.temp_allocator))
	case compiler.Constraint:
		constraint_str := ast_to_string_with_positions(n.constraint, positions)
		name_str := ast_to_string_with_positions(n.name, positions)
		result = fmt.tprintf("Constraint(%s,%s)", constraint_str, name_str)
	case compiler.Product:
		to_str := ast_to_string_with_positions(n.to, positions)
		result = fmt.tprintf("Product(%s)", to_str)
	case compiler.Expand:
		target_str := ast_to_string_with_positions(n.target, positions)
		result = fmt.tprintf("Expand(%s)", target_str)
	case compiler.External:
		scope_str := ast_to_string_with_positions(n.scope, positions)
		result = fmt.tprintf("External(%s,%s)", n.name, scope_str)
	case compiler.Unknown:
		result = "Unknown"
	case compiler.Enforce:
		left_str := ast_to_string_with_positions(n.left, positions)
		right_str := ast_to_string_with_positions(n.right, positions)
		result = fmt.tprintf("Enforce(%s,%s)", left_str, right_str)
	case compiler.Branch:
		source_str := ast_to_string_with_positions(n.source, positions)
		prod_str := ast_to_string_with_positions(n.product, positions)
		result = fmt.tprintf("Branch(%s,%s)", source_str, prod_str)
	case:
		result = fmt.tprintf("UnhandledNode(%T)", n)
	}

	// Record position mapping
	if positions != nil {
		end_pos := start_pos + len(result)
		line, column, found := get_node_position(node)
		if found {
			append(positions, Position_Info{
				start_pos = start_pos,
				end_pos = end_pos,
				line = line,
				column = column,
			})
		}
	}

	return result
}

// Find source position for a given position in the AST output
find_source_position_from_diff :: proc(positions: []Position_Info, diff_pos: int) -> (line: int, column: int, found: bool) {
	for pos in positions {
		if diff_pos >= pos.start_pos && diff_pos < pos.end_pos {
			return pos.line, pos.column, true
		}
	}
	return 1, 1, false
}

// Get position from any AST node
get_node_position :: proc(node: ^compiler.Node) -> (line: int, column: int, found: bool) {
	if node == nil do return 1, 1, false

	#partial switch n in node^ {
	case compiler.Identifier:
		return n.position.line, n.position.column, true
	case compiler.Literal:
		return n.position.line, n.position.column, true
	case compiler.Pointing:
		return n.position.line, n.position.column, true
	case compiler.PointingPull:
		return n.position.line, n.position.column, true
	case compiler.EventPush:
		return n.position.line, n.position.column, true
	case compiler.EventPull:
		return n.position.line, n.position.column, true
	case compiler.ResonancePush:
		return n.position.line, n.position.column, true
	case compiler.ResonancePull:
		return n.position.line, n.position.column, true
	case compiler.ScopeNode:
		return n.position.line, n.position.column, true
	case compiler.Override:
		return n.position.line, n.position.column, true
	case compiler.Property:
		return n.position.line, n.position.column, true
	case compiler.Operator:
		return n.position.line, n.position.column, true
	case compiler.Execute:
		return n.position.line, n.position.column, true
	case compiler.Range:
		return n.position.line, n.position.column, true
	case compiler.Pattern:
		return n.position.line, n.position.column, true
	case compiler.Constraint:
		return n.position.line, n.position.column, true
	case compiler.Product:
		return n.position.line, n.position.column, true
	case compiler.Expand:
		return n.position.line, n.position.column, true
	case compiler.External:
		return n.position.line, n.position.column, true
	case compiler.Unknown:
		return n.position.line, n.position.column, true
	case compiler.Enforce:
		return n.position.line, n.position.column, true
	case compiler.Branch:
		return n.position.line, n.position.column, true
	}
	return 1, 1, false
}

// Simple diff with source location
create_diff :: proc(expected, actual, test_name, source: string, ast: ^compiler.Node) -> string {
	// Build position map while generating actual output
	positions := make([dynamic]Position_Info, context.temp_allocator)
	actual_with_positions := ast_to_string_with_positions(ast, &positions)

	// Find first difference
	min_len := min(len(expected), len(actual))
	diff_pos := -1
	for i := 0; i < min_len; i += 1 {
		if expected[i] != actual[i] {
			diff_pos = i
			break
		}
	}

	result := make([dynamic]string, context.temp_allocator)
	append(&result, fmt.tprintf("FAILED: %s", test_name))

	if diff_pos >= 0 {
		append(&result, fmt.tprintf("AST difference at position %d:", diff_pos))

		// Show AST difference
		start := max(0, diff_pos - 20)
		end := min(len(expected), diff_pos + 20)
		append(&result, fmt.tprintf("Expected: ...%s...", expected[start:end]))
		append(&result, fmt.tprintf("Actual:   ...%s...", actual[start:min(len(actual), diff_pos + 20)]))
		append(&result, fmt.tprintf("           %s^ HERE", strings.repeat(" ", diff_pos - start + 3)))

		// Find the source position for this diff
		line, column, found := find_source_position_from_diff(positions[:], diff_pos)
		if found {
			append(&result, "")
			append(&result, fmt.tprintf("Source location: line %d, column %d", line, column))
			append(&result, show_source_context(source, line, column))
		}
	} else if len(expected) != len(actual) {
		append(&result, fmt.tprintf("Length difference: expected %d, got %d", len(expected), len(actual)))

		if len(expected) > len(actual) {
			append(&result, fmt.tprintf("Missing: %s", expected[len(actual):]))
		} else {
			append(&result, fmt.tprintf("Extra: %s", actual[len(expected):]))
		}
	}

	return strings.join(result[:], "\n", context.temp_allocator)
}

// ---------- IO ----------
load_test_file :: proc(path: string) -> (Test_Case, bool, string) {
	data, ok := os.read_entire_file(path, context.temp_allocator)
	if !ok do return {}, false, fmt.tprintf("Failed to read test file: %s", path)
	tc: Test_Case
	if err := json.unmarshal(data, &tc, allocator = context.temp_allocator); err != nil {
		return {}, false, fmt.tprintf("Failed to parse JSON in %s: %v", path, err)
	}
	return tc, true, ""
}

// ---------- Single test ----------
run_single_test :: proc(path: string) -> (ok: bool, message: string) {
	arena: vmem.Arena
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)

	tc, _ok, msg := load_test_file(path)
	ok = _ok
	if !ok do return false, msg

	cache := new(compiler.Cache)
	ast := compiler.parse(cache, tc.source)
	if ast == nil {
		return false, fmt.tprintf("Failed to parse source in test '%s' (%s)", tc.name, path)
	}

	actual := ast_to_string(ast)
	expected := tc.expect

	if actual != expected {
		return false, create_diff(expected, actual, tc.name, tc.source, ast)
	}
	return true, ""
}
