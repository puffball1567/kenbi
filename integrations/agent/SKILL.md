---
name: kenbi-memory-safety
description: >
  Use when writing or reviewing C / C++ that manages memory or other
  acquire/release resources (malloc/free, new/delete, fd, lock, file, db).
  Teaches you to (1) write kenbi ownership/lifetime annotations as you code so
  intent is explicit, (2) run the deterministic kenbi checker and treat its
  verdict as ground truth, and (3) give grounded advisory review on the
  residue kenbi cannot see. The deterministic tool — never the LLM — decides
  what is "safe".
---

# kenbi — annotation-driven memory safety for C/C++

`kenbi` is a static, deterministic memory-safety checker. It is *not* a
compiler. It reads ownership / lifetime intent written as **comment
annotations** and checks — statically — that the code does what the annotations
say. Model in one line: **don't guess; an unannotated resource carries no
verdict, and an annotated one is checked, not trusted.**

You (the agent) have three jobs, in order. The split is non-negotiable: **you
*author* annotations and safer code; the deterministic tool *judges*.** Never
emit a "this is safe" verdict yourself — run kenbi.

---

## 1. While you write C/C++ — annotate (upstream prevention)

Writing the annotation **is** the forcing function: to write `@mem` you must
decide who owns the allocation, how big it is, and who frees it — which is
exactly the reasoning that prevents leaks and double-frees. Do it at the
*boundaries*; the interior is inferred.

Declare a resource where it is allocated:

```c
/* @mem imgproc::image { size: n, free: free, owner: data } */
uint8_t *data = malloc(n);     // owner `data` now carries a free-once obligation
uint8_t *row  = data + off;    // interior pointer — inferred, must not be freed
process(row, w);               // a plain use
queue_push(q, data); // @move imgproc::image   — obligation transferred out
```

Rules of thumb:
- **Name resources with a scope** (`lib::image`, not `image`) — flat names
  collide when many libraries are combined.
- **`owner:`** is the variable that holds the allocation; **`free:`** is the
  deallocator that must release it (any function, e.g. `g_object_unref`, not
  only `free`); **`size:`** is the allocation size expression.
- **`// @move <resource>`** on a call transfers the obligation out (into a
  channel, a sink, another owner). After a move the variable is moved-from.
- **`// @copy <resource>`** on an assignment marks a **deep copy** that produces
  a *new* independent owned object (a fresh free-once obligation), as opposed to
  a plain pointer alias `q = p` (same object, inferred automatically). Use it
  when a call duplicates the resource, e.g. `char *q = dup(p); // @copy lib::buf`
  — otherwise the new owner is untracked and its leak/double-free is missed.
- Don't annotate plain values (int, value structs) — they carry no obligation.
- **`// @unsafe`** on a line *quarantines* it: findings on that line are
  suppressed and you take responsibility. Use it only for a region the checker
  genuinely can't model — never to silence a finding you should fix. If an
  `@unsafe` covers nothing, kenbi reports `STALE_UNSAFE` (like an unused
  lint-disable) so dead suppressions don't accumulate.

- **`// @nullable`** / **`// @nonnull`** on a declaration mark whether a pointer
  may be null. Dereferencing a `@nullable` pointer (`*p`, `p->x`, `p[i]`) without
  a null-check is `NULL_DEREF`. A check narrows the branch: `if (p) { /* p
  non-null here */ }`, `if (!p) return; /* p non-null after */`, `if (p != NULL)`
  / `if (p == NULL)`. This is the `Option<T>` discipline.

- **`// @frees(param)`** above a function declares it frees that argument. At
  callsites the call discharges the argument's obligation (composes with
  double-free / leak); and the function's body is checked against the claim — not
  freeing the parameter is `CONTRACT_NOT_HONORED`. This is *checked, not trusted*
  intent — declared behaviour vs. implementation. Its companions are checked the
  same way: **`// @borrows(param)`** (the function only borrows — freeing it is
  `BORROW_FREED`), **`// @moves(param)`**, **`// @owns`** above a factory (the
  return carries a fresh obligation the caller must discharge), and **`// @arena …`**
  (region-owned objects: an individual free is `BORROW_FREED`, use after the region
  dies is `BORROW_OUTLIVES_OWNER`). Passing an owned pointer to a callee with NO
  such contract is `UNCONTRACTED_ESCAPE`; freeing an undeclared pointer parameter is
  `UNCONTRACTED_RELEASE` (the default-red boundary discipline).

- **`// @must_use`** above a function: dropping its result (a bare statement, not
  assigned / returned / passed / tested) is `UNUSED_MUST_USE` — the `#[must_use]`
  discipline for ignored error codes and leaked allocations.

- **Goto vocabulary (optional — declare a goto's structured intent).** Forward
  cleanup ladders and loop-exit gotos are modelled automatically; a backward / nested /
  computed goto stays refused (`UNSTRUCTURED_GOTO`) unless declared. Optionally:
  **`// @goto_noreturn`** on a label = a non-returning terminus (abort/exit/longjmp;
  its paths don't leak); **`// @goto_finally`** on the cleanup funnel = an owning exit
  that bypasses it is `FINALLY_BYPASSED`; **`// @goto_backward`** on a back-edge models
  a simple goto-loop as a do-while (so the fixpoint catches cross-iteration hazards).

> Enforced today: `@mem`, `@move`, `@copy`, `@unsafe`, `@nullable`/`@nonnull`,
> `@frees` / `@borrows` / `@moves` / `@adopts` / `@owns` / `@arena`, `@allocator`,
> `@contract`, `@list` / `@drains`, `@raii`, `@must_use`, the goto vocabulary
> (`@goto_noreturn` / `@goto_finally` / `@goto_backward`), and the opt-in axes:
> `@spatial` (`@counted_by`, `@invariant` / `@maintains`), `@initcheck`, `@typecheck`
> (`@variant`) and `@threadsafe` (which turns the lock annotations below into verified
> checks). Not available — don't write these expecting a check: in-source protocol
> typestate (`@proto`; configured state machines exist under `--safety`) and exclusive
> borrow (`@unique`). The complete, current list is the MCP resource `kenbi://annotations`.
> Advisory outside `@threadsafe` (parsed and surfaced for *your* review, never gated — see
> §4): `@guarded_by`, `@requires_lock`, `@acquires`, `@releases`, `@lock_order`, `@llm`.

## 2. Run the deterministic checker — this is the verdict

```sh
kenbi --format=json --compile-commands=build/compile_commands.json src/foo.c
```

`--format=json` returns `{ "version", "tool", "findings": [ {file, line, code,
severity, message} ] }` with **stable codes** and deterministic order. Treat
findings with `severity: "error"` as ground truth and fix them. Codes:

| code | meaning |
|---|---|
| `DOUBLE_FREE` / `USE_AFTER_FREE` / `USE_AFTER_MOVE` | temporal misuse of an obligation |
| `LEAK` | an obligation never discharged on some path |
| `FREE_INTERIOR` / `MOVE_INTERIOR` | freeing/moving via an interior pointer |
| `FREE_AFTER_MOVE` / `MOVE_AFTER_FREE` / `DOUBLE_MOVE` | move/free ordering |
| `WRONG_DEALLOCATOR` | freed with a function other than the declared `free:` |
| `NULL_DEREF` | deref of a `@nullable` pointer with no null-check |
| `CONTRACT_NOT_HONORED` | declared `@frees` but the body doesn't free it |
| `BORROW_FREED` / `BORROW_OUTLIVES_OWNER` | a `@borrows` / arena object freed individually / used after its owner died |
| `DANGLING_RETURN` | return of a pointer into a local, or a freed pointer |
| `UNCONTRACTED_ESCAPE` / `UNCONTRACTED_RELEASE` | owned pointer crosses a callee / release boundary with no ownership contract |
| `UNUSED_MUST_USE` | a `@must_use` result is discarded |
| `UNSTRUCTURED_GOTO` | a backward / nested / computed goto kenbi refuses to model |
| `FINALLY_BYPASSED` | an owning exit bypasses a declared `@goto_finally` funnel |
| `UNKNOWN_VAR` / `UNKNOWN_RESOURCE` | annotation hygiene |

**propose-then-verify**: when you propose a fix or a new annotation, re-run
kenbi. If it still flags, you are not done. If kenbi is clean, the temporal /
deallocator claims it covers are discharged — say so plainly, scoped to what it
checks. Do not re-litigate kenbi-clean code with hypothetical doubts.

## 3. Advisory review — the residue kenbi cannot see (grounded, never a gate)

kenbi is deterministic and bounded. *You* add a second layer, **grounded by the
annotations** (this is why it beats ungrounded review: your task is "does the
code match the declared intent?", not "guess the intent"). This layer is
**advisory only** — it never overrides or replaces kenbi's verdict. For each
perspective, when you suspect a problem, write a **concrete, falsifiable
scenario** (a specific call sequence that triggers it) plus a confidence; a
concrete scenario is either reproducible or obviously wrong, which kills
hand-wavy hallucinations.

Perspectives (the catalogue of residue):
- **cross-TU ownership** — an allocation in one file freed/owned in another;
  does each side's annotation agree on who frees exactly once?
- **valid-until-next-call** — a returned pointer valid only until the next call
  on the same handle (e.g. `strtok`, iterators); is it used past that point?
- **custom allocator / pool** — arena/pool memory that must not be `free`d
  individually; is the declared `free:` the right one?
- **dual ownership** — two owners believe they free the same object.
- **secret scrub** — keys/passwords not zeroed before free (residual secret).
- **thread-handoff lifetime** — object handed to a thread/callback that
  outlives the owner's scope.
- **type appropriateness** (safety-relevant only) — a too-broad type inviting a
  bug class: `int` used as a length/index (negative → overflow), raw `char*`
  with no length, an outright **unnecessary pointer** (value/stack would do —
  "the safest pointer is the one that doesn't exist").

Keep advisory output low-priority and clearly separate from kenbi's errors.
Aesthetic preferences are out of scope; stay safety-relevant.

## 4. Advisory annotations — intent the engine does NOT decide (you verify it)

Some intent can't be settled statically at low false-positive cost — lock
discipline, lock ordering, acquire/release effects, and anything the author
flags freeform. kenbi parses these annotations and emits them as findings with
`severity: "advisory"`. **Advisory findings never gate the build (the exit code
ignores them) — they are review directives for *you*.** For each one, read the
surrounding code and verify the stated property; if it can be violated, report a
concrete, falsifiable scenario.

| annotation | code | what you must verify |
|---|---|---|
| `// @guarded_by(<lock>)` on a field/var | `GUARDED_BY` | every read/write of it occurs while `<lock>` is held; flag any access path that doesn't |
| `// @requires_lock(<lock>)` on a function | `REQUIRES_LOCK` | every call site already holds `<lock>` |
| `// @acquires(<lock>)` on a function | `ACQUIRES` | it releases `<lock>` on every path (incl. early returns / errors); no re-acquire while held |
| `// @releases(<lock>)` on a function | `RELEASES` | `<lock>` was held on entry; not used after release |
| `// @lock_order(<a> < <b>)` | `LOCK_ORDER` | no path acquires `<a>` and `<b>` in the reverse order |
| (two conflicting orders declared) | `LOCK_ORDER_CONFLICT` | a declared deadlock (`a<b` *and* `b<a`) — confirm and fix the ordering |
| `// @llm <freeform>` | `LLM_REVIEW` | the author's freeform instruction — do exactly what it asks |

These complement dynamic tools (TSan), which see only observed interleavings:
you read *all* source paths statically, including cold ones. You catch
*accidental deviation from the declared intent* — not lock-free correctness or
deliberately-racy designs, which belong to TSan. As always: advisory, never a
gate; the deterministic engine remains the only judge of `error` findings.

---

## Hard rules

- **The deterministic tool judges; you author.** Never declare code safe on your
  own authority — run kenbi.
- **Annotate boundaries, infer interiors.** Put intent at allocation / transfer
  / signatures; let the tool propagate.
- **Don't silence — fix or take responsibility.** A finding is fixed by code or
  by a reviewed, explicit annotation, not by deleting the marker.
- **Stale annotations are bugs.** If an annotation no longer matches the code,
  update it; kenbi will flag inconsistencies (`WRONG_DEALLOCATOR`, etc.).
- **Don't restate an annotation in prose.** Who owns a resource, which function
  frees it, that a pointer may be null, which lock guards a field: once an
  annotation says it, an ordinary comment saying it again is never checked and
  drifts from the code. Keep ordinary comments for what the vocabulary cannot
  say — why, and constraints from outside the code.
- **No findings is not "safe".** A result without findings covers the checks that
  ran on the functions they ran on, and rests on the contracts and `@unsafe` it
  lists; report it with that scope, not as a verdict on the whole program.
