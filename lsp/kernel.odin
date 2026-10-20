package lsp

import "../compiler"
import kernel "../kernel"
import "core:fmt"
import "core:sys/posix"
import "core:time"

// ============================================================================
// THE KERNEL IN THE EDITOR
//
// The kernel types the file in place: each written binding carries its types. The
// LSP finds a binding by the position of what is written — the deepest written
// scope that contains the cursor, then, inside it, the binding that contains it.
// The copies of a carve are not written in the file: they are not traversed.
// ============================================================================

contains :: proc(span: compiler.Span, offset: u32) -> bool {
	return span.start <= offset && offset <= span.end
}

// written_scope_at: the deepest written scope that contains offset, under s.
written_scope_at :: proc(s: ^kernel.Scope, offset: u32) -> ^kernel.Scope {
	if s == nil do return nil
	for b in s.bindings {
		if !contains(b.span, offset) do continue
		if inner := scope_in_expr(b.color, s, offset); inner != nil do return inner
		if inner := scope_in_expr(b.value, s, offset); inner != nil do return inner
	}
	return s
}

// scope_in_expr: the scope written in e (which is written in s) containing offset.
scope_in_expr :: proc(e: ^kernel.Expr, s: ^kernel.Scope, offset: u32) -> ^kernel.Scope {
	if e == nil do return nil
	#partial switch v in e^ {
	case ^kernel.Scope:
		if v.parent == s && contains(v.span, offset) do return written_scope_at(v, offset)
	case kernel.Carve:
		if inner := scope_in_expr(v.target, s, offset); inner != nil do return inner
		if v.args.parent == s && contains(v.args.span, offset) do return written_scope_at(v.args, offset)
	case kernel.Match:
		if inner := scope_in_expr(v.target, s, offset); inner != nil do return inner
		for b in v.branches {
			if b.parent != s || !contains(b.span, offset) && !contains(b.bindings[0].span, offset) do continue
			if inner := scope_in_expr(b.cover, b, offset); inner != nil do return inner
			return written_scope_at(b, offset)
		}
	case kernel.Access:
		return scope_in_expr(v.target, s, offset)
	case kernel.Collapse:
		return scope_in_expr(v.target, s, offset)
	case kernel.Op:
		if inner := scope_in_expr(v.left, s, offset); inner != nil do return inner
		return scope_in_expr(v.right, s, offset)
	case kernel.Range:
		if inner := scope_in_expr(v.lo, s, offset); inner != nil do return inner
		return scope_in_expr(v.hi, s, offset)
	case kernel.Unknown:
		return scope_in_expr(v.layout, s, offset)
	}
	return nil
}

// written_binding: the written binding that declares `name` at offset; otherwise
// the one the prelude names so (a builtin).
written_binding :: proc(program: ^kernel.Scope, name: string, offset: u32) -> ^kernel.Binding {
	if program == nil do return nil
	s := written_scope_at(program, offset)
	for &b in s.bindings do if b.name == name && contains(b.span, offset) do return &b
	if prelude := program.parent; prelude != nil {
		for &b in prelude.bindings do if b.name == name do return &b
	}
	return nil
}

// visible_bindings: the named bindings visible at offset, from the closest to the
// prelude; a shadowed name appears only once.
visible_bindings :: proc(program: ^kernel.Scope, offset: u32) -> []^kernel.Binding {
	out := make([dynamic]^kernel.Binding)
	if program == nil do return out[:]
	seen := make(map[string]bool, allocator = context.temp_allocator)
	for sc := written_scope_at(program, offset); sc != nil; sc = sc.parent {
		#reverse for &b in sc.bindings {
			if b.name == "" || b.name in seen do continue
			seen[b.name] = true
			append(&out, &b)
		}
	}
	return out[:]
}

// shown_type: the binding as the kernel typed it.
shown_type :: proc(b: ^kernel.Binding) -> string {
	return kernel.print_binding(b^, .Type)
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
		kernel.check_ast(ast)
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
