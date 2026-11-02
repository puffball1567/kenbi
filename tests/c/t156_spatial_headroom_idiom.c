// @spatial
// SPATIAL overflow-SAFE two-variable idiom: `end - p >= k` — the parser "remaining bytes"
// check. It bounds the untrusted `p` by the trusted limit `end` with headroom `k` while
// keeping the arithmetic OFF `p` (the overflow-safe counterpart to the wrap-prone `p + k <=
// end`, which is RED — see t155). `end - p >= k` ⟹ `p <= end - k` ⟹ `p < end + (1 - k)`.
// The one hazard is that `end - p` UNDERFLOWS when `p > end` (unsigned): so it is creditable
// only when a sibling conjunct proves `p < end` (companion). A SIGNED `p` fails CLOSED
// (`end - p` goes negative → `>= k` false → branch skipped), so it needs no companion.
// This comment block is >6 lines so @spatial binds FILE-LEVEL, not to the first function.
#include <stddef.h>

// (1) credited: `p < end` companion present. buf[p] and buf[p+3] are covered by `end-p>=4`.
// @counted_by(buf: end)
unsigned h_ok(const unsigned char *buf, unsigned end, unsigned p) {
  if (p < end && end - p >= 4) return buf[p] + buf[p + 3];   // GREEN — covered, no wrap on p
  return 0;
}

// (2) past the headroom: `end - p >= 4` bounds p to `end - 3`, so buf[p+4] can reach end. RED.
// @counted_by(buf: end)
unsigned h_over(const unsigned char *buf, unsigned end, unsigned p) {
  if (p < end && end - p >= 4) return buf[p + 4];   //EXPECT INAPPROPRIATE_BOUND
  return 0;
}

// (3) NO `p < end` companion (the `&&` sibling `p != 0` does not establish `p <= end`): the
// `end - p` underflow is unguarded, so the two-var bound is DROPPED — buf[p] is unbounded. RED.
// @counted_by(buf: end)
unsigned h_no_companion(const unsigned char *buf, unsigned end, unsigned p) {
  if (end - p >= 4 && p != 0) return buf[p];   //EXPECT UNVALIDATED_INDEX
  return 0;
}

// (4) signed p fails CLOSED — no companion required. GREEN (with the i>=0 lower bound present).
// @counted_by(buf: end)
int h_signed(const char *buf, int end, int p) {
  if (p >= 0 && end - p >= 4) return buf[p];   // signed: end-p negative -> guard false -> safe
  return 0;
}

// (5) loop-condition form `while (p < end && end - p >= 4)` — the same reconciliation applies
// to a compound loop test, so buf[p] in the body is covered. GREEN.
// @counted_by(buf: end)
unsigned h_loop(const unsigned char *buf, unsigned end) {
  unsigned acc = 0, p = 0;
  while (p < end && end - p >= 4) {
    acc += buf[p];        // covered by the loop's `end - p >= 4` headroom
    p += 4;
  }
  return acc;
}
