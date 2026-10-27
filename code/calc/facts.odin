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
	case .Call:
		if g.prog.funcs[n.index].pure do out.machine = g.prog.funcs[n.index].result
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
		#partial switch n.op {
		case .Neg:
			out.bounds = fit({-a.bounds.hi, -a.bounds.lo})
		case .Not:
			out.bounds = fit({-a.bounds.hi - 1, -a.bounds.lo - 1})
		}
		if x, known := a.constant.?; known do out.constant = code.unary(n.op, .Int, code.Datum{int = x}).int
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
			if d, ok := code.binary_of(n.op, .Int, code.Datum{int = x}, code.Datum{int = y}); ok do out.constant = d.int
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
	case .Start, .Arm, .Foreign, .Match, .Loop, .Again, .Exit:
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

// in_64: bounds the machine holds without wrapping.
in_64 :: proc(b: code.Bounds) -> bool {
	return b.lo >= i128(min(i64)) && b.hi <= i128(max(i64))
}

// fit: the bounds, when the machine computes them without wrapping.
fit :: proc(b: code.Bounds) -> code.Bounds {
	return in_64(b) ? b : code.EVERY
}

// binary_bounds: the bounds of a op b, from theirs.
binary_bounds :: proc(op: code.Op, a, b: code.Bounds) -> code.Bounds {
	if !in_64(a) || !in_64(b) do return code.EVERY
	corners :: proc(f: proc(x, y: i128) -> i128, a, b: code.Bounds) -> code.Bounds {
		xs := [4]i128{f(a.lo, b.lo), f(a.lo, b.hi), f(a.hi, b.lo), f(a.hi, b.hi)}
		return fit({min(xs[0], xs[1], xs[2], xs[3]), max(xs[0], xs[1], xs[2], xs[3])})
	}
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
			m := i128(u64(i64(b.lo)))
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
