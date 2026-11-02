// Soundness of join-merge, other direction: a double free that exists only ACROSS the
// join is caught. On the fall-through path `p` is freed before `cleanup`; the goto path
// reaches `cleanup` with `p` still owned. The label merges both, so `p` is may-freed at
// the second `free`, which is reported (DOUBLE_FREE on the fall-through path is real). The
// merge keeps the freed state visible past the jump — it is not erased by the goto edge.
#include <stdlib.h>
void f(int n, int cond) {
  /* @mem demo::p { free: free, owner: p } */
  char *p = malloc(n);
  if (cond) goto cleanup;
  free(p);
cleanup:
  free(p);   //EXPECT DOUBLE_FREE
}
