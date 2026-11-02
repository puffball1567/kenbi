// @spatial
// SPATIAL lower bound: an index/length is safe only when bounded BELOW as well as above.
// A SIGNED value bounded only above (`if (i < n) arr[i]`) can still be negative — an index
// below the buffer. kenbi requires the lower bound to be present on the path, the same
// default-red discipline as the upper bound: supply it by an UNSIGNED type (>= 0 by
// construction), a `>= 0` guard, or a constant `= 0` init. Without one it is
// INDEX_MAYBE_NEGATIVE. (A common idiom being red is a frequency fact, not a safety one —
// `if (i < n) arr[i]` on a signed i is genuinely unsafe.)
extern int buf[256];

// Signed index, bounded only ABOVE — could be negative. Default-red.
int guarded_above_only(int i) {
  if (i < 256) {
    return buf[i];                   //EXPECT INDEX_MAYBE_NEGATIVE
  }
  return 0;
}

// UNSIGNED index — >= 0 by type, and the guard gives the upper bound. Clean.
int unsigned_idx(unsigned int i) {
  if (i < 256) {
    return buf[i];                   // unsigned >= 0, i < 256 — both bounds present
  }
  return 0;
}

// Signed index with an explicit `>= 0` lower guard (compound with the upper). Clean.
int both_guards(int i) {
  if (i >= 0 && i < 256) {
    return buf[i];                   // i >= 0 (lower) and i < 256 (upper) — covered
  }
  return 0;
}

// Signed index established `= 0` then bounded above. Clean (the init supplies the lower).
int zero_init(int n) {
  int i = 0;
  if (i < 256) {
    return buf[i];                   // i = 0 gives i >= 0; i < 256 upper — covered
  }
  return n;
}

// A negative-going neighbour `buf[i - 1]` needs i >= 1, not just i >= 0. An unsigned i
// (>= 0) is NOT enough — i could be 0, so i - 1 underflows below the buffer. Default-red.
int neighbour_below(unsigned int i) {
  if (i < 256) {
    return buf[i - 1];               //EXPECT INDEX_MAYBE_NEGATIVE
  }
  return 0;
}
