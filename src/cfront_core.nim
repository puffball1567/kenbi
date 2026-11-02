## Shared foundation for the libclang front-end: the parse-time context `Ctx`,
## the allocator vocabulary, and the small cursor / comment helpers used across
## the front-end modules (annotations / lowering / contracts). Keeping `Ctx` and
## these utilities here lets the front-end be split by responsibility without
## circular imports — see frontend_c.nim for the driver.

import std/[tables, strutils, sets]
import ir, clang

type CFrontError* = object of CatchableError

type
  ReturnKind* = enum
    ## What a `return`-value contract makes the call result at the assignment.
    rcOwned        ## `@owns`: the call returns a fresh owned obligation (factory)
    rcArenaFromArg ## `@arena_alloc`: the result borrows from the arena passed as arg 1

  ReturnContract* = object
    kind*: ReturnKind

  RawSite* = tuple[file: string, line: int, param: string]
    ## one raw annotation site, before binding to a function (collectors append these)

  FuncSig* = tuple[file, name: string, line: int,
                   params: seq[tuple[name, key: string]], hasBody: bool, qual: string]
    ## one function declaration with its ordered parameters. `hasBody` = false for a bare
    ## prototype; `qual` = `Class::method` for a member function ("" otherwise) — the key its
    ## contracts are stored under.

type Ctx* = object  ## module-local state during a single parse (all fields public
                    ## so the responsibility-split modules can populate them)
  tu*: CXTranslationUnit
  exceptionsOn*: bool               ## C++ with exceptions enabled (not C, not `-fno-exceptions`):
                                    ## a call without a nothrow guarantee is an unwinding exit
  nothrowFuncs*: HashSet[string]    ## callees vouched `@nothrow` (by name). `noexcept` itself is
                                    ## read from the declaration — no annotation needed for it
  ownsOut*: Table[string, seq[tuple[idx: int, accessor: string]]] ## funcname -> its `@owns(p)` /
                                    ## `@owns(*p)` out-parameters (index, "" = the param itself
                                    ## (a reference), "*" = its pointee)
  ownsOutParams*: Table[string, string] ## the CURRENT function's out-params: param key -> accessor
  pointeeAlias*: Table[string, string]
    ## a pointer variable's key -> the SLOT key its `*` denotes, when that slot carries an
    ## ownership contract seeded on another name. `void *v` cast into `char **p` still derefs
    ## to the same object, so `@frees(*v)` has to reach the `free(*p)` the body actually writes.
  addrOf*: Table[string, tuple[key, disp: string]] ## pointer local -> the LOCAL it currently points
                                    ## at (`char **dataPtr = &data;`): `*dataPtr = x` assigns `data`,
                                    ## `y = *dataPtr` copies it. Dropped on any other assignment.
  throwEmitted*: bool               ## lowerCallCore already emitted this call's ikMayThrow (an
                                    ## `@owns(p)` out-param: the exit precedes the new obligation)
  prog*: Program
  ownerRes*: Table[string, string]  ## owner var name -> resource name (from @mem)
  memByLine*: seq[(int, string)]    ## (decl line, resource name) for nearest-above fallback
  moveLines*: seq[int]              ## lines carrying a `@move` annotation
  copyLines*: Table[int, string]    ## line carrying `@copy` -> resource name ("" if unspecified)
  drainLines*: Table[int, string]   ## line carrying `@drains(head)` -> the head handle's NAME:
                                    ## the loop at (or just below) that line releases every
                                    ## element of the intrusive collection rooted there
  namedContracts*: seq[tuple[fn, kw, param: string]]
                                    ## `@contract <Fn> { frees: p, borrows: q }` — an ownership
                                    ## contract declared BY NAME instead of above a declaration,
                                    ## so a project you may not edit can be contracted from a
                                    ## comment-only overlay header. Each entry is one (function,
                                    ## keyword, parameter) triple; the resolver binds them to
                                    ## every matching signature exactly as the inline form does,
                                    ## body obligation included — so it is checked, not trusted.
  linkFields*: HashSet[string]      ## every field name some resource / type declares as `link:`
  listTypes*: Table[string, string] ## record type name -> its `link:` field, from
                                    ## `@list <Type> { link: <field> }`: the collection is a
                                    ## property of the TYPE, so it reaches allocations made
                                    ## through a project's own `@allocator` family too
  varTypes*: Table[string, string]  ## local / parameter key -> the RECORD NAME its pointer
                                    ## type points at ("Cluster" for `Cluster *c`), so an
                                    ## allocation can be recognised as a collection node
  varKeys*: Table[string, string]   ## local / parameter display name -> its identity key, so a
                                    ## by-NAME annotation (`@drains(head)`) reaches the handle
  declMarkers*: Table[int, InstrKind] ## decl line -> IR to emit on that decl (generic
                                      ## decl-marker store: @nullable -> ikNullable, etc.)
  # --- generic annotation-contract stores (plugin registry, annotations/) ----
  # Raw sites are appended by the generic collector; the resolver (frontend_c)
  # binds each site to its function, populating the resolved stores below. No
  # per-annotation field/case: adding a contract is a one-line registration.
  rawAnn*: Table[string, seq[RawSite]]  ## keyword -> raw annotation sites
  argContracts*: Table[string, seq[tuple[idx: int, instr: InstrKind, accessor: string]]] ## funcname -> callsite arg effect per arg index (@frees->ikFree, @moves->ikMove). `accessor` names WHAT the callee acts on relative to the arg: "" = the arg itself (`@frees(p)`); "*" = the POINTEE (`@frees(*p)`, so a `&var` arg transfers `var` — cross-file `T**`); a field name = that field (`@frees(p.f)`, so a struct-var arg transfers `arg.f` — cross-file struct source/sink).
  bodyContracts*: Table[string, seq[tuple[idx: int, instr: InstrKind, accessor: string]]]
    ## funcname -> body param seed per param index (@frees->ikObligation, @borrows->ikBorrow).
    ## `accessor` is "" for the parameter itself, "*" for its POINTEE (`@frees(*p)`, the
    ## `T**` out-parameter sink), or a field / constant element (`@frees(p.f)`, `@frees(p[2])`).
    ## An accessor form seeds the SLOT — keyed like any field path, `<param usr>::<accessor>` —
    ## so the declared release is verified inside the callee and not merely trusted at the
    ## callsite.
  funcFreesGlobal*: Table[string, seq[tuple[usr, name: string]]] ## funcname -> file-scope GLOBALs it frees. `@frees(g)` where `g` is a global (not a parameter): a zero-arg sink that releases a module-global handed to it through that global (the static-global source/sink form). At any call to the fn, the caller frees the global's origin — which `g = data` aliased in the caller's scope.
  returnContracts*: Table[string, ReturnContract] ## funcname -> return-value contract (@owns / @arena_alloc)
  funcFlags*: HashSet[string]       ## funcnames carrying a boolean flag (@must_use)
  funcSigs*: seq[FuncSig]           ## every function decl with its ordered params
  dynType*: Table[string, string]   ## a base pointer / reference local -> the class it was
                                    ## constructed as (`Base *b = new Derived`, `Base &b =
                                    ## Derived()`): a virtual call through it dispatches to
                                    ## `Derived::method`, whose contract is the one that applies
  newClass*: Table[string, string]  ## a pointer local -> USR of the class `new` constructed for it
                                    ## (`Base *b = new Derived` -> Derived), for `delete b`
  baseClasses*: HashSet[string]     ## USRs of every class some class in the TU derives from
  fieldUnsigned*: HashSet[string]   ## field-path keys (`<base-USR>::fld`) whose member has an
                                    ## UNSIGNED integer type, collected from every `base->fld`
                                    ## reference. The INVARIANT establish check consults this so a
                                    ## `field = -1` SET can establish `field < toknext` when the
                                    ## size operand `toknext` is an unsigned field (hence >= 0).
  localVars*: HashSet[string]       ## USRs of automatic-storage locals (stack vars)
  localArrayVars*: HashSet[string]  ## USRs of local array vars (name decays to a stack pointer)
  localAddrVars*: HashSet[string]   ## USRs of pointer vars currently holding a pointer into a local
  customAllocRes*: Table[string, string] ## `@allocator` alloc-fn name -> the resource its
                                    ## result owns. A project's own malloc wrappers declared
                                    ## ONCE become vocabulary: every call site is a tracked
                                    ## allocation of a DECLARED resource (so an unreleased one
                                    ## is a definite LEAK, and releasing it with the wrong
                                    ## function is WRONG_DEALLOCATOR) — no per-site `@mem`.
  customRealloc*: HashSet[string]   ## `@allocator ... { realloc: f }` — continues an obligation
  freeReturnsNull*: HashSet[string] ## release functions DECLARED to return NULL, so the
                                    ## `p = release(p)` idiom leaves p null (owning nothing,
                                    ## and releasing it again is the defined no-op)
  arenaCreate*: Table[string, string] ## arena create-fn name -> arena resource name (`@arena`)
  arenaAlloc*: HashSet[string]      ## arena alloc-fn names (`p = alloc(R,...)` borrows from R)
  tracked*: Table[string, bool]     ## decl USRs that currently carry an obligation
  fieldBaseVars*: HashSet[string]   ## USRs of LOCAL vars used as a field-path container (`b` of
                                    ## `b->buf = malloc()`): a whole-struct `return b` of one is a
                                    ## self-evident transfer that discharges its fields (#2b)
  bufSizeSym*: Table[string, tuple[symKey, symDisp: string, off: int]] ## SPATIAL: buffer key ->
                                    ## the identifier giving its allocation element count, plus a
                                    ## constant OFFSET: the buffer holds `symKey + off` elements
                                    ## (`malloc(n)` -> off 0; a declared `@counted_by(buf: mask + 1)`
                                    ## -> off 1, the power-of-two ring-buffer idiom). A symbolic
                                    ## bound `idx < symKey + b` covers it iff `b <= off` (after the
                                    ## invariant chain). Keyed by a parameter USR or a struct
                                    ## field-path key (`<base-USR>::field`) for a field buffer.
  incomingPtrs*: HashSet[string]    ## USRs of pointer params with NO ownership contract
                                    ## (ikIncomingPtr). NOT `tracked`: using / passing one
                                    ## stays inert; only RELEASING it emits an ikFree, so a
                                    ## pure reader/forwarder is not memory-relevant. Freeing
                                    ## it is UNCONTRACTED_RELEASE (intake-side default-red).
  deallocators*: HashSet[string]    ## callee names that count as a release (free + declared free:)
  returnsFreed*: HashSet[string]    ## funcnames whose VISIBLE body frees a local it then returns
                                    ## (a dangling result): `x = f()` is a maybe-freed handle
  bodyFreesParam*: Table[string, HashSet[int]] ## funcname -> param indices its VISIBLE body
                                    ## frees (directly by name). Drives the "possible
                                    ## double-free" advisory at uncontracted callsites
                                    ## whose callee visibly frees but has no @frees.
  lockOrders*: seq[tuple[line: int, a, b: string]]  ## `@lock_order(a < b)` declarations
  initSites*: seq[tuple[file: string, line: int]] ## `@initcheck` opt-in marker locations
  raiiNames*: HashSet[string]        ## `@raii(Name)`: owner classes declared by NAME
  foldedStatics*: Table[string, int64] ## file-scope `static` integer vars PROVABLY constant in this
                                     ## TU (initialised, never assigned / incremented / address-taken
                                     ## anywhere in it): USR -> value, folded in conditions
  lambdaBodies*: Table[string, seq[Stmt]] ## a local bound to a LAMBDA -> its lowered body. The
                                     ## body runs where the lambda is CALLED, not where it is
                                     ## defined, so it is stored here and spliced at each `v()`
  lambdaMemOp*: HashSet[string]      ## those whose body allocates or releases (a lambda used in
                                     ## any other way — passed on, returned — is then refused)
  slotRes*: Table[string, string]    ## container element slot key -> the resource its elements
                                     ## hold (so a range-for can re-arm one element per iteration)
  foldedFns*: Table[string, int64]   ## `static` functions whose whole body is `return <const>;`:
                                     ## USR -> value, a call to one folds in conditions
  ctorAllocs*: Table[string, seq[tuple[field: string, line: int, freed: bool]]] ## class -> raw
                                     ## members a CONSTRUCTOR allocates into (`data = malloc(...)`):
                                     ## an `@raii` class's destructor must release each (else LEAK).
                                     ## `freed`: the constructor itself already released it (then
                                     ## the destructor's release is a DOUBLE_FREE)
  copyGapClasses*: Table[string, seq[string]] ## `@raii` class -> the copy operations it owes
                                     ## but does not have ("copy constructor" / "copy assignment
                                     ## operator"), from scanRaiiCopySafety
  copyGaps*: Table[string, seq[tuple[cls, what: string, line: int]]] ## USR of a function -> the
                                     ## places in it that COPY such a class. See `Func.copyGaps`.
  selfAssignClasses*: HashSet[string] ## the classes those operators belong to, so an explicit
                                     ## `x = x` at a call site can be recognised as reaching one
  selfAssign*: Table[string, string] ## USR of an `operator=` that releases a member and then
                                     ## reads the source, with no `this`-vs-source guard -> its
                                     ## class. `x = x` reads freed memory. See scanSelfAssignSafety.
  raiiSites*: seq[tuple[file: string, line: int]] ## `@raii` marker locations: the class / struct /
                                     ## class template declared just below each is an RAII OWNER
                                     ## type (unique_ptr / kir_owned_scalar) whose instances own a
                                     ## resource their destructor releases at scope exit
  raiiTypes*: HashSet[string]        ## the bound `@raii` owner class names (bare, no template
                                     ## args / namespace): a local of one of these types is an
                                     ## ikRaiiAlloc origin — movable, never a leak
  raiiVars*: Table[string, string]   ## decl USR -> owner class name for every RAII-owner
                                     ## variable lowered so far: a reassignment `y = std::move(x)`
                                     ## (an `operator=` call) re-owns y afresh and moves x out
  structOwnerFields*: Table[string, seq[tuple[name, cls: string]]] ## struct / class name -> its
                                     ## owner-typed fields (an `@raii` class or unique_ptr): a local /
                                     ## parameter of that struct carries one RAII origin per field
  structOwnerVars*: Table[string, seq[tuple[key, disp: string]]] ## struct variable USR -> the field-
                                     ## path keys of its owner fields, so `std::move(h)` moves them all
                                    ## (definite-assignment axis; resolved like spatialSites).
  typecheckSites*: seq[tuple[file: string, line: int]] ## `@typecheck` opt-in marker locations
                                    ## (tagged-union type-confusion axis; resolved like spatialSites).
  variantSites*: seq[tuple[file: string, line: int, spec: string]] ## `@variant(member : tag ==
                                    ## value)` sites — a union member is the active variant only when
                                    ## the discriminant `tag == value`. Resolved per function.
  variants*: Table[string, seq[tuple[memberExpr, tagExpr: string, value: int]]] ## funcname -> the
                                    ## RAW operand exprs of each `@variant`, resolved to keys in
                                    ## fnVisitor against the defining function's params (cross-file).
  curVariants*: Table[string, tuple[disp, tagKey, tagDisp: string, value: int]] ## member key ->
                                    ## (disp, the discriminant field + the value it must equal) for
                                    ## the function being lowered. scanVariantAccess consults it.
  stableScalars*: HashSet[string]
    ## CORRELATED BRANCHES: integer / enum locals and parameters this function never assigns
    ## after their declaration and never takes the address of. Their value cannot change between
    ## two tests of them, so a branch that learns one is a fact the whole rest of the path keeps —
    ## which is what makes `if (want) p = malloc(…); … if (want) free(p);` decidable, and the
    ## second of two `switch (type)` in a row analysable against the first.
  uninitLocals*: HashSet[string]    ## USRs of local scalar/pointer vars DECLARED without an
                                    ## initializer in the function being lowered — the reads of
                                    ## these are instrumented (ikInitRead) for the init pass.
  concurrentSites*: seq[tuple[file: string, line: int]] ## `@threadsafe` opt-in marker locations
                                    ## (lock-discipline axis; resolved like spatialSites — to a
                                    ## function below, or file-level). Gates `@guarded_by` access.
  guardedBySites*: seq[tuple[file: string, line: int, spec: string]] ## `@guarded_by(field: lock)`
                                    ## sites in the GATING form (a `:` present): the field is a data
                                    ## race unless `lock` is held at every access. Resolved per
                                    ## function. The single-arg form (`@guarded_by(lock)` on a struct
                                    ## member) is collected in guardedMemberSites and bound by type.
  guardedMemberSites*: seq[tuple[file: string, line: int, lockName: string]] ## single-arg
                                    ## `@guarded_by(lock)` sites — on a STRUCT MEMBER declaration, the
                                    ## sibling field `lock` guards it. resolveGuardedMembers binds each
                                    ## to the nearest field's decl USR; at an access `base->field` the
                                    ## lock `base->lock` must be held (the per-instance, type-bound
                                    ## version of the two-arg form). In a `@threadsafe` scope it GATES
                                    ## (UNGUARDED_ACCESS); otherwise it stays advisory.
  guardedMember*: Table[string, string] ## field-decl USR -> the sibling lock field's NAME, from a
                                    ## single-arg `@guarded_by(lock)`. scanGuardedAccess looks up the
                                    ## accessed field's decl USR here and synthesises `base->lock`.
  lockClassSites*: seq[tuple[file: string, line: int, name: string]] ## `@lock_class(X)` sites — on a
                                    ## lock DECLARATION (a global var), naming the lock's identity
                                    ## CLASS. Resolves the USR<->class so every acquire/contract keys
                                    ## by the author's class string (no USR / no same-name collision).
  varClass*: Table[string, string] ## lock var DECL USR -> its `@lock_class` name. lockKeyOf keys a
                                    ## classed global by the class (CHECKED: the mapping is derived
                                    ## from the decl, not trusted). Cross-file identity by class name.
  lockClasses*: HashSet[string]    ## the set of declared `@lock_class` names — a contract operand
                                    ## (`@acquires(X)` / `@lock_order(X < Y)`) that names one keys by it.
  fnCallsSites*: seq[tuple[file: string, line: int, spec: string]] ## `@calls(f, g, ...)` sites — on
                                    ## a function-pointer DECLARATION (var / field / param), naming
                                    ## the exhaustive set of functions it may point to (v3 stage 4).
  fnptrTargets*: Table[string, HashSet[string]] ## fnptr DECL USR -> its declared target function
                                    ## names. An indirect call resolves through it (an empty/absent
                                    ## set while holding a lock = UNDECLARED_INDIRECT_CALL); an
                                    ## assignment of a function outside it = UNDECLARED_FN_TARGET
                                    ## (the annotation-vs-implementation check). CHECKED, not trusted.
  fieldClass*: Table[string, string] ## lock FIELD DECL USR -> its `@lock_class` name (v3 stage 3).
                                    ## Unlike a global (keyed BY class so all instances collide), a field
                                    ## lock keys by INSTANCE (`<base-USR>::lock`) and merely CARRIES the
                                    ## class — so two distinct instances of the same class (`a->lock`,
                                    ## `b->lock`) are recognised as the same-class pair that needs a
                                    ## canonical acquire order (address ordering), not silently undecidable.
  lockAliasClass*: Table[string, string] ## local-pointer USR -> the lock CLASS it is a VERIFIED alias
                                    ## of (v3 stage 2). A pointer JOINS a class only by being assigned
                                    ## `&<classed-lock>` (unambiguously: every write is the same class
                                    ## and its address never escapes), so acquire/release through it
                                    ## keys by the class — cross-function order works through pointers,
                                    ## not just direct globals. CHECKED, not trusted (single-class def);
                                    ## an ambiguous pointer keeps USR keying (the existing residual).
  guardedBy*: Table[string, seq[tuple[fieldExpr, lockExpr: string]]] ## funcname -> the RAW operand
                                    ## exprs of `@guarded_by(field: lock)`, resolved to keys in
                                    ## fnVisitor against the DEFINING function's params (cross-file).
  curGuarded*: Table[string, tuple[disp, lockKey, lockDisp: string]] ## guarded field key ->
                                    ## (disp, the lock that must be held) for the function being
                                    ## lowered. scanGuardedAccess consults it at each field access.
  acquireSites*: seq[tuple[file: string, line: int, expr: string]] ## `@acquires(lock)` sites — in a
                                    ## `@threadsafe` scope a VERIFIED lock-balance contract (the lock
                                    ## is left held at exit); outside one it stays advisory (t42).
  releaseSites*: seq[tuple[file: string, line: int, expr: string]] ## `@releases(lock)` sites — in a
                                    ## `@threadsafe` scope the lock is held at entry and must be
                                    ## released before return; outside one it stays advisory.
  acquiresExprs*: Table[string, seq[string]] ## funcname -> RAW `@acquires` lock exprs (in a
                                    ## @threadsafe scope), resolved to keys in fnVisitor (cross-file).
  releasesExprs*: Table[string, seq[string]] ## funcname -> RAW `@releases` lock exprs (in a
                                    ## @threadsafe scope), resolved to keys in fnVisitor (cross-file).
  requiresLockSites*: seq[tuple[file: string, line: int, expr: string]] ## `@requires_lock(m)`
                                    ## sites — a callee precondition: every call site in a
                                    ## `@threadsafe` caller must hold `m`. Bound to the callee below.
  requiresLockByCallee*: Table[string, seq[string]] ## callee name -> the required lock DISPLAY
                                    ## names (matched against the caller's held-set by display, exact
                                    ## for global / file-scope locks). lowerCall emits a sink per call.
  kenbiSites*: seq[tuple[file: string, line: int]]  ## `@kenbi` opt-in marker locations
                                    ## (resolved to a function below, or file-level)
  spatialSites*: seq[tuple[file: string, line: int]]  ## `@spatial` opt-in marker locations
                                    ## (bounds axis; resolved like kenbiSites)
  countedBySites*: seq[tuple[file: string, line: int, spec: string]] ## `@counted_by(buf: size,
                                    ## …)` sites: declares a pointer/array PARAMETER is sized by
                                    ## another parameter (the `(ptr, len)` pair ubiquitous in C
                                    ## APIs). Resolved to per-function (bufKey -> sizeKey) pairs.
  countedBy*: Table[string, seq[tuple[bufExpr, sizeExpr: string, off: int]]] ## funcname ->
                                    ## the RAW operand exprs (`v->data`, `v->cap`) of `@counted_by`,
                                    ## resolved to keys in fnVisitor against the DEFINING function's
                                    ## params — so a contract declared on a header prototype binds to
                                    ## the implementation in another TU (cross-file). off = `+ k` size.
  invariantSites*: seq[tuple[file: string, line: int, spec: string]] ## `@invariant(lvalue rel
                                    ## expr)` sites: a declared data-structure invariant relating a
                                    ## PROTECTED field/var to a size (the jsmn `toknext <= num_tokens`).
  maintainsLines*: HashSet[int]     ## lines carrying `@maintains(...)` — a write here is a declared,
                                    ## invariant-preserving write (so it is not UNGUARDED_INVARIANT_WRITE).
  invariants*: Table[string, seq[tuple[lhsExpr, rel, rhsExpr: string]]] ## funcname -> the RAW
                                    ## operand exprs + relation (`<`/`<=`) of each UPPER `@invariant`,
                                    ## resolved to keys in fnVisitor against the DEFINING function's
                                    ## params (so a header-declared invariant binds to the impl).
  lowInvariants*: Table[string, seq[tuple[fieldExpr: string, lowConst: int]]]
                                    ## INVARIANT (C2): funcname -> LOWER invariants as the RAW field
                                    ## expr + constant (`@invariant(field >= c)` / `> c`). Resolved in
                                    ## fnVisitor (cross-file). A field may appear in both upper + lower.
  curProtectedLow*: Table[string, tuple[disp: string, lowConst: int]]
                                    ## protected field key -> (disp, the declared constant lower
                                    ## bound) for the function being lowered. The write-barrier and
                                    ## the lower @maintains preservation check (ikLowInvariantCheck)
                                    ## use this, in parallel with `curProtected` (upper).
  curProtected*: Table[string, tuple[disp, sizeKey, sizeDisp, rel: string,
                     sizeUnsigned: bool]] ## protected field key -> (disp, the size operand it
                                    ## is bounded by, the relation `<`/`<=`, and whether that
                                    ## size operand has an unsigned type) for the function being
                                    ## lowered. The write-barrier and the @maintains / @establish
                                    ## preservation checks use this. `sizeUnsigned` lets a
                                    ## `field = 0` SET establish `field <= size` (`0 <= size`).
  gotoNoreturnLines*: HashSet[int]  ## lines carrying `@goto_noreturn` — the label on (or
                                    ## just below) such a line is a non-returning terminus
  gotoFinallyLines*: HashSet[int]   ## lines carrying `@goto_finally` — the label on (or just
                                    ## below) such a line is the cleanup convergence funnel
  gotoBackwardLines*: HashSet[int]  ## lines carrying `@goto_backward` — the goto on that line
                                    ## is a declared loop back-edge (modelled via the fixpoint)
  callEdges*: seq[CallEdge]         ## ownership-relevant call edges of the function
                                    ## currently being lowered (reset per function in
                                    ## fnVisitor, then attached to its Func.calls)

const allocators* = ["malloc", "calloc", "realloc", "aligned_alloc", "strdup", "wcsdup", "strndup"]

const lockAcquirers* = ["pthread_mutex_lock", "pthread_spin_lock", "pthread_rwlock_wrlock",
                        "pthread_rwlock_rdlock", "mtx_lock"]
  ## CONCURRENCY: callee names that ACQUIRE the lock named by their first argument (`&m`).
  ## A recognised acquire makes the lock held on the path. (trylock is conditional — not here.)
const lockReleasers* = ["pthread_mutex_unlock", "pthread_spin_unlock", "pthread_rwlock_unlock",
                        "mtx_unlock"]
  ## CONCURRENCY: callee names that RELEASE the lock named by their first argument.
const lockTryAcquirers* = ["pthread_mutex_trylock", "pthread_spin_trylock",
                           "pthread_rwlock_trywrlock", "pthread_rwlock_tryrdlock", "mtx_trylock"]
  ## CONCURRENCY: callee names that CONDITIONALLY acquire the lock named by their first argument —
  ## they return 0 (success: lock HELD) or nonzero (failure: NOT held). The lock is therefore held
  ## only on the success branch, recognised via the enclosing `if` condition (parseTrylockCond),
  ## never as an unconditional ikLockAcquire. Re-trylocking a held lock does NOT deadlock (it
  ## returns EBUSY), so trylock is deliberately not a DOUBLE_LOCK site.

proc collectChildren*(parent: CXCursor): seq[CXCursor] =
  ## Immediate children, in source order (visitor returns continue, no recurse).
  var kids: seq[CXCursor]
  proc v(c, p: CXCursor, client: CXClientData): CXChildVisitResult {.cdecl.} =
    cast[ptr seq[CXCursor]](client)[].add c
    cvrContinue
  discard clang_visitChildren(parent, v, addr kids)
  kids

proc unwrap*(c: CXCursor): CXCursor =
  ## Peel transparent wrappers (UnexposedExpr / ParenExpr) and C-style casts to
  ## the real node. A cast like `(char *)malloc(...)` / `free((void*)p)` is
  ## transparent to pointer identity here, so we track its operand — the last
  ## child (after an optional TypeRef for a non-builtin target type). Without this
  ## the ubiquitous `(T *)malloc(...)` idiom hides the allocation from the engine.
  result = c
  while true:
    let k = clang_getCursorKind(result)
    if k == ckUnexposedExpr or k == ckParenExpr:
      let kids = collectChildren(result)
      if kids.len == 1: result = kids[0]
      else: break
    elif k == ckCStyleCastExpr:
      let kids = collectChildren(result)
      if kids.len >= 1: result = kids[^1]
      else: break
    else: break

proc commentBody*(text: string): string =
  ## Strip the `//` or `/* */` delimiters, returning the trimmed inner text.
  var s = text.strip()
  if s.startsWith("//"): s = s[2 .. ^1]
  elif s.startsWith("/*"):
    s = s[2 .. ^1]
    if s.endsWith("*/"): s = s[0 .. ^3]
  s.strip()
