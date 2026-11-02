## Test runner: for each *.mc file, compare the multiset of diagnostic codes
## the analyzer produces against the `#EXPECT <CODE>` lines in the file.
## A file with no #EXPECT lines is expected to be clean.

import std/[os, strutils, tables, algorithm]
import "../src/parse", "../src/analyze"

proc expectedCodes(src: string): seq[string] =
  for line in src.splitLines():
    let s = line.strip()
    if s.startsWith("#EXPECT"):
      let parts = s.splitWhitespace()
      if parts.len >= 2: result.add parts[1]

proc producedCodes(src: string): seq[string] =
  for d in analyze(parseProgram(src)): result.add d.code

proc multisetEq(a, b: seq[string]): bool =
  var ta, tb: CountTable[string]
  for x in a: ta.inc x
  for x in b: tb.inc x
  ta == tb

let testsDir = currentSourcePath().parentDir()
var ran, failed = 0
var names: seq[string]
for _, path in walkDir(testsDir):
  if path.endsWith(".mc"): names.add path
names.sort()

for path in names:
  inc ran
  let src = readFile(path)
  let exp = expectedCodes(src)
  let got = producedCodes(src)
  if multisetEq(exp, got):
    echo "PASS  ", extractFilename(path)
  else:
    inc failed
    echo "FAIL  ", extractFilename(path)
    echo "  expected: ", exp.sorted()
    echo "  got:      ", got.sorted()

echo "---"
echo ran - failed, "/", ran, " passed"
if failed > 0: quit(1)
