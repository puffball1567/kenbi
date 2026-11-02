// @spatial
// SPATIAL overflow-safe bound guards. A guard whose OWN arithmetic can WRAP at runtime is
// credited in ℤ but is not sound under wraparound — kenbi REDs the wrap-prone forms and only
// credits the overflow-safe rewrites (declare-don't-infer). Two hazards:
//   (穴1) a positive offset on the UNTRUSTED variable, `i + k <REL> size`, wraps near the
//         type max (i = 0xFFFFFFFE, `i + 4 == 2 <= size` passes yet buf[i] is ~4GB OOB) —
//         sound only for an access at exactly `k`; a SMALLER access offset is exposed.
//   (穴2) a negative offset on the LIMIT, `i <= size - k`, UNDERFLOWS when size < k, making
//         the bound vacuous — needs the companion `size >= k` on the path.
// Option B extends 穴1 to SIGNED variables: `var + k` overflow is UB but an untrusted `var` can
// trigger it (i=INT_MAX -> INT_MIN passes `< lim` yet is OOB) — whether it overflows is an
// unverified property of an untrusted value, so default-red. Signed is STRICTER (no safe access
// offset, unlike unsigned's `j == gk`). 穴2 stays unsigned-only: signed `lim - k` fails CLOSED.

// (穴1) wrap-prone: `i + 4 <= size` wraps for unsigned i near UINT_MAX. Access buf[i] (offset
// 0 < guard offset 4) is exposed. RED.
// @counted_by(buf: size)
unsigned h1_var_add_bad(const unsigned char *buf, unsigned size, unsigned i) {
  if (i + 4 <= size) return buf[i];   //EXPECT INAPPROPRIATE_BOUND
  return 0;
}

// (穴1 refinement) neighbour form, access offset == guard offset: `i + 1 < n` guards buf[i+1]
// — guard and access share the SAME wrapped expression, so a wrap keeps the access in range.
// @counted_by(buf: n)
unsigned h1_neighbour_ok(const unsigned char *buf, unsigned n, unsigned i) {
  if (i + 1 < n) return buf[i + 1];   // ak == gk == 1 — safe under wrap
  return 0;
}

// overflow-safe rewrite of 穴1: arithmetic on the trusted limit. `size >= 4` blocks the
// `size - 4` underflow; `i <= size - 4` bounds i..i+3 with no wrap on i.
// @counted_by(buf: size)
unsigned h1_safe(const unsigned char *buf, unsigned size, unsigned i) {
  if (size >= 4 && i <= size - 4) return buf[i] + buf[i + 3];   // covered, no wrap
  return 0;
}

// (穴2) limit-side underflow WITHOUT the companion: `i <= size - 4` alone is vacuous when
// size < 4 (unsigned `size - 4` wraps to a huge value). RED.
// @counted_by(buf: size)
unsigned h2_no_companion(const unsigned char *buf, unsigned size, unsigned i) {
  if (i <= size - 4) return buf[i];   //EXPECT INAPPROPRIATE_BOUND
  return 0;
}

// (穴2) WITH the companion `size >= 4`: the `size - 4` underflow is blocked. GREEN.
// @counted_by(buf: size)
unsigned h2_companion_ok(const unsigned char *buf, unsigned size, unsigned i) {
  if (size >= 4 && i <= size - 4) return buf[i];   // companion blocks size-4 underflow
  return 0;
}

// ---- option B: SIGNED variable-side overflow (UB, but triggerable by an untrusted value) ----

// (穴1, signed) the neighbour form `i + 1 < n` guarding buf[i + 1] — access offset == guard
// offset. For UNSIGNED this is safe (wrap lands at 0, in range); for SIGNED it is NOT: i = INT_MAX
// makes `i + 1` = INT_MIN, which passes `< n` yet buf[INT_MIN] is far out of range. So signed has
// NO safe access offset. RED (even with the i >= 0 lower bound present).
// @counted_by(buf: n)
int b1_signed_neighbour(const char *buf, int n, int i) {
  if (i >= 0 && i + 1 < n) return buf[i + 1];   //EXPECT INAPPROPRIATE_BOUND
  return 0;
}

// (穴1, signed) look-ahead `i + 4 <= size` guarding buf[i] — signed, exposed like the unsigned
// h1_var_add_bad but by UB. RED.
// @counted_by(buf: size)
int b1_signed_lookahead(const char *buf, int size, int i) {
  if (i >= 0 && i + 4 <= size) return buf[i];   //EXPECT INAPPROPRIATE_BOUND
  return 0;
}

// (穴2, signed) limit-side `n - 4` needs NO companion: signed `n - 4` goes NEGATIVE when n < 4,
// so `i <= n - 4` is false and the branch is not taken (fail-CLOSED). GREEN — the sign asymmetry
// vs the unsigned h2_no_companion (which fails OPEN to a huge value).
// @counted_by(buf: n)
int b2_signed_limit_closed(const char *buf, int n, int i) {
  if (i >= 0 && i <= n - 4) return buf[i];   // signed n-4 fails closed — no companion required
  return 0;
}

// (穴1, loop condition) a wrap-prone form `i + 4 <= len` as a LOOP CONDITION cannot be
// wrap-gated at the sink (a loop cond lowers to a plain validate with no access-offset context),
// so it is DROPPED — the index is unbounded. RED (was a false GREEN leaking through the loop
// path before the guard). The overflow-safe loop idiom `while (p < end && end - p >= k)` is
// still credited (see t156 h_loop) because it carries no wrap hazard.
// @counted_by(buf: len)
unsigned h1_loop_cond(const unsigned char *buf, unsigned len, unsigned i) {
  unsigned acc = 0;
  while (i + 4 <= len) {
    acc += buf[i];   //EXPECT UNVALIDATED_INDEX
    i += 4;
  }
  return acc;
}
