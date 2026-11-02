// Forward goto OUT of a loop to a top-level cleanup label — the ubiquitous C error-exit
// idiom. Previously refused (a goto inside a loop), now modelled: the goto deposits the
// owned state into the post-loop `cleanup` join, and the loop fixpoint snapshots the
// pending deposits so the exit is recorded once (not once per dry-run pass). The cleanup
// label merges the loop's normal-exit state with the goto-exit state; `p` is owned on
// both, freed once — clean. (A back-edge goto-loop is still refused, see t98.)
#include <stdlib.h>
void f(int n) {
  /* @mem demo::buf { free: free, owner: p } */
  char *p = malloc(n);
  for (int i = 0; i < n; i++) {
    if (i > 5) goto cleanup;
  }
cleanup:
  free(p);
}
