package x64_assembler

import "core:fmt"
import "core:testing"

// ===== REGISTER DEFINITIONS =====
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

XMMRegister :: enum u8 {
	XMM0 = 0,
	XMM1,
	XMM2,
	XMM3,
	XMM4,
	XMM5,
	XMM6,
	XMM7,
	XMM8,
	XMM9,
	XMM10,
	XMM11,
	XMM12,
	XMM13,
	XMM14,
	XMM15,
	XMM16,
	XMM17,
	XMM18,
	XMM19,
	XMM20,
	XMM21,
	XMM22,
	XMM23,
	XMM24,
	XMM25,
	XMM26,
	XMM27,
	XMM28,
	XMM29,
	XMM30,
	XMM31,
}

x87Register :: enum u8 {
	ST0 = 0,
	ST1,
	ST2,
	ST3,
	ST4,
	ST5,
	ST6,
	ST7,
}

// ===== DATA MOVEMENT INSTRUCTIONS =====
// --- General Purpose Register Movement ---
mov_r64_imm64 :: proc(reg: Register64, imm: u64) -> [10]u8 {
	// REX.W + B8+rd io (48 B8+ rd io)
	return [10]u8 {
		0x48 + (u8(reg) >> 3), // REX.W + extension bit for register
		0xB8 + (u8(reg) & 0x7), // Opcode + register

		// Store immediate value (little-endian)
		u8(imm & 0xFF),
		u8((imm >> 8) & 0xFF),
		u8((imm >> 16) & 0xFF),
		u8((imm >> 24) & 0xFF),
		u8((imm >> 32) & 0xFF),
		u8((imm >> 40) & 0xFF),
		u8((imm >> 48) & 0xFF),
		u8((imm >> 56) & 0xFF),
	}
}

mov_r64_r64 :: proc(dst: Register64, src: Register64) -> [3]u8 {
	// REX.W + 89 /r (48 89 /r)
	return [3]u8 {
		0x48 + ((u8(src) & 0x8) >> 1) + ((u8(dst) & 0x8) >> 3), // REX.W + register extensions
		0x89, // Opcode
		0xC0 + ((u8(src) & 0x7) << 3) + (u8(dst) & 0x7), // ModR/M byte
	}
}

mov_r64_m64 :: proc(dst: Register64, mem_addr: u64) -> [8]u8 {
	// REX.W + 8B /r (48 8B /r)
	return [8]u8 {
		0x48 + ((u8(dst) & 0x8) >> 1), // REX.W + register extension
		0x8B, // Opcode
		0x04 + ((u8(dst) & 0x7) << 3), // ModR/M byte with SIB
		0x25, // SIB byte for absolute addressing

		// Store address (little-endian, 32-bit)
		u8(mem_addr & 0xFF),
		u8((mem_addr >> 8) & 0xFF),
		u8((mem_addr >> 16) & 0xFF),
		u8((mem_addr >> 24) & 0xFF),
	}
}

mov_m64_r64 :: proc(mem_addr: u64, src: Register64) -> [8]u8 {
	// REX.W + 89 /r (48 89 /r)
	return [8]u8 {
		0x48 + ((u8(src) & 0x8) >> 1), // REX.W + register extension
		0x89, // Opcode
		0x04 + ((u8(src) & 0x7) << 3), // ModR/M byte with SIB
		0x25, // SIB byte for absolute addressing

		// Store address (little-endian, 32-bit)
		u8(mem_addr & 0xFF),
		u8((mem_addr >> 8) & 0xFF),
		u8((mem_addr >> 16) & 0xFF),
		u8((mem_addr >> 24) & 0xFF),
	}
}

movabs_r64_imm64 :: proc(reg: Register64, imm: u64) -> [10]u8 {
	// This is the same as mov_r64_imm64 for 64-bit mode
	return mov_r64_imm64(reg, imm)
}

xchg_r64_r64 :: proc(dst: Register64, src: Register64) -> [3]u8 {
	// REX.W + 87 /r (48 87 /r)
	return [3]u8 {
		0x48 + ((u8(src) & 0x8) >> 1) + ((u8(dst) & 0x8) >> 3), // REX.W + register extensions
		0x87, // Opcode
		0xC0 + ((u8(src) & 0x7) << 3) + (u8(dst) & 0x7), // ModR/M byte
	}
}

// --- Sign and Zero Extensions ---
movsx_r64_r32 :: proc(dst: Register64, src: Register64) -> [3]u8 {
	// REX.W + 63 /r (48 63 /r)
	return [3]u8 {
		0x48 + ((u8(dst) & 0x8) >> 1) + ((u8(src) & 0x8) >> 3), // REX.W + register extensions
		0x63, // Opcode
		0xC0 + ((u8(dst) & 0x7) << 3) + (u8(src) & 0x7), // ModR/M byte
	}
}

movzx_r64_r32 :: proc(dst: Register64, src: Register64) -> [3]u8 {
	// No need for movzx for 32-bit to 64-bit in x64, upper bits are zeroed by default
	// But for completeness, we'll encode a 32-bit mov (no REX.W prefix)
	return [3]u8 {
		0x40 + ((u8(dst) & 0x8) >> 1) + ((u8(src) & 0x8) >> 3), // REX prefix (no W bit)
		0x89, // Opcode
		0xC0 + ((u8(src) & 0x7) << 3) + (u8(dst) & 0x7), // ModR/M byte
	}
}

// --- Byte Order Control ---
movbe_r64_m64 :: proc(dst: Register64, mem_addr: u64) -> [10]u8 {
	// REX.W + 0F 38 F0 /r (48 0F 38 F0 /r)
	return [10]u8 {
		0x48 + ((u8(dst) & 0x8) >> 1), // REX.W + register extension
		0x0F, // Two-byte opcode prefix
		0x38, // Three-byte opcode prefix
		0xF0, // Opcode
		0x04 + ((u8(dst) & 0x7) << 3), // ModR/M byte with SIB
		0x25, // SIB byte for absolute addressing

		// Store address (little-endian, 32-bit)
		u8(mem_addr & 0xFF),
		u8((mem_addr >> 8) & 0xFF),
		u8((mem_addr >> 16) & 0xFF),
		u8((mem_addr >> 24) & 0xFF),
	}
}

movbe_m64_r64 :: proc(mem_addr: u64, src: Register64) -> [10]u8 {
	// REX.W + 0F 38 F1 /r (48 0F 38 F1 /r)
	return [10]u8 {
		0x48 + ((u8(src) & 0x8) >> 1), // REX.W + register extension
		0x0F, // Two-byte opcode prefix
		0x38, // Three-byte opcode prefix
		0xF1, // Opcode
		0x04 + ((u8(src) & 0x7) << 3), // ModR/M byte with SIB
		0x25, // SIB byte for absolute addressing

		// Store address (little-endian, 32-bit)
		u8(mem_addr & 0xFF),
		u8((mem_addr >> 8) & 0xFF),
		u8((mem_addr >> 16) & 0xFF),
		u8((mem_addr >> 24) & 0xFF),
	}
}

bswap_r64 :: proc(reg: Register64) -> [3]u8 { 	// Byte swap
	// REX.W + 0F C8+rd (48 0F C8+rd)
	return [3]u8 {
		0x48 + ((u8(reg) & 0x8) >> 3), // REX.W + register extension
		0x0F, // Two-byte opcode prefix
		0xC8 + (u8(reg) & 0x7), // Opcode + register
	}
}

// --- Special Registers ---
mov_cr_r64 :: proc(cr: u8, reg: Register64) -> [3]u8 {
	// 0F 22 /r (0F 22 /r)
	return [3]u8 {
		0x0F, // Two-byte opcode prefix
		0x22, // Opcode
		0xC0 + ((cr & 0x7) << 3) + (u8(reg) & 0x7), // ModR/M byte
	}
}

mov_r64_cr :: proc(reg: Register64, cr: u8) -> [3]u8 {
	// 0F 20 /r (0F 20 /r)
	return [3]u8 {
		0x0F, // Two-byte opcode prefix
		0x20, // Opcode
		0xC0 + ((cr & 0x7) << 3) + (u8(reg) & 0x7), // ModR/M byte
	}
}

mov_cr0_r64 :: proc(reg: Register64) -> [3]u8 {
	return mov_cr_r64(0, reg)
}

mov_cr2_r64 :: proc(reg: Register64) -> [3]u8 {
	return mov_cr_r64(2, reg)
}

mov_cr3_r64 :: proc(reg: Register64) -> [3]u8 {
	return mov_cr_r64(3, reg)
}

mov_cr4_r64 :: proc(reg: Register64) -> [3]u8 {
	return mov_cr_r64(4, reg)
}

// --- Debug Registers ---
mov_dr0_r64 :: proc(reg: Register64) -> [3]u8 {
	// 0F 23 /r (0F 23 /r)
	return [3]u8 {
		0x0F, // Two-byte opcode prefix
		0x23, // Opcode
		0xC0 + ((0 & 0x7) << 3) + (u8(reg) & 0x7), // ModR/M byte
	}
}

mov_dr1_r64 :: proc(reg: Register64) -> [3]u8 {
	return [3]u8 {
		0x0F,
		0x23,
		0xC8 + (u8(reg) & 0x7), // Base 0xC8 = 0xC0 + (1 << 3)
	}
}

mov_dr2_r64 :: proc(reg: Register64) -> [3]u8 {
	return [3]u8 {
		0x0F,
		0x23,
		0xD0 + (u8(reg) & 0x7), // Base 0xD0 = 0xC0 + (2 << 3)
	}
}

mov_dr3_r64 :: proc(reg: Register64) -> [3]u8 {
	return [3]u8 {
		0x0F,
		0x23,
		0xD8 + (u8(reg) & 0x7), // Base 0xD8 = 0xC0 + (3 << 3)
	}
}

mov_dr6_r64 :: proc(reg: Register64) -> [3]u8 {
	return [3]u8 {
		0x0F,
		0x23,
		0xF0 + (u8(reg) & 0x7), // Base 0xF0 = 0xC0 + (6 << 3)
	}
}

mov_dr7_r64 :: proc(reg: Register64) -> [3]u8 {
	return [3]u8 {
		0x0F,
		0x23,
		0xF8 + (u8(reg) & 0x7), // Base 0xF8 = 0xC0 + (7 << 3)
	}
}

// --- Address Manipulation ---
lea_r64_m64 :: proc(dst: Register64, mem_addr: u64) -> [8]u8 {
	// REX.W + 8D /r (48 8D /r)
	return [8]u8 {
		0x48 + ((u8(dst) & 0x8) >> 1), // REX.W + register extension
		0x8D, // Opcode
		0x04 + ((u8(dst) & 0x7) << 3), // ModR/M byte with SIB
		0x25, // SIB byte for absolute addressing

		// Store address (little-endian, 32-bit)
		u8(mem_addr & 0xFF),
		u8((mem_addr >> 8) & 0xFF),
		u8((mem_addr >> 16) & 0xFF),
		u8((mem_addr >> 24) & 0xFF),
	}
}

lea_r64_m :: proc(dst: Register64, mem: u64) -> [8]u8 {
	// This is a duplicate of lea_r64_m64 with a different name
	return lea_r64_m64(dst, mem)
}

// ===== ARITHMETIC INSTRUCTIONS =====
// --- Basic Arithmetic ---
add_r64_imm32 :: proc(reg: Register64, imm: u32) -> [7]u8 {
	// REX.W + 81 /0 id (48 81 /0 id)
	return [7]u8 {
		0x48 + ((u8(reg) & 0x8) >> 3), // REX.W + register extension
		0x81, // Opcode
		0xC0 + (u8(reg) & 0x7), // ModR/M byte (/0 = opcode extension 0 for ADD)
		// Immediate (little-endian)
		u8(imm & 0xFF),
		u8((imm >> 8) & 0xFF),
		u8((imm >> 16) & 0xFF),
		u8((imm >> 24) & 0xFF),
	}
}

add_r64_r64 :: proc(dst: Register64, src: Register64) -> [3]u8 {
	// REX.W + 01 /r (48 01 /r)
	return [3]u8 {
		0x48 + ((u8(src) & 0x8) >> 1) + ((u8(dst) & 0x8) >> 3), // REX.W + register extensions
		0x01, // Opcode
		0xC0 + ((u8(src) & 0x7) << 3) + (u8(dst) & 0x7), // ModR/M byte
	}
}

sub_r64_imm32 :: proc(reg: Register64, imm: u32) -> [7]u8 {
	// REX.W + 81 /5 id (48 81 /5 id)
	return [7]u8 {
		0x48 + ((u8(reg) & 0x8) >> 3), // REX.W + register extension
		0x81, // Opcode
		0xE8 + (u8(reg) & 0x7), // ModR/M byte (/5 = opcode extension 5 for SUB)
		// Immediate (little-endian)
		u8(imm & 0xFF),
		u8((imm >> 8) & 0xFF),
		u8((imm >> 16) & 0xFF),
		u8((imm >> 24) & 0xFF),
	}
}

sub_r64_r64 :: proc(dst: Register64, src: Register64) -> [3]u8 {
	// REX.W + 29 /r (48 29 /r)
	return [3]u8 {
		0x48 + ((u8(src) & 0x8) >> 1) + ((u8(dst) & 0x8) >> 3), // REX.W + register extensions
		0x29, // Opcode
		0xC0 + ((u8(src) & 0x7) << 3) + (u8(dst) & 0x7), // ModR/M byte
	}
}

inc_r64 :: proc(reg: Register64) -> [3]u8 {
	// REX.W + FF /0 (48 FF /0)
	return [3]u8 {
		0x48 + ((u8(reg) & 0x8) >> 3), // REX.W + register extension
		0xFF, // Opcode
		0xC0 + (u8(reg) & 0x7), // ModR/M byte (/0 = opcode extension 0 for INC)
	}
}

dec_r64 :: proc(reg: Register64) -> [3]u8 {
	// REX.W + FF /1 (48 FF /1)
	return [3]u8{0x48 + ((u8(reg) & 0x8) >> 3), 0xFF, 0xC8 + (u8(reg) & 0x7)}
}

neg_r64 :: proc(reg: Register64) -> [3]u8 {
	// REX.W + F7 /3 (48 F7 /3)
	return [3]u8{0x48 + ((u8(reg) & 0x8) >> 3), 0xF7, 0xD8 + (u8(reg) & 0x7)}
}

// --- Advanced Arithmetic ---
adc_r64_r64 :: proc(dst: Register64, src: Register64) -> [3]u8 { 	// Add with carry
	// REX.W + 11 /r (48 11 /r)
	return [3]u8 {
		0x48 + ((u8(src) & 0x8) >> 1) + ((u8(dst) & 0x8) >> 3),
		0x11, // Opcode
		0xC0 + ((u8(src) & 0x7) << 3) + (u8(dst) & 0x7), // ModR/M byte
	}
}

sbb_r64_r64 :: proc(dst: Register64, src: Register64) -> [3]u8 { 	// Subtract with borrow
	// REX.W + 19 /r (48 19 /r)
	return [3]u8 {
		0x48 + ((u8(src) & 0x8) >> 1) + ((u8(dst) & 0x8) >> 3),
		0x19, // Opcode
		0xC0 + ((u8(src) & 0x7) << 3) + (u8(dst) & 0x7),
	}
}

xadd_r64_r64 :: proc(dst: Register64, src: Register64) -> [4]u8 { 	// Exchange and add
	// REX.W + 0F C1 /r (48 0F C1 /r)
	return [4]u8 {
		0x48 + ((u8(src) & 0x8) >> 1) + ((u8(dst) & 0x8) >> 3),
		0x0F, // Two-byte opcode prefix
		0xC1, // Opcode
		0xC0 + ((u8(src) & 0x7) << 3) + (u8(dst) & 0x7), // ModR/M byte
	}
}

// --- Multiplication and Division ---
mul_r64 :: proc(reg: Register64) -> [3]u8 { 	// Unsigned multiply
	// REX.W + F7 /4 (48 F7 /4)
	return [3]u8{0x48 + ((u8(reg) & 0x8) >> 3), 0xF7, 0xE0 + (u8(reg) & 0x7)}
}

imul_r64_r64 :: proc(dst: Register64, src: Register64) -> [4]u8 { 	// Signed multiply
	// REX.W + 0F AF /r (48 0F AF /r)
	// Corrected: destination is in the reg field and source in r/m field.
	return [4]u8 {
		0x48 + ((u8(src) & 0x8) >> 1) + ((u8(dst) & 0x8) >> 3),
		0x0F, // Two-byte opcode prefix
		0xAF, // Opcode
		0xC0 + ((u8(dst) & 0x7) << 3) + (u8(src) & 0x7), // ModR/M byte
	}
}

imul_r64_r64_imm32 :: proc(dst: Register64, src: Register64, imm: u32) -> [7]u8 {
	// REX.W + 69 /r id (48 69 /r id)
	// Corrected REX prefix order (same as mov_r64_r64) and immediate encoding.
	return [7]u8 {
		0x48 + ((u8(src) & 0x8) >> 1) + ((u8(dst) & 0x8) >> 3),
		0x69, // Opcode
		0xC0 + ((u8(dst) & 0x7) << 3) + (u8(src) & 0x7),
		u8(imm & 0xFF),
		u8((imm >> 8) & 0xFF),
		u8((imm >> 16) & 0xFF),
		u8((imm >> 24) & 0xFF),
	}
}

imul_r64_imm32 :: proc(reg: Register64, imm: u32) -> [7]u8 {
	// This is the same as imul_r64_r64_imm32 where dst and src are the same
	return imul_r64_r64_imm32(reg, reg, imm)
}

div_r64 :: proc(reg: Register64) -> [3]u8 { 	// Unsigned divide
	// REX.W + F7 /6 (48 F7 /6)
	return [3]u8{0x48 + ((u8(reg) & 0x8) >> 3), 0xF7, 0xF0 + (u8(reg) & 0x7)}
}

idiv_r64 :: proc(reg: Register64) -> [3]u8 { 	// Signed divide
	// REX.W + F7 /7 (48 F7 /7)
	return [3]u8 {
		0x48 + ((u8(reg) & 0x8) >> 3),
		0xF7,
		0xF8 + (u8(reg) & 0x7), // ModR/M byte for signed divide
	}
}

// ===== BITWISE INSTRUCTIONS =====
// --- Basic Bitwise Operations ---
and_r64_r64 :: proc(dst: Register64, src: Register64) {}
or_r64_r64 :: proc(dst: Register64, src: Register64) {}
xor_r64_r64 :: proc(dst: Register64, src: Register64) {}
not_r64 :: proc(reg: Register64) {}

// --- Shifts and Rotates ---
shl_r64_imm8 :: proc(reg: Register64, imm: u8) {
	assert(imm <= 63, "Shift amount must be 0-63")
}
shr_r64_imm8 :: proc(reg: Register64, imm: u8) {
	assert(imm <= 63, "Shift amount must be 0-63")
}
rol_r64_imm8 :: proc(reg: Register64, imm: u8) {
	assert(imm <= 63, "Rotate amount must be 0-63")
}
ror_r64_imm8 :: proc(reg: Register64, imm: u8) {
	assert(imm <= 63, "Rotate amount must be 0-63")
}
shld_r64_r64_imm8 :: proc(dst: Register64, src: Register64, imm: u8) {}
shrd_r64_r64_imm8 :: proc(dst: Register64, src: Register64, imm: u8) {}

// --- Bit Manipulation ---
bt_r64_r64 :: proc(reg: Register64, bit_index: Register64) {} 	// Bit test
bts_r64_r64 :: proc(reg: Register64, bit_index: Register64) {} 	// Bit test and set
btr_r64_r64 :: proc(reg: Register64, bit_index: Register64) {} 	// Bit test and reset
btc_r64_r64 :: proc(reg: Register64, bit_index: Register64) {} 	// Bit test and complement
bsf_r64_r64 :: proc(dst: Register64, src: Register64) {} 	// Bit scan forward
bsr_r64_r64 :: proc(dst: Register64, src: Register64) {} 	// Bit scan reverse
popcnt_r64_r64 :: proc(dst: Register64, src: Register64) {} 	// Population count
lzcnt_r64_r64 :: proc(dst: Register64, src: Register64) {} 	// Leading zero count
tzcnt_r64_r64 :: proc(dst: Register64, src: Register64) {} 	// Trailing zero count
pext_r64_r64_r64 :: proc(dst: Register64, src1: Register64, src2: Register64) {} 	// Parallel bits extract
pdep_r64_r64_r64 :: proc(dst: Register64, src1: Register64, src2: Register64) {} 	// Parallel bits deposit

// ===== COMPARISON INSTRUCTIONS =====
cmp_r64_r64 :: proc(reg1: Register64, reg2: Register64) {}
cmp_r64_imm32 :: proc(reg: Register64, imm: u32) {}
test_r64_r64 :: proc(reg1: Register64, reg2: Register64) {}
test_r64_imm32 :: proc(reg: Register64, imm: u32) {}

// --- Conditional Moves ---
cmove_r64_r64 :: proc(dst: Register64, src: Register64) {} 	// Move if equal
cmovne_r64_r64 :: proc(dst: Register64, src: Register64) {} 	// Move if not equal
cmova_r64_r64 :: proc(dst: Register64, src: Register64) {} 	// Move if above
cmovae_r64_r64 :: proc(dst: Register64, src: Register64) {} 	// Move if above or equal
cmovb_r64_r64 :: proc(dst: Register64, src: Register64) {} 	// Move if below
cmovbe_r64_r64 :: proc(dst: Register64, src: Register64) {} 	// Move if below or equal

// ===== CONTROL FLOW INSTRUCTIONS =====
// --- Unconditional Jumps & Calls ---
jmp_rel32 :: proc(offset: i32) {}
jmp_r64 :: proc(reg: Register64) {}
jmp_m64 :: proc(mem_addr: u64) {}
call_rel32 :: proc(offset: i32) {}
call_r64 :: proc(reg: Register64) {}
call_m64 :: proc(mem_addr: u64) {}
ret :: proc() {}

// --- Conditional Jumps ---
je_rel32 :: proc(offset: i32) {} 	// Jump if equal
jne_rel32 :: proc(offset: i32) {} 	// Jump if not equal
jg_rel32 :: proc(offset: i32) {} 	// Jump if greater
jl_rel32 :: proc(offset: i32) {} 	// Jump if less
jge_rel32 :: proc(offset: i32) {} 	// Jump if greater or equal
jle_rel32 :: proc(offset: i32) {} 	// Jump if less or equal
ja_rel32 :: proc(offset: i32) {} 	// Jump if above
jae_rel32 :: proc(offset: i32) {} 	// Jump if above or equal
jb_rel32 :: proc(offset: i32) {} 	// Jump if below
jbe_rel32 :: proc(offset: i32) {} 	// Jump if below or equal

// --- Loop Control ---
loop_rel8 :: proc(offset: i8) {} 	// Decrement ECX/RCX; jump if not zero
loope_rel8 :: proc(offset: i8) {} 	// Loop while equal
loopne_rel8 :: proc(offset: i8) {} 	// Loop while not equal
jecxz_rel8 :: proc(offset: i8) {} 	// Jump if ECX/RCX is zero

// --- Miscellaneous Control Flow ---
setcc_r8 :: proc(dst: u8) {}
endbr64 :: proc() {} 	// End branch (for Control-flow Enforcement Technology)

// ===== STACK MANIPULATION =====
push_r64 :: proc(reg: Register64) {}
pop_r64 :: proc(reg: Register64) {}
pushfq :: proc() {} 	// Push RFLAGS
popfq :: proc() {} 	// Pop RFLAGS

// ===== SIMD INSTRUCTIONS =====
// --- SSE/AVX Data Movement ---
movd_xmm_r64 :: proc(xmm: XMMRegister, reg: Register64) {}
movd_r64_xmm :: proc(reg: Register64, xmm: XMMRegister) {}
movups_xmm_m128 :: proc(dst: XMMRegister, mem: u64) {}
movdqu_xmm_m128 :: proc(dst: XMMRegister, mem: u64) {}

// --- SSE/AVX Arithmetic ---
addps_xmm_xmm :: proc(dst: XMMRegister, src: XMMRegister) {}
mulps_xmm_xmm :: proc(dst: XMMRegister, src: XMMRegister) {}
divps_xmm_xmm :: proc(dst: XMMRegister, src: XMMRegister) {}
sqrtps_xmm :: proc(xmm: XMMRegister) {}

// --- SSE/AVX Comparison ---
cmpps_xmm_xmm_imm8 :: proc(dst: XMMRegister, src: XMMRegister, imm: u8) {}
cmpeqps_xmm_xmm :: proc(dst: XMMRegister, src: XMMRegister) {}
cmpneqps_xmm_xmm :: proc(dst: XMMRegister, src: XMMRegister) {}

// --- AVX FMA (Fused Multiply-Add) ---
vfmadd132ps_xmm_xmm_xmm :: proc(dst: XMMRegister, src1: XMMRegister, src2: XMMRegister) {}
vfmadd213ps_xmm_xmm_xmm :: proc(dst: XMMRegister, src1: XMMRegister, src2: XMMRegister) {}
vfmadd231ps_xmm_xmm_xmm :: proc(dst: XMMRegister, src1: XMMRegister, src2: XMMRegister) {}

// --- AVX Advanced Operations ---
vaddps_ymm :: proc(dst: XMMRegister, src1: XMMRegister, src2: XMMRegister) {}
vmulps_ymm :: proc(dst: XMMRegister, src1: XMMRegister, src2: XMMRegister) {}
vdivps_ymm :: proc(dst: XMMRegister, src1: XMMRegister, src2: XMMRegister) {}
vblendps_ymm :: proc(dst: XMMRegister, src1: XMMRegister, src2: XMMRegister, imm: u8) {}
vpand_ymm :: proc(dst: XMMRegister, src1: XMMRegister, src2: XMMRegister) {}
vpor_ymm :: proc(dst: XMMRegister, src1: XMMRegister, src2: XMMRegister) {}
vpxor_ymm :: proc(dst: XMMRegister, src1: XMMRegister, src2: XMMRegister) {}
vpternlogd_ymm_ymm_ymm_imm8 :: proc(
	dst: XMMRegister,
	src1: XMMRegister,
	src2: XMMRegister,
	imm: u8,
) {}
vextracti128_ymm_ymm_imm8 :: proc(dst: XMMRegister, src: XMMRegister, imm: u8) {}

// --- SIMD Integer Operations ---
pavgb_xmm_xmm :: proc(dst: XMMRegister, src: XMMRegister) {}
pavgb_ymm_ymm :: proc(dst: XMMRegister, src: XMMRegister) {}
pmaddwd_xmm_xmm :: proc(dst: XMMRegister, src: XMMRegister) {}
pmulhuw_xmm_xmm :: proc(dst: XMMRegister, src: XMMRegister) {}

// --- AVX-512 Operations ---
vaddpd_zmm_zmm_zmm :: proc(dst: XMMRegister, src1: XMMRegister, src2: XMMRegister) {}
vsubpd_zmm_zmm_zmm :: proc(dst: XMMRegister, src1: XMMRegister, src2: XMMRegister) {}
vmulpd_zmm_zmm_zmm :: proc(dst: XMMRegister, src1: XMMRegister, src2: XMMRegister) {}
vdivpd_zmm_zmm_zmm :: proc(dst: XMMRegister, src1: XMMRegister, src2: XMMRegister) {}
vgatherdps_xmm :: proc(dst: XMMRegister) {}
vscatterdps_xmm :: proc(dst: XMMRegister) {}
kmovq_k_k :: proc(dst: u8, src: u8) {}
vpxordq_zmm_zmm_zmm :: proc(dst: XMMRegister, src1: XMMRegister, src2: XMMRegister) {}
vpscatterdd_ymm_m :: proc(src: XMMRegister, mem: u64) {}
vpscatterdq_ymm_m :: proc(src: XMMRegister, mem: u64) {}
vpscatterqd_ymm_m :: proc(src: XMMRegister, mem: u64) {}
vpcompressd_ymm_ymm :: proc(dst: XMMRegister, src: XMMRegister) {}
vpcompressq_ymm_ymm :: proc(dst: XMMRegister, src: XMMRegister) {}

// ===== CRYPTOGRAPHY INSTRUCTIONS =====
aesenc :: proc(dst: XMMRegister, src: XMMRegister) {} 	// AES encryption round
aesdec :: proc(dst: XMMRegister, src: XMMRegister) {} 	// AES decryption round
pclmulqdq :: proc(dst: XMMRegister, src: XMMRegister, imm: u8) {} 	// Carryless multiplication
crc32_r64_r64 :: proc(dst: Register64, src: Register64) {} 	// CRC-32 computation

// ===== X87 FLOATING POINT INSTRUCTIONS =====
fadd_st0_st :: proc(src: x87Register) {} 	// Add
fsub_st0_st :: proc(src: x87Register) {} 	// Subtract
fmul_st0_st :: proc(src: x87Register) {} 	// Multiply
fdiv_st0_st :: proc(src: x87Register) {} 	// Divide
fcom_st :: proc(src: x87Register) {} 	// Compare floating point
fcomp_st :: proc(src: x87Register) {} 	// Compare floating point and pop
fucom_st :: proc(src: x87Register) {} 	// Unordered compare floating point
fucomp_st :: proc(src: x87Register) {} 	// Unordered compare floating point and pop
fldcw :: proc(mem: u64) {} 	// Load x87 FPU control word
fstcw :: proc(mem: u64) {} 	// Store x87 FPU control word
fnstcw :: proc(mem: u64) {} 	// Store x87 FPU control word without checking exceptions
fninit :: proc() {} 	// Initialize x87 FPU
fwait :: proc() {} 	// Wait for x87 FPU to complete current instruction

// ===== MEMORY AND STRING OPERATIONS =====
movs_m64_m64 :: proc() {} 	// Move string
stos_m64 :: proc() {} 	// Store string
cmps_m64_m64 :: proc() {} 	// Compare string
rep_movs :: proc() {} 	// Repeat move string
rep_stos :: proc() {} 	// Repeat store string
rep_cmps :: proc() {} 	// Repeat compare string

// ===== SYSTEM INSTRUCTIONS =====
// --- Interrupts and System Calls ---
syscall :: proc() {} 	// Fast system call
sysret :: proc() {} 	// Return from system call
int_imm8 :: proc(imm: u8) {} 	// Generate software interrupt
int3 :: proc() {} 	// Breakpoint
into :: proc() {} 	// Interrupt on overflow
iret :: proc() {} 	// Interrupt return

// --- Processor Control ---
cpuid :: proc() {} 	// CPU identification
rdtsc :: proc() {} 	// Read time-stamp counter
rdtscp :: proc() {} 	// Read time-stamp counter and processor ID
rdmsr :: proc() {} 	// Read model-specific register
wrmsr :: proc() {} 	// Write model-specific register
rdpmc :: proc() {} 	// Read performance-monitoring counter
hlt :: proc() {} 	// Halt processor

// --- Process & Memory Management ---
swapgs :: proc() {} 	// Swap GS base register
wrpkru :: proc() {} 	// Write PKRU register
rdpkru :: proc() {} 	// Read PKRU register
clac :: proc() {} 	// Clear AC flag (prevents SMAP violations)
stac :: proc() {} 	// Set AC flag (allows supervisor mode access)
ud2 :: proc() {} 	// Undefined instruction (for debugging)

// --- Virtualization Instructions ---
vmcall :: proc() {} 	// VMX guest system call
vmlaunch :: proc() {} 	// Launch VMX non-root operation
vmresume :: proc() {} 	// Resume VMX non-root operation
vmxoff :: proc() {} 	// Exit VMX non-root operation

// ===== ATOMIC OPERATIONS =====
lock_xadd_r64_r64 :: proc(dst: Register64, src: Register64) {} 	// Locked exchange and add
lock_cmpxchg_r64_r64 :: proc(dst: Register64, src: Register64) {} 	// Locked compare and exchange
lock_inc_r64 :: proc(reg: Register64) {} 	// Locked increment
lock_dec_r64 :: proc(reg: Register64) {} 	// Locked decrement
lock_xchg_r64_r64 :: proc(dst: Register64, src: Register64) {} 	// Locked exchange
atomic_load_r64 :: proc(dst: Register64, src: u64) {} 	// Atomic load
atomic_store_r64 :: proc(dst: u64, src: Register64) {} 	// Atomic store

// ===== TRANSACTIONAL MEMORY INSTRUCTIONS =====
xbegin :: proc(offset: i32) {} 	// Begin transaction
xend :: proc() {} 	// End transaction
xabort :: proc(imm: u8) {} 	// Abort transaction
xtest :: proc() {} 	// Test if executing in a transaction

// ===== RANDOM NUMBER GENERATION =====
rdrand_r64 :: proc(reg: Register64) {} 	// Read random number
rdseed_r64 :: proc(reg: Register64) {} 	// Read random seed

// ===== PREFETCH INSTRUCTIONS =====
prefetcht0 :: proc(mem: u64) {} 	// Prefetch to all cache levels
prefetcht1 :: proc(mem: u64) {} 	// Prefetch to L2 cache
prefetcht2 :: proc(mem: u64) {} 	// Prefetch to L3 cache
prefetchnta :: proc(mem: u64) {} 	// Prefetch with minimal cache pollution

// ===== MEMORY MANAGEMENT AND OPTIMIZATION =====
clflush_m64 :: proc(mem: u64) {} 	// Flush cache line
clflushopt_m64 :: proc(mem: u64) {} 	// Optimized flush cache line
clwb_m64 :: proc(mem: u64) {} 	// Cache line write back
bound_r64_m128 :: proc(reg: Register64, mem: u64) {} 	// Check array bounds

// ===== POWER MANAGEMENT =====
monitor_r64_r64_r64 :: proc(reg1: Register64, reg2: Register64, reg3: Register64) {} 	// Set up monitor address
mwait_r64_r64 :: proc(reg1: Register64, reg2: Register64) {} 	// Monitor wait

// ===== MEMORY FENCES =====
mfence :: proc() {} 	// Memory fence
lfence :: proc() {} 	// Load fence
sfence :: proc() {} 	// Store fence

// ===== PERFORMANCE MONITORING =====
perfmon_instructions :: proc() {} 	// Placeholder for various performance monitoring instructions

// Helper function to test if two byte arrays are equal
test_equal :: proc(t: ^testing.T, desc: string, expected: []u8, actual: [$N]u8) {
	if len(expected) != len(actual) {
		fmt.println(
			desc,
			": Length mismatch. Expected",
			len(expected),
			"bytes, got",
			len(actual),
			"bytes.",
		)
		testing.fail(t)
		return
	}

	for i in 0 ..< len(expected) {
		if expected[i] != actual[i] {
			fmt.printf(
				"%s: Byte mismatch at position %d. Expected 0x%02X, got 0x%02X.\n",
				desc,
				i,
				expected[i],
				actual[i],
			)
			testing.fail(t)
			return
		}
	}
}

@(test)
test_mov_r64_imm64 :: proc(t: ^testing.T) {
	test_equal(
		t,
		"mov rax, 0x123456789ABCDEF0",
		asm_to_bytes("mov rax, 0x123456789ABCDEF0"),
		mov_r64_imm64(Register64.RAX, 0x123456789ABCDEF0),
	)
	test_equal(t, "mov rcx, 0x0", asm_to_bytes("mov rcx, 0x0"), mov_r64_imm64(Register64.RCX, 0x0))
	test_equal(
		t,
		"mov r8, 0xFFFFFFFFFFFFFFFF",
		asm_to_bytes("mov r8, 0xFFFFFFFFFFFFFFFF"),
		mov_r64_imm64(Register64.R8, 0xFFFFFFFFFFFFFFFF),
	)
	test_equal(
		t,
		"mov r15, 0xAAAAAAAAAAAAAAAA",
		asm_to_bytes("mov r15, 0xAAAAAAAAAAAAAAAA"),
		mov_r64_imm64(Register64.R15, 0xAAAAAAAAAAAAAAAA),
	)
}

@(test)
test_mov_r64_r64 :: proc(t: ^testing.T) {
	// Regular cases
	test_equal(
		t,
		"mov rax, rbx",
		asm_to_bytes("mov rax, rbx"),
		mov_r64_r64(Register64.RAX, Register64.RBX),
	)
	test_equal(
		t,
		"mov r8, r9",
		asm_to_bytes("mov r8, r9"),
		mov_r64_r64(Register64.R8, Register64.R9),
	)
	test_equal(
		t,
		"mov r15, rax",
		asm_to_bytes("mov r15, rax"),
		mov_r64_r64(Register64.R15, Register64.RAX),
	)
	test_equal(
		t,
		"mov rsp, rbp",
		asm_to_bytes("mov rsp, rbp"),
		mov_r64_r64(Register64.RSP, Register64.RBP),
	)

	// Self-move case
	test_equal(
		t,
		"mov rdx, rdx",
		asm_to_bytes("mov rdx, rdx"),
		mov_r64_r64(Register64.RDX, Register64.RDX),
	)
}

@(test)
test_mov_m64_r64 :: proc(t: ^testing.T) {
	// Regular cases
	test_equal(
		t,
		"mov [0x1000], rax",
		asm_to_bytes("mov [0x1000], rax"),
		mov_m64_r64(0x1000, Register64.RAX),
	)
	test_equal(
		t,
		"mov [0x0], r15",
		asm_to_bytes("mov [0x0], r15"),
		mov_m64_r64(0x0, Register64.R15),
	)
	test_equal(
		t,
		"mov [0xFFFFFFFF], rdx",
		asm_to_bytes("mov [0xFFFFFFFF], rdx"),
		mov_m64_r64(0xFFFFFFFF, Register64.RDX),
	)
	test_equal(
		t,
		"mov [0x7FFFFFFF], r8",
		asm_to_bytes("mov [0x7FFFFFFF], r8"),
		mov_m64_r64(0x7FFFFFFF, Register64.R8),
	)
}

@(test)
test_movabs_r64_imm64 :: proc(t: ^testing.T) {
	// Regular cases
	test_equal(
		t,
		"movabs rax, 0x123456789ABCDEF0",
		asm_to_bytes("movabs rax, 0x123456789ABCDEF0"),
		movabs_r64_imm64(Register64.RAX, 0x123456789ABCDEF0),
	)
	test_equal(
		t,
		"movabs r10, 0x0",
		asm_to_bytes("movabs r10, 0x0"),
		movabs_r64_imm64(Register64.R10, 0x0),
	)
	test_equal(
		t,
		"movabs r15, 0xFFFFFFFFFFFFFFFF",
		asm_to_bytes("movabs r15, 0xFFFFFFFFFFFFFFFF"),
		movabs_r64_imm64(Register64.R15, 0xFFFFFFFFFFFFFFFF),
	)
	test_equal(
		t,
		"movabs rbx, 0x8000000000000000",
		asm_to_bytes("movabs rbx, 0x8000000000000000"),
		movabs_r64_imm64(Register64.RBX, 0x8000000000000000),
	)
}

@(test)
test_xchg_r64_r64 :: proc(t: ^testing.T) {
	// Regular cases
	test_equal(
		t,
		"xchg rax, rbx",
		asm_to_bytes("xchg rax, rbx"),
		xchg_r64_r64(Register64.RAX, Register64.RBX),
	)
	test_equal(
		t,
		"xchg r8, r9",
		asm_to_bytes("xchg r8, r9"),
		xchg_r64_r64(Register64.R8, Register64.R9),
	)
	test_equal(
		t,
		"xchg r15, rcx",
		asm_to_bytes("xchg r15, rcx"),
		xchg_r64_r64(Register64.R15, Register64.RCX),
	)

	// Commutative cases (should produce same encoding)
	a := xchg_r64_r64(Register64.RAX, Register64.RCX)
	b := xchg_r64_r64(Register64.RCX, Register64.RAX)
	test_equal(t, "xchg RAX/RCX commutative", a[:], b)

	// Self-exchange case
	test_equal(
		t,
		"xchg rdx, rdx",
		asm_to_bytes("xchg rdx, rdx"),
		xchg_r64_r64(Register64.RDX, Register64.RDX),
	)
}

@(test)
test_movsx_r64_r32 :: proc(t: ^testing.T) {
	// Regular cases
	test_equal(
		t,
		"movsx rax, ebx",
		asm_to_bytes("movsx rax, ebx"),
		movsx_r64_r32(Register64.RAX, Register64.RBX),
	)
	test_equal(
		t,
		"movsx r8, ecx",
		asm_to_bytes("movsx r8, ecx"),
		movsx_r64_r32(Register64.R8, Register64.RCX),
	)
	test_equal(
		t,
		"movsx r15, eax",
		asm_to_bytes("movsx r15, eax"),
		movsx_r64_r32(Register64.R15, Register64.RAX),
	)
	test_equal(
		t,
		"movsx rbx, r9d",
		asm_to_bytes("movsx rbx, r9d"),
		movsx_r64_r32(Register64.RBX, Register64.R9),
	)
}

@(test)
test_movzx_r64_r32 :: proc(t: ^testing.T) {
	// Regular cases
	test_equal(
		t,
		"movzx rax, ebx",
		asm_to_bytes("movzx rax, ebx"),
		movzx_r64_r32(Register64.RAX, Register64.RBX),
	)
	test_equal(
		t,
		"movzx r8, ecx",
		asm_to_bytes("movzx r8, ecx"),
		movzx_r64_r32(Register64.R8, Register64.RCX),
	)
	test_equal(
		t,
		"movzx r15, eax",
		asm_to_bytes("movzx r15, eax"),
		movzx_r64_r32(Register64.R15, Register64.RAX),
	)
	test_equal(
		t,
		"movzx rbx, r9d",
		asm_to_bytes("movzx rbx, r9d"),
		movzx_r64_r32(Register64.RBX, Register64.R9),
	)
}

@(test)
test_movbe_r64_m64 :: proc(t: ^testing.T) {
	// Regular cases
	test_equal(
		t,
		"movbe rax, [0x1000]",
		asm_to_bytes("movbe rax, [0x1000]"),
		movbe_r64_m64(Register64.RAX, 0x1000),
	)
	test_equal(
		t,
		"movbe r15, [0x0]",
		asm_to_bytes("movbe r15, [0x0]"),
		movbe_r64_m64(Register64.R15, 0x0),
	)
	test_equal(
		t,
		"movbe rdx, [0xFFFFFFFF]",
		asm_to_bytes("movbe rdx, [0xFFFFFFFF]"),
		movbe_r64_m64(Register64.RDX, 0xFFFFFFFF),
	)
	test_equal(
		t,
		"movbe r8, [0x7FFFFFFF]",
		asm_to_bytes("movbe r8, [0x7FFFFFFF]"),
		movbe_r64_m64(Register64.R8, 0x7FFFFFFF),
	)
}

@(test)
test_movbe_m64_r64 :: proc(t: ^testing.T) {
	// Regular cases
	test_equal(
		t,
		"movbe [0x1000], rax",
		asm_to_bytes("movbe [0x1000], rax"),
		movbe_m64_r64(0x1000, Register64.RAX),
	)
	test_equal(
		t,
		"movbe [0x0], r15",
		asm_to_bytes("movbe [0x0], r15"),
		movbe_m64_r64(0x0, Register64.R15),
	)
	test_equal(
		t,
		"movbe [0xFFFFFFFF], rdx",
		asm_to_bytes("movbe [0xFFFFFFFF], rdx"),
		movbe_m64_r64(0xFFFFFFFF, Register64.RDX),
	)
	test_equal(
		t,
		"movbe [0x7FFFFFFF], r8",
		asm_to_bytes("movbe [0x7FFFFFFF], r8"),
		movbe_m64_r64(0x7FFFFFFF, Register64.R8),
	)
}

@(test)
test_bswap_r64 :: proc(t: ^testing.T) {
	// Test all registers
	test_equal(t, "bswap rax", asm_to_bytes("bswap rax"), bswap_r64(Register64.RAX))
	test_equal(t, "bswap rcx", asm_to_bytes("bswap rcx"), bswap_r64(Register64.RCX))
	test_equal(t, "bswap r8", asm_to_bytes("bswap r8"), bswap_r64(Register64.R8))
	test_equal(t, "bswap r15", asm_to_bytes("bswap r15"), bswap_r64(Register64.R15))
}

@(test)
test_mov_cr_r64 :: proc(t: ^testing.T) {
	// Test various CR registers
	test_equal(t, "mov cr0, rax", asm_to_bytes("mov cr0, rax"), mov_cr_r64(0, Register64.RAX))
	test_equal(t, "mov cr3, rbx", asm_to_bytes("mov cr3, rbx"), mov_cr_r64(3, Register64.RBX))
	test_equal(t, "mov cr4, r8", asm_to_bytes("mov cr4, r8"), mov_cr_r64(4, Register64.R8))
	test_equal(t, "mov cr8, r15", asm_to_bytes("mov cr8, r15"), mov_cr_r64(8, Register64.R15))
}

@(test)
test_mov_r64_cr :: proc(t: ^testing.T) {
	// Test various CR registers
	test_equal(t, "mov rax, cr0", asm_to_bytes("mov rax, cr0"), mov_r64_cr(Register64.RAX, 0))
	test_equal(t, "mov rbx, cr3", asm_to_bytes("mov rbx, cr3"), mov_r64_cr(Register64.RBX, 3))
	test_equal(t, "mov r8, cr4", asm_to_bytes("mov r8, cr4"), mov_r64_cr(Register64.R8, 4))
	test_equal(t, "mov r15, cr8", asm_to_bytes("mov r15, cr8"), mov_r64_cr(Register64.R15, 8))
}

@(test)
test_mov_cr0_r64 :: proc(t: ^testing.T) {
	// Test all registers with CR0
	test_equal(t, "mov cr0, rax", asm_to_bytes("mov cr0, rax"), mov_cr0_r64(Register64.RAX))
	test_equal(t, "mov cr0, rcx", asm_to_bytes("mov cr0, rcx"), mov_cr0_r64(Register64.RCX))
	test_equal(t, "mov cr0, r8", asm_to_bytes("mov cr0, r8"), mov_cr0_r64(Register64.R8))
	test_equal(t, "mov cr0, r15", asm_to_bytes("mov cr0, r15"), mov_cr0_r64(Register64.R15))
}

@(test)
test_mov_cr2_r64 :: proc(t: ^testing.T) {
	// Test all registers with CR2
	test_equal(t, "mov cr2, rax", asm_to_bytes("mov cr2, rax"), mov_cr2_r64(Register64.RAX))
	test_equal(t, "mov cr2, rcx", asm_to_bytes("mov cr2, rcx"), mov_cr2_r64(Register64.RCX))
	test_equal(t, "mov cr2, r8", asm_to_bytes("mov cr2, r8"), mov_cr2_r64(Register64.R8))
	test_equal(t, "mov cr2, r15", asm_to_bytes("mov cr2, r15"), mov_cr2_r64(Register64.R15))
}

@(test)
test_mov_cr3_r64 :: proc(t: ^testing.T) {
	// Test all registers with CR3
	test_equal(t, "mov cr3, rax", asm_to_bytes("mov cr3, rax"), mov_cr3_r64(Register64.RAX))
	test_equal(t, "mov cr3, rcx", asm_to_bytes("mov cr3, rcx"), mov_cr3_r64(Register64.RCX))
	test_equal(t, "mov cr3, r8", asm_to_bytes("mov cr3, r8"), mov_cr3_r64(Register64.R8))
	test_equal(t, "mov cr3, r15", asm_to_bytes("mov cr3, r15"), mov_cr3_r64(Register64.R15))
}

@(test)
test_mov_cr4_r64 :: proc(t: ^testing.T) {
	// Test all registers with CR4
	test_equal(t, "mov cr4, rax", asm_to_bytes("mov cr4, rax"), mov_cr4_r64(Register64.RAX))
	test_equal(t, "mov cr4, rcx", asm_to_bytes("mov cr4, rcx"), mov_cr4_r64(Register64.RCX))
	test_equal(t, "mov cr4, r8", asm_to_bytes("mov cr4, r8"), mov_cr4_r64(Register64.R8))
	test_equal(t, "mov cr4, r15", asm_to_bytes("mov cr4, r15"), mov_cr4_r64(Register64.R15))
}

@(test)
test_mov_dr0_r64 :: proc(t: ^testing.T) {
	// Test all registers with DR0
	test_equal(t, "mov dr0, rax", asm_to_bytes("mov dr0, rax"), mov_dr0_r64(Register64.RAX))
	test_equal(t, "mov dr0, rcx", asm_to_bytes("mov dr0, rcx"), mov_dr0_r64(Register64.RCX))
	test_equal(t, "mov dr0, r8", asm_to_bytes("mov dr0, r8"), mov_dr0_r64(Register64.R8))
	test_equal(t, "mov dr0, r15", asm_to_bytes("mov dr0, r15"), mov_dr0_r64(Register64.R15))
}

@(test)
test_mov_dr1_r64 :: proc(t: ^testing.T) {
	// Test all registers with DR1
	test_equal(t, "mov dr1, rax", asm_to_bytes("mov dr1, rax"), mov_dr1_r64(Register64.RAX))
	test_equal(t, "mov dr1, rcx", asm_to_bytes("mov dr1, rcx"), mov_dr1_r64(Register64.RCX))
	test_equal(t, "mov dr1, r8", asm_to_bytes("mov dr1, r8"), mov_dr1_r64(Register64.R8))
	test_equal(t, "mov dr1, r15", asm_to_bytes("mov dr1, r15"), mov_dr1_r64(Register64.R15))
}

@(test)
test_mov_dr2_r64 :: proc(t: ^testing.T) {
	// Test all registers with DR2
	test_equal(t, "mov dr2, rax", asm_to_bytes("mov dr2, rax"), mov_dr2_r64(Register64.RAX))
	test_equal(t, "mov dr2, rcx", asm_to_bytes("mov dr2, rcx"), mov_dr2_r64(Register64.RCX))
	test_equal(t, "mov dr2, r8", asm_to_bytes("mov dr2, r8"), mov_dr2_r64(Register64.R8))
	test_equal(t, "mov dr2, r15", asm_to_bytes("mov dr2, r15"), mov_dr2_r64(Register64.R15))
}

@(test)
test_mov_dr3_r64 :: proc(t: ^testing.T) {
	// Test all registers with DR3
	test_equal(t, "mov dr3, rax", asm_to_bytes("mov dr3, rax"), mov_dr3_r64(Register64.RAX))
	test_equal(t, "mov dr3, rcx", asm_to_bytes("mov dr3, rcx"), mov_dr3_r64(Register64.RCX))
	test_equal(t, "mov dr3, r8", asm_to_bytes("mov dr3, r8"), mov_dr3_r64(Register64.R8))
	test_equal(t, "mov dr3, r15", asm_to_bytes("mov dr3, r15"), mov_dr3_r64(Register64.R15))
}

@(test)
test_mov_dr6_r64 :: proc(t: ^testing.T) {
	// Test all registers with DR6
	test_equal(t, "mov dr6, rax", asm_to_bytes("mov dr6, rax"), mov_dr6_r64(Register64.RAX))
	test_equal(t, "mov dr6, rcx", asm_to_bytes("mov dr6, rcx"), mov_dr6_r64(Register64.RCX))
	test_equal(t, "mov dr6, r8", asm_to_bytes("mov dr6, r8"), mov_dr6_r64(Register64.R8))
	test_equal(t, "mov dr6, r15", asm_to_bytes("mov dr6, r15"), mov_dr6_r64(Register64.R15))
}

@(test)
test_mov_dr7_r64 :: proc(t: ^testing.T) {
	// Test all registers with DR7
	test_equal(t, "mov dr7, rax", asm_to_bytes("mov dr7, rax"), mov_dr7_r64(Register64.RAX))
	test_equal(t, "mov dr7, rcx", asm_to_bytes("mov dr7, rcx"), mov_dr7_r64(Register64.RCX))
	test_equal(t, "mov dr7, r8", asm_to_bytes("mov dr7, r8"), mov_dr7_r64(Register64.R8))
	test_equal(t, "mov dr7, r15", asm_to_bytes("mov dr7, r15"), mov_dr7_r64(Register64.R15))
}

@(test)
test_lea_r64_m64 :: proc(t: ^testing.T) {
	// Regular cases
	test_equal(
		t,
		"lea rax, [0x1000]",
		asm_to_bytes("lea rax, [0x1000]"),
		lea_r64_m64(Register64.RAX, 0x1000),
	)
	test_equal(
		t,
		"lea r15, [0x0]",
		asm_to_bytes("lea r15, [0x0]"),
		lea_r64_m64(Register64.R15, 0x0),
	)
	test_equal(
		t,
		"lea rdx, [0xFFFFFFFF]",
		asm_to_bytes("lea rdx, [0xFFFFFFFF]"),
		lea_r64_m64(Register64.RDX, 0xFFFFFFFF),
	)
	test_equal(
		t,
		"lea r8, [0x7FFFFFFF]",
		asm_to_bytes("lea r8, [0x7FFFFFFF]"),
		lea_r64_m64(Register64.R8, 0x7FFFFFFF),
	)
}

@(test)
test_lea_r64_m :: proc(t: ^testing.T) {
	// Regular cases
	test_equal(
		t,
		"lea rax, [0x1000]",
		asm_to_bytes("lea rax, [0x1000]"),
		lea_r64_m(Register64.RAX, 0x1000),
	)
	test_equal(t, "lea r15, [0x0]", asm_to_bytes("lea r15, [0x0]"), lea_r64_m(Register64.R15, 0x0))
	test_equal(
		t,
		"lea rdx, [0xFFFFFFFF]",
		asm_to_bytes("lea rdx, [0xFFFFFFFF]"),
		lea_r64_m(Register64.RDX, 0xFFFFFFFF),
	)
	test_equal(
		t,
		"lea r8, [0x7FFFFFFF]",
		asm_to_bytes("lea r8, [0x7FFFFFFF]"),
		lea_r64_m(Register64.R8, 0x7FFFFFFF),
	)
}

@(test)
test_add_r64_imm32 :: proc(t: ^testing.T) {
	// Regular cases
	test_equal(
		t,
		"add rax, 0x1000",
		asm_to_bytes("add rax, 0x1000"),
		add_r64_imm32(Register64.RAX, 0x1000),
	)
	test_equal(t, "add r15, 0x0", asm_to_bytes("add r15, 0x0"), add_r64_imm32(Register64.R15, 0x0))
	test_equal(
		t,
		"add rdx, 0xFFFFFFFF",
		asm_to_bytes("add rdx, 0xFFFFFFFF"),
		add_r64_imm32(Register64.RDX, 0xFFFFFFFF),
	)
	test_equal(
		t,
		"add r8, 0x7FFFFFFF",
		asm_to_bytes("add r8, 0x7FFFFFFF"),
		add_r64_imm32(Register64.R8, 0x7FFFFFFF),
	)
}

@(test)
test_add_r64_r64 :: proc(t: ^testing.T) {
	// Regular cases
	test_equal(
		t,
		"add rax, rbx",
		asm_to_bytes("add rax, rbx"),
		add_r64_r64(Register64.RAX, Register64.RBX),
	)
	test_equal(
		t,
		"add r8, r9",
		asm_to_bytes("add r8, r9"),
		add_r64_r64(Register64.R8, Register64.R9),
	)
	test_equal(
		t,
		"add r15, rax",
		asm_to_bytes("add r15, rax"),
		add_r64_r64(Register64.R15, Register64.RAX),
	)
	test_equal(
		t,
		"add rsp, rbp",
		asm_to_bytes("add rsp, rbp"),
		add_r64_r64(Register64.RSP, Register64.RBP),
	)

	// Self-add case
	test_equal(
		t,
		"add rdx, rdx",
		asm_to_bytes("add rdx, rdx"),
		add_r64_r64(Register64.RDX, Register64.RDX),
	)
}

@(test)
test_sub_r64_imm32 :: proc(t: ^testing.T) {
	// Regular cases
	test_equal(
		t,
		"sub rax, 0x1000",
		asm_to_bytes("sub rax, 0x1000"),
		sub_r64_imm32(Register64.RAX, 0x1000),
	)
	test_equal(t, "sub r15, 0x0", asm_to_bytes("sub r15, 0x0"), sub_r64_imm32(Register64.R15, 0x0))
	test_equal(
		t,
		"sub rdx, 0xFFFFFFFF",
		asm_to_bytes("sub rdx, 0xFFFFFFFF"),
		sub_r64_imm32(Register64.RDX, 0xFFFFFFFF),
	)
	test_equal(
		t,
		"sub r8, 0x7FFFFFFF",
		asm_to_bytes("sub r8, 0x7FFFFFFF"),
		sub_r64_imm32(Register64.R8, 0x7FFFFFFF),
	)
}

@(test)
test_sub_r64_r64 :: proc(t: ^testing.T) {
	// Regular cases
	test_equal(
		t,
		"sub rax, rbx",
		asm_to_bytes("sub rax, rbx"),
		sub_r64_r64(Register64.RAX, Register64.RBX),
	)
	test_equal(
		t,
		"sub r8, r9",
		asm_to_bytes("sub r8, r9"),
		sub_r64_r64(Register64.R8, Register64.R9),
	)
	test_equal(
		t,
		"sub r15, rax",
		asm_to_bytes("sub r15, rax"),
		sub_r64_r64(Register64.R15, Register64.RAX),
	)
	test_equal(
		t,
		"sub rsp, rbp",
		asm_to_bytes("sub rsp, rbp"),
		sub_r64_r64(Register64.RSP, Register64.RBP),
	)

	// Self-subtract case
	test_equal(
		t,
		"sub rdx, rdx",
		asm_to_bytes("sub rdx, rdx"),
		sub_r64_r64(Register64.RDX, Register64.RDX),
	)
}

@(test)
test_inc_r64 :: proc(t: ^testing.T) {
	// Test all registers
	test_equal(t, "inc rax", asm_to_bytes("inc rax"), inc_r64(Register64.RAX))
	test_equal(t, "inc rcx", asm_to_bytes("inc rcx"), inc_r64(Register64.RCX))
	test_equal(t, "inc r8", asm_to_bytes("inc r8"), inc_r64(Register64.R8))
	test_equal(t, "inc r15", asm_to_bytes("inc r15"), inc_r64(Register64.R15))
}

@(test)
test_dec_r64 :: proc(t: ^testing.T) {
	// Test all registers
	test_equal(t, "dec rax", asm_to_bytes("dec rax"), dec_r64(Register64.RAX))
	test_equal(t, "dec rcx", asm_to_bytes("dec rcx"), dec_r64(Register64.RCX))
	test_equal(t, "dec r8", asm_to_bytes("dec r8"), dec_r64(Register64.R8))
	test_equal(t, "dec r15", asm_to_bytes("dec r15"), dec_r64(Register64.R15))
}

@(test)
test_neg_r64 :: proc(t: ^testing.T) {
	// Test all registers
	test_equal(t, "neg rax", asm_to_bytes("neg rax"), neg_r64(Register64.RAX))
	test_equal(t, "neg rcx", asm_to_bytes("neg rcx"), neg_r64(Register64.RCX))
	test_equal(t, "neg r8", asm_to_bytes("neg r8"), neg_r64(Register64.R8))
	test_equal(t, "neg r15", asm_to_bytes("neg r15"), neg_r64(Register64.R15))
}
