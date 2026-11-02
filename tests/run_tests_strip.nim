## Tests for `kenbi strip` (src/strip.nim): removing kenbi `@`-directive comments
## while leaving code, prose comments, string literals and test markers intact.
## Each case is (name, input, expected-output, expected-removed-count), checked
## against the REAL directive vocabulary (allKenbiDirectives) so the test tracks
## what the front-end actually recognises.

import std/[strutils, sets]
import "../src/strip", "../src/cfront_annotations"

let dirs = allKenbiDirectives()

type Case = tuple[name, input, want: string, removed: int]

const cases: seq[Case] = @[
  ("whole-line //",
   "int a;\n// @kenbi\nint b;\n",
   "int a;\nint b;\n", 1),
  ("indented whole-line // dropped with indent",
   "  // @frees(p)\n  free(p);\n",
   "  free(p);\n", 1),
  ("trailing // keeps code + newline",
   "void rel(char *o) {   // @unsafe note\n  free(o);\n}\n",
   "void rel(char *o) {\n  free(o);\n}\n", 1),
  ("whole-line block /* */",
   "/* @counted_by(buf: len) */\nint sum(int *buf, int len);\n",
   "int sum(int *buf, int len);\n", 1),
  ("inline block cut in place",
   "int x = f(/* @borrows(p) */ p);\n",
   "int x = f( p);\n", 1),
  ("trailing block to EOL",
   "int y = 1;  /* @invariant(y <= n) */\n",
   "int y = 1;\n", 1),
  ("string with // is untouched",
   "const char *u = \"http://x//y\";\n// @spatial\n",
   "const char *u = \"http://x//y\";\n", 1),
  ("string with /* is untouched",
   "const char *u = \"/* not a comment */\"; // @unsafe\n",
   "const char *u = \"/* not a comment */\";\n", 1),
  ("char literal with quote escape",
   "char c = '\\\"'; // @unsafe\nint z;\n",
   "char c = '\\\"';\nint z;\n", 1),
  ("prose comment kept, directive removed",
   "// this frees p\n// @frees(p)\nvoid rel(char*p);\n",
   "// this frees p\nvoid rel(char*p);\n", 1),
  ("test markers //EXPECT //COV kept (not @)",
   "int a;   //EXPECT LEAK\n//COV green=1\n// @kenbi\n",
   "int a;   //EXPECT LEAK\n//COV green=1\n", 1),
  ("prose that merely mentions @copy is not a directive",
   "// use @copy here when needed\nint a;\n",
   "// use @copy here when needed\nint a;\n", 0),
  ("multiple directives, mixed",
   "// @threadsafe\nstruct S { int d; /* @guarded_by(lk) */ };\nvoid f(){} // @llm review\n",
   "struct S { int d; };\nvoid f(){}\n", 3),
  ("multi-line block whole removal",
   "/* @arena R {\n   create: c, alloc: a, free: fr\n} */\nint main();\n",
   "int main();\n", 1),
  ("no trailing newline, whole-line directive at EOF",
   "int a;\n// @kenbi",
   "int a;\n", 1),
  ("no directives -> unchanged, zero removed",
   "int a; // plain\n/* block */\n",
   "int a; // plain\n/* block */\n", 0),
]

var ran, failed = 0
for c in cases:
  inc ran
  let (outp, removed) = stripAnnotations(c.input, dirs)
  # idempotence: stripping the output again removes nothing and changes nothing.
  let (outp2, removed2) = stripAnnotations(outp, dirs)
  if outp == c.want and removed == c.removed and outp2 == outp and removed2 == 0:
    echo "PASS  ", c.name
  else:
    inc failed
    echo "FAIL  ", c.name
    if outp != c.want:
      echo "  want: ", c.want.escape
      echo "  got:  ", outp.escape
    if removed != c.removed:
      echo "  removed: want ", c.removed, " got ", removed
    if outp2 != outp or removed2 != 0:
      echo "  not idempotent: 2nd pass removed ", removed2

# Spot-check the vocabulary covers all five axes + ownership contracts.
for kw in ["@kenbi", "@spatial", "@threadsafe", "@initcheck", "@typecheck",
           "@frees", "@owns", "@borrows", "@arena", "@counted_by", "@invariant",
           "@variant", "@guarded_by", "@lock_class", "@calls", "@nullable",
           "@must_use", "@unsafe", "@lock_order", "@drains", "@list", "@contract"]:
  inc ran
  if kw in dirs: echo "PASS  vocab has ", kw
  else:
    inc failed
    echo "FAIL  vocab missing ", kw

echo "---"
echo ran - failed, "/", ran, " passed"
if failed > 0: quit(1)
