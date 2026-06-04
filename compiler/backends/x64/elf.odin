package x64_assembler

import "core:os"
import bc "../../bytecode"

// emit_executable turns a lowered program into an executable file on disk.
emit_executable :: proc(prog: ^bc.BC_Program, path: string) -> string {
	out, msg := emit_x64(prog)
	if msg != "" do return msg
	image := build_elf(out.code, out.rodata)
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
// Produces a static ET_EXEC: ELF header + one PT_LOAD program header + the
// runtime stub + the program's code. Everything loads at BASE; the entry point
// is the stub, which:
//   1. reads argc/argv from the initial stack,
//   2. parses argv[1..] as signed integers via an inline atoi,
//   3. stores each into ARGS_TABLE (a fixed BSS-like region in the mapped image),
//   4. falls through into the program body (which reads ARGS_TABLE[slot]).
// The program ends with an exit syscall carrying the result.
//
// A minimal SECTION HEADER TABLE (.text, optional .rodata, .shstrtab) is appended
// at the end of the file — the kernel ignores it (it loads segments, not
// sections), but it makes the binary inspectable with `objdump -d`, gdb, etc.
//
// Layout decision: ?? arguments live at a FIXED absolute address (ARGS_TABLE)
// rather than relative to a call frame — simplest unambiguous contract for the
// emitter's bc.BC_Load_Arg (it reads [ARGS_TABLE + 8*slot]).
// ============================================================================

ELF_BASE :: 0x400000
ELF_HDR_SIZE :: 64
ELF_PH_SIZE :: 56
ELF_SH_SIZE :: 64 // size of one section header entry
// The file is laid out: [ELF header][program header][rodata][code][shstrtab][shdrs].
// Code virtual address = BASE + headers. ARGS_TABLE sits in extra mapped space.
ELF_HEADERS :: ELF_HDR_SIZE + ELF_PH_SIZE

// ARGS_TABLE is at a FIXED absolute address well past any realistic code size,
// so the emitter knows it before emitting (no chicken-and-egg with code length).
// The PT_LOAD's memsz extends to cover it (zero-filled tail).
ARGS_TABLE_VADDR :: ELF_BASE + 0x100000 // 1 MiB into the image
ARGS_TABLE_MAX :: 64 // up to 64 ?? slots

// build_elf assembles a full executable image:
//   [ELF header][program header][rodata][code][.shstrtab][section headers]
// The entry point is the code (right after rodata). The loadable segment covers
// rodata+code; the section table sits past it (not loaded, just for tooling).
build_elf :: proc(code: []u8, rodata: []u8) -> []u8 {
	has_rodata := len(rodata) > 0

	rodata_off := ELF_HEADERS
	code_off := rodata_off + len(rodata)
	entry := ELF_BASE + code_off
	filesz := code_off + len(code) // loadable bytes: headers + rodata + code
	memsz := (ARGS_TABLE_VADDR - ELF_BASE) + 8 * ARGS_TABLE_MAX

	// --- .shstrtab: the section-name string table. Offset 0 is the empty name. ---
	// Names: "\0.text\0.rodata\0.shstrtab\0" (rodata entry present only if needed).
	shstr := make([dynamic]u8)
	append(&shstr, 0)
	name_text := len(shstr); append_cstr(&shstr, ".text")
	name_rodata := 0
	if has_rodata {name_rodata = len(shstr); append_cstr(&shstr, ".rodata")}
	name_shstrtab := len(shstr); append_cstr(&shstr, ".shstrtab")

	shstr_off := code_off + len(code)
	// Section headers go after .shstrtab, 8-byte aligned for cleanliness.
	shoff := align8(shstr_off + len(shstr))
	// Section count: null + .text + [.rodata] + .shstrtab.
	shnum := has_rodata ? 4 : 3
	shstrndx := shnum - 1 // .shstrtab is last

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
	put64(&buf, u64(shoff)) // e_shoff
	put32(&buf, 0) // e_flags
	put16(&buf, ELF_HDR_SIZE) // e_ehsize
	put16(&buf, ELF_PH_SIZE) // e_phentsize
	put16(&buf, 1) // e_phnum
	put16(&buf, ELF_SH_SIZE) // e_shentsize
	put16(&buf, u16(shnum)) // e_shnum
	put16(&buf, u16(shstrndx)) // e_shstrndx

	// --- program header (56 bytes): one PT_LOAD, RWX ---
	put32(&buf, 1) // p_type PT_LOAD
	put32(&buf, 7) // p_flags R|W|X
	put64(&buf, 0) // p_offset
	put64(&buf, u64(ELF_BASE)) // p_vaddr
	put64(&buf, u64(ELF_BASE)) // p_paddr
	put64(&buf, u64(filesz)) // p_filesz
	put64(&buf, u64(memsz)) // p_memsz
	put64(&buf, 0x1000) // p_align

	// --- rodata, then code ---
	for b in rodata do append(&buf, b)
	for b in code do append(&buf, b)

	// --- .shstrtab contents ---
	for b in shstr do append(&buf, b)
	// pad to shoff (8-byte alignment)
	for len(buf) < shoff do append(&buf, 0)

	// --- section header table ---
	// SHT_* / SHF_* constants used below:
	SHT_NULL :: 0
	SHT_PROGBITS :: 1
	SHT_STRTAB :: 3
	SHF_ALLOC :: 0x2
	SHF_EXECINSTR :: 0x4

	// [0] null section (required).
	put_shdr(&buf, 0, SHT_NULL, 0, 0, 0, 0, 0, 0, 0, 0)
	// [1] .text — the code, allocatable + executable.
	put_shdr(
		&buf, u32(name_text), SHT_PROGBITS, SHF_ALLOC | SHF_EXECINSTR,
		u64(entry), u64(code_off), u64(len(code)), 0, 0, 16, 0,
	)
	if has_rodata {
		// [2] .rodata — the string literals, allocatable read-only.
		put_shdr(
			&buf, u32(name_rodata), SHT_PROGBITS, SHF_ALLOC,
			u64(ELF_BASE + rodata_off), u64(rodata_off), u64(len(rodata)), 0, 0, 1, 0,
		)
	}
	// [last] .shstrtab — the section-name string table (not allocated).
	put_shdr(
		&buf, u32(name_shstrtab), SHT_STRTAB, 0,
		0, u64(shstr_off), u64(len(shstr)), 0, 0, 1, 0,
	)

	return buf[:]
}

// put_shdr writes one 64-byte ELF64 section header.
put_shdr :: proc(
	b: ^[dynamic]u8,
	name: u32, type: u32, flags: u64, addr: u64, offset: u64,
	size: u64, link: u32, info: u32, addralign: u64, entsize: u64,
) {
	put32(b, name) // sh_name
	put32(b, type) // sh_type
	put64(b, flags) // sh_flags
	put64(b, addr) // sh_addr
	put64(b, offset) // sh_offset
	put64(b, size) // sh_size
	put32(b, link) // sh_link
	put32(b, info) // sh_info
	put64(b, addralign) // sh_addralign
	put64(b, entsize) // sh_entsize
}

append_cstr :: proc(b: ^[dynamic]u8, s: string) {
	for c in transmute([]u8)s do append(b, c)
	append(b, 0)
}

align8 :: proc(n: int) -> int {
	return (n + 7) & ~int(7)
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
