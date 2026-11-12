## Full call inventory, deliberately independent of ownership-relevant call edges.
import std/[os, sets, algorithm, strutils]
import checksums/sha1
import ir, clang, cfront_core, protocol_facts

proc symbol(c: CXCursor): string =
  result = usr(c)
  # Internal linkage USRs can embed only a basename. Preserve the declaration file.
  if result.len > 0 and clang_getCursorLinkage(c) == 2:
    result = absolutePath(fileOf(clang_getCursorLocation(c))) & "#" & result

proc collectEffectFacts*(tu: CXTranslationUnit, cpp: bool,
                         args: seq[string], transformed: bool,
                         markers: seq[tuple[file, profile: string, line, after: int]],
                         original: tuple[path, text: string]): EffectUnit =
  result.arguments = args
  let target = clang_getTranslationUnitTargetInfo(tu)
  if not target.isNil:
    result.targetTriple = $clang_TargetInfo_getTriple(target)
    result.pointerWidth = int(clang_TargetInfo_getPointerWidth(target))
    clang_TargetInfo_dispose(target)
  if cpp:
    result.unsupported.add "C++ implicit construction, destruction and dispatch effects are not yet modeled"
  if transformed:
    result.unsupported.add "parallel pragmas introduce runtime effects not represented in this call inventory"
  var declarations: seq[CXCursor]
  proc visitor(c, parent: CXCursor, data: CXClientData): CXChildVisitResult {.cdecl.} =
    if clang_getCursorKind(c) in [ckFunctionDecl, ckCXXMethod, ckConstructor,
        ckDestructor, ckConversionFunction, ckFunctionTemplate]:
      for child in collectChildren(c):
        if clang_getCursorKind(child) == ckCompoundStmt:
          cast[ptr seq[CXCursor]](data)[].add c
          break
      return cvrContinue
    cvrRecurse
  discard clang_visitChildren(clang_getTranslationUnitCursor(tu), visitor, addr declarations)
  proc walk(c: CXCursor, fn: var EffectFunction) =
    let kind = clang_getCursorKind(c)
    if kind == 136 and fixedTypeQuery(tu, c): return
    if kind == ckCallExpr:
      let target = clang_getCursorReferenced(c)
      let direct = clang_getCursorKind(target) == ckFunctionDecl
      fn.calls.add EffectCall(symbol: (if direct: symbol(target) else: ""),
        name: spelling(c), file: absolutePath(fileOf(clang_getCursorLocation(c))),
        line: startLine(c), indirect: not direct)
    # Explicitly refuse constructs with hidden effects instead of treating them as pure.
    # 215 = GCCAsmStmt, 229 = MSAsmStmt, 136 = UnaryExpr (sizeof / alignof).
    # sizeof may evaluate a VLA size; absence of ordinary children is not proof of purity.
    if kind in [215.cint, 229, 136, 200, ckLambdaExpr, ckCXXNewExpr]:
      fn.unsupported.add (startLine(c), "unmodeled expression/statement kind " & $kind)
      return  # children may be unevaluated; do not accuse them of executing effects
    if kind == ckVarDecl:
      # Attributes such as cleanup can call code at scope exit outside explicit CallExprs.
      for child in collectChildren(c):
        if clang_getCursorKind(child) >= 400 and explicitAlignment(tu, c, child) < 0:
          fn.unsupported.add (startLine(c), "local declaration attribute may have implicit effects")
    for child in collectChildren(c): walk(child, fn)

  var candidates: seq[tuple[cursor: CXCursor, owner: EffectFunction, whole: bool]]
  for decl in declarations:
    var fn = EffectFunction(symbol: symbol(decl), name: spelling(decl),
      file: absolutePath(fileOf(clang_getCursorLocation(decl))),
      first: startLine(decl), last: endLine(decl), nameLine: lineOf(clang_getCursorLocation(decl)))
    for child in collectChildren(decl):
      # Parameter VLA bounds can execute on entry as well as expressions inside the body.
      if clang_getCursorKind(child) in [ckCompoundStmt, ckParmDecl]: walk(child, fn)
    fn.protocol = collectProtocolFacts(tu, decl)
    result.functions.add fn
    candidates.add (decl, fn, true)
    proc blocks(c: CXCursor) =
      if clang_getCursorKind(c) == ckCompoundStmt: candidates.add (c, fn, false)
      for child in collectChildren(c): blocks(child)
    for child in collectChildren(decl): blocks(child)
  proc trivia(text: string): bool =
    var i = 0
    while i < text.len:
      if text[i] in {' ', '\t', '\n', '\r'}: inc i
      elif i+1 < text.len and text[i .. i+1] == "//":
        let stop = text.find('\n', i+2)
        i = if stop < 0: text.len else: stop+1
      elif i+1 < text.len and text[i .. i+1] == "/*":
        let stop = text.find("*/", i+2)
        if stop < 0: return false
        i = stop+2
      else: return false
    true
  for marker in markers:
    let path = absolutePath(marker.file)
    let source = readFile(path)
    var best = -1
    var first = high(int)
    for i, candidate in candidates:
      let offset = startOffset(candidate.cursor)
      if candidate.owner.file == path and offset >= marker.after and offset < first:
        best = i; first = offset
    if best < 0 or first > source.len or not trivia(source[marker.after ..< first]):
      raise newException(CFrontError, path & ":" & $marker.line &
        ": @verify must immediately precede a function definition or compound block")
    let candidate = candidates[best]
    var fn = candidate.owner
    if not candidate.whole:
      fn.protocolOwner = candidate.owner.symbol
      fn.symbol.add "#block@" & $first
      fn.name.add "::<block@" & $startLine(candidate.cursor) & ">"
      fn.first = startLine(candidate.cursor); fn.last = endLine(candidate.cursor)
      fn.calls = @[]
      # Keep enclosing-function uncertainty: e.g. returning inside this block
      # can run a cleanup attribute on a local declared BEFORE the block.
      # Ordinary outside calls are excluded, but implicit lifetime effects must
      # not disappear merely because their declaration is outside the region.
      walk(candidate.cursor, fn)
      var unique: seq[tuple[line: int, reason: string]]
      for issue in fn.unsupported:
        if issue notin unique: unique.add issue
      fn.unsupported = unique
      result.functions.add fn
    result.requirements.add (fn.symbol, marker.profile)
  var paths = initHashSet[string]()
  proc inclusion(f: CXFile, stack: ptr CXSourceLocation, n: cuint,
                 data: CXClientData) {.cdecl.} =
    if not f.isNil:
      let path = $clang_getFileName(f)
      if path.len > 0: cast[ptr HashSet[string]](data)[].incl absolutePath(path)
  clang_getInclusions(tu, inclusion, addr paths)
  var ordered: seq[string]
  for path in paths: ordered.add path
  ordered.sort()
  for path in ordered:
    if transformed and path == absolutePath(original.path):
      # The frontend blanks parallel pragmas in an unsaved buffer. Fingerprint
      # the ORIGINAL input, not that internal view, while retaining the explicit
      # unsupported-model reason above. Otherwise unchanged source looks stale.
      result.inputs.add (path, $secureHash(original.text))
      continue
    var size: csize_t
    let content = clang_getFileContents(tu, clang_getFile(tu, path.cstring), addr size)
    if content.isNil:
      result.unsupported.add "cannot snapshot parsed input: " & path
    else:
      var snapshot = newString(int(size))
      if size > 0: copyMem(addr snapshot[0], content, int(size))
      result.inputs.add (path, $secureHash(snapshot))
