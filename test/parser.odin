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


Position_Map :: struct {
	positions: [dynamic]Node_Position,
}

Node_Position :: struct {
	output_start: int,
	output_end:   int,
	ast:          ^compiler.Ast,
	idx:          compiler.Node_Index,
}

find_node_at_position :: proc(pos_map: ^Position_Map, char_pos: int) -> (^compiler.Ast, compiler.Node_Index) {
	found_ast: ^compiler.Ast
	found_idx := compiler.INVALID_NODE
	for pos in pos_map.positions {
		if pos.output_start <= char_pos && char_pos <= pos.output_end {
			found_ast = pos.ast
			found_idx = pos.idx
		}
	}
	return found_ast, found_idx
}

ast_to_string :: proc(ast: ^compiler.Ast, idx: compiler.Node_Index) -> string {
	if idx == compiler.INVALID_NODE do return "nil"
	kind := compiler.node_kind(ast, idx)
	switch kind {
	case .Identifier:
		cap := compiler.node_capture_str(ast, idx)
		name := compiler.node_name_str(ast, idx)
		if cap != "" {
			return fmt.tprintf("Identifier(%s,%s)", name, cap)
		}
		return fmt.tprintf("Identifier(%s)", name)
	case .Literal:
		lk := compiler.node_literal_kind(ast, idx)
		text := compiler.node_text(ast, idx)
		return fmt.tprintf("Literal(%v,%s)", lk, text)
	case .Pointing:
		return fmt.tprintf("Pointing(%s,%s)", ast_to_string(ast, compiler.node_left(ast, idx)), ast_to_string(ast, compiler.node_right(ast, idx)))
	case .PointingPull:
		return fmt.tprintf("PointingPull(%s,%s)", ast_to_string(ast, compiler.node_left(ast, idx)), ast_to_string(ast, compiler.node_right(ast, idx)))
	case .EventPush:
		return fmt.tprintf("EventPush(%s,%s)", ast_to_string(ast, compiler.node_left(ast, idx)), ast_to_string(ast, compiler.node_right(ast, idx)))
	case .EventPull:
		catch_str := compiler.node_event_pull_catch(ast, idx)
		return fmt.tprintf(
			"EventPull(%s,%s,%s)",
			catch_str,
			ast_to_string(ast, compiler.node_event_pull_from(ast, idx)),
			ast_to_string(ast, compiler.node_event_pull_to(ast, idx)),
		)
	case .ResonancePush:
		return fmt.tprintf("ResonancePush(%s,%s)", ast_to_string(ast, compiler.node_left(ast, idx)), ast_to_string(ast, compiler.node_right(ast, idx)))
	case .ResonancePull:
		return fmt.tprintf("ResonancePull(%s,%s)", ast_to_string(ast, compiler.node_left(ast, idx)), ast_to_string(ast, compiler.node_right(ast, idx)))
	case .ScopeNode:
		children := compiler.node_children(ast, idx)
		if len(children) == 0 do return "Scope[]"
		parts := make([dynamic]string)
		for child in children {
			append(&parts, ast_to_string(ast, child))
		}
		return fmt.tprintf("Scope[%s]", strings.join(parts[:], ","))
	case .Carve:
		carve_children := compiler.node_carve_children(ast, idx)
		ov := make([dynamic]string)
		for child in carve_children {
			append(&ov, ast_to_string(ast, child))
		}
		return fmt.tprintf("Carve(%s,[%s])", ast_to_string(ast, compiler.node_carve_source(ast, idx)), strings.join(ov[:], ","))
	case .Property:
		return fmt.tprintf("Property(%s,%s)", ast_to_string(ast, compiler.node_left(ast, idx)), ast_to_string(ast, compiler.node_right(ast, idx)))
	case .Operator:
		return fmt.tprintf(
			"Operator(%v,%s,%s)",
			compiler.node_operator_kind(ast, idx),
			ast_to_string(ast, compiler.node_operator_left(ast, idx)),
			ast_to_string(ast, compiler.node_operator_right(ast, idx)),
		)
	case .Execute:
		wrappers := compiler.node_execute_wrappers(ast, idx)
		ws := make([dynamic]string)
		for w in wrappers do append(&ws, fmt.tprintf("%v", compiler.ExecutionWrapper(w)))
		return fmt.tprintf("Execute(%s,[%s])", ast_to_string(ast, compiler.node_execute_target(ast, idx)), strings.join(ws[:], ","))
	case .CompileTime:
		return fmt.tprintf("CompileTime(%s)", ast_to_string(ast, compiler.node_unary_operand(ast, idx)))
	case .Range:
		return fmt.tprintf("Range(%s,%s)", ast_to_string(ast, compiler.node_left(ast, idx)), ast_to_string(ast, compiler.node_right(ast, idx)))
	case .Pattern:
		branches := compiler.node_pattern_branches(ast, idx)
		bs := make([dynamic]string)
		for i := 0; i < len(branches); i += 2 {
			source := branches[i]
			product := branches[i + 1] if i + 1 < len(branches) else compiler.INVALID_NODE
			append(&bs, fmt.tprintf("Branch(%s,%s)", ast_to_string(ast, source), ast_to_string(ast, product)))
		}
		return fmt.tprintf("Pattern(%s,[%s])", ast_to_string(ast, compiler.node_pattern_target(ast, idx)), strings.join(bs[:], ","))
	case .Constraint:
		return fmt.tprintf("Constraint(%s,%s)", ast_to_string(ast, compiler.node_left(ast, idx)), ast_to_string(ast, compiler.node_right(ast, idx)))
	case .Product:
		return fmt.tprintf("Product(%s)", ast_to_string(ast, compiler.node_unary_operand(ast, idx)))
	case .Expand:
		return fmt.tprintf("Expand(%s)", ast_to_string(ast, compiler.node_unary_operand(ast, idx)))
	case .External:
		return fmt.tprintf("External(%s,%s)", compiler.node_external_name(ast, idx), ast_to_string(ast, compiler.node_external_scope(ast, idx)))
	case .Unknown:
		return "Unknown"
	case .Enforce:
		return fmt.tprintf("Enforce(%s,%s)", ast_to_string(ast, compiler.node_left(ast, idx)), ast_to_string(ast, compiler.node_right(ast, idx)))
	case .Branch:
		return fmt.tprintf("Branch(%s,%s)", ast_to_string(ast, compiler.node_left(ast, idx)), ast_to_string(ast, compiler.node_right(ast, idx)))
	}
	return fmt.tprintf("UnhandledNode(%v)", kind)
}

// Recursively walk ALL nodes and map their positions
walk_all_nodes :: proc(ast: ^compiler.Ast, idx: compiler.Node_Index, full_string: string, pos_map: ^Position_Map) {
	if idx == compiler.INVALID_NODE do return

	node_str := ast_to_string(ast, idx)

	search_start := 0
	for {
		found_pos := strings.index(full_string[search_start:], node_str)
		if found_pos == -1 do break

		actual_pos := search_start + found_pos

		already_mapped := false
		for existing in pos_map.positions {
			if existing.output_start == actual_pos &&
			   existing.output_end == actual_pos + len(node_str) {
				already_mapped = true
				break
			}
		}

		if !already_mapped {
			append(
				&pos_map.positions,
				Node_Position {
					output_start = actual_pos,
					output_end = actual_pos + len(node_str),
					ast = ast,
					idx = idx,
				},
			)
		}

		search_start = actual_pos + 1
	}

	kind := compiler.node_kind(ast, idx)
	switch kind {
	case .Pointing, .PointingPull, .EventPush, .ResonancePush, .ResonancePull, .Property, .Constraint, .Range, .Enforce, .Branch:
		walk_all_nodes(ast, compiler.node_left(ast, idx), full_string, pos_map)
		walk_all_nodes(ast, compiler.node_right(ast, idx), full_string, pos_map)
	case .EventPull:
		walk_all_nodes(ast, compiler.node_event_pull_from(ast, idx), full_string, pos_map)
		walk_all_nodes(ast, compiler.node_event_pull_to(ast, idx), full_string, pos_map)
	case .ScopeNode:
		for child in compiler.node_children(ast, idx) {
			walk_all_nodes(ast, child, full_string, pos_map)
		}
	case .Carve:
		walk_all_nodes(ast, compiler.node_carve_source(ast, idx), full_string, pos_map)
		for child in compiler.node_carve_children(ast, idx) {
			walk_all_nodes(ast, child, full_string, pos_map)
		}
	case .Operator:
		walk_all_nodes(ast, compiler.node_operator_left(ast, idx), full_string, pos_map)
		walk_all_nodes(ast, compiler.node_operator_right(ast, idx), full_string, pos_map)
	case .Execute:
		walk_all_nodes(ast, compiler.node_execute_target(ast, idx), full_string, pos_map)
	case .CompileTime, .Product, .Expand:
		walk_all_nodes(ast, compiler.node_unary_operand(ast, idx), full_string, pos_map)
	case .Pattern:
		walk_all_nodes(ast, compiler.node_pattern_target(ast, idx), full_string, pos_map)
		branches := compiler.node_pattern_branches(ast, idx)
		for b in branches {
			walk_all_nodes(ast, b, full_string, pos_map)
		}
	case .External:
		walk_all_nodes(ast, compiler.node_external_scope(ast, idx), full_string, pos_map)
	case .Identifier, .Literal, .Unknown:
		// leaf nodes
	}
}

// Build position map by walking ALL nodes
build_position_map :: proc(ast: ^compiler.Ast, root: compiler.Node_Index, full_string: string) -> Position_Map {
	pos_map := Position_Map{}
	walk_all_nodes(ast, root, full_string, &pos_map)
	return pos_map
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
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil do return {}, false, fmt.tprintf("Failed to read test file: %s", path)
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
		ast, _ := compiler.parse(cache, tc.source)
		root := compiler.ast_root(ast)
		actual := ast_to_string(ast, root)

		ok = actual == tc.expect

		if !ok {
			first_diff := first_difference(actual, tc.expect)
			pos_map := build_position_map(ast, root, actual)
			log.info(len(pos_map.positions))
			found_ast, found_idx := find_node_at_position(&pos_map, first_diff)
			position := compiler.Position{line = 1, column = 1}
			if found_ast != nil && found_idx != compiler.INVALID_NODE {
				position = compiler.node_position(found_ast, found_idx)
			}
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
					format_difference(tc.expect, actual, first_diff),
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

format_difference :: proc(str1, str2: string, pos: int, ctx: int = 100) -> string {
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
