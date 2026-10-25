package kernel

import "core:slice"

// THE LAWS OF | & ~ ON CONSTANT TYPES (specs/types.md §4.1–4.4)
//
// A constant type in normal form is none, ~none, a | of cells, or the ~ of a | of
// cells. A cell is a set of one family, written as the grammar writes it:
//
//   integers     5      0..255       ..4       6..
//   reals        0.5    0.0..1.0     0.0.. & ~0.0              (>0.0, §4.3)
//   characters   'a'    'a'..'z'     ''..
//   strings      "jwt"  "jwt" + string    'a'..'z' * 1..   and their & ~ (strings.odin)
//   booleans     false  true
//   values       a scope, =t: taken as they are
//   others       a set the laws leave as an operation: u8 * u8
//
// Two cells of different families have nothing in common (§4.2). On cells of one
// family, the laws compute:
//
//   a..b & c..d    = max(a, c)..min(b, d)          none when empty
//   a..b | c..d    = min(a, c)..max(b, d)          when they meet or touch
//   a..b & ~(c..d) = a..(c - 1) | (d + 1)..b       and likewise for the reals,
//                                                  whose bounds may be open
// and, by De Morgan, ~a & ~b = ~(a | b), a | ~b = ~(b & ~a), ~~a = a.

Cell_Family :: enum u8 {
	Int,
	Real,
	Char,
	Text,
	Bool,
	Value,
	Other,
}

cell_family :: proc(t: Type) -> Cell_Family {
	#partial switch v in t {
	case Int:
		return .Int
	case Real:
		return .Real
	case Char:
		return .Char
	case Bool:
		return .Bool
	case ^Range:
		switch v.family {
		case .Int:
			return .Int
		case .Real:
			return .Real
		case .Any:
		}
		return .Char
	case ^Scope, ^Is:
		return .Value
	case ^And:
		families: bit_set[Cell_Family]
		for x in v.terms do families += {cell_family(x)}
		if _, ok := v.terms[0].(^Range); ok && families == {.Real} do return .Real
		if .Value in families do return .Value
		if families <= {.Text, .Char} do return .Text
		return .Other
	case ^Not:
		return cell_family(v.term)
	case ^Operation:
		if is_text(t) do return .Text
	}
	return .Other
}

// is_text: a set of strings: characters, +, *, and their | & ~.
is_text :: proc(t: Type) -> bool {
	#partial switch v in t {
	case Char:
		return true
	case ^Range:
		_, ok := v.lo.(Char)
		return ok
	case ^Operation:
		#partial switch v.op {
		case .Add:
			for a in v.args do if !is_text(a) do return false
			return true
		case .Mul:
			return is_text(v.args[0])
		}
	case ^Or:
		for a in v.terms do if !is_text(a) do return false
		return true
	case ^And:
		for a in v.terms do if !is_text(a) do return false
		return true
	case ^Not:
		return is_text(v.term)
	}
	return false
}

// as_cells: a constant normal form as its cells, and whether it is their ~.
as_cells :: proc(t: Type) -> (cells: []Type, negated: bool) {
	#partial switch v in t {
	case None:
		return nil, false
	case ^Not:
		inner, _ := as_cells(v.term)
		return inner, true
	case ^Or:
		return v.terms, false
	}
	return slice.clone([]Type{t}), false
}

// cells_term: the | of cells, in a fixed order.
cells_term :: proc(cells: []Type) -> Type {
	switch len(cells) {
	case 0:
		return None{}
	case 1:
		return cells[0]
	}
	sorted := slice.clone(cells)
	slice.sort_by(sorted, cell_less)
	return new_or(..sorted)
}

cell_less :: proc(a, b: Type) -> bool {
	fa, fb := cell_family(a), cell_family(b)
	if fa != fb do return fa < fb
	#partial switch fa {
	case .Int, .Char:
		x, _ := discrete_bounds(a)
		y, _ := discrete_bounds(b)
		return bound_before(x, y)
	case .Real:
		x, y := real_bounds(a), real_bounds(b)
		u, has_u := x.lo.?
		v, has_v := y.lo.?
		if !has_u || !has_v do return !has_u && has_v
		return real_less(u, v)
	case .Bool:
		return !bool(a.(Bool)) && bool(b.(Bool))
	}
	return term_less(a, b)
}

// bound_before: a lower bound before another; nil is -∞.
bound_before :: proc(a, b: Maybe(i128)) -> bool {
	x, has_x := a.?
	y, has_y := b.?
	if !has_x || !has_y do return !has_x && has_y
	return x < y
}

// --- the constant normal forms ---

// or_constants: a | b; with a ~: ~u₁ | ~u₂ = ~(u₁ & u₂), p | ~u = ~(u & ~p).
or_constants :: proc(k: ^Kernel, terms: []Type) -> Type {
	positives := make([dynamic]Type)
	negatives := make([dynamic][]Type)
	for t in terms {
		cells, negated := as_cells(t)
		if negated {
			append(&negatives, cells)
		} else {
			append(&positives, ..cells)
		}
	}
	if len(negatives) == 0 do return cells_term(union_cells(k, positives[:]))
	u := negatives[0]
	for n in negatives[1:] do u = meet_cells(k, u, n)
	u = minus_cells(k, u, union_cells(k, positives[:]))
	return new_not(cells_term(u))
}

// and_constants: a & b; with a ~: ~u₁ & ~u₂ = ~(u₁ | u₂), p & ~u = p minus u.
and_constants :: proc(k: ^Kernel, terms: []Type) -> Type {
	positive: []Type
	bounded := false // a positive term was met: what is left is in it
	negatives := make([dynamic]Type)
	for t in terms {
		cells, negated := as_cells(t)
		if negated {
			append(&negatives, ..cells)
		} else if !bounded {
			positive, bounded = cells, true
		} else {
			positive = meet_cells(k, positive, cells)
		}
	}
	u := union_cells(k, negatives[:])
	if !bounded do return new_not(cells_term(u))
	return cells_term(minus_cells(k, positive, u))
}

// not_constant: ~ of a constant normal form: ~~u = u.
not_constant :: proc(t: Type) -> Type {
	cells, negated := as_cells(t)
	if negated do return cells_term(cells)
	return new_not(cells_term(cells))
}

// --- | of cells ---

union_cells :: proc(k: ^Kernel, cells: []Type) -> []Type {
	by: [Cell_Family][dynamic]Type
	for c in cells do if !is_none(c) do append(&by[cell_family(c)], c)
	out := make([dynamic]Type)
	append(&out, ..join_discrete(.Int, by[.Int][:]))
	append(&out, ..join_reals(by[.Real][:]))
	texts := unique_cells(k, by[.Text][:])
	// a set of strings in another one is absorbed
	kept := make([dynamic]Type)
	for t, i in texts {
		absorbed := false
		for u, j in texts do if i != j && text_empty(text_and({t, text_not(u)})) && !(j > i && text_empty(text_and({u, text_not(t)}))) do absorbed = true
		if !absorbed do append(&kept, t)
	}
	chars := join_discrete(.Char, by[.Char][:])
	for t in kept {
		rest := make([dynamic]Type)
		for c in chars do append(&rest, ..chars_in_text(c, t, false))
		chars = rest[:]
	}
	append(&out, ..chars)
	append(&out, ..kept[:])
	if slice.contains(by[.Bool][:], Type(Bool(false))) do append(&out, Bool(false))
	if slice.contains(by[.Bool][:], Type(Bool(true))) do append(&out, Bool(true))
	append(&out, ..unique_cells(k, by[.Value][:]))
	append(&out, ..unique_cells(k, by[.Other][:]))
	return out[:]
}

unique_cells :: proc(k: ^Kernel, cells: []Type) -> []Type {
	out := make([dynamic]Type)
	for c in cells do if !contains_same(k, out[:], c) do append(&out, c)
	return out[:]
}

// --- & of cells ---

meet_cells :: proc(k: ^Kernel, a, b: []Type) -> []Type {
	out := make([dynamic]Type)
	for x in a do for y in b do append(&out, ..meet_cell(k, x, y))
	return union_cells(k, out[:])
}

meet_cell :: proc(k: ^Kernel, x, y: Type) -> []Type {
	fx, fy := cell_family(x), cell_family(y)
	if fx == .Text && fy == .Char do return meet_cell(k, y, x)
	if fy == .Other && fx != .Other do return meet_cell(k, y, x)
	switch {
	case fx == fy && (fx == .Int || fx == .Char):
		lo_x, hi_x := discrete_bounds(x)
		lo_y, hi_y := discrete_bounds(y)
		return cell_list(discrete_cell(fx, max_bound(lo_x, lo_y), min_bound(hi_x, hi_y)))
	case fx == fy && fx == .Real:
		return cell_list(real_cell(real_meet(real_bounds(x), real_bounds(y))))
	case fx == fy && fx == .Bool:
		return same(k, x, y) ? cell_list(x) : nil
	case fx == fy && fx == .Text:
		return text_meet(x, y)
	case fx == .Char && fy == .Text:
		return chars_in_text(x, y, true)
	case fx == fy && fx == .Value:
		if same(k, x, y) do return cell_list(x)
		if different_structures(k, x, y) do return nil
		return cell_list(new_and(x, y))
	case fx == .Other:
		if same(k, x, y) do return cell_list(x)
		if fy == .Text || fy == .Char || fy == .Bool || fy == .Value do return nil // a number is none of them
		if fy == .Int {
			// the least and greatest elements of x: nothing between them in y, nothing in common
			if lo, hi, bounded := int_bounds(k, x); bounded {
				lo_y, hi_y := discrete_bounds(y)
				if is_none(discrete_cell(.Int, max_bound(lo, lo_y), min_bound(hi, hi_y))) do return nil
			}
		}
		return cell_list(new_and(x, y))
	}
	return nil
}

cell_list :: proc(c: Type) -> []Type {
	if is_none(c) do return nil
	return slice.clone([]Type{c})
}

// --- & ~ of cells ---

// minus_cells: a & ~u, u a | of cells.
minus_cells :: proc(k: ^Kernel, a, u: []Type) -> []Type {
	out := make([dynamic]Type)
	for x in a do append(&out, ..minus_cell(k, x, u))
	return union_cells(k, out[:])
}

minus_cell :: proc(k: ^Kernel, x: Type, u: []Type) -> []Type {
	f := cell_family(x)
	for y in u do if same(k, x, y) do return nil
	switch f {
	case .Int, .Char:
		pieces := cell_list(x)
		for y in u {
			if cell_family(y) != f do continue
			next := make([dynamic]Type)
			for p in pieces do append(&next, ..discrete_minus(f, p, y))
			pieces = next[:]
		}
		if f == .Char {
			for y in u {
				if cell_family(y) != .Text do continue
				next := make([dynamic]Type)
				for p in pieces do append(&next, ..chars_in_text(p, y, false))
				pieces = next[:]
			}
		}
		return pieces
	case .Real:
		pieces := cell_list(x)
		for y in u {
			if cell_family(y) != .Real do continue
			next := make([dynamic]Type)
			for p in pieces do for q in real_minus(real_bounds(p), real_bounds(y)) do append(&next, ..cell_list(real_cell(q)))
			pieces = next[:]
		}
		return pieces
	case .Bool:
		return cell_list(x)
	case .Text:
		ys := make([dynamic]Type)
		for y in u do if g := cell_family(y); g == .Text || g == .Char do append(&ys, y)
		if len(ys) == 0 do return cell_list(x)
		removed := text_or(ys[:])
		if text_empty(text_and({x, removed})) do return cell_list(x)
		rest := text_and({x, text_not(removed)})
		if text_empty(rest) do return nil
		return cell_list(rest)
	case .Value:
		ys := make([dynamic]Type)
		for y in u do if cell_family(y) == .Value && !different_structures(k, x, y) do append(&ys, y)
		if len(ys) == 0 do return cell_list(x)
		return cell_list(new_and(x, new_not(cells_term(ys[:]))))
	case .Other:
		ys := make([dynamic]Type)
		for y in u do if g := cell_family(y); g == .Int || g == .Real || g == .Other do append(&ys, y)
		if len(ys) == 0 do return cell_list(x)
		if lo, hi, bounded := int_bounds(k, x); bounded {
			hull := discrete_cell(.Int, lo, hi)
			ints := make([dynamic]Type)
			for y in ys do if cell_family(y) == .Int do append(&ints, y)
			// nothing between its least and greatest elements outside u: none left
			if len(discrete_minus_all(hull, ints[:])) == 0 do return nil
			if len(meet_cells(k, cell_list(hull), ints[:])) == 0 do return cell_list(x)
		}
		return cell_list(new_and(x, new_not(cells_term(ys[:]))))
	}
	return cell_list(x)
}

// --- integers and characters ---

// discrete_bounds: the bounds of an integer or character cell; nil is infinite.
discrete_bounds :: proc(t: Type) -> (lo, hi: Maybe(i128)) {
	#partial switch v in t {
	case Int:
		return i128(v), i128(v)
	case Char:
		return i128(v), i128(v)
	case ^Range:
		if x, ok := v.lo.(Int); ok do lo = i128(x)
		if x, ok := v.lo.(Char); ok do lo = i128(x)
		if x, ok := v.hi.(Int); ok do hi = i128(x)
		if x, ok := v.hi.(Char); ok do hi = i128(x)
		if _, is_char := v.lo.(Char); is_char && hi == nil do hi = MAX_RUNE
	}
	return
}

// discrete_cell: the integers, or characters, from lo to hi: one primitive, a
// range, or none.
discrete_cell :: proc(f: Cell_Family, lo, hi: Maybe(i128)) -> Type {
	lo, hi := lo, hi
	if f == .Char {
		lo, hi = max_bound(lo, 0), min_bound(hi, MAX_RUNE)
	}
	l, has_l := lo.?
	h, has_h := hi.?
	if has_l && has_h {
		if l > h do return None{}
		if l == h do return f == .Char ? Type(Char(rune(l))) : Type(Int(l))
	}
	if f == .Char do return new_range(Char(rune(l)), h == MAX_RUNE ? nil : Type(Char(rune(h))))
	return new_range(has_l ? Type(Int(l)) : nil, has_h ? Type(Int(h)) : nil, .Int)
}

// join_discrete: a..b | c..d = min(a, c)..max(b, d) when they meet or touch.
join_discrete :: proc(f: Cell_Family, cells: []Type) -> []Type {
	sorted := slice.clone(cells)
	slice.sort_by(sorted, cell_less)
	out := make([dynamic]Type)
	lo, hi: Maybe(i128)
	open := false
	for c in sorted {
		x, y := discrete_bounds(c)
		if open {
			h, bounded := hi.?
			if !bounded do continue
			if s, has := x.?; !has || s <= h || h < max(i128) && s == h + 1 {
				if e, has_e := y.?; !has_e || e > h do hi = y
				continue
			}
			append(&out, discrete_cell(f, lo, hi))
		}
		lo, hi, open = x, y, true
	}
	if open do append(&out, discrete_cell(f, lo, hi))
	return out[:]
}

// discrete_minus: a..b & ~(c..d) = a..(c - 1) | (d + 1)..b. A piece beyond the
// integers written here is not computed: a & ~b stays.
discrete_minus :: proc(f: Cell_Family, x, y: Type) -> []Type {
	lo_x, hi_x := discrete_bounds(x)
	lo_y, hi_y := discrete_bounds(y)
	if is_none(discrete_cell(f, max_bound(lo_x, lo_y), min_bound(hi_x, hi_y))) do return cell_list(x)
	out := make([dynamic]Type)
	if l, has := lo_y.?; has {
		if l == min(i128) do return cell_list(new_and(x, new_not(y)))
		append(&out, ..cell_list(discrete_cell(f, lo_x, min_bound(hi_x, l - 1))))
	}
	if h, has := hi_y.?; has {
		if h == max(i128) do return cell_list(new_and(x, new_not(y)))
		append(&out, ..cell_list(discrete_cell(f, max_bound(lo_x, h + 1), hi_x)))
	}
	return out[:]
}

discrete_minus_all :: proc(x: Type, ys: []Type) -> []Type {
	pieces := cell_list(x)
	for y in ys {
		next := make([dynamic]Type)
		for p in pieces do append(&next, ..discrete_minus(.Int, p, y))
		pieces = next[:]
	}
	return pieces
}

// --- reals ---

// Real_Bounds: the bounds of a real cell, read on its term: nil is infinite; an
// open bound is the `& ~p` of `>p` (§4.3).
Real_Bounds :: struct {
	lo, hi:           Maybe(Real),
	lo_open, hi_open: bool,
}

real_bounds :: proc(t: Type) -> Real_Bounds {
	b: Real_Bounds
	#partial switch v in t {
	case Real:
		b.lo, b.hi = v, v
	case ^Range:
		if x, ok := v.lo.(Real); ok do b.lo = x
		if x, ok := v.hi.(Real); ok do b.hi = x
	case ^And:
		for x in v.terms do if _, ok := x.(^Range); ok do b = real_bounds(x)
		for x in v.terms {
			n, ok := x.(^Not)
			if !ok do continue
			p, is_real := n.term.(Real)
			if !is_real do continue
			if lo, has := b.lo.?; has && lo == p do b.lo_open = true
			if hi, has := b.hi.?; has && hi == p do b.hi_open = true
		}
	}
	return b
}

real_empty :: proc(b: Real_Bounds) -> bool {
	lo, has_lo := b.lo.?
	hi, has_hi := b.hi.?
	if !has_lo || !has_hi do return false
	c := real_compare(lo, hi)
	return c > 0 || c == 0 && (b.lo_open || b.hi_open)
}

real_cell :: proc(b: Real_Bounds) -> Type {
	if real_empty(b) do return None{}
	lo, has_lo := b.lo.?
	hi, has_hi := b.hi.?
	if has_lo && has_hi && lo == hi do return lo
	r := new_range(has_lo ? Type(lo) : nil, has_hi ? Type(hi) : nil, .Real)
	terms := make([dynamic]Type)
	append(&terms, r)
	if has_lo && b.lo_open do append(&terms, new_not(lo))
	if has_hi && b.hi_open do append(&terms, new_not(hi))
	return len(terms) == 1 ? r : new_and(..terms[:])
}

real_meet :: proc(x, y: Real_Bounds) -> Real_Bounds {
	r := x
	if y_lo, ok := y.lo.?; ok {
		x_lo, has := x.lo.?
		if !has || real_less(x_lo, y_lo) {
			r.lo, r.lo_open = y.lo, y.lo_open
		} else if y_lo == x_lo {
			r.lo_open = x.lo_open || y.lo_open
		}
	}
	if y_hi, ok := y.hi.?; ok {
		x_hi, has := x.hi.?
		if !has || real_less(y_hi, x_hi) {
			r.hi, r.hi_open = y.hi, y.hi_open
		} else if y_hi == x_hi {
			r.hi_open = x.hi_open || y.hi_open
		}
	}
	return r
}

// real_minus: x & ~y: what is below y, and what is above.
real_minus :: proc(x, y: Real_Bounds) -> []Real_Bounds {
	out := make([dynamic]Real_Bounds)
	if lo, ok := y.lo.?; ok do append(&out, real_meet(x, Real_Bounds{hi = lo, hi_open = !y.lo_open}))
	if hi, ok := y.hi.?; ok do append(&out, real_meet(x, Real_Bounds{lo = hi, lo_open = !y.hi_open}))
	kept := make([dynamic]Real_Bounds)
	for b in out do if !real_empty(b) do append(&kept, b)
	return kept[:]
}

// join_reals: two intervals that meet or touch are one.
join_reals :: proc(cells: []Type) -> []Type {
	bounds := make([dynamic]Real_Bounds)
	for c in cells do append(&bounds, real_bounds(c))
	slice.sort_by(bounds[:], proc(a, b: Real_Bounds) -> bool {
		x, has_x := a.lo.?
		y, has_y := b.lo.?
		if !has_x do return has_y
		if !has_y do return false
		return real_less(x, y) || x == y && !a.lo_open && b.lo_open
	})
	merged := make([dynamic]Real_Bounds)
	for r in bounds {
		if len(merged) == 0 {
			append(&merged, r)
			continue
		}
		last := &merged[len(merged) - 1]
		last_hi, bounded := last.hi.?
		if !bounded do break
		lo, has_lo := r.lo.?
		if has_lo && (real_less(last_hi, lo) || lo == last_hi && last.hi_open && r.lo_open) {
			append(&merged, r)
			continue
		}
		hi, has_hi := r.hi.?
		switch {
		case !has_hi:
			last.hi, last.hi_open = nil, false
		case real_less(last_hi, hi):
			last.hi, last.hi_open = r.hi, r.hi_open
		case hi == last_hi:
			last.hi_open = last.hi_open && r.hi_open
		}
	}
	out := make([dynamic]Type)
	for b in merged do append(&out, real_cell(b))
	return out[:]
}

// --- strings and characters ---

// text_meet: a & b of two sets of strings: none, one of them, or their &.
text_meet :: proc(x, y: Type) -> []Type {
	both := text_and({x, y})
	if text_empty(both) do return nil
	if text_empty(text_and({x, text_not(y)})) do return cell_list(x)
	if text_empty(text_and({y, text_not(x)})) do return cell_list(y)
	return cell_list(both)
}

// chars_in_text: the characters of the cell c that are strings of t — or that are
// not: c is in t when ∂c t holds "".
chars_in_text :: proc(c: Type, t: Type, inside: bool) -> []Type {
	lo, hi := discrete_bounds(c)
	l, _ := lo.?
	h, _ := hi.?
	points := cuts(t)
	out := make([dynamic]Type)
	for p, i in points {
		end := i + 1 < len(points) ? i128(points[i + 1]) - 1 : MAX_RUNE
		from, to := max(i128(p), l), min(end, h)
		if from > to do continue
		if nullable(quotient(t, rune(from))) == inside do append(&out, discrete_cell(.Char, from, to))
	}
	return join_discrete(.Char, out[:])
}

// --- integers left as an operation ---
//
// A set of integers built by an operator on sets — `u8 * u8` — is the | of the
// results on their elements (§4.5). It stays the operation; its least and greatest
// elements are known by the order of the integers: results at the bounds of its
// operands (a <= a' and b >= 0 give a * b <= a' * b). They are elements of the set.

// int_bounds: the least and greatest elements of a constant set of integers; nil
// on a side where it has none.
int_bounds :: proc(k: ^Kernel, t: Type) -> (lo, hi: Maybe(i128), ok: bool) {
	cells, negated := as_cells(t)
	if !negated && len(cells) > 0 {
		all_ints := true
		for c in cells do all_ints &&= cell_family(c) == .Int
		if all_ints {
			lo, _ = discrete_bounds(cells[0])
			_, hi = discrete_bounds(cells[len(cells) - 1])
			return lo, hi, true
		}
	}
	o, is_op := t.(^Operation)
	if !is_op || !is_constant(t) || is_text(t) do return
	bounds := make([][2]Maybe(i128), len(o.args))
	for a, i in o.args {
		x, y := int_bounds(k, a) or_return
		bounds[i] = {x, y}
	}
	#partial switch o.op {
	case .Add:
		lo, hi = bounds[0][0], bounds[0][1]
		for b in bounds[1:] {
			lo = add_bound(lo, b[0]) or_return
			hi = add_bound(hi, b[1]) or_return
		}
		return lo, hi, true
	case .Sub:
		a := neg_bound(bounds[1][1]) or_return
		b := neg_bound(bounds[1][0]) or_return
		lo = add_bound(bounds[0][0], a) or_return
		hi = add_bound(bounds[0][1], b) or_return
		return lo, hi, true
	case .Neg:
		lo = neg_bound(bounds[0][1]) or_return
		hi = neg_bound(bounds[0][0]) or_return
		return lo, hi, true
	case .Mul:
		lo, hi = bounds[0][0], bounds[0][1]
		for b in bounds[1:] do lo, hi = corners(lo, hi, b[0], b[1], mul_extended) or_return
		return lo, hi, true
	case .Div:
		// a divisor of one sign: a / b is monotone in each
		x, has_x := bounds[1][0].?
		y, has_y := bounds[1][1].?
		if !(has_x && x >= 1) && !(has_y && y <= -1) do return
		return corners(bounds[0][0], bounds[0][1], bounds[1][0], bounds[1][1], div_extended)
	}
	return
}

// Extended: an integer, or -∞ / +∞ (infinite, of the sign of value).
Extended :: struct {
	value:    i128,
	infinite: bool,
}

// corners: the least and greatest of x op y at the bounds, -∞ and +∞ included;
// false when one is beyond the integers written here.
corners :: proc(a_lo, a_hi, b_lo, b_hi: Maybe(i128), op: proc(x, y: Extended) -> (Extended, bool)) -> (lo, hi: Maybe(i128), ok: bool) {
	extend :: proc(v: Maybe(i128), sign: i128) -> Extended {
		if x, ok := v.?; ok do return {x, false}
		return {sign, true}
	}
	xs := [2]Extended{extend(a_lo, -1), extend(a_hi, 1)}
	ys := [2]Extended{extend(b_lo, -1), extend(b_hi, 1)}
	least, most: Extended
	first := true
	for x in xs {
		for y in ys {
			v := op(x, y) or_return
			if first || extended_less(v, least) do least = v
			if first || extended_less(most, v) do most = v
			first = false
		}
	}
	if !least.infinite do lo = least.value
	if !most.infinite do hi = most.value
	return lo, hi, true
}

extended_less :: proc(a, b: Extended) -> bool {
	rank :: proc(x: Extended) -> int {return x.infinite ? (x.value < 0 ? -1 : 1) : 0}
	if rank(a) != rank(b) do return rank(a) < rank(b)
	return rank(a) == 0 && a.value < b.value
}

sign_of :: proc(x: Extended) -> i128 {
	return x.value > 0 ? 1 : (x.value < 0 ? -1 : 0)
}

// mul_extended: 0 times anything is 0; infinite times a sign, infinite; false
// beyond the integers written here.
mul_extended :: proc(x, y: Extended) -> (Extended, bool) {
	s := sign_of(x) * sign_of(y)
	if s == 0 do return {0, false}, true
	if x.infinite || y.infinite do return {s, true}, true
	v, ok := mul_checked(x.value, y.value)
	return {v, false}, ok
}

// div_extended: truncated, as on primitives; a finite value over an infinite one
// is 0; the divisor is never 0.
div_extended :: proc(x, y: Extended) -> (Extended, bool) {
	s := sign_of(x) * sign_of(y)
	if y.infinite do return {0, false}, true
	if x.infinite do return {s, true}, true
	if x.value == min(i128) && y.value == -1 do return {}, false
	return {x.value / y.value, false}, true
}

// --- inclusion, read on normal forms ---

// included: a & ~b = none: every element of a is in b.
included :: proc(k: ^Kernel, a, b: Type) -> bool {
	return is_none(and_law(k, {a, not_law(k, b)}))
}

// apart: a & b = none: a and b have no element in common.
apart :: proc(k: ^Kernel, a, b: Type) -> bool {
	return is_none(and_law(k, {a, b}))
}

// inhabited: a constant normal form that shows an element: a ~, or a cell the laws
// computed — every one but a value or an operation whose & stays.
inhabited :: proc(k: ^Kernel, t: Type) -> bool {
	if !is_constant(t) || is_none(t) do return false
	cells, negated := as_cells(t)
	if negated do return true
	for c in cells {
		switch cell_family(c) {
		case .Int, .Real, .Char, .Text, .Bool:
			return true
		case .Value:
			if _, ok := c.(^Is); ok do return true
		case .Other:
			if _, ok := c.(^Operation); ok do return true
		}
	}
	return false
}

// decided: a constant normal form whose & and ~ with any other such one the laws
// compute whole: no value, no operation left.
decided :: proc(t: Type) -> bool {
	if !is_constant(t) do return false
	cells, _ := as_cells(t)
	for c in cells do if f := cell_family(c); f == .Value || f == .Other do return false
	return true
}

// --- terms ---

// is_constant: a term without unknown or name.
is_constant :: proc(t: Type) -> bool {
	switch v in t {
	case Char, Int, Real, Bool, None, ^Scope:
		return true
	case ^Or:
		for x in v.terms do if !is_constant(x) do return false
		return true
	case ^And:
		for x in v.terms do if !is_constant(x) do return false
		return true
	case ^Not:
		return is_constant(v.term)
	case ^Is:
		return is_constant(v.term)
	case ^Range:
		return (v.lo == nil || is_constant(v.lo)) && (v.hi == nil || is_constant(v.hi))
	case ^Operation:
		for x in v.args do if !is_constant(x) do return false
		return true
	case ^Unknown, ^Name, ^Access, ^Collapse, ^Carve, ^Default, ^Pattern, Invalid:
	}
	return false
}

sort_types :: proc(ts: []Type) {
	slice.sort_by(ts, term_less)
}

// --- bounds: integers or infinite (nil) ---

INT_MAX :: max(i128)

max_bound :: proc(a, b: Maybe(i128)) -> Maybe(i128) {
	x, has_x := a.?
	y, has_y := b.?
	if !has_x do return b
	if !has_y do return a
	return max(x, y)
}

min_bound :: proc(a, b: Maybe(i128)) -> Maybe(i128) {
	x, has_x := a.?
	y, has_y := b.?
	if !has_x do return b
	if !has_y do return a
	return min(x, y)
}

// neg_bound, add_bound: on bounds, nil being infinite; false beyond the integers
// written here: the law is then not computed, and the term stays.
neg_bound :: proc(a: Maybe(i128)) -> (Maybe(i128), bool) {
	v, ok := a.?
	if !ok do return nil, true
	if v == min(i128) do return nil, false
	return -v, true
}

add_bound :: proc(a, b: Maybe(i128)) -> (Maybe(i128), bool) {
	x, has_x := a.?
	y, has_y := b.?
	if !has_x || !has_y do return nil, true
	s, ok := add_checked(x, y)
	if !ok do return nil, false
	return s, true
}

add_checked :: proc(a, b: i128) -> (i128, bool) {
	if b > 0 && a > max(i128) - b do return 0, false
	if b < 0 && a < min(i128) - b do return 0, false
	return a + b, true
}

mul_checked :: proc(a, b: i128) -> (i128, bool) {
	if a == 0 || b == 0 do return 0, true
	if a == 1 do return b, true
	if b == 1 do return a, true
	if a == min(i128) || b == min(i128) do return 0, false
	if abs(a) > max(i128) / abs(b) do return 0, false
	return a * b, true
}
