package kernel

import "core:fmt"

// THE CHECK (specs/types.md §7)
//
//   C:x -> V    ⟺    V in C = true
//
// Every binding of a frame is typed; a colored one is checked. Its value is in its
// color when `V in C` is true; when it is false, the value is not; otherwise the
// kernel cannot decide (Unproven).

check_frame :: proc(k: ^Kernel, f: ^Frame) {
	for b, i in f.scope.bindings {
		v := value_type(k, f, i)
		c := color_type(k, f, i)
		if c == nil || is_invalid(c) || is_invalid(v) do continue
		r := type_in(v, c)
		switch {
		case is_bool(r, true), is_invalid(r):
		case is_bool(r, false):
			report(k, .Constraint_Mismatch, b.span, fmt.tprintf("%s is not an element of %s", print_type(v), print_type(c)))
		case:
			report(k, .Unproven, b.span, fmt.tprintf("cannot decide whether %s is in %s", print_type(v), print_type(c)))
		}
	}
}
