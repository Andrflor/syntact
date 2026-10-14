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
//   une inconnue seule, elle est restreinte dans la branche à ce que la branche
//   reçoit (Refinement). Le résultat est l'une des productions des branches
//   atteintes : une inconnue sur l'union de leurs valeurs.

// Refinement : dans une branche, l'inconnue `sym` ne vaut que ce que la branche
// reçoit ; elle y est remplacée par `by`, une inconnue sur ces seules valeurs.
Refinement :: struct {
	sym: int,
	by:  ^Expr,
}

type_match :: proc(k: ^Kernel, m: Match, env: ^Scope) -> ^Expr {
	t := type_of(k, m.target, env)
	if is_invalid(t) do return t
	#partial switch v in t^ {
	case Set:
		return match_value(k, m, t)
	case ^Scope:
		if !is_closed_type(t) do return report(k, .Unsupported, m.span, "pas encore dans le kernel : un pattern sur un scope qui dépend d'une inconnue")
		return match_value(k, m, t)
	case Poly, Term:
		return match_unknown(k, m, t)
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
match_value :: proc(k: ^Kernel, m: Match, t: ^Expr) -> ^Expr {
	for b in m.branches {
		c, ok := cover_set(k, b)
		if !ok do return new_expr(Invalid{})
		cover, covering := c.?
		if !covering do return production(k, b)
		switch admits(k, cover, t) {
		case .Proved:
			return production(k, b)
		case .Refuted:
		case .Undecided:
			return report(k, .Unproven, m.span, fmt.tprintf("on ne sait pas si %s est admis par %s", brief(t), brief(b.cover)))
		}
	}
	return report(k, .Non_Exhaustive_Pattern, m.span, fmt.tprintf("aucune branche n'admet %s", brief(t)))
}

// match_unknown : target dépend d'inconnues. Ses valeurs possibles se partagent
// entre les branches, dans l'ordre.
match_unknown :: proc(k: ^Kernel, m: Match, t: ^Expr) -> ^Expr {
	rest, exact := envelope(k, t)
	sym, single := lone_symbol(t)
	products := make([dynamic]^Expr, context.temp_allocator)
	for b in m.branches {
		if set_is_empty(rest) do break // les branches suivantes ne se déclenchent jamais
		c, ok := cover_set(k, b)
		if !ok do return new_expr(Invalid{})
		cover, covering := c.?
		part := covering ? set_intersect(rest, cover) : rest
		rest = covering ? set_diff(rest, cover) : {}
		if set_is_empty(part) do continue
		if !single {
			append(&products, production(k, b))
			continue
		}
		append(&k.refined, Refinement{sym, new_symbol(k, part)})
		append(&products, production(k, b))
		pop(&k.refined)
	}
	if !set_is_empty(rest) {
		if exact do return report(k, .Non_Exhaustive_Pattern, m.span, fmt.tprintf("aucune branche n'admet %s", print_set(rest)))
		return report(k, .Unproven, m.span, fmt.tprintf("on ne sait pas prouver que les branches couvrent %s", print_set(rest)))
	}
	return one_of(k, products[:], m.span)
}

// lone_symbol : t est une inconnue seule, que les branches peuvent restreindre.
lone_symbol :: proc(t: ^Expr) -> (int, bool) {
	#partial switch v in t^ {
	case Poly:
		if v.const == 0 && len(v.monos) == 1 && v.monos[0].coef == 1 && len(v.monos[0].vars) == 1 do return v.monos[0].vars[0], true
	case Term:
		if v.op == .Sym do return v.sym, true
	}
	return 0, false
}

// one_of : la valeur d'un pattern dont plusieurs branches peuvent se déclencher —
// l'une de leurs productions : une inconnue sur l'union de leurs valeurs.
one_of :: proc(k: ^Kernel, products: []^Expr, span: syn.Span) -> ^Expr {
	if len(products) == 1 do return products[0]
	values: Set
	for p in products {
		if is_invalid(p) do return p
		if _, is_scope := p^.(^Scope); is_scope do return report(k, .Unsupported, span, "pas encore dans le kernel : un pattern sur une inconnue dont une branche donne un scope")
		s, closed := exact_set(k, p)
		if !closed do s, _ = envelope(k, p) // une valeur sur des inconnues : ses valeurs possibles
		values = set_union(values, s)
	}
	return new_symbol(k, values)
}

// --- le raffinement ---

// refine : un type lu dans une branche, où ses inconnues restreintes sont remplacées.
refine :: proc(k: ^Kernel, t: ^Expr, span: syn.Span) -> ^Expr {
	r := t
	for x in k.refined do r = substitute(k, r, x.sym, x.by, span)
	return r
}

// substitute : t, où l'inconnue `sym` vaut `by`, remis en forme normale.
substitute :: proc(k: ^Kernel, t: ^Expr, sym: int, by: ^Expr, span: syn.Span) -> ^Expr {
	if !mentions_symbol(t, sym) do return t
	#partial switch v in t^ {
	case Poly:
		y, _ := as_poly(by)
		r := Poly{const = v.const}
		for m in v.monos {
			term := Poly{const = m.coef}
			for x in m.vars {
				ok: bool
				term, ok = poly_mul(term, x == sym ? y : poly_var(x))
				if !ok do return report(k, .Unsupported, span, "pas encore dans le kernel : un coefficient au-delà de i128")
			}
			ok: bool
			r, ok = poly_add(r, term)
			if !ok do return report(k, .Unsupported, span, "pas encore dans le kernel : un coefficient au-delà de i128")
		}
		return poly_type(r)
	case Term:
		if v.op == .Sym do return by
		args := make([]^Expr, len(v.args))
		for a, i in v.args do args[i] = substitute(k, a, sym, by, span)
		return rebuilt_term(k, v.op, args, span)
	case Set_Form:
		args := make([]^Expr, len(v.args))
		for a, i in v.args do args[i] = substitute(k, a, sym, by, span)
		return set_operation(k, v.op, span, ..args)
	}
	return report(k, .Unsupported, span, fmt.tprintf("pas encore dans le kernel : restreindre une inconnue dans %s", brief(t)))
}

// rebuilt_term : un terme dont les arguments ont changé, par ses constructeurs, qui
// le remettent en forme normale (ou le calculent, s'ils sont devenus connus).
rebuilt_term :: proc(k: ^Kernel, op: Term_Op, args: []^Expr, span: syn.Span) -> ^Expr {
	r: ^Expr
	status := Arith_Status.Ok
	#partial switch op {
	case .F_Add:
		r, status = value_arith(k, .Add, args[0], args[1])
	case .F_Mul:
		r, status = value_arith(k, .Mul, args[0], args[1])
	case .F_Neg:
		r = float_neg(args[0])
	case .Concat:
		r = args[0]
		for a in args[1:] do r = concat(k, r, a)
	case .Repeat:
		r, status = repeat_term(k, args[0], args[1])
	case .Lt, .Le, .Eq, .Ne:
		compare := op == .Lt ? Compare_Op.Lt : op == .Le ? .Le : op == .Eq ? .Eq : .Ne
		if len(args) == 1 {
			p, _ := as_poly(args[0])
			r, status = int_compare(k, compare, p)
		} else {
			r, status = general_compare(k, compare, args[0], args[1])
		}
	}
	if status != .Ok || r == nil do return report(k, .Unsupported, span, "pas encore dans le kernel : restreindre une inconnue dans ce terme")
	return r
}

mentions_symbol :: proc(t: ^Expr, sym: int) -> bool {
	ids := make([dynamic]int, context.temp_allocator)
	collect_symbols(t, &ids)
	for id in ids do if id == sym do return true
	return false
}
