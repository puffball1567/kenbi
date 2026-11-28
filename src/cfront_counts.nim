## REFERENCE COUNTING — the front-end half. Included by frontend_c.nim.
##
## A type declared `@refcounted T { count: f, retain: r, release: d }` is shared by counting
## references: every holder of a pointer to a `T` owns one SHARE, taken with `r` and given
## back with `d`, and the object is freed when the last share is given back. This file reads
## a function body and writes down, in source order and with the branches, loops, switches and
## labels kept, every event of that discipline (`ikCount`, see ir.nim). The reference-count
## pass (analyze_counts.nim) then follows the shares along every path.
##
## Nothing here decides anything: an expression this reader does not follow becomes an
## `rcUnmodeled` event, which the pass reports.

const rcAtomicOps = {
  # name -> (direction, the value it yields is the one AFTER the change)
  "atomic_fetch_add": (1, false), "atomic_fetch_sub": (-1, false),
  "atomic_fetch_add_explicit": (1, false), "atomic_fetch_sub_explicit": (-1, false),
  "__atomic_fetch_add": (1, false), "__atomic_fetch_sub": (-1, false),
  "__atomic_add_fetch": (1, true), "__atomic_sub_fetch": (-1, true),
  "__sync_fetch_and_add": (1, false), "__sync_fetch_and_sub": (-1, false),
  "__sync_add_and_fetch": (1, true), "__sync_sub_and_fetch": (-1, true)}.toTable

type
  RcDesigKind = enum rdNone, rdVar, rdSlot, rdNull, rdRaw, rdUnowned
  RcDesig = tuple[kind: RcDesigKind, key, disp: string]
  RcFn = object
    role: int
    subject: string                 ## key of the parameter the role is about
    countField: string              ## ... and the counter field of its type
    vars: Table[string, string]     ## this function's counted locals and parameters -> type
    names: Table[string, string]    ## ... and their names -> keys
    types: Table[string, string]    ## every designator key written -> its counted type
    rawVars: HashSet[string]        ## ... those assigned a new allocation
    slotKeys: HashSet[string]       ## the stored counted pointers it names, by the keys the
                                    ## ownership view gives them
    fnOwns: bool
    bodies: HashSet[string]         ## functions with a body in this translation unit
    labelsSeen: HashSet[string]
    scoped: HashSet[string]
    zeroIfs: seq[tuple[line: int, thenNonZero: bool]]
    any: bool                       ## some event was written

proc rcEmit(rc: var RcFn, op, line: int, a = "", aKey = "", b = "", bKey = "", cKey = "",
            off2 = 0): Stmt =
  rc.any = true
  Stmt(line: line, kind: stInstr, ik: ikCount, a: a, aKey: aKey, b: b, bKey: bKey, cKey: cKey,
       off: op, off2: off2)

proc rcTypeName(ctx: Ctx, t: CXType): string =
  ## The `@refcounted` type `t` points to, or "".
  if ctx.prog.counted.len == 0: return ""
  let ct = clang_getCanonicalType(t)
  if ct.kind != tyPointer: return ""
  let pointee = clang_getPointeeType(ct)
  let declName = spelling(clang_getTypeDeclaration(pointee))
  if declName in ctx.prog.counted: return declName
  # a `typedef struct { … } T;` has no tag: the name is the typedef's
  var written = $clang_getTypeSpelling(clang_getPointeeType(t))
  for q in ["const ", "volatile ", "struct "]: written = written.replace(q, "")
  written = written.strip()
  if written in ctx.prog.counted: return written
  ""

proc rcCountedExpr(ctx: Ctx, e: CXCursor): string =
  ## ... of the value of expression `e`, looking through casts.
  result = ctx.rcTypeName(clang_getCursorType(e))
  if result.len == 0: result = ctx.rcTypeName(clang_getCursorType(refStrip(e)))

proc rcIdentTokens(toks: seq[string]): seq[string] =
  for t in toks:
    if t.len > 0 and (t[0].isAlphaAscii or t[0] == '_'): result.add t

proc rcDesig(ctx: Ctx, rc: var RcFn, e: CXCursor): RcDesig =
  ## What a pointer expression names: a counted local or parameter, a stored pointer, null.
  let u = refStrip(e)
  let k = clang_getCursorKind(u)
  if k == ckCXXThisExpr:
    if "this" in rc.vars: return (rdVar, "this", "this")
    return
  if k == ckDeclRefExpr:
    let key = referencedUsr(u)
    if key in rc.vars: return (rdVar, key, spelling(u))
    if clang_getCursorKind(clang_getCursorReferenced(u)) == ckVarDecl and
       ctx.rcCountedExpr(u).len > 0:
      rc.slotKeys.incl key
      rc.types[rcSlotMark & spelling(u)] = ctx.rcCountedExpr(u)
      return (rdSlot, rcSlotMark & spelling(u), spelling(u))   # a global
    return
  if k in [ckMemberRefExpr, ckArraySubscriptExpr] or
     (k == ckUnaryOperator and ctx.firstTokenSpelling(u) == "*"):
    if ctx.rcCountedExpr(u).len > 0:
      let toks = ctx.cursorTokens(u)
      for key in [fieldPath(u).key, deepMemberKey(u).key]:
        if key.len > 0: rc.slotKeys.incl key
      if toks.len > 0:
        rc.types[rcSlotMark & toks.join(rcTokSep)] = ctx.rcCountedExpr(u)
        return (rdSlot, rcSlotMark & toks.join(rcTokSep), toks.join(""))
    return
  if clang_getCursorType(e).kind == tyPointer or ctx.rcCountedExpr(e).len > 0:
    if ctx.isNullLit(u): return (rdNull, "", "NULL")

proc rcExpr(ctx: Ctx, rc: var RcFn, e: CXCursor, outp: var seq[Stmt])
proc rcValue(ctx: Ctx, rc: var RcFn, e: CXCursor, outp: var seq[Stmt]): RcDesig

proc rcCounterOf(ctx: Ctx, rc: var RcFn, e: CXCursor): RcDesig =
  ## `e` is the counter field of a counted object: the pointer it is reached through.
  let u = refStrip(e)
  if clang_getCursorKind(u) != ckMemberRefExpr: return
  let kids = collectChildren(u)
  if kids.len == 0 or clang_getCursorKind(refStrip(kids[0])) == ckCXXThisExpr:
    # a member of the object a member function runs on
    let tn = rc.vars.getOrDefault("this", "")
    if tn.len > 0 and ctx.prog.counted[tn].count == spelling(u) and
       clang_getCursorKind(clang_getCursorReferenced(u)) == ckFieldDecl:
      return (rdVar, "this", "this")
    return
  let tn = ctx.rcCountedExpr(kids[0])
  if tn.len == 0 or ctx.prog.counted[tn].count != spelling(u): return
  result = ctx.rcDesig(rc, kids[0])
  if result.kind == rdNone: result = (rdSlot, "", ctx.cursorTokens(kids[0]).join(""))

var rcSourceCache {.threadvar.}: Table[string, string]

proc rcWrittenCall(ctx: Ctx, e: CXCursor, extra = 0): seq[string] =
  ## The tokens of a call as it is written in the source, from its name to its closing
  ## parenthesis — for a macro invocation, whose cursor has no tokens of its own. `extra`:
  ## that many more tokens after it (a comparison operator and its operand).
  let path = fileOf(clang_getCursorLocation(e))
  if path.len == 0: return
  if path notin rcSourceCache:
    rcSourceCache[path] = (try: readFile(path) except IOError: "")
  let text = rcSourceCache[path]
  var i = startOffset(e)
  var depth = 0
  while i >= 0 and i < text.len:
    let c = text[i]
    if c.isAlphaAscii or c == '_' or c.isDigit:
      var j = i
      while j < text.len and (text[j].isAlphaNumeric or text[j] == '_'): inc j
      result.add text[i ..< j]
      i = j
    elif c in Whitespace: inc i
    elif c == '-' and i + 1 < text.len and text[i + 1] == '>':
      result.add "->"
      i += 2
    else:
      result.add $c
      inc i
      if c == '(': inc depth
      elif c == ')':
        dec depth
        if depth <= 0: break
      elif c == ';': break
    if result.len == 1 and (i >= text.len or text[i] != '('): return @[]   # not a call
    if result.len > 64: break
  var left = extra
  while left > 0 and i < text.len:
    if text[i] in Whitespace: (inc i; continue)
    var j = i
    if text[i].isAlphaNumeric or text[i] == '_':
      while j < text.len and (text[j].isAlphaNumeric or text[j] == '_'): inc j
    else:
      inc j
      if j < text.len and text[j] == '=' and text[i] in {'=', '!', '<', '>'}: inc j
    result.add text[i ..< j]
    i = j
    dec left

proc rcAtomic(ctx: Ctx, rc: var RcFn, e: CXCursor):
    tuple[has: bool, d: RcDesig, delta: int, after: bool, setTo: int] =
  ## `setTo` >= 0: the counter is assigned that value (`atomic_init(&p->count, 1)`); -2: it is
  ## assigned something that is not a constant; -1: it is stepped by `delta`.
  ## `atomic_fetch_sub(&p->count, 1)` and its relatives, read from the tokens: the standard
  ## header spells them as macros over builtins libclang does not expose as calls.
  var toks = ctx.cursorTokens(e)
  if toks.len == 0 and clang_getCursorKind(e) == ckUnexposedExpr: toks = ctx.rcWrittenCall(e)
  if toks.len < 8 or toks[1] != "(" or toks[2] != "&": return
  let setter = toks[0] in ["atomic_init", "atomic_store", "atomic_store_explicit"]
  if toks[0] notin rcAtomicOps and not setter: return
  var j = 3
  var depth = 0
  while j < toks.len and not (depth == 0 and toks[j] == ","):
    if toks[j] == "(": inc depth
    elif toks[j] == ")": dec depth
    inc j
  # the expression is the call itself, not something that merely starts with it
  block:
    var d = 0
    var close = -1
    for i in 1 ..< toks.len:
      if toks[i] == "(": inc d
      elif toks[i] == ")":
        dec d
        if d == 0:
          close = i
          break
    if close != toks.len - 1: return
  # `&` NAME `->` FIELD `,` AMOUNT
  if j != 6 or toks[4] != "->" or j + 1 >= toks.len: return
  if not setter and toks[j + 1] != "1": return
  let key = rc.names.getOrDefault(toks[3], "")
  if key.len == 0 or ctx.prog.counted[rc.vars[key]].count != toks[5]: return
  if setter:
    var v = -2
    if toks[j + 1].allCharsInSet({'0'..'9'}) and (j + 2 >= toks.len or toks[j + 2] in [")", ","]):
      v = parseInt(toks[j + 1])
    return (true, (rdVar, key, toks[3]), 0, false, v)
  let op = rcAtomicOps[toks[0]]
  (true, (rdVar, key, toks[3]), op[0], op[1], -1)

proc rcCalleeTakes(ctx: Ctx, callee: string, pos: int): int =
  ## What `callee` declares about parameter `pos`: 2 it takes over a share, 1 it borrows,
  ## 0 nothing.
  for (idx, instr, accessor) in ctx.argContracts.getOrDefault(callee, @[]):
    if idx != pos or accessor.len > 0: continue
    if instr in {ikFree, ikMove, ikAdopt}: return 2
    if instr == ikBorrow: result = 1
  for (idx, instr, accessor) in ctx.bodyContracts.getOrDefault(callee, @[]):
    if idx == pos and accessor.len == 0 and instr == ikBorrow and result == 0: result = 1

proc rcHoldsCounted(ctx: Ctx, t: CXType, depth = 0): bool =
  ## A struct, class or array type with a pointer to a counted type somewhere inside it.
  if depth > 6 or ctx.prog.counted.len == 0: return false
  let ct = clang_getCanonicalType(t)
  if ct.kind != tyRecord:
    if ct.kind in [tyConstantArray, tyIncompleteArray]:
      return ctx.rcHoldsCounted(clang_getArrayElementType(ct), depth + 1)
    return false
  for f in collectChildren(clang_getTypeDeclaration(ct)):
    if clang_getCursorKind(f) != ckFieldDecl: continue
    let ft = clang_getCursorType(f)
    if ctx.rcTypeName(ft).len > 0 or ctx.rcHoldsCounted(ft, depth + 1): return true

proc rcAggregateCopy(ctx: Ctx, rc: var RcFn, value: CXCursor, line: int, outp: var seq[Stmt]) =
  ## `x = y` of a whole aggregate that holds counted pointers: every one of them is now held
  ## twice with one share.
  let u = refStrip(value)
  if clang_getCursorKind(u) in [119.cint, ckCallExpr]: return     # 119: an initialiser list
  if not ctx.rcHoldsCounted(clang_getCursorType(u)): return
  outp.add rc.rcEmit(rcUnmodeled, line,
    a = "'" & ctx.cursorTokens(u).join("") & "' is copied whole, and it holds pointers to " &
        "reference-counted objects: the copy holds each of them without a share of its own. " &
        "Copy the members, taking a share for each pointer.")

proc rcNewCount(ctx: Ctx, tn: string, t: CXType): int =
  ## The count a `new` object of counted class `tn` starts with, read from the class: the
  ## counter's default member initialiser, or what every constructor sets it to. -1 when the
  ## class does not say it with a constant, or a constructor's body is not in this file.
  let field = ctx.prog.counted[tn].count
  let cls = clang_getTypeDeclaration(clang_getPointeeType(clang_getCanonicalType(t)))
  var default = -1
  var ctors: seq[CXCursor]
  for m in collectChildren(cls):
    let mk = clang_getCursorKind(m)
    if mk == ckFieldDecl and spelling(m) == field:
      for ch in collectChildren(m):
        let u = refStrip(ch)
        if clang_getCursorKind(u) == ckIntegerLiteral: default = ctx.intLiteralValue(u)
    elif mk == ckConstructor: ctors.add m
  result = default
  for c in ctors:
    var def = clang_getCursorDefinition(c)
    if isNull(def):
      # a constructor that is only declared here: what it does to the counter is unknown,
      # unless it is the compiler's own (defaulted) one
      let toks = ctx.cursorTokens(c)
      if "default" in toks: continue
      return -1
    let toks = ctx.cursorTokens(def)
    var mine = default
    for i, t in toks:
      if t != field: continue
      if i + 3 < toks.len and toks[i + 1] in ["(", "{"] and toks[i + 2].allCharsInSet({'0'..'9'}) and
         toks[i + 3] in [")", "}"]:
        mine = parseInt(toks[i + 2])
      elif i + 3 < toks.len and toks[i + 1] == "=" and toks[i + 2].allCharsInSet({'0'..'9'}) and
           toks[i + 3] == ";":
        mine = parseInt(toks[i + 2])
      else: return -1
    if mine < 0: return -1
    if result >= 0 and ctors.len > 0 and mine != result and c != ctors[0]: return -1
    result = mine

proc rcIsAlloc(ctx: Ctx, e: CXCursor): bool =
  ## `e` is a new allocation: a call to an allocator, or a `new` expression.
  let u = refStrip(e)
  let k = clang_getCursorKind(u)
  if k == ckCXXNewExpr: return true
  if k != ckCallExpr: return false
  let name = spelling(u)
  name in allocators or name in ctx.customAllocRes

proc rcCall(ctx: Ctx, rc: var RcFn, call: CXCursor, outp: var seq[Stmt]) =
  ## The events of one call (its value is read by `rcValue`).
  let line = startLine(call)
  let name = spelling(call)
  let nargs = max(0, int(clang_Cursor_getNumArguments(call)))
  let decl = clang_getCursorReferenced(call)
  var roleOf = 0
  for tn, d in ctx.prog.counted:
    discard tn
    if name.len > 0:
      if name == d.retain: roleOf = 1
      elif name == d.release: roleOf = 2
      elif name == d.destroy: roleOf = 3
  let isMethod = clang_getCursorKind(decl) in refMethodKinds
  if roleOf != 0 and not isMethod and nargs == 0:
    outp.add rc.rcEmit(rcUnmodeled, line,
      a = "'" & name & "' is called without the object it acts on")
    return
  if roleOf in [1, 2]:
    var d: RcDesig
    if isMethod:
      # `p->retain()`: the object is what the member function is called on
      let o = ctx.refObject(call)
      if o.has and o.implicitThis and "this" in rc.vars: d = (rdVar, "this", "this")
      elif o.has and o.arrow: d = ctx.rcValue(rc, o.obj, outp)
      else:
        outp.add rc.rcEmit(rcUnmodeled, line,
          a = "'" & name & "' is called on an object that is not reached through a pointer: " &
              "a reference-counted object is handled through pointers to it")
        return
    else: d = ctx.rcValue(rc, clang_Cursor_getArgument(call, 0), outp)
    if d.kind in {rdVar, rdSlot} and d.key.len > 0:
      outp.add rc.rcEmit((if roleOf == 1: rcAcquire else: rcRelease), line, a = d.disp,
                         aKey = d.key, b = name)
    elif d.kind notin {rdNull}:
      outp.add rc.rcEmit(rcUnmodeled, line,
        a = "'" & name & "' is called on an expression kenbi cannot name as one pointer")
    return
  let isDealloc = name == "free" or name in ctx.deallocators
  if (roleOf == 3 or isDealloc) and nargs >= 1 and
     ctx.rcCountedExpr(clang_Cursor_getArgument(call, 0)).len > 0:
    let d = ctx.rcValue(rc, clang_Cursor_getArgument(call, 0), outp)
    if d.kind == rdVar:
      outp.add rc.rcEmit(rcDealloc, line, a = d.disp, aKey = d.key, b = name)
      outp.add rc.rcEmit(rcCall, line, a = d.disp, b = name)
    elif d.kind != rdNull:
      outp.add rc.rcEmit(rcUnmodeled, line,
        a = "'" & d.disp & "' is deallocated directly; a stored pointer to a counted object " &
            "is given up with its release function")
    return
  if name in ["memcpy", "memmove", "__builtin_memcpy", "__builtin_memmove"] and nargs >= 2:
    let src = refStrip(clang_Cursor_getArgument(call, 1))
    let st = clang_getCanonicalType(clang_getCursorType(src))
    if (st.kind == tyPointer and ctx.rcHoldsCounted(clang_getPointeeType(st))) or
       ctx.rcHoldsCounted(st):
      outp.add rc.rcEmit(rcUnmodeled, line,
        a = "'" & name & "' copies an object that holds pointers to reference-counted " &
            "objects: the copy holds each of them without a share of its own")
  var names: seq[string]
  var freshAfter: seq[RcDesig]
  var freedBase = ""
  for i in 0 ..< nargs:
    let arg = clang_Cursor_getArgument(call, cuint(i))
    let u = refStrip(arg)
    for t in rcIdentTokens(ctx.cursorTokens(arg)): names.add t
    if isDealloc and i == 0 and clang_getCursorKind(u) == ckDeclRefExpr: freedBase = spelling(u)
    if ctx.rcCountedExpr(arg).len > 0:
      let d = ctx.rcValue(rc, arg, outp)
      if d.kind in {rdVar, rdSlot}:
        let takes = ctx.rcCalleeTakes(name, i)
        if takes == 2:
          outp.add rc.rcEmit(rcRelease, line, a = d.disp, aKey = d.key, b = name, off2 = 1)
        else:
          outp.add rc.rcEmit(rcUse, line, a = d.disp, aKey = d.key, b = "passed to '" & name & "'",
                             off2 = (if name in knownBorrowFns: 0 else: 1))
          if takes == 0 and name notin rc.bodies and name notin knownBorrowFns:
            outp.add rc.rcEmit(rcUnproven, line, a = d.disp, b = name)
      continue
    # `&p`, the address of a counted local: an out-parameter the callee allocates into
    if clang_getCursorKind(u) == ckUnaryOperator and ctx.firstTokenSpelling(u) == "&":
      let kids = collectChildren(u)
      if kids.len == 1:
        let d = ctx.rcDesig(rc, kids[0])
        if d.kind == rdVar:
          var declared = false
          for (idx, acc) in ctx.ownsOut.getOrDefault(name, @[]):
            if idx == i: declared = true
          if declared: freshAfter.add d
          else:
            outp.add rc.rcEmit(rcUnmodeled, line,
              a = "the address of '" & d.disp & "' is passed to '" & name & "', which does " &
                  "not declare `@owns(…)` for that parameter: what it stores there is unknown")
          continue
    ctx.rcExpr(rc, arg, outp)
  if nargs == 0 or name.len == 0:
    # a call through a pointer, or a method: its callee expression may hold calls too
    for ch in collectChildren(call):
      if clang_getCursorKind(refStrip(ch)) == ckCallExpr: ctx.rcExpr(rc, ch, outp)
  if name notin knownBorrowFns:
    outp.add rc.rcEmit(rcCall, line, a = freedBase, b = (if name.len > 0: name else: "a call"),
                       cKey = names.join(rcTokSep))
  for d in freshAfter:
    outp.add rc.rcEmit(rcBind, line, a = d.disp, aKey = d.key, b = name, off2 = 1)

proc rcValue(ctx: Ctx, rc: var RcFn, e: CXCursor, outp: var seq[Stmt]): RcDesig =
  ## Writes the events of evaluating pointer expression `e` and says what its value names.
  let u = refStrip(e)
  let k = clang_getCursorKind(u)
  if k == ckCallExpr:
    let name = spelling(u)
    let nargs = int(clang_Cursor_getNumArguments(u))
    ctx.rcCall(rc, u, outp)
    for tn, d in ctx.prog.counted:
      discard tn
      if name == d.retain and nargs >= 1:
        # the retain function hands back the pointer it was given
        var sink: seq[Stmt]
        return ctx.rcValue(rc, clang_Cursor_getArgument(u, 0), sink)
    if ctx.rcIsAlloc(u): return (rdRaw, "", name)
    if ctx.rcCountedExpr(u).len > 0 and name.len > 0 and
       ctx.returnContracts.hasKey(name) and ctx.returnContracts[name].kind == rcOwned:
      let key = "\x02t" & $startOffset(u)
      rc.types[key] = ctx.rcCountedExpr(u)
      outp.add rc.rcEmit(rcBind, startLine(u), a = "the result of '" & name & "'", aKey = key,
                         off2 = 1)
      return (rdVar, key, "the result of '" & name & "'")
    return (rdUnowned, "", (if name.len > 0: "the result of '" & name & "'" else: "a call's result"))
  if k == ckCXXNewExpr:
    ctx.rcExpr(rc, u, outp)
    return (rdRaw, "", "new")
  result = ctx.rcDesig(rc, e)
  if result.kind == rdNone:
    ctx.rcExpr(rc, e, outp)
    result = (rdUnowned, "", ctx.cursorTokens(u).join(""))
  elif result.kind == rdSlot:
    # the expressions inside a stored pointer's name are evaluated too (`a[f(i)]`, `p->q->r`)
    for ch in collectChildren(u): ctx.rcExpr(rc, ch, outp)

proc rcAssign(ctx: Ctx, rc: var RcFn, target: RcDesig, value: CXCursor, line: int,
              outp: var seq[Stmt]) =
  ## `target = value` where `target` is a counted local or a stored counted pointer.
  let v = ctx.rcValue(rc, value, outp)
  if target.kind == rdVar:
    case v.kind
    of rdVar:
      if v.key.startsWith("\x02t") and outp.len > 0 and outp[^1].kind == stInstr and
         outp[^1].ik == ikCount and outp[^1].off == rcBind and outp[^1].aKey == v.key:
        # the result of an `@owns` function, received by this variable
        outp[^1].a = target.disp
        outp[^1].aKey = target.key
      else:
        outp.add rc.rcEmit(rcBind, line, a = target.disp, aKey = target.key, bKey = v.key)
    of rdSlot:
      outp.add rc.rcEmit(rcBind, line, a = target.disp, aKey = target.key, b = v.disp,
                         bKey = v.key, off2 = 3)
    of rdNull: outp.add rc.rcEmit(rcBind, line, a = target.disp, aKey = target.key, off2 = 4)
    of rdRaw:
      rc.rawVars.incl target.key
      outp.add rc.rcEmit(rcBind, line, a = target.disp, aKey = target.key, off2 = 2)
      if v.disp == "new" and target.key in rc.vars:
        # the class's own initialisation gives a `new` object its first count
        let n = ctx.rcNewCount(rc.vars[target.key], clang_getCursorType(value))
        if n >= 0: outp.add rc.rcEmit(rcSet, line, a = target.disp, aKey = target.key, off2 = n)
    else:
      outp.add rc.rcEmit(rcBind, line, a = target.disp, aKey = target.key, b = v.disp, off2 = 3)
  else:
    case v.kind
    of rdVar, rdSlot:
      outp.add rc.rcEmit(rcStore, line, a = target.disp, aKey = target.key, b = v.disp,
                         bKey = v.key)
    of rdNull: outp.add rc.rcEmit(rcStore, line, a = target.disp, aKey = target.key)
    else:
      # a pointer that comes with no share, or a new allocation whose counter is not set
      let key = "\x02t" & $startOffset(value)
      outp.add rc.rcEmit(rcBind, line, a = v.disp, aKey = key, off2 = (if v.kind == rdRaw: 2 else: 3))
      outp.add rc.rcEmit(rcStore, line, a = target.disp, aKey = target.key, b = v.disp, bKey = key)

proc rcStepOf(ctx: Ctx, rc: var RcFn, d: RcDesig, delta, line: int, outp: var seq[Stmt]) =
  if d.kind == rdVar:
    outp.add rc.rcEmit(rcStep, line, a = d.disp, aKey = d.key, off2 = delta)
  else:
    outp.add rc.rcEmit(rcUnmodeled, line,
      a = "the counter of '" & d.disp & "' is changed through a stored pointer")

proc rcExpr(ctx: Ctx, rc: var RcFn, e: CXCursor, outp: var seq[Stmt]) =
  ## The events of evaluating `e` when nothing reads its value as a counted pointer.
  let u = refStrip(e)
  let k = clang_getCursorKind(u)
  let line = startLine(u)
  let kids = collectChildren(u)
  block atomic:
    if k in [ckCallExpr, ckUnexposedExpr, ckParenExpr] or kids.len > 0:
      let at = ctx.rcAtomic(rc, u)
      if at.has:
        if at.setTo == -1: ctx.rcStepOf(rc, at.d, at.delta, line, outp)
        else:
          outp.add rc.rcEmit(rcSet, line, a = at.d.disp, aKey = at.d.key,
                             off2 = (if at.setTo >= 0: at.setTo else: -1))
        return
  case k
  of ckCallExpr:
    let v = ctx.rcValue(rc, u, outp)
    discard v      # an `@owns` result nobody takes stays bound to its temporary: a lost share
  of ckCXXDeleteExpr:
    if kids.len == 1 and ctx.rcCountedExpr(kids[0]).len > 0:
      let d = ctx.rcDesig(rc, kids[0])
      if d.kind == rdVar:
        outp.add rc.rcEmit(rcDealloc, line, a = d.disp, aKey = d.key, b = "delete")
        outp.add rc.rcEmit(rcCall, line, a = d.disp, b = "delete")
      elif d.kind != rdNull:
        outp.add rc.rcEmit(rcUnmodeled, line,
          a = "a reference-counted object is deleted directly through an expression kenbi " &
              "cannot name as one pointer")
    else:
      for ch in kids: ctx.rcExpr(rc, ch, outp)
      outp.add rc.rcEmit(rcCall, line, b = "delete")
  of ckDeclStmt:
    for ch in kids: ctx.rcExpr(rc, ch, outp)
  of ckVarDecl:
    let key = usr(u)
    let ty = clang_getCanonicalType(clang_getCursorType(u))
    var init: CXCursor
    var hasInit = false
    for ch in kids:
      if clang_getCursorKind(ch) notin [ckTypeRef, ckParmDecl] and
         clang_getCursorKind(ch) != 0: (init = ch; hasInit = true)
    if key in rc.vars:
      if hasInit: ctx.rcAssign(rc, (rdVar, key, spelling(u)), init, line, outp)
    else:
      if hasInit:
        ctx.rcExpr(rc, init, outp)
        ctx.rcAggregateCopy(rc, init, line, outp)
      if ty.kind != tyPointer:
        if isArrayType(u) or ty.kind == tyRecord:
          rc.scoped.incl spelling(u)
          outp.add rc.rcEmit(rcFreshBase, line, a = spelling(u), off2 = 1)
      elif hasInit and ctx.rcIsAlloc(init):
        outp.add rc.rcEmit(rcFreshBase, line, a = spelling(u))
  of ckBinaryOperator, ckCompoundAssign:
    let op = ctx.binOperator(u)
    if kids.len == 2 and op == "=":
      let cnt = ctx.rcCounterOf(rc, kids[0])
      if cnt.kind != rdNone:
        ctx.rcExpr(rc, kids[1], outp)
        let rhs = refStrip(kids[1])
        let v = (if clang_getCursorKind(rhs) == ckIntegerLiteral: ctx.intLiteralValue(rhs) else: -1)
        if cnt.kind == rdVar:
          outp.add rc.rcEmit(rcSet, line, a = cnt.disp, aKey = cnt.key, off2 = v)
        else:
          outp.add rc.rcEmit(rcUnmodeled, line,
            a = "the counter of '" & cnt.disp & "' is assigned through a stored pointer")
        return
      let target = ctx.rcDesig(rc, kids[0])
      if target.kind in {rdVar, rdSlot}:
        if target.kind == rdSlot:
          for ch in collectChildren(refStrip(kids[0])): ctx.rcExpr(rc, ch, outp)
        ctx.rcAssign(rc, target, kids[1], line, outp)
        return
      ctx.rcAggregateCopy(rc, kids[1], line, outp)
      # a counted pointer copied where its type no longer says what it is
      let v = ctx.rcDesig(rc, kids[1])
      ctx.rcExpr(rc, kids[0], outp)
      if v.kind == rdVar:
        let lt = ctx.cursorTokens(kids[0])
        outp.add rc.rcEmit(rcStore, line, a = lt.join(""), aKey = rcSlotMark & lt.join(rcTokSep),
                           b = v.disp, bKey = v.key)
      else:
        ctx.rcExpr(rc, kids[1], outp)
      let lu = refStrip(kids[0])
      if clang_getCursorKind(lu) == ckDeclRefExpr:
        outp.add rc.rcEmit(rcKill, line, a = spelling(lu))
        if ctx.rcIsAlloc(kids[1]) and referencedUsr(lu) in ctx.uqLocals:
          outp.add rc.rcEmit(rcFreshBase, line, a = spelling(lu))
      return
    if kids.len == 2 and op in ["+=", "-="]:
      let cnt = ctx.rcCounterOf(rc, kids[0])
      if cnt.kind != rdNone:
        let rhs = refStrip(kids[1])
        if clang_getCursorKind(rhs) == ckIntegerLiteral:
          let n = ctx.intLiteralValue(rhs)
          ctx.rcStepOf(rc, cnt, (if op == "+=": n else: -n), line, outp)
        else:
          outp.add rc.rcEmit(rcUnmodeled, line,
            a = "the counter of '" & cnt.disp & "' is changed by an amount that is not a constant")
        return
    for ch in kids: ctx.rcExpr(rc, ch, outp)
    if kids.len == 2 and op.endsWith("=") and op notin ["==", "!=", "<=", ">="]:
      let lu = refStrip(kids[0])
      if clang_getCursorKind(lu) == ckDeclRefExpr: outp.add rc.rcEmit(rcKill, line, a = spelling(lu))
  of ckUnaryOperator:
    let toks = ctx.cursorTokens(u)
    let step = ctx.incDecDelta(u)
    if step != 0 and kids.len == 1:
      let cnt = ctx.rcCounterOf(rc, kids[0])
      if cnt.kind != rdNone:
        ctx.rcStepOf(rc, cnt, step, line, outp)
        return
      ctx.rcExpr(rc, kids[0], outp)
      let lu = refStrip(kids[0])
      if clang_getCursorKind(lu) == ckDeclRefExpr: outp.add rc.rcEmit(rcKill, line, a = spelling(lu))
      return
    if toks.len > 0 and toks[0] == "&" and kids.len == 1:
      let d = ctx.rcDesig(rc, kids[0])
      if d.kind == rdVar:
        outp.add rc.rcEmit(rcUnmodeled, line,
          a = "the address of '" & d.disp & "' is taken: what is done through it is not followed")
        return
    if toks.len > 0 and toks[0] == "*" and kids.len == 1:
      let d = ctx.rcDesig(rc, kids[0])
      if d.kind == rdVar:
        outp.add rc.rcEmit(rcUse, line, a = d.disp, aKey = d.key, b = "dereferenced")
        return
    for ch in kids: ctx.rcExpr(rc, ch, outp)
  of ckMemberRefExpr:
    if kids.len >= 1:
      let d = ctx.rcDesig(rc, kids[0])
      if d.kind == rdVar and d.key == "this": return
      if d.kind == rdVar:
        let tn = rc.vars[d.key]
        if ctx.prog.counted[tn].count != spelling(u):
          outp.add rc.rcEmit(rcUse, line, a = d.disp, aKey = d.key, b = "dereferenced")
        return
    for ch in kids: ctx.rcExpr(rc, ch, outp)
  of ckArraySubscriptExpr:
    if kids.len == 2:
      let d = ctx.rcDesig(rc, kids[0])
      if d.kind == rdVar:
        outp.add rc.rcEmit(rcUse, line, a = d.disp, aKey = d.key, b = "dereferenced")
        ctx.rcExpr(rc, kids[1], outp)
        return
    for ch in kids: ctx.rcExpr(rc, ch, outp)
  of ckLambdaExpr:
    for t in rcIdentTokens(ctx.cursorTokens(u)):
      block:
        if t in rc.names:
          outp.add rc.rcEmit(rcUnmodeled, line,
            a = "'" & t & "' is used inside a lambda, which the reference-count pass does not read")
          return
  else:
    for ch in kids: ctx.rcExpr(rc, ch, outp)

proc rcNullTest(ctx: Ctx, rc: var RcFn, cond: CXCursor, s: Stmt) =
  ## `p`, `!p`, `p == NULL`, `p != NULL` on a counted pointer: which branch has it non-null.
  let cu = refStrip(cond)
  let k = clang_getCursorKind(cu)
  let direct = ctx.rcDesig(rc, cu)
  if direct.kind in {rdVar, rdSlot}:
    s.condKey = direct.key; s.condDisp = direct.disp; s.condThenNonNull = true
  elif k == ckUnaryOperator and ctx.firstTokenSpelling(cu) == "!":
    let kids = collectChildren(cu)
    if kids.len == 1:
      let d = ctx.rcDesig(rc, kids[0])
      if d.kind in {rdVar, rdSlot}:
        s.condKey = d.key; s.condDisp = d.disp; s.condThenNonNull = false
  elif k == ckBinaryOperator:
    let op = ctx.binOperator(cu)
    let kids = collectChildren(cu)
    if kids.len == 2 and op in ["==", "!="]:
      let l = ctx.rcDesig(rc, kids[0])
      let r = ctx.rcDesig(rc, kids[1])
      var d: RcDesig
      if l.kind in {rdVar, rdSlot} and ctx.isNullLit(refStrip(kids[1])): d = l
      elif r.kind in {rdVar, rdSlot} and ctx.isNullLit(refStrip(kids[0])): d = r
      if d.kind != rdNone:
        s.condKey = d.key; s.condDisp = d.disp; s.condThenNonNull = (op == "!=")

proc rcZeroTest(ctx: Ctx, rc: var RcFn, cond: CXCursor, s: Stmt) =
  ## In a release function: is the condition the test "no share is left"? Recognised on the
  ## counter of the function's own parameter — its value after the decrement compared with 0,
  ## or its value before compared with 1 — and recorded as which branch still has shares.
  if rc.role != 2: return
  proc operand(ctx: Ctx, rc: var RcFn, e: CXCursor): tuple[ok: bool, zeroAt: int] =
    ## the counter expression `e`, and the value it has when no share is left
    let u = refStrip(e)
    let at = ctx.rcAtomic(rc, u)
    if at.has and at.setTo == -1 and at.d.key == rc.subject and at.delta == -1:
      return (true, (if at.after: 0 else: 1))
    if clang_getCursorKind(u) == ckUnaryOperator and ctx.incDecDelta(u) == -1:
      let kids = collectChildren(u)
      if kids.len == 1 and ctx.rcCounterOf(rc, kids[0]).key == rc.subject:
        return (true, (if ctx.firstTokenSpelling(u) == "--": 0 else: 1))
    let c = ctx.rcCounterOf(rc, u)
    if c.kind == rdVar and c.key == rc.subject: return (true, 0)
  let cu = refStrip(cond)
  let k = clang_getCursorKind(cu)
  var found = false
  var thenNonZero = false
  let direct = operand(ctx, rc, cu)
  if direct.ok and direct.zeroAt == 0:
    found = true; thenNonZero = true
  elif k == ckUnaryOperator and ctx.firstTokenSpelling(cu) == "!":
    let kids = collectChildren(cu)
    if kids.len == 1:
      let o = operand(ctx, rc, kids[0])
      if o.ok and o.zeroAt == 0: (found = true; thenNonZero = false)
  elif k == ckBinaryOperator:
    var op = ctx.binOperator(cu)
    let kids = collectChildren(cu)
    if kids.len == 2 and clang_getCursorKind(refStrip(kids[1])) == ckIntegerLiteral:
      let o = operand(ctx, rc, kids[0])
      var lit = ctx.intLiteralValue(refStrip(kids[1]))
      if o.ok and op.len == 0:
        # the left side is a macro invocation: the comparison is read from the source
        let w = ctx.rcWrittenCall(refStrip(kids[0]), extra = 2)
        if w.len >= 2 and w[^1].allCharsInSet({'0'..'9'}):
          op = w[^2]
          lit = parseInt(w[^1])
        else: lit = -99
      if o.ok:
        if lit == o.zeroAt and op in ["==", "<="]: (found = true; thenNonZero = false)
        elif lit == o.zeroAt and op in ["!=", ">"]: (found = true; thenNonZero = true)
        elif lit == o.zeroAt + 1 and op == "<": (found = true; thenNonZero = false)
        elif lit == o.zeroAt + 1 and op == ">=": (found = true; thenNonZero = true)
  if found:
    s.predKey = "rc:zero"
    s.predThenNonZero = thenNonZero
    rc.zeroIfs.add (s.line, thenNonZero)

proc rcStmt(ctx: Ctx, rc: var RcFn, c: CXCursor, outp: var seq[Stmt])

proc rcSwitchItems(c: CXCursor, items: var seq[tuple[label, isDefault: bool, stmt: CXCursor]]) =
  let k = clang_getCursorKind(c)
  if k in [ckCaseStmt, ckDefaultStmt]:
    items.add (true, k == ckDefaultStmt, c)
    let kids = collectChildren(c)
    if kids.len > 0: rcSwitchItems(kids[^1], items)
  else:
    items.add (false, false, c)

proc rcStmt(ctx: Ctx, rc: var RcFn, c: CXCursor, outp: var seq[Stmt]) =
  let k = clang_getCursorKind(c)
  let kids = collectChildren(c)
  let line = startLine(c)
  case k
  of ckCompoundStmt:
    for ch in kids: ctx.rcStmt(rc, ch, outp)
  of ckIfStmt:
    var i = 0
    if kids.len >= 3 and clang_getCursorKind(kids[0]) in [ckDeclStmt, ckVarDecl]:
      ctx.rcExpr(rc, kids[0], outp)
      i = 1
    var s = Stmt(line: line, kind: stIf)
    if i < kids.len:
      ctx.rcExpr(rc, kids[i], outp)
      ctx.rcNullTest(rc, kids[i], s)
      ctx.rcZeroTest(rc, kids[i], s)
    if i + 1 < kids.len: ctx.rcStmt(rc, kids[i + 1], s.thenBody)
    if i + 2 < kids.len: ctx.rcStmt(rc, kids[i + 2], s.elseBody)
    outp.add s
  of ckWhileStmt:
    var s = Stmt(line: line, kind: stLoop)
    if kids.len >= 1: ctx.rcExpr(rc, kids[0], s.loopBody)
    s.headerAt = s.loopBody.len
    if kids.len >= 2: ctx.rcStmt(rc, kids[^1], s.loopBody)
    s.tailAt = s.loopBody.len
    outp.add s
  of ckDoStmt:
    var s = Stmt(line: line, kind: stLoop, doWhile: true)
    if kids.len >= 1: ctx.rcStmt(rc, kids[0], s.loopBody)
    s.tailAt = s.loopBody.len
    if kids.len >= 2: ctx.rcExpr(rc, kids[^1], s.loopBody)
    outp.add s
  of ckForStmt:
    # libclang gives only the header parts that are written: they are told apart by where
    # they lie relative to the header's two `;`
    var s = Stmt(line: line, kind: stLoop)
    let body = (if kids.len > 0: kids[^1] else: c)
    var semiOffs: seq[int]
    block:
      var tk: ptr CXToken
      var n: cuint
      clang_tokenize(ctx.tu, clang_getCursorExtent(c), addr tk, addr n)
      let arr = cast[ptr UncheckedArray[CXToken]](tk)
      var depth = 0
      for j in 0 ..< int(n):
        let sp = $clang_getTokenSpelling(ctx.tu, arr[j])
        if sp == "(": inc depth
        elif sp == ")":
          dec depth
          if depth == 0: break
        elif sp == ";" and depth == 1:
          semiOffs.add offsetOf(clang_getTokenLocation(ctx.tu, arr[j]))
      clang_disposeTokens(ctx.tu, tk, n)
    var tail: seq[Stmt]
    for j in 0 ..< kids.len - 1:
      let o = startOffset(kids[j])
      if semiOffs.len < 2 or o < semiOffs[0]: ctx.rcExpr(rc, kids[j], outp)        # initialiser
      elif o < semiOffs[1]: ctx.rcExpr(rc, kids[j], s.loopBody)                    # condition
      else: ctx.rcExpr(rc, kids[j], tail)                                           # increment
    s.headerAt = s.loopBody.len
    if kids.len > 0: ctx.rcStmt(rc, body, s.loopBody)
    s.tailAt = s.loopBody.len
    s.loopBody.add tail
    outp.add s
  of ckCXXForRangeStmt:
    var s = Stmt(line: line, kind: stLoop)
    for j in 0 ..< kids.len - 1: ctx.rcExpr(rc, kids[j], outp)
    if kids.len > 0: ctx.rcStmt(rc, kids[^1], s.loopBody)
    s.tailAt = s.loopBody.len
    outp.add s
  of ckSwitchStmt:
    var i = 0
    if kids.len >= 3 and clang_getCursorKind(kids[0]) in [ckDeclStmt, ckVarDecl]:
      ctx.rcExpr(rc, kids[0], outp)
      i = 1
    if i < kids.len: ctx.rcExpr(rc, kids[i], outp)
    var s = Stmt(line: line, kind: stSwitch)
    if kids.len > i + 1:
      var items: seq[tuple[label, isDefault: bool, stmt: CXCursor]]
      for ch in (if clang_getCursorKind(kids[^1]) == ckCompoundStmt: collectChildren(kids[^1])
                 else: @[kids[^1]]):
        rcSwitchItems(ch, items)
      for j in 0 ..< items.len:
        if not items[j].label: continue
        if items[j].isDefault: s.hasDefault = true
        if j + 1 < items.len and items[j + 1].label: continue    # `case 1: case 2:` — one group
        var body: seq[Stmt]
        for m in j + 1 ..< items.len:
          if not items[m].label: ctx.rcStmt(rc, items[m].stmt, body)
        s.cases.add body
    outp.add s
  of ckLabelStmt:
    rc.labelsSeen.incl spelling(c)
    outp.add Stmt(line: line, kind: stLabel, labelName: spelling(c))
    for ch in kids: ctx.rcStmt(rc, ch, outp)
  of ckGotoStmt:
    let tgt = spelling(clang_getCursorReferenced(c))
    if tgt.len == 0 or tgt in rc.labelsSeen:
      outp.add rc.rcEmit(rcUnmodeled, line,
        a = "a backward `goto` is not followed by the reference-count pass")
    outp.add Stmt(line: line, kind: stInstr, ik: ikGoto, a: tgt)
  of ckIndirectGotoStmt:
    outp.add rc.rcEmit(rcUnmodeled, line, a = "a computed `goto` is not followed")
    outp.add Stmt(line: line, kind: stInstr, ik: ikReturn)
  of ckBreakStmt: outp.add Stmt(line: line, kind: stInstr, ik: ikBreak)
  of ckContinueStmt: outp.add Stmt(line: line, kind: stInstr, ik: ikContinue)
  of ckReturnStmt:
    if kids.len == 1 and ctx.rcCountedExpr(kids[0]).len > 0:
      let v = ctx.rcValue(rc, kids[0], outp)
      case v.kind
      of rdVar, rdSlot:
        if rc.fnOwns: outp.add rc.rcEmit(rcRelease, line, a = v.disp, aKey = v.key, off2 = 2)
        else: outp.add rc.rcEmit(rcUse, line, a = v.disp, aKey = v.key, b = "returned")
      of rdUnowned, rdRaw:
        if rc.fnOwns:
          let key = "\x02t" & $startOffset(kids[0])
          outp.add rc.rcEmit(rcBind, line, a = v.disp, aKey = key,
                             off2 = (if v.kind == rdRaw: 2 else: 3))
          outp.add rc.rcEmit(rcRelease, line, a = v.disp, aKey = key, off2 = 2)
      else: discard
    else:
      for ch in kids: ctx.rcExpr(rc, ch, outp)
      if kids.len == 1:
        for t in rcIdentTokens(ctx.cursorTokens(kids[0])):
          if t in rc.scoped: outp.add rc.rcEmit(rcMovedOut, line, a = t)
    outp.add Stmt(line: line, kind: stInstr, ik: ikReturn)
  else:
    ctx.rcExpr(rc, c, outp)

proc rcCollectVars(ctx: Ctx, rc: var RcFn, c: CXCursor) =
  ## Every local and parameter of the function whose type points to a counted type.
  let k = clang_getCursorKind(c)
  if k in [ckVarDecl, ckParmDecl]:
    let tn = ctx.rcTypeName(clang_getCursorType(c))
    if tn.len > 0 and (k == ckParmDecl or usr(c) in ctx.uqLocals):
      rc.vars[usr(c)] = tn
      rc.names[spelling(c)] = usr(c)
  if k == ckLambdaExpr: return
  for ch in collectChildren(c): ctx.rcCollectVars(rc, ch)

proc rcStripped(stmts: seq[Stmt], keys: HashSet[string]): seq[Stmt] =
  ## The lowered body without the ownership events of the pointers in `keys`: those are
  ## shares, which the reference-count pass accounts for, not exclusively owned blocks.
  const owned = {ikAlloc, ikCopy, ikRealloc, ikInterior, ikUse, ikFree, ikMove, ikAdopt,
                 ikNullable, ikNonNull, ikDeref, ikObligation, ikBorrow, ikUnaccountedFree,
                 ikIncomingPtr, ikMaybeFreedResult, ikSetNull, ikRebind, ikEscape, ikEscapeCall,
                 ikEscapeCallFrees, ikFieldBaseEscape, ikMustUse}
  for s in stmts:
    case s.kind
    of stInstr:
      if s.ik in owned and (s.aKey in keys or (s.ik == ikCopy and s.bKey in keys)): continue
      if s.ik == ikReturn and s.aKey in keys:
        var c = Stmt(line: s.line, kind: stInstr)
        c[] = s[]
        c.a = ""; c.aKey = ""
        result.add c
      else: result.add s
    of stIf:
      var c = Stmt(line: s.line, kind: stIf)
      c[] = s[]
      c.thenBody = rcStripped(s.thenBody, keys)
      c.elseBody = rcStripped(s.elseBody, keys)
      if c.condKey in keys: c.condKey = ""
      result.add c
    of stLoop:
      var c = Stmt(line: s.line, kind: stLoop)
      c[] = s[]
      c.loopBody = rcStripped(s.loopBody, keys)
      var before = 0
      for i in 0 ..< min(s.headerAt, s.loopBody.len):
        let h = s.loopBody[i]
        if h.kind == stInstr and h.ik in owned and h.aKey in keys: inc before
      c.headerAt = s.headerAt - before
      result.add c
    of stSwitch:
      var c = Stmt(line: s.line, kind: stSwitch)
      c[] = s[]
      c.cases = @[]
      for body in s.cases: c.cases.add rcStripped(body, keys)
      result.add c
    of stTry:
      var c = Stmt(line: s.line, kind: stTry)
      c[] = s[]
      c.tryBody = rcStripped(s.tryBody, keys)
      c.handlers = @[]
      for h in s.handlers: c.handlers.add rcStripped(h, keys)
      result.add c
    of stLabel: result.add s

proc rcDischarge(stmts: var seq[Stmt], line: int, thenNonZero: bool,
                 held: seq[tuple[key, disp: string]]): bool =
  ## In a release function, the branch on which other shares remain keeps the object: what the
  ## function is declared to free is not freed there, and is not a leak either.
  for s in stmts:
    case s.kind
    of stIf:
      if s.line == line:
        var moves: seq[Stmt]
        for h in held: moves.add emit(ikMove, line, a = h.disp, aKey = h.key)
        if thenNonZero: s.thenBody = moves & s.thenBody
        else: s.elseBody = moves & s.elseBody
        return true
      if rcDischarge(s.thenBody, line, thenNonZero, held): return true
      if rcDischarge(s.elseBody, line, thenNonZero, held): return true
    of stLoop:
      if rcDischarge(s.loopBody, line, thenNonZero, held): return true
    else: discard

proc rcLower(ctx: var Ctx, fnCur, body: CXCursor, fn: var Func) =
  ## Fill in the reference-count view of one function, before its body is lowered for the
  ## ownership view, and say which of its pointers that view is to leave alone.
  ctx.rcKeep = initHashSet[string]()
  ctx.rcStrip = initHashSet[string]()
  ctx.rcZeroIfs = @[]
  if ctx.prog.counted.len == 0: return
  var rc = RcFn()
  for p in collectChildren(fnCur):
    if clang_getCursorKind(p) == ckParmDecl: ctx.rcCollectVars(rc, p)
  ctx.rcCollectVars(rc, body)
  let name = spelling(fnCur)
  let cls = (if clang_getCursorKind(fnCur) in [ckCXXMethod, ckConstructor, ckDestructor]:
               spelling(clang_getCursorSemanticParent(fnCur)) else: "")
  if cls in ctx.prog.counted:
    rc.vars["this"] = cls
    fn.countParams.add ("this", "this", false)
  for tn, d in ctx.prog.counted:
    let role = (if name == d.retain: 1 elif name == d.release: 2 elif name == d.destroy: 3 else: 0)
    if role == 0: continue
    if cls == tn:
      rc.role = role
      rc.subject = "this"
      rc.countField = d.count
      fn.countRole = role
      fn.countSubject = ("this", "this")
      break
    for p in collectChildren(fnCur):
      if clang_getCursorKind(p) == ckParmDecl and rc.vars.getOrDefault(usr(p), "") == tn:
        rc.role = role
        rc.subject = usr(p)
        rc.countField = d.count
        fn.countRole = role
        fn.countSubject = (usr(p), spelling(p))
        break
    if rc.role == 0:
      # declared for this type, but without a parameter of it: the pass reports it
      fn.countRole = role
  for key in [name, qualName(fnCur)]:
    if key.len > 0 and ctx.returnContracts.hasKey(key) and ctx.returnContracts[key].kind == rcOwned:
      rc.fnOwns = true
  for sig in ctx.funcSigs:
    if sig.hasBody: rc.bodies.incl sig.name
  var events: seq[Stmt]
  var pos = 0
  for p in collectChildren(fnCur):
    if clang_getCursorKind(p) != ckParmDecl: continue
    if usr(p) in rc.vars:
      fn.countParams.add (usr(p), spelling(p), ctx.rcCalleeTakes(name, pos) == 2)
    for (idx, acc) in ctx.ownsOut.getOrDefault(name, @[]):
      if idx == pos: events.add rc.rcEmit(rcFreshBase, startLine(fnCur), a = spelling(p))
    inc pos
  rc.any = false
  for ch in collectChildren(body): ctx.rcStmt(rc, ch, events)
  if not rc.any and fn.countRole == 0 and fn.countParams.len == 0: return
  fn.countBody = events
  fn.countScoped = rc.scoped
  fn.countTypes = rc.types
  for key, tn in rc.vars: fn.countTypes[key] = tn
  # the ownership view keeps the pointers it can describe: the object a constructor
  # allocates, and the parameter a release function or a destroy helper frees
  for key, tn in rc.vars:
    discard tn
    if key in rc.rawVars or (rc.role in [2, 3] and key == rc.subject): ctx.rcKeep.incl key
    else: ctx.rcStrip.incl key
  for key in rc.slotKeys: ctx.rcStrip.incl key
  if rc.role == 2: ctx.rcZeroIfs = rc.zeroIfs

proc rcFinish(ctx: Ctx, fn: var Func) =
  ## After lowering: take the shares out of the ownership view.
  if ctx.rcStrip.len > 0: fn.body = rcStripped(fn.body, ctx.rcStrip)
  for z in ctx.rcZeroIfs:
    discard rcDischarge(fn.body, z.line, z.thenNonZero, fn.freesParams)

proc rcSkipsArgument(ctx: Ctx, arg: CXCursor): bool =
  ## A call argument that is a share of a counted object: the ownership view has nothing to
  ## say about it (the reference-count view accounts for it).
  if ctx.prog.counted.len == 0 or ctx.rcCountedExpr(arg).len == 0: return false
  let u = refStrip(arg)
  not (clang_getCursorKind(u) == ckDeclRefExpr and referencedUsr(u) in ctx.rcKeep)
