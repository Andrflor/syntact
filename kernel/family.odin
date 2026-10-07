package kernel

import syn "../compiler"
import "core:fmt"
import "core:slice"
import "core:strings"

// LES ENSEMBLES QUI DÉPENDENT D'INCONNUES
//
// `n..10`, `??::u8 & >10`, `n | 6` : un ensemble par valeur des inconnues. Sa forme
// normale est la table complète — symboles triés, valeurs énumérées dans l'ordre
// de leur ensemble, le premier symbole variant le plus vite. La corrélation est
// gardée : `(n | 6) & (n | 7)` vaut {n} pour chaque n. Une table constante est son
// ensemble. Comme type, une table désigne plusieurs ensembles : ce n'est pas un
// singleton, donc pas une couleur (Insoluble).

Family :: struct {
	syms: []int,
	sets: []Set,
}

// Subsets : un ensemble qui dépend de trop d'inconnues pour être énuméré. On n'en
// garde que l'enveloppe — l'union de tous les ensembles possibles : le type est
// « un ensemble inclus dans `upper` ». C'est une sur-approximation, valable pour
// une valeur ; ce n'est jamais un singleton, donc jamais une couleur.
Subsets :: struct {
	upper: Set,
}

Set_Op_Kind :: enum u8 {
	Union,
	Inter,
	Comp,
	Arith,
	Range,
	Half, // >x, <x, >=x, <=x, !=x
}

Set_Op :: struct {
	kind:    Set_Op_Kind,
	arith:   Arith,
	half:    syn.Operator_Kind,
	lo_open: bool,
	hi_open: bool,
}

// set_operation : applique `op` à des types d'ensembles. Tous connus, c'est un
// ensemble ; sinon, la table de ses valeurs pour chaque valeur des inconnues.
set_operation :: proc(k: ^Kernel, op: Set_Op, span: syn.Span, args: ..^Expr) -> ^Expr {
	known := make([]Set, len(args))
	all_known := true
	for a, i in args {
		s, ok := known_set(a)
		known[i] = s
		all_known &&= ok
	}
	if all_known {
		r, status := apply_set_op(op, known)
		if status != .Ok do return set_op_failure(k, op, status, span, args)
		return singleton(new_expr(r))
	}
	families := make([]Family, len(args))
	for a, i in args {
		f, status := family_of(k, a)
		switch status {
		case .Ok:
			families[i] = f
		case .Too_Large:
			return enveloped(k, op, span, args)
		case .Not_Set:
			return report(k, .Unsupported, span, fmt.tprintf("pas encore dans le kernel : cette opération sur %s", print_expr(a)))
		}
	}
	syms, domains, ok := joint_domains(k, families)
	if !ok do return enveloped(k, op, span, args)
	total := 1
	for d in domains do total *= len(d)
	sets := make([]Set, total)
	digits := make([]int, len(syms))
	operands := make([]Set, len(families))
	for j in 0 ..< total {
		for f, i in families do operands[i] = f.sets[sub_index(f, syms, domains, digits)]
		r, status := apply_set_op(op, operands)
		if status != .Ok do return set_op_failure(k, op, status, span, args)
		sets[j] = r
		odometer(digits, domains)
	}
	return family_expr(syms, radices(domains), sets)
}

// enveloped : l'opération sur les enveloppes des opérandes. Chaque opération est
// monotone sur les enveloppes, sauf le complément, dont l'enveloppe est toute la
// sorte, et `!=x`, qui couvre toute la sorte dès que x a plusieurs valeurs.
enveloped :: proc(k: ^Kernel, op: Set_Op, span: syn.Span, args: []^Expr) -> ^Expr {
	uppers := make([]Set, len(args))
	for a, i in args {
		u, ok := upper_of(k, a)
		if !ok do return report(k, .Unsupported, span, fmt.tprintf("pas encore dans le kernel : cette opération sur %s", print_expr(a)))
		uppers[i] = u
	}
	r: Set
	status := Arith_Status.Ok
	switch op.kind {
	case .Union, .Inter, .Arith:
		r, status = apply_set_op(op, uppers)
	case .Range:
		r, status = range_set(uppers[0], op.lo_open, uppers[1], op.hi_open) // l'enveloppe de toutes les plages
	case .Comp:
		r = sorts_of(uppers[0])
	case .Half:
		r, status = half_envelope(op.half, uppers[0])
	}
	if status != .Ok do return set_op_failure(k, op, status, span, args)
	if set_is_empty(r) do return singleton(new_expr(r)) // inclus dans ∅ : c'est ∅
	return new_expr(Subsets{r})
}

// upper_of : l'enveloppe d'un type d'ensemble — l'union de ses ensembles possibles.
upper_of :: proc(k: ^Kernel, t: ^Expr) -> (Set, bool) {
	if s, ok := known_set(t); ok do return s, true
	#partial switch v in t^ {
	case Family:
		u := Set{}
		for s in v.sets do u = set_union(u, s)
		return u, true
	case Subsets:
		return v.upper, true
	case Poly, Term:
		vals, _ := values_of(k, t) // une valeur inconnue, vue comme l'ensemble d'elle-même
		return vals, true
	}
	return {}, false
}

// sorts_of : toutes les valeurs des sortes qu'un ensemble porte.
sorts_of :: proc(s: Set) -> Set {
	return set_complement(Set{sorts = carried(s)})
}

// half_envelope : l'union de `>x` pour tout x de `xs` (et de même pour les autres).
half_envelope :: proc(kind: syn.Operator_Kind, xs: Set) -> (Set, Arith_Status) {
	d, pure := pure_domain(xs)
	if !pure || (d != .Ints && d != .Floats) do return {}, .Invalid
	if kind == .NotEqual do return sorts_of(xs), .Ok
	if d == .Ints {
		l, h := ints_bounds(xs.ints)
		if kind == .Greater || kind == .GreaterEqual {
			if v, ok := l.?; ok do return half_line(kind, set_of_ints(ints_point(v)))
		} else {
			if v, ok := h.?; ok do return half_line(kind, set_of_ints(ints_point(v)))
		}
		return sorts_of(xs), .Ok
	}
	l, h := floats_bounds(xs.floats)
	if kind == .Greater || kind == .GreaterEqual {
		if v, ok := l.?; ok do return half_line(kind, set_of_floats(floats_point(v)))
	} else {
		if v, ok := h.?; ok do return half_line(kind, set_of_floats(floats_point(v)))
	}
	return sorts_of(xs), .Ok
}

set_op_failure :: proc(k: ^Kernel, op: Set_Op, status: Arith_Status, span: syn.Span, args: []^Expr) -> ^Expr {
	parts := make([dynamic]string)
	for a in args do append(&parts, print_expr(a))
	operands := strings.join(parts[:], ", ")
	if status == .Unsupported do return report(k, .Unsupported, span, fmt.tprintf("pas encore dans le kernel : %v sur %s", op.kind, operands))
	if op.kind == .Range || op.kind == .Half {
		return report(k, .Invalid_Range, span, fmt.tprintf("les bornes d'un intervalle sont des nombres, des caractères ou des chaînes de même sorte : %s", operands))
	}
	return report(k, .Invalid_operator, span, fmt.tprintf("%v ne s'applique pas à %s", op.kind, operands))
}

apply_set_op :: proc(op: Set_Op, args: []Set) -> (Set, Arith_Status) {
	switch op.kind {
	case .Union:
		return set_union(args[0], args[1]), .Ok
	case .Inter:
		return set_intersect(args[0], args[1]), .Ok
	case .Comp:
		return set_complement(args[0]), .Ok
	case .Arith:
		return arith_sets(op.arith, args[0], args[1])
	case .Range:
		return range_set(args[0], op.lo_open, args[1], op.hi_open)
	case .Half:
		return half_line(op.half, args[0])
	}
	return {}, .Invalid
}

// family_expr : la forme normale d'une table. On retire les inconnues dont elle ne
// dépend pas ; sans inconnue, c'est son ensemble. Deux tables qui sont la même
// fonction ont alors les mêmes inconnues, donc la même écriture.
family_expr :: proc(syms: []int, radix: []int, sets: []Set) -> ^Expr {
	f, _ := prune(syms, radix, sets)
	if len(f.syms) == 0 do return singleton(new_expr(f.sets[0]))
	return new_expr(f)
}

prune :: proc(syms: []int, radix: []int, sets: []Set) -> (Family, []int) {
	syms, radix, sets := syms, radix, sets
	for j := 0; j < len(syms); {
		if depends_on(sets, radix, j) {
			j += 1
			continue
		}
		// la dimension j ne compte pas : on ne garde que sa première valeur
		stride := 1
		for r in radix[:j] do stride *= r
		kept := make([dynamic]Set, 0, len(sets) / radix[j])
		for s, i in sets do if (i / stride) % radix[j] == 0 do append(&kept, s)
		syms = slice.concatenate([][]int{syms[:j], syms[j + 1:]})
		radix = slice.concatenate([][]int{radix[:j], radix[j + 1:]})
		sets = kept[:]
	}
	return Family{syms, sets}, radix
}

// depends_on : la table change quand seule l'inconnue j change.
depends_on :: proc(sets: []Set, radix: []int, j: int) -> bool {
	stride := 1
	for r in radix[:j] do stride *= r
	for s, i in sets {
		d := (i / stride) % radix[j]
		if d > 0 && !same_set(s, sets[i - d * stride]) do return true
	}
	return false
}

same_set :: proc(a, b: Set) -> bool {
	return atoms_subset(a, b) && atoms_subset(b, a)
}

Family_Status :: enum u8 {
	Ok,
	Too_Large,
	Not_Set,
}

// family_of : la table d'un type d'ensemble — un ensemble connu (une table
// constante), une valeur inconnue (chaque valeur vue comme l'ensemble d'elle-même),
// ou une table.
family_of :: proc(k: ^Kernel, t: ^Expr) -> (Family, Family_Status) {
	if s, ok := known_set(t); ok {
		sets := make([]Set, 1)
		sets[0] = s
		return Family{nil, sets}, .Ok
	}
	#partial switch v in t^ {
	case Family:
		return v, .Ok
	case Subsets:
		return {}, .Too_Large // déjà une enveloppe : on reste sur les enveloppes
	case Poly, Term:
		found := make([dynamic]int)
		collect_symbols(t, &found)
		slice.sort(found[:])
		syms := slice.unique(found[:])
		domains, ok := symbol_domains(k, syms)
		if !ok do return {}, .Too_Large
		total := 1
		for d in domains do total *= len(d)
		sets := make([]Set, total)
		env := make([]Atom, len(k.symbols))
		digits := make([]int, len(syms))
		for j in 0 ..< total {
			for id, i in syms do env[id] = domains[i][digits[i]]
			a, a_ok := eval(t, env)
			if !a_ok do return {}, .Not_Set
			sets[j] = set_of_atoms({a})
			odometer(digits, domains)
		}
		f, _ := prune(syms, radices(domains), sets)
		return f, .Ok
	}
	return {}, .Not_Set
}

symbol_domains :: proc(k: ^Kernel, syms: []int) -> ([][]Atom, bool) {
	domains := make([][]Atom, len(syms))
	total := 1
	for id, i in syms {
		atoms, ok := atoms_of_set(k.symbols[id], ENUMERATION_LIMIT)
		if !ok do return nil, false
		total *= len(atoms)
		if total > ENUMERATION_LIMIT do return nil, false
		domains[i] = atoms
	}
	return domains, true
}

joint_domains :: proc(k: ^Kernel, families: []Family) -> ([]int, [][]Atom, bool) {
	all := make([dynamic]int)
	for f in families do append(&all, ..f.syms)
	slice.sort(all[:])
	syms := slice.unique(all[:])
	domains, ok := symbol_domains(k, syms)
	return syms, domains, ok
}

radices :: proc(domains: [][]Atom) -> []int {
	out := make([]int, len(domains))
	for d, i in domains do out[i] = len(d)
	return out
}

// sub_index : la case de la table `f` pour une valeur des symboles `syms`.
sub_index :: proc(f: Family, syms: []int, domains: [][]Atom, digits: []int) -> int {
	index, radix := 0, 1
	for id in f.syms {
		i, _ := slice.linear_search(syms, id)
		index += digits[i] * radix
		radix *= len(domains[i])
	}
	return index
}

// odometer : la valeur suivante des symboles, le premier variant le plus vite.
odometer :: proc(digits: []int, domains: [][]Atom) {
	for i in 0 ..< len(digits) {
		digits[i] += 1
		if digits[i] < len(domains[i]) do return
		digits[i] = 0
	}
}

// range_set : `lo..hi` sur des ensembles connus. C'est l'union des plages x..y pour
// x ∈ lo, y ∈ hi. Entre des nombres ou des caractères, c'est l'enveloppe de
// lo ∪ hi (`2..1` est `1..2`, `1..4..2..7` est `1..7`) : toute valeur entre deux
// bornes est entre une borne de lo et une borne de hi. Entre des chaînes, « commence
// par » et « finit par ». `..` seul, tout.
range_set :: proc(lo: Set, lo_open: bool, hi: Set, hi_open: bool) -> (Set, Arith_Status) {
	if lo_open && hi_open do return set_top(), .Ok
	ld, l_pure := pure_domain(lo)
	hd, h_pure := pure_domain(hi)
	if lo_open do ld, l_pure = hd, h_pure
	if hi_open do hd, h_pure = ld, l_pure
	if !l_pure || !h_pure do return {}, .Invalid
	both := set_union(lo, hi) // une borne ouverte est vide : elle ne compte pas
	switch {
	case ld == .Ints && hd == .Ints:
		l, h := ints_bounds(both.ints)
		return set_of_ints(ints_range(lo_open ? nil : l, hi_open ? nil : h)), .Ok
	case ld == .Chars && hd == .Chars:
		l, h := ints_bounds(both.chars)
		return set_of_chars(ints_range(lo_open ? CHAR_EMPTY : l, hi_open ? i128(MAX_RUNE) : h)), .Ok
	case ld == .Floats && hd == .Floats:
		f := both.floats.intervals
		hull := Float_Interval{f[0].lo, f[len(f) - 1].hi, f[0].lo_open, f[len(f) - 1].hi_open}
		if lo_open do hull.lo, hull.lo_open = nil, false
		if hi_open do hull.hi, hull.hi_open = nil, false
		return set_of_floats(floats_of({hull})), .Ok
	case is_textual(ld) && is_textual(hd):
		l := strings_all()
		if !lo_open do l = strings_prefixed(as_strings(lo))
		if !hi_open do l = strings_intersect(l, strings_suffixed(as_strings(hi)))
		return set_of_strings(l), .Ok
	}
	return {}, .Invalid
}

// half_line : `>x` est l'ensemble des nombres de la sorte de x plus grands que x.
half_line :: proc(kind: syn.Operator_Kind, x: Set) -> (Set, Arith_Status) {
	d, pure := pure_domain(x)
	if !pure || set_count(x) != 1 do return {}, .Invalid
	#partial switch d {
	case .Ints:
		v, _ := ints_default(x.ints)
		#partial switch kind {
		case .Greater:
			if v == I128_MAX do return set_of_ints({}), .Ok // aucun entier au-delà de l'univers
			return set_of_ints(ints_range(v + 1, nil)), .Ok
		case .GreaterEqual:
			return set_of_ints(ints_range(v, nil)), .Ok
		case .Less:
			if v == -I128_MAX do return set_of_ints({}), .Ok
			return set_of_ints(ints_range(nil, v - 1)), .Ok
		case .LessEqual:
			return set_of_ints(ints_range(nil, v)), .Ok
		}
		return set_of_ints(ints_complement(ints_point(v))), .Ok // !=
	case .Floats:
		v, _ := floats_default(x.floats)
		#partial switch kind {
		case .Greater:
			return set_of_floats(floats_of({Float_Interval{lo = v, lo_open = true}})), .Ok
		case .GreaterEqual:
			return set_of_floats(floats_of({Float_Interval{lo = v}})), .Ok
		case .Less:
			return set_of_floats(floats_of({Float_Interval{hi = v, hi_open = true}})), .Ok
		case .LessEqual:
			return set_of_floats(floats_of({Float_Interval{hi = v}})), .Ok
		}
		return set_of_floats(floats_complement(floats_point(v))), .Ok
	}
	return {}, .Invalid
}

family_equal :: proc(a, b: Family) -> bool {
	if !slice.equal(a.syms, b.syms) || len(a.sets) != len(b.sets) do return false
	for s, i in a.sets do if !same_set(s, b.sets[i]) do return false
	return true
}

// Une enveloppe s'écrit `{-> ⊆ U}` : un ensemble inclus dans U.
write_subsets :: proc(b: ^strings.Builder, s: Subsets) {
	fmt.sbprintf(b, "{{-> ⊆ %s}}", print_set(s.upper))
}

// Une table s'écrit comme le type qu'elle est : l'un de ses ensembles,
// `{-> S1 -> S2 …}`, dans l'ordre de leur écriture.
write_family :: proc(b: ^strings.Builder, f: Family) {
	printed := make([dynamic]string)
	for s in f.sets do append(&printed, print_set(s))
	slice.sort(printed[:])
	different := slice.unique(printed[:])
	strings.write_byte(b, '{')
	for p, i in different {
		if i > 0 do strings.write_string(b, "  ")
		fmt.sbprintf(b, "-> %s", p)
	}
	strings.write_byte(b, '}')
}
