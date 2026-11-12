# kenbi

[English](README.md) · [简体中文](README.zh.md) · [日本語](README.ja.md) · **Español** · [Português](README.pt.md) · [Français](README.fr.md) · [Deutsch](README.de.md)

**kenbi comprueba el código C y C++ frente a las reglas de seguridad de memoria que declara.** Escribes como comentarios, junto al código, quién posee un búfer, quién lo libera y cuánto dura un préstamo; kenbi comprueba, estáticamente y en cada camino, que el código hace lo que dicen esos comentarios. No es un compilador y no cambia tu build.

**Pensado para escribir C/C++ con agentes de IA.** A través de su [servidor MCP](#con-agentes-de-programación-con-ia-mcp), un agente comprueba el C/C++ que acaba de escribir, pregunta por qué aparece un hallazgo y cómo es la corrección, y repite hasta que las comprobaciones no informan de nada. La seguridad de memoria pasa a formar parte del ciclo de escritura del agente en lugar de una revisión posterior, y las anotaciones que escribe quedan en el código como reglas que kenbi sigue comprobando.

> Estado: **v0.1.0**, desarrollo temprano. Las interfaces, el vocabulario de anotaciones y la
> salida JSON aún pueden cambiar.

## Un primer vistazo

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

`@kenbi` somete el archivo a la comprobación de propiedad, y `@mem` declara un tipo de recurso y cómo se reserva y se libera. Cambia el retorno anticipado por `{ free(p); return NULL; }` y el archivo informa `ok — no findings from the checks that ran`, con código de salida 0. La línea `checked:` forma parte de cada resultado: la ausencia de hallazgos solo cubre las comprobaciones que enumera.

## En qué se diferencia

- **Declarado, no inferido.** kenbi no adivina qué significa el código. Lo comprueba frente a lo que declaran las anotaciones, así que un hallazgo es un lugar donde el código se aparta de una regla establecida, no un patrón que parece sospechoso.
- **Lo no demostrado no es verde.** Donde kenbi no puede mostrar que cada camino cumple las reglas, informa de un hallazgo, y lo que no puede modelar (un `goto` hacia atrás, por ejemplo) también lo informa en lugar de saltárselo. Un resultado sin hallazgos es la afirmación que kenbi respalda.
- **Cada camino, sin ejecutar el código.** Los sanitizers y las pruebas ven los caminos que se ejecutan; kenbi sigue cada camino a través de bucles, retornos anticipados, escaleras de limpieza con `goto` y excepciones de C++.
- **Determinista, con su alcance indicado.** La misma entrada da la misma salida, y cada resultado nombra las comprobaciones ejecutadas, los contratos en los que se apoya y cada `@unsafe` que silenció un hallazgo.
- **Adopción gradual.** Cada comprobación se activa por separado, por archivo, función o bloque, para que el código existente no se convierta en un muro rojo.

## Con agentes de programación con IA (MCP)

El [servidor MCP](mcp/README.md) da a un agente el verificador y el material para actuar en consecuencia:

| | qué recibe el agente |
|---|---|
| `check_memory_safety` | los hallazgos de kenbi, con un resumen que indica qué comprobaciones se ejecutaron sobre qué funciones, para que «sin hallazgos» nunca se lea como «seguro» |
| `explain_finding` | para un código de hallazgo o un identificador CWE: qué lo provoca, por qué una corrección a medias sigue fallando, y la corrección con el contrato que declara |
| `kenbi://annotations` | la referencia de anotaciones |
| `kenbi://patterns` | formas seguras de C/C++ que kenbi acepta, junto a las formas inseguras que rechaza |

El ciclo es escribir → comprobar → explicar → corregir → volver a comprobar, y es kenbi, no el modelo, quien decide cuándo termina. El servidor también indica al agente que no repita en comentarios lo que una anotación ya dice: la anotación se comprueba, un comentario no.

El ciclo sobre [`demo/quickstart.c`](demo/quickstart.c), con las respuestas reales del servidor (a cada resumen le sigue el documento JSON completo de kenbi, omitido aquí):

1. El agente escribe `dup_name` y llama a `check_memory_safety`:

   ```text
   kenbi: 1 error(s), 0 warning(s) across 1 file(s):
     demo/quickstart.c:8: error: leak: 'app::buf' allocated here is never freed or moved [LEAK]

   Scope — the result covers only this:
     - ownership, lifetime and null (`@kenbi`, or a file with no marker): checked in every function
     - NOT checked anywhere: bounds (`@spatial`); locks (`@threadsafe`); initialisation (`@initcheck`); tagged unions (`@typecheck`)
     - verified (nothing taken on trust): 0 of 1 adopted memory-relevant functions
     - code the preprocessor excluded under these flags was not analysed
   ```

2. Llama a `explain_finding` con `LEAK` y recibe ejemplos desarrollados; el primero termina con la corrección:

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

3. Libera `p` en el retorno anticipado (`if (p[0] == '\0') { free(p); return NULL; }`) y vuelve a comprobar:

   ```text
   kenbi: no findings in 1 file(s) from the checks that ran. This is not a statement about anything outside the scope below.

   Scope — the result covers only this:
     - ownership, lifetime and null (`@kenbi`, or a file with no marker): checked in every function
     - NOT checked anywhere: bounds (`@spatial`); locks (`@threadsafe`); initialisation (`@initcheck`); tagged unions (`@typecheck`)
     - verified (nothing taken on trust): 1 of 1 adopted memory-relevant functions
     - code the preprocessor excluded under these flags was not analysed
   ```

[`integrations/agent/`](integrations/agent/) contiene instrucciones equivalentes para Claude Code (`SKILL.md`), agentes tipo Codex (`AGENTS.md`) y GitHub Copilot.

La configuración está en [`mcp/README.md`](mcp/README.md#configure-in-an-mcp-client).

## Qué comprueba

Cada comprobación se activa por separado:

| eje | activación | qué se comprueba |
|---|---|---|
| propiedad / tiempo de vida | `@kenbi` (o un archivo sin marcador) | use-after-free, double free, fugas en cada salida, use-after-move, desasignador incorrecto, retornos colgantes, tiempos de vida de préstamos y arenas, contratos declarados frente a los cuerpos de las funciones, propietarios RAII de C++, punteros inteligentes y vías de excepción |
| nulo | siempre, con `@nullable` / `@nonnull` | desreferencia de un puntero posiblemente nulo o que se sabe nulo, con estrechamiento sensible al flujo |
| límites | `@spatial` | un índice o tamaño no confiable que llega a un búfer necesita una comprobación de límites presente, suficiente y segura frente a desbordamiento; `@counted_by` e invariantes declarados de estructuras de datos (`@invariant` / `@maintains`) |
| inicialización | `@initcheck` | una variable local leída antes de asignarse en todas las vías |
| uniones etiquetadas | `@typecheck` + `@variant` | un miembro de unión usado donde su etiqueta no está demostrada |
| locks | `@threadsafe` | acceso sin protección, locks desequilibrados, orden de locks declarado (deadlock AB-BA) |
| propiedades de bajo nivel | `--safety=project.json` | efectos prohibidos en un cierre de llamadas, máquinas de estados de recursos, profundidad de pila y de llamadas, regiones de memoria, MMIO y más — ver [Verificación configurada de bajo nivel](#verificación-configurada-de-bajo-nivel---safety) |

Un front-end libclang baja («lowering») C / C++ real (leyendo `compile_commands.json`) a un motor
de typestate. Los bucles se analizan hasta un punto fijo acotado; las escaleras de limpieza con
`goto` hacia adelante, `break` / `continue` y `try` / `catch` se modelan, y todo lo que kenbi no
puede modelar se reporta en lugar de omitirse. La salida es texto o `--format=json`.

## Inicio rápido

```sh
# Debian / Ubuntu; for other systems see "Instalar libclang según el sistema operativo" below.
# Nim 2.2 or later: https://nim-lang.org/install.html
sudo apt-get install libclang1-14 libclang-common-14-dev
git clone https://github.com/puffball1567/kenbi
cd kenbi
nimble build -d:release
./kenbi demo/quickstart.c
```

## Requisitos

- **Nim** >= 2.2 ([instalación](https://nim-lang.org/install.html))
- **libclang** (la biblioteca compartida; las cabeceras `clang-c` *no* hacen
  falta — solo el `.so` / `.dylib` / `.dll` de ejecución, cargado dinámicamente
  al arrancar).
- **las cabeceras integradas de clang** (`stddef.h`, `stdarg.h`, …), que libclang necesita para
  analizar cualquier archivo que incluya una. La mayoría de los paquetes de clang/LLVM las
  instalan con la biblioteca; en Debian y Ubuntu son el paquete aparte `libclang-common-N-dev`.

libclang se carga por su soname en tiempo de ejecución; la lista de búsqueda por
defecto cubre `libclang.so`, `libclang-13..18.so`, etc. Si tu biblioteca tiene
otro nombre o ruta, anúlalo en tiempo de compilación:

```sh
nimble build -d:release -d:kenbiLibclang=/full/path/to/libclang.so
```

## Compilación y pruebas

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

### Instalar libclang según el sistema operativo

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

**macOS** (LLVM de Homebrew, o las Xcode Command Line Tools)
```sh
brew install llvm
nimble build -d:release -d:kenbiLibclang="$(brew --prefix llvm)/lib/libclang.dylib"
# Apple's Command Line Tools also ship a libclang at
#   /Library/Developer/CommandLineTools/usr/lib/libclang.dylib
```

**Windows** (MSVC + versión de LLVM)
```bat
:: install LLVM from https://releases.llvm.org and ensure libclang.dll is on PATH
nimble build -d:release -d:kenbiLibclang=libclang.dll
```

## Uso

```
kenbi [--format=text|json] [--compile-commands=PATH] [--project[=PATH]] [--emit-contracts]
      <file> [more...] [-- <extra clang args>]
kenbi [--format=text|json] --safety=project.json
kenbi --version
```

- `kenbi --version` muestra la versión de kenbi y la libclang que cargó.
- `*.c *.cc *.cpp *.cxx` → front-end libclang (C o C++ según la extensión).
- `*.mc` → mini-formato.
- Para C/C++, los flags de análisis provienen de `compile_commands.json`: pásalo
  con `--compile-commands=PATH`, o se descubre automáticamente subiendo desde el
  archivo fuente. Todo lo que va tras `--` se añade a la línea de comandos de clang.
- `--project[=compile_commands.json]` analiza cada unidad de traducción que lista la base
  de datos. Los hallazgos de cada archivo siguen siendo suyos (las anotaciones tienen ámbito de
  archivo, y el análisis también) — lo que esto añade es el **cierre**: una llamada contratada a
  una función definida en otra unidad analizada se resuelve con el veredicto de esa unidad, de
  modo que un GREEN cuyo cierre de dependencias completo está analizado y es GREEN cuenta como
  *verificado*, y la frontera de confianza se reduce a lo que nada en el proyecto define (una
  biblioteca distribuida como binario, el sistema operativo, un borde FFI). Sin ruta, la base de
  datos se busca subiendo desde el primer archivo indicado.
- `--format=json` emite hallazgos legibles por máquina con códigos estables (para
  CI, editores y agentes); `--format=text` (por defecto) es legible para humanos.
- `--safety=project.json` ejecuta las comprobaciones de bajo nivel configuradas descritas en
  [Verificación configurada de bajo nivel](#verificación-configurada-de-bajo-nivel---safety).
- Código de salida: `0` limpio · `1` problemas encontrados · `2` error de uso / análisis.


## Activación: archivo, función o bloque

`@kenbi` marca lo que está bajo disciplina — los hallazgos fuera de ello se descartan, de modo que
la adopción es gradual y nunca un muro de rojo. El marcador se aplica a lo que tenga debajo:

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

Un bloque bajo disciplina **no** pone bajo ella a su función: esos bloques se cuentan y se
reportan en su propia línea (`blocks adopted`), nunca se suman al recuento de funciones adoptadas.

## Distribuir contratos para una biblioteca

Un overlay de contratos es un archivo de comentarios — puede publicarse junto a una biblioteca, o
escribirlo un consumidor para una biblioteca que nunca ha oído hablar de kenbi. En ambos casos el
receptor tiene que saber qué describe, así que el overlay lo indica y kenbi comprueba lo que puede:

```c
// @contracts_for ImageMagick { version: 7.1.2-27, requires: MAGICKCORE_QUANTUM_DEPTH=16 }
// @allocator magick::mem { alloc: AcquireQuantumMemory, free_returns_null: RelinquishMagickMemory }
// @contract qsort { borrows: $1 }
```

- `requires:` se **comprueba** frente a la línea de compilación. Una build que contradice uno es un
  error (`CONTRACT_PACKAGE_MISMATCH`) — estos contratos se escribieron para una build distinta, así
  que lo que prometen puede no cumplirse. Una condición que la línea de compilación no resuelve se
  reporta como *no verificada*, nunca como satisfecha.
- `version:` se conserva como **declarada**. kenbi no puede leer la versión de una biblioteca a
  partir del código fuente y no finge hacerlo; el informe dice "version declared, not verified".

`--format=json` lo incluye todo (`contractPackages` con `versionDeclared`, `requires`,
`mismatched`, `unverified`, `appliesToThisBuild`), de modo que un consumidor puede decidir si
confiar en un conjunto de contratos antes de apoyarse en él.

### Publicar un conjunto de contratos

`--emit-contracts` imprime la *superficie* de contratos de lo que se haya analizado, en lugar de
comprobarlo — la forma que distribuye una biblioteca para que otra herramienta (otro verificador,
un generador de bindings, el front-end de otro lenguaje) pueda exigir a quienes la llaman los
contratos de la biblioteca sin volver a leer sus comentarios:

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

`resources` es el vocabulario alloc → free: un consumidor al que solo se le indican los
desasignadores no puede saber qué llamada le entregó la obligación en primer lugar. Y cada
contrato lleva el `status` que esta ejecución estableció para la implementación que hay detrás,
porque "un contrato está declarado" no debe poder leerse como "la implementación fue comprobada":

| `status` | qué estableció la ejecución |
|---|---|
| `declared` | no hay implementación aquí (un prototipo, o un contrato escrito desde fuera) — **no se verificó nada** |
| `unchecked` | el cuerpo está presente pero no bajo `@kenbi`: kenbi no lo comprobó |
| `red` | el cuerpo está bajo `@kenbi` y contradice sus contratos — no confíes en él |
| `green` | comprobado y limpio, apoyado en confianza (un callee contratado no cubierto, o un `@unsafe`) |
| `verified` | comprobado y limpio, y también todo su cierre contratado: sin residuo |

Publicar no es comprobar: el documento se imprime y el código de salida es 0 incluso cuando el
código tiene hallazgos. Para obtenerlos, usa una ejecución normal de `kenbi`.

## "GREEN" y "verified" son respuestas distintas

Una anotación no es una prueba, y el resultado de cobertura lo dice:

| | qué significa |
|---|---|
| `GREEN (contracted)` | las fronteras están declaradas — seguro *dados* los contratos en los que se apoya |
| `verified` | todo su cierre de dependencias contratadas está cubierto también: nada se toma por confianza |
| `trusted frontier` | los callees no cubiertos en los que se apoya actualmente un GREEN — cúbrelos para cerrarlo |
| `@unsafe vouches` | los puntos donde el autor afirmó lo que kenbi no pudo comprobar |

`verified` es un subconjunto estricto de `GREEN`. Declarar un contrato sobre un callee no cubierto
lleva una función de RED a GREEN y pone ese callee en la frontera de confianza; un `@unsafe` que
realmente suprime un hallazgo mantiene la función en GREEN y fuera de `verified` para siempre, con
el punto identificado. Así, una operación que kenbi no puede verificar nunca puede leerse como
verificada porque alguien la anotó. Todo esto está en `--format=json` (`green`, `verified`,
`trustedFrontier`, `unsafeVouches`, y `flows` por punto de entrada con sus `blockers`).

```sh
kenbi --compile-commands=build/compile_commands.json src/img.c
kenbi --project=build/compile_commands.json          # the whole project, one closure
kenbi --emit-contracts src/*.c                       # publish the contract set instead
kenbi --format=json src/*.c
kenbi foo.cpp -- -Iinclude -DDEBUG
```

El documento JSON es `{ "version", "tool", "findings": [ { "file", "line",
"code", "severity", "message" } ], "coverage", "scope" }`; los códigos son estables y el orden es
determinista. Los fallos de lectura/análisis aparecen como hallazgos `PARSE_ERROR`.
`scope` indica, por cada archivo analizado, qué comprobaciones se ejecutaron en qué funciones: para cada una de
`ownership`, `bounds`, `locks`, `initialisation` y `taggedUnions`, un `mode` que es `file` (todas las funciones),
`functions` (algunas, con las demás nombradas en `unchecked`) u `off`, además de los bloques adoptados con `@kenbi`
dentro de funciones que por lo demás no se comprueban. Un archivo sin hallazgos está limpio solo dentro de ese
alcance; la salida de texto lo muestra bajo cada archivo.

## Anotaciones

Los recursos se declaran en comentarios y se referencian por un nombre con ámbito,
único en el proyecto. La obligación recae en la *asignación* (su «origen»), no en
la variable: las copias la aliasan, los punteros interiores derivan de ella, y un
`free` / move la salda. Las ramas se fusionan de forma sólida (un estado es posible
tras una unión si lo es en *cualquiera* de las vías — liberar en una sola vía deja,
por tanto, una fuga en la otra).

```c
/* @mem demo::buf { size: n, free: free, owner: p } */
char *p = malloc(n);     // alloc of demo::buf (p is the owner)
char *r = p + 16;        // interior pointer — inferred, must not be freed
consume(p);              // use
sink(p);  // @move demo::buf   — obligation transferred out; p is now moved-from
```

- **asignación**: una inicialización / asignación cuyo lado derecho es de la familia
  `malloc` o un `new` de C++ liga la obligación a la variable destino.
- **liberación**: `free(p)` o `delete` / `delete[] p` en C++.
- **interior**: `p + off` deriva un puntero interior dentro del mismo origen.
- **alias**: `q = p` hace que `q` aliase el origen de `p`.
- **copy**: `// @copy <resource>` en una asignación marca una copia *profunda* — un
  nuevo objeto propio e independiente con su propia obligación, no un mero alias.
- **move**: una llamada en una línea con `// @move` transfiere la obligación.
- **unsafe**: `// @unsafe` en una línea la pone en cuarentena — allí se suprimen
  los hallazgos (asumes la responsabilidad). Un `@unsafe` que no cubre nada se
  reporta como `STALE_UNSAFE`, como un lint-disable sin usar.
- **seguridad de nulos**: `// @nullable` (o `@nonnull`) en una declaración marca si
  un puntero puede ser nulo; desreferenciar un puntero nullable sin una
  comprobación de nulo (`if (p)`, `if (p != NULL)`, `return` temprano) es
  `NULL_DEREF` — la disciplina `Option<T>`, sensible al flujo con estrechamiento
  por rama.
- **contrato frees**: `// @frees(param)` sobre una función declara que libera ese
  argumento. Los puntos de llamada tratan entonces la llamada como liberadora (así
  se compone con double-free / fuga), y se comprueba el cuerpo de la propia función
  — si no libera realmente el parámetro eso es `CONTRACT_NOT_HONORED` (intención
  declarada vs. implementación, algo que una herramienta sin anotaciones no puede
  comprobar).
- **retorno must-use**: `// @must_use` sobre una función declara que su resultado
  debe consumirse; una llamada cuyo valor se descarta (una sentencia desnuda, no
  asignada / retornada / pasada / comprobada) es `UNUSED_MUST_USE` — la disciplina
  `#[must_use]` para códigos de error ignorados y asignaciones con fuga.

### Vocabulario de goto (opcional — declara la intención estructurada de un goto)

Los gotos hacia adelante habituales se modelan automáticamente (sin anotación): una
escalera de limpieza hacia adelante (`if(!p) goto fail; … fail: free()`) se analiza
mediante join-merge, y se admite un goto hacia adelante que sale de un bucle/switch
hacia una etiqueta de limpieza. Un goto-bucle *hacia atrás*, un salto a una etiqueta
anidada o un goto computado siguen rechazándose (`UNSTRUCTURED_GOTO`) — sólido por
rechazo. El vocabulario opcional te permite declarar el significado estructurado de un
goto para que kenbi lo modele y verifique su forma:

- `// @goto_noreturn` sobre una etiqueta marca un término sin retorno (abort / exit
  / longjmp): una vía que lo alcanza termina, así que sus obligaciones aún en
  posesión se saldan — una vía de abort no es una fuga (suprime fugas falsas en
  vías de error-abort).
- `// @goto_finally` sobre una etiqueta marca el embudo de convergencia de la
  limpieza. Disciplina opt-in de embudo único: una salida que aún posee un recurso
  *sin* pasar por el embudo es `FINALLY_BYPASSED` (usa `goto <funnel>` para que la
  liberación ocurra allí). La completitud de la fusión en la convergencia es el
  análisis inferido habitual.
- `// @goto_backward` sobre un goto lo declara una arista de retroceso de bucle: un
  goto-bucle simple se reestructura en un do-while y se analiza con el punto fijo
  acotado (así se capturan los peligros entre iteraciones), en lugar de rechazarse.

### Límites (`@spatial`)

`// @spatial` sobre una función o a nivel de archivo activa el eje de límites para ese ámbito. Un
parámetro escalar no confiable que indexa un búfer, o que determina el tamaño de una escritura como
`memcpy`, debe tener una comprobación de límites presente en la vía — una guarda `if`, una
condición de bucle, `% n`, un clamp o una máscara — o de lo contrario es `UNVALIDATED_INDEX` /
`UNVALIDATED_SIZE`. La comprobación debe cubrir el búfer (`INAPPROPRIATE_BOUND` si está presente
pero es demasiado laxa), un índice con signo necesita además `i >= 0` (`INDEX_MAYBE_NEGATIVE`), y
la aritmética de la guarda no debe desbordarse: `i + 4 <= n` sobre un `i` sin signo no se acepta;
`n >= 4 && i <= n - 4` sí. kenbi busca la comprobación en la vía; nunca elimina ninguna.

- `// @counted_by(<buf>: <len>)` sobre una función da su tamaño a un parámetro puntero, también
  como campo (`b->buf: b->cap`) o como máscara de búfer circular (`b->mask + 1`).
- `// @invariant(<field> <rel> <size>)` declara un invariante de estructura de datos (por ejemplo
  `parser->toknext <= num_tokens`). El campo queda entonces protegido: cada escritura en él necesita
  `// @maintains(...)`, que kenbi verifica (`UNGUARDED_INVARIANT_WRITE`,
  `INVARIANT_NOT_MAINTAINED`), y un índice acotado por el campo queda cubierto a través de la relación.

### Inicialización (`@initcheck`) y uniones etiquetadas (`@typecheck`)

- `// @initcheck` sobre una función o a nivel de archivo: una variable local escalar o puntero
  declarada sin inicializador debe asignarse en todas las vías antes de leerse; de lo contrario,
  `USE_OF_UNINITIALIZED`.
- `// @typecheck` más `// @variant(<member>: <tag> == <value>)` por cada miembro de la unión: usar
  un miembro en una vía donde su etiqueta no está demostrada (`if (n->tag == 1)`, o `case 1:` sobre
  la etiqueta) es `TYPE_CONFUSION`.

### C++

`// @raii` (o `// @raii(Name)`) marca una clase cuyo destructor libera lo que posee, y kenbi
comprueba que el destructor lo haga. Copiar una clase así sin sus propias operaciones de copia es
`MISSING_COPY_CONTROL`, y un `operator=` que libera antes de leer su origen es
`SELF_ASSIGN_UNSAFE`. Eliminar un objeto derivado a través de una clase base sin destructor
virtual es `DELETE_NONVIRTUAL_BASE`. Se modelan `std::unique_ptr` / `std::shared_ptr`, `std::move`, `.get()` /
`.release()` / `.reset()`, las lambdas y las vías de excepción (`LEAK_ON_THROW`, `try` / `catch`,
`noexcept` / `// @nothrow`). La referencia completa la sirve el servidor MCP como
`kenbi://annotations` ([fuente](mcp/src/annotations.ts)).

### Anotaciones de concurrencia (verificadas bajo `@threadsafe`, consultivas fuera de él)

En un ámbito `@threadsafe` (función o archivo) estas se **verifican**, con default-red, mediante la
pasada de typestate de lock retenido:

- `// @guarded_by(<field>: <lock>)` (en una función) o `// @guarded_by(<lock>)` (en un miembro de
  struct): un acceso sin el lock demostrablemente retenido es `UNGUARDED_ACCESS`; tomar la dirección
  del campo protegido es `GUARDED_ESCAPE`.
- equilibrio de locks: `LOCK_LEAKED` / `DOUBLE_LOCK` / `UNLOCK_WITHOUT_LOCK`.
- `// @acquires(<lock>)` / `// @releases(<lock>)`: se verifican en el cuerpo (`LOCK_NOT_ACQUIRED`)
  y se consumen en los puntos de llamada; `// @requires_lock(<lock>)` en un callee:
  `REQUIRED_LOCK_NOT_HELD`.
- `// @lock_order(<a> < <b>)`: `LOCK_ORDER_VIOLATION` (deadlock AB-BA — una garantía que Rust no
  ofrece); las declaraciones en conflicto son `LOCK_ORDER_CONFLICT`. `// @lock_class(<X>)` nombra la
  identidad de un lock para que los órdenes y los contratos coincidan entre funciones y archivos; dos
  instancias de una misma clase necesitan un orden canónico (`SAME_CLASS_NO_ORDER`).
- `// @calls(<fn>, ...)` en un puntero a función: sus destinos declarados; una llamada indirecta no
  declarada bajo un lock es `UNDECLARED_INDIRECT_CALL`, y una asignación fuera del conjunto,
  `UNDECLARED_FN_TARGET`.

Fuera de un ámbito `@threadsafe`, kenbi las analiza y las emite con `severity: "advisory"`
(`GUARDED_BY`, `REQUIRES_LOCK`, `ACQUIRES`, `RELEASES`, `LOCK_ORDER`); **los hallazgos consultivos
nunca bloquean la build** — son directivas para un revisor humano/IA. `// @llm <freeform>`
→ `LLM_REVIEW` es una instrucción de texto libre que indica al revisor qué comprobar.

### Mini-formato (fixtures del motor)

```
@mem <scoped::name> { size: <id>, free: <id>, owner: <id> }
alloc <var> <resource> | copy <dst> <src> | interior <dst> <src> <off>
use <var> | free <var> | move <var> | if / else / endif
```

## Detectado hoy

Deterministas (`error` / `warning`): `DOUBLE_FREE`, `USE_AFTER_FREE`,
`USE_AFTER_MOVE`, `LEAK`, `FREE_INTERIOR`, `MOVE_INTERIOR`, `FREE_AFTER_MOVE`,
`MOVE_AFTER_FREE`, `DOUBLE_MOVE`, `WRONG_DEALLOCATOR`, `NULL_DEREF` (de un puntero
posiblemente nulo y — indicado por separado — de uno que kenbi sabe que ES nulo:
`free(p); p = NULL; *p`, o una lectura tras una liberación declarada que devuelve NULL),
`CONTRACT_NOT_HONORED`, `UNUSED_MUST_USE`, `DANGLING_RETURN` (retorno de un puntero
a un local / un puntero ya liberado), `BORROW_FREED` (un objeto `@borrows` / de
arena liberado individualmente), `BORROW_OUTLIVES_OWNER` (uso después de que el
propietario / la arena haya desaparecido), `UNCONTRACTED_ESCAPE` /
`UNCONTRACTED_RELEASE` (un puntero propio cruza una frontera de callee / liberación
que no declara ningún contrato de propiedad — la disciplina default-red),
`UNSTRUCTURED_GOTO` (un goto hacia atrás / anidado / computado que kenbi se niega a
modelar), `LOOP_FIXPOINT_LIMIT` (un bucle cuyo análisis no converge dentro de su límite de
iteraciones, rechazado en lugar de juzgado con una vista incompleta),
`LEAK_ON_THROW` (C++: un propietario crudo aún retenido donde un callee sin garantía de
nothrow — o un `new` simple — puede desenrollar; los propietarios RAII están exentos,
`noexcept` / `@nothrow` / `-fno-exceptions` son las pruebas; dentro de un `try` las salidas
por desenrollado llegan a los manejadores, que se comprueban desde su unión),
`FINALLY_BYPASSED` (una salida con posesión que evita un embudo `@goto_finally` declarado),
`FREE_NONHEAP` (un `free` de un puntero a la pila u otro almacenamiento no heap), `BORROW_MOVED` /
`UNCONTRACTED_MOVE` (un move fuera de un préstamo, o hacia un callee que no declara recepción),
`REALLOC_UNVERIFIED` / `REALLOC_SELF_REASSIGN` (un `realloc` cuyo resultado no se resuelve antes
del uso, o cuyo único handle se sobrescribe), `MISSING_COPY_CONTROL` / `SELF_ASSIGN_UNSAFE` / `DELETE_NONVIRTUAL_BASE` (C++),
`UNSUPPORTED_CONSTRUCT` (una asignación o liberación en una construcción que kenbi no modela,
rechazada en lugar de descartada), más las comprobaciones de higiene `UNKNOWN_RESOURCE` /
`STALE_UNSAFE`. Bajo los ejes opcionales: `UNVALIDATED_INDEX`, `UNVALIDATED_SIZE`,
`INAPPROPRIATE_BOUND`, `INDEX_MAYBE_NEGATIVE`, `UNGUARDED_INVARIANT_WRITE`,
`INVARIANT_NOT_MAINTAINED` (`@spatial`), `USE_OF_UNINITIALIZED` (`@initcheck`), `TYPE_CONFUSION`
(`@typecheck`), y `UNGUARDED_ACCESS`, `GUARDED_ESCAPE`, `LOCK_LEAKED`, `DOUBLE_LOCK`,
`UNLOCK_WITHOUT_LOCK`, `LOCK_NOT_ACQUIRED`, `REQUIRED_LOCK_NOT_HELD`, `LOCK_ORDER_VIOLATION`,
`SAME_CLASS_NO_ORDER`, `UNDECLARED_INDIRECT_CALL`, `UNDECLARED_FN_TARGET` (`@threadsafe`). Los
bucles (`for`/`while`/`do` y los goto-bucles declarados) se analizan mediante un **punto fijo
acotado** hasta la convergencia, de modo que se capturan los peligros entre iteraciones;
`break`/`continue` y las escaleras de limpieza con goto hacia adelante se modelan; las fugas se
comprueban en cada salida de función.

Consultivos (severidad `advisory`, nunca bloquean — para la capa de revisión): `GUARDED_BY`,
`REQUIRES_LOCK`, `ACQUIRES`, `RELEASES`, `LOCK_ORDER`, `LOCK_ORDER_CONFLICT`,
`LLM_REVIEW`, `ESCAPE_UNCHECKED` (propiedad almacenada en un campo que kenbi no
rastrea — la frontera se expone, no se descarta en silencio), `POSSIBLE_DOUBLE_FREE` /
`POSSIBLE_USE_AFTER_FREE` (un callee sin contratar cuyo cuerpo visible libera el
argumento — una pista hasta que se declara `@frees`, que lo confirma), `CONTRACT_UNBOUND` (un
contrato que nombra un parámetro que la firma no tiene), y `UNKNOWN_VAR`
(kenbi no tiene ningún origen registrado para un handle en ese punto, así que allí no se
comprueba nada — un cable trampa sobre la contabilidad interna de kenbi, nunca una afirmación
sobre el código).

## Demostrado: `unsafe` en Rust → verificado, sin `@unsafe`, en kenbi

Una lista doblemente enlazada con retro-referencias (`prev` *y* `next`) necesita
punteros crudos `unsafe` en Rust seguro (o `Rc<RefCell<…>>`/`Weak`, que se
comprueban en *tiempo de ejecución*): el borrow checker no puede expresar la
propiedad compartida y cíclica de los enlaces — la propia `LinkedList` estándar
está construida con `unsafe`.

La misma estructura bajo la disciplina `@arena` de kenbi ([`demo/dll.c`](demo/dll.c))
se verifica **segura en memoria sin ningún `@unsafe`**:

```
$ kenbi demo/dll.c
demo/dll.c: ok — no findings from the checks that ran
  checked: ownership; not checked: bounds, locks, initialisation, tagged unions
```

Cada nodo vive en la arena, los punteros cíclicos `prev`/`next` comparten el tiempo
de vida de la arena, ningún nodo se libera individualmente, y nada se usa después de
destruir la región — todo comprobado estáticamente, en todas las vías. Donde el Rust
seguro fuerza `unsafe` para *expresar* las referencias cíclicas, kenbi las *verifica*
bajo una disciplina declarada y comprobada.

**Alcance honesto.** Esto es seguridad de memoria (sin use-after-free / double-free /
fuga / use-after-region-free / liberación individual) bajo la disciplina `@arena`
*declarada* — **no** la garantía completa de Rust: no impone aliasing-XOR-mutación
(`&mut`) ni ausencia de carreras de datos, y la arena cambia memoria (toda la región
se libera de una vez) por la simplicidad. La afirmación es estrecha y real: kenbi
puede *albergar una disciplina* (propiedad por región) bajo la cual este patrón es
comprobable estáticamente, donde un lenguaje de modelo único debe recurrir a
`unsafe`. Compárese con [`demo/vec.c`](demo/vec.c) (un equivalente de `Vec<i32>`):
un `malloc` manual almacenado en un campo de struct se verifica limpio pero levanta
una **advertencia consultiva** `ESCAPE_UNCHECKED` — la propiedad del campo se señala
honestamente como no comprobada, no se pasa en silencio.

## Un asignador, muchos destructores tipados

Los proyectos reales asignan con un envoltorio genérico y liberan mediante destructores tipados
construidos sobre él. Por eso `free:` / `free_returns_null:` aceptan varios nombres de liberación —
todos ellos liberaciones válidas de la familia, y cualquier otra sigue siendo `WRONG_DEALLOCATOR` —
y `frees_fields:` registra que ese destructor libera también los campos propios del objeto:

```c
// @allocator magick::mem { alloc: AcquireQuantumMemory AcquireKernelInfo …,
//                          free_returns_null: RelinquishMagickMemory DestroyKernelInfo …,
//                          frees_fields: DestroyKernelInfo … }
```

Liberar un contenedor mientras un campo aún posee algo es un `LEAK` por defecto — correcto para un
`free(s)` simple, incorrecto para un destructor que existe para liberar el grafo, así que es la
declaración la que lo autoriza, y una liberación no declarada sigue en RED.

Declarar los pares en ImageMagick AUMENTA el recuento (689 → 729 en los 95 archivos), lo cual es el
cierre extendiéndose hacia fuera y no una regresión: una llamada `DestroyKernelInfo(kernel)` era
antes una frontera sin contrato — kenbi no podía ver que allí ocurría una liberación, así que nada
a través de ella se comprobaba — y ahora es una liberación que comprueba, lo que a su vez plantea
quién posee el objeto. También encontró una fuga real: `OrderedDitherImage` (threshold.c) retorna
ante un fallo de `SetImageStorageClass` sin el `DestroyThresholdMap` que realizan todas las demás
salidas.

*Medido en septiembre de 2026 sobre ImageMagick 7.1.2-27 con kenbi tal como era entonces; las versiones posteriores de kenbi dan totales distintos.*

## Contratar código que quizá no puedas editar

Cada contrato anterior tiene que situarse sobre una declaración — y un proyecto de terceros no
ofrece dónde ponerlo. `@contract` nombra en cambio la función, de modo que todo el vocabulario
funciona desde una cabecera overlay incluida a la fuerza y compuesta solo de comentarios:

```c
// @contract qsort            { borrows: $1 }
// @contract DestroyKernelInfo { frees: $1 }
// @contract AddValueToSplayTree { borrows: $1, moves: $2 $3 }
```

Los parámetros se nombran por POSICIÓN (`$1`, empezando en 1) además de por nombre, que suele ser
lo necesario: las cabeceras de C declaran a menudo los parámetros sin nombre, y los puntos de
llamada que necesitan el contrato solo ven el prototipo.

Es el mismo contrato, resuelto mediante la misma vinculación — así que se **comprueba, no se
confía en él**. Una declaración `frees:` sobre una función cuyo cuerpo está en la unidad de
traducción se verifica frente a ese cuerpo (`CONTRACT_NOT_HONORED` si no libera); liberar un
parámetro declarado `borrows:` es `BORROW_FREED`; y declarar un préstamo deja al llamador todavía
debiendo la liberación, de modo que un puntero entregado y nunca liberado se convierte en un `LEAK`
visible en lugar de una frontera indecidible. Un contrato que nombra un parámetro que la firma no
tiene no vincula nada — la frontera sigue en RED, la dirección segura, con un consultivo
`CONTRACT_UNBOUND` que explica por qué.

En MagickCore de ImageMagick (95 archivos, su propia línea de compilación), diez declaraciones
`borrows` en
[`demo/imagemagick/kenbi_magick_api.h`](demo/imagemagick/kenbi_magick_api.h) llevan los hallazgos
de 657 a 626 y `UNCONTRACTED_ESCAPE` de 249 a 216 — y sacan a la luz dos `LEAK` nuevos, que es el
mecanismo funcionando: una frontera declarada es una frontera decidible. Para una *factoría*,
prefiere `@allocator` — añadir el nombre a la lista `alloc:` de una familia también nombra el
recurso y su desasignador, de modo que las fugas y `WRONG_DEALLOCATOR` también se comprueban (eso
solo eliminó 16 de las 26 liberaciones sin contrato de xml-tree.c).

*Medido en septiembre de 2026 sobre ImageMagick 7.1.2-27 con kenbi tal como era entonces; las versiones posteriores de kenbi dan totales distintos.*

## Listas intrusivas: declara el enlace, declara el vaciado

La otra lista de C — nodos en el heap, encadenados mediante un campo, liberados uno a uno — no es
una arena, y es donde se nota el modelo de recursos por punto de asignación de kenbi. Cada nodo
procede de un único `malloc`, así que kenbi veía un recurso donde el programa tiene una cadena de
objetos: una liberación durante un recorrido se leía como la liberación de «el» recurso, y el
paso siguiente como un uso tras liberar.

Dos declaraciones hacen comprobable la cadena, y ninguna se toma por confianza:

```c
/* @mem t::n { free: free, owner: cur, link: next } */   /* per resource… */
// @list Cluster { link: next }                           /* …or per record TYPE */

/* @drains(head) */
for (cur = head; cur != NULL; cur = nxt) { nxt = cur->next; free(cur); }
```

`link:` dice que el recurso es un NODO de una colección encadenada mediante ese campo, de modo que
un recorrido es otro elemento y no un puntero que kenbi no puede situar, y una liberación durante
el recorrido elimina un ELEMENTO. `@drains(head)` dice que un bucle libera todos los elementos — y
kenbi lo comprueba: un bucle que no libera nada es `CONTRACT_NOT_HONORED`, una colección que nada
vacía es un `LEAK`, `free(cur); cur = cur->next;` es un `USE_AFTER_FREE`, liberar un cursor dos
veces antes de que avance es un `DOUBLE_FREE`, y todo cursor queda colgante una vez vaciada la
colección.

[`demo/list.c`](demo/list.c) es todo esto en 30 líneas — construir, recorrer, vaciar — y se
verifica limpio:

```
$ kenbi demo/list.c
demo/list.c: ok — no findings from the checks that ran
  checked: ownership; not checked: bounds, locks, initialisation, tagged unions
```

La forma por TIPO alcanza código que kenbi no puede editar. La lista de clusters de ImageMagick se
recorre en nueve funciones de `MagickCore/segment.c`; una sola línea de comentario en un overlay
incluido a la fuerza
([`demo/imagemagick/kenbi_magick_lists.h`](demo/imagemagick/kenbi_magick_lists.h)) lleva ese
archivo de 83 hallazgos a 14, con la desaparición de los 54 `USE_AFTER_FREE` y los 4
`DOUBLE_FREE`. Lo que una cabecera no puede decir es qué bucle vacía la lista — eso es un hecho
sobre una sentencia — así que esas colecciones siguen en RED hasta que el vaciado se declara en el
bucle. Esa es la pregunta que kenbi debe plantear, no una que pueda responder desde fuera del
archivo.

*Medido en septiembre de 2026 sobre ImageMagick 7.1.2-27 con kenbi tal como era entonces; las versiones posteriores de kenbi dan totales distintos.*

## Verificación configurada de bajo nivel (`--safety`)

Algunas propiedades del código de bajo nivel no están en absoluto en el código fuente: qué
funciones se ejecutan en una interrupción, qué puede hacer la API de un dispositivo, cuánta pila
usa una build, a qué memoria puede acceder un motor DMA. `--safety=project.json` las toma de un
archivo de proyecto y de archivos de contratos, y comprueba el código fuente frente a ellas:

```sh
kenbi --format=json --safety=demo/safety/project.json
```

| propiedad | documento |
|---|---|
| efectos prohibidos en un cierre de llamadas (asignación, bloqueo, espera, recursión), por bloque o función | [efectos](docs/configured_effects.md), [recursión](docs/configured_recursion.md), [efectos por estado](docs/configured_state_effects.md) |
| máquinas de estados de recursos (orden de operaciones, estados finales, resultados según el valor de retorno) | [protocolos](docs/configured_protocols.md), [resultados](docs/configured_protocol_results.md), [bloques](docs/configured_protocol_blocks.md), [fronteras de función](docs/configured_function_boundaries.md) |
| búferes prestados a operaciones asíncronas (sin modificación, liberación ni reutilización antes de completarse) | [préstamos asíncronos](docs/configured_async_borrows.md), [capacidad](docs/configured_borrow_capacity.md), [alineación](docs/configured_borrow_alignment.md), [marcas de búfer](docs/configured_buffer_marks.md), [almacenamiento de solo lectura](docs/configured_storage_permissions.md) |
| contextos de ejecución (interrupción, hilo) y las API que permite cada uno | [contextos](docs/configured_contexts.md) |
| rango y alineación de lecturas, escrituras y accesos a API | [acceso en el código fuente](docs/configured_source_access.md), [capacidad de API](docs/configured_access_capacity.md), [alineación de API](docs/configured_access_alignment.md), [punteros devueltos](docs/configured_return_pointer.md), [reasignación de punteros](docs/configured_pointer_bindings.md) |
| bucles y contadores en comprobaciones ordenadas | [for](docs/configured_for_loops.md), [do-while](docs/configured_do_while.md), [actualizaciones sin signo](docs/configured_unsigned_updates.md), [parámetros enteros](docs/configured_integer_parameters.md) |
| contratos de asignación, límites de pool y heap, regiones de memoria | [asignación](docs/configured_allocation.md), [regiones de memoria](docs/configured_memory_regions.md) |
| profundidad de llamadas y uso de pila (a partir de la salida `-fstack-usage` del compilador) | [profundidad de llamadas](docs/configured_call_depth.md), [uso de pila](docs/configured_stack_usage.md) |
| mapas de registros MMIO (solo lectura / solo escritura, write-1-to-clear, read-to-clear, bits reservados, ancho de acceso, barreras requeridas) | [MMIO](docs/configured_mmio.md) |
| cotas de tiempo de ejecución suministradas por una herramienta WCET externa, ligadas a la build | [tiempo de ejecución](docs/configured_execution_time.md) |
| vinculación de los archivos de contratos con las fuentes, opciones de compilación y destino para los que se escribieron | [artefactos](docs/configured_contract_artifacts.md), [compilación](docs/configured_contract_compilation.md), [destino](docs/configured_contract_target.md) |

Cada obligación se reporta como `verified`, `conditional` (se cumple bajo contratos externos, que
el resultado enumera como supuestos), `unverified` o `violation`. Todo lo que kenbi no puede
resolver es `unverified`, y la ejecución solo pasa cuando cada obligación es `verified`, o
`conditional` sobre supuestos que el archivo de proyecto acepta explícitamente. Los documentos
anteriores están en japonés, y cada uno indica lo que no cubre.
[`demo/safety/`](demo/safety/) y [`demo/dma/`](demo/dma/) son ejemplos prácticos sobre
dispositivos ficticios.

## Qué promete y qué no promete un GREEN

Un GREEN significa: dentro de las comprobaciones que se ejecutaron, sobre el código que kenbi
analizó, cada vía se ajusta a los contratos declarados. No significa:

- **Seguro más allá de los ejes activados.** En un archivo sin `@spatial` no se ha comprobado
  ningún límite; donde `@kenbi` marca parte de un archivo, en el resto no se ha comprobado nada.
- **Seguro más allá de los contratos.** Un contrato sobre código que kenbi no vio se toma por
  confianza, y se enumera como frontera de confianza; `@unsafe` es la palabra del autor, y también
  se enumera. `verified` es la respuesta en la que nada se toma por confianza.
- **Seguro más allá de lo que define la build.** El código excluido por el preprocesador, un
  `compile_commands.json` distinto o un destino distinto no se analizaron.

Lo que kenbi no puede modelar lo rechaza en lugar de omitirlo: `UNSTRUCTURED_GOTO` (gotos hacia
atrás, saltos a etiquetas anidadas, gotos computados), `LOOP_FIXPOINT_LIMIT`,
`UNSUPPORTED_CONSTRUCT` y `unverified` bajo `--safety`. En código real de gran tamaño estos
rechazos forman parte del resultado — una función que contiene uno sigue en RED hasta que se
reestructura o se declara.

Si encuentras un GREEN que no debería serlo, repórtalo con una reproducción mínima: es el tipo de
fallo más grave que puede tener kenbi.

## Arquitectura

El motor de análisis está desacoplado del front-end: trabaja sobre una IR independiente del
front-end, de modo que analizar C/C++ es una pieza reemplazable.

```
*.c / *.cpp  ──▶ libclang front-end  ┐
                 (src/frontend_c.nim) ├─▶ Program IR ─▶ typestate engine ─▶ diagnostics
*.mc         ──▶ mini-format parser  ┘   (src/ir.nim)   (src/analyze.nim)
                 (src/parse.nim)
```

| archivo | función |
|---|---|
| `src/ir.nim` | IR independiente del front-end (`Program`: recursos + árbol de sentencias) |
| `src/analyze.nim` | motor de typestate (orígenes, fusión may-set, punto fijo de bucles, detección de fugas, cobertura) |
| `src/clang.nim` | FFI mínimo de libclang (estructuras por valor conformes al ABI de C) |
| `src/frontend_c.nim`, `src/cfront_*.nim` | bajan C/C++ real y los comentarios de anotación a `Program` |
| `src/annotations/` | registro del vocabulario de anotaciones |
| `src/compile_db.nim` | extrae los flags de análisis de `compile_commands.json` |
| `src/safety_config.nim`, `src/safety_check.nim` | `--safety`: archivos de proyecto y de contratos, comprobaciones configuradas |
| `src/effect_facts.nim`, `src/protocol_*.nim` | `--safety`: efectos del cierre de llamadas, máquinas de estados y préstamos |
| `src/parse.nim` | parser de mini-formato (fixtures del motor) |
| `src/kenbi.nim` | CLI: reparte por extensión, imprime los diagnósticos |

## Pruebas

`tests/*.mc` accionan el motor directamente (17 casos). `tests/c/*.c` y `tests/cpp/*.cpp` llevan
esos escenarios más las comprobaciones específicas de anotaciones en C y C++ reales (349 casos); el
runner baja cada uno vía libclang y verifica los diagnósticos producidos — **incluida su línea de
origen** — frente a los marcadores `//EXPECT CODE` de cada archivo (en la propia línea, o
`//EXPECT CODE@LINE`). Una línea incorrecta o un diagnóstico faltante / sobrante hace fallar la
suite. `tests/run_tests_project.nim` comprueba el resultado de cobertura a nivel de proyecto, las
suites `tests/run_tests_*.py` comprueban `--safety` de extremo a extremo, y
`demo/verify_three_state.py` comprueba el [corpus de tres estados](demo/README_three_state.md) y el
material del servidor MCP generado a partir de él.

## Licencia

kenbi se distribuye bajo la licencia Apache 2.0 ([LICENSE.md](LICENSE.md)). El material procedente de
otros proyectos y sus licencias se registran en [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
