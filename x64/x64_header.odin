package x64_assembler

// === ELF FILE WRITING ===
write_elf :: proc(code: []u8) {
	write([]u8 {
		0x7F,
		'E',
		'L',
		'F', // Magic number
		2,
		1,
		1,
		0, // 64-bit, little-endian, ELF version
		0,
		0,
		0,
		0,
		0,
		0,
		0,
		0, // Padding
		2,
		0,
		0x3E,
		0, // Executable file, x86-64
		1,
		0,
		0,
		0, // ELF version
		0x78,
		0x00,
		0x40,
		0, // Entry point
		0x40,
		0,
		0,
		0, // Program header table offset
		0,
		0,
		0,
		0, // Section header table offset
		0,
		0,
		0,
		0, // Flags
		0x40,
		0,
		0x38,
		0, // Header size, program header entry size
		1,
		0,
		0,
		0, // Number of program headers
		0,
		0,
		0,
		0, // Number of section headers
	});
}
