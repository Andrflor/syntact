package kernel

import "core:fmt"
import "core:slice"
import "core:strings"

// LES INCONNUES ET LEURS FORMES NORMALES
//
// Une inconnue (`??::u8`, `string:s -> ??`) est un symbole qui porte l'ensemble de
// ses valeurs possibles. Une expression qui en dépend garde sa forme, normalisée
// pour être précise (`n - n` vaut 0, pas -255..255) :
//
//   entiers       un polynôme : Σ coef·monôme + constante, monômes triés,
//                 coefficients non nuls ; sans monôme, c'est l'atome.
//                 n - n → 0      n*3 + n → 4*??0      (n + 1)*2 → 2*??0 + 2
//   flottants     un terme réduit par les seules lois exactes en IEEE : la
//                 commutativité de + et *, -(-x) = x, x*1.0 = x.
//   chaînes       un mot : concaténation aplatie, littéraux voisins fusionnés.
//   comparaisons  sur les entiers p < 0, p = 0, p ≠ 0 avec p normalisé (pgcd,
//                 signe) ; sinon a < b, a <= b (sens fixé), a = b (ordonnés).
//
// Le type d'une telle expression (ses valeurs possibles) est exact quand on peut
// énumérer ses symboles, sur-approché sinon — jamais pour une couleur : une
// couleur est un singleton, donc ne dépend d'aucune inconnue.

Mono :: struct {
	coef: i128,
	vars: []int, // ids de symboles triés, répétés pour les puissances : n² = [n, n]
}

Poly :: struct {
	monos: []Mono, // triés, coefficients non nuls
	const: i128,
}

Term_Op :: enum u8 {
	Sym, // une inconnue qui n'est pas un entier pur
	F_Add, // flottants : commutatif, opérandes ordonnés
	F_Mul,
	F_Neg,
	Concat, // chaînes : un mot
	Repeat, // [texte, compte] : une répétition dont le compte est inconnu
	Lt, // entiers : [p] pour p < 0 ; sinon [a, b] pour a < b
	Le, // [a, b] pour a <= b
	Eq, // entiers : [p] pour p = 0 ; sinon [a, b] ordonnés
	Ne,
}

Term :: struct {
	op:   Term_Op,
	sym:  int, // .Sym
	args: []^Expr,
}

// Au-delà, on n'énumère plus les valeurs d'une expression : on les sur-approche.
ENUMERATION_LIMIT :: 1 << 16

// --- symboles ---

// new_symbol : une inconnue dont les valeurs possibles sont `set`. Une inconnue à
// une seule valeur possible est cette valeur.
new_symbol :: proc(k: ^Kernel, set: Set) -> ^Expr {
	if is_atom(set) do return new_expr(set)
	id := len(k.symbols)
	append(&k.symbols, set)
	if d, pure := pure_domain(set); pure && d == .Ints {
		return new_expr(poly_var(id))
	}
	return new_expr(Term{op = .Sym, sym = id})
}

poly_var :: proc(id: int) -> Poly {
	vars := make([]int, 1)
	vars[0] = id
	monos := make([]Mono, 1)
	monos[0] = Mono{1, vars}
	return Poly{monos = monos}
}

// is_value : un type de valeur — un atome, ou une forme sur des inconnues.
is_value :: proc(t: ^Expr) -> bool {
	#partial switch v in t^ {
	case Set:
		return is_atom(v)
	case Poly, Term:
		return true
	}
	return false
}

// value_domain : la sorte d'une valeur, connue ou non.
value_domain :: proc(k: ^Kernel, t: ^Expr) -> (Domain, bool) {
	#partial switch v in t^ {
	case Set:
		return pure_domain(v)
	case Poly:
		return .Ints, true
	case Term:
		switch v.op {
		case .Sym:
			return pure_domain(k.symbols[v.sym])
		case .F_Add, .F_Mul, .F_Neg:
			return .Floats, true
		case .Concat, .Repeat:
			return .Strings, true
		case .Lt, .Le, .Eq, .Ne:
			return .Bools, true
		}
	}
	return .Ints, false
}

is_textual :: proc(d: Domain) -> bool {
	return d == .Strings || d == .Chars
}

// --- polynômes entiers ---

as_poly :: proc(t: ^Expr) -> (Poly, bool) {
	#partial switch v in t^ {
	case Poly:
		return v, true
	case Set:
		if ints_count(v.ints) == 1 && set_count(v) == 1 {
			c, _ := ints_default(v.ints)
			return Poly{const = c}, true
		}
	}
	return {}, false
}

// poly_type : la forme normale d'un polynôme ; sans monôme, c'est un atome.
poly_type :: proc(p: Poly) -> ^Expr {
	if len(p.monos) == 0 do return new_expr(set_of_ints(ints_point(p.const)))
	return new_expr(p)
}

mono_less :: proc(a, b: Mono) -> bool {
	if len(a.vars) != len(b.vars) do return len(a.vars) < len(b.vars)
	for v, i in a.vars do if v != b.vars[i] do return v < b.vars[i]
	return false
}

// poly_of : trie, fusionne les monômes égaux, retire les coefficients nuls.
poly_of :: proc(monos: []Mono, c: i128) -> (Poly, bool) {
	sorted := slice.clone(monos)
	slice.sort_by(sorted, mono_less)
	out := make([dynamic]Mono, 0, len(sorted))
	for m in sorted {
		if len(out) > 0 && slice.equal(out[len(out) - 1].vars, m.vars) {
			s, ok := add_checked(out[len(out) - 1].coef, m.coef)
			if !ok do return {}, false
			out[len(out) - 1].coef = s
		} else {
			append(&out, m)
		}
	}
	kept := make([dynamic]Mono, 0, len(out))
	for m in out do if m.coef != 0 do append(&kept, m)
	return Poly{kept[:], c}, true
}

poly_add :: proc(a, b: Poly) -> (Poly, bool) {
	all := make([dynamic]Mono, 0, len(a.monos) + len(b.monos))
	append(&all, ..a.monos)
	append(&all, ..b.monos)
	c, ok := add_checked(a.const, b.const)
	if !ok do return {}, false
	return poly_of(all[:], c)
}

poly_scale :: proc(a: Poly, s: i128) -> (Poly, bool) {
	out := make([]Mono, len(a.monos))
	for m, i in a.monos {
		c, ok := mul_checked(m.coef, s)
		if !ok do return {}, false
		out[i] = Mono{c, m.vars}
	}
	c, ok := mul_checked(a.const, s)
	if !ok do return {}, false
	return poly_of(out, c)
}

poly_sub :: proc(a, b: Poly) -> (Poly, bool) {
	nb, ok := poly_scale(b, -1)
	if !ok do return {}, false
	return poly_add(a, nb)
}

poly_mul :: proc(a, b: Poly) -> (Poly, bool) {
	out := make([dynamic]Mono)
	c: i128 = 0
	for x in with_const(a) {
		for y in with_const(b) {
			coef, ok := mul_checked(x.coef, y.coef)
			if !ok do return {}, false
			vars := make([dynamic]int, 0, len(x.vars) + len(y.vars))
			append(&vars, ..x.vars)
			append(&vars, ..y.vars)
			slice.sort(vars[:])
			if len(vars) > 0 {
				append(&out, Mono{coef, vars[:]})
				continue
			}
			sum, s_ok := add_checked(c, coef)
			if !s_ok do return {}, false
			c = sum
		}
	}
	return poly_of(out[:], c)
}

// with_const : les monômes et la constante, la constante comme monôme vide.
with_const :: proc(p: Poly) -> []Mono {
	out := make([dynamic]Mono, 0, len(p.monos) + 1)
	append(&out, ..p.monos)
	if p.const != 0 do append(&out, Mono{p.const, nil})
	return out[:]
}

// poly_envelope : les valeurs d'un polynôme, par intervalles, sans énumérer.
// `exact` quand chaque inconnue y apparaît une fois, de coefficient ±1 : la somme
// d'ensembles indépendants est alors exacte.
poly_envelope :: proc(k: ^Kernel, p: Poly) -> (sum: Ints, exact: bool) {
	sum = ints_point(p.const)
	exact = true
	for m in p.monos {
		exact &&= len(m.vars) == 1 && abs(m.coef) == 1
		prod := ints_point(m.coef)
		for i := 0; i < len(m.vars); {
			j := i
			for j < len(m.vars) && m.vars[j] == m.vars[i] do j += 1
			ok: bool
			prod, ok = ints_arith(.Mul, prod, ints_pow(k.symbols[m.vars[i]].ints, j - i))
			exact &&= ok
			i = j
		}
		ok: bool
		sum, ok = ints_arith(.Add, sum, prod) // une borne qui déborde devient infinie
		exact &&= ok
	}
	return
}

// --- flottants, chaînes, comparaisons : constructeurs normalisants ---

term_of :: proc(op: Term_Op, args: ..^Expr) -> ^Expr {
	return new_expr(Term{op = op, args = slice.clone(args)})
}

// ordered : les opérandes d'une opération commutative dans un ordre fixé.
ordered :: proc(a, b: ^Expr) -> (^Expr, ^Expr) {
	if expr_less(b, a) do return b, a
	return a, b
}

expr_less :: proc(a, b: ^Expr) -> bool {
	return print_expr(a) < print_expr(b)
}

float_add :: proc(a, b: ^Expr) -> ^Expr {
	x, y := ordered(a, b)
	return term_of(.F_Add, x, y)
}

float_mul :: proc(a, b: ^Expr) -> ^Expr {
	if is_float_atom(a, 1) do return b // x · 1.0 = x, exactement
	if is_float_atom(b, 1) do return a
	x, y := ordered(a, b)
	return term_of(.F_Mul, x, y)
}

float_neg :: proc(a: ^Expr) -> ^Expr {
	if s, ok := a^.(Set); ok do return new_expr(set_of_floats(floats_neg(s.floats)))
	if t, ok := a^.(Term); ok && t.op == .F_Neg do return t.args[0] // -(-x) = x
	return term_of(.F_Neg, a)
}

is_float_atom :: proc(e: ^Expr, v: f64) -> bool {
	s, ok := e^.(Set)
	return ok && floats_count(s.floats) == 1 && set_count(s) == 1 && floats_contains(s.floats, v)
}

// concat : un mot. Les parties connues voisines fusionnent en une chaîne ; tout
// connu, c'est un atome ; le mot vide disparaît. Un caractère inconnu seul reste
// dans un mot, qui est une chaîne.
concat :: proc(k: ^Kernel, a, b: ^Expr) -> ^Expr {
	parts := make([dynamic]^Expr)
	append_parts(&parts, a)
	append_parts(&parts, b)
	if len(parts) == 0 do return new_expr(set_of_strings(strings_point("")))
	if len(parts) == 1 {
		if d, ok := value_domain(k, parts[0]); ok && d == .Strings do return parts[0]
	}
	return new_expr(Term{op = .Concat, args = parts[:]})
}

append_parts :: proc(parts: ^[dynamic]^Expr, e: ^Expr) {
	if t, ok := e^.(Term); ok && t.op == .Concat {
		for p in t.args do append_parts(parts, p)
		return
	}
	s, known := e^.(Set)
	if !known {
		append(parts, e)
		return
	}
	word, _ := strings_single(as_strings(s))
	if word == "" do return // le mot vide ne change rien
	if len(parts) > 0 {
		if last, last_known := parts[len(parts) - 1]^.(Set); last_known {
			prev, _ := strings_single(as_strings(last))
			parts[len(parts) - 1] = new_expr(set_of_strings(strings_point(fmt.tprintf("%s%s", prev, word))))
			return
		}
	}
	append(parts, new_expr(set_of_strings(strings_point(word))))
}

// repeat_term : un texte répété un nombre de fois connu est un mot ; un compte
// inconnu garde la répétition.
repeat_term :: proc(k: ^Kernel, text, count: ^Expr) -> (^Expr, Arith_Status) {
	if n, ok := as_poly(count); ok && len(n.monos) == 0 {
		if n.const < 0 do return nil, .Invalid
		if n.const > MAX_REPEAT do return nil, .Unsupported
		r := new_expr(set_of_strings(strings_point("")))
		for _ in 0 ..< n.const do r = concat(k, r, text)
		return r, .Ok
	}
	return term_of(.Repeat, text, count), .Ok
}

// --- comparaisons ---

Compare_Op :: enum u8 {
	Lt,
	Le,
	Gt,
	Ge,
	Eq,
	Ne,
}

// int_compare : `a ⋈ b` à partir de p = a - b, décidé quand les valeurs de p le
// décident, en forme normale sinon.
int_compare :: proc(k: ^Kernel, op: Compare_Op, p: Poly) -> (^Expr, Arith_Status) {
	q := p
	kind := Term_Op.Lt
	ok := true
	switch op {
	case .Lt:
	case .Gt:
		q, ok = poly_scale(p, -1)
	case .Le:
		q, ok = poly_add(p, Poly{const = -1}) // p ≤ 0 ⇔ p - 1 < 0
	case .Ge:
		q, ok = poly_scale(p, -1)
		if ok do q, ok = poly_add(q, Poly{const = -1})
	case .Eq:
		kind = .Eq
	case .Ne:
		kind = .Ne
	}
	if !ok do return nil, .Unsupported
	if len(q.monos) == 0 do return bool_atom(decide_int(kind, q.const)), .Ok
	vals, _ := values_of(k, new_expr(q))
	lo, hi := ints_bounds(vals.ints)
	#partial switch kind {
	case .Lt:
		if h, h_ok := hi.?; h_ok && h < 0 do return bool_atom(true), .Ok
		if l, l_ok := lo.?; l_ok && l >= 0 do return bool_atom(false), .Ok
	case .Eq, .Ne:
		if !ints_contains(vals.ints, 0) do return bool_atom(kind == .Ne), .Ok
		if ints_count(vals.ints) == 1 do return bool_atom(kind == .Eq), .Ok
	}
	// Normalisation : diviser par le pgcd des coefficients, fixer le signe.
	g: i128 = 0
	for m in q.monos do g = gcd(g, abs(m.coef))
	monos := make([]Mono, len(q.monos))
	for m, i in q.monos do monos[i] = Mono{m.coef / g, m.vars}
	c := q.const
	if kind == .Lt {
		c = floor_div(c, g) // g·r + c < 0 ⇔ r + ⌊c/g⌋ < 0
	} else {
		if c % g != 0 do return bool_atom(kind == .Ne), .Ok // g·r = -c n'a pas de solution entière
		c = c / g
		if monos[0].coef < 0 {
			for &m in monos do m.coef = -m.coef
			c = -c
		}
	}
	return term_of(kind, new_expr(Poly{monos, c})), .Ok
}

decide_int :: proc(kind: Term_Op, c: i128) -> bool {
	#partial switch kind {
	case .Lt:
		return c < 0
	case .Eq:
		return c == 0
	}
	return c != 0
}

// general_compare : sur une sorte sans forme polynomiale. Décidé quand les valeurs
// le décident ; sinon `>` et `>=` s'écrivent `<` et `<=` en échangeant, `=` et
// `!=` ordonnent leurs opérandes.
general_compare :: proc(k: ^Kernel, op: Compare_Op, a, b: ^Expr) -> (^Expr, Arith_Status) {
	// Deux formes normales égales sont la même valeur.
	if expr_equal(k, a, b) do return bool_atom(op == .Eq || op == .Le || op == .Ge), .Ok
	va, _ := values_of(k, a)
	vb, _ := values_of(k, b)
	#partial switch op {
	case .Eq, .Ne:
		verdict := equal_verdict(va, vb)
		if card(verdict) == 1 {
			if op == .Ne do verdict = ~verdict
			return new_expr(set_of_bools(verdict)), .Ok
		}
		x, y := ordered(a, b)
		return term_of(op == .Eq ? .Eq : .Ne, x, y), .Ok
	}
	verdict, ok := order_verdict(op, va, vb)
	if !ok do return nil, .Invalid
	if card(verdict) == 1 do return new_expr(set_of_bools(verdict)), .Ok
	#partial switch op {
	case .Lt:
		return term_of(.Lt, a, b), .Ok
	case .Le:
		return term_of(.Le, a, b), .Ok
	case .Gt:
		return term_of(.Lt, b, a), .Ok
	}
	return term_of(.Le, b, a), .Ok
}

gcd :: proc(a, b: i128) -> i128 {
	x, y := a, b
	for y != 0 do x, y = y, x % y
	return x
}

floor_div :: proc(a, b: i128) -> i128 {
	q := a / b
	if (a % b != 0) && ((a < 0) != (b < 0)) do q -= 1
	return q
}

bool_atom :: proc(v: bool) -> ^Expr {
	return new_expr(set_of_bools(bools_point(v)))
}

// --- valeurs possibles ---

// values_of : les valeurs possibles d'un type de valeur, exactes (`exact`) quand
// on peut énumérer ses inconnues, sur-approchées sinon.
values_of :: proc(k: ^Kernel, t: ^Expr) -> (vals: Set, exact: bool) {
	#partial switch v in t^ {
	case Set:
		return v, true
	case Poly, Term:
		if s, ok := enumerate(k, t); ok do return s, true
		vals, _ = envelope(k, t)
		return vals, false
	}
	return {}, false
}

// envelope : les valeurs possibles d'une forme, sans énumérer. `exact` quand
// aucune inconnue ne s'y répète et que l'opération est exacte sur des ensembles
// indépendants (une somme ±x ± y…, une concaténation de mots) ; sur-approchées
// sinon.
envelope :: proc(k: ^Kernel, t: ^Expr) -> (vals: Set, exact: bool) {
	#partial switch v in t^ {
	case Set:
		return v, true
	case Poly:
		ints, ints_exact := poly_envelope(k, v)
		return set_of_ints(ints), ints_exact
	case Term:
		arg :: proc(k: ^Kernel, t: Term, i: int) -> Set {
			s, _ := envelope(k, t.args[i])
			return s
		}
		switch v.op {
		case .Sym:
			return k.symbols[v.sym], true
		case .F_Add:
			return set_of_floats(floats_arith(.Add, arg(k, v, 0).floats, arg(k, v, 1).floats)), false
		case .F_Mul:
			return set_of_floats(floats_arith(.Mul, arg(k, v, 0).floats, arg(k, v, 1).floats)), false
		case .F_Neg:
			return set_of_floats(floats_neg(arg(k, v, 0).floats)), false
		case .Concat:
			l := strings_point("")
			for i in 0 ..< len(v.args) do l = strings_concat(l, as_strings(arg(k, v, i)))
			return set_of_strings(l), words_independent(v)
		case .Repeat:
			r, ok := strings_repeat(as_strings(arg(k, v, 0)), arg(k, v, 1).ints)
			if !ok do return set_of_strings(strings_all()), false
			return set_of_strings(r), false
		case .Lt, .Le, .Eq, .Ne:
			return set_of_bools({.False, .True}), false
		}
	}
	return {}, false
}

// words_independent : un mot dont chaque partie est connue ou une inconnue qui ne
// s'y répète pas — ses valeurs sont exactement la concaténation des ensembles.
words_independent :: proc(t: Term) -> bool {
	seen := make(map[int]bool, allocator = context.temp_allocator)
	for a in t.args {
		#partial switch v in a^ {
		case Set:
			continue
		case Term:
			if v.op == .Sym && !seen[v.sym] {
				seen[v.sym] = true
				continue
			}
		}
		return false
	}
	return true
}

// --- énumération exacte ---

Char_Atom :: distinct i128

Atom :: union {
	i128,
	f64,
	Char_Atom,
	string,
	bool,
}

enumerate :: proc(k: ^Kernel, t: ^Expr) -> (Set, bool) {
	syms := make([dynamic]int)
	collect_symbols(t, &syms)
	slice.sort(syms[:])
	ids := slice.unique(syms[:])
	domains := make([][]Atom, len(ids))
	total := 1
	for id, i in ids {
		atoms, ok := atoms_of_set(k.symbols[id], ENUMERATION_LIMIT)
		if !ok do return {}, false
		total *= len(atoms)
		if total > ENUMERATION_LIMIT do return {}, false
		domains[i] = atoms
	}
	results := make([dynamic]Atom)
	env := make([]Atom, len(k.symbols))
	index := make([]int, len(ids))
	for {
		for id, i in ids do env[id] = domains[i][index[i]]
		a, ok := eval(t, env)
		if !ok do return {}, false
		append(&results, a)
		// le compteur suivant, comme un odomètre
		i := 0
		for i < len(ids) {
			index[i] += 1
			if index[i] < len(domains[i]) do break
			index[i] = 0
			i += 1
		}
		if i == len(ids) do break
	}
	return set_of_atoms(results[:]), true
}

collect_symbols :: proc(t: ^Expr, out: ^[dynamic]int) {
	#partial switch v in t^ {
	case Poly:
		for m in v.monos do append(out, ..m.vars)
	case Term:
		if v.op == .Sym do append(out, v.sym)
		for a in v.args do collect_symbols(a, out)
	}
}

// atoms_of_set : tous les éléments d'un ensemble, s'il en a au plus `limit`.
atoms_of_set :: proc(s: Set, limit: int) -> ([]Atom, bool) {
	if domain_count(s, .Scopes) > 0 do return nil, false // des scopes ne s'énumèrent pas en atomes
	out := make([dynamic]Atom)
	for iv in s.ints.intervals {
		lo, lo_ok := iv.lo.?
		hi, hi_ok := iv.hi.?
		if !lo_ok || !hi_ok || !narrow(lo, hi, limit) do return nil, false
		for v := lo; v <= hi; v += 1 do append(&out, v)
	}
	for iv in s.chars.intervals {
		lo, _ := iv.lo.?
		hi, _ := iv.hi.?
		if !narrow(lo, hi, limit) do return nil, false
		for v := lo; v <= hi; v += 1 do append(&out, Char_Atom(v))
	}
	if floats_count(s.floats) > 1 do return nil, false
	if floats_count(s.floats) == 1 {
		v, _ := floats_default(s.floats)
		append(&out, v)
	}
	if s.strings.re != nil {
		words, ok := strings_words(s.strings, limit)
		if !ok do return nil, false
		for w in words do append(&out, w)
	}
	if .False in s.bools do append(&out, false)
	if .True in s.bools do append(&out, true)
	return out[:], len(out) <= limit
}

// narrow : lo..hi a moins de `limit` éléments, sans déborder (hi - lo peut
// dépasser I128_MAX).
narrow :: proc(lo, hi: i128, limit: int) -> bool {
	if lo > I128_MAX - i128(limit) do return true
	return hi < lo + i128(limit)
}

set_of_atoms :: proc(atoms: []Atom) -> Set {
	ints := make([dynamic]i128)
	chars := make([dynamic]i128)
	floats := make([dynamic]Float_Interval)
	words := make([dynamic]string)
	bools: Bools
	for a in atoms {
		switch v in a {
		case i128:
			append(&ints, v)
		case Char_Atom:
			append(&chars, i128(v))
		case f64:
			append(&floats, Float_Interval{lo = v, hi = v})
		case string:
			append(&words, v)
		case bool:
			bools += {v ? .True : .False}
		}
	}
	return Set {
		ints = ints_of_points(ints[:]),
		floats = floats_of(floats[:]),
		chars = ints_of_points(chars[:]),
		strings = strings_of_words(words[:]),
		bools = bools,
	}
}

// ints_of_points : l'ensemble de ces entiers, les suites consécutives en intervalles.
ints_of_points :: proc(points: []i128) -> Ints {
	slice.sort(points)
	runs := make([dynamic]Int_Interval)
	for v in points {
		if len(runs) > 0 {
			last := &runs[len(runs) - 1]
			if hi, _ := last.hi.?; v - 1 <= hi { 	// v ≥ -I128_MAX : v - 1 ne déborde pas
				last.hi = max(hi, v)
				continue
			}
		}
		append(&runs, Int_Interval{v, v})
	}
	return ints_of(runs[:])
}

// atom_of : la valeur d'un atome connu.
atom_of :: proc(s: Set) -> (Atom, bool) {
	atoms, ok := atoms_of_set(s, 1)
	if !ok || len(atoms) != 1 do return nil, false
	return atoms[0], true
}

// eval : la valeur de `t` quand chaque inconnue `id` vaut env[id].
eval :: proc(t: ^Expr, env: []Atom) -> (Atom, bool) {
	#partial switch v in t^ {
	case Set:
		return atom_of(v)
	case Poly:
		sum := v.const
		for m in v.monos {
			prod := m.coef
			for id in m.vars {
				x, is_int := env[id].(i128)
				if !is_int do return nil, false
				p, ok := mul_checked(prod, x)
				if !ok do return nil, false
				prod = p
			}
			s, ok := add_checked(sum, prod)
			if !ok do return nil, false
			sum = s
		}
		return sum, true
	case Term:
		args := make([]Atom, len(v.args))
		for a, i in v.args {
			x, ok := eval(a, env)
			if !ok do return nil, false
			args[i] = x
		}
		switch v.op {
		case .Sym:
			return env[v.sym], true
		case .F_Add, .F_Mul:
			x, x_ok := args[0].(f64)
			y, y_ok := args[1].(f64)
			if !x_ok || !y_ok do return nil, false
			return v.op == .F_Add ? x + y : x * y, true
		case .F_Neg:
			x, ok := args[0].(f64)
			return -x, ok
		case .Concat:
			b := strings.builder_make()
			for a in args do strings.write_string(&b, atom_text(a))
			return strings.to_string(b), true
		case .Repeat:
			n, ok := args[1].(i128)
			if !ok || n < 0 || n > MAX_REPEAT do return nil, false
			return strings.repeat(atom_text(args[0]), int(n)), true
		case .Lt, .Le, .Eq, .Ne:
			if len(args) == 1 {
				p, ok := args[0].(i128)
				return decide_int(v.op, p), ok
			}
			return compare_atoms(v.op, args[0], args[1])
		}
	}
	return nil, false
}

// atom_text : un caractère ou une chaîne, comme chaîne.
atom_text :: proc(a: Atom) -> string {
	#partial switch v in a {
	case string:
		return v
	case Char_Atom:
		if i128(v) == CHAR_EMPTY do return ""
		return fmt.tprintf("%c", rune(v))
	}
	return ""
}

compare_atoms :: proc(op: Term_Op, a, b: Atom) -> (Atom, bool) {
	if op == .Eq || op == .Ne do return atom_equal(a, b) == (op == .Eq), true
	less, ok := atom_less(a, b)
	if !ok do return nil, false
	if op == .Lt do return less, true
	greater, _ := atom_less(b, a)
	return !greater, true // a <= b
}

atom_equal :: proc(a, b: Atom) -> bool {
	switch x in a {
	case i128:
		y, ok := b.(i128)
		return ok && x == y
	case f64:
		y, ok := b.(f64)
		return ok && x == y
	case Char_Atom:
		y, ok := b.(Char_Atom)
		return ok && x == y
	case string:
		y, ok := b.(string)
		return ok && x == y
	case bool:
		y, ok := b.(bool)
		return ok && x == y
	}
	return false
}

atom_less :: proc(a, b: Atom) -> (bool, bool) {
	#partial switch x in a {
	case i128:
		y, ok := b.(i128)
		return x < y, ok
	case f64:
		y, ok := b.(f64)
		return x < y, ok
	case Char_Atom:
		y, ok := b.(Char_Atom)
		return x < y, ok
	}
	return false, false
}

// --- égalité des formes ---

expr_equal :: proc(k: ^Kernel, a, b: ^Expr) -> bool {
	if a == nil || b == nil do return a == b
	#partial switch x in a^ {
	case Set:
		y, ok := b^.(Set)
		return ok && atoms_subset(x, y) && atoms_subset(y, x)
	case Poly:
		y, ok := b^.(Poly)
		if !ok || x.const != y.const || len(x.monos) != len(y.monos) do return false
		for m, i in x.monos {
			if m.coef != y.monos[i].coef || !slice.equal(m.vars, y.monos[i].vars) do return false
		}
		return true
	case Term:
		y, ok := b^.(Term)
		if !ok || x.op != y.op || x.sym != y.sym || len(x.args) != len(y.args) do return false
		for e, i in x.args do if !expr_equal(k, e, y.args[i]) do return false
		return true
	case Family:
		y, ok := b^.(Family)
		return ok && family_equal(x, y)
	case ^Scope:
		return value_equal(k, a, b)
	}
	return false
}

// --- impression ---

printed_poly :: proc(p: Poly) -> (string, Level) {
	b := strings.builder_make()
	for m, i in p.monos {
		coef := m.coef
		if i > 0 {
			strings.write_string(&b, coef < 0 ? " - " : " + ")
			coef = abs(coef)
		} else if coef < 0 {
			strings.write_byte(&b, '-')
			coef = -coef
		}
		if coef != 1 do fmt.sbprintf(&b, "%d*", coef)
		for v, j in m.vars {
			if j > 0 do strings.write_byte(&b, '*')
			fmt.sbprintf(&b, "??%d", v)
		}
	}
	if p.const > 0 do fmt.sbprintf(&b, " + %d", p.const)
	if p.const < 0 do fmt.sbprintf(&b, " - %d", -p.const)
	level := Level.TERM
	if len(p.monos) == 1 && p.const == 0 {
		m := p.monos[0]
		switch {
		case m.coef == 1 && len(m.vars) == 1:
			level = .PRIMARY
		case m.coef == -1 && len(m.vars) == 1:
			level = .UNARY
		case:
			level = .FACTOR
		}
	}
	return strings.to_string(b), level
}

// printed_term : les opérandes d'une opération flottante sont tous entre
// parenthèses s'il le faut — `(a + b) + c` n'est pas `a + (b + c)` en IEEE.
printed_term :: proc(t: Term) -> (string, Level) {
	infix :: proc(args: []^Expr, symbol: string, operand: Level) -> string {
		parts := make([]string, len(args))
		for a, i in args do parts[i] = print_at(a, operand)
		return strings.join(parts, symbol)
	}
	switch t.op {
	case .Sym:
		return fmt.tprintf("??%d", t.sym), .PRIMARY
	case .F_Neg:
		return fmt.tprintf("-%s", print_at(t.args[0], .CALL)), .UNARY
	case .F_Add, .Concat:
		return infix(t.args, " + ", above(.TERM)), .TERM
	case .F_Mul, .Repeat:
		return infix(t.args, " * ", above(.FACTOR)), .FACTOR
	case .Lt, .Le:
		if len(t.args) == 1 do return fmt.tprintf("%s %s 0", print_at(t.args[0], above(.COMPARISON)), t.op == .Lt ? "<" : "<="), .COMPARISON
		return infix(t.args, t.op == .Lt ? " < " : " <= ", above(.COMPARISON)), .COMPARISON
	case .Eq, .Ne:
		if len(t.args) == 1 do return fmt.tprintf("%s %s 0", print_at(t.args[0], above(.EQUALITY)), t.op == .Eq ? "=" : "!="), .EQUALITY
		return infix(t.args, t.op == .Eq ? " = " : " != ", above(.EQUALITY)), .EQUALITY
	}
	return "", .PRIMARY
}
