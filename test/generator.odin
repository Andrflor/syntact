// generator.odin
package compiler_test

import "core:os"
import "core:path/filepath"
import "core:strings"

// Set this to the folder that contains parser_test_harness.odin (package compiler_test)
TEST_DIR :: "tests"
OUTPUT_ODIN :: "parser_generated_tests.odin"

main :: proc() {
	// discover json files
	dir, err := os.open(TEST_DIR)
	if err != nil {return}
	defer os.close(dir)

	infos, rerr := os.read_dir(dir, -1, context.temp_allocator)
	if rerr != nil {return}

	files := make([dynamic]string, context.temp_allocator)
	for i := 0; i < len(infos); i += 1 {
		info := infos[i]
		if !info.is_dir && strings.has_suffix(info.name, ".json") {
			append(&files, filepath.join({TEST_DIR, info.name}, context.temp_allocator))
		}
	}
	if len(files) == 0 {return}

	// build output source directly into []u8
	out := make([dynamic]u8, context.temp_allocator)
	append(&out, "// AUTO-GENERATED. DO NOT EDIT.\n")
	append(&out, "package compiler_test\n\n")
	append(&out, "import \"core:testing\"\n\n")
	append(&out, "// run_single_test is provided by parser_test_harness.odin\n\n")

	for i := 0; i < len(files); i += 1 {
		p := files[i]
		base := filepath.base(p)
		stem := filepath.stem(base)
		fn := sanitize_identifier(strings.concatenate({"test_", stem, "_", itoa(i)}))

		append(&out, "@(test)\n")
		append(&out, fn)
		append(&out, " :: proc(t: ^testing.T) {\n")
		append(&out, "\trun_test(\"")
		append(&out, p)
		append(&out, "\", t)\n")
		append(&out, "}\n\n")
	}

	_ = os.write_entire_file(OUTPUT_ODIN, out[:])
}

itoa :: proc(i: int) -> string {
	// simple non-allocating-ish itoa into temp allocator
	buf := make([dynamic]u8, context.temp_allocator)
	if i == 0 {
		append(&buf, '0')
		return string(buf[:])
	}
	n := i
	if n < 0 {
		append(&buf, '-')
		n = -n
	}
	// collect digits reversed
	digs := make([dynamic]u8, context.temp_allocator)
	for n > 0 {
		append(&digs, u8('0' + n % 10))
		n /= 10
	}
	// append reversed
	for j := len(digs) - 1; j >= 0; j -= 1 {
		append(&buf, digs[j])
	}
	return string(buf[:])
}

sanitize_identifier :: proc(s: string) -> string {
	buf := make([dynamic]u8, context.temp_allocator)

	// first char
	if len(s) == 0 {
		append(&buf, 't')
	} else {
		c0 := s[0]
		if (c0 >= 'a' && c0 <= 'z') || (c0 >= 'A' && c0 <= 'Z') || c0 == '_' {
			append(&buf, c0)
		} else {
			append(&buf, 't')
		}
	}

	// rest
	start := 1 if len(s) > 0 else 0
	for i := start; i < len(s); i += 1 {
		c := s[i]
		if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' {
			append(&buf, c)
		} else {
			append(&buf, '_')
		}
	}

	return string(buf[:])
}
