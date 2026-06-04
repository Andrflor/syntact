package x64_assembler

import bc "../../bytecode"

// ============================================================================
// REGISTER ALLOCATION — linear-scan over the bytecode's SSA virtual registers.
//
// The bytecode is already SSA (each vN defined once) and linear, which is the
// ideal input for linear-scan: a value's live interval is [def, last_use], and
// we sweep the intervals in start order, handing out machine registers and
// reclaiming them as intervals expire. Under register pressure a value spills to
// the stack ([rbp - offset]).
//
// CONTROL-FLOW NOTE: our only branches (lowered patterns) jump FORWARD to labels
// placed downstream. So a value's textual last-use index is a SOUND upper bound
// on its real live range — a forward jump can only shorten reachability, never
// extend a value's life past its last textual mention. This keeps liveness a
// single linear pass; a backward edge (loops) would require extending intervals
// to the loop end, which we'll add when the language grows loops.
// ============================================================================

// Where a virtual register lives after allocation.
Loc_Kind :: enum {
	Register, // in a GPR
	Stack, // spilled to [rbp - offset]
}

VReg_Loc :: struct {
	kind:   Loc_Kind,
	reg:    Register64, // valid when kind == Register
	offset: int, // positive byte offset below rbp, when kind == Stack
}

// The allocation result: one location per virtual register, plus the total
// stack space the spills need (for the function prologue's `sub rsp, N`).
Reg_Alloc :: struct {
	locs:       []VReg_Loc,
	stack_size: int, // bytes to reserve for spilled values (16-aligned)
}

// The general-purpose registers we hand out, in allocation-preference order.
// R10 is EXCLUDED too: it's the dedicated scratch holding the ARGS_TABLE base
// (loaded once, read by every Load_Arg). R10 is CALLER-saved and never a SysV
// argument register, so this stays correct when the backend grows real functions
// — unlike RBX (callee-saved), which would need save/restore in an ABI function.
// RAX and RDX are deliberately EXCLUDED — they are the fixed scratch/clobber
// pair for imul/idiv (idiv writes both), so the emitter always has them free.
// RSP/RBP are the stack frame. RBX is callee-saved; reserved for later use.
// RCX is excluded too: variable shifts (shl/shr by a register) require the count
// in CL, so the emitter keeps RCX free as the shift-count scratch.
ALLOCATABLE_REGS := [?]Register64{.RSI, .RDI, .R8, .R9, .R10, .R11, .R12, .R13, .R14, .R15}

// A live interval for one virtual register.
Live_Interval :: struct {
	vreg:  int,
	start: int, // instruction index of its definition
	end:   int, // instruction index of its last use (inclusive)
}

// allocate_registers runs liveness + linear-scan over a lowered program, with
// move-biased coloring (Briggs): a value prefers the register of a move-related
// operand that dies at its definition, so the copy elides in the emitter.
allocate_registers :: proc(prog: ^bc.BC_Program) -> Reg_Alloc {
	n := prog.value_count
	locs := make([]VReg_Loc, n)

	intervals := compute_intervals(prog)
	defer delete(intervals)

	// Move-bias hints: hint[dst] = a source vreg dst would like to share a
	// register with. Set for `dst = a op b` when `a` dies at this instruction
	// (its last use), and for `dst = move src`. Coalescing is then safe: the
	// source's interval has expired (no interference), so reusing its register
	// erases the copy. -1 = no hint.
	hint := make([]int, n)
	defer delete(hint)
	for i in 0 ..< n do hint[i] = -1
	build_move_hints(prog, hint)

	// Physical-register preferences: a value consumed by a fixed-register sink
	// (the ret value goes to RDI for the exit syscall / RSI for the string write)
	// prefers that register, so the final mov-into-the-ABI-register elides. -1 =
	// none; otherwise the index into ALLOCATABLE_REGS+ the register value.
	phys_pref := make([]int, n) // stores u8(Register64)+1, 0 = none
	defer delete(phys_pref)
	for inst in prog.insts {
		if r, ok := inst.(bc.BC_Ret); ok {
			pref := prog.result_type == .Str ? Register64.RSI : Register64.RDI
			phys_pref[int(r.src)] = int(u8(pref)) + 1
		}
	}

	// Active intervals, kept sorted by increasing `end` so the earliest-expiring
	// is reclaimed first. free_regs is the pool of currently-unused GPRs.
	free_regs := make([dynamic]Register64)
	defer delete(free_regs)
	#reverse for r in ALLOCATABLE_REGS do append(&free_regs, r) // pop takes the last

	active := make([dynamic]Live_Interval)
	defer delete(active)
	active_reg := make(map[int]Register64) // vreg → its assigned reg, while active
	defer delete(active_reg)

	next_spill_offset := 0

	for iv in intervals {
		// Expire every active interval that ends before this one starts; return
		// its register to the pool. Use `iv.start + 1` so an operand whose LAST use
		// is exactly at this instruction (end == iv.start) is also reclaimed — its
		// value is read before the result is written, so the register is free to
		// reuse for the result. This is what makes move-coalescing fire (a dies
		// here → dst takes a's register → the copy vanishes).
		expire_old(&active, &active_reg, &free_regs, iv.start + 1)

		if len(free_regs) > 0 {
			reg, has_pref := Register64{}, false
			// 1) Physical preference (ret value → RDI/RSI): if that exact register
			// is free, take it so the final mov-into-the-ABI-register elides.
			if phys_pref[iv.vreg] > 0 {
				want := Register64(u8(phys_pref[iv.vreg] - 1))
				for fr, idx in free_regs {
					if fr == want {
						reg = fr; has_pref = true
						ordered_remove(&free_regs, idx)
						break
					}
				}
			}
			// 2) Biased coloring: reuse a move-related source's just-freed register
			// so the emitter elides the copy.
			if !has_pref && hint[iv.vreg] >= 0 {
				src := hint[iv.vreg]
				if loc := locs[src]; loc.kind == .Register {
					for fr, idx in free_regs {
						if fr == loc.reg {
							reg = fr; has_pref = true
							ordered_remove(&free_regs, idx)
							break
						}
					}
				}
			}
			if !has_pref do reg = pop(&free_regs)
			locs[iv.vreg] = VReg_Loc{kind = .Register, reg = reg}
			active_reg[iv.vreg] = reg
			insert_active(&active, iv)
		} else {
			// Pressure: spill. Pick the active interval that ends LATEST; if it
			// ends later than this one, steal its register and spill IT, else
			// spill the current interval.
			next_spill_offset += 8
			spill_at := next_spill_offset
			if len(active) > 0 {
				last := active[len(active) - 1]
				if last.end > iv.end {
					reg := active_reg[last.vreg]
					// Move `last` to the stack, give its reg to iv.
					locs[last.vreg] = VReg_Loc{kind = .Stack, offset = spill_at}
					delete_key(&active_reg, last.vreg)
					ordered_remove(&active, len(active) - 1)
					locs[iv.vreg] = VReg_Loc{kind = .Register, reg = reg}
					active_reg[iv.vreg] = reg
					insert_active(&active, iv)
				} else {
					locs[iv.vreg] = VReg_Loc{kind = .Stack, offset = spill_at}
				}
			} else {
				locs[iv.vreg] = VReg_Loc{kind = .Stack, offset = spill_at}
			}
		}
	}

	// 16-byte align the spill area for ABI-correct stack alignment.
	stack_size := (next_spill_offset + 15) & ~int(15)
	return Reg_Alloc{locs = locs, stack_size = stack_size}
}

// build_move_hints fills hint[dst] with a move-related source register preference.
// For `dst = a op b`, if operand `a` makes its LAST use at this instruction (so
// its live range ends and won't interfere), dst prefers a's register. For
// `dst = move src`, dst prefers src's register. This is the bias that lets the
// emitter's reg→reg copies (mov Rdst, Ra) collapse to nothing.
build_move_hints :: proc(prog: ^bc.BC_Program, hint: []int) {
	n := prog.value_count
	last := make([]int, n)
	defer delete(last)
	for i in 0 ..< n do last[i] = -1
	for inst, pc in prog.insts {
		for u in bc_uses(inst) {
			if u >= 0 do last[u] = pc
		}
	}
	for inst, pc in prog.insts {
		#partial switch v in inst {
		case bc.BC_Bin:
			// `a` is the operand the emitter seeds the dst register with. If a dies
			// here, dst can take a's register.
			if last[int(v.a)] == pc do hint[int(v.dst)] = int(v.a)
		case bc.BC_Bin_Imm:
			if last[int(v.a)] == pc do hint[int(v.dst)] = int(v.a)
		case bc.BC_Cmp_Imm:
			if last[int(v.a)] == pc do hint[int(v.dst)] = int(v.a)
		case bc.BC_Move:
			if last[int(v.src)] == pc do hint[int(v.dst)] = int(v.src)
		}
	}
}

// compute_intervals does the single backward+forward liveness pass: a value's
// def index is where it appears as a dst, its end index is its last use.
compute_intervals :: proc(prog: ^bc.BC_Program) -> [dynamic]Live_Interval {
	n := prog.value_count
	def := make([]int, n)
	last := make([]int, n)
	defer delete(def)
	defer delete(last)
	for i in 0 ..< n {
		def[i] = -1
		last[i] = -1
	}

	for inst, pc in prog.insts {
		// Record uses (operands) first, then the def.
		for u in bc_uses(inst) {
			if u >= 0 do last[u] = pc
		}
		if d, ok := bc_def(inst); ok {
			if def[d] == -1 do def[d] = pc
			if last[d] < pc do last[d] = pc // a value with no later use lives at its def
		}
	}

	intervals := make([dynamic]Live_Interval)
	for v in 0 ..< n {
		if def[v] == -1 do continue // never defined (shouldn't happen) → skip
		end := last[v] >= def[v] ? last[v] : def[v]
		append(&intervals, Live_Interval{vreg = v, start = def[v], end = end})
	}
	// Sort by start index (insertion sort — programs are small).
	for i in 1 ..< len(intervals) {
		j := i
		for j > 0 && intervals[j - 1].start > intervals[j].start {
			intervals[j - 1], intervals[j] = intervals[j], intervals[j - 1]
			j -= 1
		}
	}
	return intervals
}

// bc_def returns the virtual register an instruction defines, if any.
bc_def :: proc(inst: bc.BC_Inst) -> (int, bool) {
	switch v in inst {
	case bc.BC_Const:
		return int(v.dst), true
	case bc.BC_Const_F:
		return int(v.dst), true
	case bc.BC_Str_Const:
		return int(v.dst), true
	case bc.BC_Load_Arg:
		return int(v.dst), true
	case bc.BC_Bin:
		return int(v.dst), true
	case bc.BC_Bin_Imm:
		return int(v.dst), true
	case bc.BC_Cmp:
		return int(v.dst), true
	case bc.BC_Cmp_Imm:
		return int(v.dst), true
	case bc.BC_Move:
		return int(v.dst), true
	case bc.BC_Label_Def, bc.BC_Jump, bc.BC_Branch_Zero, bc.BC_Ret:
		return 0, false
	}
	return 0, false
}

// bc_uses returns the virtual registers an instruction reads.
bc_uses :: proc(inst: bc.BC_Inst) -> []int {
	@(static) buf: [2]int
	switch v in inst {
	case bc.BC_Const, bc.BC_Const_F, bc.BC_Str_Const, bc.BC_Load_Arg, bc.BC_Label_Def, bc.BC_Jump:
		return buf[:0]
	case bc.BC_Bin:
		buf[0] = int(v.a); buf[1] = int(v.b)
		return buf[:2]
	case bc.BC_Bin_Imm:
		buf[0] = int(v.a)
		return buf[:1]
	case bc.BC_Cmp:
		buf[0] = int(v.a); buf[1] = int(v.b)
		return buf[:2]
	case bc.BC_Cmp_Imm:
		buf[0] = int(v.a)
		return buf[:1]
	case bc.BC_Move:
		buf[0] = int(v.src)
		return buf[:1]
	case bc.BC_Branch_Zero:
		buf[0] = int(v.cond)
		return buf[:1]
	case bc.BC_Ret:
		buf[0] = int(v.src)
		return buf[:1]
	}
	return buf[:0]
}

// expire_old returns the registers of every active interval that has ended
// before `point` to the free pool.
expire_old :: proc(
	active: ^[dynamic]Live_Interval,
	active_reg: ^map[int]Register64,
	free_regs: ^[dynamic]Register64,
	point: int,
) {
	i := 0
	for i < len(active) {
		if active[i].end < point {
			if reg, ok := active_reg[active[i].vreg]; ok {
				append(free_regs, reg)
				delete_key(active_reg, active[i].vreg)
			}
			ordered_remove(active, i)
		} else {
			i += 1
		}
	}
}

// insert_active keeps `active` sorted by increasing end index.
insert_active :: proc(active: ^[dynamic]Live_Interval, iv: Live_Interval) {
	pos := len(active)
	for k in 0 ..< len(active) {
		if active[k].end > iv.end {
			pos = k
			break
		}
	}
	resize(active, len(active) + 1)
	for k := len(active) - 1; k > pos; k -= 1 {
		active[k] = active[k - 1]
	}
	active[pos] = iv
}
