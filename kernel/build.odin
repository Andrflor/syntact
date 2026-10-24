package kernel

import syn "../compiler"
import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"

// FROM THE AST TO THE PROGRAM
//
// Each node becomes the expression it writes; each name is resolved once, to the
// last occurrence visible above it (specs/types.md §5.2). The file is a scope,
// inside the prelude, the scope of the aliases (§3).

build_program :: proc(k: ^Kernel) -> ^Frame {
	root := syn.ast_root(k.ast)
	p := prelude()
	s := new_scope(p, node_span(k, root))
	for child in syn.node_children(k.ast, root) do build_binding(k, s, child)
	s.complete = true
	return new_frame(s, new_frame(p, nil))
}

new_scope :: proc(parent: ^Scope, span: syn.Span) -> ^Scope {
	s := new(Scope)
	s.parent = parent
	s.span = span
	return s
}

node_span :: proc(k: ^Kernel, idx: syn.Node_Index) -> syn.Span {
	if idx == syn.INVALID_NODE || int(idx) >= len(k.ast.node_spans) do return {}
	return k.ast.node_spans[idx]
}

unsupported :: proc(k: ^Kernel, idx: syn.Node_Index, what: string) -> Expr {
	report(k, .Unsupported, node_span(k, idx), fmt.tprintf("not in the kernel yet: %s", what))
	return Invalid{}
}

// build_binding adds to s the binding that node idx writes. While its parts are
// built, it is the last binding of s, not yet visible (lookup).
build_binding :: proc(k: ^Kernel, s: ^Scope, idx: syn.Node_Index) {
	ast := k.ast
	data := ast.node_data[idx]
	append(&s.bindings, Binding{span = node_span(k, idx)})
	b := &s.bindings[len(s.bindings) - 1]
	#partial switch ast.node_kinds[idx] {
	case .Pointing:
		build_left(k, s, data.binary.left, b)
		if data.binary.right == syn.INVALID_NODE {
			unsupported(k, idx, "an arrow without a value")
		} else {
			b.value = build_expr(k, s, data.binary.right)
		}
	case .Constraint:
		build_left(k, s, idx, b)
	case .Product:
		b.kind = .Product
		operand := data.unary.operand
		switch {
		case operand == syn.INVALID_NODE:
			unsupported(k, idx, "a production without a value")
		case ast.node_kinds[operand] == .Constraint:
			build_left(k, s, operand, b)
			b.kind = .Product
		case:
			b.value = build_expr(k, s, operand)
		}
	case .PointingPull:
		unsupported(k, idx, "a hole <-")
	case .Expand:
		unsupported(k, idx, "the expansion ...")
	case .EventPush, .EventPull, .ResonancePush, .ResonancePull, .ReactivePush, .ReactivePull:
		unsupported(k, idx, fmt.tprintf("the arrow %v", ast.node_kinds[idx]))
	case:
		b.value = build_expr(k, s, idx) // a lone value is an anonymous binding
	}
}

// build_left: a name, or `C:name`, or `C:` (an anonymous colored binding).
build_left :: proc(k: ^Kernel, s: ^Scope, left: syn.Node_Index, b: ^Binding) {
	ast := k.ast
	if left == syn.INVALID_NODE do return
	#partial switch ast.node_kinds[left] {
	case .Identifier:
		b.name = syn.node_name_str(ast, left)
		return
	case .Constraint:
		data := ast.node_data[left].binary
		b.color = build_expr(k, s, data.left)
		if name := data.right; name != syn.INVALID_NODE {
			if ast.node_kinds[name] != .Identifier {
				unsupported(k, name, "a colored binding whose name is not an identifier")
				return
			}
			b.name = syn.node_name_str(ast, name)
		}
		return
	}
	unsupported(k, left, "a binding whose left side is not a name")
}

build_expr :: proc(k: ^Kernel, s: ^Scope, idx: syn.Node_Index) -> Expr {
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
		return build_operator(k, s, idx)
	case .Range:
		r := new(Range_Expr)
		r.span = span
		r.lo = build_expr(k, s, data.binary.left)
		r.hi = build_expr(k, s, data.binary.right)
		r.ordinal = char_bound(ast, data.binary.left) || char_bound(ast, data.binary.right)
		return r
	case .CompileTime:
		return build_expr(k, s, data.unary.operand)
	case .Unknown:
		u := new(Unknown_Expr)
		u.span = span
		return u
	}
	return unsupported(k, idx, fmt.tprintf("the form %v", ast.node_kinds[idx]))
}

// char_bound: a bound written as one character between apostrophes ('a', or ''),
// or a range of such: the range is then over the characters (§4.3).
char_bound :: proc(ast: ^syn.Ast, idx: syn.Node_Index) -> bool {
	if idx == syn.INVALID_NODE do return false
	#partial switch ast.node_kinds[idx] {
	case .Literal:
		lit := ast.node_data[idx].literal
		text := decode_string(syn.node_text(ast, idx), lit.quotation)
		return lit.kind == .String && lit.quotation == .simple && strings.rune_count(text) <= 1
	case .Range:
		data := ast.node_data[idx].binary
		return char_bound(ast, data.left) || char_bound(ast, data.right)
	}
	return false
}

// build_operator: an operator of the language, as an operation of the algebra.
// The prefix bounds are their laws (§4.3): >=t = t..  <=t = ..t  >t = t.. & ~t
// <t = ..t & ~t. There is no equality operator: equality is =t (§4.5).
build_operator :: proc(k: ^Kernel, s: ^Scope, idx: syn.Node_Index) -> Expr {
	ast := k.ast
	data := ast.node_data[idx].operator
	span := node_span(k, idx)
	right := build_expr(k, s, data.right)
	if data.left == syn.INVALID_NODE {
		#partial switch data.kind {
		case .Subtract:
			return operation(.Neg, span, right)
		case .Not:
			return operation(.Not, span, right)
		case .BitNot:
			return operation(.Bit_Not, span, right)
		case .Equal:
			return operation(.Is, span, right)
		case .GreaterEqual, .LessEqual, .Greater, .Less:
			r := new(Range_Expr)
			r.span = span
			r.ordinal = char_bound(ast, data.right)
			if data.kind == .GreaterEqual || data.kind == .Greater {
				r.lo = right
			} else {
				r.hi = right
			}
			if data.kind == .GreaterEqual || data.kind == .LessEqual do return r
			return operation(.And, span, r, operation(.Not, span, right))
		case .NotEqual:
			report(k, .Invalid_operator, span, "there is no `!=`: the values other than t are written ~t")
			return Invalid{}
		}
		return unsupported(k, idx, fmt.tprintf("the prefix operator %v", data.kind))
	}
	if data.kind == .Layout {
		// `??::L`: an unknown read in the layout L
		if ast.node_kinds[data.left] != .Unknown do return unsupported(k, idx, "`::` on anything but `??`")
		u := new(Unknown_Expr)
		u.layout, u.span = right, span
		return u
	}
	left := build_expr(k, s, data.left)
	op: Op
	#partial switch data.kind {
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
	case .And:
		op = .And
	case .Or:
		op = .Or
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
	case .Equal:
		// a = b is a in =b (§4.5)
		return operation(.In, span, left, operation(.Is, span, right))
	case .NotEqual:
		report(k, .Invalid_operator, span, "there is no `!=`: the values other than t are written ~t")
		return Invalid{}
	case:
		return unsupported(k, idx, fmt.tprintf("the operator %v", data.kind))
	}
	return operation(op, span, left, right)
}

operation :: proc(op: Op, span: syn.Span, args: ..Expr) -> Expr {
	for a in args do if is_invalid_expr(a) do return Invalid{}
	o := new(Operation)
	o^ = Operation{op, clone_exprs(args), span}
	return o
}

clone_exprs :: proc(es: []Expr) -> []Expr {
	out := make([]Expr, len(es))
	copy(out, es)
	return out
}

// build_name: the last occurrence of the name visible above, up to the prelude.
build_name :: proc(k: ^Kernel, s: ^Scope, idx: syn.Node_Index) -> Expr {
	ast := k.ast
	name := syn.node_name_str(ast, idx)
	ordinal := int(ast.node_data[idx].identifier.ordinal)
	if n, found := lookup(s, name, ordinal, node_span(k, idx)); found do return n
	report(k, .Undefined_Identifier, node_span(k, idx), fmt.tprintf("`%s` is not defined above", name))
	return Invalid{}
}

// lookup: in each scope from s up, the bindings above the one being built.
lookup :: proc(s: ^Scope, name: string, ordinal: int, span: syn.Span) -> (Name, bool) {
	for sc := s; sc != nil; sc = sc.parent {
		visible := sc.complete ? len(sc.bindings) : len(sc.bindings) - 1
		if ordinal >= 0 {
			seen := 0
			for i in 0 ..< visible {
				if sc.bindings[i].name != name do continue
				if seen == ordinal do return Name{sc, i, span}, true
				seen += 1
			}
			continue
		}
		for i := visible - 1; i >= 0; i -= 1 do if sc.bindings[i].name == name do return Name{sc, i, span}, true
	}
	return {}, false
}

build_literal :: proc(k: ^Kernel, idx: syn.Node_Index) -> Expr {
	ast := k.ast
	lit := ast.node_data[idx].literal
	text := syn.node_text(ast, idx)
	switch lit.kind {
	case .Integer, .Hexadecimal, .Binary:
		base: i128 = lit.kind == .Integer ? 10 : (lit.kind == .Hexadecimal ? 16 : 2)
		digits := lit.kind == .Integer ? text : text[2:]
		v, ok := parse_integer(digits, base)
		if !ok do return unsupported(k, idx, "an integer literal beyond 128 bits")
		return set_of(v)
	case .Float:
		v, ok := strconv.parse_f64(text)
		if !ok || math.is_inf(v) do return unsupported(k, idx, "a real literal beyond f64")
		return set_of(v)
	case .String:
		return set_of(decode_string(text, lit.quotation))
	case .Bool:
		return set_of(text == "true")
	}
	return unsupported(k, idx, "this literal")
}

// parse_integer: the digits of an integer literal; false beyond the universe of
// integers (ints.odin).
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
	@(static) aliases := [?]struct {
		name:  string,
		value: proc() -> Set,
	} {
		{"int", proc() -> Set {return Set{ints = ints_all()}}},
		{"float", proc() -> Set {return Set{reals = reals_all()}}},
		{"f32", proc() -> Set {return Set{reals = reals_all()}}},
		{"f64", proc() -> Set {return Set{reals = reals_all()}}},
		{"char", proc() -> Set {return Set{words = words_chars()}}},
		{"string", proc() -> Set {return Set{words = words_all()}}}, // ''.. * 0..
		{"bool", proc() -> Set {return Set{bools = {.False, .True}}}},
		{"none", proc() -> Set {return NONE}},
		{"u8", proc() -> Set {return Set{ints = ints_between(0, 255)}}},
		{"i8", proc() -> Set {return Set{ints = ints_between(-128, 127)}}},
		{"u16", proc() -> Set {return Set{ints = ints_between(0, 65535)}}},
		{"i16", proc() -> Set {return Set{ints = ints_between(-32768, 32767)}}},
		{"u32", proc() -> Set {return Set{ints = ints_between(0, 4294967295)}}},
		{"i32", proc() -> Set {return Set{ints = ints_between(-2147483648, 2147483647)}}},
		{"u64", proc() -> Set {return Set{ints = ints_between(0, 18446744073709551615)}}},
		{"i64", proc() -> Set {return Set{ints = ints_between(-9223372036854775808, 9223372036854775807)}}},
		{"usize", proc() -> Set {return Set{ints = ints_between(0, 18446744073709551615)}}},
		{"isize", proc() -> Set {return Set{ints = ints_between(-9223372036854775808, 9223372036854775807)}}},
	}
	p := new_scope(nil, {})
	p.complete = true
	for a in aliases do append(&p.bindings, Binding{name = a.name, kind = .Push, value = a.value()})
	return p
}
