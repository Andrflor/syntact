package x64_assembler

// ============================================================================
// MOVZX / MOVSX from memory — load-and-extend in one instruction.
//
// The base x64_instructions.odin has the register→register forms; these are the
// memory→register forms the emitter needs to fuse a typed ??'s load and its
// domain mask. A ??::u8 stored as a full i64 in ARGS_TABLE has its value in the
// low byte (little-endian), so `movzx dst, byte [mem]` reads that byte and
// zero-extends — exactly the `& 0xff` mask, fused into the load. `movsx` does
// the signed (i8/i16) case. Encodings: 0F B6 (zx byte), 0F B7 (zx word),
// 0F BE (sx byte), 0F BF (sx word), all REX.W for a 64-bit destination.
// ============================================================================

movzx_r64_m8 :: proc(dst: Register64, mem: MemoryAddress) {
	write_memory_address(mem, u8(dst), [2]u8{0x0F, 0xB6})
}

movzx_r64_m16 :: proc(dst: Register64, mem: MemoryAddress) {
	write_memory_address(mem, u8(dst), [2]u8{0x0F, 0xB7})
}

movsx_r64_m8 :: proc(dst: Register64, mem: MemoryAddress) {
	write_memory_address(mem, u8(dst), [2]u8{0x0F, 0xBE})
}

movsx_r64_m16 :: proc(dst: Register64, mem: MemoryAddress) {
	write_memory_address(mem, u8(dst), [2]u8{0x0F, 0xBF})
}

// movsxd dst64, dword [mem] : load 32 bits and sign-extend to 64 (REX.W + 63 /r).
movsxd_r64_m32 :: proc(dst: Register64, mem: MemoryAddress) {
	write_memory_address(mem, u8(dst), [1]u8{0x63})
}

// mov dst32, dword [mem] : load 32 bits into the 32-bit register, which zeroes
// the upper 32 bits of the 64-bit register (8B /r, NO REX.W — set_w = false).
mov_r64d_m32 :: proc(dst: Register64, mem: MemoryAddress) {
	write_memory_address(mem, u8(dst), [1]u8{0x8B}, set_w = false)
}

// --- 32-bit destination forms (no REX.W; the 32-bit write zero-extends to 64) ---
// Used when the value is computed in 32-bit registers (its width ≤ 32). One byte
// shorter than the r64 forms, and the natural choice for u8/i16/i32 arithmetic.

movzx_r32_m8 :: proc(dst: Register64, mem: MemoryAddress) {
	write_memory_address(mem, u8(dst), [2]u8{0x0F, 0xB6}, set_w = false)
}

movzx_r32_m16 :: proc(dst: Register64, mem: MemoryAddress) {
	write_memory_address(mem, u8(dst), [2]u8{0x0F, 0xB7}, set_w = false)
}

movsx_r32_m8 :: proc(dst: Register64, mem: MemoryAddress) {
	write_memory_address(mem, u8(dst), [2]u8{0x0F, 0xBE}, set_w = false)
}

movsx_r32_m16 :: proc(dst: Register64, mem: MemoryAddress) {
	write_memory_address(mem, u8(dst), [2]u8{0x0F, 0xBF}, set_w = false)
}
