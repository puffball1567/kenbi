## kenbi CLI — annotation-driven static memory-safety checker.
##
## Front-ends:
##   *.c / *.cc / *.cpp / *.cxx  -> libclang (real C / C++), Phase 1
##   *.mc                        -> mini-format (walking-skeleton fixtures)
##
## For C/C++, parse flags are taken from compile_commands.json when present
## (searched upward from the source, or passed via --compile-commands=PATH).
## Extra clang args can be appended after `--`.
##
## Usage: kenbi [--format=text|json] [--compile-commands=PATH] [--project[=PATH]]
##              [--emit-contracts] <file> [more...] [-- <clang args>]
##        kenbi [--format=text|json] --safety=project.json
##        kenbi --version
## Exit:  0 = clean, 1 = issues found, 2 = usage/parse error.
##
## `--emit-contracts` publishes the contract SURFACE of what was analysed instead of
## checking it: the packages, the alloc/free vocabulary and every function contract, each
## carrying what this run established about the implementation behind it. See emitContracts.

import std/[os, strutils, json, sets, tables, algorithm]
import ir, parse, analyze, frontend_c, cfront_core, compile_db
import strip, cfront_annotations, clang
import safety_check

type
  Format = enum fmtText, fmtJson
  FileResult = object
    path: string
    ok: bool            ## parsed successfully
    err: string         ## error message when not ok
    diags: seq[Diag]
    cov: CoverageStats
    unit: ProjectUnit   ## this file's contribution to PROJECT-level coverage
    contracts: seq[ContractDecl]  ## the contract surface this TU declared (--emit-contracts)
    resources: seq[Resource]      ## the resource families it declared (ditto)
    deepFrees: HashSet[string]    ## releases declared `frees_fields:`
    scope: JsonNode               ## what was checked, axis by axis (scopeOf)

proc isCSource(p: string): bool =
  let l = p.toLowerAscii
  l.endsWith(".c") or l.endsWith(".cc") or l.endsWith(".cpp") or
  l.endsWith(".cxx") or l.endsWith(".cppm")

proc loadProgram(path, dbOverride: string, extra: seq[string]): Program =
  if isCSource(path):
    let db = (if dbOverride.len > 0: dbOverride else: findCompileDb(path))
    let dbArgs = (if db.len > 0: argsForFile(db, path) else: @[])
    parseCFile(path, dbArgs & extra)
  else:
    parseProgram(readFile(path))

proc scopeOf(prog: Program): JsonNode =
  ## What this run checked in one file, axis by axis, as `axesOf` decided it for each function.
  ## A file without findings is clean within this and nothing more, so the scope is reported
  ## next to the findings rather than left for the reader to reconstruct. Per axis, `mode` is
  ## `file` (every function), `functions` (some: the rest are named in `unchecked`) or `off`.
  var names: seq[string]
  var axes = initTable[string, set[Axis]]()
  for fn in prog.funcs:
    if fn.name.len == 0: continue
    if fn.name notin axes: names.add fn.name
    axes[fn.name] = axes.getOrDefault(fn.name) + axesOf(prog, fn)
  var axesJson = newJObject()
  for ax in Axis:
    var unchecked = newJArray()
    var checked = 0
    for n in names:
      if ax in axes[n]: inc checked else: unchecked.add %n
    # a mini-format program has no functions: its single body is checked for ownership only
    let mode =
      if names.len == 0: (if ax == axOwnership: "file" else: "off")
      elif checked == names.len: "file"
      elif checked == 0: "off"
      else: "functions"
    axesJson[$ax] = %*{"mode": mode, "checked": checked,
                       "unchecked": (if mode == "functions": unchecked else: newJArray())}
  var blocks = newJArray()
  for b in prog.coveredBlocks: blocks.add %*{"first": b.first, "last": b.last}
  %*{"functions": names.len, "axes": axesJson, "ownershipBlocks": blocks}

proc scopeText(scope: JsonNode): string =
  ## One line: which checks ran and which did not, for the text output.
  var ran, partial, off: seq[string]
  for ax in Axis:
    let a = scope["axes"][$ax]
    let label = (if ax == axUnions: "tagged unions" else: $ax)
    case a["mode"].getStr
    of "file": ran.add label
    of "functions":
      partial.add label & " in " & $a["checked"].getInt & " of " & $scope["functions"].getInt &
                  " functions"
    else: off.add label
  var parts: seq[string]
  if ran.len > 0: parts.add "checked: " & ran.join(", ")
  if partial.len > 0: parts.add "partly checked: " & partial.join(", ")
  if off.len > 0: parts.add "not checked: " & off.join(", ")
  parts.join("; ")

proc analyzeOne(path, dbOverride: string, extra: seq[string]): FileResult =
  result.path = path
  var prog: Program
  try:
    prog = loadProgram(path, dbOverride, extra)
  except IOError:
    result.err = "cannot read " & path
    return
  except ParseError as e:
    result.err = "parse error: " & e.msg
    return
  except CFrontError as e:
    result.err = e.msg
    return
  result.ok = true
  let full = analyzeFull(prog)
  result.diags = full.diags
  result.cov = full.cov
  result.unit = full.unit
  result.contracts = prog.contracts
  result.deepFrees = prog.deepFrees
  for _, res in prog.resources: result.resources.add res
  result.scope = scopeOf(prog)

proc dumpStmts(stmts: seq[Stmt], indent: int) =
  ## `--dump-ir`: the lowered IR of every function, one instruction per line — the front-end's
  ## view, before the engine. For diagnosing what a construct lowered to (or did not).
  let pad = repeat(' ', indent)
  for s in stmts:
    case s.kind
    of stInstr:
      var line = pad & $s.line & ": " & $s.ik
      if s.a.len > 0: line.add " a=" & s.a
      if s.b.len > 0: line.add " b=" & s.b
      if s.aKey.len > 0: line.add " aKey=" & s.aKey
      if s.bKey.len > 0: line.add " bKey=" & s.bKey
      if s.cKey.len > 0: line.add " cKey=" & s.cKey
      if s.off != 0: line.add " off=" & $s.off
      echo line
    of stIf:
      echo pad & $s.line & ": if" & (if s.condKey.len > 0: " (" & s.condDisp & ")" else: "")
      dumpStmts(s.thenBody, indent + 2)
      if s.elseBody.len > 0:
        echo pad & "else"; dumpStmts(s.elseBody, indent + 2)
    of stLoop:
      echo pad & $s.line & ": loop"; dumpStmts(s.loopBody, indent + 2)
    of stSwitch:
      echo pad & $s.line & ": switch"
      for c in s.cases:
        echo pad & "case"; dumpStmts(c, indent + 2)
    of stLabel: echo pad & $s.line & ": label " & s.labelName
    of stTry:
      echo pad & $s.line & ": try"; dumpStmts(s.tryBody, indent + 2)
      for i, h in s.handlers:
        echo pad & "catch (" & (if i < s.handlerTypes.len: s.handlerTypes[i] else: "?") & ")"
        dumpStmts(h, indent + 2)

proc dumpIr(path, dbOverride: string, extra: seq[string]) =
  let prog = loadProgram(path, dbOverride, extra)
  for fn in prog.funcs:
    echo "== ", fn.name, " @", fn.line
    dumpStmts(fn.body, 2)

proc sevStr(s: Severity): string =
  case s
  of sevError: "error"
  of sevWarning: "warning"
  of sevAdvisory: "advisory"

proc totalCoverage(results: seq[FileResult]): CoverageStats =
  ## Coverage over everything analysed in this run. The counts and the CLOSURE are computed
  ## on the merged function set (projectCoverage), so a contracted call into a function
  ## defined in another file analysed here resolves to that file's verdict: `verified` spans
  ## the project and the trusted frontier narrows to what nothing analysed defines. Per-file
  ## flows are carried through as they are (a flow is rooted in one file's entry point).
  var units: seq[ProjectUnit]
  for r in results:
    if r.ok and r.unit.funcs.len > 0: units.add r.unit
  if units.len > 0: result = projectCoverage(units)

proc pct(n, d: int): string =
  (if d > 0: $int(n.float / d.float * 100 + 0.5) else: "0") & "%"

proc renderText(results: seq[FileResult]) =
  for r in results:
    if not r.ok:
      stderr.writeLine r.path & ": " & r.err
      continue
    for d in r.diags:
      echo r.path, ":", d.line, ": ", sevStr(d.sev), ": ", d.msg, " [", d.code, "]"
    if r.diags.len == 0:
      echo r.path, ": ok — no findings from the checks that ran"
    echo "  ", scopeText(r.scope)
  let c = totalCoverage(results)
  if c.totalMem > 0:
    echo "── kenbi coverage ───────────────────────────"
    echo "  memory-relevant functions : ", c.totalMem
    echo "  GREEN (contracted)        : ", c.green, "  (", pct(c.green, c.totalMem),
         ")  ← boundaries declared, modular-trust"
    echo "  verified (no trust residue): ", c.verified, "  (", pct(c.verified, c.totalMem),
         ")  ← whole closure covered"
    echo "  adopted (@kenbi)          : ", c.adopted, "  (", pct(c.adopted, c.totalMem), ")"
    if c.blocks > 0:
      echo "  blocks adopted (@kenbi)   : ", c.blocks,
           "  ← inside functions that are not adopted as a whole"
    if c.red > 0:
      echo "  RED (needs fixing)        : ", c.red, "  (separate from coverage — fix these)"
    if c.trustedFrontier.len > 0:
      echo "  trusted frontier          : ", c.trustedFrontier.len,
           "  ← cover these to remove trust residue"
      echo "      ", c.trustedFrontier.join(", ")
    if c.contractPackages.len > 0:
      # what a consumer needs in order to read the rest: whose contracts these are, which
      # version they were written for, and whether they describe the build in front of us
      echo "  contract packages         : ", c.contractPackages.len
      for p in c.contractPackages:
        let ver = (if p.version.len > 0: " " & p.version else: " (no version declared)")
        var note = "build conditions checked"
        if p.mismatched.len > 0: note = "BUILD MISMATCH — " & p.mismatched.join("; ")
        elif p.unverified.len > 0:
          note = "unverified: " & p.unverified.join(", ") & " (not on the compile line)"
        elif p.requires.len == 0: note = "no build conditions declared"
        echo "      ", p.name, ver, " — ", note, "  [version declared, not verified]"
    if c.unsafeVouches.len > 0:
      # the strongest trust residue: an assertion kenbi could not check. Named, so that
      # "verified" can never quietly include something only an annotation vouches for.
      echo "  @unsafe vouches           : ", c.unsafeVouches.len,
           "  ← asserted, not verified"
      for v in c.unsafeVouches:
        echo "      ", v.fn, " (line ", v.line, ")"
    var incomplete: seq[FlowInfo]
    for fl in c.flows:
      if not fl.verified: incomplete.add fl
    if incomplete.len > 0:
      echo "  flows needing work        : ", incomplete.len, " of ", c.flows.len
      for fl in incomplete:
        echo "      ", fl.entry, "  ← blocked by: ",
             (if fl.blockers.len > 0: fl.blockers.join(", ") else: "its own `@unsafe`")
    if c.adopted == 0 and c.blocks == 0:
      echo "  (no @kenbi markers — add one to adopt a function/file and start raising coverage)"

proc renderJson(results: seq[FileResult]) =
  ## Stable machine-readable schema: { version, tool, findings: [ {file, line,
  ## code, severity, message} ] }. Codes are stable; ordering is deterministic
  ## (file order, then the engine's (line, code) sort). Parse/read failures are
  ## reported as PARSE_ERROR findings so consumers see one structured document.
  ## `coverage` is the adoption and trust picture over the whole run, and `scope` lists, per
  ## analysed file, which checks ran on which functions (see scopeOf).
  var findings = newJArray()
  for r in results:
    if not r.ok:
      findings.add %*{
        "file": r.path, "line": 0, "code": "PARSE_ERROR",
        "severity": "error", "message": r.err}
      continue
    for d in r.diags:
      findings.add %*{
        "file": r.path, "line": d.line, "code": d.code,
        "severity": sevStr(d.sev), "message": d.msg}
  let c = totalCoverage(results)
  var frontierJson = newJArray()
  for f in c.trustedFrontier: frontierJson.add %f
  var pkgJson = newJArray()
  for p in c.contractPackages:
    var req = newJArray()
    for r in p.requires: req.add %*{"name": r.name, "value": r.value}
    var mm = newJArray()
    for m in p.mismatched: mm.add %m
    var uv = newJArray()
    for u in p.unverified: uv.add %u
    pkgJson.add %*{"name": p.name, "versionDeclared": p.version, "file": p.file,
                   "line": p.line, "requires": req, "mismatched": mm, "unverified": uv,
                   "appliesToThisBuild": (p.mismatched.len == 0 and p.unverified.len == 0)}
  var vouchJson = newJArray()
  for v in c.unsafeVouches: vouchJson.add %*{"function": v.fn, "line": v.line}
  var flowsJson = newJArray()
  for fl in c.flows:
    var bl = newJArray()
    for b in fl.blockers: bl.add %b
    flowsJson.add %*{"entry": fl.entry, "verified": fl.verified, "blockers": bl}
  let coverage = %*{
    "memoryFunctions": c.totalMem,
    "green": c.green,
    "verified": c.verified,
    "adopted": c.adopted,
    "red": c.red,
    "blocksAdopted": c.blocks,
    "coveragePct": (if c.totalMem > 0: int(c.verified.float / c.totalMem.float * 100 + 0.5) else: 0),
    "contractedPct": (if c.totalMem > 0: int(c.green.float / c.totalMem.float * 100 + 0.5) else: 0),
    "trustedFrontier": frontierJson,
    "contractPackages": pkgJson,
    "unsafeVouches": vouchJson,
    "flows": flowsJson}
  var scopeJson = newJArray()
  for r in results:
    if r.ok:
      var s = r.scope.copy
      s["file"] = %r.path
      scopeJson.add s
  echo (%*{"version": 1, "tool": "kenbi", "findings": findings,
           "coverage": coverage, "scope": scopeJson}).pretty

type DefVerdict = tuple[adopted, green, verified: bool, defs: int]
  ## Everything this run established about the implementations of ONE function NAME. `defs`
  ## counts them: a `static` name can be defined differently in several files, and a contract
  ## is declared on the name, so the published status must hold for every one of them.

proc contractStatus(c: ContractDecl, verdicts: Table[string, DefVerdict]): string =
  ## How much this run actually established about the implementation behind ONE contract.
  ## The whole point of publishing this next to the contract is that a consumer must not be
  ## able to read "a contract exists" as "the implementation was checked" — so the weaker
  ## states are named as plainly as the strong one:
  ##
  ##   declared   — no implementation in this run (a prototype, or a contract written from
  ##                outside for a library kenbi never compiled). NOTHING was verified.
  ##   unchecked  — the body is here but is not under `@kenbi`: kenbi did not check it.
  ##   red        — the body is under `@kenbi` and CONTRADICTS its contracts (or has another
  ##                RED finding). The contract is published, but do not rely on it.
  ##   green      — checked and clean, resting on trust: a contracted callee kenbi did not
  ##                cover, or an `@unsafe` the author vouched for.
  ##   verified   — checked and clean, and so is its whole contracted closure: no residue.
  ##
  ## Where a name has SEVERAL implementations (same-named `static`s in different files, a C++
  ## overload set under one by-name contract), the published status is the weakest of them:
  ## the contract is declared on the name, so it is only as good as the worst body behind it.
  ##
  ## A member contract is keyed `Class::method` while the definition carries the bare name,
  ## so the bare tail is the fallback lookup.
  if not c.hasBody: return "declared"
  var key = c.fn
  if key notin verdicts:
    let i = key.rfind("::")
    if i >= 0: key = key[i + 2 .. ^1]
  let v = verdicts.getOrDefault(key, (false, false, false, 0))
  if v.defs == 0: return "declared"     # nothing here defines it after all
  if not v.adopted: return "unchecked"
  if not v.green: return "red"
  if v.verified: return "verified"
  "green"

proc emitContracts(results: seq[FileResult]) =
  ## `--emit-contracts`: the contract surface of what was analysed, as a distributable
  ## document — the form a library publishes so a consumer (another checker, a binding
  ## generator, a different language's front-end) can hold the library to its contracts
  ## without re-reading its comments.
  ##
  ## Three parts, and the middle one is why the format exists:
  ##   * `packages` — whose contracts these are, the version DECLARED for them, and the build
  ##     conditions they were written against, already checked against this compile line.
  ##   * `resources` — the alloc -> free vocabulary: which calls hand out an obligation and
  ##     which discharge it. A consumer given only the deallocators cannot tell which call
  ##     obliged it in the first place.
  ##   * `contracts` — per function, the declared effects AND `status`: what this run actually
  ##     established about the implementation behind the contract (see contractStatus). An
  ##     annotation is not a proof, and a published contract that says nothing about its own
  ##     verification invites exactly that confusion.
  ##
  ## Emitted for whatever this invocation analysed: one overlay header, one library, or a
  ## whole project under `--project`, in which case `status` is the project-wide closure.
  let c = totalCoverage(results)
  # name -> what every implementation of it established, merged conservatively. The merge key
  # (`file::name` for a `static`) is how a definition is identified across files — two files
  # may each define a different `static f`, and a contract on `f` is only as good as both.
  var verdicts = initTable[string, DefVerdict]()
  for r in results:
    if not r.ok: continue
    for fn in r.unit.funcs:
      let key = (if fn.isStatic and fn.file.len > 0: fn.file & "::" & fn.name else: fn.name)
      if key notin r.unit.status: continue
      let st = r.unit.status[key]
      let one: DefVerdict = (st.adopted, st.adopted and st.green, key in c.verifiedFuncs, 1)
      if fn.name in verdicts:
        let have = verdicts[fn.name]
        verdicts[fn.name] = (have.adopted and one.adopted, have.green and one.green,
                             have.verified and one.verified, have.defs + 1)
      else: verdicts[fn.name] = one

  var pkgJson = newJArray()
  for p in c.contractPackages:
    var req = newJArray()
    for rq in p.requires: req.add %*{"name": rq.name, "value": rq.value}
    var mm = newJArray()
    for m in p.mismatched: mm.add %m
    var uv = newJArray()
    for u in p.unverified: uv.add %u
    pkgJson.add %*{"name": p.name, "versionDeclared": p.version, "file": p.file,
                   "line": p.line, "requires": req, "mismatched": mm, "unverified": uv,
                   "appliesToThisBuild": (p.mismatched.len == 0 and p.unverified.len == 0)}

  var deep = initHashSet[string]()
  for r in results:
    if r.ok: deep = deep + r.deepFrees
  var seenRes = initHashSet[string]()
  var resJson = newJArray()
  var resNames: seq[string]
  var resByName = initTable[string, Resource]()
  for r in results:
    if not r.ok: continue
    for rs in r.resources:
      if rs.name in seenRes: continue
      seenRes.incl rs.name
      resNames.add rs.name
      resByName[rs.name] = rs
  resNames.sort()
  for n in resNames:
    # NOTE: not named `res` — json's `%*` uses that identifier for its own accumulator.
    let rs = resByName[n]
    var alloc = newJArray()
    for a in rs.allocIds: alloc.add %a
    var realloc = newJArray()
    for a in rs.reallocIds: realloc.add %a
    var frees = newJArray()
    var deepFreeJson = newJArray()
    for f in rs.freeIds:
      frees.add %f
      if f in deep: deepFreeJson.add %f
    var nulling = newJArray()
    for f in rs.nullingFreeIds: nulling.add %f
    resJson.add %*{"name": rs.name, "alloc": alloc, "realloc": realloc, "free": frees,
                   "freeReturnsNull": nulling, "freesFields": deepFreeJson,
                   "link": rs.linkId, "owner": rs.ownerId, "declLine": rs.declLine}

  var seenC = initHashSet[string]()
  var merged: seq[ContractDecl]
  for r in results:
    if not r.ok: continue
    for cd in r.contracts:
      let key = cd.fn & "|" & cd.effect & "|" & cd.param
      if key in seenC:
        # the same contract reached from several TUs: seeing the BODY in any one of them is
        # what decides whether anything could have been verified
        if cd.hasBody:
          for m in merged.mitems:
            if m.fn == cd.fn and m.effect == cd.effect and m.param == cd.param:
              m.hasBody = true; m.file = cd.file; m.line = cd.line
        continue
      seenC.incl key
      merged.add cd
  merged.sort(proc (x, y: ContractDecl): int =
    result = cmp(x.fn, y.fn)
    if result == 0: result = cmp(x.effect, y.effect)
    if result == 0: result = cmp(x.param, y.param))
  var cJson = newJArray()
  for cd in merged:
    cJson.add %*{"function": cd.fn, "effect": cd.effect, "param": cd.param,
                 "file": cd.file, "line": cd.line,
                 "implementationSeen": cd.hasBody,
                 "declaredBy": (if cd.viaOverlay: "overlay" else: "inline"),
                 "status": contractStatus(cd, verdicts)}

  echo (%*{"version": 1, "tool": "kenbi", "kind": "contract-set",
           "packages": pkgJson, "resources": resJson, "contracts": cJson}).pretty

proc isStrippable(p: string): bool =
  ## Source and header files strip touches when recursing a directory. Annotations
  ## live in both .c/.cpp and their headers, so headers are included.
  let l = p.toLowerAscii
  isCSource(p) or l.endsWith(".h") or l.endsWith(".hpp") or
  l.endsWith(".hh") or l.endsWith(".hxx")

proc stripMain() =
  ## `kenbi strip [--dry-run] [--stdout] [--recursive] <file|dir> ...`
  ## Remove kenbi `@`-directive comments so an upstream diff carries only the code
  ## change. In place by default; --stdout prints instead (no file written);
  ## --dry-run reports counts without modifying; --recursive walks directories.
  var inputs: seq[string]
  var dryRun, toStdout, recursive = false
  for idx in 2 .. paramCount():
    let a = paramStr(idx)
    case a
    of "--dry-run", "-n": dryRun = true
    of "--stdout": toStdout = true
    of "--recursive", "-r": recursive = true
    else:
      if a.startsWith("-"):
        stderr.writeLine "kenbi strip: unknown option '" & a & "'"
        quit(2)
      inputs.add a
  if inputs.len == 0:
    stderr.writeLine "usage: kenbi strip [--dry-run] [--stdout] [--recursive] <file|dir> ..."
    quit(2)

  var files: seq[string]
  for inp in inputs:
    if dirExists(inp):
      if not recursive:
        stderr.writeLine "kenbi strip: '" & inp & "' is a directory (use --recursive)"
        quit(2)
      for path in walkDirRec(inp):
        if isStrippable(path): files.add path
    elif fileExists(inp):
      files.add inp
    else:
      stderr.writeLine "kenbi strip: cannot find '" & inp & "'"
      quit(2)
  files.sort()

  if toStdout and files.len != 1:
    stderr.writeLine "kenbi strip: --stdout requires exactly one file"
    quit(2)

  let directives = allKenbiDirectives()
  var totalRemoved, changedFiles = 0
  for f in files:
    let src = readFile(f)
    let (outp, removed) = stripAnnotations(src, directives)
    totalRemoved += removed
    if toStdout:
      stdout.write outp
      continue
    if removed > 0:
      inc changedFiles
      if dryRun:
        echo f, ": ", removed, " annotation(s) would be removed"
      else:
        writeFile(f, outp)
        echo f, ": removed ", removed, " annotation(s)"
  if not toStdout:
    let verb = (if dryRun: "would remove" else: "removed")
    echo "── kenbi strip: ", verb, " ", totalRemoved, " annotation(s) in ",
         changedFiles, " of ", files.len, " file(s)"

const kenbiVersion = block:
  ## The package version, read from kenbi.nimble at compile time so the two cannot disagree.
  var v = ""
  for line in staticRead("../kenbi.nimble").splitLines:
    let l = line.strip
    if l.startsWith("version") and '"' in l:
      v = l.split('"')[1]
      break
  doAssert v.len > 0, "kenbi.nimble declares no version"
  v

proc main() =
  if paramCount() >= 1 and paramStr(1) == "strip":
    stripMain()
    return
  if paramCount() == 1 and paramStr(1) == "--version":
    # The libclang that was loaded decides what C/C++ kenbi can parse, so it is part of the answer.
    echo "kenbi ", kenbiVersion, " (", $clang_getClangVersion(), ")"
    return
  var files: seq[string]
  var extra: seq[string]
  var dbOverride = ""
  var projectMode = false
  var projectDb = ""
  var format = fmtText
  var afterDD = false
  var dumpIrMode = false
  var emitMode = false
  var safetyPath = ""
  var safetyRequested = false
  var safetyArgError = false
  for idx in 1 .. paramCount():
    let a = paramStr(idx)
    if afterDD: extra.add a
    elif a == "--": afterDD = true
    elif a.startsWith("--format="):
      case a["--format=".len .. ^1]
      of "text": format = fmtText
      of "json": format = fmtJson
      else:
        stderr.writeLine "kenbi: unknown --format (use text|json)"
        quit(2)
    elif a.startsWith("--compile-commands="): dbOverride = a["--compile-commands=".len .. ^1]
    elif a == "--project": projectMode = true
    elif a.startsWith("--project="): projectMode = true; projectDb = a["--project=".len .. ^1]
    elif a == "--dump-ir": dumpIrMode = true
    elif a == "--emit-contracts": emitMode = true
    elif a.startsWith("--safety="):
      if safetyRequested: safetyArgError = true
      safetyRequested = true
      safetyPath = a["--safety=".len .. ^1]
      if safetyPath.len == 0: safetyArgError = true
    elif a.startsWith("-"): extra.add a
    else: files.add a
  if safetyRequested:
    if safetyArgError or files.len > 0 or extra.len > 0 or dbOverride.len > 0 or projectMode or dumpIrMode or emitMode:
      if format == fmtJson:
        echo (%*{"schemaVersion": 1, "kind": "safety-result", "phase": "source", "status": "unverified", "accepted": false,
          "findings": [{"code": "SAFETY_INPUT_ERROR", "message":
          "provide exactly one nonempty --safety=PATH, using sources and clangArgs from that project"}]}).pretty
      else:
        stderr.writeLine "kenbi: --safety cannot be combined with other input modes"
      quit(2)
    quit(safetyMain(safetyPath, format == fmtJson))
  # `--project[=compile_commands.json]`: analyse every translation unit the database lists, so
  # the ownership closure spans the project — a contracted call into another unit resolves to
  # that unit's verdict instead of sitting on the trusted frontier. With no path, the database
  # is found by walking up from the first file given (or the working directory).
  if projectMode:
    if projectDb.len == 0:
      projectDb = (if dbOverride.len > 0: dbOverride
                   else: findCompileDb(if files.len > 0: files[0] else: getCurrentDir() / "x"))
    if projectDb.len == 0 or not fileExists(projectDb):
      stderr.writeLine "kenbi: --project needs a compile_commands.json (none found)"
      quit(2)
    if dbOverride.len == 0: dbOverride = projectDb
    let units = filesIn(projectDb)
    if units.len == 0:
      stderr.writeLine "kenbi: " & projectDb & " lists no source files"
      quit(2)
    files = units
  if files.len == 0:
    stderr.writeLine "usage: kenbi [--format=text|json] [--compile-commands=PATH] " &
                     "[--project[=PATH]] [--emit-contracts] <file> [more...] [-- <clang args>]"
    stderr.writeLine "       kenbi [--format=text|json] --safety=project.json"
    stderr.writeLine "       kenbi --version"
    quit(2)

  if dumpIrMode:
    for f in files: dumpIr(f, dbOverride, extra)
    return
  var results: seq[FileResult]
  for f in files:
    results.add analyzeOne(f, dbOverride, extra)

  # Publishing the contract set is not a check: it reports what was declared and what this run
  # established about it, and says nothing about whether the code is clean. So it prints the
  # document and exits 0 even when there are findings — the findings are `kenbi`'s own job,
  # asked for separately.
  if emitMode:
    emitContracts(results)
    for r in results:
      if not r.ok:
        stderr.writeLine r.path & ": " & r.err
        quit(2)
    return

  case format
  of fmtText: renderText(results)
  of fmtJson: renderJson(results)

  var issues = 0
  var hadError = false
  for r in results:
    if not r.ok: hadError = true
    else:
      # advisory findings are for the review layer; they never gate the build.
      for d in r.diags:
        if d.sev != sevAdvisory: inc issues
  if hadError: quit(2)
  if issues > 0: quit(1)

main()
