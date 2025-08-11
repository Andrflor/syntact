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
	case:
		return fmt.tprintf("UnhandledNode(%T)", n)
	}
}

// ---------- Diff helpers (pure) ----------
tokenize_ast_string :: proc(s: string) -> []string {
	tokens := make([dynamic]string, context.temp_allocator)
	i := 0
	for i < len(s) {
		switch s[i] {
		case ' ', '\t', '\n', '\r': i += 1
		case '(', ')', '[', ']', ',':
			append(&tokens, s[i:i+1]); i += 1
		case:
			start := i
			for i < len(s) &&
			    s[i] != '(' && s[i] != ')' &&
			    s[i] != '[' && s[i] != ']' &&
			    s[i] != ',' && s[i] != ' ' &&
			    s[i] != '\t' && s[i] != '\n' &&
			    s[i] != '\r' { i += 1 }
			if i > start {
				token := s[start:i]
				if len(token) > 0 do append(&tokens, token)
			}
		}
	}
	return tokens[:]
}

join_tokens_readable :: proc(tokens: []string, max_tokens: int = 10) -> string {
	if len(tokens) == 0 do return ""
	out := make([dynamic]string, context.temp_allocator)
	n := min(max_tokens, len(tokens))
	for i in 0 ..< n {
		append(&out, tokens[i])
		if i < n-1 {
			next := tokens[i+1]
			if next != ")" && next != "]" && next != "," { append(&out, " ") }
		}
	}
	if len(tokens) > max_tokens do append(&out, "...")
	return strings.concatenate(out[:], context.temp_allocator)
}

find_first_difference :: proc(et, at: []string) -> (int, string) {
	min_len := min(len(et), len(at))
	for i in 0 ..< min_len {
		if et[i] != at[i] {
			start := max(0, i-3)
			ee := min(len(et), i+4)
			ae := min(len(at), i+4)
			ec := join_tokens_readable(et[start:ee], ee-start)
			ac := join_tokens_readable(at[start:ae], ae-start)
			return i, fmt.tprintf(
				"First difference at token %d:\n  Expected: ...%s\n  Actual:   ...%s\n  >>> Expected token: '%s'\n  >>> Actual token:   '%s'",
				i, ec, ac, et[i], at[i],
			)
		}
	}
	if len(et) != len(at) {
		i := min_len
		msg := fmt.tprintf("Length difference at token %d:\n  Expected length: %d\n  Actual length:   %d",
		                   i, len(et), len(at))
		if len(et) > len(at) {
			ms := i; me := min(len(et), ms+5)
			msg = fmt.tprintf("%s\n  Missing tokens: %s", msg, join_tokens_readable(et[ms:me], 5))
		} else {
			es := i; ee := min(len(at), es+5)
			msg = fmt.tprintf("%s\n  Extra tokens: %s", msg, join_tokens_readable(at[es:ee], 5))
		}
		return i, msg
	}
	return -1, "No differences found"
}

find_structural_differences :: proc(expected, actual: string) -> []string {
	diffs := make([dynamic]string, context.temp_allocator)
  nodes := []string{
		"Pointing(Identifier(List)",
		"Pointing(Identifier(Error)",
		"Pointing(Identifier(transform)",
		"Pointing(Identifier(NonEmptyList)",
	}
	for node in  nodes {
		if strings.contains(expected, node) && !strings.contains(actual, node) {
			append(&diffs, fmt.tprintf("Missing major node: %s", node))
		}
	}
  checks := []struct{pattern, description: string}{
		{"Branch(nil,nil)", "Empty pattern branches (should have content)"},
		{"Override(Pointing(", "Incorrect Override structure (should be simpler)"},
		{"Property(Property(External", "Double-wrapped External property"},
	}
	for check in  checks {
		ec := strings.count(expected, check.pattern)
		ac := strings.count(actual,   check.pattern)
		if ec != ac {
			append(&diffs, fmt.tprintf("%s: Expected %d occurrences, got %d", check.description, ec, ac))
		}
	}
	return diffs[:]
}

normalize_string :: proc(s: string) -> string {
	o := strings.trim_space(s)
	o, _ = strings.replace_all(o, " ",  "", context.temp_allocator)
	o, _ = strings.replace_all(o, "\t", "", context.temp_allocator)
	o, _ = strings.replace_all(o, "\n", "", context.temp_allocator)
	o, _ = strings.replace_all(o, "\r", "", context.temp_allocator)
	return o
}

create_detailed_diff :: proc(expected, actual: string, test_name: string) -> string {
	r := make([dynamic]string, context.temp_allocator)
	append(&r, fmt.tprintf("=== DETAILED DIFF REPORT FOR: %s ===", test_name))
	en := normalize_string(expected)
	an := normalize_string(actual)
	et := tokenize_ast_string(en)
	at := tokenize_ast_string(an)

	pos, msg := find_first_difference(et, at)
	if pos >= 0 {
		append(&r, "")
		append(&r, "TOKEN-LEVEL DIFFERENCE:")
		append(&r, msg)
	}

	structs := find_structural_differences(en, an)
	if len(structs) > 0 {
		append(&r, "")
		append(&r, "STRUCTURAL DIFFERENCES:")
		for d in structs do append(&r, fmt.tprintf("  - %s", d))
	}

	append(&r, "")
	append(&r, "LENGTH COMPARISON:")
	append(&r, fmt.tprintf("  Expected tokens: %d", len(et)))
	append(&r, fmt.tprintf("  Actual tokens:   %d", len(at)))
	append(&r, fmt.tprintf("  Difference:      %+d", len(at)-len(et)))

	show := 10
	if len(et) > 0 {
		append(&r, "")
		append(&r, "FIRST FEW EXPECTED TOKENS:")
		append(&r, fmt.tprintf("  %s", join_tokens_readable(et, show)))
	}
	if len(at) > 0 {
		append(&r, "")
		append(&r, "FIRST FEW ACTUAL TOKENS:")
		append(&r, fmt.tprintf("  %s", join_tokens_readable(at, show)))
	}

	if pos >= 0 && pos < min(len(et), len(at)) {
		append(&r, "")
		append(&r, "CONTEXT AROUND DIFFERENCE:")
		ctx := 8
		start := max(0, pos-ctx)
		ee := min(len(et), pos+ctx+1)
		ae := min(len(at), pos+ctx+1)
		append(&r, fmt.tprintf("  Expected: %s", join_tokens_readable(et[start:ee], ee-start)))
		append(&r, fmt.tprintf("  Actual:   %s", join_tokens_readable(at[start:ae], ae-start)))
	}
	append(&r, "")
	append(&r, "=== END DIFF REPORT ===")
	return strings.join(r[:], "\n", context.temp_allocator)
}

// ---------- IO (pure) ----------
load_test_file :: proc(path: string) -> (Test_Case, bool, string) {
	data, ok := os.read_entire_file(path, context.temp_allocator)
	if !ok do return {}, false, fmt.tprintf("Failed to read test file: %s", path)
	tc: Test_Case
	if err := json.unmarshal(data, &tc, allocator = context.temp_allocator); err != nil {
		return {}, false, fmt.tprintf("Failed to parse JSON in %s: %v", path, err)
	}
	return tc, true, ""
}

// ---------- Single test (pure) ----------
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

	actual   := normalize_string(ast_to_string(ast))
	expected := normalize_string(tc.expect)
	if actual != expected {
		return false, fmt.tprintf("Test '%s' (%s) mismatch:\n%s",
		                          tc.name, path, create_detailed_diff(tc.expect, ast_to_string(ast), tc.name))
	}
	return true, ""
}
