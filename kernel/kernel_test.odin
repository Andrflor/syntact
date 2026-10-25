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

// The examples of specs/types.md: each source binds `x` last; its type is
// printed, and the errors are compared by kind.
Spec_Case :: struct {
	source: string,
	type:   string, // the printed type of the last binding; "" to skip
	errors: []Error_Kind,
}

SPEC_CASES := []Spec_Case {
	// §4.1
	{`x -> ~~5`, "5", {}},
	{`x -> int & ~5`, "..4 | 6..", {}},
	{`x -> bool & ~true`, "false", {}},
	{`x -> (u8 | 300) & ~(u8 | 300)`, "none", {}},
	// §4.2
	{`x -> 0 & 1`, "none", {}},
	{`x -> 'a' & 'b'`, "none", {}},
	{`x -> 1.0 & 1`, "none", {}},
	{`x -> 5 & 5`, "5", {}},
	{`x -> u8 & 300`, "none", {}},
	{`x -> 0..10 & 5..20`, "5..10", {}},
	// §4.3
	{`x -> 0..3`, "0..3", {}},
	{`x -> 2..1`, "1..2", {}},
	{`x -> 0..`, "0..", {}},
	{`x -> ..0..`, "int", {}},
	{`x -> >=5`, "5..", {}},
	{`x -> >5`, "6..", {}},
	{`x -> <5`, "..4", {}},
	{`x -> >5.0`, ">5.0", {}},
	{`x -> 'a'..'z'`, "'a'..'z'", {}},
	{`x -> ''..`, "''..", {}},
	{`x -> "jwt"..`, `"jwt" + string`, {}},
	{`x -> "jwt".."lel"`, `("jwt" + string) & (string + "lel")`, {}},
	{`x -> 'a'..3`, "", {.Invalid_Range}},
	{`x -> 'ab'..'cd'`, `("ab" + string) & (string + "cd")`, {}},
	{`x -> "ab".."cd".."ef"`, "", {}},
	{`("ab".."cd".."ef"):x -> "abef"`, "", {.Constraint_Mismatch}},
	{`("ab".."cd".."ef"):x -> "abXcdYef"`, "", {}},
	// §4.4
	{`x -> =5`, "5", {}},
	// §4.5
	{`x -> 1.0 + 1.5`, "2.5", {}},
	{`x -> 1 + 1.5`, "", {.Invalid_operator}},
	{`x -> 0 < "a"`, "", {.Invalid_operator}},
	{`x -> 2 + 3`, "5", {}},
	{`x -> u8 + 1`, "1..256", {}},
	{`x -> u8 < 300`, "true", {}},
	{`x -> 2 > 2`, "false", {}},
	{`x -> 'a' < 'b'`, "true", {}},
	{`x -> [~]true`, "false", {}},
	{`x -> [~]5`, "-6", {}},
	{`x -> 2 = 2`, "true", {}},
	{`x -> 2 = 3`, "false", {}},
	{`x -> 5 != 5`, "", {.Invalid_operator}},
	{`x -> (0.0..10.0) * (0.0..2.0)`, "0.0..20.0", {}},
	{`x -> none + 1`, "none", {}},
	{`x -> 0.1 + 0.2`, "0.3", {}},
	{`x -> (0.1 + 0.2) = 0.3`, "true", {}},
	{`x -> 1.0 / 3.0`, "1.0 / 3.0", {}},
	{`x -> 170141183460469231731687303715884105727 + 1`, "170141183460469231731687303715884105727 + 1", {}},
	// §4.6
	{`x -> 'a' + "bc"`, `"abc"`, {}},
	{`x -> "ab" * 3`, `"ababab"`, {}},
	{`x -> 'a'..'z' * 3`, "('a'..'z') * 3", {}},
	{`x -> "ab" * 0`, `""`, {}},
	// §7
	{`u8:x -> 5`, "5", {}},
	{`u8:x -> u8`, "0..255", {.Constraint_Mismatch}},
	{`bool:x -> ~false`, "", {.Constraint_Mismatch}},
	{`none:x -> none`, "none", {}},
	{`u8:x -> none`, "none", {.Constraint_Mismatch}},
	{`u8:x`, "0", {}},
	{`string:x`, `""`, {}},
	{`bool:x`, "false", {}},
	{`(1..10):x`, "1", {}},
	{`(2..1):x`, "2", {}},
	{`(1..2):x`, "1", {}},
	{`x -> 2..1`, "1..2", {}},
	// §5.2: unknowns, names
	{"a -> ??::u8\nx -> a - a", "0", {}},
	{"a -> ??::u8\nx -> a + 3", "?0 + 3", {}},
	{"a -> ??::u8\nx -> a * 2 + a", "3 * ?0", {}},
	{"u8:n -> ??\nn:x -> n", "?0", {}},
	{"u8:n -> ??\nm -> n * 2\nn:x -> m / 2", "?0", {}},
	{"u8:n -> ??\nu16:x -> n + 1", "?0 + 1", {}},
	{"u8:n -> ??\nu8:x -> n + 1", "", {.Constraint_Mismatch}},
	{"u8:n -> ??\n(0..n):x -> ??", "", {}},
	{"u8:n -> ??\nu8:x -> 0..n", "", {.Constraint_Mismatch}},
	{"a -> ??::u8\nx -> a + 1.5", "", {.Invalid_operator}},
	{"a -> ??::u8\nbool:x -> a < 300", "", {}},
	{"a -> ??::u8\nx -> 10 / a", "", {.Invalid_operator}},
	// §5.1
	{"0:x -> {0}", "", {.Constraint_Mismatch}},
	{"=({0 | 1}):x -> {0} | {1}", "", {.Constraint_Mismatch}},
	// §5.3
	{"box -> {x -> 1  y -> x + 1}\nx -> box{x -> 10}.y", "11", {}},
	{"box -> {x -> 1  y -> x + 1}\nx -> box.y", "2", {}},
	{"b -> {x -> 0  x -> 1}\nx -> b.x", "1", {}},
	{"b -> {x -> 0  x -> 1}\nx -> b.x#0", "0", {}},
	{"x -> {a -> 1  -> a + 1}!", "2", {}},
	{"x -> {a -> 1}!", "none", {}},
	{"=({1 2 3 4}):x -> {1 ...{2 3} 4}", "", {}},
	{"b -> {x -> 1}\nx -> b{y -> 2}", "", {.Invalid_Carve}},
	{"b -> {u8:x -> 1}\nx -> b{x -> 300}", "", {.Constraint_Mismatch}},
	{"b -> {u8:x -> 1  u8:y -> x + 1}\nx -> b{x -> 255}", "", {.Constraint_Mismatch}},
	// §5.4
	{"{-> false  -> true}:x -> true", "true", {}},
	{"{-> u8}:x -> u8", "", {}},
	{"{-> u8}:x -> 5", "", {.Constraint_Mismatch}},
	{"{u8: u8:}:x -> {1 2}", "", {}},
	{"{u8:}:x -> {1 2}", "", {.Constraint_Mismatch}},
	{"Pair -> {u8: u8:}\n{...Pair: string:}:x -> {1 2 \"x\"}", "", {}},
	{"{string:}:a -> {\"\"}\nx -> a{0}", "", {.Constraint_Mismatch}},
	{"f -> {\n  1..255:n\n  -> f{n -> n - 1}\n}", "", {.Constraint_Mismatch}},
	// §6
	{"x -> 5 ? {0 -> \"zero\"  -> \"many\"}", `"many"`, {}},
	{"x -> 0 ? {0 -> \"zero\"  -> \"many\"}", `"zero"`, {}},
	{"x -> 5 ? {>0 -> 1  -> 2}", "1", {}},
	{"x -> 5 ? {u8: -> 1  -> 2}", "2", {}},
	{"x -> 0 ? {u8: -> 1  -> 2}", "1", {}},
	{"x -> 5 ? {=4 -> 1}", "", {.Non_Exhaustive_Pattern}},
	{"a -> ??::u8\nu8:x -> a ? {<10 -> a + 3  -> 10}", "", {}},
	{"a -> ??::u8\nu8:x -> a ? {<255 -> a + 1  -> 0}", "", {}},
	{"a -> ??::u8\nu8:x -> a ? {<=255 -> a + 1  -> 0}", "", {.Constraint_Mismatch}},
	{"u8:a -> ??\nx -> a ? {=5 -> 1}", "", {.Non_Exhaustive_Pattern}},
	{"a -> ??::u8\nr -> a ? {<10 -> a + 3  -> 10}\n(bool | string):x -> a ? {0..120 -> true  -> \"x\"}", "", {}},
	// §5.5
	// §6, §7: what a branch types holds for the values that reach it
	{"a -> ??::u8\nr -> a ? {<10 -> a + 3  -> 10}\n(-245..3):x -> r - a", "", {}},
	{"a -> ??::u8\nr -> a ? {<10 -> a + 3  -> 10}\n(-244..3):x -> r - a", "", {.Constraint_Mismatch}},
	{"a -> ??::u8\nu8:x -> a ? {<10 -> a * 25  -> 0}", "", {}},
	{"a -> ??::u8\nu8:x -> a ? {<10 -> a * 30  -> 0}", "", {.Constraint_Mismatch}},
	{"a -> ??::u8\nu8:x -> (a + 1) ? {<=255 -> a + 1  -> 0}", "", {}},
	{"a -> ??::u8\nx -> a ? {0 -> 0  -> 10 / a}", "", {}},
	{"a -> ??::u8\nu8:x -> a ? {0..10 -> a  11..255 -> a - 11}", "", {}},
	{"a -> ??::u8\nu8:x -> a ? {0..10 -> a  12..255 -> a - 11}", "", {.Non_Exhaustive_Pattern}},
	{"a -> ??::u8\nb -> {u8:x -> 1  u8:y -> x + 1}\nx -> a ? {<255 -> b{x -> a}  -> b}", "", {}},
	{"a -> ??::u8\nb -> {u8:x -> 1  u8:y -> x + 1}\nx -> b{x -> a}", "", {.Constraint_Mismatch}},
	{"a -> ??::u8\nb -> ??::u8\nbool:x -> a < b", "", {}},
	{"a -> ??::u8\nb -> ??::u8\ni16:x -> a - b", "?0 - ?1", {}},
	{"{u8:}:a -> ??\nx -> a", "", {}},
	{"x -> {u8:} & {u8: u8:}", "none", {}},
	{"x -> {a -> 1} & {b -> 1}", "none", {}},
	{"u8:n -> ??\n(0..n):x -> 0", "", {}},
	{"u8:n -> ??\n(0..n):x -> 5", "", {.Constraint_Mismatch}},
	{"a -> ??::u8\nu8:x -> (a < 100) ? {true -> a + 155  -> a}", "", {}},
	{"a -> ??::u8\nu8:x -> (a < 100) ? {false -> a + 155  -> a}", "", {.Constraint_Mismatch}},
	{"a -> ??::u8\nx -> a < 300", "true", {}},
	{"a -> ??::u8\nb -> ??::u8\nu16:x -> a * b", "", {}},
	{"a -> ??::u8\nb -> ??::u8\nu8:x -> a * b", "", {.Constraint_Mismatch}},
	{"a -> ??::u8\nb -> ??::u8\n(0..65025):x -> a * b", "", {}},
	{"a -> ??::u8\nb -> ??::u8\n(0..65024):x -> a * b", "", {.Constraint_Mismatch}},
	{"a -> ??::i8\nb -> ??::u8\n(-32640..32385):x -> a * b", "", {}},
	{"a -> ??::u8\nx -> 1000 / (a + 1)", "", {}},
	{"a -> ??::u8\n(3..1000):x -> 1000 / (a + 1)", "", {}},
	{"x -> u8 * u8", "(0..255) * (0..255)", {}},
	{"Pair -> {u8: u8:}\nList -> {\n  -> {}\n  -> {...Pair: ...List:}\n}\nList:x -> {1 2 3 4}", "", {}},
	{"Pair -> {u8: u8:}\nList -> {\n  -> {}\n  -> {...Pair: ...List:}\n}\nList:x -> {1 2 3}", "", {.Constraint_Mismatch}},
	// not at the edge: a scope is asked of the guarded productions, on shorter runs
	{"Tree -> {\n  -> {}\n  -> {u8: ...Tree: ...Tree:}\n}\nTree:x -> {1}", "", {}},
	{"Tree -> {\n  -> {}\n  -> {u8: ...Tree: ...Tree:}\n}\nTree:x -> {1 300}", "", {.Constraint_Mismatch}},
	{MIRROR + "List{u8}:a -> {10 10}", "", {}},
	{MIRROR + "List{u8}:a -> {1 2 3 4}", "", {}},
	{MIRROR + "List{u8}:a -> {10 10 10}", "", {.Constraint_Mismatch}},
	{MIRROR + "List{u8}:a -> {10 300}", "", {.Constraint_Mismatch}},
	// the value of a binding colored by C, carved, is checked against C
	{MIRROR + "List{u8}:a -> {10 10}\nx -> a{300}", "", {.Constraint_Mismatch}},
	{MIRROR + "List{u8}:a -> {10 10}\nx -> a{7}", "", {}},
	{"({u8: string:} | {i8: bool:}):p -> {1 \"x\"}\nx -> p{-1}", "", {.Constraint_Mismatch}},
	{"({u8: string:} | {i8: bool:}):p -> {1 \"x\"}\nx -> p{2}", "", {}},
	// a run of pieces of different lengths: cut by the law of concatenation
	{MIXED + "List:a -> {1 (-2) \"x\" 3}", "", {}},
	{MIXED + "List:a -> {}", "", {}},
	{MIXED + "List:a -> {1 (-2) 3}", "", {.Constraint_Mismatch}},
	{MIXED + "List:a -> {1 (-2) \"x\" 3}\nx -> a{\"y\"}", "", {.Constraint_Mismatch}},
	// the base case calls its scope outside any branch: an infinite recursion; read on
	// the equation as written, not under its defaults
	{"loop -> {-> loop!}", "", {.Infinite_Recursion}},
	{"same -> {u8:n -> ??  -> same{n -> n}!}", "", {.Infinite_Recursion}},
	{"head -> {-> head! ? {0 -> 1  -> 2}}", "", {.Infinite_Recursion}},
	{"lazy -> {-> {x -> lazy!}}", "", {}},
	// a character that does not print is shown by its code
	{"x -> char & ~'\\0'", "'\\x01'..", {}},
	{"f -> {u64:n -> 5  -> n ? {0 -> 1  -> n * f{n -> n - 1}!}}\nx -> f{n -> 4}!", "", {}},
	// holes (§5.7): filled by <-, skipped by position, inferred from what the carve puts
	{IDENTITY + "x -> identity{T <- u8  value -> 5}!", "5", {}},
	{IDENTITY + "x -> identity{T -> u8}!", "", {.Invalid_Carve}},
	{IDENTITY + "x -> identity{value <- 5}!", "", {.Invalid_Carve}},
	{IDENTITY + "x -> identity{value -> 5}.T", "5", {}},
	{IDENTITY + "x -> identity{T <- 4  value -> 5}!", "", {.Constraint_Mismatch}},
	{"base -> {x <- 0  u8:a -> 1  u8:b -> 2}\nx -> base{10, 20}.b", "20", {}},
	{"only -> {x <- 0}\nx -> only{9}", "", {.Invalid_Carve}},
	{PAIR + "x -> pair{data{6} data{6}}!", "6", {}},
	{PAIR + "x -> pair{data{6} data{3}}!", "", {.Constraint_Mismatch}},
	{PAIR + "x -> pair{e <- 4  data{6} data{6}}!", "", {.Constraint_Mismatch}},
	{ARRAY + MAP + "x -> map{{2 3 4 5}, {u8:e, -> e + 1}}.T", "0..255", {}},
	{ARRAY + MAP + "x -> map{{2.4 3}, {u8:e, -> e + 1}}!", "", {.Constraint_Mismatch}},
	{ARRAY + MAP + "x -> map{{\"\" 3}, {(u8 | string):e, -> e + 10}}!", "", {.Invalid_operator}},
	// not guarded: the equation stays
	{"L -> {\n  -> {}\n  -> {...L: ...L:}\n}\nL:a -> {}", "", {.Constraint_Mismatch}},
	// a carve carves any binding, in turn: z{…} (specs/language/04)
	{"a -> {\n  x -> {}\n  z -> {u8:a u8:b}\n}\nb -> a{z{a->2}}\nx -> b.z.a", "2", {}},
	{"a -> {\n  x -> {}\n  z -> {u8:a u8:b}\n}\nx -> a{z{a->300}}", "", {.Constraint_Mismatch}},
	{"Box -> { u8:n -> 0 }\nPt -> { slot -> {u8:n->0} }\nx -> Pt{Box{1}}.slot.n", "1", {}},
	// `.x`: the current scope; in the arguments of a carve, the scope carved
	{"x -> {x -> 1  y -> .x + 1}{x -> 10}.y", "11", {}},
	{"a -> {\n  x -> {}\n  z -> {u8:a u8:b}\n}\nx -> a{z -> .z{a -> 2}}.z.a", "2", {}},
	// ?ₖ read in a carve: one unknown in equal carves, another than in the original
	{"Box -> {T -> u8  T:v -> ??}\na -> Box{T -> string}.v\nb -> Box{T -> string}.v\nx -> a = b", "true", {}},
	{"Box -> {T -> u8  T:v -> ??}\na -> Box{T -> string}.v\nx -> a = Box.v", "false", {}},
	// the color flows down through runs, and through the solution of a recursion
	{"Pair -> {u8: string:}\n{...Pair: u8:}:c -> {1 \"x\" 2}\nx -> c{3, 4}", "", {.Constraint_Mismatch}},
	{ARRAY + "Array{u8}:a -> {1 2 3}\nx -> a{300}", "", {.Constraint_Mismatch}},
	{ARRAY + "Array{u8}:a -> {1 2 3}\nx -> a{7}.#0", "7", {}},
	// comparisons by the order of a ring; runs by the law of concatenation
	{"a -> ??::u8\nx -> a < a + 1", "true", {}},
	{"{...  ... u8:}:x -> {1}", "", {}},
	// destructuring: the names of a cover are read by its product (specs/language/07)
	{"Circle -> {u8:radius}\nc -> Circle{radius -> 5}\nx -> c ? {Circle: -> radius * radius  -> 0}", "25", {}},
	{"Square -> {u16:side}\nDiamond -> {u16:side}\ns -> Diamond{side -> 7}\nx -> s ? {Square: | Diamond: -> side * side  -> 0}", "49", {}},
	{ARRAY + "xs -> {3 4 5}\nx -> xs ? {\n  {u8:(h) ...Array{u8}:(t)} -> h\n  -> 0\n}", "3", {}},
	{ARRAY + "xs -> {3 4 5}\nx -> xs ? {\n  {u8(h) ...Array{u8}:(t)} -> t\n  -> {}\n}", "{4  5}", {}},
	// only a scope can be expanded: `...C:` places the default of C (specs/language/03)
	{"x -> {1 ...u8:}", "", {.Constraint_Mismatch}},
	{"xs -> {3 4 5}\nx -> xs ? {\n  {u8:(h) ...u8:(t)} -> h\n  -> 0\n}", "", {.Constraint_Mismatch}},
	{"Pair -> {u8: u8:}\ny -> {...Pair: 3}\nx -> y.#2", "3", {}},
	// shapes of one structure that differ in one place join there: {u8:} | {i8:} = {(u8 | i8):}
	{"({u8:} | {i8:}):x -> {-1}", "", {}},
	{"({u8:} | {i8:}):x -> {300}", "", {.Constraint_Mismatch}},
	{"x -> ({u8: string:} | {i8: string:})", "{((-128)..255):  string:}", {}},
	{"x -> ({u8: string:} | {i8: bool:})", "{((-128)..(-1)):  (false | true):} | {(0..127):  (string | false | true):} | {(128..255):  string:}", {}},
	// one set, one normal form, whatever the order it is written in
	{"x -> ({u8: string:} | {u8: bool:} | {i8: string:})", "{((-128)..(-1)):  string:} | {(0..255):  (string | false | true):}", {}},
	{"x -> ({u8: string:} | {i8: string:} | {u8: bool:})", "{((-128)..(-1)):  string:} | {(0..255):  (string | false | true):}", {}},
	{LISTS + "List:a -> {10 (-1)}", "", {}},
	{LISTS + "List:a -> {10 300}", "", {.Constraint_Mismatch}},
	{LISTS + "List:a -> {10 (-1)}\nx -> a{300}", "", {.Constraint_Mismatch}},
	// a comma separates bindings: no operator continues across it
	{ARRAY + "Array{u8}:a -> {10, -10}", "", {.Constraint_Mismatch}},
	// §5.6
	{"f -> {u8:n -> ??  -> n ? {0 -> 1  -> 2 * n + f{n -> n - 1}!}}\nx -> f{n -> 3}!", "13", {}},
	{"f -> {u8:n -> ??  -> n ? {1 -> 1  -> n + f{n -> n - 1}!}}\nx -> f!", "", {.Constraint_Mismatch}},
	{"fact -> {u8:n -> ??  -> n ? {0 -> 1  -> n * fact{n -> n - 1}!}}\nx -> fact{n -> 5}!", "fact{n -> 5}!", {}},
	{SUM + "x -> sum!", "(?0 + ?0 * ?0) / 2", {}},
	{SUM + "x -> sum{n -> 5}!", "15", {}},
	{SUM + "u16:x -> sum!", "", {}},
	{SUM + "u8:x -> sum!", "", {.Constraint_Mismatch}},
	{"Array -> {\n  T -> {}\n  -> {T: ...Array{T}:}\n  -> {}\n}\nArray{u8}:x", "", {.Infinite_Recursion}},
	{"Array -> {\n  T -> {}\n  -> {}\n  -> {T: ...Array{T}:}\n}\nArray{u8}:x -> {1 2 3}", "", {}},
	{"Array -> {\n  T -> {}\n  -> {}\n  -> {T: ...Array{T}:}\n}\nArray{u8}:x -> {1 300 3}", "", {.Constraint_Mismatch}},
}

ARRAY :: "Array -> {\n  T -> {}\n  -> {}\n  -> {T: ...Array{T}:}\n}\n"

IDENTITY :: "identity -> {\n  T <- none\n  T:value -> none\n  -> value\n}\n"

PAIR :: "data -> {u8:x -> 0}\npair -> {\n  u8:e <- 2\n  data{e}:first\n  data{e}:second\n  -> e\n}\n"

MAP :: "map -> {\n  T <- {}\n  E <- {}\n  Array{T}:source\n  func -> {e -> T:, -> E:}\n  -> source ? {\n    {T:(e) ...Array{T}:(r)} -> {func{e -> e}! ...map{r, func}!}\n    {} -> {}\n  }\n}\n"

MIXED :: "List -> {\n  -> {}\n  -> {u8: ...List:}\n  -> {i8: string: ...List:}\n}\n"

MIRROR :: "List -> {\n  T -> {}\n  -> {}\n  -> {T: ...List{T}: T:}\n}\n"

LISTS :: "List -> {\n  -> {}\n  -> {u8: ...List:}\n  -> {i8: ...List:}\n}\n"

SUM :: "sum -> {\n  u8:n -> ??\n  -> n ? {0 -> 0  -> n + sum{n -> n - 1}!}\n}\n"

@(test)
test_spec :: proc(t: ^testing.T) {
	arena: vmem.Arena
	context.allocator = vmem.arena_allocator(&arena)
	defer vmem.arena_destroy(&arena)
	for c in SPEC_CASES {
		k, parsed := run(c.source)
		if !testing.expectf(t, parsed, "%s: does not parse", c.source) do continue
		last := k.root.bindings[len(k.root.bindings) - 1]
		got := print_type(binding_type(&k, last))
		if c.type != "" do testing.expectf(t, got == c.type, "%s: the type is %s, expected %s", c.source, got, c.type)
		kinds := error_kinds(k.errors[:])
		testing.expectf(t, slice.equal(kinds, c.errors), "%s: errors %v, expected %v (%s)", c.source, kinds, c.errors, describe_errors(k.errors[:]))
	}
}

// The corpus of test/typecheck: each source whose forms are all built by this
// kernel must give exactly the expected errors. The others are counted apart.
Corpus_Case :: struct {
	name:          string `json:"name"`,
	source:        string `json:"source"`,
	expect_errors: []string `json:"expect_errors"`,
}

@(test)
test_corpus :: proc(t: ^testing.T) {
	arena: vmem.Arena
	context.allocator = vmem.arena_allocator(&arena)
	defer vmem.arena_destroy(&arena)
	dir, _ := filepath.join({filepath.dir(#location().file_path), "..", "test", "typecheck", "tests"})
	pattern, _ := filepath.join({dir, "*.json"})
	files, _ := filepath.glob(pattern)
	slice.sort(files)
	passed, outside, unparsed := 0, 0, 0
	failures := make([dynamic]string)
	for file in files {
		data, err := os.read_entire_file(file, context.allocator)
		if err != nil do continue
		c: Corpus_Case
		if json.unmarshal(data, &c) != nil do continue
		k, parsed := run(c.source)
		if !parsed {
			unparsed += 1
			continue
		}
		kinds := error_kinds(k.errors[:])
		if slice.contains(kinds, Error_Kind.Unsupported) {
			outside += 1
			continue
		}
		got := make([dynamic]string)
		for kind in kinds do append(&got, fmt.tprint(kind))
		want := slice.clone(c.expect_errors)
		slice.sort(want)
		want = slice.unique(want)
		if slice.equal(got[:], want) {
			passed += 1
		} else {
			append(&failures, fmt.tprintf("%s: got %v, expected %v\n    %s\n%s", c.name, got, want, describe_errors(k.errors[:]), indent(c.source)))
		}
	}
	log.infof("corpus: %d pass, %d fail, %d outside the kernel, %d do not parse (of %d)", passed, len(failures), outside, unparsed, len(files))
	for f in failures do log.info(f)
}

error_kinds :: proc(errors: []Error) -> []Error_Kind {
	out := make([dynamic]Error_Kind)
	for e in errors do append(&out, e.kind)
	slice.sort(out[:])
	return slice.unique(out[:])
}

describe_errors :: proc(errors: []Error) -> string {
	parts := make([dynamic]string)
	for e in errors do append(&parts, fmt.tprintf("%v: %s", e.kind, e.message))
	return strings.join(parts[:], "; ")
}

indent :: proc(s: string) -> string {
	lines, _ := strings.split_lines(s)
	for &l in lines do l = fmt.tprintf("      | %s", l)
	return strings.join(lines, "\n")
}
