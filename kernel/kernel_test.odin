package kernel

import syn "../compiler"
import "core:encoding/json"
import "core:fmt"
import "core:log"
import vmem "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:testing"

// A case: the source, the expected types of the scope (empty = do not compare) and
// the expected errors.
Test_Case :: struct {
	source: string,
	typed:  string,
	errors: []Error_Kind,
}

CASES := []Test_Case {
	{"x -> 1\ny -> x + 2", "{x -> 1  y -> 3}", {}},
	{"u8:a -> ??\nu8:b -> ??\nu16:c -> a + b", "{0..255:a -> ??0  0..255:b -> ??1  0..65535:c -> ??0 + ??1}", {}},
	{"u8:a -> ??\nu8:d -> a + a", "", {.Constraint_Mismatch}},
	{"u8 -> 5", "", {}}, // a builtin is only a name: a binding can shadow it
	{"e -> 0..255\nf -> >0", "{e -> 0..255  f -> 1..}", {}},
	{"Port -> u16 & >0\nPort:p -> 0", "", {.Constraint_Mismatch}},
	{"Port -> u16 & >0\nPort:p -> 8080", "", {}},
	{"none:i -> 5", "", {.Constraint_Mismatch}},
	{"none:i -> none", "{none:i -> none}", {}}, // the only value that none admits
	{"none:i", "{none:i -> none}", {}},
	{"u8:i -> none", "", {.Constraint_Mismatch}}, // none is not an element of 0..255
	{"x -> none", "{x -> none}", {}},
	{"true:check -> 2 = 2", "{true:check -> true}", {}},
	{"true:oops -> 2 = 3", "", {.Constraint_Mismatch}},
	{"((u8 | i8) & >10):x -> 42", "{11..255:x -> 42}", {}},
	// a color is a type like any other: it shares the unknowns of the value, and the
	// value must be one of its elements for every value of the unknowns
	{"n -> ??::u8\nn:x -> 5", "", {.Constraint_Mismatch}}, // 5 is not every value of n
	{"n -> ??::u8\nn:a\n(n + n):b -> a + n", "{n -> ??0  ??0:a -> ??0  (2*??0):b -> 2*??0}", {}}, // a is n
	{"u8:n -> ??\nn:a -> n\nm -> n * 2\nn:b -> m / 2", "{0..255:n -> ??0  ??0:a -> ??0  m -> 2*??0  ??0:b -> ??0}", {}}, // 2·n / 2 is n
	{"n -> ??::u8\n(0..n):d -> n\n(>n):f -> n + 1\n(n..):g -> 2 * n", "", {}},
	{"n -> ??::u8\n(0..n):e -> n + 1", "", {.Constraint_Mismatch}},
	{"n -> ??::u8\nm -> ??::u8\n(0..n):i -> m", "", {.Constraint_Mismatch}}, // m = 1, n = 0
	{"n -> ??::u8\nm -> ??::u8\n(n & m):k -> n", "", {.Constraint_Mismatch}}, // empty as soon as n ≠ m
	{"n -> ??::u8\nm -> ??::u8\n(n | m):x -> n\n(n | m):y -> 5", "", {.Constraint_Mismatch}}, // y: n and m can both differ from 5
	{"x -> ??::u8\n(x ? {<10 -> x, -> 10}):z -> x ? {<10 -> x, -> 10}", "", {}}, // each case, under its fact
	// a set of several values is not one of its elements; an atom is its own singleton
	{"n -> ??::u8\nu8:j -> 0..n", "", {.Constraint_Mismatch}}, // 0..n is an atom only for n = 0
	{"n -> ??::u8\n=(0..n):k -> 0..n", "", {}},
	{"=u8:e -> 5", "", {.Constraint_Mismatch}},
	// an unknown is in its domain, which can be an equation over earlier unknowns
	{"n -> ??::u8\n(0..n):e -> ??\nu8:f -> e\n(0..n):g -> e", "{n -> ??0  0..??0:e -> ??1  0..255:f -> ??1  0..??0:g -> ??1}", {}},
	{"n -> ??::u8\n(0..n):e -> ??\n(0..n - 1):h -> e", "", {.Constraint_Mismatch}}, // e can be n
	// a `??` written in a color is an unknown like any other
	{"??::u8:x -> 5", "", {.Constraint_Mismatch}}, // it can be 0
	{"(??::u8 & >10):b -> 11", "", {.Constraint_Mismatch}},
	{"(~??::u8):b -> 5", "", {.Constraint_Mismatch}}, // it can be 5
	{"??:z", "{??0:z -> ??0}", {}}, // z is the unknown that colors it
	// a shape whose color depends on an unknown
	{"n -> ??::u8\nP -> {(0..n):x -> n}\nP:p -> {x -> n}\nP:q -> {x -> n + 1}", "", {.Constraint_Mismatch}},
	{"~5:x -> 6", "", {}},
	{"~5:x -> 5", "", {.Constraint_Mismatch}},
	// ~ is taken within the carried sorts, and keeps them: ~~X = X, even via a ref
	{"X -> u8 | string\nY -> ~X\n(~Y):x -> \"a\"", "", {}},
	{"a -> ~bool\nb -> ~a\nc -> 0 & 1\nd -> u8 & string\ne -> ~c", "{a -> ~bool  b -> bool  c -> ~int  d -> none  e -> int}", {}},
	// scopes: a scope is its own type, its bindings carry theirs
	{"b -> {\n  n -> ??::u8\n  -> n * 2\n}\nc -> b.n\nd -> b!", "{b -> {n -> ??0  -> 2*??0}  c -> ??0  d -> 2*??0}", {}},
	// unknowns: normal forms, exact values when they can be enumerated
	{"n -> ??::u8\na -> n - n\nb -> n * 3 + n\nc -> (n + 1) * 2", "{n -> ??0  a -> 0  b -> 4*??0  c -> 2*??0 + 2}", {}},
	{"n -> ??::u8\nu8:e -> n - n", "", {}},
	{"n -> ??::u8\nm -> ??::u8\nu16:f -> n * m", "", {}},
	{"n -> ??::u8\nm -> ??::u8\nu8:f -> n * m", "", {.Constraint_Mismatch}},
	{"n -> ??::u8\ntrue:g -> n < n + 1", "", {}},
	{"n -> ??::u8\nfalse:i -> 2 * n = 3", "", {}},
	{"s -> ??::string\nw -> \"a\" + s + \"b\" + \"c\"", "{s -> ??0  w -> \"a\" + ??0 + \"bc\"}", {}},
	{"x -> ??::f64\ny -> (x + 0.1) + 0.2\ntrue:r -> x + 1.0 = 1.0 + x", "", {}},
	// sets that depend on unknowns: the form of the operation, simplified
	{"n -> ??::(0..3)\na -> (n | 6) & (n | 7)", "{n -> ??0  a -> (??0 | 6) & (??0 | 7)}", {}},
	{"n -> ??::(0..3)\n(n | 0..3):e -> 2", "", {}}, // n | 0..3 is 0..3: a single set
	{"n -> ??::(0..3)\n(n..10):g -> 5", "", {}}, // n <= 10: 5 is between n and 10
	// a form that depends on unknowns is a color like any other
	{"n -> ??::u64\na -> (n | 6) & >3", "{n -> ??0  a -> (??0 | 6) & 4..}", {}},
	{"n -> ??::u64\n(n..10):g -> 5", "", {.Constraint_Mismatch}}, // n at its maximum: 5 is outside 10..n
	// checking by tiers: envelope, affine, linear extremes, enumeration;
	// what cannot be proved is reported, never accepted
	{"n -> ??::u64\nm -> ??::u64\nu64:d -> n + m", "", {.Constraint_Mismatch}},
	{"u16:z -> (??::u8) * (??::u8)", "", {}},
	{"n -> ??::u64\n(~6):x -> n * 2 + 1", "", {}},
	{"n -> ??::u64\n(~5):x -> n * 2 + 1", "", {.Constraint_Mismatch}},
	{"n -> ??::u64\nm -> ??::u64\n(~5):x -> n * 2 + m * 4 + 1", "", {.Unproven}},
	{"(\"a\" + string):v -> \"b\" + ??::string", "", {.Constraint_Mismatch}},
	// bidirectional: the color descends into a literal scope
	{"Point -> {\n  u8:x\n  u8:y\n}\nPoint:p -> {x -> ??  y -> 2}", "", {}},
	{"Point -> {\n  u8:x\n  u8:y\n}\nLine -> {\n  Point:a\n  Point:b\n}\nLine:l -> {a -> {x -> ??  y -> 1}  b -> {x -> 3  y -> ??}}", "", {}},
	// the algebra of shapes: | & ~ of scopes, a lazy BDD
	{"Point -> {\n  u8:x\n  u8:y\n}\nCircle -> {\n  u8:radius\n}\n(Point | Circle):a -> {x -> 1  y -> 2}\n(Point | Circle):b -> {radius -> 3}", "", {}},
	{"Point -> {\n  u8:x\n  u8:y\n}\nCircle -> {\n  u8:radius\n}\n(Point | Circle):c -> {radius -> 300}", "", {.Constraint_Mismatch}},
	{"Point -> {\n  u8:x\n  u8:y\n}\nOrigin -> {\n  0:x\n  0:y\n}\n(Point & ~Origin):a -> {x -> 1  y -> 0}\ntrue:c -> (Origin & ~Point) = none\ntrue:e -> (Point | Origin) = Point", "", {}},
	{"Point -> {\n  u8:x\n  u8:y\n}\nOrigin -> {\n  0:x\n  0:y\n}\n(Point & ~Origin):b -> {x -> 0  y -> 0}", "", {.Constraint_Mismatch}},
	{"Point -> {\n  u8:x\n  u8:y\n}\nn -> ??::u8\n(Point | {string:name}):p -> {x -> n  y -> n + 1}", "", {.Constraint_Mismatch}},
	{"Point -> {\n  u8:x\n  u8:y\n}\nCircle -> {\n  u8:radius\n}\n(Point | Circle):a -> {x -> ??  y -> 2}", "", {}},
	{"box -> {\n  x -> 1\n  y -> x\n  x -> 2\n}\na -> box.x\nb -> box.y\nc -> box.x#0", "", {}},
	{"empty -> {x -> 1}\ne -> empty!", "{empty -> {x -> 1}  e -> none}", {}},
	{"Point -> {\n  u8:x\n  u8:y\n}\nPoint:p\nq -> p.x", "", {}},
	{"Point -> {\n  u8:x\n  u8:y\n}\nPoint:r -> {x -> 1 y -> 300}", "", {.Constraint_Mismatch}},
	{"Role -> {\n  -> \"member\"\n  -> \"admin\"\n}\nRole:a -> \"admin\"\nRole:c\nd -> c", "", {}},
	{"Role -> {\n  -> \"member\"\n  -> \"admin\"\n}\nRole:b -> \"guest\"", "", {.Constraint_Mismatch}},
	{"F32OrString -> {\n  -> f32:\n  -> string:\n}\nF32OrString:a -> 0.5\nF32OrString:b -> \"x\"", "", {}},
	{"F32OrString -> {\n  -> f32:\n  -> string:\n}\nF32OrString:c -> 3", "", {.Constraint_Mismatch}},
	{"r -> >0.5 & <1.0\nr:a -> 0.75\nr:d", "", {}},
	{"r -> >0.5 & <1.0\nr:b -> 1.0", "", {.Constraint_Mismatch}},
	// strings: regular languages, equality by double inclusion
	{"true:a -> (..10 * \"ab\") = (\"ab\" * 0..10)", "", {}},
	{"(..10 * \"ab\"):x -> \"abab\"", "", {}},
	{"(..10 * \"ab\"):x -> \"aba\"", "", {.Constraint_Mismatch}},
	{"true:a -> (2|1) = (2..1)", "", {}},
	{"true:a -> (2|\"a\"|3..4) = (\"a\"|2..4)", "", {}},
	{"a -> 'a'..'z' * 2..3 + \"!\"\na:x -> \"ab!\"\na:y -> \"a!\"", "", {.Constraint_Mismatch}},
	{"(\"jwt\"..\"lel\"):x -> \"jwtXlel\"", "", {}},
	{"(\"a\"..\"z\"):c -> 'b'", "", {.Constraint_Mismatch}}, // \"a\"..\"z\": starts with a, ends with z
	{"('a'..'z'):c -> 'b'", "", {}}, // 'a'..'z': a character from a to z
	{"(~'\\0' * 0.. + '\\0'):s -> \"a\\0c\\0\"", "", {.Constraint_Mismatch}},
	{"(~'\\0' * 0.. + '\\0'):s -> \"abc\\0\"", "", {}},
	{"(~\"piro\"):s -> \"pira\"", "", {}},
	{"x -> ''..", "{x -> char}", {}}, // ''..: any character
	// characters: a sort, admitted by a string color
	{"string:s -> 'c'", "", {}},
	{"char:c -> \"a\"", "", {.Constraint_Mismatch}},
	{"true:a -> 'a' = \"a\"", "", {.Constraint_Mismatch}},
	{"a -> 'a' + 'b'", "{a -> \"ab\"}", {}},
	{"char:c", "{char:c -> ''}", {}},
	// the color requires membership: a set of several values is not
	// an element of u8; {-> u8} admits only the value u8
	{"u8:a -> u8", "", {.Constraint_Mismatch}},
	{"x -> u8\nu8:y -> x", "", {.Constraint_Mismatch}},
	{"n -> ??::u8\nu8:y -> n", "", {}}, // an unknown element of u8
	{"{-> u8}:a -> u8", "{{-> 0..255}:a -> 0..255}", {}},
	{"P -> {-> u8}\nP:x\ny -> x", "{P -> {-> 0..255}  {-> 0..255}:x -> 0..255  y -> 0..255}", {}}, // the default: the first production
	{"n -> ??::(0..3)\n{-> 0..3}:z -> n | 0..3", "{n -> ??0  {-> 0..3}:z -> 0..3}", {}},
	{"n -> ??::(0..3)\n{-> 0..3}:w -> n | 1..3", "", {.Constraint_Mismatch}}, // n = 1: 1..3
	{"C -> {-> {x -> 1}}\nC:a -> {x -> 1}\nC:b -> {x -> 2}", "", {.Constraint_Mismatch}}, // the exact value, not its shape
	// carve: a symbolic copy, the arguments in place of the values, re-typed
	{"box -> {\n  x -> 1\n  y -> x + 1\n}\nbox2 -> box{x -> 10}\na -> box2.y\nb -> box.y", "{box -> {x -> 1  y -> 2}  box2 -> {x -> 10  y -> 11}  a -> 11  b -> 2}", {}},
	{"Config -> {\n  port -> \"8080\"\n  url -> \"localhost:\" + port\n  port -> \"3000\"\n}\nDev -> Config{port -> \"9000\"}\na -> Dev.port\nb -> Dev.url\nc -> Config{port#1 -> \"1\"}.port", "{Config -> {port -> \"8080\"  url -> \"localhost:8080\"  port -> \"3000\"}  Dev -> {port -> \"9000\"  url -> \"localhost:9000\"  port -> \"3000\"}  a -> \"3000\"  b -> \"localhost:9000\"  c -> \"1\"}", {}},
	// `C:p{…}`: p, colored by C, is the default of C, carved
	{"Color -> {\n  u8:r\n  u8:g\n}\nColor:o{r -> 240, g -> 120}", "{Color -> {0..255:r -> 0  0..255:g -> 0}  {0..255:r -> 0  0..255:g -> 0}:o -> {0..255:r -> 240  0..255:g -> 120}}", {}},
	{"Color -> {\n  u8:r\n  u8:g\n}\nColor:o{r -> 240, g -> 300}", "", {.Constraint_Mismatch}},
	{"Color -> {\n  u8:r\n}\nColor:o{w -> 1}", "", {.Invalid_Carve}},
	{"Circle -> {u8:r}\nSquare -> {u8:w  u8:h}\nShape -> {\n  -> Circle:\n  -> Square:\n}\nShape:s{r -> 3}", "", {}}, // the default: the first production
	// a colored production prints as `-> C:`, `-> C:(v)`
	{"S -> {\n  -> u8:\n  -> string:\n}\nT -> {-> u8:(5)}", "{S -> {-> 0..255:(0)  -> string:(\"\")}  T -> {-> 0..255:(5)}}", {}},
	// a self-reference is the unknown of type X: neither copied nor unfolded
	{"f -> {\n  u8:n\n  -> f{n -> n}\n}", "{f -> {0..255:n -> 0  -> f}}", {}}, // the same arguments: f itself
	// its arguments are checked like those of any carve: n is 1, n - 1 ∉ 1..255;
	// with other arguments, it is the equation applied to other types
	{"f -> {\n  1..255:n\n  -> f{n -> n - 1}\n}\n-> 0", "", {.Constraint_Mismatch}},
	// a recursive call is an unknown of the equation: as long as it is not
	// solved, what depends on it is not proved
	// solved when we know how: the sum Y(n) = n + Y(n - 1), Y(0) = 0 has the closed
	// form n·(n+1)/2; a call applies it to its argument, without unrolling
	{"f -> {\n  u8:n -> ??\n  -> n ? {0 -> 0, -> n + f{n -> n - 1}!}\n}", "{f -> {0..255:n -> ??0  -> (??0 + ??0*??0)/2}}", {}},
	{"f -> {\n  u8:n -> ??\n  -> n ? {0 -> 0, -> n + f{n -> n - 1}!}\n}\nu16:r -> f{n -> ??}!", "", {}},
	{"f -> {\n  u8:n -> ??\n  -> n ? {0 -> 0, -> n + f{n -> n - 1}!}\n}\nu8:r -> f{n -> ??}!", "", {.Constraint_Mismatch}}, // 255·256/2 = 32640
	{"f -> {\n  u8:n -> ??\n  -> n ? {0 -> 0, -> n + f{n -> n - 1}!}\n}\nfive -> f{n -> 5}!", "{f -> {0..255:n -> ??0  -> (??0 + ??0*??0)/2}  five -> 15}", {}},
	// an equation that cannot be solved yet remains an equation: not proved
	{"g -> {\n  u8:n -> ??\n  -> n ? {0 -> 1, -> 2 * g{n -> n - 1}!}\n}\nu16:r -> g{n -> ??}!", "", {.Unproven}},
	// a recursive call on an unknown, against a color that depends on it
	{"f -> {\n  u8:n -> ??\n  -> n ? {0 -> 0, -> n + f{n -> n - 1}!}\n}\nm -> ??::u8\n(0..(m * (m + 1) / 2)):t -> f{m}!", "", {}},
	{"f -> {\n  u8:n -> ??\n  -> n ? {0 -> 0, -> n + f{n -> n - 1}!}\n}\nm -> ??::u8\n(0..m):w -> f{m}!", "", {.Constraint_Mismatch}}, // m = 2: 3
	{"m -> ??::u8\nx -> m * (m + 1) / 2\ny -> m * 3 / 2", "{m -> ??0  x -> (??0 + ??0*??0)/2  y -> 3*??0 / 2}", {}}, // exact when 2 divides it for every m
	{"f -> {\n  u8:n -> 5\n  -> f{n -> n}!\n}", "", {.Infinite_Recursion}},
	// recursive types: read on the value, without unfolding anything
	{"Array -> {\n  T -> {}\n  -> {}\n  -> {T: ...Array{T}:}\n}\nArray{u8}:a -> {1 2 3}", "", {}},
	{"Array -> {\n  T -> {}\n  -> {}\n  -> {T: ...Array{T}:}\n}\nArray{u8}:a -> {1 \"x\"}", "", {.Constraint_Mismatch}},
	{"Array -> {\n  T -> {}\n  -> {}\n  -> {T: ...Array{T}:}\n}\nArray{u8}:a", "", {}}, // the default: {}
	// a recursive type whose color depends on an unknown, read on the value
	{"Array -> {\n  T -> {}\n  -> {}\n  -> {T: ...Array{T}:}\n}\nn -> ??::u8\nArray{0..n}:c -> {0 n}\nArray{0..n}:e", "", {}},
	{"Array -> {\n  T -> {}\n  -> {}\n  -> {T: ...Array{T}:}\n}\nn -> ??::u8\nArray{0..n}:d -> {0 n + 1}", "", {.Constraint_Mismatch}},
	{"n -> ??::u8\nP -> {(0..n):x}\nP:p", "{n -> ??0  P -> {0..??0:x -> 0}  {0..??0:x -> 0}:p -> {0..??0:x -> 0}}", {}}, // 0 is in 0..n whatever n
	{"Tree -> {\n  T -> {}\n  -> {}\n  -> {Tree{T}:l  T:v  Tree{T}:r}\n}\nTree{u8}:t -> {l -> {}  v -> 5  r -> {l -> {}  v -> 6  r -> {}}}", "", {}},
	{"Tree -> {\n  T -> {}\n  -> {}\n  -> {Tree{T}:l  T:v  Tree{T}:r}\n}\nTree{u8}:t -> {l -> {}  v -> 5  r -> {l -> {}  v -> 300  r -> {}}}", "", {.Constraint_Mismatch}},
	{"Balanced -> {\n  -> {}\n  -> {u8: ...Balanced:  string:}\n}\nBalanced:b -> {1 2 \"a\" \"b\"}", "", {}},
	{"Balanced -> {\n  -> {}\n  -> {u8: ...Balanced:  string:}\n}\nBalanced:b -> {1 \"a\" 2}", "", {.Constraint_Mismatch}},
	// the base case comes first, is not recursive, and terminates
	{"Endless -> {\n  T -> {}\n  -> {T: ...Endless{T}:}\n}", "", {.Infinite_Recursion}},
	{"Unguarded -> {\n  -> {...Unguarded:}\n  -> {}\n}", "", {.Infinite_Recursion}},
	// a pattern on an unknown gives a type by cases; the context of each
	// branch decides (specs/equational.md §3)
	{"v -> ??::u8\nc -> v + 3\nu8:l -> v ? {<10 -> c, -> 10}", "{v -> ??0  c -> ??0 + 3  0..255:l -> ??0 ? {0..9 -> ??0 + 3  10..255 -> 10}}", {}},
	{"v -> ??::u8\nc -> v + 3\nu8:l -> c", "", {.Constraint_Mismatch}},
	{"v -> ??::u8\nr -> v ? {<10 -> v ? {<10 -> 1}, -> 2}", "{v -> ??0  r -> ??0 ? {0..9 -> 1  10..255 -> 2}}", {}},
	{"v -> ??::u8\nu8:t -> (v ? {<50 -> v, -> 0}) + 200", "", {}},
	{"v -> ??::u8\nu8:t -> (v ? {<60 -> v, -> 0}) + 200", "", {.Constraint_Mismatch}},
	{"v -> ??::u8\ntrue:w -> v ? {<10 -> v < 20, -> true}", "", {}},
	{"v -> ??::u8\ntrue:w -> v ? {<30 -> v < 20, -> true}", "", {.Constraint_Mismatch}},
	// the cast `\` forces a value into a layout; it binds less tightly than
	// arithmetic: `a + b \ u8` is `(a + b) \ u8`
	{"a -> 200\nb -> 100\nc -> a + b \\ u8\nd -> -1 \\ u8\ne -> 200 \\ i8\nf -> 'A' \\ u8\ng -> true \\ u8", "{a -> 200  b -> 100  c -> 44  d -> 255  e -> -56  f -> 65  g -> 1}", {}},
	{"n -> ??::u8\nu8:c -> n + 1 \\ u8", "{n -> ??0  0..255:c -> ??0 + 1 \\ 0..255}", {}},
	{"n -> ??::u8\nu16:c -> n + 1 \\ u16", "{n -> ??0  0..65535:c -> ??0 + 1}", {}}, // it already fits
	{"a -> 5 \\ int", "", {.Invalid_Cast}},
	{"a -> 5 \\ 10..37", "", {.Invalid_Cast}},
	{"a -> 5::u8", "", {.Invalid_Cast}}, // `::` only writes the type of an unknown
	// division: truncated toward zero, the remainder with the sign of the dividend;
	// a divisor that can be 0, in the context, is an error
	{"a -> 10 / 3\nb -> 10 % 3\nc -> -7 / 2\nd -> -7 % 2\nx -> 1.0 / 4.0", "{a -> 3  b -> 1  c -> -3  d -> -1  x -> 0.25}", {}},
	{"n -> ??::u8\ne -> n / 2\nf -> n % 256\nu8:g -> n / 1", "{n -> ??0  e -> ??0 / 2  f -> ??0  0..255:g -> ??0}", {}},
	{"n -> ??::u8\nh -> 10 / n", "", {.Invalid_operator}},
	{"n -> ??::u8\ni -> n ? {0 -> 0, -> 100 / n}", "", {}},
	{"n -> ??::u8\nu8:q -> n / 2 + 128", "", {}}, // 0..127 + 128
	{"n -> ??::u8\nu8:q -> n / 2 + 129", "", {.Constraint_Mismatch}},
	// a scope sees its own name only in its productions
	{"ones -> {1 ...ones}", "", {.Undefined_Identifier}},
	{"X -> {\n  X:child\n  -> {}\n}", "", {.Undefined_Identifier}},
	{"square -> {\n  n -> 0\n  -> n * n\n}\nr -> square{n -> 5}!", "{square -> {n -> 0  -> 0}  r -> 25}", {}},
	{"a -> {\n  x -> 1\n  b -> {-> x}\n}\nc -> a{x -> 2}.b!\nd -> a.b!", "{a -> {x -> 1  b -> {-> 1}}  c -> 2  d -> 1}", {}}, // the scopes written inside follow the copy
	{"a -> {u8:d}\nb -> a{d -> ??}", "{a -> {0..255:d -> 0}  b -> {0..255:d -> ??0}}", {}}, // the argument takes the color of the binding it replaces
	{"Box -> {\n  T -> u8\n  T:v -> 0\n}\nn -> ??::u8\nb -> Box{T -> u16  v -> n * 300}", "", {.Constraint_Mismatch}}, // the color is re-typed: 300·n ∉ u16
	{"User -> {u8:age}\nUser{raole -> 1}", "", {.Invalid_Carve}}, // a scope is closed
	{"a -> {x -> 1}\na{x -> 2  x -> 3}", "", {.Invalid_Carve}},
	{"x -> 5\nx{1}", "", {.Invalid_Carve}},
	{"{string:}:a -> {\"\"}\nb -> a{\"x\"}\nb{0}", "", {.Constraint_Mismatch}}, // implicit coloring follows the copies
	{"Box -> {u8:n}\nPt -> {Box -> {u16:n}}\np -> Pt{Box{300}}", "", {}}, // z{…}: the field z wins over the visible z
	{"a -> {x -> 1}\nb -> a{zz{1}}", "", {.Undefined_Identifier}}, // neither a field nor a visible name
	{"a -> .z", "", {.Invalid_Property_Access}}, // `.x` without a source outside the arguments of a carve
	// holes: `<-` fills them, positions skip them, the carve infers the others
	{"id -> {\n  T <- none\n  T:v -> none\n  -> v\n}\nr -> id{v -> 5}!", "{id -> {T <- none  none:v -> none  -> none}  r -> 5}", {}},
	{"id -> {\n  T <- none\n  T:v -> none\n  -> v\n}\nr -> id{T <- u8 v -> 5}!", "", {}}, // required u8, 5 is in it
	{"id -> {\n  T <- none\n  T:v -> none\n  -> v\n}\nr -> id{T <- 4 v -> 5}!", "", {.Constraint_Mismatch}},
	{"id -> {\n  T <- none\n  T:v -> none\n}\nr -> id{T -> u8}", "", {.Invalid_Carve}}, // a hole is filled with <-
	{"id -> {\n  T <- none\n  T:v -> none\n}\nr -> id{v <- 5}", "", {.Invalid_Carve}}, // a field is filled with ->
	{"a -> {\n  u8:e <- 2\n  -> e\n}\nr -> a{e <- 300}!", "", {.Constraint_Mismatch}}, // the color of the hole applies
	{"a -> {\n  e <- 2\n  -> e\n}\nr -> a{<- 3}", "", {.Invalid_Binding_Name}}, // a hole carries a name
	{"B -> {\n  T <- u8\n  T:v\n  {T:w}:s -> {w -> 0}\n}\nr -> B{s -> {u8:w -> 1}}", "", {}}, // the received color of a field: a required type
	{"B -> {\n  T <- u8\n  T:v\n  {T:w}:s -> {w -> 0}\n}\nr -> B{v -> 300  s -> {u8:w -> 1}}", "", {.Constraint_Mismatch}}, // 300 ∉ u8, required by s
	{"B -> {\n  T <- u8\n  {T:w}:s -> {w -> 0}\n  {T:w}:t -> {w -> 0}\n}\nr -> B{s -> {u8:w -> 1}  t -> {u16:w -> 1}}", "", {.Constraint_Mismatch}}, // two different required types
	{"a -> {\n  e <- 2\n  u8:x -> e + 1\n}\nr -> a{x -> 6}", "", {.Unsupported}}, // a hole written inside an operation
	// pattern: the value is covered, an unknown is restricted in each branch
	{"a -> ??::u8\nu8:r -> a ? {<255 -> a + 1  -> 0}", "", {}},
	{"a -> ??::u8\nu8:r -> a ? {>0 -> a + 1  -> 0}", "", {.Constraint_Mismatch}},
	{"u8:x -> 5\nr -> x ? {=5 -> 1}", "{0..255:x -> 5  r -> 1}", {}}, // the value 5, not the color u8
	{"u8:x -> ??\nr -> x ? {=5 -> 1}", "", {.Non_Exhaustive_Pattern}},
	{"r -> 5 ? {=7 -> 300  -> 0}\nu8:z -> r", "", {}}, // a branch that does not fire is not typed
	{"a -> ??::u8\nr -> a ? {\n  -> 0\n  =5 -> 300\n}\nu8:z -> r", "", {}}, // the default branch takes everything
	{"Circle -> {u8:radius}\nSquare -> {u8:side}\nr -> Circle{radius -> 7} ? {Square: -> 2  Circle: -> 1}", "{Circle -> {0..255:radius -> 0}  Square -> {0..255:side -> 0}  r -> 1}", {}},
	{"r -> 3 ? {u8: -> 1  -> 2}", "{r -> 2}", {}}, // u8: is the default of u8: 0
	{"Circle -> {u8:radius}\nr -> Circle ? {Circle: -> radius}", "", {.Unsupported}}, // destructuring
	// expansion: `...E` lays down the bindings of the value of E, as they are
	{"xs -> {2 3}\nys -> {1 ...xs 4}", "{xs -> {2  3}  ys -> {1  2  3  4}}", {}},
	{"p -> {...{-> 5}}\nq -> p!", "{p -> {-> 5}  q -> 5}", {}}, // a laid-down production
	{"a -> {x -> 1}\nb -> {x -> 0  ...a}\nl -> b.x\nf -> b.x#0", "{a -> {x -> 1}  b -> {x -> 0  x -> 1}  l -> 1  f -> 0}", {}}, // a second occurrence
	{"b -> {...5}", "", {.Invalid_Expansion}},
	{"a -> {u8:x -> 1\n  u8:y -> x + 1}\nb -> {...a  z -> 9}\nd -> b{x -> 5}.y", "", {}}, // the carve goes through the expansion
	{"a -> {u8:x -> 1\n  u8:y -> x + 200}\nb -> {...a  z -> 9}\nc -> b{x -> 100}", "", {.Constraint_Mismatch}},
	{"xs -> {2 3}\nys -> {1 ...xs}\nzs -> ys{9 8 7}", "{xs -> {2  3}  ys -> {1  2  3}  zs -> {9  8  7}}", {}}, // positions through the expansion
	{"{u8: u8: u8:}:ys -> {1 ...{2 300}}", "", {.Constraint_Mismatch}},
	{"a -> {x -> 1}\nb -> {...a}\nc -> b{x -> 2 x -> 3}", "", {.Invalid_Carve}},
	// a colored expansion is a run: any scope that its color admits
	{"{... u8:b}:a -> {1 \"x\" {} b -> 5}", "", {}},
	{"{... u8:b}:a -> {b -> 300}", "", {.Constraint_Mismatch}},
	{"{... u8:b}:a -> {1 2}", "", {.Constraint_Mismatch}}, // no b at the end
	{"{u8:x ...}:a -> {x -> 3  y -> \"z\"  4}", "", {}},
	{"Pair -> {u8: u8:}\n{...Pair: string:}:a -> {1 2 \"x\"}", "", {}},
	{"Pair -> {u8: u8:}\n{...Pair: string:}:z -> {1 \"x\"}", "", {.Constraint_Mismatch}},
	{"q -> {...u8:}", "", {.Invalid_Expansion}}, // the default of u8 is not a scope
	{"y -> x", "", {.Undefined_Identifier}},
	{"a -> {x -> 1}\nb -> a.z", "", {.Invalid_Property_Access}},
}

@(test)
test_cases :: proc(t: ^testing.T) {
	for c in CASES {
		arena: vmem.Arena
		context.allocator = vmem.arena_allocator(&arena)
		program, k, parsed := run(c.source)
		testing.expectf(t, parsed, "parse: %q", c.source)
		if parsed {
			got := error_kinds(k.errors[:])
			testing.expectf(t, slice.equal(got, sorted_kinds(c.errors)), "%q\n  errors: %v, expected %v\n  %s", c.source, got, c.errors, describe_errors(k.errors[:]))
			if c.typed != "" {
				printed := print_type(new_expr(program))
				testing.expectf(t, printed == c.typed, "%q\n  typed:    %s\n  expected: %s", c.source, printed, c.typed)
			}
		}
		vmem.arena_destroy(&arena)
	}
}

// An error in a copy is reported at the carve that caused it (`carve ← source`),
// only once; what the carve does not change is reported in the source.
Site_Case :: struct {
	source: string,
	sites:  []string,
}

SITE_CASES := []Site_Case {
	{"Box -> {\n  u8:x -> 1\n  u8:y -> x + 200\n}\nb -> Box{x -> 100}\nc -> Box{x -> 100}", {"5:9 ← 3:3", "6:9 ← 3:3"}},
	{"Box -> {\n  u8:x -> 1\n  u8:y -> 300\n}\nb -> Box{x -> 2}", {"3:3"}},
	{"Box -> {\n  T -> u8\n  T:v -> 0\n}\nn -> ??::u8\nb -> Box{v -> n * 2}", {"6:10 ← 3:3"}}, // the carved value: at the argument
	{"Inner -> {\n  u8:a -> 0\n}\nBox -> {\n  x -> 1\n  w -> Inner{a -> x}\n}\nb -> Box{x -> 300}", {"8:9 ← 2:3"}},
	{"Pair -> {\n  u8:a\n  u8:b\n}\np -> Pair{7}\nq -> p{b -> 300}\nr -> q{a -> 1}", {"6:8 ← 3:3"}},
	{"P8 -> {\n  u8:x\n}\nP16 -> {\n  u16:x\n}\nWrap -> {\n  S -> P16\n  S:p -> {x -> 300}\n}\nw -> Wrap{S -> P8}", {"11:10 ← 9:11"}}, // the implicit color
	{"Box -> {\n  n -> ??::u8\n  u8:y -> n * 2\n  x -> 1\n}\nb -> Box{x -> 5}", {"3:3"}},
	{"f -> {\n  u8:x -> 5\n  -> x ? {=5 -> 1}\n}\ng -> f{x -> 6}!", {"5:7 ← 3:6"}},
	{"{u8: u8: u8:}:ys -> {1 ...{2 300}}", {"1:30"}}, // an expanded literal receives the shape in its place
	{"xs -> {2 300}\n{u8: u8: u8:}:ys -> {1 ...xs}", {"2:1 ← 1:10"}}, // a value received from elsewhere: at the binding, written where the 300 is
	{"p -> {x -> 1  y -> {z -> 300}}\n{u8:x  {u8:z}:y}:q -> p", {"2:1 ← 1:21"}}, // at the deepest // a carve that makes the pattern non-exhaustive
}

@(test)
test_carve_error_sites :: proc(t: ^testing.T) {
	for c in SITE_CASES {
		arena: vmem.Arena
		context.allocator = vmem.arena_allocator(&arena)
		_, k, parsed := run(c.source)
		testing.expectf(t, parsed, "parse: %q", c.source)
		got := make([dynamic]string)
		for e in k.errors {
			at := syn.span_to_position(k.ast, e.span.start)
			site := fmt.tprintf("%d:%d", at.line, at.column)
			if e.origin != e.span {
				src := syn.span_to_position(k.ast, e.origin.start)
				site = fmt.tprintf("%s ← %d:%d", site, src.line, src.column)
			}
			append(&got, site)
		}
		testing.expectf(t, slice.equal(got[:], c.sites), "%q\n  errors at %v, expected %v\n  %s", c.source, got[:], c.sites, describe_errors(k.errors[:]))
		vmem.arena_destroy(&arena)
	}
}

// A binding carries its color and its value as written, and their types: the
// type simplifies, the value keeps all the structure that produced it.
@(test)
test_value_and_type :: proc(t: ^testing.T) {
	arena: vmem.Arena
	context.allocator = vmem.arena_allocator(&arena)
	defer vmem.arena_destroy(&arena)
	program, k, parsed := run("n -> ??::u8\nu16:x -> n * 2 - n + (1 + 2)\nb -> {-> n}\ny -> b!\nsq -> {\n  m -> 0\n  -> m * m\n}\nz -> sq{m -> n}!")
	testing.expect(t, parsed && len(k.errors) == 0, "the program is valid")
	testing.expect_value(t, print_expr(new_expr(program)), "{n -> ??::u8  u16:x -> n * 2 - n + (1 + 2)  b -> {-> n}  y -> b!  sq -> {m -> 0  -> m * m}  z -> sq{m -> n}!}")
	testing.expect_value(t, print_type(new_expr(program)), "{n -> ??0  0..65535:x -> ??0 + 3  b -> {-> ??0}  y -> ??0  sq -> {m -> 0  -> 0}  z -> ??0*??0}")
}

// The corpus of test/typecheck: each source whose forms are all in the kernel
// must give exactly the expected errors. The sources that touch a form not
// implemented yet are counted separately.
Corpus_Case :: struct {
	name:          string `json:"name"`,
	source:        string `json:"source"`,
	expect_errors: []string `json:"expect_errors"`,
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
		want := slice.clone(c.expect_errors)
		slice.sort(want)
		want = slice.unique(want)
		if slice.equal(got[:], want) {
			passed += 1
			if len(want) > 0 do passed_with_errors += 1
		} else {
			append(&failures, fmt.tprintf("%s: got %v, expected %v\n    %s\n%s", c.name, got, want, describe_errors(k.errors[:]), indent(c.source)))
		}
	}
	log.infof("corpus typecheck: %d pass (%d of which expect an error), %d fail, %d out of the kernel, %d do not parse (out of %d)", passed, passed_with_errors, len(failures), skipped, unparsed, len(files))
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
	return strings.join(parts[:], "; ")
}

indent :: proc(s: string) -> string {
	lines, _ := strings.split_lines(s)
	for &l in lines do l = fmt.tprintf("      | %s", l)
	return strings.join(lines, "\n")
}

// An equation solved by Arden: the color of the binding `x`, printed as a
// set (specs/kernel-recursion.md §5).
@(test)
test_recursive_solved :: proc(t: ^testing.T) {
	arena: vmem.Arena
	context.allocator = vmem.arena_allocator(&arena)
	defer vmem.arena_destroy(&arena)
	SOLVED :: [?][2]string {
		{"Array -> {\n  T -> {}\n  -> {}\n  -> {T: ...Array{T}:}\n}\nArray{u8}:x", "{0..*0..255:}"},
		{"Rev -> {\n  T -> {}\n  -> {}\n  -> {...Rev{T}:  T:}\n}\nRev{u8}:x", "{0..*0..255:}"},
		{"NonEmpty -> {\n  T -> {}\n  -> {T:}\n  -> {T: ...NonEmpty{T}:}\n}\nNonEmpty{u8}:x -> {1}", "{0..*0..255:  0..255:}"},
		{"Pairs -> {\n  -> {}\n  -> {u8: string: ...Pairs:}\n}\nPairs:x", "{0..*(0..255:  string:)}"},
	}
	for c in SOLVED {
		program, k, parsed := run(c[0])
		testing.expect(t, parsed)
		b := program.bindings[len(program.bindings) - 1]
		set, closed := normal_set(&k, b.color_type)
		testing.expect(t, closed)
		testing.expect_value(t, print_set(set), c[1])
		testing.expect_value(t, len(k.errors), 0)
	}
}
