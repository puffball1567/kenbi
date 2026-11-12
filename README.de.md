# kenbi

[English](README.md) · [简体中文](README.zh.md) · [日本語](README.ja.md) · [Español](README.es.md) · [Português](README.pt.md) · [Français](README.fr.md) · **Deutsch**

**kenbi prüft C- und C++-Code gegen die Speichersicherheitsregeln, die er deklariert.** Sie schreiben als Kommentare neben den Code, wem ein Puffer gehört, wer ihn freigibt und wie lange eine Ausleihe gilt; kenbi prüft statisch und auf jedem Pfad, dass der Code tut, was diese Kommentare sagen. Es ist kein Compiler und ändert Ihren Build nicht.

**Gebaut, um C/C++ mit KI-Agenten zu schreiben.** Über seinen [MCP-Server](#mit-ki-coding-agenten-mcp) prüft ein Agent das C/C++, das er gerade geschrieben hat, fragt, warum ein Befund auftritt und wie die Korrektur aussieht, und wiederholt das, bis die Prüfungen nichts mehr melden. Speichersicherheit wird so Teil der Schreibschleife des Agenten statt einer nachträglichen Review, und die Annotationen, die er schreibt, bleiben als Regeln im Code, die kenbi weiter prüft.

> Status: **v0.1.0**, frühe Entwicklungsphase. Die Schnittstellen, das Annotationsvokabular und
> die JSON-Ausgabe können sich noch ändern.

## Ein erster Blick

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

`@kenbi` stellt die Datei unter die Ownership-Prüfung, und `@mem` deklariert eine Ressourcenart und wie sie belegt und freigegeben wird. Ändern Sie das frühe Return zu `{ free(p); return NULL; }`, und die Datei meldet `ok — no findings from the checks that ran` mit Exit-Code 0. Die Zeile `checked:` gehört zu jedem Ergebnis: keine Befunde gilt nur für die dort aufgeführten Prüfungen.

## Was es unterscheidet

- **Deklariert, nicht abgeleitet.** kenbi rät nicht, was der Code bedeutet. Es prüft den Code gegen das, was die Annotationen deklarieren; ein Befund ist also eine Stelle, an der der Code von einer festgelegten Regel abweicht, kein Muster, das verdächtig aussieht.
- **Unbewiesen ist nicht grün.** Wo kenbi nicht zeigen kann, dass jeder Pfad die Regeln einhält, meldet es einen Befund, und was es nicht modellieren kann (etwa ein Rückwärts-`goto`), meldet es ebenfalls, statt es zu überspringen. Ein Ergebnis ohne Befunde ist die Aussage, für die kenbi einsteht.
- **Jeder Pfad, ohne den Code auszuführen.** Sanitizer und Tests sehen die Pfade, die laufen; kenbi folgt jedem Pfad durch Schleifen, frühe Returns, `goto`-Aufräumleitern und C++-Exceptions.
- **Deterministisch, mit angegebenem Umfang.** Dieselbe Eingabe ergibt dieselbe Ausgabe, und jedes Ergebnis nennt die ausgeführten Prüfungen, die Verträge, auf denen es beruht, und jedes `@unsafe`, das einen Befund unterdrückt hat.
- **Schrittweise einführbar.** Jede Prüfung wird einzeln aktiviert, pro Datei, Funktion oder Block, sodass bestehender Code nicht zu einer roten Wand wird.

## Mit KI-Coding-Agenten (MCP)

Der [MCP-Server](mcp/README.md) gibt einem Agenten den Prüfer und das Material, um danach zu handeln:

| | was der Agent bekommt |
|---|---|
| `check_memory_safety` | die Befunde von kenbi mit einer Zusammenfassung, die angibt, welche Prüfungen auf welchen Funktionen liefen, sodass „keine Befunde“ nie als „sicher“ gelesen wird |
| `explain_finding` | zu einem Befundcode oder einer CWE-Nummer: was ihn auslöst, warum eine halbe Korrektur weiter scheitert, und die Korrektur mit dem Vertrag, den sie deklariert |
| `kenbi://annotations` | die Annotationsreferenz |
| `kenbi://patterns` | sichere C/C++-Formen, die kenbi akzeptiert, neben den unsicheren, die es ablehnt |

Die Schleife lautet schreiben → prüfen → erklären → korrigieren → erneut prüfen, und kenbi, nicht das Modell, entscheidet, wann sie fertig ist. Der Server weist den Agenten außerdem an, in Kommentaren nicht zu wiederholen, was eine Annotation bereits sagt: Die Annotation wird geprüft, ein Kommentar nicht.

Die Schleife an [`demo/quickstart.c`](demo/quickstart.c), mit den tatsächlichen Antworten des Servers (auf jede Zusammenfassung folgt das vollständige JSON-Dokument von kenbi, hier weggelassen):

1. Der Agent schreibt `dup_name` und ruft `check_memory_safety` auf:

   ```text
   kenbi: 1 error(s), 0 warning(s) across 1 file(s):
     demo/quickstart.c:8: error: leak: 'app::buf' allocated here is never freed or moved [LEAK]

   Scope — the result covers only this:
     - ownership, lifetime and null (`@kenbi`, or a file with no marker): checked in every function
     - NOT checked anywhere: bounds (`@spatial`); locks (`@threadsafe`); initialisation (`@initcheck`); tagged unions (`@typecheck`)
     - verified (nothing taken on trust): 0 of 1 adopted memory-relevant functions
     - code the preprocessor excluded under these flags was not analysed
   ```

2. Er ruft `explain_finding` mit `LEAK` auf und erhält ausgearbeitete Beispiele; das erste endet mit der Korrektur:

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

3. Er gibt `p` beim frühen Return frei (`if (p[0] == '\0') { free(p); return NULL; }`) und prüft erneut:

   ```text
   kenbi: no findings in 1 file(s) from the checks that ran. This is not a statement about anything outside the scope below.

   Scope — the result covers only this:
     - ownership, lifetime and null (`@kenbi`, or a file with no marker): checked in every function
     - NOT checked anywhere: bounds (`@spatial`); locks (`@threadsafe`); initialisation (`@initcheck`); tagged unions (`@typecheck`)
     - verified (nothing taken on trust): 1 of 1 adopted memory-relevant functions
     - code the preprocessor excluded under these flags was not analysed
   ```

[`integrations/agent/`](integrations/agent/) enthält passende Anweisungen für Claude Code (`SKILL.md`), Codex-artige Agenten (`AGENTS.md`) und GitHub Copilot.

Die Einrichtung steht in [`mcp/README.md`](mcp/README.md#configure-in-an-mcp-client).

## Was geprüft wird

Jede Prüfung wird einzeln aktiviert:

| Achse | Opt-in | was geprüft wird |
|---|---|---|
| Besitz / Lebensdauer | `@kenbi` (oder eine Datei ohne Marker) | Use-after-Free, Double-Free, Lecks an jedem Ausgang, Use-after-Move, falscher Deallocator, hängende Rückgaben, Borrow- und Arena-Lebensdauern, deklarierte Verträge gegen Funktionsrümpfe, C++-RAII-Eigentümer, Smart Pointer und Exception-Pfade |
| Null | immer, mit `@nullable` / `@nonnull` | Dereferenzierung eines möglicherweise oder bekanntermaßen nullen Zeigers, mit flusssensitiver Verengung |
| Grenzen | `@spatial` | ein nicht vertrauenswürdiger Index oder eine Größe, die einen Puffer erreicht, benötigt eine vorhandene, ausreichende, überlaufsichere Grenzprüfung; `@counted_by` und deklarierte Datenstruktur-Invarianten (`@invariant` / `@maintains`) |
| Initialisierung | `@initcheck` | eine lokale Variable, die gelesen wird, bevor sie auf jedem Pfad zugewiesen wurde |
| getaggte Unions | `@typecheck` + `@variant` | ein Union-Member, der verwendet wird, wo sein Tag nicht bewiesen ist |
| Locks | `@threadsafe` | ungeschützter Zugriff, unausgeglichene Locks, deklarierte Lock-Reihenfolge (AB-BA-Deadlock) |
| Low-Level-Eigenschaften | `--safety=project.json` | verbotene Effekte in einer Aufrufhülle, Zustandsautomaten für Ressourcen, Stack- und Aufruftiefe, Speicherregionen, MMIO und mehr – siehe [Konfigurierte Low-Level-Verifikation](#konfigurierte-low-level-verifikation---safety) |

Ein libclang-Frontend überführt echtes C / C++ (liest `compile_commands.json`) in eine
Typestate-Engine. Schleifen werden bis zu einem beschränkten Fixpunkt analysiert,
vorwärtsgerichtete `goto`-Aufräumleitern, `break` / `continue` und `try` / `catch` werden
modelliert, und was kenbi nicht modellieren kann, wird gemeldet statt übersprungen. Die Ausgabe
ist Text oder `--format=json`.

## Schnellstart

```sh
# Debian / Ubuntu; for other systems see "libclang je Betriebssystem installieren" below.
# Nim 2.2 or later: https://nim-lang.org/install.html
sudo apt-get install libclang1-14 libclang-common-14-dev
git clone https://github.com/puffball1567/kenbi
cd kenbi
nimble build -d:release
./kenbi demo/quickstart.c
```

## Voraussetzungen

- **Nim** >= 2.2 ([Installation](https://nim-lang.org/install.html))
- **libclang** (die gemeinsame Bibliothek; die `clang-c`-Header werden *nicht*
  benötigt — nur die Laufzeit-`.so` / `.dylib` / `.dll`, die beim Start dynamisch
  geladen wird).
- **die eingebauten Header von clang** (`stddef.h`, `stdarg.h`, …), die libclang braucht, um eine
  Datei zu analysieren, die einen davon einbindet. Die meisten clang/LLVM-Pakete liefern sie mit der
  Bibliothek aus; unter Debian und Ubuntu sind sie das separate Paket `libclang-common-N-dev`.

libclang wird zur Laufzeit über den Soname geladen; die Standard-Suchliste deckt
`libclang.so`, `libclang-13..18.so` usw. ab. Hat Ihre Bibliothek einen anderen
Namen oder Pfad, überschreiben Sie ihn zur Kompilierzeit:

```sh
nimble build -d:release -d:kenbiLibclang=/full/path/to/libclang.so
```

## Bauen und Testen

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

### libclang je Betriebssystem installieren

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

**macOS** (Homebrew-LLVM oder die Xcode Command Line Tools)
```sh
brew install llvm
nimble build -d:release -d:kenbiLibclang="$(brew --prefix llvm)/lib/libclang.dylib"
# Apple's Command Line Tools also ship a libclang at
#   /Library/Developer/CommandLineTools/usr/lib/libclang.dylib
```

**Windows** (MSVC + LLVM-Release)
```bat
:: install LLVM from https://releases.llvm.org and ensure libclang.dll is on PATH
nimble build -d:release -d:kenbiLibclang=libclang.dll
```

## Verwendung

```
kenbi [--format=text|json] [--compile-commands=PATH] [--project[=PATH]] [--emit-contracts]
      <file> [more...] [-- <extra clang args>]
kenbi [--format=text|json] --safety=project.json
kenbi --version
```

- `kenbi --version` gibt die Version von kenbi und die geladene libclang aus.
- `*.c *.cc *.cpp *.cxx` → libclang-Frontend (C oder C++ anhand der Endung).
- `*.mc` → Mini-Format.
- Für C/C++ stammen die Parse-Flags aus `compile_commands.json`: per
  `--compile-commands=PATH` übergeben, oder sie wird durch Aufwärtssuche von der
  Quelldatei automatisch gefunden. Alles nach `--` wird an die clang-Kommandozeile
  angehängt.
- `--project[=compile_commands.json]` analysiert jede Übersetzungseinheit, die die Datenbank
  auflistet. Die Befunde jeder Datei bleiben ihre eigenen (Annotationen gelten pro Datei, ebenso
  die Analyse) — was hinzukommt, ist die **Hülle**: ein vertraglich deklarierter Aufruf einer
  Funktion, die in einer anderen analysierten Einheit definiert ist, wird zum Urteil dieser Einheit
  aufgelöst, sodass ein GREEN, dessen gesamte Abhängigkeitshülle analysiert und GREEN ist, als
  *verified* gilt, und die vertrauenswürdige Grenze schrumpft auf das, was nichts im Projekt
  definiert (eine als Binärdatei ausgelieferte Bibliothek, das Betriebssystem, eine FFI-Kante).
  Ohne Pfad wird die Datenbank durch Aufwärtssuche von der ersten angegebenen Datei gefunden.
- `--format=json` gibt maschinenlesbare Befunde mit stabilen Codes aus (für CI,
  Editoren und Agenten); `--format=text` (Standard) ist menschenlesbar.
- `--safety=project.json` führt die konfigurierten Low-Level-Prüfungen aus, die unter
  [Konfigurierte Low-Level-Verifikation](#konfigurierte-low-level-verifikation---safety) beschrieben sind.
- Exit-Code: `0` sauber · `1` Probleme gefunden · `2` Nutzungs- / Parse-Fehler.


## Opt-in: Datei, Funktion oder Block

`@kenbi` markiert, was unter Disziplin steht — Befunde außerhalb davon werden verworfen, sodass
die Einführung schrittweise erfolgt und nie eine rote Wand entsteht. Der Marker bindet an das,
worüber er steht:

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

Ein Block unter Disziplin stellt seine Funktion **nicht** darunter: Solche Blöcke werden gezählt
und in einer eigenen Zeile gemeldet (`blocks adopted`), nie in die Zahl der übernommenen
Funktionen eingerechnet.

## Verträge für eine Bibliothek ausliefern

Ein Vertrags-Overlay ist eine Datei aus Kommentaren — es kann neben einer Bibliothek
veröffentlicht oder von einem Nutzer für eine Bibliothek geschrieben werden, die nie von kenbi
gehört hat. In beiden Fällen muss der Empfänger wissen, was es beschreibt, also sagt das Overlay
es, und kenbi prüft, was es prüfen kann:

```c
// @contracts_for ImageMagick { version: 7.1.2-27, requires: MAGICKCORE_QUANTUM_DEPTH=16 }
// @allocator magick::mem { alloc: AcquireQuantumMemory, free_returns_null: RelinquishMagickMemory }
// @contract qsort { borrows: $1 }
```

- `requires:` wird gegen die Kompilierzeile **geprüft**. Ein Build, der einer Bedingung
  widerspricht, ist ein Fehler (`CONTRACT_PACKAGE_MISMATCH`) — diese Verträge wurden für einen
  anderen Build geschrieben, also gilt möglicherweise nicht, was sie versprechen. Eine Bedingung,
  die die Kompilierzeile nicht entscheidet, wird als *unverifiziert* gemeldet, nie als erfüllt.
- `version:` wird als **deklariert** mitgeführt. kenbi kann die Version einer Bibliothek nicht aus
  dem Quelltext lesen und gibt das auch nicht vor; der Bericht sagt „version declared, not verified".

`--format=json` trägt das Ganze (`contractPackages` mit `versionDeclared`, `requires`,
`mismatched`, `unverified`, `appliesToThisBuild`), sodass ein Nutzer entscheiden kann, ob er
einem Vertragssatz vertraut, bevor er sich darauf verlässt.

### Einen Vertragssatz veröffentlichen

`--emit-contracts` gibt die Vertrags-*Oberfläche* dessen aus, was analysiert wurde, statt es zu
prüfen — die Form, die eine Bibliothek ausliefert, damit ein anderes Werkzeug (ein anderer
Prüfer, ein Binding-Generator, das Frontend einer anderen Sprache) Aufrufer an die Verträge der
Bibliothek binden kann, ohne deren Kommentare erneut zu lesen:

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

`resources` ist das Vokabular alloc → free: Ein Nutzer, dem nur die Deallocatoren genannt
werden, kann nicht erkennen, welcher Aufruf ihm die Verpflichtung überhaupt übergeben hat. Und
jeder Vertrag trägt den `status`, den dieser Lauf für die dahinterstehende Implementierung
festgestellt hat, denn „ein Vertrag ist deklariert" darf nicht als „die Implementierung wurde
geprüft" lesbar sein:

| `status` | was der Lauf festgestellt hat |
|---|---|
| `declared` | keine Implementierung hier (ein Prototyp oder ein von außen geschriebener Vertrag) — **nichts wurde verifiziert** |
| `unchecked` | der Rumpf ist vorhanden, steht aber nicht unter `@kenbi`: kenbi hat ihn nicht geprüft |
| `red` | der Rumpf steht unter `@kenbi` und widerspricht seinen Verträgen — verlassen Sie sich nicht darauf |
| `green` | geprüft und sauber, gestützt auf Vertrauen (ein nicht abgedeckter vertraglich deklarierter Callee oder ein `@unsafe`) |
| `verified` | geprüft und sauber, ebenso seine gesamte vertragliche Hülle: kein Rest |

Veröffentlichen ist keine Prüfung: Das Dokument wird ausgegeben, und der Exit-Code ist 0, selbst
wenn der Code Befunde hat. Diese erhalten Sie mit einem gewöhnlichen `kenbi`-Lauf.

## „GREEN" und „verified" sind unterschiedliche Antworten

Eine Annotation ist kein Beweis, und das Abdeckungsergebnis sagt das:

| | was es bedeutet |
|---|---|
| `GREEN (contracted)` | die Grenzen sind deklariert — sicher *unter der Voraussetzung* der Verträge, auf denen es beruht |
| `verified` | auch seine gesamte vertragliche Abhängigkeitshülle ist abgedeckt: nichts wird auf Vertrauen angenommen |
| `trusted frontier` | die nicht abgedeckten Callees, auf denen ein GREEN derzeit beruht — decken Sie diese ab, um sie zu schließen |
| `@unsafe vouches` | die Stellen, an denen der Autor zugesichert hat, was kenbi nicht prüfen konnte |

`verified` ist eine echte Teilmenge von `GREEN`. Einen Vertrag auf einem nicht abgedeckten Callee
zu deklarieren, verschiebt eine Funktion von RED nach GREEN und setzt diesen Callee auf die
vertrauenswürdige Grenze; ein `@unsafe`, das tatsächlich einen Befund unterdrückt, hält die
Funktion GREEN und dauerhaft außerhalb von `verified`, mit benannter Stelle. Eine Operation, die
kenbi nicht verifizieren kann, kann also nie als verifiziert erscheinen, weil jemand sie annotiert
hat. All dies steht in `--format=json` (`green`, `verified`, `trustedFrontier`,
`unsafeVouches` und pro Einstiegspunkt `flows` mit ihren `blockers`).

```sh
kenbi --compile-commands=build/compile_commands.json src/img.c
kenbi --project=build/compile_commands.json          # the whole project, one closure
kenbi --emit-contracts src/*.c                       # publish the contract set instead
kenbi --format=json src/*.c
kenbi foo.cpp -- -Iinclude -DDEBUG
```

Das JSON-Dokument ist `{ "version", "tool", "findings": [ { "file", "line",
"code", "severity", "message" } ], "coverage", "scope" }`; die Codes sind stabil und die Reihenfolge
ist deterministisch. Lese-/Parse-Fehler erscheinen als `PARSE_ERROR`-Befunde.
`scope` gibt für jede analysierte Datei an, welche Prüfungen auf welchen Funktionen liefen: für jede von
`ownership`, `bounds`, `locks`, `initialisation` und `taggedUnions` einen `mode`, der `file` (alle Funktionen),
`functions` (einige; die übrigen stehen in `unchecked`) oder `off` ist, dazu die mit `@kenbi` übernommenen Blöcke
in sonst nicht geprüften Funktionen. Eine Datei ohne Befunde ist nur innerhalb dieses Umfangs sauber; die
Textausgabe zeigt ihn unter jeder Datei an.

## Annotationen

Ressourcen werden in Kommentaren deklariert und über einen projektweit eindeutigen,
bereichsqualifizierten Namen referenziert. Die Verpflichtung haftet an der
*Allokation* (ihrem „Ursprung"), nicht an der Variable: Kopien aliasieren sie,
innere Zeiger leiten sich davon ab, und ein `free` / move löst sie ein. Verzweigungen
werden solide zusammengeführt (ein Zustand ist nach einer Vereinigung möglich, wenn
er auf *einem der beiden* Pfade möglich ist — ein `free` auf nur einem Pfad lässt
also auf dem anderen ein Leck zurück).

```c
/* @mem demo::buf { size: n, free: free, owner: p } */
char *p = malloc(n);     // alloc of demo::buf (p is the owner)
char *r = p + 16;        // interior pointer — inferred, must not be freed
consume(p);              // use
sink(p);  // @move demo::buf   — obligation transferred out; p is now moved-from
```

- **Allokation**: eine Initialisierung / Zuweisung, deren rechte Seite aus der
  `malloc`-Familie oder ein C++-`new` ist, bindet die Verpflichtung an die Zielvariable.
- **Freigabe**: `free(p)` oder C++-`delete`/`delete[] p`.
- **innerer Zeiger**: `p + off` leitet einen inneren Zeiger in denselben Ursprung ab.
- **Alias**: `q = p` macht `q` zum Alias des Ursprungs von `p`.
- **copy**: `// @copy <resource>` an einer Zuweisung markiert eine *tiefe* Kopie —
  ein neues, unabhängiges besessenes Objekt mit eigener Verpflichtung, kein bloßer
  Alias.
- **move**: ein Aufruf in einer Zeile mit `// @move` überträgt die Verpflichtung.
- **unsafe**: `// @unsafe` an einer Zeile stellt sie unter Quarantäne — Befunde
  dort werden unterdrückt (Sie übernehmen die Verantwortung). Ein `@unsafe`, das
  nichts abdeckt, wird als `STALE_UNSAFE` gemeldet, wie ein ungenutztes
  Lint-Disable.
- **Null-Sicherheit**: `// @nullable` (oder `@nonnull`) an einer Deklaration
  markiert, ob ein Zeiger null sein darf; das Dereferenzieren eines nullable-Zeigers
  ohne Null-Prüfung (`if (p)`, `if (p != NULL)`, frühes `return`) ist `NULL_DEREF` —
  die `Option<T>`-Disziplin, flusssensitiv mit Verzweigungsverengung.
- **frees-Vertrag**: `// @frees(param)` über einer Funktion deklariert, dass sie
  dieses Argument freigibt. Aufrufstellen behandeln den Aufruf dann als Freigabe
  (er komponiert also mit Double-Free / Leck), und der eigene Funktionsrumpf wird
  geprüft — gibt er den Parameter nicht tatsächlich frei, ist das
  `CONTRACT_NOT_HONORED` (deklarierte Absicht vs. Implementierung, was ein Werkzeug
  ohne Annotationen nicht prüfen kann).
- **must-use-Rückgabe**: `// @must_use` über einer Funktion deklariert, dass ihr
  Ergebnis verbraucht werden muss; ein Aufruf, dessen Wert verworfen wird (eine
  bloße Anweisung, nicht zugewiesen / zurückgegeben / übergeben / getestet) ist
  `UNUSED_MUST_USE` — die `#[must_use]`-Disziplin für ignorierte Fehlercodes und
  geleckte Allokationen.

### Goto-Vokabular (optional — die strukturierte Absicht eines goto deklarieren)

Häufige Vorwärts-Gotos werden automatisch modelliert (ohne Annotation): eine
vorwärtsgerichtete Aufräumleiter (`if(!p) goto fail; … fail: free()`) wird per
Join-Merge analysiert, und ein Vorwärts-Goto aus einer Schleife / einem Switch zu
einem Aufräum-Label wird zugelassen. Ein *rückwärtsgerichtetes* Goto-Loop, ein
Sprung zu einem verschachtelten Label oder ein berechnetes Goto bleibt abgelehnt
(`UNSTRUCTURED_GOTO`) — solide durch Ablehnung. Das optionale Vokabular lässt Sie
die strukturierte Bedeutung eines goto deklarieren, sodass kenbi es modelliert und
die Form gegenprüft:

- `// @goto_noreturn` an einem Label markiert einen nicht zurückkehrenden Endpunkt
  (abort / exit / longjmp): ein Pfad, der ihn erreicht, terminiert, sodass seine
  noch besessenen Verpflichtungen eingelöst werden — ein Abbruchpfad ist kein Leck
  (unterdrückt falsche Lecks auf Fehler-Abbruch-Pfaden).
- `// @goto_finally` an einem Label markiert den Aufräum-Konvergenztrichter.
  Opt-in-Einzeltrichter-Disziplin: ein Ausgang, der noch eine Ressource besitzt
  und *nicht* durch den Trichter geleitet wird, ist `FINALLY_BYPASSED`
  (`goto <funnel>`, damit die Freigabe dort geschieht). Die Vollständigkeit der
  Zusammenführung an der Konvergenz ist die übliche inferierte Analyse.
- `// @goto_backward` an einem goto deklariert es als Schleifen-Rückkante: ein
  einfaches Goto-Loop wird in ein do-while umstrukturiert und durch den
  beschränkten Fixpunkt analysiert (sodass iterationsübergreifende Gefahren
  erkannt werden), statt abgelehnt zu werden.

### Grenzen (`@spatial`)

`// @spatial` über einer Funktion oder auf Dateiebene schaltet die Grenzen-Achse für diesen
Bereich ein. Ein nicht vertrauenswürdiger skalarer Parameter, der einen Puffer indiziert oder die
Größe eines Schreibvorgangs wie `memcpy` bestimmt, muss eine auf dem Pfad vorhandene
Grenzprüfung haben — einen `if`-Guard, eine Schleifenbedingung, `% n`, ein Clamping oder eine
Maske —, sonst ist es `UNVALIDATED_INDEX` / `UNVALIDATED_SIZE`. Die Prüfung muss den Puffer
abdecken (`INAPPROPRIATE_BOUND`, wenn sie vorhanden, aber zu locker ist), ein vorzeichenbehafteter
Index braucht zusätzlich `i >= 0` (`INDEX_MAYBE_NEGATIVE`), und die Arithmetik des Guards darf
nicht überlaufen: `i + 4 <= n` bei einem vorzeichenlosen `i` wird nicht angerechnet;
`n >= 4 && i <= n - 4` schon. kenbi sucht die Prüfung auf dem Pfad; es entfernt nie eine.

- `// @counted_by(<buf>: <len>)` über einer Funktion gibt einem Zeigerparameter seine Größe, auch
  als Feld (`b->buf: b->cap`) oder als Ringpuffer-Maske (`b->mask + 1`).
- `// @invariant(<field> <rel> <size>)` deklariert eine Datenstruktur-Invariante (zum Beispiel
  `parser->toknext <= num_tokens`). Das Feld ist dann geschützt: Jeder Schreibzugriff darauf
  braucht `// @maintains(...)`, was kenbi verifiziert (`UNGUARDED_INVARIANT_WRITE`,
  `INVARIANT_NOT_MAINTAINED`), und ein durch das Feld begrenzter Index ist über die Relation
  abgedeckt.

### Initialisierung (`@initcheck`) und getaggte Unions (`@typecheck`)

- `// @initcheck` über einer Funktion oder auf Dateiebene: Eine ohne Initialisierer deklarierte
  skalare oder Zeiger-Variable muss auf jedem Pfad zugewiesen werden, bevor sie gelesen wird,
  sonst `USE_OF_UNINITIALIZED`.
- `// @typecheck` plus `// @variant(<member>: <tag> == <value>)` pro Union-Member: Die Verwendung
  eines Members auf einem Pfad, auf dem sein Tag nicht bewiesen ist (`if (n->tag == 1)` oder
  `case 1:` auf dem Tag), ist `TYPE_CONFUSION`.

### C++

`// @raii` (oder `// @raii(Name)`) markiert eine Klasse, deren Destruktor freigibt, was sie
besitzt, und kenbi prüft, dass der Destruktor das tut. Eine solche Klasse ohne eigene
Kopieroperationen zu kopieren, ist `MISSING_COPY_CONTROL`, und ein `operator=`, der freigibt,
bevor er seine Quelle liest, ist `SELF_ASSIGN_UNSAFE`. Ein abgeleitetes Objekt über eine Basisklasse ohne virtuellen
Destruktor mit `delete` freizugeben, ist `DELETE_NONVIRTUAL_BASE`. `std::unique_ptr` / `std::shared_ptr`,
`std::move`, `.get()` / `.release()` / `.reset()`, Lambdas und Exception-Pfade
(`LEAK_ON_THROW`, `try` / `catch`, `noexcept` / `// @nothrow`) werden modelliert. Die vollständige
Referenz stellt der MCP-Server als `kenbi://annotations` bereit ([Quelle](mcp/src/annotations.ts)).

### Nicht-lokale Sprünge (`setjmp` / `longjmp`)

`longjmp` verlässt eine Funktion, ohne irgendetwas danach auszuführen: keinen Aufräumcode und in
C++ keine Destruktoren. kenbi behandelt einen Aufruf von `longjmp` / `siglongjmp` als einen solchen
Ausgang und einen Aufruf einer mit `// @longjmps` deklarierten Funktion als möglichen:

- ein dort noch gehaltener roher Eigentümer ist `LEAK_ON_LONGJMP`;
- in C++ ist ein Objekt im Gültigkeitsbereich mit nicht-trivialem Destruktor
  `LONGJMP_SKIPS_DESTRUCTOR` (C++ macht den Sprung zu undefiniertem Verhalten). Ob ein Destruktor
  trivial ist, wird clang gefragt: `std::string` wird gemeldet, `std::array<int, 3>` nicht;
- eine Funktion, die direkt oder über einen `@longjmps`-Callee einen longjmp erreichen kann, ohne
  selbst `@longjmps` zu deklarieren, ist `UNDECLARED_LONGJMP` — so wandert die Deklaration bis zu
  jedem Aufrufer hinauf.

Eine Bibliotheksfunktion, die Sie nicht ändern können, wird in einem Overlay-Header per Namen
deklariert: `// @longjmps(png_error)` oder `// @contract png_error { longjmps }`. Eine Funktion,
die `setjmp` aufruft, ist der Landepunkt des Sprungs; der Wiedereintritt dort ist noch nicht
modelliert und wird daher als `UNSUPPORTED_SETJMP` gemeldet.

### Nebenläufigkeits-Annotationen (verifiziert unter `@threadsafe`, Advisory außerhalb)

In einem `@threadsafe`-Bereich (Funktion oder Datei) werden diese durch den
Lock-gehalten-Typestate-Durchlauf **verifiziert**, default-red:

- `// @guarded_by(<field>: <lock>)` (an einer Funktion) oder `// @guarded_by(<lock>)` (an einem
  Struct-Member): Ein Zugriff, ohne dass der Lock nachweislich gehalten wird, ist
  `UNGUARDED_ACCESS`; die Adresse des geschützten Feldes zu nehmen, ist `GUARDED_ESCAPE`.
- Lock-Ausgleich: `LOCK_LEAKED` / `DOUBLE_LOCK` / `UNLOCK_WITHOUT_LOCK`.
- `// @acquires(<lock>)` / `// @releases(<lock>)`: im Rumpf verifiziert (`LOCK_NOT_ACQUIRED`)
  und an Aufrufstellen verbraucht; `// @requires_lock(<lock>)` an einem Callee:
  `REQUIRED_LOCK_NOT_HELD`.
- `// @lock_order(<a> < <b>)`: `LOCK_ORDER_VIOLATION` (AB-BA-Deadlock — eine Garantie, die Rust
  nicht gibt); widersprüchliche Deklarationen sind `LOCK_ORDER_CONFLICT`. `// @lock_class(<X>)`
  benennt die Identität eines Locks, sodass Reihenfolgen und Verträge über Funktionen und Dateien
  hinweg übereinstimmen; zwei Instanzen einer Klasse brauchen eine kanonische Reihenfolge
  (`SAME_CLASS_NO_ORDER`).
- `// @calls(<fn>, ...)` an einem Funktionszeiger: seine deklarierten Ziele; ein nicht
  deklarierter indirekter Aufruf unter einem Lock ist `UNDECLARED_INDIRECT_CALL`, eine Zuweisung
  außerhalb der Menge `UNDECLARED_FN_TARGET`.

Außerhalb eines `@threadsafe`-Bereichs parst kenbi sie und gibt sie mit `severity: "advisory"`
aus (`GUARDED_BY`, `REQUIRES_LOCK`, `ACQUIRES`, `RELEASES`, `LOCK_ORDER`);
**Advisory-Befunde blockieren niemals den Build** — sie sind Direktiven für einen
KI-/menschlichen Prüfer. `// @llm <freeform>` → `LLM_REVIEW` ist eine Freitext-Anweisung, die
dem Prüfer sagt, was zu prüfen ist.

### Mini-Format (Engine-Fixtures)

```
@mem <scoped::name> { size: <id>, free: <id>, owner: <id> }
alloc <var> <resource> | copy <dst> <src> | interior <dst> <src> <off>
use <var> | free <var> | move <var> | if / else / endif
```

## Heute erkannt

Deterministisch (`error` / `warning`): `DOUBLE_FREE`, `USE_AFTER_FREE`,
`USE_AFTER_MOVE`, `LEAK`, `FREE_INTERIOR`, `MOVE_INTERIOR`, `FREE_AFTER_MOVE`,
`MOVE_AFTER_FREE`, `DOUBLE_MOVE`, `WRONG_DEALLOCATOR`, `NULL_DEREF` (eines möglicherweise
nullen Zeigers und — gesondert ausgewiesen — eines Zeigers, von dem kenbi weiß, dass er null IST:
`free(p); p = NULL; *p`, oder ein Lesen nach einer Freigabe, die als NULL-zurückgebend deklariert
ist), `CONTRACT_NOT_HONORED`, `UNUSED_MUST_USE`, `DANGLING_RETURN` (Rückgabe eines Zeigers in
eine lokale Variable / eines freigegebenen Zeigers), `BORROW_FREED` (ein `@borrows` /
Arena-Objekt einzeln freigegeben), `BORROW_OUTLIVES_OWNER` (Verwendung, nachdem der Eigentümer /
die Arena weg ist), `UNCONTRACTED_ESCAPE` / `UNCONTRACTED_RELEASE` (ein besessener Zeiger
überschreitet eine Callee- / Freigabe-Grenze, die keinen Besitzvertrag deklariert — die
default-red-Disziplin), `UNSTRUCTURED_GOTO` (ein rückwärtsgerichtetes / verschachteltes /
berechnetes goto, das kenbi zu modellieren ablehnt), `LOOP_FIXPOINT_LIMIT` (eine Schleife, deren
Analyse innerhalb ihres Iterationslimits nicht konvergiert, abgelehnt statt aus einer
unvollständigen Sicht beurteilt),
`LEAK_ON_THROW` (C++: ein roher Eigentümer, der noch gehalten wird, wo ein Callee ohne
nothrow-Garantie — oder ein einfaches `new` — abwickeln kann; RAII-Eigentümer sind ausgenommen,
`noexcept` / `@nothrow` / `-fno-exceptions` sind die Beweise; innerhalb eines `try` landen die
abwickelnden Ausgänge in den Handlern, die ab ihrer Vereinigung geprüft werden),
`LEAK_ON_LONGJMP` / `LONGJMP_SKIPS_DESTRUCTOR` / `UNDECLARED_LONGJMP` (ein roher Eigentümer oder in
C++ ein Objekt mit nicht-trivialem Destruktor, das noch im Gültigkeitsbereich ist, wo ein Aufruf
`longjmp`en kann; eine Funktion, die einen longjmp erreichen kann, ohne `@longjmps` zu deklarieren),
`UNSUPPORTED_SETJMP` (ein `setjmp`-Landepunkt, noch nicht modelliert),
`FINALLY_BYPASSED` (ein besitzender Ausgang umgeht einen deklarierten `@goto_finally`-Trichter),
`FREE_NONHEAP` (ein `free` eines Zeigers in Stack- oder anderen Nicht-Heap-Speicher),
`BORROW_MOVED` / `UNCONTRACTED_MOVE` (ein Move aus einem Borrow heraus oder in einen Callee, der
keine Übernahme deklariert), `REALLOC_UNVERIFIED` / `REALLOC_SELF_REASSIGN` (ein `realloc`, dessen
Ergebnis vor der Verwendung nicht geklärt ist oder dessen einziges Handle überschrieben wird),
`MISSING_COPY_CONTROL` / `SELF_ASSIGN_UNSAFE` / `DELETE_NONVIRTUAL_BASE` (C++), `UNSUPPORTED_CONSTRUCT` (eine Allokation oder
Freigabe in einem Konstrukt, das kenbi nicht modelliert, abgelehnt statt verworfen), sowie die
Hygieneprüfungen `UNKNOWN_RESOURCE` / `STALE_UNSAFE`. Unter den Opt-in-Achsen:
`UNVALIDATED_INDEX`, `UNVALIDATED_SIZE`, `INAPPROPRIATE_BOUND`, `INDEX_MAYBE_NEGATIVE`,
`UNGUARDED_INVARIANT_WRITE`, `INVARIANT_NOT_MAINTAINED` (`@spatial`), `USE_OF_UNINITIALIZED`
(`@initcheck`), `TYPE_CONFUSION` (`@typecheck`) sowie `UNGUARDED_ACCESS`, `GUARDED_ESCAPE`,
`LOCK_LEAKED`, `DOUBLE_LOCK`, `UNLOCK_WITHOUT_LOCK`, `LOCK_NOT_ACQUIRED`,
`REQUIRED_LOCK_NOT_HELD`, `LOCK_ORDER_VIOLATION`, `SAME_CLASS_NO_ORDER`,
`UNDECLARED_INDIRECT_CALL`, `UNDECLARED_FN_TARGET` (`@threadsafe`). Schleifen
(`for`/`while`/`do` und deklarierte Goto-Loops) werden durch einen **beschränkten Fixpunkt** bis
zur Konvergenz analysiert, sodass iterationsübergreifende Gefahren erkannt werden;
`break`/`continue` und vorwärtsgerichtete Goto-Aufräumleitern werden modelliert; Lecks werden an
jedem Funktionsausgang geprüft.

Advisory (`advisory`-Schweregrad, blockiert nie — für die Prüfschicht): `GUARDED_BY`,
`REQUIRES_LOCK`, `ACQUIRES`, `RELEASES`, `LOCK_ORDER`, `LOCK_ORDER_CONFLICT`,
`LLM_REVIEW`, `ESCAPE_UNCHECKED` (Besitz, der in ein Feld gespeichert wird, das kenbi nicht
verfolgt — die Grenze wird sichtbar gemacht, nicht stillschweigend verworfen),
`POSSIBLE_DOUBLE_FREE` / `POSSIBLE_USE_AFTER_FREE` (ein unvertraglicher Callee, dessen sichtbarer
Rumpf das Argument freigibt — ein Hinweis, bis `@frees` deklariert wird, was es bestätigt),
`CONTRACT_UNBOUND` (ein Vertrag, der einen Parameter benennt, den die Signatur nicht hat) und
`UNKNOWN_VAR` (kenbi hat an dieser Stelle keinen Ursprung für ein Handle erfasst, daher wird dort
nichts geprüft — ein Stolperdraht für kenbis eigene Buchführung, nie eine Aussage über den Code).

## Demonstriert: `unsafe` in Rust → verifiziert, ohne `@unsafe`, in kenbi

Eine doppelt verkettete Liste mit Rückverweisen (`prev` *und* `next`) benötigt
`unsafe`-Rohzeiger in sicherem Rust (oder `Rc<RefCell<…>>`/`Weak`, was zur
*Laufzeit* geprüft wird): der Borrow-Checker kann den geteilten, zyklischen Besitz
der Verkettung nicht ausdrücken — die std-`LinkedList` selbst ist mit `unsafe`
gebaut.

Dieselbe Struktur unter kenbis `@arena`-Disziplin ([`demo/dll.c`](demo/dll.c))
verifiziert **speichersicher ohne `@unsafe`**:

```
$ kenbi demo/dll.c
demo/dll.c: ok — no findings from the checks that ran
  checked: ownership; not checked: bounds, locks, initialisation, tagged unions
```

Jeder Knoten lebt in der Arena, die zyklischen `prev`/`next`-Zeiger teilen die
Lebensdauer der Arena, kein Knoten wird einzeln freigegeben, und nichts wird nach
der Zerstörung der Region verwendet — alles statisch geprüft, auf allen Pfaden. Wo
sicheres Rust `unsafe` erzwingt, um die zyklischen Verweise *auszudrücken*,
*verifiziert* kenbi sie unter einer deklarierten, geprüften Disziplin.

**Ehrlicher Geltungsbereich.** Dies ist Speichersicherheit (kein Use-after-Free /
Double-Free / Leck / Use-after-Region-Free / Einzel-Free) unter der *deklarierten*
`@arena`-Disziplin — **nicht** Rusts volle Garantie: sie erzwingt weder
Aliasing-XOR-Mutation (`&mut`) noch Datenrennen-Freiheit, und die Arena tauscht
Speicher (die gesamte Region wird auf einmal freigegeben) gegen die Einfachheit
ein. Die Behauptung ist eng und real: kenbi kann eine *Disziplin beherbergen*
(Region-Besitz), unter der dieses Muster statisch prüfbar ist, wo eine Sprache mit
einem einzigen Modell auf `unsafe` herabsteigen muss. Vergleiche
[`demo/vec.c`](demo/vec.c) (ein `Vec<i32>`-Äquivalent): manuelles `malloc`,
gespeichert in ein Struct-Feld, verifiziert sauber, löst aber eine
`ESCAPE_UNCHECKED`-**Advisory** aus — der Besitz des Feldes wird ehrlich als
ungeprüft markiert, nicht stillschweigend weitergereicht.

## Ein Allocator, viele typisierte Destruktoren

Reale Projekte allozieren mit einem generischen Wrapper und geben über typisierte Destruktoren
darum herum frei. `free:` / `free_returns_null:` akzeptieren daher mehrere Freigabenamen — alle
gültige Freigaben der Familie, alles andere bleibt `WRONG_DEALLOCATOR` —, und `frees_fields:`
hält fest, dass ein solcher Destruktor auch die besessenen Felder des Objekts freigibt:

```c
// @allocator magick::mem { alloc: AcquireQuantumMemory AcquireKernelInfo …,
//                          free_returns_null: RelinquishMagickMemory DestroyKernelInfo …,
//                          frees_fields: DestroyKernelInfo … }
```

Einen Container freizugeben, während ein Feld noch besitzt, ist standardmäßig ein `LEAK` —
richtig für ein schlichtes `free(s)`, falsch für einen Destruktor, der genau dazu da ist, den
Graphen freizugeben; daher ist es die Deklaration, die das erlaubt, und eine nicht deklarierte
Freigabe bleibt RED.

Die Paare auf ImageMagick zu deklarieren, ERHÖHT die Zahl (689 → 729 über die 95 Dateien), was
die Hülle ist, die sich nach außen ausdehnt, und keine Regression: Ein Aufruf
`DestroyKernelInfo(kernel)` war vorher eine unvertragliche Grenze — kenbi konnte nicht sehen, dass
dort eine Freigabe stattfand, also wurde nichts, was hindurchging, geprüft — und ist jetzt eine
Freigabe, die es prüft, was wiederum die Frage aufwirft, wem das Objekt gehört. Es fand auch ein
echtes Leck: `OrderedDitherImage` (threshold.c) kehrt bei einem Fehlschlag von
`SetImageStorageClass` ohne das `DestroyThresholdMap` zurück, das jeder andere Ausgang ausführt.

*Gemessen im September 2026 an ImageMagick 7.1.2-27 mit dem damaligen Stand von kenbi; spätere Versionen von kenbi melden andere Gesamtzahlen.*

## Code mit Verträgen versehen, den Sie nicht bearbeiten dürfen

Jeder obige Vertrag muss über einer Deklaration stehen — und ein Drittanbieterprojekt bietet
keinen Ort, um einen hinzuschreiben. `@contract` benennt stattdessen die Funktion, sodass das
gesamte Vokabular aus einem zwangsweise eingebundenen (force-included) Overlay-Header
funktioniert, der nur aus Kommentaren besteht:

```c
// @contract qsort            { borrows: $1 }
// @contract DestroyKernelInfo { frees: $1 }
// @contract AddValueToSplayTree { borrows: $1, moves: $2 $3 }
```

Parameter werden sowohl über ihre POSITION (`$1`, 1-basiert) als auch über ihren Namen benannt,
was meist nötig ist: C-Header deklarieren Parameter häufig unbenannt, und die Aufrufstellen, die
den Vertrag brauchen, sehen nur den Prototyp.

Es ist derselbe Vertrag, aufgelöst über dieselbe Bindung — er wird also **geprüft, nicht
vertraut**. Eine `frees:`-Deklaration an einer Funktion, deren Rumpf in der Übersetzungseinheit
liegt, wird dagegen verifiziert (`CONTRACT_NOT_HONORED`, wenn er nicht freigibt); einen als
`borrows:` deklarierten Parameter freizugeben, ist `BORROW_FREED`; und das Deklarieren eines
Borrows lässt die Freigabe weiterhin beim Aufrufer, sodass ein übergebener und nie freigegebener
Zeiger zu einem sichtbaren `LEAK` wird statt zu einer unentscheidbaren Grenze. Ein Vertrag, der
einen Parameter benennt, den die Signatur nicht hat, bindet nichts — die Grenze bleibt RED, die
sichere Richtung, mit einer `CONTRACT_UNBOUND`-Advisory, die den Grund nennt.

Auf ImageMagicks MagickCore (95 Dateien, seine eigene Kompilierzeile) senken zehn
`borrows`-Deklarationen in
[`demo/imagemagick/kenbi_magick_api.h`](demo/imagemagick/kenbi_magick_api.h) die Befunde von 657
auf 626 und `UNCONTRACTED_ESCAPE` von 249 auf 216 — und bringen zwei neue `LEAK`s zum Vorschein,
was der Mechanismus bei der Arbeit ist: Eine deklarierte Grenze ist eine entscheidbare. Für eine
*Factory* ist `@allocator` vorzuziehen — den Namen in die `alloc:`-Liste einer Familie
aufzunehmen, benennt auch die Ressource und ihren Deallocator, sodass auch Lecks und
`WRONG_DEALLOCATOR` geprüft werden (das allein beseitigte 16 der 26 unvertraglichen Freigaben in
xml-tree.c).

*Gemessen im September 2026 an ImageMagick 7.1.2-27 mit dem damaligen Stand von kenbi; spätere Versionen von kenbi melden andere Gesamtzahlen.*

## Intrusive Listen: das Glied deklarieren, das Leeren deklarieren

Die andere C-Liste — Knoten auf dem Heap, über ein Feld verkettet, einzeln freigegeben — ist
keine Arena, und hier zeigt sich kenbis Ressourcenmodell pro Allokationsstelle. Jeder Knoten
stammt aus einem einzigen `malloc`, also sah kenbi eine Ressource, wo das Programm eine Kette von
Objekten hat: Eine Freigabe in einem Durchlauf las sich als Freigabe „der" Ressource und der
nächste Schritt als Use-after-Free.

Zwei Deklarationen machen die Kette prüfbar, und keine wird auf Vertrauen angenommen:

```c
/* @mem t::n { free: free, owner: cur, link: next } */   /* per resource… */
// @list Cluster { link: next }                           /* …or per record TYPE */

/* @drains(head) */
for (cur = head; cur != NULL; cur = nxt) { nxt = cur->next; free(cur); }
```

`link:` sagt, dass die Ressource ein KNOTEN einer über dieses Feld verketteten Sammlung ist,
sodass ein Durchlaufschritt ein weiteres Element ist statt eines Zeigers, den kenbi nicht
zuordnen kann, und eine Freigabe im Durchlauf ein ELEMENT entfernt. `@drains(head)` sagt, dass
eine Schleife jedes Element freigibt — und kenbi prüft das: Eine Schleife, die nichts freigibt,
ist `CONTRACT_NOT_HONORED`, eine Sammlung, die nichts leert, ist ein `LEAK`,
`free(cur); cur = cur->next;` ist ein `USE_AFTER_FREE`, einen Cursor zweimal freizugeben, bevor er
weiterrückt, ist ein `DOUBLE_FREE`, und jeder Cursor hängt, sobald die Sammlung geleert ist.

[`demo/list.c`](demo/list.c) ist das Ganze in 30 Zeilen — aufbauen, durchlaufen, leeren — und es
verifiziert sauber:

```
$ kenbi demo/list.c
demo/list.c: ok — no findings from the checks that ran
  checked: ownership; not checked: bounds, locks, initialisation, tagged unions
```

Die TYP-Form erreicht Code, den kenbi nicht bearbeiten kann. ImageMagicks Cluster-Liste wird in
neun Funktionen von `MagickCore/segment.c` durchlaufen; eine einzige reine Kommentarzeile in einem
zwangsweise eingebundenen Overlay
([`demo/imagemagick/kenbi_magick_lists.h`](demo/imagemagick/kenbi_magick_lists.h)) bringt diese
Datei von 83 auf 14 Befunde, wobei alle 54 `USE_AFTER_FREE` und 4 `DOUBLE_FREE` verschwinden.
Was ein Header nicht sagen kann, ist, welche Schleife die Liste leert — das ist eine Tatsache
über eine Anweisung —, daher bleiben diese Sammlungen RED, bis das Leeren an der Schleife
deklariert ist. Das ist die Frage, die kenbi stellen sollte, nicht eine, die es von außerhalb der
Datei beantworten kann.

*Gemessen im September 2026 an ImageMagick 7.1.2-27 mit dem damaligen Stand von kenbi; spätere Versionen von kenbi melden andere Gesamtzahlen.*

## Konfigurierte Low-Level-Verifikation (`--safety`)

Manche Eigenschaften von Low-Level-Code stehen überhaupt nicht im Quelltext: welche Funktionen in
einem Interrupt laufen, was eine Geräte-API tun darf, wie viel Stack ein Build verbraucht, welchen
Speicher eine DMA-Engine erreichen kann. `--safety=project.json` entnimmt sie einer Projektdatei
und Vertragsdateien und prüft den Quelltext dagegen:

```sh
kenbi --format=json --safety=demo/safety/project.json
```

| Eigenschaft | Dokument |
|---|---|
| verbotene Effekte in einer Aufrufhülle (Allokation, Blockieren, Warten, Rekursion), pro Block oder Funktion | [Effekte](docs/configured_effects.md), [Rekursion](docs/configured_recursion.md), [Effekte pro Zustand](docs/configured_state_effects.md) |
| Ressourcen-Zustandsautomaten (Reihenfolge der Operationen, Endzustände, Ergebnisse je Rückgabewert) | [Protokolle](docs/configured_protocols.md), [Ergebnisse](docs/configured_protocol_results.md), [Blöcke](docs/configured_protocol_blocks.md), [Funktionsgrenzen](docs/configured_function_boundaries.md) |
| von asynchronen Operationen geliehene Puffer (keine Änderung, Freigabe oder Wiederverwendung vor Abschluss) | [asynchrone Borrows](docs/configured_async_borrows.md), [Kapazität](docs/configured_borrow_capacity.md), [Ausrichtung](docs/configured_borrow_alignment.md), [Puffermarkierungen](docs/configured_buffer_marks.md), [schreibgeschützter Speicher](docs/configured_storage_permissions.md) |
| Ausführungskontexte (Interrupt, Thread) und die APIs, die jeder erlaubt | [Kontexte](docs/configured_contexts.md) |
| Bereich und Ausrichtung von Lese-, Schreib- und API-Zugriffen | [Quelltextzugriffe](docs/configured_source_access.md), [API-Kapazität](docs/configured_access_capacity.md), [API-Ausrichtung](docs/configured_access_alignment.md), [zurückgegebene Zeiger](docs/configured_return_pointer.md), [Zeiger-Neuzuweisung](docs/configured_pointer_bindings.md) |
| Schleifen und Zähler in geordneten Prüfungen | [for](docs/configured_for_loops.md), [do-while](docs/configured_do_while.md), [vorzeichenlose Aktualisierungen](docs/configured_unsigned_updates.md), [Integer-Parameter](docs/configured_integer_parameters.md) |
| Allokationsverträge, Pool- und Heap-Grenzen, Speicherregionen | [Allokation](docs/configured_allocation.md), [Speicherregionen](docs/configured_memory_regions.md) |
| Aufruftiefe und Stack-Verbrauch (aus der `-fstack-usage`-Ausgabe des Compilers) | [Aufruftiefe](docs/configured_call_depth.md), [Stack-Verbrauch](docs/configured_stack_usage.md) |
| MMIO-Registerkarten (nur lesbar / nur schreibbar, Write-1-to-Clear, Read-to-Clear, reservierte Bits, Zugriffsbreite, erforderliche Barrieren) | [MMIO](docs/configured_mmio.md) |
| von einem externen WCET-Werkzeug gelieferte Ausführungszeitschranken, an den Build gebunden | [Ausführungszeit](docs/configured_execution_time.md) |
| Bindung von Vertragsdateien an die Quelltexte, Kompilieroptionen und das Ziel, für die sie geschrieben wurden | [Artefakte](docs/configured_contract_artifacts.md), [Kompilierung](docs/configured_contract_compilation.md), [Ziel](docs/configured_contract_target.md) |

Jede Verpflichtung wird als `verified`, `conditional` (gilt unter externen Verträgen, die das
Ergebnis als Annahmen auflistet), `unverified` oder `violation` gemeldet. Alles, was kenbi nicht
auflösen kann, ist `unverified`, und der Lauf besteht nur, wenn jede Verpflichtung `verified` ist
oder `conditional` unter Annahmen, die die Projektdatei ausdrücklich akzeptiert. Die obigen
Dokumente sind auf Japanisch, und jedes gibt an, was es nicht abdeckt.
[`demo/safety/`](demo/safety/) und [`demo/dma/`](demo/dma/) sind ausgearbeitete Beispiele auf
fiktiven Geräten.

## Was ein GREEN verspricht und was nicht

Ein GREEN bedeutet: Innerhalb der ausgeführten Prüfungen, auf dem Code, den kenbi analysiert hat,
entspricht jeder Pfad den deklarierten Verträgen. Es bedeutet nicht:

- **Sicher über die eingeschalteten Achsen hinaus.** In einer Datei ohne `@spatial` wurden keine
  Grenzen geprüft; wo `@kenbi` einen Teil einer Datei markiert, wurde im Rest nichts geprüft.
- **Sicher über die Verträge hinaus.** Einem Vertrag auf Code, den kenbi nicht gesehen hat, wird
  vertraut, und er wird als vertrauenswürdige Grenze aufgeführt; `@unsafe` ist das Wort des
  Autors und wird ebenfalls aufgeführt. `verified` ist die Antwort, bei der nichts auf Vertrauen
  angenommen wird.
- **Sicher über das hinaus, was der Build definiert.** Vom Präprozessor ausgeschlossener Code, eine
  andere `compile_commands.json` oder ein anderes Ziel wurden nicht analysiert.

Was kenbi nicht modellieren kann, lehnt es ab, statt es zu überspringen: `UNSTRUCTURED_GOTO`
(rückwärtsgerichtete Gotos, Sprünge zu verschachtelten Labels, berechnete Gotos),
`LOOP_FIXPOINT_LIMIT`, `UNSUPPORTED_CONSTRUCT` und `unverified` unter `--safety`. Bei großem realem
Code sind diese Ablehnungen Teil des Ergebnisses — eine Funktion, die eine enthält, bleibt RED,
bis sie umstrukturiert oder deklariert wird.

Wenn Sie ein GREEN finden, das keines sein sollte, melden Sie es bitte mit einer minimalen
Reproduktion: Das ist die schwerwiegendste Art von Fehler, die kenbi haben kann.

## Architektur

Die Analyse-Engine ist vom Frontend entkoppelt: Sie arbeitet auf einer frontend-unabhängigen
IR, sodass das Parsen von C/C++ ein austauschbarer Teil ist.

```
*.c / *.cpp  ──▶ libclang front-end  ┐
                 (src/frontend_c.nim) ├─▶ Program IR ─▶ typestate engine ─▶ diagnostics
*.mc         ──▶ mini-format parser  ┘   (src/ir.nim)   (src/analyze.nim)
                 (src/parse.nim)
```

| Datei | Rolle |
|---|---|
| `src/ir.nim` | frontend-unabhängige IR (`Program`: Ressourcen + Anweisungsbaum) |
| `src/analyze.nim` | Typestate-Engine (Ursprünge, May-Set-Zusammenführung, Schleifen-Fixpunkt, Leck-Scan, Abdeckung) |
| `src/clang.nim` | minimales libclang-FFI (By-Value-Strukturen passend zum C-ABI) |
| `src/frontend_c.nim`, `src/cfront_*.nim` | überführen echtes C/C++ und die Annotationskommentare in `Program` |
| `src/annotations/` | Registry des Annotationsvokabulars |
| `src/compile_db.nim` | extrahiert Parse-Flags aus `compile_commands.json` |
| `src/safety_config.nim`, `src/safety_check.nim` | `--safety`: Projekt- und Vertragsdateien, konfigurierte Prüfungen |
| `src/effect_facts.nim`, `src/protocol_*.nim` | `--safety`: Effekte der Aufrufhülle, Zustandsautomaten und Borrows |
| `src/parse.nim` | Mini-Format-Parser (Engine-Fixtures) |
| `src/kenbi.nim` | CLI: Verteilung nach Dateiendung, Ausgabe der Diagnosen |

## Tests

`tests/*.mc` treiben die Engine direkt an (17 Fälle). `tests/c/*.c` und `tests/cpp/*.cpp` tragen
diese Szenarien plus die annotationsspezifischen Prüfungen in echtem C und C++ (349 Fälle); der
Runner überführt jedes über libclang und prüft die erzeugten Diagnosen — **einschließlich ihrer
Quellzeile** — gegen die `//EXPECT CODE`-Marker in jeder Datei (in der Zeile selbst oder
`//EXPECT CODE@LINE`). Eine falsche Zeile oder eine fehlende / überzählige
Diagnose lässt die Suite fehlschlagen. `tests/run_tests_project.nim` prüft das projektweite
Abdeckungsergebnis, die `tests/run_tests_*.py`-Suiten prüfen `--safety` durchgängig, und
`demo/verify_three_state.py` prüft den [Drei-Zustands-Korpus](demo/README_three_state.md) und das
daraus generierte Material des MCP-Servers.

## Lizenz

kenbi steht unter der Apache License 2.0 ([LICENSE.md](LICENSE.md)). Material aus anderen Projekten
und dessen Lizenzen sind in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) verzeichnet.
