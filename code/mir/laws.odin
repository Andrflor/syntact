package code_mir

import code ".."

// THE LAWS OF THE CODE OF A MACHINE
//
// Identities of the integers and of the floats, applied where the operands allow
// it, with what the kernel proved of them — their bounds:
//
//   x + 0 = x - 0 = x | 0 = x ^ 0 = x << 0 = x >> 0 = x * 1 = x / 1 = x ** 1 = x
//   x * 0 = x & 0 = x % 1 = 0        x ** 0 = 1
//   x * -1 = -x
//   x * 2ᵏ = x << k
//   x / 2ᵏ = x >> k                   x ≥ 0
//   x % 2ᵏ = x & (2ᵏ - 1)             x ≥ 0
//   x ** 2m = (x ** m)²   x ** (2m + 1) = x · (x ** m)²
//   c ⊕ x = x ⊕ c                     ⊕ commutes
//   c ◁ x = x ▷ c                     ▷ the converse of ◁
//
// so that a constant is the second operand, and a backend has one instruction for
// each operation, whatever the machine.
laws :: proc(f: ^Func) {
	value := constant_values(f)
	for &b in f.blocks {
		out := make([dynamic]Inst)
		for inst in b.insts {
			#partial switch i in inst {
			case Binary:
				binary_law(f, &out, i, value)
			case Compare:
				c := i
				c.cond, c.a, c.b = converse_law(c.cond, c.a, c.b, value)
				append(&out, c)
			case:
				append(&out, inst)
			}
		}
		b.insts = out
		if br, is_branch := b.end.(Branch); is_branch {
			br.cond, br.a, br.b = converse_law(br.cond, br.a, br.b, value)
			b.end = br
		}
	}
}

binary_law :: proc(f: ^Func, out: ^[dynamic]Inst, i: Binary, value: []Maybe(i64)) {
	i := i
	// a constant first, where the operation commutes, goes second
	if r, is_reg := i.b.(Reg); is_reg {
		#partial switch i.op {
		case .Add, .Mul, .And, .Or, .Xor:
			if c, known := value[i.a].?; known do i.a, i.b = r, c
		}
	}
	c, constant := i.b.(i64)
	if !constant {
		append(out, i)
		return
	}
	if i.op == .Pow {
		power_law(f, out, i.dst, i.a, c)
		return
	}
	nonnegative := f.kinds[i.a].bounds.lo >= 0
	k, power := log2(c)
	#partial switch i.op {
	case .Add, .Sub, .Or, .Xor, .Shl, .Shr:
		if c == 0 {
			append(out, Copy{i.dst, i.a})
			return
		}
	case .Mul:
		switch {
		case c == 0:
			append(out, Copy{i.dst, i64(0)})
			return
		case c == 1:
			append(out, Copy{i.dst, i.a})
			return
		case c == -1:
			append(out, Unary{.Neg, i.dst, i.a})
			return
		case power:
			append(out, Binary{.Shl, i.dst, i.a, k})
			return
		}
	case .Div:
		switch {
		case c == 1:
			append(out, Copy{i.dst, i.a})
			return
		case power && nonnegative:
			append(out, Binary{.Shr, i.dst, i.a, k})
			return
		}
	case .Mod:
		switch {
		case c == 1:
			append(out, Copy{i.dst, i64(0)})
			return
		case power && nonnegative:
			append(out, Binary{.And, i.dst, i.a, c - 1})
			return
		}
	case .And:
		if c == 0 {
			append(out, Copy{i.dst, i64(0)})
			return
		}
	}
	append(out, i)
}

// power_law: dst = x ** n, n ≥ 0 known: the squares of x, by the bits of n from the
// highest, times x at each bit set.
power_law :: proc(f: ^Func, out: ^[dynamic]Inst, dst, x: Reg, n: i64) {
	m := f.kinds[x].machine
	switch n {
	case 0:
		if m == .Real do append(out, Real{dst, transmute(i64)f64(1)})
		else do append(out, Copy{dst, i64(1)})
		return
	case 1:
		append(out, Copy{dst, x})
		return
	}
	top := 0
	for b := n; b > 1; b >>= 1 do top += 1
	r := x
	for bit := top - 1; bit >= 0; bit -= 1 {
		set := n >> uint(bit) & 1 == 1
		square := !set && bit == 0 ? dst : register(f, m)
		append(out, Binary{.Mul, square, r, r})
		r = square
		if set {
			times := bit == 0 ? dst : register(f, m)
			append(out, Binary{.Mul, times, r, x})
			r = times
		}
	}
}

// converse_law: a constant first, in a comparison, goes second, by the converse.
converse_law :: proc(cond: Cond, a: Reg, b: Operand, value: []Maybe(i64)) -> (Cond, Reg, Operand) {
	if r, is_reg := b.(Reg); is_reg {
		if c, known := value[a].?; known do return CONVERSE[cond], r, c
	}
	return cond, a, b
}

// CONTRARY: a ◁̸ b = a ▷ b; CONVERSE: b ◁ a = a ▷ b.
CONTRARY := [Cond]Cond {
	.Eq       = .Ne,
	.Ne       = .Eq,
	.Lt       = .Ge,
	.Le       = .Gt,
	.Gt       = .Le,
	.Ge       = .Lt,
	.Below    = .Above_Eq,
	.Below_Eq = .Above,
	.Above    = .Below_Eq,
	.Above_Eq = .Below,
}

CONVERSE := [Cond]Cond {
	.Eq       = .Eq,
	.Ne       = .Ne,
	.Lt       = .Gt,
	.Le       = .Ge,
	.Gt       = .Lt,
	.Ge       = .Le,
	.Below    = .Above,
	.Below_Eq = .Above_Eq,
	.Above    = .Below,
	.Above_Eq = .Below_Eq,
}

// constant_values: the integer each register written once, by an integer, holds.
constant_values :: proc(f: ^Func) -> []Maybe(i64) {
	count := make([]int, len(f.kinds))
	value := make([]Maybe(i64), len(f.kinds))
	for i in 0 ..< len(f.source.params) do count[i] += 1
	for b in f.blocks do for inst in b.insts {
		w := writes(inst)
		if w == NO_REG do continue
		count[w] += 1
		if c, is_copy := inst.(Copy); is_copy {
			if v, is_int := c.src.(i64); is_int do value[w] = v
		}
	}
	for &v, r in value do if count[r] != 1 do v = nil
	return value
}

// register: a new register of the machine m.
register :: proc(f: ^Func, m: code.Machine) -> Reg {
	append(&f.kinds, code.Kind{m, code.EVERY})
	return Reg(len(f.kinds) - 1)
}

// log2: k when c = 2ᵏ, k ≥ 1.
log2 :: proc(c: i64) -> (k: i64, ok: bool) {
	if c < 2 || c & (c - 1) != 0 do return
	for x := c; x > 1; x >>= 1 do k += 1
	return k, true
}
