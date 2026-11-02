#include <stdlib.h>
// @owns(ret)
char *make_buf(int n) {
  /* @mem demo::buf { free: free, owner: p } */
  char *p = malloc(n);
  return p;      // ownership transfers to the caller — not a leak, not dangling
}
