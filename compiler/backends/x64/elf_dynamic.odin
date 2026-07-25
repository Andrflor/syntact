package x64_assembler

import bc "../../bytecode"

// ============================================================================
// DYNAMIC LINKING TABLES
//
// What `ld` would write into the file, written here directly — no external linker
// is invoked. The tables are a shopping list; the actual symbol resolution happens
// at STARTUP, performed by the dynamic loader:
//
//   1. the kernel reads PT_INTERP and launches the loader named there, handing it
//      this program (the loader is EXECUTED, not linked — it is an interpreter, and
//      no symbol of it is imported);
//   2. the loader reads PT_DYNAMIC, and for each DT_NEEDED opens that library —
//      searching by NAME (ld.so.cache, LD_LIBRARY_PATH, …), which is why no path to
//      a library is ever stored here;
//   3. it walks .rela.plt and writes each resolved address into its GOT slot;
//   4. it jumps to e_entry.
//
// A program with NO imports gets none of this: no PT_INTERP, no PT_DYNAMIC, and it
// stays the static, loader-free executable build_elf already produced. Dynamic
// linking is switched on by the source importing a library, never by default.
//
// DT_BIND_NOW makes the loader resolve everything up front, which is why there is no
// PLT here at all: the call goes straight through the GOT (see emit_foreign_call).
// ============================================================================

// The program interpreter. This is the ONE absolute path a dynamically linked
// executable cannot avoid: the bootstrap cannot be delegated, since something must
// start the chain, and that something is a literal open() by the kernel. It is a
// property of the target platform, not of any particular library — libraries
// themselves are named, never pathed.
DEFAULT_INTERP :: "/lib64/ld-linux-x86-64.so.2"

// ELF constants used below (see elf(5) / the System V gABI).
DT_NULL :: 0
DT_NEEDED :: 1
DT_PLTRELSZ :: 2
DT_PLTGOT :: 3
DT_HASH :: 4
DT_STRTAB :: 5
DT_SYMTAB :: 6
DT_STRSZ :: 10
DT_SYMENT :: 11
DT_PLTREL :: 20
DT_JMPREL :: 23
DT_BIND_NOW :: 24
DT_RELA :: 7
DT_RELASZ :: 8
DT_RELAENT :: 9

STT_FUNC :: 2
STB_GLOBAL :: 1
SHN_UNDEF :: 0
// R_X86_64_GLOB_DAT: "write the symbol's address at this location". The plain
// data relocation, applied unconditionally at load time — as opposed to
// R_X86_64_JUMP_SLOT, which belongs to the PLT's lazy-binding path.
R_X86_64_GLOB_DAT :: 6

SYM_ENTRY_SIZE :: 24 // sizeof(Elf64_Sym)
RELA_ENTRY_SIZE :: 24 // sizeof(Elf64_Rela)
DYN_ENTRY_SIZE :: 16 // sizeof(Elf64_Dyn)

// Dyn_Tables holds the assembled dynamic-linking sections plus the virtual address
// each was laid out at, so the .dynamic entries can point at them.
Dyn_Tables :: struct {
	interp:      []u8, // NUL-terminated interpreter path
	dynstr:      []u8,
	dynsym:      []u8,
	hash:        []u8,
	rela:        []u8,
	dyn_tab:     []u8,
	interp_addr: int,
	dynstr_addr: int,
	dynsym_addr: int,
	hash_addr:   int,
	rela_addr:   int,
	dyn_addr:    int,
}

// elf_hash is the original SysV symbol hash (still what DT_HASH indexes). The loader
// refuses a dynamic object without it, so it is written even though nothing here
// looks symbols up by hash.
elf_hash :: proc(name: string) -> u32 {
	h: u32 = 0
	for c in transmute([]u8)name {
		h = (h << 4) + u32(c)
		g := h & 0xF0000000
		if g != 0 do h ~= g >> 24
		h &= ~g
	}
	return h
}

// build_dyn_tables assembles every dynamic section for `imports`. `base_addr` is the
// virtual address the first table will live at; the tables are laid out contiguously
// from there in the order they are emitted.
//
// Symbol i in .dynsym corresponds to import i, and its relocation targets GOT slot i
// — the same index the emitter already used, so the two never need to agree on
// anything beyond ordering.
build_dyn_tables :: proc(imports: []bc.BC_Import, base_addr: int) -> Dyn_Tables {
	t: Dyn_Tables

	// --- .interp -----------------------------------------------------------
	interp := make([dynamic]u8)
	for c in transmute([]u8)string(DEFAULT_INTERP) do append(&interp, c)
	append(&interp, 0)
	t.interp = interp[:]

	// --- .dynstr: index 0 is the empty string, then each library and symbol ---
	dynstr := make([dynamic]u8)
	append(&dynstr, 0)
	lib_off := make(map[string]int)
	defer delete(lib_off)
	// One DT_NEEDED per DISTINCT library, in first-use order.
	lib_order := make([dynamic]string)
	defer delete(lib_order)
	for imp in imports {
		if imp.lib not_in lib_off {
			lib_off[imp.lib] = len(dynstr)
			append(&lib_order, imp.lib)
			for c in transmute([]u8)imp.lib do append(&dynstr, c)
			append(&dynstr, 0)
		}
	}
	sym_off := make([]int, len(imports))
	defer delete(sym_off)
	for imp, i in imports {
		sym_off[i] = len(dynstr)
		for c in transmute([]u8)imp.symbol do append(&dynstr, c)
		append(&dynstr, 0)
	}
	t.dynstr = dynstr[:]

	// --- .dynsym: a null entry, then one undefined symbol per import --------
	// st_shndx = SHN_UNDEF is what marks a symbol as IMPORTED: defined elsewhere,
	// to be resolved by the loader.
	dynsym := make([dynamic]u8)
	for _ in 0 ..< SYM_ENTRY_SIZE do append(&dynsym, 0) // index 0: reserved null entry
	for _, i in imports {
		put32(&dynsym, u32(sym_off[i])) // st_name
		append(&dynsym, u8(STB_GLOBAL << 4 | STT_FUNC)) // st_info: global function
		append(&dynsym, 0) // st_other
		put16(&dynsym, u16(SHN_UNDEF)) // st_shndx: undefined → imported
		put64(&dynsym, 0) // st_value
		put64(&dynsym, 0) // st_size
	}
	t.dynsym = dynsym[:]

	// --- .hash: SysV hash table over .dynsym -------------------------------
	// One bucket per symbol keeps it simple; correctness does not depend on the
	// bucket count, only on the chains being walkable.
	nsym := len(imports) + 1
	nbucket := nsym
	buckets := make([]u32, nbucket)
	defer delete(buckets)
	chain := make([]u32, nsym)
	defer delete(chain)
	for imp, i in imports {
		sym_index := u32(i + 1) // symbol 0 is the null entry
		b := elf_hash(imp.symbol) % u32(nbucket)
		// Prepend onto the bucket's chain.
		chain[sym_index] = buckets[b]
		buckets[b] = sym_index
	}
	hash := make([dynamic]u8)
	put32(&hash, u32(nbucket))
	put32(&hash, u32(nsym))
	for b in buckets do put32(&hash, b)
	for c in chain do put32(&hash, c)
	t.hash = hash[:]

	// --- .rela.plt: "write symbol i's address into GOT slot i" --------------
	rela := make([dynamic]u8)
	for _, i in imports {
		put64(&rela, u64(GOT_VADDR + 8 * i)) // r_offset: the GOT slot to patch
		// r_info: symbol index in the high 32 bits, relocation type in the low.
		put64(&rela, u64(u64(i + 1) << 32 | u64(R_X86_64_GLOB_DAT)))
		put64(&rela, 0) // r_addend
	}
	t.rela = rela[:]

	// --- lay the tables out, in emission order, to compute their addresses ---
	addr := base_addr
	t.interp_addr = addr; addr += len(t.interp)
	// 8-align each table the loader will read as words.
	addr = (addr + 7) & ~int(7)
	t.dynstr_addr = addr; addr += len(t.dynstr)
	addr = (addr + 7) & ~int(7)
	t.dynsym_addr = addr; addr += len(t.dynsym)
	addr = (addr + 7) & ~int(7)
	t.hash_addr = addr; addr += len(t.hash)
	addr = (addr + 7) & ~int(7)
	t.rela_addr = addr; addr += len(t.rela)
	addr = (addr + 7) & ~int(7)
	t.dyn_addr = addr

	// --- .dynamic: the index of everything above ----------------------------
	dyn_tab := make([dynamic]u8)
	put_dyn :: proc(b: ^[dynamic]u8, tag: int, val: u64) {
		put64(b, u64(tag))
		put64(b, val)
	}
	// One DT_NEEDED per distinct library — the NAME only, never a path.
	for lib in lib_order {
		put_dyn(&dyn_tab, DT_NEEDED, u64(lib_off[lib]))
	}
	put_dyn(&dyn_tab, DT_STRTAB, u64(t.dynstr_addr))
	put_dyn(&dyn_tab, DT_STRSZ, u64(len(t.dynstr)))
	put_dyn(&dyn_tab, DT_SYMTAB, u64(t.dynsym_addr))
	put_dyn(&dyn_tab, DT_SYMENT, SYM_ENTRY_SIZE)
	put_dyn(&dyn_tab, DT_HASH, u64(t.hash_addr))
	// DT_RELA, not DT_JMPREL: these are ORDINARY relocations, which the loader always
	// applies at startup. Declaring them as PLT relocations (DT_JMPREL) would tie them
	// to the lazy-binding machinery — a PLT stub per symbol and a resolver trampoline —
	// none of which exists here, since the call goes straight through the GOT.
	put_dyn(&dyn_tab, DT_RELA, u64(t.rela_addr))
	put_dyn(&dyn_tab, DT_RELASZ, u64(len(t.rela)))
	put_dyn(&dyn_tab, DT_RELAENT, RELA_ENTRY_SIZE)
	put_dyn(&dyn_tab, DT_NULL, 0)
	t.dyn_tab = dyn_tab[:]

	return t
}
