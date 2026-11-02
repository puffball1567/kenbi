## C / C++ front-end test runner: for each tests/c/*.c and tests/cpp/*.cpp,
## lower it through the libclang front-end and assert that the diagnostics the
## engine produces exactly match the `//EXPECT` lines in the file.
##
## Assertion strength: each expectation asserts a diagnostic CODE and, usually, its
## line. Three forms (all may carry several space-separated CODEs after `//EXPECT`):
##
##   * TRAILING  `<stmt>   //EXPECT CODE`  — code precedes the marker on the line, so
##     the CODE is asserted ON THAT LINE. This is **move-invariant**: the marker
##     travels with the statement, so editing comments / headers above it never shifts
##     the assertion. PREFERRED form.
##   * EXACT     `//EXPECT CODE@LINE`      — a standalone marker pinning an absolute
##     line (legacy / when the finding's line is awkward to mark inline).
##   * ANY-LINE  `//EXPECT CODE`           — a standalone marker (nothing before it):
##     presence only, no line assertion.
##
## Matching is multiset (count-sensitive): an extra or missing diagnostic fails. A
## file with no //EXPECT markers must be clean.
##
## A `//ARGS <clang flags>` line compiles that one file under a different compile line
## (e.g. `-fopenmp`, which changes the AST shape rather than just the warnings).

import std/[os, strutils, algorithm]
import "../src/frontend_c", "../src/analyze"

type Expect = tuple[code: string, line: int]   ## line: -1 = any, N = exact line N

proc expectations(src: string): seq[Expect] =
  var lineNo = 0
  for raw in src.splitLines():
    inc lineNo
    let pos = raw.find("//EXPECT")
    if pos < 0: continue
    let trailing = raw[0 ..< pos].strip().len > 0   # code before the marker -> tags this line
    for t in raw[pos + "//EXPECT".len .. ^1].splitWhitespace():
      if '@' in t:
        let pa = t.split('@')
        result.add (pa[0], (try: parseInt(pa[1]) except: -1))
      elif trailing: result.add (t, lineNo)
      else: result.add (t, -1)

proc extraArgs(src: string): seq[string] =
  ## `//ARGS <clang flags>` — compile this test under a different compile line, the way a
  ## project's own build does (`-fopenmp` changes the AST shape, not just the warnings).
  ## Without a marker the file is compiled with the default flags.
  for line in src.splitLines():
    let s = line.strip()
    if s.startsWith("//ARGS"): result.add s.splitWhitespace()[1 .. ^1]

proc covExpectations(src: string): seq[(string, string)] =
  ## `//COV key=value ...` directives assert CoverageStats fields (Phase 3 per-flow
  ## / trusted-frontier). Keys: green, verified, adopted, totalMem, red, blocks,
  ## unsafeVouches (int) and frontier (comma-separated sorted names, or `-` for none).
  ## A file with no //COV line skips the coverage assertion.
  for line in src.splitLines():
    let s = line.strip()
    if s.startsWith("//COV"):
      for tok in s.splitWhitespace()[1 .. ^1]:
        let kv = tok.split('=', 1)
        if kv.len == 2: result.add (kv[0], kv[1])

proc covMatches(exp: seq[(string, string)], cov: CoverageStats): (bool, string) =
  ## Returns (ok, detail). detail names the first mismatch for a useful failure.
  ## Most keys assert an int / the frontier list. `flow=<entry>/<verified>/<blockers>`
  ## (blockers joined by `+`, `-` for none) asserts one entry-point flow exists and
  ## matches; `flows=<n>` asserts the flow count.
  for (k, v) in exp:
    if k == "flow":
      let parts = v.split('/')
      if parts.len != 3: return (false, "bad flow spec '" & v & "'")
      var found = false
      for fl in cov.flows:
        if fl.entry != parts[0]: continue
        found = true
        let bl = (if fl.blockers.len == 0: "-" else: fl.blockers.join("+"))
        let vs = (if fl.verified: "true" else: "false")
        if vs != parts[1] or bl != parts[2]:
          return (false, "flow " & parts[0] & " expected " & parts[1] & "/" &
                  parts[2] & " got " & vs & "/" & bl)
      if not found: return (false, "no flow with entry '" & parts[0] & "'")
      continue
    let got =
      case k
      of "green": $cov.green
      of "verified": $cov.verified
      of "adopted": $cov.adopted
      of "totalMem": $cov.totalMem
      of "red": $cov.red
      of "blocks": $cov.blocks
      of "unsafeVouches": $cov.unsafeVouches.len
      of "flows": $cov.flows.len
      of "frontier": (if cov.trustedFrontier.len == 0: "-" else: cov.trustedFrontier.join(","))
      else: return (false, "unknown COV key '" & k & "'")
    if got != v: return (false, k & " expected " & v & " got " & got)
  (true, "")

proc matches(exp: seq[Expect], prod: seq[string]): bool =
  ## Every expectation must consume exactly one produced diagnostic (`CODE@LINE`);
  ## nothing left over. `line == -1` matches any line; otherwise the line must equal.
  var pool = prod
  for e in exp:
    var hit = -1
    for i, p in pool:
      let parts = p.split('@')
      if parts[0] != e.code: continue
      if e.line < 0 or (parts.len > 1 and parts[1] == $e.line): hit = i; break
    if hit < 0: return false
    pool.delete(hit)
  pool.len == 0

proc fmt(exp: seq[Expect]): seq[string] =
  for e in exp: result.add (if e.line < 0: e.code else: e.code & "@" & $e.line)
  result.sort()

let root = currentSourcePath().parentDir()
var names: seq[string]
for sub in ["c", "cpp"]:
  let dir = root / sub
  if dirExists(dir):
    for _, path in walkDir(dir):
      if path.endsWith(".c") or path.endsWith(".cpp") or path.endsWith(".cc"):
        names.add path
names.sort()

var ran, failed = 0
for path in names:
  inc ran
  let src = readFile(path)
  let exp = expectations(src)
  let covExp = covExpectations(src)
  let full = analyzeFull(parseCFile(path, extraArgs(src)))
  var got: seq[string]
  for d in full.diags: got.add d.code & "@" & $d.line
  let (covOk, covDetail) = covMatches(covExp, full.cov)
  if matches(exp, got) and covOk:
    echo "PASS  ", extractFilename(path)
  else:
    inc failed
    echo "FAIL  ", extractFilename(path)
    if not matches(exp, got):
      echo "  expected: ", fmt(exp)
      echo "  got:      ", got.sorted()
    if not covOk:
      echo "  coverage: ", covDetail

echo "---"
echo ran - failed, "/", ran, " passed"
if failed > 0: quit(1)
