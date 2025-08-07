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
	os.write_entire_file(asm_file, transmute([]byte)final_asm) or_return

	// Assemble the code
	{
		r, w := os.pipe() or_return
		proc_opts := os.Process_Desc {
			command = {"as", "--64", "-o", obj_file, asm_file},
			stderr  = w,
		}

		p := os.process_start(proc_opts) or_return
		os.close(w) // Close write end after starting process

		output := os.read_entire_file(r, context.temp_allocator) or_return

		os.close(r)
		_ = os.process_wait(p) or_return
		os.remove(asm_file)
		os.process_close(p) or_return
		if (len(output) != 0) {
			panic(
				fmt.tprintf(
					"Gnu as failed to assemble .intel_syntax noprefix for \"%s\" with the output: %s",
					asm_str,
					string(output),
				),
			)
		}
	}


	// Get disassembly using objdump
	objdump_output: []byte
	{
		r, w := os.pipe() or_return

		proc_opts := os.Process_Desc {
			command = {"objdump", "-d", "-M", "intel", obj_file},
			stdout  = w,
		}

		p := os.process_start(proc_opts) or_return
		os.close(w) // Close write end after starting process

		objdump_output = os.read_entire_file(r, context.temp_allocator) or_return
		os.close(r)
		_ = os.process_wait(p) or_return
		os.remove(obj_file)
		os.process_close(p) or_return
	}

	// Parse the objdump output to extract bytes
	parsed_bytes := parse_objdump(string(objdump_output))
	if parsed_bytes != nil && len(parsed_bytes) > 0 {
		return parsed_bytes, nil
	}

	// Fallback to reading the object file directly
	return {}, nil
}

parse_objdump :: proc(dump_output: string) -> []byte {
	byte_data := make([dynamic]byte, context.temp_allocator)
	defer delete(byte_data)

	in_text_section := false

	// Process the objdump output line by line
	for line in strings.split_lines(dump_output, allocator = context.temp_allocator) {
		if strings.contains(line, "Disassembly of section .text:") {
			in_text_section = true
			continue
		}

		if !in_text_section {
			continue
		}

		// Skip lines that don't contain disassembly
		if !strings.contains(line, ":") {
			continue
		}

		// Split by colon to separate address from bytes
		parts := strings.split(line, ":", allocator = context.temp_allocator)
		if len(parts) < 2 {
			continue
		}

		// Extract the hex bytes part
		hex_part := strings.trim_space(parts[1])

		// Find where the instruction mnemonic starts
		mnemonic_start := -1
		for i := 0; i < len(hex_part); i += 1 {
			if i > 0 && hex_part[i - 1] == ' ' && hex_part[i] == ' ' {
				mnemonic_start = i
				break
			}
		}

		if mnemonic_start < 0 {
			// Try with tab as delimiter
			mnemonic_start = strings.index_byte(hex_part, '\t')
		}

		if mnemonic_start > 0 {
			hex_part = hex_part[:mnemonic_start]
		}

		// Process each hex byte
		for hex in strings.fields(hex_part, context.temp_allocator) {
			if len(hex) == 2 {
				// Convert hex string to byte
				value, ok := strconv.parse_int(hex, 16)
				if ok {
					append(&byte_data, byte(value))
				}
			}
		}
	}

	// Return a copy of the extracted bytes
	if len(byte_data) > 0 {
		result := make([]byte, len(byte_data), context.temp_allocator)
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

// Get the string coresponding to that register
debug_register_to_string :: proc(r: DebugRegister) -> string {
	// Convert enum value to a string (will be uppercase like "AL")
	name := fmt.tprintf("%v", r)
	// Convert to lowercase
	return strings.to_lower(name, context.temp_allocator)
}
// Get the string coresponding to that register
control_register_to_string :: proc(r: ControlRegister) -> string {
	// Convert enum value to a string (will be uppercase like "AL")
	name := fmt.tprintf("%v", r)
	// Convert to lowercase
	return strings.to_lower(name, context.temp_allocator)
}


// Test data generators
get_all_registers8 :: proc() -> [16]Register8 {
	return [16]Register8 {
		.AL,
		.CL,
		.DL,
		.BL,
		// Commented to avoid clash with rex prefix reg in test
		// .AH,
		// .CH,
		// .DH,
		// .BH,
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

get_all_control_register :: proc() -> [5]ControlRegister {
	return [5]ControlRegister{.CR0, .CR2, .CR3, .CR4, .CR8}
}

get_all_debug_register :: proc() -> [6]DebugRegister {
	return [6]DebugRegister{.DR0, .DR1, .DR2, .DR3, .DR6, .DR7}
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

	// Absolute addresses (direct memory)
	// for addr in absolute_addresses {
	// 	append(&addresses, addr)
	// }


	// RIP-relative addressing (displacement only)
	for disp in displacements {
		// Create address with only displacement set (implies RIP-relative)
		append(
			&addresses,
			AddressComponents{base = nil, index = nil, scale = nil, displacement = disp},
		)
	}

	// Base register only
	for base in registers64 {
		append(
			&addresses,
			AddressComponents{base = base, index = nil, scale = nil, displacement = nil},
		)
	}

	// Base register + displacement
	for base in registers64 {
		for disp in displacements {
			append(
				&addresses,
				AddressComponents{base = base, index = nil, scale = nil, displacement = disp},
			)
		}
	}

	// Base + index
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

	// Base + index + scale
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

	// Base + index + displacement
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

	// Base + index + scale + displacement (the full SIB form)
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

	// Index + scale (no base)
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

	// Index + scale + displacement
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

get_interesting_xmmregister :: proc() -> [32]XMMRegister {
	return [32]XMMRegister {
		.XMM0, // Used for floating-point and integer SIMD operations
		.XMM1,
		.XMM2,
		.XMM3,
		.XMM4,
		.XMM5,
		.XMM6,
		.XMM7,
		.XMM8, // Requires REX prefix in encoding
		.XMM9,
		.XMM10,
		.XMM11,
		.XMM12,
		.XMM13,
		.XMM14,
		.XMM15,
		.XMM16, // Available in AVX-512
		.XMM17,
		.XMM18,
		.XMM19,
		.XMM20,
		.XMM21,
		.XMM22,
		.XMM23,
		.XMM24,
		.XMM25,
		.XMM26,
		.XMM27,
		.XMM28,
		.XMM29,
		.XMM30,
		.XMM31, // Last register available in AVX-512
	}
}

// YMM Registers: 256-bit SIMD registers (introduced in AVX)
get_interesting_ymmregister :: proc() -> [32]YMMRegister {
	return [32]YMMRegister {
		.YMM0, // Extended version of XMM0 (upper 128 bits used in AVX)
		.YMM1,
		.YMM2,
		.YMM3,
		.YMM4,
		.YMM5,
		.YMM6,
		.YMM7,
		.YMM8, // Requires REX prefix
		.YMM9,
		.YMM10,
		.YMM11,
		.YMM12,
		.YMM13,
		.YMM14,
		.YMM15,
		.YMM16, // Available in AVX-512
		.YMM17,
		.YMM18,
		.YMM19,
		.YMM20,
		.YMM21,
		.YMM22,
		.YMM23,
		.YMM24,
		.YMM25,
		.YMM26,
		.YMM27,
		.YMM28,
		.YMM29,
		.YMM30,
		.YMM31, // Last register available in AVX-512
	}
}

// ZMM Registers: 512-bit SIMD registers (introduced in AVX-512)
get_interesting_zmmregister :: proc() -> [32]ZMMRegister {
	return [32]ZMMRegister {
		.ZMM0, // Extended version of YMM0 (upper 256 bits used in AVX-512)
		.ZMM1,
		.ZMM2,
		.ZMM3,
		.ZMM4,
		.ZMM5,
		.ZMM6,
		.ZMM7,
		.ZMM8,
		.ZMM9,
		.ZMM10,
		.ZMM11,
		.ZMM12,
		.ZMM13,
		.ZMM14,
		.ZMM15,
		.ZMM16,
		.ZMM17,
		.ZMM18,
		.ZMM19,
		.ZMM20,
		.ZMM21,
		.ZMM22,
		.ZMM23,
		.ZMM24,
		.ZMM25,
		.ZMM26,
		.ZMM27,
		.ZMM28,
		.ZMM29,
		.ZMM30,
		.ZMM31, // Last register available in AVX-512
	}
}
// Mask Registers (used for AVX-512 masking operations)
get_interesting_maskregister :: proc() -> [8]MaskRegister {
	return [8]MaskRegister{.K0, .K1, .K2, .K3, .K4, .K5, .K6, .K7}
}

// Segment Registers (used for memory segmentation)
get_interesting_segmentregister :: proc() -> [6]SegmentRegister {
	return [6]SegmentRegister{.ES, .CS, .SS, .DS, .FS, .GS}
}
