package kernel

import syn "../compiler"
import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"

// Construction de l'IR depuis l'AST. Le langage n'a pas de sucre : chaque nœud
// devient sa forme d'IR, et chaque nom est résolu une fois pour toutes vers le
// binding visible au-dessus de lui (Ref relative).

build_program :: proc(k: ^Kernel, ast: ^syn.Ast) -> ^Scope {
	k.ast = ast
	root := syn.ast_root(ast)
	s := new_scope(prelude(), ast.node_spans[root])
	for child in syn.node_children(ast, root) do build_binding(k, s, child)
	return s
}

unsupported :: proc(k: ^Kernel, idx: syn.Node_Index, what: string) -> ^Expr {
	return report(k, .Unsupported, node_span(k, idx), fmt.tprintf("pas encore dans le kernel : %s", what))
}

node_span :: proc(k: ^Kernel, idx: syn.Node_Index) -> syn.Span {
	if idx == syn.INVALID_NODE || int(idx) >= len(k.ast.node_spans) do return {}
	return k.ast.node_spans[idx]
}

// build_binding ajoute à `s` le binding que décrit le nœud enfant `idx`.
build_binding :: proc(k: ^Kernel, s: ^Scope, idx: syn.Node_Index) {
	ast := k.ast
	data := ast.node_data[idx]
	span := ast.node_spans[idx]
	append(&k.building, Building{s, len(s.bindings), ast.node_kinds[idx] == .Product})
	defer pop(&k.building)
	#partial switch ast.node_kinds[idx] {
	case .Pointing, .PointingPull, .ResonancePush, .ResonancePull, .ReactivePush, .ReactivePull:
		b := Binding{kind = arrow_kind(ast.node_kinds[idx]), span = span}
		if b.kind != .Push && b.kind != .Pull do unsupported(k, idx, fmt.tprintf("la flèche %v", b.kind))
		if b.kind == .Pull && data.binary.left == syn.INVALID_NODE {
			report(k, .Invalid_Binding_Name, span, "un trou porte un nom")
			return
		}
		if !build_left(k, s, data.binary.left, &b) do return
		right := data.binary.right
		if right != syn.INVALID_NODE && ast.node_kinds[right] == .ScopeNode {
			// Le binding existe avant son corps : le corps peut se référer à lui.
			append(&s.bindings, b)
			i := len(s.bindings) - 1
			s.bindings[i].value = build_expr(k, s, right)
			return
		}
		// Le parser accepte une flèche sans valeur (`x ->`, `x -> ()`) ; son sens n'est
		// pas encore fixé.
		b.value = right == syn.INVALID_NODE ? unsupported(k, idx, "une flèche sans valeur") : build_expr(k, s, right)
		append(&s.bindings, b)
	case .Constraint:
		// `C:name` : un binding coloré sans valeur (sa valeur est le défaut de C).
		b := Binding{kind = .Push, span = span}
		if !build_left(k, s, idx, &b) do return
		append(&s.bindings, b)
	case .Product:
		b := Binding{kind = .Product, span = span}
		operand := data.unary.operand
		if operand != syn.INVALID_NODE && ast.node_kinds[operand] == .Constraint {
			// `-> C:` ou `-> C:(e)` : une production colorée.
			cdata := ast.node_data[operand]
			b.color = build_expr(k, s, cdata.binary.left)
			if v := cdata.binary.right; v != syn.INVALID_NODE do b.value = build_expr(k, s, v)
		} else if operand == syn.INVALID_NODE {
			b.value = unsupported(k, idx, "une production sans valeur")
		} else {
			b.value = build_expr(k, s, operand)
		}
		append(&s.bindings, b)
	case .Expand:
		// `...E` dépose la valeur de E ; `...C:` celle d'un binding anonyme coloré par
		// C, et `...` seul, d'un binding coloré par tous les scopes
		target := data.unary.operand
		b := Binding{kind = .Expand, span = span}
		switch {
		case target == syn.INVALID_NODE:
			b.color = new_expr(Set{sorts = {.Scopes}, scopes = .Top})
		case ast.node_kinds[target] == .Constraint:
			if !build_left(k, s, target, &b) do return
		case:
			b.value = build_expr(k, s, target)
		}
		append(&s.bindings, b)
	case .Carve:
		source := data.carve.source
		if source == syn.INVALID_NODE || ast.node_kinds[source] != .Constraint {
			append(&s.bindings, Binding{kind = .Push, value = build_expr(k, s, idx), span = span})
			return
		}
		// `C:p{…}` : p, coloré par C, vaut le défaut de C carvé (specs/language/11)
		b := Binding{kind = .Push, span = span}
		if !build_left(k, s, source, &b) do return
		b.value = new_expr(build_carve_args(k, s, idx, build_default(k, s, source)))
		append(&s.bindings, b)
	case .EventPush:
		append(&s.bindings, Binding{kind = .Event_Push, value = unsupported(k, idx, "l'émission >-"), span = span})
	case .EventPull:
		append(&s.bindings, Binding{kind = .Event_Pull, value = unsupported(k, idx, "le handler -<"), span = span})
	case:
		// Une valeur seule est un binding anonyme.
		append(&s.bindings, Binding{kind = .Push, value = build_expr(k, s, idx), span = span})
	}
}

arrow_kind :: proc(kind: syn.Node_Kind) -> Binding_Kind {
	#partial switch kind {
	case .PointingPull:
		return .Pull
	case .ResonancePush:
		return .Resonance_Push
	case .ResonancePull:
		return .Resonance_Pull
	case .ReactivePush:
		return .Reactive_Push
	case .ReactivePull:
		return .Reactive_Pull
	}
	return .Push
}

// build_left lit le côté gauche d'un binding : un nom, ou `C:nom` (couleur et nom).
build_left :: proc(k: ^Kernel, s: ^Scope, left: syn.Node_Index, b: ^Binding) -> bool {
	ast := k.ast
	if left == syn.INVALID_NODE do return false // erreur de parse, déjà signalée
	#partial switch ast.node_kinds[left] {
	case .Identifier:
		b.name = syn.node_name_str(ast, left)
		b.capture = syn.node_capture_str(ast, left)
		return true
	case .Constraint:
		cdata := ast.node_data[left]
		b.color = build_expr(k, s, cdata.binary.left)
		if name := cdata.binary.right; name != syn.INVALID_NODE {
			if ast.node_kinds[name] != .Identifier {
				report(k, .Invalid_Binding_Name, node_span(k, name), "le nom d'un binding coloré doit être un identifiant")
				return false
			}
			b.name = syn.node_name_str(ast, name)
			b.capture = syn.node_capture_str(ast, name)
		}
		return true
	}
	report(k, .Invalid_Binding_Name, node_span(k, left), "la gauche d'un binding doit être un nom")
	return false
}

build_expr :: proc(k: ^Kernel, s: ^Scope, idx: syn.Node_Index) -> ^Expr {
	if idx == syn.INVALID_NODE do return unsupported(k, idx, "une expression vide")
	ast := k.ast
	data := ast.node_data[idx]
	span := ast.node_spans[idx]
	#partial switch ast.node_kinds[idx] {
	case .Literal:
		return build_literal(k, idx)
	case .Identifier:
		return build_identifier(k, s, idx)
	case .ScopeNode:
		child := new_scope(s, span)
		for c in syn.node_children(ast, idx) do build_binding(k, child, c)
		return new_expr(child)
	case .Property:
		prop := data.binary.right
		if prop == syn.INVALID_NODE || ast.node_kinds[prop] != .Identifier {
			return report(k, .Invalid_Property_Access, span, "une propriété doit être un nom")
		}
		// `.x` sans source : le champ x du scope que carve le carve qui l'entoure
		target := data.binary.left == syn.INVALID_NODE ? new_expr(Carving{span}) : build_expr(k, s, data.binary.left)
		return new_expr(Access{target = target, name = syn.node_name_str(ast, prop), ordinal = int(ast.node_data[prop].identifier.ordinal), span = span})
	case .Execute:
		if len(syn.node_execute_wrappers(ast, idx)) > 0 do return unsupported(k, idx, "les patterns d'exécution")
		if data.execute.target == syn.INVALID_NODE do return unsupported(k, idx, "le collapse sans cible")
		return new_expr(Collapse{target = build_expr(k, s, data.execute.target), span = span})
	case .Operator:
		op := data.operator
		if op.kind == .Cast {
			if op.left != syn.INVALID_NODE && ast.node_kinds[op.left] == .Unknown {
				return new_expr(Unknown{layout = build_expr(k, s, op.right), span = span})
			}
			return unsupported(k, idx, "le cast ::")
		}
		if op.kind == .Equal && op.left == syn.INVALID_NODE {
			// `=X` : la valeur X elle-même, `{-> X}` — `=u8` admet la valeur u8, pas ses
			// éléments
			child := new_scope(s, span)
			append(&child.bindings, Binding{kind = .Product, value = build_expr(k, child, op.right), span = span})
			return new_expr(child)
		}
		left: ^Expr = nil
		if op.left != syn.INVALID_NODE do left = build_expr(k, s, op.left)
		return new_expr(Op{kind = op.kind, left = left, right = build_expr(k, s, op.right), span = span})
	case .Range:
		r := Range{span = span}
		if data.binary.left != syn.INVALID_NODE do r.lo = build_expr(k, s, data.binary.left)
		if data.binary.right != syn.INVALID_NODE do r.hi = build_expr(k, s, data.binary.right)
		return new_expr(r)
	case .Unknown:
		return new_expr(Unknown{span = span})
	case .CompileTime:
		return build_expr(k, s, data.unary.operand)
	case .Carve:
		return build_carve(k, s, idx)
	case .Pattern:
		return build_match(k, s, idx)
	case .Constraint:
		return unsupported(k, idx, "le binding coloré anonyme en position de valeur")
	}
	return unsupported(k, idx, fmt.tprintf("la forme %v", ast.node_kinds[idx]))
}

// build_carve : la cible, et les arguments comme un scope écrit à cet endroit.
build_carve :: proc(k: ^Kernel, s: ^Scope, idx: syn.Node_Index) -> ^Expr {
	return new_expr(build_carve_args(k, s, idx, build_expr(k, s, k.ast.node_data[idx].carve.source)))
}

build_carve_args :: proc(k: ^Kernel, s: ^Scope, idx: syn.Node_Index, target: ^Expr) -> Carve {
	ast := k.ast
	span := ast.node_spans[idx]
	args := new_scope(s, span)
	ordinals := make([dynamic]int)
	for child in syn.node_carve_children(ast, idx) {
		before := len(args.bindings)
		if ast.node_kinds[child] == .Carve && ast.node_kinds[ast.node_data[child].carve.source] == .Identifier {
			append(&args.bindings, Binding{kind = .Push, value = build_shorthand(k, args, child), span = node_span(k, child)})
		} else {
			build_binding(k, args, child)
		}
		if len(args.bindings) > before do append(&ordinals, carve_ordinal(ast, child))
	}
	return Carve{target = target, args = args, ordinals = ordinals[:], span = span}
}

// build_shorthand : `z{…}` sans flèche, parmi les arguments d'un carve. Sa cible,
// `.z` ou le z visible, se choisit au typage (Shorthand) : z peut n'être que le
// champ du scope carvé, sans rien de visible qui s'appelle ainsi.
build_shorthand :: proc(k: ^Kernel, args: ^Scope, idx: syn.Node_Index) -> ^Expr {
	ast := k.ast
	source := ast.node_data[idx].carve.source
	span := ast.node_spans[source]
	name := syn.node_name_str(ast, source)
	ordinal := int(ast.node_data[source].identifier.ordinal)
	sh := Shorthand {
		field = Access{target = new_expr(Carving{span}), name = name, ordinal = ordinal, span = span},
	}
	if ref, found, _ := lookup(k, args, name, ordinal, span); found do sh.outer = new_expr(ref)
	return new_expr(build_carve_args(k, args, idx, new_expr(sh)))
}

// carve_ordinal : l'occurrence que vise un argument nommé `x#n -> v` ; -1 sinon.
carve_ordinal :: proc(ast: ^syn.Ast, child: syn.Node_Index) -> int {
	#partial switch ast.node_kinds[child] {
	case .Pointing, .PointingPull, .ResonancePush, .ResonancePull, .ReactivePush, .ReactivePull:
		left := ast.node_data[child].binary.left
		if left != syn.INVALID_NODE && ast.node_kinds[left] == .Identifier do return int(ast.node_data[left].identifier.ordinal)
	}
	return -1
}

// build_identifier résout un nom vers le binding visible au-dessus de lui, en
// remontant les scopes jusqu'au prélude ; un nom qu'aucun ne définit est une erreur.
build_identifier :: proc(k: ^Kernel, s: ^Scope, idx: syn.Node_Index) -> ^Expr {
	ast := k.ast
	span := ast.node_spans[idx]
	name := syn.node_name_str(ast, idx)
	if name == "" do name = syn.node_capture_str(ast, idx) // `(c)` : un nom entre parenthèses
	ref, found, missing := lookup(k, s, name, int(ast.node_data[idx].identifier.ordinal), span)
	if !found {
		// dans une branche `C: -> …`, le nom est peut-être un champ de C
		for sc := s; sc != nil; sc = sc.parent do if shaped_cover(sc.cover) do return unsupported(k, idx, "la déstructuration")
		return report(k, .Undefined_Identifier, span, missing)
	}
	return new_expr(ref)
}

// build_match : `target ? {…}`. Chaque branche est un scope sous s : sa couverture,
// puis sa production, qui est lexicalement une production de sa couverture.
build_match :: proc(k: ^Kernel, s: ^Scope, idx: syn.Node_Index) -> ^Expr {
	ast := k.ast
	data := ast.node_data[idx].pattern
	if data.target == syn.INVALID_NODE do return unsupported(k, idx, "le pattern sans cible")
	m := Match{target = build_expr(k, s, data.target), span = ast.node_spans[idx]}
	pairs := syn.node_pattern_branches(ast, idx)
	branches := make([dynamic]^Scope)
	for i := 0; i < len(pairs); i += 2 {
		cover := pairs[i]
		product := i + 1 < len(pairs) ? pairs[i + 1] : syn.INVALID_NODE
		if product == syn.INVALID_NODE do return unsupported(k, idx, "une branche sans production")
		b := new_scope(s, node_span(k, cover != syn.INVALID_NODE ? cover : product))
		if cover != syn.INVALID_NODE do b.cover = build_cover(k, b, cover)
		append(&b.bindings, Binding{kind = .Product, value = build_expr(k, b, product), span = node_span(k, product)})
		append(&branches, b)
	}
	m.branches = branches[:]
	return new_expr(m)
}

// build_cover : ce qu'une branche admet. `C:` est un binding anonyme coloré par C :
// sa valeur complète, le défaut de C (`{-> C:}!`) — `u8:` n'admet que 0, `Circle:`
// tout scope de la forme Circle.
build_cover :: proc(k: ^Kernel, b: ^Scope, idx: syn.Node_Index) -> ^Expr {
	ast := k.ast
	#partial switch ast.node_kinds[idx] {
	case .Constraint:
		if ast.node_data[idx].binary.right != syn.INVALID_NODE do return unsupported(k, idx, "la déstructuration")
		return build_default(k, b, idx)
	case .ScopeNode:
		return unsupported(k, idx, "la déstructuration")
	}
	return build_expr(k, b, idx)
}

// build_default : la valeur complète d'un binding coloré `C:…`, le défaut de C :
// `{-> C:}!`.
build_default :: proc(k: ^Kernel, s: ^Scope, constraint: syn.Node_Index) -> ^Expr {
	span := node_span(k, constraint)
	value := new_scope(s, span)
	append(&value.bindings, Binding{kind = .Product, color = build_expr(k, value, k.ast.node_data[constraint].binary.left), span = span})
	return new_expr(Collapse{target = new_expr(value), span = span})
}

// shaped_cover : la couverture `C:`, dont la production peut lire les champs.
shaped_cover :: proc(cover: ^Expr) -> bool {
	if cover == nil do return false
	c, is_collapse := cover^.(Collapse)
	if !is_collapse do return false
	value, is_scope := c.target^.(^Scope)
	return is_scope && len(value.bindings) == 1 && value.bindings[0].kind == .Product && value.bindings[0].color != nil
}

// lookup : le binding visible au-dessus de s qui porte ce nom (la n-ième occurrence
// avec `x#n`) ; sinon, pourquoi il n'y en a pas.
lookup :: proc(k: ^Kernel, s: ^Scope, name: string, ordinal: int, span: syn.Span) -> (ref: Ref, found: bool, missing: string) {
	up := 0
	child: ^Scope = nil // le scope d'où l'on vient
	for sc := s; sc != nil; sc = sc.parent {
		if ordinal >= 0 {
			// `x#n` : la n-ième occurrence, dans le premier scope qui définit le nom.
			seen := 0
			for b, i in sc.bindings {
				if b.name != name || !visible(k, sc, i, child) do continue
				if seen == ordinal do return Ref{up, i, name, span}, true, ""
				seen += 1
			}
			if seen > 0 do return {}, false, fmt.tprintf("'%s#%d' n'existe pas", name, ordinal)
		} else {
			#reverse for b, i in sc.bindings {
				if b.name != name && (b.capture == "" || b.capture != name) do continue
				if visible(k, sc, i, child) do return Ref{up, i, name, span}, true, ""
			}
		}
		up += 1
		child = sc
	}
	return {}, false, fmt.tprintf("'%s' n'est pas défini", name)
}

// visible : le binding i de sc est-il visible depuis child, le scope d'où l'on
// vient ? Un binding qu'on est en train de construire, et dont child est le corps,
// est le scope qui se nomme lui-même : il ne se voit que dans ses productions
// (specs/kernel-recursion.md §7).
visible :: proc(k: ^Kernel, sc: ^Scope, i: int, child: ^Scope) -> bool {
	if child == nil do return true
	in_sc, in_child := false, false
	product := false
	#reverse for b in k.building {
		if !in_sc && b.scope == sc {
			in_sc = true
			if b.index != i do return true // un binding déjà construit
		}
		if !in_child && b.scope == child {
			in_child = true
			product = b.product
		}
	}
	return !in_sc || !in_child || product
}

// Les builtins sont des noms pour des ensembles (specs/language/10). Ils sont les
// bindings du prélude, le scope qui entoure tout fichier : ils se résolvent comme
// tout nom, et un binding du fichier les masque.
BUILTINS := [?]string{"u8", "i8", "u16", "i16", "u32", "i32", "u64", "usize", "i64", "isize", "int", "f32", "f64", "float", "string", "bool", "char", "none"}

prelude :: proc() -> ^Scope {
	p := new_scope(nil)
	for name in BUILTINS {
		v := new_expr(builtin(name))
		append(&p.bindings, Binding{name = name, kind = .Push, value = v, value_type = v})
	}
	return p
}

builtin :: proc(name: string) -> Set {
	switch name {
	case "u8":
		return set_of_ints(ints_range(0, 255))
	case "i8":
		return set_of_ints(ints_range(-128, 127))
	case "u16":
		return set_of_ints(ints_range(0, 65535))
	case "i16":
		return set_of_ints(ints_range(-32768, 32767))
	case "u32":
		return set_of_ints(ints_range(0, 4294967295))
	case "i32":
		return set_of_ints(ints_range(-2147483648, 2147483647))
	case "u64", "usize":
		return set_of_ints(ints_range(0, 18446744073709551615))
	case "i64", "isize":
		return set_of_ints(ints_range(-9223372036854775808, 9223372036854775807))
	case "int":
		return set_of_ints(ints_all())
	case "f32", "f64", "float":
		return set_of_floats(floats_all())
	case "string":
		return set_of_strings(strings_all())
	case "bool":
		return set_of_bools({.False, .True})
	case "char":
		return set_of_chars(chars_all())
	}
	return Set{} // none : l'ensemble vide, une valeur, son propre singleton
}

build_literal :: proc(k: ^Kernel, idx: syn.Node_Index) -> ^Expr {
	ast := k.ast
	lit := ast.node_data[idx].literal
	text := syn.node_text(ast, idx)
	switch lit.kind {
	case .Integer, .Hexadecimal, .Binary:
		base := lit.kind == .Integer ? 10 : (lit.kind == .Hexadecimal ? 16 : 2)
		digits := lit.kind == .Integer ? text : text[2:]
		v, ok := parse_integer(digits, i128(base))
		if !ok do return unsupported(k, idx, "un entier littéral au-delà de i128")
		return new_expr(set_of_ints(ints_point(v)))
	case .Float:
		v, ok := strconv.parse_f64(text)
		if !ok || math.is_inf(v) do return unsupported(k, idx, "un flottant littéral au-delà de f64")
		return new_expr(set_of_floats(floats_point(v)))
	case .String:
		// Entre apostrophes, un caractère (`'a'`, ou le caractère vide `''`) ; entre
		// guillemets, ou entre apostrophes avec plusieurs caractères, une chaîne.
		s := decode_string(text, lit.quotation)
		if lit.quotation == .simple {
			switch strings.rune_count(s) {
			case 0:
				return new_expr(set_of_chars(ints_point(CHAR_EMPTY)))
			case 1:
				return new_expr(set_of_chars(ints_point(i128(first_rune(s)))))
			}
		}
		return new_expr(set_of_strings(strings_point(s)))
	case .Bool:
		return new_expr(set_of_bools(bools_point(text == "true")))
	}
	return unsupported(k, idx, "ce littéral")
}

// parse_integer lit les chiffres d'un entier littéral ; faux s'il sort de l'univers
// des entiers (set.odin).
parse_integer :: proc(digits: string, base: i128) -> (v: i128, ok: bool) {
	for c in digits {
		d: i128
		switch c {
		case '0' ..= '9':
			d = i128(c - '0')
		case 'a' ..= 'f':
			d = i128(c - 'a' + 10)
		case 'A' ..= 'F':
			d = i128(c - 'A' + 10)
		case:
			return 0, false
		}
		if d >= base do return 0, false
		v = mul_checked(v, base) or_return
		v = add_checked(v, d) or_return
	}
	return v, len(digits) > 0
}

// decode_string interprète les échappements (le parser a déjà retiré les
// délimiteurs) ; le backtick est brut.
decode_string :: proc(body: string, quotation: syn.String_Quotation) -> string {
	if quotation == .backtick do return body
	b := strings.builder_make()
	for i := 0; i < len(body); i += 1 {
		c := body[i]
		if c != '\\' || i + 1 >= len(body) {
			strings.write_byte(&b, c)
			continue
		}
		i += 1
		switch body[i] {
		case 'n':
			strings.write_byte(&b, '\n')
		case 't':
			strings.write_byte(&b, '\t')
		case 'r':
			strings.write_byte(&b, '\r')
		case '0':
			strings.write_byte(&b, 0)
		case:
			strings.write_byte(&b, body[i])
		}
	}
	return strings.to_string(b)
}
