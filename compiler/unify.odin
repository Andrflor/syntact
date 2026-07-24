package compiler

// PULL UNIFICATION — one structural traversal, three consumers.
//
// The walk matches a field's CONSTRAINT (which may mention pulls, e.g. `data{e}`)
// against the VALUE supplied (e.g. `data{6}`) and reports every (pull, value)
// binding it discovers to a SINK:
//   * a pull mention on the constraint side binds to the value;
//   * two carves unify override-by-override on the matched source slot;
//   * a SCOPE value against a grammar carve (`Array{T}:source` proven by
//     `{2 3 4 5}`) unrolls the grammar and JOINS every element landing on a
//     pull-colored position (`T = 2|3|4|5`) — the one rule that composes with a
//     recursive list of variable length;
//   * two scopes unify field-by-field by position.
// The sink decides what a binding IS: the analyzer writes it into the clone and
// refolds; reduce writes and INVALIDATES the fold (reduce must not re-enter the
// analyzer-only fold layer); conflict detection only collects.

// Pull_Sink receives each discovered (pull index, value) binding.
Pull_Sink :: struct {
	ctx:  rawptr,
	bind: proc(ctx: rawptr, pull_idx: int, value: ^Type),
}

Pull_Walk_Opts :: struct {
	// resolve_values: reduce-side pre-resolution — a mention/reference/collapse
	// value resolves to its reduced structure on demand (a recursive carve passes
	// the cover capture `r`, a mention of the destructured tail scope).
	resolve_values: bool,
	// unroll_grammar: drive a grammar carve over a scope value's run (the join
	// rule above). Conflict DETECTION leaves it off — it only compares what the
	// overrides bind directly.
	unroll_grammar: bool,
}

// pull_walk is the shared traversal. `src` is the pre-clone scope pull mentions
// resolve against; `kinds` is the scope whose binding kinds identify a pull (the
// clone for substitution, `src` itself for detection — clones share kinds).
pull_walk :: proc(
	constraint, value: ^Type,
	src: ^Scope_Type,
	kinds: ^Scope_Type,
	sink: Pull_Sink,
	opts: Pull_Walk_Opts,
) {
	if constraint == nil || value == nil do return

	value := value
	if opts.resolve_values {
		#partial switch _ in value^ {
		case Mention_Type, Reference_Type, Execute_Type:
			value = reduce_value(value)
			if value == nil do return
		}
	}

	// A mention of a pull on the constraint side: bind it to the value.
	if m, ok := constraint^.(Mention_Type); ok {
		if m.match_scope == src && m.match_index >= 0 && m.match_index < len(kinds.kind) {
			if kinds.kind[m.match_index] == .Pointing_Pull {
				sink.bind(sink.ctx, m.match_index, value)
			}
		}
		return
	}

	if cc, c_ok := &constraint^.(Carve_Type); c_ok {
		if vc, v_ok := &value^.(Carve_Type); v_ok {
			for ci in 0 ..< len(cc.references) {
				slot := cc.references[ci].match_index
				for vi in 0 ..< len(vc.references) {
					if vc.references[vi].match_index == slot {
						pull_walk(cc.types[ci], vc.types[vi], src, kinds, sink, opts)
						break
					}
				}
			}
		} else if vs, vs_ok := &value^.(Scope_Type); vs_ok && opts.unroll_grammar {
			unify_pull_carve_scope(cc, vs^, src, kinds, sink)
		}
		return
	}

	// Two scopes: unify field-by-field by position.
	if cs, c_ok := &constraint^.(Scope_Type); c_ok {
		if vs, v_ok := &value^.(Scope_Type); v_ok {
			n := min(len(cs.types), len(vs.types))
			for i in 0 ..< n {
				pull_walk(cs.types[i], vs.types[i], src, kinds, sink, opts)
			}
		}
	}
}

// --- the two writing sinks (carve substitution) ---

Pull_Write_Ctx :: struct {
	copy:   ^Scope_Type,
	refold: bool, // analyzer path refolds; reduce invalidates instead
}

pull_write_bind :: proc(ctx: rawptr, pull_idx: int, value: ^Type) {
	w := cast(^Pull_Write_Ctx)ctx
	if pull_idx < 0 || pull_idx >= len(w.copy.kind) do return
	if w.copy.kind[pull_idx] != .Pointing_Pull do return
	w.copy.types[pull_idx] = value
	if pull_idx < len(w.copy.type_folds) {
		w.copy.type_folds[pull_idx] = w.refold ? fold_type(value) : nil
	}
}

// unify_pull resolves pull variables during the ANALYZER's carve substitution,
// writing each binding into `copy` and refreshing its fold.
unify_pull :: proc(constraint, value: ^Type, copy, src: ^Scope_Type) {
	w := Pull_Write_Ctx{copy, true}
	pull_walk(
		constraint,
		value,
		src,
		copy,
		Pull_Sink{&w, pull_write_bind},
		Pull_Walk_Opts{resolve_values = false, unroll_grammar = true},
	)
}

// reduce_unify_pull is the reduce-side twin: values pre-resolve through
// reduce_value, and folds are invalidated instead of recomputed.
reduce_unify_pull :: proc(constraint, value: ^Type, copy, src: ^Scope_Type) {
	w := Pull_Write_Ctx{copy, false}
	pull_walk(
		constraint,
		value,
		src,
		copy,
		Pull_Sink{&w, pull_write_bind},
		Pull_Walk_Opts{resolve_values = true, unroll_grammar = true},
	)
}

// carve_param_to_pull builds the map from a source-scope parameter index (in the
// carve's SOURCE, e.g. `Array`'s `T`) to the pull binding it is carved to — reading
// each override `Array{T -> a.T_pull}`: the parameter `references[i].match_index`
// is bound to the pull `kinds.kind[...] == Pointing_Pull` that `types[i]` mentions.
carve_param_to_pull :: proc(cc: ^Carve_Type, src, kinds: ^Scope_Type) -> map[int]int {
	out := make(map[int]int)
	for i in 0 ..< len(cc.references) {
		arg := cc.types[i]
		if arg == nil do continue
		m, ok := arg^.(Mention_Type)
		if !ok do continue
		if (m.match_scope == src || m.match_scope == kinds) &&
		   m.match_index >= 0 && m.match_index < len(kinds.kind) &&
		   kinds.kind[m.match_index] == .Pointing_Pull {
			out[cc.references[i].match_index] = m.match_index
		}
	}
	return out
}

// unify_pull_carve_scope unrolls the carve's grammar (`Array{T}` → `{T: ...Array{T}:}`)
// against the value run `vs` and reports every element consuming a pull-colored
// position to the sink, JOINED per pull (`T = 2|3|4|5`). Mirror of
// scope_satisfy_range/expand_satisfies in collect mode.
unify_pull_carve_scope :: proc(
	cc: ^Carve_Type,
	vs: Scope_Type,
	src, kinds: ^Scope_Type,
	sink: Pull_Sink,
) {
	if cc.source == nil do return
	// Resolve the grammar scope the carve materializes over (Array's body).
	grammar := fold_constraint(cc.source)
	if grammar == nil do return
	if rec, is_rec := grammar^.(Recursive_Mention_Type); is_rec {
		grammar = fold_constraint_target(rec.match_scope, rec.match_index)
	}
	gs, ok := &grammar^.(Scope_Type)
	if !ok do return

	param_to_pull := carve_param_to_pull(cc, src, kinds)
	if len(param_to_pull) == 0 do return

	// Accumulate, per pull binding, the join of every value landing on it.
	joined := make(map[int]^Type)
	elems := value_elements(vs)
	collect_pull_over_grammar(gs, elems[:], 0, len(elems), &param_to_pull, &joined)

	for pull_idx, val in joined {
		sink.bind(sink.ctx, pull_idx, val)
	}
}

// collect_pull_over_grammar drives grammar scope `gs`'s productions over the value run
// `elems[vi..vend]`: the cons production (`{T: ...Array{T}:}`) consumes one element on
// its pull-colored head and recurses through its `...Array{T}:` tail; the empty terminal
// closes an exhausted run. Each element consumed by a pull-colored position is joined
// into that pull in `joined`. Pure collection — never proves, so a mismatch just stops.
collect_pull_over_grammar :: proc(
	gs: ^Scope_Type,
	elems: []^Type,
	vi, vend: int,
	param_to_pull: ^map[int]int,
	joined: ^map[int]^Type,
) {
	// Try the cons production: a scope production carrying an Expand.
	for i in 0 ..< len(gs.kind) {
		if gs.kind[i] != .Product do continue
		prod := gs.type_folds[i] != nil ? gs.type_folds[i] : gs.types[i]
		if prod == nil do continue
		ps, pok := &prod^.(Scope_Type)
		if !pok do continue
		if collect_pull_over_production(ps, elems, vi, vend, gs, param_to_pull, joined) {
			return
		}
	}
}

// collect_pull_over_production walks one production's fields (`T:` then `...Array{T}:`)
// against the run. A non-expand field consumes one element; if it is colored by a pull
// (its constraint is a mention of a grammar parameter mapped to a pull), the element is
// joined into that pull. An Expand recurses into the grammar over the leftover run. The
// bool reports whether this production consumed the whole run (so the caller stops).
collect_pull_over_production :: proc(
	ps: ^Scope_Type,
	elems: []^Type,
	vi, vend: int,
	gs: ^Scope_Type,
	param_to_pull: ^map[int]int,
	joined: ^map[int]^Type,
) -> bool {
	cur := vi
	for ci in 0 ..< len(ps.kind) {
		if ps.kind[ci] == .Expand {
			// The recursive tail (`...Array{T}:`) re-drives the SAME grammar over the rest.
			collect_pull_over_grammar(gs, elems, cur, vend, param_to_pull, joined)
			return true
		}
		if cur >= vend do return false // production wants more than the run has
		// A field colored by a grammar parameter mapped to a pull joins the element.
		if pull_idx, is_pull := production_field_pull(ps, ci, gs, param_to_pull); is_pull {
			join_into(joined, pull_idx, elems[cur])
		}
		cur += 1
	}
	return cur == vend
}

// production_field_pull reports the pull a production field is colored by, if any:
// the field's constraint is a mention of a grammar parameter present in param_to_pull.
production_field_pull :: proc(
	ps: ^Scope_Type,
	ci: int,
	gs: ^Scope_Type,
	param_to_pull: ^map[int]int,
) -> (int, bool) {
	if ci >= len(ps.constraints) do return 0, false
	c := ps.constraints[ci]
	if c == nil do return 0, false
	m, ok := c^.(Mention_Type)
	if !ok do return 0, false
	if m.match_scope != gs do return 0, false
	if pull_idx, has := param_to_pull[m.match_index]; has {
		return pull_idx, true
	}
	return 0, false
}

// join_into accumulates `val` into pull `idx`'s running join (`T = 2|3|4|5`): the first
// value seeds it, each further value is an Or with the accumulator.
join_into :: proc(joined: ^map[int]^Type, idx: int, val: ^Type) {
	if val == nil do return
	if existing, has := joined[idx]; has {
		joined[idx] = new_type(Or_Type{existing, val})
	} else {
		joined[idx] = val
	}
}

// --- the collecting sink (conflict detection) ---

Pull_Conflict :: struct {
	pull_name: string,
	first:     ^Type,
	second:    ^Type,
}

pull_gather_bind :: proc(ctx: rawptr, pull_idx: int, value: ^Type) {
	bound := cast(^map[int][dynamic]^Type)ctx
	list := bound[pull_idx] or_else make([dynamic]^Type)
	append(&list, value)
	bound[pull_idx] = list
}

// carve_pull_conflict re-runs the pull unification in DETECTION mode: gathers, per
// pull, every value the overrides bind it to (`a{data{6} data{3}}` → e gets 6 then
// 3), and returns the first pull bound to two differing values. Pure — walk_carve
// emits the error. Grammar unrolling stays off: only direct bindings can conflict.
carve_pull_conflict :: proc(carve: ^Carve_Type) -> (Pull_Conflict, bool) {
	src: ^Scope_Type = nil
	cur := follow(carve.source)
	for cur != nil {
		#partial switch &s in cur^ {
		case Scope_Type:
			src = &s
		case Carve_Type:
			src = fold_carve_type(cur)
		}
		break
	}
	if src == nil do return {}, false

	// pull index → the values bound to it, in order.
	bound := make(map[int][dynamic]^Type)
	sink := Pull_Sink{&bound, pull_gather_bind}
	opts := Pull_Walk_Opts{resolve_values = false, unroll_grammar = false}
	for i in 0 ..< len(carve.references) {
		ref := carve.references[i]
		if ref.match_index < 0 || ref.match_index >= len(src.kind) do continue
		// A direct override of the pull binding itself (`e<-4`) is a binding too.
		if src.kind[ref.match_index] == .Pointing_Pull {
			pull_gather_bind(&bound, ref.match_index, carve.types[i])
			continue
		}
		// An override of a field whose constraint mentions a pull (`data{e}:s`).
		if ref.match_index < len(src.constraints) {
			pull_walk(src.constraints[ref.match_index], carve.types[i], src, src, sink, opts)
		}
	}

	for idx, vals in bound {
		if len(vals) < 2 do continue
		f0 := fold_type(vals[0])
		for k in 1 ..< len(vals) {
			fk := fold_type(vals[k])
			if !pull_values_agree(f0, fk) {
				name := idx < len(src.names) ? src.names[idx] : ""
				return Pull_Conflict{name, vals[0], vals[k]}, true
			}
		}
	}
	return {}, false
}

// pull_values_agree : two bound values agree iff mutual subset (the same singleton).
pull_values_agree :: proc(a, b: ^Type) -> bool {
	if a == nil || b == nil do return false
	return satisfy_root(a, b) && satisfy_root(b, a)
}
