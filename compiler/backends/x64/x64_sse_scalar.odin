package x64_assembler

// ============================================================================
// SSE SCALAR DOUBLE/INT instructions — the scalar floating-point ops the code
// emitter needs (addsd/subsd/mulsd/divsd) plus the int↔double conversions
// (cvtsi2sd / cvttsd2si). The pre-existing x64_instructions.odin has the XMM
// move forms (movq) but not these; they are added here in the same style (one
// proc per instruction, writing to the context ByteBuffer via `write`) so the
// emitter calls a named proc instead of emitting raw bytes.
//
// Encodings (all REX.W where a GPR is involved, XMM0..XMM1 only — the emitter's
// scratch pair):
//   addsd  xmm,xmm : F2 0F 58 /r
//   subsd  xmm,xmm : F2 0F 5C /r
//   mulsd  xmm,xmm : F2 0F 59 /r
//   divsd  xmm,xmm : F2 0F 5E /r
//   cvtsi2sd xmm,r64 : F2 REX.W 0F 2A /r
//   cvttsd2si r64,xmm : F2 REX.W 0F 2C /r
//   movq  r64,xmm : 66 REX.W 0F 7E /r   (xmm → gpr, all 64 bits)
// ============================================================================

// modrm for two XMM registers in reg/reg form (mod=11).
@(private = "file")
xmm_modrm :: proc(reg, rm: XMMRegister) -> u8 {
	return 0xC0 | ((u8(reg) & 0x7) << 3) | (u8(rm) & 0x7)
}

addsd_xmm_xmm :: proc(dst, src: XMMRegister) {
	write([]u8{0xF2, 0x0F, 0x58, xmm_modrm(dst, src)})
}

subsd_xmm_xmm :: proc(dst, src: XMMRegister) {
	write([]u8{0xF2, 0x0F, 0x5C, xmm_modrm(dst, src)})
}

mulsd_xmm_xmm :: proc(dst, src: XMMRegister) {
	write([]u8{0xF2, 0x0F, 0x59, xmm_modrm(dst, src)})
}

divsd_xmm_xmm :: proc(dst, src: XMMRegister) {
	write([]u8{0xF2, 0x0F, 0x5E, xmm_modrm(dst, src)})
}

// cvtsi2sd xmm, r64 : convert a signed 64-bit integer to a double.
cvtsi2sd_xmm_r64 :: proc(dst: XMMRegister, src: Register64) {
	rex: u8 = 0x48 | ((u8(dst) & 0x8) >> 1) | ((u8(src) & 0x8) >> 3)
	modrm := 0xC0 | ((u8(dst) & 0x7) << 3) | (u8(src) & 0x7)
	write([]u8{0xF2, rex, 0x0F, 0x2A, modrm})
}

// cvttsd2si r64, xmm : truncate a double to a signed 64-bit integer.
cvttsd2si_r64_xmm :: proc(dst: Register64, src: XMMRegister) {
	rex: u8 = 0x48 | ((u8(dst) & 0x8) >> 1) | ((u8(src) & 0x8) >> 3)
	modrm := 0xC0 | ((u8(dst) & 0x7) << 3) | (u8(src) & 0x7)
	write([]u8{0xF2, rex, 0x0F, 0x2C, modrm})
}

// movq r64, xmm : move all 64 bits of an XMM register to a GPR.
movq_r64_xmm_bits :: proc(dst: Register64, src: XMMRegister) {
	rex: u8 = 0x48 | ((u8(src) & 0x8) >> 1) | ((u8(dst) & 0x8) >> 3)
	modrm := 0xC0 | ((u8(src) & 0x7) << 3) | (u8(dst) & 0x7)
	write([]u8{0x66, rex, 0x0F, 0x7E, modrm})
}

// ----------------------------------------------------------------------------
// A few integer instructions the emitter used as raw bytes and the base
// assembler lacked, added here for the same reason.
// ----------------------------------------------------------------------------

// cqo : sign-extend RAX into RDX:RAX (before idiv).
cqo :: proc() {
	write([]u8{0x48, 0x99})
}

// shl_r64_cl / sar_r64_cl / shr_r64_cl : shift RAX (or any r64) by CL.
shl_r64_cl :: proc(reg: Register64) {
	rex: u8 = 0x48 | ((u8(reg) & 0x8) >> 3)
	write([]u8{rex, 0xD3, 0xE0 | (u8(reg) & 0x7)})
}

shr_r64_cl :: proc(reg: Register64) {
	rex: u8 = 0x48 | ((u8(reg) & 0x8) >> 3)
	write([]u8{rex, 0xD3, 0xE8 | (u8(reg) & 0x7)})
}

sar_r64_cl :: proc(reg: Register64) {
	rex: u8 = 0x48 | ((u8(reg) & 0x8) >> 3)
	write([]u8{rex, 0xD3, 0xF8 | (u8(reg) & 0x7)})
}

// sar_r64_imm8 : arithmetic shift right by an immediate (REX.W C1 /7 ib, or D1 /7
// for a shift of 1). /7 is the SAR opcode extension.
sar_r64_imm8 :: proc(reg: Register64, imm: u8) {
	rex: u8 = 0x48 | ((u8(reg) & 0x8) >> 3)
	modrm: u8 = 0xF8 | (u8(reg) & 0x7) // mod=11, /7, rm=reg
	if imm == 1 {
		write([]u8{rex, 0xD1, modrm})
	} else {
		write([]u8{rex, 0xC1, modrm, imm})
	}
}
