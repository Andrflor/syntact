# Multi-cible, exports et hot reload — audit vérifié et plan

> Audit daté du **2026-07-29**, sur `master` (`d47fb74`). **Aucune modification du compilateur.**
>
> Convention de preuve, identique à `vulkan-slice.md` :
> **[VÉRIFIÉ]** = reproduit sur le compilateur construit par `odin build compiler` ;
> **[LECTURE]** = démontré par le code cité, sans exécution ;
> **[SPEC]** = énoncé d'un document de design, **pas** une preuve d'implémentation.
>
> `targets.md`, `abi.md`, `sdk.md`, `interop.md`, `effects.md` sont traités comme des
> **intentions**. Ce document dit lesquelles tiennent, lesquelles sont fausses sur le code
> actuel, et lesquelles sont contredites par l'architecture visée.
>
> **Recouvrement avec `vulkan-slice.md`** (audit parallèle du même jour) : ce document ne
> réénonce pas la frontière `<lib>` scalaire. Ses défauts D1–D10 et son plan J1–J13 sont
> **adoptés comme prérequis** et cités, jamais réécrits. Le présent document couvre ce que
> `vulkan-slice.md` ne couvre pas : la factorisation des cibles, `Code_Object`, arm64, QEMU,
> `@platform`, les exports, le hot reload et le SDK.

---

## Sommaire des conclusions

Six conclusions structurent tout le reste.

1. **`BC_Program` est neutre vis-à-vis de la cible, mais il n'a pas de notion de fonction.**
   `BC_Inst` (`bytecode/bytecode.odin:232-247`) a 15 variantes, aucun appel, aucune mémoire ;
   `lower_to_bytecode` (`bytecode.odin:145-161`) produit **un** DAG et **un** `BC_Ret`.
   Or `Code_Object.syms` (`targets.md` §3), les exports (§10 de la demande), les callbacks
   (`abi.md` §7), la granularité de reload (`targets.md` §10) et le mode mixte (§14) exigent
   tous des **unités nommées et adressables**. C'est un seul manque, et c'est le jalon pivot.

2. **L'interpréteur ne peut pas exécuter d'appel externe** (`bytecode/interp.odin:56-68`).
   Donc : l'oracle sémantique ne couvre pas les programmes `<lib>` ; et le profil debug —
   qui *est* l'interpréteur (`targets.md` §6.3) — ne peut pas exécuter le seul type de
   programme pour lequel le hot reload est conçu (GUI, Vulkan). Fermer ce trou sert les deux
   à la fois.

3. **Un pattern dont les branches produisent des scopes ne donne accès à aucune propriété.**
   **[VÉRIFIÉ]** `s -> tag ? { 1 -> {a->7}, -> {a->9} }` puis `s.a` ⇒
   `property 'a' does not exist`. Cause exacte : `resolve_property_site`
   (`analyze.odin:1189-1216`) traite `Scope_Type`, `Carve_Type`, `Execute_Type` — **pas
   `Pattern_Type`**. C'est précisément la forme sur laquelle repose tout le nommage portable
   de bibliothèque (`abi.md` §4, `sdk.md` §3.1). Le mécanisme central du design multi-cible
   ne fonctionne pas, et l'obstacle est dans l'analyseur, pas dans le backend.

4. **La proposition d'exports de la demande §10 est déjà exprimable et résolvable.**
   **[VÉRIFIÉ]** `s -> { add }` puis `s.add` résout ; `exports.add{a->2,b->3}!` rend `5`.
   Le nom d'une mention nue est conservé comme propriété. Seule la formulation est à corriger
   (« production du file-scope », pas « première production ») et le critère
   fonction-vs-constante est une décision à prendre.

5. **Une seule mécanique — table d'indirection `identité → corps` + trampolines** — résout
   quatre problèmes que les specs traitent séparément : hot reload, callbacks entrants,
   symboles exportés, et frontière AOT/interprété du mode mixte. Elle est la raison pour
   laquelle le jalon « fonctions dans le bytecode » doit venir tôt.

6. **Le hot reload *du code* peut arriver avant la préservation d'état**, parce qu'il n'existe
   aujourd'hui **aucun état mutable** : `ir.odin:38-43` — « only the pointing pair is reduced
   today (events/resonance/reactivity are recorded, not yet reduced) ». La règle d'état (§12
   de la demande) est bloquée par l'implémentation de la résonance, pas par le backend.

---

# 1. État vérifié de l'implémentation

## 1.1 Ce qui est réellement implémenté et testé

| Capacité | Preuve |
|---|---|
| `BC_Program` neutre : `bytecode/` n'importe rien de `compiler/` | `bytecode/bytecode.odin:1-18`, aucun `import ".."` hors `core:` — **invariant 1 de `targets.md` §7 : tenu** |
| Interpréteur bytecode comme oracle | `bytecode/interp.odin:30-123` |
| Harnais différentiel interp ↔ x64 natif, par cas déclaratif | `test/codegen/codegen.odin:182-240` |
| ELF64 `ET_EXEC` statique écrit entièrement par le compilateur | `backends/x64/elf.odin:84-237` |
| ELF dynamique (`.interp/.dynstr/.dynsym/.hash/.rela/.dynamic`), GOT sans PLT | `backends/x64/elf_dynamic.odin` |
| Programme sans `<lib>` ⇒ statique, un seul `PT_LOAD` | `elf.odin:86-88` |
| Allocation de registres linear-scan, spill, coalescing biaisé par les moves | `backends/x64/regalloc.odin:63-207` |
| Sélection d'adressage (`lea`), réduction de force | `backends/x64/isel.odin`, `emit.odin:780+` |
| Suite d'encodage x64 validée contre objdump | `backends/x64/x64_test.odin` (8 007 lignes) |
| Réduction d'un pattern à scrutateur littéral, branches non retenues éliminées | **[VÉRIFIÉ]** `tag -> 1` / `tag ? {1 -> 10, 2 -> 20, -> 30}` ⇒ `v0 = const 10` |
| Frontière `<lib>` scalaire 0–6 args | `vulkan-slice.md` §1.1 |
| LSP : diagnostics, hover, définition, rename, complétion, tokens sémantiques | `lsp/lsp.odin`, `lsp/semantic.odin` |

## 1.2 Ce qui est spécifié et **absent**

| Capacité | Document | Preuve d'absence |
|---|---|---|
| Notion de cible (`Target`) | `targets.md` §6.1 | `Options` (`main.odin:11-28`) n'a ni target, ni artifact, ni profile ; `resolve.odin:469` appelle `x64.emit_executable` directement |
| `Artifact`, `Profile` | `targets.md` §6.2/§6.3 | idem |
| `Code_Object`, `Reloc`, `Sym` | `targets.md` §3 | aucun type de ce nom dans `compiler/` |
| Codegen relogeable, PIE | `targets.md` §8.2 | `elf.odin:134` `e_type = 2` (ET_EXEC) ; adresses absolues §1.3 ci-dessous |
| Backend arm64 | `targets.md` §5 | voir §1.4 |
| Writers Mach-O, PE/COFF | `targets.md` §8.3/§8.4 | absents |
| Records `Platform` / `Abi` | `targets.md` §4, `abi.md` §2.3 | `emit_exit` code `rax=60` en dur (`emit.odin:493`) ; `SYSV_INT_ARGS`/`SYSV_SSE_ARGS` en dur (`emit.odin:700-701`) |
| `@platform` | `sdk.md` §3.1 | **[VÉRIFIÉ]** `@platform.os` ⇒ `property 'os' does not exist`. `@name` va directement à la résolution de fichiers (`parse.odin:2490-2530`, `process_filenode_flat`) |
| Cache de réduction adressé par contenu, par binding | `targets.md` §10 | voir §1.5 |
| VM résidente, socket, patch | `targets.md` §10 | `interp_bytecode` est one-shot (`interp.odin:30`) |
| Exports, `.so`/`.a`/`.o` | `targets.md` §6.2 | `elf_dynamic.odin` n'écrit que des `SHN_UNDEF` |
| Callbacks (C → Syntact) | `abi.md` §7 | pas de modèle d'appel |
| Signature Mach-O ad-hoc, APK v2 | `targets.md` §9 | absents |
| Sous-commandes SDK, `devices`, `doctor`, `format` | `sdk.md` | `main.odin` = un parseur de drapeaux |
| DWARF, mapping source | `targets.md` §5 | absent |
| Boucles, arêtes arrière produites en amont | `vulkan-slice.md` §1.4 | `BC_Jump` les supporte, rien ne les produit |
| Effets / résonance réduits | `ir.odin:38-43` | « recorded, not yet reduced » |
| Section de données inscriptible | `elf.odin:110` | `memsz` ne couvre que `ARGS_TABLE` + GOT |

## 1.3 Adresses absolues : **trois** classes, pas deux

`targets.md` §8.2 affirme : *« There are exactly two absolute references in the emitted code
today — `ARGS_TABLE_VADDR` and `GOT_VADDR` »*. **C'est faux.** Il y en a trois classes sur
cinq sites. **[LECTURE]**

| Classe | Sites | Forme émise |
|---|---|---|
| Table d'arguments `??` | `emit.odin:177`, `emit.odin:205`, `emit.odin:632` | `movabs r11/rbx, ARGS_TABLE_VADDR` |
| **Adresse `.rodata`** | `emit.odin:112` (`rodata_vaddr = ELF_BASE + headers`), consommée en `emit.odin:664-666` | `movabs rax, <addr>` — **omis par `targets.md`** |
| Slot GOT | `emit.odin:759` | `movabs r10, GOT_VADDR + 8*slot` |

Plus, côté writer, les constantes que ces sites lisent : `ELF_BASE` (`elf.odin:40`),
`ARGS_TABLE_VADDR` (`elf.odin:60`), `GOT_BASE_VADDR`/`GOT_VADDR` (`elf.odin:76-77`), et le
calcul `memsz = (GOT_VADDR - ELF_BASE) + 8*GOT_MAX` (`elf.odin:110`) qui **fusionne
délibérément** la table d'arguments et le GOT dans un unique `PT_LOAD` **RWX**
(`elf.odin:149-150`, `p_flags = 7`) pour éviter une seconde contrainte d'alignement
(commentaire `elf.odin:68-70`).

L'invariant 4 de `targets.md` §7 (« aucune adresse virtuelle absolue dans `isa/*` ») est donc
violé en trois endroits, et le `PT_LOAD` RWX unique est **incompatible avec Android**
(SELinux, `targets.md` §8.5) — deux dettes qui se paient au même endroit.

## 1.4 Les « squelettes » arm64 et wasm ne sont pas compilés

`targets.md` §8.2 dit : *« The skeleton at `compiler/backends/arm64/arm64` already stubs
`adrp_x64` / `adr_x64`, so this was anticipated. »* **[LECTURE]** — à corriger :

- `compiler/backends/arm64/arm64` et `compiler/backends/wasm/wasm` n'ont **pas d'extension
  `.odin`** : Odin ne les compile pas. Ce sont des fichiers texte inertes.
- Les 332 lignes sont des `proc` à corps **vide** (`{}`), et **nommées d'après x64** :
  `adrp_x64`, `lea_x64`, `movabs_x64_imm64`, `mov_x64_imm64` (`arm64:24-38`) — un copier-coller
  de la table x64 avec des mnémoniques arm64 collées dessus. `lea` et `movabs` n'existent pas
  en AArch64.
- `Register64` y inclut `SP` à l'index 31 (`arm64:4-9`), ce qui est faux au niveau encodage :
  le registre 31 est `XZR` **ou** `SP` selon l'instruction, distinction qu'un encodeur doit
  porter.

Conclusion : **il n'y a pas de squelette arm64**, il y a une liste de vœux. À traiter comme
une page blanche, avec la nomenclature à refaire.

## 1.5 Le cache : ce qui existe n'est pas ce que `targets.md` §10 décrit

`targets.md` §10 annonce un *« content-addressed reduce cache, binding-level »*. **[LECTURE]** :

| Attendu | Réel |
|---|---|
| adressé par contenu | clé = `hash.fnv64a(cache.path)` — **le chemin**, pas le contenu (`resolve.odin:669-670`) |
| granularité binding | granularité **fichier** : `Cache` porte un `^Scope_Type` entier (`resolve.odin:35-46`) |
| cache de la *réduction* | cache de l'*analyse* : `reduce()` est appelé après, sans cache (`resolve.odin:424`) |
| invalidation exacte | `last_modified` (mtime) |
| actif | **désactivé en dur** : `options.no_cache = true` (`main.odin:32-33`), drapeaux commentés (`main.odin:71-74`) |

Et le seul mécanisme structurel présent, `dag_key` (`reduce.odin:1035-1067`), **n'est pas un
hash de contenu** : il retombe sur `fmt.aprintf("@%p", t)` — **l'adresse du nœud** — pour tout
ce qui n'est pas Integer/Float/String/Bool/None/Compose/Cast/Unknown/Mention/Reference. Donc
`Scope_Type`, `Pattern_Type`, `Foreign_Call_Type`, `Execute_Type`, `Carve_Type` sont clés par
identité de pointeur. De plus `Reducer` (avec `dag_table` et `fixedpoint_index`) est **recréé à
chaque `reduce()`** (`reduce.odin:985-1010` + commentaire), donc aucune mémoïsation ne traverse
deux compilations.

`dag_key` est une clé de CSE intra-passe, avec canonicalisation commutative
(`reduce.odin:1050-1052`). **Elle ne doit pas être détournée** en identité de reload : deux
expressions différentes peuvent être volontairement confondues, et l'identité d'un binding ne
doit pas dépendre de la commutativité de son corps.

## 1.6 Découvertes propres à cet audit

### F1 — Un pattern à branches-scopes n'expose aucune propriété **[VÉRIFIÉ]**

```syntact
tag -> 1
s -> tag ? { 1 -> { a -> 7 }, -> { a -> 9 } }
-> s.a
```
⇒ `Invalid_Property_Access: property 'a' does not exist`. Idem avec des scopes nommés
(`s -> tag ? { 1 -> A, -> B }`), idem avec des scopes `<lib>` :

```syntact
lib -> tag ? { 1 -> <libm.so.6>{ sqrt -> {f64:x, -> ??::f64} }, -> <libm.so>{ … } }
-> lib.sqrt{x->16.0}!
```
⇒ `property 'sqrt' does not exist` + `'x' does not exist in the carved scope`.

Cause exacte : `resolve_property_site` (`analyze.odin:1189-1216`) ne traite que `Scope_Type`,
`Carve_Type` et `Execute_Type`. `walk_pattern` (`analyze.odin:1893-1968`) retourne un
`Pattern_Type{target, branches}` (`:1954`) sans joindre les productions de branches.

**Portée.** C'est la forme exacte de `abi.md` §4, `sdk.md` §3.1 et de la demande §6/§7. Le
nommage de bibliothèque par plateforme, la sélection d'implémentation par architecture et le
rejet d'une plateforme sont **tous** bloqués par ce seul trou. Il est dans l'analyseur.

Noter la parenté avec `vulkan-slice.md` D3 (`holds_foreign_collapse` sans cas `Pattern_Type`) :
**`Pattern_Type` n'est pas traité comme un porteur de valeur de première classe**. C'est une
classe de défaut, pas deux accidents.

### F2 — Un `<lib>` utilisé directement comme symbole devient un slot `argv` **[VÉRIFIÉ]**

```syntact
f -> <libm.so.6>{ f64:x, -> ??::f64 }
-> f{x->16.0}!
```
⇒ `v0 = arg 0 ; ret v0` — **le `??::f64` est devenu un point fixe `??0` lu dans `argv`**, la
provenance est perdue, le binaire sort **statiquement lié**. La forme à deux niveaux
(`l -> <libm.so.6>{ sqrt -> { … } }` puis `l.sqrt{…}!`) produit bien `call [got 0]`.

Donc la provenance n'est honorée que si le symbole est un **binding interne** du scope
`<lib>`. La forme dégénérée est du **code silencieusement faux**, pas une erreur — violation
directe de la loi de `effects.md` (« un effet est levé dès qu'un collapse traverse la
frontière »). C'est aussi la forme qu'on écrirait naturellement pour `<asm>` (§8).

### F3 — Registres caller-saved détruits autour d'un appel externe **[VÉRIFIÉ]**

Confirmé indépendamment de `vulkan-slice.md` D1, avec un reproducteur différent :

```syntact
libm -> <libm.so.6>{ sqrt -> {f64:x, -> ??::f64}, pow -> {f64:a, f64:b, -> ??::f64} }
-> libm.sqrt{x->16.0}! + libm.pow{a->2.0, b->3.0}!
```
attendu `12.0`, obtenu **`6755399441056136.000000`**. `--regalloc` donne `v1 -> rsi` ;
le désassemblage donne `mov %rax,%rsi` (0x400116) puis `call *(%r10)` vers `pow` (0x400156)
puis `mov %rsi,%rax` (0x400161). `pow` détruit `rsi`.

Le même programme avec **deux fois `sqrt`** rend `7.0` correctement : `sqrt` préserve `rsi`
par accident. **Le défaut est latent et dépend de la callee.** `regalloc.odin` n'a aucune
notion de clobber (seuls `bc_def`/`bc_uses` connaissent `BC_Foreign_Call`, `:323`/`:339`), et
`ALLOCATABLE_REGS` (`regalloc.odin:51`) distribue `RSI RDI R8 R9 R10 R11` — six registres
caller-saved.

**Et l'oracle ne peut pas le voir** : `interp_bytecode` refuse tout appel externe
(`interp.odin:56-68`). Le harnais différentiel est structurellement aveugle à toute la
frontière `<lib>`. Les deux défauts se renforcent.

### F4 — Le commentaire de `regalloc.odin:41-51` est faux

Il annonce : *« R10 is EXCLUDED too: it's the dedicated scratch holding the ARGS_TABLE base »*
et *« RBX is callee-saved; reserved for later use »*. **[LECTURE]** Or `R10` **figure** dans
`ALLOCATABLE_REGS` (`:51`), `emit_body` charge la base `ARGS_TABLE` dans **`RBX`**
(`emit.odin:632`), et `emit_foreign_call` utilise **`R10`** comme scratch du slot GOT
(`emit.odin:759`) — sur un registre allouable. `abi.md` §7 cite ce commentaire
(« `regalloc.odin:39-45` exclut RBX ») comme un fait ; c'est un commentaire périmé, et le
raisonnement d'`abi.md` §7 sur les fonctions ABI reste néanmoins juste.

### F5 — Le harnais ne compare ni stderr, ni les traps

`run_shell` (`test/codegen/codegen.odin:72-88`) ouvre `popen(cmd, "r")` : **stdout seulement**.
`run_combo` (`:182-240`) compare stdout et le statut de sortie tronqué à 8 bits (`:216-218`,
`((v % 256) + 256) % 256`). Donc :

- **stderr n'est jamais comparé** (la demande §5 l'exige) ;
- un **trap** natif divergeait déjà sans être testé : `x/0` fait `SIGFPE` en natif alors que
  l'interpréteur retourne l'erreur `"division by zero"` (`interp.odin:269`). Aucun cas ne
  couvre ce désaccord ;
- le canal de résultat entier est limité à 8 bits (`emit_exit`, `emit.odin:492-494`).

### F6 — Le rendu d'un scope perd le nom d'une mention nue

**[VÉRIFIÉ]** `-> { add version }` affiche `{{a -> 0, b -> 0, -> 0}, {-> 1}}` — sans les noms.
Mais `s -> { add }` puis `s.add` **résout correctement**. C'est donc un défaut d'affichage
(`value_to_string`), pas de sémantique. Il importe ici parce qu'il rendait la proposition
d'exports de la demande §10 faussement suspecte.

## 1.7 Contradictions spec ↔ spec, et spec ↔ architecture visée

| # | Contradiction | Résolution proposée |
|---|---|---|
| C1 | `targets.md` §6.1 met `pie` et `sign` **dans la table des cibles**. Or la signature dépend de (plateforme × artifact × profile) — un `.o` ne se signe pas — et `pie` dépend de (plateforme × artifact) — un `.so` est ET_DYN par construction. | Ni l'un ni l'autre n'est un champ de `Target`. `Platform` porte la *contrainte* (`pie: Optional\|Required`, `sign_required: bool`), le résolveur combine avec l'artifact. §4 |
| C2 | `sym_prefix` est déclaré **deux fois** : `Platform` (`targets.md` §4) et `Abi` (`abi.md` §2.3). | C'est une propriété du **format d'image** (Mach-O souligne). Une seule définition, dans `image/`, exposée en lecture via `@platform`. §4 |
| C3 | `targets.md` §4 met `entry_exe`/`entry_app`/`entry_lib` + `result_kind` sur `Platform`, en notant qu'ils dépendent de (Artifact × plateforme). Trois champs pour une table à deux entrées. | Une **table** `entry_model(platform, artifact)`, pas trois champs. §4 |
| C4 | Orthographe de l'architecture : `--target linux-arm64` (`targets.md` §6.1) vs `arch aarch64` (`sdk.md` §3.1) vs `arm64` dans la demande. | Une seule orthographe source-visible : **`arm64`**. `aarch64` est réservé aux constantes qui *portent ce nom* (`R_AARCH64_*`, `EM_AARCH64`). §8 |
| C5 | `Transport` (`sdk.md` §7.1) énumère `Local, Adb, Simctl, Ios_Device` — **pas QEMU**, alors que §7.3 le cite comme moyen d'exécution croisée. | QEMU est un transport (`Qemu`), pas un détail de test. §15 |
| C6 | `BC_Foreign_Call.slot` **est** le numéro de slot GOT (`bytecode.odin:325-339` et `:348-352` : *« The index of an entry in BC_Program.imports IS its GOT slot number »*). Le GOT est un concept ELF ; il ne doit pas être décidé dans la taille de guêpe neutre. | L'index reste un **index d'import abstrait** ; c'est la couche image qui assigne GOT/IAT/binding. Renommer, et retirer la promesse d'égalité. §5 |
| C7 | `targets.md` §10 propose `hash(source_text, hashes_of_dependency_reduced_forms)` comme **identité** d'un binding. Un hash de contenu est un **détecteur de changement**, pas une identité : un binding renommé garde son hash, un binding édité change de hash tout en restant le même binding. | Identité = **chemin qualifié du binding** ; hash de contenu = détecteur de changement. Deux notions. §11 |
| C8 | `targets.md` §6.3 fait du profil debug l'interpréteur, et §11 constate que le renderer sera en Syntact. Mais l'interpréteur ne peut pas appeler `<lib>` (`interp.odin:56-68`) : le profil debug ne peut pas exécuter un programme graphique **du tout**. | La VM résidente doit acquérir un FFI. Ce n'est pas une optimisation, c'est une condition d'existence du profil debug. §11, jalon M12 |
| C9 | `targets.md` §10 dit « push the changed bytecode range ». Une plage d'octets n'est pas stable : toute édition décale ce qui suit. | Le patch remplace des **corps entiers** indexés par identité, jamais une plage. §11 |
| C10 | `sdk.md` §3.1 promet `@platform` « une définition, deux vues » avec `Platform` de `targets.md` §4, tout en listant deux jeux de champs différents. | Une seule structure de données, deux projections dérivées mécaniquement, avec un test qui échoue si un champ n'est projeté nulle part. §8 |

---

# 2. Carte des dépendances

## 2.1 Couplages actuels **[LECTURE]**

```
compiler (package compiler)
  ├── import x64 "backends/x64"          resolve.odin:2      ← le compilateur dépend d'une ISA
  │     ├── resolve.odin:455  x64.allocate_registers
  │     └── resolve.odin:469  x64.emit_executable
  └── import bc "bytecode"               resolve.odin:4

backends/x64  (UN SEUL package : x64_assembler)
  ├── isel.odin, emit.odin, x64_instructions.odin, regalloc.odin, vectorize.odin, …
  ├── elf.odin            ← writer ELF DANS le package ISA          elf.odin:1
  └── elf_dynamic.odin    ← tables dynamiques ELF, idem             elf_dynamic.odin:1

bytecode  (package bytecode)   n'importe rien de compiler/          ✔ invariant 1
```

Trois couplages à casser, par ordre de coût croissant :

1. **`compiler` → `x64`** : le pilote de codegen est inline dans `resolve.odin`. Coût : faible,
   c'est un point d'indirection.
2. **ELF dans `x64_assembler`** : `emit_executable` (`elf.odin:7-17`) *est* le pilote
   (`emit_x64` → `build_elf` → `write_entire_file`). Il faut séparer le pilote du writer.
   Coût : moyen, mécanique.
3. **`regalloc` typé x64** : `VReg_Loc.reg: Register64` (`regalloc.odin:31`),
   `ALLOCATABLE_REGS` typé (`:51`), `phys_pref` qui code en dur la convention de sortie
   RDI/RSI (`:86-91`). Coût : moyen ; c'est la seule vraie généralisation.

## 2.2 Structure visée, avec les dépendances autorisées

```
bytecode/                  ← la taille de guêpe. N'importe RIEN.
  bytecode.odin              + BC_Func, BC_Call, Loop_Info      (M5)
  interp.odin                + pile de frames, FFI, session      (M5, M12)

backends/
  target.odin              Target × Artifact × Profile + résolution.   dépend de : rien
  abi/                     records Abi, classify().                    dépend de : target
  platform/                données pures, un fichier par plateforme.   dépend de : target
  isa/
    common/
      codeobj.odin         Code_Object, Reloc, Sym, Export, Line_Map, Binding_Map
      regalloc.odin        linear-scan paramétré par Reg_File          dépend de : bytecode, abi, codeobj
      frame.odin           frame abstrait (slots, tailles, alignement)
    x64/                   isel, encodage, prologue, SIMD, const, veneers
    arm64/                 idem, indépendant
  image/
    elf/  macho/  pe/      dépend de : codeobj, target, platform.  JAMAIS de isa/*
    dwarf/                 partagé elf + macho
  sign/    macho_adhoc/ apk/                    opère sur des octets finis
  package/ raw/ sharedlib/ staticlib/ object/ apk/ appbundle/ multi/

reload/
  identity.odin            chemin qualifié de binding, hash de contenu
  cache.odin               cache de réduction adressé par contenu
  session.odin             VM résidente, table d'indirection, protocole de patch

sdk/  cli/ source/ device/ toolchain/ templates/ session/ format/
```

Règles d'import, vérifiables mécaniquement (un test qui lit les en-têtes de fichiers) :

| De | Peut importer | Ne peut pas |
|---|---|---|
| `bytecode/` | `core:` uniquement | tout le reste |
| `isa/common` | `bytecode`, `abi`, `target` | `image/*`, `platform/*`, `isa/x64`, `isa/arm64` |
| `isa/x64`, `isa/arm64` | `isa/common`, `abi`, `target` | `image/*` |
| `image/*` | `isa/common` (pour `Code_Object`), `target`, `platform` | `isa/x64`, `isa/arm64` |
| `platform/*` | `target` | tout le reste |
| `sign/*`, `package/*` | `target` | `isa/*`, `image/*` |

`image/*` a besoin de l'architecture uniquement comme **constante de lookup**
(`e_machine`, `cputype`) — jamais comme dépendance de code. C'est l'invariant 3 de
`targets.md` §7, et il devient testable.

---

# 3. Factorisation des axes : `Target × Artifact × Profile`

## 3.1 Ce qui appartient à quel niveau

```odin
// backends/target.odin — identité de la cible, rien de plus.
Arch  :: enum { X86_64, Arm64 }
Image :: enum { Elf, Macho, Pe }
Os    :: enum { Linux, Android, Macos, Ios, Ios_Sim, Windows }

Target :: struct {
    arch:     Arch,
    os:       Os,
    abi:      ^Abi,        // record, abi/  — dépend de (arch, os)
    image:    Image,       //               — dépend de os
    platform: ^Platform,   // record, platform/ — indexé par os
    features: Feature_Set, // baseline par arch, élargie à l'invocation
}

// Dérivés, JAMAIS stockés — sinon ils dérivent.
ptr_bits   :: proc(t: Target) -> int  { return 64 }          // les 8 cibles sont LP64/LLP64
endianness :: proc(t: Target) -> Endian { return .Little }   // idem
```

**Champs retirés par rapport à la demande et aux specs, avec la raison :**

| Champ | Verdict |
|---|---|
| `object_format` | **Retiré.** ELF/Mach-O/PE portent chacun *les deux* formes, image liée et objet relogeable. « Objet ou image » est l'axe **Artifact**, pas un champ de Target. |
| `pointer_width`, `endianness` | **Dérivés de `arch`**, pas stockés (C1 bis). Exposés en lecture via `@platform`. |
| `signing` | **Retiré de Target.** Fonction de (platform, artifact, profile) — voir C1. `Platform.sign_required` porte la contrainte. |
| `pie` | **Retiré de Target** (C1). `Platform.pie` porte la contrainte ; un `Shared_Library` est ET_DYN quoi qu'il arrive. |
| `feature_set` | **Conservé**, car il change la sélection d'instructions. Valeur par défaut = baseline de l'arch ; élargissable à l'invocation. |

```odin
// platform/ — données pures. Aucune branche par nom de plateforme ailleurs.
Platform :: struct {
    syscalls:      Maybe(Syscall_Table),  // nil ⇒ obligation de passer par la libc
    libc_name:     string,
    loader:        string,                // "" = statique
    lib_ref:       enum { Soname, Unversioned_Soname, Path, Dll_Name },
    page_align:    int,
    pie:           enum { Optional, Required },
    sign_required: bool,
    segments:      enum { Single_Rwx, Split_Rx_Rw },   // Android exige Split
}
```

`sym_prefix` **n'y figure pas** : il appartient à `image/macho` (C2).

```odin
Artifact :: enum { Executable, Shared_Library, Static_Library, Object, App_Package }
Profile  :: enum { Debug, Release }
```

## 3.2 Modèle d'entrée et de résultat : une table, pas des champs

Correction de C3. `entry_model` et `result_model` sont des fonctions de deux variables :

```odin
Entry_Model  :: enum { Sysv_Stack_Argv, Native_Event_Loop, Jni_OnLoad,
                       Ui_Application_Main, Dylib_Init, Abi_Functions, None }
Result_Model :: enum { Exit_Status, Return_Value, Write_Stdout, Lifecycle, None }

entry_model  :: proc(os: Os, a: Artifact) -> Entry_Model
result_model :: proc(os: Os, a: Artifact) -> Result_Model
```

| Artifact | Linux / Windows / macOS | Android | iOS |
|---|---|---|---|
| `Executable` | `Sysv_Stack_Argv` / `Exit_Status` | `Sysv_Stack_Argv` (adb shell) | sans objet |
| `App_Package` | `Native_Event_Loop` / `Lifecycle` | `Jni_OnLoad` / `Lifecycle` | `Ui_Application_Main` / `Lifecycle` |
| `Shared_Library` | `Dylib_Init` + `Abi_Functions` / `Return_Value` | `Jni_OnLoad` + `Abi_Functions` | `Dylib_Init` + `Abi_Functions` |
| `Static_Library`, `Object` | `Abi_Functions` / `Return_Value` | idem | idem |

`Result_Model.Exit_Status` est un canal **8 bits** (`emit.odin:492-494`) : il rend
`Return_Value` obligatoire dès `Shared_Library` (JNI, `targets.md` §8.5) et dès l'usage d'un
statut > 255.

## 3.3 Ce qui dépend de quoi — matrice

| Décision | ISA | ABI | Image | Plateforme | Artifact | Profile |
|---|:-:|:-:|:-:|:-:|:-:|:-:|
| sélection d'instructions | ● | | | | | |
| encodage, modes d'adressage | ● | | | | | |
| matérialisation de constante | ● | | | | | |
| prologue / épilogue, layout de frame concret | ● | ● | | | | |
| branchements longs, veneers | ● | | | | | |
| SIMD | ● | | | | | |
| registres d'arguments, ordre des slots | | ● | | | | |
| shadow space, red zone, alignement de pile | | ● | | | | |
| variadiques | | ● | | ● | | |
| classification d'agrégats, `sret` | | ● | | | | |
| registres callee-saved | | ● | | | | |
| préfixe de symbole | | | ● | | | |
| mécanisme d'import (GOT / IAT / binding) | | | ● | | | |
| numéros de relocation | ● | | ● | | | |
| en-têtes, segments, sections | | | ● | ● | | |
| `p_align` / taille de page | | | | ● | | |
| chemin du loader | | | | ● | | |
| forme du nom de bibliothèque | | | | ● | | |
| appels système vs libc | | | | ● | | |
| RX/RW séparés | | | | ● | | |
| point d'entrée | | | | ● | ● | |
| canal de résultat | | | | ● | ● | |
| symboles exportés dans les tables | | | ● | | ● | |
| relocations en *sections* (vs résolues) | | | ● | | ● | |
| archive `ar` | | | | | ● | |
| signature | | | | ● | ● | ● |
| conteneur d'application | | | | ● | ● | |
| isel + regalloc exécutés ou non | | | | | | ● |
| information de debug | | | ● | | | ● |
| hot reload | | | | | | ● |

Trois lignes croisent plusieurs colonnes et c'est là que les specs se trompent de niveau :
**variadiques** (ABI × plateforme — Apple arm64, `abi.md` §2.2), **point d'entrée / résultat**
(plateforme × artifact — C3), **signature** (plateforme × artifact × profile — C1).

---

# 4. Contrat `BC_Program → Code_Object → Image`

## 4.1 Le pipeline, avec le manque explicité

```
IR réduit
  → BC_Program                      neutre. AUJOURD'HUI SANS FONCTIONS.        (M5)
      ├── interp                    oracle + tier debug. AUJOURD'HUI SANS FFI. (M12)
      └── isa/<arch> → Code_Object  code + relocs + symboles, AUCUNE adresse   (M3)
              → image/<fmt> → []u8
                  → sign/<scheme> → []u8
                      → package/<kind>
```

## 4.2 Ce que `BC_Program` doit gagner d'abord

`targets.md` §3 décrit un `Code_Object` avec `syms: []Sym` incluant des `Global_Def`. **Rien
en amont ne peut en produire plus d'un** : `lower_to_bytecode` (`bytecode.odin:145-161`)
aplatit tout en un DAG avec CSE (`l.memo`, `:169`) et un seul `BC_Ret`. Il n'existe donc pas
d'unité nommée à exporter, à patcher, ou à appeler depuis C.

```odin
// bytecode/bytecode.odin — extension minimale (M5)
BC_Func :: struct {
    id:          Func_Id,          // index dense, local au programme
    identity:    string,           // chemin qualifié du binding — stable entre compilations
    params:      []Machine_Type,   // dans l'ordre des bindings colorés
    result:      Machine_Type,
    insts:       []BC_Inst,
    value_count: int,
    label_count: int,
    value_types: []Machine_Type,
    loops:       []Loop_Info,      // en-tête / latch / sorties — gratuit maintenant (§16)
}

BC_Call :: struct { dst: BC_Value, func: Func_Id, args: []BC_Value }

Loop_Info :: struct { header, latch: BC_Label, exits: []BC_Label }

BC_Program :: struct {
    funcs:   []BC_Func,
    entry:   Maybe(Func_Id),   // absent pour Shared_Library / Object
    exports: []Func_Id,        // §10
    rodata:  []string,
    imports: []BC_Import,      // index = index d'import ABSTRAIT (C6)
    error:   string,
}
```

`Loop_Info` est le point à ne pas rater : il est **presque gratuit** tant que les boucles
n'existent pas, et coûteux ensuite (`targets.md` §12). Il conditionne wasm et JS (§16).

## 4.3 `Code_Object`

```odin
Section :: struct { bytes: []u8, align: int }

Sym_Kind :: enum { Local, Global_Def, Undef_Import }
Sec_Id   :: enum { Code, Rodata, Data, Bss }

Sym :: struct {
    name:       string,
    kind:       Sym_Kind,
    section:    Sec_Id,
    offset:     int,
    size:       int,
    lib:        string,      // provenance <lib> opaque, pour les imports uniquement
    import_idx: int,         // index d'import abstrait, -1 si non-import
}

Export :: struct { sym: Sym_Id, signature: Abi_Signature }

Reloc :: struct { at: int, in_section: Sec_Id, kind: Reloc_Kind, sym: Sym_Id, addend: i64 }

Code_Object :: struct {
    code, rodata, data: Section,
    bss_size:  int,
    syms:      []Sym,
    relocs:    []Reloc,
    entry:     Maybe(int),        // offset dans code ; absent pour .so / .o
    exports:   []Export,
    lines:     []Line_Map,        // pc → (fichier, ligne, colonne)
    bindings:  []Binding_Range,   // identité de binding → [pc_start, pc_end) + Func_Id
    frames:    []Frame_Info,      // CFA + registres sauvés, par fonction
}
```

Trois champs au-delà de `targets.md` §3, chacun avec une raison :

- **`data` + `bss_size`** : aucune section de données inscriptible n'existe
  (`elf.odin:110`). Sans elle : pas de table d'arguments propre, pas de GOT relogeable, pas
  d'arène de scratch (`vulkan-slice.md` §1.5 A), pas de table d'indirection (§11).
- **`bindings`** : un seul champ qui sert **le debug et le hot reload**. C'est le pont entre
  l'identité de binding (§11) et le code émis. À réserver maintenant, à remplir en M5.
- **`frames`** : nécessaire dès qu'une fonction ABI existe (callbacks, exports) — un callback
  qui traverse du code C sans information d'unwind casse tout débogueur.

`entry` est un `Maybe` : c'est ce qui empêche par construction d'émettre un `_start` dans un
`.so`.

## 4.4 Relocations nécessaires

Constantes **vérifiées contre `/usr/include/elf.h`** de cette machine. Mach-O et PE restent
**[SPEC]** — à vérifier contre `mach-o/reloc.h` et la spécification PE au moment de
l'implémenter, comme l'exige `targets.md` §8.

### x86-64 / ELF

| Intention | Reloc | Valeur |
|---|---|---|
| adresse absolue en données | `R_X86_64_64` | 1 |
| référence PC-relative code/données | `R_X86_64_PC32` | 2 |
| appel vers un symbole externe (objet) | `R_X86_64_PLT32` | 4 |
| remplissage de slot GOT au chargement | `R_X86_64_GLOB_DAT` | 6 |
| pointeur interne à rebaser (PIE, données) | `R_X86_64_RELATIVE` | 8 |
| chargement RIP-relatif via GOT | `R_X86_64_GOTPCREL` | 9 |

### arm64 / ELF

| Intention | Reloc | Valeur |
|---|---|---|
| adresse absolue en données | `R_AARCH64_ABS64` | 257 |
| `adrp` — page (haut 21 bits) | `R_AARCH64_ADR_PREL_PG_HI21` | 275 |
| bas 12 bits, forme `add` | `R_AARCH64_ADD_ABS_LO12_NC` | 277 |
| bas 12 bits, forme `ldr/str` **8 bits** | `R_AARCH64_LDST8_ABS_LO12_NC` | 278 |
| … **16 bits** | `R_AARCH64_LDST16_ABS_LO12_NC` | 284 |
| … **32 bits** | `R_AARCH64_LDST32_ABS_LO12_NC` | 285 |
| … **64 bits** | `R_AARCH64_LDST64_ABS_LO12_NC` | 286 |
| … **128 bits** | `R_AARCH64_LDST128_ABS_LO12_NC` | 299 |
| `b` inconditionnel | `R_AARCH64_JUMP26` | 282 |
| `bl` | `R_AARCH64_CALL26` | 283 |
| `adrp` vers la page du GOT | `R_AARCH64_ADR_GOT_PAGE` | 311 |
| `ldr` bas 12 du slot GOT | `R_AARCH64_LD64_GOT_LO12_NC` | 312 |
| slot GOT rempli au chargement | `R_AARCH64_GLOB_DAT` | 1025 |
| pointeur interne à rebaser | `R_AARCH64_RELATIVE` | 1027 |

**Piège que `targets.md` §8.2 manque** : il ne cite que `ADD_ABS_LO12_NC`. Or le bas 12 bits
d'une paire `adrp`+**`ldr`** utilise une reloc **différente par taille d'accès** (278 / 284 /
285 / 286 / 299), parce que l'immédiat de `ldr` est **mis à l'échelle** par la taille. Utiliser
`ADD_ABS_LO12_NC` sur un `ldr` produit un déplacement multiplié par 8. Deuxième piège, celui
que `targets.md` §8.2 signale correctement : la valeur d'`adrp` est
`(target >> 12) - (pc >> 12)`, en pages de **4 Ko**, indépendamment de `p_align`.

### Mach-O, PE **[SPEC]**

| Container | Import | Interne |
|---|---|---|
| Mach-O classique | `__got`/`__la_symbol_ptr` + opcodes de bind `LC_DYLD_INFO_ONLY` | `X86_64_RELOC_*` / `ARM64_RELOC_*` |
| Mach-O moderne | `LC_DYLD_CHAINED_FIXUPS` (pointeurs chaînés) | idem |
| PE/COFF | Import Directory + IAT (nom ou ordinal) | `IMAGE_REL_AMD64_*`, `.reloc` pour le rebasing |

La question ouverte d'`abi.md` §3 (bind classique encore accepté, ou fixups chaînés
obligatoires ?) doit être tranchée **avant** de commencer Mach-O ; elle change l'ampleur du
travail d'un facteur notable.

### Où les kinds abstraits s'arrêtent

**Ne pas construire un jeu de relocations universel.** `Code_Object.Reloc_Kind` doit être
**concret par ISA, neutre par image** — exactement ce que fait `targets.md` §3 avec
`Aarch64_Adrp_Hi21` dans une énumération partagée, et c'est le bon découpage : la couche ISA
sait qu'elle a émis une paire `adrp`/`ldr64`, la couche image sait traduire ce kind en
`275` + `286` pour ELF ou en `ARM64_RELOC_PAGE21`/`PAGEOFF12` pour Mach-O. Une abstraction
plus haute (« référence PC-relative ») perdrait l'information de taille d'accès, qui est
exactement ce qui distingue 278 de 286.

## 4.5 Élimination des adresses absolues

| Site actuel | Devient | Reloc |
|---|---|---|
| `emit.odin:664-666` `movabs rax, rodata_vaddr+off` | x64 `lea rax,[rip+disp32]` ; arm64 `adrp`/`add` | `PC32` ; `275`+`277` |
| `emit.odin:177/205/632` `movabs rXX, ARGS_TABLE_VADDR` | symbole `__syn_args` en `.bss`, adressé PC-relativement | idem |
| `emit.odin:759` `movabs r10, GOT_VADDR+8*slot` puis `call [r10]` | x64 `call *__syn_got+8i(%rip)` ; arm64 `adrp`/`ldr`/`blr` | `GOTPCREL` ; `311`+`312` |
| `elf.odin:40` `ELF_BASE` | `p_vaddr` relatif à l'image, `e_type = 3` (ET_DYN) | — |
| `elf.odin:110` `memsz` couvrant args+GOT | sections `.data`/`.bss` réelles | — |
| `elf.odin:149-150` `PT_LOAD` unique RWX | `PT_LOAD` RX + `PT_LOAD` RW (`Platform.segments`) | — |
| `elf_dynamic.odin:178` `r_offset = GOT_VADDR+8i` | offset du symbole `__syn_got`, résolu au layout | — |

**Conséquence à exploiter, correctement énoncée par `targets.md` §8.2 :** si toute référence
interne est PC-relative, un **PIE statique n'a besoin d'aucune relocation à l'exécution**. Pas
de `PT_INTERP`, pas de stub d'auto-relocation, table `.rela` vide. **Ne pas écrire de
relocateur de bootstrap.**

Il faut cependant ajouter ce que `targets.md` ne dit pas : le passage RX/RW **réintroduit la
contrainte d'alignement du second segment** que le commentaire `elf.odin:68-70` évitait
délibérément. C'est le vrai coût de M4, et il est inévitable pour Android.

## 4.6 Ce que le jalon PIE ne doit pas casser

Deux acquis coûteux à ne pas re-découvrir (`interop.md` §1) : `DT_PLTGOT` doit pointer sur
l'en-tête réservé de 3 entrées (`elf.odin:75`, `GOT_RESERVED`), et le bon tag est **`DT_RELA`
+ `R_*_GLOB_DAT`**, pas `DT_JMPREL` (qui appartient au chemin PLT paresseux inexistant ici).
`elf_dynamic.odin:37-59` porte les deux, et les commentaires `:15-34` en portent la raison.
Le passage au relogeable doit les préserver mot pour mot.

---

# 5. Deux backends ISA — ce qui se partage, ce qui ne se partage pas

## 5.1 Partageable, avec les prérequis

| Élément | Prérequis réel |
|---|---|
| Analyse de vivacité | **Doit d'abord grandir** : liveness avant-seulement par construction (`regalloc.odin:14-19`), et aucune notion de clobber d'appel (F3). Partager une liveness fausse la duplique. |
| Linear-scan, spill | Paramétrer sur `Reg_File` ; retyper `VReg_Loc.reg` de `Register64` (`regalloc.odin:31`) vers un `Phys_Reg :: distinct u8` opaque + `Reg_Class`. |
| Frame abstrait | Nombre de slots, tailles, alignement. Le prologue concret reste par ISA. |
| Préférences physiques | `phys_pref` (`regalloc.odin:86-91`) code en dur RDI/RSI pour l'`exit` : doit devenir `Abi`-piloté. |
| `Code_Object`, symboles, relocations | Rien, c'est du nouveau code. |
| Harnais différentiel | Un préfixe d'exécution (`codegen.odin:206-208`) suffit ; ajouter stderr (F5). |
| `bc_def` / `bc_uses` | Déjà neutres (`regalloc.odin:303-350`). À déplacer vers `isa/common`. |

```odin
Reg_File :: struct {
    allocatable:  []Phys_Reg,      // x64 : 10 aujourd'hui ; arm64 : ~25
    reserved:     []Phys_Reg,
    caller_saved: []Phys_Reg,      // dérivé de Abi.callee_saved — UNE définition
    class_of:     proc(Machine_Type) -> Reg_Class,
}
```

`caller_saved` doit être **dérivé** de `Abi.callee_saved` et non listé deux fois : c'est le
même piège que C2. Les 31 GPR d'arm64 signifient alors « moins de spill », gratuitement, comme
le note `targets.md` §5.

## 5.2 Non partageable — et il ne faut pas forcer

| Élément | Pourquoi les mécanismes sont incomparables |
|---|---|
| Sélection d'instructions | x64 : appariement `lea`/modes d'adressage (`isel.odin`, `emit.odin:610-619`). arm64 : `madd`/`msub`, opérande décalée, pré/post-index. Rien en commun. |
| Encodage | x64 : longueur variable, REX/ModRM/SIB. arm64 : 32 bits fixes, champs de bits. |
| Matérialisation de constante | x64 : `movabs` 10 octets, une instruction. arm64 : chaîne `movz`+`movk×3`, ou pool littéral + `ldr` PC-relatif. Choix d'ingénierie, pas paramétrage. |
| Prologue / épilogue | x64 : `push rbp` ; red zone SysV 128 octets. arm64 : `stp x29,x30,[sp,#-16]!`, pas de red zone, `sp` alignée 16 **en permanence**. |
| **Branchements longs** | x64 : `rel32` ±2 Go, la passe de patch en deux temps (`emit.odin:20-21`) atteint toujours. arm64 : `b`/`bl` ±128 Mo, **`b.cond` ±1 Mo** — il faut des **veneers** ou une itération de layout jusqu'au point fixe. Le layer partagé ne doit pas supposer qu'un patch atteint toujours. |
| SIMD | `vectorize.odin`, `x64_sse_scalar.odin`, `x64_movzx_mem.odin` restent x64. NEON a son propre modèle. |
| Suite d'encodage | `x64_test.odin` : 8 007 lignes. arm64 a besoin de l'équivalent, écrit à neuf. |

`ByteBuffer` passé par `context.user_ptr` (`emit.odin:118`) est un choix d'implémentation x64.
Le backend arm64 doit passer son buffer explicitement — ne pas propager le global.

---

# 6. Linux comme première matrice, et les tests différentiels

## 6.1 Évaluation du chemin proposé

Le chemin de la demande §5 est correct dans l'ordre. Deux précisions.

1. **Le harnais avant le backend.** Le préfixe d'exécution et la capture de stderr doivent
   arriver **avant** arm64, validés sur x64 avec un préfixe vide. Sinon le premier programme
   arm64 est débogué à travers un harnais lui-même non éprouvé — exactement la faute que la
   règle « une seule variable nouvelle » interdit.
2. **Le premier jalon arm64 ne demande aucun sysroot.** Un programme sans `<lib>` sort
   **statique** (`elf.odin:86-88`) : `qemu-aarch64 ./prog` suffit, sans `-L`, sans glibc
   arm64. Le sysroot n'est requis que pour les cas dynamiques. C'est la propriété qui rend le
   premier jalon arm64 bon marché, et elle n'est pas dans `targets.md`.

## 6.2 La stratégie différentielle

```
source Syntact
  → réduction
  → BC_Program
      ├── interp                      ORACLE
      ├── x64 ELF natif               exécution directe
      └── arm64 ELF                   qemu-aarch64 [-L sysroot]
```

Extension du harnais existant (`test/codegen/codegen.odin`) :

```odin
Runner :: struct { target: string, prefix: string, needs_sysroot: bool }
// { "linux-x64",   "",                              false }
// { "linux-arm64", "qemu-aarch64 -L /usr/aarch64-linux-gnu", true }   // -L seulement si dynamique
```

`run_shell` (`codegen.odin:72-88`) devient `popen(cmd + " 2>&1")` **plus** une capture séparée,
et `run_combo` (`:182-240`) boucle sur les runners disponibles.

| Grandeur comparée | État aujourd'hui | À faire |
|---|---|---|
| valeur de résultat | comparée | — |
| stdout | comparé | — |
| **stderr** | **non capturé** (F5) | capturer et comparer |
| statut de sortie | comparé, tronqué 8 bits | conserver, documenter la limite, ajouter `Return_Value` en M11 |
| **traps** (div par 0, débordement) | **divergence existante non testée** (F5) | décider la loi, puis tester : soit l'interpréteur trappe, soit le natif produit une erreur — pas les deux comportements actuels |
| appels ABI | non observables | ajouter des cas à externe *observable* (`write` vers stdout, ordre et compte des appels) |
| **effets externes** | **aucun oracle** (F3, C8) | FFI dans l'interpréteur (M12) ; en attendant, comparaison x64 ↔ arm64 + attente écrite à la main, ce qui est plus faible et doit être signalé comme tel dans le cas de test |
| optimisations | un seul niveau | quand `Profile`/`features` existeront, croiser les runners avec les niveaux |

## 6.3 Ce que QEMU est, et n'est pas

QEMU est un **exécuteur** du backend arm64, jamais un oracle. L'oracle reste `interp`. Deux
conséquences à écrire dans le harnais :

- une divergence arm64/QEMU vs interp est un **bug du backend arm64** par défaut, et un bug
  de QEMU seulement après réduction du cas ;
- pour un programme `<lib>`, l'interp est muet (C8), donc la comparaison est
  **x64 ↔ arm64 uniquement**. Un tel cas doit être **marqué** dans le fichier de cas
  (`kind: "extern"`), pour que le rapport dise honnêtement « deux implémentations d'accord »
  et non « conforme à l'oracle ».

**Prérequis d'environnement** : `qemu-aarch64` **n'est pas installé** sur cette machine
(**[VÉRIFIÉ]** : `which qemu-aarch64` échoue, `qemu-user` absent, `/usr/aarch64-linux-gnu`
absent). Le paquet `qemu-user` et, pour les cas dynamiques, un sysroot glibc arm64 sont à
ajouter à `syntact doctor` (`sdk.md` §7.3).

---

# 7. Le modèle `@platform`

## 7.1 État : inexistant, et le chemin de résolution est occupé

**[VÉRIFIÉ]** `@platform.os` ⇒ `property 'os' does not exist`. **[LECTURE]** `@nom` construit
un nœud `External` puis appelle `process_filenode_flat` (`parse.odin:2490-2530`) : `@` est
aujourd'hui **exclusivement** la résolution du système de fichiers comme graphe de scopes.

Décision requise, déjà ouverte dans `sdk.md` §3.2 : **le compilateur possède un petit jeu fixe
de namespaces racine** (`@platform` aujourd'hui), et tout le reste retombe sur la résolution
d'arbre actuelle. C'est la décision minimale, et elle est compatible avec l'ajout ultérieur de
`@lib` ou d'un espace tiers.

## 7.2 Surface, et sa dérivation unique

`@platform` est une **projection** de `Target`/`Platform`/`Abi`, pas une seconde liste (C10).
Pour que la dérive soit impossible, un test doit échouer si un champ de `Platform` n'est
projeté ni en source ni marqué explicitement backend-only.

```
@platform.os              linux | android | macos | ios | ios_sim | windows
@platform.arch            x86_64 | arm64
@platform.abi             sysv | win64 | aapcs64 | aapcs64_apple
@platform.image           elf | macho | pe
@platform.family          unix | windows                    dérivé
@platform.pointer_bits    64                                dérivé de arch
@platform.endian          little | big                      dérivé de arch
@platform.usize/.isize    shapes entières de largeur pointeur
@platform.page_size       taille de page
@platform.syscalls        bool — false ⇒ passage obligé par la libc
@platform.libc_name       chaîne
@platform.lib_ref         soname | unversioned_soname | path | dll_name
@platform.pie             optional | required
@platform.features        jeu d'extensions ISA               OUVERT (§7.5)
@platform.artifact        Executable | Shared_Library | Static_Library | Object | App_Package
@platform.profile         debug | release
```

`sym_prefix` n'est **pas** exposé : c'est une propriété du writer d'image (C2), et un programme
n'a aucun usage de la façon dont ses propres symboles sont décorés. Restent backend-only :
`entry_model`, `result_model`, `Platform.segments`, `Platform.loader`.

## 7.3 `arch` plutôt que `aarch` — et `arm64` plutôt que `aarch64`

La demande interroge l'orthographe. Réponse :

- **`arch`** est le bon nom du champ. `aarch` n'est pas un mot ; `aarch64` est un nom
  d'architecture, pas un nom de propriété.
- Sur la **valeur**, les specs se contredisent (C4). Recommandation : **`arm64` partout où
  c'est visible du programmeur** — nom de cible (`linux-arm64`, déjà le cas dans
  `targets.md` §6.1) et valeur de `@platform.arch`. Réserver `aarch64` aux endroits qui
  *portent littéralement ce nom* : `EM_AARCH64` (183), `R_AARCH64_*`, « AAPCS64 ». Une seule
  orthographe source-visible, l'autre confinée aux constantes.

## 7.4 Ce que la syntaxe proposée fait réellement

| Forme | État |
|---|---|
| `@platform.os ? { linux -> …, -> … }` | **syntaxe valide**, `@platform` **inexistant** (**[VÉRIFIÉ]**) |
| branche par défaut `_ ->` | **invalide** : `_` est un identifiant ordinaire (**[VÉRIFIÉ]** : `'_' is not defined`). La branche par défaut est un `->` **sans pattern** (`12-patterns.md:19`) |
| `~aarch64 -> !unsupported_target` (`sdk.md` §128) | **n'existe pas** : aucune primitive d'erreur nulle part dans les specs ni le code. `!x` parse (préfixe `Execute`, `parse.odin:790`) donc `!unsupported_target` produit un `Undefined_Identifier` — une erreur, par accident, avec un message trompeur |
| `@error.panic{"…"}!` (demande §6/§8) | **n'existe pas** du tout |
| pattern à branches-scopes | **cassé** (F1) — c'est le vrai bloqueur |

## 7.5 Règles d'exhaustivité et de rejet — sans inventer de primitive

L'analyseur **impose déjà** l'exhaustivité : **[VÉRIFIÉ]** un pattern sans défaut et sans
couverture totale émet `Non_Exhaustive_Pattern` (`analyze.odin:1956-1966`). Cela donne
gratuitement une partie de la réponse.

| Question de la demande §6 | Réponse |
|---|---|
| branche par défaut obligatoire ? | **Non**, si les branches couvrent l'ensemble. Une union exhaustive de valeurs d'`os` suffit. |
| erreur de compilation si aucun cas ne correspond ? | **Oui, déjà** — mais l'erreur porte sur la *non-exhaustivité*, donc elle se déclenche sur **toutes** les plateformes, pas seulement sur celle non supportée. C'est insuffisant pour « rejeter explicitement une plateforme ». |
| branche explicite produisant une erreur ? | **La primitive manque.** Recommandation : **ne pas ajouter `@error.panic`.** La forme algébrique existe déjà : une branche de production **vide** vaut `None` — `walk_pattern` fait `product = make_none()` quand le produit est absent. Il manque **un diagnostic** : aujourd'hui `None_Type` s'abaisse silencieusement en `const 0` (`bytecode.odin:193-196`). La règle à ajouter : **une production requise qui se réduit en `None` est une erreur de compilation**, nommant le fichier, la ligne et la branche sélectionnée. Le rejet devient l'ensemble vide, ce qui est la lecture algébrique du refus. Un message textuel est du sucre, ajoutable plus tard sans changer la loi. |
| élimination des branches non retenues avant codegen ? | **Déjà acquise** (**[VÉRIFIÉ]** `tag ? {1 -> 10, 2 -> 20, -> 30}` ⇒ `v0 = const 10`). |

## 7.6 Le seul travail réel derrière `@platform`

Deux morceaux, dans cet ordre :

1. **Injection littérale.** `@platform.<champ>` se résout, à l'analyse, en la **valeur
   littérale** correspondante de la cible. Aucun mécanisme comptime nouveau : `@platform.os`
   *est* un littéral, donc `@platform.os ? { … }` est un pattern à scrutateur littéral, forme
   que le réducteur traite déjà.
2. **Projection à travers `Pattern_Type` (F1).** Deux variantes :
   - **(a) minimale, suffisante pour `@platform`** : ajouter à `resolve_property_site`
     (`analyze.odin:1189-1216`) un cas `Pattern_Type` qui, **lorsque le scrutateur est
     littéral et la branche donc décidée**, résout la propriété contre le produit de cette
     branche. Correct par construction : le pattern *est* déterminé.
   - **(b) générale** : joindre les productions de branches (`Or_Type` de scopes) et ne
     projeter que les champs communs. C'est l'item 2 de l'ordre de construction
     d'`effects.md` (« pattern types — NEXT »), et c'est un travail plus vaste.

   **(a) d'abord.** Elle débloque `@platform`, l'interop portable et la sélection par
   architecture ; (b) reste nécessaire pour un scrutateur symbolique et peut suivre.

---

# 8. Interop portable avec `<lib>`

## 8.1 Le chemin complet, et où il casse aujourd'hui

```
branche @platform réduite            ✗ @platform absent (§7) ET projection cassée (F1)
  → provenance <lib>                 ✔ Scope_Type.foreign_lib, ir.odin:118-124, survit aux clones
  → symbole importé + bibliothèque   ✔ bc_intern_import → BC_Import (bytecode.odin:349-352)
                                        ✗ mais l'index EST le slot GOT (C6)
  → classification ABI               ✗ SysV en dur (emit.odin:700-701), 6 args max (:717-720),
                                        pas de clobber (F3), pas d'agrégats
  → relocation abstraite             ✗ Code_Object absent ; adresse GOT absolue (emit.odin:759)
  → GOT / IAT / binding Mach-O       ~ GOT ELF seul (elf_dynamic.odin)
```

## 8.2 La séparation stricte des quatre questions

| Question | Propriétaire | Aujourd'hui | Cible |
|---|---|---|---|
| **nom** de la bibliothèque | **le source** | chaîne littérale opaque, jamais interprétée (`interop.md` §1) — **à préserver, c'est un invariant** | branche `@platform` réduite ⇒ le compilateur reçoit une chaîne résolue, exactement comme aujourd'hui |
| **forme** de la référence | la **plateforme** | soname versionné en dur | `Platform.lib_ref` : soname / soname non versionné / chemin / nom de DLL |
| **convention** d'appel | l'**ABI** | SysV en dur | record `Abi` (`abi.md` §2.3) |
| **mécanisme** d'import | le **format d'image** | GOT + `.rela` | GOT / IAT / bind ou fixups chaînés |

**L'invariant « aucune bibliothèque n'est privilégiée » survit intact** : le compilateur ne
gagne aucune table de noms ; il reçoit une chaîne, issue d'une branche déjà effondrée. Les
correspondances usuelles pour la libc sont **une bibliothèque Syntact ordinaire** — un dossier
de `.syn` — pas une donnée du compilateur (`abi.md` §4).

**Échappatoire à conserver** : un `<…>` contenant un littéral spécifique à une plateforme doit
continuer de fonctionner verbatim, non résolu. C'est le comportement actuel et il ne doit pas
régresser.

## 8.3 Les quatre classes de portabilité d'un binding — un seul mécanisme

| Classe | Forme |
|---|---|
| **complètement portable** | un `<lib>` unique, si le symbole existe partout sous le même nom |
| **spécifique à un OS** | `@platform.os ? { … }` autour de la déclaration `<lib>` |
| **spécifique à une architecture** | `@platform.arch ? { … }` |
| **explicitement non supporté** | une branche à production **vide** ⇒ `None` ⇒ erreur de compilation (§7.5) |

Aucune syntaxe nouvelle, aucun manifeste, aucun attribut. Les quatre classes sortent du même
pattern et de la même loi de rejet.

## 8.4 Divergences d'ABI à traiter, par ordre de morsure

Reprises d'`abi.md` §2.2/§6/§7, sans les réécrire, avec le rappel de ce qui est cassé :

1. **Registres caller-saved** (F3, `vulkan-slice.md` D1) — **prérequis absolu**, avant tout
   record `Abi`. Un `Abi` correct posé sur un appel qui détruit ses vivants ne corrige rien.
2. **Alignement de pile** (`vulkan-slice.md` D5) : `push rbp` + `sub rsp, frame` laisse
   `RSP ≡ 8` avant l'appel (`emit.odin:451-463`). Correct uniquement quand rien n'est spillé.
3. **Arguments sur la pile** — le plafond de 6 (`emit.odin:717-720`) doit tomber avant Win64
   (4 slots registres seulement).
4. **Slots positionnels Win64** — `int_i`/`sse_i` sont des compteurs indépendants
   (`emit.odin:738-749`) : correct SysV, **faux Windows**.
5. **Shadow space Win64** (32 octets) et **absence de red zone** — le scratch d'impression
   flottante en red zone (`emit.odin:507-516`) n'est pas portable.
6. **Variadiques Apple arm64** : tous sur la pile. Une implémentation AAPCS64 écrite contre les
   règles Linux produira des appels faux à toute fonction variadique sur Apple.
7. **Agrégats** : quatre implémentations, pas une fonctionnalité (`abi.md` §6). `Abi.classify`
   comme point d'extension, SysV d'abord.
8. **`sret`** : le *caller* alloue et passe un pointeur caché ; nécessite une arène
   (`vulkan-slice.md` §1.5 A montre que le mécanisme existe déjà).
9. **Callbacks** : direction inverse, une vraie fonction ABI. Voir §10 et §13 — c'est **la même
   capacité** que les symboles exportés.
10. **Préfixe Mach-O** : `_` devant chaque symbole, côté writer d'image.

Ajouter le défaut F2 à cette liste : un `<lib>` utilisé **directement** comme symbole perd sa
provenance et devient un slot `argv`, silencieusement. La forme portable pousse à écrire des
branches imbriquées, ce qui rapproche de cette faute.

---

# 9. ASM inline spécifique à l'ISA

## 9.1 La grammaire proposée ne parse pas

**[VÉRIFIÉ]** `<asm x86_64>{ … }` ⇒ quatre erreurs (`'asm' is not defined`,
`'<' expects a number`, …). Cause : `is_lib_path_byte` (`parse.odin:428-436`) n'accepte que
`[a-zA-Z0-9._+-/]` — **pas l'espace**. Donc `<asm x86_64>` n'est pas une provenance.

**[VÉRIFIÉ]** `<asm>{ u8:a, -> ??::u8 }` **parse**, comme une bibliothèque nommée `asm`, et
tombe dans le défaut F2 : `-> f{a->1}!` produit `v0 = arg 0 ; ret v0`. Aucune notion d'asm
n'existe.

## 9.2 À décider maintenant (rétrofit coûteux)

**D-1. La loi de volatilité, énoncée une seule fois pour `<lib>` et `<asm>`.**
Un bloc franchissant la frontière est **non repliable, non duplicable, non éliminable, et
ordonné**. Aujourd'hui `foreign_lib` (`ir.odin:118-124`) est le crochet « ne pas replier à
travers », et il ne dit rien de la duplication ni de l'ordre. Les preuves que ce n'est pas
théorique : un collapse externe sous un pattern est **effacé** (`vulkan-slice.md` D3), et
l'ordre de deux effets est **accidentel** (`vulkan-slice.md` §4.3). La loi doit être écrite et
implémentée une fois, pour les deux formes. C'est le prérequis de tout le reste de cette
section.

**D-2. Comment l'ISA d'un bloc est portée.** Recommandation : **deux barrières, pas une**.
   - le bloc est **éliminé comptime** par un pattern `@platform.arch` ordinaire — c'est le
     mécanisme normal, pas une directive ;
   - le bloc **porte tout de même son étiquette d'ISA**, et le backend **refuse** un bloc dont
     l'étiquette ne correspond pas à `Target.arch`. Un bloc atteint sans branche ne doit pas
     être compilé silencieusement pour la mauvaise ISA.

   Répond à la question de la demande « typé par ISA ou simplement éliminé comptime ? » :
   **les deux**, et pour deux raisons différentes — l'élimination est la sémantique, la
   vérification est un filet.

**D-3. La place de l'étiquette dans la grammaire.** Trois options, aucune sans coût :

| Option | Coût |
|---|---|
| `<asm x86_64>` | il faut autoriser l'espace dans la provenance et écrire une sous-grammaire — la provenance cesse d'être une chaîne opaque |
| `<asm.x86_64>` | parse **déjà** (`.` est un octet de chemin), zéro changement de lexer, mais collide avec l'espace des noms de bibliothèque |
| `<asm>` + étiquette dans le corps | garde la provenance opaque ; l'étiquette devient une donnée du bloc |

Recommandation : trancher **D-3 en dernier**, après D-1 et D-2, parce que c'est la seule des
trois qui est purement syntaxique. `<asm.x86_64>` est le moins-disant immédiat.

## 9.3 Différable

- Syntaxe des entrées / sorties / clobbers. `effects.md` (« ASM inline ») recommande une
  **convention fixe** d'abord (bindings → rdi/rsi/rdx…, retour → rax, clobbers SysV), les
  mappings explicites étant un sur-ensemble non cassant. Conserver, avec l'avertissement
  d'`effects.md` : **ne pas oublier les clobbers** (`syscall` détruit `rcx`/`r11`).
- Relocations depuis un bloc asm : `Code_Object.Reloc` porte déjà `at`, donc un bloc peut
  contribuer ses relocations à ses propres offsets. La capacité est réservée ; la syntaxe de
  référence à un symbole est différable.
- Alignement de pile vu du bloc : le bloc hérite de la frame ABI, mais la frame est
  **actuellement fausse** (`vulkan-slice.md` D5). Aucun bloc asm ne peut supposer
  l'alignement avant que ce défaut soit corrigé.
- Mémoire et effets : couverts par D-1, rien de plus.

---

# 10. Ordre des plateformes

## 10.1 Évaluation de l'ordre proposé, et la correction

La règle est juste : **ne jamais déboguer une ISA nouvelle à travers un conteneur nouveau.**
L'ordre de la demande la respecte, sauf sur deux points.

| Rang | Cible | Nouveauté | Justification |
|---|---|---|---|
| 1 | linux-x64 ELF | — | consolider : F3, D5, `Target`, couches, `Code_Object`, PIE |
| 2 | **linux-arm64 ELF (QEMU)** | **ISA** | conteneur connu. **Avant Windows** : arm64 conditionne **5 des 8 cibles** (linux-arm64, macos-arm64, android, ios-sim, ios) contre 1 pour PE ; et un second consommateur de `Code_Object` et du regalloc partagé est ce qui *prouve* la séparation. Enfin, QEMU rend la boucle testable sur cette machine, alors que PE exige un hôte Windows ou Wine |
| 3 | **android-arm64 ELF, exécutable via `adb`** | **plateforme seule** | **Ajout au plan de la demande.** Ni ISA nouvelle, ni conteneur nouveau, **ni signature** (`targets.md` §9 : rien ne vérifie la signature d'un ELF ; `adb push /data/local/tmp` + `chmod +x` suffit). Ce qu'il exige : un record `Platform` (PIE requis, `/system/bin/linker64`, soname non versionné, `p_align ≥ 0x10000`, RX/RW séparés). C'est **exactement** le jalon qui prouve la thèse « la plateforme est une donnée », au coût le plus bas de la matrice |
| 4 | windows-x64 PE/COFF | **conteneur** | ISA connue. Valide « aucun code d'arch dans les writers d'image », par l'autre côté. Amène l'ABI Win64 (slots positionnels, shadow space, args pile) |
| 5 | macos-x64 Mach-O | conteneur | s'exécute **non signé** (`targets.md` §9) : le writer Mach-O se développe et se teste **avant** que la signature existe |
| 6 | macos-arm64 Mach-O + ad-hoc | signature | ISA et conteneur déjà acquis ; seule la signature est nouvelle, et elle est obligatoire (noyau) |
| 7 | ios-sim-arm64 | cycle de vie | hôte macOS, `LC_BUILD_VERSION` plateforme 7, ad-hoc accepté : sortie de forme iOS **sans compte Apple** |
| 8 | ios-arm64 (device) | politique | certificat Apple + profil de provisioning + `amfid`. Le seul mur non technique |
| — | android **App_Package** (APK/AAB + v2) | conteneur + signature | **jalon séparé du rang 3**, bien plus tard |

Deux erreurs de cadrage à corriger explicitement :

- **Windows n'est pas PIE** — PE a son propre rebasing (`.reloc`, ASLR). PIE est une propriété
  de **positionnement**, pas un format : ET_DYN en ELF, `MH_PIE` en Mach-O, table `.reloc` en
  PE. Ne pas modéliser « PIE » comme un booléen de conteneur.
- **Android n'est pas Linux/arm64** — Bionic (pas glibc), `linker64` (pas `ld-linux-*`),
  sonames non versionnés, PIE requis, `p_align ≥ 16 Ko`, RX/RW séparés (SELinux), namespaces
  de linker (`targets.md` §8.5 : `libcrypto`, `libpcre2`, `libasound`, `libSDL2` de la table
  vérifiée d'`interop.md` **ne sont pas chargeables** depuis un namespace d'application), et
  au-delà de l'exécutable : JNI, cycle de vie, APK/AAB, signature.
- **macOS et iOS partagent Mach-O, pas l'ABI ni le cycle de vie** — variadiques sur la pile en
  Apple arm64 (`abi.md` §2.2), `LC_BUILD_VERSION` différent, `UIApplicationMain` vs `_start`.
- **Une application GUI n'a pas de `_start` classique** — d'où `entry_model(os, artifact)`
  (§3.2) et non un point d'entrée par plateforme.

## 10.2 Fiches par cible

| | entry | résultat | ABI | image | imports | syscalls/libc | signature | packaging | transport | debug |
|---|---|---|---|---|---|---|---|---|---|---|
| linux-x64 | `_start` argc/argv | statut 8 bits | SysV | ELF ET_DYN | GOT + `.rela` | syscalls directs, `libc.so.6` si `<lib>` | — | brut / `.so` / `.a` / `.o` | local | DWARF + gdb |
| linux-arm64 | `_start` | statut 8 bits | AAPCS64 | ELF, `p_align 0x10000` | idem | `svc #0`, `x8`, write=64 exit=93 | — | idem | QEMU, SSH | DWARF ; gdb via QEMU gdbstub |
| android-arm64 | `_start` (adb) / `JNI_OnLoad` | statut / valeur | AAPCS64 | ELF ET_DYN, PIE **requis**, RX/RW | GOT, sonames **non versionnés**, namespaces NDK | Bionic, `libc.so`, `linker64` | aucune pour adb ; v2 pour APK | brut → APK/AAB | `adb` | `logcat`, lldb |
| windows-x64 | `_start` / `WinMain` | code de sortie 32 bits | **Win64** | PE/COFF | Import Directory + IAT | pas de syscalls stables, `ucrtbase.dll` | non requise à l'exécution | `.exe` / `.dll` / `.lib` / `.obj` | local, distant | DWARF-in-PE (gdb/lldb ; **pas** WinDbg — écart accepté, `targets.md` §8.4) |
| macos-x64 | `LC_MAIN` | statut | SysV | Mach-O `MH_EXECUTE` | `__got` + bind ou fixups chaînés | **pas de syscalls garantis**, `libSystem.B.dylib` par **chemin** | non requise | brut / `.dylib` | local | DWARF + lldb |
| macos-arm64 | `LC_MAIN` | statut | **Apple arm64** (variadiques pile) | Mach-O, align `0x4000` | idem | idem | **ad-hoc obligatoire** (noyau) | idem, + universal | local | idem |
| ios-sim-arm64 | `UIApplicationMain` | cycle de vie | Apple arm64 | Mach-O, `LC_BUILD_VERSION` = 7 | idem | idem | ad-hoc accepté | `.app` | `simctl` | lldb |
| ios-arm64 | `UIApplicationMain` | cycle de vie | Apple arm64 | Mach-O, plateforme 2 | idem | idem | **cert + profil**, `amfid` | `.ipa` | usbmux / `ideviceinstaller` | debugserver ; **pas de JIT** ⇒ l'interpréteur est obligatoire |

Dernière ligne du tableau : **iOS interdit le JIT**, donc le tier debug y est nécessairement
l'interpréteur (`targets.md` §10). C'est un argument de plus pour que la VM résidente soit
construite tôt et une seule fois.

---

# 11. Artifacts bibliothèque et exports

## 11.1 La proposition évaluée

> *Pour un artifact de bibliothèque externe, les symboles publics sont les propriétés du scope
> retourné par la première production du fichier.*

**Elle tient, et elle est déjà exprimable.** **[VÉRIFIÉ]** :

```syntact
add -> { i32:a, i32:b, -> a + b }
version -> { -> 1 }
-> { add  version }
```
réduit en un scope à deux membres ; `s -> { add }` puis `s.add` **résout** ; et
`exports -> { add -> add, version -> version }` puis `exports.add{a->2,b->3}!` rend **5**.
La mention nue conserve donc son nom comme propriété — seul l'affichage le perd (F6).

## 11.2 Corrections de formulation

| Question de la demande | Réponse |
|---|---|
| « première production » ? | **Mauvais mot.** Un scope a **une** production (le produit `->`-less, `06-productions-and-collapse.md`). La formulation exacte est : **la production du file-scope** — celle dont l'effondrement *est* l'exécution (`03-first-program.md`, `sdk.md` §2). Pas « première ». |
| production racine ou du file-scope ? | Les deux nomment la même chose ; garder **« production du file-scope »**, en cohérence avec `run`. |
| bindings exportés par nom ? | **Oui.** Les propriétés portent des noms, et une mention nue les conserve (**[VÉRIFIÉ]**). |

## 11.3 Fonction, constante, non exportable — un critère algébrique

| Forme réduite de la propriété | Symbole C |
|---|---|
| scope avec **≥ 1 binding d'entrée coloré** + une production | **fonction** de ces paramètres, dans l'ordre des bindings |
| singleton (entier, flottant, chaîne concrète) | **constante** |
| scope **sans** binding d'entrée, avec production | **décision requise** — voir ci-dessous |
| trou générique non rempli (`T <- {}`) | **non exportable** : aucune signature ABI unique |
| binding non coloré | **non exportable** : aucune couche ABI (diagnostic) |
| ferme sur un binding **résonant** | **non exportable** : l'état n'a pas de représentation ABI |

**Décision requise (D-4).** `version -> { -> 1 }` n'a aucune entrée : sa production est déjà
réduite. Le critère le plus algébrique est : *une production est une fonction si et seulement
si la carver est observable*, donc **une entrée au moins**. Sous ce critère `version` s'exporte
comme la **constante `1`**, pas comme `version()`. C'est cohérent, et c'est **différent de
l'intuition de l'exemple de la demande** — donc à confirmer avec le mainteneur.

**Signature ABI stable.** Elle vient des **couleurs**, qui sont exactement ce que l'IR porte
déjà : `Scope_Type.constraints`/`constraint_folds` par binding (`ir.odin:92-93`) et
`cast_target` (largeur + signedness par champ, cité par `vulkan-slice.md` §1.5 B). Aucune
annotation nouvelle. Un binding non coloré n'a pas de signature, donc n'est pas exportable —
c'est la frontière honnête.

**Génériques, contraintes, effets, fermetures.**
- **Générique** : non exportable tel quel ; exportable **carvé au site d'export** —
  `-> { add_i32 -> add{T -> i32} }`. Algébrique, sans marqueur, sans manifeste.
- **Contrainte** : elle *est* la signature ; une contrainte plus fine qu'un type machine
  (`u8 & >10`) s'exporte comme le type machine, la contrainte devenant une obligation de
  l'appelant, non vérifiable côté C. À documenter comme telle, pas à masquer.
- **Effet** : une fonction exportée dont le corps franchit la frontière est légitime — elle
  appelle simplement vers l'extérieur.
- **Fermeture** : sur des valeurs réduites, sans problème (elles sont constantes). Sur un
  binding résonant, refus.

**Nom de symbole C.** Le nom de la propriété, **verbatim**. **Aucun mangling** : les noms sont
déjà uniques dans un scope (donc pas de collision *dans* l'ensemble exporté) et Syntact n'a pas
de surcharge. Préfixe `_` sur Mach-O, appliqué par `image/macho` (C2). Une collision avec le
monde C est le problème de l'auteur, comme dans tout langage sans espace de noms ABI.

**Visibilité.** Seules les propriétés de la production du file-scope sont `Global_Def` ; tout
le reste est `Local`. C'est la règle entière — pas de liste, pas d'attribut, pas de manifeste.

## 11.4 Ce que produire un artifact demande vraiment

| Artifact | Travail |
|---|---|
| `Object` (`.o` / `.obj`) | `Code_Object` + relocations **en sections** (non résolues) ; aucune résolution de symboles |
| `Static_Library` (`.a` / `.lib`) | idem + un writer d'archive `ar` (ou `.lib` COFF) |
| `Shared_Library` (`.so` / `.dylib` / `.dll`) | `Global_Def` dans `.dynsym` / table d'export ; pas de `_start` ; chemin d'init (`.init_array` / `LC_ROUTINES` / `DllMain`) |

`elf_dynamic.odin` n'écrit aujourd'hui que des `SHN_UNDEF` (`targets.md` §8.5) : les symboles
**définis** sont à ajouter. Le refactor de relocation (§4) paie pour les trois lignes à la
fois. **La liaison statique de bibliothèques *externes* reste hors périmètre** (`abi.md` §5) :
émettre `.a` **pour autrui** est un travail d'image, sans aucune résolution de symboles.

## 11.5 Fonctions d'entrée ABI, `sret`, callee-saved

Une fonction exportée est une **vraie fonction ABI** — l'exact inverse d'`emit_foreign_call`.
Il faut :

- les arguments lus dans les **registres ABI**, pas dans `ARGS_TABLE` (`emit.odin:632`) ;
- un prologue sauvegardant réellement les **callee-saved** — `regalloc.odin:48` réserve RBX
  « for later use », ce commentaire marque l'endroit exact où cela change (le diagnostic
  d'`abi.md` §7 est juste, même si la ligne citée est périmée, F4) ;
- `sret` : le **caller** fournit le tampon ; côté callee, écrire dedans ;
- une frame ABI réelle, avec information d'unwind (`Code_Object.frames`, §4.3).

**C'est la même capacité que les callbacks** (`abi.md` §7) : une fonction dont l'entrée obéit à
l'ABI de la plateforme. Une seule implémentation, deux usages — et c'est aussi le socle du
mode mixte (§14) et du reload (§13).

## 11.6 Erreur Syntact à travers une ABI C

Il n'existe **aucun type d'erreur** dans le langage. Recommandation : **ne pas en inventer un
pour l'ABI.** Une fonction exportée dont la production peut échouer doit déclarer une couleur
qui **contient** la valeur d'échec — l'algèbre le fait déjà, un ensemble contient ses cas. Un
canal hors-bande (`errno`, code de retour + `out`) est une décision de langage, pas d'ABI, et
elle est **différable** si les premiers exports sont des fonctions totales.

## 11.7 La distinction à ne jamais perdre

- **Bibliothèque Syntact pour Syntact** : un dossier de `.syn`, aucun artifact, aucun format
  de paquet, aucune IR sérialisée, aucun fichier d'interface, aucune surface de compatibilité
  ABI. Publier = livrer le dossier (`16-external-boundary.md`, `targets.md` §6.2).
- **Bundle pour le monde externe** : un artifact, avec une ABI et des symboles exportés.

Le cache de réduction adressé par contenu (§12) **n'est pas un artifact** : interne,
régénérable, local, jamais livré, jamais une dépendance.

---

# 12. Architecture du hot reload

## 12.1 Substrat réel, avant toute conception

| Hypothèse de `targets.md` §10 | Réalité |
|---|---|
| « unité de reload = un binding dans un scope » | **Un binding n'a aucune représentation dans le bytecode** : tout est aplati en un DAG avec CSE (`bytecode.odin:145-161`, `:169`). Il n'y a rien à remplacer. |
| « pousser la plage de bytecode changée » | Une plage n'est pas stable (C9). |
| « cache de réduction adressé par contenu, par binding » | Cache **par chemin**, granularité **fichier**, sur l'**analyse**, **désactivé** (§1.5). |
| « la VM résidente tient un `BC_Program`, écoute une socket, accepte un patch » | `interp_bytecode` est one-shot, sans socket, sans patch (`interp.odin:30`). |
| « l'interpréteur est le tier debug sur les cinq plateformes » | Il **refuse tout appel externe** (`interp.odin:56-68`) — donc il ne peut pas exécuter un programme graphique (C8). |
| « frames actives » | **Il n'y a pas de frames** : pile de `pc` unique, sans appel (`interp.odin:45-121`). |
| identité stable d'un binding | Aucune. `dag_key` retombe sur `@%p`, `fixedpoint_id` est un compteur par passe, `Reducer` est recréé à chaque `reduce()` (§1.5). |

Conclusion : le hot reload **n'a aujourd'hui aucun substrat**, et les deux manques dominants
sont les **fonctions dans le bytecode** et le **FFI dans l'interpréteur** — soit exactement les
deux manques qui bloquent aussi les exports, les callbacks, le mode mixte et l'oracle.

## 12.2 Identité — deux notions, pas une

Correction de C7.

| Notion | Définition | Sert à |
|---|---|---|
| **Identité** | le **chemin qualifié du binding** : `fichier :: scope.scope.nom`, avec un **ordinal** pour les bindings anonymes | savoir *lequel* remplacer ; ce qui traverse un patch |
| **Détecteur de changement** | `hash(texte source du binding, hashes des formes réduites de ses dépendances)` — la formule de `targets.md` §10 | savoir *s'il* a changé |

Un binding renommé a le même hash et une identité **différente** : c'est un binding nouveau, et
l'ancien disparaît — comportement correct. Un binding édité garde son identité et change de
hash : c'est un patch. Confondre les deux, comme le fait `targets.md` §10, donne les deux
mauvaises réponses.

Travail nécessaire : (a) construire le chemin qualifié — les noms et les ordinaux existent déjà
dans l'analyseur (`prop_ordinal`, `analyze.odin:1243`) ; (b) écrire un **vrai** hash de
contenu, **fonction distincte de `dag_key`** — `dag_key` est une clé de CSE avec
canonicalisation commutative (`reduce.odin:1050-1052`) et ne doit pas être détournée.

## 12.3 Granularité et mécanique du patch

L'unité de patch est un **`BC_Func` entier**, indexé par identité. Jamais une plage d'octets.

```
identité (string)  →  Body_Slot { generation: int, body: ^BC_Func | ^Native_Code }
```

La VM tient cette table. **Un appel passe par la table** — c'est ce qui fait que « le prochain
appel voit la nouvelle définition » **sans patcher aucun code**. Un patch écrit des entrées de
table ; le code émis est immuable.

## 12.4 Fermetures

Une « fermeture » Syntact est un **carve** d'un scope : une valeur composée de
`(identité de fonction, bindings carvés)`. Donc :

- un reload remplace le **corps** ; les bindings carvés survivent ;
- si la **forme** du carve a changé (binding ajouté, retiré, recoloré), la valeur de fermeture
  est invalide ⇒ réinitialisation. C'est **la même règle de forme** que l'état (§13), ce qui
  est la cohérence recherchée.

## 12.5 Frames actives

Règle : **les corps sont immuables et versionnés ; une frame épingle la version qu'elle
exécute.**

| Situation de la frame | Comportement |
|---|---|
| corps **inchangé** | rien |
| corps **changé** | la frame **termine dans l'ancien corps** (épinglé, compté par référence) ; les appels **suivants** prennent le nouveau |
| **bloquée dans un appel externe** | le patch s'applique à la table ; au retour, la frame continue dans son ancien corps épinglé |
| **signature ABI** changée alors qu'elle est enregistrée côté C | **patch refusé** pour cette identité ⇒ « restart requis » (§13) |

C'est la version *précise* de « swap the bindings ; the next iteration re-reads them »
(`targets.md` §10) : ce qui rend l'énoncé vrai est le versionnement des corps, sans lequel une
frame reprend à un `pc` qui n'a plus de sens.

## 12.6 Quand une production doit être réexécutée

Une seule règle, valable pour les trois états de programme :

> Une production est ré-effondrée si et seulement si son hash de contenu a changé, ou celui
> d'une dépendance, **et** que son résultat est **observé** après le patch.

| État du programme | Ce que « observé » signifie |
|---|---|
| **terminé** (CLI, test) | la production racine ⇒ **ré-exécution incrémentale**, quasi instantanée car tout l'inchangé est en cache. C'est la réponse honnête pour un programme batch, et c'est déjà toute la boucle de retour |
| **dans une boucle** (serveur, jeu, pompe d'événements) | la prochaine itération observe ⇒ rien à notifier |
| **bloqué sur un syscall** | l'observation a lieu au retour de l'appel |

Aucune participation de framework — c'est ce qui fait fonctionner le reload sans GUI, et c'est
le point où `targets.md` §10 a raison contre Flutter.

## 12.7 Interruption, rollback, versions

- **Points d'interruption déterministes** : la VM ne teste un drapeau d'interruption qu'aux
  **arêtes arrière** et aux **frontières d'appel externe**. Jamais au milieu d'une
  instruction. C'est aussi ce qui rend l'état de la file d'événements connu au moment du patch.
- **Rollback** : un patch est une **transaction** sur la table. Valider tous les corps (compteurs
  de valeurs/labels, imports résolubles, signatures des identités enregistrées) **avant**
  l'échange ; à la moindre erreur, jeter le lot et conserver la table précédente. Les corps
  étant immuables, le rollback est un échange de table.
- **Protocole** : le handshake porte `{version de protocole, triple de cible, version du format
  BC, identifiant de build du compilateur}`. Toute discordance ⇒ refus + demande de
  redéploiement de la VM. C'est bon marché et cela élimine la pire classe de bug.

---

# 13. État et sémantique du reload

## 13.1 Le contexte, favorable

**Il n'existe aucun état mutable aujourd'hui** : `ir.odin:38-43` — « only the pointing pair is
reduced today (events/resonance/reactivity are recorded, not yet reduced) ». Donc la règle se
décide **sans dette**, et — conclusion utile — **le hot reload du code peut être livré avant
toute préservation d'état**, puisqu'il n'y a rien à préserver. C'est plus tôt qu'on ne le
croirait.

## 13.2 Comparaison des cinq stratégies

| # | Stratégie | Verdict |
|---|---|---|
| 1 | recréer tout l'état | **Rejetée** : recréerait fenêtre, instance, device, swapchain à chaque édition — précisément ce que le hot reload doit éviter |
| 2 | préserver automatiquement les valeurs compatibles | **Correcte si et seulement si** « compatible » est défini par l'algèbre (« la valeur appartient-elle au nouvel ensemble ? ») et non par une heuristique |
| 3 | préserver ce qui a une identité explicite | **Correcte**, et c'est déjà le cas : la résonance *est* l'identité explicite |
| 4 | rejouer productions / événements | **Rejetée par défaut** : rejouer un effet le **refait** (double création de fenêtre). Pour une production **pure**, rejouer *est* ré-effondrer, et c'est gratuit — donc ce n'est pas une stratégie distincte |
| 5 | handler de migration | **Échappatoire, plus tard.** Ne doit pas être nécessaire dans le cas courant |

## 13.3 La règle recommandée

> **L'état n'existe que dans les bindings résonants** (`17-resonance-and-reactivity.md`). Un
> binding résonant est **préservé** à travers un reload si et seulement si
> **(a)** son **identité** (chemin qualifié, §12.2) est inchangée, **et**
> **(b)** sa **valeur appartient à sa couleur actuelle**.
> Sinon il est **réinitialisé** depuis sa production.

C'est la version disciplinée de 2 + 3. Ses propriétés :

- **Déterministe** : aucune heuristique, aucune inférence par position source (ce que la
  demande §12 interdit explicitement).
- **Énoncée dans les termes du langage** : « appartient à l'ensemble » est l'opération que
  l'algèbre fournit déjà. Élargir une contrainte préserve la valeur ; la resserrer la préserve
  si elle satisfait encore, sinon réinitialise. **Aucune politique à écrire** — la question est
  répondue par le langage.
- **Plus étroite et mieux définie que l'identité de widget de Flutter**, parce que la résonance
  est le seul endroit où la mutation existe : c'est le seul endroit qu'un reload peut perturber.

## 13.4 Application aux ressources concrètes

| Ressource | Comportement sous la règle |
|---|---|
| handle GLFW (fenêtre) | `u64` dans un binding résonant, couleur inchangée ⇒ **préservé**. La fenêtre n'est pas recréée. **C'est le résultat voulu.** |
| instance / device / swapchain Vulkan | idem ⇒ préservés |
| allocations, fichiers, sockets | idem, tant que le handle est résonant |
| état GPU (pipelines, buffers) | préservé via les handles |
| handlers d'effets | préservés si la **forme** du scope du handler est inchangée ; réinitialisés sinon |
| événements / résonances en attente | **drainés** avant l'application du patch (le point d'interruption est l'arête arrière, §12.7) |
| callbacks enregistrés | ne sont **pas** de l'état : voir §14, ils passent par la table d'indirection |

## 13.5 La limite à énoncer, plutôt qu'à masquer

Le corollaire de « préserver » est : **le code qui *crée* la ressource n'est pas ré-exécuté.**
Modifier les paramètres de création de la swapchain **ne prend pas effet** au reload. Deux
réponses, dans l'ordre :

1. exposer `R` (restart) dans la boucle du SDK — c'est le cas d'usage exact (`sdk.md` §8) ;
2. plus tard, permettre à un binding résonant de déclarer qu'il **possède** une ressource
   externe, de sorte qu'un changement de forme de son **créateur** l'invalide. **Ne pas
   construire ceci maintenant** ; énoncer la limite dès le premier jour.

C'est le point où promettre plus serait malhonnête : aucune règle générale ne peut savoir qu'un
`u64` est une swapchain.

---

# 14. Hot reload et interop native

## 14.1 Le problème

Du code C peut conserver : un pointeur de callback, un pointeur vers une structure, un
user-data, un handle associé à l'ancien code, l'adresse d'une fonction exportée. **Aucune de
ces adresses ne doit changer au reload.**

## 14.2 La mécanique : trampolines à cible remplaçable

**Recommandation, et c'est le seul mécanisme qui satisfait la contrainte :** une **table
d'indirection résidente**, une entrée par identité exportée ou enregistrée. L'adresse remise à
C est celle du **trampoline**, jamais celle d'un corps.

```
x64   : jmp *TABLE+8*i(%rip)
arm64 : ldr x16, [TABLE + 8*i] ; br x16
```

Propriétés, chacune décisive :

- **Le patch est une écriture de donnée, jamais de code.** Aucun problème d'icache, aucune
  discipline W^X, aucune page à remapper.
- **Un slot est un `u64` aligné** ⇒ son écriture est atomique : un callback en vol voit
  l'ancien **ou** le nouveau corps, jamais une valeur déchirée.
- **La réenregistrement devient inutile**, ce qui est précisément l'argument contre le
  réenregistrement automatique (§14.3).
- La table est de la **donnée dans `.data`** — donc elle a besoin de M4 (§4.5). Le mécanisme
  « adresse fixe dans un segment inscriptible » existe déjà (`ARGS_TABLE`, `elf.odin:57-60`,
  écrit réellement en `emit.odin:189`) : c'est une extension, pas une capacité nouvelle
  (`vulkan-slice.md` §1.5 A).

Un patch **multi-slots** n'est pas atomique dans son ensemble. Deux niveaux :

1. **Jalon 1 — mono-thread.** Appliquer les patches uniquement aux points quiescents (§12.7),
   et **refuser** les appels entrants venus d'un thread non-VM. Se tromper ici est une
   corruption mémoire silencieuse ; commencer restreint est la bonne décision.
2. **Ensuite.** Un compteur de génération : le trampoline capture la génération **une fois** à
   l'entrée et utilise le jeu de corps épinglé pour tout l'appel (seqlock côté lecture). C'est
   le seul endroit du design où une synchronisation entre thread natif et VM est réellement
   requise, et il faut le dire.

## 14.3 Ce qui ne peut pas être rechargé

| Cas | Règle | Raison |
|---|---|---|
| **signature ABI changée** d'un callback enregistré | **patch refusé** pour cette identité ⇒ « restart requis » | le type du pointeur de fonction côté C est figé à l'enregistrement ; aucun mécanisme ne peut le corriger |
| **callbacks d'allocation** (`VkAllocationCallbacks`) | **identités non rechargeables** | ils sont appelés aussi pendant `vkDestroy*` ; un `free` doit apparier le `malloc` qui l'a produit. Une seule dérogation explicite, justifiée par l'appariement, pas par la commodité |
| réenregistrement automatique | **à ne pas faire** | certaines API accumulent les enregistrements ; recréer un `VkDebugUtilsMessenger` fuit une ressource. Avec les trampolines c'est inutile |

## 14.4 GLFW et Vulkan, concrètement

| Élément | Traitement |
|---|---|
| `glfwSetKeyCallback`, `glfwSetWindowSizeCallback`, … | le pointeur remis est un **trampoline** ⇒ le reload échange le corps, **rien n'est réenregistré** ✔ |
| debug callback Vulkan (`pfnUserCallback`) | trampoline ✔. Son `pUserData` pointe une valeur Syntact : elle doit vivre dans l'**arène stable**, pas dans une allocation à durée de reload |
| callbacks d'allocation Vulkan | **non rechargeables** (§14.3) |
| pointeurs de `vkGetInstanceProcAddr` | **sortants** (adresses C que *nous* détenons) : handles dans des bindings résonants ⇒ **préservés** par la règle d'état. `vulkan-slice.md` note que tous les symboles nécessaires sont exportés par `libvulkan.so.1`, donc ce cas est **évitable** au début |
| objets Vulkan traversant un reload (instance, device, swapchain, pipelines) | handles résonants ⇒ préservés. **Mais** un pipeline construit depuis du code de shader modifié est **périmé** : même limite qu'en §13.5, à énoncer |

---

# 15. Hot reload graphique et mode mixte

## 15.1 Le problème est réel

`targets.md` §11 le pose correctement : le debug interprète, or un renderer Syntact à 60 Hz
passerait par l'interpréteur. Flutter n'a pas ce problème parce que son moteur est du C++ AOT.

## 15.2 Verdict et décision à prendre maintenant

**Le mode mixte n'est pas nécessaire au premier prototype. Mais la frontière doit être choisie
maintenant, parce qu'elle doit coïncider avec l'unité de reload** (`targets.md` §11 le dit, et
c'est juste).

**Décision recommandée : la frontière est un ensemble d'identités de `BC_Func`.** Un corps est
soit du bytecode, soit du code natif ; c'est la **même** table `identité → corps` (§12.3), avec
une variante de plus dans le slot.

| Question | Réponse |
|---|---|
| unité AOT | une identité de `BC_Func` |
| unité interprétée | une identité de `BC_Func` |
| échange de valeurs, effets, callbacks | par la table, via l'**ABI interne** de la VM |
| ABI C ou ABI interne à la frontière ? | **interne.** L'ABI C forcerait à représenter les valeurs Syntact en formes C à une frontière qui est *interne*, et interdirait de passer un scope. L'ABI C est réservée à la frontière **externe** réelle et aux symboles exportés |
| préserver l'état GPU | acquis par la règle d'état (§13) : les handles sont résonants |
| éviter de recréer fenêtre / instance / device / swapchain | même acquis |
| recompiler le renderer quand il change | ses identités passent de l'ensemble AOT à l'ensemble interprété (ou déclenchent une reconstruction AOT limitée à ces identités) |
| nécessaire immédiatement ? | **non** — après le premier prototype |

## 15.3 La conclusion architecturale majeure

**Une seule mécanique sert quatre besoins que les specs traitent séparément :**

```
table  identité → corps  (+ trampolines)
   ├── hot reload            remplacer un corps
   ├── callbacks entrants    l'adresse remise à C est stable
   ├── symboles exportés     un export EST une entrée de table, appelée depuis C
   └── mode mixte            un corps est du bytecode OU du natif
```

C'est ce qui justifie que **`BC_Func` soit le jalon pivot** : il n'y a pas quatre chantiers, il
y en a un, et trois retombées.

## 15.4 Comparaison à Flutter, sans copier

| | Flutter | Syntact |
|---|---|---|
| frontière | **de langage** (moteur C++ / app Dart), fixée à la construction du moteur | **ensemble d'identités**, dynamique |
| unité de reload | classe / bibliothèque Dart, plus `reassemble()` du framework | binding, sans participation de framework |
| reload sans UI | quasi inutile (rien ne réinvoque le code) | fonctionne : one-shot, serveur, jeu, GUI — parce que « exécuter, c'est effondrer le file-scope » |
| ce qui le rend possible | — | la réduction rend le résiduel explicite et le suivi de dépendances exact |

La frontière dynamique n'est possible **que** parce que la réduction fait partie de la
sémantique. C'est le point où Syntact peut faire mieux, et non seulement différemment.

---

# 16. Le Syn SDK

## 16.1 État

**[LECTURE]** Deux binaires (`compiler.bin`, `lsp.bin`), et `main.odin` **est** l'interface :
`Options` (`main.odin:11-28`) n'a ni target, ni artifact, ni profile, ni device. Le LSP est en
**full sync** (`lsp/lsp.odin:442`), ne fait que parse + analyze (`:600`), **jamais reduce** —
donc le partage de cache avec le reload (`sdk.md` §9) est entièrement à construire.

## 16.2 Responsabilités

Conformes à `sdk.md`, avec trois corrections :

- `Transport` gagne **`Qemu`** (C5) : `push` = copie locale, `spawn` = `qemu-aarch64 [-L …]`,
  `forward` = socket locale, `logs` = pipe. QEMU est un transport, pas un détail de test.
- Le **`--target` implique un runner** dans `test` autant que dans `run` : un seul mécanisme.
- `doctor` doit signaler `qemu-user` et le sysroot arm64 comme manquants (**[VÉRIFIÉ]** ils le
  sont sur cette machine).

## 16.3 La boucle `run --target <t>`

```
résoudre la racine (sdk.md §3 : le fichier donné, sinon main.syn, sinon lib/main.syn)
  → sélectionner (target, Executable, debug)
  → s'assurer qu'une VM native existe pour la cible          ← §16.4
  → compiler vers BC_Program
  → transport.push(vm, bytecode) ; spawn ; forward(port)
  → handshake {protocole, triple, format BC, build du compilateur}
  → observer l'arbre source
       au changement : ré-réduire les bindings dont le hash a bougé (§12.2)
                       envoyer un patch transactionnel de corps (§12.3, §12.7)
  → streamer stdout/stderr/logs ; 'r' reload, 'R' restart, 'q' quit
```

`R` (restart) n'est pas un confort : c'est la réponse à la limite de §13.5.

## 16.4 Comment un device obtient sa VM — réponse à court terme

`sdk.md` §12 laisse la question ouverte entre VM préconstruites et cross-compilation Odin.
**Réponse à court terme : la question ne se pose pas encore, et il faut le dire.**

| Situation | VM nécessaire |
|---|---|
| différentiel Linux arm64 sous QEMU | **aucune** : l'interpréteur tourne sur l'hôte, le natif arm64 sous QEMU. La VM n'est pas dans la boucle |
| `run` sur hôte Linux / Windows / macOS | la VM **est** le binaire hôte — rien à distribuer |
| `run` sur device Android / iOS | là seulement la question se pose |

Donc : **différer entièrement la décision jusqu'après Android** (rang 3 de §10.1, qui est un
`build`, pas un `run`). Coût de ce report : nul.

## 16.5 Protocole minimal

| Message | Charge |
|---|---|
| `HELLO` / `HELLO_ACK` | version de protocole, triple de cible, version du format BC, build du compilateur ; refus explicite sur discordance |
| `LOAD` | `BC_Program` initial + table des identités |
| `PATCH` | lot `{identité, corps}` + numéro de lot ; **transactionnel** |
| `PATCH_OK` / `PATCH_REJECT` | en cas de rejet : identité fautive + raison (signature figée, corps invalide, identité non rechargeable) |
| `PAUSE` / `RESUME` | s'arrête au prochain point d'interruption (§12.7) |
| `RESTART` | ré-effondre depuis la racine, en jetant l'état |
| `LOG` | flux stdout / stderr / diagnostics |
| `STATE` | terminé / en boucle / bloqué en externe / en pause |
| `BYE` | fermeture ordonnée |

---

# 17. Backends futurs — non-régression

C, JS et wasm sont différés (`targets.md` §1). Vérification que les décisions ci-dessus ne les
rendent pas artificiellement impossibles :

| Sujet | Verdict |
|---|---|
| bytecode comme point central | **préservé et renforcé** : `bytecode/` n'importe rien (`bytecode.odin:1-18`), et `BC_Func` rapproche du modèle de wasm et de JS, qui ont tous deux des fonctions |
| **contrôle structuré** | **le point à ne pas rater.** `BC_Jump`/`BC_Branch_Zero` forment un CFG non structuré ⇒ wasm et JS ont besoin d'un relooper. `targets.md` §12 note qu'il est presque gratuit tant que les branches sont avant-seulement, et coûteux ensuite. **Action concrète** : lors du jalon récursion terminale → arête arrière (`vulkan-slice.md` J7), émettre `Loop_Info{header, latch, exits}` dans `BC_Func` (§4.2). Coût nul aujourd'hui, non rétrofitable |
| boucles et arêtes arrière | idem |
| appels externes | `BC_Import` (lib, symbole) se projette directement sur les imports wasm |
| effets | inchangés : la provenance est la marque, indépendamment du backend |
| représentation des exports | ensemble de propriétés ⇒ exports wasm et exports de module JS, sans traduction |
| **table d'indirection** | **risque à éviter** : ne pas définir la table en termes d'**adresses machine**. La garder comme `identité → index de corps`, de sorte que `call_indirect` + table de fonctions (wasm) et une répartition par objet (JS) puissent la réaliser |
| natif vs non natif | ne pas replier « produit des octets pour un chargeur d'OS » et « produit un fichier texte » dans la même énumération. `Image` reste natif ; un axe `Emitter` viendra plus tard. Ne rien faire maintenant, mais ne pas rendre `Image` obligatoire d'une façon qui l'interdise |

Un backend C ajouterait un **troisième oracle** différentiel, seule chose qui relâcherait
l'exigence d'audit de l'interpréteur (`targets.md` §12).

---

# 18. Plan d'implémentation

Ordre gouverné par deux règles : **valider la séparation architecturale sur l'existant
d'abord**, puis **une seule variable nouvelle à la fois**.

`vulkan-slice.md` J1–J13 couvre la frontière interop. Les jalons ci-dessous **adoptent** J1, J2,
J5, J7 comme prérequis nommés au lieu de les redéfinir.

---

### M0 — Appel externe conforme à l'ABI · adopte `vulkan-slice.md` J1 + J2

- **Résultat observable** : `sqrt{16}! + pow{2,3}!` rend `12.0` (aujourd'hui
  `6755399441056136.0`, F3) ; `RSP ≡ 0 (mod 16)` à l'appel même avec des spills.
- **Prérequis** : aucun.
- **Fichiers** : `backends/x64/regalloc.odin` (notion de clobber), `backends/x64/emit.odin`
  (`emit_foreign_call`, `emit_prologue`).
- **Structures** : ensemble caller-saved dans l'allocateur ; extension d'intervalle ou
  sauvegarde/restauration autour de `BC_Foreign_Call`.
- **Tests** : cas `extern` multi-appels avec valeur vivante à travers l'appel ; assertion
  d'alignement.
- **Débloque** : tout le reste de l'interop, le record `Abi`, les callbacks, les exports.
- **Critère de fin** : F3 non reproductible ; corriger aussi le commentaire faux de
  `regalloc.odin:41-51` (F4).

---

### M1 — `Target × Artifact × Profile`, sans changement de comportement

- **Résultat observable** : `--target linux-x64 --artifact Executable --profile release`
  accepté ; toute autre valeur **refusée avec un message nommant les cibles connues** ; la
  sortie est **identique octet pour octet** à celle d'aujourd'hui.
- **Prérequis** : aucun (peut se faire en parallèle de M0).
- **Fichiers** : `backends/target.odin` (nouveau), `backends/platform/linux.odin` (nouveau),
  `backends/abi/sysv_x64.odin` (nouveau), `main.odin`, `resolve.odin:434-490`.
- **Structures** : `Target`, `Arch`, `Os`, `Image`, `Artifact`, `Profile`, `Platform`, `Abi`,
  `entry_model`, `result_model` (§3).
- **Tests** : `test/codegen` inchangé ; un test comparant les octets produits à un binaire de
  référence.
- **Débloque** : la dispatch par cible ; `@platform` (dont c'est la source de vérité).
- **Critère de fin** : `compiler` **n'importe plus** `backends/x64` (`resolve.odin:2`) ; la
  dispatch passe par `target.odin`.

---

### M2 — Découpage des couches, x64 seul

- **Résultat observable** : sortie identique octet pour octet ; `image/elf` compile sans
  importer de package `isa/*` et réciproquement.
- **Prérequis** : M1.
- **Fichiers** : `x64/elf.odin` + `elf_dynamic.odin` → `backends/image/elf/` ;
  `x64/regalloc.odin` + `regalloc_dump.odin` → `backends/isa/common/` ; nouveau pilote de
  codegen dans `backends/`.
- **Structures** : `Phys_Reg :: distinct u8`, `Reg_Class`, `Reg_File` (§5.1) ;
  `VReg_Loc.reg` retypé ; `phys_pref` piloté par `Abi`.
- **Tests** : **un test d'audit d'imports** qui lit les en-têtes et échoue sur toute arête
  interdite (§2.2). C'est ce test qui transforme les invariants de `targets.md` §7 en propriété
  vérifiée.
- **Débloque** : arm64 ; tous les writers d'image.
- **Critère de fin** : le tableau d'imports de §2.2 est vert, et la sortie est inchangée.

---

### M3 — `Code_Object`, relocations, PIE statique

- **Résultat observable** : `readelf -h` donne `ET_DYN` ; le binaire s'exécute ;
  `readelf -r` donne une table de relocations **vide** pour un programme pur ; les programmes
  `<lib>` continuent de fonctionner.
- **Prérequis** : M2.
- **Fichiers** : `isa/common/codeobj.odin` (nouveau), `isa/x64/emit.odin`, `image/elf/*`.
- **Structures** : `Code_Object`, `Section`, `Sym`, `Reloc`, `Reloc_Kind`, `Export`,
  `Line_Map`, `Binding_Range`, `Frame_Info` (§4.3).
- **Tests** : les cas existants ; un test asserant qu'aucun `movabs` d'adresse d'image ne
  subsiste — **imposé structurellement** en supprimant `ELF_BASE`, `ARGS_TABLE_VADDR`,
  `GOT_VADDR` du package ISA plutôt qu'en grep-ant la sortie.
- **Débloque** : PIE, Android, `.so`, Mach-O, PE, objets.
- **Critère de fin** : les cinq sites de §1.3 ont disparu ; invariant 4 de `targets.md` §7
  tenu.

---

### M4 — Segments RX/RW séparés, `.data` et `.bss` réels

- **Résultat observable** : deux `PT_LOAD` (RX, RW) ; `readelf -l` le montre ; plus de RWX ;
  `__syn_args` et `__syn_got` sont des symboles.
- **Prérequis** : M3.
- **Fichiers** : `image/elf/*`, `platform/*` (`Platform.segments`).
- **Structures** : layout de sections ; alignement du second segment — **c'est le vrai coût**,
  la contrainte que `elf.odin:68-70` évitait.
- **Tests** : suite existante ; vérification des drapeaux de segment.
- **Débloque** : Android (SELinux), l'arène de scratch, la **table d'indirection** (§14.2).
- **Critère de fin** : aucun segment RWX ; `memsz` ne joue plus le rôle de `.bss` implicite.

---

### M5 — `BC_Func`, `BC_Call`, `Loop_Info` — **jalon pivot**

- **Résultat observable** : `--bc` affiche des fonctions nommées ; un programme avec appel de
  fonction Syntact donne le même résultat sur interp et x64 ; la récursion terminale s'abaisse
  en arête arrière (adopte `vulkan-slice.md` J7).
- **Prérequis** : M0 (appel conforme), M3.
- **Fichiers** : `bytecode/bytecode.odin`, `bytecode/interp.odin` (pile de frames),
  `compiler/bytecode.odin` (lowering par binding au lieu d'un DAG unique),
  `isa/common/regalloc.odin` (liveness sur arêtes arrière), `isa/x64/emit.odin`.
- **Structures** : `BC_Func`, `BC_Call`, `Func_Id`, `Loop_Info`, frame d'interpréteur ;
  `Code_Object.bindings` rempli.
- **Tests** : différentiels par fonction ; boucle terminale ; **profondeur de récursion** ;
  correction de la liveness sur arête arrière (`regalloc.odin:14-19` dit précisément où).
- **Débloque** : exports, callbacks, granularité de reload, mode mixte, wasm/JS (via
  `Loop_Info`).
- **Critère de fin** : `codegen: recursion … does not lower yet` (`bytecode.odin:229-235`)
  disparaît ; l'unité de reload existe dans le bytecode.

---

### M6 — Record `Abi` et frontière piloté par données

- **Résultat observable** : `emit_foreign_call` et les stubs d'entrée/sortie ne contiennent
  plus de liste de registres littérale ; plus de 6 arguments fonctionne (args sur la pile).
- **Prérequis** : M0, M2.
- **Fichiers** : `abi/*`, `isa/x64/emit.odin`.
- **Structures** : `Abi` (`abi.md` §2.3) ; `Abi.classify(type) -> []Arg_Location`, SysV
  d'abord.
- **Tests** : les neuf bibliothèques d'`interop.md` §1 rejouées ; un cas à 8 arguments ; un cas
  variadique.
- **Débloque** : Win64, AAPCS64, agrégats, `sret`, callbacks.
- **Critère de fin** : le plafond de 6 args (`emit.odin:717-720`) n'existe plus.

---

### M7a — Harnais différentiel multi-runner, validé sur x64

- **Résultat observable** : le harnais tourne avec un préfixe vide et donne exactement les
  mêmes résultats ; stderr capturé et comparé ; les cas `<lib>` **marqués** comme sans oracle.
- **Prérequis** : aucun.
- **Fichiers** : `test/codegen/codegen.odin`, `test/codegen/tests/*.json`.
- **Structures** : `Runner{target, prefix, needs_sysroot}` ; `kind: "extern"`.
- **Tests** : lui-même ; plus un cas de **trap** documentant la divergence existante (F5), à
  trancher avant arm64.
- **Débloque** : arm64 et toute cible croisée.
- **Critère de fin** : stderr comparé ; le rapport distingue « conforme à l'oracle » de « deux
  implémentations d'accord ».

---

### M7b — Backend arm64, Linux ELF

- **Résultat observable** : `--target linux-arm64` produit un ELF **statique** qui s'exécute
  sous `qemu-aarch64` sans `-L`, et s'accorde avec l'interpréteur sur toute la suite.
- **Prérequis** : M2, M3, M4, M5, M7a. `qemu-user` installé.
- **Fichiers** : `isa/arm64/` (à écrire à neuf — §1.4 : rien n'est réutilisable), `image/elf`
  (constantes : `EM_AARCH64` = 183, `p_align` = `0x10000`, loader
  `/lib/ld-linux-aarch64.so.1`, `svc #0`/`x8`, write=64/exit=93).
- **Structures** : `Reg_File` arm64 ; isel arm64 ; encodeur 32 bits ; matérialisation
  `movz`/`movk` ou pool littéral ; `adrp`+`add` / `adrp`+`ldr` **avec la bonne reloc de taille**
  (§4.4) ; **veneers** pour `b.cond` ±1 Mo.
- **Tests** : suite d'encodage arm64 (équivalent de `x64_test.odin`) ; différentiel 3 voies ;
  un cas franchissant délibérément ±1 Mo pour éprouver les veneers.
- **Débloque** : Android, macOS arm64, iOS. **Valide la séparation des couches par un second
  consommateur.**
- **Critère de fin** : différentiel 3 voies vert ; `image/elf` a gagné des constantes, pas de
  branches d'ISA.

---

### M8 — `@platform` et projection à travers `Pattern_Type`

- **Résultat observable** : `@platform.os ? { linux -> …, -> … }` réduit ;
  `lib -> @platform.os ? { linux -> <libm.so.6>{…}, … }` puis `lib.sqrt{…}!` **fonctionne** ;
  une branche à production vide sur la plateforme courante est une **erreur de compilation
  nommant le fichier, la ligne et la branche**.
- **Prérequis** : M1 (source de vérité). Décisions D-5, D-6, D-7 (§19).
- **Fichiers** : `parse.odin` (jeu de namespaces racine), `analyze.odin:1189-1216`
  (cas `Pattern_Type`), `bytecode.odin:193-196` (`None` requis ⇒ diagnostic),
  `backends/target.odin` (projection).
- **Structures** : injection littérale de `@platform` ; cas `Pattern_Type` dans
  `resolve_property_site`, variante **(a)** (§7.6).
- **Tests** : les cinq formes de §7.4 ; les quatre classes de portabilité de §8.3 ; un test
  échouant si un champ de `Platform` n'est ni projeté ni marqué backend-only (C10).
- **Débloque** : interop portable, sélection par architecture, rejet de plateforme, base de
  l'ASM par ISA.
- **Critère de fin** : F1 non reproductible pour un scrutateur littéral ;
  `@platform.os` résout.

---

### M9 — Android arm64, exécutable via `adb`

- **Résultat observable** : `syntact build --target android-arm64`, `adb push`, `chmod +x`,
  exécution sur device ; statut de sortie correct.
- **Prérequis** : M4 (RX/RW), M7b (arm64). `adb` + un device autorisé.
- **Fichiers** : `platform/android.odin` (**données uniquement**), `image/elf` (aucune
  branche nouvelle attendue — c'est le test).
- **Structures** : `Platform{pie=Required, loader="/system/bin/linker64",
  lib_ref=Unversioned_Soname, page_align=0x10000, segments=Split_Rx_Rw}`.
- **Tests** : différentiel via un transport `Adb` ; vérifier qu'un `<libm.so.6>` est **rejeté**
  et qu'un `<libm.so>` fonctionne.
- **Débloque** : plus tard JNI, APK, `App_Package`.
- **Critère de fin** : **aucune branche `if android` nulle part** — la seule différence est le
  record. C'est la preuve de « la plateforme est une donnée ».

---

### M10 — Exports et artifacts `Object` / `Static_Library` / `Shared_Library` (ELF)

- **Résultat observable** : `syntact bundle --artifact Shared_Library` produit un `.so` qu'un
  programme C peut lier et appeler ; `nm -D` montre exactement les propriétés de la production
  du file-scope ; `--artifact Object` produit un `.o` que `gcc` accepte.
- **Prérequis** : M5 (fonctions), M6 (`Abi`), M3 (relocations). Décisions D-4, D-8 (§19).
- **Fichiers** : `image/elf` (`Global_Def` dans `.dynsym`, relocations en sections),
  `package/staticlib` (writer `ar`), `backends/` (stubs d'entrée ABI, `sret`, callee-saved).
- **Structures** : `Abi_Signature`, `Export` ; prologue ABI réel ; `Code_Object.frames`.
- **Tests** : un programme C compilé par `gcc` qui lie le `.so` et appelle chaque export ;
  un cas de générique non carvé **rejeté** ; un cas de binding non coloré **rejeté**.
- **Débloque** : `bundle` ; **et les callbacks, qui sont la même capacité** (§11.5).
- **Critère de fin** : `nm -D` = l'ensemble de propriétés, ni plus ni moins.

---

### M11 — VM résidente : FFI, socket, table d'indirection, protocole

- **Résultat observable** : `--run` exécute un programme `<lib>` (aujourd'hui refusé,
  `interp.odin:56-68`) ; une VM résidente accepte `LOAD`, `PATCH`, `PAUSE`, `RESTART`,
  `PATCH_REJECT` avec rollback.
- **Prérequis** : M5 (fonctions et frames), M4 (`.data` pour la table), M10 (fonctions ABI
  pour les callbacks entrants). Décision D-9.
- **Fichiers** : `bytecode/interp.odin` (FFI par `dlopen`/`dlsym`, pile de frames, points
  d'interruption), `reload/session.odin` (nouveau), `sdk/session/`.
- **Structures** : `Body_Slot{generation, body}` ; table de trampolines ; transaction de patch ;
  messages du protocole (§16.5).
- **Tests** : différentiel `<lib>` interp ↔ natif — **ce jalon ferme la cécité de l'oracle
  (C8)** ; patch d'un corps pendant une boucle ; rejet + rollback ; discordance de handshake.
- **Débloque** : profil debug utilisable, hot reload, mode mixte, callbacks survivant au reload.
- **Critère de fin** : le harnais compare interp ↔ natif sur un programme `<lib>` ; **F3 serait
  détecté automatiquement** s'il réapparaissait.
- **Restriction assumée** : mono-thread ; les appels entrants d'un thread non-VM sont refusés
  (§14.2).

---

### M12 — Identité de binding, hash de contenu, réduction incrémentale

- **Résultat observable** : éditer un binding ne re-réduit que lui et ses dépendants ;
  `run` applique un patch en un temps indépendant de la taille du fichier ; le cache sur
  disque est **réactivé**.
- **Prérequis** : M11.
- **Fichiers** : `reload/identity.odin`, `reload/cache.odin` (nouveaux), `resolve.odin:35-46`
  et `:658-740` (clé par contenu, granularité binding), `main.odin:32-33` (retirer
  `no_cache = true`), `lsp/lsp.odin` (partage du cache).
- **Structures** : chemin qualifié de binding ; `content_hash` — **fonction distincte de
  `dag_key`** (§12.2).
- **Tests** : renommer un binding ⇒ identité nouvelle, ancienne retirée ; éditer un
  commentaire ⇒ hash inchangé ⇒ aucun patch ; éditer une dépendance ⇒ les dépendants
  re-réduits ; le cache donne le **même** résiduel que sans cache (invariant à tester à chaque
  cas).
- **Débloque** : hot reload réel ; vitesse du LSP ; vitesse de build à froid.
- **Critère de fin** : un cas de non-régression prouve `avec cache == sans cache` sur toute la
  suite.

---

### M13 — Windows x64 PE/COFF + ABI Win64

- **Résultat observable** : un `.exe` s'exécute sur Windows ; un `.dll` se lie ;
  `f(int,double,int)` passe par `RCX/XMM1/R8`.
- **Prérequis** : M3, M6. Runner Windows ou Wine.
- **Fichiers** : `image/pe/` (nouveau), `abi/win64.odin`, `platform/windows.odin`.
- **Structures** : Import Directory + IAT ; slots **positionnels** ; shadow space 32 octets ;
  pas de red zone ; `.reloc`.
- **Tests** : différentiel via un runner Windows ; un cas par divergence d'ABI de §8.4.
- **Débloque** : Windows. **Valide « aucun code d'arch dans les writers d'image ».**
- **Critère de fin** : `image/pe` n'importe aucun package `isa/*`.

---

### M14 — Mach-O : macOS x64, puis macOS arm64 + signature ad-hoc, puis iOS Sim, puis iOS device

Quatre sous-jalons, une seule variable chacun.

| | Nouveauté | Critère de fin |
|---|---|---|
| M14a | writer Mach-O, sur **x86-64 qui s'exécute non signé** | un `MH_EXECUTE` x64 s'exécute sur macOS ; question bind-classique-vs-fixups-chaînés (`abi.md` §3) **tranchée avant de commencer** |
| M14b | ABI Apple arm64 + **signature ad-hoc** (`core:crypto/sha2`) | un Mach-O arm64 s'exécute ; **un cas variadique valide la divergence pile** |
| M14c | `LC_BUILD_VERSION` = 7, cycle de vie du Simulateur | une sortie de forme iOS s'exécute **sans compte Apple** |
| M14d | certificat + profil de provisioning | installation sur device — **seul point où le principe « chaque octet est le nôtre » se rompt, et sur une politique Apple, pas sur de la technique** |

---

### M15 — Règle d'état et résonance

- **Résultat observable** : un binding résonant survit à un reload quand identité et
  appartenance de valeur sont préservées ; se réinitialise sinon ; un handle GLFW/Vulkan
  survit ; la limite de §13.5 est documentée et `R` fonctionne.
- **Prérequis** : **la résonance doit être réduite** — elle n'est aujourd'hui que *recordée*
  (`ir.odin:38-43`). C'est un chantier de langage indépendant de ce plan. Plus M12.
- **Critère de fin** : la règle de §13.3 est implémentée telle quelle, sans heuristique de
  position source.

---

# 19. Décisions bloquantes et éléments différables

## 19.1 Décisions de langage réellement bloquantes

| # | Décision | Bloque | Recommandation |
|---|---|---|---|
| **D-1** | **Loi de volatilité** de `<lib>`/`<asm>` : non repliable, non duplicable, non éliminable, **ordonné** | M6, M11, tout programme interop réel | Une seule loi pour les deux formes. Preuves qu'elle manque : `vulkan-slice.md` D3 (effacé sous un pattern) et §4.3 (ordre accidentel), plus F2 (provenance perdue) |
| **D-2** | **Ordonnancement des effets** | M6, M11 | Adopter `vulkan-slice.md` §4.3 — une liaison non-production dont la valeur porte un collapse externe s'évalue dans l'ordre de déclaration |
| **D-3** | **Jeu de namespaces racine** (`sdk.md` §3.2) | M8 | Le compilateur possède un petit jeu fixe (`@platform`), tout le reste retombe sur la résolution d'arbre actuelle |
| **D-4** | **Critère fonction / constante** à l'export : un scope **sans entrée** s'exporte-t-il en constante ou en fonction 0-aire ? | M10 | **Constante** (une entrée au moins pour être une fonction). **Diverge de l'exemple de la demande §10** — à confirmer |
| **D-5** | **Orthographe de l'architecture** (C4) | M8 (source-visible) | `arm64` partout où c'est visible ; `aarch64` réservé aux constantes qui portent ce nom |
| **D-6** | **Forme du rejet de plateforme** | M8 | Pas de primitive de panique. **`None` = refus**, plus un **diagnostic sur une production requise valant `None`** (aujourd'hui silencieusement `const 0`, `bytecode.odin:193-196`) |
| **D-7** | **Projection à travers `Pattern_Type`** : variante (a) scrutateur littéral, ou (b) `Or_Type` général | M8 | **(a) d'abord** — correcte par construction pour `@platform` ; (b) ensuite pour un scrutateur symbolique |
| **D-8** | **Erreur Syntact à travers une ABI C** | M10, seulement si les premiers exports sont partiels | Ne rien inventer : la couleur de la production contient le cas d'échec. Différable |
| **D-9** | **Non-rechargeabilité** de certaines identités (signature figée, callbacks d'allocation) | M11 | Refuser le patch et exiger un restart. Le dire, ne pas le contourner |
| **D-10** | **Règle d'état** (§13.3) | M15, donc après la résonance | La règle de §13.3, formulée dans les termes de l'algèbre |

## 19.2 Différable sans coût de rétrofit

- Étiquette d'ISA dans la grammaire de l'ASM (D-3 de §9.2) — mais **pas** la loi de
  volatilité (D-1), qui est bloquante.
- Syntaxe entrées / sorties / clobbers de l'ASM ; convention fixe d'abord (`effects.md`).
- Agrégats par valeur au-delà de SysV ; `Abi.classify` est le point d'extension (`abi.md` §6).
- Question des adresses (`interop.md` §2) — derrière la proposition `Out{T}` de
  `vulkan-slice.md` §4.2.
- Liaison statique de `.a` **externes** (`abi.md` §5 : ce serait écrire un linker).
- `App_Package`, signature APK v2, JNI.
- iOS device (D-14d) : mur de politique, pas d'ingénierie.
- Binaires universels, XCFramework, `package/multi` (`targets.md` §6.4).
- DWARF au-delà des tables de lignes ; CodeView/PDB (écart accepté, `targets.md` §8.4).
- SIMD arm64 (NEON) ; `@platform.features` (honnête seulement avec deux backends,
  `sdk.md` §3.1).
- Mode mixte AOT/interprété (§15) — **mais la frontière est décidée maintenant** : un ensemble
  d'identités de `BC_Func`.
- Handlers de migration d'état (option 5 de §13.2).
- Backends C, JS, wasm — **avec une seule action à ne pas différer** : émettre `Loop_Info` au
  jalon des boucles (§17).
- `syntact format` — exige un lex conservant les trivia et le respect des règles de collage
  (`sdk.md` §10) ; ne touche aucun backend.

## 19.3 Les deux choses à ne pas différer, en une phrase chacune

1. **`Loop_Info`** au moment où les arêtes arrière apparaissent : gratuit maintenant,
   irrécupérable ensuite (`targets.md` §12).
2. **`Code_Object.bindings`** et la **table `identité → corps`** définies par index et non par
   adresse : c'est ce qui laisse le hot reload, les exports, les callbacks, le mode mixte et
   wasm réalisables par une seule mécanique (§15.3, §17).
