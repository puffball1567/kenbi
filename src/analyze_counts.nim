## REFERENCE COUNTING — the checking half. Included by analyze.nim.
##
## For a type declared `@refcounted`, every holder of a pointer owns one SHARE of the object.
## This pass follows, along every path of a function, how many shares the function itself
## holds of each object it handles, and what the stored pointers it touches hold:
##
##   * a share is taken by the retain function, by receiving the result of an `@owns`
##     function, or by arriving in a parameter declared to take one over;
##   * it is given up by the release function, by storing the pointer (the location then
##     holds the share), by handing it to a parameter that takes it over, or by returning it
##     from an `@owns` function;
##   * at every exit the function holds none, it never gives up one it does not hold, and it
##     uses an object only while something is known to keep it alive: a share of its own, the
##     caller's (a borrowed parameter), or — for a pointer read from storage — the fact that
##     nothing that could release it has run since.
##
## The retain and release functions themselves are checked against the declaration: one
## increment, one decrement, and the object freed exactly where the count is found to be zero.
##
## The paths are followed as separate states, so a pointer that is null on one path and holds
## a share on another is not confused; whatever a function does that the pass cannot follow is
## reported, never assumed harmless.

const
  rcMaxShares = 6      ## more shares of one object than this in one function are not followed
  rcMaxStates = 192    ## ... nor more distinct states at one point
  rcSlotEmpty = 1      ## a stored pointer known to be null
  rcSlotDangling = 2   ## ... released and not yet cleared or assigned
  rcSlotHolds = 3      ## ... assigned here: it holds a pointer with its share, or null

type
  RcObj = object
    n: int             ## shares this function holds
    borrowed: bool     ## a parameter: the caller's share keeps it alive throughout
    live: bool         ## no share held, but nothing that could release it has run since
    raw: bool          ## allocated here, counter not set yet
    mine: bool         ## allocated here
    gave: bool         ## a share has left this function
    dead: bool         ## deallocated here
    nn: bool           ## known non-null
    disp: string
    line: int
    why: string        ## why it may be gone, for messages
    outOf: string      ## the function that wrote it through an out-parameter, if one did

  RcSt = ref object
    objs: Table[string, RcObj]
    vars: Table[string, string]      ## variable -> object ("" = null); absent = unknown
    slots: Table[string, int]        ## stored pointer -> rcSlot*; absent = the default
    slotLine: Table[string, int]
    slotObj: Table[string, string]
    fresh: HashSet[string]           ## variables whose storage holds no counted pointer yet
    dang: Table[string, int]         ## variable -> line: an element reached through it was
                                     ## released and can no longer be named
    pendKey: string                  ## a stored pointer was copied to another without a share:
    pendLine: int                    ## accepted if this one is set to NULL next (a move)
    pendMsg: string
    delta: int                       ## retain / release function: change of the counter so far
    zero: int                        ## release function: 1 count found zero, 2 found non-zero

  RcRun = object
    prog: Program
    fn: Func
    fallback: CountedDecl          ## the declaration named when an event does not say which
    decl: CountedDecl              ## the declaration of the pointer the current event is about
    diags: seq[Diag]
    seen: HashSet[string]
    breaks, conts: seq[seq[RcSt]]
    labels: Table[string, seq[RcSt]]

proc rcDiag(r: var RcRun, line: int, code, msg: string) =
  let k = $line & code & msg
  if k in r.seen: return
  r.seen.incl k
  r.diags.add Diag(line: line, code: code, msg: msg, sev: sevError)

proc rcCopy(st: RcSt): RcSt =
  new result
  result[] = st[]

proc rcCopies(sts: seq[RcSt]): seq[RcSt] =
  for st in sts: result.add rcCopy(st)

proc rcKey(st: RcSt): string =
  var parts: seq[string]
  for id, o in st.objs:
    parts.add "o" & id & "=" & $o.n & $int(o.borrowed) & $int(o.live) & $int(o.raw) &
              $int(o.mine) & $int(o.gave) & $int(o.dead) & $int(o.nn)
  for k, v in st.vars: parts.add "v" & k & "=" & v
  for k, v in st.slots: parts.add "s" & k & "=" & $v
  for k, v in st.slotObj: parts.add "b" & k & "=" & v
  for k in st.fresh: parts.add "f" & k
  for k, v in st.dang: parts.add "d" & k
  parts.sort()
  parts.join("\x00") & "\x00" & $st.delta & "," & $st.zero & "," & st.pendKey

proc rcDedupe(r: var RcRun, sts: seq[RcSt], line: int): seq[RcSt] =
  var seen = initHashSet[string]()
  for st in sts:
    let k = rcKey(st)
    if k in seen: continue
    seen.incl k
    if result.len >= rcMaxStates:
      r.rcDiag(line, "COUNT_UNPROVEN",
        "this function reaches more distinct reference-count states here than kenbi follows " &
        "(" & $rcMaxStates & "); the paths beyond that are not checked — split the function")
      break
    result.add st

proc rcSlotRoot(key: string): string =
  for t in key[rcSlotMark.len .. ^1].split(rcTokSep):
    if t.len > 0 and (t[0].isAlphaAscii or t[0] == '_'): return t

proc rcSlotState(st: RcSt, key: string): int =
  if key in st.slots: return st.slots[key]
  if rcSlotRoot(key) in st.fresh: rcSlotEmpty else: 0

proc rcIsSlot(key: string): bool = key.startsWith(rcSlotMark)

proc rcSlotObject(st: RcSt, key, disp: string, line: int): string =
  ## The object a stored pointer points to, as far as this function knows it.
  let id = st.slotObj.getOrDefault(key, "")
  if id.len > 0 and id in st.objs: return id
  let state = st.rcSlotState(key)
  if state == rcSlotEmpty: return ""
  result = "s:" & key
  if result notin st.objs:
    st.objs[result] = RcObj(disp: disp, line: line, live: state != rcSlotDangling,
      why: (if state == rcSlotDangling:
              "its share was released at line " & $st.slotLine.getOrDefault(key, 0) else: ""))
  st.slotObj[key] = result

proc rcResolve(st: RcSt, key, disp: string, line: int): string =
  if rcIsSlot(key): st.rcSlotObject(key, disp, line)
  else: st.vars.getOrDefault(key, "")

proc rcAlive(o: RcObj): bool =
  not o.dead and (o.borrowed or o.n > 0 or o.live or (o.raw and not o.gave))

proc rcGone(o: RcObj): string =
  if o.dead: "it was freed"
  elif o.why.len > 0: o.why
  else: "nothing is known to keep the object alive"

proc rcForget(st: RcSt, id: string) =
  ## The pointer turned out to be null: there is no object.
  st.objs.del id
  for k, v in st.vars.mpairs:
    if v == id: v = ""
  var gone: seq[string]
  for k, v in st.slotObj:
    if v == id: gone.add k
  for k in gone:
    st.slotObj.del k
    st.slots[k] = rcSlotEmpty

proc rcSettlePending(r: var RcRun, st: RcSt) =
  if st.pendKey.len == 0: return
  r.rcDiag(st.pendLine, "COUNT_NO_SHARE", st.pendMsg)
  st.pendKey = ""

proc rcHeldByVar(st: RcSt, key: string): string =
  ## The object the stored pointer `key` points to, if this function read it into a variable
  ## and nothing that could change the stored pointer has run since.
  let id = st.slotObj.getOrDefault(key, "")
  if id.len == 0 or id notin st.objs: return ""
  for k, v in st.vars:
    if v == id: return id
  ""

proc rcApply(r: var RcRun, st: RcSt, s: Stmt) =
  let fn = r.fn
  r.decl = r.fallback
  for key in [s.aKey, s.bKey]:
    let tn = fn.countTypes.getOrDefault(key, "")
    if tn.len > 0 and tn in r.prog.counted:
      r.decl = r.prog.counted[tn]
      break
  if st.pendKey.len > 0 and s.off notin [rcKill, rcFreshBase]:
    if s.off == rcStore and s.aKey == st.pendKey and s.bKey.len == 0:
      # `dst = src; src = NULL;` — the share moved with the pointer
      st.pendKey = ""
      st.slots[s.aKey] = rcSlotEmpty
      st.slotObj.del s.aKey
      return
    r.rcSettlePending(st)
  let isSubject = fn.countRole in [1, 2, 3] and s.aKey == fn.countSubject.key and s.aKey.len > 0
  case s.off
  of rcBind:
    case s.off2
    of 0:
      if s.bKey in st.vars: st.vars[s.aKey] = st.vars[s.bKey]
      else: st.vars.del s.aKey
    of 1, 2:
      let id = "e:" & s.aKey & ":" & $s.line
      if id in st.objs and st.objs[id].n > 0 and not st.objs[id].dead:
        r.rcDiag(st.objs[id].line, "COUNT_LEAK",
          "the share of '" & st.objs[id].disp & "' taken here is still held when the same " &
          "statement runs again and takes another: the first is never given back")
      st.objs[id] = RcObj(n: (if s.off2 == 1: 1 else: 0), raw: s.off2 == 2, mine: s.off2 == 2,
                          disp: s.a, line: s.line, outOf: s.b)
      st.vars[s.aKey] = id
    of 3:
      if s.bKey.len > 0:
        st.vars[s.aKey] = st.rcSlotObject(s.bKey, s.b, s.line)
      else:
        let id = "u:" & s.aKey & ":" & $s.line
        st.objs[id] = RcObj(live: true, disp: s.a, line: s.line)
        st.vars[s.aKey] = id
    else: st.vars[s.aKey] = ""
  of rcAcquire:
    let id = st.rcResolve(s.aKey, s.a, s.line)
    if id.len == 0 or id notin st.objs: return
    var o = st.objs[id]
    if o.raw:
      r.rcDiag(s.line, "COUNT_UNPROVEN",
        "'" & s.a & "' is retained before its counter is set: a new object starts with the " &
        "count its creator assigns (`" & s.a & "->" & r.decl.count & " = 1`)")
    elif not rcAlive(o):
      r.rcDiag(s.line, "COUNT_USE_AFTER_RELEASE",
        "'" & s.a & "' is retained here, but this function holds no share of it and " &
        rcGone(o) & ": the object may already be gone. Take the share while something still " &
        "keeps it alive.")
    if o.n >= rcMaxShares:
      r.rcDiag(s.line, "COUNT_UNPROVEN",
        "this function holds more shares of '" & s.a & "' than kenbi follows (" &
        $rcMaxShares & ")")
    else: inc o.n
    st.objs[id] = o
  of rcRelease:
    if s.off2 == 0 and rcIsSlot(s.aKey):
      let id = st.slotObj.getOrDefault(s.aKey, "")
      if id.len > 0 and id in st.objs and st.objs[id].n > 0:
        # a share of this function's own, given back through the stored name
        dec st.objs[id].n
        if st.objs[id].n == 0: st.objs[id].live = true
        return
      case st.rcSlotState(s.aKey)
      of rcSlotEmpty: discard                # null: nothing to release
      of rcSlotDangling:
        r.rcDiag(s.line, "COUNT_OVER_RELEASE",
          "'" & s.a & "' is released again: the share it held was already released at line " &
          $st.slotLine.getOrDefault(s.aKey, 0) & ", and it has not been assigned since")
      else:
        st.slots[s.aKey] = rcSlotDangling
        st.slotLine[s.aKey] = s.line
        if id.len > 0 and id in st.objs:
          st.objs[id].live = false
          st.objs[id].why = "the share '" & s.a & "' held was released at line " & $s.line
      return
    let id = st.rcResolve(s.aKey, s.a, s.line)
    if id.len == 0 or id notin st.objs: return
    var o = st.objs[id]
    if o.dead:
      r.rcDiag(s.line, "COUNT_USE_AFTER_RELEASE", "'" & s.a & "' is used here after it was freed")
    elif o.n > 0:
      dec o.n
      if s.off2 != 0: o.gave = true
      if o.n == 0 and not o.borrowed:
        o.live = false
        o.why = (if s.off2 == 0: "its last share here was released at line " & $s.line
                 elif s.off2 == 1: "its share was handed to '" & s.b & "' at line " & $s.line
                 else: "its share was returned")
    else:
      case s.off2
      of 0:
        if o.borrowed:
          r.rcDiag(s.line, "COUNT_OVER_RELEASE",
            "'" & s.a & "' is released, but this function holds no share of it: the pointer " &
            "is borrowed from the caller, and this would give back the caller's share. Take " &
            "one with '" & r.decl.retain & "' first, or declare `@frees(" & s.a & ")` if the " &
            "function is meant to take over the caller's.")
        else:
          r.rcDiag(s.line, "COUNT_OVER_RELEASE",
            "'" & s.a & "' is released, but this function holds no share of it here" &
            (if o.why.len > 0: " (" & o.why & ")" else: "") &
            ": this gives back a share that belongs to another holder")
      of 1:
        r.rcDiag(s.line, "COUNT_NO_SHARE",
          "'" & s.a & "' is handed to '" & s.b & "', which takes over a share, but this " &
          "function holds none to give" & (if o.raw: " (its counter is not set yet)" else: "") &
          ": take one with '" & r.decl.retain & "' first")
      else:
        r.rcDiag(s.line, "COUNT_NO_SHARE",
          "'" & s.a & "' is returned from a function declared `@owns`, so the caller receives " &
          "a share — but this function holds none to give" &
          (if o.raw: " (its counter is not set yet)" else: "") &
          ": take one with '" & r.decl.retain & "' first")
    st.objs[id] = o
  of rcUse:
    let id = st.rcResolve(s.aKey, s.a, s.line)
    if id.len == 0 or id notin st.objs: return
    let o = st.objs[id]
    if fn.countRole == 2 and isSubject and st.delta < 0 and st.zero != 1 and not o.dead:
      r.rcDiag(s.line, "COUNT_USE_AFTER_RELEASE",
        "'" & s.a & "' is " & s.b & " after its count was decremented: unless that was the " &
        "last share, another holder may free the object at any moment")
    elif s.off2 == 1 and rcAlive(o) and not (o.borrowed or o.n > 0 or (o.raw and not o.gave)):
      r.rcDiag(s.line, "COUNT_USE_AFTER_RELEASE",
        "'" & s.a & "' is " & s.b & " while this function holds no share of it: the object " &
        "is kept alive only by a pointer stored elsewhere, which the callee may release " &
        "while it is still using the object. Take a share with '" & r.decl.retain &
        "' for the duration of the call.")
    elif not rcAlive(o):
      r.rcDiag(s.line, "COUNT_USE_AFTER_RELEASE",
        "'" & s.a & "' is " & s.b & " here, but this function holds no share of it and " &
        rcGone(o) & ": the object may already be gone. Use it before giving the share up, " &
        "or take a share with '" & r.decl.retain & "' while it is still known to be alive.")
  of rcStore:
    let state = st.rcSlotState(s.aKey)
    let mayHold = state in [0, rcSlotHolds]
    let taken = (if mayHold: st.rcHeldByVar(s.aKey) else: "")
    if taken.len > 0:
      # the pointer was read into a variable before being replaced: that variable now holds
      # the share the location gives up
      if st.objs[taken].n < rcMaxShares: inc st.objs[taken].n
    if s.bKey.len == 0:
      if mayHold and taken.len == 0:
        r.rcDiag(s.line, "COUNT_SLOT_OVERWRITTEN",
          "'" & s.a & "' is set to NULL while it may still hold a pointer with its share: " &
          "that share is never given back. Release it first.")
      st.slots[s.aKey] = rcSlotEmpty
      st.slotObj.del s.aKey
      return
    if mayHold and taken.len == 0:
      r.rcDiag(s.line, "COUNT_SLOT_OVERWRITTEN",
        "'" & s.a & "' is assigned while it may still hold a pointer with its share: that " &
        "share is never given back. Release the old one first, or assign only where '" & s.a &
        "' is known to be NULL.")
    let id = st.rcResolve(s.bKey, s.b, s.line)
    if id.len == 0 or id notin st.objs:
      if not rcIsSlot(s.bKey) and s.bKey in st.vars:
        st.slots[s.aKey] = rcSlotEmpty      # a null pointer is stored
        st.slotObj.del s.aKey
      else: st.slots[s.aKey] = rcSlotHolds
      return
    var o = st.objs[id]
    if o.n > 0:
      dec o.n
      o.gave = true
      if o.n == 0: o.live = true            # the location keeps it, until something runs
    else:
      let msg = "'" & s.b & "' is stored into '" & s.a & "', which then holds it — but no " &
        "share is given with it" & (if o.raw: " (its counter is not set yet)" else: "") &
        ", so nothing keeps the object alive for that holder. Take one with '" &
        r.decl.retain & "' first."
      if rcIsSlot(s.bKey) and st.rcSlotState(s.bKey) in [0, rcSlotHolds]:
        st.pendKey = s.bKey         # unless the source is cleared next: then it is a move
        st.pendLine = s.line
        st.pendMsg = msg
      else: r.rcDiag(s.line, "COUNT_NO_SHARE", msg)
    st.objs[id] = o
    st.slots[s.aKey] = rcSlotHolds
    st.slotObj[s.aKey] = id
  of rcCall:
    var gone: seq[string]
    for key, state in st.slots:
      if state != rcSlotDangling: continue
      if s.a.len > 0 and rcSlotRoot(key) == s.a: gone.add key
      else:
        r.rcDiag(s.line, "COUNT_SLOT_DANGLING",
          "'" & key[rcSlotMark.len .. ^1].replace(rcTokSep, "") & "' still holds the pointer " &
          "whose share was released at line " & $st.slotLine.getOrDefault(key, 0) & " while '" &
          s.b & "' is called: anything that reads it there uses a released object. Set it to " &
          "NULL or assign it right after the release.")
    for key in gone: st.slots.del key
    if s.a.len > 0: st.dang.del s.a
    for root, line in st.dang:
      r.rcDiag(s.line, "COUNT_SLOT_DANGLING",
        "'" & root & "' still holds a pointer whose share was released at line " & $line &
        " while '" & s.b & "' is called")
    let mentioned = s.cKey.split(rcTokSep)
    for n in mentioned: st.fresh.excl n
    gone = @[]
    for key, state in st.slots:
      if state == rcSlotHolds and rcSlotRoot(key) in mentioned: gone.add key
    for key in gone: st.slots.del key
    gone = @[]
    for key, state in st.slots:
      if state == rcSlotEmpty and rcSlotRoot(key) notin st.fresh: gone.add key
    for key in gone: st.slots.del key
    gone = @[]
    for key, id in st.slotObj:
      if rcSlotRoot(key) notin st.fresh: gone.add key
    for key in gone: st.slotObj.del key
    for id, o in st.objs.mpairs:
      if not o.borrowed and o.n == 0 and o.live:
        o.live = false
        o.why = "'" & s.b & "', called at line " & $s.line & ", may have released it"
  of rcStep:
    if fn.countRole in [1, 2] and isSubject:
      st.delta += s.off2
      return
    r.rcDiag(s.line, "COUNT_DIRECT_WRITE",
      "the counter of '" & s.a & "' is changed here, outside the retain and release " &
      "functions of its type ('" & r.decl.retain & "', '" & r.decl.release & "'): shares are " &
      "taken and given back only through them")
  of rcSet:
    let id = st.vars.getOrDefault(s.aKey, "")
    if id.len > 0 and id in st.objs and st.objs[id].raw and not isSubject:
      if s.off2 < 0:
        r.rcDiag(s.line, "COUNT_UNPROVEN",
          "the counter of the new object '" & s.a & "' is set to a value that is not a " &
          "constant: kenbi cannot tell how many shares it starts with")
      else: st.objs[id].n = min(s.off2, rcMaxShares)
      st.objs[id].raw = false
      return
    r.rcDiag(s.line, "COUNT_DIRECT_WRITE",
      "the counter of '" & s.a & "' is assigned here: only the function that allocates an " &
      "object sets its first count, and after that it changes only through '" &
      r.decl.retain & "' and '" & r.decl.release & "'")
  of rcDealloc:
    let id = st.vars.getOrDefault(s.aKey, "")
    if id.len == 0 or id notin st.objs: return
    var o = st.objs[id]
    if o.dead:
      r.rcDiag(s.line, "COUNT_DIRECT_FREE", "'" & s.a & "' is freed here a second time")
    elif fn.countRole == 3 and isSubject: discard
    elif fn.countRole == 2 and isSubject:
      if st.zero != 1:
        r.rcDiag(s.line, "COUNT_RELEASE_MISMATCH",
          "'" & s.a & "' is freed on a path where its count was not found to be zero: " &
          "another holder may still have a share. Free it only in the branch where the " &
          "decremented count is zero.")
    elif not (o.mine and not o.gave):
      r.rcDiag(s.line, "COUNT_DIRECT_FREE",
        "'" & s.a & "' is deallocated with '" & s.b & "', but other holders may have shares " &
        "of it: give up this function's share with '" & r.decl.release & "' instead, which " &
        "frees the object when the last share is gone")
    o.dead = true
    o.n = 0
    st.objs[id] = o
  of rcUnmodeled:
    r.rcDiag(s.line, "COUNT_UNPROVEN", s.a)
  of rcUnproven:
    r.rcDiag(s.line, "COUNT_UNPROVEN",
      "'" & s.a & "' is passed to '" & s.b & "', which has no body in this translation unit " &
      "and no contract for that parameter: declare `@borrows(p)` on it if it only uses the " &
      "object during the call, or `@moves(p)` if it takes over a share")
  of rcKill:
    st.fresh.excl s.a
    var gone: seq[string]
    for key, state in st.slots:
      if s.a notin key[rcSlotMark.len .. ^1].split(rcTokSep): continue
      gone.add key
      if state == rcSlotDangling:
        let root = rcSlotRoot(key)
        if root == s.a:
          r.rcDiag(s.line, "COUNT_SLOT_DANGLING",
            "'" & key[rcSlotMark.len .. ^1].replace(rcTokSep, "") & "' still holds the " &
            "pointer whose share was released at line " & $st.slotLine.getOrDefault(key, 0) &
            " when '" & s.a & "' is assigned: it can no longer be cleared through that name")
        else: st.dang[root] = st.slotLine.getOrDefault(key, s.line)
    for key in gone: st.slots.del key
    gone = @[]
    for key, id in st.slotObj:
      if s.a in key[rcSlotMark.len .. ^1].split(rcTokSep): gone.add key
    for key in gone: st.slotObj.del key
  of rcMovedOut:
    var gone: seq[string]
    for key, state in st.slots:
      if rcSlotRoot(key) == s.a: gone.add key
    for key in gone: st.slots.del key
  of rcFreshBase:
    st.fresh.incl s.a
    var gone: seq[string]
    for key, state in st.slots:
      if rcSlotRoot(key) == s.a: gone.add key
    for key in gone: st.slots.del key
  else: discard

proc rcExit(r: var RcRun, st: RcSt, line: int) =
  let fn = r.fn
  let at = (if line > 0: " at line " & $line else: "")
  r.rcSettlePending(st)
  r.decl = r.fallback
  for id, o in st.objs:
    if o.dead or o.borrowed or o.n == 0: continue
    r.rcDiag(o.line, "COUNT_LEAK",
      "a share of '" & o.disp & "' is held from here and never given back on a path that " &
      "returns" & at & ": release it with '" & r.decl.release & "', store it, hand it to a " &
      "function that takes it over, or return it from a function declared `@owns`" &
      (if o.outOf.len > 0: ". ('" & o.outOf & "' writes it through an out-parameter: on a " &
         "path where it did not, the pointer is NULL — test the pointer itself, which is " &
         "what tells kenbi there is nothing to release.)" else: ""))
  for key, state in st.slots:
    if state == rcSlotHolds and rcSlotRoot(key) in fn.countScoped:
      let id = st.slotObj.getOrDefault(key, "")
      if id.len == 0 or id in st.objs:
        r.rcDiag(line, "COUNT_LEAK",
          "'" & key[rcSlotMark.len .. ^1].replace(rcTokSep, "") & "' holds a pointer with " &
          "its share when '" & rcSlotRoot(key) & "' goes out of scope" & at & ": that share " &
          "is never given back. Release it before the function returns.")
    if state != rcSlotDangling or rcSlotRoot(key) in fn.countScoped: continue
    r.rcDiag(st.slotLine.getOrDefault(key, line), "COUNT_SLOT_DANGLING",
      "'" & key[rcSlotMark.len .. ^1].replace(rcTokSep, "") & "' gives up its share here " &
      "and still holds the pointer when the function returns" & at & ": the next reader " &
      "uses a released object. Set it to NULL or assign it.")
  for root, ln in st.dang:
    if root in fn.countScoped: continue
    r.rcDiag(ln, "COUNT_SLOT_DANGLING",
      "a pointer reached through '" & root & "' gives up its share here and is still stored " &
      "when the function returns" & at & ": free '" & root & "', or clear its elements")
  if fn.countRole in [1, 2] and fn.countSubject.key.len > 0:
    let id = st.vars.getOrDefault(fn.countSubject.key, "")
    if id.len == 0 or id notin st.objs: return          # the pointer was null on this path
    let field = fn.countSubject.disp & "->" & r.decl.count
    if fn.countRole == 1:
      if st.delta != 1:
        r.rcDiag(fn.line, "COUNT_RETAIN_MISMATCH",
          "'" & fn.name & "' is declared the retain function of '" & r.decl.typeName &
          "', but on a path that returns" & at & " it changes '" & field & "' by " & $st.delta &
          ", not by +1: every call must take exactly one share")
    else:
      if st.delta != -1:
        r.rcDiag(fn.line, "COUNT_RELEASE_MISMATCH",
          "'" & fn.name & "' is declared the release function of '" & r.decl.typeName &
          "', but on a path that returns" & at & " it changes '" & field & "' by " & $st.delta &
          ", not by -1: every call must give back exactly one share")
      elif st.zero == 1 and not st.objs[id].dead:
        r.rcDiag(fn.line, "COUNT_RELEASE_MISMATCH",
          "'" & fn.name & "' returns" & at & " with '" & field & "' at zero and the object " &
          "not freed: the last share is gone, so nothing will ever free it")
      elif st.zero == 0:
        r.rcDiag(fn.line, "COUNT_RELEASE_MISMATCH",
          "'" & fn.name & "' decrements '" & field & "' but, on a path that returns" & at &
          ", never tests whether it reached zero: kenbi cannot see that the last release " &
          "frees the object. Test the decremented count in an `if` (`if (--" & field &
          " == 0) { … }`).")

proc rcNullSplit(st: RcSt, key: string, nonNull: bool): RcSt =
  ## `st` on the branch where the tested pointer is non-null (or null); nil if that branch
  ## cannot be taken from this state.
  result = rcCopy(st)
  if rcIsSlot(key):
    let state = st.rcSlotState(key)
    if nonNull:
      if state == rcSlotEmpty: return nil
    elif state in [0, rcSlotHolds]:
      let id = st.slotObj.getOrDefault(key, "")
      if id.len > 0 and id in result.objs: result.rcForget(id)
      result.slots[key] = rcSlotEmpty
      result.slotObj.del key
    return
  if key notin st.vars: return
  let id = st.vars[key]
  if id.len == 0 or id notin st.objs:
    return (if nonNull: nil else: result)
  if nonNull: result.objs[id].nn = true
  elif st.objs[id].nn: return nil
  else: result.rcForget(id)

proc rcRunBody(r: var RcRun, body: seq[Stmt], inp: seq[RcSt]): seq[RcSt] =
  var cur = inp
  for s in body:
    case s.kind
    of stInstr:
      case s.ik
      of ikCount:
        for st in cur: r.rcApply(st, s)
        if cur.len > 1: cur = r.rcDedupe(cur, s.line)
      of ikReturn:
        for st in cur: r.rcExit(st, s.line)
        cur = @[]
      of ikBreak:
        if r.breaks.len > 0: r.breaks[^1].add cur
        cur = @[]
      of ikContinue:
        if r.conts.len > 0: r.conts[^1].add cur
        cur = @[]
      of ikGoto:
        r.labels.mgetOrPut(s.a, @[]).add cur
        cur = @[]
      else: discard
    of stLabel:
      cur.add r.labels.getOrDefault(s.labelName, @[])
      r.labels.del s.labelName
      cur = r.rcDedupe(cur, s.line)
    of stIf:
      var thenIn, elseIn: seq[RcSt]
      for st in cur:
        if s.condKey.len > 0:
          let t = rcNullSplit(st, s.condKey, s.condThenNonNull)
          let e = rcNullSplit(st, s.condKey, not s.condThenNonNull)
          if t != nil: thenIn.add t
          if e != nil: elseIn.add e
        else:
          let t = rcCopy(st)
          let e = rcCopy(st)
          if s.predKey == "rc:zero":
            t.zero = (if s.predThenNonZero: 2 else: 1)
            e.zero = (if s.predThenNonZero: 1 else: 2)
          thenIn.add t
          elseIn.add e
      let a = r.rcRunBody(s.thenBody, thenIn)
      let b = r.rcRunBody(s.elseBody, elseIn)
      cur = r.rcDedupe(a & b, s.line)
    of stLoop:
      let headerAt = min(s.headerAt, s.loopBody.len)
      let tailAt = max(headerAt, min(s.tailAt, s.loopBody.len))
      let condPart = s.loopBody[0 ..< headerAt]
      let bodyPart = s.loopBody[headerAt ..< tailAt]
      let tailPart = s.loopBody[tailAt .. ^1]
      var seenHead = initHashSet[string]()
      var work = r.rcDedupe(cur, s.line)
      var exits: seq[RcSt]
      var settled = false
      for iter in 0 ..< 24:
        var fresh: seq[RcSt]
        for st in work:
          let k = rcKey(st)
          if k notin seenHead:
            seenHead.incl k
            fresh.add st
        if fresh.len == 0:
          settled = true
          break
        let afterCond = r.rcRunBody(condPart, fresh)
        if not s.doWhile: exits.add rcCopies(afterCond)
        r.breaks.add @[]
        r.conts.add @[]
        let afterBody = r.rcRunBody(bodyPart, afterCond)
        let br = r.breaks.pop()
        let ct = r.conts.pop()
        exits.add br
        let afterTail = r.rcRunBody(tailPart, r.rcDedupe(afterBody & ct, s.line))
        if s.doWhile: exits.add rcCopies(afterTail)
        work = afterTail
      if not settled:
        r.rcDiag(s.line, "COUNT_UNPROVEN",
          "the reference-count state of this loop does not settle: each iteration changes " &
          "how many shares are held, so kenbi cannot follow them to the exit")
      cur = r.rcDedupe(exits, s.line)
    of stSwitch:
      r.breaks.add @[]
      var outs: seq[RcSt]
      for body in s.cases: outs.add r.rcRunBody(body, rcCopies(cur))
      let br = r.breaks.pop()
      if not s.hasDefault: outs.add cur
      cur = r.rcDedupe(outs & br, s.line)
    of stTry: discard
  cur

proc analyzeCounts(prog: Program, fn: Func): seq[Diag] =
  ## The reference-count findings of one function (see the top of this file).
  if fn.countBody.len == 0 and fn.countRole == 0: return
  var r = RcRun(prog: prog, fn: fn)
  # the declaration the messages name when an event does not say: the one this function has
  # a role in, else the type of the first counted pointer it handles
  for tn, d in prog.counted:
    if r.fallback.typeName.len == 0: r.fallback = d
  for p in fn.countParams:
    let tn = fn.countTypes.getOrDefault(p.key, "")
    if tn in prog.counted:
      r.fallback = prog.counted[tn]
      break
  if fn.countRole != 0:
    let tn = fn.countTypes.getOrDefault(fn.countSubject.key, "")
    if tn in prog.counted: r.fallback = prog.counted[tn]
    else:
      for tn, d in prog.counted:
        if fn.name in [d.retain, d.release, d.destroy]: r.fallback = d
  r.decl = r.fallback
  if fn.countRole != 0 and fn.countSubject.key.len == 0:
    r.rcDiag(fn.line, "COUNT_UNPROVEN",
      "'" & fn.name & "' is named in `@refcounted " & r.decl.typeName & " { … }` but has no " &
      "parameter of type '" & r.decl.typeName & " *' for it to act on")
    return r.diags
  var st = RcSt()
  for p in fn.countParams:
    let id = "p:" & p.key
    let subject = fn.countRole != 0 and p.key == fn.countSubject.key
    st.objs[id] = RcObj(n: (if p.takes and not subject: 1 else: 0),
                        borrowed: subject or not p.takes, disp: p.disp, line: fn.line)
    st.vars[p.key] = id
  let rest = r.rcRunBody(fn.countBody, @[st])
  for s in rest: r.rcExit(s, 0)
  r.diags
