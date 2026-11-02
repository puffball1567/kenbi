# Juliet three-state demonstration

kenbi is a *conformance enforcer*, not a bug-finder, so the honest way to show what
it does on the NIST Juliet corpus is not a recall/false-positive percentage — it is a
**three-state demonstration**, one trio of files per testcase:

| state | directory | what it is | kenbi verdict |
|-------|-----------|------------|---------------|
| **A** | [`juliet/`](juliet/) | the unannotated testcase: a Juliet original, or a case written in its style | **RED** — *"you cannot even write it this way"* |
| **B** | [`juliet_annotated/`](juliet_annotated/) | **same code**, with ONLY honest ownership/intent annotations added | **RED** — *"you cannot annotate your way out"* |
| **C** | [`juliet_rewritten/`](juliet_rewritten/) | the kenbi-idiomatic safe rewrite | **GREEN** — *"here is how you write it safely"* |

The three directories sit next to each other and share filenames, so a single testcase
is the same name in all three.

## Why state B is the load-bearing one

State A only proves the default is *deny* (an un-annotated heap resource is RED). The
real soundness claim is **state B**: when a conscientious developer writes the *honest*
contract — the intent that actually matches the code — the bug must **stay RED**. If any
honest annotation turned a real bug GREEN, that would be a false negative (a silent
"this is safe" on unsafe code) — the one failure kenbi must not have. State B is the
proactive hunt for exactly that.

The annotations added in state B are honest by construction: they describe what the
code *does* (a buffer is a heap resource freed with `free()`, owned by `data`;
`printLine` borrows its argument and never frees it), and they are applied **identically
to the bad and the good functions** — kenbi is never told where the bug is.

## The property this demo really checks: the RED *reason* converges

Staying RED is necessary but not sufficient. A good checker should, as you add the
honest intent, **migrate the reason for RED from a generic boundary complaint to the
true bug class.** That is the difference between "I can't reason about this" and "this
is a double free."

Measured by [`verify_three_state.py`](verify_three_state.py):

| testcase | state A reasons | state B reasons | state C |
|----------|-----------------|-----------------|---------|
| `CWE401 …malloc_01` (leak) | `UNCONTRACTED_ESCAPE`, `UNKNOWN_RESOURCE` | **`LEAK`** | GREEN |
| `CWE415 …char_01` (double free) | `DOUBLE_FREE`, `UNKNOWN_RESOURCE` | **`DOUBLE_FREE`** | GREEN |
| `CWE416 …char_01` (use after free) | `UNCONTRACTED_ESCAPE`, `UNKNOWN_RESOURCE`, `USE_AFTER_FREE` | **`USE_AFTER_FREE`** (bad), `LEAK` (goodG2B) | GREEN |
| `CWE590 …declare_01` (free non-heap) | `UNCONTRACTED_RELEASE`, … | **`FREE_NONHEAP`** | GREEN |
| `CWE761 …fixed_string_01` (free not at start) | `UNKNOWN_RESOURCE`, … | **`FREE_INTERIOR`**, `LEAK` | GREEN |
| `CWE415 …char_41` (double free, **cross-function**) | `UNCONTRACTED_ESCAPE` / `_RELEASE`, … | **`DOUBLE_FREE`** | GREEN |
| `CWE401 …malloc_41` (leak, **cross-function**) | `UNCONTRACTED_ESCAPE` / `_RELEASE`, … | **`LEAK`** | GREEN |

| `CWE415 …char_22a` (double free, **cross-file**) | `UNCONTRACTED_ESCAPE`, `UNKNOWN_RESOURCE`, … | **`DOUBLE_FREE`** | GREEN |

The two `_41` rows are the cross-function flow variant (the allocation, the first
free and the second free live in *different* functions). They are the clearest
demonstration of what declaring a contract buys: in state A kenbi can only say "ownership crosses an
undeclared boundary" (`UNCONTRACTED_ESCAPE`/`UNCONTRACTED_RELEASE`); once the sink's
honest `@frees` / `@borrows` contract is written, kenbi *proves the bug across the
call boundary* — a `DOUBLE_FREE` that spans two functions, or a `LEAK` pinned to the
allocating function. That cross-function proof is exactly what an annotation-free
checker cannot do.

The `_22a` row extends this **across files**: kenbi analyses each file independently,
so a cross-file contract rides the *prototype* the caller sees. With `@frees(data)` on
the `badSink` prototype in `…_22a.c`, kenbi proves the double free even though the
second free lives in the partner file `…_22b.c`. Multi-file testcases keep the driver
`…_NNa.c` as the three-state unit; partner files (`…_NNb.c`, …) sit in `juliet/` as
context and are skipped by the verifier (they only define the sinks).

In every case the generic `UNKNOWN_RESOURCE` / `UNCONTRACTED_ESCAPE` /
`UNCONTRACTED_RELEASE` noise is replaced by the precise diagnosis once the resource is
declared.

## Two real engine bugs this hunt found (and fixed)

State B is a proactive false-negative hunt, and on the first pass over the two
spatial-temporal classes it earned its keep:

- **CWE-761 was a SOUNDNESS HOLE.** Honestly annotated, the buggy `bad()` came out
  **GREEN** — a false "this is safe" on a real free-not-at-start-of-buffer. The cause:
  the front-end never modelled a pointer self-advance (`for(…; data++)`), so freeing
  the advanced pointer looked like a normal free. Fixed by lowering `p++` / `++p` /
  `p += n` on a tracked pointer to an interior-pointer mutation, and by lowering a
  loop's increment expression into its body so the bounded fixpoint carries it to the
  post-loop free → `FREE_INTERIOR` (+ a sound `LEAK`, because freeing the wrong
  pointer leaks the real allocation).
- **CWE-590 was MISDIAGNOSED.** It stayed RED, but for the wrong reason
  (`UNCONTRACTED_RELEASE` — "declare the intake contract", a suggestion that does not
  even apply to a local that points at a stack array). Fixed by diagnosing a free of a
  pointer known to address a stack / non-heap object as **`FREE_NONHEAP`**.

Both fixes only ever *add* RED, so the corpus-wide State-A reject is unaffected
(spot-checked: 950 files / 2453 memory-relevant functions still all RED, 0 GREEN);
mini 17/17 and C/C++ 129/129 still pass.

Note on `CWE416`: its `goodG2B` allocates and uses but never frees, so under honest
annotation it is correctly RED for **`LEAK`** — a real incidental leak Juliet itself
documents, not a false alarm. The function that goes GREEN is `goodB2G` (allocate, use,
free, do not use again). This is why the C rewrite uses the allocate→use→free-once
shape.

## Doubles as AI-grounding knowledge: the MCP fix-guidance

The State-C rewrites are not just the end of a demo — collectively they are a library of
**kenbi-verified safe idioms**, generated straight from this single corpus into the kenbi
MCP server so an agent can not only DETECT a finding but look up how to fix it:

- [`juliet/manifest.json`](juliet/manifest.json) is the source of truth — one entry per
  case (`id`, `cwe`, `class`, `axis`, `intent`, `contracts`, `file`, `provenance`).
- [`gen_mcp_from_corpus.py`](gen_mcp_from_corpus.py) emits two committed artifacts under
  `mcp/src/generated/`: `findings.ts` (finding-code → the worked A/B/C, served by the
  `explain_finding` tool) and `catalogue.ts` (the safe state-C shape per class, the
  "Complete class coverage" section of the `kenbi://patterns` resource).

The three states map to an agent loop: A = "don't write it this way", B = "you can't
annotate around it", C = "write it like this". check_memory_safety returns a finding →
`explain_finding(code)` returns its A/B/C → the agent writes the C shape → re-check → GREEN.

**No-wrong-code guarantee.** The guidance is advisory, never a trust path — the
deterministic checker stays the sole judge, so a pattern can only help the first draft,
never make the checker accept wrong code. And it cannot show wrong code: every snippet is
a real file in this corpus, `verify_three_state.py` runs kenbi to confirm each A is RED
(converged to its class), each C is GREEN, and the generated `findings.ts` / `catalogue.ts`
are in sync — a drift fails the check.

```sh
KENBI_JULIET=/path/to/juliet python3 demo/verify_three_state.py   # -> ALL THREE-STATE CHECKS PASS
python3 demo/gen_mcp_from_corpus.py                               # refresh the generated MCP files
```

## Reproduce

```sh
nimble build -d:release -y           # build ./kenbi
KENBI_JULIET=/path/to/juliet python3 demo/verify_three_state.py
```

`KENBI_JULIET` only needs to point at a Juliet checkout for its `testcasesupport/`
headers (`std_testcase.h`); the demo files themselves live here in the repo. Expected
tail: `ALL THREE-STATE CHECKS PASS`.

## Scope / status

Nine testcases in `juliet/` are taken unchanged from the Juliet suite; the others follow its
naming scheme and are written for kenbi, including minimal reproductions of three published
CVEs (see [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md)). The corpus lists 54 entries in
[`juliet/manifest.json`](juliet/manifest.json). New entries are added the same way: the
unannotated case into `juliet/`, honest annotations into `juliet_annotated/`, the safe rewrite
into `juliet_rewritten/`, and the verifier to confirm all three.
