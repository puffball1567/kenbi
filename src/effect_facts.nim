## Full call inventory, deliberately independent of ownership-relevant call edges.
import std/[os, sets, algorithm, strutils]
import checksums/sha1
import ir, clang, cfront_core, protocol_facts

proc symbol(c: CXCursor): string =
  result = usr(c)
  # Internal linkage USRs can embed only a basename. Preserve the declaration file.
  if result.len > 0 and clang_getCursorLinkage(c) == 2:
    result = absolutePath(fileOf(clang_getCursorLocation(c))) & "#" & result

proc pointerSymbol(decl: CXCursor): string =
  ## The identity of a function pointer a contract can name. A parameter is its function's
  ## symbol and its own name (`c:@F@walk_tree@param:visit`): the USR clang gives a parameter
  ## embeds a source offset, which changes whenever the file above it is edited.
  if clang_getCursorKind(decl) != ckParmDecl: return symbol(decl)
  let owner = clang_getCursorSemanticParent(decl)
  if clang_getCursorKind(owner) notin [ckFunctionDecl, ckCXXMethod]: return symbol(decl)
  var name = spelling(decl)
  if name.len == 0:
    for i in 0 ..< int(clang_Cursor_getNumArguments(owner)):
      if clang_equalCursors(clang_Cursor_getArgument(owner, cuint(i)), decl) != 0: name = $i
  symbol(owner) & "@param:" & name

proc constantTypeQuery(c: CXCursor): bool =
  ## A `sizeof` / `_Alignof` whose value is an integer constant. Its operand is then not
  ## evaluated (C11 6.5.3.4p2: only an operand of variable length array type is), so nothing
  ## written inside it runs. A `sizeof` of a variable length array is not a constant and is
  ## still refused.
  let evaluated = clang_Cursor_Evaluate(c)
  if evaluated.isNil: return false
  defer: clang_EvalResult_dispose(evaluated)
  clang_EvalResult_getKind(evaluated) == CXEval_Int

proc calledPointer(call: CXCursor): string =
  ## The function pointer an indirect call goes through, when the callee expression names it:
  ## a struct field (`cfg->read(...)`), a variable or a parameter (`cb(...)`, `(*cb)(...)`).
  let kids = collectChildren(call)
  if kids.len == 0: return ""
  var callee = stripped(kids[0])
  for _ in 0 ..< 4:                               # `(*fp)(...)`, `(**fp)(...)`
    if clang_getCursorKind(callee) != ckUnaryOperator: break
    let inner = collectChildren(callee)
    if inner.len != 1: return ""
    callee = stripped(inner[0])
  if clang_getCursorKind(callee) notin [ckMemberRefExpr, ckDeclRefExpr]: return ""
  let decl = clang_getCursorReferenced(callee)
  if clang_getCursorKind(decl) notin [ckFieldDecl, ckVarDecl, ckParmDecl]: return ""
  pointerSymbol(decl)

proc isFunctionPointer(t: CXType): bool =
  ## a pointer to function, or a function type that decays to one (110 / 111: FunctionNoProto /
  ## FunctionProto)
  let c = clang_getCanonicalType(t)
  if c.kind in [110.cint, 111]: return true
  c.kind == tyPointer and clang_getCanonicalType(clang_getPointeeType(c)).kind in [110.cint, 111]

proc functionArgument(tu: CXTranslationUnit, arg: CXCursor): tuple[kind: char, symbol: string] =
  ## What is passed where a function pointer is expected: a function named directly (`f`,
  ## `&f`), a parameter of the calling function passed on, a null pointer constant (`n`: no
  ## function at all), or something else.
  block:
    # `0`, `(void *)0`, `NULL`, `nullptr`: look through parentheses and casts for the constant
    var n = stripped(arg)
    for _ in 0 ..< 6:
      let k = clang_getCursorKind(n)
      if k == ckCStyleCastExpr or k == ckParenExpr or k == ckUnexposedExpr:
        let inner = collectChildren(n)
        if inner.len == 0: break
        n = stripped(inner[^1])
      else: break
    let k = clang_getCursorKind(n)
    if k in [120.cint, 123]: return ('n', "")     # CXXNullPtrLiteralExpr, GNUNullExpr
    if k == ckIntegerLiteral:
      let evaluated = clang_Cursor_Evaluate(n)
      if not evaluated.isNil:
        defer: clang_EvalResult_dispose(evaluated)
        if clang_EvalResult_getKind(evaluated) == CXEval_Int and
           clang_EvalResult_getAsLongLong(evaluated) == 0: return ('n', "")
  var e = stripped(arg)
  for _ in 0 ..< 4:
    if clang_getCursorKind(e) != ckUnaryOperator: break
    let inner = collectChildren(e)
    if inner.len != 1: break
    e = stripped(inner[0])
  if clang_getCursorKind(e) == ckDeclRefExpr:
    let decl = clang_getCursorReferenced(e)
    if clang_getCursorKind(decl) == ckFunctionDecl: return ('f', symbol(decl))
    if clang_getCursorKind(decl) == ckParmDecl: return ('p', pointerSymbol(decl))
  ('o', "")

proc assignment(tu: CXTranslationUnit, c: CXCursor): bool =
  ## a plain `=` (not `==`, `+=`, ...)
  let parts = collectChildren(c)
  if clang_getCursorKind(c) != ckBinaryOperator or parts.len != 2: return false
  let all = tokens(tu, c)
  let before = tokens(tu, parts[0]).len
  before < all.len and all[before] == "="

proc initialiserFor(tu: CXTranslationUnit, list, field: CXCursor): tuple[found: bool, value: CXCursor] =
  ## The expression a brace initialiser gives one field of its struct: by designator
  ## (`.read = f`) or by position. `found` is false when the list leaves the field out (it is
  ## then zero) or is not a list for the struct the field belongs to.
  let record = clang_getTypeDeclaration(clang_getCanonicalType(clang_getCursorType(list)))
  if clang_equalCursors(record, clang_getCursorSemanticParent(field)) == 0: return
  var position = -1
  var i = 0
  for f in collectChildren(record):
    if clang_getCursorKind(f) != ckFieldDecl: continue
    if clang_equalCursors(f, field) != 0: position = i
    inc i
  var index = 0
  for item in collectChildren(list):
    let inner = collectChildren(item)
    if clang_getCursorKind(item) == ckUnexposedExpr and inner.len == 2 and
       clang_getCursorKind(inner[0]) == 47:        # a designator: MemberRef, then the value
      if clang_equalCursors(clang_getCursorReferenced(inner[0]), field) != 0: return (true, inner[1])
    else:
      if index == position: return (true, item)
      inc index

proc localFieldValues(tu: CXTranslationUnit, body: CXCursor, local: string, field: CXCursor):
    tuple[known: bool, values: seq[tuple[kind: char, symbol: string]]] =
  ## What the function-pointer `field` of the automatic local `local` can hold: everything the
  ## function stores into it — `local.field = v`, `local[i].field = v`, an element or the whole
  ## assigned a compound literal, the local's own initialiser. Nothing else can write it as
  ## long as the local is only ever used member by member; if its address is taken or it is
  ## used as a whole, or one of those stores is not a literal, the answer is not known.
  var known = true
  var values: seq[tuple[kind: char, symbol: string]]
  proc rooted(e: CXCursor): bool =
    ## does this lvalue name storage inside `local` itself?
    var u = stripped(e)
    for _ in 0 ..< 16:
      let k = clang_getCursorKind(u)
      let kids = collectChildren(u)
      if k == ckDeclRefExpr: return referencedUsr(u) == local
      if k == ckMemberRefExpr:
        let ts = tokens(tu, u)
        if kids.len != 1 or (ts.len >= 2 and ts[^2] == "->"): return false
        u = stripped(kids[0])
      elif k == ckArraySubscriptExpr and kids.len == 2: u = stripped(kids[0])
      else: return false
  proc fromList(list: CXCursor) =
    let t = clang_getCanonicalType(clang_getCursorType(list))
    if t.kind == tyRecord:
      let init = initialiserFor(tu, list, field)
      if init.found:
        let a = functionArgument(tu, init.value)
        values.add (a.kind, a.symbol)
      elif clang_equalCursors(clang_getTypeDeclaration(t), clang_getCursorSemanticParent(field)) == 0:
        known = false                              # the field is nested deeper than this list
    else:
      for item in collectChildren(list):           # an array of them
        if clang_getCursorKind(stripped(item)) == 119: fromList(stripped(item))
        else: known = false
  proc visit(n: CXCursor) =
    let k = clang_getCursorKind(n)
    let kids = collectChildren(n)
    if k == 136: return                            # sizeof: nothing in it runs
    if assignment(tu, n) and rooted(kids[0]):
      let lhs = stripped(kids[0])
      if clang_getCursorKind(lhs) == ckMemberRefExpr and
         clang_equalCursors(clang_getCursorReferenced(lhs), field) != 0:
        let a = functionArgument(tu, kids[1])
        values.add (a.kind, a.symbol)
      elif clang_getCanonicalType(clang_getCursorType(lhs)).kind == tyRecord:
        var rhs = stripped(kids[1])
        if clang_getCursorKind(rhs) == 118:        # a compound literal: its list is the child
          for part in collectChildren(rhs):
            if clang_getCursorKind(part) == 119: rhs = part
        if clang_getCursorKind(rhs) == 119: fromList(rhs)
        else: known = false
      visit(kids[1])
      var at = lhs                                 # the index expressions on the way down may
      for _ in 0 ..< 16:                           # mention anything; the base is the local
        let inner = collectChildren(at)
        if clang_getCursorKind(at) == ckArraySubscriptExpr and inner.len == 2: visit(inner[1])
        if clang_getCursorKind(at) notin [ckMemberRefExpr, ckArraySubscriptExpr] or inner.len == 0: break
        at = stripped(inner[0])
      return
    if k == ckVarDecl and usr(n) == local:
      for part in kids:
        if clang_getCursorKind(part) == 119: fromList(part)
        elif clang_isExpression(clang_getCursorKind(part)) != 0 and
             clang_getCanonicalType(clang_getCursorType(part)).kind in [tyRecord, tyConstantArray,
                                                                        tyIncompleteArray, tyVariableArray]:
          known = false                            # initialised from another object (an integer
                                                   # expression here is the size of an array)
      return
    if k in [ckMemberRefExpr, ckArraySubscriptExpr] and rooted(n):
      # read member by member: fine. (The indices on the way down are ordinary expressions.)
      var at = n
      for _ in 0 ..< 16:
        let inner = collectChildren(at)
        if clang_getCursorKind(at) == ckArraySubscriptExpr and inner.len == 2: visit(inner[1])
        if clang_getCursorKind(at) notin [ckMemberRefExpr, ckArraySubscriptExpr] or inner.len == 0: break
        at = stripped(inner[0])
      return
    if k == ckDeclRefExpr and referencedUsr(n) == local:
      known = false                                # used as a whole, or its address taken
      return
    for part in kids: visit(part)
  visit(body)
  (known, values)

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
  var callees: HashSet[int]      # where a function is named as the callee of a direct call
  var current: CXCursor          # the function definition being walked
  var stores: seq[tuple[cell: string, kind: char, symbol, file: string, line: int]]
  proc recordStores(c: CXCursor) =
    ## a value stored into a function-pointer field or variable: by assignment, by a
    ## declaration's initialiser, or by one entry of a brace initialiser
    let kind = clang_getCursorKind(c)
    let parts = collectChildren(c)
    proc add(decl, value: CXCursor) =
      if clang_getCursorKind(decl) notin [ckFieldDecl, ckVarDecl] or
         not isFunctionPointer(clang_getCursorType(decl)): return
      let a = functionArgument(tu, value)
      stores.add (pointerSymbol(decl), a.kind, a.symbol,
                  absolutePath(fileOf(clang_getCursorLocation(value))), startLine(value))
    if assignment(tu, c):
      let lhs = stripped(parts[0])
      if clang_getCursorKind(lhs) in [ckMemberRefExpr, ckDeclRefExpr]:
        add(clang_getCursorReferenced(lhs), parts[1])
    elif kind == ckVarDecl and parts.len > 0 and
         clang_isExpression(clang_getCursorKind(parts[^1])) != 0 and
         clang_getCursorKind(parts[^1]) != 119:
      add(c, parts[^1])
    elif kind == 119:                              # InitListExpr
      let record = clang_getTypeDeclaration(clang_getCanonicalType(clang_getCursorType(c)))
      if clang_getCanonicalType(clang_getCursorType(c)).kind == tyRecord:
        for f in collectChildren(record):
          if clang_getCursorKind(f) == ckFieldDecl and isFunctionPointer(clang_getCursorType(f)):
            let init = initialiserFor(tu, c, f)
            if init.found: add(f, init.value)
  proc walk(c: CXCursor, fn: var EffectFunction) =
    let kind = clang_getCursorKind(c)
    recordStores(c)
    if kind == 136 and (fixedTypeQuery(tu, c) or constantTypeQuery(c)): return
    if kind == ckCallExpr:
      let target = clang_getCursorReferenced(c)
      let direct = clang_getCursorKind(target) == ckFunctionDecl
      var call = EffectCall(symbol: (if direct: symbol(target) else: ""),
        name: spelling(c), file: absolutePath(fileOf(clang_getCursorLocation(c))),
        line: startLine(c), indirect: not direct,
        pointer: (if direct: "" else: calledPointer(c)))
      let parts = collectChildren(c)
      if direct and parts.len > 0: callees.incl startOffset(stripped(parts[0]))
      for ai in 0 ..< int(clang_Cursor_getNumArguments(c)):
        let arg = clang_Cursor_getArgument(c, cuint(ai))
        if isFunctionPointer(clang_getCursorType(arg)):
          let a = functionArgument(tu, arg)
          call.fnArgs.add (ai, a.kind, a.symbol)
      fn.calls.add call
    # a function-pointer parameter given a new value in the body, or exposed by `&param`
    if kind in [ckBinaryOperator, ckUnaryOperator]:
      let parts = collectChildren(c)
      if parts.len >= 1:
        let lhs = stripped(parts[0])
        let decl = clang_getCursorReferenced(lhs)
        if clang_getCursorKind(lhs) == ckDeclRefExpr and clang_getCursorKind(decl) == ckParmDecl and
           isFunctionPointer(clang_getCursorType(decl)):
          let all = tokens(tu, c)
          if kind == ckBinaryOperator and parts.len == 2:
            let before = tokens(tu, parts[0]).len
            if before < all.len and all[before] == "=":
              # read back out of a local of this function (`cb = saved[i].cb`): whatever the
              # function itself put there, when nothing else can have written it
              var resolved = false
              var rhs = stripped(parts[1])
              let field = clang_getCursorReferenced(rhs)
              if clang_getCursorKind(rhs) == ckMemberRefExpr and
                 clang_getCursorKind(field) == ckFieldDecl:
                var root = rhs
                for _ in 0 ..< 16:
                  let inner = collectChildren(root)
                  if clang_getCursorKind(root) notin [ckMemberRefExpr, ckArraySubscriptExpr] or
                     inner.len == 0: break
                  root = stripped(inner[0])
                let holder = clang_getCursorReferenced(root)
                if clang_getCursorKind(root) == ckDeclRefExpr and
                   clang_getCursorKind(holder) == ckVarDecl and hasAutomaticStorage(holder) and
                   clang_equalCursors(clang_getCursorSemanticParent(holder), current) != 0:
                  for body in collectChildren(current):
                    if clang_getCursorKind(body) != ckCompoundStmt: continue
                    let held = localFieldValues(tu, body, usr(holder), field)
                    if held.known:
                      resolved = true
                      for v in held.values: fn.pointerStores.add (pointerSymbol(decl), v.kind, v.symbol)
              if not resolved:
                let a = functionArgument(tu, parts[1])
                fn.pointerStores.add (pointerSymbol(decl), a.kind, a.symbol)
          elif kind == ckUnaryOperator and all.len > 0 and all[0] == "&":
            fn.pointerStores.add (pointerSymbol(decl), 'o', "")
    if kind == ckDeclRefExpr and clang_getCursorKind(clang_getCursorReferenced(c)) == ckFunctionDecl and
       startOffset(c) notin callees:
      let taken = symbol(clang_getCursorReferenced(c))
      if taken notin fn.addressTaken: fn.addressTaken.add taken
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
    fn.external = clang_getCursorLinkage(decl) == 3
    current = decl
    for i in 0 ..< int(clang_Cursor_getNumArguments(decl)):
      let parm = clang_Cursor_getArgument(decl, cuint(i))
      fn.params.add (pointerSymbol(parm), isFunctionPointer(clang_getCursorType(parm)))
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
  # ... and the initialisers of the variables declared at file scope
  proc fileScope(c: CXCursor) =
    recordStores(c)
    for child in collectChildren(c): fileScope(child)
  for top in collectChildren(clang_getTranslationUnitCursor(tu)):
    if clang_getCursorKind(top) == ckVarDecl: fileScope(top)
  for store in stores:
    if store notin result.cellStores: result.cellStores.add store
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
      let path = fileName(f)
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
    let file = clang_getFile(tu, path.cstring)
    # libclang 17 and later crash on a nil file here; 14 returned nil
    let content = (if file.isNil: nil else: clang_getFileContents(tu, file, addr size))
    if content.isNil:
      result.unsupported.add "cannot snapshot parsed input: " & path
    else:
      var snapshot = newString(int(size))
      if size > 0: copyMem(addr snapshot[0], content, int(size))
      result.inputs.add (path, $secureHash(snapshot))
