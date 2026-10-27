package code_c

import code ".."
import "core:fmt"
import "core:os"
import "core:strings"

// THE PROGRAM AS C
//
// The code of a program (code/) as one C file: the reference a C compiler's own
// optimizations are measured against. The structure is kept — a match is a chain
// of if, a loop a for (;;) that an Again continues — and so are the facts. An
// integer is an int64_t, as on the machine; what the C compiler cannot see itself
// — the bounds of a parameter, an input, what a call gives back, the parameters of
// a loop — is said with ASSUME. An operation whose result the kernel proved in
// int64_t is the C operation; any other wraps, as the machine does. A symbol is
// declared under a name of its own, bound to the library's by an asm label, so
// that a header never declares it otherwise.
//
// The program reads its inputs from the command line, each in the layout it is
// written with, then ends with its value: an integer is the exit code; a float,
// written with six decimals, and a text, written, end with a newline and the exit
// code 0.

Writer :: struct {
	p:       ^code.Program,
	b:       strings.Builder,
	symbols: []string, // the C name of each import
	funcs:   []string, // the C name of each function
	f:       ^code.Func,
	defs:    []code.Inst, // in f: the instruction that defines each value
	reads:   []int, // in f: how many times each value is read
	loops:   [dynamic][]code.Value, // the parameters of the loops the code is in, innermost last
	depth:   int,
}

// write: the program as C, at path; "" when written.
write :: proc(p: ^code.Program, path: string) -> string {
	text, err := source(p)
	if err != "" do return err
	if os.write_entire_file(path, transmute([]u8)text) != nil do return "the C file cannot be written"
	return ""
}

// executable: the program as C at path.c, compiled at path by the C compiler —
// $CC, or cc — with -O3, every warning an error.
executable :: proc(p: ^code.Program, path: string) -> string {
	file := fmt.tprintf("%s.c", path)
	if msg := write(p, file); msg != "" do return msg
	cc := os.get_env("CC", context.allocator)
	command := make([dynamic]string)
	append(&command, cc != "" ? cc : "cc", "-std=c11", "-O3", "-Wall", "-Wextra", "-Werror", file, "-o", path)
	for lib in libraries(p) do append(&command, fmt.tprintf("-l%s", lib))
	state, _, stderr, failed := os.process_exec(os.Process_Desc{command = command[:]}, context.allocator)
	if failed != nil do return fmt.tprintf("the C compiler does not run: %v", failed)
	if state.exit_code != 0 do return fmt.tprintf("the C compiler fails:\n%s", string(stderr))
	return ""
}

// libraries: what -l names, for each library a symbol comes from: libm.so.6 is m;
// the C library is always linked.
libraries :: proc(p: ^code.Program) -> []string {
	libs := make([dynamic]string)
	for imp in p.imports {
		name := imp.lib
		if i := strings.index(name, ".so"); i >= 0 do name = name[:i]
		name = strings.trim_prefix(name, "lib")
		known := name == "c"
		for x in libs do known ||= x == name
		if !known do append(&libs, name)
	}
	return libs[:]
}

// source: the program as C.
source :: proc(p: ^code.Program) -> (string, string) {
	w := Writer{p = p, b = strings.builder_make()}
	w.symbols = make([]string, len(p.imports))
	for imp, i in p.imports {
		w.symbols[i] = fmt.tprintf("sym_%s", imp.symbol)
		for other in p.imports[:i] do if other.symbol == imp.symbol do w.symbols[i] = fmt.tprintf("sym_%s_%d", imp.symbol, i)
	}
	w.funcs = make([]string, len(p.funcs))
	w.funcs[0] = "program"
	for f, i in p.funcs[1:] do w.funcs[i + 1] = fmt.tprintf("fn_%s_%d", f.name, i + 1)
	prelude(&w)
	vectors(&w)
	for imp, i in p.imports {
		args := make([dynamic]string)
		for a in imp.args do append(&args, C_TYPES[a])
		if len(args) == 0 do append(&args, "void")
		fmt.sbprintfln(&w.b, "extern %s %s(%s) __asm__(\"%s\");", answer_type(imp), w.symbols[i], strings.join(args[:], ", "), imp.symbol)
	}
	if len(p.imports) > 0 do strings.write_string(&w.b, "\n")
	for f, i in p.funcs do fmt.sbprintfln(&w.b, "%s;", signature(&w, f, i))
	if len(p.inputs) > 0 do fmt.sbprintfln(&w.b, "static int64_t inputs[%d];", len(p.inputs))
	for f, i in p.funcs {
		strings.write_string(&w.b, "\n")
		if msg := function(&w, f, i); msg != "" do return "", msg
	}
	entry(&w)
	return strings.to_string(w.b), ""
}

C_TYPES := [code.Machine]string {
	.None = "void",
	.Int  = "int64_t",
	.Real = "double",
	.Text = "const char *",
}

// type_of: the C type of a value: of its machine, or a vector of it, in the
// vector extension of the C compiler.
type_of :: proc(k: code.Kind) -> string {
	if k.lanes == 0 do return C_TYPES[k.machine]
	return fmt.tprintf("%s%d", k.machine == .Real ? "f64x" : "i64x", k.lanes)
}

// vectors: the types of the vectors of the program.
vectors :: proc(w: ^Writer) {
	seen := make(map[code.Kind]bool)
	for f in w.p.funcs do for k in f.kinds {
		if k.lanes == 0 do continue
		key := code.Kind{machine = k.machine, lanes = k.lanes}
		if key in seen do continue
		seen[key] = true
		if k.machine == .Real {
			fmt.sbprintfln(&w.b, "typedef double f64x%d __attribute__((vector_size(%d)));", k.lanes, 8 * k.lanes)
		} else {
			fmt.sbprintfln(&w.b, "typedef int64_t i64x%d __attribute__((vector_size(%d)));", k.lanes, 8 * k.lanes)
			fmt.sbprintfln(&w.b, "typedef uint64_t u64x%d __attribute__((vector_size(%d)));", k.lanes, 8 * k.lanes)
		}
	}
	if len(seen) > 0 do strings.write_string(&w.b, "\n")
}

prelude :: proc(w: ^Writer) {
	libs := libraries(w.p)
	strings.write_string(&w.b, "// Written by syntact (code/c).\n")
	fmt.sbprintfln(&w.b, "// cc -O3 FILE.c -o FILE%s", strings.concatenate({len(libs) > 0 ? " -l" : "", strings.join(libs, " -l")}))
	strings.write_string(&w.b, `
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

// what the kernel proved, said to the C compiler
#define ASSUME(c) do { if (!(c)) __builtin_unreachable(); } while (0)

// the operations of the machine, which wrap
static inline int64_t wrap_add(int64_t a, int64_t b) { return (int64_t)((uint64_t)a + (uint64_t)b); }
static inline int64_t wrap_sub(int64_t a, int64_t b) { return (int64_t)((uint64_t)a - (uint64_t)b); }
static inline int64_t wrap_mul(int64_t a, int64_t b) { return (int64_t)((uint64_t)a * (uint64_t)b); }
static inline int64_t wrap_neg(int64_t a) { return (int64_t)(0 - (uint64_t)a); }
static inline int64_t wrap_shl(int64_t a, int64_t b) { return (int64_t)((uint64_t)a << (b & 63)); }

// a power, b ≥ 0, by squaring
static inline int64_t wrap_pow(int64_t a, int64_t b) {
    uint64_t out = 1, x = (uint64_t)a;
    for (; b > 0; b >>= 1, x *= x) if (b & 1) out *= x;
    return (int64_t)out;
}
static inline double real_pow(double a, int64_t b) {
    double out = 1.0;
    for (; b > 0; b >>= 1, a *= a) if (b & 1) out *= a;
    return out;
}

`)
}

// answer_bounds: the integers the C type of what a symbol gives back holds.
answer_bounds :: proc(imp: code.Import) -> code.Bounds {
	if imp.result != .Int || imp.result_bits >= 64 do return INT64
	bits := uint(imp.result_bits)
	if imp.result_signed do return {-(i128(1) << (bits - 1)), i128(1) << (bits - 1) - 1}
	return {0, i128(1) << bits - 1}
}

// answer_type: the C type of what a symbol gives back: the bits it gives.
answer_type :: proc(imp: code.Import) -> string {
	if imp.result != .Int do return C_TYPES[imp.result]
	return fmt.tprintf("%sint%d_t", imp.result_signed ? "" : "u", imp.result_bits)
}

signature :: proc(w: ^Writer, f: ^code.Func, index: int) -> string {
	params := make([dynamic]string)
	for m, i in f.params do append(&params, fmt.tprintf("%s v%d", C_TYPES[m], i))
	if len(params) == 0 do append(&params, "void")
	pure := f.pure && index > 0 && f.result != .None ? "__attribute__((pure)) " : ""
	return fmt.tprintf("static %s%s %s(%s)", pure, C_TYPES[f.result], w.funcs[index], strings.join(params[:], ", "))
}

// --- a function ---

function :: proc(w: ^Writer, f: ^code.Func, index: int) -> string {
	w.f = f
	w.defs = make([]code.Inst, len(f.kinds))
	w.reads = make([]int, len(f.kinds))
	survey(w, f.body)
	fmt.sbprintfln(&w.b, "%s {{", signature(w, f, index))
	w.depth = 1
	for _, i in f.params {
		x := code.Value(i)
		if w.reads[x] == 0 do line(w, "(void)v%d;", i)
		else do assume(w, x)
	}
	if msg := body(w, f.body); msg != "" do return msg
	if f.body.value != code.NONE do line(w, "return %s;", name(w, f.body.value))
	strings.write_string(&w.b, "}\n")
	return ""
}

// survey: the instruction that defines each value, and how many times each is read.
survey :: proc(w: ^Writer, b: code.Body) {
	read :: proc(w: ^Writer, x: code.Value) {if x != code.NONE do w.reads[x] += 1}
	for inst in b.insts {
		switch i in inst {
		case code.Const:
			w.defs[i.dst] = inst
		case code.Real_Const:
			w.defs[i.dst] = inst
		case code.Text_Const:
			w.defs[i.dst] = inst
		case code.Input:
			w.defs[i.dst] = inst
		case code.Unary:
			w.defs[i.dst] = inst
			read(w, i.a)
		case code.Binary:
			w.defs[i.dst] = inst
			read(w, i.a)
			read(w, i.b)
		case code.In:
			w.defs[i.dst] = inst
			read(w, i.x)
		case code.Splat:
			w.defs[i.dst] = inst
			read(w, i.a)
		case code.Lanes:
			w.defs[i.dst] = inst
		case code.Reduce:
			w.defs[i.dst] = inst
			read(w, i.a)
		case code.Narrow:
			w.defs[i.dst] = inst
			read(w, i.src)
		case code.Foreign:
			if i.dst != code.NONE do w.defs[i.dst] = inst
			for a in i.args do read(w, a)
		case code.Call:
			if i.dst != code.NONE do w.defs[i.dst] = inst
			for a in i.args do read(w, a)
		case code.Match:
			read(w, i.target)
			for arm in i.arms do survey(w, arm.body)
		case code.Loop:
			for x in i.init do read(w, x)
			survey(w, i.body)
		case code.Again:
			for a in i.args do read(w, a)
		}
	}
	read(w, b.value)
}

line :: proc(w: ^Writer, format: string, args: ..any) {
	for _ in 0 ..< w.depth do strings.write_string(&w.b, "    ")
	fmt.sbprintfln(&w.b, format, ..args)
}

// name: how C reads a value: a constant is written where it is read, a narrowing
// is the value it narrows.
name :: proc(w: ^Writer, x: code.Value) -> string {
	#partial switch d in w.defs[x] {
	case code.Const:
		return int_literal(i128(d.value))
	case code.Real_Const:
		return real_literal(d.value)
	case code.Text_Const:
		return text_literal(w.p.texts[d.text])
	case code.Narrow:
		return name(w, d.src)
	}
	return fmt.tprintf("v%d", int(x))
}

// declare: the value takes the expression; a value no one reads is not kept.
declare :: proc(w: ^Writer, x: code.Value, expr: string) {
	if w.reads[x] == 0 do return
	line(w, "%s v%d = %s;", type_of(w.f.kinds[x]), int(x), expr)
}

// assume: the bounds the kernel proved of an integer, when they say more than its
// C type: int64_t, or the type a symbol gives it back in. Bounds beyond int64_t
// are not said: there the int64_t holds the bits of the value, not the value.
assume :: proc(w: ^Writer, x: code.Value, given := INT64) {
	if w.f.kinds[x].machine != .Int || !proven(w, x) do return
	b := w.f.kinds[x].bounds
	if b.lo <= given.lo && given.hi <= b.hi do return
	v := name(w, x)
	switch {
	case b.lo == b.hi:
		line(w, "ASSUME(%s == %s);", v, int_literal(b.lo))
	case b.lo == INT64.lo:
		line(w, "ASSUME(%s <= %s);", v, int_literal(b.hi))
	case b.hi == INT64.hi:
		line(w, "ASSUME(%s >= %s);", v, int_literal(b.lo))
	case:
		line(w, "ASSUME(%s >= %s && %s <= %s);", v, int_literal(b.lo), v, int_literal(b.hi))
	}
}

INT64 :: code.Bounds{i128(min(i64)), i128(max(i64))}

body :: proc(w: ^Writer, b: code.Body) -> string {
	f := w.f
	for inst in b.insts {
		switch i in inst {
		case code.Const, code.Real_Const, code.Text_Const, code.Narrow:
		// written where they are read
		case code.Input:
			declare(w, i.dst, fmt.tprintf("inputs[%d]", i.slot))
			if w.reads[i.dst] > 0 do assume(w, i.dst)
		case code.Unary:
			declare(w, i.dst, unary(w, i))
		case code.Binary:
			expr, msg := binary(w, i)
			if msg != "" do return msg
			declare(w, i.dst, expr)
		case code.Splat:
			parts := make([]string, f.kinds[i.dst].lanes)
			for &x in parts do x = name(w, i.a)
			declare(w, i.dst, fmt.tprintf("(%s){%s}", type_of(f.kinds[i.dst]), strings.join(parts, ", ")))
		case code.Lanes:
			parts := make([]string, len(i.values))
			for x, k in i.values do parts[k] = int_literal(i128(x))
			declare(w, i.dst, fmt.tprintf("(%s){%s}", type_of(f.kinds[i.dst]), strings.join(parts, ", ")))
		case code.Reduce:
			declare(w, i.dst, reduce(w, i))
			if w.reads[i.dst] > 0 do assume(w, i.dst)
		case code.In:
			declare(w, i.dst, cover_test(w, name(w, i.x), f.kinds[i.x].machine, i.cover))
		case code.Foreign:
			args := make([dynamic]string)
			for a in i.args do append(&args, name(w, a))
			call := fmt.tprintf("%s(%s)", w.symbols[i.symbol], strings.join(args[:], ", "))
			if i.dst == code.NONE || w.reads[i.dst] == 0 {
				line(w, "%s;", call)
				continue
			}
			declare(w, i.dst, call)
			assume(w, i.dst, answer_bounds(w.p.imports[i.symbol]))
		case code.Call:
			args := make([dynamic]string)
			for a in i.args do append(&args, name(w, a))
			call := fmt.tprintf("%s(%s)", w.funcs[i.func], strings.join(args[:], ", "))
			if i.dst == code.NONE || w.reads[i.dst] == 0 {
				line(w, "%s;", call)
				continue
			}
			declare(w, i.dst, call)
			assume(w, i.dst)
		case code.Match:
			if i.dst != code.NONE do line(w, "%s v%d;", type_of(f.kinds[i.dst]), int(i.dst))
			target := name(w, i.target)
			for arm, n in i.arms {
				last := n == len(i.arms) - 1
				test := cover_test(w, target, f.kinds[i.target].machine, arm.cover)
				switch {
				case n == 0 && last:
					line(w, "{{")
				case n == 0:
					line(w, "if (%s) {{", test)
				case last:
					line(w, "}} else {{")
				case:
					line(w, "}} else if (%s) {{", test)
				}
				w.depth += 1
				if msg := body(w, arm.body); msg != "" do return msg
				if i.dst != code.NONE && arm.body.value != code.NONE do line(w, "v%d = %s;", int(i.dst), name(w, arm.body.value))
				w.depth -= 1
			}
			line(w, "}}")
		case code.Loop:
			if i.dst != code.NONE do line(w, "%s v%d;", type_of(f.kinds[i.dst]), int(i.dst))
			for x, n in i.params {
				if x == i.init[n] do continue
				line(w, "%s v%d = %s;", type_of(f.kinds[x]), int(x), name(w, i.init[n]))
			}
			line(w, "for (;;) {{")
			w.depth += 1
			for x in i.params do assume(w, x)
			append(&w.loops, i.params)
			if msg := body(w, i.body); msg != "" do return msg
			pop(&w.loops)
			if i.dst != code.NONE do line(w, "v%d = %s;", int(i.dst), name(w, i.body.value))
			line(w, "break;")
			w.depth -= 1
			line(w, "}}")
		case code.Again:
			if len(w.loops) == 0 do return "an Again outside a loop"
			again(w, i, w.loops[len(w.loops) - 1])
		}
	}
	return ""
}

// again: the parameters take the arguments, all read before any is written, and
// the loop continues.
again :: proc(w: ^Writer, a: code.Again, params: []code.Value) {
	moved := make([dynamic]int)
	for x, n in params do if a.args[n] != x do append(&moved, n)
	// an argument that is a parameter written here is read first
	clash := false
	for n in moved do for m in moved do clash ||= a.args[n] == params[m]
	if !clash {
		for n in moved do line(w, "v%d = %s;", int(params[n]), name(w, a.args[n]))
	} else {
		line(w, "{{")
		w.depth += 1
		for n in moved do line(w, "%s t%d = %s;", type_of(w.f.kinds[params[n]]), n, name(w, a.args[n]))
		for n in moved do line(w, "v%d = t%d;", int(params[n]), n)
		w.depth -= 1
		line(w, "}}")
	}
	line(w, "continue;")
}

unary :: proc(w: ^Writer, u: code.Unary) -> string {
	a := name(w, u.a)
	kind := w.f.kinds[u.a]
	if kind.lanes > 0 && kind.machine == .Int && u.op == .Neg do return fmt.tprintf("(%s)(-(u64x%d)%s)", type_of(kind), kind.lanes, a)
	#partial switch u.op {
	case .Neg:
		if w.f.kinds[u.a].machine == .Real || proven(w, u.dst) do return fmt.tprintf("-%s", a)
		return fmt.tprintf("wrap_neg(%s)", a)
	case .Not:
		return fmt.tprintf("~%s", a)
	}
	return a
}

// proven: the kernel proved the integer in int64_t: the C operation that gives it
// does not overflow.
proven :: proc(w: ^Writer, x: code.Value) -> bool {
	b := w.f.kinds[x].bounds
	return b.lo >= INT64.lo && b.hi <= INT64.hi
}

binary :: proc(w: ^Writer, x: code.Binary) -> (string, string) {
	a, b := name(w, x.a), name(w, x.b)
	if kind := w.f.kinds[x.a]; kind.lanes > 0 do return lanes(w, x, kind, a, b)
	if x.op == .Pow do return fmt.tprintf("%s(%s, %s)", w.f.kinds[x.a].machine == .Real ? "real_pow" : "wrap_pow", a, b), ""
	if w.f.kinds[x.a].machine == .Real {
		#partial switch x.op {
		case .Add, .Sub, .Mul, .Div, .Eq, .Ne, .Lt, .Le, .Gt, .Ge:
			return fmt.tprintf("%s %s %s", a, C_OPS[x.op], b), ""
		}
		return "", "a float operation C does not compute"
	}
	switch x.op {
	case .Add, .Sub, .Mul:
		if proven(w, x.dst) do return fmt.tprintf("%s %s %s", a, C_OPS[x.op], b), ""
		return fmt.tprintf("%s(%s, %s)", WRAPS[x.op], a, b), ""
	case .Div, .Mod, .And, .Or, .Xor, .Eq, .Ne, .Lt, .Le, .Gt, .Ge:
		return fmt.tprintf("%s %s %s", a, C_OPS[x.op], b), ""
	case .Shl:
		return fmt.tprintf("wrap_shl(%s, %s)", a, b), ""
	case .Shr:
		// the machine shifts by the count's 6 low bits
		shift := w.f.kinds[x.b].bounds
		if shift.lo >= 0 && shift.hi <= 63 do return fmt.tprintf("%s >> %s", a, b), ""
		return fmt.tprintf("%s >> (%s & 63)", a, b), ""
	case .Neg, .Not, .Pow:
	}
	return "", "a binary operation C does not compute"
}

// lanes: an operation on vectors, lane by lane: on integers, what wraps in
// unsigned lanes, a comparison 1 or 0.
lanes :: proc(w: ^Writer, x: code.Binary, kind: code.Kind, a, b: string) -> (string, string) {
	#partial switch x.op {
	case .Pow:
		return "", "a power of vectors C does not compute"
	case .Eq, .Ne, .Lt, .Le, .Gt, .Ge:
		return fmt.tprintf("(i64x%d)((%s %s %s) & 1)", kind.lanes, a, C_OPS[x.op], b), ""
	case .Add, .Sub, .Mul, .Shl:
		if kind.machine == .Int do return fmt.tprintf("(%s)((u64x%d)%s %s (u64x%d)%s)", type_of(kind), kind.lanes, a, C_OPS[x.op], kind.lanes, b), ""
	}
	return fmt.tprintf("%s %s %s", a, C_OPS[x.op], b), ""
}

// reduce: the lanes of a vector, by an operation that commutes, in order.
reduce :: proc(w: ^Writer, r: code.Reduce) -> string {
	kind := w.f.kinds[r.a]
	a := name(w, r.a)
	out := fmt.tprintf("%s[0]", a)
	for k in 1 ..< kind.lanes {
		lane := fmt.tprintf("%s[%d]", a, k)
		if kind.machine == .Int && (r.op == .Add || r.op == .Mul) do out = fmt.tprintf("%s(%s, %s)", WRAPS[r.op], out, lane)
		else do out = fmt.tprintf("%s %s %s", out, C_OPS[r.op], lane)
	}
	return out
}

C_OPS := [code.Op]string {
	.Add = "+",
	.Sub = "-",
	.Mul = "*",
	.Div = "/",
	.Mod = "%",
	.Pow = "**",
	.Neg = "-",
	.And = "&",
	.Or  = "|",
	.Xor = "^",
	.Not = "~",
	.Shl = "<<",
	.Shr = ">>",
	.Eq  = "==",
	.Ne  = "!=",
	.Lt  = "<",
	.Le  = "<=",
	.Gt  = ">",
	.Ge  = ">=",
}

WRAPS := #partial [code.Op]string {
	.Add = "wrap_add",
	.Sub = "wrap_sub",
	.Mul = "wrap_mul",
}

// cover_test: the C condition that the cover takes x.
cover_test :: proc(w: ^Writer, x: string, m: code.Machine, c: code.Cover) -> string {
	cells := make([dynamic]string)
	if m == .Real {
		for r in c.reals {
			parts := make([dynamic]string)
			if r.lo > -max(f64) do append(&parts, fmt.tprintf("%s %s %s", x, r.lo_open ? ">" : ">=", real_literal(r.lo)))
			if r.hi < max(f64) do append(&parts, fmt.tprintf("%s %s %s", x, r.hi_open ? "<" : "<=", real_literal(r.hi)))
			append(&cells, conjunction(parts[:]))
		}
	} else {
		for b in c.ints {
			parts := make([dynamic]string)
			switch {
			case b.lo == b.hi:
				append(&parts, fmt.tprintf("%s == %s", x, int_literal(b.lo)))
			case:
				if b.lo > INT64.lo do append(&parts, fmt.tprintf("%s >= %s", x, int_literal(b.lo)))
				if b.hi < INT64.hi do append(&parts, fmt.tprintf("%s <= %s", x, int_literal(b.hi)))
			}
			append(&cells, conjunction(parts[:]))
		}
	}
	test := "0"
	switch len(cells) {
	case 0:
	case 1:
		test = cells[0]
	case:
		for &x in cells do if strings.contains(x, "&&") do x = fmt.tprintf("(%s)", x)
		test = strings.join(cells[:], " || ")
	}
	if !c.negated do return test
	return fmt.tprintf("!(%s)", test)
}

conjunction :: proc(parts: []string) -> string {
	if len(parts) == 0 do return "1"
	return strings.join(parts, " && ")
}

int_literal :: proc(x: i128) -> string {
	switch {
	case x == INT64.lo:
		return "INT64_MIN"
	case x <= -(1 << 31) || x > (1 << 31) - 1:
		return fmt.tprintf("INT64_C(%d)", x)
	}
	return fmt.tprintf("%d", x)
}

real_literal :: proc(x: f64) -> string {
	switch {
	case x != x:
		return "NAN"
	case x > max(f64):
		return "INFINITY"
	case x < -max(f64):
		return "-INFINITY"
	}
	r := fmt.tprintf("%v", x)
	if !strings.contains_any(r, ".e") do r = fmt.tprintf("%s.0", r)
	return r
}

// text_literal: a C string literal of the bytes of s.
text_literal :: proc(s: string) -> string {
	b := strings.builder_make()
	strings.write_byte(&b, '"')
	for c in transmute([]u8)s {
		switch c {
		case '"', '\\', '?':
			strings.write_byte(&b, '\\')
			strings.write_byte(&b, c)
		case '\n':
			strings.write_string(&b, "\\n")
		case '\t':
			strings.write_string(&b, "\\t")
		case 0x20 ..= 0x7E:
			strings.write_byte(&b, c)
		case:
			fmt.sbprintf(&b, "\\%03o", c)
		}
	}
	strings.write_byte(&b, '"')
	return strings.to_string(b)
}

// entry: main reads the inputs, each in its layout, runs the program and ends
// with its value.
entry :: proc(w: ^Writer) {
	p := w.p
	strings.write_string(&w.b, "\n")
	if p.funcs[0].result == .Real {
		strings.write_string(&w.b, `// the float, with six decimals: round(|x| * 10^6) cut at 10^6
static void write_real(double x) {
    if (signbit(x)) {
        putchar('-');
        x = -x;
    }
    int64_t n = (int64_t)(x * 1e6 + 0.5);
    printf("%lld.%06lld\n", (long long)(n / 1000000), (long long)(n % 1000000));
}

`)
	}
	w.depth = 1
	if len(p.inputs) == 0 {
		strings.write_string(&w.b, "int main(void) {\n")
	} else {
		strings.write_string(&w.b, "int main(int argc, char **argv) {\n")
		line(w, "if (argc < %d) {{", len(p.inputs) + 1)
		line(w, "    fputs(\"missing inputs\\n\", stderr);")
		line(w, "    return 2;")
		line(w, "}}")
		for c, slot in p.inputs {
			line(w, "inputs[%d] = strtoll(argv[%d], NULL, 10);", slot, slot + 1)
			test := cover_test(w, fmt.tprintf("inputs[%d]", slot), .Int, c)
			if test == "1" do continue
			line(w, "if (!(%s)) {{", test)
			line(w, "    fputs(\"input out of range\\n\", stderr);")
			line(w, "    return 2;")
			line(w, "}}")
		}
	}
	switch p.funcs[0].result {
	case .Int:
		line(w, "return (int)(program() & 255);")
	case .Real:
		line(w, "write_real(program());")
		line(w, "return 0;")
	case .Text:
		line(w, "puts(program());")
		line(w, "return 0;")
	case .None:
		line(w, "program();")
		line(w, "return 0;")
	}
	strings.write_string(&w.b, "}\n")
}
