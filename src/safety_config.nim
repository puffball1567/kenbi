## Strict, versioned configuration for source-level effect requirements.
## The parser rejects duplicate keys BEFORE constructing JSON objects.
import std/[json, strutils, tables, sets, os, unicode, algorithm]
import checksums/sha1

type
  SafetyConfigError* = object of CatchableError
  MemoryAccess* = object
    argument*, minBytes*, alignment*: int
    mode*: string
  RegionSpec* = object
    ## A named memory region and the properties it has ("dma": a DMA engine can reach it). Which
    ## storage lies in which region is declared separately; nothing is placed by guessing.
    id*, origin*: string
    properties*: seq[string]
  MmioRegister* = object
    ## One memory-mapped register: where it is, how wide an access must be, which accesses are
    ## allowed, and bits with access rules. Masks cover the register's width.
    id*, origin*, assumption*: string
    address*, width*: BiggestInt
    access*: string                 ## read-write, read-only or write-only
    reservedMask*: BiggestInt
    reservedWrite*: string          ## zero: written as 0; preserve: written back as read
    reservedReadsZero*: bool        ## declared: reserved bits always read as 0
    writeOneToClear*, readToClear*: BiggestInt
    requiresBarrier*: string        ## barrier kind that must separate earlier memory writes from a write here
  MmioBlock* = object
    ## An address range that holds registers only: an address in it that no register declares is
    ## an error, not an unknown.
    id*, origin*: string
    base*, size*: BiggestInt
  StackFrame* = object
    ## One function's frame from a compiler stack-usage report, bound to the exact source it was
    ## produced from. `bounded` is false for a frame the compiler reports as dynamic.
    bytes*: BiggestInt
    bounded*: bool
    report*, assumption*: string
    perCallBytes*: BiggestInt
  StackKey* = tuple[source: string, line: int, name: string]
  TimingBound* = object
    ## An external timing figure for one function, callees included, as a tool reported it.
    ## Only a static analysis bound can establish a limit; a measurement cannot.
    value*: BiggestInt
    unit*, methodKind*, tool*, origin*, assumption*: string
    stale*: string                  ## why the figure no longer describes this build, if it does not
  MarkSpec* = object
    ## A named fact about a byte range of a storage object that operations establish and that
    ## CPU accesses can end — "the CPU caches for these bytes have been written back", "these
    ## bytes were written by a device and the CPU caches may be stale". Generic: the analyzer
    ## knows no mark by name, only what its definition says it does.
    id*, origin*: string
    clearedBy*: seq[string]  ## CPU access modes (read / write) that end the mark on the bytes touched
    forbids*: seq[string]    ## CPU access modes that are violations on marked bytes
  MarkEffect* = object
    ## An external function sets or clears marks on the bytes its pointer argument addresses:
    ## `lengthArgument` bytes from the pointer (a compile-time constant at the call), or, without
    ## it, from the pointer to the end of the storage.
    argument*, lengthArgument*: int
    setMarks*, clearMarks*: seq[string]
  EffectContract* = object
    returnArgument*, returnOffset*: int
    returnNullable*: bool
    allocates*: bool                ## the result is a new storage object (see allocSize etc.)
    allocSizeArgument*, allocCountArgument*: int
    allocAlignment*: int            ## declared alignment of every non-null result
    allocNullable*: bool
    allocReleasedBy*: seq[string]   ## the only functions that may release or relocate a result
    allocRegion*: string            ## the region every result lies in, if declared
    allocCapacity*: int             ## most results live at once the allocator supports; 0: not declared
    maxStackBytes*: BiggestInt      ## stack an external function uses, callees included; -1: not declared
    barrier*: seq[string]           ## barrier kinds a call establishes (memory writes before it complete first)
    maxCallDepth*: int
    symbol*, assumption*, package*, version*, origin*: string
    effects*: seq[string]
    preservesProtocols*: bool
    contextsDeclared*: bool
    contexts*: seq[string]
    accessesDeclared*: bool
    accesses*: seq[MemoryAccess]
    marks*: seq[MarkEffect]
  ProtocolOutcome* = object
    result*, target*, borrowMode*: string
    borrowArgument*: int
    minBytes*, alignment*: int
    releaseBorrow*: bool
    lengthArgument*: int            ## bytes the borrow covers; without it, to the end of storage
    requireMarks*: seq[string]      ## marks the borrowed bytes must carry when the borrow starts
    requireRegion*: seq[string]     ## properties the region holding the borrowed storage must have
    marksOnRelease*: seq[string]    ## marks placed on the borrowed bytes when the borrow ends
  ProtocolOperation* = object
    symbol*, target*: string
    argument*: int
    sources*: seq[string]
    borrowArgument*: int
    minBytes*, alignment*: int
    borrowMode*: string
    releaseBorrow*: bool
    lengthArgument*: int
    requireMarks*: seq[string]
    requireRegion*: seq[string]
    marksOnRelease*: seq[string]
    resultCase*: string
    outcomes*: seq[ProtocolOutcome]
  BoundaryState* = object
    state*, mode*: string
    bufferArgument*: int
  BoundaryOutcome* = object
    result*: string
    exit*: BoundaryState
  ProtocolBoundary* = object
    symbol*, protocol*, origin*: string
    argument*: int
    entry*, exit*: BoundaryState
    outcomes*: seq[BoundaryOutcome]
  ProtocolSpec* = object
    id*, initial*, package*, version*, origin*: string
    states*, terminal*: seq[string]
    forbidWhile*: Table[string, seq[string]]
    operations*: seq[ProtocolOperation]
  SafetyCheck* = object
    file*, function*, symbol*, profile*: string
  ArtifactBinding* = object
    path*, sha1*, role*, package*, version*, source*: string
  CompilationBinding* = object
    arguments*: seq[string]
    directory*, clangVersion*, package*, version*, source*: string
  TargetBinding* = object
    triple*, package*, version*, source*: string
    pointerWidth*: int
  SafetyConfig* = object
    id*: string
    sources*, arguments*, accepted*: seq[string]
    profiles*: Table[string, seq[string]]
    contexts*: Table[string, seq[string]]
    profileContexts*: Table[string, string]
    depthLimits*: Table[string, int]
    heapBudgets*: Table[string, BiggestInt]   ## profile -> most bytes of allocated storage live at once
    stackBudgets*: Table[string, BiggestInt]  ## profile -> most stack bytes a checked function may use
    stackFrames*: Table[StackKey, StackFrame]
    staleStackSources*: Table[string, string] ## source -> report whose recorded source hash no longer matches
    interruptHandlers*: seq[tuple[symbol: string, priority: int]]
    interruptNesting*: string                 ## by-priority or none; empty when no interrupts are declared
    interruptEntryBytes*: BiggestInt          ## stack the hardware adds on entering each handler
    interruptOrigin*: string
    timeBudgets*: Table[string, tuple[value: BiggestInt, unit: string]]  ## profile -> execution time limit
    timingBounds*: Table[tuple[source, name: string], seq[TimingBound]]
    memoryProfiles*: HashSet[string]
    protocolProfiles*: Table[string, seq[string]]
    protocols*: Table[string, ProtocolSpec]
    boundaries*: Table[string, seq[ProtocolBoundary]]
    checks*: seq[SafetyCheck]
    contracts*: Table[string, EffectContract]
    inputs*: seq[tuple[path, digest: string]]
    artifacts*: seq[ArtifactBinding]
    compilationBindings*: seq[CompilationBinding]
    targetBindings*: seq[TargetBinding]
    marks*: Table[string, MarkSpec]
    regions*: Table[string, RegionSpec]
    mmioRegisters*: seq[MmioRegister]
    mmioBlocks*: seq[MmioBlock]
    barrierKinds*: seq[string]      ## every barrier kind some contract establishes
    automaticRegion*, automaticRegionOrigin*: string  ## where automatic storage is placed, if declared

proc requiresAccessCapacity*(cfg: SafetyConfig): bool =
  for contract in cfg.contracts.values:
    for access in contract.accesses:
      if access.minBytes > 0: return true

proc requiresAccessAlignment*(cfg: SafetyConfig): bool =
  for contract in cfg.contracts.values:
    for access in contract.accesses:
      if access.alignment > 0: return true

proc requiresMemoryAccess*(cfg: SafetyConfig): bool =
  if cfg.requiresAccessCapacity or cfg.requiresAccessAlignment: return true
  for contract in cfg.contracts.values:
    if contract.returnArgument > 0 or contract.allocates: return true

proc variants*(op: ProtocolOperation): seq[ProtocolOperation] =
  if op.outcomes.len == 0: return @[op]
  for outcome in op.outcomes:
    var branch = op
    branch.outcomes = @[]
    branch.resultCase = outcome.result
    branch.target = outcome.target
    branch.alignment = outcome.alignment
    branch.minBytes = outcome.minBytes
    branch.borrowArgument = outcome.borrowArgument
    branch.borrowMode = outcome.borrowMode
    branch.releaseBorrow = outcome.releaseBorrow
    branch.lengthArgument = outcome.lengthArgument
    branch.requireMarks = outcome.requireMarks
    branch.requireRegion = outcome.requireRegion
    branch.marksOnRelease = outcome.marksOnRelease
    result.add branch

const heapPrimitives* = ["c:@F@malloc", "c:@F@calloc", "c:@F@realloc",
  "c:@F@aligned_alloc", "c:@F@posix_memalign", "c:@F@strdup", "c:@F@strndup"]

const supportedEffects* = ["heap_allocate", "block", "wait", "recurse"]

proc fail*(message: string) {.noreturn.} =
  raise newException(SafetyConfigError, message)

proc strictJson*(source, filename: string): JsonNode =
  if source.len > 4 * 1024 * 1024: fail(filename & ": configuration exceeds 4 MiB")
  if validateUtf8(source) >= 0: fail(filename & ": invalid UTF-8")
  var pos = 0
  proc ws() =
    while pos < source.len and source[pos] in {' ', '\r', '\n', '\t'}: inc pos
  proc bad(message: string) {.noreturn.} =
    fail(filename & ": byte " & $pos & ": " & message)
  proc quoted(): string =
    if pos >= source.len or source[pos] != '"': bad("expected JSON string")
    let first = pos
    inc pos
    while pos < source.len:
      let ch = source[pos]
      inc pos
      if ch == '"':
        try: return parseJson(source[first ..< pos]).getStr
        except ValueError: bad("invalid string")
      if ord(ch) < 32: bad("control character in string")
      if ch == '\\':
        if pos >= source.len: bad("unfinished escape")
        let esc = source[pos]
        inc pos
        if esc == 'u':
          for i in 0 ..< 4:
            if pos >= source.len or source[pos] notin HexDigits: bad("invalid unicode escape")
            inc pos
        elif esc notin {'"', '\\', '/', 'b', 'f', 'n', 'r', 't'}: bad("invalid escape")
    bad("unterminated string")
  proc value(depth: int): JsonNode =
    if depth > 64: bad("configuration nesting exceeds 64")
    ws()
    if pos >= source.len: bad("expected value")
    case source[pos]
    of '{':
      inc pos; ws()
      result = newJObject()
      if pos < source.len and source[pos] == '}': inc pos; return
      while true:
        ws()
        let key = quoted()
        if result.hasKey(key): bad("duplicate key '" & key & "'")
        ws()
        if pos >= source.len or source[pos] != ':': bad("expected ':'")
        inc pos
        result[key] = value(depth + 1)
        ws()
        if pos < source.len and source[pos] == '}': inc pos; return
        if pos >= source.len or source[pos] != ',': bad("expected ',' or '}'")
        inc pos
    of '[':
      inc pos; ws()
      result = newJArray()
      if pos < source.len and source[pos] == ']': inc pos; return
      while true:
        result.add value(depth + 1)
        ws()
        if pos < source.len and source[pos] == ']': inc pos; return
        if pos >= source.len or source[pos] != ',': bad("expected ',' or ']'")
        inc pos
    of '"': result = %quoted()
    of 't', 'f', 'n':
      let token = (case source[pos]
        of 't': "true"
        of 'f': "false"
        else: "null")
      if pos + token.len > source.len or source[pos ..< pos + token.len] != token:
        bad("invalid literal")
      pos += token.len
      result = parseJson(token)
    of '-', '0'..'9':
      let first = pos
      if source[pos] == '-': inc pos
      if pos >= source.len or source[pos] notin Digits: bad("invalid number")
      if source[pos] == '0': inc pos
      else:
        while pos < source.len and source[pos] in Digits: inc pos
      if pos < source.len and source[pos] == '.':
        inc pos
        if pos >= source.len or source[pos] notin Digits: bad("invalid fraction")
        while pos < source.len and source[pos] in Digits: inc pos
      if pos < source.len and source[pos] in {'e', 'E'}:
        inc pos
        if pos < source.len and source[pos] in {'+', '-'}: inc pos
        if pos >= source.len or source[pos] notin Digits: bad("invalid exponent")
        while pos < source.len and source[pos] in Digits: inc pos
      try: result = parseJson(source[first ..< pos])
      except ValueError: bad("number out of range")
    else: bad("invalid JSON token")
  result = value(0)
  ws()
  if pos != source.len: bad("trailing input")

proc keys(n: JsonNode, allowed: openArray[string], where: string) =
  if n.kind != JObject: fail(where & ": expected object")
  for key in n.keys:
    if key notin allowed: fail(where & ": unknown key '" & key & "'")

proc word(n: JsonNode, key, where: string): string =
  if not n.hasKey(key) or n[key].kind != JString or n[key].getStr.strip.len == 0:
    fail(where & ": '" & key & "' must be a nonempty string")
  result = n[key].getStr
  if '\0' in result: fail(where & ": NUL in '" & key & "'")

proc strings(n: JsonNode, key, where: string): seq[string] =
  if not n.hasKey(key): return
  if n[key].kind != JArray: fail(where & ": '" & key & "' must be an array")
  for item in n[key]:
    if item.kind != JString or item.getStr.strip.len == 0 or '\0' in item.getStr:
      fail(where & ": '" & key & "' must contain nonempty strings")
    if key != "clangArgs" and item.getStr in result: fail(where & ": duplicate '" & item.getStr & "'")
    result.add item.getStr

proc depthLimit(n: JsonNode, where: string): int =
  if n.kind != JInt or n.getBiggestInt < 1 or n.getBiggestInt > 1000000:
    fail(where & ": maxCallDepth must be an integer from 1 to 1000000")
  n.getInt

proc argumentIndex(n: JsonNode, where: string): int =
  if not n.hasKey("argument") or n["argument"].kind != JInt or
      n["argument"].getBiggestInt < 1 or n["argument"].getBiggestInt > 1024:
    fail(where & ": argument must be a one-based parameter index (1..1024)")
  n["argument"].getInt

proc effectList(n: JsonNode, key, where: string): seq[string] =
  if not n.hasKey(key): fail(where & ": missing '" & key & "'")
  result = strings(n, key, where)
  for effect in result:
    if effect notin supportedEffects: fail(where & ": unknown effect '" & effect & "'")

proc resolved(base, path: string): string =
  normalizedPath(absolutePath(path, base.parentDir))

proc alignmentValue(n: JsonNode, where: string): int =
  if n.kind != JInt or n.getBiggestInt < 1 or n.getBiggestInt > 536870912:
    fail(where & ": alignment must be a power of two from 1 to 536870912")
  result = n.getInt
  if (result and (result - 1)) != 0:
    fail(where & ": alignment must be a power of two")

proc transition(n: JsonNode, resourceArgument: int, where: string): ProtocolOutcome =
  result.target = word(n, "to", where)
  if n.hasKey("borrow"):
    let loan = n["borrow"]
    keys(loan, ["argument", "mode", "minBytes", "alignment", "lengthArgument", "requireMarks", "requireRegion", "marksOnRelease"], where)
    if loan.hasKey("requireRegion"):
      result.requireRegion = strings(loan, "requireRegion", where)
      if result.requireRegion.len == 0: fail(where & ": requireRegion must be nonempty")
    if loan.hasKey("lengthArgument"):
      result.lengthArgument = argumentIndex(%*{"argument": loan["lengthArgument"]}, where)
    if loan.hasKey("requireMarks"):
      result.requireMarks = strings(loan, "requireMarks", where)
      if result.requireMarks.len == 0: fail(where & ": requireMarks must be nonempty")
    if loan.hasKey("marksOnRelease"):
      result.marksOnRelease = strings(loan, "marksOnRelease", where)
      if result.marksOnRelease.len == 0: fail(where & ": marksOnRelease must be nonempty")
    if loan.hasKey("alignment"):
      result.alignment = alignmentValue(loan["alignment"], where)
    if loan.hasKey("minBytes"):
      let n = loan["minBytes"]
      if n.kind != JInt or n.getBiggestInt < 1 or n.getBiggestInt > 1000000000:
        fail(where & ": minBytes must be an integer from 1 to 1000000000")
      result.minBytes = n.getInt
    result.borrowArgument = argumentIndex(loan, where)
    result.borrowMode = word(loan, "mode", where)
    if result.borrowMode notin ["read", "write"]: fail(where & ": borrow mode must be read or write")
    if result.borrowArgument == resourceArgument: fail(where & ": resource cannot borrow itself")
    if result.lengthArgument > 0 and result.lengthArgument in [result.borrowArgument, resourceArgument]:
      fail(where & ": lengthArgument must name a separate argument")
  if n.hasKey("releaseBorrow"):
    if n["releaseBorrow"].kind != JBool: fail(where & ": releaseBorrow must be boolean")
    result.releaseBorrow = n["releaseBorrow"].getBool
  if result.releaseBorrow and result.borrowArgument != 0:
    fail(where & ": cannot acquire and end a borrow in one operation")

proc boundaryState(n: JsonNode, spec: ProtocolSpec, argument: int, path: string): BoundaryState =
  keys(n, ["state", "borrow"], path)
  result.state = word(n, "state", path)
  if result.state notin spec.states: fail(path & ": unknown boundary state")
  if not n.hasKey("borrow"): fail(path & ": boundary must explicitly specify borrow (null for none)")
  if n["borrow"].kind != JNull:
    let loan = n["borrow"]
    keys(loan, ["argument", "mode"], path)
    result.bufferArgument = argumentIndex(loan, path)
    result.mode = word(loan, "mode", path)
    if result.mode notin ["read", "write"] or result.bufferArgument == argument:
      fail(path & ": invalid boundary borrow")

proc markModes(n: JsonNode, key, where: string): seq[string] =
  if not n.hasKey(key): return @[]
  result = strings(n, key, where)
  for mode in result:
    if mode notin ["read", "write"]: fail(where & ": mark " & key & " accepts read and write only")

proc loadSafetyConfig*(path: string): SafetyConfig =
  var cfg: SafetyConfig
  var active, loaded = initHashSet[string]()
  var identities = initTable[string, string]()
  var contractPaths, protocolPaths, stackPaths, timingPaths: seq[string]
  var argumentOwner = ""
  proc read(path, kind: string): JsonNode =
    var source: string
    try: source = readFile(path)
    except IOError as e: fail(path & ": " & e.msg)
    result = strictJson(source, path)
    if result.kind != JObject: fail(path & ": expected object")
    if not result.hasKey("schemaVersion") or result["schemaVersion"].kind != JInt or
        result["schemaVersion"].getBiggestInt != 1: fail(path & ": unsupported schemaVersion")
    if word(result, "kind", path) != kind: fail(path & ": expected kind '" & kind & "'")
    let id = word(result, "id", path)
    if id in identities and identities[id] != path: fail(path & ": duplicate specification id '" & id & "'")
    identities[id] = path
    cfg.inputs.add (path, $secureHash(source))
  proc targetBinding(doc: JsonNode, path: string) =
    if not doc.hasKey("target"): return
    let item = doc["target"]
    keys(item, ["triple", "pointerWidth"], path & ": target")
    let triple = word(item, "triple", path)
    if not item.hasKey("pointerWidth") or item["pointerWidth"].kind != JInt or
        item["pointerWidth"].getBiggestInt < 1 or item["pointerWidth"].getBiggestInt > 65536:
      fail(path & ": target pointerWidth must be an integer from 1 to 65536 bits")
    let width = item["pointerWidth"].getInt
    for previous in cfg.targetBindings:
      if previous.triple != triple or previous.pointerWidth != width:
        fail(path & ": conflicting target requirements with " & previous.source)
    cfg.targetBindings.add TargetBinding(triple: triple, pointerWidth: width,
      package: word(doc, "id", path), version: word(doc, "version", path), source: path)
  proc compilationBinding(doc: JsonNode, path: string) =
    if not doc.hasKey("compilation"): return
    let item = doc["compilation"]
    keys(item, ["clangArgs", "directory", "clangVersion"], path & ": compilation")
    if not item.hasKey("clangArgs"): fail(path & ": compilation requires clangArgs")
    let args = strings(item, "clangArgs", path)
    for arg in args:
      if arg.startsWith("@"): fail(path & ": compilation response files are not supported")
    let directory = resolved(path, word(item, "directory", path))
    let version = word(item, "clangVersion", path)
    let effective = args & @["-working-directory=" & directory]
    for previous in cfg.compilationBindings:
      if previous.arguments != effective or previous.clangVersion != version:
        fail(path & ": conflicting compilation requirements with " & previous.source)
    cfg.compilationBindings.add CompilationBinding(arguments: effective,
      directory: directory, clangVersion: version, package: word(doc, "id", path),
      version: word(doc, "version", path), source: path)
  proc artifacts(doc: JsonNode, path: string) =
    if not doc.hasKey("artifacts"): return
    if doc["artifacts"].kind != JArray or doc["artifacts"].len == 0:
      fail(path & ": artifacts must be a nonempty array")
    var local = initHashSet[string]()
    for item in doc["artifacts"]:
      keys(item, ["path", "sha1", "role"], path & ": artifact")
      let file = resolved(path, word(item, "path", path))
      let digest = word(item, "sha1", path).toUpperAscii
      let role = word(item, "role", path)
      if digest.len != 40: fail(path & ": artifact sha1 must contain 40 hexadecimal digits")
      for ch in digest:
        if ch notin {'0'..'9', 'A'..'F'}: fail(path & ": invalid artifact sha1")
      if role notin ["parsed-input", "external-artifact"]: fail(path & ": unknown artifact role")
      if file in local: fail(path & ": duplicate artifact path")
      local.incl file
      for existing in cfg.artifacts:
        if existing.path == file and existing.sha1 != digest:
          fail(path & ": conflicting artifact digest for " & file)
      if not fileExists(file): fail(path & ": artifact file is missing: " & file)
      let actual = $secureHash(readFile(file))
      if actual != digest: fail(path & ": artifact content mismatch: " & file)
      cfg.inputs.add (file, actual)
      cfg.artifacts.add ArtifactBinding(path: file, sha1: digest, role: role,
        package: word(doc, "id", path), version: word(doc, "version", path), source: path)
  var regionReferences: seq[tuple[region, where: string]]
  var propertyReferences: seq[tuple[property, where: string]]
  proc project(path: string) =
    if path in active: fail(path & ": cyclic extends")
    if path in loaded: return
    if active.len >= 64 or loaded.len >= 256: fail(path & ": specification graph too large")
    active.incl path
    let doc = read(path, "project")
    keys(doc, ["schemaVersion", "kind", "id", "extends", "sources", "clangArgs",
      "contracts", "protocols", "contexts", "profiles", "checks", "acceptedAssumptions", "placement", "stackUsage", "timing", "interrupts"], path)
    if doc.hasKey("interrupts"):
      # Handlers that may preempt the checked code, and how they nest. Their stack adds to every
      # stack bound; nothing about interrupts is assumed when this is absent.
      if cfg.interruptNesting.len > 0: fail(path & ": interrupts are already declared in " & cfg.interruptOrigin)
      let spec = doc["interrupts"]
      keys(spec, ["nesting", "entryBytes", "handlers"], path & ": interrupts")
      cfg.interruptNesting = word(spec, "nesting", path & ": interrupts")
      if cfg.interruptNesting notin ["by-priority", "none"]: fail(path & ": interrupts.nesting must be by-priority or none")
      if not spec.hasKey("entryBytes") or spec["entryBytes"].kind != JInt or spec["entryBytes"].getBiggestInt < 0 or
          spec["entryBytes"].getBiggestInt > 4096:
        fail(path & ": interrupts.entryBytes must be an integer from 0 to 4096")
      cfg.interruptEntryBytes = spec["entryBytes"].getBiggestInt
      cfg.interruptOrigin = path
      if not spec.hasKey("handlers") or spec["handlers"].kind != JArray or spec["handlers"].len == 0:
        fail(path & ": interrupts.handlers must be a nonempty array")
      for item in spec["handlers"]:
        keys(item, ["symbol", "priority"], path & ": interrupt handler")
        let symbol = word(item, "symbol", path & ": interrupt handler")
        if not item.hasKey("priority") or item["priority"].kind != JInt or item["priority"].getBiggestInt < 0 or
            item["priority"].getBiggestInt > 1024:
          fail(path & ": interrupt priority must be an integer from 0 to 1024 (larger preempts smaller)")
        for other in cfg.interruptHandlers:
          if other.symbol == symbol: fail(path & ": interrupt handler '" & symbol & "' is declared twice")
        cfg.interruptHandlers.add (symbol, item["priority"].getInt)
    for spec in strings(doc, "timing", path):
      let file = resolved(path, spec)
      if file notin timingPaths: timingPaths.add file
    for spec in strings(doc, "stackUsage", path):
      let file = resolved(path, spec)
      if file notin stackPaths: stackPaths.add file
    if doc.hasKey("placement"):
      keys(doc["placement"], ["automatic"], path & ": placement")
      let region = word(doc["placement"], "automatic", path & ": placement")
      if cfg.automaticRegion.len > 0 and cfg.automaticRegion != region:
        fail(path & ": placement.automatic conflicts with " & cfg.automaticRegionOrigin)
      cfg.automaticRegion = region
      cfg.automaticRegionOrigin = path
      regionReferences.add (region, path)
    for parent in strings(doc, "extends", path): project(resolved(path, parent))
    cfg.id = word(doc, "id", path)
    for source in strings(doc, "sources", path):
      let file = resolved(path, source)
      if file notin cfg.sources: cfg.sources.add file
    if doc.hasKey("clangArgs"):
      var args = strings(doc, "clangArgs", path)
      for arg in args:
        if arg.startsWith("@"): fail(path & ": compiler response files are not supported")
      args.add "-working-directory=" & path.parentDir
      if argumentOwner.len > 0 and args != cfg.arguments:
        fail(path & ": clangArgs conflict with " & argumentOwner)
      cfg.arguments = args; argumentOwner = path
    for contract in strings(doc, "contracts", path):
      let file = resolved(path, contract)
      if file notin contractPaths: contractPaths.add file
    for spec in strings(doc, "protocols", path):
      let file = resolved(path, spec)
      if file notin protocolPaths: protocolPaths.add file
    for assumption in strings(doc, "acceptedAssumptions", path):
      if assumption notin cfg.accepted: cfg.accepted.add assumption
    if doc.hasKey("contexts"):
      if doc["contexts"].kind != JObject: fail(path & ": contexts must be an object")
      for id, context in doc["contexts"]:
        if id.strip.len == 0 or '\0' in id: fail(path & ": invalid context id")
        keys(context, ["forbid"], path & ": context " & id)
        let effects = effectList(context, "forbid", path)
        discard cfg.contexts.mgetOrPut(id, @[])
        for effect in effects:
          if effect notin cfg.contexts[id]: cfg.contexts[id].add effect
    if doc.hasKey("profiles"):
      if doc["profiles"].kind != JObject: fail(path & ": profiles must be an object")
      for id, profile in doc["profiles"]:
        if id.strip.len == 0: fail(path & ": empty profile id")
        keys(profile, ["forbid", "protocols", "context", "maxCallDepth", "memoryAccess", "maxLiveHeapBytes", "maxStackBytes", "maxExecutionTime"], path & ": profile " & id)
        if profile.hasKey("maxExecutionTime"):
          let limit = profile["maxExecutionTime"]
          keys(limit, ["value", "unit"], path & ": maxExecutionTime")
          if not limit.hasKey("value") or limit["value"].kind != JInt or limit["value"].getBiggestInt < 1:
            fail(path & ": maxExecutionTime.value must be a positive integer")
          let unit = word(limit, "unit", path & ": maxExecutionTime")
          if unit notin ["cycles", "ns"]: fail(path & ": maxExecutionTime.unit must be cycles or ns")
          if id in cfg.timeBudgets and cfg.timeBudgets[id].unit != unit:
            fail(path & ": maxExecutionTime of profile '" & id & "' is given in different units")
          let value = min(cfg.timeBudgets.getOrDefault(id, (limit["value"].getBiggestInt, unit)).value,
                          limit["value"].getBiggestInt)
          cfg.timeBudgets[id] = (value, unit)
        if profile.hasKey("maxStackBytes"):
          let n = profile["maxStackBytes"]
          if n.kind != JInt or n.getBiggestInt < 1 or n.getBiggestInt > 1_000_000_000:
            fail(path & ": maxStackBytes must be an integer from 1 to 1000000000")
          cfg.stackBudgets[id] = min(cfg.stackBudgets.getOrDefault(id, n.getBiggestInt), n.getBiggestInt)
        let effects = if profile.hasKey("forbid"): effectList(profile, "forbid", path) else: @[]
        let protocols = strings(profile, "protocols", path)
        if profile.hasKey("memoryAccess"):
          if profile["memoryAccess"].kind != JBool or not profile["memoryAccess"].getBool:
            fail(path & ": memoryAccess must be true; requirements cannot be disabled")
          cfg.memoryProfiles.incl id
        if profile.hasKey("context"):
          let context = word(profile, "context", path)
          if id in cfg.profileContexts and cfg.profileContexts[id] != context:
            fail(path & ": conflicting execution context for profile '" & id & "'")
          cfg.profileContexts[id] = context
        if profile.hasKey("maxCallDepth"):
          let limit = depthLimit(profile["maxCallDepth"], path)
          cfg.depthLimits[id] = min(cfg.depthLimits.getOrDefault(id, limit), limit)
        if profile.hasKey("maxLiveHeapBytes"):
          let n = profile["maxLiveHeapBytes"]
          if n.kind != JInt or n.getBiggestInt < 0 or n.getBiggestInt > 1_000_000_000_000:
            fail(path & ": maxLiveHeapBytes must be an integer from 0 to 1000000000000")
          # composition only strengthens: the smaller budget applies
          cfg.heapBudgets[id] = min(cfg.heapBudgets.getOrDefault(id, n.getBiggestInt), n.getBiggestInt)
        if effects.len == 0 and protocols.len == 0 and not profile.hasKey("context") and not profile.hasKey("maxCallDepth") and
            id notin cfg.memoryProfiles and not profile.hasKey("maxLiveHeapBytes") and not profile.hasKey("maxStackBytes") and
            not profile.hasKey("maxExecutionTime"):
          fail(path & ": profile must require effects, protocols or a context")
        discard cfg.profiles.mgetOrPut(id, @[])
        for protocol in protocols:
          if protocol notin cfg.protocolProfiles.getOrDefault(id):
            cfg.protocolProfiles.mgetOrPut(id, @[]).add protocol
        # Composition only strengthens: a child cannot remove a parent's prohibition.
        for effect in effects:
          if effect notin cfg.profiles.getOrDefault(id):
            cfg.profiles.mgetOrPut(id, @[]).add effect
    if doc.hasKey("checks"):
      if doc["checks"].kind != JArray: fail(path & ": checks must be an array")
      for check in doc["checks"]:
        keys(check, ["file", "function", "symbol", "profile"], path & ": check")
        var item = SafetyCheck(file: resolved(path, word(check, "file", path)),
          function: word(check, "function", path), profile: word(check, "profile", path))
        if check.hasKey("symbol"): item.symbol = word(check, "symbol", path)
        if item notin cfg.checks: cfg.checks.add item
    active.excl path; loaded.incl path
  project(normalizedPath(absolutePath(path)))
  if argumentOwner.len == 0: cfg.arguments.add "-working-directory=" & absolutePath(path).parentDir
  # Mark definitions may come from a contracts document (the API that establishes the mark) or a
  # protocols document (the device that requires it). The same id defined twice must say the same
  # thing; the analyzer never merges two meanings of one name.
  proc markDefinitions(doc: JsonNode, path: string) =
    if not doc.hasKey("marks"): return
    if doc["marks"].kind != JArray or doc["marks"].len == 0: fail(path & ": marks must be a nonempty array")
    for item in doc["marks"]:
      keys(item, ["id", "clearedBy", "forbids"], path & ": mark")
      let spec = MarkSpec(id: word(item, "id", path), origin: path,
        clearedBy: markModes(item, "clearedBy", path), forbids: markModes(item, "forbids", path))
      if spec.clearedBy.len == 0 and spec.forbids.len == 0:
        fail(path & ": mark '" & spec.id & "' must be cleared by or forbid a CPU access")
      if spec.id in cfg.marks:
        let old = cfg.marks[spec.id]
        if old.clearedBy != spec.clearedBy or old.forbids != spec.forbids:
          fail(path & ": conflicting definition of mark '" & spec.id & "' (also in " & old.origin & ")")
      else:
        cfg.marks[spec.id] = spec
  var markReferences: seq[tuple[mark, where: string]]
  proc number(n: JsonNode, where: string, low, high: BiggestInt): BiggestInt =
    ## An integer, or a "0x..." string for addresses and masks written the usual way.
    if n.kind == JInt: result = n.getBiggestInt
    elif n.kind == JString and n.getStr.len > 2 and n.getStr[0 .. 1] in ["0x", "0X"]:
      result = 0
      for ch in n.getStr[2 .. ^1]:
        if ch == '_': continue
        let digit = if ch in '0'..'9': ord(ch) - ord('0')
                    elif ch in 'a'..'f': ord(ch) - ord('a') + 10
                    elif ch in 'A'..'F': ord(ch) - ord('A') + 10
                    else: -1
        if digit < 0: fail(where & " must be an integer or a 0x hexadecimal string")
        if result > (high(BiggestInt) - digit) div 16: fail(where & " is too large")
        result = result * 16 + digit
    else: fail(where & " must be an integer or a 0x hexadecimal string")
    if result < low or result > high: fail(where & " is out of range")
  proc mmioDefinitions(doc: JsonNode, path: string) =
    if not doc.hasKey("mmio"): return
    let spec = doc["mmio"]
    keys(spec, ["assumption", "blocks", "registers"], path & ": mmio")
    # that the hardware behaves as this map says is an external premise, like any API contract
    let assumption = word(spec, "assumption", path & ": mmio")
    if not spec.hasKey("registers") or spec["registers"].kind != JArray or spec["registers"].len == 0:
      fail(path & ": mmio.registers must be a nonempty array")
    if spec.hasKey("blocks"):
      if spec["blocks"].kind != JArray or spec["blocks"].len == 0: fail(path & ": mmio.blocks must be a nonempty array")
      for item in spec["blocks"]:
        keys(item, ["id", "base", "size"], path & ": mmio block")
        let blk = MmioBlock(id: word(item, "id", path & ": mmio block"), origin: path,
          base: number(item.getOrDefault("base"), path & ": mmio block base", 0, high(BiggestInt) div 2),
          size: number(item.getOrDefault("size"), path & ": mmio block size", 1, high(BiggestInt) div 2))
        for other in cfg.mmioBlocks:
          if other.id == blk.id or (blk.base < other.base + other.size and other.base < blk.base + blk.size):
            fail(path & ": mmio block '" & blk.id & "' repeats or overlaps '" & other.id & "' (" & other.origin & ")")
        cfg.mmioBlocks.add blk
    for item in spec["registers"]:
      keys(item, ["id", "address", "width", "access", "reserved", "writeOneToClear", "readToClear", "requiresBarrier"], path & ": register")
      var reg = MmioRegister(id: word(item, "id", path & ": register"), origin: path, assumption: assumption)
      let where = path & ": register '" & reg.id & "'"
      if not item.hasKey("address"): fail(where & ": missing 'address'")
      reg.address = number(item["address"], where & " address", 0, high(BiggestInt) div 2)
      if not item.hasKey("width") or item["width"].kind != JInt or item["width"].getInt notin [1, 2, 4, 8]:
        fail(where & ": width must be 1, 2, 4 or 8 bytes")
      reg.width = item["width"].getBiggestInt
      if reg.address mod reg.width != 0: fail(where & ": address is not aligned to its width")
      reg.access = word(item, "access", where)
      if reg.access notin ["read-write", "read-only", "write-only"]:
        fail(where & ": access must be read-write, read-only or write-only")
      let full = if reg.width == 8: -1.BiggestInt else: (1.BiggestInt shl (8 * reg.width)) - 1
      proc mask(key: string): BiggestInt =
        result = number(item[key], where & " " & key, low(BiggestInt), high(BiggestInt))
        if reg.width < 8 and (result < 0 or (result and not full) != 0): fail(where & ": " & key & " exceeds the register width")
      if item.hasKey("reserved"):
        keys(item["reserved"], ["mask", "write", "readsAs"], where & " reserved")
        if item["reserved"].hasKey("readsAs"):
          if word(item["reserved"], "readsAs", where & " reserved") != "zero":
            fail(where & ": reserved readsAs must be zero")
          reg.reservedReadsZero = true
        if not item["reserved"].hasKey("mask"): fail(where & ": reserved requires 'mask'")
        reg.reservedMask = number(item["reserved"]["mask"], where & " reserved mask", low(BiggestInt), high(BiggestInt))
        if reg.width < 8 and (reg.reservedMask < 0 or (reg.reservedMask and not full) != 0):
          fail(where & ": reserved mask exceeds the register width")
        reg.reservedWrite = word(item["reserved"], "write", where & " reserved")
        if reg.reservedWrite notin ["zero", "preserve"]: fail(where & ": reserved write must be zero or preserve")
      if item.hasKey("requiresBarrier"):
        reg.requiresBarrier = word(item, "requiresBarrier", where)
        if reg.access == "read-only": fail(where & ": a read-only register is never written, so it needs no barrier")
      if item.hasKey("writeOneToClear"): reg.writeOneToClear = mask("writeOneToClear")
      if item.hasKey("readToClear"): reg.readToClear = mask("readToClear")
      if reg.access == "read-only" and reg.writeOneToClear != 0: fail(where & ": a read-only register has no write-one-to-clear bits")
      if reg.access == "write-only" and reg.readToClear != 0: fail(where & ": a write-only register has no read-to-clear bits")
      for other in cfg.mmioRegisters:
        if other.id == reg.id or (reg.address < other.address + other.width and other.address < reg.address + reg.width):
          fail(where & ": repeats or overlaps register '" & other.id & "' (" & other.origin & ")")
      cfg.mmioRegisters.add reg
  proc regionDefinitions(doc: JsonNode, path: string) =
    if not doc.hasKey("regions"): return
    if doc["regions"].kind != JArray or doc["regions"].len == 0: fail(path & ": regions must be a nonempty array")
    for item in doc["regions"]:
      keys(item, ["id", "properties"], path & ": region")
      if not item.hasKey("properties"): fail(path & ": region requires 'properties' (may be empty)")
      var spec = RegionSpec(id: word(item, "id", path), origin: path, properties: strings(item, "properties", path))
      spec.properties.sort()
      if spec.id in cfg.regions:
        if cfg.regions[spec.id].properties != spec.properties:
          fail(path & ": conflicting definition of region '" & spec.id & "' (also in " & cfg.regions[spec.id].origin & ")")
      else:
        cfg.regions[spec.id] = spec
  for path in contractPaths:
    let doc = read(path, "contracts")
    keys(doc, ["schemaVersion", "kind", "id", "version", "functions", "artifacts", "compilation", "target", "marks", "regions"], path)
    markDefinitions(doc, path)
    regionDefinitions(doc, path)
    artifacts(doc, path)
    compilationBinding(doc, path)
    targetBinding(doc, path)
    let version = word(doc, "version", path)
    if not doc.hasKey("functions") or doc["functions"].kind != JArray:
      fail(path & ": functions must be an array")
    for fn in doc["functions"]:
      keys(fn, ["symbol", "effects", "assumption", "preservesProtocols", "accesses", "contexts", "maxCallDepth", "returnPointer", "allocates", "marks", "maxStackBytes", "barrier"], path & ": function")
      if fn.hasKey("barrier"):
        let kinds = strings(fn, "barrier", path)
        if kinds.len == 0: fail(path & ": barrier must be a nonempty array of barrier kinds")
        for kind in kinds:
          if kind notin cfg.barrierKinds: cfg.barrierKinds.add kind
      let symbol = word(fn, "symbol", path)
      if fn.hasKey("preservesProtocols") and fn["preservesProtocols"].kind != JBool:
        fail(path & ": preservesProtocols must be boolean")
      var contract = EffectContract(preservesProtocols: fn.hasKey("preservesProtocols") and fn["preservesProtocols"].getBool, symbol: symbol, effects: effectList(fn, "effects", path),
        assumption: word(fn, "assumption", path), package: word(doc, "id", path),
        version: version, origin: path)
      if fn.hasKey("maxCallDepth"): contract.maxCallDepth = depthLimit(fn["maxCallDepth"], path)
      contract.maxStackBytes = -1
      if fn.hasKey("barrier"): contract.barrier = strings(fn, "barrier", path)
      if fn.hasKey("maxStackBytes"):
        let n = fn["maxStackBytes"]
        if n.kind != JInt or n.getBiggestInt < 0 or n.getBiggestInt > 1_000_000_000:
          fail(path & ": function maxStackBytes must be an integer from 0 to 1000000000")
        contract.maxStackBytes = n.getBiggestInt
      if fn.hasKey("returnPointer"):
        keys(fn["returnPointer"], ["argument", "byteOffset", "nullable"], path & ": returnPointer")
        contract.returnArgument = argumentIndex(fn["returnPointer"], path)
        if fn["returnPointer"].hasKey("nullable"):
          if fn["returnPointer"]["nullable"].kind != JBool:
            fail(path & ": returnPointer.nullable must be boolean")
          contract.returnNullable = fn["returnPointer"]["nullable"].getBool
        if fn["returnPointer"].hasKey("byteOffset"):
          let offset = fn["returnPointer"]["byteOffset"]
          if offset.kind != JInt or offset.getBiggestInt < -1000000000 or offset.getBiggestInt > 1000000000:
            fail(path & ": returnPointer.byteOffset must be an integer from -1000000000 to 1000000000")
          contract.returnOffset = offset.getInt
      if fn.hasKey("allocates"):
        let spec = fn["allocates"]
        keys(spec, ["sizeArgument", "countArgument", "alignment", "nullable", "releasedBy", "region", "capacity"], path & ": allocates")
        if spec.hasKey("capacity"):
          if spec["capacity"].kind != JInt or spec["capacity"].getBiggestInt < 1 or spec["capacity"].getBiggestInt > 1_000_000:
            fail(path & ": allocates.capacity must be an integer from 1 to 1000000")
          contract.allocCapacity = spec["capacity"].getInt
        if spec.hasKey("region"):
          contract.allocRegion = word(spec, "region", path & ": allocates")
          regionReferences.add (contract.allocRegion, path)
        if fn.hasKey("returnPointer"): fail(path & ": allocates cannot be combined with returnPointer")
        contract.allocates = true
        if not spec.hasKey("sizeArgument"): fail(path & ": allocates requires 'sizeArgument'")
        contract.allocSizeArgument = argumentIndex(%*{"argument": spec["sizeArgument"]}, path & ": allocates.sizeArgument")
        if spec.hasKey("countArgument"):
          contract.allocCountArgument = argumentIndex(%*{"argument": spec["countArgument"]}, path & ": allocates.countArgument")
          if contract.allocCountArgument == contract.allocSizeArgument:
            fail(path & ": allocates.countArgument must name a separate argument")
        if not spec.hasKey("alignment"): fail(path & ": allocates requires 'alignment'")
        contract.allocAlignment = alignmentValue(spec["alignment"], path & ": allocates")
        if spec.hasKey("nullable"):
          if spec["nullable"].kind != JBool: fail(path & ": allocates.nullable must be boolean")
          contract.allocNullable = spec["nullable"].getBool
        if not spec.hasKey("releasedBy"): fail(path & ": allocates requires 'releasedBy'")
        contract.allocReleasedBy = strings(spec, "releasedBy", path & ": allocates")
        if contract.allocReleasedBy.len == 0: fail(path & ": allocates.releasedBy must be nonempty")
      if fn.hasKey("contexts"):
        contract.contextsDeclared = true
        contract.contexts = strings(fn, "contexts", path)
        if contract.contexts.len == 0: fail(path & ": API contexts must be nonempty")
        for context in contract.contexts:
          if context notin cfg.contexts: fail(path & ": unknown API context '" & context & "'")
      if fn.hasKey("accesses"):
        contract.accessesDeclared = true
        if fn["accesses"].kind != JArray: fail(path & ": accesses must be an array")
        for entry in fn["accesses"]:
          keys(entry, ["argument", "mode", "minBytes", "alignment"], path)
          var access = MemoryAccess(argument: argumentIndex(entry, path), mode: word(entry, "mode", path))
          if access.mode notin ["read", "write", "release", "relocate"]:
            fail(path & ": unknown memory access mode '" & access.mode & "'")
          if entry.hasKey("minBytes"):
            let n = entry["minBytes"]
            if n.kind != JInt or n.getBiggestInt < 1 or n.getBiggestInt > 1000000000:
              fail(path & ": minBytes must be an integer from 1 to 1000000000")
            if access.mode notin ["read", "write"]:
              fail(path & ": minBytes requires read or write access")
            access.minBytes = n.getInt
          if entry.hasKey("alignment"):
            if access.mode notin ["read", "write"]:
              fail(path & ": alignment requires read or write access")
            access.alignment = alignmentValue(entry["alignment"], path)
          for previous in contract.accesses:
            if previous.argument == access.argument and previous.mode == access.mode:
              fail(path & ": duplicate memory access")
          contract.accesses.add access
      if fn.hasKey("marks"):
        if fn["marks"].kind != JArray or fn["marks"].len == 0: fail(path & ": function marks must be a nonempty array")
        for entry in fn["marks"]:
          keys(entry, ["argument", "lengthArgument", "set", "clear"], path & ": function mark")
          var effect = MarkEffect(argument: argumentIndex(entry, path))
          if entry.hasKey("lengthArgument"):
            effect.lengthArgument = argumentIndex(%*{"argument": entry["lengthArgument"]}, path)
            if effect.lengthArgument == effect.argument: fail(path & ": lengthArgument must name a separate argument")
          if entry.hasKey("set"): effect.setMarks = strings(entry, "set", path)
          if entry.hasKey("clear"): effect.clearMarks = strings(entry, "clear", path)
          if effect.setMarks.len == 0 and effect.clearMarks.len == 0:
            fail(path & ": a function mark must set or clear at least one mark")
          for mark in effect.setMarks:
            if mark in effect.clearMarks: fail(path & ": a function cannot set and clear mark '" & mark & "'")
          for mark in effect.setMarks & effect.clearMarks: markReferences.add (mark, path)
          contract.marks.add effect
      if symbol in cfg.contracts: fail(path & ": conflicting/repeated contract for '" & symbol & "'")
      cfg.contracts[symbol] = contract
  var operationOwners = initTable[string, string]()
  for path in timingPaths:
    # External timing figures (a WCET analyzer's bounds, or measurements), bound to the binary the
    # tool analyzed and to the source it was built from.
    let doc = read(path, "timing")
    keys(doc, ["schemaVersion", "kind", "id", "version", "assumption", "artifact", "sources", "functions"], path)
    discard word(doc, "version", path)
    let assumption = word(doc, "assumption", path)
    var stale = ""
    if not doc.hasKey("artifact"): fail(path & ": timing requires 'artifact' (the analyzed binary and its sha1)")
    keys(doc["artifact"], ["path", "sha1"], path & ": artifact")
    let artifact = resolved(path, word(doc["artifact"], "path", path & ": artifact"))
    let artifactSha = word(doc["artifact"], "sha1", path & ": artifact").toUpperAscii
    try:
      let content = readFile(artifact)
      cfg.inputs.add (artifact, $secureHash(content))
      if $secureHash(content) != artifactSha: stale = "the analyzed binary " & artifact & " has changed"
    except IOError: stale = "the analyzed binary " & artifact & " is not available"
    if not doc.hasKey("sources") or doc["sources"].kind != JArray or doc["sources"].len == 0:
      fail(path & ": sources must be a nonempty array")
    var sources: seq[string]
    for item in doc["sources"]:
      keys(item, ["path", "sha1"], path & ": source")
      let source = resolved(path, word(item, "path", path & ": source"))
      sources.add source
      var current = ""
      try: current = $secureHash(readFile(source))
      except IOError: discard
      if stale.len == 0 and current != word(item, "sha1", path & ": source").toUpperAscii:
        stale = "the bound was produced from a different version of " & source
    if not doc.hasKey("functions") or doc["functions"].kind != JArray or doc["functions"].len == 0:
      fail(path & ": functions must be a nonempty array")
    for item in doc["functions"]:
      keys(item, ["source", "name", "value", "unit", "method", "tool"], path & ": timing function")
      let source = resolved(path, word(item, "source", path & ": timing function"))
      if source notin sources: fail(path & ": timing function source " & source & " is not among the bound sources")
      let name = word(item, "name", path & ": timing function")
      if not item.hasKey("value") or item["value"].kind != JInt or item["value"].getBiggestInt < 0:
        fail(path & ": timing value must be a nonnegative integer")
      let bound = TimingBound(value: item["value"].getBiggestInt, unit: word(item, "unit", path & ": timing function"),
        methodKind: word(item, "method", path & ": timing function"), tool: word(item, "tool", path & ": timing function"),
        origin: path, assumption: assumption, stale: stale)
      if bound.unit notin ["cycles", "ns"]: fail(path & ": timing unit must be cycles or ns")
      if bound.methodKind notin ["static-analysis", "measurement"]:
        fail(path & ": timing method must be static-analysis or measurement")
      cfg.timingBounds.mgetOrPut((source, name), @[]).add bound
  for path in stackPaths:
    # A compiler's stack-usage reports (-fstack-usage), each bound to the source it was produced
    # from. The per-frame figures are the compiler's claim: an assumption, never a proof.
    let doc = read(path, "stackUsage")
    keys(doc, ["schemaVersion", "kind", "id", "version", "assumption", "perCallBytes", "reports"], path)
    discard word(doc, "version", path)
    let assumption = word(doc, "assumption", path)
    if not doc.hasKey("perCallBytes") or doc["perCallBytes"].kind != JInt or
        doc["perCallBytes"].getBiggestInt < 0 or doc["perCallBytes"].getBiggestInt > 4096:
      fail(path & ": perCallBytes must be an integer from 0 to 4096 (stack a call adds beyond the reported frames)")
    let perCall = doc["perCallBytes"].getBiggestInt
    if not doc.hasKey("reports") or doc["reports"].kind != JArray or doc["reports"].len == 0:
      fail(path & ": reports must be a nonempty array")
    for item in doc["reports"]:
      keys(item, ["path", "format", "source", "sourceSha1"], path & ": report")
      let report = resolved(path, word(item, "path", path & ": report"))
      let source = resolved(path, word(item, "source", path & ": report"))
      let format = word(item, "format", path & ": report")
      if format notin ["gcc", "clang"]: fail(path & ": report format must be gcc (file:line:column:name) or clang (file:line:name)")
      let recorded = word(item, "sourceSha1", path & ": report").toUpperAscii
      var text: string
      try: text = readFile(report)
      except IOError as e: fail(report & ": " & e.msg)
      cfg.inputs.add (report, $secureHash(text))
      var current = ""
      try: current = $secureHash(readFile(source))
      except IOError: current = ""
      if current != recorded: cfg.staleStackSources[source] = report
      var number = 0
      for line in text.splitLines:
        inc number
        if line.strip.len == 0: continue
        let where = report & ":" & $number
        let fields = line.split('\t')
        if fields.len != 3: fail(where & ": expected location, bytes and qualifier separated by tabs")
        let location = fields[0].split(':')
        let parts = if format == "gcc": 4 else: 3
        if location.len < parts: fail(where & ": location does not have the " & format & " form")
        let name = location[^1]
        var at: int
        try: at = parseInt(location[^(parts - 1)])
        except ValueError: fail(where & ": invalid line number")
        if format == "gcc":
          try: discard parseInt(location[^2])
          except ValueError: fail(where & ": invalid column number")
        let file = location[0 ..< location.len - (parts - 1)].join(":")
        if file.extractFilename != source.extractFilename:
          fail(where & ": entry for '" & file & "' in the report of " & source)
        var bytes: BiggestInt
        try: bytes = parseBiggestInt(fields[1].strip)
        except ValueError: fail(where & ": invalid byte count")
        if bytes < 0: fail(where & ": negative byte count")
        let qualifier = fields[2].strip
        let bounded = qualifier in ["static", "dynamic,bounded"]
        if qualifier notin ["static", "dynamic", "dynamic,bounded"]: fail(where & ": unknown qualifier '" & qualifier & "'")
        let key: StackKey = (source, at, name)
        if key in cfg.stackFrames: fail(where & ": repeats an entry for " & name & " at line " & $at)
        cfg.stackFrames[key] = StackFrame(bytes: bytes, bounded: bounded, report: report,
          assumption: assumption, perCallBytes: perCall)
  for path in protocolPaths:
    let doc = read(path, "protocols")
    keys(doc, ["schemaVersion", "kind", "id", "version", "machines", "artifacts", "compilation", "target", "marks", "regions", "mmio"], path)
    mmioDefinitions(doc, path)
    markDefinitions(doc, path)
    regionDefinitions(doc, path)
    artifacts(doc, path)
    compilationBinding(doc, path)
    targetBinding(doc, path)
    let version = word(doc, "version", path)
    # a document may only describe the device's memory (registers, regions, marks)
    let describesMemory = doc.hasKey("mmio") or doc.hasKey("regions") or doc.hasKey("marks")
    if not (describesMemory and not doc.hasKey("machines")) and
        (not doc.hasKey("machines") or doc["machines"].kind != JArray or doc["machines"].len == 0):
      fail(path & ": machines must be a nonempty array")
    for machine in doc.getOrDefault("machines").getElems:
      keys(machine, ["id", "states", "initial", "terminal", "operations", "boundaries", "forbidWhile"], path)
      var spec = ProtocolSpec(id: word(machine, "id", path), initial: word(machine, "initial", path),
        states: strings(machine, "states", path), terminal: strings(machine, "terminal", path),
        package: word(doc, "id", path), version: version, origin: path)
      if spec.id in cfg.protocols: fail(path & ": conflicting protocol '" & spec.id & "'")
      if spec.initial notin spec.states or spec.terminal.len == 0:
        fail(path & ": invalid initial or empty terminal states")
      for state in spec.terminal:
        if state notin spec.states: fail(path & ": unknown terminal state '" & state & "'")
      if machine.hasKey("forbidWhile"):
        if machine["forbidWhile"].kind != JObject: fail(path & ": forbidWhile must map states to forbidden effect arrays")
        for state, effects in machine["forbidWhile"]:
          if state notin spec.states: fail(path & ": unknown forbidWhile state '" & state & "'")
          let parsed = effectList(%*{"forbid": effects}, "forbid", path)
          if state == spec.initial and parsed.len > 0:
            fail(path & ": initial-state prohibitions require an established resource; use a transition into the guarded state")
          spec.forbidWhile[state] = parsed
      if not machine.hasKey("operations") or machine["operations"].kind != JArray or machine["operations"].len == 0:
        fail(path & ": operations must be a nonempty array")
      for operation in machine["operations"]:
        keys(operation, ["symbol", "argument", "from", "to", "borrow", "releaseBorrow", "outcomes"], path)
        var op = ProtocolOperation(symbol: word(operation, "symbol", path),
          argument: argumentIndex(operation, path), sources: strings(operation, "from", path))
        if operation.hasKey("outcomes"):
          for key in ["to", "borrow", "releaseBorrow"]:
            if operation.hasKey(key): fail(path & ": outcomes cannot be combined with unconditional transition fields")
          if operation["outcomes"].kind != JArray or operation["outcomes"].len != 2:
            fail(path & ": outcomes must cover zero and nonzero exactly once")
          var cases = initHashSet[string]()
          for item in operation["outcomes"]:
            keys(item, ["result", "to", "borrow", "releaseBorrow"], path)
            var branch = transition(item, op.argument, path)
            branch.result = word(item, "result", path)
            if branch.result notin ["zero", "nonzero"] or branch.result in cases:
              fail(path & ": outcomes must cover zero and nonzero exactly once")
            cases.incl branch.result
            op.outcomes.add branch
        else:
          let branch = transition(operation, op.argument, path)
          op.target = branch.target
          op.alignment = branch.alignment
          op.minBytes = branch.minBytes
          op.borrowArgument = branch.borrowArgument
          op.borrowMode = branch.borrowMode
          op.releaseBorrow = branch.releaseBorrow
          op.lengthArgument = branch.lengthArgument
          op.requireMarks = branch.requireMarks
          op.requireRegion = branch.requireRegion
          op.marksOnRelease = branch.marksOnRelease
        if op.sources.len == 0: fail(path & ": invalid transition")
        for branch in variants(op):
          if branch.target notin spec.states: fail(path & ": invalid transition target")
          for mark in branch.requireMarks & branch.marksOnRelease: markReferences.add (mark, path)
          for property in branch.requireRegion: propertyReferences.add (property, path)
          if branch.marksOnRelease.len > 0 and branch.borrowArgument == 0:
            fail(path & ": marksOnRelease belongs to the operation that starts the borrow")
        for state in op.sources:
          if state notin spec.states: fail(path & ": unknown source state '" & state & "'")
        if op.symbol in operationOwners: fail(path & ": conflicting protocol operation '" & op.symbol & "'")
        if op.symbol notin cfg.contracts: fail(path & ": protocol operation requires external effect contract '" & op.symbol & "'")
        if cfg.contracts[op.symbol].preservesProtocols: fail(path & ": protocol operation cannot preserve all protocols")
        if cfg.contracts[op.symbol].returnArgument > 0: fail(path & ": returnPointer cannot be combined with a protocol operation")
        if cfg.contracts[op.symbol].allocates: fail(path & ": allocates cannot be combined with a protocol operation")
        operationOwners[op.symbol] = spec.id
        spec.operations.add op
      var acquires, releases = false
      for operation in spec.operations:
        for op in variants(operation):
          acquires = acquires or op.borrowArgument > 0
          releases = releases or op.releaseBorrow
      if releases and not acquires: fail(path & ": borrow completion without any borrow acquisition")
      if machine.hasKey("boundaries"):
        if machine["boundaries"].kind != JArray: fail(path & ": boundaries must be an array")
        for fn in machine["boundaries"]:
          keys(fn, ["symbol", "argument", "entry", "exit", "outcomes"], path)
          var boundary = ProtocolBoundary(symbol: word(fn, "symbol", path), protocol: spec.id,
            argument: argumentIndex(fn, path), origin: path)
          if not fn.hasKey("entry"): fail(path & ": boundary requires entry")
          boundary.entry = boundaryState(fn["entry"], spec, boundary.argument, path)
          if fn.hasKey("outcomes"):
            if fn.hasKey("exit"): fail(path & ": boundary outcomes conflict with unconditional exit")
            if fn["outcomes"].kind != JArray or fn["outcomes"].len != 2:
              fail(path & ": boundary outcomes must cover zero and nonzero exactly once")
            var cases = initHashSet[string]()
            for item in fn["outcomes"]:
              keys(item, ["result", "exit"], path)
              let resultCase = word(item, "result", path)
              if resultCase notin ["zero", "nonzero"] or resultCase in cases:
                fail(path & ": boundary outcomes must cover zero and nonzero exactly once")
              cases.incl resultCase
              if not item.hasKey("exit"): fail(path & ": boundary outcome requires exit")
              boundary.outcomes.add BoundaryOutcome(result: resultCase,
                exit: boundaryState(item["exit"], spec, boundary.argument, path))
          else:
            if not fn.hasKey("exit"): fail(path & ": boundary requires exit or outcomes")
            boundary.exit = boundaryState(fn["exit"], spec, boundary.argument, path)
          for existing in cfg.boundaries.getOrDefault(boundary.symbol):
            if existing.protocol == boundary.protocol and existing.argument == boundary.argument:
              fail(path & ": conflicting/repeated boundary for protocol and resource argument")
          cfg.boundaries.mgetOrPut(boundary.symbol, @[]).add boundary
      cfg.protocols[spec.id] = spec
  for symbol in cfg.boundaries.keys:
    if symbol in operationOwners: fail(path & ": function boundary conflicts with external protocol operation")
  for profile, context in cfg.profileContexts:
    if context notin cfg.contexts: fail(path & ": unknown profile context '" & context & "'")
  for profile, protocols in cfg.protocolProfiles:
    for protocol in protocols:
      if protocol notin cfg.protocols: fail(path & ": unknown protocol '" & protocol & "'")
  if cfg.sources.len == 0: fail(path & ": sources must be nonempty")
  for check in cfg.checks:
    if check.profile notin cfg.profiles: fail(path & ": unknown profile '" & check.profile & "'")
  var assumptions = initHashSet[string]()
  for contract in cfg.contracts.values: assumptions.incl contract.assumption
  for register in cfg.mmioRegisters: assumptions.incl register.assumption
  for frame in cfg.stackFrames.values: assumptions.incl frame.assumption
  for bounds in cfg.timingBounds.values:
    for bound in bounds: assumptions.incl bound.assumption
  for accepted in cfg.accepted:
    if accepted notin assumptions: fail(path & ": unknown accepted assumption '" & accepted & "'")
  # Checked once everything is loaded: an API contract may set a mark a device document defines.
  for (mark, where) in markReferences:
    if mark notin cfg.marks: fail(where & ": unknown mark '" & mark & "'")
  for register in cfg.mmioRegisters:
    if register.requiresBarrier.len > 0 and register.requiresBarrier notin cfg.barrierKinds:
      fail(register.origin & ": register '" & register.id & "' requires barrier '" & register.requiresBarrier &
        "', which no function contract establishes")
  for (region, where) in regionReferences:
    if region notin cfg.regions: fail(where & ": unknown region '" & region & "'")
  for (property, where) in propertyReferences:
    var declared = false
    for region in cfg.regions.values:
      if property in region.properties: declared = true
    if not declared: fail(where & ": no declared region has property '" & property & "'")
  # An allocator's releasing functions must actually release or relocate their first argument.
  for contract in cfg.contracts.values:
    for releaser in contract.allocReleasedBy:
      var releases = releaser in ["c:@F@free", "c:@F@realloc"]
      if releaser in cfg.contracts:
        for access in cfg.contracts[releaser].accesses:
          if access.mode in ["release", "relocate"]: releases = true
      if not releases:
        fail(contract.origin & ": releasedBy '" & releaser & "' is neither free/realloc nor a contract that releases or relocates")
  result = cfg
