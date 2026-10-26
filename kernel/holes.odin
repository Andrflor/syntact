package kernel

import syn "../compiler"
import "core:fmt"

// HOLES (specs/types.md §5.7)
//
// `x <- v` is a hole: a binding the use site fills, with `<-`. Until it is filled
// it holds its default, like any binding. A carve that does not fill it infers it:
// what the carve puts where the hole is mentioned lands in it. The places are read
// on a copy of the scope where the hole is an unknown ?h — the color of each field
// the carve fills, or the value that field had —, set beside what the carve puts
// there:
//
//   - at the place of a value, a sent value;
//   - at the place of a color, a required type; a fill `x <- t` is one too.
//
// The hole takes the required type — every one the same, every sent value in it —,
// or else the sent value that holds all the others; never their union.

Landing :: struct {
	sent:     [dynamic]Type,
	required: [dynamic]Type,
}

Role :: enum u8 {
	Sent,
	Required,
}

// infer_holes: the holes of s that the carve infers, added to its changes; a
// problem when what lands in one does not agree.
infer_holes :: proc(k: ^Kernel, s: ^Scope, changes: ^map[^Binding]Type, span: syn.Span) -> Type {
	for h in s.bindings {
		if h.kind != .Pull do continue
		l: Landing
		if v, filled := changes[h]; filled do append(&l.required, v)
		u := marker(k, h.color)
		marked := make(map[^Binding]Type)
		marked[h] = u
		copy := copy_scope(k, s, marked)
		for f, i in s.bindings {
			v, carved := changes[f]
			if !carved || f.kind == .Pull do continue
			v = given(k, v) // what is sent is what the argument gives back (§4.8)
			place := copy.bindings[i]
			if f.color != nil {
				lands(k, binding_color(k, place), v, u, .Sent, &l)
			} else if f.value != nil {
				lands_template(k, binding_type(k, place), v, u, &l)
			}
		}
		value, p := settle(k, h, l, span)
		if p != nil do return p
		if value != nil do changes[h] = value
	}
	return nil
}

// marker: a fresh unknown that stands for a hole: one value of its color.
marker :: proc(k: ^Kernel, color: Type) -> ^Unknown {
	k.markers += 1
	u := new(Unknown)
	u.id, u.written = -k.markers, color
	return u
}

// lands: what lands in u when v is set at the place p: the term v itself where p is
// u; in a shape, binding by binding; in A * n, piece by piece.
lands :: proc(k: ^Kernel, p, v: Type, u: ^Unknown, role: Role, l: ^Landing) {
	if is_invalid(v) do return
	#partial switch x in p {
	case ^Unknown:
		if !same_unknown(x, u) do return
		append(role == .Sent ? &l.sent : &l.required, v)
	case ^Scope:
		value, is_scope := v.(^Scope)
		if !is_scope || role != .Sent do return
		shape := x
		if recursive(shape) {
			solution, solved := arden(k, shape)
			if !solved do return
			shape = solution
		}
		if !is_shape(k, shape) do return
		places := placed(k, shape, .Shape)
		xs := placed(k, value, .Value)
		lengths, decided, fits := run_lengths(k, xs, places)
		if !decided || !fits do return
		at := 0
		for place, i in places {
			part := xs[at:at + lengths[i]]
			at += lengths[i]
			if !is_run(place) {
				lands_binding(k, place, part[0], u, l)
			} else if place.color != nil {
				lands(k, binding_color(k, place), run_scope(k, part), u, .Sent, l)
			}
		}
	case ^Operation:
		a, is_shape := x.args[0].(^Scope)
		value, is_scope := v.(^Scope)
		if x.op != .Mul || !is_shape || !is_scope do return
		n, fixed := shape_length(k, a)
		xs := placed(k, value, .Value)
		if !fixed || n == 0 || len(xs) % n != 0 do return
		for i := 0; i < len(xs); i += n do lands(k, a, run_scope(k, xs[i:i + n]), u, .Sent, l)
	}
}

// lands_binding: a binding set at a place: its value is an element of the place's
// color — a place written `C:` takes a value of C —, its color a required one; and
// its value is set where the place has one.
lands_binding :: proc(k: ^Kernel, place, b: ^Binding, u: ^Unknown, l: ^Landing) {
	color := binding_color(k, place)
	d, anonymous := place.value.(^Default)
	if anonymous && color == nil do color = normal(k, d.color)
	if color != nil {
		if b.color != nil do lands(k, color, binding_color(k, b), u, .Required, l)
		else if b.value != nil do lands(k, color, binding_value(k, b), u, .Sent, l)
	}
	if !anonymous && place.value != nil && b.value != nil do lands(k, binding_type(k, place), binding_value(k, b), u, .Sent, l)
}

// lands_template: the value a field had, set beside the one the carve gives it: a
// scope binding by binding — a name by its first occurrence, a production by its
// rank —; any other term as the place of a value.
lands_template :: proc(k: ^Kernel, p, v: Type, u: ^Unknown, l: ^Landing) {
	template, p_scope := p.(^Scope)
	value, v_scope := v.(^Scope)
	if !p_scope || !v_scope {
		lands(k, p, v, u, .Sent, l)
		return
	}
	given := placed(k, value, .Value)
	rank := 0
	for place in placed(k, template, .Value) {
		b: ^Binding
		if place.kind == .Product {
			b = production(given, rank)
			rank += 1
		} else if place.name != "" {
			b, _ = occurrence(given, place.name, -1, false)
		}
		if b != nil do lands_binding(k, place, b, u, l)
	}
}

// production: the n-th production of bindings.
production :: proc(bindings: []^Binding, n: int) -> ^Binding {
	seen := 0
	for b in bindings {
		if b.kind != .Product do continue
		if seen == n do return b
		seen += 1
	}
	return nil
}

// settle: the value of a hole from what landed in it: the required type, every one
// the same and every sent value in it; or else the sent value that holds all the
// others. Nothing landed: the hole keeps its value.
settle :: proc(k: ^Kernel, h: ^Binding, l: Landing, span: syn.Span) -> (value: Type, p: Type) {
	if len(l.required) > 0 {
		t := l.required[0]
		for r in l.required[1:] {
			if !same(k, r, t) do return nil, problem(.Constraint_Mismatch, span, fmt.tprintf("`%s` is required to be %s and %s", h.name, print_type(t), print_type(r)))
		}
		for x in l.sent do if q := in_problem(k, x, t, span); q != nil do return nil, q
		return t, nil
	}
	next: for t in l.sent {
		for x in l.sent {
			if verdict, _ := prove(k, in_law(k, x, t)); verdict != .Proven do continue next
		}
		return t, nil
	}
	if len(l.sent) > 0 do return nil, problem(.Constraint_Mismatch, span, fmt.tprintf("no value sent to `%s` holds the others: %s", h.name, print_types(l.sent[:])))
	return nil, nil
}
