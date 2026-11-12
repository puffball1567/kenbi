## libclang front-end: lower real C / C++ into the same `Program` IR the
## temporal engine consumes (ir.nim). The analysis engine stays untouched —
## only the source of `Program` changes (mini parser vs. this).
##
## Scope (Phase 1): straight-line code + if/else within a function body, the
## resource registry from `@mem` comment annotations, alias/interior tracking,
## and escape via `@move`-annotated calls. The goal is to run the t01–t17 cases
## on real C and reproduce the engine's verdicts.

import std/[tables, strutils, sets, os]
import ir, clang, cfront_core, cfront_annotations
import annotations/registry   # generic contract lookups for the resolver
import effect_facts

# --- token helpers ----------------------------------------------------------

proc firstTokenSpelling(ctx: Ctx, c: CXCursor): string =
  var toks: ptr CXToken
  var n: cuint
  clang_tokenize(ctx.tu, clang_getCursorExtent(c), addr toks, addr n)
  if n > 0:
    let arr = cast[ptr UncheckedArray[CXToken]](toks)
    result = $clang_getTokenSpelling(ctx.tu, arr[0])
  clang_disposeTokens(ctx.tu, toks, n)

const cBinaryOps = [
  "=", "==", "!=", "<", ">", "<=", ">=", "+", "-", "*", "/", "%", "&", "|", "^", "<<", ">>",
  "&&", "||", ",", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "<<=", ">>="]

proc binOperator(ctx: Ctx, c: CXCursor): string =
  ## The operator spelling of a BinaryOperator, recovered from its tokens (libclang-14 exposes
  ## no direct accessor): the punctuation lying between the two operands' source offsets.
  ##
  ## Inside a MACRO expansion there are no usable offsets — libclang collapses every cursor in
  ## an expansion onto the invocation, so both operands report the same span and the extent
  ## tokenises to a run that starts at the operand in the macro DEFINITION and reaches the
  ## invocation. The offset filter therefore found no operator at all for anything written in a
  ## macro. Three things went with it, and C keeps its error-path cleanup in exactly such a
  ## macro: the ASSIGNMENT (a release written the house way, `pivots = Relinquish(pivots);`, is
  ## an assignment — unlowered, so the release was invisible and the memory it freed was
  ## reported leaked: 4 such claims in ImageMagick's matrix.c); the NULL GUARD around it; and
  ## `p = realloc(p, n)`, which never drew the OOM-overwrite finding it draws everywhere else.
  ## In the degenerate case the token run still BEGINS with this expression, so the operator is
  ## the first punctuation at bracket depth zero — the top-level operator of any well-formed
  ## C expression, compound conditions included.
  ##
  ## For `p = new struct S` libclang-14 reports no valid end for the new-expression, and so no
  ## valid extent for the assignment, which then tokenises to nothing. In that case only the
  ## tokens from the start of the left operand to the start of the right one are read — the
  ## operator lies between them.
  let kids = collectChildren(c)
  if kids.len < 2: return ""
  let lhsEnd = endOffset(kids[0])
  var rhsLoc = clang_getRangeStart(clang_getCursorExtent(kids[1]))
  if lineOf(rhsLoc) == 0: rhsLoc = clang_getCursorLocation(kids[1])   # the new-expression itself
  let rhsStart = offsetOf(rhsLoc)
  var toks: ptr CXToken
  var n: cuint
  let ext = clang_getCursorExtent(c)
  if lineOf(clang_getRangeStart(ext)) == 0 and rhsStart > lhsEnd:
    clang_tokenize(ctx.tu, clang_getRange(clang_getRangeStart(clang_getCursorExtent(kids[0])),
                                          rhsLoc),
                   addr toks, addr n)
  else:
    clang_tokenize(ctx.tu, ext, addr toks, addr n)
  let arr = cast[ptr UncheckedArray[CXToken]](toks)
  if rhsStart > lhsEnd:
    for i in 0 ..< int(n):
      if clang_getTokenKind(arr[i]) == tkPunctuation:
        let s = offsetOf(clang_getTokenLocation(ctx.tu, arr[i]))
        if s >= lhsEnd and s < rhsStart:
          result = $clang_getTokenSpelling(ctx.tu, arr[i])
          break
  else:
    # The token run still BEGINS with this expression, so the operator is the first punctuation
    # at bracket depth ZERO that is neither a bracket nor a leading unary sign. That is exactly
    # the top-level operator of `LHS op RHS` for any well-formed C expression, so the compound
    # forms a cleanup macro is built from are recovered too — `(a == NULL) || (b == NULL)`
    # returns `||`, not the inner `==`.
    const prefixes = ["*", "&", "-", "+", "!", "~", "++", "--"]
    var depth = 0
    var i = 0
    while i < int(n) and clang_getTokenKind(arr[i]) == tkPunctuation and
          $clang_getTokenSpelling(ctx.tu, arr[i]) in prefixes: inc i
    while i < int(n):
      if clang_getTokenKind(arr[i]) == tkPunctuation:
        let t = $clang_getTokenSpelling(ctx.tu, arr[i])
        if t in ["(", "[", "{"]: inc depth
        elif t in [")", "]", "}"]: dec depth
        elif depth == 0:
          # Only a real C binary operator counts. A macro that takes ARGUMENTS maps its
          # expansion's cursors onto the INVOCATION including the argument list, so the run
          # begins at the macro name and the first depth-zero punctuation is the `;` or `,`
          # after it — a token that is not an operator at all. Rejecting those keeps such
          # statements exactly as unrecognised as they were, rather than lowering them as
          # something they are not.
          if t in cBinaryOps: result = t
          break
      inc i
  clang_disposeTokens(ctx.tu, toks, n)

proc intLiteralValue(ctx: Ctx, c: CXCursor): int =
  let s = firstTokenSpelling(ctx, c)
  try: result = parseInt(s.strip())
  except ValueError: result = 0

proc advancesTrackedPointer(ctx: Ctx, c: CXCursor): tuple[name, key: string] =
  ## If `c` advances a TRACKED pointer in place — `p++` / `++p` / `p--` / `--p`
  ## (a UnaryOperator) or `p += n` / `p -= n` (a CompoundAssign) — return that
  ## pointer's (display, USR). Advancing a heap pointer makes it an INTERIOR
  ## pointer: it no longer addresses the allocation's start, so a later `free(p)`
  ## is FREE_INTERIOR (CWE-761, free not at start of buffer). Only tracked owned
  ## pointers qualify — an `int` loop counter `i++` is irrelevant. ("","") if not
  ## such an advance.
  let k = clang_getCursorKind(c)
  if k == ckUnaryOperator:
    # token-scan for ++ / -- (covers both prefix and postfix forms)
    var toks: ptr CXToken
    var n: cuint
    clang_tokenize(ctx.tu, clang_getCursorExtent(c), addr toks, addr n)
    let arr = cast[ptr UncheckedArray[CXToken]](toks)
    var isPlusMinus = false
    for i in 0 ..< int(n):
      let s = $clang_getTokenSpelling(ctx.tu, arr[i])
      if s == "++" or s == "--": isPlusMinus = true; break
    clang_disposeTokens(ctx.tu, toks, n)
    if isPlusMinus:
      for kid in collectChildren(c):
        let o = unwrap(kid)
        if clang_getCursorKind(o) == ckDeclRefExpr:
          let key = referencedUsr(o)
          if ctx.tracked.getOrDefault(key, false): return (spelling(o), key)
  elif k == ckCompoundAssign:
    let op = ctx.binOperator(c)
    if op == "+=" or op == "-=":
      let kids = collectChildren(c)
      if kids.len >= 1:
        let l = unwrap(kids[0])
        if clang_getCursorKind(l) == ckDeclRefExpr:
          let key = referencedUsr(l)
          if ctx.tracked.getOrDefault(key, false): return (spelling(l), key)
  ("", "")

proc advanceStep(ctx: Ctx, c: CXCursor): int =
  ## The CONSTANT amount a self-advance moves a pointer by — `p += 255` -> +255, `p -= 255` ->
  ## -255, `p++` -> +1, `p--` -> -1 — or `offsetUnknown` when the step is not a compile-time
  ## constant. Only the STEP is computed here: the running total is per-PATH and belongs to the
  ## engine, which merges it at every join. A total kept here would add up
  ## `if (c) p += 8; else p -= 8;` in source order and call the result 0 on both branches.
  let k = clang_getCursorKind(c)
  if k == ckUnaryOperator:
    var toks: ptr CXToken
    var n: cuint
    clang_tokenize(ctx.tu, clang_getCursorExtent(c), addr toks, addr n)
    defer: clang_disposeTokens(ctx.tu, toks, n)
    let arr = cast[ptr UncheckedArray[CXToken]](toks)
    for i in 0 ..< int(n):
      let t = $clang_getTokenSpelling(ctx.tu, arr[i])
      if t == "++": return 1
      if t == "--": return -1
    return offsetUnknown
  if k == ckCompoundAssign:
    let op = ctx.binOperator(c)
    let kids = collectChildren(c)
    if kids.len >= 2 and (op == "+=" or op == "-="):
      let v = constIntValue(unwrap(kids[1]))
      if v.known: return (if op == "-=": -int(v.value) else: int(v.value))
  offsetUnknown

proc ownerTail(varName: string): string =
  ## The last component of an owner path: `b->data` / `s.data` / `X::data` -> `data`. A `@mem`
  ## declares the FIELD it owns (`owner: data`) above `b->data = malloc(…)`, so the declaration
  ## and the allocation site spell the same object differently.
  var t = varName
  for sep in ["->", "::", "."]:
    let at = t.rfind(sep)
    if at >= 0: t = t[at + sep.len .. ^1]
  t

proc resourceFor(ctx: Ctx, varName: string, line: int, isNew = -1): string =
  ## Resolve which declared resource an allocation belongs to: the nearest @mem ABOVE the line
  ## whose `owner` names this variable — by its full spelling or by its last path component, so
  ## `owner: data` covers `b->data = malloc(…)`. Nearest-above and not merely "any @mem naming
  ## it", because the same owner name recurs in every function of a file (`data` in every Juliet
  ## function) and picking the LAST one brought its deallocator with it: a false
  ## WRONG_DEALLOCATOR. Else any @mem naming it.
  ##
  ## Else the nearest @mem above whatever it owns — one declaration per resource KIND, several
  ## locals of that kind (`char *n = new char[8];` beside the member the class declares). That
  ## last step is a guess about identity, so it is held to the one thing the site does state:
  ## the allocation FLAVOUR. A `new` cannot belong to a resource released by `free`, nor a
  ## `malloc` to one released by `delete`. Without that check `Base *obj = new Base;` next to an
  ## unrelated `@mem … { free: free, owner: data }` took on THAT resource's identity and
  ## `delete obj` read as WRONG_DEALLOCATOR against a resource it has nothing to do with.
  ## An allocation nothing names at all resolves to "" — UNKNOWN_RESOURCE, declare it.
  var best = ""
  var bestLine = -1
  let tail = ownerTail(varName)
  for (l, name) in ctx.memByLine:
    if l <= line and l > bestLine:
      let owner = ctx.prog.resources.getOrDefault(name).ownerId
      if owner == varName or owner == tail:
        best = name; bestLine = l
  if best.len > 0: return best
  if varName in ctx.ownerRes: return ctx.ownerRes[varName]
  bestLine = -1
  for (l, name) in ctx.memByLine:
    if l <= line and l > bestLine:
      if isNew >= 0:
        let f = ctx.prog.resources.getOrDefault(name).freeId
        let byDelete = f.startsWith("delete")
        if byDelete != (isNew == 1): continue
      best = name; bestLine = l
  best

# --- statement lowering -----------------------------------------------------

proc lowerBody(ctx: var Ctx, body: seq[CXCursor]): seq[Stmt]

proc emit(ik: InstrKind, line: int, a = "", b = "", off = 0,
          aKey = "", bKey = "", off2 = 0, cKey = "", off3 = 0): Stmt =
  Stmt(line: line, kind: stInstr, ik: ik, a: a, b: b, aKey: aKey, bKey: bKey,
       off: off, off2: off2, cKey: cKey, off3: off3)

proc pointsIntoLocal(ctx: Ctx, v: CXCursor): tuple[yes: bool, disp: string] =
  ## Does expression `v` evaluate to a pointer into a function-local (stack)
  ## object? Three decidable shapes, all flow-insensitive:
  ##   `&local`            — address-of an automatic local
  ##   `localArray`        — a local array name decays to a stack pointer
  ##   `p` (p is localAddr)— a copy of a pointer already known to point local
  ## A `static` / `extern` local is excluded (its storage outlives the call).
  let u = unwrap(v)
  let k = clang_getCursorKind(u)
  if k == ckUnaryOperator and ctx.firstTokenSpelling(u) == "&":
    let kids = collectChildren(u)
    if kids.len >= 1:
      let o = unwrap(kids[0])
      if clang_getCursorKind(o) == ckDeclRefExpr and referencedUsr(o) in ctx.localVars:
        return (true, spelling(o))
      # `&local.field` / `&localArray[i]` — the address of a PART of a stack object is as
      # dangling as the address of the whole one. Only a VALUE base counts: `&p->field` where
      # `p` is a local POINTER is the address of a member of whatever `p` points at, which is
      # not this frame's storage.
      if clang_getCursorKind(o) in [ckMemberRefExpr, ckArraySubscriptExpr]:
        let mk = collectChildren(o)
        if mk.len >= 1:
          let base = unwrap(mk[0])
          if clang_getCursorKind(base) == ckDeclRefExpr and
             referencedUsr(base) in ctx.localVars and
             not ($clang_getTypeSpelling(clang_getCursorType(base))).strip.endsWith("*"):
            return (true, spelling(base))
  elif k == ckDeclRefExpr:
    let key = referencedUsr(u)
    if key in ctx.localArrayVars or key in ctx.localAddrVars:
      return (true, spelling(u))
  (false, "")

proc fieldPath(c: CXCursor): tuple[key, disp: string] =
  ## A one-level field path `base->field` / `base.field` where base is a plain
  ## variable, as a tracking key (base USR + "::" + field) and a display name.
  ## Empty for nested paths or non-variable bases (kept bounded, no aliasing).
  let kind = clang_getCursorKind(c)
  if kind == ckArraySubscriptExpr:
    # `arr[2]` with a CONSTANT index on a plain variable is a field path too — element `[2]` of
    # the array (Juliet 66: `dataArray[2] = data; sink(dataArray)`). A variable index is not.
    let kids = collectChildren(c)
    if kids.len >= 2:
      let base = unwrap(kids[0])
      let idx = constIntValue(unwrap(kids[1]))
      if clang_getCursorKind(base) == ckDeclRefExpr and idx.known:
        let el = "[" & $idx.value & "]"
        return (referencedUsr(base) & "::" & el, spelling(base) & el)
    return ("", "")
  if kind != ckMemberRefExpr: return ("", "")
  let kids = collectChildren(c)
  if kids.len >= 1:
    let base = unwrap(kids[0])
    if clang_getCursorKind(base) == ckDeclRefExpr:
      let field = spelling(c)
      return (referencedUsr(base) & "::" & field, spelling(base) & "->" & field)
  # a member of the enclosing class inside its own member function — `this->f`, or the
  # implicit-this `f` (no variable base): keyed `this::f`, the identity ownerRef and the
  # constructor / destructor bookkeeping use (a raw member allocated in a ctor: ctorAllocs)
  if kids.len == 0 or clang_getCursorKind(unwrap(kids[0])) == ckCXXThisExpr:
    let field = spelling(c)
    return ("this::" & field, "this->" & field)
  ("", "")

proc pointeeSlot(ctx: Ctx, c: CXCursor): tuple[key, disp: string] =
  ## `*p` where `p` is a plain variable: the slot its POINTEE occupies, keyed like any other
  ## field path (`<p usr>::*`). This is what an `@frees(*p)` / `@borrows(*p)` contract binds
  ## inside the callee — the `T**` out-parameter sink, where the obligation that arrives is on
  ## the pointed-to object and not on the pointer that carries it.
  if clang_getCursorKind(c) != ckUnaryOperator or ctx.firstTokenSpelling(c) != "*": return ("", "")
  let kids = collectChildren(c)
  if kids.len != 1: return ("", "")
  let base = unwrap(kids[0])
  if clang_getCursorKind(base) != ckDeclRefExpr: return ("", "")
  let bk = referencedUsr(base)
  # A pointer COPIED from the contracted one (`char **p = (char **)v`) derefs to the same
  # object, so it resolves to the slot the contract was seeded on rather than a fresh one.
  if not ctx.tracked.getOrDefault(bk & "::*", false) and bk in ctx.pointeeAlias:
    return (ctx.pointeeAlias[bk], "*" & spelling(base))
  (bk & "::*", "*" & spelling(base))

proc fieldBaseInfo(c: CXCursor): tuple[key: string, isLocal: bool] =
  ## The base variable of a one-level field path `base->field` / `base.field`: its USR key,
  ## and whether it is a function-LOCAL declaration (`ckVarDecl`, i.e. NOT a parameter — a
  ## parameter names the caller's struct, whose field is the caller's obligation). Empty key
  ## for nested paths or a non-variable base. Lets the leak scan resolve a field origin back
  ## to its container to decide whether the container carries the obligation away (escapes /
  ## is the caller's) or leaves the field to leak at scope exit (#2b).
  let kind = clang_getCursorKind(c)
  if kind != ckMemberRefExpr and not (kind == ckArraySubscriptExpr and fieldPath(c).key.len > 0):
    return ("", false)
  let kids = collectChildren(c)
  if kids.len >= 1:
    let base = unwrap(kids[0])
    if clang_getCursorKind(base) == ckDeclRefExpr:
      let isLocal = clang_getCursorKind(clang_getCursorReferenced(base)) == ckVarDecl
      return (referencedUsr(base), isLocal)
  ("", false)

proc deepMemberKey(c: CXCursor): tuple[key, disp: string] =
  ## TYPE-CONFUSION: a possibly-NESTED member access `n->u.i` keyed `<n-USR>::u.i` (and a
  ## one-level `n->tag` as `<n-USR>::tag`). Walks member refs down to a plain-variable base;
  ## "" for a non-variable base. Matches resolveFieldPathExpr so a `@variant` operand and the
  ## access produce the same key.
  if clang_getCursorKind(c) != ckMemberRefExpr: return ("", "")
  var members: seq[string]
  var cur = unwrap(c)
  for _ in 0 ..< 8:
    if clang_getCursorKind(cur) != ckMemberRefExpr: break
    members.add spelling(cur)
    let kids = collectChildren(cur)
    if kids.len == 0: return ("", "")
    cur = unwrap(kids[0])
  if clang_getCursorKind(cur) != ckDeclRefExpr: return ("", "")
  var path = ""
  for j in countdown(members.high, 0):
    if path.len > 0: path.add "."
    path.add members[j]
  (referencedUsr(cur) & "::" & path, spelling(cur) & "->" & path)

proc allocSizeArgIndex(callee: string): int =
  ## SPATIAL: the child index (kids[0] is the callee ref) of the argument that gives
  ## the allocation's element/byte count, for the builtin allocators. -1 = none.
  case callee
  of "malloc", "calloc": 1        # malloc(size) / calloc(count, size) — count is arg0
  of "realloc", "aligned_alloc": 2  # realloc(p, size) / aligned_alloc(align, size)
  else: -1

proc allocCountSym(ctx: Ctx, sizeExpr: CXCursor): tuple[symKey, symDisp: string] =
  ## SPATIAL: extract the COUNT identifier from an allocation-size expression so a later
  ## `idx < n` bound naming the same identifier can be matched to the buffer. Handles a
  ## bare `n` and `n * sizeof(T)` / `sizeof(T) * n` (the count operand). Identity only —
  ## no arithmetic — so an unrecognised size yields no symbol (the buffer stays "unknown
  ## size" = RED, never a false GREEN).
  let e = unwrap(sizeExpr)
  if clang_getCursorKind(e) == ckDeclRefExpr and isIntegerType(e):
    return (referencedUsr(e), spelling(e))
  if clang_getCursorKind(e) == ckBinaryOperator and ctx.binOperator(e) == "*":
    let kids = collectChildren(e)
    if kids.len == 2:
      let a = unwrap(kids[0])
      let b = unwrap(kids[1])
      let aCount = clang_getCursorKind(a) == ckDeclRefExpr and isIntegerType(a) and
                   not constIntValue(a).known
      let bCount = clang_getCursorKind(b) == ckDeclRefExpr and isIntegerType(b) and
                   not constIntValue(b).known
      if aCount and not bCount: return (referencedUsr(a), spelling(a))
      if bCount and not aCount: return (referencedUsr(b), spelling(b))
  ("", "")

proc scalarTerm(ctx: Ctx, c: CXCursor): tuple[ok: bool, key, disp: string] =
  ## SPATIAL: a scalar-integer LEAF that the bounds pass tracks by identity — a
  ## local / parameter variable, or a one-level field read `s->len` (keyed by its
  ## field path). A field read is untrusted exactly like a parameter (a parser reads
  ## lengths / offsets straight out of a struct), so making it a tracked value closes
  ## the silent gap where `buf[s->idx]` / `memcpy(.., s->len)` reached a sink unchecked.
  let u = unwrap(c)
  if clang_getCursorKind(u) == ckDeclRefExpr and isIntegerType(u):
    return (true, referencedUsr(u), spelling(u))
  if clang_getCursorKind(u) == ckMemberRefExpr and isIntegerType(u):
    let (fk, fd) = fieldPath(u)
    if fk.len > 0: return (true, fk, fd)
  (false, "", "")

proc parseLinear(ctx: Ctx, c: CXCursor): tuple[ok: bool, key, disp: string, off: int] =
  ## SPATIAL: read an expression as a simple linear form `term + k` / `term - k` / a bare
  ## `term` / a pure constant, where a `term` is a variable or a field read (scalarTerm).
  ## Returns ok=false for anything else (a product, a call, two variables, …) so a bound
  ## built on it is not asserted. `key` empty + ok = a pure constant `off`. This lets
  ## bounds and index/length expressions carry a `±k` offset (the look-ahead idiom
  ## `pos + 4 <= len`, the neighbour access `buf[i + 1]`).
  let u = unwrap(c)
  let cv = constIntValue(u)
  if cv.known: return (true, "", "", int(cv.value))
  let t = ctx.scalarTerm(u)
  if t.ok: return (true, t.key, t.disp, 0)
  if clang_getCursorKind(u) == ckBinaryOperator:
    let op = ctx.binOperator(u)
    if op == "+" or op == "-":
      let kids = collectChildren(u)
      if kids.len == 2:
        let l = unwrap(kids[0]); let r = unwrap(kids[1])
        let lc = constIntValue(l); let rc = constIntValue(r)
        let lt = ctx.scalarTerm(l); let rt = ctx.scalarTerm(r)
        if lt.ok and rc.known:
          return (true, lt.key, lt.disp, (if op == "+": int(rc.value) else: -int(rc.value)))
        if op == "+" and rt.ok and lc.known:
          return (true, rt.key, rt.disp, int(lc.value))
  (false, "", "", 0)

proc assignedFnName(ctx: Ctx, value: CXCursor): string =
  ## If `value` is `f` or `&f` referencing a FUNCTION declaration, its name; else "" (v3 stage 4).
  var e = unwrap(value)
  if clang_getCursorKind(e) == ckUnaryOperator and ctx.firstTokenSpelling(e) == "&":
    let kids = collectChildren(e)
    if kids.len >= 1: e = unwrap(kids[0])
  if clang_getCursorKind(e) == ckDeclRefExpr and
     clang_getCursorKind(clang_getCursorReferenced(e)) == ckFunctionDecl:
    return spelling(e)
  ""

proc lowerExprCalls(ctx: var Ctx, c: CXCursor, outp: var seq[Stmt])
  ## Forward decl: defined after lowerCall (which it calls); lowerAssign below needs it.
proc lowerCall(ctx: var Ctx, call: CXCursor, line: int, outp: var seq[Stmt])
  ## Forward decl: the call's effects (lowerCallCore) plus its unwinding exit; defined after them.

proc raiiBaseName(typeSpelling: string): string =
  ## `const ns::kir_owned_scalar<std::uint32_t> &` -> `kir_owned_scalar`: strip template
  ## arguments, cv / reference / pointer decorations and namespace qualifiers to the bare
  ## class name the `@raii` binding recorded.
  var s = typeSpelling
  let lt = s.find('<')
  if lt >= 0: s = s[0 ..< lt]
  s = s.replace("const ", "").replace("struct ", "").replace("class ", "")
  s = s.strip(chars = {' ', '&', '*'})
  let sep = s.rfind("::")
  if sep >= 0: s = s[sep + 2 .. ^1]
  s.strip

proc pointeeRecordName(c: CXCursor): string =
  ## `Cluster *c` -> "Cluster": the record a declaration's POINTER type points at, stripped of
  ## `struct` / cv decoration and typedef aliasing, so `@list <Type>` can be matched against it.
  ## Empty for a non-pointer, or a pointer to something that is not a record.
  let t = clang_getCursorType(c)
  if clang_getCanonicalType(t).kind != tyPointer: return ""
  let spelled = raiiBaseName($clang_getTypeSpelling(t))
  if spelled.len > 0: return spelled
  raiiBaseName($clang_getTypeSpelling(clang_getCanonicalType(t)))

proc qualName(c: CXCursor): string =
  ## `Class::method` for a member function (its semantic parent is a class / struct / class
  ## template — also for an out-of-line definition); "" for a free function. Contracts on a
  ## member function are stored under this key, so `action` of two classes never collide.
  let p = clang_getCursorSemanticParent(c)
  let pk = clang_getCursorKind(p)
  if pk == ckClassDecl or pk == ckStructDecl or pk == ckClassTemplate or pk == ckUnionDecl:
    return spelling(p) & "::" & spelling(c)
  ""

proc constructedClassOf(e: CXCursor): string =
  ## The class an initializer / RHS constructs: `new Derived` (the new-expression's type),
  ## or a constructor call `Derived(...)` (the constructor's class). "" otherwise.
  let u = unwrap(e)
  let k = clang_getCursorKind(u)
  if k == ckCXXNewExpr:
    return raiiBaseName($clang_getTypeSpelling(clang_getCursorType(u)))
  if k == ckCallExpr and clang_getCursorKind(clang_getCursorReferenced(u)) == ckConstructor:
    return spelling(clang_getCursorSemanticParent(clang_getCursorReferenced(u)))
  ""

proc classDefOfPointee(e: CXCursor): CXCursor =
  ## The class definition a pointer expression points to (`Base *b` -> Base's definition), or a
  ## null cursor when the pointee is not a class / struct whose definition is in view.
  let t = clang_getPointeeType(clang_getCanonicalType(clang_getCursorType(e)))
  let d = clang_getCursorDefinition(clang_getTypeDeclaration(clang_getCanonicalType(t)))
  let k = clang_getCursorKind(d)
  if k == ckClassDecl or k == ckStructDecl: d else: clang_getNullCursor()

proc hasVirtualDestructor(cls: CXCursor, depth = 0): bool =
  ## Is the destructor of class `cls` virtual — declared `virtual` here, or inherited from a base
  ## whose destructor is (an overriding destructor is virtual whether or not it says so)?
  if depth > 32 or clang_Cursor_isNull(cls) != 0: return false
  for ch in collectChildren(cls):
    let k = clang_getCursorKind(ch)
    if k == ckDestructor and clang_CXXMethod_isVirtual(ch) != 0: return true
    if k == ckCXXBaseSpecifier:
      let b = clang_getCursorDefinition(clang_getTypeDeclaration(
                clang_getCanonicalType(clang_getCursorType(ch))))
      if hasVirtualDestructor(b, depth + 1): return true
  false

proc newClassUsr(e: CXCursor): string =
  ## The class a `new` expression constructs (`new Derived(...)` -> Derived's USR), "" otherwise.
  let u = unwrap(e)
  if clang_getCursorKind(u) != ckCXXNewExpr: return ""
  let d = classDefOfPointee(u)
  if clang_Cursor_isNull(d) != 0: "" else: usr(d)

proc ownerRef(c: CXCursor): tuple[has: bool, key, disp: string] =
  ## The owner HANDLE an RAII operation acts on: a plain variable (`up`), or a one-level field
  ## path on a variable (`h.p` / `h->p` — an owner living in a struct field), keyed like every
  ## other field path (`<baseUSR>::field`) so an owner field has one identity everywhere.
  let e = unwrap(c)
  if clang_getCursorKind(e) == ckDeclRefExpr: return (true, referencedUsr(e), spelling(e))
  if clang_getCursorKind(e) == ckMemberRefExpr:
    let (fk, fd) = fieldPath(e)
    if fk.len > 0: return (true, fk, fd)
    # a field of the enclosing class inside its own member function — `this->p`, or the
    # implicit-this `p` (a MemberRefExpr with no variable base). Keyed `this::p`, the identity
    # fnVisitor seeds for every owner field at method entry.
    let kids = collectChildren(e)
    if kids.len == 0 or clang_getCursorKind(unwrap(kids[0])) == ckCXXThisExpr:
      let field = spelling(e)
      return (true, "this::" & field, "this->" & field)
  (false, "", "")

proc stdMoveOperand(c: CXCursor): tuple[has: bool, key, disp: string] =
  ## `std::move(v)` with `v` an owner handle -> that handle. The standard rvalue cast is a KNOWN
  ## vocabulary form (like `free`), not an inference: for a move-only owner it IS the ownership
  ## transfer (KIR's OwnershipConsume emits exactly this). Recognised by spelling `move` on a
  ## callee whose USR lives in namespace std (`@N@std@`).
  let e = unwrap(c)
  if clang_getCursorKind(e) == ckCallExpr and spelling(e) == "move" and
     ("@N@std@" in referencedUsr(e)):
    let mk = collectChildren(e)
    if mk.len >= 2: return ownerRef(mk[1])
  (false, "", "")

proc ownedOperandsIn(ctx: Ctx, c: CXCursor): seq[tuple[key, disp: string]] =
  ## The owner handles an initializer / constructor argument list moves INTO a new owner: a
  ## `std::move(v)` — directly, or inside the move-constructor wrapper libclang reports as a
  ## CallExpr spelled with the class name (children = all arguments, no callee-ref) — and a plain
  ## RAW handle given to an owner constructor (`unique_ptr<T> up(p)`: the owner takes p). A plain
  ## handle whose own type is an owner class (`shared_ptr<T> b = a`, a struct holding owners) is
  ## a COPY — a second live handle, never a move (a move-only owner does not compile there).
  ## Callers route each through moveOwner, which filters by what is actually tracked.
  let e = unwrap(c)
  let sm = stdMoveOperand(e)
  if sm.has: return @[(sm.key, sm.disp)]
  if clang_getCursorKind(e) == ckCallExpr and
     clang_getCursorKind(clang_getCursorReferenced(e)) == ckConstructor:
    for ck in collectChildren(e):
      let ism = stdMoveOperand(ck)
      if ism.has: result.add (ism.key, ism.disp)
      else:
        let r = ownerRef(ck)
        if not r.has: continue
        let ty = raiiBaseName($clang_getTypeSpelling(clang_getCursorType(unwrap(ck))))
        if ty in ctx.raiiTypes or ty in ctx.structOwnerFields: continue   # a copy, not a move
        result.add (r.key, r.disp)

proc moveOwner(ctx: var Ctx, key, disp: string, line: int, outp: var seq[Stmt]) =
  ## Move an owner handle out. A struct variable that HOLDS owner fields (`std::move(h)`) moves
  ## every one of its owner fields; a tracked owner (or owner field) moves itself. An untracked
  ## handle is not an owner here and is left alone.
  if key in ctx.structOwnerVars:
    for f in ctx.structOwnerVars[key]:
      outp.add emit(ikMove, line, a = f.disp, aKey = f.key)
  elif ctx.tracked.getOrDefault(key, false):
    outp.add emit(ikMove, line, a = disp, aKey = key)

proc memberCallOn(c: CXCursor): tuple[has: bool, meth, key, disp: string] =
  ## `obj.meth(...)` on an owner handle (a variable or a one-level field path): a CallExpr whose
  ## callee is a member function and whose callee child is a MemberRefExpr on the object. The
  ## library-seam accessors (`up.get()` / `up.release()` / `up.reset(p)`) are read from this shape.
  let e = unwrap(c)
  if clang_getCursorKind(e) == ckCallExpr and
     clang_getCursorKind(clang_getCursorReferenced(e)) == ckCXXMethod:
    let mk = collectChildren(e)
    if mk.len >= 1 and clang_getCursorKind(unwrap(mk[0])) == ckMemberRefExpr:
      let mkids = collectChildren(unwrap(mk[0]))
      if mkids.len >= 1:
        let r = ownerRef(mkids[0])
        if r.has: return (true, spelling(e), r.key, r.disp)
  (false, "", "", "")

const releasedResName = "unique_ptr::released"

proc ensureReleasedResource(ctx: var Ctx) =
  ## The raw pointer a built-in owner hands out through `.release()` is a KNOWN resource kind
  ## (kenbi's own vocabulary, like the owner itself): freed by `delete`. Registered so that a
  ## released pointer that nobody frees is a definite LEAK, not merely an undeclared resource.
  if releasedResName notin ctx.prog.resources:
    ctx.prog.resources[releasedResName] = Resource(name: releasedResName, freeId: "delete",
                                                   freeIds: @["delete"],
                                                   ownerId: "", sizeId: "", declLine: 0)

proc addrStoreTarget(ctx: Ctx, e: CXCursor): tuple[has: bool, key, disp: string] =
  ## `*dataPtr` where `dataPtr = &data` was recorded (addrOf): the LOCAL `data` itself — the
  ## store `*dataPtr = x` assigns it, the read `y = *dataPtr` copies it (Juliet 32).
  let u = unwrap(e)
  if clang_getCursorKind(u) != ckUnaryOperator or ctx.firstTokenSpelling(u) != "*": return (false, "", "")
  let bk = collectChildren(u)
  if bk.len < 1 or clang_getCursorKind(unwrap(bk[0])) != ckDeclRefExpr: return (false, "", "")
  let pk = referencedUsr(unwrap(bk[0]))
  if pk notin ctx.addrOf: return (false, "", "")
  (true, ctx.addrOf[pk].key, ctx.addrOf[pk].disp)

proc cursorTokens(ctx: Ctx, c: CXCursor): seq[string] =
  ## The spellings of every token in the cursor's extent.
  var toks: ptr CXToken
  var n: cuint
  clang_tokenize(ctx.tu, clang_getCursorExtent(c), addr toks, addr n)
  defer: clang_disposeTokens(ctx.tu, toks, n)
  let arr = cast[ptr UncheckedArray[CXToken]](toks)
  for i in 0 ..< int(n): result.add $clang_getTokenSpelling(ctx.tu, arr[i])

proc foldCond(ctx: Ctx, c: CXCursor): tuple[known: bool, value: int64] =
  ## A condition's compile-time value, if it has one: a constant expression (constIntValue),
  ## a file-scope `static` integer variable PROVABLY constant in this TU (foldedStatics), a
  ## `static` function whose whole body is `return <const>;` (foldedFns), and comparisons /
  ## logical connectives over those. Sound: a `static` object or function is invisible outside
  ## the TU, and the pre-scan admits a variable only if nothing in the TU assigns, increments
  ## or takes the address of it — so its value IS its initialiser. Anything else is unknown, so
  ## a genuine runtime branch is never folded away.
  let v = constIntValue(c)
  if v.known: return v
  let u = unwrap(c)
  case clang_getCursorKind(u)
  of ckDeclRefExpr:
    let k = referencedUsr(u)
    if k in ctx.foldedStatics: return (true, ctx.foldedStatics[k])
  of ckCallExpr:
    let k = referencedUsr(u)
    if k in ctx.foldedFns and collectChildren(u).len <= 1: return (true, ctx.foldedFns[k])
  of ckUnaryOperator:
    if ctx.firstTokenSpelling(u) == "!":
      let kids = collectChildren(u)
      if kids.len == 1:
        let a = ctx.foldCond(kids[0])
        if a.known: return (true, (if a.value == 0: 1'i64 else: 0'i64))
  of ckBinaryOperator:
    let kids = collectChildren(u)
    if kids.len == 2:
      let op = ctx.binOperator(u)
      let a = ctx.foldCond(kids[0])
      let b = ctx.foldCond(kids[1])
      if a.known and b.known:
        case op
        of "==": return (true, (if a.value == b.value: 1'i64 else: 0'i64))
        of "!=": return (true, (if a.value != b.value: 1'i64 else: 0'i64))
        of "<":  return (true, (if a.value < b.value: 1'i64 else: 0'i64))
        of "<=": return (true, (if a.value <= b.value: 1'i64 else: 0'i64))
        of ">":  return (true, (if a.value > b.value: 1'i64 else: 0'i64))
        of ">=": return (true, (if a.value >= b.value: 1'i64 else: 0'i64))
        of "&&": return (true, (if a.value != 0 and b.value != 0: 1'i64 else: 0'i64))
        of "||": return (true, (if a.value != 0 or b.value != 0: 1'i64 else: 0'i64))
        else: discard
  else: discard
  (false, 0'i64)

proc forCondCursor(ctx: Ctx, c: CXCursor, kids: seq[CXCursor],
                   bodyCur: CXCursor, hasBody: bool): tuple[found, absent: bool, cur: CXCursor] =
  ## A `for`'s controlling condition. libclang lists a ForStmt's children in source order with
  ## no marker saying which is init / cond / inc, so the header's own semicolons place them: the
  ## condition is the child starting between the first and the second `;` of `for (…;…;…)`.
  ## `absent` is `for (…; ; …)` — no condition clause at all. Neither flag is set for a header
  ## that does not tokenize into three clauses (a macro-hidden loop), so nothing is folded there.
  var toks: ptr CXToken
  var n: cuint
  clang_tokenize(ctx.tu, clang_getCursorExtent(c), addr toks, addr n)
  defer: clang_disposeTokens(ctx.tu, toks, n)
  let arr = cast[ptr UncheckedArray[CXToken]](toks)
  var depth = 0
  var semis: seq[int]                       # source offsets of the header's top-level `;`
  for i in 0 ..< int(n):
    case $clang_getTokenSpelling(ctx.tu, arr[i])
    of "(": inc depth
    of ")":
      dec depth
      if depth == 0: break
    of ";":
      if depth == 1:
        semis.add offsetOf(clang_getTokenLocation(ctx.tu, arr[i]))
        if semis.len == 2: break
    else: discard
  if semis.len < 2: return (false, false, c)
  for ch in kids:
    if hasBody and clang_equalCursors(ch, bodyCur) != 0: continue
    let so = startOffset(ch)
    if so > semis[0] and so < semis[1]: return (true, false, ch)
  (false, true, c)

proc loopTripFacts(ctx: Ctx, c: CXCursor, k: cint, kids: seq[CXCursor],
                   bodyCur: CXCursor, hasBody: bool):
                   tuple[atLeastOnce, contExits, atMostOnce: bool] =
  ## What a loop's controlling test says about how often its body runs, when that test has a
  ## compile-time value (see foldCond: an absent condition, a literal, a TU-private `static
  ## const`, a comparison of those). Anything not provably constant is a genuine 0+-trip loop
  ## and gets none of these.
  ##
  ##   `while (1)` / `for (;;)`  — enters unconditionally, and `continue` always re-enters, so
  ##                               the loop is left only by break / goto / return.
  ##   `do … while (cond)`       — enters unconditionally; `continue` jumps to the test, which
  ##                               may be false, so it is an exit edge too.
  ##   `do … while (0)`          — the standard multi-statement macro wrapper: runs exactly once.
  ##
  ## Without the first, `while (1) { p = malloc(…); … break; }` reads as "the allocation may be
  ## skipped and the release may never run" — a leak the program cannot produce. Without the
  ## last, `do { … free(p); } while (0)` reads as a double free of itself across a back edge
  ## that does not exist.
  var cond: CXCursor
  var hasCond = false
  var noCond = false
  case k
  of ckDoStmt:
    # children are [body, cond]
    if kids.len >= 2 and not (hasBody and clang_equalCursors(kids[^1], bodyCur) != 0):
      cond = kids[^1]; hasCond = true
    let cv = (if hasCond: ctx.foldCond(cond) else: (known: false, value: 0'i64))
    return (true, not (cv.known and cv.value != 0), cv.known and cv.value == 0)
  of ckWhileStmt:
    # children are [cond, body]; a C++ condition-variable declaration never folds.
    if kids.len >= 2: cond = kids[^2]; hasCond = true
  of ckForStmt:
    let fc = ctx.forCondCursor(c, kids, bodyCur, hasBody)
    cond = fc.cur; hasCond = fc.found; noCond = fc.absent
  else: discard
  let constTrue = noCond or (hasCond and (let cv = ctx.foldCond(cond); cv.known and cv.value != 0))
  (constTrue, false, false)

const stdContainers = [
  ## The standard sequence / associative containers, as a BUILT-IN vocabulary item (like
  ## unique_ptr / malloc): one holding RAW pointers releases nothing when it dies, so an owned
  ## pointer put into a local one leaks at scope exit unless something takes it out. A user
  ## class is NOT assumed to behave this way (its destructor may well delete the elements) —
  ## passing an owned pointer to one stays the ordinary uncontracted escape.
  "vector", "list", "deque", "set", "multiset", "unordered_set", "unordered_multiset",
  "stack", "queue", "priority_queue", "array", "forward_list",
  "map", "multimap", "unordered_map", "unordered_multimap"].toHashSet

const containerAdders = ["push_back", "push_front", "emplace_back", "emplace_front",
                         "insert", "emplace", "push"].toHashSet
const containerReaders = ["operator[]", "at", "front", "back", "top"].toHashSet

proc containerSlot(ctx: Ctx, obj: CXCursor): tuple[has: bool, key, disp: string] =
  ## The synthetic element slot of a STANDARD container object: `<objKey>::[]`, one slot for
  ## all its elements (index-insensitive — `v[0]` and `v[1]` share it, so kenbi never claims a
  ## precise per-element fact it cannot know).
  let r = ownerRef(obj)
  if not r.has: return (false, "", "")
  let tn = raiiBaseName($clang_getTypeSpelling(clang_getCursorType(unwrap(obj))))
  if tn notin stdContainers: return (false, "", "")
  (true, r.key & "::[]", r.disp & "[]")

proc containerObjectOf(e: CXCursor): CXCursor =
  ## The object a container accessor call acts on: `v[i]` / `v.at(i)` is a member CallExpr whose
  ## first child is a MemberRefExpr on the object (or, for `operator[]`, the object itself).
  let kids = collectChildren(e)
  if kids.len == 0: return e
  let first = unwrap(kids[0])
  if clang_getCursorKind(first) == ckMemberRefExpr:
    let mk = collectChildren(first)
    if mk.len >= 1: return mk[0]
  first

proc containerStoreTarget(ctx: Ctx, lhs: CXCursor):
    tuple[has: bool, slotKey, slotDisp, baseKey: string] =
  ## `m[k] = p` — an assignment THROUGH a standard container's element accessor: the container's
  ## element slot, and the container variable it belongs to.
  if clang_getCursorKind(lhs) != ckCallExpr or spelling(lhs) notin containerReaders:
    return (false, "", "", "")
  let obj = containerObjectOf(lhs)
  let slot = ctx.containerSlot(obj)
  if not slot.has: return (false, "", "", "")
  (true, slot.key, slot.disp, ownerRef(obj).key)

proc holdsMemoryOp(ctx: Ctx, c: CXCursor): bool =
  ## Does this subtree allocate or release? (a `new` / `delete`, an allocator or a declared
  ## deallocator call). Decides whether an unmodelled construct is inert or must be refused.
  let k = clang_getCursorKind(c)
  if k == ckCXXNewExpr or k == ckCXXDeleteExpr: return true
  if k == ckCallExpr and (spelling(c) in allocators or spelling(c) in ctx.deallocators): return true
  for ch in collectChildren(c):
    if ctx.holdsMemoryOp(ch): return true
  false

proc declSaysNothrow(ctx: Ctx, decl: CXCursor): bool =
  ## A `noexcept(<expr>)` specification libclang reports only as "computed" — it does not
  ## evaluate the expression. Read the declaration's own tokens for the two forms that are
  ## literally true: `noexcept(true)`, and glibc's `__THROW` / `__THROWNL` (which expand to
  ## it and mark every libc function — malloc / free / memcpy ...). Anything else stays "may
  ## throw" (default-red: `noexcept(false)` or a dependent expression is not a proof).
  var toks: ptr CXToken
  var n: cuint
  clang_tokenize(ctx.tu, clang_getCursorExtent(decl), addr toks, addr n)
  defer: clang_disposeTokens(ctx.tu, toks, n)
  let arr = cast[ptr UncheckedArray[CXToken]](toks)
  var words: seq[string]
  for i in 0 ..< int(n): words.add $clang_getTokenSpelling(ctx.tu, arr[i])
  for i, w in words:
    if w == "__THROW" or w == "__THROWNL": return true
    if w == "noexcept" and i + 3 < words.len and words[i + 1] == "(" and
       words[i + 2] == "true" and words[i + 3] == ")":
      return true
  false

proc normExcType(s: string): string =
  ## An exception type for handler matching: canonical, minus const / volatile / reference
  ## decoration and spacing — `const std::bad_alloc &` and `std::bad_alloc` are the same catch.
  var t = s.replace("const ", "").replace("volatile ", "").replace("&", "")
  t.strip

proc catchType(ctx: Ctx, catchStmt: CXCursor): string =
  ## What a `catch` clause names: "..." for `catch (...)` (the `...` token — libclang exposes no
  ## exception-declaration kind for it), else the caught type — from the exception declaration
  ## cursor when there is one (canonical, so a typedef / `using` resolves), or from the tokens
  ## between the parentheses for an unnamed `catch (T)`.
  var toks: ptr CXToken
  var n: cuint
  clang_tokenize(ctx.tu, clang_getCursorExtent(catchStmt), addr toks, addr n)
  defer: clang_disposeTokens(ctx.tu, toks, n)
  let arr = cast[ptr UncheckedArray[CXToken]](toks)
  var words: seq[string]
  for i in 0 ..< int(n): words.add $clang_getTokenSpelling(ctx.tu, arr[i])
  if words.len >= 3 and words[2] == "...": return "..."
  for k in collectChildren(catchStmt):
    if clang_getCursorKind(k) == ckVarDecl:
      return normExcType($clang_getTypeSpelling(clang_getCanonicalType(clang_getCursorType(k))))
  var inner: seq[string]
  var i = 2
  while i < words.len and words[i] != ")":
    inner.add words[i]; inc i
  normExcType(inner.join(" "))

proc thrownType(c: CXCursor): string =
  ## The canonical type of a `throw e` operand ("" for a bare re-throw `throw;`).
  let kids = collectChildren(c)
  if kids.len == 0: return ""
  normExcType($clang_getTypeSpelling(clang_getCanonicalType(clang_getCursorType(unwrap(kids[0])))))

proc mayThrow(ctx: Ctx, call: CXCursor): bool =
  ## Can control leave the caller through this call by unwinding? C++ with exceptions on
  ## only. The proof is the callee's DECLARED exception specification, read from the
  ## referenced declaration (`noexcept`, `throw()`, `__attribute__((nothrow))`, a literally
  ## true computed form) or the `@nothrow` vouch on its name. No specification = may throw:
  ## declared, not inferred from the callee's body.
  if not ctx.exceptionsOn: return false
  let r = clang_getCursorReferenced(call)
  if spelling(call) in ctx.nothrowFuncs or spelling(r) in ctx.nothrowFuncs: return false
  case int(clang_getCursorExceptionSpecificationType(r))
  of 1, 4, 9: false                       # throw() / noexcept / nothrow attribute
  of 5: not ctx.declSaysNothrow(r)        # noexcept(expr): only a literally-true form counts
  else: true                              # none / dynamic / unevaluated / not a function

proc newMayThrow(ctx: Ctx, e: CXCursor): bool =
  ## A plain `new T(...)` may throw std::bad_alloc; `new (std::nothrow) T(...)` returns null.
  ## `@nothrow(new)` declares the project's allocation-failure policy — OOM terminates, `new`
  ## never unwinds — so every plain `new` counts as nothrow without rewriting each site.
  if not ctx.exceptionsOn or "new" in ctx.nothrowFuncs: return false
  for k in collectChildren(e):
    if spelling(unwrap(k)) == "nothrow": return false
  true

proc scanMayThrow(ctx: Ctx, c: CXCursor, outp: var seq[Stmt]) =
  ## The unwinding exits inside an expression whose ownership effects are NOT lowered (an
  ## RAII owner's initializer: `auto sp = std::make_shared<int>(1)`, `unique_ptr<int> up(new
  ## int)`) — a factory or `new` that throws assigns nothing, but every raw owner already
  ## held is lost on that path, so the exits are still emitted.
  let u = unwrap(c)
  let k = clang_getCursorKind(u)
  if k == ckCallExpr and ctx.mayThrow(u):
    outp.add emit(ikMayThrow, startLine(u), a = spelling(u))
  elif k == ckCXXNewExpr and ctx.newMayThrow(u):
    outp.add emit(ikMayThrow, startLine(u), a = "new")
  for ch in collectChildren(u): ctx.scanMayThrow(ch, outp)

proc indirectFnptr(call: CXCursor): tuple[isIndirect: bool, usr, disp: string] =
  ## If `call` goes THROUGH a function pointer (a var / param fnptr, or a struct-field fnptr), the
  ## pointer's decl USR (what `@calls` binds to) + display; else isIndirect=false. A DIRECT call
  ## (callee references a ckFunctionDecl) is not indirect. (v3 stage 4.)
  let kids = collectChildren(call)
  if kids.len == 0: return (false, "", "")
  # a CONSTRUCTOR call's children are all ARGUMENTS (no callee-ref child): its first argument
  # is the source object, never a function pointer being called through
  if clang_getCursorKind(clang_getCursorReferenced(call)) == ckConstructor: return (false, "", "")
  var callee = unwrap(kids[0])
  # `(*fp)(x)` is `fp(x)`: dereferencing a function pointer is a no-op in C, and the explicit
  # form is what allocator macros expand to (zlib's ZALLOC, and the same shape elsewhere)
  while clang_getCursorKind(callee) == ckUnaryOperator:
    let inner = collectChildren(callee)
    if inner.len != 1: break
    callee = unwrap(inner[0])
  case clang_getCursorKind(callee)
  of ckDeclRefExpr:
    let rk = clang_getCursorKind(clang_getCursorReferenced(callee))
    if rk == ckVarDecl or rk == ckParmDecl:            # a function-pointer variable / parameter
      return (true, referencedUsr(callee), spelling(callee))
  of ckMemberRefExpr:
    if clang_getCursorKind(clang_getCursorReferenced(callee)) == ckFieldDecl:  # a fnptr FIELD `c->cb`
      return (true, referencedUsr(callee), spelling(callee))
  else: discard
  (false, "", "")

proc effectiveCallee(ctx: Ctx, call: CXCursor): string =
  ## The name a call is known by for the ALLOCATOR vocabulary. A project that injects its
  ## allocator through a struct — `(*(strm->zalloc))(opaque, n, size)`, zlib's ZALLOC and the
  ## same shape in sqlite / lua / most embedded APIs — has no callee name of its own, so the
  ## function-pointer FIELD is what the declaration can name (`@allocator … { alloc: zalloc }`).
  ## Used only when that name is actually declared; otherwise the plain spelling stands.
  let ind = indirectFnptr(call)
  if ind.isIndirect and ind.disp.len > 0 and
     (ind.disp in ctx.customAllocRes or ind.disp in ctx.customRealloc or
      ind.disp in ctx.deallocators):
    return ind.disp
  spelling(call)

proc collectionLink(ctx: Ctx, res, targetKey: string): string =
  ## The `link:` field of the intrusive collection this allocation is a node of, declared
  ## either on the resource (`@mem … { link: next }`) or on the target's record TYPE
  ## (`@list Cluster { link: next }` — the form that reaches a project's own allocator family,
  ## where there is no per-site resource to hang it on). Empty = an ordinary single object.
  if res in ctx.prog.resources and ctx.prog.resources[res].linkId.len > 0:
    return ctx.prog.resources[res].linkId
  let ty = ctx.varTypes.getOrDefault(targetKey, "")
  if ty.len > 0: return ctx.listTypes.getOrDefault(ty, "")
  ""

proc lowerAssignInner(ctx: var Ctx, targetName, targetKey: string, value: CXCursor,
                      line: int, outp: var seq[Stmt]) =
  ## Lower an initializer / RHS bound to `target` into one IR instruction.
  ## `targetKey` is the target declaration's USR (its identity); `targetName`
  ## is the display name. Tracking is keyed by identity, so same-named decls in
  ## different scopes never alias.
  # SPATIAL: any reassignment invalidates the target's recorded allocation-size symbol
  # (re-added below only if this RHS is a fresh builtin allocation). Sound: a stale
  # symbol could otherwise produce a false GREEN at a later index sink.
  ctx.bufSizeSym.del targetKey
  ctx.addrOf.del targetKey          # any reassignment ends `p = &local` (re-recorded below)
  ctx.dynType.del targetKey
  ctx.newClass.del targetKey
  block newClass:                   # `Base *b = new Derived`: the object `delete b` destroys
    let nc = newClassUsr(value)
    if nc.len > 0: ctx.newClass[targetKey] = nc
  block dynamicType:                # `Base *b = new Derived` / `Base &b = Derived()`: b dispatches to Derived
    let dyn = constructedClassOf(value)
    if dyn.len > 0: ctx.dynType[targetKey] = dyn
  # `@copy` (duplicate): the RHS produces a NEW independent owned object, so the
  # target gets a fresh obligation rather than aliasing the source. This is the
  # disambiguation the move/copy ambiguity needs (deep copy vs. borrow/alias).
  if line in ctx.copyLines:
    let res = (if ctx.copyLines[line].len > 0: ctx.copyLines[line]
               else: ctx.resourceFor(targetName, line))
    if clang_getCursorKind(unwrap(value)) == ckCallExpr and ctx.mayThrow(unwrap(value)):
      outp.add emit(ikMayThrow, line, a = spelling(unwrap(value)))  # a throwing copy assigns nothing
    outp.add emit(ikAlloc, line, a = targetName, b = res, aKey = targetKey)
    ctx.tracked[targetKey] = true
    return
  let v = unwrap(value)
  let vk = clang_getCursorKind(v)
  # `p = NULL` / `p = 0` on a tracked pointer: p owns nothing from here, and releasing it is
  # the defined no-op — `free(p); p = NULL;` is the standard defensive idiom and must not read
  # as a double free at the next release.
  if vk != ckCallExpr and ctx.tracked.getOrDefault(targetKey, false):
    let cv = constIntValue(v)
    if cv.known and cv.value == 0:
      outp.add emit(ikSetNull, line, a = targetName, aKey = targetKey)
      return
  # `p = release(p)` where the release is DECLARED to return NULL (`free_returns_null`): the
  # release happens (lowered through the call below), and p is null afterwards.
  if vk == ckCallExpr and spelling(v) in ctx.freeReturnsNull:
    ctx.lowerExprCalls(v, outp)
    outp.add emit(ikSetNull, line, a = targetName, aKey = targetKey)
    return
  # CONCURRENCY (v3 stage 4): assigning a function-pointer with a declared `@calls(...)` set a target
  # OUTSIDE that set — the annotation-vs-implementation check. Emitted on the violation only (the
  # target set is in scope here); a function-name RHS produces no ownership instruction, so this does
  # not disturb the normal lowering below.
  if targetKey in ctx.fnptrTargets:
    let fn = ctx.assignedFnName(value)
    if fn.len > 0 and fn notin ctx.fnptrTargets[targetKey]:
      outp.add emit(ikFnAssign, line, a = targetName, b = fn)
  # arena create: `R = arena_create()` allocates the arena resource (owned, freed
  # once by its declared destroy fn); arena alloc: `p = arena_alloc(R, ...)` makes
  # p a region-owned object borrowed from R (shares R's lifetime).
  if vk == ckCallExpr and spelling(v) in ctx.arenaCreate:
    if ctx.mayThrow(v): outp.add emit(ikMayThrow, line, a = spelling(v))
    outp.add emit(ikAlloc, line, a = targetName, b = ctx.arenaCreate[spelling(v)], aKey = targetKey)
    ctx.tracked[targetKey] = true
    return
  let rc = (if vk == ckCallExpr and ctx.returnContracts.hasKey(spelling(v)):
              (true, ctx.returnContracts[spelling(v)].kind) else: (false, rcOwned))
  if vk == ckCallExpr and (spelling(v) in ctx.arenaAlloc or (rc[0] and rc[1] == rcArenaFromArg)):
    # built-in arena alloc, or a `@arena_alloc` wrapper (cross-file contract): the
    # result is a region object borrowed from the arena passed as arg 1.
    let kids = collectChildren(v)
    if spelling(v) notin ctx.arenaAlloc:        # a declared `@arena_alloc` wrapper: trusted too
      ctx.callEdges.add CallEdge(callee: spelling(v), line: line, kind: ckContracted)
    if kids.len >= 2:
      let arenaArg = unwrap(kids[1])
      if clang_getCursorKind(arenaArg) == ckDeclRefExpr:
        outp.add emit(ikArenaAlloc, line, a = targetName, b = spelling(arenaArg),
                      aKey = targetKey, bKey = referencedUsr(arenaArg))
        ctx.tracked[targetKey] = true
    return
  # pointer-into-local: `p = &local` / `p = localArray` / `p = anotherLocalPtr`.
  # The target now aliases stack storage; returning it later is DANGLING_RETURN.
  let local = ctx.pointsIntoLocal(v)
  if local.yes:
    outp.add emit(ikLocalAddr, line, a = targetName, aKey = targetKey)
    ctx.localAddrVars.incl targetKey
    if vk == ckUnaryOperator and ctx.firstTokenSpelling(v) == "&":
      let inner = collectChildren(v)
      if inner.len >= 1 and clang_getCursorKind(unwrap(inner[0])) == ckDeclRefExpr:
        # `dataPtr = &data`: stores / reads through `*dataPtr` act on `data` (addrStoreTarget)
        ctx.addrOf[targetKey] = (referencedUsr(unwrap(inner[0])), spelling(unwrap(inner[0])))
    return
  # `q = realloc(p, n)`: reallocation CONTINUES the buffer's obligation — the old block at `p` is
  # extended in place or freed-and-moved, so the result carries the SAME obligation, not a fresh
  # one. Alias the result to `p`'s origin so a single owner remains: the safe idiom
  # `q = realloc(p,n); if(q) p=q; free(p)` frees exactly once (GREEN), a result that is never freed
  # still leaks, and freeing both `p` and the result is a double free. `realloc(NULL, n)` / an
  # untracked pointer is a fresh malloc — fall through to the allocator branch below.
  let vCallee = (if vk == ckCallExpr: ctx.effectiveCallee(v) else: "")
  if vk == ckCallExpr and (vCallee == "realloc" or vCallee in ctx.customRealloc):
    let kids = collectChildren(v)
    if kids.len >= 2:
      let arg = unwrap(kids[1])
      var srcKey, srcDisp: string
      if clang_getCursorKind(arg) == ckDeclRefExpr:
        srcKey = referencedUsr(arg); srcDisp = spelling(arg)
      elif clang_getCursorKind(arg) == ckMemberRefExpr:
        (srcKey, srcDisp) = fieldPath(arg)
      if srcKey.len > 0 and ctx.tracked.getOrDefault(srcKey, false):
        if ctx.mayThrow(v): outp.add emit(ikMayThrow, line, a = spelling(v))
        if targetKey == srcKey:
          # SELF-reassign `p = realloc(p, n)`: the success model (alias the result to the source
          # origin) hides the failure path — on OOM the NULL result overwrites the only handle to
          # the original block, which then leaks irrecoverably. Flag it (REALLOC_SELF_REASSIGN);
          # the obligation is left on the same origin so a following `free(p)` still discharges it.
          outp.add emit(ikRealloc, line, a = targetName, aKey = targetKey)
        else:
          # FRESH-dest `q = realloc(p, n)`: the result continues the same obligation (aliases the
          # source origin — the SUCCESS path). The failure path (q NULL, original retained via p)
          # is not flatly verifiable, so the engine default-reds it (REALLOC_UNVERIFIED) unless the
          # line carries a `@realloc` vouch. Carry both handles so the engine can alias + decide.
          outp.add emit(ikRealloc, line, a = targetName, b = srcDisp, aKey = targetKey, bKey = srcKey)
        ctx.tracked[targetKey] = true
        if kids.len >= 3:                       # SPATIAL: the reallocated buffer's new size symbol
          let sym = ctx.allocCountSym(unwrap(kids[2]))
          if sym.symKey.len > 0: ctx.bufSizeSym[targetKey] = (sym.symKey, sym.symDisp, 0)
        return
  # a fresh obligation is created by `new`, a builtin allocator, or a call to a
  # function declared `@owns` (a factory returning an owned pointer — the
  # callsite owns the result and must free it exactly once, across the call
  # boundary; generalises the fixed allocator vocabulary).
  if vk == ckCXXNewExpr or
     (vk == ckCallExpr and (vCallee in allocators or vCallee in ctx.customAllocRes or
                            (rc[0] and rc[1] == rcOwned))):
    # A `@owns` FACTORY is a trusted boundary like any other declared contract: this GREEN
    # rests on that function really returning a fresh owned object. Record the ownership edge
    # so the trusted frontier lists it until its body is covered too (a plain malloc / new is
    # kenbi's own vocabulary — a flow leaf, not a body to cover).
    if vk == ckCallExpr and rc[0] and rc[1] == rcOwned and spelling(v) notin allocators:
      ctx.callEdges.add CallEdge(callee: spelling(v), line: line, kind: ckContracted)
    # a `@allocator`-declared wrapper names its resource directly; otherwise the nearest `@mem`
    let res = (if vCallee in ctx.customAllocRes: ctx.customAllocRes[vCallee]
               else: ctx.resourceFor(targetName, line,
                                     isNew = (if vk == ckCXXNewExpr: 1 else: 0)))
    # a THROWING allocation assigns nothing: the unwinding exit precedes the new obligation —
    # what that path loses is every raw owner already held, never this one (C++ only).
    if (vk == ckCXXNewExpr and ctx.newMayThrow(v)) or (vk == ckCallExpr and ctx.mayThrow(v)):
      outp.add emit(ikMayThrow, line, a = (if vk == ckCXXNewExpr: "new" else: spelling(v)))
    outp.add emit(ikAlloc, line, a = targetName, b = res, aKey = targetKey,
                  cKey = ctx.collectionLink(res, targetKey))
    ctx.tracked[targetKey] = true
    # SPATIAL: record the buffer's symbolic allocation count, so a later `idx < n` bound
    # that names the same identifier covers it (variable-size buffer by identity match).
    if vk == ckCallExpr and spelling(v) in allocators:
      let ai = allocSizeArgIndex(spelling(v))
      let kids = collectChildren(v)
      if ai >= 1 and ai < kids.len:
        let sym = ctx.allocCountSym(kids[ai])
        if sym.symKey.len > 0: ctx.bufSizeSym[targetKey] = (sym.symKey, sym.symDisp, 0)
    return
  if vk == ckDeclRefExpr:
    let srcKey = referencedUsr(v)
    # `char **p = (char **)v` where `*v`'s slot carries a contract: the copy derefs to the same
    # object, so it inherits the slot. Without this the `void *` hand-off variants lost the
    # contract at the cast and the sink's own `free(*p)` read as an unaccounted release.
    if ctx.tracked.getOrDefault(srcKey & "::*", false):
      ctx.pointeeAlias[targetKey] = srcKey & "::*"
    elif srcKey in ctx.pointeeAlias:
      ctx.pointeeAlias[targetKey] = ctx.pointeeAlias[srcKey]
    if ctx.tracked.getOrDefault(srcKey, false):
      outp.add emit(ikCopy, line, a = targetName, b = spelling(v),
                    aKey = targetKey, bKey = srcKey)
      ctx.tracked[targetKey] = true
    return
  block readThroughAddr:
    let at = ctx.addrStoreTarget(v)   # `y = *dataPtr` with `dataPtr = &data`: a copy of `data`
    if at.has:
      if ctx.tracked.getOrDefault(at.key, false):
        outp.add emit(ikCopy, line, a = targetName, b = at.disp, aKey = targetKey, bKey = at.key)
        ctx.tracked[targetKey] = true
      return
  block readPointeeSlot:
    # `data = *dataPtr` where the pointee slot carries a contract (`@frees(*dataPtr)`): the
    # local aliases that obligation, so the `free(data)` the sink actually writes discharges
    # the declared contract instead of reading as an unaccounted release.
    let ps = ctx.pointeeSlot(v)
    if ps.key.len > 0 and ctx.tracked.getOrDefault(ps.key, false):
      outp.add emit(ikCopy, line, a = targetName, b = ps.disp, aKey = targetKey, bKey = ps.key)
      ctx.tracked[targetKey] = true
      return
  if vk == ckMemberRefExpr or (vk == ckArraySubscriptExpr and fieldPath(v).key.len > 0):
    # `x = b->buf` / `x = arr[2]`: the target aliases the field's origin. The alias means the field is no
    # longer confined to the field path, so the exit leak scan defers it (an alias could free
    # it); and a later free / return of the target discharges the origin. Same origin -> a
    # double-free through both handles is still caught (#2b).
    let (fk, fd) = fieldPath(v)
    if fk.len > 0 and ctx.tracked.getOrDefault(fk, false):
      outp.add emit(ikCopy, line, a = targetName, b = fd, aKey = targetKey, bKey = fk)
      ctx.tracked[targetKey] = true
      return
    # `cur = cur->next` where `next` is a resource's declared `link:` field: a WALK STEP along
    # an intrusive collection, not a read of an object kenbi cannot place. The engine confirms
    # the base's own resource declares this link (some unrelated struct's `next` field is a
    # plain unplaceable read) and binds the target as another cursor on the same collection.
    if vk == ckMemberRefExpr and spelling(v) in ctx.linkFields:
      let kids = collectChildren(v)
      if kids.len >= 1:
        let base = unwrap(kids[0])
        let bk = referencedUsr(base)
        if clang_getCursorKind(base) == ckDeclRefExpr and ctx.tracked.getOrDefault(bk, false):
          outp.add emit(ikLinkRead, line, a = targetName, aKey = targetKey,
                        b = spelling(base), bKey = bk, cKey = spelling(v))
          ctx.tracked[targetKey] = true
          return
    return
  if vk == ckBinaryOperator:
    let op = ctx.binOperator(v)
    if op == "+":
      let kids = collectChildren(v)
      if kids.len == 2:
        let base = unwrap(kids[0])
        let offc = unwrap(kids[1])
        let baseKey = referencedUsr(base)
        if clang_getCursorKind(base) == ckDeclRefExpr and
           ctx.tracked.getOrDefault(baseKey, false):
          let off = (if clang_getCursorKind(offc) == ckIntegerLiteral:
                       ctx.intLiteralValue(offc) else: 0)
          outp.add emit(ikInterior, line, a = targetName, b = spelling(base),
                        off = off, aKey = targetKey, bKey = baseKey)
          ctx.tracked[targetKey] = true
    ctx.lowerExprCalls(v, outp)   # a call UNDER an operator (`take(p) + 1`) still escapes its args
    return
  # LIBRARY SEAM of an owner: `p = up.get()` hands out a BORROW — p is a non-owning interior
  # alias of the owner's resource (freeing it is FREE_INTERIOR: the owner still releases it);
  # `p = up.release()` hands out OWNERSHIP — the owner relinquishes (moved) and p owns a raw
  # resource that must now be freed or transferred (a declared @mem names it; else default-red).
  block containerRead:
    # `p = v[2]` / `v.at(i)` / `v.front()` on a STANDARD container holding an owned element:
    # the target ALIASES the element slot, so releasing it there discharges the obligation
    # (`for (auto p : v) free(p);` is clean) and a second release is a DOUBLE_FREE.
    if vk == ckCallExpr and spelling(v) in containerReaders:
      let rk = collectChildren(v)
      if rk.len >= 1:
        let slot = ctx.containerSlot(containerObjectOf(v))
        if slot.has and ctx.tracked.getOrDefault(slot.key, false):
          outp.add emit(ikCopy, line, a = targetName, b = slot.disp,
                        aKey = targetKey, bKey = slot.key)
          ctx.tracked[targetKey] = true
          return
  block seamAssign:
    let mc = memberCallOn(v)
    if mc.has and mc.key in ctx.raiiVars:
      let ok = mc.key
      if ctx.mayThrow(v): outp.add emit(ikMayThrow, line, a = mc.meth)
      outp.add emit(ikUse, line, a = mc.disp, aKey = ok)   # the seam USES the handle (moved = UAM)
      if mc.meth == "get":
        outp.add emit(ikInterior, line, a = targetName, b = mc.disp, aKey = targetKey, bKey = ok)
        ctx.tracked[targetKey] = true
        return
      if mc.meth == "release":
        outp.add emit(ikMove, line, a = mc.disp, aKey = ok)
        outp.add emit(ikAlloc, line, a = targetName, b = ctx.resourceFor(targetName, line), aKey = targetKey)
        ctx.tracked[targetKey] = true
        return
  # `x = f(...)` where f's VISIBLE body frees the pointer it returns (and declares nothing): the
  # result is a possibly-dangling handle — default-red advisory (POSSIBLE_USE_AFTER_FREE on a
  # use, POSSIBLE_DOUBLE_FREE on a free), the result-side sibling of the visibly-frees-its-
  # argument advisory. The bug itself is reported in f (DANGLING_RETURN).
  if vk == ckCallExpr and spelling(v) in ctx.returnsFreed and not rc[0]:
    ctx.lowerExprCalls(v, outp)
    outp.add emit(ikMaybeFreedResult, line, a = targetName, b = spelling(v), aKey = targetKey)
    ctx.tracked[targetKey] = true
    return
  # Fall-through: a GENERIC call whose result is assigned (`int ret = f(p)`) or any other
  # expression shape. The result-producing forms above (allocator / @owns / arena / copy /
  # alias / interior) all returned early, so this lowers ARG effects only for values whose
  # result is NOT tracked-owned — no double-lowering of an owned-result call's own args.
  ctx.lowerExprCalls(v, outp)

proc bindsTarget(body: seq[Stmt], key: string): bool =
  ## Did any instruction emitted for this assignment rebind `key`?
  for s in body:
    case s.kind
    of stInstr:
      if s.ik in bindingInstrs and s.aKey == key: return true
    of stIf:
      if s.thenBody.bindsTarget(key) or s.elseBody.bindsTarget(key): return true
    of stLoop:
      if s.loopBody.bindsTarget(key): return true
    of stSwitch:
      for cse in s.cases:
        if cse.bindsTarget(key): return true
    of stLabel: discard
    of stTry:
      if s.tryBody.bindsTarget(key): return true
      for h in s.handlers:
        if h.bindsTarget(key): return true
  false

proc lowerAssign(ctx: var Ctx, targetName, targetKey: string, value: CXCursor,
                 line: int, outp: var seq[Stmt]) =
  ## Lower an assignment, then make sure the target's OLD identity does not survive it.
  ## Every binding form in lowerAssignInner recognises one RHS shape and returns; an RHS
  ## none of them recognised (a read out of an untracked field, an uncontracted call's
  ## result, an arbitrary expression) used to emit nothing at all for the target, which
  ## silently left a tracked handle naming a resource it no longer points at. See ikRebind.
  let wasTracked = ctx.tracked.getOrDefault(targetKey, false)
  let before = outp.len
  ctx.lowerAssignInner(targetName, targetKey, value, line, outp)
  if wasTracked and not outp[before .. ^1].bindsTarget(targetKey):
    outp.add emit(ikRebind, line, a = targetName, aKey = targetKey)
    # `tracked` deliberately stays true: it decides which INSTRUCTIONS are emitted for later
    # mentions of the handle (a release, a return, a copy), and those must keep being emitted —
    # what the handle names is the engine's question now, and it answers it per path. Clearing
    # it here dropped the operand from a later `return blob`, and the resource the returned
    # handle carries out looked abandoned.

const knownBorrowFns = [
  ## libc functions that take a pointer but never take ownership of it (read /
  ## write / format only — they borrow). Passing an owned pointer to one of these
  ## is a use, not an escape. This is the seed of a builtin contract table: every
  ## other uncontracted callee is treated as an escape boundary (default-red), so
  ## user functions must declare @frees / @borrows / @moves (or the call is
  ## @unsafe). Extend this list as more libc contracts are catalogued.
  "printf", "fprintf", "sprintf", "snprintf", "vprintf", "vfprintf", "vsprintf",
  "vsnprintf", "scanf", "fscanf", "sscanf", "puts", "fputs", "fputc", "putc",
  "fwrite", "fread", "perror", "putchar",
  "strlen", "strnlen", "strcmp", "strncmp", "strcasecmp", "strncasecmp",
  "strcpy", "strncpy", "strcat", "strncat", "strchr", "strrchr", "strstr",
  "strspn", "strcspn", "strpbrk", "strtok", "strtol", "strtoul", "strtoll",
  "strtoull", "strtod", "strtof", "atoi", "atol", "atoll", "atof",
  "memcpy", "memmove", "memset", "memcmp", "memchr",
  # the wide-character mirrors (wchar.h): read / write / format only, like their char forms
  "wcslen", "wcsnlen", "wcscmp", "wcsncmp", "wcscasecmp", "wcsncasecmp",
  "wcscpy", "wcsncpy", "wcscat", "wcsncat", "wcschr", "wcsrchr", "wcsstr",
  "wcsspn", "wcscspn", "wcspbrk", "wcstok", "wcstol", "wcstoul", "wcstoll", "wcstoull",
  "wcstod", "wcstof", "wmemcpy", "wmemmove", "wmemset", "wmemcmp", "wmemchr",
  "wprintf", "fwprintf", "swprintf", "vwprintf", "vfwprintf", "vswprintf",
  "wscanf", "fwscanf", "swscanf", "fputws", "fputwc", "putwc", "putwchar", "fgetws",
].toHashSet

proc argContract(ctx: Ctx, callee: string, pos: int): tuple[has: bool, instr: InstrKind, accessor: string] =
  ## The declared callsite effect (@frees->ikFree, @moves->ikMove) on argument
  ## `pos` of `callee`, if any. Generic over every registered arg contract. `accessor`
  ## names what the callee acts on: "" = the arg, "*" = its pointee, else a field name.
  for (idx, instr, accessor) in ctx.argContracts.getOrDefault(callee, @[]):
    if idx == pos: return (true, instr, accessor)
  (false, ikUse, "")

proc indirectArgContract(ctx: Ctx, fnptrUsr: string, pos: int): tuple[has: bool, instr: InstrKind, accessor: string] =
  ## The callsite effect on argument `pos` of a call THROUGH a function pointer: resolved via the
  ## pointer's declared `@calls(f, g, ...)` target set — the contract every target agrees on.
  ## Targets that disagree (or an undeclared pointer) give no contract: the argument crosses an
  ## uncontracted boundary (default-red), never the most convenient target's contract.
  let targets = ctx.fnptrTargets.getOrDefault(fnptrUsr)
  if targets.len == 0: return (false, ikUse, "")
  var first = true
  for t in targets:
    let c = ctx.argContract(t, pos)
    if first: result = c; first = false
    elif c != result: return (false, ikUse, "")

proc argContractOf(ctx: Ctx, callee: string, pos: int, instr: InstrKind): tuple[has: bool, accessor: string] =
  ## The declared contract of ONE kind on argument `pos` (a parameter can carry several:
  ## `@owns(p)` + `@frees(p)` — a source that allocates into the out-parameter and frees it
  ## again before returning hands the caller a DANGLING pointer).
  for (idx, i, accessor) in ctx.argContracts.getOrDefault(callee, @[]):
    if idx == pos and i == instr: return (true, accessor)
  (false, "")

proc extraAccessorContracts(ctx: Ctx, callee: string, pos: int):
    seq[tuple[instr: InstrKind, accessor: string]] =
  ## Every ACCESSOR contract on argument `pos` beyond the one `argContract` will return. One
  ## parameter legitimately carries several — a destructor declares `@frees(n)` for the node and
  ## `@frees(n.name)` / `@frees(n.next)` for what it owns — and the ladder below applies exactly
  ## one, so the rest were silently dropped: the caller's field kept its obligation and read as a
  ## leak at the very call that releases it. Returns the others so they can be applied too, and
  ## deliberately excludes the one the ladder already handles so nothing is emitted twice.
  let first = ctx.argContract(callee, pos)
  var skipped = false
  for (idx, instr, accessor) in ctx.argContracts.getOrDefault(callee, @[]):
    if idx != pos or accessor.len == 0: continue
    if not skipped and first.has and first.instr == instr and first.accessor == accessor:
      skipped = true                                  # this is the one the ladder applies
      continue
    result.add (instr, accessor)

proc calleeParamName(ctx: Ctx, callee: string, pos: int): string =
  ## The name of parameter `pos` of `callee`, from any recorded signature (proto
  ## or definition). Used to say WHICH parameter lacks an ownership contract in an
  ## UNCONTRACTED_ESCAPE message. Empty if the signature / position is unknown.
  for fn in ctx.funcSigs:
    if (fn.name == callee or fn.qual == callee) and pos < fn.params.len: return fn.params[pos].name
  ""

# SPATIAL: functions whose argument at this 0-based position is a length / count
# written into a fixed buffer — an untrusted size here is the classic overflow
# (CWE-120 / CWE-787). Emitted as an ikIndex size sink (must be validated).
const sizeArgPos = {
  "memcpy": 2, "memmove": 2, "memset": 2, "strncpy": 2, "strncat": 2,
  "snprintf": 1, "vsnprintf": 1, "fgets": 1, "read": 2, "recv": 2,
}.toTable
# The 0-based position of the DESTINATION buffer argument, so the size sink can check
# the length is APPROPRIATE for that buffer (covers its size), not merely bounded.
const bufArgPos = {
  "memcpy": 0, "memmove": 0, "memset": 0, "strncpy": 0, "strncat": 0,
  "snprintf": 0, "vsnprintf": 0, "fgets": 0, "read": 1, "recv": 1,
}.toTable
# SPATIAL: the 0-based position of the SOURCE (read) buffer for a copy — `len` bytes are also
# READ from here. A read past a shorter-than-`len` source is a memcpy SOURCE over-read (e.g.
# Heartbleed: copy `payload` bytes from a record that only holds `rrec_length`). Checked ONLY
# when the source's size is DECLARED (@counted_by / fixed array); an unsized source is the
# caller's contract, not flagged (else every raw-pointer copy would be RED). memset has no source.
const srcArgPos = {
  "memcpy": 1, "memmove": 1, "strncpy": 1, "strncat": 1,
}.toTable
# SPATIAL: fixed-width binary read/write helpers (cutils.h convention). Each accesses
# `width` bytes at its FIRST argument, a `buf + idx` pointer — the classic binary-parser
# OOB when `idx + width` is not proven within the buffer (`get_u32(bc_buf + pos + 1)` with
# only `pos < bc_len`). Modelled as an ikIndex on `idx` with the highest byte `idx + width-1`
# so the existing bound check requires `idx + width - 1 < size`. get/put are symmetric (a
# read OOB and a write OOB have the same bound); the width is the byte count.
const readWidthFn = {
  "get_u8": 1, "get_u16": 2, "get_u32": 4, "get_u64": 8,
  "get_i8": 1, "get_i16": 2, "get_i32": 4, "get_i64": 8,
  "put_u8": 1, "put_u16": 2, "put_u32": 4, "put_u64": 8,
  "put_i8": 1, "put_i16": 2, "put_i32": 4, "put_i64": 8,
}.toTable

proc lockKeyOf(ctx: Ctx, arg: CXCursor): tuple[key, disp, cls, base: string] =
  ## The identity of a lock named by an acquire/release argument: `&s->lock` -> the `s->lock`
  ## field-path key, `&g` / `g` -> the variable key. Returns ("","","","") if not a simple lock ref.
  ## `cls`/`base` are populated ONLY for a FIELD-instance lock carrying an `@lock_class` (its class
  ## name + the base variable's USR) — the v3 stage-3 inputs for the same-class canonical-order check.
  ## A class-keyed global / pointer alias leaves them empty (those collide by key, not by instance).
  var e = unwrap(arg)
  if clang_getCursorKind(e) == ckUnaryOperator and ctx.firstTokenSpelling(e) == "&":
    let kids = collectChildren(e)
    if kids.len >= 1: e = unwrap(kids[0])
  if clang_getCursorKind(e) == ckMemberRefExpr:
    let (fk, fd) = fieldPath(e)
    if fk.len > 0:
      let cls = ctx.fieldClass.getOrDefault(referencedUsr(e), "")  # the lock field's declared class
      var base = ""
      if cls.len > 0:
        let kids = collectChildren(e)                    # the base variable (`a` of `a->lock`)
        if kids.len >= 1 and clang_getCursorKind(unwrap(kids[0])) == ckDeclRefExpr:
          base = referencedUsr(unwrap(kids[0]))
      return (fk, fd, cls, base)
  elif clang_getCursorKind(e) == ckDeclRefExpr:
    let u = referencedUsr(e)
    if u in ctx.varClass: return (ctx.varClass[u], ctx.varClass[u], "", "")  # classed global: key by class
    if u in ctx.lockAliasClass:                          # a verified pointer alias of a classed lock
      return (ctx.lockAliasClass[u], ctx.lockAliasClass[u], "", "")
    return (u, spelling(e), "", "")
  ("", "", "", "")

proc requiredLockSink(call: CXCursor, reqExpr: string): tuple[disp, key: string] =
  ## Resolve a `@requires_lock` operand at a CALL SITE. A bare name (`g_lock`) is a global /
  ## file-scope lock -> (name, "") matched by display. A `param->field` form is mapped through
  ## the callee's parameter to THIS call's argument and keyed in the CALLER's space:
  ## `@requires_lock(s->lock)` + `helper(x)` -> (`x->lock`, `<x-USR>::lock`), the same key the
  ## caller's held-set uses for `x->lock`. Unresolvable (param unnamed / arg not a plain var) ->
  ## (reqExpr, "") which matches no held lock = a sound refusal (default-red).
  if "->" notin reqExpr: return (reqExpr, "")
  let parts = reqExpr.split("->")
  if parts.len != 2: return (reqExpr, "")
  let pname = parts[0].strip
  let field = parts[1].strip
  var idx = -1                                   # the callee parameter index named `pname`
  var i = 0
  for k in collectChildren(clang_getCursorReferenced(call)):
    if clang_getCursorKind(k) == ckParmDecl:
      if spelling(k) == pname: idx = i; break
      inc i
  if idx < 0: return (reqExpr, "")
  let kids = collectChildren(call)               # kids[0] = callee ref; args from kids[1]
  if idx + 1 >= kids.len: return (reqExpr, "")
  let arg = unwrap(kids[idx + 1])
  if clang_getCursorKind(arg) == ckDeclRefExpr:
    return (spelling(arg) & "->" & field, referencedUsr(arg) & "::" & field)
  (reqExpr, "")

proc splitBufOff(ctx: Ctx, c: CXCursor, accOff: int):
    tuple[ok: bool, base, idx: CXCursor, idxKey, idxDisp: string, idxOff: int] =
  ## Decompose a pointer expression `buf + idx` (with any constant addends) into its
  ## BUFFER base and the integer INDEX linear form. Constants fold into `accOff`; the
  ## pointer-typed operand is the base and the integer-typed operand the index. Handles
  ## `buf + pos`, `buf + pos + k`, `buf + (pos + k)`. Returns ok=false for shapes it can't
  ## split (two pointers, a product, a non-linear index) — sound: no sink, stays RED elsewhere.
  let u = unwrap(c)
  if clang_getCursorKind(u) == ckBinaryOperator and ctx.binOperator(u) in ["+", "-"]:
    let op = ctx.binOperator(u)
    let kids = collectChildren(u)
    if kids.len == 2:
      let l = unwrap(kids[0]); let r = unwrap(kids[1])
      let lc = constIntValue(l); let rc = constIntValue(r)
      if rc.known: return ctx.splitBufOff(l, accOff + (if op == "+": int(rc.value) else: -int(rc.value)))
      if op == "+" and lc.known: return ctx.splitBufOff(r, accOff + int(lc.value))
      if op == "+":                      # pointer-side + integer-index-side
        if isIntegerType(r) and not isIntegerType(l):
          let ri = ctx.parseLinear(r)
          if ri.ok and ri.key.len > 0: return (true, l, r, ri.key, ri.disp, accOff + ri.off)
        elif isIntegerType(l) and not isIntegerType(r):
          let li = ctx.parseLinear(l)
          if li.ok and li.key.len > 0: return (true, r, l, li.key, li.disp, accOff + li.off)
    return (false, u, u, "", "", 0)
  (true, u, u, "", "", accOff)          # leaf: the buffer itself, only a constant offset

proc lowerCallCore(ctx: var Ctx, call: CXCursor, line: int, outp: var seq[Stmt]) =
  # A member call resolves its contracts by the CLASS::method the object dispatches to: the
  # class it was locally constructed as when known (dynType — a virtual call through a base
  # pointer / reference devirtualised by the construction in view), else the static class of
  # the referenced method. Used only when such a qualified contract exists; the plain name
  # keeps the deallocator / lock / libc vocabulary working.
  let callee = block:
    let r = clang_getCursorReferenced(call)
    var q = ""
    if clang_getCursorKind(r) == ckCXXMethod:
      var cls = spelling(clang_getCursorSemanticParent(r))
      let mc = memberCallOn(call)
      if mc.has and mc.key in ctx.dynType: cls = ctx.dynType[mc.key]
      q = cls & "::" & spelling(call)
    if q.len > 0 and (ctx.argContracts.hasKey(q) or ctx.bodyContracts.hasKey(q) or
                      ctx.returnContracts.hasKey(q) or q in ctx.nothrowFuncs or
                      ctx.ownsOut.hasKey(q)): q
    else: ctx.effectiveCallee(call)
  # Assignment to a CLASS-typed owner (`y = std::move(x)` / `y = T(...)`) is not a BinaryOperator
  # in C++ — it is a call to `operator=`, which libclang reports as a CallExpr spelled
  # "operator=" whose first child is the LHS and last child the RHS. Lowered as a plain call, the LHS
  # owner looked like an escape into an uncontracted callee. Instead: the RHS's moved-from
  # variables are moved out (later use = USE_AFTER_MOVE), and the LHS owner takes ownership
  # afresh — its previous resource is released by the move-assignment / destructor (never a
  # leak), which is exactly the RAII guarantee `@raii` / unique_ptr declare.
  block lambdaCall:
    # `v()` on a local bound to a lambda, or an immediately-invoked `[..]{..}()`: THIS is where
    # the body runs. Lowering it at the definition instead (the old behaviour) both invented a
    # release that had not happened and hid a real one — calling a cleanup lambda twice reported
    # nothing at all. Splice the stored body here; each call runs it again.
    if spelling(call) == "operator()":
      let ok = collectChildren(call)
      if ok.len >= 1:
        let obj = unwrap(ok[0])
        if clang_getCursorKind(obj) == ckDeclRefExpr and referencedUsr(obj) in ctx.lambdaBodies:
          for st in ctx.lambdaBodies[referencedUsr(obj)]: outp.add relined(st, line)
          return
        if clang_getCursorKind(obj) == ckLambdaExpr:
          let lb = collectChildren(obj)
          if lb.len >= 1:
            for st in ctx.lowerBody(@[lb[^1]]): outp.add st
          return
  if callee == "operator=":
    let ok = collectChildren(call)
    if ok.len >= 2:
      # children: [LHS, (callee ref — present for a library class such as unique_ptr,
      # absent for a defaulted user move-assignment), RHS] — the object FIRST, the value LAST.
      let lhs = ownerRef(ok[0])
      if lhs.has and lhs.key in ctx.raiiVars:
        let mvs = ctx.ownedOperandsIn(ok[^1])
        if mvs.len == 1 and ctx.raiiVars.getOrDefault(mvs[0].key, "") == ctx.raiiVars[lhs.key]:
          # `y = std::move(x)` between owners of the same class: y takes x's resource (its own
          # previous one is released by the move-assignment); only the handle x is moved-from.
          outp.add emit(ikRaiiMove, line, a = mvs[0].disp, b = lhs.disp, aKey = mvs[0].key, bKey = lhs.key)
          return
        for mv in mvs: ctx.moveOwner(mv.key, mv.disp, line, outp)
        outp.add emit(ikRaiiAlloc, line, a = lhs.disp, b = ctx.raiiVars[lhs.key], aKey = lhs.key)
        for mv in mvs:   # a raw handle the owner took: now a borrow of the owner (see lowerStmt)
          if mv.key notin ctx.raiiVars and mv.key notin ctx.structOwnerVars and
             ctx.tracked.getOrDefault(mv.key, false):
            outp.add emit(ikInterior, line, a = mv.disp, b = lhs.disp, aKey = mv.key, bKey = lhs.key)
        return
      if lhs.has and lhs.key in ctx.structOwnerVars:
        # whole-struct assignment `g = std::move(h)`: every owner field of the source moves out
        # and every OWNED field of the target is owned afresh (its old resource is released by
        # the move-assignment / destructor). Borrowed fields (a `Holder&` parameter) stay borrows.
        let mvs = ctx.ownedOperandsIn(ok[^1])
        let dst = ctx.structOwnerVars[lhs.key]
        if mvs.len == 1 and mvs[0].key in ctx.structOwnerVars and
           ctx.structOwnerVars[mvs[0].key].len == dst.len:
          # `g = std::move(h)`: field-wise handle move into g's OWNED fields; a borrowed field
          # (a `Holder&` parameter) just sees the source moved out, as before.
          let src = ctx.structOwnerVars[mvs[0].key]
          for i, f in dst:
            if f.key in ctx.raiiVars:
              outp.add emit(ikRaiiMove, line, a = src[i].disp, b = f.disp, aKey = src[i].key, bKey = f.key)
            else:
              ctx.moveOwner(src[i].key, src[i].disp, line, outp)
          return
        for mv in mvs: ctx.moveOwner(mv.key, mv.disp, line, outp)
        for f in dst:
          if f.key in ctx.raiiVars:
            outp.add emit(ikRaiiAlloc, line, a = f.disp, b = ctx.raiiVars[f.key], aKey = f.key)
        return
  # A DEREFERENCING member operator on an owner — `*up` / `up->f` / `up[i]` — is a CallExpr
  # spelled "operator*" / "operator->" / "operator[]" whose children are the OBJECT and the
  # operator ref (object FIRST, unlike a normal call). Lowered as a call, the object read as a
  # function-pointer variable (ikIndirectCall — inert for the temporal engine), so dereferencing
  # a moved-from unique_ptr was never a USE. It is one. Only the dereferencing operators count:
  # `operator bool` / `==` / `!=` on a moved-from owner are well-defined C++ (it is null), so
  # treating them as uses would be a false RED.
  if callee == "operator*" or callee == "operator->" or callee == "operator[]":
    for ch in collectChildren(call):
      let obj = ownerRef(ch)
      if obj.has and ctx.tracked.getOrDefault(obj.key, false):
        outp.add emit(ikUse, line, a = obj.disp, aKey = obj.key)
        return
  let isMove = line in ctx.moveLines
  # CONCURRENCY (v3 stage 4): a call THROUGH a function pointer. Resolve it against the pointer's
  # declared `@calls(...)` targets so the lock-balance pass can gate it — an undeclared pointer held
  # while locked is refused; declared targets contribute their `@acquires` locks to the order check.
  let ind = indirectFnptr(call)
  if ind.isIndirect:
    let targets = ctx.fnptrTargets.getOrDefault(ind.usr)
    var acqDisps: seq[string]                          # the locks the declared targets are to acquire
    for t in targets:
      for e in ctx.acquiresExprs.getOrDefault(t, @[]): acqDisps.add e
    outp.add emit(ikIndirectCall, line, a = ind.disp,
                  aKey = (if targets.len > 0: "T" else: ""), b = acqDisps.join(";"))
  # CONCURRENCY: a recognised lock acquire / release (`pthread_mutex_lock(&m)` / unlock)
  # toggles the lock named by its first argument in the flow-sensitive held-set.
  if callee in lockAcquirers or callee in lockReleasers:
    let lkids = collectChildren(call)
    if lkids.len >= 2:                              # lkids[0] = callee ref, lkids[1] = &lock
      let (lk, ld, lc, lb) = ctx.lockKeyOf(lkids[1])
      if lk.len > 0:
        # b = the lock's @lock_class (field-instance only), bKey = its base var — the same-class
        # canonical-order inputs; empty for class-keyed globals / aliases.
        outp.add emit((if callee in lockAcquirers: ikLockAcquire else: ikLockRelease),
                      line, a = ld, aKey = lk, b = lc, bKey = lb)
  # CONCURRENCY precondition: a call to a callee declared `@requires_lock(m)` — the lock-balance
  # pass verifies `m` is held here. Global locks match by display; `param->field` locks resolve
  # through this call's argument to a key in the caller's held-set (struct-based locking).
  for reqLock in ctx.requiresLockByCallee.getOrDefault(callee, @[]):
    let (disp, key) = requiredLockSink(call, reqLock)
    outp.add emit(ikRequiredLockCall, line, a = callee, b = disp, bKey = key)
  # CONCURRENCY cross-function lock flow: a callee declared `@acquires(C)` leaves C held in the
  # CALLER after the call; `@releases(C)` requires C held at entry and drops it. Modelling that in
  # the caller's held-set makes the within-function lock-order / double-lock / unlock checks span
  # the call boundary — cross-function AB-BA falls out of the existing LOCK_ORDER_VIOLATION, with
  # no new check. `param->field` locks resolve to the SAME key direct acquires use (struct-based
  # locking); a global (empty key) is skipped here — its direct acquire keys by USR, so emitting a
  # display-keyed sink would mismatch (the global key-unification is a separate follow-up).
  for acq in ctx.acquiresExprs.getOrDefault(callee, @[]):
    var (disp, key) = requiredLockSink(call, acq)
    if key.len == 0 and acq in ctx.lockClasses: (disp, key) = (acq, acq)  # `@acquires(X)` class
    if key.len > 0: outp.add emit(ikLockAcquire, line, a = disp, aKey = key)
  for rel in ctx.releasesExprs.getOrDefault(callee, @[]):
    var (disp, key) = requiredLockSink(call, rel)
    if key.len == 0 and rel in ctx.lockClasses: (disp, key) = (rel, rel)
    if key.len > 0: outp.add emit(ikLockRelease, line, a = disp, aKey = key)
  # SPATIAL size sink: if this callee takes a length argument and it is an untrusted
  # scalar parameter with no bound on the path, that is a buffer-overflow risk.
  if callee in sizeArgPos:
    let kids = collectChildren(call)
    let pos = sizeArgPos[callee] + 1            # +1: kids[0] is the callee reference
    if pos < kids.len:
      let lin = ctx.parseLinear(kids[pos])           # the length, possibly `len ± k`
      if lin.ok and lin.key.len > 0:
        var sz = -1                         # the destination buffer's size, if a fixed array
        var bsym = ""                       # or its symbolic allocation count, if malloc'd
        let bp = bufArgPos.getOrDefault(callee, -1) + 1   # +1: kids[0] is the callee ref
        if bp >= 1 and bp < kids.len:
          let bufc = unwrap(kids[bp])
          if clang_getCursorKind(bufc) == ckDeclRefExpr:
            sz = fixedArraySize(bufc)
            if sz < 0: bsym = ctx.bufSizeSym.getOrDefault(referencedUsr(bufc)).symKey
          elif clang_getCursorKind(bufc) == ckMemberRefExpr:
            sz = fixedArraySize(bufc)    # a fixed-size array member `memcpy(s->buf, …)`
        let uns = isUnsignedInteger(unwrap(kids[pos]))   # unsigned length: >= 0 by type
        outp.add emit(ikIndex, line, a = lin.disp, b = "size",
                      aKey = lin.key, off = sz, off2 = lin.off, bKey = bsym,
                      cKey = (if uns: "u" else: ""))
        # SPATIAL source-read sink: the copy also READS `len` bytes from the source buffer. When
        # the source's size is DECLARED, check the read stays within it (the memcpy SOURCE
        # over-read — Heartbleed). Only for a known source size; an unsized source is not flagged.
        let sp = srcArgPos.getOrDefault(callee, -1) + 1
        if sp >= 1 and sp < kids.len:
          var ssz = -1
          var ssym = ""
          let srcc = unwrap(kids[sp])
          if clang_getCursorKind(srcc) == ckDeclRefExpr:
            ssz = fixedArraySize(srcc)
            if ssz < 0: ssym = ctx.bufSizeSym.getOrDefault(referencedUsr(srcc)).symKey
          elif clang_getCursorKind(srcc) == ckMemberRefExpr:
            ssz = fixedArraySize(srcc)
          if ssz >= 0 or ssym.len > 0:            # only when the source size is known
            outp.add emit(ikIndex, line, a = lin.disp, b = "rsize",   # rsize = a READ length
                          aKey = lin.key, off = ssz, off2 = lin.off, bKey = ssym,
                          cKey = (if uns: "u" else: ""))
  # SPATIAL fixed-width read/write sink: `get_u32(buf + idx)` accesses `width` bytes at
  # `buf + idx`. The highest byte is `idx + width - 1`, which must be within the buffer —
  # emitted as an ikIndex on `idx` with that offset so the bound check requires it < size.
  if callee in readWidthFn:
    let kids = collectChildren(call)
    if kids.len >= 2:
      let width = readWidthFn[callee]
      let sp = ctx.splitBufOff(unwrap(kids[1]), 0)
      if sp.ok and sp.idxKey.len > 0:
        var sz = -1                         # the buffer's fixed size, if known
        var bsym = ""                       # or its symbolic allocation count / @counted_by size
        var bsymOff = 0
        if clang_getCursorKind(sp.base) == ckDeclRefExpr:
          sz = fixedArraySize(sp.base)
          if sz < 0:
            let s = ctx.bufSizeSym.getOrDefault(referencedUsr(sp.base))
            bsym = s.symKey; bsymOff = s.off
        elif clang_getCursorKind(sp.base) == ckMemberRefExpr:
          sz = fixedArraySize(sp.base)
          if sz < 0:
            let (fk, _) = fieldPath(sp.base)
            if fk.len > 0:
              let s = ctx.bufSizeSym.getOrDefault(fk)
              bsym = s.symKey; bsymOff = s.off
        let uns = isUnsignedInteger(sp.idx)
        outp.add emit(ikIndex, line, a = sp.idxDisp, aKey = sp.idxKey,
                      off = sz, off2 = sp.idxOff + width - 1, bKey = bsym,
                      cKey = (if uns: "u" else: ""), off3 = bsymOff)
  # Track how this call participates in the ownership flow (for the per-flow /
  # trusted-frontier coverage views). Recorded once per call, taking the strongest
  # kind seen across its tracked pointer args (uncontracted > contracted > known).
  var edgeKind = ckKnown
  var edgeSeen = false
  proc note(k: CallKind) =
    edgeSeen = true
    if ord(k) > ord(edgeKind): edgeKind = k
  # GLOBAL free effect (`@frees(g)` on the callee, g a file-scope global): this call releases the
  # global's origin. Emit a free of the global HERE when it currently carries an obligation in this
  # function (`g = data` aliased it) — so `free(data); g = data; sink()` is a DOUBLE_FREE across the
  # static-global channel (Juliet _45), modularly. Guarded by ctx.tracked so a call where the global
  # holds nothing here emits nothing (no spurious UNKNOWN_VAR).
  for g in ctx.funcFreesGlobal.getOrDefault(callee, @[]):
    if ctx.tracked.getOrDefault(g.usr, false):
      outp.add emit(ikFree, line, a = g.name, aKey = g.usr); note(ckContracted)
  # A member call `obj.method(...)` is a CallExpr whose callee child is a MemberRefExpr on
  # `obj` — so `obj` is NOT an argument and was never a USE. For a tracked owner (an `@raii`
  # local) that hid every use-after-move (`l0.read()` after `std::move(l0)`). Emit the use.
  block memberUse:
    let mk = collectChildren(call)
    if mk.len >= 1 and clang_getCursorKind(unwrap(mk[0])) == ckMemberRefExpr:
      let mkids = collectChildren(unwrap(mk[0]))
      if mkids.len >= 1:
        let obj = ownerRef(mkids[0])
        if obj.has and ctx.tracked.getOrDefault(obj.key, false):
          outp.add emit(ikUse, line, a = obj.disp, aKey = obj.key)
  # `up.reset(p)`: the owner TAKES a tracked raw p (its obligation is discharged into the owner,
  # whose destructor releases it) — freeing p afterwards is FREE_AFTER_MOVE. Handled here in
  # full so the positional arg loop does not also read p as passed to an uncontracted "reset".
  block ownerReset:
    let mc = memberCallOn(call)
    if mc.has and mc.meth == "reset" and mc.key in ctx.raiiVars:
      # `up.reset(p)` / `up.reset()`: the owner RELEASES its current resource (a borrow taken
      # from it — `q = up.get()` — dangles: its use is USE_AFTER_FREE) and, with an argument,
      # takes p — moved out of its own origin and re-pointed as a borrow of the owner.
      outp.add emit(ikUse, line, a = mc.disp, aKey = mc.key)
      outp.add emit(ikFree, line, a = mc.disp, aKey = mc.key)
      outp.add emit(ikRaiiAlloc, line, a = mc.disp, b = ctx.raiiVars[mc.key], aKey = mc.key)
      let rk = collectChildren(call)
      for ai in 1 ..< rk.len:
        let arg = ownerRef(rk[ai])
        if not arg.has: continue
        ctx.moveOwner(arg.key, arg.disp, line, outp)
        if arg.key notin ctx.raiiVars and arg.key notin ctx.structOwnerVars and
           ctx.tracked.getOrDefault(arg.key, false):
          outp.add emit(ikInterior, line, a = arg.disp, b = mc.disp, aKey = arg.key, bKey = mc.key)
      return
  block containerStore:
    # `v.push_back(p)` / `v.insert(it, n, p)` on a STANDARD container: the container now holds
    # the owned pointer — its obligation moves to the container's element slot. A container of
    # raw pointers frees nothing when it dies, so a local one still holding it at scope exit is
    # a LEAK; passing the container on carries the element across that boundary (the struct
    # channel), and reading an element back aliases the slot.
    if spelling(call) in containerAdders:
      let mk = collectChildren(call)
      if mk.len >= 1 and clang_getCursorKind(unwrap(mk[0])) == ckMemberRefExpr:
        let objs = collectChildren(unwrap(mk[0]))
        if objs.len >= 1:
          let slot = ctx.containerSlot(objs[0])
          let base = ownerRef(objs[0])
          if slot.has:
            var stored = false
            for ai in 1 ..< mk.len:
              let a = unwrap(mk[ai])
              if clang_getCursorKind(a) != ckDeclRefExpr: continue
              let k = referencedUsr(a)
              if not ctx.tracked.getOrDefault(k, false): continue
              let isLocal = base.key in ctx.localVars
              outp.add emit(ikFieldStore, line, a = spelling(a), aKey = k,
                            b = slot.disp, bKey = slot.key,
                            cKey = base.key, off = (if isLocal: 1 else: 0))
              ctx.tracked[slot.key] = true
              ctx.slotRes[slot.key] = ctx.resourceFor(spelling(a), line)
              if isLocal: ctx.fieldBaseVars.incl base.key
              stored = true
            if stored: return
  # children: [callee-ref, arg0, arg1, ...] — index args positionally so an
  # `@frees(N)` contract maps to the right argument even past non-pointer args.
  let kids = collectChildren(call)
  for ai in 1 ..< kids.len:
    var a = unwrap(kids[ai])
    # declared arg effect, if any — through a function pointer, the effect its declared
    # `@calls` targets unanimously give (the pointer's own name has no contract)
    let ci = (if ind.isIndirect: ctx.indirectArgContract(ind.usr, ai - 1)
              else: ctx.argContract(callee, ai - 1))
    # `std::move(v)` passed directly: `v` is moved out here (later use = USE_AFTER_MOVE, a
    # second move = DOUBLE_MOVE). Only a tracked (e.g. `@raii`) operand is moved.
    block directMove:
      let sm = stdMoveOperand(a)
      if sm.has and (sm.key in ctx.structOwnerVars or ctx.tracked.getOrDefault(sm.key, false)):
        ctx.moveOwner(sm.key, sm.disp, line, outp); note(ckContracted)
        continue
    if clang_getCursorKind(a) == ckCallExpr and
       clang_getCursorKind(clang_getCursorReferenced(a)) == ckConstructor:
      # A by-value class argument materialised from an rvalue — `consume(std::move(l0))` — is
      # wrapped in a move-CONSTRUCTOR call. libclang reports it as a CallExpr spelled with the
      # class name whose children are ALL arguments (no callee-ref child), so the positional
      # loop, which skips child 0 as the callee, never saw its only argument: the `std::move`
      # inside stayed invisible and the owner read as still "owned" after the move. Look through
      # the wrapper: each `std::move(v)` argument moves `v` out here.
      var moved = false
      for ck in collectChildren(a):
        let sm = stdMoveOperand(ck)
        if sm.has and (sm.key in ctx.structOwnerVars or ctx.tracked.getOrDefault(sm.key, false)):
          ctx.moveOwner(sm.key, sm.disp, line, outp); note(ckContracted)
          moved = true
      if moved: continue
      # A by-value COPY of an object (`sink(v)` where the parameter is `std::vector<T> v`) is the
      # same wrapper around a plain lvalue: the contract on that parameter applies to the object
      # copied from — its element slot / owner fields cross the boundary, exactly as for a
      # by-value struct argument. Look through to it and let the ordinary handling below run.
      let ctorArgs = collectChildren(a)
      if ctorArgs.len == 1:
        let inner = unwrap(ctorArgs[0])
        if clang_getCursorKind(inner) == ckDeclRefExpr or clang_getCursorKind(inner) == ckMemberRefExpr:
          a = inner
    # Every ACCESSOR contract on this argument beyond the one the ladder applies (a destructor
    # that declares the node AND its owned fields). Each binds the caller's matching slot, so the
    # release the callee performs discharges the obligation here rather than leaving it to read
    # as a leak at the call that satisfies it.
    if not ind.isIndirect and clang_getCursorKind(a) == ckDeclRefExpr:
      let argKey = referencedUsr(a)
      for (instr, accessor) in ctx.extraAccessorContracts(callee, ai - 1):
        let slotKey = argKey & "::" & accessor
        if not ctx.tracked.getOrDefault(slotKey, false): continue
        let slotDisp = spelling(a) & (if accessor == "*": "" else:
                                      (if accessor.startsWith("["): "" else: "->")) & accessor
        outp.add emit(instr, line, a = (if accessor == "*": "*" & spelling(a) else: slotDisp),
                      aKey = slotKey)
    # LIBRARY SEAM as an argument. `f(up.get())` passes a BORROW: an interior alias of the owner —
    # a callee that frees it frees what the owner still releases (FREE_INTERIOR), anything else
    # is a use. `f(up.release())` passes OWNERSHIP: the owner relinquishes and the raw resource
    # needs a receiver that frees / moves it — a borrower leaves it unowned (LEAK), an
    # uncontracted callee is the usual default-red boundary. Both use a synthetic key for the
    # temporary, so the ordinary contract dispatch applies unchanged.
    block seamArg:
      let mc = memberCallOn(a)
      if mc.has and mc.key in ctx.raiiVars:
        let ok = mc.key
        let od = mc.disp
        outp.add emit(ikUse, line, a = od, aKey = ok)   # the seam USES the handle (moved = UAM)
        if mc.meth == "get":
          let syn = ok & "::get()"
          outp.add emit(ikInterior, line, a = od & ".get()", b = od, aKey = syn, bKey = ok)
          if (ci.has and ci.instr == ikFree) or callee in ctx.deallocators:
            outp.add emit(ikFree, line, a = od & ".get()", aKey = syn); note(ckContracted)
          else:
            note(ckKnown)
          continue
        if mc.meth == "release":
          outp.add emit(ikMove, line, a = od, aKey = ok)
          let syn = ok & "::release()"
          let disp = od & ".release()"
          ctx.ensureReleasedResource()
          outp.add emit(ikAlloc, line, a = disp, b = releasedResName, aKey = syn)
          if ci.has and ci.instr == ikFree:
            outp.add emit(ikFree, line, a = disp, aKey = syn); note(ckContracted)
          elif ci.has and ci.instr == ikMove:
            outp.add emit(ikMove, line, a = disp, aKey = syn); note(ckContracted)
          elif ci.has and ci.instr == ikUse:
            outp.add emit(ikUse, line, a = disp, aKey = syn); note(ckContracted)
          elif callee in ctx.deallocators:
            outp.add emit(ikFree, line, a = disp, b = callee, aKey = syn); note(ckKnown)
          else:
            outp.add emit(ikEscapeCall, line, a = disp, b = callee, aKey = syn,
                          bKey = ctx.calleeParamName(callee, ai - 1), off = ai - 1); note(ckUncontracted)
          continue
    if clang_getCursorKind(a) == ckCallExpr:
      # a nested call argument, e.g. `print(eval(e))` — analyze it too, so the
      # inner call's own argument uses / contracts aren't lost.
      ctx.lowerCall(a, startLine(a), outp)
      continue
    if clang_getCursorKind(a) == ckMemberRefExpr or
       (clang_getCursorKind(a) == ckArraySubscriptExpr and ctx.tracked.getOrDefault(fieldPath(a).key, false)):
      # a one-level field path `base->field` (or a tracked constant element `arr[2]`) argument: free / move / use it through
      # the tracked field path (double-free / UAF detection through the field).
      let (fk, fd) = fieldPath(a)
      if fk.len > 0 and ctx.tracked.getOrDefault(fk, false):
        if ci.has and ci.instr == ikFree: outp.add emit(ikFree, line, a = fd, aKey = fk)
        elif callee in ctx.deallocators: outp.add emit(ikFree, line, a = fd, b = callee, aKey = fk)
        elif ci.has and ci.instr == ikMove: outp.add emit(ikMove, line, a = fd, aKey = fk)
        elif ci.has and ci.instr == ikAdopt: outp.add emit(ikAdopt, line, a = fd, aKey = fk)
        else: outp.add emit(ikUse, line, a = fd, aKey = fk)
      elif (ci.has and ci.instr == ikFree) or (callee in ctx.deallocators and kids.len == 2):
        # A RELEASE through a field path nothing here owns — `free(p->buf)` on a parameter, the
        # field form of UNCONTRACTED_RELEASE. It used to fall out of this branch silently, so a
        # function that frees part of a struct it was handed said nothing at all. Declaring
        # `@frees(p.buf)` seeds the slot above and makes the release checkable.
        #
        # Which ARGUMENT a release frees is only known from a `@frees` contract or from the
        # one-argument shape (`free(x)`, `DestroyFoo(x)`). A multi-argument deallocator —
        # zlib's `zfree(opaque, address)` — also passes a context pointer that it does NOT
        # free, and the field path of one of those is not a release to report. Those stay on
        # the tracked-origin path above, which tells the two apart by what the caller owns.
        outp.add emit(ikUnaccountedFree, line, a = fd); note(ckKnown)
      continue
    let co = (if ind.isIndirect: (has: false, accessor: "") else: ctx.argContractOf(callee, ai - 1, ikOwnsOut))
    if co.has:
      # `source(&data)` with `@owns(*p)`, or `source(data)` with `@owns(p)` on a `T*&` reference
      # parameter: the callee allocates a fresh owned object INTO the argument — the caller now
      # owns `data`, as if it had called the allocator itself (a declared resource via `@mem`
      # above the call, else default-red UNKNOWN_RESOURCE). The out-parameter SOURCE form.
      var target = a
      var shape = false
      if co.accessor == "*":
        if clang_getCursorKind(a) == ckUnaryOperator and ctx.firstTokenSpelling(a) == "&":
          let inner = collectChildren(a)
          if inner.len >= 1: target = unwrap(inner[0]); shape = true
        elif clang_getCursorKind(a) == ckDeclRefExpr and referencedUsr(a) in ctx.addrOf:
          # `source(pp)` where `pp = &data` (addrOf): the pointee is `data` (Juliet 64: `void *`)
          let at = ctx.addrOf[referencedUsr(a)]
          outp.add emit(ikAlloc, line, a = at.disp, b = ctx.resourceFor(at.disp, line), aKey = at.key)
          ctx.tracked[at.key] = true
          if ctx.argContractOf(callee, ai - 1, ikFree).has and ctx.argContractOf(callee, ai - 1, ikFree).accessor == "*":
            outp.add emit(ikFree, line, a = at.disp, aKey = at.key)
          note(ckContracted)
          continue
      elif co.accessor.len == 0:
        shape = true
      if shape and clang_getCursorKind(target) == ckDeclRefExpr:
        let tk = referencedUsr(target)
        # a throwing source assigns nothing: its unwinding exit precedes the new obligation
        if not ctx.throwEmitted and ctx.mayThrow(call):
          outp.add emit(ikMayThrow, line, a = spelling(call)); ctx.throwEmitted = true
        outp.add emit(ikAlloc, line, a = spelling(target),
                      b = ctx.resourceFor(spelling(target), line), aKey = tk)
        ctx.tracked[tk] = true
        # ... and ALSO declared `@frees` on the same parameter: the source releases what it
        # handed out before returning — the caller receives a dangling pointer (a use of it
        # is USE_AFTER_FREE, a free DOUBLE_FREE).
        if ctx.argContractOf(callee, ai - 1, ikFree).accessor == co.accessor and
           ctx.argContractOf(callee, ai - 1, ikFree).has:
          outp.add emit(ikFree, line, a = spelling(target), aKey = tk)
        note(ckContracted)
        continue
    if ci.has and ci.instr in {ikFree, ikMove, ikUse} and ci.accessor == "*" and
       clang_getCursorKind(a) == ckUnaryOperator and ctx.firstTokenSpelling(a) == "&":
      # `sink(&data)` where `sink` declares `@frees(*p)` / `@moves(*p)` / `@borrows(*p)`: the
      # callee acts on the POINTEE, so the `&data` argument frees / moves / USES `data` ITSELF
      # (the cross-file `T**` source/sink form). A later/earlier free of `data` is then a
      # DOUBLE_FREE, a read through a `@borrows(*p)` reader after `free(data)` is
      # USE_AFTER_FREE — modular detection across the boundary, no whole-program pass. Only
      # fires for `&<tracked var>`; anything else falls through.
      let inner = collectChildren(a)
      if inner.len >= 1 and clang_getCursorKind(unwrap(inner[0])) == ckDeclRefExpr:
        let iv = unwrap(inner[0])
        let vk = referencedUsr(iv)
        if ctx.tracked.getOrDefault(vk, false):
          outp.add emit(ci.instr, line, a = spelling(iv), aKey = vk); note(ckContracted)
          continue
    if ci.has and ci.instr in {ikFree, ikMove, ikUse} and ci.accessor == "*" and
       clang_getCursorKind(a) == ckDeclRefExpr and referencedUsr(a) in ctx.addrOf:
      # `sink(pp)` where `pp = &data` was recorded (addrOf) — the same pointee form through a
      # pointer VARIABLE (Juliet 64: `void *dataVoidPtr = &data; sink(dataVoidPtr)`)
      let at = ctx.addrOf[referencedUsr(a)]
      if ctx.tracked.getOrDefault(at.key, false):
        outp.add emit(ci.instr, line, a = at.disp, aKey = at.key); note(ckContracted)
        continue
    if ci.has and ci.instr == ikFree and ci.accessor.len > 0 and ci.accessor != "*" and
       clang_getCursorKind(a) == ckDeclRefExpr:
      # `sink(myStruct)` where `sink` declares `@frees(p.f)`: the callee frees the FIELD `p.f`, so
      # the struct-var argument transfers ownership of `arg.f`. Free the caller's field path
      # (`<argUSR>::f`) — which `myStruct.f = data` aliased to data's origin (#2) — for modular
      # cross-file struct source/sink detection. Fires only when that field path is tracked here.
      let fk = referencedUsr(a) & "::" & ci.accessor
      if ctx.tracked.getOrDefault(fk, false):
        outp.add emit(ikFree, line, a = spelling(a) & (if ci.accessor.startsWith("["): "" else: ".") & ci.accessor,
                      aKey = fk); note(ckContracted)
        continue
    block argThroughAddr:
      let at = ctx.addrStoreTarget(a)   # `sink(*dataPtr)` with `dataPtr = &data`: the arg is `data`
      if at.has and ctx.tracked.getOrDefault(at.key, false):
        if (ci.has and ci.instr == ikFree) or callee in ctx.deallocators:
          outp.add emit(ikFree, line, a = at.disp, aKey = at.key); note(ckContracted)
        elif ci.has and ci.instr == ikMove:
          outp.add emit(ikMove, line, a = at.disp, aKey = at.key); note(ckContracted)
        elif ci.has and ci.instr == ikAdopt:
          outp.add emit(ikAdopt, line, a = at.disp, aKey = at.key); note(ckContracted)
        else:
          outp.add emit(ikUse, line, a = at.disp, aKey = at.key); note(ckKnown)
        continue
    block argPointeeSlot:
      # `free(*dataPtr)` / `use(*dataPtr)` where the pointee slot carries a contract: the
      # release the `@frees(*dataPtr)` sink declares, written directly.
      let ps = ctx.pointeeSlot(a)
      if ps.key.len > 0 and ctx.tracked.getOrDefault(ps.key, false):
        if (ci.has and ci.instr == ikFree) or callee in ctx.deallocators:
          outp.add emit(ikFree, line, a = ps.disp, aKey = ps.key); note(ckContracted)
        elif ci.has and ci.instr == ikMove:
          outp.add emit(ikMove, line, a = ps.disp, aKey = ps.key); note(ckContracted)
        elif ci.has and ci.instr == ikAdopt:
          outp.add emit(ikAdopt, line, a = ps.disp, aKey = ps.key); note(ckContracted)
        else:
          outp.add emit(ikUse, line, a = ps.disp, aKey = ps.key); note(ckKnown)
        continue
    if clang_getCursorKind(a) != ckDeclRefExpr:
      # The freed argument is not a plain variable: `free(*dataPtr)` (release through
      # an out-parameter) / `free(arr[i])`. kenbi cannot bind it to a tracked origin,
      # so in covered scope it is an unaccounted release (default-red). A `free(NULL)`
      # / `free(0)` literal is NOT a release of a pointer we lost track of, so only an
      # actual deref / subscript fires (never a literal).
      let isRelease = (ci.has and ci.instr == ikFree) or callee in ctx.deallocators
      let isDeref = clang_getCursorKind(a) == ckUnaryOperator and ctx.firstTokenSpelling(a) == "*"
      let isSubscript = clang_getCursorKind(a) == ckArraySubscriptExpr
      if isRelease and (isDeref or isSubscript):
        var disp = "the freed expression"
        let inner = collectChildren(a)
        if inner.len >= 1 and clang_getCursorKind(unwrap(inner[0])) == ckDeclRefExpr:
          disp = (if isDeref: "*" else: "") & spelling(unwrap(inner[0]))
        outp.add emit(ikUnaccountedFree, line, a = disp); note(ckKnown)
      continue
    let nm = spelling(a)
    let key = referencedUsr(a)
    if key in ctx.lambdaMemOp:
      # the callee decides when (and how often) this lambda runs — its allocation / release
      # cannot be placed on any path here
      outp.add emit(ikUnsupportedConstruct, line, a = "lambda handed to '" & callee & "'")
      continue
    if not ctx.tracked.getOrDefault(key, false) and key in ctx.fieldBaseVars:
      # A STRUCT passed BY VALUE whose tracked field paths carry owned origins (`s.buf = data;
      # sink(s)` — the struct channel): every such field crosses the boundary. The contract on
      # the struct parameter applies to each — `@borrows(s)` a read, `@moves(s)` a move,
      # `@frees(s)` a release (`@frees(s.f)` for one field was handled above) — and NO contract
      # is the usual UNCONTRACTED_ESCAPE per field: the callee may take it (default-red, never a
      # silent hand-off of an owned field).
      var handled = false
      for fk, tr in ctx.tracked:
        if not tr or not fk.startsWith(key & "::"): continue
        let member = fk[key.len + 2 .. ^1]
        let fd = nm & (if member.startsWith("["): "" else: ".") & member
        if ci.has and ci.instr == ikUse:
          outp.add emit(ikUse, line, a = fd, aKey = fk); note(ckContracted)
        elif ci.has and ci.instr == ikMove:
          outp.add emit(ikMove, line, a = fd, aKey = fk); note(ckContracted)
        elif ci.has and ci.instr == ikAdopt:
          outp.add emit(ikAdopt, line, a = fd, aKey = fk); note(ckContracted)
        elif ci.has and ci.instr == ikFree:
          outp.add emit(ikFree, line, a = fd, aKey = fk); note(ckContracted)
        else:
          outp.add emit(ikEscapeCall, line, a = fd, b = callee, aKey = fk,
                        bKey = ctx.calleeParamName(callee, ai - 1), off = ai - 1)
          note(ckUncontracted)
        handled = true
      if handled: continue
    if not ctx.tracked.getOrDefault(key, false):
      # A non-tracked pointer being released. Two kinds, both default-red in covered
      # scope: an undeclared incoming parameter (UNCONTRACTED_RELEASE naming @frees /
      # @borrows), or an untracked LOCAL whose provenance kenbi cannot account for
      # (assigned from `*outparam` / a non-@owns factory) -> ikUnaccountedFree. Using /
      # passing either emits nothing (no ownership claim), so a pure reader/forwarder
      # stays non-memory-relevant; only the RELEASE is recorded.
      let isRelease = (ci.has and ci.instr == ikFree) or callee in ctx.deallocators
      if key in ctx.incomingPtrs:
        if ci.has and ci.instr == ikFree:
          outp.add emit(ikFree, line, a = nm, aKey = key); note(ckContracted)
        elif ci.has and ci.instr == ikMove:
          # a `@moves` sink takes ownership of this uncontracted param and will release it —
          # NOT a benign forward (that is only `@borrows` / a plain use). This function never
          # declared it owns the param, so handing it to a consumer is an unverifiable ownership
          # transfer: default-red UNCONTRACTED_MOVE (the engine's intake ladder, symmetric to
          # UNCONTRACTED_RELEASE on a free). Records it as an ownership edge so it is coverage-
          # relevant, like the free case.
          outp.add emit(ikMove, line, a = nm, aKey = key); note(ckContracted)
        elif ci.has and ci.instr == ikAdopt:
          outp.add emit(ikAdopt, line, a = nm, aKey = key); note(ckContracted)
        elif callee in ctx.deallocators:
          outp.add emit(ikFree, line, a = nm, b = callee, aKey = key); note(ckKnown)
      elif isRelease:
        outp.add emit(ikUnaccountedFree, line, a = nm, aKey = key); note(ckKnown)
      continue
    if ci.has and ci.instr == ikFree:
      # the callee's signature declares it frees this argument (b="" => the
      # deallocator-name check is skipped: the free happens inside the callee)
      outp.add emit(ikFree, line, a = nm, aKey = key)
      note(ckContracted)
    elif ci.has and ci.instr == ikMove:
      # `@moves`: the callee takes ownership (channel send / thread handoff) —
      # the arg is moved out, so using it afterwards is use-after-move.
      outp.add emit(ikMove, line, a = nm, aKey = key)
      note(ckContracted)
    elif ci.has and ci.instr == ikAdopt:
      # `@adopts`: a consumer takes over the RELEASE while the object stays valid — the
      # container hand-off. Reading the value afterwards is ordinary C, so this is not a move.
      outp.add emit(ikAdopt, line, a = nm, aKey = key)
      note(ckContracted)
    elif ci.has and ci.instr == ikUse:
      # `@borrows`: the callee declares it only borrows this arg — a safe use that
      # neither takes ownership nor escapes (so it is not an UNCONTRACTED_ESCAPE).
      outp.add emit(ikUse, line, a = nm, aKey = key)
      note(ckContracted)
    elif callee in ctx.deallocators:
      # a declared deallocator (or builtin free); carry the callee so the engine
      # can check it matches the resource's declared `free:`.
      outp.add emit(ikFree, line, a = nm, b = callee, aKey = key)
      note(ckKnown)
    elif isMove:
      outp.add emit(ikMove, line, a = nm, aKey = key)
      note(ckKnown)
    elif callee in knownBorrowFns:
      # a known-safe libc borrow (read / write / format) — a plain use.
      outp.add emit(ikUse, line, a = nm, aKey = key)
      note(ckKnown)
    else:
      # an UNCONTRACTED boundary: this callee declares no @frees / @borrows /
      # @moves contract and is not a known-safe borrow. Don't silently infer a
      # borrow — if the arg is owned here, the engine reports UNCONTRACTED_ESCAPE
      # (default-red) so the developer declares the contract / region / @unsafe.
      # Still carries the use semantics (use-after-free etc.) via ikEscapeCall.
      # bKey carries the callee's parameter name (which param needs a contract),
      # off carries its 0-based position, for a precise "where / what" message.
      # If the callee's VISIBLE body frees this arg, use ikEscapeCallFrees so the
      # engine can hint at a possible later double-free (still uncontracted = red).
      let visiblyFrees = (ai - 1) in ctx.bodyFreesParam.getOrDefault(callee)
      outp.add emit((if visiblyFrees: ikEscapeCallFrees else: ikEscapeCall),
                    line, a = nm, b = callee, aKey = key,
                    bKey = ctx.calleeParamName(callee, ai - 1), off = ai - 1)
      note(ckUncontracted)
  # Record one ownership-flow edge per call (only if it passed a tracked pointer).
  if edgeSeen:
    ctx.callEdges.add CallEdge(callee: callee, line: line, kind: edgeKind)

# --- null safety: deref detection + null-condition parsing ------------------

proc hasArrow(ctx: Ctx, c: CXCursor): bool =
  ## Does this member access use `->` (a pointer deref) rather than `.`?
  var toks: ptr CXToken
  var n: cuint
  clang_tokenize(ctx.tu, clang_getCursorExtent(c), addr toks, addr n)
  let arr = cast[ptr UncheckedArray[CXToken]](toks)
  for i in 0 ..< int(n):
    if $clang_getTokenSpelling(ctx.tu, arr[i]) == "->": result = true; break
  clang_disposeTokens(ctx.tu, toks, n)

proc derefVar(ctx: Ctx, base: CXCursor, line: int, outp: var seq[Stmt]) =
  let b = unwrap(base)
  if clang_getCursorKind(b) == ckDeclRefExpr:
    outp.add emit(ikDeref, line, a = spelling(b), aKey = referencedUsr(b))

proc flattenAnd(ctx: Ctx, c: CXCursor, acc: var seq[CXCursor]) =
  ## Flatten a left-associative `A && B && C` into its conjuncts [A, B, C] (in evaluation
  ## order). A non-`&&` node is itself one conjunct. Used to model `&&` SHORT-CIRCUIT: a
  ## conjunct's index sinks are only reached when every conjunct to its LEFT held.
  let cu = unwrap(c)
  if clang_getCursorKind(cu) == ckBinaryOperator and ctx.binOperator(cu) == "&&":
    let kids = collectChildren(cu)
    if kids.len == 2:
      ctx.flattenAnd(kids[0], acc); ctx.flattenAnd(kids[1], acc); return
  acc.add c

proc condLowerLift(ctx: Ctx, c: CXCursor): tuple[has: bool, key: string, lifted: int] =
  ## A guard conjunct `field != c` (or `c != field`) where `field` carries a declared
  ## `@invariant(field >= c)`: combined, `field >= c ∧ field != c ⟹ field >= c+1`. Returns
  ## the lift so a SHORT-CIRCUIT `&&` conjunct evaluated after it sees `field >= c+1`. The
  ## `!= c` asserts nothing on its own (sound: it only tightens an EXISTING declared bound).
  let cu = unwrap(c)
  if clang_getCursorKind(cu) != ckBinaryOperator or ctx.binOperator(cu) != "!=": return
  let kids = collectChildren(cu)
  if kids.len != 2: return
  let ll = ctx.parseLinear(kids[0])
  let rr = ctx.parseLinear(kids[1])
  var vLin, cLin: tuple[ok: bool, key, disp: string, off: int]
  if ll.ok and ll.key.len > 0 and rr.ok and rr.key.len == 0: vLin = ll; cLin = rr
  elif rr.ok and rr.key.len > 0 and ll.ok and ll.key.len == 0: vLin = rr; cLin = ll
  else: return
  let neqConst = cLin.off - vLin.off              # `value + vOff != cConst` -> `value != cConst-vOff`
  if vLin.key in ctx.curProtectedLow and ctx.curProtectedLow[vLin.key].lowConst == neqConst:
    return (true, vLin.key, neqConst + 1)

proc lowerCall(ctx: var Ctx, call: CXCursor, line: int, outp: var seq[Stmt]) =
  ## Every call: its declared effects (lowerCallCore), THEN — C++ with exceptions on — the
  ## unwinding exit a callee without a nothrow guarantee may take (ikMayThrow). After the
  ## effects, so a `@frees` / `@moves` argument is already the callee's (its fate on a throw
  ## is the callee's own body to answer for) and what the caller still holds is exactly what
  ## that path loses.
  ctx.throwEmitted = false
  ctx.lowerCallCore(call, line, outp)
  if not ctx.throwEmitted and ctx.mayThrow(call):
    outp.add emit(ikMayThrow, line, a = spelling(call))
  ctx.throwEmitted = false

proc lowerExprCalls(ctx: var Ctx, c: CXCursor, outp: var seq[Stmt]) =
  ## Lower the argument side-effects (escape / `@frees` / `@moves` / borrow, plus lock
  ## and size effects) of every call embedded in an EXPRESSION that is not itself a
  ## statement: an `if`/`while`/`switch` condition (`if (f(p) != 0) goto fail;`), an
  ## assignment / initializer RHS (`int r = f(p);`), a `return` expression
  ## (`return take(p);`), or a call buried under an operator (`take(p) + 1`). A
  ## statement-form call reaches `lowerCall` via the ckCallExpr case, but a call in one
  ## of these positions otherwise does NOT — without this an owned pointer passed to it
  ## is neither escaped nor contracted, so it looks still-owned and FALSE-LEAKS at the
  ## function exit (the honest verdict is the same UNCONTRACTED_ESCAPE a statement-form
  ## call gets). The rule is: any ownership-affecting `ckCallExpr` passes through
  ## `lowerCall` exactly once. Recursion stops at the outermost call of a sub-tree,
  ## because `lowerCall` already recurses into its own nested-call arguments.
  let cu = unwrap(c)
  # `std::move(v)` anywhere in an expression (`y = std::move(x)`, `return std::move(x)`, a
  # condition) is the transfer itself, not a callee to lower: `v` is moved out here. An
  # untracked operand is simply skipped (never treated as an uncontracted escape).
  block exprMove:
    let sm = stdMoveOperand(cu)
    if sm.has:
      ctx.moveOwner(sm.key, sm.disp, startLine(cu), outp)
      return
  if clang_getCursorKind(cu) == ckLambdaExpr:
    # A lambda appearing anywhere OTHER than `auto v = [..]{..}` (passed to a callee, returned,
    # stored in a std::function): kenbi cannot tell when — or how often — its body runs, so it
    # must not be lowered here as if it ran now. Inert if it touches no memory; refused if it
    # allocates or releases (silently ignoring that free could hide a later double free).
    if ctx.holdsMemoryOp(cu):
      outp.add emit(ikUnsupportedConstruct, startLine(cu), a = "lambda")
    return
  if clang_getCursorKind(cu) == ckCallExpr:
    ctx.lowerCall(cu, startLine(cu), outp)
    return
  for ch in collectChildren(cu):
    ctx.lowerExprCalls(ch, outp)

proc scanDerefs(ctx: Ctx, c: CXCursor, outp: var seq[Stmt]) =
  ## Walk an expression subtree and emit `ikDeref` for `*p` / `p->x` / `p[i]`
  ## of a named variable. Harmless on non-nullable vars (the engine only warns
  ## when null-state says maybe). Does not descend into nested statements.
  let k = clang_getCursorKind(c)
  let kids = collectChildren(c)
  case k
  of ckBinaryOperator:
    # SHORT-CIRCUIT `&&`: a guard conjunct (`toksuper != -1`, lifting a declared lower
    # invariant) bounds the conjuncts to its RIGHT, which are evaluated only when it holds.
    # Walk conjuncts left-to-right, emitting each guard's lift (ikLowBound) before the rest;
    # then CLEAR the lifts (ikTaint) so they do not persist past this condition (sound — a
    # later unguarded access falls back to the declared invariant, not the transient lift).
    if ctx.binOperator(c) == "&&" and kids.len == 2:
      var conj: seq[CXCursor]
      ctx.flattenAnd(c, conj)
      var lifted: seq[string]
      for cj in conj:
        ctx.scanDerefs(cj, outp)
        let g = ctx.condLowerLift(cj)
        if g.has:
          outp.add emit(ikLowBound, startLine(cj), aKey = g.key, off = g.lifted)
          lifted.add g.key
      for f in lifted: outp.add emit(ikTaint, startLine(c), aKey = f)
      return
    for ch in kids: ctx.scanDerefs(ch, outp)
    return
  of ckUnaryOperator:
    if ctx.firstTokenSpelling(c) == "*" and kids.len >= 1:
      ctx.derefVar(kids[0], startLine(c), outp)
  of ckArraySubscriptExpr:
    if kids.len >= 1: ctx.derefVar(kids[0], startLine(c), outp)
    # SPATIAL sink: the index expression. A value (possibly `var ± k`) used as a subscript
    # must be VALIDATED; emit ikIndex so the spatial pass can check it, carrying the `± k`
    # offset so a neighbour access `buf[i + 1]` requires `i` bounded to cover `i + 1`. A
    # pure-constant / modulo / mask index is bounded by construction (no variable -> no sink).
    if kids.len >= 2:
      let lin = ctx.parseLinear(kids[1])
      if lin.ok and lin.key.len > 0:
        let base = unwrap(kids[0])     # the buffer: its size (if a fixed array) lets the
        var sz = -1
        var bsym = ""                  # the buffer's symbolic allocation count, if known
        var bsymOff = 0                # the buffer holds `bsym + bsymOff` elements
        if clang_getCursorKind(base) == ckDeclRefExpr:
          sz = fixedArraySize(base)
          if sz < 0:
            let s = ctx.bufSizeSym.getOrDefault(referencedUsr(base))
            bsym = s.symKey; bsymOff = s.off
        elif clang_getCursorKind(base) == ckMemberRefExpr:
          sz = fixedArraySize(base)    # a fixed-size array member `s->buf[N]` (field buffer)
          if sz < 0:                   # a pointer field sized by a declared `@counted_by`
            let (fk, _) = fieldPath(base)
            if fk.len > 0:
              let s = ctx.bufSizeSym.getOrDefault(fk)
              bsym = s.symKey; bsymOff = s.off
        let uns = isUnsignedInteger(unwrap(kids[1]))   # unsigned index: >= 0 by type
        outp.add emit(ikIndex, startLine(c), a = lin.disp, aKey = lin.key,
                      off = sz, off2 = lin.off, bKey = bsym, cKey = (if uns: "u" else: ""),
                      off3 = bsymOff)
  of ckMemberRefExpr:
    if kids.len >= 1 and ctx.hasArrow(c): ctx.derefVar(kids[0], startLine(c), outp)
  else: discard
  for ch in kids: ctx.scanDerefs(ch, outp)

proc protectedKeyOf(ctx: Ctx, e: CXCursor): tuple[key, disp: string] =
  ## If `e` is a PROTECTED field/var (an `@invariant` target of the current function),
  ## its key + display. A one-level field path `s->f` or a bare variable.
  let u = unwrap(e)
  if clang_getCursorKind(u) == ckMemberRefExpr:
    let (fk, fd) = fieldPath(u)
    if fk.len > 0 and (fk in ctx.curProtected or fk in ctx.curProtectedLow): return (fk, fd)
  elif clang_getCursorKind(u) == ckDeclRefExpr:
    let key = referencedUsr(u)
    if key in ctx.curProtected or key in ctx.curProtectedLow: return (key, spelling(u))
  ("", "")

proc incDecDelta(ctx: Ctx, c: CXCursor): int =
  ## +1 for a `++` UnaryOperator, -1 for `--`, 0 if `c` is neither (prefix or postfix,
  ## by token scan).
  if clang_getCursorKind(c) != ckUnaryOperator: return 0
  var toks: ptr CXToken
  var n: cuint
  clang_tokenize(ctx.tu, clang_getCursorExtent(c), addr toks, addr n)
  let arr = cast[ptr UncheckedArray[CXToken]](toks)
  result = 0
  for i in 0 ..< int(n):
    let s = $clang_getTokenSpelling(ctx.tu, arr[i])
    if s == "++": result = 1; break
    elif s == "--": result = -1; break
  clang_disposeTokens(ctx.tu, toks, n)

proc maskByKey(ctx: Ctx, rhs: CXCursor): string =
  ## If `rhs` is `X & mask` where `mask` is a bare UNSIGNED variable / field, its key — else
  ## "". `X & mask` (mask >= 0) yields a value `<= mask`, so a SET `field = X & mask`
  ## ESTABLISHES `field <= mask` (the power-of-two ring-buffer write `idx = (idx+1) & buffer_mask`
  ## maintaining `idx <= buffer_mask`). Used by the invariant establish check.
  let v = unwrap(rhs)
  if clang_getCursorKind(v) != ckBinaryOperator or ctx.binOperator(v) != "&": return ""
  let kids = collectChildren(v)
  if kids.len != 2: return ""
  for mi in [1, 0]:                                   # prefer the right operand (`x & mask`)
    let mt = ctx.scalarTerm(unwrap(kids[mi]))
    if mt.ok and isUnsignedInteger(unwrap(kids[mi])): return mt.key
  ""

const unknownDelta = high(int)   ## a write whose delta the front-end cannot compute

proc scanInvariantWrites(ctx: Ctx, c: CXCursor, outp: var seq[Stmt]) =
  ## INVARIANT: handle a write to a PROTECTED field/var (an `@invariant` target), anywhere
  ## in an expression subtree. A NON-`@maintains` write -> ikInvariantWrite (write-barrier,
  ## slice 2). A `@maintains` write -> ikMaintainsCheck carrying the write's delta + the
  ## declared relation, so the spatial pass can verify it preserves the invariant (slice 3).
  ## Write forms + deltas: `f++`/`--f` (±1), `f += k`/`f -= k` (±k, k const), `f = …` /
  ## other compound (unknown delta -> not verifiable in this slice).
  let k = clang_getCursorKind(c)
  let kids = collectChildren(c)
  var target = CXCursor()                           # the written lvalue, if this is a write
  var isWrite = false
  var isSet = false                                 # `field = rhs` (an establishing set)
  var delta = unknownDelta
  case k
  of ckBinaryOperator:
    if ctx.binOperator(c) == "=" and kids.len >= 1:
      target = kids[0]; isWrite = true; isSet = true  # set: verified via its RHS (slice 4)
  of ckCompoundAssign:
    if kids.len >= 1:
      target = kids[0]; isWrite = true
      let op = ctx.binOperator(c)
      if kids.len >= 2:
        let rc = constIntValue(unwrap(kids[1]))
        if op == "+=" and rc.known: delta = int(rc.value)
        elif op == "-=" and rc.known: delta = -int(rc.value)
  of ckUnaryOperator:
    let d = ctx.incDecDelta(c)
    if d != 0 and kids.len >= 1: target = kids[0]; isWrite = true; delta = d
  else: discard
  if isWrite:
    let (pk, pd) = ctx.protectedKeyOf(target)
    if pk.len > 0:
      if startLine(c) in ctx.maintainsLines:
        # The RHS as a linear form `term ± off` (shared by the upper establish + the lower
        # check); "@opaque" if kenbi cannot read it. A field may carry an UPPER invariant, a
        # LOWER invariant, or BOTH — one `@maintains` is verified against every one.
        let lin = (if isSet and kids.len >= 2: ctx.parseLinear(kids[1])
                   else: (ok: false, key: "", disp: "", off: 0))
        let rhsKey = (if not lin.ok: "@opaque" else: lin.key)
        let rhsUnsigned = lin.ok and lin.key.len > 0 and lin.key in ctx.fieldUnsigned
        if pk in ctx.curProtected:                  # UPPER invariant: verify preservation
          let inv = ctx.curProtected[pk]
          let relBit = (if inv.rel == "<=": 1 else: 0)
          # `field = field ± k` is a SET that is really an INCREMENT/DECREMENT (`len = len + 1`
          # ≡ `len += 1`) — verify it like a compound `+=`, not as an establishing set.
          let selfDelta = isSet and lin.ok and lin.key == pk
          if isSet and kids.len >= 2 and not selfDelta:
            # A SET establishes the relation from its RHS directly (slice 4 — the init leg).
            # `field = X & sizeOperand` establishes `field <= sizeOperand` (the mask idiom):
            # mark it cKey="@mask" so the spatial pass accepts it for a `<=` invariant.
            let masked = (ctx.maskByKey(kids[1]) == inv.sizeKey and inv.sizeKey.len > 0)
            outp.add emit(ikEstablishCheck, startLine(c), a = pd, aKey = pk,
                          b = inv.sizeDisp, bKey = inv.sizeKey,
                          cKey = (if masked: "@mask" else: rhsKey),
                          off = lin.off, off2 = relBit or (if inv.sizeUnsigned: 2 else: 0))
          else:
            outp.add emit(ikMaintainsCheck, startLine(c), a = pd, aKey = pk,
                          b = inv.sizeDisp, bKey = inv.sizeKey,
                          off = (if selfDelta: lin.off else: delta), off2 = relBit)
        if pk in ctx.curProtectedLow:               # LOWER invariant (C2): verify preservation
          if isSet:
            # `field = rhs`: rhs >= c — a pure constant, an unsigned term (>= 0), or a
            # path-tracked `low[rhs]`. off2 bit0 = isSet, bit1 = the RHS term is unsigned.
            outp.add emit(ikLowInvariantCheck, startLine(c), a = pd, aKey = pk,
                          cKey = rhsKey, off = lin.off,
                          off2 = 1 or (if rhsUnsigned: 2 else: 0))
          else:                                     # `++`/`--`/`+=`: a non-negative δ preserves it
            outp.add emit(ikLowInvariantCheck, startLine(c), a = pd, aKey = pk,
                          off = delta, off2 = 0)
      else:
        outp.add emit(ikInvariantWrite, startLine(c), a = pd, aKey = pk)
  for ch in kids: ctx.scanInvariantWrites(ch, outp)

proc guardedFieldOf(ctx: Ctx, c: CXCursor): tuple[has: bool, fk, fd, lockDisp, lockKey: string] =
  ## If the MemberRefExpr `c` is a `@guarded_by` field (either form), its access key/display and
  ## the lock that must be held; else has=false. Shared by the access check and the escape check.
  if clang_getCursorKind(c) != ckMemberRefExpr: return
  let (fk, fd) = fieldPath(c)
  if fk.len == 0: return
  if fk in ctx.curGuarded:                            # two-arg `@guarded_by(field: lock)`
    let g = ctx.curGuarded[fk]
    return (true, fk, fd, g.lockDisp, g.lockKey)
  if ctx.guardedMember.len > 0:                       # single-arg `@guarded_by(lock)` on the member
    let declUsr = referencedUsr(c)
    if declUsr in ctx.guardedMember:
      let kids = collectChildren(c)
      if kids.len >= 1 and clang_getCursorKind(unwrap(kids[0])) == ckDeclRefExpr:
        let base = unwrap(kids[0])
        let lockName = ctx.guardedMember[declUsr]
        return (true, fk, fd, spelling(base) & "->" & lockName, referencedUsr(base) & "::" & lockName)

proc scanGuardedAccess(ctx: Ctx, c: CXCursor, outp: var seq[Stmt], seen: var HashSet[string]) =
  ## CONCURRENCY: emit ikGuardedAccess for each read/write of a `@guarded_by(field: lock)` field,
  ## and ikGuardedEscape where its ADDRESS is taken (`&c->data`) — a pointer to the guarded data
  ## escapes the lock's reach, so accesses through it can't be verified (an alias can race after
  ## the lock is dropped; default-red). Deduped per top-level statement (`seen`).
  if clang_getCursorKind(c) == ckUnaryOperator and ctx.firstTokenSpelling(c) == "&":
    let kids = collectChildren(c)
    if kids.len >= 1:
      let g = ctx.guardedFieldOf(unwrap(kids[0]))
      if g.has and g.fk notin seen:                   # &<guarded field>: the address escapes
        seen.incl g.fk
        outp.add emit(ikGuardedEscape, startLine(c), a = g.fd, aKey = g.fk)
        return                                        # not also a plain access of the operand
  let g = ctx.guardedFieldOf(c)
  if g.has and g.fk notin seen:
    seen.incl g.fk
    outp.add emit(ikGuardedAccess, startLine(c), a = g.fd, aKey = g.fk,
                  b = g.lockDisp, bKey = g.lockKey)
  for ch in collectChildren(c): ctx.scanGuardedAccess(ch, outp, seen)

proc isNullLit(ctx: Ctx, c: CXCursor): bool =
  ## Is `c` a null-pointer constant? `NULL` expands to `((void*)0)`, so peel
  ## wrappers (UnexposedExpr / ParenExpr / CStyleCastExpr) down to an integer
  ## literal; token-match `0` / `NULL` / `nullptr` as a fallback for the bare
  ## forms (the macro expansion's tokens are empty).
  if ctx.firstTokenSpelling(c) in ["0", "NULL", "nullptr"]: return true
  var cur = c
  for _ in 0 ..< 16:
    let k = clang_getCursorKind(cur)
    if k == ckIntegerLiteral: return true
    if k in [ckUnexposedExpr, ckParenExpr, ckCStyleCastExpr]:
      let kids = collectChildren(cur)
      if kids.len == 0: return false
      cur = kids[^1]
    else: return false
  false

proc nullCondTarget(c: CXCursor): tuple[key, disp: string] =
  ## The handle a null test is ABOUT: a plain variable, or a one-level field path
  ## (`b->blob`, `arr[2]`) — which the engine tracks under exactly the same kind of key, so
  ## everything downstream of the narrowing works unchanged. Only the recogniser was
  ## variable-only, and the asymmetry showed:
  ##     if (p == NULL)       p       = malloc(n);   /* clean */
  ##     if (b->blob == NULL) b->blob = malloc(n);   /* a false overwrite-leak */
  ## The second is ImageMagick's `AcquireVirtualMemory`, whose fall-back allocations are each
  ## guarded by the field still being NULL.
  if clang_getCursorKind(c) == ckDeclRefExpr:
    return (referencedUsr(c), spelling(c))
  fieldPath(c)

proc scanStableScalars(ctx: var Ctx, fn: CXCursor) =
  ## The integer / enum LOCALS and PARAMETERS this function never assigns after their
  ## declaration and never takes the address of. Such a value cannot change between two tests of
  ## it, so a branch that learns one is a fact every later statement on that path keeps.
  ##
  ## Restricted to locals and parameters on purpose. A FIELD (`c->verbose`) looks just as stable
  ## in the source and is not: any call in between can write it through the pointer, and kenbi
  ## would have to prove none does. A local's value can only change by an assignment here or
  ## through a pointer to it, and both are visible in this body.
  ctx.stableScalars = initHashSet[string]()
  var cands: HashSet[string]
  for parm in collectChildren(fn):
    if clang_getCursorKind(parm) == ckParmDecl and isIntegerType(parm):
      cands.incl usr(parm)
  var written: HashSet[string]
  proc walk(ctx: Ctx, n: CXCursor, cands, written: var HashSet[string]) =
    let k = clang_getCursorKind(n)
    if k == ckVarDecl and isIntegerType(n) and
       clang_Cursor_getStorageClass(n) notin [scStatic, scExtern]:
      cands.incl usr(n)                            # its initialiser is not an assignment
    elif k == ckBinaryOperator or k == ckCompoundAssign:
      let kids = collectChildren(n)
      if kids.len == 2 and (k == ckCompoundAssign or ctx.binOperator(n) == "="):
        let lhs = unwrap(kids[0])
        if clang_getCursorKind(lhs) == ckDeclRefExpr: written.incl referencedUsr(lhs)
    elif k == ckUnaryOperator:
      let toks = ctx.cursorTokens(n)
      if toks.len > 0 and (toks[0] in ["&", "++", "--"] or toks[^1] in ["++", "--"]):
        let kids = collectChildren(n)
        if kids.len == 1 and clang_getCursorKind(unwrap(kids[0])) == ckDeclRefExpr:
          written.incl referencedUsr(unwrap(kids[0]))
    for ch in collectChildren(n): ctx.walk(ch, cands, written)
  for ch in collectChildren(fn):
    if clang_getCursorKind(ch) == ckCompoundStmt: ctx.walk(ch, cands, written)
  for k in cands:
    if k notin written: ctx.stableScalars.incl k

proc stablePredKey(ctx: Ctx, c: CXCursor): string =
  ## `c` as a test of a stable scalar, or "" — a bare read of a local / parameter the function
  ## never writes. Deliberately narrow: anything else is a condition kenbi cannot correlate.
  let u = unwrap(c)
  if clang_getCursorKind(u) != ckDeclRefExpr: return ""
  let k = referencedUsr(u)
  if k in ctx.stableScalars: k else: ""

proc parsePredCond(ctx: Ctx, cond: CXCursor, s: Stmt) =
  ## `if (x)` / `if (!x)` on a stable scalar: record which branch is the non-zero one, so a
  ## LATER test of the same scalar on this path takes only the branch that can still happen.
  let cu = unwrap(cond)
  let direct = ctx.stablePredKey(cu)
  if direct.len > 0:
    s.predKey = direct; s.predThenNonZero = true
    return
  if clang_getCursorKind(cu) == ckUnaryOperator and ctx.firstTokenSpelling(cu) == "!":
    let kids = collectChildren(cu)
    if kids.len == 1:
      let inner = ctx.stablePredKey(kids[0])
      if inner.len > 0:
        s.predKey = inner; s.predThenNonZero = false

proc parseNullCond(ctx: Ctx, cond: CXCursor, s: Stmt) =
  ## Recognise `p`, `!p`, `p == NULL`, `p != NULL` — on a variable or a one-level field path —
  ## so the engine can narrow the branch. Anything else leaves condKey empty (no narrowing).
  let cu = unwrap(cond)
  let k = clang_getCursorKind(cu)
  let direct = nullCondTarget(cu)
  if direct.key.len > 0:
    s.condKey = direct.key; s.condDisp = direct.disp; s.condThenNonNull = true
  elif k == ckUnaryOperator and ctx.firstTokenSpelling(cu) == "!":
    let kids = collectChildren(cu)
    if kids.len >= 1:
      let o = nullCondTarget(unwrap(kids[0]))
      if o.key.len > 0:
        s.condKey = o.key; s.condDisp = o.disp; s.condThenNonNull = false
  elif k == ckBinaryOperator:
    let op = ctx.binOperator(cu)
    if op == "==" or op == "!=":
      let kids = collectChildren(cu)
      if kids.len == 2:
        let l = nullCondTarget(unwrap(kids[0]))
        let r = nullCondTarget(unwrap(kids[1]))
        var v: tuple[key, disp: string]
        var ok = false
        if l.key.len > 0 and ctx.isNullLit(kids[1]): v = l; ok = true
        elif r.key.len > 0 and ctx.isNullLit(kids[0]): v = r; ok = true
        if ok:
          s.condKey = v.key; s.condDisp = v.disp
          s.condThenNonNull = (op == "!=")

proc collectNonNullFacts(ctx: Ctx, cond: CXCursor, s: Stmt, negated: bool) =
  ## Every pointer a condition proves NON-NULL, per branch, recursing `&&` / `||`. A compound
  ## guard cannot say which operand is null, so only the non-null side is recorded — and that
  ## side is all that is needed: C allocates several buffers and guards them together
  ## (`if ((a == NULL) || (b == NULL)) { cleanup; return; }`), after which both are non-null.
  ## Without these facts every later use of them was a possibly-null dereference (47 such
  ## claims in ImageMagick's draw.c, whose extend-the-path macro is exactly this shape).
  ## `negated` tracks whether we are under a `!`, which swaps the branches.
  let cu = unwrap(cond)
  let k = clang_getCursorKind(cu)
  proc add(key, disp: string, onThen: bool) =
    if key.len == 0: return
    if onThen != negated: s.nonNullThen.add (key, disp)
    else: s.nonNullElse.add (key, disp)
  let direct = nullCondTarget(cu)
  if direct.key.len > 0:
    add(direct.key, direct.disp, true)                  # `if (p)` / `if (b->f)` -> THEN
  elif k == ckUnaryOperator and ctx.firstTokenSpelling(cu) == "!":
    let kids = collectChildren(cu)
    if kids.len >= 1: ctx.collectNonNullFacts(kids[0], s, not negated)
  elif k == ckBinaryOperator:
    let op = ctx.binOperator(cu)
    let kids = collectChildren(cu)
    if op == "&&" or op == "||":
      # `A && B` proves both on THEN; `A || B` proves both negations on ELSE. Under a `!` the
      # roles swap, which `negated` already carries into the recursion.
      for kid in kids: ctx.collectNonNullFacts(kid, s, negated)
    elif (op == "==" or op == "!=") and kids.len == 2:
      let l = nullCondTarget(unwrap(kids[0]))
      let r = nullCondTarget(unwrap(kids[1]))
      var v: tuple[key, disp: string]
      var ok = false
      if l.key.len > 0 and ctx.isNullLit(kids[1]): v = l; ok = true
      elif r.key.len > 0 and ctx.isNullLit(kids[0]): v = r; ok = true
      if ok: add(v.key, v.disp, op == "!=")

proc parsePtrCmpCond(ctx: Ctx, cond: CXCursor, s: Stmt) =
  ## CONCURRENCY (v3 stage 3): recognise an address comparison of two pointer variables
  ## (`if (a < b)`) so the lock-balance pass knows a canonical ordering between them holds on each
  ## branch. This is what legalises locking two same-class instances: `if (a<b) {lock(a);lock(b);}
  ## else {lock(b);lock(a);}` acquires the lower-addressed lock first on both paths. Only a bare
  ## `var <rel> var` is recognised (the recognisable discipline); anything else leaves it unset.
  let cu = unwrap(cond)
  if clang_getCursorKind(cu) != ckBinaryOperator: return
  let op = ctx.binOperator(cu)
  if op notin ["<", ">", "<=", ">="]: return
  let kids = collectChildren(cu)
  if kids.len != 2: return
  let l = unwrap(kids[0])
  let r = unwrap(kids[1])
  if clang_getCursorKind(l) == ckDeclRefExpr and clang_getCursorKind(r) == ckDeclRefExpr:
    s.condPtrL = referencedUsr(l); s.condPtrR = referencedUsr(r); s.condPtrOp = op

proc trylockOf(ctx: Ctx, c: CXCursor): tuple[isTry: bool, key, disp: string] =
  ## If `c` is a recognised `trylock(&m)` call, the lock's identity (key/display); else isTry=false.
  let cu = unwrap(c)
  if clang_getCursorKind(cu) == ckCallExpr and spelling(cu) in lockTryAcquirers:
    let kids = collectChildren(cu)                 # kids[0] = callee ref, kids[1] = &lock
    if kids.len >= 2:
      let (k, d, _, _) = ctx.lockKeyOf(kids[1])
      if k.len > 0: return (true, k, d)
  (false, "", "")

proc isZeroLit(c: CXCursor): bool =
  let v = constIntValue(c)
  v.known and v.value == 0

proc parseTrylockCond(ctx: Ctx, cond: CXCursor, s: Stmt) =
  ## Recognise a `trylock` test so the engine knows the lock is HELD only on the SUCCESS branch
  ## (trylock returns 0 on success, nonzero on failure). Forms, with the branch that HOLDS:
  ##   `trylock(&m) == 0` / `!trylock(&m)`            -> success on THEN
  ##   `trylock(&m) != 0` / bare `if (trylock(&m))`   -> success on ELSE (nonzero = failure)
  ## Anything else leaves condLockKey empty (no acquire recognised).
  let cu = unwrap(cond)
  let bare = ctx.trylockOf(cu)                      # bare `if (trylock(&m))`: truthy = failure
  if bare.isTry:
    s.condLockKey = bare.key; s.condLockDisp = bare.disp; s.condLockOnThen = false
    return
  let k = clang_getCursorKind(cu)
  if k == ckUnaryOperator and ctx.firstTokenSpelling(cu) == "!":
    let kids = collectChildren(cu)
    if kids.len >= 1:
      let t = ctx.trylockOf(kids[0])               # `!trylock(&m)`: success on THEN
      if t.isTry:
        s.condLockKey = t.key; s.condLockDisp = t.disp; s.condLockOnThen = true
  elif k == ckBinaryOperator:
    let op = ctx.binOperator(cu)
    if op == "==" or op == "!=":
      let kids = collectChildren(cu)
      if kids.len == 2:
        var t = ctx.trylockOf(kids[0]); var lit = kids[1]
        if not t.isTry:
          t = ctx.trylockOf(kids[1]); lit = kids[0]
        if t.isTry and isZeroLit(lit):
          s.condLockKey = t.key; s.condLockDisp = t.disp
          s.condLockOnThen = (op == "==")          # == 0 success on THEN; != 0 on ELSE

proc subPlus(a, b: int, plus1: bool): tuple[ok: bool, v: int] =
  ## `a - b (+1 if plus1)`, REFUSING (ok=false) if it would overflow `int`. Bound
  ## offsets come from real C integer literals, so an extreme constant (INT64_MAX,
  ## 0x7fff…, common in real code) can overflow the offset arithmetic. Refusing then
  ## places NO bound — sound (undecidable → stays RED) — instead of crashing.
  if b < 0 and a > high(int) + b: return (false, 0)   # a - b overflows high
  if b > 0 and a < low(int) + b: return (false, 0)    # a - b underflows low
  var r = a - b
  if plus1:
    if r == high(int): return (false, 0)
    inc r
  (true, r)

proc boundWhenTrue(ctx: Ctx, op: string, lhs, rhs: CXCursor): tuple[has: bool, eff: BoundEffect] =
  ## SPATIAL: given a relational `lhs op rhs` is TRUE, the bound it places on its variable.
  ## UPPER bound (the variable on the SMALLER side): `v OP limit` with OP in {<,<=} or
  ## `limit OP v` with OP in {>,>=}, normalised to `value < limit` (const) / `value < sym +
  ## off` (symbolic). LOWER bound (the variable on the LARGER side, CONSTANT limit only):
  ## `v >= c` / `v > c` / `c <= v` / `c < v`, normalised to `value >= constLimit` — used to
  ## discharge the signed-index lower-bound requirement (`i >= 0`).
  if op notin ["<", "<=", ">", ">="]: return (false, BoundEffect())
  let ll = ctx.parseLinear(lhs)
  let rr = ctx.parseLinear(rhs)
  if not ll.ok or not rr.ok: return (false, BoundEffect())
  var varLin, limLin: tuple[ok: bool, key, disp: string, off: int]
  var varCur, limCur: CXCursor                           # cursors of the variable / limit sides
  var nonStrict: bool
  if (op == "<" or op == "<=") and ll.key.len > 0:
    varLin = ll; limLin = rr; nonStrict = (op == "<="); varCur = lhs; limCur = rhs
  elif (op == ">" or op == ">=") and rr.key.len > 0:
    varLin = rr; limLin = ll; nonStrict = (op == ">="); varCur = rhs; limCur = lhs
  else:
    # The variable is on the LARGER side -> a LOWER bound. Track it only for a CONSTANT
    # limit (`i >= 0` is the case that matters): `var + varOff >= limConst` -> `var >=
    # limConst - varOff`; `>` adds 1. `varKey OP constKey` is `v >`/`>=` c here.
    var vLin, cLin: tuple[ok: bool, key, disp: string, off: int]
    var strict: bool
    if (op == ">" or op == ">=") and ll.key.len > 0 and rr.key.len == 0:
      vLin = ll; cLin = rr; strict = (op == ">")          # v > / >= const
    elif (op == "<" or op == "<=") and rr.key.len > 0 and ll.key.len == 0:
      vLin = rr; cLin = ll; strict = (op == "<")          # const < / <= v
    else:
      return (false, BoundEffect())                       # symbolic lower bound: not tracked
    let (okL, lowLimit) = subPlus(cLin.off, vLin.off, strict)
    if not okL: return (false, BoundEffect())
    return (true, BoundEffect(key: vLin.key, isLower: true, constLimit: lowLimit))
  # `var + varOff <REL> lim + limOff`  ->  `var < lim + (limOff - varOff [+1 if <=])`
  let (okR, rawOff) = subPlus(limLin.off, varLin.off, nonStrict)
  if not okR: return (false, BoundEffect())
  # OVERFLOW-SAFETY (spatial soundness): the ℤ rewrite above is unsound where the guard's
  # OWN arithmetic misbehaves at runtime. Two hazards, marked and carried to the sink (which
  # knows the access offset and the limit's tracked lower bound) rather than refused here:
  #  (1) UNTRUSTED-variable positive offset `var + k`. Whether `var + k` overflows is an
  #      unverified property of an untrusted value, so it is NOT creditable — default-red.
  #      UNSIGNED: `var + k` WRAPS near the type max (`i = 0xFFFFFFFE`, `i + 4 == 2 <= size`
  #      passes yet `buf[i]` is ~4GB OOB), landing at a SMALL value the check catches — so the
  #      bound is still sound for an access at exactly `k`; the sink drops only a SMALLER
  #      offset. SIGNED (option B, `wrapVarStrict`): overflow is UB and `var` near INT_MAX
  #      wraps to INT_MIN — a large NEGATIVE that passes `< limit` yet is far OOB. No access
  #      offset is safe (the `j == gk` neighbour form is unsafe too), so the sink drops EVERY
  #      access. Signed is stricter than unsigned, not weaker.
  #  (2) LIMIT-side negative offset `sym - k`. UNSIGNED: `sym - k` UNDERFLOWS to a huge value
  #      when `sym < k` (fail-OPEN), making the bound vacuous — the sink requires the companion
  #      `sym >= k`. SIGNED needs no companion: `sym - k` goes NEGATIVE, so `var <= sym - k`
  #      is false and the branch is not taken (fail-CLOSED) — already safe.
  # The overflow-safe forms are `lim >= k && var <= lim - k` or `var < lim && lim - var >= k`.
  let varUnsigned = isUnsignedInteger(unwrap(varCur))
  let wrapVar = varLin.off > 0
  let wrapVarStrict = varLin.off > 0 and not varUnsigned
  let wrapLimNeed = (if limLin.key.len > 0 and limLin.off < 0 and
                        isUnsignedInteger(unwrap(limCur)): -limLin.off else: 0)
  if limLin.key.len == 0:                            # constant limit
    return (true, BoundEffect(key: varLin.key, isConst: true, constLimit: rawOff,
                              wrapVar: wrapVar, wrapGuardOff: varLin.off,
                              wrapVarStrict: wrapVarStrict))
  return (true, BoundEffect(key: varLin.key, isConst: false,
                            symKey: limLin.key, symDisp: limLin.disp, symOff: rawOff,
                            wrapVar: wrapVar, wrapGuardOff: varLin.off,
                            wrapVarStrict: wrapVarStrict, wrapLimNeed: wrapLimNeed))

proc negateRel(op: string): string =
  case op
  of "<": ">="
  of "<=": ">"
  of ">": "<="
  of ">=": "<"
  else: ""

proc neqBound(ctx: Ctx, lhs, rhs: CXCursor): tuple[has: bool, eff: BoundEffect] =
  ## SPATIAL: `value != const` (or `const != value`) — a DISEQUALITY that, combined with a
  ## known lower bound of exactly that constant, lifts it by 1 (`x != -1` ∧ `x >= -1` ⟹
  ## `x >= 0`). It asserts no bound on its own (the value could be anywhere but the constant),
  ## so it is sound: it only tightens an EXISTING declared lower bound at the analyzer.
  let ll = ctx.parseLinear(lhs)
  let rr = ctx.parseLinear(rhs)
  var vLin, cLin: tuple[ok: bool, key, disp: string, off: int]
  if ll.ok and ll.key.len > 0 and rr.ok and rr.key.len == 0: vLin = ll; cLin = rr
  elif rr.ok and rr.key.len > 0 and ll.ok and ll.key.len == 0: vLin = rr; cLin = ll
  else: return (false, BoundEffect())
  # `value + vOff != cConst`  ->  `value != cConst - vOff`
  let (ok, lim) = subPlus(cLin.off, vLin.off, false)
  if not ok: return (false, BoundEffect())
  (true, BoundEffect(key: vLin.key, isNeq: true, constLimit: lim))

proc subHeadroomBound(ctx: Ctx, op: string, lhs, rhs: CXCursor): tuple[has: bool, eff: BoundEffect] =
  ## SPATIAL overflow-SAFE idiom: `(A - B) >= c` / `(A - B) > c` (or the const on the left),
  ## the parser "remaining bytes" check `end - p >= k`. It bounds the SUBTRAHEND `B` by the
  ## minuend `A`: `A - B >= c` ⟹ `B <= A - c` ⟹ `B < A + (1 - c)`. The arithmetic is on the
  ## TRUSTED limit `A`, so the untrusted `B` never wraps — the overflow-safe counterpart to the
  ## wrap-prone `B + c <REL> A`. The remaining hazard is that `A - B` UNDERFLOWS when `B > A`
  ## (unsigned): then it is huge and `>= c` passes with `B` unbounded. So an UNSIGNED `B` needs
  ## the companion `B <= A` (`p < end`), verified among the sibling conjuncts
  ## (`needsLtCompanion`); a SIGNED `B` fails CLOSED (`A - B` goes negative → `>= c` false →
  ## branch skipped), so it needs no companion. Recognises `A`, `B` as bare scalar terms.
  if op notin ["<", "<=", ">", ">="]: return (false, BoundEffect())
  proc asSub(cur: CXCursor): tuple[ok: bool, aKey, aDisp, bKey, bDisp: string, bUns: bool] =
    let u = unwrap(cur)
    if clang_getCursorKind(u) == ckBinaryOperator and ctx.binOperator(u) == "-":
      let kids = collectChildren(u)
      if kids.len == 2:
        let a = ctx.scalarTerm(unwrap(kids[0]))
        let b = ctx.scalarTerm(unwrap(kids[1]))
        if a.ok and b.ok:
          return (true, a.key, a.disp, b.key, b.disp, isUnsignedInteger(unwrap(kids[1])))
    (false, "", "", "", "", false)
  let lc = constIntValue(unwrap(lhs)); let rc = constIntValue(unwrap(rhs))
  var sub: tuple[ok: bool, aKey, aDisp, bKey, bDisp: string, bUns: bool]
  var c: int
  var rel: string
  if rc.known:                                     # `(A - B) op c`
    sub = asSub(lhs); c = int(rc.value); rel = op
  elif lc.known:                                   # `c op (A - B)`  ->  `(A - B) swap(op) c`
    sub = asSub(rhs); c = int(lc.value)
    rel = (case op
           of "<": ">"
           of "<=": ">="
           of ">": "<"
           of ">=": "<="
           else: "")
  else:
    return (false, BoundEffect())
  if not sub.ok or c < 1: return (false, BoundEffect())   # only positive headroom is useful
  var symOff: int
  if rel == ">=": symOff = 1 - c                   # B <= A - c  ->  B < A + (1 - c)
  elif rel == ">": symOff = -c                     # B <  A - c  ->  B < A + (-c)
  else: return (false, BoundEffect())              # `A - B <= c` lower-bounds B — not tracked
  return (true, BoundEffect(key: sub.bKey, isConst: false,
                            symKey: sub.aKey, symDisp: sub.aDisp, symOff: symOff,
                            needsLtCompanion: sub.bUns))

proc reconcileHeadroom(bounds: seq[BoundEffect]): seq[BoundEffect] =
  ## SPATIAL: resolve `sym - key >= k` two-variable bounds (`needsLtCompanion`) against their
  ## sibling conjuncts. A pending bound is credited only when another conjunct on the SAME
  ## branch establishes `key <= sym` (a symbolic upper bound of the same key by the same symbol
  ## with `symOff <= 1`, itself not pending) — otherwise `sym - key` may underflow and the bound
  ## is unsound, so it is dropped. Credited bounds are appended LAST so, under the analyzer's
  ## last-writer-wins per key, the tighter headroom bound wins regardless of source order.
  var credited: seq[BoundEffect]
  for b in bounds:
    if not b.needsLtCompanion: result.add b
  for b in bounds:
    if not b.needsLtCompanion: continue
    var found = false
    for c in result:                               # search the non-pending (normal) bounds
      if c.key == b.key and not c.isConst and not c.isLower and not c.isNeq and
         c.symKey.len > 0 and c.symKey == b.symKey and c.symOff <= 1 and c.onThen == b.onThen:
        found = true; break
    if found:
      var bb = b; bb.needsLtCompanion = false; credited.add bb
  result.add credited

proc addThenBound(ctx: Ctx, c: CXCursor, s: Stmt) =
  ## SPATIAL: add the THEN-branch upper bound(s) of a (sub)condition. Recurses through
  ## `&&` so every conjunct of `if (i >= 0 && i < n)` contributes; never adds an ELSE
  ## bound (the negation of one conjunct is not the if's else). A `!=` conjunct contributes
  ## its disequality lift (`s->cur != -1 && s->cur < 256`). The caller reconciles any
  ## `needsLtCompanion` (two-variable `end - p >= k`) bounds after all conjuncts are collected.
  let cu = unwrap(c)
  if clang_getCursorKind(cu) != ckBinaryOperator: return
  let op = ctx.binOperator(cu)
  let kids = collectChildren(cu)
  if op == "&&":
    for k in kids: ctx.addThenBound(k, s)
    return
  if kids.len != 2: return
  if op == "!=":
    let (has, eff) = ctx.neqBound(kids[0], kids[1])
    if has:
      var e = eff; e.onThen = true; s.condBounds.add e
    return
  let (hasT, effT) = ctx.boundWhenTrue(op, kids[0], kids[1])
  if hasT:
    var e = effT; e.onThen = true; s.condBounds.add e
  else:
    let (hasH, effH) = ctx.subHeadroomBound(op, kids[0], kids[1])   # `end - p >= k`
    if hasH:
      var e = effH; e.onThen = true; s.condBounds.add e

proc addElseBound(ctx: Ctx, c: CXCursor, s: Stmt) =
  ## SPATIAL: add the ELSE-branch bound(s) of a `||` disjunction. By De Morgan the
  ## disjunction is FALSE on the else only when every disjunct is false, so each
  ## disjunct's NEGATED when-true bound holds — `if (i < 0 || i >= n) return;` leaves
  ## `i < n` (and `i >= 0`, a lower bound we don't track) on the fall-through. Recurses
  ## through nested `||`; never adds a THEN bound (the disjunction's then is ambiguous).
  let cu = unwrap(c)
  if clang_getCursorKind(cu) != ckBinaryOperator: return
  let op = ctx.binOperator(cu)
  let kids = collectChildren(cu)
  if op == "||":
    for k in kids: ctx.addElseBound(k, s)
    return
  if kids.len != 2: return
  let nop = negateRel(op)
  if nop.len == 0: return
  let (has, eff) = ctx.boundWhenTrue(nop, kids[0], kids[1])
  if has:
    var e = eff; e.onThen = false; s.condBounds.add e

proc fillBounds(ctx: Ctx, cond: CXCursor, s: Stmt) =
  ## SPATIAL: collect the relational bounds a condition places on a value, per branch.
  ## A `&&` conjunction contributes only THEN bounds (one per conjunct); a `||`
  ## disjunction contributes only ELSE bounds (the negation of each disjunct — so the
  ## reject-guard `if (i < 0 || i >= n) return;` validates the fall-through). A single
  ## relational contributes its THEN bound AND the negated ELSE bound (so `if (x >= N)
  ## return;` validates x on the fall-through). Recognises `v OP lim`, `lim OP v`, and a
  ## `±k` offset on either side; unrecognised shapes add no effect (sound: stays RED).
  let cu = unwrap(cond)
  if clang_getCursorKind(cu) != ckBinaryOperator: return
  let op = ctx.binOperator(cu)
  let kids = collectChildren(cu)
  if op == "&&":
    ctx.addThenBound(cu, s)
    s.condBounds = reconcileHeadroom(s.condBounds)   # credit `end - p >= k` if `p < end` present
    return
  if op == "||":
    ctx.addElseBound(cu, s)
    return
  if kids.len != 2: return
  if op == "!=":                          # `if (x != c)`: lift a known lower bound on the THEN
    let (has, eff) = ctx.neqBound(kids[0], kids[1])
    if has:
      var e = eff; e.onThen = true; s.condBounds.add e
    return
  let (hasT, effT) = ctx.boundWhenTrue(op, kids[0], kids[1])
  if hasT:
    var e = effT; e.onThen = true; s.condBounds.add e
  let nop = negateRel(op)
  if nop.len > 0:
    let (hasE, effE) = ctx.boundWhenTrue(nop, kids[0], kids[1])
    if hasE:
      var e = effE; e.onThen = false; s.condBounds.add e

proc fillTagFacts(ctx: Ctx, cond: CXCursor, s: Stmt) =
  ## TYPE-CONFUSION: collect each `field == const` equality a condition proves on its THEN
  ## branch (a discriminant guard `if (n->tag == 0)`). A `&&` contributes each conjunct. The
  ## type-confusion pass uses these to know a `@variant` member is the active one.
  let cu = unwrap(cond)
  if clang_getCursorKind(cu) != ckBinaryOperator: return
  let op = ctx.binOperator(cu)
  let kids = collectChildren(cu)
  if op == "&&":
    for k in kids: ctx.fillTagFacts(k, s)
    return
  if op == "==" and kids.len == 2:
    let l = unwrap(kids[0]); let r = unwrap(kids[1])
    let lc = constIntValue(l); let rc = constIntValue(r)
    var memberC: CXCursor
    var val = 0
    var ok = false
    if clang_getCursorKind(l) == ckMemberRefExpr and rc.known: memberC = l; val = int(rc.value); ok = true
    elif clang_getCursorKind(r) == ckMemberRefExpr and lc.known: memberC = r; val = int(lc.value); ok = true
    if ok:
      let (k, _) = deepMemberKey(memberC)
      if k.len > 0: s.tagFacts.add (k, val, true)

proc lowerScalarAssign(ctx: Ctx, name, key: string, rhs: CXCursor, line: int,
                       outp: var seq[Stmt], lhsSigned = false) =
  ## SPATIAL: classify a scalar-integer assignment / initializer RHS into a
  ## validated-state event so the bounds pass can follow values through locals:
  ##   * a compile-time constant, or `x % n` / `x & mask`  -> VALIDATED (bounded)
  ##   * `term - k` (k >= 1 const) into a SIGNED target     -> VALIDATED `value < term`
  ##   * a copy of another scalar `m`                       -> inherit m's state
  ##   * anything else (a parameter, a call return, a deref / field read, or other
  ##     arithmetic)                                         -> TAINTED (unvalidated)
  let v = unwrap(rhs)
  let cv = constIntValue(v)
  if cv.known:                                   # value == c  ->  c <= value < c+1
    let c = int(cv.value)
    if c != high(int):                           # skip the (unrepresentable) c+1 upper bound at
      outp.add emit(ikValidate, line, a = name, aKey = key, off = c + 1)  # INT64_MAX — trivial anyway
    outp.add emit(ikLowBound, line, a = name, aKey = key, off = c); return
  let vk = clang_getCursorKind(v)
  if vk == ckBinaryOperator and ctx.binOperator(v) in ["%", "&"]:
    let kids = collectChildren(v)
    let m = (if kids.len == 2: constIntValue(unwrap(kids[1])) else: (known: false, value: 0'i64))
    if m.known:                                  # x % m < m ;  x & mask <= mask < mask+1
      let isMod = ctx.binOperator(v) == "%"
      let mv = int(m.value)
      if isMod:
        outp.add emit(ikValidate, line, a = name, aKey = key, off = mv)
      else:
        if mv != high(int):                      # skip the unrepresentable mask+1 (trivial upper)
          outp.add emit(ikValidate, line, a = name, aKey = key, off = mv + 1)
        # `x & mask` (mask >= 0) is non-negative even for negative x; `x % m` can be negative
        # for a signed x, so only the mask form supplies a lower bound.
        outp.add emit(ikLowBound, line, a = name, aKey = key, off = 0)
      return
    # SYMBOLIC mask `x & mask` where `mask` is an UNSIGNED variable / field (the power-of-two
    # ring-buffer idiom `i & buffer_mask`). ANDing only clears bits, so for a non-negative mask
    # `0 <= x & mask <= mask`, i.e. `result < mask + 1` AND `result >= 0`. The mask IS the
    # runtime bounds check, so recognising it is consistent with the existing `& const` / `% const`
    # validation (kenbi confirms a present check; it never proves one unnecessary). A runtime `%`
    # is NOT bounded this way (left tainted). The named operand must be unsigned (>= 0).
    if ctx.binOperator(v) == "&" and kids.len == 2:
      for mi in [1, 0]:                          # prefer the right operand (the usual `x & mask`)
        let mt = ctx.scalarTerm(unwrap(kids[mi]))
        if mt.ok and isUnsignedInteger(unwrap(kids[mi])):
          outp.add emit(ikValidate, line, a = name, aKey = key,
                        b = mt.disp, bKey = mt.key, off = 1)   # result < mask + 1
          outp.add emit(ikLowBound, line, a = name, aKey = key, off = 0)
          return
    outp.add emit(ikTaint, line, a = name, aKey = key); return   # non-const modulus / unbounded mask
  if vk == ckDeclRefExpr:
    outp.add emit(ikValueCopy, line, a = name, b = spelling(v),
                  aKey = key, bKey = referencedUsr(v)); return
  # `value = term - k` (k >= 1) into a SIGNED target establishes the SYMBOLIC upper bound
  # `value < term + (off + 1)` (off <= -1): value = term + off <= term - 1 < term. Sound for
  # a signed target — even if `term - k` underflows an unsigned `term` to a negative, the
  # signed value is still mathematically < term (the loop/guard supplies the lower bound,
  # the same deferred concern as every signed index). An UNSIGNED target could wrap to a
  # huge value, so it is NOT derived here (left tainted — no false green). This is the
  # reverse-loop idiom `i = toknext - 1` and the `toksuper = toknext - 1` cursor step.
  if lhsSigned:
    let lin = ctx.parseLinear(v)
    if lin.ok and lin.key.len > 0 and lin.off <= -1:
      outp.add emit(ikValidate, line, a = name, aKey = key,
                    b = lin.disp, bKey = lin.key, off = lin.off + 1); return
  outp.add emit(ikTaint, line, a = name, aKey = key)

proc scanGuarded(ctx: Ctx, c: CXCursor, outp: var seq[Stmt]) =
  ## CONCURRENCY: emit ikGuardedAccess for any `@guarded_by` field read/written in `c`. A
  ## no-op (zero cost) when neither a per-function two-arg field (curGuarded) nor a single-arg
  ## struct-member binding (guardedMember) is in play.
  if ctx.curGuarded.len == 0 and ctx.guardedMember.len == 0: return
  var seen = initHashSet[string]()
  ctx.scanGuardedAccess(c, outp, seen)

proc scanInitEffects(ctx: Ctx, c: CXCursor, outp: var seq[Stmt]) =
  ## INIT (definite-assignment): emit ikInitRead for a READ of a declared-uninit local and
  ## ikInitWrite where one becomes assigned. Reads are emitted in evaluation order BEFORE the
  ## write of an assignment (`v = rhs` reads rhs, then assigns v). `&v` = assigned (a callee may
  ## initialise it — conservative). A compound `v += …` / `v++` reads then writes.
  let k = clang_getCursorKind(c)
  let kids = collectChildren(c)
  case k
  of ckDeclRefExpr:
    let key = referencedUsr(c)
    if key in ctx.uninitLocals:
      outp.add emit(ikInitRead, startLine(c), a = spelling(c), aKey = key)
  of ckUnaryOperator:
    if ctx.firstTokenSpelling(c) == "&" and kids.len >= 1:
      let o = unwrap(kids[0])                    # `&v`: address escapes -> assume assigned
      if clang_getCursorKind(o) == ckDeclRefExpr and referencedUsr(o) in ctx.uninitLocals:
        outp.add emit(ikInitWrite, startLine(c), a = spelling(o), aKey = referencedUsr(o))
        return
    let d = ctx.incDecDelta(c)
    if d != 0 and kids.len >= 1:                 # `v++`/`--v`: a read then a write
      let o = unwrap(kids[0])
      if clang_getCursorKind(o) == ckDeclRefExpr and referencedUsr(o) in ctx.uninitLocals:
        let key = referencedUsr(o)
        outp.add emit(ikInitRead, startLine(c), a = spelling(o), aKey = key)
        outp.add emit(ikInitWrite, startLine(c), a = spelling(o), aKey = key)
        return
    for ch in kids: ctx.scanInitEffects(ch, outp)
  of ckBinaryOperator:
    if ctx.binOperator(c) == "=" and kids.len == 2:
      ctx.scanInitEffects(kids[1], outp)         # RHS reads first
      let lhs = unwrap(kids[0])
      if clang_getCursorKind(lhs) == ckDeclRefExpr and referencedUsr(lhs) in ctx.uninitLocals:
        outp.add emit(ikInitWrite, startLine(c), a = spelling(lhs), aKey = referencedUsr(lhs))
      else:
        ctx.scanInitEffects(kids[0], outp)       # `arr[i]=` / `*p=` / `s->f=` have their own reads
    else:
      for ch in kids: ctx.scanInitEffects(ch, outp)
  of ckCompoundAssign:
    if kids.len == 2:
      ctx.scanInitEffects(kids[1], outp)
      let lhs = unwrap(kids[0])
      if clang_getCursorKind(lhs) == ckDeclRefExpr and referencedUsr(lhs) in ctx.uninitLocals:
        let key = referencedUsr(lhs)             # `v += …`: read then write
        outp.add emit(ikInitRead, startLine(c), a = spelling(lhs), aKey = key)
        outp.add emit(ikInitWrite, startLine(c), a = spelling(lhs), aKey = key)
      else:
        ctx.scanInitEffects(kids[0], outp)
    else:
      for ch in kids: ctx.scanInitEffects(ch, outp)
  else:
    for ch in kids: ctx.scanInitEffects(ch, outp)

proc scanInit(ctx: Ctx, c: CXCursor, outp: var seq[Stmt]) =
  ## INIT: emit definite-assignment effects for a statement. No-op (zero cost) until the
  ## function has declared an uninitialised local.
  if ctx.uninitLocals.len == 0: return
  ctx.scanInitEffects(c, outp)

proc scanVariantAccess(ctx: Ctx, c: CXCursor, outp: var seq[Stmt], seen: var HashSet[string]) =
  ## TYPE-CONFUSION: emit ikVariantAccess for each read/write of a `@variant` union member in an
  ## expression subtree, so the pass requires its discriminant proven. Deduped per statement.
  if clang_getCursorKind(c) == ckMemberRefExpr:
    let (k, d) = deepMemberKey(c)
    if k.len > 0 and k in ctx.curVariants and k notin seen:
      seen.incl k
      let v = ctx.curVariants[k]
      outp.add emit(ikVariantAccess, startLine(c), a = d, aKey = k,
                    b = v.tagDisp, bKey = v.tagKey, off = v.value)
  for ch in collectChildren(c): ctx.scanVariantAccess(ch, outp, seen)

proc scanVariant(ctx: Ctx, c: CXCursor, outp: var seq[Stmt]) =
  ## TYPE-CONFUSION: emit variant-access sinks for a statement. No-op until the function
  ## declares a `@variant`.
  if ctx.curVariants.len == 0: return
  var seen = initHashSet[string]()
  ctx.scanVariantAccess(c, outp, seen)

proc ownerTypeName(ctx: Ctx, c: CXCursor): tuple[name, raw: string] =
  ## The owner class a declaration's type names: the type as WRITTEN, or — when that is
  ## `auto` or an alias — its canonical form (`auto up = std::make_unique<int>(1)` is a
  ## unique_ptr; a typedef of an `@raii` class is that class). `raw` is the spelling of the
  ## form that matched, keeping the reference decorations for the parameter-ownership rule.
  let t = clang_getCursorType(c)
  let spelled = $clang_getTypeSpelling(t)
  let n1 = raiiBaseName(spelled)
  if n1 in ctx.raiiTypes or n1 in ctx.structOwnerFields: return (n1, spelled)
  let canon = $clang_getTypeSpelling(clang_getCanonicalType(t))
  let n2 = raiiBaseName(canon)
  if n2 in ctx.raiiTypes or n2 in ctx.structOwnerFields: return (n2, canon)
  (n1, spelled)

proc lowerStmt(ctx: var Ctx, c: CXCursor, outp: var seq[Stmt]) =
  let k = clang_getCursorKind(c)
  case k
  of ckDeclStmt:
    for d in collectChildren(c):
      if clang_getCursorKind(d) == ckVarDecl:
        # record stack locals so a later `&d` / `return d` escape is decidable.
        if hasAutomaticStorage(d):
          ctx.localVars.incl usr(d)
          if isArrayType(d): ctx.localArrayVars.incl usr(d)
          if isPointerType(d): ctx.prog.localPtrVars.incl usr(d)
        ctx.varKeys[spelling(d)] = usr(d)   # so `@drains(head)` reaches this handle by name
        let pn = pointeeRecordName(d)       # so `@list <Type>` reaches its allocations
        if pn.len > 0: ctx.varTypes[usr(d)] = pn
        let kids = collectChildren(d)
        # `auto v = [..]{ ... }` — the body runs at each `v()`, not here: lower it into
        # lambdaBodies and emit nothing at the definition (see the lambdaCall block).
        if kids.len > 0 and clang_getCursorKind(unwrap(kids[^1])) == ckLambdaExpr:
          let lam = unwrap(kids[^1])
          let lb = collectChildren(lam)
          if lb.len >= 1:
            ctx.lambdaBodies[usr(d)] = ctx.lowerBody(@[lb[^1]])
            if ctx.holdsMemoryOp(lam): ctx.lambdaMemOp.incl usr(d)
          continue
        # A C++ REFERENCE local bound to a variable (`char *&dataRef = data;`) IS that variable
        # for its whole lifetime (never reseated): its uses resolve to the referred variable's
        # key (keyAlias) — `dataRef = malloc()` allocates `data`, `q = dataRef` copies it.
        if kids.len > 0 and "&" in $clang_getTypeSpelling(clang_getCursorType(d)) and
           clang_getCursorKind(unwrap(kids[^1])) == ckDeclRefExpr:
          keyAlias[usr(d)] = referencedUsr(unwrap(kids[^1]))
          continue
        # INIT (definite-assignment): a scalar/pointer local declared WITHOUT an initializer is
        # a candidate — its reads are checked until it is definitely assigned. (Its candidacy is
        # implicit: reads are instrumented only for uninitLocals, so no decl marker is needed.)
        if hasAutomaticStorage(d) and (isIntegerType(d) or isPointerType(d)) and not isArrayType(d):
          let hasInit = kids.len > 0 and clang_getCursorKind(kids[^1]) notin {ckTypeRef, ckParmDecl}
          if not hasInit: ctx.uninitLocals.incl usr(d)
        # RAII (`@raii` class): constructing a local of a declared owner type creates an owned
        # origin its destructor releases at scope exit — the construction IS the allocation, so
        # the ordinary initializer lowering is skipped (ctor arguments are not a pointer store).
        if hasAutomaticStorage(d) and ctx.raiiTypes.len > 0:
          let tn = ctx.ownerTypeName(d).name
          if tn in ctx.raiiTypes:
            if kids.len > 0: ctx.scanMayThrow(kids[^1], outp)   # a throwing factory / `new`
            let mvs = (if kids.len > 0: ctx.ownedOperandsIn(kids[^1]) else: @[])
            ctx.tracked[usr(d)] = true
            ctx.raiiVars[usr(d)] = tn
            if mvs.len == 1 and ctx.raiiVars.getOrDefault(mvs[0].key, "") == tn:
              # `T y = std::move(x)` between owners of the same class: the resource stays in
              # view — y holds it now (a borrow taken from x stays valid); only the handle x is
              # moved-from. Not a fresh origin.
              outp.add emit(ikRaiiMove, startLine(d), a = mvs[0].disp, b = spelling(d),
                            aKey = mvs[0].key, bKey = usr(d))
              continue
            # what the new owner takes: a RAW handle (`unique_ptr<T> up(p)`) is moved out of its
            # own origin and re-pointed as a BORROW of the new owner (`*p` stays valid; `free(p)`
            # is FREE_INTERIOR — the owner releases it); an owner of another class is moved out.
            for mv in mvs: ctx.moveOwner(mv.key, mv.disp, startLine(d), outp)
            outp.add emit(ikRaiiAlloc, startLine(d), a = spelling(d), b = tn, aKey = usr(d))
            for mv in mvs:
              if mv.key notin ctx.raiiVars and mv.key notin ctx.structOwnerVars and
                 ctx.tracked.getOrDefault(mv.key, false):
                outp.add emit(ikInterior, startLine(d), a = mv.disp, b = spelling(d),
                              aKey = mv.key, bKey = usr(d))
            continue
          if tn in ctx.structOwnerFields:
            # a local STRUCT that holds owner fields: each owner field is its own RAII origin,
            # keyed as the field path (`h->p`) and released by the struct's destructor (never a
            # leak). A move-initialisation from another such struct moves every owner field of
            # the source first. The ordinary initializer lowering still runs for call arguments.
            var fields: seq[tuple[key, disp: string]]
            for f in ctx.structOwnerFields[tn]:
              let fk = usr(d) & "::" & f.name
              ctx.tracked[fk] = true
              ctx.raiiVars[fk] = f.cls
              fields.add (fk, spelling(d) & "->" & f.name)
            ctx.structOwnerVars[usr(d)] = fields
            let mvs = (if kids.len > 0: ctx.ownedOperandsIn(kids[^1]) else: @[])
            if mvs.len == 1 and mvs[0].key in ctx.structOwnerVars and
               ctx.structOwnerVars[mvs[0].key].len == fields.len:
              # `Holder g = std::move(h)`: each owner field of h moves into the same field of g —
              # the resources stay in view, only h's handles are moved-from.
              let src = ctx.structOwnerVars[mvs[0].key]
              for i, f in fields:
                outp.add emit(ikRaiiMove, startLine(d), a = src[i].disp, b = f.disp,
                              aKey = src[i].key, bKey = f.key)
              continue
            for mv in mvs: ctx.moveOwner(mv.key, mv.disp, startLine(d), outp)
            for f in fields:
              outp.add emit(ikRaiiAlloc, startLine(d), a = f.disp, b = ctx.raiiVars[f.key], aKey = f.key)
        # initializer is the last expression child, if any
        if kids.len > 0:
          let init = kids[^1]
          let ik = clang_getCursorKind(init)
          if ik != ckParmDecl:
            ctx.lowerAssign(spelling(d), usr(d), init, startLine(d), outp)
            ctx.scanDerefs(init, outp)
            ctx.scanInvariantWrites(init, outp)
            ctx.scanGuarded(init, outp)
            ctx.scanInit(init, outp)             # reads of an uninit local in the initializer
            ctx.scanVariant(init, outp)
            if isIntegerType(d):    # SPATIAL: follow scalar-integer dataflow
              ctx.lowerScalarAssign(spelling(d), usr(d), init, startLine(d), outp,
                                    lhsSigned = not isUnsignedInteger(d))
        # a decl-marker annotation (@nullable / @nonnull) on this line -> its IR
        let dl = startLine(d)
        if dl in ctx.declMarkers: outp.add emit(ctx.declMarkers[dl], dl, a = spelling(d), aKey = usr(d))
  of ckBinaryOperator, ckCompoundAssign:
    let op = ctx.binOperator(c)
    # A PROTECTED field's spatial re-taint is DEFERRED until after the invariant maintains check
    # below reads the pre-write guard bound (`len = len + 1` under `if (len < cap)`): the taint
    # clears stale guard bounds, which must happen AFTER, not before, the maintains verification.
    var deferFk, deferFd: string
    var deferRhs: CXCursor
    var deferSigned = false
    if op == "=":
      let kids = collectChildren(c)
      if kids.len == 2:
        let lhs = unwrap(kids[0])
        if clang_getCursorKind(lhs) == ckDeclRefExpr:
          ctx.lowerAssign(spelling(lhs), referencedUsr(lhs), kids[1], startLine(c), outp)
          if ctx.ownsOutParams.getOrDefault(referencedUsr(lhs), "-") == "":
            # `data = malloc(...)` on a `@owns(data)` reference parameter: the declared hand-out
            # to the caller — the obligation leaves through the parameter, not a leak here.
            ctx.prog.escapesLines.incl startLine(c)
            outp.add emit(ikEscape, startLine(c), a = spelling(lhs), aKey = referencedUsr(lhs))
          if isIntegerType(lhs):   # SPATIAL: follow scalar-integer dataflow
            ctx.lowerScalarAssign(spelling(lhs), referencedUsr(lhs), kids[1], startLine(c), outp,
                                  lhsSigned = not isUnsignedInteger(lhs))
        elif ctx.containerStoreTarget(lhs).has:
          # `m[k] = p` on a STANDARD associative container: the container takes the owned
          # pointer into its element slot, exactly like `v.push_back(p)` (Juliet 74).
          let tgt = ctx.containerStoreTarget(lhs)
          let rhs = unwrap(kids[1])
          if clang_getCursorKind(rhs) == ckDeclRefExpr and
             ctx.tracked.getOrDefault(referencedUsr(rhs), false):
            let isLocal = tgt.baseKey in ctx.localVars
            outp.add emit(ikFieldStore, startLine(c), a = spelling(rhs), aKey = referencedUsr(rhs),
                          b = tgt.slotDisp, bKey = tgt.slotKey,
                          cKey = tgt.baseKey, off = (if isLocal: 1 else: 0))
            ctx.tracked[tgt.slotKey] = true
            ctx.slotRes[tgt.slotKey] = ctx.resourceFor(spelling(rhs), startLine(c))
            if isLocal: ctx.fieldBaseVars.incl tgt.baseKey
        elif ctx.addrStoreTarget(lhs).has:
          # `*dataPtr = x` with `dataPtr = &data`: an assignment to the local `data` itself
          let at = ctx.addrStoreTarget(lhs)
          ctx.lowerAssign(at.disp, at.key, kids[1], startLine(c), outp)
        else:
          let (fk, fd) = fieldPath(lhs)
          let rhs = unwrap(kids[1])
          let rk = clang_getCursorKind(rhs)
          # `base->field = realloc(base->field, n)` CONTINUES the field's obligation (realloc
          # extends or moves the SAME buffer) — it is NOT a fresh allocation, so it must not
          # overwrite-leak the field. Only a SELF-realloc is exempt; `field = realloc(other, n)`
          # genuinely orphans the old field buffer (a real leak) and falls through unchanged.
          var reallocSelf = false
          # A project's OWN resize (`@allocator … { realloc: ResizeQuantumMemory }`) is a
          # realloc like the builtin — the plain-variable path already treats the two alike.
          # The field path checked the builtin NAME only, so `b->f = ResizeQuantumMemory(b->f,…)`
          # lowered as a FRESH allocation into a field that (per the flow-insensitive tracking)
          # already owned something, and the overwrite rule called the growth a leak of the old
          # buffer. Every hand-rolled grow-in-place on a struct field read that way.
          if fk.len > 0 and rk == ckCallExpr and
             (spelling(rhs) == "realloc" or spelling(rhs) in ctx.customRealloc):
            let rkids = collectChildren(rhs)
            if rkids.len >= 2:
              let a = unwrap(rkids[1])
              let ak = (if clang_getCursorKind(a) == ckDeclRefExpr: referencedUsr(a)
                        elif clang_getCursorKind(a) == ckMemberRefExpr: fieldPath(a).key
                        else: "")
              reallocSelf = ak.len > 0 and ak == fk
          if reallocSelf:
            # `b->field = realloc(b->field, n)`: the field keeps its obligation across the in-place
            # realloc (success path), but the self-assignment hides the OOM failure path — on NULL
            # the only handle to the original field block is overwritten and it leaks. Flag it when
            # the field is tracked here (its origin is known); an untracked / caller-owned field
            # stays deferred (#2). REALLOC_SELF_REASSIGN, same as the plain-variable twin.
            if fk.len > 0 and ctx.tracked.getOrDefault(fk, false):
              outp.add emit(ikRealloc, startLine(c), a = fd, aKey = fk)
          elif fk.len > 0 and (rk == ckCXXNewExpr or (rk == ckCallExpr and
                 (spelling(rhs) in allocators or spelling(rhs) in ctx.customAllocRes))):
            # `base->field = malloc(...)`: track the field path for double-free / UAF.
            let bi = fieldBaseInfo(lhs)
            # ...unless the field IS the declared `link:` of the base's record type. Then this is
            # not a field the base owns, it is the NEXT ELEMENT of the intrusive collection the
            # base is already part of (`cur->next = Acquire(...); cur = cur->next;` — how every
            # hand-built C list grows). The collection's origin already stands for the whole
            # chain and is discharged by its declared `@drains` loop, so appending to it creates
            # no second obligation. Without this the append read as a field the local owned, and
            # every list-building loop leaked once per node.
            let baseTy = ctx.varTypes.getOrDefault(bi.key, "")
            let isLinkAppend = baseTy.len > 0 and
                               ctx.listTypes.getOrDefault(baseTy, "") == spelling(lhs)
            if isLinkAppend:
              ctx.tracked[fk] = true      # the link still reads as a handle into the collection
            else:
              outp.add emit(ikFieldAlloc, startLine(c), a = fd,
                            b = (if rk == ckCallExpr and spelling(rhs) in ctx.customAllocRes:
                                   ctx.customAllocRes[spelling(rhs)]
                                 else: ctx.resourceFor(spelling(lhs), startLine(c))), aKey = fk,
                            cKey = bi.key, off = (if bi.isLocal: 1 else: 0))
              ctx.tracked[fk] = true
              if bi.isLocal: ctx.fieldBaseVars.incl bi.key
          elif rk == ckDeclRefExpr and ctx.tracked.getOrDefault(referencedUsr(rhs), false):
            if fk.len > 0:
              # `b->buf = p`: the FIELD takes ownership of the tracked pointer. Re-key the origin
              # to the field so double-free / use-after-free THROUGH `b->buf` is checked (like a
              # direct `b->buf = malloc`), instead of dropping tracking with an advisory.
              let bi = fieldBaseInfo(lhs)
              outp.add emit(ikFieldStore, startLine(c), a = spelling(rhs),
                            aKey = referencedUsr(rhs), b = fd, bKey = fk,
                            cKey = bi.key, off = (if bi.isLocal: 1 else: 0))
              ctx.tracked[fk] = true
              if bi.isLocal: ctx.fieldBaseVars.incl bi.key
            else:
              # stored into a non-field untracked location (`*p` / `arr[i]`) -> escape
              # (not a false leak; the obligation leaves our view -> advisory). Through the
              # pointee of a `@owns(*p)` out-parameter it is the DECLARED hand-out to the caller.
              if clang_getCursorKind(lhs) == ckUnaryOperator and ctx.firstTokenSpelling(lhs) == "*":
                let bk = collectChildren(lhs)
                if bk.len >= 1 and clang_getCursorKind(unwrap(bk[0])) == ckDeclRefExpr and
                   ctx.ownsOutParams.getOrDefault(referencedUsr(unwrap(bk[0])), "-") == "*":
                  ctx.prog.escapesLines.incl startLine(c)
              outp.add emit(ikEscape, startLine(c), a = spelling(rhs), aKey = referencedUsr(rhs))
          elif fk.len > 0 and isIntegerType(lhs):   # SPATIAL: an integer field is reassigned
            # follow the field's scalar dataflow so a guard's validation does not persist
            # stale across `s->len = <untrusted>` (a re-tainted field stays default-red). For a
            # PROTECTED field, defer this until after the maintains check (see above) — UNLESS it
            # is a SELF inc/dec (`len = len ± k`), where the maintains check itself sets the new
            # bound (a re-taint would discard the tightened post-decrement `len < cap`).
            let selfMod = block:
              let l = ctx.parseLinear(kids[1]); l.ok and l.key == fk
            if (fk in ctx.curProtected or fk in ctx.curProtectedLow) and not selfMod:
              deferFk = fk; deferFd = fd; deferRhs = kids[1]; deferSigned = not isUnsignedInteger(lhs)
            elif fk notin ctx.curProtected and fk notin ctx.curProtectedLow:
              ctx.lowerScalarAssign(fd, fk, kids[1], startLine(c), outp,
                                    lhsSigned = not isUnsignedInteger(lhs))
    else:
      # `p += n` / `p -= n` on a tracked pointer advances it -> interior pointer.
      let adv = ctx.advancesTrackedPointer(c)
      if adv.key.len > 0:
        outp.add emit(ikInterior, startLine(c), a = adv.name, b = adv.name,
                      aKey = adv.key, bKey = adv.key, off = ctx.advanceStep(c))
      else:
        # SPATIAL: a compound mutation (`i += k`, `i <<= …`) on a scalar integer makes
        # it unvalidated again (it may now exceed any earlier bound — off-by-one). In a
        # loop the cond re-validates at the body top, so this only de-validates straight
        # line / post-loop uses. `i &= mask` / `i %= n` keep it bounded.
        let kids = collectChildren(c)
        if kids.len >= 1:
          let lhs = unwrap(kids[0])
          if clang_getCursorKind(lhs) == ckDeclRefExpr and isIntegerType(lhs):
            if op in ["&=", "%="]:
              outp.add emit(ikValidate, startLine(c), a = spelling(lhs), aKey = referencedUsr(lhs))
            else:
              outp.add emit(ikTaint, startLine(c), a = spelling(lhs), aKey = referencedUsr(lhs))
        # ...and a CALL on the right of a compound assignment still passes its arguments across
        # the boundary: `status &= AppendValueToLinkedList(cache, log_info);` hands the object to
        # the container exactly as the plain-statement form does. Without this the escape went
        # unreported and the pointer looked abandoned — a false LEAK, and worse, an ownership
        # hand-off kenbi never asked about (ImageMagick's log.c / locale.c build their caches
        # this way).
        if clang_getCursorKind(c) == ckCompoundAssign:      # a REAL `&=` / `+=` …, by kind:
          for kid in collectChildren(c)[1 .. ^1]:            # an unreadable operator inside a
            ctx.lowerExprCalls(kid, outp)                    # macro must not land here
        elif op == ",":
          # A comma at statement level is a sequence: each operand is evaluated, left to right,
          # as if it were a statement of its own (`free(p), p = NULL;`).
          for kid in collectChildren(c): ctx.lowerStmt(kid, outp)
        elif ctx.holdsMemoryOp(c):
          # Any other operator at statement level — a comparison, or an operator kenbi could
          # not read — is not lowered here, so an allocation or a release inside it would vanish
          # with it. Refuse it instead.
          outp.add emit(ikUnsupportedConstruct, startLine(c), a = "expression")
    ctx.scanDerefs(c, outp)
    ctx.scanInvariantWrites(c, outp)
    if deferFk.len > 0:                          # protected-field re-taint, AFTER the maintains check
      ctx.lowerScalarAssign(deferFd, deferFk, deferRhs, startLine(c), outp, lhsSigned = deferSigned)
    ctx.scanGuarded(c, outp)
    ctx.scanInit(c, outp)
    ctx.scanVariant(c, outp)
  of ckCStyleCastExpr:
    # `(void) f(p);` — C's way of saying "I am deliberately discarding this result", used on
    # nearly every call in some codebases. The statement was DROPPED whole, so a declared
    # `@frees` on that call never applied and the release that followed read as the only one:
    # a missed double free. The call's effects are lowered exactly as a bare call's; the
    # discard is explicit here, so it is not an UNUSED_MUST_USE.
    let inner = unwrap(c)
    if clang_getCursorKind(inner) == ckCallExpr:
      ctx.lowerCall(inner, startLine(c), outp)
    else:
      ctx.lowerExprCalls(c, outp)
    ctx.scanDerefs(c, outp)
    ctx.scanInvariantWrites(c, outp)
    ctx.scanGuarded(c, outp)
    ctx.scanInit(c, outp)
    ctx.scanVariant(c, outp)
  of ckCallExpr:
    # a call standing alone as a statement discards its result; if the callee is
    # declared `@must_use`, dropping it is the finding (ignored error code, leaked
    # allocation, …). Nested calls (assigned / returned / passed as args) reach
    # the front-end through lowerAssign / lowerCall, never here, so they're safe.
    if spelling(c) in ctx.funcFlags:
      outp.add emit(ikMustUse, startLine(c), a = spelling(c))
    ctx.lowerCall(c, startLine(c), outp)
    ctx.scanDerefs(c, outp)
    ctx.scanInvariantWrites(c, outp)
    ctx.scanGuarded(c, outp)
    ctx.scanInit(c, outp)
    ctx.scanVariant(c, outp)
  of ckReturnStmt:
    ctx.scanDerefs(c, outp)
    ctx.scanInvariantWrites(c, outp)
    ctx.scanGuarded(c, outp)
    ctx.scanInit(c, outp)
    ctx.scanVariant(c, outp)
    let kids = collectChildren(c)
    # a call in the RETURN expression (`return take(p);`, `return check(use(p));`) lowers its
    # argument effects before the exit — otherwise an owned arg it moves/escapes is left owned
    # and FALSE-LEAKs at this very return. The returned VALUE itself is handled below.
    if kids.len >= 1: ctx.lowerExprCalls(kids[0], outp)
    if kids.len >= 1:
      let r = unwrap(kids[0])
      let local = ctx.pointsIntoLocal(r)
      if local.yes:
        # returning a pointer into a local: synthesise a localAddr temp and
        # return it so the engine reports DANGLING_RETURN at this line.
        let tk = "$ret@" & $startLine(c)
        outp.add emit(ikLocalAddr, startLine(c), a = local.disp, aKey = tk)
        outp.add emit(ikReturn, startLine(c), a = local.disp, aKey = tk)
        return
      if clang_getCursorKind(r) == ckDeclRefExpr:
        # returning a named tracked pointer: the engine checks it for a freed
        # (dangling) return and discharges the transferred owned obligation.
        let key = referencedUsr(r)
        if ctx.tracked.getOrDefault(key, false):
          outp.add emit(ikReturn, startLine(c), a = spelling(r), aKey = key)
          return
        if key in ctx.fieldBaseVars:
          # `return b` of a whole struct that owns fields: a self-evident transfer — the
          # container carries its fields' obligations to the caller, so they don't leak (#2b).
          outp.add emit(ikFieldBaseEscape, startLine(c), a = spelling(r), aKey = key)
          outp.add emit(ikReturn, startLine(c))
          return
      if clang_getCursorKind(r) == ckMemberRefExpr:
        # returning a field path `return b->buf`: the field VALUE transfers to the caller,
        # so discharge the field origin (else it would false-leak at scope exit, #2b). A
        # freed field returned is still a dangling return (checkReturn decides).
        let (fk, fd) = fieldPath(r)
        if fk.len > 0 and ctx.tracked.getOrDefault(fk, false):
          outp.add emit(ikReturn, startLine(c), a = fd, aKey = fk)
          return
      if clang_getCursorKind(r) == ckUnaryOperator and ctx.firstTokenSpelling(r) == "&":
        # `return &b->member` / `return &b.member` where `b` is a tracked allocation: handing
        # out the address of a MEMBER is how C hands out a handle to the whole block — the
        # public view is the first member and the caller releases the object through that
        # pointer (ImageMagick's XMLTreeRoot behind XMLTreeInfo, GObject, every embedded-struct
        # "inheritance" in C). The block is reachable from what the caller now holds, so this
        # is the same transfer `return b` is, fields included; calling it a leak was wrong.
        let kids2 = collectChildren(r)
        if kids2.len >= 1:
          let m = unwrap(kids2[0])
          if clang_getCursorKind(m) == ckMemberRefExpr:
            let mk = collectChildren(m)
            if mk.len >= 1:
              let base = unwrap(mk[0])
              if clang_getCursorKind(base) == ckDeclRefExpr:
                let bkey = referencedUsr(base)
                if ctx.tracked.getOrDefault(bkey, false):
                  # the container's own fields travel with it, exactly as for `return b`
                  outp.add emit(ikFieldBaseEscape, startLine(c), a = spelling(base), aKey = bkey)
                  outp.add emit(ikReturn, startLine(c), a = spelling(base), aKey = bkey)
                  return
    outp.add emit(ikReturn, startLine(c))
  of ckUnaryOperator, ckArraySubscriptExpr, ckMemberRefExpr:
    let adv = ctx.advancesTrackedPointer(c)
    if adv.key.len > 0:
      outp.add emit(ikInterior, startLine(c), a = adv.name, b = adv.name,
                    aKey = adv.key, bKey = adv.key, off = ctx.advanceStep(c))
    ctx.scanDerefs(c, outp)
    ctx.scanInvariantWrites(c, outp)
    ctx.scanGuarded(c, outp)
    ctx.scanInit(c, outp)
    ctx.scanVariant(c, outp)
  of ckCXXDeleteExpr:
    # `delete p` / `delete[] p` -> free of the operand variable, or of a tracked field path
    # (`delete this->data` in a destructor, `delete s.p`, `delete arr[2]`)
    for k in collectChildren(c):
      let a = unwrap(k)
      # Deleting an object through a pointer to a base class whose destructor is not virtual is
      # undefined behaviour: the derived destructor does not run, and whatever it releases leaks.
      # Definite when the object was constructed here as a derived class; when its dynamic type
      # is not in view, unverifiable if the class is a base of any class (default-red).
      let cls = classDefOfPointee(a)
      if clang_Cursor_isNull(cls) == 0 and not hasVirtualDestructor(cls):
        let dyn = (if clang_getCursorKind(a) == ckDeclRefExpr:
                     ctx.newClass.getOrDefault(referencedUsr(a), "") else: "")
        let disp = (if clang_getCursorKind(a) == ckDeclRefExpr: spelling(a) else: fieldPath(a)[1])
        if dyn.len > 0 and dyn != usr(cls):
          outp.add emit(ikNonVirtualDelete, startLine(c), a = disp, b = spelling(cls), off = 1)
        elif dyn.len == 0 and usr(cls) in ctx.baseClasses:
          outp.add emit(ikNonVirtualDelete, startLine(c), a = disp, b = spelling(cls), off = 0)
      if clang_getCursorKind(a) == ckDeclRefExpr:
        let key = referencedUsr(a)
        if ctx.tracked.getOrDefault(key, false):
          outp.add emit(ikFree, startLine(c), a = spelling(a), b = "delete", aKey = key)
        # A release of something kenbi cannot account for is default-red whichever spelling it
        # has. `free(p)` on an untracked operand already lowered to the intake ladder — an
        # undeclared incoming parameter to UNCONTRACTED_RELEASE, any other untracked handle to
        # ikUnaccountedFree — but `delete p` emitted NOTHING, so the engine never saw a release
        # at all and the strongest guarantee in the checker did not apply to half of C++.
        elif key in ctx.incomingPtrs:
          outp.add emit(ikFree, startLine(c), a = spelling(a), aKey = key)
        elif key.len > 0:
          outp.add emit(ikUnaccountedFree, startLine(c), a = spelling(a), aKey = key)
      else:
        let (fk, fd) = fieldPath(a)
        if fk.len > 0 and ctx.tracked.getOrDefault(fk, false):
          outp.add emit(ikFree, startLine(c), a = fd, b = "delete", aKey = fk)
  of ckUnexposedExpr, ckParenExpr:
    let u = unwrap(c)
    if clang_getCursorKind(u) != k:
      ctx.lowerStmt(u, outp)
  of ckIfStmt:
    let kids = collectChildren(c)
    # IfStmt children: [cond, then, (else)]
    if kids.len >= 1:
      ctx.scanDerefs(kids[0], outp)   # derefs in the condition run before the branch
      ctx.lowerExprCalls(kids[0], outp)  # and any call in the condition escapes/contracts its args
    # Constant-condition fold: `if(1)` / `if(0)` / `if(5==5)` / a `const` flag has
    # a dead branch. Lower ONLY the live branch inline so the impossible path's
    # (non-)free is not analysed — otherwise `if(1){ free(p); }` looks like a leak
    # on the never-taken else path (a false positive on Juliet's flow variants).
    let cond = ctx.foldCond(kids[0])
    if cond.known:
      if cond.value != 0:
        if kids.len >= 2:
          for st in ctx.lowerBody(@[kids[1]]): outp.add st
      elif kids.len >= 3:
        for st in ctx.lowerBody(@[kids[2]]): outp.add st
      return
    var s = Stmt(line: startLine(c), kind: stIf)
    if kids.len >= 1:
      ctx.parseNullCond(kids[0], s)
      ctx.parsePredCond(kids[0], s)   # CORRELATED BRANCHES: a stable scalar this tests
      ctx.collectNonNullFacts(kids[0], s, false)
    if kids.len >= 1: ctx.fillBounds(kids[0], s)
    if kids.len >= 1: ctx.fillTagFacts(kids[0], s)
    if kids.len >= 1: ctx.parseTrylockCond(kids[0], s)
    if kids.len >= 1: ctx.parsePtrCmpCond(kids[0], s)
    if kids.len >= 2:
      s.thenBody = ctx.lowerBody(@[kids[1]])
    if kids.len >= 3:
      s.elseBody = ctx.lowerBody(@[kids[2]])
    outp.add s
  of ckSwitchStmt:
    # SwitchStmt children: [cond, body(CompoundStmt)]. Group the body's statements
    # into per-case bodies (a CaseStmt's child begins a group; following siblings
    # append until the next label). Each group becomes an independent branch.
    let kids = collectChildren(c)
    if kids.len >= 1:
      ctx.scanDerefs(kids[0], outp)   # derefs in the condition
      ctx.lowerExprCalls(kids[0], outp)  # a call in `switch (f(p))` escapes/contracts its args
    var bodyCur: CXCursor
    var hasBody = false
    for ch in kids:
      if clang_getCursorKind(ch) == ckCompoundStmt: bodyCur = ch; hasBody = true
    if hasBody:
      var s = Stmt(line: startLine(c), kind: stSwitch)
      # TYPE-CONFUSION: the discriminant the switch is on (`switch (n->tag)`), so each
      # `case VALUE:` proves `n->tag == VALUE` in its body.
      if kids.len >= 1:
        let condc = unwrap(kids[0])
        if clang_getCursorKind(condc) == ckMemberRefExpr:
          let (k, d) = deepMemberKey(condc)
          s.switchKey = k; s.switchDisp = d
        # CORRELATED BRANCHES: a switch on a STABLE scalar constrains every later switch on it.
        # ImageMagick's `AcquireKernelBuiltIn` has two `switch (type)` in a row, and analysing
        # the second without the first left an allocation live on a path that cannot reach it.
        s.switchPredKey = ctx.stablePredKey(condc)
      var groups: seq[seq[CXCursor]]
      var groupVals: seq[int]
      var groupIsDefault: seq[bool]
      var cur: seq[CXCursor]
      var pendingVal = low(int)                # the single const value of the group accumulating
      var pendingDefault = false               # the group accumulating carries a `default:` label
      for child in collectChildren(bodyCur):
        let ck = clang_getCursorKind(child)
        if ck == ckCaseStmt or ck == ckDefaultStmt:
          if ck == ckDefaultStmt: s.hasDefault = true
          if cur.len > 0: groups.add cur; groupVals.add pendingVal; groupIsDefault.add pendingDefault
          cur = @[]
          pendingDefault = (ck == ckDefaultStmt)
          var cs = child                       # unwrap (possibly nested) labels
          var labelCount = 0
          var caseVal = low(int)
          while clang_getCursorKind(cs) == ckCaseStmt or clang_getCursorKind(cs) == ckDefaultStmt:
            if clang_getCursorKind(cs) == ckCaseStmt:
              inc labelCount
              let lk = collectChildren(cs)
              if lk.len >= 1:
                let v = constIntValue(unwrap(lk[0]))
                if v.known: caseVal = int(v.value)
            let cks = collectChildren(cs)
            if cks.len == 0: break
            cs = cks[^1]                        # the wrapped statement (value is first)
          cur.add cs
          # a single CONSTANT case label proves a single tag value; fall-through / default => none
          pendingVal = (if ck == ckCaseStmt and labelCount == 1 and caseVal != low(int): caseVal
                        else: low(int))
        else:
          cur.add child
      if cur.len > 0: groups.add cur; groupVals.add pendingVal; groupIsDefault.add pendingDefault
      # Constant-condition fold: `switch (6)` (a literal / `const` value) selects ONE group — the
      # case whose single constant label equals it, else the `default:` group, else none. Only
      # that group is live; lowering the others (as the join of every case does) analyses paths
      # the program cannot take (`case 7: /* no free */` next to `default: free(data)`) — a
      # false LEAK. The same fold `if (1)` already gets. Kept only when the selected group ends in
      # a `break` / `return` (no fall-through into a sibling), so no reachable code is dropped.
      let cv = (if kids.len >= 1: ctx.foldCond(kids[0]) else: (known: false, value: 0'i64))
      if cv.known and groups.len > 0:
        var sel = -1
        for i, v in groupVals:
          if v != low(int) and v == int(cv.value): sel = i
        if sel < 0:
          for i, d in groupIsDefault:
            if d: sel = i
        if sel < 0:
          return                               # no case matches the constant: the body is dead
        let lastKind = clang_getCursorKind(groups[sel][^1])
        if lastKind == ckBreakStmt or lastKind == ckReturnStmt:
          s.cases.add ctx.lowerBody(groups[sel])
          s.caseValues = @[groupVals[sel]]
          s.hasDefault = true                  # no no-match path: the constant selects this group
          outp.add s
          return
      for g in groups: s.cases.add ctx.lowerBody(g)
      s.caseValues = groupVals
      outp.add s
  of ckForStmt, ckWhileStmt, ckDoStmt:
    # Lower the loop body into a stLoop node. The for-init (a DeclStmt, run once
    # before the loop) is lowered into the enclosing scope. The cond/inc exprs are
    # lowered into the loop body (after it) so a pointer self-advance in the
    # increment (`for(...; data++)`) is modelled: it makes `data` interior, and the
    # loop's bounded fixpoint carries that to a post-loop free -> FREE_INTERIOR.
    let kids = collectChildren(c)
    var bodyCur: CXCursor
    var hasBody = false
    for ch in kids:
      if clang_getCursorKind(ch) == ckCompoundStmt: bodyCur = ch; hasBody = true
    if not hasBody and kids.len > 0 and k != ckDoStmt:
      bodyCur = kids[^1]; hasBody = true   # brace-less for/while: body is last child
    # The for-init runs ONCE before the loop, so lower it into the enclosing scope (not
    # the body). A DeclStmt init, OR an assignment-form init `i = …` as the FIRST child
    # (a for whose loop variable is declared earlier — `for (i = n-1; i >= 0; i--)`): the
    # latter was previously lowered into the body, so a bound it establishes (`i < n` from
    # `i = n-1`) was unavailable at the body's accesses. Hoisting it fixes the reverse-loop
    # idiom. The cond/inc stay in the body.
    var initCur: CXCursor
    var hasInit = false
    if kids.len > 0 and (not hasBody or clang_equalCursors(kids[0], bodyCur) == 0):
      let k0 = clang_getCursorKind(kids[0])
      if k0 == ckDeclStmt or k0 == ckCompoundAssign or
         (k0 == ckBinaryOperator and ctx.binOperator(kids[0]) == "="):
        initCur = kids[0]; hasInit = true
    for ch in kids:                         # for-init declarations run once, before
      if clang_getCursorKind(ch) == ckDeclStmt: ctx.lowerStmt(ch, outp)
    if hasInit and clang_getCursorKind(initCur) != ckDeclStmt:
      ctx.lowerStmt(initCur, outp)          # assignment-form init: hoist it before the loop
    var lb: seq[Stmt]
    if hasBody: lb = ctx.lowerBody(@[bodyCur])
    for ch in kids:                         # cond / increment header expressions
      if clang_getCursorKind(ch) == ckDeclStmt: continue      # init: already lowered
      if hasInit and clang_equalCursors(ch, initCur) != 0: continue  # hoisted init
      if hasBody and clang_equalCursors(ch, bodyCur) != 0: continue  # the body itself
      ctx.lowerStmt(ch, lb)
      # a call NESTED in a compound cond/inc (`while (step(p) != 0)`) is missed by lowerStmt
      # (which only lowers a BARE-call header via ckCallExpr) — descend for its arg escapes.
      let hu = unwrap(ch)
      if clang_getCursorKind(hu) != ckCallExpr:
        for gch in collectChildren(hu): ctx.lowerExprCalls(gch, lb)
    # SPATIAL: a loop condition `i < N` (or `<=`, a symbol, a `±k` offset) bounds `i` for
    # the whole body — the loop only enters/continues when the test holds. Validate it at
    # the body's TOP so `for (i=0;i<N;i++) a[i]` does not flag the (bounded) index. The cond
    # may be COMPOUND: `for (; i < len && s[i] != 0; i++)` is the canonical parser loop, so
    # each conjunct's when-true bound is collected (addThenBound recurses `&&`), exactly as
    # an if-guard would — without this the `i < len` bound is lost on every such loop.
    for ch in kids:
      if clang_getCursorKind(ch) == ckDeclStmt: continue
      if hasBody and clang_equalCursors(ch, bodyCur) != 0: continue
      let cu = unwrap(ch)
      if clang_getCursorKind(cu) != ckBinaryOperator: continue
      var tmp = Stmt(line: startLine(c), kind: stIf)
      ctx.addThenBound(cu, tmp)
      tmp.condBounds = reconcileHeadroom(tmp.condBounds)   # `while (p < end && end - p >= k)`
      for be in tmp.condBounds:
        # OVERFLOW-SAFETY: a loop condition lowers to a plain `ikValidate`, which the sink
        # cannot wrap-gate (it has no access-offset / companion context there). So a wrap-prone
        # form (`i + k <REL> len`) or an underflow-prone limit (`i <= len - k`) as a LOOP bound
        # is dropped — the index stays unbounded (RED), sound. The overflow-safe forms
        # (`i < len`, and `len - i >= k` reconciled above) carry no hazard and are kept. (A
        # wrap-prone loop *condition* with an offset is near-nonexistent in real code — the
        # headroom check is an inner `if`, which the sink DOES wrap-gate.)
        if be.wrapVar or be.wrapLimNeed > 0: continue
        if be.isLower:                         # `for (; i >= 0; …)` -> i >= 0 in the body
          lb.insert(emit(ikLowBound, startLine(c), aKey = be.key, off = be.constLimit), 0)
        elif be.isConst:
          lb.insert(emit(ikValidate, startLine(c), aKey = be.key, off = be.constLimit), 0)
        else:
          lb.insert(emit(ikValidate, startLine(c), aKey = be.key,
                         b = be.symDisp, bKey = be.symKey, off = be.symOff), 0)
    let trips = ctx.loopTripFacts(c, k, kids, bodyCur, hasBody)
    outp.add Stmt(line: startLine(c), kind: stLoop, loopBody: lb, doWhile: trips.atLeastOnce,
                  contExits: trips.contExits, noBackEdge: trips.atMostOnce)
    # `@drains(head)` on the loop's line (or the line above it): this loop releases every
    # element of the collection rooted at `head`. Emitted AFTER the loop — the collection is
    # discharged at the loop's exit, and every cursor on it dangles from there.
    let dl = startLine(c)
    for probe in [dl, dl - 1]:
      if probe in ctx.drainLines:
        let h = ctx.drainLines[probe]
        outp.add emit(ikListDrain, dl, a = h, aKey = ctx.varKeys.getOrDefault(h, h))
        break
  of ckCompoundStmt:
    for child in collectChildren(c):
      ctx.lowerStmt(child, outp)
  of ckLabelStmt:
    # `label: stmt` — emit a join-point marker (stLabel) carrying the label name, then
    # lower the labeled statement so its body stays visible. The engine treats the
    # label as a join: it merges the fall-through state with every forward `goto` that
    # targets it (the cleanup-ladder idiom). A label nested below the function's top
    # level is not modelled — the engine then falls back to refusal for that function.
    let lblLine = startLine(c)
    # `@goto_noreturn` / `@goto_finally` on this line or the line just above mark the label.
    if lblLine in ctx.gotoNoreturnLines or (lblLine - 1) in ctx.gotoNoreturnLines:
      ctx.prog.noreturnLabels.incl spelling(c)
    if lblLine in ctx.gotoFinallyLines or (lblLine - 1) in ctx.gotoFinallyLines:
      ctx.prog.finallyLabels.incl spelling(c)
    outp.add Stmt(line: lblLine, kind: stLabel, labelName: spelling(c))
    for child in collectChildren(c):
      ctx.lowerStmt(child, outp)
  of ckGotoStmt:
    # `goto <label>` — emit a forward-goto instruction carrying the target label name.
    # The engine models it via join-merge when the jump is a modelable forward one
    # (top-level target, no back-edge); otherwise the whole function falls back to
    # UNSTRUCTURED_GOTO (refusal). If the target can't be resolved, refuse outright.
    let tgt = spelling(clang_getCursorReferenced(c))
    if tgt.len > 0:
      # a `@goto_backward`-marked goto carries the "@backward" tag in operand b so the
      # post-lowering pass can restructure its loop; an unmarked backward goto is refused.
      let back = startLine(c) in ctx.gotoBackwardLines
      outp.add emit(ikGoto, startLine(c), a = tgt, b = (if back: "@backward" else: ""))
    else:
      outp.add emit(ikUnsupportedGoto, startLine(c))
  of ckIndirectGotoStmt:
    # a computed / indirect goto (`goto *p`) has no static target — refuse (NOT a
    # silent drop): the engine reports UNSTRUCTURED_GOTO. Soundness by refusal.
    outp.add emit(ikUnsupportedGoto, startLine(c))
  of ckBreakStmt:
    # `break` leaves the innermost loop/switch — the engine routes its state to the
    # post-loop / post-switch join rather than the loop back edge (no silent drop,
    # which would erase a free/leak on the break path).
    outp.add emit(ikBreak, startLine(c))
  of ckContinueStmt:
    # `continue` jumps to the innermost loop head — routed to the loop back edge.
    outp.add emit(ikContinue, startLine(c))
  of ckCXXForRangeStmt:
    # `for (T x : range) { ... }` — children: [loop var decl, range expr, body]. Modelled as a
    # LOOP (0+ iterations, like a while): the body's effects and cross-iteration hazards are
    # analysed by the bounded fixpoint. Without this the whole body was DROPPED — a free inside
    # a range-for was invisible (a false GREEN).
    let kids = collectChildren(c)
    if kids.len >= 2: ctx.lowerExprCalls(kids[^2], outp)   # a call in the range expression
    var s = Stmt(line: startLine(c), kind: stLoop)
    # `for (auto q : v)` over a container that holds an owned element: each iteration yields ONE
    # element, which the loop variable names. Modelled as: the slot is re-armed at the top of the
    # body (a FRESH element per iteration — so releasing it every time is not a double free of
    # one object) and the loop variable aliases it (so `free(q)` discharges the container's
    # obligation: the idiomatic cleanup loop is clean, a read-only loop still leaks). The loop
    # runs at least once on this path — the slot is tracked precisely because something was put
    # in the container — so the state after it is the body's, not the never-ran entry state.
    var head: seq[Stmt]
    if kids.len >= 3 and clang_getCursorKind(kids[0]) == ckVarDecl:
      let slot = ctx.containerSlot(kids[^2])
      if slot.has and ctx.tracked.getOrDefault(slot.key, false):
        ctx.tracked[usr(kids[0])] = true
        head.add emit(ikReArm, startLine(c), a = slot.disp, aKey = slot.key)
        head.add emit(ikCopy, startLine(c), a = spelling(kids[0]), b = slot.disp,
                      aKey = usr(kids[0]), bKey = slot.key)
        s.doWhile = true
        s.contExits = true    # `continue` on the LAST element leaves the loop
    if kids.len >= 1: s.loopBody = head & ctx.lowerBody(@[kids[^1]])
    outp.add s
  of ckCXXThrowExpr:
    # `throw e;` — control leaves by unwinding: a call in the operand lowers its effects first,
    # then the exit. Inside a `try` the engine lands it in the handlers; otherwise it is a
    # function exit carrying nothing — every raw owner still held is a LEAK /
    # CONTRACT_NOT_HONORED on this path (an RAII owner is released by the unwinding itself).
    ctx.scanDerefs(c, outp)
    for kid in collectChildren(c): ctx.lowerExprCalls(kid, outp)
    outp.add emit(ikThrow, startLine(c), b = thrownType(c))   # b = the thrown type
  of ckCXXTryStmt:
    # `try { B } catch (T1) { H1 } ... catch (...) { Hn }`: B is the try body, each handler's
    # compound an alternative entered from the join of B's unwinding exits; `catch (...)` (the
    # `...` token) means nothing propagates past the handlers. Children: [B, CXXCatchStmt...],
    # each catch: [exception decl?, CompoundStmt] — the body is always the last child.
    let kids = collectChildren(c)
    var s = Stmt(line: startLine(c), kind: stTry)
    if kids.len >= 1: s.tryBody = ctx.lowerBody(@[kids[0]])
    for i in 1 ..< kids.len:
      if clang_getCursorKind(kids[i]) != ckCXXCatchStmt: continue
      let hk = collectChildren(kids[i])
      s.handlers.add (if hk.len > 0: ctx.lowerBody(@[hk[^1]]) else: @[])
      s.handlerTypes.add ctx.catchType(kids[i])
    outp.add s
  else:
    # A statement kind kenbi does not model. Dropping its subtree silently would hide any
    # allocation / release inside it (the false-GREEN failure), so: inert constructs stay
    # quiet, but one that CONTAINS a memory operation is refused (UNSUPPORTED_CONSTRUCT).
    if k >= 200 and ctx.holdsMemoryOp(c):
      outp.add emit(ikUnsupportedConstruct, startLine(c), a = "construct")

proc lowerBody(ctx: var Ctx, body: seq[CXCursor]): seq[Stmt] =
  for c in body:
    if clang_getCursorKind(c) == ckCompoundStmt:
      for child in collectChildren(c):
        ctx.lowerStmt(child, result)
    else:
      ctx.lowerStmt(c, result)

# --- driver -----------------------------------------------------------------

proc funcParams(c: CXCursor): seq[tuple[name, key: string]] =
  ## Ordered parameter (display name, USR) pairs of a function declaration.
  for k in collectChildren(c):
    if clang_getCursorKind(k) == ckParmDecl:
      result.add (spelling(k), usr(k))

proc pointerParams(c: CXCursor): seq[tuple[name, key: string]] =
  ## Pointer parameters only (`T *`), for seeding the undeclared-incoming-pointer
  ## origin (intake-side default-red). Non-pointer params carry no release obligation.
  for k in collectChildren(c):
    if clang_getCursorKind(k) == ckParmDecl and isPointerType(k):
      result.add (spelling(k), usr(k))

proc unsignedIntParamKeys(c: CXCursor): HashSet[string] =
  ## USRs of the function's UNSIGNED-integer parameters. The INVARIANT init/establish
  ## check (slice 4) consults this so `field = 0` can establish `field <= size` only
  ## when the size operand is unsigned (hence `>= 0`, so `0 <= size`).
  for k in collectChildren(c):
    if clang_getCursorKind(k) == ckParmDecl and isUnsignedInteger(k):
      result.incl usr(k)

const annBindWindow = 6
  ## How many lines below an annotation comment its function may start. Each resolver
  ## binds an annotation to the NEAREST function below it (smallest fn.line >= site.line)
  ## within this window — the window only caps an orphan annotation from binding to a
  ## far-away function. 6 accommodates several STACKED annotations on one function (e.g.
  ## `@counted_by` + two `@invariant` lines on jsmn-style code), which a tight window dropped.

proc recordContractDecl(ctx: var Ctx, fn: FuncSig, fkey, kw, param: string,
                        viaOverlay: bool) =
  ## Keep the resolved contract in the program's publishable contract surface. The same
  ## (function, effect, parameter) can be bound more than once — a declaration and its
  ## definition, or an overload set under one by-name contract — so entries are merged, and
  ## `hasBody` is the OR: seeing the implementation once is what makes verification possible.
  for c in ctx.prog.contracts.mitems:
    if c.fn == fkey and c.effect == kw and c.param == param:
      if fn.hasBody:
        c.hasBody = true
        c.file = fn.file      # prefer the definition's site: that is what was checked
        c.line = fn.line
      return
  ctx.prog.contracts.add ContractDecl(fn: fkey, effect: kw, param: param,
                                      file: fn.file, line: fn.line,
                                      hasBody: fn.hasBody, viaOverlay: viaOverlay)

proc applyContract(ctx: var Ctx, fn: FuncSig, kw, param: string,
                   globalUsr: Table[string, string],
                   viaOverlay = false): bool {.discardable.} =
  ## Bind ONE contract keyword + parameter name to one function signature, populating the
  ## resolved stores (argContracts / bodyContracts / ownsOut / returnContracts / funcFlags /
  ## funcFreesGlobal). Shared by both declaration forms — the inline `@frees(p)` above a
  ## declaration and the by-name `@contract F { frees: p }` — so the two cannot drift: a
  ## contract declared from an overlay carries the same body obligation, and is verified
  ## against the body exactly as the inline one is. Returns true if the named parameter (or
  ## global) matched, so the caller can say when a declaration found no subject.
  let ac = lookupArgContract(kw)
  let bc = lookupBodyContract(kw)
  let rc = lookupReturnContract(kw)
  let fl = lookupFuncFlag(kw)
  let fkey = (if fn.qual.len > 0: fn.qual else: fn.name)   # a member function's contracts live under `Class::method`
  var boundOut = false   # `@owns(p)` bound to a parameter: an out-param, not a return contract
  # An EMPTY param names no parameter — `@owns` on its own is a return contract, `@must_use` /
  # `@nothrow` are whole-function flags. Without this guard the empty name matched an UNNAMED
  # parameter (`char *make(int);` — the normal style in a C header), which bound `@owns` as an
  # out-parameter contract and dropped the return contract: the factory's result was not owned
  # and its leak went unreported. A false GREEN on the commonest way to declare a C prototype.
  if (ac.has or bc.has) and param.len > 0:
    # An arg contract may name a sub-object of the parameter, which the callee acts on:
    #   `@frees(*p)`  — the POINTEE of an out-parameter (`T**`); a `&var` arg transfers `var`.
    #   `@frees(p.f)` / `@frees(p->f)` — a struct FIELD; a struct-var arg transfers `arg.f`.
    # `accessor` carries "*" or the field name ("" = the arg itself). Match on the base name,
    # and skip the body-side obligation for an accessor form (verifying `free(*p)` / `free(p.f)`
    # inside the callee is future work — the callsite transfer is what the detection needs).
    var accessor = ""
    var pname = param
    if pname.startsWith("*"):
      accessor = "*"; pname = pname[1 .. ^1].strip
    elif '[' in pname:
      # `@frees(arr[2])`: the constant ELEMENT of an array parameter (accessor "[2]")
      let lb = pname.find('[')
      accessor = pname[lb .. ^1].strip; pname = pname[0 ..< lb].strip
    else:
      let sep = (if "->" in pname: pname.find("->") else: pname.find('.'))
      if sep > 0:
        let step = (if pname[sep] == '-': 2 else: 1)
        accessor = pname[sep + step .. ^1].strip; pname = pname[0 ..< sep].strip
    # A parameter may be named by POSITION (`$1`, 1-based) instead of by name. C headers are
    # written with unnamed parameters more often than not — ImageMagick declares
    # `DestroyKernelInfo(KernelInfo *)` — and the call sites that need the contract are in files
    # that see only that prototype. Without positions, a by-name contract could not reach them.
    var positional = -1
    block asPosition:
      let digits = (if pname.startsWith("$"): pname[1 .. ^1] else: pname)
      if digits.len > 0 and digits.allCharsInSet({'0'..'9'}):
        positional = parseInt(digits) - 1
    proc bindAt(ctx: var Ctx, idx: int) =
      if ac.has and (idx, ac.instr, accessor) notin ctx.argContracts.getOrDefault(fkey, @[]):
        ctx.argContracts.mgetOrPut(fkey, @[]).add (idx, ac.instr, accessor)
      if ac.has and ac.instr == ikOwnsOut:
        ctx.ownsOut.mgetOrPut(fkey, @[]).add (idx, accessor)
      # The ACCESSOR forms seed the body too, on the slot the contract names: `@frees(*p)` on
      # the `T**` out-parameter sink, `@frees(p.f)` on a struct field. Without that the contract
      # was visible at the callsite only — the callee's own `free(*p)` had nothing to discharge
      # and read as an unaccounted release, and a declared release could not be VERIFIED there.
      if bc.has and (idx, bc.instr, accessor) notin ctx.bodyContracts.getOrDefault(fkey, @[]):
        ctx.bodyContracts.mgetOrPut(fkey, @[]).add (idx, bc.instr, accessor)
    if positional >= 0:
      if positional < fn.params.len:
        result = true
        ctx.bindAt(positional)
        if ac.has and ac.instr == ikOwnsOut: boundOut = true
    else:
      for idx, p in fn.params:
        if p.name == pname:
          result = true
          ctx.bindAt(idx)
          if ac.has and ac.instr == ikOwnsOut: boundOut = true
    if not result and accessor.len == 0 and ac.has and ac.instr == ikFree and
       pname in globalUsr:
      # `@frees(g)` where `g` is a file-scope GLOBAL, not a parameter: the function releases a
      # module-global handed to it through that global (the static-global source/sink form,
      # Juliet _45). Record it as a global free effect; every call to the fn frees the global's
      # origin in the caller (which `g = data` aliased there). No parameter carries it.
      ctx.funcFreesGlobal.mgetOrPut(fkey, @[]).add (globalUsr[pname], pname)
      result = true
  if rc.has and not boundOut: ctx.returnContracts[fkey] = ReturnContract(kind: rc.kind)
  if fl.has:
    if fl.name == "nothrow": ctx.nothrowFuncs.incl fkey
    else: ctx.funcFlags.incl fkey
  if param.len == 0: result = true   # a whole-function contract has no parameter to match
  if result: ctx.recordContractDecl(fn, fkey, kw, param, viaOverlay)

proc collectFileScopeVars(tu: CXTranslationUnit): Table[string, string] =
  ## File-scope variable NAME -> USR, so `@frees(g)` naming a global rather than a parameter can
  ## be resolved to the object it names.
  ##
  ## "File scope" includes what a `namespace` or an `extern "C"` block encloses: those are
  ## containers, not scopes that hide a name from the file's annotations. Walking only the
  ## translation unit's immediate children found C's globals and none of C++'s — every Juliet
  ## testcase wraps its globals in a namespace — so a `@frees(g)` contract on a sink that
  ## releases through a module global bound to nothing, and the release went unseen at every
  ## caller. Function bodies are NOT descended into: a local is not a file-scope name.
  result = initTable[string, string]()
  proc gv(c, p: CXCursor, client: CXClientData): CXChildVisitResult {.cdecl.} =
    case clang_getCursorKind(c)
    of ckVarDecl:
      cast[ptr Table[string, string]](client)[][spelling(c)] = usr(c)
      return cvrContinue
    of ckNamespace, ckLinkageSpec, ckUnexposedDecl:
      return cvrRecurse
    else: return cvrContinue
  discard clang_visitChildren(clang_getTranslationUnitCursor(tu), gv, addr result)

proc resolveContracts(ctx: var Ctx) =
  ## Generic binding pass for every registered ownership contract. For each raw
  ## annotation site, find the function it documents — the nearest declaration at
  ## or below it within a 2-line window, in the same file — then populate the
  ## resolved stores by the keyword's registered category:
  ##   * arg / body contracts (`@frees`/`@moves`/`@borrows`) match the annotation's
  ##     param name to a parameter index of that function.
  ##   * return contracts (`@owns`/`@arena_alloc`) and func flags (`@must_use`)
  ##     bind to the function itself (no param).
  ## This single pass replaces the per-annotation resolve procs; a new contract is
  ## a one-line registration in annotations/ (see registry.nim) with no edit here.
  ## The binding itself lives in `applyContract`, shared with the by-NAME form
  ## (`@contract F { … }`, resolveNamedContracts) so the two cannot drift.
  var globalUsr = collectFileScopeVars(ctx.tu)
  for kw, sites in ctx.rawAnn:
    let fl = lookupFuncFlag(kw)
    for site in sites:
      if fl.has and fl.name == "nothrow" and site.param.len > 0:
        ctx.nothrowFuncs.incl site.param.strip   # `@nothrow(name)`: vouch by name, no binding
        continue
      var bestLine = high(int)
      var best = -1
      for i, fn in ctx.funcSigs:
        if fn.file == site.file and fn.line >= site.line and
           fn.line <= site.line + annBindWindow and fn.line < bestLine:
          bestLine = fn.line; best = i
      if best < 0: continue
      discard ctx.applyContract(ctx.funcSigs[best], kw, site.param, globalUsr)

proc resolveNamedContracts(ctx: var Ctx) =
  ## Bind every `@contract <Fn> { … }` to the signatures of that name. The by-NAME form exists
  ## because the inline annotations have to sit above a declaration, and a project kenbi may not
  ## edit offers nowhere to put one; this form lives in a comment-only overlay header instead.
  ## It goes through exactly the same binding as the inline form — including the BODY obligation,
  ## so a `frees:` contract on a function whose body is in this translation unit is still
  ## verified against it (CONTRACT_NOT_HONORED if it does not free). Not a suppression switch.
  ##
  ## A name this translation unit never declares is silently skipped: one overlay covers a whole
  ## project, and most of it is irrelevant to any single file. A name it DOES declare, with a
  ## parameter the signature does not have, is an advisory — the boundary it was meant to clear
  ## simply stays RED, which is the safe direction, and the advisory says why.
  ##
  ## The name is matched against every signature that carries it, so a C++ OVERLOAD SET all
  ## takes the same contract (`Class::method` selects a member function, but not one overload of
  ## it). Where that is wrong, the inline form still binds to one declaration.
  if ctx.namedContracts.len == 0: return
  var globalUsr = collectFileScopeVars(ctx.tu)
  for nc in ctx.namedContracts:
    if nc.kw == "@nothrow" and nc.param.len == 0:
      ctx.nothrowFuncs.incl nc.fn          # vouch by name; no signature needed
      continue
    var sawFn = false
    var matched = false
    for fn in ctx.funcSigs:
      if fn.name != nc.fn and fn.qual != nc.fn: continue
      sawFn = true
      if ctx.applyContract(fn, nc.kw, nc.param, globalUsr, viaOverlay = true): matched = true
    if sawFn and nc.param.len > 0 and not matched:
      ctx.prog.advisories.add Advisory(line: 0, code: "CONTRACT_UNBOUND",
        msg: "`@contract " & nc.fn & "` names '" & nc.param & "', but '" & nc.fn &
             "' has no such parameter here — the contract is not applied, so the boundary it " &
             "was meant to declare stays uncontracted. Check the parameter name against the " &
             "declaration kenbi sees.")

proc resolveRaiiTypes(ctx: var Ctx) =
  ## Bind each `@raii` marker to the class / struct / union / class template declared at or
  ## below it (nearest, within annBindWindow, same file): instances of that type OWN a resource
  ## their destructor releases at scope exit (unique_ptr / KIR's kir_owned_scalar). This is a
  ## DECLARED contract about the type — kenbi trusts the RAII release the class promises, it does
  ## not infer it from the class body. The bound bare class name feeds the local-decl lowering.
  ctx.raiiTypes = initHashSet[string]()
  ctx.structOwnerFields = initTable[string, seq[tuple[name, cls: string]]]()
  # std::unique_ptr is a BUILT-IN owner — a fixed vocabulary item like malloc/free, not an
  # inference: its destructor releases, std::move transfers, .get()/.release() are the seam.
  ctx.raiiTypes.incl "unique_ptr"
  # std::shared_ptr likewise: the last handle's destructor releases, std::move transfers (the
  # source is empty — use-after-move), a COPY is a second live handle (not a move), .get() is
  # the borrow seam. The template arguments (a custom deleter) are not the owner's identity.
  ctx.raiiTypes.incl "shared_ptr"
  for n in ctx.raiiNames: ctx.raiiTypes.incl n      # `@raii(Name)`: declared by name
  var decls: seq[tuple[file: string, line: int, name: string, cur: CXCursor]]
  proc rv(c, p: CXCursor, client: CXClientData): CXChildVisitResult {.cdecl.} =
    let k = clang_getCursorKind(c)
    if k == ckStructDecl or k == ckClassDecl or k == ckClassTemplate or k == ckUnionDecl:
      cast[ptr seq[tuple[file: string, line: int, name: string, cur: CXCursor]]](client)[].add (
        fileOf(clang_getCursorLocation(c)), startLine(c), spelling(c), c)
      return cvrContinue
    if k == ckNamespace or k == ckLinkageSpec or k == ckUnexposedDecl: return cvrRecurse
    cvrContinue
  discard clang_visitChildren(clang_getTranslationUnitCursor(ctx.tu), rv, addr decls)
  for site in ctx.raiiSites:
    var bestLine = high(int)
    var best = ""
    for d in decls:
      if d.file == site.file and d.line >= site.line and d.line <= site.line + annBindWindow and
         d.line < bestLine and d.name.len > 0:
        bestLine = d.line; best = d.name
    if best.len > 0: ctx.raiiTypes.incl best
  # Owner FIELDS: a struct / class whose fields include an owner type (an `@raii` class or the
  # built-in unique_ptr) HOLDS those owners — a local / parameter of that struct carries one RAII
  # origin per owner field, all released by the struct's destructor. One level deep.
  for d in decls:
    if d.name.len == 0: continue
    for ch in collectChildren(d.cur):
      if clang_getCursorKind(ch) != ckFieldDecl: continue
      let ft = ctx.ownerTypeName(ch).name
      if ft in ctx.raiiTypes:
        ctx.structOwnerFields.mgetOrPut(d.name, @[]).add (spelling(ch), ft)

proc collectBlocks(ctx: Ctx): seq[tuple[file: string, first, last: int]] =
  ## Every statement inside a function body that a `@kenbi` marker can cover: a compound
  ## statement and the control-flow statements that own one. Their line ranges are what
  ## block-level adoption is expressed in.
  var found: seq[tuple[file: string, first, last: int]]  # a closure cannot capture `var ctx`
  proc walk(n: CXCursor) =
    let k = clang_getCursorKind(n)
    if k in [ckCompoundStmt, ckIfStmt, ckForStmt, ckWhileStmt, ckDoStmt, ckSwitchStmt,
             ckCXXForRangeStmt, ckCXXTryStmt]:
      let f = fileOf(clang_getCursorLocation(n))
      if f.len > 0: found.add (file: f, first: startLine(n), last: endLine(n))
    for ch in collectChildren(n): walk(ch)
  for top in collectChildren(clang_getTranslationUnitCursor(ctx.tu)):
    walk(top)
  found

proc resolveKenbiCoverage(ctx: var Ctx) =
  ## Bind each `@kenbi` opt-in marker to what it covers, at the granularity it was written at:
  ##   * the nearest FUNCTION at/below it within a 2-line window — function-level opt-in;
  ##   * failing that, the nearest STATEMENT at/below it in the same window — BLOCK-level
  ##     opt-in, for adopting one part of a function too large to clean up at once. The
  ##     findings inside that line range are kept while the rest of the function stays
  ##     neutral, and the function does NOT count as adopted: the coverage numbers must not
  ##     claim a function is under discipline when only a block of it is.
  ##   * failing both (a marker at the top of a file), file-level: every function in the TU.
  ctx.prog.coveredFuncs = initHashSet[string]()
  let blocks = ctx.collectBlocks()
  for site in ctx.kenbiSites:
    var bestLine = high(int)
    var best = -1
    for i, fn in ctx.funcSigs:
      if fn.file == site.file and fn.line >= site.line and
         fn.line <= site.line + annBindWindow and fn.line < bestLine and fn.hasBody:
        bestLine = fn.line; best = i          # hasBody: a bare PROTOTYPE is not a coverage
    if best >= 0:
      ctx.prog.coveredFuncs.incl ctx.funcSigs[best].name       # target - binding to it
      continue
    var blkLine = high(int)
    var blk = -1
    for i, b in blocks:
      if b.file != site.file or b.first < site.line: continue
      if b.first > site.line + annBindWindow: continue
      # the NEAREST block below the marker, and the widest one starting on that line (an
      # `if` and its body start together; the marker means the whole statement)
      if b.first < blkLine or (b.first == blkLine and blk >= 0 and b.last > blocks[blk].last):
        blkLine = b.first; blk = i
    if blk >= 0: ctx.prog.coveredBlocks.add blocks[blk]
    else: ctx.prog.allCovered = true   # file-level marker (no function or block just below)

proc resolveSpatialCoverage(ctx: var Ctx) =
  ## Bind each `@spatial` opt-in marker to the function it covers, exactly like
  ## resolveKenbiCoverage but for the independent bounds axis.
  ctx.prog.spatialFuncs = initHashSet[string]()
  for site in ctx.spatialSites:
    var bestLine = high(int)
    var best = -1
    for i, fn in ctx.funcSigs:
      if fn.file == site.file and fn.line >= site.line and
         fn.line <= site.line + annBindWindow and fn.line < bestLine and fn.hasBody:
        bestLine = fn.line; best = i
    if best >= 0: ctx.prog.spatialFuncs.incl ctx.funcSigs[best].name
    else: ctx.prog.spatialAll = true   # file-level marker

proc resolveFieldPathExpr(byName: Table[string, string], expr: string):
    tuple[ok: bool, key, disp: string] =
  ## TYPE-CONFUSION: resolve a `@variant` operand — a possibly-NESTED field path `n->u.i`
  ## (keyed `<n-USR>::u.i`), a one-level `n->tag`, or a bare name — matching deepMemberKey.
  let arrow = expr.find("->")
  if arrow >= 0:
    let baseN = expr[0 ..< arrow].strip
    let path = expr[arrow + 2 .. ^1].strip       # `u.i` / `tag`
    if baseN notin byName or path.len == 0: return (false, "", "")
    (true, byName[baseN] & "::" & path, expr)
  else:
    if expr notin byName: return (false, "", "")
    (true, byName[expr], expr)

proc resolveInvLValue(byName: Table[string, string], expr: string):
    tuple[ok: bool, key, disp: string] =
  ## Resolve an `@invariant` / `@counted_by` / `@guarded_by` operand — a one-level field path
  ## `base->field` (keyed `<base-USR>::field`, the same key its writes / a bound on it use) or
  ## a bare parameter name — to its identity key + display. ok=false for anything else.
  if expr.contains("->"):
    let parts = expr.split("->")
    if parts.len != 2: return (false, "", "")
    let baseN = parts[0].strip
    let fld = parts[1].strip
    if baseN notin byName: return (false, "", "")
    (true, byName[baseN] & "::" & fld, expr)
  else:
    if expr notin byName: return (false, "", "")
    (true, byName[expr], expr)

proc resolveThreadsafeCoverage(ctx: var Ctx) =
  ## Bind each `@threadsafe` opt-in marker to the function it covers (the lock-discipline
  ## axis), exactly like resolveSpatialCoverage.
  ctx.prog.concurrentFuncs = initHashSet[string]()
  for site in ctx.concurrentSites:
    var bestLine = high(int)
    var best = -1
    for i, fn in ctx.funcSigs:
      if fn.file == site.file and fn.line >= site.line and
         fn.line <= site.line + annBindWindow and fn.line < bestLine and fn.hasBody:
        bestLine = fn.line; best = i
    if best >= 0: ctx.prog.concurrentFuncs.incl ctx.funcSigs[best].name
    else: ctx.prog.concurrentAll = true   # file-level marker

proc resolveInitCoverage(ctx: var Ctx) =
  ## Bind each `@initcheck` opt-in marker to the function it covers (definite-assignment axis),
  ## exactly like resolveSpatialCoverage.
  ctx.prog.initFuncs = initHashSet[string]()
  for site in ctx.initSites:
    var bestLine = high(int)
    var best = -1
    for i, fn in ctx.funcSigs:
      if fn.file == site.file and fn.line >= site.line and
         fn.line <= site.line + annBindWindow and fn.line < bestLine and fn.hasBody:
        bestLine = fn.line; best = i
    if best >= 0: ctx.prog.initFuncs.incl ctx.funcSigs[best].name
    else: ctx.prog.initAll = true   # file-level marker

proc resolveTypecheckCoverage(ctx: var Ctx) =
  ## Bind each `@typecheck` opt-in marker to the function it covers (type-confusion axis).
  ctx.prog.typecheckFuncs = initHashSet[string]()
  for site in ctx.typecheckSites:
    var bestLine = high(int)
    var best = -1
    for i, fn in ctx.funcSigs:
      if fn.file == site.file and fn.line >= site.line and
         fn.line <= site.line + annBindWindow and fn.line < bestLine and fn.hasBody:
        bestLine = fn.line; best = i
    if best >= 0: ctx.prog.typecheckFuncs.incl ctx.funcSigs[best].name
    else: ctx.prog.typecheckAll = true   # file-level marker

proc siteFuncName(ctx: Ctx, file: string, line: int): string =
  ## The name of the function an annotation at (file, line) binds to: the nearest function
  ## decl below it within the bind window, in the SAME file (a header prototype OR a same-file
  ## definition). Operands are resolved later against the DEFINING function's params, so a
  ## header-declared contract binds to its implementation in another TU by NAME (cross-file).
  var bestLine = high(int)
  var best = -1
  for i, fn in ctx.funcSigs:
    if fn.file == file and fn.line >= line and
       fn.line <= line + annBindWindow and fn.line < bestLine:
      bestLine = fn.line; best = i
  if best >= 0: ctx.funcSigs[best].name else: ""

proc resolveGuardedBy(ctx: var Ctx) =
  ## Bind each `@guarded_by(field: lock)` to the function below it by NAME and STORE the raw
  ## operand exprs; fnVisitor resolves them to keys against the defining function's params, so
  ## the contract binds to the implementation even in another file (cross-file).
  ctx.guardedBy = initTable[string, seq[tuple[fieldExpr, lockExpr: string]]]()
  for site in ctx.guardedBySites:
    let fn = ctx.siteFuncName(site.file, site.line)
    if fn.len == 0: continue
    let kv = site.spec.split(':')
    if kv.len != 2: continue
    ctx.guardedBy.mgetOrPut(fn, @[]).add (kv[0].strip, kv[1].strip)

proc resolveGuardedMembers(ctx: var Ctx) =
  ## Bind each single-arg `@guarded_by(lock)` (on a struct member) to that member's declaration
  ## USR, via the nearest field at/below the annotation. At an access `base->member`,
  ## scanGuardedAccess looks the member's decl USR up here and requires `base->lock` (the sibling)
  ## held — the per-instance, type-bound version of `@guarded_by(field: lock)`. Outside a
  ## `@threadsafe` scope it cannot gate, so it falls back to the GUARDED_BY advisory (prior behaviour).
  ctx.guardedMember = initTable[string, string]()
  if ctx.guardedMemberSites.len == 0: return
  if not (ctx.prog.concurrentAll or ctx.prog.concurrentFuncs.len > 0):
    for site in ctx.guardedMemberSites:
      ctx.prog.advisories.add Advisory(line: site.line, code: "GUARDED_BY",
        msg: "advisory: the annotated data must be accessed only while holding '" & site.lockName &
             "'. Reviewer: verify no read/write of it happens without that lock held. " &
             "(Mark the enclosing code `@threadsafe` to have kenbi verify this.)")
    return
  # Collect every field declaration in the TU (records can nest, so recurse).
  var fields: seq[tuple[file: string, line: int, usr: string]]
  proc fv(c, p: CXCursor, client: CXClientData): CXChildVisitResult {.cdecl.} =
    if clang_getCursorKind(c) == ckFieldDecl:
      cast[ptr seq[tuple[file: string, line: int, usr: string]]](client)[].add (
        fileOf(clang_getCursorLocation(c)), startLine(c), usr(c))
    cvrRecurse
  discard clang_visitChildren(clang_getTranslationUnitCursor(ctx.tu), fv, addr fields)
  for site in ctx.guardedMemberSites:
    var bestLine = high(int)
    var bestUsr = ""
    for f in fields:                                  # the nearest field at/below the annotation
      if f.file == site.file and f.line >= site.line and
         f.line <= site.line + annBindWindow and f.line < bestLine and f.usr.len > 0:
        bestLine = f.line; bestUsr = f.usr
    if bestUsr.len > 0: ctx.guardedMember[bestUsr] = site.lockName

proc resolveLockClasses(ctx: var Ctx) =
  ## Bind each `@lock_class(X)` to the nearest lock DECLARATION at/below it, mapping that decl's USR
  ## to the class name (CHECKED: the mapping is derived from the decl, not trusted). Two decl kinds:
  ## a file-scope GLOBAL var -> `varClass` (keyed BY class, so the global's acquires/contracts use X
  ## directly; cross-file identity by class name); a struct FIELD -> `fieldClass` (the lock keys by
  ## INSTANCE and merely CARRIES X, so two instances of one class are the same-class pair stage 3
  ## requires a canonical order for). The class names also seed `lockClasses` so a contract operand
  ## naming a class (`@acquires(X)`) keys by it rather than being treated as a variable.
  ctx.varClass = initTable[string, string]()
  ctx.fieldClass = initTable[string, string]()
  ctx.lockClasses = initHashSet[string]()
  if ctx.lockClassSites.len == 0: return
  for site in ctx.lockClassSites: ctx.lockClasses.incl site.name
  var decls: seq[tuple[file: string, line: int, usr: string, isField: bool]]
  proc dv(c, p: CXCursor, client: CXClientData): CXChildVisitResult {.cdecl.} =
    let k = clang_getCursorKind(c)
    if k == ckVarDecl or k == ckFieldDecl:
      cast[ptr seq[tuple[file: string, line: int, usr: string, isField: bool]]](client)[].add (
        fileOf(clang_getCursorLocation(c)), startLine(c), usr(c), k == ckFieldDecl)
    cvrRecurse                                          # recurse: fields nest inside records
  discard clang_visitChildren(clang_getTranslationUnitCursor(ctx.tu), dv, addr decls)
  for site in ctx.lockClassSites:
    var bestLine = high(int)
    var best: tuple[usr: string, isField: bool] = ("", false)
    for d in decls:                                     # the nearest decl (var OR field) at/below it
      if d.file == site.file and d.line >= site.line and
         d.line <= site.line + annBindWindow and d.line < bestLine and d.usr.len > 0:
        bestLine = d.line; best = (d.usr, d.isField)
    if best.usr.len > 0:
      if best.isField: ctx.fieldClass[best.usr] = site.name
      else: ctx.varClass[best.usr] = site.name

proc classOfAddrOf(ctx: Ctx, e: CXCursor): string =
  ## If `e` is `&<global>` where the global carries an `@lock_class`, the class name; else "".
  let u = unwrap(e)
  if clang_getCursorKind(u) == ckUnaryOperator and ctx.firstTokenSpelling(u) == "&":
    let kids = collectChildren(u)
    if kids.len >= 1:
      let o = unwrap(kids[0])
      if clang_getCursorKind(o) == ckDeclRefExpr:
        let ru = referencedUsr(o)
        if ru in ctx.varClass: return ctx.varClass[ru]
  ""

proc collectLockAliases(ctx: Ctx): Table[string, string] =
  ## The TU walk for resolveLockAliases (split out so the recursive closure captures a non-var Ctx).
  var cls = initTable[string, string]()              # candidate local USR -> class of its &classed writes
  var poison = initHashSet[string]()                 # locals disqualified from class membership
  proc note(usr, c: string) =
    if usr.len == 0 or usr in poison: return
    if c.len == 0: poison.incl usr; cls.del usr      # a write to a non-classed value
    elif usr in cls and cls[usr] != c: poison.incl usr; cls.del usr   # two different classes
    else: cls[usr] = c
  proc walk(n: CXCursor) =
    let k = clang_getCursorKind(n)
    if k == ckVarDecl:
      let kids = collectChildren(n)                  # an initializer is the last child, IF it is an expr
      if kids.len >= 1 and clang_getCursorKind(kids[^1]) >= ckUnexposedExpr:
        note(usr(n), ctx.classOfAddrOf(kids[^1]))
    elif k == ckBinaryOperator and ctx.binOperator(n) == "=":
      let kids = collectChildren(n)
      if kids.len == 2 and clang_getCursorKind(unwrap(kids[0])) == ckDeclRefExpr:
        note(referencedUsr(unwrap(kids[0])), ctx.classOfAddrOf(kids[1]))
    elif k == ckUnaryOperator and ctx.firstTokenSpelling(n) == "&":
      let kids = collectChildren(n)                  # `&p` of a tracked local: the address escapes -> poison
      if kids.len >= 1 and clang_getCursorKind(unwrap(kids[0])) == ckDeclRefExpr:
        let ru = referencedUsr(unwrap(kids[0]))
        if ru notin ctx.varClass: poison.incl ru; cls.del ru  # (don't poison the classed global itself)
    for ch in collectChildren(n): walk(ch)
  walk(clang_getTranslationUnitCursor(ctx.tu))
  for usr, c in cls:
    if usr notin poison: result[usr] = c

proc resolveLockAliases(ctx: var Ctx) =
  ## STAGE 2 (v3): a local pointer that is a VERIFIED alias of a classed lock JOINS that lock's
  ## class, so an acquire/release through the pointer (`pthread_mutex_lock(p)` where `p = &a`) keys
  ## by the class — cross-function order / double-lock now work THROUGH pointers, not just direct
  ## globals. The alias is CHECKED, not trusted: a pointer joins a class only if EVERY write to it
  ## is `&<classed-lock>` of the SAME class and its address is never taken (`&p`) — an unambiguous,
  ## single-class definition (the design's "p is class X because p = &g_lock", made falsifiable).
  ## Any other write (a different class, a non-classed value, an escaping `&p`) POISONS the pointer:
  ## it keeps the existing USR keying — sound for the BALANCE checks (a leaked/double-unlocked `p`
  ## is still caught by its own USR), and the cross-name identity it cannot pin stays exactly the
  ## documented pointer-aliasing residual, no WORSE than before. So stage 2 strictly ADDS hazard
  ## detection (verified aliases) and introduces no new false GREEN. Reuses no inference — only the
  ## declared `@lock_class` identity. Function-local USRs don't collide, so one TU-wide pass suffices.
  ctx.lockAliasClass = initTable[string, string]()
  if ctx.varClass.len == 0: return
  ctx.lockAliasClass = collectLockAliases(ctx)

proc resolveFnptrTargets(ctx: var Ctx) =
  ## STAGE 4 (v3): bind each `@calls(f, g, ...)` to the nearest function-pointer DECLARATION at/below
  ## it (a var, param, or struct field), mapping that decl's USR to the declared target-name set. An
  ## indirect call resolves through it; assignments and calls are then CHECKED against the set
  ## (declare-don't-infer: the implementer names the callable targets, kenbi verifies conformance).
  ctx.fnptrTargets = initTable[string, HashSet[string]]()
  if ctx.fnCallsSites.len == 0: return
  var decls: seq[tuple[file: string, line: int, usr: string]]
  proc dv(c, p: CXCursor, client: CXClientData): CXChildVisitResult {.cdecl.} =
    let k = clang_getCursorKind(c)
    if k == ckVarDecl or k == ckParmDecl or k == ckFieldDecl:
      cast[ptr seq[tuple[file: string, line: int, usr: string]]](client)[].add (
        fileOf(clang_getCursorLocation(c)), startLine(c), usr(c))
    cvrRecurse
  discard clang_visitChildren(clang_getTranslationUnitCursor(ctx.tu), dv, addr decls)
  for site in ctx.fnCallsSites:
    var bestLine = high(int)
    var bestUsr = ""
    for d in decls:                                   # the nearest fnptr decl at/below the annotation
      if d.file == site.file and d.line >= site.line and
         d.line <= site.line + annBindWindow and d.line < bestLine and d.usr.len > 0:
        bestLine = d.line; bestUsr = d.usr
    if bestUsr.len > 0:
      var targets = initHashSet[string]()
      for t in site.spec.split(','):                  # `@calls(f, g)` — a comma-separated name list
        let n = t.strip
        if n.len > 0: targets.incl n
      if targets.len > 0: ctx.fnptrTargets[bestUsr] = targets

proc resolveLockContracts(ctx: var Ctx) =
  ## Bind each `@acquires(lock)` / `@releases(lock)` to the function below it. Inside a
  ## `@threadsafe` scope it is a VERIFIED lock-balance contract — the raw operand is stored
  ## for key resolution in fnVisitor (cross-file, like @guarded_by). OUTSIDE one it stays an
  ## advisory (the engine doesn't run the lock-balance pass there), preserving the old behaviour
  ## for sparse-style contracts on bare prototypes.
  ctx.acquiresExprs = initTable[string, seq[string]]()
  ctx.releasesExprs = initTable[string, seq[string]]()
  proc covered(ctx: Ctx, fn: string): bool =
    fn.len > 0 and (ctx.prog.concurrentAll or fn in ctx.prog.concurrentFuncs)
  for site in ctx.acquireSites:
    let fn = ctx.siteFuncName(site.file, site.line)
    if ctx.covered(fn): ctx.acquiresExprs.mgetOrPut(fn, @[]).add site.expr
    else: ctx.prog.advisories.add Advisory(line: site.line, code: "ACQUIRES",
      msg: "advisory: this acquires '" & site.expr & "'. Reviewer: verify it is released on " &
           "every path (including early returns / errors) and not re-acquired while held. " &
           "(Mark the function `@threadsafe` to have kenbi verify this.)")
  for site in ctx.releaseSites:
    let fn = ctx.siteFuncName(site.file, site.line)
    if ctx.covered(fn): ctx.releasesExprs.mgetOrPut(fn, @[]).add site.expr
    else: ctx.prog.advisories.add Advisory(line: site.line, code: "RELEASES",
      msg: "advisory: this releases '" & site.expr & "'. Reviewer: verify the lock was held on " &
           "entry and is not used after release. (Mark the function `@threadsafe` to verify this.)")

proc resolveRequiresLock(ctx: var Ctx) =
  ## Bind each `@requires_lock(m)` to the callee below it by NAME and store the required lock's
  ## DISPLAY. lowerCall then emits an ikRequiredLockCall sink at every call to that callee, and
  ## the lock-balance pass (in a `@threadsafe` caller) verifies the lock is held. Display matching
  ## is exact for global / file-scope locks (the standard "hold the big lock first" precondition);
  ## field-lock preconditions need callee-param→call-arg resolution (a follow-up).
  ctx.requiresLockByCallee = initTable[string, seq[string]]()
  for site in ctx.requiresLockSites:
    let fn = ctx.siteFuncName(site.file, site.line)
    if fn.len == 0: continue
    ctx.requiresLockByCallee.mgetOrPut(fn, @[]).add site.expr

proc resolveVariants(ctx: var Ctx) =
  ## Bind each `@variant(member : tag == value)` to the function below it by NAME and store the
  ## raw operand exprs; fnVisitor resolves them against the defining function's params (cross-file).
  ctx.variants = initTable[string, seq[tuple[memberExpr, tagExpr: string, value: int]]]()
  for site in ctx.variantSites:
    let fn = ctx.siteFuncName(site.file, site.line)
    if fn.len == 0: continue
    let colon = site.spec.find(':')
    if colon < 0: continue
    let memberExpr = site.spec[0 ..< colon].strip
    let cond = site.spec[colon + 1 .. ^1].strip          # `n->tag == 0`
    let eq = cond.find("==")
    if eq < 0: continue
    let tagExpr = cond[0 ..< eq].strip
    var value: int
    try: value = parseInt(cond[eq + 2 .. ^1].strip)
    except ValueError: continue
    ctx.variants.mgetOrPut(fn, @[]).add (memberExpr, tagExpr, value)

proc splitConstOffset(expr: string): tuple[base: string, off: int] =
  ## Split a trailing `+ k` / `- k` constant offset off an operand (`buffer_mask + 1`).
  ## The `-` of a `->` arrow is not an offset operator, so only split on a top-level
  ## `+`/`-` that is followed by an integer literal. Returns (whole-expr, 0) if none.
  for i in countdown(expr.high, 1):
    let ch = expr[i]
    if ch != '+' and ch != '-': continue
    if expr[i-1] == '-' or expr[i-1] == '+': continue   # part of `->` / `++` etc
    let lhs = expr[0 ..< i].strip
    let rhs = expr[i+1 .. ^1].strip
    if lhs.len == 0: continue
    try:
      let k = parseInt(rhs)
      return (lhs, (if ch == '+': k else: -k))
    except ValueError: discard
  (expr.strip, 0)

proc resolveCountedBy(ctx: var Ctx) =
  ## Bind each `@counted_by(buf: size, …)` to the function below it and resolve the operands
  ## to keys, so lowering can seed the buffer's symbolic size. Relates a pointer to its length
  ## (the `(ptr, len)` C idiom) — without it a bound `pos < len` cannot be matched to the
  ## buffer `js`. Both operands may be a parameter name OR a one-level struct field path
  ## (`buffer->buffer: buffer->buffer_mask + 1`, the mask-based ring-buffer idiom), and the
  ## size may carry a constant `+ k` offset (the buffer holds `size + k` elements).
  ctx.countedBy = initTable[string, seq[tuple[bufExpr, sizeExpr: string, off: int]]]()
  for site in ctx.countedBySites:
    let fn = ctx.siteFuncName(site.file, site.line)
    if fn.len == 0: continue
    for pair in site.spec.split(','):
      let kv = pair.split(':')
      if kv.len != 2: continue
      let (sizeBase, sizeOff) = splitConstOffset(kv[1].strip)
      ctx.countedBy.mgetOrPut(fn, @[]).add (kv[0].strip, sizeBase, sizeOff)


proc splitRel(spec: string): tuple[ok: bool, lhs, rel, rhs: string] =
  ## Split `lvalue REL rvalue` at its relational operator, returning the trimmed operands
  ## and the operator. Recognises `<`, `<=` (UPPER invariant) and `>`, `>=` (LOWER). The
  ## `>` inside a `->` field arrow is skipped so `parser->toksuper >= -1` splits at the real
  ## `>=` (and `parser->toksuper > c` at the real `>`). Longer operators are tried first.
  for rel in ["<=", ">=", "<", ">"]:
    var start = 0
    while true:
      let idx = spec.find(rel, start)
      if idx < 0: break
      if rel == ">" and idx > 0 and spec[idx-1] == '-':   # the `>` of a `->` arrow, not a rel
        start = idx + 1; continue
      return (true, spec[0 ..< idx].strip, rel, spec[idx + rel.len .. ^1].strip)
  (false, "", "", "")

proc resolveInvariants(ctx: var Ctx) =
  ## Bind each `@invariant(lvalue rel size)` to the function below it and resolve its
  ## operands. UPPER (`<` / `<=`): both operands are lvalues — the PROTECTED field/var
  ## (`parser->toknext` -> a field path key, the same key its writes use) and the SIZE
  ## operand it is bounded by (which may itself be a PROTECTED FIELD — slice 6 — letting the
  ## spatial pass chain MULTI-HOP). LOWER (`>=` / `>`, C2): the lvalue is bounded below by a
  ## CONSTANT (`@invariant(toksuper >= -1)`); `> c` normalises to `>= c+1`. A field may carry
  ## both (toksuper: `< toknext` AND `>= -1`).
  ctx.invariants = initTable[string, seq[tuple[lhsExpr, rel, rhsExpr: string]]]()
  ctx.lowInvariants = initTable[string, seq[tuple[fieldExpr: string, lowConst: int]]]()
  for site in ctx.invariantSites:
    let fn = ctx.siteFuncName(site.file, site.line)
    if fn.len == 0: continue
    let parts = splitRel(site.spec)
    if not parts.ok: continue
    if parts.rel in ["<", "<="]:                        # UPPER: store both operand exprs + rel
      ctx.invariants.mgetOrPut(fn, @[]).add (parts.lhs, parts.rel, parts.rhs)
    else:                                               # `>=` / `>`: LOWER bound by a constant
      var c: int
      try: c = parseInt(parts.rhs)
      except ValueError: continue                       # a non-constant lower bound: not tracked
      if parts.rel == ">": inc c                        # `field > c` == `field >= c+1`
      ctx.lowInvariants.mgetOrPut(fn, @[]).add (parts.lhs, c)

proc countMarkedBack(stmts: seq[Stmt]): int =
  ## How many `@goto_backward`-tagged gotos (b == "@backward") the subtree holds.
  for s in stmts:
    case s.kind
    of stInstr:
      if s.ik == ikGoto and s.b == "@backward": inc result
    of stIf: result += countMarkedBack(s.thenBody) + countMarkedBack(s.elseBody)
    of stLoop: result += countMarkedBack(s.loopBody)
    of stSwitch: (for c in s.cases: result += countMarkedBack(c))
    of stTry:
      result += countMarkedBack(s.tryBody)
      for h in s.handlers: result += countMarkedBack(h)
    of stLabel: discard

proc firstMarkedBackHeader(stmts: seq[Stmt]): string =
  ## The target label of the first marked backward goto found (depth-first).
  for s in stmts:
    case s.kind
    of stInstr:
      if s.ik == ikGoto and s.b == "@backward": return s.a
    of stIf:
      result = firstMarkedBackHeader(s.thenBody)
      if result.len > 0: return
      result = firstMarkedBackHeader(s.elseBody)
      if result.len > 0: return
    of stLoop:
      result = firstMarkedBackHeader(s.loopBody)
      if result.len > 0: return
    of stTry:
      result = firstMarkedBackHeader(s.tryBody)
      if result.len > 0: return
      for h in s.handlers:
        result = firstMarkedBackHeader(h)
        if result.len > 0: return
    of stSwitch:
      for c in s.cases:
        result = firstMarkedBackHeader(c)
        if result.len > 0: return
    of stLabel: discard

proc countGotosTo(stmts: seq[Stmt], target: string): int =
  ## How many gotos (any kind) target `target` — used to ensure a candidate loop
  ## header is reached only by its single back-edge before we drop its label.
  for s in stmts:
    case s.kind
    of stInstr:
      if s.ik in {ikGoto, ikUnsupportedGoto} and s.a == target: inc result
    of stIf: result += countGotosTo(s.thenBody, target) + countGotosTo(s.elseBody, target)
    of stLoop: result += countGotosTo(s.loopBody, target)
    of stSwitch: (for c in s.cases: result += countGotosTo(c, target))
    of stTry:
      result += countGotosTo(s.tryBody, target)
      for h in s.handlers: result += countGotosTo(h, target)
    of stLabel: discard

proc rewriteBackwardLoop(body: seq[Stmt]): seq[Stmt] =
  ## A single `@goto_backward` to a top-level header, forming a simple do-while goto-loop,
  ## is restructured into an stLoop so the bounded fixpoint analyses it. The back-edge
  ## `if(cond) goto header;` becomes `if(cond) continue; else break;` (continue -> loop head,
  ## the not-taken exit -> break); a bare `goto header;` becomes `continue;` (an unconditional
  ## loop, exited via an inner break/return). Anything more complex is left unchanged — the
  ## marked backward goto then stays and the engine refuses it (UNSTRUCTURED_GOTO): sound.
  if countMarkedBack(body) != 1: return body
  let header = firstMarkedBackHeader(body)
  if header.len == 0: return body
  var hi = -1
  for i, s in body:
    if s.kind == stLabel and s.labelName == header: hi = i
  if hi < 0: return body                          # header is not a top-level label
  if countGotosTo(body, header) != 1: return body # header also reached by another goto
  # locate the back-goto's enclosing top-level statement (gi > hi): either a bare goto,
  # or `if(cond) goto header;` (then ends with the goto, no else).
  var gi = -1
  var conditional = false
  for i in hi+1 ..< body.len:
    let s = body[i]
    if s.kind == stInstr and s.ik == ikGoto and s.b == "@backward" and s.a == header:
      gi = i; conditional = false; break
    if s.kind == stIf and s.elseBody.len == 0 and s.thenBody.len >= 1:
      let t = s.thenBody[^1]
      if t.kind == stInstr and t.ik == ikGoto and t.b == "@backward" and t.a == header:
        gi = i; conditional = true; break
  if gi < 0: return body                          # back-goto nested deeper than v1 handles
  var loopBody: seq[Stmt]
  for i in hi+1 .. gi: loopBody.add body[i]
  if conditional:
    let theIf = loopBody[^1]                       # the `if(cond) goto header;`
    theIf.thenBody[^1] = Stmt(line: theIf.thenBody[^1].line, kind: stInstr, ik: ikContinue)
    theIf.elseBody = @[Stmt(line: theIf.line, kind: stInstr, ik: ikBreak)]
  else:
    loopBody[^1] = Stmt(line: loopBody[^1].line, kind: stInstr, ik: ikContinue)
  result = @[]
  for i in 0 ..< hi: result.add body[i]
  # a goto-loop runs its body at least once (the back-edge test follows the body), so the
  # synthetic loop is a do-while — its post-state must not include a 0-trip exit.
  result.add Stmt(line: body[hi].line, kind: stLoop, loopBody: loopBody, doWhile: true)
  for i in gi+1 ..< body.len: result.add body[i]

proc isFuncLikeKind(k: auto): bool =
  ## Every cursor kind that is a function-like DEFINITION carrying a body: a free function, a
  ## member function (ctor / dtor / method / conversion), or a function template (its
  ## uninstantiated body is still a real AST and lowers like any other). Anything here that
  ## the collector skipped would be a body kenbi never looked at — silently GREEN.
  k == ckFunctionDecl or k == ckCXXMethod or k == ckConstructor or k == ckDestructor or
  k == ckConversionFunction or k == ckFunctionTemplate

proc isFuncContainer(c: CXCursor): bool =
  ## A declaration that NESTS function-like definitions as its children: a namespace, an
  ## `extern "C" { }` linkage block, a class / struct / union (inline member definitions), or a
  ## class template. The visitors must RECURSE into these — returning cvrContinue at the top
  ## level never sees the functions inside (the namespace / extern "C" / method / template
  ## silent-drop reproduced on real KIR-generated C++).
  ## `extern "C" { }` is reported by libclang as ckUnexposedDecl (1), not ckLinkageSpec — both
  ## are recursed into. Descending into an UnexposedDecl is safe: the visitors only ACT on
  ## function-like kinds, so it can only ever surface nested functions, never mis-lower.
  let k = clang_getCursorKind(c)
  k == ckNamespace or k == ckLinkageSpec or k == ckUnexposedDecl or k == ckStructDecl or
  k == ckClassDecl or k == ckUnionDecl or k == ckClassTemplate

proc isMainFunc(c: CXCursor): bool =
  isFuncLikeKind(clang_getCursorKind(c)) and
  clang_Location_isFromMainFile(clang_getCursorLocation(c)) != 0

proc bodyOf(c: CXCursor): CXCursor =
  ## The CompoundStmt body of a function definition; a null cursor for a prototype.
  for k in collectChildren(c):
    if clang_getCursorKind(k) == ckCompoundStmt: return k

proc funcHasBody(c: CXCursor): bool =
  ## True iff this function decl is a DEFINITION (has a CompoundStmt body), not a bare
  ## prototype. Checked directly rather than via `bodyOf` because a prototype's `bodyOf`
  ## returns a default-constructed cursor that `clang_Cursor_isNull` does not treat as null.
  for k in collectChildren(c):
    if clang_getCursorKind(k) == ckCompoundStmt: return true

proc contractVisitor(c, parent: CXCursor, client: CXClientData): CXChildVisitResult {.cdecl.} =
  ## Pass 1: register each function's signature contract by name so callsites
  ## (which may precede the definition) can apply it.
  if isFuncContainer(c): return cvrRecurse        # descend into namespace / extern "C" / class
  if isFuncLikeKind(clang_getCursorKind(c)):
    let ctx = cast[ptr Ctx](client)
    # every function decl (incl. header prototypes) is recorded with its file and
    # ordered params so the generic resolver can bind cross-file contracts (e.g. a
    # `@arena_alloc` or `@moves` on a header prototype) to it by file + line window.
    ctx.funcSigs.add (fileOf(clang_getCursorLocation(c)), spelling(c),
                      startLine(c), funcParams(c), funcHasBody(c), qualName(c))
  cvrContinue

proc scanFoldableStatics(ctx: var Ctx) =
  ## The TU's provably-constant `static` integer variables and constant-returning `static`
  ## functions (see foldCond). A variable qualifies only if it is initialised to a constant and
  ## NOTHING in the TU assigns it, increments / decrements it, or takes its address; a function
  ## only if its whole body is a single `return <constant>;`.
  ctx.foldedStatics = initTable[string, int64]()
  ctx.foldedFns = initTable[string, int64]()
  var cands = initTable[string, int64]()
  var funcs: seq[CXCursor]
  proc top(c, p: CXCursor, client: CXClientData): CXChildVisitResult {.cdecl.} =
    let k = clang_getCursorKind(c)
    if k == ckNamespace or k == ckLinkageSpec or k == ckUnexposedDecl: return cvrRecurse
    if k == ckVarDecl and clang_Cursor_getStorageClass(c) == scStatic and isIntegerType(c):
      let kids = collectChildren(c)
      if kids.len > 0:
        let v = constIntValue(kids[^1])
        if v.known: cast[ptr Table[string, int64]](client)[][usr(c)] = v.value
    cvrContinue
  discard clang_visitChildren(clang_getTranslationUnitCursor(ctx.tu), top, addr cands)
  proc fv(c, p: CXCursor, client: CXClientData): CXChildVisitResult {.cdecl.} =
    if isFuncContainer(c): return cvrRecurse
    if isMainFunc(c) and clang_getCursorKind(bodyOf(c)) == ckCompoundStmt:
      cast[ptr seq[CXCursor]](client)[].add c
    cvrContinue
  discard clang_visitChildren(clang_getTranslationUnitCursor(ctx.tu), fv, addr funcs)
  var written: HashSet[string]
  proc walk(ctx: Ctx, n: CXCursor, written: var HashSet[string]) =
    let k = clang_getCursorKind(n)
    if k == ckBinaryOperator or k == ckCompoundAssign:
      let kids = collectChildren(n)
      if kids.len == 2 and (k == ckCompoundAssign or ctx.binOperator(n) == "="):
        let lhs = unwrap(kids[0])
        if clang_getCursorKind(lhs) == ckDeclRefExpr: written.incl referencedUsr(lhs)
    elif k == ckUnaryOperator:
      let toks = ctx.cursorTokens(n)
      if toks.len > 0 and (toks[0] in ["&", "++", "--"] or toks[^1] in ["++", "--"]):
        let kids = collectChildren(n)
        if kids.len == 1 and clang_getCursorKind(unwrap(kids[0])) == ckDeclRefExpr:
          written.incl referencedUsr(unwrap(kids[0]))
    for ch in collectChildren(n): ctx.walk(ch, written)
  for fn in funcs:
    ctx.walk(bodyOf(fn), written)
    # a `static` function whose body is exactly `return <const>;`
    if clang_Cursor_getStorageClass(fn) == scStatic:
      let stmts = collectChildren(bodyOf(fn))
      if stmts.len == 1 and clang_getCursorKind(stmts[0]) == ckReturnStmt:
        let rk = collectChildren(stmts[0])
        if rk.len == 1:
          let v = constIntValue(rk[0])
          if v.known: ctx.foldedFns[usr(fn)] = v.value
  for k, v in cands:
    if k notin written: ctx.foldedStatics[k] = v

proc scanCtorAllocs(ctx: var Ctx) =
  ## Every CONSTRUCTOR body's raw-member allocations: `data = malloc(...)` / `data = new T`
  ## where `data` is a member of the class (implicit or explicit `this`). An `@raii` class
  ## promises its destructor releases what its instances own — so the destructor's body is
  ## analysed entering with each such member owned (fnVisitor), and a destructor that does not
  ## release it leaks it: the declared RAII promise, verified against the implementation.
  ctx.ctorAllocs = initTable[string, seq[tuple[field: string, line: int, freed: bool]]]()
  var ctors: seq[CXCursor]
  proc cv(c, p: CXCursor, client: CXClientData): CXChildVisitResult {.cdecl.} =
    if isFuncContainer(c): return cvrRecurse
    if clang_getCursorKind(c) == ckConstructor and clang_getCursorKind(bodyOf(c)) == ckCompoundStmt:
      cast[ptr seq[CXCursor]](client)[].add c
    cvrContinue
  discard clang_visitChildren(clang_getTranslationUnitCursor(ctx.tu), cv, addr ctors)
  for ctor in ctors:
    let cls = spelling(clang_getCursorSemanticParent(ctor))
    if cls.len == 0: continue
    var found: seq[tuple[field: string, line: int, freed: bool]]
    proc walk(ctx: Ctx, n: CXCursor, found: var seq[tuple[field: string, line: int, freed: bool]]) =
      let k = clang_getCursorKind(n)
      if k == ckBinaryOperator and ctx.binOperator(n) == "=":
        let kids = collectChildren(n)
        if kids.len == 2:
          let lhs = unwrap(kids[0])
          let (fk, _) = fieldPath(lhs)
          if fk.startsWith("this::"):
            let rhs = unwrap(kids[1])
            let rk = clang_getCursorKind(rhs)
            if rk == ckCXXNewExpr or (rk == ckCallExpr and
               (spelling(rhs) in allocators or spelling(rhs) in ctx.customAllocRes)):
              found.add (fk[6 .. ^1], startLine(n), false)
      elif (k == ckCallExpr and spelling(n) in ctx.deallocators) or k == ckCXXDeleteExpr:
        # the constructor RELEASES the member it allocated (`free(data)` / `delete data`
        # after the allocation): the destructor then enters with it already freed
        for arg in collectChildren(n):
          let (fk, _) = fieldPath(unwrap(arg))
          if fk.startsWith("this::"):
            for i in 0 ..< found.len:
              if found[i].field == fk[6 .. ^1]: found[i].freed = true
      for kk in collectChildren(n): ctx.walk(kk, found)
    ctx.walk(bodyOf(ctor), found)
    if found.len > 0:
      for f in found:
        var dup = false
        for g in ctx.ctorAllocs.getOrDefault(cls, @[]):
          if g.field == f.field: dup = true
        if not dup: ctx.ctorAllocs.mgetOrPut(cls, @[]).add f

proc declaresDeleted(ctx: Ctx, c: CXCursor): bool =
  ## Is this member declared `= delete`? libclang before 16 has no `clang_CXXMethod_isDeleted`,
  ## so the declaration's own tokens answer it: `= delete` can only appear as the definition of
  ## the member being declared.
  var toks: ptr CXToken
  var cnt: cuint
  clang_tokenize(ctx.tu, clang_getCursorExtent(c), addr toks, addr cnt)
  defer: clang_disposeTokens(ctx.tu, toks, cnt)
  let arr = cast[ptr UncheckedArray[CXToken]](toks)
  var sawEq = false
  for i in 0 ..< int(cnt):
    let t = $clang_getTokenSpelling(ctx.tu, arr[i])
    if t == "=": sawEq = true
    elif sawEq and t == "delete": return true
    elif t != "delete": sawEq = sawEq and t == "="
  false

proc scanRaiiCopySafety(ctx: var Ctx) =
  ## THE RULE OF THREE, checked. A class declared `@raii` owns a resource its destructor
  ## releases. If the compiler is still allowed to copy it member-wise — no copy constructor,
  ## or no copy assignment operator, and neither deleted — then a copy hands two objects the
  ## same pointer and the second destructor releases it again. That is a double free the class
  ## carries with it to every caller, including ones in other translation units, so it is
  ## reported where the promise is made rather than at some copy site that may not exist yet.
  ##
  ## `= default` counts as NOT having one: a defaulted copy IS the member-wise copy. `= delete`
  ## resolves it — a class that cannot be copied cannot be copied wrongly.
  ##
  ## The finding is attached to the DESTRUCTOR, so the ordinary coverage gate and `@unsafe`
  ## apply to it exactly as to any other finding.
  if ctx.raiiTypes.len == 0: return
  ctx.copyGapClasses = initTable[string, seq[string]]()
  ctx.copyGaps = initTable[string, seq[tuple[cls, what: string, line: int]]]()
  var classes: seq[CXCursor]
  proc cv(c, p: CXCursor, client: CXClientData): CXChildVisitResult {.cdecl.} =
    let k = clang_getCursorKind(c)
    if k in [ckNamespace, ckLinkageSpec, ckUnexposedDecl]: return cvrRecurse
    if k in [ckClassDecl, ckStructDecl]:
      cast[ptr seq[CXCursor]](client)[].add c
    cvrContinue
  discard clang_visitChildren(clang_getTranslationUnitCursor(ctx.tu), cv, addr classes)
  for cls in classes:
    let name = spelling(cls)
    if name notin ctx.raiiTypes: continue
    var dtor = ""
    var hasCopyCtor, hasCopyAssign, copyCtorBlocked, copyAssignBlocked = false
    for m in collectChildren(cls):
      case clang_getCursorKind(m)
      of ckDestructor: dtor = spelling(m)
      of ckConstructor:
        if clang_CXXConstructor_isCopyConstructor(m) != 0:
          if ctx.declaresDeleted(m): copyCtorBlocked = true
          elif clang_CXXMethod_isDefaulted(m) == 0: hasCopyCtor = true
      of ckCXXMethod:
        if spelling(m) == "operator=" and funcParams(m).len == 1:
          if ctx.declaresDeleted(m): copyAssignBlocked = true
          elif clang_CXXMethod_isDefaulted(m) == 0: hasCopyAssign = true
      else: discard
    if dtor.len == 0: continue          # no destructor: nothing here releases, nothing to double
    if not hasCopyCtor and not copyCtorBlocked: ctx.copyGapClasses.mgetOrPut(name, @[]).add "copy constructor"
    if not hasCopyAssign and not copyAssignBlocked: ctx.copyGapClasses.mgetOrPut(name, @[]).add "copy assignment operator"

proc scanOwnerCopySites(ctx: var Ctx) =
  ## Where an `@raii` class that is MISSING a copy operation is actually copied. The finding
  ## belongs here, at the copy, and not on the class: a class that can be copied wrongly but
  ## never is has no double free, and saying otherwise on every owning class would be noise
  ## rather than a finding. A class copied in another translation unit is caught there, by this
  ## same scan — the class's `@raii` declaration travels in the header that TU includes.
  if ctx.copyGapClasses.len == 0 and ctx.selfAssignClasses.len == 0: return
  var fns: seq[CXCursor]
  proc fv(c, p: CXCursor, client: CXClientData): CXChildVisitResult {.cdecl.} =
    if isFuncContainer(c): return cvrRecurse
    if clang_getCursorKind(bodyOf(c)) == ckCompoundStmt:
      cast[ptr seq[CXCursor]](client)[].add c
    cvrContinue
  discard clang_visitChildren(clang_getTranslationUnitCursor(ctx.tu), fv, addr fns)
  for fn in fns:
    var sites: seq[tuple[cls, what: string, line: int]]
    proc walk(ctx: Ctx, n: CXCursor, sites: var seq[tuple[cls, what: string, line: int]]) =
      let k = clang_getCursorKind(n)
      if k == ckCallExpr:
        let refd = clang_getCursorReferenced(n)
        let rk = clang_getCursorKind(refd)
        if rk == ckConstructor:
          # `X b(a);` / `X b = a;` — a construction of X taking an lvalue X: the copy
          # constructor. `std::move(a)` is a MOVE and never member-wise-copies.
          let cls = raiiBaseName($clang_getTypeSpelling(clang_getCursorType(n)))
          if "copy constructor" in ctx.copyGapClasses.getOrDefault(cls, @[]):
            for arg in collectChildren(n):
              if stdMoveOperand(arg).has: continue
              if raiiBaseName($clang_getTypeSpelling(clang_getCursorType(unwrap(arg)))) == cls:
                sites.add (cls, "copy constructor", startLine(n))
                break
        elif rk == ckCXXMethod and spelling(refd) == "operator=":
          let kids = collectChildren(n)
          if kids.len >= 1:
            let cls = raiiBaseName($clang_getTypeSpelling(clang_getCursorType(unwrap(kids[0]))))
            if "copy assignment operator" in ctx.copyGapClasses.getOrDefault(cls, @[]):
              sites.add (cls, "copy assignment operator", startLine(n))
            elif cls in ctx.selfAssignClasses and kids.len >= 3:
              # `x = x` written out, through an operator that releases before it reads its
              # source: not a latent hazard but this path, now. The operator is reported at
              # its own declaration too — that says where to fix it; this says what breaks.
              # the two operands name the same object. Resolved from the cursors directly:
              # this scan runs before lowering, so the owner tables are not populated yet.
              # an operator call's children are [object, callee-reference, argument...]:
              # the source is the LAST, not the second.
              let l = unwrap(kids[0])
              let r = unwrap(kids[^1])
              if clang_getCursorKind(l) == ckDeclRefExpr and
                 clang_getCursorKind(r) == ckDeclRefExpr and
                 referencedUsr(l).len > 0 and referencedUsr(l) == referencedUsr(r):
                sites.add (cls, "SELF", startLine(n))
      for ch in collectChildren(n): ctx.walk(ch, sites)
    ctx.walk(bodyOf(fn), sites)
    if sites.len > 0: ctx.copyGaps[usr(fn)] = sites

proc scanSelfAssignSafety(ctx: var Ctx) =
  ## SELF-ASSIGNMENT SAFETY, checked the way kenbi checks anything: is the check on the path?
  ##
  ## `x = x` is legal C++ and the assignment operator must survive it. An operator that
  ## RELEASES a member and only afterwards reads the source's members has, on self-assignment,
  ## read memory it just freed. The two ways to be safe are both visible in the body:
  ##   * guard the work with a comparison of `this` against the source (`if (&o != this)`), or
  ##   * do the reading first and release only once the new value is in hand (copy-and-swap,
  ##     allocate-then-release) — then the release is not followed by any read of the source.
  ## Neither present, and the operator is unsafe for a case the language allows.
  ##
  ## Scoped to `@raii` classes: the declaration that the class owns something its destructor
  ## releases is what makes the release here meaningful. Every `operator=` DEFINITION in the
  ## translation unit is scanned, inline or out of line.
  if ctx.raiiTypes.len == 0: return
  ctx.selfAssign = initTable[string, string]()
  ctx.selfAssignClasses = initHashSet[string]()
  var meths: seq[CXCursor]
  proc mv(c, p: CXCursor, client: CXClientData): CXChildVisitResult {.cdecl.} =
    if isFuncContainer(c): return cvrRecurse
    if clang_getCursorKind(c) == ckCXXMethod and spelling(c) == "operator=" and
       clang_getCursorKind(bodyOf(c)) == ckCompoundStmt:
      cast[ptr seq[CXCursor]](client)[].add c
    cvrContinue
  discard clang_visitChildren(clang_getTranslationUnitCursor(ctx.tu), mv, addr meths)
  for m in meths:
    let cls = spelling(clang_getCursorSemanticParent(m))
    if cls notin ctx.raiiTypes: continue
    let ps = funcParams(m)
    if ps.len != 1: continue
    let pKey = ps[0].key
    let body = bodyOf(m)
    var guarded = false
    # SOURCE OFFSETS, not line numbers: an operator written on one line
    # (`{ delete[] d; d = new char[n]; copy(o.d); }`) has its release and its read of the source
    # on the same line, and a line comparison cannot order them.
    var releaseAt = high(int)
    var lastParamReadAt = -1
    var releaseLine = high(int)
    proc walk(ctx: Ctx, n: CXCursor) =
      let k = clang_getCursorKind(n)
      if k == ckIfStmt:
        # a condition mentioning both `this` and the source is the self-assignment check
        let kids = collectChildren(n)
        if kids.len >= 1:
          var sawThis, sawParam = false
          proc cond(ctx: Ctx, q: CXCursor) =
            if clang_getCursorKind(q) == ckCXXThisExpr: sawThis = true
            if clang_getCursorKind(q) == ckDeclRefExpr and referencedUsr(q) == pKey: sawParam = true
            for ch in collectChildren(q): ctx.cond(ch)
          ctx.cond(kids[0])
          if sawThis and sawParam: guarded = true
      elif (k == ckCallExpr and spelling(n) in ctx.deallocators) or k == ckCXXDeleteExpr:
        for arg in collectChildren(n):
          let (fk, _) = fieldPath(unwrap(arg))
          if fk.startsWith("this::"):
            if startOffset(n) < releaseAt:
              releaseAt = startOffset(n)
              releaseLine = startLine(n)
      elif k == ckDeclRefExpr and referencedUsr(n) == pKey:
        lastParamReadAt = max(lastParamReadAt, startOffset(n))
      for ch in collectChildren(n): ctx.walk(ch)
    ctx.walk(body)
    if not guarded and releaseAt < high(int) and lastParamReadAt > releaseAt:
      ctx.selfAssign[usr(m)] = cls
      ctx.selfAssignClasses.incl cls

proc fnVisitor(c, parent: CXCursor, client: CXClientData): CXChildVisitResult {.cdecl.} =
  ## Pass 2: lower each function definition's body into its own Func, seeding any
  ## `@frees` parameter as an incoming obligation so the body must discharge it.
  if isFuncContainer(c): return cvrRecurse        # descend into namespace / extern "C" / class
  if isMainFunc(c):
    let ctx = cast[ptr Ctx](client)
    let body = bodyOf(c)
    if clang_getCursorKind(body) != ckCompoundStmt: return cvrContinue  # prototype
    var fn = Func(name: spelling(c), line: startLine(c),
                  file: fileOf(clang_getCursorLocation(c)),
                  isStatic: clang_Cursor_getStorageClass(c) == scStatic,
                  copyGaps: ctx.copyGaps.getOrDefault(usr(c), @[]),
                  selfAssignCls: ctx.selfAssign.getOrDefault(usr(c), ""))
    # the key this function's contracts live under: `Class::method` for a member function
    let fnKey = (let q = qualName(c); if q.len > 0 and (ctx.bodyContracts.hasKey(q) or ctx.ownsOut.hasKey(q) or
                 ctx.countedBy.hasKey(q) or ctx.invariants.hasKey(q) or ctx.guardedBy.hasKey(q)): q else: spelling(c))
    ctx.callEdges = @[]   # accumulate this function's ownership-flow call edges
    # body param seeds (generic): @frees -> ikObligation (must be discharged ->
    # CONTRACT_NOT_HONORED), @borrows -> ikBorrow (non-owning; a stray free is
    # BORROW_FREED). Tracking is enabled so the body's free(p) is recognised.
    let params = funcParams(c)
    # The DEFINING function's param name -> key map. Declared contracts (@counted_by /
    # @invariant / @guarded_by) store their operands as raw exprs and are resolved HERE, against
    # THIS body's params — so a contract declared on a header prototype binds to its
    # implementation in another TU (cross-file: the operand `v->data` keys off THIS `v`).
    var implByName = initTable[string, string]()
    for p in params: implByName[p.name] = p.key
    # SPATIAL: seed declared `@counted_by` (ptr, len) pairs so a bound naming the size
    # parameter covers the buffer parameter (relates `js` to `len`, `tokens` to num_tokens).
    for pair in ctx.countedBy.getOrDefault(fnKey, @[]):
      let buf = resolveInvLValue(implByName, pair.bufExpr)
      let size = resolveInvLValue(implByName, pair.sizeExpr)
      if buf.ok and size.ok:
        ctx.bufSizeSym[buf.key] = (size.key, size.disp, pair.off)
    # INVARIANT: the protected fields of this function (write-barrier + @maintains targets).
    ctx.curProtected = initTable[string, tuple[disp, sizeKey, sizeDisp, rel: string,
                                               sizeUnsigned: bool]]()
    let unsignedKeys = unsignedIntParamKeys(c)
    for inv in ctx.invariants.getOrDefault(fnKey, @[]):
      let lhs = resolveInvLValue(implByName, inv.lhsExpr)
      let rhs = resolveInvLValue(implByName, inv.rhsExpr)
      if not lhs.ok or not rhs.ok: continue
      ctx.curProtected[lhs.key] = (lhs.disp, rhs.key, rhs.disp, inv.rel,
                                   rhs.key in unsignedKeys or rhs.key in ctx.fieldUnsigned)
      # carry the invariant to the engine so the spatial pass can CHAIN through it at an
      # index sink (`i < field` ∧ `field REL size` ⟹ `i < size`). symOff folds the
      # relation to a strict bound: `<=` is `field < size + 1`, `<` is `field < size`.
      fn.invariants.add (lhs.key, rhs.key, rhs.disp, (if inv.rel == "<=": 1 else: 0))
    # INVARIANT (C2): the LOWER invariants — a protected field known `>= lowConst`. Drives
    # the lower write-barrier check and seeds the field's known lower bound at index sinks.
    ctx.curProtectedLow = initTable[string, tuple[disp: string, lowConst: int]]()
    for lo in ctx.lowInvariants.getOrDefault(fnKey, @[]):
      let f = resolveInvLValue(implByName, lo.fieldExpr)
      if not f.ok: continue
      ctx.curProtectedLow[f.key] = (f.disp, lo.lowConst)
      fn.lowInvariants.add (f.key, lo.lowConst)
    # CONCURRENCY: the `@guarded_by(field: lock)` fields of this function — every access to
    # one emits an ikGuardedAccess sink requiring its lock to be held.
    ctx.curGuarded = initTable[string, tuple[disp, lockKey, lockDisp: string]]()
    for g in ctx.guardedBy.getOrDefault(fnKey, @[]):
      let field = resolveInvLValue(implByName, g.fieldExpr)
      let lock = resolveInvLValue(implByName, g.lockExpr)
      if field.ok and lock.ok:
        ctx.curGuarded[field.key] = (field.disp, lock.key, lock.disp)
    # CONCURRENCY (lock-balance): the `@acquires` / `@releases` lock contracts of this function,
    # resolved to held-set keys (the same key lockKeyOf produces at an acquire/release call).
    for e in ctx.acquiresExprs.getOrDefault(fnKey, @[]):
      let lk = resolveInvLValue(implByName, e)
      if lk.ok: fn.acquiresLocks.add (lk.key, lk.disp)
      elif e in ctx.lockClasses: fn.acquiresLocks.add (e, e)   # `@acquires(X)` names a lock class
    for e in ctx.releasesExprs.getOrDefault(fnKey, @[]):
      let lk = resolveInvLValue(implByName, e)
      if lk.ok: fn.releasesLocks.add (lk.key, lk.disp)
      elif e in ctx.lockClasses: fn.releasesLocks.add (e, e)
    # TYPE-CONFUSION: the `@variant(member : tag == value)` members of this function.
    ctx.curVariants = initTable[string, tuple[disp, tagKey, tagDisp: string, value: int]]()
    for v in ctx.variants.getOrDefault(fnKey, @[]):
      let member = resolveFieldPathExpr(implByName, v.memberExpr)
      let tag = resolveFieldPathExpr(implByName, v.tagExpr)
      if member.ok and tag.ok:
        ctx.curVariants[member.key] = (member.disp, tag.key, tag.disp, v.value)
    ctx.uninitLocals = initHashSet[string]()   # INIT: per-function definite-assignment candidates
    ctx[].scanStableScalars(c)                # CORRELATED BRANCHES: what cannot change here
    var seeded = initHashSet[string]()   # param keys given an ownership-contract seed
    ctx.ownsOutParams = initTable[string, string]()   # `@owns(p)` / `@owns(*p)` out-params
    for (idx, acc) in ctx.ownsOut.getOrDefault(fnKey, @[]):
      if idx < params.len: ctx.ownsOutParams[params[idx].key] = acc
    for (idx, instr, accessor) in ctx.bodyContracts.getOrDefault(fnKey, @[]):
      if idx >= params.len: continue
      let p = params[idx]
      if ctx.ownsOutParams.getOrDefault(p.key, "-") == "": continue   # an `@owns(p)` out-param carries nothing IN
      # An ACCESSOR contract binds the SLOT the contract names, not the parameter: `@frees(*p)`
      # owns the pointee, `@frees(p.f)` the field. Keyed like any other field path so the
      # existing read / release paths through `fieldPath` resolve it unchanged.
      let key = (if accessor.len == 0: p.key else: p.key & "::" & accessor)
      let disp = (if accessor.len == 0: p.name
                  elif accessor == "*": "*" & p.name
                  elif accessor.startsWith("["): p.name & accessor
                  else: p.name & "->" & accessor)
      # The SAME contract declared in two places — the header prototype the file includes and
      # the definition, which is ordinary practice — must seed the parameter ONCE. Seeding it
      # twice created two obligations for one parameter, and the single `free(p)` discharged
      # only the second: a false CONTRACT_NOT_HONORED on a function that honours its contract.
      if key in seeded: continue
      ctx.tracked[key] = true
      seeded.incl key
      fn.body.add emit(instr, startLine(c), a = disp, aKey = key)
      if instr == ikObligation: fn.freesParams.add (key, disp)
    # Every OTHER pointer parameter enters as an undeclared incoming pointer. Using /
    # passing it stays inert (we don't claim ownership, so a pure reader/forwarder is
    # NOT memory-relevant); only RELEASING it is UNCONTRACTED_RELEASE (intake-side
    # default-red). It goes in `incomingPtrs`, NOT `tracked`, so lowerCall emits an
    # ikFree for it only on a deallocator / @frees call, not on a use / pass.
    for p in pointerParams(c):
      if p.key in seeded: continue
      ctx.incomingPtrs.incl p.key
      fn.body.add emit(ikIncomingPtr, startLine(c), a = p.name, aKey = p.key)
    # `@raii` OWNER PARAMETERS — the binding form declares the contract (what KIR emits for
    # every sink): by value (`T v`, moved in at the callsite) or rvalue ref (`T&& v`) -> the
    # callee OWNS it, released by its destructor (ikRaiiAlloc: movable, never a leak); lvalue
    # ref (`T& v` / `const T& v`) -> a BORROW, the caller still owns it (ikBorrow: moving it
    # away is BORROW_MOVED). Tracked so std::move / member uses on the parameter are seen.
    if ctx.raiiTypes.len > 0:
      for parm in collectChildren(c):
        if clang_getCursorKind(parm) != ckParmDecl: continue
        let pkey = usr(parm)
        if pkey in seeded: continue
        let (tn, rawTy) = ctx[].ownerTypeName(parm)
        let owned = "&&" in rawTy or "&" notin rawTy
        if tn in ctx.raiiTypes:
          ctx.tracked[pkey] = true
          if owned:
            ctx.raiiVars[pkey] = tn
            fn.body.add emit(ikRaiiAlloc, startLine(c), a = spelling(parm), b = tn, aKey = pkey)
          else:
            fn.body.add emit(ikBorrow, startLine(c), a = spelling(parm), aKey = pkey)
        elif tn in ctx.structOwnerFields:
          # a struct parameter holding owner fields: by value / && the callee OWNS every field;
          # by lvalue reference every field is a BORROW (moving one away is BORROW_MOVED).
          var fields: seq[tuple[key, disp: string]]
          for f in ctx.structOwnerFields[tn]:
            let fk = pkey & "::" & f.name
            let fd = spelling(parm) & "->" & f.name
            ctx.tracked[fk] = true
            fields.add (fk, fd)
            if owned:
              ctx.raiiVars[fk] = f.cls
              fn.body.add emit(ikRaiiAlloc, startLine(c), a = fd, b = f.cls, aKey = fk)
            else:
              fn.body.add emit(ikBorrow, startLine(c), a = fd, aKey = fk)
          ctx.structOwnerVars[pkey] = fields
      # A MEMBER FUNCTION of a struct holding owner fields (inline or out-of-line: the semantic
      # parent is the class either way) enters owning every such field through `this` — keyed
      # `this::field`, the identity ownerRef gives `this->p` and the implicit-this `p`. Owned
      # like a by-value struct parameter: movable, released by the destructor (never a leak).
      let cls = spelling(clang_getCursorSemanticParent(c))
      if clang_getCursorKind(c) == ckDestructor and cls in ctx.raiiTypes and cls in ctx.ctorAllocs:
        # the DESTRUCTOR of an `@raii` class enters owning every raw member a constructor
        # allocated (ctorAllocs): the class's declared promise is that it releases them here —
        # a member the body never frees is a LEAK, one it frees twice a DOUBLE_FREE.
        for f in ctx.ctorAllocs[cls]:
          let fk = "this::" & f.field
          ctx.tracked[fk] = true
          fn.body.add emit(ikAlloc, startLine(c), a = "this->" & f.field,
                           b = ctx[].resourceFor(f.field, f.line), aKey = fk)
          if f.freed:   # the constructor already released it: a destructor free is a DOUBLE_FREE
            fn.body.add emit(ikFree, startLine(c), a = "this->" & f.field, aKey = fk)
      if cls in ctx.structOwnerFields:
        for f in ctx.structOwnerFields[cls]:
          let fk = "this::" & f.name
          ctx.tracked[fk] = true
          ctx.raiiVars[fk] = f.cls
          fn.body.add emit(ikRaiiAlloc, startLine(c), a = "this->" & f.name, b = f.cls, aKey = fk)
    for child in collectChildren(body):
      ctx[].lowerStmt(child, fn.body)
    fn.body = rewriteBackwardLoop(fn.body)   # declared goto-loops -> stLoop (fixpoint)
    fn.calls = ctx.callEdges
    ctx.prog.funcs.add fn
  cvrContinue

proc paramFreeScan(ctx: var Ctx, c: CXCursor) =
  ## For a function DEFINITION, record which of its pointer parameters its visible
  ## body frees (via `free` / a declared deallocator, directly by name). This is a
  ## *possibility* scan (not all-paths): even a conditional free counts, because it
  ## only feeds the advisory "this callee may free the arg — declare @frees". It
  ## never asserts; confirmation is the @frees annotation.
  ##
  ## The scan also records whether the body RETURNS something it released (`returnsFreed`),
  ## which is a fact about the result, not about any parameter — so a parameterless factory
  ## that frees the pointer it hands back is scanned too. (An early `params.len == 0` exit
  ## had skipped those entirely: `int *f(void) { int *q = new int; delete q; return q; }`
  ## handed out a dangling pointer that no caller was warned about.)
  let body = bodyOf(c)
  if clang_getCursorKind(body) != ckCompoundStmt: return
  let params = funcParams(c)
  var idxByKey = initTable[string, int]()
  for i, p in params: idxByKey[p.key] = i
  let deallocs = ctx.deallocators   # local copy: a closure cannot capture `var ctx`
  let nullRet = ctx.freeReturnsNull # releases DECLARED to hand back NULL
  var freed = initHashSet[int]()
  let tu = ctx.tu                          # a closure cannot capture `var ctx`
  proc binOp(n: CXCursor): string =
    var toks: ptr CXToken
    var cnt: cuint
    clang_tokenize(tu, clang_getCursorExtent(n), addr toks, addr cnt)
    defer: clang_disposeTokens(tu, toks, cnt)
    let arr = cast[ptr UncheckedArray[CXToken]](toks)
    for i in 0 ..< int(cnt):
      if clang_getTokenKind(arr[i]) == tkPunctuation:
        let t = $clang_getTokenSpelling(tu, arr[i])
        if t == "=": return t
        if t in ["==", "!=", "<=", ">=", "+=", "-="]: return t
    ""
  var freedKeys: HashSet[string]           # every variable the body visibly frees OUTRIGHT
  var returnedKeys: HashSet[string]        # every variable the body returns
  var assignBack: HashSet[string]          # `x = release(x)` — x is the release's RESULT after
  proc walk(n: CXCursor) =
    # `x = release(x)` hands x whatever the release returns (NULL, by the usual convention):
    # x is not a dangling pointer afterwards, so returning it is not handing one out. Recorded
    # separately from an outright `release(x)`.
    if clang_getCursorKind(n) == ckBinaryOperator and binOp(n) == "=":
      let bk = collectChildren(n)
      if bk.len == 2 and clang_getCursorKind(unwrap(bk[0])) == ckDeclRefExpr:
        let lhsKey = referencedUsr(unwrap(bk[0]))
        let rhs = unwrap(bk[1])
        if clang_getCursorKind(rhs) == ckCallExpr and spelling(rhs) in deallocs:
          for ai in 1 ..< collectChildren(rhs).len:
            let a = unwrap(collectChildren(rhs)[ai])
            if clang_getCursorKind(a) == ckDeclRefExpr and referencedUsr(a) == lhsKey:
              assignBack.incl lhsKey
    if clang_getCursorKind(n) == ckCallExpr and spelling(n) in deallocs:
      let kids = collectChildren(n)
      for ai in 1 ..< kids.len:
        let a = unwrap(kids[ai])
        if clang_getCursorKind(a) == ckDeclRefExpr:
          let k = referencedUsr(a)
          if k in idxByKey: freed.incl idxByKey[k]
          freedKeys.incl k
    elif clang_getCursorKind(n) == ckCXXDeleteExpr:
      # `delete p` releases just as `free(p)` does, but it is an EXPRESSION, not a call — so a
      # scan that only looked for calls saw a C++ body that releases as a body that releases
      # nothing. Its callers then learned neither that it takes their pointer nor that what it
      # returns is dangling, and a second release at the caller was silent: the whole
      # new/delete half of a source-frees/sink-frees flow went unreported while the identical
      # malloc/free code was caught.
      for k in collectChildren(n):
        let a = unwrap(k)
        if clang_getCursorKind(a) == ckDeclRefExpr:
          let key = referencedUsr(a)
          if key in idxByKey: freed.incl idxByKey[key]
          freedKeys.incl key
    elif clang_getCursorKind(n) == ckReturnStmt:
      let kids = collectChildren(n)
      if kids.len >= 1 and clang_getCursorKind(unwrap(kids[0])) == ckDeclRefExpr:
        returnedKeys.incl referencedUsr(unwrap(kids[0]))
      elif kids.len >= 1 and clang_getCursorKind(unwrap(kids[0])) == ckCallExpr and
           spelling(unwrap(kids[0])) in nullRet:
        # `return release(x);` where the release is DECLARED to hand back NULL: the error path
        # returns NULL, not the pointer it just released — the same reasoning as the
        # `x = release(x); return x;` assign-back one shape over, and licensed by the same
        # declaration rather than assumed. Without it a function with `return(Destroy(k));` on
        # its error paths and `return(k);` on its good ones looked like it hands out what it
        # freed, and every caller's use of the result became a use-after-free risk: 62 findings
        # in ImageMagick's morphology.c from one function.
        let rc = collectChildren(unwrap(kids[0]))
        for ai in 1 ..< rc.len:
          let a = unwrap(rc[ai])
          if clang_getCursorKind(a) == ckDeclRefExpr: assignBack.incl referencedUsr(a)
    for ch in collectChildren(n): walk(ch)
  walk(body)
  if freed.len > 0: ctx.bodyFreesParam[spelling(c)] = freed
  # a function that visibly frees a variable it also returns hands out a dangling pointer:
  # its callers' results are maybe-freed handles (ikMaybeFreedResult)
  for k in freedKeys:
    # ... so a value that is only ever released through the assign-back idiom is NOT a
    # dangling result: the release handed it its own return value (NULL) before it left.
    if k in returnedKeys and k notin assignBack: ctx.returnsFreed.incl spelling(c)

proc fieldUnsignedScan(ctx: var Ctx, c: CXCursor) =
  ## Record every `base->fld` whose member has an UNSIGNED integer type, keyed by the same
  ## field-path key its writes / bounds use, so the INVARIANT establish check can tell that a
  ## size operand that is a field (e.g. `toknext`) is >= 0. A reference reveals the member's
  ## type, so any one use of the field across the TU is enough.
  var found: seq[string]                   # collect locally: a closure cannot capture `var ctx`
  proc walk(n: CXCursor) =
    if clang_getCursorKind(n) == ckMemberRefExpr and isUnsignedInteger(n):
      let (fk, _) = fieldPath(n)
      if fk.len > 0: found.add fk
    for ch in collectChildren(n): walk(ch)
  walk(c)
  for fk in found: ctx.fieldUnsigned.incl fk

proc freeSummaryVisitor(c, parent: CXCursor, client: CXClientData): CXChildVisitResult {.cdecl.} =
  ## Pass 1.5: scan each main-file function definition for params it frees, so an
  ## uncontracted callsite can tell whether its callee *visibly* frees the arg; and collect
  ## unsigned-field signedness for the invariant establish check.
  if isFuncContainer(c): return cvrRecurse        # descend into namespace / extern "C" / class
  if isMainFunc(c):
    cast[ptr Ctx](client)[].paramFreeScan(c)
    cast[ptr Ctx](client)[].fieldUnsignedScan(c)
  cvrContinue

proc blankParallelPragmas*(src: string): tuple[text: string, count: int] =
  ## OpenMP / OpenACC directives are the one construct whose BODY libclang hides. With
  ## `-fopenmp` in the compile args — which is how these projects actually build — the parser
  ## attaches the loop to an `OMPParallelForDirective` cursor whose only children are the
  ## captured variable references, so the statement walk never reaches the loop: every
  ## allocation and release inside a `#pragma omp parallel for` body vanished from the IR and a
  ## double free across iterations came back GREEN. The construct cannot be reached through the
  ## cursor API at all, so the directive is removed BEFORE the parse: its text is replaced by
  ## spaces, byte for byte, so every offset, line and column in the AST still points at the
  ## untouched file on disk. The loop then lowers as an ordinary loop — the right reading for
  ## ownership, since a release that conflicts across iterations conflicts whether those
  ## iterations run in sequence or at once. (Races on shared state are the `@threadsafe` axis'
  ## subject; the pragma declares no lock discipline for it to verify.) Blanking happens whether
  ## or not `-fopenmp` reached us, so a file reads the same under either compile line.
  ## A trailing comment on the directive line is left in place (it may carry an annotation), and
  ## so is a comment delimiter, so a `#pragma` quoted inside a block comment cannot lose its
  ## terminator.
  var outp = src
  var count = 0
  let m = src.len
  var i = 0
  while i < m:
    # `# pragma omp …` — spaces are allowed both before the `#` and after it.
    var j = i
    while j < m and src[j] in {' ', '\t'}: inc j
    var isDirective = false
    if j < m and src[j] == '#':
      inc j
      while j < m and src[j] in {' ', '\t'}: inc j
      if src.continuesWith("pragma", j):
        j += 6
        while j < m and src[j] in {' ', '\t'}: inc j
        for w in ["omp", "acc"]:
          if src.continuesWith(w, j) and
             (j + w.len >= m or src[j + w.len] notin IdentChars): isDirective = true
    # the logical line: physical lines joined by a trailing backslash
    var e = i
    var lineStart = i
    while true:
      var le = lineStart
      while le < m and src[le] != '\n': inc le
      var t = le - 1
      while t >= lineStart and src[t] in {' ', '\t', '\r'}: dec t
      if t >= lineStart and src[t] == '\\' and le < m:
        lineStart = le + 1
        continue
      e = le
      break
    if isDirective:
      inc count
      var stop = e                        # do not blank into a comment
      for mark in ["//", "/*", "*/"]:
        let at = src.find(mark, i, e - 1)
        if at >= 0 and at < stop: stop = at
      for p in i ..< stop:
        if outp[p] != '\n': outp[p] = ' '
    i = (if e < m: e + 1 else: m)
  (outp, count)

proc checkContractPackages(ctx: var Ctx, args: seq[string]) =
  ## Check each `@contracts_for` package's `requires:` against the compile line kenbi was
  ## given. A requirement the build CONTRADICTS means the contracts may not describe this build
  ## at all; one the compile line does not settle (the macro comes from a config header, say) is
  ## recorded as unverified — never as satisfied. `version:` is not checkable from source and is
  ## carried as declared.
  var defined = initTable[string, string]()
  for a in args:
    if not a.startsWith("-D"): continue
    let body = a[2 .. ^1]
    let eq = body.find('=')
    if eq > 0: defined[body[0 ..< eq]] = body[eq+1 .. ^1]
    elif body.len > 0: defined[body] = "1"          # `-DNAME` defines it as 1
  for i in 0 ..< ctx.prog.contractPackages.len:
    for req in ctx.prog.contractPackages[i].requires:
      if req.name notin defined:
        ctx.prog.contractPackages[i].unverified.add req.name
      elif req.value.len > 0 and defined[req.name] != req.value:
        ctx.prog.contractPackages[i].mismatched.add(
          req.name & ": contracts assume " & req.value & ", this build has " & defined[req.name])

proc parseCFile*(path: string, extraArgs: seq[string] = @[], collectEffects = false): Program =
  let idx = clang_createIndex(0, 0)
  if idx.isNil: raise newException(CFrontError, "clang_createIndex failed")
  let lower = path.toLowerAscii
  let isCpp = lower.endsWith(".cpp") or lower.endsWith(".cc") or
              lower.endsWith(".cxx") or lower.endsWith(".hpp") or lower.endsWith(".hh")
  var args = (if isCpp: @["-x", "c++", "-std=c++17"] else: @["-std=c11"]) & extraArgs
  workingDirectory = ""
  for i, a in args:
    if a.startsWith("-working-directory="): workingDirectory = a["-working-directory=".len .. ^1]
    elif a == "-working-directory" and i + 1 < args.len: workingDirectory = args[i + 1]
  if workingDirectory.len > 0: workingDirectory = absolutePath(workingDirectory)
  var cargs = allocCStringArray(args)
  defer: deallocCStringArray(cargs)
  # A parallel directive hides the loop it wraps from the cursor API (blankParallelPragmas):
  # hand clang an in-memory copy with the directive spaced out, same length, same lines.
  var srcText = ""
  var originalText = ""
  var unsaved: CXUnsavedFile
  var nUnsaved = 0.cuint
  try:
    originalText = readFile(path)
    let (text, nPragma) = blankParallelPragmas(originalText)
    if nPragma > 0:
      srcText = text
      unsaved = CXUnsavedFile(filename: path.cstring, contents: srcText.cstring,
                              length: srcText.len.culong)
      nUnsaved = 1
  except CatchableError:
    discard        # unreadable here is unreadable for clang too: let the parse report it
  let tu = clang_parseTranslationUnit(idx, path.cstring, cargs, args.len.cint,
                                      (if nUnsaved > 0: addr unsaved else: nil), nUnsaved, 0)
  if tu.isNil:
    clang_disposeIndex(idx)
    raise newException(CFrontError, "failed to parse " & path)
  defer:
    clang_disposeTranslationUnit(tu)
    clang_disposeIndex(idx)
  # A non-nil TU can still be a PARTIAL parse: libclang recovers from a missing include or a
  # type error and hands back an AST in which the affected functions simply never lower, so
  # the file then looks clean (nothing to check) and the gate passes it — a false pass. Read
  # the diagnostics and REFUSE: an error-severity diagnostic is a parse failure (PARSE_ERROR,
  # exit 2), never "ok". Sound by refusal: an AST we cannot trust is not analysed silently.
  var nErr = 0
  var firstErr = ""
  for i in 0 ..< int(clang_getNumDiagnostics(tu)):
    let d = clang_getDiagnostic(tu, cuint(i))
    if clang_getDiagnosticSeverity(d) >= (if collectEffects: 2 else: 3):
      # Mandatory effect mode also refuses compiler warnings, including ignored
      # attributes/options whose hidden effects cannot safely be assumed absent.
      inc nErr
      if firstErr.len == 0: firstErr = $clang_getDiagnosticSpelling(d)
    clang_disposeDiagnostic(d)
  if nErr > 0:
    raise newException(CFrontError, "parse of " & path & " produced " & $nErr &
      " error diagnostic(s), so the AST is partial and cannot be treated as analysed; first: " &
      firstErr)
  var ctx = Ctx(tu: tu)
  # C++ with exceptions on: a call without a nothrow guarantee is an unwinding exit
  # (ikMayThrow). C has none; `-fno-exceptions` in the compile args turns them off.
  ctx.exceptionsOn = isCpp and "-fno-exceptions" notin args
  ctx.nothrowFuncs = initHashSet[string]()
  ctx.ownsOut = initTable[string, seq[tuple[idx: int, accessor: string]]]()
  ctx.addrOf = initTable[string, tuple[key, disp: string]]()
  ctx.pointeeAlias = initTable[string, string]()
  ctx.dynType = initTable[string, string]()
  ctx.newClass = initTable[string, string]()
  ctx.baseClasses = initHashSet[string]()
  proc bv(c, p: CXCursor, client: CXClientData): CXChildVisitResult {.cdecl.} =
    if clang_getCursorKind(c) == ckCXXBaseSpecifier:
      let b = clang_getCursorDefinition(clang_getTypeDeclaration(
                clang_getCanonicalType(clang_getCursorType(c))))
      if clang_Cursor_isNull(b) == 0: cast[ptr HashSet[string]](client)[].incl usr(b)
    cvrRecurse
  if isCpp: discard clang_visitChildren(clang_getTranslationUnitCursor(tu), bv, addr ctx.baseClasses)
  ctx.slotRes = initTable[string, string]()
  ctx.lambdaBodies = initTable[string, seq[Stmt]]()
  ctx.lambdaMemOp = initHashSet[string]()
  keyAlias = initTable[string, string]()
  ctx.prog.resources = initTable[string, Resource]()
  ctx.ownerRes = initTable[string, string]()
  ctx.tracked = initTable[string, bool]()
  ctx.fieldBaseVars = initHashSet[string]()
  ctx.bufSizeSym = initTable[string, tuple[symKey, symDisp: string, off: int]]()
  ctx.copyLines = initTable[int, string]()
  ctx.namedContracts = @[]
  ctx.drainLines = initTable[int, string]()
  ctx.linkFields = initHashSet[string]()
  ctx.listTypes = initTable[string, string]()
  ctx.varKeys = initTable[string, string]()
  ctx.varTypes = initTable[string, string]()
  ctx.localVars = initHashSet[string]()
  ctx.uninitLocals = initHashSet[string]()
  ctx.fieldUnsigned = initHashSet[string]()
  ctx.localArrayVars = initHashSet[string]()
  ctx.localAddrVars = initHashSet[string]()
  ctx.arenaCreate = initTable[string, string]()
  ctx.arenaAlloc = initHashSet[string]()
  ctx.prog.quarantined = initHashSet[int]()
  ctx.prog.escapesLines = initHashSet[int]()
  ctx.prog.reallocLines = initHashSet[int]()
  # These must be initialised BEFORE the comment scan: `@allocator` registers its family
  # (and its release functions) while parsing, and a later init would wipe what it stored.
  ctx.customAllocRes = initTable[string, string]()
  ctx.customRealloc = initHashSet[string]()
  ctx.freeReturnsNull = initHashSet[string]()
  ctx.deallocators = ["free"].toHashSet
  ctx.collectAnnotations()
  if not collectEffects and ctx.prog.effectMarkers.len > 0:
    raise newException(CFrontError, "@verify requires a --safety project; it cannot be ignored in ordinary analysis")
  ctx.checkContractPackages(args)   # do the shipped contracts describe THIS build?
  ctx.detectLockOrderConflicts()
  # recognise every declared `free:` deallocator (plus builtin free) as a release
  for r in ctx.prog.resources.values:
    if r.freeId.len > 0: ctx.deallocators.incl r.freeId
    for fid in r.freeIds: ctx.deallocators.incl fid
    # …and every declared `link:` field, so a walk along it lowers as a walk (ikLinkRead)
    if r.linkId.len > 0: ctx.linkFields.incl r.linkId
  for f in ctx.listTypes.values: ctx.linkFields.incl f
  let root = clang_getTranslationUnitCursor(tu)
  discard clang_visitChildren(root, contractVisitor, addr ctx)  # pass 1: collect contracts
  ctx.resolveContracts()                                        # bind ownership contracts (generic)
  ctx.resolveNamedContracts()                                   # `@contract F { … }` — by NAME
  ctx.resolveRaiiTypes()                                        # bind `@raii` owner classes
  ctx.scanCtorAllocs()                                          # raw members ctors allocate into
  ctx.scanRaiiCopySafety()                                      # the rule of three, per @raii class
  ctx.scanSelfAssignSafety()                                    # `x = x` must not read freed memory
  ctx.scanOwnerCopySites()                                      # ...and where either one is reached
  ctx.scanFoldableStatics()                                     # provably-constant statics / fns
  ctx.resolveKenbiCoverage()                                    # bind `@kenbi` opt-in markers
  ctx.resolveSpatialCoverage()                                  # bind `@spatial` opt-in markers
  ctx.resolveThreadsafeCoverage()                               # bind `@threadsafe` opt-in markers
  ctx.resolveInitCoverage()                                     # bind `@initcheck` opt-in markers
  ctx.resolveTypecheckCoverage()                                # bind `@typecheck` opt-in markers
  ctx.resolveVariants()                                         # bind `@variant(member: tag==v)`
  ctx.resolveCountedBy()                                        # bind `@counted_by` (ptr,len) pairs
  ctx.resolveInvariants()                                       # bind `@invariant` protected fields
  ctx.resolveGuardedBy()                                        # bind `@guarded_by(field: lock)`
  ctx.resolveGuardedMembers()                                   # bind single-arg `@guarded_by(lock)`
  ctx.resolveLockClasses()                                      # bind `@lock_class(X)` lock identity
  ctx.resolveLockAliases()                                      # v3 stage 2: verified pointer-alias class
  ctx.resolveFnptrTargets()                                     # v3 stage 4: `@calls` fnptr target sets
  ctx.resolveLockContracts()                                    # bind `@acquires` / `@releases`
  ctx.resolveRequiresLock()                                     # bind `@requires_lock` preconditions
  for lo in ctx.lockOrders: ctx.prog.lockOrder.add (lo.a, lo.b)  # declared @lock_order pairs
  ctx.bodyFreesParam = initTable[string, HashSet[int]]()
  ctx.returnsFreed = initHashSet[string]()
  discard clang_visitChildren(root, freeSummaryVisitor, addr ctx) # pass 1.5: visible-free summary
  discard clang_visitChildren(root, fnVisitor, addr ctx)        # pass 2: lower bodies
  if collectEffects:
    var effectsCpp = isCpp
    for arg in args:
      if "c++" in arg: effectsCpp = true
    ctx.prog.effects = collectEffectFacts(tu, effectsCpp, args, nUnsaved > 0,
      ctx.prog.effectMarkers, (path, originalText))
  result = ctx.prog
