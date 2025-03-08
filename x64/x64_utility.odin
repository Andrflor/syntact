///////////////////////////////////////////////////////////////////////////////
//
// x86-64 Assembly Instruction Set Utilities
//
// This file contains utility functions for working with x86-64 assembly,
// including string hashing, assembly conversion, and byte extraction.
//
// Author: Florian Andrieu <andrieu.florian@mail.com>
///////////////////////////////////////////////////////////////////////////////
package x64_assembler

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:os/os2"
import "core:strconv"
import "core:strings"
import "core:time"

// ==================================
// STRING UTILITIES
// ==================================

// Simple string hashing function
string_hash :: proc(s: string) -> u64 {
	hash: u64 = 5381
	for c in s {
		hash = ((hash << 5) + hash) + u64(c) // hash * 33 + c
	}
	return hash
}

// ==================================
// ASSEMBLY TO BYTECODE
// ==================================

// Converts an assembly instruction string into machine code bytes
asm_to_bytes :: proc(asm_str: string, allocator := context.allocator) -> []byte {
	// Create unique identifier based on the assembly string
	uuid := string_hash(asm_str)

	// Create temporary filenames
	asm_file := fmt.tprintf("temp_instruction_%x.s", uuid)
	obj_file := fmt.tprintf("temp_instruction_%x.o", uuid)

	// Add Intel syntax prefix if not present
	final_asm := fmt.tprintf(".intel_syntax noprefix\n%s\n", asm_str)

	// Write assembly to temp file
	success := os.write_entire_file(asm_file, transmute([]byte)final_asm)
	if !success {
		panic("Error writing assembly file")
	}
	defer os.remove(asm_file)

	// Assemble the file
	{
		as_desc := os2.Process_Desc {
			command = []string{"as", "--64", "-o", obj_file, asm_file},
		}

		as_state, as_stdout, as_stderr, as_err := os2.process_exec(as_desc, allocator)
		defer if len(as_stdout) > 0 do delete(as_stdout)
		defer if len(as_stderr) > 0 do delete(as_stderr)

		if as_err != os2.ERROR_NONE || !as_state.success {
			panic(fmt.tprintf("Error assembling:", string(as_stderr)))
		}
	}
	defer os.remove(obj_file)

	// Extract machine code using objdump
	{
		objdump_desc := os2.Process_Desc {
			command = []string{"objdump", "-d", obj_file},
		}

		objdump_state, objdump_stdout, objdump_stderr, objdump_err := os2.process_exec(
			objdump_desc,
			allocator,
		)
		defer if len(objdump_stderr) > 0 do delete(objdump_stderr)
		defer delete(objdump_stdout)

		if objdump_err != os2.ERROR_NONE || !objdump_state.success {
			panic(fmt.tprintf("Error in objdump:", string(objdump_stderr)))
		}

		// Parse objdump output to extract bytes
		return parse_objdump_output(string(objdump_stdout), allocator)
	}
}

// ==================================
// OBJECT DUMP PARSING
// ==================================

// Extracts machine code bytes from objdump output
parse_objdump_output :: proc(output: string, allocator := context.allocator) -> []byte {
	result := make([dynamic]byte, allocator = allocator)
	defer {
		if len(result) == 0 {
			delete(result)
		}
	}

	// Split output into lines
	lines := strings.split(output, "\n", allocator = allocator)
	defer delete(lines, allocator)

	in_text_section := false

	for line in lines {
		if strings.contains(line, "<.text>:") {
			in_text_section = true
			continue
		}

		if !in_text_section {
			continue
		}

		// Look for lines with hex bytes
		if idx := strings.index(line, ":"); idx >= 0 {
			if idx + 1 >= len(line) do continue

			rest := line[idx + 1:]
			if len(rest) == 0 do continue

			bytes_str := strings.split(strings.trim(rest, "\t"), "\t", allocator = allocator)
			defer delete(bytes_str, allocator)

			byte_parts := strings.split(bytes_str[0], " ", allocator = allocator)
			defer delete(byte_parts, allocator)

			for part in byte_parts {
				if len(part) == 0 do continue

				if b, ok := parse_hex_byte(part); ok {
					append(&result, b)
				}
			}
		}
	}

	// Convert dynamic array to slice allocated with the same allocator
	if len(result) == 0 {
		return nil
	}

	bytes := make([]byte, len(result), allocator)
	copy(bytes, result[:])
	delete(result)
	return bytes
}

// Converts a hex string to a byte
parse_hex_byte :: proc(hex: string) -> (byte, bool) {
	if len(hex) != 2 {
		return 0, false
	}

	val: int
	ok: bool
	val, ok = strconv.parse_int(hex, 16)
	if !ok {
		return 0, false
	}

	return byte(val), true
}
