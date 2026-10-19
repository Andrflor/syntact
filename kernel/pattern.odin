package kernel

import syn "../compiler"
import "core:fmt"

// LE PATTERN
//
// `target ? {cover -> product …}` (specs/language/12). Une couverture est une
// expression qui désigne un ensemble, lu comme une couleur : `0`, `=5`, `u8`, `>0`,
// `u8:` (le défaut de u8), `Circle:` (la forme Circle). La branche sans couverture
// admet tout. La première branche qui admet la valeur de target la donne.
//
// C'est la valeur de target qui est couverte, pas sa couleur : une définition se
// vérifie avec ses valeurs, et un carve qui les change se vérifie au carve. Pour
// couvrir toute une couleur, la valeur est `??`.
//
// - Une valeur connue : une seule branche se déclenche, les autres ne sont pas
//   typées. Aucune : Non_Exhaustive_Pattern.
// - Une inconnue : chaque branche reçoit ce que les précédentes n'ont pas pris ;
//   une branche qui ne reçoit rien ne se déclenche jamais. Ce qui reste à la fin
//   n'est couvert par aucune branche : Non_Exhaustive_Pattern. Quand target est
//   une inconnue seule, la branche le sait : c'est un fait de son contexte
//   (Scope.fact), pas une réécriture. Le résultat est le type par cas (Cases) —
//   une valeur par branche atteinte, jamais aplatie.

type_match :: proc(k: ^Kernel, m: Match, env: ^Scope) -> ^Expr {
	t := type_of(k, m.target, env)
	if is_invalid(t) do return t
	ctx := context_of(env)
	#partial switch v in t^ {
	case Set:
		return match_value(k, m, t, ctx)
	case ^Scope:
		if !is_closed_type(t) do return report(k, .Unsupported, m.span, "pas encore dans le kernel : un pattern sur un scope qui dépend d'une inconnue")
		return match_value(k, m, t, ctx)
	case Poly, Term, Cases:
		return match_unknown(k, m, t, ctx)
	}
	return report(k, .Unsupported, m.span, fmt.tprintf("pas encore dans le kernel : un pattern sur %s", brief(t)))
}

// cover_set : ce qu'admet la couverture d'une branche ; nil pour la branche par défaut.
cover_set :: proc(k: ^Kernel, b: ^Scope) -> (set: Maybe(Set), ok: bool) {
	if b.cover == nil do return nil, true
	t := type_of(k, b.cover, b)
	if is_invalid(t) do return nil, false
	s, closed := color_set(k, t)
	if !closed {
		report(k, .Unsupported, b.span, fmt.tprintf("pas encore dans le kernel : une couverture qui dépend d'une inconnue : %s", brief(t)))
		return nil, false
	}
	return s, true
}

// production : le type de la production d'une branche.
production :: proc(k: ^Kernel, b: ^Scope) -> ^Expr {
	type_scope(k, b)
	return b.bindings[0].value_type
}

// match_value : target est connue ; la première branche qui l'admet la donne.
match_value :: proc(k: ^Kernel, m: Match, t: ^Expr, ctx: Context) -> ^Expr {
	for b in m.branches {
		c, ok := cover_set(k, b)
		if !ok do return new_expr(Invalid{})
		cover, covering := c.?
		if !covering do return production(k, b)
		switch admits(k, cover, t, ctx) {
		case .Proved:
			return production(k, b)
		case .Refuted:
		case .Undecided:
			return report(k, .Unproven, m.span, fmt.tprintf("on ne sait pas si %s est admis par %s", brief(t), brief(b.cover)))
		}
	}
	return report(k, .Non_Exhaustive_Pattern, m.span, fmt.tprintf("aucune branche n'admet %s", brief(t)))
}

// match_unknown : target dépend d'inconnues. Ses valeurs possibles, dans le
// contexte, se partagent entre les branches, dans l'ordre.
match_unknown :: proc(k: ^Kernel, m: Match, t: ^Expr, ctx: Context) -> ^Expr {
	rest, exact := envelope(k, t, ctx)
	sym, single := lone_symbol(t)
	cases := make([dynamic]Case)
	for b in m.branches {
		if set_is_empty(rest) do break // les branches suivantes ne se déclenchent jamais
		c, ok := cover_set(k, b)
		if !ok do return new_expr(Invalid{})
		cover, covering := c.?
		part := covering ? set_intersect(rest, cover) : rest
		rest = covering ? set_diff(rest, cover) : {}
		if set_is_empty(part) do continue
		if single do b.fact = Fact{sym, part} // ce que la branche sait de l'inconnue
		value := production(k, b)
		if is_invalid(value) do return value
		append(&cases, Case{b.fact, value})
	}
	if !set_is_empty(rest) {
		if exact do return report(k, .Non_Exhaustive_Pattern, m.span, fmt.tprintf("aucune branche n'admet %s", print_set(rest)))
		return report(k, .Unproven, m.span, fmt.tprintf("on ne sait pas prouver que les branches couvrent %s", print_set(rest)))
	}
	if len(cases) == 1 do return cases[0].value
	for c in cases do if _, is_scope := c.value^.(^Scope); is_scope do return report(k, .Unsupported, m.span, "pas encore dans le kernel : un pattern sur une inconnue dont une branche donne un scope")
	return new_expr(Cases{cases[:]})
}

// lone_symbol : t est une inconnue seule, que les branches peuvent restreindre.
lone_symbol :: proc(t: ^Expr) -> (^Var, bool) {
	#partial switch v in t^ {
	case Poly:
		if v.const == 0 && len(v.monos) == 1 && v.monos[0].coef == 1 && len(v.monos[0].vars) == 1 do return v.monos[0].vars[0], true
	case Term:
		if v.op == .Sym do return v.sym, true
	}
	return nil, false
}
