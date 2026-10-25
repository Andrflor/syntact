package kernel

import syn "../compiler"
import "core:fmt"
import "core:strings"

// FROM THE AST TO TERMS
//
// Each node becomes the term it writes (type.odin). Each name is resolved once, to
// the last occurrence visible above it (§5.2). A scope names itself only from its
// productions (§5.6): that name is marked, and its collapse is a recursive call.
// The file is a scope, inside the prelude of the aliases (§3).

build_program :: proc(k: ^Kernel) -> ^Scope {
	root := syn.ast_root(k.ast)
	s := new_scope(prelude(), node_span(k, root))
	for child in syn.node_children(k.ast, root) do build_binding(k, s, child)
	s.complete = true
	return s
}

new_scope :: proc(parent: ^Scope, span: syn.Span) -> ^Scope {
	s := new(Scope)
	s.parent, s.span = parent, span
	return s
}

new_binding :: proc(s: ^Scope, kind: Kind, span: syn.Span) -> ^Binding {
	b := new(Binding)
	b.kind, b.span, b.scope = kind, span, s
	append(&s.bindings, b)
	return b
}

node_span :: proc(k: ^Kernel, idx: syn.Node_Index) -> syn.Span {
	if idx == syn.INVALID_NODE || int(idx) >= len(k.ast.node_spans) do return {}
	return k.ast.node_spans[idx]
}

unsupported :: proc(k: ^Kernel, idx: syn.Node_Index, what: string) -> Type {
	return report(k, .Unsupported, node_span(k, idx), fmt.tprintf("not in the kernel yet: %s", what))
}

// build_binding adds to s the binding that node idx writes. While its parts are
// built, it is the last binding of s, not yet visible (lookup).
build_binding :: proc(k: ^Kernel, s: ^Scope, idx: syn.Node_Index) {
	ast := k.ast
	data := ast.node_data[idx]
	b := new_binding(s, .Push, node_span(k, idx))
	#partial switch ast.node_kinds[idx] {
	case .Pointing:
		build_left(k, s, data.binary.left, b)
		if data.binary.right == syn.INVALID_NODE {
			b.value = unsupported(k, idx, "an arrow without a value")
		} else {
			b.value = build_term(k, s, data.binary.right)
			if v, is_scope := b.value.(^Scope); is_scope do v.name = b.name
			// `C:x -> ??`: the unknown takes the layout of its color (§5.2)
			if u, is_unknown := b.value.(^Unknown); is_unknown && u.written == nil do u.written = b.color
		}
	case .Constraint:
		build_left(k, s, idx, b)
	case .Product:
		b.kind = .Product
		was := s.producing
		s.producing = true
		defer s.producing = was
		operand := data.unary.operand
		switch {
		case operand == syn.INVALID_NODE:
			b.value = unsupported(k, idx, "a production without a value")
		case ast.node_kinds[operand] == .Constraint:
			build_left(k, s, operand, b)
		case:
			b.value = build_term(k, s, operand)
		}
	case .Expand:
		// `...e` places the bindings of e; `...C:` and `...` are runs (§5.4)
		b.kind = .Expand
		target := data.unary.operand
		switch {
		case target == syn.INVALID_NODE:
		case ast.node_kinds[target] == .Constraint:
			build_left(k, s, target, b)
		case:
			b.value = build_term(k, s, target)
		}
	case .Carve:
		source := data.carve.source
		if source != syn.INVALID_NODE && ast.node_kinds[source] == .Constraint {
			// `C:p{…}`: p, colored by C, is the default of C carved (specs/language/11)
			build_left(k, s, source, b)
			d := new(Default)
			d.color, d.span = b.color, node_span(k, source)
			b.value = build_carve(k, s, idx, d)
		} else {
			b.value = build_term(k, s, idx)
		}
	case .PointingPull:
		b.kind = .Pull
		b.value = unsupported(k, idx, "a hole <-")
	case .EventPush, .EventPull, .ResonancePush, .ResonancePull, .ReactivePush, .ReactivePull:
		b.value = unsupported(k, idx, fmt.tprintf("the arrow %v", ast.node_kinds[idx]))
	case:
		b.value = build_term(k, s, idx) // a lone value is an anonymous binding
	}
}

// build_left: a name, `C:name`, or `C:` (an anonymous colored binding).
build_left :: proc(k: ^Kernel, s: ^Scope, left: syn.Node_Index, b: ^Binding) {
	ast := k.ast
	if left == syn.INVALID_NODE do return
	#partial switch ast.node_kinds[left] {
	case .Identifier:
		b.name = syn.node_name_str(ast, left)
		return
	case .Constraint:
		data := ast.node_data[left].binary
		b.color = build_term(k, s, data.left)
		if name := data.right; name != syn.INVALID_NODE {
			if ast.node_kinds[name] != .Identifier {
				b.color = unsupported(k, name, "a colored binding whose name is not an identifier")
				return
			}
			b.name = syn.node_name_str(ast, name)
		}
		return
	}
	b.color = unsupported(k, left, "a binding whose left side is not a name")
}

build_term :: proc(k: ^Kernel, s: ^Scope, idx: syn.Node_Index) -> Type {
	if idx == syn.INVALID_NODE do return nil
	ast := k.ast
	data := ast.node_data[idx]
	span := node_span(k, idx)
	#partial switch ast.node_kinds[idx] {
	case .Literal:
		return build_literal(k, idx)
	case .Identifier:
		return build_name(k, s, idx)
	case .Operator:
		return written(build_operator(k, s, idx), span)
	case .Range:
		return written(build_range(k, s, idx), span)
	case .CompileTime:
		return build_term(k, s, data.unary.operand)
	case .Unknown:
		return new_unknown(k, nil)
	case .ScopeNode:
		child := new_scope(s, span)
		for c in syn.node_children(ast, idx) do build_binding(k, child, c)
		child.complete = true
		return child
	case .Property:
		prop := data.binary.right
		if data.binary.left == syn.INVALID_NODE do return unsupported(k, idx, "`.x` without a scope before it")
		if prop == syn.INVALID_NODE || ast.node_kinds[prop] != .Identifier do return unsupported(k, idx, "a property that is not a name")
		a := new(Access)
		a.target = build_term(k, s, data.binary.left)
		a.name = syn.node_name_str(ast, prop)
		a.ordinal = int(ast.node_data[prop].identifier.ordinal)
		a.span = span
		return a
	case .Execute:
		if len(syn.node_execute_wrappers(ast, idx)) > 0 do return unsupported(k, idx, "execution patterns")
		c := new(Collapse)
		c.target = build_term(k, s, data.execute.target)
		c.recursive = names_itself(c.target)
		c.span = span
		return c
	case .Carve:
		return build_carve(k, s, idx, build_term(k, s, data.carve.source))
	case .Pattern:
		return build_pattern(k, s, idx)
	case .Constraint:
		if data.binary.right != syn.INVALID_NODE do return unsupported(k, idx, "a named colored binding as a value")
		d := new(Default)
		d.color, d.span = build_term(k, s, data.binary.left), span
		return d
	}
	return unsupported(k, idx, fmt.tprintf("the form %v", ast.node_kinds[idx]))
}

new_unknown :: proc(k: ^Kernel, written: Type) -> ^Unknown {
	u := new(Unknown)
	u.id, u.written = k.unknowns, written
	k.unknowns += 1
	return u
}

// build_range: `l..u`. Between strings, `..` is about positions (§4.3), whichever
// way the bounds are given; a bound written between apostrophes ('a', '') is a
// character, and the range is then over the characters:
//
//   l..u = (l + string) & (string + u)      l.. = l + string      ..u = string + u
build_range :: proc(k: ^Kernel, s: ^Scope, idx: syn.Node_Index) -> Type {
	data := k.ast.node_data[idx].binary
	lo := build_term(k, s, data.left)
	hi := build_term(k, s, data.right)
	if !positional(k.ast, data.left) && !positional(k.ast, data.right) do return new_range(lo, hi)
	parts := make([dynamic]Type)
	if lo != nil do append(&parts, new_operation(.Add, lo, string_term()))
	if hi != nil do append(&parts, new_operation(.Add, string_term(), hi))
	if len(parts) == 0 do return string_term()
	return len(parts) == 1 ? parts[0] : new_and(..parts[:])
}

// positional: a bound written as a string that is not one character between
// apostrophes, or a range of such.
positional :: proc(ast: ^syn.Ast, idx: syn.Node_Index) -> bool {
	if idx == syn.INVALID_NODE do return false
	#partial switch ast.node_kinds[idx] {
	case .Literal:
		lit := ast.node_data[idx].literal
		if lit.kind != .String do return false
		text := decode_string(syn.node_text(ast, idx), lit.quotation)
		return lit.quotation != .simple || strings.rune_count(text) > 1
	case .Range:
		data := ast.node_data[idx].binary
		return positional(ast, data.left) || positional(ast, data.right)
	}
	return false
}

// build_operator: an operator of the language, as a term of the algebra. The
// prefix bounds are their laws (§4.3): >=t = t..  <=t = ..t  >t = t.. & ~t
// <t = ..t & ~t. Equality is =t: a = b is a in =b (§4.5).
build_operator :: proc(k: ^Kernel, s: ^Scope, idx: syn.Node_Index) -> Type {
	ast := k.ast
	data := ast.node_data[idx].operator
	span := node_span(k, idx)
	if data.kind == .Layout {
		// `??::L`: an unknown in the layout L
		if data.left == syn.INVALID_NODE || ast.node_kinds[data.left] != .Unknown do return unsupported(k, idx, "`::` on anything but `??`")
		return new_unknown(k, build_term(k, s, data.right))
	}
	if data.kind == .NotEqual do return report(k, .Invalid_operator, span, "there is no `!=`: the values other than t are written ~t")
	right := build_term(k, s, data.right)
	if data.left == syn.INVALID_NODE {
		#partial switch data.kind {
		case .Subtract:
			return new_operation(.Neg, right)
		case .Not:
			return new_not(right)
		case .BitNot:
			return new_operation(.Bit_Not, right)
		case .Equal:
			return new_is(right)
		case .GreaterEqual:
			return new_range(right, nil)
		case .LessEqual:
			return new_range(nil, right)
		case .Greater:
			return new_and(new_range(right, nil), new_not(right))
		case .Less:
			return new_and(new_range(nil, right), new_not(right))
		}
		return unsupported(k, idx, fmt.tprintf("the prefix operator %v", data.kind))
	}
	left := build_term(k, s, data.left)
	op: Operator
	#partial switch data.kind {
	case .And:
		return new_and(left, right)
	case .Or:
		return new_or(left, right)
	case .Equal:
		return new_operation(.In, left, new_is(right))
	case .Add:
		op = .Add
	case .Subtract:
		op = .Sub
	case .Multiply:
		op = .Mul
	case .Divide:
		op = .Div
	case .Mod:
		op = .Mod
	case .Xor:
		op = .Xor
	case .BitAnd:
		op = .Bit_And
	case .BitOr:
		op = .Bit_Or
	case .LShift:
		op = .Shl
	case .RShift:
		op = .Shr
	case .Less:
		op = .Less
	case .LessEqual:
		op = .Less_Eq
	case .Greater:
		op = .Greater
	case .GreaterEqual:
		op = .Greater_Eq
	case:
		return unsupported(k, idx, fmt.tprintf("the operator %v", data.kind))
	}
	return new_operation(op, left, right)
}

// build_pattern: `target ? {cover -> product …}`. Each branch is a scope under s,
// whose production is the product.
build_pattern :: proc(k: ^Kernel, s: ^Scope, idx: syn.Node_Index) -> Type {
	ast := k.ast
	data := ast.node_data[idx].pattern
	if data.target == syn.INVALID_NODE do return unsupported(k, idx, "a pattern without a target")
	p := new(Pattern)
	p.target, p.span = build_term(k, s, data.target), node_span(k, idx)
	pairs := syn.node_pattern_branches(ast, idx)
	branches := make([dynamic]Branch)
	for i := 0; i + 1 < len(pairs); i += 2 {
		cover, product := pairs[i], pairs[i + 1]
		if product == syn.INVALID_NODE do return unsupported(k, idx, "a branch without a product")
		b := Branch{span = node_span(k, cover != syn.INVALID_NODE ? cover : product)}
		if cover != syn.INVALID_NODE do b.cover = build_term(k, s, cover)
		b.scope = new_scope(s, b.span)
		b.product = build_term(k, b.scope, product)
		b.scope.complete = true
		append(&branches, b)
	}
	p.branches = branches[:]
	return p
}

// build_carve: `target{args}`. A named argument `x -> v` or `x#n -> v` names the
// binding it carves; an unnamed one is positional.
build_carve :: proc(k: ^Kernel, s: ^Scope, idx: syn.Node_Index, target: Type) -> Type {
	ast := k.ast
	args := make([dynamic]Carve_Arg)
	for child in syn.node_carve_children(ast, idx) {
		a := Carve_Arg{ordinal = -1, span = node_span(k, child)}
		#partial switch ast.node_kinds[child] {
		case .Pointing:
			left := ast.node_data[child].binary.left
			if left == syn.INVALID_NODE || ast.node_kinds[left] != .Identifier do return unsupported(k, child, "a carve argument whose name is not an identifier")
			a.name = syn.node_name_str(ast, left)
			a.ordinal = int(ast.node_data[left].identifier.ordinal)
			a.value = build_term(k, s, ast.node_data[child].binary.right)
		case .Carve:
			return unsupported(k, child, "the carve shorthand `z{…}` among arguments")
		case:
			a.value = build_term(k, s, child)
		}
		append(&args, a)
	}
	c := new(Carve)
	c.target, c.args, c.span = target, args[:], node_span(k, idx)
	return c
}

// build_name: the last occurrence of the name visible above, up to the prelude.
build_name :: proc(k: ^Kernel, s: ^Scope, idx: syn.Node_Index) -> Type {
	ast := k.ast
	name := syn.node_name_str(ast, idx)
	ordinal := int(ast.node_data[idx].identifier.ordinal)
	n := new(Name)
	n.span = node_span(k, idx)
	found: bool
	n.binding, n.self, found = lookup(s, name, ordinal)
	if !found do return report(k, .Undefined_Identifier, n.span, fmt.tprintf("`%s` is not defined above", name))
	return n
}

// names_itself: t is the scope being defined, or a carve of it.
names_itself :: proc(t: Type) -> bool {
	#partial switch v in t {
	case ^Name:
		return v.self != nil
	case ^Carve:
		return names_itself(v.target)
	}
	return false
}

// lookup: in each scope from s up, the bindings above the one being built. From a
// production, the binding being built whose value holds it is visible too: the
// scope names itself, and is recursive.
lookup :: proc(s: ^Scope, name: string, ordinal: int) -> (^Binding, ^Scope, bool) {
	child: ^Scope
	for sc := s; sc != nil; child, sc = sc, sc.parent {
		visible := sc.complete ? len(sc.bindings) : len(sc.bindings) - 1
		self := child != nil && child.producing && !sc.complete
		if self do visible = len(sc.bindings)
		found := -1
		if ordinal >= 0 {
			seen := 0
			for i in 0 ..< visible {
				if sc.bindings[i].name != name do continue
				if seen == ordinal {
					found = i
					break
				}
				seen += 1
			}
		} else {
			for i := visible - 1; i >= 0; i -= 1 {
				if sc.bindings[i].name == name {
					found = i
					break
				}
			}
		}
		if found < 0 do continue
		if self && found == len(sc.bindings) - 1 {
			child.recursive = true
			return sc.bindings[found], child, true
		}
		return sc.bindings[found], nil, true
	}
	return nil, nil, false
}

build_literal :: proc(k: ^Kernel, idx: syn.Node_Index) -> Type {
	ast := k.ast
	lit := ast.node_data[idx].literal
	text := syn.node_text(ast, idx)
	switch lit.kind {
	case .Integer, .Hexadecimal, .Binary:
		base: i128 = lit.kind == .Integer ? 10 : (lit.kind == .Hexadecimal ? 16 : 2)
		digits := lit.kind == .Integer ? text : text[2:]
		v, ok := parse_integer(digits, base)
		if !ok do return unsupported(k, idx, "an integer literal beyond 128 bits")
		return Int(v)
	case .Float:
		v, ok := parse_real(text)
		if !ok do return unsupported(k, idx, "a real literal beyond the integers written here")
		return v
	case .String:
		return string_value(decode_string(text, lit.quotation))
	case .Bool:
		return Bool(text == "true")
	}
	return unsupported(k, idx, "this literal")
}

// string_value: a string as the concatenation of its characters (§4.6); a
// character is a string of length 1.
string_value :: proc(s: string) -> Type {
	parts := make([dynamic]Type)
	for c in s do append(&parts, Char(c))
	if len(parts) == 1 do return parts[0]
	return new_operation(.Add, ..parts[:])
}

parse_integer :: proc(digits: string, base: i128) -> (v: i128, ok: bool) {
	for c in digits {
		d: i128
		switch c {
		case '_':
			continue
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

// decode_string: the escapes of a quoted string; the backtick is raw.
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

// prelude: the aliases (§3), bound like any binding.
prelude :: proc() -> ^Scope {
	ints :: proc(lo, hi: i128) -> Type {return new_range(Int(lo), Int(hi), .Int)}
	p := new_scope(nil, {})
	alias :: proc(p: ^Scope, name: string, value: Type) {
		b := new_binding(p, .Push, {})
		b.name, b.value = name, value
	}
	alias(p, "int", new_range(nil, nil, .Int)) // ..0..
	alias(p, "float", new_range(nil, nil, .Real)) // ..0.0..
	alias(p, "f32", new_range(nil, nil, .Real))
	alias(p, "f64", new_range(nil, nil, .Real))
	alias(p, "char", new_range(Char(0), nil)) // ''..
	alias(p, "string", string_term()) // ''.. * 0..
	alias(p, "bool", new_or(Bool(false), Bool(true)))
	alias(p, "none", None{})
	alias(p, "u8", ints(0, 255))
	alias(p, "i8", ints(-128, 127))
	alias(p, "u16", ints(0, 65535))
	alias(p, "i16", ints(-32768, 32767))
	alias(p, "u32", ints(0, 4294967295))
	alias(p, "i32", ints(-2147483648, 2147483647))
	alias(p, "u64", ints(0, 18446744073709551615))
	alias(p, "i64", ints(-9223372036854775808, 9223372036854775807))
	alias(p, "usize", ints(0, 18446744073709551615))
	alias(p, "isize", ints(-9223372036854775808, 9223372036854775807))
	p.complete = true
	return p
}
