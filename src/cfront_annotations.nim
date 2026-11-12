## Annotation collection for the libclang front-end: scan every non-system source
## file's comment tokens (main file + included user headers — header prototypes'
## contracts must be visible cross-file) and populate the parse context `Ctx`.
## Pure comment->Ctx; no statement lowering here. See cfront_core for `Ctx`.

import std/[strutils, sets, tables]
import ir, clang, cfront_core
import annotations/registry, annotations/all   # annotation plugins

proc parseMemComment(ctx: var Ctx, text: string, line: int) =
  ## Parse `@mem <scoped::name> { size: , free: , owner: }` from a comment.
  let at = text.find("@mem")
  if at < 0: return
  let braceOpen = text.find('{', at)
  if braceOpen < 0: return                 # `find('}', -1)` would be out of range
  let braceClose = text.find('}', braceOpen)
  if braceClose < 0: return
  let head = text[at+4 ..< braceOpen].splitWhitespace()
  if head.len < 1: return
  var res = Resource(name: head[0], declLine: line)
  for f in text[braceOpen+1 ..< braceClose].split(','):
    let kv = f.split(':')
    if kv.len != 2: continue
    case kv[0].strip()
    of "size":  res.sizeId = kv[1].strip()
    of "free":
      res.freeId = kv[1].strip()
      res.freeIds = @[res.freeId]
    of "owner": res.ownerId = kv[1].strip()
    of "link":  res.linkId = kv[1].strip()
    else: discard
  ctx.prog.resources[res.name] = res
  ctx.memByLine.add (line, res.name)
  if res.ownerId.len > 0: ctx.ownerRes[res.ownerId] = res.name

proc parseListComment(ctx: var Ctx, text: string, line: int) =
  ## `@list <Type> { link: <field> }` — a record type whose instances form an intrusive
  ## collection chained through `<field>`. One declaration covers every allocation of that
  ## type, whatever made it.
  let at = text.find("@list")
  if at < 0: return
  let braceOpen = text.find('{', at)
  if braceOpen < 0: return
  let braceClose = text.find('}', braceOpen)
  if braceClose < 0: return
  let head = text[at+5 ..< braceOpen].splitWhitespace()
  if head.len < 1: return
  let ty = (if head[0] == "struct" and head.len > 1: head[1] else: head[0])
  for f in text[braceOpen+1 ..< braceClose].split(','):
    let kv = f.split(':')
    if kv.len == 2 and kv[0].strip() == "link":
      ctx.listTypes[ty] = kv[1].strip()

# `@contract` block key -> the contract keyword it means. The same vocabulary as the inline
# annotations, so both forms resolve through one code path and mean exactly the same thing.
const contractKeys = {
  "frees":     "@frees",
  "borrows":   "@borrows",
  "moves":     "@moves",
  "adopts":    "@adopts",   ## the callee takes over the release; the object stays valid
  "owns":      "@owns",        ## no value: the RETURN is a fresh owned object
  "owns_out":  "@owns",        ## with a value: the callee allocates INTO that parameter
  "must_use":  "@must_use",
  "nothrow":   "@nothrow",
}.toTable

proc parseContractsForComment(ctx: var Ctx, text: string, file: string, line: int) =
  ## `@contracts_for <library> { version: <v>, requires: NAME=VALUE … }` — who these contracts
  ## are for, and what build they were written against. Shipping contracts for a library is
  ## only useful if the receiver can tell which version and which build conditions they
  ## describe; `requires` is then checked against the compile line, and `version` is reported
  ## as declared (kenbi cannot read a library's version out of source).
  let at = text.find("@contracts_for")
  if at < 0: return
  let braceOpen = text.find('{', at)
  let head = text[at+14 ..< (if braceOpen > 0: braceOpen else: text.len)].splitWhitespace()
  if head.len < 1: return
  var pkg = ContractPackage(name: head[0], file: file, line: line)
  if braceOpen > 0:
    let braceClose = text.find('}', braceOpen)
    if braceClose > 0:
      for f in text[braceOpen+1 ..< braceClose].split(','):
        let kv = f.split(':', 1)
        if kv.len != 2: continue
        case kv[0].strip()
        of "version": pkg.version = kv[1].strip()
        of "requires":
          for r in kv[1].splitWhitespace():
            let eq = r.find('=')
            if eq > 0: pkg.requires.add (name: r[0 ..< eq], value: r[eq+1 .. ^1])
            else: pkg.requires.add (name: r, value: "")   # bare NAME: must be defined
        else: discard
  ctx.prog.contractPackages.add pkg

proc parseContractComment(ctx: var Ctx, text: string, line: int) =
  ## `@contract <Fn> { frees: p, borrows: q r, owns }` — the ownership contract of a function
  ## named BY NAME. The inline forms (`@frees(p)` above the declaration) cannot reach a project
  ## you may not edit: there is nowhere to put the comment. This form can live in a
  ## comment-only overlay header, like `@allocator` and `@list`.
  ##
  ## Keys may repeat and may list several parameters (`borrows: image exception`); a key with no
  ## value is the whole-function form (`owns` = the return is owned; `must_use`; `nothrow`).
  ## Parameter names are matched against the signature kenbi collects, and the accessor forms
  ## the inline annotations accept (`*p`, `p->f`, `arr[2]`) work here too.
  let at = text.find("@contract")
  if at < 0: return
  let braceOpen = text.find('{', at)
  if braceOpen < 0: return
  let braceClose = text.find('}', braceOpen)
  if braceClose < 0: return
  let head = text[at+9 ..< braceOpen].splitWhitespace()
  if head.len < 1: return
  let fn = head[0]
  for f in text[braceOpen+1 ..< braceClose].split(','):
    let kv = f.split(':', 1)
    let key = kv[0].strip()
    if key.len == 0: continue
    if key notin contractKeys:
      ctx.prog.advisories.add Advisory(line: line, code: "UNKNOWN_CONTRACT_KEY",
        msg: "`@contract " & fn & "` names '" & key & "', which is not a contract kenbi " &
             "knows. Keys: frees, borrows, moves, owns, owns_out, must_use, nothrow.")
      continue
    let kw = contractKeys[key]
    if kv.len == 1 or kv[1].strip().len == 0:
      ctx.namedContracts.add (fn, kw, "")           # whole-function form
    else:
      for p in kv[1].splitWhitespace():
        ctx.namedContracts.add (fn, kw, p)

proc parseAllocatorComment(ctx: var Ctx, text: string, line: int) =
  ## Parse `@allocator <scoped::name> { alloc: f g h, free: r, realloc: z }` — a project's OWN
  ## allocator family, declared once (in the header everyone includes) instead of a `@mem` at
  ## every call site. Nearly every C project wraps malloc; until its wrappers are declared,
  ## kenbi has no vocabulary for them and says nothing about that memory. Several names may be
  ## listed per field, whitespace-separated. `free:` also registers the deallocator, so the
  ## resource's declared release is checked (a different release fn is WRONG_DEALLOCATOR).
  let at = text.find("@allocator")
  if at < 0: return
  let braceOpen = text.find('{', at)
  if braceOpen < 0: return
  let braceClose = text.find('}', braceOpen)
  if braceClose < 0: return
  let head = text[at+10 ..< braceOpen].splitWhitespace()
  if head.len < 1: return
  var res = Resource(name: head[0], declLine: line)
  var allocFns, reallocFns: seq[string]
  for f in text[braceOpen+1 ..< braceClose].split(','):
    let sep = f.find(':')
    if sep < 0: continue
    let key = f[0 ..< sep].strip()
    let vals = f[sep+1 .. ^1].splitWhitespace()
    case key
    of "alloc":   allocFns.add vals
    of "realloc": reallocFns.add vals
    of "free":
      if vals.len > 0 and res.freeId.len == 0: res.freeId = vals[0]
      res.freeIds.add vals            # every declared release is accepted, not just the first
      for v in vals: ctx.deallocators.incl v
    of "frees_fields":
      # a typed destroy wrapper releases the object's owned FIELDS too, so freeing the
      # container is not abandoning them. Listed names must also appear in `free:` /
      # `free_returns_null:` to be recognised as releases at all.
      for v in vals: ctx.prog.deepFrees.incl v
    of "free_returns_null":
      # `p = release(p)` — the release hands back NULL (ImageMagick's whole memory API, and a
      # common house style). Declaring it lets kenbi see that p owns nothing afterwards
      # instead of treating the next release of p as a double free.
      if vals.len > 0 and res.freeId.len == 0: res.freeId = vals[0]
      res.freeIds.add vals            # every declared release is accepted, not just the first
      for v in vals:
        ctx.deallocators.incl v
        ctx.freeReturnsNull.incl v
        res.nullingFreeIds.add v
    else: discard
  if allocFns.len == 0 and reallocFns.len == 0: return
  res.allocIds = allocFns
  res.reallocIds = reallocFns
  ctx.prog.resources[res.name] = res
  for f in allocFns: ctx.customAllocRes[f] = res.name
  for f in reallocFns:
    ctx.customRealloc.incl f
    ctx.customAllocRes[f] = res.name          # `p = resize(NULL, n)` is a fresh allocation

proc parseArenaComment(ctx: var Ctx, text: string, line: int) =
  ## Parse `@arena <name> { create: f, alloc: g, free: h }`. Registers a resource
  ## (the arena, owned and freed by `h`), records the create-fn (a factory for the
  ## arena) and the alloc-fn (whose result borrows from the arena passed as arg 1).
  let at = text.find("@arena")
  if at < 0: return
  let braceOpen = text.find('{', at)
  if braceOpen < 0: return                 # `find('}', -1)` would be out of range
  let braceClose = text.find('}', braceOpen)
  if braceClose < 0: return
  let head = text[at+6 ..< braceOpen].splitWhitespace()
  if head.len < 1: return
  var res = Resource(name: head[0], declLine: line)
  var createFn, allocFn = ""
  for f in text[braceOpen+1 ..< braceClose].split(','):
    let kv = f.split(':')
    if kv.len != 2: continue
    case kv[0].strip()
    of "create": createFn = kv[1].strip()
    of "alloc":  allocFn = kv[1].strip()
    of "free":
      res.freeId = kv[1].strip()
      res.freeIds = @[res.freeId]
    else: discard
  if createFn.len > 0: res.allocIds.add createFn   # what produces the ARENA itself
  ctx.prog.resources[res.name] = res
  if createFn.len > 0: ctx.arenaCreate[createFn] = res.name
  if allocFn.len > 0: ctx.arenaAlloc.incl allocFn


const engineCoreDirectives* = [
  ## The directive keywords handled INLINE by the `case kw` in scanCommentTokens
  ## (the engine-core half of the vocabulary; the other half is plugin-registered,
  ## queried via registeredKeywords()). KEEP IN SYNC with the `case kw` below.
  ## `allKenbiDirectives()` unions both halves; `kenbi strip` uses it so it removes
  ## exactly the comments kenbi recognises. Internal IR tags (@mask/@opaque/
  ## @backward) are NOT here — they never appear in source comments.
  "@kenbi", "@verify", "@spatial", "@threadsafe", "@initcheck", "@typecheck", "@variant",
  "@counted_by", "@invariant", "@maintains", "@mem", "@move", "@goto_noreturn",
  "@goto_finally", "@goto_backward", "@copy", "@unsafe", "@escapes", "@realloc", "@raii", "@arena",
  "@allocator", "@lock_order", "@drains", "@list", "@contract", "@contracts_for"]

proc allKenbiDirectives*(): HashSet[string] =
  ## The COMPLETE set of directive keywords kenbi recognises as the first token of
  ## a comment body: the plugin-registered ones (registeredKeywords) ∪ the inline
  ## engine-core ones (engineCoreDirectives). The single source of truth for
  ## `kenbi strip`, so stripping matches recognition exactly (no drift as
  ## annotations are added/removed). Idempotently ensures plugins are registered.
  registerBuiltinAnnotations()
  for k in registeredKeywords(): result.incl k
  for k in engineCoreDirectives: result.incl k

proc scanCommentTokens(ctx: var Ctx, toks: ptr CXToken, n: cuint) =
  ## Process one file's comment tokens. An annotation is only recognised when its
  ## keyword is the FIRST token of the comment body (`// @move x`, `/* @mem ... */`).
  ## Prose that merely mentions "@copy" or "@move" is not a directive and must not fire.
  let arr = cast[ptr UncheckedArray[CXToken]](toks)
  for i in 0 ..< int(n):
    if clang_getTokenKind(arr[i]) != tkComment: continue
    let loc = clang_getTokenLocation(ctx.tu, arr[i])
    let line = lineOf(loc)
    let body = commentBody($clang_getTokenSpelling(ctx.tu, arr[i]))
    let words = body.splitWhitespace()
    if words.len == 0: continue
    let kw = words[0].split('(')[0]   # `@frees(p)` -> `@frees`
    let pa = block:                   # paren argument from the whole body (may contain spaces)
      let op = body.find('('); let cp = body.find(')')
      if op >= 0 and cp > op: body[op+1 ..< cp].strip else: ""
    let rest = body[words[0].len .. ^1].strip  # freeform text after the keyword token
    # plugin annotations (annotations/*.nim) self-register and handle their keyword;
    # only the engine-core directives below remain inline.
    if runCollector(ctx, kw, AnnArgs(kw: kw, body: body, pa: pa, rest: rest, file: fileOf(loc), line: line)):
      continue
    case kw
    of "@verify":
      if not body.startsWith("@verify(") or not body.endsWith(")") or pa.len == 0 or
          '(' in pa or ')' in pa:
        raise newException(CFrontError, fileOf(loc) & ":" & $line & ": expected @verify(profile)")
      ctx.prog.effectMarkers.add (fileOf(loc), pa, line,
        offsetOf(clang_getRangeEnd(clang_getTokenExtent(ctx.tu, arr[i]))))
    of "@kenbi":
      # opt-in marker: this unit is under kenbi discipline. Resolved later to the
      # function below it (function-level) or, if none is near, the whole file.
      ctx.kenbiSites.add (fileOf(loc), line)
      ctx.prog.hasKenbiMarker = true
    of "@spatial":
      # opt-in marker for the SEPARATE bounds axis: this unit is bounds-checked
      # (an unvalidated value reaching an index / size sink is UNVALIDATED_INDEX).
      # Independent of @kenbi so temporal-only files are never bounds-checked.
      ctx.spatialSites.add (fileOf(loc), line)
    of "@threadsafe":
      # opt-in marker for the SEPARATE lock-discipline axis: this unit is lock-checked
      # (a `@guarded_by(field: lock)` access without the lock held is UNGUARDED_ACCESS).
      # Independent of the other axes so non-concurrent files are never lock-checked.
      ctx.concurrentSites.add (fileOf(loc), line)
    of "@initcheck":
      # opt-in marker for the SEPARATE definite-assignment axis: a read of a local that is
      # not definitely assigned on every path is USE_OF_UNINITIALIZED. Independent opt-in so
      # existing files are never init-checked.
      ctx.initSites.add (fileOf(loc), line)
    of "@typecheck":
      # opt-in marker for the SEPARATE tagged-union type-confusion axis: a `@variant` member
      # accessed without its discriminant proven is TYPE_CONFUSION. Independent opt-in.
      ctx.typecheckSites.add (fileOf(loc), line)
    of "@variant":
      # declare a tagged-union variant: `@variant(member : tag == value)` — `member` is the
      # active union member only when the discriminant `tag == value`.
      ctx.variantSites.add (fileOf(loc), line, pa)
    of "@counted_by":
      # declare a pointer/array PARAMETER's size as another parameter — the `(ptr, len)`
      # pair (`@counted_by(js: len, tokens: num_tokens)`). Resolved to the function below
      # it; seeds the buffer's symbolic size so a bound naming the size param covers it.
      ctx.countedBySites.add (fileOf(loc), line, pa)
    of "@invariant":
      # declare a data-structure invariant relating a PROTECTED field/var to a size
      # (`@invariant(parser->toknext <= num_tokens)`). The protected field is then a
      # tracked resource: every write to it must be `@maintains`-annotated (or RED), and
      # the relation may green an access bounded by it.
      ctx.invariantSites.add (fileOf(loc), line, pa)
    of "@maintains":
      # this write (line) preserves a declared invariant — so it is not an unguarded
      # write. The preservation is VERIFIED, not trusted (a lie is CONTRACT_NOT_HONORED).
      ctx.maintainsLines.incl line
    of "@mem":   ctx.parseMemComment(body, line)
    of "@move":  ctx.moveLines.add line
    of "@goto_noreturn":
      # the label on this line (or just below it) is a non-returning terminus
      # (abort/exit/longjmp); paths reaching it terminate, so they are not leaks.
      ctx.gotoNoreturnLines.incl line
    of "@goto_finally":
      # the label on this line (or just below it) is the cleanup convergence funnel:
      # owning exits that bypass it are FINALLY_BYPASSED (route them via `goto`).
      ctx.gotoFinallyLines.incl line
    of "@goto_backward":
      # the goto on this line is a declared loop back-edge — modelled as a loop
      # (bounded fixpoint) instead of being refused as an unstructured goto-loop.
      ctx.gotoBackwardLines.incl line
    of "@copy":     ctx.copyLines[line] = (if words.len > 1: words[1] else: "")
    of "@unsafe":   ctx.prog.quarantined.incl line
    of "@escapes":  ctx.prog.escapesLines.incl line
    of "@realloc":  ctx.prog.reallocLines.incl line
    of "@raii":
      # the class / struct / class template declared just below is an RAII OWNER type: its
      # instances own a resource released by the destructor (unique_ptr / kir_owned_scalar).
      # Declared, not inferred from the class body. Resolved to the decl in resolveRaiiTypes.
      # `@raii(Name)` names the class directly (its declaration may live in a header this
      # comment cannot sit above — the binding wrapper's .cpp declares the discipline).
      if pa.len > 0: ctx.raiiNames.incl pa.strip
      else: ctx.raiiSites.add (fileOf(loc), line)
    of "@drains":
      # `@drains(head)` on a loop: the loop releases EVERY element of the intrusive collection
      # rooted at `head` (a resource that declares `link:`). Verified, not trusted — a loop
      # that releases nothing is CONTRACT_NOT_HONORED, and after the drain every cursor on the
      # collection dangles. The marker may sit on the loop's own line or the line above it.
      if pa.len > 0: ctx.drainLines[line] = pa.strip
      elif words.len > 1: ctx.drainLines[line] = words[1]
    of "@contracts_for":
      # the identity of a shipped contract set: which library, which version, which build
      # conditions. `requires` is checked against the compile line; `version` is declared only.
      ctx.parseContractsForComment(body, fileOf(loc), line)
    of "@contract":
      # `@contract <Fn> { frees: p, … }` — an ownership contract declared by NAME, so a project
      # kenbi may not edit can be contracted from a comment-only overlay. Resolved through the
      # same binding as the inline form, body obligation included: still checked, not trusted.
      ctx.parseContractComment(body, line)
    of "@list":
      # `@list <Type> { link: <field> }` — objects of that record type are NODES of an
      # intrusive collection chained through that field. Declared on the TYPE rather than on
      # one `@mem` site, so it also covers allocations made through a project's own
      # `@allocator` family (where there is no per-site resource to hang it on).
      ctx.parseListComment(body, line)
    of "@arena":    ctx.parseArenaComment(body, line)
    of "@allocator": ctx.parseAllocatorComment(body, line)
    # @lock_order also records state (ctx.lockOrders) for the conflict pass, so it
    # stays inline; the pure-advisory directives are now plugins (annotations/advisory.nim).
    of "@lock_order":
      let parts = pa.split('<')
      if parts.len == 2:
        let a = parts[0].strip
        let b = parts[1].strip
        ctx.lockOrders.add (line, a, b)
        ctx.prog.advisories.add Advisory(line: line, code: "LOCK_ORDER",
          msg: "advisory: acquire '" & a & "' before '" & b & "'. Reviewer: verify no path " &
               "acquires them in the reverse order (deadlock risk).")
      else:
        ctx.prog.advisories.add Advisory(line: line, code: "LOCK_ORDER",
          msg: "advisory: lock order '" & pa & "' (expected form `a < b`).")
    else: discard

proc collectAnnotations*(ctx: var Ctx) =
  ## Scan every non-system source file in the TU — the main file AND included user
  ## headers — for annotations. Header prototypes' contracts (e.g. `@arena_alloc`)
  ## must be visible cross-file; tokenizing only the main file misses them, and
  ## libclang attaches only `///` / `/** */` doc comments to decls, not plain `//`.
  registerBuiltinAnnotations()   # idempotent: ensure annotation plugins are registered
  var files = initHashSet[string]()
  for c in collectChildren(clang_getTranslationUnitCursor(ctx.tu)):
    let loc = clang_getCursorLocation(c)
    if clang_Location_isInSystemHeader(loc) != 0: continue
    let f = fileOf(loc)
    if f.len > 0: files.incl f
  # ... and every other file the TU includes. A file that DECLARES nothing has no cursor in
  # it, so the walk above never sees it — which silently ignored the declarations in a
  # project's annotation overlay (a comment-only header, force-included with `-include`).
  var incState = (tu: ctx.tu, files: addr files)
  proc inclusion(included: CXFile, stack: ptr CXSourceLocation,
                 stackLen: cuint, client: CXClientData) {.cdecl.} =
    if included.isNil: return
    let st = cast[ptr tuple[tu: CXTranslationUnit, files: ptr HashSet[string]]](client)
    if clang_Location_isInSystemHeader(clang_getLocationForOffset(st.tu, included, 0)) != 0: return
    let name = fileName(included)
    if name.len > 0: st.files[].incl name
  clang_getInclusions(ctx.tu, inclusion, addr incState)
  for path in files:
    let cxfile = clang_getFile(ctx.tu, path.cstring)
    if cxfile.isNil: continue
    var size: csize_t
    discard clang_getFileContents(ctx.tu, cxfile, addr size)
    if size == 0: continue
    let rng = clang_getRange(clang_getLocationForOffset(ctx.tu, cxfile, 0),
                             clang_getLocationForOffset(ctx.tu, cxfile, cuint(size)))
    var toks: ptr CXToken
    var n: cuint
    clang_tokenize(ctx.tu, rng, addr toks, addr n)
    ctx.scanCommentTokens(toks, n)
    clang_disposeTokens(ctx.tu, toks, n)

proc detectLockOrderConflicts*(ctx: var Ctx) =
  ## Deterministic bonus on the advisory `@lock_order` declarations: if one says
  ## `a < b` and another says `b < a`, that pair is a declared deadlock
  ## (the conflict is pairwise, no cycle search needed). Stays advisory
  ## (never a gate). Emitted once per conflicting pair, at the later line.
  for i in 0 ..< ctx.lockOrders.len:
    for j in i + 1 ..< ctx.lockOrders.len:
      let x = ctx.lockOrders[i]
      let y = ctx.lockOrders[j]
      if x.a == y.b and x.b == y.a:
        ctx.prog.advisories.add Advisory(line: max(x.line, y.line), code: "LOCK_ORDER_CONFLICT",
          msg: "advisory: declared lock orders conflict ('" & x.a & " < " & x.b & "' vs '" &
               y.a & " < " & y.b & "') — acquiring them concurrently in opposite orders deadlocks.")
