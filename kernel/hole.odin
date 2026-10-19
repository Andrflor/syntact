package kernel

import syn "../compiler"
import "core:fmt"
import "core:strings"

// L'INFÉRENCE DES TROUS
//
// Un trou (`T <- d`) que le carve ne remplit pas reçoit sa valeur du carve
// (specs/language/14). Ce qui tombe à sa place — là où il est écrit dans la
// couleur d'un champ que le carve remplit, ou dans la valeur que ce champ avait —
// est de deux natures :
//
// - une valeur envoyée : elle se lit dans un type plus large sans changer de sens ;
// - un type requis : la couleur de ce que le carve fournit, ou le remplissage `<-`.
//   Il ne se lit pas plus large : ce serait admettre ce qu'il refuse.
//
// Le trou prend celle qui contient toutes les autres, jamais leur union. S'il y a
// des types requis, ils sont tous le même, et chaque valeur envoyée y est. Sinon,
// l'une des valeurs envoyées contient toutes les autres. La couleur du trou
// s'applique ensuite, comme à tout binding.
//
// Pour savoir ce qui tombe où, on type une sonde : une copie de la cible où chaque
// trou est une inconnue. Une couleur ou une valeur qui écrit le trou le porte alors
// dans son type, à l'endroit même où le carve met quelque chose.

Landing :: struct {
	type:     ^Expr,
	required: bool,
}

Probe :: struct {
	holes:   map[^Var]int, // la variable de la sonde → l'index du trou
	landed:  [][dynamic]Landing, // par binding de la cible : ce qui tombe à sa place
	blocked: bool, // un trou écrit dans une opération : on ne sait pas ce qui y tombe
}

// infer_holes : la valeur de chaque trou de `derived` que le carve détermine.
// `targets` : pour chaque argument, le binding qu'il remplit (fill).
infer_holes :: proc(k: ^Kernel, s: ^Scope, c: Carve, derived: ^Scope, targets: []int) {
	if !has_hole(s) do return
	p := probe(k, s, c, targets)
	if p.blocked {
		invalid := report(k, .Unsupported, c.span, "pas encore dans le kernel : un trou écrit dans une opération")
		// un trou qu'on ne sait pas inférer : ce qui en dépend reste silencieux
		for &b in derived.bindings {
			if b.kind != .Pull do continue
			if filled, is_carved := b.value^.(Carved); is_carved && filled.args == c.args do continue
			b.value = invalid
		}
		return
	}
	for &b, j in derived.bindings {
		if b.kind != .Pull || len(p.landed[j]) == 0 do continue
		t, settled := settle(k, p.landed[j][:], &b, c.span)
		if !settled do continue
		// rempli par `<-` : il garde ce remplissage, que le reste a confirmé
		if filled, is_carved := b.value^.(Carved); is_carved && filled.args == c.args do continue
		b.value = new_expr(Inferred{c.args, t})
	}
}

has_hole :: proc(s: ^Scope) -> bool {
	for b in s.bindings do if b.kind == .Pull do return true
	return false
}

// probe : ce qui tombe à la place de chaque trou. La sonde est typée en silence, et
// rien de ce qu'elle type n'est vérifié : seule sa forme compte.
probe :: proc(k: ^Kernel, s: ^Scope, c: Carve, targets: []int) -> (p: Probe) {
	previous := k.scene
	k.scene = {quiet = true}
	typed := len(k.typed)
	defer {
		resize(&k.typed, typed)
		k.scene = previous
	}

	p.landed = make([][dynamic]Landing, len(s.bindings))
	target := copy_scope(s, s.parent, k.scene.site)
	for &b, j in target.bindings {
		if b.kind != .Pull do continue
		sym := new_symbol(k, set_top())
		p.holes[sym.(^Var)] = j
		b.value = sym
	}
	type_scope(k, target, s.shape)

	// les arguments, typés à part : ceux du carve le seront avec la couleur du
	// binding qu'ils remplacent, qui peut dépendre d'un trou pas encore inféré
	args := copy_scope(c.args, c.args.parent, c.args.site)
	args.carving = s
	unread := make([]bool, len(s.bindings)) // un champ carvé que la sonde n'a pas su typer
	for &a, i in args.bindings {
		j := targets[i]
		if j < 0 do continue
		type_binding(k, &a, args, nil)
		if is_invalid(a.value_type) do continue
		if a.kind == .Pull {
			append(&p.landed[j], Landing{a.value_type, true})
			continue
		}
		b := &target.bindings[j]
		sent := Landing{a.value_type, false}
		if b.color != nil {
			color := type_of(k, b.color, target)
			unread[j] |= is_invalid(color)
			land(k, &p, color, sent)
		}
		if b.value != nil {
			unread[j] |= is_invalid(b.value_type)
			land(k, &p, b.value_type, sent)
		}
	}
	// Un champ qui dépend d'un trou, et que la sonde n'a pas su typer : on ne sait
	// pas ce qui tombe à la place du trou. Les dépendances se lisent comme celles
	// d'un carve, les trous tenant lieu de ce qui change — une fois la sonde typée,
	// car un binding changé ne se type plus en silence.
	for &b in target.bindings do if b.kind == .Pull do b.copy = .Changed
	mark_changes(target, nil, {})
	for b, j in target.bindings do if unread[j] && b.copy == .Changed do p.blocked = true
	return
}

// land : `pattern`, un type de la sonde, reçoit `at` ; chaque trou qu'il écrit
// reçoit la partie de `at` qui est à sa place. Dans un scope, la couleur d'un champ
// reçoit la couleur du champ correspondant s'il en a une (un type requis), sinon
// sa valeur ; la valeur d'un champ reçoit la valeur.
land :: proc(k: ^Kernel, p: ^Probe, pattern: ^Expr, at: Landing) {
	if pattern == nil || is_invalid(pattern) || at.type == nil || is_invalid(at.type) do return
	#partial switch v in pattern^ {
	case ^Var:
		if j, is_hole := p.holes[v]; is_hole {
			append(&p.landed[j], at)
			return
		}
	case ^Scope:
		// un scope à productions admet ce que ses productions admettent, pas sa
		// structure : on ne sait pas encore ce qui y tombe
		if first_production(v) != nil {
			if scope_mentions(p, v) do p.blocked = true
			return
		}
		w, is_scope := at.type^.(^Scope)
		if !is_scope || !same_bindings(v, w) do return // la vérification du champ le signale
		vs, ws := places(v), places(w)
		for vp, i in vs {
			vb, wb := binding_at(vp)^, binding_at(ws[i])^
			if vb.color != nil {
				inner := wb.color != nil ? Landing{wb.color_type, true} : Landing{wb.value_type, at.required}
				land(k, p, type_of(k, vb.color, vp.scope), inner)
			}
			if vb.value != nil do land(k, p, vb.value_type, Landing{wb.value_type, at.required})
		}
		return
	}
	if mentions(p, pattern) do p.blocked = true
}

// scope_mentions : un binding du scope, à quelque profondeur que ce soit, dépend
// d'un trou de la sonde.
scope_mentions :: proc(p: ^Probe, s: ^Scope) -> bool {
	for b in s.bindings {
		for t in ([2]^Expr{b.color_type, b.value_type}) {
			if t == nil do continue
			if inner, is_scope := t^.(^Scope); is_scope && scope_mentions(p, inner) do return true
			if mentions(p, t) do return true
		}
	}
	return false
}

// same_bindings : ils présentent les mêmes bindings — noms et kinds, dans l'ordre.
same_bindings :: proc(a, b: ^Scope) -> bool {
	x, y := places(a), places(b)
	if len(x) != len(y) do return false
	for p, i in x do if binding_at(p).name != binding_at(y[i]).name || binding_at(p).kind != binding_at(y[i]).kind do return false
	return true
}

// mentions : le type dépend d'un trou de la sonde.
mentions :: proc(p: ^Probe, t: ^Expr) -> bool {
	if t == nil do return false
	#partial switch v in t^ {
	case ^Var:
		return v in p.holes
	case Term:
		for a in v.args do if mentions(p, a) do return true
	case Poly:
		for m in v.monos do for x in m.vars do if x in p.holes || (derived(x) && mentions(p, x.type)) do return true
	case Set_Form:
		for a in v.args do if mentions(p, a) do return true
	case Cases:
		for c in v.cases do if mentions(p, c.value) do return true
	}
	return false
}

// settle : ce qui est tombé à la place du trou `b` désigne-t-il une valeur, celle
// qui contient toutes les autres ? Sinon, l'erreur, au carve.
settle :: proc(k: ^Kernel, landed: []Landing, b: ^Binding, span: syn.Span) -> (^Expr, bool) {
	required: ^Expr = nil
	required_set: Set
	for l in landed {
		if !l.required do continue
		set, closed := color_set(k, l.type)
		if !closed {
			report(k, .Unsupported, span, fmt.tprintf("pas encore dans le kernel : %s requis par %s", brief(l.type), display(b)))
			return nil, false
		}
		if required == nil {
			required, required_set = l.type, set
			continue
		}
		if !set_equal(set, required_set) {
			report(k, .Constraint_Mismatch, span, fmt.tprintf("%s requiert à la fois %s et %s", display(b), brief(required), brief(l.type)))
			return nil, false
		}
	}
	if required != nil {
		for l in landed {
			if l.required do continue
			switch admits(k, required_set, l.type) {
			case .Proved:
			case .Refuted:
				report(k, .Constraint_Mismatch, span, fmt.tprintf("%s ∉ %s, que requiert %s", brief(l.type), brief(required), display(b)))
				return nil, false
			case .Undecided:
				report(k, .Unproven, span, fmt.tprintf("%s ∈ %s, que requiert %s, n'a pas pu être prouvé", brief(l.type), brief(required), display(b)))
				return nil, false
			}
		}
		return required, true
	}
	// que des valeurs envoyées : l'une d'elles contient toutes les autres
	candidates: for candidate in landed {
		set, closed := exact_set(k, candidate.type)
		if !closed do continue
		for l in landed do if admits(k, set, l.type) != .Proved do continue candidates
		return candidate.type, true
	}
	report(k, .Constraint_Mismatch, span, fmt.tprintf("aucune des valeurs reçues par %s ne contient les autres : %s", display(b), listed_types(landed)))
	return nil, false
}

listed_types :: proc(landed: []Landing) -> string {
	parts := make([dynamic]string, context.temp_allocator)
	for l in landed do append(&parts, brief(l.type))
	return strings.join(parts[:], ", ")
}
