// @kenbi
#include <stdlib.h>
// GREEN: the standard reconciliation idiom, verified WITHOUT a vouch.
//
// `q = realloc(p, n)` leaves the pair unsettled: on OOM realloc returns NULL and the block is
// still the one `p` holds; on success the block is `q` and `p` is dangling. Which of them names
// it is decided by the null test the idiom is built around, and the two branches of that test
// learn opposite things — so kenbi settles the pair on each branch and checks what follows:
// here the success branch re-binds `p` to the result and the failure branch leaves `p` owning
// the original, so `free(p)` releases the one live block on both.
//
// Touching either handle BEFORE that test is still default-red (t181 / t182), and `@realloc`
// still vouches for a reconciliation kenbi cannot see.
void f(int n) {
  /* @mem g::buf { free: free, owner: p } */
  char *p = (char *)malloc(16);
  if (!p) { return; }
  char *tmp = (char *)realloc(p, n);
  if (tmp) { p = tmp; }
  free(p);
}
