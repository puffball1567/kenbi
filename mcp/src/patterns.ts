// kenbi-verified safe patterns, served as the `kenbi://patterns` resource. AI-grounding
// knowledge for an agent that writes or fixes C/C++ and self-verifies with the
// `check_memory_safety` tool: a curated intro (the golden rule + the spatial deep-dive that
// teaches nuance no single snippet carries) followed by the "Complete intent-indexed coverage" section —
// the safe (state C) shape for every finding kenbi emits, grouped by axis.
//
// Trust model: this is advisory grounding, never a trust path. The deterministic checker stays
// the sole judge — an agent writes to these shapes, runs check_memory_safety, and fixes until
// clean, so a pattern can only ever HELP the first draft; it cannot make the checker accept
// wrong code. The "Complete intent-indexed coverage" section is GENERATED and cannot show wrong code: it
// is imported from ./generated/catalogue.ts, produced by demo/gen_mcp_from_corpus.py from the
// single three-state corpus (demo/juliet/ + manifest.json), and demo/verify_three_state.py fails
// if it drifts from the verified files. The surrounding prose is advisory teaching.

import { CATALOGUE } from "./generated/catalogue.js";

export const PATTERNS = `# kenbi-verified safe patterns (C/C++), by intent

Grounding for writing or fixing C/C++ and verifying with \`check_memory_safety\`.
Indexed by what you are trying to DO (the intent); the finding it prevents and the CWE
are secondary tags. Each entry shows the SAFE shape kenbi declares GREEN; for the full
A→B→C contrast of any finding you hit, call \`explain_finding\` with its code. Annotations
are verified, not trusted: the body must match the declared intent. See
\`kenbi://annotations\` for the full directive reference.

The golden rule: **every heap resource is declared with \`@mem\` and freed exactly
once along every path; every call that takes a pointer declares what it does with it
(\`@frees\` / \`@borrows\` / \`@moves\`).** A pointer kenbi cannot account for is RED.

The three states an agent moves through: **A** "don't write it this way" (unannotated
→ RED), **B** "you can't annotate your way out" (honest annotation, bug still RED), **C**
"write it like this" (the GREEN shapes below).

---

The golden rule covers the ownership / lifetime intents; the intent-indexed catalogue below has
the safe shape for each. What follows first is the one axis with real nuance beyond a single
snippet — the **bounds** axis — then the full catalogue.

## Intent: bound an untrusted value before indexing a buffer  [CWE-125/787, SPATIAL]

A separate **bounds** axis — opt in with \`// @spatial\` (independent of \`@kenbi\`). A
runtime bound check must be PRESENT *and APPROPRIATE* before an untrusted scalar (a
parameter / external input) reaches an array subscript or a buffer length: the bound
has to actually cover the buffer's size, not merely exist. kenbi checks the bound is
present and sufficient; it never proves a check unnecessary in order to remove it, so a
check that is there must stay there.

SAFE — GREEN:
\`\`\`c
// @spatial
extern int table[256];
void write_at(int idx) {
  if (idx < 256) table[idx] = 0;   // runtime bound present -> validated
}
void write_at_early(int idx) {
  if (idx >= 256) return;          // reject out-of-range, fall through validated
  table[idx] = 0;
}
\`\`\`
Prevents **UNVALIDATED_INDEX** — \`void write_at(int idx) { table[idx] = 0; }\` lets an
untrusted parameter index the buffer with no check on the path. A loop condition
(\`for (i=0;i<n;i++) a[i]\`), a \`% n\`, a clamp or a mask count as the present bound too.

The same axis covers buffer **lengths**: an untrusted size passed to \`memcpy\` /
\`memmove\` / \`memset\` / \`strncpy\` / \`strncat\` / \`snprintf\` / \`read\` / \`recv\` with no
bound present is **UNVALIDATED_SIZE** (the classic overflow, CWE-120/787). kenbi
**follows the scalar value** through local copies and field reads, so it is caught even
when the parameter is not used directly:
\`\`\`c
// @spatial
void copy_in(char *dst, const char *src, int len) {
  int n = len;                     // taint follows the copy
  if (n <= 64) memcpy(dst, src, n);   // bounded -> GREEN; without the check -> UNVALIDATED_SIZE
}
\`\`\`
And the bound must be **appropriate**: a check that is present but too loose —
\`if (len <= 1000) memcpy(buf64, src, len);\` — does not cover the 64-byte buffer, so it
is **INAPPROPRIATE_BOUND**, not GREEN. kenbi compares the bound against a fixed-size
buffer's size (a constant comparison / size-identity match, not range arithmetic), so
GREEN means "a bound check is present and covers the buffer".

The buffer's size can be a **runtime value**, not just a fixed array — the everyday
parser / decoder shape. A buffer allocated \`malloc(n)\` / \`calloc(n, ..)\` /
\`malloc(n * sizeof T)\` is covered by a bound that names the **same identifier**: kenbi
matches by IDENTITY (no range arithmetic), so \`idx < n\` or \`for (i=0;i<n;i++)\` validates
an index into a buffer of \`n\`:
\`\`\`c
// @spatial
int read_at(int n, int idx) {
  int *buf = malloc(n * sizeof(int));   // @mem ...
  if (idx < n) return buf[idx];         // bound names buf's own count -> GREEN
  return 0;                             // idx <= n would be INAPPROPRIATE_BOUND (off-by-one)
}
\`\`\`
An INDEX must be STRICTLY \`< n\`; a LENGTH may be \`<= n\`. A bound naming a *different*
variable, or a *constant* bound on a variable-size buffer, cannot be related to the
buffer and stays **UNVALIDATED_INDEX** / **UNVALIDATED_SIZE** — bind it by the buffer's
own allocation count.

The guards may be **compound**, and the access may carry an **offset**. kenbi reads a
\`&&\` conjunction (\`if (i >= 0 && i < n)\` — the \`i < n\` conjunct validates), a variable
bound with \`± k\` (the look-ahead \`if (pos + 4 <= len)\` bounds \`pos\` so \`pos..pos+3\` are
in a \`len\`-sized buffer), and a neighbour access \`buf[i + k]\` (whose bound must cover
\`i + k\`, not just \`i\` — \`if (i < n) buf[i+1]\` is INAPPROPRIATE_BOUND, since \`i+1\` can
reach \`n\`). A compound index/length is a real sink: \`buf[i+1]\` / \`memcpy(d,s,len-1)\`
with no covering bound is UNVALIDATED, not silently accepted.

The reject form \`if (i < 0 || i >= n) return;\` validates the fall-through (the \`||\`
guard's negation gives \`i < n\`). And a fixed-size array **member** is a buffer too:
\`s->buf[i]\` / \`memcpy(s->buf, src, len)\` are checked against the member's size, like a
plain array — the everyday struct-indexing shape in parsers and protocol code. A field
READ used as an index/length (\`buf[s->idx]\`, \`memcpy(d, s, h->len)\`) is an untrusted
value too — a guard on the same field validates it.

The most common buffer in C is a **(ptr, len) parameter pair** — a pointer/array
parameter sized by another parameter (\`parse(js, len)\`, \`read(fd, buf, n)\`). kenbi cannot
relate them on its own (a bare pointer has no size), so declare it:
\`\`\`c
// @spatial
// @counted_by(js: len)
int scan(const char *js, size_t len) {
  for (size_t i = 0; i < len; i++) { use(js[i]); }   // i < len, js sized len -> GREEN
}
\`\`\`
\`@counted_by(buf: size)\` names, per function, which pointer parameter is sized by which
length parameter; then a bound on the size parameter covers the buffer. It is a
declaration, not a blanket pass — an unguarded \`js[i]\` is still UNVALIDATED. Bounds CHAIN
transitively: \`tokens[i]\` with \`i < count\` is GREEN when \`count\` itself has a validated
runtime bound to the buffer's size (\`if (count <= cap) …\`) — kenbi composes \`i < count <=
cap\`. A bound that holds only by a CROSS-CODE invariant (not a local check on this path)
still needs a declared \`@invariant\`, or bound it locally / mark the access \`@unsafe\`.

---

${CATALOGUE}
---

Workflow: write to the safe shape, run \`check_memory_safety\`, fix until kenbi reports no findings. A
finding names WHAT it cannot verify, WHY (default-red discipline), and HOW to resolve
it (which contract to declare, or rewrite). When it reports a finding, call the
\`explain_finding\` tool with the finding code for the full A→B→C worked example. GREEN
means the code is provably correct for the classes kenbi covers across its axes —
ownership/lifetime, spatial bounds, initialisation, type confusion, and lock discipline
(see the intent-indexed catalogue above). The class coverage is generated from the single
three-state corpus (\`demo/juliet/\` + \`manifest.json\`), which \`demo/verify_three_state.py\`
checks — every shape is a verified file, and a drift fails the check.`;
