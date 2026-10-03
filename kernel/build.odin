package kernel

import syn "../compiler"
import "core:fmt"
import "core:strconv"
import "core:strings"

// Construction de l'IR depuis l'AST. Le langage n'a pas de sucre : chaque nœud
// devient sa forme d'IR, et chaque nom est résolu une fois pour toutes vers le
// binding visible au-dessus de lui (Ref relative).

build_program :: proc(k: ^Kernel, ast: ^syn.Ast) -> ^Scope {
	k.ast = ast
	root := syn.ast_root(ast)
	s := new_scope(nil, ast.node_spans[root])
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
	#partial switch ast.node_kinds[idx] {
	case .Pointing, .PointingPull, .ResonancePush, .ResonancePull, .ReactivePush, .ReactivePull:
		b := Binding{kind = arrow_kind(ast.node_kinds[idx]), span = span}
		if b.kind != .Push do unsupported(k, idx, fmt.tprintf("la flèche %v", b.kind))
		if !build_left(k, s, data.binary.left, &b) do return
		right := data.binary.right
		if right != syn.INVALID_NODE && ast.node_kinds[right] == .ScopeNode {
			// Le binding existe avant son corps : le corps peut se référer à lui.
			append(&s.bindings, b)
			i := len(s.bindings) - 1
			s.bindings[i].value = build_expr(k, s, right)
			return
		}
		b.value = build_expr(k, s, right)
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
		} else {
			b.value = build_expr(k, s, operand)
		}
		append(&s.bindings, b)
	case .Expand:
		append(&s.bindings, Binding{kind = .Expand, value = unsupported(k, idx, "l'expansion ..."), span = span})
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
	if idx == syn.INVALID_NODE do return new_expr(Invalid{}) // erreur de parse, déjà signalée
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
		if data.binary.left == syn.INVALID_NODE do return unsupported(k, idx, "la propriété sans source .x")
		prop := data.binary.right
		if prop == syn.INVALID_NODE || ast.node_kinds[prop] != .Identifier {
			return report(k, .Invalid_Property_Access, span, "une propriété doit être un nom")
		}
		return new_expr(
			Access {
				target = build_expr(k, s, data.binary.left),
				name = syn.node_name_str(ast, prop),
				ordinal = int(ast.node_data[prop].identifier.ordinal),
				span = span,
			},
		)
	case .Execute:
		if len(syn.node_execute_wrappers(ast, idx)) > 0 do return unsupported(k, idx, "les patterns d'exécution")
		return new_expr(Collapse{target = build_expr(k, s, data.execute.target), span = span})
	case .Operator:
		op := data.operator
		if op.kind == .Cast {
			if op.left != syn.INVALID_NODE && ast.node_kinds[op.left] == .Unknown {
				return new_expr(Unknown{layout = build_expr(k, s, op.right), span = span})
			}
			return unsupported(k, idx, "le cast ::")
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
		return unsupported(k, idx, "le carve")
	case .Pattern:
		return unsupported(k, idx, "le pattern ?")
	case .Constraint:
		return unsupported(k, idx, "le binding coloré anonyme en position de valeur")
	}
	return unsupported(k, idx, fmt.tprintf("la forme %v", ast.node_kinds[idx]))
}

// build_identifier résout un nom vers le binding visible au-dessus de lui, en
// remontant les scopes ; un nom inconnu des scopes est un builtin, ou une erreur.
build_identifier :: proc(k: ^Kernel, s: ^Scope, idx: syn.Node_Index) -> ^Expr {
	ast := k.ast
	span := ast.node_spans[idx]
	name := syn.node_name_str(ast, idx)
	if name == "" do name = syn.node_capture_str(ast, idx) // `(c)` : un nom entre parenthèses
	ordinal := int(ast.node_data[idx].identifier.ordinal)

	up := 0
	for sc := s; sc != nil; sc = sc.parent {
		if ordinal >= 0 {
			// `x#n` : la n-ième occurrence, dans le premier scope qui définit le nom.
			seen := 0
			for b, i in sc.bindings {
				if b.name != name do continue
				if seen == ordinal do return new_expr(Ref{up, i, span})
				seen += 1
			}
			if seen > 0 {
				return report(k, .Undefined_Identifier, span, fmt.tprintf("'%s#%d' n'existe pas", name, ordinal))
			}
		} else {
			#reverse for b, i in sc.bindings {
				if b.name == name || (b.capture != "" && b.capture == name) do return new_expr(Ref{up, i, span})
			}
		}
		up += 1
	}
	if set, ok := builtin(name); ok do return new_expr(set)
	if name == "char" do return unsupported(k, idx, "char (les chaînes d'un caractère attendent l'algèbre des chaînes)")
	return report(k, .Undefined_Identifier, span, fmt.tprintf("'%s' n'est pas défini", name))
}

// Les builtins sont des noms pour des ensembles (specs/language/10).
builtin :: proc(name: string) -> (Set, bool) {
	switch name {
	case "u8":
		return set_of_ints(ints_range(0, 255)), true
	case "i8":
		return set_of_ints(ints_range(-128, 127)), true
	case "u16":
		return set_of_ints(ints_range(0, 65535)), true
	case "i16":
		return set_of_ints(ints_range(-32768, 32767)), true
	case "u32":
		return set_of_ints(ints_range(0, 4294967295)), true
	case "i32":
		return set_of_ints(ints_range(-2147483648, 2147483647)), true
	case "u64", "usize":
		return set_of_ints(ints_range(0, 18446744073709551615)), true
	case "i64", "isize":
		return set_of_ints(ints_range(-9223372036854775808, 9223372036854775807)), true
	case "int":
		return set_of_ints(ints_all()), true
	case "f32", "f64", "float":
		return set_of_floats(floats_all()), true
	case "string":
		return set_of_strings(strings_all()), true
	case "bool":
		return set_of_bools({.False, .True}), true
	case "none":
		return Set{}, true // l'ensemble vide : une valeur, son propre singleton
	}
	return {}, false
}

build_literal :: proc(k: ^Kernel, idx: syn.Node_Index) -> ^Expr {
	ast := k.ast
	lit := ast.node_data[idx].literal
	text := syn.node_text(ast, idx)
	span := ast.node_spans[idx]
	switch lit.kind {
	case .Integer, .Hexadecimal, .Binary:
		base := lit.kind == .Integer ? 10 : (lit.kind == .Hexadecimal ? 16 : 2)
		digits := lit.kind == .Integer ? text : text[2:]
		v, ok := strconv.parse_u64_of_base(digits, base)
		if !ok do return unsupported(k, idx, "un entier littéral au-delà de 64 bits")
		return new_expr(set_of_ints(ints_point(i128(v))))
	case .Float:
		v, ok := strconv.parse_f64(text)
		if !ok do return report(k, .Unsupported, span, "flottant illisible")
		return new_expr(set_of_floats(floats_point(v)))
	case .String:
		return new_expr(set_of_strings(strings_point(decode_string(text, lit.quotation))))
	case .Bool:
		return new_expr(set_of_bools(bools_point(text == "true")))
	}
	return unsupported(k, idx, "ce littéral")
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
