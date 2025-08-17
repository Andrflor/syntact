package compiler_test

import compiler "../compiler"

import "core:encoding/json"
import "core:fmt"
import "core:log"
import vmem "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

// ---------- Test case ----------
Test_Case :: struct {
	name:        string `json:"name"`,
	description: string `json:"description"`,
	source:      string `json:"source"`,
	expect:      string `json:"expect"`,
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
		parts := make([dynamic]string)
		for i in 0 ..< len(n.to) {
			stmt := new(compiler.Node)
			stmt^ = n.to[i]
			append(&parts, ast_to_string(stmt))
		}
		return fmt.tprintf("Scope[%s]", strings.join(parts[:], ","))
	case compiler.Override:
		ov := make([dynamic]string)
		for i in 0 ..< len(n.overrides) {
			x := new(compiler.Node)
			x^ = n.overrides[i]
			append(&ov, ast_to_string(x))
		}
		return fmt.tprintf("Override(%s,[%s])", ast_to_string(n.source), strings.join(ov[:], ","))
	case compiler.Property:
		return fmt.tprintf("Property(%s,%s)", ast_to_string(n.source), ast_to_string(n.property))
	case compiler.Operator:
		return fmt.tprintf(
			"Operator(%v,%s,%s)",
			n.kind,
			ast_to_string(n.left),
			ast_to_string(n.right),
		)
	case compiler.Execute:
		ws := make([dynamic]string)
		for w in n.wrappers do append(&ws, fmt.tprintf("%v", w))
		return fmt.tprintf("Execute(%s,[%s])", ast_to_string(n.to), strings.join(ws[:], ","))
	case compiler.Range:
		return fmt.tprintf("Range(%s,%s)", ast_to_string(n.start), ast_to_string(n.end))
	case compiler.Pattern:
		bs := make([dynamic]string)
		for b in n.to do append(&bs, fmt.tprintf("Branch(%s,%s)", ast_to_string(b.source), ast_to_string(b.product)))
		return fmt.tprintf("Pattern(%s,[%s])", ast_to_string(n.target), strings.join(bs[:], ","))
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

show_source_context :: proc(source: string, position: compiler.Position) -> string {
	lines := strings.split_lines(source)
	if position.line <= 0 || position.line > len(lines) {
		return "Invalid line"
	}

	result := make([dynamic]string)

	start_line := max(1, position.line - 2)
	end_line := min(len(lines), position.line + 2)

	for i := start_line; i <= end_line; i += 1 {
		prefix := "  "
		if i == position.line {
			prefix = "> "
		}
		append(&result, fmt.tprintf("%s%3d: %s", prefix, i, lines[i - 1]))
		if i == position.line {
			pointer := strings.repeat(" ", 6 + position.column - 1)
			append(&result, fmt.tprintf("%s^", pointer))
		}
	}

	return strings.join(result[:], "\n")
}


// ---------- IO ----------
load_test_file :: proc(path: string) -> (Test_Case, bool, string) {
	data, ok := os.read_entire_file(path)
	if !ok do return {}, false, fmt.tprintf("Failed to read test file: %s", path)
	tc: Test_Case
	if err := json.unmarshal(data, &tc); err != nil {
		return {}, false, fmt.tprintf("Failed to parse JSON in %s: %v", path, err)
	}
	return tc, true, ""
}

// ---------- Single test ----------
run_test :: proc(path: string, t: ^testing.T) {
	arena: vmem.Arena
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)

	tc, ok, msg := load_test_file(path)
	if ok {
		cache := new(compiler.Cache)
		ast := compiler.parse(cache, tc.source)
		actual := ast_to_string(ast)
		ok = actual == tc.expect

		if !ok {
			position := (^compiler.NodeBase)(ast).position
			msg = strings.concatenate(
				{
					fmt.tprintf(
						"\n\nTest failed for (%s)\nSource diff line %v, column %v:\n",
						tc.name,
						position.line,
						position.column,
					),
					show_source_context(tc.source, position),
					"\n\n",
					format_difference(tc.expect, actual, first_difference(actual, tc.expect)),
				},
			)
		}
	}

	testing.expectf(t, ok, "%s", msg)
}

first_difference :: proc(str1, str2: string) -> int {
	min_len := min(len(str1), len(str2))

	for i in 0 ..< min_len {
		if str1[i] != str2[i] {
			return i
		}
	}

	if len(str1) != len(str2) {
		return min_len
	}
	return -1
}

format_difference :: proc(str1, str2: string, pos: int, ctx: int = 40) -> string {

	builder := strings.builder_make()
	defer if builder.buf != nil do strings.builder_destroy(&builder)

	strings.write_string(&builder, fmt.aprintf("String diff pos: %d\n", pos))

	// Calculate context window
	start := max(0, pos - ctx)
	end1 := min(len(str1), pos + ctx + 1)
	end2 := min(len(str2), pos + ctx + 1)

	// Extract context substrings
	context1 := str1[start:end1]
	context2 := str2[start:end2]

	strings.write_string(&builder, fmt.aprintf("Expected: %s\n", context1))
	strings.write_string(&builder, fmt.aprintf("Actual  : %s\n", context2))

	// Create pointer line showing where the difference is
	pointer_line := make([]u8, len("String 1: \"") + (pos - start) + 1)

	for i in 0 ..< len(pointer_line) {
		if i == len("Expected: \"") + (pos - start) {
			pointer_line[i] = '^'
		} else {
			pointer_line[i] = ' '
		}
	}
	strings.write_string(&builder, fmt.aprintf("%s\n", string(pointer_line)))

	return strings.clone(strings.to_string(builder))
}
