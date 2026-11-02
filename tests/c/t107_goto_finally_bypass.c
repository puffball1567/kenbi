// `@goto_finally cleanup` declares the cleanup convergence funnel. The proper error path
// routes through it (`goto cleanup`); the `if (err) return;` path exits still owning p and q
// WITHOUT routing through the funnel -> FINALLY_BYPASSED (route it via `goto cleanup`). The
// alloc-failure `if(!p) return;` is NOT flagged (p is null there, nothing to clean). Merge
// completeness at the funnel (free of q which is null on the goto path, etc.) is the usual
// inferred analysis.
#include <stdlib.h>
void f(int n, int err) {
  /* @mem demo::a { free: free, owner: p } */
  char *p = malloc(n);   //EXPECT FINALLY_BYPASSED
  if (!p) return;
  /* @mem demo::b { free: free, owner: q } */
  char *q = malloc(n);   //EXPECT FINALLY_BYPASSED
  if (!q) goto cleanup;
  if (err) return;
  // @goto_finally
cleanup:
  free(q);
  free(p);
}
