package compiler

import "core:os"
import x64 "./backends/x64"

// emit_executable turns a lowered program into an executable file on disk.
emit_executable :: proc(prog: ^BC_Program, path: string) -> string {
	code, msg := emit_x64(prog)
	if msg != "" do return msg
	image := build_elf(code)
	if err := os.write_entire_file(path, image); err != nil {
		return "could not write output file"
	}
	// Make it directly runnable (rwxr-xr-x).
	os.chmod(path, os.Permissions{.Read_User, .Write_User, .Execute_User, .Read_Group, .Execute_Group, .Read_Other, .Execute_Other})
	return ""
}

// ============================================================================
// ELF64 executable writer + runtime entry stub.
//
// Produces a minimal static ET_EXEC: ELF header + one PT_LOAD program header +
// the runtime stub + the program's .text. Everything loads at BASE; the entry
// point is the stub, which:
//   1. reads argc/argv from the initial stack,
//   2. parses argv[1..] as signed integers via an inline atoi,
//   3. stores each into ARGS_TABLE (a fixed BSS-like region in the mapped image),
//   4. falls through into the program body (which reads ARGS_TABLE[slot]).
// The program ends with an exit syscall carrying the result.
//
// Layout decision: ?? arguments live at a FIXED absolute address (ARGS_TABLE)
// rather than relative to a call frame — simplest unambiguous contract for the
// emitter's BC_Load_Arg (it reads [ARGS_TABLE + 8*slot]).
// ============================================================================

ELF_BASE :: 0x400000
ELF_HDR_SIZE :: 64
ELF_PH_SIZE :: 56
// The file is laid out: [ELF header][program header][code...]. Code virtual
// address = BASE + headers. ARGS_TABLE sits in extra mapped space after the code.
ELF_HEADERS :: ELF_HDR_SIZE + ELF_PH_SIZE

// ARGS_TABLE is at a FIXED absolute address well past any realistic code size,
// so the emitter knows it before emitting (no chicken-and-egg with code length).
// The PT_LOAD's memsz extends to cover it (zero-filled tail).
ARGS_TABLE_VADDR :: ELF_BASE + 0x100000 // 1 MiB into the image
ARGS_TABLE_MAX :: 64 // up to 64 ?? slots

// build_elf assembles a full executable image from a code blob whose entry is at
// the code's start. memsz extends to cover the fixed ARGS_TABLE.
build_elf :: proc(code: []u8) -> []u8 {
	code_vaddr := ELF_BASE + ELF_HEADERS
	entry := code_vaddr
	filesz := ELF_HEADERS + len(code)
	// memsz extends to cover the args table (zero-initialized tail of the segment).
	memsz := (ARGS_TABLE_VADDR - ELF_BASE) + 8 * ARGS_TABLE_MAX

	buf := make([dynamic]u8)

	// --- ELF header (64 bytes) ---
	append(&buf, 0x7F, 'E', 'L', 'F')
	append(&buf, 0x02, 0x01, 0x01, 0x00) // 64-bit, LE, version, System V ABI
	for _ in 0 ..< 8 do append(&buf, 0) // padding
	put16(&buf, 2) // e_type ET_EXEC
	put16(&buf, 0x3E) // e_machine x86-64
	put32(&buf, 1) // e_version
	put64(&buf, u64(entry)) // e_entry
	put64(&buf, ELF_HDR_SIZE) // e_phoff
	put64(&buf, 0) // e_shoff
	put32(&buf, 0) // e_flags
	put16(&buf, ELF_HDR_SIZE) // e_ehsize
	put16(&buf, ELF_PH_SIZE) // e_phentsize
	put16(&buf, 1) // e_phnum
	put16(&buf, 0) // e_shentsize
	put16(&buf, 0) // e_shnum
	put16(&buf, 0) // e_shstrndx

	// --- program header (56 bytes): one PT_LOAD, RWX ---
	put32(&buf, 1) // p_type PT_LOAD
	put32(&buf, 7) // p_flags R|W|X
	put64(&buf, 0) // p_offset
	put64(&buf, u64(ELF_BASE)) // p_vaddr
	put64(&buf, u64(ELF_BASE)) // p_paddr
	put64(&buf, u64(filesz)) // p_filesz
	put64(&buf, u64(memsz)) // p_memsz
	put64(&buf, 0x1000) // p_align

	// --- code ---
	for b in code do append(&buf, b)

	return buf[:]
}

// --- little-endian writers -------------------------------------------------

put16 :: proc(b: ^[dynamic]u8, v: u16) {
	append(b, u8(v), u8(v >> 8))
}
put32 :: proc(b: ^[dynamic]u8, v: u32) {
	append(b, u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24))
}
put64 :: proc(b: ^[dynamic]u8, v: u64) {
	for i in 0 ..< 8 do append(b, u8(v >> (uint(i) * 8)))
}
