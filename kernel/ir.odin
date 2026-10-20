package kernel

import syn "../compiler"
import "core:slice"

// The IR of the kernel. A scope is an ordered list of bindings. A binding carries
// four things: its color and its value, symbolic, as written — and their types.
// The type simplifies (a carve that gives 5 has type 5), the value keeps all the
// structure that produced it.
//
// Types are expressions too: the type of 5 is 5, that of u8 is 0..255, that of
// `??::u8` is the unknown ??0. A scope is its own type: its bindings already carry
// theirs.

Binding_Kind :: enum u8 {
	Push, // name -> value
	Pull, // name <- value
	Product, // -> value
	Expand, // ...value
	Event_Push, // >-
	Event_Pull, // -<
	Resonance_Push, // >>-
	Resonance_Pull, // -<<
	Reactive_Push, // >>=
	Reactive_Pull, // =<<
}

Binding :: struct {
	name:       string, // "" = anonymous or production
	capture:    string, // invisible alias `(h)`
	kind:       Binding_Kind,
	color:      ^Expr, // left of the `:`; nil = uncolored
	value:      ^Expr, // right of the arrow; nil = not written: the default of the color
	color_type: ^Expr, // type_of(color): an equation, which can share the unknowns of the value
	value_type: ^Expr, // type_of(value), or the default of color_type; nil = not typed yet
	copy:       Copy,
	span:       syn.Span,
}

// Copy: what a carve did with a binding of the copy it derived. An error is
// reported only once, where it can be fixed: a binding copied without change has
// already been checked in its source, a binding that the carve changed is reported
// at the carve.
Copy :: enum u8 {
	Written, // not a copy: the binding as written
	Same, // copied from a source, without the carve touching it
	Changed, // the carved value, or a binding that depends on it
}

Scope :: struct {
	parent:   ^Scope,
	bindings: [dynamic]Binding,
	shape:    []Place, // the shape it received, place by place: the implicit color of its bindings
	site:     syn.Span, // a copy: the carve that derived it, where its errors are reported
	carving:  ^Scope, // the arguments of a carve: the scope it derives, which `.x` designates
	cover:    ^Expr, // a pattern branch: what it admits; nil for the default branch
	fact:     Fact, // a pattern branch: what it knows about the unknown it receives
	span:     syn.Span,
}

// A binding, resolved lexically: go up `up` scopes, take binding `index`.
Ref :: struct {
	up:    int,
	index: int,
	name:  string, // as written, for printing
	span:  syn.Span,
}

// `target.name` (last occurrence) or `target.name#n`.
Access :: struct {
	target:  ^Expr,
	name:    string,
	ordinal: int, // -1 = last occurrence
	span:    syn.Span,
}

// `target!`: the scope reduced by its first production.
Collapse :: struct {
	target: ^Expr,
	span:   syn.Span,
}

// An operator. `left` is nil for a unary operator (`~x`, `>0`, `-x`).
Op :: struct {
	kind:  syn.Operator_Kind,
	left:  ^Expr,
	right: ^Expr,
	span:  syn.Span,
}

// `target{…}`: a scope derived from target, some bindings of which receive another
// value. The arguments are a scope written at this place: `x -> v` targets the
// first occurrence of x (`x#n -> v`, the n-th), an unnamed argument targets the
// binding of the same rank among those that are not productions.
Carve :: struct {
	target:   ^Expr,
	args:     ^Scope,
	ordinals: []int, // for each argument, the targeted occurrence; -1: the first
	span:     syn.Span,
}

// Carved: in a carved scope, the value that an argument put in its place. It
// remains argument `index` of `args`, written and typed where it was written.
Carved :: struct {
	args:  ^Scope,
	index: int,
}

// Inferred: in a carved scope, the value that a hole received from the carve
// without being filled: the one, among what falls in its place, that contains all
// the others (hole.odin).
Inferred :: struct {
	args: ^Scope, // the arguments of the carve that inferred it
	type: ^Expr,
}

// `.x` without a source, in the arguments of a carve: the scope that this carve
// derives. `a{z -> .z{b -> 2}}` recarves the z of a.
Carving :: struct {
	span: syn.Span,
}

// `z{…}` without an arrow, among the arguments of a carve: the target of this
// inner carve remains to be chosen. If the carved scope has a field z, it is `.z`,
// and the argument recarves that field: `a{z{b -> 2}}` is `a{z -> .z{b -> 2}}`.
// Otherwise it is the visible z, and the argument is positional: `Pt{Box{1}}`.
// This is known only once the target is typed.
Shorthand :: struct {
	field: Access, // .z
	outer: ^Expr, // z, resolved above; nil when nothing is called z
}

// `target ? {…}`: each branch is a scope, whose production is that of the branch,
// written in its cover (Scope.cover). The first branch that admits the value of
// target gives it (pattern.odin).
Match :: struct {
	target:   ^Expr,
	branches: []^Scope,
	span:     syn.Span,
}

// `lo..hi`. A nil bound is open. Between characters, the interval is over the
// characters (`'a'..'z'`); between strings, over the positions (`"jwt"..` starts
// with, `.."_"` ends with).
Range :: struct {
	lo:   ^Expr,
	hi:   ^Expr,
	span: syn.Span,
}

// `??` (nil layout) or `??::T`: an unknown value, of which only the type is known.
Unknown :: struct {
	layout: ^Expr,
	span:   syn.Span,
}

// An error already reported at this place: everything that depends on it stays
// silent.
Invalid :: struct {}

Expr :: union {
	^Scope,
	Set,
	Ref,
	Access,
	Collapse,
	Carve,
	Carved,
	Inferred,
	Carving,
	Shorthand,
	Op,
	Match,
	Range,
	Unknown,
	Poly, // an integer value that depends on unknowns (a type only): unknown.odin
	Term, // another value that depends on unknowns
	^Var, // an unknown that is not a pure integer (an integer is a polynomial)
	Set_Form, // a set that depends on unknowns: set_form.odin
	Cases, // the type of a pattern on an unknown: one value per reached branch
	Invalid,
}

new_expr :: proc(e: Expr) -> ^Expr {
	r := new(Expr)
	r^ = e
	return r
}

new_scope :: proc(parent: ^Scope, span: syn.Span = {}) -> ^Scope {
	s := new(Scope)
	s.parent = parent
	s.span = span
	return s
}

// --- errors ---

Error_Kind :: enum u8 {
	Undefined_Identifier,
	Invalid_Binding_Name,
	Invalid_Property_Access,
	Invalid_Execute,
	Invalid_Carve,
	Invalid_Expansion,
	Invalid_operator,
	Invalid_Range,
	Constraint_Mismatch,
	Non_Exhaustive_Pattern, // a possible value that no branch admits
	Unproven, // the kernel cannot prove that a color is respected
	Insoluble_Constraint,
	Infinite_Recursion, // the base case of a recursive type comes back to itself
	Invalid_Cast, // a cast to what is not a layout
	Unsupported, // a form that the kernel does not handle yet
}

Error :: struct {
	kind:    Error_Kind,
	message: string,
	span:    syn.Span, // where to report it
	origin:  syn.Span, // what it concerns, written in the source of a copy; = span outside copies
}

Kernel :: struct {
	ast:      ^syn.Ast,
	errors:   [dynamic]Error,
	typed:    [dynamic]^Scope, // all typed scopes, for the final check
	variables: int, // the count of created variables: their order (unknown.odin)
	shapes:   map[^Scope]Set, // a scope read as a color, once and for all (bdd.odin)
	scene:    Scene, // the binding typed or checked right now: where its errors go
	matching: map[Matching]struct{}, // the memberships in a shape being decided
}

// Scene: where the errors of the current binding go. Outside copies, to the place
// they concern; in a copy, to the carve (site), or nowhere (quiet).
Scene :: struct {
	site:  syn.Span,
	quiet: bool,
}

// enter: the scene of a binding of scope s; returns the previous one, to restore.
enter :: proc(k: ^Kernel, s: ^Scope, b: ^Binding) -> (previous: Scene) {
	previous = k.scene
	switch b.copy {
	case .Written:
		k.scene = {}
	case .Same:
		k.scene = {
			quiet = true,
		}
	case .Changed:
		k.scene = {
			site = s.site,
		}
		// the carved value itself: at the argument, when the carve is the one that
		// derived this scope
		if b.value != nil {
			if c, carved := b.value^.(Carved); carved && c.args.span == s.site do k.scene.site = c.args.bindings[c.index].span
		}
	}
	return
}

// report: an error, at the place the scene says, only once.
report :: proc(k: ^Kernel, kind: Error_Kind, span: syn.Span, message: string) -> ^Expr {
	return report_about(k, kind, span, span, message)
}

// report_about: an error reported at `span`, which concerns what is written at
// `origin` — a binding that a scope received from elsewhere.
report_about :: proc(
	k: ^Kernel,
	kind: Error_Kind,
	span, origin: syn.Span,
	message: string,
) -> ^Expr {
	if !k.scene.quiet {
		e := Error{kind, message, k.scene.site != {} ? k.scene.site : span, origin}
		if !slice.contains(k.errors[:], e) do append(&k.errors, e)
	}
	return new_expr(Invalid{})
}

is_invalid :: proc(e: ^Expr) -> bool {
	if e == nil do return false
	_, ok := e^.(Invalid)
	return ok
}
