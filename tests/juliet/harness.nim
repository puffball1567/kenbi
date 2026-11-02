## Juliet (NIST SARD) FP/FN harness for kenbi.
##
## kenbi is run on each Juliet C testcase and its error-severity findings are
## scored against the case's KNOWN structure, NOT by an exact manifest line:
##
##   * Juliet packs one `*_bad` function (the flaw) and several `good*` functions
##     (no flaw of this CWE's class) into one file.
##   * Different defect classes report at different points (double-free at the
##     SINK free, leak at the ALLOCATION, UAF at the use), so the manifest's flaw
##     line and kenbi's report line legitimately differ by several lines. We
##     therefore match at FUNCTION-RANGE granularity, not by line proximity.
##   * Scoring is CLASS-SPECIFIC: only findings whose code matches the CWE's class
##     count as TP/FP. Other-class errors (e.g. Juliet's documented "POTENTIAL
##     INCIDENTAL ... memory leak" inside a good function) are reported separately
##     as `incidental`, never silently folded into FP — that would inflate FP and
##     would be dishonest.
##
##   TP  = the `*_bad` function contains a matching-class error
##   FN  = the `*_bad` function contains NO matching-class error (a miss)
##   FP  = a `good*` function contains a matching-class error (a false alarm)
##   recall = TP / (TP + FN) ; FPrate = flagged good funcs / total good funcs
##
## Usage:
##   nim c -r tests/juliet/harness.nim <CWE-dir> [CLASS] [--limit=N] [--juliet=PATH]
## CLASS defaults from the CWE number. PATH defaults to $KENBI_JULIET or ../juliet.
## Run from the kenbi repo root (uses ./kenbi). Build ./kenbi first.

import std/[sequtils, os, osproc, json, strutils, tables, algorithm, sequtils, sets, re]

type
  FuncKind = enum fkBad, fkGood, fkOther
  FuncRange = object
    name: string
    kind: FuncKind
    startLine, endLine: int
  CweStats = object
    files, errored: int
    tp, fn, fp: int
    goodFuncs: int           ## total good functions seen (FP denominator)
    fpAny: int               ## good functions flagged by ANY error class (SARD-strict FP:
                             ## a good function should stay completely silent). Distinct from
                             ## `fp` (same-class only) — kenbi's safety-bias UAF-on-freed-pass
                             ## fires on Juliet-"good" funcs that pass a freed pointer to a
                             ## no-op sink: strict-C UB, but Juliet labels them clean.
    fpDefensible: int        ## any-class-flagged good funcs whose findings are ONLY
                             ## USE_AFTER_FREE / DANGLING_RETURN — by construction a use/return
                             ## of an already-freed pointer's value (UB per C11 6.2.4/7.22.3/J.2) —
                             ## or a delete of a derived object through a base without a virtual
                             ## destructor (UB per [expr.delete]). kenbi stricter than Juliet here,
                             ## not wrong.
    fpLeakAcked: int         ## any-class-flagged good funcs with a LEAK finding that JULIET
                             ## ITSELF documents in the function body — "POTENTIAL INCIDENTAL -
                             ## Possible memory leak here if data was not freed/deleted", or the
                             ## return_freed_ptr family's "This call to free() was removed…".
                             ## The corpus says the block is abandoned on purpose, so reporting
                             ## it is correct: a true positive of a class the testcase is not
                             ## filed under, NOT a false alarm.
    fpLeakReview: int        ## any-class-flagged good funcs with a LEAK finding the corpus does
                             ## NOT acknowledge — a residual analysis FP, or a leak Juliet simply
                             ## does not comment on. The bucket that is actually worth reviewing.
    fpOther: int             ## any-class-flagged good funcs flagged only by some other class.
    fnSilent: int            ## missed bad functions that produced NO error of any class —
                             ## ANYWHERE in their testcase. This is the only kind of miss that is
                             ## a false GREEN, the number soundness is judged on, and it is not
                             ## the same as `fn`.
    fnElsewhere: int         ## missed bad functions whose testcase IS flagged, at the place the
                             ## defect actually lives rather than in the labelled function: a
                             ## sibling translation unit (Juliet's `83` variant puts the whole
                             ## source+sink in a class implementation file and leaves the `a`
                             ## file's `bad()` declaring a stack object), or a line inside an
                             ## indented class member that this scorer's column-0 function-range
                             ## parser cannot attribute. The code does not pass review, so it is
                             ## not a false GREEN; it is not the labelled function either.
    fnOtherClass: int        ## missed bad functions that ARE flagged, under a different class:
                             ## the bug is caught and the code is RED, but the reason kenbi can
                             ## prove modularly is not the label Juliet files the testcase
                             ## under (a freed pointer passed to an uncontracted cross-file sink
                             ## is a USE_AFTER_FREE here — that the sink then frees it again is
                             ## a fact about a body this TU never sees). Reported separately
                             ## rather than folded into either side.
    fnOtherCodes: Table[string, int]   ## which other-class codes those were flagged by
    incidental: Table[string, int]     ## other-class error code -> count (anywhere)
    incidentalGood: Table[string, int] ## other-class error code -> count IN GOOD funcs
                                       ## (a cross-class false-alarm candidate — but
                                       ## Juliet documents many real incidental leaks)
    # --- annotation coverage (like test coverage; the legibility metric) -------
    funcsTotal: int           ## all function definitions seen
    funcsRelevant: int        ## resource-relevant funcs (pointer param / alloc / free)
    funcsAnnotated: int       ## funcs we injected >=1 contract annotation onto
    contractNotHonored: int   ## CONTRACT_NOT_HONORED findings (declared intent != impl)

const cweClass = {
  "CWE415": "DOUBLE_FREE",
  "CWE416": "USE_AFTER_FREE",
  "CWE401": "LEAK",
  "CWE562": "DANGLING_RETURN",
  "CWE761": "FREE_INTERIOR",
  "CWE590": "WRONG_DEALLOCATOR",
  "CWE476": "NULL_DEREF",
}.toTable

proc isSigStart(line: string): bool =
  ## A Juliet top-level function signature: starts at column 0 (no indent), is not
  ## a preprocessor / comment / brace line, and has a `(` introducing params. The
  ## generated Juliet style keeps every signature at col 0 and the matching close
  ## brace `}` alone at col 0, so this lexical rule is reliable for the corpus.
  if line.len == 0: return false
  let c = line[0]
  if c == ' ' or c == '\t' or c == '#' or c == '/' or c == '*' or c == '}' or c == '{':
    return false
  if not (c.isAlphaAscii or c == '_'): return false
  let paren = line.find('(')
  if paren < 0: return false
  # exclude control statements that could sit at col 0 in odd formatting
  let head = line[0 ..< paren].splitWhitespace()
  if head.len == 0: return false
  let last = head[^1]
  if last in ["if", "for", "while", "switch", "return", "else", "do"]: return false
  true

proc funcNameOf(line: string): string =
  ## The identifier immediately before the `(` in a signature line.
  let paren = line.find('(')
  var i = paren - 1
  while i >= 0 and line[i] == ' ': dec i
  var j = i
  while j >= 0 and (line[j].isAlphaNumeric or line[j] == '_'): dec j
  if j < i: line[j+1 .. i] else: ""

proc classify(name: string, sig = ""): FuncKind =
  ## C: `CWE..._bad` / `..._good*`. C++ (namespaced): plain `bad` / `goodG2B` / `good`; the
  ## class-based flow variants define `CWE..._bad::action(...)` — the qualifier carries the kind.
  # a class variant's `X_bad::action` DEFINITION (in its own `_bad.cpp`) is the sink half of
  # the class: the verdict lives in the driver's `bad()` that constructs the class — no
  # expectation of its own
  if sig.contains("_bad::action("): fkOther
  elif name == "bad" or name.endsWith("_bad") or name.endsWith("Bad") or sig.contains("_bad::"): fkBad
  elif name.contains("good") or name.endsWith("Good") or sig.contains("good"): fkGood
  else: fkOther

proc funcRanges(src: string): seq[FuncRange] =
  ## Extract top-level function ranges: a signature line at col 0, spanning to the
  ## next `}` alone at col 0. Robust for Juliet's generated formatting.
  let lines = src.splitLines()
  var i = 0
  while i < lines.len:
    if isSigStart(lines[i]):
      # A PROTOTYPE (`void f(char * data);`) is a declaration, not a definition — its sig line
      # ends with `;` and has no `{ … }` body. Skipping it matters twice: the injector must not
      # read an unrelated function's `free()` as this declaration's "body" (a mis-ranged prototype
      # spans to the next col-0 `}`, i.e. the following real function) and inject a bogus contract
      # onto it; and scoring must not attribute a finding to a zero-body declaration range.
      if lines[i].strip().endsWith(";"):
        inc i
        continue
      let name = funcNameOf(lines[i])
      var e = i + 1
      while e < lines.len and not (lines[e].len > 0 and lines[e][0] == '}'): inc e
      if name.len > 0:
        var kind = classify(name, lines[i])
        # a class-based variant (83 / 84): the CONSTRUCTOR allocates, the DESTRUCTOR is where the
        # (non-)release shows — the class is the unit, scored at its destructor; the constructor
        # range does not carry an expectation of its own.
        if lines[i].contains(name & "::" & name & "(") and src.contains(name & "::~" & name & "("):
          kind = fkOther
        result.add FuncRange(name: name, kind: kind,
                             startLine: i + 1, endLine: (if e < lines.len: e + 1 else: lines.len))
      i = e + 1
    else:
      inc i

let testcaseStemRe = re(r"(_\d\d)(a|b)$")
proc testcaseStem(path: string): string =
  ## The testcase a Juliet FILE belongs to. One testcase is often several files — `…_83a.cpp`
  ## plus the `…_83_bad.cpp` / `…_83_goodG2B.cpp` class implementations, or `…_63a.c` plus
  ## `…_63b.c` — and a defect can be reported in one of them while the label sits in another.
  var b = extractFilename(path)
  for ext in [".cpp", ".c"]:
    if b.endsWith(ext): b = b[0 ..< b.len - ext.len]; break
  for suf in ["_bad", "_goodG2B", "_goodB2G", "_good"]:
    if b.endsWith(suf): return b[0 ..< b.len - suf.len]
  var m: array[2, string]
  if b.find(testcaseStemRe, m) >= 0: return b[0 ..< b.len - 1]
  b

proc funcAt(ranges: seq[FuncRange], line: int): int =
  for idx, r in ranges:
    if line >= r.startLine and line <= r.endLine: return idx
  -1

proc pointerParams(sigLine: string): seq[string] =
  ## Pointer parameter names from a single-line signature `f(T * a, U * b)`.
  let op = sigLine.find('('); let cp = sigLine.rfind(')')
  if op < 0 or cp <= op: return
  for part in sigLine[op+1 ..< cp].split(','):
    if '*' notin part: continue
    var j = part.high
    while j >= 0 and part[j] in {' ', '\t', '[', ']'}: dec j     # `char * dataArray[]`
    var k = j
    while k >= 0 and (part[k].isAlphaNumeric or part[k] == '_'): dec k
    if k < j: result.add part[k+1 .. j]

const allocCalls = ["malloc", "calloc", "realloc", "strdup", "strndup", "wcsdup",
                    "aligned_alloc", "new "]

proc bodyText(lines: seq[string], r: FuncRange): string =
  lines[min(r.startLine, lines.len) .. min(r.endLine, lines.len) - 1].join("\n")

let classHeadRe = re(r"^\s*(?:class|struct)\s+([A-Za-z_]\w*)\b")

# `this->` is accepted in front of the owner name so a CONSTRUCTOR's member allocation
# (`this->name = new char[n]`) declares its resource like any other site. Without it the class's
# own allocation was the one thing in the file left undeclared, and the destructor had nothing
# to be checked against. Only `this->` — a bare `obj->field` would name someone else's object.
# The optional leading `<type> *` lets the DECLARATION form be seen too — `Base *obj = new Base;`
# and `char *p = malloc(n);`, not only the bare assignment Juliet's C templates use. Without it a
# C++ object created where it is declared got no `@mem` at all: UNKNOWN_RESOURCE on the `new`, and
# (before the resource-lookup was made flavour-aware) the nearest unrelated `@mem` lending its
# deallocator to the `delete`.
let declPrefix = r"(?:[A-Za-z_][A-Za-z0-9_:]*\s*[\*&]\s*|[A-Za-z_][A-Za-z0-9_:]*\s+\*\s*)?"
let allocSiteRe = re(r"^\s*" & declPrefix & r"(?:this\s*->\s*)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*.*\b(malloc|calloc|realloc|strdup|strndup|wcsdup|aligned_alloc)\s*\(")
let newSiteRe = re(r"^\s*" & declPrefix & r"(?:this\s*->\s*)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*new\b")   ## C++: `data = new T` / `T *o = new T`
let globalDeclRe = re(r"^(?:static\s+)?[A-Za-z_]\w*\s+\**\s*([A-Za-z_]\w*)\s*;\s*$")
let assignRe = re(r"\b([A-Za-z_]\w*)\s*=\s*(?:\([^)]*\)\s*)?\(?\s*(\*\s*[A-Za-z_]\w*|[A-Za-z_]\w*\s*(?:->|\.)\s*[A-Za-z_]\w*|[A-Za-z_]\w*\s*\[\s*\d+\s*\]|[A-Za-z_]\w*)\s*\)?\s*;")
let freeExprRe = re(r"\bfree\s*\(\s*(\*\s*[A-Za-z_]\w*|[A-Za-z_]\w*\s*(?:->|\.)\s*[A-Za-z_]\w*|[A-Za-z_]\w*\s*\[\s*\d+\s*\]|[A-Za-z_]\w*)\s*\)")
let deleteExprRe = re(r"\bdelete\s*(?:\[\s*\])?\s*(\*\s*[A-Za-z_]\w*|[A-Za-z_]\w*\s*(?:->|\.)\s*[A-Za-z_]\w*|[A-Za-z_]\w*\s*\[\s*\d+\s*\]|[A-Za-z_]\w*)\s*;")

proc allParamNames(sigLine: string): seq[string] =
  ## Every parameter name (not just pointers) — a struct-by-value param carries a field too.
  let op = sigLine.find('('); let cp = sigLine.rfind(')')
  if op < 0 or cp <= op: return
  for part in sigLine[op+1 ..< cp].split(','):
    var j = part.high
    while j >= 0 and part[j] in {' ', '\t', '*', '&', '[', ']'}: dec j
    var k = j
    while k >= 0 and (part[k].isAlphaNumeric or part[k] == '_'): dec k
    if k < j: result.add part[k+1 .. j]

proc noSpace(s: string): string =
  for c in s:
    if c != ' ' and c != '\t': result.add c

proc deriveFrees(params: seq[string], body: string, globals: HashSet[string], sig = ""): seq[string] =
  ## The `@frees(...)` contracts a reviewer would write for THIS function, derived from what its
  ## body frees, tracing the ubiquitous Juliet `local = <source>; free(local)` indirection so the
  ## indirect channels resolve: `free(*p)` -> `@frees(*p)`, `free(p.f)` -> `@frees(p.f)`, `free(g)`
  ## (g a file-scope global) -> `@frees(g)`, plain `free(p)` -> `@frees(p)`.
  var srcOf = initTable[string, string]()          ## local -> its assigned source expr (normalised)
  var am: array[2, string]
  var pos = 0
  while true:
    let i = body.find(assignRe, am, pos)
    if i < 0: break
    srcOf[am[0]] = noSpace(am[1]); pos = i + 1
  var tracing: HashSet[string]                       # guard against `a = b; b = a` assignment cycles
  proc classify(expr: string): string =
    let e = noSpace(expr)
    if e.startsWith("*"):
      let base = e[1 .. ^1]
      if base in params: return "*" & base
      if base in srcOf and srcOf[base] != base and base notin tracing:   # `*dataPtr` with `dataPtr = p`
        tracing.incl base
        let src = classify(srcOf[base])
        return (if src.len > 0 and not src.startsWith("*") and '.' notin src and '[' notin src: "*" & src else: "")
      return ""
    if '[' in e:                                   # `free(arr[2])` -> `@frees(arr[2])`
      let base = e[0 ..< e.find('[')]
      return (if base in params: e else: "")
    let sep = (if "->" in e: e.find("->") else: e.find('.'))
    if sep > 0:
      let base = e[0 ..< sep]
      let step = (if e[sep] == '-': 2 else: 1)
      let field = e[sep + step .. ^1]
      return (if base in params: base & "." & field else: "")
    if e in params: return e
    if e in globals: return e
    if e in srcOf and srcOf[e] != e and e notin tracing:   # trace through the local (acyclically)
      tracing.incl e
      return classify(srcOf[e])
    ""
  var fm: array[1, string]
  var seen: HashSet[string]
  for rx in [freeExprRe, deleteExprRe]:            # `free(x)` and C++ `delete x` / `delete[] x`
    pos = 0
    while true:
      let i = body.find(rx, fm, pos)
      if i < 0: break
      let c = classify(fm[0])
      # `data = malloc(...); free(data);` on a PARAMETER frees the value the body allocated
      # into it, not what came in — no `@frees(data)` (the body's own origin is what it frees)
      var base = c                                   # the bare identifier of the contract form
      if base.startsWith("*"): base = base[1 .. ^1]
      for sep in [".", "["]:
        let at = base.find(sep)
        if at > 0: base = base[0 ..< at]
      # ... unless the parameter is a REFERENCE (`char *&data`): then the caller's variable holds
      # the new allocation and its release — `@owns(data)` + `@frees(data)`, a dangling hand-out
      let isRef = sig.len > 0 and sig.find(re(r"&\s*" & base & r"\b")) >= 0
      if c.len > 0 and c notin seen and
         (c != base or isRef or
          body.find(re(r"\b" & base & r"\s*=\s*(?:\([^)]*\)\s*)?(malloc|calloc|realloc|strdup|strndup|wcsdup|new)\b")) < 0):
        seen.incl c; result.add c
      pos = i + 1

proc deriveOwnsOut(sig, body: string): seq[tuple[form: string, isNew: bool]] =
  ## The `@owns(...)` OUT-parameter contracts a reviewer would write: the body allocates INTO a
  ## parameter — `p = malloc(...)` on a C++ reference `T *&p` -> `@owns(p)`; `*p = malloc(...)`
  ## through a `T **p` -> `@owns(*p)`. `isNew` = the allocation is C++ `new` (freed by delete).
  var m: array[1, string]
  for p in allParamNames(sig):
    let isRef = sig.find(re(r"&\s*" & p & r"\b")) >= 0
    let byRef = re(r"\b" & p & r"\s*=\s*(?:\([^)]*\)\s*)?(malloc|calloc|realloc|strdup|strndup|wcsdup|new)\b")
    let byPtr = re(r"\*\s*" & p & r"\s*=\s*(?:\([^)]*\)\s*)?(malloc|calloc|realloc|strdup|strndup|wcsdup|new)\b")
    if isRef and body.find(byRef, m) >= 0: result.add ("" & p, m[0] == "new")
    elif body.find(byPtr, m) >= 0: result.add ("*" & p, m[0] == "new")

proc derivesOwnedReturn(body: string): tuple[owns: bool, isNew: bool] =
  ## `@owns` (return form): the body returns a fresh allocation — `return malloc(...)` directly,
  ## or `return v` where `v = malloc/…/new` was assigned in the body (the Juliet source shape
  ## `data = badSource(data)`, in-file (42) and cross-file (61)).
  var m: array[1, string]
  let direct = re(r"\breturn\s*\(?[^;]*\b(malloc|calloc|realloc|strdup|strndup|wcsdup|new)\b")
  if body.find(direct, m) >= 0: return (true, m[0] == "new")
  var rm: array[1, string]
  var pos = 0
  while true:
    let i = body.find(re(r"\breturn\s+([A-Za-z_]\w*)\s*;"), rm, pos)
    if i < 0: break
    let v = rm[0]
    if body.find(re(r"\b" & v & r"\s*=\s*(?:\([^)]*\)\s*)?(malloc|calloc|realloc|strdup|strndup|wcsdup|new)\b"), m) >= 0 and
       body.find(re(r"\b(?:free\s*\(\s*|delete\s*(?:\[\s*\])?\s*)" & v & r"\b")) < 0:
      # (a function that FREES the value it returns hands out a dangling pointer — no reviewer
      # writes `@owns` on it; kenbi reports the DANGLING_RETURN in that function itself)
      return (true, m[0] == "new")
    pos = i + 1
  (false, false)

proc deriveBorrows(ptrParams, freedContracts: seq[string], body: string): seq[string] =
  ## `@borrows(p)` for a pointer parameter the function only READS — the reader-sink contract that
  ## clears the good-source `UNCONTRACTED_ESCAPE` (a source handing an owned pointer to a callee that
  ## does not take ownership). Conservative to never inject a WRONG borrow (which would be a false
  ## BORROW_FREED): skip a param that is freed (it is a `@frees`, base compared), returned, or stored
  ## directly (`= p`). A param used only through a deref / passed by value stays a borrow.
  var freedBase: HashSet[string]
  for c in freedContracts:
    var b = c
    if b.startsWith("*"): b = b[1 .. ^1]
    let dot = b.find('.')
    if dot > 0: b = b[0 ..< dot]
    let lb = b.find('[')
    if lb > 0: b = b[0 ..< lb]
    freedBase.incl b
  # a sibling / header-derived body may start with the signature line (`f(char * data)`): the
  # `* data` there is the declarator, not a read through the pointer — skip it for that check
  let inner = (if body.find(re(r"^[^\n{]*\(")) == 0 and body.find('\n') >= 0: body[body.find('\n') + 1 .. ^1] else: body)
  for p in ptrParams:
    if p in freedBase: continue
    if body.find(re(r"\breturn\s+&?\s*" & p & r"\s*;")) >= 0: continue     # transferred out
    if body.find(re(r"=\s*" & p & r"\s*;")) >= 0: continue                  # stored / aliased WHOLE (a field / element read is fine)
    if inner.find(re(r"\*\s*" & p & r"\s*=[^=]")) >= 0: continue            # writes the pointee: an out-param (@owns(*p)), not a borrow
    # a read through an ALIAS of it (`dataPtr = (char **)p; x = *dataPtr;` — the void* channel)
    var viaAlias = false
    var am: array[1, string]
    var pos = 0
    while true:
      let i = inner.find(re(r"\b([A-Za-z_]\w*)\s*=\s*(?:\([^)]*\)\s*)?" & p & r"\s*;"), am, pos)
      if i < 0: break
      if inner.find(re(r"\*\s*" & am[0] & r"\b")) >= 0: viaAlias = true
      pos = i + 1
    if viaAlias or inner.find(re(r"\*\s*" & p & r"\b")) >= 0: result.add "*" & p   # reads THROUGH it: `@borrows(*p)`
    else: result.add p

proc deriveStructBorrows(sig: string, freedContracts: seq[string], body: string): seq[string] =
  ## `@borrows(s)` for a STRUCT parameter passed by value whose fields the body only READS
  ## (`printLine(s.f)`): the reader-sink contract for the struct channel (Juliet 66/67). Skipped
  ## when a field of it is freed (`@frees(s.f)`), returned, or stored.
  var freedBase: HashSet[string]
  for c in freedContracts:
    var b = c
    if b.startsWith("*"): b = b[1 .. ^1]
    let dot = b.find('.')
    if dot > 0: b = b[0 ..< dot]
    freedBase.incl b
  let op = sig.find('('); let cp = sig.rfind(')')
  if op < 0 or cp <= op: return
  for part in sig[op+1 ..< cp].split(','):
    if '*' in part or '&' in part: continue                  # pointers / references: deriveBorrows
    let names = allParamNames("(" & part & ")")
    if names.len != 1: continue
    let p = names[0]
    if p in freedBase: continue
    if body.find(re(r"\b" & p & r"\s*(?:\.|->)\s*\w+")) < 0: continue   # no field access: not a channel
    if body.find(re(r"\breturn\s+" & p & r"\b")) >= 0: continue
    if body.find(re(r"=\s*" & p & r"\s*;")) >= 0: continue        # whole-struct copy (a field READ is fine)
    result.add p

proc funcBodyByName(text, name: string): string =
  ## Extract `name`'s definition body from `text` (a sibling file): from its `name(...) {`
  ## to the next col-0 `}`. Empty if not defined there (a prototype only).
  let lines = text.splitLines()
  for i in 0 ..< lines.len:
    if isSigStart(lines[i]) and not lines[i].strip().endsWith(";") and funcNameOf(lines[i]) == name:
      var e = i + 1
      while e < lines.len and not (lines[e].len > 0 and lines[e][0] == '}'): inc e
      return lines[i .. min(e, lines.len - 1)].join("\n")
  ""

proc injectAnnotations(src: string, sibling: string, st: var CweStats): string =
  ## Behavior-accurate contract injection — the declared contracts a developer would
  ## write, derived from what the code DOES, applied IDENTICALLY to bad and good
  ## functions (no bug-marking). Two stages, together the realistic annotation a
  ## reviewer adds so kenbi can verify (default-red otherwise):
  ##   * @mem — for every `<var> = malloc/calloc/strdup/… (…)` allocation site, declare
  ##     the resource (owner = the LHS var, freed by `free`) right above it. Without this
  ##     every allocation in a covered file is UNKNOWN_RESOURCE (the dominant good-func
  ##     "any-class FP" — a not-declared refusal, not a detection error). With it a
  ##     good function that frees exactly once reads clean; a double free still fires.
  ##   * @frees(...) — for every function, the intake contract derived from what its body frees:
  ##     `@frees(p)` (direct), `@frees(*p)` (out-parameter `T**`), `@frees(p.f)` (struct field),
  ##     `@frees(g)` (file-scope global). For a cross-file `_NNa` source, the sink lives in the
  ##     sibling `_NNb` — read there, the contract is stamped on the sink's PROTOTYPE in `_NNa`, so
  ##     the boundary transfer is visible modularly (this is what recovers the previously-silent
  ##     indirect-channel bads). CONTRACT_NOT_HONORED if a declared @frees is not actually met.
  ## Also tallies annotation coverage.
  let lines = src.splitLines()
  let ranges = funcRanges(src)
  var insAt = initTable[int, seq[string]]()   ## line index -> lines to insert BEFORE it
  # file-scope globals (own file + sibling): a free of one is a global free effect (`@frees(g)`).
  var globals: HashSet[string]
  var gm: array[1, string]
  for l in (src & "\n" & sibling).splitLines():
    if l.len > 0 and l[0] notin {' ', '\t', '#', '/', '}', '*'} and
       l.find('(') < 0 and l.find(globalDeclRe, gm) >= 0:
      globals.incl gm[0]
  # The Juliet support library (io.c) only READS what it is handed: the reviewer annotates its
  # pointer-taking prototypes `@borrows` once. Re-declared right after the include (same
  # linkage as the header), so every `printLine(data)` is a use, not an UNCONTRACTED_ESCAPE
  # that would also mask the leak behind it.
  for i, l in lines:
    if l.contains("#include \"std_testcase.h\""):
      insAt.mgetOrPut(i + 1, @[]).add @[
        "#ifdef __cplusplus", "extern \"C\" {", "#endif",
        "// @borrows(line)", "void printLine(const char * line);",
        "// @borrows(line)", "void printWLine(const wchar_t * line);",
        "// @borrows(structTwoIntsStruct)", "void printStructLine(const twoIntsStruct * structTwoIntsStruct);",
        "// @borrows(bytes)", "void printBytesLine(const unsigned char * bytes, size_t numBytes);",
        "#ifdef __cplusplus", "}", "#endif"]
      break
  # A class whose CONSTRUCTOR allocates into a member owns that resource, and its destructor is
  # what must release it: declare the class `@raii` so kenbi verifies the promise. This is its
  # own scan because the per-function derivation below works from `funcRanges`, which — by the
  # corpus's own lexical rule — only sees signatures at column 0. A class written with its
  # members defined INLINE (every `_01` testcase) therefore had no ownership vocabulary at all,
  # and a destructor that abandons what the constructor allocated was silent.
  block classRaii:
    var i = 0
    while i < lines.len:
      var cm: array[1, string]
      if lines[i].find(classHeadRe, cm) < 0 or '(' in lines[i]: inc i; continue
      let cls = cm[0]
      # the class body: brace-count from the head line to its closing brace
      var depth = 0
      var started = false
      var last = i
      for j in i ..< lines.len:
        for ch in lines[j]:
          if ch == '{': inc depth; started = true
          elif ch == '}': dec depth
        last = j
        if started and depth <= 0: break
      if not started: inc i; continue
      let bodyLines = lines[i .. last]
      # a constructor defined inline: `<indent>Cls(` — and not the destructor `~Cls(`
      let ctorRe = re(r"^\s*" & cls & r"\s*\(")   # `Cls(` — the destructor is `~Cls(`
      # a member allocation inside a constructor's own braces
      var allocates = false
      var k = 0
      while k < bodyLines.len and not allocates:
        if bodyLines[k].find(ctorRe) >= 0:
          var d = 0
          var st2 = false
          for m in k ..< bodyLines.len:
            for ch in bodyLines[m]:
              if ch == '{': inc d; st2 = true
              elif ch == '}': dec d
            if st2 and bodyLines[m].find(
                 re(r"\b[A-Za-z_]\w*\s*=\s*(?:\([^)]*\)\s*)?(malloc|calloc|realloc|strdup|strndup|wcsdup|new)\b")) >= 0:
              allocates = true
            if st2 and d <= 0: break
        inc k
      if allocates: insAt.mgetOrPut(i, @[]).add "// @raii(" & cls & ")"
      i = last + 1

  var ownsFns = initTable[string, bool]()   ## `@owns(...)` source function -> allocates with `new`
  var ownsRetFns = initTable[string, bool]() ## `@owns` (return) source function -> allocates with `new`
  # own-file DEFINITIONS: derive @frees(...) from the body.
  for r in ranges:
    if r.name == "main": continue
    inc st.funcsTotal
    let sig = lines[r.startLine - 1]
    let body = bodyText(lines, r)
    let pps = pointerParams(sig)
    let allocs = allocCalls.anyIt(it in body)
    let frees = ("free(" in body) or ("delete " in body)
    if pps.len > 0 or allocs or frees: inc st.funcsRelevant
    var anns: seq[string]
    let frs = deriveFrees(allParamNames(sig), body, globals, sig)
    for c in frs: anns.add "// @frees(" & c & ")"
    let owns = deriveOwnsOut(sig, body)
    var ownForms: seq[string]
    for o in owns:
      anns.add "// @owns(" & o.form & ")"; ownForms.add o.form
      ownsFns[r.name] = o.isNew
    let ret = derivesOwnedReturn(body)
    if ret.owns and r.name != "main":
      anns.add "// @owns"; ownsRetFns[r.name] = ret.isNew
    # an OUT-OF-LINE constructor (`X::X(...)`) that allocates into a member: the class owns it —
    # declare the class `@raii` so the destructor is verified against the promise. The inline
    # form is handled by the class scan above, which does not go through `funcRanges`.
    if sig.contains(r.name & "::" & r.name & "(") and
       body.find(re(r"\b[A-Za-z_]\w*\s*=\s*(?:\([^)]*\)\s*)?(malloc|calloc|realloc|strdup|strndup|wcsdup|new)\b")) >= 0:
      anns.add "// @raii(" & r.name & ")"
    for p in deriveBorrows(pps, frs & ownForms, body): anns.add "// @borrows(" & p & ")"
    for p in deriveStructBorrows(sig, frs & ownForms, body): anns.add "// @borrows(" & p & ")"
    if anns.len > 0:
      insAt.mgetOrPut(r.startLine - 1, @[]).add anns
      inc st.funcsAnnotated
  # cross-file PROTOTYPES: the sink's definition is in the sibling `_NNb` — derive from there and
  # stamp the contract on the prototype line here, so single-file analysis sees the boundary transfer.
  if sibling.len > 0:
    for i, l in lines:
      if isSigStart(l) and l.strip().endsWith(";"):
        let name = funcNameOf(l)
        if name.len == 0: continue
        let sbody = funcBodyByName(sibling, name)
        if sbody.len == 0: continue
        var anns: seq[string]
        let frs = deriveFrees(allParamNames(l), sbody, globals, l)
        for c in frs: anns.add "// @frees(" & c & ")"
        let owns = deriveOwnsOut(l, sbody)
        var ownForms: seq[string]
        for o in owns:
          anns.add "// @owns(" & o.form & ")"; ownForms.add o.form
          ownsFns[name] = o.isNew
        let ret = derivesOwnedReturn(sbody)
        if ret.owns:
          anns.add "// @owns"; ownsRetFns[name] = ret.isNew
        for p in deriveBorrows(pointerParams(l), frs & ownForms, sbody): anns.add "// @borrows(" & p & ")"
        for p in deriveStructBorrows(l, frs & ownForms, sbody): anns.add "// @borrows(" & p & ")"
        if anns.len > 0: insAt.mgetOrPut(i, @[]).add anns
  # `@calls(X)` on a function-pointer local initialised with a function name (`void (*funcPtr)
  # (char *) = badSink;`, Juliet 44 / 65): the declared target set an indirect call resolves through.
  let fnptrInitRe = re(r"^\s*[A-Za-z_][\w\s\*]*\(\s*\*\s*[A-Za-z_]\w*\s*\)\s*\([^)]*\)\s*=\s*([A-Za-z_]\w*)\s*;")
  var pm: array[1, string]
  for i, l in lines:
    if l.find(fnptrInitRe, pm) >= 0:
      insAt.mgetOrPut(i, @[]).add "// @calls(" & pm[0] & ")"
  # @mem at every callsite of an `@owns(...)` source: the caller declares the resource it
  # receives through the out-parameter (`source(&data)` / `source(data)` -> owner = data).
  var cm: array[1, string]
  for fnName, isNew in ownsFns:
    let callRe = re(r"\b" & fnName & r"\s*\(\s*&?\s*([A-Za-z_]\w*)\s*\)")
    for i, l in lines:
      if l.find(callRe, cm) >= 0 and not isSigStart(l):
        insAt.mgetOrPut(i, @[]).add "/* @mem j::c" & $i & " { free: " & (if isNew: "delete" else: "free") &
                                    ", owner: " & cm[0] & " } */"
  # @mem at every `x = source(...)` of an `@owns` (return) source: the caller declares the resource
  # it receives as the result (owner = x).
  var rm: array[1, string]
  for fnName, isNew in ownsRetFns:
    let asgRe = re(r"\b([A-Za-z_]\w*)\s*=\s*" & fnName & r"\s*\(")
    for i, l in lines:
      if l.find(asgRe, rm) >= 0 and not isSigStart(l):
        insAt.mgetOrPut(i, @[]).add "/* @mem j::r" & $i & " { free: " & (if isNew: "delete" else: "free") &
                                    ", owner: " & rm[0] & " } */"
  # @mem per allocation site (above the alloc line): owner = the LHS var, freed by free.
  var m: array[2, string]
  for i, l in lines:
    if l.find(allocSiteRe, m) >= 0:
      insAt.mgetOrPut(i, @[]).add "/* @mem j::m" & $i & " { free: free, owner: " & m[0] & " } */"
    elif l.find(newSiteRe, m) >= 0:
      insAt.mgetOrPut(i, @[]).add "/* @mem j::m" & $i & " { free: delete, owner: " & m[0] & " } */"
  result = ""
  for i, l in lines:
    if i in insAt:
      for a in insAt[i]: result.add a & "\n"
    result.add l & (if i < lines.high: "\n" else: "")

proc qualifiedBodyIn(text, cls, meth: string): string =
  ## `Class::meth(...) { ... }` definition body in `text` (a sibling .cpp): from its sig line to
  ## the next col-0 `}`. Empty if not defined there.
  let lines = text.splitLines()
  for i in 0 ..< lines.len:
    if lines[i].contains(cls & "::" & meth & "(") and not lines[i].strip().endsWith(";") and
       lines[i].len > 0 and lines[i][0] notin {' ', '\t'}:
      var e = i + 1
      while e < lines.len and not (lines[e].len > 0 and lines[e][0] == '}'): inc e
      return lines[i .. min(e, lines.len - 1)].join("\n")
  ""

proc annotateHeaders(srcPath, src, tmpDir: string) =
  ## The class-based Juliet variants (81 / 82: a virtual `action` dispatched through a base
  ## reference / pointer) declare the methods in a HEADER the driver includes, and define each
  ## class's `action` in its own sibling `.cpp` (`_81_bad.cpp`, `_81_goodG2B.cpp`, ...). The
  ## contract a reviewer writes lives on the declaration: derive it from the sibling definition
  ## (`@frees` / `@borrows` / `@owns`, by class) and write an annotated COPY of the header next to
  ## the annotated driver — a quoted `#include "X.h"` finds the copy first.
  let dir = parentDir(srcPath)
  var hm: array[1, string]
  for l in src.splitLines():
    if l.find(re("^\\s*#include\\s+\"([^\"]+\\.h)\""), hm) < 0: continue
    let hname = hm[0]
    if hname == "std_testcase.h" or not fileExists(dir / hname): continue
    let hlines = readFile(dir / hname).splitLines()
    var siblings: seq[string]
    let stem = hname[0 ..< hname.len - 2]                     # `X_81` of `X_81.h`
    for f in walkDirRec(dir):
      let base = extractFilename(f)
      if base.startsWith(stem & "_") and base.endsWith(".cpp") and f != srcPath: siblings.add readFile(f)
    var cls = ""
    var cm: array[1, string]
    var mm: array[2, string]
    var outLines: seq[string]
    for l in hlines:
      if l.find(re(r"^\s*class\s+([A-Za-z_]\w*)"), cm) >= 0: cls = cm[0]
      elif l.find(re(r"^\s*};")) >= 0: cls = ""
      elif cls.len > 0 and l.find(re(r"^\s*(?:virtual\s+)?[A-Za-z_][\w\s\*&:<>]*?\b([A-Za-z_]\w*)\s*\(([^)]*)\)[^;]*;"), mm) >= 0 and
           mm[0] != cls and not mm[0].startsWith("~"):
        let meth = mm[0]
        let sig = "(" & mm[1] & ")"
        var body = ""
        for sb in siblings:
          body = qualifiedBodyIn(sb, cls, meth)
          if body.len > 0: break
        if body.len > 0:
          var anns: seq[string]
          let frs = deriveFrees(allParamNames(sig), body, initHashSet[string](), sig)
          for c in frs: anns.add "// @frees(" & c & ")"
          let owns = deriveOwnsOut(sig, body)
          var ownForms: seq[string]
          for o in owns: anns.add "// @owns(" & o.form & ")"; ownForms.add o.form
          if derivesOwnedReturn(body).owns: anns.add "// @owns"
          for p in deriveBorrows(pointerParams(sig), frs & ownForms, body): anns.add "// @borrows(" & p & ")"
          for p in deriveStructBorrows(sig, frs & ownForms, body): anns.add "// @borrows(" & p & ")"
          for a in anns: outLines.add a
      outLines.add l
    writeFile(tmpDir / hname, outLines.join("\n"))

proc runKenbi(file, support, incDir: string): seq[JsonNode] =
  ## Run kenbi --format=json on one file; return its findings array (empty on
  ## parse trouble — the caller treats a PARSE_ERROR / empty as errored). `incDir` = the
  ## testcase's own directory (an annotated copy lives in tmp/, its `#include "..._81.h"`
  ## must still resolve). C++ is analysed with -fno-exceptions: Juliet's C-style C++ is not an
  ## exception-safety corpus, and the CWE under measurement is the memory class, not
  ## LEAK_ON_THROW.
  let extra = (if file.endsWith(".cpp"): " -fno-exceptions" else: "")
  let (outp, _) = execCmdEx("./kenbi --format=json " & quoteShell(file) &
                            " -- -I " & quoteShell(support) & " -I " & quoteShell(incDir) & extra)
  try:
    let j = parseJson(outp)
    if j.hasKey("findings"):
      for f in j["findings"]: result.add f
  except CatchableError:
    discard

proc main() =
  var cweDir, classOverride, julietRoot = ""
  var limit = high(int)
  var annotate = false
  var lang = "c"           # c (the default) | cpp | all
  var fnList = false       # --fn-list: print every missed bad function (FN) and flagged good (FP)
  julietRoot = getEnv("KENBI_JULIET", "../juliet")
  for i in 1 .. paramCount():
    let a = paramStr(i)
    if a.startsWith("--limit="): limit = parseInt(a[8 .. ^1])
    elif a.startsWith("--juliet="): julietRoot = a[9 .. ^1]
    elif a == "--annotate": annotate = true
    elif a.startsWith("--lang="): lang = a[7 .. ^1]
    elif a == "--fn-list": fnList = true
    elif cweDir.len == 0: cweDir = a
    elif classOverride.len == 0: classOverride = a
  if cweDir.len == 0:
    quit("usage: harness <CWE-dir> [CLASS] [--limit=N] [--juliet=PATH] [--annotate] [--lang=c|cpp|all]", 1)

  let cwePrefix = cweDir.split('_')[0]
  let cls = (if classOverride.len > 0: classOverride
             else: cweClass.getOrDefault(cwePrefix, ""))
  if cls.len == 0: quit("no class mapping for " & cwePrefix & " — pass CLASS explicitly", 1)
  # returning a freed pointer (DANGLING_RETURN) is the use-after-free class caught at the exit —
  # Juliet's `return_freed_ptr` variants — so 416 accepts it as its own class
  # The class a finding must belong to, widened to the codes that ARE that bug under another
  # name: 416 = the use-after-free caught at the exit (DANGLING_RETURN) or at an undeclared
  # callsite (POSSIBLE_USE_AFTER_FREE); 415 likewise (POSSIBLE_DOUBLE_FREE); 401 = the leak a
  # self-reassigning realloc causes on its failure path (REALLOC_SELF_REASSIGN says exactly
  # "if realloc fails the original block leaks irrecoverably" — Juliet's malloc_realloc bads).
  let clsSet = (if cls == "USE_AFTER_FREE": ["USE_AFTER_FREE", "DANGLING_RETURN", "POSSIBLE_USE_AFTER_FREE"].toHashSet
                elif cls == "DOUBLE_FREE": ["DOUBLE_FREE", "POSSIBLE_DOUBLE_FREE"].toHashSet
                elif cls == "LEAK": ["LEAK", "REALLOC_SELF_REASSIGN"].toHashSet
                else: [cls].toHashSet)
  let support = julietRoot / "testcasesupport"
  let dir = julietRoot / "testcases" / cweDir

  var files: seq[string]
  for f in walkDirRec(dir):
    if (f.endsWith(".c") and lang in ["c", "all"]) or (f.endsWith(".cpp") and lang in ["cpp", "all"]):
      files.add f
  files.sort()

  var st = CweStats(incidental: initTable[string, int](),
                    incidentalGood: initTable[string, int]())
  # A testcase can span several files, and the defect may be reported in a different one from the
  # one carrying the label (see `testcaseStem`). Record which testcases produced a matching-class
  # error somewhere OTHER than inside a good function, and resolve the silent misses against that
  # after every file has been scanned — the sibling may be scanned later than the label.
  var stemDefect: HashSet[string]
  var pendingSilent: seq[tuple[stem, file, fn: string]]
  let tmpDir = getCurrentDir() / "tmp" / "juliet_annot"
  if annotate: createDir(tmpDir)
  for f in files:
    if st.files >= limit: break
    inc st.files
    let rawSrc = readFile(f)
    # In --annotate mode: inject behavior-derived contracts (@frees) into a temp
    # copy and analyse THAT. Function ranges are recomputed on whatever we analyse
    # so scoring stays self-consistent under the injected line shifts.
    var src = rawSrc
    var analyzePath = f
    # a cross-file `_NNa.c` source's sink is defined in the sibling `_NNb.c` — read it so the
    # sink's `@frees(...)` can be derived and stamped on its prototype here, and so the
    # acknowledgement scan below can see a leak the corpus documents in the SINK's body rather
    # than in the caller's (empty otherwise).
    var sibling = ""
    if f.find(re(r"\d\da\.(c|cpp)$")) >= 0:
      let ext = (if f.endsWith(".cpp"): ".cpp" else: ".c")
      let sib = f[0 ..< f.len - ext.len - 1] & "b" & ext   # strip the trailing "a.<ext>", append "b.<ext>"
      if fileExists(sib): sibling = readFile(sib)
    if annotate:
      src = injectAnnotations(rawSrc, sibling, st)
      analyzePath = tmpDir / extractFilename(f)
      writeFile(analyzePath, src)
      annotateHeaders(f, rawSrc, tmpDir)   # class-based variants: contracts on the header's method decls
    let ranges = funcRanges(src)
    let srcLines = src.splitLines()
    let sibRanges = (if sibling.len > 0: funcRanges(sibling) else: @[])
    let sibLines = sibling.splitLines()
    for r in ranges:
      if r.kind == fkGood: inc st.goodFuncs
    let findings = runKenbi(analyzePath, support, parentDir(f))
    # collect matching-class error hits per function index
    var badHit = initTable[int, bool]()
    var goodFlagged = initTable[int, bool]()       ## good func -> flagged by same-class error
    var goodCodes = initTable[int, HashSet[string]]() ## good func -> set of error codes in it
    var badCodes = initTable[int, HashSet[string]]()  ## bad func -> every error code in it, so a
                                                      ## miss can say whether the function was
                                                      ## SILENT or flagged under another class
    for fnd in findings:
      if fnd{"severity"}.getStr != "error": continue
      # A delete through a base without a virtual destructor, of an object kenbi saw constructed
      # as a derived class, is undefined behaviour ([expr.delete]) — Juliet's `_82` / `_84`
      # polymorphic sinks do it in good functions too. Kept apart from the unverifiable form
      # (dynamic type not in view), which is not known to be UB.
      let code = (if fnd{"code"}.getStr == "DELETE_NONVIRTUAL_BASE" and
                     "is of a class derived" in fnd{"message"}.getStr:
                    "DELETE_NONVIRTUAL_BASE(derived)" else: fnd{"code"}.getStr)
      let line = fnd{"line"}.getInt
      if code == "CONTRACT_NOT_HONORED": inc st.contractNotHonored
      let fi = funcAt(ranges, line)
      if fi >= 0 and ranges[fi].kind == fkGood:
        goodCodes.mgetOrPut(fi, initHashSet[string]()).incl code
      if fi >= 0 and ranges[fi].kind == fkBad:
        badCodes.mgetOrPut(fi, initHashSet[string]()).incl code
      if code in clsSet:
        if fi < 0: stemDefect.incl testcaseStem(f)   # inside an indented class member
        if fi >= 0:
          case ranges[fi].kind
          of fkBad:
            badHit[fi] = true
            stemDefect.incl testcaseStem(f)
          of fkGood: goodFlagged[fi] = true
          of fkOther: stemDefect.incl testcaseStem(f)
      else:
        st.incidental.mgetOrPut(code, 0).inc
        if fi >= 0 and ranges[fi].kind == fkGood:
          st.incidentalGood.mgetOrPut(code, 0).inc
    # score: one expectation per bad function; categorize each flagged good func.
    const defensible = ["USE_AFTER_FREE", "DANGLING_RETURN", "DELETE_NONVIRTUAL_BASE(derived)"].toHashSet
    # Juliet's own words for "this function abandons the block on purpose". A LEAK reported in a
    # good function carrying one of these is the corpus agreeing with kenbi, not a false alarm:
    # the testcase is filed under its own CWE and simply tolerates the leak. Matched against the
    # function's OWN body so a neighbouring testcase's comment cannot be read as this one's.
    const leakAcknowledged = ["POSSIBLE MEMORY LEAK", "THIS CALL TO FREE() WAS REMOVED"]
    for idx, r in ranges:
      if r.kind == fkBad:
        if badHit.getOrDefault(idx, false): inc st.tp
        else:
          inc st.fn
          # A miss is not one thing. Either the bad function is COMPLETELY SILENT — kenbi
          # proved nothing and the code would pass, the one outcome soundness forbids — or it
          # is RED under a different class, which is a question of what the label says, not of
          # whether the bug was caught. Separate them: only the first is a false GREEN.
          if idx in badCodes:
            inc st.fnOtherClass
            for code in badCodes[idx]: st.fnOtherCodes.mgetOrPut(code, 0).inc
            if fnList:
              echo "FN-OTHERCLASS ", extractFilename(f), " ", r.name, " ",
                   toSeq(badCodes[idx].items).join(",")
          else:
            pendingSilent.add (testcaseStem(f), extractFilename(f), r.name)
      elif r.kind == fkGood:
        if goodFlagged.getOrDefault(idx, false): inc st.fp
        if goodCodes.hasKey(idx):
          inc st.fpAny
          if fnList: echo "FPANY ", extractFilename(f), " ", r.name, " ", toSeq(goodCodes[idx].items).join(",")
          let codes = goodCodes[idx]
          if "LEAK" in codes:
            var body = srcLines[r.startLine - 1 .. min(r.endLine, srcLines.len) - 1].join("\n")
            # In the cross-file `_NNa` variants the caller only hands the block to a sink in the
            # sibling, and it is THERE that the corpus writes the acknowledgement — so the bodies
            # of the sibling functions this one actually calls count as part of it.
            for sr in sibRanges:
              if body.contains(sr.name):
                body.add "\n" & sibLines[sr.startLine - 1 .. min(sr.endLine, sibLines.len) - 1]
                                   .join("\n")
            let up = body.toUpperAscii
            var acked = false
            for m in leakAcknowledged:
              if up.contains(m): acked = true
            if acked: inc st.fpLeakAcked else: inc st.fpLeakReview
          elif codes <= defensible: inc st.fpDefensible
          else: inc st.fpOther

  # A silent miss is only a false GREEN if the DEFECT is unreported, not merely if this function
  # is. Resolve each against the testcase-level record now that every file has been scanned.
  for ps in pendingSilent:
    if ps.stem in stemDefect:
      inc st.fnElsewhere
      if fnList: echo "FN-ELSEWHERE ", ps.file, " ", ps.fn
    else:
      inc st.fnSilent
      if fnList: echo "FN-SILENT ", ps.file, " ", ps.fn

  # report
  let total = st.tp + st.fn
  let recall = (if total > 0: st.tp.float / total.float * 100 else: 0.0)
  let fprate = (if st.goodFuncs > 0: st.fp.float / st.goodFuncs.float * 100 else: 0.0)
  echo "## ", cweDir, "  (class=", cls, (if annotate: ", ANNOTATED @frees" else: ", un-annotated"), ", lang=", lang, ")"
  echo "files scanned     : ", st.files
  if annotate:
    let cov = (if st.funcsRelevant > 0: st.funcsAnnotated.float / st.funcsRelevant.float * 100 else: 0.0)
    let covAll = (if st.funcsTotal > 0: st.funcsAnnotated.float / st.funcsTotal.float * 100 else: 0.0)
    echo "annotation coverage (stage=@frees):"
    echo "  functions total          : ", st.funcsTotal
    echo "  resource-relevant funcs  : ", st.funcsRelevant, "  (ptr-param / alloc / free)"
    echo "  annotated funcs          : ", st.funcsAnnotated
    echo "  coverage (of relevant)   : ", cov.formatFloat(ffDecimal, 1), "%   (of all: ", covAll.formatFloat(ffDecimal, 1), "%)"
    echo "  CONTRACT_NOT_HONORED     : ", st.contractNotHonored, "  (declared @frees but body does not free — intent != impl)"
  echo "bad functions     : ", total
  echo "  TP (detected)   : ", st.tp
  echo "  FN (missed)     : ", st.fn
  echo "    ├ SILENT (false GREEN — nothing reported anywhere in the testcase) : ", st.fnSilent
  echo "    ├ flagged where the defect lives (a sibling TU / an unattributable class member) : ", st.fnElsewhere
  echo "    └ flagged under another class (RED, different reason) : ", st.fnOtherClass
  if st.fnOtherCodes.len > 0:
    var oc: seq[string]
    for code, n in st.fnOtherCodes: oc.add code & " " & $n
    oc.sort()
    echo "        ", oc.join(" | ")
  echo "  recall          : ", recall.formatFloat(ffDecimal, 1), "%"
  let silentRate = (if total > 0: st.fnSilent.float / total.float * 100 else: 0.0)
  echo "  SILENT rate     : ", silentRate.formatFloat(ffDecimal, 1),
       "%  [the soundness number: defects kenbi reports nowhere in their testcase]"
  let fpAnyRate = (if st.goodFuncs > 0: st.fpAny.float / st.goodFuncs.float * 100 else: 0.0)
  echo "good functions    : ", st.goodFuncs
  echo "  FP same-class   : ", st.fp, "  (", fprate.formatFloat(ffDecimal, 1), "%)"
  echo "  FP any-class    : ", st.fpAny, "  (", fpAnyRate.formatFloat(ffDecimal, 1), "%)  [SARD-strict: good func should be silent]"
  echo "    ├ defensible (UB Juliet labels clean: freed-pointer value, non-virtual base delete) : ", st.fpDefensible
  echo "    ├ leak Juliet itself documents (a TP of another class, not a false alarm)             : ", st.fpLeakAcked
  echo "    ├ leak-in-good (REVIEW: residual FP, or a leak the corpus does not comment on)         : ", st.fpLeakReview
  echo "    └ other                                                                               : ", st.fpOther
  if st.incidental.len > 0:
    echo "incidental (other-class errors, reported not scored) [total | in good funcs]:"
    var keys = toSeq(st.incidental.keys); keys.sort()
    for k in keys:
      echo "  ", k, " : ", st.incidental[k], " | ", st.incidentalGood.getOrDefault(k, 0)

main()
