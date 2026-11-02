## Advisory annotations: lock-discipline / freeform intents the deterministic
## engine does NOT decide. Each emits a `severity: advisory` finding for the
## AI/human review layer (never gates). A self-contained plugin: to add one,
## write the handler and a registerCollector line in registerAdvisory.

import registry, ../cfront_core, ../ir

proc guardedBy(ctx: var Ctx, a: AnnArgs) =
  ## Two forms, BOTH gating in a `@threadsafe` scope. `@guarded_by(field: lock)` (a `:` present)
  ## binds per FUNCTION (the field/lock operands resolve to keys against the function's params).
  ## The single-arg `@guarded_by(lock)` on a STRUCT MEMBER binds per TYPE: the sibling field
  ## `lock` guards the annotated member, so an access `base->member` must hold `base->lock`.
  ## resolveGuardedMembers binds it (and falls back to advisory outside a `@threadsafe` scope).
  if ':' in a.pa:
    ctx.guardedBySites.add (a.file, a.line, a.pa)
  else:
    ctx.guardedMemberSites.add (a.file, a.line, a.pa)

proc requiresLock(ctx: var Ctx, a: AnnArgs) =
  ## A cross-function lock precondition. The site is recorded so the lock-balance pass can
  ## VERIFY every call site in a `@threadsafe` caller holds the lock (REQUIRED_LOCK_NOT_HELD).
  ## The advisory is still emitted (it sits on the callee decl, not a @threadsafe-gated site) so
  ## a non-thread-safe consumer / a bare prototype keeps the old reviewer hint (t42).
  ctx.requiresLockSites.add (a.file, a.line, a.pa)
  ctx.prog.advisories.add Advisory(line: a.line, code: "REQUIRES_LOCK",
    msg: "advisory: callers must already hold '" & a.pa &
         "' when calling this. Reviewer: verify every call site holds it.")

proc acquires(ctx: var Ctx, a: AnnArgs) =
  ## In a `@threadsafe` scope this becomes a VERIFIED lock-balance contract (the lock is left
  ## held at exit — an intentional hand-off, not a leak). Outside one it stays advisory. The
  ## site is recorded here; resolveLockContracts decides which, once @threadsafe is resolved.
  ctx.acquireSites.add (a.file, a.line, a.pa)

proc releases(ctx: var Ctx, a: AnnArgs) =
  ## In a `@threadsafe` scope the lock is held at entry (the caller's contract) and must be
  ## released before return; outside one it stays advisory. See acquires.
  ctx.releaseSites.add (a.file, a.line, a.pa)

proc llm(ctx: var Ctx, a: AnnArgs) =
  ctx.prog.advisories.add Advisory(line: a.line, code: "LLM_REVIEW",
    msg: "advisory (author note for AI review): " & a.rest)

proc lockClass(ctx: var Ctx, a: AnnArgs) =
  ## `@lock_class(X)` on a lock DECLARATION names the lock's identity class. resolveLockClasses
  ## binds it to the declared lock (CHECKED: derived from the decl, not trusted) so every acquire
  ## and contract keys by the author's class string X — sidestepping USR/display ambiguity and
  ## `static` same-name collisions, and making cross-function / cross-file identity stable.
  if a.pa.len > 0: ctx.lockClassSites.add (a.file, a.line, a.pa)

proc calls(ctx: var Ctx, a: AnnArgs) =
  ## `@calls(f, g, ...)` on a function-pointer DECLARATION names the exhaustive set of functions it
  ## may point to. resolveFnptrTargets binds it to the nearest fnptr decl; an indirect call then
  ## resolves through the set (CHECKED: an assignment outside it is UNDECLARED_FN_TARGET, and a
  ## lock-holding call through a pointer with no set is UNDECLARED_INDIRECT_CALL — v3 stage 4).
  if a.pa.len > 0: ctx.fnCallsSites.add (a.file, a.line, a.pa)

proc registerAdvisory* =
  registerCollector("@guarded_by", guardedBy)
  registerCollector("@requires_lock", requiresLock)
  registerCollector("@acquires", acquires)
  registerCollector("@releases", releases)
  registerCollector("@lock_class", lockClass)
  registerCollector("@calls", calls)
  registerCollector("@llm", llm)
