// @spatial
// INVARIANT slice 6 — multi-hop chaining across INTERLOCKING invariants, and the
// interprocedural CARRY. Real data structures relate a cursor to a size through several
// fields: jsmn's `toksuper < toknext <= num_tokens`. A size operand may itself be a
// protected field, so the spatial pass chains TRANSITIVELY: `j < sub` ∧ `sub < count` ∧
// `count <= cap` ⟹ `j < cap`. The invariants here are ASSUMED on entry (no establishing
// write in this function — that is done by whichever function initialises the struct; the
// invariant is carried across the boundary as a declared precondition, exactly as
// @counted_by trusts the caller's buffer size). Each link is still made trustworthy by the
// write-barrier / maintains / establish legs wherever the field IS written.
#include <stddef.h>

struct Tok { int v; };
struct Parser { unsigned int sub; unsigned int count; };

// Two interlocking invariants chain through to the buffer's size.
// @counted_by(toks: cap)
// @invariant(p->sub < p->count)
// @invariant(p->count <= cap)
void use(struct Parser *p, struct Tok *toks, unsigned int cap, unsigned int j) {
  if (j < p->sub) {
    toks[j].v = 1;             // j < sub < count <= cap — CHAINED (multi-hop) green
  }
  if (p->sub < p->count) {
    toks[p->sub].v = 2;        // sub < count <= cap — green (guard + one chain hop)
  }
}

// The middle link is NOT declared, so `j < sub` cannot reach `cap` — the chain breaks and
// the access stays red (no transitive pass without every link).
struct Plain { int sub; unsigned int count; };
// @counted_by(toks: cap)
// @invariant(p->count <= cap)
void use_broken_chain(struct Plain *p, struct Tok *toks, unsigned int cap, int j) {
  if (j < p->sub) {
    toks[j].v = 1;            //EXPECT UNVALIDATED_INDEX
  }
}
