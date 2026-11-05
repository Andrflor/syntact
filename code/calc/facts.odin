package code_calc

import code ".."

// THE FACTS OF A COMPUTATION
//
// What a node gives its class: its machine, the bounds of an integer — from the
// bounds of its arguments, where the machine computes in 64 bits without wrapping —
// and its constant, by the operation the machine does (code/interp.odin). What the
// code says of a value it reads (observe) meets them.

derive :: proc(g: ^Graph, n: Node) -> Facts {
	out := Facts{bounds = code.EVERY}
	switch n.kind {
	case .Int:
		return Facts{.Int, {i128(n.value), i128(n.value)}, n.value, 0, 0}
	case .Real:
		out.machine = .Real
	case .Text:
		out.machine = .Text
	case .Input:
		out.machine = .Int
	case .Argument:
		out.machine = g.func.params[n.index]
	case .Param:
		kind := g.loops[n.owner].params[n.index]
		out.machine, out.lanes, out.bits = kind.machine, kind.lanes, kind.bits
	case .In:
		out.machine, out.bounds = .Int, {0, 1}
	case .Narrow:
		x := g.facts[find(g, n.args[0])]
		out.machine, out.bounds, out.lanes, out.bits = x.machine, x.bounds, x.lanes, x.bits
	case .Splat:
		a := g.facts[find(g, n.args[0])]
		out.machine, out.bounds, out.lanes, out.bits, out.constant = a.machine, a.bounds, int(n.value), n.index, a.constant
	case .Lanes:
		values := g.vectors[n.index]
		out.machine, out.lanes, out.bits = .Int, len(values), int(n.value)
		out.bounds = {i128(values[0]), i128(values[0])}
		for v in values do out.bounds = code.hull(out.bounds, {i128(v), i128(v)})
	case .Reduce:
		a := g.facts[find(g, n.args[0])]
		out.machine = a.machine
		if a.machine != .Int do break
		// the lanes, one after another
		b := a.bounds
		for _ in 1 ..< a.lanes do b = binary_bounds(n.op, b, a.bounds)
		out.bounds = b
	case .Select:
		yes, no := g.facts[find(g, n.args[1])], g.facts[find(g, n.args[2])]
		out.machine, out.lanes = yes.machine, max(yes.lanes, no.lanes, g.facts[find(g, n.args[0])].lanes)
		out.bits = max(yes.bits, no.bits)
		if yes.machine == .Int do out.bounds = code.hull(yes.bounds, no.bounds)
		if x, known := yes.constant.?; known && yes.constant == no.constant do out.constant = x
	case .Unary:
		a := g.facts[find(g, n.args[0])]
		out.machine, out.lanes, out.bits = a.machine, a.lanes, a.bits
		if a.machine != .Int do break
		out.bounds = unary_bounds(n.op, a.bounds)
		if x, known := a.constant.?; known {
			if a.lanes > 0 {
				out.constant = i128(code.unary(n.op, .Int, code.Datum{int = i64(x)}).int)
			} else if v, ok := exact(n.op, x, 0); ok {
				out.constant = v
			}
		}
	case .Binary:
		a, b := g.facts[find(g, n.args[0])], g.facts[find(g, n.args[1])]
		out.machine = comparison(n.op) ? .Int : a.machine
		out.lanes, out.bits = max(a.lanes, b.lanes), max(a.bits, b.bits)
		if comparison(n.op) do out.bounds = {0, 1}
		if a.machine != .Int do break
		out.bounds = code.meet(out.bounds, binary_bounds(n.op, a.bounds, b.bounds))
		x, known_a := a.constant.?
		y, known_b := b.constant.?
		if known_a && known_b {
			// in lanes, what each lane of its bits holds; a value, exactly
			if out.lanes > 0 {
				if d, ok := code.binary_of(n.op, .Int, code.Datum{int = i64(x)}, code.Datum{int = i64(y)}); ok do out.constant = i128(d.int)
			} else if v, ok := exact(n.op, x, y); ok {
				out.constant = v
			}
		}
	case .Get:
		// a parameter a loop gives at its end: its kind; what else a tuple gives, the
		// code says
		for info in g.loops {
			if info.node >= len(g.nodes) || g.nodes[info.node].kind != .Loop || find(g, g.home[info.node]) != find(g, n.args[0]) do continue
			if k := n.index - outputs(info); k >= 0 && k < len(info.finals) {
				kind := info.params[info.finals[k]]
				out.machine, out.lanes, out.bits = kind.machine, kind.lanes, kind.bits
			}
		}
	case .Start, .Arm, .Foreign, .Memory, .Call, .Match, .Loop, .Again, .Exit:
	// a state, a tuple or a tail
	}
	if c, known := out.constant.?; known do out.bounds = {i128(c), i128(c)}
	// a lane of w bits holds the residue of what w bits do not hold
	if out.lanes > 0 && out.bits > 0 && !fits(out.bounds, out.bits) {
		half := i128(1) << uint(out.bits - 1)
		out.bounds, out.constant = {-half, half - 1}, nil
	}
	return out
}

comparison :: proc(op: code.Op) -> bool {
	#partial switch op {
	case .Eq, .Ne, .Lt, .Le, .Gt, .Ge:
		return true
	}
	return false
}

// in_64: bounds a word holds without wrapping, read signed or unsigned (code.in_word).
in_64 :: proc(b: code.Bounds) -> bool {
	return code.in_word(b)
}

// fit: the bounds, when the machine computes them without wrapping.
fit :: proc(b: code.Bounds) -> code.Bounds {
	return in_64(b) ? b : code.EVERY
}

// unary_bounds: the bounds of op a, from a's.
unary_bounds :: proc(op: code.Op, a: code.Bounds) -> code.Bounds {
	#partial switch op {
	case .Neg:
		return fit({-a.hi, -a.lo})
	case .Not:
		return fit({-a.hi - 1, -a.lo - 1})
	}
	return code.EVERY
}

// binary_bounds: the bounds of a op b, from theirs.
binary_bounds :: proc(op: code.Op, a, b: code.Bounds) -> code.Bounds {
	if !in_64(a) || !in_64(b) do return code.EVERY
	corners :: proc(f: proc(x, y: i128) -> i128, a, b: code.Bounds) -> code.Bounds {
		xs := [4]i128{f(a.lo, b.lo), f(a.lo, b.hi), f(a.hi, b.lo), f(a.hi, b.hi)}
		return fit({min(xs[0], xs[1], xs[2], xs[3]), max(xs[0], xs[1], xs[2], xs[3])})
	}
	// a product of two words may pass what an i128 holds: not read
	big :: proc(b: code.Bounds) -> bool {return b.lo < -(i128(1) << 62) || b.hi > i128(1) << 62}
	if op == .Mul && big(a) && big(b) do return code.EVERY
	#partial switch op {
	case .Add:
		return fit({a.lo + b.lo, a.hi + b.hi})
	case .Sub:
		return fit({a.lo - b.hi, a.hi - b.lo})
	case .Mul:
		return corners(proc(x, y: i128) -> i128 {return x * y}, a, b)
	case .Div:
		if b.lo > 0 do return corners(proc(x, y: i128) -> i128 {return x / y}, a, b)
	case .Mod:
		if b.lo <= 0 do break
		m := b.hi - 1
		switch {
		case a.lo >= 0:
			return {0, min(m, a.hi)}
		case a.hi <= 0:
			return {max(-m, a.lo), 0}
		}
		return {-m, m}
	case .Shl:
		if b.lo == b.hi && b.lo >= 0 && b.lo < 63 do return corners(proc(x, y: i128) -> i128 {return x << uint(y)}, a, b)
	case .Shr:
		if b.lo >= 0 && b.hi < 64 do return corners(proc(x, y: i128) -> i128 {return x >> uint(y)}, a, b)
	case .And:
		switch {
		case a.lo >= 0 && b.lo >= 0:
			return {0, min(a.hi, b.hi)}
		case a.lo >= 0:
			return {0, a.hi}
		case b.lo >= 0:
			return {0, b.hi}
		}
	case .Mul_High:
		// a not negative times an integer of 64 bits as unsigned, its high half
		if a.lo >= 0 && b.lo == b.hi {
			m := b.lo
			return {(a.lo * m) >> 64, (a.hi * m) >> 64}
		}
	case .Pow:
		if a.lo >= 0 && b.lo >= 0 && b.hi < 64 {
			lo, lo_ok := power(a.lo, b.lo)
			hi, hi_ok := power(a.hi, b.hi)
			if lo_ok && hi_ok && a.lo >= 1 do return fit({lo, hi})
			if hi_ok do return fit({0, max(hi, 1)})
		}
	}
	return code.EVERY
}

// power: x ** n, when it stays within 64 bits.
power :: proc(x, n: i128) -> (i128, bool) {
	out: i128 = 1
	for _ in 0 ..< n {
		out *= x
		if out > i128(max(i64)) do return 0, false
	}
	return out, true
}

// exact: op on the integers x and y — x alone for a unary one — exactly: false
// where it is not one integer a word holds (code.in_word).
exact :: proc(op: code.Op, x, y: i128) -> (r: i128, ok: bool) {
	small :: proc(v: i128) -> bool {return v >= -(i128(1) << 64) && v <= i128(1) << 64}
	if !small(x) || !small(y) do return
	switch op {
	case .Add:
		r = x + y
	case .Sub:
		r = x - y
	case .Mul:
		// two words: the product may pass what an i128 holds
		ux, uy := u128(abs(x)), u128(abs(y))
		if ux != 0 && uy > max(u128) / ux do return
		p := ux * uy
		if p > u128(max(i128)) do return
		r = i128(p)
		if (x < 0) != (y < 0) do r = -r
	case .Div:
		if y == 0 do return
		r = x / y
	case .Mod:
		if y == 0 do return
		r = x % y
	case .Mul_High:
		// the high half of the product of two words read as unsigned
		r = i128((u128(transmute(u64)code.word_of(x)) * u128(transmute(u64)code.word_of(y))) >> 64)
	case .Pow:
		if y < 0 do return
		r = 1
		for _ in 0 ..< y {
			r *= x
			if !small(r) do return
		}
	case .Neg:
		r = -x
	case .And:
		r = x & y
	case .Or:
		r = x | y
	case .Xor:
		r = x ~ y
	case .Not:
		r = ~x
	case .Shl:
		if y < 0 || y > 64 do return
		r = x << uint(y)
		if r >> uint(y) != x do return
	case .Shr:
		if y < 0 do return
		r = y >= 127 ? (x < 0 ? -1 : 0) : x >> uint(y)
	case .Eq:
		r = x == y ? 1 : 0
	case .Ne:
		r = x != y ? 1 : 0
	case .Lt:
		r = x < y ? 1 : 0
	case .Le:
		r = x <= y ? 1 : 0
	case .Gt:
		r = x > y ? 1 : 0
	case .Ge:
		r = x >= y ? 1 : 0
	}
	return r, code.in_word({r, r})
}
