## `kenbi strip` — remove kenbi annotation comments from C/C++ source.
##
## Purpose: before kenbi is public, ship an upstream fix WITHOUT leaking the
## annotation vocabulary — strip the `@`-directive comments and leave only the
## real code change. The stripper recognises exactly what the front-end does: a
## comment whose FIRST body token is a known directive keyword (`allKenbiDirectives`),
## reusing `commentBody` so recognition is identical to `scanCommentTokens` (the
## same `//`/`/* */`-only, `@`-first-token rule). Prose comments and test markers
## (`//EXPECT` / `//COV`) are untouched — they are never annotations.
##
## Removal is deterministic and layout-preserving:
##   * a directive comment ALONE on its line(s) -> the whole line(s) are removed;
##   * a TRAILING directive comment (`code(); // @unsafe`) -> only the comment (and
##     the whitespace before it) is removed, the code and its newline stay;
##   * an INLINE block (`f(/* @borrows(p) */ x)`) -> only the comment span is cut.
## String and char literals are skipped so a `//` or `/*` inside `"..."` / `'...'`
## is never mistaken for a comment. (C++ raw strings `R"(...)"` are a documented
## residual — not handled; kenbi corpora do not use them around annotations.)

import std/[sets, strutils]
import cfront_core   # commentBody — identical body extraction to the front-end

type Comment = object
  s, e: int          ## byte span [s, e): s at the `/`, e one past the comment
  line: bool         ## true = `//` line comment, false = `/* */` block

proc lexComments(src: string): seq[Comment] =
  ## Find every comment span, skipping string / char literals so their contents
  ## are never scanned for comment openers.
  let n = src.len
  var i = 0
  while i < n:
    let c = src[i]
    if c == '"' or c == '\'':
      let quote = c
      inc i
      while i < n:
        if src[i] == '\\': i += 2; continue          # escape: skip the next char
        if src[i] == quote: inc i; break
        inc i
    elif c == '/' and i + 1 < n and src[i+1] == '/':
      let s = i
      i += 2
      while i < n and src[i] != '\n': inc i           # to end of line (e at '\n' or n)
      result.add Comment(s: s, e: i, line: true)
    elif c == '/' and i + 1 < n and src[i+1] == '*':
      let s = i
      i += 2
      var closed = false
      while i + 1 < n:
        if src[i] == '*' and src[i+1] == '/': i += 2; closed = true; break
        inc i
      if not closed: i = n                            # unterminated block -> to EOF
      result.add Comment(s: s, e: i, line: false)
    else:
      inc i

proc firstKeyword(span: string): string =
  ## The directive keyword candidate = the first whitespace token of the comment
  ## body, minus any `(args)` — exactly the front-end's `words[0].split('(')[0]`.
  let body = commentBody(span)
  let words = body.splitWhitespace()
  if words.len == 0: return ""
  words[0].split('(')[0]

func isBlank(src: string, lo, hi: int): bool =
  ## Every char in [lo, hi) is a space or tab.
  for k in lo ..< hi:
    if src[k] notin {' ', '\t'}: return false
  true

proc removalRange(src: string, cm: Comment): tuple[a, b: int] =
  ## The byte range [a, b) to delete for a directive comment, per the layout rules.
  let n = src.len
  var ls = cm.s                                   # start of the comment's first line
  while ls > 0 and src[ls-1] != '\n': dec ls
  let prefixBlank = isBlank(src, ls, cm.s)
  if cm.line:
    if prefixBlank:                               # whole-line comment -> drop the line
      let b = (if cm.e < n and src[cm.e] == '\n': cm.e + 1 else: cm.e)
      return (ls, b)
    var a = cm.s                                  # trailing -> trim ws before it, keep newline
    while a > ls and src[a-1] in {' ', '\t'}: dec a
    return (a, cm.e)
  else:
    var le = cm.e                                 # end of the comment's last line
    while le < n and src[le] != '\n': inc le
    let suffixBlank = isBlank(src, cm.e, le)
    if prefixBlank and suffixBlank:               # block alone on its line(s) -> drop them
      let b = (if le < n: le + 1 else: le)
      return (ls, b)
    if suffixBlank:                               # code then block-to-EOL -> trailing block
      var a = cm.s
      while a > ls and src[a-1] in {' ', '\t'}: dec a
      return (a, le)
    var b = cm.e                                  # inline block -> cut the span, and if it
    if cm.s > 0 and src[cm.s-1] in {' ', '\t'} and # sat between two spaces, collapse them to one
       cm.e < n and src[cm.e] in {' ', '\t'}: inc b
    return (cm.s, b)

proc stripAnnotations*(src: string, directives: HashSet[string]): tuple[output: string, removed: int] =
  ## Return `src` with every kenbi-directive comment removed, and how many were
  ## removed. Pure and deterministic: same input -> same output.
  var edits: seq[tuple[a, b: int]]
  for cm in lexComments(src):
    if firstKeyword(src[cm.s ..< cm.e]) in directives:
      edits.add removalRange(src, cm)
  result.removed = edits.len
  if edits.len == 0:
    result.output = src
    return
  var outp = newStringOfCap(src.len)
  var pos = 0
  for ed in edits:                                # spans are in source order, non-overlapping
    if ed.a > pos: outp.add src[pos ..< ed.a]
    pos = ed.b
  if pos < src.len: outp.add src[pos ..< src.len]
  result.output = outp
