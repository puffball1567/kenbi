# kenbi

**English** · [简体中文](README.zh.md) · [日本語](README.ja.md) · [Español](README.es.md) · [Português](README.pt.md) · [Français](README.fr.md) · [Deutsch](README.de.md)

**kenbi checks C and C++ code against the memory-safety rules it declares.** You write who
owns a buffer, who frees it and how long a borrow lives as comments next to the code; kenbi
checks, statically and on every path, that the code does what those comments say. It is not
a compiler and does not change your build.

**Built for writing C/C++ with AI agents.** Through its [MCP server](#with-ai-coding-agents-mcp),
an agent checks the C/C++ it has just written, asks why a finding fires and what the fix
looks like, and repeats until the checks report nothing. Memory safety becomes part of the
agent's write loop rather than a review after the fact, and the annotations it writes stay in
the code as rules kenbi keeps checking.

> Status: **v0.1.0**, early development. The interfaces, the annotation vocabulary and the
> JSON output may still change.

## A first look

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

`@kenbi` puts the file under the ownership check, and `@mem` declares a kind of resource and
how it is allocated and released. Change the early return to `{ free(p); return NULL; }` and
the file reports `ok — no findings from the checks that ran`, with exit code 0. The
`checked:` line is part of every result: no findings covers only the checks it lists.

## How it differs

- **Declared, not inferred.** kenbi does not guess what the code means. It checks the code
  against what the annotations declare, so a finding is a place where the code departs from
  a stated rule, not a pattern that looks suspicious.
- **Unproven is not green.** Where kenbi cannot show that every path keeps the rules, it
  reports a finding, and what it cannot model (a backward `goto`, say) it reports as well
  rather than skipping. A result without findings is the claim kenbi stands behind.
- **Every path, without running the code.** Sanitizers and tests see the paths that run;
  kenbi follows every path through loops, early returns, `goto` cleanup ladders and C++
  exceptions.
- **Deterministic, with its scope stated.** The same input gives the same output, and each
  result names the checks that ran, the contracts it rests on and every `@unsafe` that
  silenced a finding.
- **Adopted gradually.** Each check is opted into separately, per file, function or block,
  so existing code does not turn into a wall of red.

## With AI coding agents (MCP)

The [MCP server](mcp/README.md) gives an agent the checker and the material to act on it:

| | what the agent gets |
|---|---|
| `check_memory_safety` | kenbi's findings, with a summary that states which checks ran on which functions, so "no findings" is never read as "safe" |
| `explain_finding` | for a finding code or a CWE id: what triggers it, why a half-fix still fails, and the fix with the contract it declares |
| `kenbi://annotations` | the annotation reference |
| `kenbi://patterns` | safe C/C++ shapes kenbi accepts, next to the unsafe shapes it rejects |

The loop is write → check → explain → fix → check again, and kenbi, not the model, decides
when it is done. The server also tells the agent not to repeat in comments what an annotation
already says: the annotation is checked, a comment is not.

The loop on [`demo/quickstart.c`](demo/quickstart.c), with the server's actual replies (each
summary is followed by kenbi's full JSON document, left out here):

1. The agent writes `dup_name` and calls `check_memory_safety`:

   ```text
   kenbi: 1 error(s), 0 warning(s) across 1 file(s):
     demo/quickstart.c:8: error: leak: 'app::buf' allocated here is never freed or moved [LEAK]

   Scope — the result covers only this:
     - ownership, lifetime and null (`@kenbi`, or a file with no marker): checked in every function
     - NOT checked anywhere: bounds (`@spatial`); locks (`@threadsafe`); initialisation (`@initcheck`); tagged unions (`@typecheck`)
     - verified (nothing taken on trust): 0 of 1 adopted memory-relevant functions
     - code the preprocessor excluded under these flags was not analysed
   ```

2. It calls `explain_finding` with `LEAK` and gets worked examples; the first ends with the fix:

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

3. It frees `p` on the early return — `if (p[0] == '\0') { free(p); return NULL; }` — and
   checks again:

   ```text
   kenbi: no findings in 1 file(s) from the checks that ran. This is not a statement about anything outside the scope below.

   Scope — the result covers only this:
     - ownership, lifetime and null (`@kenbi`, or a file with no marker): checked in every function
     - NOT checked anywhere: bounds (`@spatial`); locks (`@threadsafe`); initialisation (`@initcheck`); tagged unions (`@typecheck`)
     - verified (nothing taken on trust): 1 of 1 adopted memory-relevant functions
     - code the preprocessor excluded under these flags was not analysed
   ```

[`integrations/agent/`](integrations/agent/) has matching instructions for Claude Code
(`SKILL.md`), Codex-style agents (`AGENTS.md`) and GitHub Copilot.

Setup is in [`mcp/README.md`](mcp/README.md#configure-in-an-mcp-client).

## What it checks

Each check is opted into separately:

| check | opt-in | what is checked |
|---|---|---|
| ownership / lifetime | `@kenbi` (or a file with no marker) | use-after-free, double free, leaks on every exit, use-after-move, wrong deallocator, dangling returns, borrow and arena lifetimes, declared contracts against function bodies, C++ RAII owners, smart pointers and exception paths |
| null | always, with `@nullable` / `@nonnull` | dereference of a possibly-null or known-null pointer, with flow-sensitive narrowing |
| bounds | `@spatial` | an untrusted index or size reaching a buffer needs a present, sufficient, overflow-safe bound check; `@counted_by` and declared data-structure invariants (`@invariant` / `@maintains`) |
| initialisation | `@initcheck` | a local read before it is assigned on every path |
| tagged unions | `@typecheck` + `@variant` | a union member used where its tag is not proven |
| locks | `@threadsafe` | unguarded access, unbalanced locks, declared lock order (AB-BA deadlock) |
| low-level properties | `--safety=project.json` | forbidden effects in a call closure, resource state machines, stack and call depth, memory regions, MMIO and more — see [Configured low-level verification](#configured-low-level-verification---safety) |

A libclang front-end lowers real C / C++ (reading `compile_commands.json`) into a typestate
engine. Loops are analysed to a bounded fixpoint, forward `goto` cleanup ladders,
`break` / `continue` and `try` / `catch` are modelled, and whatever kenbi cannot model is
reported rather than skipped. Output is text or `--format=json`.

## Quick start

```sh
# Debian / Ubuntu; for other systems see "Installing libclang per OS" below.
# Nim 2.2 or later: https://nim-lang.org/install.html
sudo apt-get install libclang1-14 libclang-common-14-dev
git clone https://github.com/puffball1567/kenbi
cd kenbi
nimble build -d:release
./kenbi demo/quickstart.c
```

## Requirements

- **Nim** >= 2.2 ([installation](https://nim-lang.org/install.html))
- **libclang** (shared library + the `clang-c` headers are *not* needed — only
  the runtime `.so` / `.dylib` / `.dll`, loaded dynamically at startup).
- **clang's builtin headers** (`stddef.h`, `stdarg.h`, …), which libclang needs to parse any
  file that includes one. Most clang/LLVM packages ship them with the library; on Debian and
  Ubuntu they are the separate package `libclang-common-N-dev`.

libclang is loaded by soname at runtime; the default search list covers
`libclang.so`, `libclang-13..18.so`, etc. If your library has a different name
or path, override it at compile time:

```sh
nimble build -d:release -d:kenbiLibclang=/full/path/to/libclang.so
```

## Build & test

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

### Installing libclang per OS

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

**macOS** (Homebrew LLVM, or the Xcode Command Line Tools)
```sh
brew install llvm
nimble build -d:release -d:kenbiLibclang="$(brew --prefix llvm)/lib/libclang.dylib"
# Apple's Command Line Tools also ship a libclang at
#   /Library/Developer/CommandLineTools/usr/lib/libclang.dylib
```

**Windows** (MSVC + LLVM release)
```bat
:: install LLVM from https://releases.llvm.org and ensure libclang.dll is on PATH
nimble build -d:release -d:kenbiLibclang=libclang.dll
```

## Usage

```
kenbi [--format=text|json] [--compile-commands=PATH] [--project[=PATH]] [--emit-contracts]
      <file> [more...] [-- <extra clang args>]
kenbi [--format=text|json] --safety=project.json
kenbi --version
```

- `kenbi --version` prints kenbi's version and the libclang it loaded.
- `*.c *.cc *.cpp *.cxx` → libclang front-end (C vs C++ chosen by extension).
- `*.mc` → mini-format.
- For C/C++, parse flags come from `compile_commands.json`: pass it with
  `--compile-commands=PATH`, or it is auto-discovered by walking up from the
  source file. Anything after `--` is appended to the clang command line.
- `--project[=compile_commands.json]` analyses every translation unit the database
  lists. Each file's findings are still its own (annotations are file-scoped, and so is
  the analysis) — what this adds is the **closure**: a contracted call into a function
  defined in another analysed unit resolves to that unit's verdict, so a GREEN whose whole
  dependency closure is analysed and GREEN counts as *verified*, and the trusted frontier
  narrows to what nothing in the project defines (a library shipped as a binary, the OS, an
  FFI edge). Without a path the database is found by walking up from the first file given.
- `--format=json` emits machine-readable findings with stable codes (for CI,
  editors, and agents); `--format=text` (default) is human-readable.
- `--safety=project.json` runs the configured low-level checks described in
  [Configured low-level verification](#configured-low-level-verification---safety).
- Exit code: `0` clean · `1` issues found · `2` usage / parse error.


## Opting in: file, function, or block

`@kenbi` marks what is under discipline — findings outside it are dropped, so adoption is
gradual and never a wall of red. The marker binds to whatever it sits above:

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

A block under discipline does **not** put its function under it: such blocks are counted and
reported on their own line (`blocks adopted`), never folded into the adopted function count.

## Shipping contracts for a library

A contract overlay is a file of comments — it can be published beside a library, or written by
a consumer for a library that has never heard of kenbi. Either way the receiver has to know what
it describes, so the overlay says so and kenbi checks what it can:

```c
// @contracts_for ImageMagick { version: 7.1.2-27, requires: MAGICKCORE_QUANTUM_DEPTH=16 }
// @allocator magick::mem { alloc: AcquireQuantumMemory, free_returns_null: RelinquishMagickMemory }
// @contract qsort { borrows: $1 }
```

- `requires:` is **checked** against the compile line. A build that contradicts one is an error
  (`CONTRACT_PACKAGE_MISMATCH`) — these contracts were written for a different build, so what
  they promise may not hold. A condition the compile line does not settle is reported as
  *unverified*, never as satisfied.
- `version:` is carried as **declared**. kenbi cannot read a library's version out of source and
  does not pretend to; the report says "version declared, not verified".

`--format=json` carries the whole thing (`contractPackages` with `versionDeclared`, `requires`,
`mismatched`, `unverified`, `appliesToThisBuild`), so a consumer can decide whether to trust a
set of contracts before it relies on them.

### Publishing a contract set

`--emit-contracts` prints the contract *surface* of whatever was analysed, instead of checking
it — the form a library ships so another tool (a different checker, a binding generator, another
language's front-end) can hold callers to the library's contracts without re-reading its
comments:

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

`resources` is the alloc → free vocabulary: a consumer told only the deallocators cannot tell
which call handed it the obligation in the first place. And every contract carries the `status`
this run established for the implementation behind it, because "a contract is declared" must not
be readable as "the implementation was checked":

| `status` | what the run established |
|---|---|
| `declared` | no implementation here (a prototype, or a contract written from outside) — **nothing was verified** |
| `unchecked` | the body is present but not under `@kenbi`: kenbi did not check it |
| `red` | the body is under `@kenbi` and contradicts its contracts — do not rely on it |
| `green` | checked and clean, resting on trust (an uncovered contracted callee, or an `@unsafe`) |
| `verified` | checked and clean, and so is its whole contracted closure: no residue |

Publishing is not a check: the document is printed and the exit code is 0 even when the code has
findings. Ask for those with an ordinary `kenbi` run.

## "GREEN" and "verified" are different answers

An annotation is not a proof, and the coverage result says so:

| | what it means |
|---|---|
| `GREEN (contracted)` | the boundaries are declared — safe *given* the contracts it rests on |
| `verified` | its whole contracted-dependency closure is covered too: nothing taken on trust |
| `trusted frontier` | the uncovered callees a GREEN currently rests on — cover these to close it |
| `@unsafe vouches` | the sites where the author asserted what kenbi could not check |

`verified` is a strict subset of `GREEN`. Declaring a contract on an uncovered callee moves a
function from RED to GREEN and puts that callee on the trusted frontier; an `@unsafe` that
actually suppresses a finding keeps the function GREEN and out of `verified` for good, with the
site named. So an operation kenbi cannot verify can never read as verified because someone
annotated it. All of this is in `--format=json` (`green`, `verified`, `trustedFrontier`,
`unsafeVouches`, and per-entry-point `flows` with their `blockers`).

```sh
kenbi --compile-commands=build/compile_commands.json src/img.c
kenbi --project=build/compile_commands.json          # the whole project, one closure
kenbi --emit-contracts src/*.c                       # publish the contract set instead
kenbi --format=json src/*.c
kenbi foo.cpp -- -Iinclude -DDEBUG
```

The JSON document is `{ "version", "tool", "findings": [ { "file", "line",
"code", "severity", "message" } ], "coverage", "scope" }`; codes are stable and the order is
deterministic. Read/parse failures appear as `PARSE_ERROR` findings. `scope` lists, per analysed
file, which checks ran on which functions: for each of `ownership`, `bounds`, `locks`,
`initialisation` and `taggedUnions`, a `mode` of `file` (every function), `functions` (some, with
the others named in `unchecked`) or `off`, plus the `@kenbi` blocks adopted inside otherwise
unchecked functions. A file without findings is clean within that scope only; the text output
prints it under each file.

## Annotations

Resources are declared in comments and referenced by a scoped, project-unique
name. The obligation lives on the *allocation* (its "origin"), not the variable:
copies alias it, interior pointers derive from it, and a `free` / move discharges
it. Branches merge soundly (a state is possible after a join if possible on
*either* path — so freeing on one path still leaves a leak on the other).

```c
/* @mem demo::buf { size: n, free: free, owner: p } */
char *p = malloc(n);     // alloc of demo::buf (p is the owner)
char *r = p + 16;        // interior pointer — inferred, must not be freed
consume(p);              // use
sink(p);  // @move demo::buf   — obligation transferred out; p is now moved-from
```

- **allocation**: an initializer / assignment whose RHS is `malloc` family or C++
  `new` binds the obligation to the target variable.
- **free**: `free(p)` or C++ `delete`/`delete[] p`.
- **interior**: `p + off` derives an interior pointer into the same origin.
- **alias**: `q = p` makes `q` alias `p`'s origin.
- **copy**: `// @copy <resource>` on an assignment marks a *deep* copy — a new
  independent owned object with its own obligation, not a mere alias.
- **move**: a call on a line carrying `// @move` transfers the obligation out.
- **unsafe**: `// @unsafe` on a line quarantines it — findings there are
  suppressed (you take responsibility). An `@unsafe` that covers nothing is
  reported as `STALE_UNSAFE`, like an unused lint-disable.
- **null safety**: `// @nullable` (or `@nonnull`) on a declaration marks whether
  a pointer may be null; dereferencing a nullable pointer without a null-check
  (`if (p)`, `if (p != NULL)`, early `return`) is `NULL_DEREF` — the `Option<T>`
  discipline, flow-sensitive with branch narrowing.
- **frees contract**: `// @frees(param)` above a function declares it frees that
  argument. Callsites then treat the call as freeing it (so it composes with
  double-free / leak), and the function's own body is checked — if it doesn't
  actually free the parameter that's `CONTRACT_NOT_HONORED` (declared intent vs.
  implementation, which a tool without annotations cannot check).
- **must-use return**: `// @must_use` above a function declares its result must
  be consumed; a call whose value is dropped (a bare statement, not assigned /
  returned / passed / tested) is `UNUSED_MUST_USE` — the `#[must_use]` discipline
  for ignored error codes and leaked allocations.

### Goto vocabulary (optional — declare the structured intent of a goto)

Common forward gotos are modelled automatically (no annotation): a forward cleanup
ladder (`if(!p) goto fail; … fail: free()`) is analysed via join-merge, and a forward
goto out of a loop/switch to a cleanup label is admitted. A *backward* goto-loop, a jump
to a nested label, or a computed goto stays refused (`UNSTRUCTURED_GOTO`) — sound by
refusal. The optional vocabulary lets you declare a goto's structured meaning so kenbi
models it and cross-checks the shape:

- `// @goto_noreturn` on a label marks a non-returning terminus (abort / exit / longjmp):
  a path reaching it terminates, so its still-owned obligations are discharged — an abort
  path is not a leak (suppresses false leaks on error-abort paths).
- `// @goto_finally` on a label marks the cleanup convergence funnel. Opt-in single-funnel
  discipline: an exit that still owns a resource *without* routing through the funnel is
  `FINALLY_BYPASSED` (`goto <funnel>` so the release happens there). Merge completeness at
  the convergence is the usual inferred analysis.
- `// @goto_backward` on a goto declares it a loop back-edge: a simple goto-loop is
  restructured into a do-while and analysed by the bounded fixpoint (so cross-iteration
  hazards are caught), instead of being refused.

### Bounds (`@spatial`)

`// @spatial` above a function or at file level turns on the bounds axis for that scope. An
untrusted scalar parameter that indexes a buffer, or sizes a write such as `memcpy`, must have a
bound check present on the path — an `if` guard, a loop condition, `% n`, a clamp or a mask —
else it is `UNVALIDATED_INDEX` / `UNVALIDATED_SIZE`. The check must cover the buffer
(`INAPPROPRIATE_BOUND` if it is present but too loose), a signed index also needs `i >= 0`
(`INDEX_MAYBE_NEGATIVE`), and guard arithmetic must not wrap: `i + 4 <= n` on an unsigned `i` is
not credited; `n >= 4 && i <= n - 4` is. kenbi looks for the check on the path; it never removes
one.

- `// @counted_by(<buf>: <len>)` above a function gives a pointer parameter its size, also as a
  field (`b->buf: b->cap`) or a ring-buffer mask (`b->mask + 1`).
- `// @invariant(<field> <rel> <size>)` declares a data-structure invariant (for example
  `parser->toknext <= num_tokens`). The field is then protected: every write to it needs
  `// @maintains(...)`, which kenbi verifies (`UNGUARDED_INVARIANT_WRITE`,
  `INVARIANT_NOT_MAINTAINED`), and an index bounded by the field is covered through the relation.

### Initialisation (`@initcheck`) and tagged unions (`@typecheck`)

- `// @initcheck` above a function or at file level: a scalar or pointer local declared without
  an initializer must be assigned on every path before it is read, else `USE_OF_UNINITIALIZED`.
- `// @typecheck` plus `// @variant(<member>: <tag> == <value>)` per union member: using a member
  on a path where its tag is not proven (`if (n->tag == 1)`, or `case 1:` on the tag) is
  `TYPE_CONFUSION`.

### C++

`// @raii` (or `// @raii(Name)`) marks a class whose destructor releases what it owns, and kenbi
checks the destructor does. Copying such a class without its own copy operations is
`MISSING_COPY_CONTROL`, and an `operator=` that releases before reading its source is
`SELF_ASSIGN_UNSAFE`. Deleting a derived object through a base class without a virtual
destructor is `DELETE_NONVIRTUAL_BASE`. `std::unique_ptr` / `std::shared_ptr`, `std::move`, `.get()` /
`.release()` / `.reset()`, lambdas, and exception paths (`LEAK_ON_THROW`, `try` / `catch`,
`noexcept` / `// @nothrow`) are modelled. The complete reference is served by the MCP server as
`kenbi://annotations` ([source](mcp/src/annotations.ts)).

### Non-local jumps (`setjmp` / `longjmp`)

`longjmp` leaves a function without running anything after it: no cleanup code and, in C++, no
destructors. kenbi treats a call to `longjmp` / `siglongjmp` as such an exit, and a call to a
function declared `// @longjmps` as a possible one:

- a raw owner still held there is `LEAK_ON_LONGJMP`;
- in C++, an object in scope with a non-trivial destructor is `LONGJMP_SKIPS_DESTRUCTOR` (C++
  makes the jump undefined behaviour). Whether a destructor is trivial is asked of clang, so
  `std::string` is reported and `std::array<int, 3>` is not;
- a function that can reach a longjmp, directly or through a `@longjmps` callee, without
  declaring `@longjmps` itself is `UNDECLARED_LONGJMP`, so the declaration travels up to every
  caller.

A library function you cannot edit is declared by name in an overlay header:
`// @longjmps(png_error)` or `// @contract png_error { longjmps }`. A function that calls `setjmp`
is where the jump lands; that re-entry is not modelled yet, so it is reported as
`UNSUPPORTED_SETJMP`.

### Concurrency annotations (verified under `@threadsafe`, advisory outside it)

In a `@threadsafe` scope (function or file) these are **verified**, default-red, by the
lock-held typestate pass:

- `// @guarded_by(<field>: <lock>)` (on a function) or `// @guarded_by(<lock>)` (on a struct
  member): an access without the lock provably held is `UNGUARDED_ACCESS`; taking the guarded
  field's address is `GUARDED_ESCAPE`.
- lock balance: `LOCK_LEAKED` / `DOUBLE_LOCK` / `UNLOCK_WITHOUT_LOCK`.
- `// @acquires(<lock>)` / `// @releases(<lock>)`: verified in the body (`LOCK_NOT_ACQUIRED`)
  and consumed at call sites; `// @requires_lock(<lock>)` on a callee: `REQUIRED_LOCK_NOT_HELD`.
- `// @lock_order(<a> < <b>)`: `LOCK_ORDER_VIOLATION` (AB-BA deadlock — a guarantee Rust does
  not make); conflicting declarations are `LOCK_ORDER_CONFLICT`. `// @lock_class(<X>)` names a
  lock's identity so orders and contracts match across functions and files; two instances of
  one class need a canonical order (`SAME_CLASS_NO_ORDER`).
- `// @calls(<fn>, ...)` on a function pointer: its declared targets; an undeclared indirect
  call under a lock is `UNDECLARED_INDIRECT_CALL`, an out-of-set assignment `UNDECLARED_FN_TARGET`.

Outside a `@threadsafe` scope kenbi parses them and emits them with `severity: "advisory"`
(`GUARDED_BY`, `REQUIRES_LOCK`, `ACQUIRES`, `RELEASES`, `LOCK_ORDER`); **advisory findings
never gate the build** — they are directives for an AI/human reviewer. `// @llm <freeform>`
→ `LLM_REVIEW` is a freeform instruction telling the reviewer what to check.

### Mini-format (engine fixtures)

```
@mem <scoped::name> { size: <id>, free: <id>, owner: <id> }
alloc <var> <resource> | copy <dst> <src> | interior <dst> <src> <off>
use <var> | free <var> | move <var> | if / else / endif
```

## Detected today

Deterministic (`error` / `warning`): `DOUBLE_FREE`, `USE_AFTER_FREE`,
`USE_AFTER_MOVE`, `LEAK`, `FREE_INTERIOR`, `MOVE_INTERIOR`, `FREE_AFTER_MOVE`,
`MOVE_AFTER_FREE`, `DOUBLE_MOVE`, `WRONG_DEALLOCATOR`, `NULL_DEREF` (of a
possibly-null pointer, and — said separately — of one kenbi knows IS null:
`free(p); p = NULL; *p`, or a read after a release declared to return NULL),
`CONTRACT_NOT_HONORED`, `UNUSED_MUST_USE`, `DANGLING_RETURN` (return of a pointer
into a local / a freed pointer), `BORROW_FREED` (a `@borrows` / arena object freed
individually), `BORROW_OUTLIVES_OWNER` (use after the owner / arena is gone),
`UNCONTRACTED_ESCAPE` / `UNCONTRACTED_RELEASE` (an owned pointer crosses a callee /
release boundary that declares no ownership contract — the default-red discipline),
`UNSTRUCTURED_GOTO` (a backward / nested / computed goto kenbi refuses to model),
`LOOP_FIXPOINT_LIMIT` (a loop whose analysis does not converge within its iteration limit, refused
rather than judged from an incomplete view),
`LEAK_ON_THROW` (C++: a raw owner still held where a callee without a nothrow
guarantee — or a plain `new` — may unwind; RAII owners are exempt, `noexcept` /
`@nothrow` / `-fno-exceptions` are the proofs; inside a `try` the unwinding exits
land in the handlers, which are checked from their join),
`LEAK_ON_LONGJMP` / `LONGJMP_SKIPS_DESTRUCTOR` / `UNDECLARED_LONGJMP` (a raw owner, or in C++ an
object with a non-trivial destructor, still in scope where a call may `longjmp`; a function that
can reach a longjmp without declaring `@longjmps`), `UNSUPPORTED_SETJMP` (a `setjmp` landing
site, not modelled yet),
`FINALLY_BYPASSED` (an owning exit bypasses a declared `@goto_finally` funnel),
`FREE_NONHEAP` (a `free` of a pointer into stack or other non-heap storage), `BORROW_MOVED` /
`UNCONTRACTED_MOVE` (a move out of a borrow, or into a callee that declares no intake),
`REALLOC_UNVERIFIED` / `REALLOC_SELF_REASSIGN` (a `realloc` whose outcome is not settled before
use, or whose only handle is overwritten), `MISSING_COPY_CONTROL` / `SELF_ASSIGN_UNSAFE` / `DELETE_NONVIRTUAL_BASE` (C++),
`UNSUPPORTED_CONSTRUCT` (an allocation or release in a construct kenbi does not model, refused
rather than dropped), plus `UNKNOWN_RESOURCE` / `STALE_UNSAFE` hygiene checks. Under the opt-in
axes: `UNVALIDATED_INDEX`, `UNVALIDATED_SIZE`, `INAPPROPRIATE_BOUND`, `INDEX_MAYBE_NEGATIVE`,
`UNGUARDED_INVARIANT_WRITE`, `INVARIANT_NOT_MAINTAINED` (`@spatial`), `USE_OF_UNINITIALIZED`
(`@initcheck`), `TYPE_CONFUSION` (`@typecheck`), and `UNGUARDED_ACCESS`, `GUARDED_ESCAPE`,
`LOCK_LEAKED`, `DOUBLE_LOCK`, `UNLOCK_WITHOUT_LOCK`, `LOCK_NOT_ACQUIRED`,
`REQUIRED_LOCK_NOT_HELD`, `LOCK_ORDER_VIOLATION`, `SAME_CLASS_NO_ORDER`,
`UNDECLARED_INDIRECT_CALL`, `UNDECLARED_FN_TARGET` (`@threadsafe`). Loops
(`for`/`while`/`do` and declared goto-loops) are analyzed by a **bounded fixpoint** to
convergence, so cross-iteration hazards are caught; `break`/`continue` and forward goto
cleanup ladders are modelled; leaks are checked at every function exit.

Advisory (`advisory` severity, never gates — for the review layer): `GUARDED_BY`,
`REQUIRES_LOCK`, `ACQUIRES`, `RELEASES`, `LOCK_ORDER`, `LOCK_ORDER_CONFLICT`,
`LLM_REVIEW`, `ESCAPE_UNCHECKED` (ownership stored into a field kenbi doesn't
track — the boundary is surfaced, not silently dropped), `POSSIBLE_DOUBLE_FREE` /
`POSSIBLE_USE_AFTER_FREE` (an uncontracted callee whose visible body frees the
argument — a hint until `@frees` is declared, which confirms it), `CONTRACT_UNBOUND` (a
contract that names a parameter the signature does not have), and `UNKNOWN_VAR`
(kenbi has no origin recorded for a handle at that point, so nothing is checked
there — a tripwire on kenbi's own bookkeeping, never a claim about the code).

## Demonstrated: `unsafe` in Rust → verified, no `@unsafe`, in kenbi

A doubly-linked list with back-references (`prev` *and* `next`) needs `unsafe`
raw pointers in safe Rust (or `Rc<RefCell<…>>`/`Weak`, which is *runtime*-checked):
the borrow checker cannot express the shared, cyclic ownership of the links — the
std `LinkedList` itself is built with `unsafe`.

The same structure under kenbi's `@arena` discipline ([`demo/dll.c`](demo/dll.c))
verifies **memory-safe with no `@unsafe`**:

```
$ kenbi demo/dll.c
demo/dll.c: ok — no findings from the checks that ran
  checked: ownership; not checked: bounds, locks, initialisation, tagged unions
```

Every node lives in the arena, the cyclic `prev`/`next` pointers share the arena's
lifetime, no node is freed individually, and nothing is used after the region is
destroyed — all checked statically, on all paths. Where safe Rust forces `unsafe`
to *express* the cyclic references, kenbi *verifies* them under a declared, checked
discipline.

**Honest scope.** This is memory safety (no use-after-free / double-free / leak /
use-after-region-free / individual-free) under the *declared* `@arena` discipline —
**not** Rust's full guarantee: it does not enforce aliasing-XOR-mutation (`&mut`) or
data-race freedom, and the arena trades memory (the whole region is freed at once)
for the simplicity. The claim is narrow and real: kenbi can *host a discipline*
(region ownership) under which this pattern is statically checkable, where a
single-model language must drop to `unsafe`. Contrast [`demo/vec.c`](demo/vec.c)
(a `Vec<i32>` equivalent): manual `malloc` stored into a struct field verifies
clean but raises an `ESCAPE_UNCHECKED` **advisory** — the field's ownership is
honestly flagged as unchecked, not silently passed.

## One allocator, many typed destructors

Real projects allocate with a generic wrapper and release through typed destructors around it.
`free:` / `free_returns_null:` therefore accept several release names — all of them valid
releases of the family, with anything else still `WRONG_DEALLOCATOR` — and `frees_fields:`
records that such a destructor releases the object's owned fields as well:

```c
// @allocator magick::mem { alloc: AcquireQuantumMemory AcquireKernelInfo …,
//                          free_returns_null: RelinquishMagickMemory DestroyKernelInfo …,
//                          frees_fields: DestroyKernelInfo … }
```

Freeing a container while a field still owns is a `LEAK` by default — right for a plain
`free(s)`, wrong for a destructor that exists to release the graph, so the declaration is what
licenses it and an undeclared release stays RED.

Declaring the pairs on ImageMagick RAISES the count (689 → 729 across the 95 files), which is
the closure walking outward rather than a regression: a `DestroyKernelInfo(kernel)` call was an
uncontracted boundary before — kenbi could not see that a release happened there, so nothing
through it was checked — and is now a release it checks, which asks in turn who owns the object.
It also found a real leak: `OrderedDitherImage` (threshold.c) returns on a `SetImageStorageClass`
failure without the `DestroyThresholdMap` every other exit performs.

*Measured in September 2026 on ImageMagick 7.1.2-27 with kenbi as it was then; later versions of kenbi report different totals.*

## Contracting code you may not edit

Every contract above has to sit above a declaration — and a third-party project offers nowhere
to put one. `@contract` names the function instead, so the whole vocabulary works from a
force-included, comment-only overlay header:

```c
// @contract qsort            { borrows: $1 }
// @contract DestroyKernelInfo { frees: $1 }
// @contract AddValueToSplayTree { borrows: $1, moves: $2 $3 }
```

Parameters are named by POSITION (`$1`, 1-based) as well as by name, which is usually what is
needed: C headers commonly declare parameters unnamed, and the call sites that need the contract
see only the prototype.

It is the same contract, resolved through the same binding — so it is **checked, not trusted**.
A `frees:` declaration on a function whose body is in the translation unit is verified against
it (`CONTRACT_NOT_HONORED` if it does not free); freeing a declared `borrows:` parameter is
`BORROW_FREED`; and declaring a borrow leaves the caller still owing the release, so a pointer
handed over and never freed becomes a visible `LEAK` instead of an undecidable boundary. A
contract that names a parameter the signature does not have binds nothing — the boundary stays
RED, the safe direction, with a `CONTRACT_UNBOUND` advisory saying why.

On ImageMagick's MagickCore (95 files, its own compile line), ten `borrows` declarations in
[`demo/imagemagick/kenbi_magick_api.h`](demo/imagemagick/kenbi_magick_api.h) take 657 findings
to 626 and `UNCONTRACTED_ESCAPE` from 249 to 216 — and surface two new `LEAK`s, which is the
mechanism working: a declared boundary is a decidable one. For a *factory*, prefer `@allocator`
— adding the name to a family's `alloc:` list also names the resource and its deallocator, so
leaks and `WRONG_DEALLOCATOR` get checked too (that alone cleared 16 of xml-tree.c's 26
uncontracted releases).

*Measured in September 2026 on ImageMagick 7.1.2-27 with kenbi as it was then; later versions of kenbi report different totals.*

## Intrusive lists: declare the link, declare the drain

The other C list — nodes on the heap, chained through a field, freed one at a time — is not an
arena, and it is where kenbi's per-allocation-site resource model shows through. Every node
comes from one `malloc`, so kenbi saw one resource where the program has a chain of objects:
a release in a walk read as a release of "the" resource and the next step as a use after free.

Two declarations make the chain checkable, and neither is taken on trust:

```c
/* @mem t::n { free: free, owner: cur, link: next } */   /* per resource… */
// @list Cluster { link: next }                           /* …or per record TYPE */

/* @drains(head) */
for (cur = head; cur != NULL; cur = nxt) { nxt = cur->next; free(cur); }
```

`link:` says the resource is a NODE of a collection chained through that field, so a walk is
another element rather than a pointer kenbi cannot place, and a release in the walk removes an
ELEMENT. `@drains(head)` says one loop releases every element — and kenbi checks it: a loop
that releases nothing is `CONTRACT_NOT_HONORED`, a collection nothing drains is a `LEAK`,
`free(cur); cur = cur->next;` is a `USE_AFTER_FREE`, freeing a cursor twice before it advances
is a `DOUBLE_FREE`, and every cursor dangles once the collection is drained.

[`demo/list.c`](demo/list.c) is the whole thing in 30 lines — build, walk, drain — and it
verifies clean:

```
$ kenbi demo/list.c
demo/list.c: ok — no findings from the checks that ran
  checked: ownership; not checked: bounds, locks, initialisation, tagged unions
```

The TYPE form reaches code kenbi cannot edit. ImageMagick's cluster list is walked in nine
functions of `MagickCore/segment.c`; one comment-only line in a force-included overlay
([`demo/imagemagick/kenbi_magick_lists.h`](demo/imagemagick/kenbi_magick_lists.h)) takes that
file from 83 findings to 14, with all 54 `USE_AFTER_FREE` and 4 `DOUBLE_FREE` gone. What a
header cannot say is which loop drains the list — that is a fact about a statement — so those
collections stay RED until the drain is declared at the loop. That is the question kenbi should
be asking, not one it can answer from outside the file.

*Measured in September 2026 on ImageMagick 7.1.2-27 with kenbi as it was then; later versions of kenbi report different totals.*

## Configured low-level verification (`--safety`)

Some properties of low-level code are not in the source at all: which functions run in an
interrupt, what a device API may do, how much stack a build uses, which memory a DMA engine can
reach. `--safety=project.json` takes them from a project file and contract files, and checks the
source against them:

```sh
kenbi --format=json --safety=demo/safety/project.json
```

| property | document |
|---|---|
| forbidden effects in a call closure (allocation, blocking, waiting, recursion), per block or function | [effects](docs/configured_effects.md), [recursion](docs/configured_recursion.md), [effects per state](docs/configured_state_effects.md) |
| resource state machines (operation order, end states, results per return value) | [protocols](docs/configured_protocols.md), [results](docs/configured_protocol_results.md), [blocks](docs/configured_protocol_blocks.md), [function boundaries](docs/configured_function_boundaries.md) |
| buffers borrowed by asynchronous operations (no change, release or reuse before completion) | [async borrows](docs/configured_async_borrows.md), [capacity](docs/configured_borrow_capacity.md), [alignment](docs/configured_borrow_alignment.md), [buffer marks](docs/configured_buffer_marks.md), [read-only storage](docs/configured_storage_permissions.md) |
| execution contexts (interrupt, thread) and the APIs each allows | [contexts](docs/configured_contexts.md) |
| range and alignment of reads, writes and API accesses | [source access](docs/configured_source_access.md), [API capacity](docs/configured_access_capacity.md), [API alignment](docs/configured_access_alignment.md), [returned pointers](docs/configured_return_pointer.md), [pointer reassignment](docs/configured_pointer_bindings.md) |
| loops and counters in ordered checks | [for](docs/configured_for_loops.md), [do-while](docs/configured_do_while.md), [unsigned updates](docs/configured_unsigned_updates.md), [integer parameters](docs/configured_integer_parameters.md) |
| allocation contracts, pool and heap limits, memory regions | [allocation](docs/configured_allocation.md), [memory regions](docs/configured_memory_regions.md) |
| call depth and stack usage (from the compiler's `-fstack-usage` output) | [call depth](docs/configured_call_depth.md), [stack usage](docs/configured_stack_usage.md) |
| MMIO register maps (read-only / write-only, write-1-to-clear, read-to-clear, reserved bits, access width, required barriers) | [MMIO](docs/configured_mmio.md) |
| execution-time bounds supplied by an external WCET tool, tied to the build | [execution time](docs/configured_execution_time.md) |
| binding contract files to the sources, compile options and target they were written for | [artifacts](docs/configured_contract_artifacts.md), [compilation](docs/configured_contract_compilation.md), [target](docs/configured_contract_target.md) |

Every obligation is reported as `verified`, `conditional` (holds under external contracts, which
the result lists as assumptions), `unverified` or `violation`. Anything kenbi cannot resolve is
`unverified`, and the run passes only when every obligation is `verified`, or `conditional` on
assumptions the project file explicitly accepts. The documents above are in Japanese, and each states what it does not cover.
[`demo/safety/`](demo/safety/) and [`demo/dma/`](demo/dma/) are worked examples on fictional
devices.

## What a GREEN does and does not promise

A GREEN means: within the checks that ran, on the code kenbi analysed, every path conforms to
the declared contracts. It does not mean:

- **Safe beyond the axes that were on.** A file without `@spatial` has had no bounds checked;
  where `@kenbi` marks part of a file, the rest of it has had nothing checked.
- **Safe beyond the contracts.** A contract on code kenbi did not see is trusted, and is listed
  as the trusted frontier; `@unsafe` is the author's word, and is listed too. `verified` is the
  answer with nothing taken on trust.
- **Safe beyond what the build defines.** Code excluded by the preprocessor, a different
  `compile_commands.json`, or a different target was not analysed.

What kenbi cannot model it refuses rather than skips: `UNSTRUCTURED_GOTO` (backward gotos,
jumps to nested labels, computed gotos), `LOOP_FIXPOINT_LIMIT`, `UNSUPPORTED_CONSTRUCT`, and
`unverified` under `--safety`. On large real code these refusals are part of the result — a
function that contains one stays RED until it is restructured or declared.

If you find a GREEN that should not be one, please report it with a minimal reproduction: that
is the most serious kind of bug kenbi can have.

## Architecture

The analysis engine is decoupled from the front-end: it works on a front-end-agnostic IR, so
parsing C/C++ is a replaceable part.

```
*.c / *.cpp  ──▶ libclang front-end  ┐
                 (src/frontend_c.nim) ├─▶ Program IR ─▶ typestate engine ─▶ diagnostics
*.mc         ──▶ mini-format parser  ┘   (src/ir.nim)   (src/analyze.nim)
                 (src/parse.nim)
```

| file | role |
|---|---|
| `src/ir.nim` | front-end-agnostic IR (`Program`: resources + statement tree) |
| `src/analyze.nim` | typestate engine (origins, may-set merge, loop fixpoint, leak scan, coverage) |
| `src/clang.nim` | minimal libclang FFI (by-value structs match the C ABI) |
| `src/frontend_c.nim`, `src/cfront_*.nim` | lower real C/C++ and the annotation comments into `Program` |
| `src/annotations/` | registry of the annotation vocabulary |
| `src/compile_db.nim` | extract parse flags from `compile_commands.json` |
| `src/safety_config.nim`, `src/safety_check.nim` | `--safety`: project and contract files, configured checks |
| `src/effect_facts.nim`, `src/protocol_*.nim` | `--safety`: call-closure effects, state machines and borrows |
| `src/parse.nim` | mini-format parser (engine fixtures) |
| `src/kenbi.nim` | CLI: dispatch by extension, print diagnostics |

## Tests

`tests/*.mc` drive the engine directly (17 cases). `tests/c/*.c` and `tests/cpp/*.cpp` carry
those scenarios plus the annotation-specific checks in real C and C++ (349 cases); the runner
lowers each through libclang and asserts the produced diagnostics — **including their source
line** — against the `//EXPECT CODE` markers in each file (on the line itself, or
`//EXPECT CODE@LINE`). A wrong line or a missing/extra
diagnostic fails the suite. `tests/run_tests_project.nim` checks the project-wide coverage
result, the `tests/run_tests_*.py` suites check `--safety` end to end, and
`demo/verify_three_state.py` checks the [three-state corpus](demo/README_three_state.md) and the
MCP server's material generated from it.

## License

kenbi is licensed under the Apache License 2.0 ([LICENSE.md](LICENSE.md)). Material that comes from
other projects, and how it is licensed, is recorded in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
