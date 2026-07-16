package compiler

// unify_pull resolves PULL variables by matching a field's CONSTRAINT (which may
// mention pulls, e.g. `data{e}`) against the VALUE supplied (e.g. `data{6}`), and
// writes the resolved value into the pull's binding in `copy`. Descends structurally:
// a pull mention binds to the value; two carves unify override-by-override (matched
// slot); two scopes field-by-field. `src` is the pre-clone scope, used to recognize
// a pull and map its index into `copy`.
unify_pull :: proc(constraint, value: ^Type, copy, src: ^Scope_Type) {
	if constraint == nil || value == nil do return

	// A mention of a pull on the constraint side: bind it to the value.
	if m, ok := constraint^.(Mention_Type); ok {
		if m.match_scope == src && m.match_index >= 0 && m.match_index < len(copy.kind) {
			if copy.kind[m.match_index] == .Pointing_Pull {
				copy.types[m.match_index] = value
				if m.match_index < len(copy.type_folds) {
					copy.type_folds[m.match_index] = fold_type(value)
				}
			}
		}
		return
	}

	// A CARVE constraint. Two shapes of value:
	//  - another CARVE (`data{e}` proven by `data{6}`): unify override-by-override on
	//    the matched source slot.
	//  - a SCOPE value (`Array{T}:source` proven by `source -> {2 3 4 5}`): unroll the
	//    carve's grammar (`{T: ...Array{T}:}`) against the value run and JOIN every
	//    element landing on a pull-colored position into that pull (`T = 2|3|4|5`).
	//    This is the one rule that composes with a recursive list of variable length.
	if cc, c_ok := &constraint^.(Carve_Type); c_ok {
		if vc, v_ok := &value^.(Carve_Type); v_ok {
			for ci in 0 ..< len(cc.references) {
				slot := cc.references[ci].match_index
				// find the value override hitting the same slot
				for vi in 0 ..< len(vc.references) {
					if vc.references[vi].match_index == slot {
						unify_pull(cc.types[ci], vc.types[vi], copy, src)
						break
					}
				}
			}
		} else if vs, vs_ok := &value^.(Scope_Type); vs_ok {
			unify_pull_carve_scope(cc, vs^, copy, src)
		}
		return
	}

	// Two scopes: unify field-by-field by position.
	if cs, c_ok := &constraint^.(Scope_Type); c_ok {
		if vs, v_ok := &value^.(Scope_Type); v_ok {
			n := min(len(cs.types), len(vs.types))
			for i in 0 ..< n {
				unify_pull(cs.types[i], vs.types[i], copy, src)
			}
		}
	}
}

// carve_param_to_pull builds the map from a source-scope parameter index (in the
// carve's SOURCE, e.g. `Array`'s `T`) to the pull binding it is carved to — reading
// each override `Array{T -> a.T_pull}`: the parameter `references[i].match_index`
// is bound to the pull `copy.kind[...] == Pointing_Pull` that `types[i]` mentions.
carve_param_to_pull :: proc(cc: ^Carve_Type, copy, src: ^Scope_Type) -> map[int]int {
	out := make(map[int]int)
	for i in 0 ..< len(cc.references) {
		arg := cc.types[i]
		if arg == nil do continue
		m, ok := arg^.(Mention_Type)
		if !ok do continue
		if (m.match_scope == src || m.match_scope == copy) &&
		   m.match_index >= 0 && m.match_index < len(copy.kind) &&
		   copy.kind[m.match_index] == .Pointing_Pull {
			out[cc.references[i].match_index] = m.match_index
		}
	}
	return out
}

// unify_pull_carve_scope unrolls the carve's grammar (`Array{T}` → `{T: ...Array{T}:}`)
// against the value run `vs` and joins every element consuming a position colored by a
// pull into that pull. Mirror of scope_satisfy_range/expand_satisfies in COLLECT mode
// (as gather_pull_bindings mirrors unify_pull). Resolves the source grammar scope, then
// drives its cons production over the value elements.
unify_pull_carve_scope :: proc(cc: ^Carve_Type, vs: Scope_Type, copy, src: ^Scope_Type) {
	if cc.source == nil do return
	// Resolve the grammar scope the carve materializes over (Array's body).
	grammar := fold_constraint(cc.source)
	if grammar == nil do return
	if rec, is_rec := grammar^.(Recursive_Mention_Type); is_rec {
		grammar = fold_constraint_target(rec.match_scope, rec.match_index)
	}
	gs, ok := &grammar^.(Scope_Type)
	if !ok do return

	param_to_pull := carve_param_to_pull(cc, copy, src)
	if len(param_to_pull) == 0 do return

	// Accumulate, per pull binding, the join of every value landing on it.
	joined := make(map[int]^Type)
	elems := value_elements(vs)
	collect_pull_over_grammar(gs, elems[:], 0, len(elems), &param_to_pull, &joined)

	for pull_idx, val in joined {
		if pull_idx < 0 || pull_idx >= len(copy.kind) do continue
		if copy.kind[pull_idx] != .Pointing_Pull do continue
		copy.types[pull_idx] = val
		if pull_idx < len(copy.type_folds) {
			copy.type_folds[pull_idx] = fold_type(val)
		}
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

// Pull_Conflict reports a pull bound to two incompatible values within one carve
// (`a{data{6} data{3}}` → e gets 6 then 3). The analyzer turns it into an error.
Pull_Conflict :: struct {
	pull_name: string,
	first:     ^Type,
	second:    ^Type,
}

// carve_pull_conflict re-runs the pull unification in DETECTION mode: gathers, per
// pull, every value the overrides bind it to, and returns the first pull bound to
// two differing values. Pure — walk_carve emits the error.
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
	for i in 0 ..< len(carve.references) {
		ref := carve.references[i]
		if ref.match_index < 0 || ref.match_index >= len(src.kind) do continue
		// A direct override of the pull binding itself (`e<-4`) is a binding too.
		if src.kind[ref.match_index] == .Pointing_Pull {
			list := bound[ref.match_index] or_else make([dynamic]^Type)
			append(&list, carve.types[i])
			bound[ref.match_index] = list
			continue
		}
		// An override of a field whose constraint mentions a pull (`data{e}:s`).
		if ref.match_index < len(src.constraints) {
			gather_pull_bindings(src.constraints[ref.match_index], carve.types[i], src, &bound)
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

// gather_pull_bindings mirrors unify_pull but COLLECTS (constraint mention of a
// pull → append the value to that pull's list) instead of writing.
gather_pull_bindings :: proc(
	constraint, value: ^Type,
	src: ^Scope_Type,
	bound: ^map[int][dynamic]^Type,
) {
	if constraint == nil || value == nil do return
	if m, ok := constraint^.(Mention_Type); ok {
		if m.match_scope == src && m.match_index >= 0 && m.match_index < len(src.kind) {
			if src.kind[m.match_index] == .Pointing_Pull {
				list := bound[m.match_index] or_else make([dynamic]^Type)
				append(&list, value)
				bound[m.match_index] = list
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
						gather_pull_bindings(cc.types[ci], vc.types[vi], src, bound)
						break
					}
				}
			}
		}
		return
	}
	if cs, c_ok := &constraint^.(Scope_Type); c_ok {
		if vs, v_ok := &value^.(Scope_Type); v_ok {
			n := min(len(cs.types), len(vs.types))
			for i in 0 ..< n {
				gather_pull_bindings(cs.types[i], vs.types[i], src, bound)
			}
		}
	}
}
