package kernel

import syn "../compiler"

// run : parse, construit l'IR, la type sur place, puis vérifie. Renvoie le scope du
// fichier (le fichier est un scope), dont chaque binding porte ses types, et le
// kernel avec ses erreurs.
run :: proc(source: string) -> (program: ^Scope, k: Kernel, parsed: bool) {
	cache := new(syn.Cache)
	ast, ok := syn.parse(cache, source)
	if !ok do return nil, k, false
	program = build_program(&k, ast)
	type_scope(&k, program)
	// lancer le programme, c'est collapser le fichier : sa production est demandée
	if p, found := first_production(program); found do produced(&k, p)
	check(&k)
	return program, k, true
}
