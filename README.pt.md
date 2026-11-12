# kenbi

[English](README.md) · [简体中文](README.zh.md) · [日本語](README.ja.md) · [Español](README.es.md) · **Português** · [Français](README.fr.md) · [Deutsch](README.de.md)

**O kenbi verifica o código C e C++ em relação às regras de segurança de memória que ele declara.** Você escreve como comentários, ao lado do código, quem é dono de um buffer, quem o libera e quanto tempo dura um empréstimo; o kenbi verifica, estaticamente e em todo caminho, que o código faz o que esses comentários dizem. Não é um compilador e não altera o seu build.

**Feito para escrever C/C++ com agentes de IA.** Por meio do seu [servidor MCP](#com-agentes-de-programação-com-ia-mcp), um agente verifica o C/C++ que acabou de escrever, pergunta por que um achado aparece e como é a correção, e repete até que as verificações não relatem nada. A segurança de memória passa a fazer parte do ciclo de escrita do agente em vez de uma revisão posterior, e as anotações que ele escreve ficam no código como regras que o kenbi continua verificando.

> Status: **v0.1.0**, desenvolvimento inicial. As interfaces, o vocabulário de anotações e a
> saída JSON ainda podem mudar.

## Um primeiro olhar

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

`@kenbi` coloca o arquivo sob a verificação de posse, e `@mem` declara um tipo de recurso e como ele é alocado e liberado. Troque o retorno antecipado por `{ free(p); return NULL; }` e o arquivo relata `ok — no findings from the checks that ran`, com código de saída 0. A linha `checked:` faz parte de todo resultado: a ausência de achados cobre apenas as verificações que ela lista.

## O que o diferencia

- **Declarado, não inferido.** O kenbi não adivinha o que o código significa. Ele verifica o código em relação ao que as anotações declaram, então um achado é um lugar onde o código se afasta de uma regra declarada, não um padrão que parece suspeito.
- **O não provado não é verde.** Onde o kenbi não consegue mostrar que todo caminho segue as regras, ele relata um achado, e o que não consegue modelar (um `goto` para trás, por exemplo) também relata em vez de pular. Um resultado sem achados é a afirmação que o kenbi sustenta.
- **Todo caminho, sem executar o código.** Sanitizers e testes veem os caminhos que executam; o kenbi segue todo caminho por laços, retornos antecipados, escadas de limpeza com `goto` e exceções de C++.
- **Determinístico, com o escopo declarado.** A mesma entrada dá a mesma saída, e cada resultado nomeia as verificações executadas, os contratos em que se apoia e cada `@unsafe` que silenciou um achado.
- **Adoção gradual.** Cada verificação é ativada separadamente, por arquivo, função ou bloco, para que o código existente não vire uma parede vermelha.

## Com agentes de programação com IA (MCP)

O [servidor MCP](mcp/README.md) dá a um agente o verificador e o material para agir a partir dele:

| | o que o agente recebe |
|---|---|
| `check_memory_safety` | os achados do kenbi, com um resumo que informa quais verificações rodaram em quais funções, para que “nenhum achado” nunca seja lido como “seguro” |
| `explain_finding` | para um código de achado ou um identificador CWE: o que o dispara, por que uma correção pela metade ainda falha, e a correção com o contrato que ela declara |
| `kenbi://annotations` | a referência de anotações |
| `kenbi://patterns` | formas seguras de C/C++ que o kenbi aceita, ao lado das formas inseguras que ele rejeita |

O ciclo é escrever → verificar → explicar → corrigir → verificar de novo, e quem decide quando termina é o kenbi, não o modelo. O servidor também orienta o agente a não repetir em comentários o que uma anotação já diz: a anotação é verificada, um comentário não.

O ciclo em [`demo/quickstart.c`](demo/quickstart.c), com as respostas reais do servidor (cada resumo é seguido do documento JSON completo do kenbi, omitido aqui):

1. O agente escreve `dup_name` e chama `check_memory_safety`:

   ```text
   kenbi: 1 error(s), 0 warning(s) across 1 file(s):
     demo/quickstart.c:8: error: leak: 'app::buf' allocated here is never freed or moved [LEAK]

   Scope — the result covers only this:
     - ownership, lifetime and null (`@kenbi`, or a file with no marker): checked in every function
     - NOT checked anywhere: bounds (`@spatial`); locks (`@threadsafe`); initialisation (`@initcheck`); tagged unions (`@typecheck`)
     - verified (nothing taken on trust): 0 of 1 adopted memory-relevant functions
     - code the preprocessor excluded under these flags was not analysed
   ```

2. Ele chama `explain_finding` com `LEAK` e recebe exemplos trabalhados; o primeiro termina com a correção:

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

3. Ele libera `p` no retorno antecipado (`if (p[0] == '\0') { free(p); return NULL; }`) e verifica de novo:

   ```text
   kenbi: no findings in 1 file(s) from the checks that ran. This is not a statement about anything outside the scope below.

   Scope — the result covers only this:
     - ownership, lifetime and null (`@kenbi`, or a file with no marker): checked in every function
     - NOT checked anywhere: bounds (`@spatial`); locks (`@threadsafe`); initialisation (`@initcheck`); tagged unions (`@typecheck`)
     - verified (nothing taken on trust): 1 of 1 adopted memory-relevant functions
     - code the preprocessor excluded under these flags was not analysed
   ```

[`integrations/agent/`](integrations/agent/) traz instruções equivalentes para Claude Code (`SKILL.md`), agentes no estilo Codex (`AGENTS.md`) e GitHub Copilot.

A configuração está em [`mcp/README.md`](mcp/README.md#configure-in-an-mcp-client).

## O que é verificado

Cada verificação é ativada separadamente:

| eixo | ativação | o que é verificado |
|---|---|---|
| propriedade / tempo de vida | `@kenbi` (ou um arquivo sem marcador) | use-after-free, double free, vazamentos em todas as saídas, use-after-move, desalocador errado, retornos pendentes (dangling), tempos de vida de empréstimos e de arenas, contratos declarados confrontados com os corpos das funções, proprietários RAII de C++, ponteiros inteligentes e caminhos de exceção |
| nulo | sempre, com `@nullable` / `@nonnull` | dereferência de um ponteiro possivelmente nulo ou sabidamente nulo, com estreitamento sensível ao fluxo |
| limites | `@spatial` | um índice ou tamanho não confiável que chega a um buffer precisa de uma verificação de limite presente, suficiente e segura contra overflow; `@counted_by` e invariantes de estruturas de dados declarados (`@invariant` / `@maintains`) |
| inicialização | `@initcheck` | um local lido antes de ser atribuído em todos os caminhos |
| uniões etiquetadas | `@typecheck` + `@variant` | um membro de união usado onde sua etiqueta (tag) não está provada |
| locks | `@threadsafe` | acesso sem guarda, locks desbalanceados, ordem de locks declarada (deadlock AB-BA) |
| propriedades de baixo nível | `--safety=project.json` | efeitos proibidos em um fecho de chamadas, máquinas de estados de recursos, profundidade de pilha e de chamadas, regiões de memória, MMIO e mais — veja [Verificação de baixo nível configurada](#verificação-de-baixo-nível-configurada---safety) |

Um front-end libclang rebaixa ("lowering") C / C++ real (lendo `compile_commands.json`) para um
motor de typestate. Os laços são analisados até um ponto fixo limitado; escadas de limpeza com
`goto` para frente, `break` / `continue` e `try` / `catch` são modelados, e tudo o que o kenbi
não consegue modelar é reportado em vez de ignorado. A saída é texto ou `--format=json`.

## Início rápido

```sh
# Debian / Ubuntu; for other systems see "Instalar a libclang por sistema operacional" below.
# Nim 2.2 or later: https://nim-lang.org/install.html
sudo apt-get install libclang1-14 libclang-common-14-dev
git clone https://github.com/puffball1567/kenbi
cd kenbi
nimble build -d:release
./kenbi demo/quickstart.c
```

## Requisitos

- **Nim** >= 2.2 ([instalação](https://nim-lang.org/install.html))
- **libclang** (a biblioteca compartilhada; os cabeçalhos `clang-c` *não* são necessários —
  apenas o `.so` / `.dylib` / `.dll` de execução, carregado dinamicamente na inicialização).
- **os cabeçalhos embutidos do clang** (`stddef.h`, `stdarg.h`, …), de que a libclang precisa para
  analisar qualquer arquivo que inclua um deles. A maioria dos pacotes clang/LLVM os traz junto com a
  biblioteca; no Debian e no Ubuntu eles são o pacote separado `libclang-common-N-dev`.

A libclang é carregada pelo seu soname em tempo de execução; a lista de busca padrão cobre
`libclang.so`, `libclang-13..18.so`, etc. Se a sua biblioteca tiver outro nome ou caminho,
substitua-o em tempo de compilação:

```sh
nimble build -d:release -d:kenbiLibclang=/full/path/to/libclang.so
```

## Compilação e testes

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

### Instalar a libclang por sistema operacional

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

**macOS** (LLVM do Homebrew, ou as Xcode Command Line Tools)
```sh
brew install llvm
nimble build -d:release -d:kenbiLibclang="$(brew --prefix llvm)/lib/libclang.dylib"
# Apple's Command Line Tools also ship a libclang at
#   /Library/Developer/CommandLineTools/usr/lib/libclang.dylib
```

**Windows** (MSVC + release do LLVM)
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

- `kenbi --version` mostra a versão do kenbi e a libclang que ele carregou.
- `*.c *.cc *.cpp *.cxx` → front-end libclang (C ou C++ conforme a extensão).
- `*.mc` → mini-formato.
- Para C/C++, as flags de análise vêm de `compile_commands.json`: passe-o com
  `--compile-commands=PATH`, ou ele é descoberto automaticamente subindo a partir do
  arquivo-fonte. Tudo após `--` é anexado à linha de comando do clang.
- `--project[=compile_commands.json]` analisa todas as unidades de tradução que o banco de
  dados lista. Os achados de cada arquivo continuam sendo apenas dele (as anotações têm escopo de
  arquivo, e a análise também) — o que isto acrescenta é o **fecho**: uma chamada com contrato a
  uma função definida em outra unidade analisada resolve-se no veredito dessa unidade, de modo
  que um GREEN cujo fecho de dependências inteiro foi analisado e é GREEN conta como *verified*,
  e a fronteira de confiança se estreita ao que nada no projeto define (uma biblioteca
  distribuída como binário, o SO, uma borda de FFI). Sem caminho, o banco de dados é encontrado
  subindo a partir do primeiro arquivo informado.
- `--format=json` emite achados legíveis por máquina com códigos estáveis (para CI, editores e
  agentes); `--format=text` (padrão) é legível por humanos.
- `--safety=project.json` executa as verificações de baixo nível configuradas descritas em
  [Verificação de baixo nível configurada](#verificação-de-baixo-nível-configurada---safety).
- Código de saída: `0` limpo · `1` problemas encontrados · `2` erro de uso / análise.


## Ativação: arquivo, função ou bloco

`@kenbi` marca o que está sob disciplina — achados fora dela são descartados, de modo que a
adoção é gradual e nunca uma parede de vermelho. O marcador se vincula ao que estiver logo abaixo
dele:

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

Um bloco sob disciplina **não** coloca sua função sob ela: tais blocos são contados e reportados
em uma linha própria (`blocks adopted`), nunca somados à contagem de funções adotadas.

## Distribuindo contratos para uma biblioteca

Uma sobreposição (overlay) de contratos é um arquivo de comentários — pode ser publicada ao lado
de uma biblioteca, ou escrita por um consumidor para uma biblioteca que nunca ouviu falar do
kenbi. Em ambos os casos, quem a recebe precisa saber o que ela descreve, então a overlay o
declara e o kenbi verifica o que puder:

```c
// @contracts_for ImageMagick { version: 7.1.2-27, requires: MAGICKCORE_QUANTUM_DEPTH=16 }
// @allocator magick::mem { alloc: AcquireQuantumMemory, free_returns_null: RelinquishMagickMemory }
// @contract qsort { borrows: $1 }
```

- `requires:` é **verificado** contra a linha de compilação. Um build que contradiz uma condição
  é um erro (`CONTRACT_PACKAGE_MISMATCH`) — esses contratos foram escritos para um build
  diferente, então o que prometem pode não valer. Uma condição que a linha de compilação não
  decide é reportada como *unverified*, nunca como satisfeita.
- `version:` é mantido como **declarado**. O kenbi não consegue ler a versão de uma biblioteca a
  partir do código-fonte e não finge conseguir; o relatório diz "version declared, not verified".

`--format=json` carrega tudo isso (`contractPackages` com `versionDeclared`, `requires`,
`mismatched`, `unverified`, `appliesToThisBuild`), de modo que um consumidor pode decidir se
confia em um conjunto de contratos antes de depender dele.

### Publicando um conjunto de contratos

`--emit-contracts` imprime a *superfície* de contratos do que foi analisado, em vez de
verificá-lo — a forma que uma biblioteca distribui para que outra ferramenta (um verificador
diferente, um gerador de bindings, o front-end de outra linguagem) possa cobrar dos chamadores
os contratos da biblioteca sem reler seus comentários:

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

`resources` é o vocabulário alloc → free: um consumidor a quem só se informam os desalocadores
não consegue saber qual chamada lhe entregou a obrigação em primeiro lugar. E todo contrato
carrega o `status` que esta execução estabeleceu para a implementação por trás dele, porque "um
contrato está declarado" não pode ser lido como "a implementação foi verificada":

| `status` | o que a execução estabeleceu |
|---|---|
| `declared` | nenhuma implementação aqui (um protótipo, ou um contrato escrito de fora) — **nada foi verificado** |
| `unchecked` | o corpo está presente mas não está sob `@kenbi`: o kenbi não o verificou |
| `red` | o corpo está sob `@kenbi` e contradiz seus contratos — não dependa dele |
| `green` | verificado e limpo, apoiado em confiança (um chamado com contrato não coberto, ou um `@unsafe`) |
| `verified` | verificado e limpo, assim como todo o seu fecho com contratos: nenhum resíduo |

Publicar não é verificar: o documento é impresso e o código de saída é 0 mesmo quando o código
tem achados. Peça-os com uma execução comum do `kenbi`.

## "GREEN" e "verified" são respostas diferentes

Uma anotação não é uma prova, e o resultado de cobertura diz isso:

| | o que significa |
|---|---|
| `GREEN (contracted)` | as fronteiras estão declaradas — seguro *dados* os contratos em que se apoia |
| `verified` | todo o seu fecho de dependências com contrato também está coberto: nada aceito por confiança |
| `trusted frontier` | os chamados não cobertos em que um GREEN se apoia atualmente — cubra-os para fechá-lo |
| `@unsafe vouches` | os locais onde o autor afirmou o que o kenbi não pôde verificar |

`verified` é um subconjunto estrito de `GREEN`. Declarar um contrato em um chamado não coberto
move uma função de RED para GREEN e coloca esse chamado na fronteira de confiança; um `@unsafe`
que de fato suprime um achado mantém a função GREEN e fora de `verified` definitivamente, com o
local nomeado. Assim, uma operação que o kenbi não consegue verificar nunca pode aparecer como
verificada só porque alguém a anotou. Tudo isso está em `--format=json` (`green`, `verified`,
`trustedFrontier`, `unsafeVouches`, e `flows` por ponto de entrada com seus `blockers`).

```sh
kenbi --compile-commands=build/compile_commands.json src/img.c
kenbi --project=build/compile_commands.json          # the whole project, one closure
kenbi --emit-contracts src/*.c                       # publish the contract set instead
kenbi --format=json src/*.c
kenbi foo.cpp -- -Iinclude -DDEBUG
```

O documento JSON é `{ "version", "tool", "findings": [ { "file", "line",
"code", "severity", "message" } ], "coverage", "scope" }`; os códigos são estáveis e a ordem é determinística. Falhas
de leitura/análise aparecem como achados `PARSE_ERROR`.
`scope` lista, para cada arquivo analisado, quais verificações rodaram em quais funções: para cada uma de
`ownership`, `bounds`, `locks`, `initialisation` e `taggedUnions`, um `mode` que é `file` (todas as funções),
`functions` (algumas, com as demais nomeadas em `unchecked`) ou `off`, além dos blocos adotados com `@kenbi`
dentro de funções que de resto não são verificadas. Um arquivo sem achados está limpo apenas dentro desse
escopo; a saída de texto o mostra abaixo de cada arquivo.

## Anotações

Os recursos são declarados em comentários e referenciados por um nome com escopo, único no
projeto. A obrigação recai sobre a *alocação* (sua "origem"), não sobre a variável: as cópias a
aliasam, os ponteiros interiores derivam dela, e um `free` / move a quita. Os ramos se fundem de
forma sólida (um estado é possível após uma junção se for possível em *qualquer um* dos caminhos
— liberar em apenas um caminho deixa, portanto, um vazamento no outro).

```c
/* @mem demo::buf { size: n, free: free, owner: p } */
char *p = malloc(n);     // alloc of demo::buf (p is the owner)
char *r = p + 16;        // interior pointer — inferred, must not be freed
consume(p);              // use
sink(p);  // @move demo::buf   — obligation transferred out; p is now moved-from
```

- **alocação**: uma inicialização / atribuição cujo lado direito é da família `malloc` ou um
  `new` de C++ vincula a obrigação à variável de destino.
- **liberação**: `free(p)` ou `delete`/`delete[] p` em C++.
- **interior**: `p + off` deriva um ponteiro interior na mesma origem.
- **alias**: `q = p` faz de `q` um alias da origem de `p`.
- **copy**: `// @copy <resource>` em uma atribuição marca uma cópia *profunda* — um novo objeto
  possuído independente, com sua própria obrigação, e não um mero alias.
- **move**: uma chamada em uma linha com `// @move` transfere a obrigação para fora.
- **unsafe**: `// @unsafe` em uma linha a coloca em quarentena — os achados ali são suprimidos
  (você assume a responsabilidade). Um `@unsafe` que não cobre nada é reportado como
  `STALE_UNSAFE`, como um lint-disable não utilizado.
- **segurança de nulo**: `// @nullable` (ou `@nonnull`) em uma declaração marca se um ponteiro
  pode ser nulo; dereferenciar um ponteiro nullable sem uma verificação de nulo (`if (p)`,
  `if (p != NULL)`, `return` antecipado) é `NULL_DEREF` — a disciplina `Option<T>`, sensível ao
  fluxo com estreitamento por ramo.
- **contrato frees**: `// @frees(param)` acima de uma função declara que ela libera aquele
  argumento. Os pontos de chamada então tratam a chamada como liberando-o (compondo com
  double-free / vazamento), e o próprio corpo da função é verificado — se ela de fato não liberar
  o parâmetro, isso é `CONTRACT_NOT_HONORED` (intenção declarada vs. implementação, que uma
  ferramenta sem anotações não consegue verificar).
- **retorno must-use**: `// @must_use` acima de uma função declara que seu resultado deve ser
  consumido; uma chamada cujo valor é descartado (uma instrução isolada, não atribuída /
  retornada / passada / testada) é `UNUSED_MUST_USE` — a disciplina `#[must_use]` para códigos
  de erro ignorados e alocações vazadas.

### Vocabulário de goto (opcional — declare a intenção estruturada de um goto)

Gotos comuns para frente são modelados automaticamente (sem anotação): uma escada de limpeza para
frente (`if(!p) goto fail; … fail: free()`) é analisada via join-merge, e um goto para frente
saindo de um laço/switch para um rótulo de limpeza é admitido. Um goto-laço *para trás*, um salto
para um rótulo aninhado, ou um goto computado permanece recusado (`UNSTRUCTURED_GOTO`) — sólido
por recusa. O vocabulário opcional permite declarar o significado estruturado de um goto, de modo
que o kenbi o modele e verifique cruzadamente a forma:

- `// @goto_noreturn` em um rótulo marca um término que não retorna (abort / exit / longjmp): um
  caminho que o alcança termina, então suas obrigações ainda possuídas são quitadas — um caminho
  de abort não é um vazamento (suprime falsos vazamentos em caminhos de error-abort).
- `// @goto_finally` em um rótulo marca o funil de convergência da limpeza. Disciplina opt-in de
  funil único: uma saída que ainda possui um recurso *sem* passar pelo funil é
  `FINALLY_BYPASSED` (`goto <funnel>` para que a liberação aconteça ali). A completude da fusão
  na convergência é a análise inferida usual.
- `// @goto_backward` em um goto o declara como uma back-edge de laço: um goto-laço simples é
  reestruturado em um do-while e analisado pelo ponto fixo limitado (para que perigos entre
  iterações sejam capturados), em vez de ser recusado.

### Limites (`@spatial`)

`// @spatial` acima de uma função ou no nível do arquivo ativa o eixo de limites para esse
escopo. Um parâmetro escalar não confiável que indexa um buffer, ou dimensiona uma escrita como
`memcpy`, precisa ter uma verificação de limite presente no caminho — uma guarda `if`, uma
condição de laço, `% n`, um clamp ou uma máscara — caso contrário é `UNVALIDATED_INDEX` /
`UNVALIDATED_SIZE`. A verificação precisa cobrir o buffer (`INAPPROPRIATE_BOUND` se estiver
presente mas for frouxa demais), um índice com sinal também precisa de `i >= 0`
(`INDEX_MAYBE_NEGATIVE`), e a aritmética da guarda não pode dar a volta (wrap): `i + 4 <= n` com
um `i` sem sinal não é aceito; `n >= 4 && i <= n - 4` é. O kenbi procura a verificação no
caminho; ele nunca remove uma.

- `// @counted_by(<buf>: <len>)` acima de uma função dá a um parâmetro ponteiro o seu tamanho,
  também como campo (`b->buf: b->cap`) ou como máscara de buffer circular (`b->mask + 1`).
- `// @invariant(<field> <rel> <size>)` declara um invariante de estrutura de dados (por exemplo
  `parser->toknext <= num_tokens`). O campo passa então a ser protegido: toda escrita nele precisa
  de `// @maintains(...)`, que o kenbi verifica (`UNGUARDED_INVARIANT_WRITE`,
  `INVARIANT_NOT_MAINTAINED`), e um índice limitado pelo campo é coberto por meio da relação.

### Inicialização (`@initcheck`) e uniões etiquetadas (`@typecheck`)

- `// @initcheck` acima de uma função ou no nível do arquivo: um local escalar ou ponteiro
  declarado sem inicializador precisa ser atribuído em todos os caminhos antes de ser lido, caso
  contrário `USE_OF_UNINITIALIZED`.
- `// @typecheck` mais `// @variant(<member>: <tag> == <value>)` por membro da união: usar um
  membro em um caminho onde sua etiqueta não está provada (`if (n->tag == 1)`, ou `case 1:` sobre
  a etiqueta) é `TYPE_CONFUSION`.

### C++

`// @raii` (ou `// @raii(Name)`) marca uma classe cujo destrutor libera o que ela possui, e o
kenbi verifica que o destrutor o faz. Copiar tal classe sem operações de cópia próprias é
`MISSING_COPY_CONTROL`, e um `operator=` que libera antes de ler sua origem é
`SELF_ASSIGN_UNSAFE`. Excluir um objeto derivado por meio de uma classe base sem destrutor
virtual é `DELETE_NONVIRTUAL_BASE`. `std::unique_ptr` / `std::shared_ptr`, `std::move`, `.get()` /
`.release()` / `.reset()`, lambdas e caminhos de exceção (`LEAK_ON_THROW`, `try` / `catch`,
`noexcept` / `// @nothrow`) são modelados. A referência completa é servida pelo servidor MCP como
`kenbi://annotations` ([fonte](mcp/src/annotations.ts)).

### Saltos não locais (`setjmp` / `longjmp`)

`longjmp` sai de uma função sem executar nada do que vem depois: nenhum código de limpeza e, em
C++, nenhum destrutor. O kenbi trata uma chamada a `longjmp` / `siglongjmp` como uma saída assim, e
uma chamada a uma função declarada `// @longjmps` como uma saída possível:

- um proprietário bruto ainda mantido ali é `LEAK_ON_LONGJMP`;
- em C++, um objeto em escopo com destrutor não trivial é `LONGJMP_SKIPS_DESTRUCTOR` (o C++ torna
  esse salto comportamento indefinido). Se um destrutor é trivial é perguntado ao clang:
  `std::string` é reportado e `std::array<int, 3>` não;
- uma função que pode chegar a um longjmp, diretamente ou por um chamado `@longjmps`, sem declarar
  ela mesma `@longjmps` é `UNDECLARED_LONGJMP`, de modo que a declaração sobe até cada chamador.

Uma função de biblioteca que você não pode editar é declarada pelo nome em um cabeçalho overlay:
`// @longjmps(png_error)` ou `// @contract png_error { longjmps }`. Uma função que chama `setjmp` é
onde o salto aterrissa; essa reentrada ainda não é modelada, então é reportada como
`UNSUPPORTED_SETJMP`.

### Anotações de concorrência (verificadas sob `@threadsafe`, consultivas fora dele)

Em um escopo `@threadsafe` (função ou arquivo) elas são **verificadas**, default-red, pela
passagem de typestate de lock mantido:

- `// @guarded_by(<field>: <lock>)` (em uma função) ou `// @guarded_by(<lock>)` (em um membro de
  struct): um acesso sem o lock comprovadamente mantido é `UNGUARDED_ACCESS`; tomar o endereço do
  campo guardado é `GUARDED_ESCAPE`.
- balanço de locks: `LOCK_LEAKED` / `DOUBLE_LOCK` / `UNLOCK_WITHOUT_LOCK`.
- `// @acquires(<lock>)` / `// @releases(<lock>)`: verificados no corpo (`LOCK_NOT_ACQUIRED`) e
  consumidos nos pontos de chamada; `// @requires_lock(<lock>)` em um chamado:
  `REQUIRED_LOCK_NOT_HELD`.
- `// @lock_order(<a> < <b>)`: `LOCK_ORDER_VIOLATION` (deadlock AB-BA — uma garantia que o Rust
  não oferece); declarações conflitantes são `LOCK_ORDER_CONFLICT`. `// @lock_class(<X>)` nomeia
  a identidade de um lock para que ordens e contratos coincidam entre funções e arquivos; duas
  instâncias de uma mesma classe precisam de uma ordem canônica (`SAME_CLASS_NO_ORDER`).
- `// @calls(<fn>, ...)` em um ponteiro de função: seus alvos declarados; uma chamada indireta
  não declarada sob um lock é `UNDECLARED_INDIRECT_CALL`, uma atribuição fora do conjunto
  `UNDECLARED_FN_TARGET`.

Fora de um escopo `@threadsafe`, o kenbi as analisa e as emite com `severity: "advisory"`
(`GUARDED_BY`, `REQUIRES_LOCK`, `ACQUIRES`, `RELEASES`, `LOCK_ORDER`); **achados consultivos
nunca bloqueiam o build** — são diretivas para um revisor IA/humano. `// @llm <freeform>`
→ `LLM_REVIEW` é uma instrução em texto livre dizendo ao revisor o que verificar.

### Mini-formato (fixtures do motor)

```
@mem <scoped::name> { size: <id>, free: <id>, owner: <id> }
alloc <var> <resource> | copy <dst> <src> | interior <dst> <src> <off>
use <var> | free <var> | move <var> | if / else / endif
```

## Detectado hoje

Determinístico (`error` / `warning`): `DOUBLE_FREE`, `USE_AFTER_FREE`,
`USE_AFTER_MOVE`, `LEAK`, `FREE_INTERIOR`, `MOVE_INTERIOR`, `FREE_AFTER_MOVE`,
`MOVE_AFTER_FREE`, `DOUBLE_MOVE`, `WRONG_DEALLOCATOR`, `NULL_DEREF` (de um ponteiro possivelmente
nulo e — dito separadamente — de um que o kenbi sabe que É nulo: `free(p); p = NULL; *p`, ou uma
leitura após uma liberação declarada como retornando NULL), `CONTRACT_NOT_HONORED`,
`UNUSED_MUST_USE`, `DANGLING_RETURN` (retorno de um ponteiro para um local / de um ponteiro
liberado), `BORROW_FREED` (um objeto `@borrows` / de arena liberado individualmente),
`BORROW_OUTLIVES_OWNER` (uso após o proprietário / a arena deixar de existir),
`UNCONTRACTED_ESCAPE` / `UNCONTRACTED_RELEASE` (um ponteiro possuído cruza uma fronteira de
chamado / liberação que não declara contrato de propriedade — a disciplina default-red),
`UNSTRUCTURED_GOTO` (um goto para trás / aninhado / computado que o kenbi se recusa a modelar),
`LOOP_FIXPOINT_LIMIT` (um laço cuja análise não converge dentro do limite de iterações, recusado
em vez de julgado com uma visão incompleta),
`LEAK_ON_THROW` (C++: um proprietário bruto ainda mantido onde um chamado sem garantia de
nothrow — ou um `new` simples — pode desempilhar; proprietários RAII estão isentos, `noexcept` /
`@nothrow` / `-fno-exceptions` são as provas; dentro de um `try`, as saídas por desempilhamento
chegam aos handlers, que são verificados a partir de sua junção),
`LEAK_ON_LONGJMP` / `LONGJMP_SKIPS_DESTRUCTOR` / `UNDECLARED_LONGJMP` (um proprietário bruto, ou em
C++ um objeto com destrutor não trivial, ainda em escopo onde uma chamada pode fazer `longjmp`; uma
função que pode chegar a um longjmp sem declarar `@longjmps`), `UNSUPPORTED_SETJMP` (um ponto de
aterrissagem de `setjmp`, ainda não modelado),
`FINALLY_BYPASSED` (uma saída possuidora contorna um funil `@goto_finally` declarado),
`FREE_NONHEAP` (um `free` de um ponteiro para a pilha ou outro armazenamento fora do heap),
`BORROW_MOVED` / `UNCONTRACTED_MOVE` (um move a partir de um empréstimo, ou para um chamado que
não declara recebimento), `REALLOC_UNVERIFIED` / `REALLOC_SELF_REASSIGN` (um `realloc` cujo
resultado não é resolvido antes do uso, ou cujo único handle é sobrescrito),
`MISSING_COPY_CONTROL` / `SELF_ASSIGN_UNSAFE` / `DELETE_NONVIRTUAL_BASE` (C++), `UNSUPPORTED_CONSTRUCT` (uma alocação ou
liberação em uma construção que o kenbi não modela, recusada em vez de descartada), mais as
verificações de higiene `UNKNOWN_RESOURCE` / `STALE_UNSAFE`. Sob os eixos opt-in:
`UNVALIDATED_INDEX`, `UNVALIDATED_SIZE`, `INAPPROPRIATE_BOUND`, `INDEX_MAYBE_NEGATIVE`,
`UNGUARDED_INVARIANT_WRITE`, `INVARIANT_NOT_MAINTAINED` (`@spatial`), `USE_OF_UNINITIALIZED`
(`@initcheck`), `TYPE_CONFUSION` (`@typecheck`), e `UNGUARDED_ACCESS`, `GUARDED_ESCAPE`,
`LOCK_LEAKED`, `DOUBLE_LOCK`, `UNLOCK_WITHOUT_LOCK`, `LOCK_NOT_ACQUIRED`,
`REQUIRED_LOCK_NOT_HELD`, `LOCK_ORDER_VIOLATION`, `SAME_CLASS_NO_ORDER`,
`UNDECLARED_INDIRECT_CALL`, `UNDECLARED_FN_TARGET` (`@threadsafe`). Os laços
(`for`/`while`/`do` e goto-laços declarados) são analisados por um **ponto fixo limitado** até a
convergência, de modo que perigos entre iterações são capturados; `break`/`continue` e escadas de
limpeza com goto para frente são modelados; os vazamentos são verificados em cada saída de
função.

Consultivo (severidade `advisory`, nunca bloqueia — para a camada de revisão): `GUARDED_BY`,
`REQUIRES_LOCK`, `ACQUIRES`, `RELEASES`, `LOCK_ORDER`, `LOCK_ORDER_CONFLICT`,
`LLM_REVIEW`, `ESCAPE_UNCHECKED` (propriedade armazenada em um campo que o kenbi não rastreia —
a fronteira é exposta, não descartada silenciosamente), `POSSIBLE_DOUBLE_FREE` /
`POSSIBLE_USE_AFTER_FREE` (um chamado sem contrato cujo corpo visível libera o argumento — uma
pista até que `@frees` seja declarado, o que o confirma), `CONTRACT_UNBOUND` (um contrato que
nomeia um parâmetro que a assinatura não tem), e `UNKNOWN_VAR` (o kenbi não tem origem registrada
para um handle naquele ponto, então nada é verificado ali — um alarme sobre a própria
contabilidade do kenbi, nunca uma afirmação sobre o código).

## Demonstrado: `unsafe` em Rust → verificado, sem `@unsafe`, no kenbi

Uma lista duplamente encadeada com retro-referências (`prev` *e* `next`) precisa de ponteiros
brutos `unsafe` no Rust seguro (ou `Rc<RefCell<…>>`/`Weak`, que são verificados em *tempo de
execução*): o borrow checker não consegue expressar a propriedade compartilhada e cíclica dos
elos — a própria `LinkedList` da std é construída com `unsafe`.

A mesma estrutura sob a disciplina `@arena` do kenbi ([`demo/dll.c`](demo/dll.c)) verifica como
**segura em memória sem nenhum `@unsafe`**:

```
$ kenbi demo/dll.c
demo/dll.c: ok — no findings from the checks that ran
  checked: ownership; not checked: bounds, locks, initialisation, tagged unions
```

Cada nó vive na arena, os ponteiros cíclicos `prev`/`next` compartilham o tempo de vida da
arena, nenhum nó é liberado individualmente, e nada é usado após a região ser destruída — tudo
verificado estaticamente, em todos os caminhos. Onde o Rust seguro força `unsafe` para
*expressar* as referências cíclicas, o kenbi as *verifica* sob uma disciplina declarada e
verificada.

**Escopo honesto.** Isto é segurança de memória (sem use-after-free / double-free / vazamento /
use-after-region-free / liberação individual) sob a disciplina `@arena` *declarada* — **não** a
garantia completa do Rust: não impõe aliasing-XOR-mutação (`&mut`) nem ausência de data races, e
a arena troca memória (a região inteira é liberada de uma vez) pela simplicidade. A afirmação é
estreita e real: o kenbi pode *hospedar uma disciplina* (propriedade por região) sob a qual esse
padrão é estaticamente verificável, onde uma linguagem de modelo único precisa recorrer a
`unsafe`. Compare com [`demo/vec.c`](demo/vec.c) (um equivalente a `Vec<i32>`): um `malloc`
manual armazenado em um campo de struct verifica limpo mas levanta um **consultivo**
`ESCAPE_UNCHECKED` — a propriedade do campo é honestamente sinalizada como não verificada, e não
passada silenciosamente.

## Um alocador, muitos destrutores tipados

Projetos reais alocam com um wrapper genérico e liberam por meio de destrutores tipados em torno
dele. Por isso `free:` / `free_returns_null:` aceitam vários nomes de liberação — todos eles
liberações válidas da família, com qualquer outra coisa continuando a ser `WRONG_DEALLOCATOR` — e
`frees_fields:` registra que tal destrutor também libera os campos possuídos do objeto:

```c
// @allocator magick::mem { alloc: AcquireQuantumMemory AcquireKernelInfo …,
//                          free_returns_null: RelinquishMagickMemory DestroyKernelInfo …,
//                          frees_fields: DestroyKernelInfo … }
```

Liberar um contêiner enquanto um campo ainda possui algo é um `LEAK` por padrão — correto para um
`free(s)` simples, errado para um destrutor que existe para liberar o grafo; então é a declaração
que o autoriza, e uma liberação não declarada continua RED.

Declarar os pares no ImageMagick AUMENTA a contagem (689 → 729 nos 95 arquivos), o que é o fecho
avançando para fora e não uma regressão: uma chamada `DestroyKernelInfo(kernel)` era antes uma
fronteira sem contrato — o kenbi não conseguia ver que uma liberação acontecia ali, então nada
que passasse por ela era verificado — e agora é uma liberação que ele verifica, o que por sua vez
pergunta quem possui o objeto. Isso também encontrou um vazamento real: `OrderedDitherImage`
(threshold.c) retorna em uma falha de `SetImageStorageClass` sem o `DestroyThresholdMap` que
todas as outras saídas executam.

*Medido em setembro de 2026 no ImageMagick 7.1.2-27 com o kenbi da época; versões posteriores do kenbi relatam totais diferentes.*

## Contratando código que você talvez não possa editar

Todo contrato acima precisa ficar acima de uma declaração — e um projeto de terceiros não oferece
lugar onde colocá-lo. `@contract` nomeia a função em vez disso, de modo que todo o vocabulário
funciona a partir de um cabeçalho de overlay incluído à força (force-included), feito só de
comentários:

```c
// @contract qsort            { borrows: $1 }
// @contract DestroyKernelInfo { frees: $1 }
// @contract AddValueToSplayTree { borrows: $1, moves: $2 $3 }
```

Os parâmetros são nomeados por POSIÇÃO (`$1`, a partir de 1) além de por nome, o que costuma ser
o necessário: cabeçalhos C frequentemente declaram parâmetros sem nome, e os pontos de chamada que
precisam do contrato veem apenas o protótipo.

É o mesmo contrato, resolvido pela mesma vinculação — então ele é **verificado, não aceito por
confiança**. Uma declaração `frees:` em uma função cujo corpo está na unidade de tradução é
verificada contra ele (`CONTRACT_NOT_HONORED` se não liberar); liberar um parâmetro declarado
`borrows:` é `BORROW_FREED`; e declarar um empréstimo deixa o chamador ainda devendo a
liberação, de modo que um ponteiro entregue e nunca liberado se torna um `LEAK` visível em vez de
uma fronteira indecidível. Um contrato que nomeia um parâmetro que a assinatura não tem não
vincula nada — a fronteira continua RED, a direção segura, com um consultivo `CONTRACT_UNBOUND`
dizendo por quê.

No MagickCore do ImageMagick (95 arquivos, com sua própria linha de compilação), dez declarações
`borrows` em [`demo/imagemagick/kenbi_magick_api.h`](demo/imagemagick/kenbi_magick_api.h) levam
657 achados a 626 e `UNCONTRACTED_ESCAPE` de 249 a 216 — e revelam dois novos `LEAK`s, o que é o
mecanismo funcionando: uma fronteira declarada é uma fronteira decidível. Para uma *fábrica*,
prefira `@allocator` — adicionar o nome à lista `alloc:` de uma família também nomeia o recurso e
seu desalocador, de modo que vazamentos e `WRONG_DEALLOCATOR` também são verificados (só isso
eliminou 16 das 26 liberações sem contrato de xml-tree.c).

*Medido em setembro de 2026 no ImageMagick 7.1.2-27 com o kenbi da época; versões posteriores do kenbi relatam totais diferentes.*

## Listas intrusivas: declare o elo, declare o esvaziamento

A outra lista de C — nós no heap, encadeados por um campo, liberados um de cada vez — não é uma
arena, e é onde o modelo de recursos por local de alocação do kenbi transparece. Todo nó vem de
um único `malloc`, então o kenbi via um recurso onde o programa tem uma cadeia de objetos: uma
liberação em um percurso era lida como liberação "do" recurso e o passo seguinte como um uso após
liberação.

Duas declarações tornam a cadeia verificável, e nenhuma delas é aceita por confiança:

```c
/* @mem t::n { free: free, owner: cur, link: next } */   /* per resource… */
// @list Cluster { link: next }                           /* …or per record TYPE */

/* @drains(head) */
for (cur = head; cur != NULL; cur = nxt) { nxt = cur->next; free(cur); }
```

`link:` diz que o recurso é um NÓ de uma coleção encadeada por esse campo, de modo que um
percurso é outro elemento e não um ponteiro que o kenbi não consegue situar, e uma liberação no
percurso remove um ELEMENTO. `@drains(head)` diz que um laço libera todos os elementos — e o
kenbi verifica isso: um laço que não libera nada é `CONTRACT_NOT_HONORED`, uma coleção que nada
esvazia é um `LEAK`, `free(cur); cur = cur->next;` é um `USE_AFTER_FREE`, liberar um cursor duas
vezes antes de ele avançar é um `DOUBLE_FREE`, e todo cursor fica pendente (dangling) quando a
coleção é esvaziada.

[`demo/list.c`](demo/list.c) é tudo isso em 30 linhas — construir, percorrer, esvaziar — e
verifica limpo:

```
$ kenbi demo/list.c
demo/list.c: ok — no findings from the checks that ran
  checked: ownership; not checked: bounds, locks, initialisation, tagged unions
```

A forma por TIPO alcança código que o kenbi não pode editar. A lista de clusters do ImageMagick é
percorrida em nove funções de `MagickCore/segment.c`; uma única linha só de comentário em uma
overlay incluída à força
([`demo/imagemagick/kenbi_magick_lists.h`](demo/imagemagick/kenbi_magick_lists.h)) leva esse
arquivo de 83 achados a 14, com todos os 54 `USE_AFTER_FREE` e os 4 `DOUBLE_FREE` eliminados. O
que um cabeçalho não pode dizer é qual laço esvazia a lista — isso é um fato sobre uma instrução
— então essas coleções continuam RED até que o esvaziamento seja declarado no laço. Essa é a
pergunta que o kenbi deve fazer, e não uma que ele possa responder de fora do arquivo.

*Medido em setembro de 2026 no ImageMagick 7.1.2-27 com o kenbi da época; versões posteriores do kenbi relatam totais diferentes.*

## Verificação de baixo nível configurada (`--safety`)

Algumas propriedades de código de baixo nível simplesmente não estão no código-fonte: quais
funções rodam em uma interrupção, o que uma API de dispositivo pode fazer, quanta pilha um build
usa, que memória um motor de DMA pode alcançar. `--safety=project.json` as obtém de um arquivo de
projeto e de arquivos de contrato, e verifica o código-fonte contra elas:

```sh
kenbi --format=json --safety=demo/safety/project.json
```

| propriedade | documento |
|---|---|
| efeitos proibidos em um fecho de chamadas (alocação, bloqueio, espera, recursão), por bloco ou função | [efeitos](docs/configured_effects.md), [recursão](docs/configured_recursion.md), [efeitos por estado](docs/configured_state_effects.md) |
| máquinas de estado de recursos (ordem das operações, estados finais, resultados por valor de retorno) | [protocolos](docs/configured_protocols.md), [resultados](docs/configured_protocol_results.md), [blocos](docs/configured_protocol_blocks.md), [fronteiras de função](docs/configured_function_boundaries.md) |
| buffers emprestados por operações assíncronas (sem alteração, liberação ou reutilização antes da conclusão) | [empréstimos assíncronos](docs/configured_async_borrows.md), [capacidade](docs/configured_borrow_capacity.md), [alinhamento](docs/configured_borrow_alignment.md), [marcas de buffer](docs/configured_buffer_marks.md), [armazenamento somente leitura](docs/configured_storage_permissions.md) |
| contextos de execução (interrupção, thread) e as APIs que cada um permite | [contextos](docs/configured_contexts.md) |
| intervalo e alinhamento de leituras, escritas e acessos via API | [acesso no código-fonte](docs/configured_source_access.md), [capacidade da API](docs/configured_access_capacity.md), [alinhamento da API](docs/configured_access_alignment.md), [ponteiros retornados](docs/configured_return_pointer.md), [reatribuição de ponteiros](docs/configured_pointer_bindings.md) |
| laços e contadores em verificações ordenadas | [for](docs/configured_for_loops.md), [do-while](docs/configured_do_while.md), [atualizações sem sinal](docs/configured_unsigned_updates.md), [parâmetros inteiros](docs/configured_integer_parameters.md) |
| contratos de alocação, limites de pool e de heap, regiões de memória | [alocação](docs/configured_allocation.md), [regiões de memória](docs/configured_memory_regions.md) |
| profundidade de chamadas e uso de pilha (a partir da saída `-fstack-usage` do compilador) | [profundidade de chamadas](docs/configured_call_depth.md), [uso de pilha](docs/configured_stack_usage.md) |
| mapas de registradores MMIO (somente leitura / somente escrita, write-1-to-clear, read-to-clear, bits reservados, largura de acesso, barreiras exigidas) | [MMIO](docs/configured_mmio.md) |
| limites de tempo de execução fornecidos por uma ferramenta WCET externa, vinculados ao build | [tempo de execução](docs/configured_execution_time.md) |
| vinculação dos arquivos de contrato aos fontes, opções de compilação e alvo para os quais foram escritos | [artefatos](docs/configured_contract_artifacts.md), [compilação](docs/configured_contract_compilation.md), [alvo](docs/configured_contract_target.md) |

Toda obrigação é reportada como `verified`, `conditional` (vale sob contratos externos, que o
resultado lista como premissas), `unverified` ou `violation`. Tudo o que o kenbi não consegue
resolver é `unverified`, e a execução só passa quando toda obrigação é `verified`, ou
`conditional` sob premissas que o arquivo de projeto aceita explicitamente. Os documentos acima
estão em japonês, e cada um declara o que não cobre.
[`demo/safety/`](demo/safety/) e [`demo/dma/`](demo/dma/) são exemplos completos sobre
dispositivos fictícios.

## O que um GREEN promete e o que não promete

Um GREEN significa: dentro das verificações que foram executadas, no código que o kenbi analisou,
todo caminho está em conformidade com os contratos declarados. Ele não significa:

- **Seguro além dos eixos que estavam ativos.** Um arquivo sem `@spatial` não teve nenhum limite
  verificado; onde `@kenbi` marca parte de um arquivo, o restante dele não teve nada verificado.
- **Seguro além dos contratos.** Um contrato sobre código que o kenbi não viu é aceito por
  confiança e é listado como a fronteira de confiança; `@unsafe` é a palavra do autor e também é
  listado. `verified` é a resposta sem nada aceito por confiança.
- **Seguro além do que o build define.** Código excluído pelo pré-processador, um
  `compile_commands.json` diferente ou um alvo diferente não foram analisados.

O que o kenbi não consegue modelar, ele recusa em vez de ignorar: `UNSTRUCTURED_GOTO` (gotos
para trás, saltos para rótulos aninhados, gotos computados), `LOOP_FIXPOINT_LIMIT`,
`UNSUPPORTED_CONSTRUCT`, e `unverified` sob `--safety`. Em código real grande, essas recusas
fazem parte do resultado — uma função que contém uma delas permanece RED até ser reestruturada ou
declarada.

Se você encontrar um GREEN que não deveria sê-lo, por favor reporte-o com uma reprodução mínima:
esse é o tipo mais grave de bug que o kenbi pode ter.

## Arquitetura

O motor de análise é desacoplado do front-end: ele trabalha sobre uma IR independente do
front-end, de modo que analisar C/C++ é uma peça substituível.

```
*.c / *.cpp  ──▶ libclang front-end  ┐
                 (src/frontend_c.nim) ├─▶ Program IR ─▶ typestate engine ─▶ diagnostics
*.mc         ──▶ mini-format parser  ┘   (src/ir.nim)   (src/analyze.nim)
                 (src/parse.nim)
```

| arquivo | papel |
|---|---|
| `src/ir.nim` | IR independente do front-end (`Program`: recursos + árvore de instruções) |
| `src/analyze.nim` | motor de typestate (origens, fusão may-set, ponto fixo de laços, varredura de vazamentos, cobertura) |
| `src/clang.nim` | FFI mínimo de libclang (structs por valor conformes ao ABI de C) |
| `src/frontend_c.nim`, `src/cfront_*.nim` | rebaixam C/C++ real e os comentários de anotação para `Program` |
| `src/annotations/` | registro do vocabulário de anotações |
| `src/compile_db.nim` | extrai as flags de análise de `compile_commands.json` |
| `src/safety_config.nim`, `src/safety_check.nim` | `--safety`: arquivos de projeto e de contrato, verificações configuradas |
| `src/effect_facts.nim`, `src/protocol_*.nim` | `--safety`: efeitos do fecho de chamadas, máquinas de estado e empréstimos |
| `src/parse.nim` | parser de mini-formato (fixtures do motor) |
| `src/kenbi.nim` | CLI: despacha por extensão, imprime os diagnósticos |

## Testes

`tests/*.mc` acionam o motor diretamente (17 casos). `tests/c/*.c` e `tests/cpp/*.cpp` carregam
esses cenários mais as verificações específicas de anotações em C e C++ reais (349 casos); o
runner rebaixa cada um via libclang e verifica os diagnósticos produzidos — **incluindo a sua
linha de origem** — contra os marcadores `//EXPECT CODE` em cada arquivo (na própria linha, ou
`//EXPECT CODE@LINE`). Uma linha errada ou um diagnóstico faltante / excedente faz a suíte
falhar. `tests/run_tests_project.nim` verifica o resultado de cobertura em todo o projeto, as
suítes `tests/run_tests_*.py` verificam `--safety` de ponta a ponta, e
`demo/verify_three_state.py` verifica o [corpus de três estados](demo/README_three_state.md) e o
material do servidor MCP gerado a partir dele.

## Licença

O kenbi é distribuído sob a Licença Apache 2.0 ([LICENSE.md](LICENSE.md)). O material proveniente de
outros projetos e as respectivas licenças estão registrados em [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
