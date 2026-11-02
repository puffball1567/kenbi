// Cross-iteration hazard, now caught by the bounded fixpoint. `p` is allocated ONCE
// before the loop; freeing it inside the loop is a real double free whenever the loop
// runs ≥2 times. The fixpoint carries the freed state back to the loop head, so the
// free is a DOUBLE_FREE there — the single-pass model took only the 1st-iteration view
// and MISSED it (a soundness hole, a false GREEN). The may-analysis also surfaces the
// 0-trip LEAK (if the loop never runs, `p` is never freed): both are genuine for some
// trip count, and kenbi reports both. The fix is to free `p` after the loop (or guard
// it to run once).
#include <stdlib.h>
void f(int n) {
  /* @mem demo::buf { free: free, owner: p } */
  char *p = malloc(16);   //EXPECT LEAK
  for (int i = 0; i < n; i++) {
    free(p);   //EXPECT DOUBLE_FREE
  }
}
