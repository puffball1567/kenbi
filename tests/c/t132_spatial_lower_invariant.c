// @spatial
// SPATIAL lower-bound INVARIANTS (C2): a signed field used as a sentinel (-1 or a valid
// index) is bounded BELOW by a DECLARED data-structure invariant `@invariant(field >= c)`,
// symmetric to the upper `@invariant(field < size)`. A `!= -1` guard lifts the known
// `>= -1` to `>= 0` at the access (a `!= c` guard raises a known `>= c` to `>= c+1`). kenbi
// verifies every write preserves the lower invariant — a write it cannot show preserves it
// is INVARIANT_NOT_MAINTAINED. A field may carry BOTH an upper and a lower invariant; one
// `@maintains` checks every invariant on the field.
#include <stddef.h>

typedef struct { int cur; unsigned int n; } box;
extern int g[256];

// (1) lower invariant + `!= -1` guard ⟹ >= 0; an explicit upper guard supplies the top.
// @invariant(s->cur >= -1)
int peek_guarded(box *s) {
  if (s->cur != -1 && s->cur < 256) {
    return g[s->cur];                  // !=-1 ∧ inv >=-1 ⟹ >=0; <256 upper — covered
  }
  return 0;
}

// (2) the SAME access WITHOUT the lower invariant — `!= -1` ALONE proves no lower bound
// (cur could be -5). Default-red: this is the soundness leg ( `!= c` is not a lower bound).
int peek_no_inv(box *s) {
  if (s->cur != -1 && s->cur < 256) {
    return g[s->cur];                  //EXPECT INDEX_MAYBE_NEGATIVE
  }
  return 0;
}

// (3) writes that preserve `>= -1`: a const -1 keeps it; a guarded `= i` (i >= 0 on the
// path) keeps it. Each `@maintains` is VERIFIED, not trusted.
// @invariant(p->cur >= -1)
void clear(box *p) {
  p->cur = -1;                         // @maintains(p->cur >= -1)  -1 >= -1 — preserved
}

// @invariant(p->cur >= -1)
void set_idx(box *p, int i) {
  if (i >= 0) {
    p->cur = i;                        // @maintains(p->cur >= -1)  i >= 0 ⟹ >= -1 — preserved
  }
}

// (4) a write that CLAIMS `@maintains` but the analysis cannot show preserves `>= -1`
// (v is unbounded) — a lie. Default-red.
// @invariant(p->cur >= -1)
void set_raw(box *p, int v) {
  p->cur = v;                          // @maintains(p->cur >= -1)  //EXPECT INVARIANT_NOT_MAINTAINED
}

// (5) BOTH an upper and a lower invariant on one field; a write @maintains both at once
// (the jsmn `toksuper` shape). The access chains the upper (cur < n <= cap, buf counted_by
// cap) and lifts the lower (!= -1 ∧ >= -1 ⟹ >= 0).
// @counted_by(buf: cap)
// @invariant(b->cur < b->n)
// @invariant(b->cur >= -1)
// @invariant(b->n <= cap)
int peek_both(box *b, int *buf, unsigned int cap) {
  if (b->cur != -1) {
    return buf[b->cur];                // >= 0 (lower) ∧ cur < n <= cap (upper chain) — covered
  }
  return 0;
}

// @invariant(b->cur < b->n)
// @invariant(b->cur >= -1)
void step(box *b) {
  b->cur = b->n - 1;                   // @maintains(b->cur < b->n)  upper: n-1<n; lower: n unsigned ⇒ n-1>=-1
}

// (6) SOUNDNESS: a `!= -1` short-circuit lift inside a compound `&&` condition (`cur` is
// `>= 0` only while that condition is being evaluated) must NOT persist PAST the if — after
// it, `cur` may be -1 again. The upper bound still holds (invariant chain), so isolating the
// lower: the unguarded access below is default-red. (If the lift leaked it would false-green.)
// @counted_by(buf: cap)
// @invariant(b->cur < b->n)
// @invariant(b->cur >= -1)
// @invariant(b->n <= cap)
int leak_check(box *b, int *buf, unsigned int cap) {
  if (b->cur != -1 && cap > 0) {
    /* a guarded access here would be clean; the lift is scoped to the condition */
  }
  return buf[b->cur];                  //EXPECT INDEX_MAYBE_NEGATIVE
}
