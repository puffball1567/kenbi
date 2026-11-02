## PROJECT-level coverage regression.
##
## One file at a time, kenbi verifies each function against the contracts on the boundary and
## reports what its GREEN rests on (the trusted frontier). Analysed TOGETHER, a contracted call
## into a function defined in another analysed file resolves to that file's verdict, so a GREEN
## whose whole closure is analysed and GREEN becomes VERIFIED and drops off the frontier. What
## nothing in the project defines stays on it — that is the genuine outside.
import std/[os, json, osproc, strutils]
import "../src/frontend_c", "../src/analyze"

proc unitOf(path: string): tuple[cov: CoverageStats, unit: ProjectUnit] =
  let full = analyzeFull(parseCFile(path))
  (full.cov, full.unit)

proc check(name: string, got, want: int, failed: var int) =
  if got != want:
    echo "FAIL  ", name, ": expected ", want, ", got ", got
    inc failed

let dir = currentSourcePath().parentDir / "project"
let app = unitOf(dir / "app.c")
let lib = unitOf(dir / "lib.c")
var failed = 0

# app.c ALONE: both functions are GREEN, neither is verified — each rests on lib_make plus a
# release it cannot see, and all three names sit on the frontier.
check("app alone: green", app.cov.green, 2, failed)
check("app alone: verified", app.cov.verified, 0, failed)
check("app alone: frontier size", app.cov.trustedFrontier.len, 3, failed)
if app.cov.trustedFrontier != @["lib_make", "lib_release", "vendor_release"]:
  echo "FAIL  app alone: frontier = ", app.cov.trustedFrontier
  inc failed

# TOGETHER: lib.c's bodies close `app`'s closure. `app_vendor` still rests on vendor_release,
# which no analysed file defines — the frontier narrows to exactly that.
let proj = projectCoverage(@[app.unit, lib.unit])
check("project: memory-relevant", proj.totalMem, 4, failed)
check("project: green", proj.green, 4, failed)
check("project: verified", proj.verified, 3, failed)
check("project: red", proj.red, 0, failed)
if proj.trustedFrontier != @["vendor_release"]:
  echo "FAIL  project: frontier = ", proj.trustedFrontier
  inc failed

# the flow rooted at `app` has no blockers left; `app_vendor`'s keeps the external one
var appFlowVerified = false
var vendorBlockers: seq[string]
for fl in proj.flows:
  if fl.entry == "app": appFlowVerified = fl.verified
  elif fl.entry == "app_vendor": vendorBlockers = fl.blockers
if not appFlowVerified:
  echo "FAIL  project: the `app` flow should be verified"; inc failed
if vendorBlockers != @["vendor_release"]:
  echo "FAIL  project: app_vendor blockers = ", vendorBlockers; inc failed

# an entry with a finding of its own is not verified, even though nothing it calls blocks it
let red = projectCoverage(@[unitOf(dir / "red_entry.c").unit])
check("red entry: red", red.red, 1, failed)
check("red entry: flows", red.flows.len, 1, failed)
for fl in red.flows:
  if fl.verified or fl.blockers.len != 0:
    echo "FAIL  red entry: flow ", fl.entry, " verified=", fl.verified, " blockers=", fl.blockers
    inc failed

# --- the CLI path: `kenbi --project=<compile_commands.json>` analyses every unit the database
# lists, so one command reports the project-wide closure. The database is written here with
# this checkout's absolute directory (a committed one would name someone else's machine).
let repo = currentSourcePath().parentDir.parentDir
if fileExists(repo / "kenbi"):
  createDir(repo / "tmp")
  let db = repo / "tmp" / "project_cc.json"
  writeFile(db, ("""[
  {"directory": "$1", "file": "app.c", "arguments": ["cc", "-c", "app.c", "-I", "."]},
  {"directory": "$1", "file": "lib.c", "arguments": ["cc", "-c", "lib.c", "-I", "."]}
]""") % [dir])
  let (outp, code) = execCmdEx("./kenbi --format=json --project=" & db.quoteShell)
  if code notin [0, 1]:
    echo "FAIL  --project: exit ", code, "\n", outp
    inc failed
  else:
    let cov = parseJson(outp){"coverage"}
    if cov{"verified"}.getInt != 3:
      echo "FAIL  --project: verified = ", cov{"verified"}.getInt; inc failed
    if cov{"memoryFunctions"}.getInt != 4:
      echo "FAIL  --project: memoryFunctions = ", cov{"memoryFunctions"}.getInt; inc failed
    var fr: seq[string]
    for x in cov{"trustedFrontier"}: fr.add x.getStr
    if fr != @["vendor_release"]:
      echo "FAIL  --project: frontier = ", fr; inc failed
  # --- `--emit-contracts`: publishing the contract SET, with what was established about each.
  # The point of the format is that a consumer cannot mistake "a contract is declared" for
  # "the implementation was checked", so every weaker state has to come out as its own word.
  # ext.c exists to make all of them present at once (see its header).
  let db3 = repo / "tmp" / "project_emit_cc.json"
  writeFile(db3, ("""[
  {"directory": "$1", "file": "app.c", "arguments": ["cc", "-c", "app.c", "-I", "."]},
  {"directory": "$1", "file": "lib.c", "arguments": ["cc", "-c", "lib.c", "-I", "."]},
  {"directory": "$1", "file": "ext.c", "arguments": ["cc", "-c", "ext.c", "-I", "."]}
]""") % [dir])
  let (eOut, eCode) = execCmdEx("./kenbi --emit-contracts --project=" & db3.quoteShell)
  # publishing is not a check: ext.c is RED and the exit code is still 0
  if eCode != 0:
    echo "FAIL  --emit-contracts: exit ", eCode, "\n", eOut
    inc failed
  else:
    let doc = parseJson(eOut)
    if doc{"kind"}.getStr != "contract-set":
      echo "FAIL  --emit-contracts: kind = ", doc{"kind"}.getStr; inc failed
    var got: seq[string]
    for c in doc{"contracts"}:
      got.add c{"function"}.getStr & " " & c{"effect"}.getStr & "(" &
              c{"param"}.getStr & ")=" & c{"status"}.getStr
    let want = @[
      "ext_bad @frees(p)=red",             # body under @kenbi contradicts the contract
      "ext_take @frees(p)=unchecked",      # body present, not adopted: kenbi checked nothing
      "ext_trusting @frees(p)=green",      # checked and clean, resting on vendor_release
      "lib_make @owns()=verified",         # whole closure covered — no trust residue
      "lib_release @frees(p)=verified",
      "vendor_release @frees(p)=declared"] # no implementation anywhere: nothing was verified
    if got != want:
      echo "FAIL  --emit-contracts: contracts =\n    ", got.join("\n    "); inc failed
    # the alloc -> free vocabulary travels with the contracts: a consumer told only the
    # deallocators cannot tell which call handed it the obligation
    var resNames: seq[string]
    for r in doc{"resources"}: resNames.add r{"name"}.getStr
    if resNames != @["app::buf", "app::vbuf", "lib::buf"]:
      echo "FAIL  --emit-contracts: resources = ", resNames; inc failed
  removeFile(db3)
  removeFile(db)
else:
  echo "  (./kenbi not built — skipping the --project CLI check)"

if failed == 0: echo "project coverage: all checks passed"
else: quit(1)
