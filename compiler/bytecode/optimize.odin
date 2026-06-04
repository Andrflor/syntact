package bytecode

// ============================================================================
// AFFINE CANONICALIZATION — distribute · combine · canonicalize.
//
// A bytecode optimization pass (target-neutral, so every backend AND the
// interpreter benefit). It rewrites integer affine expressions — sums of
// constant-scaled values — into their minimal form, modeled on LLVM's
// InstCombineAddSub `<coefficient, value>` term representation plus Reassociate's
// canonical ordering.
//
//   3*(2a - 1) + 5a + 3b - 1   →   11a + 3b - 4
//
// An expression's affine form is `Σ kᵢ·χᵢ + c`: a map {value → coefficient} plus
// a constant. `normalize(v)`:
//   Const            → <c, {}>
//   Load_Arg / other → <0, {v: 1}>   (an opaque atom — a ??, or any non-affine
//                                      subexpression like a*a, a/b, a cmp)
//   Add(a, b)        → normalize(a) + normalize(b)        (distribute)
//   Sub(a, b)        → normalize(a) − normalize(b)
//   a op #k          → for Add/Sub fold the immediate; for Mul SCALE the whole
//                      affine form by k (this is the distribution).
//
// Coefficients combine (6a + 5a → 11a), constants fuse (−3 −1 → −4), then the
// result is RE-EMITTED in the cheapest form (canonicalization). Dead intermediate
// values are removed (DCE).
//
// SEMANTIC SAFETY (cf. Alive2-style concerns):
//  - INTEGER ONLY. Floats are skipped (FP add/mul are not associative).
//  - Wraparound is preserved: every term computes in i64 and the domain mask sits
//    on the Load_Arg, so the affine rewrite stays in the same ring Z/2^n where
//    +,−,*-by-constant are associative/commutative/distributive — exact.
//  - SHARING: an intermediate value used OUTSIDE the affine expression it feeds
//    is NOT folded away (its other uses still need it). We only rewrite the value
//    that is the affine root and DCE intermediates with no surviving use.
// ============================================================================

Affine :: struct {
	constant: i64,
	terms:    map[BC_Value]i64, // value → coefficient (no zero coefficients)
}

affine_destroy :: proc(a: ^Affine) {
	delete(a.terms)
}

affine_add_term :: proc(a: ^Affine, v: BC_Value, c: i64) {
	if c == 0 do return
	nc := a.terms[v] + c
	if nc == 0 {
		delete_key(&a.terms, v)
	} else {
		a.terms[v] = nc
	}
}

// affine_add folds `b` into `a` (a += b), consuming b.
affine_add :: proc(a: ^Affine, b: Affine, sign: i64 = 1) {
	a.constant += sign * b.constant
	for v, c in b.terms {
		affine_add_term(a, v, sign * c)
	}
}

// affine_scale multiplies the whole form by a constant k (the distribution step).
affine_scale :: proc(a: ^Affine, k: i64) {
	a.constant *= k
	if k == 0 {
		clear(&a.terms)
		return
	}
	for v in a.terms {
		a.terms[v] *= k
	}
}

// affine_is_atom reports an affine form that is just `1·v` (a single value, no
// constant) — i.e. normalize found nothing to simplify.
affine_is_atom :: proc(a: Affine, v: BC_Value) -> bool {
	return a.constant == 0 && len(a.terms) == 1 && a.terms[v] == 1
}

// ----------------------------------------------------------------------------
// The pass.
// ----------------------------------------------------------------------------

Opt_Ctx :: struct {
	prog:      ^BC_Program,
	def:       []int, // value → index of its defining instruction (-1 if none)
	use_count: []int, // value → number of times it is used as an operand
}

// optimize_affine runs the distribute/combine/canonicalize pass over a program,
// rewriting integer affine roots into their minimal form in place.
optimize_affine :: proc(prog: ^BC_Program) {
	n := prog.value_count
	ctx := Opt_Ctx {
		prog      = prog,
		def       = make([]int, n),
		use_count = make([]int, n),
	}
	defer delete(ctx.def)
	defer delete(ctx.use_count)
	for i in 0 ..< n do ctx.def[i] = -1

	for inst, pc in prog.insts {
		if d, ok := bc_inst_def(inst); ok do ctx.def[d] = pc
		for u in bc_inst_uses(inst) do ctx.use_count[u] += 1
	}

	// PLAN: decide which values are AFFINE ROOTS to rewrite, and which are
	// intermediates ABSORBED into a root (so they must not be re-emitted).
	//   - A value is a root candidate if its def is Add/Sub/Mul-imm.
	//   - normalize(root) develops it; intermediates it consumed (use_count==1,
	//     affine) are absorbed and marked `absorbed`.
	//   - We rewrite a root only if it is NOT itself absorbed by a larger root
	//     (process in order; the outermost root wins) AND the rewrite is a real
	//     simplification (the form isn't a bare atom).
	absorbed := make([]bool, n) // value subsumed into another value's affine form
	is_root := make([]bool, n) // value we will replace with a canonical recompute
	forms := make([]Affine, n)
	defer {
		for i in 0 ..< n do affine_destroy(&forms[i])
		delete(forms); delete(absorbed); delete(is_root)
	}

	// Walk in REVERSE so an outer root is seen before its inner pieces; mark the
	// inner affine pieces (use_count==1) as absorbed.
	for pc := len(prog.insts) - 1; pc >= 0; pc -= 1 {
		d, has_d := bc_inst_def(prog.insts[pc])
		if !has_d do continue
		if absorbed[d] do continue // already part of a bigger root
		if !is_int_value(prog, d) || !is_affine_root(&ctx, BC_Value(d)) do continue
		af := normalize(&ctx, BC_Value(d))
		// Worth rewriting only if it collapsed (more than a bare 1·v atom, and it
		// actually has structure to flatten — at least one term or a constant).
		if affine_is_atom(af, BC_Value(d)) {
			affine_destroy(&af)
			continue
		}
		is_root[d] = true
		forms[d] = af
		mark_absorbed(&ctx, BC_Value(d), absorbed)
	}

	// Re-emit: keep non-root instructions whose dst isn't absorbed; replace each
	// root with its canonical recomputation.
	new_insts := make([dynamic]BC_Inst)
	for inst in prog.insts {
		d, has_d := bc_inst_def(inst)
		if !has_d {
			append(&new_insts, inst)
			continue
		}
		if absorbed[d] do continue // subsumed into a root — drop
		if is_root[d] {
			emit_affine(prog, &new_insts, &ctx, BC_Value(d), forms[d])
			continue
		}
		append(&new_insts, inst)
	}

	delete(prog.insts)
	prog.insts = new_insts
}

// mark_absorbed walks the affine sub-DAG of a root and marks every intermediate
// value (def is Add/Sub/Mul-imm, use_count==1) it dissolves. Atoms (Load_Arg,
// shared values, non-affine) are NOT absorbed — they remain real values.
mark_absorbed :: proc(ctx: ^Opt_Ctx, v: BC_Value, absorbed: []bool) {
	pc := ctx.def[int(v)]
	if pc < 0 do return
	#partial switch inst in ctx.prog.insts[pc] {
	case BC_Bin:
		if inst.op == .Add || inst.op == .Subtract {
			absorb_child(ctx, inst.a, absorbed)
			absorb_child(ctx, inst.b, absorbed)
		}
	case BC_Bin_Imm:
		if inst.op == .Add || inst.op == .Subtract || inst.op == .Multiply {
			absorb_child(ctx, inst.a, absorbed)
		}
	}
}

absorb_child :: proc(ctx: ^Opt_Ctx, v: BC_Value, absorbed: []bool) {
	// A child is absorbed only if it is affine AND used exactly once (here).
	if ctx.use_count[int(v)] != 1 do return
	pc := ctx.def[int(v)]
	if pc < 0 do return
	is_aff := false
	#partial switch inst in ctx.prog.insts[pc] {
	case BC_Bin:
		is_aff = inst.op == .Add || inst.op == .Subtract
	case BC_Bin_Imm:
		is_aff = inst.op == .Add || inst.op == .Subtract || inst.op == .Multiply
	case BC_Const:
		is_aff = true
	}
	if !is_aff do return
	absorbed[int(v)] = true
	mark_absorbed(ctx, v, absorbed)
}

// is_int_value: the value is an integer (not float/string) — affine rewriting is
// integer-only.
is_int_value :: proc(prog: ^BC_Program, v: int) -> bool {
	mt := prog.value_types[v]
	return mtype_is_int(mt) || mt == .None
}

// is_affine_root: the value's defining op is an Add/Sub/Mul-by-immediate that
// normalize can develop, AND every value it subsumes is either an atom we keep or
// has no other use. We accept any Add/Sub/Bin_Imm(Mul/Add/Sub) root and let
// normalize decide; a root that normalizes to a bare atom isn't worth rewriting.
is_affine_root :: proc(ctx: ^Opt_Ctx, v: BC_Value) -> bool {
	pc := ctx.def[int(v)]
	if pc < 0 do return false
	#partial switch inst in ctx.prog.insts[pc] {
	case BC_Bin:
		return inst.op == .Add || inst.op == .Subtract
	case BC_Bin_Imm:
		return inst.op == .Add || inst.op == .Subtract || inst.op == .Multiply
	}
	return false
}

// normalize develops the affine form Σ kᵢ·χᵢ + c of a value. An operand whose
// definition isn't affine (or that is shared — used elsewhere — and so must keep
// its own register) becomes an opaque atom `1·v`.
normalize :: proc(ctx: ^Opt_Ctx, v: BC_Value) -> Affine {
	pc := ctx.def[int(v)]
	if pc < 0 do return atom(v)

	// A value used more than once can't be dissolved into the affine form: other
	// uses still need it as a value. Treat it as an atom (except a pure Const,
	// which is free to duplicate).
	if ctx.use_count[int(v)] > 1 {
		if c, ok := const_of(ctx, v); ok do return Affine{constant = c}
		return atom(v)
	}

	#partial switch inst in ctx.prog.insts[pc] {
	case BC_Const:
		return Affine{constant = inst.imm}
	case BC_Bin:
		if inst.op == .Add {
			a := normalize(ctx, inst.a)
			b := normalize(ctx, inst.b)
			affine_add(&a, b); affine_destroy(&b)
			return a
		}
		if inst.op == .Subtract {
			a := normalize(ctx, inst.a)
			b := normalize(ctx, inst.b)
			affine_add(&a, b, -1); affine_destroy(&b)
			return a
		}
	case BC_Bin_Imm:
		switch inst.op {
		case .Add:
			a := normalize(ctx, inst.a)
			a.constant += inst.imm
			return a
		case .Subtract:
			a := normalize(ctx, inst.a)
			a.constant -= inst.imm
			return a
		case .Multiply:
			a := normalize(ctx, inst.a)
			affine_scale(&a, inst.imm) // DISTRIBUTE k over the affine form
			return a
		case .Divide, .Mod, .BitAnd, .BitOr, .BitXor, .LShift, .RShift,
		     .Equal, .NotEqual, .Less, .Greater, .LessEqual, .GreaterEqual:
		// not affine — fall through to atom
		}
	}
	return atom(v)
}

// emit_affine RE-EMITS an affine form `Σ kᵢ·χᵢ + c` into `out`, producing the
// value `dst`. This is the canonicalization step: terms are emitted in canonical
// order (by value index, à la Reassociate), each `kᵢ·χᵢ` as a single mul-by-
// immediate (the backend strength-reduces it to shl/lea), accumulated, then the
// constant folded in. Fresh temporaries are allocated for partial sums.
//
// Forms degenerate gracefully: an empty form is `const c`; a single 1·v with no
// constant is a move; etc. We try to keep instruction count minimal.
emit_affine :: proc(prog: ^BC_Program, out: ^[dynamic]BC_Inst, ctx: ^Opt_Ctx, dst: BC_Value, af: Affine) {
	// Collect terms in canonical (sorted) order.
	keys := make([dynamic]BC_Value); defer delete(keys)
	for v in af.terms do append(&keys, v)
	// insertion sort by index (small N)
	for i in 1 ..< len(keys) {
		j := i
		for j > 0 && int(keys[j - 1]) > int(keys[j]) {
			keys[j - 1], keys[j] = keys[j], keys[j - 1]
			j -= 1
		}
	}

	// Degenerate: no terms → dst = const.
	if len(keys) == 0 {
		append(out, BC_Const{dst, af.constant})
		return
	}

	// Accumulator value being built. `acc` holds the running sum; for the first
	// term we may write straight into a temp, then fold the rest, and finally a
	// move/op into `dst`.
	fresh :: proc(prog: ^BC_Program, mt: Machine_Type) -> BC_Value {
		v := BC_Value(prog.value_count)
		prog.value_count += 1
		append(&prog.value_types, mt)
		return v
	}
	mt := prog.value_types[int(dst)]

	// Emit `k*v` into a fresh value (or just v when k==1).
	term_val :: proc(prog: ^BC_Program, out: ^[dynamic]BC_Inst, v: BC_Value, k: i64, mt: Machine_Type) -> BC_Value {
		if k == 1 do return v
		t := fresh(prog, mt)
		out_append_mul(out, t, v, k)
		return t
	}

	// First term seeds the accumulator.
	acc := term_val(prog, out, keys[0], af.terms[keys[0]], mt)
	// Add the remaining terms.
	for i in 1 ..< len(keys) {
		tv := term_val(prog, out, keys[i], af.terms[keys[i]], mt)
		s := fresh(prog, mt)
		append(out, BC_Bin{s, .Add, acc, tv})
		acc = s
	}
	// Fold the constant.
	if af.constant != 0 {
		s := dst
		op: BC_Op = af.constant > 0 ? .Add : .Subtract
		imm := af.constant > 0 ? af.constant : -af.constant
		append(out, BC_Bin_Imm{s, op, acc, imm})
		return
	}
	// No constant: dst = acc. If acc is already a distinct fresh value we must
	// move it into dst (dst is the externally-referenced name).
	if acc != dst {
		append(out, BC_Move{dst, acc})
	}
}

out_append_mul :: proc(out: ^[dynamic]BC_Inst, dst, a: BC_Value, k: i64) {
	append(out, BC_Bin_Imm{dst, .Multiply, a, k})
}

atom :: proc(v: BC_Value) -> Affine {
	a := Affine{}
	a.terms[v] = 1
	return a
}

const_of :: proc(ctx: ^Opt_Ctx, v: BC_Value) -> (i64, bool) {
	pc := ctx.def[int(v)]
	if pc < 0 do return 0, false
	if c, ok := ctx.prog.insts[pc].(BC_Const); ok do return c.imm, true
	return 0, false
}

// bc_inst_def / bc_inst_uses mirror the regalloc helpers but live here so the
// pass is self-contained in the bytecode package.
bc_inst_def :: proc(inst: BC_Inst) -> (int, bool) {
	switch v in inst {
	case BC_Const:       return int(v.dst), true
	case BC_Const_F:     return int(v.dst), true
	case BC_Str_Const:   return int(v.dst), true
	case BC_Load_Arg:    return int(v.dst), true
	case BC_Bin:         return int(v.dst), true
	case BC_Bin_Imm:     return int(v.dst), true
	case BC_Cmp:         return int(v.dst), true
	case BC_Cmp_Imm:     return int(v.dst), true
	case BC_Move:        return int(v.dst), true
	case BC_Label_Def, BC_Jump, BC_Branch_Zero, BC_Ret:
		return 0, false
	}
	return 0, false
}

bc_inst_uses :: proc(inst: BC_Inst) -> []int {
	@(static) buf: [2]int
	switch v in inst {
	case BC_Const, BC_Const_F, BC_Str_Const, BC_Load_Arg, BC_Label_Def, BC_Jump:
		return buf[:0]
	case BC_Bin:
		buf[0] = int(v.a); buf[1] = int(v.b); return buf[:2]
	case BC_Bin_Imm:
		buf[0] = int(v.a); return buf[:1]
	case BC_Cmp:
		buf[0] = int(v.a); buf[1] = int(v.b); return buf[:2]
	case BC_Cmp_Imm:
		buf[0] = int(v.a); return buf[:1]
	case BC_Move:
		buf[0] = int(v.src); return buf[:1]
	case BC_Branch_Zero:
		buf[0] = int(v.cond); return buf[:1]
	case BC_Ret:
		buf[0] = int(v.src); return buf[:1]
	}
	return buf[:0]
}
