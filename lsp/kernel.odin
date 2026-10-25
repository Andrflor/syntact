package lsp

import "../compiler"
import kernel "../kernel"
import "core:fmt"
import "core:sys/posix"
import "core:time"

// ============================================================================
// THE KERNEL IN THE EDITOR
//
// The kernel builds the file as a scope of terms: each written binding is there,
// with the color and the value it is written with. The LSP finds a binding by the
// position of what is written — the deepest written scope that contains the
// cursor, then, inside it, the binding that contains it — and shows it with the
// normal forms of its color and its value. The copies of a carve are not written
// in the file: they are not traversed.
// ============================================================================

contains :: proc(span: compiler.Span, offset: u32) -> bool {
	return span.start <= offset && offset <= span.end
}

// Located: what is written at an offset: the deepest written scope that contains
// it, and the name written there, if one is — the binding the kernel resolved it
// to — or the field read there in a scope: `s.x`, `s{x -> …}`.
Located :: struct {
	scope: ^kernel.Scope,
	name:  ^kernel.Name,
	field: Field,
}

// Field: the occurrence of `name` in the scope that target is: the last one for
// an access, the first one for a carve, or the n-th.
Field :: struct {
	target:  kernel.Type,
	name:    string,
	ordinal: int,
	last:    bool,
}

// locate: what is written at offset, under s.
locate :: proc(s: ^kernel.Scope, offset: u32) -> Located {
	for b in s.bindings {
		if !contains(b.span, offset) do continue
		if at, found := locate_in(b.color, s, offset); found do return at
		if at, found := locate_in(b.value, s, offset); found do return at
	}
	return {scope = s}
}

// locate_in: what is written at offset in t, which is written in s.
locate_in :: proc(t: kernel.Type, s: ^kernel.Scope, offset: u32) -> (Located, bool) {
	switch v in t {
	case ^kernel.Name:
		if contains(v.span, offset) do return {scope = s, name = v}, true
	case ^kernel.Scope:
		if v.parent == s && contains(v.span, offset) do return locate(v, offset), true
	case ^kernel.Carve:
		if at, found := locate_in(v.target, s, offset); found do return at, true
		return locate_in_args(v.target, v.args, s, offset)
	case ^kernel.Pattern:
		if at, found := locate_in(v.target, s, offset); found do return at, true
		for b in v.branches {
			if !contains(b.scope.span, offset) do continue
			if at, found := locate_in(b.cover, s, offset); found do return at, true
			if at, found := locate_in(b.product, b.scope, offset); found do return at, true
			return {scope = b.scope}, true
		}
	case ^kernel.Access:
		if !contains(v.span, offset) do break
		if at, found := locate_in(v.target, s, offset); found do return at, true
		return {scope = s, field = {v.target, v.name, v.ordinal, true}}, true
	case ^kernel.Collapse:
		return locate_in(v.target, s, offset)
	case ^kernel.Operation:
		return locate_in_all(v.args, s, offset)
	case ^kernel.Or:
		return locate_in_all(v.terms, s, offset)
	case ^kernel.And:
		return locate_in_all(v.terms, s, offset)
	case ^kernel.Not:
		return locate_in(v.term, s, offset)
	case ^kernel.Is:
		return locate_in(v.term, s, offset)
	case ^kernel.Range:
		if at, found := locate_in(v.lo, s, offset); found do return at, true
		return locate_in(v.hi, s, offset)
	case ^kernel.Default:
		return locate_in(v.color, s, offset)
	case ^kernel.Unknown:
		return locate_in(v.written, s, offset)
	case kernel.Char, kernel.Int, kernel.Real, kernel.Bool, kernel.None, kernel.Invalid:
	}
	return {}, false
}

locate_in_all :: proc(ts: []kernel.Type, s: ^kernel.Scope, offset: u32) -> (Located, bool) {
	for t in ts do if at, found := locate_in(t, s, offset); found do return at, true
	return {}, false
}

// locate_in_args: the arguments of a carve of target, and those of the carves in
// turn; the name of an argument is a field of target.
locate_in_args :: proc(target: kernel.Type, args: []kernel.Carve_Arg, s: ^kernel.Scope, offset: u32) -> (Located, bool) {
	for a in args {
		if !contains(a.span, offset) do continue
		if at, found := locate_in(a.value, s, offset); found do return at, true
		if at, found := locate_in_args(nil, a.carves, s, offset); found do return at, true
		if a.name != "" && target != nil do return {scope = s, field = {target, a.name, a.ordinal, false}}, true
		return {scope = s}, true
	}
	return {}, false
}

// names: b is named `name`, or captured under it.
names :: proc(b: ^kernel.Binding, name: string) -> bool {
	return name != "" && (b.name == name || b.capture == name)
}

// written_binding: the binding the name written at offset designates, as the
// kernel resolved it; the field it reads in a scope; the written binding that
// declares `name` there; otherwise the one the prelude names so (a builtin).
written_binding :: proc(k: ^kernel.Kernel, name: string, offset: u32) -> ^kernel.Binding {
	program := k.root
	if program == nil do return nil
	at := locate(program, offset)
	if at.name != nil do return at.name.binding
	if at.field.target != nil {
		f := at.field
		target, is_scope := kernel.normal(k, f.target).(^kernel.Scope)
		if !is_scope do return nil
		b, _ := kernel.occurrence(kernel.placed(k, target, .Value), f.name, f.ordinal, f.last)
		return b
	}
	for b in at.scope.bindings do if names(b, name) && contains(b.span, offset) do return b
	if prelude := program.parent; prelude != nil {
		for b in prelude.bindings do if b.name == name do return b
	}
	return nil
}

// visible_bindings: the named bindings visible at offset, from the closest to the
// prelude; a shadowed name appears only once.
visible_bindings :: proc(program: ^kernel.Scope, offset: u32) -> []^kernel.Binding {
	out := make([dynamic]^kernel.Binding)
	if program == nil do return out[:]
	seen := make(map[string]bool, allocator = context.temp_allocator)
	for sc := locate(program, offset).scope; sc != nil; sc = sc.parent {
		#reverse for b in sc.bindings {
			name := b.capture != "" ? b.capture : b.name
			if name == "" || name in seen do continue
			seen[name] = true
			append(&out, b)
		}
	}
	return out[:]
}

// shown_type: the binding with the normal forms the kernel gives it.
shown_type :: proc(k: ^kernel.Kernel, b: ^kernel.Binding) -> string {
	return kernel.print_binding(k, b)
}

// KERNEL_TIMEOUT: beyond it, the kernel is considered not to terminate.
KERNEL_TIMEOUT :: 5 * time.Second

// kernel_fails: the kernel, run in a separate process on this AST, crashes or
// does not terminate. It is deterministic: if it terminates apart, it terminates
// here.
kernel_fails :: proc(ast: ^compiler.Ast) -> (failure: string, failed: bool) {
	pid := posix.fork()
	if pid < 0 do return "", false // no separate process: run it here
	if pid == 0 {
		kernel.check(ast)
		posix._exit(0)
	}
	start := time.now()
	status: i32
	for {
		if posix.waitpid(pid, &status, {.NOHANG}) == pid do break
		if time.since(start) > KERNEL_TIMEOUT {
			posix.kill(pid, .SIGKILL)
			posix.waitpid(pid, &status, {})
			return fmt.tprintf("the kernel does not terminate within %v on this file", KERNEL_TIMEOUT), true
		}
		time.sleep(2 * time.Millisecond)
	}
	// killed by a signal: the low 7 bits of the status. Odin's posix.WIFSIGNALED
	// counts as signed under Linux, and takes a normal exit (0) for a signal.
	if signal := status & 0x7f; signal != 0 && signal != 0x7f {
		return fmt.tprintf("the kernel crashed on this file (%v)", posix.Signal(signal)), true
	}
	return "", false
}
