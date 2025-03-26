///////////////////////////////////////////////////////////////////////////////
//
// x86-64 Assembly Instruction Set Implementation (Refactored)
//
// This file contains implementations for x86-64 assembly instructions
// organized by instruction type and register size, with improved structure
// and reduced duplication.
//
// Author: Florian Andrieu <andrieu.florian@mail.com>
//
///////////////////////////////////////////////////////////////////////////////
package x64_assembler

import "core:fmt"
import "core:mem"

// ==================================
// Byte Buffer
// ==================================

// ByteBuffer is a simple growable buffer for bytecode
ByteBuffer :: struct {
	data: []u8,
	len:  int,
	cap:  int,
}

// Grows the buffer to accommodate at least min_size bytes
@(private)
grow :: proc(buffer: ^ByteBuffer, min_size: int) {
	new_cap := buffer.cap
	if new_cap == 0 {
		new_cap = 16 // Initial capacity
	}
	for new_cap < min_size {
		new_cap = new_cap * 2
	}
	new_data := make([]u8, new_cap, context.temp_allocator) // Consider using a persistent allocator if needed
	copy(new_data, buffer.data[:buffer.len])
	// Delete old data if using persistent allocator? Depends on context.
	// delete(buffer.data)
	buffer.data = new_data
	buffer.cap = new_cap
}

write :: proc(bytes: []u8) {
	_write_bytes(context.user_ptr, bytes)
}

// Writes bytes to the buffer, growing it if necessary
@(private) // Make it private, call it via assembler functions
_write_bytes :: proc(buffer: ^ByteBuffer, bytes: []u8) {
	required_size := buffer.len + len(bytes)
	if required_size > buffer.cap {
		grow(buffer, required_size)
	}
	copy(buffer.data[buffer.len:], bytes)
	buffer.len += len(bytes)
}

// Helper to write a single byte
@(private)
_write_byte :: proc(buffer: ^ByteBuffer, b: u8) {
	required_size := buffer.len + 1
	if required_size > buffer.cap {
		grow(buffer, required_size)
	}
	buffer.data[buffer.len] = b
	buffer.len += 1
}

// Helper to write immediate values of different sizes
@(private)
_write_imm8 :: proc(buffer: ^ByteBuffer, imm: u8) {
	_write_byte(buffer, imm)
}

@(private)
_write_imm16 :: proc(buffer: ^ByteBuffer, imm: u16) {
	bytes := transmute([2]u8)imm
	_write_bytes(buffer, bytes[:])
}

@(private)
_write_imm32 :: proc(buffer: ^ByteBuffer, imm: u32) {
	bytes := transmute([4]u8)imm
	_write_bytes(buffer, bytes[:])
}

@(private)
_write_imm64 :: proc(buffer: ^ByteBuffer, imm: u64) {
	bytes := transmute([8]u8)imm
	_write_bytes(buffer, bytes[:])
}


// ==================================
// CPU Register Definitions
// ==================================
// --- [ Register Enums remain the same as in the original code ] ---
// Register64, Register32, Register16, Register8
// XMMRegister, YMMRegister, ZMMRegister, MaskRegister
// SegmentRegister, ControlRegister, DebugRegister
Register64 :: enum u8 {
	RAX = 0,
	RCX = 1,
	RDX = 2,
	RBX = 3,
	RSP = 4,
	RBP = 5,
	RSI = 6,
	RDI = 7,
	R8  = 8,
	R9  = 9,
	R10 = 10,
	R11 = 11,
	R12 = 12,
	R13 = 13,
	R14 = 14,
	R15 = 15,
}
Register32 :: enum u8 {
	EAX  = 0,
	ECX  = 1,
	EDX  = 2,
	EBX  = 3,
	ESP  = 4,
	EBP  = 5,
	ESI  = 6,
	EDI  = 7,
	R8D  = 8,
	R9D  = 9,
	R10D = 10,
	R11D = 11,
	R12D = 12,
	R13D = 13,
	R14D = 14,
	R15D = 15,
}
Register16 :: enum u8 {
	AX   = 0,
	CX   = 1,
	DX   = 2,
	BX   = 3,
	SP   = 4,
	BP   = 5,
	SI   = 6,
	DI   = 7,
	R8W  = 8,
	R9W  = 9,
	R10W = 10,
	R11W = 11,
	R12W = 12,
	R13W = 13,
	R14W = 14,
	R15W = 15,
}
Register8 :: enum u8 {
	AL   = 0,
	CL   = 1,
	DL   = 2,
	BL   = 3,
	SPL  = 4,
	BPL  = 5,
	SIL  = 6,
	DIL  = 7, // Low bytes (require REX for SPL-DIL)
	R8B  = 8,
	R9B  = 9,
	R10B = 10,
	R11B = 11,
	R12B = 12,
	R13B = 13,
	R14B = 14,
	R15B = 15, // Extended low bytes
	AH   = 16,
	CH   = 17,
	DH   = 18,
	BH   = 19, // High bytes (legacy, cannot use with REX)
}
XMMRegister :: enum u8 {
	XMM0  = 0,
	XMM1  = 1,
	XMM2  = 2,
	XMM3  = 3,
	XMM4  = 4,
	XMM5  = 5,
	XMM6  = 6,
	XMM7  = 7,
	XMM8  = 8,
	XMM9  = 9,
	XMM10 = 10,
	XMM11 = 11,
	XMM12 = 12,
	XMM13 = 13,
	XMM14 = 14,
	XMM15 = 15,
	XMM16 = 16,
	XMM17 = 17,
	XMM18 = 18,
	XMM19 = 19,
	XMM20 = 20,
	XMM21 = 21,
	XMM22 = 22,
	XMM23 = 23,
	XMM24 = 24,
	XMM25 = 25,
	XMM26 = 26,
	XMM27 = 27,
	XMM28 = 28,
	XMM29 = 29,
	XMM30 = 30,
	XMM31 = 31,
}
YMMRegister :: enum u8 {
	YMM0  = 0,
	YMM1  = 1,
	YMM2  = 2,
	YMM3  = 3,
	YMM4  = 4,
	YMM5  = 5,
	YMM6  = 6,
	YMM7  = 7,
	YMM8  = 8,
	YMM9  = 9,
	YMM10 = 10,
	YMM11 = 11,
	YMM12 = 12,
	YMM13 = 13,
	YMM14 = 14,
	YMM15 = 15,
	YMM16 = 16,
	YMM17 = 17,
	YMM18 = 18,
	YMM19 = 19,
	YMM20 = 20,
	YMM21 = 21,
	YMM22 = 22,
	YMM23 = 23,
	YMM24 = 24,
	YMM25 = 25,
	YMM26 = 26,
	YMM27 = 27,
	YMM28 = 28,
	YMM29 = 29,
	YMM30 = 30,
	YMM31 = 31,
}
ZMMRegister :: enum u8 {
	ZMM0  = 0,
	ZMM1  = 1,
	ZMM2  = 2,
	ZMM3  = 3,
	ZMM4  = 4,
	ZMM5  = 5,
	ZMM6  = 6,
	ZMM7  = 7,
	ZMM8  = 8,
	ZMM9  = 9,
	ZMM10 = 10,
	ZMM11 = 11,
	ZMM12 = 12,
	ZMM13 = 13,
	ZMM14 = 14,
	ZMM15 = 15,
	ZMM16 = 16,
	ZMM17 = 17,
	ZMM18 = 18,
	ZMM19 = 19,
	ZMM20 = 20,
	ZMM21 = 21,
	ZMM22 = 22,
	ZMM23 = 23,
	ZMM24 = 24,
	ZMM25 = 25,
	ZMM26 = 26,
	ZMM27 = 27,
	ZMM28 = 28,
	ZMM29 = 29,
	ZMM30 = 30,
	ZMM31 = 31,
}
MaskRegister :: enum u8 {
	K0 = 0,
	K1 = 1,
	K2 = 2,
	K3 = 3,
	K4 = 4,
	K5 = 5,
	K6 = 6,
	K7 = 7,
}
SegmentRegister :: enum u8 {
	ES = 0,
	CS = 1,
	SS = 2,
	DS = 3,
	FS = 4,
	GS = 5,
}
ControlRegister :: enum u8 {
	CR0 = 0,
	CR2 = 2,
	CR3 = 3,
	CR4 = 4,
	CR8 = 8,
}
DebugRegister :: enum u8 {
	DR0 = 0,
	DR1 = 1,
	DR2 = 2,
	DR3 = 3,
	DR6 = 6,
	DR7 = 7,
}


// ==================================
// Memory Addressing
// ==================================

// AddressComponents represents SIB-style addressing in x86-64.
// If only displacement is set (base/index absent), it implies RIP-relative.
AddressComponents :: struct {
	base:         Maybe(Register64), // Base register (none means RIP if index is also none)
	index:        Maybe(Register64),
	scale:        Maybe(u8), // 1, 2, 4, 8 (must be none if index is none)
	displacement: Maybe(i32), // Signed offset
}

// MemoryAddress represents all x86-64 memory operand forms:
// - Absolute address (u64, encoded via relocation or reg indirection)
// - Register-relative addressing with optional index/scale/displacement
MemoryAddress :: union {
	u64, // Absolute memory address (semantically full u64) - Encoded as RIP-relative disp32
	AddressComponents, // SIB-based addressing (base/index/scale/disp)
}


// ==================================
// Encoding Helpers
// ==================================

OperandSize :: enum {
	Byte,
	Word,
	DWord,
	QWord,
}

// Generates the REX prefix byte. Returns 0 if no REX prefix is needed.
@(private)
get_rex_prefix :: proc(w: bool, r: bool, x: bool, b: bool, force_rex: bool = false) -> u8 {
	// rex prefix format: 0100wrxb
	// w: 64-bit operand size
	// r: extension for modr/m.reg
	// x: extension for sib.index
	// b: extension for modr/m.rm or sib.base
	rex: u8 = 0x40
	if w do rex |= 0x08
	if r do rex |= 0x04
	if x do rex |= 0x02
	if b do rex |= 0x01

	// Return 0 if only the base 0x40 bit is set and force_rex is false
	if rex == 0x40 && !force_rex {
		return 0
	}
	return rex
}

// Encodes the ModR/M byte.
@(private)
encode_modrm :: proc(mod: u8, reg: u8, rm: u8) -> u8 {
	// modr/m byte format: [7:6] mod | [5:3] reg | [2:0] r/m
	return (mod << 6) | ((reg & 0x7) << 3) | (rm & 0x7)
}

// Encodes the SIB (Scale-Index-Base) byte.
@(private)
encode_sib :: proc(scale: u8, index: u8, base: u8) -> u8 {
	// sib byte format: [7:6] scale | [5:3] index | [2:0] base
	// scale: scaling factor (0=1, 1=2, 2=4, 3=8)
	return (scale << 6) | ((index & 0x7) << 3) | (base & 0x7)
}

// Helper to check if an 8-bit register requires a REX prefix when used normally
// (i.e., SPL, BPL, SIL, DIL, or R8B-R15B). Does *not* include AH-DH.
@(private)
_is_rex_requiring_r8 :: proc(reg: Register8) -> bool {
	val := u8(reg)
	// Check for SPL, BPL, SIL, DIL (4-7) or R8B-R15B (8-15)
	return (val >= 4 && val <= 7) || (val >= 8 && val <= 15)
}

// Helper to check if an 8-bit register is AH, CH, DH, BH (cannot be used with REX)
@(private)
_is_high_byte_r8 :: proc(reg: Register8) -> bool {
	return u8(reg) >= 16
}

// Encodes ModR/M, SIB, and displacement for a memory operand.
// Returns REX.X and REX.B bits required *by the memory operand*.
@(private)
_encode_mem_modrm_sib_disp :: proc(
	buffer: ^ByteBuffer,
	mem: MemoryAddress,
	reg_field: u8,
) -> (
	rex_x: bool,
	rex_b: bool,
) {
	rex_x = false
	rex_b = false
	mod: u8 = 0
	rm: u8 = 0
	need_sib := false
	disp32: i32 = 0

	switch addr in mem {
	case u64:
		// Direct absolute address - encode as RIP-relative with 32-bit displacement
		// This typically requires relocation by the linker. Here we assume disp32 is calculated.
		// Treat as AddressComponents{displacement = addr} for encoding.
		// Mod = 00, R/M = 101 => RIP + disp32
		mod = 0
		rm = 5
		// Assume displacement is calculated relative to RIP. Here we just use the lower 32 bits.
		// A real assembler would calculate this based on current instruction pointer.
		disp32 = i32(addr) // Simplified: Use lower 32 bits as displacement
		_write_byte(buffer, encode_modrm(mod, reg_field & 0x7, rm))
		_write_imm32(buffer, u32(disp32))
	case AddressComponents:
		// Determine REX.B and REX.X needs from base/index
		if addr.base != nil do rex_b = (u8(addr.base.(Register64)) & 0x8) != 0
		if addr.index != nil do rex_x = (u8(addr.index.(Register64)) & 0x8) != 0

		base_reg_val := u8(7) // Default, often overwritten
		if addr.base != nil do base_reg_val = u8(addr.base.(Register64)) & 0x7

		// Determine Mod, R/M, and SIB necessity
		if addr.base == nil && addr.index == nil {
			// RIP-relative: Mod=00, R/M=101
			mod = 0
			rm = 5
			disp32 = addr.displacement != nil ? addr.displacement.(i32) : 0
		} else {
			need_sib = addr.index != nil || base_reg_val == RSP // RSP (4) always needs SIB
			if addr.base == nil { 	// [disp32] or [index*scale + disp32]
				mod = 0
				rm = 4 // SIB byte follows, base is RBP (5) in SIB
				need_sib = true
				disp32 = addr.displacement != nil ? addr.displacement.(i32) : 0
			} else { 	// base is present
				rm = base_reg_val
				disp := addr.displacement != nil ? addr.displacement.(i32) : 0

				if need_sib || rm == RBP { 	// RBP (5) as base without displacement needs disp8=0
					// Also force SIB if index present or base is RSP
					if disp == 0 && rm != RBP { 	// [base] or [base+index*scale] (but not [RBP])
						mod = 0
					} else if disp >= -128 && disp <= 127 { 	// [base + disp8] ...
						mod = 1
					} else { 	// [base + disp32] ...
						mod = 2
					}
				} else { 	// No SIB needed, base is not RBP or RSP
					if disp == 0 { 	// [base]
						mod = 0
					} else if disp >= -128 && disp <= 127 { 	// [base + disp8]
						mod = 1
					} else { 	// [base + disp32]
						mod = 2
					}
				}

				if need_sib do rm = 4 // Force SIB encoding if index used or base is RSP

				// Handle special case: [RBP] requires mod=01, disp8=0
				if mod == 0 && base_reg_val == RBP {
					mod = 1
					disp = 0 // Ensure disp8=0 is written later
				}

				// Set displacement value based on mod
				if mod == 1 || mod == 2 {
					disp32 = disp
				}
			}
		}

		// Write ModR/M
		_write_byte(buffer, encode_modrm(mod, reg_field & 0x7, rm))

		// Write SIB if needed
		if need_sib {
			scale_bits: u8
			switch addr.scale != nil ? addr.scale.(u8) : 1 {
			case 1:
				scale_bits = 0
			case 2:
				scale_bits = 1
			case 4:
				scale_bits = 2
			case 8:
				scale_bits = 3
			}
			index_val := u8(4) // RSP means no index
			if addr.index != nil do index_val = u8(addr.index.(Register64)) & 0x7

			base_val := base_reg_val
			if addr.base == nil {base_val = 5} 	// No base means use RBP encoding in SIB + mod=00 + disp32

			_write_byte(buffer, encode_sib(scale_bits, index_val, base_val))
		}

		// Write displacement
		if mod == 1 {
			_write_imm8(buffer, u8(disp32))
		} else if mod == 2 || (mod == 0 && rm == 5) { 	// disp32 cases
			_write_imm32(buffer, u32(disp32))
		}
	}

	return rex_x, rex_b
}

// Encodes a standard REX + Opcode + ModR/M instruction.
// Handles register-register and register-memory.
// op_size: Size of the operation (influences REX.W and 0x66 prefix).
// rex_w_override: Explicitly set REX.W bit (e.g., MOVSX).
// opcodes: The instruction opcode byte(s).
// reg_op: The register operand (encoded in ModR/M.reg).
// rm_op: The register or memory operand (encoded in ModR/M.rm).
// prefix_66: Force 0x66 prefix (for 16-bit ops).
// force_rex: Force emitting a REX prefix even if no bits are set (for SIL, etc.).
@(private)
_encode_rex_modrm :: proc(
	buffer: ^ByteBuffer,
	op_size: OperandSize,
	rex_w_override: Maybe(bool),
	opcodes: []u8,
	reg_op: $T, // Register type (Register64, Register32, etc.)
	rm_op: $U, // Register type or MemoryAddress
	prefix_66: bool = false,
	force_rex: bool = false,
) where U == T || U == MemoryAddress {

	reg_val := u8(reg_op)
	rex_r := (reg_val & 0x8) != 0
	rex_x := false
	rex_b := false

	// Handle 8-bit high bytes - they forbid REX and have adjusted values
	is_r8 := T == Register8
	reg_is_high_byte := false
	rm_is_high_byte := false
	rm_val: u8 = 0

	if is_r8 {
		reg_is_high_byte = _is_high_byte_r8(reg_op.(Register8))
		force_rex = force_rex || _is_rex_requiring_r8(reg_op.(Register8)) // REX needed for SPL-DIL as reg_op
		if reg_is_high_byte {
			reg_val = (reg_val - 16) | 4 // Map AH/CH/DH/BH to 4/5/6/7
		}
	}

	// Emit 0x66 prefix if needed (16-bit operand size)
	if prefix_66 || op_size == .Word {
		_write_byte(buffer, 0x66)
	}

	// Determine REX bits based on rm_op
	switch v in rm_op {
	case MemoryAddress:
	// REX.X, REX.B calculated by _encode_mem_modrm_sib_disp
	case T:
		// Register operand
		rm_val = u8(v)
		if is_r8 {
			rm_is_high_byte = _is_high_byte_r8(v.(Register8))
			if rm_is_high_byte {
				rm_val = (rm_val - 16) | 4 // Map AH/CH/DH/BH to 4/5/6/7
				if rex_r || force_rex { 	// Cannot mix REX and high bytes
					fmt.eprintf(
						"Encoding Error: Cannot use REX prefix with high 8-bit registers (AH-DH).\n",
					)
					return
				}
			} else {
				rex_b = (rm_val & 0x8) != 0
				force_rex = force_rex || _is_rex_requiring_r8(v.(Register8)) // REX needed for SPL-DIL as rm_op
			}
		} else {
			rex_b = (rm_val & 0x8) != 0
		}
		if reg_is_high_byte && (rex_b || force_rex) { 	// Cannot mix REX and high bytes
			fmt.eprintf(
				"Encoding Error: Cannot use REX prefix with high 8-bit registers (AH-DH).\n",
			)
			return
		}
	}

	// Determine REX.W
	rex_w := op_size == .QWord
	if ow := rex_w_override; ow != nil {
		rex_w = ow.?
	}
	// REX.W is ignored for 8-bit operations unless specifically forced (e.g. movzx r64, r8)
	if op_size == .Byte && rex_w_override == nil {
		rex_w = false
	}

	// Get REX prefix byte
	mem_rex_x, mem_rex_b := false, false

	// Write REX prefix (placeholder if memory operand, write actual if register)
	rex_byte: u8 = 0
	opcode_start_index := buffer.len // Remember where opcodes start in case we need to insert REX later

	// Handle differently based on rm_op type
	switch v in rm_op {
	case MemoryAddress:
		// Defer REX byte writing until after _encode_mem_modrm_sib_disp
		// Just write opcodes
		_write_bytes(buffer, opcodes)

		// Write ModR/M, SIB, and displacement
		mem_rex_x, mem_rex_b = _encode_mem_modrm_sib_disp(buffer, v, reg_val)

		// Now calculate and potentially insert the REX byte
		rex_byte = get_rex_prefix(rex_w, rex_r, mem_rex_x, mem_rex_b, force_rex)
		if rex_byte != 0 {
			// Shift existing opcode/memory bytes and insert REX
			required_size := buffer.len + 1
			if required_size > buffer.cap {
				grow(buffer, required_size)
			}
			mem.move_ptr(
				raw_data(buffer.data[opcode_start_index + 1:]),
				raw_data(buffer.data[opcode_start_index:]),
				buffer.len - opcode_start_index,
			)
			buffer.data[opcode_start_index] = rex_byte
			buffer.len += 1
		}
	case T:
		// Register operand case
		rex_byte = get_rex_prefix(rex_w, rex_r, false, rex_b, force_rex)
		if rex_byte != 0 {
			_write_byte(buffer, rex_byte)
		}

		// Write opcodes
		_write_bytes(buffer, opcodes)

		// Register operand (Mod=11)
		_write_byte(buffer, encode_modrm(3, reg_val & 0x7, rm_val & 0x7))
	}
}

// ==================================
// Data Movement Instructions (MOV, LEA, CMOV, etc.)
// ==================================

mov_r64_r64 :: proc(buffer: ^ByteBuffer, dst: Register64, src: Register64) {
	_encode_rex_modrm(buffer, .QWord, nil, []u8{0x89}, src, dst) // 89 /r: MOV r/m64, r64
}

mov_r32_r32 :: proc(buffer: ^ByteBuffer, dst: Register32, src: Register32) {
	_encode_rex_modrm(buffer, .DWord, nil, []u8{0x89}, src, dst) // 89 /r: MOV r/m32, r32
}

mov_r16_r16 :: proc(buffer: ^ByteBuffer, dst: Register16, src: Register16) {
	_encode_rex_modrm(buffer, .Word, nil, []u8{0x89}, src, dst) // 66 + 89 /r: MOV r/m16, r16
}

mov_r8_r8 :: proc(buffer: ^ByteBuffer, dst: Register8, src: Register8) {
	// Handle AH-DH cases carefully - cannot mix with REX
	if (_is_high_byte_r8(dst) || _is_high_byte_r8(src)) &&
	   (_is_rex_requiring_r8(dst) || _is_rex_requiring_r8(src)) {
		fmt.eprintf(
			"Encoding Error: Cannot mix high byte (AH-DH) and REX-requiring (SPL-R15B) 8-bit registers in MOV.\n",
		)
		return
	}
	_encode_rex_modrm(buffer, .Byte, nil, []u8{0x88}, src, dst) // 88 /r: MOV r/m8, r8
}

mov_r64_m64 :: proc(buffer: ^ByteBuffer, dst: Register64, mem: MemoryAddress) {
	_encode_rex_modrm(buffer, .QWord, nil, []u8{0x8B}, dst, mem) // 8B /r: MOV r64, r/m64
}
mov_m64_r64 :: proc(buffer: ^ByteBuffer, mem: MemoryAddress, src: Register64) {
	_encode_rex_modrm(buffer, .QWord, nil, []u8{0x89}, src, mem) // 89 /r: MOV r/m64, r64
}

mov_r32_m32 :: proc(buffer: ^ByteBuffer, dst: Register32, mem: MemoryAddress) {
	_encode_rex_modrm(buffer, .DWord, nil, []u8{0x8B}, dst, mem) // 8B /r: MOV r32, r/m32
}
mov_m32_r32 :: proc(buffer: ^ByteBuffer, mem: MemoryAddress, src: Register32) {
	_encode_rex_modrm(buffer, .DWord, nil, []u8{0x89}, src, mem) // 89 /r: MOV r/m32, r32
}

mov_r16_m16 :: proc(buffer: ^ByteBuffer, dst: Register16, mem: MemoryAddress) {
	_encode_rex_modrm(buffer, .Word, nil, []u8{0x8B}, dst, mem) // 66 + 8B /r: MOV r16, r/m16
}
mov_m16_r16 :: proc(buffer: ^ByteBuffer, mem: MemoryAddress, src: Register16) {
	_encode_rex_modrm(buffer, .Word, nil, []u8{0x89}, src, mem) // 66 + 89 /r: MOV r/m16, r16
}

mov_r8_m8 :: proc(buffer: ^ByteBuffer, dst: Register8, mem: MemoryAddress) {
	if _is_high_byte_r8(dst) {
		fmt.eprintf(
			"Encoding Error: Cannot use high byte register (AH-DH) as destination for MOV from memory.\n",
		)
		return
	}
	_encode_rex_modrm(
		buffer,
		.Byte,
		nil,
		[]u8{0x8A},
		dst,
		mem,
		force_rex = _is_rex_requiring_r8(dst),
	) // 8A /r: MOV r8, r/m8
}
mov_m8_r8 :: proc(buffer: ^ByteBuffer, mem: MemoryAddress, src: Register8) {
	if _is_high_byte_r8(src) {
		fmt.eprintf(
			"Encoding Error: Cannot use high byte register (AH-DH) as source for MOV to memory.\n",
		)
		return
	}
	_encode_rex_modrm(
		buffer,
		.Byte,
		nil,
		[]u8{0x88},
		src,
		mem,
		force_rex = _is_rex_requiring_r8(src),
	) // 88 /r: MOV r/m8, r8
}


mov_r64_imm64 :: proc(buffer: ^ByteBuffer, reg: Register64, imm: u64) {
	// Try 32-bit sign-extended immediate first (C7 /0 id)
	if i64(imm) >= -2147483648 && i64(imm) <= 2147483647 {
		rex_b := (u8(reg) & 0x8) != 0
		rex := get_rex_prefix(true, false, false, rex_b)
		if rex != 0 do _write_byte(buffer, rex)
		_write_byte(buffer, 0xC7)
		_write_byte(buffer, encode_modrm(3, 0, u8(reg) & 0x7)) // /0
		_write_imm32(buffer, u32(imm))
	} else { 	// Use 64-bit immediate (B8+r io)
		rex_b := (u8(reg) & 0x8) != 0
		rex := get_rex_prefix(true, false, false, rex_b)
		if rex != 0 do _write_byte(buffer, rex)
		_write_byte(buffer, 0xB8 + (u8(reg) & 0x7))
		_write_imm64(buffer, imm)
	}
}

mov_r32_imm32 :: proc(buffer: ^ByteBuffer, reg: Register32, imm: u32) {
	rex_b := (u8(reg) & 0x8) != 0
	rex := get_rex_prefix(false, false, false, rex_b) // No REX.W
	if rex != 0 do _write_byte(buffer, rex)
	_write_byte(buffer, 0xB8 + (u8(reg) & 0x7))
	_write_imm32(buffer, imm)
}

mov_r16_imm16 :: proc(buffer: ^ByteBuffer, reg: Register16, imm: u16) {
	_write_byte(buffer, 0x66) // Operand size prefix
	rex_b := (u8(reg) & 0x8) != 0
	rex := get_rex_prefix(false, false, false, rex_b) // No REX.W
	if rex != 0 do _write_byte(buffer, rex)
	_write_byte(buffer, 0xB8 + (u8(reg) & 0x7))
	_write_imm16(buffer, imm)
}

mov_r8_imm8 :: proc(buffer: ^ByteBuffer, reg: Register8, imm: u8) {
	rm := u8(reg) & 0xF
	is_high := _is_high_byte_r8(reg)
	needs_rex := !is_high && _is_rex_requiring_r8(reg)

	if is_high {
		_write_byte(buffer, 0xB0 + (rm - 16 + 4)) // B4+rb
		_write_imm8(buffer, imm)
	} else {
		rex_b := (rm & 0x8) != 0
		rex := get_rex_prefix(false, false, false, rex_b, needs_rex)
		if rex != 0 do _write_byte(buffer, rex)
		_write_byte(buffer, 0xB0 + (rm & 0x7))
		_write_imm8(buffer, imm)
	}
}

movabs_r64_imm64 :: proc(buffer: ^ByteBuffer, dst: Register64, imm: u64) {
	// MOVABS RAX, imm64 is REX.W A1 io
	// MOVABS R_other, imm64 is REX.W B8+r io (same as mov r64, imm64)
	// We'll use the B8+r form for consistency, assembler might optimize to A1 for RAX.
	mov_r64_imm64(buffer, dst, imm)
}

// --- Sign/Zero Extend Moves ---
movsx_r64_r32 :: proc(buffer: ^ByteBuffer, dst: Register64, src: Register32) {
	// MOVSXD r64, r/m32 (REX.W + 63 /r)
	_encode_rex_modrm(buffer, .DWord, true, []u8{0x63}, dst, src)
}
movsxd_r64_r32 :: proc(buffer: ^ByteBuffer, dst: Register64, src: Register32) {
	movsx_r64_r32(buffer, dst, src) // Alias
}

movzx_r64_r8 :: proc(buffer: ^ByteBuffer, dst: Register64, src: Register8) {
	if _is_high_byte_r8(src) {
		fmt.eprintf("Encoding Error: Cannot use high byte register (AH-DH) as source for MOVZX.\n")
		return
	}
	// REX.W + 0F B6 /r
	_encode_rex_modrm(
		buffer,
		.Byte,
		true,
		[]u8{0x0F, 0xB6},
		dst,
		src,
		force_rex = _is_rex_requiring_r8(src),
	)
}
movzx_r64_r16 :: proc(buffer: ^ByteBuffer, dst: Register64, src: Register16) {
	// REX.W + 0F B7 /r
	_encode_rex_modrm(buffer, .Word, true, []u8{0x0F, 0xB7}, dst, src)
}

movsx_r64_r8 :: proc(buffer: ^ByteBuffer, dst: Register64, src: Register8) {
	if _is_high_byte_r8(src) {
		fmt.eprintf("Encoding Error: Cannot use high byte register (AH-DH) as source for MOVSX.\n")
		return
	}
	// REX.W + 0F BE /r
	_encode_rex_modrm(
		buffer,
		.Byte,
		true,
		[]u8{0x0F, 0xBE},
		dst,
		src,
		force_rex = _is_rex_requiring_r8(src),
	)
}
movsx_r64_r16 :: proc(buffer: ^ByteBuffer, dst: Register64, src: Register16) {
	// REX.W + 0F BF /r
	_encode_rex_modrm(buffer, .Word, true, []u8{0x0F, 0xBF}, dst, src)
}

movzx_r32_r8 :: proc(buffer: ^ByteBuffer, dst: Register32, src: Register8) {
	if _is_high_byte_r8(src) {
		fmt.eprintf("Encoding Error: Cannot use high byte register (AH-DH) as source for MOVZX.\n")
		return
	}
	// 0F B6 /r
	_encode_rex_modrm(
		buffer,
		.Byte,
		false,
		[]u8{0x0F, 0xB6},
		dst,
		src,
		force_rex = _is_rex_requiring_r8(src),
	)
}
movzx_r32_r16 :: proc(buffer: ^ByteBuffer, dst: Register32, src: Register16) {
	// 0F B7 /r
	_encode_rex_modrm(buffer, .Word, false, []u8{0x0F, 0xB7}, dst, src)
}

movsx_r32_r8 :: proc(buffer: ^ByteBuffer, dst: Register32, src: Register8) {
	if _is_high_byte_r8(src) {
		fmt.eprintf("Encoding Error: Cannot use high byte register (AH-DH) as source for MOVSX.\n")
		return
	}
	// 0F BE /r
	_encode_rex_modrm(
		buffer,
		.Byte,
		false,
		[]u8{0x0F, 0xBE},
		dst,
		src,
		force_rex = _is_rex_requiring_r8(src),
	)
}
movsx_r32_r16 :: proc(buffer: ^ByteBuffer, dst: Register32, src: Register16) {
	// 0F BF /r
	_encode_rex_modrm(buffer, .Word, false, []u8{0x0F, 0xBF}, dst, src)
}

movzx_r16_r8 :: proc(buffer: ^ByteBuffer, dst: Register16, src: Register8) {
	if _is_high_byte_r8(src) {
		fmt.eprintf("Encoding Error: Cannot use high byte register (AH-DH) as source for MOVZX.\n")
		return
	}
	// 66 + 0F B6 /r
	_encode_rex_modrm(
		buffer,
		.Byte,
		false,
		[]u8{0x0F, 0xB6},
		dst,
		src,
		prefix_66 = true,
		force_rex = _is_rex_requiring_r8(src),
	)
}
movsx_r16_r8 :: proc(buffer: ^ByteBuffer, dst: Register16, src: Register8) {
	if _is_high_byte_r8(src) {
		fmt.eprintf("Encoding Error: Cannot use high byte register (AH-DH) as source for MOVSX.\n")
		return
	}
	// 66 + 0F BE /r
	_encode_rex_modrm(
		buffer,
		.Byte,
		false,
		[]u8{0x0F, 0xBE},
		dst,
		src,
		prefix_66 = true,
		force_rex = _is_rex_requiring_r8(src),
	)
}

// --- LEA ---
lea_r64_m64 :: proc(buffer: ^ByteBuffer, dst: Register64, mem: MemoryAddress) {
	// LEA doesn't care about data size, only address size (64-bit). REX.W is used.
	_encode_rex_modrm(buffer, .QWord, true, []u8{0x8D}, dst, mem) // REX.W + 8D /r
}
lea_r32_m :: proc(buffer: ^ByteBuffer, dst: Register32, mem: MemoryAddress) {
	// Address size is 64-bit, but destination is 32-bit. No REX.W.
	_encode_rex_modrm(buffer, .DWord, false, []u8{0x8D}, dst, mem) // 8D /r
}
lea_r16_m :: proc(buffer: ^ByteBuffer, dst: Register16, mem: MemoryAddress) {
	// Address size is 64-bit, but destination is 16-bit. No REX.W, needs 0x66.
	_encode_rex_modrm(buffer, .Word, false, []u8{0x8D}, dst, mem, prefix_66 = true) // 66 + 8D /r
}


// --- XCHG ---
xchg_r64_r64 :: proc(buffer: ^ByteBuffer, reg1: Register64, reg2: Register64) {
	// Optimize XCHG RAX, reg <-> XCHG reg, RAX to 90+r
	if reg1 == .RAX {
		if u8(reg2) >= 8 {_write_byte(buffer, 0x49)} else {_write_byte(buffer, 0x48)} 	// REX.W + REX.B if needed
		_write_byte(buffer, 0x90 + (u8(reg2) & 0x7))
	} else if reg2 == .RAX {
		if u8(reg1) >= 8 {_write_byte(buffer, 0x49)} else {_write_byte(buffer, 0x48)} 	// REX.W + REX.B if needed
		_write_byte(buffer, 0x90 + (u8(reg1) & 0x7))
	} else {
		// General case: REX.W + 87 /r
		_encode_rex_modrm(buffer, .QWord, nil, []u8{0x87}, reg2, reg1) // ModR/M encodes (reg2, reg1) for XCHG r/m64, r64
	}
}
xchg_r32_r32 :: proc(buffer: ^ByteBuffer, reg1: Register32, reg2: Register32) {
	if reg1 == .EAX {
		rex_b := (u8(reg2) & 0x8) != 0
		if rex_b do _write_byte(buffer, 0x41) // REX.B for r8d-r15d
		_write_byte(buffer, 0x90 + (u8(reg2) & 0x7))
	} else if reg2 == .EAX {
		rex_b := (u8(reg1) & 0x8) != 0
		if rex_b do _write_byte(buffer, 0x41) // REX.B for r8d-r15d
		_write_byte(buffer, 0x90 + (u8(reg1) & 0x7))
	} else {
		// General case: 87 /r
		_encode_rex_modrm(buffer, .DWord, nil, []u8{0x87}, reg2, reg1)
	}
}
xchg_r16_r16 :: proc(buffer: ^ByteBuffer, reg1: Register16, reg2: Register16) {
	_write_byte(buffer, 0x66)
	if reg1 == .AX {
		rex_b := (u8(reg2) & 0x8) != 0
		if rex_b do _write_byte(buffer, 0x41) // REX.B
		_write_byte(buffer, 0x90 + (u8(reg2) & 0x7))
	} else if reg2 == .AX {
		rex_b := (u8(reg1) & 0x8) != 0
		if rex_b do _write_byte(buffer, 0x41) // REX.B
		_write_byte(buffer, 0x90 + (u8(reg1) & 0x7))
	} else {
		// General case: 66 + 87 /r
		_encode_rex_modrm(buffer, .Word, nil, []u8{0x87}, reg2, reg1, prefix_66 = false) // 0x66 already written
	}
}
xchg_r8_r8 :: proc(buffer: ^ByteBuffer, reg1: Register8, reg2: Register8) {
	// 86 /r: XCHG r/m8, r8
	// Must handle high bytes carefully
	if (_is_high_byte_r8(reg1) || _is_high_byte_r8(reg2)) &&
	   (_is_rex_requiring_r8(reg1) || _is_rex_requiring_r8(reg2)) {
		fmt.eprintf(
			"Encoding Error: Cannot mix high byte (AH-DH) and REX-requiring (SPL-R15B) 8-bit registers in XCHG.\n",
		)
		return
	}
	_encode_rex_modrm(buffer, .Byte, nil, []u8{0x86}, reg2, reg1)
}

// --- BSWAP ---
bswap_r64 :: proc(buffer: ^ByteBuffer, reg: Register64) {
	rex_b := (u8(reg) & 0x8) != 0
	rex := get_rex_prefix(true, false, false, rex_b) // REX.W
	if rex != 0 do _write_byte(buffer, rex)
	_write_byte(buffer, 0x0F)
	_write_byte(buffer, 0xC8 + (u8(reg) & 0x7)) // 0F C8+rd
}

// --- MOVBE ---
movbe_r64_m64 :: proc(buffer: ^ByteBuffer, dst: Register64, mem: MemoryAddress) {
	_encode_rex_modrm(buffer, .QWord, true, []u8{0x0F, 0x38, 0xF0}, dst, mem) // REX.W + 0F 38 F0 /r
}
movbe_m64_r64 :: proc(buffer: ^ByteBuffer, mem: MemoryAddress, src: Register64) {
	_encode_rex_modrm(buffer, .QWord, true, []u8{0x0F, 0x38, 0xF1}, src, mem) // REX.W + 0F 38 F1 /r
}

// --- Segment, Control, Debug Registers ---
// (These have very specific encodings, less generalizable)
mov_sreg_r16 :: proc(buffer: ^ByteBuffer, dst: SegmentRegister, src: Register16) {
	rex_b := (u8(src) & 0x8) != 0
	rex := get_rex_prefix(false, false, false, rex_b)
	if rex != 0 do _write_byte(buffer, rex)
	_write_byte(buffer, 0x8E)
	_write_byte(buffer, encode_modrm(3, u8(dst), u8(src) & 0x7))
}
mov_r16_sreg :: proc(buffer: ^ByteBuffer, dst: Register16, src: SegmentRegister) {
	_write_byte(buffer, 0x66)
	rex_b := (u8(dst) & 0x8) != 0
	rex := get_rex_prefix(false, false, false, rex_b)
	if rex != 0 do _write_byte(buffer, rex)
	_write_byte(buffer, 0x8C)
	_write_byte(buffer, encode_modrm(3, u8(src), u8(dst) & 0x7))
}
mov_sreg_m16 :: proc(buffer: ^ByteBuffer, dst: SegmentRegister, mem: MemoryAddress) {
	// 8E /r (No REX.W needed for segment registers)
	_encode_rex_modrm(buffer, .Word, false, []u8{0x8E}, dst, mem)
}
mov_m16_sreg :: proc(buffer: ^ByteBuffer, mem: MemoryAddress, src: SegmentRegister) {
	// 8C /r (No REX.W needed for segment registers)
	_encode_rex_modrm(buffer, .Word, false, []u8{0x8C}, src, mem)
}

mov_r64_cr :: proc(buffer: ^ByteBuffer, dst: Register64, src: ControlRegister) {
	// 0F 20 /r : MOV r64, CRn
	// REX.R encodes CR8 vs others, REX.B encodes r8-r15 vs others
	rex_r := u8(src) == 8 // REX.R only for CR8
	rex_b := (u8(dst) & 0x8) != 0
	rex := get_rex_prefix(false, rex_r, false, rex_b, rex_r) // Force REX if CR8
	if rex != 0 do _write_byte(buffer, rex)
	_write_byte(buffer, 0x0F)
	_write_byte(buffer, 0x20)
	_write_byte(buffer, encode_modrm(3, u8(src) & 0x7, u8(dst) & 0x7))
}
mov_cr_r64 :: proc(buffer: ^ByteBuffer, dst: ControlRegister, src: Register64) {
	// 0F 22 /r : MOV CRn, r64
	rex_r := u8(dst) == 8 // REX.R only for CR8
	rex_b := (u8(src) & 0x8) != 0
	rex := get_rex_prefix(false, rex_r, false, rex_b, rex_r) // Force REX if CR8
	if rex != 0 do _write_byte(buffer, rex)
	_write_byte(buffer, 0x0F)
	_write_byte(buffer, 0x22)
	_write_byte(buffer, encode_modrm(3, u8(dst) & 0x7, u8(src) & 0x7))
}
mov_r64_dr :: proc(buffer: ^ByteBuffer, dst: Register64, src: DebugRegister) {
	// 0F 21 /r : MOV r64, DRn
	rex_b := (u8(dst) & 0x8) != 0
	rex := get_rex_prefix(false, false, false, rex_b)
	if rex != 0 do _write_byte(buffer, rex)
	_write_byte(buffer, 0x0F)
	_write_byte(buffer, 0x21)
	_write_byte(buffer, encode_modrm(3, u8(src) & 0x7, u8(dst) & 0x7))
}
mov_dr_r64 :: proc(buffer: ^ByteBuffer, dst: DebugRegister, src: Register64) {
	// 0F 23 /r : MOV DRn, r64
	rex_b := (u8(src) & 0x8) != 0
	rex := get_rex_prefix(false, false, false, rex_b)
	if rex != 0 do _write_byte(buffer, rex)
	_write_byte(buffer, 0x0F)
	_write_byte(buffer, 0x23)
	_write_byte(buffer, encode_modrm(3, u8(dst) & 0x7, u8(src) & 0x7))
}


// ==================================
// Arithmetic Instructions (ADD, SUB, MUL, DIV, INC, DEC, NEG, CMP, TEST)
// ==================================

// Internal helper for ADD, OR, ADC, SBB, AND, SUB, XOR, CMP immediate encodings (80, 81, 83)
@(private)
_encode_imm_arith_logic :: proc(
	buffer: ^ByteBuffer,
	op_size: OperandSize,
	opcode_ext: u8, // Value for ModR/M.reg field (0=ADD, 1=OR, 2=ADC, 3=SBB, 4=AND, 5=SUB, 6=XOR, 7=CMP)
	rm_op: $T, // Register or MemoryAddress
	imm: $U, // u32 or u16 or u8
) where T == Register64 || T == Register32 || T == Register16 || T == Register8 || T == MemoryAddress,
	U == u32 || U == u16 || U == u8 {

	// Determine REX.W and 0x66 Prefix
	rex_w := op_size == .QWord
	prefix_66 := op_size == .Word

	// Determine REX.R/X/B needs
	rex_r, rex_x, rex_b := false, false, false
	is_r8 := false
	rm_val: u8 = 0
	force_rex := false

	switch v in rm_op {
	case Register64, Register32, Register16:
		rm_val = u8(v)
		rex_b = (rm_val & 0x8) != 0
	case Register8:
		rm_val = u8(v)
		is_r8 = true
		if _is_high_byte_r8(v) {
			rm_val = (rm_val - 16) | 4
		} else {
			rex_b = (rm_val & 0x8) != 0
			force_rex = _is_rex_requiring_r8(v)
		}
	case MemoryAddress:
	// REX.X, REX.B will be determined by _encode_mem_modrm_sib_disp
	}

	// Select Opcode and Immediate Size
	opcode: u8
	imm_size: OperandSize
	imm_val_trunc: u32 // Truncated immediate value for encoding
	is_acc_special_case := false

	switch i in imm {
	case u32:
		// Typically for 64/32 bit ops
		imm_val_trunc = i
		// Use 83 ib if immediate fits in signed 8 bits, else 81 id
		if i64(i) >= -128 && i64(i) <= 127 && op_size != .Word { 	// 83 not valid for 16-bit imm16
			opcode = 0x83
			imm_size = .Byte
		} else {
			opcode = 0x81
			if op_size == .QWord || op_size == .DWord {
				imm_size = .DWord
			} else {
				fmt.eprintf("Encoding Error: Invalid immediate size for operation.\n")
				return
			}
		}

		// Special case for AL/AX/EAX/RAX (no ModR/M)
		is_acc := false

		switch v in rm_op {
		case Register8:
			is_acc = v == .AL && !_is_rex_requiring_r8(v)
		case Register16:
			is_acc = v == .AX && !rex_b
		case Register32:
			is_acc = v == .EAX && !rex_b
		case Register64:
			is_acc = v == .RAX && !rex_b
		}

		if is_acc && opcode == 0x81 {
			acc_opcodes := [8]u8{0x05, 0x0D, 0x15, 0x1D, 0x25, 0x2D, 0x35, 0x3D} // ADD,OR,ADC,SBB,AND,SUB,XOR,CMP AL/AX/EAX/RAX, imm
			opcode = acc_opcodes[opcode_ext]
			is_acc_special_case = true
		}

	case u16:
		// Typically for 16 bit ops
		imm_val_trunc = u32(i)
		if i64(i16(i)) >= -128 && i64(i16(i)) <= 127 {
			opcode = 0x83
			imm_size = .Byte
		} else {
			opcode = 0x81
			imm_size = .Word
		}

		is_acc := false
		switch v in rm_op {
		case Register16:
			is_acc = v == .AX && !rex_b
		}

		if is_acc && opcode == 0x81 {
			acc_opcodes := [8]u8{0x05, 0x0D, 0x15, 0x1D, 0x25, 0x2D, 0x35, 0x3D}
			opcode = acc_opcodes[opcode_ext]
			is_acc_special_case = true
		}

	case u8:
		// Typically for 8 bit ops
		opcode = 0x80
		imm_size = .Byte
		imm_val_trunc = u32(i)

		is_acc := false
		switch v in rm_op {
		case Register8:
			is_acc = v == .AL && !_is_rex_requiring_r8(v)
		}

		if is_acc {
			acc_opcodes := [8]u8{0x04, 0x0C, 0x14, 0x1C, 0x24, 0x2C, 0x34, 0x3C}
			opcode = acc_opcodes[opcode_ext]
			is_acc_special_case = true
		}
	}

	// We now handle both paths based on the is_acc_special_case flag
	if is_acc_special_case {
		// Accumulator special case path (previously goto emit_acc_imm)
		if prefix_66 do _write_byte(buffer, 0x66)
		rex := get_rex_prefix(rex_w, false, false, rex_b, force_rex)
		if rex != 0 do _write_byte(buffer, rex)
		_write_byte(buffer, opcode)

		// Emit Immediate
		switch imm_size {
		case .Byte:
			_write_imm8(buffer, u8(imm_val_trunc))
		case .Word:
			_write_imm16(buffer, u16(imm_val_trunc))
		case .DWord:
			_write_imm32(buffer, imm_val_trunc)
		}
	} else {
		// Standard path with ModR/M
		// Emit Prefixes and Opcode
		if prefix_66 do _write_byte(buffer, 0x66)
		rex_byte_mem: u8 // Placeholder for REX if memory operand
		mem_rex_x, mem_rex_b := false, false
		mem_mode := false

		switch v in rm_op {
		case MemoryAddress:
			mem_mode = true
		// Defer REX emission
		case Register64, Register32, Register16, Register8:
			if is_r8 && _is_high_byte_r8(rm_op.(Register8)) {
				// No REX for high bytes
			} else {
				rex := get_rex_prefix(rex_w, false, false, rex_b, force_rex)
				if rex != 0 do _write_byte(buffer, rex)
			}
		}

		opcode_start_index := buffer.len
		_write_byte(buffer, opcode)

		// Emit ModR/M, SIB, Displacement
		switch v in rm_op {
		case MemoryAddress:
			mem_rex_x, mem_rex_b = _encode_mem_modrm_sib_disp(buffer, v, opcode_ext)
			rex_byte_mem = get_rex_prefix(rex_w, false, mem_rex_x, mem_rex_b, force_rex)
			if rex_byte_mem != 0 {
				// Shift and insert REX
				required_size := buffer.len + 1
				if required_size > buffer.cap {grow(buffer, required_size)}
				mem.move_ptr(
					raw_data(buffer.data[opcode_start_index + 1:]),
					raw_data(buffer.data[opcode_start_index:]),
					buffer.len - opcode_start_index,
				)
				buffer.data[opcode_start_index] = rex_byte_mem
				buffer.len += 1
			}
		case Register64, Register32, Register16, Register8:
			_write_byte(buffer, encode_modrm(3, opcode_ext, rm_val & 0x7))
		}

		// Emit Immediate
		switch imm_size {
		case .Byte:
			_write_imm8(buffer, u8(imm_val_trunc))
		case .Word:
			_write_imm16(buffer, u16(imm_val_trunc))
		case .DWord:
			_write_imm32(buffer, imm_val_trunc)
		}
	}
}
// ADD
add_r64_r64 :: proc(buffer: ^ByteBuffer, dst: Register64, src: Register64) {_encode_rex_modrm(
		buffer,
		.QWord,
		nil,
		[]u8{0x01},
		src,
		dst,
	)} // 01 /r
add_r32_r32 :: proc(buffer: ^ByteBuffer, dst: Register32, src: Register32) {_encode_rex_modrm(
		buffer,
		.DWord,
		nil,
		[]u8{0x01},
		src,
		dst,
	)} // 01 /r
add_r16_r16 :: proc(buffer: ^ByteBuffer, dst: Register16, src: Register16) {_encode_rex_modrm(
		buffer,
		.Word,
		nil,
		[]u8{0x01},
		src,
		dst,
	)} // 66 01 /r
add_r8_r8 :: proc(buffer: ^ByteBuffer, dst: Register8, src: Register8) {
	if (_is_high_byte_r8(dst) || _is_high_byte_r8(src)) &&
	   (_is_rex_requiring_r8(dst) || _is_rex_requiring_r8(src)) {
		fmt.eprintf(
			"Encoding Error: Cannot mix high byte (AH-DH) and REX-requiring (SPL-R15B) 8-bit registers in ADD.\n",
		)
		return
	}
	_encode_rex_modrm(buffer, .Byte, nil, []u8{0x00}, src, dst) // 00 /r
}

add_r64_m64 :: proc(buffer: ^ByteBuffer, dst: Register64, mem: MemoryAddress) {_encode_rex_modrm(
		buffer,
		.QWord,
		nil,
		[]u8{0x03},
		dst,
		mem,
	)} // 03 /r
add_r32_m32 :: proc(buffer: ^ByteBuffer, dst: Register32, mem: MemoryAddress) {_encode_rex_modrm(
		buffer,
		.DWord,
		nil,
		[]u8{0x03},
		dst,
		mem,
	)} // 03 /r
add_r16_m16 :: proc(buffer: ^ByteBuffer, dst: Register16, mem: MemoryAddress) {_encode_rex_modrm(
		buffer,
		.Word,
		nil,
		[]u8{0x03},
		dst,
		mem,
	)} // 66 03 /r
add_r8_m8 :: proc(buffer: ^ByteBuffer, dst: Register8, mem: MemoryAddress) {
	if _is_high_byte_r8(
		dst,
	) {fmt.eprintf("Encoding Error: Cannot use high byte register as destination for ADD from memory.\n");return}
	_encode_rex_modrm(
		buffer,
		.Byte,
		nil,
		[]u8{0x02},
		dst,
		mem,
		force_rex = _is_rex_requiring_r8(dst),
	) // 02 /r
}

add_m64_r64 :: proc(buffer: ^ByteBuffer, mem: MemoryAddress, src: Register64) {_encode_rex_modrm(
		buffer,
		.QWord,
		nil,
		[]u8{0x01},
		src,
		mem,
	)} // 01 /r
add_m32_r32 :: proc(buffer: ^ByteBuffer, mem: MemoryAddress, src: Register32) {_encode_rex_modrm(
		buffer,
		.DWord,
		nil,
		[]u8{0x01},
		src,
		mem,
	)} // 01 /r
add_m16_r16 :: proc(buffer: ^ByteBuffer, mem: MemoryAddress, src: Register16) {_encode_rex_modrm(
		buffer,
		.Word,
		nil,
		[]u8{0x01},
		src,
		mem,
	)} // 66 01 /r
add_m8_r8 :: proc(buffer: ^ByteBuffer, mem: MemoryAddress, src: Register8) {
	if _is_high_byte_r8(
		src,
	) {fmt.eprintf("Encoding Error: Cannot use high byte register as source for ADD to memory.\n");return}
	_encode_rex_modrm(
		buffer,
		.Byte,
		nil,
		[]u8{0x00},
		src,
		mem,
		force_rex = _is_rex_requiring_r8(src),
	) // 00 /r
}


add_r64_imm32 :: proc(buffer: ^ByteBuffer, reg: Register64, imm: u32) {_encode_imm_arith_logic(
		buffer,
		.QWord,
		0,
		reg,
		imm,
	)}
add_r32_imm32 :: proc(buffer: ^ByteBuffer, reg: Register32, imm: u32) {_encode_imm_arith_logic(
		buffer,
		.DWord,
		0,
		reg,
		imm,
	)}
add_r16_imm16 :: proc(buffer: ^ByteBuffer, reg: Register16, imm: u16) {_encode_imm_arith_logic(
		buffer,
		.Word,
		0,
		reg,
		imm,
	)}
add_r8_imm8 :: proc(buffer: ^ByteBuffer, reg: Register8, imm: u8) {_encode_imm_arith_logic(
		buffer,
		.Byte,
		0,
		reg,
		imm,
	)}
// Simpler alias for common case
add_r64_imm8 :: proc(buffer: ^ByteBuffer, reg: Register64, imm: u8) {add_r64_imm32(
		buffer,
		reg,
		u32(i32(i8(imm))),
	)} // Sign extend
add_r32_imm8 :: proc(buffer: ^ByteBuffer, reg: Register32, imm: u8) {add_r32_imm32(
		buffer,
		reg,
		u32(i32(i8(imm))),
	)} // Sign extend
add_r16_imm8 :: proc(buffer: ^ByteBuffer, reg: Register16, imm: u8) {add_r16_imm16(
		buffer,
		reg,
		u16(i16(i8(imm))),
	)} // Sign extend


add_m64_imm32 :: proc(buffer: ^ByteBuffer, mem: MemoryAddress, imm: u32) {_encode_imm_arith_logic(
		buffer,
		.QWord,
		0,
		mem,
		imm,
	)}
add_m32_imm32 :: proc(buffer: ^ByteBuffer, mem: MemoryAddress, imm: u32) {_encode_imm_arith_logic(
		buffer,
		.DWord,
		0,
		mem,
		imm,
	)}
add_m16_imm16 :: proc(buffer: ^ByteBuffer, mem: MemoryAddress, imm: u16) {_encode_imm_arith_logic(
		buffer,
		.Word,
		0,
		mem,
		imm,
	)}
add_m8_imm8 :: proc(buffer: ^ByteBuffer, mem: MemoryAddress, imm: u8) {_encode_imm_arith_logic(
		buffer,
		.Byte,
		0,
		mem,
		imm,
	)}


// SUB (Similar structure to ADD, using opcode_ext = 5)
sub_r64_r64 :: proc(buffer: ^ByteBuffer, dst: Register64, src: Register64) {_encode_rex_modrm(
		buffer,
		.QWord,
		nil,
		[]u8{0x29},
		src,
		dst,
	)} // 29 /r
sub_r32_r32 :: proc(buffer: ^ByteBuffer, dst: Register32, src: Register32) {_encode_rex_modrm(
		buffer,
		.DWord,
		nil,
		[]u8{0x29},
		src,
		dst,
	)} // 29 /r
sub_r16_r16 :: proc(buffer: ^ByteBuffer, dst: Register16, src: Register16) {_encode_rex_modrm(
		buffer,
		.Word,
		nil,
		[]u8{0x29},
		src,
		dst,
	)} // 66 29 /r
sub_r8_r8 :: proc(buffer: ^ByteBuffer, dst: Register8, src: Register8) {
	if (_is_high_byte_r8(dst) || _is_high_byte_r8(src)) &&
	   (_is_rex_requiring_r8(dst) ||
			   _is_rex_requiring_r8(
				   src,
			   )) {fmt.eprintf("Encoding Error: SUB r8,r8 high/rex mix\n");return}
	_encode_rex_modrm(buffer, .Byte, nil, []u8{0x28}, src, dst) // 28 /r
}
sub_r64_m64 :: proc(buffer: ^ByteBuffer, dst: Register64, mem: MemoryAddress) {_encode_rex_modrm(
		buffer,
		.QWord,
		nil,
		[]u8{0x2B},
		dst,
		mem,
	)} // 2B /r
sub_r32_m32 :: proc(buffer: ^ByteBuffer, dst: Register32, mem: MemoryAddress) {_encode_rex_modrm(
		buffer,
		.DWord,
		nil,
		[]u8{0x2B},
		dst,
		mem,
	)} // 2B /r
sub_r16_m16 :: proc(buffer: ^ByteBuffer, dst: Register16, mem: MemoryAddress) {_encode_rex_modrm(
		buffer,
		.Word,
		nil,
		[]u8{0x2B},
		dst,
		mem,
	)} // 66 2B /r
sub_r8_m8 :: proc(buffer: ^ByteBuffer, dst: Register8, mem: MemoryAddress) {
	if _is_high_byte_r8(dst) {fmt.eprintf("Encoding Error: SUB r8,m8 high byte dst\n");return}
	_encode_rex_modrm(
		buffer,
		.Byte,
		nil,
		[]u8{0x2A},
		dst,
		mem,
		force_rex = _is_rex_requiring_r8(dst),
	) // 2A /r
}
sub_m64_r64 :: proc(buffer: ^ByteBuffer, mem: MemoryAddress, src: Register64) {_encode_rex_modrm(
		buffer,
		.QWord,
		nil,
		[]u8{0x29},
		src,
		mem,
	)} // 29 /r
sub_m32_r32 :: proc(buffer: ^ByteBuffer, mem: MemoryAddress, src: Register32) {_encode_rex_modrm(
		buffer,
		.DWord,
		nil,
		[]u8{0x29},
		src,
		mem,
	)} // 29 /r
sub_m16_r16 :: proc(buffer: ^ByteBuffer, mem: MemoryAddress, src: Register16) {_encode_rex_modrm(
		buffer,
		.Word,
		nil,
		[]u8{0x29},
		src,
		mem,
	)} // 66 29 /r
sub_m8_r8 :: proc(buffer: ^ByteBuffer, mem: MemoryAddress, src: Register8) {
	if _is_high_byte_r8(src) {fmt.eprintf("Encoding Error: SUB m8,r8 high byte src\n");return}
	_encode_rex_modrm(
		buffer,
		.Byte,
		nil,
		[]u8{0x28},
		src,
		mem,
		force_rex = _is_rex_requiring_r8(src),
	) // 28 /r
}
sub_r64_imm32 :: proc(buffer: ^ByteBuffer, reg: Register64, imm: u32) {_encode_imm_arith_logic(
		buffer,
		.QWord,
		5,
		reg,
		imm,
	)}
sub_r32_imm32 :: proc(buffer: ^ByteBuffer, reg: Register32, imm: u32) {_encode_imm_arith_logic(
		buffer,
		.DWord,
		5,
		reg,
		imm,
	)}
sub_r16_imm16 :: proc(buffer: ^ByteBuffer, reg: Register16, imm: u16) {_encode_imm_arith_logic(
		buffer,
		.Word,
		5,
		reg,
		imm,
	)}
sub_r8_imm8 :: proc(buffer: ^ByteBuffer, reg: Register8, imm: u8) {_encode_imm_arith_logic(
		buffer,
		.Byte,
		5,
		reg,
		imm,
	)}
sub_r64_imm8 :: proc(buffer: ^ByteBuffer, reg: Register64, imm: u8) {sub_r64_imm32(
		buffer,
		reg,
		u32(i32(i8(imm))),
	)}
sub_r32_imm8 :: proc(buffer: ^ByteBuffer, reg: Register32, imm: u8) {sub_r32_imm32(
		buffer,
		reg,
		u32(i32(i8(imm))),
	)}
sub_r16_imm8 :: proc(buffer: ^ByteBuffer, reg: Register16, imm: u8) {sub_r16_imm16(
		buffer,
		reg,
		u16(i16(i8(imm))),
	)}
sub_m64_imm32 :: proc(buffer: ^ByteBuffer, mem: MemoryAddress, imm: u32) {_encode_imm_arith_logic(
		buffer,
		.QWord,
		5,
		mem,
		imm,
	)}
sub_m32_imm32 :: proc(buffer: ^ByteBuffer, mem: MemoryAddress, imm: u32) {_encode_imm_arith_logic(
		buffer,
		.DWord,
		5,
		mem,
		imm,
	)}
sub_m16_imm16 :: proc(buffer: ^ByteBuffer, mem: MemoryAddress, imm: u16) {_encode_imm_arith_logic(
		buffer,
		.Word,
		5,
		mem,
		imm,
	)}
sub_m8_imm8 :: proc(buffer: ^ByteBuffer, mem: MemoryAddress, imm: u8) {_encode_imm_arith_logic(
		buffer,
		.Byte,
		5,
		mem,
		imm,
	)}

// --- INC / DEC / NEG / NOT ---
// These use Opcode FF or F7 with an opcode extension in ModR/M.reg
@(private)
_encode_unary_rm :: proc(
	buffer: ^ByteBuffer,
	op_size: OperandSize,
	opcode: u8,
	opcode_ext: u8,
	rm_op: $T,
) where T == Register64 ||
	T == Register32 ||
	T == Register16 ||
	T == Register8 ||
	T == MemoryAddress {

	rex_w := op_size == .QWord
	prefix_66 := op_size == .Word

	rex_r, rex_x, rex_b := false, false, false
	is_r8 := false
	rm_val: u8 = 0
	force_rex := false

	#partial switch v in rm_op {
	case Register64, Register32, Register16:
		rm_val = u8(v)
		rex_b = (rm_val & 0x8) != 0
	case Register8:
		rm_val = u8(v)
		is_r8 = true
		if _is_high_byte_r8(v) {
			rm_val = (rm_val - 16) | 4
		} else {
			rex_b = (rm_val & 0x8) != 0
			force_rex = _is_rex_requiring_r8(v)
		}
	case MemoryAddress:
		break // REX.X/B determined later
	}

	// Emit prefixes
	if prefix_66 do _write_byte(buffer, 0x66)

	// Write REX (or defer if memory)
	rex_byte_mem: u8
	#partial switch v in rm_op {
	case MemoryAddress:
		break // Defer
	case T:
		if is_r8 && _is_high_byte_r8(rm_op.(Register8)) {
			// No REX
		} else {
			rex := get_rex_prefix(rex_w, false, false, rex_b, force_rex)
			if rex != 0 do _write_byte(buffer, rex)
		}
	}
	opcode_start_index := buffer.len
	_write_byte(buffer, opcode)

	// Write ModR/M, SIB, Disp
	#partial switch v in rm_op {
	case MemoryAddress:
		mem_rex_x, mem_rex_b = _encode_mem_modrm_sib_disp(buffer, v, opcode_ext)
		rex_byte_mem = get_rex_prefix(rex_w, false, mem_rex_x, mem_rex_b, force_rex)
		if rex_byte_mem != 0 {
			// Shift and insert REX
			required_size := buffer.len + 1
			if required_size > buffer.cap {grow(buffer, required_size)}
			mem.move_ptr(
				raw_data(buffer.data[opcode_start_index + 1:]),
				raw_data(buffer.data[opcode_start_index:]),
				buffer.len - opcode_start_index,
			)
			buffer.data[opcode_start_index] = rex_byte_mem
			buffer.len += 1
		}
	case T:
		// Register
		_write_byte(buffer, encode_modrm(3, opcode_ext, rm_val & 0x7))
	}
}

inc_r64 :: proc(buffer: ^ByteBuffer, reg: Register64) {_encode_unary_rm(
		buffer,
		.QWord,
		0xFF,
		0,
		reg,
	)}
inc_r32 :: proc(buffer: ^ByteBuffer, reg: Register32) {_encode_unary_rm(
		buffer,
		.DWord,
		0xFF,
		0,
		reg,
	)}
inc_r16 :: proc(buffer: ^ByteBuffer, reg: Register16) {_encode_unary_rm(
		buffer,
		.Word,
		0xFF,
		0,
		reg,
	)}
inc_r8 :: proc(buffer: ^ByteBuffer, reg: Register8) {_encode_unary_rm(
		buffer,
		.Byte,
		0xFE,
		0,
		reg,
	)} // Note different opcode for 8-bit
inc_m64 :: proc(buffer: ^ByteBuffer, mem: MemoryAddress) {_encode_unary_rm(
		buffer,
		.QWord,
		0xFF,
		0,
		mem,
	)}
// inc_m32, inc_m16, inc_m8 similar...

dec_r64 :: proc(buffer: ^ByteBuffer, reg: Register64) {_encode_unary_rm(
		buffer,
		.QWord,
		0xFF,
		1,
		reg,
	)}
dec_r32 :: proc(buffer: ^ByteBuffer, reg: Register32) {_encode_unary_rm(
		buffer,
		.DWord,
		0xFF,
		1,
		reg,
	)}
dec_r16 :: proc(buffer: ^ByteBuffer, reg: Register16) {_encode_unary_rm(
		buffer,
		.Word,
		0xFF,
		1,
		reg,
	)}
dec_r8 :: proc(buffer: ^ByteBuffer, reg: Register8) {_encode_unary_rm(
		buffer,
		.Byte,
		0xFE,
		1,
		reg,
	)} // Note different opcode for 8-bit
dec_m64 :: proc(buffer: ^ByteBuffer, mem: MemoryAddress) {_encode_unary_rm(
		buffer,
		.QWord,
		0xFF,
		1,
		mem,
	)}
// dec_m32, dec_m16, dec_m8 similar...

neg_r64 :: proc(buffer: ^ByteBuffer, reg: Register64) {_encode_unary_rm(
		buffer,
		.QWord,
		0xF7,
		3,
		reg,
	)}
neg_r32 :: proc(buffer: ^ByteBuffer, reg: Register32) {_encode_unary_rm(
		buffer,
		.DWord,
		0xF7,
		3,
		reg,
	)}
neg_r16 :: proc(buffer: ^ByteBuffer, reg: Register16) {_encode_unary_rm(
		buffer,
		.Word,
		0xF7,
		3,
		reg,
	)}
neg_r8 :: proc(buffer: ^ByteBuffer, reg: Register8) {_encode_unary_rm(
		buffer,
		.Byte,
		0xF6,
		3,
		reg,
	)} // Note different opcode
neg_m64 :: proc(buffer: ^ByteBuffer, mem: MemoryAddress) {_encode_unary_rm(
		buffer,
		.QWord,
		0xF7,
		3,
		mem,
	)}
// neg_m32, neg_m16, neg_m8 similar...

not_r64 :: proc(buffer: ^ByteBuffer, reg: Register64) {_encode_unary_rm(
		buffer,
		.QWord,
		0xF7,
		2,
		reg,
	)}
not_r32 :: proc(buffer: ^ByteBuffer, reg: Register32) {_encode_unary_rm(
		buffer,
		.DWord,
		0xF7,
		2,
		reg,
	)}
not_r16 :: proc(buffer: ^ByteBuffer, reg: Register16) {_encode_unary_rm(
		buffer,
		.Word,
		0xF7,
		2,
		reg,
	)}
not_r8 :: proc(buffer: ^ByteBuffer, reg: Register8) {_encode_unary_rm(
		buffer,
		.Byte,
		0xF6,
		2,
		reg,
	)} // Note different opcode
// not_m64, not_m32, not_m16, not_m8 similar...


// --- MUL / DIV / IDIV / IMUL (single operand forms) ---
// These also use F7/F6 opcodes with different extensions
mul_r64 :: proc(buffer: ^ByteBuffer, reg: Register64) {_encode_unary_rm(
		buffer,
		.QWord,
		0xF7,
		4,
		reg,
	)}
mul_r32 :: proc(buffer: ^ByteBuffer, reg: Register32) {_encode_unary_rm(
		buffer,
		.DWord,
		0xF7,
		4,
		reg,
	)}
mul_r16 :: proc(buffer: ^ByteBuffer, reg: Register16) {_encode_unary_rm(
		buffer,
		.Word,
		0xF7,
		4,
		reg,
	)}
mul_r8 :: proc(buffer: ^ByteBuffer, reg: Register8) {_encode_unary_rm(buffer, .Byte, 0xF6, 4, reg)}
mul_m64 :: proc(buffer: ^ByteBuffer, mem: MemoryAddress) {_encode_unary_rm(
		buffer,
		.QWord,
		0xF7,
		4,
		mem,
	)}
// mul_m32, mul_m16, mul_m8 similar...

div_r64 :: proc(buffer: ^ByteBuffer, reg: Register64) {_encode_unary_rm(
		buffer,
		.QWord,
		0xF7,
		6,
		reg,
	)}
div_r32 :: proc(buffer: ^ByteBuffer, reg: Register32) {_encode_unary_rm(
		buffer,
		.DWord,
		0xF7,
		6,
		reg,
	)}
div_r16 :: proc(buffer: ^ByteBuffer, reg: Register16) {_encode_unary_rm(
		buffer,
		.Word,
		0xF7,
		6,
		reg,
	)}
div_r8 :: proc(buffer: ^ByteBuffer, reg: Register8) {_encode_unary_rm(buffer, .Byte, 0xF6, 6, reg)}
div_m64 :: proc(buffer: ^ByteBuffer, mem: MemoryAddress) {_encode_unary_rm(
		buffer,
		.QWord,
		0xF7,
		6,
		mem,
	)}
// div_m32, div_m16, div_m8 similar...

idiv_r64 :: proc(buffer: ^ByteBuffer, reg: Register64) {_encode_unary_rm(
		buffer,
		.QWord,
		0xF7,
		7,
		reg,
	)}
idiv_r32 :: proc(buffer: ^ByteBuffer, reg: Register32) {_encode_unary_rm(
		buffer,
		.DWord,
		0xF7,
		7,
		reg,
	)}
idiv_r16 :: proc(buffer: ^ByteBuffer, reg: Register16) {_encode_unary_rm(
		buffer,
		.Word,
		0xF7,
		7,
		reg,
	)}
idiv_r8 :: proc(buffer: ^ByteBuffer, reg: Register8) {_encode_unary_rm(
		buffer,
		.Byte,
		0xF6,
		7,
		reg,
	)}
idiv_m64 :: proc(buffer: ^ByteBuffer, mem: MemoryAddress) {_encode_unary_rm(
		buffer,
		.QWord,
		0xF7,
		7,
		mem,
	)}
// idiv_m32, idiv_m16, idiv_m8 similar...

imul_r64 :: proc(buffer: ^ByteBuffer, reg: Register64) {_encode_unary_rm(
		buffer,
		.QWord,
		0xF7,
		5,
		reg,
	)} // IMUL r/m64 -> RDX:RAX = RAX * r/m64
imul_r32 :: proc(buffer: ^ByteBuffer, reg: Register32) {_encode_unary_rm(
		buffer,
		.DWord,
		0xF7,
		5,
		reg,
	)} // IMUL r/m32 -> EDX:EAX = EAX * r/m32
imul_r16 :: proc(buffer: ^ByteBuffer, reg: Register16) {_encode_unary_rm(
		buffer,
		.Word,
		0xF7,
		5,
		reg,
	)} // IMUL r/m16 -> DX:AX = AX * r/m16
imul_r8 :: proc(buffer: ^ByteBuffer, reg: Register8) {_encode_unary_rm(
		buffer,
		.Byte,
		0xF6,
		5,
		reg,
	)} // IMUL r/m8 -> AX = AL * r/m8
imul_m64 :: proc(buffer: ^ByteBuffer, mem: MemoryAddress) {_encode_unary_rm(
		buffer,
		.QWord,
		0xF7,
		5,
		mem,
	)}
// imul_m32, imul_m16, imul_m8 similar...

// --- IMUL (two and three operand forms) ---
imul_r64_r64 :: proc(buffer: ^ByteBuffer, dst: Register64, src: Register64) {_encode_rex_modrm(
		buffer,
		.QWord,
		true,
		[]u8{0x0F, 0xAF},
		dst,
		src,
	)} // 0F AF /r
imul_r32_r32 :: proc(buffer: ^ByteBuffer, dst: Register32, src: Register32) {_encode_rex_modrm(
		buffer,
		.DWord,
		false,
		[]u8{0x0F, 0xAF},
		dst,
		src,
	)} // 0F AF /r
imul_r16_r16 :: proc(buffer: ^ByteBuffer, dst: Register16, src: Register16) {_encode_rex_modrm(
		buffer,
		.Word,
		false,
		[]u8{0x0F, 0xAF},
		dst,
		src,
	)} // 66 0F AF /r
imul_r64_m64 :: proc(buffer: ^ByteBuffer, dst: Register64, mem: MemoryAddress) {_encode_rex_modrm(
		buffer,
		.QWord,
		true,
		[]u8{0x0F, 0xAF},
		dst,
		mem,
	)}
imul_r32_m32 :: proc(buffer: ^ByteBuffer, dst: Register32, mem: MemoryAddress) {_encode_rex_modrm(
		buffer,
		.DWord,
		false,
		[]u8{0x0F, 0xAF},
		dst,
		mem,
	)}
imul_r16_m16 :: proc(buffer: ^ByteBuffer, dst: Register16, mem: MemoryAddress) {_encode_rex_modrm(
		buffer,
		.Word,
		false,
		[]u8{0x0F, 0xAF},
		dst,
		mem,
	)}

// IMUL r, r/m, imm (6B ib or 69 id)
@(private)
_encode_imul_imm :: proc(
	buffer: ^ByteBuffer,
	op_size: OperandSize,
	dst_reg: $T,
	src_rm: $U,
	imm: $V,
) where T == Register64 ||
	T == Register32 ||
	T == Register16,
	U == T ||
	U == MemoryAddress,
	V == u32 ||
	V == u16 {

	rex_w := op_size == .QWord
	prefix_66 := op_size == .Word

	opcode: u8
	imm_size: OperandSize
	imm_val_trunc: u32

	#partial switch i in imm {
	case u32:
		// 64/32 bit ops
		imm_val_trunc = i
		if i64(i) >= -128 && i64(i) <= 127 {
			opcode = 0x6B;imm_size = .Byte
		} else {
			opcode = 0x69;imm_size = .DWord
		}
	case u16:
		// 16 bit ops
		imm_val_trunc = u32(i)
		if i64(i16(i)) >= -128 && i64(i16(i)) <= 127 {
			opcode = 0x6B;imm_size = .Byte
		} else {
			opcode = 0x69;imm_size = .Word
		}
	}

	// Emit prefixes, REX, Opcode, ModR/M (using _encode_rex_modrm)
	_encode_rex_modrm(buffer, op_size, rex_w, []u8{opcode}, dst_reg, src_rm, prefix_66)

	// Emit immediate
	#partial switch imm_size {
	case .Byte:
		_write_imm8(buffer, u8(imm_val_trunc))
	case .Word:
		_write_imm16(buffer, u16(imm_val_trunc))
	case .DWord:
		_write_imm32(buffer, imm_val_trunc)
	}
}

imul_r64_r64_imm32 :: proc(
	buffer: ^ByteBuffer,
	dst: Register64,
	src: Register64,
	imm: u32,
) {_encode_imul_imm(buffer, .QWord, dst, src, imm)}
imul_r32_r32_imm32 :: proc(
	buffer: ^ByteBuffer,
	dst: Register32,
	src: Register32,
	imm: u32,
) {_encode_imul_imm(buffer, .DWord, dst, src, imm)}
imul_r16_r16_imm16 :: proc(
	buffer: ^ByteBuffer,
	dst: Register16,
	src: Register16,
	imm: u16,
) {_encode_imul_imm(buffer, .Word, dst, src, imm)}
imul_r64_m64_imm32 :: proc(
	buffer: ^ByteBuffer,
	dst: Register64,
	mem: MemoryAddress,
	imm: u32,
) {_encode_imul_imm(buffer, .QWord, dst, mem, imm)}
imul_r32_m32_imm32 :: proc(
	buffer: ^ByteBuffer,
	dst: Register32,
	mem: MemoryAddress,
	imm: u32,
) {_encode_imul_imm(buffer, .DWord, dst, mem, imm)}
imul_r16_m16_imm16 :: proc(
	buffer: ^ByteBuffer,
	dst: Register16,
	mem: MemoryAddress,
	imm: u16,
) {_encode_imul_imm(buffer, .Word, dst, mem, imm)}

// Simplified forms: IMUL r, imm (encoded as IMUL r, r, imm)
imul_r64_imm32 :: proc(buffer: ^ByteBuffer, reg: Register64, imm: u32) {imul_r64_r64_imm32(
		buffer,
		reg,
		reg,
		imm,
	)}
imul_r32_imm32 :: proc(buffer: ^ByteBuffer, reg: Register32, imm: u32) {imul_r32_r32_imm32(
		buffer,
		reg,
		reg,
		imm,
	)}
imul_r16_imm16 :: proc(buffer: ^ByteBuffer, reg: Register16, imm: u16) {imul_r16_r16_imm16(
		buffer,
		reg,
		reg,
		imm,
	)}

// --- CMP / TEST (Structure similar to ADD/SUB) ---
// CMP (opcode_ext = 7)
cmp_r64_r64 :: proc(buffer: ^ByteBuffer, reg1: Register64, reg2: Register64) {_encode_rex_modrm(
		buffer,
		.QWord,
		nil,
		[]u8{0x39},
		reg2,
		reg1,
	)} // 39 /r : CMP r/m64, r64
cmp_r32_r32 :: proc(buffer: ^ByteBuffer, reg1: Register32, reg2: Register32) {_encode_rex_modrm(
		buffer,
		.DWord,
		nil,
		[]u8{0x39},
		reg2,
		reg1,
	)} // 39 /r
cmp_r16_r16 :: proc(buffer: ^ByteBuffer, reg1: Register16, reg2: Register16) {_encode_rex_modrm(
		buffer,
		.Word,
		nil,
		[]u8{0x39},
		reg2,
		reg1,
	)} // 66 39 /r
cmp_r8_r8 :: proc(buffer: ^ByteBuffer, reg1: Register8, reg2: Register8) {
	if (_is_high_byte_r8(reg1) || _is_high_byte_r8(reg2)) &&
	   (_is_rex_requiring_r8(reg1) ||
			   _is_rex_requiring_r8(
				   reg2,
			   )) {fmt.eprintf("Encoding Error: CMP r8,r8 high/rex mix\n");return}
	_encode_rex_modrm(buffer, .Byte, nil, []u8{0x38}, reg2, reg1) // 38 /r
}
cmp_r64_m64 :: proc(buffer: ^ByteBuffer, reg1: Register64, mem: MemoryAddress) {_encode_rex_modrm(
		buffer,
		.QWord,
		nil,
		[]u8{0x3B},
		reg1,
		mem,
	)} // 3B /r : CMP r64, r/m64
cmp_r32_m32 :: proc(buffer: ^ByteBuffer, reg1: Register32, mem: MemoryAddress) {_encode_rex_modrm(
		buffer,
		.DWord,
		nil,
		[]u8{0x3B},
		reg1,
		mem,
	)} // 3B /r
cmp_r16_m16 :: proc(buffer: ^ByteBuffer, reg1: Register16, mem: MemoryAddress) {_encode_rex_modrm(
		buffer,
		.Word,
		nil,
		[]u8{0x3B},
		reg1,
		mem,
	)} // 66 3B /r
cmp_r8_m8 :: proc(buffer: ^ByteBuffer, reg1: Register8, mem: MemoryAddress) {
	if _is_high_byte_r8(reg1) {fmt.eprintf("Encoding Error: CMP r8,m8 high byte reg\n");return}
	_encode_rex_modrm(
		buffer,
		.Byte,
		nil,
		[]u8{0x3A},
		reg1,
		mem,
		force_rex = _is_rex_requiring_r8(reg1),
	) // 3A /r
}
cmp_m64_r64 :: proc(buffer: ^ByteBuffer, mem: MemoryAddress, src: Register64) {_encode_rex_modrm(
		buffer,
		.QWord,
		nil,
		[]u8{0x39},
		src,
		mem,
	)} // 39 /r
cmp_m32_r32 :: proc(buffer: ^ByteBuffer, mem: MemoryAddress, src: Register32) {_encode_rex_modrm(
		buffer,
		.DWord,
		nil,
		[]u8{0x39},
		src,
		mem,
	)} // 39 /r
cmp_m16_r16 :: proc(buffer: ^ByteBuffer, mem: MemoryAddress, src: Register16) {_encode_rex_modrm(
		buffer,
		.Word,
		nil,
		[]u8{0x39},
		src,
		mem,
	)} // 66 39 /r
cmp_m8_r8 :: proc(buffer: ^ByteBuffer, mem: MemoryAddress, src: Register8) {
	if _is_high_byte_r8(src) {fmt.eprintf("Encoding Error: CMP m8,r8 high byte src\n");return}
	_encode_rex_modrm(
		buffer,
		.Byte,
		nil,
		[]u8{0x38},
		src,
		mem,
		force_rex = _is_rex_requiring_r8(src),
	) // 38 /r
}
cmp_r64_imm32 :: proc(buffer: ^ByteBuffer, reg: Register64, imm: u32) {_encode_imm_arith_logic(
		buffer,
		.QWord,
		7,
		reg,
		imm,
	)}
cmp_r32_imm32 :: proc(buffer: ^ByteBuffer, reg: Register32, imm: u32) {_encode_imm_arith_logic(
		buffer,
		.DWord,
		7,
		reg,
		imm,
	)}
cmp_r16_imm16 :: proc(buffer: ^ByteBuffer, reg: Register16, imm: u16) {_encode_imm_arith_logic(
		buffer,
		.Word,
		7,
		reg,
		imm,
	)}
cmp_r8_imm8 :: proc(buffer: ^ByteBuffer, reg: Register8, imm: u8) {_encode_imm_arith_logic(
		buffer,
		.Byte,
		7,
		reg,
		imm,
	)}
cmp_m64_imm32 :: proc(buffer: ^ByteBuffer, mem: MemoryAddress, imm: u32) {_encode_imm_arith_logic(
		buffer,
		.QWord,
		7,
		mem,
		imm,
	)}
cmp_m32_imm32 :: proc(buffer: ^ByteBuffer, mem: MemoryAddress, imm: u32) {_encode_imm_arith_logic(
		buffer,
		.DWord,
		7,
		mem,
		imm,
	)}
cmp_m16_imm16 :: proc(buffer: ^ByteBuffer, mem: MemoryAddress, imm: u16) {_encode_imm_arith_logic(
		buffer,
		.Word,
		7,
		mem,
		imm,
	)}
cmp_m8_imm8 :: proc(buffer: ^ByteBuffer, mem: MemoryAddress, imm: u8) {_encode_imm_arith_logic(
		buffer,
		.Byte,
		7,
		mem,
		imm,
	)}

// TEST (opcodes 84/85 for r/m,r; F6/F7 /0 for r/m,imm; A8/A9 for AL/AX/EAX/RAX,imm)
test_r64_r64 :: proc(buffer: ^ByteBuffer, reg1: Register64, reg2: Register64) {_encode_rex_modrm(
		buffer,
		.QWord,
		nil,
		[]u8{0x85},
		reg2,
		reg1,
	)} // 85 /r
test_r32_r32 :: proc(buffer: ^ByteBuffer, reg1: Register32, reg2: Register32) {_encode_rex_modrm(
		buffer,
		.DWord,
		nil,
		[]u8{0x85},
		reg2,
		reg1,
	)} // 85 /r
test_r16_r16 :: proc(buffer: ^ByteBuffer, reg1: Register16, reg2: Register16) {_encode_rex_modrm(
		buffer,
		.Word,
		nil,
		[]u8{0x85},
		reg2,
		reg1,
	)} // 66 85 /r
test_r8_r8 :: proc(buffer: ^ByteBuffer, reg1: Register8, reg2: Register8) {
	if (_is_high_byte_r8(reg1) || _is_high_byte_r8(reg2)) &&
	   (_is_rex_requiring_r8(reg1) ||
			   _is_rex_requiring_r8(
				   reg2,
			   )) {fmt.eprintf("Encoding Error: TEST r8,r8 high/rex mix\n");return}
	_encode_rex_modrm(buffer, .Byte, nil, []u8{0x84}, reg2, reg1) // 84 /r
}
test_r64_m64 :: proc(
	buffer: ^ByteBuffer,
	reg1: Register64,
	mem: MemoryAddress,
) {_encode_rex_modrm(buffer, .QWord, nil, []u8{0x85}, reg1, mem)} 	// 85 /r (Note: reg1 in reg field for TEST r/m, r)
test_r32_m32 :: proc(
	buffer: ^ByteBuffer,
	reg1: Register32,
	mem: MemoryAddress,
) {_encode_rex_modrm(buffer, .DWord, nil, []u8{0x85}, reg1, mem)} 	// 85 /r
test_r16_m16 :: proc(
	buffer: ^ByteBuffer,
	reg1: Register16,
	mem: MemoryAddress,
) {_encode_rex_modrm(buffer, .Word, nil, []u8{0x85}, reg1, mem)} 	// 66 85 /r
test_r8_m8 :: proc(buffer: ^ByteBuffer, reg1: Register8, mem: MemoryAddress) {
	if _is_high_byte_r8(reg1) {fmt.eprintf("Encoding Error: TEST r8,m8 high byte reg\n");return}
	_encode_rex_modrm(
		buffer,
		.Byte,
		nil,
		[]u8{0x84},
		reg1,
		mem,
		force_rex = _is_rex_requiring_r8(reg1),
	) // 84 /r
}

@(private)
_encode_test_imm :: proc(
	buffer: ^ByteBuffer,
	op_size: OperandSize,
	rm_op: $T,
	imm: $U,
) where T == Register64 ||
	T == Register32 ||
	T == Register16 ||
	T == Register8 ||
	T == MemoryAddress,
	U == u32 ||
	U == u16 ||
	U == u8 {

	rex_w := op_size == .QWord
	prefix_66 := op_size == .Word
	opcode := op_size == .Byte ? u8(0xF6) : u8(0xF7)
	imm_size: OperandSize = op_size == .Byte ? .Byte : (op_size == .Word ? .Word : .DWord) // TEST imm is only 32 max
	imm_val_trunc: u32

	#partial switch i in imm {
	case u32:
		imm_val_trunc = i
	case u16:
		imm_val_trunc = u32(i)
	case u8:
		imm_val_trunc = u32(i)
	}

	// Special case for accumulator
	is_acc := false
	acc_op: u8 = 0xA8 // Base for TEST AL, imm8
	rex_b := false
	#partial switch v in rm_op {
	case Register8:
		is_acc = v == .AL && !_is_rex_requiring_r8(v);if is_acc {acc_op = 0xA8}
	case Register16:
		is_acc = v == .AX && !(u8(v) & 0x8 != 0);if is_acc {acc_op = 0xA9}
	case Register32:
		is_acc = v == .EAX && !(u8(v) & 0x8 != 0);if is_acc {acc_op = 0xA9}
	case Register64:
		is_acc = v == .RAX && !(u8(v) & 0x8 != 0);if is_acc {acc_op = 0xA9}
	}

	if is_acc {
		if prefix_66 do _write_byte(buffer, 0x66)
		rex := get_rex_prefix(rex_w, false, false, false)
		if rex != 0 do _write_byte(buffer, rex)
		_write_byte(buffer, acc_op)
		#partial switch imm_size {
		case .Byte:
			_write_imm8(buffer, u8(imm_val_trunc))
		case .Word:
			_write_imm16(buffer, u16(imm_val_trunc))
		case .DWord:
			_write_imm32(buffer, imm_val_trunc)
		}
	} else {
		// Use general F6/F7 /0 encoding
		_encode_unary_rm(buffer, op_size, opcode, 0, rm_op)
		#partial switch imm_size {
		case .Byte:
			_write_imm8(buffer, u8(imm_val_trunc))
		case .Word:
			_write_imm16(buffer, u16(imm_val_trunc))
		case .DWord:
			_write_imm32(buffer, imm_val_trunc)
		}
	}
}

test_r64_imm32 :: proc(buffer: ^ByteBuffer, reg: Register64, imm: u32) {_encode_test_imm(
		buffer,
		.QWord,
		reg,
		imm,
	)}
test_r32_imm32 :: proc(buffer: ^ByteBuffer, reg: Register32, imm: u32) {_encode_test_imm(
		buffer,
		.DWord,
		reg,
		imm,
	)}
test_r16_imm16 :: proc(buffer: ^ByteBuffer, reg: Register16, imm: u16) {_encode_test_imm(
		buffer,
		.Word,
		reg,
		imm,
	)}
test_r8_imm8 :: proc(buffer: ^ByteBuffer, reg: Register8, imm: u8) {_encode_test_imm(
		buffer,
		.Byte,
		reg,
		imm,
	)}
test_m64_imm32 :: proc(buffer: ^ByteBuffer, mem: MemoryAddress, imm: u32) {_encode_test_imm(
		buffer,
		.QWord,
		mem,
		imm,
	)}
// test_m32_imm32, test_m16_imm16, test_m8_imm8 similar...

// --- ADC / SBB --- (Similar structure to ADD/SUB, different opcodes/extensions)
adc_r64_r64 :: proc(buffer: ^ByteBuffer, dst: Register64, src: Register64) {_encode_rex_modrm(
		buffer,
		.QWord,
		nil,
		[]u8{0x11},
		src,
		dst,
	)} // 11 /r
adc_r32_r32 :: proc(buffer: ^ByteBuffer, dst: Register32, src: Register32) {_encode_rex_modrm(
		buffer,
		.DWord,
		nil,
		[]u8{0x11},
		src,
		dst,
	)} // 11 /r
adc_r16_r16 :: proc(buffer: ^ByteBuffer, dst: Register16, src: Register16) {_encode_rex_modrm(
		buffer,
		.Word,
		nil,
		[]u8{0x11},
		src,
		dst,
	)} // 66 11 /r
adc_r8_r8 :: proc(buffer: ^ByteBuffer, dst: Register8, src: Register8) {
	if (_is_high_byte_r8(dst) || _is_high_byte_r8(src)) &&
	   (_is_rex_requiring_r8(dst) ||
			   _is_rex_requiring_r8(
				   src,
			   )) {fmt.eprintf("Encoding Error: ADC r8,r8 high/rex mix\n");return}
	_encode_rex_modrm(buffer, .Byte, nil, []u8{0x10}, src, dst) // 10 /r
}
adc_r64_m64 :: proc(buffer: ^ByteBuffer, dst: Register64, mem: MemoryAddress) {_encode_rex_modrm(
		buffer,
		.QWord,
		nil,
		[]u8{0x13},
		dst,
		mem,
	)} // 13 /r
adc_m64_r64 :: proc(buffer: ^ByteBuffer, mem: MemoryAddress, src: Register64) {_encode_rex_modrm(
		buffer,
		.QWord,
		nil,
		[]u8{0x11},
		src,
		mem,
	)} // 11 /r
adc_m64_imm32 :: proc(buffer: ^ByteBuffer, mem: MemoryAddress, imm: u32) {_encode_imm_arith_logic(
		buffer,
		.QWord,
		2,
		mem,
		imm,
	)} // /2

sbb_r64_r64 :: proc(buffer: ^ByteBuffer, dst: Register64, src: Register64) {_encode_rex_modrm(
		buffer,
		.QWord,
		nil,
		[]u8{0x19},
		src,
		dst,
	)} // 19 /r
sbb_r32_r32 :: proc(buffer: ^ByteBuffer, dst: Register32, src: Register32) {_encode_rex_modrm(
		buffer,
		.DWord,
		nil,
		[]u8{0x19},
		src,
		dst,
	)} // 19 /r
sbb_r16_r16 :: proc(buffer: ^ByteBuffer, dst: Register16, src: Register16) {_encode_rex_modrm(
		buffer,
		.Word,
		nil,
		[]u8{0x19},
		src,
		dst,
	)} // 66 19 /r
sbb_r8_r8 :: proc(buffer: ^ByteBuffer, dst: Register8, src: Register8) {
	if (_is_high_byte_r8(dst) || _is_high_byte_r8(src)) &&
	   (_is_rex_requiring_r8(dst) ||
			   _is_rex_requiring_r8(
				   src,
			   )) {fmt.eprintf("Encoding Error: SBB r8,r8 high/rex mix\n");return}
	_encode_rex_modrm(buffer, .Byte, nil, []u8{0x18}, src, dst) // 18 /r
}
sbb_r64_m64 :: proc(buffer: ^ByteBuffer, dst: Register64, mem: MemoryAddress) {_encode_rex_modrm(
		buffer,
		.QWord,
		nil,
		[]u8{0x1B},
		dst,
		mem,
	)} // 1B /r
sbb_m64_r64 :: proc(buffer: ^ByteBuffer, mem: MemoryAddress, src: Register64) {_encode_rex_modrm(
		buffer,
		.QWord,
		nil,
		[]u8{0x19},
		src,
		mem,
	)} // 19 /r
sbb_m64_imm32 :: proc(buffer: ^ByteBuffer, mem: MemoryAddress, imm: u32) {_encode_imm_arith_logic(
		buffer,
		.QWord,
		3,
		mem,
		imm,
	)} // /3

// --- XADD ---
xadd_r64_r64 :: proc(buffer: ^ByteBuffer, dst: Register64, src: Register64) {_encode_rex_modrm(
		buffer,
		.QWord,
		true,
		[]u8{0x0F, 0xC1},
		src,
		dst,
	)} // REX.W 0F C1 /r

// --- CDQ/CQO ---
cdq :: proc(buffer: ^ByteBuffer) {_write_byte(buffer, 0x99)} 	// Sign extend EAX into EDX:EAX
cqo :: proc(buffer: ^ByteBuffer) {_write_bytes(buffer, []u8{0x48, 0x99})} 	// REX.W + 99: Sign extend RAX into RDX:RAX

// ==================================
// Logical Instructions (AND, OR, XOR)
// ==================================
// Structure is identical to ADD/SUB/CMP, just different opcodes/extensions

// AND (opcode_ext = 4)
and_r64_r64 :: proc(buffer: ^ByteBuffer, dst: Register64, src: Register64) {_encode_rex_modrm(
		buffer,
		.QWord,
		nil,
		[]u8{0x21},
		src,
		dst,
	)} // 21 /r
and_r32_r32 :: proc(buffer: ^ByteBuffer, dst: Register32, src: Register32) {_encode_rex_modrm(
		buffer,
		.DWord,
		nil,
		[]u8{0x21},
		src,
		dst,
	)} // 21 /r
and_r16_r16 :: proc(buffer: ^ByteBuffer, dst: Register16, src: Register16) {_encode_rex_modrm(
		buffer,
		.Word,
		nil,
		[]u8{0x21},
		src,
		dst,
	)} // 66 21 /r
and_r8_r8 :: proc(buffer: ^ByteBuffer, dst: Register8, src: Register8) {
	if (_is_high_byte_r8(dst) || _is_high_byte_r8(src)) &&
	   (_is_rex_requiring_r8(dst) ||
			   _is_rex_requiring_r8(
				   src,
			   )) {fmt.eprintf("Encoding Error: AND r8,r8 high/rex mix\n");return}
	_encode_rex_modrm(buffer, .Byte, nil, []u8{0x20}, src, dst) // 20 /r
}
and_r64_m64 :: proc(buffer: ^ByteBuffer, dst: Register64, mem: MemoryAddress) {_encode_rex_modrm(
		buffer,
		.QWord,
		nil,
		[]u8{0x23},
		dst,
		mem,
	)} // 23 /r
and_m64_r64 :: proc(buffer: ^ByteBuffer, mem: MemoryAddress, src: Register64) {_encode_rex_modrm(
		buffer,
		.QWord,
		nil,
		[]u8{0x21},
		src,
		mem,
	)} // 21 /r
and_r64_imm32 :: proc(buffer: ^ByteBuffer, reg: Register64, imm: u32) {_encode_imm_arith_logic(
		buffer,
		.QWord,
		4,
		reg,
		imm,
	)}
and_r32_imm32 :: proc(buffer: ^ByteBuffer, reg: Register32, imm: u32) {_encode_imm_arith_logic(
		buffer,
		.DWord,
		4,
		reg,
		imm,
	)}
and_r16_imm16 :: proc(buffer: ^ByteBuffer, reg: Register16, imm: u16) {_encode_imm_arith_logic(
		buffer,
		.Word,
		4,
		reg,
		imm,
	)}
and_r8_imm8 :: proc(buffer: ^ByteBuffer, reg: Register8, imm: u8) {_encode_imm_arith_logic(
		buffer,
		.Byte,
		4,
		reg,
		imm,
	)}
and_m64_imm32 :: proc(buffer: ^ByteBuffer, mem: MemoryAddress, imm: u32) {_encode_imm_arith_logic(
		buffer,
		.QWord,
		4,
		mem,
		imm,
	)}

// OR (opcode_ext = 1)
or_r64_r64 :: proc(buffer: ^ByteBuffer, dst: Register64, src: Register64) {_encode_rex_modrm(
		buffer,
		.QWord,
		nil,
		[]u8{0x09},
		src,
		dst,
	)} // 09 /r
or_r32_r32 :: proc(buffer: ^ByteBuffer, dst: Register32, src: Register32) {_encode_rex_modrm(
		buffer,
		.DWord,
		nil,
		[]u8{0x09},
		src,
		dst,
	)} // 09 /r
or_r16_r16 :: proc(buffer: ^ByteBuffer, dst: Register16, src: Register16) {_encode_rex_modrm(
		buffer,
		.Word,
		nil,
		[]u8{0x09},
		src,
		dst,
	)} // 66 09 /r
or_r8_r8 :: proc(buffer: ^ByteBuffer, dst: Register8, src: Register8) {
	if (_is_high_byte_r8(dst) || _is_high_byte_r8(src)) &&
	   (_is_rex_requiring_r8(dst) ||
			   _is_rex_requiring_r8(
				   src,
			   )) {fmt.eprintf("Encoding Error: OR r8,r8 high/rex mix\n");return}
	_encode_rex_modrm(buffer, .Byte, nil, []u8{0x08}, src, dst) // 08 /r
}
or_r64_m64 :: proc(buffer: ^ByteBuffer, dst: Register64, mem: MemoryAddress) {_encode_rex_modrm(
		buffer,
		.QWord,
		nil,
		[]u8{0x0B},
		dst,
		mem,
	)} // 0B /r
or_m64_r64 :: proc(buffer: ^ByteBuffer, mem: MemoryAddress, src: Register64) {_encode_rex_modrm(
		buffer,
		.QWord,
		nil,
		[]u8{0x09},
		src,
		mem,
	)} // 09 /r
or_r64_imm32 :: proc(buffer: ^ByteBuffer, reg: Register64, imm: u32) {_encode_imm_arith_logic(
		buffer,
		.QWord,
		1,
		reg,
		imm,
	)}
or_r32_imm32 :: proc(buffer: ^ByteBuffer, reg: Register32, imm: u32) {_encode_imm_arith_logic(
		buffer,
		.DWord,
		1,
		reg,
		imm,
	)}
or_r16_imm16 :: proc(buffer: ^ByteBuffer, reg: Register16, imm: u16) {_encode_imm_arith_logic(
		buffer,
		.Word,
		1,
		reg,
		imm,
	)}
or_r8_imm8 :: proc(buffer: ^ByteBuffer, reg: Register8, imm: u8) {_encode_imm_arith_logic(
		buffer,
		.Byte,
		1,
		reg,
		imm,
	)}
or_m64_imm32 :: proc(buffer: ^ByteBuffer, mem: MemoryAddress, imm: u32) {_encode_imm_arith_logic(
		buffer,
		.QWord,
		1,
		mem,
		imm,
	)}

// XOR (opcode_ext = 6)
xor_r64_r64 :: proc(buffer: ^ByteBuffer, dst: Register64, src: Register64) {_encode_rex_modrm(
		buffer,
		.QWord,
		nil,
		[]u8{0x31},
		src,
		dst,
	)} // 31 /r
xor_r32_r32 :: proc(buffer: ^ByteBuffer, dst: Register32, src: Register32) {_encode_rex_modrm(
		buffer,
		.DWord,
		nil,
		[]u8{0x31},
		src,
		dst,
	)} // 31 /r
xor_r16_r16 :: proc(buffer: ^ByteBuffer, dst: Register16, src: Register16) {_encode_rex_modrm(
		buffer,
		.Word,
		nil,
		[]u8{0x31},
		src,
		dst,
	)} // 66 31 /r
xor_r8_r8 :: proc(buffer: ^ByteBuffer, dst: Register8, src: Register8) {
	if (_is_high_byte_r8(dst) || _is_high_byte_r8(src)) &&
	   (_is_rex_requiring_r8(dst) ||
			   _is_rex_requiring_r8(
				   src,
			   )) {fmt.eprintf("Encoding Error: XOR r8,r8 high/rex mix\n");return}
	_encode_rex_modrm(buffer, .Byte, nil, []u8{0x30}, src, dst) // 30 /r
}
xor_r64_m64 :: proc(buffer: ^ByteBuffer, dst: Register64, mem: MemoryAddress) {_encode_rex_modrm(
		buffer,
		.QWord,
		nil,
		[]u8{0x33},
		dst,
		mem,
	)} // 33 /r
xor_m64_r64 :: proc(buffer: ^ByteBuffer, mem: MemoryAddress, src: Register64) {_encode_rex_modrm(
		buffer,
		.QWord,
		nil,
		[]u8{0x31},
		src,
		mem,
	)} // 31 /r
xor_r64_imm32 :: proc(buffer: ^ByteBuffer, reg: Register64, imm: u32) {_encode_imm_arith_logic(
		buffer,
		.QWord,
		6,
		reg,
		imm,
	)}
xor_r32_imm32 :: proc(buffer: ^ByteBuffer, reg: Register32, imm: u32) {_encode_imm_arith_logic(
		buffer,
		.DWord,
		6,
		reg,
		imm,
	)}
xor_r16_imm16 :: proc(buffer: ^ByteBuffer, reg: Register16, imm: u16) {_encode_imm_arith_logic(
		buffer,
		.Word,
		6,
		reg,
		imm,
	)}
xor_r8_imm8 :: proc(buffer: ^ByteBuffer, reg: Register8, imm: u8) {_encode_imm_arith_logic(
		buffer,
		.Byte,
		6,
		reg,
		imm,
	)}
xor_m64_imm32 :: proc(buffer: ^ByteBuffer, mem: MemoryAddress, imm: u32) {_encode_imm_arith_logic(
		buffer,
		.QWord,
		6,
		mem,
		imm,
	)}

// ==================================
// Shift and Rotate Instructions (SHL, SHR, SAR, ROL, ROR)
// ==================================

@(private)
_encode_shift_rotate :: proc(
	buffer: ^ByteBuffer,
	op_size: OperandSize,
	opcode_ext: u8,
	rm_op: $T,
	count: $U,
) where T == Register64 ||
	T == Register32 ||
	T == Register16 ||
	T == Register8 ||
	T == MemoryAddress,
	U == u8 ||
	U == type_of(Register8.CL) { 	// Immediate u8 or CL register

	is_cl := U == type_of(Register8.CL)
	imm8: u8 = 0
	if !is_cl do imm8 = count.(u8)

	opcode: u8
	if is_cl {
		opcode = op_size == .Byte ? 0xD2 : 0xD3
	} else if imm8 == 1 {
		opcode = op_size == .Byte ? 0xD0 : 0xD1
	} else {
		opcode = op_size == .Byte ? 0xC0 : 0xC1
	}

	_encode_unary_rm(buffer, op_size, opcode, opcode_ext, rm_op)

	// Write immediate if necessary
	if !is_cl && imm8 != 1 {
		_write_imm8(buffer, imm8)
	}
}

// SHL (opcode_ext = 4)
shl_r64_imm8 :: proc(buffer: ^ByteBuffer, reg: Register64, imm: u8) {_encode_shift_rotate(
		buffer,
		.QWord,
		4,
		reg,
		imm,
	)}
shl_r32_imm8 :: proc(buffer: ^ByteBuffer, reg: Register32, imm: u8) {_encode_shift_rotate(
		buffer,
		.DWord,
		4,
		reg,
		imm,
	)}
shl_r16_imm8 :: proc(buffer: ^ByteBuffer, reg: Register16, imm: u8) {_encode_shift_rotate(
		buffer,
		.Word,
		4,
		reg,
		imm,
	)}
shl_r8_imm8 :: proc(buffer: ^ByteBuffer, reg: Register8, imm: u8) {_encode_shift_rotate(
		buffer,
		.Byte,
		4,
		reg,
		imm,
	)}
shl_r64_cl :: proc(buffer: ^ByteBuffer, reg: Register64) {_encode_shift_rotate(
		buffer,
		.QWord,
		4,
		reg,
		Register8.CL,
	)}
shl_r32_cl :: proc(buffer: ^ByteBuffer, reg: Register32) {_encode_shift_rotate(
		buffer,
		.DWord,
		4,
		reg,
		Register8.CL,
	)}
shl_r16_cl :: proc(buffer: ^ByteBuffer, reg: Register16) {_encode_shift_rotate(
		buffer,
		.Word,
		4,
		reg,
		Register8.CL,
	)}
shl_r8_cl :: proc(buffer: ^ByteBuffer, reg: Register8) {_encode_shift_rotate(
		buffer,
		.Byte,
		4,
		reg,
		Register8.CL,
	)}

// SHR (opcode_ext = 5)
shr_r64_imm8 :: proc(buffer: ^ByteBuffer, reg: Register64, imm: u8) {_encode_shift_rotate(
		buffer,
		.QWord,
		5,
		reg,
		imm,
	)}
shr_r32_imm8 :: proc(buffer: ^ByteBuffer, reg: Register32, imm: u8) {_encode_shift_rotate(
		buffer,
		.DWord,
		5,
		reg,
		imm,
	)}
shr_r16_imm8 :: proc(buffer: ^ByteBuffer, reg: Register16, imm: u8) {_encode_shift_rotate(
		buffer,
		.Word,
		5,
		reg,
		imm,
	)}
shr_r8_imm8 :: proc(buffer: ^ByteBuffer, reg: Register8, imm: u8) {_encode_shift_rotate(
		buffer,
		.Byte,
		5,
		reg,
		imm,
	)}
shr_r64_cl :: proc(buffer: ^ByteBuffer, reg: Register64) {_encode_shift_rotate(
		buffer,
		.QWord,
		5,
		reg,
		Register8.CL,
	)}
shr_r32_cl :: proc(buffer: ^ByteBuffer, reg: Register32) {_encode_shift_rotate(
		buffer,
		.DWord,
		5,
		reg,
		Register8.CL,
	)}
shr_r16_cl :: proc(buffer: ^ByteBuffer, reg: Register16) {_encode_shift_rotate(
		buffer,
		.Word,
		5,
		reg,
		Register8.CL,
	)}
shr_r8_cl :: proc(buffer: ^ByteBuffer, reg: Register8) {_encode_shift_rotate(
		buffer,
		.Byte,
		5,
		reg,
		Register8.CL,
	)}

// SAR (opcode_ext = 7)
sar_r64_imm8 :: proc(buffer: ^ByteBuffer, reg: Register64, imm: u8) {_encode_shift_rotate(
		buffer,
		.QWord,
		7,
		reg,
		imm,
	)}
sar_r32_imm8 :: proc(buffer: ^ByteBuffer, reg: Register32, imm: u8) {_encode_shift_rotate(
		buffer,
		.DWord,
		7,
		reg,
		imm,
	)}
sar_r16_imm8 :: proc(buffer: ^ByteBuffer, reg: Register16, imm: u8) {_encode_shift_rotate(
		buffer,
		.Word,
		7,
		reg,
		imm,
	)}
sar_r8_imm8 :: proc(buffer: ^ByteBuffer, reg: Register8, imm: u8) {_encode_shift_rotate(
		buffer,
		.Byte,
		7,
		reg,
		imm,
	)}
sar_r64_cl :: proc(buffer: ^ByteBuffer, reg: Register64) {_encode_shift_rotate(
		buffer,
		.QWord,
		7,
		reg,
		Register8.CL,
	)}
sar_r32_cl :: proc(buffer: ^ByteBuffer, reg: Register32) {_encode_shift_rotate(
		buffer,
		.DWord,
		7,
		reg,
		Register8.CL,
	)}
sar_r16_cl :: proc(buffer: ^ByteBuffer, reg: Register16) {_encode_shift_rotate(
		buffer,
		.Word,
		7,
		reg,
		Register8.CL,
	)}
sar_r8_cl :: proc(buffer: ^ByteBuffer, reg: Register8) {_encode_shift_rotate(
		buffer,
		.Byte,
		7,
		reg,
		Register8.CL,
	)}

// ROL (opcode_ext = 0)
rol_r64_imm8 :: proc(buffer: ^ByteBuffer, reg: Register64, imm: u8) {_encode_shift_rotate(
		buffer,
		.QWord,
		0,
		reg,
		imm,
	)}
rol_r32_imm8 :: proc(buffer: ^ByteBuffer, reg: Register32, imm: u8) {_encode_shift_rotate(
		buffer,
		.DWord,
		0,
		reg,
		imm,
	)}
rol_r16_imm8 :: proc(buffer: ^ByteBuffer, reg: Register16, imm: u8) {_encode_shift_rotate(
		buffer,
		.Word,
		0,
		reg,
		imm,
	)}
rol_r8_imm8 :: proc(buffer: ^ByteBuffer, reg: Register8, imm: u8) {_encode_shift_rotate(
		buffer,
		.Byte,
		0,
		reg,
		imm,
	)}
rol_r64_cl :: proc(buffer: ^ByteBuffer, reg: Register64) {_encode_shift_rotate(
		buffer,
		.QWord,
		0,
		reg,
		Register8.CL,
	)}
rol_r32_cl :: proc(buffer: ^ByteBuffer, reg: Register32) {_encode_shift_rotate(
		buffer,
		.DWord,
		0,
		reg,
		Register8.CL,
	)}
rol_r16_cl :: proc(buffer: ^ByteBuffer, reg: Register16) {_encode_shift_rotate(
		buffer,
		.Word,
		0,
		reg,
		Register8.CL,
	)}
rol_r8_cl :: proc(buffer: ^ByteBuffer, reg: Register8) {_encode_shift_rotate(
		buffer,
		.Byte,
		0,
		reg,
		Register8.CL,
	)}

// ROR (opcode_ext = 1)
ror_r64_imm8 :: proc(buffer: ^ByteBuffer, reg: Register64, imm: u8) {_encode_shift_rotate(
		buffer,
		.QWord,
		1,
		reg,
		imm,
	)}
ror_r32_imm8 :: proc(buffer: ^ByteBuffer, reg: Register32, imm: u8) {_encode_shift_rotate(
		buffer,
		.DWord,
		1,
		reg,
		imm,
	)}
ror_r16_imm8 :: proc(buffer: ^ByteBuffer, reg: Register16, imm: u8) {_encode_shift_rotate(
		buffer,
		.Word,
		1,
		reg,
		imm,
	)}
ror_r8_imm8 :: proc(buffer: ^ByteBuffer, reg: Register8, imm: u8) {_encode_shift_rotate(
		buffer,
		.Byte,
		1,
		reg,
		imm,
	)}
ror_r64_cl :: proc(buffer: ^ByteBuffer, reg: Register64) {_encode_shift_rotate(
		buffer,
		.QWord,
		1,
		reg,
		Register8.CL,
	)}
ror_r32_cl :: proc(buffer: ^ByteBuffer, reg: Register32) {_encode_shift_rotate(
		buffer,
		.DWord,
		1,
		reg,
		Register8.CL,
	)}
ror_r16_cl :: proc(buffer: ^ByteBuffer, reg: Register16) {_encode_shift_rotate(
		buffer,
		.Word,
		1,
		reg,
		Register8.CL,
	)}
ror_r8_cl :: proc(buffer: ^ByteBuffer, reg: Register8) {_encode_shift_rotate(
		buffer,
		.Byte,
		1,
		reg,
		Register8.CL,
	)}

// Double Shifts (SHLD, SHRD) - Less common pattern
shld_r64_r64_imm8 :: proc(buffer: ^ByteBuffer, dst: Register64, src: Register64, imm: u8) {
	_encode_rex_modrm(buffer, .QWord, true, []u8{0x0F, 0xA4}, src, dst) // REX.W 0F A4 /r ib
	_write_imm8(buffer, imm)
}
shrd_r64_r64_imm8 :: proc(buffer: ^ByteBuffer, dst: Register64, src: Register64, imm: u8) {
	_encode_rex_modrm(buffer, .QWord, true, []u8{0x0F, 0xAC}, src, dst) // REX.W 0F AC /r ib
	_write_imm8(buffer, imm)
}
// Add _cl variants if needed

// ==================================
// Bit Manipulation Instructions (BT, BTS, BTR, BTC, BSF, BSR, POPCNT, LZCNT, TZCNT)
// ==================================
// BT, BTS, BTR, BTC with register index
@(private)
_encode_bt_reg :: proc(
	buffer: ^ByteBuffer,
	op_size: OperandSize,
	opcode: u8,
	rm_reg: Register64,
	bit_reg: Register64,
) {
	_encode_rex_modrm(buffer, op_size, op_size == .QWord, []u8{0x0F, opcode}, bit_reg, rm_reg)
}
bt_r64_r64 :: proc(buffer: ^ByteBuffer, reg: Register64, bit_index: Register64) {_encode_bt_reg(
		buffer,
		.QWord,
		0xA3,
		reg,
		bit_index,
	)}
bts_r64_r64 :: proc(buffer: ^ByteBuffer, reg: Register64, bit_index: Register64) {_encode_bt_reg(
		buffer,
		.QWord,
		0xAB,
		reg,
		bit_index,
	)}
btr_r64_r64 :: proc(buffer: ^ByteBuffer, reg: Register64, bit_index: Register64) {_encode_bt_reg(
		buffer,
		.QWord,
		0xB3,
		reg,
		bit_index,
	)}
btc_r64_r64 :: proc(buffer: ^ByteBuffer, reg: Register64, bit_index: Register64) {_encode_bt_reg(
		buffer,
		.QWord,
		0xBB,
		reg,
		bit_index,
	)}
// Add 32/16 bit versions if needed

// BSF, BSR
bsf_r64_r64 :: proc(buffer: ^ByteBuffer, dst: Register64, src: Register64) {_encode_rex_modrm(
		buffer,
		.QWord,
		true,
		[]u8{0x0F, 0xBC},
		dst,
		src,
	)}
bsr_r64_r64 :: proc(buffer: ^ByteBuffer, dst: Register64, src: Register64) {_encode_rex_modrm(
		buffer,
		.QWord,
		true,
		[]u8{0x0F, 0xBD},
		dst,
		src,
	)}
// Add 32/16 bit versions if needed

// POPCNT, LZCNT, TZCNT (use F3 prefix)
popcnt_r64_r64 :: proc(buffer: ^ByteBuffer, dst: Register64, src: Register64) {
	_write_byte(buffer, 0xF3)
	_encode_rex_modrm(buffer, .QWord, true, []u8{0x0F, 0xB8}, dst, src, prefix_66 = false) // F3 REX.W 0F B8 /r
}
lzcnt_r64_r64 :: proc(buffer: ^ByteBuffer, dst: Register64, src: Register64) {
	_write_byte(buffer, 0xF3)
	_encode_rex_modrm(buffer, .QWord, true, []u8{0x0F, 0xBD}, dst, src, prefix_66 = false) // F3 REX.W 0F BD /r (same opcode as BSR but with F3)
}
tzcnt_r64_r64 :: proc(buffer: ^ByteBuffer, dst: Register64, src: Register64) {
	_write_byte(buffer, 0xF3)
	_encode_rex_modrm(buffer, .QWord, true, []u8{0x0F, 0xBC}, dst, src, prefix_66 = false) // F3 REX.W 0F BC /r (same opcode as BSF but with F3)
}
// Add 32/16 bit versions if needed


// ==================================
// Conditional Moves (CMOVcc)
// ==================================

@(private)
_encode_cmovcc :: proc(
	buffer: ^ByteBuffer,
	op_size: OperandSize,
	condition_code: u8,
	dst: $T,
	src: $U,
) where T == Register64 ||
	T == Register32 ||
	T == Register16,
	U == T ||
	U == MemoryAddress {
	opcode := 0x40 + condition_code
	_encode_rex_modrm(buffer, op_size, op_size == .QWord, []u8{0x0F, opcode}, dst, src)
}

cmove_r64_r64 :: proc(buffer: ^ByteBuffer, dst: Register64, src: Register64) {_encode_cmovcc(
		buffer,
		.QWord,
		0x4,
		dst,
		src,
	)}
cmovne_r64_r64 :: proc(buffer: ^ByteBuffer, dst: Register64, src: Register64) {_encode_cmovcc(
		buffer,
		.QWord,
		0x5,
		dst,
		src,
	)}
cmovb_r64_r64 :: proc(buffer: ^ByteBuffer, dst: Register64, src: Register64) {_encode_cmovcc(
		buffer,
		.QWord,
		0x2,
		dst,
		src,
	)} // Below (C)
cmovae_r64_r64 :: proc(buffer: ^ByteBuffer, dst: Register64, src: Register64) {_encode_cmovcc(
		buffer,
		.QWord,
		0x3,
		dst,
		src,
	)} // Above or Equal (NC)
cmovbe_r64_r64 :: proc(buffer: ^ByteBuffer, dst: Register64, src: Register64) {_encode_cmovcc(
		buffer,
		.QWord,
		0x6,
		dst,
		src,
	)} // Below or Equal (C or Z)
cmova_r64_r64 :: proc(buffer: ^ByteBuffer, dst: Register64, src: Register64) {_encode_cmovcc(
		buffer,
		.QWord,
		0x7,
		dst,
		src,
	)} // Above (NC and NZ)
// Add other conditions (signed, parity, overflow) and sizes (32/16) and memory sources

cmove_r32_r32 :: proc(buffer: ^ByteBuffer, dst: Register32, src: Register32) {_encode_cmovcc(
		buffer,
		.DWord,
		0x4,
		dst,
		src,
	)}
cmovne_r32_r32 :: proc(buffer: ^ByteBuffer, dst: Register32, src: Register32) {_encode_cmovcc(
		buffer,
		.DWord,
		0x5,
		dst,
		src,
	)}
cmovb_r32_r32 :: proc(buffer: ^ByteBuffer, dst: Register32, src: Register32) {_encode_cmovcc(
		buffer,
		.DWord,
		0x2,
		dst,
		src,
	)}
cmovae_r32_r32 :: proc(buffer: ^ByteBuffer, dst: Register32, src: Register32) {_encode_cmovcc(
		buffer,
		.DWord,
		0x3,
		dst,
		src,
	)}
cmovbe_r32_r32 :: proc(buffer: ^ByteBuffer, dst: Register32, src: Register32) {_encode_cmovcc(
		buffer,
		.DWord,
		0x6,
		dst,
		src,
	)}
cmova_r32_r32 :: proc(buffer: ^ByteBuffer, dst: Register32, src: Register32) {_encode_cmovcc(
		buffer,
		.DWord,
		0x7,
		dst,
		src,
	)}

cmove_r16_r16 :: proc(buffer: ^ByteBuffer, dst: Register16, src: Register16) {_encode_cmovcc(
		buffer,
		.Word,
		0x4,
		dst,
		src,
	)}
cmovne_r16_r16 :: proc(buffer: ^ByteBuffer, dst: Register16, src: Register16) {_encode_cmovcc(
		buffer,
		.Word,
		0x5,
		dst,
		src,
	)}
cmovb_r16_r16 :: proc(buffer: ^ByteBuffer, dst: Register16, src: Register16) {_encode_cmovcc(
		buffer,
		.Word,
		0x2,
		dst,
		src,
	)}
cmovae_r16_r16 :: proc(buffer: ^ByteBuffer, dst: Register16, src: Register16) {_encode_cmovcc(
		buffer,
		.Word,
		0x3,
		dst,
		src,
	)}
cmovbe_r16_r16 :: proc(buffer: ^ByteBuffer, dst: Register16, src: Register16) {_encode_cmovcc(
		buffer,
		.Word,
		0x6,
		dst,
		src,
	)}
cmova_r16_r16 :: proc(buffer: ^ByteBuffer, dst: Register16, src: Register16) {_encode_cmovcc(
		buffer,
		.Word,
		0x7,
		dst,
		src,
	)}


// ==================================
// Conditional Set Instructions (SETcc)
// ==================================

@(private)
_encode_setcc :: proc(
	buffer: ^ByteBuffer,
	condition_code: u8,
	rm8: $T,
) where T == Register8 ||
	T == MemoryAddress {
	opcode := 0x90 + condition_code
	// SETcc is like a unary op with opcode 0F + opcode
	_encode_unary_rm(buffer, .Byte, 0x0F, 0, rm8) // Use dummy opcode ext 0
	// Overwrite the last byte (which was the ModR/M for 0xFF/0xF7) with the correct opcode
	buffer.data[buffer.len - 1] = opcode
	// Need to re-insert the ModR/M byte correctly *after* the 0F XX opcode
	modrm_byte := buffer.data[buffer.len - 2] // The ModR/M byte encoded by _encode_unary_rm
	buffer.data[buffer.len - 2] = opcode // Put the SETcc opcode in place
	_write_byte(buffer, modrm_byte) // Write the ModR/M byte at the end
}


sete_r8 :: proc(buffer: ^ByteBuffer, reg: Register8) {_encode_setcc(buffer, 0x4, reg)}
setne_r8 :: proc(buffer: ^ByteBuffer, reg: Register8) {_encode_setcc(buffer, 0x5, reg)}
setb_r8 :: proc(buffer: ^ByteBuffer, reg: Register8) {_encode_setcc(buffer, 0x2, reg)} 	// Below/Carry
setae_r8 :: proc(buffer: ^ByteBuffer, reg: Register8) {_encode_setcc(buffer, 0x3, reg)} 	// Above or Equal/Not Below
setbe_r8 :: proc(buffer: ^ByteBuffer, reg: Register8) {_encode_setcc(buffer, 0x6, reg)} 	// Below or Equal
seta_r8 :: proc(buffer: ^ByteBuffer, reg: Register8) {_encode_setcc(buffer, 0x7, reg)} 	// Above
setl_r8 :: proc(buffer: ^ByteBuffer, reg: Register8) {_encode_setcc(buffer, 0xC, reg)} 	// Less
setge_r8 :: proc(buffer: ^ByteBuffer, reg: Register8) {_encode_setcc(buffer, 0xD, reg)} 	// Greater or Equal
setle_r8 :: proc(buffer: ^ByteBuffer, reg: Register8) {_encode_setcc(buffer, 0xE, reg)} 	// Less or Equal
setg_r8 :: proc(buffer: ^ByteBuffer, reg: Register8) {_encode_setcc(buffer, 0xF, reg)} 	// Greater
// Add other conditions and memory variants


// ==================================
// Control Flow Instructions (JMP, CALL, RET, Jcc, LOOP)
// ==================================

// --- Unconditional Jumps/Calls ---
jmp_rel32 :: proc(buffer: ^ByteBuffer, offset: i32) {_write_byte(buffer, 0xE9)
	_write_imm32(buffer, u32(offset))}
jmp_rel8 :: proc(buffer: ^ByteBuffer, offset: i8) {_write_byte(buffer, 0xEB)
	_write_imm8(buffer, u8(offset))}
jmp_r64 :: proc(buffer: ^ByteBuffer, reg: Register64) {_encode_unary_rm(
		buffer,
		.QWord,
		0xFF,
		4,
		reg,
	)} // FF /4
jmp_m64 :: proc(buffer: ^ByteBuffer, mem: MemoryAddress) {_encode_unary_rm(
		buffer,
		.QWord,
		0xFF,
		4,
		mem,
	)} // FF /4

call_rel32 :: proc(buffer: ^ByteBuffer, offset: i32) {_write_byte(buffer, 0xE8)
	_write_imm32(buffer, u32(offset))}
call_r64 :: proc(buffer: ^ByteBuffer, reg: Register64) {_encode_unary_rm(
		buffer,
		.QWord,
		0xFF,
		2,
		reg,
	)} // FF /2
call_m64 :: proc(buffer: ^ByteBuffer, mem: MemoryAddress) {_encode_unary_rm(
		buffer,
		.QWord,
		0xFF,
		2,
		mem,
	)} // FF /2

ret :: proc(buffer: ^ByteBuffer) {_write_byte(buffer, 0xC3)}

// --- Conditional Jumps ---
@(private)
_encode_jcc :: proc(
	buffer: ^ByteBuffer,
	condition_code: u8,
	offset: $T,
) where T == i32 ||
	T == i8 {
	#partial switch o in offset {
	case i32:
		_write_byte(buffer, 0x0F)
		_write_byte(buffer, 0x80 + condition_code)
		_write_imm32(buffer, u32(o))
	case i8:
		_write_byte(buffer, 0x70 + condition_code)
		_write_imm8(buffer, u8(o))
	}
}

je_rel32 :: proc(buffer: ^ByteBuffer, offset: i32) {_encode_jcc(buffer, 0x4, offset)}
jne_rel32 :: proc(buffer: ^ByteBuffer, offset: i32) {_encode_jcc(buffer, 0x5, offset)}
jb_rel32 :: proc(buffer: ^ByteBuffer, offset: i32) {_encode_jcc(buffer, 0x2, offset)}
jae_rel32 :: proc(buffer: ^ByteBuffer, offset: i32) {_encode_jcc(buffer, 0x3, offset)}
jbe_rel32 :: proc(buffer: ^ByteBuffer, offset: i32) {_encode_jcc(buffer, 0x6, offset)}
ja_rel32 :: proc(buffer: ^ByteBuffer, offset: i32) {_encode_jcc(buffer, 0x7, offset)}
jl_rel32 :: proc(buffer: ^ByteBuffer, offset: i32) {_encode_jcc(buffer, 0xC, offset)}
jge_rel32 :: proc(buffer: ^ByteBuffer, offset: i32) {_encode_jcc(buffer, 0xD, offset)}
jle_rel32 :: proc(buffer: ^ByteBuffer, offset: i32) {_encode_jcc(buffer, 0xE, offset)}
jg_rel32 :: proc(buffer: ^ByteBuffer, offset: i32) {_encode_jcc(buffer, 0xF, offset)}
jo_rel32 :: proc(buffer: ^ByteBuffer, offset: i32) {_encode_jcc(buffer, 0x0, offset)}
jno_rel32 :: proc(buffer: ^ByteBuffer, offset: i32) {_encode_jcc(buffer, 0x1, offset)}
js_rel32 :: proc(buffer: ^ByteBuffer, offset: i32) {_encode_jcc(buffer, 0x8, offset)}
jns_rel32 :: proc(buffer: ^ByteBuffer, offset: i32) {_encode_jcc(buffer, 0x9, offset)}
jp_rel32 :: proc(buffer: ^ByteBuffer, offset: i32) {_encode_jcc(buffer, 0xA, offset)}
jnp_rel32 :: proc(buffer: ^ByteBuffer, offset: i32) {_encode_jcc(buffer, 0xB, offset)}

je_rel8 :: proc(buffer: ^ByteBuffer, offset: i8) {_encode_jcc(buffer, 0x4, offset)}
jne_rel8 :: proc(buffer: ^ByteBuffer, offset: i8) {_encode_jcc(buffer, 0x5, offset)}
jb_rel8 :: proc(buffer: ^ByteBuffer, offset: i8) {_encode_jcc(buffer, 0x2, offset)}
jae_rel8 :: proc(buffer: ^ByteBuffer, offset: i8) {_encode_jcc(buffer, 0x3, offset)}
jbe_rel8 :: proc(buffer: ^ByteBuffer, offset: i8) {_encode_jcc(buffer, 0x6, offset)}
ja_rel8 :: proc(buffer: ^ByteBuffer, offset: i8) {_encode_jcc(buffer, 0x7, offset)}
jl_rel8 :: proc(buffer: ^ByteBuffer, offset: i8) {_encode_jcc(buffer, 0xC, offset)}
jge_rel8 :: proc(buffer: ^ByteBuffer, offset: i8) {_encode_jcc(buffer, 0xD, offset)}
jle_rel8 :: proc(buffer: ^ByteBuffer, offset: i8) {_encode_jcc(buffer, 0xE, offset)}
jg_rel8 :: proc(buffer: ^ByteBuffer, offset: i8) {_encode_jcc(buffer, 0xF, offset)}
jo_rel8 :: proc(buffer: ^ByteBuffer, offset: i8) {_encode_jcc(buffer, 0x0, offset)}
jno_rel8 :: proc(buffer: ^ByteBuffer, offset: i8) {_encode_jcc(buffer, 0x1, offset)}
js_rel8 :: proc(buffer: ^ByteBuffer, offset: i8) {_encode_jcc(buffer, 0x8, offset)}
jns_rel8 :: proc(buffer: ^ByteBuffer, offset: i8) {_encode_jcc(buffer, 0x9, offset)}
jp_rel8 :: proc(buffer: ^ByteBuffer, offset: i8) {_encode_jcc(buffer, 0xA, offset)}
jnp_rel8 :: proc(buffer: ^ByteBuffer, offset: i8) {_encode_jcc(buffer, 0xB, offset)}

// --- LOOP ---
loop_rel8 :: proc(buffer: ^ByteBuffer, offset: i8) {_write_byte(buffer, 0xE2)
	_write_imm8(buffer, u8(offset))}
loope_rel8 :: proc(buffer: ^ByteBuffer, offset: i8) {_write_byte(buffer, 0xE1)
	_write_imm8(buffer, u8(offset))}
loopne_rel8 :: proc(buffer: ^ByteBuffer, offset: i8) {_write_byte(buffer, 0xE0)
	_write_imm8(buffer, u8(offset))}
jecxz_rel8 :: proc(buffer: ^ByteBuffer, offset: i8) {_write_bytes(buffer, []u8{0x67, 0xE3})
	_write_imm8(buffer, u8(offset))} // 67 = Address size override

// --- ENDBR ---
endbr64 :: proc(buffer: ^ByteBuffer) {_write_bytes(buffer, []u8{0xF3, 0x0F, 0x1E, 0xFA})}


// ==================================
// Stack Operations (PUSH, POP, ENTER, LEAVE)
// ==================================

push_r64 :: proc(buffer: ^ByteBuffer, reg: Register64) {
	rex_b := (u8(reg) & 0x8) != 0
	rex := get_rex_prefix(false, false, false, rex_b)
	if rex != 0 do _write_byte(buffer, rex)
	_write_byte(buffer, 0x50 + (u8(reg) & 0x7))
}
pop_r64 :: proc(buffer: ^ByteBuffer, reg: Register64) {
	rex_b := (u8(reg) & 0x8) != 0
	rex := get_rex_prefix(false, false, false, rex_b)
	if rex != 0 do _write_byte(buffer, rex)
	_write_byte(buffer, 0x58 + (u8(reg) & 0x7))
}

push_r16 :: proc(buffer: ^ByteBuffer, reg: Register16) {
	_write_byte(buffer, 0x66)
	rex_b := (u8(reg) & 0x8) != 0
	rex := get_rex_prefix(false, false, false, rex_b)
	if rex != 0 do _write_byte(buffer, rex)
	_write_byte(buffer, 0x50 + (u8(reg) & 0x7))
}
pop_r16 :: proc(buffer: ^ByteBuffer, reg: Register16) {
	_write_byte(buffer, 0x66)
	rex_b := (u8(reg) & 0x8) != 0
	rex := get_rex_prefix(false, false, false, rex_b)
	if rex != 0 do _write_byte(buffer, rex)
	_write_byte(buffer, 0x58 + (u8(reg) & 0x7))
}

pushfq :: proc(buffer: ^ByteBuffer) {_write_byte(buffer, 0x9C)}
popfq :: proc(buffer: ^ByteBuffer) {_write_byte(buffer, 0x9D)}
pushf :: proc(buffer: ^ByteBuffer) {pushfq(buffer)} 	// Alias in 64-bit mode
popf :: proc(buffer: ^ByteBuffer) {popfq(buffer)} 	// Alias in 64-bit mode

enter :: proc(buffer: ^ByteBuffer, size: u16, nesting: u8) {
	_write_byte(buffer, 0xC8)
	_write_imm16(buffer, size)
	_write_imm8(buffer, nesting)
}

leave :: proc(buffer: ^ByteBuffer) {_write_byte(buffer, 0xC9)}

// ==================================
// SIMD AND FLOATING-POINT INSTRUCTIONS (SSE, AVX, AVX-512)
// ==================================

// --- Helper: VEX/EVEX Encoding ---

// Encodes VEX 2-byte prefix. Returns slice containing the prefix.
@(private)
_encode_vex2 :: proc(r: bool, vvvv: u8, l: bool, pp: u8) -> [2]u8 {
	vex: [2]u8
	vex[0] = 0xC5
	vex[1] = ((~u8(r) & 1) << 7) | ((~vvvv & 0xF) << 3) | (u8(l) << 2) | pp
	return vex
}

// Encodes VEX 3-byte prefix. Returns slice containing the prefix.
@(private)
_encode_vex3 :: proc(
	r: bool,
	x: bool,
	b: bool,
	m: u8,
	w: bool,
	vvvv: u8,
	l: bool,
	pp: u8,
) -> [3]u8 {
	vex: [3]u8
	vex[0] = 0xC4
	// Byte 2: ~R, ~X, ~B, m-mmmm
	vex[1] = ((~u8(r) & 1) << 7) | ((~u8(x) & 1) << 6) | ((~u8(b) & 1) << 5) | m
	// Byte 3: W, ~vvvv, L, pp
	vex[2] = (u8(w) << 7) | ((~vvvv & 0xF) << 3) | (u8(l) << 2) | pp
	return vex
}

// Encodes EVEX 4-byte prefix. Returns slice containing the prefix.
@(private)
_encode_evex :: proc(
	r: bool,
	x: bool,
	b: bool,
	r_prime: bool, // REX bits R',X',B',R'
	mm: u8, // Implied map (0F, 0F38, 0F3A) -> 1, 2, 3
	w: bool, // Operand size / REX.W
	vvvv: u8, // Second source/dest register specifier (~ encoded)
	pp: u8, // Implied prefix (None, 66, F3, F2) -> 0, 1, 2, 3
	z: bool, // Zeroing masking
	ll: u8, // Vector length (128/LIG=0, 256/L0=1, 512/L1=2) or rounding control
	b_mem: bool, // Broadcast/Rounding control/Static rounding
	v_prime: bool, // High bit of vvvv if VSIB/RC/SAE
	aaa: u8, // Mask register k0-k7
) -> [4]u8 {
	evex: [4]u8
	evex[0] = 0x62
	// P1: ~R, ~X, ~B, ~R', 00, mm
	evex[1] =
		((~u8(r) & 1) << 7) |
		((~u8(x) & 1) << 6) |
		((~u8(b) & 1) << 5) |
		((~u8(r_prime) & 1) << 4) |
		(mm & 0x3)
	// P2: W, ~vvvv, 1, pp
	evex[2] = (u8(w) << 7) | ((~vvvv & 0xF) << 3) | (1 << 2) | (pp & 0x3)
	// P3: z, L'L, b, ~V', aaa
	evex[3] =
		(u8(z) << 7) |
		((ll & 0x3) << 5) |
		(u8(b_mem) << 4) |
		((~u8(v_prime) & 1) << 3) |
		(aaa & 0x7)
	return evex
}

// --- Helper: Get Register Encodings ---

// Returns REX/VEX.R/EVEX.R' bits and low 3 bits for general purpose registers
@(private)
_get_gpr_encoding :: proc(
	reg: $T,
) -> (
	r_bit: bool,
	low_bits: u8,
) where T == Register64 ||
	T == Register32 ||
	T == Register16 {
	val := u8(reg)
	return (val & 0x8) != 0, val & 0x7
}
// Returns REX/VEX.B/EVEX.B' bits and low 3 bits for general purpose registers (when used in RM/Base field)
@(private)
_get_gpr_rm_encoding :: proc(
	reg: $T,
) -> (
	b_bit: bool,
	low_bits: u8,
) where T == Register64 ||
	T == Register32 ||
	T == Register16 {
	val := u8(reg)
	return (val & 0x8) != 0, val & 0x7
}
// Returns REX/VEX.X/EVEX.X' bits and low 3 bits for general purpose registers (when used in Index field)
@(private)
_get_gpr_idx_encoding :: proc(reg: Register64) -> (x_bit: bool, low_bits: u8) {
	val := u8(reg)
	return (val & 0x8) != 0, val & 0x7
}

// Returns VEX/EVEX vvvv bits and high bit V' for SIMD regs
@(private)
_get_vvvv_encoding :: proc(
	reg: $T,
) -> (
	vvvv_bits: u8,
	v_prime_bit: bool,
) where T == XMMRegister ||
	T == YMMRegister ||
	T == ZMMRegister {
	val := u8(reg)
	return val & 0xF, (val & 0x10) != 0
}

// Returns REX/VEX/EVEX R bits and low 3 bits for SIMD regs (used in REG field)
@(private)
_get_simd_reg_encoding :: proc(
	reg: $T,
) -> (
	r_bit: bool,
	r_prime_bit: bool,
	low_bits: u8,
) where T == XMMRegister ||
	T == YMMRegister ||
	T == ZMMRegister {
	val := u8(reg)
	return (val & 0x8) != 0, (val & 0x10) != 0, val & 0x7
}
// Returns REX/VEX/EVEX B bits and low 3 bits for SIMD regs (used in RM field)
@(private)
_get_simd_rm_encoding :: proc(
	reg: $T,
) -> (
	b_bit: bool,
	b_prime_bit: bool,
	low_bits: u8,
) where T == XMMRegister ||
	T == YMMRegister ||
	T == ZMMRegister {
	val := u8(reg)
	return (val & 0x8) != 0, (val & 0x10) != 0, val & 0x7
}
// Returns VEX/EVEX X bits and low 3 bits for SIMD regs (used in Index field for VSIB)
@(private)
_get_simd_idx_encoding :: proc(
	reg: $T,
) -> (
	x_bit: bool,
	x_prime_bit: bool,
	low_bits: u8,
) where T == XMMRegister ||
	T == YMMRegister ||
	T == ZMMRegister {
	val := u8(reg)
	// Note: EVEX X' is combined with B' (b_mem bit field) for VSIB, but VEX.X is separate
	return (val & 0x8) != 0, (val & 0x10) != 0, val & 0x7
}


// --- Helper: Encode SSE/AVX/AVX-512 Operations ---

// Encodes legacy SSE instructions (REX prefix)
@(private)
_encode_sse_op :: proc(
	buffer: ^ByteBuffer,
	prefix: Maybe(u8), // Optional 66/F2/F3 prefix
	rex_w: bool,
	opcodes: []u8,
	reg: $T, // XMM/GPR in ModRM.reg
	rm: $U, // XMM/GPR/Mem in ModRM.rm/sib
	imm8: Maybe(u8), // Optional immediate byte
) where T == XMMRegister || T == Register64 || T == Register32,
	U == T || U == MemoryAddress {

	if p := prefix; p != nil do _write_byte(buffer, p.?)

	reg_r, reg_low := false, u8(0)
	#partial switch r in reg {
	case XMMRegister:
		reg_r, _, reg_low = _get_simd_reg_encoding(r)
	case Register64, Register32:
		reg_r, reg_low = _get_gpr_encoding(r)
	}

	rm_r, rm_low := false, u8(0) // For register RM
	mem_rex_x, mem_rex_b := false, false // For memory RM

	force_rex := false // For MOVD with GPR r8-r15 if W=0
	if T == Register32 && U == XMMRegister { 	// movd r32, xmm
		_, rm_low = _get_gpr_encoding(reg.(Register32)) // dst is in reg field
		reg_r, _, reg_low = _get_simd_reg_encoding(rm.(XMMRegister)) // src is in rm field
		force_rex = u8(reg) >= 8
	}
	if T == XMMRegister && U == Register32 { 	// movd xmm, r32
		reg_r, _, reg_low = _get_simd_reg_encoding(reg.(XMMRegister)) // dst is in reg field
		rm_r, rm_low = _get_gpr_rm_encoding(rm.(Register32)) // src is in rm field
		force_rex = u8(rm) >= 8
	}


	#partial switch v in rm {
	case MemoryAddress:
		break // REX.X/B handled below
	case XMMRegister:
		rm_r, _, rm_low = _get_simd_rm_encoding(v)
	case Register64, Register32:
		rm_r, rm_low = _get_gpr_rm_encoding(v)
	}

	rex_byte: u8 = 0
	opcode_start_index := buffer.len // Remember start for potential REX insertion

	#partial switch v in rm {
	case MemoryAddress:
		break // Defer REX write
	case T:
		// Write REX now for register operands
		rex_byte = get_rex_prefix(rex_w, reg_r, false, rm_r, force_rex)
		if rex_byte != 0 do _write_byte(buffer, rex_byte)
	}

	_write_bytes(buffer, opcodes)

	#partial switch v in rm {
	case MemoryAddress:
		mem_rex_x, mem_rex_b = _encode_mem_modrm_sib_disp(buffer, v, reg_low)
		// Now insert REX if needed
		rex_byte = get_rex_prefix(rex_w, reg_r, mem_rex_x, mem_rex_b, force_rex)
		if rex_byte != 0 {
			required_size := buffer.len + 1
			if required_size > buffer.cap {grow(buffer, required_size)}
			mem.move_ptr(
				raw_data(buffer.data[opcode_start_index + 1:]),
				raw_data(buffer.data[opcode_start_index:]),
				buffer.len - opcode_start_index,
			)
			buffer.data[opcode_start_index] = rex_byte
			buffer.len += 1
		}
	case T:
		_write_byte(buffer, encode_modrm(3, reg_low, rm_low))
	}

	if i := imm8; i != nil do _write_imm8(buffer, i.?)
}

// Encodes VEX-based instructions (AVX, FMA, etc.)
@(private)
_encode_vex_op :: proc(
	buffer: ^ByteBuffer,
	pp: u8, // VEX.pp field (0=None, 1=66, 2=F3, 3=F2)
	m: u8, // VEX.m-mmmm field (0=Implied 0F, 1=0F, 2=0F38, 3=0F3A)
	vex_w: bool, // VEX.W field
	vex_l: bool, // VEX.L field (0=128b, 1=256b)
	opcodes: []u8,
	reg: $T, // Dest register (usually)
	vvvv_reg: $T, // VEX.vvvv register (usually src1)
	rm: $U, // Register (src2) or Memory operand
	imm8: Maybe(u8), // Optional immediate byte
) where T == XMMRegister || T == YMMRegister || T == MaskRegister,
	U == T || U == MemoryAddress {

	reg_r, _, reg_low := _get_simd_reg_encoding(reg.(T)) // Destination R bit, low 3 bits
	vvvv_val, _ := _get_vvvv_encoding(vvvv_reg.(T)) // vvvv value

	rm_b, _, rm_low := false, u8(0) // For register RM
	mem_x, mem_b := false, false // For memory RM
	is_vsib := false // Check if rm specifies VSIB addressing later

	#partial switch v in rm {
	case MemoryAddress:
		break // X/B determined later
	case T:
		rm_b, _, rm_low = _get_simd_rm_encoding(v.(T))
	}

	// Choose VEX2 or VEX3 encoding
	// Conditions for VEX3: X/B/W=1, or m-mmmm != 1
	use_vex3 := rm_b || vex_w || m != 1
	if mem, ok := rm.(MemoryAddress); ok {
		use_vex3 = true // Always VEX3 for memory (need X/B)
	}

	vex_bytes: []u8
	if use_vex3 {
		vex := _encode_vex3(reg_r, mem_x, rm_b || mem_b, m, vex_w, vvvv_val, vex_l, pp)
		vex_bytes = vex[:]
	} else {
		vex := _encode_vex2(reg_r, vvvv_val, vex_l, pp)
		vex_bytes = vex[:]
	}
	vex_start_index := buffer.len
	_write_bytes(buffer, vex_bytes)
	opcode_start_index := buffer.len
	_write_bytes(buffer, opcodes)

	#partial switch v in rm {
	case MemoryAddress:
		mem_x, mem_b = _encode_mem_modrm_sib_disp(buffer, v, reg_low)
		if use_vex3 { 	// Need to potentially update VEX byte 1
			vex_b1 := &buffer.data[vex_start_index + 1]
			if mem_x do vex_b1^ &~= (1 << 6) // Invert to set ~X
			if mem_b do vex_b1^ &~= (1 << 5) // Invert to set ~B
		} else if mem_x || mem_b { 	// Need to switch from VEX2 to VEX3
			// This is complex: involves shifting opcodes/mem bytes, re-encoding VEX
			fmt.eprintf(
				"Internal Error: VEX2 -> VEX3 switch needed for memory operand, not implemented cleanly yet.\n",
			)
			// For simplicity, we might just always use VEX3 if memory is possible.
			return
		}
	case T:
		_write_byte(buffer, encode_modrm(3, reg_low, rm_low))
	}

	if i := imm8; i != nil do _write_imm8(buffer, i.?)
}

// Encodes EVEX-based instructions (AVX-512)
@(private)
_encode_evex_op :: proc(
	buffer: ^ByteBuffer,
	pp: u8, // EVEX.pp field (0=None, 1=66, 2=F3, 3=F2)
	m: u8, // EVEX.mm field (1=0F, 2=0F38, 3=0F3A)
	evex_w: bool, // EVEX.W field
	evex_ll: u8, // EVEX.L'L field (0=128b, 1=256b, 2=512b) or RC
	opcodes: []u8,
	mask: MaskRegister, // Mask register (k0-k7), k0 means no mask unless z=1
	zeroing: bool, // EVEX.z field
	reg: $T, // Dest register
	vvvv_reg: $T, // EVEX.vvvv register (usually src1)
	rm: $U, // Register (src2) or Memory operand
	broadcast_or_rc_sae: bool, // EVEX.b field (broadcast for mem, RC/SAE for reg-reg)
	imm8: Maybe(u8), // Optional immediate byte
) where T == XMMRegister || T == YMMRegister || T == ZMMRegister,
	U == T || U == MemoryAddress {

	reg_r, reg_rp, reg_low := _get_simd_reg_encoding(reg)
	vvvv_val, v_prime := _get_vvvv_encoding(vvvv_reg)

	rm_b, rm_bp, rm_low := false, false, u8(0) // For register RM
	mem_x, mem_b, mem_bp := false, false, false // For memory RM (X', B', B')
	is_vsib := false // Check for VSIB later

	#partial switch v in rm {
	case MemoryAddress:
		// Need to check if it's VSIB addressing
		// This requires looking inside the AddressComponents
		if ac, ok := v.(AddressComponents); ok {
			switch idx in ac.index {
			case XMMRegister, YMMRegister, ZMMRegister:
				is_vsib = true
				mem_x, mem_bp, _ = get_simd_idx_encoding(idx) // EVEX.X' and V' come from Index
			}

			if ac.base != nil {
				mem_b, _, _ = get_gpr_rm_encoding(ac.base^) // EVEX.B' comes from Base
			}
		}
	case T:
		rm_b, rm_bp, rm_low = _get_simd_rm_encoding(v)
	}

	// V' bit source depends on instruction (VSIB vs Reg-Reg with SAE/RC)
	final_v_prime := v_prime
	if is_vsib {
		final_v_prime = mem_bp // Use B' from index register for VSIB V'
	} else if _, ok := rm.(T); ok && broadcast_or_rc_sae {
		final_v_prime = v_prime // Use V' from vvvv register for SAE/RC
	}


	evex := _encode_evex(
		reg_r,
		mem_x,
		rm_b || mem_b,
		reg_rp,
		m,
		evex_w,
		vvvv_val,
		pp,
		zeroing,
		evex_ll,
		broadcast_or_rc_sae,
		final_v_prime,
		u8(mask),
	)
	_write_bytes(buffer, evex[:])
	_write_bytes(buffer, opcodes)

	#partial switch v in rm {
	case MemoryAddress:
		// VSIB encoding is handled differently
		if is_vsib {
			// Need a specialized VSIB encoder
			_encode_vsib_modrm_sib_disp(buffer, v.(AddressComponents), reg_low)
		} else {
			_, _ = _encode_mem_modrm_sib_disp(buffer, v, reg_low) // Get normal mem encoding
		}
	case T:
		_write_byte(buffer, encode_modrm(3, reg_low, rm_low))
	}

	if i := imm8; i != nil do _write_imm8(buffer, i.?)
}


// --- SSE/SSE2 Register Transfer ---
movd_xmm_r64 :: proc(buffer: ^ByteBuffer, xmm: XMMRegister, reg: Register64) {_encode_sse_op(
		buffer,
		0x66,
		true,
		[]u8{0x0F, 0x6E},
		xmm,
		reg,
		nil,
	)} // 66 REX.W 0F 6E /r
movd_r64_xmm :: proc(buffer: ^ByteBuffer, reg: Register64, xmm: XMMRegister) {_encode_sse_op(
		buffer,
		0x66,
		true,
		[]u8{0x0F, 0x7E},
		reg,
		xmm,
		nil,
	)} // 66 REX.W 0F 7E /r
movd_xmm_r32 :: proc(buffer: ^ByteBuffer, xmm: XMMRegister, reg: Register32) {_encode_sse_op(
		buffer,
		0x66,
		false,
		[]u8{0x0F, 0x6E},
		xmm,
		reg,
		nil,
	)} // 66 0F 6E /r
movd_r32_xmm :: proc(buffer: ^ByteBuffer, reg: Register32, xmm: XMMRegister) {_encode_sse_op(
		buffer,
		0x66,
		false,
		[]u8{0x0F, 0x7E},
		reg,
		xmm,
		nil,
	)} // 66 0F 7E /r

movq_xmm_r64 :: proc(buffer: ^ByteBuffer, xmm: XMMRegister, reg: Register64) {movd_xmm_r64(
		buffer,
		xmm,
		reg,
	)} // Alias in 64-bit
movq_r64_xmm :: proc(buffer: ^ByteBuffer, reg: Register64, xmm: XMMRegister) {movd_r64_xmm(
		buffer,
		reg,
		xmm,
	)} // Alias in 64-bit

movq_xmm_xmm :: proc(buffer: ^ByteBuffer, dst: XMMRegister, src: XMMRegister) {_encode_sse_op(
		buffer,
		0xF3,
		false,
		[]u8{0x0F, 0x7E},
		dst,
		src,
		nil,
	)} // F3 0F 7E /r
movq_xmm_m64 :: proc(buffer: ^ByteBuffer, dst: XMMRegister, mem: MemoryAddress) {_encode_sse_op(
		buffer,
		0xF3,
		false,
		[]u8{0x0F, 0x7E},
		dst,
		mem,
		nil,
	)} // F3 0F 7E /r
movq_m64_xmm :: proc(buffer: ^ByteBuffer, mem: MemoryAddress, src: XMMRegister) {_encode_sse_op(
		buffer,
		0x66,
		false,
		[]u8{0x0F, 0xD6},
		src,
		mem,
		nil,
	)} // 66 0F D6 /r

// --- SSE/SSE2 Data Movement (Packed) ---
movdqa_xmm_xmm :: proc(buffer: ^ByteBuffer, dst: XMMRegister, src: XMMRegister) {_encode_sse_op(
		buffer,
		0x66,
		false,
		[]u8{0x0F, 0x6F},
		dst,
		src,
		nil,
	)} // 66 0F 6F /r
movdqa_xmm_m128 :: proc(
	buffer: ^ByteBuffer,
	dst: XMMRegister,
	mem: MemoryAddress,
) {_encode_sse_op(buffer, 0x66, false, []u8{0x0F, 0x6F}, dst, mem, nil)} 	// 66 0F 6F /r
movdqa_m128_xmm :: proc(
	buffer: ^ByteBuffer,
	mem: MemoryAddress,
	src: XMMRegister,
) {_encode_sse_op(buffer, 0x66, false, []u8{0x0F, 0x7F}, src, mem, nil)} 	// 66 0F 7F /r

movdqu_xmm_xmm :: proc(buffer: ^ByteBuffer, dst: XMMRegister, src: XMMRegister) {_encode_sse_op(
		buffer,
		0xF3,
		false,
		[]u8{0x0F, 0x6F},
		dst,
		src,
		nil,
	)} // F3 0F 6F /r
movdqu_xmm_m128 :: proc(
	buffer: ^ByteBuffer,
	dst: XMMRegister,
	mem: MemoryAddress,
) {_encode_sse_op(buffer, 0xF3, false, []u8{0x0F, 0x6F}, dst, mem, nil)} 	// F3 0F 6F /r
movdqu_m128_xmm :: proc(
	buffer: ^ByteBuffer,
	mem: MemoryAddress,
	src: XMMRegister,
) {_encode_sse_op(buffer, 0xF3, false, []u8{0x0F, 0x7F}, src, mem, nil)} 	// F3 0F 7F /r

movaps_xmm_xmm :: proc(buffer: ^ByteBuffer, dst: XMMRegister, src: XMMRegister) {_encode_sse_op(
		buffer,
		nil,
		false,
		[]u8{0x0F, 0x28},
		dst,
		src,
		nil,
	)} // 0F 28 /r
movaps_xmm_m128 :: proc(
	buffer: ^ByteBuffer,
	dst: XMMRegister,
	mem: MemoryAddress,
) {_encode_sse_op(buffer, nil, false, []u8{0x0F, 0x28}, dst, mem, nil)} 	// 0F 28 /r
movaps_m128_xmm :: proc(
	buffer: ^ByteBuffer,
	mem: MemoryAddress,
	src: XMMRegister,
) {_encode_sse_op(buffer, nil, false, []u8{0x0F, 0x29}, src, mem, nil)} 	// 0F 29 /r

movapd_xmm_xmm :: proc(buffer: ^ByteBuffer, dst: XMMRegister, src: XMMRegister) {_encode_sse_op(
		buffer,
		0x66,
		false,
		[]u8{0x0F, 0x28},
		dst,
		src,
		nil,
	)} // 66 0F 28 /r
movapd_xmm_m128 :: proc(
	buffer: ^ByteBuffer,
	dst: XMMRegister,
	mem: MemoryAddress,
) {_encode_sse_op(buffer, 0x66, false, []u8{0x0F, 0x28}, dst, mem, nil)} 	// 66 0F 28 /r
movapd_m128_xmm :: proc(
	buffer: ^ByteBuffer,
	mem: MemoryAddress,
	src: XMMRegister,
) {_encode_sse_op(buffer, 0x66, false, []u8{0x0F, 0x29}, src, mem, nil)} 	// 66 0F 29 /r

movups_xmm_xmm :: proc(buffer: ^ByteBuffer, dst: XMMRegister, src: XMMRegister) {_encode_sse_op(
		buffer,
		nil,
		false,
		[]u8{0x0F, 0x10},
		dst,
		src,
		nil,
	)} // 0F 10 /r
movups_xmm_m128 :: proc(
	buffer: ^ByteBuffer,
	dst: XMMRegister,
	mem: MemoryAddress,
) {_encode_sse_op(buffer, nil, false, []u8{0x0F, 0x10}, dst, mem, nil)} 	// 0F 10 /r
movups_m128_xmm :: proc(
	buffer: ^ByteBuffer,
	mem: MemoryAddress,
	src: XMMRegister,
) {_encode_sse_op(buffer, nil, false, []u8{0x0F, 0x11}, src, mem, nil)} 	// 0F 11 /r

// --- SSE Arithmetic ---
addps_xmm_xmm :: proc(buffer: ^ByteBuffer, dst: XMMRegister, src: XMMRegister) {_encode_sse_op(
		buffer,
		nil,
		false,
		[]u8{0x0F, 0x58},
		dst,
		src,
		nil,
	)} // 0F 58 /r
subps_xmm_xmm :: proc(buffer: ^ByteBuffer, dst: XMMRegister, src: XMMRegister) {_encode_sse_op(
		buffer,
		nil,
		false,
		[]u8{0x0F, 0x5C},
		dst,
		src,
		nil,
	)} // 0F 5C /r
mulps_xmm_xmm :: proc(buffer: ^ByteBuffer, dst: XMMRegister, src: XMMRegister) {_encode_sse_op(
		buffer,
		nil,
		false,
		[]u8{0x0F, 0x59},
		dst,
		src,
		nil,
	)} // 0F 59 /r
divps_xmm_xmm :: proc(buffer: ^ByteBuffer, dst: XMMRegister, src: XMMRegister) {_encode_sse_op(
		buffer,
		nil,
		false,
		[]u8{0x0F, 0x5E},
		dst,
		src,
		nil,
	)} // 0F 5E /r
sqrtps_xmm_xmm :: proc(buffer: ^ByteBuffer, dst: XMMRegister, src: XMMRegister) {_encode_sse_op(
		buffer,
		nil,
		false,
		[]u8{0x0F, 0x51},
		dst,
		src,
		nil,
	)} // 0F 51 /r

// --- SSE Compare ---
cmpps_xmm_xmm_imm8 :: proc(
	buffer: ^ByteBuffer,
	dst: XMMRegister,
	src: XMMRegister,
	imm: u8,
) {_encode_sse_op(buffer, nil, false, []u8{0x0F, 0xC2}, dst, src, imm)} 	// 0F C2 /r ib
cmpeqps_xmm_xmm :: proc(
	buffer: ^ByteBuffer,
	dst: XMMRegister,
	src: XMMRegister,
) {cmpps_xmm_xmm_imm8(buffer, dst, src, 0x00)}
cmpneqps_xmm_xmm :: proc(
	buffer: ^ByteBuffer,
	dst: XMMRegister,
	src: XMMRegister,
) {cmpps_xmm_xmm_imm8(buffer, dst, src, 0x04)}
// Add other CMPPS predicates

// --- AVX Arithmetic (using VEX) ---
vaddps_ymm_ymm_ymm :: proc(
	buffer: ^ByteBuffer,
	dst: YMMRegister,
	src1: YMMRegister,
	src2: YMMRegister,
) {_encode_vex_op(buffer, 0, 1, false, true, []u8{0x58}, dst, src1, src2, nil)} 	// VEX.256.0F.WIG 58 /r
vaddps_xmm_xmm_xmm :: proc(
	buffer: ^ByteBuffer,
	dst: XMMRegister,
	src1: XMMRegister,
	src2: XMMRegister,
) {_encode_vex_op(buffer, 0, 1, false, false, []u8{0x58}, dst, src1, src2, nil)} 	// VEX.128.0F.WIG 58 /r
vmulps_ymm_ymm_ymm :: proc(
	buffer: ^ByteBuffer,
	dst: YMMRegister,
	src1: YMMRegister,
	src2: YMMRegister,
) {_encode_vex_op(buffer, 0, 1, false, true, []u8{0x59}, dst, src1, src2, nil)} 	// VEX.256.0F.WIG 59 /r
vdivps_ymm_ymm_ymm :: proc(
	buffer: ^ByteBuffer,
	dst: YMMRegister,
	src1: YMMRegister,
	src2: YMMRegister,
) {_encode_vex_op(buffer, 0, 1, false, true, []u8{0x5E}, dst, src1, src2, nil)} 	// VEX.256.0F.WIG 5E /r

// --- FMA (using VEX) ---
vfmadd132ps_xmm_xmm_xmm :: proc(
	buffer: ^ByteBuffer,
	dst: XMMRegister,
	src1: XMMRegister,
	src2: XMMRegister,
) {_encode_vex_op(buffer, 1, 2, false, false, []u8{0x98}, dst, src1, src2, nil)} 	// VEX.128.66.0F38.W0 98 /r
vfmadd213ps_xmm_xmm_xmm :: proc(
	buffer: ^ByteBuffer,
	dst: XMMRegister,
	src1: XMMRegister,
	src2: XMMRegister,
) {_encode_vex_op(buffer, 1, 2, false, false, []u8{0xA8}, dst, src1, src2, nil)} 	// VEX.128.66.0F38.W0 A8 /r
vfmadd231ps_xmm_xmm_xmm :: proc(
	buffer: ^ByteBuffer,
	dst: XMMRegister,
	src1: XMMRegister,
	src2: XMMRegister,
) {_encode_vex_op(buffer, 1, 2, false, false, []u8{0xB8}, dst, src1, src2, nil)} 	// VEX.128.66.0F38.W0 B8 /r
// Add YMM versions (vex_l=true) and memory operand versions

// --- AVX Blend ---
vblendps_ymm_ymm_ymm_imm8 :: proc(
	buffer: ^ByteBuffer,
	dst: YMMRegister,
	src1: YMMRegister,
	src2: YMMRegister,
	imm: u8,
) {_encode_vex_op(buffer, 1, 3, false, true, []u8{0x0C}, dst, src1, src2, imm)} 	// VEX.256.66.0F3A.WIG 0C /r ib

// --- AVX Moves (YMM) ---
vmovdqa_ymm_ymm :: proc(buffer: ^ByteBuffer, dst: YMMRegister, src: YMMRegister) {_encode_vex_op(
		buffer,
		1,
		1,
		false,
		true,
		[]u8{0x6F},
		dst,
		dst,
		src,
		nil,
	)} // VEX.256.66.0F.WIG 6F /r (vvvv ignored)
vmovdqa_ymm_m256 :: proc(
	buffer: ^ByteBuffer,
	dst: YMMRegister,
	mem: MemoryAddress,
) {_encode_vex_op(buffer, 1, 1, false, true, []u8{0x6F}, dst, dst, mem, nil)} 	// VEX.256.66.0F.WIG 6F /r
vmovdqa_m256_ymm :: proc(
	buffer: ^ByteBuffer,
	mem: MemoryAddress,
	src: YMMRegister,
) {_encode_vex_op(buffer, 1, 1, false, true, []u8{0x7F}, src, src, mem, nil)} 	// VEX.256.66.0F.WIG 7F /r
vmovdqu_ymm_ymm :: proc(buffer: ^ByteBuffer, dst: YMMRegister, src: YMMRegister) {_encode_vex_op(
		buffer,
		2,
		1,
		false,
		true,
		[]u8{0x6F},
		dst,
		dst,
		src,
		nil,
	)} // VEX.256.F3.0F.WIG 6F /r
vmovdqu_ymm_m256 :: proc(
	buffer: ^ByteBuffer,
	dst: YMMRegister,
	mem: MemoryAddress,
) {_encode_vex_op(buffer, 2, 1, false, true, []u8{0x6F}, dst, dst, mem, nil)} 	// VEX.256.F3.0F.WIG 6F /r
vmovdqu_m256_ymm :: proc(
	buffer: ^ByteBuffer,
	mem: MemoryAddress,
	src: YMMRegister,
) {_encode_vex_op(buffer, 2, 1, false, true, []u8{0x7F}, src, src, mem, nil)} 	// VEX.256.F3.0F.WIG 7F /r
vmovaps_ymm_ymm :: proc(buffer: ^ByteBuffer, dst: YMMRegister, src: YMMRegister) {_encode_vex_op(
		buffer,
		0,
		1,
		false,
		true,
		[]u8{0x28},
		dst,
		dst,
		src,
		nil,
	)} // VEX.256.0F.WIG 28 /r
vmovaps_ymm_m256 :: proc(
	buffer: ^ByteBuffer,
	dst: YMMRegister,
	mem: MemoryAddress,
) {_encode_vex_op(buffer, 0, 1, false, true, []u8{0x28}, dst, dst, mem, nil)} 	// VEX.256.0F.WIG 28 /r
vmovaps_m256_ymm :: proc(
	buffer: ^ByteBuffer,
	mem: MemoryAddress,
	src: YMMRegister,
) {_encode_vex_op(buffer, 0, 1, false, true, []u8{0x29}, src, src, mem, nil)} 	// VEX.256.0F.WIG 29 /r
vmovapd_ymm_ymm :: proc(buffer: ^ByteBuffer, dst: YMMRegister, src: YMMRegister) {_encode_vex_op(
		buffer,
		1,
		1,
		false,
		true,
		[]u8{0x28},
		dst,
		dst,
		src,
		nil,
	)} // VEX.256.66.0F.WIG 28 /r
vmovapd_ymm_m256 :: proc(
	buffer: ^ByteBuffer,
	dst: YMMRegister,
	mem: MemoryAddress,
) {_encode_vex_op(buffer, 1, 1, false, true, []u8{0x28}, dst, dst, mem, nil)} 	// VEX.256.66.0F.WIG 28 /r
vmovapd_m256_ymm :: proc(
	buffer: ^ByteBuffer,
	mem: MemoryAddress,
	src: YMMRegister,
) {_encode_vex_op(buffer, 1, 1, false, true, []u8{0x29}, src, src, mem, nil)} 	// VEX.256.66.0F.WIG 29 /r

// --- AVX Logical ---
vpand_ymm_ymm_ymm :: proc(
	buffer: ^ByteBuffer,
	dst: YMMRegister,
	src1: YMMRegister,
	src2: YMMRegister,
) {_encode_vex_op(buffer, 1, 1, false, true, []u8{0xDB}, dst, src1, src2, nil)} 	// VEX.256.66.0F.WIG DB /r
vpor_ymm_ymm_ymm :: proc(
	buffer: ^ByteBuffer,
	dst: YMMRegister,
	src1: YMMRegister,
	src2: YMMRegister,
) {_encode_vex_op(buffer, 1, 1, false, true, []u8{0xEB}, dst, src1, src2, nil)} 	// VEX.256.66.0F.WIG EB /r
vpxor_ymm_ymm_ymm :: proc(
	buffer: ^ByteBuffer,
	dst: YMMRegister,
	src1: YMMRegister,
	src2: YMMRegister,
) {_encode_vex_op(buffer, 1, 1, false, true, []u8{0xEF}, dst, src1, src2, nil)} 	// VEX.256.66.0F.WIG EF /r

// --- AVX Misc ---
vpternlogd_ymm_ymm_ymm_imm8 :: proc(
	buffer: ^ByteBuffer,
	dst: YMMRegister,
	src1: YMMRegister,
	src2: YMMRegister,
	imm: u8,
) {_encode_vex_op(buffer, 1, 3, false, true, []u8{0x25}, dst, src1, src2, imm)} 	// VEX.256.66.0F3A.W0 25 /r ib
vextracti128_xmm_ymm_imm8 :: proc(
	buffer: ^ByteBuffer,
	dst: XMMRegister,
	src: YMMRegister,
	imm: u8,
) {_encode_vex_op(buffer, 1, 3, false, false, []u8{0x39}, src, src, dst, imm)} 	// VEX.256.66.0F3A.W0 39 /r ib (dst=rm, src=reg)

// --- SSE2 Integer ---
pavgb_xmm_xmm :: proc(buffer: ^ByteBuffer, dst: XMMRegister, src: XMMRegister) {_encode_sse_op(
		buffer,
		0x66,
		false,
		[]u8{0x0F, 0xE0},
		dst,
		src,
		nil,
	)} // 66 0F E0 /r
pavgb_ymm_ymm :: proc(
	buffer: ^ByteBuffer,
	dst: YMMRegister,
	src1: YMMRegister,
	src2: YMMRegister,
) {_encode_vex_op(buffer, 1, 1, false, true, []u8{0xE0}, dst, src1, src2, nil)} 	// VEX.256.66.0F.WIG E0 /r
pmaddwd_xmm_xmm :: proc(buffer: ^ByteBuffer, dst: XMMRegister, src: XMMRegister) {_encode_sse_op(
		buffer,
		0x66,
		false,
		[]u8{0x0F, 0xF5},
		dst,
		src,
		nil,
	)} // 66 0F F5 /r
pmulhuw_xmm_xmm :: proc(buffer: ^ByteBuffer, dst: XMMRegister, src: XMMRegister) {_encode_sse_op(
		buffer,
		0x66,
		false,
		[]u8{0x0F, 0xE4},
		dst,
		src,
		nil,
	)} // 66 0F E4 /r

// --- AVX-512 Arithmetic (ZMM) ---
vaddpd_zmm_zmm_zmm :: proc(
	buffer: ^ByteBuffer,
	dst: ZMMRegister,
	src1: ZMMRegister,
	src2: ZMMRegister,
) {_encode_evex_op(buffer, 1, 1, true, 2, []u8{0x58}, .K0, false, dst, src1, src2, false, nil)} 	// EVEX.512.66.0F.W1 58 /r
vsubpd_zmm_zmm_zmm :: proc(
	buffer: ^ByteBuffer,
	dst: ZMMRegister,
	src1: ZMMRegister,
	src2: ZMMRegister,
) {_encode_evex_op(buffer, 1, 1, true, 2, []u8{0x5C}, .K0, false, dst, src1, src2, false, nil)} 	// EVEX.512.66.0F.W1 5C /r
vmulpd_zmm_zmm_zmm :: proc(
	buffer: ^ByteBuffer,
	dst: ZMMRegister,
	src1: ZMMRegister,
	src2: ZMMRegister,
) {_encode_evex_op(buffer, 1, 1, true, 2, []u8{0x59}, .K0, false, dst, src1, src2, false, nil)} 	// EVEX.512.66.0F.W1 59 /r
vdivpd_zmm_zmm_zmm :: proc(
	buffer: ^ByteBuffer,
	dst: ZMMRegister,
	src1: ZMMRegister,
	src2: ZMMRegister,
) {_encode_evex_op(buffer, 1, 1, true, 2, []u8{0x5E}, .K0, false, dst, src1, src2, false, nil)} 	// EVEX.512.66.0F.W1 5E /r

// --- AVX-512 Moves (ZMM) ---
// vmovdqa32, vmovdqa64, vmovdqu32, vmovdqu64, vmovaps, vmovapd for ZMM need _encode_evex_op
vmovdqa32_zmm_zmm :: proc(
	buffer: ^ByteBuffer,
	dst: ZMMRegister,
	src: ZMMRegister,
) {_encode_evex_op(buffer, 1, 1, false, 2, []u8{0x6F}, .K0, false, dst, dst, src, false, nil)} 	// EVEX.512.66.0F.W0 6F /r
vmovdqa64_zmm_zmm :: proc(
	buffer: ^ByteBuffer,
	dst: ZMMRegister,
	src: ZMMRegister,
) {_encode_evex_op(buffer, 1, 1, true, 2, []u8{0x6F}, .K0, false, dst, dst, src, false, nil)} 	// EVEX.512.66.0F.W1 6F /r
vmovdqu32_zmm_zmm :: proc(
	buffer: ^ByteBuffer,
	dst: ZMMRegister,
	src: ZMMRegister,
) {_encode_evex_op(buffer, 2, 1, false, 2, []u8{0x6F}, .K0, false, dst, dst, src, false, nil)} 	// EVEX.512.F3.0F.W0 6F /r
vmovdqu64_zmm_zmm :: proc(
	buffer: ^ByteBuffer,
	dst: ZMMRegister,
	src: ZMMRegister,
) {_encode_evex_op(buffer, 2, 1, true, 2, []u8{0x6F}, .K0, false, dst, dst, src, false, nil)} 	// EVEX.512.F3.0F.W1 6F /r
vmovaps_zmm_zmm :: proc(buffer: ^ByteBuffer, dst: ZMMRegister, src: ZMMRegister) {_encode_evex_op(
		buffer,
		0,
		1,
		false,
		2,
		[]u8{0x28},
		.K0,
		false,
		dst,
		dst,
		src,
		false,
		nil,
	)} // EVEX.512.0F.W0 28 /r
vmovapd_zmm_zmm :: proc(buffer: ^ByteBuffer, dst: ZMMRegister, src: ZMMRegister) {_encode_evex_op(
		buffer,
		1,
		1,
		true,
		2,
		[]u8{0x28},
		.K0,
		false,
		dst,
		dst,
		src,
		false,
		nil,
	)} // EVEX.512.66.0F.W1 28 /r
// Add memory variants

// --- AVX-512 Mask Register Ops ---
// Helper for K-reg ops (VEX encoded)
@(private)
_encode_kreg_op :: proc(
	buffer: ^ByteBuffer,
	pp: u8,
	w: bool,
	opcode: u8,
	dst: MaskRegister,
	src1: MaskRegister,
	src2: MaskRegister,
) {
	// VEX.L0.{pp}.0F[3A].W{w}
	m: u8 = (opcode >= 0x40 && opcode < 0x50) ? 3 : 1 // 0F vs 0F3A map
	vex := _encode_vex3(
		u8(dst) & 0x8 != 0,
		false,
		u8(src2) & 0x8 != 0,
		m,
		w,
		u8(src1) & 0xF,
		false,
		pp,
	)
	_write_bytes(buffer, vex[:])
	_write_byte(buffer, opcode)
	_write_byte(buffer, encode_modrm(3, u8(dst) & 7, u8(src2) & 7))
}
// Note: Original kmovq_k_k seems incorrect based on docs, using kmovw instead. Revisit if qword move needed.
kmovw_k_k :: proc(buffer: ^ByteBuffer, dst: MaskRegister, src: MaskRegister) {_encode_kreg_op(
		buffer,
		2,
		false,
		0x90,
		dst,
		src,
		src,
	)} // VEX.L0.F3.0F.W0 90 /r (src1=vvvv ignored)
kmovw_k_r32 :: proc(buffer: ^ByteBuffer, dst: MaskRegister, src: Register32) {
	// VEX.L0.F3.0F.W0 93 /r
	src_b, src_low := _get_gpr_rm_encoding(src)
	vex := _encode_vex3(u8(dst) & 8 != 0, false, src_b, 1, false, 0xF, false, 2) // vvvv=1111
	_write_bytes(buffer, vex[:])
	_write_bytes(buffer, []u8{0x0F, 0x93})
	_write_byte(buffer, encode_modrm(3, u8(dst) & 7, src_low))
}
kmovw_r32_k :: proc(buffer: ^ByteBuffer, dst: Register32, src: MaskRegister) {
	// VEX.L0.F3.0F.W0 92 /r
	dst_b, dst_low := _get_gpr_rm_encoding(dst)
	vex := _encode_vex3(u8(src) & 8 != 0, false, dst_b, 1, false, 0xF, false, 2) // vvvv=1111
	_write_bytes(buffer, vex[:])
	_write_bytes(buffer, []u8{0x0F, 0x92})
	_write_byte(buffer, encode_modrm(3, u8(src) & 7, dst_low))
}
kmovw_k_m16 :: proc(buffer: ^ByteBuffer, dst: MaskRegister, mem: MemoryAddress) {
	// VEX.L0.F3.0F.W0 90 /r
	vex := _encode_vex3(u8(dst) & 8 != 0, false, false, 1, false, 0xF, false, 2) // vvvv=1111, assume no X/B from mem for VEX byte calculation initially
	vex_start_index := buffer.len
	_write_bytes(buffer, vex[:])
	_write_bytes(buffer, []u8{0x0F, 0x90})
	mem_x, mem_b := _encode_mem_modrm_sib_disp(buffer, mem, u8(dst) & 7)
	vex_b1 := &buffer.data[vex_start_index + 1]
	if mem_x do vex_b1^ &~= (1 << 6) // Invert to set ~X
	if mem_b do vex_b1^ &~= (1 << 5) // Invert to set ~B
}
kmovw_m16_k :: proc(buffer: ^ByteBuffer, mem: MemoryAddress, src: MaskRegister) {
	// VEX.L0.F3.0F.W0 91 /r
	vex := _encode_vex3(u8(src) & 8 != 0, false, false, 1, false, 0xF, false, 2) // vvvv=1111
	vex_start_index := buffer.len
	_write_bytes(buffer, vex[:])
	_write_bytes(buffer, []u8{0x0F, 0x91})
	mem_x, mem_b := _encode_mem_modrm_sib_disp(buffer, mem, u8(src) & 7)
	vex_b1 := &buffer.data[vex_start_index + 1]
	if mem_x do vex_b1^ &~= (1 << 6) // Invert to set ~X
	if mem_b do vex_b1^ &~= (1 << 5) // Invert to set ~B
}

korw :: proc(
	buffer: ^ByteBuffer,
	dst: MaskRegister,
	src1: MaskRegister,
	src2: MaskRegister,
) {_encode_kreg_op(buffer, 1, false, 0x45, dst, src1, src2)} 	// VEX.L0.66.0F3A.W0 45 /r
kandw :: proc(
	buffer: ^ByteBuffer,
	dst: MaskRegister,
	src1: MaskRegister,
	src2: MaskRegister,
) {_encode_kreg_op(buffer, 1, false, 0x41, dst, src1, src2)} 	// VEX.L0.66.0F3A.W0 41 /r
kxorw :: proc(
	buffer: ^ByteBuffer,
	dst: MaskRegister,
	src1: MaskRegister,
	src2: MaskRegister,
) {_encode_kreg_op(buffer, 1, false, 0x47, dst, src1, src2)} 	// VEX.L0.66.0F3A.W0 47 /r
knotw :: proc(buffer: ^ByteBuffer, dst: MaskRegister, src: MaskRegister) {_encode_kreg_op(
		buffer,
		3,
		false,
		0x44,
		dst,
		src,
		src,
	)} // VEX.L0.F2.0F3A.W0 44 /r (src1=vvvv ignored)

// --- AESNI ---
aesenc :: proc(buffer: ^ByteBuffer, dst: XMMRegister, src: XMMRegister) {_encode_sse_op(
		buffer,
		0x66,
		false,
		[]u8{0x0F, 0x38, 0xDC},
		dst,
		src,
		nil,
	)} // 66 0F 38 DC /r
aesdec :: proc(buffer: ^ByteBuffer, dst: XMMRegister, src: XMMRegister) {_encode_sse_op(
		buffer,
		0x66,
		false,
		[]u8{0x0F, 0x38, 0xDE},
		dst,
		src,
		nil,
	)} // 66 0F 38 DE /r

// --- PCLMULQDQ ---
pclmulqdq :: proc(
	buffer: ^ByteBuffer,
	dst: XMMRegister,
	src: XMMRegister,
	imm: u8,
) {_encode_sse_op(buffer, 0x66, false, []u8{0x0F, 0x3A, 0x44}, dst, src, imm)} 	// 66 0F 3A 44 /r ib

// --- CRC32 ---
crc32_r64_r64 :: proc(buffer: ^ByteBuffer, dst: Register64, src: Register64) {_encode_sse_op(
		buffer,
		0xF2,
		true,
		[]u8{0x0F, 0x38, 0xF1},
		dst,
		src,
		nil,
	)} // F2 REX.W 0F 38 F1 /r
// Add other sizes if needed

// --- Scatter/Gather (Complex - Placeholders/Simplified) ---
// Need specific _encode_vsib_modrm_sib_disp helper
@(private)
_encode_vsib_modrm_sib_disp :: proc(buffer: ^ByteBuffer, addr: AddressComponents, reg_field: u8) {
	// Simplified - Assumes index is YMM/ZMM, base is GPR64, Mod=00, RM=100
	// Does not handle REX/VEX/EVEX X'/B' bits correctly yet.
	fmt.eprintf("Warning: VSIB encoding is simplified and likely incorrect.\n")
	idx_low := u8(0)
	#partial switch idx in addr.index.? {
	case XMMRegister, YMMRegister, ZMMRegister:
		idx_low = u8(idx) & 7
	}
	base_low := u8(addr.base.?) & 7
	scale_bits: u8 = 0
	switch addr.scale != nil ? addr.scale.(u8) : 1 {
	case 1:
		scale_bits = 0;case 2:
		scale_bits = 1;case 4:
		scale_bits = 2;case 8:
		scale_bits = 3
	}
	disp := addr.displacement != nil ? addr.displacement.(i32) : 0

	_write_byte(buffer, encode_modrm(0, reg_field & 7, 4)) // Mod=00, RM=100 (SIB)
	_write_byte(buffer, encode_sib(scale_bits, idx_low, base_low))
	_write_imm32(buffer, u32(disp)) // Always disp32 for VSIB with Mod=00
}

vgatherdps_xmm_vsib :: proc(
	buffer: ^ByteBuffer,
	dst: XMMRegister,
	index: XMMRegister,
	base: Register64,
	scale: u8,
	mask: XMMRegister,
) {
	// VEX.128.66.0F38.W0 92 /r VSIB
	// mask is vvvv
	// Simplified VEX encoding - does not handle X/B bits correctly for VSIB
	vex := _encode_vex3(u8(dst) & 8 != 0, false, false, 2, false, u8(mask) & 0xF, false, 1)
	_write_bytes(buffer, vex[:])
	_write_bytes(buffer, []u8{0x92})
	addr := AddressComponents {
		base  = base,
		index = index,
		scale = scale,
	}
	_encode_vsib_modrm_sib_disp(buffer, addr, u8(dst) & 7)
}

vscatterdps_vsib_xmm :: proc(
	buffer: ^ByteBuffer,
	index: XMMRegister,
	base: Register64,
	scale: u8,
	src: XMMRegister,
	mask: MaskRegister,
) {
	// EVEX.128.66.0F38.W0 A2 /r VSIB {k}
	// Simplified EVEX encoding
	fmt.eprintf("Warning: VSCATTERDPS encoding is simplified and likely incorrect.\n")
	evex := _encode_evex(
		false,
		false,
		false,
		false,
		2,
		false,
		0xF,
		1,
		false,
		0,
		false,
		false,
		u8(mask),
	)
	_write_bytes(buffer, evex[:])
	_write_bytes(buffer, []u8{0xA2})
	addr := AddressComponents {
		base  = base,
		index = index,
		scale = scale,
	}
	_encode_vsib_modrm_sib_disp(buffer, addr, u8(src) & 7) // src is technically not in reg field here
}
// Add other scatter/gather instructions similarly (they are complex)
// vpscatterdd, vpscatterdq, vpscatterqd, vpcompressd, vpcompressq ...


// ==================================
// STRING OPERATIONS
// ==================================
// Note: Use REP/REPE/REPNE prefixes separately if needed.

movs_m8_m8 :: proc(buffer: ^ByteBuffer) {_write_byte(buffer, 0xA4)}
movs_m16_m16 :: proc(buffer: ^ByteBuffer) {_write_bytes(buffer, []u8{0x66, 0xA5})}
movs_m32_m32 :: proc(buffer: ^ByteBuffer) {_write_byte(buffer, 0xA5)}
movs_m64_m64 :: proc(buffer: ^ByteBuffer) {_write_bytes(buffer, []u8{0x48, 0xA5})}

stos_m8 :: proc(buffer: ^ByteBuffer) {_write_byte(buffer, 0xAA)}
stos_m16 :: proc(buffer: ^ByteBuffer) {_write_bytes(buffer, []u8{0x66, 0xAB})}
stos_m32 :: proc(buffer: ^ByteBuffer) {_write_byte(buffer, 0xAB)}
stos_m64 :: proc(buffer: ^ByteBuffer) {_write_bytes(buffer, []u8{0x48, 0xAB})}

scas_m8 :: proc(buffer: ^ByteBuffer) {_write_byte(buffer, 0xAE)}
scas_m16 :: proc(buffer: ^ByteBuffer) {_write_bytes(buffer, []u8{0x66, 0xAF})}
scas_m32 :: proc(buffer: ^ByteBuffer) {_write_byte(buffer, 0xAF)}
scas_m64 :: proc(buffer: ^ByteBuffer) {_write_bytes(buffer, []u8{0x48, 0xAF})}

cmps_m8_m8 :: proc(buffer: ^ByteBuffer) {_write_byte(buffer, 0xA6)}
cmps_m16_m16 :: proc(buffer: ^ByteBuffer) {_write_bytes(buffer, []u8{0x66, 0xA7})}
cmps_m32_m32 :: proc(buffer: ^ByteBuffer) {_write_byte(buffer, 0xA7)}
cmps_m64_m64 :: proc(buffer: ^ByteBuffer) {_write_bytes(buffer, []u8{0x48, 0xA7})}

lods_m8 :: proc(buffer: ^ByteBuffer) {_write_byte(buffer, 0xAC)}
lods_m16 :: proc(buffer: ^ByteBuffer) {_write_bytes(buffer, []u8{0x66, 0xAD})}
lods_m32 :: proc(buffer: ^ByteBuffer) {_write_byte(buffer, 0xAD)}
lods_m64 :: proc(buffer: ^ByteBuffer) {_write_bytes(buffer, []u8{0x48, 0xAD})}

// Common REP combinations (consider adding REPE/REPNE)
rep_movsb :: proc(buffer: ^ByteBuffer) {_write_bytes(buffer, []u8{0xF3, 0xA4})}
rep_movsw :: proc(buffer: ^ByteBuffer) {_write_bytes(buffer, []u8{0xF3, 0x66, 0xA5})}
rep_movsd :: proc(buffer: ^ByteBuffer) {_write_bytes(buffer, []u8{0xF3, 0xA5})}
rep_movsq :: proc(buffer: ^ByteBuffer) {_write_bytes(buffer, []u8{0xF3, 0x48, 0xA5})}
rep_stosb :: proc(buffer: ^ByteBuffer) {_write_bytes(buffer, []u8{0xF3, 0xAA})}
// rep_stosw, rep_stosd, rep_stosq...
repe_cmpsb :: proc(buffer: ^ByteBuffer) {_write_bytes(buffer, []u8{0xF3, 0xA6})} 	// REPE uses F3
repne_scasb :: proc(buffer: ^ByteBuffer) {_write_bytes(buffer, []u8{0xF2, 0xAE})} 	// REPNE uses F2

// ==================================
// SYSTEM INSTRUCTIONS
// ==================================

syscall :: proc(buffer: ^ByteBuffer) {_write_bytes(buffer, []u8{0x0F, 0x05})}
sysret :: proc(buffer: ^ByteBuffer) {_write_bytes(buffer, []u8{0x48, 0x0F, 0x07})} 	// Assumes 64-bit mode return

int_imm8 :: proc(buffer: ^ByteBuffer, imm: u8) {_write_bytes(buffer, []u8{0xCD, imm})}
int3 :: proc(buffer: ^ByteBuffer) {_write_byte(buffer, 0xCC)}
iretq :: proc(buffer: ^ByteBuffer) {_write_bytes(buffer, []u8{0x48, 0xCF})} 	// IRET in 64-bit mode (operand size promoted)
iret :: proc(buffer: ^ByteBuffer) {iretq(buffer)} 	// Alias

cpuid :: proc(buffer: ^ByteBuffer) {_write_bytes(buffer, []u8{0x0F, 0xA2})}
rdtsc :: proc(buffer: ^ByteBuffer) {_write_bytes(buffer, []u8{0x0F, 0x31})}
rdtscp :: proc(buffer: ^ByteBuffer) {_write_bytes(buffer, []u8{0x0F, 0x01, 0xF9})}
rdmsr :: proc(buffer: ^ByteBuffer) {_write_bytes(buffer, []u8{0x0F, 0x32})}
wrmsr :: proc(buffer: ^ByteBuffer) {_write_bytes(buffer, []u8{0x0F, 0x30})}
rdpmc :: proc(buffer: ^ByteBuffer) {_write_bytes(buffer, []u8{0x0F, 0x33})}
hlt :: proc(buffer: ^ByteBuffer) {_write_byte(buffer, 0xF4)}
swapgs :: proc(buffer: ^ByteBuffer) {_write_bytes(buffer, []u8{0x0F, 0x01, 0xF8})}
wrpkru :: proc(buffer: ^ByteBuffer) {_write_bytes(buffer, []u8{0x0F, 0x01, 0xEF})}
rdpkru :: proc(buffer: ^ByteBuffer) {_write_bytes(buffer, []u8{0x0F, 0x01, 0xEE})}
clac :: proc(buffer: ^ByteBuffer) {_write_bytes(buffer, []u8{0x0F, 0x01, 0xCA})}
stac :: proc(buffer: ^ByteBuffer) {_write_bytes(buffer, []u8{0x0F, 0x01, 0xCB})}
ud2 :: proc(buffer: ^ByteBuffer) {_write_bytes(buffer, []u8{0x0F, 0x0B})}

// ==================================
// VIRTUALIZATION INSTRUCTIONS (VMX)
// ==================================

vmcall :: proc(buffer: ^ByteBuffer) {_write_bytes(buffer, []u8{0x0F, 0x01, 0xC1})}
vmlaunch :: proc(buffer: ^ByteBuffer) {_write_bytes(buffer, []u8{0x0F, 0x01, 0xC2})}
vmresume :: proc(buffer: ^ByteBuffer) {_write_bytes(buffer, []u8{0x0F, 0x01, 0xC3})}
vmxoff :: proc(buffer: ^ByteBuffer) {_write_bytes(buffer, []u8{0x0F, 0x01, 0xC4})}
// Other VMX instructions (VMPTRLD, VMCLEAR, VMREAD, VMWRITE, etc.) are more complex

// ==================================
// TRANSACTIONAL MEMORY INSTRUCTIONS (TSX)
// ==================================

xbegin :: proc(buffer: ^ByteBuffer, offset: i32) {_write_bytes(buffer, []u8{0xC7, 0xF8})
	_write_imm32(buffer, u32(offset))} // Note: 2/4 byte offset depending on prefix
xend :: proc(buffer: ^ByteBuffer) {_write_bytes(buffer, []u8{0x0F, 0x01, 0xD5})}
xabort :: proc(buffer: ^ByteBuffer, imm: u8) {_write_bytes(buffer, []u8{0xC6, 0xF8, imm})}
xtest :: proc(buffer: ^ByteBuffer) {_write_bytes(buffer, []u8{0x0F, 0x01, 0xD6})}

// ==================================
// HARDWARE SECURITY INSTRUCTIONS (SGX, RDRAND, RDSEED)
// ==================================

rdrand_r64 :: proc(buffer: ^ByteBuffer, reg: Register64) {_encode_unary_rm(
		buffer,
		.QWord,
		0x0F,
		6,
		reg,
	)} // Reuse unary helper with 0F prefix - hacky but works for structure
rdrand_r32 :: proc(buffer: ^ByteBuffer, reg: Register32) {_encode_unary_rm(
		buffer,
		.DWord,
		0x0F,
		6,
		reg,
	)}
rdrand_r16 :: proc(buffer: ^ByteBuffer, reg: Register16) {_encode_unary_rm(
		buffer,
		.Word,
		0x0F,
		6,
		reg,
	)}
rdseed_r64 :: proc(buffer: ^ByteBuffer, reg: Register64) {_encode_unary_rm(
		buffer,
		.QWord,
		0x0F,
		7,
		reg,
	)}
rdseed_r32 :: proc(buffer: ^ByteBuffer, reg: Register32) {_encode_unary_rm(
		buffer,
		.DWord,
		0x0F,
		7,
		reg,
	)}
rdseed_r16 :: proc(buffer: ^ByteBuffer, reg: Register16) {_encode_unary_rm(
		buffer,
		.Word,
		0x0F,
		7,
		reg,
	)}
// Need to fix _encode_unary_rm to handle 0F opcode prefix correctly if used generally
// Actual RDRAND opcode is 0F C7 /6, RDSEED is 0F C7 /7
// Corrected implementation:
rdrand :: proc(
	buffer: ^ByteBuffer,
	reg: $T,
) where T == Register64 ||
	T == Register32 ||
	T == Register16 {
	op_size := OperandSize.DWord
	if T == Register64 do op_size = .QWord
	if T == Register16 do op_size = .Word
	_encode_unary_rm(buffer, op_size, 0xC7, 6, reg) // Opcode C7, ext 6
	// Manually insert 0F before C7
	opcode_idx := buffer.len - 1 - size_of(T) // Approx index of C7
	if opcode_idx > 0 && buffer.data[opcode_idx] == 0xC7 {
		required_size := buffer.len + 1
		if required_size > buffer.cap {grow(buffer, required_size)}
		mem.move_ptr(
			raw_data(buffer.data[opcode_idx + 1:]),
			raw_data(buffer.data[opcode_idx:]),
			buffer.len - opcode_idx,
		)
		buffer.data[opcode_idx] = 0x0F
		buffer.len += 1
	} else {fmt.eprintf("Warning: RDRAND 0F insertion failed.\n")}
}
rdseed :: proc(
	buffer: ^ByteBuffer,
	reg: $T,
) where T == Register64 ||
	T == Register32 ||
	T == Register16 {
	op_size := OperandSize.DWord
	if T == Register64 do op_size = .QWord
	if T == Register16 do op_size = .Word
	_encode_unary_rm(buffer, op_size, 0xC7, 7, reg) // Opcode C7, ext 7
	// Manually insert 0F before C7 (similar logic as rdrand)
	opcode_idx := buffer.len - 1 - size_of(T)
	if opcode_idx > 0 && buffer.data[opcode_idx] == 0xC7 {
		required_size := buffer.len + 1
		if required_size > buffer.cap {grow(buffer, required_size)}
		mem.move_ptr(
			raw_data(buffer.data[opcode_idx + 1:]),
			raw_data(buffer.data[opcode_idx:]),
			buffer.len - opcode_idx,
		)
		buffer.data[opcode_idx] = 0x0F
		buffer.len += 1
	} else {fmt.eprintf("Warning: RDSEED 0F insertion failed.\n")}
}

// SGX instructions (ENCLS, ENCLU) are complex and not included here.

// ==================================
// MEMORY MANAGEMENT INSTRUCTIONS
// ==================================

// --- Prefetch ---
// 0F 18 /<hint>
prefetchnta :: proc(buffer: ^ByteBuffer, mem: MemoryAddress) {_encode_unary_rm(
		buffer,
		.Byte,
		0x18,
		0,
		mem,
	)
	buffer.data[buffer.len - 2 - 4 - 1] = 0x0F} // Insert 0F - HACKY index
prefetcht0 :: proc(buffer: ^ByteBuffer, mem: MemoryAddress) {_encode_unary_rm(
		buffer,
		.Byte,
		0x18,
		1,
		mem,
	)
	buffer.data[buffer.len - 2 - 4 - 1] = 0x0F}
prefetcht1 :: proc(buffer: ^ByteBuffer, mem: MemoryAddress) {_encode_unary_rm(
		buffer,
		.Byte,
		0x18,
		2,
		mem,
	)
	buffer.data[buffer.len - 2 - 4 - 1] = 0x0F}
prefetcht2 :: proc(buffer: ^ByteBuffer, mem: MemoryAddress) {_encode_unary_rm(
		buffer,
		.Byte,
		0x18,
		3,
		mem,
	)
	buffer.data[buffer.len - 2 - 4 - 1] = 0x0F}

// --- Cache Control ---
// 0F AE /<ext>
clflush :: proc(buffer: ^ByteBuffer, mem: MemoryAddress) {_encode_unary_rm(
		buffer,
		.Byte,
		0xAE,
		7,
		mem,
	)
	buffer.data[buffer.len - 2 - 4 - 1] = 0x0F} // HACKY index
clflushopt :: proc(buffer: ^ByteBuffer, mem: MemoryAddress) {_write_byte(buffer, 0x66)
	_encode_unary_rm(buffer, .Byte, 0xAE, 7, mem)
	buffer.data[buffer.len - 3 - 4 - 1] = 0x0F}
clwb :: proc(buffer: ^ByteBuffer, mem: MemoryAddress) {_write_byte(buffer, 0x66)
	_encode_unary_rm(buffer, .Byte, 0xAE, 6, mem)
	buffer.data[buffer.len - 3 - 4 - 1] = 0x0F}

// --- Monitor/Mwait ---
monitor :: proc(buffer: ^ByteBuffer) {_write_bytes(buffer, []u8{0x0F, 0x01, 0xC8})}
mwait :: proc(buffer: ^ByteBuffer) {_write_bytes(buffer, []u8{0x0F, 0x01, 0xC9})}

// --- Memory Barriers ---
mfence :: proc(buffer: ^ByteBuffer) {_write_bytes(buffer, []u8{0x0F, 0xAE, 0xF0})}
lfence :: proc(buffer: ^ByteBuffer) {_write_bytes(buffer, []u8{0x0F, 0xAE, 0xE8})}
sfence :: proc(buffer: ^ByteBuffer) {_write_bytes(buffer, []u8{0x0F, 0xAE, 0xF8})}
