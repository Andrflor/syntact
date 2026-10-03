package kernel

import syn "../compiler"

// run : parse, construit l'IR, la type, puis vérifie. Renvoie le scope typé du
// fichier (le fichier est un scope) et le kernel avec ses erreurs.
run :: proc(source: string) -> (typed: ^Scope, k: Kernel, parsed: bool) {
	cache := new(syn.Cache)
	ast, ok := syn.parse(cache, source)
	if !ok do return nil, k, false
	program := build_program(&k, ast)
	typed = type_scope(&k, program, nil)
	check(&k)
	return typed, k, true
}
