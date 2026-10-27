package kernel

import syn "../syntax"

// TYPES (specs/types.md §1–2)
//
// A type is a term of this grammar, and nothing else. The primitive types are the
// values; the algebra composes them; scopes, names and patterns are terms too. The
// program as written is made of these terms, and its types are their normal forms
// (normal.odin).

Type :: union {
	// §1: the primitives
	Char, // 'a': a character, a string of length 1
	Int, // 5
	Real, // 0.5
	Bool, // true, false
	None, // the empty type, ∨([])
	^Unknown, // ?ₖ::L
	^Effect, // εₖ(x, t)     !?, x what it gives back, bound in t (§4.8)
	// §2: the algebra
	^Or, // ∨([t…])      a | b
	^And, // ∧([t…])      a & b
	^Not, // ~(t)
	^Is, // =(t)
	^Range, // l..u         .. extends |
	^Operation, // *([t…], op)  a + b, a in b, …
	^Name, // x            the type of its binding
	^Scope, // {b…}
	^Access, // s.x
	^Collapse, // s!
	^Carve, // s{…}
	^Default, // C:           an anonymous binding colored by C
	^Pattern, // t ? {c -> p …}
	Invalid, // a term no law gives a type to, and why: the check reports it
}

Char :: distinct rune
Int :: distinct i128
Real :: struct {
	num, den: i128, // num / den, den > 0, in lowest terms (real.odin)
}
Bool :: distinct bool
None :: struct {}
// Invalid: a term no law gives a type to, with its problem, which the check reports
// (check.odin). What holds it is Invalid too, with the same problem: it is
// reported once. Without a problem, it was reported when the term was built.
Invalid :: struct {
	problem: ^Problem,
}

Problem :: struct {
	kind:    Error_Kind,
	message: string,
	span:    syn.Span,
}

// problem: the term no law gives a type to, for this reason.
problem :: proc(kind: Error_Kind, span: syn.Span, message: string) -> Type {
	p := new(Problem)
	p^ = Problem{kind, message, span}
	return Invalid{p}
}

// Unknown: `??::L`, one value in L. Each `??` written is a distinct unknown; the
// same one comes back through a name.
Unknown :: struct {
	id:      int,
	written:  Type, // `??::L`: L as written; `C:x -> ??`: the color C; nil: everything
	layout:   Type, // a branch that narrows it: ?ₖ::(L & S) (rewrite.odin); nil otherwise
	instance: ^Scope, // in a carve whose changes its layout names: ?ₖ read in that carve
	call:     ^Collapse, // what a recursive call that acts gives back (§4.8): a value of its equation
}

// Effect: εₖ(x, t), the effect written k (§4.8). x is what it gives back, bound in
// t, the computation it wraps; each run of a scope gives the acts it gathers new
// ones (effect.odin). Written alone, `!?::L` is εₖ(x::L, x).
Effect :: struct {
	id:     int,
	answer: ^Unknown, // nil: it gives nothing back, εₖ(t)
	call:   ^Collapse, // the act is this call: a recursive call that acts, or a symbol behind a boundary
	then:   Type,
	span:   syn.Span,
}

Or :: struct {
	terms: []Type,
}

And :: struct {
	terms: []Type,
}

Not :: struct {
	term: Type,
}

Is :: struct {
	term: Type,
}

// Range: every primitive from lo to hi; a nil bound is infinite. Its bounds are
// primitives of one family, or terms over unknowns (0..n). Infinite on both sides,
// it keeps its family: `..0..` is every integer, `..` alone every primitive.
Range :: struct {
	lo, hi: Type,
	family: Range_Family,
	span:   syn.Span,
}

Range_Family :: enum u8 {
	Any, // `..`: every primitive
	Int,
	Real,
}

Operator :: enum u8 {
	Add, // + : integers, reals, and the concatenation of strings
	Sub,
	Mul, // * : integers, reals, and the repetition of a string
	Div,
	Mod,
	Neg,
	Bit_And, // [&]
	Bit_Or, // [|]
	Xor, // ^
	Bit_Not, // [~]
	Shl,
	Shr,
	Less,
	Less_Eq,
	Greater,
	Greater_Eq,
	In,
}

Operation :: struct {
	op:   Operator,
	args: []Type,
	span: syn.Span, // as written: where an illegal operator is reported
}

// Name: a binding, the last occurrence visible where the name is written.
Name :: struct {
	binding: ^Binding,
	span:    syn.Span,
}

Access :: struct {
	target:  Type,
	name:    string,
	ordinal: int, // x#n; -1: the last occurrence
	span:    syn.Span,
}

// Collapse: `s!`. `recursive`: written in a production of the scope s names: a
// recursive call, never unfolded (§5.6).
Collapse :: struct {
	target:    Type,
	recursive: bool,
	span:      syn.Span,
}

Carve :: struct {
	target: Type,
	args:   []Carve_Arg,
	span:   syn.Span,
}

Carve_Arg :: struct {
	name:      string, // "" for a positional argument
	ordinal:   int, // x#n; -1: the first occurrence
	pull:      bool, // `x <- v`: fills a hole (§5.7)
	value:     Type,
	span:      syn.Span,
	// `z{…}`: a carve carves any binding, by carving it too: the binding z of the
	// target becomes z{…}. When the target has no z, z{…} is the carve of the name
	// z above, a value given by position.
	carves:    []Carve_Arg,
	otherwise: Type,
}

Default :: struct {
	color: Type,
	span:  syn.Span,
}

Pattern :: struct {
	target:   Type,
	branches: []Branch,
	span:     syn.Span,
}

// Branch: a scope whose production is written in its cover (§6): `scope` holds
// what the branch types, under the layouts its reach narrows.
Branch :: struct {
	cover:   Type, // nil: the default branch
	product: Type,
	scope:   ^Scope,
	view:    ^Scope, // the names of the cover its product reads (destructuring)
	span:    syn.Span,
}

// --- scopes (§5) ---

Kind :: enum u8 {
	Push, // name -> value, C:name, an anonymous value
	Pull, // name <- value: a hole
	Product, // -> value: a production
	Expand, // ...value, ...C:, ...
}

Typing :: enum u8 {
	Not_Asked,
	In_Progress,
	Done,
}

// Binding: a binding as written — its color and its value are terms — and their
// normal forms, given once, when asked.
Binding :: struct {
	name:        string, // "" for an anonymous binding or a production
	capture:     string, // (h): an alias the product of a cover reads; not a field
	kind:        Kind,
	color:       Type, // nil: uncolored
	value:       Type, // nil: the default of the color
	span:        syn.Span,
	scope:       ^Scope,
	source:      ^Binding, // in a copy made by a carve: the binding it copies
	carved:      bool, // in a copy: its value is the carve's
	typed_color: Type,
	typed_value: Type,
	typed_product: Type, // a production: what its value gives, before the acts above it
	state:       Typing,
}

// Scope: an ordered sequence of bindings — a type. A carve derives a scope: a copy
// where some bindings receive another value (§5.3).
Scope :: struct {
	parent:    ^Scope, // where it is written: its names see the bindings above
	bindings:  [dynamic]^Binding,
	source:    ^Scope, // a copy (carve, coloring): the scope it copies
	carved:    ^Scope, // a carve: the scope it carves, uncarved
	changes:   map[^Binding]Type, // a carve: the values of the bindings of `carved` it replaces
	complete:  bool, // all its bindings are built: all are visible
	producing: bool, // one of its productions is being built: it may name itself
	reached:   bool, // asked once: it is checked (check.odin)
	acting:    bool, // a recursive scope whose equation acts: its calls are acts (§4.8)
	boundary:  string, // `<lib>{…}`: the scopes written in it are symbols, run in lib (§4.8)
	name:      string, // the binding it is the value of, as written: for printing
	span:      syn.Span,
}

// View: a scope read as a value, where `...C:` places the default of C, or as a
// shape, where `...C:` admits a run that C admits (§5.4).
View :: enum u8 {
	Value,
	Shape,
}


// --- helpers ---

new_or :: proc(terms: ..Type) -> Type {
	o := new(Or)
	o.terms = clone_types(terms)
	return o
}

new_and :: proc(terms: ..Type) -> Type {
	a := new(And)
	a.terms = clone_types(terms)
	return a
}

new_not :: proc(t: Type) -> Type {
	n := new(Not)
	n.term = t
	return n
}

new_is :: proc(t: Type) -> Type {
	i := new(Is)
	i.term = t
	return i
}

new_range :: proc(lo, hi: Type, family := Range_Family.Any, span := syn.Span{}) -> Type {
	r := new(Range)
	r.lo, r.hi, r.family, r.span = lo, hi, family, span
	return r
}

new_operation :: proc(op: Operator, args: ..Type) -> Type {
	o := new(Operation)
	o.op, o.args = op, clone_types(args)
	return o
}

// written: a term built from the source, with the place it is written.
written :: proc(t: Type, span: syn.Span) -> Type {
	#partial switch v in t {
	case ^Operation:
		v.span = span
	case ^Range:
		v.span = span
	}
	return t
}

clone_types :: proc(ts: []Type) -> []Type {
	out := make([]Type, len(ts))
	copy(out, ts)
	return out
}

is_invalid :: proc(t: Type) -> bool {
	_, ok := t.(Invalid)
	return ok
}

is_none :: proc(t: Type) -> bool {
	_, ok := t.(None)
	return ok
}

is_bool :: proc(t: Type, b: bool) -> bool {
	v, ok := t.(Bool)
	return ok && bool(v) == b
}

// EVERYTHING: ~none, every value (§4.1).
everything :: proc() -> Type {
	return new_not(None{})
}

// is_everything: t is ~none.
is_everything :: proc(t: Type) -> bool {
	n, ok := t.(^Not)
	return ok && is_none(n.term)
}

// empty_string: "", the concatenation of nothing (§4.6).
empty_string :: proc() -> Type {
	return new_operation(.Add)
}

is_empty_string :: proc(t: Type) -> bool {
	o, ok := t.(^Operation)
	return ok && o.op == .Add && len(o.args) == 0
}

// is_primitive: a value of §1 other than an unknown.
is_primitive :: proc(t: Type) -> bool {
	#partial switch _ in t {
	case Char, Int, Real, Bool, None:
		return true
	}
	return is_string_value(t)
}

// is_string_value: a string of zero or several characters: a concatenation of
// characters.
is_string_value :: proc(t: Type) -> bool {
	o, ok := t.(^Operation)
	if !ok || o.op != .Add do return false
	for a in o.args do if _, is_char := a.(Char); !is_char do return false
	return true
}
