// @spatial
// SPATIAL `||` reject-guard — the other canonical defensive form. `if (i < 0 || i >= n)
// return;` rejects out-of-range and falls through validated. By De Morgan the fall-
// through holds `i >= 0 && i < n`, so kenbi validates `i < n` on the path after it
// (the `i >= 0` lower bound is not tracked, consistent with the upper-bound-only model).
#include <stdlib.h>

extern int table[256];

// `||` reject into a fixed array — clean on the fall-through.
int reject_fixed(int i) {
  if (i < 0 || i >= 256) return -1;
  return table[i];                   // validated by the i < 256 disjunct's negation
}

// `||` reject into a heap buffer sized by the same identifier — clean.
int reject_heap(int n, int i) {
  /* @mem demo::buf { free: free, owner: buf } */
  char *buf = malloc(n);
  int r = 0;
  if (i < 0 || i >= n) {
    free(buf);
    return 0;
  }
  r = buf[i];                        // validated by the i >= n disjunct's negation
  free(buf);
  return r;
}

// A `||` whose disjuncts do NOT bound the access — still red.
int reject_unrelated(int n, int i, int flag) {
  /* @mem demo::buf { free: free, owner: buf } */
  char *buf = malloc(n);
  int r = 0;
  if (flag != 0 || i < 0) {          // neither disjunct gives an upper bound on i
    free(buf);
    return 0;
  }
  r = buf[i];                        //EXPECT UNVALIDATED_INDEX
  free(buf);
  return r;
}
