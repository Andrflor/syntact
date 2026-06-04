package compiler

// ============================================================================
// AUTO-VECTORIZATION — analysis, deliberately not yet emitting SIMD.
//
// HONEST STATUS: Syntact, by design, reduces all concrete computation at compile
// time (structural reduction folds lists, scope fields, and arithmetic to their
// values — `arr.#0 + arr.#1 + arr.#2 + arr.#3` becomes a single constant). The
// only runtime work the bytecode carries is SCALAR operations on individual ??
// fixed points (one argv value → one register). There is currently:
//   - no loop,
//   - no runtime iteration,
//   - no runtime-valued list / homogeneous vector,
// so there is NOTHING to vectorize: SIMD pays off on N independent elements
// processed by one instruction, and the language does not yet produce that shape.
//
// The one structural candidate today — several ?? arguments masked by the same
// `& 0xff` at entry — is too small and too entangled with the following scalar
// reduction chain to beat scalar `and`s, so emitting `pand` there would be a net
// loss, not a win.
//
// Vectorization becomes real once the language grows runtime-iterable data: a
// map/fold over many ?? inputs, a list whose elements are runtime values, or the
// planned effects/resonance/reactivity (see README) that fan one operation over
// many cells. AT THAT POINT this pass should: detect a run of identical ops over
// independent, contiguous values (same op, same Machine_Type, no cross-lane
// dependency), pack them into an XMM/YMM register, emit the packed op
// (paddd/psubd/pmulld for integers, addps/mulps for floats — the assembler in
// backends/x64 already has the XMM/YMM encodings), and unpack the results.
//
// `vectorizable_run` is the detector stub the future pass will build on: it
// reports a maximal run of BC_Bin with the same operator and machine type whose
// operands form independent lanes. It currently always returns an empty run,
// because the lowering never produces such a run yet — kept so the entry point
// and contract exist and the emitter can call it without a special case.
// ============================================================================

Vector_Run :: struct {
	start: int, // first instruction index of the run
	count: int, // number of lanes (0 = not vectorizable)
	op:    Operator_Kind,
	mt:    Machine_Type,
}

// vectorizable_run scans `prog.insts` from `at` for a maximal SIMD-able run.
// Returns {count = 0} when none (the current, always-taken case).
vectorizable_run :: proc(prog: ^BC_Program, at: int) -> Vector_Run {
	// Contract for the future implementation: a run is k ≥ 4 consecutive BC_Bin
	// with identical op + Machine_Type, whose (a, b) operands are pairwise
	// independent lanes (no result of one feeding another). The structural
	// reduction in reduce.odin currently coalesces such shapes into a scalar
	// chain before they reach here, so no run exists.
	return Vector_Run{start = at, count = 0}
}
