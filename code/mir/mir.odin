package code_mir

import code ".."

// THE CODE OF A MACHINE
//
// The code of a program (code/) laid out for a machine: blocks of instructions on
// virtual registers, each ending in a jump, a branch or a return. A match becomes
// the tests of its covers, a loop a block each Again jumps back to, after the
// parameters take their values all at once. Then each register gets a place: a
// register of the machine or a slot of the frame, by a linear scan over the ranges
// where the registers live (alloc.odin). A backend (code/x64) says what registers
// it has and turns each instruction into its own.

Reg :: distinct int

NO_REG :: Reg(-1)

// Operand: a register, or an integer the instruction holds.
Operand :: union {
	Reg,
	i64,
}

Block_Id :: distinct int

// Cond: a comparison of two integers, signed, or unsigned for Below_Eq and Above;
// of two floats, unordered never holding.
Cond :: enum u8 {
	Eq,
	Ne,
	Lt,
	Le,
	Gt,
	Ge,
	Below_Eq,
	Above,
}

Inst :: union {
	Copy, // dst = src
	Real, // dst = a float, by its bits
	Text, // dst = the address of a text of the program
	Input, // dst = the n-th input of the program
	Unary, // dst = op a
	Binary, // dst = a op b
	Compare, // dst = a cond b: 1 or 0
	Foreign, // dst = a symbol, called
	Call, // dst = a function of the program, called
}

Copy :: struct {
	dst: Reg,
	src: Operand,
}

Real :: struct {
	dst:  Reg,
	bits: i64,
}

Text :: struct {
	dst:  Reg,
	text: int,
}

Input :: struct {
	dst:  Reg,
	slot: int,
}

Unary :: struct {
	op:     code.Op,
	dst, a: Reg,
}

Binary :: struct {
	op:   code.Op,
	dst:  Reg,
	a:    Reg,
	b:    Operand,
}

Compare :: struct {
	cond: Cond,
	dst:  Reg,
	a:    Reg,
	b:    Operand,
}

Foreign :: struct {
	dst:    Reg, // NO_REG: it gives nothing back
	symbol: int,
	args:   []Operand,
}

Call :: struct {
	dst:  Reg,
	func: int,
	args: []Operand,
}

Terminator :: union {
	Jump,
	Branch,
	Return,
}

Jump :: struct {
	to: Block_Id,
}

// Branch: to yes when a cond b holds, otherwise to no.
Branch :: struct {
	cond:    Cond,
	a:       Reg,
	b:       Operand,
	yes, no: Block_Id,
}

Return :: struct {
	value: Reg, // NO_REG: nothing
}

Block :: struct {
	insts: [dynamic]Inst,
	end:   Terminator,
}

// Func: a function laid out in blocks, the first its entry; its parameters are its
// first registers, r0…, as in the code it comes from, each value its register.
// The blocks are placed in order: each after those that reach it, but along loops.
Func :: struct {
	source: ^code.Func,
	blocks: [dynamic]Block,
	kinds:  [dynamic]code.Kind, // per register
	order:  []Block_Id,
}

Program :: struct {
	source: ^code.Program,
	funcs:  []^Func,
}

// layout: the program, each function laid out in blocks.
layout :: proc(p: ^code.Program) -> Program {
	out := Program{source = p, funcs = make([]^Func, len(p.funcs))}
	for f, i in p.funcs do out.funcs[i] = layout_func(f)
	return out
}

// Builder: a function being laid out: the block the instructions go to, and the
// loops it is in, innermost last.
Builder :: struct {
	f:       ^Func,
	current: Block_Id,
	loops:   [dynamic]Loop_Head,
}

Loop_Head :: struct {
	head:   Block_Id,
	params: []code.Value,
}

layout_func :: proc(src: ^code.Func) -> ^Func {
	f := new_clone(Func{source = src})
	append(&f.kinds, ..src.kinds[:])
	b := Builder{f = f}
	b.current = new_block(&b)
	body(&b, src.body)
	finish(&b, Return{value = src.body.value == code.NONE ? NO_REG : Reg(src.body.value)})
	constants(f)
	unread(f)
	f.order = placed(f)
	return f
}

// unread: what computes a register nothing reads goes, until nothing more does;
// a call stays, for what it does, but gives nothing back.
unread :: proc(f: ^Func) {
	regs := make([dynamic]Reg)
	for changed := true; changed; {
		changed = false
		read := make([]bool, len(f.kinds))
		for b in f.blocks {
			for inst in b.insts {
				clear(&regs)
				uses(inst, &regs)
				for r in regs do read[r] = true
			}
			clear(&regs)
			end_uses(b.end, &regs)
			for r in regs do read[r] = true
		}
		for &b in f.blocks {
			kept := make([dynamic]Inst)
			for original in b.insts {
				inst := original
				w := writes(inst)
				switch &i in inst {
				case Foreign:
					if w != NO_REG && !read[w] do i.dst = NO_REG
				case Call:
					if w != NO_REG && !read[w] do i.dst = NO_REG
				case Copy, Real, Text, Input, Unary, Binary, Compare:
					if !read[w] {
						changed = true
						continue
					}
				}
				append(&kept, inst)
			}
			b.insts = kept
		}
	}
}

// placed: the blocks reached from the entry, in reverse postorder: a block after
// the blocks that reach it, loops apart; a branch's no first, so that it follows.
placed :: proc(f: ^Func) -> []Block_Id {
	seen := make([]bool, len(f.blocks))
	post := make([dynamic]Block_Id)
	visit :: proc(f: ^Func, b: Block_Id, seen: []bool, post: ^[dynamic]Block_Id) {
		if seen[b] do return
		seen[b] = true
		#partial switch e in f.blocks[b].end {
		case Jump:
			visit(f, e.to, seen, post)
		case Branch:
			visit(f, e.yes, seen, post)
			visit(f, e.no, seen, post)
		}
		append(post, b)
	}
	visit(f, 0, seen, &post)
	out := make([]Block_Id, len(post))
	for b, i in post do out[len(post) - 1 - i] = b
	return out
}

// constants: a register written once, by an integer, is that integer where an
// operand may be one; its copy goes when nothing reads it any more.
constants :: proc(f: ^Func) {
	writes_count := make([]int, len(f.kinds))
	value := make([]Maybe(i64), len(f.kinds))
	for i in 0 ..< len(f.source.params) do writes_count[i] += 1
	for b in f.blocks do for inst in b.insts {
		w := writes(inst)
		if w == NO_REG do continue
		writes_count[w] += 1
		if c, is_copy := inst.(Copy); is_copy {
			if v, is_int := c.src.(i64); is_int do value[w] = v
		}
	}
	known :: proc(o: Operand, value: []Maybe(i64), writes_count: []int) -> Operand {
		if r, is_reg := o.(Reg); is_reg && writes_count[r] == 1 {
			if v, has := value[r].?; has do return v
		}
		return o
	}
	for &b in f.blocks {
		for &inst in b.insts {
			switch &i in inst {
			case Copy:
				i.src = known(i.src, value, writes_count)
			case Binary:
				i.b = known(i.b, value, writes_count)
			case Compare:
				i.b = known(i.b, value, writes_count)
			case Foreign:
				for &a in i.args do a = known(a, value, writes_count)
			case Call:
				for &a in i.args do a = known(a, value, writes_count)
			case Real, Text, Input, Unary:
			}
		}
		if br, is_branch := b.end.(Branch); is_branch {
			br.b = known(br.b, value, writes_count)
			b.end = br
		}
	}
	// what is still read
	read := make([]bool, len(f.kinds))
	regs := make([dynamic]Reg)
	for b in f.blocks {
		for inst in b.insts {
			clear(&regs)
			uses(inst, &regs)
			for r in regs do read[r] = true
		}
		clear(&regs)
		end_uses(b.end, &regs)
		for r in regs do read[r] = true
	}
	for &b in f.blocks {
		kept := make([dynamic]Inst)
		for inst in b.insts {
			if c, is_copy := inst.(Copy); is_copy && writes_count[c.dst] == 1 && value[c.dst] != nil && !read[c.dst] do continue
			append(&kept, inst)
		}
		b.insts = kept
	}
}

new_block :: proc(b: ^Builder) -> Block_Id {
	append(&b.f.blocks, Block{})
	return Block_Id(len(b.f.blocks) - 1)
}

new_reg :: proc(b: ^Builder, m: code.Machine) -> Reg {
	append(&b.f.kinds, code.Kind{m, code.EVERY})
	return Reg(len(b.f.kinds) - 1)
}

emit :: proc(b: ^Builder, inst: Inst) {
	append(&b.f.blocks[b.current].insts, inst)
}

// finish: the current block ends; what follows goes nowhere until a block is
// started.
finish :: proc(b: ^Builder, t: Terminator) {
	b.f.blocks[b.current].end = t
}

start :: proc(b: ^Builder, id: Block_Id) {
	b.current = id
}

COMPARES := #partial [code.Op]Cond {
	.Eq = .Eq,
	.Ne = .Ne,
	.Lt = .Lt,
	.Le = .Le,
	.Gt = .Gt,
	.Ge = .Ge,
}

body :: proc(b: ^Builder, src: code.Body) {
	for inst in src.insts {
		switch i in inst {
		case code.Const:
			emit(b, Copy{Reg(i.dst), i.value})
		case code.Real_Const:
			emit(b, Real{Reg(i.dst), transmute(i64)i.value})
		case code.Text_Const:
			emit(b, Text{Reg(i.dst), i.text})
		case code.Input:
			emit(b, Input{Reg(i.dst), i.slot})
		case code.Unary:
			emit(b, Unary{i.op, Reg(i.dst), Reg(i.a)})
		case code.Binary:
			#partial switch i.op {
			case .Eq, .Ne, .Lt, .Le, .Gt, .Ge:
				emit(b, Compare{COMPARES[i.op], Reg(i.dst), Reg(i.a), Reg(i.b)})
			case:
				emit(b, Binary{i.op, Reg(i.dst), Reg(i.a), Reg(i.b)})
			}
		case code.In:
			// 1, unless the cover does not take x
			yes, no, done := new_block(b), new_block(b), new_block(b)
			test(b, Reg(i.x), i.cover, yes, no)
			start(b, yes)
			emit(b, Copy{Reg(i.dst), i64(1)})
			finish(b, Jump{done})
			start(b, no)
			emit(b, Copy{Reg(i.dst), i64(0)})
			finish(b, Jump{done})
			start(b, done)
		case code.Narrow:
			emit(b, Copy{Reg(i.dst), Reg(i.src)})
		case code.Foreign:
			emit(b, Foreign{i.dst == code.NONE ? NO_REG : Reg(i.dst), i.symbol, regs(i.args)})
		case code.Call:
			emit(b, Call{i.dst == code.NONE ? NO_REG : Reg(i.dst), i.func, regs(i.args)})
		case code.Match:
			done := new_block(b)
			for arm, n in i.arms {
				last := n == len(i.arms) - 1
				taken := new_block(b)
				next := last ? Block_Id(-1) : new_block(b)
				if last do finish(b, Jump{taken})
				else do test(b, Reg(i.target), arm.cover, taken, next)
				start(b, taken)
				body(b, arm.body)
				if i.dst != code.NONE && arm.body.value != code.NONE do emit(b, Copy{Reg(i.dst), Reg(arm.body.value)})
				finish(b, Jump{done})
				if !last do start(b, next)
			}
			start(b, done)
		case code.Loop:
			head := new_block(b)
			parallel(b, i.params, i.init)
			finish(b, Jump{head})
			start(b, head)
			append(&b.loops, Loop_Head{head, i.params})
			body(b, i.body)
			pop(&b.loops)
			if i.dst != code.NONE do emit(b, Copy{Reg(i.dst), Reg(i.body.value)})
		case code.Again:
			loop := b.loops[len(b.loops) - 1]
			parallel(b, loop.params, i.args)
			finish(b, Jump{loop.head})
			// what follows the Again in its body is not reached
			start(b, new_block(b))
		}
	}
}

regs :: proc(vs: []code.Value) -> []Operand {
	out := make([]Operand, len(vs))
	for v, i in vs do out[i] = Reg(v)
	return out
}

// parallel: dst take the values of src, all read before any is written: a copy
// runs once nothing pending reads its destination; a cycle is broken by a
// register of its own.
parallel :: proc(b: ^Builder, dst, src: []code.Value) {
	Pending :: struct {
		dst: Reg,
		src: Reg,
	}
	pending := make([dynamic]Pending)
	for d, i in dst do if d != src[i] do append(&pending, Pending{Reg(d), Reg(src[i])})
	for len(pending) > 0 {
		moved := false
		for p, n in pending {
			read := false
			for q in pending do read ||= q.src == p.dst
			if read do continue
			emit(b, Copy{p.dst, p.src})
			ordered_remove(&pending, n)
			moved = true
			break
		}
		if moved do continue
		// a cycle: the first destination is kept apart
		d := pending[0].dst
		t := new_reg(b, b.f.kinds[d].machine)
		emit(b, Copy{t, d})
		for &q in pending do if q.src == d do q.src = t
	}
}

// test: to yes when the cover takes x, otherwise to no. Each cell is tested in
// turn; a cell of integers is one comparison where the bounds x has already
// imply one side, or one unsigned comparison of x - lo with hi - lo.
test :: proc(b: ^Builder, x: Reg, c: code.Cover, yes, no: Block_Id) {
	yes, no := yes, no
	if c.negated do yes, no = no, yes
	real := b.f.kinds[x].machine == .Real
	count := real ? len(c.reals) : len(c.ints)
	if count == 0 {
		finish(b, Jump{no})
		return
	}
	known := b.f.kinds[x].bounds
	for j in 0 ..< count {
		next := j == count - 1 ? no : new_block(b)
		if real {
			r := c.reals[j]
			above := r.lo > -max(f64)
			below := r.hi < max(f64)
			if above {
				// x below lo, or at an open lo: not in the cell
				lo := new_reg(b, .Real)
				emit(b, Real{lo, transmute(i64)r.lo})
				within := below ? new_block(b) : yes
				finish(b, Branch{r.lo_open ? .Gt : .Ge, x, lo, within, next})
				if below do start(b, within)
			}
			if below {
				hi := new_reg(b, .Real)
				emit(b, Real{hi, transmute(i64)r.hi})
				finish(b, Branch{r.hi_open ? .Lt : .Le, x, hi, yes, next})
			}
			if !above && !below do finish(b, Jump{yes})
		} else {
			cell := c.ints[j]
			lo_test := cell.lo > known.lo && cell.lo > i128(min(i64))
			hi_test := cell.hi < known.hi && cell.hi < i128(max(i64))
			switch {
			case cell.lo == cell.hi:
				finish(b, Branch{.Eq, x, i64(cell.lo), yes, next})
			case lo_test && hi_test:
				// lo ≤ x ≤ hi: x - lo ≤ hi - lo, unsigned
				shifted := x
				if cell.lo != 0 {
					shifted = new_reg(b, .Int)
					emit(b, Binary{.Sub, shifted, x, i64(cell.lo)})
				}
				finish(b, Branch{.Below_Eq, shifted, i64(cell.hi - cell.lo), yes, next})
			case lo_test:
				finish(b, Branch{.Ge, x, i64(cell.lo), yes, next})
			case hi_test:
				finish(b, Branch{.Le, x, i64(cell.hi), yes, next})
			case:
				finish(b, Jump{yes})
			}
		}
		if j < count - 1 do start(b, next)
	}
}
