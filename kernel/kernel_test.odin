package kernel

import "core:encoding/json"
import "core:fmt"
import "core:log"
import vmem "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:testing"

// Un cas : la source, le scope typé attendu (vide = ne pas comparer) et les
// erreurs attendues.
Case :: struct {
	source: string,
	typed:  string,
	errors: []Error_Kind,
}

CASES := []Case {
	{"x -> 1\ny -> x + 2", "{x -> 1  y -> 3}", {}},
	{"u8:a -> ??\nu8:b -> ??\nu16:c -> a + b", "{0..255:a -> ??0  0..255:b -> ??1  0..65535:c -> ??0 + ??1}", {}},
	{"u8:a -> ??\nu8:d -> a + a", "", {.Constraint_Mismatch}},
	{"u8 -> 5", "", {}}, // un builtin n'est qu'un nom : un binding peut le masquer
	{"e -> 0..255\nf -> >0", "{e -> {-> 0..255}  f -> {-> 1..}}", {}},
	{"Port -> u16 & >0\nPort:p -> 0", "", {.Constraint_Mismatch}},
	{"Port -> u16 & >0\nPort:p -> 8080", "", {}},
	{"none:i -> 5", "", {.Constraint_Mismatch}},
	{"none:i -> none", "{none:i -> none}", {}}, // la seule valeur que none admet
	{"none:i", "{none:i -> none}", {}},
	{"u8:i -> none", "", {.Constraint_Mismatch}}, // none n'est pas un élément de 0..255
	{"x -> none", "{x -> none}", {}},
	{"true:check -> 2 = 2", "{true:check -> true}", {}},
	{"true:oops -> 2 = 3", "", {.Constraint_Mismatch}},
	{"((u8 | i8) & >10):x -> 42", "{11..255:x -> 42}", {}},
	{"n -> ??::u8\nn:x -> 5", "", {.Insoluble_Constraint}},
	{"~5:x -> 6", "", {}},
	{"~5:x -> 5", "", {.Constraint_Mismatch}},
	// ~ se prend dans les sortes portées, et les garde : ~~X = X, même par une ref
	{"X -> u8 | string\nY -> ~X\n(~Y):x -> \"a\"", "", {}},
	{"a -> ~bool\nb -> ~a\nc -> 0 & 1\nd -> u8 & string\ne -> ~c", "{a -> ~bool  b -> {-> bool}  c -> ~int  d -> none  e -> {-> int}}", {}},
	// les scopes : type_of(scope{Σ b}) = { scope{Σ type_of(b)} }
	{"b -> {\n  n -> ??::u8\n  -> n * 2\n}\nc -> b.n\nd -> b!", "{b -> {-> {n -> ??0  -> 2*??0}}  c -> ??0  d -> 2*??0}", {}},
	// les inconnues : des formes normales, des valeurs exactes quand on peut les énumérer
	{"n -> ??::u8\na -> n - n\nb -> n * 3 + n\nc -> (n + 1) * 2", "{n -> ??0  a -> 0  b -> 4*??0  c -> 2*??0 + 2}", {}},
	{"n -> ??::u8\nu8:e -> n - n", "", {}},
	{"n -> ??::u8\nm -> ??::u8\nu16:f -> n * m", "", {}},
	{"n -> ??::u8\nm -> ??::u8\nu8:f -> n * m", "", {.Constraint_Mismatch}},
	{"n -> ??::u8\ntrue:g -> n < n + 1", "", {}},
	{"n -> ??::u8\nfalse:i -> 2 * n = 3", "", {}},
	{"s -> ??::string\nw -> \"a\" + s + \"b\" + \"c\"", "{s -> ??0  w -> \"a\" + ??0 + \"bc\"}", {}},
	{"x -> ??::f64\ny -> (x + 0.1) + 0.2\ntrue:r -> x + 1.0 = 1.0 + x", "", {}},
	// les ensembles qui dépendent d'inconnues : la table de leurs valeurs
	{"n -> ??::(0..3)\na -> (n | 6) & (n | 7)", "{n -> ??0  a -> {-> 0  -> 1  -> 2  -> 3}}", {}},
	{"n -> ??::(0..3)\n(n | 0..3):e -> 2", "", {}}, // une table constante est un ensemble
	{"n -> ??::(0..3)\n(n..10):g -> 5", "", {.Insoluble_Constraint}},
	// trop d'inconnues pour énumérer : l'enveloppe (une valeur), jamais une couleur
	{"n -> ??::u64\na -> (n | 6) & >3", "{n -> ??0  a -> {-> ⊆ 4..18446744073709551615}}", {}},
	{"n -> ??::u64\n(n..10):g -> 5", "", {.Insoluble_Constraint}},
	// la vérification par paliers : enveloppe, affine, extrêmes linéaires, énumération ;
	// ce qu'on ne sait pas prouver est dit, jamais accepté
	{"n -> ??::u64\nm -> ??::u64\nu64:d -> n + m", "", {.Constraint_Mismatch}},
	{"u16:z -> (??::u8) * (??::u8)", "", {}},
	{"n -> ??::u64\n(~6):x -> n * 2 + 1", "", {}},
	{"n -> ??::u64\n(~5):x -> n * 2 + 1", "", {.Constraint_Mismatch}},
	{"n -> ??::u64\nm -> ??::u64\n(~5):x -> n * 2 + m * 4 + 1", "", {.Unproven}},
	{"(\"a\" + string):v -> \"b\" + ??::string", "", {.Constraint_Mismatch}},
	// bidirectionnel : la couleur descend dans un scope littéral
	{"Point -> {\n  u8:x\n  u8:y\n}\nPoint:p -> {x -> ??  y -> 2}", "", {}},
	{"Point -> {\n  u8:x\n  u8:y\n}\nLine -> {\n  Point:a\n  Point:b\n}\nLine:l -> {a -> {x -> ??  y -> 1}  b -> {x -> 3  y -> ??}}", "", {}},
	{"box -> {\n  x -> 1\n  y -> x\n  x -> 2\n}\na -> box.x\nb -> box.y\nc -> box.x#0", "", {}},
	{"empty -> {x -> 1}\ne -> empty!", "{empty -> {-> {x -> 1}}  e -> none}", {}},
	{"Point -> {\n  u8:x\n  u8:y\n}\nPoint:p\nq -> p.x", "", {}},
	{"Point -> {\n  u8:x\n  u8:y\n}\nPoint:r -> {x -> 1 y -> 300}", "", {.Constraint_Mismatch}},
	{"Role -> {\n  -> \"member\"\n  -> \"admin\"\n}\nRole:a -> \"admin\"\nRole:c\nd -> c", "", {}},
	{"Role -> {\n  -> \"member\"\n  -> \"admin\"\n}\nRole:b -> \"guest\"", "", {.Constraint_Mismatch}},
	{"F32OrString -> {\n  -> f32:\n  -> string:\n}\nF32OrString:a -> 0.5\nF32OrString:b -> \"x\"", "", {}},
	{"F32OrString -> {\n  -> f32:\n  -> string:\n}\nF32OrString:c -> 3", "", {.Constraint_Mismatch}},
	{"r -> >0.5 & <1.0\nr:a -> 0.75\nr:d", "", {}},
	{"r -> >0.5 & <1.0\nr:b -> 1.0", "", {.Constraint_Mismatch}},
	// les chaînes : des langages réguliers, l'égalité par double inclusion
	{"true:a -> (..10 * \"ab\") = (\"ab\" * 0..10)", "", {}},
	{"(..10 * \"ab\"):x -> \"abab\"", "", {}},
	{"(..10 * \"ab\"):x -> \"aba\"", "", {.Constraint_Mismatch}},
	{"true:a -> (2|1) = (2..1)", "", {}},
	{"true:a -> (2|\"a\"|3..4) = (\"a\"|2..4)", "", {}},
	{"a -> 'a'..'z' * 2..3 + \"!\"\na:x -> \"ab!\"\na:y -> \"a!\"", "", {.Constraint_Mismatch}},
	{"(\"jwt\"..\"lel\"):x -> \"jwtXlel\"", "", {}},
	{"(\"a\"..\"z\"):c -> 'b'", "", {.Constraint_Mismatch}}, // \"a\"..\"z\" : commence par a, finit par z
	{"('a'..'z'):c -> 'b'", "", {}}, // 'a'..'z' : un caractère de a à z
	{"(~'\\0' * 0.. + '\\0'):s -> \"a\\0c\\0\"", "", {.Constraint_Mismatch}},
	{"(~'\\0' * 0.. + '\\0'):s -> \"abc\\0\"", "", {}},
	{"(~\"piro\"):s -> \"pira\"", "", {}},
	{"x -> ''..", "{x -> {-> char}}", {}}, // ''.. : n'importe quel caractère
	// les caractères : une sorte, admise par une couleur string
	{"string:s -> 'c'", "", {}},
	{"char:c -> \"a\"", "", {.Constraint_Mismatch}},
	{"true:a -> 'a' = \"a\"", "", {.Constraint_Mismatch}},
	{"a -> 'a' + 'b'", "{a -> \"ab\"}", {}},
	{"char:c", "{char:c -> ''}", {}},
	{"y -> x", "", {.Undefined_Identifier}},
	{"a -> {x -> 1}\nb -> a.z", "", {.Invalid_Property_Access}},
}

@(test)
test_cases :: proc(t: ^testing.T) {
	for c in CASES {
		arena: vmem.Arena
		context.allocator = vmem.arena_allocator(&arena)
		typed, k, parsed := run(c.source)
		testing.expectf(t, parsed, "parse : %q", c.source)
		if parsed {
			got := error_kinds(k.errors[:])
			testing.expectf(t, slice.equal(got, sorted_kinds(c.errors)), "%q\n  erreurs : %v, attendu %v\n  %s", c.source, got, c.errors, describe_errors(k.errors[:]))
			if c.typed != "" {
				printed := print_expr(new_expr(typed))
				testing.expectf(t, printed == c.typed, "%q\n  typé    : %s\n  attendu : %s", c.source, printed, c.typed)
			}
		}
		vmem.arena_destroy(&arena)
	}
}

// Le corpus de test/typecheck : chaque source dont toutes les formes sont dans le
// kernel doit donner exactement les erreurs attendues. Les sources qui touchent
// une forme pas encore implémentée sont comptées à part.
Corpus_Case :: struct {
	name:          string `json:"name"`,
	source:        string `json:"source"`,
	expect_errors: []string `json:"expect_errors"`,
}

// Les cas du corpus dont l'attente encode un comportement du proto que la
// sémantique du kernel tranche autrement. Chaque entrée dit pourquoi.
Divergence :: struct {
	name:   string,
	expect: []string,
	reason: string,
}

DIVERGENCES := []Divergence {
	{"tc_insoluble_scope_field", {}, "le champ inconnu ??::u8 est typé et a un défaut (0) : la couleur Shape reste un seul ensemble"},
	{"tc_ident_no_trail_bad", {}, "'' est le caractère vide : ''*0.. vaut \"\", donc ~(''*0.. + '_') exclut seulement \"_\""},
}

expected_errors :: proc(c: Corpus_Case) -> []string {
	for d in DIVERGENCES do if d.name == c.name do return d.expect
	return c.expect_errors
}

@(test)
test_typecheck_corpus :: proc(t: ^testing.T) {
	arena: vmem.Arena
	context.allocator = vmem.arena_allocator(&arena)
	defer vmem.arena_destroy(&arena)

	dir, _ := filepath.join({filepath.dir(#location().file_path), "..", "test", "typecheck", "tests"}, context.allocator)
	pattern, _ := filepath.join({dir, "*.json"}, context.allocator)
	files, _ := filepath.glob(pattern)
	slice.sort(files)
	passed, passed_with_errors, skipped, unparsed := 0, 0, 0, 0
	failures := make([dynamic]string)
	for f in files {
		data, err := os.read_entire_file(f, context.allocator)
		if err != nil do continue
		c: Corpus_Case
		if json.unmarshal(data, &c) != nil do continue
		_, k, parsed := run(c.source)
		if !parsed {
			unparsed += 1
			continue
		}
		if has_unsupported(k.errors[:]) {
			skipped += 1
			continue
		}
		got := make([dynamic]string)
		for kind in error_kinds(k.errors[:]) do append(&got, fmt.tprint(kind))
		want := slice.clone(expected_errors(c))
		slice.sort(want)
		want = slice.unique(want)
		if slice.equal(got[:], want) {
			passed += 1
			if len(want) > 0 do passed_with_errors += 1
		} else {
			append(&failures, fmt.tprintf("%s : obtenu %v, attendu %v\n    %s\n%s", c.name, got, want, describe_errors(k.errors[:]), indent(c.source)))
		}
	}
	log.infof("corpus typecheck : %d passent (dont %d qui attendent une erreur), %d échouent, %d hors du kernel, %d ne parsent pas (sur %d)", passed, passed_with_errors, len(failures), skipped, unparsed, len(files))
	for f in failures do log.info(f)
}

error_kinds :: proc(errors: []Error) -> []Error_Kind {
	out := make([dynamic]Error_Kind)
	for e in errors do append(&out, e.kind)
	return sorted_kinds(out[:])
}

sorted_kinds :: proc(kinds: []Error_Kind) -> []Error_Kind {
	out := slice.clone(kinds)
	slice.sort(out)
	return slice.unique(out)
}

has_unsupported :: proc(errors: []Error) -> bool {
	for e in errors do if e.kind == .Unsupported do return true
	return false
}

describe_errors :: proc(errors: []Error) -> string {
	parts := make([dynamic]string)
	for e in errors do append(&parts, fmt.tprintf("%v: %s", e.kind, e.message))
	return strings.join(parts[:], " ; ")
}

indent :: proc(s: string) -> string {
	lines, _ := strings.split_lines(s)
	for &l in lines do l = fmt.tprintf("      | %s", l)
	return strings.join(lines, "\n")
}
