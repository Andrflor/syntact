package compiler
// unify_pull resolves PULL variables by matching a field's CONSTRAINT (which may
// mention pulls, e.g. `data{e}`) against the VALUE supplied for that field (e.g.
// `data{6}`), and writes the resolved value into the pull's binding in `copy`. It
// descends structurally:
//   * constraint is a Mention of a PULL binding (kind .Pointing_Pull) in `src`
//     → bind that pull to `value` (write into copy at the pull's index).
//   * both are carves of the same source → unify override-by-override (the slot a
//     constraint override targets is matched to the value override at the same slot).
//   * both are scopes → unify field-by-field by position.
// `src` is the original (pre-clone) scope, used to recognize a mention as a pull
// and to map its index into `copy` (same column order).
unify_pull :: proc(constraint, value: ^Type, copy, src: ^Scope_Type) {
	if constraint == nil || value == nil do return

	// A mention of a pull on the constraint side: bind it to the value.
	if m, ok := constraint^.(Mention_Type); ok {
		if m.match_scope == src && m.match_index >= 0 && m.match_index < len(copy.kind) {
			if copy.kind[m.match_index] == .Pointing_Pull {
				copy.types[m.match_index] = value
				if m.match_index < len(copy.type_folds) {
					copy.type_folds[m.match_index] = fold_value_type(value)
				}
			}
		}
		return
	}

	// Two carves: unify each constraint override against the value override that
	// targets the same source slot.
	if cc, c_ok := &constraint^.(Carve_Type); c_ok {
		vc, v_ok := &value^.(Carve_Type)
		if v_ok {
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

// Pull_Conflict reports a pull bound to two incompatible values within one carve
// (`a{data{6} data{3}}` → e gets 6 then 3). The analyzer turns it into an error.
Pull_Conflict :: struct {
	pull_name: string,
	first:     ^Type,
	second:    ^Type,
}

// carve_pull_conflict re-runs the pull unification of a carve in DETECTION mode:
// it gathers, per pull, every value the overrides bind it to (via the same
// structural matching as unify_pull), and returns the first pull bound to two
// values whose folds differ. Pure — the analyzer (walk_carve) emits the error.
carve_pull_conflict :: proc(t: ^Type) -> (Pull_Conflict, bool) {
	carve, ok := &t^.(Carve_Type)
	if !ok do return {}, false

	src: ^Scope_Type = nil
	cur := follow(carve.source)
	for cur != nil {
		#partial switch &s in cur^ {
		case Scope_Type:
			src = &s
		case Carve_Type:
			src = fold_carve(cur)
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
		f0 := fold_value_type(vals[0])
		for k in 1 ..< len(vals) {
			fk := fold_value_type(vals[k])
			if !pull_values_agree(f0, fk) {
				name := idx < len(src.names) ? src.names[idx] : ""
				return Pull_Conflict{name, vals[0], vals[k]}, true
			}
		}
	}
	return {}, false
}

// pull_values_agree : two bound values are compatible iff each satisfies the
// other's set (mutual subset = same singleton, the only safe agreement here).
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
