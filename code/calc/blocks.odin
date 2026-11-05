package code_calc

import code ".."

// THE FOLD OF ITS BLOCKS
//
// A fold of N steps that compose is also the fold of its blocks (specs/types.md
// §4.10): its orbit cut into L runs of B = ⌊N/L⌋ steps, run k from x_{k·B} — the
// closed form of the orbit, Mⁿ by squares, or r(M) for r = tⁿ mod μ, the minimal
// polynomial of M (Cayley–Hamilton) —, each in a lane by M itself; what it gathers
// along the orbit recombined by the law of its monoid; the N - L·B steps left run
// by the fold itself, from x_{L·B}, where the last lane stopped.
//
// Mⁿ is code the program runs: over the words, (a, b)ⁿ by squaring the pair; over
// the bits, tⁿ mod μ by squaring a polynomial of GF(2)[t] in a word — a product
// t·p mod μ at each bit —, then r(M)·x by Horner, M applied once for each
// coefficient.

// blocked: the fold f in L lanes of runs of B steps, then the steps they leave.
blocked :: proc(g: ^Graph, f: ^Fold, lanes: int) -> bool {
	parent := f.info.parent
	// the steps a lane runs, B, and the jumps to the start of each run
	n := steps_of(g, f) or_return
	b_steps := add(g, binary(g, .Div, n, add(g, int_node(i128(lanes)))))
	bound(g, b_steps, {0, i128(max(i64))})
	jumps := make([]Jump, len(f.steps))
	for x, k in f.steps do jumps[k] = jump_of(g, x.step, b_steps, parent) or_return
	// the runs: a counter, the steps in lanes, the reductions
	kinds := make([dynamic]code.Kind)
	append(&kinds, code.Kind{.Int, {0, i128(max(i64))}, 0, 0})
	for _ in f.steps do append(&kinds, code.Kind{.Int, code.EVERY, lanes, 0})
	for r in f.reductions do append(&kinds, code.Kind{f.info.params[r.param].machine, code.EVERY, lanes, 0})
	zero := make([]code.Bounds, 1)
	// each lane runs B of the turns of the loop: its turns, over L
	b := new_loop(g, parent, kinds[:], code.Cover{ints = zero}, .Lanes, turns_of(g, g.costs, f.l) / f64(lanes))
	vectors := make(map[int]Class)
	for x, k in f.steps do vectors[x.param] = b.params[k + 1]
	nexts := make([dynamic]Class)
	append(&nexts, add(g, binary(g, .Sub, b.params[0], add(g, int_node(1)))))
	for x, k in f.steps do append(&nexts, advanced(g, x.step, b.params[k + 1], lanes, 0, 1))
	reduced_in_lanes(g, f, b, vectors, lanes, 0, &nexts) or_return
	// run k of each step from its point k·B: the jump of B, k times
	inits := make([dynamic]Class)
	append(&inits, b_steps)
	for x, k in f.steps {
		point := f.loop.args[x.param]
		runs := NO_CLASS
		for lane in 0 ..< lanes {
			if lane > 0 do point = jump_apply(g, jumps[k], point, parent)
			e := make([]i64, lanes)
			e[lane] = -1
			in_lane := add(g, binary(g, .And, splat(g, point, lanes), add(g, Node{kind = .Lanes, index = vector(g, e)})))
			runs = runs == NO_CLASS ? in_lane : add(g, binary(g, .Or, runs, in_lane))
		}
		append(&inits, runs)
	}
	for r in f.reductions do append(&inits, splat(g, neutral_of(g, r.op, f.info.params[r.param].machine), lanes))
	runs := close_loop(g, b, b.params[0], inits[:], nexts[:])
	// the steps left: from the end of the last run
	starts := make(map[int]Class)
	for x, k in f.steps do starts[x.param] = lane_of(g, given(g, runs, k + 1), lanes - 1, lanes, 0)
	return rest(g, f, runs, starts, 1 + len(f.steps), lanes)
}

// bound: what holds of the class c, by how it is built.
bound :: proc(g: ^Graph, c: Class, b: code.Bounds) {
	g.facts[find(g, c)].bounds = code.meet(g.facts[find(g, c)].bounds, b)
}

// steps_of: how many turns the fold runs, N: from its counter i₀ by d to where
// it stops, ⌈D / |d|⌉ for D > 0 — D the distance to the bound, one more when the
// bound itself goes on —, else none.
steps_of :: proc(g: ^Graph, f: ^Fold) -> (Class, bool) {
	start := f.loop.args[f.counter]
	d := i128(abs(f.delta))
	distance: Class
	#partial switch f.stop.op {
	case .Ge:
		distance = add(g, binary(g, .Sub, f.stop.bound, start))
	case .Gt:
		distance = add(g, binary(g, .Add, add(g, binary(g, .Sub, f.stop.bound, start)), add(g, int_node(1))))
	case .Le:
		distance = add(g, binary(g, .Sub, start, f.stop.bound))
	case .Lt:
		distance = add(g, binary(g, .Add, add(g, binary(g, .Sub, start, f.stop.bound)), add(g, int_node(1))))
	case:
		return NO_CLASS, false
	}
	positive := add(g, binary(g, .Gt, distance, add(g, int_node(0))))
	count := distance
	if d > 1 do count = add(g, binary(g, .Div, add(g, binary(g, .Add, distance, add(g, int_node(d - 1)))), add(g, int_node(d))))
	n := add(g, Node{kind = .Select, args = three(positive, count, add(g, int_node(0)))})
	bound(g, n, {0, i128(max(i64))})
	return n, true
}

// Jump: a step n turns on, as the program computes it: over the words, the pair
// (a, b)ⁿ; over the bits, r = tⁿ mod μ.
Jump :: struct {
	step:    Affine,
	a, b:    Class,
	r:       Class,
	minimal: Minimal,
}

// jump_of: the step s, n turns on.
jump_of :: proc(g: ^Graph, s: Affine, n: Class, parent: Region) -> (j: Jump, ok: bool) {
	j.step = s
	word :: code.Kind{.Int, code.EVERY, 0, 0}
	count :: code.Kind{.Int, {0, 64}, 0, 0}
	zero := make([]code.Bounds, 1)
	cover := code.Cover{ints = zero}
	if !s.bits {
		// (r, s) ↦ (s∘r where the bit of n is 1, s∘s), n by its bits
		b := new_loop(g, parent, {count, word, word, word, word, word}, cover, .Laned, 64)
		c, ra, rb, sa, sb, e := b.params[0], b.params[1], b.params[2], b.params[3], b.params[4], b.params[5]
		bit := add(g, binary(g, .And, e, add(g, int_node(1))))
		times :: proc(g: ^Graph, x, y: Class) -> Class {return add(g, binary(g, .Mul, x, y))}
		plus_ :: proc(g: ^Graph, x, y: Class) -> Class {return add(g, binary(g, .Add, x, y))}
		nexts := []Class {
			add(g, binary(g, .Sub, c, add(g, int_node(1)))),
			add(g, Node{kind = .Select, args = three(bit, times(g, sa, ra), ra)}),
			add(g, Node{kind = .Select, args = three(bit, plus_(g, times(g, sa, rb), sb), rb)}),
			times(g, sa, sa),
			plus_(g, times(g, sa, sb), sb),
			add(g, binary(g, .Shr, e, add(g, int_node(1)))),
		}
		inits := []Class{add(g, int_node(64)), add(g, int_node(1)), add(g, int_node(0)), add(g, int_node(i128(transmute(i64)s.a))), add(g, int_node(i128(transmute(i64)s.b))), n}
		loop := close_loop(g, b, c, inits, nexts)
		j.a, j.b = given(g, loop, 1), given(g, loop, 2)
		return j, true
	}
	// an affine map of the bits is linear here only
	if s.b != 0 do return
	j.minimal = minimal_of(s.m)
	// tⁿ mod μ: the powers t^(2ᵏ) squared, multiplied in where the bit of n is 1
	b := new_loop(g, parent, {count, word, word, word}, cover, .Laned, 64)
	c, acc, square, e := b.params[0], b.params[1], b.params[2], b.params[3]
	bit := add(g, binary(g, .And, e, add(g, int_node(1))))
	nexts := []Class {
		add(g, binary(g, .Sub, c, add(g, int_node(1)))),
		add(g, Node{kind = .Select, args = three(bit, product_mod(g, j.minimal, acc, square, Region{.Body, b.v, 0}), acc)}),
		product_mod(g, j.minimal, square, square, Region{.Body, b.v, 0}),
		add(g, binary(g, .Shr, e, add(g, int_node(1)))),
	}
	inits := []Class{add(g, int_node(64)), add(g, int_node(1)), add(g, int_node(i128(times_t(j.minimal, 1)))), n}
	j.r = given(g, close_loop(g, b, c, inits, nexts), 1)
	return j, true
}

// jump_apply: x, a jump on.
jump_apply :: proc(g: ^Graph, j: Jump, x: Class, parent: Region) -> Class {
	if !j.step.bits do return add(g, binary(g, .Add, add(g, binary(g, .Mul, j.a, x)), j.b))
	// r(M)·x by Horner: y ↦ M·y ^ x where the coefficient, from the highest, is 1
	word :: code.Kind{.Int, code.EVERY, 0, 0}
	zero := make([]code.Bounds, 1)
	b := new_loop(g, parent, {{.Int, {0, 64}, 0, 0}, word, word}, code.Cover{ints = zero}, .Laned, 64)
	c, y, r := b.params[0], b.params[1], b.params[2]
	m := j.step
	m.b = 0
	powers := []Affine{m}
	nexts := []Class {
		add(g, binary(g, .Sub, c, add(g, int_node(1)))),
		add(g, binary(g, .Xor, applied(g, powers, y, 0, 0), masked(g, top_bit(g, r), x))),
		add(g, binary(g, .Shl, r, add(g, int_node(1)))),
	}
	return given(g, close_loop(g, b, c, []Class{add(g, int_node(64)), add(g, int_node(0)), j.r}, nexts), 1)
}

// top_bit: the highest bit of x, 1 or 0.
top_bit :: proc(g: ^Graph, x: Class) -> Class {
	return add(g, binary(g, .And, add(g, binary(g, .Shr, x, add(g, int_node(63)))), add(g, int_node(1))))
}

// masked: x where the bit is 1, 0 where it is 0: -bit & x.
masked :: proc(g: ^Graph, bit, x: Class) -> Class {
	return add(g, binary(g, .And, add(g, Node{kind = .Unary, op = .Neg, args = one(bit)}), x))
}

// Minimal: the minimal polynomial of a matrix of bits: its degree, and its
// coefficients below it, in a word.
Minimal :: struct {
	degree: int,
	low:    u64,
}

// minimal_of: the first power of M that the powers before it sum to, I, M, M², …:
// μ(M) = 0.
minimal_of :: proc(m: Bit_Matrix) -> Minimal {
	Row :: struct {
		v:     Bit_Matrix,
		word:  int,
		bit:   uint,
		combo: u128,
	}
	basis := make([dynamic]Row)
	defer delete(basis)
	power := identity_bits()
	for k in 0 ..= 64 {
		v := power
		combo := u128(1) << uint(k)
		for b in basis do if v[b.word] >> b.bit & 1 == 1 {
			for &w, i in v do w ~= b.v[i]
			combo ~= b.combo
		}
		pivot := -1
		for w, i in v do if w != 0 {
			pivot = i
			break
		}
		if pivot < 0 do return Minimal{k, u64(combo & (u128(1) << uint(k) - 1))}
		bit: uint
		for v[pivot] >> bit & 1 == 0 do bit += 1
		append(&basis, Row{v, pivot, bit, combo})
		for &c in power do c = apply_bits(m, c)
	}
	return Minimal{64, 0}
}

// times_t: t·p mod μ, at compile time.
times_t :: proc(mu: Minimal, p: u64) -> u64 {
	top := p >> uint(mu.degree - 1) & 1
	keep := mu.degree == 64 ? max(u64) : u64(1) << uint(mu.degree) - 1
	return (p << 1) & keep ~ (top == 1 ? mu.low : 0)
}

// product_mod: p·q mod μ as the program computes it, in the region parent: by the
// bits of q from the highest, acc ↦ t·acc mod μ, ^ p where the bit is 1.
product_mod :: proc(g: ^Graph, mu: Minimal, p, q: Class, parent: Region) -> Class {
	word :: code.Kind{.Int, code.EVERY, 0, 0}
	zero := make([]code.Bounds, 1)
	b := new_loop(g, parent, {{.Int, {0, 64}, 0, 0}, word, word}, code.Cover{ints = zero}, .Laned, 64)
	c, acc, rest := b.params[0], b.params[1], b.params[2]
	// t·acc mod μ: shifted, μ taken away where the degree is reached
	keep := mu.degree == 64 ? max(u64) : u64(1) << uint(mu.degree) - 1
	shifted := add(g, binary(g, .And, add(g, binary(g, .Shl, acc, add(g, int_node(1)))), add(g, int_node(i128(keep)))))
	reached := add(g, binary(g, .And, add(g, binary(g, .Shr, acc, add(g, int_node(i128(mu.degree - 1))))), add(g, int_node(1))))
	times := add(g, binary(g, .Xor, shifted, masked(g, reached, add(g, int_node(i128(mu.low))))))
	nexts := []Class {
		add(g, binary(g, .Sub, c, add(g, int_node(1)))),
		add(g, binary(g, .Xor, times, masked(g, top_bit(g, rest), p))),
		add(g, binary(g, .Shl, rest, add(g, int_node(1)))),
	}
	return given(g, close_loop(g, b, c, []Class{add(g, int_node(64)), add(g, int_node(0)), q}, nexts), 1)
}
