package kernel

import "core:slice"
import "core:strings"

// STRINGS (specs/types.md §4.6)
//
// A string is composed of characters; a character is a string of length 1. A set
// of strings is a term: characters, ranges of characters, `+`, `*`, and their
// | & ~. Its laws:
//
//   "jwt" = 'j' + 'w' + 't'        + associative, "" neutral, none absorbing
//   t * 0 = ""      t * 1 = t      t * n = t + t * (n - 1)
//
// Whether a string is in a set, and whether a set of strings is none, are read on
// its quotients (Brzozowski): ∂c t, the strings w such that c + w is in t, by the
// laws
//
//   ∂c c = ""        ∂c d = none        ∂c (a..b) = "" when c is in a..b
//   ∂c (a + b) = ∂c a + b  |  ∂c b                when "" is in a
//   ∂c (a * n) = ∂c a + a * (n - 1)               n - 1 closed downward when "" is in a
//   ∂c (a | b) = ∂c a | ∂c b      ∂c (a & b) = ∂c a & ∂c b      ∂c ~a = string & ~∂c a
//
// and "" in t: "" in a + b when in both, in a * n when n holds 0 or a holds "",
// | & ~ by their laws. Then c + w in t = w in ∂c t. A set of strings is the
// equation t = ("" when "" in t) | c₁ + ∂c₁ t | c₂ + ∂c₂ t | …, over the classes of
// characters t distinguishes. Its quotients are finitely many up to the laws of
// | and & (associative, commutative, idempotent): they form a system of linear
// equations, solved by Arden; t is none when its solution is.

MAX_RUNE :: 0x10FFFF

// string_term: every string, ''.. * 0.. (§3).
string_term :: proc() -> Type {
	return new_operation(.Mul, new_range(Char(0), nil), new_range(Int(0), nil, .Int))
}

// --- the laws of + and * ---

// concatenation: + on strings: flattened, "" neutral, none absorbing; characters
// side by side are one string.
concatenation :: proc(args: []Type) -> Type {
	parts := make([dynamic]Type)
	flatten :: proc(parts: ^[dynamic]Type, a: Type) {
		if o, ok := a.(^Operation); ok && o.op == .Add {
			for x in o.args do flatten(parts, x)
		} else {
			append(parts, a)
		}
	}
	for a in args {
		if is_none(a) do return None{}
		flatten(&parts, a)
	}
	grouped := make([dynamic]Type)
	for i := 0; i < len(parts); {
		j := i
		for j < len(parts) && is_char(parts[j]) do j += 1
		switch {
		case j - i >= 2:
			append(&grouped, new_operation(.Add, ..parts[i:j]))
			i = j
		case j - i == 1:
			append(&grouped, parts[i])
			i = j
		case:
			append(&grouped, parts[i])
			i += 1
		}
	}
	if len(grouped) == 1 do return grouped[0]
	return new_operation(.Add, ..grouped[:])
}

// repetition: t * n: t * 0 = "", t * 1 = t; a string repeated a known number of
// times is that string; none when n holds no count.
repetition :: proc(t: Type, counts: Type) -> Type {
	if is_none(t) || is_none(counts) do return None{}
	if n, single := counts.(Int); single {
		if n == 0 do return empty_string()
		if n == 1 do return t
		if is_string_value(t) || is_char(t) {
			parts := make([dynamic]Type)
			for _ in 0 ..< n do append(&parts, t)
			return concatenation(parts[:])
		}
	}
	return new_operation(.Mul, t, counts)
}

is_char :: proc(t: Type) -> bool {
	_, ok := t.(Char)
	return ok
}

// --- "" in t ---

nullable :: proc(t: Type) -> bool {
	switch v in t {
	case Char, Int, Real, Bool, None, Invalid, ^Unknown, ^Effect, ^Range, ^Is, ^Scope, ^Name, ^Access, ^Collapse, ^Carve, ^Default, ^Pattern:
		return false
	case ^Operation:
		#partial switch v.op {
		case .Add:
			for a in v.args do if !nullable(a) do return false
			return true
		case .Mul:
			return counts_hold(v.args[1], 0) || nullable(v.args[0]) && !is_none(counts_from(v.args[1], 1))
		}
	case ^Or:
		for a in v.terms do if nullable(a) do return true
	case ^And:
		for a in v.terms do if !nullable(a) do return false
		return true
	case ^Not:
		return !nullable(v.term)
	}
	return false
}

// --- the quotients ---

// quotient: ∂c t, in normal form by the laws of +, * and | & of strings.
quotient :: proc(t: Type, c: rune) -> Type {
	switch v in t {
	case Char:
		return rune(v) == c ? empty_string() : None{}
	case ^Range:
		lo, hi := discrete_bounds(t)
		if _, is_chars := v.lo.(Char); !is_chars do return None{}
		if x, ok := lo.?; ok && i128(c) < x do return None{}
		if x, ok := hi.?; ok && i128(c) > x do return None{}
		return empty_string()
	case ^Operation:
		#partial switch v.op {
		case .Add:
			if len(v.args) == 0 do return None{}
			head, rest := v.args[0], concatenation(v.args[1:])
			out := concatenation({quotient(head, c), rest})
			if nullable(head) do out = text_or({out, quotient(rest, c)})
			return out
		case .Mul:
			a, n := v.args[0], v.args[1]
			more := counts_from(n, 1)
			if is_none(more) do return None{}
			less := counts_less(more)
			if nullable(a) do less = counts_below(less)
			return concatenation({quotient(a, c), repetition(a, less)})
		}
	case ^Or:
		parts := make([]Type, len(v.terms))
		for x, i in v.terms do parts[i] = quotient(x, c)
		return text_or(parts)
	case ^And:
		parts := make([]Type, len(v.terms))
		for x, i in v.terms do parts[i] = quotient(x, c)
		return text_and(parts)
	case ^Not:
		return text_and({string_term(), text_not(quotient(v.term, c))})
	case Int, Real, Bool, None, Invalid, ^Unknown, ^Effect, ^Is, ^Scope, ^Name, ^Access, ^Collapse, ^Carve, ^Default, ^Pattern:
	}
	return None{}
}

// text_or, text_and, text_not: | & ~ on sets of strings by the laws of a Boolean
// algebra that keep the quotients finitely many: flattened, none and ~none
// neutral or absorbing, without repetition, in a fixed order; ~~a = a.
text_or :: proc(terms: []Type) -> Type {
	return text_lattice(terms, true)
}

text_and :: proc(terms: []Type) -> Type {
	return text_lattice(terms, false)
}

text_not :: proc(t: Type) -> Type {
	if n, ok := t.(^Not); ok do return n.term
	return new_not(t)
}

text_lattice :: proc(terms: []Type, is_or: bool) -> Type {
	flat := make([dynamic]Type)
	stack := make([dynamic]Type)
	#reverse for t in terms do append(&stack, t)
	for len(stack) > 0 {
		t := pop(&stack)
		if o, ok := t.(^Or); ok && is_or {
			#reverse for x in o.terms do append(&stack, x)
			continue
		}
		if a, ok := t.(^And); ok && !is_or {
			#reverse for x in a.terms do append(&stack, x)
			continue
		}
		switch {
		case is_none(t):
			if !is_or do return None{}
		case is_everything(t):
			if is_or do return everything()
		case:
			append(&flat, t)
		}
	}
	slice.sort_by(flat[:], term_less)
	unique := make([dynamic]Type)
	for t in flat do if len(unique) == 0 || term_order(unique[len(unique) - 1], t) != 0 do append(&unique, t)
	switch len(unique) {
	case 0:
		return is_or ? Type(None{}) : everything()
	case 1:
		return unique[0]
	}
	return is_or ? new_or(..unique[:]) : new_and(..unique[:])
}

// --- the system of quotients ---

// cuts: the characters where a quotient of t may change: the bounds of the
// characters t is written with.
cuts :: proc(t: Type) -> []rune {
	points := make(map[rune]bool)
	points[0] = true
	visit :: proc(points: ^map[rune]bool, t: Type) {
		switch v in t {
		case Char:
			points[rune(v)] = true
			if rune(v) < MAX_RUNE do points[rune(v) + 1] = true
		case ^Range:
			lo, hi := discrete_bounds(t)
			if _, is_chars := v.lo.(Char); !is_chars do return
			if x, ok := lo.?; ok do points[rune(x)] = true
			if x, ok := hi.?; ok && x < MAX_RUNE do points[rune(x + 1)] = true
		case ^Operation:
			for a in v.args do visit(points, a)
		case ^Or:
			for a in v.terms do visit(points, a)
		case ^And:
			for a in v.terms do visit(points, a)
		case ^Not:
			visit(points, v.term)
		case Int, Real, Bool, None, Invalid, ^Unknown, ^Effect, ^Is, ^Scope, ^Name, ^Access, ^Collapse, ^Carve, ^Default, ^Pattern:
		}
	}
	visit(&points, t)
	out := make([dynamic]rune)
	for p in points do append(&out, p)
	slice.sort(out[:])
	return out[:]
}

// Equation: X_q = ("" when "" in q) | Σ class + X_target, the classes of
// characters q distinguishes leading to the quotient they give.
Equation :: struct {
	empty: Type, // "" or none
	terms: [dynamic]Term_Of, // a coefficient, then the unknown of a quotient
}

Term_Of :: struct {
	coefficient: Type,
	target:      int,
}

// equations: the system of t: one equation per quotient of t, finitely many up to
// the laws of | and &.
equations :: proc(t: Type) -> [dynamic]Equation {
	quotients := make([dynamic]Type)
	append(&quotients, t)
	system := make([dynamic]Equation)
	for i := 0; i < len(quotients); i += 1 {
		q := quotients[i]
		e := Equation{empty = nullable(q) ? empty_string() : None{}}
		points := cuts(q)
		for p, n in points {
			d := quotient(q, p)
			if is_none(d) do continue
			target := -1
			for x, j in quotients do if term_order(x, d) == 0 do target = j
			if target < 0 {
				target = len(quotients)
				append(&quotients, d)
			}
			last := n + 1 < len(points) ? i128(points[n + 1]) - 1 : MAX_RUNE
			class := discrete_cell(.Char, i128(p), last)
			merged := false
			for &x in e.terms {
				if x.target == target {
					x.coefficient = text_or({x.coefficient, class})
					merged = true
				}
			}
			if !merged do append(&e.terms, Term_Of{class, target})
		}
		append(&system, e)
	}
	return system
}

// solve_text: the solution of the system of t, eliminated from its last unknown to
// its first by Arden — X = A + X | B gives X = A * 0.. + B, "" not being in A —
// each solution put into the equations above. It is a term of characters, + and
// * and |: t is none when it is none.
solve_text :: proc(t: Type) -> Type {
	system := equations(t)
	#reverse for &e, i in system {
		// Arden on X_i itself
		star: Type = empty_string()
		for x in e.terms do if x.target == i do star = repetition(x.coefficient, new_range(Int(0), nil, .Int))
		kept := make([dynamic]Term_Of)
		for x in e.terms do if x.target != i do append(&kept, Term_Of{concatenation({star, x.coefficient}), x.target})
		e.empty = concatenation({star, e.empty})
		e.terms = kept
		// X_i put into the equations above that name it
		for &above in system[:i] {
			rest := make([dynamic]Term_Of)
			for x in above.terms {
				if x.target != i {
					append(&rest, x)
					continue
				}
				above.empty = text_or({above.empty, concatenation({x.coefficient, e.empty})})
				for y in e.terms do append(&rest, Term_Of{concatenation({x.coefficient, y.coefficient}), y.target})
			}
			above.terms = rest
		}
	}
	return system[0].empty
}

text_empty :: proc(t: Type) -> bool {
	return is_none(solve_text(t))
}

// text_witness: the shortest string of t, the first in the order of characters,
// read on the solution of its system; false when t is none.
text_witness :: proc(t: Type) -> (string, bool) {
	s := solve_text(t)
	if is_none(s) do return "", false
	b := strings.builder_make()
	for c in shortest(s) do strings.write_rune(&b, c)
	return strings.to_string(b), true
}

// shortest: the shortest string of a term of characters, + * and |: of a + b, the
// shortest of each; of a | b, the shorter, the first in the order of characters on
// a tie; of a * n, the shortest of a, n times for the least n.
shortest :: proc(t: Type) -> []rune {
	out := make([dynamic]rune)
	#partial switch v in t {
	case Char:
		append(&out, rune(v))
	case ^Range:
		lo, _ := discrete_bounds(t)
		append(&out, rune(lo.? or_else 0))
	case ^Operation:
		#partial switch v.op {
		case .Add:
			for a in v.args do append(&out, ..shortest(a))
		case .Mul:
			cells, _ := as_cells(v.args[1])
			lo, _ := discrete_bounds(cells[0])
			part := shortest(v.args[0])
			for _ in 0 ..< (lo.? or_else 0) do append(&out, ..part)
		}
	case ^Or:
		best: []rune
		for a, i in v.terms {
			s := shortest(a)
			if i == 0 || len(s) < len(best) || len(s) == len(best) && runes_less(s, best) do best = s
		}
		append(&out, ..best)
	}
	return out[:]
}

runes_less :: proc(a, b: []rune) -> bool {
	for c, i in a do if c != b[i] do return c < b[i]
	return false
}

// text_has: the string s is in t: c + w in t = w in ∂c t, and "" in t.
text_has :: proc(t: Type, s: string) -> bool {
	q := t
	for c in s {
		q = quotient(q, c)
		if is_none(q) do return false
	}
	return nullable(q)
}

// --- counts: the integers of a repetition ---

counts_hold :: proc(n: Type, v: i128) -> bool {
	cells, negated := as_cells(n)
	if negated do return false
	for c in cells {
		if cell_family(c) != .Int do continue
		lo, hi := discrete_bounds(c)
		if x, ok := lo.?; ok && v < x do continue
		if x, ok := hi.?; ok && v > x do continue
		return true
	}
	return false
}

// counts_from: the counts of n from v on.
counts_from :: proc(n: Type, v: i128) -> Type {
	cells, _ := as_cells(n)
	out := make([dynamic]Type)
	for c in cells {
		if cell_family(c) != .Int do continue
		lo, hi := discrete_bounds(c)
		x := discrete_cell(.Int, max_bound(lo, v), hi)
		if !is_none(x) do append(&out, x)
	}
	return cells_term(out[:])
}

// counts_less: n - 1, n ≥ 1.
counts_less :: proc(n: Type) -> Type {
	cells, _ := as_cells(n)
	out := make([dynamic]Type)
	for c in cells {
		lo, hi := discrete_bounds(c)
		l, _ := lo.?
		x: Maybe(i128)
		if h, bounded := hi.?; bounded do x = h - 1
		append(&out, discrete_cell(.Int, l - 1, x))
	}
	return cells_term(out[:])
}

// counts_below: 0 up to the greatest count of n.
counts_below :: proc(n: Type) -> Type {
	cells, _ := as_cells(n)
	if len(cells) == 0 do return None{}
	_, hi := discrete_bounds(cells[len(cells) - 1])
	return discrete_cell(.Int, i128(0), hi)
}
