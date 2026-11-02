// @spatial
// SPATIAL power-of-two MASK ring buffer (the AndersKaloer/Ring-Buffer idiom). A buffer is a
// POINTER FIELD sized `mask + 1` (mask is a power-of-two minus one); indices are kept in range
// by `idx & mask` (a RUNTIME mask, not a constant). Three machinery extensions, all DECLARED:
//   - `@counted_by(r->buf: r->mask + 1)` — a struct-field buffer sized by a field + a constant
//     offset (the buffer holds `mask + 1` elements).
//   - a symbolic mask `x & r->mask` (mask UNSIGNED) bounds the result `<= mask` (`< mask + 1`,
//     `>= 0`) — the mask IS the present runtime check, like `x & const` / `x % const`.
//   - a SET `field = X & mask` ESTABLISHES `field <= mask`, so the `@maintains` is verified.
#include <stddef.h>

typedef struct { char *buf; unsigned int mask; unsigned int head; } rb;

// (1) GREEN: queue-style. The access uses the declared invariant (head <= mask), chained to the
// buffer sized mask+1; the wrap write `(head+1) & mask` is verified to maintain head <= mask.
// @counted_by(r->buf: r->mask + 1)
// @invariant(r->head <= r->mask)
void rb_put(rb *r, char c) {
  r->buf[r->head] = c;                 // head <= mask < mask+1 = bufsize — covered
  r->head = (r->head + 1) & r->mask;   // @maintains(r->head <= r->mask)  — mask establishes <=
}

// (2) GREEN: peek-style. A LOCAL masked index `(head+i) & mask` is bounded `< mask + 1` by the
// symbolic mask, covering the buffer sized mask+1. No invariant needed (freshly masked).
// @counted_by(r->buf: r->mask + 1)
char rb_at(rb *r, unsigned int i) {
  unsigned int idx = (r->head + i) & r->mask;   // idx <= mask < mask+1 — symbolic mask
  return r->buf[idx];                           // covered
}

// (3) RED soundness: the `+ 1` matters. If the buffer is declared sized `mask` (not mask+1),
// `head <= mask` can reach index `mask` = one past a mask-element buffer. INAPPROPRIATE.
// @counted_by(r->buf: r->mask)
// @invariant(r->head <= r->mask)
char rb_offbyone(rb *r) {
  return r->buf[r->head];              //EXPECT INAPPROPRIATE_BOUND
}

// (4) RED soundness: a `@maintains` write the analysis cannot show preserves the invariant — a
// raw assignment of an unbounded value. The mask idiom does NOT excuse an arbitrary write.
// @counted_by(r->buf: r->mask + 1)
// @invariant(r->head <= r->mask)
void rb_bad(rb *r, unsigned int v) {
  r->head = v;                         // @maintains(r->head <= r->mask)  //EXPECT INVARIANT_NOT_MAINTAINED
}

// (5) RED soundness: masking by a field that is NOT the buffer's size operand does not relate
// the index to this buffer — the bound names the wrong identifier. Default-red.
typedef struct { char *buf; unsigned int mask; unsigned int other; } rb2;
// @counted_by(b->buf: b->mask + 1)
char rb_wrong_mask(rb2 *b, unsigned int x) {
  unsigned int idx = x & b->other;     // bounded by `other`, not the buffer's size `mask`
  return b->buf[idx];                  //EXPECT UNVALIDATED_INDEX
}
