package kernel

import syn "../compiler"
import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"

// Building the IR from the AST. The language has no sugar: each node becomes its
// IR form, and each name is resolved once and for all to the binding visible
// above it (relative Ref).

build_program :: proc(k: ^Kernel, ast: ^syn.Ast) -> ^Scope {
	k.ast = ast
	root := syn.ast_root(ast)
	s := new_scope(prelude(), ast.node_spans[root])
	for child in syn.node_children(ast, root) do build_binding(k, s, child)
	return s
}

unsupported :: proc(k: ^Kernel, idx: syn.Node_Index, what: string) -> ^Expr {
	return report(k, .Unsupported, node_span(k, idx), fmt.tprintf("not in the kernel yet: %s", what))
}

node_span :: proc(k: ^Kernel, idx: syn.Node_Index) -> syn.Span {
	if idx == syn.INVALID_NODE || int(idx) >= len(k.ast.node_spans) do return {}
	return k.ast.node_spans[idx]
}

// build_binding adds to `s` the binding that the child node `idx` describes. It
// enters its scope before its parts are built: the binding under construction is
// always the last one of its scope (visible, in lookup).
build_binding :: proc(k: ^Kernel, s: ^Scope, idx: syn.Node_Index) {
	append(&s.bindings, Binding{span = k.ast.node_spans[idx]})
	if !build_parts(k, s, idx, &s.bindings[len(s.bindings) - 1]) do pop(&s.bindings)
}

// build_parts: the arrow, the color, the name and the value of the binding b,
// already in s. False if it is not a binding (its error is reported).
build_parts :: proc(k: ^Kernel, s: ^Scope, idx: syn.Node_Index, b: ^Binding) -> bool {
	ast := k.ast
	data := ast.node_data[idx]
	span := ast.node_spans[idx]
	#partial switch ast.node_kinds[idx] {
	case .Pointing, .PointingPull, .ResonancePush, .ResonancePull, .ReactivePush, .ReactivePull:
		b.kind = arrow_kind(ast.node_kinds[idx])
		if b.kind != .Push && b.kind != .Pull do unsupported(k, idx, fmt.tprintf("the arrow %v", b.kind))
		if b.kind == .Pull && data.binary.left == syn.INVALID_NODE {
			report(k, .Invalid_Binding_Name, span, "a hole carries a name")
			return false
		}
		if !build_left(k, s, data.binary.left, b) do return false
		right := data.binary.right
		if right != syn.INVALID_NODE && ast.node_kinds[right] == .ScopeNode {
			// the body is the value of the binding before being filled: from its
			// productions, the binding sees itself
			body := new_scope(s, ast.node_spans[right])
			b.value = new_expr(body)
			for c in syn.node_children(ast, right) do build_binding(k, body, c)
			return true
		}
		// The parser accepts an arrow without a value (`x ->`, `x -> ()`); its meaning
		// is not settled yet.
		b.value = right == syn.INVALID_NODE ? unsupported(k, idx, "an arrow without a value") : build_expr(k, s, right)
	case .Constraint:
		// `C:name`: a colored binding without a value (its value is the default of C).
		b.kind = .Push
		return build_left(k, s, idx, b)
	case .Product:
		b.kind = .Product
		operand := data.unary.operand
		if operand != syn.INVALID_NODE && ast.node_kinds[operand] == .Constraint {
			// `-> C:` or `-> C:(e)`: a colored production.
			cdata := ast.node_data[operand]
			b.color = build_expr(k, s, cdata.binary.left)
			if v := cdata.binary.right; v != syn.INVALID_NODE do b.value = build_expr(k, s, v)
		} else if operand == syn.INVALID_NODE {
			b.value = unsupported(k, idx, "a production without a value")
		} else {
			b.value = build_expr(k, s, operand)
		}
	case .Expand:
		// `...E` deposits the value of E; `...C:` that of an anonymous binding colored
		// by C, and `...` alone, that of a binding colored by all scopes
		target := data.unary.operand
		b.kind = .Expand
		switch {
		case target == syn.INVALID_NODE:
			b.color = new_expr(Set{sorts = {.Scopes}, scopes = .Top})
		case ast.node_kinds[target] == .Constraint:
			return build_left(k, s, target, b)
		case:
			b.value = build_expr(k, s, target)
		}
	case .Carve:
		b.kind = .Push
		source := data.carve.source
		if source == syn.INVALID_NODE || ast.node_kinds[source] != .Constraint {
			b.value = build_expr(k, s, idx)
			return true
		}
		// `C:p{…}`: p, colored by C, is the default of C carved (specs/language/11)
		if !build_left(k, s, source, b) do return false
		b.value = new_expr(build_carve_args(k, s, idx, build_default(k, s, source)))
	case .EventPush:
		b.kind = .Event_Push
		b.value = unsupported(k, idx, "the emission >-")
	case .EventPull:
		b.kind = .Event_Pull
		b.value = unsupported(k, idx, "the handler -<")
	case:
		// A lone value is an anonymous binding.
		b.kind = .Push
		b.value = build_expr(k, s, idx)
	}
	return true
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

// build_left reads the left side of a binding: a name, or `C:name` (color and name).
build_left :: proc(k: ^Kernel, s: ^Scope, left: syn.Node_Index, b: ^Binding) -> bool {
	ast := k.ast
	if left == syn.INVALID_NODE do return false // parse error, already reported
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
				report(k, .Invalid_Binding_Name, node_span(k, name), "the name of a colored binding must be an identifier")
				return false
			}
			b.name = syn.node_name_str(ast, name)
			b.capture = syn.node_capture_str(ast, name)
		}
		return true
	}
	report(k, .Invalid_Binding_Name, node_span(k, left), "the left of a binding must be a name")
	return false
}

build_expr :: proc(k: ^Kernel, s: ^Scope, idx: syn.Node_Index) -> ^Expr {
	if idx == syn.INVALID_NODE do return unsupported(k, idx, "an empty expression")
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
			return report(k, .Invalid_Property_Access, span, "a property must be a name")
		}
		// `.x` without a source: the field x of the scope carved by the carve around it
		target := data.binary.left == syn.INVALID_NODE ? new_expr(Carving{span}) : build_expr(k, s, data.binary.left)
		return new_expr(Access{target = target, name = syn.node_name_str(ast, prop), ordinal = int(ast.node_data[prop].identifier.ordinal), span = span})
	case .Execute:
		if len(syn.node_execute_wrappers(ast, idx)) > 0 do return unsupported(k, idx, "execution patterns")
		if data.execute.target == syn.INVALID_NODE do return unsupported(k, idx, "the collapse without a target")
		return new_expr(Collapse{target = build_expr(k, s, data.execute.target), span = span})
	case .Operator:
		op := data.operator
		if op.kind == .Layout {
			// `??::T`: an unknown of type T; the cast is written `\`
			if op.left != syn.INVALID_NODE && ast.node_kinds[op.left] == .Unknown {
				return new_expr(Unknown{layout = build_expr(k, s, op.right), span = span})
			}
			return report(k, .Invalid_Cast, span, "`::` only writes the type of an unknown, `??::u8`; the cast is written `\\`")
		}
		if op.kind == .Equal && op.left == syn.INVALID_NODE {
			// `=X`: the value X itself, `{-> X}` — `=u8` admits the value u8, not its
			// elements
			child := new_scope(s, span)
			append(&child.bindings, Binding{kind = .Product, span = span})
			child.bindings[0].value = build_expr(k, child, op.right)
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
		return unsupported(k, idx, "the anonymous colored binding in value position")
	}
	return unsupported(k, idx, fmt.tprintf("the form %v", ast.node_kinds[idx]))
}

// build_carve: the target, and the arguments as a scope written at this place.
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
			append(&args.bindings, Binding{kind = .Push, span = node_span(k, child)})
			args.bindings[len(args.bindings) - 1].value = build_shorthand(k, args, child)
		} else {
			build_binding(k, args, child)
		}
		if len(args.bindings) > before do append(&ordinals, carve_ordinal(ast, child))
	}
	return Carve{target = target, args = args, ordinals = ordinals[:], span = span}
}

// build_shorthand: `z{…}` without an arrow, among the arguments of a carve. Its
// target, `.z` or the visible z, is chosen at typing (Shorthand): z may be only
// the field of the carved scope, with nothing visible of that name.
build_shorthand :: proc(k: ^Kernel, args: ^Scope, idx: syn.Node_Index) -> ^Expr {
	ast := k.ast
	source := ast.node_data[idx].carve.source
	span := ast.node_spans[source]
	name := syn.node_name_str(ast, source)
	ordinal := int(ast.node_data[source].identifier.ordinal)
	sh := Shorthand {
		field = Access{target = new_expr(Carving{span}), name = name, ordinal = ordinal, span = span},
	}
	if ref, found, _ := lookup(args, name, ordinal, span); found do sh.outer = new_expr(ref)
	return new_expr(build_carve_args(k, args, idx, new_expr(sh)))
}

// carve_ordinal: the occurrence a named argument `x#n -> v` aims at; -1 otherwise.
carve_ordinal :: proc(ast: ^syn.Ast, child: syn.Node_Index) -> int {
	#partial switch ast.node_kinds[child] {
	case .Pointing, .PointingPull, .ResonancePush, .ResonancePull, .ReactivePush, .ReactivePull:
		left := ast.node_data[child].binary.left
		if left != syn.INVALID_NODE && ast.node_kinds[left] == .Identifier do return int(ast.node_data[left].identifier.ordinal)
	}
	return -1
}

// build_identifier resolves a name to the binding visible above it, going up the
// scopes up to the prelude; a name that none defines is an error.
build_identifier :: proc(k: ^Kernel, s: ^Scope, idx: syn.Node_Index) -> ^Expr {
	ast := k.ast
	span := ast.node_spans[idx]
	name := syn.node_name_str(ast, idx)
	if name == "" do name = syn.node_capture_str(ast, idx) // `(c)`: a name in parentheses
	ref, found, missing := lookup(s, name, int(ast.node_data[idx].identifier.ordinal), span)
	if !found {
		// in a branch `C: -> …`, the name is perhaps a field of C
		for sc := s; sc != nil; sc = sc.parent do if shaped_cover(sc.cover) do return unsupported(k, idx, "destructuring")
		return report(k, .Undefined_Identifier, span, missing)
	}
	return new_expr(ref)
}

// build_match: `target ? {…}`. Each branch is a scope under s: its cover, then
// its production, which is lexically a production of its cover.
build_match :: proc(k: ^Kernel, s: ^Scope, idx: syn.Node_Index) -> ^Expr {
	ast := k.ast
	data := ast.node_data[idx].pattern
	if data.target == syn.INVALID_NODE do return unsupported(k, idx, "the pattern without a target")
	m := Match{target = build_expr(k, s, data.target), span = ast.node_spans[idx]}
	pairs := syn.node_pattern_branches(ast, idx)
	branches := make([dynamic]^Scope)
	for i := 0; i < len(pairs); i += 2 {
		cover := pairs[i]
		product := i + 1 < len(pairs) ? pairs[i + 1] : syn.INVALID_NODE
		if product == syn.INVALID_NODE do return unsupported(k, idx, "a branch without a production")
		b := new_scope(s, node_span(k, cover != syn.INVALID_NODE ? cover : product))
		if cover != syn.INVALID_NODE do b.cover = build_cover(k, b, cover)
		append(&b.bindings, Binding{kind = .Product, span = node_span(k, product)})
		b.bindings[0].value = build_expr(k, b, product)
		append(&branches, b)
	}
	m.branches = branches[:]
	return new_expr(m)
}

// build_cover: what a branch admits. `C:` is an anonymous binding colored by C:
// its complete value, the default of C (`{-> C:}!`) — `u8:` admits only 0,
// `Circle:` any scope of the shape Circle.
build_cover :: proc(k: ^Kernel, b: ^Scope, idx: syn.Node_Index) -> ^Expr {
	ast := k.ast
	#partial switch ast.node_kinds[idx] {
	case .Constraint:
		if ast.node_data[idx].binary.right != syn.INVALID_NODE do return unsupported(k, idx, "destructuring")
		return build_default(k, b, idx)
	case .ScopeNode:
		return unsupported(k, idx, "destructuring")
	}
	return build_expr(k, b, idx)
}

// build_default: the complete value of a colored binding `C:…`, the default of
// C: `{-> C:}!`.
build_default :: proc(k: ^Kernel, s: ^Scope, constraint: syn.Node_Index) -> ^Expr {
	span := node_span(k, constraint)
	value := new_scope(s, span)
	append(&value.bindings, Binding{kind = .Product, color = build_expr(k, value, k.ast.node_data[constraint].binary.left), span = span})
	return new_expr(Collapse{target = new_expr(value), span = span})
}

// shaped_cover: the cover `C:`, whose production can read the fields.
shaped_cover :: proc(cover: ^Expr) -> bool {
	if cover == nil do return false
	c, is_collapse := cover^.(Collapse)
	if !is_collapse do return false
	value, is_scope := c.target^.(^Scope)
	return is_scope && len(value.bindings) == 1 && value.bindings[0].kind == .Product && value.bindings[0].color != nil
}

// lookup: the binding visible above s that carries this name (the n-th occurrence
// with `x#n`); otherwise, why there is none.
lookup :: proc(s: ^Scope, name: string, ordinal: int, span: syn.Span) -> (ref: Ref, found: bool, missing: string) {
	up := 0
	child: ^Scope = nil // the scope we come from
	for sc := s; sc != nil; sc = sc.parent {
		if ordinal >= 0 {
			// `x#n`: the n-th occurrence, in the first scope that defines the name.
			seen := 0
			for b, i in sc.bindings {
				if b.name != name || !visible(sc, i, child) do continue
				if seen == ordinal do return Ref{up, i, name, span}, true, ""
				seen += 1
			}
			if seen > 0 do return {}, false, fmt.tprintf("'%s#%d' does not exist", name, ordinal)
		} else {
			#reverse for b, i in sc.bindings {
				if b.name != name && (b.capture == "" || b.capture != name) do continue
				if visible(sc, i, child) do return Ref{up, i, name, span}, true, ""
			}
		}
		up += 1
		child = sc
	}
	return {}, false, fmt.tprintf("'%s' is not defined", name)
}

// visible: is the binding i of sc visible from child, the scope we come from? The
// binding under construction is the last one of its scope (build_binding): it is
// seen only from the productions of the scope that is its value
// (specs/kernel-recursion.md §7). The prelude is already built.
visible :: proc(sc: ^Scope, i: int, child: ^Scope) -> bool {
	if sc.parent == nil || i != len(sc.bindings) - 1 do return true
	body, literal := scope_literal(sc.bindings[i].value)
	if !literal || body != child || len(child.bindings) == 0 do return false
	return child.bindings[len(child.bindings) - 1].kind == .Product
}

// The builtins are names for sets (specs/language/10). They are the bindings of
// the prelude, the scope that surrounds every file: they resolve like any name,
// and a binding of the file shadows them.
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
	return Set{} // none: the empty set, a value, its own singleton
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
		if !ok do return unsupported(k, idx, "an integer literal beyond i128")
		return new_expr(set_of_ints(ints_point(v)))
	case .Float:
		v, ok := strconv.parse_f64(text)
		if !ok || math.is_inf(v) do return unsupported(k, idx, "a float literal beyond f64")
		return new_expr(set_of_floats(floats_point(v)))
	case .String:
		// Between apostrophes, a character (`'a'`, or the empty character `''`);
		// between double quotes, or between apostrophes with several characters, a
		// string.
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
	return unsupported(k, idx, "this literal")
}

// parse_integer reads the digits of an integer literal; false if it leaves the
// universe of integers (set.odin).
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

// decode_string interprets the escapes (the parser has already removed the
// delimiters); the backtick is raw.
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
