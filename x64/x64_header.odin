package x64_assembler

// === ELF FILE WRITING ===
write_elf :: proc() {
	write(
		[]u8 {
			0x7F,
			'E',
			'L',
			'F', // Magic
			0x02, // 64-bit
			0x01, // little-endian
			0x01, // ELF version
			0x00, // OS ABI: UNIX - System V
			0x00, // ABI Version
			0x00,
			0x00,
			0x00,
			0x00,
			0x00,
			0x00,
			0x00, // padding
			0x02,
			0x00, // e_type: ET_EXEC (2)
			0x3E,
			0x00, // e_machine: EM_X86_64 (62)
			0x01,
			0x00,
			0x00,
			0x00, // e_version: EV_CURRENT (1)

			// Entry point address (correctly formatted for 64-bit)
			0x78,
			0x00,
			0x40,
			0x00, // e_entry (lower 32 bits)
			0x00,
			0x00,
			0x00,
			0x00, // e_entry (upper 32 bits)

			// Program header offset (e_phoff)
			0x40,
			0x00,
			0x00,
			0x00, // Program header offset (64 bytes)
			0x00,
			0x00,
			0x00,
			0x00, // Upper 32 bits (zero for small files)

			// Section header offset (e_shoff)
			0x00,
			0x00,
			0x00,
			0x00, // Section header offset (unused in this minimal example)
			0x00,
			0x00,
			0x00,
			0x00, // Upper 32 bits
			0x00,
			0x00,
			0x00,
			0x00, // e_flags (processor-specific flags, usually 0)
			0x40,
			0x00, // e_ehsize (64 bytes - size of ELF header)
			0x38,
			0x00, // e_phentsize (56 bytes - size of program header entry)
			0x01,
			0x00, // e_phnum (1 program header)
			0x40,
			0x00, // e_shentsize (64 bytes - size of section header entry)
			0x00,
			0x00, // e_shnum (0 section headers)
			0x00,
			0x00, // e_shstrndx (no section header string table)
		},
	)
}
