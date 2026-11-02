## Juliet three-state DEMONSTRATION harness for kenbi. kenbi is a conformance enforcer, not a bug-finder, so the right measure is not
## a recall/FP percentage but a three-state demonstration, per testcase:
##
##   A — un-annotated + `@kenbi` only  -> RED  ("you cannot even write it this way")
##   B — honestly annotated (bug too)  -> RED  ("you cannot annotate your way out")
##   C — the kenbi-idiomatic rewrite   -> GREEN ("here is how you write it safely")
##
## THIS FILE IMPLEMENTS STATE A (the starting point): take each Juliet testcase, add
## ONLY a file-level `// @kenbi` marker (no @mem / @frees / @borrows / @owns), and
## confirm EVERY memory-relevant function goes RED — nothing passes. A memory-relevant
## function that comes out GREEN with no ownership annotation is a hole in the
## mandatory-discipline rule (§5 invariant ①: every memory op must declare intent);
## the harness lists any such anomaly so it can be investigated.
##
## Usage:
##   nim c -r tests/juliet/demo.nim [CWE-dir ...] [--limit=N] [--juliet=PATH] [--show-green]
## With no CWE-dir, runs the five temporal classes. PATH defaults to $KENBI_JULIET or
## ../juliet. Run from the kenbi repo root; build ./kenbi first.

import std/[os, osproc, json, strutils, algorithm]

proc hasRealRelease(src: string): bool =
  ## True if the source contains an actual deallocation CALL — `free(<ident>)` or
  ## `delete <ident>` — not merely the word "free()" in a comment (Juliet's prose
  ## "Deallocate data using free()" has empty parens). A real call's `(` is followed
  ## by an identifier. Comment lines (`*` / `//` lead) are skipped.
  for raw in src.splitLines():
    let line = raw.strip()
    if line.startsWith("*") or line.startsWith("//") or line.startsWith("/*"): continue
    var i = 0
    while true:
      let at = line.find("free(", i)
      if at < 0: break
      var j = at + 5
      while j < line.len and line[j] == ' ': inc j
      if j < line.len and (line[j].isAlphaAscii or line[j] == '_'): return true
      i = at + 5
    if "delete " in line and line.find("delete ") + 7 < line.len: return true
  false

const temporalCwes = [
  "CWE415_Double_Free",
  "CWE416_Use_After_Free",
  "CWE401_Memory_Leak",
  "CWE590_Free_Memory_Not_on_Heap",
  "CWE761_Free_Pointer_Not_at_Start_of_Buffer",
]

type StateAStats = object
  files: int
  errored: int            ## kenbi failed to parse / returned no document
  memFuncs: int           ## total memory-relevant functions (the coverage denominator)
  green: int              ## memory-relevant funcs that came out GREEN (should be 0)
  red: int                ## memory-relevant funcs flagged RED
  filesAllRed: int        ## files where every mem-relevant func is RED (0 GREEN) — the goal
  filesWithGreen: int     ## files where >=1 mem-relevant func slipped through GREEN
  greenFiles: seq[string] ## paths of the anomaly files (a GREEN under @kenbi-only)
  silentRelease: int      ## files whose source frees/deletes a pointer but kenbi saw NO
                          ## memory-relevant function and flagged nothing — a release on an
                          ## undeclared parameter slipped past the discipline (State-A hole)
  silentFiles: seq[string]

proc runCoverage(file, support: string): (bool, JsonNode) =
  ## Run kenbi --format=json on one file; return (ok, coverage-object).
  let (outp, _) = execCmdEx("./kenbi --format=json " & quoteShell(file) &
                            " -- -I " & quoteShell(support))
  try:
    let j = parseJson(outp)
    if j.hasKey("coverage"): return (true, j["coverage"])
  except CatchableError: discard
  (false, newJNull())

proc main() =
  var cweDirs: seq[string]
  var julietRoot = getEnv("KENBI_JULIET", "../juliet")
  var limit = high(int)
  var showGreen = false
  var showSilent = false
  for i in 1 .. paramCount():
    let a = paramStr(i)
    if a.startsWith("--limit="): limit = parseInt(a[8 .. ^1])
    elif a.startsWith("--juliet="): julietRoot = a[9 .. ^1]
    elif a == "--show-green": showGreen = true
    elif a == "--show-silent": showSilent = true
    elif a.startsWith("--"): quit("unknown flag " & a, 1)
    else: cweDirs.add a
  if cweDirs.len == 0:
    for c in temporalCwes: cweDirs.add c

  let support = julietRoot / "testcasesupport"
  let tmpDir = getCurrentDir() / "tmp" / "juliet_state_a"
  createDir(tmpDir)

  var grand: StateAStats
  echo "# Juliet State A — un-annotated + `@kenbi` only -> expect ALL RED, 0 GREEN"
  echo "# (a memory-relevant function GREEN here would be a discipline hole)"
  echo ""
  for cwe in cweDirs:
    let dir = julietRoot / "testcases" / cwe
    if not dirExists(dir):
      echo "## ", cwe, "  -- NOT FOUND at ", dir
      continue
    var files: seq[string]
    for f in walkDirRec(dir):
      if f.endsWith(".c"): files.add f
    files.sort()

    var st: StateAStats
    for f in files:
      if st.files >= limit: break
      inc st.files
      # State A: a file-level `@kenbi` (no function on the next line) covers the whole
      # TU; NO ownership annotations are added. Everything memory-relevant must be RED.
      let dst = tmpDir / (cwe & "__" & extractFilename(f))
      let raw = readFile(f)
      writeFile(dst, "// @kenbi\n" & raw)
      let (ok, cov) = runCoverage(dst, support)
      if not ok:
        inc st.errored
        continue
      let mem = cov{"memoryFunctions"}.getInt
      let green = cov{"green"}.getInt
      let red = cov{"red"}.getInt
      st.memFuncs += mem
      st.green += green
      st.red += red
      # A release in the source (free/delete) that kenbi saw nothing of: the dealloc was
      # on an undeclared pointer parameter (a cross-function sink half) and slipped past
      # the @kenbi discipline — a State-A hole worth fixing (intake-side default-red).
      if mem == 0 and red == 0 and hasRealRelease(raw):
        inc st.silentRelease
        st.silentFiles.add f
      if mem > 0:
        if green == 0: inc st.filesAllRed
        else:
          inc st.filesWithGreen
          st.greenFiles.add f

    echo "## ", cwe
    echo "  files scanned            : ", st.files
    if st.errored > 0:
      echo "  parse-errored            : ", st.errored, "  (excluded)"
    echo "  memory-relevant functions: ", st.memFuncs
    echo "  RED                      : ", st.red
    echo "  GREEN (should be 0)      : ", st.green
    let analysed = st.filesAllRed + st.filesWithGreen
    echo "  files fully RED (0 GREEN): ", st.filesAllRed, " / ", analysed,
         (if analysed > 0 and st.filesAllRed == analysed: "   ✓ all fail (State A holds)" else: "")
    if st.filesWithGreen > 0:
      echo "  files with a GREEN slip  : ", st.filesWithGreen, "  ← discipline holes, investigate"
      if showGreen:
        for g in st.greenFiles: echo "      ", g
    if st.silentRelease > 0:
      echo "  silent release (HOLE)    : ", st.silentRelease,
           "  ← source frees a pointer but kenbi saw nothing (undeclared-param free)"
      if showSilent:
        for s in st.silentFiles: echo "      ", extractFilename(s)
    echo ""

    grand.files += st.files
    grand.errored += st.errored
    grand.memFuncs += st.memFuncs
    grand.green += st.green
    grand.red += st.red
    grand.filesAllRed += st.filesAllRed
    grand.filesWithGreen += st.filesWithGreen
    grand.silentRelease += st.silentRelease
    for g in st.greenFiles: grand.greenFiles.add g
    for s in st.silentFiles: grand.silentFiles.add s

  echo "# ───────────────────────────────────────────────"
  echo "# TOTAL  files=", grand.files, "  mem-funcs=", grand.memFuncs,
       "  RED=", grand.red, "  GREEN=", grand.green
  let analysed = grand.filesAllRed + grand.filesWithGreen
  echo "# files fully RED (0 GREEN): ", grand.filesAllRed, " / ", analysed
  if grand.filesWithGreen == 0 and analysed > 0:
    echo "# ✓ analysed files: every memory-relevant function is RED under `@kenbi`-only."
  elif grand.filesWithGreen > 0:
    echo "# ✗ ", grand.filesWithGreen, " file(s) had a GREEN memory-relevant function — investigate."
    if not showGreen:
      echo "#   re-run with --show-green to list them."
  if grand.silentRelease > 0:
    echo "# ⚠ STATE-A HOLE: ", grand.silentRelease,
         " file(s) free a pointer that kenbi never saw (release on an undeclared"
    echo "#   parameter — the cross-function sink halves). These should be RED too:"
    echo "#   freeing an undeclared pointer param is the intake-side default-red boundary."

main()
