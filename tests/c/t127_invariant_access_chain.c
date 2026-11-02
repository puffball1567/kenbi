// @spatial
// INVARIANT slice 5 — the access payoff (the FIRST green). Once a protected field is
// established (slice 4) and every write to it is guarded/maintained (slices 2-3), the
// invariant `field REL size` is trustworthy, so the spatial pass may CHAIN through it at
// an index sink: a value bounded by the protected field is, transitively, bounded by the
// field's size. `pos < count` ∧ `count <= cap` ∧ `@counted_by(toks: cap)` ⟹ `pos < cap`,
// greening `toks[pos]`. This is the jsmn `i < toknext <= num_tokens` shape (single
// function here; cross-function carry is slice 6).
#include <stddef.h>

struct Tok { int v; };
struct Parser { unsigned int count; };

// The chain greens an access bounded by the protected field.
// @counted_by(toks: cap)
// @invariant(p->count <= cap)
void fill(struct Parser *p, struct Tok *toks, unsigned int cap, unsigned int pos) {
  p->count = 0;                 // @maintains(p->count <= cap)
  if (pos < p->count) {
    toks[pos].v = 2;            // pos < count <= cap, toks sized cap — CHAINED green
  }
  if (p->count >= cap) {
    return;
  }
  toks[p->count].v = 1;         // count < cap (local guard), toks sized cap — DIRECT green
  p->count++;                   // @maintains(p->count <= cap)
}

// Without an @invariant relating `count` to the buffer's size, the same access cannot be
// chained — kenbi cannot relate `count` to `cap`, so it stays red (no blanket pass).
struct Plain { unsigned int count; };
// @counted_by(toks: cap)
void fill_no_invariant(struct Plain *p, struct Tok *toks, unsigned int cap, unsigned int pos) {
  if (pos < p->count) {
    toks[pos].v = 2;           //EXPECT UNVALIDATED_INDEX
  }
}
