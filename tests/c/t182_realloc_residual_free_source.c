// @kenbi
#include <stdlib.h>
// RED: the second fresh-dest residual — `q = realloc(p, n); free(p);`. On success realloc has moved
// the block to q and `p` is a stale (dangling) handle, so free(p) is a double-free / use-after-free.
// The release is refused (REALLOC_UNVERIFIED: which of p and q names the block is not known here),
// and the block nothing accounts for is the LEAK.
void f(int n) {
  /* @mem g::buf { free: free, owner: p } */
  char *p = (char *)malloc(16);   //EXPECT LEAK
  char *q = (char *)realloc(p, n);
  free(p);   //EXPECT REALLOC_UNVERIFIED
}
