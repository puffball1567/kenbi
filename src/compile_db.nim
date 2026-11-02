## compile_commands.json ingestion (Phase 1).
##
## Real libraries need their include paths / -D / -std to parse. Given a source
## file, find the matching entry in a compilation database and return the flags
## that affect parsing (include dirs, macros, standard, sysroot). The compiler
## name, -o/-c, and the source file itself are dropped — libclang supplies those.

import std/[json, os, strutils, sets]

const parseFlagPrefixes = ["-I", "-D", "-U", "-isystem", "-include",
                           "-std=", "-f", "-iquote", "-idirafter", "--sysroot=",
                           "-nostdinc", "-m", "-W"]

proc wanted(arg: string): bool =
  for p in parseFlagPrefixes:
    if arg.startsWith(p): return true
  false

proc splitCommand(cmd: string): seq[string] =
  ## Tokenize a `command` string with shell-like quoting: single quotes (literal),
  ## double quotes, and backslash escapes outside single quotes. This is only the
  ## fallback for compile DBs that lack the structured `arguments` array; prefer
  ## `arguments` when present (argsForFile does).
  var cur = ""
  var started = false   # distinguishes an empty quoted arg ("") from no arg
  var inS, inD = false  # inside single / double quotes
  var i = 0
  while i < cmd.len:
    let ch = cmd[i]
    if ch == '\\' and not inS and i+1 < cmd.len:
      cur.add cmd[i+1]; started = true; inc i, 2; continue
    elif ch == '\'' and not inD: inS = not inS; started = true
    elif ch == '"' and not inS: inD = not inD; started = true
    elif ch in {' ', '\t'} and not inS and not inD:
      if started: result.add cur; cur = ""; started = false
    else: cur.add ch; started = true
    inc i
  if started: result.add cur

proc argsForFile*(dbPath, srcFile: string): seq[string] =
  ## Parse-affecting flags for `srcFile` from the compile DB at `dbPath`.
  ## Returns @[] if the DB is missing or has no entry for the file.
  if not fileExists(dbPath): return @[]
  let db =
    try: parseJson(readFile(dbPath))
    except JsonParsingError: return @[]
  if db.kind != JArray: return @[]
  let target = absolutePath(srcFile)
  for entry in db:
    if entry.kind != JObject or "file" notin entry: continue
    let dir = (if "directory" in entry: entry["directory"].getStr else: "")
    let efile = entry["file"].getStr
    let abs = (if efile.isAbsolute: efile else: dir / efile)
    if absolutePath(abs) != target and efile != srcFile: continue
    var toks: seq[string]
    if "arguments" in entry and entry["arguments"].kind == JArray:
      for a in entry["arguments"]: toks.add a.getStr
    elif "command" in entry:
      toks = splitCommand(entry["command"].getStr)
    var i = 0
    while i < toks.len:
      let t = toks[i]
      if t in ["-I", "-isystem", "-include", "-iquote", "-idirafter"]:
        result.add t
        if i+1 < toks.len: inc i; result.add toks[i]
      elif wanted(t):
        result.add t
      inc i
    return result
  @[]

proc filesIn*(dbPath: string): seq[string] =
  ## Every source file a compile database lists, absolute and deduplicated, in the order the
  ## database gives them. This is what `kenbi --project <compile_commands.json>` analyses: the
  ## whole translation-unit set, so the ownership closure can be computed across it rather
  ## than stopping at each file. Headers are not listed by a compile DB — they are analysed
  ## as part of the units that include them.
  if not fileExists(dbPath): return @[]
  let db =
    try: parseJson(readFile(dbPath))
    except JsonParsingError: return @[]
  if db.kind != JArray: return @[]
  var seen = initHashSet[string]()
  for entry in db:
    if entry.kind != JObject or "file" notin entry: continue
    let dir = (if "directory" in entry: entry["directory"].getStr else: "")
    let efile = entry["file"].getStr
    let abs = absolutePath(if efile.isAbsolute: efile else: dir / efile)
    if abs in seen: continue
    seen.incl abs
    result.add abs

proc findCompileDb*(srcFile: string): string =
  ## Walk up from the source file looking for compile_commands.json.
  var dir = absolutePath(srcFile).parentDir
  while true:
    let cand = dir / "compile_commands.json"
    if fileExists(cand): return cand
    let parent = dir.parentDir
    if parent == dir: break
    dir = parent
  ""
