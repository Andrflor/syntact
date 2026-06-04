package codegen_test

import compiler "../../compiler"
import bc "../../compiler/bytecode"
import x64 "../../compiler/backends/x64"

import "core:encoding/json"
import "core:fmt"
import vmem "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

// ============================================================================
// CODEGEN test harness — the exhaustive end-to-end suite.
//
// For each case (source + args + expect) it checks BOTH backends against the
// expected value AND against each other:
//   1. INTERPRETER: lower → interp_bytecode(args) → compare to expect.
//   2. NATIVE x64:  lower → emit ELF → run the binary (popen) → compare
//      exit-status (integer/bool result) or stdout (string/float result).
// The interpreter is the oracle; a native/interp divergence fails the case.
//
// `kind` selects how the result is observed:
//   "int"   — interpreter prints the integer; native uses exit-status (& 0xff).
//   "str"   — interpreter and native both print to stdout; compared verbatim.
//   "float" — compared numerically (native prints fixed-6, interp compact), so
//             the harness parses both to f64 and compares with a tolerance.
//   "reject"— lowering must fail with an error (unsupported construct).
// ============================================================================

foreign import libc "system:c"

@(default_calling_convention = "c")
foreign libc {
	popen :: proc(command: cstring, type: cstring) -> rawptr ---
	pclose :: proc(stream: rawptr) -> i32 ---
	fread :: proc(ptr: rawptr, size: uint, nmemb: uint, stream: rawptr) -> uint ---
}

test_path :: proc(rel: string) -> string {
	dir := filepath.dir(#location().file_path)
	joined, _ := filepath.join({dir, rel}, context.allocator)
	return joined
}

// A case is ONE program compiled ONCE, then validated against MANY input/output
// combos. `args[i]` are the argv strings for combo i, `expect[i]` its expected
// result. Every combo is checked on BOTH backends; all must match.
Codegen_Test_Case :: struct {
	name:        string `json:"name"`,
	description: string `json:"description"`,
	source:      string `json:"source"`,
	args:        [][]string `json:"args"`,
	expect:      []string `json:"expect"`,
	kind:        string `json:"kind"`, // "int" | "str" | "float" | "reject"
}

load_case :: proc(rel: string) -> (Codegen_Test_Case, bool, string) {
	path := test_path(rel)
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil do return {}, false, fmt.tprintf("read fail: %s", path)
	tc: Codegen_Test_Case
	if e := json.unmarshal(data, &tc); e != nil {
		return {}, false, fmt.tprintf("json fail %s: %v", path, e)
	}
	return tc, true, ""
}

// run_shell runs a command, returning (stdout, exit_code).
run_shell :: proc(cmd: string) -> (string, int) {
	ccmd := strings.clone_to_cstring(cmd, context.temp_allocator)
	mode := strings.clone_to_cstring("r", context.temp_allocator)
	f := popen(ccmd, mode)
	if f == nil do return "", -1
	sb := strings.builder_make(context.temp_allocator)
	buf: [4096]u8
	for {
		n := fread(&buf[0], 1, len(buf), f)
		if n == 0 do break
		strings.write_bytes(&sb, buf[:n])
	}
	status := pclose(f)
	// WEXITSTATUS: (status >> 8) & 0xff on Linux.
	code := int((status >> 8) & 0xff)
	return strings.to_string(sb), code
}

parse_f64 :: proc(s: string) -> (f64, bool) {
	str := strings.trim_space(s)
	neg := false
	i := 0
	if len(str) > 0 && (str[0] == '-' || str[0] == '+') {
		neg = str[0] == '-'; i = 1
	}
	whole, frac, scale: f64 = 0, 0, 1
	saw := false
	for ; i < len(str); i += 1 {
		c := str[i]
		if c < '0' || c > '9' do break
		whole = whole * 10 + f64(c - '0'); saw = true
	}
	if i < len(str) && str[i] == '.' {
		i += 1
		for ; i < len(str); i += 1 {
			c := str[i]
			if c < '0' || c > '9' do break
			scale *= 10; frac = frac * 10 + f64(c - '0'); saw = true
		}
	}
	if !saw do return 0, false
	r := whole + frac / scale
	return neg ? -r : r, true
}

run_case :: proc(path: string, t: ^testing.T) {
	arena: vmem.Arena
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)

	tc, ok, msg := load_case(path)
	if !ok {
		testing.expectf(t, false, "%s", msg)
		return
	}

	cache := new(compiler.Cache)
	ast, _ := compiler.parse(cache, tc.source)
	compiler.analyze(cache, ast)
	result := compiler.reduce(cache.scope)
	prog := compiler.lower_to_bytecode(result)

	// "reject": lowering must carry an error.
	if tc.kind == "reject" {
		testing.expectf(
			t,
			prog != nil && prog.error != "",
			"[%s] expected a lowering rejection, got none",
			tc.name,
		)
		return
	}

	// The program is COMPILED ONCE. The native ELF is emitted once, then run per
	// combo with different argv. Every (args, expect) pair is validated on BOTH
	// backends; all must match.
	if len(tc.args) != len(tc.expect) {
		testing.expectf(
			t, false,
			"[%s] args/expect length mismatch: %d vs %d",
			tc.name, len(tc.args), len(tc.expect),
		)
		return
	}

	exe := test_path(fmt.tprintf("tests/.out_%s", tc.name))
	emsg := x64.emit_executable(prog, exe)
	testing.expectf(t, emsg == "", "[%s] emit error: %s", tc.name, emsg)
	if emsg != "" do return
	defer os.remove(exe)

	for combo in 0 ..< len(tc.args) {
		run_combo(t, tc, prog, exe, tc.args[combo], tc.expect[combo], combo)
	}
}

// run_combo validates ONE input/output pair against both backends.
run_combo :: proc(
	t: ^testing.T,
	tc: Codegen_Test_Case,
	prog: ^bc.BC_Program,
	exe: string,
	args: []string,
	expect: string,
	combo: int,
) {
	// --- 1. interpreter (oracle) ---
	r := bc.interp_bytecode(prog, args)
	testing.expectf(t, r.ok, "[%s #%d] interp error: %s", tc.name, combo, r.error)
	if !r.ok do return

	interp_str: string
	switch tc.kind {
	case "str":
		interp_str = r.svalue
	case "float":
		interp_str = fmt.tprintf("%v", r.fvalue)
	case:
		interp_str = fmt.tprintf("%d", r.value)
	}

	// --- 2. native x64 ELF (same binary, fresh argv) ---
	argline := strings.join(args, " ", context.temp_allocator)
	cmd := fmt.tprintf("%s %s", exe, argline)
	stdout, code := run_shell(cmd)

	// --- 3. compare both backends to expect (and implicitly to each other) ---
	switch tc.kind {
	case "int":
		// interp prints the full integer; native is exit-status (value & 0xff).
		want_native := 0
		if v, vok := parse_int(expect); vok do want_native = ((v % 256) + 256) % 256
		testing.expectf(
			t, interp_str == expect,
			"[%s #%d] args=%v interp=%s expect=%s", tc.name, combo, args, interp_str, expect,
		)
		testing.expectf(
			t, code == want_native,
			"[%s #%d] args=%v native exit=%d expect=%d (val %s)",
			tc.name, combo, args, code, want_native, expect,
		)
	case "str":
		got := strings.trim_right_space(stdout)
		testing.expectf(t, interp_str == expect, "[%s #%d] args=%v interp str=%q expect=%q", tc.name, combo, args, interp_str, expect)
		testing.expectf(t, got == expect, "[%s #%d] args=%v native str=%q expect=%q", tc.name, combo, args, got, expect)
	case "float":
		ev, _ := parse_f64(expect)
		iv := r.fvalue
		nv, _ := parse_f64(strings.trim_space(stdout))
		testing.expectf(t, abs_f(iv - ev) < 1e-6, "[%s #%d] args=%v interp float=%v expect=%v", tc.name, combo, args, iv, ev)
		testing.expectf(t, abs_f(nv - ev) < 1e-6, "[%s #%d] args=%v native float=%v expect=%v", tc.name, combo, args, nv, ev)
	}
}

abs_f :: proc(x: f64) -> f64 {return x < 0 ? -x : x}

parse_int :: proc(s: string) -> (int, bool) {
	str := strings.trim_space(s)
	neg := false
	i := 0
	if len(str) > 0 && (str[0] == '-' || str[0] == '+') {neg = str[0] == '-'; i = 1}
	acc := 0
	saw := false
	for ; i < len(str); i += 1 {
		c := str[i]
		if c < '0' || c > '9' do return 0, false
		acc = acc * 10 + int(c - '0'); saw = true
	}
	if !saw do return 0, false
	return neg ? -acc : acc, true
}

strings_trim_right_space :: strings.trim_right_space
