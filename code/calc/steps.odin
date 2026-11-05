package code_calc

import code ".."

// STEPS THAT COMPOSE
//
// A turn that moves a parameter by x ↦ M·x + b, M and b read by no turn, moves it
// by a map of a monoid: affine maps compose, (M, b)∘(N, c) = (M·N, M·c + b), and
// L turns are one, (M, b)ᴸ, by squaring (specs/types.md §4.10). Two rings hold
// such steps: the words, M an integer, + and · wrapping at 2⁶⁴; and the bits of a
// word under ^ (GF(2)⁶⁴), M a matrix of bits — what ^, a shift by a count, & | by
// a mask and ~ do to the bits of a word. Applied to x, a matrix of bits is the
// sum of its diagonals: the bits of x shifted by d, each kept by the mask of the
// diagonal d.

// Bit_Matrix: a linear map of GF(2)⁶⁴, by the image of each bit.
Bit_Matrix :: [64]u64

// Affine: a step x ↦ M·x + b: over the words, M is a; over the bits, the matrix m,
// and + is ^.
Affine :: struct {
	bits: bool,
	a, b: u64,
	m:    Bit_Matrix,
}

identity_bits :: proc() -> (m: Bit_Matrix) {
	for &c, j in m do c = 1 << uint(j)
	return
}

// apply_bits: M·x.
apply_bits :: proc(m: Bit_Matrix, x: u64) -> u64 {
	y: u64
	for c, j in m do if x >> uint(j) & 1 == 1 do y ~= c
	return y
}

// compose: f∘g, g first.
compose :: proc(f, g: Affine) -> Affine {
	if !f.bits do return Affine{a = f.a * g.a, b = f.a * g.b + f.b}
	out := Affine{bits = true, b = apply_bits(f.m, g.b) ~ f.b}
	for c, j in g.m do out.m[j] = apply_bits(f.m, c)
	return out
}

// power: fⁿ, by squaring.
power_of :: proc(f: Affine, n: int) -> Affine {
	out := f.bits ? Affine{bits = true, m = identity_bits()} : Affine{a = 1}
	square := f
	for k := n; k > 0; k >>= 1 {
		if k & 1 == 1 do out = compose(square, out)
		square = compose(square, square)
	}
	return out
}

// affine_step: how c, what a turn of l gives its parameter j, moves it: x ↦ a·x + b
// over the words, or x ↦ M·x ^ b over the bits.
affine_step :: proc(g: ^Graph, c: Class, l, j: int) -> (Affine, bool) {
	busy := make(map[Class]bool)
	defer delete(busy)
	if s, ok := ring_step(g, c, l, j, &busy); ok do return s, true
	clear(&busy)
	return bits_step(g, c, l, j, &busy)
}

// word: the integer of a class as the bits of its word.
word :: proc(v: i128) -> u64 {
	return transmute(u64)code.word_of(v)
}

ring_step :: proc(g: ^Graph, c: Class, l, j: int, busy: ^map[Class]bool) -> (out: Affine, ok: bool) {
	c := find(g, c)
	f := g.facts[c]
	if f.machine != .Int || f.lanes > 0 do return
	if v, known := f.constant.?; known && code.in_word({v, v}) do return Affine{b = word(v)}, true
	if busy[c] do return
	busy[c] = true
	defer busy[c] = false
	for id in g.members[c] {
		n := g.nodes[id]
		#partial switch n.kind {
		case .Param:
			if n.owner == l && n.index == j do return Affine{a = 1}, true
		case .Narrow:
			if s, is := ring_step(g, n.args[0], l, j, busy); is do return s, true
		case .Unary:
			if n.op != .Neg do continue
			x := ring_step(g, n.args[0], l, j, busy) or_continue
			return Affine{a = -x.a, b = -x.b}, true
		case .Binary:
			#partial switch n.op {
			case .Add, .Sub, .Mul, .Shl:
			case .And:
				// the mask of every bit of the word keeps it
				k, constant := g.facts[find(g, n.args[1])].constant.?
				if !constant || word(k) != max(u64) do continue
				if x, is := ring_step(g, n.args[0], l, j, busy); is do return x, true
				continue
			case:
				continue
			}
			x := ring_step(g, n.args[0], l, j, busy) or_continue
			y := ring_step(g, n.args[1], l, j, busy) or_continue
			#partial switch n.op {
			case .Add:
				return Affine{a = x.a + y.a, b = x.b + y.b}, true
			case .Sub:
				return Affine{a = x.a - y.a, b = x.b - y.b}, true
			case .Mul:
				// a product by what no turn changes: one side constant
				if x.a == 0 do return Affine{a = x.b * y.a, b = x.b * y.b}, true
				if y.a == 0 do return Affine{a = x.a * y.b, b = x.b * y.b}, true
			case .Shl:
				if y.a == 0 && y.b < 64 do return Affine{a = x.a << y.b, b = x.b << y.b}, true
			}
		}
	}
	return
}

bits_step :: proc(g: ^Graph, c: Class, l, j: int, busy: ^map[Class]bool) -> (out: Affine, ok: bool) {
	c := find(g, c)
	f := g.facts[c]
	if f.machine != .Int || f.lanes > 0 do return
	if v, known := f.constant.?; known && code.in_word({v, v}) do return Affine{bits = true, b = word(v)}, true
	if busy[c] do return
	busy[c] = true
	defer busy[c] = false
	for id in g.members[c] {
		n := g.nodes[id]
		#partial switch n.kind {
		case .Param:
			if n.owner == l && n.index == j do return Affine{bits = true, m = identity_bits()}, true
		case .Narrow:
			if s, is := bits_step(g, n.args[0], l, j, busy); is do return s, true
		case .Unary:
			if n.op != .Not do continue
			x := bits_step(g, n.args[0], l, j, busy) or_continue
			x.b = ~x.b
			return x, true
		case .Binary:
			#partial switch n.op {
			case .Xor:
				x := bits_step(g, n.args[0], l, j, busy) or_continue
				y := bits_step(g, n.args[1], l, j, busy) or_continue
				out = Affine{bits = true, b = x.b ~ y.b}
				for k in 0 ..< 64 do out.m[k] = x.m[k] ~ y.m[k]
				return out, true
			case .And, .Or:
				// by a mask: x & k keeps the bits of k; x | k = (x & ~k) ^ k
				k, constant := g.facts[find(g, n.args[1])].constant.?
				if !constant do continue
				x := bits_step(g, n.args[0], l, j, busy) or_continue
				mask := word(k)
				keep := n.op == .And ? mask : ~mask
				out = Affine{bits = true, b = x.b & keep}
				for col, i in x.m do out.m[i] = col & keep
				if n.op == .Or do out.b ~= mask
				return out, true
			case .Shl, .Shr:
				k, constant := g.facts[find(g, n.args[1])].constant.?
				if !constant || k < 0 || k > 63 do continue
				x := bits_step(g, n.args[0], l, j, busy) or_continue
				s := uint(k)
				// a word read as signed shifts its sign in from the left
				arithmetic := n.op == .Shr && g.facts[find(g, n.args[0])].bounds.lo < 0 && !code.unsigned(code.Kind{machine = .Int, bounds = f.bounds})
				shift :: proc(v: u64, s: uint, op: code.Op, arithmetic: bool) -> u64 {
					if op == .Shl do return v << s
					if arithmetic do return transmute(u64)(transmute(i64)v >> s)
					return v >> s
				}
				out = Affine{bits = true, b = shift(x.b, s, n.op, arithmetic)}
				for col, i in x.m do out.m[i] = shift(col, s, n.op, arithmetic)
				return out, true
			}
		}
	}
	return
}

// orbit: the lanes of the orbit of x: lane k is sᵏ(x).
orbit :: proc(g: ^Graph, s: Affine, x: Class, lanes, bits: int) -> Class {
	powers := make([]Affine, lanes)
	defer delete(powers)
	for &p, k in powers do p = power_of(s, k)
	return applied(g, powers, splat(g, x, lanes, bits), lanes, bits)
}

// advanced: x, a word or each lane of a vector, n turns on: by sⁿ.
advanced :: proc(g: ^Graph, s: Affine, x: Class, lanes, bits, n: int) -> Class {
	powers := make([]Affine, max(lanes, 1))
	defer delete(powers)
	p := power_of(s, n)
	for &q in powers do q = p
	return applied(g, powers, x, lanes, bits)
}

// applied: each lane k of xs by the map powers[k], as computations — xs a word
// when there are no lanes.
applied :: proc(g: ^Graph, powers: []Affine, xs: Class, lanes, bits: int) -> Class {
	count := len(powers)
	s := powers[0]
	// what each lane holds, as a vector or a word
	// over the words, the integers of the words, signed; over the bits, unsigned
	constant :: proc(g: ^Graph, values: []u64, lanes, bits: int, signed: bool) -> Class {
		if lanes == 0 do return add(g, int_node(signed ? i128(transmute(i64)values[0]) : i128(values[0])))
		vs := make([]i64, len(values))
		for v, k in values do vs[k] = transmute(i64)v
		return add(g, Node{kind = .Lanes, index = vector(g, vs), value = i128(bits)})
	}
	scalars := make([]u64, count)
	defer delete(scalars)
	if !s.bits {
		// a·x + b, a and b in each lane
		out := xs
		all_one := true
		for p, k in powers {
			scalars[k] = p.a
			all_one &&= p.a == 1
		}
		if !all_one do out = add(g, binary(g, .Mul, out, constant(g, scalars, lanes, bits, !s.bits)))
		for p, k in powers do scalars[k] = p.b
		return add(g, binary(g, .Add, out, constant(g, scalars, lanes, bits, !s.bits)))
	}
	// the sum of the diagonals: bit i of y from bit i - d of x
	masks: [127]Maybe([]u64)
	for p, k in powers do for col, j in p.m do for i in 0 ..< 64 do if col >> uint(i) & 1 == 1 {
		d := i - j + 63
		if masks[d] == nil {
			m := make([]u64, count)
			masks[d] = m
		}
		masks[d].?[k] |= 1 << uint(i)
	}
	out := NO_CLASS
	for m, d in masks {
		lane_masks := m.? or_continue
		offset := d - 63
		term := xs
		switch {
		case offset > 0:
			term = add(g, binary(g, .Shl, xs, add(g, int_node(i128(offset)))))
		case offset < 0:
			term = add(g, binary(g, .Shr, xs, add(g, int_node(i128(-offset)))))
		}
		// what the shift keeps of the word already: no mask
		full := true
		for v in lane_masks do full &&= offset >= 0 && v == max(u64) << uint(offset)
		if !full do term = add(g, binary(g, .And, term, constant(g, lane_masks, lanes, bits, false)))
		out = out == NO_CLASS ? term : add(g, binary(g, .Xor, out, term))
	}
	for p, k in powers do scalars[k] = p.b
	nonzero := false
	for v in scalars do nonzero ||= v != 0
	if out == NO_CLASS do return constant(g, scalars, lanes, bits, !s.bits)
	if nonzero do out = add(g, binary(g, .Xor, out, constant(g, scalars, lanes, bits, !s.bits)))
	return out
}
