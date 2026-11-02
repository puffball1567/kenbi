## Mini-format parser: a line-oriented stand-in for the eventual libclang
## front-end. Each meaningful line is one instruction or an @mem annotation;
## structured branches use `if` / `else` / `endif`. `#` starts a comment.
##
## Grammar (one statement per line):
##   @mem <scoped::name> { size: <id>, free: <id>, owner: <id> }
##   alloc    <var> <resource>
##   copy     <dst> <src>
##   interior <dst> <src> <offset>
##   use      <var>
##   free     <var>
##   move     <var>
##   if / else / endif

import std/[tables, strutils]
import ir

type ParseError* = object of CatchableError

type Tok = object
  line: int
  words: seq[string]

proc fail(lineNo: int, msg: string) =
  raise newException(ParseError, "line " & $lineNo & ": " & msg)

proc parseMemLine(line: string, lineNo: int, prog: var Program) =
  let braceOpen = line.find('{')
  let braceClose = line.rfind('}')
  if braceOpen < 0 or braceClose < 0 or braceClose < braceOpen:
    fail(lineNo, "malformed @mem (expected '{ ... }')")
  let head = line[0 ..< braceOpen].splitWhitespace()   # ["@mem", "<name>"]
  if head.len < 2:
    fail(lineNo, "@mem needs a resource name")
  var res = Resource(name: head[1], declLine: lineNo)
  for f in line[braceOpen+1 ..< braceClose].split(','):
    let kv = f.split(':')
    if kv.len != 2: continue
    let key = kv[0].strip()
    let val = kv[1].strip()
    case key
    of "size":  res.sizeId = val
    of "free":  res.freeId = val; res.freeIds = @[val]
    of "owner": res.ownerId = val
    else: discard
  prog.resources[res.name] = res

proc lex(src: string, prog: var Program): seq[Tok] =
  var lineNo = 0
  for raw in src.splitLines():
    inc lineNo
    let h = raw.find('#')
    let s = (if h >= 0: raw[0 ..< h] else: raw).strip()
    if s.len == 0: continue
    if s.startsWith("@mem"):
      parseMemLine(s, lineNo, prog)
      continue
    result.add Tok(line: lineNo, words: s.splitWhitespace())

proc need(t: Tok, n: int) =
  if t.words.len < n:
    fail(t.line, "'" & t.words[0] & "' expects " & $(n-1) & " operand(s)")

proc buildBlock(toks: seq[Tok], i: var int, stop: openArray[string]): seq[Stmt] =
  while i < toks.len:
    let t = toks[i]
    let kw = t.words[0]
    if kw in stop: break
    inc i
    case kw
    of "alloc":
      need(t, 3)
      result.add Stmt(line: t.line, kind: stInstr, ik: ikAlloc, a: t.words[1], b: t.words[2])
    of "copy":
      need(t, 3)
      result.add Stmt(line: t.line, kind: stInstr, ik: ikCopy, a: t.words[1], b: t.words[2])
    of "interior":
      need(t, 4)
      var off = 0
      try: off = parseInt(t.words[3])
      except ValueError: fail(t.line, "interior offset must be an integer")
      result.add Stmt(line: t.line, kind: stInstr, ik: ikInterior, a: t.words[1], b: t.words[2], off: off)
    of "use":
      need(t, 2)
      result.add Stmt(line: t.line, kind: stInstr, ik: ikUse, a: t.words[1])
    of "free":
      need(t, 2)
      result.add Stmt(line: t.line, kind: stInstr, ik: ikFree, a: t.words[1])
    of "move":
      need(t, 2)
      result.add Stmt(line: t.line, kind: stInstr, ik: ikMove, a: t.words[1])
    of "if":
      var s = Stmt(line: t.line, kind: stIf)
      s.thenBody = buildBlock(toks, i, ["else", "endif"])
      if i < toks.len and toks[i].words[0] == "else":
        inc i
        s.elseBody = buildBlock(toks, i, ["endif"])
      if i < toks.len and toks[i].words[0] == "endif":
        inc i
      else:
        fail(t.line, "'if' without matching 'endif'")
      result.add s
    else:
      fail(t.line, "unknown instruction '" & kw & "'")

proc parseProgram*(src: string): Program =
  result.resources = initTable[string, Resource]()
  let toks = lex(src, result)
  var i = 0
  result.body = buildBlock(toks, i, [])
  if i < toks.len:
    fail(toks[i].line, "stray '" & toks[i].words[0] & "'")
