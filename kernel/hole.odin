package kernel

import syn "../compiler"
import "core:fmt"
import "core:strings"

// HOLE INFERENCE
//
// A hole (`T <- d`) that the carve does not fill receives its value from the carve
// (specs/language/14). What lands in its place — where it is written in the color
// of a field that the carve fills, or in the value that this field had — is of two
// kinds:
//
// - a sent value: it reads in a wider type without changing meaning;
// - a required type: the color of what the carve provides, or the `<-` filling.
//   It does not read wider: that would be admitting what it refuses.
//
// The hole takes the one that contains all the others, never their union. If there
// are required types, they are all the same, and each sent value is in it.
// Otherwise, one of the sent values contains all the others. The color of the hole
// then applies, as to any binding.
//
// To know what lands where, we type a probe: a copy of the target where each hole
// is an unknown. A color or a value that writes the hole then carries it in its
// type, at the very place where the carve puts something.

Landing :: struct {
	type:     ^Expr,
	required: bool,
}

Probe :: struct {
	holes:   map[^Var]int, // the variable of the probe → the index of the hole
	landed:  [][dynamic]Landing, // per binding of the target: what lands in its place
	blocked: bool, // a hole written in an operation: we do not know what lands there
}

// infer_holes: the value of each hole of `derived` that the carve determines.
// `targets`: for each argument, the binding it fills (fill).
infer_holes :: proc(k: ^Kernel, s: ^Scope, c: Carve, derived: ^Scope, targets: []int) {
	if !has_hole(s) do return
	p := probe(k, s, c, targets)
	if p.blocked {
		invalid := report(k, .Unsupported, c.span, "not in the kernel yet: a hole written in an operation")
		// a hole we cannot infer: what depends on it stays silent
		for &b in derived.bindings {
			if b.kind != .Pull do continue
			if filled, is_carved := b.value^.(Carved); is_carved && filled.args == c.args do continue
			b.value = invalid
		}
		return
	}
	for &b, j in derived.bindings {
		if b.kind != .Pull || len(p.landed[j]) == 0 do continue
		t, settled := settle(k, p.landed[j][:], &b, c.span)
		if !settled do continue
		// filled by `<-`: it keeps this filling, which the rest confirmed
		if filled, is_carved := b.value^.(Carved); is_carved && filled.args == c.args do continue
		b.value = new_expr(Inferred{c.args, t})
	}
}

has_hole :: proc(s: ^Scope) -> bool {
	for b in s.bindings do if b.kind == .Pull do return true
	return false
}

// probe: what lands in the place of each hole. The probe is typed silently, and
// nothing it types is checked: only its shape counts.
probe :: proc(k: ^Kernel, s: ^Scope, c: Carve, targets: []int) -> (p: Probe) {
	previous := k.scene
	k.scene = {quiet = true}
	typed := len(k.typed)
	defer {
		resize(&k.typed, typed)
		k.scene = previous
	}

	p.landed = make([][dynamic]Landing, len(s.bindings))
	target := copy_scope(s, s.parent, k.scene.site)
	for &b, j in target.bindings {
		if b.kind != .Pull do continue
		sym := new_symbol(k, set_top())
		p.holes[sym.(^Var)] = j
		b.value = sym
	}
	type_scope(k, target, s.shape)

	// the arguments, typed apart: those of the carve will be typed with the color
	// of the binding they replace, which can depend on a hole not yet inferred
	args := copy_scope(c.args, c.args.parent, c.args.site)
	args.carving = s
	unread := make([]bool, len(s.bindings)) // a carved field that the probe could not type
	for &a, i in args.bindings {
		j := targets[i]
		if j < 0 do continue
		type_binding(k, &a, args, nil)
		if is_invalid(a.value_type) do continue
		if a.kind == .Pull {
			append(&p.landed[j], Landing{a.value_type, true})
			continue
		}
		b := &target.bindings[j]
		sent := Landing{a.value_type, false}
		if b.color != nil {
			color := type_of(k, b.color, target)
			unread[j] |= is_invalid(color)
			land(k, &p, color, sent)
		}
		if b.value != nil {
			unread[j] |= is_invalid(b.value_type)
			land(k, &p, b.value_type, sent)
		}
	}
	// A field that depends on a hole, and that the probe could not type: we do not
	// know what lands in the place of the hole. The dependencies are read like those
	// of a carve, the holes standing for what changes — once the probe is typed,
	// since a changed binding is no longer typed silently.
	for &b in target.bindings do if b.kind == .Pull do b.copy = .Changed
	mark_changes(target, nil, {})
	for b, j in target.bindings do if unread[j] && b.copy == .Changed do p.blocked = true
	return
}

// land: `pattern`, a type of the probe, receives `at`; each hole it writes receives
// the part of `at` that is in its place. In a scope, the color of a field receives
// the color of the corresponding field if it has one (a required type), otherwise
// its value; the value of a field receives the value.
land :: proc(k: ^Kernel, p: ^Probe, pattern: ^Expr, at: Landing) {
	if pattern == nil || is_invalid(pattern) || at.type == nil || is_invalid(at.type) do return
	#partial switch v in pattern^ {
	case ^Var:
		if j, is_hole := p.holes[v]; is_hole {
			append(&p.landed[j], at)
			return
		}
	case ^Scope:
		// a scope with productions admits what its productions admit, not its
		// structure: we do not know yet what lands there
		if first_production(v) != nil {
			if scope_mentions(p, v) do p.blocked = true
			return
		}
		w, is_scope := at.type^.(^Scope)
		if !is_scope || !same_bindings(v, w) do return // the check of the field reports it
		vs, ws := places(v), places(w)
		for vp, i in vs {
			vb, wb := binding_at(vp)^, binding_at(ws[i])^
			if vb.color != nil {
				inner := wb.color != nil ? Landing{wb.color_type, true} : Landing{wb.value_type, at.required}
				land(k, p, type_of(k, vb.color, vp.scope), inner)
			}
			if vb.value != nil do land(k, p, vb.value_type, Landing{wb.value_type, at.required})
		}
		return
	}
	if mentions(p, pattern) do p.blocked = true
}

// scope_mentions: a binding of the scope, at whatever depth, depends on a hole of
// the probe.
scope_mentions :: proc(p: ^Probe, s: ^Scope) -> bool {
	for b in s.bindings {
		for t in ([2]^Expr{b.color_type, b.value_type}) {
			if t == nil do continue
			if inner, is_scope := t^.(^Scope); is_scope && scope_mentions(p, inner) do return true
			if mentions(p, t) do return true
		}
	}
	return false
}

// same_bindings: they present the same bindings — names and kinds, in order.
same_bindings :: proc(a, b: ^Scope) -> bool {
	x, y := places(a), places(b)
	if len(x) != len(y) do return false
	for p, i in x do if binding_at(p).name != binding_at(y[i]).name || binding_at(p).kind != binding_at(y[i]).kind do return false
	return true
}

// mentions: the type depends on a hole of the probe.
mentions :: proc(p: ^Probe, t: ^Expr) -> bool {
	if t == nil do return false
	#partial switch v in t^ {
	case ^Var:
		return v in p.holes
	case Term:
		for a in v.args do if mentions(p, a) do return true
	case Poly:
		for m in v.monos do for x in m.vars do if x in p.holes || (derived(x) && mentions(p, x.type)) do return true
	case Set_Form:
		for a in v.args do if mentions(p, a) do return true
	case Cases:
		for c in v.cases do if mentions(p, c.value) do return true
	}
	return false
}

// settle: does what landed in the place of the hole `b` designate a value, the one
// that contains all the others? Otherwise, the error, at the carve.
settle :: proc(k: ^Kernel, landed: []Landing, b: ^Binding, span: syn.Span) -> (^Expr, bool) {
	required: ^Expr = nil
	required_set: Set
	for l in landed {
		if !l.required do continue
		set, closed := color_set(k, l.type)
		if !closed {
			report(k, .Unsupported, span, fmt.tprintf("not in the kernel yet: %s required by %s", brief(l.type), display(b)))
			return nil, false
		}
		if required == nil {
			required, required_set = l.type, set
			continue
		}
		if !set_equal(set, required_set) {
			report(k, .Constraint_Mismatch, span, fmt.tprintf("%s requires both %s and %s", display(b), brief(required), brief(l.type)))
			return nil, false
		}
	}
	if required != nil {
		for l in landed {
			if l.required do continue
			switch admits(k, required_set, l.type) {
			case .Proved:
			case .Refuted:
				report(k, .Constraint_Mismatch, span, fmt.tprintf("%s ∉ %s, which %s requires", brief(l.type), brief(required), display(b)))
				return nil, false
			case .Undecided:
				report(k, .Unproven, span, fmt.tprintf("%s ∈ %s, which %s requires, could not be proved", brief(l.type), brief(required), display(b)))
				return nil, false
			}
		}
		return required, true
	}
	// only sent values: one of them contains all the others
	candidates: for candidate in landed {
		set, closed := exact_set(k, candidate.type)
		if !closed do continue
		for l in landed do if admits(k, set, l.type) != .Proved do continue candidates
		return candidate.type, true
	}
	report(k, .Constraint_Mismatch, span, fmt.tprintf("none of the values received by %s contains the others: %s", display(b), listed_types(landed)))
	return nil, false
}

listed_types :: proc(landed: []Landing) -> string {
	parts := make([dynamic]string, context.temp_allocator)
	for l in landed do append(&parts, brief(l.type))
	return strings.join(parts[:], ", ")
}
