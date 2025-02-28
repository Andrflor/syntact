package compiler

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:os/os2"
import "core:strconv"
import "core:strings"

// asm_to_bytes takes an assembly string and returns the corresponding machine code bytes
asm_to_bytes :: proc(asm_str: string, allocator := context.allocator) -> ([]byte, bool) {
	// Create temporary files
	asm_file := "temp_instruction.s"
	obj_file := "temp_instruction.o"

	// Add Intel syntax prefix if not present
	final_asm := fmt.tprintf(".intel_syntax noprefix\n%s", asm_str)

	// Write assembly to temp file
	success := os.write_entire_file(asm_file, transmute([]byte)final_asm)
	if !success {
		fmt.eprintln("Error writing assembly file")
		return nil, false
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
			fmt.eprintln("Error assembling:", string(as_stderr))
			return nil, false
		}
	}
	defer os.remove(obj_file)

	// Use objdump to get the machine code
	{
		objdump_desc := os2.Process_Desc {
			command = []string{"objdump", "-d", obj_file},
		}

		objdump_state, objdump_stdout, objdump_stderr, objdump_err := os2.process_exec(
			objdump_desc,
			allocator,
		)
		defer if len(objdump_stderr) > 0 do delete(objdump_stderr)
		defer delete(objdump_stdout) // Always delete this

		if objdump_err != os2.ERROR_NONE || !objdump_state.success {
			fmt.eprintln("Error in objdump:", string(objdump_stderr))
			return nil, false
		}

		// Parse the objdump output to extract bytes
		return parse_objdump_output(string(objdump_stdout), allocator), true
	}
}

// parse_objdump_output extracts the machine code bytes from objdump output
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
		// TODO(andrflor): fix something wrong here...
		// Check if we're in the .text section which contains the code
		if strings.contains(line, "Disassembly of section .text:") {
			in_text_section = true
			continue
		}

		if !in_text_section {
			continue
		}

		// Look for lines with hex bytes (they have a : followed by tab and hex)
		if idx := strings.index(line, ":"); idx >= 0 {
			// Skip the address and colon
			if idx + 1 >= len(line) do continue

			rest := line[idx + 1:]
			if len(rest) == 0 do continue

			// Find the tab that separates bytes from instruction
			tab_idx := strings.index(rest, "\t")
			if tab_idx < 0 do continue

			// Get just the bytes part
			bytes_str := strings.trim_space(rest[:tab_idx])

			// Split the byte string into pairs
			byte_parts := strings.split(bytes_str, " ", allocator = allocator)
			defer delete(byte_parts, allocator)

			for part in byte_parts {
				if len(part) == 0 do continue

				// Convert hex string to byte
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

// parse_hex_byte converts a hex string to a byte
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

// Example usage
main :: proc() {
	// asm := "mov rax, 1"

	bytes, ok := asm_to_bytes("mov rax, 1")
	if !ok {
		fmt.println("Failed to convert assembly to bytes")
		return
	}

	fmt.println("Machine code bytes:")
	for b in bytes {
		fmt.printf("%02x ", b)
	}
	fmt.println()
}
