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

// Un cas : la source, les types attendus du scope (vide = ne pas comparer) et
// les erreurs attendues.
Test_Case :: struct {
	source: string,
	typed:  string,
	errors: []Error_Kind,
}

CASES := []Test_Case {
	{"x -> 1\ny -> x + 2", "{x -> 1  y -> 3}", {}},
	{"u8:a -> ??\nu8:b -> ??\nu16:c -> a + b", "{0..255:a -> ??0  0..255:b -> ??1  0..65535:c -> ??0 + ??1}", {}},
	{"u8:a -> ??\nu8:d -> a + a", "", {.Constraint_Mismatch}},
	{"u8 -> 5", "", {}}, // un builtin n'est qu'un nom : un binding peut le masquer
	{"e -> 0..255\nf -> >0", "{e -> 0..255  f -> 1..}", {}},
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
	{"a -> ~bool\nb -> ~a\nc -> 0 & 1\nd -> u8 & string\ne -> ~c", "{a -> ~bool  b -> bool  c -> ~int  d -> none  e -> int}", {}},
	// les scopes : un scope est son propre type, ses bindings portent les leurs
	{"b -> {\n  n -> ??::u8\n  -> n * 2\n}\nc -> b.n\nd -> b!", "{b -> {n -> ??0  -> 2*??0}  c -> ??0  d -> 2*??0}", {}},
	// les inconnues : des formes normales, des valeurs exactes quand on peut les énumérer
	{"n -> ??::u8\na -> n - n\nb -> n * 3 + n\nc -> (n + 1) * 2", "{n -> ??0  a -> 0  b -> 4*??0  c -> 2*??0 + 2}", {}},
	{"n -> ??::u8\nu8:e -> n - n", "", {}},
	{"n -> ??::u8\nm -> ??::u8\nu16:f -> n * m", "", {}},
	{"n -> ??::u8\nm -> ??::u8\nu8:f -> n * m", "", {.Constraint_Mismatch}},
	{"n -> ??::u8\ntrue:g -> n < n + 1", "", {}},
	{"n -> ??::u8\nfalse:i -> 2 * n = 3", "", {}},
	{"s -> ??::string\nw -> \"a\" + s + \"b\" + \"c\"", "{s -> ??0  w -> \"a\" + ??0 + \"bc\"}", {}},
	{"x -> ??::f64\ny -> (x + 0.1) + 0.2\ntrue:r -> x + 1.0 = 1.0 + x", "", {}},
	// les ensembles qui dépendent d'inconnues : la forme de l'opération, simplifiée
	{"n -> ??::(0..3)\na -> (n | 6) & (n | 7)", "{n -> ??0  a -> (??0 | 6) & (??0 | 7)}", {}},
	{"n -> ??::(0..3)\n(n | 0..3):e -> 2", "", {}}, // n | 0..3 est 0..3 : un seul ensemble
	{"n -> ??::(0..3)\n(n..10):g -> 5", "", {.Insoluble_Constraint}},
	// une forme dépend d'inconnues : jamais une couleur, même trop grande pour être énumérée
	{"n -> ??::u64\na -> (n | 6) & >3", "{n -> ??0  a -> (??0 | 6) & 4..}", {}},
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
	// l'algèbre des formes : | & ~ de scopes, un BDD paresseux
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
	{"x -> ''..", "{x -> char}", {}}, // ''.. : n'importe quel caractère
	// les caractères : une sorte, admise par une couleur string
	{"string:s -> 'c'", "", {}},
	{"char:c -> \"a\"", "", {.Constraint_Mismatch}},
	{"true:a -> 'a' = \"a\"", "", {.Constraint_Mismatch}},
	{"a -> 'a' + 'b'", "{a -> \"ab\"}", {}},
	{"char:c", "{char:c -> ''}", {}},
	// la couleur demande l'appartenance : un ensemble de plusieurs valeurs n'est pas
	// un élément de u8 ; {-> u8} n'admet que la valeur u8
	{"u8:a -> u8", "", {.Constraint_Mismatch}},
	{"x -> u8\nu8:y -> x", "", {.Constraint_Mismatch}},
	{"n -> ??::u8\nu8:y -> n", "", {}}, // un élément inconnu de u8
	{"{-> u8}:a -> u8", "{{-> 0..255}:a -> 0..255}", {}},
	{"P -> {-> u8}\nP:x\ny -> x", "{P -> {-> 0..255}  {-> 0..255}:x -> 0..255  y -> 0..255}", {}}, // le défaut : la première production
	{"n -> ??::(0..3)\n{-> 0..3}:z -> n | 0..3", "{n -> ??0  {-> 0..3}:z -> 0..3}", {}},
	{"n -> ??::(0..3)\n{-> 0..3}:w -> n | 1..3", "", {.Constraint_Mismatch}}, // n = 1 : 1..3
	{"C -> {-> {x -> 1}}\nC:a -> {x -> 1}\nC:b -> {x -> 2}", "", {.Constraint_Mismatch}}, // la valeur exacte, pas sa forme
	// le carve : une copie symbolique, les arguments à la place des valeurs, re-typée
	{"box -> {\n  x -> 1\n  y -> x + 1\n}\nbox2 -> box{x -> 10}\na -> box2.y\nb -> box.y", "{box -> {x -> 1  y -> 2}  box2 -> {x -> 10  y -> 11}  a -> 11  b -> 2}", {}},
	{"Config -> {\n  port -> \"8080\"\n  url -> \"localhost:\" + port\n  port -> \"3000\"\n}\nDev -> Config{port -> \"9000\"}\na -> Dev.port\nb -> Dev.url\nc -> Config{port#1 -> \"1\"}.port", "{Config -> {port -> \"8080\"  url -> \"localhost:8080\"  port -> \"3000\"}  Dev -> {port -> \"9000\"  url -> \"localhost:9000\"  port -> \"3000\"}  a -> \"3000\"  b -> \"localhost:9000\"  c -> \"1\"}", {}},
	// `C:p{…}` : p, coloré par C, vaut le défaut de C carvé
	{"Color -> {\n  u8:r\n  u8:g\n}\nColor:o{r -> 240, g -> 120}", "{Color -> {0..255:r -> 0  0..255:g -> 0}  {0..255:r -> 0  0..255:g -> 0}:o -> {0..255:r -> 240  0..255:g -> 120}}", {}},
	{"Color -> {\n  u8:r\n  u8:g\n}\nColor:o{r -> 240, g -> 300}", "", {.Constraint_Mismatch}},
	{"Color -> {\n  u8:r\n}\nColor:o{w -> 1}", "", {.Invalid_Carve}},
	{"Circle -> {u8:r}\nSquare -> {u8:w  u8:h}\nShape -> {\n  -> Circle:\n  -> Square:\n}\nShape:s{r -> 3}", "", {}}, // le défaut : la première production
	// une production colorée s'imprime `-> C:`, `-> C:(v)`
	{"S -> {\n  -> u8:\n  -> string:\n}\nT -> {-> u8:(5)}", "{S -> {-> 0..255:(0)  -> string:(\"\")}  T -> {-> 0..255:(5)}}", {}},
	// une self-référence est l'inconnue de type X : ni copiée, ni dépliée
	{"f -> {\n  u8:n\n  -> f{n -> n}\n}", "{f -> {0..255:n -> 0  -> f}}", {}}, // les mêmes arguments : f lui-même
	// ses arguments se vérifient comme ceux de tout carve : n vaut 1, n - 1 ∉ 1..255 ;
	// avec d'autres arguments, c'est l'équation appliquée à d'autres types
	{"f -> {\n  1..255:n\n  -> f{n -> n - 1}\n}\n-> 0", "", {.Constraint_Mismatch}},
	// un appel récursif est une inconnue de l'équation : tant qu'elle n'est pas
	// résolue, ce qui en dépend n'est pas prouvé
	// résolue quand on sait : la somme Y(n) = n + Y(n - 1), Y(0) = 0 a la forme close
	// n·(n+1)/2 ; un appel l'applique à son argument, sans dérouler
	{"f -> {\n  u8:n -> ??\n  -> n ? {0 -> 0, -> n + f{n -> n - 1}!}\n}", "{f -> {0..255:n -> ??0  -> (??0 + ??0*??0)/2}}", {}},
	{"f -> {\n  u8:n -> ??\n  -> n ? {0 -> 0, -> n + f{n -> n - 1}!}\n}\nu16:r -> f{n -> ??}!", "", {}},
	{"f -> {\n  u8:n -> ??\n  -> n ? {0 -> 0, -> n + f{n -> n - 1}!}\n}\nu8:r -> f{n -> ??}!", "", {.Constraint_Mismatch}}, // 255·256/2 = 32640
	{"f -> {\n  u8:n -> ??\n  -> n ? {0 -> 0, -> n + f{n -> n - 1}!}\n}\nfive -> f{n -> 5}!", "{f -> {0..255:n -> ??0  -> (??0 + ??0*??0)/2}  five -> 15}", {}},
	// une équation qu'on ne sait pas encore résoudre reste une équation : pas prouvé
	{"g -> {\n  u8:n -> ??\n  -> n ? {0 -> 1, -> 2 * g{n -> n - 1}!}\n}\nu16:r -> g{n -> ??}!", "", {.Unproven}},
	{"f -> {\n  u8:n -> 5\n  -> f{n -> n}!\n}", "", {.Infinite_Recursion}},
	// les types récursifs : lus sur la valeur, sans rien déplier
	{"Array -> {\n  T -> {}\n  -> {}\n  -> {T: ...Array{T}:}\n}\nArray{u8}:a -> {1 2 3}", "", {}},
	{"Array -> {\n  T -> {}\n  -> {}\n  -> {T: ...Array{T}:}\n}\nArray{u8}:a -> {1 \"x\"}", "", {.Constraint_Mismatch}},
	{"Array -> {\n  T -> {}\n  -> {}\n  -> {T: ...Array{T}:}\n}\nArray{u8}:a", "", {}}, // le défaut : {}
	{"Tree -> {\n  T -> {}\n  -> {}\n  -> {Tree{T}:l  T:v  Tree{T}:r}\n}\nTree{u8}:t -> {l -> {}  v -> 5  r -> {l -> {}  v -> 6  r -> {}}}", "", {}},
	{"Tree -> {\n  T -> {}\n  -> {}\n  -> {Tree{T}:l  T:v  Tree{T}:r}\n}\nTree{u8}:t -> {l -> {}  v -> 5  r -> {l -> {}  v -> 300  r -> {}}}", "", {.Constraint_Mismatch}},
	{"Balanced -> {\n  -> {}\n  -> {u8: ...Balanced:  string:}\n}\nBalanced:b -> {1 2 \"a\" \"b\"}", "", {}},
	{"Balanced -> {\n  -> {}\n  -> {u8: ...Balanced:  string:}\n}\nBalanced:b -> {1 \"a\" 2}", "", {.Constraint_Mismatch}},
	// le cas de base vient en premier, n'est pas récursif, et finit
	{"Endless -> {\n  T -> {}\n  -> {T: ...Endless{T}:}\n}", "", {.Infinite_Recursion}},
	{"Unguarded -> {\n  -> {...Unguarded:}\n  -> {}\n}", "", {.Infinite_Recursion}},
	// un pattern sur une inconnue donne un type par cas ; le contexte de chaque
	// branche décide (specs/equational.md §3)
	{"v -> ??::u8\nc -> v + 3\nu8:l -> v ? {<10 -> c, -> 10}", "{v -> ??0  c -> ??0 + 3  0..255:l -> ??0 ? {0..9 -> ??0 + 3  10..255 -> 10}}", {}},
	{"v -> ??::u8\nc -> v + 3\nu8:l -> c", "", {.Constraint_Mismatch}},
	{"v -> ??::u8\nr -> v ? {<10 -> v ? {<10 -> 1}, -> 2}", "{v -> ??0  r -> ??0 ? {0..9 -> 1  10..255 -> 2}}", {}},
	{"v -> ??::u8\nu8:t -> (v ? {<50 -> v, -> 0}) + 200", "", {}},
	{"v -> ??::u8\nu8:t -> (v ? {<60 -> v, -> 0}) + 200", "", {.Constraint_Mismatch}},
	{"v -> ??::u8\ntrue:w -> v ? {<10 -> v < 20, -> true}", "", {}},
	{"v -> ??::u8\ntrue:w -> v ? {<30 -> v < 20, -> true}", "", {.Constraint_Mismatch}},
	// le cast `\` force une valeur dans un layout ; il lie moins fort que
	// l'arithmétique : `a + b \ u8` est `(a + b) \ u8`
	{"a -> 200\nb -> 100\nc -> a + b \\ u8\nd -> -1 \\ u8\ne -> 200 \\ i8\nf -> 'A' \\ u8\ng -> true \\ u8", "{a -> 200  b -> 100  c -> 44  d -> 255  e -> -56  f -> 65  g -> 1}", {}},
	{"n -> ??::u8\nu8:c -> n + 1 \\ u8", "{n -> ??0  0..255:c -> ??0 + 1 \\ 0..255}", {}},
	{"n -> ??::u8\nu16:c -> n + 1 \\ u16", "{n -> ??0  0..65535:c -> ??0 + 1}", {}}, // il y tient déjà
	{"a -> 5 \\ int", "", {.Invalid_Cast}},
	{"a -> 5 \\ 10..37", "", {.Invalid_Cast}},
	{"a -> 5::u8", "", {.Invalid_Cast}}, // `::` n'écrit que le type d'une inconnue
	// la division : tronquée vers zéro, le reste du signe du dividende ; un diviseur
	// qui peut valoir 0, dans le contexte, est une erreur
	{"a -> 10 / 3\nb -> 10 % 3\nc -> -7 / 2\nd -> -7 % 2\nx -> 1.0 / 4.0", "{a -> 3  b -> 1  c -> -3  d -> -1  x -> 0.25}", {}},
	{"n -> ??::u8\ne -> n / 2\nf -> n % 256\nu8:g -> n / 1", "{n -> ??0  e -> ??0 / 2  f -> ??0  0..255:g -> ??0}", {}},
	{"n -> ??::u8\nh -> 10 / n", "", {.Invalid_operator}},
	{"n -> ??::u8\ni -> n ? {0 -> 0, -> 100 / n}", "", {}},
	{"n -> ??::u8\nu8:q -> n / 2 + 128", "", {}}, // 0..127 + 128
	{"n -> ??::u8\nu8:q -> n / 2 + 129", "", {.Constraint_Mismatch}},
	// un scope ne voit son propre nom que dans ses productions
	{"ones -> {1 ...ones}", "", {.Undefined_Identifier}},
	{"X -> {\n  X:child\n  -> {}\n}", "", {.Undefined_Identifier}},
	{"square -> {\n  n -> 0\n  -> n * n\n}\nr -> square{n -> 5}!", "{square -> {n -> 0  -> 0}  r -> 25}", {}},
	{"a -> {\n  x -> 1\n  b -> {-> x}\n}\nc -> a{x -> 2}.b!\nd -> a.b!", "{a -> {x -> 1  b -> {-> 1}}  c -> 2  d -> 1}", {}}, // les scopes écrits dedans suivent la copie
	{"a -> {u8:d}\nb -> a{d -> ??}", "{a -> {0..255:d -> 0}  b -> {0..255:d -> ??0}}", {}}, // l'argument prend la couleur du binding qu'il remplace
	{"Box -> {\n  T -> u8\n  T:v -> 0\n}\nn -> ??::u8\nb -> Box{T -> u16  v -> n * 300}", "", {.Constraint_Mismatch}}, // la couleur est re-typée : 300·n ∉ u16
	{"User -> {u8:age}\nUser{raole -> 1}", "", {.Invalid_Carve}}, // un scope est clos
	{"a -> {x -> 1}\na{x -> 2  x -> 3}", "", {.Invalid_Carve}},
	{"x -> 5\nx{1}", "", {.Invalid_Carve}},
	{"{string:}:a -> {\"\"}\nb -> a{\"x\"}\nb{0}", "", {.Constraint_Mismatch}}, // la coloration implicite suit les copies
	{"Box -> {u8:n}\nPt -> {Box -> {u16:n}}\np -> Pt{Box{300}}", "", {}}, // z{…} : le champ z l'emporte sur le z visible
	{"a -> {x -> 1}\nb -> a{zz{1}}", "", {.Undefined_Identifier}}, // ni champ ni nom visible
	{"a -> .z", "", {.Invalid_Property_Access}}, // `.x` sans source hors des arguments d'un carve
	// les trous : `<-` les remplit, les positions les sautent, le carve infère les autres
	{"id -> {\n  T <- none\n  T:v -> none\n  -> v\n}\nr -> id{v -> 5}!", "{id -> {T <- none  none:v -> none  -> none}  r -> 5}", {}},
	{"id -> {\n  T <- none\n  T:v -> none\n  -> v\n}\nr -> id{T <- u8 v -> 5}!", "", {}}, // requis u8, 5 y est
	{"id -> {\n  T <- none\n  T:v -> none\n  -> v\n}\nr -> id{T <- 4 v -> 5}!", "", {.Constraint_Mismatch}},
	{"id -> {\n  T <- none\n  T:v -> none\n}\nr -> id{T -> u8}", "", {.Invalid_Carve}}, // un trou se remplit par <-
	{"id -> {\n  T <- none\n  T:v -> none\n}\nr -> id{v <- 5}", "", {.Invalid_Carve}}, // un champ se remplit par ->
	{"a -> {\n  u8:e <- 2\n  -> e\n}\nr -> a{e <- 300}!", "", {.Constraint_Mismatch}}, // la couleur du trou s'applique
	{"a -> {\n  e <- 2\n  -> e\n}\nr -> a{<- 3}", "", {.Invalid_Binding_Name}}, // un trou porte un nom
	{"B -> {\n  T <- u8\n  T:v\n  {T:w}:s -> {w -> 0}\n}\nr -> B{s -> {u8:w -> 1}}", "", {}}, // la couleur d'un champ reçue : un type requis
	{"B -> {\n  T <- u8\n  T:v\n  {T:w}:s -> {w -> 0}\n}\nr -> B{v -> 300  s -> {u8:w -> 1}}", "", {.Constraint_Mismatch}}, // 300 ∉ u8, requis par s
	{"B -> {\n  T <- u8\n  {T:w}:s -> {w -> 0}\n  {T:w}:t -> {w -> 0}\n}\nr -> B{s -> {u8:w -> 1}  t -> {u16:w -> 1}}", "", {.Constraint_Mismatch}}, // deux types requis différents
	{"a -> {\n  e <- 2\n  u8:x -> e + 1\n}\nr -> a{x -> 6}", "", {.Unsupported}}, // un trou écrit dans une opération
	// le pattern : la valeur est couverte, une inconnue est restreinte dans chaque branche
	{"a -> ??::u8\nu8:r -> a ? {<255 -> a + 1  -> 0}", "", {}},
	{"a -> ??::u8\nu8:r -> a ? {>0 -> a + 1  -> 0}", "", {.Constraint_Mismatch}},
	{"u8:x -> 5\nr -> x ? {=5 -> 1}", "{0..255:x -> 5  r -> 1}", {}}, // la valeur 5, pas la couleur u8
	{"u8:x -> ??\nr -> x ? {=5 -> 1}", "", {.Non_Exhaustive_Pattern}},
	{"r -> 5 ? {=7 -> 300  -> 0}\nu8:z -> r", "", {}}, // une branche qui ne se déclenche pas n'est pas typée
	{"a -> ??::u8\nr -> a ? {\n  -> 0\n  =5 -> 300\n}\nu8:z -> r", "", {}}, // la branche par défaut prend tout
	{"Circle -> {u8:radius}\nSquare -> {u8:side}\nr -> Circle{radius -> 7} ? {Square: -> 2  Circle: -> 1}", "{Circle -> {0..255:radius -> 0}  Square -> {0..255:side -> 0}  r -> 1}", {}},
	{"r -> 3 ? {u8: -> 1  -> 2}", "{r -> 2}", {}}, // u8: est le défaut de u8 : 0
	{"Circle -> {u8:radius}\nr -> Circle ? {Circle: -> radius}", "", {.Unsupported}}, // la déstructuration
	// l'expansion : `...E` dépose les bindings de la valeur de E, tels quels
	{"xs -> {2 3}\nys -> {1 ...xs 4}", "{xs -> {2  3}  ys -> {1  2  3  4}}", {}},
	{"p -> {...{-> 5}}\nq -> p!", "{p -> {-> 5}  q -> 5}", {}}, // une production déposée
	{"a -> {x -> 1}\nb -> {x -> 0  ...a}\nl -> b.x\nf -> b.x#0", "{a -> {x -> 1}  b -> {x -> 0  x -> 1}  l -> 1  f -> 0}", {}}, // une seconde occurrence
	{"b -> {...5}", "", {.Invalid_Expansion}},
	{"a -> {u8:x -> 1\n  u8:y -> x + 1}\nb -> {...a  z -> 9}\nd -> b{x -> 5}.y", "", {}}, // le carve passe dans l'expansion
	{"a -> {u8:x -> 1\n  u8:y -> x + 200}\nb -> {...a  z -> 9}\nc -> b{x -> 100}", "", {.Constraint_Mismatch}},
	{"xs -> {2 3}\nys -> {1 ...xs}\nzs -> ys{9 8 7}", "{xs -> {2  3}  ys -> {1  2  3}  zs -> {9  8  7}}", {}}, // des positions à travers l'expansion
	{"{u8: u8: u8:}:ys -> {1 ...{2 300}}", "", {.Constraint_Mismatch}},
	{"a -> {x -> 1}\nb -> {...a}\nc -> b{x -> 2 x -> 3}", "", {.Invalid_Carve}},
	// une expansion colorée est une suite : tout scope que sa couleur admet
	{"{... u8:b}:a -> {1 \"x\" {} b -> 5}", "", {}},
	{"{... u8:b}:a -> {b -> 300}", "", {.Constraint_Mismatch}},
	{"{... u8:b}:a -> {1 2}", "", {.Constraint_Mismatch}}, // pas de b à la fin
	{"{u8:x ...}:a -> {x -> 3  y -> \"z\"  4}", "", {}},
	{"Pair -> {u8: u8:}\n{...Pair: string:}:a -> {1 2 \"x\"}", "", {}},
	{"Pair -> {u8: u8:}\n{...Pair: string:}:z -> {1 \"x\"}", "", {.Constraint_Mismatch}},
	{"q -> {...u8:}", "", {.Invalid_Expansion}}, // le défaut de u8 n'est pas un scope
	{"y -> x", "", {.Undefined_Identifier}},
	{"a -> {x -> 1}\nb -> a.z", "", {.Invalid_Property_Access}},
}

@(test)
test_cases :: proc(t: ^testing.T) {
	for c in CASES {
		arena: vmem.Arena
		context.allocator = vmem.arena_allocator(&arena)
		program, k, parsed := run(c.source)
		testing.expectf(t, parsed, "parse : %q", c.source)
		if parsed {
			got := error_kinds(k.errors[:])
			testing.expectf(t, slice.equal(got, sorted_kinds(c.errors)), "%q\n  erreurs : %v, attendu %v\n  %s", c.source, got, c.errors, describe_errors(k.errors[:]))
			if c.typed != "" {
				printed := print_type(new_expr(program))
				testing.expectf(t, printed == c.typed, "%q\n  typé    : %s\n  attendu : %s", c.source, printed, c.typed)
			}
		}
		vmem.arena_destroy(&arena)
	}
}

// Une erreur d'une copie est signalée au carve qui l'a causée (`carve ← source`),
// une seule fois ; ce que le carve ne change pas est signalé dans la source.
Site_Case :: struct {
	source: string,
	sites:  []string,
}

SITE_CASES := []Site_Case {
	{"Box -> {\n  u8:x -> 1\n  u8:y -> x + 200\n}\nb -> Box{x -> 100}\nc -> Box{x -> 100}", {"5:9 ← 3:3", "6:9 ← 3:3"}},
	{"Box -> {\n  u8:x -> 1\n  u8:y -> 300\n}\nb -> Box{x -> 2}", {"3:3"}},
	{"Box -> {\n  T -> u8\n  T:v -> 0\n}\nn -> ??::u8\nb -> Box{v -> n * 2}", {"6:10 ← 3:3"}}, // la valeur carvée : à l'argument
	{"Inner -> {\n  u8:a -> 0\n}\nBox -> {\n  x -> 1\n  w -> Inner{a -> x}\n}\nb -> Box{x -> 300}", {"8:9 ← 2:3"}},
	{"Pair -> {\n  u8:a\n  u8:b\n}\np -> Pair{7}\nq -> p{b -> 300}\nr -> q{a -> 1}", {"6:8 ← 3:3"}},
	{"P8 -> {\n  u8:x\n}\nP16 -> {\n  u16:x\n}\nWrap -> {\n  S -> P16\n  S:p -> {x -> 300}\n}\nw -> Wrap{S -> P8}", {"11:10 ← 9:11"}}, // la couleur implicite
	{"Box -> {\n  n -> ??::u8\n  u8:y -> n * 2\n  x -> 1\n}\nb -> Box{x -> 5}", {"3:3"}},
	{"f -> {\n  u8:x -> 5\n  -> x ? {=5 -> 1}\n}\ng -> f{x -> 6}!", {"5:7 ← 3:6"}},
	{"{u8: u8: u8:}:ys -> {1 ...{2 300}}", {"1:30"}}, // un littéral expansé reçoit la forme à sa place
	{"xs -> {2 300}\n{u8: u8: u8:}:ys -> {1 ...xs}", {"2:1 ← 1:10"}}, // une valeur reçue d'ailleurs : au binding, écrit là où est le 300
	{"p -> {x -> 1  y -> {z -> 300}}\n{u8:x  {u8:z}:y}:q -> p", {"2:1 ← 1:21"}}, // au plus profond // un carve qui rend le pattern non exhaustif
}

@(test)
test_carve_error_sites :: proc(t: ^testing.T) {
	for c in SITE_CASES {
		arena: vmem.Arena
		context.allocator = vmem.arena_allocator(&arena)
		_, k, parsed := run(c.source)
		testing.expectf(t, parsed, "parse : %q", c.source)
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
		testing.expectf(t, slice.equal(got[:], c.sites), "%q\n  erreurs à %v, attendu %v\n  %s", c.source, got[:], c.sites, describe_errors(k.errors[:]))
		vmem.arena_destroy(&arena)
	}
}

// Un binding porte sa couleur et sa valeur telles qu'écrites, et leurs types : le
// type simplifie, la valeur garde toute la structure qui l'a produit.
@(test)
test_value_and_type :: proc(t: ^testing.T) {
	arena: vmem.Arena
	context.allocator = vmem.arena_allocator(&arena)
	defer vmem.arena_destroy(&arena)
	program, k, parsed := run("n -> ??::u8\nu16:x -> n * 2 - n + (1 + 2)\nb -> {-> n}\ny -> b!\nsq -> {\n  m -> 0\n  -> m * m\n}\nz -> sq{m -> n}!")
	testing.expect(t, parsed && len(k.errors) == 0, "le programme est valide")
	testing.expect_value(t, print_expr(new_expr(program)), "{n -> ??::u8  u16:x -> n * 2 - n + (1 + 2)  b -> {-> n}  y -> b!  sq -> {m -> 0  -> m * m}  z -> sq{m -> n}!}")
	testing.expect_value(t, print_type(new_expr(program)), "{n -> ??0  0..65535:x -> ??0 + 3  b -> {-> ??0}  y -> ??0  sq -> {m -> 0  -> 0}  z -> ??0*??0}")
}

// Le corpus de test/typecheck : chaque source dont toutes les formes sont dans le
// kernel doit donner exactement les erreurs attendues. Les sources qui touchent
// une forme pas encore implémentée sont comptées à part.
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

// Une équation résolue par Arden : la couleur du binding `x`, imprimée comme
// ensemble (specs/kernel-recursion.md §5).
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
		set, closed := color_set(&k, b.color_type)
		testing.expect(t, closed)
		testing.expect_value(t, print_set(set), c[1])
		testing.expect_value(t, len(k.errors), 0)
	}
}
