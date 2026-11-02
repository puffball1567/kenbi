## Finite path exploration of externally specified resource protocols.
import std/[json, tables, sets, strutils, algorithm, math]
import ir, safety_config

type
  ProtocolResult* = object
    findings*, sourceAccessEvidence*, pointerFormationEvidence*: seq[JsonNode]
    capacityEvidence*, accessCapacityEvidence*: seq[JsonNode]
    alignmentEvidence*, accessAlignmentEvidence*: seq[JsonNode]
    regionEvidence*, mmioEvidence*, resourceEvidence*: seq[JsonNode]
    assumptions*: HashSet[string]     ## external premises the checked accesses rely on
    unverified*, violation*: bool
  Loan = object
    origin, resource, mode, protocol, file: string
    line: int
    chain: seq[string]
    lo, hi: BiggestInt            ## the borrowed bytes, when rangeKnown
    rangeKnown: bool
    marksOnRelease: seq[string]
  Span = tuple[lo, hi: BiggestInt]
  MarkBytes = object
    ## Where a mark holds on one storage object. `definite` bytes certainly carry it; `possible`
    ## bytes may (a superset of definite), and `possibleAll` means it may hold anywhere. The two
    ## are kept apart so an uncertain operation never turns into either a false acceptance or a
    ## false accusation: a requirement is met only on definite bytes, a prohibition is violated
    ## only on definite bytes, and everything in between is unverified.
    definite, possible: seq[Span]
    possibleAll: bool
  StorageRange = object
    size, offset, alignment: BiggestInt
    known, invalid: bool
    atStart: bool                     ## still the pointer an allocation returned, even if the size is unknown
  Path = object
    env: Table[string, string]
    nullPointers: HashSet[string]
    extents: Table[string, StorageRange]
    permissions: Table[string, string]
    states: Table[string, string]
    loans: Table[string, Loan]
    marks: Table[string, MarkBytes]   ## key: origin & "\0" & mark id
    dead: HashSet[string]
    allocators: Table[string, string] ## allocated origin -> the contract symbol that allocated it
    allocatedBytes: Table[string, BiggestInt]  ## allocated origin -> its size, -1 when not a constant
    untrackedLive: bool               ## an allocated object still live lost its identity to a later one
    unfenced: HashSet[string]         ## barrier kinds not yet issued since the last memory write;
                                      ## "?kind": the caller may have written before entry
    values: Table[string, string]
    lastResult, returnValue: string
    returnedPointer, returnedPointerKind: string
    lastPointer, lastPointerKind: string
    returnedExtent, lastPointerExtent: StorageRange
    returnedPointerLine: int
    outerRefs: HashSet[string]        ## origins bound in the callers' frames, invisible in `env`
    flow: string

proc shiftedRange(extent: StorageRange, delta: BiggestInt): StorageRange =
  result = extent
  if delta != 0: result.atStart = false
  if result.invalid or not result.known: return
  if delta < -result.offset or delta > result.size - result.offset:
    result.invalid = true
  else:
    result.offset += delta

proc alignmentStatus(extent: StorageRange, required: int): string =
  if extent.invalid: return "violation"
  if extent.known and extent.alignment > 0:
    let common = gcd(extent.alignment, BiggestInt(required))
    if extent.offset mod common != 0: return "violation"
    if extent.alignment mod required == 0: return "verified"
  "unverified"

proc addSpan(spans: var seq[Span], s: Span) =
  if s.hi <= s.lo: return
  var merged = s
  var kept: seq[Span]
  for t in spans:
    if t.hi < merged.lo or t.lo > merged.hi: kept.add t
    else: merged = (min(t.lo, merged.lo), max(t.hi, merged.hi))
  kept.add merged
  kept.sort(proc (a, b: Span): int = cmp(a.lo, b.lo))
  spans = kept

proc subSpan(spans: var seq[Span], s: Span) =
  var kept: seq[Span]
  for t in spans:
    if t.hi <= s.lo or t.lo >= s.hi: kept.add t
    else:
      if t.lo < s.lo: kept.add (t.lo, s.lo)
      if t.hi > s.hi: kept.add (s.hi, t.hi)
  spans = kept

proc covers(spans: seq[Span], s: Span): bool =
  if s.hi <= s.lo: return true
  for t in spans:
    if t.lo <= s.lo and t.hi >= s.hi: return true
  false

proc spansJson(spans: seq[Span]): JsonNode =
  result = newJArray()
  for t in spans: result.add %*[t.lo, t.hi]

proc touches(spans: seq[Span], s: Span): bool =
  for t in spans:
    if t.lo < s.hi and s.lo < t.hi: return true
  false

proc checkProtocols*(cfg: SafetyConfig, functions: Table[string, EffectFunction],
                     root: string, selected: seq[string], checkMemory = false,
                     heapBudget = -1.BiggestInt): ProtocolResult =
  var outcome: ProtocolResult
  var emitted = initHashSet[string]()
  var steps = 0
  let memoryAccessEnabled = cfg.requiresMemoryAccess or checkMemory
  var asyncEnabled = false
  for id in selected:
    for operation in cfg.protocols[id].operations:
      for op in variants(operation):
        if op.borrowArgument > 0: asyncEnabled = true
  proc report(code, status, message: string, fn: EffectFunction, line: int, chain: seq[string], details: JsonNode = nil, observedResult = "", boundaryProtocol = "", boundaryArgument = 0, stateRequirement: JsonNode = nil, capacityRequirement: JsonNode = nil, alignmentRequirement: JsonNode = nil, memoryPermission: JsonNode = nil, pointerDifference: JsonNode = nil, pointerComparison: JsonNode = nil, markRequirement: JsonNode = nil, regionRequirement: JsonNode = nil) =
    let item = %*{"code": code, "status": status, "message": message,
      "file": fn.file, "line": line, "callChain": chain}
    if not markRequirement.isNil: item["markRequirement"] = markRequirement
    if not regionRequirement.isNil: item["regionRequirement"] = regionRequirement
    if not pointerComparison.isNil: item["pointerComparison"] = pointerComparison
    if not pointerDifference.isNil: item["pointerDifference"] = pointerDifference
    if not memoryPermission.isNil: item["memoryPermission"] = memoryPermission
    if not alignmentRequirement.isNil: item["alignmentRequirement"] = alignmentRequirement
    if not capacityRequirement.isNil: item["capacityRequirement"] = capacityRequirement
    if not stateRequirement.isNil: item["stateRequirement"] = stateRequirement
    if observedResult.len > 0: item["returnResult"] = %observedResult
    if not details.isNil: item["borrow"] = details
    if "BOUNDARY" in code and chain.len > 0 and chain[^1] in cfg.boundaries:
      let boundaries = cfg.boundaries[chain[^1]]
      for boundary in boundaries:
        if boundaries.len == 1 or (boundary.protocol == boundaryProtocol and boundary.argument == boundaryArgument):
          item["boundary"] = %*{"symbol": boundary.symbol, "protocol": boundary.protocol,
            "source": boundary.origin, "argument": boundary.argument,
            "entry": boundary.entry, "exit": boundary.exit, "outcomes": boundary.outcomes}
      if not item.hasKey("boundary"): item["boundaries"] = %boundaries
    if $item notin emitted:
      emitted.incl $item
      outcome.findings.add item
    if status == "violation": outcome.violation = true
    else: outcome.unverified = true
  proc resolve(arg: JsonNode, path: Path): string =
    case arg["kind"].getStr
    of "address": path.env.getOrDefault("&" & arg["symbol"].getStr)
    of "pointer": path.env.getOrDefault(arg["symbol"].getStr)
    of "lastPointer": path.lastPointer
    else: ""
  proc availableRange(arg: JsonNode, path: Path): StorageRange =
    case arg["kind"].getStr
    of "address": result = path.extents.getOrDefault("&" & arg["symbol"].getStr)
    of "pointer": result = path.extents.getOrDefault(arg["symbol"].getStr)
    of "lastPointer": result = path.lastPointerExtent
    else: discard
    if arg.hasKey("offsets"):
      for step in arg["offsets"]:
        if result.invalid: break
        if step.kind != JInt:
          result.known = false
          result.atStart = false
        elif result.known:
          result = shiftedRange(result, step.getBiggestInt)
        elif step.getBiggestInt != 0:
          result.atStart = false
  proc pointerKind(arg: JsonNode, path: Path): string =
    if arg["kind"].getStr == "null" or
        (arg["kind"].getStr == "pointer" and arg["symbol"].getStr in path.nullPointers) or
        (arg["kind"].getStr == "lastPointer" and path.lastPointerKind == "null"): return "null"
    if resolve(arg, path).len > 0: return "origin"
    "unknown"
  proc signature(path: Path): string =
    var parts: seq[string]
    for key, value in path.extents: parts.add $(%*["extent", key, value])
    for key, value in path.permissions: parts.add $(%*["permission", key, value])
    for key, value in path.states: parts.add $(%*["state", key, value])
    for key, value in path.env: parts.add $(%*["binding", key, value])
    for key, loan in path.loans: parts.add $(%*["loan", key, loan.origin, loan.resource, loan.mode])
    for origin in path.dead: parts.add $(%*["dead", origin])
    for origin, allocator in path.allocators: parts.add $(%*["allocator", origin, allocator])
    for origin, bytes in path.allocatedBytes: parts.add $(%*["allocated", origin, bytes])
    parts.add $(%*["untrackedLive", path.untrackedLive])
    for kind in path.unfenced: parts.add $(%*["unfenced", kind])
    for key, m in path.marks: parts.add $(%*["mark", key, spansJson(m.definite), spansJson(m.possible), m.possibleAll])
    for symbol in path.nullPointers: parts.add $(%*["null", symbol])
    for origin in path.outerRefs: parts.add $(%*["outer", origin])
    for origin, value in path.values: parts.add $(%*["value", origin, value])
    parts.add $(%*["results", path.lastResult, path.returnValue])
    parts.add $(%*["pointerReturn", path.returnedPointer, path.returnedPointerKind, path.returnedPointerLine])
    parts.add $(%*["pointerResults", path.lastPointer, path.lastPointerKind, path.lastPointerExtent, path.returnedExtent])
    parts.sort()
    $(%parts) & path.flow
  proc valueOf(expr: JsonNode, path: Path): string =
    if expr.isNil: return "unknown"
    case expr["kind"].getStr
    of "constant": return expr["value"].getStr
    of "variable": return path.values.getOrDefault(path.env.getOrDefault("&" & expr["symbol"].getStr), "unknown")
    of "pointerTruth":
      let arg = expr["value"]
      if pointerKind(arg, path) == "null": return "zero"
      let extent = availableRange(arg, path)
      let origin = resolve(arg, path)
      if origin.len > 0 and origin notin path.dead and extent.known and not extent.invalid: return "nonzero"
      return "unknown"
    of "lastCall": return if path.lastResult.len == 0: "unknown" else: path.lastResult
    of "choice":
      let condition = valueOf(expr["condition"], path)
      if condition == "nonzero": return valueOf(expr["then"], path)
      if condition == "zero": return valueOf(expr["else"], path)
      let yes = valueOf(expr["then"], path)
      let no = valueOf(expr["else"], path)
      return if yes == no: yes else: "unknown"
    of "not":
      let value = valueOf(expr["value"], path)
      return if value == "zero": "nonzero" elif value == "nonzero": "zero" else: "unknown"
    of "==", "!=", "&&", "||":
      let left = valueOf(expr["left"], path)
      let right = valueOf(expr["right"], path)
      case expr["kind"].getStr
      of "&&":
        if left == "zero" or right == "zero": return "zero"
        if left == "nonzero" and right == "nonzero": return "nonzero"
      of "||":
        if left == "nonzero" or right == "nonzero": return "nonzero"
        if left == "zero" and right == "zero": return "zero"
      else:
        var equality = "unknown"
        if left == "zero" and right == "zero": equality = "nonzero"
        elif (left == "zero" and right == "nonzero") or (left == "nonzero" and right == "zero"):
          equality = "zero"
        # Two nonzero results need not be equal (e.g. distinct error codes).
        if expr["kind"].getStr == "!=":
          if equality == "zero": equality = "nonzero"
          elif equality == "nonzero": equality = "zero"
        return equality
    else: discard
    "unknown"

  proc conditionOf(node: JsonNode, path: Path): string =
    let value = valueOf(node.getOrDefault("conditionValue"), path)
    if value == "zero": "false"
    elif value == "nonzero": "true"
    else: node["condition"].getStr

  proc evidence(loan: Loan): JsonNode =
    %*{"bufferOrigin": loan.origin, "resourceOrigin": loan.resource, "mode": loan.mode,
      "protocol": loan.protocol, "acquiredAt": {"file": loan.file, "line": loan.line},
      "acquisitionCallChain": loan.chain}
  proc markKey(origin, mark: string): string = origin & "\0" & mark
  proc wrote(path: var Path) =
    ## A CPU write to ordinary memory: until a barrier of each kind follows, it may still be in flight.
    for kind in cfg.barrierKinds:
      path.unfenced.incl kind
      path.unfenced.excl "?" & kind
  proc fenced(path: var Path, symbol: string) =
    if symbol in cfg.contracts:
      for kind in cfg.contracts[symbol].barrier:
        path.unfenced.excl kind
        path.unfenced.excl "?" & kind
  proc dropMarks(path: var Path, origin: string) =
    ## A storage object that ends its lifetime, is released or relocated carries no marks: a new
    ## object at the same identity starts clean of every fact about the old one.
    var gone: seq[string]
    for key in path.marks.keys:
      if key.startsWith(origin & "\0"): gone.add key
    for key in gone: path.marks.del key
  proc setMark(path: var Path, origin, mark: string, span: Span, known: bool) =
    var m = path.marks.getOrDefault(markKey(origin, mark))
    if known:
      m.definite.addSpan span
      m.possible.addSpan span
    else:
      m.possibleAll = true            # it may now hold somewhere; nothing is certain
    path.marks[markKey(origin, mark)] = m
  proc clearMark(path: var Path, origin, mark: string, span: Span, known: bool) =
    let key = markKey(origin, mark)
    if key notin path.marks: return
    var m = path.marks[key]
    if known:
      m.definite.subSpan span
      m.possible.subSpan span
    else:
      m.definite = @[]                # it may be gone anywhere; it may also survive
    path.marks[key] = m
  proc markSpan(extent: StorageRange, length: BiggestInt): tuple[span: Span, known: bool] =
    ## The bytes an operation addresses: `length` bytes from the pointer when that is a known
    ## constant, to the end of the storage when no length is given (length == -2), unknown when a
    ## length is given but is not a compile-time constant (length == -1).
    if not extent.known or extent.invalid or length == -1: return ((0.BiggestInt, 0.BiggestInt), false)
    let hi = if length == -2: extent.size else: min(extent.size, extent.offset + max(0.BiggestInt, length))
    ((extent.offset, hi), true)
  proc cpuTouch(path: var Path, origin, mode: string, span: Span, known: bool,
                fn: EffectFunction, line: int, chain: seq[string]): bool =
    ## A CPU access to marked bytes: a violation where the mark forbids the access on bytes that
    ## certainly carry it, unverified where they only may; then the mark ends where the access
    ## clears it.
    result = true
    if cfg.marks.len == 0 or origin.len == 0: return
    for id, spec in cfg.marks:
      let key = markKey(origin, id)
      if key notin path.marks: continue
      let m = path.marks[key]
      if mode in spec.forbids:
        let hit = known and m.definite.touches(span)
        let maybe = m.possibleAll or (if known: m.possible.touches(span) else: m.possible.len > 0)
        if hit or maybe:
          let evidence = %*{"mark": id, "source": spec.origin, "access": mode,
            "byteRange": (if known: %*[span.lo, span.hi] else: newJNull()),
            "status": (if hit: "violation" else: "unverified")}
          report((if hit: "MARK_FORBIDS_ACCESS" else: "UNKNOWN_MARK_ACCESS"),
            (if hit: "violation" else: "unverified"),
            "CPU " & mode & " of bytes that " & (if hit: "carry" else: "may carry") & " mark '" & id & "'",
            fn, line, chain, markRequirement = evidence)
          return false
      if mode in spec.clearedBy: clearMark(path, origin, id, span, known)
  proc marksHold(path: Path, origin: string, marks: seq[string], span: Span, known: bool,
                 protocol: string, argument: int, fn: EffectFunction, line: int, chain: seq[string]): bool =
    ## Every required mark must certainly cover the borrowed bytes. A byte that certainly lacks
    ## it is a violation; a byte that only may lack it is unverified.
    for mark in marks:
      let m = path.marks.getOrDefault(markKey(origin, mark))
      let status =
        if known and m.definite.covers(span): "verified"
        elif not m.possibleAll and (if known: not m.possible.covers(span) else: m.possible.len == 0): "violation"
        else: "unverified"
      if status == "verified": continue
      let evidence = %*{"mark": mark, "source": cfg.marks[mark].origin, "protocol": protocol,
        "argument": argument, "byteRange": (if known: %*[span.lo, span.hi] else: newJNull()),
        "markedBytes": spansJson(m.definite), "status": status}
      report((if status == "violation": "BORROW_MARK_REQUIRED" else: "UNKNOWN_BORROW_MARK"), status,
        "borrowed bytes " & (if status == "violation": "lack" else: "may lack") & " required mark '" & mark & "'",
        fn, line, chain, markRequirement = evidence)
      return false
    true
  proc finish(path: var Path, origin: string, fn: EffectFunction, line: int, chain: seq[string]) =
    for loan in path.loans.values:
      if loan.origin == origin:
        report("BORROW_OUTLIVES_BUFFER", "violation", "buffer lifetime ends while an asynchronous borrow is active", fn, line, chain, evidence(loan))
      if loan.resource == origin:
        report("BORROW_NOT_ENDED", "violation", "resource lifetime ends before its borrow-completion operation", fn, line, chain, evidence(loan))
    path.dead.incl origin
    dropMarks(path, origin)
    # Declaration identities are reused by fixed-point loop exploration. Pin
    # escaping aliases to a permanently expired identity before that declaration
    # can begin a new lifetime. New address-taking still uses the live identity.
    let expired = origin & "|expired-lifetime"
    for key, bound in path.env.mpairs:
      if not key.startsWith("&") and bound == origin:
        bound = expired
        path.dead.incl expired
    path.values.del origin
    for id in selected:
      let key = id & "\0" & origin
      if key in path.states:
        if path.states[key] notin cfg.protocols[id].terminal:
          report("PROTOCOL_EXIT_STATE", "violation", "resource leaves its lifetime in nonterminal state '" &
            path.states[key] & "' of protocol '" & id & "'", fn, line, chain)
        path.states.del key

  proc referenced(path: Path, origin: string): bool =
    ## Whether anything the analysis tracks still names this storage object: a binding in this or
    ## a calling frame, a borrow, a protocol state, a mark, or a pending pointer result. Pointers
    ## loaded from memory are never given an origin, so an object reachable only that way is not
    ## counted; any use through such a pointer is already unverified.
    if origin in path.outerRefs or path.lastPointer == origin or path.returnedPointer == origin: return true
    for bound in path.env.values:
      if bound == origin: return true
    for loan in path.loans.values:
      if loan.origin == origin or loan.resource == origin: return true
    for key in path.states.keys:
      if key.endsWith("\0" & origin): return true
    for key in path.marks.keys:
      if key.startsWith(origin & "\0"): return true
    false
  proc allocation(path: var Path, site: string): string =
    ## A fresh identity for an object allocated at `site`. Re-executing the site (a loop, a repeated
    ## call) reuses the site's identity only when nothing names the previous object; otherwise a
    ## numbered alternative is taken, so a stale pointer to an earlier object is never mistaken for
    ## the new one. Identities are reused rather than counted up so that loop exploration converges.
    var index = 1
    result = site
    while referenced(path, result):
      inc index
      result = site & "#" & $index
    # An earlier object that nothing names any more may still be live (it leaked). Its identity
    # is reused, so from here on the live objects can no longer be counted.
    if result in path.allocators and result notin path.dead: path.untrackedLive = true
    path.dead.excl result
    path.values.del result
    dropMarks(path, result)
    path.permissions[result] = "writable"
  proc resourceLimits(path: Path, allocator: string, fn: EffectFunction, line: int, chain: seq[string]): bool =
    ## After an allocation: the allocator's declared capacity of live objects, and the profile's
    ## budget of live allocated bytes. Every live allocated object counts, referenced or leaked.
    result = true
    let capacity = cfg.contracts[allocator].allocCapacity
    var objects = 0
    var bytes = 0.BiggestInt
    var sizesKnown = true
    for origin, owner in path.allocators:
      if origin in path.dead: continue
      if owner == allocator: inc objects
      let size = path.allocatedBytes.getOrDefault(origin, -1)
      if size < 0: sizesKnown = false
      elif bytes <= high(BiggestInt) - size: bytes += size
      else: sizesKnown = false
    if capacity > 0:
      let evidence = %*{"kind": "allocatorCapacity", "allocator": allocator, "capacity": capacity,
        "liveObjects": (if path.untrackedLive: newJNull() else: %objects), "file": fn.file, "line": line,
        "callChain": chain, "status": (if path.untrackedLive: "unverified" elif objects > capacity: "violation" else: "verified")}
      if evidence notin outcome.resourceEvidence: outcome.resourceEvidence.add evidence
      if path.untrackedLive:
        report("UNKNOWN_ALLOCATION_CAPACITY", "unverified", "live objects of " & allocator &
          " cannot be counted: an earlier allocation from this site may still be live", fn, line, chain)
        return false
      if objects > capacity:
        report("ALLOCATION_CAPACITY", "violation", $objects & " live objects of " & allocator &
          " exceed its declared capacity of " & $capacity, fn, line, chain)
        return false
    if heapBudget >= 0:
      let known = sizesKnown and not path.untrackedLive
      let evidence = %*{"kind": "heapBudget", "maxLiveHeapBytes": heapBudget,
        "liveBytes": (if known: %bytes else: newJNull()), "file": fn.file, "line": line, "callChain": chain,
        "status": (if not known: "unverified" elif bytes > heapBudget: "violation" else: "verified")}
      if evidence notin outcome.resourceEvidence: outcome.resourceEvidence.add evidence
      if not known:
        report("UNKNOWN_HEAP_USAGE", "unverified", "live allocated bytes are not established: " &
          (if path.untrackedLive: "an earlier allocation from a repeated site may still be live" else: "an allocation size is not a constant"),
          fn, line, chain)
        return false
      if bytes > heapBudget:
        report("HEAP_BUDGET_EXCEEDED", "violation", $bytes & " live allocated bytes exceed the profile's maxLiveHeapBytes of " &
          $heapBudget, fn, line, chain)
        return false

  proc access(path: Path, origin, mode: string, fn: EffectFunction, line: int,
              chain: seq[string], protocolOperation = false, initialization = false): bool =
    if origin.len == 0:
      report("UNKNOWN_BORROW_ORIGIN", "unverified", "memory access origin is not established", fn, line, chain)
      return false
    if origin in path.dead:
      report("EXPIRED_BORROW_ORIGIN", "violation", "access uses an expired, released or relocated storage origin", fn, line, chain)
      return false
    if mode == "write" and not protocolOperation and not initialization:
      let permission = path.permissions.getOrDefault(origin, "unknown")
      if permission != "writable":
        let readonly = permission == "readonly"
        report((if readonly: "READONLY_STORAGE_WRITE" else: "UNKNOWN_STORAGE_PERMISSION"),
          (if readonly: "violation" else: "unverified"), "write access requires writable storage", fn, line, chain,
          memoryPermission = %*{"origin": origin, "storagePermission": permission, "access": mode})
        return false
    for loan in path.loans.values:
      if loan.origin == origin and (mode != "read" or loan.mode == "write"):
        report("BORROW_ACCESS_CONFLICT", "violation", mode & " conflicts with active " & loan.mode & " borrow", fn, line, chain, evidence(loan))
        return false
    if not protocolOperation and mode != "read":
      for id in selected:
        if id & "\0" & origin in path.states:
          report("UNMODELED_PROTOCOL_MUTATION", "unverified", "raw memory access may change a protocol resource", fn, line, chain)
          return false
    true

  proc allowEffects(path: Path, effects: seq[string], fn: EffectFunction, line: int, chain: seq[string]): bool =
    result = true
    for id in selected:
      let spec = cfg.protocols[id]
      for key, state in path.states:
        let prefix = id & "\0"
        if not key.startsWith(prefix): continue
        for effect in effects:
          if effect in spec.forbidWhile.getOrDefault(state):
            report("STATE_FORBIDDEN_EFFECT", "violation", "effect '" & effect & "' is forbidden while protocol '" & id & "' is in state '" & state & "'",
              fn, line, chain, stateRequirement = %*{"protocol": id, "state": state,
                "resourceOrigin": key[prefix.len .. ^1], "effect": effect, "source": spec.origin})
            result = false

  proc externalAccesses(path: var Path, symbol: string, arguments: seq[string], extents: seq[StorageRange],
                        fn: EffectFunction, line: int, chain: seq[string], lengths: seq[BiggestInt] = @[],
                        kinds: seq[string] = @[]): bool =
    var effects: seq[MemoryAccess]
    # free(NULL) does nothing, and realloc(NULL, n) only allocates
    let nullFirst = kinds.len > 0 and kinds[0] == "null"
    case symbol
    of "c:@F@free":
      if not nullFirst: effects.add MemoryAccess(argument: 1, mode: "release")
    of "c:@F@realloc":
      if not nullFirst: effects.add MemoryAccess(argument: 1, mode: "relocate")
    of "c:@F@memcpy", "c:@F@memmove":
      effects.add MemoryAccess(argument: 1, mode: "write")
      effects.add MemoryAccess(argument: 2, mode: "read")
    of "c:@F@memset": effects.add MemoryAccess(argument: 1, mode: "write")
    of "c:@F@memcmp":
      effects.add MemoryAccess(argument: 1, mode: "read")
      effects.add MemoryAccess(argument: 2, mode: "read")
    of "c:@F@memchr", "c:@F@strlen": effects.add MemoryAccess(argument: 1, mode: "read")
    else: discard
    if symbol in cfg.contracts:
      for effect in cfg.contracts[symbol].accesses:
        if nullFirst and symbol in ["c:@F@free", "c:@F@realloc"] and effect.argument == 1 and
            effect.mode in ["release", "relocate"]: continue
        effects.add effect
    var invalidated, changed: seq[string]
    for effect in effects:
      if effect.argument > arguments.len:
        report("MEMORY_ARGUMENT_MISMATCH", "unverified", "memory contract argument is absent", fn, line, chain)
        return false
      let origin = arguments[effect.argument - 1]
      if effect.minBytes > 0:
        let extent = extents[effect.argument - 1]
        let established = extent.known and not extent.invalid
        let capacity = extent.size - extent.offset
        let status = if extent.invalid: "violation"
                     elif not established: "unverified"
                     elif capacity < effect.minBytes: "violation"
                     else: "verified"
        let requirement = %*{"symbol": symbol, "source": cfg.contracts[symbol].origin,
          "argument": effect.argument, "access": effect.mode, "requiredMinimumBytes": effect.minBytes,
          "file": fn.file, "line": line, "callChain": chain, "status": status,
          "storageBytes": (if established: %extent.size else: newJNull()),
          "byteOffset": (if established: %extent.offset else: newJNull()),
          "availableBytes": (if established: %capacity else: newJNull()), "unit": "c-sizeof-bytes"}
        if requirement notin outcome.accessCapacityEvidence: outcome.accessCapacityEvidence.add requirement
        if status != "verified":
          let code = if extent.invalid: "MEMORY_POINTER_RANGE"
                     elif not established: "UNKNOWN_MEMORY_CAPACITY"
                     else: "MEMORY_CAPACITY_REQUIREMENT"
          report(code, status, "memory access capacity requirement is not satisfied or established",
            fn, line, chain, capacityRequirement = requirement)
          return false
      if effect.alignment > 0:
        let extent = extents[effect.argument - 1]
        let status = alignmentStatus(extent, effect.alignment)
        let requirement = %*{"symbol": symbol, "source": cfg.contracts[symbol].origin,
          "argument": effect.argument, "access": effect.mode, "requiredAlignment": effect.alignment,
          "baseAlignment": (if extent.alignment > 0: %extent.alignment else: newJNull()),
          "byteOffset": (if extent.known and not extent.invalid: %extent.offset else: newJNull()),
          "file": fn.file, "line": line, "callChain": chain,
          "status": status, "unit": "c-sizeof-bytes"}
        if requirement notin outcome.accessAlignmentEvidence: outcome.accessAlignmentEvidence.add requirement
        if status != "verified":
          let code = if extent.invalid: "MEMORY_POINTER_RANGE"
                     elif status == "violation": "MEMORY_ALIGNMENT_REQUIREMENT"
                     else: "UNKNOWN_MEMORY_ALIGNMENT"
          report(code, status, "memory access alignment requirement is not satisfied or established",
            fn, line, chain, alignmentRequirement = requirement)
          return false
      if not access(path, origin, effect.mode, fn, line, chain): return false
      if effect.mode in ["release", "relocate"]:
        # Storage is released only by what its allocator declares; free/realloc of storage that no
        # allocation contract produced (an automatic object, a parameter's own storage) is invalid.
        let allocator = path.allocators.getOrDefault(origin)
        if allocator.len > 0 and symbol notin cfg.contracts[allocator].allocReleasedBy:
          report("RELEASE_ALLOCATOR_MISMATCH", "violation", "storage from " & allocator &
            " is " & effect.mode & "d by " & symbol & ", which its allocation contract does not name",
            fn, line, chain)
          return false
        if allocator.len > 0:
          # only the pointer the allocator returned may be released, not one into the object
          let extent = extents[effect.argument - 1]
          if extent.invalid or (extent.known and extent.offset != 0):
            report("RELEASE_NOT_ALLOCATION_START", "violation", symbol &
              " of a pointer that is not the start of its allocation", fn, line, chain)
            return false
          if not extent.known and not extent.atStart:
            report("UNKNOWN_RELEASE_POSITION", "unverified", symbol &
              " of a pointer whose position in its allocation is not established", fn, line, chain)
            return false
        if allocator.len == 0 and symbol in ["c:@F@free", "c:@F@realloc"]:
          report("RELEASE_NOT_ALLOCATED", "violation", symbol &
            " of storage that no allocation contract produced", fn, line, chain)
          return false
      # An API's own read or write reaches the storage like a CPU access. Its byte count is not
      # part of the access contract, so the touched bytes are unknown: a forbidding mark makes it
      # unverified, never a violation, and a clearing mark stops being certain anywhere.
      if effect.mode in ["read", "write"] and
          not cpuTouch(path, origin, effect.mode, (0.BiggestInt, 0.BiggestInt), false, fn, line, chain): return false
      if effect.mode != "read": changed.add origin
      if effect.mode in ["release", "relocate"]: invalidated.add origin
    if (asyncEnabled or memoryAccessEnabled) and (symbol notin cfg.contracts or not cfg.contracts[symbol].accessesDeclared):
      report("MISSING_MEMORY_CONTRACT", "unverified", "ordered memory verification requires a complete external access contract", fn, line, chain)
      return false
    # Accesses describe a set, not an invented execution order. Invalidation
    # takes effect after checking all accesses against the call's entry state.
    for origin in changed: path.values.del origin
    for effect in effects:
      if effect.mode == "write": wrote(path)
    for origin in invalidated:
      path.dead.incl origin
      dropMarks(path, origin)
    if symbol in cfg.contracts:
      for effect in cfg.contracts[symbol].marks:
        if effect.argument > arguments.len or (effect.lengthArgument > 0 and effect.lengthArgument > arguments.len):
          report("MARK_ARGUMENT_MISMATCH", "unverified", "mark contract argument is absent", fn, line, chain)
          return false
        let origin = arguments[effect.argument - 1]
        let length = if effect.lengthArgument == 0: -2.BiggestInt
                     elif effect.lengthArgument <= lengths.len: lengths[effect.lengthArgument - 1]
                     else: -1.BiggestInt
        let (span, known) = markSpan(extents[effect.argument - 1], length)
        if origin.len == 0:
          # Bytes kenbi cannot place may be any tracked buffer's: dropping the effect would later
          # accuse a buffer that was in fact maintained, keeping it would accept one that was not.
          report("UNKNOWN_MARK_TARGET", "unverified", "mark operation addresses storage that is not established",
            fn, line, chain)
          return false
        for mark in effect.clearMarks: clearMark(path, origin, mark, span, known)
        for mark in effect.setMarks: setMark(path, origin, mark, span, known)
    true

  proc boundaryMatches(boundary: ProtocolBoundary, expected: BoundaryState, args: seq[string],
                       path: Path, fn: EffectFunction, chain: seq[string], stage: string, returnedValue = ""): bool =
    if boundary.protocol notin selected:
      report("MISSING_BOUNDARY_PROTOCOL", "unverified", "function boundary requires selected protocol " & boundary.protocol, fn, fn.first, chain, observedResult = returnedValue, boundaryProtocol = boundary.protocol, boundaryArgument = boundary.argument)
      return false
    if boundary.argument > args.len or expected.bufferArgument > args.len:
      report("UNKNOWN_BOUNDARY_ARGUMENT", "unverified", "boundary arguments are not established", fn, fn.first, chain, observedResult = returnedValue, boundaryProtocol = boundary.protocol, boundaryArgument = boundary.argument)
      return false
    let resource = args[boundary.argument - 1]
    let buffer = if expected.bufferArgument > 0: args[expected.bufferArgument - 1] else: ""
    if resource.len == 0 or (expected.bufferArgument > 0 and buffer.len == 0):
      report("UNKNOWN_BOUNDARY_ARGUMENT", "unverified", "boundary requires tracked pointer origins", fn, fn.first, chain, observedResult = returnedValue, boundaryProtocol = boundary.protocol, boundaryArgument = boundary.argument)
      return false
    let key = boundary.protocol & "\0" & resource
    if resource in path.dead or (expected.bufferArgument > 0 and buffer in path.dead):
      report("BOUNDARY_" & stage & "_MISMATCH", "violation", "boundary origin has expired", fn, fn.first, chain, observedResult = returnedValue, boundaryProtocol = boundary.protocol, boundaryArgument = boundary.argument)
      return false
    if path.states.getOrDefault(key, cfg.protocols[boundary.protocol].initial) != expected.state:
      report("BOUNDARY_" & stage & "_MISMATCH", "violation", "boundary requires state '" & expected.state & "'", fn, fn.first, chain, observedResult = returnedValue, boundaryProtocol = boundary.protocol, boundaryArgument = boundary.argument)
      return false
    if expected.bufferArgument == 0:
      if key in path.loans:
        report("BOUNDARY_" & stage & "_MISMATCH", "violation", "boundary requires no active borrow", fn, fn.first, chain, evidence(path.loans[key]), returnedValue, boundary.protocol, boundary.argument)
        return false
    elif key notin path.loans or path.loans[key].origin != buffer or path.loans[key].mode != expected.mode:
      report("BOUNDARY_" & stage & "_MISMATCH", "violation", "boundary borrow does not match its origin and mode", fn, fn.first, chain, observedResult = returnedValue, boundaryProtocol = boundary.protocol, boundaryArgument = boundary.argument)
      return false
    true

  proc execute(node: JsonNode, inputs: seq[Path], fn: EffectFunction,
               frame: string, chain: seq[string]): seq[Path]
  proc invoke(symbol: string, args: seq[string], input: Path,
              frame: string, chain: seq[string], values: seq[string] = @[], extents: seq[StorageRange] = @[], pointerKinds: seq[string] = @[]): seq[Path] =
    let fn = functions[symbol]
    if fn.protocol.isNil:
      report("UNSUPPORTED_PROTOCOL_MODEL", "unverified", "no ordered protocol facts", fn, fn.first, chain)
      return
    if chain.len > 32:
      report("UNSUPPORTED_PROTOCOL_RECURSION", "unverified", "protocol call depth exceeds 32", fn, fn.first, chain)
      return
    if (asyncEnabled or memoryAccessEnabled) and symbol in cfg.contracts and cfg.contracts[symbol].accessesDeclared:
      report("MEMORY_CONTRACT_BODY_UNVERIFIED", "unverified", "available body needs memory-contract refinement checking", fn, fn.first, chain)
    var entryValid = true
    for boundary in cfg.boundaries.getOrDefault(symbol):
      if boundary.outcomes.len > 0 and not fn.protocol.getOrDefault("returnsInt").getBool:
        report("UNSUPPORTED_BOUNDARY_RESULT", "unverified", "result-dependent boundary requires an int-returning implementation", fn, fn.first, chain,
          boundaryProtocol = boundary.protocol, boundaryArgument = boundary.argument)
        entryValid = false
      if not boundaryMatches(boundary, boundary.entry, args, input, fn, chain, "PRECONDITION"):
        entryValid = false
    if not entryValid: return
    var path = input
    for bound in input.env.values:
      if bound.len > 0: path.outerRefs.incl bound
    path.env = initTable[string, string]()
    path.nullPointers = initHashSet[string]()
    path.extents = initTable[string, StorageRange]()
    path.flow = ""
    path.returnValue = "unknown"
    path.returnedPointer = ""
    path.returnedPointerKind = ""
    path.returnedExtent = StorageRange()
    path.lastPointer = ""
    path.lastPointerKind = ""
    path.lastPointerExtent = StorageRange()
    path.lastResult = "unknown"
    var parameterOrigins: seq[string]
    for i in 0 ..< fn.protocol["parameters"].len:
      let parameter = fn.protocol["parameters"][i].getStr
      let parameterKind = fn.protocol["parameterKinds"][i].getInt
      if parameterKind in 3..20 or parameterKind == 106:
        let origin = frame & "|parameter|" & parameter
        parameterOrigins.add origin
        path.env["&" & parameter] = origin
        path.permissions[origin] = fn.protocol["parameterPermissions"][i].getStr
        path.extents["&" & parameter] = StorageRange(alignment: fn.protocol["parameterAlignments"][i].getBiggestInt, size: fn.protocol["parameterBytes"][i].getBiggestInt, known: fn.protocol["parameterBytes"][i].getBiggestInt > 0)
        path.dead.excl origin
        path.values.del origin
        # Storage facts survive integer conversions, but numeric facts need
        # conversion-aware transfer (narrowing can turn nonzero into zero).
        if parameterKind == 17 and i < values.len and values[i] in ["zero", "nonzero"]:
          path.values[origin] = values[i]
      else:
        path.env[parameter] = if i < args.len: args[i] else: ""
        if i < pointerKinds.len and pointerKinds[i] == "null": path.nullPointers.incl parameter
        path.extents[parameter] = if i < extents.len: extents[i] else: StorageRange()
    result = execute(fn.protocol["body"], @[path], fn, frame, chain)
    for path in result.mitems:
      for origin in parameterOrigins: finish(path, origin, fn, fn.last, chain)
      if symbol in cfg.contracts and cfg.contracts[symbol].returnArgument > 0:
        let index = cfg.contracts[symbol].returnArgument - 1
        if not fn.protocol.getOrDefault("returnsPointer").getBool or index >= args.len:
          report("POINTER_RETURN_ARGUMENT_MISMATCH", "unverified", "returnPointer needs a pointer result and an available argument", fn, fn.first, chain)
        elif path.returnedPointerKind == "null":
          if not cfg.contracts[symbol].returnNullable:
            report("POINTER_RETURN_CONTRACT_MISMATCH", "violation", "implementation returns null despite a non-null returnPointer contract", fn, fn.first, chain)
        elif args[index].len == 0 or path.returnedPointer.len == 0 or
            not extents[index].known or not path.returnedExtent.known:
          report("UNKNOWN_POINTER_RETURN_CONTRACT", "unverified", "returnPointer implementation needs established origins and positions", fn, fn.first, chain)
        elif path.returnedPointer != args[index] or path.returnedPointer in path.dead or
            path.returnedExtent.invalid or shiftedRange(extents[index], cfg.contracts[symbol].returnOffset).invalid or
            path.returnedExtent.offset != shiftedRange(extents[index], cfg.contracts[symbol].returnOffset).offset:
          report("POINTER_RETURN_CONTRACT_MISMATCH", "violation", "implementation does not return the declared argument at the required live position", fn, fn.first, chain)
      if checkMemory and path.returnedPointerKind.len > 0:
        if path.returnedPointerKind == "origin" and path.returnedPointer in path.dead:
          report("EXPIRED_POINTER_RETURN", "violation", "returned pointer's storage expires before function return",
            fn, path.returnedPointerLine, chain)
        elif path.returnedPointerKind == "unknown":
          report("UNKNOWN_POINTER_RETURN", "unverified", "returned pointer's origin and lifetime are not established",
            fn, path.returnedPointerLine, chain)
      var expiredLoans: seq[string]
      for key, loan in path.loans:
        if loan.resource in parameterOrigins: expiredLoans.add key
      for key in expiredLoans: path.loans.del key
      for boundary in cfg.boundaries.getOrDefault(symbol):
        if boundary.outcomes.len == 0:
          discard boundaryMatches(boundary, boundary.exit, args, path, fn, chain, "POSTCONDITION")
        elif path.returnValue notin ["zero", "nonzero"]:
          report("UNKNOWN_BOUNDARY_RESULT", "unverified", "implementation return value is not established; cannot select a boundary postcondition", fn, fn.first, chain,
            boundaryProtocol = boundary.protocol, boundaryArgument = boundary.argument)
        else:
          for branch in boundary.outcomes:
            if branch.result == path.returnValue:
              discard boundaryMatches(boundary, branch.exit, args, path, fn, chain,
                "POSTCONDITION", path.returnValue)
      path.env = input.env
      path.outerRefs = input.outerRefs
      path.nullPointers = input.nullPointers
      path.extents = input.extents
      path.lastResult = path.returnValue
      path.lastPointer = path.returnedPointer
      path.lastPointerKind = path.returnedPointerKind
      path.lastPointerExtent = path.returnedExtent
      path.returnValue = input.returnValue
      path.returnedPointer = input.returnedPointer
      path.returnedPointerKind = input.returnedPointerKind
      path.returnedPointerLine = input.returnedPointerLine
      path.returnedExtent = input.returnedExtent
      path.flow = "" # return ends the callee, not its caller

  proc execute(node: JsonNode, inputs: seq[Path], fn: EffectFunction,
               frame: string, chain: seq[string]): seq[Path] =
    if inputs.len == 0: return
    steps += inputs.len
    if steps > 10000 or inputs.len > 256:
      report("PROTOCOL_ANALYSIS_LIMIT", "unverified", "protocol path budget exceeded", fn, fn.first, chain)
      return
    let line = node["line"].getInt
    let kind = node["kind"].getStr
    for original in inputs:
      if original.flow.len > 0:
        result.add original
        continue
      var path = original
      case kind
      of "sequence", "scope":
        var paths = @[path]
        for child in node["children"]:
          paths = execute(child, paths, fn, frame, chain)
        if kind == "scope":
          for p in paths.mitems:
            var origins: seq[string]
            for key, origin in p.env:
              if key.startsWith("&") and key notin original.env: origins.add origin
            origins.sort()
            for origin in origins: finish(p, origin, fn, line, chain)
            var completed: seq[string]
            for key, loan in p.loans:
              if loan.resource in origins: completed.add key
            for key in completed: p.loans.del key
            # Drop bindings introduced by this scope, but retain assignments
            # to outer variables. Escaping pointers keep their now-dead origin.
            var locals: seq[string]
            for key in p.env.keys:
              if key notin original.env: locals.add key
            for key in locals:
              p.env.del key
              p.nullPointers.excl key
              p.extents.del key
        result.add paths
      of "declare":
        let symbol = node["symbol"].getStr
        if node["pointer"].getBool:
          if pointerKind(node["value"], path) == "null": path.nullPointers.incl symbol
          else: path.nullPointers.excl symbol
          path.extents[symbol] = availableRange(node["value"], path)
          path.env[symbol] = resolve(node["value"], path)
        else:
          let origin = frame & "|" & symbol
          path.env["&" & symbol] = origin
          path.permissions[origin] = node["storagePermission"].getStr
          path.extents["&" & symbol] = StorageRange(alignment: node["storageAlignment"].getBiggestInt, size: node["storageBytes"].getBiggestInt, known: node["storageBytes"].getBiggestInt > 0)
          path.dead.excl origin
          path.values.del origin
        result.add path
      of "pointerValue":
        let origin = resolve(node["value"], path)
        if checkMemory and origin in path.dead:
          report("EXPIRED_BORROW_ORIGIN", "violation", "pointer value reads an expired storage origin", fn, line, chain)
        else:
          result.add path
      of "pointerComparison":
        if not checkMemory:
          result.add path
          continue
        let left = resolve(node["left"], path)
        let right = resolve(node["right"], path)
        let op = node["operator"].getStr
        let details = %*{"operator": op,
          "leftOrigin": (if left.len > 0: %left else: newJNull()),
          "rightOrigin": (if right.len > 0: %right else: newJNull())}
        if left in path.dead or right in path.dead:
          report("EXPIRED_BORROW_ORIGIN", "violation", "comparison uses an expired storage origin",
            fn, line, chain, pointerComparison = details)
        elif op in ["<", ">", "<=", ">="]:
          report("UNSUPPORTED_POINTER_ORDER", "unverified", "pointer ordering needs array/subobject and language-specific verification",
            fn, line, chain, pointerComparison = details)
        else:
          # Equality can compare distinct live objects or null. Do not mistake
          # distinct origins for an ordering violation, or infer a numeric result.
          result.add path
      of "pointerDifference":
        if not checkMemory:
          result.add path
          continue
        let left = resolve(node["left"], path)
        let right = resolve(node["right"], path)
        let details = %*{"leftOrigin": (if left.len > 0: %left else: newJNull()),
          "rightOrigin": (if right.len > 0: %right else: newJNull())}
        if left in path.dead or right in path.dead:
          report("EXPIRED_BORROW_ORIGIN", "violation", "pointer difference uses an expired storage origin",
            fn, line, chain, pointerDifference = details)
        elif left.len > 0 and right.len > 0 and left != right:
          report("POINTER_DIFFERENT_STORAGE", "violation", "pointer subtraction requires pointers into the same array object",
            fn, line, chain, pointerDifference = details)
        else:
          # A shared storage origin alone does not prove a common array element
          # type, subobject bounds, or representability in ptrdiff_t.
          report("UNSUPPORTED_POINTER_DIFFERENCE", "unverified", "pointer difference needs array-layout and result-range verification",
            fn, line, chain, pointerDifference = details)
      of "pointerFormation":
        if not checkMemory:
          result.add path
          continue
        if pointerKind(node["value"], path) == "null":
          report("NULL_POINTER_ARITHMETIC", "violation", "pointer arithmetic uses a known null pointer", fn, line, chain)
          continue
        let origin = resolve(node["value"], path)
        if origin in path.dead:
          report("EXPIRED_BORROW_ORIGIN", "violation", "pointer arithmetic uses an expired storage origin", fn, line, chain)
          continue
        let extent = availableRange(node["value"], path)
        let known = origin.len > 0 and extent.known and not extent.invalid
        let status = if extent.invalid: "violation" elif not known: "unverified" else: "verified"
        let evidence = %*{"file": fn.file, "line": line, "callChain": chain, "status": status,
          "storageBytes": (if known: %extent.size else: newJNull()),
          "byteOffset": (if known: %extent.offset else: newJNull()), "unit": "c-sizeof-bytes"}
        if evidence notin outcome.pointerFormationEvidence: outcome.pointerFormationEvidence.add evidence
        if status != "verified":
          report((if extent.invalid: "SOURCE_POINTER_RANGE" else: "UNKNOWN_SOURCE_POINTER_RANGE"), status,
            "pointer formation must stay within storage or one past its end", fn, line, chain,
            capacityRequirement = evidence)
        else: result.add path
      of "mmio":
        # A volatile access at a constant address, checked against the declared register map.
        let address = node["address"].getBiggestInt
        let width = node["width"].getBiggestInt
        let mode = node["mode"].getStr
        let operation = node["operation"].getStr
        let value = node["value"]
        var register = -1
        for i, r in cfg.mmioRegisters:
          if address < r.address + r.width and r.address < address + width: register = i
        var code, status, message = ""
        var inBlock = ""
        if register < 0:
          for b in cfg.mmioBlocks:
            if address < b.base + b.size and b.base < address + width: inBlock = b.id
          if inBlock.len > 0:
            code = "MMIO_UNDECLARED_REGISTER"; status = "violation"
            message = "access inside register block '" & inBlock & "' where no register is declared"
          else:
            code = "UNKNOWN_MMIO_ADDRESS"; status = "unverified"
            message = "volatile access at an address no register map declares"
        else:
          let r = cfg.mmioRegisters[register]
          let reads = mode in ["read", "update"]
          let writes = mode in ["write", "update"]
          if r.address != address or r.width != width:
            code = "MMIO_ACCESS_WIDTH"; status = "violation"
            message = "access of " & $width & " bytes at offset " & $(address - r.address) & " of " & $r.width & "-byte register '" & r.id & "'"
          elif writes and r.access == "read-only":
            code = "MMIO_READ_ONLY_WRITE"; status = "violation"; message = "write to read-only register '" & r.id & "'"
          elif reads and r.access == "write-only":
            code = "MMIO_WRITE_ONLY_READ"; status = "violation"; message = "read of write-only register '" & r.id & "'"
          elif writes and r.requiresBarrier.len > 0 and r.requiresBarrier in path.unfenced:
            code = "MMIO_BARRIER_REQUIRED"; status = "violation"
            message = "write to '" & r.id & "' may overtake earlier memory writes: no '" & r.requiresBarrier &
              "' barrier since the last write on this path"
          elif writes and r.requiresBarrier.len > 0 and "?" & r.requiresBarrier in path.unfenced:
            code = "UNKNOWN_MMIO_BARRIER"; status = "unverified"
            message = "write to '" & r.id & "' needs a '" & r.requiresBarrier &
              "' barrier after any memory writes made before this function was entered"
          elif mode == "update" and r.writeOneToClear != 0:
            code = "MMIO_WRITE_ONE_TO_CLEAR_UPDATE"; status = "violation"
            message = "read-modify-write of '" & r.id & "' writes back set write-one-to-clear bits and clears them"
          elif mode == "update" and r.readToClear != 0:
            code = "MMIO_READ_TO_CLEAR_UPDATE"; status = "violation"
            message = "read-modify-write of '" & r.id & "' clears read-to-clear bits as a side effect of its read"
          elif writes and r.reservedMask != 0:
            # What the store leaves in the reserved bits: certainly wrong, certainly right, or unknown.
            let mask = r.reservedMask
            let known = value.kind == JInt
            let v = if known: value.getBiggestInt else: 0
            var verdict = "unknown"
            if mode == "write":
              if r.reservedWrite == "preserve": verdict = "wrong"       # a plain store cannot keep bits it never read
              elif known: verdict = (if (v and mask) == 0: "right" else: "wrong")
            elif known:
              # with reserved bits declared to read as zero, a read-modify-write writes OP(0, C) there
              let readsZero = r.reservedReadsZero and r.reservedWrite == "zero"
              case operation
              of "|=":
                if (v and mask) != 0: verdict = "wrong"
                elif r.reservedWrite == "preserve" or readsZero: verdict = "right"
              of "&=":
                if r.reservedWrite == "preserve" and (v and mask) == mask: verdict = "right"
                elif r.reservedWrite == "zero" and ((v and mask) == 0 or readsZero): verdict = "right"
              of "^=":
                if (v and mask) != 0 and (r.reservedWrite == "preserve" or readsZero): verdict = "wrong"
                elif (v and mask) == 0 and (r.reservedWrite == "preserve" or readsZero): verdict = "right"
              else: discard
            if verdict == "wrong":
              code = "MMIO_RESERVED_BITS"; status = "violation"
              message = "store to '" & r.id & "' does not keep its reserved bits (" & r.reservedWrite & ")"
            elif verdict == "unknown":
              code = "UNKNOWN_MMIO_RESERVED_BITS"; status = "unverified"
              message = "what the store to '" & r.id & "' leaves in its reserved bits is not established"
        let evidence = %*{"file": fn.file, "line": line, "callChain": chain, "address": address, "width": width,
          "access": mode, "operation": operation, "value": value,
          "register": (if register >= 0: %cfg.mmioRegisters[register].id else: newJNull()),
          "block": (if inBlock.len > 0: %inBlock else: newJNull()),
          "source": (if register >= 0: %cfg.mmioRegisters[register].origin else: newJNull()),
          "status": (if status.len > 0: status else: "verified")}
        if evidence notin outcome.mmioEvidence: outcome.mmioEvidence.add evidence
        if status.len > 0:
          report(code, status, message, fn, line, chain)
        else:
          outcome.assumptions.incl cfg.mmioRegisters[register].assumption
          result.add path
      of "scalarResult":
        path.lastResult = valueOf(node["value"], path)
        result.add path
      of "pointerResult":
        let origin = resolve(node["value"], path)
        let extent = availableRange(node["value"], path)
        let pointerResultKind = pointerKind(node["value"], path)
        path.lastPointer = origin
        path.lastPointerExtent = extent
        path.lastPointerKind = pointerResultKind
        result.add path
      of "pointerStore":
        let symbol = node["symbol"].getStr
        if symbol notin path.env:
          report("UNKNOWN_POINTER_BINDING", "unverified", "pointer assignment requires a tracked local or value parameter", fn, line, chain)
        else:
          let extent = availableRange(node["value"], path)
          let origin = resolve(node["value"], path)
          if pointerKind(node["value"], path) == "null": path.nullPointers.incl symbol
          else: path.nullPointers.excl symbol
          path.extents[symbol] = extent
          path.env[symbol] = origin
          result.add path
      of "scalarStore":
        let origin = path.env.getOrDefault("&" & node["symbol"].getStr)
        let value = valueOf(node["value"], path)
        if access(path, origin, "write", fn, line, chain, initialization = node.getOrDefault("initialization").getBool):
          if not cpuTouch(path, origin, "write", (0.BiggestInt, 0.BiggestInt), false, fn, line, chain): continue
          path.values.del origin
          if value in ["zero", "nonzero"]: path.values[origin] = value
          wrote(path)
          result.add path
      of "memory":
        if checkMemory and pointerKind(node["value"], path) == "null":
          report("NULL_POINTER_ACCESS", "violation", "memory access uses a known null pointer", fn, line, chain)
          continue
        let origin = resolve(node["value"], path)
        if origin.len == 0 and node["optional"].getBool and not checkMemory:
          # Scalar parameters/globals cannot alias a tracked automatic origin.
          result.add path
        elif access(path, origin, node["mode"].getStr, fn, line, chain):
          if checkMemory:
            let extent = availableRange(node["value"], path)
            let width = node["accessBytes"].getBiggestInt
            let alignment = node["accessAlignment"].getBiggestInt
            let known = extent.known and not extent.invalid
            var status = "verified"
            var code = ""
            if extent.invalid or (known and width > extent.size - extent.offset):
              status = "violation"; code = "SOURCE_ACCESS_RANGE"
            elif not known or width <= 0 or alignment <= 0:
              status = "unverified"; code = "UNKNOWN_SOURCE_ACCESS_RANGE"
            else:
              status = alignmentStatus(extent, int(alignment))
              if status == "violation": code = "SOURCE_ACCESS_ALIGNMENT"
              elif status == "unverified": code = "UNKNOWN_SOURCE_ACCESS_ALIGNMENT"
            let evidence = %*{"file": fn.file, "line": line, "callChain": chain,
              "access": node["mode"], "accessBytes": width, "requiredAlignment": alignment,
              "availableBytes": (if known: %(extent.size - extent.offset) else: newJNull()),
              "byteOffset": (if known: %extent.offset else: newJNull()),
              "baseAlignment": extent.alignment, "status": status, "unit": "c-sizeof-bytes"}
            if evidence notin outcome.sourceAccessEvidence: outcome.sourceAccessEvidence.add evidence
            if status != "verified":
              report(code, status, "source memory access range or alignment is not established", fn, line, chain,
                capacityRequirement = evidence)
              continue
          if cfg.marks.len > 0:
            let extent = availableRange(node["value"], path)
            let width = node["accessBytes"].getBiggestInt
            let known = extent.known and not extent.invalid and width > 0
            let span = if known: (extent.offset, extent.offset + width) else: (0.BiggestInt, 0.BiggestInt)
            if not cpuTouch(path, origin, node["mode"].getStr, span, known, fn, line, chain): continue
          if node["mode"].getStr != "read":
            path.values.del origin
            wrote(path)
          result.add path
      of "if":
        let condition = conditionOf(node, path)
        if condition != "false": result.add execute(node["then"], @[path], fn, frame, chain)
        if condition != "true": result.add execute(node["else"], @[path], fn, frame, chain)
      of "while":
        var pending = @[path]
        var seen = initHashSet[string]()
        while pending.len > 0:
          let head = pending.pop()
          let key = signature(head)
          if key in seen: continue
          seen.incl key
          var checked = @[head]
          for read in node["conditionReads"]:
            checked = execute(read, checked, fn, frame, chain)
          for checkedHead in checked:
            let condition = conditionOf(node, checkedHead)
            if condition != "true": result.add checkedHead
            if condition == "false": continue
            let body = execute(node["body"], @[checkedHead], fn, frame, chain)
            for tail in body:
              var next = tail
              case next.flow
              of "return": result.add next
              of "break": next.flow = ""; result.add next
              else:
                next.flow = ""
                if node.hasKey("increment"):
                  pending.add execute(node["increment"], @[next], fn, frame, chain)
                else: pending.add next
      of "doWhile":
        var pending = @[path]
        var seen = initHashSet[string]()
        while pending.len > 0:
          let head = pending.pop()
          let key = signature(head)
          if key in seen: continue
          seen.incl key
          # The body executes at least once. Continue goes to the condition;
          # break and return do not evaluate it, including its call effects.
          for tail in execute(node["body"], @[head], fn, frame, chain):
            var next = tail
            if next.flow == "return":
              result.add next
              continue
            if next.flow == "break":
              next.flow = ""
              result.add next
              continue
            next.flow = ""
            var checked = @[next]
            for read in node["conditionReads"]:
              checked = execute(read, checked, fn, frame, chain)
            for checkedTail in checked:
              let condition = conditionOf(node, checkedTail)
              if condition != "true": result.add checkedTail
              if condition != "false": pending.add checkedTail
      of "return", "break", "continue":
        path.flow = kind
        if kind == "return": path.returnValue = valueOf(node.getOrDefault("value"), path)
        if kind == "return" and node.hasKey("pointerReturn"):
          path.returnedPointer = resolve(node["pointerReturn"], path)
          path.returnedExtent = availableRange(node["pointerReturn"], path)
          path.returnedPointerKind = pointerKind(node["pointerReturn"], path)
          path.returnedPointerLine = line
        result.add path
      of "call":
        let symbol = node["symbol"].getStr
        path.lastResult = "unknown"
        path.lastPointer = ""
        path.lastPointerKind = "unknown"
        path.lastPointerExtent = StorageRange()
        let nextChain = chain & @[symbol]
        if symbol notin functions and node.getOrDefault("pointerResultUsed").getBool and
            (symbol notin cfg.contracts or
             (cfg.contracts[symbol].returnArgument == 0 and not cfg.contracts[symbol].allocates)):
          report("UNSUPPORTED_POINTER_RESULT_CONTRACT", "unverified", "external pointer results need an origin and lifetime contract", fn, line, nextChain)
          continue
        var arguments, argumentValues: seq[string]
        var argumentPointerKinds: seq[string]
        var argumentExtents: seq[StorageRange]
        for arg in node["arguments"]: argumentExtents.add availableRange(arg, path)
        for arg in node["arguments"]: arguments.add resolve(arg, path)
        for arg in node["arguments"]: argumentPointerKinds.add pointerKind(arg, path)
        for arg in node["argumentValues"]: argumentValues.add valueOf(arg, path)
        # compile-time byte counts, for mark and borrow ranges (-1: not a constant)
        var argumentLengths: seq[BiggestInt]
        for arg in node["arguments"]:
          argumentLengths.add(if arg.hasKey("constant"): arg["constant"].getBiggestInt
                              elif arg["kind"].getStr == "null": 0.BiggestInt
                              else: -1.BiggestInt)
        if symbol notin functions:
          var effects: seq[string]
          if symbol in cfg.contracts: effects = cfg.contracts[symbol].effects
          if symbol in heapPrimitives and "heap_allocate" notin effects: effects.add "heap_allocate"
          if not allowEffects(path, effects, fn, line, nextChain): continue
          if heapBudget >= 0 and "heap_allocate" in effects and
              not (symbol in cfg.contracts and cfg.contracts[symbol].allocates):
            # storage this call may allocate has no declared size, so the budget cannot be checked
            report("UNKNOWN_HEAP_USAGE", "unverified", symbol & " may allocate storage that no allocation contract sizes",
              fn, line, nextChain)
            continue
        var matched = false
        for id in selected:
          for operation in cfg.protocols[id].operations:
            if operation.symbol != symbol: continue
            matched = true
            for op in variants(operation):
              var branchPath = path
              if symbol in functions:
                report("PROTOCOL_IMPLEMENTATION_UNVERIFIED", "unverified",
                  "an available operation implementation needs protocol refinement checking", fn, line, nextChain)
              elif (op.resultCase.len == 0 and not node["void"].getBool) or
                  (op.resultCase.len > 0 and not node["returnsInt"].getBool):
                report("UNSUPPORTED_PROTOCOL_RESULT", "unverified",
                  "result-dependent operations require int returns; other non-void operations need explicit outcomes", fn, line, nextChain)
              elif op.argument > arguments.len:
                report("PROTOCOL_ARGUMENT_MISMATCH", "unverified", "resource argument is absent", fn, line, nextChain)
              elif arguments[op.argument - 1].len == 0:
                report("UNKNOWN_PROTOCOL_RESOURCE", "unverified",
                  "resource identity or entry state is not established", fn, line, nextChain)
              else:
                let resource = arguments[op.argument - 1]
                if not access(branchPath, resource, "write", fn, line, nextChain, true): continue
                branchPath.values.del resource
                let key = id & "\0" & resource
                let before = branchPath.states.getOrDefault(key, cfg.protocols[id].initial)
                if before notin op.sources:
                  report("PROTOCOL_PRECONDITION", "violation", "operation requires " & $op.sources &
                    "; resource may be '" & before & "' in protocol '" & id & "'", fn, line, nextChain)
                else:
                  if not externalAccesses(branchPath, symbol, arguments, argumentExtents, fn, line, nextChain, argumentLengths, argumentPointerKinds): continue
                  fenced(branchPath, symbol)
                  if op.releaseBorrow:
                    if key notin branchPath.loans:
                      report("BORROW_NOT_ACTIVE", "violation", "completion operation has no active borrow", fn, line, nextChain)
                      continue
                    let ended = branchPath.loans[key]
                    branchPath.loans.del key
                    # what the device's access leaves behind on the bytes it held (stale caches after
                    # a device write, for instance) starts exactly when the borrow ends
                    for mark in ended.marksOnRelease:
                      setMark(branchPath, ended.origin, mark, (ended.lo, ended.hi), ended.rangeKnown)
                  if op.borrowArgument > 0:
                    if key in branchPath.loans:
                      report("BORROW_ALREADY_ACTIVE", "violation", "resource already holds an asynchronous borrow", fn, line, nextChain)
                      continue
                    if op.borrowArgument > arguments.len:
                      report("BORROW_ARGUMENT_MISMATCH", "unverified", "borrowed buffer argument is absent", fn, line, nextChain)
                      continue
                    let buffer = arguments[op.borrowArgument - 1]
                    if not access(branchPath, buffer, op.borrowMode, fn, line, nextChain): continue
                    if op.minBytes > 0:
                      let extent = argumentExtents[op.borrowArgument - 1]
                      let established = extent.known and not extent.invalid
                      let capacity = extent.size - extent.offset
                      let requirement = %*{"protocol": id, "source": cfg.protocols[id].origin,
                        "argument": op.borrowArgument, "requiredMinimumBytes": op.minBytes,
                        "file": fn.file, "line": line, "callChain": nextChain,
                        "resultCase": op.resultCase,
                        "status": (if extent.invalid: "violation" elif not established: "unverified" elif capacity < op.minBytes: "violation" else: "verified"),
                        "storageBytes": (if established: %extent.size else: newJNull()),
                        "byteOffset": (if established: %extent.offset else: newJNull()),
                        "availableBytes": (if established: %capacity else: newJNull()), "unit": "c-sizeof-bytes"}
                      if requirement notin outcome.capacityEvidence: outcome.capacityEvidence.add requirement
                      if extent.invalid:
                        report("BORROW_POINTER_RANGE", "violation", "borrow pointer arithmetic leaves its storage range", fn, line, nextChain, capacityRequirement = requirement)
                        continue
                      if not established:
                        report("UNKNOWN_BORROW_CAPACITY", "unverified", "buffer capacity is not established", fn, line, nextChain, capacityRequirement = requirement)
                        continue
                      if capacity < op.minBytes:
                        report("BORROW_CAPACITY_REQUIREMENT", "violation", "buffer is smaller than the required borrow capacity", fn, line, nextChain, capacityRequirement = requirement)
                        continue
                    if op.alignment > 0:
                      let extent = argumentExtents[op.borrowArgument - 1]
                      let status = alignmentStatus(extent, op.alignment)
                      let requirement = %*{"protocol": id, "source": cfg.protocols[id].origin,
                        "argument": op.borrowArgument, "requiredAlignment": op.alignment,
                        "baseAlignment": (if extent.alignment > 0: %extent.alignment else: newJNull()),
                        "byteOffset": (if extent.known and not extent.invalid: %extent.offset else: newJNull()),
                        "file": fn.file, "line": line, "callChain": nextChain, "resultCase": op.resultCase,
                        "status": status, "unit": "c-sizeof-bytes"}
                      if requirement notin outcome.alignmentEvidence: outcome.alignmentEvidence.add requirement
                      if status != "verified":
                        let code = if extent.invalid: "BORROW_POINTER_RANGE"
                                   elif status == "violation": "BORROW_ALIGNMENT_REQUIREMENT"
                                   else: "UNKNOWN_BORROW_ALIGNMENT"
                        report(code, status, "borrow pointer alignment requirement is not satisfied or established", fn, line, nextChain, alignmentRequirement = requirement)
                        continue
                    var resourceBuffer = buffer == resource
                    for protocol in selected:
                      if protocol & "\0" & buffer in branchPath.states: resourceBuffer = true
                    if resourceBuffer:
                      report("UNSUPPORTED_RESOURCE_BORROW", "unverified", "borrowing a protocol resource as buffer needs a refinement model", fn, line, nextChain)
                      continue
                    if op.requireRegion.len > 0:
                      # The borrowed storage's region comes only from a declaration: its allocation
                      # contract, or the project's placement of automatic storage.
                      let allocator = branchPath.allocators.getOrDefault(buffer)
                      let region = if allocator.len > 0: cfg.contracts[allocator].allocRegion else: cfg.automaticRegion
                      var missing: seq[string]
                      if region.len > 0:
                        for property in op.requireRegion:
                          if property notin cfg.regions[region].properties: missing.add property
                      let status = if region.len == 0: "unverified" elif missing.len > 0: "violation" else: "verified"
                      let requirement = %*{"protocol": id, "source": cfg.protocols[id].origin,
                        "argument": op.borrowArgument, "requiredProperties": op.requireRegion,
                        "storage": (if allocator.len > 0: "allocation" else: "automatic"),
                        "allocator": (if allocator.len > 0: %allocator else: newJNull()),
                        "region": (if region.len > 0: %region else: newJNull()),
                        "regionSource": (if region.len > 0: %cfg.regions[region].origin else: newJNull()),
                        "placementSource": (if allocator.len > 0: %cfg.contracts[allocator].origin
                                            elif region.len > 0: %cfg.automaticRegionOrigin else: newJNull()),
                        "missingProperties": missing,
                        "file": fn.file, "line": line, "callChain": nextChain, "resultCase": op.resultCase,
                        "status": status}
                      if requirement notin outcome.regionEvidence: outcome.regionEvidence.add requirement
                      if status == "unverified":
                        report("UNKNOWN_BORROW_REGION", status, "the region holding the borrowed storage is not declared",
                          fn, line, nextChain, regionRequirement = requirement)
                        continue
                      if status == "violation":
                        report("BORROW_REGION_REQUIREMENT", status, "borrowed storage lies in region '" & region &
                          "', which lacks " & $missing, fn, line, nextChain, regionRequirement = requirement)
                        continue
                    let length = if op.lengthArgument == 0: -2.BiggestInt
                                 elif op.lengthArgument <= argumentLengths.len: argumentLengths[op.lengthArgument - 1]
                                 else: -1.BiggestInt
                    let (loanSpan, loanKnown) = markSpan(argumentExtents[op.borrowArgument - 1], length)
                    if op.requireMarks.len > 0 and
                        not marksHold(branchPath, buffer, op.requireMarks, loanSpan, loanKnown, id,
                                      op.borrowArgument, fn, line, nextChain):
                      continue
                    if op.borrowMode == "write": branchPath.values.del buffer
                    branchPath.loans[key] = Loan(origin: buffer, resource: resource, mode: op.borrowMode,
                      protocol: id, file: fn.file, line: line, chain: nextChain,
                      lo: loanSpan.lo, hi: loanSpan.hi, rangeKnown: loanKnown,
                      marksOnRelease: op.marksOnRelease)
                  branchPath.states[key] = op.target
                  branchPath.lastResult = if op.resultCase.len == 0: "unknown" else: op.resultCase
                  result.add branchPath
        if matched: continue
        if symbol in functions:
          if symbol in chain:
            discard allowEffects(path, @["recurse"], fn, line, nextChain)
            report("UNSUPPORTED_PROTOCOL_RECURSION", "unverified", "recursive protocol call", fn, line, nextChain)
          else:
            result.add invoke(symbol, arguments, path, frame & "/" & symbol & "@" & $line, nextChain, argumentValues, argumentExtents, argumentPointerKinds)
        else:
          if symbol in cfg.boundaries:
            report("BOUNDARY_BODY_UNAVAILABLE", "unverified", "function boundary cannot replace an unavailable implementation", fn, line, nextChain)
            continue
          if not externalAccesses(path, symbol, arguments, argumentExtents, fn, line, nextChain, argumentLengths, argumentPointerKinds): continue
          fenced(path, symbol)
          if symbol in cfg.contracts and cfg.contracts[symbol].returnArgument > 0:
            let index = cfg.contracts[symbol].returnArgument - 1
            if not node.getOrDefault("returnsPointer").getBool or index >= arguments.len:
              report("POINTER_RETURN_ARGUMENT_MISMATCH", "unverified", "returnPointer needs a pointer result and an available argument", fn, line, nextChain)
              continue
            let origin = arguments[index]
            let extent = shiftedRange(argumentExtents[index], cfg.contracts[symbol].returnOffset)
            if origin.len == 0 or not extent.known:
              report("UNKNOWN_POINTER_RETURN_CONTRACT", "unverified", "returnPointer argument origin and position are not established", fn, line, nextChain)
              continue
            if origin in path.dead:
              report("EXPIRED_BORROW_ORIGIN", "violation", "returnPointer argument has expired", fn, line, nextChain)
              continue
            if extent.invalid:
              report("MEMORY_POINTER_RANGE", "violation", "returnPointer argument or returned position leaves its storage range", fn, line, nextChain)
              continue
            path.lastPointer = origin
            path.lastPointerKind = "origin"
            path.lastPointerExtent = extent
          var allocated = true
          var beforeAllocation: Path
          if symbol in cfg.contracts and cfg.contracts[symbol].allocates:
            let contract = cfg.contracts[symbol]
            if not node.getOrDefault("returnsPointer").getBool or contract.allocSizeArgument > arguments.len or
                contract.allocCountArgument > arguments.len:
              report("ALLOCATION_ARGUMENT_MISMATCH", "unverified", "allocates needs a pointer result and its size arguments", fn, line, nextChain)
              continue
            beforeAllocation = path
            path.lastPointer = allocation(path, frame & "|heap@" & $node["site"].getInt)
            path.allocators[path.lastPointer] = symbol
            path.lastPointerKind = "origin"
            var bytes = argumentLengths[contract.allocSizeArgument - 1]
            if contract.allocCountArgument > 0:
              let count = argumentLengths[contract.allocCountArgument - 1]
              bytes = if bytes < 0 or count < 0: -1
                      elif count > 0 and bytes > high(BiggestInt) div count: -1
                      else: bytes * count
            path.lastPointerExtent = StorageRange(size: max(bytes, 0), alignment: contract.allocAlignment,
                                                  known: bytes >= 0, atStart: true)
            path.allocatedBytes[path.lastPointer] = bytes
            allocated = resourceLimits(path, symbol, fn, line, nextChain)
          if selected.len == 0 or (symbol in cfg.contracts and cfg.contracts[symbol].preservesProtocols):
            if allocated: result.add path
            if symbol in cfg.contracts and (cfg.contracts[symbol].returnNullable or cfg.contracts[symbol].allocNullable):
              # a null result allocated nothing
              var nullPath = if symbol in cfg.contracts and cfg.contracts[symbol].allocates: beforeAllocation else: path
              nullPath.lastPointer = ""
              nullPath.lastPointerKind = "null"
              nullPath.lastPointerExtent = StorageRange()
              result.add nullPath
          else:
            report("MISSING_PROTOCOL_CONTRACT", "unverified",
              "external call does not establish preservation or transitions of selected protocols", fn, line, nextChain)
      else:
        report("UNSUPPORTED_PROTOCOL_MODEL", "unverified",
          node.getOrDefault("reason").getStr("unmodeled protocol construct"), fn, line, chain)
    # Keep path explosion bounded without throwing away states as if proven.
    if result.len > 256:
      report("PROTOCOL_ANALYSIS_LIMIT", "unverified", "protocol path budget exceeded", fn, line, chain)
      result = @[]

  let owner = functions[root].protocolOwner
  let entry = if owner.len > 0: owner else: root
  if entry notin functions:
    report("UNKNOWN_PROTOCOL_SCOPE", "unverified", "enclosing function is unavailable", functions[root], functions[root].first, @[root])
  else:
    # whether the caller wrote memory just before entry is not known
    var start = Path()
    for kind in cfg.barrierKinds: start.unfenced.incl "?" & kind
    discard invoke(entry, @[], start, entry, @[entry])
  result = outcome
