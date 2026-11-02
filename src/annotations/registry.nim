## Annotation plugin registry. Collectors self-register by keyword, so adding /
## changing / removing an annotation is one self-contained module under
## annotations/ (+ one import line in annotations/all.nim). No edit to the
## dispatch, the engine, or a central case/Ctx is needed — this is where almost
## all contributor attention lands, so it is kept independent on purpose.
##
## Two registration styles:
##   * `registerCollector` — a custom handler (the collection IS the effect, e.g.
##     advisory annotations) or a decl-marker that writes the generic declMarkers.
##   * the declarative contract registrars (`registerArgContract` etc.) — for
##     ownership contracts whose effect is uniform: each just records the keyword
##     in a kind-table and wires the generic raw collector. The resolver in
##     frontend_c then binds raw sites to functions generically (no per-annotation
##     resolve proc). Adding an ownership contract is one line here, no engine edit.

import std/[tables, sets]
import ../cfront_core, ../ir

type
  AnnArgs* = object       ## everything a collector needs from one comment token
    kw*, body*, pa*, rest*, file*: string
    line*: int
  CollectProc* = proc(ctx: var Ctx, a: AnnArgs) {.nimcall.}

var
  collectors: Table[string, CollectProc]
  argContractKinds: Table[string, InstrKind]    ## keyword -> callsite arg instr
  bodyContractKinds: Table[string, InstrKind]   ## keyword -> body param seed instr
  returnContractKinds: Table[string, ReturnKind] ## keyword -> return-value kind
  funcFlagKws: Table[string, string]            ## keyword -> the func flag it sets
                                                ## ("must_use" / "nothrow")

proc registerCollector*(keyword: string, p: CollectProc) =
  ## Called at module-init time from each annotation plugin.
  collectors[keyword] = p

proc runCollector*(ctx: var Ctx, kw: string, a: AnnArgs): bool =
  ## Dispatch to a registered collector; true if one handled the keyword.
  if collectors.hasKey(kw):
    collectors[kw](ctx, a)
    return true
  false

proc registeredKeywords*(): seq[string] =
  ## Every directive keyword a plugin has registered a collector for (ownership /
  ## null-safety / advisory). The single source of truth for the plugin-provided
  ## half of the annotation vocabulary — consumed by `kenbi strip` so it removes
  ## exactly what `scanCommentTokens` recognises (no drift). Call after
  ## `registerBuiltinAnnotations()` so the table is populated.
  for k in collectors.keys: result.add k

# --- generic ownership-contract registration --------------------------------

proc rawCollector(ctx: var Ctx, a: AnnArgs) =
  ## Shared collector for every declarative contract keyword: it just records the
  ## raw site (keyword from `a.kw`); the resolver binds it to a function later.
  ctx.rawAnn.mgetOrPut(a.kw, @[]).add (a.file, a.line, a.pa)

proc ensureRawCollector(kw: string) =
  if not collectors.hasKey(kw): collectors[kw] = rawCollector

proc registerArgContract*(kw: string, instr: InstrKind) =
  ## `@frees(p)` -> ikFree, `@moves(p)` -> ikMove at the callsite arg `p`.
  argContractKinds[kw] = instr
  ensureRawCollector(kw)

proc registerBodyContract*(kw: string, instr: InstrKind) =
  ## `@frees(p)` -> ikObligation, `@borrows(p)` -> ikBorrow seeded on body param `p`.
  bodyContractKinds[kw] = instr
  ensureRawCollector(kw)

proc registerReturnContract*(kw: string, rk: ReturnKind) =
  ## `@owns` -> rcOwned, `@arena_alloc` -> rcArenaFromArg on the call's result.
  returnContractKinds[kw] = rk
  ensureRawCollector(kw)

proc registerFuncFlag*(kw: string, flag = "must_use") =
  ## `@must_use` -> a boolean flag on the function (discarded call = finding);
  ## `@nothrow` -> the "nothrow" flag (a call to it is not an unwinding exit).
  funcFlagKws[kw] = flag
  ensureRawCollector(kw)

# --- queries used by the generic resolver ------------------------------------

proc lookupArgContract*(kw: string): tuple[has: bool, instr: InstrKind] =
  if argContractKinds.hasKey(kw): (true, argContractKinds[kw]) else: (false, ikUse)

proc lookupBodyContract*(kw: string): tuple[has: bool, instr: InstrKind] =
  if bodyContractKinds.hasKey(kw): (true, bodyContractKinds[kw]) else: (false, ikUse)

proc lookupReturnContract*(kw: string): tuple[has: bool, kind: ReturnKind] =
  if returnContractKinds.hasKey(kw): (true, returnContractKinds[kw]) else: (false, rcOwned)

proc lookupFuncFlag*(kw: string): tuple[has: bool, name: string] =
  if funcFlagKws.hasKey(kw): (true, funcFlagKws[kw]) else: (false, "")
