# kenbi

[English](README.md) · [简体中文](README.zh.md) · [日本語](README.ja.md) · [Español](README.es.md) · [Português](README.pt.md) · **Français** · [Deutsch](README.de.md)

**kenbi vérifie que le code C et C++ respecte les règles de sûreté mémoire qu'il déclare.** Vous écrivez en commentaire, à côté du code, qui possède un tampon, qui le libère et combien de temps dure un emprunt ; kenbi vérifie, statiquement et sur chaque chemin, que le code fait ce que disent ces commentaires. Ce n'est pas un compilateur et il ne modifie pas votre build.

**Conçu pour écrire du C/C++ avec des agents IA.** Grâce à son [serveur MCP](#avec-des-agents-de-programmation-ia-mcp), un agent vérifie le C/C++ qu'il vient d'écrire, demande pourquoi un constat apparaît et à quoi ressemble la correction, et recommence jusqu'à ce que les vérifications ne signalent plus rien. La sûreté mémoire devient une partie de la boucle d'écriture de l'agent plutôt qu'une revue après coup, et les annotations qu'il écrit restent dans le code comme des règles que kenbi continue de vérifier.

> Statut : **v0.1.0**, développement précoce. Les interfaces, le vocabulaire d'annotations et la
> sortie JSON peuvent encore changer.

## Un premier aperçu

[`demo/quickstart.c`](demo/quickstart.c):

```c
// @kenbi
#include <stdlib.h>
#include <string.h>

/* @mem app::buf { alloc: malloc, free: free } */

char *dup_name(const char *s) {
  char *p = malloc(strlen(s) + 1);
  if (!p) return NULL;
  strcpy(p, s);
  if (p[0] == '\0') return NULL;  /* leaks p */
  return p;
}
```

```console
$ ./kenbi demo/quickstart.c
demo/quickstart.c:8: error: leak: 'app::buf' allocated here is never freed or moved [LEAK]
  checked: ownership; not checked: bounds, locks, initialisation, tagged unions
── kenbi coverage ───────────────────────────
  memory-relevant functions : 1
  GREEN (contracted)        : 0  (0%)  ← boundaries declared, modular-trust
  verified (no trust residue): 0  (0%)  ← whole closure covered
  adopted (@kenbi)          : 1  (100%)
  RED (needs fixing)        : 1  (separate from coverage — fix these)
```

`@kenbi` place le fichier sous la vérification de possession, et `@mem` déclare un type de ressource et la manière dont il est alloué et libéré. Remplacez le retour anticipé par `{ free(p); return NULL; }` et le fichier signale `ok — no findings from the checks that ran`, avec le code de sortie 0. La ligne `checked:` fait partie de chaque résultat : l'absence de constat ne couvre que les vérifications qu'elle énumère.

## Ce qui le distingue

- **Déclaré, pas déduit.** kenbi ne devine pas ce que signifie le code. Il le vérifie par rapport à ce que déclarent les annotations ; un constat est donc un endroit où le code s'écarte d'une règle énoncée, pas un motif qui semble suspect.
- **Non prouvé n'est pas vert.** Là où kenbi ne peut pas montrer que chaque chemin respecte les règles, il signale un constat, et ce qu'il ne sait pas modéliser (un `goto` en arrière, par exemple) il le signale aussi au lieu de l'ignorer. Un résultat sans constat est l'affirmation dont kenbi se porte garant.
- **Chaque chemin, sans exécuter le code.** Les sanitizers et les tests voient les chemins exécutés ; kenbi suit chaque chemin à travers les boucles, les retours anticipés, les échelles de nettoyage par `goto` et les exceptions C++.
- **Déterministe, avec sa portée indiquée.** La même entrée donne la même sortie, et chaque résultat nomme les vérifications exécutées, les contrats sur lesquels il repose et chaque `@unsafe` qui a fait taire un constat.
- **Adoptable progressivement.** Chaque vérification s'active séparément, par fichier, fonction ou bloc, pour que le code existant ne devienne pas un mur de rouge.

## Avec des agents de programmation IA (MCP)

Le [serveur MCP](mcp/README.md) donne à un agent le vérificateur et de quoi agir en conséquence :

| | ce que l'agent reçoit |
|---|---|
| `check_memory_safety` | les constats de kenbi, avec un résumé qui indique quelles vérifications ont porté sur quelles fonctions, pour qu'« aucun constat » ne soit jamais lu comme « sûr » |
| `explain_finding` | pour un code de constat ou un identifiant CWE : ce qui le déclenche, pourquoi une demi-correction échoue encore, et la correction avec le contrat qu'elle déclare |
| `kenbi://annotations` | la référence des annotations |
| `kenbi://patterns` | les formes C/C++ sûres que kenbi accepte, à côté des formes dangereuses qu'il rejette |

La boucle est écrire → vérifier → expliquer → corriger → revérifier, et c'est kenbi, pas le modèle, qui décide quand elle est terminée. Le serveur demande aussi à l'agent de ne pas répéter en commentaire ce qu'une annotation dit déjà : l'annotation est vérifiée, un commentaire ne l'est pas.

La boucle sur [`demo/quickstart.c`](demo/quickstart.c), avec les réponses réelles du serveur (chaque résumé est suivi du document JSON complet de kenbi, omis ici) :

1. L'agent écrit `dup_name` et appelle `check_memory_safety` :

   ```text
   kenbi: 1 error(s), 0 warning(s) across 1 file(s):
     demo/quickstart.c:8: error: leak: 'app::buf' allocated here is never freed or moved [LEAK]

   Scope — the result covers only this:
     - ownership, lifetime and null (`@kenbi`, or a file with no marker): checked in every function
     - NOT checked anywhere: bounds (`@spatial`); locks (`@threadsafe`); initialisation (`@initcheck`); tagged unions (`@typecheck`)
     - verified (nothing taken on trust): 0 of 1 adopted memory-relevant functions
     - code the preprocessor excluded under these flags was not analysed
   ```

2. Il appelle `explain_finding` avec `LEAK` et reçoit des exemples détaillés ; le premier se termine par la correction :

   ~~~text
   # Fixing `LEAK`  (CWE-401 · ownership axis · contracts: @mem)
   Intent: free on every path, including early returns. Free obligation skipped on an early-return branch.

   ## A — what triggers it (RED)            …
   ## B — why a half-fix stays RED           …
   ## C — the fix (GREEN)
   ```c
   // @kenbi
   #include <stdlib.h>

   void CWE401_Memory_Leak__branch_early_return_02_fixed(int c)
   {
       /* @mem g::buf { free: free, owner: data } */
       char * data = (char *)malloc(100);
       if (data == NULL) { return; }
       /* FIXED: free on the early-return path too */
       if (c) { free(data); return; }
       free(data);
   }
   ```
   ~~~

3. Il libère `p` lors du retour anticipé (`if (p[0] == '\0') { free(p); return NULL; }`) et vérifie à nouveau :

   ```text
   kenbi: no findings in 1 file(s) from the checks that ran. This is not a statement about anything outside the scope below.

   Scope — the result covers only this:
     - ownership, lifetime and null (`@kenbi`, or a file with no marker): checked in every function
     - NOT checked anywhere: bounds (`@spatial`); locks (`@threadsafe`); initialisation (`@initcheck`); tagged unions (`@typecheck`)
     - verified (nothing taken on trust): 1 of 1 adopted memory-relevant functions
     - code the preprocessor excluded under these flags was not analysed
   ```

[`integrations/agent/`](integrations/agent/) contient les instructions correspondantes pour Claude Code (`SKILL.md`), les agents de type Codex (`AGENTS.md`) et GitHub Copilot.

La configuration est décrite dans [`mcp/README.md`](mcp/README.md#configure-in-an-mcp-client).

## Ce qui est vérifié

Chaque vérification s'active séparément :

| axe | activation | ce qui est vérifié |
|---|---|---|
| propriété / durée de vie | `@kenbi` (ou un fichier sans marqueur) | use-after-free, double free, fuites à chaque sortie, use-after-move, mauvais désallocateur, retours pendants, durées de vie des emprunts et des arènes, contrats déclarés confrontés aux corps de fonction, propriétaires RAII C++, pointeurs intelligents et chemins d'exception |
| null | toujours, avec `@nullable` / `@nonnull` | déréférencement d'un pointeur possiblement null ou connu comme null, avec rétrécissement sensible au flux |
| bornes | `@spatial` | un index ou une taille non fiable qui atteint un tampon exige une vérification de borne présente, suffisante et sans débordement arithmétique ; `@counted_by` et invariants de structures de données déclarés (`@invariant` / `@maintains`) |
| initialisation | `@initcheck` | une variable locale lue avant d'être affectée sur tous les chemins |
| unions étiquetées | `@typecheck` + `@variant` | un membre d'union utilisé là où son étiquette n'est pas prouvée |
| verrous | `@threadsafe` | accès non protégé, verrous non équilibrés, ordre de verrouillage déclaré (interblocage AB-BA) |
| propriétés bas niveau | `--safety=project.json` | effets interdits dans une fermeture d'appels, machines à états de ressources, profondeur de pile et d'appels, régions mémoire, MMIO et plus — voir [Vérification bas niveau configurée](#vérification-bas-niveau-configurée---safety) |

Un front-end libclang abaisse (« lowering ») du C / C++ réel (en lisant `compile_commands.json`)
vers un moteur de typestate. Les boucles sont analysées jusqu'à un point fixe borné ; les échelles
de nettoyage par `goto` avant, `break` / `continue` et `try` / `catch` sont modélisés, et tout ce
que kenbi ne peut pas modéliser est signalé plutôt qu'ignoré. La sortie est du texte ou
`--format=json`.

## Démarrage rapide

```sh
# Debian / Ubuntu; for other systems see "Installer libclang selon l'OS" below.
# Nim 2.2 or later: https://nim-lang.org/install.html
sudo apt-get install libclang1-14 libclang-common-14-dev
git clone https://github.com/puffball1567/kenbi
cd kenbi
nimble build -d:release
./kenbi demo/quickstart.c
```

## Prérequis

- **Nim** >= 2.2 ([installation](https://nim-lang.org/install.html))
- **libclang** (la bibliothèque partagée ; les en-têtes `clang-c` ne sont *pas* nécessaires —
  seul le `.so` / `.dylib` / `.dll` d'exécution, chargé dynamiquement au démarrage).
- **les en-têtes intégrés de clang** (`stddef.h`, `stdarg.h`, …), dont libclang a besoin pour
  analyser tout fichier qui en inclut un. La plupart des paquets clang/LLVM les installent avec la
  bibliothèque ; sous Debian et Ubuntu, c'est le paquet séparé `libclang-common-N-dev`.

libclang est chargée par son soname à l'exécution ; la liste de recherche par défaut couvre
`libclang.so`, `libclang-13..18.so`, etc. Si votre bibliothèque a un nom ou un chemin différent,
remplacez-le à la compilation :

```sh
nimble build -d:release -d:kenbiLibclang=/full/path/to/libclang.so
```

## Compilation et tests

```sh
nimble build          # produces ./kenbi
nimble test           # mini-format engine suite (no libclang needed)
nimble testc          # libclang suite on real C / C++  (needs libclang)
nimble testsafety     # --safety suites (needs libclang and python3)
nimble testall        # everything

# or directly:
nim c -d:release -o:kenbi src/kenbi.nim
./kenbi path/to/file.c
./kenbi path/to/file.cpp
./kenbi tests/t01_double_free.mc       # mini-format
```

### Installer libclang selon l'OS

**Ubuntu / Debian**
```sh
sudo apt-get install libclang1-14 libclang-common-14-dev
# libclang1-14 is the library (/usr/lib/x86_64-linux-gnu/libclang-14.so.1, found by default);
# libclang-common-14-dev holds clang's builtin headers (stddef.h, stdarg.h, ...). Without
# them every file that includes one fails to parse, and kenbi reports it unanalysed (exit 2).
# If unresolved, point at it explicitly:
nimble build -d:release -d:kenbiLibclang=/usr/lib/llvm-14/lib/libclang.so
```

**Fedora / RHEL**
```sh
sudo dnf install clang-libs               # provides /usr/lib64/libclang.so.*
```

**Arch**
```sh
sudo pacman -S clang                      # /usr/lib/libclang.so
```

**macOS** (Homebrew LLVM, ou les Xcode Command Line Tools)
```sh
brew install llvm
nimble build -d:release -d:kenbiLibclang="$(brew --prefix llvm)/lib/libclang.dylib"
# Apple's Command Line Tools also ship a libclang at
#   /Library/Developer/CommandLineTools/usr/lib/libclang.dylib
```

**Windows** (MSVC + version LLVM)
```bat
:: install LLVM from https://releases.llvm.org and ensure libclang.dll is on PATH
nimble build -d:release -d:kenbiLibclang=libclang.dll
```

## Utilisation

```
kenbi [--format=text|json] [--compile-commands=PATH] [--project[=PATH]] [--emit-contracts]
      <file> [more...] [-- <extra clang args>]
kenbi [--format=text|json] --safety=project.json
kenbi --version
```

- `kenbi --version` affiche la version de kenbi et la libclang qu'il a chargée.
- `*.c *.cc *.cpp *.cxx` → front-end libclang (C ou C++ choisi par l'extension).
- `*.mc` → mini-format.
- Pour le C/C++, les drapeaux d'analyse proviennent de `compile_commands.json` : passez-le avec
  `--compile-commands=PATH`, ou il est découvert automatiquement en remontant depuis le fichier
  source. Tout ce qui suit `--` est ajouté à la ligne de commande clang.
- `--project[=compile_commands.json]` analyse chaque unité de traduction listée par la base. Les
  résultats de chaque fichier restent les siens (les annotations ont la portée du fichier, et
  l'analyse aussi) — ce que cela ajoute, c'est la **fermeture** : un appel sous contrat vers une
  fonction définie dans une autre unité analysée se résout au verdict de cette unité, de sorte
  qu'un GREEN dont toute la fermeture de dépendances est analysée et GREEN compte comme
  *vérifié* (*verified*), et la frontière de confiance se réduit à ce que rien dans le projet ne
  définit (une bibliothèque livrée sous forme binaire, le système d'exploitation, une frontière
  FFI). Sans chemin, la base est trouvée en remontant depuis le premier fichier donné.
- `--format=json` émet des résultats lisibles par machine avec des codes stables (pour la CI,
  les éditeurs et les agents) ; `--format=text` (par défaut) est lisible par un humain.
- `--safety=project.json` exécute les vérifications bas niveau configurées décrites dans
  [Vérification bas niveau configurée](#vérification-bas-niveau-configurée---safety).
- Code de sortie : `0` propre · `1` problèmes détectés · `2` erreur d'usage / d'analyse.


## Activation : fichier, fonction ou bloc

`@kenbi` marque ce qui est sous discipline — les résultats en dehors sont écartés, si bien que
l'adoption est progressive et ne se traduit jamais par un mur de rouge. Le marqueur s'attache à
ce qui se trouve juste en dessous :

```c
// @kenbi                    ← at the top of a file: every function in it
// @kenbi
void f(void) { … }           ← above a function: that function

void huge(void) {            ← a function too large to clean up at once
  …                          ← neutral, as in any unadopted function
  // @kenbi
  {                          ← above a block or an if/for/while/switch: that statement
    char *p = malloc(8);     ← checked
  }
  …                          ← neutral again
}
```

Un bloc sous discipline ne place **pas** sa fonction sous discipline : ces blocs sont comptés et
signalés sur leur propre ligne (`blocks adopted`), jamais intégrés au nombre de fonctions
adoptées.

## Livrer des contrats pour une bibliothèque

Une surcouche de contrats (overlay) est un fichier de commentaires — elle peut être publiée à
côté d'une bibliothèque, ou écrite par un consommateur pour une bibliothèque qui n'a jamais
entendu parler de kenbi. Dans les deux cas, le destinataire doit savoir ce qu'elle décrit ; la
surcouche le dit donc, et kenbi vérifie ce qu'il peut :

```c
// @contracts_for ImageMagick { version: 7.1.2-27, requires: MAGICKCORE_QUANTUM_DEPTH=16 }
// @allocator magick::mem { alloc: AcquireQuantumMemory, free_returns_null: RelinquishMagickMemory }
// @contract qsort { borrows: $1 }
```

- `requires:` est **vérifié** par rapport à la ligne de compilation. Une compilation qui en
  contredit un est une erreur (`CONTRACT_PACKAGE_MISMATCH`) — ces contrats ont été écrits pour
  une autre compilation, donc ce qu'ils promettent peut ne pas tenir. Une condition que la ligne
  de compilation ne tranche pas est signalée comme *non vérifiée*, jamais comme satisfaite.
- `version:` est transmis comme **déclaré**. kenbi ne peut pas lire la version d'une
  bibliothèque à partir du source et ne prétend pas le faire ; le rapport indique « version
  declared, not verified ».

`--format=json` transporte l'ensemble (`contractPackages` avec `versionDeclared`, `requires`,
`mismatched`, `unverified`, `appliesToThisBuild`), afin qu'un consommateur puisse décider s'il
fait confiance à un ensemble de contrats avant de s'appuyer dessus.

### Publier un ensemble de contrats

`--emit-contracts` affiche la *surface* contractuelle de ce qui a été analysé, au lieu de le
vérifier — la forme qu'une bibliothèque livre pour qu'un autre outil (un autre vérificateur, un
générateur de bindings, le front-end d'un autre langage) puisse imposer aux appelants les
contrats de la bibliothèque sans relire ses commentaires :

```sh
kenbi --emit-contracts --project=build/compile_commands.json > imagemagick.contracts.json
```

```json
{ "kind": "contract-set",
  "packages":  [ { "name": "ImageMagick", "versionDeclared": "7.1.2-27", "appliesToThisBuild": true, … } ],
  "resources": [ { "name": "magick::mem", "alloc": ["AcquireQuantumMemory", …],
                   "free": ["RelinquishMagickMemory", …], "freesFields": ["DestroyKernelInfo", …] } ],
  "contracts": [ { "function": "DestroyKernelInfo", "effect": "@frees", "param": "$1",
                   "declaredBy": "overlay", "implementationSeen": true, "status": "verified" } ] }
```

`resources` est le vocabulaire alloc → free : un consommateur à qui l'on ne donne que les
désallocateurs ne peut pas savoir quel appel lui a transmis l'obligation au départ. Et chaque
contrat porte le `status` que cette exécution a établi pour l'implémentation qui le sous-tend,
car « un contrat est déclaré » ne doit pas pouvoir se lire comme « l'implémentation a été
vérifiée » :

| `status` | ce que l'exécution a établi |
|---|---|
| `declared` | aucune implémentation ici (un prototype, ou un contrat écrit de l'extérieur) — **rien n'a été vérifié** |
| `unchecked` | le corps est présent mais pas sous `@kenbi` : kenbi ne l'a pas vérifié |
| `red` | le corps est sous `@kenbi` et contredit ses contrats — ne pas s'y fier |
| `green` | vérifié et propre, mais reposant sur la confiance (un appelé sous contrat non couvert, ou un `@unsafe`) |
| `verified` | vérifié et propre, ainsi que toute sa fermeture sous contrat : aucun résidu |

Publier n'est pas vérifier : le document est affiché et le code de sortie vaut 0 même lorsque le
code présente des résultats. Pour les obtenir, lancez une exécution `kenbi` ordinaire.

## « GREEN » et « verified » sont des réponses différentes

Une annotation n'est pas une preuve, et le résultat de couverture le dit :

| | ce que cela signifie |
|---|---|
| `GREEN (contracted)` | les frontières sont déclarées — sûr *étant donné* les contrats sur lesquels il repose |
| `verified` | toute sa fermeture de dépendances sous contrat est aussi couverte : rien n'est pris sur la confiance |
| `trusted frontier` | les appelés non couverts sur lesquels un GREEN repose actuellement — couvrez-les pour la refermer |
| `@unsafe vouches` | les sites où l'auteur a affirmé ce que kenbi ne pouvait pas vérifier |

`verified` est un sous-ensemble strict de `GREEN`. Déclarer un contrat sur un appelé non couvert
fait passer une fonction de RED à GREEN et place cet appelé sur la frontière de confiance ; un
`@unsafe` qui supprime effectivement un résultat maintient la fonction GREEN et la tient
définitivement hors de `verified`, avec le site nommé. Ainsi, une opération que kenbi ne peut pas
vérifier ne peut jamais apparaître comme vérifiée parce que quelqu'un l'a annotée. Tout cela
figure dans `--format=json` (`green`, `verified`, `trustedFrontier`, `unsafeVouches`, et les
`flows` par point d'entrée avec leurs `blockers`).

```sh
kenbi --compile-commands=build/compile_commands.json src/img.c
kenbi --project=build/compile_commands.json          # the whole project, one closure
kenbi --emit-contracts src/*.c                       # publish the contract set instead
kenbi --format=json src/*.c
kenbi foo.cpp -- -Iinclude -DDEBUG
```

Le document JSON est `{ "version", "tool", "findings": [ { "file", "line",
"code", "severity", "message" } ], "coverage", "scope" }` ; les codes sont stables et l'ordre est déterministe. Les
échecs de lecture / d'analyse apparaissent comme des résultats `PARSE_ERROR`.
`scope` indique, pour chaque fichier analysé, quelles vérifications ont tourné sur quelles fonctions : pour
chacune de `ownership`, `bounds`, `locks`, `initialisation` et `taggedUnions`, un `mode` qui vaut `file` (toutes
les fonctions), `functions` (certaines, les autres étant nommées dans `unchecked`) ou `off`, ainsi que les blocs
adoptés par `@kenbi` dans des fonctions par ailleurs non vérifiées. Un fichier sans résultat n'est propre que dans
ce périmètre ; la sortie texte l'affiche sous chaque fichier.

## Annotations

Les ressources sont déclarées dans des commentaires et référencées par un nom à portée, unique
au projet. L'obligation porte sur l'*allocation* (son « origine »), pas sur la variable : les
copies l'aliasent, les pointeurs intérieurs en dérivent, et un `free` / move l'acquitte. Les
branches fusionnent de façon saine (un état est possible après une jonction s'il l'est sur
*l'une ou l'autre* des voies — libérer sur une seule voie laisse donc une fuite sur l'autre).

```c
/* @mem demo::buf { size: n, free: free, owner: p } */
char *p = malloc(n);     // alloc of demo::buf (p is the owner)
char *r = p + 16;        // interior pointer — inferred, must not be freed
consume(p);              // use
sink(p);  // @move demo::buf   — obligation transferred out; p is now moved-from
```

- **allocation** : une initialisation / affectation dont le membre droit est de la famille
  `malloc` ou un `new` C++ lie l'obligation à la variable cible.
- **libération** : `free(p)` ou `delete`/`delete[] p` en C++.
- **intérieur** : `p + off` dérive un pointeur intérieur dans la même origine.
- **alias** : `q = p` fait de `q` un alias de l'origine de `p`.
- **copy** : `// @copy <resource>` sur une affectation marque une copie *profonde* — un nouvel
  objet possédé indépendant, avec sa propre obligation, et non un simple alias.
- **move** : un appel sur une ligne portant `// @move` transfère l'obligation.
- **unsafe** : `// @unsafe` sur une ligne la met en quarantaine — les résultats y sont supprimés
  (vous en prenez la responsabilité). Un `@unsafe` qui ne couvre rien est signalé comme
  `STALE_UNSAFE`, comme une désactivation de lint inutile.
- **sûreté du null** : `// @nullable` (ou `@nonnull`) sur une déclaration indique si un pointeur
  peut être null ; déréférencer un pointeur nullable sans vérification de null (`if (p)`,
  `if (p != NULL)`, `return` anticipé) est `NULL_DEREF` — la discipline `Option<T>`, sensible au
  flux avec rétrécissement par branche.
- **contrat frees** : `// @frees(param)` au-dessus d'une fonction déclare qu'elle libère cet
  argument. Les sites d'appel traitent alors l'appel comme le libérant (il se compose donc avec
  double-free / fuite), et le corps de la fonction est lui-même vérifié — s'il ne libère pas
  réellement le paramètre, c'est `CONTRACT_NOT_HONORED` (intention déclarée vs. implémentation,
  qu'un outil sans annotations ne peut pas vérifier).
- **retour must-use** : `// @must_use` au-dessus d'une fonction déclare que son résultat doit
  être consommé ; un appel dont la valeur est abandonnée (une instruction nue, ni affectée /
  retournée / passée / testée) est `UNUSED_MUST_USE` — la discipline `#[must_use]` pour les codes
  d'erreur ignorés et les allocations qui fuient.

### Vocabulaire de goto (optionnel — déclarer l'intention structurée d'un goto)

Les gotos avant courants sont modélisés automatiquement (sans annotation) : une échelle de
nettoyage avant (`if(!p) goto fail; … fail: free()`) est analysée par fusion à la jonction, et
un goto avant sortant d'une boucle/switch vers un label de nettoyage est admis. Une boucle-goto
*arrière*, un saut vers un label imbriqué ou un goto calculé restent refusés
(`UNSTRUCTURED_GOTO`) — sûrs par refus. Le vocabulaire optionnel vous permet de déclarer la
signification structurée d'un goto pour que kenbi le modélise et en contrôle la forme :

- `// @goto_noreturn` sur un label marque un terminus sans retour (abort / exit / longjmp) : un
  chemin qui l'atteint se termine, donc ses obligations encore possédées sont acquittées — un
  chemin d'abandon n'est pas une fuite (supprime les fausses fuites sur les chemins d'abandon en
  erreur).
- `// @goto_finally` sur un label marque l'entonnoir de convergence du nettoyage. Discipline
  opt-in à entonnoir unique : une sortie qui possède encore une ressource *sans* passer par
  l'entonnoir est `FINALLY_BYPASSED` (`goto <funnel>` pour que la libération s'y produise). La
  complétude de la fusion à la convergence reste l'analyse inférée habituelle.
- `// @goto_backward` sur un goto le déclare comme arête arrière de boucle : une simple
  boucle-goto est restructurée en do-while et analysée par le point fixe borné (de sorte que les
  dangers inter-itérations sont attrapés), au lieu d'être refusée.

### Bornes (`@spatial`)

`// @spatial` au-dessus d'une fonction ou au niveau du fichier active l'axe des bornes pour cette
portée. Un paramètre scalaire non fiable qui indexe un tampon, ou qui dimensionne une écriture
telle que `memcpy`, doit avoir une vérification de borne présente sur le chemin — une garde `if`,
une condition de boucle, `% n`, un écrêtage (clamp) ou un masque — sinon c'est
`UNVALIDATED_INDEX` / `UNVALIDATED_SIZE`. La vérification doit couvrir le tampon
(`INAPPROPRIATE_BOUND` si elle est présente mais trop lâche), un index signé exige aussi
`i >= 0` (`INDEX_MAYBE_NEGATIVE`), et l'arithmétique de la garde ne doit pas déborder :
`i + 4 <= n` sur un `i` non signé n'est pas reconnu ; `n >= 4 && i <= n - 4` l'est. kenbi
recherche la vérification sur le chemin ; il n'en supprime jamais aucune.

- `// @counted_by(<buf>: <len>)` au-dessus d'une fonction donne sa taille à un paramètre
  pointeur, également sous forme de champ (`b->buf: b->cap`) ou de masque de tampon circulaire
  (`b->mask + 1`).
- `// @invariant(<field> <rel> <size>)` déclare un invariant de structure de données (par
  exemple `parser->toknext <= num_tokens`). Le champ est alors protégé : chaque écriture dans ce
  champ exige `// @maintains(...)`, que kenbi vérifie (`UNGUARDED_INVARIANT_WRITE`,
  `INVARIANT_NOT_MAINTAINED`), et un index borné par le champ est couvert via la relation.

### Initialisation (`@initcheck`) et unions étiquetées (`@typecheck`)

- `// @initcheck` au-dessus d'une fonction ou au niveau du fichier : une variable locale scalaire
  ou pointeur déclarée sans initialiseur doit être affectée sur tous les chemins avant d'être
  lue, sinon `USE_OF_UNINITIALIZED`.
- `// @typecheck` plus `// @variant(<member>: <tag> == <value>)` pour chaque membre d'union :
  utiliser un membre sur un chemin où son étiquette n'est pas prouvée (`if (n->tag == 1)`, ou
  `case 1:` sur l'étiquette) est `TYPE_CONFUSION`.

### C++

`// @raii` (ou `// @raii(Name)`) marque une classe dont le destructeur libère ce qu'elle possède,
et kenbi vérifie que le destructeur le fait. Copier une telle classe sans ses propres opérations
de copie est `MISSING_COPY_CONTROL`, et un `operator=` qui libère avant de lire sa source est
`SELF_ASSIGN_UNSAFE`. Détruire un objet dérivé par `delete` via une classe de base sans
destructeur virtuel est `DELETE_NONVIRTUAL_BASE`. `std::unique_ptr` / `std::shared_ptr`, `std::move`, `.get()` /
`.release()` / `.reset()`, les lambdas et les chemins d'exception (`LEAK_ON_THROW`, `try` /
`catch`, `noexcept` / `// @nothrow`) sont modélisés. La référence complète est servie par le
serveur MCP sous le nom `kenbi://annotations` ([source](mcp/src/annotations.ts)).

### Annotations de concurrence (vérifiées sous `@threadsafe`, consultatives en dehors)

Dans une portée `@threadsafe` (fonction ou fichier), elles sont **vérifiées**, en default-red,
par la passe de typestate de détention de verrou :

- `// @guarded_by(<field>: <lock>)` (sur une fonction) ou `// @guarded_by(<lock>)` (sur un
  membre de struct) : un accès sans que le verrou soit prouvablement détenu est
  `UNGUARDED_ACCESS` ; prendre l'adresse du champ protégé est `GUARDED_ESCAPE`.
- équilibre des verrous : `LOCK_LEAKED` / `DOUBLE_LOCK` / `UNLOCK_WITHOUT_LOCK`.
- `// @acquires(<lock>)` / `// @releases(<lock>)` : vérifiés dans le corps
  (`LOCK_NOT_ACQUIRED`) et pris en compte aux sites d'appel ; `// @requires_lock(<lock>)` sur un
  appelé : `REQUIRED_LOCK_NOT_HELD`.
- `// @lock_order(<a> < <b>)` : `LOCK_ORDER_VIOLATION` (interblocage AB-BA — une garantie que
  Rust n'offre pas) ; des déclarations contradictoires sont `LOCK_ORDER_CONFLICT`.
  `// @lock_class(<X>)` nomme l'identité d'un verrou pour que les ordres et les contrats
  correspondent entre fonctions et fichiers ; deux instances d'une même classe exigent un ordre
  canonique (`SAME_CLASS_NO_ORDER`).
- `// @calls(<fn>, ...)` sur un pointeur de fonction : ses cibles déclarées ; un appel indirect
  non déclaré sous un verrou est `UNDECLARED_INDIRECT_CALL`, une affectation hors de l'ensemble
  `UNDECLARED_FN_TARGET`.

En dehors d'une portée `@threadsafe`, kenbi les analyse et les émet avec
`severity: "advisory"` (`GUARDED_BY`, `REQUIRES_LOCK`, `ACQUIRES`, `RELEASES`, `LOCK_ORDER`) ;
**les résultats consultatifs ne bloquent jamais la compilation** — ce sont des directives pour un
relecteur IA/humain. `// @llm <freeform>` → `LLM_REVIEW` est une instruction en texte libre
indiquant au relecteur ce qu'il doit vérifier.

### Mini-format (fixtures du moteur)

```
@mem <scoped::name> { size: <id>, free: <id>, owner: <id> }
alloc <var> <resource> | copy <dst> <src> | interior <dst> <src> <off>
use <var> | free <var> | move <var> | if / else / endif
```

## Détecté aujourd'hui

Déterministe (`error` / `warning`) : `DOUBLE_FREE`, `USE_AFTER_FREE`,
`USE_AFTER_MOVE`, `LEAK`, `FREE_INTERIOR`, `MOVE_INTERIOR`, `FREE_AFTER_MOVE`,
`MOVE_AFTER_FREE`, `DOUBLE_MOVE`, `WRONG_DEALLOCATOR`, `NULL_DEREF` (d'un pointeur possiblement
null, et — signalé séparément — d'un pointeur dont kenbi sait qu'il EST null :
`free(p); p = NULL; *p`, ou une lecture après une libération déclarée comme renvoyant NULL),
`CONTRACT_NOT_HONORED`, `UNUSED_MUST_USE`, `DANGLING_RETURN` (retour d'un pointeur vers un local
/ d'un pointeur libéré), `BORROW_FREED` (un objet `@borrows` / d'arène libéré individuellement),
`BORROW_OUTLIVES_OWNER` (utilisation après la disparition du propriétaire / de l'arène),
`UNCONTRACTED_ESCAPE` / `UNCONTRACTED_RELEASE` (un pointeur possédé franchit une frontière
d'appelé / de libération qui ne déclare aucun contrat de propriété — la discipline default-red),
`UNSTRUCTURED_GOTO` (un goto arrière / imbriqué / calculé que kenbi refuse de modéliser),
`LOOP_FIXPOINT_LIMIT` (une boucle dont l'analyse ne converge pas dans sa limite d'itérations,
refusée plutôt que jugée sur une vue incomplète),
`LEAK_ON_THROW` (C++ : un propriétaire brut encore détenu là où un appelé sans garantie nothrow
— ou un simple `new` — peut déclencher un déroulement de pile ; les propriétaires RAII en sont
exemptés, `noexcept` / `@nothrow` / `-fno-exceptions` en sont les preuves ; à l'intérieur d'un
`try`, les sorties par déroulement aboutissent dans les gestionnaires, qui sont vérifiés à partir
de leur jonction),
`FINALLY_BYPASSED` (une sortie possédante contourne un entonnoir `@goto_finally` déclaré),
`FREE_NONHEAP` (un `free` d'un pointeur vers la pile ou un autre stockage hors tas),
`BORROW_MOVED` / `UNCONTRACTED_MOVE` (un move hors d'un emprunt, ou vers un appelé qui ne déclare
aucune prise en charge), `REALLOC_UNVERIFIED` / `REALLOC_SELF_REASSIGN` (un `realloc` dont
l'issue n'est pas établie avant utilisation, ou dont l'unique handle est écrasé),
`MISSING_COPY_CONTROL` / `SELF_ASSIGN_UNSAFE` / `DELETE_NONVIRTUAL_BASE` (C++), `UNSUPPORTED_CONSTRUCT` (une allocation ou
une libération dans une construction que kenbi ne modélise pas, refusée plutôt qu'écartée), ainsi
que les contrôles d'hygiène `UNKNOWN_RESOURCE` / `STALE_UNSAFE`. Sous les axes opt-in :
`UNVALIDATED_INDEX`, `UNVALIDATED_SIZE`, `INAPPROPRIATE_BOUND`, `INDEX_MAYBE_NEGATIVE`,
`UNGUARDED_INVARIANT_WRITE`, `INVARIANT_NOT_MAINTAINED` (`@spatial`), `USE_OF_UNINITIALIZED`
(`@initcheck`), `TYPE_CONFUSION` (`@typecheck`), et `UNGUARDED_ACCESS`, `GUARDED_ESCAPE`,
`LOCK_LEAKED`, `DOUBLE_LOCK`, `UNLOCK_WITHOUT_LOCK`, `LOCK_NOT_ACQUIRED`,
`REQUIRED_LOCK_NOT_HELD`, `LOCK_ORDER_VIOLATION`, `SAME_CLASS_NO_ORDER`,
`UNDECLARED_INDIRECT_CALL`, `UNDECLARED_FN_TARGET` (`@threadsafe`). Les boucles
(`for`/`while`/`do` et les boucles-goto déclarées) sont analysées par un **point fixe borné**
jusqu'à convergence, de sorte que les dangers inter-itérations sont attrapés ;
`break`/`continue` et les échelles de nettoyage par goto avant sont modélisés ; les fuites sont
vérifiées à chaque sortie de fonction.

Consultatif (sévérité `advisory`, ne bloque jamais — pour la couche de relecture) :
`GUARDED_BY`, `REQUIRES_LOCK`, `ACQUIRES`, `RELEASES`, `LOCK_ORDER`, `LOCK_ORDER_CONFLICT`,
`LLM_REVIEW`, `ESCAPE_UNCHECKED` (propriété stockée dans un champ que kenbi ne suit pas — la
frontière est mise au jour, pas silencieusement abandonnée), `POSSIBLE_DOUBLE_FREE` /
`POSSIBLE_USE_AFTER_FREE` (un appelé sans contrat dont le corps visible libère l'argument — un
indice jusqu'à ce que `@frees` soit déclaré, ce qui le confirme), `CONTRACT_UNBOUND` (un contrat
qui nomme un paramètre que la signature ne possède pas), et `UNKNOWN_VAR` (kenbi n'a enregistré
aucune origine pour un handle à cet endroit, donc rien n'y est vérifié — un signal d'alarme sur
la propre comptabilité interne de kenbi, jamais une affirmation sur le code).

## Démonstration : `unsafe` en Rust → vérifié, sans `@unsafe`, dans kenbi

Une liste doublement chaînée avec références arrière (`prev` *et* `next`) nécessite des
pointeurs bruts `unsafe` en Rust sûr (ou `Rc<RefCell<…>>`/`Weak`, vérifiés à l'*exécution*) : le
borrow checker ne peut pas exprimer la propriété partagée et cyclique des liens — la
`LinkedList` de la std est elle-même construite avec `unsafe`.

La même structure sous la discipline `@arena` de kenbi ([`demo/dll.c`](demo/dll.c)) se vérifie
**sûre en mémoire, sans `@unsafe`** :

```
$ kenbi demo/dll.c
demo/dll.c: ok — no findings from the checks that ran
  checked: ownership; not checked: bounds, locks, initialisation, tagged unions
```

Chaque nœud vit dans l'arène, les pointeurs cycliques `prev`/`next` partagent la durée de vie de
l'arène, aucun nœud n'est libéré individuellement, et rien n'est utilisé après la destruction de
la région — le tout vérifié statiquement, sur tous les chemins. Là où le Rust sûr force `unsafe`
pour *exprimer* les références cycliques, kenbi les *vérifie* sous une discipline déclarée et
contrôlée.

**Portée honnête.** Il s'agit de sûreté mémoire (pas d'use-after-free / double-free / fuite /
use-after-region-free / libération individuelle) sous la discipline `@arena` *déclarée* —
**et non** de la garantie complète de Rust : elle n'impose pas l'aliasing-XOR-mutation (`&mut`)
ni l'absence de course de données, et l'arène échange de la mémoire (toute la région est libérée
d'un coup) contre la simplicité. L'affirmation est étroite et réelle : kenbi peut *héberger une
discipline* (propriété par région) sous laquelle ce motif est statiquement vérifiable, là où un
langage à modèle unique doit retomber sur `unsafe`. À comparer avec [`demo/vec.c`](demo/vec.c)
(un équivalent de `Vec<i32>`) : un `malloc` manuel stocké dans un champ de struct se vérifie
proprement mais lève une **consultative** `ESCAPE_UNCHECKED` — la propriété du champ est
honnêtement signalée comme non vérifiée, pas passée silencieusement.

## Un allocateur, plusieurs destructeurs typés

Les projets réels allouent avec un wrapper générique et libèrent via des destructeurs typés
construits autour. `free:` / `free_returns_null:` acceptent donc plusieurs noms de libération —
tous des libérations valides de la famille, tout autre restant `WRONG_DEALLOCATOR` — et
`frees_fields:` enregistre qu'un tel destructeur libère aussi les champs possédés de l'objet :

```c
// @allocator magick::mem { alloc: AcquireQuantumMemory AcquireKernelInfo …,
//                          free_returns_null: RelinquishMagickMemory DestroyKernelInfo …,
//                          frees_fields: DestroyKernelInfo … }
```

Libérer un conteneur alors qu'un champ possède encore est par défaut une `LEAK` — juste pour un
simple `free(s)`, faux pour un destructeur qui existe pour libérer le graphe ; c'est donc la
déclaration qui l'autorise, et une libération non déclarée reste RED.

Déclarer ces paires sur ImageMagick AUGMENTE le décompte (689 → 729 sur les 95 fichiers), ce qui
est la fermeture qui s'étend vers l'extérieur et non une régression : un appel
`DestroyKernelInfo(kernel)` était auparavant une frontière sans contrat — kenbi ne pouvait pas
voir qu'une libération s'y produisait, donc rien de ce qui passait par là n'était vérifié — et
c'est désormais une libération qu'il vérifie, ce qui pose à son tour la question de savoir qui
possède l'objet. Cela a aussi révélé une vraie fuite : `OrderedDitherImage` (threshold.c) retourne
sur un échec de `SetImageStorageClass` sans le `DestroyThresholdMap` qu'effectue toute autre
sortie.

*Mesuré en septembre 2026 sur ImageMagick 7.1.2-27 avec kenbi tel qu'il était alors ; les versions ultérieures de kenbi donnent d'autres totaux.*

## Mettre sous contrat du code que vous ne pouvez pas modifier

Chaque contrat ci-dessus doit se placer au-dessus d'une déclaration — et un projet tiers n'offre
aucun endroit où en mettre un. `@contract` nomme plutôt la fonction, de sorte que tout le
vocabulaire fonctionne depuis un en-tête de surcouche inclus de force (force-included) et composé
uniquement de commentaires :

```c
// @contract qsort            { borrows: $1 }
// @contract DestroyKernelInfo { frees: $1 }
// @contract AddValueToSplayTree { borrows: $1, moves: $2 $3 }
```

Les paramètres sont nommés par POSITION (`$1`, à partir de 1) aussi bien que par nom, ce qui est
généralement nécessaire : les en-têtes C déclarent souvent les paramètres sans nom, et les sites
d'appel qui ont besoin du contrat ne voient que le prototype.

C'est le même contrat, résolu via la même liaison — il est donc **vérifié, pas pris sur la
confiance**. Une déclaration `frees:` sur une fonction dont le corps se trouve dans l'unité de
traduction est vérifiée par rapport à ce corps (`CONTRACT_NOT_HONORED` s'il ne libère pas) ;
libérer un paramètre déclaré `borrows:` est `BORROW_FREED` ; et déclarer un emprunt laisse
l'appelant redevable de la libération, de sorte qu'un pointeur transmis et jamais libéré devient
une `LEAK` visible au lieu d'une frontière indécidable. Un contrat qui nomme un paramètre que la
signature ne possède pas ne lie rien — la frontière reste RED, la direction sûre, avec une
consultative `CONTRACT_UNBOUND` qui explique pourquoi.

Sur MagickCore d'ImageMagick (95 fichiers, sa propre ligne de compilation), dix déclarations
`borrows` dans [`demo/imagemagick/kenbi_magick_api.h`](demo/imagemagick/kenbi_magick_api.h) font
passer les résultats de 657 à 626 et `UNCONTRACTED_ESCAPE` de 249 à 216 — et mettent au jour deux
nouvelles `LEAK`, ce qui est le mécanisme à l'œuvre : une frontière déclarée est une frontière
décidable. Pour une *fabrique*, préférez `@allocator` — ajouter le nom à la liste `alloc:` d'une
famille nomme aussi la ressource et son désallocateur, de sorte que les fuites et
`WRONG_DEALLOCATOR` sont également vérifiés (cela seul a éliminé 16 des 26 libérations sans
contrat de xml-tree.c).

*Mesuré en septembre 2026 sur ImageMagick 7.1.2-27 avec kenbi tel qu'il était alors ; les versions ultérieures de kenbi donnent d'autres totaux.*

## Listes intrusives : déclarer le lien, déclarer la vidange

L'autre liste du C — des nœuds sur le tas, chaînés via un champ, libérés un par un — n'est pas
une arène, et c'est là que le modèle de ressources de kenbi par site d'allocation devient
visible. Chaque nœud provient d'un seul `malloc`, donc kenbi voyait une seule ressource là où le
programme a une chaîne d'objets : une libération dans un parcours se lisait comme la libération
de « la » ressource, et l'étape suivante comme une utilisation après libération.

Deux déclarations rendent la chaîne vérifiable, et aucune n'est prise sur la confiance :

```c
/* @mem t::n { free: free, owner: cur, link: next } */   /* per resource… */
// @list Cluster { link: next }                           /* …or per record TYPE */

/* @drains(head) */
for (cur = head; cur != NULL; cur = nxt) { nxt = cur->next; free(cur); }
```

`link:` indique que la ressource est un NŒUD d'une collection chaînée via ce champ, de sorte
qu'un parcours donne un autre élément plutôt qu'un pointeur que kenbi ne sait pas situer, et
qu'une libération dans le parcours retire un ÉLÉMENT. `@drains(head)` indique qu'une boucle
libère chaque élément — et kenbi le vérifie : une boucle qui ne libère rien est
`CONTRACT_NOT_HONORED`, une collection que rien ne vide est une `LEAK`,
`free(cur); cur = cur->next;` est un `USE_AFTER_FREE`, libérer deux fois un curseur avant qu'il
n'avance est un `DOUBLE_FREE`, et tout curseur devient pendant une fois la collection vidée.

[`demo/list.c`](demo/list.c) montre l'ensemble en 30 lignes — construction, parcours, vidange —
et il se vérifie proprement :

```
$ kenbi demo/list.c
demo/list.c: ok — no findings from the checks that ran
  checked: ownership; not checked: bounds, locks, initialisation, tagged unions
```

La forme par TYPE atteint du code que kenbi ne peut pas modifier. La liste de clusters
d'ImageMagick est parcourue dans neuf fonctions de `MagickCore/segment.c` ; une seule ligne de
commentaire dans une surcouche incluse de force
([`demo/imagemagick/kenbi_magick_lists.h`](demo/imagemagick/kenbi_magick_lists.h)) fait passer ce
fichier de 83 résultats à 14, avec la disparition des 54 `USE_AFTER_FREE` et des 4
`DOUBLE_FREE`. Ce qu'un en-tête ne peut pas dire, c'est quelle boucle vide la liste — c'est un
fait qui concerne une instruction — donc ces collections restent RED jusqu'à ce que la vidange
soit déclarée sur la boucle. C'est la question que kenbi doit poser, et non une question à
laquelle il peut répondre depuis l'extérieur du fichier.

*Mesuré en septembre 2026 sur ImageMagick 7.1.2-27 avec kenbi tel qu'il était alors ; les versions ultérieures de kenbi donnent d'autres totaux.*

## Vérification bas niveau configurée (`--safety`)

Certaines propriétés du code bas niveau ne figurent pas du tout dans le source : quelles
fonctions s'exécutent dans une interruption, ce qu'une API de périphérique a le droit de faire,
combien de pile une compilation utilise, quelle mémoire un moteur DMA peut atteindre.
`--safety=project.json` les prend dans un fichier de projet et des fichiers de contrats, et
vérifie le source par rapport à eux :

```sh
kenbi --format=json --safety=demo/safety/project.json
```

| propriété | document |
|---|---|
| effets interdits dans une fermeture d'appels (allocation, blocage, attente, récursion), par bloc ou par fonction | [effets](docs/configured_effects.md), [récursion](docs/configured_recursion.md), [effets par état](docs/configured_state_effects.md) |
| machines à états de ressources (ordre des opérations, états finaux, résultats selon la valeur de retour) | [protocoles](docs/configured_protocols.md), [résultats](docs/configured_protocol_results.md), [blocs](docs/configured_protocol_blocks.md), [frontières de fonction](docs/configured_function_boundaries.md) |
| tampons empruntés par des opérations asynchrones (aucune modification, libération ou réutilisation avant achèvement) | [emprunts asynchrones](docs/configured_async_borrows.md), [capacité](docs/configured_borrow_capacity.md), [alignement](docs/configured_borrow_alignment.md), [marques de tampon](docs/configured_buffer_marks.md), [stockage en lecture seule](docs/configured_storage_permissions.md) |
| contextes d'exécution (interruption, thread) et les API que chacun autorise | [contextes](docs/configured_contexts.md) |
| plage et alignement des lectures, écritures et accès via API | [accès dans le source](docs/configured_source_access.md), [capacité des API](docs/configured_access_capacity.md), [alignement des API](docs/configured_access_alignment.md), [pointeurs retournés](docs/configured_return_pointer.md), [réaffectation de pointeurs](docs/configured_pointer_bindings.md) |
| boucles et compteurs dans les vérifications ordonnées | [for](docs/configured_for_loops.md), [do-while](docs/configured_do_while.md), [mises à jour non signées](docs/configured_unsigned_updates.md), [paramètres entiers](docs/configured_integer_parameters.md) |
| contrats d'allocation, limites de pool et de tas, régions mémoire | [allocation](docs/configured_allocation.md), [régions mémoire](docs/configured_memory_regions.md) |
| profondeur d'appel et utilisation de la pile (à partir de la sortie `-fstack-usage` du compilateur) | [profondeur d'appel](docs/configured_call_depth.md), [utilisation de la pile](docs/configured_stack_usage.md) |
| cartes de registres MMIO (lecture seule / écriture seule, write-1-to-clear, read-to-clear, bits réservés, largeur d'accès, barrières requises) | [MMIO](docs/configured_mmio.md) |
| bornes de temps d'exécution fournies par un outil WCET externe, liées à la compilation | [temps d'exécution](docs/configured_execution_time.md) |
| liaison des fichiers de contrats aux sources, options de compilation et cible pour lesquelles ils ont été écrits | [artefacts](docs/configured_contract_artifacts.md), [compilation](docs/configured_contract_compilation.md), [cible](docs/configured_contract_target.md) |

Chaque obligation est signalée comme `verified`, `conditional` (tient sous des contrats externes,
que le résultat liste comme hypothèses), `unverified` ou `violation`. Tout ce que kenbi ne peut
pas résoudre est `unverified`, et l'exécution ne réussit que lorsque chaque obligation est
`verified`, ou `conditional` sur des hypothèses que le fichier de projet accepte explicitement.
Les documents ci-dessus sont en japonais, et chacun indique ce qu'il ne couvre pas.
[`demo/safety/`](demo/safety/) et [`demo/dma/`](demo/dma/) sont des exemples complets sur des
périphériques fictifs.

## Ce qu'un GREEN promet et ne promet pas

Un GREEN signifie : dans le cadre des vérifications exécutées, sur le code que kenbi a analysé,
chaque chemin est conforme aux contrats déclarés. Il ne signifie pas :

- **Sûr au-delà des axes activés.** Un fichier sans `@spatial` n'a fait l'objet d'aucune
  vérification de bornes ; là où `@kenbi` marque une partie d'un fichier, le reste n'a fait
  l'objet d'aucune vérification.
- **Sûr au-delà des contrats.** Un contrat sur du code que kenbi n'a pas vu est pris sur la
  confiance, et figure dans la frontière de confiance ; `@unsafe` est la parole de l'auteur, et
  figure aussi dans la liste. `verified` est la réponse où rien n'est pris sur la confiance.
- **Sûr au-delà de ce que la compilation définit.** Le code exclu par le préprocesseur, un autre
  `compile_commands.json` ou une autre cible n'a pas été analysé.

Ce que kenbi ne peut pas modéliser, il le refuse plutôt que de l'ignorer : `UNSTRUCTURED_GOTO`
(gotos arrière, sauts vers des labels imbriqués, gotos calculés), `LOOP_FIXPOINT_LIMIT`,
`UNSUPPORTED_CONSTRUCT`, et `unverified` sous `--safety`. Sur du code réel de grande taille, ces
refus font partie du résultat — une fonction qui en contient un reste RED jusqu'à ce qu'elle soit
restructurée ou déclarée.

Si vous trouvez un GREEN qui ne devrait pas en être un, merci de le signaler avec une
reproduction minimale : c'est le type de bug le plus grave que kenbi puisse avoir.

## Architecture

Le moteur d'analyse est découplé du front-end : il travaille sur une IR indépendante du
front-end, si bien que l'analyse syntaxique du C/C++ est une partie remplaçable.

```
*.c / *.cpp  ──▶ libclang front-end  ┐
                 (src/frontend_c.nim) ├─▶ Program IR ─▶ typestate engine ─▶ diagnostics
*.mc         ──▶ mini-format parser  ┘   (src/ir.nim)   (src/analyze.nim)
                 (src/parse.nim)
```

| fichier | rôle |
|---|---|
| `src/ir.nim` | IR indépendant du front-end (`Program` : ressources + arbre d'instructions) |
| `src/analyze.nim` | moteur de typestate (origines, fusion may-set, point fixe des boucles, détection de fuites, couverture) |
| `src/clang.nim` | FFI libclang minimal (structures par valeur conformes à l'ABI C) |
| `src/frontend_c.nim`, `src/cfront_*.nim` | abaissent le C/C++ réel et les commentaires d'annotation vers `Program` |
| `src/annotations/` | registre du vocabulaire d'annotations |
| `src/compile_db.nim` | extrait les drapeaux d'analyse de `compile_commands.json` |
| `src/safety_config.nim`, `src/safety_check.nim` | `--safety` : fichiers de projet et de contrats, vérifications configurées |
| `src/effect_facts.nim`, `src/protocol_*.nim` | `--safety` : effets des fermetures d'appels, machines à états et emprunts |
| `src/parse.nim` | parseur mini-format (fixtures du moteur) |
| `src/kenbi.nim` | CLI : aiguillage par extension, affichage des diagnostics |

## Tests

`tests/*.mc` pilotent directement le moteur (17 cas). `tests/c/*.c` et `tests/cpp/*.cpp` portent
ces scénarios plus les contrôles spécifiques aux annotations en C et C++ réels (349 cas) ; le
lanceur abaisse chacun via libclang et vérifie les diagnostics produits — **y compris leur ligne
source** — par rapport aux marqueurs `//EXPECT CODE` de chaque fichier (sur la ligne elle-même,
ou `//EXPECT CODE@LINE`). Une mauvaise ligne ou un diagnostic manquant / superflu fait échouer la
suite. `tests/run_tests_project.nim` vérifie le résultat de couverture à l'échelle du projet, les
suites `tests/run_tests_*.py` vérifient `--safety` de bout en bout, et
`demo/verify_three_state.py` vérifie le [corpus à trois états](demo/README_three_state.md) et le
matériel du serveur MCP généré à partir de celui-ci.

## Licence

kenbi est distribué sous la licence Apache 2.0 ([LICENSE.md](LICENSE.md)). Les éléments provenant
d'autres projets, et leurs licences, sont recensés dans [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
