package kernel

import "core:fmt"

// THE CHECK (specs/types.md §7)
//
//   C:x -> V    ⟺    V in C = true
//
// Each colored binding of a frame is checked: `V in C` must be proven, from what
// is known where the binding is written (prove.odin). What is not proven is
// refused.
//
// A production is typed when it is asked; a definition is typed along its base
// case, its first production. A carved frame is checked at its carve, in what the
// carve changed: the rest was checked in its source.
check_frame :: proc(k: ^Kernel, f: ^Frame) {
	outer_site, outer_facts := k.site, k.facts
	k.site, k.facts = f.site, f.facts
	defer k.site, k.facts = outer_site, outer_facts
	first_production := true
	for b, i in f.scope.bindings {
		if b.kind == .Product && first_production && f.source == nil && f.shape == nil {
			first_production = false
			if g, is_frame := value_type(k, f, i).(^Frame); is_frame do frame_slots(k, g) // the base case, as a value
			continue
		}
		if b.kind == .Product || b.kind == .Expand do continue
		v := value_type(k, f, i)
		c := color_type(k, f, i)
		if c == nil || is_invalid(c) || is_invalid(v) do continue
		if f.source != nil && same(k, v, value_type(k, f.source, i)) && same(k, c, color_type(k, f.source, i)) do continue
		r := type_in(k, v, c)
		if is_invalid(r) do continue
		switch prove(k, r) {
		case .Proven:
		case .Refuted:
			report(k, .Constraint_Mismatch, b.span, fmt.tprintf("%s is not in %s", print_type(v), print_type(c)))
		case .Unproven:
			report(k, .Constraint_Mismatch, b.span, fmt.tprintf("not proven that %s is in %s", print_type(v), print_type(c)))
		}
	}
}
