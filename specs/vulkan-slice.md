# Vertical slice GLFW / Vulkan — audit d'interop

> Audit daté du 2026-07-29. Aucune modification du compilateur. Chaque constat marqué
> **[VÉRIFIÉ]** a été reproduit sur le compilateur construit depuis `master` (`d47fb74`)
> avec `odin build compiler`. Chaque constat marqué **[LECTURE]** est démontré par le code
> cité, sans exécution. Les documents `interop.md`, `abi.md`, `effects.md`, `targets.md`,
> `sdk.md` sont traités comme des intentions, pas comme des preuves.
>
> Environnement de l'audit : Arch Linux x86-64, `libvulkan.so.1` présent, **GLFW absent**,
> `libSDL2-2.0.so.0` présent (utilisé comme substitut de même forme ABI pour les tests
> d'exécution — voir §1.4).

---

## 1. Ce que le compilateur fait réellement aujourd'hui

### 1.1 La frontière `<lib>` fonctionne, dans un périmètre étroit

Le chemin complet parse → analyze → reduce → bytecode → ELF dynamique existe et produit des
exécutables qui appellent réellement des symboles externes, sans linker externe.

| Capacité | État | Preuve |
|---|---|---|
| `<lib>{ sym -> { … -> ??::T } }` parse/analyse/réduit | **OK** | `parse.odin:2546`, `analyze.odin:850-865`, `reduce.odin:1437` |
| Appel indirect via GOT, tables ELF écrites par le compilateur | **OK** | `emit.odin:713-768`, `elf_dynamic.odin`, `elf.odin:57-78` |
| 0 à 6 arguments scalaires entiers/flottants | **OK** | `emit.odin:717-757` — **[VÉRIFIÉ]** `SDL_CreateWindow` à 6 args émis correctement |
| Handle opaque `u64` reçu puis rendu | **OK** | **[VÉRIFIÉ]** `fclose{f -> fopen{…}!}!` produit deux appels chaînés corrects |
| Retour entier (`rax`) / flottant (`xmm0`) | **OK** | `emit.odin:763-767` |
| `AL` = nombre de registres SSE (variadiques partiels) | **OK** | `emit.odin:753` |
| Plusieurs bibliothèques, un `DT_NEEDED` par lib distincte | **OK** | `elf_dynamic.odin:110-125` |
| Programme sans `<lib>` reste statique | **OK** | `elf.odin:86` |

### 1.2 Découvertes de l'audit — trois défauts bloquants non documentés

Ces trois points ne figurent ni dans `interop.md` ni dans `abi.md`. Ce sont les découvertes
principales de cet audit, et ils redéfinissent le chemin critique.

#### D1 — Les registres caller-saved ne sont jamais préservés autour d'un appel externe **[VÉRIFIÉ]**

`emit_foreign_call` (`emit.odin:713-768`) ne sauvegarde rien. L'allocateur distribue
`ALLOCATABLE_REGS := {RSI, RDI, R8, R9, R10, R11, R12, R13, R14, R15}`
(`regalloc.odin:51`), dont **six sont caller-saved** en System V. L'allocateur n'a aucune
notion de « cet appel détruit ces registres » : `regalloc.odin:14-19` documente uniquement
l'hypothèse des sauts avant.

Conséquence : toute valeur vivante à travers un appel externe peut être détruite.

Preuve minimale reproduite :

```syntact
sdl -> <libSDL2-2.0.so.0>{
  SDL_Init         -> { u32:flags, -> ??::i32 }
  SDL_CreateWindow -> { string:title, i32:x, i32:y, i32:w, i32:h, u32:flags, -> ??::u64 }
}
-> (sdl.SDL_CreateWindow{
      title -> "syntact\0",
      x -> sdl.SDL_Init{flags -> 32}! + 536805376,
      y -> 536805376, w -> 320, h -> 240, flags -> 4
   }! >> 40) [&] 255
```

`--regalloc` donne :

```
v0 = str .rodata[0]        ; v0 -> rsi        ← le titre est chargé AVANT l'appel
v1 = const 32              ; v1 -> rdi
v2 = call [got 0](v1)      ; SDL_Init         ← SDL_Init écrase rsi
v3 = + v2 #536805376       ; v3 -> rdi
…
v8 = call [got 1](v0, v3, …)  ; SDL_CreateWindow ← reçoit un titre corrompu
```

Exécution : **SIGSEGV**. Le même programme sans valeur vivante à travers l'appel
fonctionne. Autre reproduction, sans crash mais avec résultat faux :
`w! + w!` sur `write(1,"X",1)` n'écrit qu'un seul `X` et sort avec 255 au lieu de 2.

Ce défaut est **latent et non déterministe** : `libc.strlen` préserve accidentellement `rsi`,
donc `strlen("hello\0")! + strlen("hello\0")!` rend bien 10. Les neuf appels vérifiés dans
`interop.md` §1 sont tous des appels **uniques** ou imbriqués avec calcul d'arguments postérieur —
aucun n'expose le défaut. **Un programme Vulkan est une séquence de 15 à 40 appels : il ne peut
pas fonctionner tant que D1 n'est pas corrigé.**

#### D2 — Les chaînes littérales ne sont pas terminées par NUL **[VÉRIFIÉ]**

`emit.odin:104-107` concatène les octets bruts dans `.rodata`, sans terminateur :

```odin
for s, i in prog.rodata {
    e.rodata_off[i] = len(rodata_blob)
    for c in transmute([]u8)s do append(&rodata_blob, c)
}
```

`readelf -x .rodata` sur `-> libc.strlen{s->"hello"}!` montre exactement `68656c6c 6f` puis le
code. `strlen("hello")` renvoie **8**, pas 5 — il lit dans `.text`. `fopen("/dev/null","r")`
renvoie NULL puis `fclose(NULL)` segfaulte.

**Contournement disponible aujourd'hui** : l'échappement `\0` est supporté par le lexer et
atterrit bien dans `.rodata`. `strlen("hello\0")` renvoie **5** — **[VÉRIFIÉ]**. Donc les
`const char*` d'entrée sont utilisables dès maintenant au prix d'un `\0` explicite.

#### D3 — Un appel externe placé dans le scrutateur d'un pattern est purement effacé **[VÉRIFIÉ]**

```syntact
libc -> <libc.so.6>{ getpid -> { -> ??::i32 } }
-> libc.getpid{}! ? { >0 -> 1, -> 0 }
```

produit `v0 = const 0 ; ret v0`. Le binaire émis est **statiquement lié** (`readelf -d` : « no
dynamic section »). L'appel a disparu.

Cause : `holds_foreign_collapse` (`reduce.odin:81-101`) couvre `Execute`, `Foreign_Call`,
`Compose`, `Cast`, `Or`, `And`, `Negate`, `Range` — **pas `Pattern_Type`**. Le raccourci
singleton de `reduce` (`reduce.odin:29-35`) répond donc par le fold et efface l'effet. C'est
une violation directe de la loi énoncée dans `effects.md` : *« un effet est levé dès qu'un
collapse traverse la frontière externe, indépendamment de la forme du résultat »*.

Impact direct : `glfwWindowShouldClose(w) ? { … }` — le test de la boucle d'événements —
supprime l'appel.

### 1.3 Autres défauts vérifiés, de moindre portée

| # | Défaut | Preuve | Impact slice |
|---|---|---|---|
| D4 | Un branchement de pattern à intervalle **semi-ouvert** (`>0`, `>=1`) ne produit **aucun test** et est pris inconditionnellement | `bytecode.odin:477-490` exige `lo` **et** `hi`; sinon `bytecode.odin:434-438` émet la branche sans garde. **[VÉRIFIÉ]** : `??::u8 ? { >0 -> 1, -> 0 }` rend 1 pour toute entrée, y compris 0 | Bloque tout test de code de retour non borné |
| D5 | Désalignement de pile de 8 octets dès qu'il y a un spill | `emit.odin:451-460` : `push rbp` (RSP≡8) + `sub rsp, frame` (frame multiple de 16) ⇒ RSP≡8 avant `call`, alors que SysV exige RSP≡0. Correct **uniquement** quand `stack_size == 0` (pas de prologue). **[LECTURE]** — `interop.md` §4 le signale déjà comme « fragile » | Latent ; casse tout callee utilisant `movaps` |
| D6 | Pas de sortie propre : l'épilogue fait `exit_group` brut, jamais `exit()` de la libc | `emit.odin:465-495` | Pas d'`atexit`, pas de flush stdio ; sans conséquence pour Vulkan mais explique l'absence de sortie de `puts` |
| D7 | `??::u32 [&] 3` puis `[|] 4` se replie en constante `4` | **[VÉRIFIÉ]** ; le fold d'un OR bit-à-bit sur un intervalle perd la partie symbolique | Marginal (les flags Vulkan sont des constantes) |
| D8 | Récursion sur un `??` : se replie silencieusement en constante au lieu d'atteindre l'erreur « no loops » | **[VÉRIFIÉ]** `countdown{n -> ??::u64}!` rend `const 7` | Voir §7, jalon boucle |
| D9 | `@platform` n'existe pas | **[VÉRIFIÉ]** : `@platform.os` ⇒ `property 'os' does not exist` | Le nommage par cible (`abi.md` §4) est non implémenté ; sans objet pour un slice Linux |
| D10 | `--run` rejette tout appel externe | `bytecode/interp.odin:56-66` | L'oracle interprète ne couvrira pas le slice |

### 1.4 Ce qui n'existe pas du tout

| Capacité | Preuve |
|---|---|
| **Aucune instruction mémoire dans le bytecode** — pas de `load`, pas de `store` | `bytecode/bytecode.odin:232-247` : l'union `BC_Inst` contient 15 variantes, aucune n'accède à la mémoire hormis `BC_Str_Const` (adresse constante) |
| Struct/scope comme valeur machine | `bytecode.odin:237-238` : `case: bc_fail("codegen: unsupported value in lowering")` |
| Retour `Str` d'un externe | `bytecode.odin:274-279` |
| Arguments sur la pile (>6) | `emit.odin:717-720` |
| `sret`, agrégats deux registres | absents |
| Callbacks (code Syntact appelé depuis C) | pas de modèle d'appel ; `abi.md` §7 |
| Boucles issues du langage | `BC_Jump` supporte l'arête arrière (`bytecode.odin:242`) et `emit.odin` sait la patcher, mais **rien en amont n'en produit** ; `regalloc.odin:14-19` : la liveness est linéaire et deviendrait fausse sur une arête arrière |
| Événements / résonance | `ir.odin:41` : « seul le couple pointant est réduit aujourd'hui (events/resonance/…) » |
| Section de données inscriptible pour le programme | `elf.odin:110` : `memsz` couvre `ARGS_TABLE` et le GOT uniquement |

### 1.5 Deux acquis sous-estimés, très utiles pour la suite

**A. Le mécanisme « adresse absolue fixe dans un PT_LOAD RWX » existe déjà.** `ARGS_TABLE_VADDR`
(`elf.odin:57-60`) est une zone remise à zéro par le chargeur, à une adresse connue **avant**
l'émission, et l'émetteur y écrit réellement (`emit.odin:188` : `mov_m64_r64` indexé). Le
segment est `R|W|X` (`elf.odin:150`) et `memsz` s'étend au-delà de `filesz`
(`elf.odin:110`). **Une arène de scratch pour matérialiser les structs et les cellules de
sortie est une extension d'une seule constante**, pas une nouvelle capacité.

**B. Un paramètre externe de forme struct est déjà entièrement exprimable.** **[VÉRIFIÉ]** :

```syntact
VkApplicationInfo -> { u32:sType -> 0, u64:pNext -> 0, u32:apiVersion -> 4194304 }
vk -> <libvulkan.so.1>{
  vkCreateInstance -> { VkApplicationInfo:pCreateInfo, u64:pAllocator, u64:pInstance, -> ??::i32 }
}
-> vk.vkCreateInstance{pCreateInfo -> VkApplicationInfo{}, pAllocator -> 0, pInstance -> 0}!
```

Parse, analyse et réduction **réussissent**. Le nœud `Foreign_Call_Type` est construit avec le
scope en argument 0. Seul le lowering échoue, sur le `case:` fourre-tout de
`bytecode.odin:237`. De plus, `Scope_Type` porte `constraints` et `constraint_folds` par liaison
(`ir.odin:92-93`) et `cast_target` (`type.odin:873-900`) donne largeur + signedness par champ.
**Tout ce qu'il faut pour calculer un layout C est déjà dans l'IR.** La matérialisation de
struct est un travail de backend pur, sans décision de langage.

---

## 2. Le programme C de référence

### 2.1 Périmètre A — fenêtre et événements (GLFW seul)

```c
#include <GLFW/glfw3.h>

int main(void) {
    if (!glfwInit()) return 1;
    glfwWindowHint(GLFW_CLIENT_API, GLFW_NO_API);      /* 0x00022001, 0 */
    GLFWwindow *w = glfwCreateWindow(800, 600, "syntact", NULL, NULL);
    if (!w) { glfwTerminate(); return 1; }
    while (!glfwWindowShouldClose(w)) glfwPollEvents();
    glfwDestroyWindow(w);
    glfwTerminate();
    return 0;
}
```

Surface exacte : 7 symboles, 0 struct, 0 paramètre de sortie, 0 callback, 0 tableau.
Formes ABI : `int`, `const char*`, deux pointeurs NULL, un handle opaque retourné puis rendu.
**Tous les arguments tiennent en registre. Le seul obstacle structurel est la boucle.**

### 2.2 Périmètre B — instance, surface, device

```c
uint32_t nExt = 0;
const char **exts = glfwGetRequiredInstanceExtensions(&nExt);

VkApplicationInfo app = {
    .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,        /* 0 */
    .pNext = NULL, .pApplicationName = "syntact", .applicationVersion = 0,
    .pEngineName = "none", .engineVersion = 0,
    .apiVersion = VK_API_VERSION_1_0                     /* 0x00400000 */
};
VkInstanceCreateInfo ici = {
    .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,     /* 1 */
    .pNext = NULL, .flags = 0, .pApplicationInfo = &app,
    .enabledLayerCount = 0, .ppEnabledLayerNames = NULL,
    .enabledExtensionCount = nExt, .ppEnabledExtensionNames = exts
};
VkInstance inst;
vkCreateInstance(&ici, NULL, &inst);

VkSurfaceKHR surface;
glfwCreateWindowSurface(inst, w, NULL, &surface);

uint32_t nPd = 1; VkPhysicalDevice pd;
vkEnumeratePhysicalDevices(inst, &nPd, &pd);            /* premier device seulement */

VkBool32 supported = 0;
vkGetPhysicalDeviceSurfaceSupportKHR(pd, 0, surface, &supported);  /* famille 0 */

float prio = 1.0f;
VkDeviceQueueCreateInfo dq = {
    .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, /* 2 */
    .pNext = NULL, .flags = 0,
    .queueFamilyIndex = 0, .queueCount = 1, .pQueuePriorities = &prio
};
const char *devExt[1] = { "VK_KHR_swapchain" };
VkDeviceCreateInfo dc = {
    .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,       /* 3 */
    .pNext = NULL, .flags = 0,
    .queueCreateInfoCount = 1, .pQueueCreateInfos = &dq,
    .enabledLayerCount = 0, .ppEnabledLayerNames = NULL,
    .enabledExtensionCount = 1, .ppEnabledExtensionNames = devExt,
    .pEnabledFeatures = NULL
};
VkDevice dev; vkCreateDevice(pd, &dc, NULL, &dev);
VkQueue q;    vkGetDeviceQueue(dev, 0, 0, &q);
```

Ajoute : 4 structs d'entrée par adresse, 4 cellules de sortie scalaires, 1 adresse de `float`
constant, 1 tableau de `const char*` constant, 1 pointeur opaque stocké **dans un champ de
struct** sans jamais être déréférencé.

### 2.3 Périmètre C — swapchain et présentation d'une couleur

Ajoute au minimum : `vkGetPhysicalDeviceSurfaceCapabilitiesKHR` (struct de **sortie** de 52
octets), `vkGetPhysicalDeviceSurfaceFormatsKHR` (tableau de sortie), `VkSwapchainCreateInfoKHR`
(104 octets, contient un `VkExtent2D` imbriqué par valeur), `vkGetSwapchainImagesKHR` (tableau
de sortie de handles), pool + command buffer, deux sémaphores, une fence,
`vkAcquireNextImageKHR` (6 args), deux barrières d'image, `vkCmdClearColorImage`
(`VkClearColorValue` est une **union**), `vkQueueSubmit` (`VkSubmitInfo`), `vkQueuePresentKHR`
(`VkPresentInfoKHR`), `vkWaitForFences`, `vkDeviceWaitIdle` — le tout **dans la boucle**.

### 2.4 Supplément triangle

`vkCreateShaderModule` × 2 (blob SPIR-V en `.rodata`, `size_t codeSize`),
`VkPipelineShaderStageCreateInfo[2]` (**tableau de structs**), 7 structs d'état de pipeline,
`vkCreatePipelineLayout`, `vkCreateRenderPass` (`VkAttachmentDescription`,
`VkSubpassDescription` avec pointeurs vers sous-structs), `vkCreateFramebuffer`,
`vkCreateGraphicsPipelines` (6 args, tableau de create-infos), `vkCmdBeginRenderPass`,
`vkCmdBindPipeline`, `vkCmdSetViewport`/`Scissor`, `vkCmdDraw`, `vkCmdEndRenderPass`.

---

## 3. Matrice d'interop

Catégories : **1** fonctionne aujourd'hui · **2** exprimable, lowering manquant ·
**3** extension mécanique ABI/backend · **4** décision sémantique de langage ·
**5** évitable dans le premier slice · **6** bloquant obligatoire.

| # | Forme C | Exemple concret | Repr. C exacte | Exprimable en Syntact ? | Abaissé aujourd'hui ? | Gap précis | Changement minimal | Réutilisable ? | Cat. |
|---|---|---|---|---|---|---|---|---|---|
| 1 | Entier signé | `glfwCreateWindow(int w, int h, …)` | `int` 32b | oui, `i32:` | **oui** | — | — | — | **1** |
| 2 | Entier non signé | `SDL_Init(Uint32)`, `VkFlags` | `uint32_t` | oui, `u32:` | **oui** | — | — | — | **1** |
| 3 | 64 bits | handles, `VkDeviceSize` | `uint64_t` | oui, `u64:` | **oui** | — | — | — | **1** |
| 4 | `float` en registre | aucun dans le slice | `float` | `f32:` | non (`cvtsd2ss` absent, `interop.md` §3) | conversion f64→f32 à l'appel | 2 instructions dans `emit_foreign_call` | oui | **3/5** |
| 5 | `double` en registre | aucun dans le slice | `double` | `f64:` | **oui** (`libm.sqrt`) | — | — | — | **1/5** |
| 6 | `size_t` / `uintptr_t` | `VkShaderModuleCreateInfo.codeSize` | 64b non signé | `u64:` (pas d'alias `usize`) | **oui** en tant que `u64` | alias manquants uniquement | définir `usize`/`isize` comme alias de largeur d'arch | oui | **1** (triangle) |
| 7 | Enum C | `VkStructureType`, `VkFormat` | `int32_t`/`uint32_t` | oui, liaison constante `-> 0` | **oui** (constante) | pas de nommage groupé | scope Syntact ordinaire de constantes | oui | **1** |
| 8 | Flags bitwise | `VK_QUEUE_GRAPHICS_BIT \| …` | `uint32_t` | oui, `[\|]` `[&]` `[~]` | **oui à la compilation** — **[VÉRIFIÉ]** `1 [\|] 2` ⇒ 3 | fold symbolique bogué (D7) | corriger le fold OR sur intervalle | oui | **1** |
| 9 | Handle opaque | `VkInstance`, `GLFWwindow*`, `VkSurfaceKHR` | pointeur ou `uint64_t` (tous 8 o sur x86-64) | oui, `u64:` | **oui** — **[VÉRIFIÉ]** chaîne `fopen`→`fclose` | — | — | — | **1** |
| 10 | Pointeur NULL | `pAllocator`, `monitor`, `share` | `NULL` | oui, `-> 0` | **oui** (`pcre2_config(0,NULL)`) | — | — | — | **1** |
| 11 | `const char*` | `glfwCreateWindow` titre, `"VK_KHR_swapchain"` | pointeur vers octets NUL-terminés en `.rodata` | oui, `string:` | **oui mais faux** (D2) ; **correct avec `"…\0"`** — **[VÉRIFIÉ]** | terminateur non émis | ajouter `\0` dans `rodata_blob` (`emit.odin:106`) + contrainte `CString` d'`effects.md` | oui | **3** |
| 12 | `const char* const[]` **constant** | `VkDeviceCreateInfo.ppEnabledExtensionNames` | tableau de pointeurs en `.rodata` | pas encore (pas de littéral tableau abaissé) | non | besoin d'un blob `.rodata` contenant des adresses `.rodata` | émettre un tableau d'adresses ; les vaddr `.rodata` sont connues avant émission (`emit.odin:98-112`) | oui | **3** |
| 13 | `const char**` **retourné** | `glfwGetRequiredInstanceExtensions` | pointeur vers tableau de pointeurs | **oui, comme `u64:`** | **oui** | aucun — **il n'est jamais déréférencé**, il est recopié dans un champ de struct | aucun | — | **1** |
| 14 | Pointeur vers scalaire **constant** | `VkDeviceQueueCreateInfo.pQueuePriorities = &1.0f` | `const float*` vers `.rodata` | non | non | adresse d'un littéral en `.rodata` | poser le `f32` en `.rodata`, écrire son adresse dans le champ | oui | **3** |
| 15 | Pointeur vers struct d'entrée `const` | `vkCreateInstance(&ici, …)` | adresse d'un agrégat vivant seulement pendant l'appel | **oui** — **[VÉRIFIÉ]** §1.5 B | **non** (`bytecode.odin:237`) | matérialisation : layout C + arène + `store` + passage d'adresse | règle de layout C + `BC_Materialize` + arène (§1.5 A) | oui | **2** |
| 16 | Struct imbriquée par valeur | `VkSwapchainCreateInfoKHR.imageExtent` (`VkExtent2D`) | agrégat inline, pas de pointeur | oui (scope dans scope) | non | même mécanisme, récursif | layout récursif | oui | **2** |
| 17 | Champ pointeur dans une struct | `.pApplicationInfo`, `.ppEnabledExtensionNames` | `u64` dans l'agrégat | oui (`u64:` alimenté par #13/#14) | non | dépend de #15 | dépend de #15 | oui | **2** |
| 18 | Paramètre de sortie scalaire/handle | `VkInstance*`, `uint32_t*`, `VkBool32*`, `VkSurfaceKHR*` | adresse d'une cellule écrite par le callee | **non** | non | pas de cellule, pas de `load`, et un externe ne produit qu'**une** valeur | `Out{T}:` (§4.2) + `BC_Load` + production multi-champs | oui | **4** (décision minimale) + **6** |
| 19 | Struct de sortie | `vkGetPhysicalDeviceSurfaceCapabilitiesKHR(&caps)` | agrégat de 52 o écrit par le callee, champs relus | non | non | #18 généralisé à un agrégat | même mécanisme, relecture champ par champ | oui | **4/6** (périmètre C) |
| 20 | Tableau + longueur séparée | `vkEnumeratePhysicalDevices(inst,&n,pArr)` | idiome deux passes | non | non | buffer alloué par l'appelant + relecture indexée | fixer N à la compilation dans le slice (voir §5) | partiellement | **5** puis **4** |
| 21 | Pointeur vers pointeur | `const char* const*` déjà couvert par #12/#13 | — | — | — | aucun cas résiduel dans le slice | — | — | **5** |
| 22 | Chaîne `pNext` | tous les `pNext` du slice | `NULL` | oui (`u64:pNext -> 0`) | dépend de #15 | aucun | aucun | — | **5** |
| 23 | Union | `VkClearColorValue` (16 o) | union de 3 formes de 16 o | oui — un scope de 4 `f32` a le même layout | non | aucun besoin d'union : choisir une branche à la compilation | traiter comme un agrégat de 4 `f32` | oui | **5** |
| 24 | Callback C | `glfwSetKeyCallback` | `void(*)(GLFWwindow*,int,int,int,int)` | non | non | pas de modèle d'appel, pas de frame ABI, RBX exclu (`regalloc.odin:47-49`) | — | — | **5** (polling) |
| 25 | Function pointer | `PFN_vkVoidFunction` | pointeur code | comme `u64:` | reçu oui, **appelé non** | pas d'appel indirect sur valeur | — | — | **5** |
| 26 | `vkGetInstanceProcAddr` / `vkGetDeviceProcAddr` | chargement dynamique | — | — | — | **aucun** — **[VÉRIFIÉ]** : les 28 symboles du slice, KHR comprises, sont exportés par `libvulkan.so.1` | lier directement | — | **5** |
| 27 | Arguments sur la pile (>6) | `vkCmdPipelineBarrier` (11) | 7e argument et suivants sur la pile | oui | **non** (`emit.odin:717-720`) | pile + alignement | `Abi` record (`abi.md` §2.3) ; **ou** utiliser `vkCmdPipelineBarrier2` (2 args) | oui | **3/5** |
| 28 | Retour de struct / `sret` | aucun dans le slice | pointeur caché en `rdi` | non | non | aucun besoin | — | — | **5** |
| 29 | Alignement / padding / layout C | tous les create-infos | ordre de déclaration, alignement naturel, padding de queue | l'IR porte largeur et signedness par champ (`ir.odin:92-93`, `type.odin:873`) | non | règle de layout absente | fonction `c_layout(scope) -> (size, align, []offset)` ; **lire la contrainte, pas la valeur** (voir §7 J4) | oui | **2** |
| 30 | Durée de vie / ownership | create-infos non retenues ; handles à détruire | contrat par fonction | — | — | les create-infos ne survivent pas à l'appel ⇒ arène jetable ; les handles sont des `u64` détruits explicitement | aucun mécanisme nouveau | — | **1** |
| 31 | Mémoire mutable partagée avec C | aucune dans le slice (hors cellules de sortie) | — | — | — | — | — | — | **5** |
| 32 | Constantes/macros de header | `VK_STRUCTURE_TYPE_*`, `GLFW_*` | `#define` / enum | oui, scopes de constantes | **oui** | aucun | décrire à la main pour le prototype | oui | **1** |
| 33 | Symboles fournis par la bibliothèque | tous | `DT_NEEDED` + `.dynsym` | oui | **oui** | aucun | — | — | **1** |
| 34 | Symboles récupérés dynamiquement | — | `dlsym` | non | non | inutile ici (#26) | — | — | **5** |
| 35 | **Séquence ordonnée d'effets** | tout le programme | `;` en C | **uniquement via `a! + b!`** — **[VÉRIFIÉ]** ordre respecté | oui mais **sémantiquement accidentel** : `+` est commutatif | pas de construction de séquencement | §4.3 | oui | **4** + **6** |
| 36 | **Boucle** | `while (!glfwWindowShouldClose(w))` | boucle | non (récursion se replie faussement, D8) | non | pas d'arête arrière produite ; liveness linéaire (`regalloc.odin:14-19`) | abaissement récursion→boucle + liveness d'intervalles | oui | **6** |
| 37 | **Test d'exécution sur un résultat externe** | `if (!glfwWindowShouldClose(w))` | branchement | oui syntaxiquement | **non** — D3 efface l'appel, D4 supprime la garde | deux bogues distincts | corriger `holds_foreign_collapse` + `bc_branch_int_range` | oui | **6** |
| 38 | **Préservation des registres caller-saved** | tout appel n°2 et suivants | ABI System V | — | **non** — D1 | l'allocateur ignore les clobbers | §7 J1 | oui | **6** |

---

## 4. ABI ou sémantique du langage ?

### 4.1 Classement des usages d'adresse du slice

| Usage d'adresse | Occurrences dans le slice | Confiné à la frontière ABI ? |
|---|---|---|
| Adresse fixe d'une valeur en `.rodata` | titre de fenêtre, `"VK_KHR_swapchain"`, `&1.0f`, tableau de `const char*`, blob SPIR-V | **oui, entièrement** |
| Adresse temporaire d'une struct matérialisée par le lowering | les 4 create-infos de B, les ~10 de C | **oui, entièrement** — la durée de vie est celle de l'appel (Vulkan garantit qu'aucune create-info n'est retenue) |
| Buffer alloué par l'appelant | tableaux de `vkEnumeratePhysicalDevices`, `vkGetSwapchainImagesKHR` | **oui**, si la taille est fixée à la compilation (§5) |
| Paramètre de sortie | `VkInstance*`, `uint32_t*`, `VkSurfaceKHR*`, `VkDevice*`, `VkQueue*`, `VkSwapchainKHR*` | **non** — exige une forme visible dans le langage (§4.2) |
| Handle opaque transporté sans déréférencement | `VkInstance`, `GLFWwindow*`, `exts` de `glfwGetRequiredInstanceExtensions` | **oui** — déjà un `u64`, rien à décider |
| Cellule mutable partagée | aucune | sans objet |
| Adresse de fonction / callback | aucune (polling) | sans objet |
| Pointeur obtenu dynamiquement puis invoqué | aucune (§3 #26) | sans objet |

**Conclusion : six des huit familles restent entièrement du ressort du backend.** Cela confirme
et resserre le diagnostic d'`interop.md` §2.3 (« le cas qui exige vraiment une décision est le
plus rare à la frontière ») — mais la présente analyse contredit une hypothèse implicite
d'`interop.md` : le cas qui reste n'est *pas* « pointeur variable déréférencé », c'est
**le paramètre de sortie**, et il est omniprésent dans Vulkan (chaque `vkCreate*`).

### 4.2 Décision requise n°1 — la forme du paramètre de sortie

Ce qu'il ne faut **pas** faire : introduire un type `Pointer`. Rien dans le slice ne demande
d'arithmétique d'adresse, d'aliasing, ni d'identité de cellule.

Ce que le cas exige réellement, et rien de plus :
1. réserver une cellule de `sizeof(T)` appartenant à l'appelant, vivante le temps de l'appel ;
2. passer son adresse dans un emplacement d'argument ;
3. relire son contenu **une fois**, après l'appel, comme une valeur ordinaire.

Aucune de ces trois choses n'est un pointeur. Formulation proposée, sans syntaxe nouvelle —
`Out` est un scope Syntact ordinaire, comme `CString` dans `effects.md` :

```syntact
Out -> { T <- {} }          // le trou générique : sortie de quoi
```

```syntact
vkCreateInstance -> {
  VkInstanceCreateInfo:pCreateInfo
  u64:pAllocator -> 0
  Out{u64}:pInstance
  -> ??::i32
}
```

Le lowering, en voyant une liaison colorée par `Out{T}`, matérialise une cellule dans l'arène,
passe son adresse, et **la production de l'appel devient un scope** :

```
{ -> ??::i32, pInstance -> <valeur relue> }
```

Ainsi la loi du langage est préservée : le collapse d'un externe produit une valeur, et une
valeur composite est un scope — ce qui est déjà le modèle de Syntact. Aucune adresse n'entre
dans le langage pur.

Ceci **répond** aux questions ouvertes d'`interop.md` §2 :
- **Q1** (identité de cellule) : sans objet — la cellule ne survit pas à l'appel.
- **Q2** (le buffer de sortie est-il une `Address` résonante ?) : **non**. C'est un temporaire
  appartenant à l'appelant, résolu à la frontière. La résonance ne sert que si le C conserve
  la cellule, ce que ce programme ne fait jamais.
- **Q3** (`Address` additif ou canonique ?) : sans objet — pas d'`Address`.
- **Q4** (l'accès mémoire est-il valeur ou effet ?) : la lecture de la cellule fait partie de
  l'effet unique qu'est l'appel, pas d'un effet séparé.
- **Q5** (ownership) : les handles Vulkan sont des `u64` détruits par des appels explicites —
  question de programme, pas de frontière.

**Coût de la décision : une convention de coloration.** Coût d'implémentation : une règle de
layout, une arène, `BC_Materialize`/`BC_Load`, et une production composite.

### 4.3 Décision requise n°2 — comment ordonner des effets

C'est le point le plus important de cet audit et il n'apparaît dans aucune spec.

Aujourd'hui, la **seule** façon d'obtenir deux appels externes dans un ordre donné est
`a! + b!` — **[VÉRIFIÉ]**, l'ordre de lowering suit l'ordre source. Mais `+` est commutatif :
rien dans la loi du langage n'interdit au réducteur de canoniser la somme et de réordonner les
appels. C'est un accident d'implémentation, pas une garantie. Un programme Vulkan est avant
tout une séquence.

Le langage possède déjà la construction adéquate, et `effects.md` §« Calling an external » la
suppose : **les liaisons d'un scope sont ordonnées** (`Scope_Type` stocke `names`/`kind`/`types`
en colonnes indexées par ordinal, `ir.odin:87-90`) et `reduce` les parcourt dans l'ordre
(`reduce.odin:26`). L'exemple canonique de `15-effects-and-handlers.md` s'appuie exactement
là-dessus :

```syntact
program -> {
  Log -< e { -> io.write{e.message}! }
  >- Log{message -> "hello"}      // une liaison qui n'est pas la production
  -> 0
}
```

La décision à prendre est donc étroite : **une liaison non-production dont la valeur contient
un collapse externe doit-elle être évaluée, dans l'ordre de déclaration, avant la
production ?** Aujourd'hui `reduce` ignore purement ces liaisons — il saute directement au
`Product` (`reduce.odin:26-40`).

Réponse recommandée : **oui**, et c'est cohérent avec `effects.md` (« l'effet a lieu au `!`, et
seulement là ») ainsi qu'avec la levée d'effet par provenance. Une liaison ordinaire dont la
valeur n'a pas d'effet reste paresseuse comme aujourd'hui ; seule la présence d'un
`holds_foreign_collapse` la force. Cela donne :

```syntact
main -> {
  ok      -> glfw.glfwInit{}!
  hint    -> glfw.glfwWindowHint{hint -> 139265, value -> 0}!
  window  -> glfw.glfwCreateWindow{width -> 800, height -> 600,
                                    title -> "syntact\0", monitor -> 0, share -> 0}!
  …
  -> 0
}
```

C'est exactement le séquencement dont Vulkan a besoin, sans nouvel opérateur, sans `;`, sans
monade — et cela n'ajoute **aucune** construction de surface.

### 4.4 Décision requise n°3 — la boucle

`while (!glfwWindowShouldClose(w))` n'est pas exprimable. La voie conforme au langage est la
récursion terminale, déjà la forme naturelle :

```syntact
loop -> {
  u64:window
  -> glfw.glfwWindowShouldClose{window -> window}! ? {
       0 -> { pollEvents -> glfw.glfwPollEvents{}!, -> loop{window -> window}! }!
       -> 0
     }
}
```

Rien à décider côté langage — c'est de la récursion ordinaire. Ce qui manque est
l'**abaissement récursion terminale → arête arrière** plus une liveness qui étende les
intervalles jusqu'à la fin de boucle (`regalloc.odin:14-19` dit précisément où). Le bytecode
possède déjà `BC_Jump` avec arête arrière, `BC_Branch_Zero` et `BC_Move` comme phi
(`bytecode/bytecode.odin:241-243`). **C'est du travail mécanique, pas une décision.**

---

## 5. Stratégies de réduction de périmètre

| Stratégie | Verdict | Justification |
|---|---|---|
| Polling plutôt que callbacks | **retenue** | `glfwWindowShouldClose` + `glfwPollEvents` suffisent ; supprime entièrement §3 #24 |
| `pAllocator = NULL` | **retenue** | supprime `VkAllocationCallbacks` (struct de 6 pointeurs de fonction) |
| Lier directement les symboles Vulkan | **retenue** | **[VÉRIFIÉ]** les 28 symboles nécessaires, KHR comprises, sont exportés par `libvulkan.so.1` ; `vkGetInstanceProcAddr` inutile jusqu'au triangle inclus |
| SPIR-V précompilé | **retenue** | blob en `.rodata` + son adresse — même mécanisme que #14 |
| Constantes Vulkan décrites à la main | **retenue** | déjà supporté (§3 #32) ; le générateur depuis `vk.xml` est un travail ultérieur |
| Structs matérialisées côté backend | **retenue** | §1.5 B : déjà exprimables, seul le lowering manque |
| Fixer les cardinalités à la compilation | **retenue** | 1 device physique, famille de queue 0, 1 extension device, `minImageCount` depuis `caps` ; supprime le besoin de tableaux dynamiques pour B, le réduit à 2 tableaux fixes pour C |
| `vkCmdPipelineBarrier2` (2 args) au lieu de `vkCmdPipelineBarrier` (11 args) | **retenue** | **[VÉRIFIÉ]** exporté ; supprime le besoin d'arguments sur la pile pour tout le périmètre C |
| Wrapper C minimal | **rejetée** | voir ci-dessous |

**Sur le wrapper C.** Un wrapper masquerait exactement les quatre capacités qui constituent
l'intérêt de l'exercice : matérialisation de struct, cellule de sortie, séquencement d'effets,
boucle. Il ne masquerait aucun des trois défauts D1/D2/D3, qui restent présents dès le
deuxième appel — un wrapper à un seul point d'entrée les cache par accident, ce qui est pire.
S'il fallait néanmoins en passer par là, il faudrait lister ce qu'il encapsule ; mais le
périmètre A ne demande **aucune** de ces quatre capacités et fournit déjà un résultat
observable. Le wrapper n'a donc pas de justification.

**Note sur GLFW.** GLFW n'est pas installé sur cette machine ; les tests d'exécution de cet
audit utilisent `libSDL2-2.0.so.0`, de forme ABI identique pour le périmètre A
(`SDL_Init`/`SDL_CreateWindow`/`SDL_PollEvent`/`SDL_DestroyWindow`/`SDL_Quit`). Installer GLFW
est un prérequis du test d'intégration.

### Comparaison des trois cibles

| | **A — GLFW seul** | **B — Vulkan minimal** | **C — rendu minimal** |
|---|---|---|---|
| Résultat observable | fenêtre qui s'ouvre, se déplace, se ferme | fenêtre + device créés (sortie par code de retour) | couleur présentée à l'écran |
| Symboles externes | 7 | 7 + 8 | 7 + 8 + ~16 |
| Structs à matérialiser | **0** | 4 | ~12, dont imbriquées et une union |
| Cellules de sortie | **0** | 6 scalaires | + 1 struct de sortie, 2 tableaux de sortie |
| Args > 6 | non | non | non (avec `vkCmdPipelineBarrier2`) |
| Callbacks | non | non | non |
| Capacités bloquantes | D1, D2, D3, D4, séquencement, boucle | + matérialisation struct, `Out{T}`, adresse de littéral, tableau constant de chaînes | + relecture d'agrégat, buffers de taille fixe, boucle avec état porté |
| Charge de travail relative | 1 | 2,5 | 6 |

**A est atteignable sans aucune décision de langage nouvelle au-delà de §4.3, et sans aucun
travail mémoire.** C'est ce qui en fait le premier jalon.

---

## 6. Binding Syntact annoté

```syntact
// ─────────────────────────────────────────────────────────────────────
// PÉRIMÈTRE A — fenêtre et événements
// ─────────────────────────────────────────────────────────────────────

glfw -> <libglfw.so.3>{

  glfwInit -> {
    -> ??::i32
  }                                         // ACTUELLEMENT EXÉCUTABLE (0 arg, retour i32)

  glfwWindowHint -> {
    i32:hint
    i32:value
    -> ??::i32                              // void en C ; un retour déclaré est inoffensif
  }                                         // ACTUELLEMENT EXÉCUTABLE

  glfwCreateWindow -> {
    i32:width
    i32:height
    string:title                            // ACTUELLEMENT EXÉCUTABLE si le littéral finit par \0
    u64:monitor -> 0                        // ACTUELLEMENT EXÉCUTABLE (NULL = 0)
    u64:share   -> 0
    -> ??::u64                              // handle opaque
  }                                         // ACTUELLEMENT EXÉCUTABLE (5 args ≤ 6)

  glfwWindowShouldClose -> { u64:window, -> ??::i32 }   // ACTUELLEMENT EXÉCUTABLE
  glfwPollEvents        -> { -> ??::i32 }               // ACTUELLEMENT EXÉCUTABLE
  glfwDestroyWindow     -> { u64:window, -> ??::i32 }   // ACTUELLEMENT EXÉCUTABLE
  glfwTerminate         -> { -> ??::i32 }               // ACTUELLEMENT EXÉCUTABLE
}

GLFW_CLIENT_API -> 139265                   // 0x00022001  ACTUELLEMENT EXÉCUTABLE
GLFW_NO_API     -> 0

eventLoop -> {
  u64:window
  -> glfw.glfwWindowShouldClose{window -> window}! ? {
       0 -> { poll -> glfw.glfwPollEvents{}!, -> eventLoop{window -> window}! }!
       -> 0
     }
}                                           // EXPRIMABLE MAIS NON LOWERÉ
                                            //   · D3 efface l'appel dans le scrutateur
                                            //   · pas d'abaissement récursion → boucle
                                            //   · la liaison `poll` n'est jamais évaluée (§4.3)

main -> {
  ok     -> glfw.glfwInit{}!                            // SYNTAXE PROPOSÉE (§4.3) —
  hint   -> glfw.glfwWindowHint{hint -> GLFW_CLIENT_API,//   liaison effectuée dans l'ordre
                                value -> GLFW_NO_API}!
  window -> glfw.glfwCreateWindow{width -> 800, height -> 600,
                                  title -> "syntact\0", monitor -> 0, share -> 0}!
  run    -> eventLoop{window -> window}!
  bye    -> glfw.glfwDestroyWindow{window -> window}!
  end    -> glfw.glfwTerminate{}!
  -> 0
}
-> main!

// Aujourd'hui, le seul séquencement disponible est :
//   -> glfw.glfwInit{}! + glfw.glfwWindowHint{…}! + …
// ACTUELLEMENT EXÉCUTABLE dans la forme, mais FAUX à l'exécution à cause de D1,
// et sémantiquement non garanti (`+` est commutatif) — voir §4.3.

// ─────────────────────────────────────────────────────────────────────
// PÉRIMÈTRE B — instance, surface, device
// ─────────────────────────────────────────────────────────────────────

VK_STRUCTURE_TYPE_APPLICATION_INFO        -> 0
VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO    -> 1
VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO-> 2
VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO      -> 3
VK_API_VERSION_1_0                        -> 4194304        // ACTUELLEMENT EXÉCUTABLE

VkApplicationInfo -> {                      // EXPRIMABLE MAIS NON LOWERÉ — [VÉRIFIÉ] §1.5 B
  u32:sType              -> VK_STRUCTURE_TYPE_APPLICATION_INFO
  u64:pNext              -> 0
  u64:pApplicationName   -> 0               // SYNTAXE PROPOSÉE : adresse d'un littéral .rodata
  u32:applicationVersion -> 0
  u64:pEngineName        -> 0
  u32:engineVersion      -> 0
  u32:apiVersion         -> VK_API_VERSION_1_0
}                                           // layout C attendu : 48 octets, align 8
                                            // offsets 0,8,16,24,32,40,44 — padding après
                                            // sType, applicationVersion, engineVersion

VkInstanceCreateInfo -> {                   // 64 octets, align 8
  u32:sType                    -> VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO
  u64:pNext                    -> 0
  u32:flags                    -> 0
  VkApplicationInfo:pApplicationInfo        // DÉCISION DE LANGAGE REQUISE :
                                            //   un champ coloré par un scope est-il inline
                                            //   (comme en C une struct imbriquée) ou une
                                            //   adresse ? Ici Vulkan veut une ADRESSE.
                                            //   Proposition : `Ref{T}:` explicite, symétrique
                                            //   de `Out{T}:`, le scope nu restant inline.
  u32:enabledLayerCount        -> 0
  u64:ppEnabledLayerNames      -> 0
  u32:enabledExtensionCount                 // alimenté par la cellule de sortie de glfw
  u64:ppEnabledExtensionNames               // #13 : handle opaque, jamais déréférencé
}

vk -> <libvulkan.so.1>{
  vkCreateInstance -> {
    Ref{VkInstanceCreateInfo}:pCreateInfo   // SYNTAXE PROPOSÉE
    u64:pAllocator -> 0
    Out{u64}:pInstance                      // SYNTAXE PROPOSÉE (§4.2)
    -> ??::i32
  }
  vkEnumeratePhysicalDevices -> {
    u64:instance
    Out{u32}:pPhysicalDeviceCount           // SYNTAXE PROPOSÉE — préchargé à 1
    Out{u64}:pPhysicalDevices               // SYNTAXE PROPOSÉE — buffer de 1 élément
    -> ??::i32
  }
  vkGetDeviceQueue -> {
    u64:device, u32:queueFamilyIndex, u32:queueIndex,
    Out{u64}:pQueue
    -> ??::i32
  }
}
// La production de `vkCreateInstance{…}!` devient, après §4.2 :
//   { -> i32, pInstance -> u64 }
// donc `inst -> vk.vkCreateInstance{…}!.pInstance` — projection ordinaire, rien de nouveau.

glfwvk -> <libglfw.so.3>{
  glfwGetRequiredInstanceExtensions -> {
    Out{u32}:count                          // SYNTAXE PROPOSÉE
    -> ??::u64                              // ACTUELLEMENT EXÉCUTABLE en tant que valeur :
  }                                         //   handle opaque recopié dans un champ (#13)
  glfwCreateWindowSurface -> {
    u64:instance, u64:window, u64:allocator -> 0,
    Out{u64}:surface
    -> ??::i32
  }                                         // 4 args ≤ 6
}
```

---

## 7. Plan d'implémentation

Ordonné par dépendances réelles, chaque jalon donnant un résultat observable.

### J1 — Registres caller-saved autour d'un appel externe · **corrige D1**

- **Fichiers** : `compiler/backends/x64/regalloc.odin`, `compiler/backends/x64/emit.odin`
- **IR / bytecode** : aucun changement.
- **Lowering / codegen** : deux options. (a) restreindre `ALLOCATABLE_REGS`
  (`regalloc.odin:51`) aux callee-saved `R12–R15` dès que le programme contient un
  `BC_Foreign_Call`, et gérer leur sauvegarde dans le prologue — simple, coûteux en registres.
  (b) donner à l'allocateur la notion de clobber : à chaque `BC_Foreign_Call`, forcer le spill
  de toute valeur vivante logée dans un caller-saved. **Recommandé : (b)**, avec (a) comme
  repli si (b) déborde le jalon.
- **Règles ABI** : liste caller-saved System V = `RAX RCX RDX RSI RDI R8 R9 R10 R11` +
  tous les `XMM`.
- **Tests unitaires** : dans `test/codegen`, un programme à deux appels externes avec une
  valeur vivante à travers le premier ; vérifier le spill dans `--regalloc`.
- **Test d'intégration débloqué** : `strlen("aa\0")! + strlen("bbb\0")!` ⇒ 5, et le
  reproducteur SDL de §1.2 ne segfaulte plus.
- **Régression** : les neuf appels vérifiés d'`interop.md` §1 (appels uniques) — la pression
  registre augmente, les programmes purs ne doivent pas régresser.
- **Fin** : toute valeur vivante à travers un `BC_Foreign_Call` est soit dans un callee-saved,
  soit spillée. Vérifié par assertion sur la sortie de l'allocateur.

### J2 — Alignement de pile · **corrige D5**

- **Fichiers** : `emit.odin:451-460`, `emit.odin:745-757`
- **Codegen** : compenser les 8 octets du `push rbp` dans le calcul de `frame`, ou aligner
  explicitement avant chaque `call` (`and rsp, -16` dans un frame à `rbp`).
- **Test** : programme avec spill **et** appel externe vers un callee utilisant `movaps`
  (`memcpy` de la glibc).
- **Fin** : `RSP % 16 == 0` immédiatement avant chaque `call`, avec et sans prologue.

### J3 — Terminaison NUL des chaînes · **corrige D2**

- **Fichiers** : `emit.odin:104-107` (ajouter l'octet 0 après chaque chaîne) ;
  `emit.odin:471-473` — l'épilogue `write(1, ptr, len)` utilise `str_len`, à ne pas
  incrémenter.
- **Décision** : terminer **toujours** (coût : un octet par littéral) plutôt que d'introduire
  une distinction de représentation. La contrainte `CString` d'`effects.md` reste utile pour
  *prouver* l'absence de NUL interne, indépendamment.
- **Test** : `strlen("hello")! == 5` sans `\0` explicite ; `readelf -x .rodata`.
- **Régression** : la sortie chaîne du programme (`-> "hello"`) ne doit pas gagner un octet.
- **Fin** : `fopen("/dev/null\0"…)` et `fopen("/dev/null"…)` se comportent identiquement.

### J4 — Ordonnancement des effets par liaison · **implémente §4.3**

- **Fichiers** : `compiler/reduce.odin:20-72`
- **IR** : la production d'un scope contenant des liaisons effectuées devient une séquence.
  Représentation minimale : réutiliser `Compose_Type`/un nœud `Sequence_Type` dédié, ou
  émettre les liaisons effectuées comme des racines supplémentaires du DAG à lowerer avant la
  production.
- **Bytecode** : aucun opcode nouveau — l'ordre d'émission suffit
  (`lower_to_bytecode`, `bytecode.odin:140-158`, à étendre pour prendre une liste de racines).
- **Test unitaire** : dans `test/reduce`, un scope à trois liaisons externes et une production
  constante ⇒ trois `BC_Foreign_Call` dans l'ordre déclaré.
- **Test d'intégration débloqué** : `glfwInit` + `glfwWindowHint` + `glfwCreateWindow`
  séquencés sans passer par `+`.
- **Régression** : une liaison **sans** effet doit rester paresseuse (le `holds_foreign_collapse`
  décide) — sinon toute la propriété d'effondrement du langage régresse.
- **Fin** : l'ordre des appels est garanti par la loi du langage, pas par un accident de `+`.

### J5 — Effet préservé sous un pattern · **corrige D3**

- **Fichiers** : `compiler/reduce.odin:81-101` (ajouter le cas `Pattern_Type`, en couvrant la
  cible **et** les produits de branches) ; vérifier aussi `Carve_Type` et `Scope_Type`.
- **Test unitaire** : `test/reduce` — `ext{}! ? { 0 -> 1, -> 2 }` conserve le
  `Foreign_Call_Type` ; `test/codegen` — le binaire est dynamique.
- **Fin** : `readelf -d` montre le `DT_NEEDED` ; l'appel est présent.

### J6 — Gardes de pattern à intervalle semi-ouvert · **corrige D4**

- **Fichiers** : `compiler/bytecode.odin:433-490`
- **Changement** : `bc_branch_int_range` renvoie `(Maybe(lo), Maybe(hi))` ; le lowering émet
  une comparaison par borne présente. Une branche **sans aucune** borne reste inconditionnelle
  (c'est le défaut légitime).
- **Test unitaire** : `test/codegen` — `??::u8 ? { >0 -> 1, -> 0 }` rend 0 pour 0 et 1 sinon.
- **Régression** : le suite `test/pattern` complet ; les intervalles fermés ne doivent pas
  changer de code émis.
- **Fin** : les quatre formes `>k`, `>=k`, `<k`, `<=k` produisent une garde.

> **À l'issue de J1–J6 : le périmètre A est atteignable sauf la boucle.** Un programme
> `glfwInit ; glfwWindowHint ; glfwCreateWindow ; glfwDestroyWindow ; glfwTerminate` ouvre et
> ferme une fenêtre réelle.

### J7 — Récursion terminale → arête arrière · **implémente §4.4**

- **Fichiers** : `compiler/reduce.odin` (reconnaître le collapse récursif terminal au lieu de
  le replier faussement — corrige D8), `compiler/bytecode.odin` (émettre
  `Label_Def`/`Move`/`Branch_Zero`/`Jump` arrière), `compiler/backends/x64/regalloc.odin:14-19`
  (étendre les intervalles de vie jusqu'à la fin de boucle).
- **Bytecode** : aucun opcode nouveau (`bytecode/bytecode.odin:241-243` l'annonce déjà).
- **Test unitaire** : `countdown{n -> ??::u64}!` compile et rend le bon résultat pour plusieurs
  entrées — aujourd'hui il rend une constante fausse (D8).
- **Régression** : la liveness devient non linéaire ; toute la suite `test/codegen` est exposée.
  C'est le jalon le plus risqué du plan.
- **Test d'intégration débloqué** : **la boucle d'événements. Le périmètre A est complet.**
- **Fin** : une fenêtre GLFW s'ouvre, réagit au déplacement et se ferme sur le bouton de
  fermeture.

### J8 — Arène de scratch et matérialisation de struct · **§3 #15/#16/#17/#29**

- **Fichiers** : `compiler/backends/x64/elf.odin` (constante `SCRATCH_VADDR` sur le modèle
  d'`ARGS_TABLE_VADDR`, `elf.odin:57-60`, et extension de `memsz`, `elf.odin:110`) ;
  `compiler/type.odin` (`c_layout(scope) -> (size, align, offsets)`) ;
  `compiler/bytecode.odin` (nouveau `BC_Materialize{dst, offsets, values}`) ;
  `compiler/backends/x64/emit.odin` (suite de `mov [scratch+off], reg` puis adresse en registre).
- **Piège identifié** : le layout doit lire la **contrainte** de la liaison
  (`Scope_Type.constraint_folds`, `ir.odin:93`, via `cast_target`, `type.odin:873`), **pas** la
  valeur — `machine_type_of` (`bytecode.odin:57-60`) réduit `u32:sType -> 0` à `U8` d'après la
  valeur, ce qui produirait un layout faux.
- **Règles ABI** : layout C — ordre de déclaration, alignement naturel par champ, padding de
  queue jusqu'à l'alignement de la struct.
- **Test unitaire** : `test/codegen` — comparer `c_layout(VkApplicationInfo)` aux offsets
  attendus (0, 8, 16, 24, 32, 40, 44 ; taille 48).
- **Test d'intégration** : `vkCreateInstance` avec `pInstance = NULL` — l'appel doit renvoyer
  `VK_ERROR_INITIALIZATION_FAILED` plutôt que crasher, ce qui prouve que la struct a été lue.
- **Fin** : une struct Vulkan est reconstruite octet pour octet, comparable à un dump C.

### J9 — Adresse d'un littéral et tableau de chaînes constant · **§3 #12/#14**

- **Fichiers** : `compiler/bytecode.odin` (poser des blobs `.rodata` non-chaîne),
  `compiler/backends/x64/emit.odin:98-112` (les vaddr sont connues avant émission : un blob
  contenant des adresses est constructible sur place).
- **Test** : `pQueuePriorities` pointe sur un `f32` valant 1.0 ; `ppEnabledExtensionNames`
  pointe sur un tableau d'une adresse pointant sur `"VK_KHR_swapchain\0"`.
- **Fin** : `vkCreateDevice` accepte l'extension swapchain.

### J10 — Cellules de sortie `Out{T}` · **§4.2**

- **Fichiers** : bibliothèque source (`Out` est un scope Syntact ordinaire) ;
  `compiler/reduce.odin` (construire une production composite pour un `Foreign_Call_Type`
  portant des `Out`) ; `compiler/bytecode.odin` (`BC_Load{dst, base, off, width}`) ;
  `compiler/backends/x64/emit.odin` (`mov reg, [scratch+off]` avec extension de largeur).
- **Bytecode** : **premier opcode de lecture mémoire du projet.**
- **Test unitaire** : un externe libc à paramètre de sortie — `mbstowcs`-like, ou plus simple
  `sscanf("42\0", "%d\0", Out{i32}:v)` — et vérifier `v == 42`.
- **Test d'intégration débloqué** : `vkCreateInstance` rend un `VkInstance` non nul ;
  `glfwCreateWindowSurface` rend une surface. **Le périmètre B est complet.**
- **Régression** : la production d'un appel externe cesse d'être scalaire — tout consommateur
  de `Foreign_Call_Type.production` est concerné (`type.odin:320`, `bytecode.odin:271`).
- **Fin** : `vkGetDeviceQueue` rend une queue non nulle.

### J11 — Relecture d'agrégat et buffers de taille fixe · **§3 #19/#20**

- Généralisation directe de J10 : `Out{Scope}` relit champ par champ selon `c_layout` ;
  `Out{Array{T, N}}` réserve `N × sizeof(T)` et relit par index constant.
- **Test d'intégration débloqué** : `vkGetPhysicalDeviceSurfaceCapabilitiesKHR`,
  `vkGetSwapchainImagesKHR`.

### J12 — Périmètre C

Avec J1–J11, il ne reste que du volume de binding : ~16 symboles, ~10 structs, la boucle de
frame. Utiliser `vkCmdPipelineBarrier2` pour rester sous 6 arguments.

### J13 et au-delà — généralisation

Arguments sur la pile + `Abi` record (`abi.md` §2.3), `f32` en registre, `sret`, agrégats deux
registres, callbacks, `@platform`, générateur de bindings depuis `vk.xml`.

---

## 8. Chemin critique

### Bloquants obligatoires

Sans ceci, aucun slice viable — y compris le périmètre A.

1. **Préservation des registres caller-saved** (D1, J1). Sans cela, aucun programme à plus d'un
   appel externe n'est correct. **Le blocage n°1, et il n'est documenté nulle part.**
2. **Séquencement des effets** (§4.3, J4). Il n'existe aujourd'hui aucune construction dont la
   loi garantisse l'ordre de deux effets.
3. **Boucle** (§4.4, J7). Une boucle d'événements est constitutive de tout programme graphique.
4. **Effet préservé sous un pattern** (D3, J5) et **gardes semi-ouvertes** (D4, J6). Le test de
   la boucle passe par les deux.
5. **Terminaison NUL** (D2, J3). Toute API graphique prend des `const char*`.

Puis, pour le périmètre B :

6. **Matérialisation de struct** (J8) — mécanique, déjà exprimable.
7. **Cellules de sortie** (J10) — une décision de coloration, puis mécanique.
8. **Adresse de littéral / tableau constant** (J9) — mécanique.

### Capacités différables

Sans effet sur le premier résultat visuel : callbacks · function pointers appelables ·
`vkGetInstanceProcAddr` · arguments sur la pile (>6) · `sret` · agrégats deux registres ·
unions comme construction · chaînes `pNext` · `f32` en registre · `usize`/`isize` ·
allocateurs Vulkan personnalisés · tableaux de taille dynamique · versionnement de symboles ·
`@platform` et le nommage par cible · `.gnu.hash` · vérification d'existence des symboles ·
non-Linux, non-x86-64 · résonance et réactivité · événements et handlers.

### Décisions à prendre immédiatement

Trois, et trois seulement. Toutes les autres questions ouvertes d'`interop.md` §2 se révèlent
soit sans objet, soit contournables mécaniquement pour ce programme.

1. **Une liaison non-production dont la valeur porte un effet est-elle évaluée dans l'ordre de
   déclaration ?** (§4.3) — recommandation : **oui**. C'est la seule décision qui touche la loi
   du langage plutôt que la frontière ; sans elle, il n'y a pas de séquencement.
2. **Comment se déclare un paramètre de sortie ?** (§4.2) — recommandation : `Out{T}:` comme
   scope ordinaire de coloration, production de l'appel devenant un scope. Aucun type pointeur.
3. **Un champ coloré par un scope est-il inline ou par adresse ?** (§6, `VkInstanceCreateInfo`)
   — le C a besoin des deux. Recommandation : le scope nu est **inline** (structure imbriquée
   par valeur, ce que la règle de taille d'`effects.md` suggère déjà), et `Ref{T}:` marque le
   passage par adresse — symétrique de `Out{T}:`, même mécanisme.

Ne sont **pas** des décisions bloquantes, contrairement à ce que suggère `interop.md` §2 :
l'identité de cellule (Q1), la direction d'écriture comme résonance (Q2), le statut d'`Address`
(Q3), mémoire-valeur ou mémoire-effet (Q4), l'ownership (Q5). Le slice n'en a besoin d'aucune.

---

## 9. Estimation

Unité : jour-ingénieur sur cette base de code, hors imprévu.

### Travail mécanique — aucune décision requise

| Jalon | Charge | Risque |
|---|---|---|
| J1 clobbers caller-saved | 1–2 | moyen (touche l'allocateur) |
| J2 alignement de pile | 0,5 | faible |
| J3 terminaison NUL | 0,5 | faible |
| J5 effet sous pattern | 0,5 | faible |
| J6 gardes semi-ouvertes | 0,5 | faible |
| J7 récursion → boucle | **3–5** | **élevé** — liveness non linéaire, expose `test/codegen` |
| J8 arène + layout C + matérialisation | 3–4 | moyen |
| J9 adresse de littéral, tableau constant | 1 | faible |
| J11 relecture d'agrégat, buffers fixes | 2 | moyen |
| J12 volume de binding périmètre C | 3–4 | faible mais fastidieux |
| **Total mécanique** | **15–22** | |

### Décisions de langage

| Décision | Décision | Implémentation |
|---|---|---|
| Ordre des liaisons effectuées (§4.3, J4) | 0,5 | 2–3 |
| Forme du paramètre de sortie (§4.2, J10) | 0,5 | 2–3 |
| Champ scope : inline ou `Ref` (§6) | 0,5 | inclus dans J8 |
| **Total décisions** | **1,5** | **4–6** |

### Généralisation ultérieure

Non nécessaire au premier résultat visuel : `Abi` record + arguments sur la pile (3–4) ·
callbacks avec frame ABI réelle (5–8, et interagit avec le hot reload, `targets.md` §10) ·
`sret` et agrégats deux registres (2–3) · `f32` en registre (0,5) · générateur de bindings
depuis `vk.xml` (3–5) · `@platform` et nommage par cible (2–3). **Total : 15–25.**

**Le programme complet, de zéro à un triangle, se situe autour de 25–35 jours** — dont **1,5
jour de décisions**. Cela confirme la formule de conclusion d'`interop.md` §7 (« ce qui sépare
ceci d'un vrai interop est une décision, pas un volume de code »), mais en corrige le contenu :
la décision qui manque n'est pas celle du modèle mémoire, ce sont **l'ordre des effets** et
**la forme du paramètre de sortie**.

---

## 10. Recommandation

**Premier jalon à implémenter : J1 — la préservation des registres caller-saved autour d'un
appel externe.**

Raisons :

1. **C'est un défaut de correction, pas une fonctionnalité manquante.** Le compilateur émet
   aujourd'hui du code faux dès le deuxième appel externe, sans aucun diagnostic, avec une
   défaillance dépendant de la bibliothèque appelée. Tout travail bâti par-dessus serait
   débogué contre un socle non fiable.
2. **C'est le préalable de tout le reste.** Séquencement, boucle, structs, cellules de sortie :
   chacune de ces capacités multiplie le nombre d'appels et de valeurs vivantes à travers eux.
3. **C'est petit, local et testable seul** — 1 à 2 jours, deux fichiers, avec un reproducteur
   déterministe déjà écrit (§1.2) et un oracle immédiat (le programme SDL cesse de segfauter).
4. **Cela rend honnête la liste des sept bibliothèques d'`interop.md` §1**, qui ne teste que des
   appels uniques et laisse croire que le chemin externe est solide.

**Puis, dans l'ordre : J3, J5, J6, J2** (quatre correctifs d'un demi-jour, tous locaux, tous
avec un test unitaire évident), **puis J4** (première décision de langage, celle du
séquencement), **puis J7** (la boucle — le plus gros risque, à isoler).

À l'issue de cette séquence — environ **7 à 11 jours** — une fenêtre GLFW s'ouvre depuis un
programme Syntact, traite ses événements et se ferme proprement : le **périmètre A complet**,
sans une seule ligne de matérialisation mémoire, et avec cinq défauts de correction du
compilateur réparés au passage.

Le travail mémoire (J8–J11), qui est ce que l'on croit spontanément être le blocage, vient
**après** — et il se révèle nettement plus mécanique qu'`interop.md` ne le laisse penser, parce
que l'analyseur sait déjà typer et replier une struct de style C (§1.5 B) et que l'infrastructure
d'adresse absolue existe déjà (§1.5 A).
