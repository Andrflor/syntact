package x64_assembler

import "core:os"
import bc "../../bytecode"

// emit_executable turns a lowered program into an executable file on disk.
emit_executable :: proc(prog: ^bc.BC_Program, path: string) -> string {
	out, msg := emit_x64(prog)
	if msg != "" do return msg
	defer delete(out.code)
	defer delete(out.rodata)
	image := build_elf(out.code, out.rodata, prog.imports[:], out.scratch_size)
	defer delete(image)
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

// A dynamically linked image needs two more program headers, PT_INTERP and
// PT_DYNAMIC, which shifts everything that follows. Both the ELF writer and the
// emitter (for .rodata addresses) must agree on the size, so it is derived here from
// the one fact that decides it: whether the program imports anything.
elf_headers_size :: proc(import_count: int) -> int {
	if import_count == 0 do return ELF_HEADERS
	return ELF_HDR_SIZE + 3 * ELF_PH_SIZE
}

// ARGS_TABLE is at a FIXED absolute address well past any realistic code size,
// so the emitter knows it before emitting (no chicken-and-egg with code length).
// The PT_LOAD's memsz extends to cover it (zero-filled tail).
ARGS_TABLE_VADDR :: ELF_BASE + 0x100000 // 1 MiB into the image
ARGS_TABLE_MAX :: 64 // up to 64 ?? slots

// The GOT for imported symbols, at a FIXED absolute address for the same reason as
// ARGS_TABLE: the emitter must know a slot's address before the tables are laid out.
// Slot i (i = index into BC_Program.imports) lives at GOT_VADDR + 8*i, and is filled
// by the dynamic loader at startup from the .rela.plt relocations.
//
// It sits INSIDE the single RWX PT_LOAD, right after the args table, so no second
// (writable) segment is needed — one less alignment constraint to satisfy. Less
// hardened than a proper RELRO layout, deliberately: correctness first.
// The first THREE entries of a PLT GOT are reserved by the ABI (the loader writes
// its own bookkeeping there: the .dynamic address, the link_map, and the resolver
// entry point). DT_PLTGOT must point at that reserved header, so the symbol slots
// start after it.
GOT_RESERVED :: 3
GOT_BASE_VADDR :: ARGS_TABLE_VADDR + 8 * ARGS_TABLE_MAX
GOT_VADDR :: GOT_BASE_VADDR + 8 * GOT_RESERVED
GOT_MAX :: 128 // up to 128 distinct imported symbols

// Materialized aggregates occupy a zero-filled image tail. The bytecode refers
// only to abstract function-local slots; the x64 image assigns each function a
// disjoint range beginning here.
SCRATCH_VADDR :: GOT_VADDR + 8 * GOT_MAX + 0x1000

// build_elf assembles a full executable image:
//   [ELF header][program header][rodata][code][.shstrtab][section headers]
// The entry point is the code (right after rodata). The loadable segment covers
// rodata+code; the section table sits past it (not loaded, just for tooling).
build_elf :: proc(code: []u8, rodata: []u8, imports: []bc.BC_Import = nil, scratch_size: int = 0) -> []u8 {
	has_rodata := len(rodata) > 0
	// Dynamic linking is driven purely by whether the source imported anything: with
	// no imports the image below is byte-for-byte the static one.
	is_dynamic := len(imports) > 0
	headers := elf_headers_size(len(imports))

	rodata_off := headers
	code_off := rodata_off + len(rodata)
	entry := ELF_BASE + code_off

	// The dynamic tables follow the code, and are part of the loaded segment (the
	// loader reads them at run time, so they must be mapped).
	dyn: Dyn_Tables
	dyn_off := code_off + len(code)
	dyn_end := dyn_off
	if is_dynamic {
		dyn = build_dyn_tables(imports, ELF_BASE + dyn_off)
		// The table addresses were laid out from ELF_BASE + dyn_off, so the end of the
		// last table gives the file extent.
		dyn_end = dyn.dyn_addr - ELF_BASE + len(dyn.dyn_tab)
	}
	defer if is_dynamic do delete_dyn_tables(&dyn)

	filesz := dyn_end // loadable bytes: headers + rodata + code + dynamic tables
	// memsz additionally covers the zero-filled args table and GOT, which have no
	// file backing — the loader writes the GOT before the program runs.
	memsz := (GOT_VADDR - ELF_BASE) + 8 * GOT_MAX
	scratch_end := SCRATCH_VADDR - ELF_BASE + scratch_size
	if scratch_end > memsz do memsz = scratch_end

	// --- .shstrtab: the section-name string table. Offset 0 is the empty name. ---
	// Names: "\0.text\0.rodata\0.shstrtab\0" (rodata entry present only if needed).
	shstr := make([dynamic]u8)
	defer delete(shstr)
	append(&shstr, 0)
	name_text := len(shstr); append_cstr(&shstr, ".text")
	name_rodata := 0
	if has_rodata {name_rodata = len(shstr); append_cstr(&shstr, ".rodata")}
	name_shstrtab := len(shstr); append_cstr(&shstr, ".shstrtab")

	shstr_off := dyn_end
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
	put16(&buf, u16(is_dynamic ? 3 : 1)) // e_phnum
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

	if is_dynamic {
		// PT_INTERP — the kernel reads this FIRST and launches the interpreter named
		// here, which is what makes the whole loader mechanism start.
		put32(&buf, 3) // p_type PT_INTERP
		put32(&buf, 4) // p_flags R
		put64(&buf, u64(dyn.interp_addr - ELF_BASE)) // p_offset
		put64(&buf, u64(dyn.interp_addr)) // p_vaddr
		put64(&buf, u64(dyn.interp_addr)) // p_paddr
		put64(&buf, u64(len(dyn.interp))) // p_filesz — includes the NUL
		put64(&buf, u64(len(dyn.interp))) // p_memsz
		put64(&buf, 1) // p_align

		// PT_DYNAMIC — the index the loader walks to find everything else.
		put32(&buf, 2) // p_type PT_DYNAMIC
		put32(&buf, 6) // p_flags R|W
		put64(&buf, u64(dyn.dyn_addr - ELF_BASE)) // p_offset
		put64(&buf, u64(dyn.dyn_addr)) // p_vaddr
		put64(&buf, u64(dyn.dyn_addr)) // p_paddr
		put64(&buf, u64(len(dyn.dyn_tab))) // p_filesz
		put64(&buf, u64(len(dyn.dyn_tab))) // p_memsz
		put64(&buf, 8) // p_align

		// The header block is a fixed size, so nothing to pad: rodata starts right
		// after the third program header (see elf_headers_size).
	}

	// --- rodata, then code ---
	for b in rodata do append(&buf, b)
	for b in code do append(&buf, b)

	// --- dynamic tables, at the offsets build_dyn_tables laid them out at ---
	if is_dynamic {
		put_table :: proc(buf: ^[dynamic]u8, addr: int, data: []u8) {
			// Pad to the table's own aligned offset, then write it.
			for len(buf) < addr - ELF_BASE do append(buf, 0)
			for b in data do append(buf, b)
		}
		put_table(&buf, dyn.interp_addr, dyn.interp)
		put_table(&buf, dyn.dynstr_addr, dyn.dynstr)
		put_table(&buf, dyn.dynsym_addr, dyn.dynsym)
		put_table(&buf, dyn.hash_addr, dyn.hash)
		put_table(&buf, dyn.rela_addr, dyn.rela)
		put_table(&buf, dyn.dyn_addr, dyn.dyn_tab)
	}

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
