package kernel

import "core:fmt"

// THE CHECK (specs/types.md §7)
//
//   C:x -> V    ⟺    V in C = true
//
// Every binding of a frame is typed; a colored one is checked. Its value is in its
// color when `V in C` is true; when it is false, the value is not; otherwise the
// kernel cannot decide (Unproven).

//
// A production is lazy: it is typed when it is asked for (a collapse, a default,
// a color that reads the scope), not where it is written. A carved frame is
// checked at its carve, and only in what the carve changed: the rest was checked
// in its source.
check_frame :: proc(k: ^Kernel, f: ^Frame) {
	previous := k.site
	k.site = f.site
	defer k.site = previous
	first_production := true
	for b, i in f.scope.bindings {
		if b.kind == .Product && first_production && f.source == nil && f.shape == nil {
			// a definition is typed along its default: its first production, the base case
			first_production = false
			value_type(k, f, i)
			continue
		}
		if b.kind == .Product || b.kind == .Expand do continue
		v := value_type(k, f, i)
		c := color_type(k, f, i)
		if c == nil || is_invalid(c) || is_invalid(v) do continue
		if f.source != nil && type_same(k, v, value_type(k, f.source, i)) && type_same(k, c, color_type(k, f.source, i)) do continue
		r := type_in(k, v, c)
		if is_invalid(r) do continue
		switch verdict, counterexample := decide(r); verdict {
		case .True:
		case .False:
			when_ := counterexample == "" ? "" : fmt.tprintf(" when %s", counterexample)
			report(k, .Constraint_Mismatch, b.span, fmt.tprintf("%s is not an element of %s%s", print_type(v), print_type(c), when_))
		case .Undecided:
			report(k, .Unproven, b.span, fmt.tprintf("cannot decide whether %s is in %s", print_type(v), print_type(c)))
		}
	}
}
