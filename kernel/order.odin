package kernel

// THE ORDER OF TERMS
//
// | and & are commutative: their normal form writes their terms in one order. That
// order is read on the terms themselves: their kind, then their parts, a scope by
// the place it is written. Two terms of order 0 are written the same.

term_order :: proc(a, b: Type) -> int {
	ra, rb := term_rank(a), term_rank(b)
	if ra != rb do return ra < rb ? -1 : 1
	switch x in a {
	case None, Invalid:
		return 0
	case Bool:
		return compare_ints(i128(bool(x)), i128(bool(b.(Bool))))
	case Int:
		return compare_ints(i128(x), i128(b.(Int)))
	case Real:
		return real_compare(x, b.(Real))
	case Char:
		return compare_ints(i128(x), i128(b.(Char)))
	case ^Unknown:
		return unknown_order(x, b.(^Unknown))
	case ^Fold:
		return terms_order(fold_parts(x), fold_parts(b.(^Fold)))
	case ^Least:
		return term_order(x.holds, b.(^Least).holds)
	case ^Recurrent:
		y := b.(^Recurrent)
		if len(x.coefficients) != len(y.coefficients) do return len(x.coefficients) < len(y.coefficients) ? -1 : 1
		for c, i in x.coefficients do if c != y.coefficients[i] do return c < y.coefficients[i] ? -1 : 1
		if c := terms_order(x.initial, y.initial); c != 0 do return c
		return term_order(x.at, y.at)
	case ^Series:
		y := b.(^Series)
		if c := compare_ints(i128(x.op), i128(y.op)); c != 0 do return c
		return terms_order({x.lo, x.hi, x.term}, {y.lo, y.hi, y.term})
	case ^Effect:
		y := b.(^Effect)
		if c := compare_ints(i128(x.id), i128(y.id)); c != 0 do return c
		if (x.answer == nil) != (y.answer == nil) do return x.answer == nil ? -1 : 1
		if x.answer != nil do if c := unknown_order(x.answer, y.answer); c != 0 do return c
		return term_order(x.then, y.then)
	case ^Range:
		y := b.(^Range)
		if c := compare_ints(i128(x.family), i128(y.family)); c != 0 do return c
		if c := optional_order(x.lo, y.lo); c != 0 do return c
		return optional_order(x.hi, y.hi)
	case ^Operation:
		y := b.(^Operation)
		if c := compare_ints(i128(x.op), i128(y.op)); c != 0 do return c
		return terms_order(x.args, y.args)
	case ^Or:
		return terms_order(x.terms, b.(^Or).terms)
	case ^And:
		return terms_order(x.terms, b.(^And).terms)
	case ^Not:
		return term_order(x.term, b.(^Not).term)
	case ^Is:
		return term_order(x.term, b.(^Is).term)
	case ^Name:
		// by where its binding is written; the aliases of the prelude, by their name
		y := b.(^Name)
		if x.binding == y.binding do return 0
		if c := compare_ints(i128(x.binding.span.start), i128(y.binding.span.start)); c != 0 do return c
		if x.binding.name != y.binding.name do return x.binding.name < y.binding.name ? -1 : 1
		return scope_order(x.binding.scope, y.binding.scope)
	case ^Scope:
		return scope_order(x, b.(^Scope))
	case ^Access:
		y := b.(^Access)
		if c := term_order(x.target, y.target); c != 0 do return c
		if x.name != y.name do return x.name < y.name ? -1 : 1
		return compare_ints(i128(x.ordinal), i128(y.ordinal))
	case ^Collapse:
		y := b.(^Collapse)
		if c := compare_ints(i128(x.recursive), i128(y.recursive)); c != 0 do return c
		return term_order(x.target, y.target)
	case ^Carve:
		y := b.(^Carve)
		if c := term_order(x.target, y.target); c != 0 do return c
		if len(x.args) != len(y.args) do return len(x.args) < len(y.args) ? -1 : 1
		for a, i in x.args {
			if a.name != y.args[i].name do return a.name < y.args[i].name ? -1 : 1
			if c := term_order(a.value, y.args[i].value); c != 0 do return c
		}
		return 0
	case ^Default:
		return term_order(x.color, b.(^Default).color)
	case ^Pattern:
		y := b.(^Pattern)
		if c := term_order(x.target, y.target); c != 0 do return c
		if len(x.branches) != len(y.branches) do return len(x.branches) < len(y.branches) ? -1 : 1
		for br, i in x.branches {
			if c := optional_order(br.cover, y.branches[i].cover); c != 0 do return c
			if c := term_order(br.product, y.branches[i].product); c != 0 do return c
		}
		return 0
	}
	return 0
}

// unknown_order: an unknown by its index, then by the carve it is read in: ?ₖ read
// in two equal carves is one unknown.
unknown_order :: proc(a, b: ^Unknown) -> int {
	if c := compare_ints(i128(a.id), i128(b.id)); c != 0 do return c
	if a.instance == b.instance do return 0
	if a.instance == nil || b.instance == nil do return a.instance == nil ? -1 : 1
	x, y := a.instance, b.instance
	for binding in x.carved.bindings {
		v, in_x := x.changes[binding]
		w, in_y := y.changes[binding]
		if in_x != in_y do return in_x ? 1 : -1
		if !in_x do continue
		if c := term_order(v, w); c != 0 do return c
	}
	return 0
}

same_unknown :: proc(a, b: ^Unknown) -> bool {
	return unknown_order(a, b) == 0
}

term_less :: proc(a, b: Type) -> bool {
	return term_order(a, b) < 0
}

term_rank :: proc(t: Type) -> int {
	switch _ in t {
	case None:
		return 0
	case Bool:
		return 1
	case Int:
		return 2
	case Real:
		return 3
	case Char:
		return 4
	case ^Unknown:
		return 5
	case ^Range:
		return 6
	case ^Operation:
		return 7
	case ^Or:
		return 8
	case ^And:
		return 9
	case ^Not:
		return 10
	case ^Is:
		return 11
	case ^Name:
		return 12
	case ^Scope:
		return 13
	case ^Access:
		return 14
	case ^Collapse:
		return 15
	case ^Carve:
		return 16
	case ^Default:
		return 17
	case ^Pattern:
		return 18
	case ^Effect:
		return 19
	case Invalid:
		return 20
	case ^Fold:
		return 21
	case ^Least:
		return 22
	case ^Series:
		return 23
	case ^Recurrent:
		return 24
	}
	return 25
}

terms_order :: proc(a, b: []Type) -> int {
	for x, i in a {
		if i >= len(b) do return 1
		if c := term_order(x, b[i]); c != 0 do return c
	}
	return len(a) < len(b) ? -1 : 0
}

optional_order :: proc(a, b: Type) -> int {
	if a == nil || b == nil do return a == nil ? (b == nil ? 0 : -1) : 1
	return term_order(a, b)
}

// scope_order: by the place the scope is written; a carve after what it carves,
// then by the values it gives.
scope_order :: proc(a, b: ^Scope) -> int {
	if a == b do return 0
	if c := compare_ints(i128(a.span.start), i128(b.span.start)); c != 0 do return c
	if c := compare_ints(i128(len(a.bindings)), i128(len(b.bindings))); c != 0 do return c
	for x, i in a.bindings {
		y := b.bindings[i]
		if x.name != y.name do return x.name < y.name ? -1 : 1
		if c := optional_order(x.value, y.value); c != 0 do return c
		if c := optional_order(x.color, y.color); c != 0 do return c
	}
	return 0
}

compare_ints :: proc(a, b: i128) -> int {
	if a == b do return 0
	return a < b ? -1 : 1
}
