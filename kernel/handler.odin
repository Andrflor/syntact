package kernel

import "core:fmt"
import "core:slice"

// HANDLERS (specs/types.md §4.9)
//
// A handler is context: who answers an event where a scope is collapsed, known when
// the program is typed. An emission ⟨E{a}⟩(x, t) is held where it is written until a
// handler answers it: where the scope that holds it is collapsed, by the handler of
// E of the scope the collapse is written in; otherwise it comes up with what the
// collapse gives, and so on up. The program, collapsed by nothing, answers what
// comes up to it by the default of each emission: the handler of E visible where it
// is written. Answered, an emission is the run of its handler, what is sent carved
// in:
//
//   ⟨E{a}⟩(x, t)   answered by E -< e {…}   =   {x -> {…}{e -> E{a}}!  -> t}!
//
// An event is its handle: the binding its name is resolved to, the one a copy
// copies (as_written). A scope does not answer its own emissions — those written in
// it, in the scopes written in it, its handlers too, in any copy of these, as a
// recursive call is —: they come up to where it is collapsed, and its handlers are
// their defaults. A recursive call whose equation emits is answered where it is
// collapsed like an emission: the scopes it is collapsed in answer what its
// equation emits, each run of it.

// emission_law: ⟨E{a}⟩(x, t): what is sent, computed first — its effects before the
// emission —, an event, E the binding its name is resolved to. Its default is the
// nearest handler of E visible where it is written; without one, it is invalid.
emission_law :: proc(k: ^Kernel, e: ^Effect) -> Type {
	if e.emission.event != nil do return effect_law(k, e, normal(k, e.then))
	return sequence(k, e, {normal(k, e.emission.sent)}, sent_law)
}

sent_law :: proc(k: ^Kernel, t: Type, parts: []Type) -> Type {
	e := t.(^Effect)
	m := e.emission
	event := designated(k, m.handle)
	if _, is_scope := parts[0].(^Scope); !is_scope || event == nil {
		return problem(.Invalid_Emission, e.span, fmt.tprintf("`>-` sends an event, a scope that a name gives, not %s", print_type(parts[0])))
	}
	out := new(Emission)
	out^ = m^
	out.sent, out.event = parts[0], as_written(event)
	for h in m.handlers {
		if handled(k, h) != out.event do continue
		out.default = h
		break
	}
	if out.default == nil {
		return problem(.Invalid_Emission, e.span, fmt.tprintf("`%s` has no handler visible here: an emission needs one, its default", event.name))
	}
	x := new(Effect)
	x^ = e^
	x.emission = out
	return effect_law(k, x, normal(k, e.then))
}

// as_written: a scope or a binding as written, which a copy copies: an event is its
// handle, the binding as written.
as_written :: proc {scope_as_written, binding_as_written}

scope_as_written :: proc(s: ^Scope) -> ^Scope {
	out := s
	for out.source != nil && out.source != out do out = out.source
	return out
}

binding_as_written :: proc(b: ^Binding) -> ^Binding {
	out := b
	for out.source != nil do out = out.source
	return out
}

// handled: the event the handler h answers; nil when its handle is not a binding.
handled :: proc(k: ^Kernel, h: ^Binding) -> ^Binding {
	b := designated(k, h.handle)
	return b != nil ? as_written(b) : nil
}

// handler_of: the handler of the event in s, the last it writes; nil when it has none.
handler_of :: proc(k: ^Kernel, s: ^Scope, event: ^Binding) -> ^Binding {
	#reverse for b in s.bindings do if b.kind == .Handler && handled(k, b) == event do return b
	return nil
}

has_handlers :: proc(s: ^Scope) -> bool {
	for b in s.bindings do if b.kind == .Handler do return true
	return false
}

// answered: t, what a collapse written in s gives, its emissions answered by the
// handlers of s (§4.9).
answered :: proc(k: ^Kernel, t: Type, s: ^Scope) -> Type {
	if s == nil || !has_handlers(s) do return t
	return answer_in(k, t, s)
}

// answered_by_program: t, come up to the program: each emission answered by its
// default.
answered_by_program :: proc(k: ^Kernel, t: Type) -> Type {
	return answer_in(k, t, nil)
}

// answer_in: t, its emissions answered where they are held — at the head, in the
// branches of a pattern, a choice or a fold —, by s, or by their defaults when s is
// nil; the recursive calls whose equation is not that of s, answered by s. What the
// emissions of the head give back is bound in t, and in the terms of bound too: the
// steps of a fold read what the effects of a step give back.
answer_in :: proc(k: ^Kernel, t: Type, s: ^Scope, bound: ^[]Type = nil) -> Type {
	#partial switch v in t {
	case ^Effect:
		then := answer_in(k, v.then, s, bound)
		if v.emission != nil {
			if h := answerer(k, v.emission, s); h != nil do return answer(k, v, h, then, s, bound)
		}
		out := new(Effect)
		out^ = v^
		out.then = then
		switch {
		case v.choice != nil:
			out.choice = answer_in(k, v.choice, s)
			// a choice whose branches have no effect left is what follows: it reads
			// what the choice gives
			if !has_effect(out.choice) do return then
		case v.fold != nil:
			f := new(Fold)
			f^ = v.fold^
			n := len(f.updates)
			steps := make([]Type, n + 1)
			copy(steps, f.updates)
			steps[n] = f.value
			f.effects = answer_in(k, v.fold.effects, s, &steps)
			f.updates, f.value = steps[:n], answer_in(k, steps[n], s)
			if f.effects == v.fold.effects && identical(f.updates, v.fold.updates) && f.value == v.fold.value && then == v.then do return t
			run := folded(k, f)
			if v.answer != nil do then = rewrite(k, then, rewriting(nil, v.answer, given(k, run)))
			return sequence(k, nil, {run, then}, last_part)
		case v.call != nil && v.call.recursive && s != nil:
			c := v.call
			if target, is_scope := c.target.(^Scope); is_scope && !written_in(origin(target), s) {
				call := new(Collapse)
				call^ = c^
				call.answered = make([]^Scope, len(c.answered) + 1)
				copy(call.answered, c.answered)
				call.answered[len(c.answered)] = s
				out.call = call
			}
		}
		if then == v.then && out.choice == v.choice && out.call == v.call do return t
		return out
	case ^Pattern:
		if !has_effect(v) do return t
		branches := make([]Branch, len(v.branches))
		moved := false
		for b, j in v.branches {
			branches[j] = Branch{cover = b.cover, product = answer_in(k, b.product, s), span = b.span}
			moved ||= branches[j].product != b.product
		}
		if !moved do return t
		return pattern_law(k, branching(v, branches))
	}
	return t
}

// answerer: the handler that answers the emission m where it comes, collapsed in s:
// the handler of its event s has, unless it is written in s; collapsed by nothing,
// its default.
answerer :: proc(k: ^Kernel, m: ^Emission, s: ^Scope) -> ^Binding {
	if s == nil do return m.default
	if written_in(m.site, s) do return nil
	return handler_of(k, s, m.event)
}

// written_in: the scope x is written in s, or is s, as written.
written_in :: proc(x, s: ^Scope) -> bool {
	w := as_written(s)
	for sc := x; sc != nil; sc = sc.parent do if as_written(sc) == w do return true
	return false
}

// answer: ⟨E{a}⟩(x, t) answered by the handler h: the run of h, what is sent carved
// in, then t, x what the run gives back — in the terms of bound too. The answer is
// checked where it is given, in the layout written for x. What the run emits comes
// up from s, or is answered by its default at the program.
answer :: proc(k: ^Kernel, e: ^Effect, h: ^Binding, then: Type, s: ^Scope, bound: ^[]Type) -> Type {
	if slice.contains(k.answering[:], h) do return problem(.Infinite_Recursion, h.span, "this handler answers itself again")
	append(&k.answering, h)
	defer pop(&k.answering)
	scope, is_scope := binding_type(k, h).(^Scope)
	if !is_scope do return binding_type(k, h)
	// the first binding of a handler is what is sent (build_handler)
	carved := carve(k, scope, []Carve_Arg{Carve_Arg{ordinal = -1, value = e.emission.sent, span = e.span}}, e.span)
	sent, ok := carved.(^Scope)
	if !ok do return carved
	c := new(Collapse)
	c.target, c.span = sent, e.span
	run := collapsed(k, sent, c)
	if s == nil do run = answer_in(k, run, nil)
	if e.answer == nil do return sequence(k, nil, {run, then}, last_part)
	v := given(k, run)
	if layout := layout_of(k, e.answer); !is_everything(layout) {
		if p := in_problem(k, v, layout, scope.span); p != nil do return p
	}
	gives := rewriting(nil, e.answer, v)
	if bound != nil do bound^ = rewrite_all(k, bound^, gives)
	return sequence(k, nil, {run, rewrite(k, then, gives)}, last_part)
}
