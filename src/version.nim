## kenbi's version, read from kenbi.nimble at compile time so every place that reports it agrees
## with the package.
import std/strutils

const kenbiVersion* = block:
  var v = ""
  for line in staticRead("../kenbi.nimble").splitLines:
    let l = line.strip
    if l.startsWith("version") and '"' in l:
      v = l.split('"')[1]
      break
  doAssert v.len > 0, "kenbi.nimble declares no version"
  v
