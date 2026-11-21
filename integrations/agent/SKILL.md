---
name: kenbi-memory-safety
description: >
  Use when writing or reviewing C / C++ that manages memory or other
  acquire/release resources (malloc/free, new/delete, fd, lock, file, db),
  indexes buffers, or is checked by kenbi (CLI or the kenbi MCP server).
  Teaches you to (1) write kenbi annotations as you code so intent is
  explicit, (2) run the deterministic kenbi checker — through the MCP tools
  when they are available — and treat its verdict as ground truth, (3) fix
  each finding the way that actually resolves it, and (4) give grounded
  advisory review on the residue kenbi cannot see. The deterministic tool —
  never the LLM — decides what is "safe".
---

# kenbi — annotation-driven memory safety for C/C++

`kenbi` is a static, deterministic memory-safety checker. It is *not* a
compiler. It reads ownership / lifetime intent written as **comment
annotations** and checks — statically — that the code does what the annotations
say. Model in one line: **don't guess; an unannotated resource carries no
verdict, and an annotated one is checked, not trusted.**

You (the agent) have four jobs, in order: annotate (§1), run the checker (§2),
fix what it reports (§3), and review what it cannot see (§4, §5). The split is
non-negotiable: **you *author* annotations and safer code; the deterministic
tool *judges*.** Never emit a "this is safe" verdict yourself — run kenbi.

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

- **`// @unique(param)`** above a function declares the pointer exclusive for the
  call — no other argument reaches the same object (C's `restrict`, checked). Each
  call is verified: the same object passed twice is `UNIQUE_ALIASED`, and a pair
  kenbi cannot show distinct is `UNIQUE_UNPROVEN`. The body may not store the
  pointer where it outlives the call (`UNIQUE_ESCAPES`). Declare it on functions
  whose result is wrong when source and destination overlap.

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

### Opting in, and the other axes

Nothing is checked until the code opts in. `// @kenbi` above a function (or at
file level, or on a block) adopts it for the ownership checks; each further
axis has its own marker and is off without it. A result always lists which
checks ran on which functions — read that list before reporting.

**Bounds — `// @spatial`.** An index or a length that comes from outside must
have a bound check on the path to the access.

```c
// @spatial
// @counted_by(buf: n)                 the pointer's size, declared
// @invariant(n >= 1)                  what the body assumes of its parameters
int first_or(const int *buf, unsigned n, unsigned i) {
  if (i < n) return buf[i];            // checked on the path: covered
  return buf[0];                       // covered by the declared n >= 1
}
```

- Write the index as **a variable plus or minus a constant** (`buf[i]`,
  `buf[i + 1]`, `buf[i++]`, `*(p + i)`), a constant, or `x % K` / `x & K`.
  A product, a call, two variables or a nested read (`buf[a * b]`,
  `buf[next()]`, `buf[tab[i]]`) cannot be matched to a check and is reported:
  store the value in a variable first, then bound that variable.
- The check must cover the buffer (`i < n` for a buffer of `n` elements, not a
  looser bound), a signed index also needs `i >= 0`, and the guard must not
  wrap: `i + 4 <= n` on an unsigned `i` is not credited; `n >= 4 && i <= n - 4` is.
- A constant index into a buffer of variable size needs the size shown large
  enough: a check (`if (n >= 1)`, `if (n == 0) return;`) or `@invariant(n >= K)`.
- An `@invariant` on parameters is **verified at every call**: a caller that
  cannot show its arguments satisfy it gets `INVARIANT_NOT_MAINTAINED`. Declare
  it only when the callers really establish it. An `@invariant` on a field
  (`@invariant(p->len <= p->cap)`) protects the field: each write to it needs
  `// @maintains(...)`, which is checked.

**Initialisation — `// @initcheck`.** A local declared without an initializer
must be assigned on every path before it is read.

**Tagged unions — `// @typecheck`** with `// @variant(<member>: <tag> == <value>)`
per member: a member may be used only where its tag is proven
(`if (n->tag == 1)`, `case 1:`).

**Locks — `// @threadsafe`.** Inside it the lock annotations are verified, not
advisory: `// @guarded_by(<lock>)` on a field, `// @requires_lock(<lock>)`,
`// @acquires(<lock>)` / `// @releases(<lock>)` on functions, and
`// @lock_order(<a> < <b>)`.

**Non-local jumps.** A function that can reach a `longjmp` declares it:
`// @longjmps`, or `// @longjmps_to(<jmp_buf>)` when the buffer is known. Write
the landing site as the whole condition of an `if` or `switch`
(`if (setjmp(env))`). A local that is changed after the `setjmp` and read after
a jump back must be `volatile`.

> Enforced today: `@mem`, `@move`, `@copy`, `@unsafe`, `@nullable`/`@nonnull`,
> `@frees` / `@borrows` / `@moves` / `@adopts` / `@owns` / `@unique` / `@arena`, `@allocator`,
> `@contract`, `@list` / `@drains`, `@raii`, `@must_use`, the goto vocabulary
> (`@goto_noreturn` / `@goto_finally` / `@goto_backward`), and the opt-in axes:
> `@spatial` (`@counted_by`, `@invariant` / `@maintains`), `@initcheck`, `@typecheck`
> (`@variant`) and `@threadsafe` (which turns the lock annotations below into verified
> checks). Not available — don't write this expecting a check: in-source protocol
> typestate (`@proto`; configured state machines exist under `--safety`). The complete,
> current list is the MCP resource `kenbi://annotations`.
> Advisory outside `@threadsafe` (parsed and surfaced for *your* review, never gated — see
> §5): `@guarded_by`, `@requires_lock`, `@acquires`, `@releases`, `@lock_order`, `@llm`.

## 2. Run the deterministic checker — this is the verdict

### With the kenbi MCP server (preferred when it is connected)

The server gives you two tools and two resources. Use them in this order:

1. **Before writing**, read the resource `kenbi://annotations` (the complete,
   current annotation reference) and `kenbi://patterns` (the safe shape for each
   kind of code, and the unsafe ones kenbi rejects). They are the source of
   truth; this file is a summary of them.
2. **After every edit** to checked C/C++, call `check_memory_safety` with the
   files you changed (`files`; pass `cwd` so relative paths resolve, and
   `compileCommands` or `clangArgs` when the file needs include paths or flags
   to parse).
3. **Read the summary first.** It says which checks ran on which functions,
   and what the result rests on without checking (contracts, `@unsafe` lines).
   A file whose functions were not adopted, or an axis that did not run, was
   not checked — "no findings" there means nothing.
4. **For each finding**, call `explain_finding` with its `code`. It returns a
   worked example in three states: what triggers the finding, a half-fix that
   is still reported, and the fix. Write your code to the third shape.
5. **Re-run `check_memory_safety`** and repeat until it reports no findings.
   Do not report the work as done on the strength of the edit alone.

If a call fails (the file does not parse, the checker times out), say so and
fix the cause — a run that did not complete is not a clean result.

### With the command line

```sh
kenbi --format=json --compile-commands=build/compile_commands.json src/foo.c
```

`--format=json` returns `{ "version", "tool", "findings": [ {file, line, code,
severity, message} ] }` with **stable codes** and deterministic order. Treat
findings with `severity: "error"` as ground truth and fix them.

**propose-then-verify**: when you propose a fix or a new annotation, re-run
kenbi. If it still flags, you are not done. If kenbi is clean, the claims it
covers are discharged — say so plainly, scoped to what it checked. Do not
re-litigate kenbi-clean code with hypothetical doubts.

## 3. Fix a finding — what resolves it, and what does not

A finding means kenbi could not show the code does what it declares. Either
the code is wrong, or the intent is not declared. Decide which by reading the
code, then fix that. The message names the line and usually the fix.

| code | what it means | what resolves it |
|---|---|---|
| `LEAK` | an obligation is never discharged on some path | release it on that path (early returns and error paths are the usual ones), or transfer it with a declared `@move` / `@moves` / return from an `@owns` function |
| `DOUBLE_FREE` / `USE_AFTER_FREE` | released twice, or used after release | remove the second release or reorder the use; if a callee releases it, declare `@frees` on the callee and drop the caller's release |
| `USE_AFTER_MOVE` / `DOUBLE_MOVE` / `FREE_AFTER_MOVE` | the handle was used after its obligation left | stop using the moved-from handle, or do not move it |
| `FREE_INTERIOR` / `FREE_NONHEAP` | a release through a pointer that is not the start of a heap block | release the owner, not the interior pointer |
| `WRONG_DEALLOCATOR` | released with a function other than the declared `free:` | call the declared deallocator; change `free:` only if the declaration was the mistake |
| `NULL_DEREF` | a `@nullable` pointer dereferenced without a check | check it on the path (`if (!p) return;`) |
| `DANGLING_RETURN` | returns a pointer into a local, or a released pointer | return an owned object or write into caller storage |
| `UNCONTRACTED_ESCAPE` / `UNCONTRACTED_RELEASE` / `UNCONTRACTED_MOVE` | an owned pointer crosses a function boundary that declares nothing | declare what the callee does on the callee: `@borrows`, `@frees`, `@moves`, `@adopts` (or `@contract` for code you cannot edit) |
| `CONTRACT_NOT_HONORED` / `BORROW_FREED` / `BORROW_MOVED` | the body does not do what its contract says | fix the body, or correct the contract if it was wrong — then every caller is re-checked against it |
| `BORROW_OUTLIVES_OWNER` | a borrow or arena object used after its owner died | shorten the use or lengthen the owner |
| `UNIQUE_ALIASED` / `UNIQUE_UNPROVEN` | an `@unique` parameter is passed an object another argument reaches, or may reach | pass a separate object or a copy; make the distinction visible (distinct variables or members, a fresh allocation, `@unique` on the caller's own parameter) |
| `UNIQUE_ESCAPES` | the body stores an `@unique` pointer where it outlives the call | keep it in locals, or drop `@unique` if the function does keep it |
| `UNVALIDATED_INDEX` / `UNVALIDATED_SIZE` | an index or length reaches a buffer with no bound check on the path, or in a form kenbi cannot read | add the check before the access; put a computed index in a variable and bound that |
| `INAPPROPRIATE_BOUND` | a check is present but does not cover the buffer | check against the buffer's real size |
| `INDEX_MAYBE_NEGATIVE` | a signed index with no lower bound | add `i >= 0`, or use an unsigned type |
| `INVARIANT_NOT_MAINTAINED` | a write breaks a declared invariant, or a call does not establish a parameter invariant | establish it before the write or the call (a check, or the caller's own `@invariant`) |
| `UNGUARDED_INVARIANT_WRITE` | a protected field written without `@maintains` | add `// @maintains(...)` on a write that keeps the invariant |
| `USE_OF_UNINITIALIZED` | a local read before it is assigned on some path | initialise it at the declaration or on the missing path |
| `TYPE_CONFUSION` | a union member used where its tag is not proven | test the tag on the path |
| `UNGUARDED_ACCESS` / `REQUIRED_LOCK_NOT_HELD` | a guarded field or a `@requires_lock` function reached without the lock | take the lock, or declare `@requires_lock` on the enclosing function |
| `LOCK_LEAKED` / `DOUBLE_LOCK` / `UNLOCK_WITHOUT_LOCK` | unbalanced locking on some path | release on every path; do not re-acquire a held lock |
| `LOCK_ORDER_VIOLATION` | locks taken against the declared order | take them in the declared order |
| `LEAK_ON_THROW` / `LEAK_ON_LONGJMP` / `LONGJMP_SKIPS_DESTRUCTOR` | an owner is held where a call may unwind or jump | hold it in an RAII owner, release it before the call, or (longjmp) free it where the jump lands |
| `UNDECLARED_LONGJMP` / `UNKNOWN_LONGJMP_TARGET` | a function can reach a longjmp without declaring it, or its target | declare `@longjmps` / `@longjmps_to(<jmp_buf>)` |
| `SETJMP_CLOBBERED` | a local changed after the setjmp is read after a jump back | declare it `volatile`, or assign it again before the use |
| `UNSTRUCTURED_GOTO` / `UNSUPPORTED_SETJMP` / `UNSUPPORTED_CONSTRUCT` / `LOOP_FIXPOINT_LIMIT` | a construct kenbi refuses rather than guesses at | rewrite it in the form the message names |
| `UNUSED_MUST_USE` | a `@must_use` result discarded | use or test the result |
| `STALE_UNSAFE` / `UNKNOWN_VAR` / `UNKNOWN_RESOURCE` | an annotation that matches nothing | remove or correct the annotation |

For any code, `explain_finding` (MCP) gives a worked example; the table is the
short form.

**These do not resolve a finding. Do not do them:**

- **Adding `// @unsafe` to make it go away.** `@unsafe` is a statement that a
  human takes responsibility for a line kenbi cannot model. It is listed in
  every result as trust that was not checked. Propose it only when the code is
  right and cannot be written in a checkable form, say why, and leave the
  decision to the user.
- **Removing the opt-in marker or the annotation** (`@kenbi`, `@spatial`,
  `@mem`, …) so the check no longer runs.
- **Declaring something that is not true** to satisfy the check: an
  `@invariant` no caller establishes, a `@counted_by` larger than the buffer,
  a `@borrows` on a function that keeps the pointer, a `@frees` on one that
  does not free. Contracts are checked against bodies and callers, so this
  usually only moves the finding — and where it is not checkable, it hides a bug.
- **A check that does not check**: a bound that is looser than the buffer, a
  null test after the dereference, a guard on a different variable.
- **Hiding the expression from the checker**: routing an index through a
  helper, a cast or a macro so it is no longer read, or moving the code into a
  file that is not adopted.
- **Weakening the code's behaviour to quiet a path** (dropping an error path,
  leaking instead of freeing) without saying so.

If a finding looks wrong after you have read the code, do not work around it:
report it to the user with the smallest example that shows it.

## 4. Advisory review — the residue kenbi cannot see (grounded, never a gate)

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

## 5. Advisory annotations — outside `@threadsafe`, intent you verify

Inside a `@threadsafe` scope the lock annotations are verified by kenbi (§1,
§3). Outside one — and for anything the author flags freeform — kenbi parses
the annotations and emits them as findings with `severity: "advisory"`. **Advisory findings never gate the build (the exit code
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
  by a true, checked annotation — never by `@unsafe` on your own decision, by
  deleting a marker, or by declaring what does not hold (§3).
- **Re-run after every change.** An edit is not a fix until the checker says so.
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
