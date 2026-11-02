## Linear-typestate memory-safety analysis (temporal core).
##
## Each allocation is an "origin" carrying a free-once obligation. Variables map
## to origins; copies alias the same origin, interior pointers derive from it.
## Flow-sensitive state is tracked as a *set* of possible AllocStates per origin
## so that branches merge soundly (may-set: the union of both paths).

import std/[tables, algorithm, sets, sequtils, strutils]
import ir

type
  AllocState* = enum asOwned, asFreed, asMoved, asMaybeFreed, asEscaped
    ## asMaybeFreed: the origin was passed to an uncontracted callee whose VISIBLE body frees
    ## it. A per-PATH fact like the others — the branch that does it is usually the branch that
    ## returns (`if (bad) return Destroy(k);`), and holding the fact world-wide made every later
    ## line of the function a use-after-free risk: 490 of ImageMagick's 1135 findings, nearly
    ## all of them on paths the release cannot reach.
    ## asEscaped: ownership left kenbi's view here (stored into a location it cannot follow, or
    ## handed to an uncontracted callee). The escape was already reported, so the origin is not
    ## also called a leak — but only ON THE PATH THAT ESCAPED IT. Held function-wide, an escape
    ## on one branch silenced a real leak on another: `if (c) { s->buf = p; return; }` and the
    ## fall-through that drops `p` came back GREEN.
    ##
    ## Which is why an escape CLEARS asOwned rather than sitting beside it. Adding the flag to a
    ## still-owned state made `{asOwned, asEscaped}` mean two different things — "escaped on this
    ## path" and "escaped on one incoming path, still held on another" — and the leak scan, which
    ## read the flag as a suppressor, could not tell them apart. So the same false GREEN came back
    ## in the merged form:
    ##     if (cond()) b->slot = p;      /* escapes here */
    ##     /* the fall-through drops p — and was silent */
    ## Now the escaping path carries {asEscaped} alone, a join with a path that still holds it
    ## carries asOwned too, and the leak scan needs no special case: asOwned means some reaching
    ## path still owes the release.

  NullKind = enum nkNonNull, nkMaybe, nkNull
    ## nkNonNull is the safe default (untracked vars too); nkMaybe is a declared `@nullable`
    ## or a merge of both; nkNull is a pointer KNOWN to be null (`p = NULL`, or a release
    ## declared to return NULL) — releasing one is the defined no-op. Kept in the per-path
    ## null state so a branch's knowledge never escapes the branch.
  NullState = Table[string, NullKind]

  Severity* = enum sevError, sevWarning, sevAdvisory

  Diag* = object
    line*: int
    code*: string
    msg*: string
    sev*: Severity

  FlowInfo* = object
    ## One ownership *flow* rooted at an entry point (think of a web API
    ## handler). The most actionable view: is this flow fully safety-declared,
    ## and if not, which functions block it?
    entry*: string
    verified*: bool       ## the whole flow is covered + GREEN with no residue
    blockers*: seq[string] ## callees that keep it from being fully verified: an
                          ## uncontracted escape boundary, an uncovered contracted
                          ## callee (trusted frontier), or a RED covered callee

  CoverageStats* = object
    ## Adoption / safety coverage over memory-relevant functions. "Adopted" requires an explicit
    ## `@kenbi` marker — the no-marker convenience (a single file checked as
    ## all-covered) does NOT count as adopted, so a clean un-adopted file honestly
    ## reads 0%, not a misleading 100%.
    totalMem*: int     ## denominator: memory-relevant functions (alloc/free/own/pass)
    adopted*: int      ## memory-relevant funcs explicitly under `@kenbi`
    green*: int        ## adopted AND no RED finding — boundaries declared, modular-trust
                       ## GREEN (the *contracted* numerator: GREEN-capable).
    verified*: int     ## a subset of `green`: its whole contracted-dependency closure is
                       ## itself covered — NO trusted residue. GREEN that rests on nothing
                       ## unverified. `verified == green` ⟺ trustedFrontier is empty.
    red*: int          ## adopted but has a RED finding (needs fixing)
    blocks*: int       ## BLOCKS adopted by a `@kenbi` marker inside a function that is not
                       ## itself adopted. Counted separately, never folded into `adopted`:
                       ## a block under discipline does not put the function under it.
    trustedFrontier*: seq[string] ## uncovered callees that covered GREEN code currently
                       ## rests on via a trusted contract — "cover these to remove the
                       ## trust residue" (sorted, unique).
    contractPackages*: seq[ContractPackage]
                       ## the shipped contract sets this run applied (`@contracts_for`), with
                       ## their declared version and the result of checking their build
                       ## requirements. What a consumer needs to tell "contracts exist for this
                       ## library" from "contracts written for the build in front of me".
    unsafeVouches*: seq[tuple[fn: string, line: int]]
                       ## every `@unsafe` that actually suppressed a finding, with the function
                       ## it sits in. `@unsafe` is the strongest form of trust residue — the
                       ## author asserting what kenbi could not check — so a function carrying
                       ## one is GREEN (the boundary is declared) but never `verified`, and the
                       ## site is named here. Without this, annotating an operation kenbi cannot
                       ## verify read as 100% verified, which is the one thing the coverage
                       ## model exists to prevent.
    verifiedFuncs*: HashSet[string]
                       ## exactly which functions the `verified` count is made of, so a
                       ## per-function question — "is the implementation behind THIS contract
                       ## verified, or only declared?" — can be answered without re-deriving
                       ## the closure (see `kenbi --emit-contracts`). Keyed the way the walk
                       ## that produced it keys functions: the bare name inside one
                       ## translation unit, the merge key (`file::name` for a `static`) across
                       ## a project, where two files may each define a different `static f`.
    flows*: seq[FlowInfo] ## per-entry-point flows, sorted by entry name

  ProjectUnit* = object
    ## What one analysed translation unit contributes to PROJECT-level coverage: its
    ## functions and, per function, whether it is adopted and GREEN. Merging these lets a
    ## call into another analysed file resolve to that file's verdict, so `verified` (a
    ## GREEN that rests on nothing unverified) can span the project instead of stopping at
    ## every file boundary.
    funcs*: seq[Func]
    status*: Table[string, tuple[adopted, green, vouched: bool]]
    flows*: seq[FlowInfo]   ## this file's entry-point flows, re-resolved by projectCoverage
    unsafeVouches*: seq[tuple[fn: string, line: int]]   ## its `@unsafe` trust residue
    blocks*: int            ## its block-level `@kenbi` adoptions
    contractPackages*: seq[ContractPackage]  ## the shipped contract sets it applied

  StateMap = Table[int, set[AllocState]]
  PathState = tuple[st: StateMap, nst: NullState,
                    vo: Table[string, int], iv: Table[string, bool],
                    io: Table[string, int], uo, amb: HashSet[string],
                    tie: Table[string, tuple[other: string, srcDisp: string, resDisp: string, line: int, isResult: bool]],
                    stale: HashSet[string]]
    ## A path diverted by `break` / `continue`: its ownership state, its null state AND its
    ## variable -> origin bindings. The bindings travel with it because what is live on THAT
    ## path decides which origins still matter at the join (see dropOrphanedFreed). `uo` is
    ## the set of handles this path REBOUND to something kenbi cannot place (ikRebind) and
    ## `amb` the set that a join already found bound on one side and rebound on the other:
    ## both travel with the path, because a handle that may point at an unrelated object must
    ## not be identified with a resource at the next join either.

  LabelDeposit = tuple[st: StateMap, nst: NullState,
                       tie: Table[string, tuple[other: string, srcDisp: string,
                                                resDisp: string, line: int, isResult: bool]],
                       stale: HashSet[string]]
    ## a state deposited on a forward-goto's target label. The realloc facts ride along: a
    ## `goto` that leaves while a realloc pair is unsettled must not have that fact laundered
    ## by whichever edge happens to reach the label last.

  PredFacts = Table[string, tuple[exact: bool, val: int]]
    ## CORRELATED BRANCHES: what THIS path has learned about the stable scalars it tested.
    ## `exact` — the value is known to be `val` (a `switch` case label, or the zero side of a
    ## truth test); otherwise all that is known is that it is non-zero. A stable scalar is one
    ## the function never assigns and never takes the address of (see `Ctx.stableScalars`), so
    ## the fact holds for the rest of the path and a later test of the same scalar takes only
    ## the branch that can still happen. Pruning a branch the path cannot reach is what makes
    ##     if (want) p = malloc(…);  …  if (want) free(p);
    ## come out clean instead of leaking, and it is sound in the direction that matters: the
    ## pruned branch is one the program cannot take.

  TryDeposit = tuple[st: StateMap, nst: NullState, ty: string]
    ## a state deposited on a `try` frame by an unwinding exit inside its body; `ty` = the
    ## thrown expression's type for a literal `throw e` ("" = unknown: a may-throw call)

  Analyzer = object
    prog: Program
    nextOrigin: int
    varOrigin: Table[string, int]    ## variable -> origin id (alias resolution)
    interiorVar: Table[string, bool] ## variable -> is it an interior pointer?
    interiorOff: Table[string, int]  ## variable -> its CONSTANT offset from the start of its
                                     ## block on THIS path, folded from the self-advance steps
                                     ## (`p += k` / `p -= k` / `p++` / `p--`). `interiorVar` is
                                     ## the MAY-fact gate — once advanced on any path a handle
                                     ## stays flagged — and this is what can ACQUIT it: an
                                     ## offset provably back at 0 addresses the start again, so
                                     ## releasing the handle releases the allocation. Absent, or
                                     ## `offsetUnknown`, means kenbi cannot show where the handle
                                     ## points and the gate stands. Merged at every join by the
                                     ## flat lattice (equal -> that value, anything else ->
                                     ## unknown), so `if (c) p += 8; else p -= 8;` is unknown on
                                     ## the far side rather than a phantom 0.
    unknownOrigin: HashSet[string]   ## handles REBOUND to something kenbi cannot place
                                     ## (ikRebind). Distinct from simply having no binding:
                                     ## this is a positive fact that survives a join.
    originLink: Table[int, string]   ## collection origin -> the field its elements chain
                                     ## through, so a walk is checked against what was
                                     ## DECLARED rather than any field spelled `next`
    listOrigins: HashSet[int]        ## origins declared to be a `link:`ed collection: the
                                     ## origin stands for the whole intrusive COLLECTION, not
                                     ## one object, so a release through a cursor removes an
                                     ## ELEMENT and only a declared `@drains` loop discharges it
    conflatedOrigins: HashSet[int]   ## origins that are a MERGE of two distinct allocations,
                                     ## made because one handle could name either at a join
                                     ## while ANOTHER live handle still told them apart. A
                                     ## verdict through such an origin is a may-fact: the merge
                                     ## is kenbi's approximation, not something the program did.
    listReleased: HashSet[int]       ## collections that have had at least one element released
                                     ## — what makes a `@drains` declaration checkable
    removedHandles: HashSet[string]  ## cursors whose element was just released and that have
                                     ## not been re-bound since: using one, or reading the link
                                     ## out of it, is the classic `free(cur); cur = cur->next;`
    ambiguousHandles: HashSet[string] ## handles that MAY be their bound origin and may be
                                     ## something unplaceable — one path rebound them, another
                                     ## did not. Their origin is still discharged by a release
                                     ## (so the path that does hold it does not leak), but no
                                     ## claim is made THROUGH them: a double free or a use
                                     ## after free reads as POSSIBLE_*, never as a verdict.
    localAddrVars: HashSet[string]   ## vars holding a pointer into a local (stack);
                                     ## returning one is a dangling-stack escape
    reallocTie: Table[string, tuple[other: string, srcDisp: string, resDisp: string, line: int, isResult: bool]]
                                     ## an UNRECONCILED fresh-dest realloc: result handle ->
                                     ## the source it resized. Which of the two names the live
                                     ## block depends on whether the result came back NULL, and
                                     ## until a path learns that, touching EITHER of them is
                                     ## unverifiable (REALLOC_UNVERIFIED). A per-path fact: the
                                     ## null-test's two branches learn opposite things.
    staleAfterRealloc: HashSet[string] ## source handles a SUCCESSFUL realloc invalidated: the
                                     ## block may have moved, so the old pointer is dangling
                                     ## until it is re-bound (`p = tmp`). Per-path for the same
                                     ## reason — only the success branch knows it.
    originRes: Table[int, string]    ## origin -> resource name
    originDecl: Table[int, int]      ## origin -> declaration line
    contractOrigins: HashSet[int]    ## origins seeded from a `@frees` param contract
    borrowedOrigins: HashSet[int]    ## origins seeded from a `@borrows` param (non-owning;
                                     ## never a leak, must not be freed)
    leakedOrigins: HashSet[int]      ## origins already reported leaked at some exit (dedup:
                                     ## a leak is reported once even if it survives several exits)
    throwReported: HashSet[int]      ## origins already reported LEAK_ON_THROW (dedup: once per
                                     ## origin, at its FIRST unwinding exposure)
    movedHandles: Table[string, int] ## owner HANDLES moved-from by an ikRaiiMove (var key ->
                                     ## the origin it held then): the resource is still owned,
                                     ## by the destination; using / moving / freeing / returning
                                     ## the handle is the use-after-move. Rebinding the handle
                                     ## to another origin (a fresh owner) clears it implicitly
    arenaObjects: HashSet[int]       ## origins allocated from an arena (`@arena`): owned by
                                     ## the region, must not be individually freed
    raiiOrigins: HashSet[int]        ## origins owned by an RAII object (a local of an `@raii`
                                     ## class, e.g. unique_ptr / kir_owned_scalar): released by
                                     ## its destructor at scope exit, so NEVER a leak; movable
                                     ## (std::move -> asMoved; a later use is USE_AFTER_MOVE)
    arenaOf: Table[int, int]         ## arena-object origin -> its arena's origin (lifetime owner)
    fieldOrigins: HashSet[int]       ## origins owned by a tracked field path (`b->buf`): checked
                                     ## for double-free / UAF, leak-scanned only when the base is a
                                     ## function-local that keeps the obligation here (see fieldBase)
    fieldBase: Table[int, string]    ## field origin -> its container's var key (`b` of `b->buf`).
                                     ## The exit leak scan resolves this to decide whether the
                                     ## container carries the obligation away (param / escaped base)
                                     ## or leaves the field to leak at scope exit (#2b)
    baseEscaped: HashSet[string]     ## base var keys whose container escaped WHOLE (`return b`):
                                     ## the transfer carries the fields, so they don't leak at
                                     ## exit. A MUST-fact, intersected at joins: a container that
                                     ## left on one path and was dropped on the other did NOT
                                     ## carry its fields away on the path that dropped it, and
                                     ## holding this union-style silenced the field leaks of every
                                     ## parser that appends its element on one branch only.
    predFacts: PredFacts             ## CORRELATED BRANCHES: see PredFacts. Per path, saved and
                                     ## restored around each branch like the bindings are.
    adoptedOrigins: HashSet[int]     ## origins a declared `@adopts` consumer took over: the
                                     ## container frees the element, so this is not a leak here,
                                     ## the object is still readable (unlike a move), and a
                                     ## release in this function is now a double free
    undeclaredParams: HashSet[int]   ## origins for pointer params with NO ownership contract
                                     ## (ikIncomingPtr): freeing one is UNCONTRACTED_RELEASE
                                     ## (intake default-red); never a leak (the caller owns it)
    maybeFreedBy: Table[int, tuple[callee: string, line: int]] ## origin -> (callee, call line)
    nulledByRelease: HashSet[string] ## handles a release DECLARED to hand back NULL set to NULL
                                     ## while releasing them (`p = destroy(p)`). On such a path
                                     ## the handle is NULL, so returning it returns NULL — not a
                                     ## dangling pointer — and the paths that did NOT release it
                                     ## still own the block. Normally the freed origin is simply
                                     ## dropped as orphaned at the join and none of this is
                                     ## needed; it is needed when some OTHER handle (an interior
                                     ## alias, `cs = base + i`) still names the origin, which
                                     ## keeps it alive for use-after-free detection and so leaves
                                     ## the join holding owned AND freed at once.
    originDisp: Table[int, string]   ## origin -> display name (for contract messages)
    curCovered: bool                 ## is the function being analyzed under `@kenbi`
                                     ## discipline? Within covered scope an un-declared
                                     ## resource is an ERROR (mandatory discipline);
                                     ## uncovered functions' findings are dropped entirely.
    hasFinally: bool                 ## the current function declares a `@goto_finally` funnel
    passedFinally: bool              ## the top-level scan has reached the funnel — exits past
                                     ## here route through cleanup; an owning exit BEFORE it
                                     ## bypasses the funnel (FINALLY_BYPASSED, not a bare LEAK)
    finallyName: string              ## the funnel label name (for the bypass diagnostic)
    gotoMode: bool                   ## top-level labels are join points (always, unless a
                                     ## top-level label name repeats)
    modelledGotos: HashSet[int]      ## identities of the gotos analysed via join-merge: forward
                                     ## jumps to top-level labels. Every other goto is refused
                                     ## where it stands (UNSTRUCTURED_GOTO), so the function stays
                                     ## red while its modelable gotos are still followed.
    pendingLabels: Table[string, seq[LabelDeposit]]
                                     ## label name -> states deposited by forward gotos
                                     ## not yet merged; drained when the label is reached.
    tryFrames: seq[seq[TryDeposit]]
                                     ## one frame per enclosing `try`: the states deposited by
                                     ## the unwinding exits inside its body (a throw, a
                                     ## may-throw call), joined at handler entry
    silent: bool                     ## suppress diagnostics: the loop fixpoint runs the
                                     ## body several times to reach a convergent loop-head
                                     ## state — only the final pass should emit findings.
    breakStates: seq[PathState]      ## states that hit a `break`
                                     ## in the innermost loop/switch — routed to its exit
                                     ## join. Reset by the enclosing loop (per pass) / switch.
    continueStates: seq[PathState]   ## states that hit a `continue`
                                     ## in the innermost loop — routed to the back edge
                                     ## (fixpoint head). Reset by the loop (not by switch, so
                                     ## a continue inside a switch reaches the enclosing loop).
    diags: seq[Diag]

  OriginWorld = object
    ## A snapshot of the analyzer's origin-allocation world. The loop fixpoint reruns
    ## the body from the same baseline each pass; restoring this between passes keeps
    ## origin IDs deterministic (an in-loop `malloc` gets the SAME origin every pass),
    ## so the state maps align across passes and merge correctly. Tables/HashSets are
    ## value types, so capture/restore is a copy.
    nextOrigin: int
    varOrigin: Table[string, int]
    interiorVar: Table[string, bool]
    interiorOff: Table[string, int]
    unknownOrigin, ambiguousHandles, removedHandles: HashSet[string]
    reallocTie: Table[string, tuple[other: string, srcDisp: string, resDisp: string, line: int, isResult: bool]]
    staleAfterRealloc: HashSet[string]
    predFacts: PredFacts
    listOrigins, listReleased, conflatedOrigins: HashSet[int]
    originLink: Table[int, string]
    localAddrVars: HashSet[string]
    originRes: Table[int, string]
    originDecl: Table[int, int]
    originDisp: Table[int, string]
    fieldBase: Table[int, string]
    baseEscaped: HashSet[string]
    contractOrigins, borrowedOrigins, leakedOrigins, throwReported, arenaObjects, raiiOrigins: HashSet[int]
    fieldOrigins, undeclaredParams, adoptedOrigins: HashSet[int]
    arenaOf: Table[int, int]
    maybeFreedBy: Table[int, tuple[callee: string, line: int]]
    nulledByRelease: HashSet[string]
    tryFrames: seq[seq[TryDeposit]]
    movedHandles: Table[string, int]
    pendingLabels: Table[string, seq[LabelDeposit]]
      ## goto-exit deposits are snapshot/restored across fixpoint passes too: a forward
      ## goto OUT of a loop must deposit once (from the final diag pass), not once per dry
      ## run — else the post-loop label would merge stale duplicate exit states.

const unstructuredGotoMsg =
  "control flow through `goto` here is not statically verifiable — a backward jump " &
  "(goto-loop), a jump into a nested block, or a computed goto, none of which kenbi " &
  "models. Such jumps are hard to follow for both analysis and review, so ownership " &
  "cannot be tracked across them. Restructure into structured control flow (a loop, " &
  "early returns, or a single forward cleanup ladder of labels) so the release / " &
  "lifetime of each pointer is checkable."

proc addDiag(a: var Analyzer, line: int, code, msg: string, sev = sevError) =
  if a.silent: return            # a loop-fixpoint dry run — only the final pass emits
  a.diags.add Diag(line: line, code: code, msg: msg, sev: sev)

proc captureWorld(a: Analyzer): OriginWorld =
  OriginWorld(nextOrigin: a.nextOrigin, varOrigin: a.varOrigin,
    interiorVar: a.interiorVar, interiorOff: a.interiorOff,
    unknownOrigin: a.unknownOrigin,
    ambiguousHandles: a.ambiguousHandles, removedHandles: a.removedHandles,
    reallocTie: a.reallocTie, staleAfterRealloc: a.staleAfterRealloc,
    predFacts: a.predFacts,
    listOrigins: a.listOrigins, listReleased: a.listReleased, originLink: a.originLink,
    conflatedOrigins: a.conflatedOrigins,
    localAddrVars: a.localAddrVars,
    originRes: a.originRes, originDecl: a.originDecl, originDisp: a.originDisp,
    fieldBase: a.fieldBase, baseEscaped: a.baseEscaped,
    contractOrigins: a.contractOrigins, borrowedOrigins: a.borrowedOrigins,
    leakedOrigins: a.leakedOrigins, throwReported: a.throwReported,
    arenaObjects: a.arenaObjects, raiiOrigins: a.raiiOrigins,
    fieldOrigins: a.fieldOrigins,
    undeclaredParams: a.undeclaredParams, adoptedOrigins: a.adoptedOrigins,
    arenaOf: a.arenaOf, maybeFreedBy: a.maybeFreedBy, pendingLabels: a.pendingLabels,
    nulledByRelease: a.nulledByRelease,
    tryFrames: a.tryFrames, movedHandles: a.movedHandles)

proc restoreWorld(a: var Analyzer, w: OriginWorld) =
  a.nextOrigin = w.nextOrigin; a.varOrigin = w.varOrigin
  a.interiorVar = w.interiorVar; a.interiorOff = w.interiorOff
  a.unknownOrigin = w.unknownOrigin
  a.ambiguousHandles = w.ambiguousHandles; a.removedHandles = w.removedHandles
  a.reallocTie = w.reallocTie; a.staleAfterRealloc = w.staleAfterRealloc
  a.predFacts = w.predFacts
  a.listOrigins = w.listOrigins; a.listReleased = w.listReleased
  a.originLink = w.originLink; a.conflatedOrigins = w.conflatedOrigins
  a.localAddrVars = w.localAddrVars
  a.originRes = w.originRes; a.originDecl = w.originDecl; a.originDisp = w.originDisp
  a.fieldBase = w.fieldBase; a.baseEscaped = w.baseEscaped
  a.contractOrigins = w.contractOrigins; a.borrowedOrigins = w.borrowedOrigins
  a.leakedOrigins = w.leakedOrigins; a.arenaObjects = w.arenaObjects
  a.throwReported = w.throwReported
  a.raiiOrigins = w.raiiOrigins
  a.fieldOrigins = w.fieldOrigins
  a.undeclaredParams = w.undeclaredParams; a.adoptedOrigins = w.adoptedOrigins
  a.arenaOf = w.arenaOf; a.maybeFreedBy = w.maybeFreedBy
  a.nulledByRelease = w.nulledByRelease
  a.pendingLabels = w.pendingLabels
  a.tryFrames = w.tryFrames
  a.movedHandles = w.movedHandles

proc mergeStateInto(dst: var StateMap, src: StateMap) =
  ## may-set merge: a state is possible after a join if possible on EITHER incoming
  ## path (union). Used to merge if-branches and goto join-points (a label).
  for o, v in src: dst[o] = dst.getOrDefault(o) + v

proc mergeNullInto(dst: var NullState, src: NullState) =
  ## null merge: a var is non-null after a join only if non-null on every incoming path (an
  ## absent var defaults to non-null), and KNOWN-null only if known-null on every path — one
  ## branch setting `p = NULL` must not make p null after the join. Anything else is nkMaybe.
  for k, v in src:
    let d = dst.getOrDefault(k, nkNonNull)
    if v == d: continue
    dst[k] = (if v == nkMaybe or d == nkMaybe: nkMaybe
              elif v == nkNull or d == nkNull: nkMaybe   # null on one path only
              else: nkNonNull)
  for k, d in dst:
    if d == nkNull and src.getOrDefault(k, nkNonNull) != nkNull: dst[k] = nkMaybe

proc arenaDead(a: Analyzer, o: int, st: StateMap): bool =
  ## True if `o` is an arena object whose arena has been destroyed (freed) on the
  ## current path — using it then is a use-after-region-free (BORROW_OUTLIVES_OWNER).
  if o notin a.arenaOf: return false
  let r = a.arenaOf[o]
  r in st and asFreed in st[r]

proc keyA(s: Stmt): string =
  ## Identity of operand `a`: the stable key when present (clang USR), else the
  ## display name (mini-format fixtures carry no key). Variables that merely
  ## share a name in different scopes get distinct keys, so they don't alias.
  if s.aKey.len > 0: s.aKey else: s.a

proc keyB(s: Stmt): string =
  if s.bKey.len > 0: s.bKey else: s.b

proc sameOriginKind(a: Analyzer, o1, o2: int): bool =
  ## Two origins of the same kind (both plain owned resources, both borrows, ...): the
  ## per-origin property sets agree, so unifying them at a join loses no check.
  for s in [a.borrowedOrigins, a.arenaObjects, a.contractOrigins, a.raiiOrigins,
            a.undeclaredParams, a.fieldOrigins, a.adoptedOrigins,
            a.leakedOrigins, a.throwReported]:
    if (o1 in s) != (o2 in s): return false
  (o1 in a.arenaOf) == (o2 in a.arenaOf)

proc handleMoved(a: Analyzer, key: string): bool =
  ## Is this owner HANDLE moved-from (ikRaiiMove) while still bound to the origin it gave away?
  key in a.movedHandles and key in a.varOrigin and a.movedHandles[key] == a.varOrigin[key]

proc untrackedRelease(a: var Analyzer, line: int, disp: string) =
  ## A deallocator called on a pointer kenbi cannot place: the default-red question, asked
  ## the same way whether the handle was never tracked or was REBOUND to something unplaceable.
  a.addDiag(line, "UNCONTRACTED_RELEASE",
    "'" & disp & "' is freed here but kenbi cannot account for its ownership — its " &
    "origin is not tracked (not allocated here, not a declared @owns result, not a " &
    "contracted parameter). Declare where it comes from so the release is checkable: " &
    "@mem if it is allocated here; @owns on the function that returns it; @frees / " &
    "@borrows if it is a parameter; or mark this release @unsafe.")

proc originOf(a: var Analyzer, key, disp: string, line: int): int =
  if key notin a.varOrigin:
    # No binding: kenbi cannot say which resource this handle names, so it has nothing to
    # claim about it here. UNKNOWN_VAR is kenbi telling on ITSELF — a tripwire for a lost
    # binding in the front-end — not a finding about the code, so it is an ADVISORY: visible
    # while debugging, never gating, never counted among a file's findings. A handle rebound
    # to something unplaceable (ikRebind) has no binding on purpose and says nothing at all.
    # The sites that must not go silent (a release) ask their own question instead.
    if key notin a.unknownOrigin:
      a.addDiag(line, "UNKNOWN_VAR", "kenbi has no origin recorded for '" & disp &
        "' at this point, so nothing is checked here", sevAdvisory)
    return -1
  a.varOrigin[key]

proc fieldOrphanLeak(a: var Analyzer, o: int, st: StateMap,
                     dropped: HashSet[string], reason: string) =
  ## Report field origin `o` as a leak IF the event whose site called us *provably* orphans
  ## it — dropping the handles in `dropped` (the field paths that stop reaching it here) is
  ## its last tie to the program. Field origins are deliberately excluded from the exit leak
  ## scan (`scanLeaks`) because the base struct may escape carrying the obligation; this is
  ## the counterpart that catches the leak once the field can no longer carry it.
  ##
  ## Fires only when `o` is provably orphaned, so it never over-accuses:
  ##  - MUST-owned here (`st[o] == {asOwned}`; a free / move on ANY merged path drops it),
  ##  - a tracked field origin, not already escaped or reported,
  ##  - no live key OTHER than the `dropped` handles still reaches `o` (an out-of-struct
  ##    alias — e.g. the `p` in `b->buf = p` — could still free it; that case stays deferred).
  ## Reported once at `o`'s allocation line (like `scanLeaks`), and only for a DECLARED
  ## resource (an undeclared malloc already drew UNKNOWN_RESOURCE — no double accusation).
  if st.getOrDefault(o) != {asOwned}: return
  if o notin a.fieldOrigins: return
  if asEscaped in st.getOrDefault(o) or o in a.leakedOrigins: return
  for k, v in a.varOrigin:
    if v == o and k notin dropped: return     # another live handle reaches it — not orphaned
  let resName = a.originRes.getOrDefault(o, "")
  if resName in a.prog.resources:
    a.leakedOrigins.incl o
    a.addDiag(a.originDecl.getOrDefault(o, 0), "LEAK",
      "leak: '" & a.originDisp.getOrDefault(o, "?") & "' still owns '" & resName & "' " & reason)

proc fieldOverwriteLeak(a: var Analyzer, fieldKey: string, st: StateMap) =
  ## `b->buf = <new>` where `b->buf` already holds an owned field origin: the store overwrites
  ## the field's only handle to it, orphaning the resource it held (unless an alias survives —
  ## deferred). The dropped handle is exactly `fieldKey`.
  if fieldKey notin a.varOrigin: return
  a.fieldOrphanLeak(a.varOrigin[fieldKey], st, [fieldKey].toHashSet,
    "when it is overwritten here — free it before reassigning")

proc freeBaseOrphansFields(a: var Analyzer, baseKey, baseDisp: string, st: var StateMap,
                           releasedBy: string) =
  ## `free(b)` releases the container: after it, any field path `b->…` is inaccessible, so a
  ## field that still owns a resource is orphaned by this free — you freed the struct without
  ## releasing its owned member. Report each such field (provably orphaned; an out-of-struct
  ## alias defers it). The dropped handles are every field key of THIS base.
  let prefix = baseKey & "::"
  var dropped: HashSet[string]
  for k in a.varOrigin.keys:
    if k.startsWith(prefix): dropped.incl k
  if dropped.len == 0: return
  if releasedBy in a.prog.deepFrees:
    # a release DECLARED to free the object's owned fields as well (`frees_fields:`): the
    # fields are discharged here, not abandoned. Trusted like any contract at a boundary whose
    # body is not covered, and verified once it is.
    for fk in dropped:
      let o = a.varOrigin[fk]
      if o in st: st[o] = {asFreed}
      a.varOrigin.del fk
    return
  for fk in dropped:
    a.fieldOrphanLeak(a.varOrigin[fk], st, dropped,
      "when its container '" & baseDisp & "' is freed here — free the field before freeing the struct")

proc scanThrowLeaks(a: var Analyzer, s: Stmt, st: StateMap) =
  ## ikMayThrow: control may leave the function here by unwinding — a callee without a
  ## nothrow guarantee, or a throwing `new`. Every RAW owner still held is lost on that
  ## path: a declared resource (malloc / new / `@owns`; not an RAII owner, whose destructor
  ## runs during unwinding), or a `@frees` obligation not yet discharged. The same exclusions
  ## as the exit leak scan (a borrow, an escape, a maybe-freed handoff, an undeclared
  ## incoming pointer, a field origin never leak). Reported once per origin at its FIRST
  ## exposure (throwReported), so the fix site is the earliest call to guard.
  for o in 0 ..< a.nextOrigin:
    if o notin st or asOwned notin st[o]: continue
    if o in a.leakedOrigins or o in a.throwReported: continue
    if o in a.borrowedOrigins or asMaybeFreed in st[o] or
       o in a.undeclaredParams or o in a.raiiOrigins or o in a.fieldOrigins or
       o in a.arenaObjects:
      continue
    let disp = a.originDisp.getOrDefault(o, "?")
    if o in a.contractOrigins:
      a.throwReported.incl o
      a.addDiag(s.line, "LEAK_ON_THROW",
        "'" & disp & "' is declared `@frees` but is still owned when '" & s.a & "' may throw — " &
        "on that path it is never freed and the contract is not honoured. Release it before " &
        "the call, or prove the callee cannot throw (`noexcept`, or vouch it `@nothrow`).")
    else:
      let resName = a.originRes.getOrDefault(o, "")
      if resName notin a.prog.resources: continue   # undeclared: UNKNOWN_RESOURCE already said so
      a.throwReported.incl o
      a.addDiag(s.line, "LEAK_ON_THROW",
        "'" & resName & "' (" & disp & ") is owned here but '" & s.a & "' may throw — on that " &
        "path it is never released. Hold it in an RAII owner (unique_ptr / an `@raii` class), " &
        "release it before the call, or prove the callee cannot throw (`noexcept`, or vouch " &
        "it `@nothrow`; `-fno-exceptions` turns the axis off for a no-exception build).")

proc predSays(a: Analyzer, key: string): tuple[known: bool, nonZero: bool] =
  ## What this path already knows about the truth of a stable scalar, if anything.
  if key.len == 0 or key notin a.predFacts: return (false, false)
  let f = a.predFacts[key]
  (true, (if f.exact: f.val != 0 else: true))

proc predRulesOutCase(a: Analyzer, key: string, caseVal: int): bool =
  ## Can this path NOT be in that case group? Only when the scalar's exact value is known and
  ## differs. A group with no single constant label (`low(int)`: default, or fall-through) is
  ## never ruled out — the value could be anything the earlier groups did not claim.
  if key.len == 0 or caseVal == low(int) or key notin a.predFacts: return false
  let f = a.predFacts[key]
  f.exact and f.val != caseVal

proc mergePredInto(dst: var PredFacts, src: PredFacts) =
  ## A fact survives a join only when both incoming paths carry it, and agree.
  var keep: PredFacts
  for k, v in dst:
    if k in src and src[k] == v: keep[k] = v
  dst = keep

proc settleRealloc(a: var Analyzer, key: string, nonNull: bool, nst: var NullState) =
  ## This path has just learned whether a fresh-dest realloc's RESULT came back null, which is
  ## precisely what decides which of the two handles names the live block:
  ##   non-null -> the resize succeeded; the result owns the block and the SOURCE handle is
  ##               dangling (realloc may have moved the block) until it is re-bound (`p = tmp`);
  ##   null     -> the resize failed; the result is nothing and the SOURCE still owns the block.
  ## Either way the pair is settled and checkable again. This is the whole reason the standard
  ## idiom is safe, and the reason kenbi can now verify it instead of asking for a vouch.
  if key notin a.reallocTie: return
  let t = a.reallocTie[key]
  if not t.isResult: return   # a null test of the SOURCE decides nothing: the source is not what
                              # realloc returns, so its value says nothing about whether the
                              # resize succeeded
  a.reallocTie.del key        # the pair is tied under BOTH names; settling frees both
  a.reallocTie.del t.other
  # Record what the branch learned. The null case matters as much as the other: a release of a
  # result this path knows is NULL is the defined no-op, so it must NOT discharge the block —
  # which is still the source's, and is a leak if nothing else releases it.
  nst[key] = (if nonNull: nkNonNull else: nkNull)
  if nonNull: a.staleAfterRealloc.incl t.other

proc reallocUnsettled(a: var Analyzer, key, disp: string, line: int, verb: string): bool =
  ## Is `key` one half of a realloc pair this path has not settled — either the result, which
  ## may be NULL (so releasing it leaks the original), or a source whose block a successful
  ## realloc may have moved (so touching it is a dangling access)? Default-red either way.
  if key in a.reallocTie:
    let t = a.reallocTie[key]
    let res = t.resDisp   # the handle realloc returned
    let src = t.srcDisp   # the handle it was asked to resize
    a.addDiag(line, "REALLOC_UNVERIFIED",
      "'" & disp & "' is one half of `" & res & " = realloc(" & src & ", …)` at line " & $t.line &
      ", whose result has not been null-checked: on OOM realloc returns NULL and the block is " &
      "still the one '" & src & "' holds, while on success the block is '" & res & "' and '" &
      src & "' is dangling. Which of them names it here is therefore not known. Reconcile first " &
      "— `if (" & res & ") " & src & " = " & res & ";` — before it is " & verb &
      ", or mark this @unsafe.")
    return true
  if key in a.staleAfterRealloc:
    a.addDiag(line, "REALLOC_UNVERIFIED",
      "'" & disp & "' was resized by a realloc that succeeded, so the block may have moved and " &
      "'" & disp & "' is a dangling handle to the old one. Use the realloc result instead, or " &
      "re-bind '" & disp & "' to it (`" & disp & " = <result>;`) before it is " & verb & ".")
    return true
  false

proc applyInstr(a: var Analyzer, s: Stmt, st: var StateMap, nst: var NullState) =
  # A handle given a new identity here is of known provenance again, whatever an earlier
  # ikRebind said about it (`p = s->buf; p = malloc(8);` — the second assignment answers the
  # question the first one opened).
  if s.kind == stInstr and s.ik in bindingInstrs and s.keyA.len > 0:
    a.unknownOrigin.excl s.keyA
    a.ambiguousHandles.excl s.keyA
    a.removedHandles.excl s.keyA
  case s.ik
  of ikNullable: nst[s.keyA] = nkMaybe
  of ikNonNull:  nst[s.keyA] = nkNonNull
  of ikReturn:   discard           ## divergence handled by analyzeBody
  # SPATIAL sinks/sources — handled by analyzeSpatial (a separate bounds pass); the
  # temporal engine ignores them.
  of ikIndex, ikValidate, ikTaint, ikValueCopy, ikMaintainsCheck, ikEstablishCheck,
     ikLowBound, ikLowInvariantCheck,
     ikLockAcquire, ikLockRelease, ikGuardedAccess, ikRequiredLockCall, ikGuardedEscape,
     ikIndirectCall, ikFnAssign,
     ikInitWrite, ikInitRead, ikVariantAccess: discard
  of ikMustUse:
    # the front-end emits this only at a statement-level call whose result is
    # discarded; the callee is declared `@must_use`, so dropping it is the bug.
    a.addDiag(s.line, "UNUSED_MUST_USE",
      "result of '" & s.a & "' is discarded but it is declared `@must_use`")
  of ikInvariantWrite:
    # the front-end emits this only for an UNANNOTATED write to a field declared under
    # an `@invariant`. Every write to a protected field must declare its effect, or the
    # invariant cannot be trusted (a write that breaks it would slip past). This is the
    # write-barrier — default-red until the write is accounted for.
    a.addDiag(s.line, "UNGUARDED_INVARIANT_WRITE",
      "'" & s.a & "' is declared under an @invariant, but this write does not say what it " &
      "does to it. Every write to a protected field must be accounted for, else the invariant " &
      "is not trustworthy. Declare `@maintains(<the relation>)` on this write (kenbi verifies " &
      "it preserves the invariant), or mark it @unsafe.")
  of ikFieldBaseEscape:
    # `return b` of a struct that owns fields: the whole container transfers to the caller,
    # carrying its fields' obligations, so those fields do not leak at scope exit. Only a
    # self-evident whole-struct transfer is recorded here; an unrecognised container escape
    # stays default-red (its still-owned field leaks — declare the transfer / mark @unsafe).
    a.baseEscaped.incl s.aKey
  of ikEscape:
    # a container stored into an untracked location (`dest->state = copy`) carries its own
    # fields with it: their fate is the receiver's, so the exit leak scan must defer them
    a.baseEscaped.incl s.keyA
    # stored into an untracked location (`*p = q` / `arr[i] = q`) -> the obligation left our
    # view. kenbi stops tracking it, and does NOT assume some other owner will free it: an
    # unverifiable hand-off is default-red (declare-don't-infer). If the store intentionally
    # hands ownership to external code / a system boundary, `@escapes` on the line declares it;
    # otherwise it is an error (its leak / double-free is now unchecked — free it here, model
    # the destination's ownership, or `@escapes` / `@unsafe`). A `@borrows` value never owned it.
    if s.keyA in a.varOrigin:
      let o = a.varOrigin[s.keyA]
      st[o] = (st.getOrDefault(o) - {asOwned}) + {asEscaped}
      if o notin a.borrowedOrigins and s.line notin a.prog.escapesLines:
        a.addDiag(s.line, "ESCAPE_UNCHECKED",
          "ownership of '" & s.a & "' is stored into a location kenbi cannot follow (a raw " &
          "field / `*p` / `arr[i]`) — from here its release is unchecked. If an external owner " &
          "takes it, declare `@escapes` on this line; otherwise free it here (or `@unsafe`).")
  of ikObligation:
    # a `@frees` parameter enters the function already owning an obligation to
    # free it; if the body doesn't, that's a contract violation (not a leak).
    let o = a.nextOrigin
    inc a.nextOrigin
    a.varOrigin[s.keyA] = o
    a.interiorVar[s.keyA] = false
    a.originDecl[o] = s.line
    a.originDisp[o] = s.a
    a.contractOrigins.incl o
    st[o] = {asOwned}
  of ikBorrow:
    # a `@borrows` parameter enters as a live but non-owning reference. It is
    # usable and returnable (passthrough), never a leak, but freeing it is a
    # contract violation (the owner is responsible for the free).
    let o = a.nextOrigin
    inc a.nextOrigin
    a.varOrigin[s.keyA] = o
    a.interiorVar[s.keyA] = false
    a.originDecl[o] = s.line
    a.originDisp[o] = s.a
    a.borrowedOrigins.incl o
    st[o] = {asOwned}
  of ikGoto, ikBreak, ikContinue, ikThrow, ikOwnsOut:
    # control-flow instructions: handled in analyzeBody (deposit/route + divergence).
    # Never reached here — applyInstr is only called for non-control instructions.
    discard
  of ikUnsupportedGoto:
    # kenbi does not model this goto's control flow (backward / nested / computed).
    # Refusing (rather than silently dropping the jump) keeps soundness: a free reached
    # only via the jump can't slip past as a false GREEN. default-red in covered scope.
    if a.curCovered:
      a.addDiag(s.line, "UNSTRUCTURED_GOTO", unstructuredGotoMsg)
  of ikMaybeFreedResult:
    # `x = f()` where f visibly frees what it returns: a fresh maybe-freed origin — a use is
    # POSSIBLE_USE_AFTER_FREE, a free POSSIBLE_DOUBLE_FREE, never a leak (excluded from the
    # scan: it may indeed be gone). Advisory-strength (the callee declares no contract), like
    # the visibly-frees-its-argument case; the definite bug is f's own DANGLING_RETURN.
    let o = a.nextOrigin
    inc a.nextOrigin
    a.varOrigin[s.keyA] = o
    a.interiorVar[s.keyA] = false
    a.originDecl[o] = s.line
    a.originDisp[o] = s.a
    a.maybeFreedBy[o] = (callee: s.b, line: s.line)
    st[o] = {asOwned, asMaybeFreed}
  of ikRaiiMove:
    # `y = std::move(x)` between owners of the same class: the resource stays in view — y now
    # holds it (aliased to x's origin: a borrow taken from x stays valid, y's destructor
    # releases it) and only the HANDLE x is moved-from. The checks a move must pass are those
    # of ikMove (moving a moved / freed / borrowed / interior handle); the origin's state is
    # untouched, so nothing downstream mistakes the transfer for the resource leaving.
    let o = a.originOf(s.keyA, s.a, s.line)
    if o < 0: return
    if a.handleMoved(s.keyA):
      a.addDiag(s.line, "DOUBLE_MOVE", "double move of '" & s.a & "'")
      return
    if a.interiorVar.getOrDefault(s.keyA, false):
      a.addDiag(s.line, "MOVE_INTERIOR", "cannot move via interior pointer '" & s.a & "'")
      return
    let cur = st.getOrDefault(o)
    if asFreed in cur:
      a.addDiag(s.line, "MOVE_AFTER_FREE", "move of '" & s.a & "' after free")
      return
    if asMoved in cur:
      a.addDiag(s.line, "DOUBLE_MOVE", "double move of '" & s.a & "'")
      return
    if o in a.borrowedOrigins:
      a.addDiag(s.line, "BORROW_MOVED",
        "moves '" & s.a & "' which is only borrowed (a `&` owner parameter / `@borrows`) — the " &
        "caller still owns it, so taking its resource here steals it (the caller releases it too)")
      return
    a.varOrigin[s.keyB] = o
    a.interiorVar[s.keyB] = false
    a.movedHandles[s.keyA] = o
  of ikSetNull:
    # `p = NULL` (or a release declared to return NULL): p owns nothing from here and releasing
    # it is the defined no-op. Per PATH — a branch that nulls it must not silence the release
    # on a sibling branch — so it lives in the null state, which the joins merge. It also stops
    # NAMING whatever it held: returning it is returning NULL, not a dangling pointer, and the
    # origin it left behind is orphaned (dropOrphanedFreed clears it at the join).
    # A release that hands back NULL nulls the handle ON THE PATH THAT RELEASED IT. Record the
    # pairing while the binding is still there: it is what lets a later `return p` tell the
    # NULL-returning error convention from handing out a freed pointer, once the origin's freed
    # state survives a join because some other handle still names it.
    if s.keyA in a.varOrigin and asFreed in st.getOrDefault(a.varOrigin[s.keyA]):
      a.nulledByRelease.incl s.keyA
    nst[s.keyA] = nkNull
    a.varOrigin.del s.keyA
  of ikRebind:
    # The handle was assigned something kenbi cannot place, so it stops naming what it named
    # before. Keeping the old binding was how a linked-list walk turned into an accusation:
    # `cur = cur->next` left `cur` naming the node just freed, and every step after it read as
    # a double free / use-after-free. Dropping it is not silence — the origin, if nothing else
    # names it, is an orphan the exit leak scan still reports, and a release of the rebound
    # handle is UNCONTRACTED_RELEASE: kenbi asking where this pointer came from.
    a.varOrigin.del s.keyA
    a.interiorVar.del s.keyA
    a.movedHandles.del s.keyA
    a.unknownOrigin.incl s.keyA
    a.ambiguousHandles.excl s.keyA
    nst.del s.keyA
    # …and with it every FIELD reached through it (`b->buf` is keyed `<b>::buf`): if the base
    # points at an object kenbi cannot place, the resource it thought the field held is not
    # reachable through this handle either. Without this the base went unknown while its field
    # paths kept bindings from an allocation on some other path, and a later mention of the
    # field read as an unknown variable.
    var fieldKeys: seq[string]
    for k in a.varOrigin.keys:
      if k.startsWith(s.keyA & "::"): fieldKeys.add k
    for k in fieldKeys:
      a.varOrigin.del k
      a.interiorVar.del k
      a.unknownOrigin.incl k
      a.ambiguousHandles.excl k
  of ikLinkRead:
    # `cur = cur->next` along a declared `link:` field. The base's resource must actually
    # declare THIS field — a `next` on some unrelated struct is a read kenbi cannot place, and
    # falls through to the ordinary rebind, so declaring a link never widens what else aliases.
    let bo = a.varOrigin.getOrDefault(s.keyB, -1)
    let declaresLink = bo >= 0 and a.originLink.getOrDefault(bo, "") == s.cKey
    if not declaresLink:
      a.varOrigin.del s.keyA          # same as ikRebind: the target names something unplaceable
      a.interiorVar.del s.keyA
      a.unknownOrigin.incl s.keyA
      a.ambiguousHandles.excl s.keyA
      a.removedHandles.excl s.keyA
      nst.del s.keyA
      return
    if s.keyB in a.removedHandles:
      # `free(cur); cur = cur->next;` — the link is read out of the element just released.
      # The bug this discipline exists to catch, and it is a verdict, not a question.
      a.addDiag(s.line, "USE_AFTER_FREE",
        "reads '" & s.b & "->" & s.cKey & "' after '" & s.b & "' was freed — save the next " &
        "element before releasing this one")
      return
    if asFreed in st.getOrDefault(bo):
      a.addDiag(s.line, "USE_AFTER_FREE",
        "walks '" & s.b & "->" & s.cKey & "' after the collection was drained")
      return
    # another cursor on the same collection
    nst.del s.keyA
    a.varOrigin[s.keyA] = bo
    a.interiorVar[s.keyA] = a.interiorVar.getOrDefault(s.keyB, false)
    a.unknownOrigin.excl s.keyA
    a.ambiguousHandles.excl s.keyA
    a.removedHandles.excl s.keyA
  of ikListDrain:
    # `@drains(head)`: the loop just above released every element of this collection. Verified,
    # not trusted — a loop that released nothing does not drain anything, and a `@drains` on a
    # handle that is not a declared collection is a declaration with no subject.
    let o = a.varOrigin.getOrDefault(s.keyA, -1)
    if o < 0 or o notin a.listOrigins:
      a.addDiag(s.line, "CONTRACT_NOT_HONORED",
        "`@drains(" & s.a & ")` names no intrusive collection: '" & s.a & "' does not hold a " &
        "resource declared with `link:` here. Declare the node resource's link field with " &
        "`@mem … { link: <field> }`, or drop the annotation.")
      return
    if o notin a.listReleased:
      a.addDiag(s.line, "CONTRACT_NOT_HONORED",
        "`@drains(" & s.a & ")` declares that this loop releases every element of the " &
        "collection, but no element is released in it. Release each element (the loop body's " &
        "`" & (a.prog.resources.getOrDefault(a.originRes.getOrDefault(o, "")).freeId) &
        "`), or drop the annotation.")
      return
    st[o] = {asFreed}                 # drained: discharged, and every cursor on it dangles
    for k, v in a.varOrigin:
      if v == o: a.removedHandles.excl k
  of ikReArm:
    # one distinct element per iteration: the slot's origin is owned again at the top of the
    # body. Not a new origin — the release in the body must discharge the element the container
    # was actually holding (else it would leak while a phantom fresh one was freed).
    if s.keyA in a.varOrigin:
      let o = a.varOrigin[s.keyA]
      if o notin a.leakedOrigins: st[o] = {asOwned}
  of ikNonVirtualDelete:
    if a.curCovered:
      if s.off == 1:
        a.addDiag(s.line, "DELETE_NONVIRTUAL_BASE",
          "'" & s.a & "' is deleted through a pointer to '" & s.b & "', but the object is of a " &
          "class derived from it and '" & s.b & "' has no virtual destructor: this is undefined " &
          "behaviour, and the derived destructor — with whatever it releases — never runs. " &
          "Declare '" & s.b & "''s destructor virtual, or delete through the derived type.")
      else:
        a.addDiag(s.line, "DELETE_NONVIRTUAL_BASE",
          "'" & s.a & "' is deleted through a pointer to '" & s.b & "', which other classes derive " &
          "from and which has no virtual destructor. If the object is of a derived class this is " &
          "undefined behaviour and the derived destructor never runs; kenbi cannot see which " &
          "class it is. Declare '" & s.b & "''s destructor virtual, or delete through the type the " &
          "object was created as.")
  of ikUnsupportedConstruct:
    # a construct kenbi does not model that CONTAINS an allocation / release: refuse rather than
    # drop it (a free kenbi cannot see can never be caught as a double free / leak later).
    if a.curCovered:
      a.addDiag(s.line, "UNSUPPORTED_CONSTRUCT",
        "this " & (if s.a.len > 0: s.a else: "construct") & " contains an allocation or a " &
        "release that kenbi does not model, so ownership cannot be tracked through it. Move the " &
        "allocation / release out of it (or mark the line @unsafe if you take responsibility) — " &
        "silently ignoring it could hide a later double-free or leak.")
    # What the construct did to the objects held so far is unknown — it may have released any of
    # them — so none of them is asserted about from here (a LEAK claim on memory the construct
    # freed would be false). The refusal above keeps the function RED.
    for o in toSeq(st.keys):
      if st[o] * {asOwned, asMaybeFreed} != {}:
        st[o] = {asEscaped}
  of ikMayThrow:
    if a.tryFrames.len > 0:
      # inside a `try`: the unwinding exit lands in the handlers — deposit the state on the
      # frame (the handlers start from the join of every such exit); nothing is lost here.
      a.tryFrames[^1].add (st, nst, "")
    else:
      a.scanThrowLeaks(s, st)
  of ikUnaccountedFree:
    if nst.getOrDefault(s.keyA, nkNonNull) == nkNull: return   # free(NULL) does nothing
    # a deallocator called on a pointer whose provenance kenbi cannot account for
    # (an untracked local: assigned from `*outparam`, a non-@owns factory return,
    # etc.). default-red in covered scope — symmetric to UNCONTRACTED_RELEASE on a
    # parameter, but here we don't even know the source. Honest: name it, ask for the
    # declaration. (Uncovered scope: dropped by the gate, like every other finding.)
    if a.curCovered:
      if s.keyA in a.localAddrVars:
        # the pointer holds the address of a function-local / stack object (`p =
        # localArray` / `p = &local`), not a heap allocation — freeing it is undefined
        # (CWE-590, free of non-heap memory). This is a specific, decidable bug, not a
        # generic "cannot account for ownership", so it gets its own diagnosis.
        a.addDiag(s.line, "FREE_NONHEAP",
          "frees '" & s.a & "' which points into stack / non-heap memory; only heap " &
          "allocations (malloc / calloc / realloc / new) may be freed. Allocate the " &
          "buffer on the heap, or do not free this pointer.")
      else:
        a.untrackedRelease(s.line, s.a)
  of ikIncomingPtr:
    # a pointer parameter with no ownership contract: kenbi does not know whether
    # this function owns it. It is usable / passable and never a leak (the caller
    # owns it), but freeing it is UNCONTRACTED_RELEASE (intake-side default-red).
    let o = a.nextOrigin
    inc a.nextOrigin
    a.varOrigin[s.keyA] = o
    a.interiorVar[s.keyA] = false
    a.originDecl[o] = s.line
    a.originDisp[o] = s.a
    a.undeclaredParams.incl o
    st[o] = {asOwned}
  of ikArenaAlloc:
    # dst is allocated from arena <b>: a non-owning, arena-lifetime-bound object.
    let o = a.nextOrigin
    inc a.nextOrigin
    a.varOrigin[s.keyA] = o
    a.interiorVar[s.keyA] = false
    a.originDecl[o] = s.line
    a.originDisp[o] = s.a
    a.borrowedOrigins.incl o    # never a leak; individual free = BORROW_FREED
    a.arenaObjects.incl o
    st[o] = {asOwned}
    if s.keyB in a.varOrigin:    # link to the arena's lifetime
      a.arenaOf[o] = a.varOrigin[s.keyB]
  of ikRaiiAlloc:
    nst.del s.keyA                  # rebound: no longer the null constant
    # a local of an `@raii` class type is constructed: it OWNS a resource that its destructor
    # releases at scope exit. An owned origin — so `std::move` turns it asMoved, a later use is
    # USE_AFTER_MOVE and a second move DOUBLE_MOVE — but never a leak: the dtor frees it, which
    # is exactly the RAII guarantee kenbi is trusting here (declared by `@raii` on the class).
    let o = a.nextOrigin
    inc a.nextOrigin
    a.varOrigin[s.keyA] = o
    a.interiorVar[s.keyA] = false
    a.interiorOff[s.keyA] = 0     # a fresh block: the handle addresses its start
    a.originRes[o] = s.b
    a.originDecl[o] = s.line
    a.originDisp[o] = s.a
    a.raiiOrigins.incl o
    st[o] = {asOwned}
  of ikDeref:
    if a.reallocUnsettled(s.keyA, s.a, s.line, "dereferenced"): return
    case nst.getOrDefault(s.keyA, nkNonNull)
    of nkMaybe:
      a.addDiag(s.line, "NULL_DEREF",
        "dereference of possibly-null '" & s.a & "' (not null-checked)")
    of nkNull:
      # KNOWN null: the defensive `free(p); p = NULL;`, or a release declared to hand back NULL.
      # Dereferencing that is not a risk, it is the bug — and the silence was also what made the
      # fact unusable elsewhere: recording "this branch knows p is null" (which would rule out
      # the inner branches a cleanup macro guards with `if (p != NULL)`) cannot be worth doing
      # while a definite null dereference produces no finding at all.
      a.addDiag(s.line, "NULL_DEREF", "dereference of '" & s.a & "', which is null here")
    of nkNonNull: discard
    # a dereference (`*p` / `p[i]`) is a USE — the same liveness checks as ikUse. Without these,
    # a confirmed use-after-free / use-after-move through a subscript or star-deref was MISSED
    # (only the maybe-freed advisory fired); asFreed / asMoved are the definite cases.
    if s.keyA in a.varOrigin:
      let o = a.varOrigin[s.keyA]
      let cur = st.getOrDefault(o)
      if o in a.conflatedOrigins:
        if asFreed in cur:
          a.addDiag(s.line, "POSSIBLE_USE_AFTER_FREE",
            "'" & s.a & "' may already have been freed: two allocations reach this point " &
            "through one variable, so kenbi cannot tell which object this dereference " &
            "touches. Give each allocation its own handle, or mark this use @unsafe.")
      elif s.keyA in a.removedHandles:
        a.addDiag(s.line, "USE_AFTER_FREE",
          "dereference of '" & s.a & "' after its element was freed")
      elif s.keyA in a.ambiguousHandles:
        # may be this origin, may be an object kenbi cannot place (see the ikFree twin)
        if asFreed in cur:
          a.addDiag(s.line, "POSSIBLE_USE_AFTER_FREE",
            "'" & s.a & "' may already have been freed: it is reassigned on one path and not " &
            "on another, so kenbi cannot tell which object this dereference touches. Give the " &
            "handle one identity (a separate variable per object), or mark this use @unsafe.")
      elif a.handleMoved(s.keyA):
        a.addDiag(s.line, "USE_AFTER_MOVE", "dereference of '" & s.a & "' after move")
      elif asFreed in cur:
        a.addDiag(s.line, "USE_AFTER_FREE", "dereference of '" & s.a & "' after free")
      elif asMoved in cur:
        a.addDiag(s.line, "USE_AFTER_MOVE", "dereference of '" & s.a & "' after move")
      elif a.arenaDead(o, st):
        a.addDiag(s.line, "BORROW_OUTLIVES_OWNER",
          "dereference of '" & s.a & "' after its arena was destroyed")
      elif asMaybeFreed in st.getOrDefault(o):
        let mb = a.maybeFreedBy.getOrDefault(o)
        a.addDiag(s.line, "POSSIBLE_USE_AFTER_FREE",
          "use-after-free risk: '" & s.a & "' may already have been freed by '" &
          mb.callee & "' at line " & $mb.line & " (its body frees it, but it declares no @frees " &
          "contract, so the ownership transfer is unverifiable). Declare @frees there if it takes " &
          "ownership (then this use is a confirmed bug to fix), or @borrows if it does not.")
  of ikAlloc:
    a.staleAfterRealloc.excl s.keyA
    nst.del s.keyA                  # rebound: no longer the null constant
    let o = a.nextOrigin
    inc a.nextOrigin
    a.varOrigin[s.keyA] = o
    a.interiorVar[s.keyA] = false
    a.originRes[o] = s.b
    a.originDecl[o] = s.line
    a.originDisp[o] = s.a       # for messages that name the owner (e.g. a field's container)
    st[o] = {asOwned}
    # a declared `link:` field (on the resource, or on the target's record type) makes this an
    # intrusive COLLECTION: the origin stands for the whole chain, and only a declared
    # `@drains` loop discharges it
    if s.cKey.len > 0:
      a.listOrigins.incl o
      a.originLink[o] = s.cKey
    if s.b notin a.prog.resources:
      # Mandatory discipline: in a covered (`@kenbi`) function every allocation must
      # declare its intent with `@mem` — an un-declared resource is RED (you can't
      # reach GREEN by skipping the "obvious" annotation). Outside covered scope it
      # is only an advisory invitation (and is dropped with the rest anyway).
      if a.curCovered:
        a.addDiag(s.line, "UNKNOWN_RESOURCE",
          "allocation of undeclared resource '" & s.b & "' — declare it with @mem " &
          "(free / owner) so its intent is checkable")
      else:
        a.addDiag(s.line, "UNKNOWN_RESOURCE",
          "resource '" & s.b & "' is not declared with @mem", sevWarning)
  of ikFieldAlloc:
    # a pointer allocated directly into a one-level field path `b->buf`. Tracked
    # for double-free / UAF through the field; excluded from the leak scan (the
    # base struct may escape, carrying the field's free obligation with it).
    a.fieldOverwriteLeak(s.keyA, st)   # `b->buf = malloc()` over a still-owned `b->buf` leaks it
    let o = a.nextOrigin
    inc a.nextOrigin
    a.varOrigin[s.keyA] = o
    a.interiorVar[s.keyA] = false
    a.originRes[o] = s.b
    a.originDecl[o] = s.line
    a.originDisp[o] = s.a
    a.fieldOrigins.incl o
    if s.cKey.len > 0 and s.off == 1: a.fieldBase[o] = s.cKey  # only a function-LOCAL container
    st[o] = {asOwned}
  of ikFieldStore:
    a.baseEscaped.incl s.keyA        # stored into a field: the container carries its own fields
    # `b->buf = p`: the field takes ownership of the tracked pointer `p` (keyA). Re-key its origin
    # to the field path (bKey) so a double-free / use-after-free THROUGH `b->buf` is checked (like
    # a direct `b->buf = malloc`), and add it to fieldOrigins so it is excluded from the leak scan
    # (the base struct carries the obligation — full field lifetime is the deferred #2 work).
    if s.bKey.len > 0:
      a.fieldOverwriteLeak(s.bKey, st)   # `b->buf = p` over a still-owned `b->buf` leaks the old field origin
    if s.keyA in a.varOrigin:
      let o = a.varOrigin[s.keyA]
      a.fieldOrigins.incl o
      if s.cKey.len > 0 and s.off == 1: a.fieldBase[o] = s.cKey  # only a function-LOCAL container
      if s.bKey.len > 0:
        a.varOrigin[s.bKey] = o
        a.interiorVar[s.bKey] = false
  of ikCopy:
    a.staleAfterRealloc.excl s.keyA   # re-bound: `p = tmp` is the reconciliation itself
    nst.del s.keyA                  # rebound: no longer the null constant
    if nst.getOrDefault(s.keyB, nkNonNull) == nkNull:
      nst[s.keyA] = nkNull          # copying a null pointer: the target names nothing either
      a.varOrigin.del s.keyA
      return
    if s.keyB in a.unknownOrigin:
      a.varOrigin.del s.keyA          # the source names something unplaceable: so does the copy
      a.interiorVar.del s.keyA
      a.unknownOrigin.incl s.keyA
      return
    if s.keyB notin a.varOrigin:
      a.addDiag(s.line, "UNKNOWN_VAR", "kenbi has no origin recorded for '" & s.b &
        "' at this point, so nothing is checked here", sevAdvisory)
      return
    a.varOrigin[s.keyA] = a.varOrigin[s.keyB]
    a.interiorVar[s.keyA] = a.interiorVar.getOrDefault(s.keyB, false)
    if s.keyB in nst: nst[s.keyA] = nst[s.keyB]   ## null-ness flows with the alias
    # …and so does an unsettled realloc: a second name for a handle whose block may have moved
    # is exactly as unusable as the first, and copying it must not launder it.
    if s.keyB in a.staleAfterRealloc: a.staleAfterRealloc.incl s.keyA
    if s.keyB in a.reallocTie: a.reallocTie[s.keyA] = a.reallocTie[s.keyB]
  of ikRealloc:
    if s.keyB.len == 0:
      # SELF-reassign `p = realloc(p, n)`: realloc's success model (the result continues the same
      # obligation) hides the OOM failure path — realloc returns NULL and this self-assignment
      # overwrites the ONLY handle to the original block, which then leaks, and no later null-check
      # can recover the lost handle. default-red, and unconditionally so (no `@realloc` vouch can
      # save it — the handle is already gone; only `@unsafe`). The origin is left owned so a
      # following `free(p)` still discharges it and no second finding is raised for the same path.
      if s.keyA in a.varOrigin:
        a.addDiag(s.line, "REALLOC_SELF_REASSIGN",
          "'" & s.a & "' is reallocated into itself (`" & s.a & " = realloc(" & s.a & ", …)`): if " &
          "realloc fails it returns NULL and overwrites the only handle to the original block, which " &
          "then leaks — and no later null-check can recover it (the handle is already gone). Assign " &
          "the result to a temporary and reconcile on success: `tmp = realloc(" & s.a & ", …); if " &
          "(tmp) " & s.a & " = tmp;` (or mark this @unsafe).")
    else:
      # FRESH-dest `q = realloc(p, n)`: alias the result to the source origin (the success-path
      # "continues the obligation" model), so a following free of exactly one handle discharges it
      # and the free-once discipline (leak / double-free) is still verified.
      if a.reallocUnsettled(s.keyB, s.b, s.line, "resized again"): return
      if s.keyB notin a.varOrigin:
        a.addDiag(s.line, "UNKNOWN_VAR", "kenbi has no origin recorded for '" & s.b &
          "' at this point, so nothing is checked here", sevAdvisory)
        return
      a.varOrigin[s.keyA] = a.varOrigin[s.keyB]
      a.interiorVar[s.keyA] = a.interiorVar.getOrDefault(s.keyB, false)
      if s.keyB in nst: nst[s.keyA] = nst[s.keyB]
      a.staleAfterRealloc.excl s.keyA         # the result is a fresh binding
      # ...but the failure path is not settled HERE. realloc returns NULL on OOM, and until this
      # path learns whether it did, which of '`s.b`' and '`s.a`' names the block is open: freeing
      # the result would leak the original, and freeing (or reading) the source would touch a
      # block a successful realloc may have moved. So the pair is TIED, and the tie is settled by
      # the null test the idiom is built around — `if (tmp) p = tmp;` — on both of its branches
      # (see settleRealloc). Touching either handle while tied is REALLOC_UNVERIFIED, reported at
      # the touch rather than at the realloc, so the standard idiom needs no vouch at all. An
      # explicit `@realloc` still vouches for a reconciliation kenbi cannot see.
      if s.line notin a.prog.reallocLines:
        a.reallocTie[s.keyA] = (other: s.keyB, srcDisp: s.b, resDisp: s.a,
                                line: s.line, isResult: true)
        a.reallocTie[s.keyB] = (other: s.keyA, srcDisp: s.b, resDisp: s.a,
                                line: s.line, isResult: false)
        nst[s.keyA] = nkMaybe                 # …and the result may be NULL until checked
  of ikInterior:
    nst.del s.keyA                  # rebound: no longer the null constant
    if nst.getOrDefault(s.keyB, nkNonNull) == nkNull:
      nst[s.keyA] = nkNull
      a.varOrigin.del s.keyA
      return
    if s.keyB notin a.varOrigin:
      a.addDiag(s.line, "UNKNOWN_VAR", "kenbi has no origin recorded for '" & s.b &
        "' at this point, so nothing is checked here", sevAdvisory)
      return
    a.varOrigin[s.keyA] = a.varOrigin[s.keyB]
    a.interiorVar[s.keyA] = true          # may-fact, never cleared: see interiorOff
    if s.keyA == s.keyB:
      # a SELF-advance (`p += k`): fold the step into this path's running offset
      let prev = a.interiorOff.getOrDefault(s.keyA, 0)
      a.interiorOff[s.keyA] = (if prev == offsetUnknown or s.off == offsetUnknown: offsetUnknown
                               else: prev + s.off)
    else:
      # A non-self interior (`q = p.get()`, a field path, `q = p + k`): the handle is interior,
      # but these sites carry no offset — a 0 there means "not given", not "at the start". Only
      # a SELF-advance is folded, so only it can ever acquit the gate.
      a.interiorOff[s.keyA] = offsetUnknown
  of ikLocalAddr:
    # the var now points into a local (stack) object. This is monotonic within
    # the function (a local stays local), so it's tracked outside the flow state.
    a.localAddrVars.incl s.keyA
  of ikUse:
    if a.reallocUnsettled(s.keyA, s.a, s.line, "used"): return
    if nst.getOrDefault(s.keyA, nkNonNull) == nkNull: return   # a null pointer names nothing
    let o = a.originOf(s.keyA, s.a, s.line)
    if o < 0: return
    if s.keyA in a.removedHandles:
      a.addDiag(s.line, "USE_AFTER_FREE", "use of '" & s.a & "' after its element was freed")
      return
    if o in a.conflatedOrigins:
      if asFreed in st.getOrDefault(o):
        a.addDiag(s.line, "POSSIBLE_USE_AFTER_FREE",
          "'" & s.a & "' may already have been freed: two allocations reach this point through " &
          "one variable, so kenbi cannot tell which object this use touches. Give each " &
          "allocation its own handle, or mark this use @unsafe.")
      return
    if s.keyA in a.ambiguousHandles:
      # may be this origin, may be an object kenbi cannot place: a use is a risk to surface,
      # not a verdict to deliver (see the ikFree twin).
      if asFreed in st.getOrDefault(o):
        a.addDiag(s.line, "POSSIBLE_USE_AFTER_FREE",
          "'" & s.a & "' may already have been freed: it is reassigned on one path and not " &
          "on another, so kenbi cannot tell which object this use touches. Give the handle " &
          "one identity (a separate variable per object), or mark this use @unsafe.")
      return
    if a.handleMoved(s.keyA):
      a.addDiag(s.line, "USE_AFTER_MOVE", "use of '" & s.a & "' after move")
      return
    let cur = st.getOrDefault(o)
    if asFreed in cur:
      a.addDiag(s.line, "USE_AFTER_FREE", "use of '" & s.a & "' after free")
    elif asMoved in cur:
      a.addDiag(s.line, "USE_AFTER_MOVE", "use of '" & s.a & "' after move")
    elif a.arenaDead(o, st):
      a.addDiag(s.line, "BORROW_OUTLIVES_OWNER",
        "use of '" & s.a & "' after its arena was destroyed")
    elif asMaybeFreed in st.getOrDefault(o):
      let mb = a.maybeFreedBy.getOrDefault(o)
      a.addDiag(s.line, "POSSIBLE_USE_AFTER_FREE",
        "use-after-free risk of '" & s.a & "': it may already have been freed by '" &
        mb.callee & "' at line " & $mb.line & " (its body frees it, but has no @frees " &
        "contract, so the ownership transfer is unverifiable). Declare @frees there if it takes " &
        "ownership (then this use is a confirmed bug to fix), or @borrows if it does not.")
  of ikEscapeCall, ikEscapeCallFrees:
    if a.reallocUnsettled(s.keyA, s.a, s.line, "passed on"): return
    a.baseEscaped.incl s.keyA        # a container handed to a callee carries its fields
    # An owned pointer passed to an uncontracted callee. First the ordinary use
    # checks (a freed / moved / region-dead pointer is still a bug here)...
    let o = a.originOf(s.keyA, s.a, s.line)
    if o < 0: return
    let cur = st.getOrDefault(o)
    if asFreed in cur:
      a.addDiag(s.line, "USE_AFTER_FREE", "use of '" & s.a & "' after free")
      return
    elif asMoved in cur:
      a.addDiag(s.line, "USE_AFTER_MOVE", "use of '" & s.a & "' after move")
      return
    elif a.arenaDead(o, st):
      a.addDiag(s.line, "BORROW_OUTLIVES_OWNER",
        "use of '" & s.a & "' after its arena was destroyed")
      return
    # ...then the escape check: only a genuinely OWNED resource (a real
    # allocation we still own here) is an uncontracted escape. A borrow / arena
    # object / already-escaped / interior pointer is not (those are someone
    # else's obligation, or already out of view — store-escape of a borrow is the
    # deferred #2 work). default-red: kenbi cannot verify what the callee does.
    let isOwnedResource =
      asOwned in cur and o in a.originRes and
      o notin a.borrowedOrigins and o notin a.arenaObjects and
      asEscaped notin cur and (o notin a.fieldOrigins or o in a.fieldBase) and
      o notin a.contractOrigins and not a.interiorVar.getOrDefault(s.keyA, false)
      # a FIELD origin counts when its container is a function-local (fieldBase): the struct
      # channel `s.buf = data; sink(s)` hands an owned field across the boundary exactly like a
      # plain owned pointer — never a silent hand-off (t187, Juliet 66/67)
    if not isOwnedResource and asMaybeFreed in cur:
      # a possibly-freed value that is no allocation of ours (the result of a function that returns
      # what it freed) handed to an uncontracted callee is a use of it, exactly as at ikUse; without
      # this the hand-off said nothing at all (Juliet 416 `return_freed_ptr`: `printLine(r)`)
      let mb = a.maybeFreedBy.getOrDefault(o)
      a.addDiag(s.line, "POSSIBLE_USE_AFTER_FREE",
        "use-after-free risk of '" & s.a & "': it may already have been freed by '" &
        mb.callee & "' at line " & $mb.line & " (its body frees it, but has no @frees " &
        "contract, so the ownership transfer is unverifiable). Declare @frees there if it takes " &
        "ownership (then this use is a confirmed bug to fix), or @borrows if it does not.")
      return
    if isOwnedResource:
      # Name precisely WHERE / WHAT is missing: the callee, the parameter that
      # receives the owned pointer, and the contract kinds that would resolve it.
      let callee = (if s.b.len > 0: "'" & s.b & "'" else: "an uncontracted function")
      let param =
        if s.bKey.len > 0: "parameter '" & s.bKey & "' of " & callee
        elif s.b.len > 0: "argument " & $(s.off + 1) & " of " & callee
        else: "a parameter of " & callee
      let paramShort =
        if s.bKey.len > 0: "parameter '" & s.bKey & "'"
        elif s.b.len > 0: "argument " & $(s.off + 1)
        else: "that parameter"
      if s.ik == ikEscapeCallFrees:
        # kenbi can SEE the callee frees this arg — but no @frees is declared, so
        # the boundary is still uncontracted (red). Say so precisely, and mark the
        # pointer maybe-freed so a later free / use is a POSSIBLE_* advisory.
        a.addDiag(s.line, "UNCONTRACTED_ESCAPE",
          "'" & s.a & "' is owned here and " & callee & " appears to free " &
          paramShort & " (its body frees it) but declares no @frees contract — " &
          "declare @frees on " & paramShort & " so the ownership transfer is " &
          "explicit and kenbi can confirm any later double-free / use-after-free " &
          "(or @borrows / @moves / @arena / @unsafe).")
        st[o] = st.getOrDefault(o) + {asMaybeFreed}
        a.maybeFreedBy[o] = (s.b, s.line)
      else:
        a.addDiag(s.line, "UNCONTRACTED_ESCAPE",
          "'" & s.a & "' is owned here but " & param & " has no ownership contract, " &
          "so kenbi cannot verify whether " & callee & " frees / borrows / stores it " &
          "— safety is undecidable at this boundary. Declare what " & callee &
          " does with it (@frees / @borrows / @moves on " & paramShort & "); " &
          "or put '" & s.a & "' under an @arena region; or mark this call @unsafe.")
        # The obligation has crossed an unverifiable boundary — stop tracking it so
        # we don't also report a LEAK for it at exit (the escape is the finding; the
        # caller resolves it, after which the declared contract resumes tracking).
        st[o] = (st.getOrDefault(o) - {asOwned}) + {asEscaped}
  of ikFree:
    if a.reallocUnsettled(s.keyA, s.a, s.line, "released"): return
    if nst.getOrDefault(s.keyA, nkNonNull) == nkNull: return   # free(NULL) does nothing
    if s.keyA in a.unknownOrigin:
      # the handle was rebound to something kenbi cannot place, so this release is the
      # default-red question — never a double free of the resource it used to name
      if a.curCovered: a.untrackedRelease(s.line, s.a)
      return
    let o = a.originOf(s.keyA, s.a, s.line)
    if o < 0: return
    if o in a.listOrigins and asFreed notin st.getOrDefault(o):
      # a cursor on an intrusive collection: this releases ONE element, not "the" resource.
      # kenbi cannot count elements, so the collection's own state is unchanged and only a
      # declared `@drains` loop discharges it — but the CURSOR is now dangling, so a second
      # release through it, or any use of it before it is re-bound, is still a verdict.
      if s.keyA in a.removedHandles:
        a.addDiag(s.line, "DOUBLE_FREE",
          "double free of '" & s.a & "': this element was already released and '" & s.a &
          "' has not moved to the next one")
      else:
        a.removedHandles.incl s.keyA
        a.listReleased.incl o
      return
    if o in a.conflatedOrigins:
      # this origin is kenbi's merge of two distinct allocations (see joinBindings): releasing
      # it discharges the merge, but which of the two objects this call frees is not something
      # kenbi knows, so a second release is a may-fact rather than a verdict
      if asFreed in st.getOrDefault(o):
        a.addDiag(s.line, "POSSIBLE_DOUBLE_FREE",
          "'" & s.a & "' may already have been freed: two allocations reach this point through " &
          "one variable, so kenbi cannot tell which object this release frees. Give each " &
          "allocation its own handle, or mark this release @unsafe.")
      st[o] = {asFreed}        # the merge is discharged: each object was released once
      return
    if s.keyA in a.ambiguousHandles:
      # one path rebound this handle, another did not: it MAY be this origin. Releasing it
      # discharges the origin — on the path that still holds the resource this is its release,
      # and calling it a leak would be a phantom — but no verdict is delivered THROUGH it: a
      # release of something already freed is POSSIBLE_DOUBLE_FREE, the default-red form.
      if asFreed in st.getOrDefault(o):
        a.addDiag(s.line, "POSSIBLE_DOUBLE_FREE",
          "'" & s.a & "' may already have been freed: it is reassigned on one path and not " &
          "on another, so kenbi cannot tell which object this release frees. Give the handle " &
          "one identity (a separate variable per object, or release it before reassigning), " &
          "or mark this release @unsafe.")
      st[o] = {asFreed}
      return
    if a.handleMoved(s.keyA):
      a.addDiag(s.line, "FREE_AFTER_MOVE", "free of '" & s.a & "' after move")
      return
    if o in a.adoptedOrigins:
      a.addDiag(s.line, "DOUBLE_FREE",
        "double free of '" & s.a & "': it was handed to a consumer that took over its release " &
        "(a declared `@adopts`), so releasing it here frees it a second time")
      return
    if a.interiorVar.getOrDefault(s.keyA, false) and
       a.interiorOff.getOrDefault(s.keyA, offsetUnknown) != 0:
      a.addDiag(s.line, "FREE_INTERIOR",
        "cannot free interior pointer '" & s.a & "' (free the owner)")
      return
    if o in a.undeclaredParams:
      # Intake-side default-red, symmetric to UNCONTRACTED_ESCAPE on the call side:
      # this function frees a pointer parameter it never declared it owns, so kenbi
      # cannot verify the release is sound (the caller may also free it; or it may be
      # a borrow the owner frees). Constructive menu: declare the intake.
      let cur = st.getOrDefault(o)
      if asFreed in cur:
        a.addDiag(s.line, "DOUBLE_FREE", "double free of '" & s.a & "'")
      else:
        a.addDiag(s.line, "UNCONTRACTED_RELEASE",
          "'" & s.a & "' is a pointer parameter freed here, but this function does not " &
          "declare it owns '" & s.a & "' — kenbi cannot verify the release is sound " &
          "(the caller may free it too, or '" & s.a & "' may be borrowed). Declare the " &
          "intake contract: @frees(" & s.a & ") if this function takes ownership and " &
          "releases it; or @borrows(" & s.a & ") if the caller owns it (then this free " &
          "is a BORROW_FREED bug to fix); or @moves(" & s.a & "); or mark this release @unsafe.")
      st[o] = {asFreed}
      return
    if o in a.borrowedOrigins:
      if o in a.arenaObjects:
        a.addDiag(s.line, "BORROW_FREED",
          "frees arena-managed '" & s.a & "' individually — its arena owns it (free the arena)")
      else:
        a.addDiag(s.line, "BORROW_FREED",
          "frees '" & s.a & "' which is only borrowed (`@borrows`); the owner frees it")
      return
    # annotation consistency: the deallocator used (s.b) must match the one the
    # resource declares (checked, not trusted). Empty either side => no claim.
    let res = a.originRes.getOrDefault(o, "")
    if res in a.prog.resources:
      # Every release the resource DECLARES is accepted — a family has as many entry points as
      # it declares (`free_returns_null: RelinquishMagickMemory DestroyKernelInfo`), and
      # comparing against only the first made every other name on its own list wrong.
      let accepted = a.prog.resources[res].freeIds
      if accepted.len > 0 and s.b.len > 0 and s.b notin accepted:
        a.addDiag(s.line, "WRONG_DEALLOCATOR",
          "'" & s.a & "' freed with '" & s.b & "' but '" & res &
          "' declares free: " & accepted.join(" / "))
    let cur = st.getOrDefault(o)
    if asFreed in cur:
      a.addDiag(s.line, "DOUBLE_FREE", "double free of '" & s.a & "'")
    elif asMoved in cur:
      a.addDiag(s.line, "FREE_AFTER_MOVE", "free of '" & s.a & "' after move")
    elif asMaybeFreed in st.getOrDefault(o):
      # an uncontracted callee whose visible body frees this pointer was called earlier — so
      # this free MAY be a double free. Default-red (declare-don't-infer): the callee declares
      # no @frees contract, so the ownership transfer is unverifiable and kenbi will not guess
      # the intent. Declaring @frees turns it into a confident DOUBLE_FREE (or @borrows clears it).
      let mb = a.maybeFreedBy.getOrDefault(o)
      a.addDiag(s.line, "POSSIBLE_DOUBLE_FREE",
        "double-free risk of '" & s.a & "': it may already have been freed by '" &
        mb.callee & "' at line " & $mb.line & " (its body frees it, but has no @frees " &
        "contract, so the ownership transfer is unverifiable). Declare @frees there if it takes " &
        "ownership (then this free is a confirmed double free to fix), or @borrows if it does not.")
    st[o] = {asFreed}
    if asFreed notin cur and asMoved notin cur:
      # First clean release of the container: freeing `b` orphans any field `b->…` that
      # still owns a resource (after this the field is inaccessible). On a double-free /
      # free-after-move path the orphaning was already accounted at the real free.
      a.freeBaseOrphansFields(s.keyA, s.a, st, s.b)
  of ikMove:
    if nst.getOrDefault(s.keyA, nkNonNull) == nkNull: return   # a null pointer names nothing
    let o = a.originOf(s.keyA, s.a, s.line)
    if o < 0: return
    if a.handleMoved(s.keyA):
      a.addDiag(s.line, "DOUBLE_MOVE", "double move of '" & s.a & "'")
      return
    if a.interiorVar.getOrDefault(s.keyA, false):
      a.addDiag(s.line, "MOVE_INTERIOR",
        "cannot move via interior pointer '" & s.a & "'")
      return
    if o in a.undeclaredParams:
      # Intake-side default-red, symmetric to UNCONTRACTED_RELEASE on ikFree: this function
      # hands a pointer parameter it never declared it owns to a `@moves` sink. kenbi cannot
      # verify the transfer is sound (the caller may still free it, or it may be a borrow).
      let cur = st.getOrDefault(o)
      if asMoved in cur:
        a.addDiag(s.line, "DOUBLE_MOVE", "double move of '" & s.a & "'")
      else:
        a.addDiag(s.line, "UNCONTRACTED_MOVE",
          "'" & s.a & "' is a pointer parameter moved here (handed to a `@moves` sink), but " &
          "this function does not declare it owns '" & s.a & "' — kenbi cannot verify the " &
          "transfer is sound (the caller may still free it, or '" & s.a & "' may be borrowed). " &
          "Declare the intake contract: @frees(" & s.a & ") if this function takes ownership and " &
          "discharges it (by freeing it, or by handing it to a consumer as here); or @borrows(" &
          s.a & ") if the caller owns it (then this move is a BORROW_MOVED bug to fix); or mark " &
          "this move @unsafe.")
      st[o] = {asMoved}
      return
    let cur = st.getOrDefault(o)
    if asFreed in cur:
      a.addDiag(s.line, "MOVE_AFTER_FREE", "move of '" & s.a & "' after free")
    elif asMoved in cur:
      a.addDiag(s.line, "DOUBLE_MOVE", "double move of '" & s.a & "'")
    elif a.arenaDead(o, st):
      # moving a pointer into a destroyed arena: the region is freed, so the value handed
      # to the `@moves` sink dangles. A move reads its operand — the same use-after-region-
      # free that ikUse/ikDeref catch, completing the arenaDead ladder across every handler
      # that consumes an origin.
      a.addDiag(s.line, "BORROW_OUTLIVES_OWNER",
        "move of '" & s.a & "' after its arena was destroyed")
    elif o in a.borrowedOrigins:
      # moving a borrowed pointer to a `@moves` sink hands away ownership we do not have:
      # the sink now believes it owns the value (and will release it), while the real owner
      # still frees it — a double free. Symmetric to BORROW_FREED on the free side. The
      # borrow's state is unchanged (early return): the true owner keeps its obligation, so a
      # later BORROW_FREED / leak on the owner side is still reported. (An alive arena object
      # is borrowed too — its individual transfer is likewise illegal; the arena owns it.)
      if o in a.arenaObjects:
        a.addDiag(s.line, "BORROW_MOVED",
          "moves arena-managed '" & s.a & "' individually — its arena owns it; region memory " &
          "cannot be handed to a `@moves` sink (which would release it)")
      else:
        a.addDiag(s.line, "BORROW_MOVED",
          "moves '" & s.a & "' which is only borrowed (`@borrows`) — the owner still holds it, " &
          "so handing ownership to a `@moves` sink risks a double free (the owner frees it too)")
      return
    elif asMaybeFreed in st.getOrDefault(o):
      # an uncontracted callee whose visible body frees this pointer ran earlier — moving it to a
      # `@moves` sink now hands a possibly-already-freed value on. Default-red advisory (the callee
      # declares no @frees, so the transfer is unverifiable), matching ikUse / ikDeref.
      let mb = a.maybeFreedBy.getOrDefault(o)
      a.addDiag(s.line, "POSSIBLE_USE_AFTER_FREE",
        "use-after-free risk: '" & s.a & "' may already have been freed by '" &
        mb.callee & "' at line " & $mb.line & " (its body frees it, but declares no @frees " &
        "contract, so the ownership transfer is unverifiable) — moving it now hands a possibly-" &
        "freed pointer to the sink. Declare @frees there if it takes ownership (then this is a " &
        "confirmed bug to fix), or @borrows if it does not.")
    st[o] = {asMoved}
  of ikAdopt:
    # A declared consumer TAKES OVER the release obligation while the object stays valid: the
    # container hand-off (`AppendValueToLinkedList(list, value)`), where the collection frees the
    # element when it is destroyed. Three things follow, and no existing contract gives all
    # three: the value is not a leak here (the consumer owes the release), it is still readable
    # (putting a pointer in a list does not invalidate it — which is why `@moves` is the wrong
    # word, and `@frees` wronger still), and releasing it in this function is now a double free.
    if nst.getOrDefault(s.keyA, nkNonNull) == nkNull: return   # a null pointer names nothing
    let o = a.originOf(s.keyA, s.a, s.line)
    if o < 0: return
    let cur = st.getOrDefault(o)
    if asFreed in cur:
      a.addDiag(s.line, "USE_AFTER_FREE",
        "'" & s.a & "' is handed to a consumer that takes over its release, but it has already " &
        "been freed here")
      return
    if o in a.adoptedOrigins:
      a.addDiag(s.line, "DOUBLE_FREE",
        "'" & s.a & "' is handed to a second consumer that also takes over its release — two " &
        "owners will each free it")
      return
    if o in a.borrowedOrigins:
      a.addDiag(s.line, "BORROW_MOVED",
        "hands '" & s.a & "' to a consumer that takes over its release, but this function only " &
        "borrows it (`@borrows`) — the real owner frees it too")
      return
    if o in a.undeclaredParams:
      # Intake-side default-red, symmetric to ikFree / ikMove: this function hands a pointer
      # parameter it never declared it owns to a consumer that will release it.
      a.addDiag(s.line, "UNCONTRACTED_MOVE",
        "'" & s.a & "' is a pointer parameter handed here to a consumer that takes over its " &
        "release, but this function does not declare it owns '" & s.a & "' — kenbi cannot " &
        "verify the transfer is sound (the caller may free it too). Declare the intake " &
        "contract: @frees(" & s.a & ") if this function takes ownership and discharges it (by " &
        "handing it on as here); or @borrows(" & s.a & ") if the caller owns it (then this is a " &
        "bug to fix); or mark this @unsafe.")
      a.adoptedOrigins.incl o
      st[o] = (st.getOrDefault(o) - {asOwned}) + {asEscaped}
      return
    a.adoptedOrigins.incl o
    a.baseEscaped.incl s.keyA          # the container carries its own fields with it
    st[o] = (st.getOrDefault(o) - {asOwned}) + {asEscaped}

proc fieldExitLeak(a: var Analyzer, o: int, st: StateMap) =
  ## A field origin (`b->buf`) still owned at an exit. Field origins are not leak-scanned
  ## as ordinary locals because the container may carry the obligation away; this decides
  ## the one case where it demonstrably does NOT — a function-LOCAL container that keeps the
  ## obligation in scope — and leaks the field then. Everything else defers (sound default):
  ##  - unknown base, or a base with no tracked origin (a parameter — the caller's struct —
  ##    or a stack-value struct, not modelled in this slice) -> defer;
  ##  - a base whose origin is no longer owned here (returned / moved to a sink / freed /
  ##    escaped) -> the container left, carrying the field with it -> defer.
  ## Two local-container kinds leak their field: a heap-local container itself still owned here
  ## (it is leaking too), or a stack-VALUE local that simply dies at scope exit. Everything the
  ## container did to carry the obligation away is default-red-honest: a whole-struct `return b`
  ## is a self-evident transfer (recorded in baseEscaped) and defers; any OTHER unrecognised
  ## container escape is NOT assumed — its still-owned field leaks (declare the transfer / mark
  ## @unsafe). Provable-orphan + declared-resource gating is shared with the store / free cases via
  ## fieldOrphanLeak; the dropped handles are the base's field keys, so an out-of-struct alias
  ## (`p = b->buf`) still defers.
  let baseKey = a.fieldBase.getOrDefault(o, "")
  if baseKey.len == 0: return                    # non-local / parameter container -> defer
  if baseKey in a.baseEscaped: return            # container transferred whole (`return b`)
  var baseDisp: string
  if baseKey in a.varOrigin:
    # heap-local container: leak the field only when the container is itself still owned here
    # (not returned / moved / freed — those carried or released it).
    if st.getOrDefault(a.varOrigin[baseKey]) != {asOwned}: return
    baseDisp = a.originDisp.getOrDefault(a.varOrigin[baseKey], "?")
  else:
    # A local POINTER with no tracked origin points at an object kenbi cannot place — a tree
    # node, a pool entry, something a caller owns. Only the HANDLE dies at scope exit; the
    # object it points into outlives the frame, and what happens to the field is its owner's
    # business. Defer, exactly as for a pointer PARAMETER container (which returns above with
    # an empty base). Calling it a leak was reading `n = tree->root; n->buf = acquire()` as if
    # `n` were the object.
    if baseKey in a.prog.localPtrVars: return
    # stack-value local container: no heap origin, it dies at scope exit. Derive its display
    # from the field path (`b->buf` -> `b`).
    let fd = a.originDisp.getOrDefault(o, "")
    let arrow = fd.find("->")
    baseDisp = if arrow > 0: fd[0 ..< arrow] else: baseKey
  # At function EXIT every local handle dies — the base's field paths AND any out-of-struct
  # alias (`p` of `s.buf = p`) — so no alias could still free the field afterwards: every key
  # counts as dropped. (A container that escaped, or was returned / freed, was handled above.)
  var dropped: HashSet[string]
  for k in a.varOrigin.keys: dropped.incl k
  a.fieldOrphanLeak(o, st, dropped,
    "when its container '" & baseDisp &
    "' goes out of scope still owning it — free the field before the container is lost")

proc scanLeaks(a: var Analyzer, st: StateMap) =
  ## Report every origin still Owned (neither freed nor transferred) at an exit
  ## point: a leak, or — for a `@frees` contract origin — CONTRACT_NOT_HONORED.
  ## Borrowed origins are owned elsewhere and never leak. This runs at EVERY exit
  ## (each `return` and the fall-through end), so an early return that abandons an
  ## obligation is caught, not just one at function end. Deduped per origin
  ## (reported once, at its declaration line) so multiple exits don't double-report.
  for o in 0 ..< a.nextOrigin:
    if o in st and asOwned in st[o] and o notin a.leakedOrigins:
      if o in a.borrowedOrigins or
         asMaybeFreed in st[o] or o in a.undeclaredParams or o in a.raiiOrigins:
        discard
      elif o in a.fieldOrigins:
        a.fieldExitLeak(o, st)
      elif o in a.contractOrigins:
        a.leakedOrigins.incl o
        a.addDiag(a.originDecl[o], "CONTRACT_NOT_HONORED",
          "'" & a.originDisp.getOrDefault(o, "?") & "' is declared `@frees` but is not freed")
      elif a.hasFinally and not a.passedFinally:
        # opt-in single-funnel discipline: this path exits still owning the resource WITHOUT
        # routing through the declared `@goto_finally` cleanup — a bypass, not a bare leak.
        # The fix is to funnel the release (`goto <funnel>`), so say that precisely.
        a.leakedOrigins.incl o
        a.addDiag(a.originDecl[o], "FINALLY_BYPASSED",
          "'" & a.originRes.getOrDefault(o, "?") & "' is owned here but this path exits without " &
          "routing through the declared cleanup funnel '" & a.finallyName & "' — `goto " &
          a.finallyName & "` so the release happens at the funnel (declared `@goto_finally`).")
      else:
        a.leakedOrigins.incl o
        # Only a DECLARED resource can be a definite leak. If its ownership is undeclared
        # (a plain malloc with no `@mem`), the allocation site already emitted
        # UNKNOWN_RESOURCE ("declare it") — kenbi does NOT also assert LEAK: with the
        # ownership model undeclared, whether this must be freed HERE is unknown, so a
        # "definite leak" would be a false accusation on top of the honest refusal. Once
        # declared (`@mem`), the leak scan verifies it. (Every LEAK test declares its
        # resource, so this suppresses only the double-report, not real detection.)
        let resName = a.originRes.getOrDefault(o, "")
        if resName in a.prog.resources:
          a.addDiag(a.originDecl[o], "LEAK",
            "leak: '" & resName & "' allocated here is never freed or moved")

proc checkReturn(a: var Analyzer, s: Stmt, st: var StateMap, nst: NullState) =
  ## A `return <var>` leaves the function carrying that pointer. Two escape bugs
  ## are decidable here (low-FP): returning a pointer into a local (the value
  ## won't outlive the call), and returning a freed pointer. Otherwise, an owned
  ## pointer returned is *transferred* to the caller — discharge its obligation
  ## so the end-of-scope leak scan doesn't mistake the transfer for a leak.
  let key = s.keyA
  if key.len == 0: return                 # bare `return;` / `return <expr>` with no named var
  # returning a pointer KNOWN to be null is not handing out a dangling one — it is the
  # error convention (`p = release(p); return p;`), and the release already discharged it
  if nst.getOrDefault(key, nkNonNull) == nkNull: return
  if key in a.localAddrVars:
    a.addDiag(s.line, "DANGLING_RETURN",
      "returns '" & s.a & "', a pointer into a local that does not outlive the return")
    return
  if key in a.varOrigin:
    if a.handleMoved(key):
      a.addDiag(s.line, "DANGLING_RETURN",
        "returns '" & s.a & "' after its ownership was moved away (dangling pointer)")
      return
    let o = a.varOrigin[key]
    let cur = st.getOrDefault(o)
    if asFreed in cur and key notin a.nulledByRelease:
      a.addDiag(s.line, "DANGLING_RETURN",
        "returns '" & s.a & "' after it has been freed (dangling pointer)")
    elif asFreed in cur:
      # The freed component comes from the path where a NULL-returning release nulled this very
      # handle (`if (c) p = destroy(p); return p;`), so on that path the return hands back NULL.
      # Any path that did not release it still owns the block, and returning it transfers that.
      if asOwned in cur: st[o] = {asMoved}
    elif asMoved in cur:
      # returning a moved-out pointer: its ownership was already handed to a `@moves`
      # sink, so the returned handle dangles (the receiver, not the caller, owns it). A
      # return is a USE — the same use-after-move that ikUse/ikDeref catch, here at the
      # exit. (May-set: flagged if ANY merged path moved it — a conditionally-dangling
      # return is still a bug.)
      a.addDiag(s.line, "DANGLING_RETURN",
        "returns '" & s.a & "' after its ownership was moved away (dangling pointer)")
    elif a.arenaDead(o, st):
      # returning a pointer into a destroyed arena: the region it points into is freed,
      # so the caller receives a dangling reference. Same use-after-region-free that
      # ikUse/ikDeref catch — a return is a use too. Checked BEFORE the asOwned transfer
      # because an arena object stays asOwned (its death is tracked via its arena's state).
      a.addDiag(s.line, "BORROW_OUTLIVES_OWNER",
        "returns '" & s.a & "' after its arena was destroyed (dangling into a freed region)")
    elif asMaybeFreed in st.getOrDefault(o):
      # an uncontracted callee whose visible body frees this pointer ran earlier — returning it
      # hands the caller a possibly-already-freed value. Default-red advisory (unverifiable
      # transfer), matching ikUse / ikDeref. The obligation still transfers out (it may be owned).
      let mb = a.maybeFreedBy.getOrDefault(o)
      a.addDiag(s.line, "POSSIBLE_USE_AFTER_FREE",
        "use-after-free risk: returns '" & s.a & "' which may already have been freed by '" &
        mb.callee & "' at line " & $mb.line & " (its body frees it, but declares no @frees " &
        "contract, so the transfer is unverifiable). Declare @frees there if it takes ownership " &
        "(then this is a confirmed bug to fix), or @borrows if it does not.")
      if asOwned in cur: st[o] = {asMoved}
    elif asOwned in cur:
      st[o] = {asMoved}                   # ownership transfers out to the caller

proc dischargeNull(a: Analyzer, key: string, st: var StateMap) =
  ## On the branch where `key` is known null, a null pointer carries no free
  ## obligation — drop its owned state so it is not a false leak. Handles the very
  ## common allocation-failure pattern `p = malloc(); if (!p) return;`, where the
  ## null path returns with p owned-but-null (which is not a leak).
  ##
  ## The exception is the RESULT of an unreconciled realloc: it being null is exactly the OOM
  ## path on which the original block is still there, held by the source handle. Dropping the
  ## owned state there would lose the block — `settleRealloc` hands it back to the source.
  if key in a.reallocTie and a.reallocTie[key].isResult: return
  if key in a.varOrigin:
    let o = a.varOrigin[key]
    if o in st and asOwned in st[o]: st[o] = {}
  # …and so do the SLOTS hanging off it. A `@frees(n.name)` contract seeds an obligation on
  # `n`'s field; on the branch where `n` itself is null there is no field either, so the
  # obligation is discharged by the same fact. Without this the null guard every recursive
  # destructor opens with — `if (n == NULL) return;` — reported CONTRACT_NOT_HONORED for each
  # field the destructor honestly releases further down.
  let prefix = key & "::"
  for k, o in a.varOrigin:
    if k.startsWith(prefix) and o in st and asOwned in st[o]: st[o] = {}

proc dropOrphanedFreed(st: var StateMap, vo: Table[string, int]) =
  ## Remove origins that are FREED and that no live handle names any more. Such an origin can
  ## neither be used nor released again — nothing refers to it — so carrying its freed state
  ## into a join only invents hazards. The common shape is a buffer REPLACED inside a loop
  ## (`new = dup(old); free(old); old = new; p = old + k;`): the old origin is freed and
  ## unreferenced at the body exit, but merging it into the loop head made the (rebound)
  ## aliases look like uses of freed memory on the next iteration. An OWNED orphan is a leak
  ## and stays — that is the leak scan's business.
  var live: HashSet[int]
  for _, o in vo: live.incl o
  var drop: seq[int]
  for o, s in st:
    if o notin live and asOwned notin s and asFreed in s: drop.add o
  for o in drop: st.del o

proc joinBindings(a: var Analyzer, st: var StateMap,
                  other: Table[string, int], otherInterior: Table[string, bool],
                  otherOff: Table[string, int],
                  otherUnknown, otherAmbiguous: HashSet[string],
                  otherTie: Table[string, tuple[other: string, srcDisp: string, resDisp: string, line: int, isResult: bool]] = initTable[string, tuple[other: string, srcDisp: string, resDisp: string, line: int, isResult: bool]](),
                  otherStale: HashSet[string] = initHashSet[string]()) =
  ## Reconcile the variable -> origin bindings of another path (`other`) into the current
  ## ones at a join. A variable bound to DIFFERENT origins on the two paths keeps the current
  ## binding, whose origin takes on the other origin's states too (a state possible on either
  ## path is possible after the join — a use is a may-UAF, a free a may-double-free). When
  ## the two origins are of the same kind they are UNIFIED: every handle of the other origin
  ## now names the current one and the other is gone — one `free(data)` after the join
  ## releases "whatever data is", never a phantom leak. Origins of different kinds (a borrow
  ## vs an owner) stay separate (sound: a false leak at worst). A variable bound on the other
  ## path only keeps that binding.
  var unify = initTable[int, int]()
  # INTERIOR-ness merges as a MAY-fact: a handle advanced off the start of its block on EITHER
  # incoming path is interior after the join, because the path that advanced it is one the
  # program can take. Letting the current path's value win instead lost the whole THEN branch —
  # `if (c) p += 8;  free(p);` was silent, a false GREEN in the FREE_INTERIOR class. Done for
  # every handle the other path knows, not only the ones it alone binds.
  for k, iv in otherInterior:
    if iv: a.interiorVar[k] = true
  # The OFFSET merges by the flat lattice: the same constant on both incoming paths survives,
  # anything else is unknown. `if (c) p += 8; else p -= 8;` is +8 on one path and -8 on the
  # other, so the far side knows only that the handle is somewhere — not that it is back at the
  # start, which a running total kept outside the join would wrongly conclude.
  for k in toSeq(a.interiorOff.keys) & toSeq(otherOff.keys):
    let mine = a.interiorOff.getOrDefault(k, offsetUnknown)
    let theirs = otherOff.getOrDefault(k, offsetUnknown)
    a.interiorOff[k] = (if mine == theirs: mine else: offsetUnknown)
  # An unreconciled realloc, and a handle a successful realloc invalidated, are MAY-facts: if
  # either holds on one incoming path it holds after the join, because that path is one the
  # program can take. The canonical idiom settles BOTH branches (one learns the result is
  # non-null and re-binds, the other learns it is null), so nothing survives the join there.
  for k, v in otherTie:
    if k notin a.reallocTie: a.reallocTie[k] = v
  for k in otherStale: a.staleAfterRealloc.incl k
  for k, o1 in other:
    if k notin a.varOrigin:
      a.varOrigin[k] = o1
      if not a.interiorVar.getOrDefault(k, false):
        a.interiorVar[k] = otherInterior.getOrDefault(k, false)
    elif a.varOrigin[k] != o1 and o1 in st:
      let o2 = a.varOrigin[k]
      st[o2] = st.getOrDefault(o2) + st[o1]
      if a.sameOriginKind(o1, o2):
        unify[o1] = o2
        # Folding two allocations into one is an APPROXIMATION, and it is only invisible while
        # `k` is the sole handle on them. When another live handle still tells them apart —
        # `scanline = x_vector;` then `if (…) scanline = malloc(…);`, with `x_vector` naming the
        # first buffer throughout — the merged origin stands for two objects the program keeps
        # distinct, and freeing each of them once read as a double free of the merge. Record it:
        # verdicts through such an origin are may-facts (POSSIBLE_*), never accusations.
        for kk, oo in a.varOrigin:
          if kk != k and oo == o2: a.conflatedOrigins.incl o2
        for kk, oo in other:
          if kk != k and oo == o1: a.conflatedOrigins.incl o2
  if unify.len > 0:
    for kk, oo in a.varOrigin:
      if oo in unify: a.varOrigin[kk] = unify[oo]
    for o1 in unify.keys: st.del o1
  # A handle REBOUND on one path (`cur = cur->next`) and left alone on another is AMBIGUOUS
  # after the join: it may still be the origin the other path bound, and it may be an object
  # kenbi cannot place. Keeping the binding alone turned a list walk into a double-free
  # accusation; dropping it alone made the release on the path that DOES hold the resource
  # unaccountable and the resource a phantom leak. So the binding stays — a release through it
  # still discharges the origin — and the handle is marked ambiguous, which downgrades every
  # verdict made through it to a POSSIBLE_*. Unknown on BOTH paths stays unknown.
  for k in otherAmbiguous: a.ambiguousHandles.incl k
  for k in otherUnknown:
    if k in a.varOrigin:
      a.ambiguousHandles.incl k          # bound here, rebound there
    else:
      a.unknownOrigin.incl k
  var nowAmbiguous: seq[string]
  for k in a.unknownOrigin:
    if k in other: nowAmbiguous.add k    # rebound here, bound there
  for k in nowAmbiguous:
    a.unknownOrigin.excl k
    a.ambiguousHandles.incl k
    a.varOrigin[k] = other[k]
    a.interiorVar[k] = otherInterior.getOrDefault(k, false)
  for k in a.unknownOrigin:              # unknown on both paths: nothing to name
    a.varOrigin.del k
    a.interiorVar.del k

proc analyzeBody(a: var Analyzer, body: seq[Stmt], st: var StateMap,
                 nst: var NullState): bool =
  ## Returns true if control definitely leaves the function at the end of this body
  ## (no fall-through), so the caller can drop a diverged branch from joins.
  ##
  ## `gone` tracks whether the current straight-line path has left (a return or a
  ## forward goto). Unlike a plain early-return, we KEEP iterating while `gone`: a
  ## later top-level label is a join point that a forward goto may re-enter, so the
  ## cleanup-ladder code after a success-path `return` must still be analysed. A
  ## `gone` non-label statement is unreachable by fall-through and skipped.
  var gone = false
  for s in body:
    if s.kind == stLabel:
      # a `@goto_noreturn` label is a terminus (abort/exit/longjmp): any path reaching it
      # leaves the program, so its still-owned obligations are discharged (not leaked) and
      # the rest is unreachable. Drop the path without a leak scan.
      if s.labelName in a.prog.noreturnLabels:
        gone = true
        continue
      if s.labelName in a.prog.finallyLabels:
        a.passedFinally = true   # entering the cleanup funnel: exits past here are legit
      # join point. Merge every incoming edge: the fall-through (unless this path is
      # already gone) plus every forward-goto state deposited for this label.
      if a.gotoMode:
        var incoming: seq[LabelDeposit]
        if not gone: incoming.add (st, nst, a.reallocTie, a.staleAfterRealloc)
        if s.labelName in a.pendingLabels:
          for p in a.pendingLabels[s.labelName]: incoming.add p
          a.pendingLabels.del s.labelName
        if incoming.len > 0:
          var mst = incoming[0].st
          var mnst = incoming[0].nst
          for i in 1 ..< incoming.len:
            mergeStateInto(mst, incoming[i].st)
            mergeNullInto(mnst, incoming[i].nst)
          st = mst; nst = mnst; gone = false
          # an unsettled realloc, and the staleness a settled one leaves behind, are may-facts
          # here exactly as at an if-join: true on any incoming edge, true after it
          for inc in incoming:
            for k, v in inc.tie:
              if k notin a.reallocTie: a.reallocTie[k] = v
            for k in inc.stale: a.staleAfterRealloc.incl k
        # incoming.len == 0: a label nothing reaches (dead) — stay gone.
      # not gotoMode: the label is inert; its body was lowered inline after it.
      continue
    if gone: continue              # unreachable straight-line statement
    case s.kind
    of stLabel: discard            # handled above
    of stInstr:
      if s.ik == ikReturn:
        a.checkReturn(s, st, nst)  # discharge a returned (transferred) obligation first
        a.scanLeaks(st)          # then any OTHER obligation abandoned at this exit leaks
        gone = true              # keep iterating: a forward goto may re-enter a later label
      elif s.ik == ikThrow:
        # `throw`: inside a `try` the state lands in the handlers (deposited on the frame);
        # else it is a function exit carrying nothing — a raw owner still held leaks.
        if a.tryFrames.len > 0: a.tryFrames[^1].add (st, nst, s.b)   # b = the thrown type
        else: a.scanLeaks(st)
        gone = true
      elif s.ik == ikBreak:
        a.breakStates.add (st, nst, a.varOrigin, a.interiorVar, a.interiorOff, a.unknownOrigin, a.ambiguousHandles, a.reallocTie, a.staleAfterRealloc)  # routed to the loop/switch exit join
        gone = true
      elif s.ik == ikContinue:
        a.continueStates.add (st, nst, a.varOrigin, a.interiorVar, a.interiorOff, a.unknownOrigin, a.ambiguousHandles, a.reallocTie, a.staleAfterRealloc) # routed to the loop back edge
        gone = true
      elif s.ik == ikGoto:
        if s.a in a.prog.noreturnLabels:
          # jump to a terminus: the path leaves the program here — no deposit, no leak.
          gone = true
        elif a.gotoMode and cast[int](s) in a.modelledGotos:
          # deposit the current state at the target's join bucket; this path leaves here.
          if s.a in a.pendingLabels:
            a.pendingLabels[s.a].add (st, nst, a.reallocTie, a.staleAfterRealloc)
          else: a.pendingLabels[s.a] = @[(st, nst, a.reallocTie, a.staleAfterRealloc)]
          gone = true
        elif a.curCovered:
          a.addDiag(s.line, "UNSTRUCTURED_GOTO", unstructuredGotoMsg)
      else:
        a.applyInstr(s, st, nst)
    of stIf:
      # CORRELATED BRANCHES: if this path already knows the truth of the stable scalar this
      # condition tests, only one branch can be reached from here — analyse that one alone. The
      # pruned branch is a path the program cannot take, so nothing checkable is lost, and
      # keeping it cost real findings: `if (want) p = malloc(…); … if (want) free(p);` read as a
      # leak because the merge kept the never-allocated and never-freed combinations alive.
      let known = a.predSays(s.predKey)
      if known.known:
        let liveIsThen = (known.nonZero == s.predThenNonZero)
        let live = (if liveIsThen: s.thenBody else: s.elseBody)
        if a.analyzeBody(live, st, nst): gone = true
        continue
      # Tables are value types: these copy the incoming state per branch.
      var thenSt = st
      var thenN = nst
      # every pointer the condition proves non-null on THIS branch, including the compound
      # forms a single `condKey` cannot express (`if (a == NULL || b == NULL) return;`)
      # The realloc tie and the staleness it produces are per-path like the bindings below, and
      # this is the branch that settles them: each side learns the opposite thing about the
      # result's null-ness, which is exactly what the reconciliation idiom relies on.
      let t0 = a.reallocTie
      let sl0 = a.staleAfterRealloc
      let pf0 = a.predFacts
      let be0 = a.baseEscaped
      if s.predKey.len > 0:
        # THEN learns the scalar's truth; the ZERO side learns its exact value.
        a.predFacts[s.predKey] = (if s.predThenNonZero: (exact: false, val: 0)
                                  else: (exact: true, val: 0))
      for f in s.nonNullThen:
        thenN[f.key] = nkNonNull
        a.settleRealloc(f.key, true, thenN)
      if s.condKey.len > 0:
        if s.condThenNonNull:
          thenN[s.condKey] = nkNonNull
          a.settleRealloc(s.condKey, true, thenN)
        else:
          a.dischargeNull(s.condKey, thenSt)       # then-branch: condKey is null
          a.settleRealloc(s.condKey, false, thenN)
      # Variable -> origin BINDINGS are per path too: the else path starts from the bindings
      # at the branch point (not from what the then path rebound), and the join reconciles
      # them below. Without this `if (c) { p = malloc; free(p) } else { p = malloc }` left `p`
      # bound to the else path's origin only, and the freed one was forgotten — a use after
      # the join passed as GREEN.
      let v0 = a.varOrigin
      let i0 = a.interiorVar
      let o0 = a.interiorOff
      let u0 = a.unknownOrigin
      let m0 = a.ambiguousHandles
      let thenDiv = a.analyzeBody(s.thenBody, thenSt, thenN)
      let v1 = a.varOrigin
      let i1 = a.interiorVar
      let o1 = a.interiorOff
      let u1 = a.unknownOrigin
      let m1 = a.ambiguousHandles
      let t1 = a.reallocTie
      let sl1 = a.staleAfterRealloc
      let pf1 = a.predFacts
      let be1 = a.baseEscaped
      # an origin this branch released and then stopped referring to (the buffer it replaced)
      # carries nothing to the join: no handle can use or release it again
      dropOrphanedFreed(thenSt, v1)
      a.varOrigin = v0
      a.interiorVar = i0
      a.interiorOff = o0
      a.unknownOrigin = u0
      a.ambiguousHandles = m0
      a.reallocTie = t0
      a.staleAfterRealloc = sl0
      a.predFacts = pf0
      a.baseEscaped = be0
      if s.predKey.len > 0:
        a.predFacts[s.predKey] = (if s.predThenNonZero: (exact: true, val: 0)
                                  else: (exact: false, val: 0))

      var elseSt = st
      var elseN = nst
      for f in s.nonNullElse:
        elseN[f.key] = nkNonNull
        a.settleRealloc(f.key, true, elseN)
      if s.condKey.len > 0:
        if not s.condThenNonNull:
          elseN[s.condKey] = nkNonNull
          a.settleRealloc(s.condKey, true, elseN)
        else:
          a.dischargeNull(s.condKey, elseSt)       # else-branch: condKey is null
          a.settleRealloc(s.condKey, false, elseN)
      let elseDiv = a.analyzeBody(s.elseBody, elseSt, elseN)
      dropOrphanedFreed(elseSt, a.varOrigin)

      if thenDiv and elseDiv:
        gone = true                  # both paths leave; fall-through is unreachable
      elif thenDiv:
        st = elseSt; nst = elseN     # only the else path reaches the join (its bindings stand)
      elif elseDiv:
        st = thenSt; nst = thenN
        a.varOrigin = v1; a.interiorVar = i1; a.interiorOff = o1   # only the then path reaches
        a.unknownOrigin = u1; a.ambiguousHandles = m1
        a.reallocTie = t1; a.staleAfterRealloc = sl1; a.predFacts = pf1
        a.baseEscaped = be1
      else:
        # may-set merge: a state is possible after the join if possible on EITHER path
        var merged = thenSt
        mergeStateInto(merged, elseSt)
        st = merged
        var mn = thenN               # null: non-null only if non-null on BOTH paths
        mergeNullInto(mn, elseN)
        nst = mn
        mergePredInto(a.predFacts, pf1)   # a fact survives only if both branches carry it
        # "the container carried its fields away" is a MUST-fact: true after the join only if it
        # was true on both incoming paths. A union here let a parser that appends its element on
        # the `/>` branch silence the field leaks of the path where the file simply ended.
        # Built element by element: the standard `*` sizes its result from the operands' capacity
        # and rounds it up, so the capacity doubled at every join and a function with many
        # branches exhausted memory.
        var both = initHashSet[string]()
        for key in a.baseEscaped:
          if key in be1: both.incl key
        a.baseEscaped = both
        a.joinBindings(st, v1, i1, o1, u1, m1, t1, sl1)  # reconcile the then path's bindings into the else path's
    of stTry:
      # `try { B } catch ...`: every unwinding exit inside B — a throw, a call that may throw —
      # is deposited on this frame instead of leaving the function; the handlers are
      # alternatives entered from the JOIN of those deposits (may-set: a state possible at ANY
      # such exit is possible at handler entry, so a resource B released and then exposed
      # again is may-freed there — a handler's release of it is the double free it would be).
      # Which deposits a handler receives — C++ order, first match wins: a deposit from a
      # literal `throw e` carries e's canonical type and is consumed by the first handler
      # naming EXACTLY that type (`catch (T)` / `catch (const T&)`); an inexact relation (a
      # base class, a conversion) is not matched, so the deposit propagates — red, and sound.
      # A deposit from a may-throw call carries no type: it may reach every handler, and it
      # propagates too unless a `catch (...)` ends the chain. Whatever propagates is an
      # unwinding exit of the enclosing frame (each deposit keeps its type there) or of the
      # function (every raw owner still held leaks). A handler nothing reaches is not analysed.
      a.tryFrames.add @[]
      var bodySt = st
      var bodyN = nst
      let bodyDiv = a.analyzeBody(s.tryBody, bodySt, bodyN)
      let deposits = a.tryFrames.pop()
      var exits: seq[tuple[st: StateMap, nst: NullState]]   # states reaching the point after
      if not bodyDiv: exits.add (bodySt, bodyN)
      var unknown, unmatched: seq[TryDeposit]
      for d in deposits:
        if d.ty.len > 0: unmatched.add d else: unknown.add d
      for i, h in s.handlers:
        let ht = (if i < s.handlerTypes.len: s.handlerTypes[i] else: "")
        var entry: seq[TryDeposit]
        if ht == "...":
          entry = unknown & unmatched
          unknown = @[]; unmatched = @[]
        else:
          entry = unknown
          var rest: seq[TryDeposit]
          for d in unmatched:
            if d.ty == ht: entry.add d else: rest.add d
          unmatched = rest
        if entry.len == 0: continue
        var hSt = entry[0].st
        var hN = entry[0].nst
        for j in 1 ..< entry.len:
          mergeStateInto(hSt, entry[j].st)
          mergeNullInto(hN, entry[j].nst)
        if not a.analyzeBody(h, hSt, hN): exits.add (hSt, hN)
        if ht == "...": break
      let propagating = unknown & unmatched
      if propagating.len > 0:
        if a.tryFrames.len > 0:
          for d in propagating: a.tryFrames[^1].add d
        else:
          var pSt = propagating[0].st
          for j in 1 ..< propagating.len: mergeStateInto(pSt, propagating[j].st)
          a.scanLeaks(pSt)
      if exits.len == 0:
        gone = true
      else:
        var mst = exits[0].st
        var mn = exits[0].nst
        for i in 1 ..< exits.len:
          mergeStateInto(mst, exits[i].st)
          mergeNullInto(mn, exits[i].nst)
        st = mst; nst = mn
    of stLoop:
      # Bounded fixpoint over the may-state lattice. The loop head is a join of the
      # entry edge and the back edge (body-exit -> head), so we iterate
      #   head_{k+1} = head_k ⊔ body-exit(head_k)
      # to convergence. The lattice is finite (powerset of {Owned,Freed,Moved} per
      # origin) and the transfer function is monotone (alloc/free/move reset an origin;
      # everything else is union-merge), so the ascending chain converges — typically
      # in 2–4 passes; the cap is a backstop that should not fire.
      #
      # This makes in-body effects visible AND closes the cross-iteration hole: a free
      # of a carried-in resource (`p=malloc(); for{...} free(p);`) reaches the head as
      # may-freed, so the next iteration's free is a DOUBLE_FREE — previously missed. A
      # resource re-allocated each iteration (`for{ p=malloc(); free(p); }`) stays clean
      # because alloc resets its origin to Owned, clearing the carried-in freed state.
      #
      # restoreWorld() before each pass keeps origin IDs deterministic so the per-pass
      # state maps align; the dry runs are silent and only the final pass emits.
      let base = a.captureWorld()
      let savedBreak = a.breakStates      # this loop owns fresh break/continue collectors;
      let savedCont = a.continueStates    # restore the enclosing construct's after.
      var head = st
      var headN = nst
      # The head's UNKNOWN set travels the fixpoint with the state. A handle the body rebinds
      # (`cur = cur->next`) does not still name the entry node on the second iteration; without
      # this the head kept the entry bindings forever and the walk read as a double free of the
      # node the previous iteration released. Unknown and ambiguous handles travel alongside
      # the bindings; origin allocation still restarts from `base` on each pass.
      var headUnknown = a.unknownOrigin
      var headAmbiguous = a.ambiguousHandles
      # …and so do the BINDINGS. A resource allocated in one iteration and consumed in the NEXT
      # is the shape of every hand-rolled builder loop — ImageMagick's `ConvertPathToPolygon`
      # stores the previous round's point buffer into the edge array before allocating the next
      # one — and restoring the bindings from `base` on every pass left the handle unbound at the
      # head, so the store saw nothing to transfer and the allocation looked abandoned. The
      # body's exit bindings join into the head exactly as at any other join; each pass re-runs
      # the body from `base`, so an in-body allocation keeps the same origin id across passes and
      # the carried bindings stay aligned.
      var headBind = a.varOrigin
      var headInterior = a.interiorVar
      var headOff = a.interiorOff
      # `do … while (0)` has no back edge at all: the body runs exactly once, so the head is
      # the entry state and no fixpoint is needed. Iterating one anyway made the release in the
      # standard `do { … } while (0)` macro wrapper a double free of itself.
      const cap = 16
      var converged = s.noBackEdge
      for _ in 0 ..< (if s.noBackEdge: 0 else: cap):
        a.restoreWorld(base)
        a.varOrigin = headBind
        a.interiorVar = headInterior
        a.interiorOff = headOff
        for k in headAmbiguous: a.ambiguousHandles.incl k
        for k in headUnknown:
          if k in a.varOrigin:
            a.ambiguousHandles.incl k     # bound on the entry edge, rebound on the back edge
          else:
            a.unknownOrigin.incl k
        a.breakStates = @[]
        a.continueStates = @[]
        var bodySt = head
        var bodyN = headN
        let savedSilent = a.silent
        a.silent = true
        let bodyDiverged = a.analyzeBody(s.loopBody, bodySt, bodyN)
        a.silent = savedSilent
        # back edges into the head: the fall-through body exit (unless every path left
        # via break/continue/return) AND every `continue`.
        var newHead = head
        var newHeadN = headN
        if not bodyDiverged:
          dropOrphanedFreed(bodySt, a.varOrigin)  # a replaced-and-released buffer no handle names
          mergeStateInto(newHead, bodySt)
          mergeNullInto(newHeadN, bodyN)
        for cs in a.continueStates:
          var cst = cs.st
          dropOrphanedFreed(cst, cs.vo)     # liveness as it was on THAT path
          mergeStateInto(newHead, cst)
          mergeNullInto(newHeadN, cs.nst)
        # every back edge's unknowns join into the head's (unknown outranks a binding)
        var newUnknown = headUnknown
        var newAmbiguous = headAmbiguous
        if not bodyDiverged:
          for k in a.unknownOrigin: newUnknown.incl k
          for k in a.ambiguousHandles: newAmbiguous.incl k
        for cs in a.continueStates:
          for k in cs.uo: newUnknown.incl k
          for k in cs.amb: newAmbiguous.incl k
        # bindings on the back edge join into the head's, as at any other join: `joinBindings`
        # reconciles `other` INTO the analyzer's current world, which here is the body's exit.
        if not bodyDiverged:
          a.joinBindings(newHead, headBind, headInterior, headOff, headUnknown, headAmbiguous)
        else:
          # The analyzer may be sitting on a break/return path, which is NOT a back edge.
          # Start from the head, then merge only the explicit continue deposits below.
          a.varOrigin = headBind
          a.interiorVar = headInterior
          a.interiorOff = headOff
          a.unknownOrigin = headUnknown
          a.ambiguousHandles = headAmbiguous
        for cs in a.continueStates:
          a.joinBindings(newHead, cs.vo, cs.iv, cs.io, cs.uo, cs.amb, cs.tie, cs.stale)
        newUnknown = a.unknownOrigin
        newAmbiguous = a.ambiguousHandles
        let newBind = a.varOrigin
        let newInterior = a.interiorVar
        let newOff = a.interiorOff
        if newHead == head and newHeadN == headN and newUnknown == headUnknown and
           newAmbiguous == headAmbiguous and newBind == headBind and
           newInterior == headInterior and newOff == headOff:
          converged = true
          break                                            # fixpoint reached
        head = newHead
        headN = newHeadN
        headUnknown = newUnknown
        headAmbiguous = newAmbiguous
        headBind = newBind
        headInterior = newInterior
        headOff = newOff
      # Without convergence the head may still be missing states a later iteration reaches, so
      # findings from it would be incomplete: refuse the loop rather than trust a truncated view.
      if not converged and a.curCovered:
        a.addDiag(s.line, "LOOP_FIXPOINT_LIMIT", "the analysis of this loop did not converge within " & $cap &
          " iterations, so states a later iteration reaches may be missing and the findings here are " &
          "incomplete. Split the loop body, or reduce how many variables hand ownership on per iteration.")
      # Final pass from the convergent head WITH diagnostics: reports in-body and
      # cross-iteration findings exactly once. Its origin allocations persist into the
      # post-loop world.
      a.restoreWorld(base)
      a.varOrigin = headBind
      a.interiorVar = headInterior
      a.interiorOff = headOff
      for k in headAmbiguous: a.ambiguousHandles.incl k
      for k in headUnknown:
        if k in a.varOrigin: a.ambiguousHandles.incl k
        else: a.unknownOrigin.incl k
      a.breakStates = @[]
      a.continueStates = @[]
      var ds = head
      var dn = headN
      let diagDiverged = a.analyzeBody(s.loopBody, ds, dn)
      # Post-loop state.
      var atLeastOnce: seq[PathState]
      if s.doWhile:
        # do-while / goto-loop / a range-for over a container that holds an owned element: the
        # body ran ≥1, so the loop exits through the body's own end (the cond-false edge) or a
        # break — NOT the never-ran entry state, which would produce a false leak.
        if not diagDiverged:
          atLeastOnce.add (ds, dn, a.varOrigin, a.interiorVar, a.interiorOff,
                           a.unknownOrigin, a.ambiguousHandles,
                           a.reallocTie, a.staleAfterRealloc)
        for bs in a.breakStates: atLeastOnce.add bs
        # A `continue` in a BOTTOM-tested loop jumps to the test, which may be false: that is an
        # exit edge, not only a back edge, and dropping it lost the resource the continue path
        # still holds (`do { if (c) continue; free(p); … } while (…)` went silent). In a
        # constant-true loop (`while (1)`) the test cannot be false, so `continue` always
        # re-enters and is not an exit.
        if s.contExits:
          for cs in a.continueStates: atLeastOnce.add cs
      if s.doWhile and atLeastOnce.len > 0:
        st = atLeastOnce[0].st
        nst = atLeastOnce[0].nst
        for i in 1 ..< atLeastOnce.len:
          mergeStateInto(st, atLeastOnce[i].st)
          mergeNullInto(nst, atLeastOnce[i].nst)
        # bindings: each of those exits is a join edge, exactly as at an if-join. Without this
        # the post-loop world is whatever the LAST path analysed happened to leave behind, so a
        # handle only one `break` path advanced off the start of its block would lose its
        # interior-ness and a later free of it would go unreported.
        for ps in atLeastOnce:
          a.joinBindings(st, ps.vo, ps.iv, ps.io, ps.uo, ps.amb, ps.tie, ps.stale)
      else:
        # while/for (0+ trips, exit at the head; the 0-trip entry state is ⊆ head, a sound
        # over-approx) OR a break-less do-while (post-loop unreachable; head is a sound
        # conservative fallback). Plus any `break` exits.
        st = head
        nst = headN
        for bs in a.breakStates:
          var bst = bs.st
          dropOrphanedFreed(bst, bs.vo)
          mergeStateInto(st, bst)
          mergeNullInto(nst, bs.nst)
          a.joinBindings(st, bs.vo, bs.iv, bs.io, bs.uo, bs.amb, bs.tie, bs.stale)
        # bindings: the loop exit is reached from the head, which joins the entry (0 trips —
        # a variable the body rebinds may still be what it was), the body's own end, and every
        # `continue`. Reconcile all of them, as at an if-join.
        a.joinBindings(st, base.varOrigin, base.interiorVar, base.interiorOff,
                     base.unknownOrigin, base.ambiguousHandles,
                     base.reallocTie, base.staleAfterRealloc)
        for cs in a.continueStates: a.joinBindings(st, cs.vo, cs.iv, cs.io, cs.uo, cs.amb, cs.tie, cs.stale)
      a.breakStates = savedBreak
      a.continueStates = savedCont
    of stSwitch:
      # Each case is an independent branch from the switch entry (fall-through is
      # under-approximated — sound toward FP-avoidance: cases are not treated as a
      # sequence, so a free in two different cases is not a false double-free). The
      # post-switch state is the may-merge of every reaching case's exit (a case that
      # falls through OR ends in `break`), plus the entry state when there is no
      # `default` (the no-match path). The switch owns a fresh break collector — a
      # `break` here exits the switch, not any enclosing loop — restored after.
      let savedBreak = a.breakStates
      a.breakStates = @[]
      var merged: StateMap = (if s.hasDefault: initTable[int, set[AllocState]]() else: st)
      var anyReach = not s.hasDefault
      # bindings are per case too: each case starts from the bindings at the switch entry,
      # and every case that reaches the join (falls out or breaks) contributes its own —
      # reconciled below like an if-join (joinBindings)
      let v0 = a.varOrigin
      let i0 = a.interiorVar
      let o0 = a.interiorOff
      let u0 = a.unknownOrigin
      let m0 = a.ambiguousHandles
      let t0 = a.reallocTie
      let sl0 = a.staleAfterRealloc
      var reached: seq[tuple[v: Table[string, int], i: Table[string, bool],
                            o: Table[string, int], u, m: HashSet[string],
                            t: Table[string, tuple[other: string, srcDisp: string, resDisp: string, line: int, isResult: bool]], sl: HashSet[string]]]
      for caseBody in s.cases:
        a.varOrigin = v0
        a.interiorVar = i0
        a.interiorOff = o0
        a.unknownOrigin = u0
        a.ambiguousHandles = m0
        a.reallocTie = t0
        a.staleAfterRealloc = sl0
        var cs = st
        var cn = nst
        let nBreaks = a.breakStates.len
        let d = a.analyzeBody(caseBody, cs, cn)
        dropOrphanedFreed(cs, a.varOrigin)
        if not d:
          anyReach = true
          for o, v in cs: merged[o] = merged.getOrDefault(o) + v
        if not d or a.breakStates.len > nBreaks:
          reached.add (a.varOrigin, a.interiorVar, a.interiorOff, a.unknownOrigin,
                       a.ambiguousHandles, a.reallocTie, a.staleAfterRealloc)
      for bs in a.breakStates:    # a `break` exits the switch to the post-switch join
        anyReach = true
        # liveness as it was on THAT path, like the fall-through exit above and like the loop's
        # break edges: an origin the case released and then stopped naming (`p = Relinquish(p)`,
        # which nulls the handle) carries nothing to the join. Merging the break states raw left
        # the freed state on an origin no handle referred to, so the release after the switch —
        # reached only from the cases that did NOT free — read as a double free.
        var bst = bs.st
        dropOrphanedFreed(bst, bs.vo)
        for o, v in bst: merged[o] = merged.getOrDefault(o) + v
      a.breakStates = savedBreak
      if not s.hasDefault: reached.add (v0, i0, o0, u0, m0, t0, sl0)  # no-match path: entry bindings
      if s.hasDefault and not anyReach:
        gone = true            # default present and every case diverges -> diverges
      else:
        if reached.len > 0:
          a.varOrigin = reached[0].v
          a.interiorVar = reached[0].i
          a.interiorOff = reached[0].o
          a.unknownOrigin = reached[0].u
          a.ambiguousHandles = reached[0].m
          a.reallocTie = reached[0].t
          a.staleAfterRealloc = reached[0].sl
          for r in 1 ..< reached.len:
            a.joinBindings(merged, reached[r].v, reached[r].i, reached[r].o,
                           reached[r].u, reached[r].m, reached[r].t, reached[r].sl)
        st = merged
  return gone

proc modelledGotos(body: seq[Stmt], noreturn: HashSet[string]): tuple[ok: bool, gotos: HashSet[int]] =
  ## Which of this function's gotos the engine follows via join-merge. A goto is modelled
  ## when it is a *forward* jump to a *top-level* label: the C cleanup-ladder idiom, and a
  ## forward goto OUT of a loop/switch to a top-level cleanup label (the error-exit pattern) —
  ## the exit deposits into the label's join, and the loop fixpoint snapshots pendingLabels so
  ## the exit is recorded once. Back-edges (goto-loops), jumps to a nested label, irreducible
  ## flow and computed gotos (ikUnsupportedGoto) are not modelled; each of those is refused
  ## where it stands, which keeps the function red, so a free reached only via an unmodelled
  ## jump cannot slip past as a false GREEN. One unmodelled goto no longer drags the function's
  ## modelable gotos into refusal with it. "Forward" = target's top-level index > the goto's
  ## enclosing top-level index. `ok` is false only when a top-level label name repeats, in which
  ## case no goto is modelled.
  var labelIdx = initTable[string, int]()
  for i, s in body:
    if s.kind == stLabel:
      if s.labelName in labelIdx: return (false, initHashSet[int]())   # duplicate top-level label
      labelIdx[s.labelName] = i
  result.ok = true
  var found = initHashSet[int]()
  proc scan(stmts: seq[Stmt], topIdx: int, atTop: bool) =
    for j, s in stmts:
      let ti = if atTop: j else: topIdx     # the enclosing top-level statement index
      case s.kind
      of stLabel: discard                   # a nested label is inert: nothing jumps to it modelled
      of stInstr:
        if s.ik == ikGoto and s.a notin noreturn and s.a in labelIdx and labelIdx[s.a] > ti:
          found.incl cast[int](s)
      of stIf:
        scan(s.thenBody, ti, false)
        scan(s.elseBody, ti, false)
      of stLoop:
        scan(s.loopBody, ti, false)
      of stSwitch:
        for c in s.cases: scan(c, ti, false)
      of stTry:
        scan(s.tryBody, ti, false)
        for h in s.handlers: scan(h, ti, false)
  scan(body, -1, true)
  result.gotos = found

proc analyzeFunc(a: var Analyzer, fn: Func, covered: bool) =
  ## Analyze one function with its own fresh origin/null/flow state, then scan
  ## for leaks. Per-function isolation matters now that `return` divergence and
  ## signature contracts are per-function concerns. `covered` = is this function
  ## under `@kenbi` discipline: if not, its findings are dropped (uncovered code is
  ## neutral — never RED), so adoption is gradual and never a wall of red.
  a.curCovered = covered
  (a.gotoMode, a.modelledGotos) = modelledGotos(fn.body, a.prog.noreturnLabels)
  a.pendingLabels = initTable[string, seq[LabelDeposit]]()
  a.tryFrames = @[]
  a.movedHandles = initTable[string, int]()
  a.breakStates = @[]
  a.continueStates = @[]
  # the cleanup funnel (`@goto_finally`): owning exits before it are FINALLY_BYPASSED.
  a.hasFinally = false
  a.passedFinally = false
  a.finallyName = ""
  for s in fn.body:
    if s.kind == stLabel and s.labelName in a.prog.finallyLabels:
      a.hasFinally = true
      if a.finallyName.len == 0: a.finallyName = s.labelName
  let diagMark = a.diags.len
  # THE RULE OF THREE, and self-assignment safety. Both are facts the front-end established
  # about this function — a copy of an `@raii` class that has no copy operation of its own, and
  # an `operator=` that releases before it reads its source. Emitted after `diagMark` so the
  # ordinary coverage gate and `@unsafe` apply to them exactly as to every other finding.
  for g in fn.copyGaps:
    if g.what == "SELF":
      a.addDiag(g.line, "SELF_ASSIGN_UNSAFE",
        "this assigns a '" & g.cls & "' to itself, and '" & g.cls & "::operator=' releases a " &
        "member before it reads its source — so this assignment reads memory it just freed. " &
        "Guard the operator (`if (&other != this)`), or build the new value before releasing " &
        "the old one.")
    else:
      a.addDiag(g.line, "MISSING_COPY_CONTROL",
        "this copies '" & g.cls & "', which owns a resource its destructor releases and declares " &
        "no " & g.what & " — the compiler-generated one copies the pointer, so both objects " &
        "release the same memory (double free). Write a " & g.what & " that copies the resource, " &
        "or declare it `= delete` if instances must not be copied.")
  if fn.selfAssignCls.len > 0:
    a.addDiag(fn.line, "SELF_ASSIGN_UNSAFE",
      "'" & fn.selfAssignCls & "::operator=' releases a member and then reads the source " &
      "object — on `x = x` the source IS this object, so that read is of memory just freed. " &
      "Guard the assignment (`if (&other != this)`), or build the new value before releasing " &
      "the old one (copy-and-swap).")
  a.varOrigin = initTable[string, int]()
  a.interiorVar = initTable[string, bool]()
  a.interiorOff = initTable[string, int]()
  a.localAddrVars = initHashSet[string]()
  a.originRes = initTable[int, string]()
  a.originDecl = initTable[int, int]()
  a.originDisp = initTable[int, string]()
  a.fieldBase = initTable[int, string]()
  a.baseEscaped = initHashSet[string]()
  a.contractOrigins = initHashSet[int]()
  a.borrowedOrigins = initHashSet[int]()
  a.leakedOrigins = initHashSet[int]()
  a.throwReported = initHashSet[int]()
  a.arenaObjects = initHashSet[int]()
  a.raiiOrigins = initHashSet[int]()
  a.arenaOf = initTable[int, int]()
  a.fieldOrigins = initHashSet[int]()
  a.undeclaredParams = initHashSet[int]()
  a.adoptedOrigins = initHashSet[int]()
  a.predFacts = initTable[string, tuple[exact: bool, val: int]]()
  a.maybeFreedBy = initTable[int, tuple[callee: string, line: int]]()
  a.nulledByRelease = initHashSet[string]()
  a.unknownOrigin = initHashSet[string]()
  a.ambiguousHandles = initHashSet[string]()
  a.removedHandles = initHashSet[string]()
  a.listOrigins = initHashSet[int]()
  a.listReleased = initHashSet[int]()
  a.conflatedOrigins = initHashSet[int]()
  a.originLink = initTable[int, string]()
  a.nextOrigin = 0
  var st: StateMap = initTable[int, set[AllocState]]()
  var nst: NullState = initTable[string, NullKind]()
  let diverged = a.analyzeBody(fn.body, st, nst)
  # The fall-through end is one more exit: scan it for abandoned obligations.
  # But if every path already returned (diverged), each return was scanned at
  # its own point and the post-divergence `st` is stale — skip it to avoid a
  # spurious leak for an obligation that was actually freed on all return paths.
  if not diverged:
    a.scanLeaks(st)
  # Uncovered (not under `@kenbi`) code is neutral — drop everything this function
  # produced so it never shows RED. Its declared contracts are still usable by
  # covered callers (they live in the front-end, not here); only its body findings
  # are suppressed, and it is surfaced separately as a coverage gap (Phase 2).
  if not covered:
    # ...unless a `@kenbi` marker adopted a BLOCK of it: keep exactly the findings inside that
    # block's line range. Adoption at the granularity a large function is actually cleaned up
    # in — the rest of the function stays neutral, and the function does not count as adopted.
    var kept: seq[Diag]
    for i in diagMark ..< a.diags.len:
      for b in a.prog.coveredBlocks:
        if b.file == fn.file and a.diags[i].line >= b.first and a.diags[i].line <= b.last:
          kept.add a.diags[i]
          break
    a.diags.setLen(diagMark)
    for d in kept: a.diags.add d

proc memRelevant(fn: Func): bool =
  ## Does this function touch memory ownership — allocate, free, move, hold an
  ## ownership-contracted param, or pass a pointer to a callee? The coverage
  ## denominator. (A pure leaf reader that owns/transfers nothing is excluded.)
  proc scan(stmts: seq[Stmt]): bool =
    for s in stmts:
      case s.kind
      of stInstr:
        if s.ik in {ikAlloc, ikFieldAlloc, ikArenaAlloc, ikRaiiAlloc, ikRaiiMove, ikRealloc, ikFree, ikMove,
                    ikObligation, ikBorrow, ikEscapeCall, ikEscapeCallFrees,
                    ikUnaccountedFree}:
          return true
      of stIf:
        if scan(s.thenBody) or scan(s.elseBody): return true
      of stLoop:
        if scan(s.loopBody): return true
      of stSwitch:
        for c in s.cases:
          if scan(c): return true
      of stTry:
        if scan(s.tryBody): return true
        for h in s.handlers:
          if scan(h): return true
      of stLabel: discard
    false
  scan(fn.body)

proc mergeKey(fn: Func): string =
  ## The name a function is known by when several files are merged: a `static` one is
  ## invisible outside its TU, so it is keyed per file and can never be confused with a
  ## same-named static elsewhere.
  if fn.isStatic and fn.file.len > 0: fn.file & "::" & fn.name else: fn.name

proc resolveCallee(callerFile, callee: string,
                   byName: Table[string, string]): string =
  ## The merge key a call edge resolves to: a `static` definition in the CALLER's own file
  ## first (that is what the call can reach), else an external-linkage definition anywhere
  ## in the project. Empty when nothing analysed defines it — the genuine outside.
  let local = callerFile & "::" & callee
  if local in byName: return local
  if callee in byName: return callee
  ""

proc computeFlowCoverage(prog: Program,
                         status: Table[string, tuple[adopted, green, vouched: bool]],
                         cov: var CoverageStats) =
  ## Per-flow / trusted-frontier coverage.
  ## A GREEN function is *verified* when its whole **contracted**-call dependency
  ## closure is itself covered (adopted + GREEN) — no trusted residue. A contracted
  ## callee that is not covered is the **trusted frontier**: GREEN here rests on a
  ## body kenbi never verified (the honest "your GREEN depends on unverified X").
  ## Uncontracted edges are not trust — they are RED at the caller (UNCONTRACTED_
  ## ESCAPE), so a GREEN function has none and the closure walks contracted edges only.
  var adj = initTable[string, seq[string]]()      # caller -> contracted callees
  var allAdj = initTable[string, seq[tuple[callee: string, kind: CallKind]]]() # + uncontracted
  for fn in prog.funcs:
    var outs: seq[string]
    var allOuts: seq[tuple[callee: string, kind: CallKind]]
    for e in fn.calls:
      if e.kind == ckContracted: outs.add e.callee
      if e.kind != ckKnown: allOuts.add (e.callee, e.kind)   # ownership edges (not libc)
    if outs.len > 0: adj[fn.name] = outs
    if allOuts.len > 0: allAdj[fn.name] = allOuts
  var frontier = initHashSet[string]()
  for fn in prog.funcs:
    let st = status.getOrDefault(fn.name, (false, false, false))
    if not (st.adopted and st.green) or not memRelevant(fn): continue  # GREEN roots only
    var seen = initHashSet[string]()
    var stack = adj.getOrDefault(fn.name, @[])
    var clean = not st.vouched     # its own `@unsafe` is residue before any callee is walked
    while stack.len > 0:
      let c = stack.pop()
      if c in seen: continue
      seen.incl c
      let cs = status.getOrDefault(c, (false, false, false))
      if cs.adopted and cs.green and not cs.vouched:    # verified link — recurse in
        for nx in adj.getOrDefault(c, @[]): stack.add nx
      else:
        clean = false                                    # rests on something unverified
        if not cs.adopted: frontier.incl c               # uncovered -> trusted frontier
        # (an adopted-but-RED callee is the RED axis, not trust residue: skip it here)
    if clean:
      inc cov.verified
      cov.verifiedFuncs.incl fn.name
  var fr: seq[string]
  for x in frontier: fr.add x
  cov.trustedFrontier = sorted(fr)

  # --- per-flow view: entry points + their blockers --------------------
  # An entry point is an adopted, memory-relevant function that no *other* adopted
  # function calls (the root of an ownership flow — the WebAPI handler image).
  var calledByAdopted = initHashSet[string]()
  for fn in prog.funcs:
    let st = status.getOrDefault(fn.name, (false, false, false))
    if not st.adopted: continue
    for e in allAdj.getOrDefault(fn.name, @[]): calledByAdopted.incl e.callee
  for fn in prog.funcs:
    let st = status.getOrDefault(fn.name, (false, false, false))
    if not st.adopted or not memRelevant(fn): continue
    if fn.name in calledByAdopted: continue              # not a root
    # BFS all ownership edges from the entry; collect blockers.
    var blockers = initHashSet[string]()
    var seen = initHashSet[string]()
    var stack = @[fn.name]
    while stack.len > 0:
      let c = stack.pop()
      if c in seen: continue
      seen.incl c
      for e in allAdj.getOrDefault(c, @[]):
        let es = status.getOrDefault(e.callee, (false, false, false))
        if e.kind == ckUncontracted:
          blockers.incl e.callee                          # RED escape boundary
        elif es.adopted and es.green and not es.vouched:
          stack.add e.callee                              # verified link — follow
        elif not es.adopted:
          blockers.incl e.callee                          # trusted frontier
        else:
          blockers.incl e.callee                          # adopted but RED
    var bl: seq[string]
    for b in blockers: bl.add b
    cov.flows.add FlowInfo(entry: fn.name,
                           verified: st.green and bl.len == 0 and not st.vouched,
                           blockers: sorted(bl))
  cov.flows.sort(proc (x, y: FlowInfo): int = cmp(x.entry, y.entry))

type SpBound = object
  ## SPATIAL: what a validated scalar value is known to satisfy on a path. Either a
  ## CONSTANT strict upper bound (`value < constB`) or a SYMBOLIC bound naming an
  ## identifier (`value < symKey + symOff`). A symbolic bound covers a buffer allocated
  ## `malloc(sym)` by identity match — no range arithmetic. `symOff` folds strictness and
  ## any `±k`: `i < n` is symOff 0, `i <= n` is symOff 1, `pos + 4 <= len` is symOff -3.
  hasConst: bool
  constB: int       ## value < constB (when hasConst and symKey == "")
  symKey: string    ## value < symKey + symOff; "" = no symbolic bound
  symDisp: string   ## display name of the bound identifier (for diagnostics)
  symOff: int       ## the offset added to the symbol in the normalised bound
  # OVERFLOW-SAFETY: a guard whose arithmetic can wrap is credited in ℤ but not under
  # wraparound. These carry that hazard from the guard (frontend BoundEffect) to the sink,
  # which drops the accesses the wrap actually exposes. See analyzeSpatial's ikIndex handler.
  wrapVar: bool     ## guard was `var + gk <REL> lim`: `var + gk` can overflow, so the bound is
                    ## unsound. Unsigned var: sound only for an access at exactly `gk` (`j < gk`
                    ## is OOB). Signed var (wrapVarStrict): no safe access offset.
  wrapGuardOff: int ## `gk` — the positive variable-side offset (when wrapVar)
  wrapVarStrict: bool ## the var was SIGNED (option B): `var + gk` wraps to INT_MIN, a large
                    ## negative that passes `< lim` yet is OOB — the sink drops EVERY access
                    ## (including `j == gk`), not just `j < gk`
  wrapLimNeed: int  ## guard was `var <REL> sym - k` (unsigned sym): `sym - k` underflows when
                    ## `sym < k`; the sink requires the companion lower bound `sym >= this`

proc analyzeSpatial(fn: Func): seq[Diag] =
  ## The bounds axis (validation-coverage). A scalar value reaching an index sink
  ## (ikIndex — an untrusted parameter used as an array subscript) must be VALIDATED
  ## on the path: a runtime bound check present (an if-guard `x < N`, a loop condition,
  ## `% n`, a mask, or a marked validator). kenbi only confirms a check EXISTS — it
  ## never proves one unnecessary in order to remove it: what it establishes is that the
  ## check physically exists on the path and can be traced. Default-red: an unvalidated value at a sink is
  ## UNVALIDATED_INDEX. Validated-state flows per branch (a guard validates only its
  ## branch) and is intersected at joins (validated-after only if validated on every path).
  ## The validated-state maps a scalar's key to a STRICT UPPER BOUND it is known to
  ## satisfy on the path (it holds `value < bound`). Absent = no bound (unvalidated).
  ## At a sink the bound must be APPROPRIATE for the buffer — it must actually cover
  ## the buffer's size, not merely be present: an index into `buf[N]` needs `bound <= N`
  ## (so `value < N`), a length into `buf[N]` needs `bound <= N+1` (so `value <= N`). A
  ## present-but-too-loose check (e.g. `if (len < 1000)` for a 64-byte buffer) is RED.
  var diags: seq[Diag]
  # INVARIANT (slice 5): protected field key -> the size it is bounded by + the relation
  # as a strict-bound offset (`field < sizeKey + symOff`). The index sink CHAINS through
  # this: a value bounded by a protected field is, transitively, bounded by that field's
  # size. Trusted because slices 2-4 force every write to the field to be guarded (or RED).
  var invByField = initTable[string, tuple[sizeKey, sizeDisp: string, symOff: int]]()
  for inv in fn.invariants:
    invByField[inv.fieldKey] = (inv.sizeKey, inv.sizeDisp, inv.symOff)
  # INVARIANT (C2): the declared LOWER bound of a protected field (`toksuper >= -1`),
  # available at every sink (function-wide, like the upper invariant). It discharges the
  # signed-index lower-bound requirement once a `!= c` / `>= 0` guard lifts it on the path.
  var lowInvByField = initTable[string, int]()
  for lo in fn.lowInvariants:
    lowInvByField[lo.fieldKey] = lo.lowConst
  proc diverges(stmts: seq[Stmt]): bool =
    stmts.len > 0 and stmts[^1].kind == stInstr and stmts[^1].ik == ikReturn
  # `low[key]` = a known LOWER bound on a scalar (`value >= low[key]`). Tracked in parallel
  # with the upper-bound `valid` table so a signed index can be shown to be `>= 0` (the
  # access reads `i + k`, needing `i + k >= 0`). An unsigned index gets `>= 0` from its type
  # at the sink and needs no entry here.
  proc walk(stmts: seq[Stmt], valid: var Table[string, SpBound], low: var Table[string, int]) =
    for s in stmts:
      case s.kind
      of stInstr:
        case s.ik
        of ikValidate:
          if s.bKey.len > 0:                                     # symbolic: value < sym + off
            valid[s.keyA] = SpBound(symKey: s.bKey, symDisp: s.b, symOff: s.off)
          else:                                                  # constant: value < off
            valid[s.keyA] = SpBound(hasConst: true, constB: s.off)
        of ikLowBound:                                           # value >= off (tighter wins)
          low[s.keyA] = max(low.getOrDefault(s.keyA, low(int)), s.off)
        of ikTaint: valid.del s.keyA; low.del s.keyA             # untrusted: both bounds lost
        of ikValueCopy:
          if s.keyB in valid: valid[s.keyA] = valid[s.keyB] else: valid.del s.keyA
          if s.keyB in low: low[s.keyA] = low[s.keyB] else: low.del s.keyA
        of ikMaintainsCheck:
          # INVARIANT preservation: verify this `@maintains` write keeps `field REL size`.
          # A decrement / no-op (delta <= 0) preserves an upper bound given it held before.
          # An increment by δ needs `field <= size - δ` (`<=`) / `field < size - δ` (`<`)
          # BEFORE the write — established by a guard, recorded in `valid[field]` as a
          # symbolic bound `field < size + symOff`. It implies the precondition iff
          # symOff <= (1 - δ) for `<=`, or symOff <= -δ for `<`. An unverifiable delta
          # (a `set` / non-const compound) is left unchecked in this slice.
          let delta = s.off
          let relLE = s.off2 == 1
          let base = (if relLE: 1 else: 0)            # invariant: field < size + base
          var preserved = true
          if delta != high(int) and delta > 0:
            preserved = false
            if s.keyA in valid:
              let b = valid[s.keyA]
              if b.symKey.len > 0 and b.symKey == s.bKey:
                let need = (if relLE: 1 - delta else: -delta)
                if b.symOff <= need: preserved = true
            if not preserved:
              let relStr = (if relLE: " <= " else: " < ")
              diags.add Diag(line: s.line, code: "INVARIANT_NOT_MAINTAINED",
                msg: "'" & s.a & "' is declared `@maintains(" & s.a & relStr & s.b & ")`, but " &
                     "this write (+" & $delta & ") is not shown to preserve it — nothing on this " &
                     "path bounds '" & s.a & "' below '" & s.b &
                     (if delta > 1: " - " & $delta else: "") & "' first, so it can exceed '" &
                     s.b & "'. Guard it (e.g. if (" & s.a & " >= " & s.b & ") …) before the write.",
                sev: sevError)
          # POST-WRITE bound: an access right after the write uses the field's new bound (the
          # `arr[len-1]` idiom after `len = len - 1`). The invariant gives `field < size + base`;
          # a DECREMENT by k, with the field known `>= k` on the path (no unsigned underflow),
          # tightens it to `field < size + (base + δ)` — so `data[len]` after `len--` is `< cap`.
          if delta != high(int) and s.bKey.len > 0:
            if delta > 0:
              if preserved: valid[s.keyA] = SpBound(symKey: s.bKey, symDisp: s.b, symOff: base)
              else: valid.del s.keyA
            elif delta < 0:
              let lo = low.getOrDefault(s.keyA, low(int))
              if lo != low(int) and lo >= -delta:     # field >= k ⇒ no unsigned underflow
                valid[s.keyA] = SpBound(symKey: s.bKey, symDisp: s.b, symOff: base + delta)
                low[s.keyA] = lo + delta
              else: valid.del s.keyA
            else: valid[s.keyA] = SpBound(symKey: s.bKey, symDisp: s.b, symOff: base)
        of ikEstablishCheck:
          # INVARIANT init/establish (slice 4): a SET `field = rhs` establishes `field REL
          # size` directly from its RHS — the induction BASE CASE. Verify `rhs REL size` by
          # the fixed vocabulary; an unverifiable RHS is INVARIANT_NOT_MAINTAINED (never
          # assumed). This slice only adds RED (the access-side green is slice 5), so a
          # false invariant cannot be established silently.
          let relLE = (s.off2 and 1) == 1
          let sizeUnsigned = (s.off2 and 2) == 2
          let rhsOff = s.off
          var established = false
          if s.cKey == "@mask":
            # rhs is `X & size`: ANDing by the size operand yields a value `<= size`, so it
            # establishes the `<=` invariant (not `<` — the result can equal the mask). This is
            # the power-of-two ring-buffer write `idx = (idx+1) & buffer_mask`.
            established = relLE
          elif s.cKey == "@opaque":
            established = false                       # RHS kenbi cannot read as a linear form
          elif s.cKey.len == 0:
            # pure constant `rhsOff`: `rhsOff <= size` (`<=`) / `rhsOff < size` (`<`) is
            # provable only when size is unsigned (>= 0), so `field = 0` keeps `field <= size`.
            if sizeUnsigned: established = (if relLE: rhsOff <= 0 else: rhsOff < 0)
          elif s.cKey == s.bKey:
            # rhs = size + rhsOff: `size + off REL size` holds iff off <= 0 (`<=`) / off < 0 (`<`).
            established = (if relLE: rhsOff <= 0 else: rhsOff < 0)
          elif s.cKey in valid and valid[s.cKey].symKey == s.bKey:
            # FLOW-SENSITIVE: rhs is `var + rhsOff` and `var` is validated `var < size + symOff`
            # on this path (e.g. `toksuper = i` inside `for (i = toknext-1; …)`, where i is
            # bounded by toknext). Then `field = var + rhsOff <= size + symOff - 1 + rhsOff`, so
            # `field <= size` needs symOff + rhsOff <= 1, `field < size` needs symOff + rhsOff <= 0.
            let symOff = valid[s.cKey].symOff
            established = (if relLE: symOff + rhsOff <= 1 else: symOff + rhsOff <= 0)
          # else: rhs is some OTHER unbounded variable — cannot relate it to size — not established.
          if not established:
            let relStr = (if relLE: " <= " else: " < ")
            diags.add Diag(line: s.line, code: "INVARIANT_NOT_MAINTAINED",
              msg: "'" & s.a & "' is declared `@maintains(" & s.a & relStr & s.b & ")`, but " &
                   "this set is not shown to establish it — kenbi cannot confirm the assigned " &
                   "value is" & relStr & "'" & s.b & "'. Assign a value bounded by '" & s.b &
                   "' (e.g. 0 when '" & s.b & "' is unsigned, or '" & s.b & "' itself).",
              sev: sevError)
        of ikLowInvariantCheck:
          # INVARIANT (C2): verify this write preserves the LOWER bound `field >= c`. A SET
          # `field = rhs` keeps it iff rhs is known `>= c` — a pure constant, an unsigned term
          # (`>= 0`), or a path-tracked `low[rhs]`. An `++`/`+=` by a non-negative δ keeps it; a
          # decrement / unknown delta cannot be shown to (RED). A lie is INVARIANT_NOT_MAINTAINED
          # (declare-don't-infer — never assumed). Symmetric to the upper establish/maintains.
          let lowC = lowInvByField.getOrDefault(s.keyA, low(int))
          if lowC != low(int):
            let isSet = (s.off2 and 1) == 1
            let rhsUnsigned = (s.off2 and 2) == 2
            var preserved = false
            if isSet:
              let rhsOff = s.off
              if s.cKey == "@opaque": preserved = false        # RHS kenbi cannot read
              elif s.cKey.len == 0: preserved = rhsOff >= lowC  # pure constant: rhs = rhsOff
              elif rhsUnsigned: preserved = rhsOff >= lowC       # rhs = unsigned + rhsOff >= rhsOff
              elif s.cKey in low: preserved = low[s.cKey] + rhsOff >= lowC  # path-tracked low[rhs]
            else:
              let delta = s.off
              preserved = delta != high(int) and delta >= 0     # a non-negative δ keeps a lower bound
            if not preserved:
              diags.add Diag(line: s.line, code: "INVARIANT_NOT_MAINTAINED",
                msg: "'" & s.a & "' is declared `@maintains(" & s.a & " >= " & $lowC & ")`, but " &
                     "this write is not shown to preserve it — kenbi cannot confirm the result " &
                     "stays >= " & $lowC & ". Assign a value known >= " & $lowC & " (a constant, " &
                     "an unsigned term, or a variable guarded >= " & $lowC & "), or only increase it.",
                sev: sevError)
        of ikIndex:
          let isRead = s.b == "rsize"                            # a length that READS from a buffer
          let isSize = s.b == "size" or isRead                   # a length (write or read) vs an index
          let bufN = s.off                                       # const buffer size; <0 = unknown
          let bufSym = s.bKey                                    # symbolic buffer size; "" = none
          let bufOff = s.off3                                    # buffer holds `bufSym + bufOff` elems
          let j = s.off2                                         # the `± k` access offset
          let needOff = (if isSize: 1 else: 0)                   # index needs <size; length <=size
          let what = (if isRead: "sizes a read from" elif isSize: "sizes a write into" else: "indexes")
          let codeBase = (if isSize: "UNVALIDATED_SIZE" else: "UNVALIDATED_INDEX")
          # how the accessed value reads, with its offset: `i`, `i + 1`, `i - 1`.
          let access = (if j > 0: s.a & " + " & $j elif j < 0: s.a & " - " & $(-j) else: s.a)
          let needRel = (if isSize: " <= " else: " < ")
          # CHAIN composition `value < bufSym + effOff` from a symbolic bound, transitively
          # following protected-field invariants AND validated runtime scalar bounds. Returns the
          # final (key, off) reached. (`valid` is a var param — snapshot it for the closure.)
          let validSnap = valid
          proc chase(symKey: string, symOff: int): tuple[key: string, off: int] =
            var effKey = symKey
            var effOff = symOff
            var seen = initHashSet[string]()
            while effKey != bufSym and effKey notin seen:
              seen.incl effKey
              if effKey in invByField:
                let inv = invByField[effKey]
                effOff = effOff + inv.symOff - 1
                effKey = inv.sizeKey
              elif effKey in validSnap and validSnap[effKey].symKey.len > 0 and
                   not validSnap[effKey].wrapVar and validSnap[effKey].wrapLimNeed == 0:
                # `i < count` (this bound) composes with `count < n + off` (count's OWN validated
                # runtime bound) to `i < n + off` — the `i < count <= capacity` idiom. Only
                # WRAP-SAFE bounds chain: a wrap-prone `count` bound may not hold at runtime.
                let vb = validSnap[effKey]
                effOff = effOff + vb.symOff - 1
                effKey = vb.symKey
              else:
                break
            (effKey, effOff)
          proc coversZ(b: SpBound): bool =
            if b.symKey.len > 0:
              let (k, off) = chase(b.symKey, b.symOff)
              bufSym.len > 0 and k == bufSym and off + j <= needOff + bufOff
            else:
              bufN >= 0 and b.constB + j <= bufN + needOff
          # OVERFLOW-SAFETY: a bound that covers in ℤ is still unsound where the guard's OWN
          # arithmetic wraps at runtime for THIS access. A variable-side `var + gk` (unsigned)
          # wraps near the type max, so it only bounds an access at exactly `gk` — any SMALLER
          # offset (`j < gk`) is exposed. A limit-side `sym - k` (unsigned) underflows to a huge
          # value unless the companion `sym >= k` is a tracked lower bound on the path.
          let lowSnap = low            # immutable view for the closure (a `var` cannot be captured)
          proc wrapBlocks(b: SpBound): bool =
            # variable-side: unsigned exposes `j < gk`; SIGNED (wrapVarStrict) exposes every
            # access including `j == gk` (the INT_MIN wrap passes `< lim` yet is OOB).
            (b.wrapVar and (j < b.wrapGuardOff or (b.wrapVarStrict and j == b.wrapGuardOff))) or
            (b.wrapLimNeed > 0 and lowSnap.getOrDefault(b.symKey, low(int)) < b.wrapLimNeed)
          proc covers(b: SpBound): bool = coversZ(b) and not wrapBlocks(b)
          # The value's known bound(s): a validated runtime check on the path AND/OR — when
          # the value is ITSELF a protected field — its own declared invariant (`toksuper <
          # toknext`). The access is covered if EITHER suffices, so a weak tracked bound (e.g.
          # a stale `toksuper = -1` const) does not shadow the invariant seed. The invariant
          # is trustworthy via the write-barrier/maintains/establish legs.
          var candidates: seq[SpBound]
          if s.keyA in valid: candidates.add valid[s.keyA]
          if s.keyA in invByField:
            let inv = invByField[s.keyA]
            candidates.add SpBound(symKey: inv.sizeKey, symDisp: inv.sizeDisp, symOff: inv.symOff)
          var covered = false
          var wrapHit = false                          # a candidate covers in ℤ but wraps here
          var wrapCand: SpBound
          for cand in candidates:
            if coversZ(cand):
              if wrapBlocks(cand):
                if not wrapHit: wrapHit = true; wrapCand = cand
              else:
                covered = true; break
          # LOWER bound: the access reads `value + j`, so it needs `value + j >= 0`, i.e.
          # `value >= -j`. An UNSIGNED index/length is `>= 0` by type (cKey == "u"); a SIGNED
          # one needs a tracked lower bound (a `>= 0` guard / loop cond / `= const` init /
          # mask / a `@invariant`-seeded `>= k`). Without it a signed value could be negative
          # (index below zero / a huge unsigned size after conversion). Reported only once
          # the UPPER bound holds, so a wholly-unbounded value gets the single upper message.
          let needLow = -j
          var effLow = low.getOrDefault(s.keyA, low(int))
          if s.keyA in lowInvByField:                           # declared lower invariant `>= c`
            effLow = max(effLow, lowInvByField[s.keyA])
          if s.cKey == "u": effLow = max(effLow, 0)              # unsigned: >= 0 by type
          let lowerOk = effLow != low(int) and effLow >= needLow
          if candidates.len == 0:
            diags.add Diag(line: s.line, code: codeBase,
              msg: "'" & access & "' " & what & " a buffer but no bound check is present on " &
                   "this path — kenbi cannot confirm it is in range (it is an untrusted " &
                   "value). Add a runtime bound before the use (if (" & s.a & " < N) …, a " &
                   "clamp / mask, or " & s.a & " % N), or mark the access @unsafe.",
              sev: sevError)
          elif covered and not lowerOk:
            diags.add Diag(line: s.line, code: "INDEX_MAYBE_NEGATIVE",
              msg: "'" & access & "' is bounded above but not below — '" & s.a & "' is signed " &
                   "and nothing on this path shows it is " & (if needLow > 0: ">= " & $needLow
                   else: ">= 0") & ", so the access could go below the buffer. Make '" & s.a &
                   "' unsigned, add a lower-bound guard (if (" & s.a & " >= " &
                   (if needLow > 0: $needLow else: "0") & ") …), or declare `@invariant(" &
                   s.a & " >= 0)`.",
              sev: sevError)
          elif not covered and wrapHit:
            # OVERFLOW-SAFETY: a bound covered this access in ℤ but its guard arithmetic can
            # overflow. Emit an overflow-specific message naming the safe rewrite (declare-
            # don't-infer). `var + gk` overflowing is an unverified property of an untrusted
            # value, so it is not creditable.
            let gk = wrapCand.wrapGuardOff
            if wrapCand.wrapVar and (j < gk or (wrapCand.wrapVarStrict and j == gk)):
              let how = (if wrapCand.wrapVarStrict:
                           "OVERFLOWS for a signed value near INT_MAX (undefined behaviour; it " &
                           "wraps to a large negative that passes the check yet indexes out of range)"
                         else:
                           "WRAPS for an unsigned value near the maximum (it lands at a small " &
                           "value that passes the check while the access is far out of range)")
              diags.add Diag(line: s.line, code: "INAPPROPRIATE_BOUND",
                msg: "'" & access & "' is guarded by an overflow-UNSAFE check — the guard adds " &
                     $gk & " to the untrusted '" & s.a & "' (`" & s.a & " + " & $gk & "`), which " &
                     how & ". Whether that arithmetic overflows is an unverified property of an " &
                     "untrusted value. Keep the arithmetic on the trusted limit instead — " &
                     "`if (" & s.a & " < LIMIT && LIMIT - " & s.a & " >= " & $gk & ")` or " &
                     "`if (LIMIT >= " & $gk & " && " & s.a & " <= LIMIT - " & $gk & ")`.",
                sev: sevError)
            else:
              let k = wrapCand.wrapLimNeed
              diags.add Diag(line: s.line, code: "INAPPROPRIATE_BOUND",
                msg: "'" & access & "' is bounded by '" & wrapCand.symDisp & " - " & $k & "', but " &
                     "that subtraction UNDERFLOWS to a huge value when '" & wrapCand.symDisp &
                     "' < " & $k & " (unsigned), leaving the bound vacuous. Prove the companion " &
                     "first — `if (" & wrapCand.symDisp & " >= " & $k & " && " & s.a & " <= " &
                     wrapCand.symDisp & " - " & $k & ")`.",
                sev: sevError)
          elif not covered:
            let bnd = candidates[0]                     # emit a message from the primary bound
            if bnd.symKey.len > 0:
              # SYMBOLIC bound `value < sym + symOff`. Covers the access iff `sym` names the
              # buffer's OWN allocation count (identity) and `value + j` stays in range, i.e.
              # `symOff + j <= needOff`. If `sym` is itself a PROTECTED field whose invariant
              # relates it to this buffer's size, CHAIN: `value < field + a` ∧ `field < size + b`
              # ⟹ `value < size + (a + b - 1)` (strict-integer composition). Chaining is
              # TRANSITIVE (slice 6): `a < b`, `b <= c` follow to `a < c`, so interlocking
              # invariants compose (jsmn's `toksuper < toknext <= num_tokens`). The `seen`
              # set stops a declared cycle. Each invariant is itself made trustworthy by the
              # write-barrier/maintains/establish legs (slices 2-4).
              var effKey = bnd.symKey
              var effOff = bnd.symOff
              var effDisp = bnd.symDisp
              var seen = initHashSet[string]()
              while effKey != bufSym and effKey in invByField and effKey notin seen:
                seen.incl effKey
                let inv = invByField[effKey]
                effOff = effOff + inv.symOff - 1
                effKey = inv.sizeKey
                effDisp = inv.sizeDisp
              if bufSym.len > 0 and effKey == bufSym:
                if effOff + j > needOff + bufOff:
                  diags.add Diag(line: s.line, code: "INAPPROPRIATE_BOUND",
                    msg: "'" & access & "' must be" & needRel & "'" & effDisp & "', but the " &
                         "check only bounds '" & s.a & "' to '" & effDisp &
                         (if effOff == 0: "'" elif effOff > 0: " + " & $effOff & "'"
                          else: " - " & $(-effOff) & "'") &
                         " — the access can still reach the end. Tighten it so '" & access &
                         needRel & effDisp & "'.",
                    sev: sevError)
                # else: appropriate — clean
              else:
                diags.add Diag(line: s.line, code: codeBase,
                  msg: "'" & access & "' " & what & " a buffer and is bounded by a variable, but " &
                       "kenbi cannot relate that variable to this buffer's size. Bound it by the " &
                       "buffer's own allocation count (the identifier passed to malloc/calloc), or " &
                       "use a fixed-size buffer / declare its size, or mark the access @unsafe.",
                  sev: sevError)
            else:
              # CONSTANT bound `value < constB`: appropriate iff `constB + j <= bufN + needOff`.
              let bound = bnd.constB
              if bufN < 0:
                if bufSym.len > 0:
                  diags.add Diag(line: s.line, code: codeBase,
                    msg: "'" & access & "' " & what & " a buffer whose size is a VARIABLE, but it " &
                         "is bounded by a constant (< " & $bound & ") — kenbi cannot confirm a " &
                         "constant covers a variable size. Bound '" & s.a & "' by the buffer's " &
                         "own allocation count (the identifier passed to malloc/calloc).",
                    sev: sevError)
                else:
                  diags.add Diag(line: s.line, code: codeBase,
                    msg: "'" & access & "' " & what & " a buffer and is bounded (< " & $bound &
                         "), but kenbi cannot see the buffer's size, so it cannot confirm the " &
                         "bound covers it. Use a fixed-size buffer or declare its size.",
                    sev: sevError)
              elif bound + j > bufN + needOff:
                diags.add Diag(line: s.line, code: "INAPPROPRIATE_BOUND",
                  msg: "'" & access & "' is bounded (< " & $(bound + j) & ") but that does not " &
                       "cover the buffer, which holds " & $bufN & " — the access can still go " &
                       "out of range. Bound it to the buffer's size (need '" & access &
                       needRel & $bufN & "').",
                  sev: sevError)
        else: discard
      of stIf:
        var thenV = valid
        var elseV = valid
        var thenLow = low
        var elseLow = low
        for be in s.condBounds:
          if be.isNeq:                              # `value != c`: lift a known `>= c` to `>= c+1`
            # The known lower bound includes the declared invariant baseline. `!= c` improves it
            # ONLY when the value is already known exactly `>= c` (else it asserts no bound).
            template lift(tab: untyped) =
              let cur = max(tab.getOrDefault(be.key, low(int)),
                            lowInvByField.getOrDefault(be.key, low(int)))
              if cur != low(int) and cur == be.constLimit:
                tab[be.key] = max(tab.getOrDefault(be.key, low(int)), be.constLimit + 1)
            if be.onThen: lift(thenLow) else: lift(elseLow)
          elif be.isLower:                          # `value >= constLimit` (tighter wins)
            if be.onThen: thenLow[be.key] = max(thenLow.getOrDefault(be.key, low(int)), be.constLimit)
            else: elseLow[be.key] = max(elseLow.getOrDefault(be.key, low(int)), be.constLimit)
          else:
            let b = (if be.isConst: SpBound(hasConst: true, constB: be.constLimit,
                       wrapVar: be.wrapVar, wrapGuardOff: be.wrapGuardOff,
                       wrapVarStrict: be.wrapVarStrict)
                     else: SpBound(symKey: be.symKey, symDisp: be.symDisp, symOff: be.symOff,
                       wrapVar: be.wrapVar, wrapGuardOff: be.wrapGuardOff,
                       wrapVarStrict: be.wrapVarStrict, wrapLimNeed: be.wrapLimNeed))
            if be.onThen: thenV[be.key] = b
            else: elseV[be.key] = b
        walk(s.thenBody, thenV, thenLow)
        walk(s.elseBody, elseV, elseLow)
        let td = diverges(s.thenBody)
        let ed = diverges(s.elseBody)
        if td and not ed: valid = elseV; low = elseLow
        elif ed and not td: valid = thenV; low = thenLow
        elif td and ed: discard
        else:                                       # merge: keep a bound only if on BOTH
          var merged = initTable[string, SpBound]() # paths and COMPATIBLE; weaker holds
          for k, v in thenV:
            if k notin elseV: continue
            let w = elseV[k]
            if v.symKey.len > 0 and v.symKey == w.symKey:
              merged[k] = SpBound(symKey: v.symKey, symDisp: v.symDisp,
                                  symOff: max(v.symOff, w.symOff),    # weaker bound holds
                                  # wrap hazards survive the join: keep the STRICTER of each
                                  # (larger gk / larger companion need refuses more; signed-strict
                                  # wins) so a merged bound never loses a wrap constraint one
                                  # branch carried.
                                  wrapVar: v.wrapVar or w.wrapVar,
                                  wrapGuardOff: max(v.wrapGuardOff, w.wrapGuardOff),
                                  wrapVarStrict: v.wrapVarStrict or w.wrapVarStrict,
                                  wrapLimNeed: max(v.wrapLimNeed, w.wrapLimNeed))
            elif v.symKey.len == 0 and w.symKey.len == 0 and v.hasConst and w.hasConst:
              merged[k] = SpBound(hasConst: true, constB: max(v.constB, w.constB),
                                  wrapVar: v.wrapVar or w.wrapVar,
                                  wrapGuardOff: max(v.wrapGuardOff, w.wrapGuardOff),
                                  wrapVarStrict: v.wrapVarStrict or w.wrapVarStrict)
            # else: incompatible bounds (const vs symbolic, or different symbols) -> drop
          valid = merged
          var mergedLow = initTable[string, int]()  # a lower bound holds only if on BOTH;
          for k, v in thenLow:                       # the weaker (smaller) one holds
            if k in elseLow: mergedLow[k] = min(v, elseLow[k])
          low = mergedLow
      of stLoop:
        var loopV = valid
        var loopLow = low
        walk(s.loopBody, loopV, loopLow)
      of stSwitch:
        for c in s.cases:
          var cv = valid
          var cLow = low
          walk(c, cv, cLow)
      of stTry:
        # a handler is entered from an unknown point of the body: no bound the body established
        # is proven there — walk it from the ENTRY facts; after the try the entry facts stand.
        var tv = valid
        var tLow = low
        walk(s.tryBody, tv, tLow)
        for h in s.handlers:
          var hv = valid
          var hLow = low
          walk(h, hv, hLow)
      of stLabel: discard
  var valid = initTable[string, SpBound]()
  var low = initTable[string, int]()
  walk(fn.body, valid, low)
  diags

proc analyzeConcurrency(fn: Func): seq[Diag] =
  ## The lock-discipline axis. A read/write of a `@guarded_by(field: lock)` field
  ## (ikGuardedAccess) must occur with `lock` provably HELD on the path — a MUST-analysis:
  ## the held-set is the INTERSECTION across branches (a lock is held only if held on every
  ## path), so an access kenbi cannot prove is locked is UNGUARDED_ACCESS (default-red, a
  ## data race). Acquire/release toggle the set. kenbi confirms a lock is demonstrably held;
  ## it never proves one unnecessary (the bounds axis treats checks the same way). Separate
  ## flow pass, mirroring analyzeSpatial — the temporal/spatial passes no-op the lock
  ## instructions.
  var diags: seq[Diag]
  proc diverges(stmts: seq[Stmt]): bool =
    stmts.len > 0 and stmts[^1].kind == stInstr and stmts[^1].ik == ikReturn
  proc inter(x, y: HashSet[string]): HashSet[string] =
    for k in x:
      if k in y: result.incl k
  proc walk(stmts: seq[Stmt], held: var HashSet[string]) =
    for s in stmts:
      case s.kind
      of stInstr:
        case s.ik
        of ikLockAcquire: held.incl s.aKey
        of ikLockRelease: held.excl s.aKey
        of ikGuardedAccess:
          if s.bKey notin held:
            diags.add Diag(line: s.line, code: "UNGUARDED_ACCESS",
              msg: "'" & s.a & "' is declared `@guarded_by(" & s.b & ")`, but it is read/" &
                   "written here without '" & s.b & "' provably held on this path — a data " &
                   "race. Acquire '" & s.b & "' before the access (and release it after), or " &
                   "mark the access @unsafe.",
              sev: sevError)
        of ikGuardedEscape:
          # The address of a guarded field is taken: a pointer to the data escapes the lock's
          # reach, so accesses through it cannot be verified (an alias can race after unlock).
          # Unconditional (held or not) — holding the lock now does not protect later uses.
          diags.add Diag(line: s.line, code: "GUARDED_ESCAPE",
            msg: "the address of guarded field '" & s.a & "' is taken here — a pointer to it " &
                 "escapes the lock's protection, so kenbi cannot verify accesses through it are " &
                 "guarded (an alias can race after the lock is released). Keep the access inline " &
                 "(`" & s.a & "`) under the lock, or restructure so the address does not escape.",
            sev: sevError)
        else: discard
      of stIf:
        var thenH = held
        var elseH = held
        if s.condLockKey.len > 0:                # trylock: held only on the success branch
          if s.condLockOnThen: thenH.incl s.condLockKey
          else: elseH.incl s.condLockKey
        walk(s.thenBody, thenH)
        walk(s.elseBody, elseH)
        let td = diverges(s.thenBody)
        let ed = diverges(s.elseBody)
        if td and not ed: held = elseH
        elif ed and not td: held = thenH
        elif td and ed: discard
        else: held = inter(thenH, elseH)        # held after iff held on BOTH branches
      of stLoop:
        var bodyH = held
        walk(s.loopBody, bodyH)
        held = inter(held, bodyH)               # held after iff held on the 0-trip AND a run
      of stSwitch:
        var acc = held                          # the no-match path keeps the entry held-set
        for c in s.cases:
          var cv = held
          walk(c, cv)
          acc = inter(acc, cv)
        held = acc
      of stTry:
        var bodyH = held
        walk(s.tryBody, bodyH)
        var acc = bodyH                         # held after iff held on the body's completion
        for h in s.handlers:                    # AND on every handler's — a handler is entered
          var hv = held                         # from an unknown point: only the entry set is
          walk(h, hv)                           # proven held there
          acc = inter(acc, hv)
        held = acc
      of stLabel: discard
  var held = initHashSet[string]()
  walk(fn.body, held)
  diags

proc analyzeLockBalance(fn: Func, lockOrder: seq[tuple[before, after: string]]): seq[Diag] =
  ## The held-set discipline pass for `@threadsafe` functions — leak, self-deadlock, AB-BA
  ## deadlock, and bad-unlock. It threads BOTH a MAY held-set (union joins) and a MUST held-set
  ## (intersection joins) and checks at lock toggles + exits:
  ##  * LOCK_LEAKED — a lock acquired but still held (in MAY) at an exit. The leak analogue
  ##    (`lock(); if(err) return; ...; unlock();`). MAY: a lock leaks if held on SOME path.
  ##  * DOUBLE_LOCK — re-acquiring a lock already held (in MAY): self-deadlock on a non-recursive
  ##    mutex (a recursive lock takes `@unsafe`). Rust's `Mutex::lock()` hangs at runtime here;
  ##    kenbi refuses it statically — a guarantee Rust does NOT make.
  ##  * LOCK_ORDER_VIOLATION — acquiring a lock declared (`@lock_order(a < b)`) to come BEFORE one
  ##    already held: the classic AB-BA deadlock. Rust prevents data races, never this.
  ##  * UNLOCK_WITHOUT_LOCK — releasing a lock not provably held on EVERY path (not in MUST): UB
  ##    on an unlocked mutex / releasing another holder's lock.
  ## The escapes are declared contracts, VERIFIED (not trusted): `@acquires(l)` hands `l` to the
  ## caller held (suppresses the leak, and `l` must be provably held on EVERY exit else
  ## LOCK_NOT_ACQUIRED); `@releases(l)` says the caller holds `l` at entry (seeded into the set)
  ## and the function must release it before returning. A separate pass — temporal/spatial/the
  ## concurrency MUST-pass no-op these instructions; this one only consumes the lock toggles.
  var diags: seq[Diag]
  var acquiresSet = initHashSet[string]()
  for (k, _) in fn.acquiresLocks: acquiresSet.incl k
  var dispOf = initTable[string, string]()           # lock key -> display name (for messages)
  var releasesSet = initHashSet[string]()
  for (k, d) in fn.releasesLocks: releasesSet.incl k; dispOf[k] = d
  for (k, d) in fn.acquiresLocks: dispOf[k] = d
  const osep = ""
  var orderSet = initHashSet[string]()               # "before<after" pairs, matched on display
  for pair in lockOrder: orderSet.incl(pair.before & osep & pair.after)
  # v3 stage 3 (same-class canonical order): per held lock, its @lock_class and base-var USR;
  # `lt` carries the established "smaller<bigger" base orderings on the current path (from an
  # `if (a < b)` guard). Locking two instances of one class is legal only if the first-held base
  # is provably the smaller (the address-ordering discipline) on this path.
  let lsep = osep
  var classOf = initTable[string, string]()          # lock key -> its @lock_class (field instances)
  var baseOf = initTable[string, string]()           # lock key -> its base variable's USR
  proc diverges(stmts: seq[Stmt]): bool =
    stmts.len > 0 and stmts[^1].kind == stInstr and stmts[^1].ik == ikReturn
  proc endDiverges(stmts: seq[Stmt]): bool =
    # Can control NOT fall through to the end of `stmts`? (a trailing return, or an if whose
    # both branches diverge). Used to skip the implicit end-of-body exit check when unreachable.
    if stmts.len == 0: return false
    let s = stmts[^1]
    case s.kind
    of stInstr: s.ik == ikReturn
    of stIf: s.elseBody.len > 0 and endDiverges(s.thenBody) and endDiverges(s.elseBody)
    else: false
  proc uni(x, y: HashSet[string]): HashSet[string] =
    result = x
    for k in y: result.incl k
  proc inter(x, y: HashSet[string]): HashSet[string] =
    for k in x:
      if k in y: result.incl k
  proc checkExit(line: int, mayH, mustH: HashSet[string]) =
    # leak: any held lock not handed to the caller via @acquires.
    for k in mayH:
      if k in acquiresSet: continue
      let d = dispOf.getOrDefault(k, k)
      if k in releasesSet:
        diags.add Diag(line: line, code: "LOCK_LEAKED",
          msg: "'" & d & "' is declared `@releases(" & d & ")` (held by the caller at entry), " &
               "but it is still held at this exit — release it before returning.", sev: sevError)
      else:
        diags.add Diag(line: line, code: "LOCK_LEAKED",
          msg: "'" & d & "' is acquired in this function but still held at this exit — a leaked " &
               "lock (deadlock on the next acquire). Release it on every path, or declare " &
               "`@acquires(" & d & ")` if the caller takes it held.", sev: sevError)
    # contract: a lock declared @acquires must be provably held on EVERY path to this exit.
    for (k, d) in fn.acquiresLocks:
      if k notin mustH:
        diags.add Diag(line: line, code: "LOCK_NOT_ACQUIRED",
          msg: "'" & d & "' is declared `@acquires(" & d & ")` but it is not provably held on " &
               "this exit path — acquire it on every path, or drop the `@acquires`.", sev: sevError)
  proc walk(stmts: seq[Stmt], mayH, mustH: var HashSet[string], lt: HashSet[string]) =
    for s in stmts:
      case s.kind
      of stInstr:
        case s.ik
        of ikLockAcquire:
          # DOUBLE_LOCK: re-acquiring a lock already held on some path = self-deadlock on a
          # non-recursive mutex (Rust's Mutex::lock() just hangs here; we refuse it statically).
          if s.aKey in mayH:
            diags.add Diag(line: s.line, code: "DOUBLE_LOCK",
              msg: "'" & s.a & "' is already held on a path reaching here — re-acquiring it " &
                   "self-deadlocks a non-recursive mutex. Acquire it once, or mark this " &
                   "`@unsafe` if it is a recursive lock.", sev: sevError)
          # LOCK_ORDER_VIOLATION: acquiring a lock declared to come BEFORE one already held is the
          # AB-BA deadlock — held in the reverse of the declared order. (Rust cannot catch this.)
          for hk in mayH:
            if (s.a & osep & dispOf.getOrDefault(hk, hk)) in orderSet:
              diags.add Diag(line: s.line, code: "LOCK_ORDER_VIOLATION",
                msg: "'" & s.a & "' is declared `@lock_order(" & s.a & " < " &
                     dispOf.getOrDefault(hk, hk) & ")` to be acquired BEFORE '" &
                     dispOf.getOrDefault(hk, hk) & "', but '" & dispOf.getOrDefault(hk, hk) &
                     "' is already held here — the reverse order, an AB-BA deadlock. Acquire " &
                     "them in the declared order on every path.", sev: sevError)
          # SAME_CLASS_NO_ORDER: holding TWO distinct instances of one `@lock_class` requires a
          # canonical address order (lock the lower-addressed first). The already-held instance was
          # acquired first, so it must be provably the smaller (`heldBase < thisBase` ∈ lt, from an
          # `if (a < b)` guard). Without that proof, two threads can take them in opposite orders =
          # an AB-BA deadlock within the class. Rust does not prevent this.
          if s.b.len > 0:
            classOf[s.aKey] = s.b; baseOf[s.aKey] = s.bKey
            for hk in mayH:
              if hk == s.aKey or classOf.getOrDefault(hk, "") != s.b: continue
              let hb = baseOf.getOrDefault(hk, "")
              if hb.len == 0 or s.bKey.len == 0 or (hb & lsep & s.bKey) notin lt:
                diags.add Diag(line: s.line, code: "SAME_CLASS_NO_ORDER",
                  msg: "'" & s.a & "' and the already-held '" & dispOf.getOrDefault(hk, hk) &
                       "' are two instances of lock class `" & s.b & "` — acquiring both without a " &
                       "canonical order risks an AB-BA deadlock (another thread may take them in the " &
                       "opposite order). Acquire them lower-address-first under an `if (" &
                       "<lower> < <higher>)` guard (or `@unsafe` if a fixed order is otherwise " &
                       "guaranteed).", sev: sevError)
          mayH.incl s.aKey; mustH.incl s.aKey
          if s.aKey notin dispOf: dispOf[s.aKey] = s.a
        of ikLockRelease:
          # UNLOCK_WITHOUT_LOCK: releasing a lock not provably held on every path = UB on an
          # unlocked mutex / a double-unlock (MUST: held on EVERY path, else refuse).
          if s.aKey notin mustH:
            diags.add Diag(line: s.line, code: "UNLOCK_WITHOUT_LOCK",
              msg: "'" & s.a & "' is released here but it is not provably held on every path " &
                   "reaching this point — undefined behaviour on an unlocked mutex (or a " &
                   "double-unlock). Hold it unconditionally before releasing, or declare " &
                   "`@releases(" & s.a & ")` if the caller holds it at entry.", sev: sevError)
          mayH.excl s.aKey; mustH.excl s.aKey
        of ikRequiredLockCall:
          # the callee is declared `@requires_lock(s.b)`: that lock must be held on EVERY path
          # reaching this call (MUST), else the callee races on data the caller should have locked.
          # A resolved field lock matches by key (s.bKey); a global lock matches by display (s.b).
          var held = false
          if s.bKey.len > 0:
            held = s.bKey in mustH
          else:
            for hk in mustH:
              if dispOf.getOrDefault(hk, hk) == s.b: held = true; break
          if not held:
            diags.add Diag(line: s.line, code: "REQUIRED_LOCK_NOT_HELD",
              msg: "'" & s.a & "' is declared `@requires_lock(" & s.b & ")`, but '" & s.b &
                   "' is not provably held on every path to this call — the callee accesses " &
                   "state the caller must have locked (a data race). Acquire '" & s.b &
                   "' before calling, or mark the call `@unsafe`.", sev: sevError)
        of ikIndirectCall:
          # v3 stage 4: a call through a function pointer.
          if s.aKey != "T":
            # no declared `@calls` targets: the callee's lock behaviour is unverifiable. Holding any
            # lock across it cannot be proven deadlock-free — refuse (resolve by declaring targets,
            # not by @unsafe). A lock-free indirect call is fine (nothing to deadlock against).
            if mayH.len > 0:
              diags.add Diag(line: s.line, code: "UNDECLARED_INDIRECT_CALL",
                msg: "the call through '" & s.a & "' has no declared `@calls(...)` targets, so its " &
                     "lock behaviour is unknown — calling it while holding a lock can deadlock " &
                     "(the callee may take a lock in a conflicting order). Declare the callable " &
                     "targets with `@calls(...)`; do not silence this with @unsafe.", sev: sevError)
          else:
            # declared targets: acquiring one of THEIR locks in the reverse of a declared order is an
            # AB-BA deadlock via the callback (the same order check as a direct acquire).
            for la in s.b.split(';'):
              if la.len == 0: continue
              for hk in mayH:
                if (la & osep & dispOf.getOrDefault(hk, hk)) in orderSet:
                  diags.add Diag(line: s.line, code: "LOCK_ORDER_VIOLATION",
                    msg: "the call through '" & s.a & "' may acquire '" & la &
                         "', declared `@lock_order(" & la & " < " & dispOf.getOrDefault(hk, hk) &
                         ")` to precede the already-held '" & dispOf.getOrDefault(hk, hk) &
                         "' — an AB-BA deadlock via the callback. Reorder so the callback's lock " &
                         "is taken first, or split the call out from the held region.", sev: sevError)
        of ikFnAssign:
          # v3 stage 4: `fp` (declared `@calls`) is assigned a function OUTSIDE its target set — the
          # front-end emits this only on the violation (annotation-vs-implementation check).
          diags.add Diag(line: s.line, code: "UNDECLARED_FN_TARGET",
            msg: "'" & s.a & "' is declared `@calls(...)` but it is assigned '" & s.b &
                 "', which is not in its declared target set — an indirect call through it could " &
                 "then reach an unverified function. Add '" & s.b & "' to `@calls(...)`, or do not " &
                 "assign it here.", sev: sevError)
        of ikReturn:
          checkExit(s.line, mayH, mustH)
        else: discard
      of stIf:
        var thenMay = mayH; var thenMust = mustH
        var elseMay = mayH; var elseMust = mustH
        if s.condLockKey.len > 0:                # trylock: held (MAY & MUST) on the success branch
          if s.condLockOnThen: thenMay.incl s.condLockKey; thenMust.incl s.condLockKey
          else: elseMay.incl s.condLockKey; elseMust.incl s.condLockKey
          if s.condLockKey notin dispOf: dispOf[s.condLockKey] = s.condLockDisp
        var thenLt = lt; var elseLt = lt        # establish the address ordering each branch proves
        if s.condPtrOp.len > 0 and s.condPtrL.len > 0 and s.condPtrR.len > 0:
          let lessLR = s.condPtrL & lsep & s.condPtrR   # "L < R"
          let lessRL = s.condPtrR & lsep & s.condPtrL   # "R < L"
          # `<`/`<=` THEN ⇒ L<R, ELSE (distinct) ⇒ R<L; `>`/`>=` is the mirror.
          if s.condPtrOp in ["<", "<="]: thenLt.incl lessLR; elseLt.incl lessRL
          else: thenLt.incl lessRL; elseLt.incl lessLR
        walk(s.thenBody, thenMay, thenMust, thenLt)
        walk(s.elseBody, elseMay, elseMust, elseLt)
        let td = diverges(s.thenBody)
        let ed = diverges(s.elseBody)
        if td and not ed: mayH = elseMay; mustH = elseMust
        elif ed and not td: mayH = thenMay; mustH = thenMust
        elif td and ed: discard                       # both exit: fall-through unreachable
        else:
          mayH = uni(thenMay, elseMay)                # leaks if held on EITHER branch (MAY)
          mustH = inter(thenMust, elseMust)           # held-for-contract iff on BOTH (MUST)
      of stLoop:
        var bMay = mayH; var bMust = mustH
        walk(s.loopBody, bMay, bMust, lt)
        mayH = uni(mayH, bMay)                         # a lock the body leaves held may persist
        mustH = inter(mustH, bMust)                    # held-after iff on the 0-trip AND a run
      of stSwitch:
        var accMay = mayH                              # no-match path keeps the entry set
        var accMust = mayH
        var firstMust = true
        for c in s.cases:
          var cMay = mayH; var cMust = mustH
          walk(c, cMay, cMust, lt)
          accMay = uni(accMay, cMay)
          accMust = (if firstMust: cMust else: inter(accMust, cMust)); firstMust = false
        mayH = accMay
        mustH = inter(mustH, accMust)                  # incl. the no-match (entry) path
      of stTry:
        var bMay = mayH; var bMust = mustH
        walk(s.tryBody, bMay, bMust, lt)
        var accMay = bMay
        var accMust = bMust
        for h in s.handlers:
          # entered from an unknown point of the body: any lock the body MAY hold may be held
          # (leak check), nothing beyond the entry set is certainly held (contract check)
          var hMay = uni(mayH, bMay); var hMust = mustH
          walk(h, hMay, hMust, lt)
          accMay = uni(accMay, hMay)
          accMust = inter(accMust, hMust)
        mayH = accMay
        mustH = accMust
      of stLabel: discard
  # Entry: the caller's @releases contract hands these locks in held; they must be released.
  var mayH = releasesSet
  var mustH = releasesSet
  walk(fn.body, mayH, mustH, initHashSet[string]())
  if not endDiverges(fn.body):
    checkExit(fn.line, mayH, mustH)                    # implicit fall-through return
  diags

proc analyzeInit(fn: Func): seq[Diag] =
  ## Definite-assignment. A local READ (ikInitRead) must be in the ASSIGNED set on every path
  ## reaching it; an ikInitWrite adds it. MUST-analysis: branch join = INTERSECTION (assigned
  ## only if assigned on all paths). A read of a not-definitely-assigned local is
  ## USE_OF_UNINITIALIZED (default-red — an indeterminate value / wild pointer). Mirrors
  ## analyzeConcurrency; switch handles `default:` so an exhaustive switch is not a false red.
  var diags: seq[Diag]
  proc diverges(stmts: seq[Stmt]): bool =
    stmts.len > 0 and stmts[^1].kind == stInstr and stmts[^1].ik == ikReturn
  proc inter(x, y: HashSet[string]): HashSet[string] =
    for k in x:
      if k in y: result.incl k
  proc walk(stmts: seq[Stmt], asgn: var HashSet[string]) =
    for s in stmts:
      case s.kind
      of stInstr:
        case s.ik
        of ikInitWrite: asgn.incl s.aKey
        of ikInitRead:
          if s.aKey notin asgn:
            diags.add Diag(line: s.line, code: "USE_OF_UNINITIALIZED",
              msg: "'" & s.a & "' is read here but is not definitely assigned on every path " &
                   "reaching this point — it may hold an indeterminate value (a wild pointer / " &
                   "garbage int). Assign it on every branch before use, or initialise it at its " &
                   "declaration.",
              sev: sevError)
            asgn.incl s.aKey                  # report once: treat as assigned after, no cascade
        else: discard
      of stIf:
        var thenA = asgn
        var elseA = asgn
        walk(s.thenBody, thenA)
        walk(s.elseBody, elseA)
        let td = diverges(s.thenBody)
        let ed = diverges(s.elseBody)
        if td and not ed: asgn = elseA
        elif ed and not td: asgn = thenA
        elif td and ed: discard
        else: asgn = inter(thenA, elseA)      # assigned after iff assigned on BOTH branches
      of stLoop:
        var bodyA = asgn                       # a var assigned only in the body is NOT assigned
        walk(s.loopBody, bodyA)                # after (0-trip) — keep the entry set unchanged
      of stSwitch:
        var acc = initHashSet[string]()
        var first = true
        for c in s.cases:
          var cv = asgn
          walk(c, cv)
          if diverges(c): continue             # a case that returns doesn't constrain the join
          if first: acc = cv; first = false
          else: acc = inter(acc, cv)
        # only an EXHAUSTIVE switch (a `default:`) has no no-match fall-through; otherwise a
        # path assigns nothing, so the entry set stands (sound — no false "assigned").
        if s.hasDefault and not first: asgn = acc
      of stTry:
        var bodyA = asgn
        walk(s.tryBody, bodyA)
        var acc = bodyA                        # assigned after iff on the body's completion AND
        for h in s.handlers:                   # on every handler's — a handler is entered from
          var hv = asgn                        # an unknown point, so only the entry set holds
          walk(h, hv)
          if diverges(h): continue
          acc = inter(acc, hv)
        asgn = acc
      of stLabel: discard
  var asgn = initHashSet[string]()
  walk(fn.body, asgn)
  diags

proc analyzeTypeConfusion(fn: Func): seq[Diag] =
  ## The tagged-union TYPE-CONFUSION axis. A read/write of a `@variant(member : tag == value)`
  ## member (ikVariantAccess) requires the discriminant proven `tag == value` on the path (an
  ## `if (tag == value)` guard). A MUST-analysis: known facts are the INTERSECTION across
  ## branches. Accessing a variant whose tag was not checked is TYPE_CONFUSION (default-red —
  ## reading the wrong union member). The C analogue of a Rust enum's checked discriminant.
  var diags: seq[Diag]
  proc diverges(stmts: seq[Stmt]): bool =
    stmts.len > 0 and stmts[^1].kind == stInstr and stmts[^1].ik == ikReturn
  proc inter(x, y: Table[string, int]): Table[string, int] =
    for k, v in x:
      if y.getOrDefault(k, low(int)) == v: result[k] = v   # held only if both agree on the value
  proc walk(stmts: seq[Stmt], known: var Table[string, int]) =
    for s in stmts:
      case s.kind
      of stInstr:
        if s.ik == ikVariantAccess:
          if known.getOrDefault(s.bKey, low(int)) != s.off:
            diags.add Diag(line: s.line, code: "TYPE_CONFUSION",
              msg: "'" & s.a & "' is the `@variant` active only when '" & s.b & " == " & $s.off &
                   "', but that discriminant is not proven on this path — reading it here may " &
                   "interpret the wrong union member (type confusion). Guard the access with " &
                   "if (" & s.b & " == " & $s.off & ") …, or mark it @unsafe.",
              sev: sevError)
      of stIf:
        var thenK = known
        var elseK = known
        for f in s.tagFacts:                       # `tag == value` proven on a branch
          if f.onThen: thenK[f.key] = f.value else: elseK[f.key] = f.value
        walk(s.thenBody, thenK)
        walk(s.elseBody, elseK)
        let td = diverges(s.thenBody)
        let ed = diverges(s.elseBody)
        if td and not ed: known = elseK
        elif ed and not td: known = thenK
        elif td and ed: discard
        else: known = inter(thenK, elseK)
      of stLoop:
        var bodyK = known
        walk(s.loopBody, bodyK)
      of stSwitch:
        # a `case VALUE:` on the discriminant proves `tag == VALUE` in that case body (V2).
        for i, c in s.cases:
          var cv = known
          if s.switchKey.len > 0 and i < s.caseValues.len and s.caseValues[i] != low(int):
            cv[s.switchKey] = s.caseValues[i]
          walk(c, cv)
        # after the switch the discriminant is no longer a single proven value -> `known` stands
        # (a variant access past the switch needs its own guard).
      of stTry:
        var bodyK = known
        walk(s.tryBody, bodyK)
        for h in s.handlers:                   # entered from an unknown point: entry facts only
          var hv = known
          walk(h, hv)
        # after the try only the entry facts stand
      of stLabel: discard
  var known = initTable[string, int]()
  walk(fn.body, known)
  diags

type
  Axis* = enum
    ## The independent checks kenbi runs on a function, each opted into separately.
    axOwnership = "ownership"       ## lifetime, ownership and null: `@kenbi`, or a file with no marker
    axBounds = "bounds"             ## `@spatial`
    axLocks = "locks"               ## `@threadsafe`
    axInit = "initialisation"       ## `@initcheck`
    axUnions = "taggedUnions"       ## `@typecheck`

proc axesOf*(prog: Program, fn: Func): set[Axis] =
  ## Which checks run on `fn`. analyzeFull runs exactly these, and the reported scope of a
  ## result is read from here too, so what is reported as checked is what ran. A file with no
  ## `@kenbi` marker is un-adopted but checked for ownership throughout (a single-file check).
  if prog.allCovered or not prog.hasKenbiMarker or fn.name in prog.coveredFuncs:
    result.incl axOwnership
  if prog.spatialAll or fn.name in prog.spatialFuncs: result.incl axBounds
  if prog.concurrentAll or fn.name in prog.concurrentFuncs: result.incl axLocks
  if prog.initAll or fn.name in prog.initFuncs: result.incl axInit
  if prog.typecheckAll or fn.name in prog.typecheckFuncs: result.incl axUnions

proc analyzeFull*(prog: Program): tuple[diags: seq[Diag], cov: CoverageStats, unit: ProjectUnit] =
  ## Analyze + compute adoption/safety coverage. `analyze*` is the diags-only view. `unit` is
  ## this file's contribution to PROJECT coverage (see projectCoverage).
  var a = Analyzer(prog: prog)
  var cov: CoverageStats
  var unit = ProjectUnit(funcs: prog.funcs,
                         status: initTable[string, tuple[adopted, green, vouched: bool]]())
  # A file with no `@kenbi` marker is un-adopted: treat it as all-covered for GATING
  # (a single-file / fixture check), but NOT as adopted for the coverage metric — a
  # marker turns opt-in ON.
  # name -> (adopted, green) so the coverage graph below can ask, for any callee,
  # whether its body is itself covered + clean (verified) or trusted residue.
  var status = initTable[string, tuple[adopted, green, vouched: bool]]()
  if prog.funcs.len > 0:
    for fn in prog.funcs:
      let axes = axesOf(prog, fn)
      let adopted = prog.allCovered or fn.name in prog.coveredFuncs  # explicit marker only
      let mark = a.diags.len
      a.analyzeFunc(fn, axOwnership in axes)
      # SPATIAL (bounds) axis — independent opt-in (`@spatial`), so temporal-only files
      # are never bounds-checked. Emitted findings join the gate like any other.
      if axBounds in axes:
        for d in analyzeSpatial(fn): a.diags.add d
      # CONCURRENCY (lock discipline) axis — independent opt-in (`@threadsafe`).
      if axLocks in axes:
        for d in analyzeConcurrency(fn): a.diags.add d
        for d in analyzeLockBalance(fn, prog.lockOrder): a.diags.add d
      # INIT (definite-assignment) axis — independent opt-in (`@initcheck`).
      if axInit in axes:
        for d in analyzeInit(fn): a.diags.add d
      # TYPE-CONFUSION (tagged union) axis — independent opt-in (`@typecheck`).
      if axUnions in axes:
        for d in analyzeTypeConfusion(fn): a.diags.add d
      var hasRed = false
      var vouched = false
      for i in mark ..< a.diags.len:
        if a.diags[i].sev != sevError: continue
        if a.diags[i].line in prog.quarantined:
          # an `@unsafe` that actually suppresses something: the author is asserting what
          # kenbi could not check. GREEN, because the boundary is declared — never `verified`.
          vouched = true
          cov.unsafeVouches.add (fn: fn.name, line: a.diags[i].line)
        else: hasRed = true
      if fn.name.len > 0:
        status[fn.name] = (adopted, adopted and not hasRed, vouched)
        unit.status[mergeKey(fn)] = (adopted, adopted and not hasRed, vouched)
      if memRelevant(fn):
        inc cov.totalMem
        if adopted:
          inc cov.adopted
          if hasRed: inc cov.red else: inc cov.green
    computeFlowCoverage(prog, status, cov)
    cov.blocks = prog.coveredBlocks.len
    unit.flows = cov.flows
    unit.unsafeVouches = cov.unsafeVouches
    unit.blocks = cov.blocks
    unit.contractPackages = prog.contractPackages
  else:
    a.analyzeFunc(Func(body: prog.body), true)   # mini-format: a single anonymous body
  # `// unsafe` quarantine: drop findings on quarantined lines (the author takes
  # responsibility), and flag any `unsafe` that suppressed nothing as stale.
  if prog.quarantined.len > 0:
    var kept: seq[Diag]
    var covered = initHashSet[int]()
    for d in a.diags:
      if d.line in prog.quarantined: covered.incl d.line
      else: kept.add d
    a.diags = kept
    for ln in prog.quarantined:
      if ln notin covered:
        a.diags.add Diag(line: ln, code: "STALE_UNSAFE",
          msg: "`@unsafe` here suppresses nothing", sev: sevWarning)

  # shipped contract sets: a requirement the build CONTRADICTS is an error (these contracts
  # may not describe this build), one the compile line cannot settle is an advisory. Reported
  # at line 0 with the package's own file named, since a finding carries only a line.
  cov.contractPackages = prog.contractPackages
  for pkg in prog.contractPackages:
    for m in pkg.mismatched:
      a.diags.add Diag(line: 0, code: "CONTRACT_PACKAGE_MISMATCH",
        msg: "the contracts for '" & pkg.name & "'" &
             (if pkg.version.len > 0: " (version " & pkg.version & ")" else: "") &
             " declare a build condition this build contradicts — " & m &
             ". They were written for a different build, so the contracts they make may not " &
             "hold here. Declared in " & pkg.file & ":" & $pkg.line & ".", sev: sevError)
    for u in pkg.unverified:
      a.diags.add Diag(line: 0, code: "CONTRACT_PACKAGE_UNVERIFIED",
        msg: "the contracts for '" & pkg.name & "' require '" & u & "', which this compile " &
             "line does not settle — kenbi cannot confirm they describe this build. Pass it " &
             "on the compile line (`-D" & u & "=…`) to have the assumption checked. Declared " &
             "in " & pkg.file & ":" & $pkg.line & ".", sev: sevAdvisory)

  # advisory intents (lock discipline, lock order, acquire/release, freeform):
  # surfaced for the AI/human review layer, not decided here and not quarantined.
  for adv in prog.advisories:
    a.diags.add Diag(line: adv.line, code: adv.code, msg: adv.msg, sev: sevAdvisory)

  a.diags.sort(proc (x, y: Diag): int =
    result = cmp(x.line, y.line)
    if result == 0: result = cmp(x.code, y.code))
  (a.diags, cov, unit)

proc analyze*(prog: Program): seq[Diag] =
  ## Diags-only view (the test harness + callers that don't need coverage).
  analyzeFull(prog).diags

proc projectCoverage*(units: seq[ProjectUnit]): CoverageStats =
  ## PROJECT coverage over several analysed translation units. Each file's verdicts are its
  ## own (annotations are file-scoped, and so is the analysis); what this adds is the
  ## CLOSURE: a contracted call into a function defined in another analysed file resolves to
  ## that file's verdict, so a GREEN function whose dependencies are all analysed and GREEN
  ## counts as `verified` — and `trustedFrontier` narrows to the names nothing in the project
  ## defines (the genuine outside: a library shipped as a binary, the OS, an FFI edge).
  var status = initTable[string, tuple[adopted, green, vouched: bool]]()
  var byName = initTable[string, string]()      # merge key -> itself (membership + resolution)
  var funcs: seq[Func]
  for u in units:
    for fn in u.funcs:
      funcs.add fn
      byName[mergeKey(fn)] = mergeKey(fn)
    for k, v in u.status: status[k] = v
    for v in u.unsafeVouches: result.unsafeVouches.add v
    result.blocks += u.blocks
    for pk in u.contractPackages:      # the same package reaches every file that includes it
      var seen = false
      for have in result.contractPackages:
        if have.name == pk.name and have.file == pk.file and have.line == pk.line:
          seen = true; break
      if not seen: result.contractPackages.add pk
  # contracted adjacency over merge keys
  var adj = initTable[string, seq[string]]()
  for fn in funcs:
    var outs: seq[string]
    for e in fn.calls:
      if e.kind != ckContracted: continue
      let k = resolveCallee(fn.file, e.callee, byName)
      outs.add (if k.len > 0: k else: e.callee)   # unresolved stays a name: the outside
    if outs.len > 0: adj[mergeKey(fn)] = outs
  var frontier = initHashSet[string]()
  for fn in funcs:
    let key = mergeKey(fn)
    let st = status.getOrDefault(key, (false, false, false))
    if not memRelevant(fn): continue
    inc result.totalMem
    if st.adopted:
      inc result.adopted
      if st.green: inc result.green else: inc result.red
    if not (st.adopted and st.green): continue
    var seen = initHashSet[string]()
    var stack = adj.getOrDefault(key, @[])
    var clean = not st.vouched     # its own `@unsafe` is residue before any callee is walked
    while stack.len > 0:
      let c = stack.pop()
      if c in seen: continue
      seen.incl c
      let cs = status.getOrDefault(c, (false, false, false))
      if cs.adopted and cs.green and not cs.vouched:
        for nx in adj.getOrDefault(c, @[]): stack.add nx
      else:
        clean = false
        if not cs.adopted:
          # report the bare name: what the reader must cover / annotate next
          let bare = (let i = c.rfind("::"); if i >= 0: c[i + 2 .. ^1] else: c)
          frontier.incl bare
    if clean:
      inc result.verified
      result.verifiedFuncs.incl key
  var fr: seq[string]
  for x in frontier: fr.add x
  result.trustedFrontier = sorted(fr)
  # Flows, re-resolved against the project: a blocker that another analysed file defines and
  # keeps GREEN is no longer a blocker, and a flow with none left is verified.
  var fileOfFunc = initTable[string, string]()
  for fn in funcs:
    if fn.name notin fileOfFunc: fileOfFunc[fn.name] = fn.file
  for u in units:
    for fl in u.flows:
      var f = fl
      var left: seq[string]
      for b in fl.blockers:
        let k = resolveCallee(fileOfFunc.getOrDefault(fl.entry, ""), b, byName)
        let bs = status.getOrDefault((if k.len > 0: k else: b), (false, false, false))
        if not (bs.adopted and bs.green) or bs.vouched: left.add b
      f.blockers = left
      # the entry itself must be GREEN, and its OWN `@unsafe` is residue too — a flow cannot be
      # verified because everything it calls is, while the entry has a finding or rests on an
      # assertion kenbi could not check
      let ek = resolveCallee(fileOfFunc.getOrDefault(fl.entry, ""), fl.entry, byName)
      let es = status.getOrDefault((if ek.len > 0: ek else: fl.entry), (false, false, false))
      f.verified = left.len == 0 and es.adopted and es.green and not es.vouched
      result.flows.add f
