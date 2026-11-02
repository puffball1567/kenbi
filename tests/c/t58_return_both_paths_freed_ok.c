#include <stdlib.h>
void f(int err) {
  /* @mem demo::buf { free: free, owner: p } */
  char *p = malloc(16);
  if (err) {
    free(p);
    return;        // both paths free then return — no stale-state false leak
  } else {
    free(p);
    return;
  }
}
