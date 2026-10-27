package kernel

import syn "../syntax"
import "base:runtime"
import "core:slice"

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
	^Fold, // ⟳(k: a ↦ n until S; ε…; x: c ↦ t; v)   along an orbit (§5.6)
	^Least, // μ(i: t)    the least i ≥ 0 where t holds (§5.6)
	^Series, // Σ(i: a..b, t), Π(i: a..b, t)   (§5.6)
	^Recurrent, // C⟨c₁ … c_d | x₀ … x_{d-1}⟩(s)   a C-finite sequence (§5.6)
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
	call:     ^Collapse, // what a recursive call with effects gives back (§4.8): a value of its equation
}

// Effect: εₖ(x, t), the effect written k (§4.8). x is what it gives back, bound in
// t, the computation it wraps; each run of a scope gives the effects it gathers new
// ones (effect.odin). Written alone, `!?::L` is εₖ(x::L, x).
Effect :: struct {
	id:      int,
	answer:  ^Unknown, // nil: it gives nothing back, εₖ(t)
	call:    ^Collapse, // the effect is this call: a recursive call with effects, or a symbol behind a boundary
	fold:    ^Fold, // the effect is this fold: the effects of its steps, in order (§5.6)
	choice:  Type, // the effect is this choice: a pattern, the effects of the branch it takes
	emission: ^Emission, // an emission its handler has not answered yet (§4.9)
	then:    Type,
	span:    syn.Span,
}

// Emission: ⟨E{a}⟩(x, t), the event E sent with a, x its answer (§4.9). It is not an
// effect: a handler answers it where the scope that holds it is collapsed, when the
// program is typed. Until then it is held where it is written, like an effect,
// since its handler may have some: it is the Effect that carries it.
Emission :: struct {
	id:       int, // the emission written: copies and runs keep it
	sent:     Type, // E{a}, or E: what is sent
	handle:   Type, // E, the name of the event, as written: a copy follows it, never replaces it (copy_handle)
	event:    ^Binding, // the binding E names, as written (as_written); nil until typed
	handlers: []^Binding, // the handlers visible where it is written, the nearest first
	default:  ^Binding, // the handler of E among them: the program answers it with it; nil until typed
	site:     ^Scope, // the scope that writes it: its handlers answer it only as its default
}

Or :: struct {
	terms: []Type,
	normal: bool, // a normal form: normal gives it back
}

And :: struct {
	terms: []Type,
	normal: bool, // a normal form: normal gives it back
}

Not :: struct {
	term: Type,
	normal: bool, // a normal form: normal gives it back
}

Is :: struct {
	term: Type,
	normal: bool, // a normal form: normal gives it back
}

// Range: every primitive from lo to hi; a nil bound is infinite. Its bounds are
// primitives of one family, or terms over unknowns (0..n). Infinite on both sides,
// it keeps its family: `..0..` is every integer, `..` alone every primitive.
Range :: struct {
	lo, hi: Type,
	family: Range_Family,
	span:   syn.Span,
	normal: bool, // a normal form: normal gives it back
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
	Pow, // ** : an integer or a real, to a count
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
	normal: bool, // a normal form: normal gives it back
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
	site:      ^Scope, // the scope it is written in: its handlers answer what it emits (§4.9)
	answered:  []^Scope, // a recursive call whose equation emits: the scopes whose handlers answer it, the nearest first
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
	handler:   bool, // `E -< e {…}`: replaces the handler of E (§4.9)
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
	normal: bool, // a normal form: normal gives it back
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

// Fold: the solution of a recursion (§5.6), an ordered product along the orbit of
// its argument. k takes start and each state its init; while k is not in stop, the
// effects of a step run, in order, then the states take their updates — all read
// before any is written — and k takes next. Where k stops, the fold is its value.
// k, the states and what the effects give back are bound in it.
Fold :: struct {
	index:   ^Unknown,
	start:   Type,
	stop:    Type,
	next:    Type,
	states:  []^Unknown,
	inits:   []Type,
	effects: Type, // a chain εₖ(x, …) ending in none; none when a step has none
	updates: []Type,
	value:   Type,
	span:    syn.Span,
}

// Least: μ(i: t), the least integer i ≥ 0 for which t holds — Kleene's μ: the
// number of steps an orbit takes to where it stops (§5.6). i is bound in t.
Least :: struct {
	index: ^Unknown,
	holds: Type,
	span:  syn.Span,
}

// Series: Σ(i: lo..hi, t), the sum of t for i from lo to hi — 0 when the range is
// empty —, or Π(i: lo..hi, t), their product — 1 then (§5.6). i is bound in t.
Series :: struct {
	op:     Operator, // .Add, .Mul
	index:  ^Unknown,
	lo, hi: Type,
	term:   Type,
	span:   syn.Span,
}

// Recurrent: C⟨c₁ … c_d | x₀ … x_{d-1}⟩(s), the s-th term, s ≥ 0, of the sequence
// x_t = c₁·x_{t-1} + … + c_d·x_{t-d} from its first d terms: a C-finite sequence
// (§5.6). With α a root of x^d - c₁·x^{d-1} - … - c_d, x_s = Σ_j x_j·[αˢ]_j, the
// coordinates of αˢ in ℤ[α] — a power, in O(log s).
Recurrent :: struct {
	coefficients: []i128,
	initial:      []Type,
	at:           Type,
	span:         syn.Span,
}

// fold_parts: the terms of a fold, in a fixed order: start, stop, next, the inits,
// the effects, the updates, the value.
fold_parts :: proc(f: ^Fold) -> []Type {
	out := make([dynamic]Type)
	append(&out, f.start, f.stop, f.next)
	append(&out, ..f.inits)
	append(&out, f.effects)
	append(&out, ..f.updates)
	append(&out, f.value)
	return out[:]
}

// with_parts: f with these terms, in the order of fold_parts.
with_parts :: proc(f: ^Fold, parts: []Type) -> ^Fold {
	out := new(Fold)
	out^ = f^
	n := len(f.states)
	out.start, out.stop, out.next = parts[0], parts[1], parts[2]
	out.inits = slice.clone(parts[3:][:n])
	out.effects = parts[3 + n]
	out.updates = slice.clone(parts[4 + n:][:n])
	out.value = parts[4 + 2 * n]
	return out
}

// --- scopes (§5) ---

Kind :: enum u8 {
	Push, // name -> value, C:name, an anonymous value
	Pull, // name <- value: a hole
	Product, // -> value: a production
	Expand, // ...value, ...C:, ...
	Handler, // E -< e {…}: the handler of E, a scope in which e is what is sent (§4.9)
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
	handle:      Type, // a handler: the event it answers, as written
	span:        syn.Span,
	scope:       ^Scope,
	source:      ^Binding, // in a copy made by a carve: the binding it copies
	carved:      bool, // in a copy: its value is the carve's
	typed_color: Type,
	typed_value: Type,
	typed_product: Type, // a production: what its value gives, before the effects above it
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
	effectful: bool, // a recursive scope whose equation has effects: its calls are effects (§4.8)
	boundary:  string, // `<lib>{…}`: the scopes written in it are symbols, run in lib (§4.8)
	branch:    bool, // a branch of a pattern, or the view of its cover: what is written in it is written in the scope that holds the pattern
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

// written: a term built from the source, with the place it is written: a copy that
// holds it — a term is not changed once built, it may be shared.
written :: proc(t: Type, span: syn.Span) -> Type {
	#partial switch v in t {
	case ^Operation:
		o := new(Operation)
		o^ = v^
		o.span, o.normal = span, false
		return o
	case ^Range:
		r := new(Range)
		r^ = v^
		r.span, r.normal = span, false
		return r
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

// THE CONSTANTS
//
// The types the laws name again and again — every integer, real, character and
// string, "", ~none, the booleans, the counts — are built once, when the kernel is
// loaded, and shared: a term is not changed once built.

EVERY_INT, EVERY_REAL, EVERY_CHAR, STRING, EMPTY_STRING, EVERYTHING, BOOLS: Type
COUNTS, POSITIVE, NONPOSITIVE, NONZERO_INT, NONZERO_REAL: Type // 0.., 1.., ..0, int & ~0, float & ~0.0

@(init)
init_constants :: proc "contextless" () {
	context = runtime.default_context()
	EVERY_INT, EVERY_REAL = new_range(nil, nil, .Int), new_range(nil, nil, .Real)
	EVERY_CHAR = new_range(Char(0), nil)
	COUNTS, POSITIVE, NONPOSITIVE = new_range(Int(0), nil, .Int), new_range(Int(1), nil, .Int), new_range(nil, Int(0), .Int)
	STRING = new_operation(.Mul, EVERY_CHAR, COUNTS) // ''.. * 0..
	EMPTY_STRING = new_operation(.Add)
	EVERYTHING = new_not(None{})
	BOOLS = new_or(Bool(false), Bool(true))
	NONZERO_INT = new_or(new_range(nil, Int(-1), .Int), POSITIVE) // its cells, in their order
	NONZERO_REAL = new_or(real_cell({hi = real_int(0), hi_open = true}), real_cell({lo = real_int(0), lo_open = true}))
}

// everything: ~none, every value (§4.1).
everything :: proc() -> Type {
	return EVERYTHING
}

// is_everything: t is ~none.
is_everything :: proc(t: Type) -> bool {
	n, ok := t.(^Not)
	return ok && is_none(n.term)
}

// empty_string: "", the concatenation of nothing (§4.6).
empty_string :: proc() -> Type {
	return EMPTY_STRING
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
