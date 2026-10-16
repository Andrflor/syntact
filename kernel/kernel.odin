package kernel

import syn "../compiler"

// run : parse, construit l'IR, la type sur place, puis vérifie. Renvoie le scope du
// fichier (le fichier est un scope), dont chaque binding porte ses types, et le
// kernel avec ses erreurs.
run :: proc(source: string) -> (program: ^Scope, k: Kernel, parsed: bool) {
	cache := new(syn.Cache)
	ast, ok := syn.parse(cache, source)
	if !ok do return nil, k, false
	program, k = check_ast(ast)
	return program, k, true
}

// check_ast : le kernel sur un AST déjà parsé.
check_ast :: proc(ast: ^syn.Ast) -> (program: ^Scope, k: Kernel) {
	program = build_program(&k, ast)
	type_scope(&k, program)
	check(&k)
	return
}
