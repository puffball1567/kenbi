## Engine regressions independent of source-order tracking in the C frontend.
import std/[tables, sequtils]
import ../src/[ir, analyze]

proc ins(k: InstrKind, line: int, a = "p", b = ""): Stmt =
  Stmt(kind: stInstr, ik: k, line: line, a: a, b: b)

proc codes(body: seq[Stmt]): seq[string] =
  var p: Program
  p.resources["heap"] = Resource(name: "heap", freeId: "free", freeIds: @["free"])
  p.body = body
  analyze(p).mapIt(it.code)

# The first iteration starts without a binding; later iterations must see the
# freed allocation from the previous round, before this round allocates again.
for viaContinue in [false, true]:
  var body = @[ins(ikUse, 2), ins(ikAlloc, 3, b = "heap"), ins(ikFree, 4)]
  if viaContinue: body.add ins(ikContinue, 5)
  let got = codes(@[Stmt(kind: stLoop, line: 1, loopBody: body)])
  doAssert "USE_AFTER_FREE" in got, $got

# A break does not carry a freed binding back into an earlier use.
let stopped = codes(@[Stmt(kind: stLoop, line: 1, loopBody: @[
  ins(ikUse, 2), ins(ikAlloc, 3, b = "heap"), ins(ikFree, 4), ins(ikBreak, 5)])])
doAssert "USE_AFTER_FREE" notin stopped, $stopped

# A terminating body's offset must not poison the next dry run's loop head.
# There is no back edge: the release always sees the original pointer.
for ending in [ikBreak, ikReturn]:
  let terminated = codes(@[ins(ikAlloc, 1, b = "heap"),
    Stmt(kind: stLoop, line: 2, loopBody: @[
      ins(ikFree, 3),
      Stmt(kind: stInstr, ik: ikInterior, line: 4, a: "p", b: "p", off: 1),
      ins(ending, 5)])])
  doAssert "FREE_INTERIOR" notin terminated, $terminated

echo "PASS loop binding back edges"
