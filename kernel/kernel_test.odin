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

// COUNTER: a scope whose run gives a counter, a resonant binding changed by an event.
COUNTER :: "Counter -> {\n  Change -> {u16:value}\n  -> {\n    u16:value >>- Change -> 0\n    Change -< e { value -<< e.value }\n    increment -> { >- Change{value -> value ? {<100 -> value + 1  -> value}} }\n    -> value\n  }\n}\n"

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
	// a run carved by place (§5.3)
	{"xs -> {1 2 3}\nx -> xs{#1 -> 9}", "{1  9  3}", {}},
	{"xs -> {1 2 3}\nx -> xs{#1 -> 9}.#1", "9", {}},
	{ARRAY + "A -> Array{u8}\nA:y -> ??\nA:x -> y ? {\n  {u8(h) ...A:(t)} -> y{#0 -> 5}\n  -> y\n}", "", {}},
	{ARRAY + "A -> Array{u8}\nA:y -> ??\nA:x -> y ? {\n  {u8(h) ...A:(t)} -> y{#0 -> 300}\n  -> y\n}", "", {.Constraint_Mismatch}},
	{ARRAY + "A -> Array{u8}\nA:y -> ??\nx -> y{#0 -> 5}", "", {.Invalid_operator}},
	// an integer / rounds toward 0: only an exact division is read by the ring
	{"u8:a -> ??\nx -> (a / 4) * 4", "4 * (?0 / 4)", {}},
	{"u8:a -> ??\nx -> 3 * (a / 4) - 1", "3 * (?0 / 4) - 1", {}},
	{"u8:a -> ??\nx -> (a * (a + 1) / 2) * 2 - a", "?0 * ?0", {}},
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
	// a target over two unknowns: the guard says what the rewrite does not
	{"a -> ??::u16\nb -> ??::i8\n(0..786):x -> (a + b) ? {\n  <0 -> 0\n  >786 -> 786\n  -> a + b\n}", "", {}},
	{"a -> ??::u16\nb -> ??::i8\n(0..785):x -> (a + b) ? {\n  <0 -> 0\n  >786 -> 786\n  -> a + b\n}", "", {.Constraint_Mismatch}},
	{"a -> ??::u16\nb -> ??::i8\nx -> (a + b < 0) [|] (a + b >= 0)", "true", {}},
	{"a -> ??::u16\nb -> ??::i8\nx -> (a + b) ? {\n  <0 -> 0\n  >=0 -> 1\n}", "", {}},
	// a [&] b, each proven on its own: a shape of such fields
	{"a -> ??::u16\nb -> ??::i8\nc -> (a + b) ? {\n  <0 -> 0\n  >786 -> 786\n  -> a + b\n}\nP -> {(0..786):x (0..786):y}\nP:p -> P{c c}", "", {}},
	{"a -> ??::u16\nb -> ??::i8\nc -> (a + b) ? {\n  <0 -> 0\n  >786 -> 786\n  -> a + b\n}\nP -> {(0..786):x (0..785):y}\nP:p -> P{c c}", "", {.Constraint_Mismatch}},
	// x in x, x one value: a hole sent one value holds it
	{"Vec -> {\n  X <- i32\n  X:x\n}\na -> ??::u16\nb -> ??::i8\nv -> Vec{(a + b) ? {\n  <0 -> 0\n  -> a + b\n}}", "", {}},
	{"u8:x -> u8", "", {.Constraint_Mismatch}},
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
	// a self-call in a scope written in a branch: a branch defines nothing
	{"say -> {u8:n -> ??  -> n ? {0 -> 0  -> {r -> 1  -> 1 + say{n -> n - 1}!}!}}\nx -> say{n -> 3}!", "3", {}},
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
	// an access on a fold is the fold of the access; a fold is in what its value is in
	{"P -> {u8:a  u8:b}\ng -> {u8:n -> ??  u8:s -> 0  -> n ? {0 -> P{s  s}  -> g{n -> n - 1  s -> (s * 3 + 1) % 256}!}}\nx -> g{n -> 3}!.a", "⟳(x: 0 ↦ x + 1 until 3..; y: 0 ↦ (3 * y + 1) % 256; y)", {}},
	{"f -> {u32:n -> ??  u16:acc -> 0  -> n ? {0 -> acc  -> f{n -> n - 1  acc -> (acc + 1) % 1000}!}}\ni64:x -> f{n -> ??::u32}!", "⟳(x: 0 ↦ x + 1 until ?1..; y: 0 ↦ (y + 1) % 1000; y)", {}},
	// a recursion over what a fold builds is the fold of the recursion
	{"Node -> {\n  -> {}\n  -> {Node:l  Node:r}\n}\nmake -> {\n  (0..30):depth -> ??\n  -> depth ? {\n    0 -> {l -> {}  r -> {}}\n    -> {l -> make{depth -> depth - 1}!  r -> make{depth -> depth - 1}!}\n  }\n}\ncheck -> {\n  Node:t -> {}\n  -> t ? {\n    {Node:l  Node:r} -> l ? {\n      {} -> 1\n      -> 1 + check{t -> l}! + check{t -> r}!\n    }\n    -> 1\n  }\n}\nx -> check{t -> make{depth -> ??::(0..30)}!}!", "2 * 2 ** ?1 - 1", {}},
	// a fold that starts where it stops is its inits
	{"make -> {(0..30):depth -> ??  -> depth ? {0 -> {l -> {}  r -> {}}  -> {l -> make{depth -> depth - 1}!  r -> make{depth -> depth - 1}!}}}\nx -> make{depth -> 0}!", "{l -> {}  r -> {}}", {}},
	// a recursion reads the fields of its own calls: the hypothesis, by induction
	{"f -> {u8:n -> ??  -> n ? {0 -> {a -> 0  b -> 1}  -> {a -> f{n -> n - 1}!.b  b -> (f{n -> n - 1}!.a + f{n -> n - 1}!.b) % 256}}}\nx -> f{n -> ??::u8}!.a", "f{n -> ?1}!.a", {}},
	// calls along a counter that differ by one field are the bindings of one call
	{"g -> {u8:n -> ??  u8:p -> 0  -> n ? {0 -> p  -> (g{n -> n - 1  p -> p}! * 3 + p) % 251}}\ns -> {\n  u8:p -> 0\n  acc -> 0\n  -> p ? {>=4 -> acc  -> s{p -> p + 1  acc -> (acc + g{n -> ??::u8  p -> p}!) % 1000}!}\n}\nx -> s!", "", {}},
	// a bitwise operation summed over a range is summed bit by bit
	{"v -> ??::(0..999)\ns -> {\n  u8:p -> 0\n  acc -> 0\n  -> p ? {>=8 -> acc  -> s{p -> p + 1  acc -> acc + (v ^ p)}!}\n}\nx -> s!", "8 * ?0 - 8 * (?0 [&] 7) + 28", {}},
	{"s -> {\n  u8:p -> 17\n  acc -> 0\n  -> p ? {>=201 -> acc  -> s{p -> p + 1  acc -> acc + (123 [|] p)}!}\n}\nx -> s!", "32344", {}},
	{"s -> {\n  u8:p -> 3\n  acc -> 0\n  -> p ? {>=13 -> acc  -> s{p -> p + 1  acc -> acc + (999 [&] p)}!}\n}\nx -> s!", "35", {}},
	// a run a fold builds, read by a fold at its own step, is never built
	{ARRAY + "build -> {\n  u8:n -> ??\n  u8:r -> 1\n  Array{u8}:acc -> {}\n  -> n ? {0 -> acc  -> build{n -> n - 1  r -> (r * 3) % 256  acc -> {...acc  r}}!}\n}\nscan -> {\n  Array{u8}:data -> {}\n  u8:acc -> 0\n  -> data ? {\n    {u8(h) ...Array{u8}:(t)} -> scan{data -> t  acc -> (acc + h) % 256}!\n    -> acc\n  }\n}\nx -> scan{data -> build{n -> ??::u8}!}!", "⟳(x: 0 ↦ x + 1 until ?1..; y: 0 ↦ (y + z) % 256, z: 1 ↦ 3 * z % 256; y)", {}},
	// a recursion is in a shape by induction: its steps keep it there
	{"Node -> {-> {}  -> {u8:v  Node:l  Node:r}}\nbuild -> {\n  (0..30):depth -> ??\n  -> depth ? {\n    0 -> {v -> 1  l -> {}  r -> {}}\n    -> {v -> 2  l -> build{depth -> depth - 1}!  r -> build{depth -> depth - 1}!}\n  }\n}\nNode:x -> build{depth -> ??::(0..30)}!", "", {}},
	// a carve of a binding an expansion placed carves what is expanded
	{"inner -> {x -> 1  w -> x + 1}\nouter -> {...inner  y -> 2}\nx -> outer{x -> 5}.w", "6", {}},
	{"inner -> {x -> 1  w -> x + 1}\nouter -> {...inner  y -> 2}\ndeep -> {...outer  z -> 3}\nx -> deep{x -> 9}.w", "10", {}},
	// data not known yet is placed as it is, beside the rest
	{ARRAY + "A -> Array{u8}\nxs -> ??::A\nA:x -> {...xs  5}", "", {}},
	{ARRAY + "A -> Array{u8}\nxs -> ??::A\nA:x -> {...xs  300}", "", {.Constraint_Mismatch}},
	{ARRAY + "A -> Array{u8}\nxs -> ??::A\ny -> {...xs  b -> 5}\nx -> y.b", "5", {}},
	{"a -> ??::u8\nx -> {...a}", "", {.Constraint_Mismatch}},
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
	{"fact -> {u8:n -> ??  -> n ? {0 -> 1  -> n * fact{n -> n - 1}!}}\nx -> fact{n -> 5}!", "Π(x: 1..5, x)", {}},
	// states carried by the call: the fold goes down, each a state of it
	{"count -> {u32:n -> ??  u64:r -> ??  -> n ? {0 -> r  -> count{n -> n - 1  r -> r ^ n}!}}\nx -> count{n -> 3  r -> 0}!", "⟳(x: 0 ↦ x + 1 until 3..; y: 0 ↦ y ^ -x + 3; y)", {}},
	// a step reading a state the call changes is no orbit: Euclid stays a call
	{"f -> {u32:a -> ??  u32:b -> ??  -> b ? {0 -> a  -> f{a -> b  b -> a % b}!}}\nx -> f{a -> ??::u32  b -> ??::u32}!", "f{a -> ?2  b -> ?3}!", {}},
	// a place of a run shape written with a value admits that value only
	{ARRAY + "A -> Array{u8}\nxs -> ??::(A & ~{})\nx -> xs ? {\n  {32  ...A:(t)} -> 1\n  -> 0\n}", "?0 ? {{32  ...A:} -> 1  -> 0}", {}},
	// a run is the orbit of its positions: a fold on k until |xs|, h = xs.#k
	{ARRAY + "A -> Array{u8}\ntotal -> {\n  A:xs -> {}\n  u8:acc -> 0\n  -> xs ? {\n    {u8(h) ...A:(t)} -> total{xs -> t  acc -> (acc + h) [&] 255}!\n    -> acc\n  }\n}\nx -> total{xs -> ??::A}!", "⟳(x: 0 ↦ x + 1 until |?0|..; y: 0 ↦ y + ?0.#x [&] 255; y)", {}},
	{ARRAY + "A -> Array{u8}\ntotal -> {\n  A:xs -> {}\n  u8:acc -> 0\n  -> xs ? {\n    {u8(h) ...A:(t)} -> total{xs -> t  acc -> (acc + h) [&] 255}!\n    -> acc\n  }\n}\nx -> total{xs -> {1 2 3}}!", "⟳(x: 0 ↦ x + 1 until 3..; y: 0 ↦ y + {1  2  3}.#x [&] 255; y)", {}},
	// a cover that cuts c places moves along the run by c
	{ARRAY + "A -> Array{u8}\npairs -> {\n  A:xs -> {}\n  u16:acc -> 0\n  -> xs ? {\n    {u8(a) u8(b) ...A:(t)} -> pairs{xs -> t  acc -> (acc + a * b) % 1000}!\n    -> acc\n  }\n}\nx -> pairs{xs -> ??::A}!", "⟳(x: 0 ↦ x + 1 until (|?0| / 2)..; y: 0 ↦ (y + ?0.#(2 * x) * ?0.#(2 * x + 1)) % 1000; y)", {}},
	{ARRAY + "A -> Array{u8}\npairs -> {\n  A:xs -> {}\n  u16:acc -> 0\n  -> xs ? {\n    {u8(a) u8(b) ...A:(t)} -> pairs{xs -> t  acc -> (acc + a * b) % 1000}!\n    -> acc\n  }\n}\nbuild -> {\n  u8:n -> ??\n  u8:r -> 1\n  A:acc -> {}\n  -> n ? {0 -> acc  -> build{n -> n - 1  r -> (r * 3) % 256  acc -> {...acc  r  (r + 1) % 256}}!}\n}\nx -> pairs{xs -> build{n -> ??::u8}!}!", "⟳(x: 0 ↦ x + 1 until ?1..; y: 0 ↦ (y + z * ((z + 1) % 256)) % 1000, z: 1 ↦ 3 * z % 256; y)", {}},
	// the pieces a cover cuts from a run not known yet
	{ARRAY + "A -> Array{u8}\nxs -> ??::A\nx -> xs ? {\n  {u8(h) ...A:(t)} -> t\n  -> {}\n}", "?0 ? {{u8:  ...A:} -> ?0 from 1  -> {}}", {}},
	// a recursion whose base case is a scope folds up from it: its state a run
	{"build -> {u32:n -> ??  -> n ? {0 -> {}  -> {...build{n -> n - 1}!  n}}}\nx -> build{n -> 3}!", "⟳(x: 2 ↦ x - 1 until ..(-1); y: {} ↦ {...y  -x + 3}; y)", {}},
	{SUM + "x -> sum!", "(?0 + ?0 * ?0) / 2", {}},
	// the laws of a fold: closed forms, the length of an orbit
	{"h -> {u8:n -> ??  -> n ? {0 -> 0  -> 2 * h{n -> n - 1}! + 1}}\nx -> h!", "2 ** ?0 - 1", {}},
	{"t -> {u8:n -> ??  -> n ? {0 -> 1  -> 3 * t{n -> n - 1}! + n}}\nx -> t!", "(-(2 * ?0) + 7 * 3 ** ?0 - 3) / 4", {}},
	{"t -> {u8:n -> ??  -> n ? {0 -> 1  -> 3 * t{n -> n - 1}! + n}}\nx -> t{n -> 5}!", "422", {}},
	{"h -> {u8:n -> ??  -> n ? {0 -> 0  -> 1 + h{n -> n / 2}!}}\nx -> h!", "μ(x: ?0 / 2 ** x in 0)", {}},
	// §5.6: C-finite sequences, by the characteristic polynomial of a linear fold
	{"fib -> {u8:n -> ??  -> n ? {<2 -> n  -> fib{n -> n - 1}! + fib{n -> n - 2}!}}\nx -> fib{n -> 90}!", "2880067194370816120", {}},
	{"t -> {u8:n -> ??  -> n ? {<2 -> 1  -> 3 * t{n -> n - 1}! - 2 * t{n -> n - 2}! + 1}}\nx -> t{n -> 5}!", "27", {}},
	{"t -> {u8:n -> ??  -> n ? {<2 -> n  -> 3 * t{n -> n - 1}! - 2 * t{n -> n - 2}!}}\nx -> t{n -> 10}!", "1023", {}},
	{"t -> {u8:n -> ??  -> n ? {<2 -> n  -> 4 * t{n -> n - 1}! - 4 * t{n -> n - 2}!}}\nx -> t{n -> 5}!", "80", {}},
	// §5.6: Σ and Π
	{"f -> {u8:n -> ??  -> n ? {0 -> 1  -> n * f{n -> n - 1}!}}\nx -> f!", "Π(x: 1..?0, x)", {}},
	{"f -> {u8:n -> ??  -> n ? {0 -> 1  -> 2 * n * f{n -> n - 1}!}}\nx -> f!", "2 ** ?0 * Π(x: 1..?0, x)", {}},
	{"f -> {u8:n -> ??  -> n ? {0 -> 0  -> n * n * n + f{n -> n - 1}!}}\nx -> f{n -> 4}!", "100", {}},
	// §4.5: the power
	{"x -> 2 ** 3 ** 2", "512", {}},
	{"x -> -2 ** 2", "-4", {}},
	{"x -> (2 ** ??::u8) ** 3", "2 ** (3 * ?0)", {}},
	{"x -> 2 ** -1", "", {.Invalid_operator}},
	{"n -> ??::u8\nu16:x -> 2 ** (n % 8)", "", {}},
	{SUM + "x -> sum{n -> 5}!", "15", {}},
	{SUM + "u16:x -> sum!", "", {}},
	{SUM + "u8:x -> sum!", "", {.Constraint_Mismatch}},
	// the closed form is that of the call, whatever n holds in sum
	{SUM_ZERO + "x -> sum{n -> ??::u8}!", "(?0 + ?0 * ?0) / 2", {}},
	{SUM_ZERO + "x -> sum{n -> 5}!", "15", {}},
	{SUM_ZERO + "x -> sum!", "0", {}},
	{SUM_ZERO + "u16:x -> sum{n -> ??::u8}!", "", {}},
	{SUM_ZERO + "u8:x -> sum{n -> ??::u8}!", "", {.Constraint_Mismatch}},
	{SUM_SEVEN + "x -> sum!", "28", {}},
	{"Array -> {\n  T -> {}\n  -> {T: ...Array{T}:}\n  -> {}\n}\nArray{u8}:x", "", {.Infinite_Recursion}},
	{"Array -> {\n  T -> {}\n  -> {}\n  -> {T: ...Array{T}:}\n}\nArray{u8}:x -> {1 2 3}", "", {}},
	{"Array -> {\n  T -> {}\n  -> {}\n  -> {T: ...Array{T}:}\n}\nArray{u8}:x -> {1 300 3}", "", {.Constraint_Mismatch}},
	// §4.9: an emission is answered where the scope that holds it is collapsed, the
	// program answering by its default
	{LIB + "x -> lib!", `"default"`, {}},
	{LIB + "x -> main!", `"main"`, {}},
	{LIB + "x -> {-> lib!}!", `"default"`, {}},
	{"Log -> {string:message}\nAudit -> {string:message}\nLog -< e { -> 1 }\nx >- Audit{message -> \"x\"}", "", {.Invalid_Emission}},
	{"x >- 5", "", {.Invalid_Emission}},
	{WORK + "x -> app!", "32", {}},
	{U16_LOG + "x -> lib!", "2", {}},
	{U16_LOG + "x -> lib{Log -< e { -> 300 }}!", "301", {}},
	{U16_LOG + "x -> lib{Log -< e { -> \"a\" }}!", "", {.Constraint_Mismatch}},
	{U16_LOG + "x -> lib{Audit -< e { -> 3 }}!", "", {.Invalid_Carve}},
	// the bits of integers ≥ 0: their bounds
	{"a -> ??::u8\nu8:x -> a ^ 5", "", {}},
	{"a -> ??::u8\nu8:x -> a [&] 300", "", {}},
	{"a -> ??::u8\nu16:x -> a << 8", "", {}},
	{"a -> ??::u8\nu8:x -> a << 1", "", {.Constraint_Mismatch}},
	{"a -> ??::u16\nu8:x -> a >> 8", "", {}},
	{"a -> ??::u8\nu8:x -> a [|] 256", "", {.Constraint_Mismatch}},
	// §4.14: a resonant binding is a place, which its writes change; a read is what
	// the writes before it give, each run with places of its own
	{COUNTER + "x -> {c -> Counter!, c.increment!, c.increment!, -> c.value}!", "2", {}},
	{COUNTER + "x -> {c -> Counter!, d -> Counter!, c.increment!, -> c.value * 10 + d.value}!", "10", {}},
	{COUNTER + "u8:n -> ??\nx -> {c -> Counter!, n ? {0 -> c.increment!  -> {}}, -> c.value}!", "?2 ? {0 -> 1  -> 0}", {}},
	// a place of the file outlives the run that writes it: the write is kept
	{"Set -> {u8:v}\nu8:value >>- Set -> 0\nSet -< e { value -<< e.v }\nx -> {w >- Set{v -> 7}, -> value}!", "[?0 -<< 7](7)", {}},
	{"Set -> {u8:v}\nu8:value >>- Set -> 0\nSet -< e { value -<< 300 }\nx -> {w >- Set{v -> 7}, -> value}!", "", {.Constraint_Mismatch}},
	{"y -> 1\nx -> {y -<< 2}!", "", {.Invalid_Write}},
	// a copy keeps the handle; what a scope writes, in a scope written in it too, is
	// its own: its handlers are their defaults
	{"lib -> {\n  Log -> {string:message}\n  Log -< e { -> e.message }\n  string:m -> \"x\"\n  r >- Log{message -> m}\n  -> r\n}\nx -> {lib.Log -< e { -> e.message + \"!\" }  -> lib{m -> \"y\"}!}!", `"y!"`, {}},
	{LIB + "x -> lib{r -> \"y\"}!", "", {.Invalid_Carve}},
	{"lib -> {\n  Log -> {string:message}\n  Log -< e { -> \"default\" }\n  -> {r >- Log{message -> \"x\"}  -> r}!\n}\nx -> {lib.Log -< e { -> \"main\" }  -> lib!}!", `"main"`, {}},
	// a recursion that emits: each step, answered where the call is collapsed
	{COUNT + "x -> count{n -> 3}!", "0", {}},
	{COUNT + "x -> {count.Tick -< e { -> 1 }  -> count{n -> 3}!}!", "3", {}},
	// what the run of a handler emits comes up from the scope that runs it
	{"Audit -> {string:what}\nAudit -< e { -> 10 }\nNote -> {string:what}\nNote -< e { u8:r >- Audit{what -> e.what}  -> r + 1 }\nuser -> {u8:n >- Note{what -> \"b\"}  -> n}\nx -> {Audit -< e { -> 50 }  -> user!}!", "11", {}},
}

LIB :: "lib -> {\n  Log -> {string:message}\n  Log -< e { -> \"default\" }\n  r >- Log{message -> \"x\"}\n  -> r\n}\nmain -> {\n  lib.Log -< e { -> \"main\" }\n  -> lib!\n}\n"

WORK :: "work -> {\n  Log -> {string:message}   Log -< e { -> 0 }\n  Alloc -> {u64:size}       Alloc -< e { -> 0 }\n  a >- Log{message -> \"start\"}\n  p >- Alloc{size -> 16}\n  -> p\n}\napp -> {\n  work.Log -< e { -> 1 }\n  -> {work.Alloc -< e { -> e.size * 2 }  -> work!}!\n}\n"

U16_LOG :: "Audit -> {}\nlib -> {\n  Log -> {string:message}\n  Log -< e { -> 1 }\n  u16:r >- Log{message -> \"x\"}\n  -> r + 1\n}\n"

COUNT :: "count -> {\n  Tick -> {}\n  Tick -< e { -> 0 }\n  u8:n -> ??\n  -> n ? {0 -> 0  -> {u8:t >- Tick{}  -> t}! + count{n -> n - 1}!}\n}\n"

ARRAY :: "Array -> {\n  T -> {}\n  -> {}\n  -> {T: ...Array{T}:}\n}\n"

IDENTITY :: "identity -> {\n  T <- none\n  T:value -> none\n  -> value\n}\n"

PAIR :: "data -> {u8:x -> 0}\npair -> {\n  u8:e <- 2\n  data{e}:first\n  data{e}:second\n  -> e\n}\n"

MAP :: "map -> {\n  T <- {}\n  E <- {}\n  Array{T}:source\n  func -> {e -> T:, -> E:}\n  -> source ? {\n    {T:(e) ...Array{T}:(r)} -> {func{e -> e}! ...map{r, func}!}\n    {} -> {}\n  }\n}\n"

MIXED :: "List -> {\n  -> {}\n  -> {u8: ...List:}\n  -> {i8: string: ...List:}\n}\n"

MIRROR :: "List -> {\n  T -> {}\n  -> {}\n  -> {T: ...List{T}: T:}\n}\n"

LISTS :: "List -> {\n  -> {}\n  -> {u8: ...List:}\n  -> {i8: ...List:}\n}\n"

SUM :: "sum -> {\n  u8:n -> ??\n  -> n ? {0 -> 0  -> n + sum{n -> n - 1}!}\n}\n"

SUM_ZERO :: "sum -> {\n  u8:n\n  -> n ? {0 -> 0  -> n + sum{n -> n - 1}!}\n}\n"

SUM_SEVEN :: "sum -> {\n  u8:n -> 7\n  -> n ? {0 -> 0  -> n + sum{n -> n - 1}!}\n}\n"

// The sizes (size.odin): each source binds `x` last; the printed size of its type.
Size_Case :: struct {
	source: string,
	size:   string,
}

SIZE_CASES := []Size_Case {
	// what is known takes nothing: a value, a set written as a value
	{`x -> 5`, "0"},
	{`x -> u8`, "0"},
	{`x -> {u8: u8:}`, "0"},
	// an unknown: ⌈log₂⌉ of the count of its layout
	{`x -> ??::u8`, "8"},
	{`x -> ??::i8`, "8"},
	{`x -> ??::bool`, "1"},
	{`x -> ??::char`, "21"},
	{`x -> ??::('a'..'z')`, "5"},
	{`x -> ??::(100..103)`, "2"},
	{`x -> ??::(0..3 | 10..12)`, "3"},
	{`x -> ??::(u8 | bool)`, "9"},
	{`x -> ??::("ab" | "c" | "de")`, "2"},
	{`x -> ??::(("a" | "ab") + ("b" | ""))`, "2"}, // "a", "ab", "abb": "ab" counted once
	{`x -> ??::(('a'..'z' * (1..3)) & ~("ab" + string))`, "15"},
	{`x -> ??::('a'..'z' * 3)`, "15"},
	{`x -> ??::('a'..'z' * (0..2))`, "10"},
	{"n -> ??::u8\nx -> ??::('a'..'z' * n)", "⌈log₂ (26 ** ?0)⌉"}, // depends on n
	{`x -> ??::int`, "unbounded"},
	{`x -> ??::string`, "unbounded"},
	// a term over unknowns: the values it may take, no more than its unknowns take
	{"a -> ??::u8\nx -> a + 1", "8"},
	{"a -> ??::u8\nx -> a + a", "8"},
	{"a -> ??::u8\nx -> a * a", "8"},
	{"a -> ??::u8\nb -> ??::u8\nx -> a * b", "15"}, // the distinct products, each computed
	{"a -> ??::u8\nx -> a ? {<10 -> a  -> 1000}", "4"},
	{"x -> !?::u8", "8"},
	// a scope: its bindings; a hole and a production take nothing, a handler what it gives back
	{"a -> ??::u8\nx -> {u8:f -> a  bool:g  u8:h -> 7}", "8"},
	{"a -> ??::u8\nx -> {u8:n <- 3  t -> a}", "8"},
	{"a -> ??::u8\nx -> {u8:f -> a  -> f + 1}", "8"},
	{"E -> {u8:v}\nx -> {E -< e { -> e.v }}", "8"},
	// a shape as a layout: what it admits; a run of any length, no bound
	{`x -> ??::{u8: u8:}`, "16"},
	{`x -> ??::{u8: bool:}`, "9"},
	{ARRAY + "x -> ??::{u8: ...Array{u8}:}", "unbounded"},
	{ARRAY + "x -> ??::(Array{u8})", "unbounded"},
	// a format: the count of its values; every real: no bound
	{`x -> ??::f16`, "16"},
	{`x -> ??::f32`, "32"},
	{`x -> ??::f64`, "64"},
	{`x -> ??::(f16 & 0.0..1.0)`, "14"},
	{`x -> ??::float`, "unbounded"},
	{"a -> ??::f32\nx -> a + 0.1", "32"},
}

// The formats (real.odin, format.odin): each source binds `x` last.
FORMAT_CASES := []Spec_Case {
	// a format is a set of reals: f16 ⊂ f32 ⊂ f64 ⊂ float
	{`x -> f32 & f64`, "f32", {}},
	{`x -> f32 | f64`, "f64", {}},
	{`x -> f16 & 0.0..1.0`, "f16 & 0.0..1.0", {}},
	{`x -> -f32`, "f32", {}},
	{`f32:x -> 0.5`, "0.5", {}},
	{`f16:x -> 65504.0`, "65504.0", {}},
	{`f16:x -> 0.000000059604644775390625`, "0.000000059604644775390625", {}}, // the least subnormal
	{`float:x -> 0.1`, "0.1", {}},
	// a real in a color of a format is the value of the format nearest it, exactly
	{`f32:x -> 0.1`, "0.100000001490116119384765625", {}},
	{`f16:x -> 0.1`, "0.0999755859375", {}},
	{`f16:x -> 2049.0`, "2048.0", {}}, // a tie: the even one
	{`f16:x -> 70000.0`, "", {.Constraint_Mismatch}}, // beyond the greatest f16
	{`x -> f64 & ~f32`, "f64 & ~f32", {}}, // no union of intervals: it stays
	// an operation on a format is its exact result, rounded to the widest format
	{"a -> ??::f32\nx -> a + 0.1", "round32(?0 + 0.100000001490116119384765625)", {}},
	{"a -> ??::f16\nb -> ??::f32\nx -> a + b", "round32(?0 + ?1)", {}},
	{"a -> ??::f32\nx -> -a", "-?0", {}}, // a value of the format: nothing to round
	{"a -> ??::(f32 & 0.0..1.0)\nf32:x -> a * 0.5", "round32(0.5 * ?0)", {}}, // a subnormal halved is no f32
	{"a -> ??::f32\nf32:x -> a * a", "", {.Constraint_Mismatch}}, // it may go beyond the greatest f32
	// a value of a format lies within its extremes: what rounds within them is in it
	{"a -> ??::f32\nf32:x -> a + a", "", {.Constraint_Mismatch}},
	{`f16:x -> 65519.0`, "65504.0", {}},
	{`f16:x -> 65520.0`, "", {.Constraint_Mismatch}}, // a tie: the even one is beyond
	{"a -> ??::f32\nf64:x -> a", "?0", {}},
	{"a -> ??::f32\nf16:x -> a", "", {.Constraint_Mismatch}},
}

@(test)
test_formats :: proc(t: ^testing.T) {
	check_cases(t, FORMAT_CASES)
}

// SET: a resonant binding of the file, and the event that sets it.
SET :: "Set -> {u16:v}\nu16:value >>- Set -> 0\nSet -< e { value -<< e.v }\n"

// The memory a program keeps (§4.13, §4.14): each source binds `x` last; its type,
// and the places it keeps, with the bits they take.
Memory_Case :: struct {
	source: string,
	type:   string,
	places: int,
	bits:   string,
}

MEMORY_CASES := []Memory_Case {
	// a resonant binding nothing writes is its value: immutable
	{COUNTER + "x -> {c -> Counter!, -> c.value}!", "0", 0, "0"},
	// written twice, nothing unknown between: the last value written
	{COUNTER + "x -> {c -> Counter!, c.increment!, c.increment!, -> c.value}!", "2", 0, "0"},
	// two counters, each its own place, both simplified away
	{COUNTER + "x -> {c -> Counter!, d -> Counter!, c.increment!, -> c.value * 10 + d.value}!", "10", 0, "0"},
	// a write in a branch on an unknown: a value for each branch, no place
	{COUNTER + "u8:n -> ??\nx -> {c -> Counter!, n ? {0 -> c.increment!  -> {}}, -> c.value}!", "?2 ? {0 -> 1  -> 0}", 0, "0"},
	// what is written comes from outside: the value read is what it gave
	{SET + "x -> {u16:a -> !?, w >- Set{v -> a}, -> value + 1}!", "ε0(x::u16, [?0 -<< x](x + 1))", 1, "16"},
	// a place of the file outlives the run that writes it
	{SET + "x -> {w >- Set{v -> 7}, -> value}!", "[?0 -<< 7](7)", 1, "16"},
	// a binding reads a place where it is written; a reactive one, where it is read
	{COUNTER + "x -> {c -> Counter!, a -> c.value, c.increment!, -> a}!", "0", 0, "0"},
	{COUNTER + "x -> {c -> Counter!, a >>= c.value, c.increment!, -> a}!", "1", 0, "0"},
	{COUNTER + "x -> {c -> Counter!, p >>= c.value * 2, c.increment!, c.increment!, -> p}!", "4", 0, "0"},
	{COUNTER + "x -> {c -> Counter!, p >>= c.value * 2, a -> p, c.increment!, -> a + p}!", "2", 0, "0"},
	// a counter the run gives is held: its place lives on
	{COUNTER + "x -> {c -> Counter!, c.increment!, -> c}!", "", 1, "16"},
}

@(test)
test_memory :: proc(t: ^testing.T) {
	arena: vmem.Arena
	context.allocator = vmem.arena_allocator(&arena)
	defer vmem.arena_destroy(&arena)
	for c in MEMORY_CASES {
		k, parsed := run(c.source)
		if !testing.expectf(t, parsed, "%s: does not parse", c.source) do continue
		testing.expectf(t, len(k.errors) == 0, "%s: errors %v", c.source, k.errors)
		last := k.root.bindings[len(k.root.bindings) - 1]
		x := binding_type(&k, last)
		if c.type != "" do testing.expectf(t, print_type(x) == c.type, "%s: the type is %s, expected %s", c.source, print_type(x), c.type)
		m := memory(&k, x)
		bits := print_size(m.size)
		testing.expectf(t, len(m.places) == c.places && bits == c.bits, "%s: keeps %d places, %s bits; expected %d, %s", c.source, len(m.places), bits, c.places, c.bits)
	}
}

@(test)
test_sizes :: proc(t: ^testing.T) {
	arena: vmem.Arena
	context.allocator = vmem.arena_allocator(&arena)
	defer vmem.arena_destroy(&arena)
	for c in SIZE_CASES {
		k, parsed := run(c.source)
		if !testing.expectf(t, parsed, "%s: does not parse", c.source) do continue
		last := k.root.bindings[len(k.root.bindings) - 1]
		got := print_size(size(&k, binding_type(&k, last)))
		testing.expectf(t, got == c.size, "%s: the size is %s, expected %s", c.source, got, c.size)
	}
}

@(test)
test_spec :: proc(t: ^testing.T) {
	check_cases(t, SPEC_CASES)
}

// check_cases: each case types as it says, with the errors it says.
check_cases :: proc(t: ^testing.T, cases: []Spec_Case) {
	arena: vmem.Arena
	context.allocator = vmem.arena_allocator(&arena)
	defer vmem.arena_destroy(&arena)
	for c in cases {
		k, parsed := run(c.source)
		if !testing.expectf(t, parsed, "%s: does not parse", c.source) do continue
		last := k.root.bindings[len(k.root.bindings) - 1]
		got := print_type(binding_type(&k, last))
		if c.type != "" do testing.expectf(t, got == c.type, "%s: the type is %s, expected %s", c.source, got, c.type)
		kinds := error_kinds(k.errors[:])
		testing.expectf(t, slice.equal(kinds, c.errors), "%s: errors %v, expected %v (%s)", c.source, kinds, c.errors, describe_errors(k.errors[:]))
	}
}

// A case of a corpus: one JSON file. `type`, when given, is the printed type of the
// last binding; `productions`, the printed type of the first production of scopes
// bound in the file, by name.
Corpus_Case :: struct {
	name:          string `json:"name"`,
	source:        string `json:"source"`,
	type:          string `json:"type"`,
	productions:   map[string]string `json:"productions"`,
	expect_errors: []string `json:"expect_errors"`,
}

// production_type: the printed type of the first production of the scope bound to
// name in the file.
production_type :: proc(k: ^Kernel, name: string) -> string {
	for b in k.root.bindings {
		if b.name != name do continue
		s, is_scope := b.value.(^Scope)
		if !is_scope do return "not a scope"
		if p, found := first_production(k, s); found do return print_type(binding_type(k, p))
	}
	return "no production"
}

// corpus: the cases of the directory test/<path…>, in the order of their files.
corpus :: proc(path: ..string) -> []Corpus_Case {
	parts := make([dynamic]string)
	append(&parts, filepath.dir(#location().file_path), "..", "test")
	append(&parts, ..path)
	append(&parts, "*.json")
	pattern, _ := filepath.join(parts[:])
	files, _ := filepath.glob(pattern)
	slice.sort(files)
	out := make([dynamic]Corpus_Case)
	for file in files {
		data, err := os.read_entire_file(file, context.allocator)
		if err != nil do continue
		c: Corpus_Case
		if json.unmarshal(data, &c) == nil do append(&out, c)
	}
	return out[:]
}

// kind_names: the kinds of the errors, by name, sorted, each once.
kind_names :: proc(errors: []Error) -> []string {
	out := make([dynamic]string)
	for kind in error_kinds(errors) do append(&out, fmt.tprint(kind))
	return out[:]
}

// expected_kinds: the kinds a case expects, sorted, each once.
expected_kinds :: proc(c: Corpus_Case) -> []string {
	want := slice.clone(c.expect_errors)
	slice.sort(want)
	return slice.unique(want)
}

// The corpus of test/typecheck: each source whose forms are all built by this
// kernel must give exactly the expected errors. The others are counted apart.
// the constants the laws share are normal forms: built again, in a kernel, the laws
// give each back
@(test)
test_constants :: proc(t: ^testing.T) {
	arena: vmem.Arena
	context.allocator = vmem.arena_allocator(&arena)
	defer vmem.arena_destroy(&arena)
	k, _ := run("")
	rebuilt :: proc(t: Type) -> Type {
		#partial switch v in t {
		case ^Range:
			return new_range(rebuilt(v.lo), rebuilt(v.hi), v.family)
		case ^Or:
			terms := make([]Type, len(v.terms))
			for x, i in v.terms do terms[i] = rebuilt(x)
			return new_or(..terms)
		case ^And:
			terms := make([]Type, len(v.terms))
			for x, i in v.terms do terms[i] = rebuilt(x)
			return new_and(..terms)
		case ^Not:
			return new_not(rebuilt(v.term))
		case ^Operation:
			args := make([]Type, len(v.args))
			for x, i in v.args do args[i] = rebuilt(x)
			return new_operation(v.op, ..args)
		}
		return t
	}
	for c in constants() {
		fresh := rebuilt(c)
		testing.expectf(t, fresh != c, "%s was not built again", print_type(c))
		testing.expectf(t, same(&k, normal(&k, fresh), c), "%s is not a normal form: %s", print_type(c), print_type(normal(&k, fresh)))
	}
}

@(test)
test_corpus :: proc(t: ^testing.T) {
	arena: vmem.Arena
	context.allocator = vmem.arena_allocator(&arena)
	defer vmem.arena_destroy(&arena)
	cases := corpus("typecheck", "tests")
	passed, outside, unparsed := 0, 0, 0
	failures := make([dynamic]string)
	for c in cases {
		k, parsed := run(c.source)
		if !parsed {
			unparsed += 1
			continue
		}
		if slice.contains(error_kinds(k.errors[:]), Error_Kind.Unsupported) {
			outside += 1
			continue
		}
		got, want := kind_names(k.errors[:]), expected_kinds(c)
		if slice.equal(got, want) {
			passed += 1
		} else {
			append(&failures, fmt.tprintf("%s: got %v, expected %v\n    %s\n%s", c.name, got, want, describe_errors(k.errors[:]), indent(c.source)))
		}
	}
	log.infof("corpus: %d pass, %d fail, %d outside the kernel, %d do not parse (of %d)", passed, len(failures), outside, unparsed, len(cases))
	for f in failures do log.info(f)
}

// The corpus of test/effects (specs/types.md §4.8): a pure computation crosses the
// effects; none is erased, copied, replaced or reordered, recursive calls with
// effects included. Each source binds `x` last; its type is printed, and so are the
// productions a case names; the errors are compared by kind. Every case holds.
@(test)
test_effects :: proc(t: ^testing.T) {
	arena: vmem.Arena
	context.allocator = vmem.arena_allocator(&arena)
	defer vmem.arena_destroy(&arena)
	cases := corpus("effects")
	testing.expect(t, len(cases) > 0, "test/effects holds no case")
	for c in cases {
		k, parsed := run(c.source)
		if !testing.expectf(t, parsed, "%s: does not parse", c.name) do continue
		last := k.root.bindings[len(k.root.bindings) - 1]
		got := print_type(binding_type(&k, last))
		if c.type != "" do testing.expectf(t, got == c.type, "%s: the type is %s, expected %s", c.name, got, c.type)
		for name, want in c.productions {
			production := production_type(&k, name)
			testing.expectf(t, production == want, "%s: the production of %s is %s, expected %s", c.name, name, production, want)
		}
		kinds, want := kind_names(k.errors[:]), expected_kinds(c)
		testing.expectf(t, slice.equal(kinds, want), "%s: errors %v, expected %v (%s)", c.name, kinds, want, describe_errors(k.errors[:]))
	}
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
