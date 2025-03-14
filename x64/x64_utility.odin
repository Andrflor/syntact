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
import os "core:os/os2"
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
// assemble_asm_to_bytes takes an assembly string, writes it to a temporary file,
// assembles it using 'as', and returns the bytes of the resulting object file.
asm_to_bytes :: proc(asm_code: string, allocator := context.allocator) -> []byte {
	data, err := assemble(asm_code)
	if (err != nil) {
		panic(fmt.tprintf("Fatal error: %v", err))
	}
	return data
}

assemble :: proc(asm_str: string) -> (data: []byte, err: os.Error) {
	uuid := string_hash(asm_str)
	// Create temporary filenames
	asm_file := fmt.tprintf("temp_instruction_%x.s", uuid)
	obj_file := fmt.tprintf("temp_instruction_%x.o", uuid)
	// Add Intel syntax prefix if not present
	final_asm := fmt.tprintf(".intel_syntax noprefix\n%s\n", asm_str)
	err = os.write_entire_file(asm_file, transmute([]byte)final_asm)
	if (err != nil) {
		return
	}
	r, w := os.pipe() or_return
	defer os.close(r)
	p: os.Process;{
		defer os.close(w)
		p = os.process_start(
			{command = {"as", "--64", "-o", obj_file, asm_file}, stdout = w},
		) or_return
	}
	_ = os.process_wait(p) or_return
	output := os.read_entire_file(r, context.temp_allocator) or_return
	os.remove(asm_file)

	r2, w2 := os.pipe() or_return
	defer os.close(r2)
	p2: os.Process;{
		defer os.close(w2)
		p2 = os.process_start(
			{command = {"objdump", "-d", "-M", "intel", obj_file}, stdout = w2},
		) or_return
	}

	_ = os.process_wait(p2) or_return
	objdump_output := os.read_entire_file(r2, context.temp_allocator) or_return
	defer os.remove(obj_file)

	// Parse the objdump output
	parsed_bytes := parse_objdump(string(objdump_output))
	if len(parsed_bytes) > 0 {
		// If we successfully parsed bytes, return those
		return parsed_bytes, nil
	}

	// // Fallback to reading the object file directly
	return os.read_entire_file(obj_file, context.temp_allocator)
}

parse_objdump :: proc(dump_output: string) -> []byte {
	lines := strings.split_lines(dump_output)
	defer delete(lines)

	byte_data := make([dynamic]byte)
	defer delete(byte_data)

	// Look for lines with hex byte patterns
	// Typical objdump disassembly line format:
	// 0:   48 89 e5                mov    rbp,rsp
	in_text_section := false

	for line in lines {
		line := strings.trim_space(line)

		// Check if we've entered the .text section
		if strings.contains(line, "Disassembly of section .text:") {
			in_text_section = true
			continue
		}

		if !in_text_section {
			continue
		}

		// Skip lines that don't have instruction bytes
		if !strings.contains(line, ":") {
			continue
		}

		// Split on colon to separate address from instruction bytes
		parts := strings.split(line, ":")
		defer delete(parts)

		if len(parts) < 2 {
			continue
		}

		// Get the part with the hex bytes
		hex_part := strings.trim_space(parts[1])

		// Find where the instruction mnemonic starts
		tab_pos := strings.index_byte(hex_part, '\t')
		if tab_pos < 0 {
			// Try with multiple spaces as delimiter
			for i := 0; i < len(hex_part); i += 1 {
				if i > 0 && hex_part[i - 1] == ' ' && hex_part[i] == ' ' {
					tab_pos = i
					break
				}
			}
		}

		if tab_pos > 0 {
			hex_part = hex_part[:tab_pos]
		}

		// Split the hex bytes and convert them
		hex_bytes := strings.fields(hex_part)
		defer delete(hex_bytes)

		for hex in hex_bytes {
			if len(hex) == 2 {
				// Convert hex string to byte
				value, ok := strconv.parse_int(hex, 16)
				if ok {
					append(&byte_data, byte(value))
				}
			}
		}
	}

	// Return a copy of the dynamic array
	if len(byte_data) > 0 {
		result := make([]byte, len(byte_data))
		copy(result, byte_data[:])
		return result
	}

	return nil
}

// Get the string coresponding to that register
register64_to_string :: proc(r: Register64) -> string {
	// Convert enum value to a string (will be uppercase like "RAX")
	name := fmt.tprintf("%v", r)
	// Convert to lowercase
	return strings.to_lower(name, context.temp_allocator)
}

// Get the string coresponding to that register
register32_to_string :: proc(r: Register32) -> string {
	// Convert enum value to a string (will be uppercase like "EAX")
	name := fmt.tprintf("%v", r)
	// Convert to lowercase
	return strings.to_lower(name, context.temp_allocator)
}

// Get the string coresponding to that register
register16_to_string :: proc(r: Register16) -> string {
	// Convert enum value to a string (will be uppercase like "AX")
	name := fmt.tprintf("%v", r)
	// Convert to lowercase
	return strings.to_lower(name, context.temp_allocator)
}

// Get the string coresponding to that register
register8_to_string :: proc(r: Register8) -> string {
	// Convert enum value to a string (will be uppercase like "AL")
	name := fmt.tprintf("%v", r)
	// Convert to lowercase
	return strings.to_lower(name, context.temp_allocator)
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
	// for addr in absolute_addresses {
	// 	append(&addresses, addr)
	// }

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
