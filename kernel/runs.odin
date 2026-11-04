package kernel

// RUNS: THEIR PLACES (specs/types.md §5.6)
//
// A run — what `...` places: a scope of anonymous places, Array{T} — is read by its
// places, from 0: how many it has, what one holds, what is left without the first
// ones. On a run not known yet — an input, what a fold builds, what a place
// holds — they are terms, by their laws:
//
//   length({p₀ … pₙ₋₁})            = n          a run inlined counts its length
//   item({p₀ … pₙ₋₁}, i)           = pᵢ         i known, no run of a length not known before it
//   drop({p₀ … pₙ₋₁}, j)           = {pⱼ … pₙ₋₁}
//   drop(l, 0) = l     drop(drop(l, a), b) = drop(l, a + b)     item(drop(l, a), i) = item(l, a + i)
//   length(drop(l, a)) = length(l) - a
//
// and on a fold that builds a run, a state y ↦ {...y e₁ … e_k} from c:
//
//   length = length(c) + k · n,     n its steps: a fold of its own
//   item(·, i) = e₁ at step i,      k = 1, c = {}: e₁ where the index is its point i

// length_law: length(t).
length_law :: proc(k: ^Kernel, t: Type) -> Type {
	#partial switch v in t {
	case ^Scope:
		total: Type = Int(0)
		for b in placed(k, v, .Value) {
			switch {
			case b.kind == .Expand:
				total = op(k, .Add, total, length_law(k, given(k, binding_type(k, b))))
			case b.kind == .Push && b.name == "":
				total = op(k, .Add, total, Int(1))
			}
		}
		return total
	case ^Operation:
		if v.op == .Drop do return op(k, .Sub, length_law(k, v.args[0]), v.args[1])
	case ^Fold:
		if j, appended, ok := appending(k, v); ok {
			// a fold of its own: the length, from that of c, k more at each step
			f := new(Fold)
			f^ = v^
			l := new_unknown(k, nil)
			l.layout = COUNTS
			f.states = []^Unknown{l}
			f.inits = []Type{length_law(k, v.inits[j])}
			f.updates = []Type{op(k, .Add, l, Int(i128(len(appended))))}
			f.value, f.effects = l, None{}
			return folded(k, f)
		}
	}
	return new_operation(.Length, t)
}

// item_law: item(t, i).
item_law :: proc(k: ^Kernel, t, i: Type) -> Type {
	#partial switch v in t {
	case ^Scope:
		n, known := i.(Int)
		if !known do break
		at: i128 = 0
		for b in placed(k, v, .Value) {
			if b.kind == .Expand do break // a run of a length not known before it
			if b.kind != .Push || b.name != "" do continue
			if at == i128(n) do return binding_value(k, b)
			at += 1
		}
	case ^Operation:
		if v.op == .Drop do return item_law(k, v.args[0], op(k, .Add, v.args[1], i))
	case ^Fold:
		j, appended, ok := appending(k, v)
		if !ok || len(appended) != 1 do break
		if empty, is_scope := v.inits[j].(^Scope); !is_scope || len(placed(k, empty, .Value)) != 0 do break
		// the place i is what the step i appended: the index at its point i
		step := new_unknown(k, nil)
		step.layout = COUNTS
		point, closed := orbit(k, v.next, v.index, v.start, step)
		if !closed do break
		at := rewrite(k, point, rewriting(nil, step, i))
		return rewrite(k, appended[0], rewriting(nil, v.index, at))
	}
	return new_operation(.Item, t, i)
}

// drop_law: drop(t, n).
drop_law :: proc(k: ^Kernel, t, n: Type) -> Type {
	if m, known := n.(Int); known && m == 0 do return t
	#partial switch v in t {
	case ^Scope:
		m, known := n.(Int)
		if !known do break
		xs := placed(k, v, .Value)
		at: i128 = 0
		for b, j in xs {
			if b.kind == .Expand do break
			if b.kind != .Push || b.name != "" do continue
			if at == i128(m) do return run_scope(k, xs[j:])
			at += 1
		}
		if at == i128(m) do return run_scope(k, nil)
	case ^Operation:
		if v.op == .Drop do return drop_law(k, v.args[0], op(k, .Add, v.args[1], n))
	}
	return new_operation(.Drop, t, n)
}

// appending: f, a fold whose value is a state y each step of which appends to it,
// y ↦ {...y e₁ … e_k}: y, and the e.
appending :: proc(k: ^Kernel, f: ^Fold) -> (state: int, appended: []Type, ok: bool) {
	y, is_state := f.value.(^Unknown)
	if !is_state || has_effect(f.effects) do return
	for x, j in f.states {
		if !same_unknown(x, y) do continue
		update, is_scope := f.updates[j].(^Scope)
		if !is_scope do return
		xs := placed(k, update, .Value)
		if len(xs) == 0 || xs[0].kind != .Expand do return
		if head, is_y := given(k, binding_type(k, xs[0])).(^Unknown); !is_y || !same_unknown(head, y) do return
		out := make([dynamic]Type)
		for b in xs[1:] {
			if b.kind != .Push || b.name != "" do return
			append(&out, given(k, binding_type(k, b)))
		}
		return j, out[:], true
	}
	return
}

// run_values: the runs t may be: its values; an unknown a branch narrowed, the
// runs its type admits, which hold them.
run_values :: proc(k: ^Kernel, t: Type) -> (Type, bool) {
	set, ok := values(k, t)
	if ok && is_scope_set(set) do return set, true
	// narrowed by a branch, L & S: the runs of L hold them
	if ok {
		if runs, found := narrowed_runs(set); found do return runs, true
	}
	if u, is_unknown := t.(^Unknown); is_unknown && u.written != nil {
		written := normal(k, u.written)
		if is_scope_set(written) do return written, true
	}
	return nil, false
}

// run_element: what the places of the run t hold: the colors of the pieces it
// repeats, by Arden.
run_element :: proc(k: ^Kernel, t: Type) -> (Type, bool) {
	set, ok := run_values(k, t)
	if !ok do return nil, false
	pieces, _, repeated := run_pieces(k, set)
	if !repeated do return nil, false
	shape, is_scope := pieces.(^Scope)
	if !is_scope do return nil, false
	places := placed(k, shape, .Shape)
	if len(places) != 1 do return nil, false
	color := binding_color(k, places[0])
	return color, color != nil
}

// narrowed_runs: in t, a & of sets, its first term that is a set of scopes.
narrowed_runs :: proc(t: Type) -> (Type, bool) {
	and, is_and := t.(^And)
	if !is_and do return nil, false
	for term in and.terms {
		if is_scope_set(term) do return term, true
		if inner, found := narrowed_runs(term); found do return inner, true
	}
	return nil, false
}
