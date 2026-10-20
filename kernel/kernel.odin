package kernel

import syn "../compiler"

// run: parses, builds the IR, types it in place, then checks. Returns the scope of
// the file (the file is a scope), each binding of which carries its types, and the
// kernel with its errors.
run :: proc(source: string) -> (program: ^Scope, k: Kernel, parsed: bool) {
	cache := new(syn.Cache)
	ast, ok := syn.parse(cache, source)
	if !ok do return nil, k, false
	program, k = check_ast(ast)
	return program, k, true
}

// check_ast: the kernel on an already parsed AST.
check_ast :: proc(ast: ^syn.Ast) -> (program: ^Scope, k: Kernel) {
	program = build_program(&k, ast)
	type_scope(&k, program)
	check(&k)
	return
}
