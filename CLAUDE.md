# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Projet

Compilateur bootstrap (écrit en Odin) pour un langage homoïconique expérimental avec des concepts non-conventionnels : **pointings** (`->`/`<-`), **events** (`>-`/`-<`), **resonances** (`>>-`/`-<<`), **patterns**, **constraints**, et **overrides**. Les fichiers source utilisent l'extension `.syn`. Le compilateur final sera auto-hébergé ; ce codebase Odin est l'implémentation de bootstrap.

## Build et exécution

Le projet utilise Odin directement (pas de Makefile, pas de script de build). Chaque composant se compile indépendamment en pointant `odin` sur son répertoire-package.

```bash
# Compilateur
cd compiler && odin build . -out:compiler
./compiler <fichier.syn> [options]

# LSP
cd lsp && odin build . -out:lsp

# Tests (voir section Tests ci-dessous)
cd test && odin build . -out:test -file generator.odin && ./test  # régénère parser_generated_tests.odin
cd test && odin test .
```

Binaires committés à la racine de chaque répertoire (`compiler/compiler`, `lsp/lsp`, `test/test`) — ne pas confondre avec les sources `.odin`.

### Options CLI du compilateur

`--ast`, `--symbols`, `--scopes` (dumps de debug), `--parse-only`, `--analyze-only`, `-v`/`--verbose`, `-t`/`--timing`. Le cache disque est désactivé dans le bootstrap (`options.no_cache = true` forcé dans `parse_args`) — il sera implémenté dans la version self-hosted.

## Architecture

### Pipeline de compilation (package `compiler`)

```
main.odin → resolver.odin → parser.odin → analyzer.odin → generate.odin → backends/x64
```

1. **`main.odin`** : parsing des arguments CLI dans `Options`, puis délègue à `resolve_entry()`.
2. **`resolver.odin`** : orchestrateur multi-thread. `Resolver` global contient un `map[string]^Cache` (un `Cache` par fichier source, avec son propre `vmem.Arena`) et un `thread.Pool`. Compile les fichiers en parallèle via `process_cache_task`. La machine d'état `Status` (`Fresh → Parsing → Parsed → Analyzing → Analyzed`) et les mutex par `Cache` protègent la compilation concurrente.
3. **`parser.odin`** (~3.5k lignes) : lexer + parser Pratt. Produit un AST dont les nœuds sont une `union` Odin (voir `Node` ligne 729 et ses variantes : `Pointing`, `PointingPull`, `EventPush`, `EventPull`, `ResonancePush`, `ResonancePull`, `ScopeNode`, `Override`, `Product`, `Branch`, `Identifier`, `Pattern`, `Constraint`, `Operator`, `Execute`, `Literal`, `Property`, `Expand`, `External`, `Range`, `Enforce`, `Unknown`). Chaque nœud embarque un `NodeBase` avec la `Position` source.
4. **`analyzer.odin`** : résolution sémantique. Transforme l'AST en `ScopeData` contenant des `^Binding` (nom, `Binding_Kind`, contrainte, `symbolic_value` et `static_value` de type `ValueData`). `ValueData` est une union couvrant scopes, littéraux, propriétés, ranges, effets réactifs (`ReactiveData`, `EffectData`), binaires/unaires, overrides, refs.
5. **`generate.odin`** : génération de code. La majeure partie est commentée — le backend actif est en cours de reconstruction au-dessus de `./backends/x64`.
6. **`builtins.odin`** : initialise les bindings built-in (`u8`, `i8`, `u16`, `i16`, `u32`, `i32`, `u64`, `i64`, `f32`, `f64`, `char`, `bool`, `String`) dans un `ScopeData` global `builtin`. Attention : `String` est majuscule (pas `string`), et `usize`/`isize`/`none` mentionnés dans le README ne sont pas encore implémentés.

### Backends (`compiler/backends/`)

Seul `x64/` a du code Odin actif (package `x64_assembler`) : `x64_header.odin`, `x64_instructions.odin`, `x64_utility.odin`, `x64_test.odin`. `arm64/arm64` et `wasm/wasm` sont des fichiers source Odin avec un nom sans extension (packages `arm64_assembler` et `wasm_assembler`), pas encore intégrés au build du compilateur. Un `x64.odin.bak` dans `x64/` indique un refactor en cours.

### LSP (`lsp/`, package `lsp`)

Serveur LSP autonome qui importe `../compiler` et réutilise le `Cache` du compilateur pour fournir l'AST par document. Implémentation JSON-RPC manuelle sur stdin/stdout (`LSP_Message`, `LSP_Notification`, `LSP_Response`).

### Tests (`test/`, package `compiler_test`)

Système de tests **généré** — ne pas éditer `parser_generated_tests.odin` à la main :

- `test/tests/*.json` : cas de test déclaratifs (`{name, description, source, expect}` où `expect` est la représentation string attendue de l'AST — voir `ast_to_string` dans `test/parser.odin`).
- `test/generator.odin` (son `main`) : scanne `tests/*.json` et (ré)écrit `parser_generated_tests.odin` avec une fonction `@(test)` par JSON.
- `test/parser.odin` : harnais (`run_test`, `ast_to_string`, `build_position_map`, `show_source_context`) qui parse `source`, sérialise l'AST et compare à `expect`. En cas de diff, pointe la position source du premier nœud divergent.
- `test/drafts/*.syn` : fragments de langage expérimentaux pour design — **ce ne sont pas des tests automatisés**, juste du scratch manuel.

Flux pour ajouter un test : créer un `tests/foo.json`, rerunner `generator.odin` pour régénérer `parser_generated_tests.odin`, puis `odin test .`.

## Conventions spécifiques

- **Arenas par fichier** : chaque `Cache` possède son propre `vmem.Arena`. L'allocation de l'AST/ScopeData doit passer par l'allocator du cache, pas le contexte global.
- **Commentaires bannière** : le codebase utilise des bannières `/* ==== SECTION ==== */` pour délimiter les grandes zones logiques de fichiers monolithiques (notamment dans `parser.odin`). Respecter ce style quand on étend ces fichiers.
- **Tokens sensibles aux espaces** : le lexer distingue `PropertyAccess` (`a.b`) / `PropertyFromNone` (`.b`) / `PropertyToNone` (`a.`) selon le contexte de délimiteur, idem pour `ConstraintBind`/`ConstraintFromNone`/`ConstraintToNone` sur `:`, et `LeftBraceOverride` vs `LeftBrace`. Ne pas traiter espaces et ponctuation comme orthogonaux.
- **`ast_to_string` ↔ `expect`** : le format exact produit par `test/parser.odin:ast_to_string` est la source de vérité pour écrire les `expect` des JSON. Ajouter un nouveau variant de `Node` implique d'étendre à la fois `ast_to_string` ET `walk_all_nodes` dans `test/parser.odin`.
