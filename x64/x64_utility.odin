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
import "core:log"
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
			panic(fmt.tprintf("Error assembling: %s, %s", asm_str, string(as_stderr)))

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
			log.error("STDOUT:", objdump_err)
			fmt.println("STDOUT:", string(objdump_stdout))
			fmt.println("STDERR:", string(objdump_stderr))
			panic(fmt.tprintf("Error in objdump: %s, %s", asm_str, string(objdump_stderr)))
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

// Get the string coresponding to that register
register64_to_string :: proc(r: Register64) -> string {
	// Convert enum value to a string (will be uppercase like "RAX")
	name := fmt.tprintf("%v", r)
	// Convert to lowercase
	return strings.to_lower(name)
}

// Get the string coresponding to that register
register32_to_string :: proc(r: Register32) -> string {
	// Convert enum value to a string (will be uppercase like "EAX")
	name := fmt.tprintf("%v", r)
	// Convert to lowercase
	return strings.to_lower(name)
}

// Get the string coresponding to that register
register16_to_string :: proc(r: Register16) -> string {
	// Convert enum value to a string (will be uppercase like "AX")
	name := fmt.tprintf("%v", r)
	// Convert to lowercase
	return strings.to_lower(name)
}

// Get the string coresponding to that register
register8_to_string :: proc(r: Register8) -> string {
	// Convert enum value to a string (will be uppercase like "AL")
	name := fmt.tprintf("%v", r)
	// Convert to lowercase
	return strings.to_lower(name)
}

// Test data generators
get_all_registers8 :: proc() -> [20]Register8 {
	return [20]Register8 {
		.AL,
		.CL,
		.DL,
		.BL,
		.AH,
		.CH,
		.DH,
		.BH,
		.SPL,
		.BPL,
		.SIL,
		.DIL,
		.R8B,
		.R9B,
		.R10B,
		.R11B,
		.R12B,
		.R13B,
		.R14B,
		.R15B,
	}
}

get_all_registers16 :: proc() -> [16]Register16 {
	return [16]Register16 {
		.AX,
		.CX,
		.DX,
		.BX,
		.SP,
		.BP,
		.SI,
		.DI,
		.R8W,
		.R9W,
		.R10W,
		.R11W,
		.R12W,
		.R13W,
		.R14W,
		.R15W,
	}
}

get_all_registers32 :: proc() -> [16]Register32 {
	return [16]Register32 {
		.EAX,
		.ECX,
		.EDX,
		.EBX,
		.ESP,
		.EBP,
		.ESI,
		.EDI,
		.R8D,
		.R9D,
		.R10D,
		.R11D,
		.R12D,
		.R13D,
		.R14D,
		.R15D,
	}
}

get_all_registers64 :: proc() -> [16]Register64 {
	return [16]Register64 {
		.RAX,
		.RBX,
		.RCX,
		.RDX,
		.RSP,
		.RBP,
		.RSI,
		.RDI,
		.R8,
		.R9,
		.R10,
		.R11,
		.R12,
		.R13,
		.R14,
		.R15,
	}
}

get_interesting_imm8_values :: proc() -> [10]u8 {
	return [10]u8 {
		0, // Zero
		1, // Smallest positive
		0x0F, // Small arbitrary value
		0x42, // The Answer
		0x7F, // Largest positive signed 8-bit
		0x80, // Smallest negative signed 8-bit
		0xAA, // 10101010 pattern
		0xCC, // 11001100 pattern
		0xF0, // 11110000 pattern
		0xFF, // All bits set
	}
}

get_interesting_imm16_values :: proc() -> [16]u16 {
	return [16]u16 {
		0, // Zero
		1, // Smallest positive
		0x42, // Small arbitrary value
		0x7F, // Largest signed 8-bit
		0x80, // Smallest negative 8-bit when signed
		0xFF, // Largest unsigned 8-bit
		0x100, // Smallest value requiring 9 bits
		0x0FFF, // 12-bit value
		0x1234, // Arbitrary value
		0x5555, // 0101... pattern
		0x7FFF, // Largest positive signed 16-bit
		0x8000, // Smallest negative signed 16-bit
		0xAAAA, // 1010... pattern
		0xCCCC, // 1100... pattern
		0xF0F0, // 11110000... pattern
		0xFFFF, // All bits set
	}
}

get_interesting_imm32_values :: proc() -> [17]u32 {
	return [17]u32 {
		0, // Zero
		1, // Smallest positive
		0x42, // Small arbitrary value
		0xFF, // Largest unsigned 8-bit
		0x100, // Smallest requiring 9 bits
		0xFFFF, // Largest unsigned 16-bit
		0x10000, // Smallest requiring 17 bits
		0x12345678, // Large arbitrary value
		0x55555555, // 0101... pattern
		0x7FFFFFFF, // Largest positive signed 32-bit
		0x80000000, // Smallest negative signed 32-bit
		0xAAAAAAAA, // 1010... pattern
		0xCCCCCCCC, // 1100... pattern
		0xF0F0F0F0, // 11110000... pattern
		0xFFFF0000, // Upper half all 1s, lower half all 0s
		0x0000FFFF, // Upper half all 0s, lower half all 1s
		0xFFFFFFFF, // All bits set
	}
}

get_interesting_imm64_values :: proc() -> [17]u64 {
	return [17]u64 {
		0, // Zero
		1, // Smallest positive
		0x42, // Small arbitrary value
		0xFF, // Largest unsigned 8-bit
		0xFFFF, // Largest unsigned 16-bit
		0xFFFFFFFF, // Largest unsigned 32-bit
		0x100000000, // Smallest requiring 33 bits
		0x1122334455667788, // Arbitrary pattern
		0x5555555555555555, // 0101... pattern
		0x7FFFFFFFFFFFFFFF, // Largest positive signed 64-bit
		0x8000000000000000, // Smallest negative signed 64-bit
		0xAAAAAAAAAAAAAAAA, // 1010... pattern
		0xCCCCCCCCCCCCCCCC, // 1100... pattern
		0xF0F0F0F0F0F0F0F0, // 11110000... pattern
		0xFFFFFFFF00000000, // Upper half all 1s, lower half all 0s
		0x00000000FFFFFFFF, // Upper half all 0s, lower half all 1s
		0xFFFFFFFFFFFFFFFF, // All bits set
	}
}

get_interesting_signed_imm8_values :: proc() -> [8]i8 {
	return [8]i8 {
		0, // Zero
		1, // Smallest positive
		0x42, // Arbitrary positive
		0x7F, // Largest positive signed 8-bit
		-1, // -1
		-0x42, // Arbitrary negative
		-0x7F, // -127
		-0x80, // Smallest negative signed 8-bit
	}
}

get_interesting_signed_imm16_values :: proc() -> [13]i16 {
	return [13]i16 {
		0, // Zero
		1, // Smallest positive
		0x42, // Small positive
		0x7F, // Largest positive signed 8-bit
		0x80, // Smallest requiring 9 bits
		0x7FFF, // Largest positive signed 16-bit
		-1, // -1
		-0x42, // Small negative
		-0x7F, // -127
		-0x80, // Smallest negative signed 8-bit
		-0x81, // Smallest requiring 9 bits
		-0x7FFF, // Second smallest negative 16-bit
		-0x8000, // Smallest negative signed 16-bit
	}
}

get_interesting_signed_imm32_values :: proc() -> [22]i32 {
	return [22]i32 {
		0, // Zero displacement
		1, // Smallest positive displacement
		0x42, // Small arbitrary value
		0x7F, // Largest positive 8-bit
		0x80, // Smallest requiring 32-bit encoding
		0xFF, // 8-bit boundary
		0xFFF, // 12-bit value
		0x1000, // Page size
		0x12345, // Medium value
		0x12345678, // Large arbitrary value
		0x7FFFFFFF, // Maximum positive 32-bit
		-1, // Smallest negative displacement
		-0x42, // Small negative arbitrary value
		-0x7F, // Near negative 8-bit boundary
		-0x80, // Largest negative 8-bit
		-0x81, // Smallest negative requiring 32-bit encoding
		-0x100, // Small power of 2
		-0x1000, // Negative page size
		-0x12345, // Medium negative
		-0x12345678, // Large negative arbitrary value
		-0x7FFFFFFF, // Near minimum 32-bit
		-0x80000000, // Minimum negative 32-bit
	}
}

get_scales :: proc() -> [4]u8 {
	return [4]u8{1, 2, 4, 8}
}

// Generate Intel syntax string representation of a memory address operand
memory_address_to_string :: proc(addr: MemoryAddress) -> string {
	builder := strings.builder_make(context.temp_allocator)
	defer strings.builder_destroy(&builder)

	// Write opening bracket for memory operand
	strings.write_string(&builder, "qword ptr [")

	// Handle the union type
	switch a in addr {
	case u64:
		// Absolute address - just write the hex value
		fmt.sbprintf(&builder, "0x%x", a)

	case AddressComponents:
		// Handle SIB-style addressing
		has_base := a.base != nil
		has_index := a.index != nil
		has_displacement := a.displacement != nil

		// Special case: RIP-relative addressing (no base/index, only displacement)
		if !has_base && !has_index && has_displacement {
			fmt.sbprintf(&builder, "rip%+d", a.displacement.?)
			strings.write_string(&builder, "]")
			return strings.to_string(builder)
		}

		// Write base register if present
		if has_base {
			strings.write_string(&builder, register64_to_string(a.base.?))
		}

		// Write index register and scale if present
		if has_index {
			// Add plus if we already wrote a base
			if has_base {
				strings.write_string(&builder, "+")
			}

			strings.write_string(&builder, register64_to_string(a.index.?))

			// Add scale if specified (must be present if index is present)
			if a.scale != nil {
				fmt.sbprintf(&builder, "*%d", a.scale.?)
			}
		}

		// Write displacement if present
		if has_displacement {
			// Only add sign if we have base or index terms already
			if has_base || has_index {
				if a.displacement.? >= 0 {
					strings.write_string(&builder, "+")
				}
				fmt.sbprintf(&builder, "%d", a.displacement.?)
			} else {
				// Displacement alone
				fmt.sbprintf(&builder, "%d", a.displacement.?)
			}
		}
	}

	// Write closing bracket
	strings.write_string(&builder, "]")
	return strings.to_string(builder)
}

// Generate all possible combinations of x86-64 addressing modes
get_all_addressing_combinations :: proc() -> [dynamic]MemoryAddress {
	addresses := make([dynamic]MemoryAddress)

	// Get all the test data
	registers64 := get_all_registers64()
	scales := get_scales()
	displacements := get_interesting_signed_imm32_values()
	absolute_addresses := get_interesting_imm64_values()

	// 1. Absolute addresses (direct memory)
	for addr in absolute_addresses {
		append(&addresses, addr)
	}

	// 2. RIP-relative addressing (displacement only)
	for disp in displacements {
		// Create address with only displacement set (implies RIP-relative)
		append(
			&addresses,
			AddressComponents{base = nil, index = nil, scale = nil, displacement = disp},
		)
	}

	// 3. Base register only
	for base in registers64 {
		append(
			&addresses,
			AddressComponents{base = base, index = nil, scale = nil, displacement = nil},
		)
	}

	// 4. Base register + displacement
	for base in registers64 {
		for disp in displacements {
			append(
				&addresses,
				AddressComponents{base = base, index = nil, scale = nil, displacement = disp},
			)
		}
	}

	// 5. Base + index
	for base in registers64 {
		for index in registers64 {
			// Skip invalid combinations (RSP cannot be used as an index)
			if index == .RSP do continue

			append(
				&addresses,
				AddressComponents {
					base         = base,
					index        = index,
					scale        = 1, // Default scale is 1
					displacement = nil,
				},
			)
		}
	}

	// 6. Base + index + scale
	for base in registers64 {
		for index in registers64 {
			// Skip invalid combinations (RSP cannot be used as an index)
			if index == .RSP do continue

			for scale in scales {
				append(
					&addresses,
					AddressComponents {
						base = base,
						index = index,
						scale = scale,
						displacement = nil,
					},
				)
			}
		}
	}

	// 7. Base + index + displacement
	for base in registers64 {
		for index in registers64 {
			// Skip invalid combinations (RSP cannot be used as an index)
			if index == .RSP do continue

			// Just use a few representative displacements to avoid explosion
			representative_disps := [?]i32{0, 42, -42, 0x1000, -0x1000}
			for disp in representative_disps {
				append(
					&addresses,
					AddressComponents {
						base         = base,
						index        = index,
						scale        = 1, // Default scale is 1
						displacement = disp,
					},
				)
			}
		}
	}

	// 8. Base + index + scale + displacement (the full SIB form)
	for base in registers64 {
		for index in registers64 {
			// Skip invalid combinations (RSP cannot be used as an index)
			if index == .RSP do continue

			for scale in scales {
				// Just use a few representative displacements to avoid explosion
				representative_disps := [?]i32{42, -42, 0x1000}
				for disp in representative_disps {
					append(
						&addresses,
						AddressComponents {
							base = base,
							index = index,
							scale = scale,
							displacement = disp,
						},
					)
				}
			}
		}
	}

	// 9. Index + scale (no base)
	// This is a special case that's allowed in SIB addressing
	for index in registers64 {
		// Skip invalid combinations (RSP cannot be used as an index)
		if index == .RSP do continue

		for scale in scales {
			append(
				&addresses,
				AddressComponents {
					base         = .RBP, // Special encoding with RBP as base and disp=0 means no base
					index        = index,
					scale        = scale,
					displacement = 0,
				},
			)
		}
	}

	// 10. Index + scale + displacement
	for index in registers64 {
		// Skip invalid combinations (RSP cannot be used as an index)
		if index == .RSP do continue

		for scale in scales {
			representative_disps := [?]i32{42, -42, 0x1000}
			for disp in representative_disps {
				append(
					&addresses,
					AddressComponents {
						base         = .RBP, // Special encoding with RBP as base means no base
						index        = index,
						scale        = scale,
						displacement = disp,
					},
				)
			}
		}
	}

	return addresses
}
