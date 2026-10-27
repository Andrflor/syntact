package x64_assembler

// ============================================================================
// SSE2 PACKED instructions — what the code emitter writes a vector with: two
// lanes of 64 bits in an XMM register, integers or doubles. Each is
// prefix [REX] 0F op /r, the prefix 66; a shift by an immediate is 66 [REX] 0F
// 72|73 /ext ib, the register in r/m.
// ============================================================================

// packed: prefix [REX] 0F op, dst in reg, src in r/m.
packed :: proc(prefix, op: u8, dst, src: XMMRegister) {
	rex: u8 = 0x40 | (u8(dst) & 0x8) >> 1 | (u8(src) & 0x8) >> 3
	modrm := encode_modrm(3, u8(dst) & 0x7, u8(src) & 0x7)
	if rex != 0x40 do write([]u8{prefix, rex, 0x0F, op, modrm})
	else do write([]u8{prefix, 0x0F, op, modrm})
}

paddq_xmm_xmm :: proc(dst, src: XMMRegister) {packed(0x66, 0xD4, dst, src)}
psubq_xmm_xmm :: proc(dst, src: XMMRegister) {packed(0x66, 0xFB, dst, src)}
pand_xmm_xmm :: proc(dst, src: XMMRegister) {packed(0x66, 0xDB, dst, src)}
por_xmm_xmm :: proc(dst, src: XMMRegister) {packed(0x66, 0xEB, dst, src)}
pxor_xmm_xmm :: proc(dst, src: XMMRegister) {packed(0x66, 0xEF, dst, src)}
pmuludq_xmm_xmm :: proc(dst, src: XMMRegister) {packed(0x66, 0xF4, dst, src)}
pcmpeqd_xmm_xmm :: proc(dst, src: XMMRegister) {packed(0x66, 0x76, dst, src)}
punpcklqdq_xmm_xmm :: proc(dst, src: XMMRegister) {packed(0x66, 0x6C, dst, src)}
addpd_xmm_xmm :: proc(dst, src: XMMRegister) {packed(0x66, 0x58, dst, src)}
subpd_xmm_xmm :: proc(dst, src: XMMRegister) {packed(0x66, 0x5C, dst, src)}
mulpd_xmm_xmm :: proc(dst, src: XMMRegister) {packed(0x66, 0x59, dst, src)}
divpd_xmm_xmm :: proc(dst, src: XMMRegister) {packed(0x66, 0x5E, dst, src)}

// shift_imm8: 66 [REX.B] 0F op /ext ib.
shift_imm8 :: proc(op, ext: u8, reg: XMMRegister, imm: u8) {
	modrm := encode_modrm(3, ext, u8(reg) & 0x7)
	if u8(reg) & 0x8 != 0 do write([]u8{0x66, 0x41, 0x0F, op, modrm, imm})
	else do write([]u8{0x66, 0x0F, op, modrm, imm})
}

psllq_xmm_imm8 :: proc(reg: XMMRegister, imm: u8) {shift_imm8(0x73, 6, reg, imm)}
psrlq_xmm_imm8 :: proc(reg: XMMRegister, imm: u8) {shift_imm8(0x73, 2, reg, imm)}
psrad_xmm_imm8 :: proc(reg: XMMRegister, imm: u8) {shift_imm8(0x72, 4, reg, imm)}

// pshufd xmm, xmm, imm8 : 66 [REX] 0F 70 /r ib — the dwords of src, in the order
// imm8 says.
pshufd_xmm_xmm_imm8 :: proc(dst, src: XMMRegister, imm: u8) {
	packed(0x66, 0x70, dst, src)
	write([]u8{imm})
}
